// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] stage 2, the runtime: api.h says what it is. Here: the box (a
// wasm_engine::Engine running box/'s Lua), the entity tree with its
// instances, the queue of runs a tick works through within its budget,
// the save's two rows, the nodes that carry shared state to the clients,
// and the voxels the instances own.
#include "kit/api.h"
#include "accounts/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "interface/wasm_box.h"
#include "core/log.h"
#include "core/json.h"
#include "interface/fs.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/sha256.h"
#include "interface/os.h"
#include "kit/world.h"
#include "voxel_objects/api.h"
#include <Scene.h>
#include <Node.h>
#include <array>
#include <chrono>
#include <cmath>
#include <deque>
#include <fstream>
#include <mutex>
#include <algorithm>
#include <set>
#include <sstream>
#define MODULE "kit"

namespace kit {

namespace pv = PolyVox;
namespace magic = Urho3D;
using interface::Event;
using json::jstr;

// A signal passed along more links than this is a loop, and cut
static const int MAX_HOPS = 16;
static const size_t MAX_QUEUE = 4096;
// A run's slice of the box's meter is its budget() / this (about 5 ms of
// a plain loop); a tick works through TICK_SLICES of them at most
static const int64_t SLICE_DIV = 20;
static const int64_t TICK_SLICES = 4;
static const size_t MAX_TYPE_SOURCE = 256 << 10;
// A zone's or an owned volume's extent in cells, each way, and the cells
// a volume has at most
static const int MAX_EXTENT = 64;
static const int MAX_VOLUME = 64;
// The most of an item a player has (Kit's own counts, c:add)
static const int64_t MAX_ITEMS = 1000000;
// What an editor's packet may be and do
static const size_t MAX_EDIT_PACKET = 4096;
static const size_t MAX_STRING = 256;
static const double MAX_COORD = 30000;
static const size_t MAX_ENTITIES = 4096;
static const size_t MAX_LINKS = 64;
// An editor's undo goes back this many edits
static const size_t UNDO_MAX = 50;
// [KIT] stage 4d: the entities play makes at most (copies), a prefab's
// members, the lines an entity's log keeps, the signals a tick shows the
// builders flowing
static const size_t MAX_MADE = 1024;
static const size_t MAX_PREFAB = 64;
static const size_t LOG_LINES = 50;
static const size_t MAX_FLOWS = 64;
// [KIT] stage 4f: a brush's radius at most, a fill's side and depth at most;
// on a heightmap a dab's step a strength (metres) and the slope (rise a
// metre) its ground turns stone over (builtin/heightmap's generation's)
static const int MAX_BRUSH = 12;
static const int MAX_FILL = 64;
static const double HM_STEP = 0.25;
static const float HM_ROCK_SLOPE = 0.35f;
// on_remove runs inside the run that removed: so deep at most
static const int MAX_REMOVE_DEPTH = 4;

struct Link
{
	ss_ output;
	uint64_t to = 0;
	ss_ input;
};

struct Instance
{
	ss_ type; // "<author>/<name>"
	int64_t version = 1; // authored: the type's version it was made with
	json::Value params = json::object(); // authored
	sv_<Link> links; // authored
	json::Value state = json::object(); // runtime
	ss_ disabled; // runtime: why, "" while it runs
	// runtime: its timer (c:after), when on the game's clock (-1: none),
	// and who set off the run that set it
	int64_t due_us = -1;
	ss_ due_by;
	// runtime: the players in its zone, by their entity's id ([KIT] stage
	// 4d: saved, so a restart does not enter them again)
	std::set<ss_> inside;
	// authored: a prefab copy's parameters set on this copy, kept as the
	// prefab changes ([KIT] stage 4d)
	std::set<ss_> overrides;
};

struct Entity
{
	uint64_t id = 0, parent = 0;
	// "app", "scene", "player" (runtime, [KIT] stage 4d) or "" (an entity)
	ss_ name, kind;
	bool has_pos = false;
	double pos[3] = {0, 0, 0};
	// [KIT] stage 4e2: its turn round y, degrees 0...360 (its node's, its
	// look turning with it)
	double yaw = 0;
	sv_<Instance> comps;
	uint32_t node = 0; // a positional one's node in its scene
	// authored: a prefab copy's member, {"of", "version", "member" (its id
	// in the prefab), "copy" (the copy's first entity)}; undefined if none
	json::Value prefab;
	// runtime ([KIT] stage 4d): made in play (0: authored), 'g' a game
	// change or 'b' a build by made_by (a player's name), and the instance
	// that made it
	char made = 0;
	ss_ made_by;
	uint64_t maker = 0;
	size_t maker_comp = 0;
};

struct Type
{
	json::Value decl;
	std::set<ss_> inputs, outputs, handlers, shared;
	// [KIT] stage 4d: each signal's value's type ("any" where the file
	// gives none; "none": no value)
	sm_<ss_, ss_> in_types, out_types;
	// It reads every player entity (players = true); it is on each player
	// entity, not placed (player = true)
	bool players = false, player = false;
	// Its client part, <name>.client.lua beside it ("" none)
	ss_ client;
	bool usable = false, owns_voxel = false;
	// It provides the players' inventory (inventory = true)
	bool inventory = false;
	// [KIT] stage 4c: it places players at the round's start (spawn), it
	// says what players keep between plays (between_plays), it goes on the
	// app root (root)
	bool spawn = false, between_plays = false, root = false;
	// [KIT] stage 4e: it is the World (kit/world; the first on the root)
	bool world = false;
	ss_ spawn_param;
	// Its voxel writes are builds by the player who set the run off, not
	// game changes (builds = true)
	bool builds = false;
	int64_t version = 1;
	// The position parameters that are its zone's, its owned volume's and
	// its grants' extent ("" for none)
	ss_ zone, volume, grants;
};

struct Run
{
	uint64_t entity = 0;
	size_t comp = 0;
	ss_ handler;
	json::Value args = json::array();
	ss_ by = "app"; // who caused it, carried along the links
	int hops = 0;
};

struct Write
{
	main_context::SceneReference scene = nullptr;
	pv::Vector3DInt32 p;
	ss_ voxel, by;
	// Its origin while Running ([KIT] stage 4c): 'g' a game change, 'b' a
	// build by the player in `by`, 'k' kept as it is made (by `by`)
	char origin = 'g';
};

struct Peer
{
	ss_ name, scene;
	double pos[3] = {0, 0, 0};
	bool editing = false;
	// The tools' colour (an index of COLORS, -1 while they are off), the
	// selected entity (0: none) and the cursor (null: none), which the
	// other builders see
	int color = -1;
	uint64_t sel = 0;
	json::Value cursor = json::null();
	// Their player entity ([KIT] stage 4d; 0 before they have a name)
	uint64_t player = 0;
	// [KIT] 4d's answer: no account (a guest, p1...): their entity goes
	// when they leave or log in
	bool guest = false;
};

// A builder's colour while their tools are on: the first one no other
// builder has
static const char *COLORS[] = {"#ff5a4a", "#4aa0ff", "#50d050", "#ffb030",
	"#c060ff", "#30d0d0", "#ff70c0", "#c0c040"};
static const int NUM_COLORS = sizeof COLORS / sizeof COLORS[0];

// [KIT] stage 4c: a cell play changed and who: a build ('b', kept only if a
// builder keeps it at Stop) or kept as it is made ('k': a live edit, or a
// build with "Always keep builds"), and the voxel it was given. A cell the
// game changed has none; one whose voxel is another at Stop was changed
// by the game after (the last writer's)
struct Mark
{
	char kind = 'b';
	ss_ by;
	uint32_t id = 0;
};

// A build Stop discarded: its cell and final voxel, until the next Play;
// or ([KIT] stage 4d) an entity a player made (`entity` its row) or removed
// (`removed`, `entity` the authored one)
struct Discarded
{
	ss_ scene;
	int p[3] = {0, 0, 0};
	uint32_t id = 0;
	ss_ by;
	json::Value entity;
	bool removed = false;
};

// [KIT] stage 4d: an authored entity play removed, back at Stop: a game
// change, or a build ('b') of a player's
struct Removed
{
	Entity e;
	char origin = 'g';
	ss_ by;
};

// One edit: the entities it changed as they were before (null: not there),
// in the order an undo puts them back
struct Change
{
	sv_<std::pair<uint64_t, json::Value>> before;
	// [KIT] stage 4f: a terrain stroke (its id, -1: none), all its dabs one
	// change: the World's cells as they were before its first write to
	// each, a heightmap's samples likewise, and the decorations it put on
	// a heightmap (their ids in Kit's list)
	int64_t stroke = -1;
	std::map<std::tuple<int, int, int>, uint32_t> cells;
	std::map<std::pair<int, int>, std::pair<float, heightmap::Weights>>
			samples;
	sv_<uint64_t> decor;
};

// [KIT] stage 4f: a decoration on a heightmap surface: a voxel object of
// its structure's model, turned about y (degrees)
struct Decor
{
	ss_ structure;
	float x = 0, y = 0, z = 0, yaw = 0;
	unsigned node = 0;
};

struct Module;

// voxelworld's side: a write to a position Kit owns, queued for Kit's
// thread (it comes on voxelworld's, under its lock)
struct Owner: public voxelworld::OwnerHandler
{
	main_context::SceneReference scene;
	std::mutex *mutex;
	std::deque<Write> *queue;
	void on_write(voxelworld::Instance *world, const pv::Vector3DInt32 &p,
			const interface::VoxelInstance &v, const voxelworld::Owned &owned,
			const ss_ &by)
	{
		Write w;
		w.scene = scene;
		w.p = p;
		const interface::VoxelDefinition *def =
				world->get_voxel_reg()->get(world->get_voxel_reg()->get_format().
				id.get(v.data));
		w.voxel = def ? def->name.block_name : "?";
		w.by = by;
		std::lock_guard<std::mutex> lock(*mutex);
		if(queue->size() < MAX_QUEUE)
			queue->push_back(w);
	}
};

// [KIT] stage 4c: voxelworld's side of the copy-on-write start. A section's
// voxels before the round first writes to it, queued for Kit's thread (it
// comes on voxelworld's, under its lock) as the store's key and the copy
struct Watch: public voxelworld::SectionWatch
{
	ss_ scene;
	std::mutex *mutex;
	std::deque<std::pair<ss_, ss_>> *queue;
	void before_write(voxelworld::Instance *world,
			const pv::Vector3DInt16 &sp, const interface::VoxelVolume &before)
	{
		const ss_ key = "start:"+scene+":"+itos(sp.getX())+","+
				itos(sp.getY())+","+itos(sp.getZ());
		ss_ copy = interface::serialize_volume_compressed(before);
		std::lock_guard<std::mutex> lock(*mutex);
		queue->push_back(std::make_pair(key, std::move(copy)));
	}
};

// A JSON value as a Lua literal, for the box's requests (which it reads
// with an empty environment)
static void lua_lit(const json::Value &v, ss_ &o, int depth = 0)
{
	if(depth > 32){
		o += "nil";
		return;
	}
	switch(v.get_type()){
	case json::Value::T_BOOL:
		o += v.as_boolean() ? "true" : "false";
		return;
	case json::Value::T_INT:
		o += itos(v.as_integer());
		return;
	case json::Value::T_FLOAT: {
		const double d = v.as_real();
		if(d != d){
			o += "(0/0)";
		} else if(std::isinf(d)){
			o += d > 0 ? "(1/0)" : "(-1/0)";
		} else {
			char b[40];
			snprintf(b, sizeof b, "%.17g", d);
			o += b;
		}
		return; }
	case json::Value::T_STRING: {
		o += '"';
		for(unsigned char c : v.as_string()){
			if(c == '"' || c == '\\'){
				o += '\\';
				o += (char)c;
			} else if(c < 32 || c == 127){
				char b[8];
				snprintf(b, sizeof b, "\\%03d", c);
				o += b;
			} else {
				o += (char)c;
			}
		}
		o += '"';
		return; }
	case json::Value::T_ARRAY:
		o += '{';
		for(unsigned i = 0; i < v.size(); i++){
			lua_lit(v.at(i), o, depth + 1);
			o += ',';
		}
		o += '}';
		return;
	case json::Value::T_OBJECT:
		o += '{';
		for(json::Iterator it(v); it; ++it){
			o += '[';
			lua_lit(json::Value(it.key()), o, depth + 1);
			o += "]=";
			lua_lit(*it, o, depth + 1);
			o += ',';
		}
		o += '}';
		return;
	default:
		o += "nil";
	}
}

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	std::ostringstream os(std::ios::binary);
	os<<f.rdbuf();
	return os.str();
}

static bool name_ok(const ss_ &s)
{
	if(s.empty() || s.size() > 64)
		return false;
	for(char c : s)
		if(!isalnum((unsigned char)c) && c != '_')
			return false;
	return true;
}

// [KIT] stage 4d, typed signals: a value's type, as a signal declares it
static const char *SIGNAL_TYPES[] = {"any", "none", "number", "bool",
	"string", "entity", "position"};

// A type's inputs or outputs as its file gives them, {"a", b = "number"}
// (an array, or an object whose number keys are names of type "any"):
// the names, each one's type; the declaration's key made the array of the
// names and "<key>_types" an object of their types
static bool signals(json::Value &decl, const char *key, std::set<ss_> &names,
		sm_<ss_, ss_> &types, ss_ &why)
{
	const json::Value &v = decl.get(key);
	json::Value list = json::array(), typed = json::object();
	auto add = [&](const ss_ &name, const ss_ &type) -> bool {
		if(!name_ok(name)){
			why = ss_(key)+": a name is letters, digits and _: \""+
					name.substr(0, 64)+"\"";
			return false;
		}
		if(std::find_if(std::begin(SIGNAL_TYPES), std::end(SIGNAL_TYPES),
				[&](const char *t){ return type == t; }) ==
				std::end(SIGNAL_TYPES)){
			why = ss_(key)+": "+name+"'s type is one of any, none, number, "
					"bool, string, entity, position (not \""+type.substr(0, 32)+"\")";
			return false;
		}
		names.insert(name);
		types[name] = type;
		list.append(name);
		typed.set(name, type);
		return true;
	};
	if(v.is_array()){
		for(unsigned i = 0; i < v.size(); i++)
			if(v.at(i).is_string() && !add(v.at(i).as_string(), "any"))
				return false;
	} else if(v.is_object()){
		for(json::Iterator it(v); it; ++it){
			const bool index = !it.key().empty() && std::all_of(
					it.key().begin(), it.key().end(), ::isdigit);
			if(index && (*it).is_string()){
				if(!add((*it).as_string(), "any"))
					return false;
			} else if(!add(it.key(), (*it).is_string() ? (*it).as_string() :
					json::jstr(*it, "type"))){
				return false;
			}
		}
	} else if(!v.is_undefined()){
		why = ss_(key)+" is a list of names";
		return false;
	}
	decl.set(key, list);
	decl.set(ss_(key)+"_types", typed);
	return true;
}

// Whether a value is of a signal's type
static bool signal_ok(const ss_ &type, const json::Value &v)
{
	if(type == "number")
		return v.is_number() && std::isfinite(v.as_number());
	if(type == "bool")
		return v.is_boolean();
	if(type == "string")
		return v.is_string();
	if(type == "entity")
		return v.is_number() && v.as_number() >= 0 &&
				v.as_number() == std::floor(v.as_number());
	if(type == "position"){
		if(!v.is_array() || v.size() != 3)
			return false;
		for(unsigned k = 0; k < 3; k++)
			if(!v.at(k).is_number())
				return false;
		return true;
	}
	return true; // any, none
}

