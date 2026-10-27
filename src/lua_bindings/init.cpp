// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/init.h"
#include "core/log.h"
#include "interface/fs.h"
#include <luabind/luabind.hpp>
#include <luabind/class_info.hpp>
#define MODULE "lua_bindings"

namespace lua_bindings {

extern void init_misc(lua_State *L);
extern void init_cereal(lua_State *L);
extern void init_voxel(lua_State *L);
extern void init_atlas(lua_State *L);
extern void init_mesh(lua_State *L);
extern void init_voxel_volume(lua_State *L);
extern void init_voxel_data(lua_State *L);
extern void init_image(lua_State *L);
extern void init_spatial_update_queue(lua_State *L);
extern void init_misc_urho3d(lua_State *L);
extern void init_network(lua_State *L);
extern void init_crypto(lua_State *L);
extern void init_compress(lua_State *L);
extern void init_synth(lua_State *L);
extern void init_wasm(lua_State *L);

void init(lua_State *L)
{
	luabind::open(L);
	luabind::bind_class_info(L);

	init_misc(L);
	init_cereal(L);
	init_voxel(L);
	init_atlas(L);
	init_mesh(L);
	init_voxel_volume(L);
	init_voxel_data(L);
	init_image(L);
	init_spatial_update_queue(L);
	init_misc_urho3d(L);
	init_network(L);
	init_crypto(L);
	init_compress(L);
	init_synth(L);
	init_wasm(L);
}

} // namespace lua_bindingss
// vim: set noet ts=4 sw=4:
