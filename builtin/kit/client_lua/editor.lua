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
-- Menu button; Escape's otherwise).
-- F6 or "Edit" asks the server for edit mode; with edit rights (the
-- server's admin, a builder) the server answers with the palette and the
-- authored tree. Floorplanner's, here:
--   - **Three views**, the top bar's dropdown or F1, F2, F3: 2D (an
--     orthographic camera looking down from the cut height, which the
--     bar's Cut - and + move, north up), 3D (a free camera: WASD, Space
--     and C, Shift faster; the arrows turn it with nothing selected), and
--     walking (the app's own camera and its walk). 2D: the middle drag
--     and WASD pan, the wheel zooms about the pointer; a right drag goes
--     into 3D orbiting, let go north-up straight down back into the plan.
--     3D: the right drag orbits round what the pointer is on, the middle
--     drag pans, the wheel goes toward it. Walking at the pointer, the
--     right drag turns; a click on the view goes up into the crosshair
--     (the mouse looks, the clicks act at the crosshair) and Escape comes
--     back down.
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
--     editor's last edit, Tab selects the next entity
--   - **The palette** (left): a type or prefab dragged onto the view goes
--     where it is let go (its ghost there meanwhile), or clicked it is
--     placed by the clicks on the view until Escape, a right click or a
--     click on it again (floorplanner's Object tool)
--   - **Links dragged**: the selected entity's outputs are ports beside
--     it; one dragged onto another entity's input (its ports show as the
--     drag is over it) links them, onto the entity a link to its one
--     input. The inspector's "Link <output>" and then "To <input>" too
--   - **A right click** (held, it looks) on an entity: its menu -- Delete,
--     Duplicate, Make prefab..., Restart this (Running) -- for the
--     selection if it is in it; on nothing it lets go of the selection
--   - the inspector (right): the selected entity's instances, their
--     parameters in ui_utils' settings_form, "Apply" sends them
--   - every entity drawn as a box, the selected ones yellow, links as
--     lines, and a type's gizmo (a sphere or a box), in edit mode only
--   - the admin's: who is here, each "Builder: yes/no" to grant or take
--     edit rights; ([KIT] stage 4c) the builders with the tools on, each
--     in a colour: another's selection outlined in theirs with their name
--     over it, their cursor a cross; game-wide entities (on the app root)
--     listed to select; "Save as start" (the bar, Running); the builds the
--     last Stop discarded until the next Play: "Keep them", or "Choose..."
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
-- are on; F6) and the server's state ("Play" while Stopped, "Stop" while
-- Running); kit.editor{bar = false} leaves it out of play for an app's own
-- menu (the tools always have theirs): kit.can_edit(), kit.editing(),
-- kit.running() (and kit.by(), who), and kit.set_tools(on),
-- kit.toggle_tools(), kit.play(), kit.stop(), kit.save_as_start() do what
-- the bar does; kit.on_change(fn) calls fn() as any of the states changes.
-- kit.add_menu_items(menu) puts Edit and Play/Stop in extensions/
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
		choose = false, prefab_name = "", logs = {}, flows = {}}) do
	init(E, k, v)
end
-- Floorplanner's S: the view, the cameras and what the pointer is doing
local S = {view = "walk", sel = {}, primary = nil, grid = 1, angle = 4,
	pos = nil, yaw = 0, pitch = 30, cx = 0, cz = 0, span = 24, cut = nil,
	press = nil, drag = nil, right_click = nil, mx = 0, my = 0,
	placing = nil, crosshair = false, fingers = {}, folds = {},
	touch = buildat.get_env("BUILDAT_TOUCH") == "1"}
M.S = S

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

function M.save_as_start()
	send({op = "save_start"})
end

-- What this builder has selected and their cursor, for the others
local function focus()
	send({op = "focus", sel = S.primary or 0, cursor = E.cursor})
end

local function entities()
	local r = {}
	for _, e in ipairs(E.state and E.state.authored and
			E.state.authored.entities or {}) do
		r[#r + 1] = e
	end
	return r
end

-- [KIT] stage 4d: the round's own entities (made in play) and the players,
-- shown and selected, not edited
local function made()
	return E.state and E.state.made or {}
end

local function find(id)
	for _, e in ipairs(entities()) do
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

-- What the pointer is on: an entity (the nearest along the ray: its look,
-- or a box round its cell), else a voxel (and the cell before its face),
-- else the ground. {id, t} or {cell, front, t} or {ground} or nil
local function pick(mx, my, skip)
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
	if id and (not hit or et <= vt + 0.05) then
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
		local hit, front = M.voxel_ray({o.x, o.y, o.z}, {v.x, v.y, v.z},
				O.solid, MAX_RAY)
		if hit then
			return front
		end
	end
	return ground_at(o, v)
end

-- ---- The panels: floorplanner's -- a slim bar at the top, the palette at
-- the left and the inspector at the right under it, folded away on a
-- narrow screen ([FP_TOUCH] 2) and opened from the bar, one at a time
local W = {} -- the windows: bar, palette, inspector, people, log, ctx, dialog, touch
local function narrow()
	return magic.ui.root.width < 700 or magic.ui.root.height < 500
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

local refresh, people, show_log, rebuild_bar, set_view

-- The bar: Edit and Play/Stop in play (an app's own menu can have them:
-- bar = false); in the tools floorplanner's toolbar -- Menu, the views,
-- the grid, the angle step, the cut, Undo, Save as start, Play/Stop, Play
-- mode, and on a narrow screen the panels' toggles
-- The bar's buttons in rows, as many as the screen's width needs
-- ([FP_TOUCH] 2, floorplanner's build_toolbar): place(make) puts what
-- make(parent) makes in the row it fits in
local bar_row, bar_used, bar_room, bar_first
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
	return place(function(parent) return button(parent, s, fn, down) end)
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
	if not E.can_edit or (not E.editing and O.bar == false) then
		return
	end
	-- The tools' at the top left, as floorplanner's toolbar
	local w = E.editing and window(magic.HA_LEFT, magic.VA_TOP, 8, 4, true) or
			window(magic.HA_CENTER, magic.VA_TOP, 0, 4, true)
	W.bar = w
	if not E.editing then
		button(w, "Edit", M.toggle_tools)
		button(w, E.running and "Stop" or "Play", function()
			if E.running then M.stop() else M.play() end
		end)
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
	if E.running then
		bar_button("Save as start", nil, M.save_as_start)
	end
	bar_button(E.running and "Stop" or "Play", nil, function()
		if E.running then M.stop() else M.play() end
	end)
	bar_button("Play mode", nil, M.toggle_tools)
	if narrow() then
		for _, p in ipairs({{"palette", "Palette"}, {"inspector", "Inspector"}}) do
			bar_button(p[2], nil, function()
				toggle_fold(p[1])
				refresh()
			end, not folded(p[1]))
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
-- clicks on the view), a drag puts one where it is let go
local palette_buttons = {}
local palette
palette = function()
	drop("palette")
	palette_buttons = {}
	if not E.editing or folded("palette") then
		return
	end
	local y = W.bar and W.bar.height + 12 or 40
	local w = window(magic.HA_LEFT, magic.VA_TOP, 8, y)
	W.palette = w
	text(w, "Palette", DIM)
	local items = {}
	for _, t in ipairs(E.state.palette or {}) do
		items[#items + 1] = {label = t, type = t}
	end
	for _, p in ipairs(E.state.prefabs or {}) do
		items[#items + 1] = {label = "[" .. p .. "]", prefab = p}
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
				S.placing = {type = it.type, prefab = it.prefab, label = it.label}
				log:info("kit editor: placing " .. it.label)
			end
			palette()
		end, armed)
		palette_buttons[#palette_buttons + 1] = {button = b, item = it}
	end
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
	elseif t == "prefab" then
		f.type = "choice"
		f.choices = {{"none", ""}}
		for _, p in ipairs(E.state.prefabs or {}) do
			f.choices[#f.choices + 1] = {p, p}
		end
	elseif t == "number" or t == "bool" then
		f.type = t
	elseif t == "entity" then
		f.type = "choice"
		f.choices = {{"none", 0}}
		for _, e in ipairs(entities()) do
			f.choices[#f.choices + 1] = {e.id .. " " .. tostring(e.name), e.id}
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
	text(w, e.kind == "player" and "A player" or ("Made in play" ..
			(e.made == "b" and " by " .. tostring(e.made_by) or "") ..
			", by entity " .. tostring(e.maker) .. ": gone at Stop"), DIM)
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
	if e.pos then
		text(w, string.format("at %g, %g, %g", e.pos[1], e.pos[2], e.pos[3]) ..
				((e.yaw or 0) ~= 0 and string.format(", turned %g", e.yaw) or ""),
				DIM)
	end
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
		for k, v in pairs(c.params or {}) do
			values[k] = v
		end
		for _, k in ipairs(names) do
			fields[#fields + 1] = field(k, decl[k], values)
		end
		if #fields > 0 then
			local key = e.id .. "/" .. ci
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
		for _, l in ipairs(c.links or {}) do
			local r = row(w)
			local to = find(l.to)
			label(r, l.output .. " -> " .. l.to .. " " .. tostring(to and
					to.name or "?") .. ": " .. l.input)
			button(r, "Unlink", function()
				send({op = "unlink", id = e.id, comp = ci - 1,
					output = l.output, to = l.to, input = l.input})
			end)
		end
		local r = row(w)
		for _, o in ipairs(t.outputs or {}) do
			button(r, "Link " .. o, function()
				begin_link(e.id, ci - 1, o)
				refresh()
			end)
		end
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

local function inspector_window()
	drop("inspector")
	local e, is_made = nil, false
	if S.primary then
		e, is_made = find(S.primary)
	end
	if not E.editing or not e or folded("inspector") then
		return
	end
	local y = W.bar and W.bar.height + 12 or 40
	W.inspector = window(magic.HA_RIGHT, magic.VA_TOP, -8, y)
	inspector(W.inspector, e, is_made)
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

-- Below at the left, out of the view's way: the server's state, a refusal,
-- game-wide entities, who edits and who may. Rebuilt alone as the
-- builders move (the inspector being typed in is left as it is)
people = function()
	drop("people")
	-- A narrow screen's palette opened is where it was
	if not E.editing or (narrow() and not folded("palette")) then
		return
	end
	local b = window(magic.HA_LEFT, magic.VA_BOTTOM, 10, -50)
	W.people = b
	text(b, E.running and "Running: edits change the start and the round" or
			"Stopped: edits change the start", DIM)
	if E.status ~= "" then
		text(b, E.status, WARN)
	end
	-- Game-wide entities (on the app root, no position), to select
	for _, e in ipairs(entities()) do
		if not e.pos and e.kind ~= "scene" then
			local gr = row(b)
			label(gr, "Game-wide: " .. e.id .. " " .. tostring(e.name))
			button(gr, e.id == S.primary and "Selected" or "Select", function()
				M.select(e.id)
			end)
		end
	end
	-- The builds the last Stop discarded, to keep until the next Play: all,
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
		label(dr, "Builds discarded at Stop: " .. table.concat(list, ", "))
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
	-- The builders with the tools on, each in their colour
	for _, bd in ipairs(E.builders) do
		text(b, "Builder: " .. tostring(bd.name) .. (bd.you and " (you)" or
				"") .. ((tonumber(bd.sel) or 0) > 0 and ", on " .. bd.sel or ""),
				color(bd.color, DIM))
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
local function select(id, add)
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

local function prefab_dialog(ids)
	drop("dialog")
	local w = window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	W.dialog = w
	w.priority = 10
	text(w, "Make a prefab of " .. #ids .. (#ids == 1 and " entity" or
			" entities"))
	local r = row(w)
	label(r, "Prefab name:")
	edit(r, E.prefab_name, function(s)
		E.prefab_name = s
	end)
	local br = row(w)
	button(br, "Save prefab", function()
		send({op = "save_prefab", ids = ids, name = E.prefab_name})
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
	magic.set_preferred_viewports({magic.Viewport:new(O.scene, cam)})
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
-- keys move it, a press at a time), 3D flies, the arrows turn it with
-- nothing selected; walking is the app's
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
	local speed = (shift and 12 or 4) * dt
	local yaw = math.rad(S.yaw)
	S.pos = {x = S.pos.x + (math.sin(yaw) * f + math.cos(yaw) * r) * speed,
		y = S.pos.y + u * speed,
		z = S.pos.z + (math.cos(yaw) * f - math.sin(yaw) * r) * speed}
end

-- What a right or middle drag in 3D turns about or pans by: the point the
-- pointer is on, or where its ray meets the ground
local function camera_pivot(mx, my)
	local o, v = M.screen_ray(mx, my)
	local p = pick(mx, my)
	if p and p.t then
		return o + v * p.t
	end
	return plane_at(o, v, O.ground_y - 0.5)
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
	if item.prefab then
		send({op = "place", prefab = item.prefab, pos = cell})
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

-- Kit's items in an app's pause menu (extensions/pause_menu), a builder's:
-- Edit ("Play mode" while the tools are on) and Play or Stop; and the
-- tools' Escape first
function M.add_menu_items(menu)
	E.menu = menu
	menu.add(function()
		return E.can_edit and (E.editing and "Play mode" or "Edit") or nil
	end, M.toggle_tools, {order = 10})
	menu.add(function()
		return E.can_edit and (E.running and "Stop" or "Play") or nil
	end, function()
		if E.running then M.stop() else M.play() end
	end, {order = 11})
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
			local p = camera_pivot(mx, my)
			S.pan3d = {dist = p and (p - cam3d_node.position):Length() or 5}
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
		if rc and rc.moved < RIGHT_CLICK_PX then
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
		local _, h = screen_size()
		local k = S.pan3d.dist * 2 * math.tan(math.rad(cam3d.fov) / 2) / h
		local q = rot3d()
		local r, u = q * magic.Vector3(1, 0, 0), q * magic.Vector3(0, 1, 0)
		S.pos = {x = S.pos.x - (r.x * dx - u.x * dy) * k,
			y = S.pos.y - (r.y * dx - u.y * dy) * k,
			z = S.pos.z - (r.z * dx - u.z * dy) * k}
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

local function mouse_wheel(wheel)
	if not E.editing or over_ui(S.mx, S.my) then
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
		local p = pick(S.mx, S.my)
		local dist = p and p.t or 10
		local step = math.min(dist * (1 - f), math.max(0, dist - 0.3))
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
		-- Whatever the first began is dropped
		S.press, S.drag, S.panning, S.pan3d = nil, nil, false, nil
		clear_preview()
		local p = S.view == "3d" and camera_pivot(x, y) or nil
		S.gesture = {pivot = p, dist = p and (p - cam3d_node.position):Length()
			or 5}
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
				local p = camera_pivot(x, y)
				S.pan3d = {dist = p and (p - cam3d_node.position):Length() or 5}
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
			not only.held and buildat.get_time_us() - only.t0 > LONG_PRESS_US then
		only.held = true
		S.press, S.drag = nil, nil
		right_click({mx = only.x, my = only.y})
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
		local list, at = {}, 0
		for _, x in ipairs(entities()) do
			if x.pos then
				list[#list + 1] = x.id
				if x.id == S.primary then
					at = #list
				end
			end
		end
		if #list > 0 then
			select(list[at % #list + 1])
		end
	elseif key == magic.KEY_Z and ctrl then
		send({op = "undo"})
	elseif key == magic.KEY_D and ctrl then
		local ids = sel_ids()
		if #ids > 0 then
			send({op = "duplicate", ids = ids, by = {1, 0, 0}})
		end
	elseif key == magic.KEY_DELETE then
		M.delete_selected()
	elseif ctrl then
		return
	elseif key == magic.KEY_G then
		M.next_grid()
	elseif key == magic.KEY_H then
		M.next_angle()
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
	if t.text ~= item.label then
		t.text = item.label
	end
	hover.box(v3(cell), magic.Vector3(0.45, 0.45, 0.45), nil, M.PLACE)
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
	if over_ui(mx, my) then
		return nil
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
			{{"left", "Left"}, {"right", "Right"}, {"middle", "Middle"}}
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
local function draw()
	if not E.editing then
		show_ports("out", nil)
		show_ports("in", nil)
		return
	end
	local dbg = O.debug
	local now = buildat.get_time_us()
	local YELLOW = magic.Color(1, 0.9, 0.2)
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
				for _, k in ipairs({"zone", "volume", "grants"}) do
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
								magic.Color(0.3, 0.75, 1) or magic.Color(1, 0.6, 0.2),
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
		E.state = E.editing and s or nil
		if was ~= E.editing then
			log:info("kit editor: edit mode " .. (E.editing and "on" or "off"))
			E.link, E.status = nil, ""
			S.drag, S.press, S.placing, S.crosshair = nil, nil, nil, false
			drop("ctx")
			drop("dialog")
			if not E.editing then
				E.builders = {}
			end
			apply_viewport()
		end
		E.discarded = type(s.discarded) == "table" and s.discarded or {}
		E.always_keep = s.always_keep == true
		if not next(E.discarded) then
			E.choose = false
		end
		if E.running ~= (s.running == true) or E.by ~= tostring(s.by or "") then
			E.running, E.by = s.running == true, tostring(s.by or "")
			log:info("kit editor: the server is " .. (E.running and "Running" or
					"Stopped") .. " (by " .. E.by .. ")")
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
		mouse_wheel(data:GetInt("Wheel"))
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
		if E.editing then
			move_camera(dt)
			place_cameras()
			long_press_tick()
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
