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
#include "kit/symmetry.h"
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
#include <future>
#include <algorithm>
#include <random>
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
// [KIT_INPUT_ACTIONS] The actions a type declares, the actions in the
// world at once (the clients' key store's room), a client's acts a
// second (kit:action, kit:use and kit:exit together; [KIT_USE_FLOOD])
// and their burst, and how often "held" comes
static const size_t MAX_TYPE_ACTIONS = 8, MAX_ACTIONS = 16;
static const double ACTION_RATE = 20, ACTION_BURST = 40;
// A builder's generator builds: their allowance in calls' budgets (a
// build costs what its run spent, BUILD_MIN at least), BUILD_RATE a second
// coming back up to BUILD_BURST; an edit that would build with less is
// refused. simplified: a refusal, not a build deferred; the allowance a
// peer's, not a name's (a reconnect starts it full; a slow way round it)
static const double BUILD_RATE = 0.2, BUILD_BURST = 1, BUILD_MIN = 0.05;
static const int64_t HELD_EVERY_US = 100000;
static const size_t MAX_TYPE_SOURCE = 256 << 10;
// A zone's or an owned volume's extent in cells, each way, and the cells
// a volume has at most
static const int MAX_EXTENT = 64;
static const int MAX_VOLUME = 64;
// [KIT_CTF] A region's extent each way: the World's whole height, so a
// map-wide region and a column down to the World's bottom fit;
// [KIT_AIRSHIPS_2] the widest World's side (kit/world's width), so one
// covers a whole 1024 heightmap (the airships template's deadly ground)
static const int MAX_REGION_EXTENT = 2048;
// The cells a grants type's c:set_voxel sets at most (its box)
static const int MAX_SET_CELLS = 4096;
// [KIT_CTF] c:explode: its radius in cells (a sphere of about 3050 cells
// at most), the reach of its kill and hurt radii, the entities told
// (on_blast), and Kit's blasts a second (a server's, every round's
// together) and their burst
static const double MAX_BLAST_RADIUS = 9, MAX_BLAST_REACH = 32;
static const size_t MAX_BLAST_TOLD = 64;
static const double EXPLODE_RATE = 4, EXPLODE_BURST = 16;
// [KIT_PARTICLES] c:effect: the particles of a burst, the colours and voxel
// materials it shares them between, how far from a player it is sent at
// most (m), and Kit's bursts a second (a server's, every round's together)
// and their burst
static const int MAX_EFFECT_PARTICLES = 256;
static const unsigned MAX_EFFECT_KINDS = 4;
static const double MAX_EFFECT_RANGE = 128;
static const double EFFECT_RATE = 240, EFFECT_BURST = 480;
// [KIT_VOXEL_STATES] A voxel_box's extent each way, a pattern parameter's
// bytes and the voxel names in it at most
static const int MAX_VOXEL_BOX = 16;
static const size_t MAX_PATTERN = 32768;
static const size_t MAX_PATTERN_NAMES = 256;
// The most of an item a player has (Kit's own counts, c:add)
static const int64_t MAX_ITEMS = 1000000;
// What an editor's packet may be and do
static const size_t MAX_EDIT_PACKET = 4096;
// [KIT_SIGNALS_LIVE] The most of a value a builder's test sends
static const size_t MAX_TRY_VALUE = 512;
// The most of an output's value a watcher is told, and how often
static const size_t WATCH_VALUE_BYTES = 64;
static const int64_t WATCH_EVERY_US = 200000;
static const size_t MAX_STRING = 256;
static const double MAX_COORD = 30000;
static const size_t MAX_ENTITIES = 4096;
// [KIT_NESTING] The levels of entities under entities a scene has at most
static const int MAX_NEST = 16;
// [KIT_PREFAB_ROOT] What a placed prefab's members are under
static const char *const PREFAB_ROOT = "kit/prefab_copy";
// [KIT_COMPONENTS] What moves a free object by a function of the round's time
static const char *const WAVE_TYPE = "kit/wave";
// [KIT_SYMMETRY]
static const char *const SYMMETRY_TYPE = "kit/symmetry";
// [KIT_VEHICLE_MOVEMENTS] A free object's course there and back, a movement
static const char *const COURSE_TYPE = "kit/course";
// [KIT_AIRSHIPS] Who builds on a free copy in play and what a voxel costs; the
// players' money for the round; a ship's core voxel (one a ship, stage 4's)
static const char *const HULL_TYPE = "kit/hull";
static const char *const WALLET_TYPE = "kit/wallet";
static const char *const CORE_VOXEL = "kit/core";
// [KIT_AIRSHIPS] stages 3-5: a ship's parts summed for its movement, its radar,
// the zone whose `deadly` loses a ship touching it
static const char *const ENGINE_TYPE = "kit/engine";
static const char *const RADAR_TYPE = "kit/radar";
static const char *const TRIGGER_TYPE = "kit/trigger_zone";
static const size_t MAX_LINKS = 64;
// [KIT_COMPONENTS] Components an entity has at most, by Add component
static const size_t MAX_COMPONENTS = 16;
// [KIT] stage 4g: the builders' voxel types and uploaded textures a save
// has at most, and what an upload may be
static const size_t MAX_VOXEL_TYPES = 256, MAX_TEXTURES = 256;
static const size_t MAX_ITEM_TYPES = 256; // [KIT_TOOLS_1]
// [KIT_SOUNDS] the sounds a save has at most, a sound's params' length
static const size_t MAX_SOUNDS = 256, MAX_SOUND = 2048;
static const size_t MAX_PROJECTILES = 256; // [KIT_TOOLS_2] a round's
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
// [KIT_GENERATORS] The children a generator's build makes at most: with
// the generator, a prefab's members
static const size_t MAX_BUILT = MAX_PREFAB - 1;
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
// [KIT_AIRSHIPS_2] a kit/world_region's side at most
static const int MAX_WORLD_REGION = 128;
static const int MAX_FILL = 64;
static const double HM_STEP = 0.25;
static const float HM_ROCK_SLOPE = 0.35f;
// [KIT_HEIGHTMAP_REGEN_LOSS] The edited samples' rows' chunk side, and how
// far round an edited sample a generated one is blended toward it
static const int HM_EDIT_CHUNK = 64, HM_BLEND = 4;
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
	// look turning with it). [KIT_FREE_ROTATION] pitch and roll too, Urho3D's
	// Quaternion(pitch, yaw, roll) (roll first, then pitch, then yaw)
	double yaw = 0, pitch = 0, roll = 0;
	sv_<Instance> comps;
	uint32_t node = 0; // a positional one's node in its scene
	// [KIT_PREFAB_ROOT] authored: a placed prefab's root (kit/prefab_copy),
	// {"of", "version", "voxels" (the prefab's voxels_version this copy last
	// stamped, if it has any)}, its members its built children. Made in play
	// (c:spawn, no root): each member's {"of", "version", "member", "copy"
	// (the copy's first entity)}. Undefined if none
	json::Value prefab;
	// authored ([KIT_GENERATORS]): a generator's child, {"by" (its id),
	// "member" (its number in the build), "moved": true (put elsewhere by
	// a builder: a rebuild keeps its place)}; undefined if none
	json::Value built;
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
	// [KIT_UI_COMPONENTS] The state each player has their own of, {"player:
	// <id>": value} (per_player = true): each client is sent only theirs
	std::set<ss_> per_player;
	// [KIT] stage 4d: each signal's value's type ("any" where the file
	// gives none; "none": no value)
	sm_<ss_, ss_> in_types, out_types;
	// It reads every player entity (players = true); it is on each player
	// entity, not placed (player = true)
	bool players = false, player = false;
	// [KIT_PARTICLES] The parameter saying which world event its on_event
	// takes (events = "<param>"; "": none)
	ss_ events;
	// [KIT_TOOLS_1] A player's type builders also place on entities
	// (placeable = true: kit/health); it is health (health = true: on_hit,
	// what a hit damages), equipment (equipment = true: the hands slot,
	// on_tool, the wear)
	bool placeable = false, health = false, equipment = false;
	// [KIT_MINIGAMES_1] It is a team (team = true: the Team interface, its
	// state members and score); it reads every team (teams = true)
	bool team = false, teams = false;
	// [KIT_CTF] It reads its scene's regions (regions = true: c:region_at)
	bool regions = false;
	// Its client part, <name>.client.lua beside it ("" none)
	ss_ client;
	bool usable = false, owns_voxel = false;
	// It provides the players' inventory (inventory = true)
	bool inventory = false;
	// [KIT] stage 4c: it places players at the round's start (spawn), it
	// says what players keep between plays (between_plays), it goes on the
	// app root (root)
	bool spawn = false, between_plays = false, root = false;
	// [KIT_NO_WORLD_TYPES]
	bool no_position = false;
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
	// [KIT_AIRSHIPS_2] The position parameter that is its kit/world_region
	// box ("" none): the World's voxels Kit generates in it
	ss_ world_region;
	// [KIT_SYMMETRY] Its parameters' kinds in space (api.h), as kit/symmetry's
	// copies take them: declared (space = {}) or of its boxes
	std::map<ss_, ss_> space;
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
	// [KIT_AFTER_DRIFT] on_timer's: the timer's due time; set again in
	// its own handler, it counts from that, not from the tick it ran in
	int64_t timer_due = 0;
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
	// [KIT_MOVING_OBJECTS] The moving object their body stands on (0: none) and
	// where they would be with it at rest: what their node says
	uint64_t frame = 0;
	double frame_rest[3] = {0, 0, 0};
	bool editing = false;
	// [KIT_JOIN_ORIGIN_POSITION] Joined, the join's runs (a spawner's
	// teleport) not done yet: in no zone, its place the app's
	bool spawning = false;
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
	// [KIT_INPUT_ACTIONS] The actions they hold: when pressed and when
	// "held" last came (game_us); their allowance of acts (time_us)
	std::map<ss_, std::pair<int64_t, int64_t>> held;
	double action_tokens = ACTION_BURST;
	int64_t action_at = 0;
	// Their generator builds' allowance (BUILD_RATE; time_us)
	double build_tokens = BUILD_BURST;
	int64_t build_at = 0;
	// [KIT_USE_FLOOD] The refusal last logged and when (time_us): the
	// same one again is logged once a second at most
	ss_ refused_why;
	int64_t refused_at = 0;
	// [KIT_UI_COMPONENTS] Their own of each per_player state as last sent
	// ("<entity>:<key>": JSON), and the UI buttons they hold
	std::map<ss_, ss_> mine_sent;
	std::set<uint64_t> ui_held;
	// [KIT_EDIT_MODE_FPS] kit:edit_state's keys as last sent (JSON): one the
	// same again goes by name in "same", not again (about 100 KB a state
	// in edit mode, the types' declarations most of it)
	std::map<ss_, ss_> state_sent;
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

// [KIT] stage 4f: a decoration on a heightmap surface: a voxel object of
// its structure's model, turned about y (degrees)
struct Decor
{
	ss_ structure;
	float x = 0, y = 0, z = 0, yaw = 0;
	unsigned node = 0;
	// [KIT_HEIGHTMAP_REGEN_LOSS] put by a builder (the decorate brush): kept
	// over a regeneration, as the edited samples are
	bool hand = false;
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
	// [KIT_HEIGHTMAP_REGEN_LOSS] a heightmap stroke's samples' edit marks
	// as they were (false: not edited), and a regeneration of all (its
	// undo the previous heightmap put back)
	std::map<std::pair<int, int>, std::pair<bool, std::pair<float,
			heightmap::Weights>>> hm_marks;
	bool hm_restore = false;
	// [KIT_PREFAB_VOXELS] stroke -3: a prefab's place, its entities in
	// before and its voxels' cells in cells (scene's), undone together
	// [KIT_SYMMETRY] the decorations it removed (kit/symmetry's copy over
	// the other slices), put back by its undo
	sv_<Decor> decor_gone;
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
	// A game session's finite map: loaded round its players and the
	// spawn, as an infinite World is; a section it does not hold stays
	// the start's alone (its SessionSource's), copied in for a player
	// near it or a write (lean_section())
	voxelworld::Instance *lean_world = nullptr;
	json::Value world_applied;
	world::Params wp;
	// [KIT_MATERIAL_SETS] the material set it is made of (its
	// "materials": the app's, or an installed package's)
	world::MaterialSet materials;
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
	// [KIT_HEIGHTMAP_REGEN_LOSS] a builder's decorations off the map (it
	// was made smaller): kept in the save, back if it grows again
	sv_<Decor> decor_off;
	// The heightmap's samples the terrain tools wrote, by cell (the map is
	// from the origin, a sample a cell): their height and layers, kept
	// over every regeneration and resize (those off the map too), saved in
	// rows "hm_edit/<cx>,<cz>" by HM_EDIT_CHUNK cells; the chunks changed
	std::map<std::pair<int, int>, std::pair<float, heightmap::Weights>>
			hm_edits;
	std::set<std::pair<int, int>> hm_edits_dirty;
	bool hm_edits_loaded = false;
	// A regeneration of everything asked (regenerate_all()): apply_world
	// generates though nothing changed
	bool hm_force = false;
	// [KIT_HM_ORIGIN] The heightmap's sample (0, 0) at the world's origin
	// (a World saved before maps had an origin: kept where it was), not at
	// the map's corner (x0(), z0()), as the voxels' finite area
	bool hm_corner = false;
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

// [KIT_SESSIONS_1] The start's copies of one scene's sections the default
// round wrote, as a session's source reads them on voxelworld's thread: the
// Watch's in flight (before Kit's next tick stores them), else the store's
// rows ("start:<scene>:x,y,z"); cleared as the copies go (Play, Stop, Save
// as start)
struct StartCopies
{
	std::mutex mutex;
	std::map<ss_, ss_> data;
	storage::Store *store = nullptr;
	void put(const ss_ &key, const ss_ &d)
	{
		std::lock_guard<std::mutex> lock(mutex);
		data[key] = d;
	}
	void clear()
	{
		std::lock_guard<std::mutex> lock(mutex);
		data.clear();
		kept.clear();
	}
	// The cells of a section kept as made (live edits, marks 'k') since
	// its copy, by its key
	std::map<ss_, sv_<pv::Vector3DInt32>> kept;
	void set_kept(const ss_ &key, const sv_<pv::Vector3DInt32> &cells)
	{
		std::lock_guard<std::mutex> lock(mutex);
		if(cells.empty())
			kept.erase(key);
		else
			kept[key] = cells;
	}
	sv_<pv::Vector3DInt32> kept_of(const ss_ &key)
	{
		std::lock_guard<std::mutex> lock(mutex);
		auto it = kept.find(key);
		return it == kept.end() ? sv_<pv::Vector3DInt32>() : it->second;
	}
	bool get(const ss_ &key, ss_ &out)
	{
		if(store && store->get(key, out))
			return true;
		std::lock_guard<std::mutex> lock(mutex);
		auto it = data.find(key);
		if(it == data.end())
			return false;
		out = it->second;
		return true;
	}
};

// [KIT_SESSIONS_1] A session's scene's voxels, copy-on-write over the
// start's (voxelworld's SectionSource): a section the default round wrote,
// its copy (the round's live edits over it); else the default's instance's
// own (loaded, or its save's); else none (the session's World generates
// it, as the start's would).
// simplified: read as the session first loads it; a live edit in the
// default since the session started is in a section it loads after
// (its entities are the start's as it started). A snapshot of the start
// at the session's start is the upgrade
struct SessionSource: public voxelworld::SectionSource
{
	ss_ scene;
	voxelworld::Instance *base = nullptr;
	sp_<StartCopies> copies;
	bool section(voxelworld::Instance *world, const pv::Vector3DInt16 &sp,
			interface::VoxelVolume &out)
	{
		ss_ data;
		const ss_ key = "start:"+scene+":"+itos(sp.getX())+","+
				itos(sp.getY())+","+itos(sp.getZ());
		if(copies && copies->get(key, data)){
			up_<interface::VoxelVolume> v = interface::deserialize_volume(data);
			if(v){
				out = *v;
				const sv_<pv::Vector3DInt32> kept = copies->kept_of(key);
				interface::VoxelVolume now(out.getEnclosingRegion());
				if(!kept.empty() && base && base->read_section(sp, now))
					for(const pv::Vector3DInt32 &p : kept)
						out.setVoxelAt(p, now.getVoxelAt(p));
				return true;
			}
		}
		return base && base->read_section(sp, out);
	}
};

// [KIT_SESSIONS_1] A session's store: an overlay over Kit's, its rows in
// memory (read through to the start's), so nothing a session does reaches
// the save; the builder's own server-wide rows (prefabs, voxel types,
// textures, packages) pass through
struct OverlayStore: public storage::Store
{
	storage::Store *base = nullptr;
	// key -> (there, value)
	std::map<ss_, std::pair<bool, ss_>> own;
	static bool through(const ss_ &key)
	{
		for(const char *pre : {"prefab:", "voxel:", "texture:", "package:"})
			if(key.compare(0, strlen(pre), pre) == 0)
				return true;
		return false;
	}
	bool get(const ss_ &key, ss_ &value_out)
	{
		auto it = own.find(key);
		if(it == own.end() || through(key))
			return base->get(key, value_out);
		if(!it->second.first)
			return false;
		value_out = it->second.second;
		return true;
	}
	void set(const ss_ &key, const ss_ &value)
	{
		if(through(key))
			return base->set(key, value);
		own[key] = std::make_pair(true, value);
	}
	void remove(const ss_ &key)
	{
		if(through(key))
			return base->remove(key);
		own[key] = std::make_pair(false, ss_());
	}
	sv_<ss_> list(const ss_ &prefix)
	{
		std::set<ss_> r;
		for(const ss_ &k : base->list(prefix))
			r.insert(k);
		for(auto it = own.lower_bound(prefix); it != own.end() &&
				it->first.compare(0, prefix.size(), prefix) == 0; ++it){
			if(through(it->first))
				continue;
			if(it->second.first)
				r.insert(it->first);
			else
				r.erase(it->first);
		}
		return sv_<ss_>(r.begin(), r.end());
	}
	void batch(std::function<void()> writes)
	{
		writes();
	}
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
	// [KIT_SESSIONS_1] the sessions' view of the copies
	sp_<StartCopies> start;
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
		if(start)
			start->put(c.key, c.data);
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
// names and "<key>_types" an object of their types. "string:player" is a
// string, its label ("<key>_labels") what the editor calls it: a link looks
// at the type alone, so that a text element still takes a player's name
static bool signals(json::Value &decl, const char *key, std::set<ss_> &names,
		sm_<ss_, ss_> &types, ss_ &why)
{
	const json::Value &v = decl.get(key);
	json::Value list = json::array(), typed = json::object(),
			labels = json::object();
	auto add = [&](const ss_ &name, const ss_ &declared) -> bool {
		const size_t colon = declared.find(':');
		const ss_ type = declared.substr(0, colon);
		if(colon != ss_::npos){
			const ss_ label = declared.substr(colon + 1);
			if(type != "string" || !name_ok(label)){
				why = ss_(key)+": "+name+": only a string has a label, of "
						"letters, digits and _ (not \""+declared.substr(0, 32)+"\")";
				return false;
			}
			labels.set(name, label);
		}
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
	decl.set(ss_(key)+"_labels", labels);
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
	// [SK_KIT_START_STALL] The first box, made from init() on a thread of
	// its own: its box/ built to a .wasm on a cold cache took 5.9 s, which
	// an app hosting Kit late (skeldat, once its world is in) waited out
	// on its tick with every player behind it. start_box() takes it.
	std::future<std::pair<interface::WasmBox*, ss_>> m_early_box;
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
	// [KIT_CTF] c:explode's allowance (EXPLODE_RATE), time_us
	double m_blast_tokens = EXPLODE_BURST;
	int64_t m_blast_at = 0;
	// [KIT_PARTICLES] c:effect's allowance (EFFECT_RATE), time_us
	double m_effect_tokens = EFFECT_BURST;
	int64_t m_effect_at = 0;
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
	// [KIT_SET_UPGRADE_BREAKS] set_breaks()'s set, by package, while it tries
	sm_<ss_, json::Value> m_set_trial;
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
		// [KIT_PREFAB_ROOT] a stamp's: this box's cells emptied first, and
		// the undo the same as the move just before it
		bool clear = false, merge = false;
		int clear_at[3] = {0, 0, 0}, clear_size[3] = {0, 0, 0};
		// [KIT_FREE_PREFAB] the box emptied, nothing written
		bool only_clear = false;
	} m_paste;
	// [KIT_FREE_PREFAB] (sync_free_objects()) by root; each scene's models made;
	// each model's boxes in its object's frame, x0 y0 z0 x1 y1 z1 each, for the
	// bodies; what each peer has been sent of those. simplified: a model's boxes
	// stay here once made, a few KB a saved version until the server stops;
	// erasing them with the last scene's model is the upgrade
	struct FreeObject
	{
		main_context::SceneReference ref = nullptr;
		ss_ model;
		uint node = 0;
		// x y z yaw pitch roll
		std::array<double, 6> place = {{0, 0, 0, 0, 0, 0}};
		// [KIT_MOVING_OBJECTS] the node from the root, in its frame; the body is off
		// its node
		double corner[3] = {0, 0, 0};
		bool body_moved = false;
		// [KIT_AIRSHIPS] its boxes' name in m_free_boxes: the model's, or its own
		// voxels' (a new name each rebuild, so a client is sent them again)
		ss_ boxes;
	};
	std::map<uint64_t, FreeObject> m_free_objects;
	// [KIT_AIRSHIPS] A free copy's own voxels in play (own_build()): its prefab's
	// cells copied into a cube of OWN_SIDE about the prefab's box once a player
	// changes one, shown by a model of its own ("kitown_<id>") with boxes of its own,
	// made again at most once in OWN_REBUILD_GAP for all copies together. Play
	// state: gone at Stop, the copy showing its prefab's model again
	static const int OWN_SIDE = 32;
	struct OwnCell
	{
		interface::VoxelTypeId id = 0;
		uint8_t param = 0, tint = 0;
	};
	struct OwnGrid
	{
		int a[3] = {0, 0, 0}; // the entity frame's cell at the cube's (0, 0, 0)
		sv_<OwnCell> v; // x + OWN_SIDE * (y + OWN_SIDE * z)
		std::set<int> changed; // since its model last took them
		bool made = false; // its model and boxes exist
		bool dirty = false;
		int64_t since = 0; // the first change waiting, us
		int rev = 0;
		ss_ boxes;
		// The core (kit/core): the cell connection is reckoned from (stage 4);
		// -1: none
		int core = -1;
		// [KIT_AIRSHIPS] stage 3: its voxels' mass (-1: to be summed again); the
		// parts mounted on each cell (their first entity's ids). Stage 4: the
		// damage each cell has taken, and what each destroyed cell was (a repair
		// puts it back)
		double mass = -1;
		int lo[3] = {0, 0, 0}, hi[3] = {-1, -1, -1}; // its voxels' cells, with mass
		std::map<int, sv_<uint64_t>> mounts;
		std::map<int, int> mounted_on; // a part's cell: the voxel it is on (a shot there hits that)
		std::map<int, double> hurt;
		std::map<int, OwnCell> lost;
	};
	std::map<uint64_t, OwnGrid> m_own;
	// [KIT_AIRSHIPS] stage 3: the radars' contacts last made (us)
	int64_t m_radar_at = 0;
	// Not a session's: one budget for every ship of the server
	int64_t m_own_rebuilt_at = 0;
	std::map<main_context::SceneReference, std::set<ss_>> m_free_models;
	sm_<ss_, sv_<float>> m_free_boxes;
	sm_<size_t, std::set<ss_>> m_boxes_sent;
	// [KIT_PREFAB_ROOT] a save's: the copies of this prefab but that one
	// are built again (rebuilds())
	ss_ m_follow;
	uint64_t m_follow_source = 0;
	// [KIT_PREFAB_BENCH] The prefab this edit saved in a bench
	ss_ m_bench_saved;
	// [KIT_GENERATORS] a build's call under way (box_call(): its budget)
	bool m_building = false;
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
		if(m_early_box.valid())
			delete m_early_box.get().first;
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
				// [KIT_SESSIONS_1] the sessions' scenes
				for(auto &r : m_ref_session){
					voxelworld::Instance *w = ivw->get_instance(r.first);
					if(w){
						w->set_owner_handler("kit", nullptr);
						w->set_section_source(nullptr);
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
		m_early_box = std::async(std::launch::async, [this](){
			ss_ why;
			interface::WasmBox *b = m_server->create_wasm_box(MODULE, "box",
					why);
			return std::make_pair(b, why);
		});
		sub(m_server, "core:tick", &Module::on_tick);
		// [KIT_SHUTDOWN_SAVE] Synchronous, every save still open: what
		// changed since the last tick (a mark, the runtime) was lost at a
		// stop before the next one
		sub(m_server, "core:shutdown", &Module::on_shutdown);
		sub(m_server, "core:save", &Module::on_shutdown);
		// [WORKBENCH_SWITCH_PROJECT] And before a reload (an app's switch):
		// the app closes its save after
		sub(m_server, "core:unload", &Module::on_shutdown);
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
		sub(m_server, "network:packet_received/kit:action", &Module::on_action);
		sub(m_server, "network:packet_received/kit:ui", &Module::on_ui_press);
		sub(m_server, "network:packet_received/kit:exit", &Module::on_exit);
		// [KIT_AIRSHIPS] a place or dig on a free object
		sub(m_server, "network:packet_received/kit:obuild", &Module::on_obuild);
		// [KIT_TOOLS_1] the hands, a melee hit, an item's use
		sub(m_server, "network:packet_received/kit:hold", &Module::on_hold);
		sub(m_server, "network:packet_received/kit:inv", &Module::on_inv);
		sub(m_server, "network:packet_received/kit:hit", &Module::on_hit);
		sub(m_server, "network:packet_received/kit:item",
				&Module::on_item_use);
		// [KIT_TOOLS_2] a ranged item's draw, shot and reload
		sub(m_server, "network:packet_received/kit:draw", &Module::on_draw);
		sub(m_server, "network:packet_received/kit:shoot", &Module::on_shoot);
		sub(m_server, "network:packet_received/kit:reload",
				&Module::on_reload);
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
		up_<interface::WasmBox> b;
		if(m_early_box.valid()){
			const int64_t t0 = interface::os::time_us();
			auto r = m_early_box.get();
			b.reset(r.first);
			why = r.second;
			log_i(MODULE, "The box made since the start: waited %.1f s for it",
					(interface::os::time_us() - t0) / 1e6);
		} else {
			b.reset(m_server->create_wasm_box(MODULE, "box", why));
		}
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
			// [KIT_MAP_ROTATION_LEFTOVERS] math.random seeded by the clock
			if(!box_call("N"+std::to_string(interface::os::time_us()), answer, why))
				log_w(MODULE, "The box's random seed: %s", cs(why));
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
		// [KIT_GENERATORS] a build (in the editor, not a tick's) a call's
		const int64_t slice = request[0] == 'D' || request[0] == 'L' ||
				m_building ? m_box->budget() : request[0] == 'S' ?
				m_box->budget() / 4 :
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
		t.placeable = t.decl.get("placeable").is_true();
		t.health = t.decl.get("health").is_true();
		t.equipment = t.decl.get("equipment").is_true();
		t.team = t.decl.get("team").is_true();
		t.teams = t.decl.get("teams").is_true();
		t.regions = t.decl.get("regions").is_true();
		t.events = jstr(t.decl, "events");
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
				else if((*it).get("per_player").is_true()){
					t.per_player.insert(it.key());
					t.shared.insert(it.key());
				}
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
		// [KIT_OWN_LOOK] Whether its own look shows in play, the engine's on
		// every type with a look (show_of() marks it hidden; the clients
		// draw it faded in edit mode). Off hides only the look: its
		// collision is its own (a mover's box still carries players while
		// solid), the entities under it are drawn as ever
		if(t.decl.get("look").is_object()){
			json::Value ps = t.decl.get("params");
			if(!ps.is_object())
				ps = json::object();
			if(!ps.get("own_look").is_undefined()){
				why = name+": \"own_look\" is Kit's parameter on a type with "
						"a look";
				return false;
			}
			json::Value o = json::object();
			o.set("type", "bool");
			o.set("default", true);
			o.set("cat", "look");
			ps.set("own_look", o);
			t.decl.set("params", ps);
		}
		// [KIT_PARAM_CATEGORIES] Which of the inspector's categories a
		// parameter is under. Another value does not stop the type: warned
		// of and treated as none (behaviour)
		json::Value cat_ps = t.decl.get("params");
		if(cat_ps.is_object()){
			std::vector<ss_> bad_cats;
			for(json::Iterator it(cat_ps); it; ++it){
				if(!(*it).is_object() || (*it).get("cat").is_undefined())
					continue;
				const json::Value &c = (*it).get("cat");
				if(!c.is_string() || (c.as_string() != "behaviour" &&
						c.as_string() != "hud" && c.as_string() != "look" &&
						c.as_string() != "physics" && c.as_string() != "advanced"))
					bad_cats.push_back(it.key());
			}
			for(const ss_ &k : bad_cats){
				log_w(MODULE, "%s: parameter %s: cat %s is none of behaviour, "
						"hud, look, physics, advanced: treated as behaviour",
						cs(name), cs(k), cs(cat_ps.get(k).get("cat").stringify()));
				json::Value p = cat_ps.get(k);
				p.set("cat", "behaviour");
				cat_ps.set(k, p);
			}
			if(!bad_cats.empty())
				t.decl.set("params", cat_ps);
		}
		t.owns_voxel = t.decl.get("owns_voxel").is_true();
		// [KIT_INPUT_ACTIONS] {{name =, key =, label =}...}: strings, each
		// a value or "param:<name>"
		const json::Value &acts = t.decl.get("actions");
		if(!acts.is_undefined()){
			bool ok = acts.is_array() && acts.size() <= MAX_TYPE_ACTIONS;
			for(unsigned i = 0; ok && i < acts.size(); i++)
				ok = acts.at(i).is_object() && acts.at(i).get("name").is_string();
			if(!ok){
				why = name+": actions is a list of at most "+
						itos(MAX_TYPE_ACTIONS)+" {name = , key = , label = }";
				return false;
			}
		}
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
		t.no_position = t.decl.get("no_position").is_true();
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
				std::make_pair("voxel_box", &t.voxel_box),
				std::make_pair("world_region", &t.world_region)}){
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
		// [KIT_SYMMETRY] What its parameters are in space (api.h): declared,
		// and its boxes' by what they are
		{
			const json::Value &sp = t.decl.get("space");
			if(!sp.is_undefined() && !sp.is_object()){
				why = name+": space is {<param> = <kind>}";
				return false;
			}
			for(json::Iterator it(sp); it; ++it){
				const ss_ k = (*it).is_string() ? (*it).as_string() : "";
				const ss_ pt = jstr(t.decl.get("params").get(it.key()), "type");
				if(k != "world" && k != "offset" && k != "rotation" &&
						k != "mirror" && k != "box" && k != "cells"){
					why = name+": space's "+it.key()+": world, offset, rotation, "
							"mirror, box or cells";
					return false;
				}
				if(pt != (k == "mirror" ? "bool" : "position")){
					why = name+": space's "+it.key()+" names no "+(k == "mirror" ?
							"bool" : "position")+" parameter";
					return false;
				}
				t.space[it.key()] = k;
			}
			for(const ss_ &b : {t.zone, t.region, t.grants, lx})
				if(!b.empty() && !t.space.count(b))
					t.space[b] = "box";
			for(const ss_ &b : {t.volume, t.voxel_box, t.world_region})
				if(!b.empty() && !t.space.count(b))
					t.space[b] = "cells";
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

	// [KIT_NO_WORLD_TYPES] Whether all its types say no_position (api.h)
	bool no_position(const Entity &e)
	{
		if(e.comps.empty() || !e.kind.empty())
			return false;
		for(const Instance &in : e.comps){
			// [KIT_PREFAB_ROOT] a copy's root has a place by its prefab: one
			// with none has no position as these have
			if(in.type == PREFAB_ROOT && !e.has_pos)
				continue;
			auto t = m_types.find(in.type);
			if(t == m_types.end() || !t->second.no_position)
				return false;
		}
		return true;
	}

	// [KIT_PANEL_PARENT] A UI element: no position and a `ui` (not a flag's or
	// an arena's, which stand in the world); is_panel: one of kind "panel",
	// which those under it are laid out in
	bool is_ui_element(const Entity &e)
	{
		if(!no_position(e))
			return false;
		for(const Instance &in : e.comps)
			if(m_types[in.type].decl.get("ui").is_object())
				return true;
		return false;
	}
	bool is_panel(const Entity &e)
	{
		if(!no_position(e))
			return false;
		for(const Instance &in : e.comps){
			const json::Value &d = m_types[in.type].decl.get("ui");
			if(d.is_object())
				return jstr(d, "kind") == "panel";
		}
		return false;
	}
	// The panel a UI element is in: its parent if one, 0 none
	uint64_t panel_of(const Entity &e)
	{
		auto it = m_entities.find(e.parent);
		return it != m_entities.end() && is_panel(it->second) ? e.parent : 0;
	}

	// [KIT_PREFAB_ROOT] Whether it is a placed prefab's root
	static bool is_root(const Entity &e)
	{
		if(!e.prefab.is_object())
			return false;
		for(const Instance &in : e.comps)
			if(in.type == PREFAB_ROOT)
				return true;
		return false;
	}

	// [KIT_COMPONENTS] Whether a type goes on an entity through the inspector's
	// Add component: one without a place (api.h)
	bool addable(const ss_ &type)
	{
		const auto t = m_types.find(type);
		if(t == m_types.end())
			return false;
		const json::Value &c = t->second.decl.get("component");
		return c.is_boolean() ? c.as_boolean() : t->second.placeable ||
				(t->second.no_position && !t->second.decl.get("ui").is_object());
	}

	// Whether it has a node: one with no position's is its shared state's and
	// its HUD element's alone, nothing drawn in the world
	bool wants_node(const Entity &e)
	{
		return e.has_pos || (no_position(e) && scene_of(e));
	}

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

	// ---- [KIT_NESTING] Children for places: an entity under a positioned
	// one has its position and yaw in its parent's frame, moving and turning
	// with it; under a scene, the world's. Its node is its scene's child
	// all the same, at its place in the world, with "kit_parent" its
	// parent's id (0: none).
	// simplified: replicate's nodes flat, each placed in the world (the
	// clients' code reads node.position as the world's); a parent's move
	// places each node under it again, a scan of the entities a level

	// [KIT_FREE_ROTATION] A turn as a quaternion, in doubles: world poses are
	// composed in these, rows keep the angles
	struct Turn
	{
		double w = 1, x = 0, y = 0, z = 0;
		Turn(){}
		Turn(double w, double x, double y, double z): w(w), x(x), y(y), z(z){}
		// Degrees, as magic::Quaternion(pitch, yaw, roll)
		static Turn of(double yaw, double pitch = 0, double roll = 0)
		{
			if(yaw == 0 && pitch == 0 && roll == 0)
				return Turn();
			const double k = 3.14159265358979323846 / 360;
			const double sy = std::sin(yaw * k), cy = std::cos(yaw * k);
			const double sx = std::sin(pitch * k), cx = std::cos(pitch * k);
			const double sz = std::sin(roll * k), cz = std::cos(roll * k);
			return Turn(cy * cx * cz + sy * sx * sz, cy * sx * cz + sy * cx * sz,
					sy * cx * cz - cy * sx * sz, cy * cx * sz - sy * sx * cz);
		}
		static Turn of(const Entity &e)
		{
			return of(e.yaw, e.pitch, e.roll);
		}
		// Round an axis of length 1
		static Turn around(const double a[3], double degrees)
		{
			const double r = degrees * 3.14159265358979323846 / 360;
			const double sn = std::sin(r);
			return Turn(std::cos(r), a[0] * sn, a[1] * sn, a[2] * sn);
		}
		// This one after b (a parent's * a child's)
		Turn operator*(const Turn &b) const
		{
			return Turn(w * b.w - x * b.x - y * b.y - z * b.z,
					w * b.x + x * b.w + y * b.z - z * b.y,
					w * b.y - x * b.z + y * b.w + z * b.x,
					w * b.z + x * b.y - y * b.x + z * b.w);
		}
		Turn inverse() const
		{
			return Turn(w, -x, -y, -z);
		}
		bool none() const
		{
			return std::fabs(x) + std::fabs(y) + std::fabs(z) < 1e-9;
		}
		void apply(double v[3]) const
		{
			if(x == 0 && y == 0 && z == 0)
				return;
			const double tx = 2 * (y * v[2] - z * v[1]);
			const double ty = 2 * (z * v[0] - x * v[2]);
			const double tz = 2 * (x * v[1] - y * v[0]);
			v[0] += w * tx + y * tz - z * ty;
			v[1] += w * ty + z * tx - x * tz;
			v[2] += w * tz + x * ty - y * tx;
		}
		// Its angles, each 0...360 and to a millionth of a degree (what a yaw
		// of 90 is tested by). At a pitch of 90 all of it is yaw
		void angles(double &yaw, double &pitch, double &roll) const
		{
			const double d = 180 / 3.14159265358979323846;
			const double check = 2 * (w * x - y * z);
			if(std::fabs(check) > 1 - 1e-10){
				pitch = check > 0 ? 90 : -90;
				yaw = 2 * std::atan2(y, w) * d;
				roll = 0;
			} else {
				pitch = std::asin(check) * d;
				yaw = std::atan2(2 * (x * z + w * y), 1 - 2 * (x * x + y * y)) * d;
				roll = std::atan2(2 * (x * y + w * z), 1 - 2 * (x * x + z * z)) * d;
			}
			for(double *a : {&yaw, &pitch, &roll}){
				*a = std::fmod(std::round(*a * 1e6) / 1e6, 360.0) + 0.0;
				if(*a < 0)
					*a += 360;
			}
		}
		// The way it faces on the level: what a spawn looks along
		double yaw() const
		{
			double a, b, c;
			angles(a, b, c);
			return a;
		}
		magic::Quaternion q() const
		{
			return magic::Quaternion((float)w, (float)x, (float)y, (float)z);
		}
	};

	// A row's pitch and roll taken from another's
	static void row_tilt(json::Value &row, const json::Value &from)
	{
		for(const char *k : {"pitch", "roll"})
			if(from.get(k).is_number())
				row.set(k, norm_yaw(from.get(k).as_number()));
	}
	// A row's turn, as kept: yaw always, the others when it has them
	static void row_turn(json::Value &row, double yaw, double pitch, double roll)
	{
		row.set("yaw", norm_yaw(yaw));
		if(pitch != 0 || row.get("pitch").is_number())
			row.set("pitch", norm_yaw(pitch));
		if(roll != 0 || row.get("roll").is_number())
			row.set("roll", norm_yaw(roll));
	}
	static void row_turn(json::Value &row, const Turn &q)
	{
		double a, b, c;
		q.angles(a, b, c);
		row_turn(row, a, b, c);
	}
	static double row_num(const json::Value &row, const char *k)
	{
		const json::Value &v = row.get(k);
		return v.is_number() && std::isfinite(v.as_number()) ? v.as_number() : 0;
	}

	// The frame the entities under id are in: its place in the world,
	// moved by what its look carries (kit/mover's offset while out: they
	// go where it goes, at once, as its box does for the players); the
	// world's for a scene, the root or one with no position
	void frame_of(uint64_t id, double o[3], Turn &q, int depth = 0)
	{
		o[0] = o[1] = o[2] = 0;
		q = Turn();
		auto it = m_entities.find(id);
		if(it == m_entities.end() || !it->second.has_pos ||
				depth > MAX_NEST + 2)
			return;
		const Entity &e = it->second;
		world_of(e, o, &q, depth + 1);
		for(const Instance &in : e.comps){
			auto ti = m_types.find(in.type);
			if(ti == m_types.end())
				continue;
			const json::Value &d = ti->second.decl.get("look");
			const ss_ key = d.is_object() ? jstr(d, "state") : ss_();
			if(key.empty() || !in.state.get(key).is_true() ||
					!d.get("when").is_object() ||
					d.get("when").get("offset").is_undefined())
				continue;
			const json::Value off = look_of(in, d).get("when").get("offset");
			if(!pos_ok(off))
				continue;
			double v[3] = {off.at(0u).as_number(), off.at(1u).as_number(),
					off.at(2u).as_number()};
			q.apply(v);
			for(int k = 0; k < 3; k++)
				o[k] += v[k];
			break;
		}
	}

	// [KIT_MOVING_OBJECTS] A free object's motion: a function of the round's time
	// (motion_t()), so that the clients compute the same and no pose is sent. On each
	// side it is the object's place and turn over its row's; move.lua's M.link_at says
	// the same in the world, and that is the one a body steps with. Running only.
	// [KIT_COMPONENTS] kit/wave's parameters when this entity's object moves; nullptr:
	// it is where its row says
	// [KIT_VEHICLE_MOVEMENTS] Built each tick by sync_motions(): kit/wave's and
	// kit/course's parameters together, and a steered one's track
	const json::Value* motion_of(const Entity &e)
	{
		if(!m_session.running)
			return nullptr;
		auto it = m_motions.find(e.id);
		return it == m_motions.end() ? nullptr : &it->second;
	}

	// A free root's wave and course, one table as move.lua's M.wave reads it (an
	// object; empty: neither moves it)
	json::Value timed_motion(const Entity &e)
	{
		json::Value m = json::object();
		if(!is_root(e) || !m_free_objects.count(e.id))
			return m;
		for(const Instance &in : e.comps){
			const json::Value &p = in.params;
			if(in.type == WAVE_TYPE){
				bool any = false;
				for(const char *k : {"wave_roll", "wave_pitch", "wave_yaw", "wave_heave"})
					any = any || (row_num(p, k) != 0 &&
							row_num(p, (ss_(k)+"_period").c_str()) > 0);
				if(any)
					for(json::Iterator it(p); it; ++it)
						m.set(it.key(), *it);
			} else if(in.type == COURSE_TYPE){
				const json::Value &c = p.get("course");
				if(row_num(p, "course_time") > 0 && pos_ok(c) && (c.at(0u).as_number() != 0
						|| c.at(1u).as_number() != 0 || c.at(2u).as_number() != 0)){
					m.set("course", c);
					m.set("course_time", p.get("course_time"));
				}
			}
		}
		return m;
	}

	// ---- [KIT_VEHICLE_MOVEMENTS] Steered movements. A movement on a free object's
	// root, or on an entity under one that moves (a turret, a car on a deck), is
	// stepped here, not by its holder's body: its input from the seat's holder (their
	// inputs as they come), else its instance's `throttle` and `steer` state (signals,
	// an NPC's), stepped ahead of the round's time by DRIVE_LEAD. Each batch ends in a
	// key {t ms, x, y, z, yaw, pitch, roll} (its place in its parent's frame), sent to
	// every client in its scene ("kit:track"); the pose at a time is the keys'
	// (move.lua's M.track_at, track_at() here: between two, or on from the last), so a
	// passenger's step and the server's of it pose the deck alike while the keys came
	// before the stamp. kit/wave goes on top as on any free object.
	// simplified: the holder's input takes effect as it comes, a network's delay and
	// DRIVE_LEAD after it was pressed; a stamped input applied at its stamp plus a
	// fixed delay is the upgrade if a driver's timing ever matters
	static constexpr double DRIVE_LEAD = 0.1; // s
	static constexpr double TRACK_KEEP = 3; // s of keys kept
	struct Drive
	{
		int64_t gen = 0;
		ss_ type, scene;
		json::Value params = json::object();
		json::Value state = json::object();
		double t = 0; // stepped to, the round's time (s)
		std::deque<std::array<double, 7>> keys;
		ss_ input; // the holder's last, fields of a Lua table
		bool held = false;
		bool failed = false;
		uint64_t deck = 0; // under a moving free object: steps on its boxes, in its frame
		double speed = 0, turn = 0; // m/s, degrees/s: the last batch's
		// [KIT_AIRSHIPS] a ship's: its parts as last logged, its speed as last logged
		ss_ parts;
		double logged_speed = -1;
	};
	std::map<uint64_t, Drive> m_drives;
	int64_t m_drive_gen = 0;
	std::map<uint64_t, json::Value> m_motions;
	// What each peer has of each track: its gen, its last key's time
	std::map<size_t, std::map<uint64_t, std::pair<int64_t, double>>> m_track_sent;
	// [KIT_VEHICLE_MOVEMENTS] c:set_param's: entity, type, parameter, value; play's
	std::map<uint64_t, std::map<ss_, json::Value>> m_play_params;

	// A track's pose at t (s); false: no key yet
	static bool track_at(const std::deque<std::array<double, 7>> &k, double t, double v[6])
	{
		if(k.empty())
			return false;
		const double ms = t * 1000;
		size_t lo = 0, hi = k.size() - 1;
		if(ms <= k[0][0]){
			for(int i = 0; i < 6; i++)
				v[i] = k[0][i + 1];
			return true;
		}
		while(lo < hi){
			const size_t mid = (lo + hi + 1) / 2;
			if(k[mid][0] <= ms)
				lo = mid;
			else
				hi = mid - 1;
		}
		const std::array<double, 7> *a = &k[lo], *b = nullptr;
		double u = 0;
		if(lo + 1 < k.size()){
			b = &k[lo + 1];
			u = (ms - (*a)[0]) / ((*b)[0] - (*a)[0]);
		} else if(lo > 0){
			b = &k[lo];
			a = &k[lo - 1];
			u = (std::min(ms, (*b)[0] + 500) - (*a)[0]) / ((*b)[0] - (*a)[0]);
		}
		for(int i = 0; i < 6; i++){
			if(!b){
				v[i] = (*a)[i + 1];
				continue;
			}
			double d = (*b)[i + 1] - (*a)[i + 1];
			if(i >= 3)
				d -= 360 * std::floor((d + 180) / 360);
			v[i] = (*a)[i + 1] + d * u;
		}
		return true;
	}

	// The motions of this tick: each free root's wave and course, each steered
	// movement's drive (made at its first tick in play, gone with it)
	void sync_motions()
	{
		m_motions.clear();
		if(!m_session.running){
			m_drives.clear();
			return;
		}
		for(auto &f : m_free_objects){
			auto it = m_entities.find(f.first);
			if(it == m_entities.end())
				continue;
			json::Value m = timed_motion(it->second);
			if(m.size())
				m_motions[f.first] = m;
		}
		// Steered: a movement on a free root, or under what moves (a parent first)
		std::map<uint64_t, int> memo;
		std::function<bool(uint64_t, int)> moving = [&](uint64_t id, int depth) -> bool {
			auto it = m_entities.find(id);
			if(it == m_entities.end() || depth > MAX_NEST + 2)
				return false;
			auto mi = memo.find(id);
			if(mi != memo.end())
				return mi->second != 0;
			const Entity &e = it->second;
			const bool steered = steerable(e) && (m_free_objects.count(e.id) ||
					moving(e.parent, depth + 1));
			const bool r = steered || m_motions.count(id) || moving(e.parent, depth + 1);
			memo[id] = steered ? 2 : r ? 1 : 0;
			return r;
		};
		for(auto &p : m_entities)
			moving(p.first, 0);
		for(auto it = m_drives.begin(); it != m_drives.end();){
			auto mi = memo.find(it->first);
			if(mi == memo.end() || mi->second != 2)
				it = m_drives.erase(it);
			else
				++it;
		}
		AtRest rest(m_at_rest);
		for(auto &mp : memo){
			if(mp.second != 2)
				continue;
			const Entity &e = m_entities[mp.first];
			Drive &d = m_drives[e.id];
			const Instance *mv = movement_on(e);
			if(!d.gen){
				d.gen = ++m_drive_gen;
				d.t = motion_t();
				json::Value pos = json::array();
				pos.append(e.pos[0]);
				pos.append(e.pos[1] - 0.5);
				pos.append(e.pos[2]);
				d.state.set("pos", pos);
				d.state.set("yaw", e.yaw);
				d.keys.push_back({{std::floor(d.t * 1000), e.pos[0], e.pos[1], e.pos[2],
						e.yaw, e.pitch, e.roll}});
				scene_of(e, &d.scene);
				log_i(MODULE, "Entity %s's %s steps in play", cs(itos(e.id)),
						cs(mv->type));
			}
			d.type = mv->type;
			d.params = move_params(e, *mv, d.scene);
			// [KIT_AIRSHIPS] a ship's parts summed for its movement
			if(hull_of(e) && m_free_objects.count(e.id)){
				const json::Value parts = ship_parts(e.id);
				d.params.set("parts", parts);
				const ss_ ps = parts.stringify();
				if(ps != d.parts){
					d.parts = ps;
					log_i(MODULE, "[KIT_AIRSHIPS] entity %s's parts: mass %g, thrust %g, "
							"lift %g, %i engines", cs(itos(e.id)), row_num(parts, "mass"),
							row_num(parts, "thrust"), row_num(parts, "lift"),
							(int)row_num(parts, "engines"));
				}
			}
			// On a free object's deck: the nearest moving free root it is under
			d.deck = 0;
			for(auto pi = m_entities.find(e.parent); pi != m_entities.end() &&
					!d.deck; pi = m_entities.find(pi->second.parent))
				if(m_free_objects.count(pi->first))
					d.deck = pi->first;
			json::Value m = m_free_objects.count(e.id) ? timed_motion(e) : json::object();
			m.set("track", (int64_t)e.id);
			double o[3], a, b, c;
			Turn pq;
			frame_of(e.parent, o, pq);
			pq.angles(a, b, c);
			json::Value fr = json::array();
			for(double x : {o[0], o[1], o[2], a, b, c})
				fr.append(x);
			m.set("frame", fr);
			m_motions[e.id] = m;
		}
	}

	// A movement's type stepped here: one with a step and a body, not kit/course
	// (a function of time)
	bool steerable(const Entity &e)
	{
		const Instance *mv = movement_on(e);
		return mv && !m_types[mv->type].decl.get("movement").get("timed").is_true();
	}

	// A movement's parameters, play's (c:set_param) over the row's, the scene's
	// gravity and sea level in
	json::Value move_params(const Entity &e, const Instance &in, const ss_ &scene,
			bool env = true)
	{
		json::Value p = params_of(in.type, &in);
		auto pp = m_play_params.find(e.id);
		if(pp != m_play_params.end())
			for(auto &kv : pp->second){
				const size_t at = kv.first.find('|');
				if(kv.first.substr(0, at) == in.type)
					p.set(kv.first.substr(at + 1), kv.second);
			}
		// (a body's gravity is body_movement()'s)
		const json::Value &g = p.get("gravity");
		const double f = env ? env_gravity(scene) : 1;
		if(g.is_number() && f != 1)
			p.set("gravity", g.as_number() * f);
		if(p.get("water_level").is_number() && jstr(p, "water") == "world")
			if(World *w = world_named(scene))
				p.set("water_level", w->wp.sea_level + 0.5);
		return json::load_string(p.stringify().c_str());
	}

	double motion_t()
	{
		if(!m_motion_base)
			m_motion_base = now_us();
		return (now_us() - m_motion_base) / 1e6;
	}

	static double swing(const json::Value &m, const char *k, double t)
	{
		const double period = row_num(m, (ss_(k)+"_period").c_str());
		return period > 0 ? row_num(m, k) * std::sin(2 *
				3.14159265358979323846 * t / period) : 0;
	}

	// v and q, an object's place and turn in its parent, as its motion has them at t
	void moved_local(const json::Value &m, double t, double v[3], Turn &q)
	{
		// [KIT_VEHICLE_MOVEMENTS] a steered one's place and turn: its track's
		if(m.get("track").is_number()){
			auto di = m_drives.find((uint64_t)m.get("track").as_number());
			double k[6];
			if(di != m_drives.end() && track_at(di->second.keys, t, k)){
				v[0] = k[0], v[1] = k[1], v[2] = k[2];
				q = Turn::of(k[3], k[4], k[5]);
			}
		}
		const Turn wave = Turn::of(swing(m, "wave_yaw", t), swing(m, "wave_pitch", t),
				swing(m, "wave_roll", t));
		double add[3] = {0, swing(m, "wave_heave", t), 0};
		const double ct = row_num(m, "course_time");
		const json::Value &c = m.get("course");
		if(ct > 0 && pos_ok(c)){
			double u = t / ct;
			u -= 2 * std::floor(u / 2);
			u = u > 1 ? 2 - u : u;
			for(unsigned k = 0; k < 3; k++)
				add[k] += c.at(k).as_number() * u;
		}
		const json::Value &pv = m.get("pivot");
		if(pos_ok(pv)){
			double turned[3] = {pv.at(0u).as_number(), pv.at(1u).as_number(),
					pv.at(2u).as_number()};
			wave.apply(turned);
			for(unsigned k = 0; k < 3; k++)
				add[k] += pv.at(k).as_number() - turned[k];
		}
		q.apply(add);
		for(int k = 0; k < 3; k++)
			v[k] += add[k];
		q = q * wave;
	}

	// While alive, world_of() says where things are at rest: what the replicated
	// nodes say and the rows' places. The clients turn the rest into now themselves
	struct AtRest
	{
		bool &flag;
		const bool was;
		AtRest(bool &f): flag(f), was(f){ flag = true; }
		~AtRest(){ flag = was; }
	};

	// An entity's place and turn in the world, moved by its motion and its parents'
	void world_of(const Entity &e, double w[3], Turn *wq = nullptr,
			int depth = 0)
	{
		double o[3];
		Turn pq;
		frame_of(e.parent, o, pq, depth);
		double v[3] = {e.pos[0], e.pos[1], e.pos[2]};
		Turn own = Turn::of(e);
		if(!m_at_rest)
			if(const json::Value *m = motion_of(e))
				moved_local(*m, motion_t(), v, own);
		pq.apply(v);
		for(int k = 0; k < 3; k++)
			w[k] = o[k] + v[k];
		if(wq)
			*wq = pq * own;
	}

	// What moves it: its own object's motion and those of the objects it is under,
	// each {x, y, z, yaw, pitch, roll (at rest, in the world), parameters}, the nearest
	// first (move.lua's M.link_at; empty: nothing)
	json::Value links_of(const Entity &e)
	{
		AtRest rest(m_at_rest);
		json::Value out = json::array();
		const Entity *at = &e;
		for(int depth = 0; at && depth <= MAX_NEST + 2; depth++){
			if(const json::Value *m = motion_of(*at)){
				double w[3], a, b, c;
				Turn q;
				world_of(*at, w, &q);
				q.angles(a, b, c);
				json::Value l = json::array();
				for(int k = 0; k < 3; k++)
					l.append(w[k]);
				l.append(a);
				l.append(b);
				l.append(c);
				l.append(*m);
				out.append(l);
			}
			auto it = m_entities.find(at->parent);
			at = it == m_entities.end() ? nullptr : &it->second;
		}
		return out;
	}

	bool moves(const Entity &e)
	{
		const Entity *at = &e;
		for(int depth = 0; at && depth <= MAX_NEST + 2; depth++){
			if(motion_of(*at))
				return true;
			auto it = m_entities.find(at->parent);
			at = it == m_entities.end() ? nullptr : &it->second;
		}
		return false;
	}

	// A place and turn in the world as an entity under `parent` has them
	void to_local(uint64_t parent, const double w[3], double l[3],
			const Turn *wq = nullptr, Turn *lq = nullptr)
	{
		double o[3];
		Turn pq;
		frame_of(parent, o, pq);
		for(int k = 0; k < 3; k++)
			l[k] = w[k] - o[k];
		const Turn inv = pq.inverse();
		inv.apply(l);
		if(wq && lq)
			*lq = inv * *wq;
	}

	// [KIT_FREE_ROTATION] Where a zone's or a region's box is: its corner
	// cell's middle and its turn. Level (no turn in the world) it stays on
	// voxel_p's cell
	void box_frame(const Entity &e, double o[3], Turn &q)
	{
		world_of(e, o, &q);
		if(q.none())
			for(int k = 0; k < 3; k++)
				o[k] = std::floor(o[k]);
	}

	// Whether a point (a cell's middle is its whole coordinates) is in a box
	// of n cells from that corner, along its turned axes
	static bool box_holds(const double o[3], const Turn &q, const int n[3],
			const double p[3])
	{
		double l[3] = {p[0] - o[0], p[1] - o[1], p[2] - o[2]};
		q.inverse().apply(l);
		for(int k = 0; k < 3; k++){
			const double c = std::floor(l[k] + 0.5);
			if(c < 0 || c >= n[k])
				return false;
		}
		return true;
	}

	// A row's "pos" and turn, given in the world, made its parent's
	// frame's (on the grid; nothing for a row under a scene)
	void localize(json::Value &row)
	{
		const uint64_t parent = (uint64_t)json::jint(row, "parent", 0);
		auto pi = m_entities.find(parent);
		if(!pos_ok(row.get("pos")) || pi == m_entities.end() ||
				!pi->second.has_pos)
			return;
		double w[3], l[3];
		for(unsigned k = 0; k < 3; k++)
			w[k] = row.get("pos").at(k).as_number();
		const Turn wq = Turn::of(row_num(row, "yaw"), row_num(row, "pitch"),
				row_num(row, "roll"));
		Turn lq;
		to_local(parent, w, l, &wq, &lq);
		json::Value pos = json::array();
		for(int k = 0; k < 3; k++)
			pos.append(grid(l[k]));
		row.set("pos", pos);
		row_turn(row, lq);
	}

	// An authored row as the editors get it: its place and turn the
	// world's
	json::Value world_row(const Entity &e)
	{
		json::Value j = entity_json(e);
		auto pi = m_entities.find(e.parent);
		if(!e.has_pos || pi == m_entities.end() || !pi->second.has_pos)
			return j;
		double w[3], a, b, c;
		Turn q;
		world_of(e, w, &q);
		q.angles(a, b, c);
		json::Value pos = json::array();
		for(int k = 0; k < 3; k++)
			pos.append(w[k]);
		j.set("pos", pos);
		j.set("yaw", a);
		j.del_key("pitch");
		j.del_key("roll");
		if(b != 0)
			j.set("pitch", b);
		if(c != 0)
			j.set("roll", c);
		return j;
	}

	// ---- [KIT_SYMMETRY] kit/symmetry (api.h): its sources' copies are
	// entities commit() keeps as their sources are, each under its source's
	// parent's copy (or the kit/symmetry), {"by", "member" (source * 8 +
	// slice), "source", "slice"} its built

	static const Instance *symmetry_in(const Entity &e)
	{
		for(const Instance &in : e.comps)
			if(in.type == SYMMETRY_TYPE)
				return &in;
		return nullptr;
	}

	// The kit/symmetry a copy is of (0: it is none)
	uint64_t copy_by(const Entity &e)
	{
		if(!e.built.is_object() || !e.built.get("slice").is_number())
			return 0;
		const uint64_t by = (uint64_t)json::jint(e.built, "by", 0);
		auto it = m_entities.find(by);
		return it != m_entities.end() && symmetry_in(it->second) ? by : 0;
	}
	uint64_t copy_by(uint64_t id)
	{
		auto it = m_entities.find(id);
		return it == m_entities.end() ? 0 : copy_by(it->second);
	}

	// The kit/symmetry, on, an entity is a source of (0: none; a copy is
	// none's)
	uint64_t sym_source(uint64_t id)
	{
		auto it = m_entities.find(id);
		if(it == m_entities.end() || copy_by(it->second))
			return 0;
		for(int i = 0; i <= MAX_NEST + 2; i++){
			it = m_entities.find(it->second.parent);
			if(it == m_entities.end() || it->first == 1)
				return 0;
			if(const Instance *in = symmetry_in(it->second))
				return in->params.get("on").is_true() ? it->first : 0;
		}
		return 0;
	}

	// Its slices on its scene's World
	bool sym_config(const Entity &s, symmetry::Config &c, ss_ &why)
	{
		const Instance *in = symmetry_in(s);
		ss_ scene;
		scene_of(s, &scene);
		const World *w = world_named(scene);
		if(!in || !w){
			why = "kit/symmetry: its scene has no World";
			return false;
		}
		const json::Value &p = in->params;
		return symmetry::make(jstr(p, "slices"), jstr(p, "angle"),
				jstr(p, "mode"), jstr(p, "slice"), w->wp.finite(), w->wp.x0(),
				w->wp.z0(), w->wp.width, w->wp.depth, c, why);
	}

	// A source's image by m: its place and turn in the world, its
	// instances' parameters (their space, api.h). simplified: a mirror's
	// image is turned from the source flipped along its x (z for a type
	// with a mirror of its own, kit/door's), its look not flipped; the
	// first box or cells parameter alone places it
	void sym_image(const Entity &e, const symmetry::Map &m, double w[3],
			Turn &q, sv_<json::Value> &params)
	{
		AtRest rest(m_at_rest);
		Turn sq;
		world_of(e, w, &sq);
		const int det = m.det();
		int fx = 1, fz = 1;
		const Instance *box_in = nullptr, *cells_in = nullptr;
		ss_ box_p, cells_p;
		bool own_mirror = false;
		for(const Instance &in : e.comps)
			for(auto &s : m_types[in.type].space){
				own_mirror = own_mirror || s.second == "mirror";
				if(s.second == "box" && !box_in){
					box_in = &in;
					box_p = s.first;
				}
				if(s.second == "cells" && !cells_in){
					cells_in = &in;
					cells_p = s.first;
				}
			}
		if(det < 0)
			(own_mirror ? fz : fx) = -1;
		const pv::Vector3DInt32 cell((int32_t)std::floor(w[0]),
				(int32_t)std::floor(w[1]), (int32_t)std::floor(w[2]));
		// A level box is on its corner cell (box_frame())
		if(box_in && sq.none()){
			w[0] = cell.getX();
			w[2] = cell.getZ();
		}
		m.apply(w[0], w[2]);
		// The turn seen in the mirror, then the turn m with the flip is
		const Turn c(sq.w, det * (m.a * sq.x + m.b * sq.z), det * sq.y,
				det * (m.c * sq.x + m.d * sq.z));
		q = c * Turn::of(std::atan2((double)m.b * fz, (double)m.d * fz) * 180 /
				3.14159265358979323846);
		// Flipped, a box from its corner reaches the other way
		if(det < 0 && box_in){
			int n[3];
			extent(box_in->params.get(box_p), n);
			double s[3] = {fx < 0 ? -(n[0] - 1.0) : 0, 0, fz < 0 ?
					-(n[2] - 1.0) : 0};
			q.apply(s);
			for(int k = 0; k < 3; k++)
				w[k] += s[k];
		}
		// A box of the world's cells: its image's lowest corner
		int cn[3] = {1, 1, 1}, lo[2] = {0, 0};
		if(cells_in){
			extent(cells_in->params.get(cells_p), cn);
			for(int k = 0; k < 4; k++){
				int x = cell.getX() + (k & 1 ? cn[0] - 1 : 0),
						z = cell.getZ() + (k & 2 ? cn[2] - 1 : 0);
				m.apply(x, z);
				lo[0] = k ? std::min(lo[0], x) : x;
				lo[1] = k ? std::min(lo[1], z) : z;
			}
			w[0] = lo[0];
			w[2] = lo[1];
		}
		for(int k = 0; k < 3; k++)
			w[k] += 0.0;
		params.clear();
		for(const Instance &in : e.comps){
			json::Value p = in.params.deepcopy();
			const Type &t = m_types[in.type];
			auto vec = [&](const ss_ &k, double v[3]){
				const json::Value &x = p.get(k);
				if(!pos_ok(x))
					return false;
				for(unsigned i = 0; i < 3; i++)
					v[i] = x.at(i).as_number();
				return true;
			};
			auto put = [&](const ss_ &k, const double v[3]){
				json::Value a = json::array();
				for(int i = 0; i < 3; i++)
					a.append(v[i] + 0.0);
				p.set(k, a);
			};
			for(auto &s : t.space){
				double v[3];
				if(s.second == "mirror"){
					if(det < 0)
						p.set(s.first, !p.get(s.first).is_true());
					continue;
				}
				if(!vec(s.first, v))
					continue;
				if(s.second == "world"){
					m.apply(v[0], v[2]);
				} else if(s.second == "offset" && det < 0){
					v[0] *= fx;
					v[2] *= fz;
				} else if(s.second == "rotation" && det < 0){
					const Turn r = Turn::of(v[1], v[0], v[2]);
					Turn(r.w, -fx * r.x, -r.y, -fz * r.z).angles(v[1], v[0], v[2]);
				} else if(s.second == "cells" && m.swaps()){
					std::swap(v[0], v[2]);
				} else {
					continue;
				}
				put(s.first, v);
			}
			// A pattern of the box's cells, each where its cell's image is
			if(&in == cells_in){
				const json::Value &decl = t.decl.get("params");
				for(json::Iterator it(decl); decl.is_object() && it; ++it){
					Pattern pt;
					ss_ why;
					if(jstr(*it, "type") != "voxels" || !p.get(it.key()).is_string() ||
							!parse_pattern(p.get(it.key()).as_string(), pt, why) ||
							pt.n[0] != cn[0] || pt.n[1] != cn[1] || pt.n[2] != cn[2])
						continue;
					int nn[3] = {cn[0], cn[1], cn[2]};
					if(m.swaps())
						std::swap(nn[0], nn[2]);
					sv_<ss_> cells(pt.cells.size());
					size_t i = 0;
					for(int y = 0; y < cn[1]; y++)
						for(int z = 0; z < cn[2]; z++)
							for(int x = 0; x < cn[0]; x++, i++){
								int gx = cell.getX() + x, gz = cell.getZ() + z;
								m.apply(gx, gz);
								cells[(size_t)(gx - lo[0]) + nn[0] * ((size_t)(gz - lo[1]) +
										(size_t)nn[2] * y)] = pt.names[pt.cells[i]];
							}
					p.set(it.key(), encode_pattern(nn, cells));
				}
			}
			params.push_back(p);
		}
	}

	// Each on kit/symmetry's copies made as its sources are now (and those
	// of one gone or off gone), the rows they were in `before`
	void symmetries(sv_<std::pair<uint64_t, json::Value>> *before)
	{
		std::map<uint64_t, sv_<uint64_t>> kids;
		sv_<uint64_t> syms;
		std::map<std::pair<uint64_t, int64_t>, uint64_t> have;
		sv_<uint64_t> stray;
		for(auto &p : m_entities){
			if(p.first != 1)
				kids[p.second.parent].push_back(p.first);
			if(symmetry_in(p.second))
				syms.push_back(p.first);
			const json::Value &bt = p.second.built;
			if(!bt.is_object() || !bt.get("slice").is_number())
				continue;
			const auto key = std::make_pair((uint64_t)json::jint(bt, "by", 0),
					json::jint(bt, "member", 0));
			if(!copy_by(p.second) || have.count(key))
				stray.push_back(p.first);
			else
				have[key] = p.first;
		}
		sv_<std::pair<uint64_t, json::Value>> out;
		std::set<std::pair<uint64_t, int64_t>> wanted;
		for(uint64_t sid : syms){
			const Entity &s = m_entities[sid];
			symmetry::Config c;
			ss_ why;
			if(!symmetry_in(s)->params.get("on").is_true())
				continue;
			if(!sym_config(s, c, why)){
				log_w(MODULE, "Entity %s's kit/symmetry copies nothing: %s",
						cs(itos(sid)), cs(why));
				continue;
			}
			// Its sources, those under others after them
			sv_<uint64_t> src = kids[sid];
			for(size_t i = 0; i < src.size(); i++){
				if(copy_by(src[i])){
					src.erase(src.begin() + i--);
					continue;
				}
				for(uint64_t k : kids[src[i]])
					src.push_back(k);
			}
			struct Img {
				uint64_t src = 0;
				size_t i = 0;
				double w[3] = {0, 0, 0};
				Turn q;
				sv_<json::Value> params;
			};
			// Each source's copy in each slice (itself where its image is it)
			std::map<std::pair<uint64_t, size_t>, uint64_t> copy;
			std::map<uint64_t, std::pair<std::array<double, 3>, Turn>> pose;
			sv_<Img> imgs;
			for(size_t i = 1; i < c.maps.size(); i++)
				for(uint64_t x : src){
					const Entity &e = m_entities[x];
					Img im;
					im.src = x;
					im.i = i;
					sym_image(e, c.maps[i], im.w, im.q, im.params);
					if(e.has_pos){
						AtRest rest(m_at_rest);
						double sw[3];
						Turn sq;
						world_of(e, sw, &sq);
						bool same = std::fabs(std::fabs(sq.w * im.q.w + sq.x * im.q.x +
								sq.y * im.q.y + sq.z * im.q.z) - 1) < 1e-9;
						for(int k = 0; k < 3; k++)
							same = same && std::fabs(sw[k] - im.w[k]) < 1e-6;
						for(size_t k = 0; k < e.comps.size() && same; k++)
							same = e.comps[k].params.stringify() ==
									im.params[k].stringify();
						if(same){
							copy[std::make_pair(x, i)] = x;
							continue;
						}
					}
					const int64_t member = (int64_t)x * 8 + (int64_t)i;
					wanted.insert(std::make_pair(sid, member));
					auto h = have.find(std::make_pair(sid, member));
					const uint64_t id = h != have.end() ? h->second : m_next_id++;
					copy[std::make_pair(x, i)] = id;
					pose[id] = std::make_pair(std::array<double, 3>{{im.w[0],
							im.w[1], im.w[2]}}, im.q);
					imgs.push_back(im);
				}
			for(const Img &im : imgs){
				const Entity &e = m_entities[im.src];
				const uint64_t id = copy[std::make_pair(im.src, im.i)];
				json::Value row = entity_json(e).deepcopy();
				row.set("id", (int64_t)id);
				row.del_key("prefab");
				auto pc = copy.find(std::make_pair(e.parent, im.i));
				const uint64_t parent = pc != copy.end() ? pc->second : e.parent;
				row.set("parent", (int64_t)parent);
				row.set("name", e.name+" (copy "+itos(im.i)+")");
				json::Value bt = json::object();
				bt.set("by", (int64_t)sid);
				bt.set("member", (int64_t)im.src * 8 + (int64_t)im.i);
				bt.set("source", (int64_t)im.src);
				bt.set("slice", (int64_t)im.i);
				row.set("built", bt);
				if(e.has_pos){
					double o[3], l[3];
					Turn pq;
					auto pp = pose.find(parent);
					if(pp != pose.end()){
						for(int k = 0; k < 3; k++)
							o[k] = pp->second.first[k];
						pq = pp->second.second;
					} else {
						AtRest rest(m_at_rest);
						frame_of(parent, o, pq);
					}
					for(int k = 0; k < 3; k++)
						l[k] = im.w[k] - o[k];
					pq.inverse().apply(l);
					json::Value pos = json::array();
					for(int k = 0; k < 3; k++)
						pos.append(grid(l[k]) + 0.0);
					row.set("pos", pos);
					row.del_key("pitch");
					row.del_key("roll");
					row_turn(row, pq.inverse() * im.q);
				}
				auto ex = m_entities.find(id);
				json::Value cs_ = json::array();
				for(size_t k = 0; k < e.comps.size(); k++){
					const Instance &in = e.comps[k];
					json::Value cj = row.get("components").at((unsigned)k).deepcopy();
					json::Value p = im.params[k];
					// Its entities and links: the same slice's copies of
					// sources, the others the same
					const json::Value &decl = m_types[in.type].decl.get("params");
					for(json::Iterator it(decl); decl.is_object() && it; ++it){
						if(jstr(*it, "type") != "entity" || !p.get(it.key()).is_number())
							continue;
						auto to = copy.find(std::make_pair((uint64_t)
								p.get(it.key()).as_number(), im.i));
						if(to != copy.end())
							p.set(it.key(), (int64_t)to->second);
					}
					json::Value ls = json::array();
					const json::Value &was = cj.get("links");
					for(unsigned m = 0; m < was.size(); m++){
						json::Value l = was.at(m).deepcopy();
						auto to = copy.find(std::make_pair((uint64_t)json::jint(l,
								"to", 0), im.i));
						if(to != copy.end())
							l.set("to", (int64_t)to->second);
						ls.append(l);
					}
					cj.set("links", ls);
					// What a builder set on this copy stays its own
					cj.del_key("overrides");
					if(ex != m_entities.end())
						for(const Instance &xin : ex->second.comps){
							if(xin.type != in.type || xin.overrides.empty())
								continue;
							json::Value ov = json::array();
							for(const ss_ &o : xin.overrides){
								p.set(o, xin.params.get(o));
								ov.append(o);
							}
							cj.set("overrides", ov);
						}
					cj.set("params", p);
					cs_.append(cj);
				}
				row.set("components", cs_);
				// (compared as entity_json writes it: the row's keys are in
				// another order, which made every edit make every copy again)
				Entity ne;
				ss_ nwhy;
				if(ex == m_entities.end() || !entity_from_json(row, ne, nwhy) ||
						entity_json(ex->second).stringify() !=
						entity_json(ne).stringify()){
					out.push_back(std::make_pair(id, row));
					double a, b, cr;
					im.q.angles(a, b, cr);
					log_v(MODULE, "kit/symmetry %s: copy %s of %s, slice %zu: at "
							"%.4f,%.4f,%.4f turned %.4f,%.4f,%.4f: %s", cs(itos(sid)),
							cs(itos(id)), cs(itos(im.src)), im.i, im.w[0], im.w[1],
							im.w[2], a, b, cr, cs(cs_.stringify()));
				}
			}
		}
		for(auto &h : have)
			if(!wanted.count(h.first))
				out.push_back(std::make_pair(h.second, json::null()));
		for(uint64_t id : stray)
			out.push_back(std::make_pair(id, json::null()));
		if(out.empty())
			return;
		for(auto &o : out)
			if(!o.second.is_null())
				m_pending_ids.insert(o.first);
		size_t made = 0, gone = 0;
		std::set<uint64_t> had;
		if(before)
			for(auto &b : *before)
				had.insert(b.first);
		for(auto &o : ordered(out)){
			auto it = m_entities.find(o.first);
			if(before && had.insert(o.first).second)
				before->push_back(std::make_pair(o.first, it == m_entities.end() ?
						json::null() : entity_json(it->second)));
			// One under a copy gone is gone with it
			if(o.second.is_null() && it == m_entities.end())
				continue;
			apply(o.first, o.second);
			(o.second.is_null() ? gone : made)++;
		}
		log_i(MODULE, "kit/symmetry: %zu copies made or changed, %zu gone",
				made, gone);
	}

	// Whether an edit may be: a copy changes only by what a builder sets
	// on it (an override; its source's edits make the rest) and goes only
	// with its kit/symmetry, nothing goes under a copy or links to one
	// newly, a source of an on kit/symmetry stays in its authored slice
	// (kit/wave none); a kit/symmetry stands at its World's middle (put
	// there), level, under its scene, one a scene
	bool sym_check(sv_<std::pair<uint64_t, json::Value>> &change, ss_ &why)
	{
		std::set<uint64_t> gone;
		std::map<uint64_t, json::Value> rows;
		for(auto &c : change)
			if(c.second.is_null())
				gone.insert(c.first);
		auto bare = [](const json::Value &r0){
			json::Value r = r0.deepcopy();
			r.del_key("built");
			json::Value cs_ = json::array();
			const json::Value &was = r.get("components");
			for(unsigned k = 0; k < was.size(); k++){
				json::Value cj = was.at(k).deepcopy();
				cj.del_key("params");
				cj.del_key("overrides");
				cj.del_key("version");
				cs_.append(cj);
			}
			r.set("components", cs_);
			return r.stringify();
		};
		auto has_sym = [&](const json::Value &row, bool *on){
			const json::Value &cs_ = row.get("components");
			for(unsigned k = 0; k < cs_.size(); k++)
				if(full_type(jstr(cs_.at(k), "type")) == SYMMETRY_TYPE){
					if(on)
						*on = cs_.at(k).get("params").get("on").is_true();
					return true;
				}
			return false;
		};
		for(auto &c : change){
			auto ei = m_entities.find(c.first);
			const uint64_t by = ei == m_entities.end() ? 0 : copy_by(ei->second);
			if(by){
				if(c.second.is_null() ? !gone.count(by) :
						bare(c.second) != bare(entity_json(ei->second))){
					why = "entity "+itos(c.first)+" is kit/symmetry "+itos(by)+
							"'s copy of entity "+itos((uint64_t)json::jint(
							ei->second.built, "source", 0))+": edit its source "
							"(only parameters set on a copy are its own)";
					return false;
				}
				if(!c.second.is_null())
					rows[c.first] = c.second;
				continue;
			}
			if(c.second.is_null())
				continue;
			json::Value &row = c.second;
			// A copy's duplicate is no copy
			if(row.get("built").is_object() && row.get("built").get("slice").
					is_number())
				row.del_key("built");
			const uint64_t parent = (uint64_t)json::jint(row, "parent", 1);
			if(copy_by(parent)){
				why = "entity "+itos(parent)+" is a kit/symmetry copy: nothing "
						"goes under it (put it under the source)";
				return false;
			}
			const json::Value &cs_ = row.get("components");
			for(unsigned k = 0; k < cs_.size(); k++){
				const json::Value &ls = cs_.at(k).get("links");
				for(unsigned m = 0; m < ls.size(); m++){
					const uint64_t to = (uint64_t)json::jint(ls.at(m), "to", 0);
					if(!copy_by(to))
						continue;
					bool had = false;
					if(ei != m_entities.end())
						for(const Instance &in : ei->second.comps)
							for(const Link &l : in.links)
								had = had || l.to == to;
					if(!had){
						why = "entity "+itos(to)+" is a kit/symmetry copy: link "
								"to its source (a link from outside reaches each "
								"copy)";
						return false;
					}
				}
			}
			bool on = false;
			if(has_sym(row, &on)){
				json::Value pos = json::array();
				pos.append(0.0);
				pos.append(pos_ok(row.get("pos")) ? row.get("pos").at(1u) :
						json::Value(0.0));
				pos.append(0.0);
				row.set("pos", pos);
				row.set("yaw", 0.0);
				row.del_key("pitch");
				row.del_key("roll");
				auto pi = m_entities.find(parent);
				if(pi == m_entities.end() || pi->second.kind != "scene"){
					why = "kit/symmetry goes right under its scene";
					return false;
				}
				for(auto &p : m_entities)
					if(p.first != c.first && p.second.parent == parent &&
							!gone.count(p.first) && symmetry_in(p.second)){
						why = "its scene has kit/symmetry "+itos(p.first)+
								" already: one a scene";
						return false;
					}
				Entity n;
				symmetry::Config cf;
				if(on && (!entity_from_json(row, n, why) || !sym_config(n, cf,
						why)))
					return false;
			}
			rows[c.first] = row;
		}
		// The sources as the edit leaves them: each row's under an on
		// kit/symmetry, and those under them
		auto parent_of = [&](uint64_t id) -> uint64_t {
			auto r = rows.find(id);
			if(r != rows.end())
				return (uint64_t)json::jint(r->second, "parent", 1);
			auto it = m_entities.find(id);
			return it == m_entities.end() ? 0 : it->second.parent;
		};
		std::map<uint64_t, sv_<uint64_t>> kids;
		for(auto &p : m_entities)
			if(p.first != 1 && !rows.count(p.first) && !gone.count(p.first))
				kids[p.second.parent].push_back(p.first);
		for(auto &r : rows)
			kids[parent_of(r.first)].push_back(r.first);
		sv_<uint64_t> look;
		for(auto &r : rows)
			look.push_back(r.first);
		std::set<uint64_t> seen;
		for(size_t i = 0; i < look.size(); i++)
			if(seen.insert(look[i]).second)
				for(uint64_t k : kids[look[i]])
					look.push_back(k);
		// A place in the world as the edit leaves it (simplified: a look's
		// offset, a mover's out, left out)
		std::function<bool(uint64_t, double *, Turn &, int)> at =
				[&](uint64_t id, double *w, Turn &q, int d){
			double v[3] = {0, 0, 0};
			Turn own;
			auto r = rows.find(id);
			if(r != rows.end()){
				const json::Value &p = r->second.get("pos");
				if(!pos_ok(p))
					return false;
				for(unsigned k = 0; k < 3; k++)
					v[k] = p.at(k).as_number();
				own = Turn::of(row_num(r->second, "yaw"), row_num(r->second,
						"pitch"), row_num(r->second, "roll"));
			} else {
				auto it = m_entities.find(id);
				if(it == m_entities.end() || !it->second.has_pos)
					return false;
				for(int k = 0; k < 3; k++)
					v[k] = it->second.pos[k];
				own = Turn::of(it->second);
			}
			double o[3] = {0, 0, 0};
			Turn pq;
			if(d < MAX_NEST + 2)
				at(parent_of(id), o, pq, d + 1);
			pq.apply(v);
			for(int k = 0; k < 3; k++)
				w[k] = o[k] + v[k];
			q = pq * own;
			return true;
		};
		std::map<uint64_t, std::pair<bool, symmetry::Config>> cfgs;
		for(uint64_t id : seen){
			// Its kit/symmetry, if on
			uint64_t sid = 0, a = id;
			bool is_copy = copy_by(id) != 0;
			for(int i = 0; i <= MAX_NEST + 2 && a > 1 && !sid; i++){
				a = parent_of(a);
				auto r = rows.find(a);
				auto it = m_entities.find(a);
				if(r != rows.end() ? has_sym(r->second, nullptr) :
						it != m_entities.end() && symmetry_in(it->second))
					sid = a;
			}
			if(!sid || is_copy || gone.count(id))
				continue;
			if(!cfgs.count(sid)){
				auto r = rows.find(sid);
				Entity n;
				bool on = false;
				ss_ w2;
				if(r != rows.end()){
					has_sym(r->second, &on);
					if(on && !entity_from_json(r->second, n, w2))
						on = false;
				} else {
					n = m_entities[sid];
					on = symmetry_in(n)->params.get("on").is_true();
				}
				symmetry::Config cf;
				cfgs[sid] = std::make_pair(on && sym_config(n, cf, w2), cf);
			}
			const auto &cf = cfgs[sid];
			if(!cf.first)
				continue;
			auto r = rows.find(id);
			const json::Value row = r != rows.end() ? r->second :
					entity_json(m_entities[id]);
			const json::Value &cs_ = row.get("components");
			for(unsigned k = 0; k < cs_.size(); k++)
				if(full_type(jstr(cs_.at(k), "type")) == WAVE_TYPE){
					why = "entity "+itos(id)+": a moving object (kit/wave) is "
							"not copied by kit/symmetry "+itos(sid)+": put it "
							"outside it";
					return false;
				}
			double w[3];
			Turn q;
			if(at(id, w, q, 0) && !cf.second.in(w[0], w[2])){
				char b[64];
				snprintf(b, sizeof b, "%g, %g", w[0], w[2]);
				why = "entity "+itos(id)+" at "+b+" is outside kit/symmetry "+
						itos(sid)+"'s authored slice "+cf.second.slice;
				return false;
			}
		}
		return true;
	}

	// ---- [KIT_SYMMETRY] The voxels, the samples and the decorations
	// (api.h): a builder's edit in the authored slice written into each
	// other slice too, one undo; elsewhere refused, and what a brush
	// writes past a seam cut (put back as its source's image is). The
	// whole authored slice copied over the others as it is turned on and
	// after each regeneration; at Play only compared

	// The on kit/symmetry of a scene's World and its slices (nullptr: none)
	const Entity *sym_scene(main_context::SceneReference ref,
			symmetry::Config &c)
	{
		if(!ref)
			return nullptr;
		for(auto &p : m_entities){
			const Instance *in = symmetry_in(p.second);
			ss_ why;
			if(in && in->params.get("on").is_true() && scene_of(p.second) == ref &&
					sym_config(p.second, c, why))
				return &p.second;
		}
		return nullptr;
	}

	// A cell's state as its image by m: a shape's facing turned
	static uint32_t sym_word(voxelworld::Instance *w, uint32_t word,
			const symmetry::Map &m)
	{
		const interface::VoxelFormat &f = w->get_voxel_reg()->get_format();
		if(!f.param.bound())
			return word;
		const interface::VoxelDefinition *d = w->get_voxel_reg()->get(
				f.id.get(word));
		const ss_ name = d ? d->name.block_name : ss_();
		if(!is_shape(name))
			return word;
		const size_t colon = name.rfind(':');
		const bool corner = name.compare(colon + 1, ss_::npos, "inner_stair") == 0 ||
				name.compare(colon + 1, ss_::npos, "outer_stair") == 0;
		f.param.set(word, symmetry::facing(f.param.get(word), m, corner));
		return word;
	}

	// The cells an edit wrote (in w, a scene's): each authored one's
	// images written as it is, each one past a seam its source's image (or
	// as it was, `before`'s, with none); the cells' old states into
	// `before` (the edit's undo) the first time. The images written
	size_t sym_write(voxelworld::Instance *w, main_context::SceneReference ref,
			const symmetry::Config &c, const sv_<pv::Vector3DInt32> &wrote,
			std::map<std::tuple<int, int, int>, uint32_t> *before,
			const ss_ &who)
	{
		size_t n = 0;
		auto put = [&](const pv::Vector3DInt32 &q, uint32_t word){
			uint32_t old = 0;
			if(!hm_section(w, q) || !voxel_id(w, q, old) || old == word)
				return;
			if(before)
				before->emplace(std::make_tuple(q.getX(), q.getY(), q.getZ()), old);
			set_id(w, q, word);
			mark(w, ref, q, 'k', who);
			n++;
		};
		sv_<pv::Vector3DInt32> cut;
		for(const pv::Vector3DInt32 &p : wrote){
			if(!c.editable(p.getX(), p.getZ())){
				cut.push_back(p);
				continue;
			}
			uint32_t word = 0;
			if(!voxel_id(w, p, word))
				continue;
			for(size_t i = 1; i < c.maps.size(); i++){
				int x = p.getX(), z = p.getZ();
				c.maps[i].apply(x, z);
				if(x != p.getX() || z != p.getZ())
					put(pv::Vector3DInt32(x, p.getY(), z), sym_word(w, word,
							c.maps[i]));
			}
		}
		for(const pv::Vector3DInt32 &p : cut){
			int sx, sz;
			size_t i;
			uint32_t word = 0;
			if(c.source(p.getX(), p.getZ(), sx, sz, i)){
				if(i && voxel_id(w, pv::Vector3DInt32(sx, p.getY(), sz), word))
					put(p, sym_word(w, word, c.maps[i]));
			} else if(before){
				auto b = before->find(std::make_tuple(p.getX(), p.getY(), p.getZ()));
				if(b != before->end() && voxel_id(w, p, word) && word != b->second){
					set_id(w, p, b->second);
					mark(w, ref, p, 'k', who);
				}
			}
		}
		return n;
	}

	// What the copy over the other slices writes (or, `write` false, would):
	// each loaded cell of them its source's image; on a heightmap each
	// sample and the decorations (those outside the authored slice gone,
	// each authored one's images put). The old ones into c (an undo's)
	struct SymCounts
	{
		size_t cells = 0, samples = 0, decor = 0;
		ss_ text() const
		{
			return itos(cells)+" cells, "+itos(samples)+" samples, "+
					itos(decor)+" decorations";
		}
	};
	SymCounts sym_copy(main_context::SceneReference ref,
			const symmetry::Config &cf, bool write, Change *c, const ss_ &who,
			bool decor_only = false)
	{
		WorldScope ws(m_w, world_at(ref));
		SymCounts n;
		if(!decor_only)
			voxelworld::access(m_server, ref, [&](voxelworld::Instance *w){
			const pv::Vector3DInt16 ss = w->get_section_size_voxels();
			for(const pv::Vector3DInt16 &s : w->get_loaded_sections())
				for(int y = 0; y < ss.getY(); y++)
					for(int z = 0; z < ss.getZ(); z++)
						for(int x = 0; x < ss.getX(); x++){
							const pv::Vector3DInt32 p(s.getX() * ss.getX() + x,
									s.getY() * ss.getY() + y, s.getZ() * ss.getZ() + z);
							int sx, sz;
							size_t i;
							uint32_t src = 0, cur = 0;
							if(!cf.in_map(p.getX(), p.getZ()) || !cf.source(p.getX(),
									p.getZ(), sx, sz, i) || !i || !voxel_id(w,
									pv::Vector3DInt32(sx, p.getY(), sz), src) ||
									!voxel_id(w, p, cur))
								continue;
							const uint32_t want = sym_word(w, src, cf.maps[i]);
							if(want == cur)
								continue;
							n.cells++;
							if(!write)
								continue;
							if(c)
								c->cells.emplace(std::make_tuple(p.getX(), p.getY(),
										p.getZ()), cur);
							set_id(w, p, want);
							mark(w, ref, p, 'k', who);
						}
		});
		if(!m_w || !m_w->wp.heightmap())
			return n;
		if(!decor_only)
			heightmap::access(m_server, m_w->world_scene, [&](heightmap::Instance *map){
			const int ox = hm_ox(map), oz = hm_oz(map);
			for(int z = oz; z < oz + map->samples_z(); z++)
				for(int x = ox; x < ox + map->samples_x(); x++){
					int sx, sz;
					size_t i;
					if(!cf.in_map(x, z) || !cf.source(x, z, sx, sz, i) || !i ||
							sx < ox || sz < oz || sx >= ox + map->samples_x() ||
							sz >= oz + map->samples_z())
						continue;
					const float h = map->get_height(sx - ox, sz - oz);
					const heightmap::Weights wt = map->get_weights(sx - ox, sz - oz);
					if(h == map->get_height(x - ox, z - oz) &&
							wt == map->get_weights(x - ox, z - oz))
						continue;
					n.samples++;
					if(!write)
						continue;
					if(c)
						c->samples.emplace(std::make_pair(x, z), std::make_pair(
								map->get_height(x - ox, z - oz),
								map->get_weights(x - ox, z - oz)));
					map->set_height(x - ox, z - oz, h);
					map->set_weights(x - ox, z - oz, wt);
					hm_mark(x, z, true, h, wt, c);
				}
		});
		// The decorations: an authored one's images where none is
		auto same = [](const Decor &a, const Decor &b){
			return a.structure == b.structure && std::fabs(a.x - b.x) < 0.01f &&
					std::fabs(a.z - b.z) < 0.01f && std::fabs(a.yaw - b.yaw) < 0.01f;
		};
		sv_<Decor> want;
		for(auto &d : m_w->decor){
			if(!cf.in(d.second.x, d.second.z))
				continue;
			for(size_t i = 1; i < cf.maps.size(); i++){
				Decor im = d.second;
				im.node = 0;
				cf.maps[i].apply(im.x, im.z);
				const symmetry::Map &m = cf.maps[i];
				const Turn q = Turn::of(d.second.yaw);
				im.yaw = (float)(Turn(q.w, 0, m.det() * q.y, 0) * Turn::of(
						std::atan2((double)m.b, (double)m.d) * 180 /
						3.14159265358979323846)).yaw();
				if(!same(im, d.second))
					want.push_back(im);
			}
		}
		sv_<uint64_t> gone;
		std::set<size_t> there;
		for(auto &d : m_w->decor){
			if(cf.in(d.second.x, d.second.z))
				continue;
			bool kept = false;
			for(size_t k = 0; k < want.size() && !kept; k++)
				if(!there.count(k) && same(want[k], d.second)){
					there.insert(k);
					kept = true;
				}
			if(!kept)
				gone.push_back(d.first);
		}
		n.decor = gone.size() + want.size() - there.size();
		if(!write)
			return n;
		for(uint64_t id : gone){
			if(c)
				c->decor_gone.push_back(m_w->decor[id]);
			remove_decor(id);
		}
		for(size_t k = 0; k < want.size(); k++){
			if(there.count(k))
				continue;
			const uint64_t id = add_decor(want[k].structure, want[k].x, want[k].y,
					want[k].z, want[k].yaw);
			m_w->decor[id].hand = want[k].hand;
			if(c)
				c->decor.push_back(id);
		}
		save_decor();
		hm_edits_save();
		return n;
	}

	// The entities of its scene outside it, in the other slices: single,
	// unlike the slices (a warning's text; "": none)
	ss_ sym_parity_entities(const Entity &s, const symmetry::Config &cf)
	{
		const main_context::SceneReference ref = scene_of(s);
		size_t n = 0;
		ss_ ids;
		AtRest rest(m_at_rest);
		for(auto &p : m_entities){
			const Entity &e = p.second;
			if(!e.has_pos || !e.kind.empty() || copy_by(e) || sym_source(p.first) ||
					p.first == s.id || scene_of(e) != ref)
				continue;
			double w[3];
			world_of(e, w);
			if(cf.in(w[0], w[2]))
				continue;
			if(n++ < 8)
				ids += (ids.empty() ? "" : ", ")+itos(p.first);
		}
		return n ? itos(n)+" entities outside it in the other slices, not copied ("+
				ids+(n > 8 ? ", ..." : "")+")" : ss_();
	}

	// The editor's view of its scene's kit/symmetry ([KIT_SYMMETRY] stage 3):
	// {id, on, why (what its slices can't be), slice, maps [[a, b, c, d]],
	// planes [[a, b]] (the authored slice: a x + b z >= 0), x0, z0, width,
	// depth, parity (the entities outside it in the other slices)}
	json::Value sym_state(const ss_ &scene)
	{
		json::Value a = json::array();
		auto si = m_host.scenes.find(scene);
		if(si == m_host.scenes.end())
			return a;
		for(auto &p : m_entities){
			const Instance *in = symmetry_in(p.second);
			if(!in || scene_of(p.second) != si->second)
				continue;
			json::Value o = json::object();
			o.set("id", (int64_t)p.first);
			const bool on = in->params.get("on").is_true();
			o.set("on", on);
			symmetry::Config c;
			ss_ why;
			if(!sym_config(p.second, c, why)){
				o.set("why", why);
				a.append(o);
				continue;
			}
			o.set("slice", c.slice);
			json::Value maps = json::array(), planes = json::array();
			for(const symmetry::Map &m : c.maps){
				json::Value v = json::array();
				for(int k : {m.a, m.b, m.c, m.d})
					v.append((int64_t)k);
				maps.append(v);
			}
			for(auto &pl : c.planes()){
				json::Value v = json::array();
				v.append((int64_t)pl.first);
				v.append((int64_t)pl.second);
				planes.append(v);
			}
			o.set("maps", maps);
			o.set("planes", planes);
			o.set("x0", (int64_t)c.x0);
			o.set("z0", (int64_t)c.z0);
			o.set("width", (int64_t)c.width);
			o.set("depth", (int64_t)c.depth);
			if(on)
				o.set("parity", sym_parity_entities(p.second, c));
			a.append(o);
		}
		return a;
	}

	// Whether an entity's place in the tree may be: under one that is
	// there; one with a position under a scene or a positioned entity (no
	// player); no loop, MAX_NEST levels under its scene at most. Its own
	// id may be in the tree already (an edit of it)
	bool nest_ok(const Entity &n, ss_ &why)
	{
		auto pi = m_entities.find(n.parent);
		if(n.id == 1)
			return true;
		if(pi == m_entities.end()){
			why = "entity "+itos(n.id)+": no parent "+itos(n.parent);
			return false;
		}
		if(n.has_pos && pi->second.kind != "scene" && (!pi->second.has_pos ||
				!pi->second.kind.empty())){
			why = "entity "+itos(n.id)+"'s parent "+itos(n.parent)+
					" is no scene and has no position";
			return false;
		}
		uint64_t id = n.parent;
		for(int i = 0; id != 1; i++){
			auto it = m_entities.find(id);
			if(id == n.id || it == m_entities.end() || i > MAX_NEST + 2){
				why = "entity "+itos(n.id)+"'s parent "+itos(n.parent)+
						(id == n.id ? " is under it" : it == m_entities.end() ?
						" is not under the root" : " is too deep");
				return false;
			}
			id = it->second.parent;
		}
		return true;
	}

	// An entity's node at its place in the world, and those under it
	void place_nodes(uint64_t id, int depth = 0)
	{
		auto it = m_entities.find(id);
		if(it == m_entities.end())
			return;
		Entity &e = it->second;
		if(e.node){
			double w[3];
			Turn q;
			{
				// [KIT_MOVING_OBJECTS] a client moves it from there
				AtRest rest(m_at_rest);
				world_of(e, w, &q);
			}
			main_context::access(m_server, scene_of(e), [&](magic::Scene *sc){
				magic::Node *n = sc->GetNode(e.node);
				if(n){
					n->SetPosition(magic::Vector3(w[0], w[1], w[2]));
					n->SetRotation(q.q());
				}
			});
		}
		if(depth > MAX_NEST || e.kind == "player")
			return;
		for(auto &p : m_entities)
			if(p.second.parent == id && p.first != id && p.second.has_pos)
				place_nodes(p.first, depth + 1);
	}

	// The cell an entity is in, the world's
	pv::Vector3DInt32 voxel_p(const Entity &e)
	{
		double w[3];
		world_of(e, w);
		return pv::Vector3DInt32((int32_t)std::floor(w[0]),
				(int32_t)std::floor(w[1]), (int32_t)std::floor(w[2]));
	}

	// An extent parameter's cells each way: whole numbers, 1...max
	static void extent(const json::Value &v, int out[3],
			int max = MAX_EXTENT)
	{
		for(unsigned k = 0; k < 3; k++){
			const double d = v.at(k).is_number() ? v.at(k).as_number() : 1;
			out[k] = (int)std::max(1.0, std::min((double)max,
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
		if(t == "sound"){
			// [KIT_SOUNDS] a project's sound's name ("": none; one not here
			// plays nothing)
			if(!v.is_string() || v.as_string().size() > 129 ||
					(!v.as_string().empty() && (!item_ok(v.as_string()) ||
					v.as_string().find('/') == ss_::npos)))
				return "a sound's name, <author>/<name>";
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
		const json::Value &bt = j.get("built");
		if(bt.is_object() && json::jint(bt, "by", 0) > 1 &&
				json::jint(bt, "member", 0) > 0)
			e.built = bt.deepcopy();
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
		if(j.get("pitch").is_number())
			e.pitch = norm_yaw(j.get("pitch").as_number());
		if(j.get("roll").is_number())
			e.roll = norm_yaw(j.get("roll").as_number());
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
					// (use: Kit's, gone with a type no longer usable; own_look
					// with one that has no look)
					if((object || it.key() == "use" ||
							it.key() == "own_look") &&
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
		// [KIT_NO_WORLD_TYPES] A position it was given goes (an old save's, a
		// prefab's)
		if(no_position(e)){
			e.has_pos = false;
			e.pos[0] = e.pos[1] = e.pos[2] = e.yaw = e.pitch = e.roll = 0;
		}
		// [KIT_TEMPLATE_ROUGH_EDGES] The World has no position: one given
		// (a hand-written composition's) goes, said
		for(const Instance &in : e.comps)
			if(e.has_pos && e.kind.empty() && m_types[in.type].world){
				log_w(MODULE, "Entity %s's %s has a position: dropped (the World "
						"has none)", cs(itos(e.id)), cs(in.type));
				e.has_pos = false;
				e.pos[0] = e.pos[1] = e.pos[2] = e.yaw = e.pitch = e.roll = 0;
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
		if(!e.built.is_undefined())
			j.set("built", e.built);
		if(e.has_pos){
			json::Value pos = json::array();
			for(int k = 0; k < 3; k++)
				pos.append(e.pos[k]);
			j.set("pos", pos);
			if(e.yaw != 0)
				j.set("yaw", e.yaw);
			if(e.pitch != 0)
				j.set("pitch", e.pitch);
			if(e.roll != 0)
				j.set("roll", e.roll);
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

	// [KIT_TEMPLATES] Host::opens_in_edit's first builder is yet to come
	bool m_open_tools = false;

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
			// [KIT_NESTING] under one that is there, a positioned one under
			// a scene or a positioned entity, no loop
			if(!nest_ok(e, why))
				return false;
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

	// What play moved goes back to: its row's place and turn
	static std::array<double, 6> home_of(const Entity &e)
	{
		return {{e.pos[0], e.pos[1], e.pos[2], e.yaw, e.pitch, e.roll}};
	}
	static void home_put(Entity &e, const std::array<double, 6> &h)
	{
		for(int k = 0; k < 3; k++)
			e.pos[k] = h[k];
		e.yaw = h[3];
		e.pitch = h[4];
		e.roll = h[5];
	}

	// The composition: the authored entities, those play removed too.
	// world: [KIT_NESTING] each one's place and turn the world's (the
	// editors'), else its parent's frame's (the save's)
	json::Value authored_json(bool world = false)
	{
		std::map<uint64_t, const Entity*> all;
		for(auto &p : m_entities)
			if(p.first != 1 && authored(p.second))
				all[p.first] = &p.second;
		for(auto &r : m_removed)
			all[r.first] = &r.second.e;
		json::Value c = json::object();
		json::Value es = json::array();
		for(auto &p : all){
			// What play moved (c:move, a vehicle) at its place before:
			// the round's place is never the composition's
			// simplified: one under a moved one is placed (world) in the
			// moved one's frame
			auto h = m_seat_home.find(p.first);
			Entity e = *p.second;
			if(h != m_seat_home.end())
				home_put(e, h->second);
			es.append(world ? world_row(e) : entity_json(e));
		}
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
		const int64_t now = now_us();
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
	void runtime_from(Instance &in, const json::Value &s)
	{
		const json::Value &st = s.get("state");
		if(st.is_object())
			for(json::Iterator it(st); it; ++it)
				in.state.set(it.key(), *it);
		in.disabled = jstr(s, "disabled");
		const int64_t now = now_us();
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

	void on_shutdown()
	{
		if(!m_hosted)
			return;
		size_t n = 0;
		auto save = [&](){
			n += m_runtime_dirty + m_marks_dirty.size();
			save_runtime();
			save_marks();
		};
		save();
		sv_<uint64_t> ids;
		for(auto &s : m_sessions)
			ids.push_back(s.first);
		for(uint64_t id : ids){
			SessionScope sc(*this, id);
			save();
		}
		if(n)
			log_i(MODULE, "Kit: saved at the stop: %zu rows changed since the"
					" last tick (the runtime, marks)", n);
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
		// [KIT_PREFAB_ROOT] the editor's place of a prefab makes these
		if(t == PREFAB_ROOT)
			return;
		if(ty.player){
			if(starting)
				m_player_types.push_back(t);
			if(ty.placeable)
				m_palette.insert(t);
		} else if(ty.world && m_host.world_scene.empty()){
			// [KIT] stage 4e: no World where the app has none
		} else if(!m_host.controls && (ty.decl.get("controls").is_true() ||
				ty.decl.get("movement").is_object() || ty.decl.get("seat").is_true())){
			// [KIT] stage 4h: the controls, the movements and the seats where
			// the app has Kit's controls
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
		m_kit_store = m_store;
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
		load_items();
		load_sounds();
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
			// [KIT_TEMPLATES] A template's first start: Stopped, the first
			// builder to come in the tools
			m_session.running = !(first && host.opens_in_edit);
			m_open_tools = !m_session.running;
			log_i(MODULE, "%s", m_open_tools ? "A template: Stopped, in edit mode" :
					had_runtime ? "A save from before Play and "
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
		for(auto &m : m_marks)
			kept_to_copies(m.first);
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
			if(wants_node(p.second))
				make_node(p.second);
		own_voxels();
		pick_provider();
		sync_free_objects();
		if(m_migrated)
			m_runtime_dirty = true;
		if(m_session.running)
			watch(true);
		log_i(MODULE, "The server is %s (by %s): %zu sections copied out, %zu "
				"to put back", m_session.running ? "Running" : "Stopped",
				m_session.by.empty() ? "no one" : cs(m_session.by),
				m_session.copied.size(), m_session.restore.size());
		sessions_from_save();
		m_hosted = true;
		// [KIT_AIRSHIPS_2] a kit/symmetry's copies where the build has none
		// yet (a template's), then the regions a template or another build
		// placed
		symmetries(nullptr);
		m_store->set("authored", authored_json().stringify());
		regions_sync(nullptr, "");
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
			if(reg->has(n))
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
		if(!reg->has(n))
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
			if(!reg->has(sd.name))
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
			if(!reg->has(n))
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
				// [KIT_MATERIAL_SETS] the World's set's, listed first
				if(m_w->materials.voxels.count(n))
					v.set("set", true);
				interface::VoxelName sn;
				sn.block_name = n+":"+world::shapes()[0].name;
				v.set("shapes", reg->has(sn));
				if(it == m_voxel_types.end() &&
						!d.textures[0].resource_name.empty())
					v.set("texture", d.textures[0].resource_name);
				out.append(v);
			}
		});
		return out;
	}

	// {"op": "voxel", "name", "texture", "kind", "solid", "transparent",
	// "light", "friction", "blast_resist", "surface", "group", "level", "sound_dig",
	// "sound_place", "drop"}: the builder's voxel type "<their name>/<name>", or its
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
		// [KIT_CTF] the blast strength it stands (0: any blast's)
		row.set("blast_resist", j.get("blast_resist").is_number() ?
				j.get("blast_resist") : json::Value(0.0));
		row.set("surface", jstr(j, "surface"));
		// [KIT_TOOLS_1] its material group and level
		row.set("group", jstr(j, "group"));
		row.set("level", j.get("level").is_number() ? j.get("level") :
				json::Value((int64_t)0));
		// [KIT_SOUNDS] its dig's and place's sounds
		row.set("sound_dig", jstr(j, "sound_dig"));
		row.set("sound_place", jstr(j, "sound_place"));
		// [KIT_CTF] what its dig drops ("" itself)
		row.set("drop", jstr(j, "drop"));
		world::Material m;
		if(!m.parse(row) || m.light != row.get("light").as_number())
			return refuse("a texture, a kind (solid, leaves, plant, water), "
					"light (a whole number 0...15), friction 0...10, "
					"blast_resist 0...1000, a "
					"surface tag and a group (letters, digits and _), a "
					"level (a whole number 0...15), sounds' names and a "
					"drop's (<author>/<name>)");
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
			taken = taken || reg->has(n);
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
				"%i, friction %g, surface \"%s\", group \"%s\" level %i)%s",
				cs(p.name), cs(name),
				cs(itos(version)), cs(texture), cs(m.kind),
				m.solid ? ", solid" : "", m.transparent ? ", transparent" : "",
				m.light, m.friction, cs(m.surface), cs(m.group), m.level,
				taken ? ": drawn so at the next start" : "");
		if(taken)
			for(auto &o : m_peers)
				if(o.second.name == p.name)
					network::access(m_server, [&](network::Interface *in){
						in->send(o.first, "kit:warning", "Voxel type "+name+
								" version "+itos(version)+" is drawn so at the "
								"next start");
					});
		send_state_all();
	}

	// "kit:texture" (a PNG's bytes): a builder with the tools on uploads a
	// texture for their voxel types; answered with "kit:texture" (its
	// name, "kit/up/<hash>.png") or "kit:edit_refused". Decoded here and
	// saved again as a PNG: a client is sent only what decoded
	// [KIT_SESSIONS_1] in the sender's session
	void on_texture(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_texture_u(packet);
	}

	void on_texture_u(const network::Packet &packet)
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
		send_state_all();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:texture", name);
		});
	}

	// A texture's PNG checked, decoded and saved again as a PNG (a client
	// is sent only what decoded) in the row "texture:<hash>", and served:
	// its name ("kit/up/<hash>.png"), or "" and why not.
	// [KIT_SET_ORPHAN_TEXTURES] pending: only checked and decoded, put
	// there by hash, stored once the whole package is taken
	ss_ store_texture(const ss_ &d, ss_ &why,
			sm_<ss_, ss_> *pending = nullptr)
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
		if(m_textures.size() + (pending ? pending->size() : 0) >= MAX_TEXTURES)
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
		if(pending){
			(*pending)[hash] = png;
			return "kit/up/"+hash+".png";
		}
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
	// [KIT_SESSIONS_1] in the sender's session
	void on_package(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_package_u(packet);
	}

	void on_package_u(const network::Packet &packet)
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
		send_state_all();
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
		sm_<ss_, json::Value> prefabs, voxels, items, sounds;
		for(auto &f : files){
			if(f.first.compare(0, 6, "types/") != 0)
				continue;
			const ss_ base = f.first.substr(6);
			ss_ n, kind;
			for(const char *suffix : {".client.lua", ".prefab.json",
					".voxel.json", ".item.json", ".sound.json", ".lua"}){
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
			// [KIT_SOUNDS] its sounds, {"params": "blip1:..."}, "<fp>/<n>"
			if(kind == ".sound.json"){
				const ss_ params = jstr(json::load_string(f.second.c_str()),
						"params");
				if(!sound_params_ok(params))
					return f.first+": no blip1 \"params\"";
				ss_ row;
				if(m_store->get("sound:"+fp+"/"+n, row) && jstr(json::load_string(
						row.c_str()), "package") != name)
					return "the sound "+fp+"/"+n+" is a builder's here";
				json::Value r = json::object();
				r.set("params", params);
				sounds[fp+"/"+n] = r;
				continue;
			}
			if(kind == ".prefab.json" || kind == ".voxel.json" ||
					kind == ".item.json"){
				const json::Value j = json::load_string(f.second.c_str());
				if(!j.is_object())
					return f.first+": not a JSON object";
				json::Value r = j.deepcopy();
				resolve_names(r, keys);
				(kind == ".prefab.json" ? prefabs : kind == ".voxel.json" ?
						voxels : items)[fp+"/"+n] = r;
				continue;
			}
			json::Value t = types.get(n).is_object() ? types.get(n) :
					json::object();
			t.set(kind == ".lua" ? "source" : "client", f.second);
			types.set(n, t);
		}
		// [KIT_MATERIAL_SETS] materials.json: a material set (world.h's
		// format) a World may be made of. Its own voxels are "<author>/<n>",
		// installed as its voxel types; "extends": kit/default (Kit's own)
		// or a set it depends on, the later set winning (world::merge_sets)
		json::Value set, base;
		std::set<ss_> set_voxels;
		const auto mj = files.find("materials.json");
		if(mj != files.end()){
			set = json::load_string(mj->second.c_str());
			if(!set.is_object() || jstr(set, "format") != "kit_materials")
				return "materials.json: not a kit_materials set";
			resolve_names(set, keys);
			set.set("author", fp);
			set.set("name", jstr(m, "name"));
			const ss_ ex = jstr(set, "extends");
			bool dep = ex.empty() || ex == "kit/default";
			for(json::Iterator it(resolved); it; ++it){
				auto d = m_packages.find((*it).as_string());
				dep = dep || (d != m_packages.end() && d->first == ex &&
						d->second.get("materials").is_object());
			}
			if(!dep || ex == name)
				return "materials.json: \"extends\" is kit/default or the set "
						"of a package it depends on";
			ss_ pin, bwhy;
			if(!ex.empty() && !material_json(ex, base, pin, bwhy))
				return "materials.json: "+bwhy;
			// Its voxels' tints named by a palette of it (or its base's)
			// made the palette, as a voxel type's row has it
			const json::Value pals = (ex.empty() ? set :
					world::merge_sets(base, set)).get("palettes");
			const json::Value &sv = set.get("voxels");
			for(json::Iterator it(sv); sv.is_object() && it; ++it){
				// resolve_names() leaves keys: "<author>/<n>" made "<fp>/<n>"
				const ss_ k = it.key().compare(0, author.size() + 1,
						author+"/") == 0 ? fp+it.key().substr(author.size()) :
						it.key();
				if(k.compare(0, fp.size() + 1, fp+"/") != 0 ||
						!name_ok(k.substr(fp.size() + 1)) || !(*it).is_object())
					return "materials.json: voxel "+it.key()+": its own, "+
							author+"/<letters, digits and _>";
				json::Value v = (*it).deepcopy();
				const json::Value &tn = v.get("tint");
				if(tn.is_string() && pals.get(tn.as_string()).is_array())
					v.set("tint", pals.get(tn.as_string()).deepcopy());
				if(voxels.count(k))
					return "materials.json: voxel "+k+" is in types/ too";
				voxels[k] = v;
				set_voxels.insert(k);
			}
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
		if(old != m_packages.end() && old->second.get("materials").is_object() &&
				!set.is_object())
			return version+" has no material set, which "+old_version+" had";
		// [KIT_PACKAGE_ITEMS] its item types, "<fp>/<n>", each sheet as a
		// builder's is checked; one of the project's own of that name kept
		for(auto &it : items){
			json::Value sheet;
			ss_ iwhy;
			if(!item_sheet(it.second, json::object(), sheet, iwhy))
				return "types/"+it.first.substr(fp.size() + 1)+".item.json: "+
						iwhy;
			ss_ row;
			if(m_store->get("item:"+it.first, row) && jstr(json::load_string(
					row.c_str()), "package") != name)
				return "the item type "+it.first+" is a builder's here";
			if(!m_item_types.count(it.first) &&
					m_item_types.size() >= MAX_ITEM_TYPES)
				return "the save has "+itos(MAX_ITEM_TYPES)+" item types";
			it.second = sheet;
		}
		size_t new_sounds = 0;
		for(auto &so : sounds)
			new_sounds += !m_sounds.count(so.first);
		if(m_sounds.size() + new_sounds > MAX_SOUNDS)
			return "the save has "+itos(MAX_SOUNDS)+" sounds";
		if(types.size() + prefabs.size() + voxels.size() + items.size() +
				sounds.size() == 0 && !set.is_object())
			return "no types, prefabs or voxel types in types/, and no "
					"materials.json";
		// The textures its voxel types wear, stored as an upload's: each
		// face's ([KIT_MATERIAL_SETS] a set's voxel's: top, side, bottom,
		// a season's)
		// [KIT_SET_ORPHAN_TEXTURES] decoded here, stored only once nothing
		// refuses the package
		const std::set<ss_> choices = texture_choices();
		sm_<ss_, ss_> pending_textures;
		auto take = [&](const ss_ &what, json::Value &o, const char *face){
			if(o.get(face).is_undefined())
				return ss_();
			const ss_ tex = jstr(o, face);
			if(tex.compare(0, 9, "textures/") == 0){
				auto f = files.find(tex);
				if(f == files.end())
					return what+": its texture "+tex+" is not in the archive";
				ss_ twhy;
				const ss_ served = store_texture(f->second, twhy,
						&pending_textures);
				if(served.empty())
					return tex+": "+twhy;
				o.set(face, served);
			} else if(!choices.count(tex)){
				return what+": no voxel or upload has the texture "+tex;
			}
			return ss_();
		};
		for(auto &it : items){
			const ss_ twhy = jstr(it.second, "icon").empty() ? ss_() :
					take(it.first, it.second, "icon");
			if(!twhy.empty())
				return twhy;
		}
		for(auto &v : voxels){
			for(const char *face : {"texture", "top", "side", "bottom"}){
				const ss_ twhy = take(v.first, v.second, face);
				if(!twhy.empty())
					return twhy;
			}
			if(v.second.get("seasons").is_object()){
				json::Value ss = v.second.get("seasons").deepcopy();
				for(json::Iterator it(v.second.get("seasons")); it; ++it){
					json::Value se = (*it).deepcopy();
					for(const char *face : {"texture", "top", "side", "bottom"}){
						const ss_ twhy = take(v.first, se, face);
						if(!twhy.empty())
							return twhy;
					}
					ss.set(it.key(), se);
				}
				v.second.set("seasons", ss);
			}
			world::Material mt;
			if(!mt.parse(v.second))
				return v.first+": not a texture, a kind, light 0...15, "
						"friction 0...10 and a surface tag";
		}
		// The set as a World would take it, its voxels with their textures
		// served; its biomes and structures named as types are
		if(set.is_object()){
			json::Value sv = json::object();
			for(const ss_ &k : set_voxels)
				sv.set(k, voxels[k].deepcopy());
			set.set("voxels", sv);
			world::MaterialSet ms;
			ss_ mwhy;
			if(!ms.parse(base.is_object() ? world::merge_sets(base, set) : set,
					mwhy))
				return "materials.json: "+mwhy;
			for(const char *k : {"biomes", "structures"})
				for(json::Iterator it(set.get(k)); set.get(k).is_object() && it;
						++it)
					if(!name_ok(it.key()))
						return "materials.json: "+ss_(k)+": "+it.key()+": a name "
								"is letters, digits and _";
			// [KIT_SET_UPGRADE_BREAKS] an upgrade a World made of it takes
			if(old != m_packages.end()){
				const ss_ bwhy = set_breaks(name, set);
				if(!bwhy.empty())
					return bwhy;
			}
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
		if(set.is_object())
			row.set("materials", set);
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
		for(auto &t : pending_textures){
			m_store->set("texture:"+t.first, t.second);
			serve_texture(t.first, t.second);
			log_i(MODULE, "Texture kit/up/%s.png (%zu bytes), %s's", cs(t.first),
					t.second.size(), cs(named));
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
		json::Value il = json::array();
		for(auto &it : items){
			it.second.set("format", ss_("kit_item"));
			it.second.set("author", author);
			it.second.set("name", it.first.substr(fp.size() + 1));
			it.second.set("version", (int64_t)1);
			it.second.set("package", name);
			m_store->set("item:"+it.first, it.second.stringify());
			m_item_types[it.first] = it.second;
			il.append(it.first);
		}
		if(!items.empty())
			send_item_types(-1);
		json::Value sl = json::array();
		for(auto &so : sounds){
			so.second.set("author", author);
			so.second.set("name", so.first.substr(fp.size() + 1));
			so.second.set("version", (int64_t)1);
			so.second.set("package", name);
			m_store->set("sound:"+so.first, so.second.stringify());
			m_sounds[so.first] = so.second;
			sl.append(so.first);
		}
		if(!sounds.empty())
			send_sounds(-1);
		row.set("prefabs", pl);
		row.set("voxels", vl);
		row.set("items", il);
		row.set("sounds", sl);
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
				(items.empty() ? "" : ", "+itos(items.size())+" item types")+
				(sounds.empty() ? "" : ", "+itos(sounds.size())+" sounds")+
				(set.is_object() ? ", a material set" : "")+
				(change.empty() ? "" : ", "+itos(change.size())+
				" entities upgraded");
		log_i(MODULE, "%s %s (%s, from %s)", cs(by), cs(what), cs(name),
				cs(aitta));
		// [KIT_MATERIAL_SETS] a World made of its set (an upgrade) made again
		world_check(by);
		send_state_all();
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
		// [KIT_PACKAGE_ITEMS] the builder's item types, what the prefabs'
		// givers and kits name (an uploaded icon in textures/, as a voxel
		// type's). simplified: all of them, not only those the prefabs name.
		for(const ss_ &k : m_store->list("item:"+author+"/")){
			ss_ src, png;
			m_store->get(k, src);
			json::Value row = json::load_string(src.c_str());
			if(!row.is_object() || !jstr(row, "package").empty())
				continue;
			for(const char *f : {"format", "author", "name", "version",
					"look_data"})
				row.del_key(f);
			const ss_ icon = jstr(row, "icon");
			if(icon.compare(0, 7, "kit/up/") == 0 && m_store->get("texture:"+
					icon.substr(7, icon.size() - 11), png)){
				static const char *H = "0123456789abcdef";
				ss_ h;
				for(unsigned char ch : png){
					h += H[ch >> 4];
					h += H[ch & 15];
				}
				hex.set("textures/"+icon.substr(7), h);
				row.set("icon", "textures/"+icon.substr(7));
			}
			files.set("types/"+k.substr(6 + author.size())+".item.json",
					row.stringify());
		}
		// [KIT_SOUNDS] the builder's sounds, types/<n>.sound.json
		// {"params"}. simplified: all of them, as the item types
		for(const ss_ &k : m_store->list("sound:"+author+"/")){
			ss_ src;
			m_store->get(k, src);
			const json::Value row = json::load_string(src.c_str());
			if(!row.is_object() || !jstr(row, "package").empty())
				continue;
			json::Value o = json::object();
			o.set("params", jstr(row, "params"));
			files.set("types/"+k.substr(7 + author.size())+".sound.json",
					o.stringify());
		}
		if(!files.size())
			return refuse("no prefabs, voxel or item types of "+author+
					"'s here");
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
		// [KIT_PREFAB_ROOT] Others' copies will name these: no renaming them
		for(auto &pf : pfs){
			const ss_ name = author+"/"+pf.first;
			const json::Value *row = prefab(name);
			if(!row)
				continue;
			json::Value marked = row->deepcopy();
			marked.set("published", true);
			m_store->set("prefab:"+name, marked.stringify());
			m_prefabs[name] = marked;
		}
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
		// [KIT_MATERIAL_SETS] A package's set pinned by its version (and
		// its bases'): an upgrade is a change of the World's, applied as
		// one (sections nobody wrote generated again)
		const ss_ set = jstr(out, "materials");
		if(!set.empty()){
			json::Value j;
			ss_ pin, why;
			material_json(set, j, pin, why);
			out.set("materials_pin", pin);
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
		// [KIT_SESSIONS_1] a session's, "<name>~<id>" to the app
		main_context::SceneReference ref = m_host.make_scene(
				app_scene(name, m_active), this);
		if(!ref){
			why = "scene "+name+": the app made none";
			return false;
		}
		m_host.scenes[name] = ref;
		if(m_active)
			session_scene(name, ref);
		else if(m_session.running)
			watch_scene(name, ref, true);
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

	// [KIT_MATERIAL_SETS] A material set as JSON (world.h's format): ""
	// the app's (Host::materials, else Kit's own), "kit/default" Kit's own,
	// else an installed package's ("<fp>/<name>"), the sets it extends
	// under it (world::merge_sets). pin: the packages and their versions,
	// what the World's row keeps
	bool material_json(const ss_ &id, json::Value &out, ss_ &pin, ss_ &why,
			int depth = 0)
	{
		if(id.empty() || id == "kit/default"){
			const ss_ ms = !id.empty() || m_host.materials.empty() ?
					read_file(m_server->get_module_path(MODULE)+
					"/materials.json") : m_host.materials;
			out = json::load_string(ms.c_str());
			return true;
		}
		auto pk = m_packages.find(id);
		// [KIT_SET_UPGRADE_BREAKS] an upgrade's set tried in its place
		auto tr = m_set_trial.find(id);
		const json::Value set = tr != m_set_trial.end() ? tr->second :
				pk == m_packages.end() ? json::Value() :
				pk->second.get("materials");
		if(!set.is_object()){
			why = "no material set "+shown(id)+" is installed";
			return false;
		}
		// A dependency loop (an upgrade may make one) ends here
		if(depth >= 8){
			why = shown(id)+" extends sets 8 deep (a loop?)";
			return false;
		}
		pin = id+" "+jstr(pk->second, "version")+(pin.empty() ? "" :
				" < "+pin);
		const ss_ base = jstr(set, "extends");
		if(base.empty()){
			out = set;
			return true;
		}
		json::Value b;
		if(!material_json(base, b, pin, why, depth + 1))
			return false;
		out = world::merge_sets(b, set);
		return true;
	}

	// [KIT_SET_UPGRADE_BREAKS] Why package id's set `set` in place of its
	// installed one would break a World made of it ("": none would)
	ss_ set_breaks(const ss_ &id, const json::Value &set)
	{
		ss_ out;
		for(auto &w : m_worlds){
			if(!out.empty() || !w.second.world_scene || !scene_id(w.first))
				continue;
			WorldScope ws(m_w, &w.second);
			const json::Value params = world_params();
			const ss_ uses = jstr(params, "materials_pin");
			if(!(uses.compare(0, id.size() + 1, id+" ") == 0 ||
					uses.find(" < "+id+" ") != ss_::npos))
				continue;
			m_set_trial[id] = set;
			world::MaterialSet ms;
			ss_ pin, why;
			world::Params p;
			p.from(params);
			if(material_set(jstr(params, "materials"), ms, pin, why))
				why = set_refusal(p, ms);
			m_set_trial.clear();
			if(!why.empty())
				out = "it would break the World of scene "+w.first+": "+why;
		}
		return out;
	}

	bool material_set(const ss_ &id, world::MaterialSet &out, ss_ &pin,
			ss_ &why)
	{
		json::Value j;
		if(!id.empty() && !m_host.material_sets){
			why = "this app binds its own materials (no material set packages)";
			return false;
		}
		if(!material_json(id, j, pin, why))
			return false;
		out = world::MaterialSet();
		if(!out.parse(j, why))
			return false;
		if(!id.empty())
			out.name = shown(id);
		return true;
	}

	bool host_world(ss_ &why)
	{
		if(m_host.world_scene.empty())
			return true;
		if(!m_host.scenes.count(m_host.world_scene)){
			why = "the World's scene "+m_host.world_scene+" is none of the app's";
			return false;
		}
		world::MaterialSet app;
		ss_ mwhy, pin;
		if(!material_set("", app, pin, mwhy)){
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
			// [KIT_HM_ORIGIN] a heightmap World saved before maps had an
			// origin keeps its map at the world's origin (the row says so
			// from its next write on)
			const json::Value &an = r.get("hm_anchor");
			m_w->hm_corner = an.is_string() ? an.as_string() == "corner" :
					was.heightmap();
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

	// Why a World of these parameters cannot be made of the set ("": it
	// can): its biome, the roles its generator needs, a heightmap's layers
	static ss_ set_refusal(const world::Params &p, const world::MaterialSet &ms)
	{
		auto bi = ms.biomes.find(p.biome);
		if(bi == ms.biomes.end())
			return "no biome \""+p.biome+"\" in the material set "+ms.name;
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
			if(ms.resolve(b, r).empty())
				return "the "+p.generator+" generator needs the role "+r+
						", which biome "+p.biome+" has none of (material set "+
						ms.name+")";
		if(p.heightmap())
			for(const char *r : {"top", "stone", "riverbed"}){
				const ss_ v = ms.resolve(b, r);
				auto m = ms.voxels.find(v);
				if(m == ms.voxels.end() || m->second.layer < 0)
					return v+" ("+r+") has no heightmap layer";
			}
		return "";
	}

	bool apply_world(const json::Value &params, const ss_ &by, bool first,
			ss_ &why)
	{
		world::Params p;
		p.from(params);
		// [KIT_MATERIAL_SETS] its material set, the one world_params() pinned
		world::MaterialSet ms;
		ss_ pin;
		const ss_ set_id = jstr(params, "materials");
		bool fell_back = false;
		if(!material_set(set_id, ms, pin, why)){
			// [KIT_SET_MISSING_NO_HOST] Hosting, a set not here (or broken):
			// the app's, the biome its first where it has not that one; the
			// ground as the save has it (nothing generated again), so it is
			// the set's again once it is installed
			if(!first || set_id.empty())
				return false;
			fell_back = true;
			warn("material set "+shown(set_id)+": "+why+"; the app's set "
					"used until it is installed");
			why.clear();
			if(!material_set("", ms, pin, why))
				return false;
			if(!ms.biomes.count(p.biome) && !ms.biomes.empty()){
				warn("no biome \""+p.biome+"\" in the app's set; "+
						ms.biomes.begin()->first+" used");
				p.biome = ms.biomes.begin()->first;
			}
		}
		why = set_refusal(p, ms);
		if(!why.empty())
			return false;
		const world::Biome &b = ms.biomes.find(p.biome)->second;
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
		const bool again = had && !fell_back && (m_w->hm_force ||
				ground_key(params) != ground_key(m_w->world_applied));
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
			world::resolve_biome(ms, b, id, ids.structs, ids);
			// [KIT_SOIL_DEPTH] the World's own (-1: the biome's)
			const int64_t soil = json::jint(params, "soil_depth", -1);
			if(soil >= 0)
				ids.filler_depth = (int)std::min<int64_t>(soil, 16);
			if(!ids.water)
				ids.water = ids.air;
		});
		if(!why.empty())
			return false;
		if(p.heightmap())
			for(const char *r : {"top", "stone", "riverbed"})
				layers.push_back(ms.voxels.find(ms.resolve(b, r))->second.layer);
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
		// [KIT_HEIGHTMAP_REGEN_LOSS] A heightmap about to be generated again
		// or replaced kept as the previous one (regenerate_heightmap() kept
		// it already, its edits with it)
		if(!first && had && m_w->wp.heightmap() && (again || reshape) &&
				!m_w->hm_force)
			hm_backup();
		// From here the World is made of the set (decorations' structures);
		// the old one back if the heightmap refuses
		world::MaterialSet was_set = m_w->materials;
		m_w->materials = ms;
		if(reshape && m_w->wp.heightmap()){
			// [KIT_HEIGHTMAP_REGEN_LOSS] a builder's decorations kept aside
			for(auto &d : m_w->decor)
				if(d.second.hand){
					Decor o = d.second;
					o.node = 0;
					m_w->decor_off.push_back(o);
				}
			decor_clear();
			m_w->decor_dirty = true;
			save_decor();
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				ih->delete_instance(m_w->world_scene);
			});
		}
		if(p.heightmap()){
			if(!apply_heightmap(p, *h, layers, ids, again, first, hash, why)){
				m_w->materials = was_set;
				return false;
			}
			dn = m_w->decor.size();
			dh = decor_hash();
			set_world_generator(p, ids, nullptr, lo, hi);
			// The voxel ground it replaces: unloaded and forgotten (the
			// edited sections stay in the save, unloaded)
			if(reshape && !m_w->wp.heightmap()){
				// (not told; [KIT_REGEN_ANSWER_LOST] one under way still is)
				const bool was = m_w->world_regenerating;
				regenerate(by, false);
				m_w->world_regenerating = was;
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
		row.set("hm_anchor", ss_(m_w->hm_corner ? "corner" : "centre"));
		m_store->set(world_row("world"), row.stringify());
		world_load_points();
		log_i(MODULE, "World%s: %s %s, seed %u, biome %s, %s, %s; ground %i "
				"to %i, heights hash %08x%s; version %i%s%s, decorations %zu "
				"(hash %08x); materials %s", by.empty() ? "" : cs(" by "+by),
				cs(p.generator), cs(p.size == "finite" ? itos(p.width)+"x"+
				itos(p.depth) : ss_("infinite")), p.seed, cs(p.biome),
				cs(p.heightmap() ? ss_("a heightmap") : "voxels"),
				cs("border "+p.border), lo, hi, hash,
				first ? (again ? ", the save's was another" : "") : "",
				world::VERSION, p.with_caves() && !p.heightmap() ? ", caves" : "",
				cs(caves), dn, dh, cs(ms.name));
		// [KIT_SYMMETRY] a heightmap generated again: its authored slice
		// copied over the others (a voxel World's in on_gen_queue)
		symmetry::Config scf;
		if(p.heightmap() && !first && sym_scene(m_w->world_scene, scf))
			log_i(MODULE, "kit/symmetry: the slice %s copied over the others after "
					"the heightmap's generation: %s", cs(scf.slice), cs(sym_copy(
					m_w->world_scene, scf, true, nullptr, by.empty() ? "kit" : by).text()));
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
		// [KIT_SOIL_DEPTH] the biome's (-1), the key from before it
		if(json::jint(c, "soil_depth", -1) < 0)
			c.del_key("soil_depth");
		// [KIT_HEIGHTMAP_REGEN_LOSS] The app's own set ("") is the key
		// from before [KIT_MATERIAL_SETS]: no "materials", no pin
		if(json::jstr(c, "materials").empty())
			c.del_key("materials");
		if(json::jstr(c, "materials_pin").empty())
			c.del_key("materials_pin");
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
			// [KIT_SESSIONS_1] a session's: only what it changed
			w->set_save_unaltered(!m_active && p.finite() && !p.heightmap());
			m_w->hm_world = p.heightmap() ? w : nullptr;
			m_w->lean_world = m_active && !in_draft() && p.finite() &&
					!p.heightmap() ? w : nullptr;
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
		// [KIT_SYMMETRY] a section with no authored cell is all copies: it is
		// generated again, and copied over again after
		symmetry::Config cf;
		const bool sym = sym_scene(m_w->world_scene, cf) != nullptr;
		voxelworld::access(m_server, m_w->world_scene,
				[&](voxelworld::Instance *w){
			// The edited ones into the save, so its index says them all
			w->save();
			const pv::Vector3DInt16 ss = w->get_section_size_voxels();
			auto copies = [&](const pv::Vector3DInt16 &p){
				for(int z = 0; z < ss.getZ(); z++)
					for(int x = 0; x < ss.getX(); x++)
						if(cf.editable(p.getX() * ss.getX() + x, p.getZ() * ss.getZ() + z))
							return false;
				return true;
			};
			sv_<pv::Vector3DInt16> forget;
			for(const auto &s : w->section_stats()){
				const auto k = std::make_tuple(s.p.getX(), s.p.getY(), s.p.getZ());
				if(s.altered && !(sym && copies(s.p)))
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
		// [KIT_REGEN_ANSWER_LOST] one under way still is: this one's sections
		// join its wait (kit:regenerated once all are in)
		m_w->world_regenerating = m_w->world_regenerating || again > 0;
		m_w->regen_wait.insert(m_w->regen_wait.end(), wait.begin(), wait.end());
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
		// Made out here: its valleys query reaches luanti_mapgen, which
		// depends on voxelworld and so cannot be accessed from inside it
		up_<world::Generator> g;
		if(m_w->world_scene)
			g = diff_generator();
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
		// Made out here: its valleys query reaches luanti_mapgen, which
		// depends on voxelworld and so cannot be accessed from inside it
		up_<world::Generator> g = diff_generator();
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
		if(value.stringify().size() > MAX_TRY_VALUE)
			return refuse("value: longer than "+itos(MAX_TRY_VALUE)+" bytes");
		// [KIT_SIGNALS_LIVE] The scene the builder is in (or none: game-wide)
		ss_ scene;
		scene_of(*e, &scene);
		if(!scene.empty() && scene != p.scene)
			return refuse("entity "+itos(e->id)+" is in the scene "+scene);
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

	// [KIT_SIGNALS_LIVE] {"op": "watch", "id": n}: this builder is shown what
	// entity n's outputs emit in their session ("kit:fired", at most every
	// WATCH_EVERY_US); 0 stops. Nothing is kept or done while nobody watches.
	// simplified: an output's last value of the period, from any player; a
	// per-player view of it is the upgrade
	struct SignalWatch {
		struct Fired {
			ss_ value;
			int n = 0;
		};
		uint64_t session = 0;
		uint64_t id = 0;
		std::map<std::pair<size_t, ss_>, Fired> fired;
		int64_t sent = 0;
	};
	std::map<size_t, SignalWatch> m_watches;

	void watch_op(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const json::Value &v = j.get("id");
		if(v.is_number() && v.as_number() == 0){
			if(m_watches.erase(peer))
				log_i(MODULE, "%s stops watching", cs(p.name));
			return;
		}
		ss_ why;
		Entity *e = entity_arg(j, "id", why);
		if(!e)
			return refuse(why);
		auto it = m_watches.find(peer);
		if(it != m_watches.end() && it->second.id == e->id &&
				it->second.session == m_active)
			return;
		SignalWatch &w = m_watches[peer];
		w = SignalWatch();
		w.session = m_active;
		w.id = e->id;
		log_i(MODULE, "%s watches entity %s", cs(p.name), cs(itos(e->id)));
	}

	// An emit, while somebody watches
	void watch_fired(uint64_t id, size_t comp, const ss_ &output,
			const json::Value &value)
	{
		for(auto &o : m_watches){
			SignalWatch &w = o.second;
			if(w.id != id || w.session != m_active)
				continue;
			SignalWatch::Fired &f = w.fired[std::make_pair(comp, output)];
			f.n++;
			f.value = value.is_null() ? ss_() : value.is_string() ?
					value.as_string() : value.stringify();
			if(f.value.size() > WATCH_VALUE_BYTES){
				// Not ending inside a character
				size_t n = WATCH_VALUE_BYTES;
				while(n > 0 && (f.value[n] & 0xC0) == 0x80)
					n--;
				f.value.resize(n);
			}
		}
	}

	// What fired since the last time, and whether each may still watch
	void watch_flush()
	{
		const int64_t now = interface::os::time_us();
		for(auto it = m_watches.begin(); it != m_watches.end();){
			const size_t peer = it->first;
			SignalWatch &w = it->second;
			if(now - w.sent < WATCH_EVERY_US){
				++it;
				continue;
			}
			if(session_of_peer(peer) != w.session){
				it = m_watches.erase(it);
				continue;
			}
			SessionScope sc(*this, w.session);
			auto pi = m_peers.find(peer);
			if(pi == m_peers.end()){
				it = m_watches.erase(it);
				continue;
			}
			WorldScope ws(m_w, world_named(pi->second.scene));
			if(!pi->second.editing || !can_edit(peer)){
				it = m_watches.erase(it);
				continue;
			}
			w.sent = now;
			if(!w.fired.empty()){
				json::Value fired = json::array();
				for(auto &f : w.fired){
					json::Value o = json::array();
					o.append((int64_t)f.first.first);
					o.append(f.first.second);
					o.append(f.second.value);
					o.append((int64_t)f.second.n);
					fired.append(o);
				}
				json::Value a = json::object();
				a.set("id", (int64_t)w.id);
				a.set("fired", fired);
				log_i(MODULE, "Fired for %s: entity %s: %s", cs(pi->second.name),
						cs(itos(w.id)), cs(fired.stringify().substr(0, 200)));
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(peer, "kit:fired", a.stringify());
				});
				w.fired.clear();
			}
			++it;
		}
	}

	// [KIT_HM_ORIGIN] A heightmap's sample (0, 0) as a world cell
	static int hm_ox(heightmap::Instance *map)
	{
		return (int)std::floor(map->get_size().origin_x + 0.5f);
	}
	static int hm_oz(heightmap::Instance *map)
	{
		return (int)std::floor(map->get_size().origin_z + 0.5f);
	}

	// ---- [KIT_HEIGHTMAP_REGEN_LOSS] A heightmap's edited samples
	// (World::hm_edits): the terrain tools mark what they write, a
	// regeneration generates the rest and puts them back over it, the
	// generated ones within HM_BLEND of them blended toward them

	static int floor_div(int a, int b)
	{
		return a >= 0 ? a / b : -((-a - 1) / b) - 1;
	}

	void hm_edits_load()
	{
		if(m_w->hm_edits_loaded)
			return;
		m_w->hm_edits_loaded = true;
		m_w->hm_edits.clear();
		const ss_ pre = world_row("hm_edit")+"/";
		const size_t rec = 6 + heightmap::MAX_MATERIALS;
		for(const ss_ &k : m_store->list(pre)){
			int cx = 0, cz = 0;
			ss_ v;
			if(sscanf(k.c_str() + pre.size(), "%d,%d", &cx, &cz) != 2 ||
					!m_store->get(k, v))
				continue;
			for(size_t i = 0; i + rec <= v.size(); i += rec){
				float h;
				memcpy(&h, v.data() + i + 2, 4);
				heightmap::Weights w;
				memcpy(w.data(), v.data() + i + 6, heightmap::MAX_MATERIALS);
				if(std::isfinite(h))
					m_w->hm_edits[std::make_pair(cx * HM_EDIT_CHUNK +
							(uint8_t)v[i], cz * HM_EDIT_CHUNK +
							(uint8_t)v[i + 1])] = std::make_pair(h, w);
			}
		}
		if(!m_w->hm_edits.empty())
			log_i(MODULE, "World: %zu edited heightmap samples in the save",
					m_w->hm_edits.size());
	}

	// The chunks of edits changed, to their rows (a chunk with none: gone)
	// simplified: the float as this machine has it (a save moved to a
	// big-endian one reads its edits wrong)
	void hm_edits_save()
	{
		const int C = HM_EDIT_CHUNK;
		for(const auto &ch : m_w->hm_edits_dirty){
			ss_ v;
			for(int x = ch.first * C; x < ch.first * C + C; x++)
				for(auto it = m_w->hm_edits.lower_bound(std::make_pair(x,
						ch.second * C)); it != m_w->hm_edits.end() &&
						it->first.first == x && it->first.second <
						ch.second * C + C; ++it){
					char b[6 + heightmap::MAX_MATERIALS];
					b[0] = (char)(x - ch.first * C);
					b[1] = (char)(it->first.second - ch.second * C);
					memcpy(b + 2, &it->second.first, 4);
					memcpy(b + 6, it->second.second.data(),
							heightmap::MAX_MATERIALS);
					v.append(b, sizeof b);
				}
			const ss_ k = world_row("hm_edit")+"/"+itos(ch.first)+","+
					itos(ch.second);
			if(v.empty())
				m_store->remove(k);
			else
				m_store->set(k, v);
		}
		m_w->hm_edits_dirty.clear();
	}

	// A sample marked edited (with what it holds) or not, its mark as it
	// was kept in the change for an undo
	void hm_mark(int x, int z, bool edited, float h,
			const heightmap::Weights &w, Change *c)
	{
		hm_edits_load();
		const std::pair<int, int> k(x, z);
		auto it = m_w->hm_edits.find(k);
		if(c && !c->hm_marks.count(k))
			c->hm_marks[k] = it == m_w->hm_edits.end() ? std::make_pair(false,
					std::make_pair(0.0f, heightmap::Weights{})) :
					std::make_pair(true, it->second);
		if(edited)
			m_w->hm_edits[k] = std::make_pair(h, w);
		else if(it != m_w->hm_edits.end())
			m_w->hm_edits.erase(it);
		m_w->hm_edits_dirty.insert(std::make_pair(floor_div(x, HM_EDIT_CHUNK),
				floor_div(z, HM_EDIT_CHUNK)));
	}

	// An unedited sample's height: the generator's, blended toward the
	// nearest edited sample within HM_BLEND (its difference from the
	// generator's there, fading with the distance). deltas: those
	// differences, kept over calls
	float hm_blended(world::Heights &h, int x, int z,
			std::map<std::pair<int, int>, float> &deltas)
	{
		const float g = h.at((float)x, (float)z) + 0.5f;
		double best = HM_BLEND + 1;
		float delta = 0;
		for(int dz = -HM_BLEND; dz <= HM_BLEND; dz++)
		for(int dx = -HM_BLEND; dx <= HM_BLEND; dx++){
			const std::pair<int, int> k(x + dx, z + dz);
			const double d = std::sqrt((double)(dx * dx + dz * dz));
			if(d >= best)
				continue;
			auto e = m_w->hm_edits.find(k);
			if(e == m_w->hm_edits.end())
				continue;
			auto dl = deltas.find(k);
			if(dl == deltas.end())
				dl = deltas.emplace(k, e->second.first - (h.at((float)k.first,
						(float)k.second) + 0.5f)).first;
			best = d;
			delta = dl->second;
		}
		return best > HM_BLEND ? g : g + delta * (float)(1 - best /
				(HM_BLEND + 1));
	}

	// The edited samples over a map just generated, and the generated ones
	// round them blended
	void hm_overlay(heightmap::Instance *map, world::Heights &h)
	{
		hm_edits_load();
		// [KIT_HM_ORIGIN] the edits by world cell, the samples from the
		// map's origin
		const int sx = map->samples_x(), sz = map->samples_z(),
				ox = hm_ox(map), oz = hm_oz(map);
		auto on = [&](int x, int z){
			return x >= ox && z >= oz && x < ox + sx && z < oz + sz;
		};
		std::set<std::pair<int, int>> near;
		size_t n = 0;
		for(auto &e : m_w->hm_edits){
			const int x = e.first.first, z = e.first.second;
			if(!on(x, z))
				continue;
			map->set_height(x - ox, z - oz, e.second.first);
			map->set_weights(x - ox, z - oz, e.second.second);
			n++;
			for(int dz = -HM_BLEND; dz <= HM_BLEND; dz++)
			for(int dx = -HM_BLEND; dx <= HM_BLEND; dx++){
				const std::pair<int, int> k(x + dx, z + dz);
				if(on(k.first, k.second) && !m_w->hm_edits.count(k))
					near.insert(k);
			}
		}
		std::map<std::pair<int, int>, float> deltas;
		for(auto &q : near)
			map->set_height(q.first - ox, q.second - oz, hm_blended(h, q.first,
					q.second, deltas));
		if(!m_w->hm_edits.empty())
			log_i(MODULE, "World: %zu edited heightmap samples kept over the "
					"generated map, %zu blended round them, %zu off the map",
					n, near.size(), m_w->hm_edits.size() - n);
	}

	// ---- [KIT_HEIGHTMAP_REGEN_LOSS] The previous heightmap: before a
	// regeneration, the map's rows (store "heightmap", "<name>/...") copied
	// to "<name>~prev/...", its edits' rows to "hm_prev_edit/...", and the
	// row "hm_prev" its World's parameters and decorations; restoring swaps
	// them, so a restore is undone by another

	static void clear_rows(storage::Store *st, const ss_ &prefix)
	{
		st->batch([&](){
			for(const ss_ &k : st->list(prefix))
				st->remove(k);
		});
	}

	static void copy_rows(storage::Store *st, const ss_ &from, const ss_ &to)
	{
		st->batch([&](){
			for(const ss_ &k : st->list(to))
				st->remove(k);
			for(const ss_ &k : st->list(from)){
				ss_ v;
				if(st->get(k, v))
					st->set(to+k.substr(from.size()), v);
			}
		});
	}

	// The map's and the edits' rows as they are now
	void hm_flush()
	{
		heightmap::access(m_server, [&](heightmap::Interface *ih){
			heightmap::Instance *map = ih->get_instance(m_w->world_scene);
			if(map)
				map->commit();
		});
		hm_edits_load();
		hm_edits_save();
		m_w->decor_dirty = true;
		save_decor();
	}

	void hm_backup()
	{
		storage::Store *hs = m_host.save ? m_host.save->store("heightmap") :
				nullptr;
		if(!hs)
			return;
		hm_flush();
		const ss_ name = world_row("world");
		copy_rows(hs, name+"/", name+"~prev/");
		copy_rows(m_store, world_row("hm_edit")+"/",
				world_row("hm_prev_edit")+"/");
		json::Value meta = json::object();
		meta.set("params", m_w->world_applied);
		ss_ dec;
		m_store->get(world_row("decor"), dec);
		meta.set("decor", dec);
		m_store->set(world_row("hm_prev"), meta.stringify());
		log_i(MODULE, "World: the heightmap kept as the previous one (%zu "
				"edited samples)", m_w->hm_edits.size());
	}

	// The first World entity on the World's scene and its instance's index
	bool world_entity(uint64_t &id, size_t &comp)
	{
		const uint64_t sid = scene_id(m_w->name);
		for(auto &p : m_entities){
			if(!sid || p.second.parent != sid || p.second.has_pos)
				continue;
			for(size_t i = 0; i < p.second.comps.size(); i++)
				if(m_types.count(p.second.comps[i].type) &&
						m_types[p.second.comps[i].type].world){
					id = p.first;
					comp = i;
					return true;
				}
		}
		return false;
	}

	// The previous heightmap back (swapped with this one): its samples,
	// edits, decorations and the World's parameters it was made by
	bool hm_restore(const ss_ &by, ss_ &why)
	{
		storage::Store *hs = m_host.save ? m_host.save->store("heightmap") :
				nullptr;
		ss_ ms;
		uint64_t id = 0;
		size_t comp = 0;
		if(!hs || !m_w->world_scene || !m_store->get(world_row("hm_prev"), ms)){
			why = "no previous heightmap";
			return false;
		}
		if(m_session.running && !m_host.persistent){
			why = "the game is Running: End it first";
			return false;
		}
		if(!m_w->wp.heightmap()){
			why = "the World is voxels now: its surface a heightmap first";
			return false;
		}
		const json::Value meta = json::load_string(ms.c_str());
		json::Value params = meta.get("params").deepcopy();
		world::Params pp;
		pp.from(params);
		if(!params.is_object() || !pp.heightmap() || !world_entity(id, comp)){
			why = "the previous heightmap's World is none to restore";
			return false;
		}
		hm_flush();
		const ss_ name = world_row("world"), e = world_row("hm_edit")+"/",
				pe = world_row("hm_prev_edit")+"/", te = world_row("hm_tmp_edit")+"/";
		copy_rows(hs, name+"/", name+"~tmp/");
		copy_rows(hs, name+"~prev/", name+"/");
		copy_rows(hs, name+"~tmp/", name+"~prev/");
		clear_rows(hs, name+"~tmp/");
		copy_rows(m_store, e, te);
		copy_rows(m_store, pe, e);
		copy_rows(m_store, te, pe);
		clear_rows(m_store, te);
		ss_ dec;
		m_store->get(world_row("decor"), dec);
		m_store->set(world_row("decor"), jstr(meta, "decor"));
		json::Value now = json::object();
		now.set("params", m_w->world_applied);
		now.set("decor", dec);
		m_store->set(world_row("hm_prev"), now.stringify());
		// Made again from the save, as at a start (the map read, kept)
		decor_clear();
		m_w->decor_off.clear();
		heightmap::access(m_server, [&](heightmap::Interface *ih){
			ih->delete_instance(m_w->world_scene);
		});
		m_w->hm_edits_loaded = false;
		m_w->hm_edits.clear();
		m_w->hm_edits_dirty.clear();
		if(!apply_world(params, by, true, why))
			return false;
		// The World entity's parameters those it was made by
		auto it = m_entities.find(id);
		json::Value ej = entity_json(it->second);
		json::Value comps = ej.get("components").deepcopy();
		json::Value c0 = comps.at((unsigned)comp).deepcopy();
		params.del_key("materials_pin");
		c0.set("params", params);
		comps.set_at((unsigned)comp, c0);
		ej.set("components", comps);
		commit({std::make_pair(id, ej)}, nullptr);
		log_i(MODULE, "World by %s: the previous heightmap restored (%zu "
				"edited samples)", cs(by), m_w->hm_edits.size());
		return true;
	}

	// {"op": "hm_regenerate"}: the heightmap generated anew, its
	// edited samples and a builder's decorations discarded (the map before
	// kept as the previous one: the undo restores it)
	void regenerate_heightmap(Peer &p, size_t peer, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		(void)j;
		if(!m_w->world_scene || !m_w->wp.heightmap())
			return refuse("a heightmap World's");
		if(m_session.running && !m_host.persistent)
			return refuse("the game is Running: End it first");
		hm_backup();
		const size_t n = m_w->hm_edits.size();
		for(auto &e : m_w->hm_edits)
			m_w->hm_edits_dirty.insert(std::make_pair(floor_div(e.first.first,
					HM_EDIT_CHUNK), floor_div(e.first.second, HM_EDIT_CHUNK)));
		m_w->hm_edits.clear();
		hm_edits_save();
		for(auto &d : m_w->decor)
			d.second.hand = false;
		m_w->decor_off.clear();
		m_w->decor_dirty = true;
		save_decor();
		m_w->hm_force = true;
		ss_ why;
		const bool ok = apply_world(world_params(), p.name, false, why);
		m_w->hm_force = false;
		if(!ok)
			return refuse(why);
		std::deque<Change> &u = m_undo[p.name];
		Change nc;
		nc.hm_restore = true;
		u.push_back(nc);
		while(u.size() > UNDO_MAX)
			u.pop_front();
		log_i(MODULE, "World by %s: the heightmap generated anew, %zu edited "
				"samples discarded (%zu to undo)", cs(p.name), n, u.size());
		send_state(peer);
	}

	// A heightmap surface: builtin/heightmap's map in the World's scene,
	// generated from the same heights unless the save had it as applied;
	// its grass, rock and sand the biome's top, stone and riverbed layers
	// [KIT_HEIGHTMAP_REGEN_LOSS] At a start (first) the save's map is kept
	// even where the World's parameters differ from those it was made by
	// (a warning): only a builder's change generates it again, and then
	// only its unedited samples (hm_overlay())
	bool apply_heightmap(const world::Params &p, world::Heights &h,
			const sv_<int> &layers, const world::Ids &ids, bool again,
			bool first, uint32_t &hash, ss_ &why)
	{
		bool generated = false;
		heightmap::Size size;
		size.chunks_x = (p.width + 63) / 64;
		size.chunks_z = (p.depth + 63) / 64;
		size.chunk_size = 64;
		size.cell_size = 1;
		size.base_y = -100;
		size.materials = 5;
		// [KIT_HM_ORIGIN] on the voxels' finite area (its corner x0(),
		// z0()), so a resize grows every side; a World from before at the
		// world's origin
		if(!m_w->hm_corner){
			size.origin_x = (float)p.x0();
			size.origin_z = (float)p.z0();
		}
		heightmap::access(m_server, [&](heightmap::Interface *ih){
			heightmap::Instance *map = ih->get_instance(m_w->world_scene);
			bool loaded = false;
			if(!map){
				map = ih->create_instance(m_w->world_scene, size);
				loaded = map->set_save(m_host.save, world_row("world"));
			}
			if(loaded && again && first)
				warn("the save's heightmap kept, though the World's "
						"parameters differ from those it was made by; a change "
						"of them generates its unedited samples again");
			if(!loaded || (again && !first)){
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
				hm_overlay(map, h);
			}
			hash = map->content_hash();
			log_i(MODULE, "World: the heightmap from (%i,%i) to (%i,%i)",
					hm_ox(map), hm_oz(map), hm_ox(map) + map->samples_x() - 1,
					hm_oz(map) + map->samples_z() - 1);
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
		auto si = m_w->materials.structures.find(name);
		if(si == m_w->materials.structures.end())
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

	// ---- [KIT_FREE_PREFAB] A prefab's copy as a free object: kit/prefab_copy's
	// mode "free". Its root's place and turn are the object's, no voxel of it is
	// in the world; its members are under the root as a stamped copy's. A model
	// per prefab and voxels_version in each scene with a copy of it, so a save
	// changes all of them. The objects follow the entities and prefabs here,
	// after whatever changed them. Not saved: the rows say it all

	static bool is_free(const Entity &e)
	{
		if(!is_root(e))
			return false;
		for(const Instance &in : e.comps)
			if(in.type == PREFAB_ROOT)
				return jstr(in.params, "mode") == "free";
		return false;
	}

	// The solid cells merged along x, z, then y, in the object's frame (a
	// cell's middle its whole coordinates). simplified: past MAX_FREE_BOXES the
	// model's whole box, a warning said; a sweep through a grid in the object's
	// frame is the upgrade
	static const size_t MAX_FREE_BOXES = 4096;
	struct FreeCells
	{
		int n[3], a[3];
		sv_<char> solid;
		char& at(int x, int y, int z)
		{
			return solid[(size_t)x + (size_t)n[0] * ((size_t)z + (size_t)n[2] * y)];
		}
	};
	static void free_boxes(FreeCells &g, sv_<float> &out)
	{
		auto put = [&](int x0, int y0, int z0, int x1, int y1, int z1){
			out.push_back(g.a[0] + x0 - 0.5f);
			out.push_back(g.a[1] + y0 - 0.5f);
			out.push_back(g.a[2] + z0 - 0.5f);
			out.push_back(g.a[0] + x1 + 0.5f);
			out.push_back(g.a[1] + y1 + 0.5f);
			out.push_back(g.a[2] + z1 + 0.5f);
		};
		for(int y = 0; y < g.n[1]; y++)
		for(int z = 0; z < g.n[2]; z++)
		for(int x = 0; x < g.n[0]; x++){
			if(g.at(x, y, z) != 1)
				continue;
			int x1 = x, z1 = z, y1 = y;
			while(x1 + 1 < g.n[0] && g.at(x1 + 1, y, z) == 1)
				x1++;
			auto row = [&](int zz, int yy){
				for(int i = x; i <= x1; i++)
					if(g.at(i, yy, zz) != 1)
						return false;
				return true;
			};
			while(z1 + 1 < g.n[2] && row(z1 + 1, y))
				z1++;
			auto plane = [&](int yy){
				for(int k = z; k <= z1; k++)
					if(!row(k, yy))
						return false;
				return true;
			};
			while(y1 + 1 < g.n[1] && plane(y1 + 1))
				y1++;
			for(int j = y; j <= y1; j++)
			for(int k = z; k <= z1; k++)
			for(int i = x; i <= x1; i++)
				g.at(i, j, k) = 2;
			put(x, y, z, x1, y1, z1);
		}
	}

	// The prefab's voxels as a model of the scene's (its registry's ids; a
	// voxel it has not is empty), made once. A shape's own boxes for the bodies,
	// as a world cell's
	void free_model(voxel_objects::Instance *vo, main_context::SceneReference ref,
			const ss_ &model, const json::Value &vx)
	{
		if(vo->get_model(model))
			return;
		const json::Value &kinds = vx.get("kinds"), &runs = vx.get("runs");
		FreeCells g;
		for(unsigned k = 0; k < 3; k++){
			g.n[k] = (int)vx.get("size").at(k).as_number();
			g.a[k] = (int)vx.get("at").at(k).as_number();
		}
		g.solid.assign((size_t)g.n[0] * g.n[1] * g.n[2], 0);
		struct Kind
		{
			interface::VoxelTypeId id = 0;
			uint8_t param = 0, tint = 0;
			bool solid = false;
			sv_<float> shape;
		};
		sv_<Kind> ks;
		size_t unknown = 0;
		voxelworld::access(m_server, ref, [&](voxelworld::Instance *w){
			for(unsigned i = 0; i < kinds.size(); i++){
				const json::Value &c = kinds.at(i);
				Kind k;
				interface::VoxelName vn;
				vn.block_name = c.at(0u).as_string();
				k.param = (uint8_t)c.at(1u).as_number();
				k.tint = (uint8_t)c.at(2u).as_number();
				const interface::VoxelDefinition *d = w->get_voxel_reg()->get(vn);
				if(d && vn.block_name != "air"){
					k.id = d->id;
					k.solid = d->physically_solid;
					k.shape = d->collision_boxes;
					const size_t vi = d->variant_of_param[k.param];
					if(vi < d->variants.size() &&
							!d->variants[vi].collision_boxes.empty())
						k.shape = d->variants[vi].collision_boxes;
				} else if(!d){
					unknown++;
				}
				ks.push_back(k);
			}
		});
		sv_<float> boxes;
		voxel_objects::Model *m = vo->create_model(model, g.n[0], g.n[1], g.n[2]);
		size_t cell = 0;
		for(unsigned r = 0; r + 1 < runs.size(); r += 2){
			const size_t count = (size_t)runs.at(r).as_number();
			const Kind &k = ks[(size_t)runs.at(r + 1).as_number()];
			for(size_t c = 0; c < count; c++, cell++){
				if(!k.id)
					continue;
				const int x = (int)(cell % g.n[0]);
				const int z = (int)(cell / g.n[0] % g.n[2]);
				const int y = (int)(cell / g.n[0] / g.n[2]);
				m->set_voxel_state(x, y, z, k.id, k.param, k.tint);
				if(!k.solid)
					continue;
				if(k.shape.empty()){
					g.at(x, y, z) = 1;
					continue;
				}
				for(size_t b = 0; b + 6 <= k.shape.size(); b += 6)
					for(size_t q = 0; q < 6; q++)
						boxes.push_back(k.shape[b + q] +
								g.a[q % 3] + (q % 3 == 0 ? x : q % 3 == 1 ? y : z));
			}
		}
		free_boxes(g, boxes);
		if(boxes.size() > MAX_FREE_BOXES * 6){
			log_w(MODULE, "The free object %s has %zu boxes: its whole box is "
					"what bodies meet", cs(model), boxes.size() / 6);
			boxes = {g.a[0] - 0.5f, g.a[1] - 0.5f, g.a[2] - 0.5f,
					g.a[0] + g.n[0] - 0.5f, g.a[1] + g.n[1] - 0.5f,
					g.a[2] + g.n[2] - 0.5f};
		}
		m_free_boxes[model] = boxes;
		vo->commit();
		log_i(MODULE, "A free object's model %s: %ix%ix%i, %zu boxes%s", cs(model),
				g.n[0], g.n[1], g.n[2], boxes.size() / 6, unknown ?
				", voxels the scene has not left out" : "");
	}

	void sync_free_objects()
	{
		voxel_objects::Interface *iv = nullptr;
		voxel_objects::access(m_server, [&](voxel_objects::Interface *i){ iv = i; });
		if(!iv)
			return;
		// [KIT_MOVING_OBJECTS] The rows, the nodes: at rest (free_bodies_tick()
		// moves the collision)
		AtRest rest(m_at_rest);
		std::set<uint64_t> wanted;
		std::map<main_context::SceneReference, std::set<ss_>> used;
		for(auto &x : m_entities){
			const Entity &e = x.second;
			// [KIT_AIRSHIPS] a copy made in play (c:spawn of a prefab with voxels) too
			if(e.kind == "player" || !e.has_pos || !is_free(e))
				continue;
			const ss_ of = jstr(e.prefab, "of");
			const json::Value *pf = prefab(of);
			main_context::SceneReference ref = scene_of(e);
			if(!pf || !ref || !pf->get("voxels").is_object())
				continue;
			bool has_world = false;
			voxelworld::access(m_server, [&](voxelworld::Interface *w){
				has_world = w->get_instance(ref) != nullptr;
			});
			if(!has_world)
				continue;
			voxel_objects::Instance *vo = iv->get_instance(ref);
			if(!vo)
				vo = iv->create_instance(ref);
			uint32_t h = 2166136261u;
			for(char c : of)
				h = (h ^ (unsigned char)c) * 16777619u;
			char hex[16];
			snprintf(hex, sizeof hex, "%08x", h);
			const ss_ shared = "kitfree_"+ss_(hex)+"_"+itos(voxels_version(*pf));
			const json::Value &vx = pf->get("voxels");
			double w[3], wy, wp, wr;
			Turn wq;
			world_of(e, w, &wq);
			wq.angles(wy, wp, wr);
			const magic::Quaternion q = wq.q();
			double corner[3] = {vx.get("at").at(0u).as_number() - 0.5,
					vx.get("at").at(1u).as_number() - 0.5,
					vx.get("at").at(2u).as_number() - 0.5};
			// [KIT_AIRSHIPS] its own voxels once their model is made
			ss_ model = shared, boxes = shared;
			auto oi = m_own.find(e.id);
			if(oi != m_own.end() && oi->second.made){
				model = own_model(e.id);
				boxes = oi->second.boxes;
				for(int k = 0; k < 3; k++)
					corner[k] = oi->second.a[k] - 0.5;
			} else {
				free_model(vo, ref, shared, vx);
			}
			const double corner0[3] = {corner[0], corner[1], corner[2]};
			wq.apply(corner);
			const magic::Vector3 pos(w[0] + corner[0], w[1] + corner[1],
					w[2] + corner[2]);
			auto it = m_free_objects.find(e.id);
			if(it != m_free_objects.end() && (it->second.ref != ref ||
					it->second.model != model)){
				if(iv->get_instance(it->second.ref))
					iv->get_instance(it->second.ref)->remove_object(it->second.node);
				m_free_objects.erase(it);
				it = m_free_objects.end();
			}
			const std::array<double, 6> place = {{w[0], w[1], w[2], wy, wp, wr}};
			if(it == m_free_objects.end()){
				FreeObject o;
				o.ref = ref;
				o.model = model;
				o.boxes = boxes;
				o.node = vo->create_object(model, pos, q);
				o.place = place;
				std::copy(corner0, corner0 + 3, o.corner);
				m_free_objects[e.id] = o;
				log_i(MODULE, "The free object of %s: entity %s, model %s, at "
						"%.3f,%.3f,%.3f yaw %.3f pitch %.3f roll %.3f, node at "
						"%.4f,%.4f,%.4f turn %.5f,%.5f,%.5f,%.5f", cs(of),
						cs(itos(e.id)), cs(model), w[0], w[1], w[2], wy, wp, wr,
						pos.x_, pos.y_, pos.z_, q.w_, q.x_, q.y_, q.z_);
			} else if(it->second.place != place){
				it->second.place = place;
				std::copy(corner0, corner0 + 3, it->second.corner);
				const uint node = it->second.node;
				main_context::access(m_server, ref, [&](magic::Scene *sc){
					magic::Node *n = sc->GetNode(node);
					if(n){
						n->SetPosition(pos);
						n->SetRotation(q);
					}
				});
				log_i(MODULE, "The free object of entity %s moved to %.3f,%.3f,%.3f "
						"yaw %.3f pitch %.3f roll %.3f, node at %.4f,%.4f,%.4f turn "
						"%.5f,%.5f,%.5f,%.5f", cs(itos(e.id)), w[0], w[1], w[2], wy,
						wp, wr, pos.x_, pos.y_, pos.z_, q.w_, q.x_, q.y_, q.z_);
			}
			m_free_objects[e.id].boxes = boxes;
			wanted.insert(e.id);
			used[ref].insert(model);
			m_free_models[ref].insert(model);
		}
		for(auto it = m_free_objects.begin(); it != m_free_objects.end();){
			if(wanted.count(it->first)){
				++it;
				continue;
			}
			if(iv->get_instance(it->second.ref))
				iv->get_instance(it->second.ref)->remove_object(it->second.node);
			log_i(MODULE, "The free object of entity %s is gone", cs(itos(it->first)));
			it = m_free_objects.erase(it);
		}
		// [KIT_AIRSHIPS] the own voxels of what is no free object any more
		for(auto it = m_own.begin(); it != m_own.end();){
			if(wanted.count(it->first)){
				++it;
				continue;
			}
			m_free_boxes.erase(it->second.boxes);
			it = m_own.erase(it);
		}
		// The versions nothing shows any more
		for(auto &sm : m_free_models){
			for(auto it = sm.second.begin(); it != sm.second.end();){
				if(used[sm.first].count(*it)){
					++it;
					continue;
				}
				if(iv->get_instance(sm.first))
					iv->get_instance(sm.first)->remove_model(*it);
				log_i(MODULE, "A free object's model %s is no longer in use", cs(*it));
				it = sm.second.erase(it);
			}
		}
	}

	// [KIT_MOVING_OBJECTS] Each tick the collision of what moves follows, its node
	// staying where its row says; back there when it stops moving
	void free_bodies_tick()
	{
		for(auto &f : m_free_objects){
			auto it = m_entities.find(f.first);
			if(it == m_entities.end())
				continue;
			const bool moving = moves(it->second);
			if(!moving && !f.second.body_moved)
				continue;
			f.second.body_moved = moving;
			double w[3];
			Turn q;
			world_of(it->second, w, &q);
			double c[3] = {f.second.corner[0], f.second.corner[1], f.second.corner[2]};
			q.apply(c);
			voxel_objects::access(m_server, f.second.ref,
					[&](voxel_objects::Instance *vo){
				vo->set_body_pose(f.second.node, magic::Vector3(w[0] + c[0],
						w[1] + c[1], w[2] + c[2]), q.q());
			});
		}
	}

	// ---- [KIT_AIRSHIPS] Voxels on a free object in play (kit_plan 4s stage 1)

	static ss_ own_model(uint64_t id)
	{
		return "kitown_"+itos(id);
	}

	// A voxel's solid shape as an object's boxes take it: solid, and its boxes
	// about the cell's middle (none: the whole cell)
	static void cell_shape(interface::VoxelRegistry *reg, interface::VoxelTypeId id,
			uint8_t param, bool &solid, sv_<float> &shape)
	{
		solid = false;
		shape.clear();
		const interface::VoxelDefinition *d = id ? reg->get(id) : nullptr;
		if(!d)
			return;
		solid = d->physically_solid;
		shape = d->collision_boxes;
		const size_t vi = d->variant_of_param[param];
		if(vi < d->variants.size() && !d->variants[vi].collision_boxes.empty())
			shape = d->variants[vi].collision_boxes;
	}

	// The copy's prefab's cells in a new grid, its box in the cube's middle;
	// false: a prefab larger than the cube
	bool own_grid(const Entity &e, OwnGrid &g, ss_ &why)
	{
		const json::Value *pf = prefab(jstr(e.prefab, "of"));
		if(!pf || !pf->get("voxels").is_object()){
			why = "It has no voxels";
			return false;
		}
		const json::Value &vx = pf->get("voxels");
		int n[3];
		for(unsigned k = 0; k < 3; k++){
			n[k] = (int)vx.get("size").at(k).as_number();
			if(n[k] > OWN_SIDE){
				why = "Larger than "+itos(OWN_SIDE)+" voxels a side: not built on";
				return false;
			}
			g.a[k] = (int)vx.get("at").at(k).as_number() - (OWN_SIDE - n[k]) / 2;
		}
		const int o[3] = {(OWN_SIDE - n[0]) / 2, (OWN_SIDE - n[1]) / 2,
				(OWN_SIDE - n[2]) / 2};
		g.v.assign((size_t)OWN_SIDE * OWN_SIDE * OWN_SIDE, OwnCell());
		const json::Value &kinds = vx.get("kinds"), &runs = vx.get("runs");
		sv_<OwnCell> ks;
		interface::VoxelTypeId core = 0;
		voxelworld::access(m_server, scene_of(e), [&](voxelworld::Instance *w){
			for(unsigned i = 0; i < kinds.size(); i++){
				const json::Value &c = kinds.at(i);
				interface::VoxelName vn;
				vn.block_name = c.at(0u).as_string();
				const interface::VoxelDefinition *d = w->get_voxel_reg()->get(vn);
				OwnCell k;
				if(d && vn.block_name != "air"){
					k.id = d->id;
					k.param = (uint8_t)c.at(1u).as_number();
					k.tint = (uint8_t)c.at(2u).as_number();
				}
				ks.push_back(k);
			}
			interface::VoxelName cn;
			cn.block_name = CORE_VOXEL;
			const interface::VoxelDefinition *d = w->get_voxel_reg()->get(cn);
			core = d ? d->id : 0;
		});
		size_t cell = 0;
		for(unsigned r = 0; r + 1 < runs.size(); r += 2){
			const size_t count = (size_t)runs.at(r).as_number();
			const size_t ki = (size_t)runs.at(r + 1).as_number();
			for(size_t c = 0; c < count; c++, cell++){
				if(ki >= ks.size() || !ks[ki].id)
					continue;
				const int x = (int)(cell % n[0]) + o[0];
				const int z = (int)(cell / n[0] % n[2]) + o[2];
				const int y = (int)(cell / n[0] / n[2]) + o[1];
				const int i = x + OWN_SIDE * (y + OWN_SIDE * z);
				g.v[i] = ks[ki];
				if(core && ks[ki].id == core && g.core < 0)
					g.core = i;
			}
		}
		return true;
	}

	// Its model and boxes made again from the grid: the model's changed cells
	// (all of them the first time), the boxes under a new name
	void own_rebuild(uint64_t id, OwnGrid &g)
	{
		auto fi = m_free_objects.find(id);
		if(fi == m_free_objects.end())
			return;
		const int64_t t0 = interface::os::time_us();
		const main_context::SceneReference ref = fi->second.ref;
		const ss_ model = own_model(id);
		const int S = OWN_SIDE;
		size_t written = 0;
		interface::VoxelRegistry *reg = nullptr;
		voxelworld::access(m_server, ref, [&](voxelworld::Instance *w){
			reg = w->get_voxel_reg();
		});
		if(!reg)
			return;
		voxel_objects::access(m_server, ref, [&](voxel_objects::Instance *vo){
			voxel_objects::Model *m = vo->get_model(model);
			auto put = [&](int i){
				const OwnCell &c = g.v[i];
				m->set_voxel_state(i % S, i / S % S, i / (S * S), c.id, c.param, c.tint);
				written++;
			};
			if(!m){
				m = vo->create_model(model, S, S, S);
				for(int i = 0; i < S * S * S; i++)
					if(g.v[i].id)
						put(i);
			} else {
				for(int i : g.changed)
					put(i);
			}
			vo->commit();
		});
		const int64_t t1 = interface::os::time_us();
		FreeCells c;
		for(int k = 0; k < 3; k++){
			c.n[k] = S;
			c.a[k] = g.a[k];
		}
		c.solid.assign((size_t)S * S * S, 0);
		sv_<float> boxes, shape;
		size_t voxels = 0;
		for(int i = 0; i < S * S * S; i++){
			const OwnCell &v = g.v[i];
			if(!v.id)
				continue;
			voxels++;
			bool solid;
			cell_shape(reg, v.id, v.param, solid, shape);
			if(!solid)
				continue;
			const int x = i % S, y = i / S % S, z = i / (S * S);
			if(shape.empty()){
				c.at(x, y, z) = 1;
				continue;
			}
			for(size_t b = 0; b + 6 <= shape.size(); b += 6)
				for(size_t q = 0; q < 6; q++)
					boxes.push_back(shape[b + q] + g.a[q % 3] +
							(q % 3 == 0 ? x : q % 3 == 1 ? y : z));
		}
		free_boxes(c, boxes);
		if(boxes.size() > MAX_FREE_BOXES * 6)
			boxes = {g.a[0] - 0.5f, g.a[1] - 0.5f, g.a[2] - 0.5f,
					g.a[0] + S - 0.5f, g.a[1] + S - 0.5f, g.a[2] + S - 0.5f};
		m_free_boxes.erase(g.boxes);
		g.boxes = model+"."+itos(++g.rev);
		m_free_boxes[g.boxes] = boxes;
		const size_t changed = g.made ? g.changed.size() : voxels;
		const double waited = (t0 - g.since) / 1000.0;
		g.made = true;
		g.dirty = false;
		g.changed.clear();
		sync_free_objects();
		log_i(MODULE, "[KIT_AIRSHIPS] entity %s's own voxels rebuilt (rev %i): %zu "
				"changed, %zu voxels, %zu written, %zu boxes; model %.1f ms, boxes %.1f "
				"ms; waited %.0f ms", cs(itos(id)), g.rev, changed, voxels, written,
				boxes.size() / 6, (t1 - t0) / 1000.0,
				(interface::os::time_us() - t1) / 1000.0, waited);
	}

	// Each tick: the copy waiting longest made again, at most one in OWN_REBUILD_GAP
	// for all of them (the budget: about one collision and mesh rebuild a second
	// shared by every ship, kit_plan 4s). simplified: a fixed gap, not a measured
	// cost; a cost per rebuild against a time budget is the upgrade if ships get
	// dear
	static constexpr int64_t OWN_REBUILD_GAP = 500000; // us
	void own_tick()
	{
		const int64_t now = interface::os::time_us();
		if(now - m_own_rebuilt_at < OWN_REBUILD_GAP)
			return;
		OwnGrid *best = nullptr;
		uint64_t best_id = 0;
		for(auto &o : m_own)
			if(o.second.dirty && (!best || o.second.since < best->since))
				best = &o.second, best_id = o.first;
		if(!best)
			return;
		m_own_rebuilt_at = now;
		own_rebuild(best_id, *best);
	}

	// The kit/hull on a free copy's root: who builds on it, what a voxel costs
	const Instance* hull_of(const Entity &e)
	{
		for(const Instance &in : e.comps)
			if(in.type == HULL_TYPE)
				return &in;
		return nullptr;
	}

	// The team a player is in (0: none)
	uint64_t team_of_player(uint64_t player)
	{
		for(auto &p : m_entities)
			for(const Instance &in : p.second.comps)
				if(m_types[in.type].team && in_team(player, p.first))
					return p.first;
		return 0;
	}

	// The player's kit/wallet (nullptr: none)
	Instance* wallet_of(uint64_t player)
	{
		auto it = m_entities.find(player);
		if(it == m_entities.end())
			return nullptr;
		for(Instance &in : it->second.comps)
			if(in.type == WALLET_TYPE)
				return &in;
		return nullptr;
	}

	// "kit:obuild" {"id", "cell": [x, y, z] (the entity's frame: a cell's middle
	// its whole coordinates), "voxel" (a name, "air" digs), "param", "tint"}: a
	// placed peer's place or dig on a free object, its kit/hull's rules first.
	// Refused: told why
	void on_obuild(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_obuild_u(packet);
	}

	void on_obuild_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second))
			return;
		auto refuse = [&](const ss_ &why){
			auto p = m_peers.find(peer);
			if(p == m_peers.end())
				return;
			tell(peer, why);
			if(log_refusal(p->second, why))
				log_i(MODULE, "[KIT_AIRSHIPS] a build on an object by %s refused: %s",
						cs(p->second.name), cs(why));
		};
		if(waiting_refused(pi->second, "build"))
			return;
		if(!m_session.running)
			return refuse("The server is not Running");
		const json::Value j = packet.data.size() < 512 ?
				json::load_string(packet.data.c_str()) : json::null();
		const json::Value &cj = j.get("cell");
		const ss_ voxel = jstr(j, "voxel");
		const int64_t param = json::jint(j, "param", 0), tint = json::jint(j, "tint", 0);
		bool ok = j.get("id").is_number() && cj.is_array() && cj.size() == 3 &&
				param >= 0 && param < 256 && tint >= 0 && tint < 16 && !voxel.empty();
		int cell[3] = {0, 0, 0};
		for(unsigned k = 0; ok && k < 3; k++){
			ok = cj.at(k).is_number() && std::fabs(cj.at(k).as_number()) < 1000;
			cell[k] = ok ? (int)std::floor(cj.at(k).as_number() + 0.5) : 0;
		}
		if(!ok)
			return refuse("Not a build");
		const uint64_t id = (uint64_t)std::max(0.0, j.get("id").as_number());
		auto ei = m_entities.find(id);
		auto fi = m_free_objects.find(id);
		if(ei == m_entities.end() || fi == m_free_objects.end())
			return refuse("Nothing to build on");
		const Entity &e = ei->second;
		ss_ scene;
		scene_of(e, &scene);
		if(scene != pi->second.scene)
			return refuse("In another scene");
		// Within reach: the cell where the object is now (a use's range and the
		// cube's half, as a client aims from its eye at a moving deck)
		double w[3];
		Turn q;
		world_of(e, w, &q);
		double cw[3] = {(double)cell[0], (double)cell[1], (double)cell[2]};
		q.apply(cw);
		double d2 = 0;
		for(int k = 0; k < 3; k++){
			cw[k] += w[k];
			d2 += (cw[k] - pi->second.pos[k]) * (cw[k] - pi->second.pos[k]);
		}
		const double reach = m_host.use_range + 4;
		if(d2 > reach * reach)
			return refuse("Too far away");
		const bool dig = voxel == "air";
		const Instance *hull = hull_of(e);
		const uint64_t me = pi->second.player;
		if(!pi->second.editing){
			if(!hull)
				return refuse("Protected: nobody builds on this");
			const ss_ rule = jstr(hull->params, "build");
			const uint64_t owner = (uint64_t)std::max<int64_t>(0,
					json::jint(hull->state, "owner", 0));
			const bool mine = me && owner == me;
			const uint64_t team = owner ? team_of_player(owner) : 0;
			if(!(rule == "anyone" || (rule == "owner" && mine) ||
					(rule == "team" && (mine || (team && in_team(me, team))))))
				return refuse(rule == "nobody" ? "Protected: nobody builds on this" :
						rule == "team" ? "Not your team's" : "Not yours");
			const json::Value r = game_rules();
			if(!r.get(dig ? "dig" : "place").is_true())
				return refuse(dig ? "No digging in this game" : "No placing in this game");
		}
		interface::VoxelTypeId vid = 0, core = 0;
		bool placeable = false;
		voxelworld::access(m_server, scene_of(e), [&](voxelworld::Instance *vw){
			interface::VoxelName n;
			n.block_name = voxel;
			const interface::VoxelDefinition *d = vw->get_voxel_reg()->get(n);
			placeable = d != nullptr;
			vid = d && !dig ? d->id : 0;
			n.block_name = CORE_VOXEL;
			d = vw->get_voxel_reg()->get(n);
			core = d ? d->id : 0;
		});
		if(!placeable)
			return refuse("Not a voxel to build with");
		ss_ gwhy;
		OwnGrid *gp = own_of(e, gwhy);
		if(!gp)
			return refuse(gwhy);
		OwnGrid &g = *gp;
		int l[3];
		for(int k = 0; k < 3; k++){
			l[k] = cell[k] - g.a[k];
			if(l[k] < 0 || l[k] >= OWN_SIDE)
				return refuse("A ship is "+itos(OWN_SIDE)+" voxels a side at most");
		}
		const int i = l[0] + OWN_SIDE * (l[1] + OWN_SIDE * l[2]);
		OwnCell &c = g.v[i];
		// [KIT_AIRSHIPS] stage 3: a part held (a kit/shop's with mount) goes on
		// that face instead of a voxel
		Instance *hw = !dig && !pi->second.editing && hull ? wallet_of(me) : nullptr;
		if(hw && !jstr(hw->state, "part").empty()){
			if(c.id)
				return refuse("Taken");
			ss_ why;
			if(!mount_part(e, g, i, jstr(hw->state, "part"), "player:"+itos(me), why))
				return refuse(why);
			hw->state.set("part", "");
			auto pe = m_entities.find(me);
			for(size_t k = 0; pe != m_entities.end() && k < pe->second.comps.size(); k++)
				if(&pe->second.comps[k] == hw)
					replicate_state(pe->second, k, "part");
			m_runtime_dirty = true;
			return;
		}
		ss_ was;
		if(dig){
			if(!c.id)
				return refuse("Nothing there to dig");
			if(i == g.core)
				return refuse("The core stays");
			voxelworld::access(m_server, scene_of(e), [&](voxelworld::Instance *vw){
				const interface::VoxelDefinition *d = vw->get_voxel_reg()->get(c.id);
				was = d ? d->name.block_name : "";
			});
		} else {
			if(c.id)
				return refuse("Taken");
			if(core && vid == core)
				return refuse("One core a ship: it comes with the ship");
			ss_ why;
			if(!place_ready(peer, voxel, &why))
				return refuse(why);
		}
		// The cost of a placed voxel, from the placer's wallet;
		// [KIT_AIRSHIPS_2] none while it is `free` (a kit/shop's
		// free_outside_rounds, out of a round)
		Instance *wl = wallet_of(me);
		const int64_t cost = hull && !dig && !pi->second.editing &&
				!(wl && wl->state.get("free").is_true()) ?
				json::jint(hull->params, "cost", 0) : 0;
		if(cost > 0){
			const int64_t money = wl ? json::jint(wl->state, "money", 0) : 0;
			if(!wl || money < cost)
				return refuse("Not enough money: a voxel costs "+itos(cost)+
						", you have "+itos(money));
			wl->state.set("money", money - cost);
			auto pe = m_entities.find(me);
			for(size_t k = 0; pe != m_entities.end() && k < pe->second.comps.size(); k++)
				if(&pe->second.comps[k] == wl)
					replicate_state(pe->second, k, "money");
			m_runtime_dirty = true;
		}
		c.id = vid;
		c.param = dig ? 0 : (uint8_t)param;
		c.tint = dig ? 0 : (uint8_t)tint;
		g.changed.insert(i);
		g.mass = -1;
		g.hurt.erase(i);
		if(!g.dirty){
			g.dirty = true;
			g.since = interface::os::time_us();
		}
		// [KIT_AIRSHIPS] what was mounted on a dug voxel drops, and what it held to
		// the core is debris
		if(dig){
			drop_mounts(id, g, {i}, "player:"+itos(me));
			ship_destroy(id, g, {}, "player:"+itos(me), pi->second.name+"'s dig");
		}
		const pv::Vector3DInt32 at((int)std::floor(cw[0] + 0.5),
				(int)std::floor(cw[1] + 0.5), (int)std::floor(cw[2] + 0.5));
		log_i(MODULE, "[KIT_AIRSHIPS] %s %s entity %s's cell (%i,%i,%i)%s; "
				"the object at %.2f,%.2f,%.2f", cs(pi->second.name), dig ?
				cs("dug "+was+" from") : cs("placed "+voxel+" on"), cs(itos(id)),
				cell[0], cell[1], cell[2], cost > 0 ? cs(" for "+itos(cost)) : "",
				w[0], w[1], w[2]);
		if(dig)
			dug(peer, at.getX(), at.getY(), at.getZ(), was);
		else
			placed(peer, at.getX(), at.getY(), at.getZ(), voxel);
	}

	// ---- [KIT_AIRSHIPS] Stages 3 to 5 (kit_plan 4s): parts, damage, death by touch

	// A free copy's own grid, its prefab's cells copied the first time (a build,
	// a hit, its parts summed): nullptr if it can't have one (why)
	OwnGrid* own_of(const Entity &e, ss_ &why)
	{
		auto oi = m_own.find(e.id);
		if(oi != m_own.end())
			return &oi->second;
		OwnGrid g;
		if(!own_grid(e, g, why))
			return nullptr;
		log_i(MODULE, "[KIT_AIRSHIPS] entity %s's voxels copied from its prefab %s "
				"(its own from now on)", cs(itos(e.id)), cs(jstr(e.prefab, "of")));
		return &m_own.emplace(e.id, std::move(g)).first->second;
	}

	// Which of its components is its kit/hull
	size_t hull_comp(const Entity &e)
	{
		for(size_t k = 0; k < e.comps.size(); k++)
			if(e.comps[k].type == HULL_TYPE)
				return k;
		return 0;
	}

	interface::VoxelRegistry* registry_of(const Entity &e)
	{
		interface::VoxelRegistry *reg = nullptr;
		voxelworld::access(m_server, scene_of(e), [&](voxelworld::Instance *w){
			reg = w->get_voxel_reg();
		});
		return reg;
	}

	// A ship voxel's mass and toughness (the damage that destroys it) by its
	// material's group: stone is the armour.
	// simplified: by group, not numbers of a material's own; a materials.json
	// field each is the upgrade
	void ship_cell_stats(interface::VoxelRegistry *reg, interface::VoxelTypeId id,
			double &mass, double &tough)
	{
		mass = 1;
		tough = 10;
		const interface::VoxelDefinition *d = reg && id ? reg->get(id) : nullptr;
		const world::Material *m = d ? material_named(d->name.block_name) : nullptr;
		const ss_ g = m ? m->group : ss_();
		if(g == "stone")
			mass = 3, tough = 30;
		else if(g == "dirt" || g == "sand")
			mass = 2, tough = 5;
		else if(g == "leaves" || g == "plant")
			mass = 0.2, tough = 2;
	}

	// Its voxels' mass, summed again after a change, with the box they fill
	double ship_mass(uint64_t id, OwnGrid &g)
	{
		if(g.mass >= 0)
			return g.mass;
		auto ei = m_entities.find(id);
		interface::VoxelRegistry *reg = ei == m_entities.end() ? nullptr :
				registry_of(ei->second);
		const int S = OWN_SIDE;
		g.mass = 0;
		for(int k = 0; k < 3; k++)
			g.lo[k] = S, g.hi[k] = -1;
		std::map<interface::VoxelTypeId, double> masses;
		for(int i = 0; i < S * S * S; i++){
			const interface::VoxelTypeId v = g.v[i].id;
			if(!v)
				continue;
			auto mi = masses.find(v);
			if(mi == masses.end()){
				double m, t;
				ship_cell_stats(reg, v, m, t);
				mi = masses.emplace(v, m).first;
			}
			g.mass += mi->second;
			const int c[3] = {i % S, i / S % S, i / (S * S)};
			for(int k = 0; k < 3; k++)
				g.lo[k] = std::min(g.lo[k], c[k]), g.hi[k] = std::max(g.hi[k], c[k]);
		}
		return g.mass;
	}

	// [KIT_AIRSHIPS] stage 3: the query over a ship's parts its movement reads (p.parts
	// in airship.lua): its voxels' mass by material, its engines' (kit/engine
	// anywhere under it) thrust and lift summed.
	// simplified: the server's only; a drive is stepped here, its rider
	// predicting nothing (4r6), so the client needs none of it
	json::Value ship_parts(uint64_t id)
	{
		json::Value p = json::object();
		auto ei = m_entities.find(id);
		ss_ why;
		OwnGrid *g = ei == m_entities.end() ? nullptr : own_of(ei->second, why);
		if(g)
			p.set("mass", ship_mass(id, *g));
		double thrust = 0, lift = 0;
		int64_t engines = 0;
		for(auto &x : m_entities){
			if(x.first == id || !under_or(x.second, id))
				continue;
			for(const Instance &in : x.second.comps)
				if(in.type == ENGINE_TYPE && in.disabled.empty()){
					const json::Value ps = params_of(in.type, &in);
					thrust += row_num(ps, "thrust");
					lift += row_num(ps, "lift");
					engines++;
				}
		}
		p.set("thrust", thrust);
		p.set("lift", lift);
		p.set("engines", engines);
		return p;
	}

	// A part (a prefab without voxels: kit/airship_engine...) put on a ship's
	// empty cell i, on the face of a voxel beside it (the one under it first):
	// made in play under the ship's root, the hull's, mounted on that voxel
	bool mount_part(const Entity &root, OwnGrid &g, int i, const ss_ &name,
			const ss_ &by, ss_ &why)
	{
		const json::Value *pf = prefab(name);
		if(!pf || pf->get("voxels").is_object() || pf->get("entities").size() < 1 ||
				pf->get("entities").size() > 8){
			why = "Not a part to put on a ship: "+name;
			return false;
		}
		const int S = OWN_SIDE;
		const int x = i % S, y = i / S % S, z = i / (S * S);
		static const int off[6][3] = {{0, -1, 0}, {0, 1, 0}, {-1, 0, 0}, {1, 0, 0},
				{0, 0, -1}, {0, 0, 1}};
		int on = -1;
		for(const auto &o : off){
			const int nx = x + o[0], ny = y + o[1], nz = z + o[2];
			if(nx < 0 || ny < 0 || nz < 0 || nx >= S || ny >= S || nz >= S)
				continue;
			const int j = nx + S * (ny + S * nz);
			if(g.v[j].id){
				on = j;
				break;
			}
		}
		if(on < 0){
			why = "A part goes on a face of the ship";
			return false;
		}
		const size_t n = pf->get("entities").size();
		if(made_count() + n > MAX_MADE || m_entities.size() + n > MAX_ENTITIES){
			why = "The round has made "+itos(MAX_MADE)+" entities";
			return false;
		}
		const double base[3] = {(double)(x + g.a[0]), (double)(y + g.a[1]),
				(double)(z + g.a[2])};
		sv_<json::Value> rows;
		const uint64_t first = m_next_id;
		instantiate(*pf, name, root.id, base, first, rows);
		m_next_id = first + rows.size();
		const size_t hc = hull_comp(root);
		for(const json::Value &row : rows)
			m_pending_ids.insert((uint64_t)json::jint(row, "id", 0));
		sv_<uint64_t> made;
		for(const json::Value &row : rows){
			Entity e;
			ss_ bad;
			if(!entity_from_json(row, e, bad) || m_entities.count(e.id)){
				log_w(MODULE, "[KIT_AIRSHIPS] a member of %s does not load: %s",
						cs(name), cs(bad));
				continue;
			}
			e.made = 'g';
			e.maker = root.id;
			e.maker_comp = hc;
			m_entities[e.id] = e;
			made.push_back(e.id);
		}
		m_pending_ids.clear();
		for(uint64_t id : made){
			Entity &e = m_entities[id];
			for(Instance &in : e.comps){
				const json::Value &sd = m_types[in.type].decl.get("state");
				in.state = json::object();
				if(sd.is_object())
					for(json::Iterator it(sd); it; ++it)
						in.state.set(it.key(), (*it).get("default"));
			}
			if(wants_node(e))
				make_node(e);
			for(size_t k = 0; k < e.comps.size(); k++){
				Run r;
				r.entity = id;
				r.comp = k;
				r.handler = "on_start";
				r.by = by;
				queue_run(r);
			}
		}
		if(made.empty()){
			why = "Not a part to put on a ship: "+name;
			return false;
		}
		g.mounts[on].push_back(made[0]);
		g.mounted_on[i] = on;
		m_runtime_dirty = true;
		log_i(MODULE, "[KIT_AIRSHIPS] %s mounted %s on entity %s's cell (%i,%i,%i) on "
				"(%i,%i,%i) as %s", player_id(by) ? cs(m_entities[player_id(by)].name) :
				cs(by), cs(name), cs(itos(root.id)),
				x + g.a[0], y + g.a[1], z + g.a[2], on % S + g.a[0], on / S % S + g.a[1],
				on / (S * S) + g.a[2], cs(itos(made[0])));
		return true;
	}

	// What is mounted on those cells drops (simplified: removed, not a falling
	// object)
	void drop_mounts(uint64_t root, OwnGrid &g, const sv_<int> &cells, const ss_ &by)
	{
		sv_<uint64_t> ids;
		for(int c : cells){
			auto it = g.mounts.find(c);
			if(it == g.mounts.end())
				continue;
			ids.insert(ids.end(), it->second.begin(), it->second.end());
			g.mounts.erase(it);
			for(auto mo = g.mounted_on.begin(); mo != g.mounted_on.end();)
				mo = mo->second == c ? g.mounted_on.erase(mo) : std::next(mo);
		}
		auto ri = m_entities.find(root);
		if(ids.empty() || ri == m_entities.end())
			return;
		const size_t hc = hull_comp(ri->second);
		const Instance *hull = hull_of(ri->second);
		const uint64_t owner = hull ? (uint64_t)std::max<int64_t>(0,
				json::jint(hull->state, "owner", 0)) : 0;
		const uint64_t shooter = player_id(by);
		for(uint64_t id : ids){
			if(!m_entities.count(id))
				continue;
			log_i(MODULE, "[KIT_AIRSHIPS] entity %s, mounted on entity %s, drops "
					"with its voxel", cs(itos(id)), cs(itos(root)));
			// (the owner and who did it told)
			const ss_ note = "A part dropped: "+m_entities[id].name;
			remove_entity(root, hc, by, id);
			if(owner)
				deliver(owner, "note", json::Value(note), "app", 0);
			if(shooter && shooter != owner)
				deliver(shooter, "note", json::Value(note), "app", 0);
		}
	}

	// [KIT_AIRSHIPS] stage 4: damage on a ship's cells ({cell, amount}...), what a
	// shot or a blast did: a cell past its toughness destroyed, the core hit the
	// ship lost
	void ship_damage(uint64_t root, const sv_<std::pair<int, double>> &hits,
			const ss_ &by, const ss_ &what)
	{
		auto ei = m_entities.find(root);
		ss_ why;
		OwnGrid *g = ei == m_entities.end() ? nullptr : own_of(ei->second, why);
		if(!g)
			return;
		interface::VoxelRegistry *reg = registry_of(ei->second);
		sv_<int> gone;
		for(auto &h : hits){
			const int i = h.first;
			if(i < 0 || i >= (int)g->v.size() || !g->v[i].id)
				continue;
			if(i == g->core)
				return ship_lost(root, by, what+" hit its core");
			double mass, tough;
			ship_cell_stats(reg, g->v[i].id, mass, tough);
			double &hurt = g->hurt[i];
			hurt += h.second;
			const int S = OWN_SIDE;
			log_i(MODULE, "[KIT_AIRSHIPS] entity %s's cell (%i,%i,%i) takes %g from %s: "
					"%g of %g", cs(itos(root)), i % S + g->a[0], i / S % S + g->a[1],
					i / (S * S) + g->a[2], h.second, cs(what), hurt, tough);
			if(hurt >= tough)
				gone.push_back(i);
		}
		if(!gone.empty())
			ship_destroy(root, *g, gone, by, what);
	}

	// Those cells gone (what each was kept for a repair), then what no longer
	// connects to the core (6 ways, from it) as debris: gone too, with what is
	// mounted on all of them; the model and boxes made again in the budget.
	// simplified: debris is removed, not a falling free object (the upgrade:
	// a free object of its cells, falling until it lands, then gone)
	void ship_destroy(uint64_t root, OwnGrid &g, const sv_<int> &gone, const ss_ &by,
			const ss_ &what)
	{
		const int S = OWN_SIDE;
		sv_<int> all;
		auto take = [&](int i){
			if(!g.v[i].id)
				return;
			if(!g.lost.count(i))
				g.lost[i] = g.v[i];
			g.v[i] = OwnCell();
			g.hurt.erase(i);
			g.changed.insert(i);
			all.push_back(i);
		};
		for(int i : gone)
			take(i);
		const size_t destroyed = all.size();
		if(g.core >= 0 && g.v[g.core].id){
			sv_<char> seen(g.v.size(), 0);
			sv_<int> q = {g.core};
			seen[g.core] = 1;
			while(!q.empty()){
				const int i = q.back();
				q.pop_back();
				const int c[3] = {i % S, i / S % S, i / (S * S)};
				for(int k = 0; k < 6; k++){
					int n[3] = {c[0], c[1], c[2]};
					n[k / 2] += k % 2 ? 1 : -1;
					if(n[k / 2] < 0 || n[k / 2] >= S)
						continue;
					const int j = n[0] + S * (n[1] + S * n[2]);
					if(!seen[j] && g.v[j].id){
						seen[j] = 1;
						q.push_back(j);
					}
				}
			}
			for(int i = 0; i < S * S * S; i++)
				if(g.v[i].id && !seen[i])
					take(i);
		}
		if(all.empty())
			return;
		g.mass = -1;
		if(!g.dirty){
			g.dirty = true;
			g.since = interface::os::time_us();
		}
		log_i(MODULE, "[KIT_AIRSHIPS] entity %s: %zu voxels destroyed by %s, %zu cut "
				"off from the core (debris)", cs(itos(root)), destroyed, cs(what),
				all.size() - destroyed);
		drop_mounts(root, g, all, by);
	}

	// A ship lost (its core hit, a deadly zone touched): its root and all under it
	// gone, its owner told, the shop that sold it ("lost") told
	void ship_lost(uint64_t root, const ss_ &by, const ss_ &why)
	{
		auto ei = m_entities.find(root);
		if(ei == m_entities.end() || !hull_of(ei->second))
			return;
		const Entity &e = ei->second;
		const Instance *hull = hull_of(e);
		const uint64_t owner = (uint64_t)std::max<int64_t>(0,
				json::jint(hull->state, "owner", 0));
		const uint64_t maker = e.made ? e.maker : 0;
		const size_t hc = hull_comp(e);
		log_i(MODULE, "[KIT_AIRSHIPS] entity %s is lost: %s", cs(itos(root)), cs(why));
		if(owner)
			deliver(owner, "note", json::Value("Your ship was lost: "+why), "app", 0);
		if(maker && maker != root)
			deliver(maker, "lost", json::Value((int64_t)root), by, 0);
		remove_entity(root, hc, by, root);
		sync_free_objects();
	}

	// The nearest ship cell (a free object with kit/hull, not skip) along a ray (d
	// a unit vector) from o within max, in steps of 5 cm: its root (0: none), t its
	// distance, cell its index
	uint64_t ray_ship(main_context::SceneReference sref, const double o[3],
			const double d[3], double max, uint64_t skip, double &t, int &cell)
	{
		uint64_t best = 0;
		const int S = OWN_SIDE;
		for(auto &f : m_free_objects){
			if(f.first == skip || f.second.ref != sref)
				continue;
			auto ei = m_entities.find(f.first);
			ss_ why;
			OwnGrid *g = ei == m_entities.end() || !hull_of(ei->second) ? nullptr :
					own_of(ei->second, why);
			if(!g)
				continue;
			ship_mass(f.first, *g);
			if(g->hi[0] < g->lo[0])
				continue;
			double w[3];
			Turn q;
			world_of(ei->second, w, &q);
			double lo[3] = {o[0] - w[0], o[1] - w[1], o[2] - w[2]};
			double ld[3] = {d[0], d[1], d[2]};
			q.inverse().apply(lo);
			q.inverse().apply(ld);
			double blo[3], bhi[3], t0 = 0;
			for(int k = 0; k < 3; k++){
				blo[k] = g->lo[k] + g->a[k] - 0.5;
				bhi[k] = g->hi[k] + g->a[k] + 0.5;
			}
			// (and its mounted parts' cells)
			for(auto &mo : g->mounted_on){
				const int c[3] = {mo.first % S, mo.first / S % S, mo.first / (S * S)};
				for(int k = 0; k < 3; k++){
					blo[k] = std::min(blo[k], c[k] + g->a[k] - 0.5);
					bhi[k] = std::max(bhi[k], c[k] + g->a[k] + 0.5);
				}
			}
			if(!ray_box(lo, ld, blo, bhi, t0) || t0 > max)
				continue;
			for(double s = t0; s <= max && s <= t0 + 2 * S; s += 0.05){
				int c[3];
				bool in = true;
				for(int k = 0; k < 3; k++){
					c[k] = (int)std::floor(lo[k] + ld[k] * s + 0.5) - g->a[k];
					in = in && c[k] >= 0 && c[k] < S;
				}
				if(!in)
					continue;
				int i = c[0] + S * (c[1] + S * c[2]);
				// (a mounted part: the voxel it is on takes the hit)
				auto mo = g->v[i].id ? g->mounted_on.end() : g->mounted_on.find(i);
				if(!g->v[i].id && mo == g->mounted_on.end())
					continue;
				if(mo != g->mounted_on.end())
					i = mo->second;
				best = f.first;
				max = t = s;
				cell = i;
				break;
			}
		}
		return best;
	}

	// A blast's damage on the ships near it: a cell within radius takes power *
	// (1 - distance / radius) * BLAST_SHIP_DAMAGE (a blast of power 1 at its
	// middle a shot's 10)
	static constexpr double BLAST_SHIP_DAMAGE = 10;
	void ships_blast(main_context::SceneReference sref, const double at[3],
			double radius, double power, const ss_ &by, const ss_ &who)
	{
		if(radius <= 0)
			return;
		const int S = OWN_SIDE;
		std::map<uint64_t, sv_<std::pair<int, double>>> hits;
		for(auto &f : m_free_objects){
			if(f.second.ref != sref)
				continue;
			auto ei = m_entities.find(f.first);
			ss_ why;
			OwnGrid *g = ei == m_entities.end() || !hull_of(ei->second) ? nullptr :
					own_of(ei->second, why);
			if(!g)
				continue;
			double w[3];
			Turn q;
			world_of(ei->second, w, &q);
			double l[3] = {at[0] - w[0], at[1] - w[1], at[2] - w[2]};
			q.inverse().apply(l);
			int lo[3], hi[3];
			for(int k = 0; k < 3; k++){
				lo[k] = std::max(0, (int)std::floor(l[k] - radius) - g->a[k]);
				hi[k] = std::min(S - 1, (int)std::ceil(l[k] + radius) - g->a[k]);
			}
			for(int z = lo[2]; z <= hi[2]; z++)
				for(int y = lo[1]; y <= hi[1]; y++)
					for(int x = lo[0]; x <= hi[0]; x++){
						const int i = x + S * (y + S * z);
						if(!g->v[i].id)
							continue;
						const double dx = x + g->a[0] - l[0], dy = y + g->a[1] - l[1],
								dz = z + g->a[2] - l[2];
						const double dist = std::sqrt(dx * dx + dy * dy + dz * dz);
						if(dist <= radius)
							hits[f.first].push_back(std::make_pair(i,
									power * (1 - dist / radius) * BLAST_SHIP_DAMAGE));
					}
		}
		for(auto &h : hits)
			ship_damage(h.first, h.second, by, who+"'s blast");
	}

	// [KIT_AIRSHIPS] stage 3: each radar's contacts, twice a second: the other ships
	// in its scene within its range, nearest first (5 at most), off its ship's
	// heading
	void radars_tick()
	{
		const int64_t now = interface::os::time_us();
		if(now - m_radar_at < 500000)
			return;
		m_radar_at = now;
		struct Ship
		{
			uint64_t id;
			ss_ scene;
			double w[3];
		};
		sv_<Ship> ships;
		for(auto &f : m_free_objects){
			auto ei = m_entities.find(f.first);
			if(ei == m_entities.end() || !hull_of(ei->second))
				continue;
			Ship s;
			s.id = f.first;
			scene_of(ei->second, &s.scene);
			world_of(ei->second, s.w);
			ships.push_back(s);
		}
		for(auto &p : m_entities){
			Entity &e = p.second;
			for(size_t k = 0; k < e.comps.size(); k++){
				if(e.comps[k].type != RADAR_TYPE || !e.comps[k].disabled.empty())
					continue;
				// Its ship: the nearest free object it is under
				uint64_t mine = 0;
				for(auto pi = m_entities.find(e.parent); pi != m_entities.end() && !mine;
						pi = m_entities.find(pi->second.parent))
					if(m_free_objects.count(pi->first))
						mine = pi->first;
				ss_ scene;
				scene_of(e, &scene);
				double w[3];
				Turn q;
				if(mine)
					world_of(m_entities[mine], w, &q);
				else
					world_of(e, w, &q);
				const double range = num(params_of(RADAR_TYPE, &e.comps[k]), "range",
						150, 1, 1000);
				sv_<std::pair<double, ss_>> list;
				for(const Ship &s : ships){
					if(s.id == mine || s.scene != scene)
						continue;
					double l[3] = {s.w[0] - w[0], s.w[1] - w[1], s.w[2] - w[2]};
					const double dist = std::sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2]);
					if(dist > range)
						continue;
					q.inverse().apply(l);
					const double b = std::atan2(l[0], l[2]) * 180 / 3.14159265358979323846;
					const Instance *h = hull_of(m_entities[s.id]);
					const uint64_t owner = h ? (uint64_t)std::max<int64_t>(0,
							json::jint(h->state, "owner", 0)) : 0;
					auto oe = m_entities.find(owner);
					char buf[160];
					snprintf(buf, sizeof buf, "%s: %.0f m, %.0f %s, %.0f %s",
							owner && oe != m_entities.end() ? cs(oe->second.name+"'s ship") :
							cs("ship "+itos(s.id)), dist, std::fabs(b),
							b >= 0 ? "right" : "left", std::fabs(l[1]), l[1] >= 0 ?
							"up" : "down");
					list.push_back(std::make_pair(dist, ss_(buf)));
				}
				std::sort(list.begin(), list.end());
				ss_ text;
				for(size_t n = 0; n < list.size() && n < 5; n++)
					text += (n ? "\n" : "")+list[n].second;
				const ss_ was = jstr(e.comps[k].state, "contacts");
				if(was == text)
					continue;
				const size_t before = was.empty() ? 0 :
						std::count(was.begin(), was.end(), '\n') + 1;
				e.comps[k].state.set("contacts", text);
				replicate_state(e, k, "contacts");
				m_runtime_dirty = true;
				if(before != std::min<size_t>(list.size(), 5))
					log_i(MODULE, "[KIT_AIRSHIPS] entity %s's radar: %zu ships: %s",
							cs(itos(e.id)), std::min<size_t>(list.size(), 5),
							cs(text.empty() ? ss_("none") : text.substr(0, text.find('\n'))));
			}
		}
	}

	// [KIT_AIRSHIPS] stage 4: a repair (kit/wallet's "repair"): each ship the player
	// owns has its destroyed voxels back, as they were, where nothing is now.
	// simplified: what dropped with them (mounted parts) does not come back
	void repair_ships(uint64_t player)
	{
		for(auto &o : m_own){
			auto ei = m_entities.find(o.first);
			const Instance *h = ei == m_entities.end() ? nullptr : hull_of(ei->second);
			if(!h || json::jint(h->state, "owner", 0) != (int64_t)player)
				continue;
			OwnGrid &g = o.second;
			size_t back = 0;
			for(auto it = g.lost.begin(); it != g.lost.end();){
				if(!g.v[it->first].id){
					g.v[it->first] = it->second;
					g.changed.insert(it->first);
					back++;
				}
				it = g.lost.erase(it);
			}
			g.hurt.clear();
			if(!back)
				continue;
			g.mass = -1;
			if(!g.dirty){
				g.dirty = true;
				g.since = interface::os::time_us();
			}
			auto pe = m_entities.find(player);
			log_i(MODULE, "[KIT_AIRSHIPS] entity %s repaired: %zu voxels back (for %s)",
					cs(itos(o.first)), back, pe == m_entities.end() ? "?" :
					cs(pe->second.name));
		}
	}

	// A decoration's object: its structure's origin cell on (x, y, z),
	// turned by yaw about it
	void decor_object(Decor &d)
	{
		if(!decor_model(d.structure))
			return;
		const world::Structure &st = m_w->materials.structures[d.structure];
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
		auto put = [&](const Decor &d){
			json::Value r = json::array();
			r.append(d.structure);
			for(float v : {d.x, d.y, d.z, d.yaw})
				r.append((double)v);
			// [KIT_HEIGHTMAP_REGEN_LOSS] a builder's
			if(d.hand)
				r.append(true);
			a.append(r);
		};
		for(auto &d : m_w->decor)
			put(d.second);
		for(const Decor &d : m_w->decor_off)
			put(d);
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
		// [KIT_HM_ORIGIN] (x, z) a world cell, its sample from the origin
		const int ox = hm_ox(map), oz = hm_oz(map);
		const float h = map->get_height(x - ox, z - oz);
		float steep = 0;
		for(int k = 0; k < 4; k++){
			const int nx = x - ox + (k == 0) - (k == 1),
					nz = z - oz + (k == 2) - (k == 3);
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
	// [KIT_HEIGHTMAP_REGEN_LOSS] A generated map keeps a builder's
	// decorations (the row's, "hand"), each on the ground there, those off
	// the map kept aside
	void decor_start(const world::Params &p, const world::Ids &ids,
			bool generated)
	{
		decor_clear();
		ss_ row;
		const bool had = m_store->get(world_row("decor"), row);
		const bool saved = !generated && had;
		struct New { ss_ s; float x, y, z, yaw; bool hand; };
		sv_<New> made;
		if(had){
			const json::Value a = json::load_string(row.c_str());
			for(unsigned i = 0; a.is_array() && i < a.size(); i++){
				const json::Value &r = a.at(i);
				const bool hand = r.size() == 6 && r.at(5).is_true();
				if(r.is_array() && (r.size() == 5 || r.size() == 6) &&
						r.at(0).is_string() && (saved || hand) &&
						m_w->materials.structures.count(r.at(0).as_string()))
					made.push_back({r.at(0).as_string(),
						(float)r.at(1).as_number(), (float)r.at(2).as_number(),
						(float)r.at(3).as_number(), (float)r.at(4).as_number(),
						hand});
			}
		}
		m_w->decor_off.clear();
		if(!saved && !p.with_decorations() && made.empty()){
			m_w->decor_dirty = true;
			save_decor();
			return;
		}
		if(!decor_instance())
			return;
		// Those off the map aside, the others on its ground (a generated
		// one's)
		heightmap::access(m_server, m_w->world_scene,
				[&](heightmap::Instance *map){
			sv_<New> on;
			const float ox = (float)hm_ox(map), oz = (float)hm_oz(map);
			for(New &n : made){
				if(n.x < ox - 0.5f || n.z < oz - 0.5f ||
						n.x > ox + map->samples_x() - 0.5f ||
						n.z > oz + map->samples_z() - 0.5f){
					if(n.hand){
						Decor d;
						d.structure = n.s;
						d.x = n.x, d.y = n.y, d.z = n.z, d.yaw = n.yaw;
						d.hand = true;
						m_w->decor_off.push_back(d);
					}
					continue;
				}
				if(!saved)
					n.y = decor_y(map, n.x, n.z);
				on.push_back(n);
			}
			made.swap(on);
		});
		if(saved){
		} else if(p.with_decorations()){
			// Not where a builder's stands
			std::set<std::pair<int, int>> taken;
			for(const New &n : made)
				for(int dz = -1; dz <= 1; dz++)
				for(int dx = -1; dx <= 1; dx++)
					taken.insert(std::make_pair((int)std::floor(n.x + 0.5f) + dx,
							(int)std::floor(n.z + 0.5f) + dz));
			heightmap::access(m_server, m_w->world_scene,
					[&](heightmap::Instance *map){
				// [KIT_HM_ORIGIN] by world cell
				const int ox = hm_ox(map), oz = hm_oz(map);
				for(int z = oz; z < oz + map->samples_z(); z++)
				for(int x = ox; x < ox + map->samples_x(); x++){
					if(taken.count(std::make_pair(x, z)))
						continue;
					// Not on the spawn (world_spawn: the middle)
					if(std::abs(x - ox - map->samples_x() / 2) <= 3 &&
							std::abs(z - oz - map->samples_z() / 2) <= 3)
						continue;
					float yaw = 0;
					const ss_ s = decor_pick(map, ids, ids.structs, p.seed, x, z,
							1, yaw);
					if(!s.empty())
						made.push_back({s, (float)x, decor_y(map, (float)x,
								(float)z), (float)z, yaw, false});
				}
			});
		}
		for(const New &n : made)
			m_w->decor[add_decor(n.s, n.x, n.y, n.z, n.yaw)].hand = n.hand;
		m_w->decor_dirty = true;
		save_decor();
		size_t hand = 0;
		for(auto &d : m_w->decor)
			hand += d.second.hand;
		log_i(MODULE, "World: %zu decorations on the heightmap (%s), %zu of "
				"them a builder's, %zu off the map", m_w->decor.size(),
				saved ? "the save's" : "generated", hand, m_w->decor_off.size());
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
		for(auto &b : m_w->materials.biomes){
			world::BiomeIds bi;
			world::resolve_biome(m_w->materials, b.second, id, br.structs, bi);
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
		for(auto &v : m_w->materials.voxels)
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
			"flatten", "paint", "fill", "decorate", "column", "reset", "seed"};
		if(!TOOLS.count(tool))
			return refuse("tool: raise, lower, smooth, flatten, paint, fill, "
					"decorate, reset, seed or column");
		// [KIT_AIRSHIPS_2] on a heightmap's World, "on": "voxels" works on
		// its voxels (a floating island) instead of the map; a seed is
		// always voxels
		const bool on_voxels = tool == "seed" || jstr(j, "on") == "voxels";
		if(tool == "reset" && on_voxels)
			return refuse("reset: a heightmap's samples");
		if(tool == "reset" && !m_w->wp.heightmap())
			return refuse("reset: a heightmap's (a voxel World's edited "
					"sections are generated again from their list)");
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
		if(!m_w->materials.biomes.count(biome) && !(tool == "fill" &&
				biome == "water"))
			return refuse("biome: one of the material set's"+ss_(tool ==
					"fill" ? ", or water" : ""));
		// [KIT_SYMMETRY] a dab in the authored slice (a fill's both corners)
		{
			symmetry::Config cf;
			const Entity *sym = tool == "column" ? nullptr :
					sym_scene(m_w->world_scene, cf);
			const int cx = (int)std::floor(x + 0.5), cz = (int)std::floor(z + 0.5);
			if(sym && (!cf.editable(cx, cz) || (tool == "fill" &&
					!cf.editable((int)std::floor(x1 + 0.5), (int)std::floor(z1 + 0.5)))))
				return refuse("("+itos(cx)+","+itos(cz)+") is outside kit/symmetry "+
						itos(sym->id)+"'s authored slice "+cf.slice);
		}
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
		if(m_w->wp.heightmap() && !on_voxels)
			what = terrain_heightmap(p, tool, x, y, z, x1, z1, r, s, level,
					biome, c, why);
		else
			what = terrain_voxels(p, tool, x, y, z, x1, z1, r, s, level, biome,
					c, why);
		if(!why.empty())
			return refuse(why);
		save_decor();
		hm_edits_save();
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
			// [KIT_AIRSHIPS_2] a heightmap's voxels have no sea
			if(m_w->wp.heightmap())
				br.p.sea_level = INT_MIN / 2;
			br.get = [&](int x, int y, int z, interface::VoxelTypeId &v){
				uint32_t id = 0;
				if(!voxel_id(w, pv::Vector3DInt32(x, y, z), id))
					return false;
				v = type_of(w, id);
				// [KIT_AIRSHIPS_2] (a heightmap's cell not loaded: air)
				if(!v)
					v = br.air;
				return true;
			};
			// [KIT_SYMMETRY] the dab's cells, written into the other slices after
			sv_<pv::Vector3DInt32> dab;
			br.set = [&](int x, int y, int z, interface::VoxelTypeId v){
				const pv::Vector3DInt32 q(x, y, z);
				uint32_t old = 0;
				if(!hm_section(w, q) || !voxel_id(w, q, old))
					return;
				if(c)
					c->cells.emplace(std::make_tuple(x, y, z), old);
				set_id(w, q, v);
				mark(w, m_w->world_scene, q, 'k', p.name);
				dab.push_back(q);
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
			if(tool == "seed"){
				// [KIT_AIRSHIPS_2] an island's seed in the air: a ball of the
				// biome's ground (radius the size, 1 a single cell), its top
				// cells top, filler under them, stone deeper
				const int R = r - 1;
				for(int dz = -R; dz <= R; dz++)
				for(int dx = -R; dx <= R; dx++){
					int t = INT_MIN;
					for(int dy = R; dy >= -R; dy--){
						if(dx * dx + dy * dy + dz * dz > R * R + R)
							continue;
						const int x = cx + dx, y = cy + dy, z = cz + dz;
						interface::VoxelTypeId v = 0;
						if(!br.get(x, y, z, v) || !br.soft.count(v))
							continue;
						if(t == INT_MIN)
							t = y;
						br.put(x, y, z, y == t ? sel->top : y >= t -
								sel->filler_depth ? sel->filler : sel->stone);
					}
					columns += t != INT_MIN;
				}
			} else if(tool == "raise" || tool == "lower"){
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
			symmetry::Config cf;
			size_t images = 0;
			if(!dab.empty() && sym_scene(m_w->world_scene, cf))
				images = sym_write(w, m_w->world_scene, cf, dab, c ? &c->cells :
						nullptr, p.name);
			int t;
			const bool has = br.top_of(cx, cz, hi, lo, t);
			if(what.empty() || tool == "decorate")
				what = (what.empty() ? tool : what)+" at ("+itos(cx)+","+
						itos(cy)+","+itos(cz)+") size "+itos(r)+" strength "+
						itos((int)s)+": "+itos(columns)+" columns, "+
						itos(br.written)+" cells";
			what += "; column ("+itos(cx)+","+itos(cz)+"): "+(has ?
					describe_column(w, br, cx, cz, t + 2, t - 6) : ss_("none"));
			if(images)
				what += "; "+itos(images)+" images";
		});
		return what;
	}

	// The heightmap's layer each biome role's voxel is (-1: none)
	int layer_of(const world::Biome &b, const char *role)
	{
		auto m = m_w->materials.voxels.find(m_w->materials.resolve(b, role));
		return m == m_w->materials.voxels.end() ? -1 : m->second.layer;
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
		const world::Biome &sel = m_w->materials.biomes[biome];
		ss_ what;
		size_t samples = 0, added = 0, images = 0;
		int bx0 = cx - r - 1, bz0 = cz - r - 1, bx1 = cx + r + 1,
				bz1 = cz + r + 1;
		sv_<std::pair<ss_, std::array<float, 4>>> decorate;
		world::BiomeIds bi;
		sv_<world::StructIds> structs;
		if(tool == "decorate")
			voxelworld::access(m_server, m_w->world_scene,
					[&](voxelworld::Instance *w){
				world::resolve_biome(m_w->materials, sel,
						[&](const ss_ &name) -> interface::VoxelTypeId {
					interface::VoxelName n;
					n.block_name = name;
					const interface::VoxelDefinition *d =
							w->get_voxel_reg()->get(n);
					return d ? d->id : 0;
				}, structs, bi);
			});
		heightmap::access(m_server, m_w->world_scene, [&](heightmap::Instance *map){
			// [KIT_HM_ORIGIN] world cells here, the map's samples from its
			// origin
			const int sx = map->samples_x(), sz = map->samples_z(),
					ox = hm_ox(map), oz = hm_oz(map);
			auto in = [&](int x, int z){
				return x >= ox && z >= oz && x < ox + sx && z < oz + sz;
			};
			auto HG = [&](int x, int z){ return map->get_height(x - ox, z - oz); };
			auto HS = [&](int x, int z, float h){
				map->set_height(x - ox, z - oz, h);
			};
			auto WG = [&](int x, int z){ return map->get_weights(x - ox, z - oz); };
			auto WS = [&](int x, int z, const heightmap::Weights &w){
				map->set_weights(x - ox, z - oz, w);
			};
			// [KIT_HEIGHTMAP_REGEN_LOSS] each sample written marked edited
			// after (reset's unmarked). [KIT_HM_EDIT_RUNNING_MARKS] A stroke
			// while Running is a live edit: End puts no heightmap back (Kit
			// keeps no copy of one), so the stroke and its marks both stay
			std::set<std::pair<int, int>> touched, wrote;
			auto keep = [&](int x, int z){
				if(c)
					c->samples.emplace(std::make_pair(x, z), std::make_pair(
							HG(x, z), WG(x, z)));
				if(tool != "reset")
					touched.insert(std::make_pair(x, z));
				wrote.insert(std::make_pair(x, z));
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
				const heightmap::Weights w = WG(x, z);
				int best = 0;
				for(int k = 1; k < heightmap::MAX_MATERIALS; k++)
					if(w[k] > w[best])
						best = k;
				for(auto &b : m_w->materials.biomes)
					if(layer_of(b.second, "top") == best)
						return b.second;
				return m_w->materials.biomes[m_w->wp.biome];
			};
			// A sample's layer as its ground is: stone where steep, the
			// riverbed under the sea, else its biome's top
			auto relayer = [&](int x, int z, const world::Biome &b){
				const float h = HG(x, z);
				float steep = 0;
				for(int k = 0; k < 4; k++){
					const int nx = x + (k == 0) - (k == 1),
							nz = z + (k == 2) - (k == 3);
					if(in(nx, nz))
						steep = std::max(steep, std::fabs(HG(nx, nz) -
								h));
				}
				const int layer = steep > HM_ROCK_SLOPE ? layer_of(b, "stone") :
						h < m_w->wp.sea_level + 0.5f ? layer_of(b, "riverbed") :
						layer_of(b, "top");
				const heightmap::Weights w = one_hot(layer);
				if(w != WG(x, z))
					WS(x, z, w);
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
					next[std::make_pair(x, z)] = HG(x, z) +
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
							sum += HG(x + dx, z + dz), n++;
					const float h = HG(x, z);
					next[std::make_pair(x, z)] = h + (sum / n - h) * k;
				});
			} else if(tool == "flatten"){
				circle([&](int x, int z, double){
					const float h = HG(x, z);
					next[std::make_pair(x, z)] = h + std::max(-step,
							std::min(step, (float)level - h));
				});
			} else if(tool == "fill"){
				const int x0 = std::max(ox, std::min(cx, (int)std::floor(fx1 + 0.5))),
						x1 = std::min(ox + sx - 1, std::max(cx, (int)std::floor(fx1 + 0.5))),
						z0 = std::max(oz, std::min(cz, (int)std::floor(fz1 + 0.5))),
						z1 = std::min(oz + sz - 1, std::max(cz, (int)std::floor(fz1 + 0.5)));
				for(int z = z0; z <= z1; z++)
					for(int x = x0; x <= x1; x++)
						if(HG(x, z) < level)
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
			} else if(tool == "reset"){
				// [KIT_HEIGHTMAP_REGEN_LOSS] back to the generator's: unmarked,
				// the generator's height (blended toward the edited ones
				// near), the World's biome's layer by the ground's slope
				// simplified: the layer is the brushes' rule (stone where
				// steep, the riverbed under the sea, else the top), not the
				// generator's blend of them
				world::Heights gh;
				gh.p = m_w->wp;
				valleys_query(gh);
				std::set<std::pair<int, int>> cells, round;
				circle([&](int x, int z, double){
					cells.insert(std::make_pair(x, z));
				});
				for(auto &q : cells){
					keep(q.first, q.second);
					hm_mark(q.first, q.second, false, 0, heightmap::Weights{}, c);
					for(int dz = -HM_BLEND; dz <= HM_BLEND; dz++)
					for(int dx = -HM_BLEND; dx <= HM_BLEND; dx++)
						if(in(q.first + dx, q.second + dz) &&
								!m_w->hm_edits.count(std::make_pair(q.first + dx,
								q.second + dz)))
							round.insert(std::make_pair(q.first + dx,
									q.second + dz));
				}
				std::map<std::pair<int, int>, float> deltas;
				for(auto &q : round){
					keep(q.first, q.second);
					HS(q.first, q.second, hm_blended(gh, q.first,
							q.second, deltas));
				}
				for(auto &q : cells)
					relayer(q.first, q.second, m_w->materials.biomes[m_w->wp.biome]);
				samples = round.size();
				bx0 = cx - r - HM_BLEND - 1, bz0 = cz - r - HM_BLEND - 1;
				bx1 = cx + r + HM_BLEND + 1, bz1 = cz + r + HM_BLEND + 1;
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
				HS(q.first.first, q.first.second, q.second);
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
			for(auto &q : touched)
				hm_mark(q.first, q.second, true, HG(q.first,
						q.second), WG(q.first, q.second), c);
			// [KIT_SYMMETRY] each authored sample written into its images,
			// each one past a seam its source's again
			symmetry::Config cf;
			if(sym_scene(m_w->world_scene, cf)){
				auto put = [&](int tx, int tz, int fx, int fz){
					if(!in(tx, tz) || !in(fx, fz) || (HG(tx, tz) == HG(fx, fz) &&
							WG(tx, tz) == WG(fx, fz)))
						return;
					keep(tx, tz);
					HS(tx, tz, HG(fx, fz));
					WS(tx, tz, WG(fx, fz));
					hm_mark(tx, tz, true, HG(fx, fz), WG(fx, fz), c);
					images++;
					bx0 = std::min(bx0, tx - 1), bz0 = std::min(bz0, tz - 1);
					bx1 = std::max(bx1, tx + 1), bz1 = std::max(bz1, tz + 1);
				};
				const std::set<std::pair<int, int>> dab = wrote;
				for(auto &q : dab){
					int sx, sz;
					size_t i;
					if(!cf.editable(q.first, q.second)){
						if(cf.source(q.first, q.second, sx, sz, i) && i)
							put(q.first, q.second, sx, sz);
						continue;
					}
					for(i = 1; i < cf.maps.size(); i++){
						int x = q.first, z = q.second;
						cf.maps[i].apply(x, z);
						put(x, z, q.first, q.second);
					}
				}
			}
			if(what.empty())
				what = tool+" at ("+itos(cx)+","+itos(cz)+") size "+itos(r)+
						" strength "+itos((int)s);
			if(in(cx, cz)){
				const heightmap::Weights w = WG(cx, cz);
				int best = 0;
				for(int k = 1; k < heightmap::MAX_MATERIALS; k++)
					if(w[k] > w[best])
						best = k;
				what += " on the heightmap: "+itos(samples)+" samples; ("+
						itos(cx)+","+itos(cz)+") at "+ftos(HG(cx,
						cz))+" layer "+itos(best);
			}
			what += ", map hash "+itos(map->content_hash());
			if(images)
				what += ", "+itos(images)+" images";
		});
		// [KIT_SYMMETRY] the decorations in the authored slice alone, and
		// their images
		symmetry::Config cf;
		const bool sym = sym_scene(m_w->world_scene, cf);
		for(auto &d : decorate){
			if(sym && !cf.in(d.second[0], d.second[2]))
				continue;
			const uint64_t id = add_decor(d.first, d.second[0], d.second[1],
					d.second[2], d.second[3]);
			m_w->decor[id].hand = true;
			if(c)
				c->decor.push_back(id);
			added++;
		}
		if(sym && added)
			added += sym_copy(m_w->world_scene, cf, true, c, p.name, true).decor;
		if(tool == "decorate")
			what += ", "+itos(added)+" decorations ("+itos(m_w->decor.size())+
					" in all, hash "+itos(decor_hash())+")";
		if(tool != "paint" && tool != "decorate" && tool != "column")
			reseat_decor(bx0, bz0, bx1, bz1);
		return what;
	}

	// ---- [KIT_AIRSHIPS_2] kit/world_region (types/world_region.lua): the
	// regions' voxels written into the World as they are placed and changed
	// while editing. Each World's row "regions" is what was written (each
	// region's corner and parameters): a change writes the difference, the
	// cells of a region gone or moved that still hold what it wrote back to
	// the World's generated ground, the new cells as the regions make them
	// (later ids over earlier), as edits (marked kept) into `back` (the
	// edit's undo), and kit/symmetry's images of them. A symmetry copy of a
	// region writes nothing (its source's cells are copied)


	// The regions' cells of a World's config (its "regions" row's array)
	bool region_cells(voxelworld::Instance *w, const json::Value &cfg,
			std::unordered_map<int64_t, interface::VoxelTypeId> &out,
			ss_ &why)
	{
		interface::VoxelRegistry *reg = w->get_voxel_reg();
		auto id = [&](const ss_ &name) -> interface::VoxelTypeId {
			interface::VoxelName n;
			n.block_name = name;
			const interface::VoxelDefinition *d = reg->get(n);
			return d ? d->id : 0;
		};
		for(unsigned i = 0; i < cfg.size(); i++){
			const json::Value &r = cfg.at(i), &pa = r.get("params"),
					&o = r.get("o"), &n = r.get("n");
			world::Region rg;
			for(unsigned k = 0; k < 3; k++){
				rg.o[k] = o.at(k).is_number() ? (int)o.at(k).as_number() : 0;
				rg.n[k] = n.at(k).is_number() ? std::max(1, std::min(
						MAX_WORLD_REGION, (int)n.at(k).as_number())) : 1;
			}
			rg.sphere = jstr(pa, "shape") == "sphere";
			rg.decorate = !pa.get("decorations").is_boolean() ||
					pa.get("decorations").is_true();
			const ss_ biome = jstr(pa, "biome", m_w->wp.biome);
			auto bi = m_w->materials.biomes.find(biome);
			if(bi == m_w->materials.biomes.end()){
				why = "entity "+itos(json::jint(r, "id", 0))+": no biome \""+
						biome+"\" in the material set";
				continue;
			}
			world::resolve_biome(m_w->materials, bi->second, id, rg.ids.structs,
					rg.ids);
			rg.ids.air = id("air");
			const int64_t soil = json::jint(pa, "soil_depth", -1);
			if(soil >= 0)
				rg.ids.filler_depth = (int)std::min<int64_t>(soil, 16);
			if(!rg.ids.top || !rg.ids.filler || !rg.ids.stone){
				why = "biome "+biome+" has no top, filler or stone";
				continue;
			}
			world::Heights h;
			h.p.generator = jstr(pa, "generator", "noise");
			h.p.seed = (uint32_t)json::jint(pa, "seed", 0);
			rg.seed = h.p.seed;
			const int64_t lv = json::jint(pa, "level", -1);
			h.p.level = rg.o[1] + (lv < 0 ? rg.n[1] / 2 - 1 : (int)lv);
			h.p.height = (int)json::jint(pa, "height", 2);
			h.p.spread = std::max(1, (int)json::jint(pa, "spread", 12));
			valleys_query(h);
			if(h.p.generator == "valleys" && !h.valleys){
				why = "the valleys generator needs builtin/luanti_mapgen";
				continue;
			}
			rg.h = &h;
			rg.cells(out);
		}
		return why.empty();
	}

	// The World's regions as the entities have them now
	json::Value regions_now()
	{
		json::Value out = json::array();
		for(auto &p : m_entities){
			const Entity &e = p.second;
			if(!e.has_pos || copy_by(e) || scene_of(e) != m_w->world_scene)
				continue;
			for(const Instance &in : e.comps){
				const ss_ &pn = m_types[in.type].world_region;
				if(pn.empty())
					continue;
				int n[3];
				extent(in.params.get(pn), n, MAX_WORLD_REGION);
				const pv::Vector3DInt32 o = voxel_p(e);
				json::Value r = json::object(), oa = json::array(),
						na = json::array();
				oa.append((int64_t)o.getX());
				oa.append((int64_t)o.getY());
				oa.append((int64_t)o.getZ());
				for(int k = 0; k < 3; k++)
					na.append((int64_t)n[k]);
				r.set("id", (int64_t)e.id);
				r.set("o", oa);
				r.set("n", na);
				r.set("params", in.params.deepcopy());
				out.append(r);
			}
		}
		return out;
	}

	// Every World's regions written as they are now (Stopped or not, never
	// in a session: a round's World is its start's); back: the edit's undo
	void regions_sync(Change *back, const ss_ &by)
	{
		if(!m_hosted || m_active)
			return;
		for(auto &wd : m_worlds){
			if(!wd.second.world_scene || !scene_id(wd.first))
				continue;
			WorldScope ws(m_w, &wd.second);
			region_sync_one(back, by);
		}
	}

	void region_sync_one(Change *back, const ss_ &by)
	{
		const json::Value now = regions_now();
		ss_ row;
		json::Value was = json::array();
		if(m_store->get(world_row("regions"), row)){
			const json::Value r = json::load_string(row.c_str());
			if(r.is_array())
				was = r.deepcopy();
		}
		if(now.stringify() == was.stringify())
			return;
		const main_context::SceneReference ref = m_w->world_scene;
		size_t wrote = 0, cleared = 0, images = 0, kept = 0;
		ss_ why;
		// Made out here: its valleys query reaches luanti_mapgen, which
		// depends on voxelworld and so cannot be accessed from inside it
		up_<world::Generator> g = diff_generator();
		voxelworld::access(m_server, ref, [&](voxelworld::Instance *w){
			std::unordered_map<int64_t, interface::VoxelTypeId> a, b;
			ss_ wwhy;
			region_cells(w, was, a, wwhy);
			region_cells(w, now, b, why);
			const pv::Vector3DInt16 ss = w->get_section_size_voxels();
			// The generated ground, a section at a time
			std::map<std::tuple<int, int, int>, up_<interface::VoxelVolume>> gen;
			interface::VoxelName an;
			an.block_name = "air";
			const interface::VoxelDefinition *ad = w->get_voxel_reg()->get(an);
			const uint32_t air = ad ? ad->id : 0;
			// (a heightmap's voxels are all air: its generator's sea is not)
			auto base = [&](const pv::Vector3DInt32 &q) -> uint32_t {
				if(m_w->wp.heightmap())
					return air;
				const pv::Vector3DInt16 sp = section_of(w, q);
				auto &v = gen[std::make_tuple(sp.getX(), sp.getY(), sp.getZ())];
				if(!v){
					const pv::Region r = w->get_section_region_voxels(sp);
					v.reset(new interface::VoxelVolume(r));
					g->generate(ref, sp, *v);
				}
				return v->getVoxelAt(q.getX(), q.getY(), q.getZ()).data;
			};
			sv_<pv::Vector3DInt32> done;
			auto put = [&](const pv::Vector3DInt32 &q, uint32_t v) -> bool {
				uint32_t old = 0;
				const bool have = loaded(w, q);
				if(!have && (v == air || v == 0))
					return false;
				if(have && voxel_id(w, q, old) && old == v)
					return false;
				const pv::Vector3DInt16 sp = section_of(w, q);
				if(sp.getY() < WORLD_SECTION_Y0 || sp.getY() > WORLD_SECTION_Y1)
					return false;
				if(!hm_section(w, q) && !loaded(w, q))
					w->load_or_generate_section(sp);
				if(!voxel_id(w, q, old) || old == v)
					return false;
				if(back)
					back->cells.emplace(std::make_tuple(q.getX(), q.getY(),
							q.getZ()), old);
				set_id(w, q, v);
				mark(w, ref, q, 'k', by);
				done.push_back(q);
				return true;
			};
			int x, y, z;
			for(auto &c : a){
				if(b.count(c.first))
					continue;
				world::Region::unkey(c.first, x, y, z);
				const pv::Vector3DInt32 q(x, y, z);
				uint32_t cur = 0;
				if(!voxel_id(w, q, cur))
					continue;
				if(type_of(w, cur) != c.second && !(cur == 0 && c.second == air)){
					kept++;
					continue;
				}
				cleared += put(q, base(q));
			}
			for(auto &c : b){
				auto ai = a.find(c.first);
				if(ai != a.end() && ai->second == c.second)
					continue;
				world::Region::unkey(c.first, x, y, z);
				wrote += put(pv::Vector3DInt32(x, y, z), c.second);
			}
			symmetry::Config cf;
			if(!done.empty() && sym_scene(ref, cf))
				images = sym_write(w, ref, cf, done, back ? &back->cells :
						nullptr, by);
		});
		if(!why.empty())
			warn("kit/world_region: "+why);
		m_store->set(world_row("regions"), now.stringify());
		if(back && (wrote || cleared)){
			back->stroke = -3;
			back->scene = ref;
		}
		log_i(MODULE, "World%s: kit/world_region: %u regions, %zu cells "
				"written, %zu cleared (%zu changed since kept)%s", cs(by.empty() ?
				ss_() : " by "+by), (unsigned)now.size(), wrote, cleared, kept,
				images ? cs(", "+itos(images)+" symmetry images") : "");
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
				// [KIT_HM_ORIGIN] kept by world cell; one the map no longer
				// holds (a resize since) is left
				const int ox = hm_ox(map), oz = hm_oz(map);
				for(auto &q : c.samples){
					const int sx = q.first.first - ox, sz = q.first.second - oz;
					if(sx < 0 || sz < 0 || sx >= map->samples_x() ||
							sz >= map->samples_z())
						continue;
					map->set_height(sx, sz, q.second.first);
					map->set_weights(sx, sz, q.second.second);
					x0 = std::min(x0, q.first.first);
					x1 = std::max(x1, q.first.first);
					z0 = std::min(z0, q.first.second);
					z1 = std::max(z1, q.first.second);
				}
			});
		// [KIT_HEIGHTMAP_REGEN_LOSS] the samples' edit marks as they were
		for(auto &q : c.hm_marks){
			if(q.second.first)
				m_w->hm_edits[q.first] = q.second.second;
			else
				m_w->hm_edits.erase(q.first);
			m_w->hm_edits_dirty.insert(std::make_pair(floor_div(q.first.first,
					HM_EDIT_CHUNK), floor_div(q.first.second, HM_EDIT_CHUNK)));
		}
		hm_edits_save();
		for(uint64_t id : c.decor)
			remove_decor(id);
		for(const Decor &d : c.decor_gone)
			m_w->decor[add_decor(d.structure, d.x, d.y, d.z, d.yaw)].hand = d.hand;
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
			// [KIT_SCENES_EMPTY_CELL] id 0 has no name: a section loaded
			// and not generated yet holds it
			what = (!d ? ss_("?") : d->name.block_name.empty() ?
					ss_("undefined") : d->name.block_name)+
					", param "+itos(f.param.bound() ? f.param.get(word) : 0)+
					", tint "+itos(f.tint.bound() ? f.tint.get(word) : 0)+
					", sky light "+itos(f.light_sky.bound() ?
					f.light_sky.get(word) : 0);
		});
		if(what.empty())
			return refuse("the cell's section is not loaded");
		// ([KIT_FREE_ROTATION] and the region deciding it)
		const Entity *re = nullptr;
		const Instance *rg = region_at(p.scene, c[0], c[1], c[2], &re);
		log_i(MODULE, "Voxel at (%i,%i,%i): %s%s", c[0], c[1], c[2], cs(what),
				rg ? cs(", region "+itos(re->id)) : "");
	}

	// [KIT_MOVING_OBJECTS] {"op": "body_ray", "pos": [x, y, z]}: what Bullet's bodies
	// in the builder's scene say straight down from there, and the motion's time,
	// logged (a check's read-back that the collision goes with a moving object)
	void body_ray(Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const json::Value &pos = j.get("pos");
		if(!pos_ok(pos))
			return refuse("pos: [x, y, z]");
		auto si = m_host.scenes.find(p.scene);
		if(si == m_host.scenes.end())
			return refuse("not in a scene of the app's");
		const double x = pos.at(0u).as_number(), y = pos.at(1u).as_number(),
				z = pos.at(2u).as_number();
		bool hit = false;
		float at = 0;
		voxel_objects::access(m_server, [&](voxel_objects::Interface *iv){
			voxel_objects::Instance *vo = iv->get_instance(si->second);
			hit = vo && vo->ray_down(magic::Vector3(x, y, z), 256, &at);
		});
		log_i(MODULE, "Bullet down from (%.3f,%.3f,%.3f) at %.3f: %s", x, y, z,
				motion_t(), hit ? cs(ftos(at)) : "nothing");
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
		// [KIT_SYMMETRY] in the authored slice, written into the others too
		symmetry::Config cf;
		const Entity *sym = sym_scene(si->second, cf);
		if(sym && !cf.editable(c[0], c[2]))
			return refuse("("+itos(c[0])+","+itos(c[2])+") is outside kit/symmetry "+
					itos(sym->id)+"'s authored slice "+cf.slice);
		std::map<std::tuple<int, int, int>, uint32_t> images;
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
			if(r == voxelworld::Instance::WRITTEN && sym)
				sym_write(w, si->second, cf, {q}, &images, p.name);
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
		nc.cells.insert(images.begin(), images.end());
		u.push_back(nc);
		while(u.size() > UNDO_MAX)
			u.pop_front();
		log_i(MODULE, "A voxel edit by %s: %s%s (%zu to undo)", cs(p.name),
				cs(what), sym ? cs(", "+itos(images.size())+" images") : "",
				u.size());
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
		// [KIT_SYMMETRY] a box in the authored slice, written into the others
		symmetry::Config cf;
		const Entity *sym = sym_scene(nc.scene, cf);
		if(sym && (!cf.editable(o.getX(), o.getZ()) || !cf.editable(o.getX() + n[0] -
				1, o.getZ()) || !cf.editable(o.getX(), o.getZ() + n[2] - 1) ||
				!cf.editable(o.getX() + n[0] - 1, o.getZ() + n[2] - 1)))
			return refuse(who+": its box is outside kit/symmetry "+itos(sym->id)+
					"'s authored slice "+cf.slice+" (its source's shows it)");
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
			if(sym){
				sv_<pv::Vector3DInt32> wrote;
				for(auto &q : nc.cells)
					wrote.push_back(pv::Vector3DInt32(std::get<0>(q.first),
							std::get<1>(q.first), std::get<2>(q.first)));
				sym_write(w, nc.scene, cf, wrote, &nc.cells, p.name);
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
		const bool lean = m_w->lean_world != nullptr;
		if(p.heightmap() || !p.finite() || lean){
			// [KIT_HM_WALK] round the spawn and each player; a heightmap's
			// voxels are air built on over the terrain
			// [KIT_HM_FREE] A heightmap's: only the sections the save has
			// (what was built) loaded, none generated (-1): a body walks
			// over cells not loaded (move.lua's), and an edit generates
			// its own section (hm_section())
			// A session's finite map: only what the start (its source) or
			// its own save has, nothing generated
			const bool none = p.heightmap() || lean;
			const int hgen = none ? -1 : 1;
			double x = 0, y = 0, z = 0;
			world_spawn(x, y, z);
			pts.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					none ? (int)x : 0, (int)y, none ? (int)z : 0),
					1, 1, hgen, hgen));
			const int gxz = none ? -1 : world::GEN_XZ;
			const int gy = none ? -1 : world::LOAD_Y;
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
		if(!m_w->world_scene || (m_w->wp.finite() && !m_w->wp.heightmap() &&
				!m_w->lean_world) || m_w->name != scene)
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
				x = hm_ox(map) + map->samples_x() / 2 + 0.5;
				z = hm_oz(map) + map->samples_z() / 2 + 0.5;
				y = map->height_at((float)x, (float)z) + 0.5;
			});
			// [KIT_AIRSHIPS_2] on the highest voxel over it (a floating
			// island of kit/world_region's), not under it
			voxelworld::access(m_server, m_w->world_scene,
					[&](voxelworld::Instance *w){
				interface::VoxelName an;
				an.block_name = "air";
				const interface::VoxelDefinition *ad = w->get_voxel_reg()->get(an);
				const uint32_t air = ad ? ad->id : 0;
				const int lo = std::max((int)std::floor(y),
						WORLD_SECTION_Y0 * WORLD_SECTION);
				for(int vy = (WORLD_SECTION_Y1 + 1) * WORLD_SECTION - 1; vy >= lo; vy--){
					uint32_t v = 0;
					if(voxel_id(w, pv::Vector3DInt32((int)std::floor(x), vy,
							(int)std::floor(z)), v) && v &&
							type_of(w, v) != air){
						y = vy + 1;
						return;
					}
				}
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
		// [KIT_SCENES_EMPTY_CELL] A new World's queue drains between the
		// streamer's batches: told "generated" after its first two
		// sections, a builder read the cell they stood by as id 0. The
		// section at each load point (the spawn, each player) is in first.
		// simplified: the point's own section, not all of its generate
		// radius
		if(back && m_w->world_first)
			voxelworld::access(m_server, m_w->world_scene,
					[&](voxelworld::Instance *w){
				const pv::Vector3DInt16 ss = w->get_section_size_voxels();
				auto div = [](int32_t a, int b){
					return (int16_t)std::floor((double)a / b);
				};
				for(const voxelworld::LoadPoint &lp : w->get_load_points()){
					if(lp.generate_xz < 0 || lp.generate_y < 0 || lp.hold_only)
						continue;
					const pv::Vector3DInt16 sp(div(lp.p.getX(), ss.getX()),
							div(lp.p.getY(), ss.getY()),
							div(lp.p.getZ(), ss.getZ()));
					// One out of the World's region is never generated
					if(sp.getY() < WORLD_SECTION_Y0 ||
							sp.getY() > WORLD_SECTION_Y1 ||
							std::abs(sp.getX()) >= WORLD_SECTIONS_XZ ||
							std::abs(sp.getZ()) >= WORLD_SECTIONS_XZ)
						continue;
					if(!w->is_section_loaded(sp) ||
							!w->is_section_generated(sp)){
						back = false;
						break;
					}
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
		// [KIT_SYMMETRY] the authored slice copied over the ground generated
		// (sections loaded for the first time or a regeneration's; no undo:
		// a regeneration's undo is its own)
		symmetry::Config cf;
		if(const Entity *s = sym_scene(m_w->world_scene, cf))
			log_i(MODULE, "kit/symmetry %s: the slice %s copied over the others "
					"after %s: %s", cs(itos(s->id)), cs(cf.slice),
					m_w->world_regenerating ? "the regeneration" : "a generation",
					cs(sym_copy(m_w->world_scene, cf, true, nullptr, "kit").text()));
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
			if(!n)
				return;
			// [KIT_MOVING_OBJECTS] on a moving deck: the place with the deck at rest
			// and which deck, so that one standing still sends nothing and the clients
			// draw it on the deck they draw. In a variable: a client smooths a node's
			// position towards what it is sent, and it moves this one from the rest itself
			if(p.frame){
				char rest[96];
				snprintf(rest, sizeof rest, "%.5f %.5f %.5f", p.frame_rest[0],
						p.frame_rest[1], p.frame_rest[2]);
				n->SetVar(magic::StringHash("kit_rest"), magic::Variant(magic::String(rest)));
			} else {
				n->SetPosition(magic::Vector3(e.pos[0], e.pos[1], e.pos[2]));
			}
			const magic::Variant &was = n->GetVar(magic::StringHash("kit_frame"));
			if(was.IsEmpty() ? p.frame != 0 : (uint64_t)was.GetInt() != p.frame)
				n->SetVar(magic::StringHash("kit_frame"), magic::Variant((int)p.frame));
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

	// [KIT_FLAG_CLICK_RANGE] A type's own `use_range` ("param:<name>"): its
	// parameter's value, -1 with none
	double use_range_of(const Instance &in)
	{
		const json::Value &u = m_types[in.type].decl.get("use_range");
		if(!u.is_string() || u.as_string().compare(0, 6, "param:") != 0)
			return -1;
		const json::Value &v = in.params.get(u.as_string().substr(6));
		return v.is_number() ? v.as_number() : -1;
	}

	// What its types show every client: the first look and hud
	json::Value show_of(const Entity &e)
	{
		json::Value show = json::object(), parts = json::array();
		std::set<ss_> shared;
		for(const Instance &in : e.comps){
			const json::Value &d = m_types[in.type].decl;
			if(show.get("look").is_undefined() && !d.get("look").is_undefined()){
				json::Value l = look_of(in, d.get("look"));
				// [KIT_OWN_LOOK] hidden in play
				if(in.params.get("own_look").is_false())
					l.set("hidden", true);
				show.set("look", l);
			}
			if(show.get("hud").is_undefined() && !d.get("hud").is_undefined())
				show.set("hud", d.get("hud"));
			// [KIT_CTF] its world marker, "param:<name>" as a look's
			if(show.get("marker").is_undefined() && d.get("marker").is_object())
				show.set("marker", look_of(in, d.get("marker")));
			// [KIT_FLAG_RIGHT_CLICK] the shared state naming the player
			// whose right click uses it
			if(show.get("right_use").is_undefined() &&
					d.get("right_use").is_string())
				show.set("right_use", d.get("right_use"));
			// [KIT_FLAG_CLICK_RANGE] where and when a client's pointer shows
			// it as usable
			if(use_range_of(in) >= 0)
				show.set("use_range", use_range_of(in));
			if(show.get("use_when").is_undefined() &&
					d.get("use_when").is_string())
				show.set("use_when", d.get("use_when"));
			// [KIT_UI_COMPONENTS] Its UI, "param:<name>" as a look's
			if(show.get("ui").is_undefined() && d.get("ui").is_object()){
				json::Value u = look_of(in, d.get("ui"));
				u.set("comp", (int64_t)(&in - &e.comps[0]));
				// [KIT_PANEL_PARENT] (no parents in a player's state)
				if(const uint64_t pn = panel_of(e))
					u.set("panel", (int64_t)pn);
				show.set("ui", u);
			}
			// [KIT] stage 4e2: what a click would do, shown on it: it is
			// used (a client's use reaches it), it grants digging or placing
			// in its box (its state's dig and place, shared)
			const Type &ty = m_types[in.type];
			// [KIT_PLAYER_MODEL] a team's colour, its members' (its state's
			// members, shared) tint on their bodies
			if(ty.team && show.get("team_color").is_undefined())
				show.set("team_color", jstr(in.params, "color"));
			// (a seat: taken by a use, [KIT] stage 4h)
			// ([KIT_USE_ACCESS] "locked": its use is nobody's, a click
			// told so)
			if(use_kind(e, in)){
				if(jstr(in.params, "use") != "nobody")
					show.set("usable", true);
				else if(!show.get("usable").is_true())
					show.set("usable", ss_("locked"));
			}
			// [KIT] stage 4j: a region's extent by its parameter (its state's
			// size while resized), and its border drawn in play
			if(!ty.region.empty() && show.get("region").is_undefined()){
				int n[3];
				extent(in.params.get(ty.region), n, MAX_REGION_EXTENT);
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
				if(!m_types[in.type].per_player.count(k))
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
		if(e.kind == "player"){
			show.set("player", true);
			// [KIT_SPECTATE] whom a spectator watches
			show.set("player_name", e.name);
		}
		// [KIT_TOOLS_1] a hit reaches it (hands.lua's pick)
		for(const Instance &in : e.comps)
			if(m_types[in.type].health && in.disabled.empty())
				show.set("health", true);
		return show;
	}

	// [KIT_NESTING] The entity a positioned one is under (0: a scene)
	uint64_t parent_node_id(const Entity &e)
	{
		auto it = m_entities.find(e.parent);
		return it != m_entities.end() && it->second.has_pos ? e.parent : 0;
	}

	void make_node(Entity &e)
	{
		const json::Value show = show_of(e);
		main_context::SceneReference ref = scene_of(e);
		double w[3];
		Turn wq;
		{
			AtRest rest(m_at_rest);
			world_of(e, w, &wq);
		}
		main_context::access(m_server, ref, [&](magic::Scene *scene){
			magic::Node *n = scene->CreateChild(("kit:"+itos(e.id)).c_str());
			n->SetPosition(magic::Vector3(w[0], w[1], w[2]));
			n->SetRotation(wq.q());
			n->SetVar(magic::StringHash("kit_id"), magic::Variant((int)e.id));
			n->SetVar(magic::StringHash("kit_parent"),
					magic::Variant((int)parent_node_id(e)));
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
		if(m_types[e.comps[comp].type].per_player.count(key)){
			for(auto &p : m_peers)
				send_mine(p.first, e, comp, key);
			return;
		}
		const ss_ v = e.comps[comp].state.get(key).stringify();
		main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
			magic::Node *n = scene->GetNode(e.node);
			if(n)
				n->SetVar(magic::StringHash(("kit:"+key).c_str()),
						magic::Variant(v.c_str()));
		});
		// [KIT_NESTING] the state that moves its look (kit/mover's out)
		// moves what is under it
		const json::Value &look = m_types[e.comps[comp].type].decl.get("look");
		if(look.is_object() && jstr(look, "state") == key &&
				look.get("when").is_object() &&
				!look.get("when").get("offset").is_undefined())
			place_nodes(e.id);
	}

	// [KIT_UI_COMPONENTS] A per_player state's value for a peer placed in
	// the entity's scene: their own ({"player:<id>": v}'s; null: none),
	// into the batch or sent as "kit:mine" {"list": [{"id", "key",
	// "value"}]} when it is not what they were sent last
	void send_mine(size_t peer, const Entity &e, size_t comp, const ss_ &key,
			json::Value *batch = nullptr)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end() || !pi->second.player || !e.node)
			return;
		ss_ scene;
		scene_of(e, &scene);
		if(scene != pi->second.scene)
			return;
		const json::Value &all = e.comps[comp].state.get(key);
		json::Value v = all.is_object() ?
				all.get("player:"+itos(pi->second.player)) : json::null();
		if(v.is_undefined())
			v = json::null();
		const ss_ text = v.stringify(), k = itos(e.id)+":"+key;
		auto &sent = pi->second.mine_sent;
		auto it = sent.find(k);
		if(it == sent.end() ? v.is_null() : it->second == text)
			return;
		sent[k] = text;
		json::Value o = json::object();
		o.set("id", (int64_t)e.id);
		o.set("key", key);
		o.set("value", v);
		if(batch){
			batch->append(o);
			return;
		}
		json::Value m = json::object(), l = json::array();
		l.append(o);
		m.set("list", l);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:mine", m.stringify());
		});
	}

	// All of a peer's own, as they come into a scene or as another player:
	// "kit:mine" {"all": true, "list"} (what they had before dropped)
	void send_all_mine(size_t peer)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return;
		pi->second.mine_sent.clear();
		json::Value l = json::array();
		for(auto &p : m_entities)
			for(size_t i = 0; i < p.second.comps.size(); i++)
				for(const ss_ &k : m_types[p.second.comps[i].type].per_player)
					send_mine(peer, p.second, i, k, &l);
		json::Value m = json::object();
		m.set("all", true);
		m.set("list", l);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:mine", m.stringify());
		});
	}

	// [KIT_UI_COMPONENTS] Whether a UI entity (a type with `ui`) is up for
	// a player (their entity): its state `shown`, everyone's, under their
	// own ("own": {"player:<id>": {shown}}), and its panel's (its parent,
	// if a panel) the same way
	bool ui_visible(uint64_t id, uint64_t player, int depth = 0)
	{
		auto it = m_entities.find(id);
		if(it == m_entities.end() || depth > 8)
			return false;
		for(const Instance &in : it->second.comps){
			const json::Value &d = m_types[in.type].decl.get("ui");
			if(!d.is_object())
				continue;
			bool shown = in.state.get("shown").is_true();
			const json::Value &own = in.state.get("own");
			if(own.is_object()){
				const json::Value &o = own.get("player:"+itos(player));
				if(o.is_object() && o.get("shown").is_boolean())
					shown = o.get("shown").is_true();
			}
			if(!shown)
				return false;
			const uint64_t pid = panel_of(it->second);
			return !pid || ui_visible(pid, player, depth + 1);
		}
		return false;
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
			// [KIT_AIRSHIPS] a wallet's repair is Kit's: its player's ships
			if(in.type == WALLET_TYPE && input == "repair")
				repair_ships(to);
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
		// [KIT_PANEL_PARENT]
		if(const uint64_t pn = panel_of(e))
			o += ",panel="+itos(pn);
		// [KIT_TOOLS_1] a player's entity (kit/health respawns them)
		if(e.kind == "player")
			o += ",is_player=true";
		if(e.has_pos){
			// [KIT_NESTING] the world's
			double w[3];
			Turn wq;
			world_of(e, w, &wq);
			o += ",pos={";
			for(int k = 0; k < 3; k++){
				lua_lit(json::Value(w[k]), o);
				o += ',';
			}
			o += "},yaw=";
			lua_lit(json::Value(wq.yaw()), o);
		}
		o += ",params=";
		// [KIT_INVENTORY_PLAY] Kit's own inventory stores by the rules
		lua_lit(in.type == "kit/inventory" ? inv_params() : in.params, o);
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
				lua_lit(pv_->type == "kit/inventory" ? inv_params() :
						pv_->params, o);
				o += ",state=";
				lua_lit(pv_->state, o);
				o += "}";
			}
		} else if(r.handler == "on_leave"){
			// [KIT_GUEST_NO_LEAVE] A guest's entity dropped: who left it, by
			// the id they had (no inventory: it went with the entity)
			names.set(r.by, player_of(r.by));
			o += ",player_id="+r.by.substr(7)+",player=";
			lua_lit(json::Value(r.by), o);
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
			// [KIT_CTF] its scene: a player in another is `away`
			ss_ own_scene;
			scene_of(e, &own_scene);
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
				// [KIT_CTF] where they are (the world's, their feet's cell's
				// middle), which way they look, alive
				if(it->second.has_pos){
					double w[3];
					world_of(it->second, w);
					json::Value pos = json::array();
					for(int k = 0; k < 3; k++)
						pos.append(w[k]);
					j.set("pos", pos);
					auto bi = m_bodies.find(peer_of_player(pl.second));
					j.set("yaw", bi != m_bodies.end() ? bi->second.look_yaw :
							it->second.yaw);
					ss_ ps;
					scene_of(it->second, &ps);
					if(!own_scene.empty() && ps != own_scene)
						j.set("away", true);
				}
				j.set("alive", player_alive(it->second));
				players.append(j);
				names.set("player:"+itos(pl.second), pl.first);
			}
			o += ",players=";
			lua_lit(players, o);
		}
		// [KIT_CTF] its scene's regions: {id, team, rules, o, n} (the
		// enabled ones; c:region_at picks the smallest holding a cell)
		if(m_types[in.type].regions){
			ss_ scene;
			scene_of(e, &scene);
			json::Value regions = json::array();
			for(auto &p : m_entities){
				const Entity &re = p.second;
				if(!re.has_pos)
					continue;
				for(const Instance &ri : re.comps){
					const Type &rt = m_types[ri.type];
					if(rt.region.empty() || !ri.disabled.empty() ||
							ri.state.get("enabled").is_false())
						continue;
					ss_ rs;
					scene_of(re, &rs);
					if(rs != scene)
						continue;
					int n[3];
					region_extent(ri, rt, n);
					double c[3];
					Turn rq;
					box_frame(re, c, rq);
					json::Value j = json::object(), o = json::array(),
							nn = json::array();
					for(int k = 0; k < 3; k++)
						o.append(c[k]);
					// [KIT_FREE_ROTATION] turned: o its corner cell's middle,
					// q its turn
					if(!rq.none()){
						json::Value q = json::array();
						for(double v : {rq.w, rq.x, rq.y, rq.z})
							q.append(v);
						j.set("q", q);
					}
					for(int k = 0; k < 3; k++)
						nn.append(n[k]);
					j.set("id", (int64_t)re.id);
					j.set("team", (int64_t)team_over(re));
					j.set("rules", ri.state.get("rules").is_object() ?
							ri.state.get("rules") : json::object());
					j.set("o", o);
					j.set("n", nn);
					regions.append(j);
				}
			}
			o += ",regions=";
			lua_lit(regions, o);
		}
		// [KIT_MINIGAMES_1] its teams, by id: {id, params, state}
		if(m_types[in.type].teams){
			json::Value teams = json::array();
			for(uint64_t tid : teams_of(e))
				for(const Instance &ti : m_entities[tid].comps)
					if(m_types[ti.type].team){
						json::Value j = json::object();
						j.set("id", (int64_t)tid);
						j.set("params", ti.params);
						j.set("state", ti.state);
						teams.append(j);
						break;
					}
			o += ",teams=";
			lua_lit(teams, o);
			// [KIT_MAP_ROTATION] the composition's scenes
			json::Value scenes = json::array();
			for(auto &sn : m_host.scenes)
				scenes.append(sn.first);
			o += ",scenes=";
			lua_lit(scenes, o);
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
		// [KIT_MINIGAMES_FIX] its own name (c:name(c.id)), and whether the
		// player who set it off is elsewhere than its scene
		if(!e.name.empty())
			names.set(itos(e.id), e.name);
		if(pid){
			ss_ scene;
			scene_of(e, &scene);
			if(!peer_of(player_of(r.by), scene))
				o += ",player_away=true";
		}
		o += ",names=";
		lua_lit(names, o);
		// [KIT_SESSIONS_1] the session it runs in (0: the default);
		// [KIT_MINIGAMES_FIX] the entity whose run started it (0: none, a
		// draft's)
		o += ",session="+itos(m_active);
		if(GameSession *gs = active_session())
			o += ",session_maker="+itos(gs->maker)+",session_players="+
					itos(gs->start_players);
		// [KIT_LATE_JOIN] the game sessions it made (from the default
		// round): each one's players now, those its start took and its
		// clock (s)
		if(!m_active){
			o += ",sessions={";
			for(auto &s : m_sessions){
				const GameSession &gs = *s.second;
				if(gs.draft || gs.maker != e.id || gs.maker_comp != ci)
					continue;
				size_t n = 0;
				for(auto &ps : m_peer_session)
					n += ps.second == s.first;
				o += "["+itos(s.first)+"]={players="+itos(n)+",taken="+
						itos(gs.start_players)+",clock="+itos((interface::os::
						game_us() - gs.ctx.clock_base) / 1000000)+"},";
			}
			o += "}";
		}
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
		// [KIT_TOOLS_1] modify_hit's hit as it goes on
		if(fx.get("hit").is_object())
			m_hit_ret = fx.get("hit");
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
		// [KIT_TEAM_JOIN_LEAVES_OTHERS] A team joined: the player out of the
		// scene's other teams (respawn_at takes the last one they are in)
		if(t.team && pid && r.handler == "on_input" &&
				jstr_at(r.args, 0) == "join" && in_team(pid, e.id))
			leave_teams(pid, e);
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
			if(!m_watches.empty())
				watch_fired(e.id, r.comp, output, value);
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
				const uint64_t from = e.id, to = l.to;
				const ss_ input = l.input;
				deliver(to, input, value, r.by, r.hops + 1, from, output);
				// [KIT_SYMMETRY] from outside its group, to each copy too
				// (simplified: a scan of the entities each such signal)
				const uint64_t sid = sym_source(to);
				if(sid && sym_source(from) != sid && copy_by(from) != sid){
					sv_<uint64_t> copies;
					for(auto &x : m_entities)
						if(copy_by(x.second) == sid && (uint64_t)json::jint(
								x.second.built, "source", 0) == to)
							copies.push_back(x.first);
					for(uint64_t c : copies)
						deliver(c, input, value, r.by, r.hops + 1, from, output);
				}
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
				double bo[3];
				Turn bq;
				box_frame(e, bo, bq);
				if(n[0] * n[1] * n[2] > MAX_SET_CELLS){
					log_w(MODULE, "Entity %s's %s sets %i cells, past %i",
							cs(itos(e.id)), cs(type), n[0] * n[1] * n[2],
							MAX_SET_CELLS);
				} else if(!t.region.empty() && !bq.none()){
					// [KIT_FREE_ROTATION] the world's cells with their middles in it
					double lo[3], hi[3];
					for(int k = 0; k < 3; k++)
						lo[k] = bo[k], hi[k] = bo[k];
					for(int c = 0; c < 8; c++){
						double v[3];
						for(int k = 0; k < 3; k++)
							v[k] = c >> k & 1 ? n[k] - 0.5 : -0.5;
						bq.apply(v);
						for(int k = 0; k < 3; k++){
							lo[k] = std::min(lo[k], bo[k] + v[k]);
							hi[k] = std::max(hi[k], bo[k] + v[k]);
						}
					}
					for(int x = std::floor(lo[0]); x <= std::ceil(hi[0]); x++)
						for(int y = std::floor(lo[1]); y <= std::ceil(hi[1]); y++)
							for(int z = std::floor(lo[2]); z <= std::ceil(hi[2]); z++){
								const double p[3] = {(double)x, (double)y, (double)z};
								if(box_holds(bo, bq, n, p))
									cells.push_back(pv::Vector3DInt32(x, y, z));
							}
				} else {
					for(int x = 0; x < n[0]; x++)
						for(int y = 0; y < n[1]; y++)
							for(int z = 0; z < n[2]; z++)
								cells.push_back(o + pv::Vector3DInt32(x, y, z));
				}
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
		// [KIT_SOUNDS] c:sound(name, {everywhere}): at the entity (none
		// placed, or everywhere: not positional), heard in its scene (one
		// with no scene: in every one)
		const json::Value &sounds = fx.get("sounds");
		for(unsigned i = 0; i < sounds.size(); i++){
			ss_ scene;
			const bool in_scene = scene_of(e, &scene) != nullptr ||
					!scene.empty();
			double w[3];
			const bool at = e.has_pos && !sounds.at(i).at(1u).is_true();
			if(at)
				world_of(e, w);
			play_sound(jstr_at(sounds.at(i), 0), in_scene ? &scene : nullptr,
					at ? w : nullptr, "entity "+itos(e.id)+"'s "+type);
		}
		// [KIT_PARTICLES] c:effect, c:event
		const json::Value &effects = fx.get("effects");
		for(unsigned i = 0; i < effects.size(); i++)
			effect_fx(e, type, effects.at(i));
		const json::Value &events = fx.get("events");
		for(unsigned i = 0; i < events.size(); i++)
			event_fx(e, type, events.at(i), r.by);
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
			// The running timer set again: from its due time, so a chain
			// keeps its period (a tick late at most, not a tick each)
			const bool own = r.timer_due && r.handler == "on_timer" &&
					jstr_at(r.args, 0) == name && jstr_at(r.args, 1) == player;
			set_timer(e, in, name, player, s, r.by, own ? r.timer_due : 0);
		}
		const ss_ who = player_of(r.by);
		const json::Value &tp = fx.get("teleport");
		if(tp.is_array())
			teleport(e, type, who, tp, fx.get("teleport_yaw"),
					fx.get("teleport_scene"), fx.get("teleport_entity"));
		// [KIT_CTF] c:move (its own entity), c:speed (players it reaches)
		const json::Value &mv = fx.get("move");
		if(mv.is_array())
			move_fx(e, r.comp, mv, r.by);
		const json::Value &speeds = fx.get("speed");
		for(unsigned i = 0; i < speeds.size(); i++)
			speed_fx(e, r.comp, r.by, speeds.at(i));
		const json::Value &set_params = fx.get("set_param");
		for(unsigned i = 0; i < set_params.size(); i++)
			set_param_fx(e, r.comp, r.by, set_params.at(i));
		// [KIT_CARRY_ATTACH] c:attach, c:detach
		const json::Value &att = fx.get("attach");
		if(att.is_array())
			attach_fx(e, r.comp, r.by, att);
		else if(att.is_false() && m_attached.count(e.id))
			detach(e.id, "c:detach");
		const json::Value &apps = fx.get("app");
		for(unsigned i = 0; i < apps.size(); i++)
			app_call(e, type, r.by, who, apps.at(i));
		const json::Value &sessions = fx.get("sessions");
		if(sessions.size())
			session_fx(e, r.comp, r, sessions);
		const json::Value &items = fx.get("items");
		if(!who.empty() && !items.is_undefined())
			got_items(e, type, who, items);
		// [KIT_TOOLS_1] kit/health's c:respawn() on a player's entity
		if(fx.get("respawn").is_true() && e.kind == "player")
			respawn_player(e.id);
		// [KIT_CTF] a health's c:died(by, type) on a player's entity; a
		// component's c:respawn_waiting(), c:hurt() and c:explode() (each
		// running the targets' hooks now: what the caller's run() reads
		// kept)
		const json::Value &died = fx.get("died");
		const json::Value &hurts = fx.get("hurt");
		const json::Value &blasts = fx.get("explode");
		if((died.is_array() && e.kind == "player") ||
				fx.get("respawn_waiting").is_true() || hurts.size() ||
				blasts.size()){
			const json::Value ret = m_ret, hit_ret = m_hit_ret;
			const uint64_t self = e.id;
			if(died.is_array() && e.kind == "player")
				player_death(self, r.by, name_ok(jstr_at(died, 1)) ?
						jstr_at(died, 1) : ss_("normal"));
			if(fx.get("respawn_waiting").is_true())
				log_i(MODULE, "Entity %s's %s respawns %i waiting players",
						cs(itos(self)), cs(type), respawn_waiting());
			for(unsigned i = 0; i < hurts.size() && m_entities.count(self);
					i++)
				hurt(m_entities[self], type, hurts.at(i), r.by);
			for(unsigned i = 0; i < blasts.size() && m_entities.count(self);
					i++)
				explode(m_entities[self], type, blasts.at(i), r.by);
			m_ret = ret;
			m_hit_ret = hit_ret;
		}
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
	// run off, every player for a type that reads them (`players`), and
	// [KIT_PANEL_PARENT] the panel it is in
	std::set<uint64_t> reach(const Entity &e, size_t comp, const ss_ &by)
	{
		std::set<uint64_t> r;
		r.insert(e.id);
		if(comp >= e.comps.size())
			return r;
		if(const uint64_t pn = panel_of(e))
			r.insert(pn);
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
		if(m_types[in.type].teams)
			for(uint64_t tid : teams_of(e))
				r.insert(tid);
		return r;
	}

	// [KIT_MINIGAMES_FIX] The teams a `teams = true` type reads: those in
	// its scene, and of those the ones under its own parent when there are
	// any (a placed prefab's own)
	// [KIT_CTF] A `map` scene of its own (kit/arena's): that scene's teams
	sv_<uint64_t> teams_of(const Entity &e)
	{
		ss_ scene;
		scene_of(e, &scene);
		for(const Instance &in : e.comps)
			if(m_types[in.type].teams && m_host.scenes.count(
					jstr(in.params, "map")))
				scene = jstr(in.params, "map");
		// [KIT_MAP_ROTATION] Its round's: the map picked for it
		const GameSession *gs = active_session();
		if(gs && gs->maker == e.id && !gs->map.empty())
			scene = gs->map;
		sv_<uint64_t> all, sib;
		for(auto &p : m_entities){
			bool team = false;
			for(const Instance &ti : p.second.comps)
				team = team || m_types[ti.type].team;
			ss_ ts;
			if(!team || !scene_of(p.second, &ts) || ts != scene)
				continue;
			all.push_back(p.first);
			if(p.second.parent == e.parent)
				sib.push_back(p.first);
		}
		return sib.empty() ? all : sib;
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
				// [KIT_AIRSHIPS] one with voxels: a free copy, its root first
				if(pf)
					out["prefab:"+n] = pf->get("entities").size() +
							(pf->get("voxels").is_object() ? 1 : 0);
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

	// [KIT_AIRSHIPS] A free copy's root row, as place_prefab's "free": kit/prefab_copy
	// and the prefab's "root" components ({"root": {"components": [{"type",
	// "params"}...]}}: what a copy's root carries, a movement, a hull), at base
	json::Value free_root_row(const json::Value &pf, const ss_ &name, uint64_t id,
			uint64_t parent, const double base[3])
	{
		json::Value row = json::object(), comps = json::array(), comp = json::object(),
				ps = json::object(), pi = json::object(), pos = json::array();
		row.set("id", (int64_t)id);
		row.set("parent", (int64_t)parent);
		row.set("name", name.substr(name.find('/') + 1)+" "+itos(id));
		pi.set("of", name);
		pi.set("version", json::jint(pf, "version", 1));
		pi.set("voxels", voxels_version(pf));
		row.set("prefab", pi);
		for(int k = 0; k < 3; k++)
			pos.append(grid(base[k]));
		row.set("pos", pos);
		comp.set("type", PREFAB_ROOT);
		ps.set("mode", "free");
		comp.set("params", ps);
		comps.append(comp);
		root_components(pf, comps);
		row.set("components", comps);
		return row;
	}

	// The prefab's root components appended to a copy root's
	void root_components(const json::Value &pf, json::Value &comps)
	{
		const json::Value &rc = pf.get("root").get("components");
		for(unsigned i = 0; i < rc.size(); i++){
			json::Value c = json::object();
			c.set("type", full_type(jstr(rc.at(i), "type")));
			c.set("params", rc.at(i).get("params").is_object() ?
					rc.at(i).get("params").deepcopy() : json::object());
			c.set("links", json::array());
			comps.append(c);
		}
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
			first_place(g, base);
			pf = group_prefab(g, base);
		}
		const json::Value &pos = s.at(1u);
		if(pos_ok(pos)){
			for(unsigned k = 0; k < 3; k++)
				base[k] = pos.at(k).as_number();
		} else if(e.has_pos){
			world_of(e, base);
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
		// [KIT_AIRSHIPS] A prefab with voxels: a free copy as the editor's "Place
		// free" makes, its root (kit/prefab_copy free, the prefab's root components)
		// at pos and its members under it, its voxels a free object
		const bool free = !name.empty() && pf.get("voxels").is_object();
		if(free){
			rows.push_back(free_root_row(pf, name, first, sc, base));
			const double zero[3] = {0, 0, 0};
			instantiate(pf, "", first, zero, first + 1, rows);
		} else {
			instantiate(pf, name, sc, base, first, rows);
		}
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
			if(wants_node(n))
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
		if(free)
			sync_free_objects();
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
		// [KIT_AIRSHIPS] a free copy's root components: types that go on an
		// entity with others, their parameters theirs (no entity parameters)
		const json::Value &rt = j.get("root");
		if(!rt.is_undefined()){
			const json::Value &rc = rt.get("components");
			if(!vox || !rt.is_object() || !rc.is_array() || rc.size() > 8){
				why = "root: {\"components\": [...]} of at most 8, with voxels";
				return false;
			}
			for(unsigned k = 0; k < rc.size(); k++){
				const ss_ type = full_type(jstr(rc.at(k), "type"));
				if(!load_type(type, why) || m_types[type].player){
					why = "root: "+(why.empty() ? type+" is a player's" : why);
					return false;
				}
				const json::Value &ps = rc.at(k).get("params");
				const json::Value &decl = m_types[type].decl.get("params");
				if(ps.is_object())
					for(json::Iterator it(ps); it; ++it){
						const json::Value &d = decl.get(it.key());
						const ss_ bad = !d.is_object() ? "not a parameter of it" :
								jstr(d, "type") == "entity" ? "an entity parameter" :
								check_param(d, *it);
						if(!bad.empty()){
							why = "root: "+type+"'s "+it.key()+" is "+bad;
							return false;
						}
					}
			}
		}
		const json::Value &es = j.get("entities");
		if(!es.is_array() || es.size() < (vox ? 0 : 1) ||
				es.size() > MAX_PREFAB){
			why = (vox ? "0" : "1")+ss_(" to ")+itos(MAX_PREFAB)+" entities";
			return false;
		}
		std::set<int64_t> ids, placed;
		for(unsigned i = 0; i < es.size(); i++){
			const json::Value &e = es.at(i);
			const int64_t id = json::jint(e, "id", 0);
			const int64_t parent = json::jint(e, "parent", 0);
			// [KIT_NESTING] one with a place under the scene or a member
			// with a place
			if(parent && !e.get("pos").is_undefined() && ids.count(parent) &&
					!placed.count(parent)){
				why = "member "+itos(id)+" has a position, its parent none";
				return false;
			}
			if(!e.get("pos").is_undefined())
				placed.insert(id);
			if(id < 1 || id > (int64_t)MAX_PREFAB || ids.count(id)){
				why = "a member's id is 1..."+itos(MAX_PREFAB)+", once";
				return false;
			}
			if(parent && !ids.count(parent)){
				why = "member "+itos(id)+"'s parent is no earlier member";
				return false;
			}
			// [KIT_GENERATORS] a generator's child: its generator an
			// earlier member
			const json::Value &bt = e.get("built");
			if(!bt.is_undefined() && (!bt.is_object() ||
					!ids.count(json::jint(bt, "by", 0)) ||
					json::jint(bt, "member", 0) < 1)){
				why = "member "+itos(id)+"'s built names no earlier member";
				return false;
			}
			if(!jstr(e, "kind").empty() || (!e.get("pos").is_undefined() &&
					!pos_ok(e.get("pos")))){
				why = "member "+itos(id)+" is no plain entity with a position";
				return false;
			}
			// [KIT_PREFAB_ROOT] another prefab's copy among them
			const json::Value &ppf = e.get("prefab");
			if(!ppf.is_undefined() && (!ppf.is_object() ||
					jstr(ppf, "of").empty() || jstr(ppf, "of").size() > 200)){
				why = "member "+itos(id)+"'s prefab names none";
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
				if(m_types[type].player && !m_types[type].placeable){
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
	// not loaded or the scene has no voxels. [KIT_PREFAB_ROOT] k: the box
	// is the prefab's, whose copy stands turned k quarter turns about base:
	// the cells read there, a shape's facing turned back
	json::Value read_voxels(main_context::SceneReference ref,
			const int o[3], const int n[3], const int base[3], bool air,
			ss_ &why, size_t *solid = nullptr, int k = 0)
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
						int tx = o[0] + x - base[0], tz = o[2] + z - base[2];
						turn_cell(tx, tz, k);
						const pv::Vector3DInt32 q(base[0] + tx, o[1] + y,
								base[2] + tz);
						uint32_t word = 0;
						if(!voxel_id(w, q, word)){
							why = "the cell ("+itos(q.getX())+","+itos(q.getY())+
									","+itos(q.getZ())+")'s section is not loaded";
							return;
						}
						const interface::VoxelDefinition *d =
								reg->get(f.id.get(word));
						// (id 0, a cell no generator wrote, has no name)
						const ss_ name = d && !d->name.block_name.empty() ?
								d->name.block_name : ss_("air");
						uint32_t pm = f.param.bound() ? f.param.get(word) : 0;
						if(k && is_shape(name))
							pm = (pm & 4) | ((pm + 4 - k) & 3);
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

	// [KIT_PREFAB_ROOT] All cells of a box air, terrain too; each cell's old
	// word in nc (an undo's) the first time; cells not loaded skipped, counted
	void clear_voxels(main_context::SceneReference ref, const int o[3],
			const int n[3], Change &nc, const ss_ &who, size_t &cleared,
			size_t &missing)
	{
		voxelworld::access(m_server, ref, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			const interface::VoxelFormat &f = reg->get_format();
			interface::VoxelName vn;
			vn.block_name = "air";
			const interface::VoxelDefinition *d = reg->get(vn);
			if(!d)
				return;
			const uint32_t word = (uint32_t)kit::voxel_word(f, d->id, 0, 0) &
					state_mask(f);
			for(int y = 0; y < n[1]; y++)
				for(int z = 0; z < n[2]; z++)
					for(int x = 0; x < n[0]; x++){
						const pv::Vector3DInt32 q(o[0] + x, o[1] + y, o[2] + z);
						uint32_t old = 0;
						if(!hm_section(w, q) || !voxel_id(w, q, old)){
							missing++;
							continue;
						}
						if(old == word)
							continue;
						nc.cells.insert(std::make_pair(std::make_tuple(q.getX(),
								q.getY(), q.getZ()), old));
						set_id(w, q, word);
						mark(w, ref, q, 'k', who);
						cleared++;
					}
		});
	}

	// [KIT_PREFAB_ROOT] The cells a prefab's voxels fill with its base at
	// base, turned k quarter turns: the low corner and the size
	static void placed_box(const json::Value &vx, const int base[3], int k,
			int o[3], int n[3])
	{
		int x0 = (int)vx.get("at").at(0u).as_number();
		int z0 = (int)vx.get("at").at(2u).as_number();
		int x1 = x0 + (int)vx.get("size").at(0u).as_number() - 1;
		int z1 = z0 + (int)vx.get("size").at(2u).as_number() - 1;
		turn_cell(x0, z0, k);
		turn_cell(x1, z1, k);
		o[0] = base[0] + std::min(x0, x1);
		o[1] = base[1] + (int)vx.get("at").at(1u).as_number();
		o[2] = base[2] + std::min(z0, z1);
		n[0] = std::abs(x1 - x0) + 1;
		n[1] = (int)vx.get("size").at(1u).as_number();
		n[2] = std::abs(z1 - z0) + 1;
	}

	// [KIT_PREFAB_ROOT] A root's base cell and quarter turns, the world's:
	// false with why where the turn is no multiple of 90 (voxels only turn
	// so) or it has no place
	bool root_frame(const Entity &e, int base[3], int &k, ss_ &why)
	{
		if(!e.has_pos){
			why = "entity "+itos(e.id)+" has no place, so no voxels' box";
			return false;
		}
		double w[3], wy, wp, wr;
		Turn wq;
		world_of(e, w, &wq);
		wq.angles(wy, wp, wr);
		if(std::fmod(wy, 90.0) != 0 || wp != 0 || wr != 0){
			char deg[96];
			snprintf(deg, sizeof deg, wp != 0 || wr != 0 ?
					"yaw %g pitch %g roll %g" : "%g", wy, wp, wr);
			why = "entity "+itos(e.id)+" is turned "+deg+": voxels go "
					"by multiples of 90";
			return false;
		}
		k = ((int)std::floor(wy / 90 + 0.5) % 4 + 4) % 4;
		for(int i = 0; i < 3; i++)
			base[i] = (int)std::floor(w[i] + 0.5);
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
	// before its children), positions from `base` (the world's; [KIT_NESTING]
	// a member under a positioned member keeps its own, its parent's
	// frame's), links and entity parameters among them made the members',
	// others left out
	// Where a group's first member with a place is (base as it was: none)
	void first_place(const sv_<uint64_t> &ids, double base[3])
	{
		for(uint64_t id : ids)
			if(m_entities[id].has_pos){
				world_of(m_entities[id], base);
				return;
			}
	}

	// [KIT_PREFAB_ROOT] frame: what those directly under it keep their own
	// places in, as a member's frame (a root's save); numbers: their ids in
	// the prefab
	json::Value group_prefab(const sv_<uint64_t> &ids, const double base[3],
			uint64_t frame = 0,
			const std::map<uint64_t, int64_t> *numbers = nullptr)
	{
		std::map<uint64_t, int64_t> local;
		for(size_t i = 0; i < ids.size(); i++)
			local[ids[i]] = (int64_t)i + 1;
		if(numbers)
			local = *numbers;
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
			// [KIT_PREFAB_ROOT] another prefab's copy among them: still one
			if(is_root(src))
				j.set("prefab", src.prefab);
			// [KIT_GENERATORS] a child of a generator among them: still its
			// (a copy's generator's), its overrides kept
			const bool built = !src.built.is_undefined() &&
					member((uint64_t)json::jint(src.built, "by", 0));
			if(built){
				json::Value bt = src.built.deepcopy();
				bt.set("by", member((uint64_t)json::jint(src.built, "by", 0)));
				j.set("built", bt);
			}
			if(src.has_pos){
				const bool framed = (member(src.parent) &&
						m_entities[src.parent].has_pos) ||
						(frame && src.parent == frame);
				double w[3], wy = src.yaw, wp = src.pitch, wr = src.roll;
				if(!framed){
					Turn wq;
					world_of(src, w, &wq);
					wq.angles(wy, wp, wr);
				}
				json::Value pos = json::array();
				for(int k = 0; k < 3; k++)
					pos.append(framed ? src.pos[k] : w[k] - base[k]);
				j.set("pos", pos);
				if(wy != 0)
					j.set("yaw", wy);
				if(wp != 0)
					j.set("pitch", wp);
				if(wr != 0)
					j.set("roll", wr);
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
				if(built && !in.overrides.empty()){
					json::Value ov = json::array();
					for(const ss_ &o : in.overrides)
						ov.append(o);
					cj.set("overrides", ov);
				}
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
	// fixed: each member's id given ([KIT_GENERATORS] a rebuild's)
	void instantiate(const json::Value &pf, const ss_ &name, uint64_t scene,
			const double base[3], uint64_t first, sv_<json::Value> &out,
			int turn = 0, const std::map<int64_t, uint64_t> *fixed = nullptr)
	{
		const json::Value &es = pf.get("entities");
		std::map<int64_t, uint64_t> ids;
		for(unsigned i = 0; i < es.size(); i++)
			ids[json::jint(es.at(i), "id", 0)] = first + i;
		if(fixed)
			ids = *fixed;
		auto map = [&](const json::Value &v) -> int64_t {
			const int64_t l = v.is_number() ? (int64_t)v.as_number() : 0;
			auto it = ids.find(l);
			return it == ids.end() ? 0 : (int64_t)it->second;
		};
		// The new ids of the members with a place
		std::set<int64_t> positioned;
		for(unsigned i = 0; i < es.size(); i++)
			if(pos_ok(es.at(i).get("pos")))
				positioned.insert((int64_t)ids[json::jint(es.at(i), "id", 0)]);
		for(unsigned i = 0; i < es.size(); i++){
			const json::Value &m = es.at(i);
			const int64_t lid = json::jint(m, "id", 0);
			json::Value e = json::object();
			e.set("id", (int64_t)ids[lid]);
			const int64_t parent = map(m.get("parent"));
			e.set("parent", parent ? parent : (int64_t)scene);
			e.set("name", jstr(m, "name"));
			const json::Value &bt = m.get("built");
			if(bt.is_object() && map(bt.get("by"))){
				json::Value b = bt.deepcopy();
				b.set("by", map(bt.get("by")));
				e.set("built", b);
			}
			if(m.get("prefab").is_object())
				e.set("prefab", m.get("prefab").deepcopy());
			// [KIT_NESTING] under a positioned member: its own place in its
			// parent's frame (a turn turns it with its parent)
			if(parent && pos_ok(m.get("pos")) && positioned.count(parent)){
				json::Value pos = json::array();
				for(unsigned k = 0; k < 3; k++)
					pos.append(grid(m.get("pos").at(k).as_number()));
				e.set("pos", pos);
				if(m.get("yaw").is_number())
					e.set("yaw", norm_yaw(m.get("yaw").as_number()));
				row_tilt(e, m);
			} else if(pos_ok(m.get("pos"))){
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
				// (a yaw over the angles: the turn is round the world's y)
				row_tilt(e, m);
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
				if(bt.is_object() && c.get("overrides").is_array())
					cj.set("overrides", c.get("overrides"));
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
	// a copy of the prefab in the editor's scene: [KIT_PREFAB_ROOT] its root
	// (kit/prefab_copy, a place only if the prefab has a positioned member or
	// voxels; turned, it is what turns), its members its built children, the
	// next ids. [KIT_PREFAB_VOXELS] "clipboard": true instead of a
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
		// [KIT_FREE_PREFAB] "free": true: its voxels an object, none stamped
		const bool free = !paste && j.get("free").is_true();
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
		const size_t n = pf->get("entities").size() + 1;
		if(m_entities.size() + n > MAX_ENTITIES){
			why = "the composition has "+itos(MAX_ENTITIES)+" entities";
			return false;
		}
		double base[3];
		for(unsigned k = 0; k < 3; k++)
			base[k] = vox && !free ?
					std::floor(j.get("pos").at(k).as_number() + 0.5) :
					grid(j.get("pos").at(k).as_number());
		if(vox && !free){
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
		// [KIT_NESTING] "parent": its members under that entity
		// ([KIT_PANEL_PARENT] a panel: a paste of UI elements only; a
		// prefab's copy has a root, which is none)
		uint64_t under = 0;
		bool all_ui = paste;
		const json::Value &ms = pf->get("entities");
		for(unsigned i = 0; all_ui && i < ms.size(); i++){
			if(json::jint(ms.at(i), "parent", 0))
				continue;
			const json::Value &cs_ = ms.at(i).get("components");
			bool ui = false;
			for(unsigned c = 0; c < cs_.size(); c++){
				const Type &t = m_types[full_type(jstr(cs_.at(c), "type"))];
				ui = ui || (t.no_position && t.decl.get("ui").is_object());
			}
			all_ui = ui;
		}
		if(!parent_arg(j, p, under, why, 1, all_ui))
			return false;
		if(!paste){
			const uint64_t id = m_next_id++;
			json::Value row = json::object(), comps = json::array(),
					comp = json::object(), pi = json::object();
			row.set("id", (int64_t)id);
			row.set("parent", (int64_t)(under ? under : scene));
			row.set("name", name.substr(name.find('/') + 1)+" "+itos(id));
			pi.set("of", name);
			pi.set("version", json::jint(*pf, "version", 1));
			if(vox)
				pi.set("voxels", voxels_version(*pf));
			row.set("prefab", pi);
			if(needs_place(*pf)){
				json::Value pos = json::array();
				for(int k = 0; k < 3; k++)
					pos.append(base[k]);
				row.set("pos", pos);
				if(turn)
					row.set("yaw", (double)(90 * turn));
				if(under)
					localize(row);
			}
			comp.set("type", PREFAB_ROOT);
			if(free){
				json::Value ps = json::object();
				ps.set("mode", "free");
				comp.set("params", ps);
			}
			comps.append(comp);
			// [KIT_AIRSHIPS] what a free copy's root carries
			if(free)
				root_components(*pf, comps);
			row.set("components", comps);
			Entity e;
			if(!entity_from_json(row, e, why))
				return false;
			change.push_back(std::make_pair(id, row));
			ss_ built;
			rebuild(e, *pf, change, built);
			what = "placed prefab "+name+" as "+itos(id)+"..."+
					itos(m_next_id - 1)+(turn ? ", turned "+itos(turn * 90) :
					ss_());
			return true;
		}
		sv_<json::Value> rows;
		instantiate(*pf, "", scene, base, m_next_id, rows, turn);
		for(json::Value &row : rows){
			if(under && json::jint(row, "parent", 0) == (int64_t)scene){
				row.set("parent", (int64_t)under);
				localize(row);
			}
			// Named as a duplicate's are
			const json::Value &cs_ = row.get("components");
			if(cs_.size())
				row.set("name", jstr(cs_.at(0), "type")+" "+
						itos(json::jint(row, "id", 0)));
			change.push_back(std::make_pair((uint64_t)json::jint(row, "id", 0),
					row));
		}
		what = ss_("pasted the copy")+(rows.empty() ? ss_() : " as "+
				itos(m_next_id)+"..."+itos(m_next_id + rows.size() - 1))+
				(turn ? ", turned "+itos(turn * 90) : ss_());
		m_next_id += rows.size();
		return true;
	}

	// [KIT_PREFAB_ROOT] Whether a copy of it has a place: a positioned member,
	// or voxels
	static bool needs_place(const json::Value &pf)
	{
		if(pf.get("voxels").is_object())
			return true;
		const json::Value &es = pf.get("entities");
		for(unsigned i = 0; i < es.size(); i++)
			if(!es.at(i).get("pos").is_undefined())
				return true;
		return false;
	}

	// [KIT_PREFAB_ROOT] The version a prefab's voxels last changed in
	static int64_t voxels_version(const json::Value &pf)
	{
		return json::jint(pf, "voxels_version", json::jint(pf, "version", 1));
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
			// [KIT_NESTING] with what is under it
			const sv_<uint64_t> sub = group_of(e->id);
			if(sub.empty()){
				why = "entity "+itos(e->id)+" has more than "+
						itos(MAX_PREFAB)+" entities under it";
				return false;
			}
			for(uint64_t x : sub)
				if(std::find(group.begin(), group.end(), x) == group.end())
					group.push_back(x);
		}
		if(group.size() > MAX_PREFAB){
			why = "more than "+itos(MAX_PREFAB)+" entities with those under "
					"them";
			return false;
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
		} else {
			first_place(group, base);
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
		// [KIT_NESTING] one under another of them goes with it
		const std::set<uint64_t> all(group.begin(), group.end());
		group.erase(std::remove_if(group.begin(), group.end(),
				[&](uint64_t id){
			return under_one_of(id, all);
		}), group.end());
		return true;
	}

	// [KIT_NESTING] Whether an entity is under one of `ids` (at any depth)
	bool under_one_of(uint64_t id, const std::set<uint64_t> &ids)
	{
		auto it = m_entities.find(id);
		for(int d = 0; it != m_entities.end() && d <= MAX_NEST + 2; d++){
			if(ids.count(it->second.parent))
				return true;
			if(it->second.parent == 1)
				break;
			it = m_entities.find(it->second.parent);
		}
		return false;
	}

	// [KIT] stage 4e2: {"op": "move", "ids": [n...], "by": [dx, dy, dz],
	// "turn": degrees, "axis": [x, y, z]}: entities moved together, one edit
	// (an editor's drag of its selection), turned about their middle (the mean
	// of their positions) round a line of the world (y unless axis says) and
	// each by as much. The turn is by, not to: quick presses all count
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
		double axis[3] = {0, 1, 0};
		const json::Value &ax = j.get("axis");
		if(!ax.is_undefined()){
			double l = 0;
			if(pos_ok(ax))
				for(unsigned k = 0; k < 3; k++){
					axis[k] = ax.at(k).as_number();
					l += axis[k] * axis[k];
				}
			if(l < 1e-9){
				why = "axis: three numbers, not all 0";
				return false;
			}
			for(int k = 0; k < 3; k++)
				axis[k] /= std::sqrt(l);
		}
		double d[3] = {0, 0, 0}, mid[3] = {0, 0, 0};
		for(unsigned k = 0; by.is_array() && k < 3; k++)
			d[k] = by.at(k).as_number();
		// [KIT_NESTING] in the world (what is under them goes with them)
		struct At { double w[3]; Turn q; };
		sm_<uint64_t, At> at;
		for(uint64_t id : group){
			At &w = at[id];
			world_of(m_entities[id], w.w, &w.q);
			for(int k = 0; k < 3; k++)
				mid[k] += w.w[k] / group.size();
		}
		const double a = turn.is_number() ? turn.as_number() : 0;
		const Turn tq = Turn::around(axis, a);
		const bool only_turn = group.size() == 1 && d[0] == 0 && d[1] == 0 &&
				d[2] == 0;
		for(uint64_t id : group){
			const Entity &e = m_entities[id];
			const At &w = at[id];
			double np[3] = {w.w[0] - mid[0], w.w[1] - mid[1], w.w[2] - mid[2]};
			tq.apply(np);
			for(int k = 0; k < 3; k++)
				np[k] += mid[k] + d[k];
			for(int k = 0; k < 3; k++)
				if(std::fabs(np[k]) > MAX_COORD){
					why = "entity "+itos(id)+" would go past "+
							itos((int)MAX_COORD);
					return false;
				}
			json::Value after = entity_json(e), pos = json::array();
			for(int k = 0; k < 3; k++)
				pos.append(grid(np[k]));
			after.set("pos", pos);
			row_turn(after, tq * w.q);
			localize(after);
			if(a == 0)
				row_turn(after, e.yaw, e.pitch, e.roll);
			// One turning where it is stays where it is in its frame (off the
			// world's grid under a turned parent)
			if(only_turn){
				json::Value own = json::array();
				for(int k = 0; k < 3; k++)
					own.append(e.pos[k]);
				after.set("pos", own);
			}
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
		sv_<uint64_t> tops;
		if(!group_arg(j, tops, why))
			return false;
		// [KIT_NESTING] each with what is under it, the copy beside it
		// (under its parent)
		std::sort(tops.begin(), tops.end());
		sv_<uint64_t> group;
		for(uint64_t id : tops)
			for(uint64_t x : group_of(id, MAX_ENTITIES))
				group.push_back(x);
		if(group.size() > MAX_PREFAB){
			why = "more than "+itos(MAX_PREFAB)+" entities with those under "
					"them";
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
		const Entity &first = m_entities[group[0]];
		double base[3];
		world_of(first, base);
		const json::Value pf = group_prefab(group, base);
		for(int k = 0; k < 3; k++)
			base[k] += by.at(k).as_number();
		sv_<json::Value> rows;
		instantiate(pf, "", scene, base, m_next_id, rows);
		for(size_t i = 0; i < rows.size(); i++){
			json::Value &row = rows[i];
			const uint64_t src_parent = m_entities[group[i]].parent;
			if(std::find(tops.begin(), tops.end(), group[i]) != tops.end() &&
					src_parent != scene){
				row.set("parent", (int64_t)src_parent);
				localize(row);
			}
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

	// [KIT_PREFAB_ROOT] The name a builder's prefabs are under: "" if none may
	// be, "kit" being Kit's
	static ss_ prefab_author(const Peer &p)
	{
		ss_ author = p.name.substr(0, 64);
		for(char &c : author)
			if(!isalnum((unsigned char)c))
				c = '_';
		return author == "kit" ? ss_() : author;
	}

	// [KIT_PREFAB_ROOT] An edit's root of a placed prefab
	Entity* root_arg(const json::Value &j, const char *key, ss_ &why)
	{
		Entity *e = entity_arg(j, key, why);
		if(e && !is_root(*e)){
			why = "entity "+itos(e->id)+" is no placed prefab's root";
			return nullptr;
		}
		return e;
	}

	// {"op": "save_prefab", "ids": [n...], "name": n}: those entities a
	// prefab "<the builder's name>/<n>" (a new version of it if it is
	// there), in the save, placeable from then on; those entities stay as
	// they are. [KIT_PREFAB_ROOT] {"op": "save_prefab", "root": id}: the
	// new version of that copy's prefab, of what is under it (by its own
	// member numbers, new ones next, in its frame) and, if the prefab has
	// voxels or "box" names one (the world's), that box as it stands, turned
	// back to the prefab's frame ("air" as given, else as it was); it is then
	// what the prefab says, overrides and moves no more. Whichever: every copy
	// follows (rebuilds()). A prefab that was deleted comes back so.
	bool save_prefab(const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what,
			ss_ &why)
	{
		const ss_ author = prefab_author(p);
		if(author.empty()){
			why = "a builder's prefabs are under their name, and it is \""+
					p.name.substr(0, 64)+"\"";
			return false;
		}
		Entity *root = nullptr;
		ss_ short_name = jstr(j, "name");
		if(!j.get("root").is_undefined()){
			root = root_arg(j, "root", why);
			if(!root)
				return false;
			// [KIT_PREFAB_BENCH] not of a box its voxels are not in yet
			if(active_session() && active_session()->stamp.is_object()){
				why = "its voxels are still being laid out here: a moment";
				return false;
			}
			const ss_ of = jstr(root->prefab, "of");
			if(of.compare(0, author.size() + 1, author+"/") != 0){
				why = of+" is "+(of.compare(0, 4, "kit/") == 0 ? ss_("Kit's") :
						"not yours")+": Make prefab makes one of your own of it";
				return false;
			}
			short_name = of.substr(author.size() + 1);
		}
		if(!name_ok(short_name)){
			why = "name: letters, digits and _";
			return false;
		}
		const ss_ name = author+"/"+short_name;
		m_bad_prefabs.erase(name);
		const json::Value *old = prefab(name);
		if(old && !jstr(*old, "package").empty()){
			why = name+" is the package "+jstr(*old, "package")+"'s";
			return false;
		}
		sv_<uint64_t> group;
		json::Value pf;
		if(root){
			group = group_of(root->id);
			if(group.empty()){
				why = "more than "+itos(MAX_PREFAB)+" entities under it";
				return false;
			}
			group.erase(group.begin());
			std::sort(group.begin(), group.end(), [&](uint64_t a, uint64_t b){
				const int da = depth(a), db = depth(b);
				return da != db ? da < db : a < b;
			});
			// Its members' numbers kept (what other copies know them by); a
			// new one's past any there was, or else the lowest free
			std::map<uint64_t, int64_t> numbers;
			std::set<int64_t> used;
			int64_t next = 1;
			for(uint64_t id : group){
				const json::Value &bt = m_entities[id].built;
				if((uint64_t)json::jint(bt, "by", 0) != root->id)
					continue;
				numbers[id] = json::jint(bt, "member", 0);
				used.insert(numbers[id]);
				next = std::max(next, numbers[id] + 1);
			}
			const json::Value empty = json::array();
			const json::Value &was = old ? old->get("entities") : empty;
			for(unsigned i = 0; i < was.size(); i++)
				next = std::max(next, json::jint(was.at(i), "id", 0) + 1);
			for(uint64_t id : group){
				if(numbers.count(id))
					continue;
				if(next > (int64_t)MAX_PREFAB)
					next = 1;
				while(used.count(next))
					next++;
				numbers[id] = next;
				used.insert(next++);
			}
			const double zero[3] = {0, 0, 0};
			pf = group_prefab(group, zero, root->id, &numbers);
			// [KIT_FREE_PREFAB] a free one has no voxels in the world to read:
			// the prefab's stay as they are
			const bool free = is_free(*root);
			const bool box = !free && !j.get("box").is_undefined();
			const json::Value none;
			const json::Value &ov = old ? old->get("voxels") : none;
			if(free && ov.is_object()){
				pf.set("voxels", ov);
			} else if(!free && (box || ov.is_object())){
				int base[3], k = 0, o[3], n[3];
				if(!root_frame(*root, base, k, why))
					return false;
				if(box){
					int wo[3], wn[3];
					if(!box_arg(j, wo, wn, why))
						return false;
					// Its corners in the prefab's frame
					int x0 = wo[0] - base[0], z0 = wo[2] - base[2];
					int x1 = x0 + wn[0] - 1, z1 = z0 + wn[2] - 1;
					turn_cell(x0, z0, 4 - k);
					turn_cell(x1, z1, 4 - k);
					o[0] = base[0] + std::min(x0, x1);
					o[1] = wo[1];
					o[2] = base[2] + std::min(z0, z1);
					n[0] = std::abs(x1 - x0) + 1;
					n[1] = wn[1];
					n[2] = std::abs(z1 - z0) + 1;
				} else {
					placed_box(ov, base, 0, o, n);
				}
				auto si = m_host.scenes.find(p.scene);
				if(si == m_host.scenes.end()){
					why = "not in a scene of the app's";
					return false;
				}
				const bool air = j.get("air").is_undefined() ?
						ov.get("air").is_true() : j.get("air").is_true();
				const json::Value v = read_voxels(si->second, o, n, base, air, why,
						nullptr, k);
				if(v.is_null())
					return false;
				pf.set("voxels", v);
			}
			if(pf.stringify().size() > MAX_TYPE_SOURCE){
				why = "it is past "+itos(MAX_TYPE_SOURCE)+" bytes as a prefab";
				return false;
			}
		// [KIT_PREFAB_VOXELS] "box" (and "air"): a box of voxels in it too;
		// "clipboard": true: the builder's copy named
		} else if(j.get("clipboard").is_true()){
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
		const int64_t version = old ? json::jint(*old, "version", 1) + 1 :
				root ? json::jint(root->prefab, "version", 0) + 1 : 1;
		pf.set("author", author);
		pf.set("name", short_name);
		pf.set("version", version);
		if(pf.get("voxels").is_object())
			pf.set("voxels_version", old && old->get("voxels").stringify() ==
					pf.get("voxels").stringify() ? voxels_version(*old) : version);
		if(old && old->get("published").is_true())
			pf.set("published", true);
		if(!check_prefab(pf, why))
			return false;
		// The copies that will follow, at their most
		size_t follow = 0;
		for(auto &x : m_entities)
			if(authored(x.second) && is_root(x.second) &&
					jstr(x.second.prefab, "of") == name)
				follow++;
		if(m_entities.size() + follow * pf.get("entities").size() >
				MAX_ENTITIES){
			why = "its "+itos(follow)+" copies would take the composition past "+
					itos(MAX_ENTITIES)+" entities";
			return false;
		}
		m_store->set("prefab:"+name, pf.stringify());
		m_prefabs[name] = pf;
		m_prefab_palette.insert(name);
		// [KIT_BROADCAST_SESSION] builders in every session see it in their
		// palette
		each_session([&]{
			for(auto &o : m_peers)
				if(o.second.editing)
					send_state(o.first);
		});
		// [KIT_TOOLS_2] an item type's look may be it
		for(auto &it : m_item_types)
			if(jstr(it.second, "look") == name){
				send_item_types(-1);
				break;
			}
		// [KIT_PREFAB_ROOT] The copy saved: what it is is what the prefab says
		if(root){
			std::set<uint64_t> in_group(group.begin(), group.end());
			const json::Value &ms = pf.get("entities");
			for(size_t i = 0; i < group.size(); i++){
				Entity copy = m_entities[group[i]];
				if(in_group.count((uint64_t)json::jint(copy.built, "by", 0)))
					continue;
				json::Value bt = json::object();
				bt.set("by", (int64_t)root->id);
				bt.set("member", json::jint(ms.at((unsigned)i), "id", 0));
				copy.built = bt;
				for(Instance &in : copy.comps)
					in.overrides.clear();
				change.push_back(std::make_pair(copy.id, entity_json(copy)));
			}
			Entity r = *root;
			r.prefab = root->prefab.deepcopy();
			r.prefab.set("of", name);
			r.prefab.set("version", version);
			if(pf.get("voxels").is_object())
				r.prefab.set("voxels", voxels_version(pf));
			change.push_back(std::make_pair(r.id, entity_json(r)));
		}
		m_follow = name;
		m_follow_source = root ? root->id : 0;
		if(active_session() && active_session()->bench)
			m_bench_saved = name;
		const json::Value &vx = pf.get("voxels");
		what = "saved prefab "+name+" version "+itos(version)+" of "+
				itos(pf.get("entities").size())+" entities"+(vx.is_object() ?
				" and a box of "+vx.get("size").stringify()+" voxels"+
				(vx.get("air").is_true() ? " (air replaces)" : "") : ss_());
		return true;
	}

	// [KIT_PREFAB_ROOT] {"op": "stamp", "id": root, "clear": bool, "from":
	// [x, y, z, yaw] (the world's), "merge": bool}: the prefab's voxels written
	// at the root's place and turn. clear: all cells of a box emptied first,
	// terrain too: the box at `from` (a move's, where it was), else the one it
	// is stamped in. merge: one undo with the root's move just before. Its
	// voxels are this version's on the root from then on
	bool stamp(const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what, ss_ &why)
	{
		Entity *e = root_arg(j, "id", why);
		if(!e)
			return false;
		const ss_ of = jstr(e->prefab, "of");
		const json::Value *pf = prefab(of);
		if(!pf){
			why = "the prefab "+of+" is gone: nothing to stamp";
			return false;
		}
		const json::Value &vx = pf->get("voxels");
		if(!vx.is_object()){
			why = "the prefab "+of+" has no voxels";
			return false;
		}
		// [KIT_FREE_PREFAB] "only_clear": what a switch to free leaves, its
		// box emptied and nothing stamped; else a free one has no stamp
		const bool only_clear = j.get("only_clear").is_true();
		if(is_free(*e) && !only_clear){
			why = "entity "+itos(e->id)+" is a free object: nothing to stamp";
			return false;
		}
		ss_ scene;
		scene_of(*e, &scene);
		if(scene != p.scene || !m_host.scenes.count(p.scene)){
			why = "entity "+itos(e->id)+" is in another scene";
			return false;
		}
		int base[3], k = 0;
		if(!root_frame(*e, base, k, why))
			return false;
		m_paste.vox = vx;
		for(int i = 0; i < 3; i++)
			m_paste.base[i] = base[i];
		m_paste.turn = k;
		m_paste.set = true;
		m_paste.merge = j.get("merge").is_true();
		m_paste.clear = j.get("clear").is_true() || only_clear;
		m_paste.only_clear = only_clear;
		if(m_paste.clear){
			int cb[3] = {base[0], base[1], base[2]}, ck = k;
			const json::Value &from = j.get("from");
			if(!from.is_undefined()){
				if(!from.is_array() || from.size() != 4){
					why = "from: [x, y, z, yaw]";
					return false;
				}
				for(unsigned i = 0; i < 4; i++)
					if(!from.at(i).is_number() ||
							!std::isfinite(from.at(i).as_number()) ||
							std::fabs(from.at(i).as_number()) > MAX_COORD){
						why = "from: [x, y, z, yaw]";
						return false;
					}
				const double fy = from.at(3u).as_number();
				if(std::fmod(fy, 90.0) != 0){
					why = "from: a yaw of a multiple of 90";
					return false;
				}
				for(unsigned i = 0; i < 3; i++)
					cb[i] = (int)std::floor(from.at(i).as_number() + 0.5);
				ck = (((int)fy / 90) % 4 + 4) % 4;
			}
			placed_box(vx, cb, ck, m_paste.clear_at, m_paste.clear_size);
		}
		Entity copy = *e;
		copy.prefab = e->prefab.deepcopy();
		if(!only_clear)
			copy.prefab.set("voxels", voxels_version(*pf));
		change.push_back(std::make_pair(e->id, entity_json(copy)));
		what = (only_clear ? "cleared the stamp of " : "stamped ")+of+" on "+
				itos(e->id);
		return true;
	}

	// [KIT_PREFAB_ROOT] {"op": "prefab_detach", "id": root}: the root gone,
	// what is under it plain entities under its parent, where they are; the
	// voxels stay. (Links to the root: it has no inputs.)
	bool detach_prefab(const json::Value &j,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what, ss_ &why)
	{
		Entity *e = root_arg(j, "id", why);
		if(!e)
			return false;
		const uint64_t id = e->id, up = e->parent;
		const ss_ of = jstr(e->prefab, "of");
		size_t n = 0;
		for(auto &x : m_entities){
			if(!authored(x.second) || x.first == id)
				continue;
			const bool under = x.second.parent == id;
			const bool by = (uint64_t)json::jint(x.second.built, "by", 0) == id;
			if(!under && !by)
				continue;
			Entity copy = x.second;
			if(by){
				copy.built = json::Value();
				for(Instance &in : copy.comps)
					in.overrides.clear();
				n++;
			}
			json::Value row = entity_json(copy);
			if(under){
				row = world_row(copy);
				row.set("parent", (int64_t)up);
				localize(row);
			}
			change.push_back(std::make_pair(x.first, row));
		}
		change.push_back(std::make_pair(id, json::null()));
		what = "detached "+itos(n)+" entities from the copy "+itos(id)+" of "+of;
		return true;
	}

	// [KIT_PREFAB_ROOT] {"op": "prefab_reset", "id", "comp", "param"}: a copy's
	// member's parameter the prefab's again, no longer its own
	bool reset_param(const json::Value &j,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what, ss_ &why)
	{
		Entity *e = nullptr;
		Instance *in = instance_arg(j, e, why);
		if(!in)
			return false;
		const uint64_t by = (uint64_t)json::jint(e->built, "by", 0);
		// [KIT_SYMMETRY] a copy's: commit() gives it its source's again
		if(copy_by(*e)){
			const ss_ param = jstr(j, "param");
			if(!in->overrides.count(param)){
				why = "its "+param.substr(0, 64)+" is not its own";
				return false;
			}
			const json::Value row = entity_json(*e).deepcopy();
			json::Value cs_ = row.get("components");
			json::Value cj = cs_.at((unsigned)(in - &e->comps[0]));
			json::Value ov = json::array();
			for(const ss_ &o : in->overrides)
				if(o != param)
					ov.append(o);
			cj.set("overrides", ov);
			cs_.set_at((unsigned)(in - &e->comps[0]), cj);
			json::Value out = row;
			out.set("components", cs_);
			change.push_back(std::make_pair(e->id, out));
			what = "entity "+itos(e->id)+"'s "+param+" its source's again";
			return true;
		}
		auto ri = m_entities.find(by);
		if(ri == m_entities.end() || !is_root(ri->second)){
			why = "entity "+itos(e->id)+" is no prefab's member";
			return false;
		}
		const ss_ param = jstr(j, "param"), of = jstr(ri->second.prefab, "of");
		if(!in->overrides.count(param)){
			why = "its "+param.substr(0, 64)+" is not its own";
			return false;
		}
		const json::Value *pf = prefab(of);
		if(!pf){
			why = "the prefab "+of+" is gone: nothing to reset to";
			return false;
		}
		const size_t ci = in - &e->comps[0];
		const json::Value &ms = pf->get("entities");
		const int64_t lid = json::jint(e->built, "member", 0);
		json::Value decl = m_types[in->type].decl.get("params").get(param);
		json::Value v = decl.get("default");
		bool member = false;
		for(unsigned i = 0; i < ms.size(); i++){
			if(json::jint(ms.at(i), "id", 0) != lid)
				continue;
			const json::Value &cs_ = ms.at(i).get("components");
			if(ci < cs_.size() && full_type(jstr(cs_.at((unsigned)ci), "type")) ==
					in->type){
				member = true;
				const json::Value &pv = cs_.at((unsigned)ci).get("params").
						get(param);
				if(!pv.is_undefined())
					v = pv;
			}
		}
		if(!member){
			why = "the prefab "+of+" has no such member now";
			return false;
		}
		// An entity's: the member's number made this copy's
		if(jstr(decl, "type") == "entity"){
			int64_t to = 0;
			for(auto &x : m_entities)
				if((uint64_t)json::jint(x.second.built, "by", 0) == by &&
						v.is_number() && json::jint(x.second.built, "member", 0) ==
						(int64_t)v.as_number())
					to = (int64_t)x.first;
			v = json::Value(to);
		}
		const ss_ bad = check_param(decl, v);
		if(!bad.empty()){
			why = "the prefab's "+param+" is "+bad;
			return false;
		}
		Entity copy = *e;
		copy.comps[ci].params = in->params.deepcopy();
		copy.comps[ci].params.set(param, v);
		copy.comps[ci].overrides.erase(param);
		change.push_back(std::make_pair(e->id, entity_json(copy)));
		what = "reset "+itos(e->id)+"'s "+in->type+" "+param+" to the prefab's "+
				v.stringify();
		return true;
	}

	// [KIT_PREFAB_ROOT] A row of an entity or a prefab's member: what it names
	// of prefab `from` by `to`. Whether it named it
	bool row_prefab_renamed(json::Value &row, const ss_ &from, const ss_ &to)
	{
		bool any = false;
		if(jstr(row.get("prefab"), "of") == from){
			json::Value pi = row.get("prefab").deepcopy();
			pi.set("of", to);
			row.set("prefab", pi);
			any = true;
		}
		const json::Value &cs0 = row.get("components");
		if(!cs0.is_array())
			return any;
		json::Value cs_ = cs0.deepcopy();
		bool in_params = false;
		for(unsigned c = 0; c < cs_.size(); c++){
			json::Value cj = cs_.at(c), ps = cj.get("params");
			auto t = m_types.find(full_type(jstr(cj, "type")));
			if(!ps.is_object() || t == m_types.end())
				continue;
			const json::Value &decl = t->second.decl.get("params");
			for(json::Iterator it(decl); decl.is_object() && it; ++it)
				if(jstr(*it, "type") == "prefab" && jstr(ps, it.key().c_str()) == from){
					ps.set(it.key(), to);
					in_params = true;
				}
			cj.set("params", ps);
			cs_.set_at(c, cj);
		}
		if(in_params)
			row.set("components", cs_);
		return any || in_params;
	}

	// [KIT_PREFAB_ROOT] What in a prefab or an entity's parameters names a
	// prefab, for a refusal; "" none
	ss_ prefab_named_by(const ss_ &name)
	{
		for(const ss_ &k : m_store->list("prefab:")){
			if(k.substr(7) == name)
				continue;
			const json::Value *pf = prefab(k.substr(7));
			const json::Value empty = json::array();
			const json::Value &es = pf ? pf->get("entities") : empty;
			for(unsigned i = 0; i < es.size(); i++){
				json::Value row = es.at(i).deepcopy();
				row.del_key("prefab");
				if(row_prefab_renamed(row, name, name))
					return "the prefab "+k.substr(7);
			}
		}
		ss_ by;
		each_session([&]{
			for(auto &x : m_entities){
				if(!by.empty() || !authored(x.second))
					continue;
				json::Value row = entity_json(x.second);
				row.del_key("prefab");
				if(row_prefab_renamed(row, name, name))
					by = "entity "+itos(x.first);
			}
		});
		return by;
	}

	// [KIT_PREFAB_ROOT] A prefab that this builder may rename or delete, with
	// why not: their own, of a row, no package's
	const json::Value* own_prefab(const Peer &p, const ss_ &name, ss_ &why)
	{
		const json::Value *pf = prefab(name);
		const ss_ author = prefab_author(p);
		ss_ row;
		if(!pf)
			why = "no prefab \""+name.substr(0, 130)+"\"";
		else if(!jstr(*pf, "package").empty())
			why = name+" is the package "+jstr(*pf, "package")+"'s";
		else if(name.compare(0, 4, "kit/") == 0)
			why = name+" is Kit's";
		else if(author.empty() || name.compare(0, author.size() + 1,
				author+"/") != 0 || !m_store->get("prefab:"+name, row))
			why = name+" is not yours";
		return why.empty() ? pf : nullptr;
	}

	// {"op": "prefab_rename", "name": "<author>/<n>", "to": m}: the prefab
	// under the other name, and what names it: its copies in every session,
	// their undo, other prefabs, parameters and item types' looks. Refused if
	// it went into a package (others' copies know it by its name)
	void rename_prefab(Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const ss_ name = jstr(j, "name"), to = jstr(j, "to");
		ss_ why;
		const json::Value *pf = own_prefab(p, name, why);
		if(!pf)
			return refuse(why);
		if(pf->get("published").is_true())
			return refuse(name+" is published in a package: its name stays");
		if(!name_ok(to))
			return refuse("to: letters, digits and _");
		const ss_ new_name = prefab_author(p)+"/"+to;
		m_bad_prefabs.erase(new_name);
		if(prefab(new_name))
			return refuse("there is a prefab "+new_name+" already");
		json::Value row = pf->deepcopy();
		row.set("name", to);
		m_store->remove("prefab:"+name);
		m_store->set("prefab:"+new_name, row.stringify());
		m_prefabs.erase(name);
		m_prefabs[new_name] = row;
		m_prefab_palette.erase(name);
		m_prefab_palette.insert(new_name);
		for(const ss_ &k : m_store->list("prefab:")){
			const json::Value *other = prefab(k.substr(7));
			if(!other)
				continue;
			json::Value o = other->deepcopy(), es = o.get("entities");
			bool any = false;
			for(unsigned i = 0; es.is_array() && i < es.size(); i++){
				json::Value m = es.at(i);
				if(row_prefab_renamed(m, name, new_name)){
					es.set_at(i, m);
					any = true;
				}
			}
			if(any){
				o.set("entities", es);
				m_store->set(k, o.stringify());
				m_prefabs[k.substr(7)] = o;
			}
		}
		size_t copies = 0;
		const ss_ short_old = name.substr(name.find('/') + 1);
		each_session([&]{
			sv_<std::pair<uint64_t, json::Value>> change;
			for(auto &x : m_entities){
				if(!authored(x.second))
					continue;
				json::Value r = entity_json(x.second);
				if(!row_prefab_renamed(r, name, new_name))
					continue;
				if(is_root(x.second)){
					copies++;
					// One still named as it was placed
					if(x.second.name == short_old+" "+itos(x.first))
						r.set("name", to+" "+itos(x.first));
				}
				change.push_back(std::make_pair(x.first, r));
			}
			if(!change.empty())
				commit(change, nullptr);
			for(auto &u : m_undo)
				for(Change &c : u.second)
					for(auto &b : c.before)
						if(b.second.is_object())
							row_prefab_renamed(b.second, name, new_name);
		});
		bool looks = false;
		for(auto &it : m_item_types)
			if(jstr(it.second, "look") == name){
				it.second.set("look", new_name);
				m_store->set("item:"+it.first, it.second.stringify());
				looks = true;
			}
		if(looks)
			send_item_types(-1);
		log_i(MODULE, "%s renamed the prefab %s to %s (%zu copies)", cs(p.name),
				cs(name), cs(new_name), copies);
		each_session([&]{
			sync_free_objects();
			for(auto &o : m_peers)
				if(o.second.editing)
					send_state(o.first);
		});
	}

	// {"op": "prefab_delete", "name": "<author>/<n>"}: the prefab gone. Copies
	// placed stay as they are, their "of" naming nothing: they follow nothing,
	// and a Save to prefab on one makes it again. What must find it (an item's
	// look, a parameter, another prefab's parameter) refuses it
	void delete_prefab(Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const ss_ name = jstr(j, "name");
		ss_ why;
		if(!own_prefab(p, name, why))
			return refuse(why);
		for(auto &it : m_item_types)
			if(jstr(it.second, "look") == name)
				return refuse(name+" is the look of the item "+it.first);
		const ss_ by = prefab_named_by(name);
		if(!by.empty())
			return refuse(by+" names "+name+" in a parameter");
		m_store->remove("prefab:"+name);
		m_prefabs.erase(name);
		m_prefab_palette.erase(name);
		m_bad_prefabs.erase(name);
		log_i(MODULE, "%s deleted the prefab %s", cs(p.name), cs(name));
		each_session([&]{
			sync_free_objects();
			for(auto &o : m_peers)
				if(o.second.editing)
					send_state(o.first);
		});
	}
	// ---- [KIT_GENERATORS] Generators: a type with on_build makes its own
	// children from its parameters, in the editor (api.h)

	// A generator's build, run as the entity is after an edit (it may be
	// a new one, not in the tree yet): its children as a prefab's members
	// (their positions its frame's), checked as a prefab's, MAX_BUILT at
	// most, no generators, root, World or environment types among them;
	// metered as a handler's run
	bool build_of(const Entity &e, size_t comp, json::Value &pf, ss_ &why,
			int64_t *spent_out = nullptr)
	{
		Run r;
		r.entity = e.id;
		r.comp = comp;
		r.handler = "on_build";
		ss_ answer, error;
		bool runaway = false;
		int64_t spent = 0;
		m_building = true;
		const bool called = box_call(request_of(e, e.comps[comp], r), answer,
				error, &runaway, &spent);
		m_building = false;
		if(spent_out)
			*spent_out = spent;
		auto it = m_entities.find(e.id);
		if(it != m_entities.end() && comp < it->second.comps.size())
			it->second.comps[comp].spent += spent;
		if(!called){
			why = runaway ? "on_build ran past its budget" : "on_build: "+error;
			add_log(e.id, why);
			return false;
		}
		const json::Value fx = json::load_string(answer.c_str());
		const json::Value &lines = fx.get("log");
		for(unsigned i = 0; i < lines.size(); i++)
			if(lines.at(i).is_string())
				add_log(e.id, lines.at(i).as_string());
		const json::Value &b = fx.get("build");
		const json::Value &es = b.get("entities");
		pf = json::object();
		pf.set("format", "kit_prefab");
		pf.set("entities", es.is_array() ? es : json::array());
		if(!b.get("voxels").is_undefined())
			pf.set("voxels", b.get("voxels"));
		if(pf.get("entities").size() > MAX_BUILT){
			why = "on_build makes "+itos(pf.get("entities").size())+
					" children, past "+itos(MAX_BUILT);
			return false;
		}
		if(pf.get("entities").size() == 0 && pf.get("voxels").is_undefined())
			return true;
		// A link to 0 is to the generator itself: aside ("to_self":
		// [[member, component, output, input]...]), its input the
		// generator's
		json::Value ms0 = pf.get("entities"), self_links = json::array();
		for(unsigned i = 0; i < ms0.size(); i++){
			json::Value m = ms0.at(i), cs_ = m.get("components");
			for(unsigned k = 0; cs_.is_array() && k < cs_.size(); k++){
				json::Value cj = cs_.at(k);
				const json::Value &ls = cj.get("links");
				json::Value keep = json::array();
				for(unsigned l = 0; l < ls.size(); l++){
					if(json::jint(ls.at(l), "to", -1) != 0){
						keep.append(ls.at(l));
						continue;
					}
					const ss_ input = jstr(ls.at(l), "input");
					bool ok = false;
					for(const Instance &in : e.comps)
						ok = ok || m_types[in.type].inputs.count(input);
					if(!ok){
						why = "on_build: child "+itos(i + 1)+" links to the "
								"generator's "+input.substr(0, 64)+", which it has "
								"not";
						return false;
					}
					json::Value sl = json::array();
					sl.append(json::jint(m, "id", 0));
					sl.append((int64_t)k);
					sl.append(jstr(ls.at(l), "output"));
					sl.append(input);
					self_links.append(sl);
				}
				cj.set("links", keep);
				cs_.set_at(k, cj);
			}
			m.set("components", cs_);
			ms0.set_at(i, m);
		}
		pf.set("entities", ms0);
		if(!check_prefab(pf, why)){
			why = "on_build: "+why;
			return false;
		}
		for(unsigned i = 0; i < self_links.size(); i++){
			const json::Value &sl = self_links.at(i);
			const json::Value &cs_ = ms0.at((unsigned)sl.at(0u).as_number() -
					1).get("components");
			const ss_ type = full_type(jstr(cs_.at((unsigned)sl.at(1u).
					as_number()), "type"));
			if(!m_types[type].outputs.count(sl.at(2u).as_string())){
				why = "on_build: a link from an output "+type+" has not";
				return false;
			}
		}
		pf.set("to_self", self_links);
		const json::Value &ms = pf.get("entities");
		// Its children's levels under it, the generator's own under the
		// root's with them MAX_NEST at most
		std::map<int64_t, int> level;
		const int at = depth(e.parent) + 1;
		for(unsigned i = 0; i < ms.size(); i++){
			const int64_t pm = json::jint(ms.at(i), "parent", 0);
			const int l = (pm ? level[pm] : 0) + 1;
			level[json::jint(ms.at(i), "id", 0)] = l;
			if(at + l > MAX_NEST){
				why = "on_build: its children nest past "+itos(MAX_NEST)+
						" levels";
				return false;
			}
		}
		for(unsigned i = 0; i < ms.size(); i++){
			const json::Value &cs_ = ms.at(i).get("components");
			for(unsigned k = 0; k < cs_.size(); k++){
				const Type &t = m_types[full_type(jstr(cs_.at(k), "type"))];
				if(t.handlers.count("on_build") || t.root || t.world ||
						t.environment){
					why = "on_build: child "+itos(i + 1)+" is a "+
							jstr(cs_.at(k), "type")+(t.handlers.count("on_build") ?
							": a generator builds no generators" :
							", which goes on the root or a scene");
					return false;
				}
			}
		}
		return true;
	}

	// The generator g (its row after the edit, n) built again into the
	// change: its old children replaced by pf's members, one with the
	// member's number, type and parent kept as it was (its id, links from
	// others to it and its own to others, what is under it by hand, its
	// overrides, and its place if a builder moved it), the rest gone (what
	// a builder put under one of those put under g, where it was) or new.
	// [KIT_PREFAB_ROOT] g a copy's root, pf its prefab: a member a generator
	// (or another copy's root) built is its builder's own affair while that
	// builder stays: no row of it here, it goes with that builder, and comes
	// new with a new one
	void rebuild(const Entity &n, const json::Value &pf,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what)
	{
		const uint64_t g = n.id;
		const bool root = is_root(n);
		std::map<int64_t, uint64_t> old;
		for(auto &x : m_entities)
			if(authored(x.second) && (uint64_t)json::jint(x.second.built, "by",
					0) == g)
				old[json::jint(x.second.built, "member", 0)] = x.first;
		const json::Value &es = pf.get("entities");
		std::map<int64_t, uint64_t> ids;
		std::set<uint64_t> kept;
		std::set<unsigned> others;
		std::set<uint64_t> others_ids;
		for(unsigned i = 0; i < es.size(); i++){
			const json::Value &m = es.at(i);
			const int64_t lid = json::jint(m, "id", 0);
			const int64_t pm = json::jint(m, "parent", 0);
			const json::Value &mb = m.get("built");
			if(root && mb.is_object()){
				auto by = ids.find(json::jint(mb, "by", 0));
				if(by == ids.end() || !kept.count(by->second)){
					ids[lid] = m_next_id++;
					continue;
				}
				others.insert(i);
				for(auto &x : m_entities)
					if(authored(x.second) && (uint64_t)json::jint(x.second.built,
							"by", 0) == by->second && json::jint(x.second.built,
							"member", 0) == json::jint(mb, "member", 0)){
						ids[lid] = x.first;
						others_ids.insert(x.first);
					}
				continue;
			}
			const uint64_t want_parent = pm ? ids[pm] : g;
			auto o = old.find(lid);
			const Entity *oe = o == old.end() ? nullptr : &m_entities[o->second];
			const json::Value &cs_ = m.get("components");
			if(oe && oe->parent == want_parent && !oe->comps.empty() &&
					cs_.size() && oe->comps[0].type ==
					full_type(jstr(cs_.at(0u), "type"))){
				ids[lid] = oe->id;
				kept.insert(oe->id);
			} else {
				ids[lid] = m_next_id++;
			}
		}
		std::set<uint64_t> gone, was_built;
		for(auto &o : old){
			was_built.insert(o.second);
			if(!kept.count(o.second))
				gone.insert(o.second);
		}
		if(root)
			for(auto &x : m_entities)
				if(authored(x.second) && gone.count((uint64_t)json::jint(
						x.second.built, "by", 0))){
					gone.insert(x.first);
					was_built.insert(x.first);
				}
		// The rows this writes are this build's alone
		std::set<uint64_t> mine(gone.begin(), gone.end());
		for(auto &x : ids)
			if(x.second && !others_ids.count(x.second))
				mine.insert(x.second);
		const double zero[3] = {0, 0, 0};
		size_t overrides = 0;
		sv_<json::Value> rows;
		sv_<unsigned> row_member;
		{
			sv_<json::Value> all;
			instantiate(pf, "", g, zero, 0, all, 0, &ids);
			for(unsigned i = 0; i < all.size(); i++)
				if(!others.count(i)){
					rows.push_back(all[i]);
					row_member.push_back(i);
				}
		}
		const json::Value &self_links = pf.get("to_self");
		for(unsigned i = 0; i < self_links.size(); i++){
			const json::Value &sl = self_links.at(i);
			const size_t r = (size_t)sl.at(0u).as_number() - 1;
			const unsigned k = (unsigned)sl.at(1u).as_number();
			if(r >= rows.size())
				continue;
			json::Value cs_ = rows[r].get("components");
			json::Value cj = cs_.at(k), ls = cj.get("links"),
					lj = json::object();
			lj.set("output", sl.at(2u));
			lj.set("to", (int64_t)g);
			lj.set("input", sl.at(3u));
			ls.append(lj);
			cj.set("links", ls);
			cs_.set_at(k, cj);
			rows[r].set("components", cs_);
		}
		for(size_t i = 0; i < rows.size(); i++){
			json::Value &row = rows[i];
			const uint64_t id = (uint64_t)json::jint(row, "id", 0);
			json::Value bt = json::object();
			bt.set("by", (int64_t)g);
			bt.set("member", json::jint(es.at(row_member[i]), "id", 0));
			row.set("name", jstr(row, "name").substr(0, MAX_STRING));
			if(jstr(row, "name").empty()){
				const json::Value &cs_ = row.get("components");
				row.set("name", (cs_.size() ? jstr(cs_.at(0u), "type") :
						ss_("child"))+" "+itos(id));
			}
			// [KIT_PREFAB_ROOT] (new) with its builder, as the prefab has it
			if(root && es.at(row_member[i]).get("built").is_object())
				continue;
			if(!kept.count(id)){
				row.set("built", bt);
				continue;
			}
			// An old one: what the builder made of it kept
			const Entity &oe = m_entities[id];
			// ([KIT_PREFAB_ROOT] a member that is another prefab's copy follows
			// that prefab, not this one's idea of it)
			if(is_root(oe))
				row.set("prefab", oe.prefab);
			if(oe.built.get("moved").is_true()){
				bt.set("moved", true);
				json::Value pos = json::array();
				for(int k = 0; k < 3; k++)
					pos.append(oe.pos[k]);
				row.set("pos", pos);
				row.set("yaw", oe.yaw);
				row.set("pitch", oe.pitch);
				row.set("roll", oe.roll);
			}
			row.set("built", bt);
			json::Value cs_ = row.get("components");
			// [KIT_COMPONENTS] by its type: the prefab's may have gained or lost others
			for(unsigned c = 0; c < cs_.size(); c++){
				json::Value cj = cs_.at(c);
				auto oit = std::find_if(oe.comps.begin(), oe.comps.end(),
						[&](const Instance &x){
					return x.type == full_type(jstr(cj, "type"));
				});
				if(oit == oe.comps.end())
					continue;
				const Instance &oi = *oit;
				json::Value params = cj.get("params").is_object() ?
						cj.get("params") : json::object();
				json::Value ov = json::array();
				for(const ss_ &k : oi.overrides){
					params.set(k, oi.params.get(k));
					ov.append(k);
					overrides++;
				}
				cj.set("params", params);
				if(ov.size())
					cj.set("overrides", ov);
				json::Value ls = cj.get("links");
				for(const Link &l : oi.links){
					bool there = was_built.count(l.to) > 0;
					for(unsigned m = 0; !there && m < ls.size(); m++)
						there = jstr(ls.at(m), "output") == l.output &&
								(uint64_t)json::jint(ls.at(m), "to", 0) == l.to &&
								jstr(ls.at(m), "input") == l.input;
					if(there)
						continue;
					json::Value lj = json::object();
					lj.set("output", l.output);
					lj.set("to", (int64_t)l.to);
					lj.set("input", l.input);
					if(l.visible)
						lj.set("visible", true);
					ls.append(lj);
				}
				cj.set("links", ls);
				cs_.set_at(c, cj);
			}
			row.set("components", cs_);
		}
		// What a builder put under one that goes: under g, where it was
		sv_<json::Value> moved;
		for(auto &x : m_entities){
			if(!gone.count(x.second.parent) || was_built.count(x.first) ||
					!authored(x.second))
				continue;
			json::Value row = world_row(x.second);
			row.set("parent", (int64_t)g);
			localize(row);
			moved.push_back(row);
			mine.insert(x.first);
		}
		// The edit's own rows of these give way to the build's; the links
		// to those that go, out of every other row
		auto strip = [&](json::Value &row){
			json::Value cs_ = row.get("components");
			bool any = false;
			for(unsigned c = 0; c < cs_.size(); c++){
				const json::Value &ls = cs_.at(c).get("links");
				json::Value keep = json::array();
				for(unsigned l = 0; l < ls.size(); l++)
					if(gone.count((uint64_t)json::jint(ls.at(l), "to", 0)))
						any = true;
					else
						keep.append(ls.at(l));
				json::Value cj = cs_.at(c);
				cj.set("links", keep);
				cs_.set_at(c, cj);
			}
			if(any)
				row.set("components", cs_);
			return any;
		};
		change.erase(std::remove_if(change.begin(), change.end(),
				[&](const std::pair<uint64_t, json::Value> &c){
			return mine.count(c.first) > 0;
		}), change.end());
		std::set<uint64_t> in_change;
		for(auto &c : change){
			in_change.insert(c.first);
			if(!c.second.is_null())
				strip(c.second);
		}
		for(auto &x : m_entities){
			if(mine.count(x.first) || in_change.count(x.first) ||
					!authored(x.second))
				continue;
			json::Value row = entity_json(x.second);
			if(strip(row))
				change.push_back(std::make_pair(x.first, row));
		}
		for(uint64_t id : gone)
			change.push_back(std::make_pair(id, json::null()));
		for(json::Value &row : rows)
			change.push_back(std::make_pair((uint64_t)json::jint(row, "id", 0),
					row));
		for(json::Value &row : moved)
			change.push_back(std::make_pair((uint64_t)json::jint(row, "id", 0),
					row));
		what += ", built "+itos(g)+" again: "+itos(rows.size())+" children ("+
				itos(kept.size())+" kept, "+itos(rows.size() - kept.size())+
				" new, "+itos(gone.size())+" gone"+(overrides ? ", "+
				itos(overrides)+" overrides kept" : ss_())+")";
	}

	// The generators an edit's change touches, built again into it: one
	// placed (not a copy with its children) or with its parameters
	// changed. A child of one a builder moved or put elsewhere is marked
	// so first. false and why: a build refused (the edit with it)
	bool rebuilds(sv_<std::pair<uint64_t, json::Value>> &change,
			Peer &p, ss_ &what, ss_ &why)
	{
		for(auto &c : change){
			if(c.second.is_null() || !c.second.get("built").is_object())
				continue;
			auto it = m_entities.find(c.first);
			// [KIT_SYMMETRY] a copy is its source's, not built
			if(it == m_entities.end() || copy_by(it->second))
				continue;
			const Entity &o = it->second;
			if((uint64_t)json::jint(c.second, "parent", 0) != o.parent){
				// Put under another: the builder's now
				c.second.del_key("built");
				continue;
			}
			const json::Value &pos = c.second.get("pos");
			bool moved = c.second.get("yaw").is_number() &&
					c.second.get("yaw").as_number() != o.yaw;
			moved = moved || row_num(c.second, "pitch") != o.pitch ||
					row_num(c.second, "roll") != o.roll;
			for(unsigned k = 0; pos_ok(pos) && k < 3; k++)
				moved = moved || pos.at(k).as_number() != o.pos[k];
			if(moved){
				json::Value bt = c.second.get("built").deepcopy();
				bt.set("moved", true);
				c.second.set("built", bt);
			}
		}
		// [KIT_PREFAB_ROOT] The prefab just saved: its other copies built
		// again, as a generator's children are (here, so that what the build
		// moves is no builder's moving)
		if(!m_follow.empty()){
			const ss_ name = m_follow;
			m_follow.clear();
			const json::Value *pf = prefab(name);
			sv_<uint64_t> roots;
			for(auto &x : m_entities)
				if(authored(x.second) && is_root(x.second) && x.first !=
						m_follow_source && jstr(x.second.prefab, "of") == name)
					roots.push_back(x.first);
			for(uint64_t id : roots){
				Entity e = m_entities[id];
				e.prefab = e.prefab.deepcopy();
				e.prefab.set("version", json::jint(*pf, "version", 1));
				// simplified: a copy that had no place gets the scene's origin
				// when its prefab comes to need one; moved from there by hand
				if(!e.has_pos && needs_place(*pf))
					e.has_pos = true;
				change.push_back(std::make_pair(id, entity_json(e)));
				rebuild(e, *pf, change, what);
			}
			if(!roots.empty())
				what += " ("+itos(roots.size())+" other copies follow it)";
		}
		sv_<std::pair<Entity, size_t>> gens;
		for(auto &c : change){
			if(c.second.is_null())
				continue;
			Entity n;
			ss_ bad;
			if(!entity_from_json(c.second, n, bad))
				continue;
			auto it = m_entities.find(n.id);
			if(it != m_entities.end() && copy_by(it->second))
				continue;
			for(size_t ci = 0; ci < n.comps.size(); ci++){
				if(!m_types[n.comps[ci].type].handlers.count("on_build"))
					continue;
				bool again;
				if(it == m_entities.end()){
					// A copy (a duplicate, a prefab's, a paste) has its own
					again = true;
					for(auto &x : change)
						if(!x.second.is_null() && (uint64_t)json::jint(
								x.second.get("built"), "by", 0) == n.id)
							again = false;
				} else {
					again = ci >= it->second.comps.size() ||
							it->second.comps[ci].type != n.comps[ci].type ||
							it->second.comps[ci].params.stringify() !=
							n.comps[ci].params.stringify();
				}
				if(again){
					gens.push_back(std::make_pair(n, ci));
					break;
				}
			}
		}
		for(auto &gi : gens){
			const Entity &n = gi.first;
			const size_t ci = gi.second;
			json::Value pf;
			// The builder's allowance, charged what the build spent
			const int64_t t_us = interface::os::time_us();
			p.build_tokens = std::min(BUILD_BURST, p.build_tokens +
					(t_us - p.build_at) * 1e-6 * BUILD_RATE);
			p.build_at = t_us;
			if(p.build_tokens < BUILD_MIN){
				why = "generators built too often: again in "+itos((int64_t)
						std::ceil((BUILD_MIN - p.build_tokens) / BUILD_RATE))+" s";
				log_i(MODULE, "Entity %s's build refused: %s", cs(itos(n.id)),
						cs(why));
				return false;
			}
			int64_t spent = 0;
			const bool built = build_of(n, ci, pf, why, &spent);
			p.build_tokens -= std::max(BUILD_MIN, m_box ? (double)spent /
					std::max<int64_t>(1, m_box->budget()) : BUILD_MIN);
			if(!built){
				why = "entity "+itos(n.id)+"'s "+n.comps[ci].type+": "+why;
				log_i(MODULE, "Entity %s's build refused: %s", cs(itos(n.id)),
						cs(why));
				return false;
			}
			size_t now = 0;
			for(auto &x : m_entities)
				now += (uint64_t)json::jint(x.second.built, "by", 0) == n.id ?
						0 : 1;
			if(now + pf.get("entities").size() > MAX_ENTITIES){
				why = "the composition has "+itos(MAX_ENTITIES)+" entities";
				return false;
			}
			rebuild(n, pf, change, what);
			// Its voxels, with the edit's (one box an edit; simplified: what
			// an earlier build wrote stays where this one writes none)
			if(pf.get("voxels").is_object() && !m_paste.set){
				if(m_host.scenes.find(p.scene) == m_host.scenes.end()){
					what += ", its voxels not written (not in a scene of the "
							"app's)";
					continue;
				}
				double w[3];
				Turn wq;
				world_of(n, w, &wq);
				const double wy = wq.yaw();
				m_paste.vox = pf.get("voxels");
				for(int k = 0; k < 3; k++)
					m_paste.base[k] = (int)std::floor(w[k] + 0.5);
				m_paste.turn = ((int)std::floor(wy / 90 + 0.5) % 4 + 4) % 4;
				m_paste.set = true;
			}
		}
		return true;
	}

	// ---- Debugging for novices ([KIT] stage 4d): each entity's log

	void add_log(uint64_t id, const ss_ &line)
	{
		if(!id)
			return;
		// The game clock's minutes and seconds
		char t[32];
		const double sec = std::fmod(now_us() / 1e6, 3600);
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
					double w[3];
					world_of(*te, w);
					x = w[0];
					y = w[1];
					z = w[2];
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
			add_log(e.id, ss_("a teleport refused: ")+why);
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
					now_us() + 10000000);
		to_scene(peer, other ? target : "", x, y, z, look);
	}

	// [KIT_CTF] c:move(pos, {fall}): the entity itself to a place in the
	// world (and what is under it with it), back where it was at Stop; with
	// fall, onto the first solid below there (fall_to), on_fall(c, pos)
	// after (pos where it landed; nil: nothing below, it stayed). A
	// player's entity (c:teleport moves them) or one owning voxels is
	// refused
	void move_fx(Entity &e, size_t comp, const json::Value &m, const ss_ &by)
	{
		const uint64_t id = e.id;
		const ss_ type = comp < e.comps.size() ? e.comps[comp].type : "";
		double w[3];
		for(unsigned k = 0; k < 3; k++)
			w[k] = m.at(k).is_number() ? m.at(k).as_number() : 0;
		ss_ why;
		if(!e.has_pos || e.kind == "player")
			why = "it has no place of its own to move";
		else if(!owned_cells(e).empty())
			why = "it owns voxels";
		for(int k = 0; k < 3 && why.empty(); k++)
			if(!std::isfinite(w[k]) || std::fabs(w[k]) > MAX_COORD)
				why = "past the world's coordinates";
		if(!why.empty()){
			log_w(MODULE, "Entity %s's %s: a move refused: %s", cs(itos(id)),
					cs(type), cs(why));
			add_log(id, "a move refused: "+why);
			return;
		}
		const bool fall = m.at(3u).is_true();
		const bool landed = !fall || fall_to(e, w);
		if(landed){
			if(!m_seat_home.count(id))
				m_seat_home[id] = home_of(e);
			double l[3];
			to_local(e.parent, w, l);
			for(int k = 0; k < 3; k++)
				e.pos[k] = l[k];
			place_nodes(id);
			log_i(MODULE, "Entity %s's %s moves to (%g, %g, %g)", cs(itos(id)),
					cs(type), w[0], w[1], w[2]);
		} else {
			log_i(MODULE, "Entity %s's %s: nothing to fall onto below (%g, "
					"%g, %g)", cs(itos(id)), cs(type), w[0], w[1], w[2]);
		}
		if(!fall || !m_types[type].handlers.count("on_fall"))
			return;
		Run r;
		r.entity = id;
		r.comp = comp;
		r.handler = "on_fall";
		r.by = by;
		if(landed){
			json::Value p = json::array();
			for(int k = 0; k < 3; k++)
				p.append(w[k]);
			r.args.append(p);
		} else {
			r.args.append(json::null());
		}
		queue_run(r);
	}

	// [KIT_CTF] A point dropped onto the first solid voxel below its cell
	// (or a heightmap's ground over it): w[1] the middle of the cell over
	// it (the ground + 0.5). A cell not loaded counts as solid, as
	// move.lua's; false: nothing down to the World's bottom
	bool fall_to(const Entity &e, double w[3])
	{
		ss_ scene;
		main_context::SceneReference sr = scene_of(e, &scene);
		const int x = (int)std::floor(w[0] + 0.5),
				z = (int)std::floor(w[2] + 0.5),
				bottom = WORLD_SECTION_Y0 * WORLD_SECTION;
		bool found = false;
		double y = 0;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *vw = sr ? ivw->get_instance(sr) : nullptr;
			if(!vw)
				return;
			interface::VoxelRegistry *reg = vw->get_voxel_reg();
			const auto &fmt = reg->get_format();
			const pv::Vector3DInt16 ss = vw->get_section_size_voxels();
			auto div = [](int a, int b){ return a >= 0 ? a / b : -((-a + b - 1) / b); };
			for(int j = (int)std::floor(w[1] + 0.5) - 1; j >= bottom; j--){
				const pv::Vector3DInt16 sp(div(x, ss.getX()), div(j, ss.getY()),
						div(z, ss.getZ()));
				bool solid = !vw->is_section_loaded(sp);
				if(!solid){
					const interface::VoxelDefinition *d = reg->get((uint32_t)
							fmt.id.get(vw->get_voxel(pv::Vector3DInt32(x, j, z),
							true).data));
					solid = d && d->physically_solid;
				}
				if(solid){
					found = true;
					y = j + 1;
					break;
				}
			}
		});
		// The World's heightmap ground, where it is over the voxels found
		World *wd = world_at(sr);
		WorldScope ws(m_w, wd);
		if(wd && m_w->world_scene && sr == m_w->world_scene &&
				m_w->wp.heightmap())
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_w->world_scene);
				if(!map)
					return;
				const double g = map->height_at((float)w[0], (float)w[2]) + 0.5;
				if(g <= w[1] && (!found || g > y)){
					found = true;
					y = g;
				}
			});
		if(found)
			w[1] = y;
		return found;
	}

	// [KIT_CTF] c:speed(player, factor): the player's movement's `speed`
	// times factor (0...10) from now on, on the server's steps and their
	// client's prediction (controls_for sends the parameters), until the
	// next call, their body's going (a leave, another session) or Stop. A
	// player it reaches: the run's, or any for a type with `players`
	void speed_fx(const Entity &e, size_t comp, const ss_ &by,
			const json::Value &s)
	{
		const json::Value &who = s.at(0u);
		const uint64_t pid = who.is_string() ? player_id(who.as_string()) :
				who.is_number() && who.as_number() > 0 ?
				(uint64_t)who.as_number() : 0;
		const double f = s.at(1u).is_number() ? s.at(1u).as_number() : 1;
		auto pi = m_entities.find(pid);
		ss_ why;
		if(pi == m_entities.end() || pi->second.kind != "player")
			why = "no player";
		else if(!reach(e, comp, by).count(pid))
			why = "not a player it reaches";
		else if(!(f >= 0 && f <= 10))
			why = "a factor from 0 to 10";
		const size_t peer = why.empty() ? peer_of_player(pid) : 0;
		if(why.empty() && (!peer || !m_host.controls))
			why = "they are not here";
		if(!why.empty()){
			add_log(e.id, "speed "+itos(pid)+" refused: "+why);
			return;
		}
		Body &b = m_bodies[peer];
		if(b.speed != f)
			log_i(MODULE, "%s's speed x%g", cs(pi->second.name), f);
		b.speed = f;
	}

	// [KIT_VEHICLE_MOVEMENTS] c:set_param(id, type, param, value): a parameter of an
	// entity's component it reaches, from now until Stop (play's; the row keeps its
	// own). Checked as an edit's. A movement's go into its next step: a steered one's
	// next batch, a body's next input (its client told, kit:controls)
	// simplified: movements read them (move_params()); the other types' c.params
	// stay their rows'
	void set_param_fx(const Entity &e, size_t comp, const ss_ &by, const json::Value &s)
	{
		const uint64_t id = s.at(0u).is_number() ? (uint64_t)s.at(0u).as_number() : 0;
		const ss_ type = s.at(1u).is_string() ? s.at(1u).as_string() : ss_();
		const ss_ param = s.at(2u).is_string() ? s.at(2u).as_string() : ss_();
		auto ti = m_entities.find(id);
		ss_ why;
		const Instance *in = nullptr;
		if(ti == m_entities.end() || !reach(e, comp, by).count(id))
			why = "not an entity it reaches";
		else
			for(const Instance &x : ti->second.comps)
				if(x.type == type)
					in = &x;
		const json::Value &decl = in ? m_types[type].decl.get("params").get(param) :
				json::Value();
		if(why.empty() && !in)
			why = "it has no "+type.substr(0, 64);
		else if(why.empty() && !decl.is_object())
			why = type+" has no parameter "+param.substr(0, 64);
		if(why.empty()){
			const ss_ bad = check_param(decl, s.at(3u));
			if(!bad.empty())
				why = param+" is "+bad;
		}
		if(!why.empty()){
			add_log(e.id, "set_param refused: "+why);
			log_i(MODULE, "Entity %s: set_param refused: %s", cs(itos(e.id)), cs(why));
			return;
		}
		m_play_params[id][type+"|"+param] = s.at(3u);
		log_i(MODULE, "Entity %s's %s %s set to %s in play", cs(itos(id)), cs(type),
				cs(param), cs(s.at(3u).stringify()));
	}

	// [KIT_CARRY_ATTACH] c:attach(player, {bone, offset}): its own entity
	// on a player it reaches, in its scene: drawn by every client at the
	// player's drawn body (the node's "kit_attach": "<player> <bone> <x>
	// <y> <z>"), its place (c.pos, for logic) the server's, ATTACH_US
	// apart (attach_tick()). Not a player's entity, nor one owning voxels.
	// Until c:detach(), Stop, either going, or the player leaving the
	// scene; where it was at Stop it is again (as c:move's)
	static const int64_t ATTACH_US = 200000;
	void attach_fx(Entity &e, size_t comp, const ss_ &by, const json::Value &a)
	{
		const json::Value &who = a.at(0u);
		const uint64_t pid = who.is_string() ? player_id(who.as_string()) :
				who.is_number() && who.as_number() > 0 ?
				(uint64_t)who.as_number() : 0;
		const ss_ bone = jstr_at(a, 1);
		auto pi = m_entities.find(pid);
		ss_ why, es, ps;
		if(pi == m_entities.end() || pi->second.kind != "player" ||
				!pi->second.has_pos)
			why = "no placed player";
		else if(!reach(e, comp, by).count(pid))
			why = "not a player it reaches";
		else if(!e.has_pos || e.kind == "player")
			why = "it has no place of its own";
		else if(!owned_cells(e).empty())
			why = "it owns voxels";
		else if(!scene_of(e, &es) || !scene_of(pi->second, &ps) || es != ps)
			why = "the player is in another scene";
		else if(bone != "" && bone != "head" && bone != "body" && bone != "hand")
			why = "a bone: head, body, hand or none";
		Attach at;
		for(int k = 0; k < 3 && why.empty(); k++){
			const json::Value &v = a.at(2 + k);
			at.off[k] = v.is_number() ? v.as_number() : 0;
			if(!std::isfinite(at.off[k]) || std::fabs(at.off[k]) > 16)
				why = "an offset of 16 m at most";
		}
		if(!why.empty()){
			add_log(e.id, "attach to "+itos(pid)+" refused: "+why);
			log_w(MODULE, "Entity %s: an attach refused: %s", cs(itos(e.id)),
					cs(why));
			return;
		}
		at.player = pid;
		at.bone = bone;
		if(!m_seat_home.count(e.id))
			m_seat_home[e.id] = home_of(e);
		m_attached[e.id] = at;
		log_i(MODULE, "Entity %s attached to %s (%s, %g, %g, %g)",
				cs(itos(e.id)), cs(pi->second.name), bone.empty() ? "feet" :
				cs(bone), at.off[0], at.off[1], at.off[2]);
		attach_tick(e.id);
	}

	void detach(uint64_t id, const ss_ &why)
	{
		auto ai = m_attached.find(id);
		if(ai == m_attached.end())
			return;
		m_attached.erase(ai);
		auto ei = m_entities.find(id);
		if(ei != m_entities.end() && ei->second.node)
			main_context::access(m_server, scene_of(ei->second),
					[&](magic::Scene *sc){
				magic::Node *n = sc->GetNode(ei->second.node);
				if(n)
					n->SetVar(magic::StringHash("kit_attach"),
							magic::Variant(""));
			});
		log_i(MODULE, "Entity %s detached (%s)", cs(itos(id)), cs(why));
	}

	// Each attached entity's place kept on its player's (only = one now):
	// the bone's rough height over the feet, the offset turned by the
	// view's yaw; the client's node told once it is there
	void attach_tick(uint64_t only = 0)
	{
		const int64_t now = interface::os::time_us();
		sv_<std::pair<uint64_t, ss_>> gone;
		for(auto &ap : m_attached){
			if(only && ap.first != only)
				continue;
			Attach &a = ap.second;
			auto ei = m_entities.find(ap.first);
			auto pi = m_entities.find(a.player);
			ss_ es, ps;
			if(ei == m_entities.end() || !ei->second.has_pos){
				gone.push_back({ap.first, "it is gone"});
				continue;
			}
			if(pi == m_entities.end() || !pi->second.has_pos ||
					!scene_of(ei->second, &es) || !scene_of(pi->second, &ps) ||
					es != ps){
				gone.push_back({ap.first, "its player is gone"});
				continue;
			}
			Entity &e = ei->second;
			if(e.node && a.told != e.node){
				a.told = e.node;
				char buf[160];
				snprintf(buf, sizeof buf, "%llu %s %g %g %g",
						(unsigned long long)a.player, a.bone.empty() ? "-" :
						a.bone.c_str(), a.off[0], a.off[1], a.off[2]);
				main_context::access(m_server, scene_of(e), [&](magic::Scene *sc){
					magic::Node *n = sc->GetNode(e.node);
					if(n)
						n->SetVar(magic::StringHash("kit_attach"),
								magic::Variant(buf));
				});
			}
			if(!only && now - a.at_us < ATTACH_US)
				continue;
			a.at_us = now;
			double yaw = 0;
			const size_t peer = peer_of_player(a.player);
			auto bi = peer ? m_bodies.find(peer) : m_bodies.end();
			if(bi != m_bodies.end())
				yaw = bi->second.look_yaw * 0.017453292519943295;
			// The bone's place on the body (simplified: its rest, the
			// model's; players.lua draws it posed)
			double b[3] = {0, 0, 0};
			if(a.bone == "head")
				b[1] = 1.3;
			else if(a.bone == "body")
				b[1] = 1.0;
			else if(a.bone == "hand")
				b[0] = 0.3, b[1] = 0.8;
			const double lx = b[0] + a.off[0], lz = b[2] + a.off[2];
			// (the player's entity's place is its feet's cell's middle)
			double w[3] = {pi->second.pos[0] + lx * std::cos(yaw) +
					lz * std::sin(yaw), pi->second.pos[1] - 0.5 + b[1] + a.off[1],
					pi->second.pos[2] - lx * std::sin(yaw) + lz * std::cos(yaw)};
			double l[3];
			to_local(e.parent, w, l);
			if(std::fabs(l[0] - e.pos[0]) + std::fabs(l[1] - e.pos[1]) +
					std::fabs(l[2] - e.pos[2]) < 0.01)
				continue;
			for(int k = 0; k < 3; k++)
				e.pos[k] = l[k];
			place_nodes(e.id);
		}
		for(auto &g : gone)
			detach(g.first, g.second);
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
						v.get(it.key()).is_boolean() ? (*it).is_boolean() :
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
		const int64_t now = now_us();
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
		// [KIT_LIGHTING] The lighting is the composition's: the root's
		// environment's (cartoon with none there), whatever a scene's says
		const Instance *root = env_at(1);
		j.set("lighting", root ? env_values(*root).get("lighting") :
				json::Value("cartoon"));
		// and the voxel types that give light ({name: 1..15}), which
		// physical draws
		json::Value lamps = json::object();
		for(auto &m : m_registered)
			if(m.second.light > 0)
				lamps.set(m.first, (int64_t)std::min(15, m.second.light));
		j.set("lamps", lamps);
		EnvClock &c = env_clock(id, *in, v);
		if(key)
			*key = j.stringify()+"|"+itos(c.at)+"|"+std::to_string(c.base);
		j.set("time", env_hours(c, now_us()));
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
		const int64_t now = now_us();
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
				if(item_ok(it.key()) && n >= 1 && n <= MAX_ITEMS &&
						n == std::floor(n))
					mine.set(it.key(), (int64_t)n);
			}
		log_i(MODULE, "Entity %s's %s: %s has %s", cs(itos(e.id)), cs(type),
				cs(who), cs(mine.stringify()));
		// [KIT_TOOLS_1] what the hands may hold
		m_items_seen[who] = mine;
		check_hands(who, mine);
		// [KIT_INVENTORY_PLAY] what did not fit dropped, the slots sent
		slots_changed(who);
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
				if(item_ok(it.key()) && n >= 1 && n == std::floor(n))
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
		double w[3] = {0, 0, 0};
		if(e.has_pos)
			world_of(e, w);
		a->x = w[0], a->y = w[1], a->z = w[2];
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
		// [KIT_INVENTORY_PLAY]
		send_slots(who);
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
		SessionScope sc(*this, session_of_peer(peer));
		return can_dig_u(peer, x, y, z);
	}

	bool can_dig_u(size_t peer, int x, int y, int z)
	{
		return allows(peer, "dig", x, y, z, nullptr);
	}

	uint64_t region_of(size_t peer, int x, int y, int z)
	{
		SessionScope sc(*this, session_of_peer(peer));
		return region_of_u(peer, x, y, z);
	}

	uint64_t region_of_u(size_t peer, int x, int y, int z)
	{
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end())
			return 0;
		const Entity *re = nullptr;
		return region_at(pi->second.scene, x, y, z, &re) ? re->id : 0;
	}

	bool can_place(size_t peer, int x, int y, int z)
	{
		SessionScope sc(*this, session_of_peer(peer));
		return can_place_u(peer, x, y, z);
	}

	bool can_place_u(size_t peer, int x, int y, int z)
	{
		return allows(peer, "place", x, y, z, nullptr);
	}

	// ---- [KIT] stage 4j: regions

	// A region's extent: its state's size while a signal resized it, else
	// its parameter's
	void region_extent(const Instance &in, const Type &t, int n[3])
	{
		const json::Value &sz = in.state.get("size");
		extent(pos_ok(sz) ? sz : in.params.get(t.region), n,
				MAX_REGION_EXTENT);
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
				// simplified: a turned region decides by the cell's middle, so
				// its edge has steps of a cell for a player too (the zones use
				// their place); allows() taking the point is the upgrade
				double o[3];
				Turn q;
				box_frame(e, o, q);
				const double cell[3] = {(double)x, (double)y, (double)z};
				if(!box_holds(o, q, n, cell))
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
	// (edit rights), "team" (the members of the team the region `re` is
	// under, [KIT_MINIGAMES_1]), or names (a list, or a text of them)
	bool owns(size_t peer, const json::Value &owners,
			const Entity *re = nullptr)
	{
		const Peer &p = m_peers[peer];
		if(owners.is_string()){
			const ss_ o = owners.as_string();
			if(o == "nobody" || o.empty())
				return false;
			if(o == "builders")
				return can_edit(peer);
			if(o == "team")
				return re && in_team(p.player, team_over(*re));
			// [KIT_TEAM_LEFTOVERS] a team captured it (set_owner by team)
			if(o.compare(0, 5, "team:") == 0)
				return in_team(p.player, strtoull(o.c_str() + 5, nullptr, 10));
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

	// [KIT_MINIGAMES_1] The Team interface: the team an entity is under
	// (itself or the nearest one up its parents with a `team` type's
	// instance), 0 none; whether a player's entity is among a team's
	// members (its state's list of ids)
	uint64_t team_over(const Entity &e)
	{
		const Entity *x = &e;
		for(int i = 0; x && i <= MAX_NEST; i++){
			for(const Instance &in : x->comps)
				if(m_types[in.type].team)
					return x->id;
			auto it = m_entities.find(x->parent);
			x = it == m_entities.end() ? nullptr : &it->second;
		}
		return 0;
	}

	// [KIT_TEAM_JOIN_LEAVES_OTHERS] A player out of every team in the scene
	// of the one they joined but it
	void leave_teams(uint64_t player, const Entity &joined)
	{
		ss_ scene;
		scene_of(joined, &scene);
		for(auto &x : m_entities){
			ss_ xs;
			if(x.first == joined.id || !scene_of(x.second, &xs) || xs != scene)
				continue;
			for(size_t c = 0; c < x.second.comps.size(); c++){
				Instance &o = x.second.comps[c];
				if(!m_types[o.type].team)
					continue;
				const json::Value &m = o.state.get("members");
				json::Value keep = json::array();
				bool had = false;
				for(unsigned i = 0; i < m.size(); i++){
					if(m.at(i).is_number() &&
							(uint64_t)m.at(i).as_number() == player)
						had = true;
					else
						keep.append(m.at(i));
				}
				if(!had)
					continue;
				o.state.set("members", keep);
				m_runtime_dirty = true;
				if(m_types[o.type].shared.count("members"))
					replicate_state(x.second, c, "members");
				log_i(MODULE, "Entity %s's %s: player %s left it for entity %s",
						cs(itos(x.first)), cs(o.type), cs(itos(player)),
						cs(itos(joined.id)));
			}
		}
	}

	bool in_team(uint64_t player, uint64_t team)
	{
		auto it = m_entities.find(team);
		if(!player || it == m_entities.end())
			return false;
		for(const Instance &in : it->second.comps){
			if(!m_types[in.type].team)
				continue;
			const json::Value &m = in.state.get("members");
			for(unsigned i = 0; i < m.size(); i++)
				if(m.at(i).is_number() &&
						(uint64_t)m.at(i).as_number() == player)
					return true;
		}
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
		SessionScope sc(*this, session_of_peer(peer));
		if(!allows_u(peer, action, x, y, z, why))
			return false;
		auto pi = m_peers.find(peer);
		// [KIT_INVENTORY_PLAY] kit/game_rules' dig, place and placed_only
		if((action == "dig" || action == "place") && pi != m_peers.end()){
			const json::Value r = game_rules();
			ss_ no;
			if(!r.get(action).is_true())
				no = action == "dig" ? "No digging in this game" :
						"No placing in this game";
			else if(action == "dig" && r.get("placed_only").is_true() &&
					!player_placed(pi->second.scene, x, y, z))
				no = "Only what players placed can be dug";
			if(!no.empty()){
				if(why)
					*why = no;
				return false;
			}
		}
		if((action == "dig" || action == "place") && pi != m_peers.end() &&
				!session_room(cell_key(pi->second.scene, x, y, z), false)){
			if(why)
				*why = "This round's world takes no more changes here";
			return false;
		}
		return true;
	}

	bool allows_u(size_t peer, const ss_ &action, int x, int y, int z, ss_ *why)
	{
		auto pi = m_peers.find(peer);
		const bool build = action == "dig" || action == "place";
		// Stopped, the world is the start: only a builder changes it
		if(!m_hosted || pi == m_peers.end() || (build && !m_session.running)){
			if(why)
				*why = build ? "The server is not Running" : "Not here";
			return !build && pi != m_peers.end();
		}
		// [KIT_CTF] a dead player waiting to respawn does nothing but stand
		if(action != "enter" && player_waiting(pi->second.player)){
			if(why)
				*why = "Waiting to respawn";
			return false;
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
		// [KIT_REGION_NEW_RULES_EMPTY] Its rules not published yet (placed
		// and its start not run): its parameters, which the start publishes
		// as they are. Not "none": a player standing where it was placed
		// was put back by its enter rule
		const bool fresh = !rule.is_string();
		const ss_ ow = jstr(rg->params, "owner");
		const bool owner = owns(peer, !fresh ? rg->state.get("owners") :
				rg->params.get(ow == "players" ? "owners" : "owner"), re);
		// Who may: "all", "owners", "others" or "none"
		const ss_ who = !fresh ? rule.as_string() :
				rg->params.get(action).is_string() ?
				rg->params.get(action).as_string() : "none";
		const bool yes = who == "all" || who == (owner ? "owners" : "others");
		if(!yes && why)
			*why = refusal(action);
		return yes;
	}

	// [KIT_INVENTORY_PLAY] Whether a player placed the voxel at a cell in
	// this round: its mark a build ('b') of a voxel, not a dig. Edits
	// ('k': a builder's, or any with "Always keep builds") and a
	// persistent world's (no marks) do not count
	bool player_placed(const ss_ &scene, int x, int y, int z)
	{
		auto si = m_host.scenes.find(scene);
		if(si == m_host.scenes.end())
			return false;
		bool yes = false;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *w = ivw->get_instance(si->second);
			if(!w)
				return;
			auto mi = m_marks.find(section_key(scene, w,
					pv::Vector3DInt32(x, y, z)));
			if(mi == m_marks.end())
				return;
			auto ci = mi->second.find(std::make_tuple(x, y, z));
			yes = ci != mi->second.end() && ci->second.kind == 'b' &&
					type_of(w, ci->second.id) > 1;
		});
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
		if(w && !loaded(w, p) && lean_section(w, p))
			return loaded(w, p);
		if(!w || !hm_world_of(w) || loaded(w, p))
			return loaded(w, p);
		WorldScope ws(m_w, hm_world_of(w));
		// (the heightmap's samples: whole chunks of 64 from its origin,
		// apply_heightmap()'s, [KIT_HM_ORIGIN])
		const int ox = m_w->hm_corner ? 0 : m_w->wp.x0(),
				oz = m_w->hm_corner ? 0 : m_w->wp.z0();
		if(p.getX() < ox || p.getZ() < oz ||
				p.getX() >= ox + (m_w->wp.width + 63) / 64 * 64 ||
				p.getZ() >= oz + (m_w->wp.depth + 63) / 64 * 64)
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

	// A game session's finite map: a section not loaded, in the map,
	// copied from the start for a write (unloaded again once no player is
	// near, its change kept in the session's save). False if the World
	// is none such
	// simplified: a read of a cell far from every player sees it not
	// loaded, as an infinite World's (an entity there reads no voxels);
	// reading the start's through the SessionSource would take that away
	bool lean_section(voxelworld::Instance *w, const pv::Vector3DInt32 &p)
	{
		World *wd = nullptr;
		for(auto &x : m_worlds)
			if(x.second.lean_world == w)
				wd = &x.second;
		if(!wd)
			return false;
		const world::Params &wp = wd->wp;
		const int m = wp.border == "water" ? world::SEA_BORDER :
				wp.border == "wall" ? 1 : 0;
		if(p.getX() < wp.x0() - m || p.getX() >= wp.x0() + wp.width + m ||
				p.getZ() < wp.z0() - m || p.getZ() >= wp.z0() + wp.depth + m)
			return true;
		const pv::Vector3DInt16 sp = section_of(w, p);
		if(sp.getY() < WORLD_SECTION_Y0 || sp.getY() > WORLD_SECTION_Y1)
			return true;
		w->load_or_generate_section(sp);
		return true;
	}

	static pv::Vector3DInt16 section_of(voxelworld::Instance *w,
			const pv::Vector3DInt32 &p)
	{
		const pv::Vector3DInt16 ss = w->get_section_size_voxels();
		return pv::Vector3DInt16(div_floor(p.getX(), ss.getX()),
				div_floor(p.getY(), ss.getY()), div_floor(p.getZ(), ss.getZ()));
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
			const ss_ scene = scene_name(w.scene);
			if(!session_room(cell_key(scene, w.p.getX(), w.p.getY(),
					w.p.getZ()), true)){
				log_w(MODULE, "Voxel (%i,%i,%i) not set: session %s has "
						"written %zu sections", w.p.getX(), w.p.getY(),
						w.p.getZ(), cs(itos(m_active)), SESSION_MAX_WRITTEN);
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
	// player set (again), or taken back (seconds < 0); MAX_TIMERS at most.
	// from: when it counts from (0: now)
	void set_timer(const Entity &e, Instance &in, const ss_ &name,
			const ss_ &player, double s, const ss_ &by, int64_t from = 0)
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
		it->due_us = (from ? from : now_us()) + (int64_t)(s * 1e6);
		it->by = by;
	}

	// Timers due on the game's clock: on_timer(c, name, player), as by
	// whoever set it off
	void run_timers()
	{
		const int64_t now = now_us();
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
					r.timer_due = t.due_us;
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
		// [KIT_AIRSHIPS] stage 5: the ships touching a deadly kit/trigger_zone
		// (lost after the scan)
		sv_<std::pair<uint64_t, uint64_t>> touched;
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
				// [KIT_AIRSHIPS] a deadly zone as large as a region (the ground
				// under the islands)
				const bool deadly = in.type == TRIGGER_TYPE &&
						in.params.get("deadly").is_true();
				int n[3];
				extent(in.params.get(t.zone), n, deadly ? MAX_REGION_EXTENT : MAX_EXTENT);
				double o[3];
				Turn q;
				box_frame(e, o, q);
				if(deadly && m_session.running)
					ships_in_box(e.id, scene, o, q, n, touched);
				// Who is in it, by their entity's id; those arriving on it
				// by a teleport enter it silently
				std::set<ss_> now, silent;
				for(auto &pp : m_peers){
					const Peer &peer = pp.second;
					if(peer.scene != scene || !peer.player)
						continue;
					// [KIT_JOIN_ORIGIN_POSITION] One joining or not put yet is
					// nowhere: the app's place before the spawn's (the origin's
					// ground on a join and at a session's end) is in no zone
					auto bi = m_bodies.find(pp.first);
					const bool inside = !peer.spawning && (!m_host.controls ||
							(bi != m_bodies.end() && bi->second.put)) &&
							box_holds(o, q, n, peer.pos);
					if(inside != (in.inside.count(itos(peer.player)) > 0))
						log_i(MODULE, "Entity %s: %s %s its zone at %.3f,%.3f,%.3f",
								cs(itos(e.id)), cs(peer.name), inside ? "enters" :
								"leaves", peer.pos[0], peer.pos[1], peer.pos[2]);
					if(inside)
						now.insert(itos(peer.player));
					auto ar = m_arrive.find(peer.name);
					if(inside && ar != m_arrive.end() &&
							ar->second.first == e.id){
						if(ar->second.second > now_us())
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
		for(auto &tz : touched)
			ship_lost(tz.first, "app", "it touched a deadly zone ("+m_entities[tz.second].name+")");
	}

	// The ships (free objects with kit/hull) in a scene with a corner of their
	// boxes' bounds, or their middle, in a box (a zone's)
	void ships_in_box(uint64_t zone, const ss_ &scene, const double o[3], const Turn &q,
			const int n[3], sv_<std::pair<uint64_t, uint64_t>> &out)
	{
		for(auto &f : m_free_objects){
			auto ei = m_entities.find(f.first);
			if(ei == m_entities.end() || !hull_of(ei->second))
				continue;
			ss_ s;
			scene_of(ei->second, &s);
			auto bi = m_free_boxes.find(f.second.boxes);
			if(s != scene || bi == m_free_boxes.end() || bi->second.size() < 6)
				continue;
			const sv_<float> &bx = bi->second;
			double lo[3] = {1e9, 1e9, 1e9}, hi[3] = {-1e9, -1e9, -1e9};
			for(size_t b = 0; b + 6 <= bx.size(); b += 6)
				for(int k = 0; k < 3; k++)
					lo[k] = std::min(lo[k], (double)bx[b + k]),
					hi[k] = std::max(hi[k], (double)bx[b + 3 + k]);
			double w[3];
			Turn wq;
			world_of(ei->second, w, &wq);
			bool in = false;
			for(int c = 0; c < 9 && !in; c++){
				double p[3];
				for(int k = 0; k < 3; k++)
					p[k] = c == 8 ? (lo[k] + hi[k]) / 2 : (c >> k & 1) ? hi[k] : lo[k];
				wq.apply(p);
				for(int k = 0; k < 3; k++)
					p[k] += w[k];
				in = box_holds(o, q, n, p);
			}
			if(in)
				out.push_back(std::make_pair(f.first, zone));
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
		// [WB_HOVER_OUT_OF_REACH] how far it may use things (kit:use's)
		you.set("use_range", m_host.use_range);
		// [KIT_TOOLS_1] Kit's hotbar (not where the app has its own items)
		you.set("hands", !m_host.app_items && equipment_of(p.player));
		for(auto &t : m_types)
			if(!t.second.client.empty())
				parts.set(t.first, t.second.client);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:client_parts", parts.stringify());
			inetwork->send(peer, "kit:you", you.stringify());
		});
		send_sky((int64_t)peer);
		send_env(peer);
		send_actions((int64_t)peer);
		send_item_types((int64_t)peer);
		send_sounds((int64_t)peer);
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
		// [KIT_SESSIONS_1] Writes routed to owned voxels, by the session
		// whose scene it is; each round's tick in its own members
		std::deque<Write> all;
		{
			std::lock_guard<std::mutex> lock(m_writes_mutex);
			all.swap(m_writes);
		}
		std::map<uint64_t, std::deque<Write>> writes;
		for(Write &w : all)
			writes[session_of_ref(w.scene)].push_back(w);
		tick_round(writes[0]);
		sv_<uint64_t> ids;
		for(auto &s : m_sessions)
			ids.push_back(s.first);
		for(uint64_t id : ids){
			SessionScope sc(*this, id);
			tick_round(writes[id]);
			bench_stamp();
		}
		session_ops();
		rules_watch();
		if(!m_watches.empty())
			watch_flush();
		// Sessions nobody is in end: a draft as its builder leaves, a game
		// session after SESSION_IDLE_US
		const int64_t now = interface::os::time_us();
		std::set<uint64_t> used;
		for(auto &ps : m_peer_session)
			used.insert(ps.second);
		for(uint64_t id : ids){
			auto si = m_sessions.find(id);
			if(si == m_sessions.end())
				continue;
			GameSession &gs = *si->second;
			if(used.count(id)){
				gs.empty_since = 0;
				continue;
			}
			if(!gs.empty_since)
				gs.empty_since = now;
			if(gs.draft || now - gs.empty_since > SESSION_IDLE_US)
				end_session(id, "nobody in it");
		}
		if(!m_drop_scenes.empty())
			drop_scenes();
	}

	// One round's tick (the default's or a session's, entered); a
	// session's has no copies or start of its own to write
	// simplified: each session runs its round with a tick's whole budget
	// (MAX_SESSIONS of them at most), not a share of one
	void tick_round(std::deque<Write> &writes)
	{
		for(auto &w : m_worlds){
			WorldScope ws(m_w, &w.second);
			sky_relight_tick();
			hm_sections_tick();
		}
		// [KIT_CARRY_ATTACH]
		attach_tick();
		if(!m_active)
			flush_copies();
		// Writes into the start, made as their sections load: Running,
		// kept past the round's Stop
		for(size_t n = m_active ? 0 : m_start_writes.size(); n > 0; n--){
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
		sync_motions();
		int64_t spent = step_bodies(budget);
		spent += step_drives(budget - spent);
		send_tracks();
		free_bodies_tick();
		own_tick(); // [KIT_AIRSHIPS]
		if(m_session.running)
			radars_tick();
		send_controls();
		env_tick();
		// simplified: the world's actions looked for once a second, not
		// as the instances and their parameters change; a change hook is
		// the upgrade if a world of thousands makes the scan a cost
		if(interface::os::time_us() - m_actions_at > 1000000){
			m_actions_at = interface::os::time_us();
			send_actions(-1);
		}
		if(!m_session.running){
			m_projectiles.clear(); // [KIT_TOOLS_2]
			// Stopped: components do not run. A write routed to one is
			// made by no one
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
		// [KIT_TOOLS_2] reloads due, projectiles in flight
		reloads_tick();
		projectiles_tick();
		actions_held();
		check_zones();
		check_regions();
		// The queue, in order, within the tick's budget
		while(!m_queue.empty() && spent < budget && m_box){
			const Run r = m_queue.front();
			m_queue.pop_front();
			if(!left_out(r.entity))
				spent += run(r);
		}
		if(!m_queue.empty())
			log_v(MODULE, "%zu runs wait for the next tick", m_queue.size());
		else if(!m_kits_due.empty())
			kits_due();
		// [KIT_JOIN_ORIGIN_POSITION] the joins' runs done: placed
		if(m_queue.empty())
			for(auto &p : m_peers)
				p.second.spawning = false;
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
		// [KIT_VEHICLE_MOVEMENTS] the steered vehicle it rides (0: none; a seat on
		// one that is not steered here moves it by this body's steps)
		uint64_t ride = 0;
		bool failed = false; // a step's error logged
		// [KIT_TOOLS_1] the last input's yaw (degrees from +z toward +x):
		// a hit's knockback where nothing else gives its direction
		double look_yaw = 0;
		// [KIT_CTF] c:speed's factor on the movement's `speed`
		double speed = 1;
		// [KIT_PLAYER_MODEL] the last input's view pitch (degrees, down
		// positive), the client's count of its swings and its digging (1)
		// or not; the pose last set on the player's node
		double look_pitch = 0, swings = 0, dig = 0;
		ss_ pose_sent;
		// [KIT_PUT_COUNTED_CORRECTION] Play and Stop move what is under a body
		// before its client hears of it: the acks until then say "settle", a
		// difference the client takes without counting a correction.
		// simplified: a fixed time (SETTLE_US); a tick the client acknowledges
		// would end it exactly
		int64_t settle_until = 0;
	};
	static constexpr int64_t SETTLE_US = 500000;
	ss_ settle_json(const Body &b) const
	{
		return interface::os::time_us() < b.settle_until ? ",\"settle\":true" : "";
	}
	void settle_bodies()
	{
		for(auto &bp : m_bodies)
			bp.second.settle_until = interface::os::time_us() + SETTLE_US;
	}
	std::map<size_t, Body> m_bodies;
	sm_<size_t, ss_> m_controls_sent;
	// [KIT_MOVING_OBJECTS] when each peer last got the shared time (time_us)
	sm_<size_t, int64_t> m_clock_sent;
	// Vehicles moved in play, where they were: back at Stop
	std::map<uint64_t, std::array<double, 6>> m_seat_home;
	// [KIT_CARRY_ATTACH] Entities on players (c:attach): the player, the
	// bone ("" the feet, "head", "body", "hand"), the offset (m, in the
	// body's turn), the node told and when it was last placed
	struct Attach
	{
		uint64_t player = 0;
		ss_ bone;
		double off[3] = {0, 0, 0};
		uint32_t told = 0;
		int64_t at_us = 0;
	};
	std::map<uint64_t, Attach> m_attached;

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

	// [KIT_COMPONENTS] An entity's one movement (nullptr: none)
	const Instance* movement_on(const Entity &e)
	{
		for(const Instance &in : e.comps)
			if(is_movement(in.type))
				return &in;
		return nullptr;
	}

	// [KIT_VEHICLE_MOVEMENTS] What a seat drives: the nearest of it and what it is
	// under with a movement, not a course's (nullptr: none)
	Entity* vehicle_of(const Entity &seat)
	{
		auto it = m_entities.find(seat.id);
		for(int depth = 0; it != m_entities.end() && depth <= MAX_NEST + 2; depth++){
			if(const Instance *mv = movement_on(it->second))
				return m_types[mv->type].decl.get("movement").get("timed").is_true() ?
						nullptr : &it->second;
			it = m_entities.find(it->second.parent);
		}
		return nullptr;
	}
	Entity* vehicle_of(uint64_t seat)
	{
		auto it = m_entities.find(seat);
		return it == m_entities.end() ? nullptr : vehicle_of(it->second);
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
		// [KIT_VEHICLE_MOVEMENTS] the vehicle's, a seat's or what it is on; play's
		// parameters over its own
		if(b.seat)
			if(Entity *v = vehicle_of(b.seat)){
				const Instance *in = movement_on(*v);
				type = in->type;
				ss_ sc;
				scene_of(*v, &sc);
				params = move_params(*v, *in, sc, false);
				b.ride = m_drives.count(v->id) ? v->id : 0;
				return;
			}
		b.ride = 0;
		type = jstr(controls_params(), "movement", "kit/walker");
		if(!is_movement(type)){
			type = "";
			params = json::object();
			return;
		}
		params = params_of(type, root_instance(type));
		// [KIT_CTF] c:speed's factor (a seat's movement is the vehicle's own)
		const json::Value &sp = params.get("speed");
		if(b.speed != 1 && sp.is_number()){
			params.set("speed", sp.as_number() * b.speed);
			params = json::load_string(params.stringify().c_str());
		}
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
			// [KIT_VEHICLE_MOVEMENTS] a steered vehicle ridden: its inputs, no steps
			if(b.ride)
				c.set("ride", (int64_t)b.ride);
			if(b.seat)
				if(Entity *v = vehicle_of(b.seat))
					c.set("vehicle", (int64_t)v->id);
		}
		// [KIT_VEHICLE_MOVEMENTS] the steered ones that are no free object (a
		// turret, a car on a deck): {id, links}, moved by the clients as objects are
		json::Value steered = json::array();
		for(auto &d : m_drives){
			auto ei = m_entities.find(d.first);
			if(m_free_objects.count(d.first) || ei == m_entities.end() ||
					d.second.scene != pe.scene)
				continue;
			json::Value r = json::array();
			r.append((int64_t)d.first);
			r.append(links_of(ei->second));
			steered.append(r);
		}
		if(steered.size())
			c.set("steered", steered);
		c.set("voxels", voxel_extra());
		// [KIT_FREE_PREFAB] the free objects in its scene
		auto psi = m_host.scenes.find(pe.scene);
		json::Value objs = json::array();
		for(auto &f : m_free_objects){
			if(psi == m_host.scenes.end() || f.second.ref != psi->second)
				continue;
			json::Value r = json::array();
			r.append(f.second.boxes); // [KIT_AIRSHIPS] its boxes' name
			for(int k = 0; k < 6; k++)
				r.append(f.second.place[k]);
			r.append((int64_t)f.first);
			// [KIT_MOVING_OBJECTS] the node a client moves, what moves it
			r.append((int64_t)f.second.node);
			auto ei = m_entities.find(f.first);
			if(ei != m_entities.end())
				r.append(links_of(ei->second));
			objs.append(r);
		}
		if(objs.size())
			c.set("objects", objs);
		if(m_w->world_scene && m_w->wp.heightmap() && pe.scene == m_host.world_scene)
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_w->world_scene);
				if(!map)
					return;
				json::Value hm = json::array();
				hm.append(map->samples_x());
				hm.append(map->samples_z());
				// [KIT_HM_ORIGIN] its sample (0, 0)'s world cell
				hm.append(hm_ox(map));
				hm.append(hm_oz(map));
				c.set("hm", hm);
			});
		return c;
	}

	bool any_moving()
	{
		for(auto &f : m_free_objects){
			auto it = m_entities.find(f.first);
			if(it != m_entities.end() && moves(it->second))
				return true;
		}
		return false;
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
			// [KIT_MOVING_OBJECTS] The shared time, with the rows and then once a
			// second while something moves: all a client needs to place what moves
			int64_t &clock_at = m_clock_sent[p.first];
			const int64_t real = interface::os::time_us();
			if(s != sent || (real - clock_at >= 1000000 && any_moving())){
				clock_at = real;
				char clk[64];
				snprintf(clk, sizeof clk, "%.0f %.9g", motion_t() * 1000,
						interface::os::game_rate());
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(p.first, "kit:clock", clk);
				});
			}
			if(s == sent)
				continue;
			sent = s;
			network::access(m_server, [&](network::Interface *inetwork){
				// [KIT_FREE_PREFAB] the boxes of a model it has not got
				auto psi = m_host.scenes.find(p.second.scene);
				std::set<ss_> &got = m_boxes_sent[p.first];
				for(auto &f : m_free_objects){
					const ss_ &name = f.second.boxes;
					if(psi == m_host.scenes.end() || f.second.ref != psi->second ||
							!got.insert(name).second)
						continue;
					json::Value b = json::array();
					for(float v : m_free_boxes[name])
						b.append((double)v);
					inetwork->send(p.first, "kit:object_boxes",
							name+" "+b.stringify());
				}
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
		// [KIT_VEHICLE_MOVEMENTS] a steered one's seat goes with it: the body is there
		if(b.ride){
			ride_moved(peer, b);
			return;
		}
		if(b.seat){
			if(Entity *ve = vehicle_of(b.seat)){
				Entity &e = *ve;
				// [KIT_NESTING] the body's place is the world's
				// simplified: a vehicle stays level in the world under a tilted
				// parent; a pose of its own comes with 4r6's movements
				double w[3];
				Turn wq;
				world_of(e, w, &wq);
				w[0] = v[0], w[1] = v[1] + 0.5, w[2] = v[2];
				const json::Value &yaw = b.state.get("yaw");
				if(yaw.is_number() && std::isfinite(yaw.as_number()))
					wq = Turn::of(yaw.as_number());
				Turn lq;
				to_local(e.parent, w, e.pos, &wq, &lq);
				lq.angles(e.yaw, e.pitch, e.roll);
				e.yaw = norm_yaw(e.yaw);
				e.pitch = norm_yaw(e.pitch);
				e.roll = norm_yaw(e.roll);
				place_nodes(e.id);
			}
		}
		Peer &p = m_peers[peer];
		p.pos[0] = v[0];
		p.pos[1] = v[1] + 0.5;
		p.pos[2] = v[2];
		// [KIT_MOVING_OBJECTS] On a moving deck: from its feet in the deck
		p.frame = 0;
		const json::Value &fr = b.state.get("frame"), &at = b.state.get("at");
		if(fr.is_number() && pos_ok(at)){
			auto di = m_entities.find((uint64_t)fr.as_number());
			if(di != m_entities.end() && moves(di->second)){
				AtRest rest(m_at_rest);
				double o[3], l[3] = {at.at(0u).as_number(), at.at(1u).as_number(),
						at.at(2u).as_number()};
				Turn q;
				world_of(di->second, o, &q);
				q.apply(l);
				for(int k = 0; k < 3; k++)
					p.frame_rest[k] = o[k] + l[k];
				p.frame_rest[1] += 0.5;
				p.frame = di->first;
			}
		}
		world_peer(peer, p.scene, p.pos[0], p.pos[1], p.pos[2]);
		place_player(p);
	}

	// [KIT_VEHICLE_MOVEMENTS] A rider where its seat is now; drawn by the clients on
	// the seat as it rests, carried by the vehicle's links (kit_frame, kit_rest)
	void ride_moved(size_t peer, Body &b)
	{
		auto si = m_entities.find(b.seat);
		if(si == m_entities.end())
			return;
		Peer &p = m_peers[peer];
		double w[3];
		Turn q;
		world_of(si->second, w, &q);
		for(int k = 0; k < 3; k++)
			p.pos[k] = w[k];
		json::Value pos = json::array();
		pos.append(w[0]);
		pos.append(w[1] - 0.5);
		pos.append(w[2]);
		b.state.set("pos", pos);
		b.state.set("yaw", q.yaw());
		b.state.set("ride", (int64_t)b.ride);
		b.state_json = b.state.stringify();
		{
			AtRest rest(m_at_rest);
			world_of(si->second, p.frame_rest);
		}
		p.frame = b.ride;
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
		SessionScope sc(*this, session_of_peer(peer));
		put_player_u(peer, x, y, z, look);
	}

	void put_player_u(size_t peer, double x, double y, double z,
			double look)
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
	// [KIT_SESSIONS_1] in the sender's session
	void on_input(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_input_u(packet);
	}

	void on_input_u(const network::Packet &packet)
	{
		auto bi = m_bodies.find(packet.sender);
		if(bi == m_bodies.end() || !bi->second.put ||
				packet.data.size() > 16384)
			return;
		Body &b = bi->second;
		const uint32_t last = b.inputs.empty() ? b.ack : b.inputs.back().first;
		const bool waiting = m_peers.count(packet.sender) &&
				player_waiting(m_peers[packet.sender].player);
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
			// [KIT_PLAYER_MODEL] then the pitch, the swings and the dig,
			// for the body others see (an older client sends none);
			// [KIT_MOVING_OBJECTS] then the time it was stepped at (ms)
			// [KIT_VEHICLE_MOVEMENTS] then down (0/1: an airship's descent)
			double v[13] = {0};
			const int got = sscanf(one.c_str(), "%u %lf %lf %lf %lf %lf %lf "
					"%lf %lf %lf %lf %lf %lf %lf", &n, &v[0], &v[1], &v[2], &v[3], &v[4],
					&v[5], &v[6], &v[7], &v[8], &v[9], &v[10], &v[11], &v[12]);
			if(got != 9 && got != 12 && got != 13 && got != 14)
				continue;
			bool ok = n > at;
			for(int k = 0; k < 11; k++)
				ok = ok && std::isfinite(v[k]) && std::fabs(v[k]) <= MAX_COORD;
			if(!ok)
				continue;
			if(b.inputs.size() >= (size_t)MAX_INPUTS)
				break;
			at = n;
			// [KIT_CTF] a dead player waiting to respawn stays where they
			// fell: no walking, jumping or going (the view turns)
			if(waiting)
				v[0] = v[1] = v[3] = v[4] = 0;
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
			if(got == 14 && v[12] != 0)
				o += ",down=1";
			// [KIT_MOVING_OBJECTS] Taken within reason of the round's time: the server
			// steps it against the pose the client stepped it against, so a late
			// input is no correction. simplified: a client can choose its pose within
			// the window (a second back, a quarter ahead); its worth is a deck's
			// fraction of a swing, the window narrower is the upgrade if it is ever
			// worth more
			if(got >= 13 && std::isfinite(v[11]) && v[11] != 0){
				const double t_now = motion_t() * 1000;
				o += ",t=";
				lua_lit(json::Value(std::floor(std::max(t_now - 1000,
						std::min(t_now + 250, v[11])))), o);
			}
			o += "}";
			b.inputs.push_back(std::make_pair(n, o));
			b.look_yaw = v[2];
			b.look_pitch = std::max(-90.0, std::min(90.0, v[8]));
			b.swings = v[9];
			b.dig = v[10];
		}
		set_pose(packet.sender, b);
	}

	// [KIT_PLAYER_MODEL] What others draw of a player's body that its
	// node's place does not say, on the node as "kit_pose": "<yaw> <pitch>
	// <swings> <flags> <held item>" (flags: 1 digging, 2 in a seat, 4 not
	// in play: waiting to respawn), set as it changes
	void set_pose(size_t peer, Body &b)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end() || !pi->second.player)
			return;
		auto ei = m_entities.find(pi->second.player);
		if(ei == m_entities.end() || !ei->second.node)
			return;
		const int flags = (b.dig != 0 ? 1 : 0) | (b.seat ? 2 : 0) |
				(player_waiting(pi->second.player) ? 4 : 0);
		char buf[64];
		snprintf(buf, sizeof buf, "%.0f %.0f %.0f %d ", b.look_yaw,
				b.look_pitch, std::fmod(b.swings, 1000000), flags);
		const ss_ pose = buf + hands_of(pi->second.player);
		// (a node made again, at a scene's change, has none yet)
		const ss_ sent = itos(ei->second.node) + "|" + pose;
		if(sent == b.pose_sent)
			return;
		b.pose_sent = sent;
		main_context::access(m_server, scene_of(ei->second),
				[&](magic::Scene *sc){
			magic::Node *n = sc->GetNode(ei->second.node);
			if(n)
				n->SetVar(magic::StringHash("kit_pose"),
						magic::Variant(pose.c_str()));
		});
	}

	// [KIT_MOVING_OBJECTS] How fast what links_of() said can take a point at most rad
	// from the object: m/s
	double motion_speed(const json::Value &links, double rad)
	{
		double v = 0;
		const double tau = 2 * 3.14159265358979323846, deg = tau / 360;
		for(unsigned i = 0; i < links.size(); i++){
			const json::Value &m = links.at(i).at(6u);
			// [KIT_VEHICLE_MOVEMENTS] a steered one's last batch's
			if(m.get("track").is_number()){
				auto di = m_drives.find((uint64_t)m.get("track").as_number());
				if(di != m_drives.end())
					v += di->second.speed + di->second.turn * deg * rad;
			}
			for(const char *k : {"wave_roll", "wave_pitch", "wave_yaw", "wave_heave"}){
				const double period = row_num(m, (ss_(k)+"_period").c_str());
				if(period > 0)
					v += std::fabs(row_num(m, k)) * tau / period *
							(ss_(k) == "wave_heave" ? 1 : deg * rad);
			}
			const json::Value &c = m.get("course");
			if(row_num(m, "course_time") > 0 && pos_ok(c))
				v += (std::fabs(c.at(0u).as_number()) + std::fabs(c.at(1u).as_number()) +
						std::fabs(c.at(2u).as_number())) / row_num(m, "course_time");
		}
		return v;
	}

	// [KIT_AIRSHIP_CORE_DEATH] How far a look's box reaches from its entity's place
	// at most (move.lua's M.look_box: its size, a state's scale, the offsets)
	static double look_reach(const json::Value &look)
	{
		auto vec = [](const json::Value &v, double s[3], double def, double lo,
				double hi){
			for(unsigned i = 0; i < 3; i++){
				double x = v.is_array() && i < v.size() && v.at(i).is_number() ?
						v.at(i).as_number() : def;
				s[i] = std::isfinite(x) ? std::max(lo, std::min(hi, x)) : def;
			}
		};
		double s[3], k[3], a[3], b[3];
		const json::Value &sz = look.get("size"), &wh = look.get("when");
		if(sz.is_array()){
			vec(sz, s, 1, 0.02, 64);
		} else {
			const double v = sz.is_number() && std::isfinite(sz.as_number()) ?
					sz.as_number() * 2 : 0.8;
			s[0] = s[1] = s[2] = std::min(128.0, std::fabs(v));
		}
		vec(wh.get("scale"), k, 1, 1, 64);
		vec(look.get("offset"), a, 0, -1e6, 1e6);
		vec(wh.get("offset"), b, 0, -1e6, 1e6);
		double d2 = 0, o2 = 0;
		for(int i = 0; i < 3; i++){
			d2 += s[i] * k[i] * s[i] * k[i];
			o2 += (std::fabs(a[i]) + std::fabs(b[i])) * (std::fabs(a[i]) + std::fabs(b[i]));
		}
		return std::sqrt(d2) / 2 + std::sqrt(o2);
	}

	// The world round a body for a step: its cells, the solid looks near
	// it and a heightmap's samples (move.lua's snapshot)
	void snapshot(ss_ &o, const Peer &pe, const Body &b, const double pos[3],
			double r, double h, double reach)
	{
		const Entity *v = b.seat ? vehicle_of(b.seat) : nullptr;
		snapshot(o, pe.scene, b.state, v ? v->id : 0, pos, r, h, reach);
	}

	// [KIT_VEHICLE_MOVEMENTS] own: what is stepping (a vehicle), not met with what is
	// under it; the tracks of the scene's steered ones
	void snapshot(ss_ &o, const ss_ &scene_name, const json::Value &state, uint64_t own,
			const double pos[3], double r, double h, double reach)
	{
		WorldScope ws(m_w, world_named(scene_name));
		auto si = m_host.scenes.find(scene_name);
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
			if(!e.has_pos || e.kind == "player" || (own && under_or(e, own)))
				continue;
			// [KIT_NESTING] where it is in the world; what rides on the
			// vehicle stepping none either
			// [KIT_AIRSHIP_CORE_DEATH] each look as far as its own size reaches: an
			// island's edge is far from its middle (16x4x26: past 10 m from it
			// the body fell through). simplified: a look is met no further than
			// 64 m from its entity's place (a 64 m box's corner is 55 m out)
			double w[3];
			Turn wq;
			world_of(e, w, &wq);
			const double near[3] = {std::fabs(w[0] - pos[0]) - R - 8,
					std::fabs(w[1] - pos[1]) - ny - 8, std::fabs(w[2] - pos[2]) - R - 8};
			if(near[0] > 64 || near[1] > 64 || near[2] > 64)
				continue;
			// [KIT_MOVING_OBJECTS] one that moves: at rest, what moves it with it
			const json::Value links = links_of(e);
			if(links.size()){
				AtRest rest(m_at_rest);
				world_of(e, w, &wq);
			}
			ss_ es;
			if(scene_of(e, &es) != scene || !scene)
				continue;
			for(const Instance &in : e.comps){
				const json::Value &d = m_types[in.type].decl.get("look");
				if(d.is_undefined())
					continue;
				const json::Value look = look_of(in, d);
				const double lr = look_reach(look);
				if(near[0] > lr || near[1] > lr || near[2] > lr)
					continue;
				const ss_ key = jstr(look, "state");
				const bool on = !key.empty() && in.state.get(key).is_true();
				o += "{";
				lua_lit(look, o);
				o += on ? ",true,{" : ",false,{";
				for(int k = 0; k < 3; k++){
					lua_lit(json::Value(w[k]), o);
					o += ',';
				}
				o += "},";
				double wy, wp, wr;
				wq.angles(wy, wp, wr);
				lua_lit(json::Value(wy), o);
				if(wp != 0 || wr != 0 || links.size()){
					o += ",";
					lua_lit(json::Value(wp), o);
					o += ",";
					lua_lit(json::Value(wr), o);
				}
				if(links.size()){
					o += ",";
					lua_lit(links, o);
				}
				o += "},";
				break;
			}
		}
		o += "}";
		// [KIT_MOVING_OBJECTS] The time a step with no stamp of its own goes by
		o += ",t=";
		lua_lit(json::Value(motion_t()), o);
		// [KIT_FREE_PREFAB] The free objects' boxes near it
		o += ",turned={";
		for(auto &f : m_free_objects){
			if(f.second.ref != scene || f.first == own)
				continue;
			const std::array<double, 6> &wp = f.second.place;
			// [KIT_WALKER_FRAME] The feet in its frame
			double l[3] = {pos[0] - wp[0], pos[1] - wp[1], pos[2] - wp[2]};
			Turn::of(wp[3], wp[4], wp[5]).inverse().apply(l);
			double m = R + 2;
			const sv_<float> &bx = m_free_boxes[f.second.boxes];
			// [KIT_MOVING_OBJECTS] One moving: where it is now, as far again as it can
			// go by a stamp (on_input_u's window); one this body stands on: from the
			// feet there, whatever its pose
			auto fe = m_entities.find(f.first);
			json::Value links = json::array();
			if(fe != m_entities.end())
				links = links_of(fe->second);
			if(links.size()){
				const json::Value &st_at = state.get("at");
				const json::Value &st_fr = state.get("frame");
				if(st_fr.is_number() && (uint64_t)st_fr.as_number() == f.first &&
						pos_ok(st_at)){
					for(unsigned k = 0; k < 3; k++)
						l[k] = st_at.at(k).as_number();
				} else {
					double now[3];
					Turn nq;
					world_of(fe->second, now, &nq);
					for(int k = 0; k < 3; k++)
						l[k] = pos[k] - now[k];
					nq.inverse().apply(l);
					double far = 0;
					for(float c : bx)
						far = std::max(far, (double)std::fabs(c));
					m += 1.25 * motion_speed(links, far * std::sqrt(3.0));
				}
			}
			ss_ list;
			for(size_t i = 0; i + 6 <= bx.size(); i += 6){
				if(l[0] + m < bx[i] || l[0] - m > bx[i + 3] ||
						l[1] + h + m < bx[i + 1] || l[1] - m > bx[i + 4] ||
						l[2] + m < bx[i + 2] || l[2] - m > bx[i + 5])
					continue;
				for(size_t q = 0; q < 6; q++){
					lua_lit(json::Value((double)bx[i + q]), list);
					list += ',';
				}
			}
			if(list.empty())
				continue;
			o += "{";
			for(int k = 0; k < 6; k++){
				lua_lit(json::Value(wp[k]), o);
				o += ',';
			}
			o += "{"+list+"},"+itos(f.first);
			if(links.size()){
				o += ",";
				lua_lit(links, o);
			}
			o += "},";
		}
		o += "}";
		if(m_w->world_scene && m_w->wp.heightmap() && scene == m_w->world_scene)
			heightmap::access(m_server, [&](heightmap::Interface *ih){
				heightmap::Instance *map = ih->get_instance(m_w->world_scene);
				if(!map)
					return;
				// [KIT_HM_ORIGIN] world cells, the map from its origin
				const int ox = hm_ox(map), oz = hm_oz(map);
				const int hx0 = std::max(ox, x0), hz0 = std::max(oz, z0);
				const int hx1 = std::min(ox + map->samples_x() - 1, x0 + nx),
						hz1 = std::min(oz + map->samples_z() - 1, z0 + nz);
				if(hx1 < hx0 || hz1 < hz0)
					return;
				// [KIT_HM_FREE] the map's size: its edge is a wall
				o += ",hm={sx="+itos(map->samples_x())+",sz="+
						itos(map->samples_z())+",ox="+itos(ox)+",oz="+itos(oz)+
						",x0="+itos(hx0)+",z0="+
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
		tracks_lit(o, scene_name);
		o += "}";
	}

	// [KIT_VEHICLE_MOVEMENTS] ",tracks={[id]={{t, x, y, z, yaw, pitch, roll}...}}": the
	// keys of the steered ones in the scene, from TRACK_KEEP back (a stamp is a second
	// back at most)
	void tracks_lit(ss_ &o, const ss_ &scene_name)
	{
		o += ",tracks={";
		const double from = (motion_t() - 1.5) * 1000;
		char buf[48];
		for(auto &d : m_drives){
			if(d.second.scene != scene_name || d.second.keys.empty())
				continue;
			o += "["+itos(d.first)+"]={";
			const auto &k = d.second.keys;
			size_t i = 0;
			while(i + 2 < k.size() && k[i + 1][0] < from)
				i++;
			for(; i < k.size(); i++){
				o += "{";
				for(int n = 0; n < 7; n++){
					snprintf(buf, sizeof buf, "%.17g,", k[i][n]);
					o += buf;
				}
				o += "},";
			}
			o += "},";
		}
		o += "}";
	}

	// Whether e is id or under it
	bool under_or(const Entity &e, uint64_t id)
	{
		const Entity *at = &e;
		for(int depth = 0; at && depth <= MAX_NEST + 2; depth++){
			if(at->id == id)
				return true;
			auto it = m_entities.find(at->parent);
			at = it == m_entities.end() ? nullptr : &it->second;
		}
		return false;
	}

	// [KIT_VEHICLE_MOVEMENTS] Each drive stepped on to DRIVE_LEAD past the round's
	// time, one box call, a key at its end: what it spent
	int64_t step_drives(int64_t budget)
	{
		int64_t spent = 0;
		const double now = motion_t();
		for(auto &dp : m_drives){
			Drive &d = dp.second;
			auto ei = m_entities.find(dp.first);
			if(ei == m_entities.end() || d.failed || !m_box || spent >= budget)
				continue;
			const Entity &e = ei->second;
			const Instance *mv = movement_on(e);
			if(!mv)
				continue;
			const double rate = num(d.params, "rate", 60, 10, 120), dt = 1 / rate;
			if(d.t < now - 1)
				d.t = now - 1;
			const int n = std::min((int)std::floor((now + DRIVE_LEAD - d.t) * rate),
					2 * BATCH);
			if(n <= 0)
				continue;
			// The input: its holder's, else its own state's (signals)
			bool held = false;
			size_t holder = 0;
			for(auto &bp : m_bodies)
				if(!held && bp.second.ride == dp.first)
					held = true, holder = bp.first;
			ss_ in = held ? d.input : ss_();
			const double shots = row_num(d.state, "shots");
			if(!held){
				const json::Value &st = mv->state;
				in = "{f=";
				lua_lit(json::Value(std::max(-1.0, std::min(1.0, row_num(st, "throttle")))), in);
				in += ",r=";
				lua_lit(json::Value(std::max(-1.0, std::min(1.0, row_num(st, "steer")))), in);
				in += ",climb=";
				lua_lit(json::Value(std::max(-1.0, std::min(1.0, row_num(st, "climb")))), in);
				in += ",yaw=0,jump=0,go=0,tx=0,ty=0,tz=0}";
			}
			if(in.empty())
				in = "{f=0,r=0,yaw=0,jump=0,go=0,tx=0,ty=0,tz=0}";
			const json::Value bd = body_decl(d.type);
			const double r = num(bd, "r", 0.45, 0.05, 8), h = num(bd, "h", 1.7, 0.05, 16);
			double pos[3] = {0, 0, 0};
			const json::Value &sp = d.state.get("pos");
			for(unsigned k = 0; k < 3 && sp.is_array() && k < sp.size(); k++)
				pos[k] = sp.at(k).is_number() ? sp.at(k).as_number() : 0;
			ss_ o = "Sreturn {type=";
			lua_lit(json::Value(d.type), o);
			o += ",params=";
			lua_lit(d.params, o);
			o += ",state=";
			lua_lit(d.state, o);
			o += ",dt=";
			lua_lit(json::Value(dt), o);
			o += ",sub="+itos((int64_t)num(d.params, "substeps", 1, 1, 8));
			o += ",inputs={";
			for(int k = 0; k < n; k++)
				o += in.substr(0, in.size() - 1)+",t="+
						itos((int64_t)std::floor((d.t + k * dt) * 1000))+"},";
			o += "},world=";
			double v2 = 0;
			const json::Value &sv = d.state.get("vel");
			for(unsigned k = 0; k < 3 && sv.is_array() && k < sv.size(); k++)
				if(sv.at(k).is_number())
					v2 += sv.at(k).as_number() * sv.at(k).as_number();
			const double reach = std::min(16.0, (std::sqrt(v2) + 10) * n / rate);
			if(d.deck)
				deck_snapshot(o, d, e, pos, r, h, reach);
			else
				snapshot(o, d.scene, d.state, e.id, pos, r, h, reach);
			o += "}";
			ss_ answer, why;
			bool runaway = false;
			int64_t used = 0;
			const bool ok = box_call(o, answer, why, &runaway, &used);
			spent += used;
			if(!ok){
				log_w(MODULE, "Entity %s's %s: %s", cs(itos(e.id)), cs(d.type), cs(why));
				d.failed = true;
				continue;
			}
			d.state = json::load_string(answer.c_str());
			d.t += n * dt;
			// [KIT_SHIP] a gun's shots (kit/turret's): its holder's, at most a few a tick
			if(held)
				for(int k = 0; k < 4 && k < row_num(d.state, "shots") - shots; k++)
					drive_shot(holder, e, d.params);
			const json::Value &np = d.state.get("pos");
			if(!pos_ok(np))
				continue;
			auto ang = [&](const char *k, double row){
				const json::Value &a = d.state.get(k);
				return a.is_number() && std::isfinite(a.as_number()) ? a.as_number() : row;
			};
			const std::array<double, 7> key = {{std::floor(d.t * 1000),
					np.at(0u).as_number(), np.at(1u).as_number() + 0.5, np.at(2u).as_number(),
					ang("yaw", e.yaw), ang("pitch", e.pitch), ang("roll", e.roll)}};
			double flat = -1; // (along the ground)
			if(!d.keys.empty()){
				const std::array<double, 7> &l = d.keys.back();
				const double s = (key[0] - l[0]) / 1000;
				if(s > 0){
					const double dx = key[1] - l[1], dy = key[2] - l[2], dz = key[3] - l[3];
					flat = std::sqrt(dx * dx + dz * dz) / s;
					double dy2 = key[4] - l[4];
					dy2 -= 360 * std::floor((dy2 + 180) / 360);
					d.speed = std::sqrt(dx * dx + dy * dy + dz * dz) / s;
					d.turn = std::fabs(dy2) / s;
				}
			}
			// [KIT_AIRSHIPS] a ship's speed along the ground as it changes by half
			// a metre a second
			if(!d.parts.empty() && flat >= 0 && std::fabs(flat - d.logged_speed) >= 0.5){
				d.logged_speed = flat;
				log_i(MODULE, "[KIT_AIRSHIPS] entity %s flies at %.2f m/s",
						cs(itos(e.id)), flat);
			}
			d.keys.push_back(key);
			while(d.keys.size() > 2 && d.keys[1][0] < (now - TRACK_KEEP) * 1000)
				d.keys.pop_front();
		}
		return spent;
	}

	// A drive under a moving free object (d.deck): its world the deck's boxes in its
	// parent's frame, nothing else (simplified: the world's voxels and other objects
	// are not met on a deck)
	void deck_snapshot(ss_ &o, const Drive &d, const Entity &e, const double pos[3],
			double r, double h, double reach)
	{
		o += "{x0=0,y0=0,z0=0,nx=0,ny=0,nz=0,cells=\"\",classes={},looks={},t=";
		lua_lit(json::Value(motion_t()), o);
		o += ",turned={";
		auto fi = m_free_objects.find(d.deck);
		if(fi != m_free_objects.end()){
			AtRest rest(m_at_rest);
			double od[3], op[3];
			Turn qd, qp;
			world_of(m_entities[d.deck], od, &qd);
			frame_of(e.parent, op, qp);
			double l[3] = {od[0] - op[0], od[1] - op[1], od[2] - op[2]};
			qp.inverse().apply(l);
			double a, b, c;
			(qp.inverse() * qd).angles(a, b, c);
			// The vehicle in the deck's frame, for the boxes near it
			double vl[3] = {pos[0] - l[0], pos[1] - l[1], pos[2] - l[2]};
			(qp.inverse() * qd).inverse().apply(vl);
			const double m = r + reach + 2;
			ss_ list;
			const sv_<float> &bx = m_free_boxes[fi->second.boxes];
			for(size_t i = 0; i + 6 <= bx.size(); i += 6){
				if(vl[0] + m < bx[i] || vl[0] - m > bx[i + 3] || vl[1] + h + m < bx[i + 1] ||
						vl[1] - m > bx[i + 4] || vl[2] + m < bx[i + 2] || vl[2] - m > bx[i + 5])
					continue;
				for(size_t q = 0; q < 6; q++){
					lua_lit(json::Value((double)bx[i + q]), list);
					list += ',';
				}
			}
			if(!list.empty()){
				o += "{";
				for(double x : {l[0], l[1], l[2], a, b, c}){
					lua_lit(json::Value(x), o);
					o += ',';
				}
				o += "{"+list+"},"+itos(d.deck)+"},";
			}
		}
		o += "}";
		tracks_lit(o, d.scene);
		o += "}";
	}

	// "kit:track": "<id> <gen> <t> <x> <y> <z> <yaw> <pitch> <roll> ...;..." the keys a
	// peer in the drive's scene has not had (a new gen: all of them, from the first)
	void send_tracks()
	{
		for(auto &p : m_peers){
			if(!p.second.player)
				continue;
			auto &sent = m_track_sent[p.first];
			ss_ out;
			char buf[48];
			for(auto &dp : m_drives){
				const Drive &d = dp.second;
				if(d.scene != p.second.scene || d.keys.empty())
					continue;
				auto &s = sent[dp.first];
				const bool fresh = s.first != d.gen;
				if(!fresh && s.second >= d.keys.back()[0])
					continue;
				if(!out.empty())
					out += ";";
				out += itos(dp.first)+" "+itos(d.gen);
				for(const auto &k : d.keys){
					if(!fresh && k[0] <= s.second)
						continue;
					for(int n = 0; n < 7; n++){
						snprintf(buf, sizeof buf, " %.17g", k[n]);
						out += buf;
					}
				}
				s = std::make_pair(d.gen, d.keys.back()[0]);
			}
			if(out.empty())
				continue;
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(p.first, "kit:track", out);
			});
		}
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
			// [KIT_COMPONENTS] An edit took the seat or the movement off (or the
			// entity away) under its holder
			if(b.seat){
				auto si = m_entities.find(b.seat);
				if(si == m_entities.end() || !has_seat(si->second))
					unseat(bp.first, b);
			}
			// An edit changed the movement or its parameters: put again where
			// it is, so the client steps on with the same
			ss_ type;
			json::Value params;
			const uint64_t ride = b.ride;
			body_movement(b, type, params, pi->second.scene);
			const bool changed = params.stringify() != b.params.stringify();
			if(type != b.type || ride != b.ride || (changed && !b.ride)){
				if(type == b.type && !type.empty()){
					const json::Value &g = params.get("gravity");
					log_i(MODULE, "%s's movement %s changed: gravity %s",
							cs(pi->second.name), cs(type), cs(g.is_number() ?
							std::to_string(g.as_number()) : ss_("-")));
				}
				const json::Value st = b.state.deepcopy();
				put_body(bp.first, b, 0, 0, 0, 0, &st);
			} else if(changed){
				// [KIT_VEHICLE_MOVEMENTS] a rider's vehicle's parameters (c:set_param
				// while driving): it predicts nothing, so no put (that unseats)
				b.params = params;
			}
			if(b.type.empty())
				continue;
			// [KIT_VEHICLE_MOVEMENTS] A rider steps nothing: its inputs are the
			// vehicle's, it is where its seat is
			if(b.ride){
				if(b.inputs.empty())
					continue;
				auto di = m_drives.find(b.ride);
				if(di != m_drives.end()){
					ss_ in = b.inputs.back().second;
					// (its own time off: each step of the drive has its own)
					const size_t tp = in.find(",t=");
					if(tp != ss_::npos)
						in = in.substr(0, tp)+"}";
					// [KIT_SHIP] a press anywhere in the batch is the batch's (a
					// gun's trigger tapped between two ticks)
					const size_t jp = in.find(",jump=0,");
					for(auto &q : b.inputs)
						if(jp != ss_::npos && q.second.find(",jump=1,") != ss_::npos){
							in[jp + 6] = '1';
							break;
						}
					di->second.input = in;
				}
				b.ack = b.inputs.back().first;
				b.inputs.clear();
				ride_moved(bp.first, b);
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(bp.first, "kit:body", "{\"ack\":"+itos(b.ack)+
							",\"s\":"+b.state_json+"}");
				});
				continue;
			}
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
						settle_json(b)+",\"s\":"+b.state_json+"}");
			});
		}
		return spent;
	}

	// Possession: a seat (a type with `seat = true` and a movement) used
	// takes the player's controls until they leave it ("kit:exit")
	// What a use reaches on it: an on_use, or a seat ([KIT] stage 4h)
	bool use_kind(const Entity &e, const Instance &in)
	{
		const Type &ty = m_types[in.type];
		return ty.usable && (ty.handlers.count("on_use") || (m_host.controls &&
				ty.decl.get("seat").is_true() && vehicle_of(e)));
	}

	// [KIT_COMPONENTS] Whether a player can hold it: a seat and a movement on it
	// ([KIT_VEHICLE_MOVEMENTS] or on what it is under)
	bool has_seat(const Entity &e)
	{
		for(const Instance &in : e.comps)
			if(m_types[in.type].decl.get("seat").is_true())
				return vehicle_of(e) != nullptr;
		return false;
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
		if(rg && owns(peer, rg->state.get("owners"), re))
			return true;
		*why = "Locked: its owners' only";
		return false;
	}

	void seat(size_t peer, uint64_t id)
	{
		Body &b = m_bodies[peer];
		// [KIT_VEHICLE_MOVEMENTS] one holder a vehicle, whichever of its seats
		Entity *ve = vehicle_of(id);
		if(!ve)
			return;
		Entity &e = *ve;
		for(auto &o : m_bodies)
			if(o.second.seat && vehicle_of(o.second.seat) == ve && o.first != peer){
				log_i(MODULE, "Entity %s: %s is in it already", cs(itos(id)),
						cs(m_peers[o.first].name));
				return;
			}
		if(b.seat)
			unseat(peer, b, false);
		if(!m_seat_home.count(e.id) && !m_drives.count(e.id))
			m_seat_home[e.id] = home_of(e);
		b.seat = id;
		double w[3];
		Turn wq;
		world_of(m_drives.count(e.id) ? m_entities[id] : e, w, &wq);
		json::Value st = json::object(), pos = json::array();
		pos.append(w[0]);
		pos.append(w[1] - 0.5);
		pos.append(w[2]);
		st.set("pos", pos);
		st.set("yaw", wq.yaw());
		log_i(MODULE, "%s takes the seat of entity %s", cs(m_peers[peer].name),
				cs(itos(id)));
		put_body(peer, b, 0, 0, 0, 0, &st);
	}

	// Out of the seat: beside it (its right, its left, behind, on it),
	// standing; put: the client told
	void unseat(size_t peer, Body &b, bool put = true)
	{
		const uint64_t id = b.seat, ride = b.ride;
		b.seat = 0;
		b.ride = 0;
		log_i(MODULE, "%s leaves the seat of entity %s", cs(m_peers[peer].name),
				cs(itos(id)));
		// The drive's input let go
		auto di = m_drives.find(ride);
		if(di != m_drives.end())
			di->second.input.clear();
		Entity *ve = vehicle_of(id);
		if(!put || !ve)
			return;
		// [KIT_VEHICLE_MOVEMENTS] Off a steered one's seat: a metre to the seat's
		// right, standing in the frame of the free object it is on
		if(ride){
			const Entity &se = m_entities[id];
			uint64_t deck = 0;
			for(auto pi = m_entities.find(id); pi != m_entities.end() && !deck;
					pi = m_entities.find(pi->second.parent))
				if(m_free_objects.count(pi->first))
					deck = pi->first;
			double w[3];
			Turn q;
			world_of(se, w, &q);
			const double a = q.yaw() * 3.14159265358979323846 / 180;
			w[0] += std::cos(a);
			w[2] -= std::sin(a);
			json::Value st = json::object(), pos = json::array();
			pos.append(w[0]);
			pos.append(w[1] - 0.45);
			pos.append(w[2]);
			st.set("pos", pos);
			st.set("yaw", 0.0);
			if(deck){
				// The feet in the deck's frame: the deck's top under them
				double o[3], l[3];
				Turn dq;
				world_of(m_entities[deck], o, &dq);
				for(int k = 0; k < 3; k++)
					l[k] = w[k] - o[k];
				dq.inverse().apply(l);
				l[1] -= 0.45;
				json::Value at = json::array(), vel = json::array();
				for(int k = 0; k < 3; k++){
					at.append(l[k]);
					vel.append(0.0);
				}
				st.set("frame", (int64_t)deck);
				st.set("at", at);
				st.set("vel", vel);
				st.set("ground", true);
			}
			put_body(peer, b, 0, 0, 0, 0, &st);
			return;
		}
		const Entity &e = *ve;
		double w[3];
		Turn wq;
		world_of(e, w, &wq);
		const double a = wq.yaw() * 3.14159265358979323846 / 180;
		const Instance *mv = movement_on(e);
		const double d = (mv ? num(body_decl(mv->type), "r", 1, 0.05, 8) : 1) + 1;
		double x = w[0] + std::cos(a) * d, z = w[2] - std::sin(a) * d;
		const double y = std::floor(w[1] + 0.5);
		put_body(peer, b, x, y, z);
	}

	// [KIT_SESSIONS_1] in the sender's session
	void on_exit(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_exit_u(packet);
	}

	void on_exit_u(const network::Packet &packet)
	{
		auto pi = m_peers.find(packet.sender);
		if(pi == m_peers.end() || !act_allowed(pi->second))
			return;
		auto bi = m_bodies.find(packet.sender);
		if(bi == m_bodies.end() || !bi->second.seat)
			return;
		unseat(packet.sender, bi->second);
	}

	// Stop: everyone out of the seats, the vehicles (and what c:move moved,
	// [KIT_CTF]) back
	void seats_home()
	{
		for(auto &bp : m_bodies){
			if(bp.second.seat)
				unseat(bp.first, bp.second);
			// [KIT_CTF] c:speed's factors gone
			bp.second.speed = 1;
		}
		for(auto &h : m_seat_home){
			auto it = m_entities.find(h.first);
			if(it == m_entities.end())
				continue;
			Entity &e = it->second;
			home_put(e, h.second);
			place_nodes(e.id);
		}
		m_seat_home.clear();
		m_play_params.clear();
		// [KIT_CARRY_ATTACH] nothing on a player past Stop
		sv_<uint64_t> on;
		for(auto &a : m_attached)
			on.push_back(a.first);
		for(uint64_t id : on)
			detach(id, "Stop");
	}

	// ---- Clients act

	// [KIT_USE_FLOOD] A placed peer's act (kit:action, kit:use, kit:exit)
	// taken from their allowance: ACTION_RATE a second, ACTION_BURST at
	// once; false: dropped, unsaid
	static bool act_allowed(Peer &pe)
	{
		const int64_t now = interface::os::time_us();
		pe.action_tokens = std::min(ACTION_BURST, pe.action_tokens +
				(now - pe.action_at) * 1e-6 * ACTION_RATE);
		pe.action_at = now;
		if(pe.action_tokens < 1)
			return false;
		pe.action_tokens -= 1;
		return true;
	}

	// [KIT_CTF] A dead player waiting to respawn acts on nothing: refused
	// (logged as other refusals)
	bool waiting_refused(Peer &pe, const char *what)
	{
		if(!player_waiting(pe.player))
			return false;
		if(log_refusal(pe, ss_("waiting to respawn: ")+what))
			log_i(MODULE, "%s's %s refused: waiting to respawn", cs(pe.name),
					what);
		return true;
	}

	// Whether a refusal is logged: not the same one again within a second
	static bool log_refusal(Peer &pe, const ss_ &why)
	{
		const int64_t now = interface::os::time_us();
		if(why == pe.refused_why && now - pe.refused_at < 1000000)
			return false;
		pe.refused_why = why;
		pe.refused_at = now;
		return true;
	}

	// [KIT_SESSIONS_1] in the sender's session
	void on_use(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_use_u(packet);
	}

	void on_use_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const ss_ data = packet.data.substr(0, 32);
		char *end = nullptr;
		const uint64_t id = strtoull(data.c_str(), &end, 10);
		// Unplaced or not hosted: dropped unsaid (nobody to bound it by)
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second))
			return;
		if(waiting_refused(pi->second, "use"))
			return;
		auto refuse = [&](const ss_ &why){
			auto p = m_peers.find(peer);
			if(p != m_peers.end() && log_refusal(p->second, why))
				log_i(MODULE, "A use of entity %s by peer %zu refused: %s",
						cs(data), peer, cs(why));
		};
		if(!m_session.running)
			return refuse("the server is Stopped");
		if(data.empty() || !end || *end)
			return refuse("not an entity's id");
		auto it = m_entities.find(id);
		if(it == m_entities.end() || !it->second.has_pos)
			return refuse("no such object");
		Entity &e = it->second;
		ss_ scene;
		scene_of(e, &scene);
		if(scene != pi->second.scene)
			return refuse("in another scene");
		// [KIT_NESTING] where it is in the world
		double w[3], d2 = 0;
		world_of(e, w);
		for(int k = 0; k < 3; k++)
			d2 += (w[k] - pi->second.pos[k]) * (w[k] - pi->second.pos[k]);
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
			if(!use_kind(e2, in))
				continue;
			if(!may_use(peer, e2, in, &why))
				continue;
			// [KIT_FLAG_CLICK_RANGE] Not what they carry: its place is
			// up to ATTACH_US behind them
			const double ur = use_range_of(in);
			auto ca = m_attached.find(id);
			if(ur >= 0 && d2 > ur * ur && (ca == m_attached.end() ||
					ca->second.player != player_id(by))){
				why = "Too far away";
				continue;
			}
			// [KIT] stage 4h: a seat taken
			if(!seated && m_host.controls && m_types[in.type].decl.get("seat").
					is_true() && vehicle_of(e2) && m_bodies[peer].put &&
					m_bodies[peer].seat != id){
				seat(peer, id);
				seated = any = true;
			}
			// [KIT_INVENTORY_PLAY] a chest opens on the user's screen
			if(!m_types[in.type].decl.get("container").is_undefined())
				chest_opened(peer, id);
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
		// [KIT_GOALS] a use, as a world event: kit/goal's "use" is done by it
		json::Value ev = json::object();
		ev.set("kind", ss_("use"));
		ev.set("entity", (int64_t)id);
		ev.set("player", (int64_t)player_id(by));
		fire_event(scene, ev, by);
	}

	// ---- [KIT_TOOLS_1] (stage 7c's first part) Tools and weapons: item
	// types, the hands slot (kit/equipment), the hit through health's
	// modifiers (kit/health), melee, digging by a voxel's material group and
	// level, wear (api.h)

	// The item types by name: Kit's (types/<name>.item.json, the presets)
	// and the builders' (the rows "item:<author>/<name>")
	sm_<ss_, json::Value> m_item_types;
	// [KIT_SOUNDS] the project's sounds by name, {params, author, name,
	// version, package}
	sm_<ss_, json::Value> m_sounds;
	// Each placed peer's last hit or item use (the game's clock) and the
	// dig under way: its cell and when it started
	struct ToolUse
	{
		bool used = false;
		int64_t used_us = 0;
		bool digging = false;
		int dig[3] = {0, 0, 0};
		int64_t dig_us = 0;
		// [KIT_TOOLS_2] a charge's draw begun ("kit:draw") and when; a
		// reload under way: the item and when its round is in
		bool drawing = false;
		int64_t draw_us = 0;
		ss_ reloading;
		int64_t reload_us = 0;
	};
	std::map<size_t, ToolUse> m_tool_use;
	// [KIT_TOOLS_2] A projectile in flight: the server's own (no entity
	// row: not saved, gone at Stop), stepped each tick on the game's clock
	struct Projectile
	{
		uint64_t id = 0;
		size_t peer = 0; // whose shot (gone with them)
		ss_ item;
		json::Value sheet;
		double pos[3] = {0, 0, 0}, vel[3] = {0, 0, 0};
		double damage = 0;
		int64_t at_us = 0, until_us = 0;
		// [KIT_AIRSHIPS] the ship it was fired from (a turret's): not hit by it
		uint64_t ship = 0;
	};
	std::vector<Projectile> m_projectiles;
	uint64_t m_next_shot = 1;
	// The items each player had as a run last listed them (a replacing
	// provider's: Kit reads its own kit/inventory's state)
	sm_<ss_, json::Value> m_items_seen;
	// modify_hit's answer (run()'s fx.hit)
	json::Value m_hit_ret;
	// [KIT_HIT_FEEDBACK] the item of the player's hit being applied (a
	// death's kill message names it)
	ss_ m_striking;

	// An item: letters, digits and _, or an item type's "<author>/<name>"
	static bool item_ok(const ss_ &s)
	{
		const size_t sl = s.find('/');
		if(sl == ss_::npos)
			return name_ok(s);
		return name_ok(s.substr(0, sl)) && name_ok(s.substr(sl + 1));
	}

	// An item type's sheet from what a builder or a file gives (j), over
	// base (a preset's; null: the defaults): each field checked, those it
	// does not know left out. One flat sheet for every use kind; 7c-2's
	// ranged, loading and look go beside these
	static bool item_sheet(const json::Value &j, const json::Value &base,
			json::Value &out, ss_ &why)
	{
		struct Field { const char *name; double lo, hi, def; bool whole; };
		static const Field NUMBERS[] = {
			{"stack", 1, 999, 1, true},
			// timing: a cooldown (s); auto repeats while held; burst
			// (7c-2's ranged) shots a press; charge (s, a bow's draw)
			{"cooldown", 0, 60, 0.5, false},
			{"burst", 1, 20, 3, true},
			{"charge", 0, 10, 0, false},
			// damage: the amount, a critical (melee: falling) multiplier,
			// the share lost at the full reach, knockback (m/s)
			{"damage", 0, 1000000, 1, false},
			{"crit", 1, 100, 1, false},
			{"falloff", 0, 1, 0, false},
			{"knockback", 0, 50, 0, false},
			// melee: how far it hits (m, from the eye to the body)
			{"reach", 0.5, 16, 3, false},
			// digging: the level it drops voxels of (dig: speed a group)
			{"level", 0, 15, 0, true},
			// wear: uses until it breaks (0: never), a use's cost by action
			{"uses", 0, 1000000, 0, true},
			{"wear_dig", 0, 1000, 1, true},
			{"wear_hit", 0, 1000, 1, true},
			{"wear_shot", 0, 1000, 1, true},
			// [KIT_TOOLS_2] ranged: a projectile's speed (m/s), gravity
			// (m/s/s) and lifetime (s); the spread (degrees off the aim,
			// each pellet), pellets a shot, range (m: a hitscan's reach,
			// its falloff's full distance), recoil (degrees the view kicks
			// up, the client's)
			{"speed", 1, 500, 40, false},
			{"gravity", 0, 100, 9.81, false},
			{"lifetime", 0.1, 30, 5, false},
			{"spread", 0, 45, 0, false},
			{"pellets", 1, 32, 1, true},
			{"range", 1, 1000, 50, false},
			{"recoil", 0, 45, 0, false},
			// loading: rounds a magazine (0: none, a shot takes an ammo
			// item if it has one), the reload's time (s; one round's, one
			// at a time)
			{"magazine", 0, 1000, 0, true},
			{"reload", 0, 60, 1, false},
		};
		auto field = [&](const char *k) -> const json::Value& {
			const json::Value &v = j.get(k);
			return v.is_undefined() ? base.get(k) : v;
		};
		out = json::object();
		for(const Field &f : NUMBERS){
			const json::Value &v = field(f.name);
			if(v.is_undefined() || v.is_null()){
				out.set(f.name, f.whole ? json::Value((int64_t)f.def) :
						json::Value(f.def));
				continue;
			}
			const double x = v.is_number() ? v.as_number() : NAN;
			if(!std::isfinite(x) || x < f.lo || x > f.hi ||
					(f.whole && x != std::floor(x))){
				why = ss_(f.name)+": "+(f.whole ? "a whole number " :
						"a number ")+dtos(f.lo)+"..."+dtos(f.hi);
				return false;
			}
			out.set(f.name, f.whole ? json::Value((int64_t)x) :
					json::Value(x));
		}
		auto choice = [&](const char *k, const char *def,
				std::initializer_list<const char*> cs) -> bool {
			const json::Value &v = field(k);
			const ss_ s = v.is_string() ? v.as_string() : def;
			for(const char *c : cs)
				if(s == c){
					out.set(k, s);
					return true;
				}
			why = ss_(k)+": one of";
			for(const char *c : cs)
				why += ss_(" ")+c;
			return false;
		};
		// The use kind: none (an item to carry: a key, a material), melee
		// (it hits), use (on_item hooks only: a wand); 7c-2 adds ranged
		// [KIT_TOOLS_2] ranged: it shoots, hitscan (a ray from the eye) or
		// a projectile; a reload fills the whole magazine or one round
		if(!choice("use", "none", {"none", "melee", "use", "ranged"}) ||
				!choice("mode", "single", {"single", "auto", "burst"}) ||
				!choice("shot", "hitscan", {"hitscan", "projectile"}) ||
				!choice("reload_mode", "whole", {"whole", "one"}))
			return false;
		auto text = [&](const char *k, const char *def,
				bool (*ok)(const ss_&)) -> bool {
			const json::Value &v = field(k);
			const ss_ s = v.is_string() ? v.as_string() : def;
			if(!s.empty() && !ok(s)){
				why = ss_(k)+": \""+s.substr(0, 64)+"\" is no name";
				return false;
			}
			out.set(k, s);
			return true;
		};
		// The damage's type ("normal": armour, stage 9, tells them apart),
		// the item that mends it, the preset it was made from; the icon (a
		// texture's name, checked by the caller) and the look (7c-2: a
		// prefab, its parts or voxels; kept, not drawn yet)
		// [KIT_SOUNDS] its sounds by action, a project's sound's name each
		for(const char *k : {"sound_swing", "sound_shot", "sound_hit",
				"sound_reload", "sound_break"})
			if(!text(k, "", item_ok))
				return false;
		if(!text("damage_type", "normal", name_ok) ||
				!text("repair", "", item_ok) || !text("preset", "", item_ok) ||
				!text("look", "", item_ok) || !text("ammo", "", item_ok))
			return false;
		// [KIT_TOOLS_2] its colour ("#rrggbb": a shot's, a splat's, the
		// default look's) and the grip: where the look is in first person
		// (metres right, up and ahead of the eye)
		const json::Value &col = field("color");
		const ss_ cs_ = col.is_string() ? col.as_string() : "#c0c0c0";
		if(cs_.size() != 7 || cs_[0] != '#' ||
				cs_.find_first_not_of("0123456789abcdefABCDEF", 1) != ss_::npos){
			why = "color: \"#rrggbb\"";
			return false;
		}
		out.set("color", cs_);
		const json::Value &gr = field("grip");
		json::Value grip = json::array();
		for(unsigned i = 0; i < 3; i++){
			const double def[3] = {0.13, -0.11, 0.22};
			const double x = gr.is_array() && gr.at(i).is_number() ?
					gr.at(i).as_number() : gr.is_undefined() || gr.is_null() ?
					def[i] : NAN;
			if(!(x >= -1 && x <= 1)){
				why = "grip: [right, up, ahead], each -1...1 (m)";
				return false;
			}
			grip.append(x);
		}
		out.set("grip", grip);
		const json::Value &ic = field("icon");
		out.set("icon", ic.is_string() ? ic.as_string().substr(0, 128) : ss_());
		if(out.get("damage_type").as_string().empty())
			out.set("damage_type", ss_("normal"));
		// Digging: its speed a material group, {group: speed} or the text
		// "stone 4, wood 2"; a hand's is 1 for every group
		json::Value dig = json::object();
		const json::Value &d = field("dig");
		if(d.is_string()){
			std::istringstream is(d.as_string());
			ss_ part;
			while(std::getline(is, part, ',')){
				std::istringstream ps(part);
				ss_ g;
				double sp = NAN;
				if(!(ps >> g))
					continue;
				if(!(ps >> sp)){
					why = "dig: \"group speed, ...\" (\""+part.substr(0, 32)+
							"\")";
					return false;
				}
				dig.set(g, sp);
			}
		} else if(d.is_object()){
			dig = d.deepcopy();
		} else if(!d.is_undefined() && !d.is_null()){
			why = "dig: {group: speed} or \"group speed, ...\"";
			return false;
		}
		size_t n = 0;
		for(json::Iterator it(dig); it; ++it){
			const double sp = (*it).is_number() ? (*it).as_number() : NAN;
			if(!name_ok(it.key()) || it.key().size() > 32 || !(sp >= 0.01) ||
					sp > 1000 || ++n > 16){
				why = "dig: up to 16 groups (letters, digits and _), each "
						"a speed 0.01...1000";
				return false;
			}
		}
		out.set("dig", dig);
		return true;
	}

	static ss_ dtos(double v)
	{
		char b[32];
		snprintf(b, sizeof b, "%g", v);
		return b;
	}

	// Kit's item types (the presets: kit/sword, kit/pickaxe) and the
	// save's builders'
	void load_items()
	{
		m_item_types.clear();
		const ss_ dir = author_path("kit");
		for(const auto &n : interface::fs::list_directory(dir)){
			const size_t dot = n.name.rfind(".item.json");
			if(n.is_directory || dot == ss_::npos || dot + 10 != n.name.size())
				continue;
			const ss_ name = "kit/"+n.name.substr(0, dot);
			json::Value sheet;
			ss_ why;
			const json::Value j = json::load_string(read_file(dir+"/"+
					n.name).c_str());
			if(!j.is_object() || !item_sheet(j, json::object(), sheet, why)){
				log_w(MODULE, "Item type %s: %s", cs(name), why.empty() ?
						"not a JSON object" : cs(why));
				continue;
			}
			sheet.set("version", j.get("version").is_number() ?
					j.get("version") : json::Value((int64_t)1));
			m_item_types[name] = sheet;
		}
		for(const ss_ &k : m_store->list("item:")){
			ss_ row;
			if(m_store->get(k, row))
				m_item_types[k.substr(5)] = json::load_string(row.c_str());
		}
		std::set<ss_> sorted;
		for(auto &it : m_item_types)
			sorted.insert(it.first);
		ss_ names;
		for(const ss_ &n : sorted)
			names += (names.empty() ? "" : " ")+n;
		log_i(MODULE, "Item types: %s", names.empty() ? "none" : cs(names));
	}

	// [KIT_TOOLS_2] An item type's look, a prefab of parts and voxels (4i's)
	// as the client draws it in first person: {parts: [{pos, size,
	// rotation, color, shape, material, voxel}], voxels: the prefab's};
	// null: no such prefab (the default look is drawn).
	// simplified: a member's place adds its parents' places, not their
	// turns; a part's own rotation is kept
	json::Value look_data(const ss_ &name)
	{
		const json::Value *pf = prefab(name);
		if(!pf)
			return json::null();
		json::Value out = json::object(), parts = json::array();
		std::map<int64_t, std::array<double, 3>> at;
		const json::Value &es = pf->get("entities");
		for(unsigned i = 0; es.is_array() && i < es.size(); i++){
			const json::Value &e = es.at(i);
			std::array<double, 3> p = {0, 0, 0};
			auto pa = at.find(json::jint(e, "parent", 0));
			for(unsigned k = 0; k < 3; k++)
				p[k] = (pa == at.end() ? 0 : pa->second[k]) +
						(e.get("pos").at(k).is_number() ?
						e.get("pos").at(k).as_number() : 0);
			at[json::jint(e, "id", 0)] = p;
			const json::Value &cs_ = e.get("components");
			for(unsigned c = 0; cs_.is_array() && c < cs_.size(); c++){
				if(jstr(cs_.at(c), "type") != "kit/part")
					continue;
				json::Value part = cs_.at(c).get("params").is_object() ?
						cs_.at(c).get("params").deepcopy() : json::object();
				part.set("pos", point(p.data()));
				parts.append(part);
			}
		}
		out.set("parts", parts);
		if(pf->get("voxels").is_object())
			out.set("voxels", pf->get("voxels"));
		return out;
	}

	// "kit:item_types" {name: sheet}: to a peer of this session, or every
	// one of every session (-1)
	void send_item_types(int64_t peer)
	{
		json::Value all = json::object();
		for(auto &it : m_item_types){
			// [KIT_TOOLS_2] its look's prefab with it, as drawn
			json::Value sheet = it.second.deepcopy();
			const ss_ look = jstr(sheet, "look");
			if(!look.empty())
				sheet.set("look_data", look_data(look));
			all.set(it.first, sheet);
		}
		const ss_ data = all.stringify();
		auto send = [&]{
			network::access(m_server, [&](network::Interface *inetwork){
				for(auto &p : m_peers)
					if(peer < 0 || (size_t)peer == p.first)
						inetwork->send(p.first, "kit:item_types", data);
			});
		};
		if(peer < 0)
			each_session(send);
		else
			send();
	}

	// [KIT_ITEMS_TAB] {"op": "item_delete", "name"}: a builder's item type
	// gone (the project's own: Kit's and a package's are not); what holds
	// it keeps the name, an item of no type
	void delete_item(const Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		if(active_session())
			return refuse("in a draft: the default round's");
		const ss_ name = jstr(j, "name");
		ss_ row;
		if(!item_ok(name) || !m_store->get("item:"+name, row) ||
				!jstr(json::load_string(row.c_str()), "package").empty())
			return refuse("no item type of the project's own named "+
					name.substr(0, 129));
		m_store->remove("item:"+name);
		m_item_types.erase(name);
		log_i(MODULE, "%s deleted item type %s", cs(p.name), cs(name));
		send_item_types(-1);
	}

	// [KIT_ITEMS_TAB] {"op": "give", "item"}: one of an item to the
	// builder's own player in play, as a dig's drop goes (kit/equipment's
	// on_tool: the slots, a full inventory's rule)
	void give_me(const Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const ss_ item = jstr(j, "item");
		if(!item_ok(item))
			return refuse("give: an item's name");
		if(!m_session.running || !p.player || !equipment_of(p.player))
			return refuse("give: in play, to a player with kit/equipment");
		tool_run(p.player, "", 0, 0, item);
		log_i(MODULE, "%s gives themselves %s", cs(p.name), cs(item));
	}

	// {"op": "item", "name": n, "preset": an item type, and the sheet's
	// fields}: the builder's item type "<their name>/<n>" (the row
	// "item:<their name>/<n>", its version counted up by each), the
	// preset's sheet under the fields given
	void make_item(const Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const ss_ short_name = jstr(j, "name");
		const ss_ author = builder_author(p.name);
		if(!name_ok(short_name))
			return refuse("name: letters, digits and _");
		if(author.empty())
			return refuse("a builder's item types are under their name, "
					"and it is \""+p.name.substr(0, 64)+"\"");
		const ss_ name = author+"/"+short_name;
		const ss_ preset = jstr(j, "preset");
		json::Value base = json::object();
		if(!preset.empty()){
			auto pt = m_item_types.find(preset);
			if(pt == m_item_types.end())
				return refuse("preset: no item type "+preset.substr(0, 129));
			base = pt->second.deepcopy();
			base.set("preset", preset);
		}
		json::Value row;
		ss_ why;
		if(!item_sheet(j, base, row, why))
			return refuse(why);
		const ss_ icon = jstr(row, "icon");
		if(!icon.empty() && !texture_choices().count(icon))
			return refuse("icon: no voxel or upload has "+icon);
		auto old = m_item_types.find(name);
		if(old == m_item_types.end() && m_item_types.size() >= MAX_ITEM_TYPES)
			return refuse("the save has "+itos(MAX_ITEM_TYPES)+" item types");
		const int64_t version = old == m_item_types.end() ? 1 :
				json::jint(old->second, "version", 1) + 1;
		row.set("format", ss_("kit_item"));
		row.set("author", author);
		row.set("name", short_name);
		row.set("version", version);
		m_store->set("item:"+name, row.stringify());
		m_item_types[name] = row;
		log_i(MODULE, "%s made item type %s version %s: %s", cs(p.name),
				cs(name), cs(itos(version)), cs(row.stringify()));
		send_item_types(-1);
	}

	// ---- [KIT_SOUNDS] The project's sounds: named blip sounds (blip1's
	// compact form, extensions/blip: data, not audio), Kit's own
	// (sounds.json: kit/click...) and the builders' (rows
	// "sound:<author>/<name>", a package's too), to every session's peers
	// as "kit:sounds" {name: {params, author, version}}; a trigger plays one
	// by name, "kit:sound" {name, at: [x, y, z] | null} to the peers in its
	// scene

	static bool sound_params_ok(const ss_ &s)
	{
		if(s.size() < 7 || s.size() > MAX_SOUND || s.compare(0, 6, "blip1:"))
			return false;
		for(size_t i = 6; i < s.size(); i++)
			if(!isalnum((unsigned char)s[i]) && !strchr("-_+", s[i]))
				return false;
		return true;
	}

	void load_sounds()
	{
		m_sounds.clear();
		const json::Value own = json::load_string(read_file(
				m_server->get_module_path(MODULE)+"/sounds.json").c_str());
		for(json::Iterator it(own.get("sounds")); own.get("sounds").
				is_object() && it; ++it){
			json::Value r = json::object();
			r.set("params", jstr(*it, "params"));
			r.set("author", ss_("kit"));
			r.set("name", it.key());
			r.set("version", (int64_t)1);
			if(sound_params_ok(jstr(r, "params")) && name_ok(it.key()))
				m_sounds["kit/"+it.key()] = r;
			else
				log_w(MODULE, "Kit's sound %s: not blip1 params", cs(it.key()));
		}
		for(const ss_ &k : m_store->list("sound:")){
			ss_ row;
			if(m_store->get(k, row))
				m_sounds[k.substr(6)] = json::load_string(row.c_str());
		}
		log_i(MODULE, "Sounds: %zu", m_sounds.size());
	}

	// "kit:sounds" to a peer of this session, or every one of every
	// session (-1)
	void send_sounds(int64_t peer)
	{
		json::Value all = json::object();
		for(auto &it : m_sounds)
			all.set(it.first, it.second);
		const ss_ data = all.stringify();
		auto send = [&]{
			network::access(m_server, [&](network::Interface *inetwork){
				for(auto &p : m_peers)
					if(peer < 0 || (size_t)peer == p.first)
						inetwork->send(p.first, "kit:sounds", data);
			});
		};
		if(peer < 0)
			each_session(send);
		else
			send();
	}

	// {"op": "sound", "name": n, "params": "blip1:..."}: a builder's sound
	// made ("<their name>/<n>") or one of the project's changed (n its
	// whole name, a builder's or a package's not; Kit's are copied, not
	// changed); {"op": "sound_delete", "name": whole name}
	void make_sound(const Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		ss_ name = jstr(j, "name");
		const ss_ params = jstr(j, "params");
		if(!sound_params_ok(params))
			return refuse("params: blip1's compact form, \"blip1:...\", "
					"at most "+itos(MAX_SOUND)+" characters");
		auto old = m_sounds.find(name);
		if(old == m_sounds.end()){
			const ss_ author = builder_author(p.name);
			if(!name_ok(name))
				return refuse("name: letters, digits and _ (or a sound's "
						"whole name)");
			if(author.empty())
				return refuse("a builder's sounds are under their name, and "
						"it is \""+p.name.substr(0, 64)+"\"");
			name = author+"/"+name;
			old = m_sounds.find(name);
		}
		if(old != m_sounds.end() && (jstr(old->second, "author") == "kit" ||
				!jstr(old->second, "package").empty()))
			return refuse(name+" is "+(jstr(old->second, "author") == "kit" ?
					ss_("Kit's") : "a package's")+": copy it as new");
		if(old == m_sounds.end() && m_sounds.size() >= MAX_SOUNDS)
			return refuse("the save has "+itos(MAX_SOUNDS)+" sounds");
		json::Value row = json::object();
		row.set("params", params);
		row.set("author", name.substr(0, name.find('/')));
		row.set("name", name.substr(name.find('/') + 1));
		row.set("version", old == m_sounds.end() ? (int64_t)1 :
				json::jint(old->second, "version", 1) + 1);
		m_store->set("sound:"+name, row.stringify());
		m_sounds[name] = row;
		log_i(MODULE, "%s made sound %s version %s: %s", cs(p.name), cs(name),
				cs(itos(json::jint(row, "version", 1))), cs(params));
		send_sounds(-1);
	}

	void delete_sound(const Peer &p, const json::Value &j,
			std::function<void(const ss_&)> refuse)
	{
		const ss_ name = jstr(j, "name");
		auto it = m_sounds.find(name);
		if(it == m_sounds.end())
			return refuse("no sound "+name.substr(0, 129));
		if(jstr(it->second, "author") == "kit" ||
				!jstr(it->second, "package").empty())
			return refuse(name+" is "+(jstr(it->second, "author") == "kit" ?
					ss_("Kit's") : "a package's"));
		// simplified: what names it (a parameter, an item type) keeps the
		// name and plays nothing; made again under it, it plays again
		m_store->remove("sound:"+name);
		m_sounds.erase(it);
		log_i(MODULE, "%s deleted sound %s", cs(p.name), cs(name));
		send_sounds(-1);
	}

	// A sound played (its name; "" or one not here: nothing) for the peers
	// of this session in `scene` (null: in any): at a place (positional),
	// or at == null for each where they are; except a peer (0 none: its
	// client played it already). why: the trigger, for the log
	void play_sound(const ss_ &name, const ss_ *scene, const double *at,
			const ss_ &why, size_t except = 0)
	{
		if(name.empty())
			return;
		if(!m_sounds.count(name)){
			log_i(MODULE, "Sound %s (%s): no such sound", cs(name), cs(why));
			return;
		}
		json::Value j = json::object();
		j.set("name", name);
		j.set("at", at ? point(at) : json::null());
		const ss_ data = j.stringify();
		size_t n = 0;
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &o : m_peers)
				if((!scene || o.second.scene == *scene) && o.first != except){
					inetwork->send(o.first, "kit:sound", data);
					n++;
				}
		});
		char where[96] = "everywhere";
		if(at)
			snprintf(where, sizeof where, "at (%.1f,%.1f,%.1f)", at[0], at[1],
					at[2]);
		log_i(MODULE, "Sound %s (%s) %s to %zu peers", cs(name), cs(why),
				where, n);
	}

	// An item type's sound for an action ("swing", "shot", "hit",
	// "reload", "break"; its sheet's sound_<action>)
	ss_ item_sound(const ss_ &item, const char *action)
	{
		auto it = m_item_types.find(item);
		return it == m_item_types.end() ? ss_() :
				jstr(it->second, (ss_("sound_")+action).c_str());
	}

	// A peer's own place (its body's middle) and the item's sound there
	void play_item_sound(size_t peer, const ss_ &item, const char *action,
			bool except_them)
	{
		auto pi = m_peers.find(peer);
		if(pi == m_peers.end())
			return;
		play_sound(item_sound(item, action), &pi->second.scene,
				pi->second.pos, item+"'s "+action, except_them ? peer : 0);
	}

	// A player's equipment (kit/equipment on their entity): its instance
	// and index, null for none (or disabled)
	Instance* equipment_of(uint64_t player, size_t *comp = nullptr)
	{
		auto it = m_entities.find(player);
		if(it == m_entities.end())
			return nullptr;
		for(size_t i = 0; i < it->second.comps.size(); i++){
			Instance &in = it->second.comps[i];
			if(m_types[in.type].equipment && in.disabled.empty()){
				if(comp)
					*comp = i;
				return &in;
			}
		}
		return nullptr;
	}

	// What a player holds ("" a hand) and its sheet (null: no item type)
	ss_ hands_of(uint64_t player, const json::Value **sheet = nullptr)
	{
		const Instance *eq = equipment_of(player);
		const ss_ item = eq ? jstr(eq->state, "hands") : ss_();
		if(sheet){
			auto it = m_item_types.find(item);
			*sheet = it == m_item_types.end() ? nullptr : &it->second;
		}
		return item;
	}

	// Whether a player has an item (Kit's kit/inventory's state, the app's
	// list, or a replacing provider's as a run last listed it)
	bool has_item(const ss_ &who, const ss_ &item)
	{
		const json::Value *list = nullptr;
		if(app_items()){
			auto ai = m_app_items.find(who);
			list = ai == m_app_items.end() ? nullptr : &ai->second;
		} else if(provider()){
			auto si = m_items_seen.find(who);
			list = si == m_items_seen.end() ? nullptr : &si->second;
		} else {
			auto pl = m_players.find(who);
			const Instance *own = pl == m_players.end() ? nullptr :
					own_inventory(pl->second);
			list = own ? &own->state.get("items") : nullptr;
		}
		return list && list->get(item.c_str()).is_number() &&
				list->get(item.c_str()).as_number() >= 1;
	}

	// The hands emptied when what they held is gone from the list
	void check_hands(const ss_ &who, const json::Value &items)
	{
		auto pl = m_players.find(who);
		size_t comp = 0;
		Instance *eq = pl == m_players.end() ? nullptr :
				equipment_of(pl->second, &comp);
		const ss_ item = eq ? jstr(eq->state, "hands") : ss_();
		// [KIT_INVENTORY_PLAY] The hands hold a slot: what is in it now
		const int64_t slot = eq ? json::jint(eq->state, "slot", 0) : 0;
		if(eq && slot > 0 && own_slots()){
			const json::Value sl = slots_of(pl->second);
			const ss_ now = slot_item(sl.at((unsigned)slot - 1));
			if(now == item)
				return;
			set_hands(pl->second, comp, now);
			log_i(MODULE, "%s's slot %s holds %s: in hand", cs(who),
					cs(itos(slot)), now.empty() ? "nothing" : cs(now));
			if(!now.empty())
				tool_run(pl->second, now, 0, 0, "");
			return;
		}
		if(item.empty() || (items.get(item.c_str()).is_number() &&
				items.get(item.c_str()).as_number() >= 1))
			return;
		set_hands(pl->second, comp, "");
		log_i(MODULE, "%s has no %s: the hands empty", cs(who), cs(item));
	}

	// slot: the inventory's slot they hold (-1: as it was)
	void set_hands(uint64_t player, size_t comp, const ss_ &item,
			int64_t slot = -1)
	{
		Entity &e = m_entities[player];
		e.comps[comp].state.set("hands", item);
		m_runtime_dirty = true;
		replicate_state(e, comp, "hands");
		if(slot >= 0){
			e.comps[comp].state.set("slot", slot);
			replicate_state(e, comp, "slot");
		}
	}

	// "kit:hold" <item>: a placed peer's hands take one of their items
	// ("": a hand)
	// [KIT_SESSIONS_1] in the sender's session
	void on_hold(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_hold_u(packet);
	}

	void on_hold_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const ss_ item = packet.data.substr(0, 130);
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second))
			return;
		if(waiting_refused(pi->second, "hold"))
			return;
		Peer &p = pi->second;
		size_t comp = 0;
		if(!p.player || !equipment_of(p.player, &comp))
			return;
		// [KIT_INVENTORY_PLAY] "#<n>": the slot n (from 1; empty: a hand);
		// an item: its first slot
		if(own_slots()){
			const json::Value sl = slots_of(p.player);
			int64_t slot = 0;
			if(!item.empty() && item[0] == '#'){
				slot = atoll(item.c_str() + 1);
				if(slot < 1 || slot > 256)
					return;
			} else {
				for(unsigned i = 0; i < sl.size() && !item.empty(); i++)
					if(slot_item(sl.at(i)) == item){
						slot = i + 1;
						break;
					}
			}
			const ss_ now = slot ? slot_item(sl.at((unsigned)slot - 1)) : "";
			if(!item.empty() && item[0] != '#' && !slot){
				if(log_refusal(p, "hold "+item))
					log_i(MODULE, "%s may not hold %s: not one of their items",
							cs(p.name), cs(item.substr(0, 64)));
				return;
			}
			set_hands(p.player, comp, now, slot);
			log_i(MODULE, "%s holds %s (slot %s)", cs(p.name), now.empty() ?
					"nothing" : cs(now), cs(itos(slot)));
			send_slots(p.name);
			tool_run(p.player, now, 0, 0, "");
			return;
		}
		if(!item.empty() && (!item_ok(item) || !has_item(p.name, item))){
			if(log_refusal(p, "hold "+item))
				log_i(MODULE, "%s may not hold %s: not one of their items",
						cs(p.name), cs(item.substr(0, 64)));
			return;
		}
		set_hands(p.player, comp, item);
		log_i(MODULE, "%s holds %s", cs(p.name), item.empty() ? "nothing" :
				cs(item));
		// [KIT_TOOLS_2] its instance's wear and rounds to the client
		tool_run(p.player, item, 0, 0, "");
	}

	// The cell a world point is in
	static pv::Vector3DInt32 cell_of(const double w[3])
	{
		return pv::Vector3DInt32((int)std::floor(w[0] + 0.5),
				(int)std::floor(w[1] + 0.5), (int)std::floor(w[2] + 0.5));
	}

	// Whether nothing solid of the scene's voxels is between two points
	// (each tenth of a metre)
	bool in_sight(main_context::SceneReference scene, const double a[3],
			const double b[3])
	{
		bool clear = true;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *w = ivw->get_instance(scene);
			if(!w)
				return;
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			const auto &fmt = reg->get_format();
			const double d = std::sqrt((b[0] - a[0]) * (b[0] - a[0]) +
					(b[1] - a[1]) * (b[1] - a[1]) + (b[2] - a[2]) * (b[2] - a[2]));
			const int n = std::min(400, (int)std::ceil(d / 0.1));
			for(int i = 1; i < n && clear; i++){
				const double t = (double)i / n, p[3] = {a[0] + (b[0] - a[0]) * t,
						a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t};
				const uint32_t id = (uint32_t)fmt.id.get(w->get_voxel(
						cell_of(p), true).data);
				const interface::VoxelDefinition *def = reg->get(id);
				clear = !def || !def->physically_solid;
			}
		});
		return clear;
	}

	// [KIT_CTF] Whether a player is alive (c.players' alive): placed, not
	// waiting to respawn and their health's hp above 0 where they have one
	bool player_alive(const Entity &pe)
	{
		if(!pe.has_pos)
			return false;
		for(const Instance &in : pe.comps)
			if(m_types[in.type].health){
				const json::Value &hp = in.state.get("hp");
				return !in.state.get("waiting").is_true() &&
						(!hp.is_number() || hp.as_number() > 0);
			}
		return true;
	}

	// The placed peer of a player's entity in this round (0: none)
	size_t peer_of_player(uint64_t player)
	{
		for(auto &p : m_peers)
			if(p.second.player == player)
				return p.first;
		return 0;
	}

	// Whether Kit's rules let a hit by a placed peer reach an entity, and
	// why not: the game's peaceful (kit/game_rules: players take no
	// damage), the region holding the target -- its pvp rule for the
	// attacker against a player, its damage rule for the player hit (an
	// entity: for the attacker) -- and a team's friendly fire (kit/team's
	// friendly_fire, off by default: its members do not hurt each other)
	bool hit_allowed(size_t peer, const Entity &t, ss_ &why)
	{
		double w[3];
		world_of(t, w);
		const pv::Vector3DInt32 c = cell_of(w);
		if(t.kind != "player")
			return allows(peer, "damage", c.getX(), c.getY(), c.getZ(), &why);
		const Instance *gr = root_instance("kit/game_rules");
		if(gr && gr->params.get("peaceful").is_true()){
			why = "Peaceful: players take no damage";
			return false;
		}
		if(!allows(peer, "pvp", c.getX(), c.getY(), c.getZ(), &why))
			return false;
		const size_t tp = peer_of_player(t.id);
		if(tp && !allows(tp, "damage", c.getX(), c.getY(), c.getZ(), &why))
			return false;
		return !spared(m_peers[peer].player, t.id, why);
	}

	// Whether a team spares a player from another's hit: both its members
	// and its friendly_fire off (kit/team's default)
	bool spared(uint64_t me, uint64_t target, ss_ &why)
	{
		for(auto &e : m_entities)
			for(const Instance &in : e.second.comps)
				if(m_types[in.type].team && in_team(me, e.first) &&
						in_team(target, e.first) &&
						!in.params.get("friendly_fire").is_true()){
					why = "Friendly fire is off in team "+jstr(in.params, "name");
					return true;
				}
		return false;
	}

	// ---- [KIT_PARTICLES] World events and effects (api.h)

	// A world event ({kind, pos, ...}) to on_event(c, ev, by) of the
	// instances asking for its kind (their `events` parameter) in the scene
	// and with no place on the root. Queued: it runs in this tick
	void fire_event(const ss_ &scene, const json::Value &ev, const ss_ &by)
	{
		const ss_ kind = jstr(ev, "kind");
		for(auto &e : m_entities){
			ss_ es;
			if(!(e.second.parent == 1 && !e.second.has_pos) &&
					!(e.second.has_pos && e.second.kind != "player" &&
					scene_of(e.second, &es) && es == scene))
				continue;
			for(size_t i = 0; i < e.second.comps.size(); i++){
				const Instance &in = e.second.comps[i];
				const Type &t = m_types[in.type];
				if(t.events.empty() || !t.handlers.count("on_event") ||
						jstr(in.params, t.events.c_str()) != kind)
					continue;
				Run r;
				r.entity = e.first;
				r.comp = i;
				r.handler = "on_event";
				r.by = by;
				r.args.append(ev);
				r.args.append(by);
				queue_run(r);
			}
		}
	}

	// A player's dig or place, as world events
	void voxel_event(size_t peer, const char *kind, int x, int y, int z,
			const ss_ &voxel)
	{
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || pi->second.editing ||
				!m_session.running)
			return;
		const double c[3] = {(double)x, (double)y, (double)z};
		json::Value ev = json::object();
		ev.set("kind", kind);
		ev.set("pos", point(c));
		json::Value vs = json::array();
		vs.append(world::material_of(voxel));
		ev.set("voxels", vs);
		ev.set("player", (int64_t)pi->second.player);
		fire_event(pi->second.scene, ev, pi->second.player ?
				"player:"+itos(pi->second.player) : ss_("app"));
	}

	// A hit that came to something (apply_hit), as a world event: where it
	// landed, how much of the target's health (share, 0...1), and with a
	// hit.from the way its spray goes (dir): towards it, or with hit.away
	// away from it
	void hit_event(uint64_t target, const json::Value &hit, double amount,
			const ss_ &by)
	{
		auto it = m_entities.find(target);
		if(it == m_entities.end())
			return;
		double w[3];
		ss_ scene;
		const size_t peer = it->second.kind == "player" ?
				peer_of_player(target) : 0;
		if(peer){
			const Peer &p = m_peers[peer];
			w[0] = p.pos[0], w[1] = p.pos[1] + 0.4, w[2] = p.pos[2];
			scene = p.scene;
		} else if(it->second.has_pos && scene_of(it->second, &scene)){
			world_of(it->second, w);
		} else {
			return;
		}
		json::Value ev = json::object();
		ev.set("kind", "hit");
		ev.set("pos", point(w));
		ev.set("amount", amount);
		const double max = health_max(target);
		ev.set("share", max > 0 ? std::min(1.0, amount / max) : 1.0);
		ev.set("type", jstr(hit, "type"));
		if(peer)
			ev.set("player", (int64_t)target);
		const json::Value &from = hit.get("from");
		if(from.size() == 3 && from.at(0u).is_number() &&
				from.at(1u).is_number() && from.at(2u).is_number()){
			double d[3], l = 0;
			for(unsigned k = 0; k < 3; k++){
				d[k] = from.at(k).as_number() - w[k];
				if(hit.get("away").is_true())
					d[k] = -d[k];
				l += d[k] * d[k];
			}
			l = std::sqrt(l);
			if(l > 1e-3){
				for(double &v : d)
					v /= l;
				ev.set("dir", point(d));
			}
			ev.set("from", from);
		}
		fire_event(scene, ev, by);
	}

	// c:event(kind): a type's own world event, not one of Kit's
	void event_fx(const Entity &e, const ss_ &ctype, const json::Value &x,
			const ss_ &by)
	{
		const ss_ kind = jstr_at(x, 0);
		ss_ scene;
		if(!name_ok(kind) || kind == "dig" || kind == "place" ||
				kind == "hit" || kind == "blast" || kind == "respawn" ||
				!scene_of(e, &scene)){
			log_w(MODULE, "Entity %s's %s: event %s refused",
					cs(itos(e.id)), cs(ctype), cs(kind));
			return;
		}
		double w[3] = {0, 0, 0};
		if(e.has_pos)
			world_of(e, w);
		json::Value ev = json::object();
		ev.set("kind", kind);
		ev.set("pos", point(w));
		const uint64_t pid = player_id(by);
		if(pid)
			ev.set("player", (int64_t)pid);
		fire_event(scene, ev, by);
	}

	// c:effect{...}, its fields as kit/effect's parameters (api.h): each
	// clamped here, for it comes from a composition, and sent to the
	// players of the scene near enough; the arc to its player alone
	void effect_fx(const Entity &e, const ss_ &ctype, const json::Value &x)
	{
		const ss_ who = "Entity "+itos(e.id)+"'s "+ctype;
		const int64_t now = interface::os::time_us();
		m_effect_tokens = std::min(EFFECT_BURST, m_effect_tokens +
				(now - m_effect_at) * 1e-6 * EFFECT_RATE);
		m_effect_at = now;
		if(m_effect_tokens < 1){
			log_v(MODULE, "%s: effect refused: past %g bursts a second",
					cs(who), EFFECT_RATE);
			return;
		}
		m_effect_tokens -= 1;
		if(!x.is_object())
			return;
		auto num = [&](const char *k, double def, double lo, double hi){
			const json::Value &v = x.get(k);
			const double d = v.is_number() ? v.as_number() : def;
			return std::isfinite(d) ? std::max(lo, std::min(hi, d)) : def;
		};
		auto vec = [&](const char *k, double out[3], double lim){
			const json::Value &v = x.get(k);
			if(v.size() != 3)
				return false;
			for(unsigned i = 0; i < 3; i++){
				const json::Value &n = v.at(i);
				if(!n.is_number() || !std::isfinite(n.as_number()) ||
						std::fabs(n.as_number()) > lim)
					return false;
				out[i] = n.as_number();
			}
			return true;
		};
		auto color_ok = [](const ss_ &c){
			if(c.size() != 7 && c.size() != 9)
				return false;
			for(size_t i = 1; i < c.size(); i++)
				if(!isxdigit((unsigned char)c[i]))
					return false;
			return c[0] == '#';
		};
		// Where: an entity's (the clients follow its look), the point, its own
		double at[3], off[3] = {0, 0, 0};
		ss_ scene;
		const Entity *on = &e;
		const json::Value &ent = x.get("entity");
		if(ent.is_number() && ent.as_number() > 0){
			auto f = m_entities.find((uint64_t)ent.as_number());
			if(f == m_entities.end() || !f->second.has_pos)
				return;
			on = &f->second;
		}
		const bool in_scene = scene_of(*on, &scene) != nullptr ||
				!scene.empty();
		if(on != &e || !vec("at", at, MAX_COORD)){
			if(!on->has_pos){
				log_i(MODULE, "%s: effect: no place to be at", cs(who));
				return;
			}
			world_of(*on, at);
		}
		vec("offset", off, 16);
		for(int k = 0; k < 3; k++)
			at[k] += off[k];
		json::Value j = json::object();
		j.set("at", point(at));
		if(on != &e){
			j.set("entity", (int64_t)on->id);
			j.set("offset", point(off));
		}
		// The particles
		int count = (int)num("count", 0, 0, MAX_EFFECT_PARTICLES);
		ss_ shape = jstr(x, "shape", "square");
		if(shape != "square" && shape != "round" && shape != "ring" &&
				shape != "voxel")
			shape = "square";
		json::Value colors = json::array(), voxels = json::array();
		const json::Value &cl = x.get("colors");
		for(unsigned i = 0; i < cl.size() && i < MAX_EFFECT_KINDS; i++)
			if(cl.at(i).is_string() && color_ok(cl.at(i).as_string()))
				colors.append(cl.at(i));
		if(shape == "voxel"){
			const json::Value &vl = x.get("voxels");
			for(unsigned i = 0; i < vl.size() && i < MAX_EFFECT_KINDS; i++)
				if(vl.at(i).is_string() && material_named(vl.at(i).as_string()))
					voxels.append(vl.at(i));
			if(!voxels.size())
				count = 0;
		}
		if(count > 0){
			j.set("count", (int64_t)count);
			j.set("shape", shape);
			j.set("colors", colors);
			j.set("voxels", voxels);
			double dir[3] = {0, 1, 0};
			vec("dir", dir, 1e6);
			const double l = std::sqrt(dir[0] * dir[0] + dir[1] * dir[1] +
					dir[2] * dir[2]);
			if(l > 1e-6){
				for(double &v : dir)
					v /= l;
			} else {
				dir[0] = dir[2] = 0, dir[1] = 1;
			}
			j.set("dir", point(dir));
			j.set("spread", num("spread", 180, 0, 180));
			const double smin = num("speed_min", 1, 0, 60);
			j.set("speed_min", smin);
			j.set("speed_max", num("speed_max", smin, smin, 60));
			j.set("gravity", num("gravity", 0, -50, 50));
			j.set("drag", num("drag", 0, 0, 20));
			const double tmin = num("ttl_min", 1, 0.05, 10);
			j.set("ttl_min", tmin);
			j.set("ttl_max", num("ttl_max", tmin, tmin, 10));
			const double zmin = num("size_min", 0.1, 0.01, 8);
			j.set("size_min", zmin);
			j.set("size_max", num("size_max", zmin, zmin, 8));
			j.set("grow", num("grow", 0, -20, 100));
			j.set("fade", num("fade", 0.3, 0, 1));
			j.set("box", num("box", 0, 0, 16));
			j.set("spin", num("spin", 0, 0, 1440));
			j.set("land", x.get("land").is_true());
		}
		// The light, without a shadow ever
		const double ltime = num("light_time", 0, 0, 2);
		const ss_ lc = jstr(x, "light_color");
		if(ltime > 0 && color_ok(lc)){
			j.set("light_color", lc);
			j.set("light_time", ltime);
			j.set("light_range", num("light_range", 8, 0.5, 40));
			j.set("light_brightness", num("light_brightness", 2, 0, 8));
		}
		// The tint on a player's body, the arc on their screen
		const json::Value &pl = x.get("player");
		const uint64_t player = pl.is_number() && pl.as_number() > 0 ?
				(uint64_t)pl.as_number() : 0;
		const double ftime = num("flash_time", 0, 0, 2);
		const ss_ fc = jstr(x, "flash_color");
		if(player && ftime > 0 && color_ok(fc)){
			j.set("flash_player", (int64_t)player);
			j.set("flash_color", fc);
			j.set("flash_time", ftime);
		}
		const double atime = num("arc_time", 0, 0, 10);
		const ss_ ac = jstr(x, "arc_color");
		double from[3];
		if(player && atime > 0 && color_ok(ac) &&
				vec("arc_from", from, MAX_COORD)){
			const size_t ap = peer_of_player(player);
			if(ap){
				json::Value a = json::object();
				a.set("from", point(from));
				a.set("color", ac);
				a.set("time", atime);
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(ap, "kit:effect_arc", a.stringify());
				});
				log_v(MODULE, "%s: a hit's arc to player %s", cs(who),
						cs(itos(player)));
			}
		}
		if(j.get("count").is_undefined() &&
				j.get("light_color").is_undefined() &&
				j.get("flash_color").is_undefined())
			return;
		const ss_ data = j.stringify();
		size_t n = 0;
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &p : m_peers){
				if(in_scene && p.second.scene != scene)
					continue;
				const double dx = p.second.pos[0] - at[0], dy = p.second.pos[1] -
						at[1], dz = p.second.pos[2] - at[2];
				if(dx * dx + dy * dy + dz * dz >
						MAX_EFFECT_RANGE * MAX_EFFECT_RANGE)
					continue;
				inetwork->send(p.first, "kit:effect", data);
				n++;
			}
		});
		log_v(MODULE, "%s: an effect of %i %s at (%.1f,%.1f,%.1f) to %zu peers",
				cs(who), count, cs(shape), at[0], at[1], at[2], n);
	}

	// A hit on an entity: its components' modify_hit hooks in their order,
	// each given the hit ({amount, type, item, crit}) and returning it as
	// it goes on (nil: as it was; an amount of 0 ends it: armour, a
	// shield, an effect's resistance, stage 9's), then its health's on_hit.
	// What it came to (0: nothing)
	double apply_hit(uint64_t target, json::Value hit, const ss_ &by)
	{
		for(size_t i = 0; ; i++){
			auto it = m_entities.find(target);
			if(it == m_entities.end() || i >= it->second.comps.size())
				break;
			if(!m_types[it->second.comps[i].type].handlers.count("modify_hit"))
				continue;
			Run r;
			r.entity = target;
			r.comp = i;
			r.handler = "modify_hit";
			r.by = by;
			r.args.append(hit);
			r.args.append(by);
			m_hit_ret = json::Value();
			run(r);
			if(!m_hit_ret.is_object())
				continue;
			const json::Value &a = m_hit_ret.get("amount");
			if(a.is_number() && std::isfinite(a.as_number()))
				hit.set("amount", std::max(0.0, a.as_number()));
			const ss_ ty = jstr(m_hit_ret, "type");
			if(name_ok(ty))
				hit.set("type", ty);
		}
		const double amount = hit.get("amount").as_number();
		auto it = m_entities.find(target);
		if(it == m_entities.end())
			return 0;
		if(amount <= 0){
			log_i(MODULE, "A hit on entity %s by %s comes to nothing",
					cs(itos(target)), cs(by_text(by)));
			return 0;
		}
		for(size_t i = 0; i < it->second.comps.size(); i++){
			const Instance &in = it->second.comps[i];
			if(!m_types[in.type].health || !in.disabled.empty())
				continue;
			Run r;
			r.entity = target;
			r.comp = i;
			r.handler = "on_hit";
			r.by = by;
			r.args.append(hit);
			r.args.append(by);
			run(r);
			hit_event(target, hit, amount, by);
			return amount;
		}
		return 0;
	}

	// A player's entity back at their spawn (kit/health's c:respawn()):
	// their team's pad, else the last spawner of players in their scene,
	// else the app's default
	void respawn_player(uint64_t player)
	{
		const size_t peer = peer_of_player(player);
		if(!peer)
			return;
		// [KIT_INVENTORY_PLAY] the inventory at a death, the kits at a spawn
		player_died(player);
		revive(player);
	}

	// ---- [KIT_CTF] Death and respawn, hurts and blasts

	// A player's health: the first enabled instance of a `health` type on
	// their entity (nullptr: none)
	Instance *health_of(uint64_t player, size_t *comp = nullptr)
	{
		auto it = m_entities.find(player);
		if(it == m_entities.end())
			return nullptr;
		for(size_t i = 0; i < it->second.comps.size(); i++){
			Instance &in = it->second.comps[i];
			if(m_types[in.type].health && in.disabled.empty()){
				if(comp)
					*comp = i;
				return &in;
			}
		}
		return nullptr;
	}

	// A player's health state set by Kit (its "waiting", its "hp")
	void set_health(uint64_t player, const ss_ &key, const json::Value &v)
	{
		size_t comp = 0;
		Instance *h = health_of(player, &comp);
		if(!h)
			return;
		h->state.set(key, v);
		m_runtime_dirty = true;
		if(m_types[h->type].shared.count(key))
			replicate_state(m_entities[player], comp, key);
	}

	// Whether a player is dead and waiting to respawn (kit/game_rules'
	// respawn "on_signal"): their health's state "waiting"
	bool player_waiting(uint64_t player)
	{
		const Instance *h = player ? health_of(player) : nullptr;
		return h && h->state.get("waiting").is_true();
	}

	// The most health a player has (their health's max)
	double health_max(uint64_t player)
	{
		const Instance *h = health_of(player);
		if(!h)
			return 0;
		const json::Value &m = h->state.get("max").is_number() ?
				h->state.get("max") : h->params.get("max");
		return m.is_number() ? m.as_number() : 0;
	}

	// A player back from a death: not waiting, their health at its max, at
	// their spawn (their team's pad...), through the kits
	void revive(uint64_t player)
	{
		set_health(player, "waiting", false);
		const double max = health_max(player);
		if(max > 0)
			set_health(player, "hp", max);
		const size_t peer = peer_of_player(player);
		if(peer)
			respawn_at(player, peer);
		give_kits(player, true);
	}

	// A player's death (their health's c:died(by, type)): on_died(c,
	// player, by, type) of every instance in their scene, on the root and
	// on their entity; their inventory by on_death; then by kit/game_rules'
	// respawn: "at_once" back at their spawn, "on_signal" waiting (no
	// actions, the body still) until a c:respawn_waiting() (game_rules'
	// input "respawn")
	void player_death(uint64_t player, const ss_ &by, const ss_ &type)
	{
		auto pe = m_entities.find(player);
		if(pe == m_entities.end() || player_waiting(player))
			return;
		const size_t peer = peer_of_player(player);
		const ss_ scene = peer ? m_peers[peer].scene : ss_();
		for(auto &e : m_entities){
			ss_ es;
			const bool here = e.first == player || (e.second.parent == 1 &&
					!e.second.has_pos) || (!scene.empty() &&
					e.second.kind != "player" &&
					scene_of(e.second, &es) && es == scene);
			if(!here)
				continue;
			for(size_t i = 0; i < e.second.comps.size(); i++){
				if(!m_types[e.second.comps[i].type].handlers.count("on_died"))
					continue;
				Run r;
				r.entity = e.first;
				r.comp = i;
				r.handler = "on_died";
				r.by = by;
				r.args.append((int64_t)player);
				r.args.append(by);
				r.args.append(type);
				queue_run(r);
			}
		}
		player_died(player);
		const uint64_t bid = player_id(by);
		const ss_ bn = bid && m_entities.count(bid) ? m_entities[bid].name : by;
		// [KIT_HIT_FEEDBACK] the kill message to the session's players: who
		// (a player, else none), whom, with what (the hit's item; none: its
		// damage type)
		{
			json::Value km = json::object();
			km.set("victim", pe->second.name);
			km.set("by", bid && bid != player ? bn : ss_());
			km.set("item", bid ? m_striking : ss_());
			km.set("type", type);
			const ss_ data = km.stringify();
			log_i(MODULE, "Kill message: %s", cs(data));
			network::access(m_server, [&](network::Interface *inetwork){
				for(auto &p : m_peers)
					inetwork->send(p.first, "kit:kill", data);
			});
		}
		if(jstr(game_rules(), "respawn") == "on_signal"){
			set_health(player, "waiting", true);
			log_i(MODULE, "%s died (%s by %s): waiting to respawn",
					cs(pe->second.name), cs(type), cs(bn));
			return;
		}
		log_i(MODULE, "%s died (%s by %s): respawns at once",
				cs(pe->second.name), cs(type), cs(bn));
		revive(player);
	}

	// c:respawn_waiting(): every player of the round waiting to respawn
	// back at their spawn; how many
	int respawn_waiting()
	{
		sv_<uint64_t> list;
		for(auto &e : m_entities)
			if(e.second.kind == "player" && player_waiting(e.first))
				list.push_back(e.first);
		for(uint64_t id : list)
			revive(id);
		return (int)list.size();
	}

	// Whether Kit lets a player take damage that is no player's hit (a
	// component's c:hurt, a blast), and why not: waiting to respawn, the
	// game's peaceful, the region at them (its damage rule for them)
	bool takes_damage(uint64_t player, ss_ &why)
	{
		if(player_waiting(player)){
			why = "waiting to respawn";
			return false;
		}
		const Instance *gr = root_instance("kit/game_rules");
		if(gr && gr->params.get("peaceful").is_true()){
			why = "Peaceful: players take no damage";
			return false;
		}
		const size_t tp = peer_of_player(player);
		if(!tp)
			return true;
		const pv::Vector3DInt32 c = cell_of(m_peers[tp].pos);
		return allows(tp, "damage", c.getX(), c.getY(), c.getZ(), &why);
	}

	// c:hurt(player, amount | {amount, fraction, type}): a player of the
	// round hurt by a component, through their modifiers and health as a
	// hit (type "hurt" by default); fraction: of their health's max
	void hurt(const Entity &e, const ss_ &ctype, const json::Value &h,
			const ss_ &by)
	{
		const json::Value &pv = h.at(0u);
		const uint64_t id = pv.is_number() && pv.as_number() > 0 ?
				(uint64_t)pv.as_number() : 0;
		auto it = m_entities.find(id);
		const ss_ who = "Entity "+itos(e.id)+"'s "+ctype;
		if(it == m_entities.end() || it->second.kind != "player"){
			log_w(MODULE, "%s: hurt: %s is no player", cs(who), cs(itos(id)));
			return;
		}
		const json::Value &a = h.at(1u);
		const json::Value &f = h.at(2u);
		double amount = a.is_number() ? a.as_number() : 0;
		if(f.is_number())
			amount = f.as_number() * health_max(id);
		if(!std::isfinite(amount) || amount <= 0)
			return;
		ss_ why;
		if(!takes_damage(id, why)){
			log_i(MODULE, "%s: hurt of %s refused: %s", cs(who),
					cs(it->second.name), cs(why));
			return;
		}
		json::Value hit = json::object();
		hit.set("amount", amount);
		hit.set("type", name_ok(jstr_at(h, 3)) ? jstr_at(h, 3) : ss_("hurt"));
		hit.set("item", ss_());
		hit.set("crit", false);
		log_i(MODULE, "%s hurts %s: %g %s", cs(who), cs(it->second.name),
				amount, cs(jstr(hit, "type")));
		apply_hit(id, hit, by);
	}

	// c:explode{at, radius, power, kill, hurt, share, friendly_fire, type}
	// ({x, y, z, radius, power, kill, hurt, share, friendly_fire, type}
	// here): a blast at a world point of the entity's scene. Each cell
	// within radius whose voxel's blast_resist is below the strength
	// there (power, falling to 0 at radius) goes to air, a game change,
	// but for those a region forbids digging to any player (its dig rule
	// not "all"); the players within kill are hit for their health's max,
	// those within hurt for share of it, as a hit of type `type` (Kit's
	// takes_damage; friendly_fire false: a team's friendly_fire spares the
	// members of the team of the player who set it off); on_blast(c, pos,
	// by) of the entities within radius. Kit's blasts a second
	// (EXPLODE_RATE) are limited
	void explode(const Entity &e, const ss_ &ctype, const json::Value &x,
			const ss_ &by)
	{
		const ss_ who = "Entity "+itos(e.id)+"'s "+ctype;
		const int64_t now = interface::os::time_us();
		m_blast_tokens = std::min(EXPLODE_BURST, m_blast_tokens +
				(now - m_blast_at) * 1e-6 * EXPLODE_RATE);
		m_blast_at = now;
		if(m_blast_tokens < 1){
			log_w(MODULE, "%s: explode refused: past %g blasts a second",
					cs(who), EXPLODE_RATE);
			add_log(e.id, "explode refused: past the blasts a second");
			return;
		}
		m_blast_tokens -= 1;
		ss_ scene;
		main_context::SceneReference sref = scene_of(e, &scene);
		if(!sref){
			log_w(MODULE, "%s: explode: not in a scene", cs(who));
			return;
		}
		double at[3];
		for(unsigned k = 0; k < 3; k++){
			const json::Value &v = x.at(k);
			at[k] = v.is_number() ? v.as_number() : 0;
			if(!std::isfinite(at[k]) || std::fabs(at[k]) > MAX_COORD)
				return;
		}
		auto arg = [&](unsigned i, double def, double hi){
			const json::Value &v = x.at(i);
			const double d = v.is_number() ? v.as_number() : def;
			return std::isfinite(d) ? std::max(0.0, std::min(hi, d)) : def;
		};
		const double radius = arg(3, 0, MAX_BLAST_RADIUS);
		const double power = arg(4, 1, 1000);
		const double kill = arg(5, radius, MAX_BLAST_REACH);
		const double hurt_r = arg(6, 0, MAX_BLAST_REACH);
		const double share = arg(7, 0.5, 1);
		const bool ff = !x.at(8u).is_false();
		const ss_ htype = name_ok(jstr_at(x, 9)) ? jstr_at(x, 9) :
				ss_("blast");
		// The cells: those in the sphere, by their voxel's resistance
		sv_<pv::Vector3DInt32> cells;
		// [KIT_PARTICLES] (the blast event's voxels: the commonest of those
		// it may carve)
		std::map<ss_, int> blown;
		const int r = (int)std::ceil(radius);
		const pv::Vector3DInt32 c0 = cell_of(at);
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *w = ivw->get_instance(sref);
			if(!w || radius <= 0)
				return;
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			const auto &fmt = reg->get_format();
			for(int dx = -r; dx <= r; dx++)
				for(int dy = -r; dy <= r; dy++)
					for(int dz = -r; dz <= r; dz++){
						const pv::Vector3DInt32 q = c0 +
								pv::Vector3DInt32(dx, dy, dz);
						const double ex = q.getX() - at[0], ey = q.getY() -
								at[1], ez = q.getZ() - at[2];
						const double d = std::sqrt(ex * ex + ey * ey + ez * ez);
						if(d > radius || !loaded(w, q))
							continue;
						const uint32_t id = (uint32_t)fmt.id.get(
								w->get_voxel(q, true).data);
						if(id <= 1)
							continue;
						const interface::VoxelDefinition *def = reg->get(id);
						if(!def)
							continue;
						auto mi = m_registered.find(world::material_of(
								def->name.block_name));
						const double resist = mi == m_registered.end() ? 0 :
								mi->second.blast_resist;
						if(resist > 0 && resist >= power * (1 - d / radius))
							continue;
						cells.push_back(q);
						blown[world::material_of(def->name.block_name)]++;
					}
		});
		size_t kept = 0, carved = 0;
		for(const pv::Vector3DInt32 &q : cells){
			const Entity *re = nullptr;
			const Instance *rg = region_at(scene, q.getX(), q.getY(),
					q.getZ(), &re);
			if(rg){
				const json::Value &rule = rg->state.get("rules").get("dig");
				const ss_ dig = rule.is_string() ? rule.as_string() :
						jstr(rg->params, "dig", "none");
				if(dig != "all"){
					kept++;
					continue;
				}
			}
			Write w;
			w.scene = sref;
			w.p = q;
			w.voxel = "air";
			w.by = by;
			w.origin = 'g';
			if(!set_voxel(w))
				m_pending_voxels.push_back(w);
			carved++;
		}
		log_i(MODULE, "%s explodes at (%.2f,%.2f,%.2f) radius %g power %g: "
				"%zu cells to air, %zu protected", cs(who), at[0], at[1], at[2],
				radius, power, carved, kept);
		// [KIT_AIRSHIPS] stage 4: the ships' voxels near it
		ships_blast(sref, at, radius, power, by, who);
		// [KIT_PARTICLES] The blast as a world event
		{
			sv_<std::pair<int, ss_>> most;
			for(auto &b : blown)
				most.push_back(std::make_pair(-b.second, b.first));
			std::sort(most.begin(), most.end());
			json::Value vs = json::array();
			for(size_t i = 0; i < most.size() && i < MAX_EFFECT_KINDS; i++)
				vs.append(most[i].second);
			json::Value ev = json::object();
			ev.set("kind", "blast");
			ev.set("pos", point(at));
			ev.set("radius", radius);
			ev.set("voxels", vs);
			ev.set("cells", (int64_t)carved);
			fire_event(scene, ev, by);
		}
		// The players: their bodies' middle (Peer::pos is the bottom + 0.5)
		const uint64_t me = player_id(by);
		sv_<std::pair<uint64_t, double>> hits;
		for(auto &p : m_peers){
			if(!p.second.player || p.second.scene != scene)
				continue;
			const double dx = p.second.pos[0] - at[0], dy = p.second.pos[1] +
					0.4 - at[1], dz = p.second.pos[2] - at[2];
			const double d = std::sqrt(dx * dx + dy * dy + dz * dz);
			const double f = d <= kill ? 1 : d <= hurt_r ? share : 0;
			if(f > 0)
				hits.push_back(std::make_pair(p.second.player, f));
		}
		for(auto &h : hits){
			auto pe = m_entities.find(h.first);
			if(pe == m_entities.end())
				continue;
			ss_ why;
			if(!takes_damage(h.first, why) || (!ff && me && me != h.first &&
					spared(me, h.first, why))){
				log_i(MODULE, "%s's blast spares %s: %s", cs(who),
						cs(pe->second.name), cs(why));
				continue;
			}
			json::Value hit = json::object();
			hit.set("amount", h.second * health_max(h.first));
			hit.set("type", htype);
			hit.set("item", ss_());
			hit.set("crit", false);
			hit.set("from", point(at));
			hit.set("away", true);
			log_i(MODULE, "%s's blast hits %s: %g %s", cs(who),
					cs(pe->second.name), hit.get("amount").as_number(),
					cs(htype));
			apply_hit(h.first, hit, by);
		}
		// on_blast(c, pos, by) of the entities within radius
		json::Value pos = json::array();
		for(int k = 0; k < 3; k++)
			pos.append(at[k]);
		size_t told = 0;
		for(auto &o : m_entities){
			ss_ os;
			if(o.first == e.id || !o.second.has_pos || o.second.kind ==
					"player" || !scene_of(o.second, &os) || os != scene)
				continue;
			double w[3];
			world_of(o.second, w);
			const double dx = w[0] - at[0], dy = w[1] - at[1],
					dz = w[2] - at[2];
			if(dx * dx + dy * dy + dz * dz > radius * radius)
				continue;
			for(size_t i = 0; i < o.second.comps.size() &&
					told < MAX_BLAST_TOLD; i++){
				if(!m_types[o.second.comps[i].type].handlers.count("on_blast"))
					continue;
				Run rr;
				rr.entity = o.first;
				rr.comp = i;
				rr.handler = "on_blast";
				rr.by = by;
				rr.args.append(pos);
				rr.args.append(by);
				queue_run(rr);
				told++;
			}
		}
	}

	void respawn_at(uint64_t player, size_t peer)
	{
		const ss_ scene = m_peers[peer].scene;
		const Entity *pad = nullptr, *spawner = nullptr;
		for(auto &e : m_entities){
			ss_ es;
			if(!e.second.has_pos || !scene_of(e.second, &es) || es != scene)
				continue;
			for(const Instance &in : e.second.comps){
				const Type &ty = m_types[in.type];
				if(ty.team && in_team(player, e.first))
					pad = &e.second;
				else if(ty.spawn && (ty.spawn_param.empty() ||
						in.params.get(ty.spawn_param).is_true()))
					spawner = &e.second;
			}
		}
		const Entity *at = pad ? pad : spawner;
		const ss_ who = m_peers[peer].name;
		if(!at){
			log_i(MODULE, "%s respawns at the app's spawn", cs(who));
			m_server->emit_event("kit:spawn_player", new SpawnPlayer(peer));
			return;
		}
		double w[3];
		Turn wq;
		world_of(*at, w, &wq);
		log_i(MODULE, "%s respawns at entity %s", cs(who), cs(itos(at->id)));
		to_scene(peer, "", w[0], w[1], w[2], wq.yaw());
		// [KIT_PARTICLES] simplified: not at the app's own spawn, above, whose
		// place the app decides later
		json::Value ev = json::object();
		ev.set("kind", "respawn");
		ev.set("pos", point(w));
		ev.set("player", (int64_t)player);
		fire_event(scene, ev, "player:"+itos(player));
	}

	// A player's knockback: their body's speed added to, away along the
	// hit's direction (dx, dz, level) and a little up, put again so the
	// client steps from it
	void knock(size_t peer, double dx, double dz, double k)
	{
		auto bi = m_bodies.find(peer);
		if(!m_host.controls || bi == m_bodies.end() || !bi->second.put ||
				bi->second.seat || k <= 0)
			return;
		Body &b = bi->second;
		json::Value st = b.state.deepcopy();
		json::Value v = json::array();
		const json::Value &ov = st.get("vel");
		const double add[3] = {dx * k, k * 0.4, dz * k};
		// [KIT_WALKER_FRAME] On an object its velocity is the object's: move.lua
		// takes the world's knock out of the frame
		const bool framed = st.get("frame").is_number();
		for(unsigned i = 0; i < 3; i++)
			v.append(framed ? add[i] : (ov.is_array() && ov.at(i).is_number() ?
					ov.at(i).as_number() : 0) + add[i]);
		st.set(framed ? "push" : "vel", v);
		st.set("ground", false);
		log_i(MODULE, "%s knocked back (%.2f, %.2f, %.2f)",
				cs(m_peers[peer].name), add[0], add[1], add[2]);
		put_body(peer, b, 0, 0, 0, 0, &st);
	}

	// The item's wear and a drop, by kit/equipment's on_tool on the
	// player's entity, their run: cost of the held item's uses (it breaks
	// at 0, one taken), drop added. [KIT_TOOLS_2] The wear is the held
	// instance's (the first of the item in the inventory); shot (an
	// object: {rounds, magazine, ammo}) takes a shot's rounds from its
	// magazine, or its ammo item where it has none. Run with only the
	// item it says the instance (equipment's "held", the client's). False:
	// refused (why: no rounds)
	bool tool_run(uint64_t player, const ss_ &item, int64_t cost,
			int64_t uses, const ss_ &drop, const json::Value &shot =
			json::Value(), ss_ *why = nullptr)
	{
		size_t comp = 0;
		if(!equipment_of(player, &comp) || (drop.empty() && item.empty()))
			return true;
		Run r;
		r.entity = player;
		r.comp = comp;
		r.handler = "on_tool";
		r.by = "player:"+itos(player);
		r.args.append(item);
		r.args.append(cost);
		r.args.append(uses);
		r.args.append(drop.empty() ? json::null() : json::Value(drop));
		r.args.append(shot.is_object() ? shot : json::null());
		run(r);
		if(m_ret.is_array() && m_ret.at(0u).is_boolean() &&
				!m_ret.at(0u).as_boolean()){
			if(why)
				*why = jstr_at(m_ret, 1);
			return false;
		}
		// [KIT_SOUNDS] equipment's on_tool says "broke" (true, "broke"):
		// the item's break sound where its holder is
		if(m_ret.is_array() && jstr_at(m_ret, 1) == "broke")
			play_item_sound(peer_of_player(player), item, "break", false);
		return true;
	}

	// The hooks for the rest ([KIT_TOOLS_1]): on_item(c, item, action,
	// target, by) of each instance in the player's scene, on the root and
	// on their entity, after what the item did -- "hit" (target the
	// entity), "dig" (the cell {x, y, z}) or "use" (a use kind "use"
	// item's click: the entity pointed at, 0 none)
	void item_hooks(size_t peer, const ss_ &item, const ss_ &action,
			const json::Value &target)
	{
		const Peer &p = m_peers[peer];
		const ss_ by = "player:"+itos(p.player);
		for(auto &e : m_entities){
			ss_ es;
			const bool here = e.first == p.player || (e.second.parent == 1 &&
					!e.second.has_pos) || (
					e.second.kind != "player" && scene_of(e.second, &es) &&
					es == p.scene);
			if(!here)
				continue;
			for(size_t i = 0; i < e.second.comps.size(); i++){
				if(!m_types[e.second.comps[i].type].handlers.count("on_item"))
					continue;
				Run r;
				r.entity = e.first;
				r.comp = i;
				r.handler = "on_item";
				r.by = by;
				r.args.append(item);
				r.args.append(action);
				r.args.append(target);
				r.args.append(by);
				queue_run(r);
			}
		}
	}

	// A placed peer's use of their hands now (a hit, an item's use): past
	// its cooldown (the game's clock), taken; false: refused, why
	bool cooled(size_t peer, const json::Value &sheet, ss_ &why)
	{
		ToolUse &tu = m_tool_use[peer];
		const int64_t now = now_us();
		const double cd = sheet.get("cooldown").as_number();
		if(tu.used && now >= tu.used_us && now - tu.used_us < cd * 1e6){
			why = "cooling down";
			return false;
		}
		tu.used = true;
		tu.used_us = now;
		return true;
	}

	// "kit:hit" <id>: a placed peer's melee hit with what they hold, on an
	// entity with health (a player, or one placed with kit/health). The
	// client has played the swing; the server decides: Running, out of
	// the tools, a melee item held, its cooldown, the target in the
	// peer's scene within its reach and in sight; then Kit's rules, the
	// item's wear, the target's modifiers and health, knockback, the hooks
	// [KIT_SESSIONS_1] in the sender's session
	void on_hit(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_hit_u(packet);
	}

	void on_hit_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const ss_ data = packet.data.substr(0, 32);
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second))
			return;
		if(waiting_refused(pi->second, "hit"))
			return;
		auto refuse = [&](const ss_ &why){
			auto p = m_peers.find(peer);
			if(p != m_peers.end() && log_refusal(p->second, why))
				log_i(MODULE, "A hit on entity %s by %s refused: %s", cs(data),
						cs(p->second.name), cs(why));
		};
		Peer &p = pi->second;
		if(!m_session.running)
			return refuse("the server is Stopped");
		if(p.editing)
			return refuse("in edit mode");
		char *end = nullptr;
		const uint64_t id = strtoull(data.c_str(), &end, 10);
		if(data.empty() || !end || *end)
			return refuse("not an entity's id");
		auto it = m_entities.find(id);
		if(it == m_entities.end() || !it->second.has_pos || id == p.player)
			return refuse("no such target");
		bool health = false;
		for(const Instance &in : it->second.comps)
			health = health || (m_types[in.type].health && in.disabled.empty());
		ss_ scene;
		scene_of(it->second, &scene);
		if(!health || scene != p.scene)
			return refuse(!health ? "it has no health" : "in another scene");
		const json::Value *sheet = nullptr;
		const ss_ item = hands_of(p.player, &sheet);
		if(!sheet || jstr(*sheet, "use") != "melee")
			return refuse(item.empty() ? "nothing in hand" : item+
					" is no melee item");
		if(!has_item(p.name, item))
			return refuse("no "+item+" in their inventory");
		// From the eye (the body's bottom and 1.55; Peer::pos is its
		// bottom and 0.5) to the target's middle (a player's body's: its
		// node's 0.35 up), less the body's half width
		const bool player = it->second.kind == "player";
		double t[3];
		world_of(it->second, t);
		if(player)
			t[1] += 0.35;
		const double eye[3] = {p.pos[0], p.pos[1] + 1.05, p.pos[2]};
		const double dx = t[0] - eye[0], dy = t[1] - eye[1], dz = t[2] - eye[2];
		const double d = std::max(0.0, std::sqrt(dx * dx + dy * dy + dz * dz) -
				(player ? 0.45 : 0.5));
		const double reach = sheet->get("reach").as_number();
		if(d > reach + 0.25)
			return refuse("out of reach ("+dtos(d)+" m)");
		if(!in_sight(scene_of(it->second), eye, t))
			return refuse("not in sight");
		ss_ why;
		if(!cooled(peer, *sheet, why))
			return refuse(why);
		if(!hit_allowed(peer, it->second, why)){
			tell(peer, why);
			return refuse(why);
		}
		// The hit: the amount less the falloff at its distance, a critical
		// one falling (the attacker's body going down in the air)
		double amount = sheet->get("damage").as_number() *
				(1 - sheet->get("falloff").as_number() * std::min(1.0, d / reach));
		bool crit = false;
		auto bi = m_bodies.find(peer);
		if(bi != m_bodies.end()){
			const json::Value &v = bi->second.state.get("vel");
			crit = !bi->second.state.get("ground").is_true() && v.is_array() &&
					v.at(1u).is_number() && v.at(1u).as_number() < -1;
		}
		// [KIT_SOUNDS] the swing's sound for the others (the client played
		// it; a swing at nothing is its client's alone)
		play_item_sound(peer, item, "swing", true);
		// The hit; then the item worn (it may break)
		const json::Value sh = sheet->deepcopy();
		const uint64_t me = p.player;
		strike(peer, id, item, sh, amount, crit, dx, dz, true);
		tool_run(me, item, json::jint(sh, "wear_hit", 1),
				json::jint(sh, "uses", 0), "");
	}

	// [KIT_TOOLS_2] A hit Kit's rules allow landing (a melee hit's, a
	// shot's): logged, the target's modifiers and health, knockback on a
	// player (away along dx, dz, or where the attacker looks when on
	// top), the hooks' "hit". allowed: Kit's rules asked already; else
	// asked here (refused: logged and told)
	void strike(size_t peer, uint64_t id, const ss_ &item,
			const json::Value &sheet, double amount, bool crit, double dx,
			double dz, bool allowed = false)
	{
		auto it = m_entities.find(id);
		auto pi = m_peers.find(peer);
		if(it == m_entities.end() || pi == m_peers.end())
			return;
		Peer &p = pi->second;
		ss_ why;
		if(!allowed && !hit_allowed(peer, it->second, why)){
			tell(peer, why);
			if(log_refusal(p, why))
				log_i(MODULE, "A hit on entity %s by %s refused: %s",
						cs(itos(id)), cs(p.name), cs(why));
			return;
		}
		if(crit)
			amount *= sheet.get("crit").as_number();
		json::Value hit = json::object();
		hit.set("amount", amount);
		hit.set("type", jstr(sheet, "damage_type", "normal"));
		hit.set("item", item);
		hit.set("crit", crit);
		// [KIT_PARTICLES] (their body's middle, as hit_event's target's)
		const double hf[3] = {p.pos[0], p.pos[1] + 0.4, p.pos[2]};
		hit.set("from", point(hf));
		const ss_ by = "player:"+itos(p.player);
		log_i(MODULE, "%s hits entity %s with %s: %g %s%s", cs(p.name),
				cs(itos(id)), cs(item), amount, cs(jstr(hit, "type")),
				crit ? " (critical)" : "");
		const double k = sheet.get("knockback").as_number();
		// [KIT_SOUNDS] the item's hit sound where the target is
		{
			double tw[3];
			world_of(it->second, tw);
			play_sound(jstr(sheet, "sound_hit"), &p.scene, tw, item+"'s hit");
		}
		// Not after a respawn (a put since)
		const size_t tp = it->second.kind == "player" ? peer_of_player(id) : 0;
		const int64_t puts = m_bodies.count(tp) ? m_bodies[tp].puts : -1;
		m_striking = item;
		const double came = apply_hit(id, hit, by);
		m_striking.clear();
		// [KIT_HIT_FEEDBACK] the attacker told it landed (the crosshair's
		// hit marker)
		if(came > 0 && m_peers.count(peer)){
			json::Value hl = json::object();
			hl.set("id", (int64_t)id);
			hl.set("amount", came);
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "kit:hit_landed", hl.stringify());
			});
		}
		if(came > 0 && tp && m_bodies.count(tp) && m_bodies[tp].puts == puts &&
				!player_waiting(id)){
			// Away from the attacker, or where they look when on top
			double kx = dx, kz = dz;
			double l = std::sqrt(kx * kx + kz * kz);
			if(l < 0.2){
				const double a = m_bodies.count(peer) ?
						m_bodies[peer].look_yaw * 0.017453292519943295 : 0;
				kx = std::sin(a), kz = std::cos(a), l = 1;
			}
			knock(tp, kx / l, kz / l, k);
		}
		if(m_peers.count(peer))
			item_hooks(peer, item, "hit", json::Value((int64_t)id));
	}

	// "kit:item" <id>: a placed peer's click with a use kind "use" item
	// (a wand): its cooldown, then the hooks' "use" with the entity
	// pointed at (0: none; one in their scene within use range)
	// [KIT_SESSIONS_1] in the sender's session
	void on_item_use(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_item_use_u(packet);
	}

	void on_item_use_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const ss_ data = packet.data.substr(0, 32);
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second))
			return;
		if(waiting_refused(pi->second, "item use"))
			return;
		Peer &p = pi->second;
		auto refuse = [&](const ss_ &why){
			if(log_refusal(p, why))
				log_i(MODULE, "An item's use by %s refused: %s", cs(p.name),
						cs(why));
		};
		if(!m_session.running || p.editing)
			return refuse(p.editing ? "in edit mode" : "the server is Stopped");
		const json::Value *sheet = nullptr;
		const ss_ item = hands_of(p.player, &sheet);
		if(!sheet || jstr(*sheet, "use") != "use" || !has_item(p.name, item))
			return refuse("no item of use kind \"use\" in hand");
		uint64_t id = strtoull(data.c_str(), nullptr, 10);
		auto it = m_entities.find(id);
		ss_ scene;
		double w[3], d2 = 0;
		if(id && (it == m_entities.end() || !it->second.has_pos ||
				!scene_of(it->second, &scene) || scene != p.scene))
			id = 0;
		if(id){
			world_of(it->second, w);
			for(int k = 0; k < 3; k++)
				d2 += (w[k] - p.pos[k]) * (w[k] - p.pos[k]);
			if(d2 > m_host.use_range * m_host.use_range)
				id = 0;
		}
		ss_ why;
		if(!cooled(peer, *sheet, why))
			return refuse(why);
		log_i(MODULE, "%s uses %s on entity %s", cs(p.name), cs(item),
				cs(itos(id)));
		item_hooks(peer, item, "use", json::Value((int64_t)id));
	}

	// ---- [KIT_TOOLS_2] (stage 7c's second part) Ranged items: "kit:draw"
	// (a charge's draw begun), "kit:shoot" {dir} (a shot along the aim
	// from the eye), "kit:reload" (api.h). The server decides as a melee
	// hit's: Running, out of the tools, a ranged item held, its cooldown,
	// a reload not under way, the rounds (kit/equipment's on_tool: the
	// held instance's magazine, or its ammo item where it has none); a
	// hitscan's pellets hit what a ray from the eye meets first within
	// its range (a solid voxel stops it), a projectile flies (speed,
	// gravity, lifetime) and hits what its path meets; each hit through
	// strike() (Kit's rules, the modifiers, health).
	// simplified: no lag compensation (a hit lands where the target is
	// now on the server); add it if arenas play badly

	// Where a ray (d a unit vector) from o meets a solid voxel of the
	// scene: its distance, max if none within it. Steps of a tenth of a
	// metre (2000 at most)
	double ray_wall(main_context::SceneReference scene, const double o[3],
			const double d[3], double max)
	{
		double hit = max;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *w = ivw->get_instance(scene);
			if(!w)
				return;
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			const auto &fmt = reg->get_format();
			const double step = std::max(0.1, max / 2000);
			for(double t = std::min(step, max); ; t = std::min(t + step, max)){
				const double p[3] = {o[0] + d[0] * t, o[1] + d[1] * t,
						o[2] + d[2] * t};
				const interface::VoxelDefinition *def = reg->get(
						(uint32_t)fmt.id.get(w->get_voxel(cell_of(p),
						true).data));
				if(def && def->physically_solid){
					hit = t;
					return;
				}
				if(t >= max)
					return;
			}
		});
		return hit;
	}

	// A ray's entry into a box (lo...hi) at t >= 0
	static bool ray_box(const double o[3], const double d[3],
			const double lo[3], const double hi[3], double &t)
	{
		double t0 = 0, t1 = 1e30;
		for(int k = 0; k < 3; k++){
			if(std::fabs(d[k]) < 1e-12){
				if(o[k] < lo[k] || o[k] > hi[k])
					return false;
				continue;
			}
			double a = (lo[k] - o[k]) / d[k], b = (hi[k] - o[k]) / d[k];
			if(a > b)
				std::swap(a, b);
			t0 = std::max(t0, a);
			t1 = std::min(t1, b);
			if(t0 > t1)
				return false;
		}
		t = t0;
		return true;
	}

	// The nearest entity with health in the scene along a ray (d a unit
	// vector) from o within max, skip not: a player's body a box 0.7 wide
	// from its node's 0.5 down to 1.2 up (its head the top 0.3), another's
	// a cell round it. 0 for none; t its distance, head a player's head
	uint64_t ray_target(const ss_ &scene, const double o[3],
			const double d[3], double max, uint64_t skip, double &t,
			bool &head)
	{
		uint64_t best = 0;
		for(auto &e : m_entities){
			const Entity &en = e.second;
			if(e.first == skip || !en.has_pos)
				continue;
			bool health = false;
			for(const Instance &in : en.comps)
				health = health || (m_types[in.type].health &&
						in.disabled.empty());
			ss_ es;
			if(!health || !scene_of(en, &es) || es != scene)
				continue;
			double w[3], et = 0;
			world_of(en, w);
			const bool player = en.kind == "player";
			const double r = player ? 0.35 : 0.5;
			const double lo[3] = {w[0] - r, w[1] - (player ? 0.5 : r),
					w[2] - r};
			const double hi[3] = {w[0] + r, w[1] + (player ? 1.2 : r),
					w[2] + r};
			if(!ray_box(o, d, lo, hi, et) || et > max)
				continue;
			best = e.first;
			max = t = et;
			head = player && o[1] + d[1] * et > w[1] + 0.9;
		}
		return best;
	}

	// The aim d turned at random within spread (radians) off it
	static void spread_dir(const double d[3], double spread, double out[3])
	{
		static std::mt19937 rng(std::random_device{}());
		std::uniform_real_distribution<double> u(0, 1);
		const double a = spread * std::sqrt(u(rng)), phi = 2 * 3.14159265358979323846 * u(rng);
		// Two unit vectors across d
		double x[3] = {0, 1, 0};
		if(std::fabs(d[1]) > 0.9)
			x[0] = 1, x[1] = 0;
		double v1[3] = {d[1] * x[2] - d[2] * x[1], d[2] * x[0] - d[0] * x[2],
				d[0] * x[1] - d[1] * x[0]};
		const double l = std::sqrt(v1[0] * v1[0] + v1[1] * v1[1] +
				v1[2] * v1[2]);
		for(double &c : v1)
			c /= l;
		const double v2[3] = {d[1] * v1[2] - d[2] * v1[1],
				d[2] * v1[0] - d[0] * v1[2], d[0] * v1[1] - d[1] * v1[0]};
		for(int k = 0; k < 3; k++)
			out[k] = d[k] * std::cos(a) + (v1[k] * std::cos(phi) +
					v2[k] * std::sin(phi)) * std::sin(a);
	}

	static json::Value point(const double p[3])
	{
		json::Value v = json::array();
		for(int k = 0; k < 3; k++)
			v.append(p[k]);
		return v;
	}

	// A packet to every peer in a scene (shots and projectiles drawn)
	void send_scene(const ss_ &scene, const char *name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &p : m_peers)
				if(p.second.scene == scene)
					inetwork->send(p.first, name, data);
		});
	}

	// The held ranged item of a placed peer able to use it: its sheet
	// (null: refused, why)
	const json::Value* ranged_held(size_t peer, ss_ &item, ss_ &why)
	{
		Peer &p = m_peers[peer];
		const json::Value *sheet = nullptr;
		item = hands_of(p.player, &sheet);
		if(!m_session.running)
			why = "the server is Stopped";
		else if(p.editing)
			why = "in edit mode";
		else if(!sheet || jstr(*sheet, "use") != "ranged")
			why = item.empty() ? "nothing in hand" : item+" is no ranged item";
		else if(!has_item(p.name, item))
			why = "no "+item+" in their inventory";
		else
			return sheet;
		return nullptr;
	}

	// [KIT_SESSIONS_1] each in the sender's session
	void on_draw(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		auto pi = m_peers.find(packet.sender);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second))
			return;
		if(waiting_refused(pi->second, "draw"))
			return;
		ToolUse &tu = m_tool_use[packet.sender];
		tu.drawing = true;
		tu.draw_us = now_us();
	}

	void on_shoot(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_shoot_u(packet);
	}

	void on_shoot_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second))
			return;
		if(waiting_refused(pi->second, "shoot"))
			return;
		const ss_ who = pi->second.name, scene = pi->second.scene;
		const uint64_t me = pi->second.player;
		auto refuse = [&](const ss_ &why){
			auto p = m_peers.find(peer);
			if(p != m_peers.end() && log_refusal(p->second, why))
				log_i(MODULE, "A shot by %s refused: %s", cs(who), cs(why));
		};
		ss_ item, why;
		const json::Value *sp = ranged_held(peer, item, why);
		if(!sp)
			return refuse(why);
		const json::Value sheet = sp->deepcopy();
		const json::Value j = json::load_string(packet.data.substr(0, 256).
				c_str());
		const json::Value &dv = j.get("dir");
		double dir[3], l = 0;
		for(unsigned k = 0; k < 3; k++){
			dir[k] = dv.is_array() && dv.at(k).is_number() ?
					dv.at(k).as_number() : NAN;
			l += dir[k] * dir[k];
		}
		l = std::sqrt(l);
		if(!std::isfinite(l) || l < 1e-6)
			return refuse("no aim");
		for(double &c : dir)
			c /= l;
		auto mi = m_entities.find(me);
		if(mi == m_entities.end() || !mi->second.has_pos)
			return refuse("not placed");
		ToolUse &tu = m_tool_use[peer];
		if(!tu.reloading.empty())
			return refuse("reloading");
		if(!cooled(peer, sheet, why))
			return refuse(why);
		// A charge: the share of its time drawn (a tenth at least) scales
		// the damage and a projectile's speed
		const double charge = sheet.get("charge").as_number();
		double f = 1;
		if(charge > 0)
			f = std::max(0.1, tu.drawing ? std::min(1.0,
					(now_us() - tu.draw_us) / (charge * 1e6)) : 0.0);
		tu.drawing = false;
		// The round: the held instance's magazine's, or an ammo item; the
		// wear
		json::Value shot = json::object();
		shot.set("rounds", (int64_t)1);
		shot.set("magazine", json::jint(sheet, "magazine", 0));
		shot.set("ammo", jstr(sheet, "ammo"));
		if(!tool_run(me, item, json::jint(sheet, "wear_shot", 1),
				json::jint(sheet, "uses", 0), "", shot, &why)){
			tell(peer, why);
			return refuse(why);
		}
		mi = m_entities.find(me);
		auto p2 = m_peers.find(peer);
		if(mi == m_entities.end() || p2 == m_peers.end())
			return;
		const main_context::SceneReference sref = scene_of(mi->second);
		// The eye: the body's bottom and 1.55 (Peer::pos its bottom and
		// 0.5)
		const double eye[3] = {p2->second.pos[0], p2->second.pos[1] + 1.05,
				p2->second.pos[2]};
		const bool projectile = jstr(sheet, "shot") == "projectile";
		const int64_t pellets = json::jint(sheet, "pellets", 1);
		const double spread = sheet.get("spread").as_number() * 3.14159265358979323846 / 180;
		const double damage = sheet.get("damage").as_number() * f;
		const double range = sheet.get("range").as_number();
		log_i(MODULE, "%s shoots %s: %s, %s pellet%s, charge %g, damage %g",
				cs(who), cs(item), projectile ? "a projectile" : "hitscan",
				cs(itos(pellets)), pellets > 1 ? "s" : "", f, damage);
		// [KIT_SOUNDS] its shot sound for the others (their client played it)
		play_item_sound(peer, item, "shot", true);
		json::Value ends = json::array();
		for(int64_t i = 0; i < pellets; i++){
			double d[3];
			spread_dir(dir, spread, d);
			if(projectile){
				if(!launch(peer, who, item, sheet, eye, d,
						sheet.get("speed").as_number() * f, damage, me, scene))
					break;
				continue;
			}
			const double wall = ray_wall(sref, eye, d, range);
			double t = 0;
			bool head = false;
			const uint64_t id = ray_target(scene, eye, d, wall, me, t, head);
			const double et = id ? t : wall;
			const double e[3] = {eye[0] + d[0] * et, eye[1] + d[1] * et,
					eye[2] + d[2] * et};
			json::Value end = point(e);
			end.append(id ? 2 : wall < range ? 1 : 0);
			ends.append(end);
			if(!id){
				log_i(MODULE, "%s's shot with %s misses: %s at %.2f m",
						cs(who), cs(item), wall < range ? "a wall" :
						"out of range", et);
				continue;
			}
			strike(peer, id, item, sheet, damage * (1 - sheet.get("falloff").
					as_number() * std::min(1.0, t / range)), head, d[0], d[2]);
			if(!m_peers.count(peer))
				return;
		}
		if(projectile)
			return;
		// Drawn by every client in the scene: a tracer, a splat
		json::Value sj = json::object();
		sj.set("by", (int64_t)me);
		sj.set("item", item);
		sj.set("color", jstr(sheet, "color"));
		sj.set("from", point(eye));
		sj.set("ends", ends);
		send_scene(scene, "kit:shot", sj.stringify());
	}

	// A projectile from `from` along d (a unit vector) at speed v, the sheet's
	// gravity, lifetime, colour and ([KIT_SHIP]) size; drawn by every client in
	// the scene. False: too many in flight
	bool launch(size_t peer, const ss_ &who, const ss_ &item, const json::Value &sheet,
			const double from[3], const double d[3], double v, double damage,
			uint64_t me, const ss_ &scene)
	{
		// A round's projectiles at once: a ceiling on the ticks' work
		if(m_projectiles.size() >= MAX_PROJECTILES){
			log_i(MODULE, "%s's projectile not made: %s in flight",
					cs(who), cs(itos(MAX_PROJECTILES)));
			return false;
		}
		Projectile pr;
		pr.id = m_next_shot++;
		pr.peer = peer;
		pr.item = item;
		pr.sheet = sheet;
		for(int k = 0; k < 3; k++)
			pr.pos[k] = from[k], pr.vel[k] = d[k] * v;
		pr.damage = damage;
		pr.at_us = now_us();
		pr.until_us = pr.at_us + (int64_t)(sheet.get("lifetime").
				as_number() * 1e6);
		json::Value pj = json::object();
		pj.set("id", (int64_t)pr.id);
		pj.set("from", point(pr.pos));
		pj.set("vel", point(pr.vel));
		pj.set("gravity", sheet.get("gravity"));
		pj.set("life", sheet.get("lifetime"));
		pj.set("color", jstr(sheet, "color"));
		if(sheet.get("size").is_number())
			pj.set("size", sheet.get("size"));
		pj.set("by", (int64_t)me);
		m_projectiles.push_back(pr);
		send_scene(scene, "kit:projectile", pj.stringify());
		return true;
	}

	// [KIT_SHIP] A turret's shot (kit/turret's s.shots went up): its holder's, a
	// cannonball from its front along its facing
	void drive_shot(size_t peer, const Entity &e, const json::Value &params)
	{
		auto pi = m_peers.find(peer);
		auto mi = pi == m_peers.end() ? m_entities.end() :
				m_entities.find(pi->second.player);
		if(mi == m_entities.end() || !m_session.running)
			return;
		double w[3], d[3] = {0, 0, 1};
		Turn q;
		world_of(e, w, &q);
		q.apply(d);
		const double from[3] = {w[0] + d[0], w[1] + d[1], w[2] + d[2]};
		json::Value sheet = json::object();
		sheet.set("gravity", num(params, "shot_gravity", 9.8, 0, 100));
		sheet.set("lifetime", 4.0);
		sheet.set("color", "#202020");
		sheet.set("size", 0.3);
		sheet.set("knockback", 0.0);
		sheet.set("crit", 1.0);
		const double v = num(params, "shot_speed", 40, 1, 200);
		const double damage = num(params, "shot_damage", 10, 0, 1000);
		const ss_ who = pi->second.name;
		log_i(MODULE, "%s fires entity %s's %s", cs(who), cs(itos(e.id)),
				cs(movement_on(e) ? movement_on(e)->type : ss_()));
		// [KIT_AIRSHIPS] not into its own ship: the free object it is under
		uint64_t ship = 0;
		for(auto si = m_entities.find(e.parent); si != m_entities.end() && !ship;
				si = m_entities.find(si->second.parent))
			if(m_free_objects.count(si->first))
				ship = si->first;
		if(launch(peer, who, "kit/turret", sheet, from, d, v, damage, mi->first,
				pi->second.scene))
			m_projectiles.back().ship = ship;
	}

	// Each tick, Running: the projectiles step on the game's clock (a
	// twentieth of a second at most each step), each hitting what the
	// step's path meets first -- an entity with health (strike), a solid
	// voxel -- or gone at its lifetime; their shooter gone, they go
	void projectiles_tick()
	{
		const int64_t now = now_us();
		for(size_t i = 0; i < m_projectiles.size(); ){
			Projectile pr = m_projectiles[i];
			auto pi = m_peers.find(pr.peer);
			auto mi = pi == m_peers.end() ? m_entities.end() :
					m_entities.find(pi->second.player);
			bool ended = mi == m_entities.end(), hit = false;
			const ss_ scene = ended ? ss_() : pi->second.scene;
			const main_context::SceneReference sref = ended ?
					main_context::SceneReference() : scene_of(mi->second);
			const uint64_t me = ended ? 0 : mi->first;
			double left = (std::min(now, pr.until_us) - pr.at_us) / 1e6;
			while(!ended && left > 1e-6){
				const double dt = std::min(0.05, left);
				left -= dt;
				const double g = pr.sheet.get("gravity").as_number();
				const double np[3] = {pr.pos[0] + pr.vel[0] * dt,
						pr.pos[1] + pr.vel[1] * dt - 0.5 * g * dt * dt,
						pr.pos[2] + pr.vel[2] * dt};
				pr.vel[1] -= g * dt;
				double d[3] = {np[0] - pr.pos[0], np[1] - pr.pos[1],
						np[2] - pr.pos[2]};
				const double len = std::sqrt(d[0] * d[0] + d[1] * d[1] +
						d[2] * d[2]);
				if(len < 1e-9)
					continue;
				for(double &c : d)
					c /= len;
				const double wall = ray_wall(sref, pr.pos, d, len);
				double t = 0;
				bool head = false;
				uint64_t id = ray_target(scene, pr.pos, d, wall, me, t,
						head);
				// [KIT_AIRSHIPS] a ship's voxel before them
				double st = 0;
				int sc = -1;
				const uint64_t ship = ray_ship(sref, pr.pos, d, id ? t : std::min(wall, len),
						pr.ship, st, sc);
				if(ship)
					id = 0, t = st;
				const double go = id || ship ? t : wall;
				for(int k = 0; k < 3; k++)
					pr.pos[k] += d[k] * go;
				if(ship){
					const int S = OWN_SIDE;
					const OwnGrid &g = m_own[ship];
					log_i(MODULE, "%s's projectile %s hits entity %s's cell (%i,%i,%i)",
							cs(pi->second.name), cs(itos(pr.id)), cs(itos(ship)),
							sc % S + g.a[0], sc / S % S + g.a[1], sc / (S * S) + g.a[2]);
					ship_damage(ship, {std::make_pair(sc, pr.damage)}, "player:"+itos(me),
							pi->second.name+"'s shot");
					ended = hit = true;
				} else if(id){
					log_i(MODULE, "%s's projectile %s hits entity %s",
							cs(pi->second.name), cs(itos(pr.id)), cs(itos(id)));
					strike(pr.peer, id, pr.item, pr.sheet, pr.damage, head,
							d[0], d[2]);
					ended = hit = true;
				} else if(wall < len){
					log_i(MODULE, "%s's projectile %s lands at (%.2f, %.2f, "
							"%.2f)", cs(pi->second.name), cs(itos(pr.id)),
							pr.pos[0], pr.pos[1], pr.pos[2]);
					ended = true;
				}
			}
			pr.at_us = std::min(now, pr.until_us);
			if(!ended && now >= pr.until_us){
				log_i(MODULE, "Projectile %s gone at its lifetime",
						cs(itos(pr.id)));
				ended = true;
			}
			if(!ended){
				m_projectiles[i++] = pr;
				continue;
			}
			json::Value ej = json::object();
			ej.set("id", (int64_t)pr.id);
			ej.set("at", point(pr.pos));
			ej.set("hit", hit);
			ej.set("color", jstr(pr.sheet, "color"));
			if(!scene.empty())
				send_scene(scene, "kit:projectile_end", ej.stringify());
			m_projectiles.erase(m_projectiles.begin() + i);
		}
	}

	// "kit:reload": the held ranged item's magazine filled after its
	// reload time (one round each time, one at a time), from its ammo
	// items if it takes any (kit/equipment's on_reload)
	void on_reload(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		const size_t peer = packet.sender;
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second))
			return;
		if(waiting_refused(pi->second, "reload"))
			return;
		Peer &p = pi->second;
		ss_ item, why;
		const json::Value *sheet = ranged_held(peer, item, why);
		if(sheet && json::jint(*sheet, "magazine", 0) <= 0)
			why = item+" has no magazine";
		ToolUse &tu = m_tool_use[peer];
		if(sheet && !tu.reloading.empty())
			why = "reloading already";
		if(!why.empty()){
			if(log_refusal(p, why))
				log_i(MODULE, "A reload by %s refused: %s", cs(p.name), cs(why));
			return;
		}
		const double time = sheet->get("reload").as_number();
		tu.reloading = item;
		tu.reload_us = now_us() + (int64_t)(time * 1e6);
		log_i(MODULE, "%s reloads %s: %g s", cs(p.name), cs(item), time);
		// [KIT_SOUNDS] its reload sound, theirs too (their client plays
		// none of its own: a refused reload makes no sound)
		play_item_sound(peer, item, "reload", false);
		json::Value rj = json::object();
		rj.set("item", item);
		rj.set("time", time);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:reloading", rj.stringify());
		});
	}

	// Each tick, Running: the reloads due (the hands still holding the
	// item): on_reload; one at a time, again while it says there is more
	void reloads_tick()
	{
		const int64_t now = now_us();
		sv_<size_t> due;
		for(auto &p : m_peers){
			auto ti = m_tool_use.find(p.first);
			if(ti != m_tool_use.end() && !ti->second.reloading.empty() &&
					now >= ti->second.reload_us)
				due.push_back(p.first);
		}
		for(size_t peer : due){
			ToolUse &tu = m_tool_use[peer];
			const ss_ item = tu.reloading;
			tu.reloading.clear();
			Peer &p = m_peers[peer];
			const json::Value *sheet = nullptr;
			size_t comp = 0;
			if(hands_of(p.player, &sheet) != item || !sheet ||
					!equipment_of(p.player, &comp)){
				log_i(MODULE, "%s's reload of %s stops: not in hand",
						cs(p.name), cs(item));
				continue;
			}
			const bool one = jstr(*sheet, "reload_mode") == "one";
			const double time = sheet->get("reload").as_number();
			Run r;
			r.entity = p.player;
			r.comp = comp;
			r.handler = "on_reload";
			r.by = "player:"+itos(p.player);
			r.args.append(item);
			r.args.append(json::jint(*sheet, "magazine", 0));
			r.args.append(jstr(*sheet, "ammo"));
			r.args.append(one);
			run(r);
			const bool more = m_ret.is_array() && m_ret.at(0u).is_true();
			if(!m_tool_use.count(peer))
				continue;
			if(one && more){
				m_tool_use[peer].reloading = item;
				m_tool_use[peer].reload_us = now + (int64_t)(time * 1e6);
			}
		}
	}


	// The material of a voxel by name (Kit's set's, a builder's), null for
	// another's (the app's own)
	const world::Material* material_named(const ss_ &voxel)
	{
		auto it = m_registered.find(world::material_of(voxel));
		return it == m_registered.end() ? nullptr : &it->second;
	}

	bool dig_ready(size_t peer, int x, int y, int z, const ss_ &voxel,
			double *wait) override
	{
		SessionScope sc(*this, session_of_peer(peer));
		return dig_ready_u(peer, x, y, z, voxel, wait);
	}

	// [KIT_DEFAULT_GROUPS] Digging by tools: [KIT_INVENTORY_PLAY]
	// kit/game_rules' building "inventory" (the default; "creative": every
	// voxel digs at once and drops nothing, as before groups)
	bool dig_by_tools()
	{
		return inventory_mode();
	}

	// A bare hand's speed for a material group (1 / the seconds a voxel
	// takes), also an item's for a group its sheet's dig leaves out; a
	// group not named here 1
	static double hand_speed(const ss_ &group)
	{
		static const std::map<ss_, double> speeds = {{"stone", 0.25},
				{"dirt", 1}, {"sand", 1.5}, {"wood", 0.5}, {"leaves", 4},
				{"plant", 50}};
		auto it = speeds.find(group);
		return it == speeds.end() ? 1 : it->second;
	}

	bool dig_ready_u(size_t peer, int x, int y, int z, const ss_ &voxel,
			double *wait)
	{
		auto pi = m_peers.find(peer);
		const world::Material *m = material_named(voxel);
		if(!m_hosted || pi == m_peers.end() || !m || m->group.empty() ||
				pi->second.editing || !m_session.running || !dig_by_tools())
			return true;
		const json::Value *sheet = nullptr;
		const ss_ item = hands_of(pi->second.player, &sheet);
		double speed = hand_speed(m->group);
		bool hand = true;
		if(sheet && has_item(pi->second.name, item)){
			const json::Value &s = sheet->get("dig").get(m->group.c_str());
			if(s.is_number())
				speed = s.as_number(), hand = false;
		}
		// [KIT_CTF] kit/game_rules' hand_level: a dig at a hand's speed
		// of a material above it refused
		if(hand && m->level > json::jint(game_rules(), "hand_level", 15)){
			const ss_ why = "A hand does not dig "+voxel;
			if(log_refusal(pi->second, why)){
				log_i(MODULE, "A dig by %s refused: %s (level %i)",
						cs(pi->second.name), cs(why), m->level);
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(peer, "kit:warning", why);
				});
			}
			if(wait)
				*wait = 0;
			return false;
		}
		const int64_t need = (int64_t)(1e6 / speed), now = now_us();
		ToolUse &tu = m_tool_use[peer];
		const bool same = tu.digging && tu.dig[0] == x && tu.dig[1] == y &&
				tu.dig[2] == z;
		if(need <= 50000 || (same && now - tu.dig_us >= need)){
			tu.digging = false;
			return true;
		}
		if(!same){
			tu.digging = true;
			tu.dig[0] = x, tu.dig[1] = y, tu.dig[2] = z;
			tu.dig_us = now;
		}
		const double left = (need - (now - tu.dig_us)) / 1e6;
		if(wait)
			*wait = left;
		json::Value j = json::object(), c = json::array();
		c.append((int64_t)x);
		c.append((int64_t)y);
		c.append((int64_t)z);
		j.set("cell", c);
		// [KIT_TOOLS_1] the client waits on the wall clock: the game's
		// seconds at its rate (--sim-rate; 0, as fast as it goes: as they are)
		const double rate = interface::os::game_rate();
		j.set("wait", rate > 0 ? left / rate : left);
		j.set("time", need / 1e6);
		// [KIT_DIG_LOOK] the whole dig on the wall clock (the crack's, the
		// swing's)
		j.set("span", rate > 0 ? need / 1e6 / rate : need / 1e6);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:digging", j.stringify());
		});
		if(!same)
			log_i(MODULE, "%s digs %s (%s, level %i) with %s: %g s",
					cs(pi->second.name), cs(voxel), cs(m->group), m->level,
					item.empty() ? "a hand" : cs(item), need / 1e6);
		return false;
	}

	void dug(size_t peer, int x, int y, int z, const ss_ &voxel) override
	{
		SessionScope sc(*this, session_of_peer(peer));
		auto pi = m_peers.find(peer);
		const world::Material *m = material_named(voxel);
		voxel_sound(peer, x, y, z, m ? m->sound_dig : ss_(), voxel+"'s dig");
		voxel_event(peer, "dig", x, y, z, voxel);
		// [KIT_INVENTORY_PLAY] a voxel with no group (the app's own) drops
		// itself at any level
		if(!m_hosted || pi == m_peers.end() || voxel.empty() ||
				voxel == "air" || pi->second.editing || !m_session.running ||
				!pi->second.player || !dig_by_tools())
			return;
		const int mlevel = m && !m->group.empty() ? m->level : 0;
		const json::Value *sheet = nullptr;
		ss_ item = hands_of(pi->second.player, &sheet);
		if(!sheet || !has_item(pi->second.name, item))
			item.clear(), sheet = nullptr;
		const int64_t level = sheet ? json::jint(*sheet, "level", 0) : 0;
		// [KIT_CTF] its material's drop (none: itself)
		const ss_ what = m && !m->drop.empty() ? m->drop :
				world::material_of(voxel);
		const ss_ drop = level >= mlevel && item_ok(what) ? what : "";
		log_i(MODULE, "%s dug %s (level %i) with %s (level %s): %s",
				cs(pi->second.name), cs(voxel), mlevel, item.empty() ?
				"a hand" : cs(item), cs(itos(level)), drop.empty() ?
				"no drop" : cs("drops "+drop));
		tool_run(pi->second.player, item, sheet ? json::jint(*sheet,
				"wear_dig", 1) : 0, sheet ? json::jint(*sheet, "uses", 0) : 0,
				drop);
		json::Value c = json::array();
		c.append((int64_t)x);
		c.append((int64_t)y);
		c.append((int64_t)z);
		if(!item.empty())
			item_hooks(peer, item, "dig", c);
	}

	// [KIT_SOUNDS] A voxel type's dig or place sound at the cell's middle,
	// edit mode too
	void voxel_sound(size_t peer, int x, int y, int z, const ss_ &name,
			const ss_ &why)
	{
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end())
			return;
		const double c[3] = {x + 0.5, y + 0.5, z + 0.5};
		play_sound(name, &pi->second.scene, c, why);
	}

	bool place_ready(size_t peer, const ss_ &voxel, ss_ *why) override
	{
		SessionScope sc(*this, session_of_peer(peer));
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || pi->second.editing ||
				!m_session.running || !inventory_mode())
			return true;
		const ss_ held = pi->second.player ? hands_of(pi->second.player) : "";
		if(!held.empty() && held == world::material_of(voxel) &&
				has_item(pi->second.name, held))
			return true;
		if(why)
			*why = held.empty() ? "Nothing in hand to place" :
					"Not in hand: "+world::material_of(voxel);
		return false;
	}

	void placed(size_t peer, int x, int y, int z, const ss_ &voxel) override
	{
		SessionScope sc(*this, session_of_peer(peer));
		const world::Material *mt = material_named(voxel);
		voxel_sound(peer, x, y, z, mt ? mt->sound_place : ss_(),
				voxel+"'s place");
		voxel_event(peer, "place", x, y, z, voxel);
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || pi->second.editing ||
				!m_session.running || !inventory_mode() || !pi->second.player)
			return;
		const uint64_t pid = pi->second.player;
		const ss_ item = world::material_of(voxel);
		const Instance *eq = equipment_of(pid);
		const int64_t slot = eq ? json::jint(eq->state, "slot", 0) : 0;
		json::Value sl = slots_of(pid);
		const json::Value s = sl.at((unsigned)std::max<int64_t>(0, slot - 1));
		if(own_slots() && slot > 0 && slot_item(s) == item){
			json::Value one = json::object();
			if(slot_n(s) > 1){
				one.set("item", item);
				one.set("n", slot_n(s) - 1);
				json::Value inst = s.get("inst");
				if(inst.is_array() && inst.size() > 1){
					inst.del_at(0);
					one.set("inst", inst);
				}
			}
			sl.set_at((unsigned)slot - 1, one);
			set_slots(pid, sl);
		} else {
			// simplified: under a replacing provider (counts only, no held
			// slot) a place takes nothing; its own on_item may
			return;
		}
		log_i(MODULE, "%s placed %s at (%i,%i,%i): one taken from slot %s",
				cs(pi->second.name), cs(voxel), x, y, z, cs(itos(slot)));
	}

	// ---- [KIT_INVENTORY_PLAY] Inventory play: kit/game_rules' building
	// and inventory rules (its declared defaults without one on the root),
	// the slots of Kit's kit/inventory (its Lua's format: {item, n, inst},
	// {} an empty one; `items` the counts), the hands by slot, pickups,
	// chests, starting kits and the inventory at a death and at a round's
	// ends. Under a replacing provider or the app's own items: counts only,
	// none of the slot parts

	json::Value game_rules()
	{
		json::Value r = json::object();
		auto ti = m_types.find("kit/game_rules");
		if(ti != m_types.end() && ti->second.decl.get("params").is_object())
			for(json::Iterator it(ti->second.decl.get("params")); it; ++it)
				r.set(it.key(), (*it).get("default"));
		const Instance *gr = root_instance("kit/game_rules");
		if(gr && gr->params.is_object())
			for(json::Iterator it(gr->params); it; ++it)
				r.set(it.key(), *it);
		return r;
	}

	// [KIT_HUD_STYLE] kit/game_rules' parameters of Kit's own HUD: the
	// root's, a scene's own kit/game_rules over them for that scene
	json::Value hud_rules(const ss_ &scene)
	{
		const json::Value r = game_rules();
		json::Value h = json::object();
		const auto is_hud = [](const ss_ &k) -> bool {
			for(const char *pre : {"health_", "hotbar_", "feed_", "hint_",
					"item_line_"})
				if(k.compare(0, strlen(pre), pre) == 0)
					return true;
			return false;
		};
		for(json::Iterator it(r); it; ++it)
			if(is_hud(it.key()))
				h.set(it.key(), *it);
		uint64_t sc = 0;
		for(auto &e : m_entities)
			if(e.second.kind == "scene" && e.second.name == scene)
				sc = e.first;
		for(auto &p : m_entities){
			if(!sc || p.second.parent != sc || p.second.has_pos)
				continue;
			for(const Instance &i : p.second.comps)
				if(i.type == "kit/game_rules" && i.params.is_object())
					for(json::Iterator it(i.params); it; ++it)
						if(is_hud(it.key()))
							h.set(it.key(), *it);
		}
		return h;
	}

	bool inventory_mode()
	{
		return jstr(game_rules(), "building") != "creative";
	}

	// Kit's own slots in play (not under a replacing provider or the app's
	// items)
	bool own_slots()
	{
		return !provider() && !app_items();
	}

	// kit/inventory's params: the rules it stores by
	json::Value inv_params()
	{
		const json::Value r = game_rules();
		json::Value p = json::object(), st = json::object();
		for(const char *k : {"slots", "stack", "full"})
			p.set(k, r.get(k));
		for(auto &it : m_item_types)
			if(it.second.get("stack").is_number())
				st.set(it.first, it.second.get("stack"));
		p.set("stacks", st);
		return p;
	}

	// An item's stack size by the rules (unlimited slots: no limit)
	int64_t stack_of(const json::Value &rules, const ss_ &item)
	{
		if(json::jint(rules, "slots", 0) <= 0)
			return MAX_ITEMS;
		auto it = m_item_types.find(item);
		const int64_t s = it != m_item_types.end() &&
				it->second.get("stack").is_number() ?
				json::jint(it->second, "stack", 1) :
				json::jint(rules, "stack", 99);
		return std::max<int64_t>(1, std::min(MAX_ITEMS, s));
	}

	static int64_t slot_n(const json::Value &s)
	{
		return s.is_object() ? json::jint(s, "n", 0) : 0;
	}

	static ss_ slot_item(const json::Value &s)
	{
		return slot_n(s) > 0 ? jstr(s, "item") : ss_();
	}

	// A player's slots (a copy; empty without Kit's own inventory)
	json::Value slots_of(uint64_t pid)
	{
		const Instance *own = own_inventory(pid);
		const json::Value &s = own ? own->state.get("slots") :
				json::Value();
		return s.is_array() ? s : json::array();
	}

	// A list of slots made sound (each {item, n, inst} or {}), at most
	// `size` (0: any) of them, the trailing empties dropped; the counts
	static json::Value clean_slots(const json::Value &in, size_t size,
			json::Value *items = nullptr)
	{
		json::Value out = json::array();
		if(items)
			*items = json::object();
		size_t last = 0;
		for(unsigned i = 0; i < in.size() && (!size || i < size) && i < 256;
				i++){
			const json::Value &s = in.at(i);
			const ss_ item = slot_item(s);
			const int64_t n = std::min(MAX_ITEMS, slot_n(s));
			if(item.empty() || !item_ok(item)){
				out.append(json::object());
				continue;
			}
			json::Value o = json::object();
			o.set("item", item);
			o.set("n", n);
			if(s.get("inst").is_array() && s.get("inst").size())
				o.set("inst", s.get("inst"));
			out.append(o);
			last = out.size();
			if(items)
				items->set(item, std::min<int64_t>(MAX_ITEMS,
						json::jint(*items, item.c_str(), 0) + n));
		}
		while(out.size() > last)
			out.del_at(out.size() - 1);
		return out;
	}

	// A player's slots set (Kit's own inventory): the counts with them,
	// their client told, the hands following the held slot
	void set_slots(uint64_t pid, const json::Value &slots)
	{
		Instance *own = own_inventory(pid);
		auto ei = m_entities.find(pid);
		if(!own || ei == m_entities.end())
			return;
		json::Value items;
		own->state.set("slots", clean_slots(slots, 0, &items));
		own->state.set("items", items);
		m_runtime_dirty = true;
		got_items(ei->second, own->type, ei->second.name, items);
	}

	// Where a player is: their peer's scene and place (false: not placed)
	bool player_at(uint64_t pid, ss_ &scene, double p[3])
	{
		const size_t peer = peer_of_player(pid);
		if(!peer)
			return false;
		scene = m_peers[peer].scene;
		for(int k = 0; k < 3; k++)
			p[k] = m_peers[peer].pos[k];
		return true;
	}

	// A pickup (kit/pickup) of n of an item made at a world point of a
	// scene, a game change gone at Stop
	void make_pickup(const ss_ &scene, const double p[3], const ss_ &item,
			int64_t n, const json::Value &inst)
	{
		const uint64_t sc = scene_entity(scene);
		if(!sc || !m_types.count("kit/pickup") || n < 1 || !item_ok(item) ||
				made_count() >= MAX_MADE || m_entities.size() >= MAX_ENTITIES){
			log_w(MODULE, "A pickup of %s %s at (%.1f,%.1f,%.1f) not made: %s",
					cs(itos(n)), cs(item), p[0], p[1], p[2], !sc ? "no scene" :
					"the round has made its entities");
			return;
		}
		Entity e;
		e.id = m_next_id++;
		e.parent = sc;
		e.has_pos = true;
		for(int k = 0; k < 3; k++)
			e.pos[k] = std::floor(p[k] + 0.5);
		e.made = 'g';
		Instance in;
		in.type = "kit/pickup";
		fresh(in);
		in.params.set("item", item);
		in.params.set("count", std::min(MAX_ITEMS, n));
		if(inst.is_array())
			in.state.set("inst", inst);
		e.comps.push_back(in);
		m_entities[e.id] = e;
		make_node(m_entities[e.id]);
		Run r;
		r.entity = e.id;
		r.handler = "on_start";
		queue_run(r);
		m_runtime_dirty = true;
		log_i(MODULE, "A pickup of %s %s at (%g,%g,%g): entity %s",
				cs(itos(n)), cs(item), e.pos[0], e.pos[1], e.pos[2],
				cs(itos(e.id)));
	}

	// Each slot's stack a pickup where a player is (at most 64)
	void drop_slots(uint64_t pid, const json::Value &slots,
			const double *at = nullptr)
	{
		ss_ scene;
		double p[3];
		if(!player_at(pid, scene, p))
			return;
		if(at)
			for(int k = 0; k < 3; k++)
				p[k] = at[k];
		for(unsigned i = 0, made = 0; i < slots.size() && made < 64; i++)
			if(!slot_item(slots.at(i)).empty()){
				make_pickup(scene, p, slot_item(slots.at(i)),
						slot_n(slots.at(i)), slots.at(i).get("inst"));
				made++;
			}
	}

	// After an inventory change of Kit's own: what did not fit dropped as
	// a pickup where the player is (got_items: then the hands follow the
	// held slot, check_hands, and send_items sends the slots)
	void slots_changed(const ss_ &who)
	{
		auto pl = m_players.find(who);
		Instance *own = pl == m_players.end() ? nullptr :
				own_inventory(pl->second);
		if(!own || !own_slots())
			return;
		const json::Value of = own->state.get("overflow");
		if(of.is_array() && of.size()){
			own->state.set("overflow", json::array());
			m_runtime_dirty = true;
			drop_slots(pl->second, of);
		}
	}

	// "kit:slots" {slots: [{item, n, wear, loaded}...], held, rules} to a
	// player's clients: their slots (the first instance's wear and rounds)
	// and the rules the hotbar, the screen and the HUD go by
	void send_slots(const ss_ &who)
	{
		auto pl = m_players.find(who);
		json::Value j = json::object(), l = json::array();
		const json::Value r = game_rules();
		if(pl != m_players.end() && own_slots()){
			const json::Value s = slots_of(pl->second);
			for(unsigned i = 0; i < s.size(); i++){
				json::Value o = json::object();
				if(!slot_item(s.at(i)).empty()){
					o.set("item", slot_item(s.at(i)));
					o.set("n", slot_n(s.at(i)));
					const json::Value &d = s.at(i).get("inst").at(0u);
					for(const char *k : {"wear", "loaded"})
						if(d.get(k).is_number())
							o.set(k, d.get(k));
				}
				l.append(o);
			}
			const Instance *eq = equipment_of(pl->second);
			j.set("held", eq ? json::jint(eq->state, "slot", 0) : 0);
		}
		j.set("slots", l);
		json::Value rules = json::object();
		for(const char *k : {"building", "slots", "hotbar", "screen",
				"drop_items", "show_health", "dig", "place"})
			rules.set(k, r.get(k));
		rules.set("own", own_slots());
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &p : m_peers)
				if(p.second.name == who){
					rules.set("hud", hud_rules(p.second.scene));
					j.set("rules", rules);
					inetwork->send(p.first, "kit:slots", j.stringify());
				}
		});
	}

	// The rules as last sent: a change (an edit of kit/game_rules) sends
	// every player's slots again
	ss_ m_rules_sent;
	void rules_watch()
	{
		// (a scene's own kit/game_rules too: its HUD's override)
		ss_ r = game_rules().stringify();
		for(auto &p : m_entities)
			if(p.second.kind == "scene")
				r += hud_rules(p.second.name).stringify();
		if(r == m_rules_sent)
			return;
		m_rules_sent = r;
		std::set<ss_> names;
		for(auto &p : m_peers)
			if(!p.second.name.empty())
				names.insert(p.second.name);
		for(const ss_ &n : names)
			send_slots(n);
	}

	// Moves n from one slot to another (the same list or two), by the
	// stack size: onto an empty slot or the same item's as far as it
	// fits; a whole stack onto another item's swaps them. The instances'
	// data goes with the first ones moved
	bool move_slots(json::Value &a, unsigned ai, json::Value &b, unsigned bi,
			int64_t n, const json::Value &rules, bool same)
	{
		while(a.size() <= ai)
			a.append(json::object());
		while(b.size() <= bi)
			b.append(json::object());
		if(same && ai == bi)
			return false;
		json::Value from = a.at(ai), to = b.at(bi);
		const ss_ item = slot_item(from), there = slot_item(to);
		const int64_t have = slot_n(from);
		if(item.empty() || n < 1)
			return false;
		n = std::min(n, have);
		if(!there.empty() && there != item){
			if(n != have)
				return false;
			a.set_at(ai, to);
			b.set_at(bi, from);
			return true;
		}
		const int64_t st = stack_of(rules, item);
		n = std::min(n, st - slot_n(to));
		if(n < 1)
			return false;
		json::Value fi = from.get("inst").is_array() ? from.get("inst") :
				json::array();
		json::Value moved = json::array(), rest = json::array();
		for(unsigned i = 0; i < fi.size(); i++)
			((int64_t)i < n ? moved : rest).append(fi.at(i));
		if(!there.empty()){
			while((int64_t)moved.size() < n && to.get("inst").size())
				moved.append(json::object());
			const json::Value &ti = to.get("inst");
			for(unsigned i = 0; i < ti.size(); i++)
				moved.append(ti.at(i));
		}
		json::Value nt = json::object();
		nt.set("item", item);
		nt.set("n", slot_n(to) + n);
		if(moved.size())
			nt.set("inst", moved);
		json::Value nf = json::object();
		if(have > n){
			nf.set("item", item);
			nf.set("n", have - n);
			if(rest.size())
				nf.set("inst", rest);
		}
		a.set_at(ai, nf);
		b.set_at(bi, nt);
		return true;
	}

	// The chest a peer has open: its entity, while it is there, in their
	// scene and in reach (0: none)
	sm_<size_t, uint64_t> m_open_chest;
	Instance* open_chest(size_t peer, Entity **ep = nullptr)
	{
		auto oc = m_open_chest.find(peer);
		auto pi = m_peers.find(peer);
		if(oc == m_open_chest.end() || pi == m_peers.end())
			return nullptr;
		auto it = m_entities.find(oc->second);
		ss_ scene;
		double w[3], d2 = 0;
		if(it != m_entities.end() && it->second.has_pos){
			scene_of(it->second, &scene);
			world_of(it->second, w);
			for(int k = 0; k < 3; k++)
				d2 += (w[k] - pi->second.pos[k]) * (w[k] - pi->second.pos[k]);
		}
		if(it == m_entities.end() || scene != pi->second.scene ||
				d2 > m_host.use_range * m_host.use_range * 2.25){
			m_open_chest.erase(oc);
			return nullptr;
		}
		for(Instance &in : it->second.comps)
			if(!m_types[in.type].decl.get("container").is_undefined()){
				if(ep)
					*ep = &it->second;
				return &in;
			}
		m_open_chest.erase(oc);
		return nullptr;
	}

	size_t chest_size(const Instance &in)
	{
		const ss_ p = jstr(m_types[in.type].decl, "container");
		return (size_t)std::max<int64_t>(1, std::min<int64_t>(54,
				json::jint(in.params, p.c_str(), 27)));
	}

	// "kit:chest" {id, name, size, slots} to the peers with it open ({}
	// for one whose chest is gone)
	void send_chest(size_t peer)
	{
		Entity *e = nullptr;
		Instance *in = open_chest(peer, &e);
		json::Value j = json::object();
		if(in){
			j.set("id", (int64_t)e->id);
			j.set("name", e->name.empty() ? in->type : e->name);
			j.set("size", (int64_t)chest_size(*in));
			json::Value l = json::array();
			const json::Value &s = in->state.get("slots");
			for(unsigned i = 0; i < s.size(); i++){
				json::Value o = json::object();
				if(!slot_item(s.at(i)).empty()){
					o.set("item", slot_item(s.at(i)));
					o.set("n", slot_n(s.at(i)));
				}
				l.append(o);
			}
			j.set("slots", l);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:chest", j.stringify());
		});
	}

	// A container type's use: it opens on the user's screen
	void chest_opened(size_t peer, uint64_t id)
	{
		if(!own_slots() || !game_rules().get("screen").is_true())
			return;
		m_open_chest[peer] = id;
		log_i(MODULE, "%s opens entity %s", cs(m_peers[peer].name),
				cs(itos(id)));
		send_chest(peer);
	}

	// "kit:inv" {op, ...} from a placed peer ([KIT_SESSIONS_1] in their
	// session): "move" {from: [where, slot], to: [where, slot], n} (where
	// "p" their own, "c" their open chest; slots from 1), "drop" {slot, n,
	// dir: [x, z]} (a pickup two metres along dir), "close" (the chest)
	void on_inv(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_inv_u(packet);
	}

	void on_inv_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || !act_allowed(pi->second) ||
				!pi->second.player || packet.data.size() > 512 ||
				!own_inventory(pi->second.player))
			return;
		if(waiting_refused(pi->second, "inventory move"))
			return;
		Peer &p = pi->second;
		const json::Value j = json::load_string(packet.data.c_str());
		const ss_ op = jstr(j, "op");
		const json::Value rules = game_rules();
		auto refuse = [&](const ss_ &why){
			if(log_refusal(p, "inv "+why))
				log_i(MODULE, "%s's inventory %s refused: %s", cs(p.name),
						cs(op.substr(0, 16)), cs(why));
		};
		if(op == "close"){
			m_open_chest.erase(peer);
			return;
		}
		if(!own_slots())
			return refuse("not Kit's own slots");
		if(!m_session.running)
			return refuse("the server is Stopped");
		const int64_t size = json::jint(rules, "slots", 0);
		auto slot_ok = [&](int64_t s, int64_t max){
			return s >= 1 && s <= (max > 0 ? max : 256);
		};
		if(op == "drop"){
			const int64_t s = json::jint(j, "slot", 0);
			if(!rules.get("drop_items").is_true())
				return refuse("dropping items is off");
			json::Value sl = slots_of(p.player);
			if(!slot_ok(s, size) || s > (int64_t)sl.size() ||
					slot_item(sl.at((unsigned)s - 1)).empty())
				return refuse("no such slot");
			const json::Value from = sl.at((unsigned)s - 1);
			const int64_t n = std::max<int64_t>(1, std::min(slot_n(from),
					json::jint(j, "n", 1)));
			json::Value one = json::array();
			one.append(json::object());
			move_slots(sl, (unsigned)s - 1, one, 0, n, json::object(), false);
			const json::Value &d = j.get("dir");
			double dx = d.at(0u).is_number() ? d.at(0u).as_number() : 0,
					dz = d.at(1u).is_number() ? d.at(1u).as_number() : 0;
			const double len = std::sqrt(dx * dx + dz * dz);
			dx = len > 1e-6 ? dx / len : 0;
			dz = len > 1e-6 ? dz / len : 0;
			double at[3] = {p.pos[0] + 2 * dx, p.pos[1], p.pos[2] + 2 * dz};
			log_i(MODULE, "%s drops %s %s", cs(p.name), cs(itos(n)),
					cs(slot_item(one.at(0u))));
			const uint64_t pid = p.player;
			set_slots(pid, sl);
			drop_slots(pid, one, at);
			return;
		}
		if(op != "move")
			return refuse("no such op");
		if(!rules.get("screen").is_true())
			return refuse("the inventory screen is off");
		const json::Value &f = j.get("from"), &t = j.get("to");
		const ss_ fw = jstr_at(f, 0), tw = jstr_at(t, 0);
		const int64_t fs = f.at(1u).is_number() ? (int64_t)f.at(1u).
				as_number() : 0, ts = t.at(1u).is_number() ? (int64_t)t.at(1u).
				as_number() : 0;
		const int64_t n = json::jint(j, "n", 0);
		Instance *chest = (fw == "c" || tw == "c") ? open_chest(peer) :
				nullptr;
		if((fw == "c" || tw == "c") && !chest)
			return refuse("no chest open");
		const int64_t cs_ = chest ? (int64_t)chest_size(*chest) : 0;
		if((fw != "p" && fw != "c") || (tw != "p" && tw != "c") ||
				!slot_ok(fs, fw == "p" ? size : cs_) ||
				!slot_ok(ts, tw == "p" ? size : cs_))
			return refuse("no such slot");
		json::Value mine = slots_of(p.player);
		json::Value theirs = chest && chest->state.get("slots").is_array() ?
				chest->state.get("slots") : json::array();
		json::Value &a = fw == "p" ? mine : theirs;
		json::Value &b = tw == "p" ? mine : theirs;
		// The chest's stacks by the same rules (its slots limited)
		json::Value cr = rules;
		if(!json::jint(cr, "slots", 0))
			cr.set("slots", (int64_t)cs_);
		if(!move_slots(a, (unsigned)fs - 1, b, (unsigned)ts - 1, n,
				fw == "c" || tw == "c" ? cr : rules, fw == tw))
			return refuse("nothing moves");
		log_i(MODULE, "%s moves %s from %s:%s to %s:%s", cs(p.name),
				cs(itos(n)), cs(fw), cs(itos(fs)), cs(tw), cs(itos(ts)));
		const uint64_t pid = p.player;
		if(fw == "c" || tw == "c"){
			chest->state.set("slots", clean_slots(theirs, (size_t)cs_));
			m_runtime_dirty = true;
			for(auto &oc : m_open_chest)
				if(open_chest(oc.first) == chest)
					send_chest(oc.first);
		}
		if(fw == "p" || tw == "p")
			set_slots(pid, mine);
	}

	// The hook for the rest: each instance with on_inventory(c, player,
	// when, kept, gone) in the player's scene, on the root or on their
	// entity -- when "death" or "round_end"; kept what the player will
	// have, gone what is dropped or lost -- returns them as it wants them
	// (nil: as they are)
	void inventory_hooks(uint64_t pid, const ss_ &when, json::Value &kept,
			json::Value &gone)
	{
		ss_ scene;
		double p[3];
		const bool placed = player_at(pid, scene, p);
		sv_<std::pair<uint64_t, size_t>> list;
		for(auto &e : m_entities){
			ss_ es;
			const bool here = e.first == pid || (e.second.parent == 1 &&
					!e.second.has_pos) || (placed &&
					scene_of(e.second, &es) && es == scene);
			if(!here)
				continue;
			for(size_t i = 0; i < e.second.comps.size(); i++)
				if(m_types[e.second.comps[i].type].handlers.count(
						"on_inventory"))
					list.push_back(std::make_pair(e.first, i));
		}
		for(auto &x : list){
			if(!m_entities.count(x.first))
				continue;
			Run r;
			r.entity = x.first;
			r.comp = x.second;
			r.handler = "on_inventory";
			r.by = "player:"+itos(pid);
			r.args.append(r.by);
			r.args.append(when);
			r.args.append(kept);
			r.args.append(gone);
			m_ret = json::null();
			run(r);
			if(m_ret.is_array() && m_ret.at(0u).is_array()){
				kept = clean_slots(m_ret.at(0u), 256);
				gone = m_ret.at(1u).is_array() ? clean_slots(m_ret.at(1u),
						256) : json::array();
				log_i(MODULE, "Entity %s's on_inventory (%s) for %s: %s kept, "
						"%s gone", cs(itos(x.first)), cs(when), cs(itos(pid)),
						cs(itos(kept.size())), cs(itos(gone.size())));
			}
		}
	}

	// A player's death (kit/health's respawn), before they are put back:
	// kit/game_rules' on_death -- keep, drop (each stack a pickup where
	// they died) or lose --, through the hook; marked died for the round
	void player_died(uint64_t pid)
	{
		Instance *own = own_inventory(pid);
		if(!own || !own_slots())
			return;
		own->state.set("died", true);
		const ss_ rule = jstr(game_rules(), "on_death");
		json::Value kept = slots_of(pid), gone = json::array();
		if(rule == "drop" || rule == "lose")
			std::swap(kept, gone);
		inventory_hooks(pid, "death", kept, gone);
		log_i(MODULE, "%s died: on_death %s: %s stacks kept, %s %s",
				cs(m_entities[pid].name), cs(rule), cs(itos(kept.size())),
				cs(itos(gone.size())), rule == "drop" ? "dropped" : "lost");
		if(rule == "drop")
			drop_slots(pid, gone);
		set_slots(pid, kept);
	}

	// The starting kits (a type with on_give, kit/starting_kit) a player
	// goes through: at a round's start ("round": each kit) or a respawn
	// ("spawn": those whose `when` is spawn); in the player's scene or on
	// the root, one under a team its members' only. A kit's `clear`
	// empties the inventory first
	void give_kits(uint64_t pid, bool respawn)
	{
		ss_ scene;
		double p[3];
		if(!own_inventory(pid) || !player_at(pid, scene, p))
			return;
		sv_<std::pair<uint64_t, size_t>> list;
		for(auto &e : m_entities){
			ss_ es;
			if(scene_of(e.second, &es) ? es != scene : e.second.parent != 1)
				continue;
			for(size_t i = 0; i < e.second.comps.size(); i++){
				const Instance &in = e.second.comps[i];
				if(!m_types[in.type].handlers.count("on_give") ||
						!in.disabled.empty() || (respawn &&
						jstr(in.params, "when") != "spawn"))
					continue;
				const uint64_t tid = team_over(e.second);
				if(tid && !in_team(pid, tid))
					continue;
				list.push_back(std::make_pair(e.first, i));
			}
		}
		for(auto &x : list){
			if(m_entities[x.first].comps[x.second].params.get("clear").
					is_true())
				set_slots(pid, json::array());
			Run r;
			r.entity = x.first;
			r.comp = x.second;
			r.handler = "on_give";
			r.by = "player:"+itos(pid);
			r.args.append(r.by);
			run(r);
		}
	}

	// ---- The round's ends ([KIT_INVENTORY_PLAY]; kit/arena's at_start
	// and at_end, kit/player_state's carry): what goes into a game session
	// and back, by the player's name
	struct Carry {
		json::Value slots = json::array();
		json::Value numbers = json::object(); // {type: {key: value}}
		ss_ at_start = "kit";
	};
	sm_<ss_, Carry> m_carry_in;
	// The players whose round's starting kits wait for its joins: {session,
	// player entity}
	std::set<std::pair<uint64_t, uint64_t>> m_kits_due;

	// In a round's tick, its queue run through
	void kits_due()
	{
		sv_<uint64_t> due;
		for(auto it = m_kits_due.begin(); it != m_kits_due.end();)
			if(it->first == m_active){
				due.push_back(it->second);
				it = m_kits_due.erase(it);
			} else {
				++it;
			}
		for(uint64_t pid : due)
			give_kits(pid, false);
	}

	// kit/player_state's carry: the state keys that carry
	std::set<ss_> carried_keys()
	{
		std::set<ss_> out;
		for(auto &p : m_entities)
			for(const Instance &in : p.second.comps)
				if(m_types[in.type].between_plays){
					std::istringstream is(jstr(in.params, "carry"));
					ss_ k;
					while(is >> k)
						if(k.size() <= 64)
							out.insert(k);
					return out;
				}
		return out;
	}

	// A player entity's numbers in the carried keys, {type: {key: value}}
	json::Value numbers_of(uint64_t pid, const std::set<ss_> &keys)
	{
		json::Value out = json::object();
		auto it = m_entities.find(pid);
		if(it == m_entities.end())
			return out;
		for(const Instance &in : it->second.comps)
			for(const ss_ &k : keys)
				if(in.state.get(k).is_number()){
					json::Value o = out.get(in.type).is_object() ?
							out.get(in.type) : json::object();
					o.set(k, in.state.get(k));
					out.set(in.type, o);
				}
		return out;
	}

	void set_numbers(uint64_t pid, const json::Value &nums)
	{
		auto it = m_entities.find(pid);
		if(it == m_entities.end() || !nums.is_object())
			return;
		Entity &e = it->second;
		for(size_t i = 0; i < e.comps.size(); i++){
			const json::Value &o = nums.get(e.comps[i].type);
			if(!o.is_object())
				continue;
			for(json::Iterator k(o); k; ++k){
				e.comps[i].state.set(k.key(), *k);
				if(m_types[e.comps[i].type].shared.count(k.key()))
					replicate_state(e, i, k.key());
			}
			m_runtime_dirty = true;
		}
	}

	// A game session's maker's parameter (kit/arena's at_start, at_end):
	// read in the default round
	ss_ maker_param(uint64_t session, const char *key, const ss_ &def)
	{
		auto si = m_sessions.find(session);
		if(si == m_sessions.end() || si->second->draft)
			return "";
		SessionScope sc(*this, 0);
		auto it = m_entities.find(si->second->maker);
		if(it == m_entities.end() || si->second->maker_comp >=
				it->second.comps.size())
			return def;
		const ss_ v = jstr(it->second.comps[si->second->maker_comp].params,
				key);
		return v.empty() ? def : v;
	}

	// ---- [KIT_INPUT_ACTIONS] Input as named actions: a type's `actions`
	// (api.h), each client's keys for them its own (the clients' key
	// store), a press reaching the instances that declare it

	static bool action_name_ok(const ss_ &n)
	{
		if(n.empty() || n.size() > 32)
			return false;
		for(char c : n)
			if(!isalnum((unsigned char)c) && c != '_')
				return false;
		return true;
	}

	// An instance's actions, {name, key, label}: its type's with
	// "param:<name>" that parameter's value; a bad name left out
	sv_<json::Value> actions_of(const Instance &in)
	{
		sv_<json::Value> out;
		const json::Value &a = m_types[in.type].decl.get("actions");
		for(unsigned i = 0; i < a.size(); i++){
			json::Value o = json::object();
			for(const char *k : {"name", "key", "label"}){
				ss_ v = jstr(a.at(i), k);
				if(v.compare(0, 6, "param:") == 0)
					v = jstr(in.params, v.substr(6).c_str());
				o.set(k, v.substr(0, 64));
			}
			if(action_name_ok(jstr(o, "name")))
				out.push_back(o);
		}
		return out;
	}

	std::set<ss_> m_action_names;
	ss_ m_actions_sent;
	int64_t m_actions_at = 0;

	// "kit:actions" [{name, key, label}...], the world's (the first
	// MAX_ACTIONS names): to a peer, or to all (-1) when it changed
	void send_actions(int64_t peer)
	{
		json::Value l = json::array();
		std::set<ss_> names;
		for(auto &p : m_entities)
			for(const Instance &in : p.second.comps)
				for(const json::Value &a : actions_of(in))
					if(names.size() < MAX_ACTIONS &&
							names.insert(jstr(a, "name")).second)
						l.append(a);
		const ss_ text = l.stringify();
		if(peer < 0 && text == m_actions_sent)
			return;
		m_action_names.swap(names);
		if(peer < 0){
			m_actions_sent = text;
			log_i(MODULE, "Actions: %s", cs(text));
		}
		network::access(m_server, [&](network::Interface *inetwork){
			if(peer >= 0){
				inetwork->send((size_t)peer, "kit:actions", text);
				return;
			}
			for(auto &p : m_peers)
				inetwork->send(p.first, "kit:actions", text);
		});
	}

	// on_action(c, name, phase, value, by) on each instance declaring the
	// action, in the player's scene or on the root: phase "pressed",
	// "released" or "held" (value: the seconds held)
	void action_runs(size_t peer, const ss_ &name, const ss_ &phase,
			const json::Value &value)
	{
		const Peer &pe = m_peers[peer];
		const ss_ by = by_of(pe.name);
		for(auto &p : m_entities){
			const Entity &e = p.second;
			ss_ scene;
			if(scene_of(e, &scene) && scene != pe.scene)
				continue;
			for(size_t i = 0; i < e.comps.size(); i++){
				const Instance &in = e.comps[i];
				if(!m_types[in.type].handlers.count("on_action"))
					continue;
				bool has = false;
				for(const json::Value &a : actions_of(in))
					has = has || jstr(a, "name") == name;
				if(!has)
					continue;
				Run r;
				r.entity = p.first;
				r.comp = i;
				r.handler = "on_action";
				r.by = by;
				r.args.append(name);
				r.args.append(phase);
				r.args.append(value);
				r.args.append(by);
				queue_run(r);
			}
		}
	}

	// "kit:action" "<name> 1" pressed, "<name> 0" released: from a peer
	// the app placed, in play (not in the tools), an action the world
	// declares, within ACTION_RATE a second
	// [KIT_SESSIONS_1] in the sender's session
	void on_action(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_action_u(packet);
	}

	void on_action_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const ss_ d = packet.data.substr(0, 40);
		const size_t sp = d.find(' ');
		const ss_ name = d.substr(0, sp);
		const bool down = sp != ss_::npos && d.substr(sp + 1) == "1";
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || pi->second.name.empty() ||
				!act_allowed(pi->second))
			return;
		Peer &pe = pi->second;
		auto refuse = [&](const ss_ &why){
			if(log_refusal(pe, why))
				log_i(MODULE, "An action from peer %zu refused: %s", peer,
						cs(why));
		};
		// A release always lets go (Stopped, or the action gone meanwhile)
		auto h = pe.held.find(name);
		if(!down){
			if(h == pe.held.end())
				return;
			pe.held.erase(h);
			if(!m_session.running || !m_action_names.count(name))
				return;
		} else {
			if(h != pe.held.end())
				return;
			if(!m_session.running)
				return refuse("the server is Stopped");
			if(sp == ss_::npos || !action_name_ok(name) ||
					!m_action_names.count(name))
				return refuse("no such action");
			if(pe.editing)
				return refuse("in the tools");
			if(waiting_refused(pe, "action"))
				return;
			const int64_t t = now_us();
			pe.held[name] = std::make_pair(t, t);
		}
		log_i(MODULE, "Action %s %s by %s", cs(name),
				down ? "pressed" : "released", cs(pe.name));
		action_runs(peer, name, down ? "pressed" : "released", json::null());
	}

	// [KIT_UI_COMPONENTS] "kit:ui" "<id> 1" pressed, "<id> 0" released:
	// a UI button (a `ui` of kind "button" with on_ui) on a player's screen,
	// from a peer the app placed, in play, in the button's scene, while it
	// is up for them (ui_visible), within the acts' allowance
	// (act_allowed, kit:action's); on_ui(c, phase, by) on it. A release
	// lets go of a press only
	// [KIT_SESSIONS_1] in the sender's session
	void on_ui_press(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_ui_press_u(packet);
	}

	void on_ui_press_u(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const ss_ d = packet.data.substr(0, 32);
		char *end = nullptr;
		const uint64_t id = strtoull(d.c_str(), &end, 10);
		const bool down = end && ss_(end) == " 1";
		auto pi = m_peers.find(peer);
		if(!m_hosted || pi == m_peers.end() || pi->second.name.empty() ||
				!pi->second.player || !act_allowed(pi->second))
			return;
		Peer &pe = pi->second;
		auto refuse = [&](const ss_ &why){
			if(log_refusal(pe, why))
				log_i(MODULE, "A UI press of %s from peer %zu refused: %s",
						cs(d), peer, cs(why));
		};
		if(!end || end == d.c_str() || (!down && ss_(end) != " 0"))
			return refuse("not \"<id> 1|0\"");
		if(!down){
			if(!pe.ui_held.erase(id) || !m_session.running)
				return;
		} else {
			if(pe.ui_held.count(id))
				return;
			if(!m_session.running)
				return refuse("the server is Stopped");
			if(pe.editing)
				return refuse("in the tools");
		}
		auto it = m_entities.find(id);
		if(it == m_entities.end())
			return refuse("no such button");
		ss_ scene;
		scene_of(it->second, &scene);
		if(scene != pe.scene)
			return refuse("in another scene");
		size_t comp = 0;
		bool button = false;
		for(size_t i = 0; i < it->second.comps.size() && !button; i++){
			const Type &t = m_types[it->second.comps[i].type];
			comp = i;
			// [KIT_AIRSHIPS_2] a pause menu's item (kit/pause_menu_action)
			const ss_ kind = jstr(t.decl.get("ui"), "kind");
			button = (kind == "button" || kind == "menu") &&
					t.handlers.count("on_ui");
		}
		if(!button)
			return refuse("no such button");
		if(down){
			if(!ui_visible(id, pe.player))
				return refuse("not on their screen");
			if(pe.ui_held.size() >= 16)
				return refuse("too many held");
			pe.ui_held.insert(id);
		}
		log_i(MODULE, "UI button %s %s by %s", cs(itos(id)),
				down ? "pressed" : "released", cs(pe.name));
		Run r;
		r.entity = id;
		r.comp = comp;
		r.handler = "on_ui";
		r.by = by_of(pe.name);
		r.args.append(down ? "pressed" : "released");
		r.args.append(r.by);
		queue_run(r);
	}

	// "held" every HELD_EVERY_US of game time while held (in play)
	void actions_held()
	{
		const int64_t now = now_us();
		for(auto &pp : m_peers){
			if(pp.second.editing || player_waiting(pp.second.player))
				continue;
			for(auto &h : pp.second.held){
				if(now - h.second.second < HELD_EVERY_US)
					continue;
				h.second.second = now;
				action_runs(pp.first, h.first, "held",
						json::Value((now - h.second.first) * 1e-6));
			}
		}
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
		m_watches.erase(old.info.id);
		// [KIT_SESSIONS_1] from their session's round; a guest's entity
		// in the default goes too
		const uint64_t id = session_of_peer(old.info.id);
		ss_ name;
		bool guest = false;
		{
			SessionScope sc(*this, id);
			auto pi = m_peers.find(old.info.id);
			if(pi != m_peers.end()){
				name = pi->second.name;
				guest = pi->second.guest;
			}
			leave_round(old.info.id, true);
		}
		m_peer_session.erase(old.info.id);
		m_tools_back.erase(old.info.id);
		if(id && guest)
			drop_guest(name);
	}

	// A peer out of the round entered: gone from the server, or
	// ([KIT_SESSIONS_1]) to another session's (a guest's entity kept)
	void leave_round(size_t peer, bool gone)
	{
		const bool was_editing = m_peers.count(peer) && m_peers[peer].editing;
		const uint64_t player = m_peers.count(peer) ? m_peers[peer].player : 0;
		const bool guest = m_peers.count(peer) && m_peers[peer].guest;
		const ss_ name = m_peers.count(peer) ? m_peers[peer].name : "";
		auto bi = m_bodies.find(peer);
		if(bi != m_bodies.end() && bi->second.seat)
			unseat(peer, bi->second, false);
		m_bodies.erase(peer);
		m_controls_sent.erase(peer);
		m_clock_sent.erase(peer);
		m_boxes_sent.erase(peer);
		m_tool_use.erase(peer);
		m_open_chest.erase(peer);
		m_peers.erase(peer);
		if(player)
			unplace_player(player);
		if(guest && gone)
			drop_guest(name);
		for(auto &w : m_worlds)
			if(w.second.world_peers.erase(peer)){
				WorldScope ws(m_w, &w.second);
				world_load_points();
			}
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
		if(was_editing)
			send_builders();
	}

	// [KIT_SESSIONS_1] The app's scene "<scene>~<id>" is session id's
	// scene: the peer's there once Kit moved them (move_peer()); a place
	// in another than their session's is from before the move
	void set_peer(size_t peer, const ss_ &name, const ss_ &app_scene,
			double x, double y, double z)
	{
		ss_ scene;
		const uint64_t id = split_scene(app_scene, scene);
		if(id != session_of_peer(peer)){
			log_v(MODULE, "Peer %zu placed in %s, not in their session %s's",
					peer, cs(app_scene), cs(itos(session_of_peer(peer))));
			return;
		}
		SessionScope sc(*this, id);
		const bool join = !m_peers.count(peer);
		set_peer_u(peer, name, scene, x, y, z);
		// [KIT_TEMPLATE_ROUGH_EDGES] One joining a Stopped server: on its
		// scene's spawner of players, as Play puts them (a round's join does)
		double look = NAN;
		const bool spawned = join && m_hosted && !m_session.running &&
				stopped_spawn(name, scene, x, y, z, look);
		// A body first put where the app placed them, but for one the join
		// put already (a spawner's teleport)
		if(join && m_host.controls && (!m_bodies[peer].put || spawned))
			put_player_u(peer, x, y, z, look);
		else if(spawned)
			m_server->emit_event("kit:move_player",
					new MovePlayer(peer, x, y, z, look));
		// A draft's builder: their tools on there; and back in the default
		// as they were in the session ([KIT_DRAFT_LEAVE_PLAY])
		GameSession *s = active_session();
		Peer &p = m_peers[peer];
		const bool back = join && m_tools_back.erase(peer) > 0;
		if(join && ((s && s->draft && p.name == s->by) || back) &&
				can_edit(peer) && !p.editing){
			log_i(MODULE, "%s's tools on in session %s", cs(p.name),
					cs(itos(session_of_peer(peer))));
			tools(p, peer, true);
			send_state(peer);
			send_builders();
		}
	}

	// The last spawner of players in the scene (as a round's joins leave
	// one): its place and facing
	bool stopped_spawn(const ss_ &who, const ss_ &scene, double &x, double &y,
			double &z, double &look)
	{
		const Entity *at = nullptr;
		for(auto &p : m_entities){
			ss_ es;
			if(!scene_of(p.second, &es) || es != scene)
				continue;
			for(auto &in : p.second.comps){
				const Type &t = m_types[in.type];
				if(t.spawn && (t.spawn_param.empty() ||
						in.params.get(t.spawn_param).is_true()))
					at = &p.second;
			}
		}
		if(!at)
			return false;
		double w[3];
		Turn q;
		world_of(*at, w, &q);
		x = w[0];
		y = w[1];
		z = w[2];
		look = norm_yaw(q.yaw());
		log_i(MODULE, "%s joins Stopped: put on spawner %s at (%g, %g, %g)",
				cs(who), cs(itos(at->id)), x, y, z);
		return true;
	}

	void set_peer_u(size_t peer, const ss_ &name, const ss_ &scene,
			double x, double y, double z)
	{
		Peer &p = m_peers[peer];
		const bool join = p.name != name || p.scene != scene;
		const bool moved_scene = !p.scene.empty() && p.scene != scene;
		// (a guest logging in stays where they are: their zones swap who)
		if(p.name.empty() || moved_scene)
			p.spawning = true;
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
		if(join){
			joined(peer);
			send_all_mine(peer);
		}
		if(m_open_tools && can_edit_u(peer)){
			m_open_tools = false;
			tools(p, peer, true);
			log_i(MODULE, "%s opens the template in edit mode", cs(p.name));
			// Where its players begin, not the World's middle: in a wall, maybe
			if(p.player)
				respawn_at(p.player, peer);
			send_state(peer);
			send_builders();
		}
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
		SessionScope sc(*this, session_of_peer(peer));
		return can_edit_u(peer);
	}

	bool can_edit_u(size_t peer)
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
		SessionScope sc(*this, session_of_peer(peer));
		return is_editing_u(peer);
	}

	bool is_editing_u(size_t peer)
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
		each_session([&]{ on_privs_u(login); });
	}

	void on_privs_u(const accounts::Login &login)
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

	// "<scene>:x,y,z", the section of a cell of a Kit scene's World
	ss_ cell_key(const ss_ &scene, int x, int y, int z)
	{
		const World *wd = world_named(scene);
		const int S = wd ? wd->section_size : 64;
		return scene+":"+itos(div_floor(x, S))+","+itos(div_floor(y, S))+
				","+itos(div_floor(z, S));
	}

	// A game session's room for a write to a section (its key): one it
	// wrote, or SESSION_MAX_WRITTEN not reached; `take` counts it in. The
	// default round and a draft have no bound
	bool session_room(const ss_ &key, bool take)
	{
		GameSession *gs = active_session();
		if(!gs || gs->draft || gs->written.count(key))
			return true;
		if(gs->written.size() >= SESSION_MAX_WRITTEN)
			return false;
		if(take)
			gs->written.insert(key);
		return true;
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
		SessionScope sc(*this, session_of_peer(peer));
		player_wrote_u(peer, x, y, z, build);
	}

	void player_wrote_u(size_t peer, int x, int y, int z, bool build)
	{
		auto pi = m_peers.find(peer);
		if(!m_hosted || !m_session.running || pi == m_peers.end())
			return;
		auto si = m_host.scenes.find(pi->second.scene);
		if(si == m_host.scenes.end())
			return;
		const char origin = pi->second.editing ? 'k' : build ? 'b' : 'g';
		session_room(cell_key(pi->second.scene, x, y, z), true);
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
				kept_to_copies(key);
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
		for(auto &s : m_host.scenes)
			watch_scene(s.first, s.second, on);
	}

	// One scene's watch; [KIT_SCENE_RUNNING_UNWATCHED] a scene made while
	// Running gets its own at once
	void watch_scene(const ss_ &name, main_context::SceneReference ref,
			bool on)
	{
		on = on && !m_host.persistent;
		if(m_active)
			return;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *w = ivw->get_instance(ref);
			if(!w)
				return;
			sp_<Watch> wt;
			if(on){
				wt = std::make_shared<Watch>();
				wt->scene = name;
				wt->mutex = &m_copies_mutex;
				wt->queue = &m_copies;
				wt->start = start_copies(name);
				wt->copied = m_session.copied;
				wt->copied.insert(m_session.restore.begin(),
						m_session.restore.end());
			}
			w->set_section_watch(wt);
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
	// type's defaults (a key's `param`'s value if it has one); nothing
	// disabled
	void to_start(Entity &e, size_t i)
	{
		Instance &in = e.comps[i];
		in.state = json::object();
		const json::Value &sd = m_types[in.type].decl.get("state");
		if(sd.is_object())
			for(json::Iterator it(sd); it; ++it){
				const json::Value &pv = in.params.get(jstr(*it, "param"));
				in.state.set(it.key(), (*it).get("param").is_string() &&
						!pv.is_undefined() ? pv : (*it).get("default"));
			}
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
			json::Value kept = m_aside.get(name).deepcopy();
			// [KIT_INVENTORY_PLAY] carried numbers; the slots with the items
			set_numbers(pid, kept.get("#numbers"));
			kept.del_key("#numbers");
			if(own && keep_inventory && kept.get("#slots").is_array()){
				json::Value items;
				own->state.set("slots", clean_slots(kept.get("#slots"), 0,
						&items));
				own->state.set("items", items);
			} else if(own && keep_inventory && kept.is_object() &&
					kept.size()){
				own->state.set("items", kept);
			}
			m_aside.del_key(name);
			// A game session's start: kit/arena's at_start, the numbers
			// carried in, the starting kits (after the round's joins:
			// a team's own)
			auto ci = m_carry_in.find(name);
			ss_ at_start = "kit";
			if(ci != m_carry_in.end()){
				at_start = ci->second.at_start;
				set_numbers(pid, ci->second.numbers);
				if(own && at_start == "keep"){
					json::Value items;
					own->state.set("slots", clean_slots(ci->second.slots, 0,
							&items));
					own->state.set("items", items);
				}
				m_carry_in.erase(ci);
			}
			if(at_start == "kit")
				m_kits_due.insert(std::make_pair(m_active, pid));
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
		// [KIT_CTF] The arena that made the game, in another scene, when
		// this is its `map`: its join (the teams)
		if(GameSession *gs = active_session()){
			auto me = m_entities.find(gs->maker);
			ss_ ms;
			if(me != m_entities.end() && scene_of(me->second, &ms) &&
					ms != scene && gs->maker_comp < me->second.comps.size() &&
					gs->map == scene){
				Run r;
				r.entity = gs->maker;
				r.comp = gs->maker_comp;
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
		m_motion_base = now_us();
		// [KIT_VEHICLE_MOVEMENTS] steered from their rows again, play's parameters gone
		m_drives.clear();
		m_play_params.clear();
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
		clear_start_copies();
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
		settle_bodies();
		log_i(MODULE, "Play by %s: a round from the start (authored %s, "
				"start %s)", cs(by), cs(digest(authored_json())),
				cs(digest(m_start)));
		// [KIT_SYMMETRY] parity verified: each slice its source's image
		for(auto &pe : m_entities){
			symmetry::Config cf;
			ss_ why;
			if(!symmetry_in(pe.second) || !symmetry_in(pe.second)->params.get(
					"on").is_true() || !sym_config(pe.second, cf, why))
				continue;
			const SymCounts n = sym_copy(scene_of(pe.second), cf, false, nullptr, by);
			const ss_ ents = sym_parity_entities(pe.second, cf);
			log_i(MODULE, "kit/symmetry %s at Play: %s differ from their "
					"source's image%s%s", cs(itos(pe.first)), cs(n.text()),
					ents.empty() ? "" : "; ", cs(ents));
			if(n.cells || n.samples || n.decor || !ents.empty())
				warn("kit/symmetry "+itos(pe.first)+" at Play: "+n.text()+
						" differ from their source's image"+(ents.empty() ? "" :
						"; "+ents));
		}
		// [KIT_TEMPLATE_ROUGH_EDGES] A voxel parameter naming a voxel no
		// scene has (it draws grey, writes nothing): said, once a name
		// simplified: checked at Play only, not as it is set or loaded
		std::set<ss_> names;
		for(auto &pe : m_entities)
			for(const Instance &in : pe.second.comps){
				auto t = m_types.find(in.type);
				const json::Value &decl = t == m_types.end() ? json::Value() :
						t->second.decl.get("params");
				if(!decl.is_object())
					continue;
				for(json::Iterator it(decl); it; ++it){
					const ss_ v = in.params.get(it.key()).is_string() ?
							in.params.get(it.key()).as_string() : "";
					if(jstr(*it, "type") != "voxel" || v.empty() || v == "air" ||
							!names.insert(v).second)
						continue;
					bool known = false;
					each_registry([&](interface::VoxelRegistry *reg){
						interface::VoxelName n;
						n.block_name = v;
						known = known || reg->has(n);
					});
					if(!known)
						warn("entity "+itos(pe.first)+"'s "+in.type+" "+it.key()+
								": no voxel "+v+" (drawn grey)");
				}
			}
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
		// [KIT_AIRSHIPS] the free copies' own voxels gone: their prefabs' again
		// (sync_free_objects() below)
		for(auto &o : m_own)
			m_free_boxes.erase(o.second.boxes);
		m_own.clear();
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
		}
		// ([KIT_AIRSHIPS] after every node: a made free copy's members are under
		// its root, their scene found through it)
		for(uint64_t id : made)
			m_entities.erase(id);
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
		}
		// [KIT_NESTING] once all are back: one under another is placed in
		// its frame
		for(auto &r : m_removed){
			Entity &e = m_entities[r.first];
			if(wants_node(e))
				make_node(e);
		}
		if(!made.empty() || !m_removed.empty())
			log_i(MODULE, "The round's entities: %zu made gone, %zu removed "
					"back", made.size(), m_removed.size());
		m_removed.clear();
		sync_free_objects();
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
		clear_start_copies();
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
		// [KIT_INVENTORY_PLAY] the slots with them ("#slots"), and
		// kit/player_state's carried numbers ("#numbers")
		const std::set<ss_> carry = carried_keys();
		for(auto &p : m_players){
			const Instance *own = keep_inventory ? own_inventory(p.second) :
					nullptr;
			json::Value a = json::object();
			if(own && own->state.get("items").is_object() &&
					own->state.get("items").size()){
				a = own->state.get("items").deepcopy();
				if(own->state.get("slots").is_array())
					a.set("#slots", own->state.get("slots"));
			}
			const json::Value nums = numbers_of(p.second, carry);
			if(nums.size())
				a.set("#numbers", nums);
			if(a.size())
				m_aside.set(p.first, a);
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
		settle_bodies();
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
		clear_start_copies();
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
		// What play moved stays where it is: its start's place now
		m_seat_home.clear();
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
		// [KIT_SESSIONS_1] the session they are in: {id, kind, by, clock}
		{
			GameSession *gs = active_session();
			json::Value sj = json::object();
			sj.set("id", (int64_t)m_active);
			sj.set("kind", ss_(!gs ? "default" : gs->bench ? "bench" :
					gs->draft ? "draft" : "game"));
			sj.set("by", gs ? gs->by : ss_());
			if(gs && gs->bench){
				sj.set("prefab", gs->prefab);
				sj.set("root", (int64_t)gs->root);
				sj.set("box", gs->box);
				sj.set("ready", !gs->stamp.is_object());
			}
			sj.set("clock", (int64_t)(now_us() / 1000000));
			sj.set("can", (bool)m_host.drop_scene && !m_host.persistent);
			j.set("session", sj);
		}
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
						"usable", "zone", "volume", "grants", "region", "voxel_box",
						"world_region", "version",
						"inventory", "root", "no_position", "inputs_types", "outputs_types",
						"inputs_labels", "outputs_labels", "player", "ui", "about", "seat",
						"movement"})
					if(!d.get(k).is_undefined())
						o.set(k, d.get(k));
				if(addable(t))
					o.set("addable", true);
				pal.set(t, o);
			}
			// The composition's types that are not in the palette, too:
			// the inspector needs every instance's parameters and signals
			json::Value types = pal;
			for(auto &t : m_types)
				if(!m_palette.count(t.first)){
					json::Value o = json::object();
					for(const char *k : {"params", "inputs", "outputs", "gizmo",
							"zone", "volume", "grants", "region", "voxel_box", "world_region",
							"version", "inventory",
							"root", "no_position", "inputs_types", "outputs_types", "inputs_labels",
							"outputs_labels", "player", "ui", "about", "seat", "movement"})
						if(!t.second.decl.get(k).is_undefined())
							o.set(k, t.second.decl.get(k));
					if(addable(t.first))
						o.set("addable", true);
					types.set(t.first, o);
				}
			// [KIT] stage 4h: the controls, the movements and the seats
			// after the objects
			json::Value names = json::array();
			for(int last = 0; last < 2; last++)
				for(const ss_ &t : m_palette){
					const json::Value &d = m_types[t].decl;
					// [KIT_COMPONENTS] (one that only goes on an entity: its inspector's)
					if(!d.get("component").is_true() && (d.get("controls").is_true() ||
							d.get("movement").is_object()) == (last == 1))
						names.append(t);
				}
			j.set("palette", names);
			j.set("types", types);
			j.set("authored", authored_json(true));
			// [KIT] stage 4d: the round's own entities (made in play) and
			// the players here, shown and selected, not edited; the prefabs
			json::Value made = json::array(), pfs = json::array();
			for(auto &e : m_entities){
				if(authored(e.second) || (e.second.kind == "player" &&
						!e.second.has_pos))
					continue;
				json::Value mj = world_row(e.second);
				if(e.second.made){
					mj.set("made", ss_(1, e.second.made));
					mj.set("made_by", e.second.made_by);
					mj.set("maker", (int64_t)e.second.maker);
				}
				made.append(mj);
			}
			j.set("made", made);
			// [KIT_HUD_WALK_ONLY] those holding a UI component
			json::Value pfs_ui = json::array();
			for(const ss_ &n : m_prefab_palette){
				pfs.append(n);
				const json::Value *pf = prefab(n);
				bool ui = false;
				for(unsigned i = 0; pf && i < pf->get("entities").size(); i++){
					const json::Value &es = pf->get("entities");
					const json::Value &cs_ = es.at(i).get("components");
					for(unsigned c = 0; c < cs_.size(); c++){
						ui = ui || jstr(cs_.at(c), "type").rfind("kit/ui_", 0) == 0;
					}
				}
				if(ui)
					pfs_ui.append(n);
			}
			j.set("prefabs", pfs);
			j.set("prefabs_ui", pfs_ui);
			// [KIT_PREFAB_ROOT] What the inspector and the palette's menu say
			// of each: its versions, its voxels' box, its copies here, and
			// whether this builder may rename or delete it
			{
				std::map<ss_, int64_t> copies;
				for(auto &e : m_entities)
					if(authored(e.second) && is_root(e.second))
						copies[jstr(e.second.prefab, "of")]++;
				std::map<ss_, int64_t> frees;
				for(auto &e : m_entities)
					if(authored(e.second) && is_free(e.second))
						frees[jstr(e.second.prefab, "of")]++;
				const ss_ author = prefab_author(pi->second);
				json::Value info = json::object();
				for(const ss_ &n : m_prefab_palette){
					const json::Value *pf = prefab(n);
					if(!pf)
						continue;
					json::Value o = json::object();
					o.set("version", json::jint(*pf, "version", 1));
					o.set("copies", copies[n]);
					o.set("free", frees[n]);
					const json::Value &vx = pf->get("voxels");
					if(vx.is_object()){
						o.set("voxels", voxels_version(*pf));
						o.set("at", vx.get("at"));
						o.set("size", vx.get("size"));
					}
					if(!author.empty() && jstr(*pf, "package").empty() &&
							n.compare(0, author.size() + 1, author+"/") == 0)
						o.set("own", true);
					info.set(n, o);
				}
				j.set("prefabs_info", info);
				// [KIT_FREE_PREFAB] each free copy's object's node
				json::Value fo = json::object();
				for(auto &f : m_free_objects)
					fo.set(itos(f.first), (int64_t)f.second.node);
				j.set("free_objects", fo);
			}
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
				for(auto &b : m_w->materials.biomes)
					bs.append(b.first);
				t.set("biomes", bs);
				t.set("biome", m_w->wp.biome);
				t.set("surface", ss_(m_w->wp.heightmap() ? "heightmap" : "voxels"));
				// [KIT_HEIGHTMAP_REGEN_LOSS] its edited samples, a previous map
				if(m_w->wp.heightmap()){
					hm_edits_load();
					t.set("edited_samples", (int64_t)m_w->hm_edits.size());
					ss_ prev;
					t.set("previous", m_store->get(world_row("hm_prev"), prev));
				}
				// [KIT_MATERIAL_SETS] the sets a World may be made of:
				// [label, id], the app's ("") first
				json::Value sets = json::array();
				sets.append(json::load_string("[\"the app's\", \"\"]"));
				for(auto &pk : m_packages)
					if(m_host.material_sets &&
							pk.second.get("materials").is_object()){
						json::Value e = json::array();
						e.append(package_label(pk.first));
						e.append(pk.first);
						sets.append(e);
					}
				t.set("material_sets", sets);
				j.set("terrain", t);
			}
			j.set("undo", (int64_t)m_undo[pi->second.name].size());
			j.set("symmetry", sym_state(pi->second.scene));
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
		// [KIT_EDIT_MODE_FPS] What is as last sent goes by name only
		if(pi != m_peers.end()){
			std::map<ss_, ss_> &was = pi->second.state_sent;
			std::map<ss_, ss_> now;
			json::Value out = json::object(), same = json::array();
			for(json::Iterator it(j); it; ++it){
				const ss_ k = it.key();
				ss_ v = it.value().stringify();
				auto wi = was.find(k);
				if(wi != was.end() && wi->second == v)
					same.append(k);
				else
					out.set(k, it.value());
				now[k] = std::move(v);
			}
			was = std::move(now);
			out.set("same", same);
			j = out;
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "kit:edit_state", j.stringify());
		});
	}

	// [KIT_SESSIONS_1] in the sender's session
	void on_edit(const network::Packet &packet)
	{
		SessionScope sc(*this, session_of_peer(packet.sender));
		on_edit_u(packet);
	}

	void on_edit_u(const network::Packet &packet)
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
		// [KIT_EDIT_MODE_FPS] The whole state again: a client that lacks a
		// key sent as the same (its Kit loaded again)
		if(op == "state"){
			p.state_sent.clear();
			return send_state(peer);
		}
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
		// [KIT_SESSIONS_1] The sessions (stats in the log), a builder's
		// draft; in a game session the tools edit nothing, in a draft
		// nothing of the default round's
		if(op == "sessions"){
			log_i(MODULE, "Sessions: %s", cs(session_stats().stringify()));
			return;
		}
		GameSession *gs = active_session();
		if(gs && !gs->draft && op != "voxel_info" && op != "body_ray" && op != "mode" &&
				op != "focus" && op != "try" && op != "watch")
			return refuse("in a game session: the tools edit nothing here");
		if(gs && (op == "play" || op == "stop" || op == "save_start" ||
				op == "keep" || op == "always_keep" || op == "terrain" ||
				op == "voxel" || op == "item" || op == "sound" ||
				op == "sound_delete" || op == "regenerate" ||
				op == "prefab_rename" || op == "prefab_delete" ||
				op == "hm_regenerate" ||
				op == "hm_restore" || op == "new_scene" || op == "export" ||
				op == "draft" || op == "prefab_bench" ||
				(gs->bench && op == "publish")))
			return refuse(gs->bench ? "editing a prefab: the project's; Close "
					"first" : "in a draft: the default round's");
		if(op == "draft")
			return make_draft(p, peer, refuse);
		if(op == "publish")
			return publish(p, refuse);
		if(op == "leave_draft"){
			if(!gs)
				return refuse("not in a draft");
			SessionOp so;
			so.op = "end";
			so.target = m_active;
			so.by = p.name;
			m_session_ops.push_back(so);
			return;
		}
		// In play too: it reads
		if(op == "voxel_info")
			return voxel_info(p, j, refuse);
		if(op == "body_ray")
			return body_ray(p, j, refuse);
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
		if(op == "prefab_bench")
			return prefab_bench(p, peer, j, refuse);
		if(op == "scene")
			return switch_scene(p, peer, j, refuse);
		// [KIT_WALK_HERE] {"op": "walk_here", "pos": [x, y, z]}: the
		// builder's body put there (its feet; the client turns its view)
		if(op == "walk_here"){
			const json::Value &ps = j.get("pos");
			if(!pos_ok(ps))
				return refuse("pos: three numbers within "+
						itos((int)MAX_COORD));
			log_i(MODULE, "%s walks here: (%g, %g, %g)", cs(p.name),
					ps.at(0u).as_number(), ps.at(1u).as_number(),
					ps.at(2u).as_number());
			return to_scene(peer, "", ps.at(0u).as_number(),
					ps.at(1u).as_number(), ps.at(2u).as_number());
		}
		if(op == "terrain")
			return terrain(p, peer, j, refuse);
		if(op == "voxel")
			return make_voxel(p, j, refuse);
		if(op == "item")
			return make_item(p, j, refuse);
		if(op == "sound")
			return make_sound(p, j, refuse);
		if(op == "sound_delete")
			return delete_sound(p, j, refuse);
		if(op == "set_voxel")
			return edit_voxel(p, peer, j, refuse);
		if(op == "edited")
			return send_edited(peer);
		if(op == "regenerate")
			return regenerate_sections(p, peer, j, refuse);
		if(op == "hm_regenerate")
			return regenerate_heightmap(p, peer, j, refuse);
		if(op == "hm_restore"){
			ss_ why;
			if(!hm_restore(p.name, why))
				return refuse(why);
			send_state(peer);
			return;
		}
		if(op == "try")
			return try_input(p, peer, j, refuse);
		if(op == "watch")
			return watch_op(p, peer, j, refuse);
		if(op == "pattern")
			return pattern_op(p, peer, j, refuse);
		if(op == "copy")
			return copy_op(p, peer, j, refuse);
		if(op == "export")
			return export_package(peer, p, refuse);
		// [KIT_ITEMS_TAB]
		if(op == "item_delete")
			return delete_item(p, j, refuse);
		// [KIT_PREFAB_ROOT] (no undo: the server's, as a voxel type's)
		if(op == "prefab_rename")
			return rename_prefab(p, j, refuse);
		if(op == "prefab_delete")
			return delete_prefab(p, j, refuse);
		if(op == "give")
			return give_me(p, j, refuse);
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
			// [KIT_HEIGHTMAP_REGEN_LOSS] a regeneration of all: the
			// heightmap before it back
			if(c.hm_restore){
				WorldScope ws(m_w, world_at(c.scene));
				if(!hm_restore(p.name, why))
					return refuse(why);
				send_state(peer);
				return;
			}
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
		m_paste = VoxelPaste();
		m_bench_saved.clear();
		const uint64_t next0 = m_next_id;
		if(!build_change(op, j, p, change, what, why) ||
				!rebuilds(change, p, what, why) || !sym_check(change, why)){
			m_paste.set = false;
			m_follow.clear();
			// [KIT_GENERATORS] a build refused: its ids not taken
			m_next_id = next0;
			return refuse(why);
		}
		if(in_draft())
			for(const auto &c : change)
				if(world_or_env(c.first, c.second)){
					m_next_id = next0;
					return refuse(active_session()->bench ? "editing a prefab: "
							"the World and the environment are the project's" :
							"in a draft: the World and the environment are the "
							"default round's");
				}
		two_way_returns(change, what);
		// [KIT_SYMMETRY] a place's voxels in the authored slice (its sides:
		// the slice and the map are convex), copied into the others after
		symmetry::Config scf;
		auto ssi = m_host.scenes.find(p.scene);
		const Entity *ssym = ssi == m_host.scenes.end() ? nullptr :
				sym_scene(ssi->second, scf);
		if(ssym && m_paste.set){
			auto box_ok = [&](const int o[3], const int n[3]){
				for(int k = 0; k < 4; k++)
					if(!scf.editable(o[0] + (k & 1 ? n[0] - 1 : 0),
							o[2] + (k & 2 ? n[2] - 1 : 0)))
						return false;
				return true;
			};
			int o[3], n[3];
			bool ok = true;
			if(!m_paste.only_clear && m_paste.vox.is_object()){
				placed_box(m_paste.vox, m_paste.base, m_paste.turn, o, n);
				ok = box_ok(o, n);
			}
			if(m_paste.clear)
				ok = ok && box_ok(m_paste.clear_at, m_paste.clear_size);
			if(!ok){
				m_paste.set = false;
				m_follow.clear();
				m_next_id = next0;
				return refuse("its voxels go outside kit/symmetry "+itos(ssym->id)+
						"'s authored slice "+scf.slice);
			}
		}
		// Turned on or changed: its slices' voxels copied after
		std::map<uint64_t, ss_> sym_was;
		for(auto &e : m_entities)
			if(const Instance *si = symmetry_in(e.second))
				sym_was[e.first] = si->params.get("on").is_true() ?
						si->params.stringify() : "";
		std::deque<Change> &u = m_undo[p.name];
		commit(change, &u);
		for(auto &e : m_entities){
			const Instance *si = symmetry_in(e.second);
			symmetry::Config cf;
			ss_ cwhy;
			if(!si || !si->params.get("on").is_true() || sym_was[e.first] ==
					si->params.stringify() || u.empty() ||
					!sym_config(e.second, cf, cwhy))
				continue;
			Change &nc = u.back();
			nc.stroke = -3;
			nc.scene = scene_of(e.second);
			const SymCounts n = sym_copy(nc.scene, cf, true, &nc, p.name);
			what += ", the slice "+cf.slice+" copied over the others: "+n.text();
			ss_ warnings = sym_parity_entities(e.second, cf);
			if(!warnings.empty())
				warn("kit/symmetry "+itos(e.first)+": "+warnings);
		}
		// [KIT_PREFAB_VOXELS] a place's voxels, with its entities one undo
		if(m_paste.set){
			m_paste.set = false;
			auto si = m_host.scenes.find(p.scene);
			Change &nc = u.back();
			nc.stroke = -3;
			nc.scene = si->second;
			size_t written = 0, missing = 0, unknown = 0, cleared = 0;
			if(m_paste.clear)
				clear_voxels(nc.scene, m_paste.clear_at, m_paste.clear_size, nc,
						p.name, cleared, missing);
			if(!m_paste.only_clear)
				write_voxels(m_paste.vox, nc.scene, m_paste.base, m_paste.turn,
						nc, p.name, written, missing, unknown);
			if(ssym){
				sv_<pv::Vector3DInt32> wrote;
				for(auto &q : nc.cells)
					wrote.push_back(pv::Vector3DInt32(std::get<0>(q.first),
							std::get<1>(q.first), std::get<2>(q.first)));
				size_t images = 0;
				voxelworld::access(m_server, nc.scene, [&](voxelworld::Instance *w){
					images = sym_write(w, nc.scene, scf, wrote, &nc.cells, p.name);
				});
				what += ", "+itos(images)+" images";
			}
			what += ", "+(m_paste.clear ? itos(cleared)+" voxels cleared, " :
					ss_())+itos(written)+" voxels written"+(missing ? ", "+
					itos(missing)+" not loaded" : ss_())+(unknown ? ", "+
					itos(unknown)+" of voxels the scene has not" : ss_());
			// [KIT_PREFAB_ROOT] with the root's move just before: one undo,
			// its own rows first so that the move's older ones are put last
			if(m_paste.merge && u.size() >= 2){
				Change &was = u[u.size() - 2];
				bool moved = false;
				for(const auto &b : was.before)
					moved = moved || b.first == (uint64_t)json::jint(j, "id", 0);
				if(moved && was.stroke == -1 && was.regen.empty()){
					was.stroke = -3;
					was.scene = nc.scene;
					was.cells = nc.cells;
					was.before.insert(was.before.begin(), nc.before.begin(),
							nc.before.end());
					u.pop_back();
					what += ", one undo with the move";
					send_state(peer); // commit() sent the count before this
				}
			}
		}
		log_i(MODULE, "An edit by %s: %s", cs(p.name), cs(what));
		world_check(p.name);
		if(!m_bench_saved.empty())
			bench_follow(p);
		// [KIT_FREE_PREFAB] every session's objects are the prefab's new model
		if(op == "save_prefab")
			each_session([&]{ sync_free_objects(); });
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

	// [KIT_SESSIONS_1] Whether an entity changed is (or becomes) a World's
	// or an environment's
	bool world_or_env(uint64_t id, const json::Value &after)
	{
		auto is = [&](const ss_ &t){
			auto ti = m_types.find(t);
			return t == "kit/environment" ||
					(ti != m_types.end() && ti->second.world);
		};
		auto it = m_entities.find(id);
		if(it != m_entities.end())
			for(const Instance &in : it->second.comps)
				if(is(in.type))
					return true;
		const json::Value &cs = after.get("components");
		for(unsigned i = 0; cs.is_array() && i < cs.size(); i++)
			if(is(full_type(jstr(cs.at(i), "type"))))
				return true;
		return false;
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
				new ChangeScene(peer, app_scene(scene, m_active), x, y, z, look));
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

	// [KIT_NESTING] An edit's "parent" (optional; 0 or none: the scene):
	// a positioned authored entity of the editor's scene, room under it
	// for `height` levels more; [KIT_PANEL_PARENT] or a panel, for a
	// `ui_child` only (the panel has no position, a UI element no use for
	// one). false with why
	bool parent_arg(const json::Value &j, const Peer &p, uint64_t &parent,
			ss_ &why, int height = 1, bool ui_child = false)
	{
		parent = 0;
		const json::Value &v = j.get("parent");
		if(v.is_undefined() || (v.is_number() && v.as_number() == 0))
			return true;
		Entity *e = entity_arg(j, "parent", why);
		if(!e)
			return false;
		ss_ scene;
		scene_of(*e, &scene);
		const bool panel = is_panel(*e);
		if(panel && !ui_child){
			why = "parent: only a UI element goes under the panel "+itos(e->id);
			return false;
		}
		if((!e->has_pos && !panel) || !e->kind.empty()){
			why = "parent: entity "+itos(e->id)+" has no position";
			return false;
		}
		if(scene != p.scene){
			why = "parent: entity "+itos(e->id)+" is in another scene";
			return false;
		}
		if(depth(e->id) - depth(scene_entity(scene)) + height > MAX_NEST){
			why = "parent: entity "+itos(e->id)+" is "+itos(MAX_NEST)+
					" levels deep";
			return false;
		}
		parent = e->id;
		return true;
	}

	// How many levels an entity and those under it are
	int height_of(uint64_t id, int d = 0)
	{
		int h = 1;
		if(d > MAX_NEST + 2)
			return h;
		for(auto &o : m_entities)
			if(o.second.parent == id && o.first != id)
				h = std::max(h, 1 + height_of(o.first, d + 1));
		return h;
	}

	// [KIT_NESTING] {"op": "parent", "id": n, "parent": m (0: the scene)}:
	// the entity (and what is under it) under m, where it is in the world
	// kept; m not it nor under it
	bool parent_change(const json::Value &j, const Peer &p,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what,
			ss_ &why)
	{
		Entity *e = entity_arg(j, "id", why);
		if(!e)
			return false;
		if((!e->has_pos && !no_position(*e)) || !e->kind.empty()){
			why = "entity "+itos(e->id)+" has no position";
			return false;
		}
		ss_ scene;
		scene_of(*e, &scene);
		if(scene != p.scene){
			why = "entity "+itos(e->id)+" is in another scene";
			return false;
		}
		uint64_t parent = 0;
		if(!parent_arg(j, p, parent, why, height_of(e->id), is_ui_element(*e)))
			return false;
		if(parent == e->id || under_one_of(parent, {e->id})){
			why = "parent: entity "+itos(parent)+" is "+(parent == e->id ?
					"itself" : "under it");
			return false;
		}
		const uint64_t to = parent ? parent : scene_entity(scene);
		if(to == e->parent){
			why = "entity "+itos(e->id)+" is under "+itos(to)+" already";
			return false;
		}
		json::Value after = entity_json(*e);
		after.set("parent", (int64_t)to);
		if(e->has_pos){
			double w[3];
			Turn wq;
			world_of(*e, w, &wq);
			json::Value pos = json::array();
			for(int k = 0; k < 3; k++)
				pos.append(grid(w[k]));
			after.set("pos", pos);
			row_turn(after, wq);
			localize(after);
		}
		change.push_back(std::make_pair(e->id, after));
		what = "put "+itos(e->id)+" under "+(parent ? itos(parent) :
				"the scene "+scene);
		return true;
	}

	// An entity's delete as a change: it gone ([KIT_NESTING] and what is
	// under it), and the links to them from the other authored entities
	void delete_change(uint64_t id,
			sv_<std::pair<uint64_t, json::Value>> &change)
	{
		const sv_<uint64_t> g = group_of(id, MAX_ENTITIES);
		const std::set<uint64_t> gone(g.begin(), g.end());
		for(uint64_t x : g)
			change.push_back(std::make_pair(x, json::null()));
		for(auto &o : m_entities){
			if(gone.count(o.first) || !authored(o.second))
				continue;
			bool links = false;
			for(const Instance &in : o.second.comps)
				for(const Link &l : in.links)
					links = links || gone.count(l.to);
			if(!links)
				continue;
			Entity copy = o.second;
			for(Instance &in : copy.comps)
				in.links.erase(std::remove_if(in.links.begin(),
						in.links.end(), [&](const Link &l){
					return gone.count(l.to) > 0;
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
		// [KIT_PREFAB_ROOT] (and prefab_rename, prefab_delete: on_edit_u())
		if(op == "stamp")
			return stamp(j, p, change, what, why);
		if(op == "prefab_detach")
			return detach_prefab(j, change, what, why);
		if(op == "prefab_reset")
			return reset_param(j, change, what, why);
		if(op == "place"){
			const ss_ type = jstr(j, "type");
			if(!m_palette.count(type)){
				why = "no type \""+type.substr(0, 64)+"\" in the palette";
				return false;
			}
			if(m_types[type].decl.get("component").is_true()){
				why = type+" has no place: add it to an entity";
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
			// [KIT_NO_WORLD_TYPES] The scene's, or under that entity, no position
			const bool no_pos = m_types[type].no_position;
			uint64_t scene = 0;
			for(auto &e : m_entities)
				if(e.second.kind == "scene" && e.second.name == p.scene)
					scene = e.first;
			if(!scene && (!root || on_scene)){
				why = "the editor is in no scene of the composition's";
				return false;
			}
			// [KIT_NESTING] "parent": under that entity, pos the world's
			// (a type the root or the scene has, as ever)
			uint64_t under = 0;
			if(!root && !on_scene && !parent_arg(j, p, under, why, 1,
					no_pos && m_types[type].decl.get("ui").is_object()))
				return false;
			const uint64_t id = m_next_id++;
			json::Value e = json::object();
			e.set("id", (int64_t)id);
			e.set("parent", (int64_t)(on_scene ? scene : root ? 1 :
					under ? under : scene));
			e.set("name", type+" "+itos(id));
			json::Value pos = json::array();
			for(unsigned k = 0; k < 3; k++)
				pos.append(grid(j.get("pos").at(k).as_number()));
			if(!root && !no_pos){
				e.set("pos", pos);
				localize(e);
			}
			json::Value comp = json::object();
			comp.set("type", type);
			// [KIT_ITEMS_TAB] "params": set at the place (an item dragged
			// in: a kit/pickup of it), each checked as "set" checks it
			const json::Value &ps = j.get("params");
			if(ps.is_object()){
				json::Value own = json::object();
				for(json::Iterator it(ps); it; ++it){
					const json::Value &decl = m_types[type].decl.
							get("params").get(it.key());
					const ss_ bad = decl.is_object() ?
							check_param(decl, *it) : "not a parameter of it";
					if(!bad.empty()){
						why = type+"'s "+it.key().substr(0, 64)+" is "+bad;
						return false;
					}
					own.set(it.key(), *it);
				}
				comp.set("params", own);
			}
			json::Value comps = json::array();
			comps.append(comp);
			e.set("components", comps);
			change.push_back(std::make_pair(id, e));
			what = "placed "+type+" "+itos(id)+(on_scene ? " on the scene "+
					p.scene : root ? ss_(" on the app root") : no_pos ?
					ss_(", no position") : " at "+pos.stringify())+
					(under ? " under "+itos(under) :
					ss_())+(ps.is_object() ? " with "+
					comp.get("params").stringify() : ss_());
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
			const char *angles[] = {"yaw", "pitch", "roll"};
			bool turned = false;
			for(const char *k : angles){
				const json::Value &v = j.get(k);
				if(!v.is_undefined() && (!v.is_number() ||
						!std::isfinite(v.as_number()))){
					why = ss_(k)+": a number of degrees";
					return false;
				}
				turned = turned || !v.is_undefined();
			}
			json::Value after = entity_json(*e);
			json::Value pos = json::array();
			for(unsigned k = 0; k < 3; k++)
				pos.append(grid(j.get("pos").at(k).as_number()));
			after.set("pos", pos);
			// [KIT_NESTING] pos and turn the world's: its parent's frame's
			// kept (what is under it goes with it). An angle left out: as it
			// is in the world
			double w[3], wa[3];
			Turn wq;
			world_of(*e, w, &wq);
			wq.angles(wa[0], wa[1], wa[2]);
			for(int k = 0; k < 3; k++)
				if(j.get(angles[k]).is_number())
					wa[k] = j.get(angles[k]).as_number();
			row_turn(after, wa[0], wa[1], wa[2]);
			localize(after);
			if(!turned)
				row_turn(after, e->yaw, e->pitch, e->roll);
			change.push_back(std::make_pair(e->id, after));
			what = "moved "+itos(e->id)+" to "+pos.stringify()+
					(yaw.is_number() ? ", turned to "+
					json::Value(norm_yaw(yaw.as_number())).stringify() : ss_());
			for(const char *k : {"pitch", "roll"})
				if(j.get(k).is_number())
					what += ", "+ss_(k)+" "+json::Value(
							norm_yaw(j.get(k).as_number())).stringify();
			return true;
		}
		// [KIT_SIGNALS_VIEW] {"op": "rename", "id", "name"}: the name a builder
		// reads it by, kept as the rest of the row is; "" back to its type's
		// and id. A scene's name is what it is found by: not that
		if(op == "rename"){
			Entity *e = entity_arg(j, "id", why);
			if(!e)
				return false;
			if(!e->kind.empty()){
				why = "entity "+itos(e->id)+" is a "+e->kind;
				return false;
			}
			ss_ name;
			for(char c : jstr(j, "name"))
				if((unsigned char)c >= 32 && c != 127)
					name += c;
			if(name.size() > 64){
				// (not left in the middle of a UTF-8 sequence)
				size_t end = 64;
				while(end > 0 && ((unsigned char)name[end] & 0xc0) == 0x80)
					end--;
				name = name.substr(0, end);
			}
			if(name.empty())
				name = (e->comps.empty() ? ss_("entity") : e->comps[0].type)+" "+
						itos(e->id);
			Entity copy = *e;
			copy.name = name;
			change.push_back(std::make_pair(e->id, entity_json(copy)));
			what = "renamed "+itos(e->id)+" to "+name;
			return true;
		}
		if(op == "add_component" || op == "remove_component")
			return component_change(op, j, change, what, why);
		if(op == "duplicate")
			return duplicate(j, p, change, what, why);
		if(op == "parent")
			return parent_change(j, p, change, what, why);
		if(op == "delete"){
			Entity *e = entity_arg(j, "id", why);
			if(!e)
				return false;
			if(!e->kind.empty()){
				why = "entity "+itos(e->id)+" is a "+e->kind;
				return false;
			}
			for(auto &o : m_entities)
				if(o.second.parent == e->id && !authored(o.second)){
					why = "entity "+itos(e->id)+" has entities of play's or "
							"a player under it";
					return false;
				}
			delete_change(e->id, change);
			size_t under = 0;
			for(auto &c : change)
				under += c.second.is_null() && c.first != e->id ? 1 : 0;
			what = "deleted "+itos(e->id)+(under ? " and "+itos(under)+
					" under it" : "")+(change.size() > under + 1 ? ", "+
					itos(change.size() - under - 1)+" links' ends" : "");
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
			// [KIT_WAVE_PIVOT_CENTER] "center": true sets a centre button's parameter
			// to the object's centre
			const bool centre = j.get("center").is_true();
			if(centre && jstr(decl, "button") != "center"){
				why = in->type+"'s "+param+" has no centre";
				return false;
			}
			const json::Value value = centre ? centre_of(*e) : j.get("value");
			const ss_ bad = check_param(decl, value);
			if(!bad.empty()){
				why = in->type+"'s "+param+" is "+bad;
				return false;
			}
			const size_t ci = in - &e->comps[0];
			Entity copy = *e;
			// (its own params: a copy of the Value shares them with e's, and
			// the undo's before-row had the new value)
			copy.comps[ci].params = copy.comps[ci].params.deepcopy();
			copy.comps[ci].params.set(param, value);
			// A prefab copy's own value from now on, kept as the prefab
			// changes ([KIT_GENERATORS] a generator's child's, as it builds
			// again; [KIT_PREFAB_ROOT] a copy's members are its root's children
			// so)
			if(!copy.built.is_undefined())
				copy.comps[ci].overrides.insert(param);
			change.push_back(std::make_pair(e->id, entity_json(copy)));
			what = "set "+itos(e->id)+"'s "+in->type+" "+param+" to "+
					value.stringify();
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

	// [KIT_WAVE_PIVOT_CENTER] A placed prefab's centre in its root's frame: the middle
	// of its voxels' box (cells' middles at at...at+size-1); none: its root's place
	json::Value centre_of(const Entity &e)
	{
		json::Value c = json::array();
		const json::Value *pf = e.prefab.is_object() ? prefab(jstr(e.prefab, "of")) :
				nullptr;
		const json::Value &vx = pf ? pf->get("voxels") : json::Value();
		const bool ok = vx.is_object() && pos_ok(vx.get("at")) && pos_ok(vx.get("size"));
		for(unsigned k = 0; k < 3; k++)
			c.append(ok ? vx.get("at").at(k).as_number() +
					(vx.get("size").at(k).as_number() - 1) / 2 : 0.0);
		return c;
	}

	// [KIT_COMPONENTS] {"op": "add_component", "id", "type"} and {"op":
	// "remove_component", "id", "comp"}: a component without a place on an entity, or
	// off it. A type once an entity, so (entity, type) names a component whatever is
	// added or removed beside it; a comp index is as the state last said.
	bool component_change(const ss_ &op, const json::Value &j,
			sv_<std::pair<uint64_t, json::Value>> &change, ss_ &what, ss_ &why)
	{
		Entity *e = entity_arg(j, "id", why);
		if(!e)
			return false;
		if(!e->kind.empty()){
			why = "entity "+itos(e->id)+" is a "+e->kind;
			return false;
		}
		if(!e->built.is_undefined()){
			why = "entity "+itos(e->id)+" is built by "+itos((uint64_t)json::jint(
					e->built, "by", 0))+": its components are its prefab's or generator's";
			return false;
		}
		Entity copy = *e;
		if(op == "remove_component"){
			Entity *e2 = nullptr;
			Instance *in = instance_arg(j, e2, why);
			if(!in)
				return false;
			if(!addable(in->type)){
				why = in->type+" has a place: it is what the entity is";
				return false;
			}
			if(e->comps.size() < 2){
				why = "it is the entity's last component: delete the entity";
				return false;
			}
			what = "removed "+in->type+" from "+itos(e->id);
			copy.comps.erase(copy.comps.begin() + (in - &e->comps[0]));
			change.push_back(std::make_pair(e->id, entity_json(copy)));
			return true;
		}
		const ss_ type = jstr(j, "type");
		if(!m_palette.count(type) || !addable(type)){
			why = "no component \""+type.substr(0, 64)+"\" to add";
			return false;
		}
		if(e->comps.size() >= MAX_COMPONENTS){
			why = "an entity has "+itos(MAX_COMPONENTS)+" components at most";
			return false;
		}
		for(const Instance &in : e->comps)
			if(in.type == type){
				why = "entity "+itos(e->id)+" has a "+type;
				return false;
			}
		if(m_types[type].decl.get("component").is_true() && !e->has_pos){
			why = type+" needs a place: entity "+itos(e->id)+" has none";
			return false;
		}
		if(is_movement(type)){
			if(const Instance *mv = movement_on(*e)){
				why = "entity "+itos(e->id)+" has a movement: "+mv->type;
				return false;
			}
		}
		if((type == WAVE_TYPE || type == COURSE_TYPE) && !is_root(*e)){
			why = type+" goes on a placed prefab's root";
			return false;
		}
		Instance in;
		in.type = type;
		const json::Value &decl = m_types[type].decl.get("params");
		what = "added "+type+" to "+itos(e->id);
		if(decl.is_object())
			for(json::Iterator it(decl); it; ++it){
				// [KIT_WAVE_PIVOT_CENTER] a centre button's parameter starts there
				const bool c = jstr((*it), "button") == "center";
				in.params.set(it.key(), c ? centre_of(*e) : (*it).get("default"));
				if(c)
					what += ", its "+it.key()+" "+in.params.get(it.key()).stringify();
			}
		copy.comps.push_back(in);
		change.push_back(std::make_pair(e->id, entity_json(copy)));
		return true;
	}

	// The entities as the change has them, live: their nodes, runtime state
	// and owned voxels follow, the authored row is saved, and each editor
	// is sent the tree. undo: the editor's, which gets what puts it back.
	// Running, a deleted entity's on_remove runs first ([KIT] stage 4d)
	void commit(const sv_<std::pair<uint64_t, json::Value>> &change_in,
			std::deque<Change> *undo)
	{
		const sv_<std::pair<uint64_t, json::Value>> change =
				ordered(change_in);
		// [KIT_SESSIONS_1] a draft's, for its Publish
		if(in_draft())
			for(const auto &c : change)
				active_session()->touched.insert(c.first);
		Change back;
		for(const auto &c : change)
			if(!c.second.is_null())
				m_pending_ids.insert(c.first);
		for(const auto &c : change)
			if(c.second.is_null() && m_session.running &&
					m_entities.count(c.first))
				run_now(c.first, "on_remove", "app");
		// [KIT_COMPONENTS] and a removed component's
		for(const auto &c : change){
			auto ei = m_entities.find(c.first);
			if(c.second.is_null() || !m_session.running || ei == m_entities.end())
				continue;
			const json::Value &cs_ = c.second.get("components");
			for(size_t i = ei->second.comps.size(); i-- > 0;){
				const ss_ type = ei->second.comps[i].type;
				bool kept = false;
				for(unsigned k = 0; k < cs_.size() && !kept; k++)
					kept = full_type(jstr(cs_.at(k), "type")) == type;
				if(kept || !m_types[type].handlers.count("on_remove"))
					continue;
				Run r;
				r.entity = c.first;
				r.comp = i;
				r.handler = "on_remove";
				r.by = "app";
				run(r);
				ei = m_entities.find(c.first);
				if(ei == m_entities.end() || i > ei->second.comps.size())
					break;
			}
		}
		for(const auto &c : change){
			if(undo){
				auto it = m_entities.find(c.first);
				back.before.push_back(std::make_pair(c.first,
						it == m_entities.end() ? json::null() :
						entity_json(it->second)));
			}
			apply(c.first, c.second);
		}
		// [KIT_SYMMETRY] the copies as their sources are now, one undo (an
		// undo's rows have them already)
		if(undo)
			symmetries(&back.before);
		m_pending_ids.clear();
		// [KIT_AIRSHIPS_2] the regions' voxels, in the same undo
		regions_sync(undo ? &back : nullptr, "");
		if(undo){
			undo->push_back(back);
			while(undo->size() > UNDO_MAX)
				undo->pop_front();
		}
		m_runtime_dirty = true;
		own_voxels();
		pick_provider();
		sync_free_objects();
		m_store->set("authored", authored_json().stringify());
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
	}

	// [KIT_NESTING] A change in the order it applies in: the entities that
	// go first, those under others before them; then the rows, a parent's
	// before those under it (an undo's rows are its change's, in its order)
	sv_<std::pair<uint64_t, json::Value>> ordered(
			const sv_<std::pair<uint64_t, json::Value>> &change)
	{
		sv_<std::pair<uint64_t, json::Value>> out;
		sv_<size_t> gone;
		std::map<uint64_t, size_t> row;
		for(size_t i = 0; i < change.size(); i++)
			if(change[i].second.is_null())
				gone.push_back(i);
			else
				row[change[i].first] = i;
		std::stable_sort(gone.begin(), gone.end(), [&](size_t a, size_t b){
			return depth(change[a].first) > depth(change[b].first);
		});
		sv_<bool> done(change.size(), false);
		// [KIT_PREFAB_ROOT] a row coming out from under what goes (a Detach):
		// before it goes, its way up is how its node's scene is found
		std::set<uint64_t> going;
		for(size_t i : gone)
			going.insert(change[i].first);
		for(size_t i = 0; i < change.size(); i++){
			if(change[i].second.is_null())
				continue;
			auto ei = m_entities.find(change[i].first);
			if(ei != m_entities.end() && going.count(ei->second.parent)){
				done[i] = true;
				out.push_back(change[i]);
			}
		}
		for(size_t i : gone)
			out.push_back(change[i]);
		std::function<void(size_t, int)> put = [&](size_t i, int d){
			if(done[i])
				return;
			done[i] = true;
			auto pi = row.find((uint64_t)json::jint(change[i].second,
					"parent", 0));
			if(pi != row.end() && d < MAX_NEST + 2)
				put(pi->second, d + 1);
			out.push_back(change[i]);
		};
		for(size_t i = 0; i < change.size(); i++)
			if(!change[i].second.is_null())
				put(i, 0);
		return out;
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

	// [KIT_COMPONENTS] What names an instance of `id` by its number, as an edit
	// moves them (same: each new number's old): the queued runs (one of an instance
	// gone, dropped), what it made and its sessions
	void renumber(uint64_t id, const std::map<size_t, size_t> &same, size_t was)
	{
		std::map<size_t, size_t> to;
		bool moved = same.size() != was;
		for(auto &s : same){
			to[s.second] = s.first;
			moved = moved || s.first != s.second;
		}
		if(!moved)
			return;
		for(auto r = m_queue.begin(); r != m_queue.end();){
			if(r->entity == id && !to.count(r->comp)){
				r = m_queue.erase(r);
				continue;
			}
			if(r->entity == id)
				r->comp = to[r->comp];
			++r;
		}
		for(auto &p : m_entities)
			if(p.second.made && p.second.maker == id && to.count(p.second.maker_comp))
				p.second.maker_comp = to[p.second.maker_comp];
		for(auto &gs : m_sessions)
			if(gs.second->maker == id && to.count(gs.second->maker_comp))
				gs.second->maker_comp = to[gs.second->maker_comp];
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
				!nest_ok(n, why) || (n.has_pos && !scene_of(n))){
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
		// An edit that puts one play moved elsewhere: that place is its
		// composition's, not the one before play moved it
		if(had)
			for(int k = 0; k < 3; k++)
				if(std::fabs(n.pos[k] - it->second.pos[k]) > 1e-6 ||
						std::fabs(n.yaw - it->second.yaw) > 1e-6 ||
						std::fabs(n.pitch - it->second.pitch) > 1e-6 ||
						std::fabs(n.roll - it->second.roll) > 1e-6)
					m_seat_home.erase(id);
		sv_<size_t> fresh;
		// Running, an instance whose parameters changed is told which, and
		// what each was ([KIT] stage 4d)
		sv_<std::pair<size_t, json::Value>> changed;
		// [KIT_COMPONENTS] The same instance is the same type's, wherever Remove or an
		// undo put it. What named it by its number goes with it
		std::map<size_t, size_t> same;
		std::set<size_t> taken;
		for(size_t i = 0; had && i < n.comps.size(); i++)
			for(size_t k = 0; k < it->second.comps.size(); k++)
				if(!taken.count(k) && it->second.comps[k].type == n.comps[i].type){
					taken.insert(k);
					same[i] = k;
					break;
				}
		renumber(id, same, had ? it->second.comps.size() : 0);
		for(size_t i = 0; i < n.comps.size(); i++){
			Instance &in = n.comps[i];
			if(same.count(i)){
				// The same instance: its runtime state goes on
				const Instance &was = it->second.comps[same[i]];
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
			if(n.node && (!wants_node(n) || scene_of(n) != scene_of(it->second))){
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
		// [KIT_COMPONENTS] on a node there already, shared state to tell
		for(size_t i : fresh)
			if(had)
				for(const ss_ &k : m_types[e.comps[i].type].shared)
					replicate_state(e, i, k);
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
		if(wants_node(e) && !e.node){
			make_node(e);
		} else if(e.node){
			main_context::access(m_server, scene_of(e), [&](magic::Scene *scene){
				magic::Node *nd = scene->GetNode(e.node);
				if(nd){
					// A parameter its look is drawn from may have changed
					nd->SetVar(magic::StringHash("kit_show"), magic::Variant(
							show_of(e).stringify().c_str()));
					nd->SetVar(magic::StringHash("kit_parent"),
							magic::Variant((int)parent_node_id(e)));
				}
			});
		}
		// [KIT_NESTING] it and what is under it where it is now
		place_nodes(id);
	}

	// ---- [KIT_SESSIONS_1] Sessions (api.h): game sessions and builders'
	// private drafts beside the default round, each a round of its own from
	// the start in the app's scenes "<scene>~<id>". The members a round has
	// of its own are swapped in as the code at hand is about one
	// (enter_session(); SessionScope): the rest (types, palette, prefabs,
	// packages, rights, ids) are the server's

	static const size_t MAX_SESSIONS = 8;
	// The sections a game session writes, its own beside the start's
	// (each a copy of up to ~100 KB in memory): a write into one more is
	// refused
	static const size_t SESSION_MAX_WRITTEN = 256;
	static const int64_t SESSION_IDLE_US = 60000000;

	struct Ctx
	{
		std::map<uint64_t, Entity> entities;
		std::deque<Run> queue;
		sm_<size_t, Peer> peers;
		bool runtime_dirty = false;
		std::deque<Write> pending_voxels;
		uint64_t provider = 0;
		size_t provider_comp = 0;
		std::set<ss_> inv_refused;
		sm_<ss_, std::deque<Change>> undo;
		std::map<main_context::SceneReference,
				std::set<std::tuple<int, int, int>>> owned_sections;
		Session session;
		json::Value start = json::object();
		std::map<ss_, std::map<std::tuple<int, int, int>, Mark>> marks;
		std::set<ss_> marks_dirty;
		sv_<Discarded> discarded;
		std::map<uint64_t, Removed> removed;
		std::map<ss_, uint64_t> players;
		json::Value aside = json::object();
		json::Value flows = json::array();
		std::map<ss_, json::Value> play_flows;
		std::map<uint64_t, std::deque<ss_>> logs;
		std::set<uint64_t> log_dirty;
		std::map<ss_, World> worlds;
		World *w = nullptr;
		sm_<ss_, main_context::SceneReference> scenes;
		storage::Store *store = nullptr;
		std::map<ss_, std::pair<uint64_t, int64_t>> arrive;
		std::map<uint64_t, EnvClock> env_clock;
		sm_<ss_, ss_> env_sent, season_sent;
		int64_t cost_since = 0, cost_budget = 0;
		json::Value costs = json::object();
		std::map<size_t, Body> bodies;
		sm_<size_t, ss_> controls_sent;
		std::map<uint64_t, std::array<double, 6>> seat_home;
		// [KIT_VEHICLE_MOVEMENTS]
		std::map<uint64_t, Drive> drives;
		std::map<uint64_t, json::Value> motions;
		std::map<size_t, std::map<uint64_t, std::pair<int64_t, double>>> track_sent;
		std::map<uint64_t, std::map<ss_, json::Value>> play_params;
		std::map<uint64_t, Attach> attached;
		std::set<ss_> action_names;
		ss_ actions_sent;
		int64_t actions_at = 0;
		std::map<std::pair<ss_, ss_>, std::array<double, 3>> scene_pos;
		std::vector<Projectile> projectiles; // [KIT_TOOLS_2]
		std::map<uint64_t, FreeObject> free_objects;
		std::map<uint64_t, OwnGrid> own;
		int64_t radar_at = 0;
		std::map<main_context::SceneReference, std::set<ss_>> free_models;
		sm_<size_t, std::set<ss_>> boxes_sent;
		int64_t clock_base = 0;
		int64_t motion_base = 0;
	};

	void swap_ctx(Ctx &c)
	{
		using std::swap;
		swap(m_entities, c.entities);
		swap(m_queue, c.queue);
		swap(m_peers, c.peers);
		swap(m_runtime_dirty, c.runtime_dirty);
		swap(m_pending_voxels, c.pending_voxels);
		swap(m_provider, c.provider);
		swap(m_provider_comp, c.provider_comp);
		swap(m_inv_refused, c.inv_refused);
		swap(m_undo, c.undo);
		swap(m_owned_sections, c.owned_sections);
		swap(m_session, c.session);
		swap(m_start, c.start);
		swap(m_marks, c.marks);
		swap(m_marks_dirty, c.marks_dirty);
		swap(m_discarded, c.discarded);
		swap(m_removed, c.removed);
		swap(m_players, c.players);
		swap(m_aside, c.aside);
		swap(m_flows, c.flows);
		swap(m_play_flows, c.play_flows);
		swap(m_logs, c.logs);
		swap(m_log_dirty, c.log_dirty);
		swap(m_worlds, c.worlds);
		swap(m_w, c.w);
		swap(m_host.scenes, c.scenes);
		swap(m_store, c.store);
		swap(m_arrive, c.arrive);
		swap(m_env_clock, c.env_clock);
		swap(m_env_sent, c.env_sent);
		swap(m_season_sent, c.season_sent);
		swap(m_cost_since, c.cost_since);
		swap(m_cost_budget, c.cost_budget);
		swap(m_costs, c.costs);
		swap(m_bodies, c.bodies);
		swap(m_controls_sent, c.controls_sent);
		swap(m_free_objects, c.free_objects);
		swap(m_own, c.own);
		swap(m_radar_at, c.radar_at);
		swap(m_free_models, c.free_models);
		swap(m_boxes_sent, c.boxes_sent);
		swap(m_seat_home, c.seat_home);
		swap(m_drives, c.drives);
		swap(m_motions, c.motions);
		swap(m_track_sent, c.track_sent);
		swap(m_play_params, c.play_params);
		swap(m_attached, c.attached);
		swap(m_action_names, c.action_names);
		swap(m_actions_sent, c.actions_sent);
		swap(m_actions_at, c.actions_at);
		swap(m_scene_pos, c.scene_pos);
		swap(m_clock_base, c.clock_base);
		swap(m_motion_base, c.motion_base);
		swap(m_projectiles, c.projectiles);
	}

	struct GameSession
	{
		uint64_t id = 0;
		bool draft = false;
		ss_ by; // who made it: a builder's name (a draft), a run's by
		// The instance that made it (0: none), told on_session_end
		uint64_t maker = 0;
		size_t maker_comp = 0;
		Ctx ctx;
		up_<OverlayStore> store;
		// A draft's: the entities its edits changed (Publish's)
		std::set<uint64_t> touched;
		// The app's scenes made for it, by their names
		std::set<ss_> app_scenes;
		// Since when nobody is in it (time_us; 0: someone is)
		int64_t empty_since = 0;
		// The sections its players and entities wrote ("<scene>:x,y,z")
		std::set<ss_> written;
		// [KIT_LATE_JOIN] The players its start took in
		size_t start_players = 0;
		// [KIT_CTF] The scene its round is played in ("": the maker's own);
		// [KIT_MAP_ROTATION] the rotation's other maps: their entities do
		// not run in it
		ss_ map;
		std::set<ss_> left_out;
		// [KIT_PREFAB_BENCH] A prefab's temporary scene (prefab_bench()): which
		// prefab, its copy's root, its box of voxels ([x0, y0, z0, x1, y1, z1]
		// or null) and where its builder came from. stamp: its voxels until
		// they are laid out (null then), retried at stamp_next (time_us)
		bool bench = false;
		ss_ prefab;
		uint64_t root = 0;
		json::Value box = json::null();
		ss_ back_scene;
		double back_pos[3] = {0, 0, 0};
		double at[3] = {0, 0, 0};
		json::Value stamp = json::null();
		int64_t stamp_next = 0;
		size_t stamped = 0;
	};
	std::map<uint64_t, up_<GameSession>> m_sessions;
	// The default round's members while a session is entered
	Ctx m_default_ctx;
	uint64_t m_active = 0;
	uint64_t m_next_session = 1;
	// The peers in a session (none: the default)
	std::map<size_t, uint64_t> m_peer_session;
	// [KIT_DRAFT_LEAVE_PLAY] The builders moved back to the default with
	// their tools on: on again there as they join
	std::set<size_t> m_tools_back;
	std::map<main_context::SceneReference, uint64_t> m_ref_session;
	// The app's scenes of ended sessions, dropped once their players are
	// out (time_us)
	sv_<std::pair<int64_t, ss_>> m_drop_scenes;
	// What runs asked (c:session_start/move/end), done after the tick's
	// rounds
	struct SessionOp
	{
		ss_ op;
		uint64_t from = 0, maker = 0, target = 0;
		size_t comp = 0;
		ss_ by;
		sv_<size_t> peers;
		// [KIT_MINIGAMES_1] an end's result, on_session_end's third
		json::Value result = json::null();
		// [KIT_MAP_ROTATION] a start's map and the rotation's others
		ss_ map;
		std::set<ss_> left_out;
	};
	std::deque<SessionOp> m_session_ops;
	// The round's clock: game time since its start (the default's: the
	// server's)
	int64_t m_clock_base = 0;
	// [KIT_MOVING_OBJECTS] now_us() where a motion's time begins: at Play, the wave
	// from where its row says
	int64_t m_motion_base = 0;
	bool m_at_rest = false;
	// Kit's own store (a session's m_store is its overlay)
	storage::Store *m_kit_store = nullptr;
	// The start's voxel copies the sessions read, by scene
	sm_<ss_, sp_<StartCopies>> m_start_copies;

	int64_t now_us()
	{
		return interface::os::game_us() - m_clock_base;
	}

	Ctx& stash_of(uint64_t id)
	{
		return id ? m_sessions[id]->ctx : m_default_ctx;
	}

	// The members the session's (0: the default round's) from here on
	void enter_session(uint64_t id)
	{
		if(id && !m_sessions.count(id))
			id = 0;
		if(id == m_active)
			return;
		swap_ctx(stash_of(m_active));
		swap_ctx(stash_of(id));
		m_active = id;
	}

	struct SessionScope
	{
		Module &m;
		uint64_t was;
		SessionScope(Module &m, uint64_t id): m(m), was(m.m_active)
		{
			m.enter_session(id);
		}
		~SessionScope(){ m.enter_session(was); }
	};

	// [KIT_BROADCAST_SESSION] f in the default session's scope and then in
	// each other's: m_peers is a session's, so what is the whole server's
	// (item types, voxel types, textures, packages, prefabs) is sent so
	void each_session(const std::function<void()> &f)
	{
		sv_<uint64_t> ids = {0};
		for(auto &s : m_sessions)
			ids.push_back(s.first);
		for(uint64_t id : ids){
			SessionScope sc(*this, id);
			f();
		}
	}

	// The editor state to every session's peers: the server's palette,
	// voxel types, textures or packages changed
	void send_state_all()
	{
		each_session([&]{
			for(auto &o : m_peers)
				send_state(o.first);
		});
	}

	uint64_t session_of_peer(size_t peer)
	{
		auto it = m_peer_session.find(peer);
		return it == m_peer_session.end() ? 0 : it->second;
	}

	uint64_t session_of_ref(main_context::SceneReference ref)
	{
		auto it = m_ref_session.find(ref);
		return it == m_ref_session.end() ? 0 : it->second;
	}

	GameSession* active_session()
	{
		auto it = m_sessions.find(m_active);
		return it == m_sessions.end() ? nullptr : it->second.get();
	}

	bool in_draft()
	{
		GameSession *s = active_session();
		return s && s->draft;
	}

	// A scene of Kit's as the app has it in session `id`
	static ss_ app_scene(const ss_ &scene, uint64_t id)
	{
		return id ? scene+"~"+itos(id) : scene;
	}

	// The app's scene name as a session's (0 for none) and Kit's name
	static uint64_t split_scene(const ss_ &app, ss_ &scene)
	{
		const size_t t = app.rfind('~');
		scene = app;
		if(t == ss_::npos)
			return 0;
		const ss_ n = app.substr(t + 1);
		if(n.empty() || n.size() > 15 ||
				n.find_first_not_of("0123456789") != ss_::npos)
			return 0;
		scene = app.substr(0, t);
		return std::stoull(n);
	}

	sp_<StartCopies> start_copies(const ss_ &scene)
	{
		sp_<StartCopies> &c = m_start_copies[scene];
		if(!c){
			c = std::make_shared<StartCopies>();
			c->store = m_kit_store;
		}
		return c;
	}

	void clear_start_copies()
	{
		for(auto &c : m_start_copies)
			c.second->clear();
	}

	// A section's live edits kept (marks 'k'), which the start's copy has
	// not before a Stop: the sessions' source reads them from the default's
	// voxels
	void kept_to_copies(const ss_ &key)
	{
		if(m_active)
			return;
		sv_<pv::Vector3DInt32> cells;
		auto it = m_marks.find(key);
		if(it != m_marks.end())
			for(auto &c : it->second)
				if(c.second.kind == 'k')
					cells.push_back(pv::Vector3DInt32(std::get<0>(c.first),
							std::get<1>(c.first), std::get<2>(c.first)));
		start_copies(key.substr(0, key.find(':')))->set_kept("start:"+key,
				cells);
	}

	// The row "sessions": the next id and the app's scenes the live ones
	// have (and ended ones' not dropped yet), which a restart drops
	// (sessions are not saved), and the live ones' makers [id, entity,
	// comp], told on_session_end at the restart
	void save_sessions()
	{
		json::Value live = json::array(), makers = json::array();
		for(auto &s : m_sessions){
			for(const ss_ &n : s.second->app_scenes)
				live.append(n);
			if(s.second->maker){
				json::Value m = json::array();
				m.append((int64_t)s.first);
				m.append((int64_t)s.second->maker);
				m.append((int64_t)s.second->maker_comp);
				makers.append(m);
			}
		}
		// and those of ended ones not dropped yet
		for(auto &d : m_drop_scenes)
			live.append(d.second);
		json::Value j = json::object();
		j.set("next", (int64_t)m_next_session);
		j.set("live", live);
		j.set("makers", makers);
		m_kit_store->set("sessions", j.stringify());
	}

	void sessions_from_save()
	{
		ss_ row;
		if(!m_kit_store->get("sessions", row))
			return;
		const json::Value j = json::load_string(row.c_str());
		const int64_t next = json::jint(j, "next", 1);
		if(next > 0 && next < (int64_t)1e15)
			m_next_session = (uint64_t)next;
		const json::Value &live = j.get("live");
		size_t n = 0;
		for(unsigned i = 0; i < live.size(); i++)
			if(live.at(i).is_string() && m_host.drop_scene){
				m_host.drop_scene(live.at(i).as_string());
				n++;
			}
		if(n)
			log_i(MODULE, "Sessions: %zu scenes of sessions before the "
					"restart dropped", n);
		// Their makers told they ended (an arena back to its lobby)
		const json::Value &makers = j.get("makers");
		for(unsigned i = 0; i < makers.size(); i++){
			const json::Value &m = makers.at(i);
			const json::Value &e = m.at(1u), &c = m.at(2u), &id = m.at(0u);
			if(!id.is_number() || !e.is_number() || !c.is_number() ||
					!m_entities.count((uint64_t)e.as_number()))
				continue;
			Run r;
			r.entity = (uint64_t)e.as_number();
			r.comp = (size_t)std::max(0.0, c.as_number());
			r.handler = "on_session_end";
			r.args.append((int64_t)id.as_number());
			json::Value o = json::object();
			o.set("stopped", true);
			o.set("ended", "the server restarted");
			r.args.append(o);
			queue_run(r);
			log_i(MODULE, "Session %s ended by the restart",
					cs(itos((int64_t)id.as_number())));
		}
		save_sessions();
	}

	// [KIT_SESSIONS_1] One of the session's scenes as the app made it: its
	// voxels the start's, copy-on-write (SessionSource), its registry the
	// default scene's order (the copies' ids are the default's), its save
	// only what the session changed
	void session_scene(const ss_ &name, main_context::SceneReference ref)
	{
		GameSession *s = active_session();
		s->app_scenes.insert(app_scene(name, m_active));
		m_ref_session[ref] = m_active;
		save_sessions();
		// [KIT_PREFAB_BENCH] a bench's: no source, the voxels' ids its builder's
		// scene's
		auto bi = m_default_ctx.scenes.find(s->bench ? s->back_scene : name);
		const main_context::SceneReference base =
				bi == m_default_ctx.scenes.end() ? nullptr : bi->second;
		sp_<SessionSource> src = std::make_shared<SessionSource>();
		src->scene = name;
		src->copies = start_copies(name);
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *w = ivw->get_instance(ref);
			voxelworld::Instance *b = base ? ivw->get_instance(base) : nullptr;
			if(!w)
				return;
			if(b){
				interface::VoxelRegistry *reg = w->get_voxel_reg();
				size_t off = 0;
				for(const interface::VoxelDefinition &d :
						b->get_voxel_reg()->get_all()){
					if(d.id == interface::VOXELTYPEID_UNDEFINED)
						continue;
					// By id: a name looked up that is not there is a warning
					const interface::VoxelDefinition *have = reg->get(d.id);
					if(have)
						off += !(have->name == d.name);
					else
						off += reg->add_voxel(d) != d.id;
				}
				if(off)
					log_w(MODULE, "Session %s: %zu voxel ids of scene %s "
							"not the default's: its voxels read wrong",
							cs(itos(m_active)), off, cs(name));
			}
			src->base = b;
			if(!s->bench)
				w->set_section_source(src);
			w->set_writes_alter(true);
			w->set_save_unaltered(false);
		});
	}

	// A session from the start ([KIT_SESSIONS_1]): the composition's
	// entities at their start (the row "start" over the types' defaults),
	// each scene's World as the default's, its on_start runs. 0 with why
	// when refused. Made at the top (the default round entered)
	uint64_t make_session(bool draft, const ss_ &by, uint64_t maker,
			size_t comp, ss_ &why, const json::Value *bench = nullptr,
			const ss_ &back_scene = "")
	{
		if(!m_host.make_scene || !m_host.drop_scene){
			why = "the app makes no scenes for sessions";
			return 0;
		}
		if(m_host.persistent){
			why = "the world is persistent: no sessions";
			return 0;
		}
		if(m_sessions.size() >= MAX_SESSIONS){
			why = itos(MAX_SESSIONS)+" sessions at most";
			return 0;
		}
		// A copy: the session's entities are its own
		const json::Value c = bench ? *bench : json::load_string(
				authored_json().stringify().c_str());
		const uint64_t id = m_next_session++;
		up_<GameSession> s(new GameSession());
		s->id = id;
		s->draft = draft;
		s->by = by;
		s->maker = maker;
		s->maker_comp = comp;
		s->store.reset(new OverlayStore());
		s->store->base = m_kit_store;
		s->ctx.store = s->store.get();
		s->ctx.w = &m_none;
		s->ctx.clock_base = interface::os::game_us();
		// [KIT_PREFAB_BENCH] a bench's components do not run
		s->bench = bench != nullptr;
		s->back_scene = back_scene;
		s->ctx.session.running = !bench;
		s->ctx.session.by = by;
		s->ctx.start = m_start.deepcopy();
		m_sessions[id] = std::move(s);
		save_sessions();
		bool ok = false;
		{
			SessionScope sc(*this, id);
			ok = session_load(c, why);
		}
		if(!ok){
			end_session(id, "", false);
			return 0;
		}
		log_i(MODULE, "Session %s (%s) by %s: %zu entities from the start",
				cs(itos(id)), bench ? "a bench" : draft ? "a draft" : "a game",
				cs(by),
				stash_of(id).entities.size());
		return id;
	}

	bool session_load(const json::Value &c, ss_ &why)
	{
		const uint64_t next = m_next_id;
		const bool bench = active_session()->bench;
		for(auto &sc : m_default_ctx.scenes)
			if((!bench || sc.first == m_host.world_scene) &&
					!m_host.scenes.count(sc.first) && !make_scene(sc.first, why))
				return false;
		// [KIT_PREFAB_BENCH] its World its own, not the save's row
		if(bench)
			m_store->remove("world");
		if(!load_composition(c, why))
			return false;
		m_next_id = std::max(m_next_id, next);
		if(!host_world(why))
			return false;
		for(auto &pe : m_entities)
			for(size_t i = 0; !bench && i < pe.second.comps.size(); i++){
				to_start(pe.second, i);
				Run r;
				r.entity = pe.first;
				r.comp = i;
				r.handler = "on_start";
				queue_run(r);
			}
		for(auto &p : m_entities)
			if(wants_node(p.second))
				make_node(p.second);
		own_voxels();
		pick_provider();
		sync_free_objects();
		m_runtime_dirty = true;
		return true;
	}

	// A peer out of its round (as a leave, their entity there kept) and the
	// app told to take them to the scene of that name in session `to` (0:
	// the default; there at the scene's spawn), where set_peer() joins them
	// to its round. At the top
	void move_peer(size_t peer, uint64_t to)
	{
		const uint64_t from = session_of_peer(peer);
		if(from == to || (to && !m_sessions.count(to)))
			return;
		ss_ scene;
		double pos[3] = {0.5, 1, 0.5};
		round_ends(peer, from, to);
		{
			SessionScope sc(*this, from);
			auto pi = m_peers.find(peer);
			if(pi == m_peers.end())
				return;
			scene = pi->second.scene;
			for(int k = 0; k < 3; k++)
				pos[k] = pi->second.pos[k];
			if(!to && pi->second.editing)
				m_tools_back.insert(peer);
			// [KIT_CTF] Waiting to respawn (on_signal) there, they wait no
			// more: back in that round later, they are alive at their max
			const uint64_t pid = pi->second.player;
			if(pid && player_waiting(pid)){
				set_health(pid, "waiting", false);
				const double max = health_max(pid);
				if(max > 0)
					set_health(pid, "hp", max);
				log_i(MODULE, "%s waits to respawn no more: moved out of "
						"session %s", cs(pi->second.name), cs(itos(from)));
			}
			leave_round(peer, false);
		}
		if(to)
			m_peer_session[peer] = to;
		else
			m_peer_session.erase(peer);
		// [KIT_CTF] kit/arena's `map`: into the game in that scene, and
		// back out in the arena's own
		auto msi = m_sessions.find(to ? to : from);
		const ss_ map = msi == m_sessions.end() ? "" : msi->second->map;
		if(!map.empty()){
			if(to)
				scene = map;
			else if(m_sessions.count(from)){
				SessionScope sc(*this, 0);
				auto me = m_entities.find(m_sessions[from]->maker);
				if(me != m_entities.end())
					scene_of(me->second, &scene);
			}
		}
		{
			SessionScope sc(*this, to);
			if(!m_host.scenes.count(scene))
				scene = m_host.world_scene.empty() ?
						m_host.scenes.begin()->first : m_host.world_scene;
			if(!to || !map.empty())
				scene_spawn(scene, pos[0], pos[1], pos[2]);
			// [KIT_PREFAB_BENCH] Into one: where its copy is seen from; out:
			// where they came from
			auto bi = m_sessions.find(to ? to : from);
			if(bi != m_sessions.end() && bi->second->bench){
				const GameSession &b = *bi->second;
				if(to || m_host.scenes.count(b.back_scene)){
					scene = to ? scene : b.back_scene;
					for(int k = 0; k < 3; k++)
						pos[k] = to ? b.at[k] : b.back_pos[k];
				}
			}
		}
		log_i(MODULE, "Peer %zu from session %s to session %s (scene %s)",
				peer, cs(itos(from)), cs(itos(to)), cs(app_scene(scene, to)));
		m_server->emit_event("kit:change_scene", new ChangeScene(peer,
				app_scene(scene, to), pos[0], pos[1], pos[2]));
	}

	// [KIT_INVENTORY_PLAY] A player into a game session from the default
	// round: their slots and carried numbers for its start (round_join
	// takes them by kit/arena's at_start: keep, clear or the kit); back
	// out: the round's inventory by its at_end -- "before" (the default:
	// what they had before it), keep, clear, or "living" (the round's if
	// they did not die in it) -- through the hook ("round_end": kept, gone),
	// and the numbers back. Drafts carry nothing
	void round_ends(size_t peer, uint64_t from, uint64_t to)
	{
		ss_ name;
		{
			// m_peers is a session's: the peer is in `from`'s
			SessionScope sc(*this, from);
			auto pi = m_peers.find(peer);
			if(pi != m_peers.end())
				name = pi->second.name;
		}
		if(name.empty())
			return;
		const std::set<ss_> carry = carried_keys();
		if(!from && to){
			const ss_ at_start = maker_param(to, "at_start", "kit");
			if(at_start.empty())
				return;
			auto pl = m_players.find(name);
			Carry c;
			c.at_start = at_start;
			if(pl != m_players.end()){
				c.slots = slots_of(pl->second);
				c.numbers = numbers_of(pl->second, carry);
			}
			m_carry_in[name] = c;
			return;
		}
		if(!from || to)
			return;
		const ss_ at_end = maker_param(from, "at_end", "before");
		if(at_end.empty())
			return;
		json::Value before = json::array();
		{
			auto pl = m_players.find(name);
			if(pl != m_players.end())
				before = slots_of(pl->second);
		}
		json::Value kept, gone, nums = json::object();
		{
			SessionScope sc(*this, from);
			const uint64_t pid = m_peers[peer].player;
			const Instance *own = pid ? own_inventory(pid) : nullptr;
			if(!own || !own_slots())
				return;
			const json::Value round = slots_of(pid);
			const bool died = own->state.get("died").is_true();
			const bool keep = at_end == "keep" || (at_end == "living" &&
					!died);
			kept = at_end == "before" ? before : keep ? round : json::array();
			gone = keep ? json::array() : round;
			inventory_hooks(pid, "round_end", kept, gone);
			nums = numbers_of(pid, carry);
			log_i(MODULE, "%s's round ends (at_end %s%s): %s stacks kept, %s "
					"gone", cs(name), cs(at_end), died ? ", died in it" : "",
					cs(itos(kept.size())), cs(itos(gone.size())));
		}
		auto pl = m_players.find(name);
		if(pl == m_players.end() || !own_inventory(pl->second))
			return;
		set_numbers(pl->second, nums);
		set_slots(pl->second, kept);
	}

	// A session ended: its players back in the default round, its scenes
	// dropped once they are out, its maker told (on_session_end). At the top
	void end_session(uint64_t id, const ss_ &by, bool tell = true,
			const json::Value &result = json::null())
	{
		auto it = m_sessions.find(id);
		if(it == m_sessions.end())
			return;
		sv_<size_t> peers;
		for(auto &ps : m_peer_session)
			if(ps.second == id)
				peers.push_back(ps.first);
		for(size_t peer : peers)
			move_peer(peer, 0);
		{
			SessionScope sc(*this, id);
			m_queue.clear();
			voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
				for(auto &s : m_host.scenes){
					voxelworld::Instance *w = ivw->get_instance(s.second);
					if(w){
						w->set_owner_handler("kit", nullptr);
						w->set_section_source(nullptr);
						w->set_load_points({});
					}
				}
			});
			for(auto &s : m_host.scenes){
				worldgen::access(m_server, [&](worldgen::Interface *i){
					if(i->get_instance(s.second))
						i->delete_instance(s.second);
				});
				heightmap::access(m_server, [&](heightmap::Interface *ih){
					if(ih->get_instance(s.second))
						ih->delete_instance(s.second);
				});
				if(m_server->has_module("voxel_objects"))
					voxel_objects::access(m_server, [&](
							voxel_objects::Interface *io){
						if(io->get_instance(s.second))
							io->delete_instance(s.second);
					});
				m_ref_session.erase(s.second);
			}
		}
		GameSession &s = *it->second;
		for(const ss_ &n : s.app_scenes)
			m_drop_scenes.push_back(std::make_pair(
					interface::os::time_us() + 2000000, n));
		const uint64_t maker = s.maker;
		const size_t comp = s.maker_comp;
		log_i(MODULE, "Session %s ended%s", cs(itos(id)),
				by.empty() ? "" : cs(" by "+by));
		m_sessions.erase(it);
		save_sessions();
		if(tell && maker && m_entities.count(maker)){
			Run r;
			r.entity = maker;
			r.comp = comp;
			r.handler = "on_session_end";
			r.args.append((int64_t)id);
			r.args.append(result);
			queue_run(r);
		}
		for(auto &p : m_peers)
			if(p.second.editing)
				send_state(p.first);
	}

	// The app's scenes of ended sessions, once their players are out
	void drop_scenes()
	{
		const int64_t now = interface::os::time_us();
		for(size_t i = 0; i < m_drop_scenes.size();){
			if(m_drop_scenes[i].first > now){
				i++;
				continue;
			}
			const ss_ n = m_drop_scenes[i].second;
			m_drop_scenes.erase(m_drop_scenes.begin() + i);
			m_host.drop_scene(n);
			log_i(MODULE, "Session scene %s dropped", cs(n));
		}
		save_sessions();
	}

	// [KIT_MAP_ROTATION] Whether an entity is in a map its session was not
	// picked for: the map's whole content is the copy's, as the start is, and
	// none of it runs (its timers would reach the arena's "win").
	// simplified: the map's scene is still made per session, its entities
	// still loaded; loading only the picked map would make many maps cheaper
	bool left_out(uint64_t entity)
	{
		const GameSession *gs = active_session();
		if(!gs || gs->left_out.empty())
			return false;
		auto it = m_entities.find(entity);
		ss_ scene;
		return it != m_entities.end() && scene_of(it->second, &scene) &&
				gs->left_out.count(scene);
	}

	// What the tick's runs asked of sessions, at the top
	void session_ops()
	{
		while(!m_session_ops.empty()){
			const SessionOp o = m_session_ops.front();
			m_session_ops.pop_front();
			if(o.op == "start"){
				ss_ why;
				const uint64_t id = make_session(false, o.by, o.maker, o.comp,
						why);
				if(!id){
					log_i(MODULE, "Entity %s's session refused: %s",
							cs(itos(o.maker)), cs(why));
					add_log(o.maker, "session refused: "+why);
					continue;
				}
				add_log(o.maker, "session "+itos(id)+" started");
				// (counted first: a move runs its join)
				size_t taken = 0;
				for(size_t peer : o.peers)
					taken += !session_of_peer(peer);
				m_sessions[id]->start_players = taken;
				// [KIT_MAP_ROTATION] the map asked for, else the maker's `map`
				// [KIT_CTF]; of the others never the arena's own scene
				GameSession &gs = *m_sessions[id];
				gs.map = o.map.empty() ? maker_param(id, "map", "") : o.map;
				if(!m_host.scenes.count(gs.map))
					gs.map.clear();
				gs.left_out = o.left_out;
				gs.left_out.erase(gs.map);
				auto me = m_entities.find(o.maker);
				ss_ own;
				if(me != m_entities.end() && scene_of(me->second, &own))
					gs.left_out.erase(own);
				if(!gs.map.empty())
					log_i(MODULE, "Session %s on the map %s", cs(itos(id)),
							cs(gs.map));
				for(size_t peer : o.peers)
					if(!session_of_peer(peer))
						move_peer(peer, id);
				Run r;
				r.entity = o.maker;
				r.comp = o.comp;
				r.handler = "on_session_start";
				r.args.append((int64_t)id);
				queue_run(r);
			} else if(o.op == "move"){
				for(size_t peer : o.peers)
					if(session_of_peer(peer) == o.from)
						move_peer(peer, o.target);
			} else if(o.op == "end"){
				end_session(o.target, o.by, true, o.result);
			}
		}
	}

	// A run's c:session_start(players), c:session_move(player, id),
	// c:session_end(id): the players it reaches (in its zone, the run's,
	// any for a type with `players`), the sessions it made; none from a
	// session but its own end and moves back
	void session_fx(const Entity &e, size_t comp, const Run &r,
			const json::Value &ops)
	{
		const Instance &in = e.comps[comp];
		const bool any = m_types[in.type].players;
		const uint64_t run_player = player_id(r.by);
		auto may = [&](uint64_t pid){
			return pid && (any || pid == run_player ||
					in.inside.count(itos(pid)));
		};
		auto peer_of_player = [&](uint64_t pid, size_t &peer){
			for(auto &p : m_peers)
				if(p.second.player == pid){
					peer = p.first;
					return true;
				}
			return false;
		};
		auto made_by = [&](uint64_t id){
			auto it = m_sessions.find(id);
			return it != m_sessions.end() && it->second->maker == e.id &&
					it->second->maker_comp == comp;
		};
		for(unsigned i = 0; i < ops.size() && i < 8; i++){
			const json::Value &o = ops.at(i);
			const ss_ op = jstr_at(o, 0);
			SessionOp so;
			so.op = op;
			so.from = m_active;
			so.maker = e.id;
			so.comp = comp;
			so.by = r.by;
			ss_ why;
			if(op == "start"){
				if(m_active)
					why = "no session from inside one";
				const json::Value &l = o.at(1u);
				std::set<uint64_t> want;
				if(l.is_array()){
					for(unsigned k = 0; k < l.size() && k < 64; k++)
						if(l.at(k).is_number())
							want.insert((uint64_t)std::max(0.0,
									l.at(k).as_number()));
				} else {
					for(const ss_ &x : in.inside)
						want.insert(std::stoull(x));
					if(run_player)
						want.insert(run_player);
				}
				for(uint64_t pid : want){
					size_t peer = 0;
					if(!may(pid))
						why = "player "+itos(pid)+" is none it reaches";
					else if(peer_of_player(pid, peer))
						so.peers.push_back(peer);
				}
				// [KIT_MAP_ROTATION]
				so.map = jstr_at(o, 2);
				if(!so.map.empty() && !m_host.scenes.count(so.map))
					why = "no scene "+so.map.substr(0, 32);
				const json::Value &others = o.at(3u);
				for(unsigned k = 0; others.is_array() && k < others.size() &&
						k < 64; k++)
					so.left_out.insert(jstr_at(others, k));
			} else if(op == "move"){
				const uint64_t pid = o.at(1u).is_number() ?
						(uint64_t)std::max(0.0, o.at(1u).as_number()) : 0;
				so.target = o.at(2u).is_number() ?
						(uint64_t)std::max(0.0, o.at(2u).as_number()) : 0;
				size_t peer = 0;
				if(!may(pid) || !peer_of_player(pid, peer))
					why = "player "+itos(pid)+" is none it reaches here";
				else if(m_active ? so.target != 0 : !made_by(so.target))
					why = "session "+itos(so.target)+" is none it made";
				so.peers.push_back(peer);
			} else if(op == "end"){
				so.target = o.at(1u).is_number() ?
						(uint64_t)std::max(0.0, o.at(1u).as_number()) : 0;
				if(m_active ? so.target != m_active : !made_by(so.target))
					why = "session "+itos(so.target)+" is none it made";
				// [KIT_MINIGAMES_1] its result for the maker, 4 KiB at most
				const json::Value &res = o.at(2u);
				if(!res.is_undefined() && !res.is_null() &&
						res.stringify().size() > 4096)
					why = "a result past 4096 bytes";
				else if(!res.is_undefined())
					so.result = res.deepcopy();
			} else {
				why = "no session op "+op.substr(0, 16);
			}
			if(!why.empty()){
				add_log(e.id, "session_"+op.substr(0, 16)+" refused: "+why);
				continue;
			}
			m_session_ops.push_back(so);
		}
	}

	// The rounds' sessions' stats ({"op": "sessions"}): each one's kind,
	// players, clock, entities, runtime and voxel sections
	json::Value session_stats()
	{
		json::Value a = json::array();
		sv_<uint64_t> ids = {0};
		for(auto &s : m_sessions)
			ids.push_back(s.first);
		size_t default_loaded = 0;
		for(uint64_t id : ids){
			SessionScope sc(*this, id);
			json::Value j = json::object();
			GameSession *gs = active_session();
			j.set("id", (int64_t)id);
			j.set("kind", ss_(!gs ? "default" : gs->bench ? "bench" :
					gs->draft ? "draft" : "game"));
			j.set("by", gs ? gs->by : m_session.by);
			json::Value pl = json::array();
			for(auto &p : m_peers)
				pl.append(p.second.name);
			j.set("players", pl);
			j.set("clock", (int64_t)(now_us() / 1000000));
			j.set("entities", (int64_t)m_entities.size());
			j.set("runtime", digest(runtime_json()));
			size_t loaded = 0, sourced = 0, saved = 0, altered = 0, all = 0;
			voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
				for(auto &s : m_host.scenes){
					voxelworld::Instance *w = ivw->get_instance(s.second);
					if(!w)
						continue;
					// A session's: what it changed written (its own)
					if(id)
						w->save();
					size_t l = 0, a = 0;
					sourced += w->sourced_sections(&l, &a);
					loaded += l;
					all += a;
					for(const auto &st : w->section_stats()){
						saved++;
						altered += st.altered;
					}
				}
			});
			j.set("sourced", (int64_t)sourced);
			j.set("sourced_loaded", (int64_t)loaded);
			j.set("sections", (int64_t)saved);
			j.set("altered", (int64_t)altered);
			// Its sections in memory; a session's: those it wrote, and
			// those of the default's it holds no copy of
			j.set("loaded", (int64_t)all);
			if(!id)
				default_loaded = all;
			if(gs){
				j.set("written", (int64_t)gs->written.size());
				j.set("shared", (int64_t)(default_loaded > all ?
						default_loaded - all : 0));
			}
			a.append(j);
		}
		return a;
	}

	// A builder's private draft ([KIT_SESSIONS_1]): a session of the start
	// for them alone, their tools on in it
	void make_draft(Peer &p, size_t peer,
			const std::function<void(const ss_&)> &refuse)
	{
		if(m_active)
			return refuse("in a session already");
		ss_ why;
		const uint64_t id = make_session(true, p.name, 0, 0, why);
		if(!id)
			return refuse(why);
		move_peer(peer, id);
	}

	// [KIT_PREFAB_BENCH] {"op": "prefab_bench", "prefab": name}: a clean place
	// to edit a prefab of the builder's own. A session of its own (so its own
	// entities, undo, peers and voxels, and nothing saved; a restart drops it):
	// an empty infinite World of their scene's look, the components not running,
	// one copy at the origin, its voxels laid out as their sections load. Its
	// Save is the root's save_prefab; the project's copies follow it
	// (bench_follow()). {"op": "leave_draft"} ends it, as does leaving.
	// One a builder, for them alone; MAX_SESSIONS with the others
	void prefab_bench(Peer &p, size_t peer, const json::Value &j,
			const std::function<void(const ss_&)> &refuse)
	{
		if(m_active)
			return refuse("in a session already");
		const ss_ name = jstr(j, "prefab");
		const json::Value *pf = prefab(name);
		if(!pf)
			return refuse("no prefab \""+name.substr(0, 130)+"\"");
		const ss_ author = prefab_author(p);
		if(author.empty() || name.compare(0, author.size() + 1, author+"/") != 0
				|| !jstr(*pf, "package").empty())
			return refuse(name+" is not yours: Make prefab makes one of your "
					"own of it");
		const uint64_t from = scene_id(p.scene);
		if(!from || m_host.world_scene.empty() || !world_named(p.scene))
			return refuse("not in a scene with a World");
		json::Value looks;
		{
			WorldScope ws(m_w, world_named(p.scene));
			looks = world_params();
		}
		const uint64_t sid = m_next_id;
		m_next_id += 2;
		json::Value es = json::array(), sc = json::object(), wo = json::object(),
				comps = json::array(), comp = json::object(),
				params = json::object();
		sc.set("id", (int64_t)sid);
		sc.set("parent", (int64_t)1);
		sc.set("name", m_host.world_scene);
		sc.set("kind", "scene");
		es.append(sc);
		for(const char *k : {"biome", "materials", "sky_light"})
			if(!looks.get(k).is_undefined())
				params.set(k, looks.get(k));
		params.set("generator", "empty");
		params.set("size", "infinite");
		params.set("surface", "voxels");
		params.set("decorations", false);
		params.set("caves", false);
		comp.set("type", "kit/world");
		comp.set("params", params);
		comps.append(comp);
		wo.set("id", (int64_t)(sid + 1));
		wo.set("parent", (int64_t)sid);
		wo.set("name", "World");
		wo.set("components", comps);
		es.append(wo);
		// Its environment too: the same light
		for(auto &pe : m_entities){
			if(pe.second.parent != from || pe.second.has_pos)
				continue;
			bool env = false;
			for(const Instance &i : pe.second.comps)
				env = env || i.type == "kit/environment";
			if(!env)
				continue;
			Entity c = pe.second;
			c.id = m_next_id++;
			c.parent = sid;
			for(Instance &i : c.comps)
				i.links.clear();
			es.append(entity_json(c));
		}
		json::Value all = json::object();
		all.set("entities", es);
		all.set("next_id", (int64_t)m_next_id);
		ss_ why;
		const uint64_t id = make_session(true, p.name, 0, 0, why, &all, p.scene);
		if(!id)
			return refuse(why);
		GameSession &gs = *m_sessions[id];
		gs.prefab = name;
		for(int k = 0; k < 3; k++)
			gs.back_pos[k] = p.pos[k];
		const json::Value &vx = pf->get("voxels");
		gs.at[0] = 0.5;
		gs.at[1] = 2;
		gs.at[2] = -7.5;
		if(vx.is_object()){
			const json::Value &a = vx.get("at"), &n = vx.get("size");
			json::Value box = json::array();
			for(unsigned k = 0; k < 3; k++)
				box.append(a.at(k));
			for(unsigned k = 0; k < 3; k++)
				box.append(a.at(k).as_number() + n.at(k).as_number() - 1);
			gs.box = box;
			gs.stamp = vx.deepcopy();
			gs.at[0] = a.at(0u).as_number() + n.at(0u).as_number() / 2;
			gs.at[1] = a.at(1u).as_number() + n.at(1u).as_number() + 2;
			gs.at[2] = a.at(2u).as_number() - 8;
		}
		bool ok = false;
		{
			SessionScope scope(*this, id);
			Peer t;
			t.name = p.name;
			t.scene = m_host.world_scene;
			json::Value a = json::object(), pos = json::array();
			for(int k = 0; k < 3; k++)
				pos.append((int64_t)0);
			a.set("prefab", name);
			a.set("pos", pos);
			sv_<std::pair<uint64_t, json::Value>> change;
			ss_ what;
			m_paste = VoxelPaste();
			ok = place_prefab(a, t, change, what, why);
			m_paste.set = false;
			if(ok){
				gs.root = change[0].first;
				// A prefab with no place too: the box's frame is the root's
				if(change[0].second.get("pos").is_undefined())
					change[0].second.set("pos", pos);
				ok = rebuilds(change, t, what, why);
			}
			if(ok)
				commit(change, nullptr);
		}
		if(!ok){
			end_session(id, "", false);
			return refuse(why);
		}
		log_i(MODULE, "%s edits the prefab %s in session %s", cs(p.name), cs(name),
				cs(itos(id)));
		move_peer(peer, id);
	}

	// The bench's copy's voxels, as their sections are there; a Save waits for
	// them, or it would lose those not laid out. Entered
	void bench_stamp()
	{
		GameSession *gs = active_session();
		const int64_t now = interface::os::time_us();
		if(!gs || !gs->stamp.is_object() || now < gs->stamp_next)
			return;
		gs->stamp_next = now + 500000;
		auto si = m_host.scenes.find(m_host.world_scene);
		if(si == m_host.scenes.end())
			return;
		Change nc;
		const int base[3] = {0, 0, 0};
		size_t written = 0, missing = 0, unknown = 0;
		write_voxels(gs->stamp, si->second, base, 0, nc, gs->by, written, missing,
				unknown);
		gs->stamped += written;
		if(missing)
			return;
		gs->stamp = json::null();
		log_i(MODULE, "The prefab %s's voxels laid out in session %s: %zu",
				cs(gs->prefab), cs(itos(m_active)), gs->stamped);
		for(auto &o : m_peers)
			send_state(o.first);
		// A Save drops what the scene has no voxel for: said now
		if(unknown)
			warn("the prefab "+gs->prefab+" has "+itos(unknown)+" voxels of types "
					"this scene has not: not shown, and a Save drops them");
	}

	// A save in a bench: its own round's copies followed in rebuilds(); the
	// project's follow here. No undo: the temporary scene's history stays its
	// own, and the project's has nothing of it.
	// simplified: others' drafts' copies do not follow (as a save from a draft)
	void bench_follow(Peer &p)
	{
		const ss_ name = m_bench_saved;
		m_bench_saved.clear();
		SessionScope sc(*this, 0);
		sv_<std::pair<uint64_t, json::Value>> change;
		ss_ what, why;
		m_follow = name;
		m_follow_source = 0;
		if(!rebuilds(change, p, what, why)){
			m_follow.clear();
			log_w(MODULE, "The copies of %s do not follow: %s", cs(name), cs(why));
			return;
		}
		if(change.empty())
			return;
		commit(change, nullptr);
		world_check(p.name);
		log_i(MODULE, "The project's copies of %s follow:%s", cs(name), cs(what));
	}

	// Publish: the entities the draft's edits changed, as the draft has
	// them, into the default's composition (one edit, one undo), and the
	// cells its builds and edits wrote into the start, as live edits. The
	// draft goes on, its edits published
	void publish(Peer &p, const std::function<void(const ss_&)> &refuse)
	{
		GameSession *s = active_session();
		if(!s || !s->draft)
			return refuse("not in a draft");
		const ss_ name = p.name;
		sv_<std::pair<uint64_t, json::Value>> change;
		for(uint64_t id : s->touched){
			auto it = m_entities.find(id);
			change.push_back(std::make_pair(id, it == m_entities.end() ||
					!authored(it->second) ? json::null() :
					entity_json(it->second)));
		}
		sv_<Write> cells;
		size_t unknown = 0;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			for(auto &sec : m_marks){
				const ss_ scene = sec.first.substr(0, sec.first.find(':'));
				auto si = m_host.scenes.find(scene);
				auto di = m_default_ctx.scenes.find(scene);
				voxelworld::Instance *w = si == m_host.scenes.end() ? nullptr :
						ivw->get_instance(si->second);
				if(!w || di == m_default_ctx.scenes.end()){
					unknown += sec.second.size();
					continue;
				}
				for(auto &c : sec.second){
					Write wr;
					wr.scene = di->second;
					wr.p = pv::Vector3DInt32(std::get<0>(c.first),
							std::get<1>(c.first), std::get<2>(c.first));
					const interface::VoxelDefinition *d = w->get_voxel_reg()->
							get(w->get_voxel_reg()->get_format().id.get(
							w->get_voxel(wr.p).data));
					if(!d){
						unknown++;
						continue;
					}
					wr.voxel = d->name.block_name;
					wr.by = name;
					wr.origin = 'k';
					cells.push_back(wr);
				}
			}
		});
		for(auto &sec : m_marks)
			m_marks_dirty.insert(sec.first);
		m_marks.clear();
		s->touched.clear();
		const uint64_t id = m_active;
		SessionScope sc(*this, 0);
		// simplified: the draft's entity as it has it, over what the default
		// made of it meanwhile (no merge)
		if(!change.empty()){
			commit(change, &m_undo[name]);
			world_check(name);
		}
		for(const Write &w : cells)
			m_start_writes.push_back(w);
		log_i(MODULE, "%s publishes draft %s: %zu entities, %zu cells%s",
				cs(name), cs(itos(id)), change.size(), cells.size(),
				unknown ? cs(", "+itos(unknown)+" not read") : "");
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_kit(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
