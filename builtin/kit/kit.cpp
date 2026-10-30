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
#include <Scene.h>
#include <Node.h>
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
	// runtime, not saved: the players in its zone, by name
	std::set<ss_> inside;
};

struct Entity
{
	uint64_t id = 0, parent = 0;
	ss_ name, kind; // "app", "scene" or "" (an entity)
	bool has_pos = false;
	double pos[3] = {0, 0, 0};
	sv_<Instance> comps;
	uint32_t node = 0; // a positional one's node in its scene
};

struct Type
{
	json::Value decl;
	std::set<ss_> inputs, outputs, handlers, shared;
	bool usable = false, owns_voxel = false;
	// It provides the players' inventory (inventory = true)
	bool inventory = false;
	// [KIT] stage 4c: it places players at the round's start (spawn), it
	// says what players keep between plays (between_plays), it goes on the
	// app root (root)
	bool spawn = false, between_plays = false, root = false;
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

// A build Stop discarded: its cell and final voxel, until the next Play
struct Discarded
{
	ss_ scene;
	int p[3] = {0, 0, 0};
	uint32_t id = 0;
	ss_ by;
};

// One edit: the entities it changed as they were before (null: not there),
// in the order an undo puts them back
struct Change
{
	sv_<std::pair<uint64_t, json::Value>> before;
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
	// Runtime: each player's items, by name ({item: n}), Kit's own inventory
	json::Value m_items = json::object();
	// The replacing inventory provider (an entity's id and its instance; 0:
	// none, Kit's counts above), and those refused as a second
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
		// Inventories put aside while Stopped ("keep inventory")
		json::Value aside = json::object();
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
		sub(m_server, "network:packet_received/kit:use", &Module::on_use);
		sub(m_server, "network:packet_received/kit:edit", &Module::on_edit);
		sub(m_server, "network:client_disconnected", &Module::on_left);
		sub(m_server, "accounts:privs", &Module::on_privs);
		sub(m_server, "voxelworld:section_loaded", &Module::on_section_loaded);
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
		// leaves no box (no restart inside a restart)
		m_starting = true;
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
		const int64_t slice = request[0] == 'D' ? m_box->budget() :
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
		names("inputs", t.inputs);
		names("outputs", t.outputs);
		names("handlers", t.handlers);
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
		t.spawn = t.decl.get("spawn").is_true();
		t.between_plays = t.decl.get("between_plays").is_true();
		t.root = t.decl.get("root").is_true();
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
				if(!isalnum((unsigned char)c) && c != '_' && c != ':')
					return "a voxel's name (letters, digits, _ and :)";
			return "";
		}
		if(t == "entity"){
			// 0: none
			if(!v.is_number() || v.as_number() != std::floor(v.as_number()) ||
					v.as_number() < 0 || v.as_number() > 9e15 ||
					(v.as_number() != 0 &&
					!m_entities.count((uint64_t)v.as_number())))
				return "an entity's id";
			return "";
		}
		if(t == "position")
			return pos_ok(v) ? "" : "a position, three numbers";
		return "a type of parameter Kit has (\""+t.substr(0, 32)+"\" is none)";
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
		if(e.kind != "" && e.kind != "scene"){
			why = "entity "+itos(e.id)+": no kind \""+e.kind+"\"";
			return false;
		}
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
		if(e.has_pos){
			json::Value pos = json::array();
			for(int k = 0; k < 3; k++)
				pos.append(e.pos[k]);
			j.set("pos", pos);
		}
		json::Value comps = json::array();
		for(const Instance &in : e.comps){
			json::Value cj = json::object();
			cj.set("type", in.type);
			cj.set("version", in.version);
			cj.set("params", in.params);
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
		for(unsigned i = 0; i < es.size(); i++){
			Entity e;
			if(!entity_from_json(es.at(i), e, why))
				return false;
			if(m_entities.count(e.id)){
				why = "entity "+itos(e.id)+" twice";
				return false;
			}
			m_entities[e.id] = e;
		}
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

	json::Value authored_json()
	{
		json::Value c = json::object();
		json::Value es = json::array();
		for(auto &p : m_entities)
			if(p.first != 1)
				es.append(entity_json(p.second));
		c.set("entities", es);
		c.set("next_id", (int64_t)m_next_id);
		return c;
	}

	// {"<id>": [{"type", "state", "disabled", "timer": s, "timer_by"}, ...],
	//  "items": {player: {item: n}}}
	json::Value runtime_json()
	{
		json::Value r = json::object();
		const int64_t now = interface::os::game_us();
		for(auto &p : m_entities){
			if(p.second.comps.empty())
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
				a.append(j);
			}
			r.set(itos(p.first), a);
		}
		r.set("items", m_items.deepcopy());
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
		if(first || m_migrated || !m_migrated_objects.empty())
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
				if(n.is_directory || dot == ss_::npos ||
						dot + 4 != n.name.size())
					continue;
				const ss_ type = author+"/"+n.name.substr(0, dot);
				ss_ twhy;
				if(load_type(type, twhy))
					m_palette.insert(type);
				else
					log_w(MODULE, "Not in the palette: %s", cs(twhy));
			}
		}
		ss_ names;
		for(const ss_ &t : m_palette)
			names += (names.empty() ? "" : " ")+t;
		log_i(MODULE, "The palette: %s", cs(names));

		// The session ([KIT] stage 4c): Stopped or Running. A save from
		// before has no row; it ran its components, so it is Running, its
		// start its types' defaults. A fresh save is Running too: an empty
		// composition Running is the same as Stopped, and a builder's Stop
		// is what stops a server
		ss_ runtime, session, start, discarded;
		const bool had_runtime = m_store->get("runtime", runtime);
		if(m_store->get("session", session)){
			const json::Value sj = json::load_string(session.c_str());
			m_session.running = sj.get("running").is_true();
			m_session.by = jstr(sj, "by");
			for(const char *k : {"round", "restore"}){
				const json::Value &a = sj.get(k);
				for(unsigned i = 0; i < a.size(); i++)
					if(a.at(i).is_string())
						(ss_(k) == "round" ? m_session.round :
								m_session.restore).insert(a.at(i).as_string());
			}
			if(sj.get("aside").is_object())
				m_session.aside = sj.get("aside").deepcopy();
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
		const json::Value rt = had_runtime ?
				json::load_string(runtime.c_str()) : json::object();
		if(m_session.running && rt.get("items").is_object())
			m_items = rt.get("items");
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
					if(!in.disabled.empty())
						log_w(MODULE, "Entity %s's %s stays disabled: %s",
								cs(itos(e.id)), cs(in.type), cs(in.disabled));
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
		size_t n = 0;
		for(auto &p : m_entities)
			n += p.second.comps.size();
		log_i(MODULE, "Hosted: %zu entities, %zu instances, %zu types%s",
				m_entities.size(), n, m_types.size(),
				first ? " (the composition's first start)" : "");
		return true;
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
		json::Value show = json::object();
		for(const Instance &in : e.comps){
			const json::Value &d = m_types[in.type].decl;
			if(show.get("look").is_undefined() && !d.get("look").is_undefined())
				show.set("look", look_of(in, d.get("look")));
			if(show.get("hud").is_undefined() && !d.get("hud").is_undefined())
				show.set("hud", d.get("hud"));
		}
		return show;
	}

	void make_node(Entity &e)
	{
		const json::Value show = show_of(e);
		main_context::SceneReference ref = scene_of(e);
		main_context::access(m_server, ref, [&](magic::Scene *scene){
			magic::Node *n = scene->CreateChild(("kit:"+itos(e.id)).c_str());
			n->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
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

	// An input to an entity: each of its instances that has it
	void deliver(uint64_t to, const ss_ &input, const json::Value &value,
			const ss_ &by, int hops)
	{
		auto it = m_entities.find(to);
		if(it == m_entities.end())
			return;
		for(size_t i = 0; i < it->second.comps.size(); i++){
			const Instance &in = it->second.comps[i];
			if(!m_types[in.type].inputs.count(input))
				continue;
			Run r;
			r.entity = to;
			r.comp = i;
			r.handler = "on_input";
			r.args.append(input);
			r.args.append(value);
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
		// The player who set it off, and their inventory's provider: Kit's
		// counts of theirs, or the replacing instance (itself, or its
		// type, params and state)
		const ss_ who = player_of(r.by);
		if(!who.empty()){
			o += ",player=";
			lua_lit(json::Value(who), o);
			const Instance *pv_ = provider();
			if(!pv_){
				o += ",items=";
				lua_lit(m_items.get(who).is_object() ? m_items.get(who) :
						json::object(), o);
			} else if(pv_ == &in){
				o += ",inv_self=true";
			} else {
				o += ",inv={type=";
				lua_lit(json::Value(pv_->type), o);
				o += ",id="+itos(m_provider)+",params=";
				lua_lit(pv_->params, o);
				o += ",state=";
				lua_lit(pv_->state, o);
				o += "}";
			}
		}
		o += "}";
		return o;
	}

	static ss_ player_of(const ss_ &by)
	{
		return by.compare(0, 7, "player:") == 0 ? by.substr(7) : "";
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
		if(!box_call(request, answer, error, &runaway, &spent, &in_provider)){
			Instance *pv_ = provider();
			if(runaway && in_provider && pv_){
				// The replacing provider ran past it: it is disabled, not
				// the caller, and Kit's own counts are the inventory now
				pv_->disabled = "its inventory ran past its budget in entity "+
						itos(r.entity)+"'s "+r.handler;
				m_runtime_dirty = true;
				log_w(MODULE, "Entity %s's %s disabled: %s; the players' "
						"inventory is Kit's own counts now",
						cs(itos(m_provider)), cs(pv_->type), cs(pv_->disabled));
			} else if(runaway){
				Instance &in = m_entities[r.entity].comps[r.comp];
				in.disabled = r.handler+" ran past its budget";
				m_runtime_dirty = true;
				log_w(MODULE, "Entity %s's %s disabled: %s", cs(itos(r.entity)),
						cs(type), cs(in.disabled));
			} else {
				log_w(MODULE, "Entity %s's %s, %s: %s", cs(itos(r.entity)),
						cs(type), cs(r.handler), cs(error));
			}
			return spent;
		}
		const json::Value fx = json::load_string(answer.c_str());
		Instance &in = e.comps[r.comp];
		const Type &t = m_types[type];
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
				continue;
			}
			for(const Link &l : in.links){
				if(l.output != output)
					continue;
				if(r.hops + 1 > MAX_HOPS){
					log_w(MODULE, "A signal loop cut: entity %s's %s -> entity "
							"%s's %s, past %i links", cs(itos(e.id)), cs(output),
							cs(itos(l.to)), cs(l.input), MAX_HOPS);
					continue;
				}
				deliver(l.to, l.input, emits.at(i).at(1u), r.by, r.hops + 1);
			}
		}
		// The provider's state, changed by the inventory calls of this run
		Instance *pv_ = provider();
		const json::Value &inv_set = fx.get("inv_set");
		if(pv_ && pv_ != &in && inv_set.size()){
			Entity &pe = m_entities[m_provider];
			for(unsigned i = 0; i < inv_set.size(); i++){
				const json::Value &kv = inv_set.at(i);
				if(!kv.at(0u).is_string())
					continue;
				const ss_ k = kv.at(0u).as_string();
				pv_->state.set(k, kv.at(1u));
				m_runtime_dirty = true;
				if(m_types[pv_->type].shared.count(k))
					replicate_state(pe, m_provider_comp, k);
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
					w.origin = t.builds && !player_of(r.by).empty() ? 'b' : 'g';
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
		return spent;
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
		const char *why = !m_host.moves_players ? "the app moves no players" :
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
		m_server->emit_event("kit:move_player", new MovePlayer(peer, x, y, z));
	}

	// ---- The players' inventory: count, add, take and list (api.h), Kit's
	// own counts (m_items) unless one component replaces them

	// The provider: the first instance (by entity id) whose type has
	// inventory = true; another is refused, logged once
	void pick_provider()
	{
		const uint64_t was = m_provider;
		const size_t was_comp = m_provider_comp;
		m_provider = 0;
		m_provider_comp = 0;
		for(auto &p : m_entities)
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
		if(m_provider != was || m_provider_comp != was_comp)
			log_i(MODULE, "The players' inventory: %s", m_provider ?
					cs("entity "+itos(m_provider)+"'s "+m_entities[m_provider].
					comps[m_provider_comp].type) : "Kit's own counts");
	}

	// The provider's instance, running (not disabled), or null
	Instance* provider()
	{
		auto it = m_entities.find(m_provider);
		if(it == m_entities.end() || m_provider_comp >= it->second.comps.size())
			return nullptr;
		Instance &in = it->second.comps[m_provider_comp];
		return in.disabled.empty() ? &in : nullptr;
	}

	// A run's inventory calls done: the player's items as the provider
	// lists them now, kept (Kit's own counts) and sent to their client
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
		if(!provider()){
			if(mine.size())
				m_items.set(who, mine);
			else
				m_items.del_key(who);
			m_runtime_dirty = true;
		}
		log_i(MODULE, "Entity %s's %s: %s has %s", cs(itos(e.id)), cs(type),
				cs(who), cs(mine.stringify()));
		send_items(who, mine);
	}

	// simplified: under a replacing provider a client is sent its list
	// only after a run that touched it, not as it joins
	void send_items(const ss_ &who, json::Value mine = json::Value())
	{
		if(mine.is_undefined())
			mine = m_items.get(who);
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
	// on_enter(c, by) and on_leave(c, by) as that changes
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
				std::set<ss_> now;
				for(auto &pp : m_peers){
					const Peer &peer = pp.second;
					if(peer.scene != scene || peer.name.empty())
						continue;
					bool inside = true;
					for(int k = 0; k < 3; k++){
						const double c = std::floor(peer.pos[k] + 0.5) -
								(k == 0 ? o.getX() : k == 1 ? o.getY() : o.getZ());
						inside = inside && c >= 0 && c < n[k];
					}
					if(inside)
						now.insert(peer.name);
				}
				auto fire = [&](const char *handler, const ss_ &name){
					Run r;
					r.entity = e.id;
					r.comp = i;
					r.handler = handler;
					r.by = "player:"+name;
					r.args.append(r.by);
					queue_run(r);
				};
				for(const ss_ &name : now)
					if(!in.inside.count(name))
						fire("on_enter", name);
				for(const ss_ &name : in.inside)
					if(!now.count(name))
						fire("on_leave", name);
				in.inside.swap(now);
			}
		}
	}

	// A player placed for the first time (or as another name): Running,
	// through the round's start (round_join); and their items
	void joined(size_t peer)
	{
		const Peer &p = m_peers[peer];
		log_i(MODULE, "%s joined %s", cs(p.name), cs(p.scene));
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
					r.args.append(w.by);
					r.by = w.by;
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
		const int64_t budget = m_box ? m_box->budget() / SLICE_DIV *
				TICK_SLICES : 0;
		int64_t spent = 0;
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
		for(size_t i = 0; i < e.comps.size(); i++){
			const Type &t = m_types[e.comps[i].type];
			if(!t.usable || !t.handlers.count("on_use"))
				continue;
			any = true;
			Run r;
			r.entity = id;
			r.comp = i;
			r.handler = "on_use";
			r.by = "player:"+pi->second.name;
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
		m_peers.erase(old.info.id);
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
		p.name = name;
		p.scene = scene;
		p.pos[0] = x;
		p.pos[1] = y;
		p.pos[2] = z;
		if(join && m_hosted)
			joined(peer);
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
			for(int k = 0; k < 3; k++)
				p.append((int64_t)d.p[k]);
			j.set("scene", d.scene);
			j.set("p", p);
			j.set("id", (int64_t)d.id);
			j.set("by", d.by);
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
		m_discarded.swap(rest);
		save_discarded();
		log_i(MODULE, "%s keeps the builds of %s: %zu cells put into the start "
				"(%zu discarded left)", cs(p.name), cs(counts_text(
				discarded_counts(put))), n, m_discarded.size());
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
		j.set("aside", m_session.aside);
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

	// A player through the round's start, once a round: their inventory
	// reset (or what they had, kept); then, as each time the app places
	// them, on_join in their scene, a spawn type's placing them. At Play,
	// keep_position leaves them where they are, and no spawn type in their
	// scene is the app's default spawn
	void round_join(size_t peer, bool at_play)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end() || pi->second.name.empty())
			return;
		const ss_ name = pi->second.name, scene = pi->second.scene;
		bool keep_inventory = false, keep_position = false;
		between_plays(keep_inventory, keep_position);
		if(m_session.round.insert(name).second){
			const json::Value kept = m_session.aside.get(name);
			if(keep_inventory && kept.is_object() && kept.size())
				m_items.set(name, kept);
			else
				m_items.del_key(name);
			m_session.aside.del_key(name);
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
				if(!t.handlers.count("on_join") ||
						(t.spawn && at_play && keep_position))
					continue;
				placed = placed || t.spawn;
				Run r;
				r.entity = p.first;
				r.comp = i;
				r.handler = "on_join";
				r.by = "player:"+name;
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
		m_items = json::object();
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

	// Stop: play state thrown away. The sections play wrote to put back as
	// they were at Play, each instance's state its start; the players'
	// inventories dropped, or put aside to give back at Play
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
		for(auto &pe : m_entities)
			for(size_t i = 0; i < pe.second.comps.size(); i++)
				to_start(pe.second, i);
		bool keep_inventory = false, keep_position = false;
		between_plays(keep_inventory, keep_position);
		if(keep_inventory){
			for(json::Iterator it(m_items); it; ++it)
				m_session.aside.set(it.key(), *it);
		} else {
			m_session.aside = json::object();
		}
		m_items = json::object();
		for(auto &p : m_peers)
			send_items(p.second.name);
		m_session.round.clear();
		m_runtime_dirty = true;
		save_runtime();
		save_session();
		log_i(MODULE, "Stop by %s: %zu sections put back (%zu wait for their "
				"load), each instance at its start, inventories %s (authored "
				"%s, start %s, runtime %s)", cs(by), done.size(),
				m_session.restore.size(), keep_inventory ? "put aside" :
				"dropped", cs(digest(authored_json())), cs(digest(m_start)),
				cs(digest(runtime_json())));
		log_i(MODULE, "Stop by %s: %zu kept cells (edits, builds always "
				"kept) put back in, %zu builds discarded%s%s", cs(by), kept_n,
				m_discarded.size(), m_discarded.empty() ? "" : ": ",
				cs(counts_text(discarded_counts())));
		session_changed(false, by);
		if(!m_discarded.empty())
			send_discarded();
	}

	// Save as start: the play state is the start from now on. The copies
	// go (the sections as they stand are the start), each instance's state
	// now its start; the round goes on
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
		m_start = runtime_json();
		m_start.del_key("items");
		m_store->set("start", m_start.stringify());
		save_session();
		log_i(MODULE, "Saved as the start by %s: %zu sections' copies dropped, "
				"the start's state %s", cs(by), n, cs(digest(m_start)));
		session_changed(true, by);
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
		if(id != p.sel)
			log_i(MODULE, "%s selects %s", cs(p.name),
					id ? cs("entity "+itos(id)) : "nothing");
		p.sel = id;
		p.cursor = cursor;
		send_builders();
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
						"inventory", "root"})
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
							"root"})
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
		if(op == "restart"){
			Entity *e = nullptr;
			ss_ why;
			Instance *in = instance_arg(j, e, why);
			if(!in)
				return refuse(why);
			if(!m_session.running)
				return refuse("the server is Stopped: it is at its start");
			const size_t ci = in - &e->comps[0];
			to_start(*e, ci);
			Run r;
			r.entity = e->id;
			r.comp = ci;
			r.handler = "on_start";
			queue_run(r);
			m_runtime_dirty = true;
			pick_provider();
			log_i(MODULE, "%s restarts entity %s's %s from the start",
					cs(p.name), cs(itos(e->id)), cs(in->type));
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
			commit(c.before, nullptr);
			log_i(MODULE, "An undo by %s: %zu entities put back (%zu more "
					"to undo)", cs(p.name), c.before.size(), u.size());
			return;
		}
		if(!build_change(op, j, p, change, what, why))
			return refuse(why);
		commit(change, &m_undo[p.name]);
		log_i(MODULE, "An edit by %s: %s", cs(p.name), cs(what));
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
			why = ss_(key)+": no entity "+v.stringify();
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

	// What an editor's op changes: each entity after it (null: gone).
	// Everything in it is checked here; the client is trusted with nothing
	bool build_change(const ss_ &op, const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what, ss_ &why)
	{
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
				pos.append(std::floor(j.get("pos").at(k).as_number()));
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
			json::Value after = entity_json(*e);
			json::Value pos = json::array();
			for(unsigned k = 0; k < 3; k++)
				pos.append(std::floor(j.get("pos").at(k).as_number()));
			after.set("pos", pos);
			change.push_back(std::make_pair(e->id, after));
			what = "moved "+itos(e->id)+" to "+pos.stringify();
			return true;
		}
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
			change.push_back(std::make_pair(e->id, json::null()));
			// And the links to it, from the others
			for(auto &o : m_entities){
				if(o.first == e->id)
					continue;
				bool links = false;
				for(const Instance &in : o.second.comps)
					for(const Link &l : in.links)
						links = links || l.to == e->id;
				if(!links)
					continue;
				Entity copy = o.second;
				for(Instance &in : copy.comps)
					in.links.erase(std::remove_if(in.links.begin(),
							in.links.end(), [&](const Link &l){
						return l.to == e->id;
					}), in.links.end());
				change.push_back(std::make_pair(o.first, entity_json(copy)));
			}
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
			for(const Instance &ti : to->comps)
				has_input = has_input || m_types[ti.type].inputs.count(l.input);
			if(!has_input){
				why = "entity "+itos(to->id)+" has no input \""+
						l.input.substr(0, 64)+"\"";
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
	// is sent the tree. undo: the editor's, which gets what puts it back
	void commit(const sv_<std::pair<uint64_t, json::Value>> &change,
			std::deque<Change> *undo)
	{
		Change back;
		for(const auto &c : change){
			if(undo){
				auto it = m_entities.find(c.first);
				back.before.push_back(std::make_pair(c.first,
						it == m_entities.end() ? json::null() :
						entity_json(it->second)));
			}
			apply(c.first, c.second);
		}
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
					[&](const Link &l){ return !m_entities.count(l.to); }),
					in.links.end());
		const bool had = it != m_entities.end();
		sv_<size_t> fresh;
		for(size_t i = 0; i < n.comps.size(); i++){
			Instance &in = n.comps[i];
			if(had && i < it->second.comps.size() &&
					it->second.comps[i].type == in.type){
				// The same instance: its runtime state goes on
				in.state = it->second.comps[i].state;
				in.disabled = it->second.comps[i].disabled;
				in.due_us = it->second.comps[i].due_us;
				in.due_by = it->second.comps[i].due_by;
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
				if(p.second.scene != scene || p.second.name.empty())
					continue;
				r.handler = "on_join";
				r.by = "player:"+p.second.name;
				r.args = json::array();
				r.args.append(r.by);
				queue_run(r);
			}
		}
		if(e.has_pos && !e.node){
			make_node(e);
		} else if(e.node){
			main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
				magic::Node *nd = scene->GetNode(e.node);
				if(nd){
					nd->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
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
