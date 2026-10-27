// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
extern "C" {
	struct lua_State;
	typedef struct lua_State lua_State;
}

namespace lua_bindings
{
	void init(lua_State *L);
	// What the collector let go of, released ([HOLD_REF_UAF]): each frame,
	// out of any Lua call; with true at the end, and at once from then on
	void release_held_refs(bool from_now_at_once = false);
}
// vim: set noet ts=4 sw=4:
