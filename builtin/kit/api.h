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
namespace interface
{
	struct VoxelRegistry;
}

// **Kit** ([KIT], doc/plan's kit_plan.md): components any app can host.
// The app's world is a tree of entities: the app the root (id 1), scenes
// under it (the app's main_context scenes, by name), positional entities
// ("objects") in a scene, and entities with no position under the root.
// An entity carries component instances: a component type is a Lua file
// run in Kit's box, a Lua 5.1 in a server .wasm (box/box.c, sandboxed and
// metered by src/wasm/engine.cpp); an instance has the type's parameters'
// values and links from its outputs to other entities' inputs.
//
// A type is named "<author>/<name>" ([KIT] stage 4b): everyone makes their
// own door. Kit's own generic types are builtin/kit/types/<name>.lua,
// author "kit", in every hosting app; the app's are <types_path>/<name>.lua
// under its author (Host::author, the app's id until publishing binds an
// author to a key). An instance records its type and the type's version
// (the file's `version`). A save from before, its types bare names, is
// read as the app's type of that name if it has one, else Kit's, and
// written back so.
//
// A component type's file returns a table:
//   version  = n             -- a whole number from 1 (1 if left out)
//   params   = {name = {type = "voxel"|"number"|"string"|"bool"|"entity"|
//                "position", default = v}, ...}   -- authored, per instance;
//              a voxel "" is none (a generic type's, which the app's
//              Host::defaults or the composer fills)
//   state    = {name = {default = v, shared = true}, ...} -- runtime; a
//              shared one is replicated to the clients
//   inputs   = {"name", ...}; outputs = {"name", ...}  -- signals, discrete
//   usable   = true          -- a client may "use" it (in range); with an
//                               on_use, the clients point it out as
//                               used by a click ([KIT] stage 4e2)
//   owns_voxel = true        -- it owns its position's voxel
//   volume = "<param>"       -- with owns_voxel: it owns the box of cells
//                               from its own up and on, the extent a
//                               position parameter gives (64 cells at most)
//   zone = "<param>"         -- the box of cells, the same way, that
//                               on_enter/on_leave watch
//   look = {shape = "box"|"sphere", size = n (half its side) or {x, y, z}
//           (its sides), color = "#rrggbb", text = "<shared state key>",
//           extent = "<position param>", depth = n, solid = true,
//           state = "<shared state key>", when = {color, solid, scale =
//           {x, y, z}, swing = true}}  -- drawn where it is on every
//                               client, in both modes (Stopped: the
//                               start's state), the state `text` over
//                               it. extent: a box over those cells from
//                               its own up and on (as zone), its z side
//                               `depth` in its first cells' middle when
//                               given. solid: a collision shape on the
//                               clients (client-side, as the voxels').
//                               while the state `state` is true, `when`
//                               over it: scale its sides (its bottom
//                               kept), swing it a quarter round its -x
//                               edge (a door). kit/door, gate, button,
//                               lever and key_door are such objects
//                               ([KIT] stage 4c; before, voxels they
//                               owned: a save's are migrated, the cells
//                               they owned cleared)
//   hud = "<shared state key>"  -- that state on every client's screen
//   on_input(c, input, value, by), on_use(c, by), on_voxel(c, voxel, by),
//   on_timer(c), on_enter(c, by), on_leave(c, by), on_join(c, by),
//   on_params(c, changed) (a live edit changed its parameters: {name = the
//   value before}), on_remove(c) (it is about to go: deleted while Running,
//   removed by c:remove, or "Restart this" before its on_start)
// c: c.id, c.pos, c.params (read), c.state (read and written; a table in
// it changed in place is written too), c:emit(output, value),
// c:set_voxel(name) (each cell it owns),
// c:after(seconds) (on_timer then, on the game's clock; one an instance,
// c:after() takes it back), c:teleport({x, y, z}) (the player who set the
// run off, the app moving them on kit:move_player), c:log(...) (the
// server's log and the entity's own, which the inspector shows). A
// component reaches its own entity and its links, the entities its entity
// parameters name and the copies it made, and the player who set it off
// (every player with `players = true`), nothing else.
//
// [KIT] stage 4d:
//   Typed signals: inputs = {"a", b = "number"} (a name alone is "any"):
//   any, none (no value), number, bool, string, entity, position. A link
//   joins an output to an input that takes its values; an emitted or
//   delivered value not of its type is logged and not sent.
//   `by` is "player:<id>", the player's entity (a login keeps it), or
//   "app"; c:name(by) the player's name, c.player their entity's id.
//   Players are entities: each player has one in their scene (kind
//   "player", made the first time they come, its id theirs from then on,
//   1000000 and up),
//   carrying each type with `player = true` -- Kit's kit/inventory (the
//   default inventory provider) and kit/score -- not placed, not edited;
//   their state is play state (the round's start resets it), kept in the
//   runtime row (its "players": {name: {id, aside}}). A type with
//   `players = true` reads every player: c.players = {{id, name, here,
//   state = {type = state}}}.
//   Entities made in play: c:spawn{prefab = name | entity = id, pos =
//   {x, y, z}} (a copy of a prefab its prefab parameters name, or of an
//   entity it reaches with what is under it, in its scene at pos or its
//   own position; returns the copy's first id; on_start runs on each),
//   c:remove(id) (an entity it reaches and what is under it; nil itself:
//   on_remove first), c:send(id, input, value) (an input to an entity it
//   reaches), c.made (its copies there now, each by its first id, which
//   c:remove takes the whole copy by). They are play state: what
//   play made is gone at Stop and what it removed back; a type with
//   `builds = true` set off by a player makes builds (Stop's notice, Keep
//   them, Always keep builds), others game changes. Save as start makes
//   them the start's. MAX_MADE at once.
//   Prefabs: a group of entities saved to place again, "<author>/<name>"
//   as types are, in a file of its own (stage 5 publishes it):
//     {"format": "kit_prefab", "author", "name", "version": n,
//      "entities": [{"id": 1..., "parent": 0 (the scene) or an earlier
//      member's id, "name", "pos" (from where a copy is placed),
//      "components": [{"type", "version", "params", "links": [{"output",
//      "to": a member's id, "input"}]}]}]}
//   an entity parameter in it a member's id (0: none). Kit's and the
//   app's are <types dir>/<name>.prefab.json; a builder's ({"op":
//   "save_prefab"}, author their name) the save's row
//   "prefab:<author>/<name>", over a file. A copy's members have new ids,
//   their links and entity parameters among them made the copy's, and
//   remember the prefab ({"prefab": {"of", "version", "member", "copy"}});
//   a parameter set on a copy is its override. A parameter type "prefab"
//   names one; a parameter's `choices` = {...} are the values it takes.
//   Client parts: <name>.client.lua beside a type, sent to every client at
//   join and run there as the client's own Lua is (client_lua/module.lua
//   says what it gets).
//   Looks: shape "wedge", rotation {x, y, z} (degrees), material (plain,
//   metal, glass, glow), and "param:<name>" anywhere in a look is that
//   parameter's value (kit/part).
//   Debugging: the builders with the tools on are sent each tick's signals
//   along links ("kit:flow" [[from, output, to, input]...], their lines
//   lit) and their selection's log ("kit:log" {"id", "lines"}).
//
// That player's inventory: c:count(item, ext) (how many), c:add(item, n,
// ext) (c:give the same), c:take(item, n, ext) (all n or none: true if
// taken), c:list(ext) ({item = n}), c:has(item, n, ext) (count >= n); n is
// 1 if left out, an item letters, digits and _, ext a free-form table the
// provider may read (nil: {}). The provider is the player entity's own
// kit/inventory ([KIT] stage 4d; Kit's counts before); one component may
// replace it for every player: a type with
//   inventory = true, inventory_count(c, player, item, ext),
//   inventory_add(c, player, item, n, ext) (true if added),
//   inventory_take(c, player, item, n, ext) (true if taken, all or none),
//   inventory_list(c, player, ext) ({item = n})
// whose first instance (by entity id) is the provider for every player of
// the app, its c its own (its state written as by its own runs). A second
// is refused, logged. After a run that called them, the player's list is
// sent to their client. A provider whose call runs past the caller's
// budget is disabled itself (logged), not the caller, and the players'
// own kit/inventory is the inventory from then on.
//
// Voxel writes (c:set_voxel, owns_voxel) are game changes, unless the type
// has `builds = true`: then a build of the player who set the run off
// (Edit and play's origins, below).
//
// Grants (dig and place for players, beside the app's edit rights):
//   grants = "<param>"     -- a box of cells (as zone), where the
//                             instance's state dig/place, when true, lets
//                             players dig/place: Interface::can_dig/place;
//                             dig and place are shared, so the clients
//                             show where a click digs ([KIT] stage 4e2).
// `by` is who caused it, "player:<name>" or "app", carried along the links
// it sets off and kept with a timer. Handlers run only while the server
// is Running (below).
// on_start(c) as a round starts from the start (Play, an instance placed
// or restarted in the round); on_join(c, by) as a player goes through the
// round's start and each time the app places them in its scene anew
// (set_peer: the first time, or as another name); on_enter/on_leave as a
// player's position (the cell it rounds to) comes into or leaves its zone.
//
// Clients act, components react: a client's packet "kit:use" (an entity's
// id) reaches the entity's usable components if the app placed the peer
// (set_peer) in the entity's scene within use_range. A client fires no
// signal: there is no packet for one.
//
// Authored and runtime state are kept apart, each its own row of the
// save's store "kit": "authored" (the composition: entities, instances,
// parameters, links; the composition file the first time) and "runtime"
// (each instance's state and timer, the disabled ones, the players'
// items).
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
//       type of Kit's and of the app's that loads), its id the next; a
//       position on a 1/16 cell's grid
//   {"op": "place", "prefab": name, "pos": [x, y, z]}  -- a prefab's copy
//   {"op": "save_prefab", "ids": [n...], "name": n}  -- those entities a
//       prefab of the builder's, they a copy of it; other copies follow
//       its parameters but their overrides
//   {"op": "move", "id": n, "pos": [x, y, z], "yaw": degrees}  -- yaw
//       optional ([KIT] stage 4e2: an entity's turn round y, 0...360, its
//       look turned with it; zones and grants stay boxes of cells)
//   {"op": "move", "ids": [n...], "by": [dx, dy, dz], "turn": degrees}
//       -- entities moved together, one edit, turned about their middle
//   {"op": "duplicate", "ids": [n...], "by": [dx, dy, dz]}  -- a copy of
//       them that far off, their links among them the copies'
//   {"op": "delete", "id": n}
//   {"op": "set", "id": n, "comp": i, "param": p, "value": v}
//   {"op": "link"|"unlink", "id": n, "comp": i, "output": o, "to": m,
//    "input": in}
//   {"op": "undo"}  -- the editor's own last edit, UNDO_MAX of them
//   {"op": "builder", "name": account, "on": bool}  -- the admin's only:
//       makes an account a builder, or no longer
//   {"op": "play"}, {"op": "stop"}, {"op": "save_start"}  -- the server's
//       state, below (a builder's, the tools on or not)
//   {"op": "restart", "id": n, "comp": i}  -- Running: the instance's
//       state from the start again, and its on_start
//   {"op": "focus", "sel": n (0: none), "cursor": [x, y, z] or null}  --
//       what the builder has selected and where their cursor is, which
//       the other builders see (no edit, no undo)
//   {"op": "terrain", "tool": t, "x", "y", "z" (the point on the ground),
//    "size": 1..12 (cells), "strength": 1..5, "biome": b (the World's by
//    default), "level": y, "x1", "z1", "stroke": n}  -- ([KIT] stage 4f)
//       a dab of a brush on the World's surface (voxels or a heightmap):
//       raise, lower, smooth, flatten (toward level), paint (biome b's
//       ground), decorate (b's scatter; in a cave its floor's and wall's),
//       fill (the rectangle x, z to x1, z1 up to level, with b's ground or
//       "water"; voxels only), or column (nothing changed: the column at
//       the point said, for a check). Every dab carrying the same stroke
//       is one undo. On voxels a column's layers follow its biome (by
//       its top cell): the top role over filler (its depth) over stone,
//       the riverbed under sea level, water over it up to sea level; only
//       ground, air, water and plants are written. On a heightmap a
//       sample's layer is stone where steep, the riverbed under the sea,
//       else its biome's top, and decorations are voxel objects. Answered
//       with "kit:terrain" {tool, stroke, undo, what}
// Each is checked on the server, the rights first, then the ids, types,
// parameter values (as the type declares them) and signal names; a
// refusal is logged and answered with "kit:edit_refused" ("<op>: why").
// An editor is sent "kit:edit_state" after each edit, anyone's:
// {"editing", "palette": [type...], "types": {type: {params, inputs,
// outputs, gizmo, usable, root}}, "authored": the row, "undo": n, "admin",
// and the admin's "people": [{name, admin, builder}] here}, and always
// "can_edit", "running" and "by" (who started the round). Everyone is
// sent it as the server's state changes, and a player as the admin grants
// or takes their rights. The builders with the tools on are sent
// "kit:builders" as any of them turns them on or off, selects or moves
// their cursor: [{"name", "color": "#rrggbb", "sel", "cursor"}]. A type's
// `gizmo = {shape = "box"|"sphere", size = n, color = "#rrggbb"}` is drawn
// in edit mode only. The client half is builtin/kit/client_lua/module.lua.
//
// **Edit and play** ([KIT] stage 4c): the server is Stopped or Running,
// server-wide, one session (stage 7 makes more of them). Stopped: the
// world is the start -- each instance's state its start (the save's row
// "start", or its type's defaults), the voxels as they stand -- components
// do not run, a client's use is refused, a grant grants nothing, and
// edits and a builder's voxel writes change the start. Play starts a round
// from the start: each instance's state from the start, its on_start, and
// every player through the round's start (below). Everything play does is
// play state: a section of voxels is copied out the first time anything
// writes to it (voxelworld's section watch), the copy kept in the store
// ("start:<scene>:x,y,z") so a restart mid-round still knows the start.
// Stop puts those sections back (one not loaded when its section loads)
// and each instance's state to its start; "Save as start" makes the play
// state the start (the copies dropped, the row "start" the states now). A
// server starts Running: a fresh save (an empty composition Running is the
// same as Stopped), and one from before stage 4c, its start its types'
// defaults; a restart resumes what the save says. Stopped only by a
// builder's Stop (or the app's set_running).
//
// Origins: a cell play writes is a build or a game change. Builds are what
// players make: their own dig or place (the app says so, player_wrote())
// and the voxel writes of a type with `builds = true` set off by a player;
// game changes are the rest (a component's writes, the app's own). A
// builder's write with the tools on is a live edit, kept. Each cell's
// last origin is its mark ("marks:<scene>:x,y,z", beside its section's
// copy); a build whose cell has another voxel at Stop was changed by the
// game after it, and is the game's. Stop puts the edits back in over the
// copies and discards the builds, and only then tells each builder (and
// each player whose builds they were) who built how many cells, the
// packet "kit:discarded" {"counts": {name: n}, "you", "can_keep"}. The
// builds stay to keep until the next Play (the row "discarded";
// "kit:edit_state"'s "discarded" {name: n}): {"op": "keep"} puts them all
// into the start, each cell its voxel at Stop, {"op": "keep", "names":
// [...]} those players'. "Always keep builds" (kit/player_state's
// keep_builds, "kit:edit_state"'s "always_keep"; {"op": "always_keep",
// "on": bool} sets it, placing a kit/player_state when there is none)
// keeps builds as they are made: Stop discards only game changes, and
// tells no one.
//
// The round's start, for each player there at Play and each that comes
// in the round (once a round): their entity at its start (no items, no
// score; with "keep inventory" the items they had at the last Stop, put
// aside meanwhile), and on_join of each instance in their scene -- a type
// with `spawn = true` places them (kit/spawner; `spawn = "<bool
// parameter>"` while that is true); at Play, with none in their
// scene, the app's default (kit:spawn_player). A type with
// `between_plays = true` (kit/player_state, one, on the app root: a type
// with `root = true` is placed there) gives the round's start its
// parameters keep_inventory and keep_position (at Play the players stay
// where they are). Live editing: while Running an edit changes the start
// and the round at once -- a placed component's on_start and on_join for
// those in its scene, a parameter changed with the state kept, a move, a
// delete, an undo.
//
// Players ([KIT] 4d's answers): a guest's entity (no account, where
// builtin/accounts is) is dropped when they leave or log in; leaving the
// server leaves a zone (on_leave), and joining inside one enters it.
//
// **The World** ([KIT] stage 4e; world.h says how it is made): one
// game-wide kit/world on the app root, its parameters the choices -- the
// generator (empty, flat, noise, valleys), the seed, the biome, the size
// (finite width x depth round the origin, baked; or infinite, only edited
// sections saved, the generator's version pinned in the row "world"), a
// finite map's border (void, wall, water) and the surface (voxels or
// builtin/heightmap's map). An app that has one names its scene
// (Host::world_scene) and creates its voxelworld instance with the region
// WORLD_SECTIONS_XZ / WORLD_SECTION_Y0..Y1 and nothing loaded (Kit sets
// the load points), and its voxels (register_voxels(): Kit's own
// material set, materials.json) before the save. Generators work against
// roles (stone, top, filler, water, riverbed, dust, cave_floor,
// cave_wall) that a material set's biomes bind to voxels, never voxel
// names; a role missing is refused, named. An edit of the World's
// parameters generates again every section nobody wrote; a builder is
// sent "kit:warning" (text) for the seams, a refusal, and what applies
// at the next start. Voxel objects ([VOXEL_OBJECTS]) on a heightmap are
// their own entities once they exist, not the World's.
namespace kit
{
	// The World's voxelworld region, in sections (voxelworld's, WORLD_SECTION
	// voxels a side): what an infinite world may reach, -16384...16383
	// each way, -128...255 up
	static const int WORLD_SECTION = 64;
	static const int WORLD_SECTIONS_XZ = 256;
	static const int WORLD_SECTION_Y0 = -2, WORLD_SECTION_Y1 = 3;

	struct Host
	{
		// The app's component types, <types_path>/<name>.lua ("": none of
		// its own), named <author>/<name>
		ss_ types_path;
		// The app's types' author, letters, digits and _; "" is the app's
		// id (any other character of it a _)
		ss_ author;
		// The app's defaults for types' parameters, over the types' own
		// (JSON): {"kit/door": {"closed": "door"}, ...}
		ss_ defaults;
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
		// Whether the app moves players for a component (c:teleport), on
		// the event "kit:move_player" (MovePlayer). False: a teleport is
		// refused
		bool moves_players = false;
		// [KIT] stage 4e: the scene (a name in `scenes`) the World makes,
		// "" for none (kit/world not in the palette)
		ss_ world_scene;
		// The material set (JSON, world.h's format) binding the roles to
		// the app's voxels; "": Kit's own (materials.json)
		ss_ materials;
	};

	// kit:move_player: a component moves a player (c:teleport); the app
	// puts the peer's feet in the cell at x, y, z of the player's scene,
	// and says so by set_peer (Kit's zones and ranges go by that)
	struct MovePlayer: public interface::Event::Private
	{
		size_t peer = 0;
		double x = 0, y = 0, z = 0;
		MovePlayer(size_t peer, double x, double y, double z):
			peer(peer), x(x), y(y), z(z){}
	};

	// kit:spawn_player: a round starts (Play) and nothing in the player's
	// scene places them: the app puts them at its default spawn (and says
	// so by set_peer)
	struct SpawnPlayer: public interface::Event::Private
	{
		size_t peer = 0;
		SpawnPlayer(size_t peer): peer(peer){}
	};

	// kit:session: the server is Running or Stopped now (Play, Stop, Save
	// as start: saved true), by whom: an app that keeps state of its own
	// beside Kit's resets it here
	struct SessionChanged: public interface::Event::Private
	{
		bool running = false;
		bool saved = false;
		ss_ by;
		SessionChanged(bool running, bool saved, const ss_ &by):
			running(running), saved(saved), by(by){}
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
		// Whether a placed peer has edit rights here (the accounts' or the
		// app's word): an app's own building tools ask it
		virtual bool can_edit(size_t peer) = 0;
		// Whether a component grants a placed peer digging (placing) the
		// voxel at x, y, z of their scene (a type's `grants`). Edit rights
		// are not in it: an app asks it beside can_edit
		virtual bool can_dig(size_t peer, int x, int y, int z) = 0;
		virtual bool can_place(size_t peer, int x, int y, int z) = 0;
		// The server's state ([KIT] stage 4c): Running or Stopped. The app
		// plays or stops as a builder would, by "app" (or another name)
		virtual bool running() = 0;
		virtual void set_running(bool running, const ss_ &by) = 0;
		// A voxel the app wrote for a placed peer in their scene, their own
		// dig or place ([KIT] stage 4c's origins): a build by default, a
		// game change with build false (a mining game's digs), a live edit
		// while their tools are on. Called after the write; nothing while
		// Stopped
		virtual void player_wrote(size_t peer, int x, int y, int z,
				bool build = true) = 0;
		// [KIT] stage 4e: Kit's material set's voxels (kit/stone...)
		// registered, the ones not there yet: before set_save()
		virtual void register_voxels(interface::VoxelRegistry *reg) = 0;
		// Where a player stands at the World's middle: x, z, and y the
		// cell their feet are in (a heightmap's: its surface + 0.5)
		virtual void world_spawn(double &x, double &y, double &z) = 0;
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
