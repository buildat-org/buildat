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
#include "interface/voxel_selector.h"
#include "interface/sha256.h"
#include "interface/os.h"
#include "interface/aitta.h"
#include "interface/address.h"
#include "interface/zip.h"
#include "kit/world.h"
#include "voxel_objects/api.h"
#include "client_file/api.h"
#include <Scene.h>
#include <Image.h>
#include <MemoryBuffer.h>
#include <VectorBuffer.h>
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
#include <thread>
#define MODULE "kit"

namespace kit {

namespace pv = PolyVox;
namespace magic = Urho3D;
using interface::Event;
using json::jstr;

// A signal passed along more links than this is a loop, and cut
static const int MAX_HOPS = 16;
static const size_t MAX_QUEUE = 4096;
// [KIT] stage 7b's first part: named timers an instance (c:after)
static const size_t MAX_TIMERS = 64;
// [KIT] stage 4l: the window costs are measured over
static const int64_t COST_WINDOW_US = 5000000;
// A run's slice of the box's meter is its budget() / this (about 5 ms of
// a plain loop); a tick works through TICK_SLICES of them at most
static const int64_t SLICE_DIV = 20;
static const int64_t TICK_SLICES = 4;
static const size_t MAX_TYPE_SOURCE = 256 << 10;
// A zone's or an owned volume's extent in cells, each way, and the cells
// a volume has at most
static const int MAX_EXTENT = 64;
static const int MAX_VOLUME = 64;
// The cells a grants type's c:set_voxel sets at most (its box)
static const int MAX_SET_CELLS = 4096;
// [KIT_VOXEL_STATES] A voxel_box's extent each way, a pattern parameter's
// bytes and the voxel names in it at most
static const int MAX_VOXEL_BOX = 16;
static const size_t MAX_PATTERN = 32768;
static const size_t MAX_PATTERN_NAMES = 256;
// The most of an item a player has (Kit's own counts, c:add)
static const int64_t MAX_ITEMS = 1000000;
// What an editor's packet may be and do
static const size_t MAX_EDIT_PACKET = 4096;
static const size_t MAX_STRING = 256;
static const double MAX_COORD = 30000;
static const size_t MAX_ENTITIES = 4096;
static const size_t MAX_LINKS = 64;
// [KIT] stage 4g: the builders' voxel types and uploaded textures a save
// has at most, and what an upload may be
static const size_t MAX_VOXEL_TYPES = 256, MAX_TEXTURES = 256;
static const size_t MAX_TEXTURE_BYTES = 64 << 10;
static const uint32_t MAX_TEXTURE_SIDE = 128;
// An editor's undo goes back this many edits
static const size_t UNDO_MAX = 50;
// [KIT_VOXEL_EDITS] The edited sections "kit:edited" lists at most
static const size_t MAX_EDITED_LISTED = 256;
// [KIT] stage 4d: the entities play makes at most (copies), a prefab's
// members, the lines an entity's log keeps, the signals a tick shows the
// builders flowing
static const size_t MAX_MADE = 1024;
static const size_t MAX_PREFAB = 64;
// [KIT_PREFAB_VOXELS] A prefab's voxel box each way, and the kinds of cell
// (a voxel, its param and tint) in it at most
static const int MAX_PREFAB_BOX = 64;
static const size_t MAX_PREFAB_KINDS = 256;
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
// [KIT] stage 5: what a Kit package may be, packed and unpacked, and the
// packages a save has at most
static const size_t MAX_PACKAGE_BYTES = 1 << 20, MAX_PACKAGE_UNPACKED = 4 << 20;
static const size_t MAX_PACKAGES = 128;

struct Link
{
	ss_ output;
	uint64_t to = 0;
	ss_ input;
	// [KIT] stage 4l: its signals are drawn for players too, in play
	bool visible = false;
};

struct Instance
{
	ss_ type; // "<author>/<name>"
	int64_t version = 1; // authored: the type's version it was made with
	json::Value params = json::object(); // authored
	sv_<Link> links; // authored
	json::Value state = json::object(); // runtime
	ss_ disabled; // runtime: why, "" while it runs
	// runtime: its timers (c:after), each by its name and player ("" the
	// shared one), when due on the game's clock, and who set off the run
	// that set it ([KIT] stage 7b's first part: named, many an instance)
	struct Timer {
		ss_ name, player;
		int64_t due_us = 0;
		ss_ by;
	};
	sv_<Timer> timers;
	// runtime: the players in its zone, by their entity's id ([KIT] stage
	// 4d: saved, so a restart does not enter them again)
	std::set<ss_> inside;
	// authored: a prefab copy's parameters set on this copy, kept as the
	// prefab changes ([KIT] stage 4d)
	std::set<ss_> overrides;
	// runtime, not saved ([KIT] stage 4l): the meter it spent in this cost
	// window
	int64_t spent = 0;
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
	// [KIT_ENVIRONMENT] it is an environment (kit/environment: the root's
	// for every scene, a scene's own for it)
	bool environment = false;
	ss_ spawn_param;
	// Its voxel writes are builds by the player who set the run off, not
	// game changes (builds = true)
	bool builds = false;
	int64_t version = 1;
	// The position parameters that are its zone's, its owned volume's and
	// its grants' extent ("" for none)
	ss_ zone, volume, grants;
	// [KIT] stage 4j: the position parameter that is its region's extent
	// ("" none): it decides digging, placing, entering, pvp and damage in
	// it by its state's rules and owners
	ss_ region;
	// [KIT_VOXEL_STATES] The position parameter that is the box its
	// c:set_voxels writes in ("" none), and whether its runs read that
	// box's voxels (reads_voxels = true)
	ss_ voxel_box;
	bool reads_voxels = false;
};

// [KIT_VOXEL_STATES] A voxel pattern (a "voxels" parameter): a box's
// size, its voxel names and each cell's index in them, in box order (x
// fastest, then z, then y). Its text: "<sx> <sy> <sz>;<name> ...;<run>
// ..." with a run "<i>" or "<i>*<n>" (i from 0); "" is no pattern
struct Pattern
{
	int n[3] = {0, 0, 0};
	sv_<ss_> names;
	sv_<uint16_t> cells;
};

static bool voxel_name_ok(const ss_ &v)
{
	if(v.empty() || v.size() > 64)
		return false;
	for(char c : v)
		if(!isalnum((unsigned char)c) && c != '_' && c != ':' && c != '/')
			return false;
	return true;
}

// The pattern in `text`, or false and why
static bool parse_pattern(const ss_ &text, Pattern &out, ss_ &why)
{
	out = Pattern();
	if(text.size() > MAX_PATTERN){
		why = "a pattern of at most "+itos(MAX_PATTERN)+" bytes";
		return false;
	}
	const size_t a = text.find(';'), b = a == ss_::npos ? a :
			text.find(';', a + 1);
	if(b == ss_::npos){
		why = "a pattern: \"<sx> <sy> <sz>;<names>;<runs>\"";
		return false;
	}
	{
		std::istringstream is(text.substr(0, a));
		size_t total = 1;
		for(int k = 0; k < 3; k++){
			if(!(is >> out.n[k]) || out.n[k] < 1 || out.n[k] > MAX_VOXEL_BOX){
				why = "a pattern's size: three whole numbers 1..."+
						itos(MAX_VOXEL_BOX);
				return false;
			}
			total *= out.n[k];
		}
		out.cells.reserve(total);
	}
	{
		std::istringstream is(text.substr(a + 1, b - a - 1));
		ss_ v;
		while(is >> v){
			if(!voxel_name_ok(v) || out.names.size() >= MAX_PATTERN_NAMES){
				why = "a pattern's names: at most "+itos(MAX_PATTERN_NAMES)+
						" voxel names";
				return false;
			}
			out.names.push_back(v);
		}
	}
	const size_t total = (size_t)out.n[0] * out.n[1] * out.n[2];
	std::istringstream is(text.substr(b + 1));
	ss_ run;
	while(is >> run){
		const size_t star = run.find('*');
		char *end = nullptr;
		const long i = strtol(run.c_str(), &end, 10);
		long n = 1;
		if(star != ss_::npos)
			n = strtol(run.c_str() + star + 1, nullptr, 10);
		if(end == run.c_str() || (star == ss_::npos ? *end != 0 :
				end != run.c_str() + star) || i < 0 ||
				(size_t)i >= out.names.size() || n < 1 ||
				out.cells.size() + n > total){
			why = "a pattern's runs: \"<i>\" or \"<i>*<n>\", its cells "+
					itos(total);
			return false;
		}
		out.cells.insert(out.cells.end(), n, (uint16_t)i);
	}
	if(out.cells.size() != total){
		why = "a pattern of "+itos(total)+" cells has "+
				itos(out.cells.size());
		return false;
	}
	return true;
}

// A box's voxels (names in box order) as a pattern's text
static ss_ encode_pattern(const int n[3], const sv_<ss_> &cells)
{
	sv_<ss_> names;
	sm_<ss_, size_t> index;
	ss_ runs;
	for(size_t i = 0; i < cells.size();){
		auto it = index.find(cells[i]);
		if(it == index.end()){
			it = index.insert(std::make_pair(cells[i], names.size())).first;
			names.push_back(cells[i]);
		}
		size_t j = i + 1;
		while(j < cells.size() && cells[j] == cells[i])
			j++;
		runs += (runs.empty() ? "" : " ")+itos(it->second)+
				(j - i > 1 ? "*"+itos(j - i) : "");
		i = j;
	}
	ss_ o = itos(n[0])+" "+itos(n[1])+" "+itos(n[2])+";";
	for(size_t i = 0; i < names.size(); i++)
		o += (i ? " " : "")+names[i];
	return o+";"+runs;
}

struct Run
{
	uint64_t entity = 0;
	size_t comp = 0;
	ss_ handler;
	json::Value args = json::array();
	ss_ by = "app"; // who caused it, carried along the links
	int hops = 0;
	// [KIT_TRY_INPUTS] The peer + 1 of the builder whose Try it is (0:
	// none), told what it emits
	size_t tried = 0;
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
	// [KIT] stage 4j: where they last stood that they may enter (a refused
	// region puts them back), and when they were last told why
	double ok_pos[3] = {0, 0, 0};
	bool has_ok = false;
	int64_t told_us = 0;
};

// A builder's colour while their tools are on: the first one no other
// builder has
static const char *COLORS[] = {"#ff5a4a", "#4aa0ff", "#50d050", "#ffb030",
	"#c060ff", "#30d0d0", "#ff70c0", "#c0c040"};
static const int NUM_COLORS = sizeof COLORS / sizeof COLORS[0];

// [KIT] stage 4c: a cell play changed and who: a build ('b', kept only if a
// builder keeps it at Stop) or kept as it is made ('k': a live edit, or a
// build with "Always keep builds"), and the voxel it was given. A cell the
// game changed has none; a build whose voxel is another at Stop was
// changed by the game after (the last writer's). A game write leaves a 'k'
// mark: Stop writes the cell back as edited. [KIT_ROUND_START] A build over
// an edit keeps the edit under it (under_by, under_id), given back when the
// build is discarded or the game writes over it
struct Mark
{
	char kind = 'b';
	ss_ by;
	uint32_t id = 0;
	ss_ under_by; // empty: no edit under it
	uint32_t under_id = 0;
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
	// [KIT_EDIT_VOXELS] a voxel edit's scene (the builder's), its cell in
	// cells; nullptr: the World's
	main_context::SceneReference scene = nullptr;
	// [KIT_VOXEL_EDITS] a regeneration's sections (the World's), their
	// cells that differed from the generator's in cells: undone once they
	// are generated again
	sv_<pv::Vector3DInt16> regen;
	// [KIT_PREFAB_VOXELS] stroke -3: a prefab's place, its entities in
	// before and its voxels' cells in cells (scene's), undone together
};

// [KIT] stage 4f: a decoration on a heightmap surface: a voxel object of
// its structure's model, turned about y (degrees)
struct Decor
{
	ss_ structure;
	float x = 0, y = 0, z = 0, yaw = 0;
	unsigned node = 0;
};

// [KIT] stage 4e: a scene's World (world.h; [KIT_SCENES] one a scene):
// the parameters applied (its row) and parsed, the finite map's lowest and
// highest ground, the section each player is in (an infinite world loads
// round them), and the sections generated (logged as worldgen's queue
// empties)
struct World
{
	// The scene's name and its reference
	ss_ name;
	main_context::SceneReference world_scene = nullptr;
	// [KIT_HM_FREE] The World's voxels when it is a heightmap: a section
	// not loaded is air (never generated round a player); an edit
	// generates its own (hm_section())
	voxelworld::Instance *hm_world = nullptr;
	json::Value world_applied;
	world::Params wp;
	int world_min = 0, world_max = 0;
	int section_size = 32;
	sm_<size_t, std::array<int32_t, 3>> world_peers;
	// Where players appear on a voxel World: the cell their feet go in
	std::array<int, 3> world_spawn = {{0, 1, 0}};
	size_t world_generated = 0, world_logged = 0;
	// A regeneration whose sections are not all generated again yet
	bool world_regenerating = false;
	// [KIT_SCENES_GENERATED] A World with no section in the save, its
	// first sections not all generated yet (a new scene's)
	bool world_first = false;
	// The loaded sections regenerate() unloaded: the load points bring them
	// back over the next passes, so an empty worldgen queue is not the end
	// until each is in again ([KIT_REGENERATED_EARLY])
	// simplified: one the load points no longer reach keeps the notice
	// back until the next regeneration
	sv_<pv::Vector3DInt16> regen_wait;
	// [KIT_VOXEL_EDITS] what the World's generator was made of, for a
	// copy that says what a section would be (generated())
	world::Params gen_p;
	world::Ids gen_ids;
	int gen_hi = 0;
	bool gen_voxels = false;
	// The decorations on a heightmap surface (its row "decor"), by id, and
	// the voxel objects' models made, by structure
	std::map<uint64_t, Decor> decor;
	uint64_t next_decor = 1;
	bool decor_dirty = false;
	std::set<ss_> decor_models;
	// [KIT_VOXEL_FORMAT] its sky light (apply_sky()) and the loaded
	// sections' relight under way
	bool sky = false;
	size_t sky_relight = 0;
	size_t sky_left = 0;
	int64_t sky_relight_us = 0, sky_relight_t0 = 0, sky_relight_max_us = 0;
	// [KIT_HM_FREE] its heightmap's loaded sections, logged as they change
	size_t hm_loaded = 0;
	int hm_ticks = 0;
};

// [KIT_SCENES] The World the code at hand is about, for a scope: m_w set
// to w (null: left as it is) and put back after
struct WorldScope
{
	World *&ref;
	World *was;
	WorldScope(World *&ref, World *w): ref(ref), was(ref)
	{
		if(w)
			ref = w;
	}
	~WorldScope(){ ref = was; }
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

// A section's copy for the store (its key, the copy), or
// ([KIT_ROUND_START]) a generator's merge into a copied section: its part
// of the merge's volume, to make into the copy too
struct Copy
{
	ss_ key, data;
	up_<interface::VoxelVolume> merge;
	bool has_owned = false;
	pv::Region owned;
	bool keep_standing = false;
};

// [KIT] stage 4c: voxelworld's side of the copy-on-write start. A section's
// voxels before the round first writes to it, queued for Kit's thread (it
// comes on voxelworld's, under its lock) as the store's key and the copy;
// then a merge into a copied one (`copied`, the copies' keys: the round's
// before this watch, and those it made), after its copy
struct Watch: public voxelworld::SectionWatch
{
	ss_ scene;
	std::mutex *mutex;
	std::deque<Copy> *queue;
	std::set<ss_> copied;
	ss_ key_of(const pv::Vector3DInt16 &sp)
	{
		return "start:"+scene+":"+itos(sp.getX())+","+
				itos(sp.getY())+","+itos(sp.getZ());
	}
	void before_write(voxelworld::Instance *world,
			const pv::Vector3DInt16 &sp, const interface::VoxelVolume &before)
	{
		Copy c;
		c.key = key_of(sp);
		c.data = interface::serialize_volume_compressed(before);
		std::lock_guard<std::mutex> lock(*mutex);
		copied.insert(c.key);
		queue->push_back(std::move(c));
	}
	void merged(voxelworld::Instance *world, const pv::Vector3DInt16 &sp,
			const interface::VoxelVolume &volume, const pv::Region *owned,
			bool keep_standing)
	{
		Copy c;
		c.key = key_of(sp);
		{
			std::lock_guard<std::mutex> lock(*mutex);
			if(!copied.count(c.key))
				return;
		}
		// The merge's part in the section
		pv::Region r = volume.getEnclosingRegion();
		const pv::Vector3DInt16 ss = world->get_section_size_voxels();
		const pv::Vector3DInt32 sl(sp.getX() * ss.getX(),
				sp.getY() * ss.getY(), sp.getZ() * ss.getZ());
		r.cropTo(pv::Region(sl, sl + pv::Vector3DInt32(ss.getX() - 1,
				ss.getY() - 1, ss.getZ() - 1)));
		const pv::Vector3DInt32 lc = r.getLowerCorner();
		const pv::Vector3DInt32 uc = r.getUpperCorner();
		if(lc.getX() > uc.getX() || lc.getY() > uc.getY() ||
				lc.getZ() > uc.getZ())
			return;
		c.merge.reset(new interface::VoxelVolume(r, volume.planes()));
		const size_t n = (size_t)(uc.getX() - lc.getX() + 1);
		for(int z = lc.getZ(); z <= uc.getZ(); z++)
		for(int y = lc.getY(); y <= uc.getY(); y++)
			c.merge->copy_run_from(volume, lc.getX(), y, z, lc.getX(), y, z, n);
		c.has_owned = owned != nullptr;
		if(owned)
			c.owned = *owned;
		c.keep_standing = keep_standing;
		std::lock_guard<std::mutex> lock(*mutex);
		queue->push_back(std::move(c));
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
	// [KIT] stage 5: the Kit packages installed (rows
	// "package:<fp>/<name>", [AITTA_KEY_IDENTITY]), by id, and their
	// component types, {"source", "client", "package"} by type
	sm_<ss_, json::Value> m_packages;
	// [AITTA_KEY_IDENTITY] The vouches asked of the Aittas the installing
	// clients named, each a GET on a thread of its own: the package's id
	// and when (once per package and key; one unreached is asked again
	// after VOUCH_AGAIN_US), their answers ("" or why not) as they come
	struct VouchResults {
		std::mutex m;
		sv_<std::pair<ss_, ss_>> r;
	};
	std::shared_ptr<VouchResults> m_vouches =
			std::make_shared<VouchResults>();
	sm_<ss_, int64_t> m_vouch_asked;
	// The peers on this machine (a loopback address): the Aitta they name
	// may be on its loopback too
	std::set<size_t> m_local_peers;
	sm_<ss_, json::Value> m_package_types;
	// The app's defaults for parameters, {type: {param: value}}
	json::Value m_defaults = json::object();
	std::set<ss_> m_palette;
	// Bare type names made <author>/<name> as the composition was read
	size_t m_migrated = 0;
	// [KIT] stage 4j: the entities a load made regions of dig zones
	std::set<uint64_t> m_from_dig_zone;
	// A handler's answer (what it returned: [value, reason]), the last run's
	json::Value m_ret = json::null();
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
	std::deque<Copy> m_copies;
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
	// [KIT_PREFAB_VOXELS] Each builder's copy: an unnamed prefab ("copy"),
	// and a place's voxels, written once its entities are in (on_edit())
	sm_<ss_, json::Value> m_clipboard;
	struct VoxelPaste
	{
		json::Value vox;
		int base[3] = {0, 0, 0};
		int turn = 0;
		bool set = false;
	} m_paste;
	// Those that did not load (logged once), and those loading now (a
	// prefab naming itself is none)
	std::set<ss_> m_bad_prefabs, m_prefab_loading;
	// Signals passed along links this tick, for the builders' link lines
	json::Value m_flows = json::array();
	// [KIT] stage 4l: the signals along links shown in play, by scene; its
	// players not editing are sent them
	std::map<ss_, json::Value> m_play_flows;
	// Each entity's log (its c:log lines and Kit's about it), not saved,
	// and those with new lines this tick
	std::map<uint64_t, std::deque<ss_>> m_logs;
	std::set<uint64_t> m_log_dirty;
	int m_remove_depth = 0;
	// Ids of entities being made together (a composition, a prefab's
	// copy), which an entity parameter may name before they are there
	std::set<uint64_t> m_pending_ids;
	// [KIT] stage 4e: the material set the Worlds are made of
	world::MaterialSet m_materials;
	// [KIT_SCENES] Each scene's World, by the scene's name, and the one the
	// code at hand is about (m_w; use_world()). A scene not the app's World
	// scene's kind (Host::world_scene "": none) has m_none's
	std::map<ss_, World> m_worlds;
	World m_none;
	World *m_w = &m_none;
	// Guests' dropped entities' names by their `by`, for this run
	// simplified: kept for the run (a name each guest that came)
	sm_<ss_, ss_> m_gone_guests;
	// [KIT] stage 4g: the builders' voxel types (rows "voxel:<name>") by
	// name, and the uploaded textures' served names (rows
	// "texture:<hash>")
	sm_<ss_, json::Value> m_voxel_types;
	// [KIT] stage 6a (Host::app_items): each player's inventory as the app
	// last gave it (set_items), by name
	sm_<ss_, json::Value> m_app_items;
	std::set<ss_> m_textures;
	// The properties of what register_voxels() and a builder's type
	// registered, by name (voxel_type())
	sm_<ss_, world::Material> m_registered;
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
		sub(m_server, "network:packet_received/kit:texture",
				&Module::on_texture);
		sub(m_server, "network:packet_received/kit:package",
				&Module::on_package);
		sub(m_server, "kit:use_through", &Module::on_use);
		sub(m_server, "kit:edit_through", &Module::on_edit);
		sub(m_server, "network:client_disconnected", &Module::on_left);
		sub(m_server, "network:client_connected", &Module::on_joined);
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
		// [KIT_INTERP_SLICE] In the interpreter (the compile under way, a
		// cold cache) a handler's slice is a tick's: its units are a
		// sixteenth of the compiled engine's, and a handler fine there was
		// disabled for good here
		const bool interp = m_box->engine_name().compare(0, 11,
				"interpreter") == 0;
		const int64_t slice = request[0] == 'D' || request[0] == 'L' ?
				m_box->budget() : request[0] == 'S' ? m_box->budget() / 4 :
				m_box->budget() / SLICE_DIV * (interp ? TICK_SLICES : 1);
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
	// (Kit's and the app's; other authors' are installed packages',
	// m_package_types)
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
		// [KIT] stage 5: an installed package's, else the author's files
		const ss_ dir = author_path(author);
		auto pt = m_package_types.find(name);
		if(dir.empty() && pt == m_package_types.end()){
			why = "no component type "+name+" (no types of "+author+" here)";
			return false;
		}
		const bool pkg = pt != m_package_types.end();
		const ss_ path = pkg ? "package "+jstr(pt->second, "package") :
				dir+"/"+short_name+".lua";
		const ss_ src = pkg ? jstr(pt->second, "source") : read_file(path);
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
		const ss_ client = pkg ? jstr(pt->second, "client") :
				read_file(dir+"/"+short_name+".client.lua");
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
		// [KIT_USE_ACCESS] Who may use it, the engine's on every usable type
		// (on_use() asks it): all, owners (of the region holding it) or
		// nobody (used through its links only)
		if(t.usable){
			json::Value ps = t.decl.get("params");
			if(!ps.is_object())
				ps = json::object();
			if(!ps.get("use").is_undefined()){
				why = name+": \"use\" is Kit's parameter on a usable type";
				return false;
			}
			json::Value u = json::object();
			u.set("type", "string");
			u.set("default", "all");
			json::Value ch = json::array();
			for(const char *c : {"all", "owners", "nobody"})
				ch.append(c);
			u.set("choices", ch);
			ps.set("use", u);
			t.decl.set("params", ps);
		}
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
		t.environment = t.decl.get("environment").is_true();
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
				std::make_pair("grants", &t.grants),
				std::make_pair("region", &t.region),
				std::make_pair("voxel_box", &t.voxel_box)}){
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
		// A region's too ([KIT] stage 4j: the clients say why before asking)
		if(!t.region.empty())
			for(const char *k : {"enabled", "owners", "rules", "size"})
				t.shared.insert(k);
		// A look's extent is a position parameter's too
		const ss_ lx = jstr(t.decl.get("look"), "extent");
		if(!lx.empty() && jstr(t.decl.get("params").get(lx), "type") !=
				"position"){
			why = name+": its look's extent names no position parameter";
			return false;
		}
		t.reads_voxels = t.decl.get("reads_voxels").is_true();
		if(t.reads_voxels && t.voxel_box.empty()){
			why = name+": reads_voxels reads its voxel_box, and it has none";
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

	// [KIT_VOXEL_STATES] An instance's voxel_box: its first cell and its
	// extent; false if its type has none, the entity no place, or a side
	// is past MAX_VOXEL_BOX (why)
	bool voxel_box(const Entity &e, const Instance &in, pv::Vector3DInt32 &o,
			int n[3], ss_ *why = nullptr)
	{
		const Type &t = m_types[in.type];
		if(t.voxel_box.empty() || !e.has_pos){
			if(why)
				*why = in.type+" has no voxel box";
			return false;
		}
		extent(in.params.get(t.voxel_box), n);
		for(int k = 0; k < 3; k++)
			if(n[k] > MAX_VOXEL_BOX){
				if(why)
					*why = "its box is past "+itos(MAX_VOXEL_BOX)+
							" cells a side";
				return false;
			}
		o = voxel_p(e);
		return true;
	}

	// The box's voxels' names in box order (x fastest, then z, then y),
	// "" where its section is not loaded, "air" where never written
	sv_<ss_> read_box(const Entity &e, const pv::Vector3DInt32 &o,
			const int n[3])
	{
		sv_<ss_> out((size_t)n[0] * n[1] * n[2]);
		voxelworld::access(m_server, scene_of(e), [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			size_t i = 0;
			for(int y = 0; y < n[1]; y++)
				for(int z = 0; z < n[2]; z++)
					for(int x = 0; x < n[0]; x++, i++){
						uint32_t id = 0;
						if(!voxel_id(w, o + pv::Vector3DInt32(x, y, z), id))
							continue;
						// 0: a cell never written (no generator's), air
						if(id == 0){
							out[i] = "air";
							continue;
						}
						const interface::VoxelDefinition *d = reg->get(type_of(w, id));
						if(d)
							out[i] = d->name.block_name;
					}
		});
		return out;
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
		if(t == "voxels"){
			// [KIT_VOXEL_STATES] a pattern ("": none); not an inspector
			// field (Capture and Fill set it)
			if(!v.is_string())
				return "a voxel pattern";
			Pattern pt;
			ss_ why;
			if(!v.as_string().empty() && !parse_pattern(v.as_string(), pt, why))
				return why;
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
	// [KIT] stage 5: an older version's parameters (from) as the type's
	// version takes them: through its migrate(params, from) where it has
	// one, then those it does not declare or whose value it refuses left
	// out, each logged (a migrate that fails leaves the parameters as
	// they were for that)
	void migrate_params(const ss_ &type, int64_t from, json::Value &params,
			const ss_ &who)
	{
		const Type &t = m_types[type];
		if(t.handlers.count("migrate")){
			ss_ o = "Mreturn {type=";
			lua_lit(json::Value(type), o);
			o += ",from=";
			lua_lit(json::Value(from), o);
			o += ",params=";
			lua_lit(params, o);
			o += "}";
			ss_ answer, err;
			if(box_call(o, answer, err)){
				const json::Value p = json::load_string(answer.c_str());
				params = p.is_object() ? p : json::object();
				log_i(MODULE, "%s: %s's migrate from version %lli: %s",
						cs(who), cs(type), (long long)from,
						cs(params.stringify().substr(0, 200)));
			} else {
				log_w(MODULE, "%s: %s's migrate from version %lli failed: %s",
						cs(who), cs(type), (long long)from, cs(err));
			}
		}
		const json::Value &decl = t.decl.get("params");
		json::Value kept = json::object();
		for(json::Iterator it(params); it; ++it){
			const json::Value &d = decl.get(it.key());
			const ss_ bad = !d.is_object() ? "not a parameter of it" :
					jstr(d, "type") == "entity" ? "" : check_param(d, *it);
			if(bad.empty())
				kept.set(it.key(), *it);
			else
				log_w(MODULE, "%s: %s's %s of version %lli left out: %s",
						cs(who), cs(type), cs(it.key()), (long long)from, cs(bad));
		}
		params = kept;
	}

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
			// [KIT] stage 4j: a dig zone is a region with only dig and place,
			// for everyone; its inputs on, off and dig are enable, disable
			// and dig_out (load_composition() moves the links to it)
			json::Value dz;
			if(in.type == "kit/dig_zone"){
				const json::Value &op = cj.get("params");
				dz = json::object();
				if(pos_ok(op.get("size")))
					dz.set("size", op.get("size"));
				const bool dig = !op.get("dig").is_boolean() ||
						op.get("dig").as_boolean();
				const bool place = op.get("place").is_true();
				dz.set("dig", dig ? "all" : "none");
				dz.set("place", place ? "all" : "none");
				in.type = "kit/region";
				m_from_dig_zone.insert(e.id);
				log_i(MODULE, "Entity %s's kit/dig_zone is a kit/region now "
						"(dig %s, place %s, for everyone)", cs(itos(e.id)),
						dig ? "yes" : "no", place ? "yes" : "no");
				m_migrated++;
			}
			if(!load_type(in.type, why))
				return false;
			const Type &t = m_types[in.type];
			// The version it was made with; the type's own for a new one
			const json::Value &ver = cj.get("version");
			in.version = ver.is_number() && ver.as_number() >= 1 &&
					ver.as_number() <= 1e9 ? (int64_t)ver.as_number() : t.version;
			json::Value pj = dz.is_object() ? dz : cj.get("params");
			if(dz.is_object())
				in.version = t.version;
			// A starter door, gate, button or lever of before is an object
			const bool object = migrate_object(e, in, pj);
			// [KIT] stage 5: an instance of an older version is upgraded to
			// the type's, its parameters through the type's migrate
			if(!object && in.version < t.version){
				pj = pj.is_object() ? pj.deepcopy() : json::object();
				migrate_params(in.type, in.version, pj, "Entity "+itos(e.id));
				log_i(MODULE, "Entity %s's %s upgraded from version %lli to "
						"%lli", cs(itos(e.id)), cs(in.type), (long long)in.version,
						(long long)t.version);
				in.version = t.version;
				m_upgraded++;
			}
			// simplified: a newer version's instance (a type's file put
			// back to an older one) runs on the file's
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
					// (use: Kit's, gone with a type no longer usable)
					if((object || it.key() == "use") &&
							!decl.get(it.key()).is_object())
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
				l.visible = ls.at(m).get("visible").is_boolean() &&
						ls.at(m).get("visible").as_boolean();
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
				if(l.visible)
					lj.set("visible", true);
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
		m_from_dig_zone.clear();
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
			if(e.kind == "scene" && !m_host.scenes.count(e.name) &&
					!make_scene(e.name, why))
				return false;
			if(e.has_pos && !scene_of(e)){
				why = "entity "+itos(e.id)+" has a position and no scene";
				return false;
			}
			for(Instance &in : e.comps)
				for(Link &l : in.links){
					// A dig zone's inputs, a region's now ([KIT] stage 4j)
					if(m_from_dig_zone.count(l.to))
						l.input = l.input == "on" ? "enable" : l.input == "off" ?
								"disable" : l.input == "dig" ? "dig_out" : l.input;
					if(!m_entities.count(l.to)){
						why = "entity "+itos(e.id)+": a link to "+itos(l.to)+
								", which is not there";
						return false;
					}
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

	// {"<id>": [{"type", "state", "disabled", "timers": [{"name",
	//  "player", "s", "by"}] (before stage 7b: "timer": s, "timer_by"),
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
				if(!in.timers.empty()){
					json::Value ts = json::array();
					for(const Instance::Timer &t : in.timers){
						json::Value tj = json::object();
						tj.set("name", t.name);
						if(!t.player.empty())
							tj.set("player", t.player);
						tj.set("s", std::max<int64_t>(0, t.due_us - now) / 1e6);
						tj.set("by", t.by);
						ts.append(tj);
					}
					j.set("timers", ts);
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
		const int64_t now = interface::os::game_us();
		in.timers.clear();
		const json::Value &t = s.get("timer");
		if(t.is_number() && t.as_number() >= 0){
			Instance::Timer tm;
			tm.due_us = now + (int64_t)(t.as_number() * 1e6);
			tm.by = jstr(s, "timer_by");
			in.timers.push_back(tm);
		}
		const json::Value &ts = s.get("timers");
		for(unsigned i = 0; i < ts.size() && in.timers.size() < MAX_TIMERS;
				i++){
			const json::Value &tj = ts.at(i);
			const json::Value &left = tj.get("s");
			if(!tj.is_object() || !left.is_number() || left.as_number() < 0)
				continue;
			Instance::Timer tm;
			tm.name = jstr(tj, "name");
			tm.player = jstr(tj, "player");
			tm.due_us = now + (int64_t)(left.as_number() * 1e6);
			tm.by = jstr(tj, "by");
			in.timers.push_back(tm);
		}
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

	// A type in the palette if it loads. The types on each player entity
	// ([KIT] stage 4d) are not placed: at the start (`starting`) they are
	// put on the players instead
	// simplified: a package's player type installed while the server runs
	// is on the players from the next start
	void palette_add(const ss_ &t, bool starting)
	{
		ss_ why;
		if(!load_type(t, why)){
			log_w(MODULE, "Not in the palette: %s", cs(why));
			return;
		}
		const Type &ty = m_types[t];
		if(ty.player){
			if(starting)
				m_player_types.push_back(t);
		} else if(ty.world && m_host.world_scene.empty()){
			// [KIT] stage 4e: no World where the app has none
		} else if(!m_host.controls && (ty.decl.get("controls").is_true() ||
				ty.decl.get("movement").is_object())){
			// [KIT] stage 4h: the controls and the movements where the
			// app has Kit's controls
		} else {
			m_palette.insert(t);
		}
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

		load_packages();
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
				palette_add(author+"/"+n.name.substr(0, dot), true);
			}
		}
		// [KIT] stage 5: and the installed packages'
		for(const auto &pt : m_package_types)
			palette_add(pt.first, true);
		std::sort(m_player_types.begin(), m_player_types.end());
		ss_ names;
		for(const ss_ &t : m_palette)
			names += (names.empty() ? "" : " ")+t;
		log_i(MODULE, "The palette: %s", cs(names));
		names.clear();
		for(const ss_ &t : m_player_types)
			names += (names.empty() ? "" : " ")+t;
		log_i(MODULE, "On each player: %s", cs(names));
		load_prefab_palette();
		load_builder_voxels();
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
		if(m_host.persistent){
			// [KIT] stage 6a2: the world as it stands is the game; a round
			// host's copies, marks and discarded builds dropped.
			// simplified: what a component makes (c:spawn) stays play-made
			// for good -- kept, its maker reaching it, the editor not
			// editing it; making it authored would cut its maker off
			size_t n = 0;
			m_store->batch([&](){
				for(const char *pre : {"start:", "marks:"})
					for(const ss_ &k : m_store->list(pre))
						m_store->remove(k), n++;
				m_store->remove("discarded");
			});
			if(n || !m_session.running || !m_session.restore.empty())
				log_i(MODULE, "Persistent: %zu copies and marks dropped, "
						"%zu sections not put back, Running", n,
						m_session.restore.size());
			m_session.running = true;
			m_session.restore.clear();
			save_session();
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
		// A round host's removed entities are gone in a persistent world
		if(m_host.persistent && !m_removed.empty()){
			m_removed.clear();
			m_store->set("authored", authored_json().stringify());
		}
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
					for(Instance::Timer &t : in.timers)
						if(!player_id(t.by) && !player_of(t.by).empty())
							t.by = by_of(player_of(t.by));
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
			m_registered.emplace(v.first, v.second);
			if(reg->get(n))
				continue;
			reg->add_voxel(v.second.definition(v.first));
		}
		// [KIT_VOXEL_FORMAT] the shapes of every solid cube there (Kit's,
		// and the app's own registered before); a material knows
		for(const interface::VoxelDefinition &d : reg->get_all()){
			const ss_ &name = d.name.block_name;
			if(d.id == interface::VOXELTYPEID_UNDEFINED || !d.physically_solid ||
					!d.shape.empty() || name.empty() ||
					world::material_of(name) != name)
				continue;
			auto it = m_registered.find(name);
			if(it != m_registered.end() ? !it->second.has_shapes() :
					d.alpha_masked || d.translucent)
				continue;
			register_shapes(reg, d);
		}
	}

	// [KIT_TINT_MATERIALS] An app's own voxel as a material (world.h's
	// set's voxel: its palette, its kind), registered unless it is there
	bool register_material(interface::VoxelRegistry *reg, const ss_ &name,
			const json::Value &material, ss_ *why)
	{
		world::Material m;
		if(name.empty() || world::material_of(name) != name ||
				!m.parse(material, &material.get("palettes"))){
			if(why)
				*why = "not a material: "+name;
			return false;
		}
		m_registered.emplace(name, m);
		interface::VoxelName n;
		n.block_name = name;
		if(!reg->get(n))
			reg->add_voxel(m.definition(name));
		return true;
	}

	// A cube's shape types where they are not yet
	void register_shapes(interface::VoxelRegistry *reg,
			const interface::VoxelDefinition &cube)
	{
		if(!reg->get_format().param.bound())
			return;
		for(const interface::VoxelDefinition &sd :
				world::shape_definitions(cube)){
			if(!reg->get(sd.name))
				reg->add_voxel(sd);
		}
	}

	json::Value voxel_type(const ss_ &name)
	{
		auto it = m_registered.find(world::material_of(name));
		return it == m_registered.end() ? json::Value() :
				it->second.properties();
	}

	// ---- [KIT] stage 4g: voxel types made by builders (api.h)

	// A builder's name as an author: letters, digits and _ ("" for none
	// that may be one)
	static ss_ builder_author(const ss_ &name)
	{
		ss_ author = name.substr(0, 64);
		for(char &c : author)
			if(!isalnum((unsigned char)c))
				c = '_';
		// [AITTA_KEY_IDENTITY] A key's fingerprint's shape is a package's
		return author == "kit" || interface::aitta::fingerprint_ok(author) ?
				"" : author;
	}

	// The registries of the app's scenes that have voxels
	void each_registry(std::function<void(interface::VoxelRegistry*)> f)
	{
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(auto &s : m_host.scenes){
				voxelworld::Instance *w = ivw->get_instance(s.second);
				if(w)
					f(w->get_voxel_reg());
			}
		});
	}

	// A builder's type registered where it is not yet (a new version of
	// one registered: at the next start)
	// simplified: a registry's definitions never change once added (its
	// rule), so a new version of a type is drawn at the next start
	void register_builder_voxel(const ss_ &name, const json::Value &row)
	{
		world::Material m;
		if(!m.parse(row)){
			log_w(MODULE, "Voxel type %s: not a texture, a kind, light "
					"0...15, friction 0...10 and a surface tag; not "
					"registered", cs(name));
			return;
		}
		m.layer = -1;
		// simplified: the row's at once, though drawn so at the next start
		m_registered[name] = m;
		each_registry([&](interface::VoxelRegistry *reg){
			interface::VoxelName n;
			n.block_name = name;
			if(!reg->get(n))
				reg->add_voxel(m.definition(name));
			if(m.has_shapes())
				register_shapes(reg, m.definition(name));
		});
	}

	// The save's: the uploaded textures served, the builders' types
	// registered, before a section is loaded (the save's names then
	// resolve to them)
	void load_builder_voxels()
	{
		for(const ss_ &k : m_store->list("texture:")){
			ss_ png;
			if(m_store->get(k, png))
				serve_texture(k.substr(8), png);
		}
		for(const ss_ &k : m_store->list("voxel:")){
			ss_ row;
			if(!m_store->get(k, row))
				continue;
			const json::Value r = json::load_string(row.c_str());
			m_voxel_types[k.substr(6)] = r;
			register_builder_voxel(k.substr(6), r);
		}
		log_i(MODULE, "Builders' voxel types: %zu, uploaded textures: %zu",
				m_voxel_types.size(), m_textures.size());
	}

	void serve_texture(const ss_ &hash, const ss_ &png)
	{
		const ss_ name = "kit/up/"+hash+".png";
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_content(name, png);
		});
		m_textures.insert(name);
	}

	// The textures a builder's type may wear: every registered voxel's and
	// the uploaded ones
	std::set<ss_> texture_choices()
	{
		std::set<ss_> out = m_textures;
		each_registry([&](interface::VoxelRegistry *reg){
			for(const auto &d : reg->get_all())
				for(const auto &t : d.textures)
					if(!t.resource_name.empty())
						out.insert(t.resource_name);
		});
		return out;
	}

	// The voxels to place, for the palette: each registered one but air,
	// a builder's with its properties
	json::Value voxel_palette()
	{
		json::Value out = json::array();
		std::set<ss_> seen;
		each_registry([&](interface::VoxelRegistry *reg){
			for(const auto &d : reg->get_all()){
				const ss_ &n = d.name.block_name;
				// [KIT_VOXEL_FORMAT] a shape is its material's entry's
				if(d.fully_empty || world::material_of(n) != n ||
						!seen.insert(n).second)
					continue;
				auto it = m_voxel_types.find(n);
				auto mt = m_registered.find(n);
				json::Value v = it != m_voxel_types.end() ?
						it->second.deepcopy() : mt != m_registered.end() ?
						mt->second.properties() : json::object();
				// [KIT_TINT_PALETTE] a builder's type: its material's palette
				if(it != m_voxel_types.end() && v.get("tint_names").is_undefined()){
					world::Material m;
					if(m.parse(v)){
						const json::Value p = m.properties();
						v.set("tint", p.get("tint"));
						v.set("tint_names", p.get("tint_names"));
					}
				}
				v.set("name", n);
				interface::VoxelName sn;
				sn.block_name = n+":"+world::shapes()[0].name;
				v.set("shapes", reg->get(sn) != nullptr);
				if(it == m_voxel_types.end() &&
						!d.textures[0].resource_name.empty())
					v.set("texture", d.textures[0].resource_name);
				out.append(v);
			}
		});
		return out;
	}

	// {"op": "voxel", "name", "texture", "kind", "solid", "transparent",
	// "light", "friction", "surface"}: the builder's voxel type "<their name>/<name>", or its
	// next version
	void make_voxel(const Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const ss_ short_name = jstr(j, "name");
		const ss_ author = builder_author(p.name);
		if(!name_ok(short_name))
			return refuse("name: letters, digits and _");
		if(author.empty())
			return refuse("a builder's voxel types are under their name, "
					"and it is \""+p.name.substr(0, 64)+"\"");
		const ss_ name = author+"/"+short_name;
		json::Value row = json::object();
		row.set("format", ss_("kit_voxel"));
		row.set("author", author);
		row.set("name", short_name);
		const ss_ texture = jstr(j, "texture");
		row.set("texture", texture);
		row.set("kind", jstr(j, "kind", "solid"));
		row.set("solid", !j.get("solid").is_boolean() ||
				j.get("solid").is_true());
		row.set("transparent", j.get("transparent").is_true());
		row.set("light", j.get("light").is_number() ? j.get("light") :
				json::Value((int64_t)0));
		row.set("friction", j.get("friction").is_number() ?
				j.get("friction") : json::Value(1.0));
		row.set("surface", jstr(j, "surface"));
		world::Material m;
		if(!m.parse(row) || m.light != row.get("light").as_number())
			return refuse("a texture, a kind (solid, leaves, plant, water), "
					"light (a whole number 0...15), friction 0...10 and a "
					"surface tag (letters, digits and _)");
		if(!texture_choices().count(texture))
			return refuse("texture: no voxel or upload has "+texture);
		auto old = m_voxel_types.find(name);
		if(old != m_voxel_types.end() && !jstr(old->second, "package").empty())
			return refuse(name+" is the package "+jstr(old->second, "package")+
					"'s");
		bool taken = false;
		each_registry([&](interface::VoxelRegistry *reg){
			interface::VoxelName n;
			n.block_name = name;
			taken = taken || reg->get(n);
		});
		if(old == m_voxel_types.end() && taken)
			return refuse(name+" is the app's or Kit's voxel");
		if(old == m_voxel_types.end() &&
				m_voxel_types.size() >= MAX_VOXEL_TYPES)
			return refuse("the save has "+itos(MAX_VOXEL_TYPES)+
					" builders' voxel types");
		const int64_t version = old == m_voxel_types.end() ? 1 :
				json::jint(old->second, "version", 1) + 1;
		row.set("version", version);
		m_store->set("voxel:"+name, row.stringify());
		m_voxel_types[name] = row;
		register_builder_voxel(name, row);
		log_i(MODULE, "%s made voxel type %s version %s (%s, %s%s%s, light "
				"%i, friction %g, surface \"%s\")%s", cs(p.name), cs(name),
				cs(itos(version)), cs(texture), cs(m.kind),
				m.solid ? ", solid" : "", m.transparent ? ", transparent" : "",
				m.light, m.friction, cs(m.surface),
				taken ? ": drawn so at the next start" : "");
		if(taken)
			for(auto &o : m_peers)
				if(o.second.name == p.name)
					network::access(m_server, [&](network::Interface *in){
						in->send(o.first, "kit:warning", "Voxel type "+name+
								" version "+itos(version)+" is drawn so at the "
								"next start");
					});
		for(auto &o : m_peers)
			send_state(o.first);
	}

	// "kit:texture" (a PNG's bytes): a builder with the tools on uploads a
	// texture for their voxel types; answered with "kit:texture" (its
	// name, "kit/up/<hash>.png") or "kit:edit_refused". Decoded here and
	// saved again as a PNG: a client is sent only what decoded
	void on_texture(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		auto refuse = [&](const ss_ &why){
			log_i(MODULE, "A texture by peer %zu refused: %s", peer, cs(why));
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "kit:edit_refused", "texture: "+why);
			});
		};
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !pi->second.editing ||
				!can_edit(peer))
			return refuse("the tools on, with edit rights");
		ss_ why;
		const ss_ name = store_texture(packet.data, why);
		if(name.empty())
			return refuse(why);
		log_i(MODULE, "%s uploaded texture %s", cs(pi->second.name), cs(name));
		// The state first: the answer's name is in its textures
		for(auto &o : m_peers)
			send_state(o.first);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:texture", name);
		});
	}

	// A texture's PNG checked, decoded and saved again as a PNG (a client
	// is sent only what decoded) in the row "texture:<hash>", and served:
	// its name ("kit/up/<hash>.png"), or "" and why not
	ss_ store_texture(const ss_ &d, ss_ &why)
	{
		auto refuse = [&](const ss_ &s){
			why = s;
			return ss_();
		};
		// A PNG's signature and its IHDR's sides, before it is decoded
		auto be32 = [&](size_t at){
			return (uint32_t)(uint8_t)d[at] << 24 | (uint32_t)(uint8_t)d[at +
					1] << 16 | (uint32_t)(uint8_t)d[at + 2] << 8 |
					(uint8_t)d[at + 3];
		};
		const uint32_t w = d.size() >= 24 ? be32(16) : 0,
				h = d.size() >= 24 ? be32(20) : 0;
		if(d.size() > MAX_TEXTURE_BYTES || d.compare(0, 8,
				"\x89PNG\r\n\x1a\n", 8) != 0 || w != h || w < 8 ||
				w > MAX_TEXTURE_SIDE || (w & (w - 1)))
			return refuse("a PNG of at most "+itos(MAX_TEXTURE_BYTES >> 10)+
					" KiB, square, its side a power of two 8..."+
					itos(MAX_TEXTURE_SIDE));
		if(m_textures.size() >= MAX_TEXTURES)
			return refuse("the save has "+itos(MAX_TEXTURES)+" textures");
		ss_ png;
		main_context::access(m_server, [&](main_context::Interface *imc){
			magic::Image img(imc->get_context());
			magic::MemoryBuffer in(d.data(), (unsigned)d.size());
			if(!img.Load(in) || img.IsCompressed() ||
					img.GetWidth() != (int)w || img.GetHeight() != (int)h)
				return;
			magic::VectorBuffer buf;
			if(img.Save(buf))
				png.assign((const char*)buf.GetData(), buf.GetSize());
		});
		if(png.empty())
			return refuse("not an image that decodes");
		const ss_ hash = interface::sha256::hex(
				interface::sha256::calculate(png)).substr(0, 16);
		m_store->set("texture:"+hash, png);
		serve_texture(hash, png);
		log_i(MODULE, "Texture kit/up/%s.png (%ux%u, %zu bytes)", cs(hash), w,
				h, png.size());
		return "kit/up/"+hash+".png";
	}

	// ---- Packages ([KIT] stage 5): api.h says what one is

	void load_packages()
	{
		for(const ss_ &k : m_store->list("package:")){
			ss_ row;
			if(!m_store->get(k, row))
				continue;
			const json::Value r = json::load_string(row.c_str());
			if(r.is_object())
				add_package(k.substr(8), r);
		}
		log_i(MODULE, "Kit packages: %zu", m_packages.size());
		// [AITTA_KEY_IDENTITY] Those no Aitta vouched for yet, asked again
		for(auto &p : m_packages)
			ask_vouch(p.first, p.second.get("local").is_true());
	}

	void add_package(const ss_ &name, const json::Value &r)
	{
		for(auto it = m_package_types.begin(); it != m_package_types.end();)
			if(jstr(it->second, "package") == name)
				it = m_package_types.erase(it);
			else
				++it;
		m_packages[name] = r;
		const ss_ author = name.substr(0, name.find('/'));
		const json::Value &ts = r.get("types");
		if(ts.is_object())
			for(json::Iterator it(ts); it; ++it){
				json::Value t = (*it).deepcopy();
				t.set("package", name);
				m_package_types[author+"/"+it.key()] = t;
			}
	}

	// "kit:package" (the Aitta it came from, a 0 byte, a release's .sig,
	// a 0 byte and its zip, as the Aitta serves them): a builder with the
	// tools on installs a Kit package, or a newer version of one. Answered
	// with "kit:package", {"ok": true, "what"} or {"ok": false, "why"}
	void on_package(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		auto answer = [&](bool ok, const ss_ &s){
			log_i(MODULE, "A package by peer %zu %s: %s", peer,
					ok ? "taken" : "refused", cs(s));
			json::Value a = json::object();
			a.set("ok", ok);
			a.set(ok ? "what" : "why", s);
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "kit:package", a.stringify());
			});
		};
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !pi->second.editing ||
				!can_edit(peer))
			return answer(false, "the tools on, with edit rights");
		const size_t za = packet.data.find('\0');
		const ss_ aitta = za == ss_::npos ? "" : packet.data.substr(0, za);
		const ss_ d = za == ss_::npos ? "" : packet.data.substr(za + 1);
		const size_t z = d.find('\0');
		bool plain = aitta.size() <= 200;
		for(char c : aitta)
			plain = plain && (unsigned char)c > 32 && c != 127;
		if(d.size() > MAX_PACKAGE_BYTES || z == ss_::npos || aitta.empty() ||
				!plain)
			return answer(false, "the Aitta, a 0 byte, a release's .sig, a 0 "
					"byte and its zip, "+itos(MAX_PACKAGE_BYTES >> 10)+
					" KiB at most");
		const json::Value sig = json::load_string(d.substr(0, z).c_str());
		const ss_ zip = d.substr(z + 1);
		const ss_ sha = interface::sha256::hex(
				interface::sha256::calculate(zip));
		if(jstr(sig, "format") != interface::aitta::RELEASE_FORMAT ||
				jstr(sig, "sha256") != sha || !interface::aitta::verify(
				jstr(sig, "key"), zip, jstr(sig, "signature")))
			return answer(false, "the signature does not match the archive");
		// Unpacked under the cache, read and thrown away
		const ss_ tmp = m_server->get_config().get<ss_>("cache_path")+
				"/kit_package_"+sha.substr(0, 16);
		sm_<ss_, ss_> files;
		ss_ why;
		try {
			interface::fs::create_directories(tmp+"/x");
			if(!interface::fs::write_file(tmp+"/p.zip", zip))
				throw Exception("cannot write "+tmp);
			interface::zip_extract(tmp+"/p.zip", tmp+"/x", MAX_PACKAGE_UNPACKED);
			for(const auto &e : interface::zip_list(tmp+"/p.zip"))
				if(!e.name.empty() && e.name.back() != '/')
					files[e.name] = read_file(tmp+"/x/"+e.name);
		} catch(std::exception &e){
			why = e.what();
		}
		interface::fs::remove_all(tmp);
		if(!why.empty())
			return answer(false, "the archive: "+why);
		why = install_package(pi->second.name, sig, files, aitta,
				m_local_peers.count(peer) != 0);
		if(why.compare(0, 3, "ok ") == 0)
			return answer(true, why.substr(3));
		answer(false, why);
	}

	// [AITTA_KEY_IDENTITY] What a package is called where people read
	// it: its author's name and its own, with its Aitta's host where
	// another installed package's author has that name under another key,
	// and " (unverified)" (and the host) where its Aitta did not vouch
	ss_ package_label(const ss_ &id, const ss_ &what = "")
	{
		auto pk = m_packages.find(id);
		if(pk == m_packages.end())
			return what.empty() ? id : what;
		const json::Value &mf = pk->second.get("manifest");
		const ss_ author = jstr(mf, "author");
		bool shared = false;
		for(auto &o : m_packages)
			shared = shared || (o.first.substr(0, o.first.find('/')) !=
					id.substr(0, id.find('/')) &&
					jstr(o.second.get("manifest"), "author") == author);
		const bool vouched = pk->second.get("vouched").is_true();
		const ss_ host = interface::aitta::aitta_host(jstr(pk->second, "aitta"));
		return author+"/"+(what.empty() ? jstr(mf, "name") : what)+
				(shared || !vouched ? " @"+host : "")+
				(vouched ? "" : " (unverified)");
	}

	// A package's thing, "<fp>/<n>", as people read it ("alice/lamp");
	// anything else as it is
	ss_ shown(const ss_ &n)
	{
		const size_t slash = n.find('/');
		if(slash == ss_::npos ||
				!interface::aitta::fingerprint_ok(n.substr(0, slash)))
			return n;
		const ss_ fp = n.substr(0, slash);
		for(auto &o : m_packages)
			if(o.first.compare(0, fp.size() + 1, fp+"/") == 0)
				return package_label(o.first, n.substr(slash + 1));
		return n;
	}

	// [AITTA_KEY_IDENTITY] The vouch for a package, asked of the Aitta its
	// installing client named, on a thread (vouch_guarded() narrows where
	// it goes); once per package and key, again after VOUCH_AGAIN_US where
	// it was not reached. The server's "kit_vouch" setting: "" asks any
	// Aitta a client names, "none" none, else the Aittas (origins) it
	// lists, comma-separated
	static const int64_t VOUCH_AGAIN_US = 60 * 1000000LL;
	void ask_vouch(const ss_ &id, bool loopback_ok)
	{
		auto pk = m_packages.find(id);
		if(pk == m_packages.end() || pk->second.get("vouched").is_true())
			return;
		const int64_t now = interface::os::time_us();
		auto asked = m_vouch_asked.find(id);
		if(asked != m_vouch_asked.end() && (asked->second < 0 ||
				now - asked->second < VOUCH_AGAIN_US))
			return;
		const ss_ aitta = jstr(pk->second, "aitta"),
				key = jstr(pk->second, "key"),
				author = jstr(pk->second.get("manifest"), "author");
		const ss_ allowed = m_server->get_config().get<ss_>("kit_vouch");
		bool listed = allowed.empty();
		if(allowed != "none"){
			std::istringstream list(allowed);
			ss_ a;
			while(std::getline(list, a, ','))
				listed = listed || a == aitta;
		}
		if(!listed){
			log_i(MODULE, "Package %s: unverified, kit_vouch does not "
					"ask %s", cs(id), cs(aitta));
			m_vouch_asked[id] = -1;
			return;
		}
		m_vouch_asked[id] = now;
		log_i(MODULE, "Package %s: asking %s whose key it is", cs(id),
				cs(aitta));
		std::shared_ptr<VouchResults> results = m_vouches;
		std::thread([=](){
			const ss_ why = interface::aitta::vouch_guarded(aitta, key,
					author, loopback_ok);
			std::lock_guard<std::mutex> lock(results->m);
			results->r.push_back(std::make_pair(id, why));
		}).detach();
	}

	// The vouches answered: each package's row says it, and everyone's
	// labels follow
	void take_vouches()
	{
		sv_<std::pair<ss_, ss_>> got;
		{
			std::lock_guard<std::mutex> lock(m_vouches->m);
			got.swap(m_vouches->r);
		}
		if(got.empty())
			return;
		for(auto &g : got){
			auto pk = m_packages.find(g.first);
			if(pk == m_packages.end())
				continue;
			const ss_ host = interface::aitta::aitta_host(jstr(pk->second,
					"aitta"));
			if(g.second.empty()){
				pk->second.set("vouched", true);
				m_vouch_asked[g.first] = -1;
				log_i(MODULE, "Package %s: %s's on %s", cs(g.first),
						cs(jstr(pk->second.get("manifest"), "author")), cs(host));
			} else {
				log_i(MODULE, "Package %s: unverified by %s: %s", cs(g.first),
						cs(host), cs(g.second));
				// An answer that is not a vouch stands; an unreached
				// Aitta is asked again
				if(g.second.compare(0, 23, "the Aitta was not reach") != 0)
					m_vouch_asked[g.first] = -1;
			}
			m_store->set("package:"+g.first, pk->second.stringify());
		}
		for(auto &o : m_peers)
			send_state(o.first);
	}

	// [AITTA_KEY_IDENTITY] JSON from a package, every "<author>/<n>" of an
	// author in `keys` made "<fp>/<n>" (its own author's and its
	// dependencies')
	static void resolve_names(json::Value &v, const sm_<ss_, ss_> &keys)
	{
		if(v.is_string()){
			const ss_ s = v.as_string();
			const size_t slash = s.find('/');
			auto k = slash == ss_::npos ? keys.end() :
					keys.find(s.substr(0, slash));
			if(k != keys.end() && name_ok(s.substr(slash + 1)))
				v = json::Value((k->second+s.substr(slash)).c_str());
		} else if(v.is_array()){
			for(unsigned i = 0; i < v.size(); i++){
				json::Value e = v.at(i);
				resolve_names(e, keys);
				v.set_at(i, e);
			}
		} else if(v.is_object()){
			sv_<ss_> ks;
			for(json::Iterator it(v); it; ++it)
				ks.push_back(it.key());
			for(const ss_ &k : ks){
				json::Value e = v.get(k);
				resolve_names(e, keys);
				v.set(k, e);
			}
		}
	}

	// A package's files installed: "ok <what was done>", or why not.
	// aitta: the one its client named it from; loopback_ok: that client
	// is on this machine
	ss_ install_package(const ss_ &by, const json::Value &sig,
			sm_<ss_, ss_> &files, const ss_ &aitta, bool loopback_ok)
	{
		const json::Value m = json::load_string(files["meta.json"].c_str());
		ss_ why = interface::aitta::check_manifest(m);
		if(!why.empty())
			return "meta.json: "+why;
		if(interface::aitta::kind_of(m) != "kit")
			return "not a Kit package (\"kind\": \"kit\")";
		const ss_ key = jstr(sig, "key"),
				fp = interface::aitta::fingerprint(key);
		if(fp.empty())
			return "the signature's key is not a key";
		// [AITTA_KEY_IDENTITY] A package is its key's and its name: two
		// Aittas' "alice" are two, and nothing here pins an author's name
		// to a key. Its things are "<fp>/<n>"; author is what people read
		const ss_ author = jstr(m, "author"), name = fp+"/"+jstr(m, "name"),
				named = author+"/"+jstr(m, "name"),
				version = jstr(m, "version");
		auto old = m_packages.find(name);
		const ss_ old_version = old == m_packages.end() ? "" :
				jstr(old->second, "version");
		if(!old_version.empty() &&
				!interface::aitta::version_less(old_version, version)){
			// Not vouched yet: asked again (an Aitta unreached before)
			if(old->second.get("vouched").is_true() == false &&
					jstr(old->second, "aitta") == aitta)
				ask_vouch(name, loopback_ok);
			return "ok "+named+" "+old_version+" is installed already";
		}
		if(old_version.empty() && m_packages.size() >= MAX_PACKAGES)
			return "the save has "+itos(MAX_PACKAGES)+" packages";
		// Its dependencies, "author/name", the installed ones from its
		// Aitta (or as an older version of it resolved them): each its
		// "<fp>/<name>" in the row's "deps", and its author's names
		// resolved through it
		const json::Value &deps = m.get("dependencies");
		sm_<ss_, ss_> keys;
		keys[author] = fp;
		json::Value resolved = json::object();
		for(unsigned i = 0; i < deps.size(); i++){
			const ss_ dn = jstr(deps.at(i), "kit"),
					dv = jstr(deps.at(i), "version");
			const ss_ kept = old == m_packages.end() ? "" :
					jstr(old->second.get("deps"), dn.c_str());
			auto have = m_packages.find(kept);
			if(have == m_packages.end()){
				for(auto o = m_packages.begin(); o != m_packages.end(); ++o){
					const json::Value &om = o->second.get("manifest");
					if(jstr(om, "author")+"/"+jstr(om, "name") == dn &&
							jstr(o->second, "aitta") == aitta)
						have = o;
				}
			}
			if(have == m_packages.end() || interface::aitta::version_less(
					jstr(have->second, "version"), dv))
				return "it needs "+dn+" "+dv+" or newer from "+
						interface::aitta::aitta_host(aitta)+": install that first";
			const ss_ da = dn.substr(0, dn.find('/')),
					dfp = have->first.substr(0, have->first.find('/'));
			if(keys.count(da) && keys[da] != dfp)
				return "two of its packages' authors are "+da+", by two keys";
			keys[da] = dfp;
			resolved.set(dn, have->first);
		}
		// Its contents: types/<name>.lua (and <name>.client.lua),
		// <name>.prefab.json and <name>.voxel.json; textures/<file>.png
		json::Value types = json::object();
		sm_<ss_, json::Value> prefabs, voxels;
		for(auto &f : files){
			if(f.first.compare(0, 6, "types/") != 0)
				continue;
			const ss_ base = f.first.substr(6);
			ss_ n, kind;
			for(const char *suffix : {".client.lua", ".prefab.json",
					".voxel.json", ".lua"}){
				const size_t sl = strlen(suffix);
				if(base.size() > sl && base.compare(base.size() - sl, sl,
						suffix) == 0){
					n = base.substr(0, base.size() - sl);
					kind = suffix;
					break;
				}
			}
			if(kind.empty())
				continue;
			if(!name_ok(n))
				return f.first+": a name is letters, digits and _";
			if(kind == ".prefab.json" || kind == ".voxel.json"){
				const json::Value j = json::load_string(f.second.c_str());
				if(!j.is_object())
					return f.first+": not a JSON object";
				json::Value r = j.deepcopy();
				resolve_names(r, keys);
				(kind == ".prefab.json" ? prefabs : voxels)[fp+"/"+n] = r;
				continue;
			}
			json::Value t = types.get(n).is_object() ? types.get(n) :
					json::object();
			t.set(kind == ".lua" ? "source" : "client", f.second);
			types.set(n, t);
		}
		for(json::Iterator it(types); it; ++it){
			const ss_ t = fp+"/"+it.key();
			if(jstr(*it, "source").empty())
				return "types/"+it.key()+".client.lua: no "+it.key()+".lua";
			auto pt = m_package_types.find(t);
			if(pt != m_package_types.end() && jstr(pt->second, "package") != name)
				return t+" is "+jstr(pt->second, "package")+"'s here";
		}
		// A newer version keeps the types the composition may use
		if(old != m_packages.end()){
			const json::Value &ot = old->second.get("types");
			for(json::Iterator it(ot); ot.is_object() && it; ++it)
				if(!types.get(it.key()).is_object())
					return version+" has no "+named.substr(0, named.find('/'))+
							"/"+it.key()+", which "+
							old_version+" had";
		}
		for(auto &p : prefabs){
			ss_ row;
			if(m_store->get("prefab:"+p.first, row) && jstr(json::load_string(
					row.c_str()), "package") != name)
				return "the prefab "+p.first+" is a builder's here";
		}
		for(auto &v : voxels){
			auto vt = m_voxel_types.find(v.first);
			if(vt != m_voxel_types.end() ? jstr(vt->second, "package") != name :
					m_registered.count(v.first) != 0)
				return "the voxel type "+v.first+" is another's here";
		}
		if(types.size() + prefabs.size() + voxels.size() == 0)
			return "no types, prefabs or voxel types in types/";
		// The textures its voxel types wear, stored as an upload's
		for(auto &v : voxels){
			const ss_ tex = jstr(v.second, "texture");
			if(tex.compare(0, 9, "textures/") == 0){
				auto f = files.find(tex);
				if(f == files.end())
					return v.first+": its texture "+tex+" is not in the archive";
				ss_ twhy;
				const ss_ served = store_texture(f->second, twhy);
				if(served.empty())
					return tex+": "+twhy;
				v.second.set("texture", served);
			} else if(!texture_choices().count(tex)){
				return v.first+": no voxel or upload has the texture "+tex;
			}
			world::Material mt;
			if(!mt.parse(v.second))
				return v.first+": not a texture, a kind, light 0...15, "
						"friction 0...10 and a surface tag";
		}
		// The types as the box takes them, then the prefabs on them; on a
		// refusal the old version's are put back
		std::set<ss_> names;
		for(json::Iterator it(types); it; ++it)
			names.insert(fp+"/"+it.key());
		json::Value row = json::object();
		row.set("version", version);
		row.set("key", key);
		row.set("aitta", aitta);
		row.set("local", loopback_ok);
		row.set("deps", resolved);
		// A vouch stands for its Aitta's key, which the id is
		row.set("vouched", old != m_packages.end() &&
				jstr(old->second, "aitta") == aitta &&
				old->second.get("vouched").is_true());
		row.set("sha256", jstr(sig, "sha256"));
		row.set("by", by);
		row.set("manifest", m);
		row.set("types", types);
		json::Value was = old == m_packages.end() ? json::Value() : old->second;
		auto reload = [&](){
			for(const ss_ &t : names){
				m_types.erase(t);
				m_sources.erase(t);
			}
		};
		reload();
		add_package(name, row);
		for(const ss_ &t : names)
			if(!load_type(t, why))
				break;
		for(auto &p : prefabs){
			if(!why.empty())
				break;
			p.second.set("author", author);
			p.second.set("name", p.first.substr(fp.size() + 1));
			p.second.set("package", name);
			m_bad_prefabs.erase(p.first);
			ss_ pwhy;
			if(!check_prefab(p.second, pwhy))
				why = "the prefab "+p.first+": "+pwhy;
		}
		if(!why.empty()){
			reload();
			if(was.is_object()){
				add_package(name, was);
				ss_ ignore;
				for(const ss_ &t : names)
					load_type(t, ignore);
			} else {
				m_packages.erase(name);
				add_package(name, json::object());
				m_packages.erase(name);
			}
			return why;
		}
		json::Value pl = json::array(), vl = json::array();
		for(auto &p : prefabs){
			m_store->set("prefab:"+p.first, p.second.stringify());
			m_prefabs[p.first] = p.second;
			m_prefab_palette.insert(p.first);
			pl.append(p.first);
		}
		for(auto &v : voxels){
			v.second.set("format", ss_("kit_voxel"));
			v.second.set("author", author);
			v.second.set("name", v.first.substr(fp.size() + 1));
			v.second.set("package", name);
			m_store->set("voxel:"+v.first, v.second.stringify());
			m_voxel_types[v.first] = v.second;
			register_builder_voxel(v.first, v.second);
			vl.append(v.first);
		}
		row.set("prefabs", pl);
		row.set("voxels", vl);
		m_packages[name] = row;
		m_store->set("package:"+name, row.stringify());
		for(const ss_ &t : names)
			palette_add(t, false);
		// An upgrade: each authored instance of an older version of its
		// types made the new one's (entity_from_json() migrates it)
		// simplified: the authored ones; an entity made in play runs on
		// the new version with the parameters it was made with
		sv_<std::pair<uint64_t, json::Value>> change;
		for(auto &e : m_entities){
			if(!authored(e.second))
				continue;
			bool older = false;
			for(const Instance &in : e.second.comps)
				older = older || (names.count(in.type) &&
						in.version < m_types[in.type].version);
			if(older)
				change.push_back(std::make_pair(e.first, entity_json(e.second)));
		}
		if(!change.empty())
			commit(change, nullptr);
		ask_vouch(name, loopback_ok);
		const ss_ what = (old_version.empty() ? "installed "+named+" "+version :
				"upgraded "+named+" from "+old_version+" to "+version)+": "+
				itos(names.size())+" types, "+itos(prefabs.size())+
				" prefabs, "+itos(voxels.size())+" voxel types"+
				(change.empty() ? "" : ", "+itos(change.size())+
				" entities upgraded");
		log_i(MODULE, "%s %s (%s, from %s)", cs(by), cs(what), cs(name),
				cs(aitta));
		for(auto &o : m_peers)
			send_state(o.first);
		return "ok "+what;
	}

	// [KIT] stage 5: who made what the composition uses, for the credits:
	// each package its types and prefabs came in, and each other author
	// (Kit, the app's, a builder's prefabs), with what of theirs it uses
	json::Value credits()
	{
		sm_<ss_, std::set<ss_>> uses; // "p<package>" or "a<author>": what
		auto by = [&](const ss_ &n, const ss_ &pkg, const ss_ &what){
			uses[pkg.empty() ? "a"+n.substr(0, n.find('/')) : "p"+pkg].insert(
					what);
		};
		for(auto &e : m_entities){
			if(!authored(e.second))
				continue;
			for(const Instance &in : e.second.comps){
				auto pt = m_package_types.find(in.type);
				by(in.type, pt == m_package_types.end() ? "" :
						jstr(pt->second, "package"), in.type);
			}
			const ss_ of = jstr(e.second.prefab, "of");
			const json::Value *pf = of.empty() ? nullptr : prefab(of);
			if(pf)
				by(of, jstr(*pf, "package"), "["+of+"]");
		}
		json::Value out = json::array();
		for(auto &u : uses){
			json::Value c = json::object();
			const ss_ n = u.first.substr(1);
			auto pk = m_packages.find(n);
			if(u.first[0] == 'p' && pk != m_packages.end()){
				const json::Value &mf = pk->second.get("manifest");
				// [AITTA_KEY_IDENTITY] The author as people read it: the
				// host where it is ambiguous or unverified
				const ss_ label = package_label(n);
				const size_t sp = label.find(' ');
				c.set("author", jstr(mf, "author")+(sp == ss_::npos ? "" :
						label.substr(sp)));
				c.set("package", jstr(mf, "author")+"/"+jstr(mf, "name"));
				c.set("id", n);
				c.set("aitta", interface::aitta::aitta_host(jstr(pk->second,
						"aitta")));
				c.set("verified", pk->second.get("vouched").is_true());
				c.set("version", jstr(pk->second, "version"));
				c.set("license_code", jstr(mf, "license_code"));
				c.set("license_media", jstr(mf, "license_media"));
			} else {
				c.set("author", n);
				if(n == "kit" || n == m_author)
					c.set("of", ss_(n == "kit" ? "kit" : "app"));
			}
			json::Value w = json::array();
			for(const ss_ &x : u.second)
				w.append(x[0] == '[' ? "["+shown(x.substr(1, x.size() - 2))+
						"]" : shown(x));
			c.set("uses", w);
			out.append(c);
		}
		return out;
	}

	// {"op": "export"}: the builder's own prefabs and voxel types (under
	// their name, not a package's) as a Kit package's files, answered with
	// "kit:export", {"author", "files": {path: text}, "hex": {path: bytes
	// as hex}, "dependencies": [{"kit", "version"}]}: the packages their
	// prefabs' types came in, at the versions here
	// simplified: a prefab of the app's own types installs where that app
	// is (the install's check of it says so elsewhere)
	void export_package(size_t peer, const Peer &p,
			std::function<void(const ss_&)> refuse)
	{
		const ss_ author = builder_author(p.name);
		if(author.empty())
			return refuse("a builder's prefabs are under their name, and it "
					"is \""+p.name.substr(0, 64)+"\"");
		json::Value files = json::object(), hex = json::object(),
				deps = json::array();
		std::set<ss_> dep_names;
		sm_<ss_, json::Value> pfs;
		for(const ss_ &k : m_store->list("prefab:"+author+"/")){
			ss_ src;
			m_store->get(k, src);
			const json::Value pf = json::load_string(src.c_str());
			if(!pf.is_object() || !jstr(pf, "package").empty())
				continue;
			const json::Value &es = pf.get("entities");
			for(unsigned i = 0; i < es.size(); i++){
				const json::Value &cs_ = es.at(i).get("components");
				for(unsigned c = 0; c < cs_.size(); c++){
					auto pt = m_package_types.find(jstr(cs_.at(c), "type"));
					if(pt != m_package_types.end())
						dep_names.insert(jstr(pt->second, "package"));
				}
			}
			// [KIT_PREFAB_VOXELS] its voxels' packages too
			const json::Value &kinds = pf.get("voxels").get("kinds");
			for(unsigned i = 0; kinds.is_array() && i < kinds.size(); i++){
				auto vt = m_voxel_types.find(jstr_at(kinds.at(i), 0));
				if(vt != m_voxel_types.end() &&
						!jstr(vt->second, "package").empty())
					dep_names.insert(jstr(vt->second, "package"));
			}
			pfs[k.substr(8 + author.size())] = pf;
		}
		// [AITTA_KEY_IDENTITY] A package's file says names as its author
		// does, "<author>/<n>": each dependency's "<fp>/" made its
		// author's, which its manifest's dependencies resolve again
		sm_<ss_, ss_> authors;
		std::set<ss_> named;
		for(const ss_ &n : dep_names){
			const ss_ da = jstr(m_packages[n].get("manifest"), "author");
			if(named.count(da) && authors[n.substr(0, n.find('/'))] != da)
				return refuse("two packages your prefabs use are "+da+"'s, "
						"by two keys");
			authors[n.substr(0, n.find('/'))] = da;
			named.insert(da);
		}
		for(auto &pf : pfs){
			resolve_names(pf.second, authors);
			files.set("types/"+pf.first+".prefab.json", pf.second.stringify());
		}
		for(auto &v : m_voxel_types){
			if(v.first.compare(0, author.size() + 1, author+"/") != 0 ||
					!jstr(v.second, "package").empty())
				continue;
			json::Value row = v.second.deepcopy();
			const ss_ tex = jstr(row, "texture");
			ss_ png;
			if(tex.compare(0, 7, "kit/up/") == 0 && m_store->get("texture:"+
					tex.substr(7, tex.size() - 11), png)){
				static const char *H = "0123456789abcdef";
				ss_ h;
				for(unsigned char ch : png){
					h += H[ch >> 4];
					h += H[ch & 15];
				}
				const ss_ path = "textures/"+tex.substr(7);
				hex.set(path, h);
				row.set("texture", path);
			}
			files.set("types/"+v.first.substr(author.size() + 1)+
					".voxel.json", row.stringify());
		}
		if(!files.size())
			return refuse("no prefabs or voxel types of "+author+"'s here");
		for(const ss_ &n : dep_names){
			const json::Value &dm = m_packages[n].get("manifest");
			json::Value dj = json::object();
			dj.set("kit", jstr(dm, "author")+"/"+jstr(dm, "name"));
			dj.set("version", jstr(m_packages[n], "version"));
			deps.append(dj);
		}
		json::Value j = json::object();
		j.set("author", author);
		j.set("files", files);
		j.set("hex", hex);
		j.set("dependencies", deps);
		log_i(MODULE, "%s exports %zu files, %zu dependencies", cs(p.name),
				(size_t)files.size(), (size_t)deps.size());
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:export", j.stringify());
		});
	}

	// The World's parameters: the first World on the current World's
	// scene ([KIT_SCENES]; before, on the root), over its type's defaults
	// (the app's among them); none: the defaults
	json::Value world_params()
	{
		json::Value out = json::object();
		ss_ type;
		const Instance *in = nullptr;
		const uint64_t sid = scene_id(m_w->name);
		for(auto &p : m_entities){
			if(!sid || p.second.parent != sid || p.second.has_pos || in)
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

	// A builder is told: the World's refusals and seams
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

	// [KIT_SCENES] The app asked for a scene of this name (Host::make_scene)
	bool make_scene(const ss_ &name, ss_ &why)
	{
		if(!m_host.make_scene){
			why = "scene "+name+": the app has none of that name";
			return false;
		}
		main_context::SceneReference ref = m_host.make_scene(name, this);
		if(!ref){
			why = "scene "+name+": the app made none";
			return false;
		}
		m_host.scenes[name] = ref;
		log_i(MODULE, "Scene %s made by the app", cs(name));
		return true;
	}

	// [KIT_SCENES] The scene entity of this name (0: none)
	uint64_t scene_id(const ss_ &name)
	{
		if(name.empty())
			return 0;
		for(auto &e : m_entities)
			if(e.second.kind == "scene" && e.second.name == name)
				return e.first;
		return 0;
	}

	World *world_named(const ss_ &scene)
	{
		auto it = m_worlds.find(scene);
		return it == m_worlds.end() ? nullptr : &it->second;
	}

	World *world_at(main_context::SceneReference ref)
	{
		if(!ref)
			return nullptr;
		for(auto &w : m_worlds)
			if(w.second.world_scene == ref)
				return &w.second;
		return nullptr;
	}

	// A peer's scene's World, the main one's for a peer not placed
	World *world_of_peer(size_t peer)
	{
		auto it = m_peers.find(peer);
		World *w = it == m_peers.end() ? nullptr : world_named(it->second.scene);
		return w ? w : m_w;
	}

	// The save's row of the current World: the main scene's by its old
	// name, another's with ":<scene>"
	ss_ world_row(const ss_ &base)
	{
		return m_w->name == m_host.world_scene || m_w->name.empty() ? base :
				base+":"+m_w->name;
	}

	// [KIT_SCENES] A World on the root (before every scene owned its own)
	// moved onto the main scene
	bool migrate_root_world()
	{
		const uint64_t main = scene_id(m_host.world_scene);
		if(!main)
			return false;
		bool moved = false;
		for(auto &p : m_entities){
			Entity &e = p.second;
			if(e.parent != 1 || e.has_pos)
				continue;
			for(const Instance &i : e.comps)
				if(m_types.count(i.type) && m_types[i.type].world){
					e.parent = main;
					moved = true;
					log_i(MODULE, "World: entity %llu moved from the root onto "
							"the scene %s", (unsigned long long)e.id,
							cs(m_host.world_scene));
					break;
				}
		}
		return moved;
	}

	bool host_world(ss_ &why)
	{
		if(m_host.world_scene.empty())
			return true;
		if(!m_host.scenes.count(m_host.world_scene)){
			why = "the World's scene "+m_host.world_scene+" is none of the app's";
			return false;
		}
		const ss_ ms = m_host.materials.empty() ? read_file(
				m_server->get_module_path(MODULE)+"/materials.json") :
				m_host.materials;
		ss_ mwhy;
		if(!m_materials.parse(json::load_string(ms.c_str()), mwhy)){
			why = "the material set: "+mwhy;
			return false;
		}
		if(migrate_root_world())
			m_store->set("authored", authored_json().stringify());
		// The main scene's first, so that a refusal elsewhere is told in it
		if(!host_world_of(m_host.world_scene, why))
			return false;
		for(auto &e : m_entities)
			if(e.second.kind == "scene" && e.second.name != m_host.world_scene)
				if(!host_world_of(e.second.name, why))
					return false;
		m_w = &m_worlds[m_host.world_scene];
		return true;
	}

	// One scene's World made and applied (hosting, a new scene)
	bool host_world_of(const ss_ &name, ss_ &why)
	{
		auto si = m_host.scenes.find(name);
		if(si == m_host.scenes.end()){
			why = "scene "+name+": the app has none of that name";
			return false;
		}
		World &wd = m_worlds[name];
		wd.name = name;
		wd.world_scene = si->second;
		WorldScope ws(m_w, &wd);
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			m_w->section_size = w->get_section_size_voxels().getX();
		});
		ss_ row;
		if(m_store->get(world_row("world"), row)){
			const json::Value r = json::load_string(row.c_str());
			m_w->world_applied = r.get("params").deepcopy();
			world::Params was;
			was.from(m_w->world_applied);
			const int64_t v = json::jint(r, "version", 0);
			if(!was.finite() && !was.heightmap() &&
					v != world::generator_version(was.generator)){
				why = "the save's infinite world is the "+was.generator+
						" generator's version "+itos(v)+", this build's is "+
						itos(world::generator_version(was.generator));
				return false;
			}
			m_w->wp = was;
		}
		ss_ awhy;
		if(!apply_world(world_params(), "", true, awhy)){
			// The save's own World again, else nothing generated
			warn("not applied: "+awhy);
			if(m_w->world_applied.is_object() &&
					!apply_world(m_w->world_applied, "", true, awhy)){
				why = "the World: "+awhy;
				return false;
			}
		}
		return true;
	}

	// The World's parameters changed (an edit, an undo): applied
	void world_check(const ss_ &by)
	{
		// [KIT_SCENES] each scene's
		for(auto &w : m_worlds){
			if(!scene_id(w.first))
				continue;
			WorldScope ws(m_w, &w.second);
			world_check_one(by);
		}
	}

	void world_check_one(const ss_ &by)
	{
		if(!m_w->world_scene)
			return;
		const json::Value p = world_params();
		if(p.stringify() == m_w->world_applied.stringify())
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
		// The surface or a heightmap's size changed: the heightmap there
		// goes (below, once nothing refuses), the new ground replacing it
		const bool had = m_w->world_applied.is_object();
		const bool reshape = !first && had && (p.heightmap() != m_w->wp.heightmap()
				|| (p.heightmap() && (p.width != m_w->wp.width ||
				p.depth != m_w->wp.depth)));
		// [KIT_VOXEL_FORMAT] the sky light alone changed generates nothing
		const bool again = had && ground_key(params) !=
				ground_key(m_w->world_applied);
		world::Ids ids;
		ids.filler_depth = b.filler_depth;
		sv_<int> layers;
		voxelworld::access(m_server, m_w->world_scene,
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
		if(reshape && m_w->wp.heightmap()){
			decor_clear();
			m_w->decor_dirty = true;
			save_decor();
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				ih->delete_instance(m_w->world_scene);
			});
		}
		if(p.heightmap()){
			if(!apply_heightmap(p, *h, layers, ids, again, hash, why))
				return false;
			dn = m_w->decor.size();
			dh = decor_hash();
			set_world_generator(p, ids, nullptr, lo, hi);
			// The voxel ground it replaces: unloaded and forgotten (the
			// edited sections stay in the save, unloaded)
			if(reshape && !m_w->wp.heightmap()){
				regenerate(by, false);
				m_w->world_regenerating = false;
			}
		} else {
			set_world_generator(p, ids, std::move(h), lo, hi);
			if(again)
				regenerate(by);
		}
		m_w->wp = p;
		m_w->world_min = lo;
		m_w->world_max = hi;
		m_w->world_applied = params.deepcopy();
		apply_sky(params.get("sky_light").is_true() && !p.heightmap(), by);
		json::Value row = json::object();
		row.set("params", m_w->world_applied);
		row.set("version", (int64_t)world::generator_version(p.generator));
		m_store->set(world_row("world"), row.stringify());
		world_load_points();
		log_i(MODULE, "World%s: %s %s, seed %u, biome %s, %s, %s; ground %i "
				"to %i, heights hash %08x%s; version %i%s%s, decorations %zu "
				"(hash %08x)", by.empty() ? "" : cs(" by "+by),
				cs(p.generator), cs(p.size == "finite" ? itos(p.width)+"x"+
				itos(p.depth) : ss_("infinite")), p.seed, cs(p.biome),
				cs(p.heightmap() ? ss_("a heightmap") : "voxels"),
				cs("border "+p.border), lo, hi, hash,
				first ? (again ? ", the save's was another" : "") : "",
				world::VERSION, p.with_caves() && !p.heightmap() ? ", caves" : "",
				cs(caves), dn, dh);
		if(first && !p.heightmap())
			voxelworld::access(m_server, m_w->world_scene,
					[&](voxelworld::Instance *w){
				size_t n = 0, edited = 0;
				for(const auto &s : w->section_stats())
					n++, edited += s.altered;
				log_i(MODULE, "World: the save holds %zu sections (%zu "
						"edited)", n, edited);
				m_w->world_first = n == 0;
			});
		// [KIT_HM_VOXELS] the voxels built over a heightmap
		if(first && p.heightmap())
			voxelworld::access(m_server, m_w->world_scene,
					[&](voxelworld::Instance *w){
				size_t n = 0;
				for(const auto &s : w->section_stats())
					n += s.altered;
				log_i(MODULE, "World: %zu edited voxel sections over the "
						"heightmap", n);
			});
		return true;
	}

	// The World's parameters but its sky light, which generates nothing
	static ss_ ground_key(const json::Value &params)
	{
		if(!params.is_object())
			return params.stringify();
		json::Value c = params.deepcopy();
		c.del_key("sky_light");
		return c.stringify();
	}

	// [KIT_VOXEL_FORMAT] The World's sky light, per World: on, voxelworld
	// keeps the light_sky bits up to date (each write floods; the sections
	// loaded now are relit at once) and the clients mesh with it ("kit:sky");
	// off, nothing is computed and the bits are left as they are (relit
	// when it is on again). A heightmap's world has none (its ground is no
	// voxels). simplified: per World, not per scene -- a peer in another
	// scene is told the World's
	void apply_sky(bool on, const ss_ &by)
	{
		if(on == m_w->sky)
			return;
		bool bound = false;
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			bound = w->get_voxel_reg()->get_format().light_sky.bound();
		});
		if(on && !bound){
			warn("sky light: the app's voxel format has no light_sky "
					"(kit::voxel_format() has)");
			return;
		}
		m_w->sky = on;
		const int64_t t0 = interface::os::time_us();
		size_t n = 0;
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			w->set_light_maintained(voxelworld::Instance::LIGHT_SKY, on);
			if(!on)
				return;
			for(const pv::Vector3DInt16 &sp : w->get_loaded_sections()){
				w->relight_region_later(w->get_section_region_voxels(sp));
				n++;
			}
		});
		m_w->sky_relight = m_w->sky_left = n;
		m_w->sky_relight_us = m_w->sky_relight_max_us = 0;
		m_w->sky_relight_t0 = t0;
		log_i(MODULE, "World%s: sky light %s (%zu loaded sections to relight)",
				by.empty() ? "" : cs(" by "+by), on ? "on" : "off", n);
		send_sky(-1);
	}

	// The loaded sections' relight, a slice a tick (a section is a quarter
	// of a million voxels: 8 of them at once were a 2.5 s step); each
	// commit sends what is done. Until then a section wears its old light
	// (none: dark until it is relit)
	static constexpr int64_t SKY_RELIGHT_BUDGET_US = 20000;
	void sky_relight_tick()
	{
		if(!m_w->sky_relight || !m_w->world_scene)
			return;
		const int64_t t0 = interface::os::time_us();
		size_t left = 0;
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			left = w->relight_stale(SKY_RELIGHT_BUDGET_US);
			// Committed as each section is done, not each tick
			if(left != m_w->sky_left)
				w->commit();
		});
		m_w->sky_left = left;
		const int64_t took = interface::os::time_us() - t0;
		m_w->sky_relight_us += took;
		m_w->sky_relight_max_us = std::max(m_w->sky_relight_max_us, took);
		if(left)
			return;
		log_i(MODULE, "World: sky light: %zu sections relit, %.1f ms of "
				"ticks (at most %.1f in one) over %.1f s", m_w->sky_relight,
				m_w->sky_relight_us / 1000.0, m_w->sky_relight_max_us / 1000.0,
				(interface::os::time_us() - m_w->sky_relight_t0) / 1e6);
		m_w->sky_relight = 0;
		send_sky(-1, true);
	}

	// "kit:sky" {"on": bool, "relit": true once the loaded sections are} to
	// a peer (-1: all of them)
	void send_sky(int64_t peer, bool relit = false)
	{
		// [KIT_SCENES] A peer's own scene's; all: the current World's
		// scene's peers
		json::Value j = json::object();
		j.set("on", peer >= 0 ? world_of_peer((size_t)peer)->sky : m_w->sky);
		if(relit)
			j.set("relit", true);
		network::access(m_server, [&](network::Interface *inetwork){
			if(peer >= 0){
				inetwork->send((size_t)peer, "kit:sky", j.stringify());
				return;
			}
			for(auto &p : m_peers)
				if(world_of_peer(p.first) == m_w)
					inetwork->send(p.first, "kit:sky", j.stringify());
		});
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
		// What generated() makes its own of
		m_w->gen_p = p;
		m_w->gen_ids = ids;
		m_w->gen_hi = hi;
		m_w->gen_voxels = h != nullptr;
		if(!h){
			// A heightmap's scene: no voxels, all air: neither the World's
			// sea (an empty map's columns are all under it: water up to
			// sea_level over the voxel map's square, round the origin and
			// not the heightmap's) nor its border, caves or decorations
			// ([KIT_HM_NO_SEA])
			g->p.generator = "empty";
			g->p.border = "void";
			g->p.sea_level = INT_MIN / 2;
			g->p.caves = false;
			g->p.decorations = false;
			h.reset(new world::Heights());
			h->p = g->p;
		}
		g->h = std::move(h);
		g->max_top = hi;
		worldgen::access(m_server, [&](worldgen::Interface *i){
			if(!i->get_instance(m_w->world_scene))
				i->create_instance(m_w->world_scene);
			worldgen::Instance *wi = i->get_instance(m_w->world_scene);
			wi->set_generator(g);
			wi->enable();
		});
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			w->set_writes_alter(true);
			// [KIT_HM_VOXELS] a heightmap's air sections: only the
			// edited ones saved
			w->set_save_unaltered(p.finite() && !p.heightmap());
			m_w->hm_world = p.heightmap() ? w : nullptr;
		});
	}

	// Every section nobody edited generated again (unloaded and forgotten:
	// the load points bring them back); the edited ones stay, and those
	// beside a regenerated one are the seams
	void regenerate(const ss_ &by, bool seams_named = true)
	{
		size_t again = 0;
		std::set<std::tuple<int, int, int>> edited, redo;
		sv_<pv::Vector3DInt16> wait;
		voxelworld::access(m_server, m_w->world_scene,
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
				wait.push_back(s);
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
		m_w->world_regenerating = again > 0;
		m_w->regen_wait = wait;
		if(n && seams_named)
			warn(itos(n)+" edited sections kept, seams where they meet the "
					"new ground: "+seams+(n > 8 ? " ..." : ""));
	}

	// ---- [KIT_VOXEL_EDITS] The voxel edits manager (api.h's "edited" and
	// "regenerate"): the World's sections somebody wrote (voxelworld's
	// altered, set_writes_alter), each with how many of its cells differ
	// from what the generator makes there, and a regeneration that drops a
	// section's writes, the World generating it again; one undo.
	// simplified: a section not loaded (an infinite World's far one, the
	// voxel ground's under a heightmap surface) is listed with no count
	// and not regenerated: its cells unread, an undo would have nothing

	// A copy of the World's generator, to say what a section would be
	up_<world::Generator> diff_generator()
	{
		up_<world::Generator> g(new world::Generator());
		g->p = m_w->gen_p;
		g->ids = m_w->gen_ids;
		g->max_top = m_w->gen_hi;
		g->h.reset(new world::Heights());
		g->h->p = m_w->gen_p;
		if(m_w->gen_voxels)
			valleys_query(*g->h);
		else
			g->h->p.generator = "empty";
		return g;
	}

	// A loaded, generated World section's cells that differ from the
	// generator's: how many, and (out) each one's id now
	bool section_diff(voxelworld::Instance *w, world::Generator &g,
			const pv::Vector3DInt16 &s, size_t &n,
			std::map<std::tuple<int, int, int>, uint32_t> *out = nullptr)
	{
		n = 0;
		if(!w->is_section_loaded(s) || !w->is_section_generated(s))
			return false;
		const pv::Region r = w->get_section_region_voxels(s);
		interface::VoxelVolume gen(r);
		g.generate(m_w->world_scene, s, gen);
		const interface::VoxelVolume now = w->get_volume(r);
		const uint32_t sm = state_mask(w->get_voxel_reg()->get_format());
		const pv::Vector3DInt32 lc = r.getLowerCorner(), uc = r.getUpperCorner();
		for(int y = lc.getY(); y <= uc.getY(); y++)
		for(int z = lc.getZ(); z <= uc.getZ(); z++)
		for(int x = lc.getX(); x <= uc.getX(); x++){
			const uint32_t a = now.getVoxelAt(x, y, z).data & sm;
			if(a == (gen.getVoxelAt(x, y, z).data & sm))
				continue;
			n++;
			if(out)
				out->emplace(std::make_tuple(x, y, z), a);
		}
		return true;
	}

	// "kit:edited" {"size": a section's side, "sections": [{"s": [x, y, z],
	// "cells": n (-1: not loaded), "owned": true (a component's voxels in
	// it: not regenerated)}], "more": n past MAX_EDITED_LISTED}
	void send_edited(size_t peer)
	{
		json::Value list = json::array();
		size_t more = 0;
		if(m_w->world_scene)
			voxelworld::access(m_server, m_w->world_scene,
					[&](voxelworld::Instance *w){
				sv_<pv::Vector3DInt16> edited;
				// The index marks a section altered as it is saved
				w->save();
				for(const auto &s : w->section_stats())
					if(s.altered)
						edited.push_back(s.p);
				std::sort(edited.begin(), edited.end(), [](
						const pv::Vector3DInt16 &a, const pv::Vector3DInt16 &b){
					return std::make_tuple(a.getY(), a.getZ(), a.getX()) <
							std::make_tuple(b.getY(), b.getZ(), b.getX());
				});
				if(edited.size() > MAX_EDITED_LISTED){
					more = edited.size() - MAX_EDITED_LISTED;
					edited.resize(MAX_EDITED_LISTED);
				}
				up_<world::Generator> g = diff_generator();
				const auto &owned = m_owned_sections[m_w->world_scene];
				for(const pv::Vector3DInt16 &s : edited){
					size_t n = 0;
					const bool counted = section_diff(w, *g, s, n);
					json::Value r = json::object();
					json::Value sp = json::array();
					sp.append((int64_t)s.getX());
					sp.append((int64_t)s.getY());
					sp.append((int64_t)s.getZ());
					r.set("s", sp);
					r.set("cells", counted ? (int64_t)n : (int64_t)-1);
					if(owned.count(std::make_tuple((int)s.getX(), (int)s.getY(),
							(int)s.getZ())))
						r.set("owned", true);
					list.append(r);
				}
			});
		json::Value j = json::object();
		j.set("size", (int64_t)m_w->section_size);
		j.set("sections", list);
		j.set("more", (int64_t)more);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:edited", j.stringify());
		});
	}

	// {"op": "regenerate", "s": [x, y, z]} one edited section, {"all":
	// true} every one that can be: Ended only (a Running round's copies of
	// the start would put its voxels back at End), or a persistent world
	void regenerate_sections(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		if(!m_w->world_scene)
			return refuse("no World here");
		if(m_session.running && !m_host.persistent)
			return refuse("the game is Running: End it first");
		const bool all = j.get("all").is_true();
		std::tuple<int, int, int> one;
		if(!all){
			const json::Value &s = j.get("s");
			if(!s.is_array() || s.size() != 3)
				return refuse("s: a section's [x, y, z]");
			int c[3];
			for(unsigned k = 0; k < 3; k++){
				const json::Value &v = s.at(k);
				const int lo = k == 1 ? WORLD_SECTION_Y0 : -WORLD_SECTIONS_XZ,
						hi = k == 1 ? WORLD_SECTION_Y1 : WORLD_SECTIONS_XZ - 1;
				if(!v.is_number() || v.as_number() != std::floor(v.as_number())
						|| v.as_number() < lo || v.as_number() > hi)
					return refuse("s: a World section's whole numbers");
				c[k] = (int)v.as_number();
			}
			one = std::make_tuple(c[0], c[1], c[2]);
		}
		Change nc;
		nc.stroke = -2;
		size_t cells = 0, skipped = 0;
		ss_ why;
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			std::set<std::tuple<int, int, int>> want;
			w->save();
			for(const auto &s : w->section_stats())
				if(s.altered)
					want.insert(std::make_tuple((int)s.p.getX(),
							(int)s.p.getY(), (int)s.p.getZ()));
			if(!all){
				if(!want.count(one)){
					why = "not an edited section of the World";
					return;
				}
				want = {one};
			}
			up_<world::Generator> g = diff_generator();
			const auto &owned = m_owned_sections[m_w->world_scene];
			sv_<pv::Vector3DInt16> forget;
			for(const auto &k : want){
				const pv::Vector3DInt16 s(std::get<0>(k), std::get<1>(k),
						std::get<2>(k));
				size_t n = 0;
				std::map<std::tuple<int, int, int>, uint32_t> before;
				if(owned.count(k) || !section_diff(w, *g, s, n, &before)){
					if(!all)
						why = owned.count(k) ? "the section holds a component's "
								"voxels" : "the section is not loaded";
					skipped++;
					continue;
				}
				nc.cells.insert(before.begin(), before.end());
				cells += n;
				nc.regen.push_back(s);
				w->unload_section(s);
				forget.push_back(s);
			}
			w->forget_sections(forget);
		});
		if(!why.empty())
			return refuse(why);
		if(nc.regen.empty())
			return refuse("no edited section to regenerate ("+itos(skipped)+
					" not loaded or a component's)");
		std::deque<Change> &u = m_undo[p.name];
		u.push_back(nc);
		while(u.size() > UNDO_MAX)
			u.pop_front();
		m_w->world_regenerating = true;
		log_i(MODULE, "World by %s: %zu edited sections regenerated, %zu cells "
				"back to the generator's, %zu skipped (%zu to undo)", cs(p.name),
				nc.regen.size(), cells, skipped, u.size());
		send_state(peer);
		send_edited(peer);
	}

	// [KIT_TRY_INPUTS] {"op": "try", "id": n, "input": i, "value": v}: the
	// inspector's Try, the input delivered to the entity as a link would,
	// by the builder; Running only (the editor runs the game first). Its
	// runs' emits are answered with "kit:tried"
	void try_input(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		ss_ why;
		Entity *e = entity_arg(j, "id", why);
		if(!e)
			return refuse(why);
		if(!m_session.running)
			return refuse("the game is Ended: Run it first");
		const ss_ input = jstr(j, "input");
		json::Value value = j.get("value");
		if(value.is_undefined())
			value = json::null();
		bool has = false, ok = false;
		ss_ type;
		for(const Instance &in : e->comps){
			const Type &t = m_types[in.type];
			if(!t.inputs.count(input))
				continue;
			has = true;
			type = t.in_types.at(input);
			ok = ok || signal_ok(type, value);
		}
		if(!has)
			return refuse("input: entity "+itos(e->id)+" has no input \""+
					input.substr(0, 32)+"\"");
		if(!ok)
			return refuse("value: its input "+input+" takes a "+type);
		const uint64_t id = e->id;
		const size_t before = m_queue.size();
		deliver(id, input, value, by_of(p.name), 0);
		for(size_t i = before; i < m_queue.size(); i++)
			m_queue[i].tried = peer + 1;
		log_i(MODULE, "%s tries entity %s's %s %s", cs(p.name), cs(itos(id)),
				cs(input), cs(value.stringify().substr(0, 64)));
		add_log(id, "tried: "+input+" by "+p.name);
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
			heightmap::Instance *map = ih->get_instance(m_w->world_scene);
			bool loaded = false;
			if(!map){
				map = ih->create_instance(m_w->world_scene, size);
				loaded = map->set_save(m_host.save, world_row("world"));
			}
			if(!loaded || again){
				generated = true;
				heightmap::GenerateParams gp;
				gp.seed = p.seed;
				// A voxel column's top cell is centred on its whole number
				gp.height_fn = [&](float x, float z){ return h.at(x, z) + 0.5f; };
				// Sand (the riverbed's layer) where a voxel column's top
				// is under the sea, as the voxels have it: a flat ground
				// at the sea's level its top's
				gp.sand_below = p.sea_level;
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
			vo = iv->get_instance(m_w->world_scene);
			if(!vo)
				vo = iv->create_instance(m_w->world_scene);
		});
		return vo;
	}

	// A structure's model, made once from the material set's voxels
	bool decor_model(const ss_ &name)
	{
		if(m_w->decor_models.count(name))
			return true;
		auto si = m_materials.structures.find(name);
		if(si == m_materials.structures.end())
			return false;
		const world::Structure &st = si->second;
		sv_<interface::VoxelTypeId> ids;
		voxelworld::access(m_server, m_w->world_scene, [&](voxelworld::Instance *w){
			for(const ss_ &c : st.cells){
				interface::VoxelName n;
				n.block_name = c;
				const interface::VoxelDefinition *d = c.empty() ? nullptr :
						w->get_voxel_reg()->get(n);
				ids.push_back(d ? d->id : 0);
			}
		});
		voxel_objects::access(m_server, m_w->world_scene,
				[&](voxel_objects::Instance *vo){
			voxel_objects::Model *m = vo->get_model("kit_"+name);
			if(!m)
				m = vo->create_model("kit_"+name, st.sx, st.sy, st.sz);
			for(int y = 0; y < st.sy; y++)
			for(int z = 0; z < st.sz; z++)
			for(int x = 0; x < st.sx; x++)
				m->set_voxel(x, y, z, ids[((size_t)y * st.sz + z) * st.sx + x]);
		});
		m_w->decor_models.insert(name);
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
		voxel_objects::access(m_server, m_w->world_scene,
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
		const uint64_t id = m_w->next_decor++;
		decor_object(d);
		m_w->decor[id] = d;
		m_w->decor_dirty = true;
		return id;
	}

	void remove_decor(uint64_t id)
	{
		auto it = m_w->decor.find(id);
		if(it == m_w->decor.end())
			return;
		if(it->second.node)
			voxel_objects::access(m_server, m_w->world_scene,
					[&](voxel_objects::Instance *vo){
				vo->remove_object(it->second.node);
			});
		m_w->decor.erase(it);
		m_w->decor_dirty = true;
	}

	void save_decor()
	{
		if(!m_w->decor_dirty)
			return;
		m_w->decor_dirty = false;
		json::Value a = json::array();
		for(auto &d : m_w->decor){
			json::Value r = json::array();
			r.append(d.second.structure);
			for(float v : {d.second.x, d.second.y, d.second.z, d.second.yaw})
				r.append((double)v);
			a.append(r);
		}
		m_store->set(world_row("decor"), a.stringify());
	}

	// FNV-1a over the decorations, in their order: their structures' names
	// and their places in sixteenths
	uint32_t decor_hash()
	{
		uint32_t h = 2166136261u;
		auto add = [&](uint8_t b){ h ^= b; h *= 16777619u; };
		for(auto &d : m_w->decor){
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
				m_w->wp.sea_level, mult, turns);
		if(k < 0 || b.decors[k].on != 't' || steep > 0.8f)
			return "";
		const world::StructIds &s = structs[b.decors[k].s];
		if(s.sx * s.sy * s.sz <= 1)
			return "";
		// Any angle: an object turns freely
		yaw = (float)(world::hash_at(seed, x, 1, z, 99) % 360);
		return s.name;
	}

	// The decorations removed: their objects and the list (the row
	// "decor" is save_decor()'s)
	void decor_clear()
	{
		for(auto &d : m_w->decor)
			if(d.second.node)
				voxel_objects::access(m_server, m_w->world_scene,
						[&](voxel_objects::Instance *vo){
					vo->remove_object(d.second.node);
				});
		m_w->decor.clear();
	}

	// The decorations at a start: generated with a generated map (the
	// biome's scatter over its samples), else the save's
	void decor_start(const world::Params &p, const world::Ids &ids,
			bool generated)
	{
		decor_clear();
		ss_ row;
		const bool saved = !generated && m_store->get(world_row("decor"), row);
		if(!saved && !p.with_decorations()){
			m_w->decor_dirty = true;
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
			heightmap::access(m_server, m_w->world_scene,
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
		m_w->decor_dirty = true;
		save_decor();
		log_i(MODULE, "World: %zu decorations on the heightmap (%s)",
				m_w->decor.size(), saved ? "the save's" : "generated");
	}

	// The decorations over a rectangle of samples back on the ground
	void reseat_decor(int x0, int z0, int x1, int z1)
	{
		sv_<uint64_t> moved;
		heightmap::access(m_server, m_w->world_scene, [&](heightmap::Instance *map){
			for(auto &d : m_w->decor){
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
			decor_object(m_w->decor[id]);
		if(!moved.empty())
			m_w->decor_dirty = true;
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
		br.p = m_w->wp;
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
			if(b.first == m_w->wp.biome)
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
		if(!m_w->world_scene)
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
			biome = m_w->wp.biome;
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
		if(m_w->wp.heightmap())
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
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			world::Brush br;
			if(!make_brush(w, br, why))
				return;
			br.get = [&](int x, int y, int z, interface::VoxelTypeId &v){
				uint32_t id = 0;
				if(!voxel_id(w, pv::Vector3DInt32(x, y, z), id))
					return false;
				v = type_of(w, id);
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
				mark(w, m_w->world_scene, q, 'k', p.name);
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
				const uint32_t seed = m_w->wp.seed ^ world::BRUSH_SALT;
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
								m_w->wp.sea_level, mult, turns);
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
			voxelworld::access(m_server, m_w->world_scene,
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
		heightmap::access(m_server, m_w->world_scene, [&](heightmap::Instance *map){
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
				return m_materials.biomes[m_w->wp.biome];
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
						h < m_w->wp.sea_level + 0.5f ? layer_of(b, "riverbed") :
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
					const ss_ st = decor_pick(map, bi, structs, m_w->wp.seed ^
							world::BRUSH_SALT, x, z, 2 * s, yaw);
					if(st.empty())
						return;
					for(auto &d : m_w->decor)
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
			what += ", "+itos(added)+" decorations ("+itos(m_w->decor.size())+
					" in all, hash "+itos(decor_hash())+")";
		if(tool != "paint" && tool != "decorate" && tool != "column")
			reseat_decor(bx0, bz0, bx1, bz1);
		return what;
	}

	// An editor's undo of a terrain stroke: its cells, samples and
	// decorations as they were
	void undo_terrain(const Change &c, const Peer &p)
	{
		WorldScope ws(m_w, world_at(c.scene));
		size_t cells = 0;
		if(!c.cells.empty())
			voxelworld::access(m_server, c.scene ? c.scene : m_w->world_scene,
					[&](voxelworld::Instance *w){
				for(auto &q : c.cells){
					const pv::Vector3DInt32 v(std::get<0>(q.first),
							std::get<1>(q.first), std::get<2>(q.first));
					if(!hm_section(w, v))
						continue;
					set_id(w, v, q.second);
					mark(w, c.scene ? c.scene : m_w->world_scene, v, 'k', p.name);
					cells++;
				}
			});
		int x0 = INT_MAX, z0 = INT_MAX, x1 = INT_MIN, z1 = INT_MIN;
		if(!c.samples.empty())
			heightmap::access(m_server, m_w->world_scene,
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
		if(m_w->wp.heightmap())
			heightmap::access(m_server, m_w->world_scene,
					[&](heightmap::Instance *map){
				hash = ", map hash "+itos(map->content_hash());
			});
		log_i(MODULE, "An undo by %s: %s, %zu cells, %zu samples "
				"and %zu decorations put back%s", cs(p.name), c.scene ?
				"a voxel edit" : !c.regen.empty() ? "a regeneration" :
				"a terrain stroke", cells,
				c.samples.size(), c.decor.size(), cs(hash));
	}

	// [KIT_EDIT_VOXELS] A builder's place or dig in edit mode (api.h's
	// "set_voxel" op): the cell in their scene, through voxelworld's
	// routed write (an owned one goes to its owner), one undo.
	// simplified: a write routed to an owner is not undone (its owner
	// decided what it did)
	// [KIT_VOXEL_FORMAT] {"op": "voxel_info", "pos": [x, y, z]}: what a
	// cell of the builder's scene holds, logged -- its voxel, param (a
	// shape's facing), tint and sky light (a check's read-back)
	void voxel_info(Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const json::Value &pos = j.get("pos");
		if(!pos.is_array() || pos.size() != 3)
			return refuse("pos: [x, y, z]");
		int c[3];
		for(unsigned k = 0; k < 3; k++){
			const json::Value &v = pos.at(k);
			if(!v.is_number() || !std::isfinite(v.as_number()) ||
					std::fabs(v.as_number()) > MAX_COORD)
				return refuse("pos: numbers of at most "+ftos(MAX_COORD));
			c[k] = (int)std::floor(v.as_number());
		}
		auto si = m_host.scenes.find(p.scene);
		if(si == m_host.scenes.end())
			return refuse("not in a scene of the app's");
		ss_ what;
		voxelworld::access(m_server, si->second, [&](voxelworld::Instance *w){
			const pv::Vector3DInt32 q(c[0], c[1], c[2]);
			if(!loaded(w, q))
				return;
			const interface::VoxelFormat &f = w->get_voxel_reg()->get_format();
			const uint32_t word = w->get_voxel(q, true).data;
			const interface::VoxelDefinition *d =
					w->get_voxel_reg()->get(f.id.get(word));
			what = (d ? d->name.block_name : ss_("?"))+
					", param "+itos(f.param.bound() ? f.param.get(word) : 0)+
					", tint "+itos(f.tint.bound() ? f.tint.get(word) : 0)+
					", sky light "+itos(f.light_sky.bound() ?
					f.light_sky.get(word) : 0);
		});
		if(what.empty())
			return refuse("the cell's section is not loaded");
		log_i(MODULE, "Voxel at (%i,%i,%i): %s", c[0], c[1], c[2], cs(what));
	}

	void edit_voxel(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const json::Value &pos = j.get("pos");
		if(!pos.is_array() || pos.size() != 3)
			return refuse("pos: [x, y, z]");
		int c[3];
		for(unsigned k = 0; k < 3; k++){
			const json::Value &v = pos.at(k);
			if(!v.is_number() || !std::isfinite(v.as_number()) ||
					std::fabs(v.as_number()) > MAX_COORD ||
					v.as_number() != std::floor(v.as_number()))
				return refuse("pos: whole numbers of at most "+
						ftos(MAX_COORD));
			c[k] = (int)v.as_number();
		}
		const ss_ voxel = jstr(j, "voxel");
		// [KIT_VOXEL_FORMAT] a shape's facing (0..7) and a tint (0..15)
		const json::Value &pj = j.get("param"), &tj = j.get("tint");
		if(!pj.is_undefined() && !(pj.is_number() &&
				pj.as_number() >= 0 && pj.as_number() <= 255 &&
				pj.as_number() == std::floor(pj.as_number())))
			return refuse("param: a whole number 0..255");
		if(!tj.is_undefined() && !(tj.is_number() &&
				tj.as_number() >= 0 && tj.as_number() <= 15 &&
				tj.as_number() == std::floor(tj.as_number())))
			return refuse("tint: a whole number 0..15");
		const uint32_t param = pj.is_undefined() ? 0 : (uint32_t)pj.as_number();
		const uint32_t tint = tj.is_undefined() ? 0 : (uint32_t)tj.as_number();
		auto si = m_host.scenes.find(p.scene);
		if(si == m_host.scenes.end())
			return refuse("not in a scene of the app's");
		const pv::Vector3DInt32 q(c[0], c[1], c[2]);
		uint32_t old = 0;
		int r = -1;
		ss_ why;
		voxelworld::access(m_server, si->second, [&](voxelworld::Instance *w){
			interface::VoxelName n;
			n.block_name = voxel;
			const interface::VoxelDefinition *d = w->get_voxel_reg()->get(n);
			if(!d){
				why = "voxel: a registered voxel's name (air: a dig)";
				return;
			}
			if(!hm_section(w, q) || !voxel_id(w, q, old)){
				why = "the cell's section is not loaded";
				return;
			}
			const interface::VoxelFormat &f = w->get_voxel_reg()->get_format();
			if((param && !f.param.bound()) || (tint && !f.tint.bound())){
				why = "the scene's voxels take no param or tint";
				return;
			}
			const uint32_t word = kit::voxel_word(f, d->id, param, tint);
			r = w->routed_set_voxel(q, interface::VoxelInstance(word),
					"player:"+p.name);
			if(r == voxelworld::Instance::WRITTEN)
				mark(w, si->second, q, 'k', p.name);
		});
		if(!why.empty())
			return refuse(why);
		if(r < 0)
			return refuse("the scene has no voxels");
		if(r == voxelworld::Instance::REFUSED)
			return refuse("an owned voxel whose owner takes no writes");
		const ss_ what = (voxel == "air" ? ss_("dug") : "placed "+voxel+
				(param || tint ? " (param "+itos(param)+", tint "+itos(tint)+
				")" : ss_("")))+" at ("+itos(c[0])+","+itos(c[1])+","+
				itos(c[2])+")";
		if(r == voxelworld::Instance::ROUTED){
			log_i(MODULE, "A voxel edit by %s: %s, routed to its owner",
					cs(p.name), cs(what));
			return;
		}
		std::deque<Change> &u = m_undo[p.name];
		Change nc;
		nc.stroke = -2;
		nc.scene = si->second;
		nc.cells[std::make_tuple(c[0], c[1], c[2])] = old;
		u.push_back(nc);
		while(u.size() > UNDO_MAX)
			u.pop_front();
		log_i(MODULE, "A voxel edit by %s: %s (%zu to undo)", cs(p.name),
				cs(what), u.size());
		send_state(peer);
	}

	// [KIT_VOXEL_STATES] An editor's {"op": "pattern", "id", "comp",
	// "param" (a "voxels" parameter), "action": "capture" | "fill" |
	// "show", "voxel" (fill's)}: the box's voxels recorded in it, it made
	// one voxel throughout, or it written into the box. Each an edit,
	// undone as others
	void pattern_op(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		Entity *e = nullptr;
		ss_ why;
		Instance *in = instance_arg(j, e, why);
		if(!in)
			return refuse(why);
		const ss_ param = jstr(j, "param"), action = jstr(j, "action");
		if(jstr(m_types[in->type].decl.get("params").get(param), "type") !=
				"voxels")
			return refuse(in->type+" has no voxel pattern \""+
					param.substr(0, 64)+"\"");
		pv::Vector3DInt32 o;
		int n[3];
		if(!voxel_box(*e, *in, o, n, &why))
			return refuse(why);
		const size_t total = (size_t)n[0] * n[1] * n[2];
		const ss_ who = itos(e->id)+"'s "+in->type+" "+param;
		if(action == "capture" || action == "fill"){
			sv_<ss_> cells;
			if(action == "capture"){
				cells = read_box(*e, o, n);
				for(const ss_ &c : cells)
					if(c.empty())
						return refuse("a cell of the box is not loaded");
			} else {
				const ss_ v = jstr(j, "voxel");
				bool known = false;
				voxelworld::access(m_server, scene_of(*e),
						[&](voxelworld::Instance *w){
					interface::VoxelName vn;
					vn.block_name = v;
					known = voxel_name_ok(v) && w->get_voxel_reg()->get(vn);
				});
				if(!known)
					return refuse("voxel: a registered voxel's name");
				cells.assign(total, v);
			}
			const ss_ text = encode_pattern(n, cells);
			Pattern check;
			if(!parse_pattern(text, check, why))
				return refuse("the box's voxels as a pattern: "+why);
			json::Value set = json::object();
			set.set("id", (int64_t)e->id);
			set.set("comp", (int64_t)(in - &e->comps[0]));
			set.set("param", param);
			set.set("value", text);
			sv_<std::pair<uint64_t, json::Value>> change;
			ss_ what;
			if(!build_change("set", set, p, change, what, why))
				return refuse(why);
			commit(change, &m_undo[p.name]);
			log_i(MODULE, "An edit by %s: %s %s, %zu cells in %zu voxels "
					"(%zu bytes)", cs(p.name), action == "capture" ?
					"captured" : "filled", cs(who), total, check.names.size(),
					text.size());
			world_check(p.name);
			return;
		}
		if(action != "show")
			return refuse("action: capture, fill or show");
		const ss_ text = jstr(in->params, param.c_str());
		Pattern pt;
		if(text.empty())
			return refuse(who+" is empty");
		if(!parse_pattern(text, pt, why))
			return refuse(who+": "+why);
		if(pt.n[0] != n[0] || pt.n[1] != n[1] || pt.n[2] != n[2])
			return refuse(who+" is of a box "+itos(pt.n[0])+"x"+
					itos(pt.n[1])+"x"+itos(pt.n[2])+", the box "+itos(n[0])+
					"x"+itos(n[1])+"x"+itos(n[2]));
		Change nc;
		nc.stroke = -2;
		nc.scene = scene_of(*e);
		voxelworld::access(m_server, nc.scene, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			sv_<uint32_t> ids;
			for(const ss_ &nm : pt.names){
				interface::VoxelName vn;
				vn.block_name = nm;
				const interface::VoxelDefinition *d = reg->get(vn);
				if(!d){
					why = "no voxel "+nm;
					return;
				}
				ids.push_back(d->id);
			}
			size_t i = 0;
			for(int y = 0; y < n[1]; y++)
				for(int z = 0; z < n[2]; z++)
					for(int x = 0; x < n[0]; x++, i++){
						const pv::Vector3DInt32 q = o + pv::Vector3DInt32(x, y, z);
						uint32_t old = 0;
						if(!hm_section(w, q) || !voxel_id(w, q, old)){
							why = "a cell of the box is not loaded";
							continue;
						}
						if(old == ids[pt.cells[i]])
							continue;
						nc.cells[std::make_tuple(q.getX(), q.getY(),
								q.getZ())] = old;
						set_id(w, q, ids[pt.cells[i]]);
						mark(w, nc.scene, q, 'k', p.name);
					}
		});
		if(!nc.cells.empty()){
			std::deque<Change> &u = m_undo[p.name];
			u.push_back(nc);
			while(u.size() > UNDO_MAX)
				u.pop_front();
		}
		log_i(MODULE, "An edit by %s: showed %s, %zu cells written%s",
				cs(p.name), cs(who), nc.cells.size(),
				why.empty() ? "" : cs(" ("+why+")"));
		send_state(peer);
	}

	// Where voxelworld keeps the World loaded: a finite map's sections
	// pinned, its whole; an infinite one, and a heightmap's voxels (air
	// over the terrain), round each player and the spawn
	void world_load_points()
	{
		if(!m_w->world_scene)
			return;
		sv_<voxelworld::LoadPoint> pts;
		const int S = m_w->section_size;
		auto sec = [&](int v){ return v >= 0 ? v / S : -((-v + S - 1) / S); };
		const world::Params &p = m_w->wp;
		if(p.heightmap() || !p.finite()){
			// [KIT_HM_WALK] round the spawn and each player; a heightmap's
			// voxels are air built on over the terrain
			// [KIT_HM_FREE] A heightmap's: only the sections the save has
			// (what was built) loaded, none generated (-1): a body walks
			// over cells not loaded (move.lua's), and an edit generates
			// its own section (hm_section())
			const int hgen = p.heightmap() ? -1 : 1;
			double x = 0, y = 0, z = 0;
			world_spawn(x, y, z);
			pts.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					p.heightmap() ? (int)x : 0, (int)y, p.heightmap() ? (int)z : 0),
					1, 1, hgen, hgen));
			const int gxz = p.heightmap() ? -1 : world::GEN_XZ;
			const int gy = p.heightmap() ? -1 : world::LOAD_Y;
			for(auto &wp : m_w->world_peers)
				pts.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
						wp.second[0], wp.second[1], wp.second[2]),
						world::LOAD_XZ, world::LOAD_Y, gxz, gy, wp.first));
		} else {
			// A finite voxel World: every section of the map
			const int m = p.border == "water" ? world::SEA_BORDER :
					p.border == "wall" ? 1 : 0;
			const int ylo = std::min(m_w->world_min, p.border == "water" ?
					p.sea_level - world::SEA_BED : INT_MAX) -
					(p.with_caves() ? world::CAVE_DEEP : 8);
			const int yhi = std::max(m_w->world_max + (p.border == "wall" ? 4 : 0),
					p.sea_level);
			for(int sx = sec(p.x0() - m); sx <= sec(p.x0() + p.width - 1 + m); sx++)
			for(int sz = sec(p.z0() - m); sz <= sec(p.z0() + p.depth - 1 + m); sz++)
			for(int sy = std::max(sec(ylo), (int)WORLD_SECTION_Y0);
					sy <= std::min(sec(yhi), (int)WORLD_SECTION_Y1); sy++)
				pts.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
						sx * S + S / 2, sy * S + S / 2, sz * S + S / 2), 0, 0, 0, 0));
		}
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			w->set_load_points(pts);
		});
		log_v(MODULE, "World: %zu load points", pts.size());
	}

	// An infinite World, or a heightmap's voxels, load round a player as
	// they go (the section they are in changed)
	void world_peer(size_t peer, const ss_ &scene, double x, double y,
			double z)
	{
		// [KIT_SCENES] Gone from another scene's World: it loads round
		// them no more
		for(auto &w : m_worlds){
			if(w.first == scene || !w.second.world_peers.erase(peer))
				continue;
			WorldScope ws(m_w, &w.second);
			world_load_points();
		}
		WorldScope ws(m_w, world_named(scene));
		if(!m_w->world_scene || (m_w->wp.finite() && !m_w->wp.heightmap()) ||
				m_w->name != scene)
			return;
		const std::array<int32_t, 3> c = {{(int32_t)std::floor(x),
				(int32_t)std::floor(y), (int32_t)std::floor(z)}};
		auto it = m_w->world_peers.find(peer);
		const int S = m_w->section_size;
		if(it != m_w->world_peers.end()){
			bool same = true;
			for(int k = 0; k < 3; k++)
				same = same && std::floor(it->second[k] / (double)S) ==
						std::floor(c[k] / (double)S);
			if(same)
				return;
		}
		m_w->world_peers[peer] = c;
		world_load_points();
	}

	void scene_spawn(const ss_ &scene, double &x, double &y, double &z)
	{
		WorldScope ws(m_w, scene.empty() ? nullptr : world_named(scene));
		world_spawn(x, y, z);
	}

	void world_spawn(double &x, double &y, double &z)
	{
		x = 0.5;
		y = 1;
		z = 0.5;
		if(!m_w->world_scene)
			return;
		const world::Params &p = m_w->wp;
		if(p.heightmap()){
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_w->world_scene);
				if(!map)
					return;
				x = map->samples_x() / 2 + 0.5;
				z = map->samples_z() / 2 + 0.5;
				y = map->height_at((float)x, (float)z) + 0.5;
			});
			return;
		}
		x = m_w->world_spawn[0] + 0.5;
		y = m_w->world_spawn[1];
		z = m_w->world_spawn[2] + 0.5;
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
		m_w->world_spawn = {{0, p.generator == "empty" ? p.level : 1, 0}};
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
				m_w->world_spawn = {{(int)dx, t + 1, (int)dz}};
			}
		if(best < 0)
			m_w->world_spawn = {{0, std::max(tops[(size_t)(d / 2) * w + w / 2],
					p.sea_level) + 1, 0}};
	}

	void on_generated(const worldgen::SectionGenerated &e)
	{
		WorldScope ws(m_w, world_at(e.scene));
		if(e.scene == m_w->world_scene && m_w->world_scene)
			m_w->world_generated++;
	}

	void on_gen_queue(const worldgen::QueueModifiedEvent &e)
	{
		WorldScope ws(m_w, world_at(e.scene));
		if(e.scene != m_w->world_scene || !m_w->world_scene || e.queue_size ||
				m_w->world_generated == m_w->world_logged)
			return;
		// The event's queue size is the one when it was emitted: a
		// regeneration queued since, or a section still being generated,
		// is not done ([KIT_REGENERATED_EARLY]: a brush right after "World:
		// generated again" found no ground)
		size_t pending = 0;
		worldgen::access(m_server, [&](worldgen::Interface *i){
			worldgen::Instance *wi = i->get_instance(m_w->world_scene);
			pending = wi ? wi->get_num_sections_pending() : 0;
		});
		if(pending)
			return;
		bool back = true;
		if(!m_w->regen_wait.empty())
			voxelworld::access(m_server, m_w->world_scene,
					[&](voxelworld::Instance *w){
				for(const pv::Vector3DInt16 &sp : m_w->regen_wait)
					if(!w->is_section_loaded(sp) ||
							!w->is_section_generated(sp)){
						back = false;
						break;
					}
			});
		if(!back)
			return;
		m_w->regen_wait.clear();
		m_w->world_logged = m_w->world_generated;
		log_i(MODULE, "World: %zu sections generated since the start",
				m_w->world_generated);
		// [KIT_SCENES_GENERATED] The builders in a new World's scene told
		// its ground is in: what they read of it after is the generator's
		if(m_w->world_first){
			m_w->world_first = false;
			sv_<size_t> in;
			for(auto &p : m_peers)
				if(can_edit(p.first) && p.second.scene == m_w->name)
					in.push_back(p.first);
			network::access(m_server, [&](network::Interface *inetwork){
				for(size_t peer : in)
					inetwork->send(peer, "kit:generated", m_w->name);
			});
		}
		// Builders told the regeneration is done: what they read of the
		// ground after it is the new ground's
		if(!m_w->world_regenerating)
			return;
		m_w->world_regenerating = false;
		sv_<size_t> to;
		for(auto &p : m_peers)
			if(can_edit(p.first))
				to.push_back(p.first);
		network::access(m_server, [&](network::Interface *inetwork){
			for(size_t peer : to)
				inetwork->send(peer, "kit:regenerated", "");
		});
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
					// (a copy, set back: its `when` substituted too)
					json::Value sub = (*it).deepcopy();
					params(sub, depth + 1);
					set.push_back(std::make_pair(it.key(), sub));
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
			// (a seat: taken by a use, [KIT] stage 4h)
			// ([KIT_USE_ACCESS] "locked": its use is nobody's, a click
			// told so)
			if(use_kind(in)){
				if(jstr(in.params, "use") != "nobody")
					show.set("usable", true);
				else if(!show.get("usable").is_true())
					show.set("usable", ss_("locked"));
			}
			// [KIT] stage 4j: a region's extent by its parameter (its state's
			// size while resized), and its border drawn in play
			if(!ty.region.empty() && show.get("region").is_undefined()){
				int n[3];
				extent(in.params.get(ty.region), n);
				json::Value g = json::array();
				for(int k = 0; k < 3; k++)
					g.append(n[k]);
				show.set("region", g);
				if(in.params.get("show_border").is_true())
					show.set("border", true);
			}
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
			// [KIT] stage 4l: its links shown in play, [to id, ...]
			for(const Link &l : in.links)
				if(l.visible){
					if(show.get("links").is_undefined())
						show.set("links", json::array());
					json::Value ls = show.get("links");
					ls.append((int64_t)l.to);
					show.set("links", ls);
				}
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
			o += "},yaw=";
			lua_lit(json::Value(e.yaw), o);
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
			if(app_items()){
				// [KIT] stage 6a: the app's own, as Kit's counts are read
				o += ",items=";
				auto ai = m_app_items.find(m_entities[pid].name);
				lua_lit(ai == m_app_items.end() ? json::object() : ai->second, o);
			} else if(!pv_){
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
		// [KIT_VOXEL_STATES] its voxel box's size, and with reads_voxels
		// its voxels: their names and each cell's index in them (from 1; 0:
		// not loaded)
		{
			pv::Vector3DInt32 bo;
			int bn[3];
			if(voxel_box(e, in, bo, bn)){
				o += ",box={"+itos(bn[0])+","+itos(bn[1])+","+itos(bn[2])+"}";
				if(m_types[in.type].reads_voxels){
					const sv_<ss_> cells = read_box(e, bo, bn);
					sm_<ss_, size_t> index;
					ss_ ids;
					o += ",voxels={names={";
					for(const ss_ &c : cells){
						if(c.empty()){
							ids += "0,";
							continue;
						}
						auto it = index.find(c);
						if(it == index.end()){
							it = index.insert(std::make_pair(c,
									index.size() + 1)).first;
							lua_lit(json::Value(c), o);
							o += ",";
						}
						ids += itos(it->second)+",";
					}
					o += "},ids={"+ids+"}}";
				}
			}
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
		m_ret = json::null();
		const ss_ request = request_of(e, e.comps[r.comp], r);
		const uint64_t pid = player_id(r.by);
		uint64_t inv_id = 0;
		size_t inv_comp = 0;
		const bool called = box_call(request, answer, error, &runaway, &spent,
				&in_provider);
		{
			// Its cost ([KIT] stage 4l), to the instance that ran
			auto ci = m_entities.find(r.entity);
			if(ci != m_entities.end() && r.comp < ci->second.comps.size())
				ci->second.comps[r.comp].spent += spent;
		}
		if(!called){
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
		if(fx.get("ret").is_array())
			m_ret = fx.get("ret");
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
		json::Value tried_out = json::array();
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
			if(r.tried){
				json::Value o = json::array();
				o.append(output);
				o.append(value);
				tried_out.append(o);
			}
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
				if(l.visible){
					ss_ scene;
					scene_of(e, &scene);
					auto pf = m_play_flows.find(scene);
					if(pf == m_play_flows.end())
						pf = m_play_flows.emplace(scene, json::array()).first;
					if(pf->second.size() < MAX_FLOWS){
						json::Value f = json::array();
						f.append((int64_t)e.id);
						f.append(output);
						f.append((int64_t)l.to);
						f.append(l.input);
						pf->second.append(f);
					}
				}
				deliver(l.to, l.input, value, r.by, r.hops + 1, e.id, output);
			}
		}
		// [KIT_TRY_INPUTS] The Try's answer: what it emitted, nothing too
		if(r.tried){
			json::Value a = json::object();
			a.set("id", (int64_t)r.entity);
			a.set("input", r.args.at(0u));
			a.set("emitted", tried_out);
			log_i(MODULE, "A try of entity %s's %s emitted %s", cs(itos(r.entity)),
					cs(r.args.at(0u).stringify()), cs(tried_out.stringify().
					substr(0, 200)));
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(r.tried - 1, "kit:tried", a.stringify());
			});
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
			// The cells it owns, or a grants type's or a region's box
			// ([KIT_TRIGGER_DIG]: kit/region's dig_out), MAX_SET_CELLS at most
			sv_<pv::Vector3DInt32> cells = owned_cells(e);
			if(!t.owns_voxel && (!t.grants.empty() || !t.region.empty()) &&
					e.has_pos){
				int n[3];
				if(!t.region.empty())
					region_extent(in, t, n);
				else
					extent(in.params.get(t.grants), n);
				const pv::Vector3DInt32 o = voxel_p(e);
				if(n[0] * n[1] * n[2] <= MAX_SET_CELLS)
					for(int x = 0; x < n[0]; x++)
						for(int y = 0; y < n[1]; y++)
							for(int z = 0; z < n[2]; z++)
								cells.push_back(o + pv::Vector3DInt32(x, y, z));
				else
					log_w(MODULE, "Entity %s's %s sets %i cells, past %i",
							cs(itos(e.id)), cs(type), n[0] * n[1] * n[2],
							MAX_SET_CELLS);
			}
			if(cells.empty()){
				log_w(MODULE, "Entity %s's %s sets a voxel it does not own",
						cs(itos(e.id)), cs(type));
			} else {
				for(const pv::Vector3DInt32 &p : cells){
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
		const json::Value &vx = fx.get("voxels");
		if(vx.is_array() && vx.size())
			set_voxels(e, in, vx, r.by, t.builds && pid ? 'b' : 'g');
		// c:after(seconds, name, {player = id}): {{name, seconds, player}}
		const json::Value &after = fx.get("after");
		for(unsigned i = 0; i < after.size(); i++){
			const json::Value &a = after.at(i);
			const ss_ name = a.at(0).is_string() ? a.at(0).as_string() : "";
			const double s = a.at(1).is_number() ? a.at(1).as_number() : -1;
			ss_ player;
			const json::Value &pl = a.at(2);
			if(pl.is_number() && pl.as_number() > 0)
				player = "player:" + itos((int64_t)pl.as_number());
			else if(pl.is_string())
				player = pl.as_string();
			if(!player.empty() && !player_id(player)){
				log_w(MODULE, "Entity %s's %s: after: %s is no player",
						cs(itos(e.id)), cs(type), cs(player));
				continue;
			}
			set_timer(e, in, name, player, s, r.by);
		}
		const ss_ who = player_of(r.by);
		const json::Value &tp = fx.get("teleport");
		if(tp.is_array())
			teleport(e, type, who, tp, fx.get("teleport_yaw"),
					fx.get("teleport_scene"), fx.get("teleport_entity"));
		const json::Value &apps = fx.get("app");
		for(unsigned i = 0; i < apps.size(); i++)
			app_call(e, type, r.by, who, apps.at(i));
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
				if(m_host.persistent || (origin == 'b' && always_keep())){
					// A build kept as made (in a persistent world any
					// removal): out of the start too
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
		// [KIT_PREFAB_VOXELS] its voxels, if any: then it may have no
		// entities
		const bool vox = !j.get("voxels").is_undefined();
		if(vox && !check_voxels(j.get("voxels"), why)){
			why = "voxels: "+why;
			return false;
		}
		const json::Value &es = j.get("entities");
		if(!es.is_array() || es.size() < (vox ? 0 : 1) ||
				es.size() > MAX_PREFAB){
			why = (vox ? "0" : "1")+ss_(" to ")+itos(MAX_PREFAB)+" entities";
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
				// [KIT] stage 5: a member of an older version of its type
				// is checked as its copies will be made, migrated
				json::Value ps = c.get("params");
				if(ps.is_object() && json::jint(c, "version", 1) <
						m_types[type].version){
					ps = ps.deepcopy();
					migrate_params(type, json::jint(c, "version", 1), ps,
							"A prefab's "+who);
				}
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

	// [KIT_PREFAB_VOXELS] A prefab's voxels: {"at": [x, y, z] (its box's
	// low corner from the prefab's base, whole numbers), "size": [x, y, z]
	// (1...MAX_PREFAB_BOX each), "air": true (its air cells replace what is
	// there; else they are skipped), "kinds": [[voxel name, param, tint]...]
	// (MAX_PREFAB_KINDS at most), "runs": [count, kind, count, kind...]
	// (the cells x fastest, then z, then y, every one)}
	static bool check_voxels(const json::Value &v, ss_ &why)
	{
		if(!v.is_object()){
			why = "an object";
			return false;
		}
		auto whole = [](const json::Value &n, double lo, double hi){
			return n.is_number() && n.as_number() >= lo &&
					n.as_number() <= hi && n.as_number() == std::floor(
					n.as_number());
		};
		const json::Value &at = v.get("at"), &size = v.get("size");
		if(!at.is_array() || at.size() != 3 || !size.is_array() ||
				size.size() != 3){
			why = "at and size: three numbers each";
			return false;
		}
		size_t total = 1;
		for(unsigned k = 0; k < 3; k++){
			if(!whole(at.at(k), -MAX_COORD, MAX_COORD) ||
					!whole(size.at(k), 1, MAX_PREFAB_BOX)){
				why = "at: whole numbers within "+itos((int)MAX_COORD)+
						", size: 1..."+itos(MAX_PREFAB_BOX)+" each";
				return false;
			}
			total *= (size_t)size.at(k).as_number();
		}
		if(!v.get("air").is_undefined() && !v.get("air").is_boolean()){
			why = "air: true or false";
			return false;
		}
		const json::Value &kinds = v.get("kinds"), &runs = v.get("runs");
		if(!kinds.is_array() || kinds.size() < 1 ||
				kinds.size() > MAX_PREFAB_KINDS){
			why = "kinds: 1 to "+itos(MAX_PREFAB_KINDS);
			return false;
		}
		for(unsigned i = 0; i < kinds.size(); i++){
			const json::Value &c = kinds.at(i);
			if(!c.is_array() || c.size() != 3 || !c.at(0u).is_string() ||
					!voxel_name_ok(c.at(0u).as_string()) ||
					!whole(c.at(1u), 0, 255) || !whole(c.at(2u), 0, 15)){
				why = "a kind is [a voxel's name, param 0..255, tint 0..15]";
				return false;
			}
		}
		if(!runs.is_array() || runs.size() % 2 != 0){
			why = "runs: [count, kind...]";
			return false;
		}
		size_t n = 0;
		for(unsigned i = 0; i < runs.size(); i += 2){
			if(!whole(runs.at(i), 1, (double)total) ||
					!whole(runs.at(i + 1), 0, kinds.size() - 1)){
				why = "runs: a count from 1 and a kind's index each";
				return false;
			}
			n += (size_t)runs.at(i).as_number();
			if(n > total)
				break;
		}
		if(n != total){
			why = "runs: "+itos(n)+" cells, the box has "+itos(total);
			return false;
		}
		return true;
	}

	// A cell of a prefab's box turned k quarter turns round y about its
	// base cell (a cell's middle is its whole coordinates; Urho3D's +z
	// towards +x, as move_group()'s): x, z from the base
	static void turn_cell(int &x, int &z, int k)
	{
		for(int i = 0; i < (k & 3); i++){
			const int nx = z, nz = -x;
			x = nx;
			z = nz;
		}
	}
	// An offset (a member's position) turned likewise
	static void turn_offset(double &x, double &z, int k)
	{
		for(int i = 0; i < (k & 3); i++){
			const double nx = z, nz = -x;
			x = nx;
			z = nz;
		}
	}

	// Whether a voxel's param is a shape's facing (world.h's shapes:
	// "<material>:<shape>")
	static bool is_shape(const ss_ &name)
	{
		const size_t colon = name.rfind(':');
		if(colon == ss_::npos)
			return false;
		for(const world::ShapeDef &d : world::shapes())
			if(name.compare(colon + 1, ss_::npos, d.name) == 0)
				return true;
		return false;
	}

	// [KIT_PREFAB_VOXELS] A box of a scene's voxels ([o, o + n)) as a
	// prefab's voxels, at from `base`; null with why if a cell of it is
	// not loaded or the scene has no voxels
	json::Value read_voxels(main_context::SceneReference ref,
			const int o[3], const int n[3], const int base[3], bool air,
			ss_ &why, size_t *solid = nullptr)
	{
		json::Value out = json::null();
		bool any = false;
		voxelworld::access(m_server, ref, [&](voxelworld::Instance *w){
			any = true;
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			const interface::VoxelFormat &f = reg->get_format();
			std::map<std::tuple<ss_, uint32_t, uint32_t>, size_t> index;
			json::Value kinds = json::array(), runs = json::array();
			int64_t last = -1, count = 0;
			size_t not_air = 0;
			for(int y = 0; y < n[1]; y++)
				for(int z = 0; z < n[2]; z++)
					for(int x = 0; x < n[0]; x++){
						const pv::Vector3DInt32 q(o[0] + x, o[1] + y, o[2] + z);
						uint32_t word = 0;
						if(!voxel_id(w, q, word)){
							why = "the cell ("+itos(q.getX())+","+itos(q.getY())+
									","+itos(q.getZ())+")'s section is not loaded";
							return;
						}
						const interface::VoxelDefinition *d =
								reg->get(f.id.get(word));
						const ss_ name = d ? d->name.block_name : ss_("air");
						const uint32_t pm = f.param.bound() ? f.param.get(word) : 0;
						const uint32_t tn = f.tint.bound() ? f.tint.get(word) : 0;
						if(name != "air")
							not_air++;
						const auto key = std::make_tuple(name, pm, tn);
						auto it = index.find(key);
						if(it == index.end()){
							if(index.size() >= MAX_PREFAB_KINDS){
								why = "more than "+itos(MAX_PREFAB_KINDS)+
										" kinds of cell";
								return;
							}
							it = index.insert(std::make_pair(key,
									index.size())).first;
							json::Value c = json::array();
							c.append(name);
							c.append((int64_t)pm);
							c.append((int64_t)tn);
							kinds.append(c);
						}
						if((int64_t)it->second == last){
							count++;
							continue;
						}
						if(count){
							runs.append(count);
							runs.append(last);
						}
						last = (int64_t)it->second;
						count = 1;
					}
			if(count){
				runs.append(count);
				runs.append(last);
			}
			out = json::object();
			json::Value at = json::array(), size = json::array();
			for(int k = 0; k < 3; k++){
				at.append((int64_t)(o[k] - base[k]));
				size.append((int64_t)n[k]);
			}
			out.set("at", at);
			out.set("size", size);
			if(air)
				out.set("air", true);
			out.set("kinds", kinds);
			out.set("runs", runs);
			if(solid)
				*solid = not_air;
		});
		if(!any)
			why = "the scene has no voxels";
		if(!why.empty())
			return json::null();
		return out;
	}

	// [KIT_PREFAB_VOXELS] A prefab's voxels written in a scene, its base
	// cell at `base`, turned k quarter turns (a shape's facing too): its
	// air cells skipped unless it has "air"; each cell's old word in nc
	// (an undo's) the first time. Cells not loaded and voxels the scene
	// has not are skipped, counted
	void write_voxels(const json::Value &vox, main_context::SceneReference ref,
			const int base[3], int k, Change &nc, const ss_ &who,
			size_t &written, size_t &missing, size_t &unknown)
	{
		const json::Value &at = vox.get("at"), &size = vox.get("size");
		const json::Value &kinds = vox.get("kinds"), &runs = vox.get("runs");
		const bool air = vox.get("air").is_true();
		int n[3], a[3];
		for(unsigned i = 0; i < 3; i++){
			n[i] = (int)size.at(i).as_number();
			a[i] = (int)at.at(i).as_number();
		}
		voxelworld::access(m_server, ref, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			const interface::VoxelFormat &f = reg->get_format();
			// Each kind's word turned, or -1 (skipped)
			sv_<int64_t> words;
			sv_<bool> is_air;
			for(unsigned i = 0; i < kinds.size(); i++){
				const json::Value &c = kinds.at(i);
				const ss_ name = c.at(0u).as_string();
				interface::VoxelName vn;
				vn.block_name = name;
				const interface::VoxelDefinition *d = reg->get(vn);
				uint32_t pm = (uint32_t)c.at(1u).as_number();
				if(is_shape(name))
					pm = (pm & 4) | ((pm + k) & 3);
				words.push_back(d ? (int64_t)kit::voxel_word(f, d->id, pm,
						(uint32_t)c.at(2u).as_number()) : -1);
				is_air.push_back(name == "air");
			}
			size_t cell = 0;
			for(unsigned r = 0; r < runs.size(); r += 2){
				const size_t count = (size_t)runs.at(r).as_number();
				const size_t kind = (size_t)runs.at(r + 1).as_number();
				for(size_t c = 0; c < count; c++, cell++){
					if(is_air[kind] && !air)
						continue;
					if(words[kind] < 0){
						unknown++;
						continue;
					}
					int x = a[0] + (int)(cell % n[0]);
					int z = a[2] + (int)(cell / n[0] % n[2]);
					const int y = a[1] + (int)(cell / n[0] / n[2]);
					turn_cell(x, z, k);
					const pv::Vector3DInt32 q(base[0] + x, base[1] + y,
							base[2] + z);
					uint32_t old = 0;
					if(!hm_section(w, q) || !voxel_id(w, q, old)){
						missing++;
						continue;
					}
					const uint32_t word = (uint32_t)words[kind] &
							state_mask(f);
					if(old == word)
						continue;
					nc.cells.insert(std::make_pair(std::make_tuple(q.getX(),
							q.getY(), q.getZ()), old));
					set_id(w, q, word);
					mark(w, ref, q, 'k', who);
					written++;
				}
			}
		});
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
					if(l.visible)
						lj.set("visible", true);
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
	// member remembers it), "" for an entity's copy. turn: quarter turns
	// round y about the base ([KIT_PREFAB_VOXELS]), each member's position
	// and yaw
	void instantiate(const json::Value &pf, const ss_ &name, uint64_t scene,
			const double base[3], uint64_t first, sv_<json::Value> &out,
			int turn = 0)
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
				double off[3];
				for(unsigned k = 0; k < 3; k++)
					off[k] = m.get("pos").at(k).as_number();
				turn_offset(off[0], off[2], turn);
				for(unsigned k = 0; k < 3; k++)
					pos.append(grid(base[k] + off[k]));
				e.set("pos", pos);
				const double yaw = (m.get("yaw").is_number() ?
						m.get("yaw").as_number() : 0) + 90.0 * (turn & 3);
				if(m.get("yaw").is_number() || (turn & 3))
					e.set("yaw", norm_yaw(yaw));
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
					if(links.at(l).get("visible").is_boolean() &&
							links.at(l).get("visible").as_boolean())
						lj.set("visible", true);
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

	// {"op": "place", "prefab": name, "pos": [x, y, z], "turn": degrees}:
	// a copy of the prefab in the editor's scene, its members' ids the
	// next ones. [KIT_PREFAB_VOXELS] "clipboard": true instead of a
	// prefab: the builder's copy (a paste, its members no prefab's);
	// turn: a multiple of 90, the copy turned round y about its base
	// (members, their yaws, its voxels and their shapes' facings); its
	// voxels written in on_edit() once the entities are in (m_paste), its
	// base the cell pos is in (a cell's middle its whole coordinates)
	bool place_prefab(const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what,
			ss_ &why)
	{
		const bool paste = j.get("clipboard").is_true();
		const ss_ name = paste ? ss_() : jstr(j, "prefab");
		const json::Value *pf = nullptr;
		if(paste){
			auto ci = m_clipboard.find(p.name);
			if(ci == m_clipboard.end()){
				why = "nothing copied (the copy op)";
				return false;
			}
			pf = &ci->second;
		} else {
			pf = prefab(name);
		}
		if(!pf){
			why = "no prefab \""+name.substr(0, 130)+"\"";
			return false;
		}
		const json::Value &tj = j.get("turn");
		if(!tj.is_undefined() && !(tj.is_number() &&
				std::fabs(tj.as_number()) <= 3600 &&
				std::fmod(tj.as_number(), 90.0) == 0)){
			why = "turn: a multiple of 90 degrees";
			return false;
		}
		const int turn = tj.is_number() ?
				(((int)tj.as_number() / 90) % 4 + 4) % 4 : 0;
		const bool vox = pf->get("voxels").is_object();
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
			base[k] = vox ? std::floor(j.get("pos").at(k).as_number() + 0.5) :
					grid(j.get("pos").at(k).as_number());
		if(vox){
			if(m_host.scenes.find(p.scene) == m_host.scenes.end()){
				why = "not in a scene of the app's";
				return false;
			}
			m_paste.vox = pf->get("voxels");
			for(int k = 0; k < 3; k++)
				m_paste.base[k] = (int)base[k];
			m_paste.turn = turn;
			m_paste.set = true;
		}
		sv_<json::Value> rows;
		instantiate(*pf, name, scene, base, m_next_id, rows, turn);
		for(json::Value &row : rows){
			if(paste){
				// Named as a duplicate's are
				const json::Value &cs_ = row.get("components");
				if(cs_.size())
					row.set("name", jstr(cs_.at(0), "type")+" "+
							itos(json::jint(row, "id", 0)));
			}
			change.push_back(std::make_pair((uint64_t)json::jint(row, "id", 0),
					row));
		}
		what = (paste ? ss_("pasted the copy") : "placed prefab "+name)+
				(rows.empty() ? ss_() : " as "+itos(m_next_id)+"..."+
				itos(m_next_id + rows.size() - 1))+(turn ? ", turned "+
				itos(turn * 90) : ss_());
		m_next_id += rows.size();
		return true;
	}

	// [KIT_PREFAB_VOXELS] {"box": [x0, y0, z0, x1, y1, z1]} (cells, both
	// corners in it) as its low corner and size, MAX_PREFAB_BOX each way
	bool box_arg(const json::Value &j, int o[3], int n[3], ss_ &why)
	{
		const json::Value &b = j.get("box");
		if(!b.is_array() || b.size() != 6){
			why = "box: [x0, y0, z0, x1, y1, z1]";
			return false;
		}
		int c[6];
		for(unsigned i = 0; i < 6; i++){
			const json::Value &v = b.at(i);
			if(!v.is_number() || std::fabs(v.as_number()) > MAX_COORD ||
					v.as_number() != std::floor(v.as_number())){
				why = "box: whole numbers within "+itos((int)MAX_COORD);
				return false;
			}
			c[i] = (int)v.as_number();
		}
		for(int k = 0; k < 3; k++){
			o[k] = std::min(c[k], c[k + 3]);
			n[k] = std::abs(c[k] - c[k + 3]) + 1;
			if(n[k] > MAX_PREFAB_BOX){
				why = "box: "+itos(MAX_PREFAB_BOX)+" cells each way at most";
				return false;
			}
		}
		return true;
	}

	// [KIT_PREFAB_VOXELS] Entities (ids) and a box of voxels (box, air) as
	// an unnamed prefab: its base the box's low corner (else the first
	// entity's position; a cell's corner with voxels), the entities a
	// parent before its children. false with why
	bool group_with_voxels(const json::Value &j, const Peer &p,
			sv_<uint64_t> &group, json::Value &pf, ss_ &why)
	{
		const json::Value &ids = j.get("ids");
		const bool box = !j.get("box").is_undefined();
		if(!ids.is_undefined() && (!ids.is_array() ||
				ids.size() > MAX_PREFAB)){
			why = "ids: at most "+itos(MAX_PREFAB)+" entities";
			return false;
		}
		if(!box && (!ids.is_array() || ids.size() < 1)){
			why = "ids: 1 to "+itos(MAX_PREFAB)+" entities, or a box";
			return false;
		}
		for(unsigned i = 0; ids.is_array() && i < ids.size(); i++){
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
		int o[3] = {0, 0, 0}, n[3] = {0, 0, 0};
		if(box && !box_arg(j, o, n, why))
			return false;
		if(!j.get("air").is_undefined() && !j.get("air").is_boolean()){
			why = "air: true or false";
			return false;
		}
		double base[3] = {0, 0, 0};
		if(box){
			for(int k = 0; k < 3; k++)
				base[k] = o[k];
		} else if(m_entities[group[0]].has_pos){
			for(int k = 0; k < 3; k++)
				base[k] = m_entities[group[0]].pos[k];
		}
		pf = group_prefab(group, base);
		if(box){
			auto si = m_host.scenes.find(p.scene);
			if(si == m_host.scenes.end()){
				why = "not in a scene of the app's";
				return false;
			}
			const int b[3] = {o[0], o[1], o[2]};
			const json::Value v = read_voxels(si->second, o, n, b,
					j.get("air").is_true(), why);
			if(v.is_null())
				return false;
			pf.set("voxels", v);
		}
		if(pf.stringify().size() > MAX_TYPE_SOURCE){
			why = "it is past "+itos(MAX_TYPE_SOURCE)+" bytes as a prefab";
			return false;
		}
		return true;
	}

	// [KIT_PREFAB_VOXELS] {"op": "copy", "ids": [n...], "box": [x0, y0, z0,
	// x1, y1, z1], "air": bool}: the builder's copy (an unnamed prefab,
	// the server's: a paste is a place of it), entities, a box of voxels or
	// both
	void copy_op(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		sv_<uint64_t> group;
		json::Value pf;
		ss_ why;
		if(!group_with_voxels(j, p, group, pf, why))
			return refuse(why);
		m_clipboard[p.name] = pf;
		const json::Value &v = pf.get("voxels");
		log_i(MODULE, "%s copied %zu entities and %s", cs(p.name),
				group.size(), v.is_object() ? cs("a box of "+
				v.get("size").stringify()+" voxels ("+
				itos(v.get("kinds").size())+" kinds)") : "no voxels");
		send_state(peer);
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
		const json::Value *had = prefab(name);
		if(had && !jstr(*had, "package").empty()){
			why = name+" is the package "+jstr(*had, "package")+"'s";
			return false;
		}
		// [KIT_PREFAB_VOXELS] "box" (and "air"): a box of voxels in it too;
		// "clipboard": true: the builder's copy named (no entities of the
		// composition's become its copy)
		sv_<uint64_t> group;
		json::Value pf;
		if(j.get("clipboard").is_true()){
			auto ci = m_clipboard.find(p.name);
			if(ci == m_clipboard.end()){
				why = "nothing copied (the copy op)";
				return false;
			}
			pf = ci->second.deepcopy();
			if(!j.get("air").is_undefined() && pf.get("voxels").is_object()){
				json::Value v = pf.get("voxels").deepcopy();
				v.set("air", j.get("air").is_true());
				pf.set("voxels", v);
			}
		} else if(!group_with_voxels(j, p, group, pf, why)){
			return false;
		}
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
		const json::Value &vx = pf.get("voxels");
		what = "saved prefab "+name+" version "+itos(version)+" of "+
				itos(pf.get("entities").size())+" entities"+(vx.is_object() ?
				" and a box of "+vx.get("size").stringify()+" voxels"+
				(vx.get("air").is_true() ? " (air replaces)" : "") : ss_())+
				" ("+itos(updated)+" entities of other copies follow it)";
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
		for(auto &sf : m_play_flows){
			if(!sf.second.size())
				continue;
			const ss_ data = sf.second.stringify();
			network::access(m_server, [&](network::Interface *inetwork){
				for(auto &p : m_peers)
					if(!p.second.editing && p.second.scene == sf.first)
						inetwork->send(p.first, "kit:flow", data);
			});
		}
		m_play_flows.clear();
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

	// c:teleport(pos[, {yaw, scene, entity}]): the player who set the run
	// off, in the entity's scene, moved by the app, with a yaw looking that
	// way level ([KIT_SPAWNER_PLAYERS]). A component moves no one else.
	// [KIT_SCENES] `scene`: to pos in another scene of the composition (the
	// app moving them there); `entity`: to that entity's place, in its
	// scene, arriving there silently (its zone not entered)
	void teleport(const Entity &e, const ss_ &type, const ss_ &who,
			const json::Value &pos, const json::Value &yaw,
			const json::Value &to_scene_v = json::Value(),
			const json::Value &to_entity = json::Value())
	{
		ss_ scene;
		scene_of(e, &scene);
		const size_t peer = who.empty() ? 0 : peer_of(who, scene);
		ss_ target = to_scene_v.is_string() ? to_scene_v.as_string() : scene;
		double x = 0, y = 0, z = 0;
		const Entity *te = nullptr;
		if(to_entity.is_number()){
			auto it = m_entities.find((uint64_t)to_entity.as_number());
			if(it != m_entities.end() && it->second.has_pos &&
					it->second.kind.empty()){
				te = &it->second;
				ss_ ts;
				if(scene_of(*te, &ts)){
					target = ts;
					x = te->pos[0];
					y = te->pos[1];
					z = te->pos[2];
				} else {
					te = nullptr;
				}
			}
		} else if(pos_ok(pos)){
			x = pos.at(0u).as_number();
			y = pos.at(1u).as_number();
			z = pos.at(2u).as_number();
		}
		const bool other = target != scene;
		const char *why = !m_host.moves_players && !m_host.controls ?
				"the app moves no players" :
				who.empty() ? "no player set it off" :
				!peer ? "the player is not in its scene" :
				to_entity.is_number() && !te ? "the target is no placed entity" :
				!to_entity.is_number() && !pos_ok(pos) ? "not a position" :
				other && !m_host.scenes.count(target) ?
						"no scene of that name" :
				other && !m_host.make_scene ?
						"the app moves no one between scenes" : nullptr;
		if(why){
			log_w(MODULE, "Entity %s's %s: a teleport refused: %s",
					cs(itos(e.id)), cs(type), why);
			return;
		}
		const double look = yaw.is_number() && std::isfinite(yaw.as_number()) ?
				norm_yaw(yaw.as_number()) : NAN;
		const ss_ in = other ? " in the scene "+target : "";
		if(std::isnan(look))
			log_i(MODULE, "Entity %s's %s teleports %s to (%g, %g, %g)%s",
					cs(itos(e.id)), cs(type), cs(who), x, y, z, cs(in));
		else
			log_i(MODULE, "Entity %s's %s teleports %s to (%g, %g, %g)%s "
					"facing %g", cs(itos(e.id)), cs(type), cs(who), x, y, z,
					cs(in), look);
		if(te)
			m_arrive[who] = std::make_pair(te->id,
					interface::os::game_us() + 10000000);
		to_scene(peer, other ? target : "", x, y, z, look);
	}

	// [KIT_SCENES] A player teleported onto an entity, by name: its id and
	// until when (game µs) stepping into its zone is no entering
	std::map<ss_, std::pair<uint64_t, int64_t>> m_arrive;

	// ---- [KIT_ENVIRONMENT] The environment: a scene's own kit/environment
	// (on its scene entity, no position), else the root's; its parameters
	// over the type's defaults and what its signals set (state.set). Kit
	// keeps its clock (the time of day going at day_minutes a day) and
	// tells the clients in the scene ("kit:environment") as it changes;
	// the season's voxel textures go as a registry ("kit:season")

	// The environment instance on an entity (nullptr: none)
	const Instance* env_on(const Entity &e)
	{
		if(e.has_pos || !e.kind.empty())
			return nullptr;
		for(const Instance &i : e.comps)
			if(m_types.count(i.type) && m_types[i.type].environment &&
					i.disabled.empty())
				return &i;
		return nullptr;
	}

	// The environment on an entity's children: the root's (1) or a
	// scene's; its entity's id in *id
	const Instance* env_at(uint64_t parent, uint64_t *id = nullptr)
	{
		if(!parent)
			return nullptr;
		for(auto &p : m_entities){
			if(p.second.parent != parent)
				continue;
			const Instance *in = env_on(p.second);
			if(in){
				if(id)
					*id = p.first;
				return in;
			}
		}
		return nullptr;
	}

	// A scene's: its own, else the root's; from says which
	const Instance* env_of(const ss_ &scene, uint64_t *id = nullptr,
			const char **from = nullptr)
	{
		const Instance *in = env_at(scene_id(scene), id);
		if(from)
			*from = in ? "scene" : "root";
		return in ? in : env_at(1, id);
	}

	json::Value env_values(const Instance &in)
	{
		json::Value v = params_of(in.type, &in);
		const json::Value &set = in.state.get("set");
		if(set.is_object())
			for(json::Iterator it(set); it; ++it)
				if(v.get(it.key()).is_number() ? (*it).is_number() :
						v.get(it.key()).is_string() && (*it).is_string())
					v.set(it.key(), *it);
		return v;
	}

	double env_gravity(const ss_ &scene)
	{
		const Instance *in = env_of(scene);
		if(!in)
			return 1;
		const json::Value g = env_values(*in).get("gravity");
		return g.is_number() && std::isfinite(g.as_number()) ?
				std::max(0.0, std::min(10.0, g.as_number())) : 1;
	}

	// An environment's clock: from `base` hours at `at` (game µs), a day
	// each `minutes`; started again as set_time's count or the time
	// parameter changes
	struct EnvClock
	{
		ss_ seq;
		double base = 12, minutes = 0, last = -1;
		int64_t at = 0;
	};
	std::map<uint64_t, EnvClock> m_env_clock;
	sm_<ss_, ss_> m_env_sent, m_season_sent;
	// A scene's season registry, by scene and season: the base registry's
	// count it was made of, and it serialized ("": nothing to swap)
	std::map<ss_, std::pair<size_t, ss_>> m_season_regs;

	static double env_num(const json::Value &v, const char *k, double def)
	{
		const json::Value &x = v.get(k);
		return x.is_number() && std::isfinite(x.as_number()) ?
				x.as_number() : def;
	}

	EnvClock& env_clock(uint64_t id, const Instance &in, const json::Value &v)
	{
		EnvClock &c = m_env_clock[id];
		const int64_t now = interface::os::game_us();
		const ss_ seq = in.params.get("time").stringify()+"|"+
				in.state.get("time_set").stringify();
		const double minutes = std::max(0.0, env_num(v, "day_minutes", 0));
		if(seq != c.seq){
			c.seq = seq;
			c.base = std::fmod(std::max(0.0, env_num(v, "time", 12)), 24.0);
			c.at = now;
			c.minutes = minutes;
			c.last = -1;
		} else if(minutes != c.minutes){
			c.base = env_hours(c, now);
			c.at = now;
			c.minutes = minutes;
		}
		return c;
	}

	static double env_hours(const EnvClock &c, int64_t now)
	{
		if(c.minutes <= 0)
			return c.base;
		const double h = c.base + (double)(now - c.at) / 1e6 / 60.0 /
				c.minutes * 24.0;
		return std::fmod(h, 24.0);
	}

	// What the clients of a scene are told: {"on"} with none, else the
	// values, "from" (root or scene) and the time now
	json::Value env_json(const ss_ &scene, ss_ *key = nullptr)
	{
		json::Value j = json::object();
		uint64_t id = 0;
		const char *from = "root";
		const Instance *in = env_of(scene, &id, &from);
		j.set("on", in != nullptr);
		if(!in){
			if(key)
				*key = j.stringify();
			return j;
		}
		const json::Value v = env_values(*in);
		for(json::Iterator it(v); it; ++it)
			j.set(it.key(), *it);
		j.set("from", from);
		j.set("entity", (int64_t)id);
		EnvClock &c = env_clock(id, *in, v);
		if(key)
			*key = j.stringify()+"|"+itos(c.at)+"|"+std::to_string(c.base);
		j.set("time", env_hours(c, interface::os::game_us()));
		return j;
	}

	void send_env(size_t peer)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return;
		const ss_ s = env_json(pi->second.scene).stringify();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:environment", s);
		});
		send_season(pi->second.scene, (int64_t)peer);
	}

	// Each tick: a scene's environment changed is told to its peers; the
	// clocks' dawn (6) and dusk (18) run on_daytime, Running
	void env_tick()
	{
		for(auto &sc : m_host.scenes){
			const ss_ &scene = sc.first;
			if(!scene_id(scene))
				continue;
			ss_ key;
			const json::Value j = env_json(scene, &key);
			ss_ &sent = m_env_sent[scene];
			if(key != sent){
				sent = key;
				const ss_ s = j.stringify();
				log_i(MODULE, "Environment of the scene %s: %s", cs(scene),
						cs(s.substr(0, 400)));
				network::access(m_server, [&](network::Interface *inetwork){
					for(auto &p : m_peers)
						if(p.second.scene == scene)
							inetwork->send(p.first, "kit:environment", s);
				});
			}
			send_season(scene, -1);
		}
		const int64_t now = interface::os::game_us();
		for(auto &c : m_env_clock){
			auto e = m_entities.find(c.first);
			const Instance *in = e == m_entities.end() ? nullptr :
					env_on(e->second);
			if(!in)
				continue;
			const double h = env_hours(c.second, now);
			const double was = c.second.last;
			c.second.last = h;
			if(was < 0 || c.second.minutes <= 0 || !m_session.running)
				continue;
			for(double mark : {6.0, 18.0}){
				const bool passed = was <= h ? (was < mark && h >= mark) :
						(was < mark || h >= mark);
				if(!passed)
					continue;
				Run r;
				r.entity = c.first;
				r.comp = in - &e->second.comps[0];
				r.handler = "on_daytime";
				r.args.append(mark == 6.0 ? "dawn" : "dusk");
				queue_run(r);
			}
		}
	}

	// The season's registry to a scene's peers (-1: those not told it
	// yet) or one peer: the base registry with the season textures of the
	// materials that have them; "" swaps back
	void send_season(const ss_ &scene, int64_t peer)
	{
		const Instance *in = env_of(scene);
		const ss_ season = in ? jstr(env_values(*in), "season") : "";
		if(peer < 0 && m_season_sent[scene] == season)
			return;
		if(peer < 0)
			m_season_sent[scene] = season;
		auto si = m_host.scenes.find(scene);
		if(si == m_host.scenes.end() || !si->second)
			return;
		size_t count = 0;
		sv_<interface::VoxelDefinition> defs;
		interface::VoxelFormat format;
		interface::VoxelSelector look;
		bool have = false;
		voxelworld::access(m_server, si->second, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *r = w->get_voxel_reg();
			if(!r)
				return;
			count = r->get_count();
			have = true;
			std::pair<size_t, ss_> &c = m_season_regs[scene+"\n"+season];
			if(c.first == count && count)
				return;
			defs = r->get_all();
			format = r->get_format();
			look = r->get_look_selector();
		});
		if(!have)
			return;
		std::pair<size_t, ss_> &c = m_season_regs[scene+"\n"+season];
		if(c.first != count || !count){
			size_t swapped = 0;
			for(interface::VoxelDefinition &d : defs){
				const ss_ &n = d.name.block_name;
				auto mi = m_registered.find(n.substr(0, n.find(':')));
				if(mi == m_registered.end())
					continue;
				auto se = mi->second.seasons.find(season);
				if(se == mi->second.seasons.end())
					continue;
				for(int f = 0; f < 6; f++)
					d.textures[f].resource_name = se->second[f == 0 ? 0 :
							f == 1 ? 2 : 1];
				swapped++;
			}
			ss_ data;
			if(swapped){
				up_<interface::VoxelRegistry> reg(
						interface::createVoxelRegistry());
				reg->set_format(format);
				reg->add_voxels(defs);
				reg->set_look_selector(look);
				data = reg->serialize();
			}
			c = std::make_pair(count, data);
			log_i(MODULE, "Season %s of the scene %s: %zu voxel types' "
					"textures swapped", cs(season.empty() ? "none" : season),
					cs(scene), swapped);
		}
		const ss_ msg = season+"\n"+c.second;
		network::access(m_server, [&](network::Interface *inetwork){
			if(peer >= 0){
				inetwork->send((size_t)peer, "kit:season", msg);
				return;
			}
			for(auto &p : m_peers)
				if(p.second.scene == scene)
					inetwork->send(p.first, "kit:season", msg);
		});
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
		if(app_items()){
			json::Value &had = m_app_items[who];
			if(!had.is_object())
				had = json::object();
			m_server->emit_event("kit:items", new ItemsChanged(who,
					had.deepcopy(), mine.deepcopy(), false));
			had = mine;
			return;
		}
		send_items(who, mine);
	}

	// [KIT] stage 6a: the app's own inventory is the players' (Host::
	// app_items), unless a component replaces it
	bool app_items()
	{
		return m_host.app_items && !m_provider;
	}

	void set_items(const ss_ &player, const json::Value &items)
	{
		json::Value mine = json::object();
		if(items.is_object())
			for(json::Iterator it(items); it; ++it){
				const double n = (*it).is_number() ? (*it).as_number() : 0;
				if(name_ok(it.key()) && n >= 1 && n == std::floor(n))
					mine.set(it.key(), (int64_t)std::min<double>(n, MAX_ITEMS));
			}
		m_app_items[player] = mine;
	}

	// c:app(what, value) ([KIT] stage 6a): the app's own types' calls into
	// its native code, the event kit:app; another author's refused
	void app_call(const Entity &e, const ss_ &type, const ss_ &by,
			const ss_ &who, const json::Value &call)
	{
		const ss_ what = jstr_at(call, 0);
		if(type.compare(0, m_author.size() + 1, m_author+"/") != 0){
			log_w(MODULE, "Entity %s's %s: c:app(%s) refused: not one of the "
					"app's own types", cs(itos(e.id)), cs(type), cs(what));
			add_log(e.id, "app "+what+" refused: not one of the app's types");
			return;
		}
		AppCall *a = new AppCall();
		a->entity = e.id;
		a->type = type;
		a->what = what;
		a->value = call.at(1u).deepcopy();
		a->by = by;
		a->name = who;
		scene_of(e, &a->scene);
		a->has_pos = e.has_pos;
		a->x = e.pos[0], a->y = e.pos[1], a->z = e.pos[2];
		log_i(MODULE, "Entity %s's %s: app %s %s", cs(itos(e.id)), cs(type),
				cs(what), cs(a->value.stringify().substr(0, 64)));
		m_server->emit_event("kit:app", a);
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
		return allows(peer, "dig", x, y, z, nullptr);
	}

	uint64_t region_of(size_t peer, int x, int y, int z)
	{
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end())
			return 0;
		const Entity *re = nullptr;
		return region_at(pi->second.scene, x, y, z, &re) ? re->id : 0;
	}

	bool can_place(size_t peer, int x, int y, int z)
	{
		return allows(peer, "place", x, y, z, nullptr);
	}

	// ---- [KIT] stage 4j: regions

	// A region's extent: its state's size while a signal resized it, else
	// its parameter's
	void region_extent(const Instance &in, const Type &t, int n[3])
	{
		const json::Value &sz = in.state.get("size");
		extent(pos_ok(sz) ? sz : in.params.get(t.region), n);
	}

	// The region deciding a cell of a scene: the smallest enabled one
	// holding it (nullptr: none), and the entity it is on
	const Instance *region_at(const ss_ &scene, int x, int y, int z,
			const Entity **on)
	{
		const Instance *best = nullptr;
		int64_t best_v = 0;
		for(auto &p : m_entities){
			const Entity &e = p.second;
			if(!e.has_pos)
				continue;
			for(const Instance &in : e.comps){
				const Type &t = m_types[in.type];
				if(t.region.empty() || !in.disabled.empty() ||
						in.state.get("enabled").is_false())
					continue;
				int n[3];
				region_extent(in, t, n);
				const pv::Vector3DInt32 o = voxel_p(e);
				if(x < o.getX() || x >= o.getX() + n[0] || y < o.getY() ||
						y >= o.getY() + n[1] || z < o.getZ() ||
						z >= o.getZ() + n[2])
					continue;
				ss_ sc;
				scene_of(e, &sc);
				if(sc != scene)
					continue;
				const int64_t v = (int64_t)n[0] * n[1] * n[2];
				if(!best || v < best_v){
					best = &in;
					best_v = v;
					*on = &e;
				}
			}
		}
		return best;
	}

	// Whether the peer is among a region's owners: "nobody", "builders"
	// (edit rights), or names (a list, or a text of them)
	bool owns(size_t peer, const json::Value &owners)
	{
		const Peer &p = m_peers[peer];
		if(owners.is_string()){
			const ss_ o = owners.as_string();
			if(o == "nobody" || o.empty())
				return false;
			if(o == "builders")
				return can_edit(peer);
			ss_ name;
			for(size_t i = 0; i <= o.size(); i++){
				if(i == o.size() || o[i] == ',' || o[i] == ' '){
					if(!name.empty() && name == p.name)
						return true;
					name.clear();
				} else {
					name += o[i];
				}
			}
			return false;
		}
		for(unsigned i = 0; i < owners.size(); i++)
			if(owners.at(i).is_string() && owners.at(i).as_string() == p.name)
				return true;
		return false;
	}

	static const char *refusal(const ss_ &action)
	{
		return action == "dig" ? "Protected: no digging here" :
				action == "place" ? "Protected: no placing here" :
				action == "enter" ? "Protected: no entering here" :
				action == "pvp" ? "Protected: no fighting players here" :
				action == "damage" ? "Protected: no damage here" :
				action == "use" ? "Protected: no using things here" :
				"Protected";
	}

	// Whether a placed peer may do action ("dig", "place", "enter", "pvp",
	// "damage" or "use") at a cell of their scene, and why not. The region
	// holding it decides (the smallest): a component on its entity with an
	// allow handler first (true or false decides, nil leaves it), then its
	// rules, the owners' column or everyone else's. Outside every region
	// the World's default: digging and placing by a type's grants alone
	// (none: no), entering, pvp and damage yes. Edit mode is not in it
	bool allows(size_t peer, const ss_ &action, int x, int y, int z, ss_ *why)
	{
		auto pi = m_peers.find(peer);
		const bool build = action == "dig" || action == "place";
		// Stopped, the world is the start: only a builder changes it
		if(!m_hosted || pi == m_peers.end() || (build && !m_session.running)){
			if(why)
				*why = build ? "The server is not Running" : "Not here";
			return !build && pi != m_peers.end();
		}
		const Entity *re = nullptr;
		const Instance *rg = region_at(pi->second.scene, x, y, z, &re);
		if(!rg){
			if(!build)
				return true;
			if(granted(peer, action.c_str(), x, y, z))
				return true;
			if(why)
				*why = refusal(action);
			return false;
		}
		// The hook: the entity's allow handlers, by its player
		const uint64_t rid = re->id;
		const ss_ by = pi->second.player ? "player:"+itos(pi->second.player) :
				"app";
		for(size_t i = 0; m_session.running; i++){
			auto it = m_entities.find(rid);
			if(it == m_entities.end() || i >= it->second.comps.size())
				break;
			if(!m_types[it->second.comps[i].type].handlers.count("allow"))
				continue;
			Run r;
			r.entity = rid;
			r.comp = i;
			r.handler = "allow";
			r.by = by;
			r.args.append(by);
			r.args.append(action);
			json::Value pos = json::array();
			pos.append((int64_t)x);
			pos.append((int64_t)y);
			pos.append((int64_t)z);
			r.args.append(pos);
			run(r);
			if(m_ret.is_array() && m_ret.at(0u).is_boolean()){
				const bool yes = m_ret.at(0u).as_boolean();
				if(!yes && why)
					*why = m_ret.at(1u).is_string() && !m_ret.at(1u).
							as_string().empty() ? m_ret.at(1u).as_string().
							substr(0, 200) : refusal(action);
				return yes;
			}
		}
		// (the hook may have changed the tree: the region again)
		rg = region_at(pi->second.scene, x, y, z, &re);
		if(!rg){
			if(!build || granted(peer, action.c_str(), x, y, z))
				return true;
			if(why)
				*why = refusal(action);
			return false;
		}
		const json::Value &rule = rg->state.get("rules").get(action);
		const bool owner = owns(peer, rg->state.get("owners"));
		// Who may: "all", "owners", "others" or "none"
		const ss_ who = rule.is_string() ? rule.as_string() : "none";
		const bool yes = who == "all" || who == (owner ? "owners" : "others");
		if(!yes && why)
			*why = refusal(action);
		return yes;
	}

	// Who stands where they may not enter is put back where they last
	// could (while Running, by an app that moves its players), and told
	void check_regions()
	{
		if(!m_hosted || !m_session.running ||
				(!m_host.moves_players && !m_host.controls))
			return;
		const int64_t now = interface::os::time_us();
		for(auto &pp : m_peers){
			Peer &p = pp.second;
			if(!p.player)
				continue;
			int c[3];
			for(int k = 0; k < 3; k++)
				c[k] = (int)std::floor(p.pos[k] + 0.5);
			ss_ why;
			if(allows(pp.first, "enter", c[0], c[1], c[2], &why)){
				for(int k = 0; k < 3; k++)
					p.ok_pos[k] = p.pos[k];
				p.has_ok = true;
				continue;
			}
			if(!p.has_ok)
				continue;
			log_i(MODULE, "%s may not enter (%i,%i,%i): %s; put back",
					cs(p.name), c[0], c[1], c[2], cs(why));
			const size_t peer = pp.first;
			const double x = p.ok_pos[0], y = p.ok_pos[1], z = p.ok_pos[2];
			for(int k = 0; k < 3; k++)
				p.pos[k] = p.ok_pos[k];
			// (put_player()'s y is the body's + 0.45, a peer's pos its + 0.5:
			// the peer's y given as is lifted it 0.05 a put, and one walking
			// into the region rose into the air)
			if(m_host.controls)
				put_player(peer, x, y - 0.05, z);
			else
				m_server->emit_event("kit:move_player",
						new MovePlayer(peer, x, y, z));
			if(now - p.told_us > 1000000){
				p.told_us = now;
				tell(peer, why);
			}
		}
	}

	// A line shown to a peer ("kit:warning", a notification)
	void tell(size_t peer, const ss_ &text)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:warning", text);
		});
	}

	// [KIT_HM_FREE] How many of a heightmap's sections are loaded, logged
	// as it changes (a few ticks apart): only what was built and edited,
	// none round a player for walking
	void hm_sections_tick()
	{
		if(!m_w->hm_world || ++m_w->hm_ticks < 10)
			return;
		m_w->hm_ticks = 0;
		size_t n = 0;
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			n = w->get_loaded_sections().size();
		});
		if(n == m_w->hm_loaded)
			return;
		m_w->hm_loaded = n;
		log_i(MODULE, "World: %zu of the heightmap's voxel sections loaded",
				n);
	}

	// [KIT_HM_FREE] A heightmap's section an edit goes in: generated
	// (all air) if not loaded; false elsewhere or past the map
	// [KIT_SCENES] The World whose heightmap's voxels w is, null for none
	World *hm_world_of(voxelworld::Instance *w)
	{
		for(auto &x : m_worlds)
			if(w && x.second.hm_world == w)
				return &x.second;
		return nullptr;
	}

	bool hm_section(voxelworld::Instance *w, const pv::Vector3DInt32 &p)
	{
		if(!w || !hm_world_of(w) || loaded(w, p))
			return loaded(w, p);
		WorldScope ws(m_w, hm_world_of(w));
		// (the heightmap's samples: whole chunks of 64, apply_heightmap()'s)
		if(p.getX() < 0 || p.getZ() < 0 ||
				p.getX() >= (m_w->wp.width + 63) / 64 * 64 ||
				p.getZ() >= (m_w->wp.depth + 63) / 64 * 64)
			return false;
		const pv::Vector3DInt16 ss = w->get_section_size_voxels();
		auto div = [](int32_t a, int b){
			return (int16_t)std::floor((double)a / b);
		};
		const pv::Vector3DInt16 sp(div(p.getX(), ss.getX()),
				div(p.getY(), ss.getY()), div(p.getZ(), ss.getZ()));
		if(sp.getY() < WORLD_SECTION_Y0 || sp.getY() > WORLD_SECTION_Y1)
			return false;
		w->load_or_generate_section(sp);
		log_i(MODULE, "World: a heightmap's section (%i,%i,%i) generated "
				"for an edit", sp.getX(), sp.getY(), sp.getZ());
		return loaded(w, p);
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

	// [KIT_VOXEL_STATES] c:set_voxels(cells): {{x, y, z, name}...} in the
	// instance's voxel box (x, y, z from its first cell), MAX_SET_CELLS at
	// most, each a registered voxel's name; all written or, one refused,
	// none (logged)
	void set_voxels(const Entity &e, const Instance &in, const json::Value &vx,
			const ss_ &by, char origin)
	{
		pv::Vector3DInt32 o;
		int n[3];
		ss_ why;
		sv_<Write> ws;
		if(!voxel_box(e, in, o, n, &why)){
		} else if(vx.size() > (unsigned)MAX_SET_CELLS){
			why = itos(vx.size())+" cells, past "+itos(MAX_SET_CELLS);
		} else {
			std::set<ss_> names;
			for(unsigned i = 0; i < vx.size() && why.empty(); i++){
				const json::Value &c = vx.at(i);
				int q[3];
				for(unsigned k = 0; k < 3 && why.empty(); k++){
					const json::Value &v = c.at(k);
					if(!v.is_number() || v.as_number() != std::floor(v.as_number()) ||
							v.as_number() < 0 || v.as_number() >= n[k])
						why = "cell "+itos(i + 1)+" is not in its box";
					else
						q[k] = (int)v.as_number();
				}
				const ss_ name = jstr_at(c, 3);
				if(why.empty() && !voxel_name_ok(name))
					why = "cell "+itos(i + 1)+": a voxel's name";
				if(!why.empty())
					break;
				names.insert(name);
				Write w;
				w.scene = scene_of(e);
				w.p = o + pv::Vector3DInt32(q[0], q[1], q[2]);
				w.voxel = name;
				w.by = by;
				w.origin = origin;
				ws.push_back(w);
			}
			if(why.empty())
				voxelworld::access(m_server, scene_of(e),
						[&](voxelworld::Instance *w){
					for(const ss_ &nm : names){
						interface::VoxelName vn;
						vn.block_name = nm;
						if(!w->get_voxel_reg()->get(vn)){
							why = "no voxel "+nm;
							return;
						}
					}
				});
		}
		if(!why.empty()){
			log_w(MODULE, "Entity %s's %s: set_voxels refused: %s",
					cs(itos(e.id)), cs(in.type), cs(why));
			add_log(e.id, "set_voxels refused: "+why);
			return;
		}
		for(const Write &w : ws)
			if(!set_voxel(w))
				m_pending_voxels.push_back(w);
		log_i(MODULE, "Entity %s's %s set %zu cells", cs(itos(e.id)),
				cs(in.type), ws.size());
	}

	// A voxel an instance sets: false if its section is not loaded yet
	bool set_voxel(const Write &w)
	{
		bool done = true;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *world = ivw->get_instance(w.scene);
			if(!world)
				return;
			if(!hm_section(world, w.p)){
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

	// c:after(seconds, name, player): the instance's timer of that name and
	// player set (again), or taken back (seconds < 0); MAX_TIMERS at most
	void set_timer(const Entity &e, Instance &in, const ss_ &name,
			const ss_ &player, double s, const ss_ &by)
	{
		auto it = std::find_if(in.timers.begin(), in.timers.end(),
				[&](const Instance::Timer &t){
					return t.name == name && t.player == player; });
		m_runtime_dirty = true;
		if(!(s >= 0 && s < 1e7)){
			if(it != in.timers.end())
				in.timers.erase(it);
			return;
		}
		if(it == in.timers.end()){
			if(in.timers.size() >= MAX_TIMERS){
				log_w(MODULE, "Entity %s's %s: after: %i timers at most; "
						"\"%s\" not set", cs(itos(e.id)), cs(in.type),
						(int)MAX_TIMERS, cs(name));
				return;
			}
			in.timers.push_back(Instance::Timer());
			it = in.timers.end() - 1;
			it->name = name;
			it->player = player;
		}
		it->due_us = interface::os::game_us() + (int64_t)(s * 1e6);
		it->by = by;
	}

	// Timers due on the game's clock: on_timer(c, name, player), as by
	// whoever set it off
	void run_timers()
	{
		const int64_t now = interface::os::game_us();
		for(auto &p : m_entities)
			for(size_t i = 0; i < p.second.comps.size(); i++){
				Instance &in = p.second.comps[i];
				// In the order they are due; one set again in its own
				// on_timer waits for its next due
				sv_<Instance::Timer> due;
				for(size_t k = 0; k < in.timers.size();){
					if(now >= in.timers[k].due_us){
						due.push_back(in.timers[k]);
						in.timers.erase(in.timers.begin() + k);
					} else {
						k++;
					}
				}
				if(due.empty())
					continue;
				std::stable_sort(due.begin(), due.end(),
						[](const Instance::Timer &a, const Instance::Timer &b){
							return a.due_us < b.due_us; });
				m_runtime_dirty = true;
				for(const Instance::Timer &t : due){
					Run r;
					r.entity = p.first;
					r.comp = i;
					r.handler = "on_timer";
					r.by = t.by.empty() ? "app" : t.by;
					// on_timer(c, name, player): nil, nil for the unnamed
					// shared one, so a handler of before reads as it did
					r.args.append(t.name.empty() ? json::null() :
							json::Value(t.name));
					r.args.append(t.player.empty() ? json::null() :
							json::Value(t.player));
					queue_run(r);
				}
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
				// Who is in it, by their entity's id; those arriving on it
				// by a teleport enter it silently
				std::set<ss_> now, silent;
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
					auto ar = m_arrive.find(peer.name);
					if(inside && ar != m_arrive.end() &&
							ar->second.first == e.id){
						if(ar->second.second > interface::os::game_us())
							silent.insert(itos(peer.player));
						m_arrive.erase(ar);
					}
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
					if(!in.inside.count(id) && !silent.count(id))
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
		you.set("name", p.name);
		for(auto &t : m_types)
			if(!t.second.client.empty())
				parts.set(t.first, t.second.client);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:client_parts", parts.stringify());
			inetwork->send(peer, "kit:you", you.stringify());
		});
		send_sky((int64_t)peer);
		send_env(peer);
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
		take_vouches();
		for(auto &w : m_worlds){
			WorldScope ws(m_w, &w.second);
			sky_relight_tick();
			hm_sections_tick();
		}
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
		env_tick();
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
		check_regions();
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
		send_costs(budget);
	}

	// ---- Costs ([KIT] stage 4l): what each instance spent of the meter,
	// over COST_WINDOW_US, as a share of Kit's budget for that time (a
	// tick's budget times the ticks); sent to the builders ("kit:costs"
	// {"entities": {id: percent}, "types": {type: the average of its
	// instances}}): the inspector shows the selected entity's, the palette
	// an armed type's. simplified: the runs only, not a body's steps
	int64_t m_cost_since = 0;
	int64_t m_cost_budget = 0;
	json::Value m_costs = json::object();

	void send_costs(int64_t tick_budget)
	{
		const int64_t now = interface::os::time_us();
		if(!m_cost_since)
			m_cost_since = now;
		m_cost_budget += tick_budget;
		if(now - m_cost_since < COST_WINDOW_US)
			return;
		const double whole = (double)std::max<int64_t>(1, m_cost_budget);
		m_cost_since = now;
		m_cost_budget = 0;
		json::Value ents = json::object(), types = json::object();
		std::map<ss_, std::pair<double, int>> by_type;
		for(auto &p : m_entities){
			double sum = 0;
			for(Instance &in : p.second.comps){
				const double pct = 100.0 * in.spent / whole;
				in.spent = 0;
				sum += pct;
				auto &bt = by_type[in.type];
				bt.first += pct;
				bt.second++;
			}
			if(sum > 0)
				ents.set(itos(p.first), std::round(sum * 1000) / 1000);
		}
		for(auto &t : by_type)
			types.set(t.first, std::round(t.second.first / t.second.second *
					1000) / 1000);
		m_costs = json::object();
		m_costs.set("entities", ents);
		m_costs.set("types", types);
		const ss_ data = m_costs.stringify();
		for(auto &p : m_peers){
			if(!p.second.editing)
				continue;
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(p.first, "kit:costs", data);
			});
		}
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
	void body_movement(Body &b, ss_ &type, json::Value &params,
			const ss_ &scene)
	{
		body_movement_of(b, type, params);
		// [KIT_ENVIRONMENT] the scene's gravity, times the movement's own
		const json::Value &g = params.get("gravity");
		const double f = env_gravity(scene);
		if(g.is_number() && f != 1)
			params.set("gravity", g.as_number() * f);
	}

	void body_movement_of(Body &b, ss_ &type, json::Value &params)
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

	// The voxels' friction and surface ([KIT] stage 4g's properties: Kit's
	// set's and the builders' types), those other than friction 1 and no
	// surface
	json::Value voxel_extra()
	{
		json::Value out = json::object();
		for(auto &r : m_registered){
			const world::Material &m = r.second;
			if(m.friction == 1 && m.surface.empty())
				continue;
			json::Value e = json::object();
			e.set("friction", m.friction);
			if(!m.surface.empty())
				e.set("surface", m.surface);
			out.set(r.first, e);
		}
		return out;
	}

	// What a peer's client controls with: the camera, the pointer, the
	// effects and the signals for them, the movement (its source, its
	// parameters, its body) and the seat
	json::Value controls_for(size_t peer)
	{
		WorldScope ws(m_w, world_of_peer(peer));
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
		if(m_w->world_scene && m_w->wp.heightmap() && pe.scene == m_host.world_scene)
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_w->world_scene);
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
	// look: the view's yaw set too, level (NaN: the view kept)
	void put_body(size_t peer, Body &b, double x, double y, double z,
			double yaw = 0, const json::Value *state = nullptr,
			double look = NAN)
	{
		body_movement(b, b.type, b.params, m_peers[peer].scene);
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
					itos(b.ack)+(std::isnan(look) ? ss_() :
					",\"look\":"+json::Value(look).stringify())+
					",\"s\":"+b.state_json+"}");
		});
	}

	void put_player(size_t peer, double x, double y, double z,
			double look = NAN) override
	{
		if(!m_host.controls || !m_peers.count(peer))
			return;
		Body &b = m_bodies[peer];
		if(b.seat)
			unseat(peer, b, false);
		log_i(MODULE, "%s put at (%g, %g, %g)", cs(m_peers[peer].name), x, y,
				z);
		put_body(peer, b, x, y, z, std::isnan(look) ? 0 : look, nullptr, look);
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
		WorldScope ws(m_w, world_named(pe.scene));
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
					const uint32_t word = vol.getVoxelAt(x0 + x, y0 + y,
							z0 + z).data;
					const uint32_t id = (uint32_t)fmt.id.get(word);
					// [KIT_VOXEL_FORMAT] a shape's class is its facing's too
					const uint32_t key = id | (fmt.param.bound() ?
							(fmt.param.get(word) & 0xff) << 16 : 0);
					char ch = '.';
					if(id == interface::VOXELTYPEID_UNDEFINED){
						ch = '?';
					} else {
						auto c = cls.find(key);
						if(c != cls.end()){
							ch = c->second;
						} else {
							const interface::VoxelDefinition *def = reg->get(id);
							if(def && def->physically_solid && classes.size() < 190){
								const ss_ name = def->name.block_name;
								json::Value k = json::array();
								k.append(name);
								k.append(true);
								const json::Value &x = extra.get(
										world::material_of(name));
								k.append(x.get("friction").is_number() ?
										x.get("friction") : json::Value(1.0));
								k.append(jstr(x, "surface"));
								// Its boxes (the cell's -0.5...0.5), a
								// shape's by its param's variant
								const sv_<float> *bx = &def->collision_boxes;
								if(!def->variants.empty()){
									const size_t vi = def->variant_of_param[
											(key >> 16) & 0xff];
									if(vi < def->variants.size() &&
											!def->variants[vi].collision_boxes.empty())
										bx = &def->variants[vi].collision_boxes;
								}
								if(!bx->empty()){
									json::Value b = json::array();
									for(float f : *bx)
										b.append((double)f);
									k.append(b);
								}
								classes.append(k);
								ch = (char)(64 + classes.size());
							}
							cls[key] = ch;
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
		if(m_w->world_scene && m_w->wp.heightmap() && scene == m_w->world_scene)
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_w->world_scene);
				if(!map)
					return;
				const int hx0 = std::max(0, x0), hz0 = std::max(0, z0);
				const int hx1 = std::min(map->samples_x() - 1, x0 + nx),
						hz1 = std::min(map->samples_z() - 1, z0 + nz);
				if(hx1 < hx0 || hz1 < hz0)
					return;
				// [KIT_HM_FREE] the map's size: its edge is a wall
				o += ",hm={sx="+itos(map->samples_x())+",sz="+
						itos(map->samples_z())+",x0="+itos(hx0)+",z0="+
						itos(hz0)+",nx="+
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
			if(!b.put || pi == m_peers.end())
				continue;
			// An edit changed the movement or its parameters: put again where
			// it is, so the client steps on with the same
			ss_ type;
			json::Value params;
			body_movement(b, type, params, pi->second.scene);
			if(type != b.type || params.stringify() != b.params.stringify()){
				if(type == b.type && !type.empty()){
					const json::Value &g = params.get("gravity");
					log_i(MODULE, "%s's movement %s changed: gravity %s",
							cs(pi->second.name), cs(type), cs(g.is_number() ?
							std::to_string(g.as_number()) : ss_("-")));
				}
				const json::Value st = b.state.deepcopy();
				put_body(bp.first, b, 0, 0, 0, 0, &st);
			}
			if(b.type.empty())
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
	// What a use reaches on it: an on_use, or a seat ([KIT] stage 4h)
	bool use_kind(const Instance &in)
	{
		const Type &ty = m_types[in.type];
		return ty.usable && (ty.handlers.count("on_use") || (m_host.controls &&
				ty.decl.get("seat").is_true() && is_movement(in.type)));
	}

	// [KIT_USE_ACCESS] Whether a placed peer may use an instance by its
	// use parameter, and why not: all (or none set), owners or nobody.
	// simplified: owners are the owners of the region deciding its cell
	// (kit/region's owner: nobody, the builders or named players, a
	// set_owner's capture), none outside every region; an owner of its
	// own (a name per object) when one is asked for
	bool may_use(size_t peer, const Entity &e, const Instance &in, ss_ *why)
	{
		const ss_ use = jstr(in.params, "use");
		if(use == "nobody"){
			*why = "Locked: used through its links only";
			return false;
		}
		if(use != "owners")
			return true;
		const pv::Vector3DInt32 c = voxel_p(e);
		const Entity *re = nullptr;
		ss_ scene;
		scene_of(e, &scene);
		const Instance *rg = region_at(scene, c.getX(), c.getY(), c.getZ(),
				&re);
		if(rg && owns(peer, rg->state.get("owners")))
			return true;
		*why = "Locked: its owners' only";
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
			return refuse("the server is Ended");
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
		// [KIT_USE_ACCESS] The region's use rule for the player first (its
		// allow hook may run and change the tree: the entity again), then
		// each part's own use; a refusal told
		ss_ why;
		const pv::Vector3DInt32 c = voxel_p(e);
		if(!allows(peer, "use", c.getX(), c.getY(), c.getZ(), &why)){
			tell(peer, why);
			return refuse(why);
		}
		it = m_entities.find(id);
		if(it == m_entities.end() || m_peers.find(peer) == m_peers.end())
			return refuse("no such object");
		Entity &e2 = it->second;
		const ss_ by = by_of(m_peers[peer].name);
		bool any = false, seated = false;
		for(size_t i = 0; i < e2.comps.size(); i++){
			const Instance &in = e2.comps[i];
			if(!use_kind(in))
				continue;
			if(!may_use(peer, e2, in, &why))
				continue;
			// [KIT] stage 4h: a seat taken
			if(!seated && m_host.controls && m_types[in.type].decl.get("seat").
					is_true() && is_movement(in.type) && m_bodies[peer].put &&
					m_bodies[peer].seat != id){
				seat(peer, id);
				seated = any = true;
			}
			if(!m_types[in.type].handlers.count("on_use"))
				continue;
			any = true;
			Run r;
			r.entity = id;
			r.comp = i;
			r.handler = "on_use";
			r.by = by;
			r.args.append(r.by);
			queue_run(r);
		}
		if(!any && !why.empty()){
			tell(peer, why);
			return refuse(why);
		}
		if(!any)
			return refuse("nothing on it is usable");
		log_i(MODULE, "Entity %s used by %s", cs(itos(id)),
				cs(m_peers[peer].name));
	}

	void on_joined(const network::NewClient &nc)
	{
		const ss_ &a = nc.info.address;
		ss_ host = a, port;
		interface::split_host_port(a, &host, &port, "0");
		if(!nc.info.web && interface::aitta::public_address(host, true) &&
				!interface::aitta::public_address(host, false))
			m_local_peers.insert(nc.info.id);
	}

	void on_left(const network::OldClient &old)
	{
		m_local_peers.erase(old.info.id);
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
		for(auto &w : m_worlds)
			if(w.second.world_peers.erase(old.info.id)){
				WorldScope ws(m_w, &w.second);
				world_load_points();
			}
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
		const bool moved_scene = !p.scene.empty() && p.scene != scene;
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
		// [KIT_ENVIRONMENT] The new scene's environment and season
		if(moved_scene && m_hosted)
			send_env(peer);
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

	// [KIT_BUILDER_PLAY_RULES] In edit mode now (api.h)
	bool is_editing(size_t peer)
	{
		auto pi = m_peers.find(peer);
		return pi != m_peers.end() && pi->second.editing && can_edit(peer);
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

	// [KIT_VOXEL_FORMAT] A voxel's state where its section is loaded: its
	// word less its light (id, param, tint), what undo, the round's copies
	// and the marks keep, so a shape's facing and a tint survive them
	static uint32_t state_mask(const interface::VoxelFormat &f)
	{
		uint32_t m = 0;
		f.id.set(m, 0xffffffff);
		if(f.param.bound() && f.param.plane == f.id.plane)
			f.param.set(m, 0xffffffff);
		if(f.tint.bound() && f.tint.plane == f.id.plane)
			f.tint.set(m, 0xffffffff);
		return m;
	}

	// (A heightmap's cell not loaded: 0, never written, air)
	bool voxel_id(voxelworld::Instance *w, const pv::Vector3DInt32 &p,
			uint32_t &id)
	{
		if(!loaded(w, p)){
			if(!w || !hm_world_of(w))
				return false;
			id = 0;
			return true;
		}
		const interface::VoxelFormat &f = w->get_voxel_reg()->get_format();
		id = w->get_voxel(p, true).data & state_mask(f);
		return true;
	}

	// The type id alone of a state voxel_id() gave
	static uint32_t type_of(voxelworld::Instance *w, uint32_t state)
	{
		return w->get_voxel_reg()->get_format().id.get(state);
	}

	static void set_id(voxelworld::Instance *w, const pv::Vector3DInt32 &p,
			uint32_t state)
	{
		w->set_voxel(p, interface::VoxelInstance(
				state & state_mask(w->get_voxel_reg()->get_format())));
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
	// build's mark there goes: the game wrote last; an edit's stays, and
	// one under the build is the mark again), 'b' a build by `who` (kept as
	// made with "Always keep builds"; over an edit, the edit kept under
	// it), 'k' kept as made. Running only: Stopped, every write is the
	// start's
	void mark(voxelworld::Instance *w, main_context::SceneReference ref,
			const pv::Vector3DInt32 &p, char origin, const ss_ &who)
	{
		if(!m_session.running || m_host.persistent)
			return;
		const ss_ scene = scene_name(ref);
		if(scene.empty())
			return;
		const ss_ key = section_key(scene, w, p);
		const auto c = std::make_tuple(p.getX(), p.getY(), p.getZ());
		auto si = m_marks.find(key);
		Mark *old = nullptr;
		if(si != m_marks.end()){
			auto ci = si->second.find(c);
			if(ci != si->second.end())
				old = &ci->second;
		}
		if(origin == 'g' || who.empty()){
			if(!old || old->kind == 'k')
				return;
			if(old->under_by.empty()){
				si->second.erase(c);
			} else {
				old->kind = 'k';
				old->by = old->under_by;
				old->id = old->under_id;
				old->under_by.clear();
				old->under_id = 0;
			}
			m_marks_dirty.insert(key);
			return;
		}
		Mark m;
		if(!voxel_id(w, p, m.id))
			return;
		m.kind = origin == 'k' || always_keep() ? 'k' : 'b';
		m.by = who;
		if(m.kind == 'b' && old){
			m.under_by = old->kind == 'k' ? old->by : old->under_by;
			m.under_id = old->kind == 'k' ? old->id : old->under_id;
		}
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
					if(!c.second.under_by.empty()){
						a.append(c.second.under_by);
						a.append((int64_t)c.second.under_id);
					}
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
				if(m.kind == 'b' && (*it).at(3u).is_string() &&
						(*it).at(4u).is_number()){
					m.under_by = (*it).at(3u).as_string();
					m.under_id = (uint32_t)(*it).at(4u).as_number();
				}
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
				if(!hm_section(w, p)){
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

	// At Stop, before the copies are put back: each edit ('k') as it was
	// made, into `kept`, and each build whose voxel is still what its mark
	// gave (else the game wrote it last) into m_discarded, the edit under
	// it into `kept`. The marks go
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
					if(!w)
						continue;
					if(c.second.kind == 'k'){
						d.id = c.second.id;
						kept.push_back(d);
						continue;
					}
					if(voxel_id(w, pv::Vector3DInt32(d.p[0], d.p[1],
							d.p[2]), d.id) && d.id == c.second.id)
						m_discarded.push_back(d);
					if(!c.second.under_by.empty()){
						d.by = c.second.under_by;
						d.id = c.second.under_id;
						kept.push_back(d);
					}
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
			return refuse("the server is Running: End discards and keeps");
		if(m_discarded.empty())
			return refuse("no builds discarded since the last Run");
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
	// every section copied again at its next write), or off. Never on in
	// a persistent world: nothing to put back
	void watch(bool on)
	{
		on = on && !m_host.persistent;
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
					wt->copied = m_session.copied;
					wt->copied.insert(m_session.restore.begin(),
							m_session.restore.end());
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
	// [KIT_ROUND_START] A generator's merge into a copied section is made
	// into the copy too, in the queue's order (after the copy)
	void flush_copies()
	{
		std::deque<Copy> copies;
		{
			std::lock_guard<std::mutex> lock(m_copies_mutex);
			copies.swap(m_copies);
		}
		if(copies.empty() || !m_session.running)
			return;
		size_t n = 0, merges = 0;
		// The copies this flush stores, as data or, merged into, read
		sm_<ss_, ss_> out;
		sm_<ss_, up_<interface::VoxelVolume>> read;
		for(Copy &c : copies){
			if(!c.merge){
				if(m_session.copied.insert(c.key).second){
					out[c.key] = std::move(c.data);
					n++;
				}
				continue;
			}
			if(!m_session.copied.count(c.key) &&
					!m_session.restore.count(c.key))
				continue;
			up_<interface::VoxelVolume> &v = read[c.key];
			if(!v){
				ss_ data;
				auto it = out.find(c.key);
				if(it != out.end())
					data = it->second;
				else if(!m_store->get(c.key, data))
					continue;
				v = interface::deserialize_volume(data);
				if(!v)
					continue;
			}
			main_context::SceneReference scene = nullptr;
			pv::Vector3DInt16 sp;
			if(!parse_copy(c.key, scene, sp))
				continue;
			voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
				voxelworld::Instance *w = ivw->get_instance(scene);
				if(w)
					w->merge_into_volume(*v, *c.merge,
							c.has_owned ? &c.owned : nullptr, c.keep_standing);
			});
			merges++;
		}
		for(auto &r : read)
			if(r.second)
				out[r.first] = interface::serialize_volume_compressed(
						*r.second);
		m_store->batch([&](){
			for(auto &o : out)
				m_store->set(o.first, o.second);
		});
		if(n)
			log_i(MODULE, "%zu sections copied out (%zu this round)", n,
					m_session.copied.size());
		if(merges)
			log_i(MODULE, "%zu generator merges made into the copies", merges);
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
		in.timers.clear();
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
			// The app's inventory reset at Play only: one who joins a
			// round has the app's own, as the app keeps it
			if(app_items() && !keep_inventory && at_play)
				m_server->emit_event("kit:items", new ItemsChanged(name,
						json::object(), json::object(), true));
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
		if(!m_hosted || m_host.persistent)
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
		WorldScope ws(m_w, world_of_peer(peer));
		auto pi = m_peers.find(peer);
		json::Value j = json::object();
		const bool editing = pi != m_peers.end() && pi->second.editing;
		j.set("editing", editing);
		j.set("can_edit", can_edit(peer));
		j.set("running", m_session.running);
		j.set("by", m_session.by);
		j.set("persistent", m_host.persistent);
		// The builds the last Stop discarded, until the next Play, and
		// whether builds are always kept
		j.set("discarded", discarded_counts());
		j.set("always_keep", always_keep());
		// [KIT_SCENES] The composition's scenes and theirs, and whether
		// new ones can be made
		json::Value scenes = json::array();
		for(auto &e : m_entities)
			if(e.second.kind == "scene")
				scenes.append(e.second.name);
		j.set("scenes", scenes);
		j.set("scene", pi != m_peers.end() ? pi->second.scene : ss_());
		j.set("can_make_scenes", (bool)m_host.make_scene);
		// [KIT] stage 5: the credits, everyone's
		j.set("credits", credits());
		if(editing){
			// The installed packages' versions, by name
			json::Value pk = json::object();
			// [AITTA_KEY_IDENTITY] and each package's thing ("<fp>/<n>")
			// as people read it, by name
			json::Value shown_as = json::object();
			for(auto &k : m_packages){
				pk.set(k.first, jstr(k.second, "version"));
				shown_as.set(k.first, package_label(k.first));
				for(const char *what : {"prefabs", "voxels"}){
					const json::Value &l = k.second.get(what);
					for(unsigned i = 0; l.is_array() && i < l.size(); i++)
						shown_as.set(l.at(i).as_string(),
								shown(l.at(i).as_string()));
				}
				const json::Value &ts = k.second.get("types");
				for(json::Iterator it(ts); ts.is_object() && it; ++it){
					const ss_ t = k.first.substr(0, k.first.find('/'))+"/"+
							it.key();
					shown_as.set(t, shown(t));
				}
			}
			j.set("packages", pk);
			j.set("names", shown_as);
			json::Value pal = json::object();
			for(const ss_ &t : m_palette){
				const json::Value &d = m_types[t].decl;
				json::Value o = json::object();
				for(const char *k : {"params", "inputs", "outputs", "gizmo",
						"usable", "zone", "volume", "grants", "region", "voxel_box", "version",
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
							"zone", "volume", "grants", "region", "voxel_box", "version", "inventory",
							"root", "inputs_types", "outputs_types", "player"})
						if(!t.second.decl.get(k).is_undefined())
							o.set(k, t.second.decl.get(k));
					types.set(t.first, o);
				}
			// [KIT] stage 4h: the controls, the movements and the seats
			// after the objects
			json::Value names = json::array();
			for(int last = 0; last < 2; last++)
				for(const ss_ &t : m_palette){
					const json::Value &d = m_types[t].decl;
					if((d.get("controls").is_true() ||
							d.get("movement").is_object()) == (last == 1))
						names.append(t);
				}
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
			// [KIT_PREFAB_VOXELS] the builder's copy: its entities and
			// its box's size ([0, 0, 0]: none), from its base
			auto ci = m_clipboard.find(pi->second.name);
			if(ci != m_clipboard.end()){
				json::Value cb = json::object();
				cb.set("entities", (int64_t)ci->second.get("entities").size());
				const json::Value &v = ci->second.get("voxels");
				cb.set("size", v.is_object() ? v.get("size") :
						json::load_string("[0, 0, 0]"));
				if(v.is_object())
					cb.set("at", v.get("at"));
				j.set("clipboard", cb);
			}
			// [KIT] stage 4g: the voxels to place and the textures a
			// builder's type may wear
			j.set("voxels", voxel_palette());
			json::Value ts = json::array();
			for(const ss_ &t : texture_choices())
				ts.append(t);
			j.set("textures", ts);
			// [KIT] stage 4f: what the terrain brushes choose from
			if(m_w->world_scene){
				json::Value t = json::object(), bs = json::array();
				for(auto &b : m_materials.biomes)
					bs.append(b.first);
				t.set("biomes", bs);
				t.set("biome", m_w->wp.biome);
				t.set("surface", ss_(m_w->wp.heightmap() ? "heightmap" : "voxels"));
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
		// [KIT_SCENES] The World of the scene the editor is in
		WorldScope ws(m_w, world_named(p.scene));
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
		// In play too: it reads
		if(op == "voxel_info")
			return voxel_info(p, j, refuse);
		if(op == "mode"){
			tools(p, peer, j.get("on").is_true());
			log_i(MODULE, "%s %s edit mode", cs(p.name),
					p.editing ? "is in" : "left");
			send_state(peer);
			send_builders();
			return;
		}
		// The server's state: a builder's, the tools on or not
		if(m_host.persistent && (op == "play" || op == "stop" ||
				op == "save_start" || op == "keep" || op == "always_keep"))
			return refuse("the world is persistent: no rounds");
		if(op == "play" || op == "stop" || op == "save_start"){
			if(op == "play" && m_session.running)
				return refuse("the server is Running");
			if(op != "play" && !m_session.running)
				return refuse("the server is Ended");
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
		if(op == "scene")
			return switch_scene(p, peer, j, refuse);
		if(op == "terrain")
			return terrain(p, peer, j, refuse);
		if(op == "voxel")
			return make_voxel(p, j, refuse);
		if(op == "set_voxel")
			return edit_voxel(p, peer, j, refuse);
		if(op == "edited")
			return send_edited(peer);
		if(op == "regenerate")
			return regenerate_sections(p, peer, j, refuse);
		if(op == "try")
			return try_input(p, peer, j, refuse);
		if(op == "pattern")
			return pattern_op(p, peer, j, refuse);
		if(op == "copy")
			return copy_op(p, peer, j, refuse);
		if(op == "export")
			return export_package(peer, p, refuse);
		if(op == "restart"){
			Entity *e = nullptr;
			ss_ why;
			Instance *in = instance_arg(j, e, why);
			if(!in)
				return refuse(why);
			if(!m_session.running)
				return refuse("the server is Ended: it is at its start");
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
			// A regeneration's: once its sections are there again
			bool back = true;
			if(!u.back().regen.empty())
				voxelworld::access(m_server, m_w->world_scene,
						[&](voxelworld::Instance *w){
					for(const pv::Vector3DInt16 &s : u.back().regen)
						back = back && w->is_section_loaded(s) &&
								w->is_section_generated(s);
				});
			if(!back)
				return refuse("the regenerated sections are not generated "
						"again yet");
			const Change c = u.back();
			u.pop_back();
			if(c.stroke != -1 && c.stroke != -3){
				undo_terrain(c, p);
				send_state(peer);
				return;
			}
			// [KIT_PREFAB_VOXELS] a prefab's place: its voxels too
			if(c.stroke == -3)
				undo_terrain(c, p);
			commit(c.before, nullptr);
			log_i(MODULE, "An undo by %s: %zu entities put back (%zu more "
					"to undo)", cs(p.name), c.before.size(), u.size());
			world_check(p.name);
			return;
		}
		m_paste.set = false;
		if(!build_change(op, j, p, change, what, why)){
			m_paste.set = false;
			return refuse(why);
		}
		two_way_returns(change, what);
		std::deque<Change> &u = m_undo[p.name];
		commit(change, &u);
		// [KIT_PREFAB_VOXELS] a place's voxels, with its entities one undo
		if(m_paste.set){
			m_paste.set = false;
			auto si = m_host.scenes.find(p.scene);
			Change &nc = u.back();
			nc.stroke = -3;
			nc.scene = si->second;
			size_t written = 0, missing = 0, unknown = 0;
			write_voxels(m_paste.vox, nc.scene, m_paste.base, m_paste.turn,
					nc, p.name, written, missing, unknown);
			what += ", "+itos(written)+" voxels written"+(missing ? ", "+
					itos(missing)+" not loaded" : ss_())+(unknown ? ", "+
					itos(unknown)+" of voxels the scene has not" : ss_());
		}
		log_i(MODULE, "An edit by %s: %s", cs(p.name), cs(what));
		world_check(p.name);
		// [KIT_SCENES] a new scene: its World, and its maker taken there
		if(op == "new_scene"){
			const ss_ name = jstr(j, "name");
			ss_ hwhy;
			if(!m_worlds.count(name) && !m_host.world_scene.empty() &&
					!host_world_of(name, hwhy))
				warn("scene "+name+": "+hwhy);
			go_to_scene(p, peer, name);
		}
	}

	// [KIT_SCENES] A two-way teleporter in a change, onto an entity: that
	// entity teleports back (a teleporter put on it, or its own one with no
	// target given this one), in the same undo
	void two_way_returns(sv_<std::pair<uint64_t, json::Value>> &change,
			ss_ &what)
	{
		const size_t n = change.size();
		for(size_t ci = 0; ci < n; ci++){
			const uint64_t id = change[ci].first;
			if(!change[ci].second.is_object())
				continue;
			Entity e;
			ss_ why;
			if(!entity_from_json(change[ci].second, e, why))
				continue;
			for(const Instance &in : e.comps){
				const json::Value &tv = in.params.get("target");
				if(in.type != "kit/teleporter" ||
						!in.params.get("two_way").is_true() ||
						!tv.is_number() || tv.as_number() < 2)
					continue;
				const uint64_t tid = (uint64_t)tv.as_number();
				auto ti = m_entities.find(tid);
				bool in_change = false;
				for(auto &c : change)
					in_change = in_change || c.first == tid;
				if(tid == id || in_change || ti == m_entities.end() ||
						!ti->second.has_pos || !ti->second.kind.empty())
					continue;
				Entity t = ti->second;
				Instance *back = nullptr;
				for(Instance &ti2 : t.comps)
					if(ti2.type == "kit/teleporter")
						back = &ti2;
				if(back){
					const json::Value &bt = back->params.get("target");
					if((bt.is_number() && bt.as_number() != 0) ||
							jstr(back->params, "scene") != "")
						continue;
					back->params.set("target", (int64_t)id);
				} else {
					Instance r = in;
					r.links.clear();
					r.overrides.clear();
					r.params = in.params.deepcopy();
					r.params.set("target", (int64_t)id);
					r.params.set("two_way", false);
					r.params.set("scene", "");
					t.comps.push_back(r);
				}
				change.push_back(std::make_pair(tid, entity_json(t)));
				what += ", a teleporter back on entity "+itos(tid);
			}
		}
	}

	// [KIT_SCENES] A scene of the composition, a name of letters, digits
	// and _: its entity, and its World the current scene's copied ("copy")
	// or the World type's defaults (the app's); the app makes it
	// (Host::make_scene). simplified: an undo takes the entities back, the
	// app's scene stays (empty, unused)
	bool new_scene_change(const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what,
			ss_ &why)
	{
		const ss_ name = jstr(j, "name");
		if(!m_host.make_scene){
			why = "the app makes no scenes";
			return false;
		}
		if(name.empty() || name.size() > 32 || !name_ok(name)){
			why = "a scene's name is 1 to 32 letters, digits and _";
			return false;
		}
		if(scene_id(name)){
			why = "there is a scene "+name+" already";
			return false;
		}
		if(!m_host.scenes.count(name) && !make_scene(name, why))
			return false;
		const uint64_t sid = m_next_id++;
		json::Value e = json::object();
		e.set("id", (int64_t)sid);
		e.set("parent", (int64_t)1);
		e.set("name", name);
		e.set("kind", "scene");
		change.push_back(std::make_pair(sid, e));
		what = "made the scene "+name;
		if(!j.get("copy").is_true() || m_host.world_scene.empty())
			return true;
		// The current scene's World entity, copied
		const uint64_t cur = scene_id(p.scene);
		for(auto &pe : m_entities){
			const Entity &we = pe.second;
			if(!cur || we.parent != cur || we.has_pos)
				continue;
			bool is_world = false;
			for(const Instance &i : we.comps)
				is_world = is_world || (m_types.count(i.type) &&
						m_types[i.type].world);
			if(!is_world)
				continue;
			Entity c = we;
			c.id = m_next_id++;
			c.parent = sid;
			c.prefab = json::Value();
			for(Instance &i : c.comps)
				i.links.clear();
			change.push_back(std::make_pair(c.id, entity_json(c)));
			what += ", its World "+p.scene+"'s copied";
			break;
		}
		return true;
	}

	// [KIT_SCENES] Where each player last was in each scene, by name and
	// scene: a builder going back to one comes back there
	std::map<std::pair<ss_, ss_>, std::array<double, 3>> m_scene_pos;

	// A builder to another scene of the composition: where they last were
	// in it, else its World's spawn
	void go_to_scene(Peer &p, size_t peer, const ss_ &name)
	{
		m_scene_pos[std::make_pair(p.name, p.scene)] =
				{{p.pos[0], p.pos[1], p.pos[2]}};
		auto it = m_scene_pos.find(std::make_pair(p.name, name));
		double x = 0.5, y = 1, z = 0.5;
		if(it != m_scene_pos.end()){
			x = it->second[0];
			y = it->second[1];
			z = it->second[2];
		} else {
			scene_spawn(name, x, y, z);
		}
		to_scene(peer, name, x, y, z);
	}

	// A player put at x, y, z of a scene: their own, put now; another,
	// by the app (kit:change_scene)
	void to_scene(size_t peer, const ss_ &scene, double x, double y,
			double z, double look = NAN)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return;
		if(scene.empty() || scene == pi->second.scene){
			if(m_host.controls)
				put_player(peer, x, y, z, look);
			else
				m_server->emit_event("kit:move_player",
						new MovePlayer(peer, x, y, z, look));
			return;
		}
		log_i(MODULE, "%s goes to the scene %s at (%g, %g, %g)",
				cs(pi->second.name), cs(scene), x, y, z);
		m_server->emit_event("kit:change_scene",
				new ChangeScene(peer, scene, x, y, z, look));
	}

	void switch_scene(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const ss_ name = jstr(j, "name");
		if(!scene_id(name) || !m_host.scenes.count(name))
			return refuse("no scene "+name.substr(0, 64));
		if(name == p.scene)
			return refuse("already in the scene "+name);
		if(!m_host.make_scene)
			return refuse("the app moves no one between scenes");
		go_to_scene(p, peer, name);
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
					"it; it is back at End)" : "");
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
		if(op == "place" && (!j.get("prefab").is_undefined() ||
				j.get("clipboard").is_true()))
			return place_prefab(j, p, change, what, why);
		if(op == "new_scene")
			return new_scene_change(j, p, change, what, why);
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
			// type (root) on the app root, no position. [KIT_SCENES] A
			// World on the scene itself, no position (each scene's own),
			// and a root type asked "on": "scene" (an environment of the
			// scene's own)
			// [KIT_ENVIRONMENT] an environment on the root, the scene's
			// own once the root has one
			const bool on_scene = m_types[type].world ||
					(m_types[type].root && jstr(j, "on") == "scene") ||
					(m_types[type].environment && jstr(j, "on") != "root" &&
					env_at(1));
			const bool root = m_types[type].root;
			uint64_t scene = 0;
			for(auto &e : m_entities)
				if(e.second.kind == "scene" && e.second.name == p.scene)
					scene = e.first;
			if(!scene && (!root || on_scene)){
				why = "the editor is in no scene of the composition's";
				return false;
			}
			const uint64_t id = m_next_id++;
			json::Value e = json::object();
			e.set("id", (int64_t)id);
			e.set("parent", (int64_t)(on_scene ? scene : root ? 1 : scene));
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
			what = "placed "+type+" "+itos(id)+(on_scene ? " on the scene "+
					p.scene : root ? ss_(" on the app root") :
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
		// [KIT] stage 4l {"op": "link_visible", "id", "output", "to", "input",
		// "visible": bool}
		if(op == "link_visible"){
			Entity *e = nullptr;
			Instance *in = instance_arg(j, e, why);
			if(!in)
				return false;
			const ss_ output = jstr(j, "output"), input = jstr(j, "input");
			const uint64_t to = (uint64_t)json::jint(j, "to", 0);
			const bool vis = j.get("visible").is_boolean() &&
					j.get("visible").as_boolean();
			const size_t ci = in - &e->comps[0];
			Entity copy = *e;
			bool found = false;
			for(Link &l : copy.comps[ci].links)
				if(l.output == output && l.to == to && l.input == input){
					l.visible = vis;
					found = true;
				}
			if(!found){
				why = "no such link";
				return false;
			}
			change.push_back(std::make_pair(e->id, entity_json(copy)));
			what = ss_(vis ? "showed " : "hid ")+itos(e->id)+"."+output+
					" -> "+itos(to)+"."+input+" in play";
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
				in.timers = was.timers;
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