// Whether an output's values go to an input: either takes any, or the
// input takes none, or they are the same
static bool signals_meet(const ss_ &out, const ss_ &in)
{
	return out == "any" || in == "any" || in == "none" || out == in;
}

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	bool m_hosted = false;
	Host m_host;
	storage::Store *m_store = nullptr;
	up_<interface::WasmBox> m_box;
	bool m_starting = false;
	sm_<ss_, ss_> m_sources; // the types' Lua, by name
	sm_<ss_, Type> m_types;
	std::map<uint64_t, Entity> m_entities;
	uint64_t m_next_id = 2;
	// Players' entities have their own range, so a join does not move the
	// ids authoring gives out next
	// simplified: authored ids are not kept below it (a million entities)
	static const uint64_t FIRST_PLAYER = 1000000;
	uint64_t m_next_player = FIRST_PLAYER;
	std::deque<Run> m_queue;
	sm_<size_t, Peer> m_peers;
	bool m_runtime_dirty = false;
	// Writes routed to owned voxels, from voxelworld's thread
	std::mutex m_writes_mutex;
	std::deque<Write> m_writes;
	// Voxels an instance set whose section was not loaded: tried each tick
	std::deque<Write> m_pending_voxels;
	// The editor: edit rights the app gave or took (set_editor) over the
	// accounts' default, the types an editor places (each of Kit's
	// and the app's that loads), each editor's undo, and the sections Kit owns
	// positions in, each scene's
	std::map<ss_, bool> m_rights;
	// The replacing inventory provider (an entity's id and its instance; 0:
	// none: each player entity's own), and those refused as a second
	uint64_t m_provider = 0;
	size_t m_provider_comp = 0;
	std::set<ss_> m_inv_refused;
	// Types are "<author>/<name>": Kit's own in builtin/kit/types/ (author
	// "kit"), the app's in Host::types_path under its author
	ss_ m_kit_types, m_author;
	// The app's defaults for parameters, {type: {param: value}}
	json::Value m_defaults = json::object();
	std::set<ss_> m_palette;
	// Bare type names made <author>/<name> as the composition was read
	size_t m_migrated = 0;
	// Instances of Kit's own types made their file's version
	size_t m_upgraded = 0;
	sm_<ss_, std::deque<Change>> m_undo;
	std::map<main_context::SceneReference,
			std::set<std::tuple<int, int, int>>> m_owned_sections;
	// [KIT] stage 4c: the server Stopped or Running, one session (stage 7
	// adds more). The save's row "session" is it, "start" each instance's
	// state at the start ({"<id>": [{type, state, timer, timer_by}]}; none:
	// its type's defaults), and "start:<scene>:x,y,z" the voxel copies
	struct Session
	{
		bool running = false;
		ss_ by; // who started the round
		// The players who went through this round's start
		std::set<ss_> round;
		// The sections copied out this round, and copies that wait for
		// their section to load to be put back (a Stop's), as store keys
		std::set<ss_> copied, restore;
	} m_session;
	json::Value m_start = json::object();
	// Copies from voxelworld's thread (Watch)
	std::mutex m_copies_mutex;
	std::deque<std::pair<ss_, ss_>> m_copies;
	// The origins of the round's changed cells ("<scene>:x,y,z" a section,
	// its cells; saved as "marks:<scene>:x,y,z" beside its copy), the
	// sections changed since the last save, and the builds the last Stop
	// discarded (the row "discarded")
	std::map<ss_, std::map<std::tuple<int, int, int>, Mark>> m_marks;
	std::set<ss_> m_marks_dirty;
	sv_<Discarded> m_discarded;
	// Writes into the start (a migrated door's voxels cleared), tried each
	// tick until their section is loaded
	std::deque<Write> m_start_writes;
	// Migrated objects: their entity, cells that were owned and the voxel
	// that clears them ([KIT] stage 4c, the starter objects)
	struct Migrated
	{
		uint64_t id;
		sv_<pv::Vector3DInt32> cells;
		ss_ air;
	};
	sv_<Migrated> m_migrated_objects;
	// [KIT] stage 4d: authored entities play removed, back at Stop
	std::map<uint64_t, Removed> m_removed;
	// The players' entities by name (kept: a player's id is stable), and
	// what each keeps between plays ("keep inventory": their items)
	std::map<ss_, uint64_t> m_players;
	json::Value m_aside = json::object();
	// The types each player entity carries (`player = true`), Kit's own
	// inventory and score among them
	sv_<ss_> m_player_types;
	// Prefabs by "<author>/<name>", as read, and those placeable
	sm_<ss_, json::Value> m_prefabs;
	std::set<ss_> m_prefab_palette;
	// Those that did not load (logged once), and those loading now (a
	// prefab naming itself is none)
	std::set<ss_> m_bad_prefabs, m_prefab_loading;
	// Signals passed along links this tick, for the builders' link lines
	json::Value m_flows = json::array();
	// Each entity's log (its c:log lines and Kit's about it), not saved,
	// and those with new lines this tick
	std::map<uint64_t, std::deque<ss_>> m_logs;
	std::set<uint64_t> m_log_dirty;
	int m_remove_depth = 0;
	// Ids of entities being made together (a composition, a prefab's
	// copy), which an entity parameter may name before they are there
	std::set<uint64_t> m_pending_ids;
	// [KIT] stage 4e: the World (world.h) in Host::world_scene: the
	// material set, the parameters applied (the row "world") and parsed,
	// the finite map's lowest and highest ground, the section each player
	// is in (an infinite world loads round them), and the sections
	// generated (logged as worldgen's queue empties)
	main_context::SceneReference m_world_scene = nullptr;
	world::MaterialSet m_materials;
	json::Value m_world_applied;
	world::Params m_wp;
	int m_world_min = 0, m_world_max = 0;
	int m_section_size = 32;
	sm_<size_t, std::array<int32_t, 3>> m_world_peers;
	// Where players appear on a voxel World: the cell their feet go in
	std::array<int, 3> m_world_spawn = {{0, 1, 0}};
	size_t m_world_generated = 0, m_world_logged = 0;
	// A change that applies at the next start, warned of once
	ss_ m_world_pending;
	// Guests' dropped entities' names by their `by`, for this run
	// simplified: kept for the run (a name each guest that came)
	sm_<ss_, ss_> m_gone_guests;
	// [KIT] stage 4f: the World's generator version as the save pinned it
	// (1: a stage 4e save, kept so until the World changes; 0: none)
	int64_t m_saved_version = 0;
	// The decorations on a heightmap surface (row "decor"), by id, and the
	// voxel objects' models made, by structure
	std::map<uint64_t, Decor> m_decor;
	uint64_t m_next_decor = 1;
	bool m_decor_dirty = false;
	std::set<ss_> m_decor_models;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		// The owner handlers hold pointers into this module. Nothing is
		// saved here: the runtime row is written after each tick that
		// changed it, and the app's save may be closed by now
		if(m_hosted) try {
			voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
				for(auto &s : m_host.scenes){
					voxelworld::Instance *w = ivw->get_instance(s.second);
					if(w){
						w->set_owner_handler("kit", nullptr);
						w->set_section_watch(nullptr);
					}
				}
			});
		} catch(std::exception &e){
			log_w(MODULE, "The voxel owners' handlers not taken back: %s",
					e.what());
		}
	}

	void init()
	{
		sub(m_server, "core:tick", &Module::on_tick);
		// [KIT_DIG_STOP_ORDER] A client's kit packets are handled once
		// every module has handled what the client sent before them: a dig
		// (the app's packet, its module's thread) sent just before a Stop
		// is a build the Stop sees. Both kinds, so they keep their order
		for(const ss_ kind : {"use", "edit"})
			sub<network::Packet>(m_server, "network:packet_received/kit:"+kind,
					[this, kind](const network::Packet &p){
				m_server->emit_event_after_queued(interface::Event(
						"kit:"+kind+"_through", new network::Packet(p)));
			});
		sub(m_server, "kit:use_through", &Module::on_use);
		sub(m_server, "kit:edit_through", &Module::on_edit);
		sub(m_server, "network:client_disconnected", &Module::on_left);
		// [KIT] stage 4h: a body's inputs, a seat left
		sub(m_server, "network:packet_received/kit:input", &Module::on_input);
		sub(m_server, "network:packet_received/kit:exit", &Module::on_exit);
		sub(m_server, "accounts:privs", &Module::on_privs);
		sub(m_server, "voxelworld:section_loaded", &Module::on_section_loaded);
		sub(m_server, "worldgen:section_generated", &Module::on_generated);
		sub(m_server, "worldgen:queue_modified", &Module::on_gen_queue);
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	// ---- The box

	bool start_box(ss_ &why)
	{
		// The new box is made before the old one goes: a compile of the
		// .wasm under way is then the new one's to wait on, not killed (and
		// waited for) with the old
		// "box", meta.json's "wasm_box"
		up_<interface::WasmBox> b(m_server->create_wasm_box(MODULE, "box",
				why));
		m_box = std::move(b);
		if(!m_box)
			return false;
		// The types again: a new box knows none. One that fails here
		// leaves no box (no restart inside a restart). [KIT] stage 4h: the
		// movement library first
		m_starting = true;
		{
			ss_ answer;
			const ss_ lib = read_file(m_server->get_module_path(MODULE)+
					"/client_lua/move.lua");
			if(lib.empty() || !box_call("L"+lib, answer, why)){
				why = "client_lua/move.lua: "+(lib.empty() ? ss_("none") : why);
				m_starting = false;
				m_box.reset();
				return false;
			}
		}
		for(auto &s : m_sources){
			ss_ answer;
			if(!define(s.first, s.second, answer, why)){
				m_starting = false;
				m_box.reset();
				return false;
			}
		}
		m_starting = false;
		return true;
	}

	// One request: true and the answer, or false and the error.
	// *runaway: the meter stopped it (the box is a new one after that)
	// *in_provider: the meter stopped it in a call into the replacing
	// inventory provider (the box's last mark "P")
	bool box_call(const ss_ &request, ss_ &answer, ss_ &error,
			bool *runaway = nullptr, int64_t *spent = nullptr,
			bool *in_provider = nullptr)
	{
		if(runaway)
			*runaway = false;
		if(in_provider)
			*in_provider = false;
		if(!m_box){
			error = "no box";
			return false;
		}
		m_box->poll();
		// A type's file (and the box's first making) runs with the whole
		// of a call's budget; a handler with its slice
		// [KIT] stage 4h: a body's batch of steps a quarter
		const int64_t slice = request[0] == 'D' || request[0] == 'L' ?
				m_box->budget() : request[0] == 'S' ? m_box->budget() / 4 :
				m_box->budget() / SLICE_DIV;
		m_box->set_call_budget(slice);
		m_box->input = request;
		m_box->output.clear();
		uint32_t r = 0;
		const auto t0 = std::chrono::steady_clock::now();
		const ss_ trap = m_box->call("box_call", &r);
		log_d(MODULE, "A %c call: %i ms, %s, spent %lli of %lli", request[0],
				(int)std::chrono::duration_cast<std::chrono::milliseconds>(
				std::chrono::steady_clock::now() - t0).count(),
				trap.empty() ? "ok" : cs(trap),
				(long long)(slice - m_box->meter_left()), (long long)slice);
		if(spent)
			*spent = slice - std::max<int64_t>(0, m_box->meter_left());
		ss_ out = m_box->output;
		if(!trap.empty()){
			const bool past = m_box->meter_left() < 0;
			if(in_provider)
				*in_provider = past && !out.empty() && out.back() == 'P';
			bool recovered = false;
			if(!past){
				m_box->input.clear();
				m_box->output.clear();
				const ss_ t2 = m_box->call("box_recover", &r);
				recovered = t2.empty() && r == 1;
				out = m_box->output;
			}
			if(!recovered){
				// The state inside is not to be trusted: a new box
				error = past ? "past its budget of "+itos(slice)+
						" (a loop that does not end?)" : "trap: "+trap;
				if(runaway)
					*runaway = past;
				ss_ why;
				if(m_starting){
					m_box.reset();
				} else if(!start_box(why)){
					log_e(MODULE, "The box could not be started again: %s",
							cs(why));
					m_box.reset();
				} else {
					log_w(MODULE, "A new box after: %s", cs(error));
				}
				return false;
			}
		}
		// The marks of calls into the inventory provider, ahead of it
		const size_t marks = out.find_first_not_of("Pp");
		out = marks == ss_::npos ? ss_() : out.substr(marks);
		if(out.empty() || (out[0] != 'O' && out[0] != 'E')){
			error = "no answer";
			return false;
		}
		if(out[0] == 'E'){
			error = out.substr(1);
			return false;
		}
		answer = out.substr(1);
		return true;
	}

	bool define(const ss_ &name, const ss_ &src, ss_ &decl_json, ss_ &why)
	{
		ss_ request = "D"+name;
		request += '\0';
		request += src;
		if(!box_call(request, decl_json, why)){
			why = name+": "+why;
			return false;
		}
		return true;
	}

	// The directory an author's types are in: "" for an author not here
	// simplified: Kit's and the app's; other authors' come with stage 5's
	// packages
	ss_ author_path(const ss_ &author)
	{
		if(author == "kit")
			return m_kit_types;
		if(author == m_author)
			return m_host.types_path;
		return "";
	}

	// A bare type name (a save from before types had authors) as the
	// type it was: the app's own if it has one of the name, else Kit's
	ss_ full_type(const ss_ &type)
	{
		if(type.find('/') != ss_::npos || !name_ok(type))
			return type;
		if(!m_host.types_path.empty() &&
				interface::fs::path_exists(m_host.types_path+"/"+type+".lua"))
			return m_author+"/"+type;
		return "kit/"+type;
	}

	bool load_type(const ss_ &name, ss_ &why)
	{
		if(m_types.count(name))
			return true;
		const size_t slash = name.find('/');
		const ss_ author = slash == ss_::npos ? "" : name.substr(0, slash);
		const ss_ short_name = slash == ss_::npos ? name : name.substr(slash + 1);
		if(!name_ok(author) || !name_ok(short_name)){
			why = "a type is <author>/<name>, each letters, digits and _: \""+
					name.substr(0, 64)+"\"";
			return false;
		}
		const ss_ dir = author_path(author);
		if(dir.empty()){
			why = "no component type "+name+" (no types of "+author+" here)";
			return false;
		}
		const ss_ path = dir+"/"+short_name+".lua";
		const ss_ src = read_file(path);
		if(src.empty() || src.size() > MAX_TYPE_SOURCE){
			why = "no component type "+name+" ("+path+")";
			return false;
		}
		ss_ decl_json;
		if(!define(name, src, decl_json, why))
			return false;
		m_sources[name] = src;
		Type t;
		t.decl = json::load_string(decl_json.c_str());
		auto names = [&](const char *key, std::set<ss_> &out){
			const json::Value &a = t.decl.get(key);
			for(unsigned i = 0; i < a.size(); i++)
				if(a.at(i).is_string())
					out.insert(a.at(i).as_string());
		};
		if(!signals(t.decl, "inputs", t.inputs, t.in_types, why) ||
				!signals(t.decl, "outputs", t.outputs, t.out_types, why)){
			why = name+": "+why;
			return false;
		}
		names("handlers", t.handlers);
		t.players = t.decl.get("players").is_true();
		t.player = t.decl.get("player").is_true();
		// Its client part, beside it
		const ss_ client = read_file(dir+"/"+short_name+".client.lua");
		if(client.size() > MAX_TYPE_SOURCE / 4){
			why = name+": its client part is past "+itos(MAX_TYPE_SOURCE / 4)+
					" bytes";
			return false;
		}
		t.client = client;
		const json::Value &st = t.decl.get("state");
		if(st.is_object())
			for(json::Iterator it(st); it; ++it)
				if((*it).get("shared").is_true())
					t.shared.insert(it.key());
		t.usable = t.decl.get("usable").is_true();
		t.owns_voxel = t.decl.get("owns_voxel").is_true();
		const json::Value &ver = t.decl.get("version");
		if(!ver.is_undefined() && (!ver.is_number() ||
				ver.as_number() != std::floor(ver.as_number()) ||
				ver.as_number() < 1 || ver.as_number() > 1e9)){
			why = name+": its version is a whole number from 1";
			return false;
		}
		t.version = ver.is_number() ? (int64_t)ver.as_number() : 1;
		t.inventory = t.decl.get("inventory").is_true();
		// spawn = true, or ([KIT] stage 4d) the bool parameter whose value
		// says whether the instance places players
		t.spawn = t.decl.get("spawn").is_true() ||
				t.decl.get("spawn").is_string();
		if(t.decl.get("spawn").is_string()){
			t.spawn_param = t.decl.get("spawn").as_string();
			if(jstr(t.decl.get("params").get(t.spawn_param), "type") != "bool"){
				why = name+": its spawn names no bool parameter";
				return false;
			}
		}
		t.between_plays = t.decl.get("between_plays").is_true();
		t.root = t.decl.get("root").is_true();
		t.world = t.decl.get("world").is_true();
		t.builds = t.decl.get("builds").is_true();
		for(const char *h : {"inventory_count", "inventory_add",
				"inventory_take", "inventory_list"})
			if(t.inventory && !t.handlers.count(h)){
				why = name+": an inventory provider has "+h;
				return false;
			}
		// The app's defaults for its parameters, over the type's own
		json::Value params = t.decl.get("params").deepcopy();
		const json::Value &defs = m_defaults.get(name);
		if(defs.is_object() && params.is_object())
			for(json::Iterator it(defs); it; ++it){
				const ss_ bad = !params.get(it.key()).is_object() ?
						"not a parameter of it" :
						check_param(params.get(it.key()), *it);
				if(!bad.empty()){
					log_w(MODULE, "The app's default for %s's %s left out: %s",
							cs(name), cs(it.key()), cs(bad));
					continue;
				}
				json::Value p = params.get(it.key());
				p.set("default", *it);
				params.set(it.key(), p);
				t.decl.set("params", params);
			}
		// zone, volume and grants name position parameters of the type's own
		for(auto k : {std::make_pair("zone", &t.zone),
				std::make_pair("volume", &t.volume),
				std::make_pair("grants", &t.grants)}){
			const ss_ pn = jstr(t.decl, k.first);
			if(pn.empty())
				continue;
			if(jstr(t.decl.get("params").get(pn), "type") != "position"){
				why = name+": its "+k.first+" names no position parameter";
				return false;
			}
			*k.second = pn;
		}
		// A grant's state is shown on the clients ([KIT] stage 4e2: where a
		// player may dig or place)
		if(!t.grants.empty()){
			t.shared.insert("dig");
			t.shared.insert("place");
		}
		// A look's extent is a position parameter's too
		const ss_ lx = jstr(t.decl.get("look"), "extent");
		if(!lx.empty() && jstr(t.decl.get("params").get(lx), "type") !=
				"position"){
			why = name+": its look's extent names no position parameter";
			return false;
		}
		if(!t.volume.empty() && !t.owns_voxel){
			why = name+": a volume is the voxels it owns (owns_voxel)";
			return false;
		}
		m_types[name] = t;
		log_i(MODULE, "Component type %s version %lli: inputs %zu, outputs "
				"%zu, %s%s%s", cs(name), (long long)t.version, t.inputs.size(),
				t.outputs.size(), t.usable ? "usable" : "not usable",
				t.owns_voxel ? ", owns its voxel" : "",
				t.inventory ? ", an inventory provider" : "");
		return true;
	}

	// ---- The tree

	main_context::SceneReference scene_of(const Entity &e, ss_ *name = nullptr)
	{
		uint64_t id = e.parent;
		for(int i = 0; i < 64 && id; i++){
			auto it = m_entities.find(id);
			if(it == m_entities.end())
				return nullptr;
			if(it->second.kind == "scene"){
				auto s = m_host.scenes.find(it->second.name);
				if(name)
					*name = it->second.name;
				return s == m_host.scenes.end() ? nullptr : s->second;
			}
			id = it->second.parent;
		}
		return nullptr;
	}

	static pv::Vector3DInt32 voxel_p(const Entity &e)
	{
		return pv::Vector3DInt32((int32_t)std::floor(e.pos[0]),
				(int32_t)std::floor(e.pos[1]), (int32_t)std::floor(e.pos[2]));
	}

	// An extent parameter's cells each way: whole numbers, 1...MAX_EXTENT
	static void extent(const json::Value &v, int out[3])
	{
		for(unsigned k = 0; k < 3; k++){
			const double d = v.at(k).is_number() ? v.at(k).as_number() : 1;
			out[k] = (int)std::max(1.0, std::min((double)MAX_EXTENT,
					std::floor(d)));
		}
	}

	// The cells an entity owns: its own, or its owning instance's volume
	// (from its cell up and on, the volume's extent; simplified: one past
	// MAX_VOLUME cells is its own cell alone)
	sv_<pv::Vector3DInt32> owned_cells(const Entity &e)
	{
		sv_<pv::Vector3DInt32> out;
		if(!e.has_pos)
			return out;
		const pv::Vector3DInt32 o = voxel_p(e);
		for(const Instance &in : e.comps){
			const Type &t = m_types[in.type];
			if(!t.owns_voxel)
				continue;
			int n[3] = {1, 1, 1};
			if(!t.volume.empty())
				extent(in.params.get(t.volume), n);
			if(n[0] * n[1] * n[2] > MAX_VOLUME)
				n[0] = n[1] = n[2] = 1;
			for(int x = 0; x < n[0]; x++)
				for(int y = 0; y < n[1]; y++)
					for(int z = 0; z < n[2]; z++)
						out.push_back(o + pv::Vector3DInt32(x, y, z));
			break;
		}
		return out;
	}

	// A parameter's value as its declaration types it: "" when it is one,
	// else what it should be. The composition's, the save's and an
	// editor's values all pass here
	ss_ check_param(const json::Value &decl, const json::Value &v)
	{
		const ss_ t = jstr(decl, "type");
		// A parameter of a few choices ([KIT] stage 4d): one of them
		const json::Value &ch = decl.get("choices");
		if(ch.is_array()){
			for(unsigned i = 0; i < ch.size(); i++)
				if(ch.at(i).stringify() == v.stringify())
					return "";
			return "one of "+ch.stringify().substr(0, 200);
		}
		if(t == "prefab"){
			// "": none
			if(!v.is_string() || v.as_string().size() > 130)
				return "a prefab's name";
			if(!v.as_string().empty() && !prefab(v.as_string()))
				return "a prefab there is (no \""+v.as_string()+"\")";
			return "";
		}
		if(t == "number"){
			if(!v.is_number() || !std::isfinite(v.as_number()))
				return "a number";
			const json::Value &lo = decl.get("min"), &hi = decl.get("max");
			if(lo.is_number() && v.as_number() < lo.as_number())
				return "at least "+lo.stringify();
			if(hi.is_number() && v.as_number() > hi.as_number())
				return "at most "+hi.stringify();
			return "";
		}
		if(t == "bool")
			return v.is_boolean() ? "" : "true or false";
		if(t == "string"){
			if(!v.is_string() || v.as_string().size() > MAX_STRING)
				return "a string of at most "+itos(MAX_STRING)+" bytes";
			for(unsigned char c : v.as_string())
				if(c < 32 || c == 127)
					return "a line of text";
			return "";
		}
		if(t == "voxel"){
			// "": none (a type's own default the app or the composer fills)
			if(!v.is_string() || v.as_string().size() > 64)
				return "a voxel's name";
			for(char c : v.as_string())
				if(!isalnum((unsigned char)c) && c != '_' && c != ':' &&
						c != '/')
					return "a voxel's name (letters, digits, _, : and /)";
			return "";
		}
		if(t == "entity"){
			// 0: none
			if(!v.is_number() || v.as_number() != std::floor(v.as_number()) ||
					v.as_number() < 0 || v.as_number() > 9e15 ||
					(v.as_number() != 0 &&
					!m_entities.count((uint64_t)v.as_number()) &&
					!m_pending_ids.count((uint64_t)v.as_number())))
				return "an entity's id";
			return "";
		}
		if(t == "position")
			return pos_ok(v) ? "" : "a position, three numbers";
		return "a type of parameter Kit has (\""+t.substr(0, 32)+"\" is none)";
	}

	// An editor's coordinate: on a 1/16 cell's grid ([KIT] stage 4d: off
	// the voxels' own, kit/part's)
	static double grid(double v)
	{
		return std::round(v * 16) / 16;
	}

	// A turn as kept: 0...360, on a 1/16 degree's grid
	static double norm_yaw(double a)
	{
		if(!std::isfinite(a))
			return 0;
		a = std::fmod(a, 360.0);
		if(a < 0)
			a += 360;
		a = std::round(a * 16) / 16;
		return a >= 360 ? 0 : a;
	}

	static bool pos_ok(const json::Value &p)
	{
		if(!p.is_array() || p.size() != 3)
			return false;
		for(unsigned k = 0; k < 3; k++)
			if(!p.at(k).is_number() || !std::isfinite(p.at(k).as_number()) ||
					std::fabs(p.at(k).as_number()) > MAX_COORD)
				return false;
		return true;
	}

	// [KIT] stage 4c: Kit's door, key door, gate, button and lever were the
	// voxels they owned (version 1); they are objects now, their look and
	// collision on the clients. An instance of before has its voxels'
	// parameters dropped and its type's version, and the cells it owned are
	// cleared once the tree is read (their owner entries, and their voxel
	// made its "open" one, air by default). True if it was one
	bool migrate_object(const Entity &e, Instance &in, const json::Value &pj)
	{
		static const char *OLD[] = {"closed", "open", "up", "down",
				"off_voxel", "on_voxel"};
		const ss_ &t = in.type;
		const bool sized = t == "kit/door" || t == "kit/key_door" ||
				t == "kit/gate";
		if(!sized && t != "kit/button" && t != "kit/lever")
			return false;
		bool old = in.version < 2;
		for(const char *k : OLD)
			old = old || !pj.get(k).is_undefined();
		if(!old)
			return false;
		Migrated m;
		m.id = e.id;
		m.air = jstr(pj, "open").empty() ? "air" : jstr(pj, "open");
		if(e.has_pos){
			int n[3] = {1, 1, 1};
			if(sized){
				json::Value size = pj.get("size");
				if(!pos_ok(size)){
					size = json::array();
					for(int k : {t == "kit/gate" ? 3 : 1, t == "kit/gate" ? 3 : 2, 1})
						size.append((int64_t)k);
				}
				extent(size, n);
			}
			if(n[0] * n[1] * n[2] > MAX_VOLUME)
				n[0] = n[1] = n[2] = 1;
			const pv::Vector3DInt32 o = voxel_p(e);
			for(int x = 0; x < n[0]; x++)
				for(int y = 0; y < n[1]; y++)
					for(int z = 0; z < n[2]; z++)
						m.cells.push_back(o + pv::Vector3DInt32(x, y, z));
		}
		in.version = m_types[t].version;
		m_migrated_objects.push_back(m);
		log_i(MODULE, "Entity %s's %s is an object now: its voxels' parameters "
				"dropped, its %zu owned cells to be cleared to %s", cs(itos(e.id)),
				cs(t), m.cells.size(), cs(m.air));
		return true;
	}

	// An entity as the authored row has it (the parent and the links not
	// checked against the tree here)
	bool entity_from_json(const json::Value &j, Entity &e, ss_ &why)
	{
		e.id = (uint64_t)json::jint(j, "id", 0);
		e.parent = (uint64_t)json::jint(j, "parent", 1);
		e.name = jstr(j, "name");
		e.kind = jstr(j, "kind");
		if(e.id < 2){
			why = "an entity's id is 2 or more: "+j.stringify().substr(0, 200);
			return false;
		}
		if(e.kind != "" && e.kind != "scene" && e.kind != "player"){
			why = "entity "+itos(e.id)+": no kind \""+e.kind+"\"";
			return false;
		}
		const json::Value &pf = j.get("prefab");
		if(pf.is_object() && !jstr(pf, "of").empty())
			e.prefab = pf.deepcopy();
		const json::Value &p = j.get("pos");
		if(!p.is_undefined()){
			if(!pos_ok(p)){
				why = "entity "+itos(e.id)+": a position is three numbers";
				return false;
			}
			e.has_pos = true;
			for(unsigned k = 0; k < 3; k++)
				e.pos[k] = p.at(k).as_number();
		}
		if(j.get("yaw").is_number())
			e.yaw = norm_yaw(j.get("yaw").as_number());
		const json::Value &cs_ = j.get("components");
		for(unsigned k = 0; k < cs_.size(); k++){
			const json::Value &cj = cs_.at(k);
			Instance in;
			in.type = full_type(jstr(cj, "type"));
			if(in.type != jstr(cj, "type")){
				log_i(MODULE, "Entity %s's type %s is %s now", cs(itos(e.id)),
						cs(jstr(cj, "type")), cs(in.type));
				m_migrated++;
			}
			if(!load_type(in.type, why))
				return false;
			const Type &t = m_types[in.type];
			// The version it was made with; the type's own for a new one
			// simplified: one version of a type is on disk, and an
			// instance of another runs on it. An explicit upgrade (and a
			// parameter migration hook) comes with stage 5's packages
			const json::Value &ver = cj.get("version");
			in.version = ver.is_number() && ver.as_number() >= 1 &&
					ver.as_number() <= 1e9 ? (int64_t)ver.as_number() : t.version;
			const json::Value &pj = cj.get("params");
			// A starter door, gate, button or lever of before is an object
			const bool object = migrate_object(e, in, pj);
			// Kit's own types keep their older versions' parameters: an
			// instance of one is upgraded to the file's ([KIT] stage 4d)
			if(!object && in.version < t.version &&
					in.type.compare(0, 4, "kit/") == 0){
				log_i(MODULE, "Entity %s's %s upgraded from version %lli to "
						"%lli", cs(itos(e.id)), cs(in.type), (long long)in.version,
						(long long)t.version);
				in.version = t.version;
				m_upgraded++;
			}
			if(in.version != t.version)
				log_w(MODULE, "Entity %s's %s is of version %lli, its file "
						"%lli: run on the file's", cs(itos(e.id)), cs(in.type),
						(long long)in.version, (long long)t.version);
			// The parameters the type declares, its defaults under the
			// instance's
			const json::Value &decl = t.decl.get("params");
			if(decl.is_object())
				for(json::Iterator it(decl); it; ++it)
					in.params.set(it.key(), (*it).get("default"));
			if(pj.is_object())
				for(json::Iterator it(pj); it; ++it){
					if(object && !decl.get(it.key()).is_object())
						continue;
					if(!decl.get(it.key()).is_object()){
						why = "entity "+itos(e.id)+": "+in.type+
								" has no parameter "+it.key();
						return false;
					}
					const ss_ bad = check_param(decl.get(it.key()), *it);
					if(!bad.empty()){
						why = "entity "+itos(e.id)+": "+in.type+"'s "+
								it.key()+" is "+bad;
						return false;
					}
					in.params.set(it.key(), *it);
				}
			const json::Value &ov = cj.get("overrides");
			for(unsigned m = 0; m < ov.size(); m++)
				if(ov.at(m).is_string() && decl.get(ov.at(m).as_string()).
						is_object())
					in.overrides.insert(ov.at(m).as_string());
			const json::Value &ls = cj.get("links");
			for(unsigned m = 0; m < ls.size(); m++){
				Link l;
				l.output = jstr(ls.at(m), "output");
				l.to = (uint64_t)json::jint(ls.at(m), "to", 0);
				l.input = jstr(ls.at(m), "input");
				if(!t.outputs.count(l.output)){
					why = "entity "+itos(e.id)+": "+in.type+
							" has no output "+l.output;
					return false;
				}
				in.links.push_back(l);
			}
			e.comps.push_back(in);
		}
		return true;
	}

	json::Value entity_json(const Entity &e)
	{
		json::Value j = json::object();
		j.set("id", (int64_t)e.id);
		j.set("parent", (int64_t)e.parent);
		j.set("name", e.name);
		if(!e.kind.empty())
			j.set("kind", e.kind);
		if(!e.prefab.is_undefined())
			j.set("prefab", e.prefab);
		if(e.has_pos){
			json::Value pos = json::array();
			for(int k = 0; k < 3; k++)
				pos.append(e.pos[k]);
			j.set("pos", pos);
			if(e.yaw != 0)
				j.set("yaw", e.yaw);
		}
		json::Value comps = json::array();
		for(const Instance &in : e.comps){
			json::Value cj = json::object();
			cj.set("type", in.type);
			cj.set("version", in.version);
			cj.set("params", in.params);
			if(!in.overrides.empty()){
				json::Value ov = json::array();
				for(const ss_ &o : in.overrides)
					ov.append(o);
				cj.set("overrides", ov);
			}
			json::Value ls = json::array();
			for(const Link &l : in.links){
				json::Value lj = json::object();
				lj.set("output", l.output);
				lj.set("to", (int64_t)l.to);
				lj.set("input", l.input);
				ls.append(lj);
			}
			cj.set("links", ls);
			comps.append(cj);
		}
		j.set("components", comps);
		return j;
	}

	bool load_composition(const json::Value &c, ss_ &why)
	{
		Entity root;
		root.id = 1;
		root.kind = "app";
		root.name = "app";
		m_entities[1] = root;
		const json::Value &es = c.get("entities");
		m_pending_ids.clear();
		for(unsigned i = 0; i < es.size(); i++)
			m_pending_ids.insert((uint64_t)json::jint(es.at(i), "id", 0));
		for(unsigned i = 0; i < es.size(); i++){
			Entity e;
			const bool ok = entity_from_json(es.at(i), e, why);
			if(ok && e.kind == "player")
				why = "entity "+itos(e.id)+": a player is no authored entity";
			else if(ok && m_entities.count(e.id))
				why = "entity "+itos(e.id)+" twice";
			if(!ok || e.kind == "player" || m_entities.count(e.id)){
				m_pending_ids.clear();
				return false;
			}
			m_entities[e.id] = e;
		}
		m_pending_ids.clear();
		m_next_id = std::max<uint64_t>((uint64_t)json::jint(c, "next_id", 2), 2);
		for(auto &p : m_entities){
			Entity &e = p.second;
			if(e.id != 1 && !m_entities.count(e.parent)){
				why = "entity "+itos(e.id)+": no parent "+itos(e.parent);
				return false;
			}
			m_next_id = std::max(m_next_id, e.id + 1);
			if(e.kind == "scene" && !m_host.scenes.count(e.name)){
				why = "scene "+e.name+": the app has none of that name";
				return false;
			}
			if(e.has_pos && !scene_of(e)){
				why = "entity "+itos(e.id)+" has a position and no scene";
				return false;
			}
			for(Instance &in : e.comps)
				for(const Link &l : in.links)
					if(!m_entities.count(l.to)){
						why = "entity "+itos(e.id)+": a link to "+itos(l.to)+
								", which is not there";
						return false;
					}
		}
		return true;
	}

	// Whether an entity is the composition's: not made in play, no player
	static bool authored(const Entity &e)
	{
		return !e.made && e.kind != "player";
	}

	// The composition: the authored entities, those play removed too
	json::Value authored_json()
	{
		std::map<uint64_t, const Entity*> all;
		for(auto &p : m_entities)
			if(p.first != 1 && authored(p.second))
				all[p.first] = &p.second;
		for(auto &r : m_removed)
			all[r.first] = &r.second.e;
		json::Value c = json::object();
		json::Value es = json::array();
		for(auto &p : all)
			es.append(entity_json(*p.second));
		c.set("entities", es);
		c.set("next_id", (int64_t)m_next_id);
		return c;
	}

	// {"<id>": [{"type", "state", "disabled", "timer": s, "timer_by",
	//  "inside": [id...]}, ...]}, and ([KIT] stage 4d) unless it is for the
	// start, the round's entities: "made": [{"entity", "origin", "by",
	// "maker": [id, comp]}], "removed": [{"entity", "origin", "by"}], the
	// players {name: {"id", "aside"}} and "next_id"
	json::Value runtime_json(bool for_start = false)
	{
		json::Value r = json::object();
		const int64_t now = interface::os::game_us();
		json::Value made = json::array();
		for(auto &p : m_entities){
			if(p.second.comps.empty() || (for_start && !authored(p.second)))
				continue;
			json::Value a = json::array();
			for(const Instance &in : p.second.comps){
				json::Value j = json::object();
				j.set("type", in.type);
				j.set("state", in.state);
				if(!in.disabled.empty())
					j.set("disabled", in.disabled);
				if(in.due_us >= 0){
					j.set("timer", std::max<int64_t>(0, in.due_us - now) / 1e6);
					j.set("timer_by", in.due_by);
				}
				if(!in.inside.empty() && !for_start){
					json::Value ins = json::array();
					for(const ss_ &x : in.inside)
						ins.append(x);
					j.set("inside", ins);
				}
				a.append(j);
			}
			r.set(itos(p.first), a);
			if(p.second.made){
				json::Value m = json::object(), mk = json::array();
				m.set("entity", entity_json(p.second));
				m.set("origin", ss_(1, p.second.made));
				m.set("by", p.second.made_by);
				mk.append((int64_t)p.second.maker);
				mk.append((int64_t)p.second.maker_comp);
				m.set("maker", mk);
				made.append(m);
			}
		}
		if(for_start)
			return r;
		json::Value removed = json::array();
		for(auto &rm : m_removed){
			json::Value m = json::object();
			m.set("entity", entity_json(rm.second.e));
			m.set("origin", ss_(1, rm.second.origin));
			m.set("by", rm.second.by);
			removed.append(m);
		}
		json::Value players = json::object();
		for(auto &p : m_players){
			json::Value j = json::object();
			j.set("id", (int64_t)p.second);
			if(m_aside.get(p.first).is_object())
				j.set("aside", m_aside.get(p.first));
			players.set(p.first, j);
		}
		r.set("made", made);
		r.set("removed", removed);
		r.set("players", players);
		r.set("next_id", (int64_t)m_next_id);
		return r;
	}

	// An instance's runtime from a runtime row's entry for it
	static void runtime_from(Instance &in, const json::Value &s)
	{
		const json::Value &st = s.get("state");
		if(st.is_object())
			for(json::Iterator it(st); it; ++it)
				in.state.set(it.key(), *it);
		in.disabled = jstr(s, "disabled");
		const json::Value &t = s.get("timer");
		in.due_us = t.is_number() && t.as_number() >= 0 ?
				interface::os::game_us() + (int64_t)(t.as_number() * 1e6) : -1;
		in.due_by = jstr(s, "timer_by");
		in.inside.clear();
		const json::Value &ins = s.get("inside");
		for(unsigned i = 0; i < ins.size(); i++)
			if(ins.at(i).is_string())
				in.inside.insert(ins.at(i).as_string());
	}

	void save_runtime()
	{
		if(!m_store || !m_runtime_dirty)
			return;
		m_store->set("runtime", runtime_json().stringify());
		m_runtime_dirty = false;
		log_v(MODULE, "Runtime state saved");
	}

	// ---- Hosting

	bool host(const Host &host, ss_ &why)
	{
		if(m_hosted){
			why = "Kit is hosted already";
			log_e(MODULE, "%s", cs(why));
			return false;
		}
		const bool ok = host_u(host, why);
		if(!ok)
			log_e(MODULE, "Not hosted: %s", cs(why));
		return ok;
	}

	bool host_u(const Host &host, ss_ &why)
	{
		m_host = host;
		if(!host.save){
			why = "no save";
			return false;
		}
		m_store = host.save->store("kit");
		m_kit_types = m_server->get_module_path(MODULE)+"/types";
		m_author = host.author;
		if(m_author.empty()){
			// The app's id, as an author's name has it
			m_author = m_server->get_app_id().substr(0, 64);
			for(char &c : m_author)
				if(!isalnum((unsigned char)c))
					c = '_';
		}
		if(!name_ok(m_author) || m_author == "kit"){
			why = "the app's author is letters, digits and _, not kit: \""+
					m_author.substr(0, 64)+"\"";
			return false;
		}
		if(!host.defaults.empty()){
			m_defaults = json::load_string(host.defaults.c_str());
			if(!m_defaults.is_object()){
				why = "the parameters' defaults are not a JSON object";
				return false;
			}
		}
		if(!start_box(why)){
			why = "no box: "+why;
			return false;
		}
		log_i(MODULE, "The box is up (%s)", cs(m_box->engine_name()));

		// Authored: the save's, or the app's file the first time
		ss_ authored;
		bool first = false;
		if(!m_store->get("authored", authored)){
			authored = read_file(host.composition_path);
			if(authored.empty()){
				why = "no composition at "+host.composition_path;
				return false;
			}
			first = true;
		}
		json::json_error_t err;
		err.line = -1;
		const json::Value c = json::load_string(authored.c_str(), &err);
		if(!c.is_object()){
			why = "the composition is not a JSON object";
			return false;
		}
		if(!load_composition(c, why))
			return false;
		if(m_migrated)
			log_i(MODULE, "%zu bare type names made <author>/<name>",
					m_migrated);
		if(first || m_migrated || m_upgraded || !m_migrated_objects.empty())
			m_store->set("authored", authored_json().stringify());
		if(!m_migrated_objects.empty())
			m_runtime_dirty = true;
		clear_migrated();
		// The palette: every type of Kit's and of the app's that loads
		for(const ss_ &author : {ss_("kit"), m_author}){
			const ss_ dir = author_path(author);
			if(dir.empty())
				continue;
			for(const auto &n : interface::fs::list_directory(dir)){
				const size_t dot = n.name.rfind(".lua");
				// <name>.client.lua is a type's client part
				if(n.is_directory || dot == ss_::npos ||
						dot + 4 != n.name.size() ||
						n.name.find('.') != dot)
					continue;
				const ss_ type = author+"/"+n.name.substr(0, dot);
				ss_ twhy;
				if(load_type(type, twhy))
					m_palette.insert(type);
				else
					log_w(MODULE, "Not in the palette: %s", cs(twhy));
			}
		}
		// The types on each player entity ([KIT] stage 4d) are not placed
		for(const ss_ &t : sv_<ss_>(m_palette.begin(), m_palette.end()))
			if(m_types[t].player){
				m_player_types.push_back(t);
				m_palette.erase(t);
			} else if(m_types[t].world && m_host.world_scene.empty()){
				// [KIT] stage 4e: no World where the app has none
				m_palette.erase(t);
			}
		ss_ names;
		for(const ss_ &t : m_palette)
			names += (names.empty() ? "" : " ")+t;
		log_i(MODULE, "The palette: %s", cs(names));
		names.clear();
		for(const ss_ &t : m_player_types)
			names += (names.empty() ? "" : " ")+t;
		log_i(MODULE, "On each player: %s", cs(names));
		load_prefab_palette();
		if(!host_world(why))
			return false;

		// The session ([KIT] stage 4c): Stopped or Running. A save from
		// before has no row; it ran its components, so it is Running, its
		// start its types' defaults. A fresh save is Running too: an empty
		// composition Running is the same as Stopped, and a builder's Stop
		// is what stops a server
		ss_ runtime, session, start, discarded;
		const bool had_runtime = m_store->get("runtime", runtime);
		json::Value old_aside;
		if(m_store->get("session", session)){
			const json::Value sj = json::load_string(session.c_str());
			// Before [KIT] stage 4d the players' kept items were here
			old_aside = sj.get("aside");
			m_session.running = sj.get("running").is_true();
			m_session.by = jstr(sj, "by");
			for(const char *k : {"round", "restore"}){
				const json::Value &a = sj.get(k);
				for(unsigned i = 0; i < a.size(); i++)
					if(a.at(i).is_string())
						(ss_(k) == "round" ? m_session.round :
								m_session.restore).insert(a.at(i).as_string());
			}
		} else {
			m_session.running = true;
			log_i(MODULE, "%s", had_runtime ? "A save from before Play and "
					"Stop: Running, its start its types' defaults" :
					"A fresh save: Running");
			save_session();
		}
		if(m_store->get("start", start)){
			m_start = json::load_string(start.c_str());
			if(!m_start.is_object())
				m_start = json::object();
		}
		for(const ss_ &k : m_store->list("start:"))
			if(!m_session.restore.count(k))
				m_session.copied.insert(k);
		load_marks();
		if(m_store->get("discarded", discarded))
			discarded_from(json::load_string(discarded.c_str()));
		// Runtime: Running, the save's over each type's defaults; Stopped,
		// the start
		json::Value rt = had_runtime ?
				json::load_string(runtime.c_str()) : json::object();
		if(!rt.is_object())
			rt = json::object();
		// The players' entities ([KIT] stage 4d), and the round's own:
		// entities play made and removed
		load_players(rt, old_aside);
		if(m_session.running)
			load_round(rt);
		const json::Value &nid = rt.get("next_id");
		if(nid.is_number() && nid.as_number() > m_next_id &&
				nid.as_number() < 9e15)
			m_next_id = (uint64_t)nid.as_number();
		for(auto &p : m_entities){
			Entity &e = p.second;
			const json::Value &saved = rt.get(itos(e.id));
			for(size_t i = 0; i < e.comps.size(); i++){
				Instance &in = e.comps[i];
				if(!m_session.running){
					to_start(e, i);
					continue;
				}
				const json::Value &sd = m_types[in.type].decl.get("state");
				if(sd.is_object())
					for(json::Iterator it(sd); it; ++it)
						in.state.set(it.key(), (*it).get("default"));
				const json::Value &s = saved.at((unsigned)i);
				if(full_type(jstr(s, "type")) == in.type){
					runtime_from(in, s);
					// Before [KIT] stage 4d a timer's player was a name
					if(!player_id(in.due_by) && !player_of(in.due_by).empty())
						in.due_by = by_of(player_of(in.due_by));
					if(!in.disabled.empty())
						log_w(MODULE, "Entity %s's %s stays disabled: %s",
								cs(itos(e.id)), cs(in.type), cs(in.disabled));
				} else if(e.kind == "player"){
					// A player's type new to them: its defaults
				} else {
					// New: its start
					Run r;
					r.entity = e.id;
					r.comp = i;
					r.handler = "on_start";
					m_queue.push_back(r);
					m_runtime_dirty = true;
				}
			}
		}
		// Before [KIT] stage 4d Kit's counts were the runtime row's "items",
		// {name: {item: n}}: each player's own inventory now
		const json::Value &items = rt.get("items");
		if(m_session.running && items.is_object())
			for(json::Iterator it(items); it; ++it){
				Instance *in = own_inventory(ensure_player(it.key()));
				if(in && (*it).is_object()){
					in->state.set("items", (*it).deepcopy());
					log_i(MODULE, "%s's items %s are their own inventory's now",
							cs(it.key()), cs((*it).stringify()));
				}
				m_runtime_dirty = true;
			}

		// The nodes that carry the positional entities' shared state, and
		// the voxels they own
		for(auto &p : m_entities)
			if(p.second.has_pos)
				make_node(p.second);
		own_voxels();
		pick_provider();
		if(m_migrated)
			m_runtime_dirty = true;
		if(m_session.running)
			watch(true);
		log_i(MODULE, "The server is %s (by %s): %zu sections copied out, %zu "
				"to put back", m_session.running ? "Running" : "Stopped",
				m_session.by.empty() ? "no one" : cs(m_session.by),
				m_session.copied.size(), m_session.restore.size());
		m_hosted = true;
		size_t n = 0, es = 0;
		for(auto &p : m_entities)
			if(Module::authored(p.second)){
				es++;
				n += p.second.comps.size();
			}
		log_i(MODULE, "Hosted: %zu entities, %zu instances, %zu types%s; %zu "
				"players, %zu entities made in the round", es, n, m_types.size(),
				first ? " (the composition's first start)" : "",
				m_players.size(), m_entities.size() - es - m_players.size());
		return true;
	}

	// ---- The World ([KIT] stage 4e; world.h)

	// Kit's own material set's voxels, for an app that builds with them
	void register_voxels(interface::VoxelRegistry *reg)
	{
		world::MaterialSet set;
		ss_ why;
		if(!set.parse(json::load_string(read_file(m_server->get_module_path(
				MODULE)+"/materials.json").c_str()), why)){
			log_e(MODULE, "Kit's materials.json: %s", cs(why));
			return;
		}
		for(auto &v : set.voxels){
			interface::VoxelName n;
			n.block_name = v.first;
			if(reg->get(n))
				continue;
			const world::Material &m = v.second;
			interface::VoxelDefinition def;
			def.name = n;
			// The faces: +y, -y, then the sides
			for(int f = 0; f < 6; f++){
				auto &seg = def.textures[f];
				seg.resource_name = f == 0 ? m.top : f == 1 ? m.bottom : m.side;
				seg.total_segments = magic::IntVector2(1, 1);
				seg.select_segment = magic::IntVector2(0, 0);
			}
			if(m.kind == "water"){
				// Passive: no flow (user, 2026-10-30)
				def.edge_material_id = 10;
				def.translucent = true;
				def.transmits_light = true;
			} else if(m.kind == "plant"){
				// [KIT] stage 4f: Luanti's plantlike, two quads a cell
				// across crossed on its diagonals, both sides drawn, cut out
				// by the texture's alpha; walked through
				def.face_draw_type = interface::FaceDrawType::NEVER;
				def.edge_material_id = interface::EDGEMATERIALID_EMPTY;
				def.alpha_masked = true;
				def.transmits_light = true;
				def.shape_double_sided = true;
				const float r = 0.5f * 0.70710678f;
				for(int i = 0; i < 2; i++){
					const float az = i ? r : -r;
					const float pts[4][3] = {{-r, -0.5f, az}, {r, -0.5f, -az},
						{r, 0.5f, -az}, {-r, 0.5f, az}};
					const float uv[4][2] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};
					interface::VoxelQuad q;
					for(int k = 0; k < 4; k++){
						for(int c = 0; c < 3; c++)
							q.p[k][c] = pts[k][c];
						q.uv[k][0] = uv[k][0];
						q.uv[k][1] = uv[k][1];
					}
					def.shape.push_back(q);
				}
			} else {
				def.edge_material_id = interface::EDGEMATERIALID_GROUND;
				def.physically_solid = true;
				def.alpha_masked = m.kind == "leaves";
			}
			reg->add_voxel(def);
		}
	}

	// The World's parameters: the first World on the root's, over its
	// type's defaults (the app's among them); none: the defaults
	json::Value world_params()
	{
		json::Value out = json::object();
		ss_ type;
		const Instance *in = nullptr;
		for(auto &p : m_entities){
			if(p.second.parent != 1 || p.second.has_pos || in)
				continue;
			for(const Instance &i : p.second.comps)
				if(m_types.count(i.type) && m_types[i.type].world){
					in = &i;
					break;
				}
		}
		type = in ? in->type : ss_("kit/world");
		if(!m_types.count(type))
			return out;
		const json::Value &pd = m_types[type].decl.get("params");
		if(pd.is_object())
			for(json::Iterator it(pd); it; ++it){
				const json::Value &v = in ? in->params.get(it.key()) :
						json::Value();
				out.set(it.key(), v.is_undefined() ? (*it).get("default") : v);
			}
		return out;
	}

	// A builder is told: the World's refusals, seams and what waits for
	// the next start
	void warn(const ss_ &text)
	{
		log_w(MODULE, "World: %s", cs(text));
		sv_<size_t> to;
		for(auto &p : m_peers)
			if(can_edit(p.first))
				to.push_back(p.first);
		network::access(m_server, [&](network::Interface *inetwork){
			for(size_t peer : to)
				inetwork->send(peer, "kit:warning", "World: "+text);
		});
	}

	bool host_world(ss_ &why)
	{
		if(m_host.world_scene.empty())
			return true;
		auto si = m_host.scenes.find(m_host.world_scene);
		if(si == m_host.scenes.end()){
			why = "the World's scene "+m_host.world_scene+" is none of the app's";
			return false;
		}
		m_world_scene = si->second;
		const ss_ ms = m_host.materials.empty() ? read_file(
				m_server->get_module_path(MODULE)+"/materials.json") :
				m_host.materials;
		ss_ mwhy;
		if(!m_materials.parse(json::load_string(ms.c_str()), mwhy)){
			why = "the material set: "+mwhy;
			return false;
		}
		voxelworld::access(m_server, m_world_scene,
				[&](voxelworld::Instance *w){
			m_section_size = w->get_section_size_voxels().getX();
		});
		ss_ row;
		if(m_store->get("world", row)){
			const json::Value r = json::load_string(row.c_str());
			m_world_applied = r.get("params").deepcopy();
			// Parameters newer than the save ([KIT] stage 4f's caves and
			// decorations) at their defaults: not a change of the World (a
			// version 1 save makes neither)
			const json::Value pd = m_types.count("kit/world") ?
					m_types["kit/world"].decl.get("params") : json::Value();
			if(m_world_applied.is_object() && pd.is_object())
				for(json::Iterator it(pd); it; ++it)
					if(m_world_applied.get(it.key()).is_undefined())
						m_world_applied.set(it.key(), (*it).get("default"));
			world::Params was;
			was.from(m_world_applied);
			const int64_t v = json::jint(r, "version", 0);
			// Version 1 is kept: no caves or decorations ([KIT] stage 4f)
			m_saved_version = v;
			if(!was.finite() && !was.heightmap() && v != 1 &&
					v != world::generator_version(was.generator)){
				why = "the save's infinite world is the "+was.generator+
						" generator's version "+itos(v)+", this build's is "+
						itos(world::generator_version(was.generator));
				return false;
			}
			was.version = v == 1 ? 1 : world::VERSION;
			m_wp = was;
		}
		ss_ awhy;
		if(!apply_world(world_params(), "", true, awhy)){
			// The save's own World again, else nothing generated
			warn("not applied: "+awhy);
			if(m_world_applied.is_object() &&
					!apply_world(m_world_applied, "", true, awhy)){
				why = "the World: "+awhy;
				return false;
			}
		}
		return true;
	}

	// The World's parameters changed (an edit, an undo): applied
	void world_check(const ss_ &by)
	{
		if(!m_world_scene)
			return;
		const json::Value p = world_params();
		if(p.stringify() == m_world_applied.stringify())
			return;
		ss_ why;
		if(!apply_world(p, by, false, why))
			warn("not applied: "+why);
	}

	bool apply_world(const json::Value &params, const ss_ &by, bool first,
			ss_ &why)
	{
		world::Params p;
		p.from(params);
		auto bi = m_materials.biomes.find(p.biome);
		if(bi == m_materials.biomes.end()){
			why = "no biome \""+p.biome+"\" in the material set "+
					m_materials.name;
			return false;
		}
		const world::Biome &b = bi->second;
		// The roles the generator needs, each a voxel by its biome
		sv_<ss_> need;
		if(p.generator != "empty")
			need = {"top", "filler", "stone", "riverbed"};
		if(p.generator == "noise" || p.generator == "valleys" ||
				p.border == "water" || (p.generator == "flat" &&
				p.sea_level > p.level))
			need.push_back("water");
		if(p.border == "wall")
			need.push_back("stone");
		for(const ss_ &r : need)
			if(m_materials.resolve(b, r).empty()){
				why = "the "+p.generator+" generator needs the role "+r+
						", which biome "+p.biome+" has none of";
				return false;
			}
		if(p.heightmap() && !p.finite()){
			why = "a heightmap surface is finite only";
			return false;
		}
		if(!p.heightmap() && p.finite() && (p.width > world::MAX_FINITE_VOXELS
				|| p.depth > world::MAX_FINITE_VOXELS)){
			why = "a finite voxel map is "+itos(world::MAX_FINITE_VOXELS)+
					" cells a side at most";
			return false;
		}
		if(p.generator == "valleys" && !m_server->has_module("luanti_mapgen")){
			why = "the valleys generator needs builtin/luanti_mapgen, which "
					"this server has not";
			return false;
		}
		// What applies at the next start: the surface, a heightmap's size
		const bool had = m_world_applied.is_object();
		if(!first && had && (p.heightmap() != m_wp.heightmap() ||
				(p.heightmap() && (p.width != m_wp.width ||
				p.depth != m_wp.depth)))){
			const ss_ w = "the surface and a heightmap's size apply at the "
					"next start";
			if(m_world_pending != w)
				warn(w);
			m_world_pending = w;
			return true;
		}
		m_world_pending.clear();
		const bool again = had && params.stringify() !=
				m_world_applied.stringify();
		// A stage 4e save's version kept until the World changes
		p.version = first && !again && m_saved_version == 1 ? 1 :
				world::VERSION;
		world::Ids ids;
		ids.filler_depth = b.filler_depth;
		sv_<int> layers;
		voxelworld::access(m_server, m_world_scene,
				[&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			auto id = [&](const ss_ &name) -> interface::VoxelTypeId {
				interface::VoxelName n;
				n.block_name = name;
				const interface::VoxelDefinition *d = reg->get(n);
				if(!d && why.empty())
					why = "voxel "+name+" is not registered";
				return d ? d->id : 0;
			};
			ids.air = id("air");
			if(p.generator == "empty")
				return;
			// The roles, the decorations' structures ([KIT] stage 4f)
			world::resolve_biome(m_materials, b, id, ids.structs, ids);
			if(!ids.water)
				ids.water = ids.air;
		});
		if(!why.empty())
			return false;
		if(p.heightmap())
			for(const char *r : {"top", "stone", "riverbed"}){
				const ss_ v = m_materials.resolve(b, r);
				auto m = m_materials.voxels.find(v);
				if(m == m_materials.voxels.end() || m->second.layer < 0){
					why = v+" ("+r+") has no heightmap layer";
					return false;
				}
				layers.push_back(m->second.layer);
			}
		up_<world::Heights> h(new world::Heights());
		h->p = p;
		valleys_query(*h);
		// The map's ground (finite), or the origin's (infinite): its
		// lowest and highest, and its hash, which a check compares
		const int fx = p.finite() ? p.x0() : -32, fz = p.finite() ? p.z0() : -32;
		const int fw = p.finite() ? p.width : 64, fd = p.finite() ? p.depth : 64;
		sv_<int> tops;
		h->tops(fx, fz, fw, fd, tops);
		int lo = INT_MAX, hi = INT_MIN;
		for(int t : tops)
			lo = std::min(lo, t), hi = std::max(hi, t);
		if(p.generator == "empty")
			lo = hi = p.level - 1;
		uint32_t hash = world::hash_ints(tops);
		if(!p.heightmap())
			find_spawn(*h, ids);
		// The decorations over the same ground: how many, their hash
		size_t dn = 0;
		uint32_t dh = 0;
		if(p.with_decorations() && !p.heightmap())
			world::scatter_hash(p, ids, tops, fx, fz, fw, fd, dn, dh);
		// And its caves, sampled every fourth column each way: a check sees
		// that they are there and the same by the seed
		ss_ caves;
		if(p.with_caves() && !p.heightmap()){
			size_t n = 0, of = 0;
			for(int z = 0; z < fd; z += 4)
				for(int x = 0; x < fw; x += 4){
					const int t = tops[(size_t)z * fw + x];
					for(int y = t - world::CAVE_DEEP; y <= t - world::CAVE_TOP;
							y++, of++)
						n += world::cave_at(p.seed, fx + x, y, fz + z, t);
				}
			caves = " ("+itos(n)+" of "+itos(of)+" sampled cells)";
		}
		if(p.heightmap()){
			if(!apply_heightmap(p, *h, layers, ids, again, hash, why))
				return false;
			dn = m_decor.size();
			dh = decor_hash();
			set_world_generator(p, ids, nullptr, lo, hi);
		} else {
			set_world_generator(p, ids, std::move(h), lo, hi);
			if(again)
				regenerate(by);
		}
		m_wp = p;
		m_world_min = lo;
		m_world_max = hi;
		m_world_applied = params.deepcopy();
		json::Value row = json::object();
		row.set("params", m_world_applied);
		row.set("version", (int64_t)(world::generator_version(p.generator) ?
				p.version : 0));
		m_store->set("world", row.stringify());
		world_load_points();
		log_i(MODULE, "World%s: %s %s, seed %u, biome %s, %s, %s; ground %i "
				"to %i, heights hash %08x%s; version %i%s%s, decorations %zu "
				"(hash %08x)", by.empty() ? "" : cs(" by "+by),
				cs(p.generator), cs(p.size == "finite" ? itos(p.width)+"x"+
				itos(p.depth) : ss_("infinite")), p.seed, cs(p.biome),
				cs(p.heightmap() ? ss_("a heightmap") : "voxels"),
				cs("border "+p.border), lo, hi, hash,
				first ? (again ? ", the save's was another" : "") : "",
				p.version, p.with_caves() && !p.heightmap() ? ", caves" : "",
				cs(caves), dn, dh);
		if(first && !p.heightmap())
			voxelworld::access(m_server, m_world_scene,
					[&](voxelworld::Instance *w){
				size_t n = 0, edited = 0;
				for(const auto &s : w->section_stats())
					n++, edited += s.altered;
				log_i(MODULE, "World: the save holds %zu sections (%zu "
						"edited)", n, edited);
			});
		return true;
	}

	// The voxels' generator, and voxelworld told what to keep: a section
	// any write but the generator's changed is edited; an infinite world
	// saves only those
	void set_world_generator(const world::Params &p, const world::Ids &ids,
			up_<world::Heights> h, int lo, int hi)
	{
		world::Generator *g = new world::Generator();
		g->p = p;
		g->ids = ids;
		if(!h){
			// A heightmap's scene: no voxels
			h.reset(new world::Heights());
			h->p = p;
			h->p.generator = "empty";
		}
		g->h = std::move(h);
		g->max_top = hi;
		worldgen::access(m_server, [&](worldgen::Interface *i){
			if(!i->get_instance(m_world_scene))
				i->create_instance(m_world_scene);
			worldgen::Instance *wi = i->get_instance(m_world_scene);
			wi->set_generator(g);
			wi->enable();
		});
		voxelworld::access(m_server, m_world_scene,
				[&](voxelworld::Instance *w){
			w->set_writes_alter(true);
			w->set_save_unaltered(p.finite());
		});
	}

	// Every section nobody edited generated again (unloaded and forgotten:
	// the load points bring them back); the edited ones stay, and those
	// beside a regenerated one are the seams
	void regenerate(const ss_ &by)
	{
		size_t again = 0;
		std::set<std::tuple<int, int, int>> edited, redo;
		voxelworld::access(m_server, m_world_scene,
				[&](voxelworld::Instance *w){
			// The edited ones into the save, so its index says them all
			w->save();
			sv_<pv::Vector3DInt16> forget;
			for(const auto &s : w->section_stats()){
				const auto k = std::make_tuple(s.p.getX(), s.p.getY(), s.p.getZ());
				if(s.altered)
					edited.insert(k);
				else
					forget.push_back(s.p);
			}
			for(const pv::Vector3DInt16 &s : w->get_loaded_sections()){
				const auto k = std::make_tuple(s.getX(), s.getY(), s.getZ());
				if(edited.count(k))
					continue;
				w->unload_section(s);
				forget.push_back(s);
			}
			for(const pv::Vector3DInt16 &s : forget)
				redo.insert(std::make_tuple(s.getX(), s.getY(), s.getZ()));
			w->forget_sections(forget);
			again = redo.size();
		});
		ss_ seams;
		size_t n = 0;
		for(const auto &e : edited){
			bool beside = false;
			for(int dx = -1; dx <= 1 && !beside; dx++)
			for(int dy = -1; dy <= 1 && !beside; dy++)
			for(int dz = -1; dz <= 1 && !beside; dz++)
				beside = redo.count(std::make_tuple(std::get<0>(e) + dx,
						std::get<1>(e) + dy, std::get<2>(e) + dz)) > 0;
			if(!beside)
				continue;
			if(n++ < 8)
				seams += ss_(seams.empty() ? "" : " ")+"("+
						itos(std::get<0>(e))+","+itos(std::get<1>(e))+","+
						itos(std::get<2>(e))+")";
		}
		log_i(MODULE, "World%s: %zu sections generated again, %zu edited kept",
				by.empty() ? "" : cs(" by "+by), again, edited.size());
		if(n)
			warn(itos(n)+" edited sections kept, seams where they meet the "
					"new ground: "+seams+(n > 8 ? " ..." : ""));
	}

	// A heightmap surface: builtin/heightmap's map in the World's scene,
	// generated from the same heights unless the save had it as applied;
	// its grass, rock and sand the biome's top, stone and riverbed layers
	bool apply_heightmap(const world::Params &p, world::Heights &h,
			const sv_<int> &layers, const world::Ids &ids, bool again,
			uint32_t &hash, ss_ &why)
	{
		bool generated = false;
		heightmap::Size size;
		size.chunks_x = (p.width + 63) / 64;
		size.chunks_z = (p.depth + 63) / 64;
		size.chunk_size = 64;
		size.cell_size = 1;
		size.base_y = -100;
		size.materials = 5;
		heightmap::access(m_server, [&](heightmap::Interface *ih){
			heightmap::Instance *map = ih->get_instance(m_world_scene);
			bool loaded = false;
			if(!map){
				map = ih->create_instance(m_world_scene, size);
				loaded = map->set_save(m_host.save, "world");
			}
			if(!loaded || again){
				generated = true;
				heightmap::GenerateParams gp;
				gp.seed = p.seed;
				// A voxel column's top cell is centred on its whole number
				gp.height_fn = [&](float x, float z){ return h.at(x, z) + 0.5f; };
				gp.sand_below = p.sea_level + 1.0f;
				map->generate(gp);
				if(layers != sv_<int>{0, 1, 2})
					for(int z = 0; z < map->samples_z(); z++)
					for(int x = 0; x < map->samples_x(); x++){
						const heightmap::Weights w = map->get_weights(x, z);
						heightmap::Weights o{};
						for(int k = 0; k < 3; k++)
							o[layers[k]] = (uint8_t)std::min(255,
									o[layers[k]] + w[k]);
						map->set_weights(x, z, o);
					}
			}
			hash = map->content_hash();
		});
		decor_start(p, ids, generated);
		return why.empty();
	}

	// ---- [KIT] stage 4f: decorations on a heightmap surface, as voxel
	// objects ([VOXEL_OBJECTS]): a model a structure (its voxels Kit's),
	// an object a decoration, the list saved in the row "decor"

	// The scene's voxel objects, made at the first need
	voxel_objects::Instance* decor_instance()
	{
		voxel_objects::Instance *vo = nullptr;
		voxel_objects::access(m_server, [&](voxel_objects::Interface *iv){
			vo = iv->get_instance(m_world_scene);
			if(!vo)
				vo = iv->create_instance(m_world_scene);
		});
		return vo;
	}

	// A structure's model, made once from the material set's voxels
	bool decor_model(const ss_ &name)
	{
		if(m_decor_models.count(name))
			return true;
		auto si = m_materials.structures.find(name);
		if(si == m_materials.structures.end())
			return false;
		const world::Structure &st = si->second;
		sv_<interface::VoxelTypeId> ids;
		voxelworld::access(m_server, m_world_scene, [&](voxelworld::Instance *w){
			for(const ss_ &c : st.cells){
				interface::VoxelName n;
				n.block_name = c;
				const interface::VoxelDefinition *d = c.empty() ? nullptr :
						w->get_voxel_reg()->get(n);
				ids.push_back(d ? d->id : 0);
			}
		});
		voxel_objects::access(m_server, m_world_scene,
				[&](voxel_objects::Instance *vo){
			voxel_objects::Model *m = vo->get_model("kit_"+name);
			if(!m)
				m = vo->create_model("kit_"+name, st.sx, st.sy, st.sz);
			for(int y = 0; y < st.sy; y++)
			for(int z = 0; z < st.sz; z++)
			for(int x = 0; x < st.sx; x++)
				m->set_voxel(x, y, z, ids[((size_t)y * st.sz + z) * st.sx + x]);
		});
		m_decor_models.insert(name);
		return true;
	}

	// A decoration's object: its structure's origin cell on (x, y, z),
	// turned by yaw about it
	void decor_object(Decor &d)
	{
		if(!decor_model(d.structure))
			return;
		const world::Structure &st = m_materials.structures[d.structure];
		const magic::Quaternion q(0, d.yaw, 0);
		const magic::Vector3 pos = magic::Vector3(d.x, d.y, d.z) -
				q * magic::Vector3(st.ox + 0.5f, (float)st.oy, st.oz + 0.5f);
		voxel_objects::access(m_server, m_world_scene,
				[&](voxel_objects::Instance *vo){
			if(d.node)
				vo->remove_object(d.node);
			d.node = vo->create_object("kit_"+d.structure, pos, q);
		});
	}

	// Where a decoration stands on the map: a little into the ground, so
	// a slope shows no gap under it
	float decor_y(heightmap::Instance *map, float x, float z)
	{
		return map->height_at(x, z) - 0.35f;
	}

	uint64_t add_decor(const ss_ &structure, float x, float y, float z,
			float yaw)
	{
		Decor d;
		d.structure = structure;
		d.x = x, d.y = y, d.z = z, d.yaw = yaw;
		const uint64_t id = m_next_decor++;
		decor_object(d);
		m_decor[id] = d;
		m_decor_dirty = true;
		return id;
	}

	void remove_decor(uint64_t id)
	{
		auto it = m_decor.find(id);
		if(it == m_decor.end())
			return;
		if(it->second.node)
			voxel_objects::access(m_server, m_world_scene,
					[&](voxel_objects::Instance *vo){
				vo->remove_object(it->second.node);
			});
		m_decor.erase(it);
		m_decor_dirty = true;
	}

	void save_decor()
	{
		if(!m_decor_dirty)
			return;
		m_decor_dirty = false;
		json::Value a = json::array();
		for(auto &d : m_decor){
			json::Value r = json::array();
			r.append(d.second.structure);
			for(float v : {d.second.x, d.second.y, d.second.z, d.second.yaw})
				r.append((double)v);
			a.append(r);
		}
		m_store->set("decor", a.stringify());
	}

	// FNV-1a over the decorations, in their order: their structures' names
	// and their places in sixteenths
	uint32_t decor_hash()
	{
		uint32_t h = 2166136261u;
		auto add = [&](uint8_t b){ h ^= b; h *= 16777619u; };
		for(auto &d : m_decor){
			for(char c : d.second.structure)
				add((uint8_t)c);
			for(float v : {d.second.x, d.second.y, d.second.z, d.second.yaw}){
				const int32_t i = (int32_t)std::floor(v * 16 + 0.5f);
				for(int k = 0; k < 4; k++)
					add((uint8_t)(i >> (k * 8)));
			}
		}
		return h;
	}

	// The decoration a heightmap's sample (x, z) carries by the biome's
	// scatter (a structure more than a cell, on dry ground not too steep):
	// "" none
	ss_ decor_pick(heightmap::Instance *map, const world::BiomeIds &b,
			const sv_<world::StructIds> &structs, uint32_t seed, int x, int z,
			double mult, float &yaw)
	{
		const float h = map->get_height(x, z);
		float steep = 0;
		for(int k = 0; k < 4; k++){
			const int nx = x + (k == 0) - (k == 1), nz = z + (k == 2) - (k == 3);
			if(nx >= 0 && nz >= 0 && nx < map->samples_x() &&
					nz < map->samples_z())
				steep = std::max(steep, std::fabs(map->get_height(nx, nz) - h));
		}
		int turns = 0;
		const int k = world::pick_surface(b, seed, x, z, (int)std::floor(h),
				m_wp.sea_level, mult, turns);
		if(k < 0 || b.decors[k].on != 't' || steep > 0.8f)
			return "";
		const world::StructIds &s = structs[b.decors[k].s];
		if(s.sx * s.sy * s.sz <= 1)
			return "";
		// Any angle: an object turns freely
		yaw = (float)(world::hash_at(seed, x, 1, z, 99) % 360);
		return s.name;
	}

	// The decorations at a start: generated with a generated map (the
	// biome's scatter over its samples), else the save's
	void decor_start(const world::Params &p, const world::Ids &ids,
			bool generated)
	{
		for(auto &d : m_decor)
			if(d.second.node)
				voxel_objects::access(m_server, m_world_scene,
						[&](voxel_objects::Instance *vo){
					vo->remove_object(d.second.node);
				});
		m_decor.clear();
		ss_ row;
		const bool saved = !generated && m_store->get("decor", row);
		if(!saved && !p.with_decorations()){
			m_decor_dirty = true;
			save_decor();
			return;
		}
		if(!decor_instance())
			return;
		struct New { ss_ s; float x, y, z, yaw; };
		sv_<New> made;
		if(saved){
			const json::Value a = json::load_string(row.c_str());
			for(unsigned i = 0; a.is_array() && i < a.size(); i++){
				const json::Value &r = a.at(i);
				if(r.is_array() && r.size() == 5 && r.at(0).is_string() &&
						m_materials.structures.count(r.at(0).as_string()))
					made.push_back({r.at(0).as_string(),
						(float)r.at(1).as_number(), (float)r.at(2).as_number(),
						(float)r.at(3).as_number(), (float)r.at(4).as_number()});
			}
		} else {
			heightmap::access(m_server, m_world_scene,
					[&](heightmap::Instance *map){
				for(int z = 0; z < map->samples_z(); z++)
				for(int x = 0; x < map->samples_x(); x++){
					// Not on the spawn (world_spawn: the middle)
					if(std::abs(x - map->samples_x() / 2) <= 3 &&
							std::abs(z - map->samples_z() / 2) <= 3)
						continue;
					float yaw = 0;
					const ss_ s = decor_pick(map, ids, ids.structs, p.seed, x, z,
							1, yaw);
					if(!s.empty())
						made.push_back({s, (float)x, decor_y(map, (float)x,
								(float)z), (float)z, yaw});
				}
			});
		}
		for(const New &n : made)
			add_decor(n.s, n.x, n.y, n.z, n.yaw);
		m_decor_dirty = true;
		save_decor();
		log_i(MODULE, "World: %zu decorations on the heightmap (%s)",
				m_decor.size(), saved ? "the save's" : "generated");
	}

	// The decorations over a rectangle of samples back on the ground
	void reseat_decor(int x0, int z0, int x1, int z1)
	{
		sv_<uint64_t> moved;
		heightmap::access(m_server, m_world_scene, [&](heightmap::Instance *map){
			for(auto &d : m_decor){
				if(d.second.x < x0 - 0.5f || d.second.x > x1 + 0.5f ||
						d.second.z < z0 - 0.5f || d.second.z > z1 + 0.5f)
					continue;
				const float y = decor_y(map, d.second.x, d.second.z);
				if(std::fabs(y - d.second.y) < 0.01f)
					continue;
				d.second.y = y;
				moved.push_back(d.first);
			}
		});
		for(uint64_t id : moved)
			decor_object(m_decor[id]);
		if(!moved.empty())
			m_decor_dirty = true;
	}

	// ---- [KIT] stage 4f: the terrain brushes (api.h's "terrain" op)

	// Kit's material set as the brushes see a world's voxels: every biome's
	// roles and decorations as ids, the kinds of cells
	bool make_brush(voxelworld::Instance *w, world::Brush &br, ss_ &why)
	{
		interface::VoxelRegistry *reg = w->get_voxel_reg();
		auto id = [&](const ss_ &name) -> interface::VoxelTypeId {
			interface::VoxelName n;
			n.block_name = name;
			const interface::VoxelDefinition *d = reg->get(n);
			if(!d && why.empty())
				why = "voxel "+name+" is not registered";
			return d ? d->id : 0;
		};
		br.p = m_wp;
		br.air = id("air");
		for(auto &b : m_materials.biomes){
			world::BiomeIds bi;
			world::resolve_biome(m_materials, b.second, id, br.structs, bi);
			br.biomes.push_back(std::make_pair(b.first, bi));
			for(interface::VoxelTypeId v : {bi.top, bi.filler, bi.stone,
					bi.riverbed, bi.cave_floor, bi.cave_wall})
				if(v)
					br.ground.insert(v);
			for(interface::VoxelTypeId v : {bi.top, bi.filler, bi.riverbed})
				if(v)
					br.surface.insert(v);
			if(bi.water){
				br.water.insert(bi.water);
				br.soft.insert(bi.water);
			}
			if(b.first == m_wp.biome)
				br.world = bi;
		}
		br.soft.insert(br.air);
		for(auto &v : m_materials.voxels)
			if(v.second.kind == "plant")
				br.soft.insert(id(v.first));
		return why.empty();
	}

	// A column's cells from over its top down, as runs: "kit/grass 3,
	// kit/dirt 0..2, kit/stone -4..-1" (what a check reads)
	ss_ describe_column(voxelworld::Instance *w, world::Brush &br, int x,
			int z, int hi, int lo)
	{
		ss_ out, run;
		int from = 0, to = 0;
		auto flush = [&](){
			if(run.empty())
				return;
			out += (out.empty() ? "" : ", ")+run+" "+(from == to ? itos(from) :
					itos(to)+".."+itos(from));
		};
		for(int y = hi; y >= lo; y--){
			interface::VoxelTypeId v = 0;
			ss_ name = "?";
			if(br.get(x, y, z, v)){
				const interface::VoxelDefinition *d = w->get_voxel_reg()->get(v);
				name = d ? d->name.block_name : "?";
			}
			if(name == run){
				to = y;
				continue;
			}
			flush();
			run = name, from = to = y;
		}
		flush();
		return out;
	}

	// One dab of a stroke (or a fill, or a look at a column). Everything
	// in it is checked here; the client is trusted with nothing
	void terrain(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		if(!m_world_scene)
			return refuse("the app has no World");
		const ss_ tool = jstr(j, "tool");
		static const std::set<ss_> TOOLS = {"raise", "lower", "smooth",
			"flatten", "paint", "fill", "decorate", "column"};
		if(!TOOLS.count(tool))
			return refuse("tool: raise, lower, smooth, flatten, paint, fill, "
					"decorate or column");
		auto num = [&](const char *k, double lo, double hi, double def,
				double &out) -> bool {
			const json::Value &v = j.get(k);
			if(v.is_undefined()){
				out = def;
				return true;
			}
			if(!v.is_number() || !std::isfinite(v.as_number()) ||
					v.as_number() < lo || v.as_number() > hi){
				refuse(ss_(k)+": a number "+ftos(lo)+" to "+ftos(hi));
				return false;
			}
			out = v.as_number();
			return true;
		};
		double x, y, z, x1, z1, size, strength, level, stroke;
		if(!num("x", -MAX_COORD, MAX_COORD, NAN, x) ||
				!num("y", -MAX_COORD, MAX_COORD, NAN, y) ||
				!num("z", -MAX_COORD, MAX_COORD, NAN, z) ||
				!num("x1", -MAX_COORD, MAX_COORD, 0, x1) ||
				!num("z1", -MAX_COORD, MAX_COORD, 0, z1) ||
				!num("size", 1, MAX_BRUSH, 3, size) ||
				!num("strength", 1, 5, 2, strength) ||
				!num("level", -MAX_COORD, MAX_COORD, 0, level) ||
				!num("stroke", 0, 9e15, -1, stroke))
			return;
		if(std::isnan(x) || std::isnan(y) || std::isnan(z))
			return refuse("x, y, z: the point");
		if(stroke >= 0 && stroke != std::floor(stroke))
			return refuse("stroke: a whole number");
		if(tool == "fill" && (std::fabs(x1 - x) >= MAX_FILL ||
				std::fabs(z1 - z) >= MAX_FILL))
			return refuse("fill: "+itos(MAX_FILL)+" cells a side at most");
		ss_ biome = jstr(j, "biome");
		if(biome.empty())
			biome = m_wp.biome;
		if(!m_materials.biomes.count(biome) && !(tool == "fill" &&
				biome == "water"))
			return refuse("biome: one of the material set's"+ss_(tool ==
					"fill" ? ", or water" : ""));
		// The editor's undo: a stroke's dabs one change
		Change *c = nullptr;
		if(tool != "column"){
			std::deque<Change> &u = m_undo[p.name];
			if(stroke < 0 || u.empty() || u.back().stroke != (int64_t)stroke){
				Change nc;
				nc.stroke = stroke < 0 ? -2 : (int64_t)stroke;
				u.push_back(nc);
				while(u.size() > UNDO_MAX)
					u.pop_front();
			}
			c = &u.back();
		}
		const int r = (int)std::floor(size + 0.5);
		const double s = std::floor(strength + 0.5);
		ss_ what, why;
		if(m_wp.heightmap())
			what = terrain_heightmap(p, tool, x, y, z, x1, z1, r, s, level,
					biome, c, why);
		else
			what = terrain_voxels(p, tool, x, y, z, x1, z1, r, s, level, biome,
					c, why);
		if(!why.empty())
			return refuse(why);
		save_decor();
		const size_t undo = m_undo[p.name].size();
		log_i(MODULE, "Terrain by %s: %s%s", cs(p.name), cs(what),
				c ? cs(", stroke "+itos((int64_t)stroke)+" ("+itos(undo)+
				" to undo)") : "");
		json::Value a = json::object();
		a.set("tool", tool);
		a.set("stroke", stroke);
		a.set("undo", (int64_t)undo);
		a.set("what", what);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:terrain", a.stringify());
		});
	}

	ss_ terrain_voxels(Peer &p, const ss_ &tool, double fx, double fy,
			double fz, double fx1, double fz1, int r, double s, double level,
			const ss_ &biome, Change *c, ss_ &why)
	{
		const int cx = (int)std::floor(fx + 0.5), cy = (int)std::floor(fy + 0.5),
				cz = (int)std::floor(fz + 0.5);
		const int L = (int)std::floor(level + 0.5);
		ss_ what;
		voxelworld::access(m_server, m_world_scene,
				[&](voxelworld::Instance *w){
			world::Brush br;
			if(!make_brush(w, br, why))
				return;
			br.get = [&](int x, int y, int z, interface::VoxelTypeId &v){
				uint32_t id = 0;
				if(!voxel_id(w, pv::Vector3DInt32(x, y, z), id))
					return false;
				v = id;
				return true;
			};
			br.set = [&](int x, int y, int z, interface::VoxelTypeId v){
				const pv::Vector3DInt32 q(x, y, z);
				uint32_t old = 0;
				if(!voxel_id(w, q, old))
					return;
				if(c)
					c->cells.emplace(std::make_tuple(x, y, z), old);
				set_id(w, q, v);
				mark(w, m_world_scene, q, 'k', p.name);
			};
			const world::BiomeIds *sel = &br.world;
			for(auto &b : br.biomes)
				if(b.first == biome)
					sel = &b.second;
			// The columns in the dab's circle, their tops near the point
			const int hi = cy + r + 6, lo = cy - r - 24;
			size_t columns = 0;
			std::map<std::pair<int, int>, int> tops;
			auto top = [&](int x, int z, int &t) -> bool {
				auto it = tops.find(std::make_pair(x, z));
				if(it != tops.end()){
					t = it->second;
					return it->second != INT_MIN;
				}
				const bool ok = br.top_of(x, z, hi, lo, t);
				tops[std::make_pair(x, z)] = ok ? t : INT_MIN;
				return ok;
			};
			auto circle = [&](std::function<void(int, int, double)> f){
				for(int dz = -r; dz <= r; dz++)
				for(int dx = -r; dx <= r; dx++){
					const double d = std::sqrt((double)(dx * dx + dz * dz));
					if(d <= r + 0.01)
						f(cx + dx, cz + dz, d);
				}
			};
			if(tool == "raise" || tool == "lower"){
				const int sign = tool == "raise" ? 1 : -1;
				circle([&](int x, int z, double d){
					int t;
					if(!top(x, z, t))
						return;
					const double f = 1 - (d / (r + 1)) * (d / (r + 1));
					const int a = std::max(1, (int)std::floor(s * f + 0.5));
					br.set_column(x, z, t, t + sign * a, br.biome_of(x, z, t));
					columns++;
				});
			} else if(tool == "smooth"){
				const double k = std::min(1.0, 0.3 + 0.2 * s);
				std::map<std::pair<int, int>, int> next;
				circle([&](int x, int z, double){
					int t;
					if(!top(x, z, t))
						return;
					double sum = 0;
					int n = 0;
					for(int dz = -2; dz <= 2; dz++)
					for(int dx = -2; dx <= 2; dx++){
						int u;
						if(top(x + dx, z + dz, u))
							sum += u, n++;
					}
					next[std::make_pair(x, z)] = t + (int)std::floor(
							(sum / n - t) * k + 0.5);
				});
				for(auto &q : next){
					const int t = tops[q.first];
					if(q.second != t)
						br.set_column(q.first.first, q.first.second, t, q.second,
								br.biome_of(q.first.first, q.first.second, t));
					columns++;
				}
			} else if(tool == "flatten"){
				const int step = std::max(1, (int)s);
				circle([&](int x, int z, double){
					int t;
					if(!top(x, z, t))
						return;
					const int t2 = t + std::max(-step, std::min(step, L - t));
					if(t2 != t)
						br.set_column(x, z, t, t2, br.biome_of(x, z, t));
					columns++;
				});
			} else if(tool == "paint"){
				circle([&](int x, int z, double){
					int t;
					if(!top(x, z, t))
						return;
					br.set_column(x, z, t, t, *sel);
					columns++;
				});
			} else if(tool == "decorate"){
				// In a cave (ground over the point): its floor's and wall's
				// decorations round the point; else the surface's
				bool roofed = false;
				for(int y = cy + 2; y <= cy + 32 && !roofed; y++)
					roofed = br.is_ground(cx, y, cz);
				const double mult = 2 * s;
				const uint32_t seed = m_wp.seed ^ world::BRUSH_SALT;
				if(roofed){
					for(int dy = -r; dy <= r; dy++)
					for(int dz = -r; dz <= r; dz++)
					for(int dx = -r; dx <= r; dx++){
						if(dx * dx + dy * dy + dz * dz > r * r)
							continue;
						const int x = cx + dx, y = cy + dy, z = cz + dz;
						interface::VoxelTypeId v = 0, up = 0;
						if(!br.get(x, y, z, v) || !br.ground.count(v) ||
								!br.get(x, y + 1, z, up))
							continue;
						if(up == br.air){
							const interface::VoxelTypeId put = world::pick_cave(
									*sel, br.structs, seed, x, y + 1, z, 'c', mult);
							if(put)
								br.put(x, y + 1, z, put);
							continue;
						}
						bool open = false;
						for(int k = 0; k < 5 && !open; k++){
							interface::VoxelTypeId nv = 0;
							open = br.get(x + (k == 0) - (k == 1), y - (k == 4),
									z + (k == 2) - (k == 3), nv) && nv == br.air;
						}
						if(open){
							const interface::VoxelTypeId put = world::pick_cave(
									*sel, br.structs, seed, x, y, z, 'v', mult);
							if(put)
								br.put(x, y, z, put);
						}
					}
					what = "decorate (a cave)";
				} else {
					circle([&](int x, int z, double){
						int t, turns = 0;
						if(!top(x, z, t))
							return;
						columns++;
						const int k = world::pick_surface(*sel, seed, x, z, t,
								m_wp.sea_level, mult, turns);
						if(k >= 0)
							br.place(br.structs[sel->decors[k].s], turns, x, t + 1,
									z, sel->decors[k].on == 'w');
					});
				}
			} else if(tool == "fill"){
				const int x0 = std::min(cx, (int)std::floor(fx1 + 0.5)),
						x1 = std::max(cx, (int)std::floor(fx1 + 0.5)),
						z0 = std::min(cz, (int)std::floor(fz1 + 0.5)),
						z1 = std::max(cz, (int)std::floor(fz1 + 0.5));
				interface::VoxelTypeId water = br.world.water;
				for(auto &b : br.biomes)
					if(!water)
						water = b.second.water;
				if(biome == "water" && !water){
					why = "no biome of the material set has water";
					return;
				}
				for(int z = z0; z <= z1; z++)
				for(int x = x0; x <= x1; x++){
					int t;
					if(!br.top_of(x, z, L + 8, L - MAX_FILL, t) || t >= L)
						continue;
					columns++;
					if(biome != "water"){
						br.set_column(x, z, t, L, *sel);
						continue;
					}
					for(int y = t + 1; y <= L; y++){
						interface::VoxelTypeId v = 0;
						if(br.get(x, y, z, v) && br.soft.count(v) &&
								!br.water.count(v))
							br.put(x, y, z, water);
					}
				}
				what = "fill "+biome+" ("+itos(x0)+","+itos(z0)+") to ("+
						itos(x1)+","+itos(z1)+") up to "+itos(L)+": "+
						itos(columns)+" columns, "+itos(br.written)+" cells";
			}
			int t;
			const bool has = br.top_of(cx, cz, hi, lo, t);
			if(what.empty() || tool == "decorate")
				what = (what.empty() ? tool : what)+" at ("+itos(cx)+","+
						itos(cy)+","+itos(cz)+") size "+itos(r)+" strength "+
						itos((int)s)+": "+itos(columns)+" columns, "+
						itos(br.written)+" cells";
			what += "; column ("+itos(cx)+","+itos(cz)+"): "+(has ?
					describe_column(w, br, cx, cz, t + 2, t - 6) : ss_("none"));
		});
		return what;
	}

	// The heightmap's layer each biome role's voxel is (-1: none)
	int layer_of(const world::Biome &b, const char *role)
	{
		auto m = m_materials.voxels.find(m_materials.resolve(b, role));
		return m == m_materials.voxels.end() ? -1 : m->second.layer;
	}

	ss_ terrain_heightmap(Peer &p, const ss_ &tool, double fx, double fy,
			double fz, double fx1, double fz1, int r, double s, double level,
			const ss_ &biome, Change *c, ss_ &why)
	{
		(void)p;
		(void)fy;
		if(tool == "fill" && biome == "water"){
			why = "no water on a heightmap yet";
			return "";
		}
		const int cx = (int)std::floor(fx + 0.5), cz = (int)std::floor(fz + 0.5);
		const world::Biome &sel = m_materials.biomes[biome];
		ss_ what;
		size_t samples = 0, added = 0;
		int bx0 = cx - r - 1, bz0 = cz - r - 1, bx1 = cx + r + 1,
				bz1 = cz + r + 1;
		sv_<std::pair<ss_, std::array<float, 4>>> decorate;
		world::BiomeIds bi;
		sv_<world::StructIds> structs;
		if(tool == "decorate")
			voxelworld::access(m_server, m_world_scene,
					[&](voxelworld::Instance *w){
				world::resolve_biome(m_materials, sel,
						[&](const ss_ &name) -> interface::VoxelTypeId {
					interface::VoxelName n;
					n.block_name = name;
					const interface::VoxelDefinition *d =
							w->get_voxel_reg()->get(n);
					return d ? d->id : 0;
				}, structs, bi);
			});
		heightmap::access(m_server, m_world_scene, [&](heightmap::Instance *map){
			const int sx = map->samples_x(), sz = map->samples_z();
			auto in = [&](int x, int z){
				return x >= 0 && z >= 0 && x < sx && z < sz;
			};
			auto keep = [&](int x, int z){
				if(c)
					c->samples.emplace(std::make_pair(x, z), std::make_pair(
							map->get_height(x, z), map->get_weights(x, z)));
			};
			auto one_hot = [](int layer){
				heightmap::Weights w{};
				if(layer >= 0 && layer < heightmap::MAX_MATERIALS)
					w[layer] = 255;
				return w;
			};
			// The biome a sample is by its strongest layer (a biome whose
			// top is it), else the World's
			auto biome_of = [&](int x, int z) -> const world::Biome& {
				const heightmap::Weights w = map->get_weights(x, z);
				int best = 0;
				for(int k = 1; k < heightmap::MAX_MATERIALS; k++)
					if(w[k] > w[best])
						best = k;
				for(auto &b : m_materials.biomes)
					if(layer_of(b.second, "top") == best)
						return b.second;
				return m_materials.biomes[m_wp.biome];
			};
			// A sample's layer as its ground is: stone where steep, the
			// riverbed under the sea, else its biome's top
			auto relayer = [&](int x, int z, const world::Biome &b){
				const float h = map->get_height(x, z);
				float steep = 0;
				for(int k = 0; k < 4; k++){
					const int nx = x + (k == 0) - (k == 1),
							nz = z + (k == 2) - (k == 3);
					if(in(nx, nz))
						steep = std::max(steep, std::fabs(map->get_height(nx, nz) -
								h));
				}
				const int layer = steep > HM_ROCK_SLOPE ? layer_of(b, "stone") :
						h < m_wp.sea_level + 0.5f ? layer_of(b, "riverbed") :
						layer_of(b, "top");
				const heightmap::Weights w = one_hot(layer);
				if(w != map->get_weights(x, z))
					map->set_weights(x, z, w);
			};
			std::map<std::pair<int, int>, float> next;
			auto circle = [&](std::function<void(int, int, double)> f){
				for(int dz = -r; dz <= r; dz++)
				for(int dx = -r; dx <= r; dx++){
					const double d = std::sqrt((double)(dx * dx + dz * dz));
					if(d <= r + 0.01 && in(cx + dx, cz + dz))
						f(cx + dx, cz + dz, d);
				}
			};
			const float step = (float)(HM_STEP * s);
			if(tool == "raise" || tool == "lower"){
				circle([&](int x, int z, double d){
					const double f = 1 - (d / (r + 1)) * (d / (r + 1));
					next[std::make_pair(x, z)] = map->get_height(x, z) +
							(tool == "raise" ? 1 : -1) * step * (float)f;
				});
			} else if(tool == "smooth"){
				const float k = (float)std::min(1.0, 0.25 * s);
				circle([&](int x, int z, double){
					float sum = 0;
					int n = 0;
					for(int dz = -1; dz <= 1; dz++)
					for(int dx = -1; dx <= 1; dx++)
						if(in(x + dx, z + dz))
							sum += map->get_height(x + dx, z + dz), n++;
					const float h = map->get_height(x, z);
					next[std::make_pair(x, z)] = h + (sum / n - h) * k;
				});
			} else if(tool == "flatten"){
				circle([&](int x, int z, double){
					const float h = map->get_height(x, z);
					next[std::make_pair(x, z)] = h + std::max(-step,
							std::min(step, (float)level - h));
				});
			} else if(tool == "fill"){
				const int x0 = std::max(0, std::min(cx, (int)std::floor(fx1 + 0.5))),
						x1 = std::min(sx - 1, std::max(cx, (int)std::floor(fx1 + 0.5))),
						z0 = std::max(0, std::min(cz, (int)std::floor(fz1 + 0.5))),
						z1 = std::min(sz - 1, std::max(cz, (int)std::floor(fz1 + 0.5)));
				for(int z = z0; z <= z1; z++)
					for(int x = x0; x <= x1; x++)
						if(map->get_height(x, z) < level)
							next[std::make_pair(x, z)] = (float)level;
				bx0 = x0 - 1, bz0 = z0 - 1, bx1 = x1 + 1, bz1 = z1 + 1;
				what = "fill "+biome+" ("+itos(x0)+","+itos(z0)+") to ("+
						itos(x1)+","+itos(z1)+") up to "+ftos(level);
			} else if(tool == "paint"){
				circle([&](int x, int z, double){
					keep(x, z);
					relayer(x, z, sel);
					samples++;
				});
			} else if(tool == "decorate"){
				circle([&](int x, int z, double){
					samples++;
					float yaw = 0;
					const ss_ st = decor_pick(map, bi, structs, m_wp.seed ^
							world::BRUSH_SALT, x, z, 2 * s, yaw);
					if(st.empty())
						return;
					for(auto &d : m_decor)
						if(std::fabs(d.second.x - x) < 1.5f &&
								std::fabs(d.second.z - z) < 1.5f)
							return;
					decorate.push_back(std::make_pair(st, std::array<float, 4>{{
							(float)x, decor_y(map, (float)x, (float)z), (float)z,
							yaw}}));
				});
			}
			// The heights, then the layers round them
			for(auto &q : next){
				keep(q.first.first, q.first.second);
				map->set_height(q.first.first, q.first.second, q.second);
				samples++;
			}
			std::set<std::pair<int, int>> around;
			for(auto &q : next)
				for(int dz = -1; dz <= 1; dz++)
				for(int dx = -1; dx <= 1; dx++)
					if(in(q.first.first + dx, q.first.second + dz))
						around.insert(std::make_pair(q.first.first + dx,
								q.first.second + dz));
			for(auto &q : around){
				keep(q.first, q.second);
				relayer(q.first, q.second, tool == "fill" ? sel :
						biome_of(q.first, q.second));
			}
			if(what.empty())
				what = tool+" at ("+itos(cx)+","+itos(cz)+") size "+itos(r)+
						" strength "+itos((int)s);
			if(in(cx, cz)){
				const heightmap::Weights w = map->get_weights(cx, cz);
				int best = 0;
				for(int k = 1; k < heightmap::MAX_MATERIALS; k++)
					if(w[k] > w[best])
						best = k;
				what += " on the heightmap: "+itos(samples)+" samples; ("+
						itos(cx)+","+itos(cz)+") at "+ftos(map->get_height(cx,
						cz))+" layer "+itos(best);
			}
			what += ", map hash "+itos(map->content_hash());
		});
		for(auto &d : decorate){
			const uint64_t id = add_decor(d.first, d.second[0], d.second[1],
					d.second[2], d.second[3]);
			if(c)
				c->decor.push_back(id);
			added++;
		}
		if(tool == "decorate")
			what += ", "+itos(added)+" decorations ("+itos(m_decor.size())+
					" in all, hash "+itos(decor_hash())+")";
		if(tool != "paint" && tool != "decorate" && tool != "column")
			reseat_decor(bx0, bz0, bx1, bz1);
		return what;
	}

	// An editor's undo of a terrain stroke: its cells, samples and
	// decorations as they were
	void undo_terrain(const Change &c, const Peer &p)
	{
		size_t cells = 0;
		if(!c.cells.empty())
			voxelworld::access(m_server, m_world_scene,
					[&](voxelworld::Instance *w){
				for(auto &q : c.cells){
					const pv::Vector3DInt32 v(std::get<0>(q.first),
							std::get<1>(q.first), std::get<2>(q.first));
					if(!loaded(w, v))
						continue;
					set_id(w, v, q.second);
					mark(w, m_world_scene, v, 'k', p.name);
					cells++;
				}
			});
		int x0 = INT_MAX, z0 = INT_MAX, x1 = INT_MIN, z1 = INT_MIN;
		if(!c.samples.empty())
			heightmap::access(m_server, m_world_scene,
					[&](heightmap::Instance *map){
				for(auto &q : c.samples){
					map->set_height(q.first.first, q.first.second, q.second.first);
					map->set_weights(q.first.first, q.first.second,
							q.second.second);
					x0 = std::min(x0, q.first.first);
					x1 = std::max(x1, q.first.first);
					z0 = std::min(z0, q.first.second);
					z1 = std::max(z1, q.first.second);
				}
			});
		for(uint64_t id : c.decor)
			remove_decor(id);
		if(!c.samples.empty())
			reseat_decor(x0, z0, x1, z1);
		save_decor();
		ss_ hash;
		if(m_wp.heightmap())
			heightmap::access(m_server, m_world_scene,
					[&](heightmap::Instance *map){
				hash = ", map hash "+itos(map->content_hash());
			});
		log_i(MODULE, "An undo by %s: a terrain stroke, %zu cells, %zu samples "
				"and %zu decorations put back%s", cs(p.name), cells,
				c.samples.size(), c.decor.size(), cs(hash));
	}

	// Where voxelworld keeps the World loaded: a finite map's sections
	// pinned, its whole; an infinite one round each player and the spawn;
	// a heightmap's scene none
	void world_load_points()
	{
		if(!m_world_scene)
			return;
		sv_<voxelworld::LoadPoint> pts;
		const int S = m_section_size;
		auto sec = [&](int v){ return v >= 0 ? v / S : -((-v + S - 1) / S); };
		const world::Params &p = m_wp;
		if(p.heightmap()){
		} else if(p.finite()){
			const int m = p.border == "water" ? world::SEA_BORDER :
					p.border == "wall" ? 1 : 0;
			const int ylo = std::min(m_world_min, p.border == "water" ?
					p.sea_level - world::SEA_BED : INT_MAX) -
					(p.with_caves() ? world::CAVE_DEEP : 8);
			const int yhi = std::max(m_world_max + (p.border == "wall" ? 4 : 0),
					p.sea_level);
			for(int sx = sec(p.x0() - m); sx <= sec(p.x0() + p.width - 1 + m); sx++)
			for(int sz = sec(p.z0() - m); sz <= sec(p.z0() + p.depth - 1 + m); sz++)
			for(int sy = std::max(sec(ylo), (int)WORLD_SECTION_Y0);
					sy <= std::min(sec(yhi), (int)WORLD_SECTION_Y1); sy++)
				pts.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
						sx * S + S / 2, sy * S + S / 2, sz * S + S / 2), 0, 0, 0, 0));
		} else {
			double x = 0, y = 0, z = 0;
			world_spawn(x, y, z);
			pts.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(0, (int)y, 0),
					1, 1, 1, 1));
			for(auto &wp : m_world_peers)
				pts.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
						wp.second[0], wp.second[1], wp.second[2]), world::LOAD_XZ,
						world::LOAD_Y, world::GEN_XZ, world::LOAD_Y, wp.first));
		}
		voxelworld::access(m_server, m_world_scene,
				[&](voxelworld::Instance *w){
			w->set_load_points(pts);
		});
		log_v(MODULE, "World: %zu load points", pts.size());
	}

	// An infinite World loads round a player as they go (the section
	// they are in changed)
	void world_peer(size_t peer, const ss_ &scene, double x, double y,
			double z)
	{
		if(!m_world_scene || m_wp.finite() || scene != m_host.world_scene)
			return;
		const std::array<int32_t, 3> c = {{(int32_t)std::floor(x),
				(int32_t)std::floor(y), (int32_t)std::floor(z)}};
		auto it = m_world_peers.find(peer);
		const int S = m_section_size;
		if(it != m_world_peers.end()){
			bool same = true;
			for(int k = 0; k < 3; k++)
				same = same && std::floor(it->second[k] / (double)S) ==
						std::floor(c[k] / (double)S);
			if(same)
				return;
		}
		m_world_peers[peer] = c;
		world_load_points();
	}

	void world_spawn(double &x, double &y, double &z)
	{
		x = 0.5;
		y = 1;
		z = 0.5;
		if(!m_world_scene)
			return;
		const world::Params &p = m_wp;
		if(p.heightmap()){
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_world_scene);
				if(!map)
					return;
				x = map->samples_x() / 2 + 0.5;
				z = map->samples_z() / 2 + 0.5;
				y = map->height_at((float)x, (float)z) + 0.5;
			});
			return;
		}
		x = m_world_spawn[0] + 0.5;
		y = m_world_spawn[1];
		z = m_world_spawn[2] + 0.5;
	}

	// The valleys' surface for these heights (luanti_mapgen's; its
	// rivers' size 0: the valleys stay, no channel is cut)
	void valleys_query(world::Heights &h)
	{
		if(h.p.generator != "valleys")
			return;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *i){
			luanti_mapgen::Params lp;
			lp.mgname = "valleys";
			lp.seed = h.p.seed;
			lp.water_level = h.p.sea_level;
			lp.settings["mgvalleys_river_size"] = "0";
			// The ids every Luanti game has and the mapgen's aliases; no
			// node is placed
			lp.content_ids = {{"ignore", 0}, {"unknown", 1}, {"air", 2},
				{"mapgen_stone", 3}, {"mapgen_water_source", 4},
				{"mapgen_river_water_source", 5}};
			h.valleys.reset(i->create_surface_query(lp));
		});
	}

	// The spawn: the dry column nearest the middle (of the map, or the
	// origin's 128 x 128), on the water at the middle if there is none
	void find_spawn(world::Heights &h, const world::Ids &ids)
	{
		const world::Params &p = h.p;
		m_world_spawn = {{0, p.generator == "empty" ? p.level : 1, 0}};
		if(p.generator == "empty")
			return;
		const int w = p.finite() ? std::min(p.width, 128) : 128;
		const int d = p.finite() ? std::min(p.depth, 128) : 128;
		sv_<int> tops;
		h.tops(-w / 2, -d / 2, w, d, tops);
		// [KIT] stage 4f: a column a decoration of more than a cell stands
		// over (a tree's trunk or leaves) is not one
		auto blocked = [&](int x, int z){
			if(!p.with_decorations())
				return false;
			const int R = ids.reach;
			bool hit = false;
			for(int az = z - R; az <= z + R && !hit; az++)
			for(int ax = x - R; ax <= x + R && !hit; ax++){
				if(ax < 0 || az < 0 || ax >= w || az >= d)
					continue;
				int turns = 0;
				const int k = world::pick_surface(ids, p.seed, ax - w / 2,
						az - d / 2, tops[(size_t)az * w + ax], p.sea_level, 1,
						turns);
				if(k < 0)
					continue;
				const world::StructIds &s = ids.structs[ids.decors[k].s];
				if(s.sx * s.sy * s.sz <= 1)
					continue;
				s.each(turns, [&](int dx, int, int dz, interface::VoxelTypeId){
					hit = hit || (ax + dx == x && az + dz == z);
				});
			}
			return hit;
		};
		int64_t best = -1;
		for(int z = 0; z < d; z++)
			for(int x = 0; x < w; x++){
				const int t = tops[(size_t)z * w + x];
				const int64_t dx = x - w / 2, dz = z - d / 2,
						d2 = dx * dx + dz * dz;
				if(t < p.sea_level || (best >= 0 && d2 >= best) ||
						blocked(x, z))
					continue;
				best = d2;
				m_world_spawn = {{(int)dx, t + 1, (int)dz}};
			}
		if(best < 0)
			m_world_spawn = {{0, std::max(tops[(size_t)(d / 2) * w + w / 2],
					p.sea_level) + 1, 0}};
	}

	void on_generated(const worldgen::SectionGenerated &e)
	{
		if(e.scene == m_world_scene && m_world_scene)
			m_world_generated++;
	}

	void on_gen_queue(const worldgen::QueueModifiedEvent &e)
	{
		if(e.scene != m_world_scene || !m_world_scene || e.queue_size ||
				m_world_generated == m_world_logged)
			return;
		m_world_logged = m_world_generated;
		log_i(MODULE, "World: %zu sections generated since the start",
				m_world_generated);
	}

	// ---- Players as entities ([KIT] stage 4d)

	// An instance as new: its type's parameters and state at their defaults
	void fresh(Instance &in)
	{
		const json::Value &decl = m_types[in.type].decl;
		in.version = m_types[in.type].version;
		const json::Value &pd = decl.get("params");
		if(pd.is_object())
			for(json::Iterator it(pd); it; ++it)
				in.params.set(it.key(), (*it).get("default"));
		const json::Value &sd = decl.get("state");
		if(sd.is_object())
			for(json::Iterator it(sd); it; ++it)
				in.state.set(it.key(), (*it).get("default"));
	}

	// A player's entity, made the first time they are seen: kind "player",
	// under the root until the app places them, each player type's
	// instance on it. Its id is theirs from then on (`by` is
	// "player:<id>"), kept in the runtime row
	uint64_t ensure_player(const ss_ &name)
	{
		auto it = m_players.find(name);
		if(it != m_players.end() && m_entities.count(it->second))
			return it->second;
		Entity e;
		e.id = it != m_players.end() ? it->second : m_next_player++;
		e.parent = 1;
		e.kind = "player";
		e.name = name;
		for(const ss_ &t : m_player_types){
			Instance in;
			in.type = t;
			fresh(in);
			e.comps.push_back(in);
		}
		m_entities[e.id] = e;
		m_players[name] = e.id;
		m_runtime_dirty = true;
		if(m_hosted)
			log_i(MODULE, "%s is entity %s", cs(name), cs(itos(e.id)));
		return e.id;
	}

	// The players' entities from the runtime row; from before [KIT] stage
	// 4d, the session's "aside" (each player's items kept between plays)
	void load_players(const json::Value &rt, const json::Value &old_aside)
	{
		const json::Value &pl = rt.get("players");
		if(pl.is_object())
			for(json::Iterator it(pl); it; ++it){
				const uint64_t id = (uint64_t)json::jint(*it, "id", 0);
				if(id < 2 || id > 9e15 || m_entities.count(id) ||
						it.key().empty()){
					log_w(MODULE, "Player %s's entity %s is not one: dropped",
							cs(it.key()), cs(itos(id)));
					continue;
				}
				m_players[it.key()] = id;
				ensure_player(it.key());
				m_next_player = std::max(m_next_player, id + 1);
				if((*it).get("aside").is_object())
					m_aside.set(it.key(), (*it).get("aside").deepcopy());
			}
		if(old_aside.is_object())
			for(json::Iterator it(old_aside); it; ++it){
				ensure_player(it.key());
				m_aside.set(it.key(), (*it).deepcopy());
			}
	}

	// The round's entities from the runtime row (Running): those play
	// made, and the authored ones it removed
	void load_round(const json::Value &rt)
	{
		const json::Value &made = rt.get("made");
		for(unsigned i = 0; i < made.size(); i++)
			m_pending_ids.insert((uint64_t)json::jint(made.at(i).get("entity"),
					"id", 0));
		for(unsigned i = 0; i < made.size(); i++){
			const json::Value &m = made.at(i);
			Entity e;
			ss_ why;
			if(!entity_from_json(m.get("entity"), e, why) || e.kind != "" ||
					m_entities.count(e.id) || !m_entities.count(e.parent)){
				log_w(MODULE, "An entity the round made is dropped: %s",
						why.empty() ? cs(m.get("entity").stringify().substr(0,
						100)) : cs(why));
				continue;
			}
			e.made = jstr(m, "origin") == "b" ? 'b' : 'g';
			e.made_by = jstr(m, "by");
			e.maker = (uint64_t)std::max(0.0, m.get("maker").at(0u).is_number() ?
					m.get("maker").at(0u).as_number() : 0.0);
			e.maker_comp = (size_t)std::max(0.0, m.get("maker").at(1u).
					is_number() ? m.get("maker").at(1u).as_number() : 0.0);
			m_next_id = std::max(m_next_id, e.id + 1);
			m_entities[e.id] = e;
		}
		m_pending_ids.clear();
		const json::Value &removed = rt.get("removed");
		for(unsigned i = 0; i < removed.size(); i++){
			const json::Value &r = removed.at(i);
			auto it = m_entities.find((uint64_t)json::jint(r.get("entity"),
					"id", 0));
			if(it == m_entities.end() || !authored(it->second) ||
					!it->second.kind.empty())
				continue;
			Removed rm;
			rm.e = it->second;
			rm.origin = jstr(r, "origin") == "b" ? 'b' : 'g';
			rm.by = jstr(r, "by");
			m_removed[it->first] = rm;
			m_entities.erase(it);
		}
		if(made.size() || removed.size())
			log_i(MODULE, "The round's entities: %u made, %zu removed",
					made.size(), m_removed.size());
	}

	// The player entity `by` is ("player:<id>"), or 0
	uint64_t player_id(const ss_ &by)
	{
		if(by.compare(0, 7, "player:") != 0 || by.size() == 7 ||
				by.find_first_not_of("0123456789", 7) != ss_::npos)
			return 0;
		auto it = m_entities.find(strtoull(by.c_str() + 7, nullptr, 10));
		return it != m_entities.end() && it->second.kind == "player" ?
				it->first : 0;
	}

	// The player's name `by` is: their entity's; "player:<name>" from
	// before [KIT] stage 4d its name; "" for no player
	ss_ player_of(const ss_ &by)
	{
		const uint64_t id = player_id(by);
		if(id)
			return m_entities[id].name;
		// A guest's dropped entity still has its name (their zone's
		// on_leave runs after)
		auto g = m_gone_guests.find(by);
		if(g != m_gone_guests.end())
			return g->second;
		return by.compare(0, 7, "player:") == 0 ? by.substr(7) : "";
	}

	// A player's `by`: "player:<their entity's id>"
	ss_ by_of(const ss_ &name)
	{
		return "player:"+itos(ensure_player(name));
	}

	// A `by` as the app gives it ("player:<name>", as a routed voxel write
	// carries it) as Kit's: "player:<id>"
	ss_ norm_by(const ss_ &by)
	{
		if(player_id(by) || by.compare(0, 7, "player:") != 0 || by.size() == 7)
			return by;
		return by_of(by.substr(7));
	}

	// `by` as a log says it: "player:7 (kitboss)"
	ss_ by_text(const ss_ &by)
	{
		const uint64_t id = player_id(by);
		return id ? by+" ("+m_entities[id].name+")" : by;
	}

	// A player entity's own inventory: its type with the inventory's
	// handlers (Kit's kit/inventory)
	Instance* own_inventory(uint64_t player)
	{
		auto it = m_entities.find(player);
		if(it == m_entities.end())
			return nullptr;
		for(Instance &in : it->second.comps)
			if(m_types[in.type].handlers.count("inventory_list"))
				return &in;
		return nullptr;
	}

	// The scene entity of a scene's name (0: none)
	uint64_t scene_entity(const ss_ &scene)
	{
		for(auto &e : m_entities)
			if(e.second.kind == "scene" && e.second.name == scene)
				return e.first;
		return 0;
	}

	// A placed player's entity where the app puts them: in their scene,
	// its node there carrying its shared state (a score)
	void place_player(Peer &p)
	{
		if(p.name.empty())
			return;
		const uint64_t id = ensure_player(p.name);
		Entity &e = m_entities[id];
		const uint64_t scene = scene_entity(p.scene);
		if(!scene)
			return;
		if(e.parent != scene || !e.has_pos){
			remove_node(e);
			e.node = 0;
			e.parent = scene;
			e.has_pos = true;
		}
		for(int k = 0; k < 3; k++)
			e.pos[k] = p.pos[k];
		if(!e.node){
			make_node(e);
			return;
		}
		main_context::access(m_server, scene_of(e), [&](magic::Scene *sc){
			magic::Node *n = sc->GetNode(e.node);
			if(n)
				n->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
		});
	}

	// A player gone (or by another name): their entity stays, unplaced
	void unplace_player(uint64_t id)
	{
		auto it = m_entities.find(id);
		if(it == m_entities.end() || it->second.kind != "player")
			return;
		for(auto &p : m_peers)
			if(p.second.player == id)
				return;
		remove_node(it->second);
		it->second.node = 0;
		it->second.has_pos = false;
		it->second.parent = 1;
	}

	// The cells migrated objects owned: their owner entries emptied (by
	// own_voxels(), which empties the sections it owned in) and their voxels
	// cleared, written into the start
	void clear_migrated()
	{
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(const Migrated &m : m_migrated_objects){
				auto it = m_entities.find(m.id);
				main_context::SceneReference sc = it == m_entities.end() ?
						nullptr : scene_of(it->second);
				voxelworld::Instance *w = sc ? ivw->get_instance(sc) : nullptr;
				if(!w)
					continue;
				const pv::Vector3DInt16 ss = w->get_section_size_voxels();
				for(const pv::Vector3DInt32 &p : m.cells){
					m_owned_sections[sc].insert(std::make_tuple(
							div_floor(p.getX(), ss.getX()),
							div_floor(p.getY(), ss.getY()),
							div_floor(p.getZ(), ss.getZ())));
					Write wr;
					wr.scene = sc;
					wr.p = p;
					wr.voxel = m.air;
					wr.by = "kit";
					m_start_writes.push_back(wr);
				}
			}
		});
		m_migrated_objects.clear();
	}

	static int div_floor(int32_t a, int b)
	{
		return (int)std::floor((double)a / b);
	}

	// A look as the clients get it: the type's, its extent (a position
	// parameter: the cells from its own up and on) made a size (its sides,
	// the z side its depth when it has one) and an offset of its middle
	// from the entity's position
	json::Value look_of(const Instance &in, const json::Value &decl)
	{
		json::Value l = decl.deepcopy();
		// [KIT] stage 4d: "param:<name>" anywhere in it (its `when` too) is
		// that parameter's value (kit/part's size, colour, rotation...)
		std::function<void(json::Value&, int)> params =
				[&](json::Value &o, int depth){
			if(!o.is_object() || depth > 2)
				return;
			sv_<std::pair<ss_, json::Value>> set;
			for(json::Iterator it(o); it; ++it){
				if((*it).is_object()){
					json::Value sub = *it;
					params(sub, depth + 1);
				} else if((*it).is_string() &&
						(*it).as_string().compare(0, 6, "param:") == 0){
					const json::Value &v = in.params.get((*it).as_string().
							substr(6));
					set.push_back(std::make_pair(it.key(), v.is_undefined() ?
							json::null() : v));
				}
			}
			for(auto &s : set)
				o.set(s.first, s.second);
		};
		params(l, 0);
		const ss_ ext = jstr(decl, "extent");
		if(ext.empty())
			return l;
		int n[3];
		extent(in.params.get(ext), n);
		const json::Value &d = decl.get("depth");
		const bool depth = d.is_number() && d.as_number() > 0 &&
				d.as_number() <= MAX_EXTENT;
		json::Value size = json::array(), off = json::array();
		size.append((double)n[0]);
		size.append((double)n[1]);
		size.append(depth ? d.as_number() : (double)n[2]);
		off.append((n[0] - 1) / 2.0);
		off.append((n[1] - 1) / 2.0);
		off.append(depth ? 0.0 : (n[2] - 1) / 2.0);
		l.set("size", size);
		l.set("offset", off);
		l.del_key("extent");
		l.del_key("depth");
		return l;
	}

	// What its types show every client: the first look and hud
	json::Value show_of(const Entity &e)
	{
		json::Value show = json::object(), parts = json::array();
		std::set<ss_> shared;
		for(const Instance &in : e.comps){
			const json::Value &d = m_types[in.type].decl;
			if(show.get("look").is_undefined() && !d.get("look").is_undefined())
				show.set("look", look_of(in, d.get("look")));
			if(show.get("hud").is_undefined() && !d.get("hud").is_undefined())
				show.set("hud", d.get("hud"));
			// [KIT] stage 4e2: what a click would do, shown on it: it is
			// used (a client's use reaches it), it grants digging or placing
			// in its box (its state's dig and place, shared)
			const Type &ty = m_types[in.type];
			if(ty.usable && ty.handlers.count("on_use"))
				show.set("usable", true);
			if(!ty.grants.empty() && show.get("grants").is_undefined()){
				int n[3];
				extent(in.params.get(ty.grants), n);
				json::Value g = json::array();
				for(int k = 0; k < 3; k++)
					g.append(n[k]);
				show.set("grants", g);
			}
			// The types whose client part runs for it ([KIT] stage 4d), and
			// the state they see
			if(!m_types[in.type].client.empty())
				parts.append(in.type);
			for(const ss_ &k : m_types[in.type].shared)
				shared.insert(k);
		}
		if(parts.size()){
			json::Value keys = json::array();
			for(const ss_ &k : shared)
				keys.append(k);
			show.set("client", parts);
			show.set("shared", keys);
		}
		if(e.kind == "player")
			show.set("player", true);
		return show;
	}

	void make_node(Entity &e)
	{
		const json::Value show = show_of(e);
		main_context::SceneReference ref = scene_of(e);
		main_context::access(m_server, ref, [&](magic::Scene *scene){
			magic::Node *n = scene->CreateChild(("kit:"+itos(e.id)).c_str());
			n->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
			n->SetRotation(magic::Quaternion(0, (float)e.yaw, 0));
			n->SetVar(magic::StringHash("kit_id"), magic::Variant((int)e.id));
			n->SetVar(magic::StringHash("kit_show"),
					magic::Variant(show.stringify().c_str()));
			e.node = n->GetID();
		});
		for(size_t i = 0; i < e.comps.size(); i++)
			for(const ss_ &k : m_types[e.comps[i].type].shared)
				replicate_state(e, i, k);
	}

	void replicate_state(const Entity &e, size_t comp, const ss_ &key)
	{
		if(!e.node)
			return;
		const ss_ v = e.comps[comp].state.get(key).stringify();
		main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
			magic::Node *n = scene->GetNode(e.node);
			if(n)
				n->SetVar(magic::StringHash(("kit:"+key).c_str()),
						magic::Variant(v.c_str()));
		});
	}

	void own_voxels()
	{
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(auto &s : m_host.scenes){
				voxelworld::Instance *w = ivw->get_instance(s.second);
				if(!w)
					continue;
				auto owner = std::make_shared<Owner>();
				owner->scene = s.second;
				owner->mutex = &m_writes_mutex;
				owner->queue = &m_writes;
				w->set_owner_handler("kit", owner);
				// Each section's "kit" entries, replaced: loaded or not
				const pv::Vector3DInt16 ss = w->get_section_size_voxels();
				std::map<std::tuple<int, int, int>, voxelworld::OwnedList> by;
				for(auto &p : m_entities){
					const Entity &e = p.second;
					if(!e.has_pos || scene_of(e) != s.second)
						continue;
					for(const pv::Vector3DInt32 &v : owned_cells(e)){
						auto div = [](int32_t a, int b){
							return (int)std::floor((double)a / b);
						};
						by[std::make_tuple(div(v.getX(), ss.getX()),
								div(v.getY(), ss.getY()), div(v.getZ(),
								ss.getZ()))].push_back(std::make_pair(v,
								itos(e.id)));
					}
				}
				// And emptied where an entity owned and owns no more
				for(const auto &k : m_owned_sections[s.second])
					by[k];
				m_owned_sections[s.second].clear();
				for(auto &b : by){
					w->set_section_owned(pv::Vector3DInt16(
							std::get<0>(b.first), std::get<1>(b.first),
							std::get<2>(b.first)), "kit", b.second);
					if(!b.second.empty())
						m_owned_sections[s.second].insert(b.first);
				}
			}
		});
	}

	// ---- Runs

	void queue_run(const Run &r)
	{
		if(m_queue.size() >= MAX_QUEUE){
			log_w(MODULE, "The queue is full: %s on entity %s dropped",
					cs(r.handler), cs(itos(r.entity)));
			return;
		}
		m_queue.push_back(r);
	}

	// An input to an entity: each of its instances that has it, the value
	// as the input declares it ([KIT] stage 4d). from and output: the
	// link's other end, the builders shown it passing
	void deliver(uint64_t to, const ss_ &input, const json::Value &value,
			const ss_ &by, int hops, uint64_t from = 0, const ss_ &output = "")
	{
		auto it = m_entities.find(to);
		if(it == m_entities.end())
			return;
		bool flowed = false;
		for(size_t i = 0; i < it->second.comps.size(); i++){
			const Instance &in = it->second.comps[i];
			const Type &t = m_types[in.type];
			if(!t.inputs.count(input))
				continue;
			const ss_ &type = t.in_types.at(input);
			if(!signal_ok(type, value)){
				log_w(MODULE, "Entity %s's %s: its input %s takes a %s, not %s",
						cs(itos(to)), cs(in.type), cs(input), cs(type),
						cs(value.stringify().substr(0, 64)));
				add_log(to, "input "+input+" takes a "+type+", not "+
						value.stringify().substr(0, 64));
				continue;
			}
			if(from && !flowed && m_flows.size() < MAX_FLOWS){
				json::Value f = json::array();
				f.append((int64_t)from);
				f.append(output);
				f.append((int64_t)to);
				f.append(input);
				m_flows.append(f);
				flowed = true;
			}
			Run r;
			r.entity = to;
			r.comp = i;
			r.handler = "on_input";
			r.args.append(input);
			r.args.append(type == "none" ? json::null() : value);
			r.args.append(by);
			r.by = by;
			r.hops = hops;
			queue_run(r);
		}
	}

	ss_ request_of(const Entity &e, const Instance &in, const Run &r)
	{
		ss_ o = "Rreturn {type=";
		lua_lit(json::Value(in.type), o);
		o += ",handler=";
		lua_lit(json::Value(r.handler), o);
		o += ",id="+itos(e.id);
		if(e.has_pos){
			o += ",pos={";
			for(int k = 0; k < 3; k++){
				lua_lit(json::Value(e.pos[k]), o);
				o += ',';
			}
			o += '}';
		}
		o += ",params=";
		lua_lit(in.params, o);
		o += ",state=";
		lua_lit(in.state, o);
		o += ",args=";
		lua_lit(r.args, o);
		o += ",nargs="+itos(r.args.size());
		// The player who set it off (their entity, their name), and their
		// inventory's provider: the replacing instance, or their entity's
		// own kit/inventory (itself, or its type, id, params and state)
		const uint64_t pid = player_id(r.by);
		json::Value names = json::object();
		if(pid){
			names.set(r.by, m_entities[pid].name);
			o += ",player_id="+itos(pid)+",player=";
			lua_lit(json::Value(r.by), o);
			uint64_t inv_id = 0;
			size_t inv_comp = 0;
			const Instance *pv_ = provider_for(pid, inv_id, inv_comp);
			if(!pv_){
				o += ",items={}";
			} else if(pv_ == &in){
				o += ",inv_self=true";
			} else {
				o += ",inv={type=";
				lua_lit(json::Value(pv_->type), o);
				o += ",id="+itos(inv_id)+",params=";
				lua_lit(pv_->params, o);
				o += ",state=";
				lua_lit(pv_->state, o);
				o += "}";
			}
		}
		// [KIT] stage 4d: the copies it made, every player for a type that
		// reads them, the next ids and what each copy it may make makes
		const size_t ci = &in - &e.comps[0];
		o += ",made={";
		for(auto &p : m_entities)
			if(made_head(p.second, e.id, ci))
				o += itos(p.first)+",";
		o += "}";
		if(m_types[in.type].players){
			json::Value players = json::array();
			for(auto &pl : m_players){
				auto it = m_entities.find(pl.second);
				if(it == m_entities.end())
					continue;
				json::Value j = json::object(), st = json::object();
				j.set("id", (int64_t)pl.second);
				j.set("name", pl.first);
				j.set("here", it->second.has_pos);
				for(const Instance &pi : it->second.comps)
					st.set(pi.type, pi.state);
				j.set("state", st);
				players.append(j);
				names.set("player:"+itos(pl.second), pl.first);
			}
			o += ",players=";
			lua_lit(players, o);
		}
		o += ",names=";
		lua_lit(names, o);
		o += ",next_id="+itos(m_next_id)+",sizes={";
		for(const auto &s : copy_sizes(e, ci)){
			o += '[';
			lua_lit(json::Value(s.first), o);
			o += "]="+itos(s.second)+",";
		}
		o += "}}";
		return o;
	}

	// One run; what it spent of the meter
	int64_t run(const Run &r)
	{
		auto it = m_entities.find(r.entity);
		if(it == m_entities.end() || r.comp >= it->second.comps.size())
			return 0;
		Entity &e = it->second;
		const ss_ type = e.comps[r.comp].type;
		if(!e.comps[r.comp].disabled.empty() ||
				!m_types[type].handlers.count(r.handler))
			return 0;
		ss_ answer, error;
		bool runaway = false, in_provider = false;
		int64_t spent = 0;
		const ss_ request = request_of(e, e.comps[r.comp], r);
		const uint64_t pid = player_id(r.by);
		uint64_t inv_id = 0;
		size_t inv_comp = 0;
		if(!box_call(request, answer, error, &runaway, &spent, &in_provider)){
			Instance *pv_ = provider_for(pid, inv_id, inv_comp);
			if(runaway && in_provider && pv_){
				// The inventory's provider ran past it: it is disabled, not
				// the caller; a replacing one's players have their own
				// inventories from then on
				pv_->disabled = "its inventory ran past its budget in entity "+
						itos(r.entity)+"'s "+r.handler;
				m_runtime_dirty = true;
				log_w(MODULE, "Entity %s's %s disabled: %s; the players' "
						"inventory is %s now", cs(itos(inv_id)), cs(pv_->type),
						cs(pv_->disabled), inv_id == pid ? "none" :
						"their entities' own");
				add_log(inv_id, "disabled: "+pv_->disabled);
			} else if(runaway){
				Instance &in = m_entities[r.entity].comps[r.comp];
				in.disabled = r.handler+" ran past its budget";
				m_runtime_dirty = true;
				log_w(MODULE, "Entity %s's %s disabled: %s", cs(itos(r.entity)),
						cs(type), cs(in.disabled));
				add_log(r.entity, "disabled: "+in.disabled);
			} else {
				log_w(MODULE, "Entity %s's %s, %s: %s", cs(itos(r.entity)),
						cs(type), cs(r.handler), cs(error));
				add_log(r.entity, r.handler+": "+error);
			}
			return spent;
		}
		const json::Value fx = json::load_string(answer.c_str());
		Instance &in = e.comps[r.comp];
		const Type &t = m_types[type];
		const json::Value &lines = fx.get("log");
		for(unsigned i = 0; i < lines.size(); i++)
			if(lines.at(i).is_string())
				add_log(e.id, lines.at(i).as_string());
		const json::Value &sets = fx.get("set");
		for(unsigned i = 0; i < sets.size(); i++){
			const json::Value &kv = sets.at(i);
			if(!kv.at(0u).is_string())
				continue;
			const ss_ k = kv.at(0u).as_string();
			in.state.set(k, kv.at(1u));
			m_runtime_dirty = true;
			if(t.shared.count(k))
				replicate_state(e, r.comp, k);
		}
		const json::Value &emits = fx.get("emit");
		for(unsigned i = 0; i < emits.size(); i++){
			const ss_ output = emits.at(i).at(0u).is_string() ?
					emits.at(i).at(0u).as_string() : ss_();
			if(!t.outputs.count(output)){
				log_w(MODULE, "Entity %s's %s emits %s, which it does not "
						"declare", cs(itos(e.id)), cs(type), cs(output));
				add_log(e.id, "emits "+output+", which it does not declare");
				continue;
			}
			// [KIT] stage 4d: the value as the output declares it
			const ss_ &ot = t.out_types.at(output);
			json::Value value = emits.at(i).at(1u);
			if(!signal_ok(ot, value)){
				log_w(MODULE, "Entity %s's %s emits %s %s, which is no %s: "
						"not sent", cs(itos(e.id)), cs(type), cs(output),
						cs(value.stringify().substr(0, 64)), cs(ot));
				add_log(e.id, "emits "+output+" "+value.stringify().substr(0,
						64)+", which is no "+ot+": not sent");
				continue;
			}
			if(ot == "none")
				value = json::null();
			for(const Link &l : in.links){
				if(l.output != output)
					continue;
				if(r.hops + 1 > MAX_HOPS){
					log_w(MODULE, "A signal loop cut: entity %s's %s -> entity "
							"%s's %s, past %i links", cs(itos(e.id)), cs(output),
							cs(itos(l.to)), cs(l.input), MAX_HOPS);
					add_log(e.id, "a signal loop cut at "+output+" -> "+
							itos(l.to)+"."+l.input);
					continue;
				}
				deliver(l.to, l.input, value, r.by, r.hops + 1, e.id, output);
			}
		}
		// The provider's state, changed by the inventory calls of this run
		Instance *pv_ = provider_for(pid, inv_id, inv_comp);
		const json::Value &inv_set = fx.get("inv_set");
		if(pv_ && pv_ != &in && inv_set.size()){
			Entity &pe = m_entities[inv_id];
			for(unsigned i = 0; i < inv_set.size(); i++){
				const json::Value &kv = inv_set.at(i);
				if(!kv.at(0u).is_string())
					continue;
				const ss_ k = kv.at(0u).as_string();
				pv_->state.set(k, kv.at(1u));
				m_runtime_dirty = true;
				if(m_types[pv_->type].shared.count(k))
					replicate_state(pe, inv_comp, k);
			}
		}
		const json::Value &voxel = fx.get("voxel");
		if(voxel.is_string() && !voxel.as_string().empty()){
			if(!t.owns_voxel || !e.has_pos){
				log_w(MODULE, "Entity %s's %s sets a voxel it does not own",
						cs(itos(e.id)), cs(type));
			} else {
				for(const pv::Vector3DInt32 &p : owned_cells(e)){
					Write w;
					w.scene = scene_of(e);
					w.p = p;
					w.voxel = voxel.as_string();
					w.by = r.by;
					// A game change, or a build of the player who set it
					// off (the type's builds)
					w.origin = t.builds && pid ? 'b' : 'g';
					if(!set_voxel(w))
						m_pending_voxels.push_back(w);
				}
			}
		}
		const json::Value &after = fx.get("after");
		if(after.is_number()){
			// simplified: one timer an instance; a new c:after replaces it
			const double s = after.as_number();
			in.due_us = s >= 0 && s < 1e7 ? interface::os::game_us() +
					(int64_t)(s * 1e6) : -1;
			in.due_by = r.by;
			m_runtime_dirty = true;
		}
		const ss_ who = player_of(r.by);
		const json::Value &tp = fx.get("teleport");
		if(tp.is_array())
			teleport(e, type, who, tp);
		const json::Value &items = fx.get("items");
		if(!who.empty() && !items.is_undefined())
			got_items(e, type, who, items);
		// [KIT] stage 4d: entities: copies made, signals sent, removals
		// (last: the instance itself may go)
		const uint64_t self = e.id;
		const size_t comp = r.comp;
		const json::Value &spawns = fx.get("spawn");
		for(unsigned i = 0; i < spawns.size(); i++)
			spawn(self, comp, r.by, spawns.at(i));
		const json::Value &sends = fx.get("send");
		if(sends.size()){
			const std::set<uint64_t> rch = reach(m_entities[self], comp, r.by);
			for(unsigned i = 0; i < sends.size(); i++){
				const json::Value &s = sends.at(i);
				const uint64_t to = s.at(0u).is_number() ?
						(uint64_t)std::max(0.0, s.at(0u).as_number()) : 0;
				const ss_ input = jstr_at(s, 1);
				if(!rch.count(to) || r.hops + 1 > MAX_HOPS){
					add_log(self, "send "+input+" to "+itos(to)+" refused: "+
							(rch.count(to) ? "past "+itos(MAX_HOPS)+" links" :
							"not one it reaches"));
					continue;
				}
				deliver(to, input, s.at(2u), r.by, r.hops + 1, self, "send");
			}
		}
		const json::Value &removes = fx.get("remove");
		for(unsigned i = 0; i < removes.size(); i++)
			if(removes.at(i).is_number())
				remove_entity(self, comp, r.by,
						(uint64_t)std::max(0.0, removes.at(i).as_number()));
		if(spawns.size() || removes.size()){
			own_voxels();
			pick_provider();
		}
		return spent;
	}

	// ---- Entities made and removed in play ([KIT] stage 4d)

	// The entities an instance reaches: its own, its links' ends, those its
	// entity parameters name, the copies it made, the player who set the
	// run off, and every player for a type that reads them (`players`)
	std::set<uint64_t> reach(const Entity &e, size_t comp, const ss_ &by)
	{
		std::set<uint64_t> r;
		r.insert(e.id);
		if(comp >= e.comps.size())
			return r;
		const Instance &in = e.comps[comp];
		for(const Link &l : in.links)
			r.insert(l.to);
		const json::Value &decl = m_types[in.type].decl.get("params");
		if(decl.is_object())
			for(json::Iterator it(decl); it; ++it){
				const json::Value &v = in.params.get(it.key());
				if(jstr(*it, "type") == "entity" && v.is_number() &&
						v.as_number() >= 2)
					r.insert((uint64_t)v.as_number());
			}
		for(auto &p : m_entities)
			if(p.second.made && p.second.maker == e.id &&
					p.second.maker_comp == comp)
				r.insert(p.first);
		const uint64_t pid = player_id(by);
		if(pid)
			r.insert(pid);
		if(m_types[in.type].players)
			for(auto &p : m_players)
				r.insert(p.second);
		return r;
	}

	// An entity and every entity under it, parents first; empty past
	// MAX_PREFAB of them
	// A copy an instance made, by its first entity: not under another of
	// its copies' entities, nor a prefab copy's later member
	bool made_head(const Entity &x, uint64_t maker, size_t comp)
	{
		if(!x.made || x.maker != maker || x.maker_comp != comp)
			return false;
		auto par = m_entities.find(x.parent);
		if(par != m_entities.end() && par->second.made &&
				par->second.maker == maker && par->second.maker_comp == comp)
			return false;
		const int64_t copy = json::jint(x.prefab, "copy", 0);
		return !copy || copy == (int64_t)x.id;
	}

	sv_<uint64_t> group_of(uint64_t id, size_t max = MAX_PREFAB)
	{
		sv_<uint64_t> g;
		if(!m_entities.count(id))
			return g;
		g.push_back(id);
		for(size_t i = 0; i < g.size(); i++){
			for(auto &p : m_entities)
				if(p.second.parent == g[i] && p.first != g[i])
					g.push_back(p.first);
			if(g.size() > max)
				return sv_<uint64_t>();
		}
		return g;
	}

	// What an instance may copy (c:spawn): a prefab its parameters name
	// ("prefab:<name>"), and an entity it reaches that is no scene, app or
	// player ("entity:<id>"), each with how many entities a copy makes
	std::map<ss_, size_t> copy_sizes(const Entity &e, size_t comp)
	{
		std::map<ss_, size_t> out;
		if(comp >= e.comps.size())
			return out;
		const Instance &in = e.comps[comp];
		const json::Value &decl = m_types[in.type].decl.get("params");
		if(decl.is_object())
			for(json::Iterator it(decl); it; ++it){
				if(jstr(*it, "type") != "prefab")
					continue;
				const ss_ n = jstr(in.params, it.key().c_str());
				const json::Value *pf = n.empty() ? nullptr : prefab(n);
				if(pf)
					out["prefab:"+n] = pf->get("entities").size();
			}
		for(uint64_t id : reach(e, comp, "")){
			auto it = m_entities.find(id);
			if(it == m_entities.end() || !it->second.kind.empty())
				continue;
			const size_t n = group_of(id).size();
			if(n)
				out["entity:"+itos(id)] = n;
		}
		return out;
	}

	size_t made_count()
	{
		size_t n = 0;
		for(auto &p : m_entities)
			n += p.second.made ? 1 : 0;
		return n;
	}

	// c:spawn {ref, pos, id}: a copy of a prefab or of an entity the
	// instance reaches (it and what is under it), in its scene at pos (its
	// own position if none), ids from id. Play state: a game change, or a
	// build of the player who set the run off for a type with `builds`
	// ("Always keep builds": the start's at once). Each instance's
	// on_start runs
	void spawn(uint64_t maker, size_t comp, const ss_ &by, const json::Value &s)
	{
		Entity &e = m_entities[maker];
		const ss_ ref = jstr_at(s, 0);
		auto refuse = [&](const ss_ &why){
			log_w(MODULE, "Entity %s: a copy of %s refused: %s",
					cs(itos(maker)), cs(ref.substr(0, 140)), cs(why));
			add_log(maker, "a copy of "+ref.substr(0, 140)+" refused: "+why);
		};
		if(comp >= e.comps.size())
			return;
		const auto sizes = copy_sizes(e, comp);
		auto si = sizes.find(ref);
		if(si == sizes.end())
			return refuse("not one it reaches");
		if(made_count() + si->second > MAX_MADE ||
				m_entities.size() + si->second > MAX_ENTITIES)
			return refuse("the round has made "+itos(MAX_MADE)+" entities");
		json::Value pf;
		ss_ name;
		double base[3] = {0, 0, 0};
		if(ref.compare(0, 7, "prefab:") == 0){
			name = ref.substr(7);
			pf = prefab(name)->deepcopy();
		} else {
			const sv_<uint64_t> g = group_of(strtoull(ref.c_str() + 7,
					nullptr, 10));
			const Entity &src = m_entities[g[0]];
			if(src.has_pos)
				for(int k = 0; k < 3; k++)
					base[k] = src.pos[k];
			pf = group_prefab(g, base);
		}
		const json::Value &pos = s.at(1u);
		if(pos_ok(pos)){
			for(unsigned k = 0; k < 3; k++)
				base[k] = pos.at(k).as_number();
		} else if(e.has_pos){
			for(int k = 0; k < 3; k++)
				base[k] = e.pos[k];
		} else {
			return refuse("no position: its own, or pos");
		}
		ss_ scene;
		scene_of(e, &scene);
		const uint64_t sc = scene_entity(scene);
		if(!sc)
			return refuse("it is in no scene");
		const uint64_t first = s.at(2u).is_number() ?
				(uint64_t)std::max(0.0, s.at(2u).as_number()) : 0;
		if(first < m_next_id)
			return refuse("its ids are taken");
		sv_<json::Value> rows;
		instantiate(pf, name, sc, base, first, rows);
		m_next_id = first + rows.size();
		const Type &t = m_types[e.comps[comp].type];
		const uint64_t pid = player_id(by);
		const char origin = t.builds && pid ? 'b' : 'g';
		const bool keep = origin == 'b' && always_keep();
		for(const json::Value &row : rows)
			m_pending_ids.insert((uint64_t)json::jint(row, "id", 0));
		sv_<uint64_t> made;
		for(const json::Value &row : rows){
			Entity n;
			ss_ why;
			if(!entity_from_json(row, n, why) || m_entities.count(n.id) ||
					(!m_entities.count(n.parent) &&
					!m_pending_ids.count(n.parent))){
				refuse("a member does not load: "+why);
				continue;
			}
			if(!keep){
				n.made = origin;
				n.made_by = origin == 'b' ? m_entities[pid].name : "";
				n.maker = maker;
				n.maker_comp = comp;
			}
			m_entities[n.id] = n;
			made.push_back(n.id);
		}
		m_pending_ids.clear();
		for(uint64_t id : made){
			Entity &n = m_entities[id];
			// Its state its types' defaults, as a new entity's
			for(Instance &in : n.comps){
				const json::Value &sd = m_types[in.type].decl.get("state");
				in.state = json::object();
				if(sd.is_object())
					for(json::Iterator it(sd); it; ++it)
						in.state.set(it.key(), (*it).get("default"));
			}
			if(n.has_pos)
				make_node(n);
			for(size_t i = 0; i < n.comps.size(); i++){
				Run r;
				r.entity = id;
				r.comp = i;
				r.handler = "on_start";
				r.by = by;
				queue_run(r);
			}
		}
		if(keep)
			m_store->set("authored", authored_json().stringify());
		m_runtime_dirty = true;
		ss_ ids;
		for(uint64_t id : made)
			ids += (ids.empty() ? "" : ",")+itos(id);
		log_i(MODULE, "Entity %s made a copy of %s: %s (%s)", cs(itos(maker)),
				cs(ref), cs(ids), keep ? "a build, kept as made" :
				origin == 'b' ? cs("a build of "+m_entities[pid].name) :
				"a game change");
		add_log(maker, "made a copy of "+ref+": "+ids);
		if(!made.empty())
			for(auto &p : m_peers)
				if(p.second.editing)
					send_state(p.first);
	}

	// An entity's handler run at once (on_remove, before it goes), each of
	// its instances that has it
	void run_now(uint64_t id, const char *handler, const ss_ &by)
	{
		for(size_t i = 0; ; i++){
			auto it = m_entities.find(id);
			if(it == m_entities.end() || i >= it->second.comps.size())
				return;
			if(!m_types[it->second.comps[i].type].handlers.count(handler))
				continue;
			Run r;
			r.entity = id;
			r.comp = i;
			r.handler = handler;
			r.by = by;
			run(r);
		}
	}

	// c:remove: an entity the instance reaches, with what is under it, out
	// of the round, each one's on_remove first. One made in play is gone;
	// an authored one comes back at Stop (a game change, or a build of the
	// player who set it off for a type with `builds`, which "Keep them"
	// takes out of the start)
	void remove_entity(uint64_t maker, size_t comp, const ss_ &by, uint64_t id)
	{
		auto mi = m_entities.find(maker);
		const char *why = mi == m_entities.end() ? "its remover is gone" :
				!m_entities.count(id) ? "it is not there" :
				!m_entities[id].kind.empty() ? "a scene, app or player" :
				!reach(mi->second, comp, by).count(id) ? "not one it reaches" :
				nullptr;
		if(why){
			log_w(MODULE, "Entity %s: a removal of %s refused: %s",
					cs(itos(maker)), cs(itos(id)), why);
			if(mi != m_entities.end())
				add_log(maker, "remove "+itos(id)+" refused: "+why);
			return;
		}
		const uint64_t pid = player_id(by);
		const char origin = m_types[mi->second.comps[comp].type].builds &&
				pid ? 'b' : 'g';
		sv_<uint64_t> g = group_of(id, MAX_ENTITIES);
		// A prefab copy made in play goes whole, by its first member
		const Entity &target = m_entities[id];
		if(target.made && json::jint(target.prefab, "copy", 0) == (int64_t)id){
			sv_<uint64_t> others;
			for(auto &p : m_entities)
				if(p.first != id && p.second.made &&
						json::jint(p.second.prefab, "copy", 0) == (int64_t)id)
					others.push_back(p.first);
			for(uint64_t o : others)
				for(uint64_t x : group_of(o, MAX_ENTITIES))
					if(std::find(g.begin(), g.end(), x) == g.end())
						g.push_back(x);
		}
		if(m_remove_depth < MAX_REMOVE_DEPTH){
			m_remove_depth++;
			for(uint64_t x : g)
				run_now(x, "on_remove", by);
			m_remove_depth--;
		}
		size_t n = 0;
		bool authored_gone = false;
		for(auto x = g.rbegin(); x != g.rend(); ++x){
			auto it = m_entities.find(*x);
			if(it == m_entities.end())
				continue;
			remove_node(it->second);
			it->second.node = 0;
			if(!it->second.made){
				if(origin == 'b' && always_keep()){
					// A build kept as made: out of the start too
					authored_gone = true;
				} else {
					Removed rm;
					rm.e = it->second;
					rm.origin = origin;
					rm.by = origin == 'b' ? m_entities[pid].name : "";
					m_removed[*x] = rm;
				}
			}
			m_entities.erase(it);
			n++;
		}
		if(authored_gone)
			m_store->set("authored", authored_json().stringify());
		m_runtime_dirty = true;
		log_i(MODULE, "Entity %s removed %s (%zu entities, %s)",
				cs(itos(maker)), cs(itos(id)), n, origin == 'b' ?
				cs("a build of "+player_of(by)) : "a game change");
		if(m_entities.count(maker))
			add_log(maker, "removed "+itos(id));
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
	}

	// ---- Prefabs ([KIT] stage 4d): api.h says what one is

	// A prefab by its name: the save's row (a builder's) over the file;
	// null when there is none or it does not read (logged once)
	const json::Value* prefab(const ss_ &name)
	{
		auto it = m_prefabs.find(name);
		if(it != m_prefabs.end())
			return &it->second;
		const size_t slash = name.find('/');
		if(slash == ss_::npos || !name_ok(name.substr(0, slash)) ||
				!name_ok(name.substr(slash + 1)) || m_bad_prefabs.count(name) ||
				m_prefab_loading.count(name))
			return nullptr;
		ss_ src;
		if(!m_store || !m_store->get("prefab:"+name, src)){
			const ss_ dir = author_path(name.substr(0, slash));
			if(!dir.empty())
				src = read_file(dir+"/"+name.substr(slash + 1)+".prefab.json");
		}
		if(src.empty() || src.size() > MAX_TYPE_SOURCE)
			return nullptr;
		const json::Value j = json::load_string(src.c_str());
		ss_ why;
		m_prefab_loading.insert(name);
		const bool ok = check_prefab(j, why);
		m_prefab_loading.erase(name);
		if(!ok){
			log_w(MODULE, "Prefab %s does not load: %s", cs(name), cs(why));
			m_bad_prefabs.insert(name);
			return nullptr;
		}
		m_prefabs[name] = j;
		return &m_prefabs[name];
	}

	// A prefab's file as Kit takes it: its members, their parents earlier
	// members, their types, parameters and links as an authored entity's
	bool check_prefab(const json::Value &j, ss_ &why)
	{
		if(!j.is_object() || jstr(j, "format") != "kit_prefab"){
			why = "not a JSON object of \"format\": \"kit_prefab\"";
			return false;
		}
		const json::Value &v = j.get("version");
		if(!v.is_undefined() && (!v.is_number() || v.as_number() < 1 ||
				v.as_number() > 1e9 || v.as_number() != std::floor(
				v.as_number()))){
			why = "its version is a whole number from 1";
			return false;
		}
		const json::Value &es = j.get("entities");
		if(!es.is_array() || es.size() < 1 || es.size() > MAX_PREFAB){
			why = "1 to "+itos(MAX_PREFAB)+" entities";
			return false;
		}
		std::set<int64_t> ids;
		for(unsigned i = 0; i < es.size(); i++){
			const json::Value &e = es.at(i);
			const int64_t id = json::jint(e, "id", 0);
			const int64_t parent = json::jint(e, "parent", 0);
			if(id < 1 || id > (int64_t)MAX_PREFAB || ids.count(id)){
				why = "a member's id is 1..."+itos(MAX_PREFAB)+", once";
				return false;
			}
			if(parent && !ids.count(parent)){
				why = "member "+itos(id)+"'s parent is no earlier member";
				return false;
			}
			if(!jstr(e, "kind").empty() || (!e.get("pos").is_undefined() &&
					!pos_ok(e.get("pos")))){
				why = "member "+itos(id)+" is no plain entity with a position";
				return false;
			}
			ids.insert(id);
		}
		for(unsigned i = 0; i < es.size(); i++){
			const json::Value &e = es.at(i);
			const ss_ who = "member "+itos(json::jint(e, "id", 0));
			const json::Value &cs_ = e.get("components");
			if(!cs_.is_array() || cs_.size() > 16){
				why = who+": a list of at most 16 components";
				return false;
			}
			for(unsigned k = 0; k < cs_.size(); k++){
				const json::Value &c = cs_.at(k);
				const ss_ type = full_type(jstr(c, "type"));
				if(!load_type(type, why)){
					why = who+": "+why;
					return false;
				}
				if(m_types[type].player){
					why = who+": "+type+" is a player's";
					return false;
				}
				const json::Value &decl = m_types[type].decl.get("params");
				const json::Value &ps = c.get("params");
				if(ps.is_object())
					for(json::Iterator it(ps); it; ++it){
						const json::Value &d = decl.get(it.key());
						ss_ bad;
						if(!d.is_object())
							bad = "not a parameter of it";
						else if(jstr(d, "type") == "entity")
							bad = (*it).is_number() && ((*it).as_number() == 0 ||
									ids.count((int64_t)(*it).as_number())) ? "" :
									"a member's id or 0";
						else
							bad = check_param(d, *it);
						if(!bad.empty()){
							why = who+": "+type+"'s "+it.key()+" is "+bad;
							return false;
						}
					}
				const json::Value &ls = c.get("links");
				for(unsigned m = 0; m < ls.size(); m++){
					const json::Value &l = ls.at(m);
					if(!m_types[type].outputs.count(jstr(l, "output")) ||
							!ids.count(json::jint(l, "to", 0)) ||
							!name_ok(jstr(l, "input"))){
						why = who+": a link from an output of "+type+" to a "
								"member's input";
						return false;
					}
				}
			}
		}
		return true;
	}

	// The placeable prefabs: Kit's and the app's files, the builders' rows
	void load_prefab_palette()
	{
		std::set<ss_> names;
		for(const ss_ &author : {ss_("kit"), m_author}){
			const ss_ dir = author_path(author);
			if(dir.empty())
				continue;
			for(const auto &n : interface::fs::list_directory(dir)){
				const size_t dot = n.name.rfind(".prefab.json");
				if(!n.is_directory && dot != ss_::npos && dot + 12 ==
						n.name.size())
					names.insert(author+"/"+n.name.substr(0, dot));
			}
		}
		for(const ss_ &k : m_store->list("prefab:"))
			names.insert(k.substr(7));
		ss_ list;
		for(const ss_ &n : names)
			if(prefab(n)){
				m_prefab_palette.insert(n);
				list += (list.empty() ? "" : " ")+n;
			}
		log_i(MODULE, "Prefabs: %s", list.empty() ? "none" : cs(list));
	}

	// Entities as a prefab: members 1... in the order given (a parent
	// before its children), positions from `base`, links and entity
	// parameters among them made the members', others left out
	json::Value group_prefab(const sv_<uint64_t> &ids, const double base[3])
	{
		std::map<uint64_t, int64_t> local;
		for(size_t i = 0; i < ids.size(); i++)
			local[ids[i]] = (int64_t)i + 1;
		auto member = [&](uint64_t id) -> int64_t {
			auto it = local.find(id);
			return it == local.end() ? 0 : it->second;
		};
		json::Value es = json::array();
		for(uint64_t id : ids){
			const Entity &src = m_entities[id];
			json::Value j = json::object();
			j.set("id", member(id));
			j.set("parent", member(src.parent));
			j.set("name", src.name);
			if(src.has_pos){
				json::Value pos = json::array();
				for(int k = 0; k < 3; k++)
					pos.append(src.pos[k] - base[k]);
				j.set("pos", pos);
				if(src.yaw != 0)
					j.set("yaw", src.yaw);
			}
			json::Value comps = json::array();
			for(const Instance &in : src.comps){
				json::Value cj = json::object(), ls = json::array();
				cj.set("type", in.type);
				cj.set("version", in.version);
				json::Value params = in.params.deepcopy();
				const json::Value &decl = m_types[in.type].decl.get("params");
				if(decl.is_object())
					for(json::Iterator it(decl); it; ++it)
						if(jstr(*it, "type") == "entity"){
							const json::Value &v = in.params.get(it.key());
							params.set(it.key(), member(v.is_number() &&
									v.as_number() > 0 ? (uint64_t)v.as_number() :
									0));
						}
				cj.set("params", params);
				for(const Link &l : in.links){
					if(!member(l.to))
						continue;
					json::Value lj = json::object();
					lj.set("output", l.output);
					lj.set("to", member(l.to));
					lj.set("input", l.input);
					ls.append(lj);
				}
				cj.set("links", ls);
				comps.append(cj);
			}
			j.set("components", comps);
			es.append(j);
		}
		json::Value pf = json::object();
		pf.set("format", "kit_prefab");
		pf.set("version", (int64_t)1);
		pf.set("entities", es);
		return pf;
	}

	// A prefab's copy as entities' rows, ids from `first` in its order,
	// under `scene` (or their parent among them), positions from `base`,
	// links and entity parameters to the new ids. name: the prefab's (each
	// member remembers it), "" for an entity's copy
	void instantiate(const json::Value &pf, const ss_ &name, uint64_t scene,
			const double base[3], uint64_t first, sv_<json::Value> &out)
	{
		const json::Value &es = pf.get("entities");
		std::map<int64_t, uint64_t> ids;
		for(unsigned i = 0; i < es.size(); i++)
			ids[json::jint(es.at(i), "id", 0)] = first + i;
		auto map = [&](const json::Value &v) -> int64_t {
			const int64_t l = v.is_number() ? (int64_t)v.as_number() : 0;
			auto it = ids.find(l);
			return it == ids.end() ? 0 : (int64_t)it->second;
		};
		for(unsigned i = 0; i < es.size(); i++){
			const json::Value &m = es.at(i);
			const int64_t lid = json::jint(m, "id", 0);
			json::Value e = json::object();
			e.set("id", (int64_t)ids[lid]);
			const int64_t parent = map(m.get("parent"));
			e.set("parent", parent ? parent : (int64_t)scene);
			e.set("name", jstr(m, "name"));
			if(pos_ok(m.get("pos"))){
				json::Value pos = json::array();
				for(unsigned k = 0; k < 3; k++)
					pos.append(grid(base[k] + m.get("pos").at(k).as_number()));
				e.set("pos", pos);
				// simplified: each member keeps its own turn; the copy is
				// not turned as a whole
				if(m.get("yaw").is_number())
					e.set("yaw", norm_yaw(m.get("yaw").as_number()));
			}
			json::Value comps = json::array();
			const json::Value &cs_ = m.get("components");
			for(unsigned k = 0; k < cs_.size(); k++){
				const json::Value &c = cs_.at(k);
				const ss_ type = full_type(jstr(c, "type"));
				json::Value cj = json::object(), ls = json::array();
				cj.set("type", type);
				if(c.get("version").is_number())
					cj.set("version", c.get("version"));
				json::Value params = c.get("params").is_object() ?
						c.get("params").deepcopy() : json::object();
				const json::Value &decl = m_types[type].decl.get("params");
				if(decl.is_object())
					for(json::Iterator it(decl); it; ++it)
						if(jstr(*it, "type") == "entity" &&
								!params.get(it.key()).is_undefined())
							params.set(it.key(), map(params.get(it.key())));
				cj.set("params", params);
				const json::Value &links = c.get("links");
				for(unsigned l = 0; l < links.size(); l++){
					const int64_t to = map(links.at(l).get("to"));
					if(!to)
						continue;
					json::Value lj = json::object();
					lj.set("output", jstr(links.at(l), "output"));
					lj.set("to", to);
					lj.set("input", jstr(links.at(l), "input"));
					ls.append(lj);
				}
				cj.set("links", ls);
				comps.append(cj);
			}
			e.set("components", comps);
			if(!name.empty()){
				json::Value pi = json::object();
				pi.set("of", name);
				pi.set("version", json::jint(pf, "version", 1));
				pi.set("member", lid);
				pi.set("copy", (int64_t)first);
				e.set("prefab", pi);
			}
			out.push_back(e);
		}
	}

	// {"op": "place", "prefab": name, "pos": [x, y, z]}: a copy of the
	// prefab in the editor's scene, its members' ids the next ones
	bool place_prefab(const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what,
			ss_ &why)
	{
		const ss_ name = jstr(j, "prefab");
		const json::Value *pf = prefab(name);
		if(!pf){
			why = "no prefab \""+name.substr(0, 130)+"\"";
			return false;
		}
		if(!pos_ok(j.get("pos"))){
			why = "pos: three numbers within "+itos((int)MAX_COORD);
			return false;
		}
		const uint64_t scene = scene_entity(p.scene);
		if(!scene){
			why = "the editor is in no scene of the composition's";
			return false;
		}
		const size_t n = pf->get("entities").size();
		if(m_entities.size() + n > MAX_ENTITIES){
			why = "the composition has "+itos(MAX_ENTITIES)+" entities";
			return false;
		}
		double base[3];
		for(unsigned k = 0; k < 3; k++)
			base[k] = grid(j.get("pos").at(k).as_number());
		sv_<json::Value> rows;
		instantiate(*pf, name, scene, base, m_next_id, rows);
		for(const json::Value &row : rows)
			change.push_back(std::make_pair((uint64_t)json::jint(row, "id", 0),
					row));
		what = "placed prefab "+name+" as "+itos(m_next_id)+"..."+
				itos(m_next_id + rows.size() - 1);
		m_next_id += rows.size();
		return true;
	}

	// The positional authored entities of `ids` (1 to MAX_PREFAB, none
	// twice), or false with why
	bool group_arg(const json::Value &j, sv_<uint64_t> &group, ss_ &why)
	{
		const json::Value &ids = j.get("ids");
		if(!ids.is_array() || ids.size() < 1 || ids.size() > MAX_PREFAB){
			why = "ids: 1 to "+itos(MAX_PREFAB)+" entities";
			return false;
		}
		for(unsigned i = 0; i < ids.size(); i++){
			json::Value a = json::object();
			a.set("id", ids.at(i));
			Entity *e = entity_arg(a, "id", why);
			if(!e)
				return false;
			if(!e->has_pos || !e->kind.empty()){
				why = "entity "+itos(e->id)+" has no position to move";
				return false;
			}
			if(std::find(group.begin(), group.end(), e->id) == group.end())
				group.push_back(e->id);
		}
		return true;
	}

	// [KIT] stage 4e2: {"op": "move", "ids": [n...], "by": [dx, dy, dz],
	// "turn": degrees}: entities moved together, one edit (an editor's drag
	// of its selection), turned round y about their middle (the mean of
	// their positions) and each by as much
	bool move_group(const json::Value &j,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what,
			ss_ &why)
	{
		sv_<uint64_t> group;
		if(!group_arg(j, group, why))
			return false;
		const json::Value &by = j.get("by");
		if(!by.is_undefined() && !pos_ok(by)){
			why = "by: three numbers within "+itos((int)MAX_COORD);
			return false;
		}
		const json::Value &turn = j.get("turn");
		if(!turn.is_undefined() && (!turn.is_number() ||
				!std::isfinite(turn.as_number()))){
			why = "turn: a number of degrees";
			return false;
		}
		double d[3] = {0, 0, 0}, mid[3] = {0, 0, 0};
		for(unsigned k = 0; by.is_array() && k < 3; k++)
			d[k] = by.at(k).as_number();
		for(uint64_t id : group)
			for(int k = 0; k < 3; k++)
				mid[k] += m_entities[id].pos[k] / group.size();
		const double a = turn.is_number() ? turn.as_number() : 0;
		// Urho3D's turn round y: +z towards +x
		const double r = a * 3.14159265358979323846 / 180, c = std::cos(r), sn = std::sin(r);
		for(uint64_t id : group){
			const Entity &e = m_entities[id];
			const double rx = e.pos[0] - mid[0], rz = e.pos[2] - mid[2];
			double np[3] = {mid[0] + rx * c + rz * sn + d[0], e.pos[1] + d[1],
					mid[2] - rx * sn + rz * c + d[2]};
			json::Value after = entity_json(e), pos = json::array();
			for(int k = 0; k < 3; k++){
				if(std::fabs(np[k]) > MAX_COORD){
					why = "entity "+itos(id)+" would go past "+
							itos((int)MAX_COORD);
					return false;
				}
				pos.append(grid(np[k]));
			}
			after.set("pos", pos);
			if(a != 0)
				after.set("yaw", norm_yaw(e.yaw + a));
			change.push_back(std::make_pair(id, after));
		}
		ss_ list;
		for(uint64_t id : group)
			list += (list.empty() ? "" : " ")+itos(id);
		json::Value bv = json::array();
		for(int k = 0; k < 3; k++)
			bv.append(d[k]);
		what = "moved "+list+" by "+bv.stringify()+(a != 0 ? ", turned "+
				json::Value(a).stringify() : ss_());
		return true;
	}

	// [KIT] stage 4e2: {"op": "duplicate", "ids": [n...], "by": [dx, dy,
	// dz]}: a copy of the entities that far off, their links and entity
	// parameters among them made the copies' (a prefab copy's copy is a
	// plain one)
	bool duplicate(const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what,
			ss_ &why)
	{
		sv_<uint64_t> group;
		if(!group_arg(j, group, why))
			return false;
		for(uint64_t id : group)
			for(auto &o : m_entities)
				if(o.second.parent == id){
					why = "entity "+itos(id)+" has entities under it";
					return false;
				}
		const json::Value &by = j.get("by");
		if(!pos_ok(by)){
			why = "by: three numbers within "+itos((int)MAX_COORD);
			return false;
		}
		if(m_entities.size() + group.size() > MAX_ENTITIES){
			why = "the composition has "+itos(MAX_ENTITIES)+" entities";
			return false;
		}
		const uint64_t scene = scene_entity(p.scene);
		if(!scene){
			why = "the editor is in no scene of the composition's";
			return false;
		}
		std::sort(group.begin(), group.end());
		const Entity &first = m_entities[group[0]];
		double base[3];
		for(int k = 0; k < 3; k++)
			base[k] = first.pos[k];
		const json::Value pf = group_prefab(group, base);
		for(int k = 0; k < 3; k++)
			base[k] += by.at(k).as_number();
		sv_<json::Value> rows;
		instantiate(pf, "", scene, base, m_next_id, rows);
		for(json::Value &row : rows){
			// Named as a placed one is
			const json::Value &cs_ = row.get("components");
			if(cs_.size())
				row.set("name", jstr(cs_.at(0), "type")+" "+
						itos(json::jint(row, "id", 0)));
			change.push_back(std::make_pair((uint64_t)json::jint(row, "id", 0),
					row));
		}
		what = "duplicated "+itos(group.size())+" as "+itos(m_next_id)+"..."+
				itos(m_next_id + rows.size() - 1);
		m_next_id += rows.size();
		return true;
	}

	// How deep an entity is under the root
	int depth(uint64_t id)
	{
		int d = 0;
		for(auto it = m_entities.find(id); it != m_entities.end() && d < 64 &&
				it->second.parent && it->first != 1; d++)
			it = m_entities.find(it->second.parent);
		return d;
	}

	// A prefab copy's member (its id in the prefab) as an entity, or 0
	uint64_t copy_member(int64_t copy, int64_t member)
	{
		for(auto &e : m_entities)
			if(json::jint(e.second.prefab, "copy", 0) == copy &&
					json::jint(e.second.prefab, "member", 0) == member)
				return e.first;
		return 0;
	}

	// {"op": "save_prefab", "ids": [n...], "name": n}: those entities a
	// prefab "<the builder's name>/<n>" (a new version of it if it is
	// there), in the save, placeable from then on; they are a copy of it,
	// and every other copy follows it: each member's parameters the
	// prefab's, but those set on that copy (its overrides)
	// simplified: a copy follows the parameters; members and links added
	// or gone are not, nor a prefab of files (Kit's, the app's)
	bool save_prefab(const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what,
			ss_ &why)
	{
		const ss_ short_name = jstr(j, "name");
		if(!name_ok(short_name)){
			why = "name: letters, digits and _";
			return false;
		}
		ss_ author = p.name.substr(0, 64);
		for(char &c : author)
			if(!isalnum((unsigned char)c))
				c = '_';
		if(author.empty() || author == "kit"){
			why = "a builder's prefabs are under their name, and it is \""+
					author+"\"";
			return false;
		}
		const ss_ name = author+"/"+short_name;
		const json::Value &ids = j.get("ids");
		if(!ids.is_array() || ids.size() < 1 || ids.size() > MAX_PREFAB){
			why = "ids: 1 to "+itos(MAX_PREFAB)+" entities";
			return false;
		}
		sv_<uint64_t> group;
		for(unsigned i = 0; i < ids.size(); i++){
			json::Value a = json::object();
			a.set("id", ids.at(i));
			Entity *e = entity_arg(a, "id", why);
			if(!e)
				return false;
			if(!e->kind.empty()){
				why = "entity "+itos(e->id)+" is a "+e->kind;
				return false;
			}
			if(std::find(group.begin(), group.end(), e->id) == group.end())
				group.push_back(e->id);
		}
		std::sort(group.begin(), group.end(), [&](uint64_t a, uint64_t b){
			const int da = depth(a), db = depth(b);
			return da != db ? da < db : a < b;
		});
		double base[3] = {0, 0, 0};
		const Entity &first = m_entities[group[0]];
		if(first.has_pos)
			for(int k = 0; k < 3; k++)
				base[k] = first.pos[k];
		json::Value pf = group_prefab(group, base);
		m_bad_prefabs.erase(name);
		const json::Value *old = prefab(name);
		const int64_t version = old ? json::jint(*old, "version", 1) + 1 : 1;
		pf.set("author", author);
		pf.set("name", short_name);
		pf.set("version", version);
		if(!check_prefab(pf, why))
			return false;
		m_store->set("prefab:"+name, pf.stringify());
		m_prefabs[name] = pf;
		m_prefab_palette.insert(name);
		std::set<uint64_t> in_group(group.begin(), group.end());
		for(size_t i = 0; i < group.size(); i++){
			Entity copy = m_entities[group[i]];
			json::Value pi = json::object();
			pi.set("of", name);
			pi.set("version", version);
			pi.set("member", (int64_t)i + 1);
			pi.set("copy", (int64_t)group[0]);
			copy.prefab = pi;
			for(Instance &in : copy.comps)
				in.overrides.clear();
			change.push_back(std::make_pair(copy.id, entity_json(copy)));
		}
		size_t updated = 0;
		const json::Value &members = pf.get("entities");
		for(auto &e : m_entities){
			if(in_group.count(e.first) || !authored(e.second) ||
					jstr(e.second.prefab, "of") != name)
				continue;
			const int64_t lid = json::jint(e.second.prefab, "member", 0);
			const int64_t copy_id = json::jint(e.second.prefab, "copy", 0);
			json::Value m;
			for(unsigned i = 0; i < members.size(); i++)
				if(json::jint(members.at(i), "id", 0) == lid)
					m = members.at(i);
			if(m.is_undefined())
				continue;
			Entity copy = e.second;
			const json::Value &mc = m.get("components");
			for(size_t c = 0; c < copy.comps.size() && c < mc.size(); c++){
				Instance &in = copy.comps[c];
				if(full_type(jstr(mc.at((unsigned)c), "type")) != in.type)
					continue;
				const json::Value &np = mc.at((unsigned)c).get("params");
				const json::Value &decl = m_types[in.type].decl.get("params");
				if(np.is_object())
					for(json::Iterator it(np); it; ++it){
						if(in.overrides.count(it.key()))
							continue;
						json::Value v = *it;
						if(jstr(decl.get(it.key()), "type") == "entity")
							v = json::Value((int64_t)copy_member(copy_id,
									v.is_number() ? (int64_t)v.as_number() : 0));
						in.params.set(it.key(), v);
					}
			}
			copy.prefab = e.second.prefab.deepcopy();
			copy.prefab.set("version", version);
			change.push_back(std::make_pair(copy.id, entity_json(copy)));
			updated++;
		}
		what = "saved prefab "+name+" version "+itos(version)+" of "+
				itos(group.size())+" entities ("+itos(updated)+" entities of "
				"other copies follow it)";
		return true;
	}
	// ---- Debugging for novices ([KIT] stage 4d): each entity's log

	void add_log(uint64_t id, const ss_ &line)
	{
		if(!id)
			return;
		// The game clock's minutes and seconds
		char t[32];
		const double sec = std::fmod(interface::os::game_us() / 1e6, 3600);
		snprintf(t, sizeof t, "%02d:%04.1f ", (int)(sec / 60),
				std::fmod(sec, 60));
		std::deque<ss_> &l = m_logs[id];
		l.push_back(t+line.substr(0, 200));
		while(l.size() > LOG_LINES)
			l.pop_front();
		m_log_dirty.insert(id);
	}

	// The log of the entity a builder has selected, to them: whole as they
	// select it, then as it grows
	void send_log(size_t peer)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end() || !pi->second.editing || !pi->second.sel)
			return;
		json::Value j = json::object(), lines = json::array();
		j.set("id", (int64_t)pi->second.sel);
		for(const ss_ &l : m_logs[pi->second.sel])
			lines.append(l);
		j.set("lines", lines);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:log", j.stringify());
		});
	}

	// At a tick's end: the builders are sent the signals that passed along
	// links (their lines light up), and their selection's new log lines
	void send_debug()
	{
		sv_<size_t> editors;
		for(auto &p : m_peers)
			if(p.second.editing)
				editors.push_back(p.first);
		if(!editors.empty() && m_flows.size()){
			const ss_ data = m_flows.stringify();
			network::access(m_server, [&](network::Interface *inetwork){
				for(size_t peer : editors)
					inetwork->send(peer, "kit:flow", data);
			});
		}
		m_flows = json::array();
		for(size_t peer : editors)
			if(m_log_dirty.count(m_peers[peer].sel))
				send_log(peer);
		m_log_dirty.clear();
	}
	// The peer a player's name is, in a scene (0: none)
	size_t peer_of(const ss_ &name, const ss_ &scene)
	{
		for(auto &p : m_peers)
			if(p.second.name == name && p.second.scene == scene)
				return p.first;
		return 0;
	}

	// c:teleport(pos): the player who set the run off, in the entity's
	// scene, moved by the app. A component moves no one else
	void teleport(const Entity &e, const ss_ &type, const ss_ &who,
			const json::Value &pos)
	{
		ss_ scene;
		scene_of(e, &scene);
		const size_t peer = who.empty() ? 0 : peer_of(who, scene);
		const char *why = !m_host.moves_players && !m_host.controls ?
				"the app moves no players" :
				who.empty() ? "no player set it off" :
				!peer ? "the player is not in its scene" :
				!pos_ok(pos) ? "not a position" : nullptr;
		if(why){
			log_w(MODULE, "Entity %s's %s: a teleport refused: %s",
					cs(itos(e.id)), cs(type), why);
			return;
		}
		const double x = pos.at(0u).as_number(), y = pos.at(1u).as_number(),
				z = pos.at(2u).as_number();
		log_i(MODULE, "Entity %s's %s teleports %s to (%g, %g, %g)",
				cs(itos(e.id)), cs(type), cs(who), x, y, z);
		if(m_host.controls)
			put_player(peer, x, y, z);
		else
			m_server->emit_event("kit:move_player", new MovePlayer(peer, x, y, z));
	}

	// ---- The players' inventory: count, add, take and list (api.h), Kit's
	// own counts (m_items) unless one component replaces them

	// The replacing provider: the first authored instance (by entity id)
	// whose type has inventory = true; another is refused, logged once
	void pick_provider()
	{
		const uint64_t was = m_provider;
		const size_t was_comp = m_provider_comp;
		m_provider = 0;
		m_provider_comp = 0;
		for(auto &p : m_entities){
			if(!authored(p.second))
				continue;
			for(size_t i = 0; i < p.second.comps.size(); i++){
				const Instance &in = p.second.comps[i];
				if(!m_types[in.type].inventory)
					continue;
				if(!m_provider){
					m_provider = p.first;
					m_provider_comp = i;
					continue;
				}
				const ss_ k = itos(p.first)+"/"+itos(i)+"/"+in.type;
				if(m_inv_refused.insert(k).second)
					log_w(MODULE, "Entity %s's %s would provide the players' "
							"inventory, which entity %s's %s does: refused (one "
							"replacing provider at a time)", cs(itos(p.first)),
							cs(in.type), cs(itos(m_provider)), cs(m_entities[
							m_provider].comps[m_provider_comp].type));
			}
		}
		if(m_provider != was || m_provider_comp != was_comp)
			log_i(MODULE, "The players' inventory: %s", m_provider ?
					cs("entity "+itos(m_provider)+"'s "+m_entities[m_provider].
					comps[m_provider_comp].type) : "each player entity's own");
	}

	// The replacing provider's instance, running (not disabled), or null
	Instance* provider()
	{
		auto it = m_entities.find(m_provider);
		if(it == m_entities.end() || m_provider_comp >= it->second.comps.size())
			return nullptr;
		Instance &in = it->second.comps[m_provider_comp];
		return in.disabled.empty() ? &in : nullptr;
	}

	// A player's inventory ([KIT] stage 4d): the replacing provider, else
	// their entity's own (Kit's kit/inventory), running; null for neither.
	// id and comp: whose
	Instance* provider_for(uint64_t player, uint64_t &id, size_t &comp)
	{
		Instance *pv = provider();
		if(pv){
			id = m_provider;
			comp = m_provider_comp;
			return pv;
		}
		Instance *own = player ? own_inventory(player) : nullptr;
		if(!own || !own->disabled.empty())
			return nullptr;
		id = player;
		comp = own - &m_entities[player].comps[0];
		return own;
	}

	// A run's inventory calls done: the player's items as the provider
	// lists them now, sent to their client
	void got_items(const Entity &e, const ss_ &type, const ss_ &who,
			const json::Value &items)
	{
		json::Value mine = json::object();
		if(items.is_object())
			for(json::Iterator it(items); it; ++it){
				const double n = (*it).is_number() ? (*it).as_number() : 0;
				if(name_ok(it.key()) && n >= 1 && n <= MAX_ITEMS &&
						n == std::floor(n))
					mine.set(it.key(), (int64_t)n);
			}
		log_i(MODULE, "Entity %s's %s: %s has %s", cs(itos(e.id)), cs(type),
				cs(who), cs(mine.stringify()));
		send_items(who, mine);
	}

	// A player's items to their client: as given, or their entity's own
	// inventory's ("items" of Kit's kit/inventory)
	// simplified: under a replacing provider a client is sent its list
	// only after a run that touched it, not as it joins
	void send_items(const ss_ &who, json::Value mine = json::Value())
	{
		if(mine.is_undefined()){
			auto it = m_players.find(who);
			const Instance *own = it == m_players.end() ? nullptr :
					own_inventory(it->second);
			mine = own ? own->state.get("items") : json::object();
		}
		const ss_ data = mine.is_object() ? mine.stringify() : "{}";
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &p : m_peers)
				if(p.second.name == who)
					inetwork->send(p.first, "kit:items", data);
		});
	}
	// ---- Grants (api.h's can_dig, can_place)

	// Whether an instance in the peer's scene grants them key ("dig" or
	// "place") at the cell: its type's `grants` box holds the cell and its
	// state's key is true
	bool granted(size_t peer, const char *key, int x, int y, int z)
	{
		auto pi = m_peers.find(peer);
		// Stopped, the world is the start: only a builder changes it
		if(!m_hosted || pi == m_peers.end() || !m_session.running)
			return false;
		for(auto &p : m_entities){
			const Entity &e = p.second;
			if(!e.has_pos)
				continue;
			for(const Instance &in : e.comps){
				const Type &t = m_types[in.type];
				if(t.grants.empty() || !in.disabled.empty() ||
						!in.state.get(key).is_true())
					continue;
				ss_ scene;
				scene_of(e, &scene);
				if(scene != pi->second.scene)
					continue;
				int n[3];
				extent(in.params.get(t.grants), n);
				const pv::Vector3DInt32 o = voxel_p(e);
				if(x >= o.getX() && x < o.getX() + n[0] && y >= o.getY() &&
						y < o.getY() + n[1] && z >= o.getZ() &&
						z < o.getZ() + n[2])
					return true;
			}
		}
		return false;
	}

	bool can_dig(size_t peer, int x, int y, int z)
	{
		return granted(peer, "dig", x, y, z);
	}

	bool can_place(size_t peer, int x, int y, int z)
	{
		return granted(peer, "place", x, y, z);
	}

	static bool loaded(voxelworld::Instance *world, const pv::Vector3DInt32 &p)
	{
		const pv::Vector3DInt16 ss = world->get_section_size_voxels();
		auto div = [](int32_t a, int b){
			return (int16_t)std::floor((double)a / b);
		};
		return world->is_section_loaded(pv::Vector3DInt16(div(p.getX(),
				ss.getX()), div(p.getY(), ss.getY()), div(p.getZ(), ss.getZ())));
	}

	// A voxel an instance sets: false if its section is not loaded yet
	bool set_voxel(const Write &w)
	{
		bool done = true;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *world = ivw->get_instance(w.scene);
			if(!world)
				return;
			if(!loaded(world, w.p)){
				done = false;
				return;
			}
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			interface::VoxelName name;
			name.block_name = w.voxel;
			const interface::VoxelDefinition *def = reg->get(name);
			if(!def){
				log_w(MODULE, "No voxel type %s", cs(w.voxel));
				return;
			}
			uint32_t word = 0;
			reg->get_format().id.set(word, def->id);
			world->set_voxel(w.p, interface::VoxelInstance(word));
			mark(world, w.scene, w.p, w.origin, w.origin == 'b' ?
					player_of(w.by) : w.by);
			log_v(MODULE, "Voxel (%i,%i,%i) set to %s by %s", w.p.getX(),
					w.p.getY(), w.p.getZ(), cs(w.voxel), cs(w.by));
		});
		return done;
	}

	// Timers due on the game's clock: on_timer(c), as by whoever set it off
	void run_timers()
	{
		const int64_t now = interface::os::game_us();
		for(auto &p : m_entities)
			for(size_t i = 0; i < p.second.comps.size(); i++){
				Instance &in = p.second.comps[i];
				if(in.due_us < 0 || now < in.due_us)
					continue;
				in.due_us = -1;
				m_runtime_dirty = true;
				Run r;
				r.entity = p.first;
				r.comp = i;
				r.handler = "on_timer";
				r.by = in.due_by.empty() ? "app" : in.due_by;
				queue_run(r);
			}
	}

	// Zones: a type's `zone` (a position parameter, its extent in cells
	// from the entity's own up and on) and who stands in it, the players
	// as the app placed them (the cell their position rounds to):
	// on_enter(c, by) and on_leave(c, by) as that changes. Leaving the
	// server is leaving the zone, and joining inside one enters it (4d's
	// answer, user 2026-10-30: a scoring zone guards re-entry itself); so
	// is a restart: those not back yet leave
	void check_zones()
	{
		for(auto &p : m_entities){
			Entity &e = p.second;
			if(!e.has_pos)
				continue;
			for(size_t i = 0; i < e.comps.size(); i++){
				Instance &in = e.comps[i];
				const Type &t = m_types[in.type];
				if(t.zone.empty() || !in.disabled.empty())
					continue;
				ss_ scene;
				scene_of(e, &scene);
				int n[3];
				extent(in.params.get(t.zone), n);
				const pv::Vector3DInt32 o = voxel_p(e);
				// Who is in it, by their entity's id
				std::set<ss_> now;
				for(auto &pp : m_peers){
					const Peer &peer = pp.second;
					if(peer.scene != scene || !peer.player)
						continue;
					bool inside = true;
					for(int k = 0; k < 3; k++){
						const double c = std::floor(peer.pos[k] + 0.5) -
								(k == 0 ? o.getX() : k == 1 ? o.getY() : o.getZ());
						inside = inside && c >= 0 && c < n[k];
					}
					if(inside)
						now.insert(itos(peer.player));
				}
				auto fire = [&](const char *handler, const ss_ &id){
					Run r;
					r.entity = e.id;
					r.comp = i;
					r.handler = handler;
					r.by = "player:"+id;
					r.args.append(r.by);
					queue_run(r);
				};
				if(now == in.inside)
					continue;
				for(const ss_ &id : now)
					if(!in.inside.count(id))
						fire("on_enter", id);
				for(const ss_ &id : in.inside)
					if(!now.count(id))
						fire("on_leave", id);
				in.inside.swap(now);
				m_runtime_dirty = true;
			}
		}
	}

	// A player placed for the first time (or as another name): Running,
	// through the round's start (round_join); and their items
	void joined(size_t peer)
	{
		const Peer &p = m_peers[peer];
		log_i(MODULE, "%s joined %s as entity %s", cs(p.name), cs(p.scene),
				cs(itos(p.player)));
		// Their entity, and the client parts of the types ([KIT] stage 4d)
		json::Value you = json::object(), parts = json::object();
		you.set("id", (int64_t)p.player);
		for(auto &t : m_types)
			if(!t.second.client.empty())
				parts.set(t.first, t.second.client);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:client_parts", parts.stringify());
			inetwork->send(peer, "kit:you", you.stringify());
		});
		if(m_session.running)
			round_join(peer, false);
		else
			send_items(p.name);
		send_state(peer);
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_hosted || !m_box)
			return;
		m_box->poll();
		flush_copies();
		// Writes into the start, made as their sections load: Running,
		// kept past the round's Stop
		for(size_t n = m_start_writes.size(); n > 0; n--){
			Write w = m_start_writes.front();
			m_start_writes.pop_front();
			w.origin = 'k';
			if(!set_voxel(w))
				m_start_writes.push_back(w);
		}
		save_marks();
		// [KIT] stage 4h: the bodies step Stopped too, first, out of the
		// tick's budget
		const int64_t budget = m_box ? m_box->budget() / SLICE_DIV *
				TICK_SLICES : 0;
		int64_t spent = step_bodies(budget);
		send_controls();
		if(!m_session.running){
			// Stopped: components do not run. A write routed to one is
			// made by no one
			std::deque<Write> writes;
			{
				std::lock_guard<std::mutex> lock(m_writes_mutex);
				writes.swap(m_writes);
			}
			for(const Write &w : writes)
				log_i(MODULE, "A write routed to (%i,%i,%i) by %s: the server "
						"is Stopped, its component does not run", w.p.getX(),
						w.p.getY(), w.p.getZ(), cs(w.by));
			save_runtime();
			send_debug();
			return;
		}
		for(size_t n = m_pending_voxels.size(); n > 0; n--){
			Write w = m_pending_voxels.front();
			m_pending_voxels.pop_front();
			if(!set_voxel(w))
				m_pending_voxels.push_back(w);
		}
		// Writes routed to owned voxels: to the owner's on_voxel
		std::deque<Write> writes;
		{
			std::lock_guard<std::mutex> lock(m_writes_mutex);
			writes.swap(m_writes);
		}
		for(const Write &w : writes){
			bool owned = false;
			for(auto &p : m_entities){
				Entity &e = p.second;
				if(!e.has_pos || scene_of(e) != w.scene)
					continue;
				const auto cells = owned_cells(e);
				if(std::find(cells.begin(), cells.end(), w.p) == cells.end())
					continue;
				for(size_t i = 0; i < e.comps.size(); i++){
					if(!m_types[e.comps[i].type].owns_voxel)
						continue;
					owned = true;
					Run r;
					r.entity = e.id;
					r.comp = i;
					r.handler = "on_voxel";
					r.args.append(w.voxel);
					r.by = norm_by(w.by);
					r.args.append(r.by);
					queue_run(r);
				}
			}
			if(!owned)
				log_w(MODULE, "A write routed to (%i,%i,%i), which no entity "
						"owns now", w.p.getX(), w.p.getY(), w.p.getZ());
		}
		run_timers();
		check_zones();
		// The queue, in order, within the tick's budget
		while(!m_queue.empty() && spent < budget && m_box){
			const Run r = m_queue.front();
			m_queue.pop_front();
			spent += run(r);
		}
		if(!m_queue.empty())
			log_v(MODULE, "%zu runs wait for the next tick", m_queue.size());
		// simplified: the runtime row is written after each tick that
		// changed it; a write per interval is the upgrade if a busy world
		// makes it a cost
		save_runtime();
		save_marks();
		send_debug();
	}

	// ---- [KIT] stage 4h: the players' controls (Host::controls). Each
	// placed player has a body that a movement type steps (kit/walker; a
	// seat's own while they hold it: kit/car, kit/ball): `movement` says
	// its body, `step(s, i, dt, w, p)` its steps, in the box on this side
	// and in the client's own Lua for its prediction, both with
	// client_lua/move.lua's world. The client sends its inputs numbered
	// ("kit:input"), each one step at the movement's rate; the server steps
	// those it gets, no more than the clock allows, within the tick's
	// budget, and answers the state after the last ("kit:body", the input
	// it ends with); the client takes it and steps again those it sent
	// since (hillclimb's prediction). A put ("kit:body" with put) starts
	// it over. The camera, the pointer, the effects and the movement each
	// player has come in "kit:controls" (controls_for()), sent again as
	// they change.
	struct Body
	{
		bool put = false;
		ss_ type; // the movement stepping it now
		json::Value params = json::object();
		json::Value state = json::object();
		ss_ state_json = "{}";
		uint32_t ack = 0; // the last input stepped
		std::deque<std::pair<uint32_t, ss_>> inputs; // each a Lua literal
		double allowance = 0;
		int64_t last_us = 0;
		int64_t puts = 0;
		double home[3] = {0, 0, 0}; // the last put's cell
		uint64_t seat = 0; // the seat held (an entity, 0: none)
		bool failed = false; // a step's error logged
	};
	std::map<size_t, Body> m_bodies;
	sm_<size_t, ss_> m_controls_sent;
	// Vehicles moved in play, where they were: back at Stop
	std::map<uint64_t, std::array<double, 4>> m_seat_home;
	// The voxels' friction and surface where the material set has them
	// ({name: {friction, surface}}; read once)
	json::Value m_voxel_extra;
	bool m_voxel_extra_read = false;

	static const int MAX_INPUTS = 120; // queued, a body
	static const int BATCH = 8; // inputs a step request

	// A movement type: its file's `movement` and a step
	bool is_movement(const ss_ &type)
	{
		ss_ why;
		if(type.empty() || !load_type(type, why))
			return false;
		const Type &t = m_types[type];
		return t.decl.get("movement").is_object() && t.handlers.count("step");
	}

	// The first instance of a type on the app root (nullptr: none)
	const Instance* root_instance(const ss_ &type)
	{
		for(auto &p : m_entities){
			if(p.second.parent != 1 || p.second.has_pos)
				continue;
			for(const Instance &i : p.second.comps)
				if(i.type == type)
					return &i;
		}
		return nullptr;
	}

	// An instance's parameters over its type's defaults (nullptr: the
	// defaults), as the client gets them (JSON's own precision), so both
	// sides step with the same
	json::Value params_of(const ss_ &type, const Instance *in)
	{
		json::Value out = json::object();
		const json::Value &pd = m_types[type].decl.get("params");
		if(pd.is_object())
			for(json::Iterator it(pd); it; ++it){
				const json::Value &v = in ? in->params.get(it.key()) :
						json::Value();
				out.set(it.key(), v.is_undefined() ? (*it).get("default") : v);
			}
		return json::load_string(out.stringify().c_str());
	}

	json::Value controls_params()
	{
		ss_ why;
		if(!load_type("kit/controls", why))
			return json::object();
		return params_of("kit/controls", root_instance("kit/controls"));
	}

	// The movement a body has: its seat's, else the controls' choice
	void body_movement(Body &b, ss_ &type, json::Value &params)
	{
		if(b.seat){
			auto it = m_entities.find(b.seat);
			if(it != m_entities.end())
				for(const Instance &in : it->second.comps)
					if(is_movement(in.type)){
						type = in.type;
						params = params_of(in.type, &in);
						return;
					}
		}
		type = jstr(controls_params(), "movement", "kit/walker");
		if(!is_movement(type)){
			type = "";
			params = json::object();
			return;
		}
		params = params_of(type, root_instance(type));
	}

	static double num(const json::Value &v, const char *k, double def,
			double lo, double hi)
	{
		const json::Value &x = v.get(k);
		const double d = x.is_number() ? x.as_number() : def;
		return std::isfinite(d) ? std::max(lo, std::min(hi, d)) : def;
	}

	// The movement's body: {r, h, eye}
	json::Value body_decl(const ss_ &type)
	{
		const json::Value &m = m_types[type].decl.get("movement");
		return m.get("body").is_object() ? m.get("body") : json::object();
	}

	// The voxels' friction and surface where the material set gives them
	// simplified: a voxel's "friction" and "surface" in the material set's
	// JSON (the app's or Kit's materials.json); none: 1 and its name
	const json::Value& voxel_extra()
	{
		if(m_voxel_extra_read)
			return m_voxel_extra;
		m_voxel_extra_read = true;
		m_voxel_extra = json::object();
		const ss_ ms = m_host.materials.empty() ? read_file(
				m_server->get_module_path(MODULE)+"/materials.json") :
				m_host.materials;
		const json::Value j = json::load_string(ms.c_str());
		const json::Value &vs = j.get("voxels");
		if(vs.is_object())
			for(json::Iterator it(vs); it; ++it){
				const json::Value &f = (*it).get("friction");
				const ss_ s = jstr(*it, "surface");
				if(!f.is_number() && s.empty())
					continue;
				json::Value e = json::object();
				if(f.is_number())
					e.set("friction", f.as_number());
				if(!s.empty())
					e.set("surface", s);
				m_voxel_extra.set(it.key(), e);
			}
		return m_voxel_extra;
	}

	// What a peer's client controls with: the camera, the pointer, the
	// effects and the signals for them, the movement (its source, its
	// parameters, its body) and the seat
	json::Value controls_for(size_t peer)
	{
		json::Value c = json::object();
		const json::Value p = controls_params();
		c.set("params", p);
		// The signals' state, those for everyone and this player's
		const Instance *ci = root_instance("kit/controls");
		const Peer &pe = m_peers[peer];
		json::Value sig = json::object();
		if(ci && ci->state.is_object())
			for(json::Iterator it(ci->state); it; ++it){
				const ss_ by = jstr(*it, "by");
				if(jstr(p, "to") == "player" && !by.empty() && by != pe.name)
					continue;
				sig.set(it.key(), *it);
			}
		c.set("signals", sig);
		auto bi = m_bodies.find(peer);
		if(bi != m_bodies.end() && !bi->second.type.empty()){
			Body &b = bi->second;
			json::Value m = json::object();
			m.set("type", b.type);
			m.set("src", m_sources[b.type]);
			m.set("params", b.params);
			m.set("decl", m_types[b.type].decl.get("movement"));
			c.set("move", m);
			c.set("seat", (int64_t)b.seat);
		}
		c.set("voxels", voxel_extra());
		if(m_world_scene && m_wp.heightmap() && pe.scene == m_host.world_scene)
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_world_scene);
				if(!map)
					return;
				json::Value hm = json::array();
				hm.append(map->samples_x());
				hm.append(map->samples_z());
				c.set("hm", hm);
			});
		return c;
	}

	void send_controls()
	{
		if(!m_host.controls)
			return;
		for(auto &p : m_peers){
			if(!p.second.player)
				continue;
			const ss_ s = controls_for(p.first).stringify();
			ss_ &sent = m_controls_sent[p.first];
			if(s == sent)
				continue;
			sent = s;
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(p.first, "kit:controls", s);
			});
		}
	}

	// Where a body's state puts a peer (the middle of the cell their feet
	// are in: x and z as they are, the feet + 0.5), and their entity
	void body_moved(size_t peer, Body &b)
	{
		const json::Value &pos = b.state.get("pos");
		if(!pos.is_array() || pos.size() != 3)
			return;
		double v[3];
		for(unsigned k = 0; k < 3; k++){
			v[k] = pos.at(k).is_number() ? pos.at(k).as_number() : 0;
			if(!std::isfinite(v[k]))
				return;
		}
		if(b.seat){
			auto it = m_entities.find(b.seat);
			if(it != m_entities.end()){
				Entity &e = it->second;
				e.pos[0] = v[0];
				e.pos[1] = v[1] + 0.5;
				e.pos[2] = v[2];
				const json::Value &yaw = b.state.get("yaw");
				if(yaw.is_number() && std::isfinite(yaw.as_number()))
					e.yaw = norm_yaw(yaw.as_number());
				main_context::access(m_server, scene_of(e), [&](magic::Scene *sc){
					magic::Node *n = sc->GetNode(e.node);
					if(n){
						n->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
						n->SetRotation(magic::Quaternion(0, (float)e.yaw, 0));
					}
				});
			}
		}
		Peer &p = m_peers[peer];
		p.pos[0] = v[0];
		p.pos[1] = v[1] + 0.5;
		p.pos[2] = v[2];
		world_peer(peer, p.scene, p.pos[0], p.pos[1], p.pos[2]);
		place_player(p);
	}

	// A body put: its state new at the cell (its feet just over the cell's
	// bottom), the client told
	void put_body(size_t peer, Body &b, double x, double y, double z,
			double yaw = 0, const json::Value *state = nullptr)
	{
		body_movement(b, b.type, b.params);
		if(state){
			b.state = state->deepcopy();
		} else {
			b.state = json::object();
			json::Value pos = json::array();
			pos.append(x);
			pos.append(y - 0.45);
			pos.append(z);
			b.state.set("pos", pos);
			b.state.set("yaw", yaw);
			b.home[0] = x;
			b.home[1] = y;
			b.home[2] = z;
		}
		b.state = json::load_string(b.state.stringify().c_str());
		b.state_json = b.state.stringify();
		b.put = true;
		b.inputs.clear();
		b.allowance = 0;
		b.last_us = interface::os::time_us();
		b.failed = false;
		const int64_t n = ++b.puts;
		body_moved(peer, b);
		// The controls first: the client steps the put with the movement
		send_controls();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:body", "{\"put\":"+itos(n)+",\"ack\":"+
					itos(b.ack)+",\"s\":"+b.state_json+"}");
		});
	}

	void put_player(size_t peer, double x, double y, double z)
	{
		if(!m_host.controls || !m_peers.count(peer))
			return;
		Body &b = m_bodies[peer];
		if(b.seat)
			unseat(peer, b, false);
		log_i(MODULE, "%s put at (%g, %g, %g)", cs(m_peers[peer].name), x, y,
				z);
		put_body(peer, b, x, y, z);
	}

	// "kit:input": "<put>;<n> f r yaw jump go tx ty tz;..." (the inputs
	// after the last the client heard of, numbered on; put: the last put
	// it heard of, those of an earlier one dropped)
	void on_input(const network::Packet &packet)
	{
		auto bi = m_bodies.find(packet.sender);
		if(bi == m_bodies.end() || !bi->second.put ||
				packet.data.size() > 16384)
			return;
		Body &b = bi->second;
		const uint32_t last = b.inputs.empty() ? b.ack : b.inputs.back().first;
		uint32_t at = last;
		const ss_ &d = packet.data;
		size_t i = d.find(';');
		if(i == ss_::npos || atoll(d.substr(0, i).c_str()) != b.puts)
			return;
		i++;
		while(i < d.size()){
			size_t e = d.find(';', i);
			if(e == ss_::npos)
				e = d.size();
			const ss_ one = d.substr(i, std::min<size_t>(e - i, 200));
			i = e + 1;
			unsigned n = 0;
			double v[8];
			if(sscanf(one.c_str(), "%u %lf %lf %lf %lf %lf %lf %lf %lf", &n,
					&v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) != 9)
				continue;
			bool ok = n > at;
			for(int k = 0; k < 8; k++)
				ok = ok && std::isfinite(v[k]) && std::fabs(v[k]) <= MAX_COORD;
			if(!ok)
				continue;
			if(b.inputs.size() >= (size_t)MAX_INPUTS)
				break;
			at = n;
			ss_ o = "{f=";
			lua_lit(json::Value(std::max(-1.0, std::min(1.0, v[0]))), o);
			o += ",r=";
			lua_lit(json::Value(std::max(-1.0, std::min(1.0, v[1]))), o);
			o += ",yaw=";
			lua_lit(json::Value(v[2]), o);
			o += ",jump=";
			o += v[3] != 0 ? "1" : "0";
			o += ",go=";
			o += v[4] != 0 ? "1" : "0";
			o += ",tx=";
			lua_lit(json::Value(v[5]), o);
			o += ",ty=";
			lua_lit(json::Value(v[6]), o);
			o += ",tz=";
			lua_lit(json::Value(v[7]), o);
			o += "}";
			b.inputs.push_back(std::make_pair(n, o));
		}
	}

	// The world round a body for a step: its cells, the solid looks near
	// it and a heightmap's samples (move.lua's snapshot)
	void snapshot(ss_ &o, const Peer &pe, const Body &b, const double pos[3],
			double r, double h, double reach)
	{
		auto si = m_host.scenes.find(pe.scene);
		const main_context::SceneReference scene =
				si == m_host.scenes.end() ? nullptr : si->second;
		// As far as the batch may go (reach, m) and a cell more: the cells
		// past it read as air (a request's text is dear in the box)
		const int R = (int)std::ceil(r + reach) + 1, down = (int)std::ceil(reach) + 2;
		const int x0 = (int)std::floor(pos[0] + 0.5) - R,
				z0 = (int)std::floor(pos[2] + 0.5) - R,
				y0 = (int)std::floor(pos[1] + 0.5) - down;
		const int nx = 2 * R + 1, nz = 2 * R + 1,
				ny = down + (int)std::ceil(h + reach) + 2;
		ss_ cells((size_t)nx * ny * nz, '.');
		json::Value classes = json::array();
		std::map<uint32_t, char> cls;
		const json::Value &extra = voxel_extra();
		if(scene)
			voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
				voxelworld::Instance *w = ivw->get_instance(scene);
				if(!w)
					return;
				interface::VoxelRegistry *reg = w->get_voxel_reg();
				const auto &fmt = reg->get_format();
				const interface::VoxelVolume vol = w->get_volume(pv::Region(
						pv::Vector3DInt32(x0, y0, z0), pv::Vector3DInt32(x0 + nx - 1,
						y0 + ny - 1, z0 + nz - 1)));
				for(int y = 0; y < ny; y++)
				for(int z = 0; z < nz; z++)
				for(int x = 0; x < nx; x++){
					const uint32_t id = (uint32_t)fmt.id.get(vol.getVoxelAt(
							x0 + x, y0 + y, z0 + z).data);
					char ch = '.';
					if(id == interface::VOXELTYPEID_UNDEFINED){
						ch = '?';
					} else {
						auto c = cls.find(id);
						if(c != cls.end()){
							ch = c->second;
						} else {
							const interface::VoxelDefinition *def = reg->get(id);
							if(def && def->physically_solid && classes.size() < 190){
								const ss_ name = def->name.block_name;
								json::Value k = json::array();
								k.append(name);
								k.append(true);
								const json::Value &x = extra.get(name);
								k.append(x.get("friction").is_number() ?
										x.get("friction") : json::Value(1.0));
								k.append(jstr(x, "surface"));
								classes.append(k);
								ch = (char)(64 + classes.size());
							}
							cls[id] = ch;
						}
					}
					cells[x + (size_t)nx * (z + (size_t)nz * y)] = ch;
				}
			});
		o += "{x0="+itos(x0)+",y0="+itos(y0)+",z0="+itos(z0)+",nx="+itos(nx)+
				",ny="+itos(ny)+",nz="+itos(nz)+",cells=";
		lua_lit(json::Value(cells), o);
		o += ",classes=";
		lua_lit(classes, o);
		// The solid looks near it (the seat held none)
		o += ",looks={";
		for(auto &p : m_entities){
			const Entity &e = p.second;
			if(!e.has_pos || e.id == b.seat || e.kind == "player" ||
					std::fabs(e.pos[0] - pos[0]) > R + 8 ||
					std::fabs(e.pos[2] - pos[2]) > R + 8 ||
					std::fabs(e.pos[1] - pos[1]) > ny + 8)
				continue;
			ss_ es;
			if(scene_of(e, &es) != scene || !scene)
				continue;
			for(const Instance &in : e.comps){
				const json::Value &d = m_types[in.type].decl.get("look");
				if(d.is_undefined())
					continue;
				const json::Value look = look_of(in, d);
				const ss_ key = jstr(look, "state");
				const bool on = !key.empty() && in.state.get(key).is_true();
				o += "{";
				lua_lit(look, o);
				o += on ? ",true,{" : ",false,{";
				for(int k = 0; k < 3; k++){
					lua_lit(json::Value(e.pos[k]), o);
					o += ',';
				}
				o += "},";
				lua_lit(json::Value(e.yaw), o);
				o += "},";
				break;
			}
		}
		o += "}";
		if(m_world_scene && m_wp.heightmap() && scene == m_world_scene)
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_world_scene);
				if(!map)
					return;
				const int hx0 = std::max(0, x0), hz0 = std::max(0, z0);
				const int hx1 = std::min(map->samples_x() - 1, x0 + nx),
						hz1 = std::min(map->samples_z() - 1, z0 + nz);
				if(hx1 < hx0 || hz1 < hz0)
					return;
				o += ",hm={x0="+itos(hx0)+",z0="+itos(hz0)+",nx="+
						itos(hx1 - hx0 + 1)+",nz="+itos(hz1 - hz0 + 1)+",h={";
				char buf[32];
				for(int z = hz0; z <= hz1; z++)
					for(int x = hx0; x <= hx1; x++){
						snprintf(buf, sizeof buf, "%.9g,", map->height_at(x, z));
						o += buf;
					}
				o += "}}";
			});
		o += "}";
	}

	// The bodies' inputs stepped, the clock's worth for each, within the
	// tick's budget: what it spent
	int64_t step_bodies(int64_t budget)
	{
		int64_t spent = 0;
		const int64_t now = interface::os::time_us();
		for(auto &bp : m_bodies){
			Body &b = bp.second;
			auto pi = m_peers.find(bp.first);
			if(!b.put || b.type.empty() || pi == m_peers.end())
				continue;
			const double rate = num(b.params, "rate", 60, 10, 120);
			// A twentieth over the clock: a client's that runs a little fast
			// is not held back
			b.allowance = std::min(rate * 0.5 + BATCH, b.allowance +
					(now - b.last_us) / 1e6 * rate * 1.05);
			b.last_us = now;
			bool stepped = false;
			while(!b.inputs.empty() && b.allowance >= 1 && spent < budget &&
					m_box){
				const json::Value bd = body_decl(b.type);
				const double r = num(bd, "r", 0.45, 0.05, 8),
						h = num(bd, "h", 1.7, 0.05, 16);
				double pos[3] = {0, 0, 0};
				const json::Value &sp = b.state.get("pos");
				for(unsigned k = 0; k < 3 && sp.is_array() && k < sp.size(); k++)
					pos[k] = sp.at(k).is_number() ? sp.at(k).as_number() : 0;
				ss_ o = "Sreturn {type=";
				lua_lit(json::Value(b.type), o);
				o += ",params=";
				lua_lit(b.params, o);
				o += ",state=";
				lua_lit(b.state, o);
				o += ",dt=";
				lua_lit(json::Value(1.0 / rate), o);
				o += ",sub="+itos((int64_t)num(b.params, "substeps", 1, 1, 8));
				o += ",inputs={";
				uint32_t last = b.ack;
				int n_in = 0;
				for(; n_in < BATCH && !b.inputs.empty() &&
						b.allowance >= 1; n_in++){
					o += b.inputs.front().second+",";
					last = b.inputs.front().first;
					b.inputs.pop_front();
					b.allowance -= 1;
				}
				o += "},world=";
				// The speed now and what a batch may add to it
				double v2 = 0;
				const json::Value &sv = b.state.get("vel");
				for(unsigned k = 0; k < 3 && sv.is_array() && k < sv.size(); k++)
					if(sv.at(k).is_number())
						v2 += sv.at(k).as_number() * sv.at(k).as_number();
				const double reach = std::min(16.0, (std::sqrt(v2) + 10) *
						n_in / rate);
				snapshot(o, pi->second, b, pos, r, h, reach);
				o += "}";
				ss_ answer, why;
				bool runaway = false;
				int64_t used = 0;
				const bool ok = box_call(o, answer, why, &runaway, &used);
				spent += used;
				if(!ok){
					if(!b.failed)
						log_w(MODULE, "%s's body (%s): %s", cs(pi->second.name),
								cs(b.type), cs(why));
					b.failed = true;
					b.inputs.clear();
					break;
				}
				b.ack = last;
				b.state = json::load_string(answer.c_str());
				b.state_json = answer;
				stepped = true;
			}
			if(!stepped)
				continue;
			// Out of the World's region: back where it was put
			const json::Value &sp = b.state.get("pos");
			if(sp.is_array() && sp.size() == 3 && sp.at(1).is_number() &&
					sp.at(1).as_number() < WORLD_SECTION_Y0 * WORLD_SECTION - 8){
				log_i(MODULE, "%s fell out of the world", cs(pi->second.name));
				if(b.seat)
					unseat(bp.first, b, false);
				put_body(bp.first, b, b.home[0], b.home[1], b.home[2]);
				continue;
			}
			body_moved(bp.first, b);
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(bp.first, "kit:body", "{\"ack\":"+itos(b.ack)+
						",\"s\":"+b.state_json+"}");
			});
		}
		return spent;
	}

	// Possession: a seat (a type with `seat = true` and a movement) used
	// takes the player's controls until they leave it ("kit:exit")
	bool seat_type(const Entity &e)
	{
		for(const Instance &in : e.comps)
			if(m_types[in.type].decl.get("seat").is_true() && is_movement(in.type))
				return true;
		return false;
	}

	void seat(size_t peer, uint64_t id)
	{
		Body &b = m_bodies[peer];
		Entity &e = m_entities[id];
		for(auto &o : m_bodies)
			if(o.second.seat == id){
				log_i(MODULE, "Entity %s: %s is in it already", cs(itos(id)),
						cs(m_peers[o.first].name));
				return;
			}
		if(b.seat)
			unseat(peer, b, false);
		if(!m_seat_home.count(id))
			m_seat_home[id] = {{e.pos[0], e.pos[1], e.pos[2], e.yaw}};
		b.seat = id;
		json::Value st = json::object(), pos = json::array();
		pos.append(e.pos[0]);
		pos.append(e.pos[1] - 0.5);
		pos.append(e.pos[2]);
		st.set("pos", pos);
		st.set("yaw", e.yaw);
		log_i(MODULE, "%s takes the seat of entity %s", cs(m_peers[peer].name),
				cs(itos(id)));
		put_body(peer, b, 0, 0, 0, 0, &st);
	}

	// Out of the seat: beside it (its right, its left, behind, on it),
	// standing; put: the client told
	void unseat(size_t peer, Body &b, bool put = true)
	{
		const uint64_t id = b.seat;
		b.seat = 0;
		auto it = m_entities.find(id);
		log_i(MODULE, "%s leaves the seat of entity %s", cs(m_peers[peer].name),
				cs(itos(id)));
		if(!put || it == m_entities.end())
			return;
		const Entity &e = it->second;
		const double a = e.yaw * 3.14159265358979323846 / 180;
		double r = 1;
		for(const Instance &in : e.comps)
			if(is_movement(in.type))
				r = num(body_decl(in.type), "r", 1, 0.05, 8);
		const double d = r + 1;
		double x = e.pos[0] + std::cos(a) * d, z = e.pos[2] - std::sin(a) * d;
		const double y = std::floor(e.pos[1] + 0.5);
		put_body(peer, b, x, y, z);
	}

	void on_exit(const network::Packet &packet)
	{
		auto bi = m_bodies.find(packet.sender);
		if(bi == m_bodies.end() || !bi->second.seat)
			return;
		unseat(packet.sender, bi->second);
	}

	// Stop: everyone out of the seats, the vehicles back
	void seats_home()
	{
		for(auto &bp : m_bodies)
			if(bp.second.seat)
				unseat(bp.first, bp.second);
		for(auto &h : m_seat_home){
			auto it = m_entities.find(h.first);
			if(it == m_entities.end())
				continue;
			Entity &e = it->second;
			for(int k = 0; k < 3; k++)
				e.pos[k] = h.second[k];
			e.yaw = h.second[3];
			main_context::access(m_server, scene_of(e), [&](magic::Scene *sc){
				magic::Node *n = sc->GetNode(e.node);
				if(n){
					n->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
					n->SetRotation(magic::Quaternion(0, (float)e.yaw, 0));
				}
			});
		}
		m_seat_home.clear();
	}

	// ---- Clients act

	void on_use(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const ss_ data = packet.data.substr(0, 32);
		char *end = nullptr;
		const uint64_t id = strtoull(data.c_str(), &end, 10);
		auto refuse = [&](const ss_ &why){
			log_i(MODULE, "A use of entity %s by peer %zu refused: %s",
					cs(data), peer, cs(why));
		};
		if(!m_hosted)
			return refuse("Kit is not hosted");
		if(!m_session.running)
			return refuse("the server is Stopped");
		if(data.empty() || !end || *end)
			return refuse("not an entity's id");
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return refuse("the app has not placed the player");
		auto it = m_entities.find(id);
		if(it == m_entities.end() || !it->second.has_pos)
			return refuse("no such object");
		Entity &e = it->second;
		ss_ scene;
		scene_of(e, &scene);
		if(scene != pi->second.scene)
			return refuse("in another scene");
		double d2 = 0;
		for(int k = 0; k < 3; k++)
			d2 += (e.pos[k] - pi->second.pos[k]) * (e.pos[k] - pi->second.pos[k]);
		if(d2 > m_host.use_range * m_host.use_range)
			return refuse("out of range");
		bool any = false;
		// [KIT] stage 4h: a seat taken
		if(m_host.controls && seat_type(e) && m_bodies[peer].put &&
				m_bodies[peer].seat != id){
			seat(peer, id);
			any = true;
		}
		for(size_t i = 0; i < e.comps.size(); i++){
			const Type &t = m_types[e.comps[i].type];
			if(!t.usable || !t.handlers.count("on_use"))
				continue;
			any = true;
			Run r;
			r.entity = id;
			r.comp = i;
			r.handler = "on_use";
			r.by = by_of(pi->second.name);
			r.args.append(r.by);
			queue_run(r);
		}
		if(!any)
			return refuse("nothing on it is usable");
		log_i(MODULE, "Entity %s used by %s", cs(itos(id)),
				cs(pi->second.name));
	}

	void on_left(const network::OldClient &old)
	{
		const bool was_editing = m_peers.count(old.info.id) &&
				m_peers[old.info.id].editing;
		const uint64_t player = m_peers.count(old.info.id) ?
				m_peers[old.info.id].player : 0;
		const bool guest = m_peers.count(old.info.id) &&
				m_peers[old.info.id].guest;
		const ss_ name = m_peers.count(old.info.id) ?
				m_peers[old.info.id].name : "";
		m_bodies.erase(old.info.id);
		m_controls_sent.erase(old.info.id);
		m_peers.erase(old.info.id);
		if(player)
			unplace_player(player);
		if(guest)
			drop_guest(name);
		if(m_world_peers.erase(old.info.id))
			world_load_points();
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
		if(was_editing)
			send_builders();
	}

	void set_peer(size_t peer, const ss_ &name, const ss_ &scene,
			double x, double y, double z)
	{
		Peer &p = m_peers[peer];
		const bool join = p.name != name || p.scene != scene;
		if(p.name != name){
			const bool was = p.editing;
			tools(p, peer, false);
			if(was)
				send_builders();
			// The admins' list of who is here
			for(auto &o : m_peers)
				if(o.second.editing && o.first != peer)
					send_state(o.first);
		}
		const bool renamed = p.name != name;
		const ss_ old_name = p.name;
		const bool was_guest = p.guest;
		p.name = name;
		p.scene = scene;
		// [KIT] stage 4h: a body put is where it is
		if(!m_host.controls || !m_bodies[peer].put){
			p.pos[0] = x;
			p.pos[1] = y;
			p.pos[2] = z;
		}
		// A guest: no account (where builtin/accounts is; without it
		// nobody is one)
		if(renamed)
			p.guest = m_server->has_module("accounts") &&
					account_of(peer).empty();
		world_peer(peer, scene, p.pos[0], p.pos[1], p.pos[2]);
		if(!m_hosted)
			return;
		// Their entity follows them ([KIT] stage 4d)
		const uint64_t was = p.player;
		p.player = name.empty() ? 0 : ensure_player(name);
		if(was && was != p.player)
			unplace_player(was);
		if(renamed && was_guest)
			drop_guest(old_name);
		place_player(p);
		if(join)
			joined(peer);
	}

	// [KIT] 4d's answer (user, 2026-10-30): a guest's player entity is
	// dropped when they leave or log in, not kept in the runtime row
	void drop_guest(const ss_ &name)
	{
		auto it = m_players.find(name);
		if(name.empty() || it == m_players.end())
			return;
		const uint64_t id = it->second;
		for(auto &p : m_peers)
			if(p.second.player == id)
				return;
		auto e = m_entities.find(id);
		if(e != m_entities.end()){
			remove_node(e->second);
			m_entities.erase(e);
		}
		m_players.erase(it);
		m_aside.del_key(name);
		m_gone_guests["player:"+itos(id)] = name;
		// Written now: a shutdown can come before the next tick's save
		m_runtime_dirty = true;
		save_runtime();
		log_i(MODULE, "Guest %s's entity %s dropped", cs(name), cs(itos(id)));
	}

	void input(uint64_t entity, const ss_ &input, const ss_ &value)
	{
		deliver(entity, input, value.empty() ? json::null() :
				json::load_string(value.c_str()), "app", 0);
	}

	ss_ get_state(uint64_t entity, size_t component, const ss_ &key)
	{
		auto it = m_entities.find(entity);
		if(it == m_entities.end() || component >= it->second.comps.size())
			return "";
		const json::Value &v = it->second.comps[component].state.get(key);
		return v.is_undefined() ? "" : v.stringify();
	}

	// ---- The editor (api.h: edit mode, the packet kit:edit)

	void set_editor(const ss_ &player, bool can)
	{
		m_rights[player] = can;
		log_i(MODULE, "%s %s edit rights (the app's)", cs(player),
				can ? "has" : "has no");
		recheck_rights();
	}

	// The accounts' name of a peer and whether it is the server's admin
	// (the launcher's own user is): "" and false without builtin/accounts
	ss_ account_of(size_t peer, bool *admin = nullptr)
	{
		ss_ name;
		bool a = false;
		if(m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *i){
				name = i->name_of(peer);
				a = i->is_local(peer) || (!name.empty() && i->is_admin(name));
			});
		if(admin)
			*admin = a;
		return name;
	}

	bool is_builder(const ss_ &account)
	{
		bool b = false;
		if(!account.empty() && m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *i){
				b = i->has_priv(account, "builder");
			});
		return b;
	}

	// Edit rights: the app's word for the name it gave the player, else
	// builtin/accounts': the admin, and the accounts the admin made
	// builders. By the peer's account, not the app's name for it: a name
	// the app makes up may be someone's account
	bool can_edit(size_t peer)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return false;
		auto o = m_rights.find(pi->second.name);
		if(o != m_rights.end())
			return o->second;
		bool admin = false;
		const ss_ name = account_of(peer, &admin);
		return admin || is_builder(name);
	}

	// An editor who lost the rights leaves edit mode; the admins' lists
	// of who is a builder are sent again
	void recheck_rights()
	{
		bool left = false;
		for(auto &p : m_peers){
			if(!p.second.editing)
				continue;
			if(!can_edit(p.first)){
				tools(p.second, p.first, false);
				left = true;
				log_i(MODULE, "%s left edit mode: no edit rights now",
						cs(p.second.name));
			}
			send_state(p.first);
		}
		if(left)
			send_builders();
	}

	// The player is told, so a new builder's client says it may edit now
	void on_privs(const accounts::Login &login)
	{
		recheck_rights();
		auto pi = m_peers.find(login.peer);
		if(pi != m_peers.end() && !pi->second.editing)
			send_state(login.peer);
	}

	// ---- Origins ([KIT] stage 4c): a round's builds, game changes and live
	// edits. A cell's mark is beside its section's copy; Stop reads them

	ss_ scene_name(main_context::SceneReference ref)
	{
		for(auto &s : m_host.scenes)
			if(s.second == ref)
				return s.first;
		return "";
	}

	// A voxel's id, where its section is loaded
	static bool voxel_id(voxelworld::Instance *w, const pv::Vector3DInt32 &p,
			uint32_t &id)
	{
		if(!loaded(w, p))
			return false;
		id = (uint32_t)w->get_voxel_reg()->get_format().id.get(
				w->get_voxel(p, true).data);
		return true;
	}

	static void set_id(voxelworld::Instance *w, const pv::Vector3DInt32 &p,
			uint32_t id)
	{
		uint32_t word = 0;
		w->get_voxel_reg()->get_format().id.set(word, id);
		w->set_voxel(p, interface::VoxelInstance(word));
	}

	// "<scene>:x,y,z", the section of a cell
	static ss_ section_key(const ss_ &scene, voxelworld::Instance *w,
			const pv::Vector3DInt32 &p)
	{
		const pv::Vector3DInt16 ss = w->get_section_size_voxels();
		return scene+":"+itos(div_floor(p.getX(), ss.getX()))+","+
				itos(div_floor(p.getY(), ss.getY()))+","+
				itos(div_floor(p.getZ(), ss.getZ()));
	}

	// "Always keep builds": keep_builds of the first between_plays instance
	// (kit/player_state)
	bool always_keep()
	{
		for(auto &p : m_entities)
			for(const Instance &in : p.second.comps)
				if(m_types[in.type].between_plays)
					return in.params.get("keep_builds").is_true();
		return false;
	}

	// A cell the round wrote to, as written: origin 'g' a game change (a
	// build's mark there goes: the game wrote last), 'b' a build by `who`
	// (kept as made with "Always keep builds"), 'k' kept as made. Running
	// only: Stopped, every write is the start's
	void mark(voxelworld::Instance *w, main_context::SceneReference ref,
			const pv::Vector3DInt32 &p, char origin, const ss_ &who)
	{
		if(!m_session.running)
			return;
		const ss_ scene = scene_name(ref);
		if(scene.empty())
			return;
		const ss_ key = section_key(scene, w, p);
		const auto c = std::make_tuple(p.getX(), p.getY(), p.getZ());
		if(origin == 'g' || who.empty()){
			auto it = m_marks.find(key);
			if(it != m_marks.end() && it->second.erase(c))
				m_marks_dirty.insert(key);
			return;
		}
		Mark m;
		if(!voxel_id(w, p, m.id))
			return;
		m.kind = origin == 'k' || always_keep() ? 'k' : 'b';
		m.by = who;
		m_marks[key][c] = m;
		m_marks_dirty.insert(key);
	}

	// The app's write for a player, their own dig or place: a build, or a
	// game change (build false), or with their tools on a live edit
	void player_wrote(size_t peer, int x, int y, int z, bool build)
	{
		auto pi = m_peers.find(peer);
		if(!m_hosted || !m_session.running || pi == m_peers.end())
			return;
		auto si = m_host.scenes.find(pi->second.scene);
		if(si == m_host.scenes.end())
			return;
		const char origin = pi->second.editing ? 'k' : build ? 'b' : 'g';
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *w = ivw->get_instance(si->second);
			if(w)
				mark(w, si->second, pv::Vector3DInt32(x, y, z), origin,
						pi->second.name);
		});
		log_v(MODULE, "(%i,%i,%i) by %s: %s", x, y, z, cs(pi->second.name),
				origin == 'k' ? "an edit" : origin == 'b' ? "a build" :
				"a game change");
	}

	void save_marks()
	{
		if(m_marks_dirty.empty() || !m_store)
			return;
		m_store->batch([&](){
			for(const ss_ &key : m_marks_dirty){
				auto it = m_marks.find(key);
				if(it == m_marks.end() || it->second.empty()){
					m_store->remove("marks:"+key);
					if(it != m_marks.end())
						m_marks.erase(it);
					continue;
				}
				json::Value j = json::object();
				for(auto &c : it->second){
					json::Value a = json::array();
					a.append(ss_(1, c.second.kind));
					a.append(c.second.by);
					a.append((int64_t)c.second.id);
					j.set(itos(std::get<0>(c.first))+","+
							itos(std::get<1>(c.first))+","+
							itos(std::get<2>(c.first)), a);
				}
				m_store->set("marks:"+key, j.stringify());
			}
		});
		m_marks_dirty.clear();
	}

	void load_marks()
	{
		for(const ss_ &k : m_store->list("marks:")){
			ss_ v;
			if(!m_store->get(k, v))
				continue;
			const json::Value j = json::load_string(v.c_str());
			if(!j.is_object())
				continue;
			auto &cells = m_marks[k.substr(6)];
			for(json::Iterator it(j); it; ++it){
				int x = 0, y = 0, z = 0;
				if(sscanf(it.key().c_str(), "%d,%d,%d", &x, &y, &z) != 3 ||
						!(*it).at(1u).is_string() || !(*it).at(2u).is_number())
					continue;
				Mark m;
				m.kind = jstr_at((*it), 0) == "k" ? 'k' : 'b';
				m.by = (*it).at(1u).as_string();
				m.id = (uint32_t)(*it).at(2u).as_number();
				cells[std::make_tuple(x, y, z)] = m;
			}
		}
	}

	static ss_ jstr_at(const json::Value &a, unsigned i)
	{
		return a.at(i).is_string() ? a.at(i).as_string() : ss_();
	}

	// Each builder's discarded builds, {name: cells}
	json::Value discarded_counts()
	{
		return discarded_counts(m_discarded);
	}

	static json::Value discarded_counts(const sv_<Discarded> &l)
	{
		json::Value n = json::object();
		for(const Discarded &d : l)
			n.set(d.by, n.get(d.by).is_number() ?
					(int64_t)n.get(d.by).as_number() + 1 : (int64_t)1);
		return n;
	}

	static ss_ counts_text(const json::Value &n)
	{
		ss_ s;
		for(json::Iterator it(n); it; ++it)
			s += (s.empty() ? "" : ", ")+it.key()+" "+(*it).stringify();
		return s;
	}

	void save_discarded()
	{
		if(m_discarded.empty()){
			m_store->remove("discarded");
			return;
		}
		json::Value a = json::array();
		for(const Discarded &d : m_discarded){
			json::Value j = json::object(), p = json::array();
			j.set("by", d.by);
			if(!d.entity.is_undefined()){
				j.set("entity", d.entity);
				j.set("removed", d.removed);
				a.append(j);
				continue;
			}
			for(int k = 0; k < 3; k++)
				p.append((int64_t)d.p[k]);
			j.set("scene", d.scene);
			j.set("p", p);
			j.set("id", (int64_t)d.id);
			a.append(j);
		}
		m_store->set("discarded", a.stringify());
	}

	void discarded_from(const json::Value &a)
	{
		for(unsigned i = 0; i < a.size(); i++){
			const json::Value &j = a.at(i);
			Discarded d;
			d.scene = jstr(j, "scene");
			d.by = jstr(j, "by");
			d.id = (uint32_t)json::jint(j, "id", 0);
			if(j.get("entity").is_object() && !d.by.empty()){
				d.entity = j.get("entity").deepcopy();
				d.removed = j.get("removed").is_true();
				m_discarded.push_back(d);
				continue;
			}
			if(!pos_ok(j.get("p")) || d.by.empty())
				continue;
			for(unsigned k = 0; k < 3; k++)
				d.p[k] = (int)j.get("p").at(k).as_number();
			m_discarded.push_back(d);
		}
	}

	// Cells put into the world as they were at Stop: how many could be
	// (a section not loaded is loaded for them, as a copy is)
	size_t put_cells(const sv_<Discarded> &cells)
	{
		size_t n = 0;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(const Discarded &d : cells){
				if(!d.entity.is_undefined())
					continue;
				auto si = m_host.scenes.find(d.scene);
				voxelworld::Instance *w = si == m_host.scenes.end() ? nullptr :
						ivw->get_instance(si->second);
				const pv::Vector3DInt32 p(d.p[0], d.p[1], d.p[2]);
				if(!w)
					continue;
				if(!loaded(w, p)){
					const pv::Vector3DInt16 ss = w->get_section_size_voxels();
					w->load_section_no_generate(pv::Vector3DInt16(
							div_floor(p.getX(), ss.getX()),
							div_floor(p.getY(), ss.getY()),
							div_floor(p.getZ(), ss.getZ())));
				}
				if(!loaded(w, p))
					continue;
				set_id(w, p, d.id);
				n++;
			}
		});
		return n;
	}

	// At Stop, before the copies are put back: each marked cell whose voxel
	// is still what its mark gave (else the game wrote it last), into
	// `kept` (kept as made) or m_discarded (builds). The marks go
	// simplified: a marked cell in a section unloaded by now is dropped
	void sort_marks(sv_<Discarded> &kept)
	{
		m_discarded.clear();
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(auto &sec : m_marks){
				const ss_ scene = sec.first.substr(0, sec.first.rfind(':'));
				auto si = m_host.scenes.find(scene);
				voxelworld::Instance *w = si == m_host.scenes.end() ? nullptr :
						ivw->get_instance(si->second);
				for(auto &c : sec.second){
					Discarded d;
					d.scene = scene;
					d.p[0] = std::get<0>(c.first);
					d.p[1] = std::get<1>(c.first);
					d.p[2] = std::get<2>(c.first);
					d.by = c.second.by;
					if(!w || !voxel_id(w, pv::Vector3DInt32(d.p[0], d.p[1],
							d.p[2]), d.id) || d.id != c.second.id)
						continue;
					(c.second.kind == 'k' ? kept : m_discarded).push_back(d);
				}
			}
		});
		drop_marks();
	}

	void drop_marks()
	{
		for(auto &sec : m_marks)
			m_marks_dirty.insert(sec.first);
		m_marks.clear();
		save_marks();
	}

	// The Stop notice: to each builder, and each player whose builds were
	// discarded, who built how many cells ("you" the one it is sent to)
	void send_discarded()
	{
		const json::Value counts = discarded_counts();
		// The rights first: accounts is not reached from inside network
		sv_<std::pair<size_t, ss_>> out;
		for(auto &p : m_peers){
			const bool can = can_edit(p.first);
			if(!can && !counts.get(p.second.name).is_number())
				continue;
			json::Value j = json::object();
			j.set("counts", counts);
			j.set("you", p.second.name);
			j.set("can_keep", can);
			out.push_back(std::make_pair(p.first, j.stringify()));
		}
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &o : out)
				inetwork->send(o.first, "kit:discarded", o.second);
		});
	}

	// {"op": "keep", "names": [name...]}: Stopped, the builds the last Stop
	// discarded put into the start (all, or those players'), each cell its
	// voxel at Stop. Until the next Play
	void keep(const Peer &p, const json::Value &j,
			const std::function<void(const ss_&)> &refuse)
	{
		if(m_session.running)
			return refuse("the server is Running: Stop discards and keeps");
		if(m_discarded.empty())
			return refuse("no builds discarded since the last Play");
		const json::Value &names = j.get("names");
		std::set<ss_> chosen;
		for(unsigned i = 0; i < names.size(); i++)
			if(names.at(i).is_string())
				chosen.insert(names.at(i).as_string());
		sv_<Discarded> put, rest;
		for(const Discarded &d : m_discarded)
			(!names.is_array() || chosen.count(d.by) ? put : rest).push_back(d);
		if(put.empty())
			return refuse("no builds of those players discarded");
		const size_t n = put_cells(put);
		// [KIT] stage 4d: entities made put into the start, those removed
		// taken out of it
		sv_<std::pair<uint64_t, json::Value>> change;
		size_t made = 0, removed = 0;
		for(const Discarded &d : put){
			if(d.entity.is_undefined())
				continue;
			const uint64_t id = (uint64_t)json::jint(d.entity, "id", 0);
			auto it = m_entities.find(id);
			if(d.removed && it != m_entities.end() && authored(it->second)){
				delete_change(id, change);
				removed++;
			} else if(!d.removed && it == m_entities.end()){
				change.push_back(std::make_pair(id, d.entity));
				made++;
			}
		}
		if(!change.empty())
			commit(change, nullptr);
		m_discarded.swap(rest);
		save_discarded();
		log_i(MODULE, "%s keeps the builds of %s: %zu cells put into the start, "
				"%zu entities made, %zu removed (%zu discarded left)", cs(p.name),
				cs(counts_text(discarded_counts(put))), n, made, removed,
				m_discarded.size());
		for(auto &o : m_peers)
			send_state(o.first);
	}

	// {"op": "always_keep", "on": bool}: "Always keep builds", the
	// parameter keep_builds of the game-wide kit/player_state (the first
	// between_plays instance; one placed on the app root for it). An edit
	void set_always_keep(Peer &p, const json::Value &j,
			const std::function<void(const ss_&)> &refuse)
	{
		const bool on = j.get("on").is_true();
		sv_<std::pair<uint64_t, json::Value>> change;
		for(auto &e : m_entities){
			for(size_t i = 0; i < e.second.comps.size() && change.empty(); i++){
				const Instance &in = e.second.comps[i];
				if(!m_types[in.type].between_plays)
					continue;
				if(!m_types[in.type].decl.get("params").get("keep_builds").
						is_object())
					return refuse(in.type+" has no keep_builds");
				Entity copy = e.second;
				copy.comps[i].params.set("keep_builds", on);
				change.push_back(std::make_pair(e.first, entity_json(copy)));
			}
			if(!change.empty())
				break;
		}
		if(change.empty()){
			if(!on)
				return refuse("builds are not always kept");
			const ss_ type = "kit/player_state";
			if(!m_palette.count(type))
				return refuse("no "+type+" in the palette");
			if(m_entities.size() >= MAX_ENTITIES)
				return refuse("the composition has "+itos(MAX_ENTITIES)+
						" entities");
			const uint64_t id = m_next_id++;
			json::Value e = json::object(), comp = json::object(),
					comps = json::array(), params = json::object();
			e.set("id", (int64_t)id);
			e.set("parent", (int64_t)1);
			e.set("name", type+" "+itos(id));
			params.set("keep_builds", true);
			comp.set("type", type);
			comp.set("params", params);
			comps.append(comp);
			e.set("components", comps);
			change.push_back(std::make_pair(id, e));
		}
		commit(change, &m_undo[p.name]);
		log_i(MODULE, "An edit by %s: builds %s", cs(p.name), on ?
				"always kept" : "kept only by a builder's choice");
	}

	// ---- Edit and play ([KIT] stage 4c): the server Stopped or Running

	static ss_ digest(const json::Value &v)
	{
		return interface::sha256::hex(interface::sha256::calculate(
				v.stringify())).substr(0, 16);
	}

	void save_session()
	{
		json::Value j = json::object();
		j.set("running", m_session.running);
		j.set("by", m_session.by);
		json::Value round = json::array(), restore = json::array();
		for(const ss_ &n : m_session.round)
			round.append(n);
		for(const ss_ &k : m_session.restore)
			restore.append(k);
		j.set("round", round);
		j.set("restore", restore);
		m_store->set("session", j.stringify());
	}

	// voxelworld's section watch on, each scene's (a new round of copies:
	// every section copied again at its next write), or off
	void watch(bool on)
	{
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(auto &s : m_host.scenes){
				voxelworld::Instance *w = ivw->get_instance(s.second);
				if(!w)
					continue;
				sp_<Watch> wt;
				if(on){
					wt = std::make_shared<Watch>();
					wt->scene = s.first;
					wt->mutex = &m_copies_mutex;
					wt->queue = &m_copies;
				}
				w->set_section_watch(wt);
			}
		});
	}

	// The copies voxelworld made, kept in the store: a section's first
	// this round (one copied before a restart is not copied again)
	// simplified: a copy waits for Kit's next tick to reach the store, and
	// voxelworld's checkpoint could write the changed section first; a
	// crash between them loses that section's start
	void flush_copies()
	{
		std::deque<std::pair<ss_, ss_>> copies;
		{
			std::lock_guard<std::mutex> lock(m_copies_mutex);
			copies.swap(m_copies);
		}
		if(copies.empty() || !m_session.running)
			return;
		size_t n = 0;
		m_store->batch([&](){
			for(auto &c : copies)
				if(m_session.copied.insert(c.first).second){
					m_store->set(c.first, c.second);
					n++;
				}
		});
		if(n)
			log_i(MODULE, "%zu sections copied out (%zu this round)", n,
					m_session.copied.size());
	}

	// A copy's key, "start:<scene>:x,y,z", as its scene and section
	bool parse_copy(const ss_ &key, main_context::SceneReference &scene,
			pv::Vector3DInt16 &sp)
	{
		const size_t c = key.rfind(':');
		if(key.compare(0, 6, "start:") != 0 || c == ss_::npos || c < 6)
			return false;
		auto it = m_host.scenes.find(key.substr(6, c - 6));
		int x = 0, y = 0, z = 0;
		if(it == m_host.scenes.end() ||
				sscanf(key.c_str() + c + 1, "%d,%d,%d", &x, &y, &z) != 3)
			return false;
		scene = it->second;
		sp = pv::Vector3DInt16(x, y, z);
		return true;
	}

	// A copy put back into its section, loaded for it if it is not: false
	// when it cannot be (outside a streaming world's range; it waits for
	// its load). One that does not read is dropped
	// simplified: the copy holds this run's voxel ids; an app that
	// registers its voxels in another order after a restart mid-round
	// gets other voxels back. The names' table with the copy is the upgrade
	bool put_back(const ss_ &key)
	{
		main_context::SceneReference scene = nullptr;
		pv::Vector3DInt16 sp;
		ss_ data;
		if(!parse_copy(key, scene, sp) || !m_store->get(key, data)){
			log_w(MODULE, "The voxel copy %s is none of this app's: dropped",
					cs(key));
			return true;
		}
		up_<interface::VoxelVolume> v = interface::deserialize_volume(data);
		if(!v){
			log_w(MODULE, "The voxel copy %s does not read: dropped", cs(key));
			return true;
		}
		bool done = false;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *w = ivw->get_instance(scene);
			if(!w){
				done = true;
				return;
			}
			if(!w->is_section_loaded(sp))
				w->load_section_no_generate(sp);
			done = w->put_section(sp, *v);
		});
		return done;
	}

	// A section that a Stop's copy waits for has loaded
	void on_section_loaded(const voxelworld::SectionLoaded &ev)
	{
		if(!m_hosted || m_session.restore.empty())
			return;
		for(auto &s : m_host.scenes){
			if(s.second != ev.scene)
				continue;
			const ss_ key = "start:"+s.first+":"+itos(ev.section_p.getX())+
					","+itos(ev.section_p.getY())+","+
					itos(ev.section_p.getZ());
			if(!m_session.restore.count(key) || !put_back(key))
				return;
			m_session.restore.erase(key);
			// Running, it is this round's copy of the start
			if(m_session.running)
				m_session.copied.insert(key);
			else
				m_store->remove(key);
			save_session();
			log_i(MODULE, "The voxel copy %s put back as its section loaded",
					cs(key));
		}
	}

	// An instance's state at the start: the row "start"'s, over its
	// type's defaults; nothing disabled
	void to_start(Entity &e, size_t i)
	{
		Instance &in = e.comps[i];
		in.state = json::object();
		const json::Value &sd = m_types[in.type].decl.get("state");
		if(sd.is_object())
			for(json::Iterator it(sd); it; ++it)
				in.state.set(it.key(), (*it).get("default"));
		in.due_us = -1;
		in.due_by.clear();
		in.inside.clear();
		const json::Value &s = m_start.get(itos(e.id)).at((unsigned)i);
		if(full_type(jstr(s, "type")) == in.type)
			runtime_from(in, s);
		in.disabled.clear();
		for(const ss_ &k : m_types[in.type].shared)
			replicate_state(e, i, k);
	}

	// What players keep between plays: the first instance (by entity id)
	// of a between_plays type, its keep_inventory and keep_position
	void between_plays(bool &keep_inventory, bool &keep_position)
	{
		keep_inventory = keep_position = false;
		for(auto &p : m_entities)
			for(const Instance &in : p.second.comps)
				if(m_types[in.type].between_plays){
					keep_inventory = in.params.get("keep_inventory").is_true();
					keep_position = in.params.get("keep_position").is_true();
					return;
				}
	}

	// A player through the round's start, once a round: their entity at its
	// start (each player type's defaults: no items, no score), the items
	// they had at the last Stop with "keep inventory"; then, as each time
	// the app places them, on_join in their scene, a spawn type's placing
	// them. At Play, keep_position leaves them where they are, and no spawn
	// type in their scene is the app's default spawn
	void round_join(size_t peer, bool at_play)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end() || pi->second.name.empty())
			return;
		const ss_ name = pi->second.name, scene = pi->second.scene;
		const uint64_t pid = ensure_player(name);
		bool keep_inventory = false, keep_position = false;
		between_plays(keep_inventory, keep_position);
		if(m_session.round.insert(name).second){
			Entity &pe = m_entities[pid];
			for(size_t i = 0; i < pe.comps.size(); i++)
				to_start(pe, i);
			Instance *own = own_inventory(pid);
			const json::Value kept = m_aside.get(name);
			if(own && keep_inventory && kept.is_object() && kept.size())
				own->state.set("items", kept.deepcopy());
			m_aside.del_key(name);
			m_runtime_dirty = true;
			save_session();
			log_i(MODULE, "%s goes through the round's start: inventory %s",
					cs(name), keep_inventory ? "kept" : "reset");
		}
		bool placed = false;
		for(auto &p : m_entities){
			ss_ es;
			if(!scene_of(p.second, &es) || es != scene)
				continue;
			for(size_t i = 0; i < p.second.comps.size(); i++){
				const Type &t = m_types[p.second.comps[i].type];
				const bool places = t.spawn && (t.spawn_param.empty() ||
						p.second.comps[i].params.get(t.spawn_param).is_true());
				if(!t.handlers.count("on_join") ||
						(places && at_play && keep_position))
					continue;
				placed = placed || places;
				Run r;
				r.entity = p.first;
				r.comp = i;
				r.handler = "on_join";
				r.by = "player:"+itos(pid);
				r.args.append(r.by);
				queue_run(r);
			}
		}
		if(at_play && !keep_position && !placed){
			log_i(MODULE, "%s to the app's default spawn", cs(name));
			m_server->emit_event("kit:spawn_player", new SpawnPlayer(peer));
		}
		send_items(name);
	}

	// Each player is told the server's state, and the app
	void session_changed(bool saved, const ss_ &by)
	{
		if(!m_session.running)
			seats_home();
		for(auto &p : m_peers)
			send_state(p.first);
		m_server->emit_event("kit:session", new SessionChanged(
				m_session.running, saved, by));
	}

	// Play: a round from the start. Each instance's state from the start
	// and its on_start, voxels copied out as play writes to them, every
	// player there through the round's start
	void play(const ss_ &by)
	{
		if(m_session.running)
			return;
		m_session.running = true;
		m_session.by = by;
		m_session.round.clear();
		// The last Stop's discarded builds are no longer to keep
		if(!m_discarded.empty())
			log_i(MODULE, "The builds of %s discarded for good",
					cs(counts_text(discarded_counts())));
		m_discarded.clear();
		save_discarded();
		drop_marks();
		{
			std::lock_guard<std::mutex> lock(m_copies_mutex);
			m_copies.clear();
		}
		watch(true);
		m_queue.clear();
		for(auto &pe : m_entities)
			for(size_t i = 0; i < pe.second.comps.size(); i++){
				to_start(pe.second, i);
				Run r;
				r.entity = pe.first;
				r.comp = i;
				r.handler = "on_start";
				queue_run(r);
			}
		m_runtime_dirty = true;
		log_i(MODULE, "Play by %s: a round from the start (authored %s, "
				"start %s)", cs(by), cs(digest(authored_json())),
				cs(digest(m_start)));
		// Each player told first, then through the round's start
		session_changed(false, by);
		sv_<size_t> peers;
		for(auto &p : m_peers)
			peers.push_back(p.first);
		for(size_t peer : peers)
			round_join(peer, true);
		save_session();
		save_runtime();
	}

	// [KIT] stage 4d, the round's entities at Stop: those play made go,
	// the authored ones it removed come back. A player's builds among them
	// (a type with `builds`) are discarded, to keep until the next Play
	// (after sort_marks(), which starts the list)
	void end_round_entities()
	{
		sv_<uint64_t> made;
		for(auto &p : m_entities)
			if(p.second.made)
				made.push_back(p.first);
		for(uint64_t id : made){
			Entity &e = m_entities[id];
			if(e.made == 'b' && !e.made_by.empty()){
				Discarded d;
				d.by = e.made_by;
				d.entity = entity_json(e);
				m_discarded.push_back(d);
			}
			remove_node(e);
			m_entities.erase(id);
		}
		for(auto &r : m_removed){
			if(r.second.origin == 'b' && !r.second.by.empty()){
				Discarded d;
				d.by = r.second.by;
				d.entity = entity_json(r.second.e);
				d.removed = true;
				m_discarded.push_back(d);
			}
			Entity &e = m_entities[r.first];
			e = r.second.e;
			e.node = 0;
			if(e.has_pos)
				make_node(e);
		}
		if(!made.empty() || !m_removed.empty())
			log_i(MODULE, "The round's entities: %zu made gone, %zu removed "
					"back", made.size(), m_removed.size());
		m_removed.clear();
	}

	// Stop: play state thrown away. The sections play wrote to put back as
	// they were at Play, the entities it made gone and those it removed
	// back, each instance's state its start; the players' inventories
	// dropped, or put aside to give back at Play
	void stop(const ss_ &by)
	{
		if(!m_session.running)
			return;
		watch(false);
		flush_copies();
		// The round's marked cells as they are now: the kept ones go back
		// in over the copies, the builds are discarded with them
		sv_<Discarded> kept;
		sort_marks(kept);
		end_round_entities();
		m_session.running = false;
		m_session.by = by;
		sv_<ss_> done;
		for(const ss_ &k : m_session.copied){
			if(put_back(k))
				done.push_back(k);
			else
				m_session.restore.insert(k);
		}
		const size_t kept_n = put_cells(kept);
		save_discarded();
		m_store->batch([&](){
			for(const ss_ &k : done)
				m_store->remove(k);
		});
		m_session.copied.clear();
		m_queue.clear();
		m_pending_voxels.clear();
		{
			std::lock_guard<std::mutex> lock(m_writes_mutex);
			m_writes.clear();
		}
		// What the players had, put aside with "keep inventory"
		bool keep_inventory = false, keep_position = false;
		between_plays(keep_inventory, keep_position);
		m_aside = json::object();
		for(auto &p : m_players){
			const Instance *own = keep_inventory ? own_inventory(p.second) :
					nullptr;
			if(own && own->state.get("items").is_object() &&
					own->state.get("items").size())
				m_aside.set(p.first, own->state.get("items").deepcopy());
		}
		for(auto &pe : m_entities)
			for(size_t i = 0; i < pe.second.comps.size(); i++)
				to_start(pe.second, i);
		for(auto &p : m_peers)
			send_items(p.second.name);
		m_session.round.clear();
		m_runtime_dirty = true;
		save_runtime();
		save_session();
		m_store->set("authored", authored_json().stringify());
		log_i(MODULE, "Stop by %s: %zu sections put back (%zu wait for their "
				"load), each instance at its start, inventories %s (authored "
				"%s, start %s, runtime %s)", cs(by), done.size(),
				m_session.restore.size(), keep_inventory ? "put aside" :
				"dropped", cs(digest(authored_json())), cs(digest(m_start)),
				cs(digest(runtime_json(true))));
		log_i(MODULE, "Stop by %s: %zu kept cells (edits, builds always "
				"kept) put back in, %zu builds discarded%s%s", cs(by), kept_n,
				m_discarded.size(), m_discarded.empty() ? "" : ": ",
				cs(counts_text(discarded_counts())));
		own_voxels();
		pick_provider();
		session_changed(false, by);
		if(!m_discarded.empty())
			send_discarded();
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
	}

	// Save as start: the play state is the start from now on. The copies
	// go (the sections as they stand are the start), the entities play
	// made are authored and those it removed gone ([KIT] stage 4d), each
	// instance's state now its start; the round goes on
	void save_as_start(const ss_ &by)
	{
		if(!m_session.running)
			return;
		flush_copies();
		const size_t n = m_session.copied.size();
		m_store->batch([&](){
			for(const ss_ &k : m_session.copied)
				m_store->remove(k);
		});
		m_session.copied.clear();
		// The marks with them: the round's cells are the start's now
		drop_marks();
		watch(true);
		size_t made = 0;
		for(auto &p : m_entities)
			if(p.second.made){
				p.second.made = 0;
				p.second.made_by.clear();
				p.second.maker = 0;
				p.second.maker_comp = 0;
				made++;
			}
		const size_t removed = m_removed.size();
		m_removed.clear();
		m_store->set("authored", authored_json().stringify());
		m_start = runtime_json(true);
		m_store->set("start", m_start.stringify());
		m_runtime_dirty = true;
		save_session();
		log_i(MODULE, "Saved as the start by %s: %zu sections' copies dropped, "
				"%zu entities made authored, %zu removed gone, the start's "
				"state %s", cs(by), n, made, removed, cs(digest(m_start)));
		pick_provider();
		session_changed(true, by);
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
	}
	bool running()
	{
		return m_session.running;
	}

	void set_running(bool running, const ss_ &by)
	{
		if(!m_hosted)
			return;
		if(running)
			play(by.empty() ? "app" : by);
		else
			stop(by.empty() ? "app" : by);
	}

	// The builders with the tools on: their colours, selections and
	// cursors, to each of them ("you" the one it is sent to)
	void send_builders()
	{
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &to : m_peers){
				if(!to.second.editing)
					continue;
				json::Value a = json::array();
				for(auto &p : m_peers){
					if(!p.second.editing)
						continue;
					json::Value b = json::object();
					b.set("name", p.second.name);
					b.set("color", COLORS[std::max(0, p.second.color) %
							NUM_COLORS]);
					b.set("sel", (int64_t)p.second.sel);
					b.set("cursor", p.second.cursor);
					b.set("you", p.first == to.first);
					a.append(b);
				}
				inetwork->send(to.first, "kit:builders", a.stringify());
			}
		});
	}

	// A colour no other builder with the tools on has
	int free_color(size_t peer)
	{
		for(int c = 0; c < NUM_COLORS; c++){
			bool used = false;
			for(auto &p : m_peers)
				used = used || (p.first != peer && p.second.editing &&
						p.second.color == c);
			if(!used)
				return c;
		}
		return (int)(peer % NUM_COLORS);
	}

	// A builder's tools on or off: nothing of their play resets
	void tools(Peer &p, size_t peer, bool on)
	{
		p.editing = on;
		p.color = on ? (p.color >= 0 ? p.color : free_color(peer)) : -1;
		if(!on){
			p.sel = 0;
			p.cursor = json::null();
		}
	}

	// {"op": "focus", "sel": n, "cursor": [x, y, z]}: what the builder
	// has selected and their cursor
	void focus(size_t peer, const json::Value &j,
			const std::function<void(const ss_&)> &refuse)
	{
		Peer &p = m_peers[peer];
		const json::Value &sel = j.get("sel"), &c = j.get("cursor");
		uint64_t id = 0;
		if(sel.is_number() && sel.as_number() == std::floor(sel.as_number()) &&
				sel.as_number() >= 0 && sel.as_number() <= 9e15)
			id = (uint64_t)sel.as_number();
		else if(!sel.is_undefined() && !sel.is_null())
			return refuse("sel: an entity's id, or 0");
		if(id && !m_entities.count(id))
			return refuse("sel: no entity "+itos(id));
		json::Value cursor = json::null();
		if(!c.is_undefined() && !c.is_null()){
			if(!pos_ok(c))
				return refuse("cursor: three numbers within "+
						itos((int)MAX_COORD));
			cursor = json::array();
			for(unsigned k = 0; k < 3; k++)
				cursor.append(std::floor(c.at(k).as_number()));
		}
		const bool other = id != p.sel;
		if(other)
			log_i(MODULE, "%s selects %s", cs(p.name),
					id ? cs("entity "+itos(id)) : "nothing");
		p.sel = id;
		p.cursor = cursor;
		send_builders();
		// Its log, in the inspector ([KIT] stage 4d)
		if(other)
			send_log(peer);
	}

	// {"op": "builder", "name": n, "on": bool}: the admin grants or takes
	// an account's edit rights, kept in builtin/accounts
	void grant(size_t peer, const json::Value &j,
			const std::function<void(const ss_&)> &refuse)
	{
		bool admin = false;
		const ss_ by = account_of(peer, &admin);
		if(!admin)
			return refuse("only the server's admin makes builders");
		const ss_ name = jstr(j, "name").substr(0, 64);
		const bool on = j.get("on").is_true();
		// The launcher's own user may have no account: Kit checked it
		ss_ why;
		accounts::access(m_server, [&](accounts::Interface *i){
			why = i->set_priv(name, "builder", on, by);
		});
		if(!why.empty())
			return refuse(why);
		log_i(MODULE, "%s %s builder %s", by.empty() ? "The local user" :
				cs(by), on ? "made" : "took", cs(name));
	}

	// What an editor's client shows: the palette and the authored tree, or
	// that it is not editing
	void send_state(size_t peer)
	{
		auto pi = m_peers.find(peer);
		json::Value j = json::object();
		const bool editing = pi != m_peers.end() && pi->second.editing;
		j.set("editing", editing);
		j.set("can_edit", can_edit(peer));
		j.set("running", m_session.running);
		j.set("by", m_session.by);
		// The builds the last Stop discarded, until the next Play, and
		// whether builds are always kept
		j.set("discarded", discarded_counts());
		j.set("always_keep", always_keep());
		if(editing){
			json::Value pal = json::object();
			for(const ss_ &t : m_palette){
				const json::Value &d = m_types[t].decl;
				json::Value o = json::object();
				for(const char *k : {"params", "inputs", "outputs", "gizmo",
						"usable", "zone", "volume", "grants", "version",
						"inventory", "root", "inputs_types", "outputs_types",
						"player"})
					if(!d.get(k).is_undefined())
						o.set(k, d.get(k));
				pal.set(t, o);
			}
			// The composition's types that are not in the palette, too:
			// the inspector needs every instance's parameters and signals
			json::Value types = pal;
			for(auto &t : m_types)
				if(!m_palette.count(t.first)){
					json::Value o = json::object();
					for(const char *k : {"params", "inputs", "outputs", "gizmo",
							"zone", "volume", "grants", "version", "inventory",
							"root", "inputs_types", "outputs_types", "player"})
						if(!t.second.decl.get(k).is_undefined())
							o.set(k, t.second.decl.get(k));
					types.set(t.first, o);
				}
			json::Value names = json::array();
			for(const ss_ &t : m_palette)
				names.append(t);
			j.set("palette", names);
			j.set("types", types);
			j.set("authored", authored_json());
			// [KIT] stage 4d: the round's own entities (made in play) and
			// the players here, shown and selected, not edited; the prefabs
			json::Value made = json::array(), pfs = json::array();
			for(auto &e : m_entities){
				if(authored(e.second) || (e.second.kind == "player" &&
						!e.second.has_pos))
					continue;
				json::Value mj = entity_json(e.second);
				if(e.second.made){
					mj.set("made", ss_(1, e.second.made));
					mj.set("made_by", e.second.made_by);
					mj.set("maker", (int64_t)e.second.maker);
				}
				made.append(mj);
			}
			j.set("made", made);
			for(const ss_ &n : m_prefab_palette)
				pfs.append(n);
			j.set("prefabs", pfs);
			// [KIT] stage 4f: what the terrain brushes choose from
			if(m_world_scene){
				json::Value t = json::object(), bs = json::array();
				for(auto &b : m_materials.biomes)
					bs.append(b.first);
				t.set("biomes", bs);
				t.set("biome", m_wp.biome);
				t.set("surface", ss_(m_wp.heightmap() ? "heightmap" : "voxels"));
				j.set("terrain", t);
			}
			j.set("undo", (int64_t)m_undo[pi->second.name].size());
			// The admin's: who is here with an account, to make builders
			bool admin = false;
			account_of(peer, &admin);
			j.set("admin", admin);
			if(admin){
				json::Value people = json::array();
				for(auto &o : m_peers){
					bool o_admin = false;
					const ss_ n = account_of(o.first, &o_admin);
					if(o.first == peer || n.empty())
						continue;
					json::Value r = json::object();
					r.set("name", n);
					r.set("admin", o_admin);
					r.set("builder", is_builder(n));
					people.append(r);
				}
				j.set("people", people);
			}
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:edit_state", j.stringify());
		});
	}

	void on_edit(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const json::Value j = packet.data.size() <= MAX_EDIT_PACKET ?
				json::load_string(packet.data.c_str()) : json::null();
		const ss_ op = j.is_object() ? jstr(j, "op").substr(0, 16) : "";
		auto refuse = [&](const ss_ &why){
			log_i(MODULE, "An edit (%s) by peer %zu refused: %s",
					op.empty() ? "?" : cs(op), peer, cs(why));
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "kit:edit_refused", (op.empty() ? "?" :
						op)+": "+why);
			});
		};
		if(!m_hosted)
			return refuse("Kit is not hosted");
		if(!j.is_object())
			return refuse("not a JSON object of at most "+
					itos(MAX_EDIT_PACKET)+" bytes");
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return refuse("the app has not placed the player");
		Peer &p = pi->second;
		// Rights each packet: a revoked editor's next edit is refused
		if(!can_edit(peer)){
			if(p.editing){
				p.editing = false;
				send_state(peer);
			}
			return refuse("no edit rights here");
		}
		if(op == "builder")
			return grant(peer, j, refuse);
		if(op == "mode"){
			tools(p, peer, j.get("on").is_true());
			log_i(MODULE, "%s %s edit mode", cs(p.name),
					p.editing ? "is in" : "left");
			send_state(peer);
			send_builders();
			return;
		}
		// The server's state: a builder's, the tools on or not
		if(op == "play" || op == "stop" || op == "save_start"){
			if(op == "play" && m_session.running)
				return refuse("the server is Running");
			if(op != "play" && !m_session.running)
				return refuse("the server is Stopped");
			if(op == "play")
				play(p.name);
			else if(op == "stop")
				stop(p.name);
			else
				save_as_start(p.name);
			return;
		}
		// The builds Stop discarded: a builder's, the tools on or not (the
		// Stop notice offers it)
		if(op == "keep")
			return keep(p, j, refuse);
		if(op == "always_keep")
			return set_always_keep(p, j, refuse);
		if(!p.editing)
			return refuse("not in edit mode");
		if(op == "focus")
			return focus(peer, j, refuse);
		if(op == "terrain")
			return terrain(p, peer, j, refuse);
		if(op == "restart"){
			Entity *e = nullptr;
			ss_ why;
			Instance *in = instance_arg(j, e, why);
			if(!in)
				return refuse(why);
			if(!m_session.running)
				return refuse("the server is Stopped: it is at its start");
			const size_t ci = in - &e->comps[0];
			const uint64_t id = e->id;
			const ss_ type = in->type;
			// Its on_remove first ([KIT] stage 4d): what it made in the
			// round, it may take back
			Run r;
			r.entity = id;
			r.comp = ci;
			r.handler = "on_remove";
			r.by = by_of(p.name);
			run(r);
			auto it = m_entities.find(id);
			if(it == m_entities.end() || ci >= it->second.comps.size())
				return;
			to_start(it->second, ci);
			r.handler = "on_start";
			queue_run(r);
			m_runtime_dirty = true;
			pick_provider();
			log_i(MODULE, "%s restarts entity %s's %s from the start",
					cs(p.name), cs(itos(id)), cs(type));
			add_log(id, "restarted by "+p.name);
			return;
		}
		sv_<std::pair<uint64_t, json::Value>> change;
		ss_ why, what;
		if(op == "undo"){
			std::deque<Change> &u = m_undo[p.name];
			if(u.empty())
				return refuse("nothing of "+p.name+"'s to undo");
			const Change c = u.back();
			u.pop_back();
			if(c.stroke != -1){
				undo_terrain(c, p);
				send_state(peer);
				return;
			}
			commit(c.before, nullptr);
			log_i(MODULE, "An undo by %s: %zu entities put back (%zu more "
					"to undo)", cs(p.name), c.before.size(), u.size());
			world_check(p.name);
			return;
		}
		if(!build_change(op, j, p, change, what, why))
			return refuse(why);
		commit(change, &m_undo[p.name]);
		log_i(MODULE, "An edit by %s: %s", cs(p.name), cs(what));
		world_check(p.name);
	}

	// An id in a client's packet: a whole number of an entity that is there
	Entity* entity_arg(const json::Value &j, const char *key, ss_ &why)
	{
		const json::Value &v = j.get(key);
		if(!v.is_number() || v.as_number() != std::floor(v.as_number()) ||
				v.as_number() < 2 || v.as_number() > 9e15){
			why = ss_(key)+": an entity's id";
			return nullptr;
		}
		auto it = m_entities.find((uint64_t)v.as_number());
		if(it == m_entities.end()){
			why = ss_(key)+": no entity "+v.stringify()+(m_removed.count(
					(uint64_t)v.as_number()) ? " in the round (play removed "
					"it; it is back at Stop)" : "");
			return nullptr;
		}
		// Edits are the composition's ([KIT] stage 4d)
		if(!authored(it->second)){
			why = ss_(key)+": entity "+v.stringify()+" is "+(it->second.made ?
					"made in play" : "a player's")+", not the composition's";
			return nullptr;
		}
		return &it->second;
	}

	// An instance of an entity in a client's packet: "id" and "comp"
	Instance* instance_arg(const json::Value &j, Entity *&e, ss_ &why)
	{
		e = entity_arg(j, "id", why);
		if(!e)
			return nullptr;
		const json::Value &v = j.get("comp");
		if(!v.is_number() || v.as_number() != std::floor(v.as_number()) ||
				v.as_number() < 0 || v.as_number() >= e->comps.size()){
			why = "comp: entity "+itos(e->id)+" has "+itos(e->comps.size())+
					" components";
			return nullptr;
		}
		return &e->comps[(size_t)v.as_number()];
	}

	// An entity's delete as a change: it gone, and the links to it from the
	// other authored entities
	void delete_change(uint64_t id,
			sv_<std::pair<uint64_t, json::Value>> &change)
	{
		change.push_back(std::make_pair(id, json::null()));
		for(auto &o : m_entities){
			if(o.first == id || !authored(o.second))
				continue;
			bool links = false;
			for(const Instance &in : o.second.comps)
				for(const Link &l : in.links)
					links = links || l.to == id;
			if(!links)
				continue;
			Entity copy = o.second;
			for(Instance &in : copy.comps)
				in.links.erase(std::remove_if(in.links.begin(),
						in.links.end(), [&](const Link &l){
					return l.to == id;
				}), in.links.end());
			change.push_back(std::make_pair(o.first, entity_json(copy)));
		}
	}

	// What an editor's op changes: each entity after it (null: gone).
	// Everything in it is checked here; the client is trusted with nothing
	bool build_change(const ss_ &op, const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what, ss_ &why)
	{
		if(op == "place" && !j.get("prefab").is_undefined())
			return place_prefab(j, p, change, what, why);
		if(op == "save_prefab")
			return save_prefab(j, p, change, what, why);
		if(op == "place"){
			const ss_ type = jstr(j, "type");
			if(!m_palette.count(type)){
				why = "no type \""+type.substr(0, 64)+"\" in the palette";
				return false;
			}
			if(!pos_ok(j.get("pos"))){
				why = "pos: three numbers within "+itos((int)MAX_COORD);
				return false;
			}
			if(m_entities.size() >= MAX_ENTITIES){
				why = "the composition has "+itos(MAX_ENTITIES)+" entities";
				return false;
			}
			// In the scene the app placed the editor in, or a game-wide
			// type (root) on the app root, no position
			const bool root = m_types[type].root;
			uint64_t scene = 0;
			for(auto &e : m_entities)
				if(e.second.kind == "scene" && e.second.name == p.scene)
					scene = e.first;
			if(!scene && !root){
				why = "the editor is in no scene of the composition's";
				return false;
			}
			const uint64_t id = m_next_id++;
			json::Value e = json::object();
			e.set("id", (int64_t)id);
			e.set("parent", (int64_t)(root ? 1 : scene));
			e.set("name", type+" "+itos(id));
			json::Value pos = json::array();
			for(unsigned k = 0; k < 3; k++)
				pos.append(grid(j.get("pos").at(k).as_number()));
			if(!root)
				e.set("pos", pos);
			json::Value comp = json::object();
			comp.set("type", type);
			json::Value comps = json::array();
			comps.append(comp);
			e.set("components", comps);
			change.push_back(std::make_pair(id, e));
			what = "placed "+type+" "+itos(id)+(root ? ss_(" on the app root") :
					" at "+pos.stringify());
			return true;
		}
		if(op == "move" && !j.get("ids").is_undefined())
			return move_group(j, change, what, why);
		if(op == "move"){
			Entity *e = entity_arg(j, "id", why);
			if(!e)
				return false;
			if(!e->has_pos || !e->kind.empty()){
				why = "entity "+itos(e->id)+" has no position to move";
				return false;
			}
			if(!pos_ok(j.get("pos"))){
				why = "pos: three numbers within "+itos((int)MAX_COORD);
				return false;
			}
			const json::Value &yaw = j.get("yaw");
			if(!yaw.is_undefined() && (!yaw.is_number() ||
					!std::isfinite(yaw.as_number()))){
				why = "yaw: a number of degrees";
				return false;
			}
			json::Value after = entity_json(*e);
			json::Value pos = json::array();
			for(unsigned k = 0; k < 3; k++)
				pos.append(grid(j.get("pos").at(k).as_number()));
			after.set("pos", pos);
			if(yaw.is_number())
				after.set("yaw", norm_yaw(yaw.as_number()));
			change.push_back(std::make_pair(e->id, after));
			what = "moved "+itos(e->id)+" to "+pos.stringify()+
					(yaw.is_number() ? ", turned to "+
					json::Value(norm_yaw(yaw.as_number())).stringify() : ss_());
			return true;
		}
		if(op == "duplicate")
			return duplicate(j, p, change, what, why);
		if(op == "delete"){
			Entity *e = entity_arg(j, "id", why);
			if(!e)
				return false;
			if(!e->kind.empty()){
				why = "entity "+itos(e->id)+" is a "+e->kind;
				return false;
			}
			for(auto &o : m_entities)
				if(o.second.parent == e->id){
					why = "entity "+itos(e->id)+" has entities under it";
					return false;
				}
			delete_change(e->id, change);
			what = "deleted "+itos(e->id)+(change.size() > 1 ? " and "+
					itos(change.size() - 1)+" links' ends" : "");
			return true;
		}
		if(op == "set"){
			Entity *e = nullptr;
			Instance *in = instance_arg(j, e, why);
			if(!in)
				return false;
			const ss_ param = jstr(j, "param");
			const json::Value &decl = m_types[in->type].decl.get("params").
					get(param);
			if(param.empty() || !decl.is_object()){
				why = in->type+" has no parameter \""+param.substr(0, 64)+"\"";
				return false;
			}
			const ss_ bad = check_param(decl, j.get("value"));
			if(!bad.empty()){
				why = in->type+"'s "+param+" is "+bad;
				return false;
			}
			const size_t ci = in - &e->comps[0];
			Entity copy = *e;
			copy.comps[ci].params.set(param, j.get("value"));
			// A prefab copy's own value from now on, kept as the prefab
			// changes
			if(!copy.prefab.is_undefined())
				copy.comps[ci].overrides.insert(param);
			change.push_back(std::make_pair(e->id, entity_json(copy)));
			what = "set "+itos(e->id)+"'s "+in->type+" "+param+" to "+
					j.get("value").stringify();
			return true;
		}
		if(op == "link" || op == "unlink"){
			Entity *e = nullptr;
			Instance *in = instance_arg(j, e, why);
			if(!in)
				return false;
			Link l;
			l.output = jstr(j, "output");
			l.input = jstr(j, "input");
			if(!m_types[in->type].outputs.count(l.output)){
				why = in->type+" has no output \""+l.output.substr(0, 64)+"\"";
				return false;
			}
			Entity *to = entity_arg(j, "to", why);
			if(!to)
				return false;
			l.to = to->id;
			bool has_input = false;
			ss_ in_type;
			for(const Instance &ti : to->comps)
				if(m_types[ti.type].inputs.count(l.input) && !has_input){
					has_input = true;
					in_type = m_types[ti.type].in_types.at(l.input);
				}
			if(!has_input){
				why = "entity "+itos(to->id)+" has no input \""+
						l.input.substr(0, 64)+"\"";
				return false;
			}
			// Typed signals ([KIT] stage 4d): the output's values the input's
			const ss_ &out_type = m_types[in->type].out_types.at(l.output);
			if(op == "link" && !signals_meet(out_type, in_type)){
				why = l.output+" sends a "+out_type+", "+l.input+" takes a "+
						in_type;
				return false;
			}
			auto same = [&](const Link &o){
				return o.output == l.output && o.to == l.to && o.input == l.input;
			};
			const bool there = std::any_of(in->links.begin(), in->links.end(),
					same);
			const size_t ci = in - &e->comps[0];
			Entity copy = *e;
			sv_<Link> &links = copy.comps[ci].links;
			if(op == "link"){
				if(there){
					why = "that link is there";
					return false;
				}
				if(links.size() >= MAX_LINKS){
					why = "an instance has "+itos(MAX_LINKS)+" links at most";
					return false;
				}
				links.push_back(l);
			} else {
				if(!there){
					why = "no such link";
					return false;
				}
				links.erase(std::remove_if(links.begin(), links.end(), same),
						links.end());
			}
			change.push_back(std::make_pair(e->id, entity_json(copy)));
			what = op+"ed "+itos(e->id)+"."+l.output+" -> "+itos(l.to)+"."+
					l.input;
			return true;
		}
		why = "no op \""+op+"\"";
		return false;
	}

	// The entities as the change has them, live: their nodes, runtime state
	// and owned voxels follow, the authored row is saved, and each editor
	// is sent the tree. undo: the editor's, which gets what puts it back.
	// Running, a deleted entity's on_remove runs first ([KIT] stage 4d)
	void commit(const sv_<std::pair<uint64_t, json::Value>> &change,
			std::deque<Change> *undo)
	{
		Change back;
		for(const auto &c : change)
			if(!c.second.is_null())
				m_pending_ids.insert(c.first);
		for(const auto &c : change)
			if(c.second.is_null() && m_session.running &&
					m_entities.count(c.first))
				run_now(c.first, "on_remove", "app");
		for(const auto &c : change){
			if(undo){
				auto it = m_entities.find(c.first);
				back.before.push_back(std::make_pair(c.first,
						it == m_entities.end() ? json::null() :
						entity_json(it->second)));
			}
			apply(c.first, c.second);
		}
		m_pending_ids.clear();
		if(undo){
			undo->push_back(back);
			while(undo->size() > UNDO_MAX)
				undo->pop_front();
		}
		m_runtime_dirty = true;
		own_voxels();
		pick_provider();
		m_store->set("authored", authored_json().stringify());
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
	}

	void remove_node(const Entity &e)
	{
		if(!e.node)
			return;
		main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
			magic::Node *n = scene->GetNode(e.node);
			if(n)
				n->Remove();
		});
	}

	void apply(uint64_t id, const json::Value &after)
	{
		auto it = m_entities.find(id);
		if(after.is_null()){
			if(it != m_entities.end()){
				remove_node(it->second);
				m_entities.erase(it);
			}
			return;
		}
		Entity n;
		ss_ why;
		if(!entity_from_json(after, n, why) || n.id != id ||
				!m_entities.count(n.parent) || (n.has_pos && !scene_of(n))){
			log_w(MODULE, "An edit of entity %s not made: %s", cs(itos(id)),
					why.empty() ? "no parent or scene" : cs(why));
			return;
		}
		// Links to what is no longer there (an undo past a delete of
		// someone else's) are left out
		for(Instance &in : n.comps)
			in.links.erase(std::remove_if(in.links.begin(), in.links.end(),
					[&](const Link &l){
				return !m_entities.count(l.to) && !m_pending_ids.count(l.to);
			}), in.links.end());
		const bool had = it != m_entities.end();
		sv_<size_t> fresh;
		// Running, an instance whose parameters changed is told which, and
		// what each was ([KIT] stage 4d)
		sv_<std::pair<size_t, json::Value>> changed;
		for(size_t i = 0; i < n.comps.size(); i++){
			Instance &in = n.comps[i];
			if(had && i < it->second.comps.size() &&
					it->second.comps[i].type == in.type){
				// The same instance: its runtime state goes on
				const Instance &was = it->second.comps[i];
				in.state = was.state;
				in.disabled = was.disabled;
				in.due_us = was.due_us;
				in.due_by = was.due_by;
				in.inside = was.inside;
				json::Value old = json::object();
				for(json::Iterator pi(in.params); pi; ++pi)
					if((*pi).stringify() != was.params.get(pi.key()).stringify())
						old.set(pi.key(), was.params.get(pi.key()));
				if(old.size())
					changed.push_back(std::make_pair(i, old));
				continue;
			}
			// simplified: a new instance (an undone delete's too) starts
			// with its type's defaults; the runtime state of a deleted one
			// is not kept for an undo
			const json::Value &sd = m_types[in.type].decl.get("state");
			if(sd.is_object())
				for(json::Iterator si(sd); si; ++si)
					in.state.set(si.key(), (*si).get("default"));
			fresh.push_back(i);
		}
		if(had){
			n.node = it->second.node;
			if(n.node && (!n.has_pos || scene_of(n) != scene_of(it->second))){
				remove_node(it->second);
				n.node = 0;
			}
		}
		m_entities[id] = n;
		Entity &e = m_entities[id];
		// Running, live: a new instance starts at once, and joins those in
		// its scene. Stopped, it is at its start
		ss_ scene;
		scene_of(e, &scene);
		for(size_t i : m_session.running ? fresh : sv_<size_t>()){
			Run r;
			r.entity = id;
			r.comp = i;
			r.handler = "on_start";
			queue_run(r);
			if(!m_types[e.comps[i].type].handlers.count("on_join") ||
					scene.empty())
				continue;
			for(auto &p : m_peers){
				if(p.second.scene != scene || !p.second.player)
					continue;
				r.handler = "on_join";
				r.by = "player:"+itos(p.second.player);
				r.args = json::array();
				r.args.append(r.by);
				queue_run(r);
			}
		}
		for(auto &c : changed){
			if(!m_session.running)
				break;
			Run r;
			r.entity = id;
			r.comp = c.first;
			r.handler = "on_params";
			r.args.append(c.second);
			queue_run(r);
		}
		if(e.has_pos && !e.node){
			make_node(e);
		} else if(e.node){
			main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
				magic::Node *nd = scene->GetNode(e.node);
				if(nd){
					nd->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
					nd->SetRotation(magic::Quaternion(0, (float)e.yaw, 0));
					// A parameter its look is drawn from may have changed
					nd->SetVar(magic::StringHash("kit_show"), magic::Variant(
							show_of(e).stringify().c_str()));
				}
			});
		}
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_kit(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
