// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
extern "C" {
	struct lua_State;
	typedef struct lua_State lua_State;
}
namespace Urho3D
{
	class Scene;
}

namespace lua_bindings
{
	namespace magic = Urho3D;

	namespace replicate
	{
		void on_node_created(lua_State *L, uint node_id);
		void on_node_removed(lua_State *L, uint node_id);
		void on_node_updated(lua_State *L, uint node_id);
		void set_scene(lua_State *L, magic::Scene *scene);
	}
}
// vim: set noet ts=4 sw=4:
