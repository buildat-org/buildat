// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Lua table helpers the module's parts share ([LUANTI_MODULAR]); the
// table is on top of the stack.
#pragma once
#include "core/types.h"
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

}
// vim: set noet ts=4 sw=4:
