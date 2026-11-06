// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/server.h"
#include "interface/module.h"
#include "core/json.h"
#include "interface/voxel.h"
#include <functional>
#include <cmath>

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
// [KIT_NO_WORLD_TYPES] A type with `no_position = true` has nothing at a
// place (kit/timer, kit/ui_text): an entity with only such types has no
// position, what it is given is dropped, and nothing of it is drawn or
// picked in the world, in the editor neither. It is under its scene, or
// under a positioned entity (kit/starting_kit under a kit/team), and has
// nothing under it; it runs as one in its scene does; a node of its own
// still carries its shared state and its HUD element, not at any place.
// [KIT_NESTING] A positioned entity may be under another one in its scene
// (MAX_NEST levels): its position and yaw are its parent's frame's, so it
// moves and turns with it, and while its parent's look slides
// (kit/mover's when.offset) it is carried there too. Zones, regions,
// grants, owned voxels, use ranges, looks, c.pos and c.yaw are in the
// world through the parents (zones and regions stay boxes of cells, not
// turned). Its node is its scene's child at its place in the world (the
// var "kit_parent": the entity it is under, 0 none). A positioned
// entity's parent is a scene or a positioned entity; a loop, a missing
// parent or one with no position is refused, in an edit and in a save.
// An entity carries component instances: a component type is a Lua file
// run in Kit's box, a Lua 5.1 in a server .wasm (box/box.c, sandboxed and
// metered by src/wasm/engine.cpp); an instance has the type's parameters'
// values and links from its outputs to other entities' inputs. Its code
// has Lua's base (no pcall, coroutines or loadstring), string, table and
// math's abs, min, max, floor, ceil, sqrt, fmod, sin, cos, atan, atan2
// (radians; the box's own, the same on the server and every client), pi,
// huge and random (one sequence in the box).
//
// A type is named "<author>/<name>" ([KIT] stage 4b): everyone makes their
// own door. Kit's own generic types are builtin/kit/types/<name>.lua,
// author "kit", in every hosting app; the app's are <types_path>/<name>.lua
// under its author (Host::author, the app's id); other authors' come in
// packages (below), named "<fp>/<name>" by the package's key
// ([AITTA_KEY_IDENTITY]: fp the key's fingerprint, doc/aitta.txt). An instance records its type and the type's version
// (the file's `version`). A save from before, its types bare names, is
// read as the app's type of that name if it has one, else Kit's, and
// written back so.
//
// A component type's file returns a table:
//   version  = n             -- a whole number from 1 (1 if left out)
//   params   = {name = {type = "voxel"|"number"|"string"|"bool"|"entity"|
//                "position"|"voxels", default = v}, ...}   -- authored,
//              per instance; a voxel "" is none (a generic type's, which
//              the app's Host::defaults or the composer fills). "voxels"
//              ([KIT_VOXEL_STATES]): a pattern of the voxel_box's cells,
//              "" (none) or "<sx> <sy> <sz>;<name> <name>...;<run> ..."
//              -- a palette of names, then each run "i" (one cell of the
//              palette's i, from 0) or "i*n" (n cells), in the box's order
//              (c:voxels'), 4096 cells, 256 names and 32 KiB at most. The
//              editor hides it from the fields: its op "pattern" sets it
//   state    = {name = {default = v, shared = true}, ...} -- runtime; a
//              shared one is replicated to the clients;
//              ([KIT_UI_COMPONENTS]) a per_player = true one is a table
//              {"player:<id>": v} (a `by`'s key), each client sent only
//              its own player's v ("kit:mine" {"all": bool, "list":
//              [{"id", "key", "value"}]}; null: none) while in its scene.
//              simplified: a player's entry stays until the round's start
//              resets the state, in a persistent world for good (one a
//              player who ever set it off); dropping a gone player's is
//              the upgrade
//   inputs   = {"name", ...}; outputs = {"name", ...}  -- signals, discrete
//   about    = {what = "...", inputs = {name = "..."}, outputs = {name = "..."}}
//                            -- [KIT_SIGNALS_DOCS] For the builders, all of it
//                               optional: what the type is, and for each
//                               signal what sets an output off or what an
//                               input does. A signal's first sentence is the
//                               line under it in the Signals view, the whole
//                               text (a line or two; at most 200 bytes shown)
//                               its hover. One with a value says it in a
//                               sentence "Value: ..."
//   usable   = true          -- a client may "use" it (in range); with an
//                               on_use, the clients point it out as
//                               used by a click ([KIT] stage 4e2).
//                               Kit adds its parameter use ("all",
//                               "owners" of the region holding it, or
//                               "nobody": through its links only), asked
//                               after the region's use rule
//                               ([KIT_USE_ACCESS]); a type's own "use"
//                               parameter is refused
//   owns_voxel = true        -- it owns its position's voxel
//   volume = "<param>"       -- with owns_voxel: it owns the box of cells
//                               from its own up and on, the extent a
//                               position parameter gives (64 cells at most)
//   zone = "<param>"         -- the box of cells, the same way, that
//                               on_enter/on_leave watch
//   voxel_box = "<param>"    -- ([KIT_VOXEL_STATES]) the box of cells, the
//                               same way (16 a side at most), that
//                               c:set_voxels writes and the editor's
//                               patterns capture; outlined in the editor;
//                               c.box = {sx, sy, sz} its size
//   reads_voxels = true      -- with voxel_box: c:voxels() the box's cells'
//                               names (x fastest, then z, then y: index
//                               1 + x + sx*(z + sz*y); "" where not loaded)
//   look = {shape = "box"|"sphere", size = n (half its side) or {x, y, z}
//           (its sides), color = "#rrggbb", text = "<shared state key>",
//           extent = "<position param>", depth = n, solid = true,
//           voxel = "<voxel material>",
//           state = "<shared state key>", when = {color, solid, scale =
//           {x, y, z}, swing = true, mirror = true}}  -- drawn where it
//                               is on every client, in both modes (Stopped: the
//                               start's state), the state `text` over
//                               it. extent: a box over those cells from
//                               its own up and on (as zone). voxel: a
//                               box or a wedge (its slope the top)
//                               wears that voxel material's tiles, a
//                               texture a metre as the voxels
//                               (its colour unused; "": none)
//                               [KIT_LOOK_MATERIAL]; kit/door, key_door,
//                               gate, sign and mover's `material`,
//                               kit/part's `voxel`. Its z side
//                               `depth` in its first cells' middle when
//                               given. solid: a collision shape on the
//                               clients (client-side, as the voxels').
//                               while the state `state` is true, `when`
//                               over it: scale its sides (its bottom
//                               kept), swing it a quarter round its -x
//                               edge (a door; towards +z, or with
//                               mirror towards -z [KIT_DOOR_MIRROR]:
//                               "param:mirror", kit/door's). kit/door,
//                               gate, button, lever and key_door are
//                               such objects
//                               ([KIT] stage 4c; before, voxels they
//                               owned: a save's are migrated, the cells
//                               they owned cleared)
//                               Kit adds its parameter own_look (on by
//                               default; [KIT_OWN_LOOK]): off, the look
//                               is not drawn in play (faded in edit
//                               mode), its collision and the entities
//                               under it as ever; a type's own
//                               "own_look" parameter is refused
//   hud = "<shared state key>"  -- that state on every client's screen
//   ui = {kind = "text"|"bar"|"button"|"panel", anchor =, x =, y =,
//         ...}  -- ([KIT_UI_COMPONENTS], stage 4m) drawn on the
//                               players' screens, not in the world
//                               (client_lua/ui.lua; "param:<name>" as a
//                               look's): kit/ui_text, ui_bar, ui_button and
//                               ui_panel. [KIT_HUD_STYLE] Its fields as
//                               theirs: style, width, height, size, color,
//                               background, border, order, a bar's form,
//                               direction, blink_below, source, a panel's
//                               layout and gap; x, y and the sizes in
//                               percent of the screen's shorter side;
//                               prefix: its parameters' names' start, for
//                               edit mode's drags (kit/arena's "hud_").
//                               It is up for a player while its
//                               state `shown` (shared) is true, or their
//                               own in `own` (per_player, {shown}) says
//                               so, and its parent, if a panel
//                               ([KIT_PANEL_PARENT]: of no position, under
//                               which only such UI types go, and c.panel its
//                               id, a component reaching it), is up for
//                               them. A button's press: the packet
//                               "kit:ui" "<id> 1" (pressed) or "<id> 0"
//                               (released), from a placed peer out of the
//                               tools, while Running, in its scene, while
//                               it is up for them, within kit:action's
//                               allowance (one bucket a peer); on_ui(c,
//                               phase, by) on it ("pressed", "released")
//   actions = {{name = "fire", key = "R", label = "Fire"}, ...}
//                            -- ([KIT_INPUT_ACTIONS]) keys the players
//                               press (8 at most; each value a string or
//                               "param:<name>", kit/action's): name
//                               letters, digits and _, key its default (a
//                               key name, Input::GetKeyName's), label the
//                               keys page's and a touch button's. Each
//                               client binds its own key (its key store);
//                               "[name]" in a shown text is that key.
//                               on_action(c, name, phase, value, by) on
//                               every instance declaring it, in the
//                               player's scene or on the root: phase
//                               "pressed", "released" or "held" (every
//                               0.1 s of game time between, value the
//                               seconds held). 16 actions in a world at
//                               most (the first found)
//   on_input(c, input, value, by), on_use(c, by), on_voxel(c, voxel, by),
//   on_timer(c, name, player), on_enter(c, by), on_leave(c, by),
//   on_join(c, by),
//   on_params(c, changed) (a live edit changed its parameters: {name = the
//   value before}), on_remove(c) (it is about to go: deleted while Running,
//   removed by c:remove, or "Restart this" before its on_start)
//   migrate(params, from) ([KIT] stage 5) -- an instance of an older
//                               version `from` (a save's, a prefab's, an
//                               upgraded package's) made this one's: its
//                               parameters returned as this version takes
//                               them; then those it does not declare, or
//                               whose value it refuses, are left out
//                               (logged). No c; none: the parameters as
//                               they were, so filtered
// c: c.id, c.pos, c.params (read), c.state (read and written; a table in
// it changed in place is written too), c:emit(output, value),
// [KIT_SOUNDS] c:sound(name, {everywhere = true}) (a project's sound at
// it, heard in its scene; everywhere, or an entity with no place: not
// positional; 8 a run; "" or nil nothing),
// c:set_voxel(name) (each cell it owns; a `grants` type that owns none:
// each cell of its grants box, 4096 at most),
// c:set_voxels({{x, y, z, name}, ...}) ([KIT_VOXEL_STATES]; a voxel_box
// type: x, y, z from the box's first cell, 0 to its size - 1; 4096 a run;
// all refused, logged, if one is outside the box or its name is not a
// registered voxel; a cell whose section is not loaded is written when
// it is),
// c:after(seconds, name, {player = id}) (on_timer(c, name, player) then,
// on the game's clock, as by whoever set it; [KIT] stage 7b's first part:
// many an instance, 64 at most, each by its name and player, a new one of
// the same replacing it; no name: the unnamed one, on_timer's name and
// player nil; a player: their own, "player:<id>" or c.player's number, a
// button each player may use once in 10 s; no seconds takes that one
// back; due at the first tick at or after its time, and set again in its
// own on_timer counted from when it was due, so a chain keeps its period;
// saved as game time left; the scope is where the component lives,
// so one on a player's entity follows them), c:teleport({x, y, z}) (the player who set the
// run off, the app moving them on kit:move_player), c:log(...) (the
// server's log and the entity's own, which the inspector shows),
// c:app(what, value) ([KIT] stage 6a; the app's own types only: the event
// kit:app, AppCall, its native code's to do; 8 a run). A
// component reaches its own entity and its links, the entities its entity
// parameters name and the copies it made, and the player who set it off
// (every player with `players = true`), the panel it is in (c.panel), nothing
// else.
//
// [KIT_PARTICLES], [KIT_FEEDBACK_EFFECTS] What the clients show at a moment,
// no play reads it. c:effect{...} (32 a run; 240 a second in all, burst 480,
// past it refused and logged at verbose): all optional, each clamped, a bad
// one its default. at {x, y, z} (none: the entity's place) or entity (an id:
// the clients follow its look, a carried flag's), offset; count (256 at most,
// to peers within 128 m in its scene), shape square, round, ring or voxel
// (voxels: 4 material names, the particles sharing them; none: no particles),
// colors (4 "#rrggbb", the particles sharing them), dir, spread (degrees
// either side), speed_min, speed_max, gravity, drag, ttl_min, ttl_max (10 s),
// size_min, size_max (m a side), grow, fade, box, spin, land (stops on the
// ground's voxels within 3 cells); a light, never with a shadow: light_time
// (2 s), light_color, light_range, light_brightness; player (an id): their
// body flash_time s in flash_color for everyone, and on their own screen an
// arc_time s arc in arc_color at the edge towards arc_from {x, y, z}.
// Packets: "kit:effect", "kit:effect_arc" (that player's alone). A client
// keeps 1500 particles at most and drops what is past that.
// World events: `events = "<a string parameter>"` in a type and on_event(c,
// ev, by) on every instance in the scene whose parameter names the kind:
// "dig", "place" (ev.pos, ev.voxels
// {material}, ev.player), "hit" (ev.pos at the target's body, ev.player a hit
// player's id, ev.from where it came from, ev.dir the way its spray goes:
// towards a hitter, away from a blast; ev.share of its health, at most 1),
// "blast" (ev.pos, ev.radius, ev.voxels the blown ones' 4 commonest
// materials, ev.cells), "respawn" (ev.pos, ev.player), or any other a
// component says with c:event(kind) (at it, 8 a run: kit/pickup's "pickup").
// types/effect.lua is the type a composition uses for all of it.
//
// [KIT] stage 4d:
//   Typed signals: inputs = {"a", b = "number"} (a name alone is "any"):
//   any, none (no value), number, bool, string, entity, position. A link
//   joins an output to an input that takes its values; an emitted or
//   delivered value not of its type is logged and not sent.
//   "string:player" is a string the editor calls a player; a link does not
//   look at the label.
//   `by` is "player:<id>", the player's entity (a login keeps it), or
//   "app"; c:name(by) the player's name, c.player their entity's id (on
//   on_leave, a guest's entity may be gone by then: its id still).
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
//   as types are, in a file of its own (a package's, below):
//     {"format": "kit_prefab", "author", "name", "version": n,
//      "entities": [{"id": 1..., "parent": 0 (the scene) or an earlier
//      member's id, "name", "pos" (from where a copy is placed; under a
//      member with a position, [KIT_NESTING], in that member's frame),
//      "components": [{"type", "version", "params", "links": [{"output",
//      "to": a member's id, "input"}]}]}],
//      "voxels": {"at": [x, y, z], "size": [x, y, z], "air": bool,
//       "kinds": [[voxel, param, tint]...], "runs": [count, kind...]}}
//   an entity parameter in it a member's id (0: none).
//   [KIT_PREFAB_VOXELS] "voxels" (optional; then it may have no entities)
//   is a box of cells (MAX_PREFAB_BOX each way) at `at` from its base (a
//   cell's middle), each cell a kind (MAX_PREFAB_KINDS), the runs x
//   fastest, then z, then y. A copy writes them into the editor's scene
//   with its entities, one undo: their air cells skipped unless "air"
//   (air replaces), cells not loaded and voxels the scene has not
//   skipped. A copy turned (place's turn, quarter turns about its base)
//   turns its members, their yaws, its cells and a shape's facing (its
//   param, world.h's Shapes). Links between its entities and the cells
//   they own stay its own: an owned voxel is its entity's (own_voxels()).
//   simplified: a prefab copied in play (c:spawn) makes its entities, not
//   its voxels; a cell's owned data is not in it. Kit's and the
//   app's are <types dir>/<name>.prefab.json; a builder's ({"op":
//   "save_prefab"}, author their name) the save's row
//   "prefab:<author>/<name>", over a file. [KIT_PREFAB_ROOT] The editor's
//   place makes a root (kit/prefab_copy, no position if the prefab has no
//   positioned member and no voxels; {"prefab": {"of", "version", "voxels"}})
//   and the members its built children, new ids, links and entity parameters
//   among them made the copy's. A save builds every other copy again:
//   members, links and parameters follow, a parameter set on a copy (its
//   override) and a member moved on it kept, a member deleted from it back.
//   Voxels never follow: a copy's are world cells, written only at its place,
//   by the op "stamp" (the editor's Refresh voxels, and after a move). The
//   root's turn is its yaw; a stamp takes multiples of 90. A copy made in
//   play (c:spawn) has no root, its members remember the prefab
//   ({"prefab": {"of", "version", "member", "copy"}}).
//   A parameter type "prefab"
//   names one; a parameter's `choices` = {...} are the values it takes;
//   `choices_from = "biomes"` makes the inspector's a dropdown of the
//   material set's biomes (a string still; the World refuses another).
//   `choices_from = "scenes"`: a dropdown of the composition's scenes
//   and "none" (""). [KIT_SOUNDS] A parameter type "sound": a dropdown of
//   the project's sounds and "none" ("").
//   [KIT_PARAM_CATEGORIES] A parameter's `cat` is the inspector's category
//   it is under: "behaviour" (without one), "hud", "look" (appearance in
//   the world and sounds), "physics" or "advanced" (technical: poll, rate,
//   substeps). Another value is warned of at the type's load and treated
//   as behaviour. A type with 8 parameters or more in two categories or
//   more gets a row of chips for them.
//   Client parts: <name>.client.lua beside a type, sent to every client at
//   join and run there as the client's own Lua is (client_lua/module.lua
//   says what it gets).
//   [KIT_GENERATORS] **Generators**: a type with on_build(c) builds its
//   own children from c.params, in the editor: as it is placed (not a
//   copy that has its own: a duplicate, a prefab's, a paste) and as an
//   edit changes its parameters, into that edit (one undo puts the old
//   children back). In it: c:child{type =, pos = {x, y, z} (its frame's;
//   0, 0, 0 if none), yaw =, name =, params =, parent = an earlier
//   child's number} -> the child's number (1...), c:link(from, output, to,
//   input) (between children by their numbers, to 0 the generator
//   itself), c:voxel_box{at =, size =, cells = {name...} (x fastest, then
//   z, then y), air = bool} (a prefab's voxels, written about it as a
//   prefab copy's). What it returns is checked as a prefab is
//   (check_prefab()), MAX_BUILT children at most, no generator, root,
//   World or environment among them; it runs with a call's budget (a
//   build is not a tick's), past it the edit refused. Its children are
//   ordinary authored entities marked {"built": {"by": the generator,
//   "member": n, "moved": true once a builder moved it}}: a build again
//   keeps a child of the same number, type and parent (its id, its
//   overrides -- a parameter set on it -- its links to others and theirs
//   to it, what was put under it by hand, its place if it was moved),
//   and removes those it no longer makes (what a builder put under one
//   then under the generator, where it was); one a builder put under
//   another entity is theirs. A child not built (a builder's) is left as
//   it is. Copies (duplicate, prefab, paste, c:spawn) carry the marks.
//   simplified: the voxels an earlier build wrote stay where a new one
//   writes none; a copy following its prefab builds again as its
//   parameters change, its built children's overrides kept over the
//   prefab's values. A build at each session's start: stage 7.
//   [KIT] stage 5 **Packages**: component types, prefabs and builders'
//   voxel types published to Aitta as a package of "kind": "kit"
//   (doc/aitta.txt). [AITTA_KEY_IDENTITY] A package is its key and its
//   name, "<fp>/<name>", and its things are "<fp>/<n>": two Aittas'
//   "alice" are two. Its files name them by its manifest's author
//   (whom its Aitta binds to the key), "<author>/<n>":
//     meta.json      the manifest, with "dependencies": [{"kit":
//                    "<author>/<name>", "version": the lowest it works
//                    with}] (the packages its prefabs' types are of)
//     types/<n>.lua, <n>.client.lua   the type <author>/<n>
//     types/<n>.prefab.json           the prefab <author>/<n>
//     types/<n>.voxel.json            the voxel type <author>/<n> (as
//                    {"op": "voxel"} has it; "texture" a registered one's
//                    or textures/<file>.png in the package)
//     types/<n>.sound.json            ([KIT_SOUNDS]) the sound <author>/<n>,
//                    {"params": "blip1:..."}
//     materials.json ([KIT_MATERIAL_SETS]) a material set (world.h): its
//                    voxels its voxel types, "extends" kit/default or a
//                    dependency's set; a World's "materials" may name it
//                    (Host::material_sets), the row's "materials" holding
//                    it with its textures served
//   A builder installs one into the save from the palette's New tab:
//   "kit:package" (the Aitta it came from, a 0 byte, the release's .sig,
//   a 0 byte, its zip; the client fetched them from that Aitta with the
//   dependencies, which go first), its signature checked, its
//   dependencies installed here at their versions or newer (each "<author>/
//   <name>" the one installed from the same Aitta, or the key an older
//   version resolved it to), nothing of it another's (a builder's,
//   another package's). Its prefabs' and voxel types' "<author>/<n>" of
//   its own author or a dependency's are made "<fp>/<n>" as it is
//   installed (simplified: in their JSON; a type's Lua names others as
//   stored, "<fp>/<n>"). It is the rows "package:<fp>/<name>"
//   ({"version", "key", "sha256", "by", "aitta", "local", "vouched",
//   "deps": {"<author>/<name>": "<fp>/<name>"}, "manifest", "types":
//   {name: {"source", "client"}}, "prefabs", "voxels"}), "prefab:..." and
//   "voxel:..." ({"package"} in each) and "texture:...". The server asks
//   the named Aitta whose key it is (interface::aitta::vouch_guarded(),
//   whose limits say where it may go; the setting kit_vouch narrows it);
//   until it says the manifest's author, the package is shown
//   "alice/lamps @<host> (unverified)". Where two packages' authors have
//   one name, each is shown with its Aitta's host. "kit:edit_state"'s
//   "names": {"<fp>/<n>" or a package's id: as shown}. A newer version upgrades it in place: it keeps the
//   types the older had, and each authored instance of an older version
//   of a type is migrated (migrate above). Answered with "kit:package"
//   {"ok": true, "what"} or {"ok": false, "why"}. {"op": "export"}: the
//   builder's own prefabs and voxel types as a package's files
//   ("kit:export" {"author", "files", "hex", "dependencies"}; the
//   packages' "<fp>/" its author's name again, a dependency its
//   "<author>/<name>"), which the editor hands the client's publish
//   screen. Credits: each client's
//   "kit:edit_state" has "credits", [{"author" (a package's with its
//   Aitta's host where it is ambiguous or unverified), "package"
//   ("<author>/<name>"), "id", "aitta", "verified", "version",
//   "license_code", "license_media" (a package's), "of": "kit"|"app",
//   "uses": [types, "[prefab]"]}], what the composition uses by who made
//   it (kit.show_credits(), the palette's Credits).
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
// Voxel writes (c:set_voxel, c:set_voxels, owns_voxel) are game changes, unless the type
// has `builds = true`: then a build of the player who set the run off
// (Edit and play's origins, below).
//
// [KIT_VOXEL_STATES] kit/voxel_replace and kit/voxel_states write a box
// of voxels (their `size`, 16 a side at most), inputs on/off/toggle, the
// shared state "on" (`start_on` at the start, which they write then),
// the output "changed" (the new on). voxel_replace: on, every `find` cell
// becomes `replace` (either may be air), the cells it changed kept (the
// round's, not shared); off, of those only the ones still `replace` go
// back (one that was `replace` before, or one dug in between, stays). A
// repeated on or off changes nothing. voxel_states: its patterns a and b
// ("voxels"), on writing b and off a, only the cells that differ; an
// empty one writes nothing. Their writes are game changes (End puts the
// start back).
//
// Grants (dig and place for players, beside the app's edit rights):
//   grants = "<param>"     -- a box of cells (as zone), where the
//                             instance's state dig/place, when true, lets
//                             players dig/place: Interface::can_dig/place;
//                             dig and place are shared, so the clients
//                             show where a click digs ([KIT] stage 4e2).
// Regions ([KIT] stage 4j, kit/region):
//   region = "<param>"     -- a box of cells (as zone) whose state decides
//                             dig, place, enter, pvp, damage and use in it:
//                             enabled (false: it decides nothing), owners
//                             ("nobody", "builders", or names) and rules
//                             ({dig = {owners, others}, ...}), all shared.
//                             The smallest holding a cell decides
//                             (Interface::allows); a component on its
//                             entity with allow(c, player, action, pos)
//                             returning true or false, reason decides
//                             first (nil: the rules). [KIT_CTF] 384 cells
//                             a side at most (the World's whole height:
//                             a map-wide region, a column to the bottom)
// **Places, moves, speed and markers** ([KIT_CTF], any game's):
//   c.players (a type's `players`): each also has pos {x, y, z} (placed
//   ones: the world's, their feet's cell's middle, as c.pos is for an
//   entity), yaw (degrees, their view's last input) and alive (placed,
//   not waiting to respawn, their health's hp above 0 where they have
//   one); away true when they are in another scene than the entity.
//   regions = true -- c:region_at({x, y, z}): the region deciding the
//   cell the point is in (the smallest enabled one of its scene, as
//   allows() picks), {id, team (the team it is under, 0 none), rules
//   ({dig = "all"|"owners"|"others"|"none", ...}, its published state)},
//   nil outside every region (the World's default). As the run began.
//   c:move({x, y, z}, {fall = true}): its own entity (and what is under
//   it) to that place in the world after the run, back where it was at
//   Stop (as a vehicle); the composition (a save, an edit, a session's
//   copy) keeps where it was (Save as start: where it is). fall:
//   dropped onto the first solid voxel below
//   the point's cell (or the World's heightmap ground), its middle the
//   cell over it; then on_fall(c, pos): where it landed, or nil when
//   nothing was below down to the World's bottom (not moved). A cell not
//   loaded counts as solid (move.lua's). A player's entity (c:teleport)
//   and one owning voxels are refused, logged.
//   c:speed(player, factor): a player it reaches (an id or a by), on an
//   app with Kit's controls, moves at their movement's `speed` times
//   factor (0...10; 1 as it was) from then on: the server's steps and
//   their client's prediction ("kit:controls"' parameters) alike. Until
//   another call, Stop, or their body's going (they leave, another
//   session). 64 a run.
//   c:attach(player, {bone = name, offset = {x, y, z}})
//   ([KIT_CARRY_ATTACH]): its own entity on a player it reaches (an id or
//   a by), placed and in its scene: every client draws its look at the
//   player's body as that client draws it (its own prediction for the
//   player themselves, the others' interpolated place for the rest; the
//   body's turn), at the bone's point -- "head" (the neck), "body" (the
//   hips), "hand" (the right hand's grip, turning with the arm), none
//   (the feet) -- and offset metres in the body's turn (x right, y up, z
//   forward). Its c.pos (and its node, for logic: reach, regions,
//   c:near) follow the player's 5 times a second, roughly (the bone's
//   rest). Last call wins; c:detach() lets go where it is. Gone also at
//   Stop (back where it was then, as c:move's), with the entity, or as
//   the player leaves or changes scene. Not a player's entity, nor one
//   owning voxels (refused, logged).
//   marker = {color = "#rrggbb", label = text, lift = m (1), state =
//   "<shared state key>"} ("param:<name>" as a look's) -- the entity
//   pointed out on every client's screen (client_lua/ui.lua) while that
//   state is true (none: always): a dot and its label `lift` over it,
//   over the world (seen through walls), at the screen's edge while it
//   is off the screen or behind the view, following the entity.
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
// signal: there is no packet for one. "kit:action" "<name> 1" (pressed)
// or "<name> 0" (released) ([KIT_INPUT_ACTIONS]): from a placed peer out
// of the tools, while Running, a name the world declares ("kit:actions"
// [{name, key, label}...] tells the clients, at the join and as it
// changes), 20 a second at most (a burst of 40); a release always lets go.
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
//   {"op": "place", "prefab": name, "pos": [x, y, z], "turn": degrees}
//       -- a prefab's copy, turned a multiple of 90 about its base
//       ([KIT_PREFAB_VOXELS]); "clipboard": true instead of a prefab: the
//       builder's copy pasted (its members no prefab's)
//   {"op": "save_prefab", "ids": [n...], "name": n, "box": [x0, y0, z0,
//    x1, y1, z1], "air": bool}  -- those entities a prefab of the
//       builder's, they a copy of it; other copies follow its parameters
//       but their overrides. [KIT_PREFAB_VOXELS] box: the cells between
//       its corners (the editor's scene's) its voxels too, its base the
//       box's low corner (ids then optional); "clipboard": true instead:
//       the builder's copy named
//   {"op": "copy", "ids": [n...], "box": [...], "air": bool}  --
//       [KIT_PREFAB_VOXELS] the builder's copy (the server's, an unnamed
//       prefab): entities, a box's voxels or both; edit_state's
//       "clipboard" {entities, size, at} says it
//   {"op": "move", "id": n, "pos": [x, y, z], "yaw": degrees}  -- yaw
//       optional ([KIT] stage 4e2: an entity's turn round y, 0...360, its
//       look turned with it; zones and grants stay boxes of cells)
//   {"op": "move", "ids": [n...], "by": [dx, dy, dz], "turn": degrees}
//       -- entities moved together, one edit, turned about their middle
//   {"op": "duplicate", "ids": [n...], "by": [dx, dy, dz]}  -- a copy of
//       them that far off, their links among them the copies'
//   [KIT_NESTING] Positions and yaws in edits are the world's (a
//   child's made its parent's frame's); a place (a type's, a prefab's, a
//   paste) takes "parent": m, under that positioned entity of the scene
//   ([KIT_PANEL_PARENT] or a panel, for a UI element or a paste of them: a
//   UI type with no position, nothing else, refused);
//   a move, duplicate, delete, copy and save_prefab take the entities
//   under each one with it (one under another named goes with that one)
//   {"op": "parent", "id": n, "parent": m}  -- n (and what is under it)
//       under m (0: the scene), where it is in the world kept; m not n
//       nor under it
//   {"op": "delete", "id": n}
//   {"op": "set", "id": n, "comp": i, "param": p, "value": v}
//   {"op": "link"|"unlink", "id": n, "comp": i, "output": o, "to": m,
//    "input": in}
//   {"op": "undo"}  -- the editor's own last edit, UNDO_MAX of them
//   {"op": "builder", "name": account, "on": bool}  -- the admin's only:
//       makes an account a builder, or no longer
//   {"op": "play"}, {"op": "stop"}, {"op": "save_start"}  -- the server's
//       state, below (a builder's, the tools on or not; refused in a
//       persistent world, Host::persistent)
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
//   {"op": "set_voxel", "pos": [x, y, z], "voxel": n}  -- ([KIT_EDIT_VOXELS])
//       the cell in the builder's scene set to voxel n ("air": a dig),
//       routed as a player's write (an owned cell goes to its owner's
//       on_voxel), one undo, answered with "kit:edit_state"
//   {"op": "edited"}  -- ([KIT_VOXEL_EDITS]) answered with "kit:edited"
//       {"size": a section's side, "sections": [{"s": [x, y, z], "cells":
//       how many differ from the generator's (-1: not loaded), "owned":
//       true where a component owns voxels}], "more": n past 256}: the
//       World's sections somebody wrote, which a change of its parameters
//       keeps
//   {"op": "regenerate", "s": [x, y, z]} or {"op": "regenerate", "all":
//       true}  -- Ended only: an edited section's writes dropped (one
//       loaded, no component's voxels in it), the World generating it
//       again; one undo, which waits for it to be generated
//   {"op": "try", "id": n, "input": i, "value": v}  -- ([KIT_TRY_INPUTS])
//       Running only: input i delivered to entity n as a link would, by
//       the builder, v checked against the input's type; the runs it
//       makes answered with "kit:tried" {"id", "input", "emitted":
//       [[output, value], ...]} (a timer's later emits are not); refused
//       unless the entity is the builder's scene's or game-wide, a value
//       past 512 bytes refused
//   {"op": "watch", "id": n}  -- ([KIT_SIGNALS_LIVE]) what entity n's outputs
//       emit in this session sent to this builder, as "kit:fired" {"id",
//       "fired": [[comp, output, value as text, times], ...]}, at most five
//       a second, each output's last of that time; 0 stops. Dropped when
//       the builder leaves, leaves the session or stops editing
//   {"op": "pattern", "id", "comp", "param", "action": "capture"|"show"|
//    "fill", "voxel": n}  -- ([KIT_VOXEL_STATES]) a "voxels" parameter
//       of the instance: capture (the voxel_box's cells as they are now;
//       "" where not loaded) or fill (all of them voxel n) sets it as
//       "set" does (one undo); show writes the pattern into the world (an
//       edit, one undo; refused if empty or of another box size)
//   {"op": "voxel", "name": n, "texture": t, "kind": "solid"|"leaves"|
//    "plant"|"water", "solid", "transparent", "light": 0..15,
//    "friction": 0..10, "surface": tag, "group": tag, "level": 0..15,
//    "sound_dig", "sound_place", "drop": a voxel or item type ("" itself)}
//       -- ([KIT] stage 4g) the
//       builder's voxel type "<their name>/<n>" (the store's row
//       "voxel:<their name>/<n>", its "version" counted up by each),
//       world.h's Material's fields: registered in every scene at once and
//       sent to the clients connected (voxelworld's registry), placed by
//       its name, saved by it. Texture t is a registered voxel's or an
//       upload's. A new version of a registered one is drawn so at the
//       next start (a registry's definitions never change). Friction and
//       surface are for what moves on it (stage 4h); nothing reads them
//       yet but voxel_type(). [KIT_TOOLS_1] group (its material group,
//       "" none) and level: digging, below
//   {"op": "item", "name": n, "preset": an item type, and the sheet's
//    fields}  -- [KIT_TOOLS_1] the builder's item type "<their name>/<n>"
//       (the row "item:<their name>/<n>", its "version" counted up by
//       each): the preset's sheet under the fields given (Tools, below).
//       Refused in a draft
//   {"op": "sound", "name": n, "params": "blip1:..."}  -- [KIT_SOUNDS]
//       the builder's sound "<their name>/<n>" made or changed, or n a
//       project's sound's whole name changed (not Kit's, not a
//       package's: those are copied); {"op": "sound_delete", "name": its
//       whole name}. Refused in a draft. Sounds below
// "kit:texture", a PNG's bytes ([KIT] stage 4g): a builder with the tools
// on uploads a texture (square, 8..128 a side, a power of two, 64 KiB at
// most), decoded and saved again (the row "texture:<hash>"), served as
// "kit/up/<hash>.png" and answered with "kit:texture", that name.
// Each is checked on the server, the rights first, then the ids, types,
// parameter values (as the type declares them) and signal names; a
// refusal is logged and answered with "kit:edit_refused" ("<op>: why").
// An editor is sent "kit:edit_state" after each edit, anyone's:
// {"editing", "palette": [type...], "types": {type: {params, inputs,
// outputs, gizmo, usable, root}}, "authored": the row (positions and
// yaws the world's, [KIT_NESTING]), "undo": n, "admin",
// "voxels": [{"name", "texture", and the properties above}...] (each
// placeable voxel), "textures": [name...] (what a type may wear),
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
// builder's Stop (or the app's set_running). A persistent host
// (Host::persistent) is Running always: no start, no copies, no Stop;
// "kit:edit_state" says "persistent".
//
// **Sessions** ([KIT_SESSIONS_1], stage 7): beside the default round,
// game sessions and builders' private drafts, each a round of its own from
// the start (the composition's entities at their start, their on_start),
// its own clock (game time since it started), entities, runtime, players'
// entities and voxels, in the app's scenes "<scene>~<id>" (Host::make_scene;
// Host::drop_scene takes them down; an app without both has no sessions,
// nor a persistent one). A session's voxels are the start's copy-on-write:
// a section is the start's until the session writes it (the default
// round's copy, its live edits over it; else the default's own), and only
// the sections it changed are its own. A game session holds in memory
// only the sections round its players and spawn (a finite map's too, as
// an infinite World's) and those a write copies in; the others stay the
// start's alone. It writes 256 sections at most: a dig or place into one
// more is refused (told), an entity's write dropped (logged). A component makes one
// (c:session_start(players): players it reaches, in its zone or the
// run's, any for a type with `players`; nil: those in its zone and the
// run's), moves a player into one it made or back (c:session_move(player,
// id), id 0 the default) and ends one it made (c:session_end(id));
// on_session_start(c, id) and on_session_end(c, id) are its own. In a
// session c.session is its id (0 in the default) and c:session_end() ends
// it; none is made from inside one, MAX_SESSIONS (8) at most. Ending one
// sends its players back to the default round at their scene's spawn.
// Kit takes a player to a session by kit:change_scene to its scene; the
// app's set_peer() there joins its round. A builder's draft ({"op":
// "draft"}) is a session for them alone, their tools on in it: their edits
// change the draft, not the start ("kit:edit_state"'s "session" {id,
// kind: "default" | "draft" | "game", by, clock, can}); {"op": "publish"}
// puts the entities the draft's edits changed into the composition as one
// edit (one undo) and the cells its builds and edits wrote into the start
// as live edits; {"op": "leave_draft"} ends it (a builder back in the
// default with their tools on as they were in the session, as after a
// game session's end). In a draft the World, the
// environment, terrain, voxel types, new scenes, rounds (Play, Stop) and
// exports are refused; in a game session the tools edit nothing.
// {"op": "sessions"} logs each session's stats (a session's "loaded",
// "written" and "shared": the default's loaded sections it holds no copy
// of). Sessions are not saved: a
// restart drops them and their scenes (the row "sessions").
// [KIT_PREFAB_BENCH] {"op": "prefab_bench", "prefab": name} takes a builder
// to a prefab's temporary scene: a draft (kind "bench"; "kit:edit_state"'s
// session adds prefab, root, box, ready) of an empty World with nothing from
// the start but the environment, no generator, not running; one copy of the
// prefab at the origin, its voxels laid out as sections arrive (ready, and
// save_prefab refused before it). The World is the bench's own, one per
// builder, under MAX_SESSIONS. Refused: another's prefab, Kit's and packages',
// from inside a session, an app without sessions. {"op": "save_prefab"} with
// a root and box there is the Save; the project's own copies of the prefab
// follow (no undo entry in the project), other drafts' do not. {"op":
// "leave_draft"} is its Close: nothing else leaves it.
// [KIT_MINIGAMES_1] c:session_end(id, result) carries a result (JSON, 4
// KiB at most) to the maker's on_session_end(c, id, result) (nil
// without one), so a round's outcome reaches the default round.
// [KIT_MINIGAMES_FIX] In a session c.session_maker is the entity whose
// run started it (0: none, a draft); c.player_away is true when the player
// who set the run off is in another scene than the entity.
// [KIT_LATE_JOIN] In a game session c.session_players is the number of
// players its start took in; in the default round c.sessions =
// {[id] = {players, taken, clock}} the game sessions it made: its players
// now, those its start took, its clock (s). As the run began.
//
// **Minigames** ([KIT_MINIGAMES_1], stage 7b's first part): the framework
// owns a round's lifecycle, each game its goal. kit/arena is the lobby
// and the queue (its zone: players join by entering it), the countdown
// (its minimum `players` in it; one leaving under it cancels), the
// session for up to `max_players`, the round timer (`duration`), the
// teams' split and the result (`results` seconds on the screens, then
// everyone back): its input "win" is the win-condition slot a builder
// fills by a link (a team's id or name, or the team of the player who
// set it off); the timer's end without one is a draw. kit/team is a team:
// its name, colour, spawn (its pad) and shared score ("add", "set";
// "reached" at win_score). **The Team interface**: a type with `team =
// true` is a team, its state `members` (its players' entity ids) and
// `score`; a type with `teams = true` reads the teams in its scene (of
// those, the ones under its own parent when there are any: a placed
// prefab's own), c.teams = {{id, params, state}} by id, and reaches them
// (c:send); a kit/arena runs a round only in the session it started (any
// other arena there idle); a kit/region with
// owner "team" is owned by the members of the team it is under (itself or
// an entity up its parents with a team: a team's base placed under the
// team). The prefab kit/team_match is a two-team match to place.
// [KIT_CTF] kit/arena's `map` (a scene's name; "" none: the round in the
// arena's own scene): the session's players go into that scene's copy
// (its spawn, then their team's pad), its teams the round's (c.teams, a
// `teams = true` type's with a `map`), and at the session's end back to
// the arena's scene (its spawn). `time_up`: "draw" (the default) or
// "most": the team with the most points wins at the timer's end; a tie
// runs on as overtime (the status line says so) until the scores differ
// (checked each second). Its UI is drawn in its own scene only: its
// output `status` (the round's line as it changes: the time left or
// "Overtime", the scores, the result) is for a kit/ui_text in the map.
// [KIT_FLAG_RIGHT_CLICK] A type's `right_use` names a shared state of its
// own: the player whose entity id it holds has their right click use the
// entity (kit:use, its on_use) instead of placing a voxel (the client's
// pointer target's right); kit/flag's while carried with place_by
// "right_click".
// [KIT_FLAG_CLICK_RANGE] A type's `use_range` ("param:<name>") is how far
// it is used from, the server's check and a client's pointer alike, below
// the host's own; its `use_when` names a shared state of its own: while
// that is false a client's pointer goes through it. kit/flag's click_range,
// 2 m by default.
// [KIT_ARENA_SCORE_TO_WIN] `score_to_win` (0 none): a team with that many
// points wins the round, whichever of it and the time up comes first.
// kit/timer's output `left`: the seconds left,
// (repeats - ticks) * interval, at its start and each tick (none without
// repeats).
//
// **Sounds** ([KIT_SOUNDS]): the project's named sounds, each blip's
// parameters (extensions/blip's compact form, "blip1:...": data, made in
// its designer, not audio files): Kit's own in sounds.json (kit/click,
// kit/swing, kit/shot, kit/hit, kit/dig, kit/place, kit/door,
// kit/pickup), a builder's {"op": "sound"} (rows "sound:<author>/<n>"), a
// package's types/<n>.sound.json ({"params"}). Every session's clients
// get them as "kit:sounds" {name: {params, author, name, version,
// package}}. A trigger plays one by name, "kit:sound" {name, at: [x, y,
// z] | null} to the peers in the scene (at: positional there; null: not
// positional), the server logging "Sound <name> (<why>) ...": an item
// type's sound_* (the swing, the shot and the reload where its holder is
// -- the holder's client plays its own swing and shot at once, the
// server the others'; the hit at the target; the break where it broke),
// a voxel type's sound_dig and sound_place (at the cell, edit mode too),
// a component's c:sound (kit/door's sound_open and sound_close,
// kit/button's sound_press, kit/pickup's sound, kit/sound's "play"
// input).
//
// **Tools** ([KIT_TOOLS_1], stage 7c's first part). An item type is a
// flat sheet, "<author>/<name>": Kit's are types/<name>.item.json
// (kit/sword, kit/pickaxe: the presets), a builder's are made by {"op":
// "item"}. Its fields (each checked; one left out the preset's, else the
// default): icon (a texture, "" a text label), stack (1..999), use
// ("none", "melee": it hits, "use": a click runs the hooks, "ranged":
// it shoots, [KIT_TOOLS_2]), timing (cooldown s, mode single|auto|burst, burst, charge
// s), damage (damage, damage_type "normal", crit: the multiplier of a hit
// falling, falloff: the share lost at the full reach, knockback m/s),
// melee (reach m), digging (dig {group: speed}, or the text "stone 4,
// wood 2"; level 0..15), wear (uses: 0 never wears, wear_dig, wear_hit,
// wear_shot: a use's cost; repair: an item, kept). [KIT_TOOLS_2] ranged
// (shot "hitscan"|"projectile", speed m/s, gravity m/s/s, lifetime s,
// spread degrees, pellets, range m, recoil degrees: the client's view
// kick), loading (magazine: rounds, 0 none -- a shot then takes an ammo
// item if it names one; reload s; reload_mode "whole"|"one"; ammo: an
// item or ""), look (a prefab's name: its kit/parts and voxels drawn in
// first person, fitted to 0.2 m about its base, +z ahead; "" a bar of its
// colour with its icon), color ("#rrggbb": a shot's, a splat's), grip
// ([right, up, ahead] m from the eye: where it is held in view).
// [KIT_SOUNDS] sound_swing, sound_shot, sound_hit, sound_reload,
// sound_break: a project's sound each ("" none).
// Clients get them all as "kit:item_types" {name: sheet}, a look's
// prefab with it ("look_data" {parts, voxels}; sent again as the prefab
// is saved). An item in an
// inventory is a name of letters, digits and _, or an item type's.
// kit/equipment (on each player entity; `equipment = true`) holds the
// hands slot, state "hands": the client's hotbar sends "kit:hold" <item>
// (one of theirs, "" a hand); a list without it empties the hands.
// [KIT_TOOLS_2] ([KIT_ITEM_WEAR_SHAPE]) An item is an instance with data
// of its own (kit/inventory's: the extension argument's "instances", a
// take's out, an add's in): the hands hold the first of an item, its
// wear (uses left) and loaded rounds on it, state "held" its data;
// on_tool(c, item, cost, uses, drop, shot) is Kit's call after a use and
// as the hands take it: the drop added, the cost taken (the instance
// gone at 0: "broke"), shot {rounds, magazine, ammo} a shot's round from
// the magazine or an ammo item (none: it returns false, why: refused);
// on_reload(c, item, magazine, ammo, one) loads (true: one at a time has
// more to load). kit/item_box moves an instance between players.
// kit/health (on each player entity, and placeable: `health = true`)
// has hp of max; a hit is on_hit(c, hit, by) there, after each
// component of the entity's modify_hit(c, hit, by) in order: given hit
// = {amount, type, item, crit}, it returns the hit as it goes on (nil:
// unchanged; amount 0: nothing) -- armour, shields, stage 9's effects.
// It signals "damaged" (the amount) and "died"; a player dead respawns
// (c:respawn(): their team's pad, else the last spawner of players in
// their scene, else the app's spawn) at max. c.is_player: on a player's
// entity. "kit:hit" <entity id> is a placed peer's melee hit with what
// they hold: Running, out of the tools, a melee item of theirs, past its
// cooldown (game time), the target with health in their scene within its
// reach (eye to body) and in sight (no solid voxel between); then Kit's
// rules (kit/game_rules' peaceful on the root: players take no damage; the
// region at the target: pvp for the attacker on a player, damage for the
// player hit, damage for the attacker on an entity; kit/team's
// friendly_fire, off: members do not hurt each other), the item's wear
// (wear_hit), the hit (the amount less the falloff at the distance, the
// crit multiplier falling), knockback on a player (away, or along their
// look). "kit:item" <id> is a use kind "use" item's click (its cooldown;
// id the entity pointed at, 0 none). After each: on_item(c, item,
// action, target, by) of every instance in the player's scene, the root's
// and their entity's -- "hit" (the entity), "use" (the entity, 0), "dig"
// (the cell [x, y, z]). [KIT_TOOLS_2] "kit:draw" (a charge's draw
// begun), "kit:shoot" {dir: [x, y, z]} (a placed peer's shot along dir
// from their eye, the body's bottom and 1.55): Running, out of the tools,
// a ranged item of theirs, past its cooldown, no reload under way, a
// round (on_tool); a charge's share drawn (0.1...1 of its time) scales
// the damage and speed; each pellet spread at random: hitscan hits the
// first entity with health on the ray within range before a solid voxel
// (a player's body a box 0.7 wide, its top 0.3 the head: crit), less the
// falloff at the distance; a projectile is the server's, stepped each
// tick with gravity until it meets an entity with health, a solid voxel
// or its lifetime; a hit through Kit's rules as melee's. Clients draw
// "kit:shot" {by, item, color, from, ends: [[x, y, z, 0 nothing|1 a
// wall|2 a target]]}, "kit:projectile" {id, from, vel, gravity, life,
// color, by} and "kit:projectile_end" {id, at, hit, color}. "kit:reload":
// the held ranged item's magazine loaded after its reload time
// ("kit:reloading" {item, time} to the client), one round a time while
// "one". simplified: no lag compensation. Digging (dig_ready, dug below),
// under kit/game_rules' dig_by_tools (off by default: every voxel digs at
// once and drops nothing): a voxel with a material group takes 1 / speed
// s (the held item's for the group, else a hand's: stone 0.25, dirt 1,
// sand 1.5, wood 0.5, leaves 4, plant 50, any other 1; "kit:digging"
// {cell, wait, time} tells the client to ask again) and drops its
// material into the inventory where the item's level is the voxel's or
// above; one without a group digs as before. Kit's default set's groups:
// stone (stone, cobble, mossy cobble; level 1), dirt (dirt, grass, snow),
// sand (sand, gravel), wood (log, planks), leaves, plant.
// [KIT_CTF] A material's `drop` is what its dig drops instead of itself
// (kit/stone's kit/cobble). kit/game_rules' hand_level (15 by default:
// any): a dig at a hand's speed -- nothing held, or an item whose sheet's
// dig names no speed for the voxel's group -- of a material above that
// level is refused ("kit:warning", the client stops asking).
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
// **Death, respawn, hurts and blasts** ([KIT_CTF]). A player's death is
// their health's c:died(by, type) (kit/health's at hp 0, on a player's
// entity: c.is_player): on_died(c, player, by, type) of every instance in
// their scene, on the root and on their entity (player their entity's
// id, by who set the hit off: "player:<id>", an entity's run's by...,
// type the hit's), their inventory by on_death, then kit/game_rules'
// `respawn`: "at_once" (the default) back at their spawn (their team's
// pad, else the scene's last spawner of players, else the app's) with
// their health's hp at its max, through the spawn kits; "on_signal": the
// player waits, their health's state "waiting" true (shared), until a
// c:respawn_waiting() -- game_rules' input `respawn` -- puts every
// waiting player of the round back so. A waiting player does nothing:
// Kit refuses their hit, shot, draw, reload, use, item use, hold,
// inventory move and action presses, and allows() everything but
// "enter" ("Waiting to respawn": no dig, place or damage); the server
// steps their body with no walking or jumping (the view turns), the
// client too, and Kit's HUD says "Waiting to respawn". game_rules' respawn
// changed to "at_once" respawns those waiting. A player moved to another
// session (c:session_move, an arena's round and its end) waits no more in
// the one they leave. c:respawn() (before
// [KIT_CTF] kit/health's) still respawns a player at once.
// c:hurt(player, amount | {amount = n | fraction = f, type = name}):
// a player of the round hurt (fraction: of their health's max) through
// their modify_hit hooks and health as a hit of type `type` ("hurt" by
// default), by the run's by; Kit refuses it (logged) for a player waiting,
// under game_rules' peaceful, or where the region at them refuses them
// damage. 16 a run.
// c:explode{at = {x, y, z} (c.pos by default), radius (0...9, 0), power
// (0...1000, 1), kill (0...32, radius), hurt (0...32, 0), share (0...1,
// 0.5), friendly_fire (true), type ("blast")}: a blast in the entity's
// scene. A cell within radius (its middle) goes to air, a game change,
// where the blast's strength there, power * (1 - distance / radius), is
// above its material's blast_resist (materials.json's and op "voxel"'s,
// 0...1000; 0, every material of Kit's set, goes at any strength), unless
// the region holding it forbids digging to anyone (its dig rule other
// than "all"). The players within kill (their body's middle, 0.9 m up)
// are hit for their health's max, those within hurt for share of it,
// each as a hit of type `type` by the run's by through Kit's refusals for
// c:hurt; friendly_fire false: also a team's friendly_fire spares the
// members of the team of the player who set it off (true: a blast hurts
// teammates and its own player). on_blast(c, pos, by) of each other
// entity within radius (64 at most). 4 a run; Kit's blasts are limited to
// EXPLODE_RATE (4) a second, EXPLODE_BURST (16) at once, server-wide;
// a refusal is in the entity's log.
// [KIT_CTF] Built on these, Kit's types (their files say how): kit/flag (a
// carriable objective: taken by a click or within a range, stolen,
// placed by an action, scoring in a team's region, home by a timer, a
// death, a leave, a fall), kit/explosive (a fuse, a hiss, c:explode) and
// kit/placer (an item of use kind "use" puts a prefab's copy ahead of its
// player); kit/part's shape "sphere"; the prefabs kit/hut (voxels) and
// kit/bomb_look; the sound kit/hiss. util/kit_ctf_check.sh composes a
// capture the flag of them.
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
// sent "kit:warning" (text) for the seams and a refusal. Voxel objects
// ([VOXEL_OBJECTS]) on a heightmap are their own entities once they
// exist, not the World's.
namespace kit
{
	// The World's voxelworld region, in sections (voxelworld's, WORLD_SECTION
	// voxels a side): what an infinite world may reach, -16384...16383
	// each way, -128...255 up
	static const int WORLD_SECTION = 64;
	static const int WORLD_SECTIONS_XZ = 256;
	static const int WORLD_SECTION_Y0 = -2, WORLD_SECTION_Y1 = 3;

	// [KIT_VOXEL_FORMAT] (stage 4g2) Kit's voxel format, what an app
	// hosting Kit's World sets on its registry before the first voxel:
	// plane 0 is `id` 0..15 (material and shape: "kit/stone" and
	// "kit/stone:stair" are two ids, the shapes made by Kit's registering,
	// world.h), `param` 16..23 (what the definition says: a shape's
	// facing, see world::SHAPE_PARAMS), `tint` 24..27 (16 steps of the
	// material's tint ramp, albedo) and `light_sky` 28..31, maintained
	// only while the World's "sky_light" is on (dark caves; off, nothing
	// computes it and the client draws the world as fully lit). A save
	// from before read 0 in the new bits: the default facing, no tint, no
	// light (computed when sky light is turned on).
	inline interface::VoxelFormat voxel_format()
	{
		interface::VoxelFormat f;
		f.id = interface::VoxelField{0, 0, 16};
		f.param = interface::VoxelField{0, 16, 8};
		f.tint = interface::VoxelField{0, 24, 4};
		f.light_sky = interface::VoxelField{0, 28, 4};
		return f;
	}
	// A voxel's word in a format: its id, param and tint (bits the format
	// does not have dropped), the light 0 (computed where maintained)
	inline uint32_t voxel_word(const interface::VoxelFormat &f, uint32_t id,
			uint32_t param = 0, uint32_t tint = 0)
	{
		uint32_t w = 0;
		f.id.set(w, id);
		if(f.param.bound())
			f.param.set(w, param);
		if(f.tint.bound())
			f.tint.set(w, tint);
		return w;
	}

	struct Interface;

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
		// [KIT_SCENES] The app makes a scene of this name for the
		// composition (a builder's New scene, a saved composition's scene
		// it has not made yet) and gives its reference, null when it will
		// not. On a World app (world_scene) the scene has a voxelworld
		// instance like world_scene's: the same voxels registered in the
		// same order (one registry file serves every scene), its own save.
		// Unset: the composition's scenes are only `scenes`. Called on
		// Kit's thread: Kit's own calls (register_voxels...) go through k,
		// not access()
		std::function<main_context::SceneReference(const ss_ &name,
				Interface *k)> make_scene;
		// [KIT_SESSIONS_1] A session's scene the app made ("<scene>~<id>")
		// taken down: its voxelworld instance and its save's rows gone, its
		// peers (none, Kit moved them out) in the main scene. Called on
		// Kit's thread, for one made or one from before a restart (rows
		// only). Unset (or make_scene unset): no sessions
		std::function<void(const ss_ &name)> drop_scene;
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
		// [KIT_MATERIAL_SETS] Whether a World may name an installed material
		// set package (its "materials") instead of the app's set: an app
		// whose generators and brushes may use any voxels (Workbench). False:
		// the app binds the roles in code (skeldat, vanilla)
		bool material_sets = false;
		// [KIT] stage 4h: Kit moves the players: each one's body is stepped
		// by a movement (kit/walker...) on the server and predicted on their
		// client (kit.controls{} there), the camera, the pointer and the
		// movement the app root's kit/controls (its defaults with none).
		// set_peer()'s position is then only where a player first appears
		// (their body put there, unless a spawner on the join put it),
		// put_player() puts them, a teleport puts them without
		// kit:move_player. False: the app moves them (set_peer)
		bool controls = false;
		// [KIT] stage 6a: the players' inventory is the app's own (a native
		// app's, skeldat's): Kit's count/add/take/list read the list the
		// app gave by set_items(), and a run that changed it is the event
		// "kit:items" (ItemsChanged) for the app to apply, as is the round's
		// start's reset. A replacing component (inventory = true) still
		// replaces it. False: Kit's own (kit/inventory on the player entity)
		bool app_items = false;
		// [KIT] stage 6a2: the world is the game itself (skeldat; vanilla
		// later), not a round from a start: always Running, no Play, Stop
		// or Save as start; nothing copied out, marked or discarded; an
		// authored entity a component removes is gone. Edits apply live,
		// as Running's do. A save from round hosting is Running from here
		// on, the voxels as they stand, its copies and marks dropped
		bool persistent = false;
	};

	// kit:items ([KIT] stage 6a, Host::app_items): a player's inventory as
	// Kit's run left it, {item: n}, and as it had it (set_items()'s) -- the
	// app applies the difference; or reset: the round's start, the app's
	// inventory as it gives one at a start (no "keep inventory")
	struct ItemsChanged: public interface::Event::Private
	{
		ss_ name;
		json::Value before, after;
		bool reset = false;
		ItemsChanged(const ss_ &name, const json::Value &before,
				const json::Value &after, bool reset):
			name(name), before(before), after(after), reset(reset){}
	};

	// kit:app ([KIT] stage 6a): one of the app's own types (its author's)
	// called c:app(what, value): the app's native code does what it names,
	// at the entity's position, for the player who set the run off (by,
	// their name; "" for none). The app checks the value: it is the type's
	// word, and the app's types are the app's own code
	struct AppCall: public interface::Event::Private
	{
		uint64_t entity = 0;
		ss_ type, what;
		json::Value value;
		ss_ by, name, scene;
		bool has_pos = false;
		double x = 0, y = 0, z = 0;
	};

	// kit:move_player: a component moves a player (c:teleport); the app
	// puts the peer's feet in the cell at x, y, z of the player's scene,
	// and says so by set_peer (Kit's zones and ranges go by that)
	struct MovePlayer: public interface::Event::Private
	{
		size_t peer = 0;
		double x = 0, y = 0, z = 0;
		// [KIT_SPAWNER_PLAYERS] The yaw to look at, level; NaN: as it was
		double yaw = NAN;
		MovePlayer(size_t peer, double x, double y, double z,
				double yaw = NAN):
			peer(peer), x(x), y(y), z(z), yaw(yaw){}
	};

	// [KIT_SCENES] kit:change_scene: a player goes to another scene of the
	// composition (a portal, a builder's switch of the scene edited): the
	// app moves the peer there (replicate's scene, its voxels round them),
	// says so by set_peer with that scene and puts them at x, y, z
	// (put_player; with a yaw as MovePlayer's). Kit sends it only to an app
	// with make_scene
	struct ChangeScene: public interface::Event::Private
	{
		size_t peer = 0;
		ss_ scene;
		double x = 0, y = 0, z = 0;
		double yaw = NAN;
		ChangeScene(size_t peer, const ss_ &scene, double x, double y,
				double z, double yaw = NAN):
			peer(peer), scene(scene), x(x), y(y), z(z), yaw(yaw){}
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
		// [KIT_BUILDER_PLAY_RULES] Whether a placed peer is in edit mode
		// now (edit rights, the editor on): an app's own building tools
		// build freely for that only. Out of edit mode a builder plays by
		// the rules as everyone (allows() below), so they can try them
		virtual bool is_editing(size_t peer) = 0;
		// Whether a component grants a placed peer digging (placing) the
		// voxel at x, y, z of their scene (a type's `grants`). Edit rights
		// are not in it: an app asks it beside is_editing
		virtual bool can_dig(size_t peer, int x, int y, int z) = 0;
		virtual bool can_place(size_t peer, int x, int y, int z) = 0;
		// [KIT] stage 4j: whether a placed peer may do action ("dig",
		// "place", "enter", "pvp", "damage" or "use") at x, y, z of their scene,
		// and why not (why: may be null; "Protected: no digging here", or
		// an allow hook's reason): the smallest region holding the cell
		// decides, by its owners' column or everyone else's; outside every
		// region digging and placing need a grant and the rest is allowed.
		// can_dig and can_place are it. Kit's own hits ([KIT_TOOLS_1]) ask
		// pvp and damage here; a game with hits of its own asks them too.
		// Edit rights are not in it
		virtual bool allows(size_t peer, const ss_ &action, int x, int y,
				int z, ss_ *why) = 0;
		// The entity of the region deciding at x, y, z of a placed peer's
		// scene (the smallest enabled holding it), 0 outside every region:
		// an app whose own default differs outside them asks allows() only
		// where this is one (sample_kit's digs)
		virtual uint64_t region_of(size_t peer, int x, int y, int z) = 0;
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
		// [KIT_TOOLS_1] Digging by a voxel's material group and level: a
		// placed peer's dig of `voxel` (its name) at x, y, z is ready now,
		// or not yet (wait: the seconds left; Kit tells the client
		// "kit:digging" {cell, wait, time, span: the whole on the wall
		// clock}, and it asks again). A grouped voxel takes 1 / speed
		// seconds of game time, the speed the held
		// item's for its group (its sheet's dig; a hand's 1), counted from
		// the first ask at the cell. Ready at once: a voxel with no group
		// (the app's own), edit mode, Stopped, kit/game_rules'
		// dig_by_tools off. Asked before the dig is written
		virtual bool dig_ready(size_t peer, int x, int y, int z,
				const ss_ &voxel, double *wait) = 0;
		// A placed peer's dig of `voxel` written (after player_wrote): the
		// held item wears (its wear_dig), and the voxel's material drops
		// into their inventory where the item's level (a hand's 0) is the
		// voxel's or above. Nothing for a voxel with no group, or with
		// dig_by_tools off
		virtual void dug(size_t peer, int x, int y, int z,
				const ss_ &voxel) = 0;
		// [KIT_INVENTORY_PLAY] Whether a placed peer may put down `voxel`
		// now by kit/game_rules' building, and why not: "inventory" (the
		// default), one of the held slot's material (a shape of it too);
		// "creative", any (the palette). Edit mode and Stopped: yes. Asked
		// after allows() and before the write; placed() after it takes
		// the one put down from the held slot
		virtual bool place_ready(size_t peer, const ss_ &voxel,
				ss_ *why) = 0;
		virtual void placed(size_t peer, int x, int y, int z,
				const ss_ &voxel) = 0;
		// [KIT] stage 4e: Kit's material set's voxels (kit/stone...)
		// registered, the ones not there yet: before set_save()
		virtual void register_voxels(interface::VoxelRegistry *reg) = 0;
		// [KIT_TINT_MATERIALS] An app's own voxel `name` made of a material
		// as a material set's voxel says it (world.h; its "tint" may name
		// one of its own "palettes"), registered when it is not yet: before
		// register_voxels(), which makes its shapes. False (why says) for
		// one that does not parse
		virtual bool register_material(interface::VoxelRegistry *reg,
				const ss_ &name, const json::Value &material,
				ss_ *why = nullptr) = 0;
		// [KIT] stage 4g: a voxel's properties, Kit's set's or a builder's
		// type's ({kind, solid, transparent, light, friction, surface}; a
		// heightmap material's are its ground's); null for another's
		virtual json::Value voxel_type(const ss_ &name) = 0;
		// Where a player stands at the World's middle: x, z, and y the
		// cell their feet are in (a heightmap's: its surface + 0.5)
		virtual void world_spawn(double &x, double &y, double &z) = 0;
		// [KIT_SCENES] The same in a scene's World ("": the World scene's)
		virtual void scene_spawn(const ss_ &scene, double &x, double &y,
				double &z) = 0;
		// [KIT] stage 4h (Host::controls): a placed peer's body put with
		// its feet in the cell at x, y, z (a spawn, a respawn), standing
		// still, out of any seat; with a look (degrees, [KIT_SPAWNER_PLAYERS])
		// their view turned that way, level (NaN: the view kept)
		virtual void put_player(size_t peer, double x, double y, double z,
				double look = NAN) = 0;
		// [KIT] stage 6a (Host::app_items): the player's inventory as the
		// app has it now, {item: n}, an item letters, digits and _ (the
		// app maps its own names); the app calls it as it changes
		virtual void set_items(const ss_ &player, const json::Value &items) = 0;
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
