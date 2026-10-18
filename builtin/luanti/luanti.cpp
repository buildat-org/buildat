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
#include "luanti/clock.h"
#include "luanti/node_meta.h"
#include "luanti/map_access.h"
#include "luanti/world.h"
#include "luanti/game_media.h"
#include "luanti/players.h"

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
	// Seconds until the startup tables are served as files a second time;
	// see the tick
	float m_startup_files_wait = 5.0f;
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
	pv::Vector3DInt16 m_section_size{0, 0, 0};
	// [LUANTI_MODULAR] players.h's
	Players m_players{m_lua, m_lua_mutex, m_store, m_section_size,
			[this](const ss_ &key, const ss_ &value){ store_set(key, value); }};
	// [LUANTI_MODULAR] map_access.h's
	MapAccess m_map{m_server, m_scene};
	void set_region_map(RegionMap *map)
	{
		m_map.m_region_map = map;
	}
	// [LUANTI_MODULAR] game_media.h's, and registry.h's with its maps
	Media m_media{m_server, m_lua, m_lua_mutex, m_paths, m_mapgen};
	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		m_media.on_files_transmitted(event);
	}
	void on_get_texmods(const network::Packet &packet)
	{
		m_media.on_get_texmods(packet);
	}
	Registry m_registry{m_server, m_lua, m_lua_mutex, m_media.m_served_media,
			m_media.m_texmods, [this](const sv_<ss_> &names){
				m_media.serve_node_textures(names);
			}};

	// How often the clients are told what time it is
	static constexpr float TIME_INTERVAL_S = 5.0f;
	float m_time_accum = 0.0f;
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
	float m_checkpoint_accum = 0.0f;

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
		m_map.flush_node_writes();
		sv_<std::pair<ss_, ss_>> writes;
		m_save_sink = &writes;
		m_clock.save_clock();
		m_players.save_players();
		m_meta.copy_loaded_meta();
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

	// [LUANTI_MODULAR] node_meta.h's
	NodeMeta m_meta{m_server, m_scene, m_lua, m_lua_mutex, m_store,
			m_section_size,
			[this](const ss_ &key, const ss_ &value){ store_set(key, value); }};
	// [LUANTI_MODULAR] clock.h's and mapgen_params.h's, each with the
	// other's
	GameClock m_clock{m_lua, m_lua_mutex, m_store, m_mapgen,
			[this](const ss_ &key, const ss_ &value){ store_set(key, value); }};
	MapgenParams m_mapgen{m_lua, m_lua_mutex, m_store, m_clock.m_world_is_new};

	void on_section_loaded(const voxelworld::SectionLoaded &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		m_meta.load_section_meta(event.section_p);
	}

	void on_section_unloaded(const voxelworld::SectionUnloaded &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		m_meta.save_section_meta(event.section_p);
	}

	// [SAVE_LIMIT] A trimmed section's metadata goes with it
	void on_sections_forgotten(const voxelworld::SectionsForgotten &event)
	{
		if(!m_store || event.scene != m_scene)
			return;
		m_meta.forget(event.sections);
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
				m_world.m_chunks_run.erase(World::chunk_key(cx, cy, cz));
		}
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
				m_media.serve_startup_tables();
		}
		// Other players' digs and the loader's unloads land between steps
		m_map.drop_read_cache();
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
				m_map.drop_read_cache();
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
		m_world.update_load_points();
		if(m_game_running)
			m_world.run_completed_chunks();
		m_world.check_map_when_ready(dtime);
		step_environment(dtime);
		m_map.flush_node_writes();
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

	pv::Vector3DInt16 section_of(const pv::Vector3DInt32 &p)
	{
		return luanti::section_of(p, m_section_size);
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
			self->m_world.m_forceloaded[key]++;
		} else {
			auto it = self->m_world.m_forceloaded.find(key);
			if(it != self->m_world.m_forceloaded.end() && --it->second <= 0)
				self->m_world.m_forceloaded.erase(it);
		}
		log_v(MODULE, "forceload: %zu sections kept",
				self->m_world.m_forceloaded.size());
		// The points are pushed once a step; this only says what they are
		lua_pushboolean(L, wanted ? 1 : 0);
		return 1;
	}

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

	void create_world()
	{
		m_world.read_range_settings();
		// Nothing streams while a world is being imported into this one:
		// see run_game(). The budget goes back to what it was once the
		// import is done.
		if(!m_importer.m_import_path.empty())
			m_world.m_stream_budget = 0;
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
		m_world.update_load_points();

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
		m_media.serve_startup_tables();
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
		params.seed = m_clock.m_seed;
		params.singlenode_word = m_world.singlenode_word();
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
		m_world.m_mapgen_params = params;
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
			m_world.generate_world();

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

		m_players.check_active_range();

		// After the world, because a section is what the metadata is now
		// written per and the section size comes from voxelworld
		m_meta.migrate_node_meta();
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
			[this](){ m_meta.write_all_node_meta(); }};
	// [LUANTI_MODULAR] world.h's
	World m_world{m_server, m_scene, m_lua, m_lua_mutex, m_section_size,
			m_players.m_player_pos, m_players.m_player_peers, m_game_running, m_map, m_clock,
			m_mapgen, m_importer,
			[this](const ss_ &chunk){ return node_action(chunk); }};
	void on_section_generated(const worldgen::SectionGenerated &event)
	{
		m_world.on_section_generated(event);
	}
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
		m_clock.load_clock();
		m_clock.load_seed();
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
		// the section it is in, and the migrate_node_meta() below is what an
		// older save's one blob of it becomes.
		m_players.load_players();
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
		m_media.serve_game_media(game_path);

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
			m_world.generate_world();
			m_world.m_stream_budget = 2;
			m_world.update_load_points();
		}

		m_world.start_check_map();

		// Last, so that it is the hour whatever the save or the imported
		// world said
		m_clock.force_clock();

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
		m_players.place_peer(name, peer);
		node_action("core.__add_player(\""+lua_quoted(name)+"\") return true");
	}

	void place_player(const ss_ &name, size_t peer)
	{
		m_players.place_peer(name, peer);
		node_action("core.__place_player(\""+lua_quoted(name)+"\") return true");
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
		auto it = m_players.m_player_peers.find(name);
		if(it != m_players.m_player_peers.end()){
			m_players.m_peer_players.erase(it->second);
			m_peer_mode.erase(it->second);
			m_players.m_player_peers.erase(it);
		}
		// The world stops being kept loaded around where they were
		m_players.m_player_pos.erase(name);
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
		m_players.m_player_pos[name] = pv::Vector3DInt32(
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
		PlayerCause cause(m_map.m_by_player);
		return node_action("return core.__use_wielded(\""+
				lua_quoted(player_name)+"\")");
	}

	bool drop_wielded(const ss_ &player_name, int count)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_map.m_by_player);
		return node_action("return core.__drop_wielded(\""+
				lua_quoted(player_name)+"\", "+itos(count)+")");
	}

	bool punch_object(int32_t id, const ss_ &player_name)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_map.m_by_player);
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
		PlayerCause cause(m_map.m_by_player);
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
		PlayerCause cause(m_map.m_by_player, !player_name.empty());
		return node_action("return core.__dig_node({x = "+itos(x)+
				", y = "+itos(y)+", z = "+itos(z)+"}, "+digger+")");
	}

	bool punch_node(int32_t x, int32_t y, int32_t z, const ss_ &player_name)
	{
		ss_ puncher = player_name.empty() ? ss_("nil") :
				"core.get_player_by_name(\""+lua_quoted(player_name)+"\")";
		PlayerCause cause(m_map.m_by_player, !player_name.empty());
		return node_action("return core.__punch_node({x = "+itos(x)+
				", y = "+itos(y)+", z = "+itos(z)+"}, "+puncher+")");
	}

	bool place_node(int32_t ux, int32_t uy, int32_t uz,
			int32_t ax, int32_t ay, int32_t az, const ss_ &player_name,
			bool sneak)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_map.m_by_player);
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

	void set_generated_sounds(const ss_ &prefix, int count)
	{
		m_media.set_generated_sounds(prefix, count);
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
