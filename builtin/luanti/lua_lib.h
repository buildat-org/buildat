// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// What C++ gives the game's Lua beside the Module's bindings
// ([LUANTI_MODULAR]): the profiler and the step watchdog, the bounded
// pcall, the table builders, the log and the clock, the directory listing,
// the hashes, compression and core.encode_png(). File-level and static: the
// module is one translation unit, and luanti.cpp registers these.
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/sha1.h"
#include "interface/sha256.h"
#include "interface/compress.h"
#include "luanti/game_media.h"
#include <algorithm>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

namespace luanti {

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

}
// vim: set noet ts=4 sw=4:
