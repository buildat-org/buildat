// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/replicate.h"
#include "core/log.h"
#include <luabind/luabind.hpp>
#include <tolua++.h>
#define MODULE "lua_bindings"

namespace lua_bindings {
namespace replicate {

void on_node_created(lua_State *L, uint node_id)
{
	luabind::call_function<void>(L, "__buildat_replicate_on_node_created",
			(uint32_t)node_id);
}

void on_node_removed(lua_State *L, uint node_id)
{
	luabind::call_function<void>(L, "__buildat_replicate_on_node_removed",
			(uint32_t)node_id);
}

// [KIT_STILL_LOOKS] A node's attributes or vars updated by the server: a
// script that reads its nodes only as they change (Kit's) asks which did
// (the replicate extension's take_changed)
void on_node_updated(lua_State *L, uint node_id)
{
	luabind::call_function<void>(L, "__buildat_replicate_on_node_updated",
			(uint32_t)node_id);
}

void set_scene(lua_State *L, magic::Scene *scene)
{
	tolua_pushusertype(L, scene, "Scene");

	int top_L = lua_gettop(L);
	luabind::handle scene_handle(L, top_L);
	luabind::object scene_object(scene_handle);

	luabind::object globals = luabind::globals(L);
	globals["__buildat_replicated_scene"] = scene_object;
}

} // namespace replicate
} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
