// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// A Luanti game's own Lua -- its builtin layer and a game's mods -- running
// inside buildat_server. Luanti's network protocol is nowhere in this; the
// game logic is Luanti's and everything around it is buildat's. See
// doc/luanti_module.txt and doc/plan/luanti_module_plan.md.
//
// This file is deliberately thin. Lua 5.1 comes with io and os, so reading
// files, splitting paths and running chunks all happen in Lua; the only
// things C++ has that Lua does not are a directory listing, the log and the
// clock. The arrangement -- what a mod is, what order mods load in, what the
// core table holds -- is in lua/ beside this file, where it can be read.
#include "luanti/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "luanti_mapgen/api.h"
#include "storage/api.h"
#include "main_context/api.h"
#include "client_file/api.h"
#include "network/api.h"
#include "accounts/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/voxel.h"
#include "interface/mutex.h"
#include "interface/sha1.h"
#include "interface/sha256.h"
#include "interface/compress.h"
#include "interface/noise.h"
#include "luanti/mapblock.h"
#include "luanti/shapes.h"
#include "luanti/node_registry.h"
#include "luanti/media.h"
#include "luanti/session.h"
#include <sqlite3.h>
#include <fstream>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <unordered_map>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
#include "interface/polyvox_cereal.h"
extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>
}
// LuaJIT's bit library, which Luanti's mods use as if it were part of the
// language. Luanti loads this same file -- Mike Pall's Lua BitOp -- when it
// is not running on LuaJIT, and the Lua here is Urho3D's 5.1, so it always
// does. A module is one translation unit, so the implementation comes in
// with the header.
#include "vendor/bitop/bit.h"
#include "vendor/bitop/bit.cpp"
// Luanti's core.encode_png() is a real function of its API and devtest checks
// what comes out of it, so it is written rather than stubbed. Urho3D ships
// stb_image_write but does not export it, so it is compiled in here; it is
// one header and the only C++ in this file that is not glue.
#include <Scene.h>
#include <Node.h>
#include <StaticModel.h>
#include <Model.h>
#include <Material.h>
#include <ResourceCache.h>
#include <Image.h>
#include <MemoryBuffer.h>
#include <Context.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <STB/stb_image_write.h>
#define MODULE "luanti"
// The Module's parts ([LUANTI_MODULAR]), after MODULE, which they log as
#include "luanti/lua_util.h"
#include "luanti/mapgen_params.h"
#include "luanti/registry.h"
#include "luanti/import.h"

using interface::Event;
namespace pv = PolyVox;
namespace magic = Urho3D;
using namespace luanti_shapes;
using namespace luanti_registry;

namespace luanti {


using main_context::SceneReference;

// A sampling profiler for the module's Lua, behind BUILDAT_LUANTI_LUAPROF.
//
// What it answers is a porter's question -- which of my two hundred mods,
// and which function in it, is costing the startup or the step -- and it
// answers it on a build they already have: set the variable and read the
// report at shutdown. A tool that wants a rebuild is a tool nobody uses.
//
// Sampling rather than LUA_MASKCALL: an instrumenting hook distorts exactly
// the small hot functions this is looking for, and the count hook is one
// branch per N instructions. The default N is 10000, which is about a
// percent of the run's time on this machine; BUILDAT_LUANTI_LUAPROF=<n>
// sets it.
//
// One state, one thread, so a plain map and no locking. Attribution is to
// the function the sample landed in -- short_src:linedefined -- which is
// what a name means in Lua once a mod has built half its callbacks out of
// closures.
struct LuaProfiler
{
	bool enabled = false;
	int interval = 10000;
	sm_<ss_, size_t> samples;
	size_t total = 0;
};
static LuaProfiler g_lua_prof;

// A step that has not come back. The module's thread does one thing at a
// time, so a step that runs for minutes is a server that answers nothing --
// and the step's own timing line cannot say so, because it prints when the
// step ends. This says it while it is still going, once, with the Lua stack
// it is standing on.
//
// It rides the same count hook as the profiler and costs a comparison per N
// instructions. The interval is coarse when nothing is being profiled,
// because all this needs is to notice within a second or two of a deadline
// that is tens of seconds long.
struct StepWatchdog
{
	int64_t deadline_us = 0;
	bool warned = false;
	int64_t started_us = 0;
};
static StepWatchdog g_step_watch;

static void lua_step_watchdog(lua_State *L)
{
	if(g_step_watch.deadline_us == 0 || g_step_watch.warned)
		return;
	const int64_t now = interface::os::time_us();
	if(now < g_step_watch.deadline_us)
		return;
	g_step_watch.warned = true;
	log_w(MODULE, "a step has been running for %.0f s and has not come "
			"back; where its Lua is standing now:",
			(now - g_step_watch.started_us) / 1e6);
	lua_Debug d;
	for(int level = 0; level < 24; level++){
		if(!lua_getstack(L, level, &d))
			break;
		if(!lua_getinfo(L, "Sln", &d))
			break;
		log_w(MODULE, "  #%d %s:%d %s%s", level, d.short_src, d.currentline,
				d.name != nullptr ? d.name : "?",
				d.name != nullptr ? "()" : "");
	}
}

// __luanti_bounded_pcall(f, budget) -> ok, result: f run interpreted --
// LuaJIT's compiled loops do not reach a count hook -- with an error after
// `budget` instructions, and the hook that was on (the watchdog, the
// profiler) put back as it was. Lua's own debug.sethook cannot do the last
// part: a C hook comes back from debug.gethook as a string. What
// core.deserialize runs saved data through ([SECURITY_RUN_1]).
static void bounded_hook(lua_State *L, lua_Debug *ar)
{
	luaL_error(L, "the data runs too long");
}

static int l_bounded_pcall(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TFUNCTION);
	const int budget = luaL_checkint(L, 2);
	lua_Hook old = lua_gethook(L);
	const int old_mask = lua_gethookmask(L);
	const int old_count = lua_gethookcount(L);
	luaJIT_setmode(L, 1, LUAJIT_MODE_ALLFUNC | LUAJIT_MODE_OFF);
	lua_sethook(L, bounded_hook, LUA_MASKCOUNT, budget > 0 ? budget : 1);
	lua_pushvalue(L, 1);
	const int r = lua_pcall(L, 0, 1, 0);
	lua_sethook(L, old, old_mask, old_count);
	lua_pushboolean(L, r == 0);
	lua_insert(L, -2);
	return 2;
}

static void lua_prof_hook(lua_State *L, lua_Debug *ar)
{
	lua_step_watchdog(L);
	if(!g_lua_prof.enabled)
		return;
	if(!lua_getinfo(L, "Sn", ar))
		return;
	ss_ key = ss_(ar->short_src) + ":" + itos(ar->linedefined);
	if(ar->name != nullptr)
		key += ss_(" ") + ar->name + "()";
	g_lua_prof.samples[key]++;
	g_lua_prof.total++;
}

// Every function the samples landed in, most first. Called at shutdown, and
// cheap enough to call whenever else somebody wants one -- which is what
// core.__lua_profile() is for: a run's startup, its world generation and
// its first minute with a player in it are three different questions, and
// one report over all of them answers none of them.
static void lua_prof_report(const ss_ &label = "")
{
	if(!g_lua_prof.enabled || g_lua_prof.total == 0)
		return;
	const ss_ tag = label.empty() ? ss_("Lua profile") :
			ss_("Lua profile [")+label+"]";
	sv_<std::pair<ss_, size_t>> sorted(
			g_lua_prof.samples.begin(), g_lua_prof.samples.end());
	std::sort(sorted.begin(), sorted.end(),
			[](const std::pair<ss_, size_t> &a,
					const std::pair<ss_, size_t> &b){
		return a.second > b.second;
	});
	log_i(MODULE, "%s: %zu samples, every %i instructions", cs(tag),
			g_lua_prof.total, g_lua_prof.interval);
	for(size_t i = 0; i < sorted.size() && i < 40; i++){
		const double share = 100.0 * sorted[i].second / g_lua_prof.total;
		if(share < 0.1)
			break;
		log_i(MODULE, "%s: %5.1f%% %6zu  %s", cs(tag), share,
				sorted[i].second, cs(sorted[i].first));
	}
}

// __luanti_copy_ints(dst, src) -> dst: src's array part into dst's, in C.
//
// A mod that hands VoxelManip:get_data() a buffer to fill is doing the
// thing Luanti's own documentation tells it to -- reusing one table
// instead of making half a million entries a chunk -- and Luanti fills it
// in C. Filled in Lua it was **a third of all the Lua time** a VoxeLibre
// world spent in its first fifteen seconds with a player in it, because a
// mapgen chunk is 512000 elements and the loop pays the interpreter for
// every one of them.
static int l_copy_ints(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checktype(L, 2, LUA_TTABLE);
	const size_t n = lua_objlen(L, 2);
	for(size_t i = 1; i <= n; i++){
		lua_rawgeti(L, 2, (int)i);
		lua_rawseti(L, 1, (int)i);
	}
	lua_pushvalue(L, 1);
	return 1;
}

// The nested tables Luanti's NoiseMap:get_2d_map() and get_3d_map() answer
// with, built from the flat array in C.
//
// Luanti builds them in C too. Built with Lua loops they were 7.7% of the
// time VoxeLibre's two hundred mods took to load, because a mod that asks
// for a big map asks for a very big one -- mcl_end_island's is 401 x 30 x
// 401, which is four and a half million entries and as many table writes.
//
// __luanti_nest_2d(flat, sx, sy) -> out[y][x], and
// __luanti_nest_3d(flat, sx, sy, sz) -> out[x][y][z], which are the two
// orders Luanti's own API builds them in.
static int l_nest_2d(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	const int sx = (int)luaL_checkinteger(L, 2);
	const int sy = (int)luaL_checkinteger(L, 3);
	lua_createtable(L, sy, 0);
	for(int y = 1; y <= sy; y++){
		lua_createtable(L, sx, 0);
		for(int x = 1; x <= sx; x++){
			lua_rawgeti(L, 1, (y - 1) * sx + x);
			lua_rawseti(L, -2, x);
		}
		lua_rawseti(L, -2, y);
	}
	return 1;
}

static int l_nest_3d(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	const int sx = (int)luaL_checkinteger(L, 2);
	const int sy = (int)luaL_checkinteger(L, 3);
	const int sz = (int)luaL_checkinteger(L, 4);
	lua_createtable(L, sx, 0);
	for(int x = 1; x <= sx; x++){
		lua_createtable(L, sy, 0);
		for(int y = 1; y <= sy; y++){
			lua_createtable(L, sz, 0);
			for(int z = 1; z <= sz; z++){
				lua_rawgeti(L, 1, ((z - 1) * sy + (y - 1)) * sx + x);
				lua_rawseti(L, -2, z);
			}
			lua_rawseti(L, -2, y);
		}
		lua_rawseti(L, -2, x);
	}
	return 1;
}

// core.__lua_profile(label): what has been sampled since the last call,
// under a name, and then the counters start again. A probe calls it at the
// edges of whatever it wants measured.
static int l_lua_profile(lua_State *L)
{
	const char *label = lua_tostring(L, 1);
	lua_prof_report(label ? label : "");
	g_lua_prof.samples.clear();
	g_lua_prof.total = 0;
	return 0;
}



// The Lua state's own log lines land here, so a mod's core.log() is a buildat
// log line with the mod's level
static void log_from_lua(const ss_ &level, const ss_ &text)
{
	if(level == "error")
		log_e(MODULE, "%s", cs(text));
	else if(level == "warning")
		log_w(MODULE, "%s", cs(text));
	else if(level == "verbose" || level == "debug" || level == "deprecated")
		log_v(MODULE, "%s", cs(text));
	else if(level == "trace")
		log_t(MODULE, "%s", cs(text));
	else
		log_i(MODULE, "%s", cs(text));
}

static int l_log(lua_State *L)
{
	ss_ level = "action";
	ss_ text;
	if(lua_gettop(L) >= 2){
		level = lua_tostring(L, 1) ? lua_tostring(L, 1) : "action";
		text = lua_tostring(L, 2) ? lua_tostring(L, 2) : "";
	} else {
		text = lua_tostring(L, 1) ? lua_tostring(L, 1) : "";
	}
	log_from_lua(level, text);
	return 0;
}

static int l_get_us_time(lua_State *L)
{
	lua_pushnumber(L, (lua_Number)interface::os::time_us());
	return 1;
}

// The one thing Lua 5.1 cannot do for itself. Returns an array of
// {name=..., is_directory=...}, or an empty array for a path that is not a
// directory -- a caller that cares checks with io.open first.
static int l_list_dir(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	lua_newtable(L);
	int i = 1;
	try {
		for(const interface::fs::Node &n : interface::fs::list_directory(path)){
			if(n.name == "." || n.name == "..")
				continue;
			lua_newtable(L);
			lua_pushstring(L, n.name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushboolean(L, n.is_directory);
			lua_setfield(L, -2, "is_directory");
			lua_rawseti(L, -2, i++);
		}
	} catch(...){
		// A path that is not there is an empty listing, which is what every
		// caller here wants
	}
	return 1;
}

// Whether anything is at a path, file or directory. Luanti has
// core.path_exists() and a game uses it to decide whether its own data is
// there -- capturetheflag asks before reading each of its maps.
static int l_path_exists(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	bool exists = false;
	try {
		exists = interface::fs::path_exists(path);
	} catch(...){
		exists = false;
	}
	lua_pushboolean(L, exists);
	return 1;
}

static int l_create_directories(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	lua_pushboolean(L, interface::fs::create_directories(path));
	return 1;
}

// (width, height, components, pixel bytes) -> a PNG. The caller decided how
// many components the image wants; see core.encode_png in lua/png.lua.
static void png_write_cb(void *context, void *data, int size)
{
	ss_ *out = (ss_*)context;
	out->append((const char*)data, size);
}

// core.sha1(data, raw) and core.sha256(data, raw): the digest as hex unless
// the raw bytes are asked for. Luanti has both and mods hash with them.
static int l_sha1(lua_State *L)
{
	size_t n = 0;
	const char *p = luaL_checklstring(L, 1, &n);
	ss_ raw = interface::sha1::calculate(ss_(p, n));
	if(lua_toboolean(L, 2)){
		lua_pushlstring(L, raw.c_str(), raw.size());
		return 1;
	}
	ss_ hex = interface::sha1::hex(raw);
	lua_pushlstring(L, hex.c_str(), hex.size());
	return 1;
}

static int l_sha256(lua_State *L)
{
	size_t n = 0;
	const char *p = luaL_checklstring(L, 1, &n);
	ss_ raw = interface::sha256::calculate(ss_(p, n));
	if(lua_toboolean(L, 2)){
		lua_pushlstring(L, raw.c_str(), raw.size());
		return 1;
	}
	ss_ hex = interface::sha256::hex(raw);
	lua_pushlstring(L, hex.c_str(), hex.size());
	return 1;
}

// core.compress(data, method, level) and core.decompress(data, method), with
// the three methods Luanti has: "deflate" is zlib's own framing,
// "raw_deflate" the same stream without it, and "zstd" what a mapblock is in.
static int l_compress(lua_State *L)
{
	size_t n = 0;
	const char *p = luaL_checklstring(L, 1, &n);
	ss_ data(p, n);
	ss_ method = luaL_optstring(L, 2, "deflate");
	int level = (int)luaL_optinteger(L, 3, method == "zstd" ? 3 : 6);
	std::ostringstream os(std::ios::binary);
	try {
		if(method == "deflate")
			interface::compress_zlib(data, os, level);
		else if(method == "raw_deflate")
			interface::compress_deflate_raw(data, os, level);
		else if(method == "zstd")
			interface::compress_zstd(data, os, level);
		else
			return luaL_error(L, "compress(): no such method: %s",
					method.c_str());
	} catch(std::exception &e){
		return luaL_error(L, "compress(): %s", e.what());
	}
	ss_ out = os.str();
	lua_pushlstring(L, out.c_str(), out.size());
	return 1;
}

static int l_decompress(lua_State *L)
{
	size_t n = 0;
	const char *p = luaL_checklstring(L, 1, &n);
	ss_ data(p, n);
	ss_ method = luaL_optstring(L, 2, "deflate");
	std::ostringstream os(std::ios::binary);
	try {
		if(method == "zstd"){
			interface::decompress_zstd(data, os);
		} else {
			std::istringstream is(data, std::ios::binary);
			if(method == "deflate")
				interface::decompress_zlib(is, os);
			else if(method == "raw_deflate")
				interface::decompress_deflate_raw(is, os);
			else
				return luaL_error(L, "decompress(): no such method: %s",
						method.c_str());
		}
	} catch(std::exception &e){
		return luaL_error(L, "decompress(): %s", e.what());
	}
	ss_ out = os.str();
	lua_pushlstring(L, out.c_str(), out.size());
	return 1;
}

static int l_encode_png(lua_State *L)
{
	int w = luaL_checkinteger(L, 1);
	int h = luaL_checkinteger(L, 2);
	int components = luaL_checkinteger(L, 3);
	size_t data_len = 0;
	const char *data = luaL_checklstring(L, 4, &data_len);
	if(w <= 0 || h <= 0 || components < 1 || components > 4)
		return luaL_error(L, "encode_png: bad size or component count");
	if(data_len != (size_t)w * (size_t)h * (size_t)components)
		return luaL_error(L, "encode_png: %d bytes for %dx%dx%d",
				(int)data_len, w, h, components);
	ss_ out;
	if(!stbi_write_png_to_func(png_write_cb, &out, w, h, components,
			data, w * components))
		return luaL_error(L, "encode_png: failed");
	lua_pushlstring(L, out.c_str(), out.size());
	return 1;
}

// 21 bits each, which covers Luanti's +-31000 map many times over
static int64_t pos_key(int32_t x, int32_t y, int32_t z)
{
	return ((int64_t)(x & 0x1fffff) << 42) |
			((int64_t)(y & 0x1fffff) << 21) |
			((int64_t)(z & 0x1fffff));
}

struct Module: public interface::Module, public luanti::Interface,
		public luanti_session::Game
{
	interface::Server *m_server;
	lua_State *m_lua = nullptr;
	// Two of this module's handlers can be inside Lua at once: a queued
	// core:tick runs on the module's own thread while core:shutdown is
	// emitted synchronously from another, and the server does not serialise
	// the two. One lua_State under two threads is a crash, and a step that
	// does real work -- the ABM sweep -- is long enough to hit it every
	// time. Everything that enters Lua takes this first.
	//
	// simplified: the engine is what should serialise a module's handlers,
	// and then this would be unnecessary. It is one mutex here against a
	// change to how every module is called; see ModuleThread::handle_event
	// in src/server/state.cpp, which takes no lock where emit_event_sync
	// takes the container's.
	interface::Mutex m_lua_mutex;
	// What the server is doing while a game loads; see set_progress_handler()
	std::function<void(const ss_ &)> m_progress;
	// The voxel a generated section is filled with; see
	// on_generation_request(). Zero until the first section is generated,
	// which is after the mods have loaded and named it.
	uint32_t m_singlenode_word = 0;
	// What the world's generator was built from, kept for the questions a
	// mapgen can answer without generating: where the ground is
	luanti_mapgen::Params m_mapgen_params;
	// The texture modifier expressions the game's nodes are drawn with, by
	// the resource name each is composed under. The client is what composes
	// them; this is what it is sent when it asks.
	sm_<ss_, ss_> m_texmods;
	// Seconds until the startup tables are served as files a second time;
	// see the tick
	float m_startup_files_wait = 5.0f;
	// Peers that asked for the texture modifiers while the game's media
	// was still on its way to them: the launcher's own client is
	// connected before the game is chosen, so the media is announced
	// after the join and composing over it fails until it has arrived
	// ([FIRST_RUN]). Answered on client_file:files_transmitted.
	std::set<network::PeerInfo::Id> m_texmods_waiting;
	std::set<network::PeerInfo::Id> m_files_transmitted;
	// Whether the save has node metadata in it, so that a world that has
	// none does not get a blob written for it every shutdown
	bool m_had_node_meta = false;
	// The same for the players; a world nobody has been in stays that way
	bool m_had_players = false;
	// [COMPAT_BREAK_07] 8h: a players row or a clock this cannot read (a
	// newer Buildat's) is kept rather than written over
	bool m_players_unreadable = false;
	bool m_clock_unreadable = false;
	// Which client a player is, so that what is sent to one has somewhere to
	// go, and which player a client is, for what comes back. Whoever names a
	// player says which peer it is; see add_player().
	sm_<ss_, size_t> m_player_peers;
	sm_<size_t, ss_> m_peer_players;
	bool m_game_running = false;
	// What load_lua() was handed before run_game(), in the order it came
	sv_<std::pair<ss_, ss_>> m_pending_lua;

	// The map. One voxelworld instance, in a scene of this module's own: the
	// module is what knows the Luanti world's shape, its node ids and its
	// light, so it is what owns them. The launcher is told about the scene by
	// luanti:game_loaded.
	SceneReference m_scene = nullptr;
	// The save the world is. Opened by whoever called run_game(), and theirs
	// to close; the store is this module's own namespace in it, holding what
	// is not the map -- the clock so far.
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	// The world's bounds in sections. A section is voxelworld's load and
	// unload unit and sixty-four voxels a side; Luanti's map limit is 31000
	// voxels in every direction, which is this many of them. Nothing outside
	// is ever loaded and the sky is above the top of it -- what is loaded is
	// what the load points below keep, which is far less.
	static const int32_t MAP_LIMIT_SECTIONS = 484;
	pv::Region m_section_region{
			pv::Vector3DInt32(-MAP_LIMIT_SECTIONS, -MAP_LIMIT_SECTIONS,
					-MAP_LIMIT_SECTIONS),
			pv::Vector3DInt32(MAP_LIMIT_SECTIONS, MAP_LIMIT_SECTIONS,
					MAP_LIMIT_SECTIONS)};
	// Luanti's three ranges, in the same descending order and for the same
	// reasons, in sections rather than its blocks of sixteen voxels:
	// max_block_send_distance (12 blocks) is the client's own and capped by
	// the load radius, max_block_generate_distance (10) is what is filled,
	// and active_block_range (4 blocks, which is exactly one section) is
	// what the ABM and LBM sweeps touch.
	// **How far out is the server's to decide, not the client's**
	// (user, 2026-09-26): a player who asks for a view range of four
	// hundred is asking this machine to keep and to make that much world,
	// and a public server has to be able to say no. So the two radii are
	// Luanti's own settings -- `max_block_send_distance` (12 blocks of
	// sixteen nodes, which is the 3 sections this used to hard-code) and
	// `max_block_generate_distance` (10 blocks, the old 2) -- read once
	// when the mods have loaded. A client's request is capped by the load
	// radius in voxelworld, which sends the smaller of the two.
	int16_t m_load_radius_xz = 3;
	int16_t m_generate_radius_xz = 2;
	// **Y does not grow with XZ.** Terrain worth generating at three
	// hundred nodes out is the band the player's eye is in; a mapgen asked
	// for a sphere spends most of it on sky and on stone a hundred and
	// fifty nodes down that nobody at that distance will look at. Which
	// band is right is the mapgen's business and this is a heuristic, not
	// a truth (user, 2026-09-26), so the vertical radii stay where they
	// are while the horizontal ones follow the setting.
	static const int16_t LOAD_RADIUS_Y = 2;
	static const int16_t GENERATE_RADIUS_Y = 1;
	static const int32_t ACTIVE_RADIUS = 1;
	// The world around the origin, which is where a mod puts things while
	// the game loads and where a player with nowhere else to be spawns. It
	// is what the world was in its entirety before it streamed.
	static const int16_t SPAWN_RADIUS = 1;
	// Taller than it is wide, because what the spawn needs is the ground
	// under the origin and a mapgen can put that a long way down -- an ocean
	// trench, a deep valley. A column too short is a player left in the air
	// at the origin with nothing under them to stand on.
	static const int16_t SPAWN_RADIUS_Y = 2;
	// How many sections a streaming pass may take on, which goes down while
	// a mod's mapgen is slow; see run_on_generated(), and is nothing at all
	// while a world is being imported into this one
	size_t m_stream_budget = 2;
	// Where each player is, in voxels. Written by set_player_pos() a few
	// times a second and read once a step; it is what the world streams
	// around, and what says which sections are active.
	sm_<ss_, pv::Vector3DInt32> m_player_pos;
	pv::Vector3DInt16 m_section_size{0, 0, 0};
	// While a mapgen mod's on_generated runs: what it wrote, as a box, so
	// that the one relight it gets afterwards covers it ([STEP_SLICE])
	bool m_gen_writing = false;
	bool m_gen_wrote = false;
	pv::Region m_gen_bbox;
	void note_gen_write(const pv::Region &r)
	{
		if(!m_gen_writing)
			return;
		if(!m_gen_wrote){
			m_gen_bbox = r;
			m_gen_wrote = true;
			return;
		}
		const pv::Vector3DInt32 a = m_gen_bbox.getLowerCorner(),
				b = m_gen_bbox.getUpperCorner(),
				c = r.getLowerCorner(), d = r.getUpperCorner();
		m_gen_bbox = pv::Region(
				pv::Vector3DInt32(std::min(a.getX(), c.getX()),
					std::min(a.getY(), c.getY()), std::min(a.getZ(), c.getZ())),
				pv::Vector3DInt32(std::max(b.getX(), d.getX()),
					std::max(b.getY(), d.getY()), std::max(b.getZ(), d.getZ())));
	}
	// The media the game shipped, name -> path: a tile naming one can be
	// handed to the client as it is, and a palette has to be read here
	sm_<ss_, ss_> m_served_media;
	Registry m_registry{m_server, m_lua, m_lua_mutex, m_served_media,
			m_texmods, [this](const sv_<ss_> &names){
				serve_node_textures(names);
			}};

	// The write-behind buffer. core.set_node writes here and voxelworld sees
	// it once per Luanti step, inside a single access() -- one commit covers
	// every chunk the step touched, instead of a skylight pass and a 32^3
	// serialize-and-replicate per node placed. core.get_node reads through
	// it, because Luanti's semantics are that a write is visible immediately
	// and the callbacks in the same step will look.
	// by_player: written while a player's action was handled ([SAVE_LIMIT]),
	// which makes its section altered and keeps it out of a trim
	struct PendingNode { int32_t x, y, z; uint32_t word; bool by_player; };
	bool m_by_player = false;
	// Around what the engine calls for a player -- a dig, a place, a use, a
	// chat command, a formspec's fields: what the game writes meanwhile is
	// that player's. simplified: what it sets going (a fire, TNT's chain)
	// is the world's own once the call returns.
	struct PlayerCause {
		bool &flag, was;
		PlayerCause(bool &flag, bool on = true): flag(flag), was(flag)
		{
			flag = was || on;
		}
		~PlayerCause(){ flag = was; }
	};
	std::unordered_map<int64_t, PendingNode> m_node_writes;

	// Luanti steps at dedicated_server_step (0.09 s), buildat ticks at 30 Hz;
	// a mod's globalstep dtime is written against the former
	static constexpr float STEP_S = 0.09f;
	// How often the clients are told what time it is
	static constexpr float TIME_INTERVAL_S = 5.0f;
	float m_time_accum = 0.0f;
	// The map check, which waits for the sections it uses; see
	// start_check_map()
	bool m_check_map_pending = false;
	float m_check_map_waited = 0.0f;
	sv_<pv::Vector3DInt16> m_check_sections;
	sv_<uint64_t> m_check_pinned;
	// Sections a generator has been over and whose voxels have arrived;
	// kept only while the check is waiting for its own
	std::set<uint64_t> m_generated_sections;
	float m_step_accum = 0.0f;
	// The longest step a game is told about. Luanti's own dedicated server
	// caps its dtime the same way: time nobody can make up is time to let
	// go of, and a mod that is handed ten seconds at once does something
	// silly with them.
	static constexpr float MAX_STEP_S = 0.5f;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		// The generator is luanti_mapgen's code and worldgen's to run.
		// Taken out while luanti_mapgen is still loaded -- it unloads
		// after this, and worldgen after both -- and set_generator()
		// waits for a generate() in progress to return.
		if(m_scene){
			worldgen::access(m_server, [&](worldgen::Interface *iw){
				worldgen::Instance *instance = iw->get_instance(m_scene);
				if(instance)
					instance->set_generator(nullptr);
			});
		}
		lua_prof_report();
		if(m_lua)
			lua_close(m_lua);
	}

	// The Lua the two Luanti clients share, from the extension's res,
	// served under the module's own client namespace so a game's client
	// half runs it by name ([VIEW_BOB]: camera_motion.lua; [EXT_SETTINGS]:
	// key_editor.lua; [EXT_HUD_PARITY]: minimap.lua; [EXT_HOTBAR]:
	// hotbar.lua; [LUANTI_SHARED]: texmod.lua, formspec.lua). At start rather
	// than with a game's media: a menu-only connection (the settings
	// screen, [MENU_CONTEXT]) runs no game and draws the key editor.
	void serve_shared_lua()
	{
		const ss_ shared = m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res";
		for(const char *name : {"camera_motion.lua", "key_editor.lua",
				"minimap.lua", "hotbar.lua", "texmod.lua",
				"formspec.lua", "formspec_ui.lua", "hud.lua", "hud_draw.lua",
				"sounds.lua", "particles.lua", "form_session.lua",
				"item_shape.lua", "sky_model.lua", "touch.lua", "skybox.lua"}){
			const ss_ path = shared+"/"+name;
			if(interface::fs::path_exists(path)){
				client_file::access(m_server, [&](client_file::Interface *i){
					i->add_file_path(ss_("luanti/")+name, path);
				});
			} else
				log_w(MODULE, "shared client Lua not found: %s", cs(path));
		}
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:module_unloaded"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		// [USER_DIR_COPY] An operator's save_now: what shutdown saves
		m_server->sub_event(this, Event::t("core:save"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("worldgen:section_generated"));
		m_server->sub_event(this, Event::t("voxelworld:section_loaded"));
		m_server->sub_event(this, Event::t("voxelworld:section_unloaded"));
		m_server->sub_event(this, Event::t("voxelworld:sections_forgotten"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_texmods"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_item_images"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_item_palettes"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_wield_meshes"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_object_props"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_dig_props"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_world_info"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:refshot_shot"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_translations"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_model"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:fields"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:inv_action"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		for(const char *n : luanti_session::PACKETS)
			m_server->sub_event(this, Event::t(
					ss_("network:packet_received/luanti:")+n));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("core:module_unloaded", on_module_unloaded,
				interface::ModuleUnloadedEvent)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:shutdown", on_shutdown)
		EVENT_VOIDN("core:save", on_shutdown)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("worldgen:section_generated", on_section_generated,
				worldgen::SectionGenerated)
		EVENT_TYPEN("voxelworld:section_loaded", on_section_loaded,
				voxelworld::SectionLoaded)
		EVENT_TYPEN("voxelworld:section_unloaded", on_section_unloaded,
				voxelworld::SectionUnloaded)
		EVENT_TYPEN("voxelworld:sections_forgotten", on_sections_forgotten,
				voxelworld::SectionsForgotten)
		EVENT_TYPEN("network:packet_received/luanti:get_texmods",
				on_get_texmods, network::Packet)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/luanti:get_item_images",
				on_get_item_images, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_item_palettes",
				on_get_item_palettes, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_wield_meshes",
				on_get_wield_meshes, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_object_props",
				on_get_object_props, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_dig_props",
				on_get_dig_props, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_world_info",
				on_get_world_info, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_translations",
				on_get_translations, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_model",
				on_get_model, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:refshot_shot",
				on_refshot_shot, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:fields",
				on_fields, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:inv_action",
				on_inv_action, network::Packet)
		// [LUANTI_APP_GLUE] The player session's (session.h)
		for(const char *n : luanti_session::PACKETS){
			if(type == Event::t(ss_("network:packet_received/luanti:")+n)){
				m_session.packet(*dynamic_cast<const network::Packet*>(p));
				return;
			}
		}
	}

	void on_start()
	{
		serve_shared_lua();
		// What may go ahead of the queue and replace its own stale copy
		// ([NET_CHANNELS]): the player's own position, the clock, and the
		// objects -- whose packet is the whole list every time (the
		// client removes what is not in it), so the newest replaces an
		// older one whole and no key by id is needed.
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->declare("luanti:player_pos",
					network::Interface::Channel::LatestOnly);
			inetwork->declare("luanti:time",
					network::Interface::Channel::LatestOnly);
			inetwork->declare("luanti:objects",
					network::Interface::Channel::LatestOnly);
		});
	}
	void on_unload(){}
	void on_continue(){}

	// The last node writes and the clock. voxelworld has a core:shutdown
	// handler of its own and may have run it already -- subscribers are
	// called in the order the modules were loaded -- so this asks the world
	// to save rather than trusting that it has not saved yet. Asking twice
	// costs nothing: a section that has not changed is not written.
	void on_shutdown()
	{
		checkpoint();
	}

	// [SAVE_CHECKPOINT] Every save_interval_s and at shutdown: the node
	// writes, the clock, the players and the loaded sections' metadata,
	// and the world's changed sections, as one transaction -- so a copy of
	// the save taken at any moment has a chest's items in the chest or in
	// the inventory, never both or neither. The writes here are collected
	// on this thread and made by voxelworld inside its save, on its thread:
	// a batch() held here around world->save() would hold the save's lock
	// while voxelworld's thread waits for it.
	sv_<std::pair<ss_, ss_>> *m_save_sink = nullptr;
	// What the last checkpoint wrote for a loaded section's metadata, so an
	// unchanged one is not written again; a section that unloads writes its
	// own and leaves this
	std::map<ss_, ss_> m_meta_written;
	float m_checkpoint_accum = 0.0f;
	ss_ m_players_written;

	void store_set(const ss_ &key, const ss_ &value)
	{
		if(m_save_sink)
			m_save_sink->push_back(std::make_pair(key, value));
		else
			m_store->set(key, value);
	}

	void checkpoint()
	{
		if(!m_game_running || !m_store)
			return;
		const int64_t t0 = interface::os::time_us();
		flush_node_writes();
		sv_<std::pair<ss_, ss_>> writes;
		m_save_sink = &writes;
		save_clock();
		save_players();
		copy_loaded_meta();
		m_save_sink = nullptr;
		const int64_t t1 = interface::os::time_us();
		storage::Store *store = m_store;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->save([&](){
				for(const auto &w : writes)
					store->set(w.first, w.second);
			});
		});
		const int64_t t2 = interface::os::time_us();
		if(t2 - t0 > 100000)
			log_w(MODULE, "checkpoint: %i ms (%i ms ours, %zu writes)",
					(int)((t2 - t0) / 1000), (int)((t1 - t0) / 1000),
					writes.size());
		else
			log_v(MODULE, "checkpoint: %i ms (%i ms ours, %zu writes)",
					(int)((t2 - t0) / 1000), (int)((t1 - t0) / 1000),
					writes.size());
	}

	// The metadata of every loaded section, left in memory (unlike
	// save_section_meta(), which is the section leaving)
	void copy_loaded_meta()
	{
		if(!m_store || !m_lua || !m_scene || m_section_size.getX() <= 0)
			return;
		sv_<pv::Vector3DInt16> sections;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			sections = world->get_loaded_sections();
		});
		std::map<ss_, ss_> now;
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__regroup_node_meta");
			lua_pushinteger(L, m_section_size.getX());
			if(lua_pcall(L, 1, 2, 0) != 0){
				log_w(MODULE, "__regroup_node_meta(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return;
			}
			if(lua_istable(L, -2)){
				const size_t count = lua_objlen(L, -2);
				for(size_t i = 1; i + 1 <= count; i += 2){
					size_t kl = 0, vl = 0;
					lua_rawgeti(L, -2, (int)i);
					const char *k = lua_tolstring(L, -1, &kl);
					lua_rawgeti(L, -3, (int)i + 1);
					const char *v = lua_tolstring(L, -1, &vl);
					now["node_meta/"+ss_(k ? k : "", kl)] = ss_(v ? v : "", vl);
					lua_pop(L, 2);
				}
			}
			lua_settop(L, base);
		}
		for(const pv::Vector3DInt16 &section_p : sections){
			const ss_ key = section_meta_key(section_p);
			auto it = now.find(key);
			const ss_ data = it == now.end() ? ss_() : it->second;
			auto was = m_meta_written.find(key);
			if(was != m_meta_written.end() && was->second == data)
				continue;
			// Not known yet and nothing here: clear only what the save has
			ss_ old;
			if(was == m_meta_written.end() && data.empty() &&
					(!m_store->get(key, old) || old.empty())){
				m_meta_written[key] = "";
				continue;
			}
			store_set(key, data);
			m_meta_written[key] = data;
		}
	}

	// The clock, in the save's object store beside the map: a world put down
	// at dusk is picked up at dusk. Luanti keeps the same three numbers in
	// its env_meta.txt.
	// Written with every checkpoint ([SAVE_CHECKPOINT]), as Luanti writes
	// its own with the map.
	// The world's seed, which a mapgen is a function of. Luanti keeps it in
	// map_meta.txt and makes one up when a world is created; here it is in
	// the save beside the clock, and the importer takes the imported world's
	// if it has one. What reads it is core.get_mapgen_setting("seed") and
	// the block seed every on_generated is given.
	int64_t m_seed = 0;
	// Whether this save is one nobody has opened before; see load_seed()
	bool m_world_is_new = false;
	MapgenParams m_mapgen{m_lua, m_lua_mutex, m_store, m_world_is_new};

	void load_seed()
	{
		ss_ data;
		if(m_store && m_store->get("seed", data) && !data.empty()){
			// Unsigned, because Luanti's is: a world's seed is a u64 there
			// and half of them do not fit in the signed one this keeps. The
			// bits are what a mapgen is a function of, so they are what is
			// kept.
			m_seed = (int64_t)strtoull(data.c_str(), nullptr, 10);
		} else {
			// The first thing a world is asked for is its seed, so a save
			// with none is a save nobody has played yet. What that decides
			// is what mapgen it gets; see MapgenParams::mapgen_name().
			m_world_is_new = true;
			// Luanti's own fixed_map_seed, which is what makes one world the
			// same world twice: a benchmark that generates terrain has to
			// generate the same terrain, and a bug report about a place has
			// to be able to name it. Read the way Luanti reads it -- only
			// when a world is being made, never over one that has a seed.
			const ss_ fixed = m_mapgen.setting_string("fixed_map_seed");
			if(!fixed.empty()){
				m_seed = (int64_t)strtoull(fixed.c_str(), nullptr, 10);
				log_i(MODULE, "The world's seed is fixed_map_seed, %s",
						cs(itos(m_seed)));
			} else {
				// Somewhere nobody has been before: the clock is what there
				// is to be random with here, and a world is seeded once
				m_seed = (int64_t)interface::os::time_us();
				m_seed ^= (int64_t)(size_t)this;
			}
			if(m_store)
				m_store->set("seed", itos(m_seed));
		}
		set_global_string("__luanti_world_seed", itos(m_seed));
		log_v(MODULE, "The world's seed is %s", cs(itos(m_seed)));
	}

	void set_seed(int64_t seed)
	{
		m_seed = seed;
		if(m_store)
			m_store->set("seed", itos(m_seed));
		set_global_string("__luanti_world_seed", itos(m_seed));
	}

	// A scripted run cannot wait for morning, and two pictures taken at
	// different hours are not comparable -- which is what the reference
	// comparison in doc/plan/luanti_module_plan.md is. Spelled the way
	// extensions/luanti_client spells them, because it is the other half of
	// that comparison: BUILDAT_LUANTI_FORCE_TIME is a Luanti time of day
	// (0..24000, so 9000 is mid-morning) and BUILDAT_LUANTI_FORCE_DAY is
	// noon without having to remember 12000.
	//
	// The clock stops as well as moves: a screenshot taken a minute into a
	// run should be the same picture as one taken at the start, and
	// time_speed is Luanti's own way of saying so.
	void force_clock()
	{
		const char *t = getenv("BUILDAT_LUANTI_FORCE_TIME");
		const char *d = getenv("BUILDAT_LUANTI_FORCE_DAY");
		double tod = -1.0;
		if(t != nullptr && t[0] != '\0')
			tod = atof(t) / 24000.0;
		else if(d != nullptr && d[0] != '\0')
			tod = 0.5;
		if(tod < 0.0)
			return;
		char buf[200];
		snprintf(buf, sizeof buf,
				"core.set_timeofday(%f) "
				"core.settings:set('time_speed', '0') "
				"core.__send_time()", tod);
		run_chunk_string(buf, "force_clock");
		log_i(MODULE, "The clock is pinned at %.0f of Luanti's 24000 and "
				"does not run", tod * 24000.0);
	}

	void load_clock()
	{
		if(!m_store)
			return;
		ss_ data;
		if(!m_store->get("clock", data))
			return;
		double time_of_day = 0.5, game_time = 0.0;
		int32_t day_count = 0;
		{
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			// A newer one is kept as it is, not reset to noon
			if(version != 1){
				log_e(MODULE, "The save's clock is version %i and this build "
						"reads 1; it is not written over", (int)version);
				m_clock_unreadable = true;
				return;
			}
			ar(time_of_day, game_time, day_count);
		}
		lua_State *L = m_lua;
		interface::MutexScope ms(m_lua_mutex);
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__set_clock");
		lua_pushnumber(L, time_of_day);
		lua_pushnumber(L, game_time);
		lua_pushnumber(L, day_count);
		if(lua_pcall(L, 3, 0, 0) != 0)
			log_w(MODULE, "__set_clock(): %s", lua_tostring(L, -1));
		lua_settop(L, base);
		log_v(MODULE, "Clock read from the save: day %i, time %.4f, "
				"%.0f seconds played", (int)day_count, time_of_day, game_time);
	}

	// Step 5c of doc/plan/world_persistence_plan.md: what hangs off the
	// voxels -- a chest's contents, a sign's text -- goes into the save
	// beside the clock. One blob, because the world is the sections a mod
	// can reach; lua/bootstrap.lua names the upgrade path where it builds it.
	void save_node_meta()
	{
		if(!m_store || !m_lua)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__save_node_meta");
		if(lua_pcall(L, 0, 2, 0) != 0){
			log_w(MODULE, "__save_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		ss_ data = lua_tostring(L, -2) ? lua_tostring(L, -2) : "";
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		if(n == 0 && !m_had_node_meta)
			return; // Nothing to write and nothing there to clear
		m_had_node_meta = (n != 0);
		m_store->set("node_meta", data);
		log_v(MODULE, "Node metadata written to the save: %i positions", n);
	}

	// What hangs off the voxels of one section, in the save under a key of
	// its own: a section that unloads takes its metadata with it and brings
	// it back when it returns, which is how Luanti keeps a block's metadata
	// with the block. See step 5c of doc/plan/world_persistence_plan.md.
	ss_ section_meta_key(const pv::Vector3DInt16 &p)
	{
		return ss_()+"node_meta/"+itos(p.getX())+","+itos(p.getY())+","+
				itos(p.getZ());
	}

	void save_section_meta(const pv::Vector3DInt16 &section_p)
	{
		if(!m_store || !m_lua || m_section_size.getX() <= 0)
			return;
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int32_t x0 = (int32_t)section_p.getX() * sx;
		const int32_t y0 = (int32_t)section_p.getY() * sy;
		const int32_t z0 = (int32_t)section_p.getZ() * sz;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__take_node_meta");
		lua_pushinteger(L, x0);
		lua_pushinteger(L, y0);
		lua_pushinteger(L, z0);
		lua_pushinteger(L, x0 + sx - 1);
		lua_pushinteger(L, y0 + sy - 1);
		lua_pushinteger(L, z0 + sz - 1);
		if(lua_pcall(L, 6, 2, 0) != 0){
			log_w(MODULE, "__take_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		size_t len = 0;
		const char *p = lua_tolstring(L, -2, &len);
		const ss_ data(p ? p : "", p ? len : 0);
		const int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		const ss_ key = section_meta_key(section_p);
		m_meta_written.erase(key);
		if(n == 0){
			// Nothing there, and what the save holds is older than that
			ss_ old;
			if(m_store->get(key, old))
				m_store->set(key, "");
			return;
		}
		m_store->set(key, data);
		log_v(MODULE, "%i node metadata written with section (%i, %i, %i)", n,
				(int)section_p.getX(), (int)section_p.getY(),
				(int)section_p.getZ());
	}

	void load_section_meta(const pv::Vector3DInt16 &section_p)
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get(section_meta_key(section_p), data) || data.empty())
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_node_meta");
		lua_pushlstring(L, data.c_str(), data.size());
		if(lua_pcall(L, 1, 1, 0) != 0){
			log_w(MODULE, "__load_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		}
		lua_settop(L, base);
	}

	void on_section_loaded(const voxelworld::SectionLoaded &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		load_section_meta(event.section_p);
	}

	void on_section_unloaded(const voxelworld::SectionUnloaded &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		save_section_meta(event.section_p);
	}

	// [SAVE_LIMIT] A trimmed section's metadata goes with it
	void on_sections_forgotten(const voxelworld::SectionsForgotten &event)
	{
		if(!m_store || event.scene != m_scene)
			return;
		m_store->batch([&](){
			for(const pv::Vector3DInt16 &p : event.sections){
				const ss_ key = section_meta_key(p);
				m_store->remove(key);
				m_meta_written.erase(key);
			}
		});
		// Made again, they are new terrain: a mod's on_generated runs over
		// their mapchunks again as it did the first time
		using luanti_mapgen::chunk_index;
		const int sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		for(const pv::Vector3DInt16 &p : event.sections){
			const int x0 = p.getX() * sx, y0 = p.getY() * sy,
					z0 = p.getZ() * sz;
			for(int cz = chunk_index(z0); cz <= chunk_index(z0 + sz - 1); cz++)
			for(int cy = chunk_index(y0); cy <= chunk_index(y0 + sy - 1); cy++)
			for(int cx = chunk_index(x0); cx <= chunk_index(x0 + sx - 1); cx++)
				m_chunks_run.erase(chunk_key(cx, cy, cz));
		}
	}

	// Everything the Lua half holds, grouped by the section each position
	// is in and written; what is in memory is left there. What wants this
	// is the importer -- a world it read metadata for is mostly sections
	// nothing has loaded -- and the migration below.
	size_t write_all_node_meta()
	{
		if(!m_store || !m_lua || m_section_size.getX() <= 0)
			return 0;
		sv_<ss_> flat;
		int n = 0;
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__regroup_node_meta");
			lua_pushinteger(L, m_section_size.getX());
			if(lua_pcall(L, 1, 2, 0) != 0){
				log_w(MODULE, "__regroup_node_meta(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return 0;
			}
			n = (int)lua_tonumber(L, -1);
			if(lua_istable(L, -2)){
				const size_t count = lua_objlen(L, -2);
				for(size_t i = 1; i <= count; i++){
					lua_rawgeti(L, -2, (int)i);
					size_t len = 0;
					const char *p = lua_tolstring(L, -1, &len);
					flat.push_back(ss_(p ? p : "", p ? len : 0));
					lua_pop(L, 1);
				}
			}
			lua_settop(L, base);
		}
		for(size_t i = 0; i + 1 < flat.size(); i += 2)
			m_store->set("node_meta/"+flat[i], flat[i + 1]);
		log_v(MODULE, "%i node metadata over %zu sections", n,
				flat.size() / 2);
		return flat.size() / 2;
	}

	// A save written when the metadata was one blob for the whole world:
	// read it, write it out per section, and only then drop the blob, so
	// that a crash in the middle leaves the blob to be read again.
	void migrate_node_meta()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("node_meta", data) || data.empty())
			return;
		log_i(MODULE, "The save's node metadata is one blob; writing it out "
				"per section");
		load_node_meta();
		write_all_node_meta();
		m_store->set("node_meta", "");
		m_had_node_meta = false;
	}

	void load_node_meta()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("node_meta", data))
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_node_meta");
		lua_pushlstring(L, data.c_str(), data.size());
		if(lua_pcall(L, 1, 1, 0) != 0){
			log_w(MODULE, "__load_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		m_had_node_meta = (n != 0);
		log_v(MODULE, "Node metadata read from the save: %i positions", n);
	}

	// The players, in the save beside the node metadata and written the same
	// way: what a player carries is item strings as well. lua/entity.lua says
	// what one row is.
	void save_players()
	{
		if(!m_store || !m_lua || m_players_unreadable)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__save_players");
		if(lua_pcall(L, 0, 2, 0) != 0){
			log_w(MODULE, "__save_players(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		size_t len = 0;
		const char *p = lua_tolstring(L, -2, &len);
		ss_ data(p ? p : "", p ? len : 0);
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		if(n == 0 && !m_had_players)
			return; // Nothing to write and nothing there to clear
		m_had_players = (n != 0);
		if(data == m_players_written)
			return; // A checkpoint with nobody moving
		m_players_written = data;
		store_set("players", data);
		log_v(MODULE, "Players written to the save: %i", n);
	}

	void load_players()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("players", data))
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_players");
		lua_pushlstring(L, data.c_str(), data.size());
		// One this cannot read is kept as it is: the next checkpoint
		// would otherwise drop every player not online
		if(lua_pcall(L, 1, 1, 0) != 0 || lua_isnil(L, -1)){
			log_e(MODULE, "The save's players cannot be read (%s); they are "
					"not written over", lua_isstring(L, -1) ?
					lua_tostring(L, -1) : "a newer Buildat's, or broken");
			m_players_unreadable = true;
			lua_settop(L, base);
			return;
		}
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		m_had_players = (n != 0);
		log_v(MODULE, "Players read from the save: %i", n);
	}

	void save_clock()
	{
		if(!m_store || !m_lua || m_clock_unreadable)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__get_clock");
		if(lua_pcall(L, 0, 3, 0) != 0){
			log_w(MODULE, "__get_clock(): %s", lua_tostring(L, -1));
			lua_settop(L, base);
			return;
		}
		double time_of_day = lua_tonumber(L, -3);
		double game_time = lua_tonumber(L, -2);
		int32_t day_count = (int32_t)lua_tonumber(L, -1);
		lua_settop(L, base);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)1, time_of_day, game_time, day_count);
		}
		store_set("clock", os.str());
		log_v(MODULE, "Clock written to the save: day %i, time %.4f, "
				"%.0f seconds played", (int)day_count, time_of_day, game_time);
	}

	// The server ticks at 30 Hz and Luanti steps at 0.09 s, so a tick's
	// dtime is accumulated into a step. A tick the server could not deliver
	// on time arrives with the time it was late by added to it -- see
	// push_event() in src/server/state.cpp -- so a game whose step costs
	// more than a tick interval, which VoxeLibre's 220 mods do, runs slow
	// rather than falling further behind on every tick.
	void on_tick(const interface::TickEvent &event)
	{
		if(!m_game_running)
			return;
		m_session.tick(event.dtime);
		m_step_accum += event.dtime;
		if(m_step_accum < STEP_S)
			return;
		float dtime = m_step_accum;
		if(dtime > MAX_STEP_S)
			dtime = MAX_STEP_S;
		m_step_accum = 0.0f;
		// The startup tables once more, a few seconds in: a game's entity
		// looks are not all registered when the voxel registry is built
		// (VoxeLibre had ten of them after and none at it), and a file
		// that is there before the next client connects is the point
		// ([BLOCKED_MODULE])
		if(m_startup_files_wait > 0.0f){
			m_startup_files_wait -= dtime;
			if(m_startup_files_wait <= 0.0f)
				serve_startup_tables();
		}
		// Other players' digs and the loader's unloads land between steps
		drop_read_cache();
		// The relights the mapgen mods' writes asked for, one or two a tick
		// rather than in the step that wrote them ([STEP_SLICE])
		if(m_scene){
			const int64_t t0 = interface::os::time_us();
			size_t left = 0;
			int64_t t_in = 0;
			voxelworld::access(m_server, m_scene,
					[&](voxelworld::Instance *world){
				t_in = interface::os::time_us();
				left = world->relight_stale(RELIGHT_BUDGET_US,
						RELIGHT_NEAR_BUDGET_US);
			});
			const int64_t took = interface::os::time_us() - t0;
			// What of it was waiting for voxelworld rather than lighting:
			// the relight's own budget is 20 ms (100 near) and a step of a
			// second in "relight" is another module holding the world --
			// the physics variant's does. A phase of its own says so
			// rather than reading as this one's cost ([MAPGEN_STEP]).
			const int64_t waited = t_in > t0 ? t_in - t0 : 0;
			if(took > 1000){
				drop_read_cache();
				char buf[96];
				snprintf(buf, sizeof buf,
						"core.__note_phase(\"%s\", %f)",
						waited * 2 > took ? "relight_wait" : "relight",
						(double)took / 1000000.0);
				run_chunk_string(buf, "relight");
				if(left > 0 || waited > 100000)
					log_v(MODULE, "relight: %i ms (%i waiting for "
							"voxelworld), %zu sections still stale",
							(int)(took / 1000), (int)(waited / 1000), left);
			}
		}
		update_load_points();
		if(m_game_running)
			run_completed_chunks();
		check_map_when_ready(dtime);
		step_environment(dtime);
		flush_node_writes();
		// The clock, now and then: a client carries it on by itself between
		// these, so this is a correction rather than a tick
		m_time_accum += dtime;
		if(m_time_accum >= TIME_INTERVAL_S){
			m_time_accum = 0.0f;
			run_chunk_string("core.__send_time()", "send_time");
		}
		const double interval = atof(m_server->get_config().get<ss_>(
				"save_interval_s").c_str());
		m_checkpoint_accum += dtime;
		if(interval > 0 && m_checkpoint_accum >= interval){
			m_checkpoint_accum = 0.0f;
			checkpoint();
		}
	}

	// One Luanti step: the clock now, the globalsteps and core.after later
	// How long a step may run before the watchdog says where it is. Long
	// enough that a world generating around a player -- which is seconds of
	// honest work -- says nothing, and short enough that a step that will
	// never come back is caught while somebody is still watching.
	static const int64_t STEP_WATCHDOG_US = 30000000;
	// How much of a tick the deferred relights may take; a section is
	// about 160 ms on VoxeLibre, so this is one a tick
	static const int64_t RELIGHT_BUDGET_US = 20000;
	// And while a stale section is within two of a player: the player's
	// own canopy black for twenty seconds was the small budget on
	// 250k-blocker sections ([SEED5_SETTLE])
	static const int64_t RELIGHT_NEAR_BUDGET_US = 100000;

	void step_environment(float dtime)
	{
		char buf[64];
		snprintf(buf, sizeof buf, "core.__step(%f)", (double)dtime);
		g_step_watch.started_us = interface::os::time_us();
		g_step_watch.deadline_us =
				g_step_watch.started_us + STEP_WATCHDOG_US;
		g_step_watch.warned = false;
		try {
			run_chunk_string(buf, "step");
		} catch(Exception &e){
			log_w(MODULE, "step: %s", e.what());
		}
		g_step_watch.deadline_us = 0;
	}

	// The map

	// Floor division, because a section boundary is not at zero and C's
	// division rounds towards it
	static int32_t floordiv(int32_t a, int32_t b)
	{
		return (a >= 0) ? (a / b) : -((-a + b - 1) / b);
	}

	pv::Vector3DInt16 section_of(const pv::Vector3DInt32 &p)
	{
		if(m_section_size.getX() <= 0)
			return pv::Vector3DInt16(0, 0, 0);
		return pv::Vector3DInt16(
				(int16_t)floordiv(p.getX(), m_section_size.getX()),
				(int16_t)floordiv(p.getY(), m_section_size.getY()),
				(int16_t)floordiv(p.getZ(), m_section_size.getZ()));
	}

	// Where the world stays loaded: every player, and the origin whether or
	// not anybody is there. A player's point is tagged with their peer,
	// which is what makes it the point the world is sent to them from.
	void update_load_points()
	{
		if(!m_scene)
			return;
		sv_<voxelworld::LoadPoint> points;
		points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(0, 0, 0),
				SPAWN_RADIUS, SPAWN_RADIUS_Y,
				SPAWN_RADIUS, SPAWN_RADIUS_Y));
		for(const auto &pair : m_player_pos){
			size_t peer = 0;
			auto it = m_player_peers.find(pair.first);
			if(it != m_player_peers.end())
				peer = it->second;
			points.push_back(voxelworld::LoadPoint(pair.second,
					m_load_radius_xz, LOAD_RADIUS_Y,
					m_generate_radius_xz, GENERATE_RADIUS_Y, peer));
		}
		// A forceloaded section is a point with no radius at all
		for(const auto &pair : m_forceloaded){
			const pv::Vector3DInt16 sp = section_from_key(pair.first);
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					(int32_t)sp.getX() * m_section_size.getX(),
					(int32_t)sp.getY() * m_section_size.getY(),
					(int32_t)sp.getZ() * m_section_size.getZ()),
					0, 0, 0, 0));
		}
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_load_points(points);
			world->set_stream_budget(m_stream_budget);
		});
	}

	// The active range is a section around a player and nothing where there
	// is none, which is what stops a furnace on the other side of the world
	// from firing into a section nobody has loaded
	void check_active_range()
	{
		sm_<ss_, pv::Vector3DInt32> saved;
		saved.swap(m_player_pos);
		assert(!is_section_active(pv::Vector3DInt16(0, 0, 0)));
		m_player_pos["__check"] = pv::Vector3DInt32(0, 0, 0);
		assert(is_section_active(pv::Vector3DInt16(0, 0, 0)));
		assert(is_section_active(pv::Vector3DInt16(1, 0, -1)));
		assert(!is_section_active(pv::Vector3DInt16(2, 0, 0)));
		// A player one voxel the other side of a boundary is in the section
		// that side of it, and the range goes with them
		m_player_pos["__check"] = pv::Vector3DInt32(-1, 0, 0);
		assert(is_section_active(pv::Vector3DInt16(-2, 0, 0)));
		assert(!is_section_active(pv::Vector3DInt16(1, 0, 0)));
		m_player_pos = saved;
		log_v(MODULE, "check_active_range: the range is where the players are");
	}

	// Luanti's forceload: a block a mod wants kept whatever nobody is near
	// it, which is a load point with no radius at all. Kept by section,
	// because that is what loads and unloads here; a mod asking for a
	// block gets the section it is in.
	//
	// Nothing here is written down, and nothing needs to be: the vendored
	// builtin's forceloading.lua keeps the ones that are not transient in
	// force_loaded.txt beside the world and asks for them again when it
	// loads, which is where Luanti keeps them too.
	// Section key -> how many holds: a game's forceload_block() per
	// mapblock (VoxeLibre makes and frees thousands) and the map check's
	// pin share this, and one owner's free took the other's hold with it
	// (the check read its room out of an unloaded section, 2026-09-21)
	sm_<uint64_t, int> m_forceloaded;

	static uint64_t section_key(const pv::Vector3DInt16 &p)
	{
		return (uint64_t)(uint16_t)p.getX() |
				((uint64_t)(uint16_t)p.getY() << 16) |
				((uint64_t)(uint16_t)p.getZ() << 32);
	}

	static pv::Vector3DInt16 section_from_key(uint64_t k)
	{
		return pv::Vector3DInt16((int16_t)k, (int16_t)(k >> 16),
				(int16_t)(k >> 32));
	}

	// __luanti_accounts(cmd, a, b): Luanti's kicks and bans, which are
	// builtin/accounts' ([VANILLA_PUBLIC] 4). A player's name is their
	// account's.
	//   "kick", name, reason -> "" when done, else why not
	//   "ban", name          -> the same
	//   "unban", name or address -> the same
	//   "ban_list"           -> "name|address, ..."
	//   "ip", name           -> the address, or ""
	static int l_accounts(lua_State *L)
	{
		Module *self = module_of(L);
		const ss_ cmd = luaL_checkstring(L, 1);
		const ss_ a = luaL_optstring(L, 2, "");
		const ss_ b = luaL_optstring(L, 3, "");
		ss_ out;
		accounts::access(self->m_server, [&](accounts::Interface *i){
			const accounts::PeerId peer = a.empty() ? 0 : i->find_peer(a);
			// A world's privileges reach this server's accounts: kick and
			// ban leave an admin alone, and unban lifts what a world banned,
			// not an admin's ban ([SECURITY_RUN_1])
			if(cmd == "kick"){
				if(!peer)
					out = a+" is not here";
				else if(i->is_admin(a))
					out = "An admin is not kicked";
				else
					i->kick(peer, b.empty() ? "Kicked" : b);
			} else if(cmd == "ban"){
				out = i->ban(a, "the game");
			} else if(cmd == "unban"){
				out = i->unban(a, "the game");
			} else if(cmd == "ban_list"){
				for(const ss_ &ban : i->ban_list())
					out += (out.empty() ? "" : ", ")+ban;
			} else if(cmd == "ip"){
				out = peer ? i->address_of(peer) : "";
			}
		});
		lua_pushstring(L, out.c_str());
		return 1;
	}

	// __luanti_forceload(x, y, z, wanted) -> whether it is kept now
	static int l_forceload(lua_State *L)
	{
		Module *self = module_of(L);
		const int32_t x = (int32_t)luaL_checkinteger(L, 1);
		const int32_t y = (int32_t)luaL_checkinteger(L, 2);
		const int32_t z = (int32_t)luaL_checkinteger(L, 3);
		const bool wanted = lua_toboolean(L, 4) != 0;
		if(self->m_section_size.getX() <= 0){
			lua_pushboolean(L, 0);
			return 1;
		}
		const uint64_t key = section_key(
				self->section_of(pv::Vector3DInt32(x, y, z)));
		if(wanted){
			self->m_forceloaded[key]++;
		} else {
			auto it = self->m_forceloaded.find(key);
			if(it != self->m_forceloaded.end() && --it->second <= 0)
				self->m_forceloaded.erase(it);
		}
		log_v(MODULE, "forceload: %zu sections kept",
				self->m_forceloaded.size());
		// The points are pushed once a step; this only says what they are
		lua_pushboolean(L, wanted ? 1 : 0);
		return 1;
	}

	// Luanti's active_block_range: what is near a player is what steps.
	// Nobody near it means nothing runs in it, which is Luanti's answer too
	// -- a world with no players in it is a world where nothing happens.
	bool is_section_active(const pv::Vector3DInt16 &section_p)
	{
		for(const auto &pair : m_player_pos){
			pv::Vector3DInt16 c = section_of(pair.second);
			if(std::abs((int32_t)section_p.getX() - c.getX()) <= ACTIVE_RADIUS &&
					std::abs((int32_t)section_p.getY() - c.getY()) <= ACTIVE_RADIUS &&
					std::abs((int32_t)section_p.getZ() - c.getZ()) <= ACTIVE_RADIUS)
				return true;
		}
		return false;
	}

	void flush_node_writes()
	{
		if(m_node_writes.empty() || !m_scene)
			return;
		drop_read_cache();
		size_t n = m_node_writes.size();
		const int64_t t0 = interface::os::time_us();
		int64_t t_set = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			// set_voxel() into a section that is not there does nothing and
			// says so in a warning. Luanti's set_node emerges the block it
			// writes into, so this does too -- and in a singlenode world
			// "generate" means nobody answers the request, which is what
			// makes the world void.
			pv::Vector3DInt16 size = world->get_section_size_voxels();
			for(const auto &pair : m_node_writes){
				const PendingNode &node = pair.second;
				pv::Vector3DInt16 section_p(
						floordiv(node.x, size.getX()),
						floordiv(node.y, size.getY()),
						floordiv(node.z, size.getZ()));
				// Loaded, not generated: a set_node past the generated
				// world -- a mapgen mod's structure into the next section
				// -- waits there for the generator, which keeps what stands
				if(!world->is_section_loaded(section_p))
					world->load_section_no_generate(section_p);
			}
			for(const auto &pair : m_node_writes){
				const PendingNode &node = pair.second;
				world->set_cause(node.by_player ? "a player" : "");
				world->set_voxel(pv::Vector3DInt32(node.x, node.y, node.z),
						interface::VoxelInstance(node.word), true);
			}
			world->set_cause("");
			t_set = interface::os::time_us();
		});
		m_node_writes.clear();
		// Split into the writes and the commit that follows them on the
		// way out of access(), since a step's flush is what is left of
		// its stall once the reads stopped flushing ([STEP_PEAK])
		const int64_t took = interface::os::time_us() - t0;
		if(took > 50000)
			log_v(MODULE, "Flushed %zu node writes in %.2f s: the writes "
					"%.2f, the commit %.2f", n, took / 1e6, (t_set - t0) / 1e6,
					(interface::os::time_us() - t_set) / 1e6);
		else
			log_d(MODULE, "Flushed %zu node writes", n);
	}

	RegionMap *m_region_map = nullptr;
	void set_region_map(RegionMap *map)
	{
		m_region_map = map;
	}

	void buffer_node_write(int32_t x, int32_t y, int32_t z, uint32_t word)
	{
		if(!coord_ok(x) || !coord_ok(y) || !coord_ok(z))
			return;
		// A body's voxel ([BODY_INTERACT]): written straight to its owner,
		// which is not the map and has no buffer to land in
		if(y >= REGION_Y){
			// **And a write with no body under it says so** (2026-09-25):
			// a body's volume carries four voxels of air around it and a
			// place past that has nowhere to land, so it was dropped in
			// silence -- the node simply never appeared, and nothing in
			// any log said why. Growing the volume is the fix and it is
			// [BODY_INTERACT]'s own leftover; until then this is the
			// line that names it. Rate limited: a VoxelManip over a body
			// is a write per voxel and a mod that misses by one misses
			// by thousands.
			if(!m_region_map || !m_region_map->set(x, y, z, word)){
				// Counted rather than timed: this module has no clock of
				// its own in scope, and what a reader needs is the first
				// one and a sense of how many followed
				static uint64_t dropped = 0;
				dropped++;
				if(dropped == 1 || dropped % 1000 == 0){
					log_w(MODULE, "a write at %i,%i,%i is past every "
							"body's margin and is dropped (%llu so far)",
							(int)x, (int)y, (int)z,
							(unsigned long long)dropped);
				}
			}
			return;
		}
		PendingNode node;
		node.x = x;
		node.y = y;
		node.z = z;
		node.word = word;
		node.by_player = m_by_player;
		auto it = m_node_writes.find(pos_key(x, y, z));
		if(it != m_node_writes.end() && it->second.by_player)
			node.by_player = true;
		m_node_writes[pos_key(x, y, z)] = node;
		note_gen_write(pv::Region(pv::Vector3DInt32(x, y, z),
				pv::Vector3DInt32(x, y, z)));
	}

	// A read takes one voxelworld access(), which commits on the way out.
	// commit() is cheap with nothing dirty, but it is not free; what reads a
	// box reads it with read_region() below.
	uint32_t read_node(int32_t x, int32_t y, int32_t z)
	{
		// Ignore, past anything that can be there
		if(!coord_ok(x) || !coord_ok(y) || !coord_ok(z))
			return 0;
		// A buffered write answers with the word that went in. The read
		// used to flush the buffer first so that a mod placing a lamp and
		// asking what the room is lit by saw the flood -- but every flush
		// is a voxelworld commit with the skylight, and a mod that reads
		// and writes node by node (VoxeLibre's fix_foliage_missed over a
		// forest, its structure placers, any set_node, which reads first)
		// paid one per node: 31 s for one section's on_generated, 1.9
		// million skylight updates for a bench. So a read answers out of
		// the buffer for what is buffered and out of the world for the
		// rest, and the buffer lands at the end of the step or before a
		// region read.
		// simplified: the light of a voxel *next to* a buffered write is
		// the light before it, until the flush. A mod that needs the flood
		// in the same step reads a region (VoxelManip), which flushes.
		auto it = m_node_writes.find(pos_key(x, y, z));
		if(it != m_node_writes.end())
			return it->second.word;
		// A body's voxel ([BODY_INTERACT]), or ignore where no body is
		if(y >= REGION_Y){
			uint32_t word = 0;
			if(m_region_map && m_region_map->get(x, y, z, word))
				return word;
			return 0;
		}
		// Before the world exists -- the mods are loading -- everything
		// else is ignore; the buffer above still answers, which is what
		// a mod's own load-time check of set_node and place_node reads
		// (the minimal game's floor mod; [WIN_MAPGEN_BUILD] found it
		// failing since the guard stood ahead of the buffer)
		if(!m_scene)
			return 0;
		// And out of a cache of 16^3 blocks for the rest: an access() is
		// a handoff to voxelworld's thread and back, a quarter of a
		// millisecond whatever it reads, and what reads node by node is a
		// mod sweeping a box -- fix_foliage_missed read 171 thousand of
		// them in two minutes. One region read per block instead. The
		// cache is dropped whenever the world can have moved under it:
		// a flush, a region write, a step, a section generated.
		const int32_t bx = floordiv(x, 16), by = floordiv(y, 16),
				bz = floordiv(z, 16);
		const int64_t key = pos_key(bx, by, bz);
		auto c = m_read_cache.find(key);
		if(c == m_read_cache.end()){
			// The first read of a block is a single voxel; the block is
			// read whole on the second. A world generating drops the
			// cache every section, and a mod reading one node here and
			// one there paid a 4096-voxel region per read for nothing --
			// a second on devtest's world generation.
			if(m_read_seen.insert(key).second){
				uint32_t word = 0;
				voxelworld::access(m_server, m_scene,
						[&](voxelworld::Instance *world){
					word = world->get_voxel(pv::Vector3DInt32(x, y, z),
							true).data;
				});
				return word;
			}
			sv_<uint32_t> words;
			read_region_uncached(bx * 16, by * 16, bz * 16,
					bx * 16 + 15, by * 16 + 15, bz * 16 + 15, words);
			c = m_read_cache.emplace(key, std::move(words)).first;
		}
		return c->second[(size_t)((z - bz * 16) * 256 + (y - by * 16) * 16 +
				(x - bx * 16))];
	}

	// See read_node()
	std::unordered_map<int64_t, sv_<uint32_t>> m_read_cache;
	set_<int64_t> m_read_seen;
	void drop_read_cache()
	{
		m_read_cache.clear();
		m_read_seen.clear();
	}

	// Luanti's own cap on how much map a call may look at in one go
	// (MAX_WORKING_VOLUME). A mod asking for more than this has made a
	// mistake, and quietly building a table of that many numbers is not the
	// way to tell it so.
	static const size_t MAX_REGION_VOXELS = 4096000;
	// How far from the origin a node can be, the bodies' band at REGION_Y
	// included. Past it nothing is read or written: a coordinate from a
	// mod's arithmetic on what a client sent reached 2^30, where a box's
	// "y <= y1" loop never ended and wrote past its buffer, and past 2^21
	// a section's 16-bit index wraps ([SECURITY_RUN_1], util/fuzz).
	static const int32_t COORD_LIMIT = 2000000;
	static bool coord_ok(int32_t v)
	{
		return v >= -COORD_LIMIT && v <= COORD_LIMIT;
	}
	// A box: a node's 16^3 block or a mod's area round one, so a little
	// past COORD_LIMIT
	static bool box_ok(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1)
	{
		const int32_t L = COORD_LIMIT + 64;
		for(int32_t v : {x0, y0, z0, x1, y1, z1})
			if(v < -L || v > L)
				return false;
		return true;
	}

	// A box of voxel words in one access(), x fastest and then y and then z.
	//
	// This is what the region reads are for. Written a voxel at a time in
	// Lua they took one access_module() each -- a module lock acquired and
	// the lock hierarchy validated per voxel, 125 of them for a 5x5x5 box --
	// and the work inside voxelworld was nearly free by comparison, since
	// the commit on the way out early-outs with nothing dirty.
	void read_region(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1, sv_<uint32_t> &out)
	{
		// See box_ok(): every caller bounds its box first
		if(!box_ok(x0, y0, z0, x1, y1, z1) || x1 < x0 || y1 < y0 || z1 < z0){
			out.clear();
			return;
		}
		// What core.set_node has written and not yet flushed is part of the
		// map as far as a mod is concerned -- Luanti's semantics are that a
		// write is visible immediately. A small box has the buffer laid
		// over it, a lookup per voxel: a mod that alternates a
		// find_nodes_in_area of a few voxels with set_nodes (VoxeLibre's
		// geodes, per calcite node) paid a commit with the skylight per
		// read when every read flushed. A big box -- a section's
		// VoxelManip, a find over a chunk -- flushes first as before:
		// walking a buffer of tens of thousands per read, a hundred reads
		// a section, cost VoxeLibre's world generation a third.
		const size_t volume = (size_t)(x1 - x0 + 1) * (size_t)(y1 - y0 + 1) *
				(size_t)(z1 - z0 + 1);
		// A box in a body's region ([BODY_INTERACT]) is read voxel by
		// voxel off the body's owner; the map has nothing there. A box
		// across the line reads as ignore above it.
		if(y0 >= REGION_Y){
			out.assign(volume, 0);
			if(!m_region_map)
				return;
			size_t i = 0;
			for(int32_t z = z0; z <= z1; z++)
			for(int32_t y = y0; y <= y1; y++)
			for(int32_t x = x0; x <= x1; x++, i++){
				uint32_t word = 0;
				if(m_region_map->get(x, y, z, word))
					out[i] = word;
			}
			return;
		}
		if(volume > 4096)
			flush_node_writes();
		read_region_uncached(x0, y0, z0, x1, y1, z1, out);
		if(m_node_writes.empty())
			return;
		size_t i = 0;
		for(int32_t z = z0; z <= z1; z++)
		for(int32_t y = y0; y <= y1; y++)
		for(int32_t x = x0; x <= x1; x++, i++){
			auto it = m_node_writes.find(pos_key(x, y, z));
			if(it != m_node_writes.end())
				out[i] = it->second.word;
		}
	}

	void read_region_uncached(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1, sv_<uint32_t> &out)
	{
		// The callers bound it (box_ok() at the Lua entries, read_node()
		// for its block); a box past it here is a caller's bug, and an
		// empty answer is what a short read gets
		if(!box_ok(x0, y0, z0, x1, y1, z1) || x1 < x0 || y1 < y0 || z1 < z0){
			out.clear();
			return;
		}
		size_t w = (size_t)(x1 - x0 + 1);
		size_t h = (size_t)(y1 - y0 + 1);
		size_t d = (size_t)(z1 - z0 + 1);
		out.assign(w * h * d, 0);
		if(!m_scene)
			return;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			// One read for the box rather than one per voxel: what asks for
			// this is a sweep -- an ABM, a find_nodes_in_area -- and the
			// difference is a clip per chunk against a section and buffer
			// lookup per voxel
			interface::VoxelVolume vol = world->get_volume(pv::Region(
					pv::Vector3DInt32(x0, y0, z0),
					pv::Vector3DInt32(x1, y1, z1)));
			// A row at a time: the answer is an array of words and a row
			// of the volume is a run of them, so the only per-voxel work
			// left is the assembly out of the bytes. A sampler per voxel
			// was the top of a devtest profile with this underneath it.
			interface::VoxelVolume::Sampler src(&vol);
			size_t i = 0;
			for(int32_t z = z0; z <= z1; z++){
				for(int32_t y = y0; y <= y1; y++){
					if(vol.read_words(x0, y, z, w, &out[i])){
						i += w;
						continue;
					}
					src.setPosition(x0, y, z);
					for(int32_t x = x0; x <= x1; x++, src.movePositiveX()){
						out[i++] = src.getVoxel().data;
					}
				}
			}
		});
		// What has been written and not flushed is not in voxelworld yet, so
		// it goes over the top -- the same order read_node() reads in. The
		// buffer is emptied every Luanti step, so sweeping it is cheaper
		// than a lookup per voxel of the box.
		for(const auto &pair : m_node_writes){
			const PendingNode &n = pair.second;
			if(n.x < x0 || n.x > x1 || n.y < y0 || n.y > y1 ||
					n.z < z0 || n.z > z1)
				continue;
			out[(size_t)(n.x - x0) + (size_t)(n.y - y0) * w +
					(size_t)(n.z - z0) * w * h] = n.word;
		}
	}

	// Lua

	ss_ module_path()
	{
		return m_server->get_module_path(MODULE);
	}

	// core.get_cache_path(): buildat's own cache, never the user's Luanti
	// install. The games and worlds themselves are under the user path; see
	// apps/vanilla.
	ss_ luanti_cache_path()
	{
		return m_server->get_config().get<ss_>("cache_path")+"/luanti";
	}

	void run_chunk_file(const ss_ &path)
	{
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		if(luaL_loadfile(L, path.c_str()) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: cannot load "+path+": "+err);
		}
		if(lua_pcall(L, 0, 0, base + 1) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: error in "+path+":\n"+err);
		}
		lua_settop(L, base);
	}

	void run_chunk_string(const ss_ &chunk, const ss_ &chunkname)
	{
		luanti::run_chunk_string(m_lua, m_lua_mutex, chunk, chunkname);
	}

	void set_global_string(const char *name, const ss_ &value)
	{
		lua_pushstring(m_lua, value.c_str());
		lua_setglobal(m_lua, name);
	}

	void set_global_cfunction(const char *name, lua_CFunction f)
	{
		lua_pushcfunction(m_lua, f);
		lua_setglobal(m_lua, name);
	}

	// The world
	//
	// Built after the mods have loaded, because add_voxel() takes a finished
	// definition and hands out ids in call order -- so the definitions have
	// to be made in one pass in content id order, and only the final
	// core.registered_nodes is ever looked at. That is also what makes
	// core.override_item and core.unregister_item non-issues here.

	// Luanti's own two settings, read once the mods have loaded and
	// turned from its blocks of sixteen nodes into this world's sections
	// of sixty-four. The defaults are Luanti's: 12 blocks sent, 10
	// generated, which are the 3 and 2 sections this carried before.
	void read_range_settings()
	{
		run_chunk_string(
				"__buildat_send_blocks = tonumber(core.settings:get("
				"'max_block_send_distance')) or 12 "
				"__buildat_generate_blocks = tonumber(core.settings:get("
				"'max_block_generate_distance')) or 10",
				"read_range_settings");
		auto sections_of = [&](const char *global, int fallback) -> int16_t {
			lua_getglobal(m_lua, global);
			const int blocks = lua_isnumber(m_lua, -1) ?
					(int)lua_tonumber(m_lua, -1) : fallback;
			lua_pop(m_lua, 1);
			// Sixteen nodes to a block, sixty-four to a section; never
			// nothing, and never so much that one player's setting can ask
			// the machine for a world of thousands of sections
			const int sections = blocks * 16 / 64;
			return (int16_t)(sections < 1 ? 1 : (sections > 16 ? 16 :
					sections));
		};
		m_load_radius_xz = sections_of("__buildat_send_blocks", 12);
		m_generate_radius_xz = sections_of("__buildat_generate_blocks", 10);
		log_i(MODULE, "world kept %i sections out and generated %i "
				"(max_block_send_distance, max_block_generate_distance)",
				(int)m_load_radius_xz, (int)m_generate_radius_xz);
	}

	void create_world()
	{
		read_range_settings();
		// Nothing streams while a world is being imported into this one:
		// see run_game(). The budget goes back to what it was once the
		// import is done.
		if(!m_importer.m_import_path.empty())
			m_stream_budget = 0;
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});

		// Singlenode: nothing generates anything, so the world is void and
		// the only nodes in it are the ones a mod places. The region is the
		// map's limits; what is loaded of it is what the load points keep.
		voxelworld::access(m_server, [&](voxelworld::Interface *iv){
			iv->create_instance(m_scene, m_section_region, m_server_physics);
		});

		// Before voxelworld's first tick, which is when a world that has
		// said nothing gets its whole region created
		update_load_points();

		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			// Luanti's cut of the voxel word: a 16-bit node id, param1 as
			// two light nibbles, param2 above them. Nothing is packed by
			// hand anywhere in this module because of this line.
			reg->set_format(interface::VoxelFormat::luanti());
			m_registry.build_voxel_registry(reg);
			// After the registry and before anything asks for a section: the
			// save stores node names and the run owns the numbering, so the
			// content ids the mods asked for while loading are the ids this
			// run uses whatever a previous one did. See
			// doc/plan/world_persistence_plan.md.
			world->set_name_aliases(m_mapgen.node_aliases());
			world->set_save(m_save, "main");
			// [SAVE_CHECKPOINT] Nothing to write yet; says this game
			// checkpoints itself, so voxelworld does not on its own
			world->save([](){});
			m_section_size = world->get_section_size_voxels();
		});
		// The startup tables are known once the registry is built, and they
		// go out as files as well as on request ([BLOCKED_MODULE])
		serve_startup_tables();
		// A section is what this world generates at a time, which is what
		// core.get_mapgen_chunksize() answers with
		set_global_string("__luanti_section_size",
				itos(m_section_size.getX()));

		// The generator runs in worldgen's thread rather than here: what
		// fills a section is a mod's Lua today and Luanti's own mapgen
		// when it is vendored, and neither belongs on the thread the
		// server steps on. It is created before the first section is
		// asked for, which is the next line but one.
		// What fills a section is builtin/luanti_mapgen's, which is where
		// Luanti's own mapgens are vendored: this module hands over what a
		// generator is a function of and gets one back.
		luanti_mapgen::Params params;
		params.mgname = m_mapgen.mapgen_name();
		params.seed = m_seed;
		params.singlenode_word = singlenode_word();
		params.content_ids = m_mapgen.content_ids_by_name();
		params.node_props = m_mapgen.mapgen_node_props();
		params.biomes = m_mapgen.mapgen_biomes();
		params.ores = m_mapgen.mapgen_ores();
		params.decorations = m_mapgen.mapgen_decorations();
		params.section_size = m_section_size.getX();
		params.water_level = m_mapgen.mapgen_water_level();
		params.mg_flags = m_mapgen.mapgen_flags();
		// What a mod asks for as get_mapgen_setting("water_level"): the
		// world's own, which is not always what the settings say
		set_global_string("__luanti_water_level", itos(params.water_level));
		m_mapgen.mapgen_gen_notify(params.gen_notify_flags,
				params.gen_notify_deco_ids);
		if(!params.gen_notify_flags.empty())
			log_v(MODULE, "gennotify: \"%s\", %zu decoration ids",
					cs(params.gen_notify_flags),
					params.gen_notify_deco_ids.size());
		// Kept, because the spawn search asks the same mapgen where the
		// ground is without generating anything; see l_spawn_level()
		m_mapgen_params = params;
		m_biome_query = nullptr;
		worldgen::GeneratorInterface *generator = nullptr;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *im){
			generator = im->create_generator(params);
		});
		worldgen::access(m_server, [&](worldgen::Interface *iw){
			iw->create_instance(m_scene);
			worldgen::Instance *instance = iw->get_instance(m_scene);
			if(generator)
				instance->set_generator(generator);
			instance->enable();
		});

		// Singlenode is a node everywhere, and this is where it is put.
		// Before the skylight is on: what the fill writes is a world of lit
		// air, and every voxel of it changing from nothing to air with the
		// light running would be a skylight seed -- seven million of them,
		// and eight seconds of startup to settle what the fill already
		// knows.
		//
		// A world being imported waits: what this asks for is the sections
		// around the origin, and a section a generator has been over is one
		// the import can no longer write into. run_game() calls it once the
		// map has been read, and the sections the import filled are marked
		// generated by then.
		if(m_importer.m_import_path.empty())
			generate_world();

		// The light is voxelworld's to maintain and the generator's to
		// start. voxelworld floods from the top of the world region, which
		// for a Luanti-sized map is thirty thousand voxels up and never
		// loaded -- so nothing would ever be lit if that were the only
		// source. What lights a generated world is the mapgen, which fills
		// the light as it builds (the MG_LIGHT flag), and voxelworld keeps
		// that light and spreads it from there: a write that carries light
		// means it. So a hole dug into a mountain fills from the daylight
		// around its mouth, the way it does in Luanti.
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_maintained(
					voxelworld::Instance::LIGHT_SKY, true);
			// And the light a node makes of its own, which a Luanti game's
			// mechanics are written against: what spawns where, what grows
			// underground, what a mod reads out of core.get_node_light().
			// A game whose lamps are lights in the scene would leave this
			// off; a Luanti game cannot.
			world->set_light_maintained(
					voxelworld::Instance::LIGHT_LAMP, true);
		});

		check_active_range();

		// After the world, because a section is what the metadata is now
		// written per and the section size comes from voxelworld
		migrate_node_meta();
	}

	// The client half asks for these once it has loaded, rather than being
	// sent them when it connects: a packet that arrives before the script
	// that subscribes to it has nowhere to go.
	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		m_files_transmitted.insert(event.recipient);
		if(m_texmods_waiting.erase(event.recipient))
			send_texmods(event.recipient);
	}

	void on_get_texmods(const network::Packet &packet)
	{
		// A batch of media announced since this peer's last
		// files_transmitted is still on its way: the answer waits for it
		if(!m_files_transmitted.count(packet.sender)){
			m_texmods_waiting.insert(packet.sender);
			return;
		}
		send_texmods(packet.sender);
	}

	// The same flat array the packet carries: a resource name and the
	// expression it is for, in pairs
	ss_ texmods_blob()
	{
		sv_<ss_> flat;
		flat.reserve(m_texmods.size() * 2);
		for(const auto &pair : m_texmods){
			flat.push_back(pair.first);
			flat.push_back(pair.second);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		return os.str();
	}

	// And as a file, served by client_file ([BLOCKED_MODULE]): this module
	// answers nothing while a slow mapgen holds it -- realtest's sections
	// were 29.6 s each and the client drew 840 missing textures -- and
	// client_file is a module of its own with a queue of its own, so a file
	// reaches the client whatever this one is doing. The client reads it
	// before it asks, and the packet stays for what is added later.
	void serve_texmods_file()
	{
		if(m_texmods.empty())
			return;
		const ss_ blob = texmods_blob();
		client_file::access(m_server, [&](client_file::Interface *ifile){
			ifile->add_file_content("luanti_data/texmods.bin", blob);
		});
		log_v(MODULE, "%zu texture modifiers served as a file",
				m_texmods.size());
	}

	// The same for the tables the client's other startup requests read:
	// each is built at mod load and the request only reads it, so none of
	// them has any business waiting behind a mapgen ([BLOCKED_MODULE]).
	// The requests stay -- a game may add to a table while it runs.
	void serve_lua_table_file(const char *lua_fn, const ss_ &file_name,
			const char *what)
	{
		sv_<ss_> flat = string_list_from_lua(lua_fn);
		if(flat.empty())
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		const ss_ blob = os.str();
		client_file::access(m_server, [&](client_file::Interface *ifile){
			ifile->add_file_content(file_name, blob);
		});
		log_v(MODULE, "%zu %s served as a file", flat.size(), what);
	}

	void serve_startup_tables()
	{
		serve_texmods_file();
		serve_lua_table_file("__object_appearances",
				"luanti_data/object_props.bin", "object look fields");
		serve_lua_table_file("__dig_props", "luanti_data/dig_props.bin",
				"dig prop records");
		serve_lua_table_file("__translations",
				"luanti_data/translations.bin", "translated strings");
		serve_lua_table_file("__item_images", "luanti_data/item_images.bin",
				"item image fields");
		serve_lua_table_file("__item_palettes",
				"luanti_data/item_palettes.bin", "item palettes");
		serve_lua_table_file("__wield_meshes",
				"luanti_data/wield_meshes.bin", "wield meshes");
	}

	void send_texmods(network::PeerInfo::Id peer)
	{
		std::ostringstream os(std::ios::binary);
		os << texmods_blob();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "luanti:texmods", os.str());
		});
		log_v(MODULE, "C%zu: %zu texture modifiers", (size_t)peer,
				m_texmods.size());
	}

	// The mapgen, which at singlenode is one node everywhere: Luanti's own
	// MapgenSinglenode fills a generated block with whatever
	// "mapgen_singlenode" names, or with air when a game does not name one,
	// and sets the sunlight. So a generated section here is air as well --
	// what a mod reads out of a part of the world nobody has built in is
	// "air" and not "ignore", which is what every mod that looks before it
	// places is written against.
	//
	// merge_volume() and not set_volume(): this is a generator, and the
	// priorities in voxelworld's api.h are exactly what a generator wants --
	// anything a mod has already put there stays.
	//
	// simplified: the section is filled at once rather than a chunk at a
	// time as voxelworld asks, because a singlenode section is one word
	// repeated and the whole of it costs a few milliseconds. A real mapgen
	// is the milestone where that stops being true.
	uint32_t singlenode_word()
	{
		if(m_singlenode_word == 0){
			bool known = false;
			uint32_t id = m_importer.import_content_id("mapgen_singlenode", known);
			if(!known)
				id = m_importer.import_content_id("air", known);
			const interface::VoxelFormat f = interface::VoxelFormat::luanti();
			uint32_t word = 0;
			f.id.set(word, id);
			// Lit, because a world with nothing in it is a world the sky
			// reaches everywhere in -- and because this is written before
			// voxelworld's skylight is turned on, so nothing else will put
			// the light there. Luanti's MapgenSinglenode sets the same
			// sunlight for the same reason.
			f.light_sky.set(word, f.light_sky.mask());
			m_singlenode_word = word;
		}
		return m_singlenode_word;
	}

	void generate_section(voxelworld::Instance *world,
			const pv::Vector3DInt16 &section_p)
	{
		pv::Region region = world->get_section_region_voxels(section_p);
		interface::VoxelVolume vol(region);
		vol.fill(interface::VoxelInstance(singlenode_word()));
		world->merge_volume(vol, false);
	}

	// worldgen has filled a section and merged it into the world. The
	// callbacks a mod registered run here, on the main thread, over terrain
	// that is already in the map -- which is the same order Luanti gives
	// them: its mapgen has written the chunk by the time they see it.
	void on_section_generated(const worldgen::SectionGenerated &event)
	{
		drop_read_cache();
		if(m_check_map_pending)
			m_generated_sections.insert(section_key(event.section_p));
		if(!m_game_running || event.scene != m_scene)
			return;
		for(const pv::Vector3DInt16 &c : chunks_completed(event.section_p))
			run_on_generated_chunk(c);
	}

	// The chunks run_on_generated_chunk() has been over in this run. Not
	// saved: a chunk is complete when its last section is generated, and
	// that happens once, or once more after a trim forgot it.
	std::set<int64_t> m_chunks_run;
	// The chunks a generated section is in that are still missing one,
	// so their on_generated has not run: emerge_area() does not call a
	// block of one there yet, as Luanti calls it after on_generated.
	// simplified: a section between its merge and its event here reads
	// as there already; the window is one event dispatch.
	std::set<int64_t> m_chunks_pending;
	// Sections asked for only to complete a chunk. One of them arriving
	// completes what it can and asks for nothing more: asking again would
	// complete the next chunk out, and the next, without end.
	std::set<uint64_t> m_completion_sections;
	// A pending chunk's sections, pinned the way a forceload pins one
	// until its on_generated has run: the streamer unloads what no point
	// holds, and the game's writes into an unloaded section are dropped --
	// VoxeLibre's bedrock and void were, under the box a test asked for.
	sm_<int64_t, sv_<uint64_t>> m_chunk_pins;

	static int64_t chunk_key(int x, int y, int z)
	{
		return ((int64_t)(int16_t)x << 32) | ((int64_t)(uint16_t)y << 16) |
				(int64_t)(uint16_t)z;
	}

	// Luanti runs a game's on_generated once per mapchunk, over all of
	// it, and a game's chances and boxes are written against that. A
	// chunk is in up to eight sections; this returns the ones this section
	// completed. Near a player or the spawn, the sections a chunk is still
	// missing are asked for too, so the ground there is finished; anywhere
	// else a chunk waits until something wants a block of it (see
	// ask_chunk() in l_loaded_at). Completing every chunk a section touches
	// is what Luanti does not do -- an emerge there generates one chunk --
	// and with VoxeLibre's dungeons, which emerge their own surroundings,
	// it never stopped spreading.
	sv_<pv::Vector3DInt16> chunks_completed(const pv::Vector3DInt16 &section_p)
	{
		using luanti_mapgen::chunk_index;
		sv_<pv::Vector3DInt16> out;
		const int sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		if(sx <= 0)
			return out;
		const int x0 = section_p.getX() * sx, y0 = section_p.getY() * sy,
				z0 = section_p.getZ() * sz;
		const bool asked = m_completion_sections.erase(section_key(section_p));
		// Forceloaded too: Luanti emerges a forceloaded block's whole
		// mapchunk, and with nobody near the sections of it outside the
		// forceload were left to unload before it completed
		const bool may_ask = !asked && (near_a_point(section_p) ||
				m_forceloaded.count(section_key(section_p)));
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(int cz = chunk_index(z0); cz <= chunk_index(z0 + sz - 1); cz++)
			for(int cy = chunk_index(y0); cy <= chunk_index(y0 + sy - 1); cy++)
			for(int cx = chunk_index(x0); cx <= chunk_index(x0 + sx - 1); cx++){
				if(m_chunks_run.count(chunk_key(cx, cy, cz)))
					continue;
				if(ask_chunk(world, cx, cy, cz, may_ask))
					out.push_back(pv::Vector3DInt16(cx, cy, cz));
			}
		});
		if(m_load_points_changed){
			m_load_points_changed = false;
			update_load_points();
		}
		return out;
	}

	// Whether a chunk not yet run has all its sections generated; true
	// marks it run, and the caller runs it. With ask, the missing ones are
	// asked for -- from the save, which is synchronous, or from the
	// generator, whose answer comes back through on_section_generated().
	bool ask_chunk(voxelworld::Instance *world, int cx, int cy, int cz,
			bool ask)
	{
		using luanti_mapgen::CHUNK_NODES;
		using luanti_mapgen::CHUNK_OFFSET;
		const int sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int nx = cx * CHUNK_NODES + CHUNK_OFFSET;
		const int ny = cy * CHUNK_NODES + CHUNK_OFFSET;
		const int nz = cz * CHUNK_NODES + CHUNK_OFFSET;
		const int64_t key = chunk_key(cx, cy, cz);
		bool complete = true;
		const bool pin = ask && !m_chunk_pins.count(key);
		for(int z = floordiv(nz, sz); z <= floordiv(nz + CHUNK_NODES - 1, sz); z++)
		for(int y = floordiv(ny, sy); y <= floordiv(ny + CHUNK_NODES - 1, sy); y++)
		for(int x = floordiv(nx, sx); x <= floordiv(nx + CHUNK_NODES - 1, sx); x++){
			const pv::Vector3DInt16 sp(x, y, z);
			if(pin){
				m_forceloaded[section_key(sp)]++;
				m_chunk_pins[key].push_back(section_key(sp));
				m_load_points_changed = true;
			}
			if(world->is_section_generated(sp))
				continue;
			if(ask){
				world->load_or_generate_section(sp);
				if(world->is_section_generated(sp))
					continue;
				m_completion_sections.insert(section_key(sp));
			}
			complete = false;
		}
		if(complete){
			m_chunks_run.insert(key);
			m_chunks_pending.erase(key);
		} else {
			m_chunks_pending.insert(key);
		}
		return complete;
	}

	// Inside the generate radius of the spawn's point or a player's
	bool near_a_point(const pv::Vector3DInt16 &sp)
	{
		auto in_reach = [&](const pv::Vector3DInt16 &c, int rxz, int ry){
			return std::abs(sp.getX() - c.getX()) <= rxz &&
					std::abs(sp.getZ() - c.getZ()) <= rxz &&
					std::abs(sp.getY() - c.getY()) <= ry;
		};
		if(in_reach(pv::Vector3DInt16(0, 0, 0), SPAWN_RADIUS, SPAWN_RADIUS_Y))
			return true;
		for(const auto &pair : m_player_pos){
			if(in_reach(section_of(pair.second), m_generate_radius_xz,
					GENERATE_RADIUS_Y))
				return true;
		}
		return false;
	}

	// Chunks an emerge completed, run on the next tick: l_loaded_at is
	// called from Lua, and a mod's on_generated is not run inside it
	sv_<pv::Vector3DInt16> m_chunks_to_run;
	// Pins changed inside a voxelworld access, where the points cannot be
	// pushed: whoever made the access pushes them after it
	bool m_load_points_changed = false;

	void run_completed_chunks()
	{
		sv_<pv::Vector3DInt16> list;
		list.swap(m_chunks_to_run);
		for(const pv::Vector3DInt16 &c : list)
			run_on_generated_chunk(c);
	}

	// A mod's on_generated over one mapchunk, as Luanti calls it: the
	// chunk's corners, the blockseed its mapgen used, and what the mapgen
	// reported and mapped there
	void run_on_generated_chunk(const pv::Vector3DInt16 &c)
	{
		using luanti_mapgen::CHUNK_NODES;
		using luanti_mapgen::CHUNK_OFFSET;
		sv_<luanti_mapgen::GennotifyEvent> events;
		luanti_mapgen::SectionMaps maps;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *im){
			im->take_gennotify(c.getX(), c.getY(), c.getZ(), events);
			im->take_maps(c.getX(), c.getY(), c.getZ(), maps);
		});
		const int x0 = c.getX() * CHUNK_NODES + CHUNK_OFFSET;
		const int y0 = c.getY() * CHUNK_NODES + CHUNK_OFFSET;
		const int z0 = c.getZ() * CHUNK_NODES + CHUNK_OFFSET;
		run_on_generated_box(x0, y0, z0, x0 + CHUNK_NODES - 1,
				y0 + CHUNK_NODES - 1, z0 + CHUNK_NODES - 1,
				luanti_mapgen::chunk_blockseed(c.getX(), c.getY(), c.getZ(),
						m_seed),
				gennotify_string(events), maps);
		auto pins = m_chunk_pins.find(chunk_key(c.getX(), c.getY(), c.getZ()));
		if(pins != m_chunk_pins.end()){
			for(uint64_t k : pins->second){
				auto it = m_forceloaded.find(k);
				if(it != m_forceloaded.end() && --it->second <= 0)
					m_forceloaded.erase(it);
			}
			m_chunk_pins.erase(pins);
		}
	}

	// The world create_instance() just made, asked for before anything reads
	// it, and -- in a singlenode world only -- filled here as well.
	//
	// The fill is what makes a singlenode world a world: nobody answers a
	// generation request there, so without it the map is void rather than
	// air. A world with a mapgen must not have it. Its air would be written
	// into sections the generator has not reached yet, and air that is
	// already in the map is terrain as far as anything else is concerned --
	// which is how a v7 world came to have a room the size of this loop
	// under its surface (2026-09-13, and see "What the first playtest of a
	// generated world found" in doc/plan/luanti_module_plan.md).
	//
	// The sections are still asked for either way: worldgen answers in its
	// own thread and the answers arrive after run_game() has returned, but
	// asking early is what gets the ground near the origin on its way
	// before a player is standing on it.
	void generate_world()
	{
		const bool fill = (m_mapgen.mapgen_name() == "singlenode");
		const pv::Vector3DInt32 p0(-SPAWN_RADIUS, -SPAWN_RADIUS_Y,
				-SPAWN_RADIUS);
		const pv::Vector3DInt32 p1(SPAWN_RADIUS, SPAWN_RADIUS_Y,
				SPAWN_RADIUS);
		size_t n = 0, already = 0;
		sv_<pv::Vector3DInt16> generated;
		int64_t t0 = interface::os::time_us();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(int32_t z = p0.getZ(); z <= p1.getZ(); z++)
			for(int32_t y = p0.getY(); y <= p1.getY(); y++)
			for(int32_t x = p0.getX(); x <= p1.getX(); x++){
				pv::Vector3DInt16 section_p(x, y, z);
				// voxelworld makes the region's sections on its first tick
				// rather than when the instance is created, so that a game
				// has its chance to name a save first; that has happened by
				// now, and what is read next is the map, so they are asked
				// for here
				if(!world->is_section_loaded(section_p))
					world->load_or_generate_section(section_p);
				if(!fill)
					continue;
				// A section that has been generated already holds this
				// node everywhere nothing else was built, so one voxel of
				// it says whether the fill has been here -- and a section
				// out of a save is not walked again for nothing. A save
				// from before there was a fill reads as undefined and gets
				// one, which is the migration.
				pv::Region r = world->get_section_region_voxels(section_p);
				if(world->get_voxel(r.getLowerCorner(), true).data != 0){
					already++;
					continue;
				}
				generate_section(world, section_p);
				generated.push_back(section_p);
				n++;
			}
		});
		if(fill){
			log_v(MODULE, "The world: %zu sections filled with one node in "
					"%i ms, %zu already there", n,
					(int)((interface::os::time_us() - t0) / 1000), already);
		} else {
			log_v(MODULE, "The world: the sections around the origin asked "
					"for in %i ms; the mapgen fills them",
					(int)((interface::os::time_us() - t0) / 1000));
		}
		// Outside the access: a mod's on_generated reads and writes the map
		// through a VoxelManip, which is voxelworld again
		for(const pv::Vector3DInt16 &section_p : generated)
			run_on_generated(section_p);
	}

	// A mod's core.register_on_generated, over the section that has just
	// been filled. Luanti runs these after its mapgen has written a chunk
	// and before the block is put in the map; here the fill is already in
	// the map and a mod writes over it, which is the same order from a
	// mod's point of view -- what it reads is the generated terrain and
	// what it writes lands on top.
	//
	// Not inside a voxelworld access: what a mod does here is a VoxelManip,
	// which reaches into voxelworld itself.
	//
	// simplified: per section, with a section's own blockseed. What calls
	// this is a singlenode world's fill, where there is no mapgen chunk;
	// a generated world runs run_on_generated_chunk() instead.
	void run_on_generated(const pv::Vector3DInt16 &section_p)
	{
		if(!m_scene || m_section_size.getX() <= 0)
			return;
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int32_t x0 = (int32_t)section_p.getX() * sx;
		const int32_t y0 = (int32_t)section_p.getY() * sy;
		const int32_t z0 = (int32_t)section_p.getZ() * sz;
		run_on_generated_box(x0, y0, z0, x0 + sx - 1, y0 + sy - 1,
				z0 + sz - 1, (uint32_t)block_seed(section_p), "",
				luanti_mapgen::SectionMaps());
	}

	void run_on_generated_box(int x0, int y0, int z0, int x1, int y1, int z1,
			uint32_t blockseed, const ss_ &gennotify,
			const luanti_mapgen::SectionMaps &maps)
	{
		if(!m_scene)
			return;
		{
			interface::MutexScope ms(m_lua_mutex);
			set_global_string("__luanti_gennotify", gennotify);
			set_global_maps(maps);
		}
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__run_on_generated(%i, %i, %i, %i, %i, %i, %u)",
				x0, y0, z0, x1, y1, z1, (unsigned)blockseed);
		// Timed because it is a mod's code over a quarter of a million
		// voxels on the server's own thread: Luanti generates on an emerge
		// thread of its own, and this module has one Lua state and no
		// thread to put it on. A mapgen that takes longer than a step is
		// what makes that a problem rather than a note.
		const int64_t t0 = interface::os::time_us();
		// No light flood for what the mods write here: the box they
		// touched is relit once, later, under the tick's budget, and the
		// flood from a cave-carving section was 550 ms of the same work
		// ([STEP_SLICE])
		m_gen_writing = true;
		m_gen_wrote = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_deferred(true);
		});
		node_action(buf);
		flush_node_writes();
		m_gen_writing = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_deferred(false);
			if(m_gen_wrote)
				world->relight_region_later(m_gen_bbox);
		});
		const int64_t took = interface::os::time_us() - t0;
		if(took > 1000){
			log_v(MODULE, "on_generated (%i, %i, %i): %i ms",
					x0, y0, z0, (int)(took / 1000));
		}
		// A generator that takes longer than a step is one the streamer
		// should ask less of: one section a pass instead of two, until it
		// is quick again. This is what set_stream_budget() is for, and only
		// this module can see how long its own mods took.
		m_stream_budget = (took > (int64_t)(STEP_S * 1000000.0)) ? 1 : 2;
	}

	// What the mapgen made in a chunk and was asked to report, as a
	// line per event: the name, and where it is. A string because that is
	// the boundary the rest of this crossing uses, and because a section
	// with three hundred decorations in it is ten kilobytes of it.
	static ss_ gennotify_string(
			const sv_<luanti_mapgen::GennotifyEvent> &events)
	{
		ss_ out;
		for(const luanti_mapgen::GennotifyEvent &e : events){
			out += e.name;
			out += " "+itos(e.x)+" "+itos(e.y)+" "+itos(e.z)+"\n";
		}
		return out;
	}

	// __luanti_mapgen_maps = {size_x, size_z, heightmap = {...}, biomemap,
	// heatmap, humiditymap}: the section's maps as Lua arrays, x fastest
	// then z, 1-based; a map the mapgen did not make is absent, and the
	// whole table nil when there are none
	void set_global_maps(const luanti_mapgen::SectionMaps &maps)
	{
		lua_State *L = m_lua;
		if(maps.heightmap.empty() && maps.biomemap.empty()){
			lua_pushnil(L);
			lua_setglobal(L, "__luanti_mapgen_maps");
			return;
		}
		lua_newtable(L);
		lua_pushinteger(L, maps.size_x);
		lua_setfield(L, -2, "size_x");
		lua_pushinteger(L, maps.size_z);
		lua_setfield(L, -2, "size_z");
		auto push_ints = [&](const char *name, const int16_t *p16,
				const uint16_t *pu16, size_t n){
			if(n == 0)
				return;
			lua_createtable(L, (int)n, 0);
			for(size_t i = 0; i < n; i++){
				lua_pushinteger(L, p16 ? (int)p16[i] : (int)pu16[i]);
				lua_rawseti(L, -2, (int)i + 1);
			}
			lua_setfield(L, -2, name);
		};
		auto push_floats = [&](const char *name, const sv_<float> &v){
			if(v.empty())
				return;
			lua_createtable(L, (int)v.size(), 0);
			for(size_t i = 0; i < v.size(); i++){
				lua_pushnumber(L, v[i]);
				lua_rawseti(L, -2, (int)i + 1);
			}
			lua_setfield(L, -2, name);
		};
		push_ints("heightmap", maps.heightmap.data(), nullptr,
				maps.heightmap.size());
		push_ints("biomemap", nullptr, maps.biomemap.data(),
				maps.biomemap.size());
		push_floats("heatmap", maps.heatmap);
		push_floats("humiditymap", maps.humidmap);
		lua_setglobal(L, "__luanti_mapgen_maps");
	}

	// Luanti's get_blockseed2, which is what a mapgen's randomness starts
	// from: the world's seed and where the block is
	int32_t block_seed(const pv::Vector3DInt16 &p)
	{
		return (int32_t)(uint32_t)((uint64_t)m_seed % 0x100000000ULL) +
				(int32_t)p.getZ() * 38134234 +
				(int32_t)p.getY() * 42123 +
				(int32_t)p.getX() * 23;
	}

	// lua/check_map.lua, with the flush this module does between its two
	// halves: a round trip that never leaves the write-behind buffer would
	// prove nothing about voxelworld.
	// The check works above where any mapgen builds, in sections that
	// nothing else keeps: a player's point is elsewhere, the streamer
	// unloads what no point holds, and a generator that arrives after the
	// check has written its room owns that section and writes over it. So
	// the sections are pinned the way a forceload pins one, asked for, and
	// the round trip waits until a generator has been over every one of
	// them -- which is what anything writing terrain of its own has to do.
	void start_check_map()
	{
		m_check_sections = check_map_sections();
		for(const pv::Vector3DInt16 &sp : m_check_sections){
			const uint64_t k = section_key(sp);
			m_forceloaded[k]++;
			m_check_pinned.push_back(k);
		}
		update_load_points();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(const pv::Vector3DInt16 &sp : m_check_sections){
				if(!world->is_section_loaded(sp))
					world->load_or_generate_section(sp);
			}
		});
		m_check_map_pending = true;
		m_check_map_waited = 0.0f;
	}

	// Once a generator has been over all of them; see start_check_map()
	void check_map_when_ready(float dtime)
	{
		if(!m_check_map_pending)
			return;
		m_check_map_waited += dtime;
		// Every section a generator has actually been over, which is what
		// on_section_generated() records. voxelworld calls a section
		// generated as soon as it has asked for one, and the volume arrives
		// later -- so waiting on that would have the check writing its room
		// just before the generator wrote over it.
		bool ready = true;
		for(const pv::Vector3DInt16 &sp : m_check_sections){
			if(m_generated_sections.count(section_key(sp)) == 0){
				ready = false;
				break;
			}
		}
		if(!ready){
			// A world whose generator never answers is a world this cannot
			// check; it is said once and the check is dropped rather than
			// waited for forever
			if(m_check_map_waited < 20.0f)
				return;
			log_w(MODULE, "check_map: the sections it uses were not "
					"generated in %.0f seconds; skipping the check",
					(double)m_check_map_waited);
			m_check_map_pending = false;
			unpin_check_map();
			return;
		}
		m_check_map_pending = false;
		m_generated_sections.clear();
		check_map_round_trip();
		unpin_check_map();
	}

	void unpin_check_map()
	{
		for(uint64_t k : m_check_pinned){
			auto it = m_forceloaded.find(k);
			if(it != m_forceloaded.end() && --it->second <= 0)
				m_forceloaded.erase(it);
		}
		m_check_pinned.clear();
		update_load_points();
	}

	void check_map_round_trip()
	{
		run_chunk_string("if not core.__check_map_write() then\n"
				"    core.log('verbose', 'check_map: no node to write')\n"
				"    core.__check_map_read = function() end\n"
				"end\n", "check_map_write");
		flush_node_writes();
		// A self-check that fails is a warning, not the end of a running
		// game: it has read `ignore` back once under a 6.8 s emerge step
		// with a player in the world, and took the server with it. What
		// it found is logged and stays open -- [CHECK_MAP_FLAKE] in
		// doc/plan/luanti_module_plan.md.
		try {
			run_chunk_string("core.__check_map_read()", "check_map_read");
		} catch(std::exception &e){
			log_w(MODULE, "check_map: the round trip failed and the game "
					"goes on: %s", e.what());
		}
		// The check puts air back where it wrote; that has to land too, or
		// the world starts with a block of cobble nobody asked for
		flush_node_writes();
	}

	// The sections core.__check_map_box() reaches into
	sv_<pv::Vector3DInt16> check_map_sections()
	{
		sv_<pv::Vector3DInt16> out;
		if(!m_lua || m_section_size.getX() <= 0)
			return out;
		int32_t b[6] = {};
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__check_map_box");
			if(lua_pcall(L, 0, 6, 0) != 0){
				log_w(MODULE, "__check_map_box(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return out;
			}
			for(int i = 0; i < 6; i++)
				b[i] = (int32_t)lua_tonumber(L, -6 + i);
			lua_settop(L, base);
		}
		const pv::Vector3DInt16 p0 = section_of(
				pv::Vector3DInt32(b[0], b[1], b[2]));
		const pv::Vector3DInt16 p1 = section_of(
				pv::Vector3DInt32(b[3], b[4], b[5]));
		for(int16_t z = p0.getZ(); z <= p1.getZ(); z++)
		for(int16_t y = p0.getY(); y <= p1.getY(); y++)
		for(int16_t x = p0.getX(); x <= p1.getX(); x++)
			out.push_back(pv::Vector3DInt16(x, y, z));
		return out;
	}

	// The one runnable check the mapblock reader leaves behind: a block put
	// together here in each of the two shapes the format has, and read back.
	// It proves the reader against the spec it was written from; that it
	// agrees with Luanti was checked by importing real worlds at versions
	// 25, 28 and 29 and comparing what arrived with an independent decode of
	// the same database. See doc/plan/luanti_module_plan.md, M7.
	static void check_mapblock()
	{
		const size_t N = luanti_mapblock::NODECOUNT;
		// What the check puts in and expects back
		sv_<uint16_t> id(N, 0);
		sv_<uint8_t> p1(N, 0), p2(N, 0);
		for(size_t i = 0; i < N; i++){
			id[i] = (uint16_t)(i % 300);
			p1[i] = (uint8_t)(i % 251);
			p2[i] = (uint8_t)(i % 253);
		}
		auto u8s = [](ss_ &os, uint32_t v){ os += (char)(v & 0xff); };
		auto u16s = [&](ss_ &os, uint32_t v){
			u8s(os, v >> 8); u8s(os, v);
		};
		auto u32s = [&](ss_ &os, uint32_t v){
			u16s(os, v >> 16); u16s(os, v);
		};
		auto string16 = [&](ss_ &os, const ss_ &v){
			u16s(os, (uint32_t)v.size());
			os += v;
		};
		// Two names, one of them at an id that needs two bytes
		auto nimap = [&](ss_ &os){
			u8s(os, 0);
			u16s(os, 2);
			u16s(os, 7);
			string16(os, "check:stone");
			u16s(os, 299);
			string16(os, "check:sand");
		};
		auto nodes = [&](ss_ &os){
			for(size_t i = 0; i < N; i++)
				u16s(os, id[i]);
			for(size_t i = 0; i < N; i++)
				u8s(os, p1[i]);
			for(size_t i = 0; i < N; i++)
				u8s(os, p2[i]);
		};
		// One node with something hanging off it: a field and a two-slot
		// inventory with one thing in it
		auto node_metadata = [&](){
			ss_ os;
			u8s(os, 2);                 // version
			u16s(os, 1);                // one node has any
			u16s(os, 258);              // x=2, y=0, z=1
			u32s(os, 1);                // one field
			string16(os, "infotext");
			u16s(os, 0);                // a field's length is four bytes
			u16s(os, 11);
			os += "a sign says";
			u8s(os, 0);                 // not private
			os += "List main 2\n";
			os += "Width 0\n";
			os += "Item check:stone 5\n";
			os += "Empty\n";
			os += "EndInventoryList\n";
			os += "EndInventory\n";
			return os;
		};
		// One entity, at one node and two up and three across, and one
		// timer on the node the metadata is on
		auto static_objects = [&](ss_ &os){
			u8s(os, 0);                 // version
			u16s(os, 1);                // one object
			u8s(os, 7);                 // a LuaEntity, which is a mod's own
			u32s(os, 1 * 10 * 1000);    // the position, in BS thousandths
			u32s(os, 2 * 10 * 1000);
			u32s(os, 3 * 10 * 1000);
			string16(os, "an object");
		};
		auto node_timers = [&](ss_ &os){
			u8s(os, 2 + 4 + 4);         // how long one of them is
			u16s(os, 1);                // one node has one
			u16s(os, 258);              // the same node the metadata is on
			u32s(os, 5000);             // five seconds long
			u32s(os, 2500);             // and half way through
		};
		auto check_block = [&](const luanti_mapblock::Block &b,
				const char *what){
			for(size_t i = 0; i < N; i++){
				if(b.param0[i] != id[i] || b.param1[i] != p1[i] ||
						b.param2[i] != p2[i])
					throw Exception(ss_("check_mapblock: ")+what+" came back "
							"wrong at "+itos(i));
			}
			if(b.names.size() != 2 || b.names.at(7) != "check:stone" ||
					b.names.at(299) != "check:sand")
				throw Exception(ss_("check_mapblock: ")+what+" lost its "
						"name-id mapping");
			if(b.meta.size() != 1 || b.meta.count(258) == 0)
				throw Exception(ss_("check_mapblock: ")+what+" came back "
						"with "+itos(b.meta.size())+" nodes of metadata");
			const luanti_mapblock::NodeMeta &m = b.meta.at(258);
			if(m.fields.size() != 1 ||
					m.fields.at("infotext") != "a sign says")
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"field hanging off a node");
			if(m.lists.size() != 1 || m.lists.at("main").size() != 2 ||
					m.lists.at("main")[0] != "check:stone 5" ||
					!m.lists.at("main")[1].empty())
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"inventory hanging off a node");
			if(b.objects.size() != 1 || b.objects[0].type != 7 ||
					b.objects[0].data != "an object" ||
					b.objects[0].x != 1.0f || b.objects[0].y != 2.0f ||
					b.objects[0].z != 3.0f)
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"entity it was holding");
			if(b.timers.size() != 1 || b.timers.count(258) == 0 ||
					b.timers.at(258).timeout != 5.0f ||
					b.timers.at(258).elapsed != 2.5f)
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"timer on a node");
		};

		// Version 29: one zstd frame, and what is wanted is in front of it
		{
			ss_ inside;
			u8s(inside, 0x00);          // flags
			u16s(inside, 0xffff);       // lighting_complete
			u32s(inside, 12345);        // timestamp
			nimap(inside);
			u8s(inside, 2);             // content_width
			u8s(inside, 2);             // params_width
			nodes(inside);
			inside += node_metadata();
			static_objects(inside);
			node_timers(inside);
			ss_ data;
			u8s(data, 29);
			std::ostringstream os(std::ios::binary);
			interface::compress_zstd(inside, os);
			data += os.str();
			luanti_mapblock::Block block;
			luanti_mapblock::deserialize_block(data, block);
			check_block(block, "the version 29 block");
		}

		// Version 25: two zlib streams, and the mapping at the back behind
		// the static objects
		{
			ss_ data;
			u8s(data, 25);
			u8s(data, 0x00);            // flags
			u8s(data, 2);               // content_width
			u8s(data, 2);               // params_width
			ss_ raw_nodes;
			nodes(raw_nodes);
			{
				std::ostringstream os(std::ios::binary);
				interface::compress_zlib(raw_nodes, os);
				data += os.str();
			}
			{
				std::ostringstream os(std::ios::binary);
				interface::compress_zlib(node_metadata(), os);
				data += os.str();
			}
			static_objects(data);
			u32s(data, 12345);          // timestamp
			nimap(data);
			node_timers(data);
			luanti_mapblock::Block block;
			luanti_mapblock::deserialize_block(data, block);
			check_block(block, "the version 25 block");
		}

		// The key a row has, which is three twelve-bit coordinates in one
		// integer and has to survive the negative ones
		const int coords[6] = {0, 1, -1, 2047, -2048, -3};
		for(int i = 0; i < 6; i++){
			for(int j = 0; j < 6; j++){
				int64_t key = (int64_t)coords[j] * 0x1000000 +
						(int64_t)coords[i] * 0x1000 + (int64_t)coords[i];
				pv::Vector3DInt16 p =
						luanti_mapblock::block_pos_of_key(key);
				if(p.getX() != coords[i] || p.getY() != coords[i] ||
						p.getZ() != coords[j])
					throw Exception("check_mapblock: the block key of ("+
							itos(coords[i])+", "+itos(coords[i])+", "+
							itos(coords[j])+") came back as ("+
							itos(p.getX())+", "+itos(p.getY())+", "+
							itos(p.getZ())+")");
			}
		}
		log_v(MODULE, "check_mapblock: both shapes of a block read back");
	}

	// What the LBM list and "[combine" readers make of a few known
	// inputs. Runs once, from run_game(), beside the shapes' and the
	// registry's own checks.
	static void check_params()
	{
		// The LBM list a Luanti world carries, which decides what this
		// module leaves alone in an imported world
		assert(Importer::lbm_names_of("a:one~0;b:two~1234;") == "a:one;b:two;");
		assert(Importer::lbm_names_of("a:one~0") == "a:one;");
		assert(Importer::lbm_names_of("") == "");
		// A name with no time is not a record and is dropped rather than
		// taken as a name, and a record with no name is dropped too
		assert(Importer::lbm_names_of("nope;a:one~0;") == "a:one;");
		assert(Importer::lbm_names_of("~5;") == "");

		// A palette named as a "[combine" expression is the picture it
		// places, cut to the size it names
		{
			int w = 0, h = 0;
			sv_<CombinePlace> places;
			assert(parse_combine(
					"[combine:16x2:0,0=mcl_core_palette_foliage.png",
					w, h, places));
			assert(w == 16 && h == 2);
			assert(places.size() == 1);
			assert(places[0].x == 0 && places[0].y == 0);
			assert(places[0].name == "mcl_core_palette_foliage.png");
			places.clear();
			assert(parse_combine("[combine:4x4:0,0=a.png:1,2=b.png",
					w, h, places));
			assert(places.size() == 2);
			assert(places[1].x == 1 && places[1].y == 2 &&
					places[1].name == "b.png");
			places.clear();
			assert(!parse_combine("mcl_core_palette_grass.png", w, h, places));
			assert(!parse_combine("[multiply:#ff0000", w, h, places));
			assert(!parse_combine("[combine:16x2", w, h, places));
			assert(!parse_combine("[combine:16x2:0,0=", w, h, places));
			assert(!parse_combine("[combine:0x0:0,0=a.png", w, h, places));
		}
	}

	// core.__voxel_defs() -> add_voxel(), in id order, with a solid colour
	// each until M3 brings the real tiles

	// The game's own media, named the way Luanti names it: by basename and
	// nothing else, because a tile string says "default_stone.png" and says
	// nothing about where it came from. A clash between two mods is the
	// game's to avoid, which is the deal Luanti gives them too.
	//
	// Luanti draws no line between a texture, a model, a sound and a
	// translation: whatever sits under a mod's media directories and ends in
	// an extension on the whitelist is media and goes to the client. What
	// the client makes of it is the game's business, not the server's.
	// Luanti's own textures -- the heart, the bubble, the blank tile a HUD
	// draws on, the crack over a node being dug. They are the engine's
	// rather than a game's, so Luanti's client has them built in and never
	// sends them; here the client is buildat's and gets everything from the
	// server, so they are served like any other media if the user has put
	// them where this looks.
	//
	// Not vendored: Luanti's textures are CC BY-SA with their authors listed
	// in its LICENSE.txt, and nothing here copies them into the tree. What
	// the user does is put the pack in buildat's own directory, which is the
	// same rule the games follow -- see apps/vanilla.
	// The render mode the app's settings screen wrote (Paths'
	// settings_file, e.g. vanilla's settings.json), "" when there is none.
	// Read here with no JSON parser: the file is the app's own, one line,
	// and the key's value is a bare word.
	ss_ settings_render_mode()
	{
		if(m_paths.settings_file.empty())
			return "";
		std::ifstream f(m_paths.settings_file);
		if(!f.good())
			return "";
		std::stringstream ss;
		ss << f.rdbuf();
		const ss_ text = ss.str();
		const size_t k = text.find("\"render_mode\"");
		if(k == ss_::npos)
			return "";
		const size_t q1 = text.find('"', k + 13);
		const size_t q2 = q1 == ss_::npos ? ss_::npos : text.find('"', q1 + 1);
		if(q2 == ss_::npos)
			return "";
		return text.substr(q1 + 1, q2 - q1 - 1);
	}

	// Luanti's own base textures -- blank.png, heart.png, bubble.png,
	// what a game's HUD asks the engine for: the copy under the module
	// (textures/base, with its licence), or the user's own if the app
	// names one (Paths' base_textures), which wins
	ss_ base_textures_path()
	{
		const ss_ user = m_paths.base_textures;
		if(!user.empty() && interface::fs::path_exists(user))
			return user;
		return module_path()+"/textures/base/pack";
	}

	// The world's texture pack ([WORLD_TXP]): the one world.mt names as
	// buildat_texture_pack, a directory under Paths' texture_packs, where
	// the app installs them (vanilla: user/shared/vanilla/texture_packs). It
	// goes in front of everything else, because first-one-wins is the rule
	// below and a pack's whole point is to override what the game ships --
	// including the LabPBR sidecars the atlas reads ([VOXEL_MATERIALS]
	// layer 2). None named, none served: a pack is the admin's choice for
	// the world, not every installed one at once.
	// simplified: its override.txt is not applied (vanilla's menu says so)
	void collect_texture_packs(sv_<ss_> &dirs)
	{
		for(const ss_ &d : luanti_media::texture_pack_dirs(m_paths.texture_packs,
				m_mapgen.setting_string("buildat_texture_pack")))
			dirs.push_back(d);
	}

	void serve_game_media(const ss_ &game_path)
	{
		// Luanti's directories, in Luanti's order (src/server/mods.cpp)
		static const sv_<ss_> wanted = {"textures", "sounds", "media",
				"models", "locale", "fonts"};
		sv_<ss_> dirs;
		// The player's packs first: what they hold wins
		collect_texture_packs(dirs);
		// The game's own textures/, beside its mods' (src/server.cpp)
		luanti_media::recursive_dirs(game_path+"/textures", dirs);
		// [MEDIA_OVERRIDE_ORDER] The mods in reverse load order, as
		// Luanti's getModsMediaPaths: a mod loaded later overrides a
		// dependency's media of the same name
		const sv_<ss_> mods = mod_paths_in_load_order();
		for(auto it = mods.rbegin(); it != mods.rend(); ++it)
			for(const ss_ &w : wanted)
				luanti_media::recursive_dirs(*it+"/"+w, dirs);
		// Last, so that the first-one-wins rule below leaves a game's own
		// version of a name in front of the engine's
		const ss_ base_path = base_textures_path();
		if(interface::fs::path_exists(base_path)){
			luanti_media::recursive_dirs(base_path, dirs);
		} else {
			log_w(MODULE, "No Luanti base textures at %s: a game's HUD asks "
					"for the engine's own textures -- blank.png, heart.png, "
					"bubble.png -- and they are not served. Copy Luanti's "
					"textures/base/pack there to have them.",
					cs(base_path));
		}
		const sm_<ss_, ss_> files = luanti_media::collect(dirs);
		// One announce for the lot: a client already connected (the
		// launcher's own, [FIRST_RUN]) fetches them as one batch
		sv_<std::pair<ss_, ss_>> name_paths;
		name_paths.reserve(files.size());
		for(const auto &pair : files)
			name_paths.push_back(std::make_pair(
					media_resource_name(pair.first), pair.second));
		// Every connected peer has this batch on its way now, and its
		// texture modifiers wait for the batch's files_transmitted
		m_files_transmitted.clear();
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_paths(name_paths);
		});
		for(const auto &pair : files)
			m_served_media[pair.first] = pair.second;
		log_i(MODULE, "%zu media files from %zu directories under %s",
				files.size(), dirs.size(), cs(game_path));
	}

	// The mods' directories in the order lua/modloader.lua loaded them
	sv_<ss_> mod_paths_in_load_order()
	{
		sv_<ss_> paths;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mod_names");
		lua_getfield(L, -2, "__mod_paths");
		if(lua_istable(L, -2) && lua_istable(L, -1)){
			for(int i = 1; ; i++){
				lua_rawgeti(L, -2, i);
				if(!lua_isstring(L, -1))
					break;
				lua_gettable(L, -2);
				if(lua_isstring(L, -1))
					paths.push_back(lua_tostring(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
		return paths;
	}




	// One flat PNG per node, generated and handed to client_file rather than
	// written to disk: there is no file behind these and there should not be
	// one. What still uses one is a node whose tile the client cannot load
	// as it stands.
	void serve_node_textures(const sv_<ss_> &names)
	{
		sm_<ss_, ss_> files;
		for(const ss_ &name : names){
			ss_ resource = node_texture_name(name);
			if(files.count(resource))
				continue;
			uint8_t rgb[3];
			node_colour(name, rgb);
			const int size = 16;
			ss_ pixels;
			pixels.reserve(size * size * 3);
			for(int i = 0; i < size * size; i++){
				pixels.push_back((char)rgb[0]);
				pixels.push_back((char)rgb[1]);
				pixels.push_back((char)rgb[2]);
			}
			ss_ png;
			if(!stbi_write_png_to_func(png_write_cb, &png, size, size, 3,
					pixels.c_str(), size * 3)){
				log_w(MODULE, "Could not encode a texture for %s", cs(name));
				continue;
			}
			files[resource] = png;
		}
		client_file::access(m_server, [&](client_file::Interface *ifile){
			for(const auto &pair : files)
				ifile->add_file_content(pair.first, pair.second);
		});
		log_v(MODULE, "%zu node textures served", files.size());
	}

	#include "lua_bindings.h"

	#include "requests.h"
	// [LUANTI_APP_GLUE] The player session (session.h), this the Game
	luanti_session::Session m_session{*this};
	void join_player(const ss_ &name, size_t peer, bool admin)
	{
		m_session.join(name, peer, admin);
	}
	bool player_in_world(size_t peer)
	{
		return m_session.in_world(peer);
	}
	void set_chat_limit(double burst)
	{
		m_session.set_chat_limit(burst);
	}
	void set_chat_gate(std::function<ss_(size_t peer, const ss_ &name)> gate)
	{
		m_session.set_chat_gate(gate);
	}

	// Interface

	// [LUANTI_MODULAR] import.h's
	Importer m_importer{m_server, m_scene, m_lua, m_lua_mutex, m_store,
			m_section_size, m_section_region, m_game_running, m_mapgen,
			[this](){ write_all_node_meta(); },
			[this](const pv::Vector3DInt32 &p){ return section_of(p); },
			[](const pv::Vector3DInt16 &p){ return section_key(p); }};
	void import_world(const ss_ &luanti_world_path)
	{
		m_importer.import_world(luanti_world_path);
	}
	void import_world_settings(const ss_ &luanti_world_path,
			storage::Save *save)
	{
		m_importer.import_world_settings(luanti_world_path, save);
	}

	void set_progress_handler(std::function<void(const ss_ &)> handler)
	{
		m_progress = handler;
	}

	void progress(const ss_ &line)
	{
		// And the log's status line, which the client's waiting screen
		// and a shell start read ([START_PROGRESS])
		log_i(MODULE, "STATUS %s", cs(line));
		if(m_progress)
			m_progress(line);
	}

	// __luanti_progress(text): the mod loader saying which mod it is on
	static int l_progress(lua_State *L)
	{
		Module *self = module_of(L);
		size_t len = 0;
		const char *p = luaL_checklstring(L, 1, &len);
		self->progress(ss_(p ? p : "", len));
		return 0;
	}

	void run_game(const ss_ &game_path, storage::Save *save)
	{
		if(m_game_running)
			throw Exception("luanti: run_game() called twice");
		if(!save)
			throw Exception("luanti: run_game() without a save; the world is "
					"the save");
		m_save = save;
		m_store = save->store("luanti");
		// A directory of the save's rather than the save's own root, so that
		// a mod writing through core.get_worldpath() cannot land on
		// save.sqlite or on anything else of ours it does not expect to be
		// there. devtest's testnodes mod writes a PNG through it while it
		// loads, so this is not hypothetical.
		ss_ world_path = save->path()+"/luanti";
		interface::fs::create_directories(world_path);
		log_i(MODULE, "run_game(): game=%s world=%s",
				cs(game_path), cs(world_path));
		progress("Loading "+game_path.substr(game_path.find_last_of('/') + 1));

		m_lua = luaL_newstate();
		if(!m_lua)
			throw Exception("luanti: cannot create a Lua state");
		luaL_openlibs(m_lua);
		{
			// The Lua sampling profiler, if this run asked for one
			const char *env = getenv("BUILDAT_LUANTI_LUAPROF");
			// The hook is on either way: without the profiler it is only
			// the step watchdog, at an interval coarse enough to cost
			// nothing measurable.
			if(env == nullptr || env[0] == '\0'){
				lua_sethook(m_lua, lua_prof_hook, LUA_MASKCOUNT, 1000000);
			}
			if(env != nullptr && env[0] != '\0'){
				const int n = atoi(env);
				g_lua_prof.interval = n > 0 ? n : 10000;
				g_lua_prof.enabled = true;
				lua_sethook(m_lua, lua_prof_hook, LUA_MASKCOUNT,
						g_lua_prof.interval);
				log_i(MODULE, "Lua profile: sampling every %i instructions; "
						"the report comes at shutdown",
						g_lua_prof.interval);
			}
		}
		// bit.band and its family, before any mod can ask for them
		lua_pushcfunction(m_lua, luaopen_bit);
		lua_pushstring(m_lua, "bit");
		lua_call(m_lua, 1, 0);

		set_global_cfunction("__luanti_log", l_log);
		set_global_cfunction("__luanti_accounts", l_accounts);
		set_global_cfunction("__luanti_get_us_time", l_get_us_time);
		set_global_cfunction("__luanti_list_dir", l_list_dir);
		set_global_cfunction("__luanti_path_exists", l_path_exists);
		set_global_cfunction("__luanti_create_directories", l_create_directories);
		set_global_cfunction("__luanti_encode_png", l_encode_png);
		set_global_cfunction("__luanti_sha1", l_sha1);
		set_global_cfunction("__luanti_sha256", l_sha256);
		set_global_cfunction("__luanti_compress", l_compress);
		set_global_cfunction("__luanti_decompress", l_decompress);
		set_global_cfunction("__luanti_refshot_mark", l_refshot_mark);
		set_global_cfunction("__luanti_emit", l_emit);
		set_global_cfunction("__luanti_set_node", l_set_node);
		set_global_cfunction("__luanti_get_node", l_get_node);
		set_global_cfunction("__luanti_region_to_world", l_region_to_world);
		set_global_cfunction("__luanti_get_region", l_get_region);
		set_global_cfunction("__luanti_get_region_data", l_get_region_data);
		set_global_cfunction("__luanti_set_region_data", l_set_region_data);
		set_global_cfunction("__luanti_noise_value", l_noise_value);
		set_global_cfunction("__luanti_noise_map", l_noise_map);
		set_global_cfunction("__luanti_bounded_pcall", l_bounded_pcall);
		set_global_cfunction("__luanti_forceload", l_forceload);
		set_global_cfunction("__luanti_active_boxes", l_active_boxes);
		set_global_cfunction("__luanti_loaded_boxes", l_loaded_boxes);
		set_global_cfunction("__luanti_find_ids", l_find_ids);
		set_global_cfunction("__luanti_liquid_edges", l_liquid_edges);
		set_global_cfunction("__luanti_find_nodes", l_find_nodes);
		set_global_cfunction("__luanti_ids_at", l_ids_at);
		// The world is not made yet and a mod that asks how big a chunk is
		// asks while it loads -- minetest_game does -- so this carries the
		// default until create_world() knows the real one. Without it the
		// read is of a global that does not exist, which the module's own
		// strict-global guard warns about, once, for nothing.
		set_global_string("__luanti_section_size", "64");
		set_global_cfunction("__luanti_show_objects_to", l_show_objects_to);
		set_global_cfunction("__luanti_show_object_props_to",
				l_show_object_props_to);
		set_global_cfunction("__luanti_send_inventory", l_send_inventory);
		set_global_cfunction("__luanti_send_player_pos", l_send_player_pos);
		set_global_cfunction("__luanti_spawn_level", l_spawn_level);
		set_global_cfunction("__luanti_biome_at", l_biome_at);
		set_global_cfunction("__luanti_relight", l_relight);
		set_global_cfunction("__luanti_send_chat", l_send_chat);
		set_global_cfunction("__luanti_send_hud", l_send_hud);
		set_global_cfunction("__luanti_send_physics", l_send_physics);
		set_global_cfunction("__luanti_send_privs", l_send_privs);
		set_global_cfunction("__luanti_send_camera", l_send_camera);
		set_global_cfunction("__luanti_send_modes", l_send_modes);
		set_global_cfunction("__luanti_send_day_night", l_send_day_night);
		set_global_cfunction("__luanti_send_sound", l_send_sound);
		set_global_cfunction("__luanti_sound_file", l_sound_file);
		set_global_cfunction("__luanti_sound_files", l_sound_files);
		set_global_cfunction("__luanti_add_media", l_add_media);
		set_global_cfunction("__luanti_lua_profile", l_lua_profile);
		set_global_cfunction("__luanti_copy_ints", l_copy_ints);
		set_global_cfunction("__luanti_nest_2d", l_nest_2d);
		set_global_cfunction("__luanti_nest_3d", l_nest_3d);
		set_global_cfunction("__luanti_send_particles", l_send_particles);
		set_global_cfunction("__luanti_send_sky", l_send_sky);
		set_global_cfunction("__luanti_send_lights", l_send_lights);
		set_global_cfunction("__luanti_send_time", l_send_time);
		set_global_cfunction("__luanti_show_formspec", l_show_formspec);
		set_global_cfunction("__luanti_request_shutdown", l_request_shutdown);
		set_global_cfunction("__luanti_player_formspec", l_player_formspec);
		set_global_cfunction("__luanti_send_node_inventory",
				l_send_node_inventory);
		set_global_cfunction("__luanti_progress", l_progress);
		set_global_cfunction("__luanti_step_peak", l_step_peak);
		set_global_cfunction("__luanti_flush_node_writes",
				l_flush_node_writes);
		set_global_cfunction("__luanti_loaded_at", l_loaded_at);
		set_global_cfunction("__luanti_section_state", l_section_state);
		lua_pushlightuserdata(m_lua, (void*)this);
		lua_setfield(m_lua, LUA_REGISTRYINDEX, "__luanti_module");
		set_global_string("__luanti_module_path", module_path());
		// The Lua both clients share, serve_shared_lua()'s; the server's
		// get_translated_string() runs its formspec.lua too
		set_global_string("__luanti_shared_path",
				m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res");
		set_global_string("__luanti_cache_path", luanti_cache_path());
		set_global_string("__luanti_game_path", game_path);
		set_global_string("__luanti_world_path", world_path);

		// Ours first: it is what builds the core table the vendored builtin
		// then expects to be there
		run_chunk_file(module_path()+"/lua/bootstrap.lua");
		run_chunk_file(module_path()+"/vendor/builtin/init.lua");
		// And what this tree adds to what the builtin registered: after it,
		// because it changes commands the builtin has already put there
		run_chunk_file(module_path()+"/lua/chatcommands.lua");
		for(const auto &pair : m_pending_lua)
			run_chunk_string(pair.first, pair.second);
		m_pending_lua.clear();
		// Before the mods load, because a mod can ask the time while it
		// does, and after the builtin, because that is where the clock is
		load_clock();
		load_seed();
		// Which mapgen this world is, before the mods load, because a mod
		// reads it while it loads -- VoxeLibre registers no biomes at all
		// for a singlenode world. The save's own answer, which for an
		// imported world is its map_meta.txt's and is in no setting here.
		set_global_string("__luanti_mapgen_name", m_mapgen.mapgen_name());
		// And which LBMs this world has already had; see Importer::lbm_names_of()
		m_mapgen.publish_lbm_introduced();

		run_chunk_file(module_path()+"/lua/modloader.lua");

		// After the mods, because what the metadata holds is item strings
		// and a mod's items have to be registered for one to mean anything.
		// The node metadata is not read here any more: it comes back with
		// the section it is in, and migrate_node_meta() below is what an
		// older save's one blob of it becomes.
		load_players();
		run_chunk_string("core.__check_players() "
				"core.__check_inventory_move() "
				"core.__check_bone_hand() "
				"core.__check_craft_index()", "check_players");

		check_shapes();
		check_params();
		check_registry();
		check_mapblock();
		luanti_media::check_media_names();

		// The game's own media before the registry, because what a node's
		// tiles can be depends on which files were actually shipped
		progress("Serving the media");
		serve_game_media(game_path);

		// The registry, the world and the light, in that order: the ids the
		// mods asked for while loading are the ids the definitions are built
		// under, and the definitions have to exist before anything is lit.
		progress("Building the world");
		create_world();

		m_game_running = true;

		// The map of another engine's world, if this world is being made
		// out of one: after the nodes and the world, and before anything
		// has asked a generator for a section. The streamer was told to
		// take on nothing while this runs, because a section it generated
		// underneath the import would be one the import cannot have.
		if(!m_importer.m_import_path.empty()){
			progress("Importing the world");
			m_importer.read_luanti_world(m_importer.m_import_path);
			m_importer.m_import_path.clear();
			// What create_world() left to this: the sections around the
			// origin, so that whatever the imported world did not reach
			// still has ground under it
			generate_world();
			m_stream_budget = 2;
			update_load_points();
		}

		start_check_map();

		// Last, so that it is the hour whatever the save or the imported
		// world said
		force_clock();

		m_server->emit_event("luanti:game_loaded", new GameLoaded(m_scene));
	}

	void load_lua(const ss_ &chunk, const ss_ &chunkname)
	{
		if(m_game_running)
			throw Exception("luanti: load_lua() after run_game(); whatever "
					"extends the environment is registered before the game "
					"runs");
		m_pending_lua.push_back({chunk, chunkname});
	}

	// A string that is going into a chunk of Lua as a quoted one. What the
	// caller hands over is a name from the network, and a chunk is code.
	static ss_ lua_quoted(const ss_ &s)
	{
		ss_ out;
		for(char c : s){
			if(c == '"' || c == '\\')
				out += '\\';
			if(c == '\n' || c == '\r')
				continue;
			out += c;
		}
		return out;
	}

	// A chunk of Lua run for its answer, which is how core.dig_node()
	// reaches a game's own click handler from outside Lua
	bool node_action(const ss_ &chunk)
	{
		if(!m_game_running)
			return false;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		if(luaL_loadbuffer(L, chunk.c_str(), chunk.size(), "node_action") != 0){
			log_w(MODULE, "node_action(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return false;
		}
		if(lua_pcall(L, 0, 1, base + 1) != 0){
			log_w(MODULE, "node_action(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return false;
		}
		bool ok = lua_toboolean(L, -1) != 0;
		lua_settop(L, base);
		return ok;
	}

	// A client arrives and leaves, and says where it is. A player is what
	// Luanti calls whoever is on the other end of one: the name is the
	// caller's to choose and is what everything about the player is keyed
	// by. The callbacks a mod registers for a join and a leave run here.
	void add_player(const ss_ &name, size_t peer)
	{
		place_peer(name, peer);
		node_action("core.__add_player(\""+lua_quoted(name)+"\") return true");
	}

	void place_player(const ss_ &name, size_t peer)
	{
		place_peer(name, peer);
		node_action("core.__place_player(\""+lua_quoted(name)+"\") return true");
	}

	void place_peer(const ss_ &name, size_t peer)
	{
		m_player_peers[name] = peer;
		m_peer_players[peer] = name;
		// At the origin until the client says otherwise, which is where a
		// player is put anyway and what keeps the world around them loaded
		// from the moment they are one
		if(!m_player_pos.count(name))
			m_player_pos[name] = pv::Vector3DInt32(0, 0, 0);
	}

	void set_admin(const ss_ &name, bool admin)
	{
		node_action("core.__set_admin(\""+lua_quoted(name)+"\", "+
				(admin ? "true" : "false")+") return true");
	}

	void chat_send(const ss_ &to, const ss_ &text)
	{
		if(to.empty())
			node_action("core.chat_send_all(\""+lua_quoted(text)+
					"\") return true");
		else
			node_action("core.chat_send_player(\""+lua_quoted(to)+"\", \""+
					lua_quoted(text)+"\") return true");
	}

	void remove_player(const ss_ &name)
	{
		node_action("core.__remove_player(\""+lua_quoted(name)+
				"\") return true");
		auto it = m_player_peers.find(name);
		if(it != m_player_peers.end()){
			m_peer_players.erase(it->second);
			m_peer_mode.erase(it->second);
			m_player_peers.erase(it);
		}
		// The world stops being kept loaded around where they were
		m_player_pos.erase(name);
	}

	void set_player_pos(const ss_ &name, float x, float y, float z,
			float look_h, float look_v, int32_t controls)
	{
		// Off the network: a NaN or a 1e30 was undefined in the cast below
		// and "nan" or a cut-off chunk in the Lua one ([SECURITY_RUN_1]).
		// Luanti's world ends at 31007; past 32000 is no position.
		for(float v : {x, y, z, look_h, look_v}){
			if(!std::isfinite(v))
				return;
		}
		if(std::fabs(x) > 32000 || std::fabs(y) > 32000 ||
				std::fabs(z) > 32000 || std::fabs(look_h) > 1e6 ||
				std::fabs(look_v) > 1e6)
			return;
		// What the world streams around and what is active near; the step
		// reads it, so this only writes it down
		m_player_pos[name] = pv::Vector3DInt32(
				(int32_t)std::floor(x), (int32_t)std::floor(y),
				(int32_t)std::floor(z));
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__set_player_pos(\"%s\", %f, %f, %f, %f, %f, %d) "
				"return true",
				lua_quoted(name).c_str(), (double)x, (double)y, (double)z,
				(double)look_h, (double)look_v, (int)controls);
		node_action(buf);
	}

	void player_fell(const ss_ &name, float speed)
	{
		if(!std::isfinite(speed) || std::fabs(speed) > 1e6)
			return;
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__player_fell(\"%s\", %f) return true",
				lua_quoted(name).c_str(), (double)speed);
		node_action(buf);
	}

	bool use_wielded(const ss_ &player_name)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_by_player);
		return node_action("return core.__use_wielded(\""+
				lua_quoted(player_name)+"\")");
	}

	bool drop_wielded(const ss_ &player_name, int count)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_by_player);
		return node_action("return core.__drop_wielded(\""+
				lua_quoted(player_name)+"\", "+itos(count)+")");
	}

	bool punch_object(int32_t id, const ss_ &player_name)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_by_player);
		return node_action("return core.__punch_object(\""+
				lua_quoted(player_name)+"\", "+itos(id)+")");
	}

	void set_wield_index(const ss_ &player_name, int index)
	{
		node_action("core.__set_wield_index(\""+lua_quoted(player_name)+
				"\", "+itos(index)+") return true");
	}

	// A line a player typed, handed to the callbacks the way Luanti's own
	// server hands one over. The "/" commands are among those callbacks,
	// registered by the vendored builtin.
	void chat_message(const ss_ &player_name, const ss_ &message)
	{
		// Luanti's own limit on a chat line, and the reason for one here is
		// that this comes off the network
		static const size_t MAX_CHAT = 500;
		ss_ line = message.size() > MAX_CHAT ?
				message.substr(0, MAX_CHAT) : message;
		PlayerCause cause(m_by_player);
		node_action("core.__chat_message(\""+lua_quoted(player_name)+
				"\", \""+lua_quoted(line)+"\") return true");
	}

	bool dig_node(int32_t x, int32_t y, int32_t z, const ss_ &player_name)
	{
		// The digger is who the drops go to: core.handle_node_drops() puts
		// them in a player's inventory and on the ground for anyone else.
		// An empty name is nobody, which is what it was before there were
		// players.
		ss_ digger = player_name.empty() ? ss_("nil") :
				"core.get_player_by_name(\""+lua_quoted(player_name)+"\")";
		PlayerCause cause(m_by_player, !player_name.empty());
		return node_action("return core.__dig_node({x = "+itos(x)+
				", y = "+itos(y)+", z = "+itos(z)+"}, "+digger+")");
	}

	bool punch_node(int32_t x, int32_t y, int32_t z, const ss_ &player_name)
	{
		ss_ puncher = player_name.empty() ? ss_("nil") :
				"core.get_player_by_name(\""+lua_quoted(player_name)+"\")";
		PlayerCause cause(m_by_player, !player_name.empty());
		return node_action("return core.__punch_node({x = "+itos(x)+
				", y = "+itos(y)+", z = "+itos(z)+"}, "+puncher+")");
	}

	bool place_node(int32_t ux, int32_t uy, int32_t uz,
			int32_t ax, int32_t ay, int32_t az, const ss_ &player_name,
			bool sneak)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_by_player);
		return node_action("return core.__use_node(\""+
				lua_quoted(player_name)+"\", "
				"{x = "+itos(ux)+", y = "+itos(uy)+", z = "+itos(uz)+"}, "
				"{x = "+itos(ax)+", y = "+itos(ay)+", z = "+itos(az)+"}, "+
				(sneak ? "true" : "false")+")");
	}

	sv_<ss_> call_string_list(const ss_ &name)
	{
		return string_list_from_lua(name.c_str());
	}

	ss_ call_json(const ss_ &name, const ss_ &json)
	{
		interface::MutexScope ms(m_lua_mutex);
		if(!m_lua)
			return "";
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__call_json");
		lua_remove(L, -2);
		lua_pushlstring(L, name.c_str(), name.size());
		lua_pushlstring(L, json.c_str(), json.size());
		if(lua_pcall(L, 2, 1, base + 1) != 0){
			log_w(MODULE, "call_json(%s): %s", cs(name),
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return "";
		}
		size_t len = 0;
		const char *p = lua_tolstring(L, -1, &len);
		const ss_ r = p ? ss_(p, len) : "";
		lua_settop(L, base);
		return r;
	}

	Paths m_paths;
	void set_paths(const Paths &paths)
	{
		m_paths = paths;
	}

	// [SKELENTI_SOUNDS] See set_generated_sounds() in api.h
	ss_ m_generated_sound_prefix;
	int m_generated_sound_count = 0;
	void set_generated_sounds(const ss_ &prefix, int count)
	{
		m_generated_sound_prefix = prefix;
		m_generated_sound_count = std::max(0, std::min(count, 9));
	}
	// A sound group's files: Luanti's own suffixes, the plain name and
	// one digit, which is what its media lookup accepts. The names are
	// asked for rather than scanned for, because what the module serves
	// is a hash map. A generated group has .1 .. .<count>, made by the
	// app's client.
	sv_<ss_> sound_files(const ss_ &group)
	{
		sv_<ss_> files;
		if(group.empty())
			return files;
		if(!m_generated_sound_prefix.empty() &&
				group.compare(0, m_generated_sound_prefix.size(),
					m_generated_sound_prefix) == 0){
			for(int d = 1; d <= m_generated_sound_count; d++)
				files.push_back(group+"."+itos(d)+".ogg");
			return files;
		}
		if(m_served_media.count(group+".ogg"))
			files.push_back(group+".ogg");
		for(char d = '0'; d <= '9'; d++){
			const ss_ name = group+"."+d+".ogg";
			if(m_served_media.count(name))
				files.push_back(name);
		}
		return files;
	}

	bool m_server_physics = false;
	void set_server_physics(bool on)
	{
		m_server_physics = on;
	}

	SceneReference get_scene()
	{
		return m_scene;
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_luanti(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
