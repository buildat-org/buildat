// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/init.h"
#include "lua_bindings/util.h"
#include "core/log.h"
#include "client/app.h"
#include "client/config.h"
#include "interface/fs.h"
#include "lua_bindings/tree_depth.h"
#include <tolua++.h>
#include <cstring>
#include <vector>
#include <Context.h>
#include <Scene.h>
#include <Sound.h>
#include <Image.h>
#include <MemoryBuffer.h>
#include <Profiler.h>
#include <ResourceCache.h>
#include <Camera.h>
#include <Graphics.h>
#include <Node.h>
#include <Renderer.h>
#include <RenderSurface.h>
#include <Texture2D.h>
#include <UIElement.h>
#include <Viewport.h>
#define MODULE "lua_bindings"

namespace magic = Urho3D;

extern client::Config g_client_config;

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace lua_bindings {

#define GET_TOLUA_STUFF(result_name, index, type) \
	if(!tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
		tolua_error(L, __PRETTY_FUNCTION__, &tolua_err); \
		return 0; \
	} \
	type *result_name = (type*)tolua_tousertype(L, index, 0);
#define TRY_GET_TOLUA_STUFF(result_name, index, type) \
	type *result_name = nullptr; \
	if(tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
		result_name = (type*)tolua_tousertype(L, index, 0); \
	}

static int l_profiler_block_begin(lua_State *L)
{
	// A name, which Urho3D's profiler reads without asking whether there
	// is one; a server's Lua passing none crashed the next profiler_data
	const char *name = luaL_checkstring(L, 1);

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	Profiler *profiler = context->GetSubsystem<magic::Profiler>();
	if(!profiler)
		return 0;
	// And 64 deep at most: each frame walks the blocks recursively, so a
	// script's million unended begins would have been the stack's end
	int depth = 0;
	for(const ProfilerBlock *b = profiler->GetCurrentBlock(); b; b = b->parent_)
		if(++depth > 64)
			return luaL_error(L, "profiler_block_begin: 64 blocks deep at most");
	profiler->BeginBlock(name);

	return 0;
}

// profiler_data(max_depth) -> string: Urho3D's profiler table for the
// interval since the last call (a block's average and max per frame), which
// is what says where a frame went when the script's own marks do not
// ([FRAME_PEAK]). Each call starts the next interval.
static int l_profiler_data(lua_State *L)
{
	int max_depth = luaL_optinteger(L, 1, 3);

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	Profiler *profiler = context->GetSubsystem<magic::Profiler>();
	if(!profiler)
		return 0;
	magic::String data = profiler->PrintData(false, false, max_depth);
	profiler->BeginInterval();
	lua_pushstring(L, data.CString());
	return 1;
}

static int l_profiler_block_end(lua_State *L)
{
	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	Profiler *profiler = context->GetSubsystem<magic::Profiler>();
	if(profiler)
		profiler->EndBlock();

	return 0;
}

// add_resource_dir(path: string) -> bool
//
// Puts a directory on Urho3D's resource search path, so that files written
// there can be asked for by name. Urho3D's own Lua bindings do not expose
// this, and the Luanti client extension needs it for the media a server sends.
//
// Only directories under the client's cache path are allowed. A resource dir
// is readable by everything the client draws, including sandboxed game code,
// so this is not a general "put any directory on the search path" call.
static int l_add_resource_dir(lua_State *L)
{
	ss_ path = interface::fs::get_absolute_path(lua_checkcppstring(L, 1));
	if(!interface::fs::is_inside_path(path,
			g_client_config.get<ss_>("cache_path")))
		return luaL_error(L, "add_resource_dir(): \"%s\" is not under the "
				"cache path", path.c_str());
	if(!interface::fs::path_exists(path))
		return luaL_error(L, "add_resource_dir(): \"%s\" does not exist",
				path.c_str());

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	ResourceCache *rc = context->GetSubsystem<magic::ResourceCache>();
	bool ok = rc->AddResourceDir(path.c_str());
	if(ok)
		log_v(MODULE, "add_resource_dir(): \"%s\"", cs(path));
	else
		log_w(MODULE, "add_resource_dir(): \"%s\" failed", cs(path));
	lua_pushboolean(L, ok);
	return 1;
}

// render_scene_to_texture(scene: Scene, camera_node: Node, w, h) -> Texture2D
//
// A scene drawn into a texture instead of into the window. What wants it is a
// thumbnail: a model or a voxel volume seen on its own, on a button.
//
// One function rather than RenderSurface, its update modes and the texture
// formats, because a thumbnail is all anyone has needed; exposing the surface
// properly is what a live mirror or a portal would want.
//
// simplified: the surface updates every frame for as long as the texture
// lives, and neither is ever freed. A thumbnail's scene is a few thousand
// voxels at 96x96, so this is cheap, and it is what makes a texture correct
// after geometry that was built asynchronously arrives. The upgrade path is
// a manual update mode and a call to queue one.
static int l_render_scene_to_texture(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(scene, 1, Scene);
	GET_TOLUA_STUFF(camera_node, 2, Node);
	int w = lua_tointeger(L, 3);
	int h = lua_tointeger(L, 4);
	if(w <= 0 || h <= 0 || w > 4096 || h > 4096)
		return luaL_error(L, "render_scene_to_texture(): %ix%i is not a "
				"sensible size", w, h);
	Camera *camera = camera_node->GetComponent<Camera>();
	if(camera == nullptr)
		return luaL_error(L, "render_scene_to_texture(): the node has no "
				"Camera component");

	Context *context = scene->GetContext();
	SharedPtr<Texture2D> texture(new Texture2D(context));
	texture->SetSize(w, h, Graphics::GetRGBFormat(), TEXTURE_RENDERTARGET);
	texture->SetFilterMode(FILTER_BILINEAR);
	RenderSurface *surface = texture->GetRenderSurface();
	if(surface == nullptr)
		return luaL_error(L, "render_scene_to_texture(): the texture has no "
				"render surface");
	surface->SetViewport(0, new Viewport(context, scene, camera));
	surface->SetUpdateMode(SURFACE_UPDATEALWAYS);

	// Held by a reference that is never released, because what goes to Lua is
	// a raw pointer and nothing else holds one. Deliberately leaked rather
	// than kept in a container: a container of SharedPtr destroyed at exit
	// tears a viewport down after Urho3D's context is gone, which is a crash
	// on the way out.
	texture->AddRef();

	tolua_pushusertype(L, (void*)texture.Get(), "Texture2D");
	return 1;
}

// set_preferred_viewports({viewport, ...}). An empty table is teardown.
// The engine draws these at the user's render_scale; see
// CApp::apply_preferred_viewports() in src/client/app.cpp.
static int l_set_preferred_viewports(lua_State *L)
{
	tolua_Error tolua_err;
	if(!lua_istable(L, 1))
		return luaL_error(L, "set_preferred_viewports(): expected a table");

	sv_<Viewport*> viewports;
	size_t n = lua_objlen(L, 1);
	for(size_t i = 1; i <= n; i++){
		lua_rawgeti(L, 1, i);
		GET_TOLUA_STUFF(viewport, -1, Viewport);
		lua_pop(L, 1);
		viewports.push_back(viewport);
	}

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	buildat_app->set_preferred_viewports(viewports);
	return 0;
}

// set_voxel_data(node, data: string)
// A chunk node's buildat_voxel_data from a string, which is what a volume
// serializes to; the mesher reads the var and a string has no way into a
// Variant from the sandbox. For a client's predicted dig or place
// ([PREDICTION]); the server's replication of the var overwrites it.
static int l_set_voxel_data(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(node, 1, Node);
	size_t len = 0;
	const char *data = lua_tolstring(L, 2, &len);
	if(!data)
		throw Exception("set_voxel_data: data must be a string");
	node->SetVar(StringHash("buildat_voxel_data"), Variant(
			PODVector<uint8_t>((const uint8_t*)data, len)));
	return 0;
}

// image_set_data(image, w, h, components, data: string)
// **A generated tile in one call** ([ROOM_BOOT], 2026-09-24): the room
// draws seventy marks at boot and each was four thousand wrapped
// SetPixel calls -- a quarter of a million crossings of the sandbox for
// pictures that are built in Lua and never read back. Image::SetData
// takes the whole buffer, and a Lua string is already one; it is not in
// Urho3D's own .pkg, so it is bound here rather than regenerated there.
// components is 1 to 4: luminance, luminance and alpha, rgb, rgba.
static int l_image_set_data(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(image, 1, Image);
	int w = lua_tointeger(L, 2);
	int h = lua_tointeger(L, 3);
	int comps = lua_tointeger(L, 4);
	size_t len = 0;
	const char *data = lua_tolstring(L, 5, &len);
	if(!data)
		throw Exception("image_set_data: data must be a string");
	if(w < 1 || h < 1 || comps < 1 || comps > 4)
		throw Exception("image_set_data: w, h >= 1 and components 1..4");
	if(len != (size_t)w * (size_t)h * (size_t)comps)
		throw Exception("image_set_data: the string is not w * h * "
				"components bytes");
	if(!image->SetSize(w, h, comps))
		throw Exception("image_set_data: SetSize failed");
	image->SetData((const unsigned char*)data);
	return 0;
}

// sound_set_data(sound, data: string)
// [DOOM_APP] A Sound's samples from a string: safe_classes.lua's
// Sound:SetData(string), which checks the sizes first. A string is how a
// module's wasm hands bytes over; the VectorBuffer it took before was one
// binding call per sample.
static int l_sound_set_data(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(sound, 1, Sound);
	size_t len = 0;
	const char *data = lua_tolstring(L, 2, &len);
	if(!data || len == 0)
		throw Exception("sound_set_data: data must be a string, not empty");
	sound->SetData(data, (unsigned)len);
	return 0;
}

// image_load_data(image, data: string[, max_side]) -> whether it was read
// **A PNG or a JPEG from its bytes** ([HEARTH_ATTACHMENTS]): a picture a
// server sends at run time, as Hearth's thumbnails, not a resource of the
// cache. max_side is 1024 unless said, 4096 at most, and the file is at
// most max_side squared bytes (1 MiB at 1024). A PNG says its size in its
// header and is refused from that before the decode; a JPEG is checked
// once read, the decoder's 8192 a side the cap on what it may unpack to.
// The 4096 is for vanilla's loading picture ([LOADING_PIC_DECODE]), a
// 2 MB 1920x1080 PNG.
static int l_image_load_data(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(image, 1, Image);
	size_t len = 0;
	const char *data = lua_tolstring(L, 2, &len);
	if(!data)
		throw Exception("image_load_data: data must be a string");
	lua_Integer max_side = luaL_optinteger(L, 3, 1024);
	if(max_side < 1 || max_side > 4096)
		throw Exception("image_load_data: max_side is 1 to 4096");
	const unsigned char *u = (const unsigned char*)data;
	auto be32 = [&](size_t i){
		return (uint32_t)u[i] << 24 | (uint32_t)u[i+1] << 16 |
				(uint32_t)u[i+2] << 8 | (uint32_t)u[i+3];
	};
	// IHDR first, where its size is read below: an Apple CgBI chunk before
	// it (stb_image takes those) put the size past the check, and an 8192
	// a side picture was decoded before it was refused ([SEC_RUN5_LEFTOVERS])
	bool png = len >= 24 && memcmp(data, "\x89PNG", 4) == 0 &&
			memcmp(data + 12, "IHDR", 4) == 0;
	bool ok = len <= (size_t)(max_side * max_side) && (png ||
			(len >= 4 && memcmp(data, "\xff\xd8\xff", 3) == 0));
	// IHDR's width and height, bytes 16 to 23
	if(ok && png)
		ok = be32(16) <= (uint32_t)max_side && be32(20) <= (uint32_t)max_side;
	if(ok){
		MemoryBuffer buf(data, (unsigned)len);
		ok = image->Load(buf) && image->GetWidth() <= max_side &&
				image->GetHeight() <= max_side;
	}
	lua_pushboolean(L, ok);
	return 1;
}

// get_voxel_data(node) -> string, or nil for a node without the var
static int l_get_voxel_data(lua_State *L)
{
	tolua_Error tolua_err;
	GET_TOLUA_STUFF(node, 1, Node);
	const Variant &var = node->GetVar(StringHash("buildat_voxel_data"));
	if(var.GetType() != VAR_BUFFER){
		lua_pushnil(L);
		return 1;
	}
	const PODVector<uint8_t> &buf = var.GetBuffer();
	lua_pushlstring(L, buf.Size() ? (const char*)&buf[0] : "", buf.Size());
	return 1;
}

// hold_ref(unsafe) -> a userdata holding a reference to the object, or
// nil for what is not reference counted. **A wrapper keeps its object**
// ([SECURITY_RUN_1]): tolua's userdata is a bare pointer, so an object
// the engine let go of -- a cloned RenderPath with its viewport -- was
// freed under a script's wrapper, and a call through it used it (the
// game fuzz). extension/magic_sandbox holds one of these per object
// wrapped, for as long as a wrapper of it lives.
// Reference counted by tolua's account (its RefCounted), or one of the
// classes it registers without a base though Urho's are reference
// counted. Subsystems are left out: they live as long as the client, and
// a reference held into Lua's close would outlive the Context.
static const char *const HELD_ROOTS[] = {"RefCounted", "Resource",
		"RenderPath", "Viewport", "RenderSurface", "SoundStream"};
// **Released at the frame's start, not in the collector**
// ([HOLD_REF_UAF]): a collection runs at any allocation, and a release
// there that deletes a Scene detaches its whole tree, freeing every node
// only its parent held -- one a binding had just made and not yet handed
// to hold_ref (a script whose scene was collected under its nodes, 4000
// CreateChild in). Nothing is deleted under Lua that way; the client
// calls release_held_refs() at each frame's start, and from its own end
// on the releases are made at once again (the Lua state's close). Never
// destroyed: what an exit by another way left in it is not released after
// the Context.
static std::vector<SharedPtr<RefCounted>> &g_released =
		*new std::vector<SharedPtr<RefCounted>>;
static bool g_release_at_once = false;
static int l_held_ref_gc(lua_State *L)
{
	SharedPtr<RefCounted> *p = (SharedPtr<RefCounted>*)lua_touserdata(L, 1);
	if(!g_release_at_once && *p)
		g_released.push_back(*p);
	p->~SharedPtr();
	return 0;
}
void release_held_refs(bool from_now_at_once)
{
	// Swapped out first: a release that runs Lua can queue more
	std::vector<SharedPtr<RefCounted>> v;
	v.swap(g_released);
	v.clear();
	if(from_now_at_once){
		g_release_at_once = true;
		g_released.clear();
	}
}
static int l_hold_ref(lua_State *L)
{
	tolua_Error err;
	bool held = false;
	for(const char *root : HELD_ROOTS)
		if(tolua_isusertype(L, 1, root, 0, &err))
			held = true;
	for(const char *sub : {"Graphics", "Input", "UI", "Time", "Audio"})
		if(tolua_isusertype(L, 1, sub, 0, &err))
			held = false;
	// simplified: the pointer is cast as tolua casts it, which holds while
	// RefCounted is at the start of every class (Urho's single bases)
	RefCounted *p = held ? (RefCounted*)tolua_tousertype(L, 1, 0) : nullptr;
	if(!p)
		return 0;
	// One a script made (Node(), Scene()) is tolua's to delete when its
	// userdata is collected, whatever else holds it -- the engine, or the
	// reference below: the count decides from here
	void *u = *(void**)lua_touserdata(L, 1);
	lua_getfield(L, LUA_REGISTRYINDEX, "tolua_gc");
	if(lua_istable(L, -1)){
		lua_pushlightuserdata(L, u);
		lua_pushnil(L);
		lua_rawset(L, -3);
	}
	lua_pop(L, 1);
	new(lua_newuserdata(L, sizeof(SharedPtr<RefCounted>)))
			SharedPtr<RefCounted>(p);
	if(luaL_newmetatable(L, "buildat_held_ref")){
		lua_pushcfunction(L, l_held_ref_gc);
		lua_setfield(L, -2, "__gc");
	}
	lua_setmetatable(L, -2);
	return 1;
}

// tree_depth(node_or_element, limit) -> how many levels it is below its
// root, counted up to limit + 1 ([SANDBOX_TREE_DEPTH]), as the sandbox's
// CreateChild asks of each parent: in Lua it was a tolua call a level, and
// chains of a thousand took seconds.
static int l_tree_depth(lua_State *L)
{
	tolua_Error tolua_err;
	int limit = luaL_checkinteger(L, 2);
	TRY_GET_TOLUA_STUFF(node, 1, Node);
	if(node){
		lua_pushinteger(L, tree_depth(node, limit));
	} else {
		GET_TOLUA_STUFF(element, 1, UIElement);
		lua_pushinteger(L, tree_depth(element, limit));
	}
	return 1;
}

// tree_height(element, limit) -> how many levels there are under a UI
// element, counted up to limit + 1 ([SANDBOX_TREE_DEPTH])
static int l_tree_height(lua_State *L)
{
	tolua_Error tolua_err;
	int limit = luaL_checkinteger(L, 2);
	GET_TOLUA_STUFF(element, 1, UIElement);
	lua_pushinteger(L, tree_height(element, limit));
	return 1;
}

void init_misc_urho3d(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(profiler_block_begin);
	DEF_BUILDAT_FUNC(profiler_block_end);
	DEF_BUILDAT_FUNC(profiler_data);
	DEF_BUILDAT_FUNC(add_resource_dir);
	DEF_BUILDAT_FUNC(render_scene_to_texture);
	DEF_BUILDAT_FUNC(set_preferred_viewports);
	DEF_BUILDAT_FUNC(set_voxel_data);
	DEF_BUILDAT_FUNC(get_voxel_data);
	DEF_BUILDAT_FUNC(image_set_data);
	DEF_BUILDAT_FUNC(image_load_data);
	DEF_BUILDAT_FUNC(sound_set_data);
	DEF_BUILDAT_FUNC(hold_ref);
	DEF_BUILDAT_FUNC(tree_depth);
	DEF_BUILDAT_FUNC(tree_height);
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
