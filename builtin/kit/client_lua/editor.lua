-- Buildat: builtin/kit/client_lua/editor.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 3, Kit's editor on the client (builtin/kit/api.h says what
-- the server takes); its UX apps/floorplanner's ([KIT] stage 4e2: "do what
-- floorplanner does"). module.lua runs this file with what it shares.
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
--   - **The palette** (left): a type or prefab dragged onto the view goes
--     where it is let go (its ghost there meanwhile), or clicked it is
--     placed by the clicks on the view until Escape, a right click or a
--     click on it again (floorplanner's Object tool); its Voxel list puts
--     a voxel type in hand (O.pick_voxel(name), the app's placing) and
--     the voxels tool on, "none" away; and "New voxel type..." makes a
--     builder's own: a texture (Kit's or an uploaded PNG), kind, solid,
--     transparent, light, friction, surface
--   - **The voxels tool** (V, or Voxels by the palette's title; an app
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
--     while Ended; what it emitted is shown a moment ("→ opened")
--   - every entity drawn as a box, the selected ones yellow, links as
--     lines, and a type's gizmo (a sphere or a box), in edit mode only
--   - the admin's: who is here, each "Builder: yes/no" to grant or take
--     edit rights; ([KIT] stage 4c) the builders with the tools on, each
--     in a colour: another's selection outlined in theirs with their name
--     over it, their cursor a cross; the entities listed to select (the
--     game-wide ones, on the app root; "Hide positioned entities" off,
--     all), a list that scrolls, kept under the palette; "Save as start" (the bar, Running); the builds the
--     last End discarded until the next Run: "Keep them", or "Choose..."
--     a player's; "Always keep builds"
--   - **A touchscreen** (BUILDAT_TOUCH=1, [FP_TOUCH]'s): a tap is a click,
--     a finger dragged on the selection moves it (on a port links, on the
--     knob turns), elsewhere it moves the view (2D: pans; 3D: pans; two
--     fingers pinch to zoom, in 2D pan together and in 3D orbit round the
--     middle; walking: the app's), held still it is the right click; the
--     bar at the lower right: Undo, Delete, Cancel (Escape); the top bar's
--     Menu; the panels folded on a narrow screen, the bar's Palette and
--     Inspector open one
-- Kit's top bar, for a builder: the tools ("Edit", "Play mode" while they
-- are on; F6; play mode Runs the game if it has Ended) and the server's
-- state ("Run" while Ended, "End" while Running: End puts the start
-- back; [KIT_PLAYTEST_TWEAKS], Play and Stop before);
-- kit.editor{bar = false} leaves it out of play for an app's own menu
-- (the tools always have theirs): kit.can_edit(), kit.editing(),
-- kit.running() (and kit.by(), who), and kit.set_tools(on),
-- kit.toggle_tools(), kit.play(), kit.stop(), kit.save_as_start() do what
-- the bar does; kit.on_change(fn) calls fn() as any of the states changes.
-- kit.add_menu_items(menu) puts Edit and Run/End (a builder's) and
-- Credits... (everyone's) in extensions/
-- pause_menu's menu and Kit's Escape first (kit.escape(): the context
-- menu, a drag, placing, a pending link, the crosshair; true when taken).
-- kit.view() ("2d", "3d" or "walk": the app walks only in "walk" while
-- editing), kit.looking() (the editor's crosshair: the app's mouse looks).
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
			surface = ""}}) do
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
	local EDITS = {set = true, move = true, link = true, unlink = true}
	send = function(j)
		if EDITS[j.op] then
			for _, id in ipairs(j.ids or {j.id}) do
				touch(id)
			end
		end
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
local LONG_PRESS_US = 500000
local VIEW_NAMES = {["2d"] = "2D", ["3d"] = "3D", walk = "Walk"}
local VIEW_KEYS = {["2d"] = "F1", ["3d"] = "F2", walk = "F3"}
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

-- An entity's cell is the voxel at its position, centred on it
local function center(e)
	return magic.Vector3(e.pos[1], e.pos[2], e.pos[3])
end

-- Where it is drawn: an edit's preview (P.preview[id] = {x, y, z, yaw},
-- till: let go, until the node is there), else its node's, else its row's
local function drawn_at(e)
	local pv = P.preview[e.id]
	if pv then
		return magic.Vector3(pv[1], pv[2], pv[3])
	end
	local n = P.nodes[e.id]
	return n and n.node.position or center(e)
end

-- A drag's preview of an entity: moved by d, turned by turn
local function preview(e, d, turn)
	P.preview[e.id] = {e.pos[1] + d[1], e.pos[2] + d[2], e.pos[3] + d[3],
		(e.yaw or 0) + turn}
end

-- The previews let go of: shown until the server's nodes are there
local function release_preview()
	local till = buildat.get_time_us() + 2000000
	for _, pv in pairs(P.preview) do
		pv.till = pv.till or till
	end
end

local function name_of(e)
	return tostring(e and e.name or "?")
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
end

local function screen_size()
	local sc = magic.ui.scale
	return magic.ui.root.width * sc, magic.ui.root.height * sc
end

local function active_camera()
	if not E.editing or S.view == "walk" then
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
			(E.menu ~= nil and E.menu.held())
end

M.over_ui = over_ui

local refresh, people, show_log, rebuild_bar, set_view, terrain_panel
local inspector_window
local voxel_names

-- [KIT] stage 4f: the terrain tool's state: the brush, its size (cells)
-- and strength, the biome (nil: the World's), the stroke being drawn
-- (its id, the last dab and when, a fill's corner, the level)
local T = {brush = "raise", size = 3, strength = 2, biome = nil,
	stroke = nil}
local BRUSHES = {"raise", "lower", "smooth", "flatten", "paint", "fill",
	"decorate"}
local BRUSH_NAMES = {raise = "Raise", lower = "Lower", smooth = "Smooth",
	flatten = "Flatten", paint = "Paint", fill = "Fill", decorate = "Decorate"}
local MAX_BRUSH = 12
M.T = T
local brush_at, stroke_begin, stroke_move, stroke_end, draw_brush
-- [KIT_VOXEL_EDITS] The edited sections ("kit:edited": list), the
-- terrain panel's rows of them ({el, s}), its view and where it was
-- scrolled, and the section hovered
local ED = {list = nil, rows = {}, view = nil, y = 0, hover = nil}
local ED_HEIGHT = 200

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

rebuild_bar = function()
	drop("bar")
	bar_items, bar_log = {}, false
	if not E.can_edit or (not E.editing and O.bar == false) then
		return
	end
	-- The tools' at the top left, as floorplanner's toolbar
	local w = E.editing and window(magic.HA_LEFT, magic.VA_TOP, 8, 4, true) or
			window(magic.HA_CENTER, magic.VA_TOP, 0, 4, true)
	W.bar = w
	if not E.editing then
		button(w, "Edit", M.toggle_tools)
		run_end(w)
		return
	end
	w:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(6, 6, 6, 6))
	bar_row, bar_used, bar_first = row(w), 0, true
	bar_room = magic.ui.root.width - 16 - 12
	if O.menu then
		bar_button("Menu", "Esc", function()
			O.menu()
		end)
	end
	local views = {}
	for _, v in ipairs({"2d", "3d", "walk"}) do
		views[#views + 1] = {VIEW_NAMES[v] .. (S.touch and "" or
				" (" .. VIEW_KEYS[v] .. ")"), v}
	end
	-- Not measured on the side (a dropdown made is kept by ui_utils): the
	-- second thing in the first row
	local d = ui_utils.dropdown(bar_row, views, S.view, function(v)
		set_view(v)
	end, {height = 24})
	bar_used = bar_used + math.max(d.minWidth, 90) + 4
	-- [KIT_SCENES] the scene edited, switched by the list; New scene...
	local scenes = E.state and E.state.scenes or {}
	if #scenes > 1 or (E.state and E.state.can_make_scenes) then
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
		bar_button("Copy", "Ctrl+C", M.copy)
		bar_button("Make prefab...", nil, function()
			M.prefab_dialog(sel_ids())
		end)
	end
	if E.state and E.state.clipboard then
		bar_button("Paste", "Ctrl+V", M.paste)
	end
	bar_items[#bar_items + 1] = {E.running and "End" or "Run", place(run_end)}
	bar_button("Play mode", nil, M.toggle_tools)
	if narrow() then
		for _, p in ipairs({{"palette", "Palette"}, {"inspector", "Inspector"}}) do
			bar_button(p[2], nil, function()
				toggle_fold(p[1])
				refresh()
			end, not folded(p[1]))
		end
	end
	if E.running then
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
-- clicks on the view), a drag puts one where it is let go
local palette_buttons = {}
local palette

-- [KIT] stage 4f: the palette's title and the terrain tool's, each with a
-- button to the other (T), as tall as the title: the buttons under it stay
-- where they were
local function panel_title(w, s, other)
	local r = row(w)
	local t = text(r, s, DIM)
	t.minWidth = t.width + 8
	if E.state and E.state.terrain then
		local b = button(r, other .. (S.touch and "" or " (T)"), function()
			M.set_tool(S.tool ~= "terrain" and "terrain" or nil)
		end)
		b.minHeight, b.maxHeight = t.height, t.height
	end
	-- [KIT_EDIT_VOXELS] the voxels tool, on with the voxel in hand
	if s == "Palette" and E.state and E.state.voxels and O.solid then
		local b = button(r, "Voxels" .. (S.touch and "" or " (V)"),
				M.toggle_voxels, S.tool == "voxels")
		b.minHeight, b.maxHeight = t.height, t.height
	end
	-- [KIT_PREFAB_VOXELS] the Box tool: a box of voxels to copy or make
	-- a prefab of
	if s == "Palette" and O.solid then
		local b = button(r, "Box" .. (S.touch and "" or " (B)"),
				M.toggle_box, S.tool == "box")
		b.minHeight, b.maxHeight = t.height, t.height
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
		send({op = "export"})
	end)
end

palette = function()
	if ED.view then
		ED.y = ED.view.viewPosition.y
	end
	ED.view, ED.rows, ED.hover = nil, {}, nil
	drop("palette")
	palette_buttons = {}
	if not E.editing or folded("palette") then
		return
	end
	local y = W.bar and W.bar.height + 12 or 40
	local w = window(magic.HA_LEFT, magic.VA_TOP, 8, y)
	W.palette = w
	if S.tool == "terrain" then
		return terrain_panel(w)
	end
	panel_title(w, "Palette", "Terrain")
	-- [KIT] stage 5: its tabs at its foot (what is above them stays where
	-- it was): all, the favourites and the New tab, and the credits
	-- (a player's in the pause menu)
	local function tabs()
		local tr = row(w)
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
	local fav = {}
	if S.tab == "Favourites" then
		for _, n in ipairs(aitta.kit_favourites()) do
			fav[n] = true
		end
	end
	local items = {}
	-- Each by its name (a favourite's), shown as people read it
	for _, t in ipairs(E.state.palette or {}) do
		if S.tab ~= "Favourites" or fav[t] then
			items[#items + 1] = {key = t, label = shown(t), type = t}
		end
	end
	for _, p in ipairs(E.state.prefabs or {}) do
		if S.tab ~= "Favourites" or fav["[" .. p .. "]"] then
			items[#items + 1] = {key = "[" .. p .. "]",
					label = "[" .. shown(p) .. "]", prefab = p}
		end
	end
	if #items == 0 and S.tab == "Favourites" then
		text(w, "None yet: arm one, then \"Favourite\"", DIM)
	end
	local r
	for i, it in ipairs(items) do
		if i % 2 == 1 then
			r = row(w)
		end
		local armed = S.placing ~= nil and S.placing.label == it.label
		local b = button(r, it.label, function()
			-- A click: armed, or no longer (a drag was not a click)
			if S.palette_dragged then
				S.palette_dragged = nil
				return
			end
			if armed then
				S.placing = nil
				log:info("kit editor: placing nothing")
			else
				M.set_tool(nil)
				S.placing = {type = it.type, prefab = it.prefab, label = it.label,
						key = it.key}
				log:info("kit editor: placing " .. it.label)
			end
			palette()
		end, armed)
		palette_buttons[#palette_buttons + 1] = {button = b, item = it}
	end
	-- [KIT] stage 4g: the voxel in hand (the app's, O.pick_voxel) and a
	-- builder's own voxel type
	if E.state.voxels then
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
	end
	-- The armed one starred or not
	if S.placing then
		local name, on = S.placing.key or S.placing.label, false
		for _, n in ipairs(aitta.kit_favourites()) do
			on = on or n == name
		end
		local label = S.placing.label
		-- [KIT] stage 4l: the type's average cost, its instances' now
		if S.placing.type then
			local c = E.costs and E.costs.types and
					E.costs.types[S.placing.type]
			text(w, c and string.format("Costs %.2f%% of Kit's budget an " ..
					"instance", c) or "Its cost: none running", DIM)
		end
		button(w, (on and "Unfavourite " or "Favourite ") .. label, function()
			aitta.kit_favourite(name, not on)
			log:info("kit editor: " .. label .. (on and " not" or "") ..
					" a favourite")
			palette()
		end)
	end
	tabs()
end

-- The voxels to place, the builders' own first, then by name
voxel_names = function()
	local names, own = {}, {}
	for _, v in ipairs(E.state and E.state.voxels or {}) do
		names[#names + 1] = v.name
		own[v.name] = v.author ~= nil
	end
	table.sort(names, function(a, b)
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
				f.choices[#f.choices + 1] = {e.id .. " " .. tostring(e.name) ..
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
local function typed(t, kind, name)
	local ty = t[kind .. "_types"] and t[kind .. "_types"][name]
	return (ty and ty ~= "any") and " (" .. ty .. ")" or ""
end

-- [KIT] stage 4d: an entity of the round's own (made in play) or a
-- player's, shown and not edited
local function inspect_made(w, e)
	text(w, "Entity " .. e.id .. ": " .. tostring(e.name))
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

local function inspector(w, e, is_made)
	if is_made then
		return inspect_made(w, e)
	end
	local n = #sel_ids()
	if n > 1 then
		text(w, n .. " selected", DIM)
	end
	text(w, "Entity " .. e.id .. ": " .. tostring(e.name))
	-- [KIT] stage 4l: what it costs, changed in place as "kit:costs" comes
	S.cost_text = text(w, M.cost_line(e.id), DIM)
	S.cost_id = e.id
	-- Its position typed in (fine tuning, and where keys are not at hand:
	-- a touchscreen), Move one edit; with several selected they move by
	-- what this one moves
	if e.pos then
		local r, at = row(w), {e.pos[1], e.pos[2], e.pos[3]}
		for i, axis in ipairs({"x", "y", "z"}) do
			-- One letter's room: the row's layout has already widened it
			label(r, axis):SetFixedWidth(12)
			local f = edit(r, string.format("%g", at[i]), function(s)
				at[i] = tonumber(s)
			end)
			f.minWidth = 56
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
		if (e.yaw or 0) ~= 0 then
			text(w, string.format("turned %g", e.yaw), DIM)
		end
	end
	button(w, "Delete", function()
		M.delete_selected()
	end)
	for ci, c in ipairs(e.components or {}) do
		local t = type_of(c.type)
		text(w, c.type, magic.Color(1.0, 0.85, 0.3))
		if E.running then
			button(w, "Restart this", function()
				send({op = "restart", id = e.id, comp = ci - 1})
			end)
		end
		local names, decl = {}, t.params or {}
		for k in pairs(decl) do
			names[#names + 1] = k
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
			ui_utils.settings_form(w, fields, values, function(k, v)
				E.pending[key] = E.pending[key] or {}
				E.pending[key][k] = v
				log:info("kit editor: " .. key .. " " .. k .. " = " .. tostring(v))
			end, WIDGETS)
			button(w, "Apply", function()
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
		for _, l in ipairs(c.links or {}) do
			local r = row(w)
			local to = find(l.to)
			label(r, l.output .. " -> " .. l.to .. " " .. tostring(to and
					to.name or "?") .. ": " .. l.input)
			button(r, "Unlink", function()
				send({op = "unlink", id = e.id, comp = ci - 1,
					output = l.output, to = l.to, input = l.input})
			end)
			-- [KIT] stage 4l: drawn for players in play too
			button(r, l.visible and "Shown in play" or "Hidden in play",
					function()
				send({op = "link_visible", id = e.id, comp = ci - 1,
					output = l.output, to = l.to, input = l.input,
					visible = not l.visible})
				log:info("kit editor: link " .. e.id .. "." .. l.output ..
						" -> " .. l.to .. "." .. l.input .. " " ..
						(l.visible and "hidden" or "shown") .. " in play")
			end)
		end
		local r = row(w)
		for _, o in ipairs(t.outputs or {}) do
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
		local r = row(w)
		local seen = {}
		for _, c in ipairs(e.components or {}) do
			for _, i in ipairs(type_of(c.type).inputs or {}) do
				if not seen[i] then
					seen[i] = true
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
	-- [KIT] stage 4d: a prefab's copy
	if type(e.prefab) == "table" then
		text(w, "Prefab " .. tostring(e.prefab.of) .. " " ..
				tostring(e.prefab.version), DIM)
	end
end

-- [KIT_BOX_ADJUST] The Box tool's box adjusted once its two corners are
-- in: typed (its low corner and its size, at the inspector's top) or by
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
	inspector_window()
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

-- The inspector's box: its low corner and its size typed, each change
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

-- A check's question: where the 3D camera is
magic.SubscribeToEvent("command_seq:kit_cam_where", function(_, data)
	local p = S.pos or {x = 0, y = 0, z = 0}
	log:info(string.format("kit editor: the 3D camera at %.2f %.2f %.2f "
			.. "(%s)", p.x, p.y, p.z, data:GetString("Param")))
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

inspector_window = function()
	drop("inspector")
	S.cost_text, S.cost_id = nil, nil
	local e, is_made = nil, false
	if S.primary then
		e, is_made = find(S.primary)
	end
	-- [KIT_BOX_ADJUST] the Box tool's box at its top
	local box = E.editing and S.tool == "box" and not folded("inspector")
	if not E.editing or folded("inspector") or (not e and not box) then
		return
	end
	local y = W.bar and W.bar.height + 12 or 40
	W.inspector = window(magic.HA_RIGHT, magic.VA_TOP, -8, y)
	if box then
		BX.box_section(W.inspector)
	end
	if e then
		inspector(W.inspector, e, is_made)
	end
end

-- A touchscreen's keys ([FP_TOUCH] 4): Undo, Delete and Escape's Cancel, at
-- the lower right
local function touch_bar()
	drop("touch")
	if not E.editing or not S.touch then
		return
	end
	local b = window(magic.HA_RIGHT, magic.VA_BOTTOM, -8, -8, true)
	W.touch = b
	button(b, "Undo", function() send({op = "undo"}) end)
	button(b, "Delete", function() M.delete_selected() end)
	button(b, "Cancel", function() M.escape() end)
end

refresh = function()
	rebuild_bar()
	palette()
	touch_bar()
	inspector_window()
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
	local lines = E.editing and S.primary and E.logs[S.primary] or {}
	if #lines == 0 then
		return
	end
	local lw = window(magic.HA_RIGHT, magic.VA_BOTTOM, -10,
			W.touch and -(W.touch.height + 16) or -50)
	W.log = lw
	text(lw, "Log of " .. S.primary .. ":", DIM)
	for i = math.max(1, #lines - 7), #lines do
		text(lw, tostring(lines[i]))
	end
end

-- The people window's list (a ScrollView in it) and where it was scrolled
local PV = {view = nil, y = 0}

-- The list's height: what is left between the palette's foot (the bar's,
-- folded) and the people window's place over the bottom, less the rest of
-- the window; each frame, as the palette, the window and the screen change
local function fit_people()
	local b, view = W.people, PV.view
	if not b or not view or not view.visible then
		return
	end
	local above = W.palette or W.bar
	local top = above and above.screenPosition.y + above.height + 8 or 8
	-- The rest of the window, as it was built (its layout does not shrink
	-- with the view: its height is set)
	PV.other = PV.other or b.height - view.height
	local room = magic.ui.root.height - 50 - top - PV.other
	local h = math.max(0, math.min(view.contentElement.height, room))
	if view.height ~= h then
		view:SetScrollBarsVisible(false, h < view.contentElement.height)
		view:SetFixedHeight(h)
		b.height = PV.other + h
		log:info(string.format("kit editor: the list %d of %d tall, the " ..
				"window's top %d, the palette's foot %d", h,
				view.contentElement.height, b.screenPosition.y, top - 8))
	end
end

-- Below at the left, out of the view's way: the server's state, a refusal,
-- the entities' list, who edits and who may. Rebuilt alone as the
-- builders move (the inspector being typed in is left as it is)
people = function()
	if W.people and PV.view then
		PV.y = PV.view.viewPosition.y
	end
	PV.view, PV.other = nil, nil
	drop("people")
	-- A narrow screen's palette opened is where it was
	if not E.editing or (narrow() and not folded("palette")) then
		return
	end
	local b = window(magic.HA_LEFT, magic.VA_BOTTOM, 10, -50)
	W.people = b
	text(b, E.running and "Running: edits change the start and the round" or
			"Ended: edits change the start", DIM)
	if E.status ~= "" then
		text(b, E.status, WARN)
	end
	-- The entities, to select ([KIT_SELECT_BURIED]: one under the ground
	-- too): the game-wide ones (on the app root, no position), and the
	-- positioned with "Hide positioned entities" off; in a view that
	-- scrolls, fit_people() bounding it under the palette
	local hide = S.hide_positioned ~= false
	local view = b:CreateChild("ScrollView")
	local list = view:CreateChild("UIElement")
	list:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	local lw, n = 0, 0
	for _, e in ipairs(entities()) do
		if e.kind ~= "scene" and not (hide and e.pos) then
			local gr = row(list)
			local l = label(gr, e.pos and e.id .. " " .. tostring(e.name) ..
					" at " .. table.concat(e.pos, ",") or "Game-wide: " .. e.id ..
					" " .. tostring(e.name))
			local sb = button(gr, e.id == S.primary and "Selected" or "Select",
					function()
				M.select(e.id)
			end)
			lw, n = math.max(lw, l.minWidth + 4 + sb.minWidth), n + 1
		end
	end
	-- Its layout's size, as the rows made it
	local lh = list.height
	view:SetStyleAuto()
	view:SetFocusMode(magic.FM_NOTFOCUSABLE)
	view.scrollBarsAutoVisible = false
	view:SetScrollBarsVisible(false, false)
	list:SetFixedSize(lw, lh)
	view.contentElement = list
	list:SetPosition(0, 0)
	view:SetFixedWidth(lw + view.verticalScrollBar.width + 4)
	view:SetFixedHeight(lh)
	view.visible = n > 0
	PV.view = view
	button(b, "Hide positioned entities: " .. (hide and "yes" or "no"),
			function()
		S.hide_positioned = not hide
		log:info("kit editor: hide positioned entities " ..
				(S.hide_positioned and "yes" or "no"))
		people()
	end)
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
	button(b, "Always keep builds: " .. (E.always_keep and "yes" or "no"),
			function()
		send({op = "always_keep", on = not E.always_keep})
	end)
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
	fit_people()
	if PV.view then
		PV.view.viewPosition = magic.IntVector2(0, PV.y)
	end
end

-- The selection: a click's, Shift's adding or taking out, a box's
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
	focus()
	refresh()
end
M.select = function(id)
	select(id)
end

-- The context menu ([KIT] stage 4e2): an entity's, a right click's or a
-- long press's, for the selection when it is in it
local function close_menu()
	drop("ctx")
end

function M.delete_selected()
	for _, id in ipairs(sel_ids()) do
		local e, is_made = find(id)
		if e and not is_made then
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
	{name = "surface", type = "text", max_length = 32},
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
	ui_utils.settings_form(w, VOXEL_FIELDS, f, function(k, v)
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
	local w = window(magic.HA_LEFT, magic.VA_TOP, math.floor(mx / sc),
			math.floor(my / sc))
	W.ctx = w
	w.priority = 10
	text(w, #ids > 1 and #ids .. " selected" or name_of(e), DIM)
	button(w, "Delete", function()
		close_menu()
		M.delete_selected()
	end)
	button(w, "Duplicate", function()
		close_menu()
		send({op = "duplicate", ids = ids, by = {1, 0, 0}})
	end)
	button(w, "Make prefab...", function()
		close_menu()
		prefab_dialog(ids)
	end)
	if E.running then
		button(w, "Restart this", function()
			close_menu()
			for _, sid in ipairs(ids) do
				local se = find(sid)
				for ci in ipairs(se and se.components or {}) do
					send({op = "restart", id = sid, comp = ci - 1})
				end
			end
		end)
	end
	-- On the screen whole
	local rw, rh = magic.ui.root.width, magic.ui.root.height
	w:SetPosition(math.max(0, math.min(math.floor(mx / sc), rw - w.width)),
			math.max(0, math.min(math.floor(my / sc), rh - w.height)))
	log:info("kit editor: the menu of " .. id .. " (" .. #ids .. " selected)")
end

-- ---- The views ([FP] Views): set_view, the cameras placed each frame
local function apply_viewport()
	local want = E.editing and S.view or "walk"
	if S.shown_view == want then
		return
	end
	S.shown_view = want
	local node, cam = active_camera()
	-- The walk view with the controls' effects (controls.lua)
	magic.set_preferred_viewports({want == "walk" and (O.viewport and
			O.viewport() or M.viewport(O.scene, cam)) or
			magic.Viewport:new(O.scene, cam)})
	if O.set_camera then
		O.set_camera(node)
	end
end

-- The free camera from the app's: where it is, looking as it does
local function cam3d_from_app()
	local p, d = O.camera.worldPosition, O.camera.worldDirection
	S.pos = {x = p.x, y = p.y, z = p.z}
	S.yaw = math.deg(math.atan2(d.x, d.z))
	S.pitch = math.deg(math.asin(math.max(-1, math.min(1, -d.y))))
end

set_view = function(v)
	if v ~= "2d" and v ~= "3d" and v ~= "walk" then
		return
	end
	if v == "3d" and not S.pos then
		cam3d_from_app()
	end
	if v == "2d" and not S.cut then
		local p = O.camera.worldPosition
		S.cx, S.cz = p.x, p.z
		S.cut = O.ground_y + 1.5
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

local function place_cameras()
	local w, h = screen_size()
	cam2d.orthoSize = S.span
	cam2d.aspectRatio = w / math.max(1, h)
	cam2d_node.position = magic.Vector3(S.cx, S.cut or (O.ground_y + 1.5), S.cz)
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
	if typing() or key_held(magic.KEY_LCTRL) or key_held(magic.KEY_RCTRL) or
			(E.menu and E.menu.held()) then
		return
	end
	local shift = key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT)
	local f, r, u = 0, 0, 0
	if key_held(magic.KEY_W) then f = f + 1 end
	if key_held(magic.KEY_S) then f = f - 1 end
	if key_held(magic.KEY_D) then r = r + 1 end
	if key_held(magic.KEY_A) then r = r - 1 end
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
		if key_held(magic.KEY_RIGHT) then turn = turn + 1 end
		if key_held(magic.KEY_LEFT) then turn = turn - 1 end
		if key_held(magic.KEY_UP) then tilt = tilt + 1 end
		if key_held(magic.KEY_DOWN) then tilt = tilt - 1 end
		local rate = (shift and 180 or 60) * dt
		S.yaw = S.yaw + turn * rate
		S.pitch = math.max(-89, math.min(89, S.pitch - tilt * rate))
	end
	if key_held(magic.KEY_SPACE) then u = u + 1 end
	if key_held(magic.KEY_C) then u = u - 1 end
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

-- ---- Ports and the knob: what is dragged to link and to turn
local PORTS = {out = {}, ["in"] = {}}
local ports_root = nil

-- The ports of a kind shown beside an entity: {label, comp, name}...;
-- nil hides them
local function show_ports(kind, id, list)
	if not ports_root then
		-- Under the panels (their priority -1)
		ports_root = magic.ui.root:CreateChild("UIElement")
		ports_root.priority = -2
	end
	local P_ = PORTS[kind]
	local key = id and tostring(id) .. ":" .. table.concat((function()
		local l = {}
		for _, p in ipairs(list) do l[#l + 1] = p.label end
		return l
	end)(), ",") or ""
	if P_.key ~= key then
		for _, p in ipairs(P_.items or {}) do
			p.button:Remove()
		end
		P_.items, P_.key, P_.id = {}, key, id
		for _, p in ipairs(id and list or {}) do
			if not ports_root.defaultStyle then
				ports_root.defaultStyle = STYLE
			end
			local b = button(ports_root, p.label, function() end)
			b.priority = -2
			P_.items[#P_.items + 1] = {button = b, comp = p.comp, name = p.name}
		end
	end
	if not id then
		return
	end
	local e = find(id)
	local sx, sy = nil, nil
	if e and e.pos then
		sx, sy = to_screen(drawn_at(e))
	end
	local sc = magic.ui.scale
	local y0 = sy and sy / sc - #P_.items * 13
	local at = {}
	for i, p in ipairs(P_.items) do
		p.button.visible = sx ~= nil
		if sx then
			-- Outputs at the right of it, inputs at the left
			local x = kind == "out" and sx / sc + 24 or sx / sc - 24 -
					p.button.width
			local y = y0 + (i - 1) * 26
			p.button:SetPosition(math.floor(x), math.floor(y))
			at[#at + 1] = string.format("%s %d,%d", p.name,
					math.floor((x + p.button.width / 2) * sc),
					math.floor((y + p.button.height / 2) * sc))
		end
	end
	-- Where they are, for a drive, as they come or move
	local where = table.concat(at, ", ")
	if where ~= P_.where then
		P_.where = where
		if where ~= "" then
			log:info("kit editor: " .. kind .. " ports of " .. id .. ": " .. where)
		end
	end
end

local function port_at(kind, mx, my)
	local sc = magic.ui.scale
	for _, p in ipairs(PORTS[kind].items or {}) do
		if p.button.visible and inside(p.button, mx / sc, my / sc) then
			return p
		end
	end
end

local function outputs_of(e)
	local l = {}
	for ci, c in ipairs(e and e.components or {}) do
		for _, o in ipairs(type_of(c.type).outputs or {}) do
			l[#l + 1] = {label = o .. " >", comp = ci - 1, name = o}
		end
	end
	return l
end

local function inputs_of(e)
	local l, seen = {}, {}
	for _, c in ipairs(e and e.components or {}) do
		for _, i in ipairs(type_of(c.type).inputs or {}) do
			if not seen[i] then
				seen[i] = true
				l[#l + 1] = {label = "> " .. i, name = i}
			end
		end
	end
	return l
end

-- The selection's knob: on a circle round the primary, the way it faces
local function knob()
	local e, is_made = nil, false
	if S.primary then
		e, is_made = find(S.primary)
	end
	if not e or not e.pos or is_made then
		return nil
	end
	local c = drawn_at(e)
	local n = P.nodes[e.id]
	local r = 1.2
	if n and n.box then
		r = math.max(r, math.max(n.box.size[1], n.box.size[3]) / 2 + 0.6)
	end
	local pv = P.preview[e.id]
	local yaw = pv and pv[4] or (e.yaw or 0)
	local a = math.rad(yaw)
	return c + magic.Vector3(math.sin(a) * r, 0, math.cos(a) * r), c, r, yaw
end

local function near_knob(mx, my)
	local k = knob()
	if not k then
		return false
	end
	local _, c = knob()
	local sx, sy = to_screen(k)
	local cx, cy = to_screen(c)
	-- Nearer it than the entity's middle: a finger's wide reach on a
	-- small plan takes the entity
	return sx ~= nil and math.abs(sx - mx) <= px(SNAP_PX) and
			math.abs(sy - my) <= px(SNAP_PX) and (cx == nil or
			(sx - mx) ^ 2 + (sy - my) ^ 2 < (cx - mx) ^ 2 + (cy - my) ^ 2)
end

-- ---- What a press would take: the knob, a port, an entity
local function press_target(mx, my)
	if near_knob(mx, my) then
		return {knob = true}
	end
	local port = port_at("out", mx, my)
	if port then
		return {port = port}
	end
	local p = pick(mx, my)
	if p and p.id then
		return {id = p.id}
	end
	return {pick = p}
end

local function snap(v, g)
	return math.floor(v / g + 0.5) * g
end

-- Each selected authored entity, with a position
local function movable()
	local l = {}
	for _, id in ipairs(sel_ids()) do
		local e, is_made = find(id)
		if e and e.pos and not is_made then
			l[#l + 1] = e
		end
	end
	return l
end

local function clear_preview()
	P.preview = {}
end

local function start_drag()
	local t = S.press.target
	if t.knob then
		local _, c, _, yaw = knob()
		S.drag = {kind = "turn", c = c, yaw0 = yaw, turn = 0}
		log:info("kit editor: turning " .. S.primary)
		return
	end
	if t.port then
		begin_link(PORTS.out.id, t.port.comp, t.port.name)
		S.drag = {kind = "link", from = PORTS.out.id}
		refresh()
		return
	end
	if t.id and S.sel[t.id] and #movable() > 0 then
		local e = find(t.id)
		local o, v = M.screen_ray(S.press.mx, S.press.my)
		local y = e.pos and e.pos[2] or O.ground_y
		local hp = plane_at(o, v, y)
		if hp then
			S.drag = {kind = "move", y = y, hp = hp, dx = 0, dz = 0,
				ids = movable()}
			log:info("kit editor: moving " .. #S.drag.ids)
			return
		end
	end
	-- A finger's drag on what is not selected moves the view
	-- ([FP_TOUCH] 3): no box
	if S.touch then
		return
	end
	S.drag = {kind = "box"}
end

local function update_drag()
	local d = S.drag
	if d.kind == "move" then
		local o, v = M.screen_ray(S.mx, S.my)
		local hc = plane_at(o, v, d.y)
		if hc then
			local g = GRID_STEPS[S.grid]
			d.dx, d.dz = snap(hc.x - d.hp.x, g), snap(hc.z - d.hp.z, g)
		end
		for _, e in ipairs(d.ids) do
			preview(e, {d.dx, 0, d.dz}, 0)
		end
	elseif d.kind == "turn" then
		local o, v = M.screen_ray(S.mx, S.my)
		local hc = plane_at(o, v, d.c.y)
		if hc then
			local a = math.deg(math.atan2(hc.x - d.c.x, hc.z - d.c.z))
			local step = ANGLE_STEPS[S.angle]
			if step then
				a = snap(a, step)
			end
			d.turn = ((a - d.yaw0) % 360 + 540) % 360 - 180
		end
		for _, e in ipairs(movable()) do
			preview(e, {0, 0, 0}, d.turn)
		end
	end
end

local function place_at(cell, item)
	if not cell or not item then
		return
	end
	if item.clipboard then
		send({op = "place", clipboard = true, pos = cell,
			turn = item.turn or 0})
	elseif item.prefab then
		send({op = "place", prefab = item.prefab, pos = cell,
			turn = item.turn or 0})
	else
		send({op = "place", type = item.type, pos = cell})
	end
	log:info("kit editor: placed " .. item.label .. " at " ..
			table.concat(cell, ","))
end

local function end_drag()
	local d = S.drag
	S.drag = nil
	if d.kind == "move" then
		if d.dx == 0 and d.dz == 0 then
			clear_preview()
			return
		end
		if #d.ids == 1 then
			local e = d.ids[1]
			send({op = "move", id = e.id, pos = {e.pos[1] + d.dx, e.pos[2],
				e.pos[3] + d.dz}})
		else
			local ids = {}
			for _, e in ipairs(d.ids) do
				ids[#ids + 1] = e.id
			end
			send({op = "move", ids = ids, by = {d.dx, 0, d.dz}})
		end
		release_preview()
		log:info(string.format("kit editor: moved %d by %g, %g", #d.ids, d.dx,
				d.dz))
	elseif d.kind == "turn" then
		local l = movable()
		if d.turn == 0 or #l == 0 then
			clear_preview()
			return
		end
		if #l == 1 then
			local e = l[1]
			send({op = "move", id = e.id, pos = e.pos, yaw = (e.yaw or 0) + d.turn})
		else
			local ids = {}
			for _, e in ipairs(l) do
				ids[#ids + 1] = e.id
			end
			send({op = "move", ids = ids, by = {0, 0, 0}, turn = d.turn})
		end
		release_preview()
		log:info(string.format("kit editor: turned %d by %g", #l, d.turn))
	elseif d.kind == "box" then
		local x0, x1 = math.min(S.press.mx, S.mx), math.max(S.press.mx, S.mx)
		local y0, y1 = math.min(S.press.my, S.my), math.max(S.press.my, S.my)
		if not S.press.shift then
			S.sel = {}
			S.primary = nil
		end
		local n = 0
		for _, e in ipairs(entities()) do
			if e.pos then
				local sx, sy = to_screen(drawn_at(e))
				if sx and sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1 then
					S.sel[e.id] = true
					S.primary = S.primary or e.id
					n = n + 1
				end
			end
		end
		log:info("kit editor: a box selected " .. n .. ", " .. #sel_ids() ..
				" in the selection")
		focus()
		refresh()
	elseif d.kind == "link" then
		local link = E.link
		local port = port_at("in", S.mx, S.my)
		local to = port and PORTS["in"].id
		if not to then
			local p = pick(S.mx, S.my, {[d.from] = true})
			to = p and p.id
		end
		local te, made_ = nil, false
		if to then
			te, made_ = find(to)
		end
		if not link or not te or made_ or to == d.from then
			E.link, E.status = nil, ""
			log:info("kit editor: link dropped on nothing")
		else
			local ins = inputs_of(te)
			local input = port and port.name or (#ins == 1 and ins[1].name)
			if input then
				send({op = "link", id = link.id, comp = link.comp,
					output = link.output, to = to, input = input})
				log:info("kit editor: link dropped on " .. to .. " " .. input)
				E.link, E.status = nil, ""
			else
				-- Which input: the inspector's To buttons
				log:info("kit editor: link dropped on " .. to .. ", " .. #ins ..
						" inputs")
				select(to)
			end
		end
		show_ports("in", nil)
		refresh()
	end
end

-- A click (a press let go where it was)
local function click()
	local t = S.press.target
	if S.placing then
		local c = place_cell(S.press.mx, S.press.my)
		if c then
			place_at(c, S.placing)
		end
		return
	end
	if t.id then
		select(t.id, S.press.shift)
		return
	end
	if not S.press.shift then
		if next(S.sel) then
			select(nil)
		end
		-- The cursor, which the other builders see
		local c = place_cell(S.press.mx, S.press.my)
		if c then
			E.cursor = c
			log:info("kit editor: cursor at " .. table.concat(c, ","))
			focus()
		end
	end
end

-- The right button let go where it was pressed: placing stops; on an
-- entity its menu, on nothing the selection goes ([FP]'s)
local function right_click(rc)
	if S.tool == "terrain" then
		M.set_tool(nil)
		return
	end
	if S.placing then
		S.placing = nil
		log:info("kit editor: placing nothing")
		palette()
		return
	end
	local p = pick(rc.mx, rc.my)
	if p and p.id then
		context_menu(p.id, rc.mx, rc.my)
	elseif next(S.sel) then
		select(nil)
	end
end

-- Escape's, the tools' first ([FP_ESC]: down one level): a dialog or the
-- menu, a drag, placing, a pending link, the crosshair. True when taken
function M.escape()
	if W.dialog or W.ctx then
		drop("dialog")
		close_menu()
		return true
	end
	if S.drag then
		S.drag, S.press = nil, nil
		clear_preview()
		show_ports("in", nil)
		E.link, E.status = nil, ""
		log:info("kit editor: the drag given up")
		return true
	end
	if T.down then
		stroke_end(S.mx, S.my)
		return true
	end
	-- In the crosshair Escape leaves it first, the voxels tool kept
	if S.tool and not M.looking() then
		M.set_tool(nil)
		return true
	end
	if S.placing then
		S.placing = nil
		log:info("kit editor: placing nothing")
		palette()
		return true
	end
	if M.cancel_link() then
		return true
	end
	if M.looking() then
		S.crosshair = false
		log:info("kit editor: out of the crosshair")
		changed()
		return true
	end
	return false
end

-- A pending link cancelled: true if there was one (the tools' Escape
-- takes it before the app's pause menu)
function M.cancel_link()
	if not E.link then
		return false
	end
	E.link, E.status = nil, ""
	log:info("kit editor: link cancelled")
	refresh()
	return true
end

-- [KIT] stage 5 kit.show_credits(): who made what the composition uses,
-- the server's (each package with its version and licences, Kit's, the
-- app's and each builder's). From the pause menu (menu given): a page of
-- it, its Close or Escape the menu again
function M.show_credits(menu)
	menu = type(menu) == "table" and menu or nil
	drop("dialog")
	local w = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.dialog = w
	w.priority = 10
	w:SetFixedWidth(math.min(560, magic.ui.root.width - 16))
	text(w, "Credits: what this world is made of")
	for _, c in ipairs(E.credits or {}) do
		local who = c.package and tostring(c.package) .. " " ..
				tostring(c.version) .. " by " .. tostring(c.author) .. " (" ..
				tostring(c.license_code) .. ", " .. tostring(c.license_media) ..
				")" or c.of == "kit" and "Kit (Buildat)" or c.of == "app" and
				"The app (" .. tostring(c.author) .. ")" or
				"Built here by " .. tostring(c.author)
		local uses = {}
		for _, u in ipairs(type(c.uses) == "table" and c.uses or {}) do
			uses[#uses + 1] = tostring(u)
		end
		local t = text(w, who)
		t:SetWordwrap(true)
		local u = text(w, "  " .. table.concat(uses, ", "), DIM)
		u:SetWordwrap(true)
		log:info("kit editor: credit " .. who .. ": " .. table.concat(uses, " "))
	end
	if #(E.credits or {}) == 0 then
		text(w, "Nothing placed yet", DIM)
	end
	local function close()
		drop("dialog")
		log:info("kit editor: the credits closed")
		if menu then
			menu.back()
		end
	end
	button(w, "Close", close)
	if menu then
		menu.hold(close, w)
	end
end

-- Kit's items in an app's pause menu (extensions/pause_menu), a builder's:
-- Edit ("Play mode" while the tools are on) and Run or End; everyone's
-- Credits...; and the tools' Escape first
function M.add_menu_items(menu)
	E.menu = menu
	menu.add(function()
		return E.can_edit and (E.editing and "Play mode" or "Edit") or nil
	end, M.toggle_tools, {order = 10})
	menu.add(function()
		return E.can_edit and (E.running and "End" or "Run") or nil
	end, function()
		if E.running then M.stop() else M.play() end
	end, {order = 11})
	menu.add("Credits...", function() M.show_credits(menu) end,
			{order = 70, page = true})
	menu.on_escape(M.escape)
	M.on_change(menu.refresh)
	O.menu = O.menu or function() menu.open() end
end

-- The crosshair let go of (the app's lost pointer lock): true if it was up
function M.drop_crosshair()
	if not M.looking() then
		return false
	end
	S.crosshair = false
	changed()
	return true
end

-- ---- [KIT] stage 4f: the terrain tool. T (or Terrain on the palette's
-- title) puts its brushes in the palette's place: Raise, Lower, Smooth, Flatten (to the
-- stroke's first point), Paint (the biome's ground), Fill (a rectangle
-- dragged, up to its first corner's level, with the biome's ground or
-- water) and Decorate (the biome's scatter; in a cave its floor's and
-- wall's), their size and strength ([ and ], with Shift the strength) and
-- the biome. A left drag on the ground is a stroke (one undo), its dabs
-- as it moves and while it stays; a touchscreen's finger the same. The
-- brush is a circle on the ground in what it does' colour; a right click
-- or Escape puts the tool away (floorplanner's Object tool).
-- [KIT_VOXEL_EDITS] Under the brushes the World's edited sections, each
-- with its cells unlike the generator's, Regenerate and Regenerate all
-- (Ended: the section generated again, one undo); a row hovered outlines
-- its section brighter; with the tool on every edited section is
-- outlined in 2D and 3D
local heightmap = require("buildat/module/heightmap")

function M.set_tool(tool)
	if S.tool == tool then
		return
	end
	-- [KIT_PREFAB_VOXELS] the Box tool's box goes with it
	if S.tool == "box" then
		S.vbox, S.box_drag = nil, nil
	end
	S.tool = tool
	T.down, T.fill = false, nil
	S.placing = nil
	log:info("kit editor: tool " .. tostring(tool or "select"))
	if tool == "terrain" then
		send({op = "edited"})
	end
	refresh()
end

function M.brush_size(d)
	T.size = math.max(1, math.min(MAX_BRUSH, T.size + d))
	log:info("kit editor: brush size " .. T.size)
	palette()
end

function M.brush_strength(d)
	T.strength = math.max(1, math.min(5, T.strength + d))
	log:info("kit editor: brush strength " .. T.strength)
	palette()
end

-- What a brush does, in its colour: adding green, taking away red, the
-- rest the hover's
local function brush_color()
	return T.brush == "lower" and M.DIG or (T.brush == "smooth" or
			T.brush == "flatten") and M.HOVER or M.PLACE
end

local BRUSH_TEXT = {raise = "raise the ground", lower = "lower the ground",
	smooth = "smooth the ground", flatten = "flatten to the stroke's start",
	paint = "paint the biome's ground", decorate = "decorate (the biome's)",
	fill = "drag: fill a rectangle up to here"}

terrain_panel = function(w)
	panel_title(w, "Terrain", "Palette")
	local r
	for i, b in ipairs(BRUSHES) do
		if i % 2 == 1 then
			r = row(w)
		end
		button(r, BRUSH_NAMES[b], function()
			T.brush = b
			log:info("kit editor: brush " .. b)
			palette()
		end, T.brush == b)
	end
	for _, k in ipairs({{"Size", T.size, M.brush_size},
			{"Strength", T.strength, M.brush_strength}}) do
		local sr = row(w)
		label(sr, k[1] .. " " .. k[2], 80)
		button(sr, "-", function() k[3](-1) end)
		button(sr, "+", function() k[3](1) end)
	end
	local tr = E.state and E.state.terrain or {}
	local choices = {}
	for _, b in ipairs(tr.biomes or {}) do
		choices[#choices + 1] = {b, b}
	end
	if T.brush == "fill" then
		choices[#choices + 1] = {"water", "water"}
	end
	text(w, "Biome", DIM)
	ui_utils.dropdown(w, choices, T.biome or tr.biome, function(v)
		T.biome = v
		log:info("kit editor: brush biome " .. tostring(v))
	end, {height = 24})
	text(w, tr.surface == "heightmap" and "On the heightmap" or
			"On the voxels", DIM)
	-- [KIT_VOXEL_EDITS] The sections somebody wrote, which a change of the
	-- World's parameters keeps: each its cells unlike the generator's
	-- (hovered, outlined in the view), Regenerate dropping its writes (one
	-- undo); in a view that scrolls past ED_HEIGHT
	local l = ED.list
	if not l then
		return
	end
	local secs = type(l.sections) == "table" and l.sections or {}
	text(w, "Edited sections: " .. (#secs + (tonumber(l.more) or 0)), DIM)
	if #secs == 0 then
		return
	end
	local view = w:CreateChild("ScrollView")
	local list = view:CreateChild("UIElement")
	list:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	local lw = 0
	for _, e in ipairs(secs) do
		local s = e.s
		local n = tonumber(e.cells) or -1
		local r = row(list)
		local lb = label(r, table.concat(s, ",") .. ": " .. (n < 0 and
				"not loaded" or n .. " cells") .. (e.owned and
				" (a component's)" or ""), 130)
		local b = button(r, "Regenerate", function()
			log:info("kit editor: regenerate " .. table.concat(s, ","))
			send({op = "regenerate", s = s})
		end)
		lw = math.max(lw, lb.minWidth + 4 + b.minWidth)
		ED.rows[#ED.rows + 1] = {el = r, s = s}
	end
	local lh = list.height
	view:SetStyleAuto()
	view:SetFocusMode(magic.FM_NOTFOCUSABLE)
	view.scrollBarsAutoVisible = false
	view:SetScrollBarsVisible(false, lh > ED_HEIGHT)
	list:SetFixedSize(lw, lh)
	view.contentElement = list
	list:SetPosition(0, 0)
	view:SetFixedWidth(lw + view.verticalScrollBar.width + 4)
	view:SetFixedHeight(math.min(lh, ED_HEIGHT))
	view.viewPosition = magic.IntVector2(0, ED.y)
	ED.view = view
	button(w, "Regenerate all", function()
		log:info("kit editor: regenerate all")
		send({op = "regenerate", all = true})
	end)
end

-- The edited sections hovered in the terrain panel's list (the pointer's
-- pixels), and outlined in the view: the terrain tool's, the hovered one
-- brighter
local function draw_edited(dbg, mx, my)
	if S.tool ~= "terrain" or not ED.list then
		return
	end
	local sc = magic.ui.scale
	local x, y = mx / sc, my / sc
	local hover = nil
	if ED.view and inside(ED.view, x, y) then
		for _, r in ipairs(ED.rows) do
			if inside(r.el, x, y) then
				hover = r.s
			end
		end
	end
	local key = hover and table.concat(hover, ",")
	if key ~= ED.hover then
		ED.hover = key
		log:info("kit editor: section hovered: " .. tostring(key))
	end
	if S.view == "walk" then
		return
	end
	local n = tonumber(ED.list.size) or 64
	for _, e in ipairs(type(ED.list.sections) == "table" and
			ED.list.sections or {}) do
		local s = e.s
		local lit = table.concat(s, ",") == key
		dbg:AddBoundingBox(magic.BoundingBox(
				magic.Vector3(s[1] * n - 0.5, s[2] * n - 0.5, s[3] * n - 0.5),
				magic.Vector3((s[1] + 1) * n - 0.5, (s[2] + 1) * n - 0.5,
				(s[3] + 1) * n - 0.5)), lit and magic.Color(1, 1, 0.3) or
				magic.Color(1, 0.45, 0.1), false)
	end
end

-- The ground the pointer is on: {x, y, z}, a voxel's cell (its top cell)
-- or a heightmap's point; nil off the ground
brush_at = function(mx, my)
	local o, v = M.screen_ray(mx, my)
	if O.solid then
		local hit, _, t = M.voxel_ray({o.x, o.y, o.z}, {v.x, v.y, v.z},
				O.solid, MAX_RAY)
		if hit and heightmap.terrain then
			local p = o + v * t
			local h = heightmap.height_at(p.x, p.z)
			if h then
				return {x = p.x, y = h, z = p.z}
			end
		end
		if hit then
			return {x = hit[1], y = hit[2], z = hit[3]}
		end
	end
	local g = ground_at(o, v)
	return g and {x = g[1], y = g[2] - 1, z = g[3]} or nil
end

-- The ground's surface at a column near y0 (a voxel's top face), for the
-- brush's circle
local function surface_y(x, z, y0)
	if heightmap.terrain then
		local h = heightmap.height_at(x, z)
		return h and h + 0.05 or y0
	end
	if not O.solid then
		return O.ground_y - 0.45
	end
	local cx, cz = round(x), round(z)
	local top = round(y0) + T.size + 3
	local above = O.solid(cx, top + 1, cz)
	for y = top, top - T.size - 12, -1 do
		local s = O.solid(cx, y, cz)
		if s and not above then
			return y + 0.55
		end
		above = s
	end
	return round(y0) + 0.55
end

local function dab(pt)
	send({op = "terrain", tool = T.brush, x = pt.x, y = pt.y, z = pt.z,
		size = T.size, strength = T.strength, stroke = T.stroke,
		biome = T.biome, level = T.level})
	T.last = {x = pt.x, z = pt.z, t = buildat.get_time_us()}
	T.dabs = T.dabs + 1
end

stroke_begin = function(mx, my)
	local pt = brush_at(mx, my)
	if not pt then
		return false
	end
	-- An id of its own: every dab of it one undo
	T.stroke = math.floor(buildat.get_time_us()) % 1000000000000
	T.down, T.level, T.dabs = true, pt.y, 0
	log:info(string.format("kit editor: a %s stroke at %g, %g, %g", T.brush,
			pt.x, pt.y, pt.z))
	if T.brush == "fill" then
		T.fill = pt
		return true
	end
	dab(pt)
	return true
end

-- Each frame while it is down: a dab where it moved half the brush, or
-- where it stays a while
stroke_move = function(mx, my)
	if not T.down or T.brush == "fill" then
		return
	end
	local pt = brush_at(mx, my)
	if not pt or not T.last then
		return
	end
	local now = buildat.get_time_us()
	local d = math.sqrt((pt.x - T.last.x) ^ 2 + (pt.z - T.last.z) ^ 2)
	if (d >= math.max(1, T.size * 0.5) and now - T.last.t > 50000) or
			now - T.last.t > 150000 then
		dab(pt)
	end
end

stroke_end = function(mx, my)
	if not T.down then
		return
	end
	T.down = false
	if T.brush == "fill" and T.fill then
		local pt = brush_at(mx, my) or T.fill
		send({op = "terrain", tool = "fill", x = T.fill.x, y = T.fill.y,
			z = T.fill.z, x1 = pt.x, z1 = pt.z, level = T.level,
			biome = T.biome, stroke = T.stroke})
		log:info(string.format("kit editor: fill %g, %g to %g, %g", T.fill.x,
				T.fill.z, pt.x, pt.z))
	else
		log:info("kit editor: the stroke ended, " .. T.dabs .. " dabs")
	end
	T.fill = nil
	-- The edited sections as the stroke left them (after its dabs: the
	-- server takes them in order)
	send({op = "edited"})
end

-- The brush on the ground: its circle (a fill's rectangle) where it is
draw_brush = function(dbg, mx, my)
	if S.tool ~= "terrain" or (over_ui(mx, my) and not T.down) then
		return
	end
	local col = brush_color()
	local pt = brush_at(mx, my)
	if T.brush == "fill" and T.fill then
		pt = pt or T.fill
		local y = T.level + (heightmap.terrain and 0.05 or 0.55)
		local x0, x1 = math.min(T.fill.x, pt.x) - 0.5, math.max(T.fill.x, pt.x) + 0.5
		local z0, z1 = math.min(T.fill.z, pt.z) - 0.5, math.max(T.fill.z, pt.z) + 0.5
		dbg:AddBoundingBox(magic.BoundingBox(magic.Vector3(x0, y - 0.02, z0),
				magic.Vector3(x1, y + 0.02, z1)), col, false)
		return
	end
	if not pt then
		return
	end
	local r = T.size + 0.5
	local prev = nil
	for i = 0, 40 do
		local a = i / 40 * 2 * math.pi
		local x, z = pt.x + r * math.cos(a), pt.z + r * math.sin(a)
		local p = magic.Vector3(x, surface_y(x, z, pt.y), z)
		if prev then
			dbg:AddLine(prev, p, col, false)
		end
		prev = p
	end
	dbg:AddCross(magic.Vector3(pt.x, surface_y(pt.x, pt.z, pt.y), pt.z), 0.6,
			col, false)
end

-- ---- [KIT_EDIT_VOXELS] the voxels tool (V, or Voxels on the palette's
-- title): on while a voxel is in hand (the palette's Voxel list; "none"
-- puts it away, as do V and Escape). A left click places it on the face
-- pointed at, Shift+left digs the voxel pointed at, each one edit (one
-- undo) through Kit's routed writes ("set_voxel"); walking, as play, the
-- left button digs and the right one places (a tap and a finger held), at
-- the crosshair within play's reach (O.reach, 6 cells past the body); the
-- other views at the pointer, where the right button stays the view's and
-- the entity menu's.
-- simplified: a click is one cell, and in 2D and 3D a touchscreen's tap
-- selects as before; a left drag filling a box (Shift: clearing one), one op and
-- one undo, is the upgrade
local function voxel_target(mx, my)
	if not O.solid then
		return nil
	end
	local o, v = M.screen_ray(mx, my)
	v = v:Normalized()
	local reach = MAX_RAY
	if S.view == "walk" then
		-- A camera away from the eye reaches as far past the player
		-- (Workbench's target())
		local b = M.body_pos and M.body_pos()
		local far = b and math.sqrt((o.x - b.x) ^ 2 + (o.y - b.y - 1.5) ^ 2 +
				(o.z - b.z) ^ 2) or 0
		reach = (O.reach or 6) + (far > 1 and far or 0)
	end
	local solid = M.with_terrain(O.solid)
	local hit, front, t = M.voxel_ray({o.x, o.y, o.z}, {v.x, v.y, v.z}, solid,
			reach)
	-- [KIT_HM_VOXELS] on the heightmap: the cell over the hit point
	front = M.place_front(hit, front, {o.x, o.y, o.z}, {v.x, v.y, v.z}, t,
			solid)
	return hit and {cell = hit, front = front,
		y = t and o.y + v.y * t} or nil
end

local function voxel_click(mx, my, dig)
	local t = voxel_target(mx, my)
	local c = t and (dig and t.cell or t.front)
	if not c or not S.voxel then
		return
	end
	-- The heightmap is not dug: voxels only (the Terrain tool's)
	if dig and M.terrain_cell(c[1], c[2], c[3]) then
		log:info("kit editor: dig: the heightmap is not dug, at " ..
				table.concat(c, ","))
		return
	end
	local name = dig and "air" or M.hand_voxel(S.voxel)
	local j = {op = "set_voxel", pos = c, voxel = name}
	if not dig then
		-- [KIT_VOXEL_FORMAT] the facing from the view, the tint
		local o, v = M.screen_ray(mx, my)
		v = v:Normalized()
		local n = {c[1] - t.cell[1], c[2] - t.cell[2], c[3] - t.cell[3]}
		if math.abs(n[1]) + math.abs(n[2]) + math.abs(n[3]) ~= 1 then
			n = {0, 1, 0}
		end
		j.param = M.hand.shape ~= "" and M.shape_param(v, n, t.y) or 0
		j.tint = M.hand.tint
	end
	-- [KIT_HM_VOXELS] on the heightmap: the surface it is sunken in
	local h = not dig and M.terrain_cell(t.cell[1], t.cell[2], t.cell[3]) and
			heightmap.height_at(c[1], c[3])
	if h then
		log:info(string.format("kit editor: on the heightmap, its surface " ..
				"at %.3f", h))
	end
	log:info("kit editor: " .. (dig and "dig" or "place " .. name) .. " at " ..
			table.concat(c, ",") .. (j.param and j.param ~= 0 and
			" param " .. j.param or "") .. (j.tint and j.tint ~= 0 and
			" tint " .. j.tint or ""))
	send(j)
end

-- [KIT_PREFAB_VOXELS] The Box tool: a click on a voxel (or the ground
-- cell) a corner of the box, the first and then the second; a third
-- starts a new box
local function box_click(mx, my)
	local t = voxel_target(mx, my)
	local c = t and t.cell or place_cell(mx, my)
	if not c then
		return
	end
	local b = S.vbox
	if not b or b.b then
		S.vbox = {a = c}
		log:info("kit editor: box corner " .. table.concat(c, ","))
	else
		b.b = c
		log:info("kit editor: box " .. table.concat(vbox(), ","))
	end
	refresh()
end

-- [KIT_PREFAB_VOXELS] The copy (the server's, the builder's): the
-- selected entities and the Box tool's voxels
function M.copy()
	local ids, box = sel_ids(), vbox()
	if #ids == 0 and not box then
		log:info("kit editor: copy: nothing selected and no box")
		return
	end
	send({op = "copy", ids = #ids > 0 and ids or nil, box = box})
	log:info("kit editor: copy of " .. #ids .. " entities" .. (box and
			" and the box " .. table.concat(box, ",") or ""))
end

-- A paste: the copy placed as a prefab is, turned with Z and X
function M.paste()
	if not (E.state and E.state.clipboard) then
		log:info("kit editor: paste: nothing copied")
		return
	end
	M.set_tool(nil)
	S.placing = {clipboard = true, label = "Paste", turn = 0}
	log:info("kit editor: pasting")
	refresh()
end

function M.toggle_box()
	M.set_tool(S.tool ~= "box" and "box" or nil)
end

-- The box a voxel prefab's (or the copy's) voxels would fill placed at
-- cell, turned: its low and high cells
local function turn_xz(x, z, turn)
	for _ = 1, math.floor((turn or 0) / 90) % 4 do
		x, z = z, -x
	end
	return x, z
end
function M.placed_box(cell, item)
	local cb = item.clipboard and E.state and E.state.clipboard
	local size = cb and cb.size
	if not size or size[1] == 0 then
		return nil
	end
	local at = cb.at or {0, 0, 0}
	local x0, z0 = turn_xz(at[1], at[3], item.turn)
	local x1, z1 = turn_xz(at[1] + size[1] - 1, at[3] + size[3] - 1, item.turn)
	local base = {round(cell[1]), round(cell[2]), round(cell[3])}
	return {base[1] + math.min(x0, x1), base[2] + at[2],
			base[3] + math.min(z0, z1)},
		{base[1] + math.max(x0, x1), base[2] + at[2] + size[2] - 1,
			base[3] + math.max(z0, z1)}
end

-- ---- Input: the mouse ([FP]'s mouse_down, mouse_up, mouse_move)
local function mouse_down(button_)
	if not E.editing or S.touch then
		return
	end
	local mx, my = S.mx, S.my
	if button_ == magic.MOUSEB_LEFT and not M.looking() then
		local item = palette_at(mx, my)
		if item then
			S.palette_press = {item = item, mx = mx, my = my}
			S.palette_dragged = nil
			return
		end
	end
	if over_ui(mx, my) and not M.looking() then
		return
	end
	if W.ctx then
		close_menu()
		S.swallow_up = button_
		return
	end
	-- Walking, a click on the view goes up into the crosshair, where the
	-- app has a mouse look ([FP_ESC])
	if O.mouse_look and S.view == "walk" and not S.crosshair and
			button_ == magic.MOUSEB_LEFT then
		S.crosshair = true
		S.swallow_up = button_
		log:info("kit editor: into the crosshair")
		changed()
		return
	end
	if S.tool == "terrain" and button_ == magic.MOUSEB_LEFT then
		stroke_begin(mx, my)
		return
	end
	if S.tool == "box" and button_ == magic.MOUSEB_LEFT then
		-- [KIT_BOX_ADJUST] a face's handle dragged
		local h = BX.box_handle_at(mx, my)
		if h then
			local sx, sy = to_screen(h.at)
			BX.box_grab(h, sx, sy, key_held(magic.KEY_LSHIFT) or
					key_held(magic.KEY_RSHIFT))
			return
		end
		box_click(mx, my)
		return
	end
	if S.tool == "voxels" and button_ == magic.MOUSEB_LEFT then
		-- Walking, the left button digs as in play
		voxel_click(mx, my, S.view == "walk" or key_held(magic.KEY_LSHIFT) or
				key_held(magic.KEY_RSHIFT))
		return
	end
	if button_ == magic.MOUSEB_RIGHT then
		S.right_click = {moved = 0, mx = mx, my = my}
		if M.looking() then
			return
		end
		-- 2D: into 3D once it moves (mouse_move), a click staying a click
		if S.view == "3d" then
			S.orbit = camera_pivot(mx, my)
		end
		return
	end
	if button_ == magic.MOUSEB_MIDDLE then
		if S.view == "2d" then
			S.panning = true
		elseif S.view == "3d" then
			S.pan3d = pan3d_start(mx, my)
		end
		return
	end
	if button_ == magic.MOUSEB_LEFT then
		local shift = key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT)
		S.press = {mx = mx, my = my, shift = shift,
			target = press_target(mx, my)}
	end
end

local function mouse_up(button_)
	if not E.editing or S.touch then
		return
	end
	if S.swallow_up == button_ then
		S.swallow_up = nil
		return
	end
	if button_ == magic.MOUSEB_LEFT and T.down then
		stroke_end(S.mx, S.my)
		return
	end
	if button_ == magic.MOUSEB_LEFT and S.box_drag then
		BX.box_drop()
		return
	end
	if button_ == magic.MOUSEB_LEFT and S.palette_press then
		local pp = S.palette_press
		S.palette_press = nil
		if S.drag and S.drag.kind == "palette" then
			S.drag = nil
			if not over_ui(S.mx, S.my) then
				place_at(place_cell(S.mx, S.my), pp.item)
			else
				log:info("kit editor: the drag from the palette given up")
			end
		end
		return
	end
	if button_ == magic.MOUSEB_RIGHT then
		local rc = S.right_click
		S.right_click = nil
		local orbited = S.orbit
		S.orbit = nil
		if rc and rc.moved < RIGHT_CLICK_PX and S.tool == "voxels" and
				S.view == "walk" then
			-- Walking, the right button places as in play
			voxel_click(rc.mx, rc.my, false)
		elseif rc and rc.moved < RIGHT_CLICK_PX then
			if M.looking() then
				-- The menu wants the pointer
				S.crosshair = false
				changed()
				local w, h = screen_size()
				rc.mx, rc.my = w / 2, h / 2
			end
			right_click(rc)
		elseif orbited and S.from_plan and plan_aligned() then
			-- Back to the plan, where its floor is the view's
			local o = S.pos
			local q = rot3d() * magic.Vector3(0, 0, 1)
			local t = q.y < -1e-6 and ((S.cut or O.ground_y) - o.y) / q.y or 0
			S.cx, S.cz = o.x + q.x * t, o.z + q.z * t
			S.span = math.max(4, math.min(400, math.abs(o.y - (S.cut or 0)) *
					2 * math.tan(math.rad(cam3d.fov) / 2)))
			set_view("2d")
		end
		return
	end
	if button_ == magic.MOUSEB_MIDDLE then
		if S.pan3d then
			local f = S.pan3d.from
			log:info(string.format("kit editor: panned in 3D from %.2f,%.2f,%.2f"
					.. " to %.2f,%.2f,%.2f", f.x, f.y, f.z, S.pos.x, S.pos.y,
					S.pos.z))
		end
		S.panning, S.pan3d = false, nil
		return
	end
	if button_ ~= magic.MOUSEB_LEFT or not S.press then
		return
	end
	if S.drag then
		end_drag()
	else
		click()
	end
	S.press = nil
end

local function mouse_move(x, y, dx, dy)
	if S.box_drag then
		BX.box_drag_move(x, y)
		return
	end
	local rc = S.right_click
	if rc then
		rc.moved = rc.moved + math.abs(dx) + math.abs(dy)
		if S.view == "2d" and rc.moved >= RIGHT_CLICK_PX and
				not M.looking() then
			-- Into 3D as if it had been 3D all along ([FP_ORBIT_2D]): the
			-- camera straight above the plan's middle, looking down, as
			-- high as makes the cut's plane the plan's; then this is an
			-- orbit round what was pressed
			local d = S.span / (2 * math.tan(math.rad(cam3d.fov) / 2))
			S.pos = {x = S.cx, y = (S.cut or O.ground_y) + d, z = S.cz}
			S.yaw, S.pitch = 0, 90
			local pivot = camera_pivot(rc.mx, rc.my)
			set_view("3d")
			S.from_plan = true
			S.orbit = pivot
		end
	end
	if S.orbit then
		-- The camera round the point, its offset held in the camera's frame
		local p = S.orbit
		local q0 = rot3d()
		local inv = magic.Quaternion(q0.w, -q0.x, -q0.y, -q0.z)
		local off = inv * (magic.Vector3(S.pos.x, S.pos.y, S.pos.z) - p)
		local k = 0.3 * (S.touch and 0.5 or 1)
		S.yaw = S.yaw + dx * k
		S.pitch = math.max(-90, math.min(90, S.pitch + dy * k))
		local wp = p + rot3d() * off
		S.pos = {x = wp.x, y = wp.y, z = wp.z}
		return
	end
	if S.pan3d then
		-- In the XZ plane: the point grabbed stays under the pointer where
		-- both rays meet its height; else (looking level) by the view's
		-- right and its forward along the ground
		local o0, v0 = M.screen_ray(x - dx, y - dy)
		local o1, v1 = M.screen_ray(x, y)
		local a, b = plane_at(o0, v0, S.pan3d.y), plane_at(o1, v1, S.pan3d.y)
		-- [KIT_CAM_MIN_MOVE] never slower than a point this far away
		-- grabbed: close to a surface, or under it, the pan still goes
		local _, h = screen_size()
		local kpx = 2 * math.tan(math.rad(cam3d.fov) / 2) / h
		local least = 6 * kpx * math.sqrt(dx * dx + dy * dy)
		local mx_, mz_
		if a and b then
			mx_, mz_ = b.x - a.x, b.z - a.z
			local m = math.sqrt(mx_ * mx_ + mz_ * mz_)
			if m < 1e-6 then
				mx_ = nil
			elseif m < least then
				mx_, mz_ = mx_ * least / m, mz_ * least / m
			end
		end
		if not mx_ then
			local k = math.max(6, S.pan3d.dist) * kpx
			local yaw = math.rad(S.yaw)
			local rx, rz = math.cos(yaw), -math.sin(yaw)
			-- right (rx, rz), forward along the ground (-rz, rx)
			mx_, mz_ = (rx * dx + rz * dy) * k, (rz * dx - rx * dy) * k
		end
		S.pos = {x = S.pos.x - mx_, y = S.pos.y, z = S.pos.z - mz_}
		return
	end
	if M.looking() then
		return
	end
	S.mx, S.my = x, y
	if S.panning and S.view == "2d" then
		local _, h = screen_size()
		local k = S.span / h
		S.cx, S.cz = S.cx - dx * k, S.cz + dy * k
	end
	local pp = S.palette_press
	if pp and not S.drag and math.abs(x - pp.mx) + math.abs(y - pp.my) >
			px(DRAG_PX) and not palette_at(x, y) then
		S.drag = {kind = "palette", item = pp.item}
		S.palette_dragged = true
		log:info("kit editor: dragging " .. pp.item.label .. " from the palette")
	end
	if S.press and not S.drag and math.abs(x - S.press.mx) +
			math.abs(y - S.press.my) > px(DRAG_PX) then
		start_drag()
	end
	if S.drag then
		update_drag()
	end
end

-- [KIT_WALK_WHEEL] Walking with the voxels tool on (the crosshair's or
-- the pointer's): the wheel steps the voxel in hand through the Voxel
-- list, Shift+wheel its shape (a material with shapes), Ctrl+Shift+wheel
-- its tint; up the one before, as Luanti's hotbar, round at the ends
local function wheel_hand(wheel, q)
	local shift = q % 2 == 1
	local ctrl = math.floor(q / 2) % 2 == 1
	local step = wheel > 0 and -1 or 1
	local function round(i, n)
		return (i - 1) % n + 1
	end
	if ctrl and not shift then
		return
	end
	if not shift then
		local names = voxel_names()
		if #names == 0 then
			return
		end
		local at = 0
		for i, n in ipairs(names) do
			if n == S.voxel then
				at = i
			end
		end
		return M.pick_voxel(names[round(at == 0 and (step > 0 and 0 or 1) +
				step or at + step, #names)])
	end
	if not S.voxel then
		return
	end
	if ctrl then
		local n = #M.tints_of(S.voxel)
		M.hand.tint = (M.hand.tint + step) % n
		log:info("kit editor: tint " .. M.tint_label(S.voxel, M.hand.tint))
		return palette()
	end
	if not M.material_has_shapes(S.voxel) then
		log:info("kit editor: " .. S.voxel .. " has no shapes")
		return
	end
	local shapes = {""}
	local at = 1
	for _, sh in ipairs(M.SHAPES) do
		shapes[#shapes + 1] = sh
		if sh == M.hand.shape then
			at = #shapes
		end
	end
	M.hand.shape = shapes[round(at + step, #shapes)]
	log:info("kit editor: shape " .. (M.hand.shape ~= "" and
			M.hand.shape:gsub("_", " ") or "cube"))
	if O.pick_voxel then
		O.pick_voxel(S.voxel)
	end
	palette()
end

local function mouse_wheel(wheel, q)
	if not E.editing then
		return
	end
	if S.view == "walk" and S.tool == "voxels" and wheel ~= 0 and
			(M.looking() or not over_ui(S.mx, S.my)) then
		return wheel_hand(wheel, q or 0)
	end
	if over_ui(S.mx, S.my) then
		return
	end
	local notches = math.max(-10, math.min(10, wheel))
	local f = 0.8 ^ notches
	if S.view == "2d" then
		-- About the pointer: the point under it stays under it
		local o0 = M.screen_ray(S.mx, S.my)
		S.span = math.max(4, math.min(400, S.span * f))
		place_cameras()
		local o1 = M.screen_ray(S.mx, S.my)
		S.cx, S.cz = S.cx + o0.x - o1.x, S.cz + o0.z - o1.z
	elseif S.view == "3d" then
		local o, v = M.screen_ray(S.mx, S.my)
		local p = pick(S.mx, S.my, nil, true)
		local dist = p and p.t or 10
		local step = math.min(dist * (1 - f), math.max(0, dist - 0.3))
		-- [KIT_CAM_MIN_MOVE] at least a cell a notch: close to a surface,
		-- or under it, the wheel still moves along the look
		local least = math.abs(notches) * 1
		if notches ~= 0 and math.abs(step) < least then
			step = notches > 0 and least or -least
		end
		S.pos = {x = S.pos.x + v.x * step, y = S.pos.y + v.y * step,
			z = S.pos.z + v.z * step}
	end
end

-- ---- Fingers ([FP_TOUCH] 3 and 4): a tap a click, a drag on the
-- selection moves it, elsewhere the view; two pinch and pan or orbit; held
-- still the right click. Walking, the app's stick and turn, the taps and
-- the holds Kit's
local function fingers_n()
	local n = 0
	for _, f in pairs(S.fingers) do
		if not f.ui then
			n = n + 1
		end
	end
	return n
end

local function touch_begin(id, x, y)
	if not E.editing then
		return
	end
	local item = palette_at(x, y)
	local ui = over_ui(x, y)
	S.fingers[id] = {x = x, y = y, x0 = x, y0 = y,
		t0 = buildat.get_time_us(), ui = ui and not item, item = item}
	if item then
		S.palette_press = {item = item, mx = x, my = y, finger = id}
		return
	end
	if ui then
		return
	end
	if W.ctx then
		close_menu()
		S.fingers[id].ui = true
		return
	end
	S.mx, S.my = x, y
	if fingers_n() == 2 then
		-- Whatever the first began is dropped (a stroke ends where it is)
		if T.down then
			T.fill = nil
			stroke_end(x, y)
		end
		S.press, S.drag, S.panning, S.pan3d = nil, nil, false, nil
		clear_preview()
		local p = S.view == "3d" and camera_pivot(x, y) or nil
		S.gesture = {pivot = p, dist = p and (p - cam3d_node.position):Length()
			or 5}
		return
	end
	-- [KIT] stage 4f: a finger on the ground paints the terrain tool's
	-- stroke
	if S.tool == "terrain" and S.view ~= "walk" then
		S.fingers[id].stroke = stroke_begin(x, y)
		return
	end
	if S.view ~= "walk" then
		S.press = {mx = x, my = y, target = press_target(x, y), finger = id}
	end
end

local function touch_move(id, x, y, dx, dy)
	local f = S.fingers[id]
	if not f or f.ui then
		return
	end
	local px_, py_ = f.x, f.y
	f.x, f.y = x, y
	if math.abs(x - f.x0) + math.abs(y - f.y0) > px(DRAG_PX) then
		f.moved = true
	end
	local pp = S.palette_press
	if pp and pp.finger == id then
		S.mx, S.my = x, y
		if not S.drag and f.moved and not palette_at(x, y) then
			S.drag = {kind = "palette", item = pp.item}
			log:info("kit editor: dragging " .. pp.item.label .. " from the palette")
		end
		return
	end
	if f.stroke then
		S.mx, S.my = x, y
		return
	end
	if S.view == "walk" then
		return
	end
	if S.gesture then
		local o = nil
		for oid, of in pairs(S.fingers) do
			if oid ~= id and not of.ui then
				o = of
			end
		end
		if not o then
			return
		end
		local d0 = math.max(1, math.sqrt((px_ - o.x) ^ 2 + (py_ - o.y) ^ 2))
		local d1 = math.max(1, math.sqrt((x - o.x) ^ 2 + (y - o.y) ^ 2))
		local mdx, mdy = (x - px_) / 2, (y - py_) / 2
		if S.view == "2d" then
			-- About the point between the fingers, which follows them
			local w, h = screen_size()
			local ax, ay = (px_ + o.x) / 2, (py_ + o.y) / 2
			local k = S.span / h
			local wx, wz = S.cx + (ax - w / 2) * k, S.cz - (ay - h / 2) * k
			S.span = math.max(4, math.min(400, S.span * d0 / d1))
			k = S.span / h
			ax, ay = ax + mdx, ay + mdy
			S.cx, S.cz = wx - (ax - w / 2) * k, wz + (ay - h / 2) * k
		else
			local p = S.gesture.pivot
			if p then
				local q0 = rot3d()
				local inv = magic.Quaternion(q0.w, -q0.x, -q0.y, -q0.z)
				local off = inv * (magic.Vector3(S.pos.x, S.pos.y, S.pos.z) - p)
				S.yaw = S.yaw + mdx * 0.15
				S.pitch = math.max(-90, math.min(90, S.pitch + mdy * 0.15))
				local wp = p + rot3d() * off
				S.pos = {x = wp.x, y = wp.y, z = wp.z}
			end
			local fw = rot3d() * magic.Vector3(0, 0, 1)
			local zoom = S.gesture.dist * (1 - d0 / d1)
			S.gesture.dist = S.gesture.dist - zoom
			S.pos = {x = S.pos.x + fw.x * zoom, y = S.pos.y + fw.y * zoom,
				z = S.pos.z + fw.z * zoom}
		end
		return
	end
	S.mx, S.my = x, y
	if S.press and not S.drag and not S.touch_cam and f.moved then
		start_drag()
		if not S.drag then
			-- The view moves: the plan pans, the 3D camera pans
			S.touch_cam = true
			if S.view == "3d" then
				S.pan3d = pan3d_start(x, y)
			end
		end
	end
	if S.drag then
		update_drag()
	elseif S.touch_cam then
		if S.view == "2d" then
			local _, h = screen_size()
			local k = S.span / h
			S.cx, S.cz = S.cx - dx * k, S.cz + dy * k
		elseif S.pan3d then
			mouse_move(x, y, dx, dy)
		end
	end
end

local function touch_end(id, x, y)
	local f = S.fingers[id]
	S.fingers[id] = nil
	if not f then
		return
	end
	local pp = S.palette_press
	if pp and pp.finger == id then
		S.palette_press = nil
		if S.drag and S.drag.kind == "palette" then
			S.drag = nil
			if not over_ui(x, y) then
				place_at(place_cell(x, y), pp.item)
			end
		end
		-- An untouched one: its button's own tap arms it
		return
	end
	if f.stroke then
		S.mx, S.my = x, y
		stroke_end(x, y)
		return
	end
	if f.ui or f.held then
		return
	end
	if S.gesture then
		if fingers_n() == 0 then
			S.gesture = nil
			log:info(string.format("kit editor: two fingers let go: %s",
					S.view == "2d" and string.format("the plan %.1f across",
					S.span) or string.format("the camera at %.1f,%.1f,%.1f",
					S.pos.x, S.pos.y, S.pos.z)))
		end
		return
	end
	S.mx, S.my = x, y
	if S.drag then
		end_drag()
	elseif not f.moved and not S.touch_cam and S.tool == "voxels" and
			S.view == "walk" then
		-- Walking with the voxels tool, as play's: a tap digs
		voxel_click(x, y, true)
	elseif not f.moved and not S.touch_cam then
		-- A tap: the left click at the finger
		S.press = S.press or {mx = x, my = y}
		S.press.target = S.press.target or press_target(x, y)
		click()
	end
	S.press, S.touch_cam, S.pan3d = nil, nil, nil
end

-- A finger held still: the right button's ([FP_TOUCH] 4)
local function long_press_tick()
	if not S.touch or not E.editing then
		return
	end
	local only, n = nil, 0
	for fid, f in pairs(S.fingers) do
		only, n = f, n + 1
		only.id = fid
	end
	if n == 1 and not only.ui and not only.item and not only.moved and
			not only.held and not only.stroke and
			buildat.get_time_us() - only.t0 > LONG_PRESS_US then
		only.held = true
		S.press, S.drag = nil, nil
		if S.tool == "voxels" and S.view == "walk" then
			-- Walking with the voxels tool, as play's: held, it places
			voxel_click(only.x, only.y, false)
		else
			right_click({mx = only.x, my = only.y})
		end
	end
end

-- ---- Keys
local function nudge(d)
	local l = movable()
	if #l == 0 then
		return false
	end
	if #l == 1 then
		local e = l[1]
		send({op = "move", id = e.id, pos = {e.pos[1] + d[1], e.pos[2] + d[2],
			e.pos[3] + d[3]}})
	else
		local ids = {}
		for _, e in ipairs(l) do
			ids[#ids + 1] = e.id
		end
		send({op = "move", ids = ids, by = d})
	end
	return true
end

local function turn_selection(deg)
	local l = movable()
	if #l == 1 then
		local e = l[1]
		send({op = "move", id = e.id, pos = e.pos, yaw = (e.yaw or 0) + deg})
	elseif #l > 1 then
		local ids = {}
		for _, e in ipairs(l) do
			ids[#ids + 1] = e.id
		end
		send({op = "move", ids = ids, by = {0, 0, 0}, turn = deg})
	end
end

local function key_down(key, ctrl, shift)
	if key == magic.KEY_F1 then
		return set_view("2d")
	elseif key == magic.KEY_F2 then
		return set_view("3d")
	elseif key == magic.KEY_F3 then
		return set_view("walk")
	elseif key == magic.KEY_TAB then
		-- The last accessed first (S.recent), then the rest by id; Shift
		-- the other way
		local list, placed, rest = {}, {}, {}
		for _, x in ipairs(entities()) do
			if x.pos then
				placed[x.id] = true
				rest[#rest + 1] = x.id
			end
		end
		for _, id in ipairs(S.recent) do
			if placed[id] then
				list[#list + 1] = id
				placed[id] = false
			end
		end
		table.sort(rest)
		local at = 0
		for _, id in ipairs(rest) do
			if placed[id] then
				list[#list + 1] = id
			end
		end
		for i, id in ipairs(list) do
			if id == S.primary then
				at = i
			end
		end
		at = S.tab_at and list[S.tab_at] and S.tab_at or at
		if #list > 0 then
			S.tab_at = at == 0 and (shift and #list or 1) or
					(at - 1 + (shift and -1 or 1)) % #list + 1
			select(list[S.tab_at], false, true)
		end
	elseif key == magic.KEY_Z and ctrl then
		send({op = "undo"})
	elseif key == magic.KEY_C and ctrl then
		M.copy()
	elseif key == magic.KEY_V and ctrl then
		M.paste()
	elseif key == magic.KEY_D and ctrl then
		local ids = sel_ids()
		if #ids > 0 then
			send({op = "duplicate", ids = ids, by = {1, 0, 0}})
		end
	elseif key == magic.KEY_DELETE then
		M.delete_selected()
	elseif ctrl then
		return
	elseif key == magic.KEY_T and E.state and E.state.terrain then
		M.set_tool(S.tool ~= "terrain" and "terrain" or nil)
	elseif key == magic.KEY_V and E.state and E.state.voxels and O.solid then
		M.toggle_voxels()
	elseif key == magic.KEY_B and O.solid then
		M.toggle_box()
	elseif S.tool == "terrain" and (key == 91 or key == 93) then
		-- [ and ] (SDL's keycodes: Urho3D's Lua has no names for them)
		local d = key == 91 and -1 or 1
		if shift then
			M.brush_strength(d)
		else
			M.brush_size(d)
		end
	elseif key == magic.KEY_G then
		M.next_grid()
	elseif key == magic.KEY_H then
		M.next_angle()
	elseif (key == magic.KEY_Z or key == magic.KEY_X) and S.placing and
			(S.placing.prefab or S.placing.clipboard) then
		-- [KIT_PREFAB_VOXELS] a prefab or a paste turned a quarter
		S.placing.turn = ((S.placing.turn or 0) +
				(key == magic.KEY_Z and -90 or 90)) % 360
		log:info("kit editor: placing turned " .. S.placing.turn)
	elseif key == magic.KEY_Z or key == magic.KEY_X then
		turn_selection((key == magic.KEY_Z and -1 or 1) *
				(ANGLE_STEPS[S.angle] or 15))
	else
		local g = shift and 0.25 or GRID_STEPS[S.grid]
		local d = ({[magic.KEY_LEFT] = {-1, 0, 0}, [magic.KEY_RIGHT] = {1, 0, 0},
			[magic.KEY_UP] = {0, 0, 1}, [magic.KEY_DOWN] = {0, 0, -1},
			[magic.KEY_PAGEUP] = {0, 1, 0}, [magic.KEY_PAGEDOWN] = {0, -1, 0}})[key]
		-- 2D: the movement keys move the selection, a press at a time
		if not d and S.view == "2d" then
			d = ({[magic.KEY_A] = {-1, 0, 0}, [magic.KEY_D] = {1, 0, 0},
				[magic.KEY_W] = {0, 0, 1}, [magic.KEY_S] = {0, 0, -1}})[key]
		end
		if d then
			nudge({d[1] * g, d[2] * g, d[3] * g})
		end
	end
end

-- ---- What the pointer would do ([FP_GUIDES]): what it is on, framed in
-- the action's colour, and what each button does, said at the bottom
local hover = M.highlighter()
local guide_hud, guide_shown = nil, nil
local box_bars = {}

-- The box being dragged, four thin bars
local function draw_box_rect()
	local d = S.drag
	local on = d and d.kind == "box" and S.press
	if #box_bars == 0 then
		for i = 1, 4 do
			local b = magic.ui.root:CreateChild("BorderImage")
			b.color = M.HOVER
			b.priority = 50
			box_bars[i] = b
		end
	end
	for _, b in ipairs(box_bars) do
		b.visible = on and true or false
	end
	if not on then
		return
	end
	local sc = magic.ui.scale
	local x0, x1 = math.min(S.press.mx, S.mx) / sc, math.max(S.press.mx, S.mx) / sc
	local y0, y1 = math.min(S.press.my, S.my) / sc, math.max(S.press.my, S.my) / sc
	local function put(b, x, y, w, h)
		b:SetPosition(math.floor(x), math.floor(y))
		b.width, b.height = math.max(1, math.floor(w)), math.max(1, math.floor(h))
	end
	put(box_bars[1], x0, y0, x1 - x0, 1)
	put(box_bars[2], x0, y1, x1 - x0, 1)
	put(box_bars[3], x0, y0, 1, y1 - y0)
	put(box_bars[4], x1, y0, 1, y1 - y0)
end

-- The ghost of what a drop or a click would place: its cell's frame in
-- placing's colour, its name over it
local ghost_label = nil
local function ghost(cell, item)
	if not ghost_label then
		ghost_label = O.scene:CreateChild("kit_ghost_label")
		local t = ghost_label:CreateComponent("Text3D")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 14)
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		t.faceCameraMode = magic.FC_ROTATE_XYZ
		t.fixedScreenSize = true
		t.textEffect = magic.TE_STROKE
		t.effectColor = magic.Color(0, 0, 0, 0.8)
		t:SetColor(M.PLACE)
	end
	local t = ghost_label:GetComponent("Text3D")
	if not cell then
		ghost_label.enabled = false
		return
	end
	ghost_label.enabled = true
	-- Over it, and in the plan north of it
	ghost_label.position = magic.Vector3(cell[1], cell[2] + 0.8,
			cell[3] + (S.view == "2d" and 0.9 or 0))
	local label = item.label .. ((item.turn or 0) ~= 0 and
			" (turned " .. item.turn .. ")" or "")
	if t.text ~= label then
		t.text = label
	end
	hover.box(v3(cell), magic.Vector3(0.45, 0.45, 0.45), nil, M.PLACE)
	-- [KIT_PREFAB_VOXELS] a paste's voxels' box
	local lo, hi = M.placed_box(cell, item)
	if lo then
		O.debug:AddBoundingBox(magic.BoundingBox(
				magic.Vector3(lo[1] - 0.5, lo[2] - 0.5, lo[3] - 0.5),
				magic.Vector3(hi[1] + 0.5, hi[2] + 0.5, hi[3] + 0.5)),
				M.PLACE, false)
	end
end

local function compute_guide()
	local g = {}
	local mx, my = S.mx, S.my
	if M.looking() then
		local w, h = screen_size()
		mx, my = w / 2, h / 2
	end
	-- Walking at the pointer, where the app looks: a click goes up into
	-- the crosshair
	if O.mouse_look and S.view == "walk" and not S.crosshair and not S.touch then
		g.left = "into the crosshair to select and place (Esc: back)"
		g.right = "drag: turn"
		return g
	end
	local d = S.drag
	if d then
		if d.kind == "move" then
			g.left = string.format("let go: move %d by %g, %g (grid %s)",
					#d.ids, d.dx, d.dz, grid_text())
		elseif d.kind == "turn" then
			g.left = string.format("let go: turn by %g (step %s)", d.turn,
					angle_text())
		elseif d.kind == "box" then
			g.left = "let go: select what is in the box"
		elseif d.kind == "link" then
			local p = pick(mx, my, {[d.from] = true})
			local te = p and p.id and find(p.id)
			local inport = port_at("in", mx, my)
			if inport then
				-- On one of the target's inputs: its ports stay
				M.frame_entity(hover, PORTS["in"].id, M.HOVER)
				show_ports("in", PORTS["in"].id, inputs_of(find(PORTS["in"].id)))
				g.left = "let go: link to " .. PORTS["in"].id .. "'s " ..
						inport.name
			elseif te then
				local ins = inputs_of(te)
				show_ports("in", p.id, ins)
				M.frame_entity(hover, p.id, M.HOVER)
				g.left = "let go: link to " .. name_of(te) .. (#ins == 1 and "'s " ..
						ins[1].name or #ins == 0 and " (it has no inputs)" or
						": onto one of its inputs")
			else
				show_ports("in", nil)
				g.left = "let go on an entity's input to link to it"
			end
		elseif d.kind == "palette" then
			local c = not over_ui(mx, my) and place_cell(mx, my)
			if c then
				ghost(c, d.item)
				g.left = "let go: place " .. d.item.label .. " at " ..
						table.concat(c, ",")
			else
				ghost(nil)
				g.left = "let go on the view to place " .. d.item.label
			end
		end
		return g
	end
	if T.down then
		g.left = T.brush == "fill" and "let go: fill the rectangle up to " ..
				string.format("%g", T.level) or "let go: end the stroke (" ..
				T.dabs .. " dabs, one undo)"
		return g
	end
	if over_ui(mx, my) then
		return nil
	end
	if S.tool == "terrain" then
		ghost(nil)
		local right = S.view == "2d" and "drag: into 3D, orbiting" or
				S.view == "3d" and "drag: orbit" or "drag: turn"
		if brush_at(mx, my) then
			g.left = BRUSH_TEXT[T.brush] .. (T.brush == "fill" and "" or
					string.format(" (size %d, strength %d%s); drag: a stroke",
					T.size, T.strength, T.biome and ", " .. T.biome or ""))
		end
		g.right = "put the terrain tool away; " .. right
		g.note = not S.touch and "[ ]: size, Shift [ ]: strength, Esc: away" or nil
		return g
	end
	if S.tool == "box" then
		ghost(nil)
		local t = voxel_target(mx, my)
		local c = t and t.cell or place_cell(mx, my)
		-- [KIT_BOX_ADJUST] a handle: its face dragged
		local h = S.box_drag and S.box_drag.h or BX.box_handle_at(mx, my)
		if h then
			g.left = "drag: the box's " .. h.name .. " face (Shift: the " ..
					"whole box)"
		elseif c then
			hover.box(v3(c), magic.Vector3(0.5, 0.5, 0.5), nil, M.HOVER)
			g.left = ((S.vbox and not S.vbox.b) and "the box's second corner"
					or "the box's first corner") .. " at " .. table.concat(c, ",")
		end
		g.right = S.view == "2d" and "drag: into 3D, orbiting" or
				S.view == "3d" and "drag: orbit" or "drag: turn"
		g.note = not S.touch and "Ctrl+C: copy the box (and the selection), " ..
				"Ctrl+V: paste, B or Esc: put the box away" or nil
		return g
	end
	if S.tool == "voxels" and S.view == "walk" then
		-- [KIT_PLAYTEST_TWEAKS] walking as in play: left digs, right places
		ghost(nil)
		local t = voxel_target(mx, my)
		if t then
			hover.box(v3(t.cell), magic.Vector3(0.5, 0.5, 0.5), nil, M.DIG)
			if t.front then
				hover.face(t.cell, {t.front[1] - t.cell[1], t.front[2] -
						t.cell[2], t.front[3] - t.cell[3]}, M.PLACE)
			end
			g.left = "dig " .. table.concat(t.cell, ",")
			g.right = t.front and "place " .. tostring(S.voxel) .. " at " ..
					table.concat(t.front, ",") or nil
		end
		g.note = not S.touch and "V: put the voxels away" ..
				(M.looking() and ", Esc: out of the crosshair" or "") or nil
		return g
	end
	if S.tool == "voxels" then
		ghost(nil)
		local t = voxel_target(mx, my)
		if t then
			if key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT) then
				hover.box(v3(t.cell), magic.Vector3(0.5, 0.5, 0.5), nil, M.DIG)
			elseif t.front then
				hover.face(t.cell, {t.front[1] - t.cell[1], t.front[2] -
						t.cell[2], t.front[3] - t.cell[3]}, M.PLACE)
			end
			g.left = t.front and "place " .. tostring(S.voxel) .. " at " ..
					table.concat(t.front, ",") or nil
			g.shift = "dig " .. table.concat(t.cell, ",")
		end
		local p = pick(mx, my)
		g.right = (p and p.id and "its menu; " or "") .. (S.view == "2d" and
				"drag: into 3D, orbiting" or S.view == "3d" and "drag: orbit" or
				"drag: turn")
		g.note = not S.touch and "V or Esc: put the voxels away" or nil
		return g
	end
	if S.placing then
		local c = place_cell(mx, my)
		ghost(c, S.placing)
		g.left = c and "place " .. S.placing.label .. " at " ..
				table.concat(c, ",") or nil
		g.right = "stop placing"
		g.note = "Esc: stop placing"
		return g
	end
	ghost(nil)
	if near_knob(mx, my) then
		local k = knob()
		hover.box(k, magic.Vector3(0.15, 0.15, 0.15), nil, M.HOVER)
		g.left = "drag: turn the selection (step " .. angle_text() .. ")"
		return g
	end
	local port = port_at("out", mx, my)
	if port then
		g.left = "drag: link " .. port.name .. " to another's input"
		return g
	end
	local p = pick(mx, my)
	local e = p and p.id and find(p.id)
	local right_drag = S.view == "2d" and "drag: into 3D, orbiting" or
			S.view == "3d" and "drag: orbit round what the pointer is on" or
			"drag: turn"
	if e then
		M.frame_entity(hover, e.id, M.HOVER)
		local name = name_of(e)
		local shift = key_held(magic.KEY_LSHIFT) or key_held(magic.KEY_RSHIFT)
		if shift then
			g.left = (S.sel[e.id] and "take " .. name .. " out of" or "add " ..
					name .. " to") .. " the selection"
		elseif S.sel[e.id] then
			g.left = "keep " .. name .. " selected; drag: move the selection"
		else
			g.left = "select " .. name .. (S.touch and "" or
					"; drag: select by a box")
		end
		local _, is_made = find(e.id)
		g.right = (is_made and "" or "its menu; ") .. right_drag
	else
		g.left = S.touch and (next(S.sel) and "let go of the selection") or
				(next(S.sel) and "let go of the selection; drag: select by a box" or
				"drag: select by a box")
		g.right = (next(S.sel) and "let go of the selection; " or "") .. right_drag
	end
	if S.view ~= "walk" then
		g.middle = "drag: pan the view"
	end
	return g
end

local function guide_text(g)
	if not g then
		return ""
	end
	local lines = {}
	local names = S.touch and {{"left", "Tap"}, {"right", "Hold"}} or
			{{"left", "Left"}, {"shift", "Shift+left"}, {"right", "Right"},
			{"middle", "Middle"}}
	for _, b in ipairs(names) do
		local t = g[b[1]]
		if t and S.touch then
			t = t:gsub("; drag: [^;]*", ""):gsub("^drag: [^;]*;? ?", "")
			if t == "" then
				t = nil
			end
		end
		if t then
			lines[#lines + 1] = b[2] .. ": " .. t
		end
	end
	if g.note then
		lines[#lines + 1] = g.note
	end
	return table.concat(lines, "\n")
end

local function draw_guide()
	if not guide_hud then
		guide_hud = magic.ui.root:CreateChild("Text")
		guide_hud:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 15)
		guide_hud:SetAlignment(magic.HA_CENTER, magic.VA_BOTTOM)
		guide_hud:SetTextEffect(magic.TE_SHADOW)
		guide_hud:SetTextAlignment(magic.HA_CENTER)
		guide_hud.priority = 90
	end
	local s = ""
	if E.editing and not (E.menu and E.menu.held()) then
		s = guide_text(compute_guide())
	else
		ghost(nil)
	end
	if s ~= guide_shown then
		guide_shown = s
		guide_hud:SetText(s)
		if s ~= "" then
			log:info("kit editor: guide: " .. s:gsub("\n", " | "))
		end
	end
	-- Over the touch bar, and on a narrow screen over the people's panel
	local y = W.touch and W.touch.height + 20 or 12
	if narrow() and W.people then
		y = math.max(y, W.people.height + 58)
	end
	guide_hud:SetPosition(0, -y)
end

-- ---- Drawing: every entity a box, the selection yellow, gizmos, zones,
-- links, the cursor, the knob, the link being dragged, the builders
-- [KIT] stage 4l: the links shown in play, for every player: drawn as in
-- edit mode, lit 0.6 s as a signal passes
local function draw_play_links()
	local dbg = O.debug
	local now = buildat.get_time_us()
	E.play_drawn = E.play_drawn or {}
	for id, n in pairs(P.nodes) do
		local show = type(n.show) == "table" and n.show or {}
		-- [KIT] stage 4j: a region's border, its show_border on (its size
		-- as a resize has it)
		if show.border and type(show.region) == "table" and n.node and
				n.node:GetVar("kit:enabled"):GetString() ~= "false" then
			local sz = network.parse_json(n.node:GetVar("kit:size"):GetString())
			if type(sz) ~= "table" then
				sz = show.region
			end
			local p = n.node.position
			local o = magic.Vector3(math.floor(p.x + 1e-4) - 0.5,
					math.floor(p.y + 1e-4) - 0.5, math.floor(p.z + 1e-4) - 0.5)
			local e = {}
			for i = 1, 3 do
				e[i] = math.max(1, math.min(64, math.floor(tonumber(sz[i]) or 1)))
			end
			dbg:AddBoundingBox(magic.BoundingBox(o, magic.Vector3(o.x + e[1],
					o.y + e[2], o.z + e[3])), magic.Color(1, 0.3, 0.3), true)
			local key = "border " .. id
			local was = E.play_drawn[key]
			local now_s = table.concat(e, "x")
			if was ~= now_s then
				E.play_drawn[key] = now_s
				log:info("kit: region " .. id .. " border " .. now_s ..
						" drawn in play")
			end
		end
		for _, to in ipairs(type(show.links) == "table" and show.links or {}) do
			local o = P.nodes[to]
			if o and n.node and o.node then
				local a, b = n.at or n.node.position, o.at or o.node.position
				local key = id .. ">" .. tostring(to)
				local lit = (E.flows[key] or 0) > now
				local col = lit and magic.Color(1, 1, 0.3) or
						magic.Color(0.2, 1, 0.4)
				dbg:AddLine(a, b, col, false)
				dbg:AddCross(magic.Vector3(a.x + (b.x - a.x) * 0.85,
						a.y + (b.y - a.y) * 0.85, a.z + (b.z - a.z) * 0.85),
						lit and 0.6 or 0.3, col, false)
				local was = E.play_drawn[key]
				if was ~= (lit and "lit" or "drawn") then
					E.play_drawn[key] = lit and "lit" or "drawn"
					log:info("kit: link " .. key .. " " .. E.play_drawn[key] ..
							" in play")
				end
			end
		end
	end
end

local function draw()
	if not E.editing then
		show_ports("out", nil)
		show_ports("in", nil)
		draw_play_links()
		return
	end
	fit_people()
	log_bar()
	local dbg = O.debug
	local now = buildat.get_time_us()
	-- A Try's answer shown long enough
	if E.tried and now >= E.tried.till then
		E.tried = nil
		inspector_window()
	end
	local YELLOW = magic.Color(1, 0.9, 0.2)
	-- [KIT_PREFAB_VOXELS] the Box tool's box (its first corner alone
	-- until the second)
	local vb = S.vbox
	if vb and vb.a then
		local a, b = vb.a, vb.b or vb.a
		dbg:AddBoundingBox(magic.BoundingBox(
				magic.Vector3(math.min(a[1], b[1]) - 0.5,
					math.min(a[2], b[2]) - 0.5, math.min(a[3], b[3]) - 0.5),
				magic.Vector3(math.max(a[1], b[1]) + 0.5,
					math.max(a[2], b[2]) + 0.5, math.max(a[3], b[3]) + 0.5)),
				magic.Color(0.3, 1, 0.5), false)
		-- [KIT_BOX_ADJUST] its handles, the axes' colours, the one under
		-- the pointer or dragged yellow
		local under = S.box_drag and S.box_drag.h or
				BX.box_handle_at(S.mx or 0, S.my or 0)
		local AXIS_COLOURS = {magic.Color(1, 0.35, 0.3),
			magic.Color(0.4, 1, 0.4), magic.Color(0.35, 0.6, 1)}
		for _, h in ipairs(BX.box_handles()) do
			local r = 0.2
			dbg:AddBoundingBox(magic.BoundingBox(
					h.at - magic.Vector3(r, r, r), h.at + magic.Vector3(r, r, r)),
					(under and under.name == h.name) and YELLOW or
					AXIS_COLOURS[h.k], false)
		end
	end
	-- The round's own entities, orange (players are drawn by the app)
	for _, e in ipairs(made()) do
		if e.pos and e.kind ~= "player" then
			local c = drawn_at(e)
			dbg:AddBoundingBox(magic.BoundingBox(
					magic.Vector3(c.x - 0.35, c.y - 0.35, c.z - 0.35),
					magic.Vector3(c.x + 0.35, c.y + 0.35, c.z + 0.35)),
					S.sel[e.id] and YELLOW or magic.Color(1, 0.55, 0.1), false)
		end
	end
	for _, e in ipairs(entities()) do
		if e.pos then
			local m = drawn_at(e)
			local x, y, z = m.x, m.y, m.z
			dbg:AddBoundingBox(magic.BoundingBox(
					magic.Vector3(x - 0.4, y - 0.4, z - 0.4),
					magic.Vector3(x + 0.4, y + 0.4, z + 0.4)),
					S.sel[e.id] and YELLOW or magic.Color(0.8, 0.8, 0.8), false)
			if S.sel[e.id] and P.nodes[e.id] and P.nodes[e.id].box then
				-- Its look's outline too
				local c, half, rot = K.look_frame(P.nodes[e.id])
				if c then
					hover.box(c, half, rot, YELLOW)
				end
			end
			for _, c in ipairs(e.components or {}) do
				local g = type_of(c.type).gizmo
				if type(g) == "table" then
					local col = color(g.color, magic.Color(0.3, 0.9, 1))
					local s = tonumber(g.size) or 0.5
					if g.shape == "box" then
						dbg:AddBoundingBox(magic.BoundingBox(
								magic.Vector3(x - s, y - s, z - s),
								magic.Vector3(x + s, y + s, z + s)), col, false)
					else
						dbg:AddSphere(magic.Sphere(m, s), col, false)
					end
				end
				-- A zone's and an owned volume's extent, from its cell on
				local t = type_of(c.type)
				for _, k in ipairs({"zone", "volume", "grants", "voxel_box",
						"region"}) do
					local n = t[k] and c.params and c.params[t[k]]
					if type(n) == "table" then
						local ext = {}
						for i = 1, 3 do
							ext[i] = math.max(1, math.floor(tonumber(n[i]) or 1))
						end
						dbg:AddBoundingBox(magic.BoundingBox(
								magic.Vector3(x - 0.5, y - 0.5, z - 0.5),
								magic.Vector3(x + ext[1] - 0.5, y + ext[2] - 0.5,
								z + ext[3] - 0.5)), k == "zone" and
								magic.Color(0.3, 0.75, 1) or k == "voxel_box" and
								magic.Color(0.63, 0.38, 0.88) or k == "region" and
								magic.Color(1, 0.3, 0.3) or magic.Color(1, 0.6, 0.2),
								false)
					end
				end
				for _, l in ipairs(c.links or {}) do
					local to = find(l.to)
					if to and to.pos then
						local a, b = m, drawn_at(to)
						-- Lit while a signal passes ([KIT] stage 4d)
						local lit = (E.flows[e.id .. ">" .. l.to] or 0) > now
						local col = lit and magic.Color(1, 1, 0.3) or
								magic.Color(0.2, 1, 0.4)
						dbg:AddLine(a, b, col, false)
						dbg:AddCross(magic.Vector3(a.x + (b.x - a.x) * 0.85,
								a.y + (b.y - a.y) * 0.85, a.z + (b.z - a.z) * 0.85),
								lit and 0.6 or 0.3, col, false)
					end
				end
			end
		end
	end
	if E.cursor then
		dbg:AddCross(magic.Vector3(E.cursor[1], E.cursor[2] - 0.5,
				E.cursor[3]), 0.8, magic.Color(1, 0.4, 1), false)
	end
	-- The knob, and the turn being dragged
	local k, c, r = knob()
	if k then
		dbg:AddCircle(c, magic.Vector3(0, 1, 0), r, YELLOW, 32, false)
		dbg:AddLine(c, k, YELLOW, false)
		dbg:AddSphere(magic.Sphere(k, 0.12), YELLOW, false)
	end
	-- The ports: the selected one's outputs (none in a drag of another kind)
	local e = S.primary and find(S.primary)
	local _, is_made = nil, false
	if e then
		_, is_made = find(S.primary)
	end
	local d = S.drag
	if e and not is_made and (not d or d.kind == "link") and not M.looking() then
		show_ports("out", e.id, outputs_of(e))
	else
		show_ports("out", nil)
	end
	if not d or d.kind ~= "link" then
		show_ports("in", nil)
	else
		local from = find(d.from)
		local o, v = M.screen_ray(S.mx, S.my)
		local p = pick(S.mx, S.my, {[d.from] = true})
		local to = o + v * (p and p.t or 6)
		if from and from.pos then
			dbg:AddLine(drawn_at(from), to, M.HOVER, false)
		end
	end
	draw_box_rect()
	draw_edited(dbg, S.mx, S.my)
	if not (E.menu and E.menu.held()) then
		local mx, my = S.mx, S.my
		if M.looking() then
			local w, h = screen_size()
			mx, my = w / 2, h / 2
		end
		draw_brush(dbg, mx, my)
	end
end

-- The other builders' names over what they have selected
local function label_of(name, col)
	local l = E.labels[name]
	if not l then
		l = O.scene:CreateChild("kit_builder_label")
		local t = l:CreateComponent("Text3D")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 14)
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		t.faceCameraMode = magic.FC_ROTATE_XYZ
		t.fixedScreenSize = true
		t.textEffect = magic.TE_STROKE
		t.effectColor = magic.Color(0, 0, 0, 0.8)
		E.labels[name] = l
	end
	if E.label_text[name] ~= name then
		local t = l:GetComponent("Text3D")
		t:SetColor(col)
		t.text = name
		E.label_text[name] = name
	end
	return l
end

local function draw_builders(dbg)
	local shown = {}
	for _, b in ipairs(E.editing and E.builders or {}) do
		if not b.you then
			local c = color(b.color, magic.Color(1, 1, 1))
			local e = (tonumber(b.sel) or 0) > 0 and find(b.sel)
			if e and e.pos then
				local x, y, z = e.pos[1], e.pos[2], e.pos[3]
				dbg:AddBoundingBox(magic.BoundingBox(
						magic.Vector3(x - 0.5, y - 0.5, z - 0.5),
						magic.Vector3(x + 0.5, y + 0.5, z + 0.5)), c, false)
				local l = label_of(tostring(b.name), c)
				l.position = magic.Vector3(x, y + 0.9, z)
				shown[tostring(b.name)] = true
			end
			if type(b.cursor) == "table" then
				dbg:AddCross(magic.Vector3(b.cursor[1], b.cursor[2] - 0.5,
						b.cursor[3]), 0.8, c, false)
			end
		end
	end
	for name, l in pairs(E.labels) do
		if not shown[name] and E.label_text[name] ~= "" then
			l:GetComponent("Text3D").text = ""
			E.label_text[name] = ""
		end
	end
end

-- ---- The editor turned on
function M.editor(options)
	for k, v in pairs(options) do
		O[k] = v
	end
	O.ground_y = O.ground_y or 0
	-- The scene's own one where it has it (the replicated scene does): the
	-- view draws the first
	O.debug = O.scene:GetComponent("DebugRenderer") or
			O.scene:CreateComponent("DebugRenderer")
	make_cameras()
	rebuild_bar()

	buildat.sub_packet("kit:edit_state", function(data)
		local s = network.parse_json(data)
		if type(s) ~= "table" then
			return
		end
		local was = E.editing
		E.editing = s.editing == true
		if E.can_edit ~= (s.can_edit == true) then
			E.can_edit = s.can_edit == true
			log:info("kit editor: edit rights: " .. (E.can_edit and "yes" or "no"))
			if E.can_edit and not E.editing then
				ui_utils.show_notification("You may edit here: Edit, or F6", 4)
			end
		end
		for _, p in ipairs(s.people or {}) do
			log:info("kit editor: people: " .. tostring(p.name) ..
					(p.admin and " admin" or p.builder and " builder" or " player"))
		end
		if E.editing and #(s.voxels or {}) ~= #((E.state or {}).voxels or {}) then
			log:info("kit editor: " .. #(s.voxels or {}) .. " voxels to place")
		end
		-- [AITTA_KEY_IDENTITY] A package's name as people read it, said
		-- when it changes (its Aitta's vouch, a second "alice")
		local old_names = (E.state or {}).names or {}
		for id, label in pairs(E.editing and type(s.names) == "table" and
				s.packages or {}) do
			local l = s.names[id]
			if l and l ~= old_names[id] then
				log:info("kit editor: installed " .. tostring(l) .. " as " .. id)
			end
		end
		-- Entities new since the last state (placed, duplicated): Tab's
		-- order's top
		if E.editing then
			local known = {}
			for _, e in ipairs(s.authored and s.authored.entities or {}) do
				known[e.id] = true
				if S.known and not S.known[e.id] then
					touch(e.id)
				end
			end
			S.known = known
		end
		E.state = E.editing and s or nil
		-- [KIT_SCENES] the scene edited, and the composition's
		if E.state and (E.state.scene ~= E.scene_logged or
				#(E.state.scenes or {}) ~= E.scenes_logged) then
			E.scene_logged = E.state.scene
			E.scenes_logged = #(E.state.scenes or {})
			log:info("kit editor: in the scene " .. tostring(E.state.scene) ..
					" of " .. table.concat(E.state.scenes or {}, ", "))
		end
		if was ~= E.editing then
			log:info("kit editor: edit mode " .. (E.editing and "on" or "off"))
			E.link, E.status = nil, ""
			S.drag, S.press, S.placing, S.crosshair = nil, nil, nil, false
			T.down, T.fill = false, nil
			drop("ctx")
			drop("dialog")
			if not E.editing then
				E.builders = {}
			end
			apply_viewport()
		end
		E.credits = type(s.credits) == "table" and s.credits or {}
		E.discarded = type(s.discarded) == "table" and s.discarded or {}
		E.always_keep = s.always_keep == true
		if not next(E.discarded) then
			E.choose = false
		end
		if E.running ~= (s.running == true) or E.by ~= tostring(s.by or "") then
			E.running, E.by = s.running == true, tostring(s.by or "")
			log:info("kit editor: the server is " .. (E.running and "Running" or
					"Ended") .. " (by " .. E.by .. ")")
		end
		if E.editing then
			local n = #entities()
			log:info("kit editor: state: " .. n .. " entities, " ..
					tostring(s.undo) .. " to undo")
			for _, e in ipairs(entities()) do
				local links = {}
				for _, c in ipairs(e.components or {}) do
					for _, l in ipairs(c.links or {}) do
						links[#links + 1] = l.output .. "->" .. l.to .. "." ..
								l.input
					end
				end
				log:verbose("kit editor: entity " .. e.id .. " " ..
						tostring(e.name) .. (e.pos and " at " ..
						table.concat(e.pos, ",") or "") .. ((e.yaw or 0) ~= 0 and
						" yaw " .. e.yaw or "") .. " links " ..
						table.concat(links, " "))
			end
			for id in pairs(S.sel) do
				if not find(id) then
					S.sel[id] = nil
				end
			end
			if S.primary and not find(S.primary) then
				S.primary = next(S.sel)
			end
		end
		refresh()
		changed()
		if E.editing and S.tool == "terrain" then
			send({op = "edited"})
		end
	end)
	-- [KIT_TRY_INPUTS] A Try's answer: what the entity emitted ("→ opened"),
	-- in the inspector for 3 s
	buildat.sub_packet("kit:tried", function(data)
		local a = network.parse_json(data)
		if type(a) ~= "table" then
			return
		end
		local outs = {}
		for _, o in ipairs(type(a.emitted) == "table" and a.emitted or {}) do
			local v = type(o) == "table" and o[2]
			outs[#outs + 1] = tostring(type(o) == "table" and o[1]) ..
					(v ~= nil and type(v) ~= "table" and " " .. tostring(v) or "")
		end
		local t = "→ " .. (#outs > 0 and table.concat(outs, ", ") or
				"nothing emitted")
		E.tried = {id = tonumber(a.id), text = t,
			till = buildat.get_time_us() + 3000000}
		log:info("kit editor: tried " .. tostring(a.id) .. "'s " ..
				tostring(a.input) .. ": " .. t)
		inspector_window()
	end)
	-- [KIT_VOXEL_EDITS] The edited sections, the terrain panel's list
	buildat.sub_packet("kit:edited", function(data)
		local a = network.parse_json(data)
		if type(a) ~= "table" then
			return
		end
		ED.list = a
		local parts = {}
		local secs = type(a.sections) == "table" and a.sections or {}
		for i = 1, math.min(#secs, 16) do
			parts[i] = table.concat(secs[i].s or {}, ",") .. "=" ..
					tostring(secs[i].cells)
		end
		log:info("kit editor: edited sections: " .. #secs .. " " ..
				table.concat(parts, " "))
		if S.tool == "terrain" then
			palette()
		end
	end)
	buildat.sub_packet("kit:builders", function(data)
		local a = network.parse_json(data)
		E.builders = type(a) == "table" and a or {}
		for _, b in ipairs(E.builders) do
			local name = tostring(b.name)
			local was = E.seen[name] or {}
			local cur = type(b.cursor) == "table" and table.concat(b.cursor, ",") or
					"none"
			if not b.you and (was.sel ~= b.sel or was.cursor ~= cur) then
				log:info("kit editor: builder " .. name .. " (" .. tostring(b.color) ..
						") selects " .. tostring(b.sel) .. ", cursor " .. cur)
			end
			E.seen[name] = {sel = b.sel, cursor = cur}
		end
		people()
	end)
	-- [KIT] stage 4d: signals passing along links light their lines, and
	-- the selected entity's log
	buildat.sub_packet("kit:flow", function(data)
		local a = network.parse_json(data)
		local till = buildat.get_time_us() + 600000
		for _, f in ipairs(type(a) == "table" and a or {}) do
			E.flows[tostring(f[1]) .. ">" .. tostring(f[3])] = till
			log:info("kit editor: signal " .. tostring(f[1]) .. "." ..
					tostring(f[2]) .. " -> " .. tostring(f[3]) .. "." ..
					tostring(f[4]))
		end
	end)
	-- [KIT] stage 4l: the costs, every few seconds while editing
	buildat.sub_packet("kit:costs", function(data)
		local c = network.parse_json(data)
		if type(c) ~= "table" then
			return
		end
		E.costs = c
		if S.cost_text and S.cost_id then
			local line = M.cost_line(S.cost_id)
			S.cost_text.text = line
			-- [KIT_COST_LOG_FLAKY] Told once a line, also when the inspector
			-- showed it already (the costs in before the selection)
			local said = S.cost_said
			if not said or said.id ~= S.cost_id or said.line ~= line then
				S.cost_said = {id = S.cost_id, line = line}
				log:info("kit editor: entity " .. S.cost_id .. ": " .. line)
			end
		end
	end)
	buildat.sub_packet("kit:log", function(data)
		local l = network.parse_json(data)
		if type(l) ~= "table" or type(l.lines) ~= "table" then
			return
		end
		E.logs[tonumber(l.id) or 0] = l.lines
		log:info("kit editor: log of " .. tostring(l.id) .. ": " ..
				tostring(l.lines[#l.lines]))
		show_log()
	end)
	-- [KIT] stage 4f: a terrain dab's answer
	buildat.sub_packet("kit:terrain", function(data)
		local a = network.parse_json(data)
		if type(a) == "table" then
			log:info("kit editor: terrain: " .. tostring(a.what) .. " (" ..
					tostring(a.undo) .. " to undo)")
		end
	end)
	-- [KIT] stage 4g: an upload's name, the dialog's texture
	buildat.sub_packet("kit:texture", function(data)
		E.voxel_form.texture = data
		log:info("kit editor: uploaded " .. data)
		if W.dialog then
			M.voxel_dialog()
		end
	end)
	-- [KIT] stage 5: an install's answer, and the export to publish
	buildat.sub_packet("kit:package", function(data)
		local a = network.parse_json(data)
		if type(a) ~= "table" then
			return
		end
		E.status = a.ok and "Package: " .. tostring(a.what) or
				"Package refused: " .. tostring(a.why)
		log:info("kit editor: " .. E.status)
		if E.editing then
			people()
		else
			ui_utils.show_notification(E.status, 4)
		end
	end)
	buildat.sub_packet("kit:export", function(data)
		local a = network.parse_json(data)
		if type(a) ~= "table" then
			return
		end
		log:info("kit editor: the export of " .. tostring(a.author))
		aitta.kit_publish({name = E.package_name, author = a.author,
			files = a.files, hex = a.hex, dependencies = a.dependencies})
	end)
	buildat.sub_packet("kit:edit_refused", function(data)
		E.status = "Refused: " .. tostring(data)
		log:info("kit editor: refused: " .. tostring(data))
		clear_preview()
		if E.editing then
			people()
		else
			ui_utils.show_notification(E.status, 4)
		end
	end)
	magic.SubscribeToEvent("KeyDown", function(_, data)
		local key = data:GetInt("Key")
		if typing() then
			return
		end
		if key == magic.KEY_F6 then
			return M.toggle_tools()
		end
		if E.editing and not (E.menu and E.menu.held()) then
			local q = data:GetInt("Qualifiers")
			key_down(key, q == magic.QUAL_CTRL, q == magic.QUAL_SHIFT)
		end
	end)
	magic.SubscribeToEvent("MouseButtonDown", function(_, data)
		local m = magic.input:GetMousePosition()
		if not M.looking() then
			S.mx, S.my = m.x, m.y
		end
		mouse_down(data:GetInt("Button"))
	end)
	magic.SubscribeToEvent("MouseButtonUp", function(_, data)
		mouse_up(data:GetInt("Button"))
	end)
	magic.SubscribeToEvent("MouseMove", function(_, data)
		if not E.editing or S.touch then
			return
		end
		mouse_move(data:GetInt("X"), data:GetInt("Y"), data:GetInt("DX"),
				data:GetInt("DY"))
	end)
	magic.SubscribeToEvent("MouseWheel", function(_, data)
		if S.touch then
			return
		end
		mouse_wheel(data:GetInt("Wheel"), data:GetInt("Qualifiers"))
	end)
	magic.SubscribeToEvent("TouchBegin", function(_, data)
		if S.touch then
			touch_begin(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"))
		end
	end)
	magic.SubscribeToEvent("TouchMove", function(_, data)
		if S.touch then
			touch_move(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"),
					data:GetInt("DX"), data:GetInt("DY"))
		end
	end)
	magic.SubscribeToEvent("TouchEnd", function(_, data)
		if S.touch then
			touch_end(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"))
		end
	end)
	magic.SubscribeToEvent("Update", function(_, data)
		local dt = data:GetFloat("TimeStep")
		if S.uploading then
			local name, png = buildat.picked_file()
			if name then
				S.uploading = false
				log:info("kit editor: uploading " .. name)
				buildat.send_packet("kit:texture", png)
			elseif png then
				S.uploading = false
				E.status = tostring(png)
				people()
			end
		end
		if E.editing then
			move_camera(dt)
			place_cameras()
			long_press_tick()
			if T.down then
				stroke_move(S.mx, S.my)
			end
		end
		hover.begin()
		-- The frames' bars: vanilla's, and in the plan about 3 pixels
		local _, sh = screen_size()
		hover.w = E.editing and S.view == "2d" and 3 * S.span / math.max(1, sh) or
				nil
		draw()
		draw_guide()
		hover.finish()
		draw_builders(O.debug)
	end)
end
end
-- vim: set noet ts=4 sw=4:
