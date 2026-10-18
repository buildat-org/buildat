// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Lua table helpers the module's parts share ([LUANTI_MODULAR]); the
// table is on top of the stack, and a chunk run with a traceback.
#pragma once
#include "core/types.h"
#include "interface/mutex.h"
extern "C" {
#include <lua.h>
}

namespace luanti {

static inline ss_ table_string(lua_State *L, const char *key)
{
	lua_getfield(L, -1, key);
	ss_ v = lua_tostring(L, -1) ? lua_tostring(L, -1) : "";
	lua_pop(L, 1);
	return v;
}

static inline bool table_boolean(lua_State *L, const char *key)
{
	lua_getfield(L, -1, key);
	bool v = lua_toboolean(L, -1);
	lua_pop(L, 1);
	return v;
}

static inline double table_number(lua_State *L, const char *key, double def)
{
	lua_getfield(L, -1, key);
	double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : def;
	lua_pop(L, 1);
	return v;
}

// An array of numbers under key; left empty when it is not there
static inline void table_numbers(lua_State *L, const char *key, sv_<float> &out)
{
	out.clear();
	lua_getfield(L, -1, key);
	if(!lua_istable(L, -1)){
		lua_pop(L, 1);
		return;
	}
	size_t n = lua_objlen(L, -1);
	out.reserve(n);
	for(size_t i = 1; i <= n; i++){
		lua_rawgeti(L, -1, (int)i);
		out.push_back((float)lua_tonumber(L, -1));
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
}

// An array of six strings under key, or false when it is not there
static inline bool table_six_strings(lua_State *L, const char *key, ss_ out[6])
{
	lua_getfield(L, -1, key);
	if(!lua_istable(L, -1)){
		lua_pop(L, 1);
		return false;
	}
	bool ok = true;
	for(size_t i = 0; i < 6; i++){
		lua_rawgeti(L, -1, (int)i + 1);
		cc_ *v = lua_tostring(L, -1);
		if(v)
			out[i] = v;
		else
			ok = false;
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
	return ok;
}

static inline void table_six_numbers(lua_State *L, const char *key, float out[6])
{
	lua_getfield(L, -1, key);
	if(!lua_istable(L, -1)){
		lua_pop(L, 1);
		return;
	}
	for(size_t i = 0; i < 6; i++){
		lua_rawgeti(L, -1, (int)i + 1);
		out[i] = (float)lua_tonumber(L, -1);
		lua_pop(L, 1);
	}
	lua_pop(L, 1);
}

// What a traceback is added by; lua_pcall's error handler
static inline int l_traceback(lua_State *L)
{
	const char *msg = lua_tostring(L, 1);
	lua_getglobal(L, "debug");
	lua_getfield(L, -1, "traceback");
	lua_remove(L, -2);
	lua_pushstring(L, msg ? msg : "(non-string error)");
	lua_pushinteger(L, 2);
	lua_call(L, 2, 1);
	return 1;
}

// A global string in the game's Lua
static inline void set_global_string(lua_State *L, const char *name,
		const ss_ &value)
{
	lua_pushstring(L, value.c_str());
	lua_setglobal(L, name);
}

// A chunk run in the game's Lua, with a traceback; throws on an error
static inline void run_chunk_string(lua_State *L, interface::Mutex &mutex,
		const ss_ &chunk, const ss_ &chunkname)
{
	interface::MutexScope ms(mutex);
	int base = lua_gettop(L);
	lua_pushcfunction(L, l_traceback);
	if(luaL_loadbuffer(L, chunk.c_str(), chunk.size(),
			chunkname.c_str()) != 0){
		ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
		lua_settop(L, base);
		throw Exception("luanti: cannot load "+chunkname+": "+err);
	}
	if(lua_pcall(L, 0, 0, base + 1) != 0){
		ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
		lua_settop(L, base);
		throw Exception("luanti: error in "+chunkname+":\n"+err);
	}
	lua_settop(L, base);
}

// What a function of the game's core table returns as a list of strings;
// empty when there is no game
static inline sv_<ss_> string_list_from_lua(lua_State *L,
		interface::Mutex &mutex, const char *name)
{
	sv_<ss_> flat;
	interface::MutexScope ms(mutex);
	// No game yet -- a server at its world menu -- and a client may
	// ask anyway: an empty answer, not a null state
	if(!L)
		return flat;
	int base = lua_gettop(L);
	lua_getglobal(L, "core");
	lua_getfield(L, -1, name);
	if(lua_pcall(L, 0, 1, 0) != 0){
		log_w(MODULE, "%s(): %s", name,
				lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		lua_settop(L, base);
		return flat;
	}
	size_t n = lua_objlen(L, -1);
	flat.reserve(n);
	for(size_t i = 0; i < n; i++){
		lua_rawgeti(L, -1, (int)i + 1);
		size_t len = 0;
		const char *p = lua_tolstring(L, -1, &len);
		flat.push_back(ss_(p ? p : "", p ? len : 0));
		lua_pop(L, 1);
	}
	lua_settop(L, base);
	return flat;
}

}
// vim: set noet ts=4 sw=4:
