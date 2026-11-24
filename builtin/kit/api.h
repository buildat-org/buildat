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
// [KIT_SCENE_TREE] A scene may be under another scene (a group: a hub or a
// menu, a real scene with its own World, its tracks under it). The root
// types (`root = true`: kit/controls, a movement's parameters,
// kit/game_rules, kit/environment, a builder's own) are looked up from a
// player's scene up, the nearest copy winning (one on an entity right under
// a scene with no position, "on": "scene"), the root's last.
// [KIT_ENV_INHERIT] kit/environment by each parameter: a scene's has those
// set on it (its component's "overrides", saved and exported with it), the
// rest the nearest's above that sets them, the root's setting all.
// [KIT_SINGLE] A type with `single = true` has at most one instance a
// holder: the app root, a scene (the nearest scene above the entity, else
// the root); one on the root and one in a scene is the scene's override.
// A second's arrival in a holder (a place, a reparent, a paste, a prefab's
// copy, an import) is refused naming the one there ("scene world has
// kit/environment 12 already: one per scene"); the editor's Place selects
// that one instead. Duplicates a saved game has load with a warning, the
// first (by id) used. Kit's: kit/environment, kit/controls, kit/game_rules,
// kit/terrain (the World), kit/player_state, the root movements
// (kit/walker, kit/click_to_move), kit/scene_info and kit/symmetry.
// simplified: game-wide whatever the scene: the inventory's size and screen
// (kit/game_rules' slots, hotbar, stack, full, drop_items, screen),
// kit/player_state and the types on every player (`player = true`: health,
// inventory, equipment, score). What walks a scene's entities (its World,
// a session's copy of it, its cell jobs, world_check) stops at a scene
// under it; a scene with scenes under it is not removed. A scene's World
// "none" ([KIT_NO_WORLD]) with no spawner of players holds its players
// where they are (no movement), not dropped into a fall that meets
// nothing.
// [KIT_NO_WORLD_TYPES] A type with `no_position = true` has nothing at a
// place (kit/timer, kit/ui_text): an entity with only such types has no
// position, what it is given is dropped, and nothing of it is drawn or
// picked in the world, in the editor neither. It is under its scene, or
// under a positioned entity (kit/starting_kit under a kit/team), and has
// nothing under it; it runs as one in its scene does; a node of its own
// still carries its shared state and its HUD element, not at any place.
// [KIT_SCENE_PACKAGES] A UI element on the root (or in a panel there) has
// such a node in every scene, so a hub's lobby and its screens are on every
// player's screen wherever they are, pressed from any scene.
// [KIT_NESTING] A positioned entity may be under another one in its scene
// (MAX_NEST levels): its position and yaw are its parent's frame's, so it
// moves and turns with it, and while its parent's look slides
// (kit/mover's when.offset) it is carried there too. Zones, regions,
// grants, owned voxels, use ranges, looks, c.pos and c.yaw are in the
// world through the parents. [KIT_FREE_ROTATION] A row has yaw, pitch and roll
// (pitch and roll absent at 0), its frame the parents' composed. A zone and a
// region turn with the parents: their cells are those whose middle is in the
// turned box, c:region_at and the client's the same way. c.yaw is the yaw of
// that turn; [KIT_WALKER_FRAME] a walker on a free object steps in the object's
// frame (move.lua's W:walk_on, kit/walker's slope_limit). Grants and owned voxels stay boxes of cells, stamped
// copies at 90 degree turns. Its node is its scene's child at its place in the world (the
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
// [KIT_API_1] **What Kit API 1 promises** (kit_plan 4z37j). A game made
// with Kit API 1 keeps loading and playing the same way in every later
// Buildat. A builder can rely on: the game file's structure; each builtin
// type's params, their defaults and meanings, inputs, outputs and state
// keys (older values move forward through the type's migrations); the
// server script interface this file documents (c: methods and fields, the
// handlers, the type-table fields, signal value types); movement
// declarations, a step's s, i and p, and the 10 official w methods
// (client_lua/move.lua's head); the client parts' handlers, e, and the 15
// names of their `kit` table (Client parts, below); and the jam1, blip1 and
// weave1 formats. Within API 1 Kit only adds things; a renamed thing keeps
// its old name as an alias until API 2. A Kit that meets a game made with a
// newer one refuses it with a message saying which Buildat to use, and
// never loads it half-way. Its inventory, name by name: doc/kit_api1.txt.
// [KIT_TEXT_PLACEHOLDER] **A text's placeholders**: in a text a client
// draws (a kit/sign's, a kit/ui_text's, a kit/goal's line, any HUD text)
// {<word>:...} is Kit's. API 1 has {key:<action>}, this player's key for
// the action (bare; "(unbound)" with none; on a touchscreen the on-screen
// control's label; drawn anew as the player rebinds; an action nobody
// declares as written), and {value:time} (m:ss), [KIT_RECORDS]
// {value:time1} (to a tenth: 12.3, 1:02.3; 0.0 before any) and
// {value:int} (with {value}, a kit/ui_text's or kit/ui_bar's value; a
// kit/stopwatch's running time counts on in each). Any other word is drawn as
// written, and an edit setting it, Play and get_goal_warnings warn of it
// (kit.cpp's placeholder_warnings()): a later Kit may give
// it a meaning, so a game must not use it for one of its own. A
// "[<word>]" is drawn as written.
// Outside the promise (any release may change them):
// - what is marked experimental: generators (on_build, c:child, c:link,
//   c:voxel_box, c.entities, c.move_lib, c:generate, the "points" keys `values`
//   and `level`), driving bots (c:drive, c.body, c.path, kit/path and
//   kit/bot's drive, skill and ask; a kit/bot walking the goals is API
//   1's), kit/parallax and a movement's touch_axes; a type of its own by
//   `experimental = true`. Publishing a game that uses one warns and is not
//   blocked (kit.cpp's experimental_names(), pub_experimental());
// - kit.internal (the whole client module) and w's 18 internal methods;
// - [KIT_API_1] (item 11) the texts of refusals, errors and log lines, the
//   MCP tools' texts and get_guide's wording. A script must not branch on
//   an error's text: a game that needs to tell failures apart gets a
//   return value from Kit, not a stable message. The checks match these
//   texts in the tree and change with them;
// - network protocols (the packets: a client and its server update
//   together, and nothing persisted is lost);
// - per-run caps and rates: c:hurt 16 a run, c:explode 4, c:speed and
//   c:body_var 64, c:set_voxels 4096, sessions 8, c:after 64, c:sound 8,
//   a generator's 63 children, EXPLODE_RATE, EFFECT_RATE, client parts' 64
//   bursts and 240 a second, the 0.1 s held period, box.c's STEP_CAP and
//   string params' lengths. Kit aims to raise them, not lower them; a game
//   must not rely on meeting one;
// - the editor's and Workbench's UI.
//
// A type is named "<author>/<name>" ([KIT] stage 4b): everyone makes their
// own door. Kit's own generic types are builtin/kit/types/<name>.lua,
// author "kit", in every hosting app; the app's are <types_path>/<name>.lua
// under its author (Host::author, the app's id); other authors' come in
// packages (below), named "<fp>/<name>" by the package's key
// ([AITTA_KEY_IDENTITY]: fp the key's fingerprint, doc/aitta.txt); the
// game's own are custom types, "local/<name>" (below). An instance records its type and the type's version
// (the file's `version`), each one's written ([KIT_API_1]; one left out:
// in a file of "kit" 1 or more version 1, in one from before the type's
// current). A save from before, its types bare names, is
// read as the app's type of that name if it has one, else Kit's, and
// written back so.
//
// A component type's file returns a table:
//   version  = n             -- a whole number from 1 (1 if left out)
//   component = true         -- ([KIT_COMPONENTS]) it has no place of its own and only
//                               goes on an entity with one, by the inspector's Add
//                               component: not in the palette. Types that say
//                               no_position (no `ui`) and placeable ones are added
//                               too; component = false says not this one. "Children
//                               for places, components for properties": what needs an
//                               offset is a child. A type once an entity, so (entity,
//                               type, parameter) names a value through any add or
//                               remove; one movement (`movement` and `step`) an entity.
//   seat = true              -- ([KIT_COMPONENTS]) a use of the entity (with usable)
//                               takes the player's controls for its movement
//                               ([KIT_VEHICLE_MOVEMENTS] the nearest movement on it or
//                               above it: a seat is a child entity on a deck, one
//                               holder a vehicle)
//                            -- [KIT_VEHICLE_MOVEMENTS] A movement on a free object's
//                               root, or on an entity under something that moves, is
//                               steered in play: the server steps it (step(s, i, dt, w,
//                               p), its seat's holder's input as i, else i.f, i.r,
//                               i.climb from its instance's state throttle, steer,
//                               climb: an NPC's, a signal's), DRIVE_LEAD ahead of the
//                               shared time, and sends each client its keys
//                               ("kit:track"); a holder predicts nothing. Its world is
//                               the scene's, or under a deck the deck's boxes in its
//                               parent's frame. movement = {timed = true} is no
//                               steered one (kit/course: a function of the time).
//                               [KIT_ENT_PERF] movement.native = "path" on a
//                               steered creature's: stepped in C++, not by its
//                               step (Units, by Creatures below; kit/unit_walker).
//                               Stock: kit/sea_vessel, kit/airship, kit/car,
//                               kit/turret, kit/course
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
//              shared one is replicated to the clients; param = "<p>":
//              at a round's start the parameter p's value, not default
//              (sent as it is from the start, not after on_start);
//              ([KIT_UI_COMPONENTS]) a per_player = true one (shared = true
//              beside it or not) is a table
//              {"player:<id>": v} (a `by`'s key), each client sent only
//              its own player's v ("kit:mine" {"all": bool, "list":
//              [{"id", "key", "value"}]}; null: none) while in its scene.
//              In a run it is a plain table: `for by, v in
//              pairs(c.state.<key>)` lists every player's entry, and
//              c.state.<key>[by] = nil clears one (a table changed in
//              place is a set); pairs and next on c.state itself list
//              the state's keys ([KIT_AGENT_FEEDBACK_1117]).
//              An entry is dropped when the body goes ([KIT_REPORT_1123]:
//              a guest's as they leave, a bot's as it is removed; at a
//              game's load those of bodies not there, a guest's at a stop
//              included: it is not saved). A player with an account
//              keeps their body, so their entry stays until the round's
//              start resets the state, in a persistent world for good.
//              Keys other than
//              "player:<id>"/"bot:<id>" are left alone.
//              [CRAG_BEST_RESET] A kept = true one (not
//              per_player) play never resets: Play, Stop, a round's start,
//              Restart and a server restart keep it; it is in the runtime
//              row, never the start's (Save as start leaves it out); a
//              builder's op clear_kept puts its default back (best times,
//              keyed by c:name(by), a high score); in a game session the
//              session's own (Sessions)
//   linked_in = true         -- [CRAG_BEST_RESET] c.linked_in = {input =
//              {id...}}: the entities with a link to it, by its input,
//              which it reaches (c:send to each: crag_run's gems)
//   listed = true            -- [KIT_SCENE_PACKAGES] c.listed = {{scene,
//              title, author}...}: the scenes a kit/scene_info on them
//              lists (title the scene's name where it gives none), by the
//              scene's id (kit/ui_scene_list, kit/arena's maps "*")
//   experimental = true      -- [KIT_API_1] (item 10) the type is outside
//              Kit API 1 and may change in any release (kit/path,
//              kit/parallax): get_guide's list says "(experimental)", and
//              publishing a game that places one warns
//   container = "<param>"    -- [KIT_API_1] (finding 16; kit/chest's) with
//              usable = true: a use opens its slots on the player's
//              inventory screen beside their own, as many as that number
//              parameter says (1 to 54; 27 without it), its state `slots`
//              as kit/inventory's
//   inputs   = {"name", ...}; outputs = {"name", ...}  -- signals, discrete
//   about    = {what = "...", inputs = {name = "..."}, outputs = {name = "..."},
//               params = {name = "..."}}
//                            -- [KIT_SIGNALS_DOCS] For the builders, all of it
//                               optional: what the type is, and for each
//                               signal what sets an output off or what an
//                               input does. A signal's first sentence is the
//                               line under it in the Signals view, the whole
//                               text (a line or two; at most 200 bytes shown)
//                               its hover. One with a value says it in a
//                               sentence "Value: ..."
//                               [KIT_PARAM_ABOUT] params = {name = "..."}:
//                               what each parameter is, a line; the
//                               inspector's tooltip on its row (a tap on
//                               its name on a touchscreen), list_types'.
//                               (Kit adds its own parameters' lines: use,
//                               own_look)
//                               [KIT_PALETTE_SECTIONS] group = "World" (or
//                               Building, Logic, Game, Players, Creatures,
//                               Vehicles, Items, UI): its section in the
//                               editor's Place tab (none: Other); keywords =
//                               "a b c": words its filter also finds it by,
//                               beside its name and what. A prefab's
//                               "group" is its section the same way
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
//                            -- [KIT_ZONE_SHAPES] zone = "look": the entity's
//                               own look as drawn and turned, followed at
//                               once through a reshape or a move (no copy):
//                               a kit/polygon's outline over its depth, a
//                               box look (a kit/part's, turned by its
//                               rotation; its state's `when` over it), a
//                               sphere of equal sides. simplified: a wedge
//                               and an uneven sphere are their boxes. A spike
//                               hazard is a component of its own with zone =
//                               "look" on the spikes' polygon, reacting in
//                               on_enter. An entity with no look, or under a
//                               kit/parallax layer (drawn offset, never met),
//                               has nobody in it. A body is met by its
//                               movement's s.spheres, else a walker's body
//                               box (movement.zone = "box": kit/walker,
//                               kit/click_to_move), else its point (a seat's
//                               holder, a bot, an app's own movement): box
//                               zones the same way (client_lua/move.lua's
//                               header). Nothing of a zone runs on the
//                               clients. get_state's "zone": its kind,
//                               shape and bounds, who is in it
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
//           text_idle = "param:<name>" (drawn while that state is empty:
//           a Stopped server has run nothing to set it) [KIT_TEMPLATES],
//           text_facing = "flat"|"camera", text_back = true (flat text on
//           the back too, kit/sign's both_sides) [KIT_AGENT_FEEDBACK_1117],
//           extent = "<position param>", depth = n, solid = true,
//           voxel = "<voxel material>", edge = "#rrggbb",
//           state = "<shared state key>", when = {color, solid, scale =
//           {x, y, z}, swing = true, mirror = true, vanish = "fly"}}
//                            -- drawn where it
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
//                               kit/part's `voxel`. [KIT_COLLECTIBLE]
//                               edge: a box's twelve edges as boards of
//                               that colour, an eighth of its shortest
//                               side wide (a crate's frame; module.lua's
//                               draw_look; "": none), kit/collectible's
//                               `edge`. Its z side
//                               `depth` in its first cells' middle when
//                               given. solid: a collision shape on the
//                               clients (client-side, as the voxels').
//                               while the state `state` is true, `when`
//                               over it: scale its sides (its bottom
//                               kept), swing it a quarter round its -x
//                               edge (a door; towards +z, or with
//                               mirror towards -z [KIT_DOOR_MIRROR]:
//                               "param:mirror", kit/door's);
//                               [KIT_COLLECTIBLE] vanish "fly": as the
//                               state turns on (not on a look drawn
//                               anew), its body first shrinks, turns
//                               half round and rises 0.8 over 0.35 s
//                               (module.lua's VANISH_TIME), else
//                               ("none") at once. kit/door,
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
//                               layout, gap and ([KIT_UI_KEYS]) keyboard
//                               ("auto", "on", "off": it goes by the
//                               keys); [KIT_UI_EMPHASIS] appear ("none",
//                               "fade", "slide", "pop"; a panel's not
//                               pop), on_change ("none", "pop",
//                               "pop_words"), a bar's pulse_below (a
//                               fraction); x, y and the sizes in
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
//                               phase, by) on it ("pressed", "released").
//                               [KIT_AIRSHIPS_2] kind "menu": an item in
//                               the app's pause menu (extensions/
//                               pause_menu, through E.menu), not drawn:
//                               text its label, order its place; listed
//                               while up for the player and in play, a
//                               press a button's (pressed, released at
//                               once): kit/pause_menu_action
//                               [KIT_TEXT_INPUT] kind "input": a line
//                               a player enters (text the label,
//                               max_length its field's): the packet
//                               "kit:ui_text" "<id> <text>", checked as a
//                               press, the text without control
//                               characters and cut at 200 bytes; on_ui(c,
//                               "entered", by, text): kit/ui_input.
//                               [KIT_BOT_DIFFICULTY] A type with
//                               `takes_text = true` takes it with no
//                               ui (not checked as on the screen; its
//                               on_ui checks who): kit/bot's dialog
//                               [KIT_PLAYER_LIST] kind "players": its
//                               text a title over rows from its shared
//                               state `value`, {{name, colour, score}..}:
//                               kit/ui_player_list
//                               [KIT_SCENE_PACKAGES] kind "list": its
//                               text a title over a button a row of its
//                               shared state `value`, {{title, author,
//                               scene}...}; a press "kit:ui" "<id> 1|0
//                               <row>" (from 1), on_ui(c, phase, by, row):
//                               kit/ui_scene_list
//   actions ={{name = "fire", key = "R", label = "Fire"}, ...}
//                            -- ([KIT_INPUT_ACTIONS]) keys the players
//                               press (8 at most; each value a string or
//                               "param:<name>", kit/action's): name
//                               letters, digits and _, key its default (a
//                               key name, Input::GetKeyName's), label the
//                               keys page's and a touch button's. Each
//                               client binds its own key (its key store);
//                               {key:name} in a shown text is that key.
//                               on_action(c, name, phase, value, by) on
//                               every instance declaring it, in the
//                               player's scene or on the root: phase
//                               "pressed", "released" or "held" (every
//                               0.1 s of game time between, value the
//                               seconds held). 16 actions in a world at
//                               most (the first found).
//                               [KIT_SMALL_PIECES] mouse = "left",
//                               "right" or "middle": that button does it
//                               too, as the left click does Kit's use
//                               (the keys page shows it beside the key;
//                               not rebound): a race's fire
//   client_params = {"name", ...}
//                            -- ([KIT_SMALL_PIECES]) its parameters whose
//                               values its client part reads (e.params,
//                               in the entity's show: sent as an edit
//                               changes them, play's c:set_param not;
//                               32 at most). Opt-in: the others never
//                               leave the server (a puzzle's answer)
//   on_input(c, input, value, by), on_use(c, by), on_voxel(c, voxel, by),
//   on_timer(c, name, player), on_enter(c, by), on_leave(c, by),
//   on_join(c, by), on_away(c, by) ([KIT_SMALL_PIECES]; below),
//   [KIT_API_1] (finding 16) on_give(c, by) (kit/starting_kit's: a starting
//   kit for the player by, at a round's start, and where its `when`
//   parameter is "spawn" at each respawn too; each instance in the
//   player's scene or on the root, one under a kit/team its members' only;
//   a `clear` parameter true empties the inventory first),
//   on_inventory(c, player, when, kept, gone) (before a player's inventory
//   changes, when "death", kit/game_rules' on_death, or "round_end"; kept
//   the slots they will have, gone those dropped or lost; it returns kept,
//   gone as it wants them, nil as they are; each instance in the player's
//   scene, on the root or on their entity; simplified: box.c passes on a
//   boolean return only, so what it returns is not taken yet: no type
//   uses it),
//   on_daytime(c, what) (an `environment = true` type's, kit/environment's:
//   "dawn" as its clock passes 6:00, "dusk" at 18:00, while Running),
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
//                               they were, so filtered. [KIT_API_1] What
//                               is left out goes to the component's
//                               old_params {name: value} (saved, exported,
//                               in the entity's Log; the builder op
//                               clear_old_params, {"id", "comp"}, drops it)
// c: c.id, c.pos, c.params (read), c.state (read and written; a table in
// it changed in place is written too), [KIT_ZONE_SHAPES] c:params_of(type)
// (the parameters of the same entity's component of that type, as its own
// c.params; a copy, so writing it changes nothing; nil: none there; as they
// are at the run's start: no sibling on_params, a read at use is always
// current; c:params_of("kit/polygon").points a polygon's outline; only a
// type whose file names params_of has them in its runs), c:emit(output, value),
// [KIT_SOUNDS] c:sound(name, {everywhere = true}) (a game's sound at
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
// run off, the app moving them on kit:move_player; [KIT_SCENE_PACKAGES]
// c:teleport(nil, {scene = name}) onto that scene's spawner of players, its
// last, else its World's spawn; from the root, wherever the player is;
// [KIT_TEMPLATE_CLEANUP] c:teleport(nil, {entity = id}) onto a spawner of
// players with no yaw given: facing its way, as a join there),
// c:set_param(id, type,
// param, value, opts) ([KIT_VEHICLE_MOVEMENTS] a parameter of a component on an
// entity it reaches, until Stop, checked as an edit's, the row keeping its
// own; a movement's take it at its next step: an engine upgrade, wind, fuel;
// 64 a run; [KIT_PLAYER_PARAMS] value nil: play's value gone, the row's
// again; read by the movements, the players' kit/controls and bodies'
// movement and a UI type's `ui` "param:" fields, below; opts {player =
// by}: that player's own, below), c:log(...) (the
// server's log and the entity's own, which the inspector shows),
// c:app(what, value) ([KIT] stage 6a; the app's own types only: the event
// kit:app, AppCall, its native code's to do; 8 a run). A
// component reaches its own entity and its links, the entities its entity
// parameters name and the copies it made, and the player who set it off
// (every player with `reads_players = true`), the panel it is in (c.panel), the
// entities linking to it with `linked_in = true`, nothing else.
//
// [KIT_API_1] **Names** (kit_api1_review.md items 5 and 7). A type's table
// holds the fields above and its handlers alone: put_type (and the
// editor's type put) refuses another field ("x: not a type field Kit
// knows"), a function under a name that is no handler (a helper goes in a
// local), and a parameter or state key starting kit_; a save's or a
// package's type with one still loads, each warned of in the log. The
// prefix kit_ is Kit's: every name Kit adds after API 1 on e (client
// parts), s and i (movements' steps), w, an inventory call's ext and the
// parameters it injects (use, own_look) starts kit_, so a game's own
// names, which never do, never meet a later Kit's. Kit's rules for its
// own names:
// - A bool parameter "active from the start" is `enabled`; no parameter
//   is named `on`.
// - Inputs: show/hide a UI's visibility (ui_*, pause_menu_action), on/off
//   a switch whose state is drawn or sent on (lever, effect, voxel_replace,
//   voxel_states), enable/disable a behaviour started or stopped (attack,
//   flag, flee, follow, region, senses, spawn_rule, wander). Inputs are
//   never renamed: a link names its target's input, and migrate sees
//   parameters only.
// - Distances: radius an area round the entity (explosive, spawn_rule,
//   wander), range how far it notices or lets a player act (radar,
//   senses, flag's *_range), distance one it keeps or places at
//   (controls, flee, follow, placer), reach how far an attack or a hand
//   reaches (attack, bot).
// - Speeds: a movement's `speed` (walkers) and `top_speed` (vehicles,
//   which accelerate towards it) are m/s; every other speed is relative to
//   the body's own (c:speed's factor, propose_move's speed, kit/flag's and
//   kit/flee's, kit/bot's speed in percent as its aim and reaction).
// - Damage is `type` everywhere: c:hurt{type}, c:explode{type},
//   c:died(by, type), on_died(c, player, by, type).
// - A type field giving read access is reads_*: reads_players,
//   reads_teams, reads_regions, reads_voxels.
// - A label in a signal's type, "string:<label>", is free text the editor
//   shows ("string:player", "string:team", ...); a link does not read it.
// Renamed in 4z37j (each type's migrate takes a placed one forward):
// kit/effect's `on` is `trigger` (v2), kit/symmetry's `on` `enabled` (v2),
// kit/spawn_rule's `on` `on_voxels` (v2), kit/voxel_replace's and
// kit/voxel_states' `start_on` `enabled` (v2); on_build's c.move is
// c.move_lib; a client part's kit.mark takes a table.
// Reserved for a later Kit (not there yet; a game uses none of them for
// its own): an inventory call's ext.player (that player's inventory;
// refused now, "ext.player is reserved"); kit/goal's pick = "nearest_type"
// with the parameter pick_type (a type name), when_state (a key of the
// bot's own entity state: the goal counts while it is true, "!key" while
// false) and kind = "dig" (the cells of its size box); c:voxel_at(x, y, z)
// (a voxel's name or nil, world cells of the entity's scene) and
// c:set_voxels_at({{x, y, z, name}...}) (4096 a run, game changes as
// c:set_voxels'), both for a type with world_voxels = true; a client
// part's kit.report(value) and the server handler on_report(c, by, value).
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
// [KIT_GOALS] "use" (ev.entity the object a player used, ev.player),
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
//   [KIT_REPORT_1122] The order: a run's emits go out as emitted, each
//   along its component's links in their list's order (the order they
//   were made; a save, export and duplicate keep it; [KIT_SYMMETRY] a
//   link's copies right after it), into an entity's components that take
//   the input in theirs; each becomes a run at the end of one queue, run
//   in order. So what a signal sets off comes after every run queued
//   before it: a value two links away (a kit/records' best from a
//   kit/stopwatch's elapsed) always after the ones one link away (that
//   elapsed to the run), whatever the links' order.
//   "string:player" is a string the editor calls a player; a link does not
//   look at the label.
//   [KIT_SCENE_PACKAGES] A link by name ("to_name" instead of "to"; the op
//   link's too, refused unless an entity of that name in a scene takes the
//   input): each signal reaches the entity of that name (the lowest id of
//   several) in the scene of the player or bot `by` is, now; no player or
//   no such entity there drops it, logged ("... dropped: why"). A root's
//   link into each scene's own (a track's run), not shown in play.
//   `by` is "player:<id>", the player's entity (a login keeps it), or
//   "app"; c:name(by) the player's name, c.player their entity's id (on
//   on_leave, a guest's entity may be gone by then: its id still).
//   Players are entities: each player has one in their scene (kind
//   "player", made the first time they come, its id theirs from then on,
//   1000000 and up, never handed out again),
//   carrying each type with `player = true` -- Kit's kit/inventory (the
//   default inventory provider) and kit/score -- not placed, not edited;
//   their state is play state (the round's start resets it), kept in the
//   runtime row (its "players": {name: {id, aside}}; a guest's not, an
//   agent's play body's neither). A type with
//   `reads_players = true` reads every player: c.players = {{id, name, here,
//   state = {type = state}, scene}}: every scene's players, each with
//   the scene they are in ([KIT_AGENT_FEEDBACK_1117] "" none); a
//   scene's component keeps to its own by `not p.away` (below).
//   Entities made in play: c:spawn{prefab = name | entity = id, pos =
//   {x, y, z}} (a copy of a prefab its prefab parameters name, or of an
//   entity it reaches with what is under it, in its scene at pos or its
//   own position; returns the copy's first id; on_start runs on each),
//   c:remove(id) (an entity it reaches and what is under it; nil itself:
//   on_remove first), c:send(id, input, value[, by]) (an input to an entity
//   it reaches; [KIT_LOBBY] by a player or bot it reaches, as c:emit's),
//   c.made (its copies there now, each by its first id, which
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
//      "to": a member's id (or "to_name", by name), "input"}]}]}],
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
//   param, terrain.h's Shapes). Links between its entities and the cells
//   they own stay its own: an owned voxel is its entity's (own_voxels()).
//   [KIT_AIRSHIPS] A prefab with voxels copied in play (c:spawn) is a free copy
//   as the editor's Place free makes one: a root (kit/prefab_copy free, at pos,
//   the returned id) with its members under it, its voxels a free object; a
//   prefab without voxels makes its entities only. "root": {"components":
//   [{"type", "params"}...]} (8 at most; voxels only; no player type) are
//   what such a copy's root carries, placed or spawned (a movement, a
//   kit/hull). A cell's owned data is not in a copy. Kit's and the
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
//   root's turn is its yaw; a stamp takes multiples of 90 of it and refuses a
//   pitch or a roll ([KIT_FREE_ROTATION]: only a free copy tilts). A copy made in
//   play (c:spawn) of a prefab without voxels has no root, its members remember
//   the prefab ({"prefab": {"of", "version", "member", "copy"}}).
//   [KIT_AIRSHIPS] Building on a free copy in play: "kit:obuild" {"id", "cell":
//   [x, y, z] in the root's frame (a cell's middle its whole coordinates),
//   "voxel" ("air" digs), "param", "tint"}, from a placed peer within its use
//   range and 4 m. Refused (told why) without a kit/hull on the root, by its
//   build rule against its state owner (owner, team: the owner's team too,
//   anyone, nobody), by kit/game_rules' dig and place, outside the 32 cube
//   centred on the prefab's box, on a taken or empty cell, on the core (the
//   voxel kit/core: one a ship, never dug or placed), and without the hull's
//   cost in the placer's kit/wallet (taken from it; [KIT_AIRSHIPS_2] none
//   while the wallet's state `free` is true: a kit/shop's
//   free_outside_rounds sets it at each join, true in the default round,
//   false in a game session's). Editing skips the hull.
//   The first change copies the prefab's voxels into the copy's own grid (copy
//   on write); its model ("kitown_<id>") and boxes ("kitown_<id>.<rev>", sent
//   as any free object's) are rebuilt for one copy at a time, the one changed
//   longest ago, at most every OWN_REBUILD_GAP for all of them. A late joiner
//   gets the copy's model as it is. Stop forgets the grids (play state).
//   simplified: a fixed 32 cube, no sliding window; the client's aim is the
//   boxes it has, so a cell placed and not yet rebuilt is not aimed at
//   [KIT_AIRSHIPS] stages 3 to 5. Parts: a placer whose kit/wallet holds a
//   part (its state "part", a prefab without voxels, 1 to 8 entities; a
//   kit/shop with `mount` puts it there) mounts it with a place on an empty
//   cell beside a ship's voxel (its support: below, above, then the sides):
//   the prefab made there as children of the root, the wallet's part
//   cleared. Mounted entities drop (removed, the owner and the shooter told
//   by a note) as their support goes. A ship's parts sum (mass by its
//   voxels' material group: stone 3, dirt and sand 2, leaves 0.2, else 1;
//   thrust and lift of kit/engine under it) is the movement step's
//   params.parts {mass, thrust, lift, engines}. Damage: a shot from a turret
//   (not on its own ship) or a blast hits a cell; its toughness (stone 30,
//   dirt and sand 5, leaves 2, else 10) worn down, then the cell is destroyed
//   (kept for a repair), the rebuild through the budget; cells no longer
//   connected to the core are debris (removed); a hit on the core loses the
//   ship (removed; its owner's note; its shop's "lost" input). A wallet's
//   "repair" input puts back the destroyed cells, still empty, of the ships
//   that player owns. A kit/radar's state "contacts" lists the other ships in
//   its scene within its range. A kit/trigger_zone with `deadly` loses a ship
//   touching it (8 corners and the middle of its box) and is as large as a
//   region may be.
//   simplified: debris and dropped parts vanish; toughness and mass by
//   material group, not per material; a part's own box is its support's
//   A parameter type "prefab"
//   names one; a parameter's `choices` = {...} are the values it takes;
//   `choices_from = "biomes"` makes the inspector's a dropdown of the
//   material set's biomes (a string still; the World refuses another).
//   `choices_from = "scenes"`: a dropdown of the composition's scenes
//   and "none" (""). `choices_from = "scene_list"`: a text of scene names,
//   comma separated, and a dropdown adding one to it ("item_list" the same
//   of items). [KIT_PLANE] `choices_from = "movements"`: a dropdown of the
//   types that step players' bodies (a `movement` and a step, not steered
//   nor timed) and "none", an edit or c:set_param of another refused (a load
//   takes it: the players then stand). [KIT_SOUNDS] A parameter type "sound": a dropdown of
//   the game's sounds and "none" ("").
//   [MUSIC_SYNTH] A parameter type "song": a song's text in jam's format
//   (jam1; get_guide topic music), "" none, a parse error refused with its
//   line; the inspector's own section (the text, Play/Stop, the moods).
//   [KIT_PLANE] A parameter type "points": a closed shape [[x, y]...] of 3 to
//   512 points (|x|, |y| <= 256, [KIT_SIDE_SCENERY]; its edges not crossing
//   nor touching, its area not 0; any winding), edited in a side game's 2D
//   view, not the inspector (kit/polygon's). [KIT_STUNTS] With `crossing` =
//   true its edges may cross and its area be 0, no point twice in a row
//   still (a loop round a figure eight: kit/path's points).
//   [KIT_PARAM_CATEGORIES] A parameter's `cat` is the inspector's category
//   it is under: "behaviour" (without one), "hud", "look" (appearance in
//   the world and sounds), "physics" or "advanced" (technical: poll, rate,
//   substeps). Another value is warned of at the type's load and treated
//   as behaviour. A type with 8 parameters or more in two categories or
//   more gets a row of chips for them.
//   Client parts: <name>.client.lua beside a type, sent to every client at
//   join and run there as the client's own Lua is (client_lua/module.lua
//   says what it gets).
//   [KIT_CLIENT_REACT] (3) **What a client part reaches**: its handlers'
//   `e` (e.id, e.node, e.state, e.look, e.hinge, e.body, e.swing, e.mine,
//   e.you, e:shown(key), e:predict(key, v, s), e:near(d), e:log(text): this
//   client's log only; [KIT_SMALL_PIECES] e.params: the values of the
//   parameters its type names in `client_params`, below, {} with none;
//   [KIT_UI_CLIENT_PART] e.ui, below);
//   `local kit = require("buildat/module/kit")`,
//   [KIT_API_1] these 16 names of the client's Kit and no others (another
//   is nil; module.lua's, controls.lua's and input.lua's heads say more):
//   kit.pointed(origin, dir, reach) and kit.use(id), kit.body_state() this
//   client's predicted body, kit.body_pos(), kit.seated(), kit.ui_keys()
//   (true while a UI page has the keys: play gets none),
//   kit.press_action(name, down) (a game action, a type's `actions`,
//   pressed or let go as by its key), kit.key_down(id) (a key action held),
//   kit.key_name(id) (its key's name) and kit.key_text(s) (each {key:id}
//   in s as this client's key, as signs show it), [KIT_MOVE_DRAW]
//   kit.material(hex, {unlit = bool, texture = name}) (a cached material of
//   the colour "#rrggbb", lit or unlit, or of a texture drawn as it is, the
//   colour where it does not load: module.lua's), kit.shared, kit.shake,
//   kit.effect, kit.mark and kit.clear_marks below. kit.internal is the
//   whole client module, the editor's too: outside Kit API 1 (it may
//   change in any release; the apps that host Kit use it, and publishing a
//   game whose part does warns). [RACER_FEEL] (2), (3) from a handler or a
//   movement's
//   draw, this client's alone and at once: kit.shake(amount) the camera
//   shaken as kit/controls' shake input does (0...5, from this frame),
//   kit.effect{at = {x, y, z}, ...} c:effect's particles (its particle
//   fields, clamped alike; 64 live bursts and 240 a second from all parts,
//   past it dropped; effects.lua), kit.mark{at = {x, y, z}, yaw, size,
//   color, alpha} a flat ground mark (size {across, along}; a ring of 1024;
//   ~60 us a mark, the sandbox's Vector3s),
//   kit.clear_marks(); (2) kit.shared, one plain table per client every
//   client part of every entity shares (local, nothing sent; a part's
//   reload, a scene switch, Play and Stop keep it, the connection's end
//   drops it; keys by convention the type's name; simplified: a part
//   clears its own keys in on_remove); the client sandbox's
//   require("buildat/extension/urho3d") with the Urho3D classes its
//   whitelist allows (client/core/urho3d/safe_classes.lua: e.node's
//   children and components, Vector3, materials...) and
//   require("buildat/extension/network") (write_json, parse_json). Refused:
//   node:GetScene() (a scene-wide handle reaches Kit's own nodes on every
//   visitor's client; the whitelist has it for a Viewport only), a global
//   set in a handler (a part's own state goes in locals of its chunk, on
//   e, or in kit.shared), the server's c: (state reaches a client part
//   through `shared` and per_player state). simplified: the scene is
//   still reachable (a Node's `scene` property, replicate's main_scene:
//   the sandbox guards the player's machine, not Kit's nodes from a
//   builder's part); the guide asks a part to change only what it made
//   under e.node, closing those the upgrade. A handler that errs is
//   switched off for that part on that entity on that client, and (4) its
//   first failure there goes to the server ("kit:part_failed" {id, type,
//   handler, error}; 10 a minute a client, the error cut at 300 bytes):
//   the entity's log (get_log, a builder's editor Log), "the client part
//   of <type>: <handler> failed on <player>'s client: <error>" (the server's
//   camera's, not yet playing a body: "on the server's camera").
//   [KIT_CLIENT_REACT] (1) A client part's on_enter(e) and on_leave(e): this
//   client's own predicted body met the entity's zone or left it, tested on
//   the client each frame in the server's shapes (cells, a look's outline,
//   box or sphere; the body's spheres, box or point: move.lua's zone_meets),
//   before the server's on_enter(c, by) hears of it: a gem gone at once
//   (e:predict), the server still the one that decides. The zone's cells go
//   in kit_show (zones) for an entity with client parts only.
//   [KIT_CLIENT_REACT] (10) Out of play (dead and waiting to respawn, a
//   kit/lobby's lobby or result) a movement's step gets i.out_of_play = true,
//   its keys none, on the server's steps and the client's prediction alike
//   (move.lua's header; c:speed(by, 0) stays the freeze: [KIT_MOVE_DRAW]
//   i.speed is its factor, 1 normally, 0 frozen). [KIT_BODY_VARS]
//   s.vars: what c:body_var set on the body (read only; nil: none), the
//   server's in the client's re-steps too: a step decides by the run's
//   state itself (a finish open) with no rewind. [KIT_MOVE_DRAW] A
//   movement's draw(s, node, yaw, p): p its parameters (the step's p: a
//   size both need is a parameter, not a constant in two files); s.vars
//   another body's public vars (c:body_var's {public = true}); s.pose by
//   name too where the movement declares pose = {"name"...} (its slots in
//   order, 16 at most ([KIT_STUNTS]; 8 before): the step writes s.pose by
//   name or by index, kept and sent as the numbers); node made anew when the draw function changes
//   (its client part put again). A put (a teleport, a respawn, a seat)
//   starts the movement's state afresh on the server and the client: a
//   step keeping a place of its own starts over from s.pos. A hazard that
//   must react at once belongs in the step (a surface it meets), not in a
//   server zone, whose on_enter is a round trip late on the client. (9) A kit/lobby's
//   keep_own_body: the player's own body stays drawn for them out of play,
//   their camera on it (no spectating), hidden from the others as ever (the
//   pose's flag 8, players.lua).
//   [KIT_UI_CLIENT_PART] **A UI element's client part**: the client part of
//   a type with a `ui` (kit/ui_*, a builder's own) moves and changes its
//   own entity's element on this client, each frame if it likes (its
//   on_update runs before the frame's layout), as a movement's draw does
//   its node: a lobby's elements animated, a value's text styled, with no
//   server round trip. e.ui (ui.lua's M.ui_api), in UI units (percent of
//   the screen's shorter side, as the ui's x, y, width, height and size):
//   e.ui.rect() -> x, y (from the screen's top left), w, h, shown: the
//   element as last drawn (nil: none drawn yet, or no `ui`);
//   e.ui.screen() -> w, h: the screen's (100 the shorter side);
//   e.ui.text() -> the text as last drawn ({value} filled), a bar's fill
//   0...1 (nil for others);
//   e.ui.set{...}: dx, dy (-400...400: an offset from where the layout
//   puts it, kept in its box: the screen or its panel), width, height
//   (0...400; 0 from its contents), size (0.5...30: its text's), opacity
//   (0...1, times its own; its text too, a panel's children's shapes but
//   not their texts: Urho3D's Text keeps its own opacity), color
//   ("#rrggbb" or "#rrggbbaa": a text's, a bar's fill), text (as the ui's
//   `text`: {value} filled, | a new line; 200 characters). Each kept till
//   set again, false: its own again; its part put again (an edited type)
//   drops them all; another field or a bad value is an error (the part
//   switched off, as a handler's). width, height, size, color and text go
//   over the ui's own fields and a player's own (c:set_param {player}),
//   so the layout fits it to them. Drawn in play and unframed edit mode;
//   framed edit mode draws the element as authored (a drag places it, a
//   handle sizes it). Kept to its own element: e.ui knows only its
//   entity's id, gives no element, and nothing names another's or Kit's
//   own HUD (simplified: the sandbox's urho3d ui.root still reaches every
//   element, as the scene does above; a part is asked to touch only its
//   own).
//   Cost (2026-11-22, 61 elements bobbing and fading each frame, setting
//   their text and colour once a second): the UI's layout 6.2 ms a frame
//   against 5.7 with no parts (~10 us an element); an element with no part
//   costs nothing more. An element whose part moves it logs its line
//   twice a second at most.
//   [KIT_GENERATORS] **Generators** (experimental, [KIT_API_1]: on_build,
//   c:child, c:link, c:voxel_box, c.entities, c.move_lib, c:generate and the
//   "points" keys `values`, `level` and `crossing` may change in any release; publishing
//   a game that uses them warns): a type with on_build(c) builds its
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
//   (4z37f) A type's `children = n` (1...1023) raises its build's cap (63
//   by default). c:child takes pitch and roll too; c:link's `to` may be
//   {id = n}, an entity of c.entities (a checkpoint linked to its race).
//   c.entities: the generator's scene's other entities, its own children
//   left out, {id, name, types = {type...}, pos = {x, y, z} (the world's;
//   none without a place), yaw}: to avoid or decorate hand-placed ones;
//   c.move_lib: move.lua's library (the clients' kit.move_lib; not
//   c:move), to check what it builds. [KIT_SMALL_PIECES] c:random(seed)
//   (any handler's; not experimental): a seeded generator, g:next() 0...1
//   (never 1) and g:int(a, b) a whole number a...b (a, b whole, a <= b),
//   the same numbers from the same seed on every server and build (Lehmer's
//   16807 on the seed's whole part; math.random is seeded by the clock): a
//   layout from the generator's seed parameter (brim_yard's junk). An error() refuses
//   the run (the edit with it), its text the reason. Run again on demand:
//   the edit op {"op": "build", "id", "comp", "params"} (the editor's Run,
//   MCP run_generator): params set first, then built whether they changed
//   or not, one undo. Each generator's last run (when, by whom, children,
//   kept, gone, ms, its c:log lines or why refused; live for a round's) is
//   in the edit state's and get_state's "generators" ({id, name, type,
//   scene, children, last}). A parameter type "points" with `values` =
//   {{name, min, max, default}...}: each point [x, y, v1...], those after
//   its x and y in order, each in its range; `level = true`: the points are
//   the entity's own x and z (the ground's plane), dragged in the plan view
//   on the entity's own (a track's corner list with each bend's radius);
//   the inspector edits them as text, a point a line.
//   In play c:generate(id, params) (a generator the instance reaches, 4 a
//   run): built again live for the round, params over its own (a seed: a
//   new layout each round): what it built (authored, or an earlier live
//   run's) out of the round as c:remove takes it (the authored back at
//   Stop), the new children made in play under it; nothing saved.
//   simplified: a live build writes no voxels; refused in a persistent
//   world
//   [KIT_SYMMETRY] **Symmetric maps** (kit/symmetry, kit_plan 7c): one a
//   scene, right under it, put at its World's middle (x = z = 0, level).
//   Its slices: halves or quadrants, their seams straight (along x and z)
//   or at 45 degrees, mirrored or rotational; `slice` names the authored
//   one (types/symmetry.lua lists the names). The World is finite, and
//   square where a map turns x into z (a quarter turn, a diagonal's
//   mirror); an edit enabling it otherwise is refused, why said. With
//   `enabled`, what is under it (its sources, each in the authored slice: one put
//   outside is refused, and so is a kit/wave) has a copy in each other
//   slice: an authored entity marked {"built": {"by": the kit/symmetry,
//   "member": source * 8 + slice, "source", "slice"}}, under its source's
//   parent's copy, made and kept by commit() in the same undo as the edit
//   (an undo puts the copies back with the rest). A copy's place and turn
//   are its source's image; a mirror's flips no model: it is the source
//   turned to the image's facing, flipped along its x, or its z for a
//   type with a `mirror` space parameter (kit/door: its swing), that
//   toggled. A source whose image is itself (on a seam, facing along it)
//   has no copy there. Links and entity parameters to a source become the
//   same slice's copy's; to elsewhere, the same. A signal from outside
//   the group to a source reaches each copy too. A copy is edited only by
//   its parameters (each one set its own, an override, kept as the source
//   changes; prefab_reset gives it the source's again): a move, a rename,
//   Add/Remove component, a child, a parent, a delete (but with the
//   kit/symmetry), a link to or from it are refused. Disabled or deleted, its
//   copies go. Entities outside it stay single. [KIT_AIRSHIPS_2] Hosting
//   makes the copies a build has none of yet (a template's on kit/symmetry).
//   A type's `space` = {<param> = <kind>} says what its parameters are
//   in space, for the copies: "world" (a position parameter that is a
//   place or a direction in the world: the image's), "offset" (along its
//   own axes: flipped with it), "rotation" (degrees round its x, y, z:
//   mirrored with it), "mirror" (a bool, its own mirror along z:
//   toggled), "box" (an extent from its corner cell along its axes: the
//   image's corner), "cells" (a box of the world's cells from its cell:
//   the image's lowest corner, its sides swapped as x and z are, its
//   voxels patterns too). Its zone, region, grants and look extent are
//   "box" and its volume and voxel_box "cells" unless it says. Kit's
//   types: kit/teleporter to "world", kit/effect axis and offset
//   "world", kit/mover offset and kit/course course "offset", kit/part
//   rotation "rotation", kit/door and kit/key_door mirror "mirror";
//   centred sizes need none.
//   simplified: a box's image is placed by its entity's first box or
//   cells parameter; a voxels pattern's shapes keep their facings; a
//   look's offset (a mover out) is not in a source's place
//   Its scene's World on (stage 2): a cell (set_voxel, a brush's dab
//   centre, a fill's corners, a paste's or a pattern's box) is edited
//   only in the authored slice where its images are on the map (out of
//   it refused, why said); each cell written writes its images (a
//   shape's facing turned, an inner or outer stair's mirrored by its
//   diagonal) in the same undo, and one written past a seam gets its
//   source's image back. On a heightmap a stroke's samples and its
//   decorations the same (a decorate stroke scatters in the authored
//   slice alone). Turned on, or its slices changed, the authored slice
//   is copied over the others (cells, samples, decorations: one undo
//   with the edit); after a generation or a regeneration (the voxels'
//   sections, a heightmap's) the same, with no undo; a section with no
//   authored column regenerates as unedited. At Play the server counts
//   the cells, samples and decorations differing from their source's
//   image and the entities outside it in the other slices: a warning to
//   the builders where any (util/kit_symmetry_voxels_check.sh).
//   simplified: only loaded sections are copied (a finite World is all
//   loaded near it); copied cells and samples are marked edited; a
//   generator's voxel_box writes are not mirrored
//   The editor's view (stage 3; the edit state's "symmetry": its slices'
//   maps, the authored slice's half-planes, the map, the parity text):
//   in edit mode the seams and a shade over the other slices; a copy
//   selected shows its parameters alone (with its overrides and Reset)
//   and "Go to source"; a kit/symmetry's inspector lists every override
//   on its copies and the parity warning
//   (util/kit_symmetry_view_check.sh).
//   [KIT_AIRSHIPS_2] **World regions** (kit/terrain_region): a type's
//   `world_region` names its position parameter, a box of the World's
//   cells from its cell (the box of `shape` "sphere"'s ball). Kit writes
//   its cells with the region's own generator (types/terrain_region.lua) as
//   it is placed and changed while editing (never in a game session), as
//   kept edits in the edit's undo, and its symmetry images; the World's
//   row "regions" holds what was written, so a change writes the
//   difference and a restart nothing: the cells of a region gone, moved
//   or reshaped that still hold what it wrote back to the World's
//   generated ground (air over a heightmap), the others left. A
//   kit/symmetry copy of a region writes nothing. On a heightmap's World
//   the regions' sections are its edited voxels (loaded from the save).
//   simplified: no water or caves; 128 cells a side; a builder's change
//   inside a region is written over by the region's next change
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
//     materials.json ([KIT_MATERIAL_SETS]) a material set (terrain.h): its
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
//   screen. [KIT_SCENE_PACKAGES] **Scene packages** (doc/aitta.txt
//   "Scenes"): {"op": "export_scene", "scene" (none: the builder's),
//   "publish"}: "kit:scene_export" (its file's name "<scene>.scene.zip", a
//   0 byte, the zip), or with publish "kit:scene_publish" {"name",
//   "author", "title", "game", "files", "hex"} for the publish screen
//   (kit_publish's kind "scene"). "kit:scene" (a scene package's zip, or
//   the Aitta, a 0 byte, its release's .sig, a 0 byte and its zip, the
//   signature checked as a package's and the key's vouch asked): a
//   builder with the tools on, Stopped, adds its scene as a new one, the
//   next free name of its own; its links and entity parameters onto
//   entities outside it made this game's entities of the same name, or
//   left out; its custom types the game lacks added, those it has kept
//   as they are; its rows checked as an export's (those of a key the
//   game has kept as they are). Answered with "kit:scene" {"ok": true,
//   "what", "scene", "game", "dropped": [what was left out], "kept": [its
//   types kept as the game's]} or {"ok": false, "why"}; "kit:edit_state"
//   has "game" ("<author>/<name>", the running one's). Credits: each client's
//   "kit:edit_state" has "credits", [{"author" (a package's with its
//   Aitta's host where it is ambiguous or unverified), "package"
//   ("<author>/<name>"), "id", "aitta", "verified", "version",
//   "license_code", "license_media" (a package's), "of": "kit"|"app",
//   "uses": [types, "[prefab]"]}], what the composition uses by who made
//   it (kit.show_credits(), the palette's Credits).
//   [KIT_CUSTOM_TYPES] **Custom types**: a game's own, "local/<name>"
//   (name letters, digits and _), each a type's file and an optional
//   client part as above, run as a package's are (the box, the clients'
//   sandbox). Kit's store's rows "type:local/<name>" {"source", "client",
//   "by"}; at most 64 of them, 64 KiB a server part (its declaration
//   too, as JSON), 32 KiB a client part. Any builder with the tools on
//   puts, reads and deletes them, in the default round, each an undo:
//   "kit:type" {"op": "get"|"put"|"delete", "name" ("bike" is
//   local/bike), "source", "client"} (outside "kit:edit"'s 4096 bytes),
//   answered with "kit:type" {"op", "name", "ok", "what"|"why"}; a get's
//   with "source", "client" and "custom" (Kit's own types, installed
//   packages' and custom ones read; never the app's own, which may be
//   private).
//   A put loads at once, Running or not: refused (a syntax or load error;
//   the client part's syntax compiled in the box, not run), the version
//   before runs on and the error is said in the Log of each entity on it.
//   Taken, each entity on it keeps its params and state (the new
//   version's state keys and params added at their defaults, its errors
//   forgotten; a param or a link's output the file no longer takes
//   dropped, here and when a composition loads, not the game),
//   its next runs the new handlers; the bodies on a movement step with
//   the new one, and the clients load the new client part. A newer
//   `version` migrates the authored instances as a package's upgrade. A
//   delete is refused while anything uses it. A put that takes long
//   holds its builder's next for a while. Agents: put_type, get_type,
//   delete_type. A template's types/<name>.lua are its game's from
//   its first start (Host::local_types_path); an export (below) takes
//   those its prefabs use as the builder's own <author>/<name>.
//   simplified: a start that finds one no longer loading (a file not the
//   same each run) leaves it out of the box, its entities' runs failing
//   Looks: shape "wedge", rotation {x, y, z} (degrees), material (plain,
//   metal, glass, glow), and "param:<name>" anywhere in a look is that
//   parameter's value (kit/part). [KIT_PLANE] shape "polygon", points (a
//   "points" value in the entity's x and y), depth (along its z, centred on
//   its position): a prism, its mesh built on the clients; solid, it is met by
//   the movements (move.lua) where it stands (turned by yaw 0 or 180 and any
//   roll; [KIT_STUNTS] (G6) at any turn, below), not by the clients' physics; with kit/controls' plane vertical only
//   where its depth spans the plane's z (others background or foreground).
//   [KIT_TOP_DOWN] (1) kit/controls' plane horizontal holds the bodies at one
//   height (the feet on the bottom of the spawn's cell, kit.cpp's plane_of()),
//   moving in x and z: kit/walker there has no gravity and no jump; a step's
//   w.horizontal is true, w.plane that cell's middle y, and w:circle's and
//   w:segment's x, y are the world's x and z (move.lua's header).
//   [KIT_TOP_DOWN] (8) The bodies pass through each other there unless the
//   movement's type declares movement.bodies = true: then a step's w:circle
//   meets the other players' bodies in the scene (in play, not seated, within
//   its reach) as circles of their body's r, info.body their by and info.vel
//   their velocity's x and z; the step pushes its own body out, each body
//   by its own step. The server's snapshot sends them (kit.cpp's
//   bodies_lit()); a client predicts against the others' last known places
//   (players.lua's others_bodies()). [KIT_STUNTS] Each with its feet's
//   height and its body's h: met only where they span the circle's slice
//   (a car on a bridge is no wall to one under it). simplified: a correction
//   on contact (the others' places are a round trip old on the client); no
//   bodies in a vertical plane or without one. [KIT_3D_GAINS_1] (4z38) a
//   steered creature's movement (kit/creature_walker's kind) declaring it
//   meets them too: a barrel knocked about; the players' bodies meet no
//   creature.
//   [KIT_STUNTS] movement.own_height = true there: the body keeps the height
//   and the speed up its step gives it (no holding; a put keeps the put's
//   height), the plane's 2D queries as ever, asked at the step's own slice
//   (w:circle's and w:segment's last argument): a car's own floor by w:down
//   and w:under, its jumps, a bridge's deck over and under (move.lua's
//   header). w:ray meets the solid polygons' prisms (standing, lying flat,
//   [KIT_STUNTS] (G6) tilted) as it meets boxes: a chase camera stays out of a
//   deck, a wall or a loop.
//   [KIT_TOP_DOWN] (2) a polygon turned pitch 90 (or -90) lies flat: its
//   points the world's x and z, its depth along y; its edges are upright
//   walls, met in a level plane where its depth spans the plane's y, in 3D its
//   top a floor. kit/polygon's `floor` (with collision off; flat only): a
//   floor patch, no wall, its info what w:under(x, y, z) gives over its area
//   (a walker's s.surface and s.friction), on both sides. The creatures'
//   pathfinder takes a flat one's box turned so (kit.cpp's grid_looks).
//   Its size and offset are its points' box (kit.cpp's). [KIT_SIDE_SCENERY]
//   voxel (a voxel type's name) and edge_depth: its textures world-aligned and
//   a band of its top along the edges facing up (module.lua's polygon_mesh).
//   [KIT_CLIENT_REACT] (5) surface (a short tag, "polygon" if none) and
//   friction (0...10, 1 if none): the info a movement's step gets where it
//   meets the polygon (w:circle's, w:segment's, w:move's hits, a walker's
//   s.surface), on the server's steps and the client's prediction alike
//   (kit/polygon's params so named): a spike strip a bike's step crashes on
//   itself, no zone and no round trip. [KIT_3D_GAINS_1] (4z38) kit/part's
//   surface ("object" if none) and friction too, on its solid box (M.look_box's
//   b.info): a boost pad or an oil slick a car's w:under tells under a tyre
//   (the higher of a floor polygon and a solid box under the point).
//   simplified: a free voxel object's hits say M.OBJECT, not their voxel's
//   (its boxes merge every material's cells).
//   [KIT_3D_GAINS_1] (4z38) In a level plane w:circle meets the free voxel
//   objects too (a kit/wave's swinging prefab: the builtin kit/hammer), each
//   of their boxes as turned now sliced at the plane's y (a convex outline).
//   simplified: a box's slice, no speed of its own (a swing pushes a body out,
//   it hands it no speed).
//   [KIT_STUNTS] (G6) A polygon turned otherwise (neither standing nor lying
//   flat: a tilted prism) is met too, kept with its turn (on Kit's grid, a
//   16th of a degree, the same bits on both sides): w:down, w:under and w:floor_at
//   (`floor` too), w:sweep and w:blocked, w:ray, w:segment and w:circle's
//   slice (its outline at the slice's height; a hit's info its +z face's,
//   with its normal: a slab lying near level told from a wall); a concave
//   one as its triangles. Before, it was met by nothing: a fix as (G4)'s, only such turns
//   act otherwise. A face met hands its normal: info.n {x, y, z} out of it
//   (info.nx its horizontal length, info.ny its up: w:move climbs it as far
//   as the body's slope lets, else steps up it), and w:down returns d, info,
//   nx, ny, nz (the normal of what it met for every kind; up for a voxel's, a
//   box's top and the ground): a stunt car on a loop of them.
//   [KIT_SIDE_SCENERY] (8) parallax = {follow =, follow_y =, repeat =}
//   ("param:<name>" as a look's; kit/parallax; experimental, [KIT_API_1]:
//   the field and the type may change in any release): the looks under the entity
//   are drawn by each client offset by its camera's travel from the
//   entity's place, 1 - follow of it along x and 1 - follow_y up
//   ([KIT_TOP_DOWN] (5) along z with kit/controls' plane horizontal), with
//   copies every repeat along x (0: none); never met (kit.cpp's collision
//   snapshot and the bots' grid leave them out, as controls.lua's world()
//   does). The editor draws them where authored (module.lua's parallax pass).
//   [KIT_3D_GAINS_1] (4z38) far = true: drawn behind the world as the sky is
//   (KitFar*.xml: at the far plane, no depth write, after the sky, unlit, no
//   fog, no shadow; the nearer of two looks drawn over the farther), a
//   mountain ring round a 3D view with follow 0 and follow_y 0; placed within
//   the camera's far clip (fog_end and a tenth), which culls past it.
//   repeat_z: with kit/controls' plane horizontal, copies every repeat_z along
//   z too (32 copies in all at most).
//   [KIT_3D_GAINS_1] (4z38) The looks are drawn no farther than the far clip
//   (kit/environment's fog_end and a tenth; past fog_end all is fog colour)
//   from the camera, measured to each drawable's box's middle plus half its
//   size (module.lua's cull); a far layer's looks at any distance, a get_view
//   pose sees them all. A client part's own nodes set their drawDistance.
//   Debugging: the builders with the tools on are sent each tick's signals
//   along links ("kit:flow" [[from, output, to, input]...], their lines
//   lit) and their selection's log ("kit:log" {"id", "lines"}).
//
// That player's inventory: c:count(item, ext) (how many), c:add(item, n,
// ext), c:take(item, n, ext) (all n or none: true if
// taken), c:list(ext) ({item = n}), c:has(item, n, ext) (count >= n); n is
// 1 if left out, an item letters, digits and _, ext a free-form table the
// provider may read (nil: {}; [KIT_API_1] its player and kit_ keys Kit's,
// refused: "ext.player is reserved"). The provider is the player entity's own
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
// shared state "on" (`enabled` at the start, which they write then),
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
//   c.players (a type's `reads_players`): each also has pos {x, y, z} (placed
//   ones: the world's, their feet's cell's middle, as c.pos is for an
//   entity), yaw (degrees, their view's last input), [KIT_MOVE_DRAW]
//   heading (degrees, their body's own: its movement state's yaw, a car's
//   nose; else the entity's) and alive (placed,
//   not waiting to respawn, their health's hp above 0 where they have
//   one); away true when they are in another scene than the entity (a
//   placed one's; never on the root's), scene the one they are in.
//   reads_regions = true -- c:region_at({x, y, z}): the region deciding the
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
//   session). 64 a run. A movement's step gets the factor as i.speed
//   ([KIT_MOVE_DRAW]). [KIT_SMALL_PIECES] The two apart: Kit scales the
//   body's own movement's `speed` parameter by the factor before the step
//   sees p (a walker's pace: its step needs nothing more), and passes the
//   factor itself as i.speed, which is the step's to use for the rest (a
//   bike's motor and brakes, a car's engine; 0 a freeze: brim_car holds
//   itself still at i.speed 0, as the race's grid does). A seat's movement
//   is the vehicle's own: its p unscaled (a steered vehicle's i.speed 1, a
//   seated player's step theirs); a driving bot's i.speed its own factor.
//   [KIT_SMALL_PIECES] A hazard that must react at once (spikes, a pit's
//   edge, ice) is the movement's step's to meet: a surface it reads (w:circle's
//   and w:under's info.surface, a kit/polygon's `surface` parameter), the
//   same on the server and in the client's prediction. A zone's on_enter
//   (a kit/trigger_zone) is the server's alone: the client learns of it a
//   round trip late and rewinds. crag_bike's head and finish line are so;
//   its spikes would be.
//   [KIT_BODY_VARS] c:body_var(player, key, value[, opts]): a player it reaches
//   (an id or a by, as c:speed's), on an app with Kit's controls: their
//   body's state has s.vars[key] = value from then on (nil clears), which
//   their movement's step reads on the server's steps and in their
//   client's prediction alike: it goes in each state the server sends
//   (kit:body), and the client steps its inputs since again with it, so a
//   rewind replays with the server's value. Until another call, Stop or
//   their body's going; kept over a put (a teleport, a respawn). 16 keys
//   a body, a key 1 to 32 letters, digits or _ (not a digit first), a
//   value a number, a boolean or a string of 64 bytes at most: a bad key
//   or value errs (as c:speed's factor), the 17th key, a player it does
//   not reach or one not here are refused in its log. 64 a run. Crag
//   Trial's run sets finish_open with a rider's last gem; the bike's step
//   holds itself still on the finish line's polygon (surface "finish")
//   while s.vars.finish_open. simplified: a value set less than a round
//   trip before the step that needs it still rewinds the client.
//   [KIT_MOVE_DRAW] opts {public = true}: the value is also in every
//   client's draw of that body (s.vars, the other players' clients too):
//   on its node, sent once a change to the clients that see it, a client
//   that comes later given the current ones. Each call says it again (one
//   without public makes the key private). A rider's style, a car's paint.
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
//   [KIT_GOALS] on = false: not drawn (a bool parameter's). arrow: the label
//   gets a <, >, ^ or v the way to it at the screen's edge. kind "use": at
//   the entity `target` names instead (its own place while it has none);
//   kind "reach": at the middle of the box of cells `box` from its own. A
//   UI's `stack` (kit/goal's): the shown ones of one anchor and place go
//   under each other (over, at a bottom anchor), a hidden one or one with no
//   text leaving no gap, by order then id.
// `by` is who caused it, "player:<id>" (a bot's "bot:<id>") or "app",
// carried along the links it sets off and kept with a timer. [KIT_API_1] A
// function's player argument (c:hurt, c:speed, c:session_move...) is a
// player's entity id or such a by. Handlers run only while the server
// is Running (below).
// on_start(c) as a round starts from the start (Play, an instance placed
// or restarted in the round); on_join(c, by) as a player goes through the
// round's start and each time the app places them in its scene anew
// (set_peer: the first time, or as another name; [KIT_SCENE_PACKAGES] one
// with no position on the root: in any scene, each scene they come into
// too); [KIT_SMALL_PIECES] on_away(c, by), a `reads_players` type's only,
// on_join's counterpart: once as a placed player leaves the scene it is in
// (gone from the game, to another scene or session, logged in as another
// name), the player's c.players entry then as it is after (here false when
// gone, else the scene they went to); one with no position on the root has
// it for each scene they leave, as on_join for each they come into, so a
// scene change there is on_away then on_join (p.here tells a leave of the
// game). A round that polled c.players for p.away or not p.here in a tick
// reacts here instead. on_enter/on_leave as a
// player's position (the cell it rounds to) comes into or leaves its zone
// ([KIT_ZONE_SHAPES] or its body's spheres or box: as zone's, above).
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
// [KIT_API_1] **Formats and levels.** A composition (the authored row, an
// export's or scene's composition.json) and a prefab say at their top
// "kit": the file format, raised when a file's structure changes, a newer
// Kit reading the older; and "api": the script level the game's own types
// are written for, which a new game gets as this Kit's and only its builder
// raises (none: a file from before, 1 each). A Kit kind's meta.json says
// "kit_api", which an install refuses above this Kit's
// (interface::aitta::check_manifest). A Kit that meets a newer "kit" or
// "api" refuses the file whole: "This game was made with a newer Buildat
// (Kit format 2, Buildat <its version, where known>). ... Update Buildat to
// open it."
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
//       position on a 1/16 cell's grid; [KIT_TOP_DOWN] (4) "pitch":
//       degrees, turned so in the world (90: a kit/polygon lying flat)
//   {"op": "place", "prefab": name, "pos": [x, y, z], "turn": degrees}
//       -- a prefab's copy, turned a multiple of 90 about its base
//       ([KIT_PREFAB_VOXELS]); "clipboard": true instead of a prefab: the
//       builder's copy pasted (its members no prefab's); [KIT_COMPONENT_ORDER]
//       "detached": true: its entities plain ones as a paste's (the editor's
//       for a stock prefab with no voxels)
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
//       look turned with it). [KIT_FREE_ROTATION] "pitch" and "roll" as well:
//       Quaternion(pitch, yaw, roll), roll first and yaw last; each one left
//       out keeps its value in the world. Zones and regions turn with it;
//       grants stay boxes of cells
//   {"op": "move", "ids": [n...], "by": [dx, dy, dz], "turn": degrees,
//       "axis": [x, y, z]}
//       -- entities moved together, one edit, turned about their middle;
//       [KIT_FREE_ROTATION] each by a turn relative to what it has when this
//       arrives, so quick presses add up. With "axis" (the world's; y when
//       absent) the turn is about that; one alone keeps its position
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
//       nor under it. [KIT_ROOT_EDIT] m "root" (or 1): onto the app root,
//       every scene's, for one with no position (a type with none and what
//       is under it, a root type; no World); one there is edited from any
//       scene, 0 putting it into the editor's. A place takes "parent":
//       "root" alike for a type with no position
//   {"op": "delete", "id": n}
//   {"op": "set", "id": n, "comp": i, "param": p, "value": v}
//       ([KIT_WAVE_PIVOT_CENTER] "center": true for "value": a parameter declared
//       with button = "center" -- kit/wave's pivot -- set to the placed prefab's
//       centre, its voxels' box's middle in its root's frame; the inspector's
//       "Center <param>" button. Add component starts such a parameter there)
//   {"op": "add_component", "id": n, "type": t}, {"op": "remove_component", "id": n,
//       "comp": i} ([KIT_COMPONENTS]): one undo each. Refused on a prefab's or a
//       generator's built child (its prefab's to change), a second of a type or a
//       second movement, what has a place (it is what the entity is) and an entity's
//       last. Live while Running: on_start for one added, on_remove for one removed.
//       [KIT_COMPONENT_ORDER] {"op": "move_component", "id": n, "comp": i, "by": -1
//       or 1}: swapped with that neighbour, both without a place; the order is the
//       behaviours' priority (the first to propose a move wins)
//   {"op": "link"|"unlink", "id": n, "comp": i, "output": o, "to": m,
//    "input": in}
//   {"op": "undo"}  -- the editor's own last edit, UNDO_MAX of them
//   {"op": "builder", "name": account, "on": bool}  -- the admin's only:
//       makes an account a builder, or no longer
//   {"op": "play"}, {"op": "stop"}, {"op": "save_start"}  -- the server's
//       state, below (a builder's, the tools on or not; refused in a
//       persistent world, Host::persistent)
//   {"op": "end_rounds"}, {"op": "remove_bots"}  -- [KIT_BUILDER_ROUND_CONTROLS]
//       a builder's, from anywhere (a round's session too, the tools on or
//       not): every game session ended; every bot made in play gone, in
//       the default and in each game session
//   {"op": "restart", "id": n, "comp": i}  -- Running: the instance's
//       state from the start again, and its on_start (its kept state stays)
//   {"op": "clear_kept", "id": n, "comp": i, "key": k}  -- [CRAG_BEST_RESET]
//       the instance's kept state (state.kept) at its defaults, Running or
//       not, one undo (the values before back); logged, the inspector's
//       "Clear kept state". [KIT_REPORT_1122B] With key (MCP's, no button):
//       only k removed from each kept value that is a table (a player's
//       name in kit/records' bests), the rest kept; refused ("no kept entry
//       k in <type>") when none has it
//   {"op": "focus", "sel": n (0: none), "cursor": [x, y, z] or null}  --
//       what the builder has selected and where their cursor is, which
//       the other builders see (no edit, no undo)
//   {"op": "terrain", "tool": t, "x", "y", "z" (the point on the ground),
//    "size": 1..12 (cells), "strength": 1..5, "biome": b (the World's by
//    default), "level": y, "x1", "z1", "stroke": n}  -- ([KIT] stage 4f)
//       a dab of a brush on the World's surface (voxels or a heightmap):
//       raise, lower, smooth, flatten (toward level), paint (biome b's
//       ground), decorate (b's scatter; in a cave its floor's and wall's),
//       dedecorate ([KIT_DEDECORATE] the World's decorations under it
//       taken away: on voxels a cell still as the generator decorated it
//       gets its undecorated value, an edited one stays; on a heightmap
//       the decoration objects standing there go), fill (the rectangle x, z to x1, z1 up to level, with b's ground or
//       "water"; voxels only), or column (nothing changed: the column at
//       the point said, for a check). Every dab carrying the same stroke
//       is one undo. On voxels a column's layers follow its biome (by
//       its top cell): the top role over filler (its depth) over stone,
//       the riverbed under sea level, water over it up to sea level; only
//       ground, air, water and plants are written. On a heightmap a
//       sample's layer is stone where steep, the riverbed under the sea,
//       else its biome's top, and decorations are voxel objects. Answered
//       with "kit:terrain" {tool, stroke, undo, what}
//       [KIT_AIRSHIPS_2] "on": "voxels" on a heightmap's World works on its
//       voxels instead (a floating island), and tool "seed" (always the
//       voxels) puts a ball of b's ground (radius size - 1) at the point,
//       in the air too: an island's start. A floating column (no ground in
//       the 8 cells under those a dab writes) grows no ground under its old
//       top: lowered past its bottom it is dug away. The editor's terrain
//       tool sends "on" for a voxel pointed at over a heightmap, and its
//       Seed brush goes on the cell in front of the voxel pointed at, else
//       12 cells along the pointer's ray
//       [KIT_AGENT_NEXT_2] "area": [x0, z0, x1, z1] in place of the point
//       (a heightmap's raise, lower, flatten and smooth; a side 256 at
//       most): the rectangle at once, no falloff; "amount" (cells) raises
//       or lowers by that, flatten goes to level itself
//   {"op": "region", "action": a, "at": [x, y, z], "size": [w, h, d],
//    ...}  -- ([KIT_AGENT_NEXT_2]) a box of voxels at once, one undo: fill
//       ("voxel", "param", "tint"), hollow ("voxel" its shell, none: the
//       shell as it is; the inside air), clear, replace ("voxel"'s cells
//       with "with"), copy (into the builder's clipboard), paste (the
//       copy's low corner at at, "turn" a multiple of 90, "air": its air
//       cells too), move (to "to", likewise); 32 a side. Its sections are
//       loaded first: while one is generated it is refused, nothing
//       written
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
//       terrain.h's Material's fields: registered in every scene at once and
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
//       game's sound's whole name changed (not Kit's, not a
//       package's: those are copied); {"op": "sound_delete", "name": its
//       whole name}. Refused in a draft. Sounds below
// "kit:texture", a PNG's bytes ([KIT] stage 4g): a builder with the tools
// on uploads a texture (square, 8..128 a side, a power of two, 64 KiB at
// most), decoded and saved again (the row "texture:<hash>"), served as
// "kit/up/<hash>.png" and answered with "kit:texture", that name.
// Each is checked on the server, the rights first, then the ids, types,
// parameter values (as the type declares them) and signal names; a
// refusal is logged and answered with "kit:edit_refused" ("<op>: why").
// [KIT_SINGLE] A place (a client's, not an agent's) refused for a single
// type its holder has is answered with "kit:single" {"id": the one there,
// "text": "place: why"} instead: the editor selects that one.
// An editor is sent "kit:edit_state" after each edit, anyone's:
// {"editing", "palette": [type...], "types": {type: {params, inputs,
// outputs, gizmo, usable, root}}, "authored": the row (positions and
// yaws the world's, [KIT_NESTING]), "undo": n, "admin",
// "voxels": [{"name", "texture", and the properties above}...] (each
// placeable voxel), "textures": [name...] (what a type may wear),
// and the admin's "people": [{name, admin, builder}] here}, and always
// "can_edit", "running" and "by" (who started the round). Everyone is
// sent it as the server's state changes, and a player as the admin grants
// or takes their rights. [KIT_EDIT_MODE_FPS] A key the same as last sent
// to that client is not sent again but named in "same": [key...], the
// client keeping its value; {"op": "state"} asks for all of it again (any
// client, rights or not). The builders with the tools on are sent
// "kit:builders" as any of them turns them on or off, selects or moves
// their cursor: [{"name", "color": "#rrggbb", "sel", "cursor"}].
// [KIT_AGENT_NEXT_2] An agent's show sends its account's clients
// "kit:agent_show" {"from", "color", "at", "box", "ids": [{"id", "at"}],
// "label"} (only from and color: cleared, as when it leaves). A type's
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
// run's, any for a type with `reads_players`; nil: those in its zone and the
// run's), moves a player into one it made or back (c:session_move(player,
// id), id 0 the default) and ends one it made (c:session_end(id));
// on_session_start(c, id) and on_session_end(c, id) are its own.
// [KIT_MAP_ROTATION] c:session_start(players, map, others): `map` the scene
// its players go into (nil: the maker's own), `others` scenes
// whose entities run nothing in this session, less `map` and the maker's own
// scene. c.scenes, for a `reads_teams = true` type, the composition's scenes. In a
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
// [KIT_API_1] (decision 6) Kept state (kept = true) in a session belongs to
// that session: it starts at its default there and is gone at the
// session's end, the default's untouched; what a session leaves behind
// goes out through c:session_end(id, result).
// [KIT_PREFAB_BENCH] {"op": "prefab_bench", "prefab": name} takes a builder
// to a prefab's temporary scene: a draft (kind "bench"; "kit:edit_state"'s
// session adds prefab, root, box, ready) of an empty World with nothing from
// the start but the environment, no generator, not running; one copy of the
// prefab at the origin, its voxels laid out as sections arrive (ready, and
// save_prefab refused before it). The World is the bench's own, one per
// builder, under MAX_SESSIONS. Refused: another's prefab, Kit's and packages',
// from inside a session, an app without sessions. {"op": "save_prefab"} with
// a root and box there is the Save; the game's own copies of the prefab
// follow (no undo entry in the game), other drafts' do not. {"op":
// "leave_draft"} is its Close: nothing else leaves it.
// [KIT_MINIGAMES_1] c:session_end(id, result) carries a result (JSON, 4
// KiB at most) to the maker's on_session_end(c, id, result) (nil
// without one), so a round's outcome reaches the default round.
// [KIT_MINIGAMES_FIX] In a session c.session_maker is the entity whose
// run started it (0: none, a draft); c.player_away is true when the player
// who set the run off is in another scene than the entity
// ([KIT_SCENE_PACKAGES] c.player_scene: the scene they are in, "" none).
// [KIT_LATE_JOIN] In a game session c.session_players is the number of
// players its start took in, bots too; in the default round c.sessions =
// {[id] = {players, taken, clock}} the game sessions it made: its players
// now (no bots), those its start took, its clock (s). As the run began.
// [KIT_RECORDS] c.now: the round's clock (a session's its own), seconds of
// game time as the run began; only differences mean anything (a time is
// c.now - an earlier c.now). The clients have the same clock (kit:clock):
// a kit/stopwatch's running time is counted on there from a c.now stamp.
// [KIT_PAUSE_ALONE] It is the clock of the entity's scene (one with none:
// that of the scene of the player who set the run off), which stops while
// the scene is paused.
//
// **The pause menu pauses a scene played alone** ([KIT_PAUSE_ALONE]): the
// client tells the server its app's pause menu (extensions/pause_menu,
// kit.add_menu_items' menu: the menu or a page of it) is up or not, the
// packet "kit:menu" "open" or "closed" ("closed" before an item acts).
// While Running, a scene whose one counting player (placed, in play, not
// editing, not the server's camera) has it up pauses, by the scene's
// kit/game_rules' pause_alone (on by default): its players' bodies (their
// clients' prediction held: kit:controls' paused), the steered movements
// and creatures, the projectiles, the actions held, the timers (on_timer;
// moved on by the pause as it ends, never early) and the scene's clock
// (c.now, kit:clock at rate 0: a kit/stopwatch, what moves by time) stop.
// A second counting player coming in, the menu closing, the player
// leaving or editing ends it; the first one's menu stays up. The day's
// clock, the music and what runs on other events go on; other scenes, and
// a session's round, are their own. The client's preference
// kit_pause_unfocused (off by default) opens the menu in play as the window
// loses the focus.
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
// `score`; a type with `reads_teams = true` reads the teams in its scene (of
// those, the ones under its own parent when there are any: a placed
// prefab's own), c.teams = {{id, params, state}} by id, and reaches them
// (c:send); a kit/arena runs a round only in the session it started (any
// other arena there idle); a kit/region with
// owner "team" is owned by the members of the team it is under (itself or
// an entity up its parents with a team: a team's base placed under the
// team). The prefab kit/team_match is a two-team match to place.
// [KIT_AIRSHIPS_2] kit/arena's "began" (the session's id) is emitted in the
// round as it starts, so the round's copies of what it links to hear it
// (kit/pause_menu_action's "hide": "To the lobby" out of a round only);
// "started" and "ended" stay the default round's.
// [KIT_CTF] kit/arena's map (of its `maps`; none: the round in the
// arena's own scene): the session's players go into that scene's copy
// (its spawn, then their team's pad), its teams the round's (c.teams, a
// `reads_teams = true` type's; outside a round its `next_map` state's
// scene's), and at the session's end back to
// the arena's scene (its spawn). `time_up`: "draw" (the default) or
// "most": the team with the most points wins at the timer's end
// ([KIT_API_1] with no teams the player with the most kit/score points,
// the result's scores theirs); a tie runs on as overtime (the status line says so) until the scores differ
// (checked each second). Its UI is drawn in its own scene only: its
// output `status` (the round's line as it changes: the time left or
// "Overtime", the scores, the result) is for a kit/ui_text in the map.
// [KIT_MAP_ROTATION] `maps` (scene names, comma separated) and
// `map_pick` ("round_robin", "random", "signal"), inputs "next_map" and
// "prev_map" in the default round: each round's map, shown as "Next map:" in
// the lobby's status; a round's own c.teams are its map's, and a map of the
// list not picked runs nothing in that round (not its timers either), so
// each map can hold its own teams and win conditions.
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
// **Sounds** ([KIT_SOUNDS]): the game's named sounds, each blip's
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
// [MUSIC_SYNTH] **Music**: kit/music (types/music.lua) holds a song's text
// (jam1, extensions/jam), synthesised on each client. music_tick() picks
// each player's (on: its per-player `on`, else `playing`; in their scene
// or on the root; the highest priority, a scene's, the lowest id) and
// sends "kit:music" {id, song, t0, now, mood} as it changes ({id, mood}
// for a mood alone, {id: 0} none): t0 when the entity went on for anyone,
// now the round's clock (motion_t()), so a late joiner starts at the bar
// the others are at (client_lua/music.lua). Nothing while the round is
// not Running; Play starts every song anew. get_state's round.music,
// analyze_music and get_guide topic music are the agents'.
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
// sound_break: a game's sound each ("" none).
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
// (by kit/game_rules' respawn: their team's pad, else the last spawner of
// players in their scene, else the app's spawn) at max. c.is_player: on a player's
// entity. "kit:hit" <entity id> is a placed peer's melee hit with what
// they hold: Running, out of the tools, a melee item of theirs, past its
// cooldown (game time), the target with health in their scene within its
// reach (eye to body) and in sight (no solid voxel between); then Kit's
// rules (kit/game_rules' peaceful on the root, [KIT_SCENE_TREE] the
// target's scene's nearest: players take no damage; the
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
// waiting player of the round back so; [KIT_RACE_PIECES]
// c:respawn_waiting(player) (an id, "player:<id>" or "bot:<id>"; 16 a
// run) that one alone, if waiting (each wreck its own wait: Brimstone's
// race). A waiting player does nothing:
// Kit refuses their hit, shot, draw, reload, use, item use, hold,
// inventory move and action presses, and allows() everything but
// "enter" ("Waiting to respawn": no dig, place or damage); the server
// steps their body with no walking or jumping (the view turns), the
// client too, and Kit's HUD says "Waiting to respawn". game_rules' respawn
// changed to "at_once" respawns those waiting. A player moved to another
// session (c:session_move, an arena's round and its end) waits no more in
// the one they leave.
// c:hurt(player, amount | {amount = n | fraction = f, type = name}):
// a player of the round hurt (fraction: of their health's max) through
// their modify_hit hooks and health as a hit of type `type` ("hurt" by
// default), by the run's by; Kit refuses it (logged) for a player waiting,
// under game_rules' peaceful, or where the region at them refuses them
// damage. 16 a run; a player that is no id or by an error.
// [KIT_CREATURES_8A] Creatures: an entity with a creature movement
// (kit/creature_walker's `movement.steered`, the server's drive) and
// behaviours, types with `creature = true`. A behaviour proposes a goal,
// c:propose_move{to = {x, y, z}, range (m, 0...64, 0), speed (a share of
// the walker's, 0.1...3, 1)}, or none, c:propose_move(nil); of the enabled ones that
// propose, the first in the entity's component order wins. The server
// paths the body (creatures.h: A* over the World's cells, walking, a jump
// of jump_height, a drop of 3; PATH_NODES_ONE a path, PATH_NODES_TICK a
// tick, charged to the meter) and hands the walker its waypoints. A
// creature type reads c.moving (its drive has a way to walk), c.health
// (its kit/health's share, 0...1), c.target (a `senses = true` type's
// state target). A type's `nearby = n | "param:name"` (m, 64 at most)
// reads c.nearby = {{id, pos, dist, types, player, name, alive[, sight]}}
// (16 nearest, from a 16 m bucket index; `sight = true`: also in_sight),
// c:nearest(type | "player"). [KIT_SPAWN_RULE] A type's `spawn_spots = true`
// reads, in on_timer, c.spots = {{x, y, z}...} (a spot by each player its
// parameters allow: prefab, radius, on_voxels, light_min, light_max, apart,
// apart_any) and c.far = {id...} (its copies no player is within despawn
// m of); kit.cpp's spawn_spots_lit, kit/spawn_rule. A creature whose section is not loaded
// sleeps: no steps, no timers (they are pushed on by its sleep), and goes
// on where it was when the section is back. The pathfinder's cells: the
// World's voxels and the solid looks (kit/part's, a shut door's).
// [KIT_ENT_PERF] Units: a steered movement declaring `native = "path"`
// (kit/unit_walker) is stepped by the server itself, no box call: its
// state's path walked as kit/creature_walker's step walks it (its params
// speed, width, height, jump_height, acceleration, gravity, rate), its body
// against the pathfinder's cells round it, and pushed out of the other
// native units' bodies in its scene. Its step runs instead where the
// server cannot (held, on a moving deck). Any other value of `native` is
// reserved: the step runs. simplified: whole cells (no slopes, step_height
// or swim); a door shut is met up to half a second late.
// c:fire{item = name, at = {x, y, z} | dir = {x, y, z}, from = {x, y, z}}:
// a shot of a ranged item of shot "projectile" from the run's own entity
// (from: off its place along the world's axes, {0, 0.5, 0} by default)
// towards `at` or along `dir`: the item's speed, damage, gravity,
// lifetime, pellets and spread; one a cooldown (the item's) an entity, a
// call before it passed ignored; 8 a run. Its hit is as a bot's (no
// knockback or hit rules): modify_hit and on_hit read hit.unit, the
// shooter's id, and by the run's by; the shooter is not hit by its own
// shots, which go with it. Refused (logged) while Stopped, unplaced, or
// for an item that is not a ranged projectile one. simplified: no
// magazine, ammo or wear; hitscan items refused.
// [KIT_RTS] Units a player commands: a type with `unit = true` (kit/unit)
// makes its entity one, and its param `team` whose (a kit/team's name: its
// members'; "": any player's). Its show has unit = {team}, and kit/controls'
// camera "rts" (a player who is a camera alone: no body, no movement stepped
// on either side, not drawn, not hit, in no zone; client_lua/rts.lua) selects
// such units by a click or a box and orders them. An order, "kit:order"
// {"ids": [id...], "at": [x, y, z]} or {"ids", "target": id}, is a placed
// player's in play (Running, not in the tools, within the acts' allowance),
// to 256 units at most; the ids they do not command (another team's, another
// scene's, gone) are left out, logged. It runs on_order(c, order, by) on each
// instance with it of each unit: order = {at = its own spot (the units in a
// square 1.5 m apart about the point, sorted by z then x), center = the point,
// k = its place (1...), n = how many} or {target = id, k, n}. kit/unit's walks
// to the spot (c:propose_move), or goes after the target to within its range
// and shoots it with its weapon (c:fire) while there (its state target, so
// c.target), until the target is gone or another order comes. kit:controls
// carries the player's team's name (team) for the client's selection.
// [KIT_GUIDE_BOTS] Bots: a type with `bot = true` (kit/bot, on a creature)
// acts as a player for the goals, its `by` "bot:<id>" (c:name: "<name>
// <id>"): its own goal state as a player's, a goal's zone entered, and
// c:use(id), a use as a player's (Kit's use range; simplified: no who-may-use
// rule). It reads c.goal = {id, kind, text, target, via, at, dist}, its
// active goal (the first by id, not audience "players"). Drawn as a player
// (show.player, show.bot).
// [KIT_GUIDE_BOTS_2] A bot is a player but for what an account holds: in
// c.players ({id, name, bot = true, by, here, state, pos, yaw, away,
// scene, alive}), c.player its own id in its runs (its own kit/inventory and the
// other player types, added as it is made), teams, an arena's queue and
// count (ready as it enters), zones, sessions (a round's: a copy of it made
// at the session's spawn, the bot itself parked until the session ends; a
// session with bots in it does not end idle), a flag's carry, health,
// respawn and hits. Not remembered, no edit or admin rights, no chat, no
// UI sent. c.goal = {id, kind, text, target, via, carry, at, dist}: the
// first by id it can act on now. c:emit(output, value, by): by (a player's
// or a bot's, one the instance reaches) is the `by` of the runs its links
// make (kit/flag's taken, credited to the taker).
// [KIT_GOAL_PRIORITIES] Goals are a priority list (kit/goal's priority,
// when_holding, item_tag; picks nearest_item and nearest_opponent; kinds
// attack and place_item with an item): c.goal is the highest priority one
// a bot can act on, with item, damage, reach and cooldown of the item its
// when_holding names (a bot holds all it has). c:use_item(name) (a bot's):
// the item hooks (on_item "use", target 0) as a player's click with it, an
// item of use kind "use" it has, once a second at most. c:hurt and blasts
// reach bots. An item's sheet has `tags` (8 names at most; the stock
// items' weapon, blade, tool, explosive), sent to the clients with it.
// [KIT_GUIDE_STATIONS] Stations: a movement declares one (movement =
// {station = "helm" | "gun"}); a reach or an attack goal whose via is a seat
// of such a vehicle gives c.goal.station = {seat, vehicle, does, held, at,
// dist, board, pos, yaw, elev, pitch, speed, params, muzzle, life}. A bot's
// c:use of a seat takes it as a player's use does (one on a free object from
// anywhere in its scene; simplified: the pathfinder does not walk a deck);
// c.seat is the seat held (0: none), c:drive{f, r, fire} its inputs there
// (-1...1; fire: a holder's jump, a turret's trigger), c:leave_seat() back
// where it stood; a teleport or a death takes it out. [KIT_BOT_DRIVE] A
// driving bot (kit/bot's drive) also steers the players' movement with
// c:drive; its runs have c.body {pos, vel, yaw, top} (its body as last
// stepped, the world's; top its movement's speed) and c.path {points =
// {{x, y, z}...}} (its kit/bot's `path`, else its scene's first kit/path,
// in the world; nil: none). Experimental ([KIT_API_1]): c:drive, c.body,
// c.path, kit/path and kit/bot's drive, skill and ask may change in any
// release, and publishing a type that uses them warns; a kit/bot that
// walks the goals is Kit API 1's. A turret held by a bot
// fires its shots as the bot's. c.aim(speed, gravity, d, h, lo, hi): the
// flattest elevation (radians) between lo and hi whose arc is h m over the
// muzzle d m out (move.lua's M.aim, by M.arc, which a gunner's impact
// marker draws with). Goal pick "nearest_health": the nearest thing with
// health that is no player or bot.
// [KIT_AIRSHIPS_BOTS_LEFTOVERS] A shot from a ship's gun passes its crew
// (seated under the ship, or a player on its deck). A bot hurt, or the ship
// it crews hit, fights back: c.goal {id = -1, kind = "attack", text = "fight
// back", target, station} through that ship's free gun for 30 s. A reach
// goal through a held station counts whoever aboard enters as the holder.
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
// [KIT_COLLECTIBLE] kit/collectible (its file says how): a gem, coin or
// crate each player takes for themselves by walking into its zone (`size`;
// a per_player state, taken for one and still there for the others); a
// take sends "pickup" (its `value`, by the player), Kit's world event
// "pickup" and its `sound`; it is back for that player after `again`
// seconds (0: never by itself) and by its "reset" input (set off by a
// player or a bot: theirs; by anything else: everyone's). Its client part
// hides it at once (e:predict), its look's when.vanish (`vanish`: "fly"
// or "none") drawing the going; its box may wear a `voxel` material and
// `edge` boards (Brimstone Speedway's wooden crates). A run counts a player's takes by linking
// pickup to an input of its own and resets the ones linked to it there
// (c.linked_in, c:send(id, "reset", nil, by): Crag Trial's crag_run).
// [KIT_RECORDS] kit/stopwatch (its file says how): each player's own, by
// the player the signal carries: "start" from 0 (again while it runs: from
// 0 again), "stop" (elapsed: its seconds), "reset" (stopped at 0), "lap"
// (lap: the seconds since its start or the last lap, running on); a stop or
// reset by no player is everyone's. Its "time", one signal at each start,
// stop and reset, is for a kit/ui_text to the player: while it runs the
// value {since = c.now} (the round's clock at its 0), which that text's
// {value}, {value:time} and {value:time1} count on from on the client by
// the shared time (kit:clock; controls.lua's M.shared_time()), so a running
// clock costs the server nothing; stopped, the seconds. kit/records: each
// player's best "time" or "score" (a number by a player; `better` "lower"
// or "higher"), kept state by the player's name (play and restarts keep
// them; Clear kept state drops them); each value sends "new_best" (a new
// best, by them) then "best" (their best, by them; also as they come into
// the round: on_join), and "board" the top `count` as they change and at
// the start, "1. name 12.3|2. ..." (a time to a tenth, a score as it is;
// a Clear kept state's empty one within a second).
// Crag Trial's crag_run and Brimstone's time trial are timed and ranked by
// them: the run's outputs start and stop the stopwatch, its elapsed (or
// lap) goes to the records' time and back to the run, the records' best
// back to the run for its result card.
// [KIT_PLAYER_PARAMS] c:set_param(id, type, param, value, {player = by}) (by
// "player:<id>" or a player's entity id; a player it reaches; not a bot):
// that player's own value of the parameter (nil: theirs gone), over the
// row's and play's for everyone, for them alone, wherever Kit reads the
// parameter for a player: their kit/controls (the nearest copy's: camera,
// camera_frame, distance, offset_*, fov..., their camera alone, sent to
// their client alone in "kit:controls"; not `plane`, one a scene: refused),
// their body's movement (its nearest copy's p, kit/walker's gravity: the
// server's steps and their client's prediction alike, their body put
// afresh where it is as the value changes, so prediction does not correct),
// a seat's movement while they hold it, and a UI type's `ui` fields that
// are "param:<name>" (kit/ui_bar's width and height from their stats:
// their client gets "kit:pparams" {"ui": {"<id>": {field: value}}} and
// draws the element made anew with them). Elsewhere (a handler's c.params,
// a look, `ui`'s `when`, client_params) the row's or play's. Until Stop,
// as c:set_param's; the inspector shows the row's. A change (not the same
// value again, not a nil with none) counts toward 20 a player and second,
// past that refused (logged once a second); 256 values a player.
// kit/param_set (its file says how) does it with no code: "set" sets
// `param` of the `target` entity's `target_type` component to `value`
// (true, false, a number, "x, y, z" or a text) or (source "signal") to the
// signal's number times `scale` plus `offset` within `min` and `max`;
// "reset" puts the target's own back; `to` "player": for the player the
// signal carries (a signal by no player does nothing), "everyone": play's
// for all. A trigger zone's entered and left to set and reset a gravity, a
// lever's on and off a camera.
// [KIT_RACE_PIECES] kit/checkpoint (its file says how): an unseen gate of a
// course, `order` its place (1, 2...), its zone `size` cells from its own
// along its own axes turned by its yaw (x across, z the way through: a
// gate across a road its heading's). Each player's last one passed (its
// per_player state `last`) is the scene's: Kit copies a run's change of it
// to every kit/checkpoint there (one course a scene). A pass counts in
// order, the one after the last or 1 at any time (the next lap, a fresh
// start); out of order (3 before 2) it does nothing. A counted pass sends
// "passed" (its order, by the player); "respawn" (by a player or bot, sent
// to each checkpoint) puts them at the middle of their last one facing its
// yaw; "reset" clears that player's progress, everyone's from no player.
// Laps are the course's own: Brimstone's brim_race counts them.
//
// **The World** ([KIT] stage 4e; terrain.h says how it is made): one
// game-wide kit/terrain on the app root, its parameters the choices -- the
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
	// [KIT_NO_WORLD] A scene without kit/terrain has none (surface "none":
	// no voxels, no heightmap), unless Host::world_default.
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
	// terrain.h), `param` 16..23 (what the definition says: a shape's
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
		// [KIT_TEMPLATES] That composition is a template's: its first start is
		// Stopped and the first builder to come is put in the tools (the
		// plan's "opens in: edit"); from then on the save says, as any
		bool opens_in_edit = false;
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
		// "" for none (kit/terrain not in the palette)
		ss_ world_scene;
		// [KIT_NO_WORLD] A scene with no kit/terrain has no World (no voxels,
		// no heightmap: its surface "none"); true: the World type's defaults
		// (`defaults`' among them) are its World, as before (Workbench's
		// games that neither New nor a template made: the checks')
		bool world_default = false;
		// The material set (JSON, terrain.h's format) binding the roles to
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
		// movement the app root's kit/controls (its defaults with none;
		// [KIT_SCENE_TREE] the nearest copy from the player's scene up).
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
		// [KIT_AGENT_NEXT_1] The agents' server camera (kit.cpp): a client
		// of the server's own draws get_view where no client of the
		// agent's account is, and plays a body (play_join). The app lets
		// in a client named accounts::CAMERA_NAME as Kit's (Workbench)
		bool camera = false;
		// [KIT_CUSTOM_TYPES] With composition_path a template's: its types
		// directory (<name>.lua, <name>.client.lua), the game's custom
		// types local/<name> from its first start ("": none)
		ss_ local_types_path;
		// [KIT_PROJECT_EXPORT] The game's name: a builder exports it
		// ("export_project", the agents' export_template) as a template
		// under it; "": no export. A template's first start also takes the
		// rest of an export from composition_path's directory (items.json,
		// sounds.json, voxels.json, prefabs.json, textures/, edits.bin) and
		// [KIT_SCENE_PACKAGES] its game: its meta.json's "game", else its
		// "<author>/<name>" (Kit's row "game"; a game no template made is
		// its first exporter's "<author>/<its name>"). A builder exports one
		// scene as a scene package ("export_scene", the agents'
		// export_scene) and adds one as a new scene ("kit:scene", the
		// scene list's Add from a file... and the New tab's list of the
		// Aittas' scene packages): doc/aitta.txt "Scenes"
		ss_ project;
		// [KIT_PROJECT_EXPORT] The app's games for the agents' tools
		// (list_games, copy_game, rename_game), an admin's: op
		// "list" (out: [{name, bytes, running}]), "copy" or "rename" {name,
		// to}; false and why not. Called on Kit's thread. Unset: no tools
		std::function<bool(const ss_ &op, const json::Value &args,
				json::Value &out, ss_ &why)> projects;
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
		// as a material set's voxel says it (terrain.h; its "tint" may name
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
