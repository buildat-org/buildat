-- Buildat: builtin/kit/client_lua/editor.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 3, Kit's editor on the client (builtin/kit/api.h says what
-- the server takes); its UX apps/floorplanner's ([KIT] stage 4e2: "do what
-- floorplanner does"). module.lua runs this file with what it shares.
-- ([KIT_EDITOR_LOCALS] its second half, input and drawing: editor_input.lua)
--   kit.editor{scene = scene, camera = camera_node, ground_y = 1,
--       solid = function(x, y, z) return <a voxel there> end,
--       bar = false, menu = function() <the app's pause menu> end,
--       set_camera = function(node) <the app's camera for its world> end}
-- An entity's cell is the voxel at its position (centred on it, as
-- voxelworld's are). solid (optional) is the app's voxels, which a click
-- points at; ground_y the cells' y where no voxel is met; camera the
-- app's own (walking's); set_camera tells the app which camera draws
-- (voxelworld.set_camera); menu opens the app's menu (a touchscreen's
-- Menu button; Escape's otherwise). ([KIT] stage 6a) viewport (optional):
-- a function giving the app's own viewport for the walk view (its render
-- path: skeldat's sky), else Kit's (its controls' effects).
-- The keys below are the defaults: each is an action of input.lua's, the
-- player's to rebind ([KIT_INPUT_ACTIONS]); Ctrl, Shift and Escape fixed.
-- F6 or "Edit" asks the server for edit mode; with edit rights (the
-- server's admin, a builder) the server answers with the palette and the
-- authored tree. Floorplanner's, here:
--   - **Three views**, the top bar's dropdown or F1, F2, F3: 2D (an
--     orthographic camera looking down from the cut height, which the
--     bar's Cut - and + move, north up), 3D (a free camera: WASD, Space
--     and C, faster the higher it is, as the plan's zoom, Shift faster;
--     the arrows turn it with nothing selected), and
--     walking (the app's own camera and its walk). 2D: the middle drag
--     and WASD pan, the wheel zooms about the pointer; a right drag goes
--     into 3D orbiting, let go north-up straight down back into the plan.
--     3D: the right drag orbits round what the pointer is on, the middle
--     drag pans over the ground (the XZ plane, the point grabbed kept under
--     the pointer), the wheel goes toward it. Walking at the pointer, the
--     right drag turns; a click on the view goes up into the crosshair
--     (the mouse looks, the clicks act at the crosshair) and Escape comes
--     back down. Walking with the voxels tool on, the wheel steps the
--     voxel in hand through the Voxel list, Shift+wheel its shape,
--     Ctrl+Shift+wheel its tint ([KIT_WALK_WHEEL])
--   - **The same tools in every view**: what a click would do is shown on
--     what is pointed at (kit.HOVER's frame) and said at the bottom
--     ("Left: ... Right: ..."), nothing where a click does nothing; a click
--     selects (Shift: adds or takes out), a click on nothing lets go; a
--     drag from nothing (or from what is not selected) selects by a box
--     (as floorplanner, in every view); a drag of the selection moves it
--     on the ground by the grid (the bar's Grid, G), one edit; the
--     selection's knob (the circle's) turns it by the angle step (the
--     bar's Angle, H; Z and X turn it a step), one edit; the arrows nudge
--     it a grid step (Shift: a quarter), Page Up and Down up and down;
--     Delete deletes it, Ctrl+D duplicates it, Ctrl+Z undoes this
--     editor's last edit, Tab selects the next entity in the order last
--     accessed (clicked on, edited, made or duplicated: the top; Tab's
--     own selection moves nothing), Shift+Tab the other way
--   - **The panel** (left; [KIT_EDITOR_PANELS]): its tabs are the tools,
--     each tab's body (it scrolls) the tool's options -- Components,
--     Terrain (T), Voxels (V); Box (B), Entities, Items and Sounds, in
--     two rows
--     ([KIT_TABS_TWO_ROWS]); the tabs and the 3D camera as the builder
--     left them in the project, kit.remember ([WB_EDITOR_VIEW_MEMORY]).
--     Components: a type or
--     prefab dragged onto the view goes where it is let go (its ghost
--     there meanwhile), or clicked it is placed by the clicks on the view
--     until Escape, a right click or a click on it again (floorplanner's
--     Object tool); a type with no position, clicked, has a menu instead:
--     Place (in the scene edited, at once), Favourite, Cancel
--     ([KIT_PALETTE_MENU]). Voxels: its Voxel list puts a voxel type in hand
--     (O.pick_voxel(name), the app's placing) and the voxels tool on,
--     "none" away; and "New voxel type..." makes a builder's own: a
--     texture (Kit's or an uploaded PNG), kind, solid, transparent, light,
--     friction, surface. Entities: the entities listed to select (tabs:
--     Game-wide, Scene, Positioned). [KIT_ITEMS_TAB] Items: the item
--     types by group (a search), one selected its sheet in the inspector,
--     each copied as new, given to oneself in play, deleted (the
--     project's own), dragged into the view as a kit/pickup of it.
--     [KIT_SOUNDS] Sounds: the
--     project's named sounds (blip's parameters), each played, edited in
--     blip's designer (its Save writes it back), copied as new or deleted;
--     "New sound..." names one and opens the designer
--   - **The voxels tool** (V, or the panel's Voxels; an app
--     with solid): a left click places the voxel in hand on the face
--     pointed at, Shift+left digs the voxel pointed at, each one undo;
--     walking as play ([KIT_PLAYTEST_TWEAKS]): the left button digs, the
--     right one places (a touchscreen: a tap digs, a finger held places),
--     at the crosshair within play's reach (reach, 6 cells by default),
--     Escape out of the crosshair first; the other views at the pointer
--   - **Links dragged**: the selected entity's outputs are ports beside
--     it; one dragged onto another entity's input (its ports show as the
--     drag is over it) links them, onto the entity a link to its one
--     input. The inspector's "Link <output>" and then "To <input>" too
--   - **What a click picks** ([KIT_SELECT_BURIED], user): an entity
--     anywhere along the ray, through voxels (one under the ground too),
--     to select, for its menu, to link to and in the hover; voxels hide
--     what is behind them only while they are worked on (pick's
--     voxel_work()) and for the camera's pivot
--   - **A right click** (held, it looks) on an entity: its menu -- Delete,
--     Duplicate, Make prefab..., Restart this (Running) -- for the
--     selection if it is in it; on nothing it lets go of the selection
--   - the inspector (right): the selected entity's instances, their
--     parameters in ui_utils' settings_form, "Apply" sends them; its x, y
--     and z typed in and "Move" (the selection by as much), "Delete"
--     (the selection, a game-wide entity too); ([KIT_TRY_INPUTS]) "Try:"
--     a button per input (a value field beside one that takes a value)
--     sends it to the entity as a link would, running the game first
--     while Ended; what it emitted is shown a moment ("→ opened");
--     ([KIT_REPARENT_BUTTONS]) "Switch parent" and then an entity clicked
--     (the view's or the list's; Escape or the button again cancels) puts
--     it under that one, "Un-parent" back under the scene; a UI element's
--     new parent may be a panel ([KIT_PANEL_PARENT]), which it is then in
--   - every entity drawn as a box, the selected ones yellow, links as
--     lines, and a type's gizmo (a sphere or a box), in edit mode only
--   - the admin's: who is here, each "Builder: yes/no" to grant or take
--     edit rights; ([KIT] stage 4c) the builders with the tools on, each
--     in a colour: another's selection outlined in theirs with their name
--     over it, their cursor a cross (the builders' panel, below at the
--     left); "Save as start" (the bar, Running); the builds the last End
--     discarded until the next Run: "Keep them", or "Choose..." a
--     player's; "Always keep builds" (the game's settings window's Kit
--     section)
--   - **A touchscreen** (BUILDAT_TOUCH=1, [FP_TOUCH]'s): a tap is a click,
--     a finger dragged on the selection moves it (on a port links, on the
--     knob turns), elsewhere it moves the view (2D: pans; 3D: pans; two
--     fingers pinch to zoom, in 2D pan together and in 3D orbit round the
--     middle; walking: the app's), held still it is the right click; the
--     bar at the lower right: Undo, Delete, Cancel (Escape); the top bar's
--     Menu; the panels folded on a narrow screen, the bar's Tools and
--     Inspector open one
-- Kit's top bar, for a builder: the tools ("Edit", "Play mode" while they
-- are on; F6; play mode Runs the game if it has Ended) and the server's
-- state ("Run" while Ended, "End" while Running: End puts the start
-- back; [KIT_PLAYTEST_TWEAKS], Play and Stop before; none of it, nor
-- Save as start, the discarded builds or "Always keep builds", in a
-- persistent world, [KIT] stage 6a2);
-- kit.editor{bar = false} leaves it out of play for an app's own menu
-- (the tools always have theirs): kit.can_edit(), kit.editing(),
-- kit.running() (and kit.by(), who), and kit.set_tools(on),
-- kit.toggle_tools(), kit.play(), kit.stop(), kit.save_as_start() do what
-- the bar does; kit.on_change(fn) calls fn() as any of the states changes.
-- kit.add_menu_items(menu) puts Edit and Run/End (a builder's) and
-- Credits... (everyone's) in extensions/
-- pause_menu's menu and Kit's Escape first (kit.escape(): the context
-- menu, a drag, placing, a pending link, the crosshair; true when taken).
-- [KIT_SIGNALS_VIEW] F5 or the dropdown: Signals, the composition's links as a
-- table over the whole window (signals.lua).
-- kit.view() ("2d", "3d", "walk", "hud" or "signals": the app walks only in
-- "walk" while editing), kit.looking() (the editor's crosshair: the app's mouse looks).
-- kit.selected(): the id last selected, kept after edit mode.
-- simplified: one edit per entity for a Delete of several; a duplicate
-- one cell along +x; the windows rebuilt whole on each state
return function(K)
local M, E, O, P = K.M, K.E, K.O, K.P
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local aitta = require("buildat/extension/aitta")
local log = K.log
local send, color, row, text, label, button, edit, v3 = K.send, K.color,
		K.row, K.text, K.label, K.button, K.edit, K.v3
local WARN, DIM, STYLE = K.WARN, K.DIM, K.STYLE

-- The editor's own state: E's beside the shared
local function init(t, k, v)
	if t[k] == nil then
		t[k] = v
	end
end
for k, v in pairs({state = nil, link = nil, cursor = nil, pending = {},
		status = "", windows = {}, builders = {}, seen = {}, labels = {},
		label_text = {}, listeners = {}, discarded = {}, always_keep = false,
		choose = false, prefab_name = "", logs = {}, flows = {},
		package_name = "my_prefabs", credits = {}, try_values = {},
		voxel_form = {name = "my_voxel", texture = "kit/stone.png", kind = "solid",
			solid = true, transparent = false, light = 0, friction = 1,
			blast_resist = 0,
			surface = "", group = "", level = 0, drop = ""}}) do
	init(E, k, v)
end
-- Floorplanner's S: the view, the cameras and what the pointer is doing
local S = {view = "walk", sel = {}, primary = nil, grid = 1, angle = 4,
	pos = nil, yaw = 0, pitch = 30, cx = 0, cz = 0, span = 24, cut = nil,
	press = nil, drag = nil, right_click = nil, mx = 0, my = 0,
	placing = nil, crosshair = false, fingers = {}, folds = {},
	touch = buildat.get_env("BUILDAT_TOUCH") == "1"}
M.S = S

-- [KIT_PLAYTEST_TWEAKS] Tab's order: the entities last clicked on, edited,
-- made or duplicated first (S.recent, ids), the rest after them by id;
-- S.tab_at where Tab walks from, the top again at each of those
S.recent = {}
local function touch(id)
	for i, x in ipairs(S.recent) do
		if x == id then
			table.remove(S.recent, i)
			break
		end
	end
	table.insert(S.recent, 1, id)
	S.tab_at = 1
end
do
	local send_ = send
	local EDITS = {set = true, move = true, link = true, unlink = true,
		rename = true}
	send = function(j)
		if EDITS[j.op] then
			for _, id in ipairs(j.ids or {j.id}) do
				touch(id)
			end
		end
		-- [KIT_PREFAB_ROOT] prefabs.lua
		if j.op == "move" or j.op == "set" then
			K.prefab_moving(j)
		end
		K.prefab_bench_sent(j)
		return send_(j)
	end
end

-- Floorplanner's: the grid steps (cells) and the angle steps (degrees, its
-- for objects 15), the pixels a press may move and still be a click, a
-- knob or port is pointed within, a right press may move and be a click
local GRID_STEPS = {1, 0.5, 0.25, 1 / 16}
local ANGLE_STEPS = {false, 1, 5, 15, 45, 90}
local DRAG_PX = 4
local SNAP_PX = 12
local RIGHT_CLICK_PX = 5
-- [KIT_PLAN_3D_SKY] How high over the cut a plan's 3D view starts at most
local PLAN_3D_MAX_H = 100
local LONG_PRESS_US = 500000
local VIEW_NAMES = {["2d"] = "2D", ["3d"] = "3D", walk = "Walk", hud = "HUD",
	signals = "Signals"}
-- [KIT_INPUT_ACTIONS] each view's key's action (input.lua)
local VIEW_KEYS = {["2d"] = "view_2d", ["3d"] = "view_3d", walk = "view_walk",
	hud = "view_hud", signals = "view_signals"}
-- How far a click looks for a voxel, in cells
local MAX_RAY = 128

-- [FP_TOUCH] 4: a finger is broader than a pointer, and a pixel a device's
local function px(n)
	return S.touch and n * 2 * magic.ui.scale or n
end

function M.selected()
	return S.primary
end

-- Whether this player is in edit mode now: an app with a mouse look lets
-- the pointer go for the editor's clicks
function M.editing()
	return E.editing
end

function M.can_edit()
	return E.can_edit
end

function M.running()
	return E.running
end

function M.by()
	return E.by
end

function M.view()
	return S.view
end

-- The editor's crosshair: walking, the mouse held for the view
function M.looking()
	return E.editing and S.view == "walk" and S.crosshair and not S.touch
end

function M.on_change(fn)
	E.listeners[#E.listeners + 1] = fn
end

local function changed()
	for _, fn in ipairs(E.listeners) do
		fn()
	end
end

function M.set_tools(on)
	-- [KIT_PLAYTEST_TWEAKS] play mode runs the game if it has ended
	if not on and E.editing and not E.running then
		M.play()
	end
	send({op = "mode", on = on == true})
end

function M.toggle_tools()
	M.set_tools(not E.editing)
end

function M.play()
	send({op = "play"})
end

function M.stop()
	send({op = "stop"})
end

local people
-- [KIT_TRY_INPUTS] The inspector's Try: entity id's input sent to it, the
-- value typed (s) read as the input's type ty takes it; Ended, the game
-- Run first (as play mode does)
function M.try(id, input, ty, s)
	s = s or ""
	local v, ok = nil, true
	if ty == "number" or ty == "entity" then
		v = tonumber(s)
		ok = v ~= nil
	elseif ty == "bool" then
		ok = s == "true" or s == "false"
		v = s == "true"
	elseif ty == "position" then
		local x, y, z = s:match(
				"^%s*(%-?[%d.]+)[%s,]+(%-?[%d.]+)[%s,]+(%-?[%d.]+)%s*$")
		v = x and {tonumber(x), tonumber(y), tonumber(z)}
		ok = v ~= nil
	elseif ty == "string" then
		v = s
	elseif ty == "any" and s ~= "" then
		v = tonumber(s) or s
	end
	if not ok then
		E.status = "Try " .. input .. ": " .. (ty == "position" and
				"three numbers" or ty == "bool" and "true or false" or "a " .. ty)
		return people()
	end
	if not E.running then
		M.play()
	end
	log:info("kit editor: try " .. id .. "'s " .. input .. (v ~= nil and
			" " .. tostring(type(v) == "table" and table.concat(v, ",") or v) or
			""))
	send({op = "try", id = id, input = input, value = v})
end

function M.save_as_start()
	send({op = "save_start"})
end

-- What this builder has selected and their cursor, for the others
local function focus()
	send({op = "focus", sel = S.primary or 0, cursor = E.cursor})
end

-- Every authored entity, of every scene
local function all_entities()
	local r = {}
	for _, e in ipairs(E.state and E.state.authored and
			E.state.authored.entities or {}) do
		r[#r + 1] = e
	end
	return r
end

-- [KIT_SCENES] The scene an entity is in (its scene entity's name; nil
-- for the root's and the scenes themselves)
local scene_cache = {state = nil, by = {}, of = {}}
local function scene_name(e)
	if scene_cache.state ~= E.state then
		scene_cache = {state = E.state, by = {}, of = {}}
		for _, x in ipairs(all_entities()) do
			scene_cache.by[x.id] = x
		end
	end
	local by = scene_cache.by
	if e.id and scene_cache.of[e.id] ~= nil then
		return scene_cache.of[e.id] or nil
	end
	local found = false
	local id = e.parent
	for _ = 1, 64 do
		local x = by[id]
		if not x then
			return nil
		end
		if x.kind == "scene" then
			found = x.name
			break
		end
		id = x.parent
	end
	if e.id then
		scene_cache.of[e.id] = found
	end
	return found or nil
end

-- The scene the editor is in
local function current_scene()
	return E.state and E.state.scene or ""
end

-- The authored entities the editor sees: the root's, the scenes, and
-- those of the scene it is in
local function entities()
	local r = {}
	local cur = current_scene()
	for _, e in ipairs(all_entities()) do
		local s = scene_name(e)
		if s == nil or s == cur then
			r[#r + 1] = e
		end
	end
	return r
end

-- [KIT] stage 4d: the round's own entities (made in play) and the players,
-- shown and selected, not edited (those of the scene it is in)
local function made()
	local r = {}
	local cur = current_scene()
	for _, e in ipairs(E.state and E.state.made or {}) do
		local s = scene_name(e)
		if s == nil or s == cur then
			r[#r + 1] = e
		end
	end
	return r
end

local function find(id)
	for _, e in ipairs(all_entities()) do
		if e.id == id then
			return e
		end
	end
	for _, e in ipairs(made()) do
		if e.id == id then
			return e, true
		end
	end
end

local function type_of(t)
	return E.state and E.state.types and E.state.types[t] or {}
end

-- [KIT_NESTING] The tree of the positioned entities: each one's children
-- (by its id), in the order they were added. A row's pos and yaw are the
-- world's (the server's edit_state; the save keeps them in the parent's
-- frame). In one table: the file's locals are at Lua's 200
local NT = {cache = {}}

-- [KIT_SIGNALS_VIEW] Whether the Signals table has the window now
function NT.sig()
	return E.editing and S.view == "signals"
end

-- The views with the world's clicks and keys not taken
function NT.world_off()
	return E.editing and (S.view == "hud" or S.view == "signals")
end
-- [KIT_HUD_STYLE] kit/game_rules' entity and component: the scene's own,
-- else the root's (nil: none)
function M.rules_entity()
	local cur, id, comp = current_scene(), nil, nil
	for _, e in ipairs(all_entities()) do
		if not e.pos then
			for i, c in ipairs(e.components or {}) do
				if c.type == "kit/game_rules" then
					local s = scene_name(e)
					if s == cur then
						return e.id, i - 1
					elseif s == nil then
						id, comp = e.id, i - 1
					end
				end
			end
		end
	end
	return id, comp
end

-- [KIT_HUD_STYLE] "Copy style from...": a UI element's style parameters
-- (never its position, text or wiring) onto another's. A type's own prefix
-- where they live beside others (its parameters' names start with it)
NT.STYLE_KEYS = {"style", "form", "direction", "color", "background", "border",
	"size", "blink_below", "width", "height"}
NT.STYLE_PREFIX = {["kit/game_rules"] = "health_", ["kit/arena"] = "hud_",
	["kit/flag"] = "hud_", ["kit/goal"] = "hud_"}

-- The prefix of a component with a style (nil: it has none)
function NT.style_prefix(ctype)
	local pre = NT.STYLE_PREFIX[ctype] or ""
	return (type_of(ctype).params or {})[pre .. "style"] and pre or nil
end

-- Those with a style but the component `id`, `ci` ({label, "<id> <comp>"})
function NT.style_sources(id, ci)
	local list = {{"pick one", ""}}
	for _, e in ipairs(entities()) do
		for i, c in ipairs(e.components or {}) do
			if NT.style_prefix(c.type) and (e.id ~= id or i ~= ci) then
				list[#list + 1] = {NT.entity_label(e), e.id .. " " .. i}
			end
		end
	end
	return list
end

-- [KIT_COMPONENTS] A seat with no movement or a movement with no seat does nothing:
-- said where it is added
function NT.component_hint(w, e, t)
	if not t.seat and not (t.movement and not t.root) then
		return
	end
	local seat, movement = false, false
	for _, c in ipairs(e.components or {}) do
		local o = type_of(c.type)
		seat, movement = seat or o.seat, movement or o.movement
	end
	if t.seat and not movement then
		text(w, "No one can sit: it needs a movement (kit/car)", WARN)
	elseif t.movement and not seat then
		text(w, "No one drives it: it needs a kit/seat", WARN)
	end
end

-- [KIT_COMPONENTS] "Add component": the types without a place not on it yet (the
-- server's refusals, a second movement, come back as the status)
function NT.add_component(w, e)
	local on, list = {}, {{"pick one", ""}}
	for _, c in ipairs(e.components or {}) do
		on[c.type] = true
	end
	local names = {}
	for name, t in pairs(E.state.types or {}) do
		if t.addable and not on[name] then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		list[#list + 1] = {name, name}
	end
	if #names == 0 then
		return
	end
	ui_utils.dropdown(row(w), list, "", function(x)
		if x and x ~= "" then
			log:info("kit editor: add " .. tostring(x) .. " to " .. e.id)
			send({op = "add_component", id = e.id, type = x})
		end
	end, {label = "Add component...", fill = true})
end

function NT.copy_style(from, from_ci, to, to_ci)
	local f, t = find(from), find(to)
	local fc = f and f.components and f.components[from_ci]
	local tc = t and t.components and t.components[to_ci]
	local fp = fc and NT.style_prefix(fc.type)
	local tp = tc and NT.style_prefix(tc.type)
	if not fp or not tp then
		return
	end
	local fd, td = type_of(fc.type).params, type_of(tc.type).params
	local n = 0
	for _, k in ipairs(NT.STYLE_KEYS) do
		local d, dt = fd[fp .. k], td[tp .. k]
		if d and dt then
			local v = (fc.params or {})[fp .. k]
			if v == nil then
				v = d.default
			end
			local now = (tc.params or {})[tp .. k]
			if now == nil then
				now = dt.default
			end
			if v ~= now then
				send({op = "set", id = to, comp = to_ci - 1, param = tp .. k,
					value = v})
				n = n + 1
			end
		end
	end
	log:info("kit editor: copied the style of " .. from .. " to " .. to .. ": " ..
			n .. " parameters")
end

-- For a drive: "event kit_copy_style <from id> <to id>" (the first
-- component of each), as the sheet's dropdown does
magic.SubscribeToEvent("command_seq:kit_copy_style", function(_, data)
	local from, to = data:GetString("Param"):match("^(%d+) (%d+)$")
	if from then
		NT.copy_style(tonumber(from), 1, tonumber(to), 1)
	end
end)

-- [KIT_PANEL_PARENT] simplified: kit/ui_panel by name, as NT.is_ui goes; a
-- builder's own type of ui kind "panel" takes its elements in the server and
-- on the screen, but Switch parent here and the list's indent miss it
function NT.is_panel(e)
	local c1 = e and e.components and e.components[1]
	return c1 and c1.type == "kit/ui_panel"
end

-- p, if x stands in its tree: a positioned one under a positioned one, or
-- ([KIT_PANEL_PARENT]) one with no position in a panel
function NT.tree_parent(x, p)
	return p and ((x.pos and p.pos) or (not x.pos and NT.is_panel(p))) and p or
			nil
end

function NT.tree()
	local tree_cache = NT.cache
	if tree_cache.state ~= E.state then
		local by, kids = {}, {}
		for _, x in ipairs(all_entities()) do
			by[x.id] = x
		end
		for _, x in ipairs(all_entities()) do
			local p = NT.tree_parent(x, by[x.parent])
			if p then
				kids[p.id] = kids[p.id] or {}
				table.insert(kids[p.id], x)
			end
		end
		tree_cache = {state = E.state, by = by, kids = kids}
		NT.cache = tree_cache
	end
	return tree_cache
end

-- The positioned entity or the panel e is under, or nil (a scene)
function NT.parent_of(e)
	return e and NT.tree_parent(e, NT.tree().by[e.parent]) or nil
end

-- Every entity under id, parents first
function NT.under(id)
	local r, kids = {}, NT.tree().kids
	local function walk(x, d)
		for _, c in ipairs(kids[x] or {}) do
			r[#r + 1] = c
			if d < 16 then
				walk(c.id, d + 1)
			end
		end
	end
	walk(id, 0)
	return r
end

-- Whether e is under one of the ids (a set)
function NT.under_one_of(e, ids)
	local p = NT.parent_of(e)
	for _ = 1, 18 do
		if not p then
			return false
		end
		if ids[p.id] then
			return true
		end
		p = NT.parent_of(p)
	end
	return false
end

-- An entity's cell is the voxel at its position, centred on it
local function center(e)
	return magic.Vector3(e.pos[1], e.pos[2], e.pos[3])
end

-- Where it is drawn: an edit's preview (P.preview[id] = {x, y, z, yaw, q = its
-- turn, angles = {yaw, pitch, roll} of a selection's handles, till: let go,
-- until the node is there), else its node's, else its row's
local function drawn_at(e)
	local pv = P.preview[e.id]
	if pv then
		return magic.Vector3(pv[1], pv[2], pv[3])
	end
	local n = P.nodes[e.id]
	return n and n.node.position or center(e)
end

-- [KIT_FREE_ROTATION] A row's turn in the world, as drawn
function NT.drawn_turn(e)
	local pv = P.preview[e.id]
	if pv then
		return pv.q or magic.Quaternion(0, pv[4], 0)
	end
	return magic.Quaternion(e.pitch or 0, e.yaw or 0, e.roll or 0)
end

-- A drag's preview of an entity: moved by d, turned by turn about mid (a
-- Vector3; its own position without one), as the server's move_group
-- ([KIT_GROUP_TURN_JUMP]: its place on the 1/16 grid; [KIT_NESTING] what
-- is under it with it, turned round the same middle). h: the handle turning
-- (knobs() of editor_input.lua), its axis in the world and which angle; none:
-- round y
local function preview(e, d, turn, mid, h)
	local c = center(e)
	local q
	if h then
		local half, a = math.rad(turn) / 2, h.axis
		local sn = math.sin(half)
		q = magic.Quaternion(math.cos(half), a.x * sn, a.y * sn, a.z * sn)
	else
		q = magic.Quaternion(0, turn, 0)
	end
	local which = h and h.which or 1
	local function row_q(x)
		return q * magic.Quaternion(x.pitch or 0, x.yaw or 0, x.roll or 0)
	end
	mid = mid or c
	local p = mid + q * (c - mid)
	local function g(v)
		return math.floor(v * 16 + 0.5) / 16
	end
	local at = magic.Vector3(g(p.x + d[1]), g(p.y + d[2]), g(p.z + d[3]))
	local angles = {e.yaw or 0, e.pitch or 0, e.roll or 0}
	angles[which] = angles[which] + turn
	P.preview[e.id] = {at.x, at.y, at.z, angles[1], q = row_q(e), angles = angles}
	for _, x in ipairs(NT.under(e.id)) do
		local px = at + q * (center(x) - c)
		P.preview[x.id] = {px.x, px.y, px.z, (x.yaw or 0) + (which == 1 and turn or 0),
			q = row_q(x)}
	end
end

-- The previews let go of: shown until the server's nodes are there
local function release_preview()
	local till = buildat.get_time_us() + 2000000
	for _, pv in pairs(P.preview) do
		pv.till = pv.till or till
	end
end

local function name_of(e)
	return e and NT.entity_label(e) or "?"
end

local function sel_ids()
	local ids = {}
	for id in pairs(S.sel) do
		if find(id) then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

-- ---- The cameras ([FP] Views), made in the app's scene by kit.editor
local cam2d_node, cam2d, cam3d_node, cam3d
local function make_cameras()
	cam2d_node = O.scene:CreateChild("kit_camera_2d")
	cam2d = cam2d_node:CreateComponent("Camera")
	cam2d.orthographic = true
	cam2d.nearClip = 0.001
	cam2d.farClip = 200
	cam2d_node.rotation = magic.Quaternion(90, 0, 0)
	cam3d_node = O.scene:CreateChild("kit_camera_3d")
	cam3d = cam3d_node:CreateComponent("Camera")
	cam3d.nearClip = 0.05
	cam3d.farClip = 300
	cam3d.fov = 60
	return cam3d_node, cam3d
end

local function screen_size()
	local sc = magic.ui.scale
	return magic.ui.root.width * sc, magic.ui.root.height * sc
end

local function active_camera()
	if not E.editing or S.view == "walk" or S.view == "hud" or
			S.view == "signals" then
		return O.camera, O.camera:GetComponent("Camera")
	elseif S.view == "2d" then
		return cam2d_node, cam2d
	end
	return cam3d_node, cam3d
end

local function rot3d()
	return magic.Quaternion(S.pitch, S.yaw, 0)
end

-- The camera's ray through a point of the screen (pixels): its origin and
-- direction, Vector3s; the crosshair's the middle
function M.screen_ray(mx, my, node, cam)
	if not node then
		node, cam = active_camera()
	end
	local w, h = screen_size()
	local fx, fy = mx / w, my / h
	if M.looking() then
		fx, fy = 0.5, 0.5
	end
	local d, r, u
	if node == cam3d_node then
		local q = rot3d()
		d, r, u = q * magic.Vector3(0, 0, 1), q * magic.Vector3(1, 0, 0),
				q * magic.Vector3(0, 1, 0)
	else
		d = node.worldDirection
		local rx, rz = d.z, -d.x
		local rl = math.sqrt(rx * rx + rz * rz)
		if rl < 1e-6 then
			rx, rz, rl = 1, 0, 1
		end
		r = magic.Vector3(rx / rl, 0, rz / rl)
		u = magic.Vector3(d.y * r.z, d.z * r.x - d.x * r.z, -d.y * r.x)
	end
	local o = node.worldPosition
	local aspect = w / math.max(1, h)
	if cam.orthographic then
		local hh = cam.orthoSize / 2
		return o + r * ((2 * fx - 1) * hh * aspect) + u * ((1 - 2 * fy) * hh), d
	end
	local t = math.tan(math.rad(cam.fov / 2))
	local a, b = (2 * fx - 1) * t * aspect, (1 - 2 * fy) * t
	return o, (d + r * a + u * b):Normalized()
end

-- A point of the world on the screen, in pixels (nil behind the camera)
local function to_screen(p)
	local node, cam = active_camera()
	local d = node == cam3d_node and rot3d() * magic.Vector3(0, 0, 1) or
			node.worldDirection
	local o = node.worldPosition
	if not cam.orthographic and (p.x - o.x) * d.x + (p.y - o.y) * d.y +
			(p.z - o.z) * d.z <= 0.01 then
		return nil
	end
	local s = cam:WorldToScreenPoint(p)
	local w, h = screen_size()
	return s.x * w, s.y * h
end

local function round(x)
	return math.floor(x + 0.5)
end

-- The ground cell (y = ground_y, standing on the plane half a cell below)
-- the ray meets
local function ground_at(o, v)
	local t = math.abs(v.y) > 1e-6 and (O.ground_y - 0.5 - o.y) / v.y or -1
	if t <= 0 or t > 500 then
		return nil
	end
	return {round(o.x + v.x * t), O.ground_y, round(o.z + v.z * t)}
end

-- Where the ray meets the level plane at y
local function plane_at(o, v, y)
	local t = math.abs(v.y) > 1e-6 and (y - o.y) / v.y or -1
	if t <= 0 or t > 300 then
		return nil
	end
	return o + v * t
end

-- Whether voxels are what is being worked on ([KIT_SELECT_BURIED], user):
-- the voxels and terrain tools, a palette item armed or dragged, an entity
-- dragged (where it lands)
local function voxel_work()
	local d = S.drag and S.drag.kind
	return S.tool == "voxels" or S.tool == "terrain" or S.tool == "box" or
			S.placing ~= nil or
			d == "palette" or d == "move" or d == "turn"
end

-- What the pointer is on: an entity (the nearest along the ray: its look,
-- or a box round its cell), else a voxel (and the cell before its face),
-- else the ground. {id, t} or {cell, front, t} or {ground} or nil.
-- Voxels hide an entity behind them only in voxel_work() or with nearest
-- (the camera's pivot): otherwise (select, the menu, a link, the hover) an
-- entity anywhere along the ray wins, so one under the ground is clicked
local function pick(mx, my, skip, nearest)
	local o, v = M.screen_ray(mx, my)
	local id, et = nil, nil
	local oo, dd = {o.x, o.y, o.z}, {v.x, v.y, v.z}
	-- A box round a point, as drawn in edit mode: its whole cell (a voxel
	-- in it, such as one the entity owns, is the entity)
	local function cell_t(p)
		local c = {p.x, p.y, p.z}
		local t0, t1 = 0, math.huge
		for i = 1, 3 do
			local lo, hi = c[i] - 0.5, c[i] + 0.5
			if math.abs(dd[i]) < 1e-9 then
				if oo[i] < lo or oo[i] > hi then
					return nil
				end
			else
				local a, b = (lo - oo[i]) / dd[i], (hi - oo[i]) / dd[i]
				if a > b then a, b = b, a end
				t0, t1 = math.max(t0, a), math.min(t1, b)
			end
		end
		return t0 <= t1 and t0 or nil
	end
	local all = entities()
	for _, e in ipairs(made()) do
		if e.kind ~= "player" then
			all[#all + 1] = e
		end
	end
	local free_id, ft_at
	for _, e in ipairs(all) do
		if e.pos and not (skip and skip[e.id]) then
			local n = P.nodes[e.id]
			-- Its look as drawn, else its cell (its node's, or its row's
			-- before the node has come)
			local t
			-- (the plan: its cell, the box drawn round it there)
			if n and K.look_frame(n) and not P.preview[e.id] and
					S.view ~= "2d" then
				t = K.entity_t(n, o, v)
			else
				t = cell_t(drawn_at(e))
			end
			if t and (not et or t < et) then
				id, et = e.id, t
			end
			local ft = NT.pf.pick_t(e, oo, dd)
			if ft and (not ft_at or ft < ft_at) then
				free_id, ft_at = e.id, ft
			end
		end
	end
	-- [KIT_FREE_PREFAB] A free copy's box: not over what is in it, its members
	if free_id and free_id ~= id and (not id or ft_at < et) then
		local got = find(id)
		if not (got and type(got.built) == "table" and got.built.by == free_id) then
			id, et = free_id, ft_at
		end
	end
	local hit, front, vt
	if O.solid then
		hit, front, vt = M.voxel_ray({o.x, o.y, o.z}, {v.x, v.y, v.z}, O.solid,
				MAX_RAY)
	end
	if id and (not hit or et <= vt + 0.05 or not (nearest or voxel_work())) then
		return {id = id, t = et}
	end
	if hit then
		return {cell = hit, front = front, t = vt}
	end
	local g = ground_at(o, v)
	return g and {ground = g} or nil
end

-- Where a placement goes: the cell before the pointed voxel's face, or the
-- ground's (entities left out)
local function place_cell(mx, my)
	local o, v = M.screen_ray(mx, my)
	if O.solid then
		local solid = M.with_terrain(O.solid)
		local hit, front, t = M.voxel_ray({o.x, o.y, o.z}, {v.x, v.y, v.z},
				solid, MAX_RAY)
		if hit then
			return M.place_front(hit, front, {o.x, o.y, o.z}, {v.x, v.y, v.z},
					t, solid)
		end
	end
	return ground_at(o, v)
end

-- ---- The panels: floorplanner's -- a slim bar at the top, the palette at
-- the left and the inspector at the right under it, folded away on a
-- narrow screen ([FP_TOUCH] 2) and opened from the bar, one at a time
local W = {} -- the windows: bar, palette, inspector, people, log, ctx, dialog, touch
-- The screen's own size in UI units is the root's smallest at the
-- screen's pixels: the client's fit only shrinks the UI, and its root
-- under the open palette (470 tall in a phone's 400) read as no longer
-- narrow, the fold buttons gone ([KIT_NARROW_RESCALE]).
-- simplified: a UI scale turned down keeps the smaller root until the
-- screen's size changes; the client giving Lua its scale before the fit
-- is the upgrade
local screen_ui = {}
local function narrow()
	local r, g, u = magic.ui.root, magic.graphics, screen_ui
	if u.gw ~= g.width or u.gh ~= g.height then
		u.gw, u.gh, u.w, u.h = g.width, g.height, r.width, r.height
	end
	u.w, u.h = math.min(u.w, r.width), math.min(u.h, r.height)
	return u.w < 700 or u.h < 500
end

local function folded(key)
	if not narrow() then
		return false
	end
	if S.folds[key] == nil then
		S.folds[key] = true
	end
	return S.folds[key]
end

local function toggle_fold(key)
	local opening = folded(key)
	S.folds[key] = not opening
	if opening then
		for k in pairs(S.folds) do
			if k ~= key then
				S.folds[k] = true
			end
		end
	end
end

local function window(halign, valign, x, y, horizontal)
	local w = magic.ui.root:CreateChild("Window")
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = STYLE
	end
	w:SetStyleAuto()
	w:SetLayout(horizontal and magic.LM_HORIZONTAL or magic.LM_VERTICAL, 4,
			magic.IntRect(6, 6, 6, 6))
	w:SetAlignment(halign, valign)
	w:SetPosition(x, y)
	w.opacity = 0.92
	-- [KIT_HUD_VIEW] No panels there; one rebuilt there stays out of the way
	-- ([KIT_PARAM_CATEGORIES] but for NT.hud_panel's)
	w.visible = S.view ~= "hud"
	-- Under the menus (the pause menu over a wide inspector)
	w.priority = -1
	w.bringToFront = false
	return w
end

local function drop(key)
	if W[key] then
		W[key]:Remove()
		W[key] = nil
	end
end

local function inside(w, x, y)
	local p, s = w.screenPosition, w.size
	return x >= p.x and y >= p.y and x < p.x + s.x and y < p.y + s.y
end

-- Whether the pointer (pixels) is on a panel, a menu or a dialog: not the
-- view's
local function over_ui(mx, my)
	local sc = magic.ui.scale
	local x, y = mx / sc, my / sc
	for _, w in pairs(W) do
		if w.visible and inside(w, x, y) then
			return true
		end
	end
	return ui_utils.dropdown_open() or ui_utils.clicks_wanted() or
			(E.menu ~= nil and E.menu.held()) or (M.ui_at ~= nil and M.ui_at(mx, my))
end

M.over_ui = over_ui

local refresh, show_log, rebuild_bar, set_view, terrain_panel, walk_here
local inspector_window
local voxel_names

-- [KIT] stage 4f: the terrain tool's state: the brush, its size (cells)
-- and strength, the biome (nil: the World's), the stroke being drawn
-- (its id, the last dab and when, a fill's corner, the level)
local T = {brush = "raise", size = 3, strength = 2, biome = nil,
	stroke = nil}
-- [KIT_HEIGHTMAP_REGEN_LOSS] reset: a heightmap's samples back to the
-- generator's, no longer edited
-- [KIT_AIRSHIPS_2] seed: a ball of the biome's ground on the voxel pointed
-- at, or in the air in front (an island's start)
local BRUSHES = {"raise", "lower", "smooth", "flatten", "paint", "fill",
	"decorate", "reset", "seed"}
local BRUSH_NAMES = {raise = "Raise", lower = "Lower", smooth = "Smooth",
	flatten = "Flatten", paint = "Paint", fill = "Fill", decorate = "Decorate",
	reset = "Reset", seed = "Seed"}
local MAX_BRUSH = 12
M.T = T
-- [KIT_VOXEL_EDITS] The edited sections ("kit:edited": list), the
-- terrain tab's rows of them ({el, s}), and the section hovered
local ED = {list = nil, rows = {}, hover = nil}

-- The bar: Edit and Run/End in play (an app's own menu can have them:
-- bar = false); in the tools floorplanner's toolbar -- Menu, the views,
-- the grid, the angle step, the cut, Undo, Run/End, Play mode, on a
-- narrow screen the panels' toggles, and Save as start (Running) last:
-- Run and End one place, one width, so nothing moves as they swap
-- The bar's buttons in rows, as many as the screen's width needs
-- ([FP_TOUCH] 2, floorplanner's build_toolbar): place(make) puts what
-- make(parent) makes in the row it fits in
local bar_row, bar_used, bar_room, bar_first
-- The bar's buttons {label, element}, their places logged once laid out
-- (as they change)
local bar_items, bar_log, bar_logged = {}, false, nil
local function place(make)
	-- Measured before it is put in a row (floorplanner's probe)
	local probe = make(magic.ui.root)
	local wd = probe.minWidth + 4
	probe:Remove()
	-- The first row clear of the server button at the top right
	-- (builtin/accounts')
	if bar_used > 0 and bar_used + wd > bar_room - (bar_first and 110 or 0) then
		bar_row, bar_used, bar_first = row(W.bar), 0, false
	end
	local e = make(bar_row)
	e.maxWidth = e.minWidth
	bar_used = bar_used + wd
	return e
end

local function bar_button(s, key, fn, down)
	if key and not S.touch then
		s = s .. " (" .. key .. ")"
	end
	local e = place(function(parent) return button(parent, s, fn, down) end)
	bar_items[#bar_items + 1] = {s, e}
	return e
end

-- Run while Ended, End while Running, as wide as the wider of them
local function run_end(parent)
	local wd = 0
	for _, s in ipairs({"Run", "End"}) do
		local p = button(magic.ui.root, s, function() end)
		wd = math.max(wd, p.minWidth)
		p:Remove()
	end
	local b = button(parent, E.running and "End" or "Run", function()
		if E.running then M.stop() else M.play() end
	end)
	b.minWidth = wd
	return b
end

local function grid_text()
	local g = GRID_STEPS[S.grid]
	return g >= 1 and tostring(g) or g == 0.5 and "1/2" or g == 0.25 and "1/4" or
			"1/16"
end

local function angle_text()
	local a = ANGLE_STEPS[S.angle]
	return a and a .. " deg" or "free"
end

-- [KIT_EDIT_MODE_FPS] What the bar shows, all of it: built again (8-17 ms)
-- only as it changes, by refresh()
local function bar_key()
	local st = E.state or {}
	local ses = E.session or {}
	local keys = {}
	for _, v in ipairs({"2d", "3d", "walk", "hud", "signals"}) do
		keys[#keys + 1] = tostring(M.key_name(VIEW_KEYS[v]))
	end
	return table.concat({tostring(E.can_edit), tostring(E.editing), tostring(O.bar),
		tostring(ses.kind), tostring(ses.prefab), tostring(ses.can), tostring(E.persistent),
		tostring(E.running), tostring(magic.ui.root.width), tostring(S.touch), S.view,
		table.concat(st.scenes or {}, "\1"), tostring(st.can_make_scenes),
		tostring(current_scene()), grid_text(), angle_text(), tostring(S.tool),
		tostring(st.clipboard ~= nil), tostring(NT.sig() and NT.sg.bar_key()),
		tostring(narrow()), tostring(folded("palette")), tostring(folded("inspector")),
		table.concat(keys, " "), tostring(M.key_name("copy")),
		tostring(M.key_name("paste"))}, "\0")
end

rebuild_bar = function(if_changed)
	local key = bar_key()
	if if_changed and key == S.bar_key and (W.bar or not E.can_edit) then
		return false
	end
	S.bar_key = key
	drop("bar")
	bar_items, bar_log = {}, false
	if not E.can_edit or (not E.editing and O.bar == false) then
		return
	end
	-- The tools' at the top left, as floorplanner's toolbar
	local w = E.editing and window(magic.HA_LEFT, magic.VA_TOP, 8, 4, true) or
			window(magic.HA_CENTER, magic.VA_TOP, 0, 4, true)
	W.bar = w
	-- ui_utils' notices go under it
	w:SetName("kit: bar")
	-- [KIT_SESSIONS_1] the round's: the default's only
	local kind = (E.session or {}).kind or "default"
	local rounds = not E.persistent and kind == "default"
	if not E.editing then
		button(w, "Edit", M.toggle_tools)
		if rounds then
			run_end(w)
		end
		return
	end
	w:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(6, 6, 6, 6))
	bar_row, bar_used, bar_first = row(w), 0, true
	bar_room = magic.ui.root.width - 16 - 12
	S.bar_root_w = magic.ui.root.width
	if O.menu then
		bar_button("Menu", "Esc", function()
			O.menu()
		end)
	end
	local views = {}
	for _, v in ipairs({"2d", "3d", "walk", "hud", "signals"}) do
		views[#views + 1] = {VIEW_NAMES[v] .. (S.touch and "" or
				" (" .. M.key_name(VIEW_KEYS[v]) .. ")"), v}
	end
	-- [KIT_WALK_HERE] last: the walker put where this view's camera is
	views[#views + 1] = {"Walk here", "\0walk_here"}
	-- Not measured on the side (a dropdown made is kept by ui_utils): the
	-- second thing in the first row
	local d
	d = ui_utils.dropdown(bar_row, views, S.view, function(v)
		if v ~= "\0walk_here" then
			set_view(v)
		elseif not walk_here() then
			ui_utils.dropdown_set(d, S.view)
		end
	end, {height = 24})
	bar_used = bar_used + math.max(d.minWidth, 90) + 4
	-- [KIT_SCENES] the scene edited, switched by the list; New scene...
	local scenes = E.state and E.state.scenes or {}
	-- [KIT_PREFAB_BENCH] a prefab's temporary scene: its name and its two buttons
	-- in the scene list's place
	if kind == "bench" then
		place(function(parent)
			return label(parent, "Editing prefab " .. tostring(E.session.prefab) ..
					":")
		end)
		bar_button("Save", nil, NT.pf.bench_save)
		bar_button("Close", nil, NT.pf.bench_close)
	elseif #scenes > 1 or (E.state and E.state.can_make_scenes) then
		local choices = {}
		for _, n in ipairs(scenes) do
			choices[#choices + 1] = {"Scene: " .. n, n}
		end
		if E.state.can_make_scenes then
			choices[#choices + 1] = {"New scene...", "\0new"}
		end
		-- (in the first row as the view's: a dropdown is not probed)
		local sd = ui_utils.dropdown(bar_row, choices, current_scene(),
				function(v)
			if v == "\0new" then
				M.scene_dialog()
			elseif v ~= current_scene() then
				M.switch_scene(v)
			end
		end, {height = 24})
		bar_used = bar_used + math.max(sd.minWidth, 120) + 4
	end
	bar_button("Grid " .. grid_text(), "G", function()
		M.next_grid()
	end)
	bar_button("Angle " .. angle_text(), "H", function()
		M.next_angle()
	end)
	if S.view == "2d" then
		bar_button("Cut -", nil, function()
			S.cut = S.cut - 1
			log:info("kit editor: cut at " .. S.cut)
		end)
		bar_button("Cut +", nil, function()
			S.cut = S.cut + 1
			log:info("kit editor: cut at " .. S.cut)
		end)
	end
	bar_button("Undo", nil, function()
		send({op = "undo"})
	end)
	-- [KIT_PREFAB_VOXELS] the Box tool's: the box (and the selection)
	-- copied or a prefab, the copy pasted
	if S.tool == "box" then
		bar_button("Copy", "Ctrl+" .. M.key_name("copy"), M.copy)
		bar_button("Make prefab...", nil, function()
			M.prefab_dialog(sel_ids())
		end)
	end
	if E.state and E.state.clipboard then
		bar_button("Paste", "Ctrl+" .. M.key_name("paste"), M.paste)
	end
	if rounds then
		bar_items[#bar_items + 1] = {E.running and "End" or "Run", place(run_end)}
	end
	-- [KIT_SESSIONS_1] a private draft of the start: made, published, left
	if kind == "draft" then
		bar_button("Publish", nil, function()
			NT.publish_checked("this draft", function()
				send({op = "publish"})
			end)
		end)
		bar_button("Leave draft", nil, function()
			send({op = "leave_draft"})
		end)
	elseif kind == "default" and (E.session or {}).can then
		bar_button("Draft", nil, function()
			send({op = "draft"})
		end)
	end
	if kind ~= "bench" then
		bar_button("Play mode", nil, M.toggle_tools)
	end
	if NT.sig() then
		NT.sg.bar(bar_button)
	elseif narrow() then
		for _, p in ipairs({{"palette", "Tools"}, {"inspector", "Inspector"}}) do
			bar_button(p[2], nil, function()
				toggle_fold(p[1])
				refresh()
			end, not folded(p[1]))
		end
	end
	if E.running and rounds then
		bar_button("Save as start", nil, M.save_as_start)
	end
	bar_log = true
end

-- The bar's buttons' places, once laid out (a check compares them)
local function log_bar()
	if not bar_log or not W.bar then
		return
	end
	bar_log = false
	local t = {}
	for _, it in ipairs(bar_items) do
		local p = it[2].screenPosition
		t[#t + 1] = string.format("%s %d,%d", it[1], p.x, p.y)
	end
	local s = table.concat(t, "; ")
	if s ~= bar_logged then
		bar_logged = s
		log:info("kit editor: bar: " .. s)
		-- [KIT_BAR_SERVER_OVERLAP] the first row's right end and the
		-- server button's left (builtin/accounts'), for a check
		local y0, x1 = t[1] and bar_items[1][2].screenPosition.y, 0
		for _, it in ipairs(bar_items) do
			local p = it[2].screenPosition
			if p.y == y0 then
				x1 = math.max(x1, p.x + it[2].width)
			end
		end
		local root = magic.ui.root
		for i = 0, root:GetNumChildren() - 1 do
			-- nil for the client's own hidden UI
			local c = root:GetChild(i)
			local t = c and c:GetTypeName() == "Button" and c.visible and
					c:GetNumChildren() > 0 and c:GetChild(0)
			if t and t:GetTypeName() == "Text" and t.text == "Server" then
				log:info(string.format("kit editor: bar's first row ends at "
						.. "%d, the Server button from %d", x1,
						c.screenPosition.x))
			end
		end
	end
end

function M.next_grid()
	S.grid = S.grid % #GRID_STEPS + 1
	log:info("kit editor: grid " .. grid_text())
	rebuild_bar()
end

function M.next_angle()
	S.angle = S.angle % #ANGLE_STEPS + 1
	log:info("kit editor: angle step " .. angle_text())
	rebuild_bar()
end

-- The palette: the types and the prefabs, a click arms one (placed by the
-- clicks on the view) or, with no position, opens its menu; a drag puts one
-- where it is let go
local palette_buttons = {}
local palette

-- [KIT_EDITOR_PANELS] The left panel (user, 2026-11-03): one window,
-- its tabs the tools -- Components (the types and the prefabs to place),
-- Terrain, Voxels, Box and Entities (the list) -- each tab's body the
-- tool's options, in a view that scrolls (NT.view), bounded each frame
-- above the builders' panel or the screen's foot (NT.fit_panel). A tab
-- chosen is its tool on; a tool on (its key: T, V, B) is its tab; put away
-- (Escape, a right click) the panel goes back to Components or Entities,
-- whichever was last (S.panel_tab)
-- [KIT_TABS_TWO_ROWS] in two rows, the panel as narrow as its content
NT.TABS = {{"Components", "Terrain", "Voxels"},
	{"Box", "Entities", "Items", "Sounds"}}
NT.TOOL_TAB = {terrain = "Terrain", voxels = "Voxels", box = "Box"}
NT.TAB_KEY = {Terrain = "terrain", Voxels = "voxels", Box = "box"}
-- Where each tab's body was scrolled
NT.y = {}

function NT.tab_shown(name)
	local st = E.state or {}
	if name == "Terrain" then
		return st.terrain ~= nil
	elseif name == "Voxels" then
		return st.voxels ~= nil and (O.solid ~= nil or O.pick_voxel ~= nil)
	elseif name == "Box" then
		return O.solid ~= nil
	end
	return true
end

function NT.tab()
	local t = NT.TOOL_TAB[S.tool or ""] or S.panel_tab or "Components"
	return NT.tab_shown(t) and t or "Components"
end

function NT.choose(name)
	if name ~= NT.tab() then
		log:info("kit editor: the panel's " .. name .. " tab")
		S.placing = nil
	end
	if name == "Terrain" then
		return M.set_tool("terrain")
	elseif name == "Box" then
		return M.set_tool("box")
	elseif name == "Voxels" and O.solid then
		if S.tool ~= "voxels" then
			return M.toggle_voxels()
		end
		return palette()
	end
	-- (Voxels without the app's voxels: the voxel in hand for its placing)
	S.panel_tab = name
	if S.tool then
		return M.set_tool(nil)
	end
	refresh()
end

-- The Voxels tab: the voxel in hand (the app's, O.pick_voxel), its shape
-- and tint, and a builder's own voxel type
function NT.voxels(w)
	if O.pick_voxel or O.solid then
		local names = {{"none", ""}}
		for _, n in ipairs(voxel_names()) do
			names[#names + 1] = n
		end
		ui_utils.dropdown(row(w), names, S.voxel or "", function(name)
			M.pick_voxel(name ~= "" and name or nil)
		end, {label = "Voxel", fill = true})
		-- [KIT_VOXEL_FORMAT] its shape (a solid cube's; the facing
		-- from the view as it is placed) and tint
		local entry = nil
		for _, v in ipairs(E.state.voxels or {}) do
			if v.name == S.voxel then
				entry = v
			end
		end
		if entry and entry.shapes then
			local shapes = {{"cube", ""}}
			for _, sh in ipairs(M.SHAPES) do
				shapes[#shapes + 1] = {sh:gsub("_", " "), sh}
			end
			ui_utils.dropdown(row(w), shapes, M.hand.shape, function(sh)
				M.hand.shape = sh
				log:info("kit editor: shape " .. (sh ~= "" and sh or "cube"))
				if S.voxel and O.pick_voxel then
					O.pick_voxel(S.voxel)
				end
			end, {label = "Shape", fill = true})
		end
		if entry then
			-- [KIT_TINT_PALETTE] its palette's entries, by name
			local tints = M.tints_of(S.voxel)
			if M.hand.tint >= #tints then
				M.hand.tint = 0
			end
			ui_utils.dropdown(row(w), tints, M.hand.tint, function(t)
				M.hand.tint = tonumber(t) or 0
				log:info("kit editor: tint " .. M.tint_label(S.voxel,
						M.hand.tint))
			end, {label = "Tint", fill = true})
		end
	end
	button(w, "New voxel type...", function()
		M.voxel_dialog()
	end)
	if O.solid then
		text(w, S.touch and "Walking: a tap digs, a finger held places" or
				"Left: place, Shift+left: dig; walking: left digs, right places",
				DIM)
	end
end

-- [KIT_ITEMS_TAB] The Items tab: Kit's item types, the project's own
-- and its packages', grouped by their use -- Tools (a dig speed, or the
-- use kind "use"), Weapons (melee, ranged), Ammo (another's ammo), Other
-- -- and searched by name. A row's name selects it (its sheet in the
-- inspector, IT.sheet) or, dragged into the world, places a kit/pickup
-- of it; Copy as new (a type of the builder's own from it, the next free
-- "<name>_<n>"), Give to me (in play: one, into the slots as a dig's
-- drop) and Delete (the project's own). "New item type..." at its top: a
-- new sheet in the inspector. IT.choices() is the same list for every
-- field that names an item
local IT = {GROUPS = {"Tools", "Weapons", "Ammo", "Other"}, sel = nil}
NT.IT = IT

-- The item types by name, the project's own first
function IT.names()
	local out = {}
	for n in pairs(M.item_types or {}) do
		out[#out + 1] = n
	end
	table.sort(out, function(a, b)
		local oa, ob = IT.own(a), IT.own(b)
		if oa ~= ob then
			return oa
		end
		return a < b
	end)
	return out
end

-- The project's own (a builder's; not Kit's nor a package's)
function IT.own(n)
	local s = M.item_types[n]
	return type(s) == "table" and s.author ~= nil and s.package == nil
end

function IT.group(n, ammo)
	local s = M.item_types[n] or {}
	if ammo[n] then
		return "Ammo"
	elseif (type(s.dig) == "table" and next(s.dig)) or s.use == "use" then
		return "Tools"
	elseif s.use == "melee" or s.use == "ranged" then
		return "Weapons"
	end
	return "Other"
end

-- A picker's choices ({label, value}): none (""), the item types, then
-- the voxels (a dig's drops, placed from the hands); the value too when
-- it is none of them
function IT.choices(value)
	local out, has = {{"none", ""}}, value == nil or value == ""
	for _, n in ipairs(IT.names()) do
		out[#out + 1] = {M.shown(n), n}
		has = has or n == value
	end
	for _, n in ipairs(voxel_names()) do
		out[#out + 1] = {n, n}
		has = has or n == value
	end
	if not has and type(value) == "string" then
		out[#out + 1] = {value, value}
	end
	return out
end

-- The builder's own author name (kit.cpp's builder_author)
function IT.me()
	return (tostring(P.my_name or ""):sub(1, 64):gsub("%W", "_"))
end

-- A copy of n as the builder's own, the sheet's fields f over it
function IT.copy(n, f)
	local base = n:match("[^/]*$")
	local cand, i = base, 1
	while M.item_types[IT.me() .. "/" .. cand] do
		i = i + 1
		cand = base .. "_" .. i
	end
	local j = {}
	for k, v in pairs(f or {}) do
		j[k] = v
	end
	j.format, j.author, j.version, j.look_data, j.package = nil, nil, nil,
			nil, nil
	j.op, j.name, j.preset = "item", cand, n
	send(j)
	IT.sel, IT.form = IT.me() .. "/" .. cand, nil
	log:info("kit editor: item " .. n .. " copied as " .. IT.sel)
end

-- The rows shown by the search (and their groups' headings)
function IT.filter()
	local q, seen, n = (IT.search or ""):lower(), {}, 0
	for _, r in ipairs(IT.rows or {}) do
		local on = q == "" or r.label:lower():find(q, 1, true) ~= nil
		r.row.visible = on
		seen[r.group] = seen[r.group] or on
		n = n + (on and 1 or 0)
	end
	for g, h in pairs(IT.heads or {}) do
		h.visible = seen[g] == true
	end
	-- (a layout only grows: the body shrunk to what it shows, the panel
	-- after it, NT.fit_panel)
	if NT.view and NT.view.contentElement then
		NT.view.contentElement.height = 0
	end
	if q ~= (IT.searched or "") then
		IT.searched = q
		log:info("kit editor: items for \"" .. q .. "\": " .. n)
	end
end

function NT.items(w)
	button(w, "New item type...", function()
		IT.sel, IT.form = "", nil
		log:info("kit editor: a new item type")
		refresh()
	end)
	local sr = row(w)
	label(sr, "Search", 60)
	edit(sr, IT.search or "", function(s)
		IT.search = s
		IT.filter()
	end):SetName("item search")
	local ammo, groups = {}, {}
	for _, sh in pairs(M.item_types or {}) do
		if type(sh.ammo) == "string" and sh.ammo ~= "" then
			ammo[sh.ammo] = true
		end
	end
	for _, n in ipairs(IT.names()) do
		local g = IT.group(n, ammo)
		groups[g] = groups[g] or {}
		table.insert(groups[g], n)
	end
	IT.rows, IT.heads = {}, {}
	local said = {}
	for _, g in ipairs(IT.GROUPS) do
		if groups[g] then
			IT.heads[g] = text(w, g, magic.Color(1.0, 0.85, 0.3))
		end
		for _, n in ipairs(groups[g] or {}) do
			local r = row(w)
			local b = button(r, M.shown(n), function()
				-- (a drag into the world was not a click)
				if S.palette_dragged then
					S.palette_dragged = nil
					return
				end
				IT.sel, IT.form = n, nil
				log:info("kit editor: item " .. n .. " selected")
				refresh()
			end, IT.sel == n)
			b:SetName("item " .. n)
			palette_buttons[#palette_buttons + 1] = {button = b,
				item = {label = M.shown(n), pickup = n}}
			button(r, "Copy as new", function()
				IT.copy(n)
			end):SetName("copy " .. n)
			if E.running then
				button(r, "Give to me", function()
					send({op = "give", item = n})
					log:info("kit editor: give me " .. n)
				end):SetName("give " .. n)
			end
			if IT.own(n) then
				button(r, "Delete", function()
					send({op = "item_delete", name = n})
					if IT.sel == n then
						IT.sel = nil
					end
					log:info("kit editor: item " .. n .. " deleted")
				end):SetName("delete " .. n)
			end
			IT.rows[#IT.rows + 1] = {row = r, label = M.shown(n), group = g}
			said[#said + 1] = g .. " " .. n
		end
	end
	if #IT.rows == 0 then
		text(w, "No item types", DIM)
	end
	text(w, "Drag one into the world: a pickup of it", DIM)
	IT.filter()
	-- For a check: the list as it changes
	local line = "kit editor: items (" .. #said .. "): " ..
			table.concat(said, ", ")
	if line ~= IT.said then
		IT.said = line
		log:info(line)
	end
end

function M.items_changed()
	if E.editing and NT.tab() == "Items" then
		palette()
		inspector_window()
	end
end

-- The Entities tab: the entities, to select ([KIT_SELECT_BURIED]: one
-- under the ground too), in three tabs ([KIT_LIST_TABS], user): Game-wide
-- (the root's, no position), Scene (the scene's with no position: its
-- World, an environment) and Positioned (the scene's, or the root's,
-- placed), each in the order they were added; the tab kept for the
-- session. [KIT_NESTING] Positioned in the tree's order, each one under
-- its parent indented, [KIT_PANEL_PARENT] and a panel's elements under it
-- ([KIT_REPARENT_BUTTONS]: a Select with Switch parent armed picks the
-- parent)
-- The Entities tab's lists, and how deep in the tree each one is
function NT.entity_lists()
	local tabs = {["Game-wide"] = {}, Scene = {}, Positioned = {}}
	local indent = {}
	local function add_tree(t, e, d)
		table.insert(tabs[t], e)
		indent[e.id] = d
		for _, c in ipairs(NT.tree().kids[e.id] or {}) do
			if d < 16 then
				add_tree(t, c, d + 1)
			end
		end
	end
	for _, e in ipairs(entities()) do
		if e.kind ~= "scene" then
			local t = e.pos and "Positioned" or scene_name(e) and "Scene" or
					"Game-wide"
			if not NT.parent_of(e) then
				add_tree(t, e, 0)
			end
		end
	end
	return tabs, indent
end

function NT.entities(w)
	local tabs, indent = NT.entity_lists()
	local tab = S.list_tab or "Game-wide"
	local tr = row(w)
	for _, name in ipairs({"Game-wide", "Scene", "Positioned"}) do
		button(tr, name .. " (" .. #tabs[name] .. ")", function()
			S.list_tab = name
			palette()
		end, name == tab)
	end
	local n, ids = 0, {}
	for _, e in ipairs(tabs[tab]) do
		local gr = row(w)
		label(gr, string.rep("    ", indent[e.id] or 0) .. NT.entity_label(e) ..
				(e.pos and " at " ..
				table.concat(e.pos, ",") or ""))
		local sb = button(gr, e.id == S.primary and "Selected" or
				S.reparent and (e.pos or NT.is_panel(e)) and "Parent" or "Select",
				function()
			if not NT.pick_parent(e.id) then
				M.select(e.id)
			end
		end)
		-- For a driven click by whose it is
		sb:SetName("select " .. e.id)
		n = n + 1
		ids[#ids + 1] = (indent[e.id] or 0) > 0 and
				string.rep(">", indent[e.id]) .. e.id or e.id
	end
	if n == 0 then
		text(w, "None", DIM)
	end
	-- For a check: the tab and what it lists, as it changes
	local said = "kit editor: list " .. tab .. " (" .. n .. "): " ..
			table.concat(ids, ", ")
	if said ~= NT.list_said then
		NT.list_said = said
		log:info(said)
	end
end

-- The panel's body, each frame: as tall as it is, or the room there is
-- (a scroll bar then), and as wide, or the screen's (a bar across)
function NT.fit_panel()
	local w, view = W.palette, NT.view
	if not w or not view then
		return
	end
	local body = view.contentElement
	local foot = W.touch and W.touch.visible and W.touch.height + 16 or 12
	-- The screen's size at the unfitted scale (as fit_inspector's)
	narrow()
	local bottom = screen_ui.h - foot
	if W.people and W.people.visible then
		bottom = math.min(bottom, W.people.screenPosition.y - 8)
	end
	local sb = view.verticalScrollBar.width + 4
	-- The body as the view shows it: inside its panel's clip border
	-- (DefaultStyle's 2 a side)
	local bw, bh = body.width + 4, body.height + 4
	local room_w = math.min(screen_ui.w, magic.ui.root.width) - 16 - 12 - 8
	local hbar = bw > room_w
	-- [KIT_PALETTE_FOOT] What the window has under the view: its border,
	-- the palette's foot
	local under = w.height - view.position.y - view.height
	local room_h = bottom - view.screenPosition.y - under - 2 -
			(hbar and view.horizontalScrollBar.height + 4 or 0)
	local h = math.max(40, math.min(bh, room_h))
	local vbar = h < bh
	local vw = math.min(bw + (vbar and sb or 0), room_w)
	local vh = h + (hbar and view.horizontalScrollBar.height + 4 or 0)
	if view.height ~= vh or view.width ~= vw then
		view:SetScrollBarsVisible(hbar, vbar)
		view:SetFixedSize(vw, vh)
		-- A layout only grows the window (and stretches its rows to
		-- fill it): shrunk to what it holds
		w.width, w.height = 0, 0
		log:info(string.format("kit editor: the panel %d of %d tall, %d of " ..
				"%d wide, its window down to %d of %d", h, bh, vw, bw,
				w.screenPosition.y + w.height, bottom))
	end
end

-- [KIT] stage 5: the New tab, Kit packages from the Aittas in the
-- settings: each with Install (Upgrade where an older version is
-- installed here), which fetches it with what it needs and sends each to
-- the server; and Publish..., the builder's own prefabs and voxel types
-- written into a package for the publish screen (native)
function M.fetch_packages()
	E.packages_status = "Asking the Aittas..."
	aitta.kit_packages(function(list)
		E.packages = list
		E.packages_status = #list == 0 and "No Kit packages on the Aittas " ..
				"in the settings" or nil
		log:info("kit editor: " .. #list .. " packages listed")
		for _, p in ipairs(list) do
			log:info("kit editor: package " .. tostring(p.label or p.key) ..
					" " .. p.version)
		end
		if S.tab == "New" then
			palette()
		end
	end)
end

-- [AITTA_KEY_IDENTITY] A package's thing ("<fp>/<n>") as people read it:
-- its author's name, and its Aitta's host where that is ambiguous or
-- unverified (the server's word)
local function shown(n)
	local names = E.state and type(E.state.names) == "table" and
			E.state.names or {}
	return names[n] or n
end
M.shown = shown

local function install(key, label)
	E.status = "Fetching " .. (label or key) .. "..."
	log:info("kit editor: fetching " .. key)
	people()
	aitta.kit_fetch(key, function(list, why)
		if not list then
			E.status = "Not installed: " .. tostring(why)
			log:info("kit editor: " .. E.status)
			return people()
		end
		for _, p in ipairs(list) do
			log:info("kit editor: sending " .. p.key .. " " .. p.version)
			-- The Aitta it came from first, which the server asks whose
			-- key it is
			buildat.send_packet("kit:package", p.aitta .. "\0" .. p.data)
		end
	end)
end

local function new_tab(w)
	local have = E.state.packages or {}
	if E.packages_status then
		text(w, E.packages_status, DIM)
	end
	for i, p in ipairs(E.packages or {}) do
		if i > 12 then
			break
		end
		local r = row(w)
		local t = text(r, tostring(p.label or p.key) .. " " .. p.version)
		t.minWidth = 220
		local cur = have[p.key]
		if cur == p.version then
			text(r, "installed", DIM)
		else
			button(r, cur and "Upgrade" or "Install", function()
				install(p.key, p.label)
			end)
		end
		if p.description ~= "" then
			text(w, p.description:sub(1, 80), DIM)
		end
	end
	local r = row(w)
	label(r, "Package:")
	edit(r, E.package_name, function(s)
		E.package_name = s
	end)
	button(w, "Publish my prefabs...", function()
		NT.publish_checked("my prefabs", function()
			send({op = "export"})
		end)
	end)
end

-- The Components tab: the types and the prefabs, a click arms one (placed
-- by the clicks on the view) or, with no position, opens its menu; a drag
-- puts one where it is let go
function NT.components(w)
	-- [KIT] stage 5: its tabs at its foot (what is above them stays where
	-- it was): all, the favourites and the New tab, and the credits
	-- (a player's in the pause menu)
	-- [KIT_PALETTE_FOOT] The foot, the armed one's Favourite and the tabs,
	-- in the panel's window under the view (created after it), not in the
	-- body: the list scrolls, they stay in view (NT.fit_panel leaves them
	-- their room)
	-- simplified: the foot's rows do not wrap; a screen narrower than the
	-- tabs or a long name's Favourite runs off it (wrap as palette()'s tabs)
	local foot = W.palette
	local function tabs()
		local tr = row(foot)
		for _, tab in ipairs({"All", "Favourites", "New"}) do
			button(tr, tab, function()
				S.tab = tab
				log:info("kit editor: the palette's " .. tab .. " tab")
				if tab == "New" then
					M.fetch_packages()
				end
				palette()
			end, (S.tab or "All") == tab)
		end
		button(tr, "Credits", M.show_credits)
	end
	if S.tab == "New" then
		new_tab(w)
		return tabs()
	end
	local items = NT.palette_items(S.tab)
	if #items == 0 and S.tab == "Favourites" then
		text(w, "None yet: click one, then \"Favourite\"", DIM)
	end
	local r
	for i, it in ipairs(items) do
		if i % 2 == 1 then
			r = row(w)
		end
		local armed = S.placing ~= nil and S.placing.label == it.label
		local b
		b = button(r, it.label, function()
			-- A click: armed, or no longer (a drag was not a click)
			if S.palette_dragged then
				S.palette_dragged = nil
				return
			end
			-- [KIT_PALETTE_MENU] No click on the view to wait for: a menu
			if NT.positionless(it) then
				local p = b.screenPosition
				return NT.palette_menu(it, p.x, p.y + b.height)
			end
			-- [KIT_PREFAB_ROOT] A prefab: Place (arms), Rename, Delete
			if it.prefab then
				local p = b.screenPosition
				return NT.pf.menu(it, p.x, p.y + b.height, palette)
			end
			if armed then
				S.placing = nil
				log:info("kit editor: placing nothing")
				palette()
			else
				NT.arm(it)
			end
		end, armed)
		palette_buttons[#palette_buttons + 1] = {button = b, item = it}
	end
	-- The armed one starred or not
	if S.placing then
		local label = S.placing.label
		-- [KIT] stage 4l: the type's average cost, its instances' now
		if S.placing.type then
			text(foot, NT.cost_line(S.placing.type), DIM)
		end
		local fs, fn = NT.favourite(S.placing.key or label, label, palette)
		button(foot, fs, fn)
	end
	tabs()
end

-- What the palette lists, in a tab: {key, label, and type or prefab}
function NT.palette_items(tab)
	local fav = {}
	if tab == "Favourites" then
		for _, n in ipairs(aitta.kit_favourites()) do
			fav[n] = true
		end
	end
	local items = {}
	-- Each by its name (a favourite's), shown as people read it
	for _, t in ipairs(E.state.palette or {}) do
		if tab ~= "Favourites" or fav[t] then
			items[#items + 1] = {key = t, label = shown(t), type = t}
		end
	end
	for _, p in ipairs(E.state.prefabs or {}) do
		if tab ~= "Favourites" or fav["[" .. p .. "]"] then
			items[#items + 1] = {key = "[" .. p .. "]",
					label = "[" .. shown(p) .. "]", prefab = p}
		end
	end
	return items
end

-- [KIT_PALETTE_MENU] A type that says no_position: no click on the view
-- places it. Nor the three the root or the scene takes wherever the click
-- is: by name, as root = true is also on the controls and the movements,
-- which stay armed
NT.PLACED_AT_ONCE = {["kit/game_rules"] = true, ["kit/world"] = true,
	["kit/environment"] = true}
function NT.positionless(it)
	return it.type ~= nil and (type_of(it.type).no_position == true or
			NT.PLACED_AT_ONCE[it.type] == true)
end

function NT.arm(it, free)
	M.set_tool(nil)
	S.reparent = nil
	S.placing = {type = it.type, prefab = it.prefab, label = it.label,
			key = it.key, free = free}
	log:info("kit editor: placing " .. it.label)
	NT.palette_chosen(it)
	palette()
end

-- The type's average cost, its instances' now ([KIT] stage 4l)
function NT.cost_line(t)
	local c = E.costs and E.costs.types and E.costs.types[t]
	return c and string.format("Costs %.2f%% of Kit's budget an instance", c) or
			"Its cost: none running"
end

-- A favourite's button: its text and what it does, redraw after
function NT.favourite(name, label, redraw)
	local on = false
	for _, n in ipairs(aitta.kit_favourites()) do
		on = on or n == name
	end
	return (on and "Unfavourite " or "Favourite ") .. label, function()
		aitta.kit_favourite(name, not on)
		log:info("kit editor: " .. label .. (on and " not" or "") ..
				" a favourite")
		redraw()
	end
end

-- [KIT_PALETTE_MENU] A positionless type's menu, in UI units; what the
-- palette's foot has for an armed one is here, it is never armed
function NT.palette_menu(it, x, y)
	local fs, fn = NT.favourite(it.key, it.label, function()
		palette()
		NT.palette_menu(it, x, y)
	end)
	NT.menu({it.label, NT.cost_line(it.type), {"Place", function()
		NT.palette_chosen(it)
		NT.place_now(it)
	end}, {fs, fn}, {"Cancel", function() end}}, x, y)
	log:info("kit editor: the palette's menu of " .. it.label)
end

palette = function()
	if NT.view then
		NT.y[NT.shown or ""] = NT.view.viewPosition.y
	end
	NT.view, ED.rows, ED.hover = nil, {}, nil
	drop("palette")
	palette_buttons = {}
	if not E.editing or folded("palette") or NT.sig() then
		return
	end
	local y = W.bar and W.bar.height + 12 or 40
	local w = window(magic.HA_LEFT, magic.VA_TOP, 8, y)
	W.palette = w
	local tab = NT.tab()
	NT.shown = tab == "Entities" and "Entities/" .. (S.list_tab or "") or tab
	-- The tabs, NT.TABS's rows, each in as many as the screen's width
	-- needs (with room for the row's spacing and the scroll bar's)
	local room = math.min(screen_ui.w or 1e9, magic.ui.root.width) - 16 - 12 -
			24
	for _, names in ipairs(NT.TABS) do
		local r, used = nil, 0
		for _, name in ipairs(names) do
			if NT.tab_shown(name) then
				local key = NT.TAB_KEY[name]
				local s = name .. ((key and not S.touch) and
						" (" .. M.key_name(key) .. ")" or "")
				-- Measured on the side, as the bar's (place())
				local probe = button(magic.ui.root, s, function() end)
				local bw = probe.minWidth + 4
				probe:Remove()
				if not r or used > 0 and used + bw > room then
					r, used = row(w), 0
				end
				button(r, s, function() NT.choose(name) end, name == tab)
				used = used + bw
			end
		end
	end
	local view = w:CreateChild("ScrollView")
	local body = view:CreateChild("UIElement")
	body:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	local fill = tab == "Items" and NT.items or
			tab == "Terrain" and terrain_panel or tab == "Voxels" and
			NT.voxels or tab == "Box" and NT.box_section or
			tab == "Entities" and NT.entities or
			tab == "Sounds" and NT.sounds or NT.components
	fill(body)
	view:SetStyleAuto()
	view:SetFocusMode(magic.FM_NOTFOCUSABLE)
	view.scrollBarsAutoVisible = false
	view:SetScrollBarsVisible(false, false)
	view.contentElement = body
	body:SetPosition(0, 0)
	view:SetFixedSize(body.width, body.height)
	NT.view = view
	NT.fit_panel()
	view.viewPosition = magic.IntVector2(0, NT.y[NT.shown] or 0)
end

-- The voxels to place: the World's material set's first
-- ([KIT_MATERIAL_SETS]), then the builders' own, then by name
voxel_names = function()
	local names, own, set = {}, {}, {}
	for _, v in ipairs(E.state and E.state.voxels or {}) do
		names[#names + 1] = v.name
		own[v.name] = v.author ~= nil
		set[v.name] = v.set == true
	end
	table.sort(names, function(a, b)
		if set[a] ~= set[b] then
			return set[a]
		end
		if own[a] ~= own[b] then
			return own[a]
		end
		return a < b
	end)
	return names
end

-- [KIT_EDIT_VOXELS] The voxel in hand (nil: none): the app's
-- (O.pick_voxel) and the voxels tool's, on with one and away with none
-- Whether a material of the palette has shapes (module.lua's hand_voxel)
-- [KIT_TINT_PALETTE] A material's tints as the dropdown and the log name
-- them: {{label, index}...}, its palette's length (an index past it draws
-- as 0), its entries' names where it has them
function M.tints_of(name)
	local entry
	for _, v in ipairs(E.state and E.state.voxels or {}) do
		if v.name == name then
			entry = v
		end
	end
	local colors = entry and type(entry.tint) == "table" and entry.tint or {}
	local names = entry and type(entry.tint_names) == "table" and
			entry.tint_names or {}
	local n = math.max(1, math.min(16, #colors > 0 and #colors or 16))
	local out = {}
	for i = 0, n - 1 do
		local nm = names[i + 1]
		out[#out + 1] = {type(nm) == "string" and nm ~= "" and nm or
				(i == 0 and "default" or tostring(i)), i}
	end
	return out
end

-- "3 (very muddy)": the log's tint, its name after it when named
function M.tint_label(name, i)
	local t = M.tints_of(name)[i + 1]
	return tostring(i) .. (t and t[1] ~= tostring(i) and " (" .. t[1] .. ")"
			or "")
end

-- A check's look at a material's tints as the dropdown has them:
-- `event kit_tints <material>` logs "kit editor: tints of <material>:
-- default, dusty, ..."
magic.SubscribeToEvent("command_seq:kit_tints", function(_, data)
	local name = data:GetString("Param")
	local labels = {}
	for _, t in ipairs(M.tints_of(name)) do
		labels[#labels + 1] = t[1]
	end
	log:info("kit editor: tints of " .. name .. ": " ..
			table.concat(labels, ", "))
end)

function M.material_has_shapes(name)
	for _, v in ipairs(E.state and E.state.voxels or {}) do
		if v.name == name then
			return v.shapes == true
		end
	end
	return false
end

function M.pick_voxel(name)
	-- A material without shapes is placed as its cube
	if name ~= S.voxel and not M.material_has_shapes(name) then
		M.hand.shape = ""
	end
	S.voxel = name
	log:info("kit editor: in hand " .. tostring(name or "none"))
	if name and O.pick_voxel then
		O.pick_voxel(name)
	end
	if name and O.solid then
		M.set_tool("voxels")
	elseif S.tool == "voxels" then
		M.set_tool(nil)
	end
	palette()
end

-- V or Voxels: the tool on (with the list's first in hand if none is) or
-- away
function M.toggle_voxels()
	if S.tool == "voxels" then
		return M.set_tool(nil)
	end
	if not S.voxel then
		return M.pick_voxel(voxel_names()[1])
	end
	M.set_tool("voxels")
end

-- The palette's entry the pointer is on
local function palette_at(mx, my)
	local sc = magic.ui.scale
	-- (one scrolled out of the panel's view is not there, nor one under a menu)
	if not NT.view or not inside(NT.view, mx / sc, my / sc) or
			(W.ctx and inside(W.ctx, mx / sc, my / sc)) then
		return nil
	end
	for _, pb in ipairs(palette_buttons) do
		if inside(pb.button, mx / sc, my / sc) then
			return pb.item
		end
	end
end

local WIDGETS = {row = row, label = label, text = text, warn = WARN,
	edit = edit, dropdown = function(parent, choices, current, on_choose)
		return ui_utils.dropdown(parent, choices, current, on_choose)
	end}

-- A parameter as settings_form's field: Kit's types on the form's
local function field(name, d, values)
	local f = {name = name, label = name, default = d.default,
		min = d.min, max = d.max}
	local t = d.type
	if type(d.choices) == "table" then
		f.type = "choice"
		f.choices = {}
		for _, c in ipairs(d.choices) do
			f.choices[#f.choices + 1] = {tostring(c), c}
		end
	elseif d.choices_from == "items" then
		-- [KIT_ITEMS_TAB] an item: the Items tab's list
		f.type = "choice"
		f.choices = IT.choices(values[name])
	elseif d.choices_from == "biomes" and E.state and E.state.terrain then
		-- The material set's biomes, as the Terrain tool's (the value
		-- there too when it is none of them, the server's refusal named)
		f.type = "choice"
		f.choices = {}
		local has = false
		for _, b in ipairs(E.state.terrain.biomes or {}) do
			f.choices[#f.choices + 1] = {b, b}
			has = has or b == values[name]
		end
		if not has and type(values[name]) == "string" then
			f.choices[#f.choices + 1] = {values[name], values[name]}
		end
	elseif d.choices_from == "material_sets" and E.state and E.state.terrain then
		-- [KIT_MATERIAL_SETS] the sets a World may be made of ({label, id})
		f.type = "choice"
		f.choices = {}
		local has = false
		for _, s in ipairs(E.state.terrain.material_sets or {}) do
			f.choices[#f.choices + 1] = {s[1], s[2]}
			has = has or s[2] == values[name]
		end
		if not has and type(values[name]) == "string" then
			f.choices[#f.choices + 1] = {values[name], values[name]}
		end
	elseif d.choices_from == "scenes" then
		-- [KIT_TP_SCENE_CHOICE] The composition's scenes ("" none; the value
		-- too when it names none of them)
		f.type = "choice"
		f.choices = {{"none", ""}}
		local has = values[name] == "" or values[name] == nil
		for _, sn in ipairs(E.state and E.state.scenes or {}) do
			f.choices[#f.choices + 1] = {sn, sn}
			has = has or sn == values[name]
		end
		if not has and type(values[name]) == "string" then
			f.choices[#f.choices + 1] = {values[name], values[name]}
		end
	elseif d.choices_from == "voxels" then
		-- [KIT_LOOK_MATERIAL] The voxel materials, as the voxels tool's (the
		-- value too when it is none of them)
		f.type = "choice"
		f.choices = {{"none", ""}}
		local has = values[name] == ""
		for _, v in ipairs(voxel_names()) do
			f.choices[#f.choices + 1] = {v, v}
			has = has or v == values[name]
		end
		if not has and type(values[name]) == "string" then
			f.choices[#f.choices + 1] = {values[name], values[name]}
		end
	elseif t == "sound" then
		-- [KIT_SOUNDS] the project's sounds and "none"
		f.type = "choice"
		f.choices = M.sound_choices(values[name])
	elseif t == "prefab" then
		f.type = "choice"
		f.choices = {{"none", ""}}
		for _, p in ipairs(E.state.prefabs or {}) do
			f.choices[#f.choices + 1] = {shown(p), p}
		end
	elseif t == "number" or t == "bool" then
		f.type = t
	elseif t == "entity" then
		f.type = "choice"
		f.choices = {{"none", 0}}
		-- [KIT_SCENES] every scene's, another's named (a portal's target)
		local cur = current_scene()
		for _, e in ipairs(all_entities()) do
			if e.kind ~= "scene" then
				local s = scene_name(e)
				f.choices[#f.choices + 1] = {NT.entity_label(e) ..
						((s and s ~= cur) and " (" .. s .. ")" or ""), e.id}
			end
		end
	else
		f.type = "text"
		f.max_length = t == "voxel" and 64 or 256
		if t == "position" and type(values[name]) == "table" then
			values[name] = table.concat(values[name], " ")
		end
	end
	return f
end

-- A signal's value's type as a label says it ("" for any)
-- A signal's type as the editor calls it: "string:player" reads as player
local function signal_kind(t, kind, name)
	local labels, types = t[kind .. "_labels"], t[kind .. "_types"]
	return type(labels) == "table" and labels[name] or
			type(types) == "table" and types[name] or nil
end

local function typed(t, kind, name)
	local ty = signal_kind(t, kind, name)
	return (ty and ty ~= "any") and " (" .. ty .. ")" or ""
end

-- [KIT] stage 4d: an entity of the round's own (made in play) or a
-- player's, shown and not edited
local function inspect_made(w, e)
	text(w, NT.entity_label(e))
	-- [KIT] stage 4l: what it costs, changed in place as "kit:costs" comes
	S.cost_text = text(w, M.cost_line(e.id), DIM)
	S.cost_id = e.id
	text(w, e.kind == "player" and "A player" or ("Made in play" ..
			(e.made == "b" and " by " .. tostring(e.made_by) or "") ..
			", by entity " .. tostring(e.maker) .. ": gone at End"), DIM)
	for _, c in ipairs(e.components or {}) do
		text(w, c.type, magic.Color(1.0, 0.85, 0.3))
	end
end

-- A link begun (the inspector's "Link <output>", or a port's drag)
local function begin_link(id, comp, output)
	E.link = {id = id, comp = comp, output = output}
	local e = find(id)
	local t = e and e.components and e.components[comp + 1] and
			type_of(e.components[comp + 1].type) or {}
	E.status = "Linking " .. id .. "'s " .. output ..
			typed(t, "outputs", output) .. ": select the entity to link to"
	log:info("kit editor: linking from " .. id .. " " .. output)
end

-- [KIT_PARAM_CATEGORIES] The inspector's categories of a component's parameters,
-- a parameter's `cat` in its type (undeclared: Behaviour). The chip chosen
-- (S.param_cat, nil All) is kept between entities: a type without it shows All
-- and it is chosen again on the next that has it. Kit's own HUD element
-- selected narrows kit/game_rules to its <name>_*, until a chip is pressed
-- (S.cat_released). A chip holding an edit not applied says so with a " *".
-- simplified: the marks are read as the inspector is drawn: a value being typed
-- marks its own chip, the one in view, only on the next draw
NT.CATS = {{"behaviour", "Behaviour"}, {"hud", "HUD"}, {"look", "Look"},
	{"physics", "Physics"}, {"advanced", "Advanced"}}
NT.CAT_ROW_MIN = 8
NT.OWN_NAMES = {health = "Health bar", hotbar = "Hotbar", feed = "Kill feed",
	hint = "Spectate hint", item_line = "Item line"}

function NT.cat_of(d)
	for _, c in ipairs(NT.CATS) do
		if d.cat == c[1] then
			return c[1]
		end
	end
	return "behaviour"
end

function NT.own_keep(own)
	local prefix = own .. "_"
	return function(k)
		return k:sub(1, #prefix) == prefix
	end
end

-- A chip pressed: the parameters drawn again, from the top; what is pending
-- stays in E.pending
function NT.cat_pick(cat, own)
	S.param_cat, S.cat_released, S.cat_top = cat, own, true
	log:info("kit editor: the chip " .. tostring(cat or "all"))
	inspector_window()
end

-- The row at the top of a component's parameters, none on a type with few or
-- with one category. Returns keep(name, decl) for params_form
function NT.cat_row(w, e, ci, c, t)
	local decl, has, n, kinds = t.params or {}, {}, 0, 0
	for _, d in pairs(decl) do
		local cat = NT.cat_of(d)
		n = n + 1
		kinds = kinds + (has[cat] and 0 or 1)
		has[cat] = true
	end
	local sel_own = c.type == "kit/game_rules" and M.own_selected and
			M.own_selected(e.id) or nil
	local own = sel_own ~= S.cat_released and sel_own or nil
	local keep, cur = nil, not own and has[S.param_cat] and S.param_cat or nil
	local chips, held = {}, {}
	for k in pairs(E.pending[e.id .. "/" .. ci] or {}) do
		if decl[k] then
			held[NT.cat_of(decl[k])] = " *"
		end
	end
	if own or (n >= NT.CAT_ROW_MIN and kinds >= 2) then
		local r = row(w)
		if own then
			button(r, NT.OWN_NAMES[own] or own, function() end, true)
			chips[1] = "[" .. own .. "]"
			keep = NT.own_keep(own)
		end
		button(r, "All", function() NT.cat_pick(nil, sel_own) end,
				not own and not cur)
		chips[#chips + 1] = "All"
		for _, k in ipairs(NT.CATS) do
			if has[k[1]] then
				local name = k[2] .. (held[k[1]] or "")
				button(r, name, function() NT.cat_pick(k[1], sel_own) end,
						not own and cur == k[1])
				chips[#chips + 1] = name
			end
		end
		if cur then
			keep = function(_, d)
				return NT.cat_of(d) == cur
			end
		end
	end
	-- Said as it changes: the chips and what they show
	local shown = {}
	for k, d in pairs(decl) do
		if not keep or keep(k, d) then
			shown[#shown + 1] = k
		end
	end
	table.sort(shown)
	local line = e.id .. "/" .. ci .. " " .. c.type .. ": " .. (#chips > 0 and
			"chips " .. table.concat(chips, " ") .. ", showing " ..
			(own and own .. "_*" or cur or "all") or "no chips") .. ", " .. #shown ..
			" of " .. n .. ": " .. table.concat(shown, " ")
	S.cat_log = S.cat_log or {}
	if S.cat_log[ci] ~= line then
		S.cat_log[ci] = line
		log:info("kit editor: parameters " .. line)
	end
	return keep
end

-- [KIT_PARAM_CATEGORIES] A click on a HUD element: the HUD chip, Kit's own
-- narrowed to its parameters, its panel open in the HUD view
function M.hud_picked()
	S.param_cat, S.cat_released, S.hud_panel_off, S.cat_top = "hud", nil, nil, true
	inspector_window()
	NT.hud_panel(true)
end

-- [KIT_PARAM_CATEGORIES] A component's parameters, keep(name, decl) saying which
-- (all without one), with Apply. Pending values and Apply cover every parameter
-- of it, shown or not: the inspector's and the HUD view's panel's share them
function NT.params_form(w, e, ci, c, t, keep)
	local names, decl = {}, t.params or {}
	for k in pairs(decl) do
		if not keep or keep(k, decl[k]) then
				names[#names + 1] = k
			end
	end
	table.sort(names)
	local fields, values = {}, {}
	local key = e.id .. "/" .. ci
	for k, v in pairs(c.params or {}) do
		values[k] = v
	end
	-- What is picked and not applied yet stays picked: the inspector is
	-- drawn again on the state's packets (user, 2026-10-31: the camera
	-- dropdown went back to first_person at once)
	for k, v in pairs(E.pending[key] or {}) do
		values[k] = v
	end
	local patterns = {}
	for _, k in ipairs(names) do
		-- [KIT_VOXEL_STATES] A pattern of voxels is no text to type:
		-- its buttons below
		if decl[k].type == "voxels" then
			patterns[#patterns + 1] = k
		else
			fields[#fields + 1] = field(k, decl[k], values)
		end
	end
	if #fields > 0 then
		-- [KIT_APPLY_AMBER] Apply's label amber ([MENU_BRAND]'s main)
		-- while an edit waits for it (user, 2026-11-02)
		local apply_text
		local function mark()
			if apply_text then
				apply_text:SetColor(next(E.pending[key] or {}) and
						magic.Color(ui_utils.rgb("main")) or
						magic.Color(ui_utils.rgb("text")))
			end
		end
		ui_utils.settings_form(w, fields, values, function(k, v)
			E.pending[key] = E.pending[key] or {}
			E.pending[key][k] = v
			log:info("kit editor: " .. key .. " " .. k .. " = " .. tostring(v))
			mark()
		end, WIDGETS)
		-- [KIT_WAVE_PIVOT_CENTER] a parameter's `button = "center"`: the object's
		-- centre set again (the server's, one edit)
		for _, k in ipairs(names) do
			if decl[k].button == "center" then
				button(w, "Center " .. k, function()
					log:info("kit editor: " .. key .. " " .. k .. " centred")
					if E.pending[key] then
						E.pending[key][k] = nil
					end
					send({op = "set", id = e.id, comp = ci - 1, param = k, center = true})
				end)
			end
		end
		-- [KIT_ITEMS_TAB] a list of items: one added from the Items
		-- tab's list (a count typed after it)
		-- [KIT_MAP_ROTATION] a list of scenes the same way
		for _, k in ipairs(names) do
			local list = decl[k].choices_from == "item_list" and IT.choices()
			if decl[k].choices_from == "scene_list" then
				list = {{"none", ""}}
				for _, sn in ipairs(E.state and E.state.scenes or {}) do
					list[#list + 1] = {sn, sn}
				end
			end
			if list then
				ui_utils.dropdown(row(w), list, "", function(x)
					local cur = tostring(values[k] or decl[k].default or "")
					if x == "" then
						return
					end
					E.pending[key] = E.pending[key] or {}
					E.pending[key][k] = cur:match("%S") and cur .. ", " ..
							x or x
					log:info("kit editor: " .. key .. " " .. k .. " = " ..
							E.pending[key][k])
					inspector_window()
				end, {label = "Add to " .. k, fill = true})
			end
		end
		local _
		_, apply_text = button(w, "Apply", function()
			for k, v in pairs(E.pending[key] or {}) do
				if decl[k] and decl[k].type == "position" then
					local x, y, z = tostring(v):match(
							"^%s*(%-?[%d.]+)[%s,]+(%-?[%d.]+)[%s,]+(%-?[%d.]+)%s*$")
					v = x and {tonumber(x), tonumber(y), tonumber(z)}
				end
				if v == nil then
					E.status = k .. ": three numbers"
				else
					send({op = "set", id = e.id, comp = ci - 1, param = k,
						value = v})
				end
			end
			E.pending[key] = nil
			refresh()
		end)
		mark()
		NT.pf.overrides(w, e, ci)
	end
	-- [KIT_VOXEL_STATES] Each pattern: Capture (the box as it is now),
	-- Show (written into the world, an edit undone as one) and Fill (all
	-- of the box one voxel: the one picked here, the one in hand first)
	if #patterns > 0 then
		E.fill = E.fill or {}
		local names = {{"air", "air"}}
		for _, n in ipairs(voxel_names()) do
			names[#names + 1] = n
		end
		E.fill[key] = E.fill[key] or S.voxel or "air"
		ui_utils.dropdown(row(w), names, E.fill[key], function(name)
			E.fill[key] = name
			log:info("kit editor: " .. key .. " fill with " .. name)
		end, {label = "Fill with", fill = true})
	end
	for _, k in ipairs(patterns) do
		local r, v = row(w), values[k]
		local cells = type(v) == "string" and v:match("^(%d+ %d+ %d+);")
		label(r, k:upper() .. (cells and "" or " (empty)"))
		for _, a in ipairs({{"Capture", "capture"}, {"Show", "show"},
				{"Fill", "fill"}}) do
			button(r, a[1] .. " " .. k:upper(), function()
				send({op = "pattern", id = e.id, comp = ci - 1, param = k,
					action = a[2], voxel = a[2] == "fill" and E.fill[key] or
					nil})
				log:info("kit editor: " .. a[2] .. " " .. e.id .. " " .. k)
			end)
		end
	end
return names
end

-- [KIT_GOALS] What the links say of the goals (kit/goal; of every scene):
-- {warned = {id = {lines}}, list = {"<goal>: <line>"...}, final = {id = true},
-- reachable = {id = "<line>"}}, worked out once a state. An edge is a link into
-- a goal's activate or into anything else, whatever its output or input: a path
-- of links, not that it can happen.
-- simplified: "nothing activates" looks at one goal's links alone: a closed
-- loop of goals no way in leads to is not warned of; only a named final goal's
-- walk sees that. c:send from a script counts for nothing (a false warning)
local function goal_of(e)
	for _, c in ipairs(e.components or {}) do
		if c.type == "kit/goal" then
			return c
		end
	end
end
-- Each id's depth from `from` along `next_` ({id = {id...}})
local function walk(next_, from)
	local depth, queue = {[from] = 0}, {from}
	for _, id in ipairs(queue) do
		for _, to in ipairs(next_[id] or {}) do
			if not depth[to] then
				depth[to] = depth[id] + 1
				queue[#queue + 1] = to
			end
		end
	end
	return depth
end
function NT.goal_check()
	if NT.goal_checked and NT.goal_checked.state == E.state then
		return NT.goal_checked
	end
	local r = {state = E.state, warned = {}, list = {}, final = {}, reachable = {}}
	NT.goal_checked = r
	local by, into, from_, activated = {}, {}, {}, {}
	local all = all_entities()
	for _, e in ipairs(all) do
		by[e.id] = e
	end
	for _, e in ipairs(all) do
		for _, c in ipairs(e.components or {}) do
			for _, l in ipairs(c.links or {}) do
				local to = by[l.to]
				local is_goal = to and goal_of(to)
				if to and l.to ~= e.id and (not is_goal or l.input == "activate") then
					from_[e.id] = from_[e.id] or {}
					table.insert(from_[e.id], l.to)
					into[l.to] = into[l.to] or {}
					table.insert(into[l.to], e.id)
				end
				if is_goal and l.input == "activate" and l.to ~= e.id then
					activated[l.to] = true
				end
			end
		end
	end
	local function warn(e, line)
		r.warned[e.id] = r.warned[e.id] or {}
		table.insert(r.warned[e.id], line)
		r.list[#r.list + 1] = NT.entity_label(e) .. ": " .. line
	end
	-- The deepest goal in a walk, the lowest id of those
	local function deepest(depth)
		local best
		for _, e in ipairs(all) do
			local d = depth[e.id]
			if d and goal_of(e) and (not best or d > depth[best.id]) then
				best = e
			end
		end
		return best
	end
	for _, e in ipairs(all) do
		local c = goal_of(e)
		local p = c and c.params or {}
		if c and not activated[e.id] and p.autostart ~= true then
			warn(e, "nothing activates it: no link to its activate, autostart off")
		end
		if c and p.kind == "use" and not by[tonumber(p.target) or 0] then
			warn(e, "a use goal with no object to use (target)")
		end
		local fin = tonumber(p.validate_reachable) or 0
		if c and fin ~= 0 then
			local fe = by[fin]
			if not (fe and goal_of(fe)) then
				warn(e, "validate reachable names no goal")
			else
				r.final[fin] = true
				local depth = walk(from_, e.id)
				if depth[fin] then
					r.reachable[e.id] = "Links lead from here to " ..
							NT.entity_label(fe)
				else
					warn(e, "no chain of links reaches " .. NT.entity_label(fe) ..
							": last reached " .. NT.entity_label(deepest(depth)) ..
							", first cut off " ..
							NT.entity_label(deepest(walk(into, fin))))
				end
			end
		end
	end
	local said = table.concat(r.list, "\n")
	if NT.goal_said ~= said then
		NT.goal_said = said
		log:info("kit editor: goal warnings: " .. #r.list)
		for _, line in ipairs(r.list) do
			log:info("kit editor: goal warning: " .. line)
		end
	end
	return r
end

-- [KIT_GOALS] Publish: the goals' warnings listed first, go() when answered
-- (not a refusal: the builder decides). simplified: a draft's Publish and
-- Publish my prefabs...; the launcher's publishing of a whole app sees no
-- composition
-- A warning in lines of about 52 bytes: a long one otherwise sets the width of
-- the whole inspector
function NT.warn_text(w, line)
	local cur = ""
	for word in line:gmatch("%S+") do
		if cur ~= "" and #cur + #word > 52 then
			text(w, cur, WARN)
			cur = word
		else
			cur = cur == "" and word or cur .. " " .. word
		end
	end
	text(w, cur, WARN)
end

function NT.publish_checked(what, go)
	local list = NT.goal_check().list
	log:info("kit editor: publish " .. what .. ": " .. #list .. " goal warnings")
	if #list == 0 then
		return go()
	end
	if W.goal_dialog then
		W.goal_dialog:Remove()
	end
	local d = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.goal_dialog = d
	d.priority = 10
	text(d, "Publish " .. what .. "? " .. #list .. " goal warnings:")
	for _, line in ipairs(list) do
		log:info("kit editor: at publish: " .. line)
		NT.warn_text(d, line)
	end
	local function close()
		d:Remove()
		W.goal_dialog = nil
	end
	local r = row(d)
	button(r, "Publish anyway", function()
		close()
		log:info("kit editor: published with goal warnings")
		go()
	end)
	button(r, "Cancel", function()
		close()
		log:info("kit editor: publish cancelled")
	end)
end

-- ---- [KIT_SYMMETRY] stage 3, the editor's view of kit/symmetry (the server's
-- state.symmetry: kit.cpp's sym_state)

-- A kit/symmetry's copy: its built ({by, source, slice}), or nil
function NT.sym_copy(e)
	local b = type(e) == "table" and e.built
	if type(b) ~= "table" or type(b.slice) ~= "number" then
		return nil
	end
	local g = find(b.by)
	for _, c in ipairs(g and g.components or {}) do
		if c.type == "kit/symmetry" then
			return b
		end
	end
end

-- The state of the kit/symmetry `id` in this scene, or nil
function NT.sym_state(id)
	for _, s in ipairs(E.state and E.state.symmetry or {}) do
		if s.id == id then
			return s
		end
	end
end

-- A convex polygon {{x, z}...} cut to its part where a x + b z >= 0
function NT.sym_clip(poly, a, b)
	local out = {}
	for i = 1, #poly do
		local p, q = poly[i], poly[i % #poly + 1]
		local dp, dq = a * p[1] + b * p[2], a * q[1] + b * q[2]
		if dp >= 0 then
			out[#out + 1] = p
		end
		if (dp >= 0) ~= (dq >= 0) then
			local t = dp / (dp - dq)
			out[#out + 1] = {p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t}
		end
	end
	return out
end

-- Its seams (the lines a x + b z = 0 across the map) and each slice's polygon,
-- [1] the authored one: the map's rectangle (cells' edges) cut by the authored
-- slice's half-planes, those turned by each slice's map for the others
function NT.sym_shapes(st)
	local x0, z0 = st.x0 - 0.5, st.z0 - 0.5
	local x1, z1 = x0 + st.width, z0 + st.depth
	local rect = {{x0, z0}, {x1, z0}, {x1, z1}, {x0, z1}}
	local seams, slices = {}, {}
	for _, pl in ipairs(st.planes or {}) do
		-- Along (-b, a) from the origin, within the rectangle
		local d = {-pl[2], pl[1]}
		local lo, hi = -math.huge, math.huge
		for k, range in ipairs({{x0, x1}, {z0, z1}}) do
			if d[k] ~= 0 then
				local ta, tb = range[1] / d[k], range[2] / d[k]
				lo, hi = math.max(lo, math.min(ta, tb)), math.min(hi, math.max(ta, tb))
			end
		end
		if lo < hi then
			seams[#seams + 1] = {{d[1] * lo, d[2] * lo}, {d[1] * hi, d[2] * hi}}
		end
	end
	for i, m in ipairs(st.maps or {}) do
		local poly = rect
		for _, pl in ipairs(st.planes or {}) do
			-- The normal's image: x' = a x + b z, z' = c x + d z
			poly = NT.sym_clip(poly, m[1] * pl[1] + m[2] * pl[2],
					m[3] * pl[1] + m[4] * pl[2])
		end
		slices[i] = poly
	end
	return seams, slices
end

-- In edit mode: the seams, and a shade over the slices not to be edited (drawn
-- over everything, at the kit/symmetry's ground)
function NT.sym_draw(dbg)
	for _, st in ipairs(E.state and E.state.symmetry or {}) do
		local se = find(st.id)
		if st.on and st.planes and se and se.pos then
			local y = se.pos[2] - 0.45
			local seams, slices = NT.sym_shapes(st)
			local V = magic.Vector3
			-- (three lines a tenth of a cell apart: one is lost in the plan)
			local seam = magic.Color(1, 0.9, 0.4)
			for _, s in ipairs(seams) do
				local dx, dz = s[2][1] - s[1][1], s[2][2] - s[1][2]
				local l = math.sqrt(dx * dx + dz * dz)
				for o = -0.1, 0.11, 0.1 do
					local ox, oz = -dz / l * o, dx / l * o
					dbg:AddLine(V(s[1][1] + ox, y, s[1][2] + oz),
							V(s[2][1] + ox, y, s[2][2] + oz), seam, false)
				end
			end
			local shade = magic.Color(0.55, 0.2, 0.6, 0.28)
			for i = 2, #slices do
				local p = slices[i]
				for k = 2, #p - 1 do
					dbg:AddTriangle(V(p[1][1], y, p[1][2]), V(p[k][1], y, p[k][2]),
							V(p[k + 1][1], y, p[k + 1][2]), shade, false)
				end
			end
			local said = st.id .. " " .. #seams .. " seams, " .. (#slices - 1) ..
					" shaded"
			if NT.sym_drawn ~= said then
				NT.sym_drawn = said
				log:info("kit editor: symmetry " .. said)
			end
		end
	end
end

-- A copy's inspector: what it is a copy of and the way to it
function NT.sym_copy_section(w, e, b)
	local src = find(b.source)
	text(w, "Copy of " .. (src and NT.entity_label(src) or tostring(b.source)) ..
			", slice " .. b.slice .. ": its parameters only", DIM)
	button(w, "Go to source " .. b.source, function()
		local from = drawn_at(e)
		local fx, fy, fz = from.x, from.y, from.z
		log:info("kit editor: to copy " .. e.id .. "'s source " .. b.source)
		M.select(b.source)
		-- The view moved by what lies between them
		local s = src and drawn_at(src)
		if s then
			local dx, dy, dz = s.x - fx, s.y - fy, s.z - fz
			S.cx, S.cz = S.cx + dx, S.cz + dz
			if S.pos then
				S.pos = {x = S.pos.x + dx, y = S.pos.y + dy, z = S.pos.z + dz}
			end
		end
	end)
end

-- A kit/symmetry's inspector: why it copies nothing, every override on its
-- copies, the parity warnings
function NT.sym_section(w, e)
	local st = NT.sym_state(e.id)
	if not st then
		return
	end
	if st.why then
		NT.warn_text(w, "It copies nothing: " .. st.why)
	end
	if not st.on or st.why then
		return
	end
	local lines = {}
	for _, x in ipairs(entities()) do
		local b = NT.sym_copy(x)
		for _, c in ipairs(b and b.by == e.id and x.components or {}) do
			for _, k in ipairs(c.overrides or {}) do
				local v = (c.params or {})[k]
				lines[#lines + 1] = {id = x.id, text = "Copy " .. x.id .. " of " ..
						b.source .. " (slice " .. b.slice .. "): " .. k .. " = " ..
						(type(v) == "table" and table.concat(v, ", ") or tostring(v))}
			end
		end
	end
	table.sort(lines, function(a, b) return a.text < b.text end)
	local ov = #lines == 1 and "1 override" or #lines .. " overrides"
	text(w, #lines == 0 and "No overrides: each copy is its source's image" or
			ov .. ":", DIM)
	for _, l in ipairs(lines) do
		local r = row(w)
		label(r, l.text)
		button(r, "Select " .. l.id, function()
			M.select(l.id)
		end)
	end
	if (st.parity or "") ~= "" then
		NT.warn_text(w, "Parity: " .. st.parity)
	end
	local said = ov .. "; parity: " .. (st.parity ~= "" and
			st.parity or "none")
	for _, l in ipairs(lines) do
		said = said .. "\n  " .. l.text
	end
	if NT.sym_said ~= said then
		NT.sym_said = said
		log:info("kit editor: symmetry " .. e.id .. ": " .. said)
	end
end

local function inspector(w, e, is_made)
	if is_made then
		return inspect_made(w, e)
	end
	local n = #sel_ids()
	if n > 1 then
		text(w, n .. " selected", DIM)
	end
	text(w, NT.entity_label(e))
	-- [KIT_SYMMETRY] a copy: its parameters alone, the rest its source's
	local copy = NT.sym_copy(e)
	if copy then
		NT.sym_copy_section(w, e, copy)
	end
	-- [KIT_GOALS]
	local gc = goal_of(e) and NT.goal_check()
	for _, line in ipairs(gc and gc.warned[e.id] or {}) do
		NT.warn_text(w, "Warning: " .. line)
	end
	if gc and gc.reachable[e.id] then
		text(w, gc.reachable[e.id], DIM)
	end
	if gc and gc.final[e.id] then
		text(w, "A final goal: drawn gold on the map", DIM)
	end
	-- [KIT] stage 4l: what it costs, changed in place as "kit:costs" comes
	S.cost_text = text(w, M.cost_line(e.id), DIM)
	S.cost_id = e.id
	-- [KIT_SIGNALS_VIEW] In the Signals view its position, its parameters, its
	-- parent's buttons and Try alone: the links are the view's own table
	local sig = NT.sig()
	-- Its position typed in (fine tuning, and where keys are not at hand:
	-- a touchscreen), Move one edit; with several selected they move by
	-- what this one moves
	if e.pos and not copy then
		local r, at = row(w), {e.pos[1], e.pos[2], e.pos[3]}
		for i, axis in ipairs({"x", "y", "z"}) do
			-- One letter's room: the row's layout has already widened it
			label(r, axis):SetFixedWidth(12)
			local f = edit(r, string.format("%g", at[i]), function(s)
				at[i] = tonumber(s)
			end)
			f.minWidth = 56
			-- For a driven click
			f:SetName("position " .. axis)
		end
		button(r, "Move", function()
			if not (at[1] and at[2] and at[3]) then
				E.status = "Move: three numbers"
				return people()
			end
			local by = {at[1] - e.pos[1], at[2] - e.pos[2], at[3] - e.pos[3]}
			if n > 1 then
				send({op = "move", ids = sel_ids(), by = by})
			else
				send({op = "move", id = e.id, pos = at})
			end
			log:info(string.format("kit editor: moved %d by %g, %g, %g from "
					.. "the inspector", n, by[1], by[2], by[3]))
		end)
		-- [KIT_FREE_ROTATION] Its turn typed in, once it has one or may well get
		-- one (the rows' angles: in the world, as the position's)
		if (e.yaw or 0) ~= 0 or (e.pitch or 0) ~= 0 or (e.roll or 0) ~= 0 or
				NT.pf.is_free(e) then
			local tr = row(w)
			local a = {e.yaw or 0, e.pitch or 0, e.roll or 0}
			for i, axis in ipairs({"yaw", "pitch", "roll"}) do
				label(tr, axis:sub(1, 1)):SetFixedWidth(12)
				-- (a place in the field's width; the rows are on a 1/16's grid, a
				-- parent's turn makes it long)
				local f = edit(tr, string.format("%.4g", a[i]), function(s)
					a[i] = tonumber(s)
				end)
				f.minWidth = 56
				f:SetName("turn " .. axis)
			end
			button(tr, "Turn", function()
				if not (a[1] and a[2] and a[3]) then
					E.status = "Turn: three numbers"
					return people()
				end
				send({op = "move", id = e.id, pos = e.pos, yaw = a[1], pitch = a[2],
					roll = a[3]})
				log:info(string.format("kit editor: turned %d to %g, %g, %g from "
						.. "the inspector", e.id, a[1], a[2], a[3]))
			end)
		end
	end
	-- ([KIT_NO_WORLD_TYPES] one with no position too: kit/starting_kit under a
	-- kit/team)
	local c1 = e.components and e.components[1]
	if not copy and (e.pos or (c1 and type_of(c1.type).no_position)) then
		-- [KIT_NESTING] what it is under; what is placed next under it.
		-- [KIT_REPARENT_BUTTONS] Switch parent arms: the next entity clicked
		-- (the view's or the list's, [KIT_SIGNALS_PARENT_BUTTONS] the Signals
		-- list's) is its parent; Un-parent puts it back under the scene. The
		-- server keeps its place in the world
		local pe = NT.tree().by[e.parent]
		pe = pe and (pe.pos or NT.is_panel(pe)) and pe
		if pe then
			text(w, "Under " .. NT.entity_label(pe), DIM)
		end
		local pr, armed = row(w), S.reparent == e.id
		button(pr, armed and "Switch parent: Cancel" or "Switch parent",
				function()
			NT.arm_parent(not armed and e.id or nil)
		end, armed)
		if pe then
			button(pr, "Un-parent", function()
				log:info("kit editor: un-parent " .. e.id)
				send({op = "parent", id = e.id, parent = 0})
			end)
		end
	end
	if (e.pos or NT.is_panel(e)) and not sig and not copy then
		local on = S.under == e.id
		button(w, on and "Placing under this: stop" or "Place under this",
				function()
			S.under = not on and e.id or nil
			log:info("kit editor: placing under " ..
					tostring(S.under or "the scene"))
			refresh()
		end, on)
	end
	if not sig and not copy then
		button(w, "Delete", function()
			M.delete_selected()
		end)
	end
	-- [KIT_COMPONENTS] A built child's are its prefab's. (Over the components: a
	-- movement's parameters are longer than the screen)
	local may_compose = not sig and type(e.built) ~= "table" and not e.kind
	if may_compose then
		NT.add_component(w, e)
	end
	for ci, c in ipairs(e.components or {}) do
		local t = type_of(c.type)
		if may_compose and t.addable and #e.components > 1 then
			local tr = row(w)
			label(tr, c.type).color = magic.Color(1.0, 0.85, 0.3)
			button(tr, "Remove", function()
				log:info("kit editor: remove " .. c.type .. " from " .. e.id)
				send({op = "remove_component", id = e.id, comp = ci - 1})
			end)
		else
			text(w, c.type, magic.Color(1.0, 0.85, 0.3))
		end
		NT.component_hint(w, e, t)
		if E.running then
			button(w, "Restart this", function()
				send({op = "restart", id = e.id, comp = ci - 1})
			end)
		end
		-- [KIT_HUD_STYLE] "Copy style from..."
		if NT.style_prefix(c.type) then
			ui_utils.dropdown(row(w), NT.style_sources(e.id, ci), "", function(x)
				local fid, fci = tostring(x):match("^(%d+) (%d+)$")
				if fid then
					NT.copy_style(tonumber(fid), tonumber(fci), e.id, ci)
				end
			end, {label = "Copy style from...", fill = true})
		end
		-- [KIT_HEIGHTMAP_REGEN_LOSS] A heightmap World: its edited samples,
		-- kept over every regeneration; generating all anew (discarding
		-- them) asks first; the map before the last regeneration back
		local tr = E.state.terrain
		if c.type == "kit/world" and tr and tr.surface == "heightmap" then
			text(w, (tr.edited_samples or 0) .. " edited heightmap samples",
					DIM)
			if E.regen_ask then
				local r = row(w)
				button(r, "Discard edits, regenerate all", function()
					E.regen_ask = nil
					send({op = "hm_regenerate"})
					log:info("kit editor: the heightmap regenerated, edits "
							.. "discarded")
				end)
				button(r, "Cancel", function()
					E.regen_ask = nil
					refresh()
				end)
			else
				button(w, "Regenerate all...", function()
					E.regen_ask = true
					log:info("kit editor: regenerate all? " ..
							(tr.edited_samples or 0) .. " edited samples")
					refresh()
				end)
			end
			if tr.previous then
				button(w, "Restore the previous heightmap", function()
					send({op = "hm_restore"})
					log:info("kit editor: the previous heightmap asked back")
				end)
			end
		end
		NT.params_form(w, e, ci, c, t, NT.cat_row(w, e, ci, c, t))
		for _, l in ipairs(not sig and not copy and c.links or {}) do
			local r = row(w)
			local to = find(l.to)
			label(r, l.output .. " -> " .. l.to .. " " .. tostring(to and
					to.name or "?") .. ": " .. l.input)
			button(r, "Unlink", function()
				send({op = "unlink", id = e.id, comp = ci - 1,
					output = l.output, to = l.to, input = l.input})
			end)
			-- [KIT] stage 4l: drawn for players in play too
			-- ([KIT_PARAM_CATEGORIES] as short as the Signals view's: a long link's
			-- row is what sets the inspector's width)
			button(r, l.visible and "Shown" or "Hidden",
					function()
				send({op = "link_visible", id = e.id, comp = ci - 1,
					output = l.output, to = l.to, input = l.input,
					visible = not l.visible})
				log:info("kit editor: link " .. e.id .. "." .. l.output ..
						" -> " .. l.to .. "." .. l.input .. " " ..
						(l.visible and "hidden" or "shown") .. " in play")
			end)
		end
		-- [KIT_PARAM_CATEGORIES] Three a row, as Try's: kit/flag's eight in one
		-- made the whole inspector over 1000 wide
		local r
		for i, o in ipairs(not sig and not copy and t.outputs or {}) do
			if i % 3 == 1 then
				r = row(w)
			end
			button(r, "Link " .. o, function()
				begin_link(e.id, ci - 1, o)
				refresh()
			end)
		end
		-- [KIT_TRY_INPUTS] Try: each input sent to it as a link would (by
		-- this builder), a value typed beside one that takes one, three a
		-- row
		local tr
		for i, input in ipairs(t.inputs or {}) do
			if i % 3 == 1 then
				tr = row(w)
				label(tr, i == 1 and "Try:" or "", 32)
			end
			local ty = type(t.inputs_types) == "table" and
					t.inputs_types[input] or "any"
			local vk = e.id .. "/" .. input
			if ty ~= "none" then
				edit(tr, E.try_values[vk] or "", function(s)
					E.try_values[vk] = s
				end).minWidth = 48
			end
			button(tr, input, function()
				M.try(e.id, input, ty, E.try_values[vk])
			end)
		end
	end
	-- What the last Try's runs emitted, for a while
	local a = E.tried
	if a and a.id == e.id and buildat.get_time_us() < a.till then
		text(w, a.text, magic.Color(0.5, 1, 0.6))
	end
	if E.link and E.link.id ~= e.id then
		text(w, "Link " .. E.link.id .. "'s " .. E.link.output .. " to:")
		local r, m = nil, 0
		local seen = {}
		for _, c in ipairs(e.components or {}) do
			for _, i in ipairs(type_of(c.type).inputs or {}) do
				if not seen[i] then
					seen[i] = true
					m = m + 1
					if m % 3 == 1 then
						r = row(w)
					end
					button(r, "To " .. i, function()
						send({op = "link", id = E.link.id, comp = E.link.comp,
							output = E.link.output, to = e.id, input = i})
						E.link = nil
						E.status = ""
					end)
				end
			end
		end
		if not next(seen) then
			text(w, "It has no inputs", WARN)
		end
	end
	if E.link then
		button(w, "Cancel link", function()
			E.link = nil
			E.status = ""
			refresh()
		end)
	end
	-- [KIT_SYMMETRY] a kit/symmetry's overrides and parity warnings
	NT.sym_section(w, e)
	-- [KIT_PREFAB_ROOT] a prefab's copy, its root
	if type(e.prefab) == "table" then
		NT.pf.section(w, e)
	end
	-- [KIT_GENERATORS] a generator's child: built again as it changes,
	-- what is set here kept
	if type(e.built) == "table" and not copy then
		local g = find(e.built.by)
		text(w, "Built by " .. (g and name_of(g) or tostring(e.built.by)) ..
				" (its " .. tostring(e.built.member) .. ")", DIM)
	end
end

-- [KIT_BOX_ADJUST] The Box tool's box adjusted once its two corners are
-- in: typed (its low corner and its size, in the panel's Box tab) or by
-- the handles on its six faces (a drag moves that face; Shift, the whole
-- box along the axis). The box is the tool's: put away, it goes (a
-- selection made first is kept, so entities and voxels copy together)
local BX = {MAX = 64, AXES = {"x", "y", "z"}}

-- Its low and high cells, or nil while it has no second corner
function BX.box_lh()
	local b = S.vbox
	if not b or not b.a or not b.b then
		return nil
	end
	local lo, hi = {}, {}
	for k = 1, 3 do
		lo[k], hi[k] = math.min(b.a[k], b.b[k]), math.max(b.a[k], b.b[k])
	end
	return lo, hi
end

function BX.set_box(lo, hi, how)
	S.vbox = {a = {lo[1], lo[2], lo[3]}, b = {hi[1], hi[2], hi[3]}}
	if how then
		log:info(string.format("kit editor: box %d,%d,%d,%d,%d,%d (%s)",
				lo[1], lo[2], lo[3], hi[1], hi[2], hi[3], how))
	end
end

-- The handles: a small cube out from each face's middle
function BX.box_handles()
	local lo, hi = BX.box_lh()
	if not lo or S.tool ~= "box" then
		return {}
	end
	local hs = {}
	for k = 1, 3 do
		for _, side in ipairs({-1, 1}) do
			local c = {(lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2,
				(lo[3] + hi[3]) / 2}
			c[k] = side < 0 and lo[k] - 0.9 or hi[k] + 0.9
			hs[#hs + 1] = {k = k, side = side,
				name = (side < 0 and "-" or "+") .. BX.AXES[k],
				at = magic.Vector3(c[1], c[2], c[3])}
		end
	end
	return hs
end

-- The handle under the pointer (the nearest on the screen), or nil
function BX.box_handle_at(mx, my)
	local best, bd = nil, nil
	for _, h in ipairs(BX.box_handles()) do
		local sx, sy = to_screen(h.at)
		if sx then
			local d = (sx - mx) ^ 2 + (sy - my) ^ 2
			if d <= px(SNAP_PX * 1.5) ^ 2 and (not bd or d < bd) then
				best, bd = h, d
			end
		end
	end
	return best
end

-- Where along a handle's axis the ray through the screen point (sx, sy)
-- passes nearest: the axis's line through the handle, in cells from it
function BX.box_axis_t(h, sx, sy)
	local o, v = M.screen_ray(sx, sy)
	local w = {h.at.x - o.x, h.at.y - o.y, h.at.z - o.z}
	local vv = {v.x, v.y, v.z}
	local b = vv[h.k]
	local denom = 1 - b * b
	if denom < 1e-4 then
		return nil
	end
	local e = vv[1] * w[1] + vv[2] * w[2] + vv[3] * w[3]
	return (b * e - w[h.k]) / denom
end

-- A press on a handle: the drag follows the pointer's moves from here,
-- the handle where it was on the screen
function BX.box_grab(h, sx, sy, shift)
	local lo, hi = BX.box_lh()
	S.box_drag = {h = h, lo = lo, hi = hi, shift = shift, m0 = {S.mx, S.my},
		s0 = {sx, sy}, t0 = BX.box_axis_t(h, sx, sy), delta = 0}
	log:info("kit editor: box handle " .. h.name .. (shift and
			", moving the box" or ""))
end

function BX.box_drag_move(x, y)
	local d = S.box_drag
	local t = d.t0 and BX.box_axis_t(d.h, d.s0[1] + x - d.m0[1],
			d.s0[2] + y - d.m0[2])
	if not t then
		return
	end
	local delta = round(t - d.t0)
	if delta == d.delta then
		return
	end
	d.delta = delta
	local k = d.h.k
	local lo = {d.lo[1], d.lo[2], d.lo[3]}
	local hi = {d.hi[1], d.hi[2], d.hi[3]}
	if d.shift then
		lo[k], hi[k] = lo[k] + delta, hi[k] + delta
	elseif d.h.side > 0 then
		hi[k] = math.max(lo[k], math.min(lo[k] + BX.MAX - 1, hi[k] + delta))
	else
		lo[k] = math.min(hi[k], math.max(hi[k] - BX.MAX + 1, lo[k] + delta))
	end
	BX.set_box(lo, hi)
	palette()
end

function BX.box_drop()
	local d = S.box_drag
	S.box_drag = nil
	local lo, hi = BX.box_lh()
	if lo then
		BX.set_box(lo, hi, (d.shift and "moved " or "face ") .. d.h.name ..
				" by " .. d.delta)
	end
	refresh()
end

-- The Box tab's box: its low corner and its size typed, each change
-- taken as it is a whole number (a size 1 to 64)
function BX.box_section(w)
	local lo, hi = BX.box_lh()
	text(w, "Box")
	if not lo then
		text(w, S.vbox and "Click its second corner." or
				"Click its first corner.", DIM)
		return
	end
	local at = {lo[1], lo[2], lo[3]}
	local size = {hi[1] - lo[1] + 1, hi[2] - lo[2] + 1, hi[3] - lo[3] + 1}
	local function apply(what)
		BX.set_box(at, {at[1] + size[1] - 1, at[2] + size[2] - 1,
			at[3] + size[3] - 1}, "typed " .. what)
	end
	for _, part in ipairs({{"at", at, {"x", "y", "z"}},
			{"size", size, {"w", "h", "d"}}}) do
		local r = row(w)
		label(r, part[1]):SetFixedWidth(40)
		for i, axis in ipairs(part[3]) do
			label(r, axis):SetFixedWidth(12)
			local f = edit(r, tostring(part[2][i]), function(s)
				local n = tonumber(s)
				if not n or n ~= math.floor(n) or n == part[2][i] or
						(part[1] == "size" and (n < 1 or n > BX.MAX)) or
						math.abs(n) > 30000 then
					return
				end
				part[2][i] = n
				apply(part[1] .. " " .. axis)
			end)
			f.minWidth = 48
		end
	end
	text(w, "Drag a face's handle; Shift: the whole box", DIM)
end
NT.box_section = BX.box_section

-- A check's two corner clicks: "x y z x y z", the Box tool's box
magic.SubscribeToEvent("command_seq:kit_box", function(_, data)
	local c = {}
	for n in data:GetString("Param"):gmatch("%-?%d+") do
		c[#c + 1] = tonumber(n)
	end
	if #c ~= 6 or S.tool ~= "box" then
		log:info("kit editor: kit_box: x y z x y z, the Box tool on")
		return
	end
	S.vbox = {a = {c[1], c[2], c[3]}, b = {c[4], c[5], c[6]}}
	log:info("kit editor: box " .. table.concat(c, ","))
	refresh()
end)

-- A check's 3d view camera: "x y z x y z", where it is and a point it
-- looks at
magic.SubscribeToEvent("command_seq:kit_cam3d", function(_, data)
	local c = {}
	for n in data:GetString("Param"):gmatch("%-?[%d.]+") do
		c[#c + 1] = tonumber(n)
	end
	if #c ~= 6 then
		log:info("kit editor: kit_cam3d: x y z x y z")
		return
	end
	local dx, dy, dz = c[4] - c[1], c[5] - c[2], c[6] - c[3]
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	if l < 0.001 then
		return
	end
	S.pos = {x = c[1], y = c[2], z = c[3]}
	S.yaw = math.deg(math.atan2(dx, dz))
	S.pitch = math.deg(math.asin(-dy / l))
	set_view("3d")
end)

-- [KIT_PLAN_CAPS] A check's plan: "x z span cut", its middle, how far
-- across it is high and the cut
magic.SubscribeToEvent("command_seq:kit_plan", function(_, data)
	local c = {}
	for n in data:GetString("Param"):gmatch("%-?[%d.]+") do
		c[#c + 1] = tonumber(n)
	end
	if #c ~= 4 then
		log:info("kit editor: kit_plan: x z span cut")
		return
	end
	S.cx, S.cz, S.span, S.cut = c[1], c[2], c[3], c[4]
	set_view("2d")
end)

-- [KIT_DRAFT_LEAVE_PLAY] A check's question: edit mode or play now
magic.SubscribeToEvent("command_seq:kit_mode", function(_, data)
	log:info("kit editor: the mode: " .. (E.editing and "edit" or "play") ..
			" (" .. data:GetString("Param") .. ")")
end)

-- [WB_EDITOR_VIEW_MEMORY] A check's question: the view and the tabs
magic.SubscribeToEvent("command_seq:kit_tabs", function(_, data)
	log:info("kit editor: the view " .. S.view .. ", the tabs " .. NT.tab() ..
			", " .. tostring(S.list_tab) .. ", " .. tostring(S.tab) .. " (" ..
			data:GetString("Param") .. ")")
	NT.log_shown()
end)

-- A check's question: where the editor's windows are on the screen, in
-- pixels ("<name> x y w h" each), for a mask over a frame compared
magic.SubscribeToEvent("command_seq:kit_ui_where", function(_, data)
	local sc, r = magic.ui.scale, {}
	for _, k in ipairs({"bar", "palette", "inspector", "people", "sg_list",
			"sg_links", "sg_view", "hud_panel", "ctx"}) do
		local w = W[k]
		if w and w.visible then
			local p = w.screenPosition
			r[#r + 1] = string.format("%s %d %d %d %d", k, p.x * sc, p.y * sc,
					w.width * sc, w.height * sc)
		end
	end
	log:info("kit editor: the windows at " .. table.concat(r, ", ") ..
			" (" .. data:GetString("Param") .. ")")
end)

-- A check's question: where the 3D camera is
magic.SubscribeToEvent("command_seq:kit_cam_where", function(_, data)
	local p = S.pos or {x = 0, y = 0, z = 0}
	log:info(string.format("kit editor: the 3D camera at %.2f %.2f %.2f "
			.. "(%s)", p.x, p.y, p.z, data:GetString("Param")))
	log:info(string.format("kit editor: the plan %.2f across (%s)", S.span or 0,
			data:GetString("Param")))
	-- [KIT_WALK_HERE] and the walker's
	local w, d = O.camera.worldPosition, O.camera.worldDirection
	log:info(string.format("kit editor: the walk camera at %.2f %.2f %.2f looking "
			.. "%.3f %.3f %.3f (%s)", w.x, w.y, w.z, d.x, d.y, d.z, data:GetString("Param")))
end)

-- A check's look for a handle by its name ("+y", "-x"): where it is on
-- the screen, and whether a press there takes it
magic.SubscribeToEvent("command_seq:kit_box_where", function(_, data)
	local name = data:GetString("Param")
	for _, h in ipairs(BX.box_handles()) do
		local sx, sy = to_screen(h.at)
		if h.name == name and sx then
			local found = BX.box_handle_at(sx, sy)
			log:info(string.format("kit editor: box handle %s on the screen "
					.. "at %d, %d%s", name, sx, sy, found and found.name == name
					and "" or ", not the one picked there"))
			return
		end
	end
	log:info("kit editor: no box handle " .. name .. " on the screen")
end)

-- [KIT_INSPECTOR_OFF_SCREEN] The inspector's body scrolls (a ScrollView:
-- the wheel, its bar, a finger dragged), bounded each frame above the
-- screen's foot and the touch bar: kit/region's ran off a phone's screen
-- at the UI fit's floor, Apply out of reach. Where it was scrolled is kept
-- as it is drawn again on the state's packets.
-- simplified: the title, Delete and Apply scroll with the rest; held in
-- sight they would need inspector() to build into a head and a foot
local IV = {view = nil, y = 0}

-- [KIT_LAST_ROW_CLIP] For kit_tabs: how far down each unscrolled body is shown
function NT.log_shown()
	for _, v in ipairs({{"inspector", IV.view}, {"HUD panel", S.hud_panel_view}}) do
		local view = v[2]
		if view and view.visible and not view.verticalScrollBar.visible then
			local b = view.contentElement
			log:info(string.format("kit editor: the %s's body ends at %d, shown to %d",
					v[1], b.screenPosition.y + b.height,
					view.screenPosition.y + view.height - 2))
		end
	end
end

local function fit_inspector()
	local w, view = W.inspector, IV.view
	-- ([KIT_SIGNALS_VIEW] the view's own column there, NT.sg.layout)
	if not w or not view or NT.sig() then
		return
	end
	local body = view.contentElement
	local foot = W.touch and W.touch.visible and W.touch.height + 16 or 16
	-- The screen's height at the unfitted scale (narrow()'s): bounded by
	-- the root's, the inspector followed the fit and the fit it
	narrow()
	local room = screen_ui.h - w.position.y - 12 - foot
	-- A field's warning grows the body and a layout never shrinks it again by
	-- itself: asked to, while it is over the height it was built at
	if body.height > S.inspector_h0 then
		body.height = 1
	end
	-- ([KIT_PARAM_CATEGORIES] 4, [KIT_LAST_ROW_CLIP]: the view's clip border, 2 a
	-- side, cut the fields' right edge and the last row's foot)
	local bh = body.height + 4
	local h = math.max(40, math.min(bh, room))
	local bw = body.width + 4 + (h < bh and view.verticalScrollBar.width + 4 or 0)
	if view.height ~= h or view.width ~= bw then
		view:SetScrollBarsVisible(false, h < bh)
		view:SetFixedSize(bw, h)
		log:info(string.format("kit editor: the inspector %d of %d tall", h, bh))
	end
end

inspector_window = function()
	if W.inspector and IV.view then
		IV.y = IV.view.viewPosition.y
	end
	if S.cat_top then
		S.cat_top, IV.y = nil, 0
	end
	-- [KIT_TOUCH_RULES_INSPECTOR] Another entity's sheet starts at its head: the
	-- last one's scroll hid kit/game_rules' chips, past the last sheet's rows
	if IV.of ~= S.primary then
		IV.of, IV.y = S.primary, 0
	end
	IV.view = nil
	drop("inspector")
	S.cost_text, S.cost_id = nil, nil
	local e, is_made = nil, false
	if S.primary then
		e, is_made = find(S.primary)
	end
	-- [KIT_ITEMS_TAB] the Items tab's item type's sheet instead
	local sig = NT.sig()
	local item = not sig and NT.tab() == "Items" and IT.sel
	if not E.editing or (folded("inspector") and not sig) or
			not (e or item) then
		return
	end
	local y = W.bar and W.bar.height + 12 or 40
	W.inspector = sig and window(magic.HA_LEFT, magic.VA_TOP, 0, 0) or
			window(magic.HA_RIGHT, magic.VA_TOP, -8, y)
	local view = W.inspector:CreateChild("ScrollView")
	local body = view:CreateChild("UIElement")
	body:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	if item then
		IT.sheet(body)
	else
		inspector(body, e, is_made)
	end
	view:SetStyleAuto()
	view:SetFocusMode(magic.FM_NOTFOCUSABLE)
	view.scrollBarsAutoVisible = false
	view:SetScrollBarsVisible(false, false)
	view.contentElement = body
	body:SetPosition(0, 0)
	view:SetFixedSize(body.width, body.height)
	S.inspector_h0 = body.height
	IV.view = view
	if sig then
		NT.sg.inspector(W.inspector, view)
	end
	fit_inspector()
	view.viewPosition = magic.IntVector2(0, IV.y)
end

-- [KIT_PARAM_CATEGORIES] The HUD view's one panel: the selected HUD element's
-- HUD parameters, beside it; a click on the background closes it
-- (S.hud_panel_off), a click on an element opens it again. Each frame it follows
-- the element; on each state it is drawn again, as the inspector
function NT.hud_panel_said(names)
	local line = table.concat(names, " ")
	if line ~= S.hud_panel_said then
		S.hud_panel_said = line
		log:info("kit editor: the HUD panel's parameters: " .. line)
	end
end

function NT.hud_panel_body(body, own)
	local keep = function(_, d)
		return NT.cat_of(d) == "hud"
	end
	if own then
		text(body, NT.OWN_NAMES[own] or own, magic.Color(1.0, 0.85, 0.3))
		local rid, comp = M.rules_entity()
		local re = rid and find(rid)
		local rc = re and re.components and re.components[comp + 1]
		if not rc then
			button(body, "Place kit/game_rules", function()
				send({op = "place", type = "kit/game_rules", pos = {0, 0, 0}})
			end)
			return
		end
		return NT.hud_panel_said(NT.params_form(body, re, comp + 1, rc,
				type_of(rc.type), NT.own_keep(own)))
	end
	local e = find(S.primary)
	if not e then
		return
	end
	text(body, NT.entity_label(e), magic.Color(1.0, 0.85, 0.3))
	local any = false
	for ci, c in ipairs(e.components or {}) do
		local t = type_of(c.type)
		for _, d in pairs(t.params or {}) do
			if NT.cat_of(d) == "hud" then
				any = true
				NT.hud_panel_said(NT.params_form(body, e, ci, c, t, keep))
				break
			end
		end
	end
	if not any then
		text(body, "No HUD parameters", DIM)
	end
end

function NT.hud_panel_build(key, own)
	local view_y = S.hud_panel_key == key and W.hud_panel and
			S.hud_panel_view.viewPosition.y or 0
	drop("hud_panel")
	local win = window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	win.visible = true
	W.hud_panel = win
	local view = win:CreateChild("ScrollView")
	local body = view:CreateChild("UIElement")
	body:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	NT.hud_panel_body(body, own)
	view:SetStyleAuto()
	view:SetFocusMode(magic.FM_NOTFOCUSABLE)
	view.scrollBarsAutoVisible = false
	view.contentElement = body
	body:SetPosition(0, 0)
	S.hud_panel_h0 = body.height
	view:SetFixedSize(1, 1)
	NT.hud_panel_fit(view)
	view.viewPosition = magic.IntVector2(0, view_y)
	S.hud_panel_view, S.hud_panel_key = view, key
end

-- Its height the body's, at most the screen's, the rest scrolled. A field's
-- warning grows the body and a layout never shrinks it again by itself: asked
-- to, while it is over the height it was built at
function NT.hud_panel_fit(view)
	local body = view.contentElement
	if body.height > S.hud_panel_h0 then
		body.height = 1
	end
	-- (the view's clip border, 2 a side: [KIT_LAST_ROW_CLIP])
	local bh = body.height + 4
	local h = math.min(bh, magic.ui.root.height - 28, S.hud_panel_limit or math.huge)
	local tall = h < bh
	local bw = body.width + 4 + (tall and view.verticalScrollBar.width + 4 or 0)
	if view.height ~= h or view.width ~= bw then
		view:SetScrollBarsVisible(false, tall)
		view:SetFixedSize(bw, h)
	end
end

-- Beside the element: of the sides it fits on, the one with most room. On none,
-- above or below scrolled to the room there (a short window), and when that is
-- too little to use, over the element, inside the screen
function NT.hud_panel_place(x, y, w, h)
	local win, root, gap = W.hud_panel, magic.ui.root, 6
	local view = S.hud_panel_view
	local pw, ph = win.width, win.height
	-- Its height unscrolled: what the sides are asked for, so that scrolling
	-- does not change the answer
	local chrome = ph - view.height
	local fh = view.contentElement.height + chrome
	local sides = {{"right", root.width - x - w, pw}, {"left", x, pw},
		{"below", root.height - y - h, fh}, {"above", y, fh}}
	local best, best_fits = nil, false
	for _, s in ipairs(sides) do
		local fits = s[2] >= s[3] + gap
		if not best or (fits and not best_fits) or (fits == best_fits and
				s[2] > best[2]) then
			best, best_fits = s, fits
		end
	end
	S.hud_panel_limit = nil
	if not best_fits then
		local v = sides[3][2] >= sides[4][2] and sides[3] or sides[4]
		if v[2] - gap - chrome >= 100 then
			best, S.hud_panel_limit = v, v[2] - gap - chrome
		end
	end
	if S.hud_panel_limit or best_fits then
		ph = math.min(fh, S.hud_panel_limit and S.hud_panel_limit + chrome or fh)
	end
	local px, py = x + math.floor((w - pw) / 2), y + math.floor((h - ph) / 2)
	if best[1] == "right" then
		px = x + w + gap
	elseif best[1] == "left" then
		px = x - pw - gap
	elseif best[1] == "below" then
		py = y + h + gap
	else
		py = y - ph - gap
	end
	px = math.max(0, math.min(root.width - pw, px))
	py = math.max(0, math.min(root.height - ph, py))
	win:SetPosition(px, py)
	local line = string.format("%s %s %d %d %d %d", S.hud_panel_key, best[1], px, py,
			pw, ph)
	if line ~= S.hud_panel_line then
		S.hud_panel_line = line
		log:info("kit editor: the HUD panel at " .. line .. string.format(
				", the element %d %d %d %d", x, y, w, h))
	end
end

-- Up to date with the view and the selection; rebuild: its values too
function NT.hud_panel(rebuild)
	local x, y, w, h, own
	if S.view == "hud" and E.editing and not S.hud_panel_off and
			M.hud_selected_rect then
		x, y, w, h, own = M.hud_selected_rect()
	end
	if not x then
		if W.hud_panel then
			drop("hud_panel")
			S.hud_panel_view, S.hud_panel_line = nil, nil
			log:info("kit editor: the HUD panel closed")
		end
		return
	end
	local key = own and "own:" .. own or tostring(S.primary)
	if rebuild or not W.hud_panel or key ~= S.hud_panel_key then
		NT.hud_panel_build(key, own)
	end
	NT.hud_panel_fit(S.hud_panel_view)
	NT.hud_panel_place(x, y, w, h)
end

-- A touchscreen's keys ([FP_TOUCH] 4): Undo, Delete and Escape's Cancel, at
-- the lower right
local function touch_bar()
	drop("touch")
	if not E.editing or not S.touch or NT.sig() then
		return
	end
	local b = window(magic.HA_RIGHT, magic.VA_BOTTOM, -8, -8, true)
	W.touch = b
	button(b, "Undo", function() send({op = "undo"}) end)
	button(b, "Delete", function() M.delete_selected() end)
	button(b, "Cancel", function() M.escape() end)
end

-- [KIT_EDIT_MODE_FPS] Whether the left panel shows nothing a refresh for why
-- changes: a selection ("select") or a state ("state", NT.state_changed its
-- keys) leave the Components tab as it is (17 ms to build again)
local function palette_stays(why)
	if not W.palette or not why or NT.tab() ~= "Components" or S.tab == "New" then
		return false
	end
	if why == "select" then
		return true
	end
	local c = NT.state_changed or {}
	return why == "state" and not (c.palette or c.prefabs or c.names or c.editing or
			c.can_edit)
end

-- Every panel drawn again ([KIT_EDIT_MODE_FPS] why: "select" or "state", what
-- stays the same not: the bar unless what it shows changed)
refresh = function(why)
	local bar = rebuild_bar(true) ~= false
	if bar or not palette_stays(why) then
		palette()
	end
	touch_bar()
	inspector_window()
	NT.hud_panel(true)
	NT.sg.refresh()
	people()
	show_log()
end

-- [KIT] stage 4l: an entity's cost, the last few seconds' share of Kit's
-- budget its components spent
function M.cost_line(id)
	local ents = E.costs and E.costs.entities
	if not ents then
		return "Cost: measuring"
	end
	local c = tonumber(ents[tostring(id)]) or 0
	return string.format("Cost: %.2f%% of Kit's budget", c)
end

-- The selected entity's log ([KIT] stage 4d): its c:log lines and Kit's
-- about it, its last ones, below on the right. Rebuilt alone as it grows
show_log = function()
	drop("log")
	local lines = E.editing and not NT.sig() and S.primary and
			E.logs[S.primary] or {}
	if #lines == 0 then
		return
	end
	-- Beside the inspector, not over its lower rows (a narrow screen's has no
	-- room beside it)
	local lw = window(magic.HA_RIGHT, magic.VA_BOTTOM,
			W.inspector and W.inspector.visible and not narrow() and
			-(W.inspector.width + 20) or -10,
			W.touch and -(W.touch.height + 16) or -50)
	W.log = lw
	text(lw, "Log of " .. S.primary .. ":", DIM)
	for i = math.max(1, #lines - 7), #lines do
		text(lw, tostring(lines[i]))
	end
end

-- Below at the left, out of the view's way ([KIT_EDITOR_PANELS]: the
-- builders' panel, small): the server's state, a refusal, the builds the
-- last End discarded, who edits and who may. Rebuilt alone as the
-- builders move (the inspector being typed in is left as it is)
people = function()
	drop("people")
	-- [KIT_SIGNALS_VIEW] A refusal over the table; the rest not in that view
	if NT.sig() then
		return NT.sg.status()
	end
	-- A narrow screen's panel opened is where it was
	if not E.editing or (narrow() and not folded("palette")) then
		return
	end
	local b = window(magic.HA_LEFT, magic.VA_BOTTOM, 10, -50)
	W.people = b
	text(b, (E.session or {}).kind == "bench" and "Only Save reaches the prefab" or
			E.persistent and "Edits change the world" or E.running and
			"Running: edits change the start and the round" or
			"Ended: edits change the start", DIM)
	if E.status ~= "" then
		text(b, E.status, WARN)
	end
	if S.under and find(S.under) then
		text(b, "New entities go under " .. S.under .. " (its inspector's " ..
				"Place under this)", DIM)
	end
	-- The builds the last End discarded, to keep until the next Run: all,
	-- or by player ("Choose...")
	local names = {}
	for name in pairs(E.discarded) do
		names[#names + 1] = name
	end
	table.sort(names)
	if #names > 0 and not E.running then
		local list = {}
		for _, name in ipairs(names) do
			list[#list + 1] = name .. " " .. tostring(E.discarded[name])
		end
		local dr = row(b)
		label(dr, "Builds discarded at End: " .. table.concat(list, ", "))
		button(dr, "Keep them", function()
			send({op = "keep"})
		end)
		button(dr, E.choose and "Done" or "Choose...", function()
			E.choose = not E.choose
			people()
		end)
		for _, name in ipairs(E.choose and names or {}) do
			local cr = row(b)
			label(cr, name .. ": " .. tostring(E.discarded[name]) .. " cells", 140)
			button(cr, "Keep " .. name .. "'s", function()
				send({op = "keep", names = {name}})
			end)
		end
	end
	-- The builders with the tools on, each by a blob in their colour (user,
	-- 2026-10-31: coloured text reads as a meaning, red as an error;
	-- Hearth's larger blob) and the text plain
	for _, bd in ipairs(E.builders) do
		local br = row(b)
		local dot = text(br, "●", color(bd.color, DIM))
		dot:SetFixedWidth(dot.minWidth)
		text(br, "Builder: " .. tostring(bd.name) .. (bd.you and " (you)" or
				"") .. ((tonumber(bd.sel) or 0) > 0 and ", on " .. bd.sel or "")
				):SetTextAlignment(magic.HA_LEFT)
	end
	-- The admin's: who here may edit
	for _, p in ipairs(E.state and E.state.admin and E.state.people or {}) do
		local pr = row(b)
		label(pr, p.name .. (p.admin and ": admin" or ""), 100)
		if not p.admin then
			button(pr, p.builder and "Builder: yes" or "Builder: no", function()
				send({op = "builder", name = p.name, on = not p.builder})
			end)
		end
	end
end

-- The selection: a click's, Shift's adding or taking out, a box's
-- [KIT_HUD_WALK_ONLY] The HUD is the Walk view's: to choose a UI component
-- is to go there.
-- simplified: kit/ui_* by name; kit/flag and kit/arena declare a ui too but
-- stand in the world, and so would a builder's type (no way to say yet)
function NT.walk_for_ui(ui)
	if ui and (S.view == "2d" or S.view == "3d") then
		set_view("walk")
	end
end

function NT.is_ui(t)
	return type(t) == "string" and t:sub(1, 7) == "kit/ui_"
end

function NT.palette_chosen(item)
	local ui = NT.is_ui(item.type)
	for _, n in ipairs(item.prefab and E.state.prefabs_ui or {}) do
		ui = ui or n == item.prefab
	end
	NT.walk_for_ui(ui)
end

local function select(id, add, by_tab)
	if not add then
		S.sel = {}
	end
	local out = false
	if id then
		if add and S.sel[id] then
			S.sel[id] = nil
			out = true
			if S.primary == id then
				S.primary = next(S.sel)
			end
		else
			S.sel[id] = true
			S.primary = id
			if not by_tab then
				touch(id)
			end
		end
	elseif not add then
		S.primary = nil
	end
	local e = id and find(id)
	local n = #sel_ids()
	log:info("kit editor: " .. (out and "took out " or "selected ") ..
			tostring(id or "none") .. " (" .. tostring(e and e.name) .. ")" ..
			(n > 1 and ", " .. n .. " in the selection" or ""))
	-- (not while Tab goes through them, nor a click adding to a selection)
	if e and not add and not by_tab then
		for _, c in ipairs(e.components or {}) do
			NT.walk_for_ui(NT.is_ui(c.type))
			-- [KIT_PARAM_CATEGORIES] one chosen in the list too
			if NT.is_ui(c.type) and (S.view == "walk" or S.view == "hud") then
				S.param_cat = "hud"
			end
		end
	end
	focus()
	refresh("select")
end
M.select = function(id, add)
	select(id, add)
end

-- The context menu ([KIT] stage 4e2): an entity's, a right click's or a
-- long press's, for the selection when it is in it
local function close_menu()
	drop("ctx")
end

-- A menu at x, y (UI units), kept on the screen whole. entries: a string is a
-- dim line, {text, fn} a button that closes the menu and calls fn
function NT.menu(entries, x, y)
	close_menu()
	local w = window(magic.HA_LEFT, magic.VA_TOP, x, y)
	W.ctx = w
	w.priority = 10
	for _, en in ipairs(entries) do
		if type(en) == "string" then
			text(w, en, DIM)
		else
			button(w, en[1], function()
				close_menu()
				en[2]()
			end)
		end
	end
	local rw, rh = magic.ui.root.width, magic.ui.root.height
	w:SetPosition(math.max(0, math.min(x, rw - w.width)),
			math.max(0, math.min(y, rh - w.height)))
end

-- A press on a panel, past the menu, closes it (in the Signals view
-- SG.pressed's). A press on the view has its own: it closes the menu and
-- is swallowed
function NT.menu_press(mx, my)
	local sc = magic.ui.scale
	if W.ctx and not NT.sig() and not inside(W.ctx, mx / sc, my / sc) then
		close_menu()
	end
end

function M.delete_selected()
	for _, id in ipairs(sel_ids()) do
		local e, is_made = find(id)
		-- [KIT_NESTING] one under another selected goes with it
		if e and not is_made and not NT.under_one_of(e, S.sel) then
			send({op = "delete", id = id})
		end
	end
end

-- [KIT_PREFAB_VOXELS] The voxel box (the Box tool's two corners) as
-- the server takes it, or nil
local function vbox()
	local b = S.vbox
	if not b or not b.a or not b.b then
		return nil
	end
	return {b.a[1], b.a[2], b.a[3], b.b[1], b.b[2], b.b[3]}
end

local function prefab_dialog(ids)
	drop("dialog")
	local w = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.dialog = w
	w.priority = 10
	-- [KIT_PREFAB_VOXELS] the Box tool's voxels too, their air replacing
	-- what is there or not
	local box = vbox()
	text(w, "Make a prefab of " .. #ids .. (#ids == 1 and " entity" or
			" entities") .. (box and " and the box's voxels" or ""))
	local r = row(w)
	label(r, "Prefab name:")
	edit(r, E.prefab_name, function(s)
		E.prefab_name = s
	end)
	if box then
		button(row(w), "Air replaces: " .. (E.prefab_air and "on" or "off"),
				function()
			E.prefab_air = not E.prefab_air
			prefab_dialog(ids)
		end, E.prefab_air)
	end
	local br = row(w)
	button(br, "Save prefab", function()
		send({op = "save_prefab", ids = #ids > 0 and ids or nil,
			box = box, air = box and (E.prefab_air or false) or nil,
			name = E.prefab_name})
		drop("dialog")
	end)
	button(br, "Cancel", function()
		drop("dialog")
	end)
end

M.prefab_dialog = prefab_dialog

-- [KIT_SCENES] The scene edited switched (the server takes the builder
-- there), and a new one made: its World the current one's copied, or a
-- blank one (the World's defaults)
function M.switch_scene(name)
	log:info("kit editor: to the scene " .. tostring(name))
	send({op = "scene", name = name})
end

function M.new_scene(name, copy)
	log:info("kit editor: a new scene " .. tostring(name) ..
			(copy and ", its World copied" or ", a blank World"))
	send({op = "new_scene", name = name, copy = copy and true or false})
end

E.scene_name = E.scene_name or ""
E.scene_copy = E.scene_copy ~= false
function M.scene_dialog()
	drop("dialog")
	local w = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.dialog = w
	w.priority = 10
	text(w, "A new scene: its own World and entities")
	local r = row(w)
	label(r, "Scene name:")
	edit(r, E.scene_name, function(s)
		E.scene_name = s
	end)
	button(row(w), E.scene_copy and "World: a copy of " .. current_scene() ..
			"'s" or "World: a blank one", function()
		E.scene_copy = not E.scene_copy
		M.scene_dialog()
	end, E.scene_copy)
	local br = row(w)
	button(br, "Make scene", function()
		M.new_scene(E.scene_name, E.scene_copy)
		drop("dialog")
	end)
	button(br, "Cancel", function()
		drop("dialog")
	end)
end

-- ---- [KIT_SOUNDS] The project's sounds (sounds.lua's M.sounds)

-- A dropdown's choices: "none" (""), the project's own by name, then
-- Kit's and the packages'; the value too when it names none of them (a
-- deleted one)
function M.sound_choices(value)
	local own, other = {}, {}
	for n, s in pairs(M.sounds or {}) do
		local list = (s.author == "kit" or s.package) and other or own
		list[#list + 1] = n
	end
	table.sort(own)
	table.sort(other)
	local out, has = {{"none", ""}}, value == nil or value == ""
	for _, list in ipairs({own, other}) do
		for _, n in ipairs(list) do
			out[#out + 1] = {n, n}
			has = has or n == value
		end
	end
	if not has and type(value) == "string" then
		out[#out + 1] = {value, value}
	end
	return out
end

-- A form's fields, each of type "sound" a dropdown of sound_choices()
function M.with_sounds(fields, values)
	local out = {}
	for i, f in ipairs(fields) do
		if f.type == "sound" then
			f = {name = f.name, label = f.label, type = "choice",
				choices = M.sound_choices(values[f.name])}
		end
		out[i] = f
	end
	return out
end

-- A name asked (a builder's sound, "<their name>/<name>"), then ok(name)
function NT.sound_name_dialog(title, name, ok)
	drop("dialog")
	local w = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.dialog = w
	w.priority = 10
	w:SetFixedWidth(math.min(360, magic.ui.root.width - 16))
	text(w, title)
	local f = {name = name}
	ui_utils.settings_form(w, {{name = "name", type = "text",
		max_length = 64}}, f, function(k, v) f[k] = v end, WIDGETS)
	local br = row(w)
	button(br, "OK", function()
		drop("dialog")
		ok(f.name)
	end)
	button(br, "Cancel", function()
		drop("dialog")
	end)
end

-- The designer (blip's) on a sound; its Save sends it as name
function NT.design(name, params)
	log:info("kit editor: designing sound " .. name)
	require("buildat/extension/blip").design(params, function(packed)
		send({op = "sound", name = name, params = packed})
	end)
end

-- A short name for a copy of `of`, one no sound has: <name>_2, _3...
function NT.copy_name(of)
	local base = tostring(of):match("[^/]*$")
	local taken = {}
	for n in pairs(M.sounds) do
		taken[n:match("[^/]*$")] = true
	end
	local i, cand = 2, base .. "_2"
	while taken[cand] do
		i = i + 1
		cand = base .. "_" .. i
	end
	return cand
end

M.on_sounds(function()
	if E.editing and NT.tab() == "Sounds" then
		palette()
	end
end)

-- The Sounds tab: "New sound..." (a name, then the designer; its Save
-- makes it), then each sound: Play, Edit (the designer; its Save writes
-- it back) and Delete for the project's own, Copy as new for every one
-- (Kit's and a package's are copied, not changed)
function NT.sounds(w)
	button(w, "New sound...", function()
		NT.sound_name_dialog("A new sound of yours", "my_sound", function(n)
			-- blip's own first sound (its pickup)
			NT.design(n, "blip1:AAAAVgDHjZmAAf_f_AAAAf_AAAAf_AAf_f___f_AAAAf_gAwG2s")
		end)
	end)
	local list = M.sound_choices()
	if #list == 1 then
		text(w, "No sounds", DIM)
	end
	for i = 2, #list do
		local n = list[i][2]
		local s = M.sounds[n]
		local own = s.author ~= "kit" and not s.package
		local r = row(w)
		label(r, n .. (own and "" or s.author == "kit" and " (Kit's)" or
				" (a package's)"), 150)
		-- Named for a drive: "sound play <name>"...
		button(r, "Play", function() M.play_sound(n) end):SetName(
				"sound play " .. n)
		if own then
			button(r, "Edit", function() NT.design(n, s.params) end):SetName(
					"sound edit " .. n)
		end
		button(r, "Copy as new", function()
			NT.sound_name_dialog("A copy of " .. n, NT.copy_name(n), function(c)
				send({op = "sound", name = c, params = s.params})
			end)
		end):SetName("sound copy " .. n)
		if own then
			button(r, "Delete", function()
				send({op = "sound_delete", name = n})
			end):SetName("sound delete " .. n)
		end
	end
end

-- [KIT] stage 4g: a builder's voxel type ("<their name>/<name>"), made or
-- its next version: a registered voxel's texture or an uploaded PNG's
local VOXEL_FIELDS = {
	{name = "name", type = "text", max_length = 64},
	{name = "texture", type = "texture"},
	{name = "kind", type = "choice",
		choices = {"solid", "leaves", "plant", "water"}},
	{name = "solid", type = "bool"},
	{name = "transparent", type = "bool"},
	{name = "light", type = "number", integer = true, min = 0, max = 15},
	{name = "friction", type = "number", min = 0, max = 10},
	-- [KIT_CTF] the blast strength it stands (0: any blast's; c:explode)
	{name = "blast_resist", type = "number", min = 0, max = 1000},
	{name = "surface", type = "text", max_length = 32},
	-- [KIT_TOOLS_1] its material group ("" none: dug at once, no drop) and
	-- the level a tool needs for the drop; both only under kit/game_rules'
	-- dig_by_tools
	{name = "group", type = "text", max_length = 32},
	{name = "level", type = "number", integer = true, min = 0, max = 15},
	-- [KIT_SOUNDS] its dig's and place's sounds
	{name = "sound_dig", type = "sound"},
	{name = "sound_place", type = "sound"},
	-- [KIT_CTF] what its dig drops ("" itself): a voxel or item type
	{name = "drop", type = "text", max_length = 129},
}

function M.voxel_dialog()
	drop("dialog")
	local w = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.dialog = w
	w.priority = 10
	-- A fixed width: the form's rows widen it past the screen otherwise
	w:SetFixedWidth(math.min(480, magic.ui.root.width - 16))
	local f = E.voxel_form
	text(w, "A voxel type of yours")
	ui_utils.settings_form(w, M.with_sounds(VOXEL_FIELDS, f), f, function(k, v)
		f[k] = v
	end, WIDGETS, {texture = E.state.textures or {}})
	local br = row(w)
	button(br, "Upload a PNG...", function()
		S.uploading = buildat.pick_file(".png")
	end)
	button(br, "Make", function()
		local j = {op = "voxel"}
		for k, v in pairs(f) do
			j[k] = v
		end
		send(j)
		drop("dialog")
	end)
	button(br, "Cancel", function()
		drop("dialog")
	end)
end

-- [KIT_TOOLS_1] A builder's item type ("<their name>/<name>"), made or
-- its next version: a preset's sheet (Kit's kit/sword, kit/pickaxe; any
-- item type) under the fields set here. dig is "group speed, ..."
local ITEM_FIELDS = {
	{name = "name", type = "text", max_length = 64},
	{name = "icon", type = "texture"},
	{name = "stack", type = "number", integer = true, min = 1, max = 999},
	{name = "use", type = "choice", choices = {"none", "melee", "use",
		"ranged"}},
	{name = "cooldown", type = "number", min = 0, max = 60},
	{name = "mode", type = "choice", choices = {"single", "auto", "burst"}},
	{name = "burst", type = "number", integer = true, min = 1, max = 20},
	{name = "charge", type = "number", min = 0, max = 10},
	{name = "damage", type = "number", min = 0, max = 1000000},
	{name = "damage_type", type = "text", max_length = 64},
	{name = "crit", type = "number", min = 1, max = 100},
	{name = "falloff", type = "number", min = 0, max = 1},
	{name = "knockback", type = "number", min = 0, max = 50},
	{name = "reach", type = "number", min = 0.5, max = 16},
	{name = "dig", type = "text", max_length = 200},
	{name = "level", type = "number", integer = true, min = 0, max = 15},
	{name = "uses", type = "number", integer = true, min = 0, max = 1000000},
	{name = "wear_dig", type = "number", integer = true, min = 0, max = 1000},
	{name = "wear_hit", type = "number", integer = true, min = 0, max = 1000},
	{name = "wear_shot", type = "number", integer = true, min = 0, max = 1000},
	{name = "repair", type = "text", max_length = 129},
	-- [KIT_TOOLS_2] ranged, loading, the look (a prefab's name: its parts
	-- and voxels) and its colour
	{name = "shot", type = "choice", choices = {"hitscan", "projectile"}},
	{name = "speed", type = "number", min = 1, max = 500},
	{name = "gravity", type = "number", min = 0, max = 100},
	{name = "lifetime", type = "number", min = 0.1, max = 30},
	{name = "spread", type = "number", min = 0, max = 45},
	{name = "pellets", type = "number", integer = true, min = 1, max = 32},
	{name = "range", type = "number", min = 1, max = 1000},
	{name = "recoil", type = "number", min = 0, max = 45},
	{name = "magazine", type = "number", integer = true, min = 0, max = 1000},
	{name = "reload", type = "number", min = 0, max = 60},
	{name = "reload_mode", type = "choice", choices = {"whole", "one"}},
	{name = "ammo", type = "text", max_length = 129},
	{name = "look", type = "text", max_length = 129},
	{name = "color", type = "text", max_length = 7},
	-- [KIT_SOUNDS] its sounds by action
	{name = "sound_swing", type = "sound"},
	{name = "sound_shot", type = "sound"},
	{name = "sound_hit", type = "sound"},
	{name = "sound_reload", type = "sound"},
	{name = "sound_break", type = "sound"},
}

-- The form from an item type's sheet (its dig as text)
local function item_form(preset, name)
	local f = {preset = preset, name = name or "my_item"}
	for k, v in pairs(M.item_types[preset] or {}) do
		f[k] = v
	end
	local dig = {}
	for g, sp in pairs(type(f.dig) == "table" and f.dig or {}) do
		dig[#dig + 1] = g .. " " .. tostring(sp)
	end
	table.sort(dig)
	f.dig = table.concat(dig, ", ")
	f.preset, f.name = preset, name or "my_item"
	return f
end

-- [KIT_ITEMS_TAB] An item type's sheet in the inspector (the Items tab's
-- selection), its buttons at the top, its fields in sections, each folded
-- by its button (at first the basics and its use's own open): Kit's and a package's copied as new (the
-- edits made here go into the copy), the project's own saved as its next
-- version, a new one ("New item type...") made from a preset
IT.SECTIONS = {
	{"Basics", {"icon", "stack", "use", "color", "look"}},
	{"Timing", {"cooldown", "mode", "burst", "charge"}},
	{"Damage", {"damage", "damage_type", "crit", "falloff", "knockback",
		"reach"}},
	{"Ranged", {"shot", "speed", "gravity", "lifetime", "spread", "pellets",
		"range", "recoil"}},
	{"Loading", {"magazine", "reload", "reload_mode", "ammo"}},
	{"Digging", {"dig", "level"}},
	{"Wear", {"uses", "wear_dig", "wear_hit", "wear_shot", "repair"}},
}
IT.open = {}

function IT.needs(sec, f)
	if sec == "Damage" then
		return f.use == "melee"
	elseif sec == "Ranged" then
		return f.use == "ranged"
	elseif sec == "Digging" then
		return (f.dig or "") ~= ""
	end
	return sec == "Basics"
end

-- ITEM_FIELDS' as the sheet shows them: ammo and repair the item picker,
-- look a prefab's
function IT.fields(list, f)
	local out = {}
	for i, fd in ipairs(list) do
		if fd.name == "ammo" or fd.name == "repair" then
			fd = {name = fd.name, type = "choice",
				choices = IT.choices(f[fd.name])}
		elseif fd.name == "look" then
			fd = {name = "look", type = "choice", choices = {{"none", ""}}}
			for _, p in ipairs(E.state.prefabs or {}) do
				fd.choices[#fd.choices + 1] = {M.shown(p), p}
			end
		end
		out[i] = fd
	end
	return M.with_sounds and M.with_sounds(out, f) or out
end

-- A sheet's form sent: Make, Save, a copy
function IT.send(f, name)
	local j = {}
	for k, v in pairs(f) do
		j[k] = v
	end
	j.format, j.author, j.version, j.look_data, j.package = nil, nil, nil,
			nil, nil
	j.op, j.name = "item", name
	send(j)
end

function IT.sheet(w)
	local n = IT.sel
	local new, sheet = n == "", M.item_types[n]
	if not new and not sheet then
		text(w, "Item type " .. n .. ": not here (yet)", DIM)
		return
	end
	if not IT.form then
		IT.preset = IT.preset or "kit/sword"
		IT.form = item_form(new and IT.preset or n, new and "my_item" or
				n:match("[^/]*$"))
		IT.form.preset = new and IT.preset or sheet.preset
	end
	local f, own = IT.form, not new and IT.own(n)
	text(w, new and "A new item type of yours" or "Item type " ..
			M.shown(n))
	text(w, new and "From a preset, its fields changed here" or own and
			"The project's own: Save makes its next version" or
			(sheet.package and "A package's" or "Kit's") ..
			": Copy as new to change it", DIM)
	local br = row(w)
	if new then
		button(br, "Make", function()
			IT.send(f, f.name)
			IT.sel, IT.form = IT.me() .. "/" .. tostring(f.name), nil
			log:info("kit editor: item " .. IT.sel .. " made")
		end)
	elseif own then
		button(br, "Save", function()
			IT.send(f, n:match("[^/]*$"))
			IT.form = nil
			log:info("kit editor: item " .. n .. " saved")
		end)
	end
	if not new then
		button(br, "Copy as new", function()
			IT.copy(n, f)
		end)
	end
	if new then
		local presets = {}
		for _, p in ipairs(IT.names()) do
			presets[#presets + 1] = {M.shown(p), p}
		end
		ui_utils.settings_form(w, {{name = "name", type = "text",
				max_length = 64}, {name = "preset", type = "choice",
				choices = presets}}, f, function(k, v)
			if k == "preset" then
				IT.preset, IT.form = v, item_form(v, f.name)
				return inspector_window()
			end
			f[k] = v
		end, WIDGETS)
	end
	-- The icon: a voxel's or an upload's texture, "" none (a text label)
	local tex = {""}
	for _, t in ipairs(E.state.textures or {}) do tex[#tex + 1] = t end
	local by, placed, secs = {}, {name = true}, {}
	for _, fd in ipairs(ITEM_FIELDS) do
		by[fd.name] = fd
	end
	for _, sec in ipairs(IT.SECTIONS) do
		local list = {}
		for _, k in ipairs(sec[2]) do
			list[#list + 1] = by[k]
			placed[k] = true
		end
		secs[#secs + 1] = {sec[1], list}
	end
	-- The fields no section names (its sounds, [KIT_SOUNDS]) last
	local rest = {}
	for _, fd in ipairs(ITEM_FIELDS) do
		if not placed[fd.name] then
			rest[#rest + 1] = fd
		end
	end
	if #rest > 0 then
		secs[#secs + 1] = {"More", rest}
	end
	for _, sec in ipairs(secs) do
		local name, open = sec[1], IT.open[sec[1]]
		if open == nil then
			open = IT.needs(name, f)
		end
		button(w, (open and "- " or "+ ") .. name, function()
			IT.open[name] = not open
			log:info("kit editor: item section " .. name ..
					(open and " folded" or " open"))
			inspector_window()
		end, open):SetName("section " .. name)
		if open then
			ui_utils.settings_form(w, IT.fields(sec[2], f), f,
					function(k, v)
				f[k] = v
				log:info("kit editor: item " .. (new and "(new)" or n) ..
						" " .. k .. " = " .. tostring(v))
				if k == "use" then
					inspector_window()
				end
			end, WIDGETS, {texture = tex})
		end
	end
end

local function context_menu(id, mx, my)
	close_menu()
	local e, is_made = find(id)
	if not e or is_made then
		return
	end
	if not S.sel[id] then
		select(id)
	end
	local ids = sel_ids()
	local sc = magic.ui.scale
	local entries = {#ids > 1 and #ids .. " selected" or name_of(e),
		{"Delete", M.delete_selected},
		{"Duplicate", function()
			send({op = "duplicate", ids = ids, by = {1, 0, 0}})
		end},
		{"Make prefab...", function() prefab_dialog(ids) end}}
	if E.running then
		entries[#entries + 1] = {"Restart this", function()
			for _, sid in ipairs(ids) do
				local se = find(sid)
				for ci in ipairs(se and se.components or {}) do
					send({op = "restart", id = sid, comp = ci - 1})
				end
			end
		end}
	end
	NT.menu(entries, math.floor(mx / sc), math.floor(my / sc))
	log:info("kit editor: the menu of " .. id .. " (" .. #ids .. " selected)")
end

-- ---- The views ([FP] Views): set_view, the cameras placed each frame
local function apply_viewport()
	local want = E.editing and S.view or "walk"
	if want == "hud" then
		want = "walk"
	end
	if S.shown_view == want then
		return
	end
	S.shown_view = want
	-- [KIT_SIGNALS_VIEW] The world in the view's own View3D
	if want == "signals" then
		magic.set_preferred_viewports({NT.sg.world_viewport()})
		if O.set_camera then
			O.set_camera(NT.sg.node())
		end
		return
	end
	local node, cam = active_camera()
	-- The walk view with the controls' effects (controls.lua).
	-- [KIT_EDITOR_VIEW_HDR] The 3D and 2D views draw by the app's walk
	-- view's render path (skeldat's HDR one: its exposure and tonemap);
	-- the default path under an app's HDR was a frame of raw radiance,
	-- white at noon. [KIT_SK_2D_EMPTY] HDR off for 2D (floorplanner's) is
	-- as white: skeldat's light is in the reference's radiances.
	local vp
	if want == "walk" then
		vp = O.viewport and O.viewport() or M.viewport(O.scene, cam)
	else
		vp = magic.Viewport:new(O.scene, cam)
		if O.viewport then
			vp.renderPath = O.viewport().renderPath
		else
			-- [KIT_LIGHTING] the composition's lighting's (environment.lua)
			M.lit_viewport(vp, "editor", nil, node)
		end
	end
	magic.set_preferred_viewports({vp})
	if O.set_camera then
		O.set_camera(node)
	end
end

-- [KIT_SK_2D_EMPTY] The ground's cell y under a point: the first cell
-- over the app's voxels (or the heightmap) below it, else ground_y. The
-- plan's first cut is from it: skeldat's ground is at 6, under the
-- constant ground_y's cut of 1.5, and its plan was empty.
-- simplified: 64 cells down at most
local function ground_under(p)
	if O.solid then
		local solid = M.with_terrain(O.solid)
		local x, z = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
		local y0 = math.floor(p.y + 0.5)
		for y = y0, y0 - 64, -1 do
			if solid(x, y, z) then
				return y + 1
			end
		end
	end
	return O.ground_y
end

-- The free camera from the app's: where it is, looking as it does
local function cam3d_from_app()
	local p, d = O.camera.worldPosition, O.camera.worldDirection
	S.pos = {x = p.x, y = p.y, z = p.z}
	S.yaw = math.deg(math.atan2(d.x, d.z))
	S.pitch = math.deg(math.asin(math.max(-1, math.min(1, -d.y))))
end

set_view = function(v)
	if not VIEW_NAMES[v] then
		return
	end
	-- [KIT_HUD_VIEW] Adjusting the HUD: the walk camera held still, no
	-- panels, the world not to be clicked; out to the view it came from
	if v == "hud" and S.view ~= "hud" then
		S.before_hud = S.view
		S.hud_panel_off = nil
		close_menu()
		drop("dialog")
	end
	-- [KIT_SIGNALS_VIEW] Out to the view it came from, past a HUD view
	if v == "signals" and S.view ~= "signals" then
		S.before_signals = S.view == "hud" and S.before_hud or S.view
		close_menu()
		drop("dialog")
		E.link, S.placing = nil, nil
	end
	-- (a link's menu or the palette's popup do not outlive the view)
	if S.view == "signals" and v ~= "signals" then
		close_menu()
	end
	for _, w in pairs(W) do
		w.visible = v ~= "hud"
	end
	if v == "3d" and not S.pos then
		cam3d_from_app()
	end
	if v == "2d" and not S.cut then
		local p = O.camera.worldPosition
		S.cx, S.cz = p.x, p.z
		S.cut = ground_under(p) + 1.5
	end
	if v ~= S.view then
		S.crosshair = false
		S.from_plan = nil
	end
	S.view = v
	apply_viewport()
	log:info("kit editor: the view is " .. VIEW_NAMES[v])
	refresh()
	changed()
end
M.set_view = function(v)
	set_view(v)
end

-- [KIT_WALK_HERE] The walker put where the view's camera is, looking as it
-- does, and the Walk view; in 2D on the ground under the plan's middle,
-- the walker's yaw kept, level. In Walk and HUD nothing (false).
-- simplified: the 3D or Signals camera's place as it is, in the air or in a
-- wall too (the walker falls or is pushed out as the server puts it)
walk_here = function()
	local v = S.view
	if v ~= "2d" and v ~= "3d" and v ~= "signals" then
		log:info("kit editor: walk here: nothing in " .. VIEW_NAMES[v])
		return false
	end
	local feet
	if v == "2d" then
		local p = magic.Vector3(S.cx or 0, S.cut or 0, S.cz or 0)
		feet = M.walk_here(p, nil, 0)
		feet[2] = ground_under(p) - 0.5
	else
		local node = v == "signals" and NT.sg.node() or active_camera()
		local p, d = node.worldPosition, node.worldDirection
		feet = M.walk_here(p, math.deg(math.atan2(d.x, d.z)),
				math.deg(math.asin(math.max(-1, math.min(1, -d.y)))))
	end
	send({op = "walk_here", pos = feet})
	log:info(string.format("kit editor: walk here from %s at %.2f,%.2f,%.2f",
			VIEW_NAMES[v], feet[1], feet[2], feet[3]))
	set_view("walk")
	return true
end

-- [WB_EDITOR_VIEW_MEMORY] kit.remember(key): how this user left the
-- editor, kept on this machine under key (the app's: Workbench's
-- project), in the storage of the server's game (buildat.storage_*, the
-- client's user directory; never the server's, so never in a published
-- project): edit mode or play, the view, the 3D camera, the tabs (the
-- panel's, the palette's, the list's), the parameters' chip and whether the
-- Signals view hides its descriptions. Edit mode is asked for again
-- once the rights are known; the view and the tab put back as edit mode
-- comes on. Running or Stopped is not kept here: it is the server's (the
-- save's session, which a restart resumes), and a Stop asked by a memory
-- would throw a round away.
-- Written at most once a second (MEM.every), at once when edit mode changes,
-- and at the client's exit.
-- simplified: leaving for the launcher within a second of a change of view,
-- tab or camera loses that change (the game gets no word of a leave; a hook
-- in leave_to_menu if it matters); the palette's New tab not restored (its
-- fetch asks about the network)
local MEM = {every = 1}
function MEM.name()
	return "kit_editor_" .. MEM.key:gsub("[^%w_%-]", function(c)
		return string.format(".%02x", c:byte())
	end)
end

-- After an edit state (was: edit mode before it), and as the key comes
function MEM.restore(was)
	if not MEM.key then
		return
	end
	if MEM.edit == "asked" then
		MEM.edit = nil -- the server's answer
	elseif MEM.edit == "want" and E.state_seen then
		MEM.edit = E.can_edit and not E.editing and "asked" or nil
		if MEM.edit then
			log:info("kit editor: remembered: edit mode")
			M.set_tools(true)
		end
	end
	local t = MEM.view
	if t and E.editing and not was then
		MEM.view = nil
		if VIEW_NAMES[t.view or ""] then
			set_view(t.view)
		end
		if t.tab and NT.tab_shown(t.tab) and t.tab ~= NT.tab() then
			NT.choose(t.tab)
		end
	end
end

function M.remember(key)
	MEM.key = key
	local t = {}
	for k, v in (buildat.storage_read(MEM.name()) or ""):gmatch(
			"([%w_]+) ([^\n]*)") do
		t[k] = v
	end
	MEM.saved, MEM.at = nil, 0
	MEM.edit = t.mode == "edit" and "want" or nil
	MEM.view = t
	local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
	local yaw, pitch = tonumber(t.yaw), tonumber(t.pitch)
	if x and y and z and yaw and pitch then
		S.pos, S.yaw, S.pitch = {x = x, y = y, z = z}, yaw, pitch
	end
	if t.list_tab == "Game-wide" or t.list_tab == "Scene" or
			t.list_tab == "Positioned" then
		S.list_tab = t.list_tab
	end
	if t.palette_tab == "All" or t.palette_tab == "Favourites" then
		S.tab = t.palette_tab
	end
	S.sg_about_hidden = t.sg_about == "hidden" or nil
	for _, c in ipairs(NT.CATS) do
		if t.param_cat == c[1] then
			S.param_cat = c[1]
		end
	end
	log:info("kit editor: remembered for " .. key .. ": " ..
			(next(t) and (t.mode or "play") .. ", " .. tostring(t.view) ..
			", " .. tostring(t.tab) .. (S.pos and string.format(
			", the 3D camera at %.2f %.2f %.2f", S.pos.x, S.pos.y, S.pos.z) or
			"") or "nothing"))
	MEM.restore(false)
end

-- Each frame: written when it changed, at most every MEM.every seconds
-- unless edit mode changed or now (the client's exit)
function MEM.tick(dt, now)
	MEM.at = (MEM.at or 0) + dt
	local old = MEM.last or {}
	local mode = (E.editing or MEM.edit) and "edit" or "play"
	if not MEM.key or not now and MEM.at < MEM.every and
			mode == (old.mode or mode) then
		return
	end
	MEM.at = 0
	local t = {mode = mode}
	-- Until edit mode put them back, the remembered; out of it, the last
	local live = E.editing and not MEM.view
	t.view = live and (S.view == "hud" and S.before_hud or S.view) or
			(MEM.view or {}).view or old.view
	t.tab = live and NT.tab() or (MEM.view or {}).tab or old.tab
	t.list_tab = S.list_tab
	t.palette_tab = S.tab
	t.param_cat = S.param_cat
	t.sg_about = S.sg_about_hidden and "hidden" or nil
	if S.pos then
		t.x, t.y, t.z = string.format("%.3f", S.pos.x),
				string.format("%.3f", S.pos.y), string.format("%.3f", S.pos.z)
		t.yaw, t.pitch = string.format("%.3f", S.yaw),
				string.format("%.3f", S.pitch)
	end
	local lines = {}
	for _, k in ipairs({"mode", "view", "tab", "list_tab", "palette_tab",
			"param_cat", "sg_about", "x", "y", "z", "yaw", "pitch"}) do
		if t[k] then
			lines[#lines + 1] = k .. " " .. t[k]
		end
	end
	local data = table.concat(lines, "\n") .. "\n"
	if data ~= MEM.saved then
		MEM.saved, MEM.last = data, t
		local ok, err = buildat.storage_write(MEM.name(), data)
		if not ok then
			log:warning("kit editor: the editor's memory: " .. tostring(err))
		end
	end
end

-- [KIT_PLAN_CAPS] What the plan's cut goes through, drawn in 2D (caps.lua)
local caps
do
	local ok, err, install = buildat.run_script_file("kit/caps.lua")
	assert(ok and type(install) == "function", "kit: caps.lua: " ..
			tostring(err))
	caps = install({O = O, S = S, P = P, color = color, log = log})
end

-- [KIT_SIGNALS_VIEW] The Signals view's table and viewport (signals.lua)
do
	local ok, err, install = buildat.run_script_file("kit/signals.lua")
	assert(ok and type(install) == "function", "kit: signals.lua: " ..
			tostring(err))
	install({K = K, S = S, W = W, NT = NT, IV = IV, send = send, window = window,
		find = find, entities = entities, all_entities = all_entities,
		type_of = type_of, typed = typed, signal_kind = signal_kind,
		drawn_at = drawn_at, narrow = narrow, LONG_PRESS_US = LONG_PRESS_US,
		refresh = function() refresh() end})
end

-- [KIT_PREFAB_ROOT] A placed prefab's root, the palette's menu on a prefab, the
-- stamp's dialog (prefabs.lua)
do
	local ok, err, install = buildat.run_script_file("kit/prefabs.lua")
	assert(ok and type(install) == "function", "kit: prefabs.lua: " ..
			tostring(err))
	install({K = K, S = S, W = W, NT = NT, send = send, window = window,
		find = find, drop = drop, drawn_at = drawn_at, vbox = vbox, BX = BX})
end

local function place_cameras()
	local w, h = screen_size()
	cam2d.orthoSize = S.span
	cam2d.aspectRatio = w / math.max(1, h)
	-- [KIT_PLAN_CAPS] A hair under the cut: an orthographic camera's near
	-- clip is 0 in Urho3D, and a voxel's top at the cut (the cut's layer's,
	-- capped) showed through its cap in patches
	cam2d_node.position = magic.Vector3(S.cx,
			(S.cut or (O.ground_y + 1.5)) - caps.CAM_UNDER, S.cz)
	if S.pos then
		cam3d.aspectRatio = w / math.max(1, h)
		cam3d_node.position = magic.Vector3(S.pos.x, S.pos.y, S.pos.z)
		cam3d_node.rotation = rot3d()
	end
end

local function typing()
	local f = magic.ui.focusElement
	return f ~= nil and f:GetTypeName() == "LineEdit"
end

local function key_held(k)
	return magic.input:GetKeyDown(k)
end

-- The movement keys ([FP]'s move_camera): 2D pans (with a selection the
-- keys move it, a press at a time), 3D flies (the faster the higher), the
-- arrows turn it with nothing selected; walking is the app's
local function move_camera(dt)
	-- [KIT_DROPDOWN_ARROWS_MOVE] an open dropdown's popup has the arrows
	if typing() or key_held(magic.KEY_LCTRL) or key_held(magic.KEY_RCTRL) or
			(E.menu and E.menu.held()) or ui_utils.dropdown_open() then
		return
	end
	local shift = key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT)
	local f, r, u = 0, 0, 0
	-- [KIT_INPUT_ACTIONS] the keys play's (input.lua)
	local held = M.key_down
	if held("forward") then f = f + 1 end
	if held("back") then f = f - 1 end
	if held("right") then r = r + 1 end
	if held("left") then r = r - 1 end
	if S.view == "2d" then
		if next(S.sel) then
			return
		end
		local k = S.span * dt
		S.cx, S.cz = S.cx + r * k, S.cz + f * k
		return
	end
	if S.view ~= "3d" then
		return
	end
	if not next(S.sel) then
		local turn, tilt = 0, 0
		if held("nudge_right") then turn = turn + 1 end
		if held("nudge_left") then turn = turn - 1 end
		if held("nudge_forward") then tilt = tilt + 1 end
		if held("nudge_back") then tilt = tilt - 1 end
		local rate = (shift and 180 or 60) * dt
		S.yaw = S.yaw + turn * rate
		S.pitch = math.max(-89, math.min(89, S.pitch - tilt * rate))
	end
	if held("jump") then u = u + 1 end
	if held("down") then u = u - 1 end
	-- [KIT_PLAYTEST_TWEAKS] as fast as the plan pans at the zoom that sees
	-- as much: the ground's width across the view from the camera's height
	-- simplified: the height above the ground's level, not the voxels or
	-- the heightmap under it
	local h = S.pos.y - (O.ground_y - 0.5)
	local speed = math.max(4, 2 * h * math.tan(math.rad(cam3d.fov) / 2)) *
			(shift and 3 or 1) * dt
	local yaw = math.rad(S.yaw)
	S.pos = {x = S.pos.x + (math.sin(yaw) * f + math.cos(yaw) * r) * speed,
		y = S.pos.y + u * speed,
		z = S.pos.z + (math.cos(yaw) * f - math.sin(yaw) * r) * speed}
end

-- What a right or middle drag in 3D turns about or pans by: the point the
-- pointer is on, or where its ray meets the ground
local function camera_pivot(mx, my)
	local o, v = M.screen_ray(mx, my)
	local p = pick(mx, my, nil, true)
	if p and p.t then
		return o + v * p.t
	end
	return plane_at(o, v, O.ground_y - 0.5)
end

-- A 3D pan's start: the height it slides at, the pointer's point's
-- (user's playtest, 2026-10-31: in the XZ plane, as floorplanner's)
local function pan3d_start(mx, my)
	local p = camera_pivot(mx, my)
	return {dist = p and (p - cam3d_node.position):Length() or 5,
		y = p and p.y or O.ground_y - 0.5,
		from = {x = S.pos.x, y = S.pos.y, z = S.pos.z}}
end

-- Whether the 3D camera looks as the plan does: straight down, north up
-- within 10 degrees
local function plan_aligned()
	local off = (S.yaw % 360 + 180) % 360 - 180
	return S.pitch >= 89.5 and math.abs(off) <= 10
end

-- [KIT_EDITOR_LOCALS] The rest of the editor: ports, press and drag, the
-- terrain and voxels tools, mouse, fingers and keys, guides, drawing and
-- M.editor (editor_input.lua)
do
	local ok, err, install = buildat.run_script_file("kit/editor_input.lua")
	assert(ok and type(install) == "function", "kit: editor_input.lua: " ..
			tostring(err))
	terrain_panel = install({aitta = aitta, ANGLE_STEPS = ANGLE_STEPS,
		angle_text = angle_text, apply_viewport = apply_viewport,
		begin_link = begin_link, BRUSH_NAMES = BRUSH_NAMES, BRUSHES = BRUSHES,
		button = button, BX = BX, camera_pivot = camera_pivot, caps = caps,
		changed = changed, close_menu = close_menu, color = color,
		context_menu = context_menu, DIM = DIM, DRAG_PX = DRAG_PX,
		drawn_at = drawn_at, drop = drop, E = E, ED = ED, entities = entities,
		find = find, fit_inspector = fit_inspector, focus = focus,
		GRID_STEPS = GRID_STEPS, grid_text = grid_text, ground_at = ground_at,
		inside = inside, inspector_window = inspector_window, K = K,
		key_held = key_held, label = label, log = log, log_bar = log_bar,
		LONG_PRESS_US = LONG_PRESS_US, M = M, made = made, magic = magic,
		make_cameras = make_cameras, MAX_BRUSH = MAX_BRUSH, MAX_RAY = MAX_RAY,
		MEM = MEM, move_camera = move_camera, name_of = name_of,
		narrow = narrow, network = network, NT = NT, O = O, over_ui = over_ui,
		P = P, palette = palette, palette_at = palette_at,
		pan3d_start = pan3d_start, people = people, pick = pick,
		place_cameras = place_cameras, place_cell = place_cell,
		PLAN_3D_MAX_H = PLAN_3D_MAX_H, plan_aligned = plan_aligned,
		plane_at = plane_at, preview = preview, px = px,
		rebuild_bar = rebuild_bar, refresh = refresh,
		release_preview = release_preview, RIGHT_CLICK_PX = RIGHT_CLICK_PX,
		rot3d = rot3d, round = round, row = row, S = S,
		screen_size = screen_size, sel_ids = sel_ids, select = select,
		send = send, set_view = set_view, show_log = show_log,
		SNAP_PX = SNAP_PX, STYLE = STYLE, T = T, text = text,
		to_screen = to_screen, touch = touch, type_of = type_of,
		typing = typing, ui_utils = ui_utils, v3 = v3, vbox = vbox,
		VIEW_KEYS = VIEW_KEYS, voxel_names = voxel_names, W = W,
		window = window})
end
end
-- vim: set noet ts=4 sw=4:
