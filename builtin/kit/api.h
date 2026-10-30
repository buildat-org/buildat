// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}
namespace storage
{
	struct Save;
}

// **Kit** ([KIT], doc/plan's kit_plan.md): components any app can host.
// The app's world is a tree of entities: the app the root (id 1), scenes
// under it (the app's main_context scenes, by name), positional entities
// ("objects") in a scene, and entities with no position under the root.
// An entity carries component instances: a component type is a Lua file
// of the app's (<types_path>/<type>.lua) run in Kit's box, a Lua 5.1 in a
// server .wasm (box/box.c, sandboxed and metered by src/wasm/engine.cpp);
// an instance has the type's parameters' values and links from its
// outputs to other entities' inputs.
//
// A component type's file returns a table:
//   params   = {name = {type = "voxel"|"number"|"string"|"bool"|"entity"|
//                "position", default = v}, ...}   -- authored, per instance
//   state    = {name = {default = v, shared = true}, ...} -- runtime; a
//              shared one is replicated to the clients
//   inputs   = {"name", ...}; outputs = {"name", ...}  -- signals, discrete
//   usable   = true          -- a client may "use" it (in range)
//   owns_voxel = true        -- it owns its position's voxel
//   on_input(c, input, value, by), on_use(c, by), on_voxel(c, voxel, by)
// c: c.id, c.pos, c.params (read), c.state (read and written),
// c:emit(output, value), c:set_voxel(name), c:log(...). A component
// reaches its own entity and its links, nothing else. `by` is who caused
// it, "player:<name>" or "app", carried along the links it sets off.
// on_start(c) runs once, when an instance first has runtime state.
//
// Clients act, components react: a client's packet "kit:use" (an entity's
// id) reaches the entity's usable components if the app placed the peer
// (set_peer) in the entity's scene within use_range. A client fires no
// signal: there is no packet for one.
//
// Authored and runtime state are kept apart, each its own row of the
// save's store "kit": "authored" (the composition: entities, instances,
// parameters, links; the composition file the first time) and "runtime"
// (each instance's state, and the disabled ones).
//
// Budgets: each handler run has a slice of the box's meter, and a tick a
// few slices; the queue waits for the next tick past that. A run past its
// slice disables its instance (logged, saved with the runtime), and a new
// box takes over: the server and the other instances go on. A signal
// passed along more than MAX_HOPS links is cut, the loop named.
//
// **The editor** (stage 3): a player with edit rights switches edit mode
// on and edits the authored tree, live for everyone on the server. Edit
// rights by default are builtin/accounts': the server's admin (and the
// launcher's own user), and each account the admin made a builder (the
// account's privilege "builder", kept in the accounts, so for every app
// on the server); set_editor() overrides them for a name. The packet
// "kit:edit", a JSON object of an op:
//   {"op": "mode", "on": true|false}
//   {"op": "place", "type": t, "pos": [x, y, z]}  -- a new entity in the
//       editor's scene with an instance of t (the palette: every
//       <types_path>/*.lua that loads), its id the next
//   {"op": "move", "id": n, "pos": [x, y, z]}    {"op": "delete", "id": n}
//   {"op": "set", "id": n, "comp": i, "param": p, "value": v}
//   {"op": "link"|"unlink", "id": n, "comp": i, "output": o, "to": m,
//    "input": in}
//   {"op": "undo"}  -- the editor's own last edit, UNDO_MAX of them
//   {"op": "builder", "name": account, "on": bool}  -- the admin's only:
//       makes an account a builder, or no longer
// Each is checked on the server, the rights first, then the ids, types,
// parameter values (as the type declares them) and signal names; a
// refusal is logged and answered with "kit:edit_refused" ("<op>: why").
// An editor is sent "kit:edit_state" after each edit, anyone's:
// {"editing", "palette": [type...], "types": {type: {params, inputs,
// outputs, gizmo, usable}}, "authored": the row, "undo": n, "admin",
// and the admin's "people": [{name, admin, builder}] here}, and always
// "can_edit". A player is sent it too as the admin grants or takes their
// rights. A type's
// `gizmo = {shape = "box"|"sphere", size = n, color = "#rrggbb"}` is drawn
// in edit mode only. The client half is builtin/kit/client_lua/module.lua.
namespace kit
{
	struct Host
	{
		// The app's component types, <types_path>/<type>.lua
		ss_ types_path;
		// The composition used when the save has none yet (JSON):
		//   {"entities": [{"id": 2, "name": "world", "kind": "scene"},
		//     {"id": 3, "parent": 2, "name": "door", "pos": [4, 1, 0],
		//      "components": [{"type": "door", "params": {...},
		//        "links": [{"output": "opened", "to": 4, "input": "count"}]}]}],
		//    "next_id": 5}
		// Id 1 is the app (the root); a scene's name is one of `scenes`.
		ss_ composition_path;
		// The save Kit keeps its rows in (its store "kit")
		storage::Save *save = nullptr;
		// The app's scenes by the names the composition gives them; a
		// scene with a voxelworld instance has its voxels owned
		sm_<ss_, main_context::SceneReference> scenes;
		// How far from an entity a player may use it
		double use_range = 6;
	};

	struct Interface
	{
		// The one call: Kit runs the app's composition from here on. False
		// with why when it cannot (no box, a type that does not load).
		virtual bool host(const Host &host, ss_ &why) = 0;
		// Where a player is: Kit takes a client's action only from a peer
		// placed here, in the entity's scene and in range. The app calls it
		// as the player moves; a disconnect forgets it.
		virtual void set_peer(size_t peer, const ss_ &name, const ss_ &scene,
				double x, double y, double z) = 0;
		// The app's own code drives an entity: an input to its components,
		// as a link would deliver it (by "app"). value is JSON.
		virtual void input(uint64_t entity, const ss_ &input,
				const ss_ &value) = 0;
		// A component's runtime state value as JSON, "" when there is none
		virtual ss_ get_state(uint64_t entity, size_t component,
				const ss_ &key) = 0;
		// Edit rights ([KIT] stage 3) by the name set_peer() gives, over
		// the accounts' default (above): given or taken (an editor in edit
		// mode leaves it), for this run
		virtual void set_editor(const ss_ &player, bool can) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(kit::Interface*)> cb)
	{
		return server->access_module("kit", [&](interface::Module *module){
			cb((kit::Interface*)module->check_interface());
		});
	}

	// [KIT] An app hosts Kit by this one call (in its core:start, after
	// its scenes): false with why logged by Kit
	inline bool host(interface::Server *server, const Host &h)
	{
		bool ok = false;
		access(server, [&](Interface *i){
			ss_ why;
			ok = i->host(h, why);
		});
		return ok;
	}
}
// vim: set noet ts=4 sw=4:
