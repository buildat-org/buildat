-- Buildat: builtin/kit/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 3, Kit's editor on the client (builtin/kit/api.h says what
-- the server takes). An app hosting Kit turns it on with
--   local kit = require("buildat/module/kit")
--   kit.editor{scene = scene, camera = camera_node, ground_y = 1,
--       solid = function(x, y, z) return <a voxel there> end}
-- An entity's cell is the voxel at its position (centred on it, as
-- voxelworld's are). solid (optional) is the app's voxels, which a click
-- points at; ground_y the cells' y where no voxel is met.
-- An "Edit" button (and F6) asks the server for edit mode; with edit
-- rights (the server's admin, a builder) the server answers with the
-- palette and the authored tree:
--   - a click on the view selects the entity there (or the one owning the
--     voxel there), or puts the cursor in front of the voxel's face, or on
--     the ground, where "Place <type>" puts a new one; Tab selects the
--     next entity
--   - the arrows move the selected one on the ground, Page Up and Down up
--     and down; Delete deletes it; Ctrl+Z undoes this editor's last edit
--   - the inspector: the selected entity's instances, their parameters in
--     ui_utils' settings_form, "Apply" sends them; "Link <output>" and then
--     another entity's "To <input>" links them
--   - every entity drawn as a box, the selected one yellow, links as lines,
--     and a type's gizmo (a sphere or a box), in edit mode only
--   - the admin's: who is here, each "Builder: yes/no" to grant or take
--     edit rights
--   - ([KIT] stage 4c) the builders with the tools on, each in a colour:
--     another's selection outlined in theirs with their name over it,
--     their cursor a cross; game-wide entities (on the app root) listed to
--     select; "Save as start" and an instance's "Restart this" while the
--     server is Running
--   - (the origins) the builds the last Stop discarded, until the next
--     Play: "Keep them", or "Choose..." a player's; "Always keep builds"
-- Kit's top bar, for a builder: the tools ("Edit", "Play mode" while they
-- are on; F6) and the server's state ("Play" while Stopped, "Stop" while
-- Running). kit.editor{bar = false} leaves it out for an app's own menu:
-- kit.can_edit(), kit.editing(), kit.running() (and kit.by(), who), and
-- kit.set_tools(on), kit.toggle_tools(), kit.play(), kit.stop(),
-- kit.save_as_start() do what the bar does; kit.on_change(fn) calls fn()
-- as any of the states changes. kit.add_menu_items(menu) puts Edit and
-- Play/Stop in extensions/pause_menu's menu, kit.cancel_link() is the
-- tools' Escape.
-- kit.selected(): the id last selected, kept after edit mode.
-- simplified: a nudge by keys and no drag, the windows rebuilt whole on
-- each state; a drag and a gizmo per handle are the upgrades
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = buildat.Logger("kit")

local M = {}
local E = {editing = false, running = false, by = "", can_edit = false,
	state = nil, sel = nil, link = nil, cursor = nil, pending = {}, status = "",
	windows = {}, builders = {}, seen = {}, labels = {}, label_text = {},
	listeners = {}, discarded = {}, always_keep = false, choose = false}
local O = nil -- the app's options

local WARN = magic.Color(1.0, 0.55, 0.45)
local DIM = magic.Color(0.7, 0.7, 0.7)
local STYLE = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")

function M.selected()
	return E.sel
end

-- Whether this player is in edit mode now: an app with a mouse look lets
-- the pointer go for the editor's clicks
function M.editing()
	return E.editing
end

-- Whether this player has edit rights, and the server's state
function M.can_edit()
	return E.can_edit
end

function M.running()
	return E.running
end

function M.by()
	return E.by
end

function M.on_change(fn)
	E.listeners[#E.listeners + 1] = fn
end

local function changed()
	for _, fn in ipairs(E.listeners) do
		fn()
	end
end

local function send(t)
	local text = network.write_json(t)
	log:info("kit editor: sent " .. tostring(text))
	buildat.send_packet("kit:edit", text)
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
	send({op = "focus", sel = E.sel or 0, cursor = E.cursor})
end

local function entities()
	local r = {}
	for _, e in ipairs(E.state and E.state.authored and
			E.state.authored.entities or {}) do
		r[#r + 1] = e
	end
	return r
end

local function find(id)
	for _, e in ipairs(entities()) do
		if e.id == id then
			return e
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

-- How far a click looks for a voxel, in cells
local MAX_RAY = 128

local function color(hex, fallback)
	local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then
		return fallback
	end
	return magic.Color(tonumber(r, 16) / 255, tonumber(g, 16) / 255,
			tonumber(b, 16) / 255)
end

-- ---- The windows

local function window(halign, x, bottom)
	local w = magic.ui.root:CreateChild("Window")
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = STYLE
	end
	w:SetStyleAuto()
	w:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(6, 6, 6, 6))
	-- bottom: over an app's own lines at the bottom (Workbench's help)
	w:SetAlignment(halign, bottom and magic.VA_BOTTOM or magic.VA_TOP)
	w:SetPosition(x, bottom and -50 or 40)
	w.opacity = 0.92
	E.windows[#E.windows + 1] = w
	return w
end

local function row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	return r
end

local function text(parent, s, c)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(s)
	if c then
		t:SetColor(c)
	end
	return t
end

local function label(parent, s, width)
	local t = text(parent, s)
	t.minWidth = math.max(width or 0, t.width)
	return t
end

local function button(parent, s, fn)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b.minHeight = 24
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(s)
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = t.width + 16
	magic.SubscribeToEvent(b, "Released", function()
		fn()
	end)
	return b
end

local function edit(parent, value, on_text)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minWidth = 120
	e.minHeight = 24
	e:SetText(value)
	magic.SubscribeToEvent(e, "TextChanged", function()
		on_text(e:GetText())
	end)
	return e
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
	if t == "number" or t == "bool" then
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

local rebuild, people

local function inspector(w, e)
	text(w, "Entity " .. e.id .. ": " .. tostring(e.name))
	if e.pos then
		text(w, string.format("at %d, %d, %d", e.pos[1], e.pos[2], e.pos[3]),
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
				rebuild()
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
				E.link = {id = e.id, comp = ci - 1, output = o}
				E.status = "Linking " .. e.id .. "'s " .. o ..
						": select the entity to link to"
				log:info("kit editor: linking from " .. e.id .. " " .. o)
				rebuild()
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
end

rebuild = function()
	for _, w in ipairs(E.windows) do
		w:Remove()
	end
	E.windows = {}
	if not E.editing then
		people()
		return
	end
	local w = window(magic.HA_LEFT, 10)
	text(w, "Edit mode", magic.Color(1.0, 0.85, 0.3))
	text(w, "Click: select, or the cursor. Tab: next.", DIM)
	text(w, "Arrows, PgUp/PgDn: move. Del. Ctrl+Z.", DIM)
	-- The palette, <author>/<name>, three a row
	text(w, "Place:", DIM)
	local pr
	for i, t in ipairs(E.state.palette or {}) do
		if i % 3 == 1 then
			pr = row(w)
		end
		button(pr, t, function()
			local c = E.cursor or {0, O.ground_y, 0}
			send({op = "place", type = t, pos = c})
		end)
	end
	local r = row(w)
	button(r, "Delete", function()
		if E.sel then
			send({op = "delete", id = E.sel})
		end
	end)
	button(r, "Undo", function()
		send({op = "undo"})
	end)
	label(r, "(" .. tostring(E.state.undo or 0) .. ")")
	if E.running then
		button(r, "Save as start", M.save_as_start)
	end
	if E.link then
		button(w, "Cancel link", function()
			E.link = nil
			E.status = ""
			rebuild()
		end)
	end
	if E.status ~= "" then
		text(w, E.status, WARN)
	end
	people()
	local e = E.sel and find(E.sel)
	if e then
		inspector(window(magic.HA_RIGHT, -10), e)
	end
end

-- A pending link cancelled: true if there was one (the tools' Escape
-- takes it before the app's pause menu)
function M.cancel_link()
	if not E.link then
		return false
	end
	E.link, E.status = nil, ""
	log:info("kit editor: link cancelled")
	rebuild()
	return true
end

-- Kit's items in an app's pause menu (extensions/pause_menu), a builder's:
-- Edit ("Play mode" while the tools are on) and Play or Stop; and the
-- tools' Escape cancelling a pending link first
function M.add_menu_items(menu)
	menu.add(function()
		return E.can_edit and (E.editing and "Play mode" or "Edit") or nil
	end, M.toggle_tools, {order = 10})
	menu.add(function()
		return E.can_edit and (E.running and "Stop" or "Play") or nil
	end, function()
		if E.running then M.stop() else M.play() end
	end, {order = 11})
	menu.on_escape(M.cancel_link)
	M.on_change(menu.refresh)
end

-- Below, out of the view's way: the server's state, game-wide entities,
-- who edits and who may. Rebuilt alone as the builders move (the
-- inspector being typed in is left as it is)
people = function()
	if E.people then
		E.people:Remove()
		E.people = nil
	end
	if not E.editing then
		return
	end
	local b = window(magic.HA_LEFT, 10, true)
	table.remove(E.windows)
	E.people = b
	text(b, E.running and "Running: edits change the start and the round" or
			"Stopped: edits change the start", DIM)
	-- Game-wide entities (on the app root, no position), to select
	for _, e in ipairs(entities()) do
		if not e.pos and e.kind ~= "scene" then
			local gr = row(b)
			label(gr, "Game-wide: " .. e.id .. " " .. tostring(e.name))
			button(gr, e.id == E.sel and "Selected" or "Select", function()
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
	for _, p in ipairs(E.state.admin and E.state.people or {}) do
		local pr = row(b)
		label(pr, p.name .. (p.admin and ": admin" or ""), 100)
		if not p.admin then
			button(pr, p.builder and "Builder: yes" or "Builder: no", function()
				send({op = "builder", name = p.name, on = not p.builder})
			end)
		end
	end
end

-- ---- The view

local function inside(w, x, y)
	local p, s = w.screenPosition, w.size
	return x >= p.x and y >= p.y and x < p.x + s.x and y < p.y + s.y
end

local function over_windows(x, y)
	for _, w in ipairs(E.windows) do
		if inside(w, x, y) then
			return true
		end
	end
	return E.people ~= nil and inside(E.people, x, y)
end

local function select(id)
	E.sel = id
	local e = id and find(id)
	log:info("kit editor: selected " .. tostring(id) .. " (" ..
			tostring(e and e.name) .. ")")
	focus()
	rebuild()
end
M.select = select

-- The camera's ray through a point of the screen (fractions): its origin
-- and direction, {x, y, z} each
local function ray_at(fx, fy)
	local cam = O.camera:GetComponent("Camera")
	local d = O.camera.worldDirection
	local rx, ry, rz = d.z, 0, -d.x
	local rl = math.sqrt(rx * rx + rz * rz)
	if rl < 1e-6 then
		rx, rz, rl = 1, 0, 1
	end
	rx, rz = rx / rl, rz / rl
	local ux, uy, uz = d.y * rz - d.z * ry, d.z * rx - d.x * rz,
			d.x * ry - d.y * rx
	local h = math.tan(math.rad(cam.fov / 2))
	local a, b = (2 * fx - 1) * h * cam.aspectRatio, (1 - 2 * fy) * h
	local vx, vy, vz = d.x + rx * a + ux * b, d.y + ry * a + uy * b,
			d.z + rz * a + uz * b
	local o = O.camera.worldPosition
	return {o.x, o.y, o.z}, {vx, vy, vz}
end

-- Cells are voxels, centred on whole numbers as voxelworld's are
local function round(x)
	return math.floor(x + 0.5)
end

-- The ground cell (y = ground_y, standing on the plane half a cell below)
-- the ray meets
local function ground_at(o, v)
	local t = math.abs(v[2]) > 1e-6 and (O.ground_y - 0.5 - o[2]) / v[2] or -1
	if t <= 0 then
		return nil
	end
	return {round(o[1] + v[1] * t), O.ground_y, round(o[3] + v[3] * t)}
end

-- The first cell along the ray that solid() says is a voxel, and the cell
-- before it (the face's side; nil when the ray starts in it), at most
-- `max` cells on: a walk from cell to cell (Amanatides and Woo)
local function voxel_ray(o, v, solid, max)
	local c, step, tmax, tdelta = {}, {}, {}, {}
	for k = 1, 3 do
		local p = o[k] + 0.5
		c[k] = math.floor(p)
		if v[k] > 1e-9 then
			step[k], tmax[k], tdelta[k] = 1, (c[k] + 1 - p) / v[k], 1 / v[k]
		elseif v[k] < -1e-9 then
			step[k], tmax[k], tdelta[k] = -1, (p - c[k]) / -v[k], -1 / v[k]
		else
			step[k], tmax[k], tdelta[k] = 0, math.huge, math.huge
		end
	end
	local prev = nil
	for _ = 1, max do
		if solid(c[1], c[2], c[3]) then
			return {c[1], c[2], c[3]}, prev
		end
		prev = {c[1], c[2], c[3]}
		local k = 1
		if tmax[2] < tmax[k] then k = 2 end
		if tmax[3] < tmax[k] then k = 3 end
		c[k] = c[k] + step[k]
		tmax[k] = tmax[k] + tdelta[k]
	end
end

-- A click on the view: the entity drawn there (its box's centre near, or
-- its cell the pointed one), else the cursor: in front of the voxel the
-- pointer is on (where the app gave solid()), else on the ground
local function click_view(mx, my)
	local cam = O.camera:GetComponent("Camera")
	local sc = magic.ui.scale
	local fx = mx / sc / magic.ui.root.width
	local fy = my / sc / magic.ui.root.height
	local o, v = ray_at(fx, fy)
	local hit, front
	if O.solid then
		hit, front = voxel_ray(o, v, O.solid, MAX_RAY)
	end
	local g = front or (not hit and ground_at(o, v)) or nil
	local function at(e, c)
		return c and e.pos[1] == c[1] and e.pos[2] == c[2] and e.pos[3] == c[3]
	end
	local best, bd = nil, 0.03 * 0.03
	for _, e in ipairs(entities()) do
		if e.pos then
			local p = cam:WorldToScreenPoint(center(e))
			local d = (p.x - fx) * (p.x - fx) + (p.y - fy) * (p.y - fy)
			if at(e, g) or at(e, hit) then
				d = 0
			end
			if d < bd then
				best, bd = e.id, d
			end
		end
	end
	if best then
		if best ~= E.sel then
			select(best)
		end
	elseif g then
		E.cursor = g
		log:info("kit editor: cursor at " .. table.concat(g, ","))
		focus()
	end
end

local function draw()
	if not E.editing then
		return
	end
	local dbg = O.debug
	for _, e in ipairs(entities()) do
		if e.pos then
			local x, y, z = e.pos[1], e.pos[2], e.pos[3]
			dbg:AddBoundingBox(magic.BoundingBox(
					magic.Vector3(x - 0.4, y - 0.4, z - 0.4),
					magic.Vector3(x + 0.4, y + 0.4, z + 0.4)),
					e.id == E.sel and magic.Color(1, 0.9, 0.2) or
					magic.Color(0.8, 0.8, 0.8), false)
			for _, c in ipairs(e.components or {}) do
				local g = type_of(c.type).gizmo
				if type(g) == "table" then
					local col = color(g.color, magic.Color(0.3, 0.9, 1))
					local s = tonumber(g.size) or 0.5
					if g.shape == "box" then
						local m = center(e)
						dbg:AddBoundingBox(magic.BoundingBox(
								magic.Vector3(m.x - s, m.y - s, m.z - s),
								magic.Vector3(m.x + s, m.y + s, m.z + s)), col,
								false)
					else
						dbg:AddSphere(magic.Sphere(center(e), s), col, false)
					end
				end
				-- A zone's and an owned volume's extent, from its cell on
				local t = type_of(c.type)
				for _, k in ipairs({"zone", "volume"}) do
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
						local a, b = center(e), center(to)
						dbg:AddLine(a, b, magic.Color(0.2, 1, 0.4), false)
						dbg:AddCross(magic.Vector3(a.x + (b.x - a.x) * 0.85,
								a.y + (b.y - a.y) * 0.85, a.z + (b.z - a.z) * 0.85),
								0.3, magic.Color(0.2, 1, 0.4), false)
					end
				end
			end
		end
	end
	if E.cursor then
		dbg:AddCross(magic.Vector3(E.cursor[1], E.cursor[2] - 0.5,
				E.cursor[3]), 0.8, magic.Color(1, 0.4, 1), false)
	end
end

local function key_down(key, ctrl)
	local e = E.sel and find(E.sel)
	if key == magic.KEY_TAB then
		local list, at = {}, 0
		for _, x in ipairs(entities()) do
			if x.pos then
				list[#list + 1] = x.id
				if x.id == E.sel then
					at = #list
				end
			end
		end
		if #list > 0 then
			select(list[at % #list + 1])
		end
	elseif key == magic.KEY_Z and ctrl then
		send({op = "undo"})
	elseif key == magic.KEY_DELETE and e then
		send({op = "delete", id = e.id})
	elseif e and e.pos then
		local d = ({[magic.KEY_LEFT] = {-1, 0, 0}, [magic.KEY_RIGHT] = {1, 0, 0},
			[magic.KEY_UP] = {0, 0, 1}, [magic.KEY_DOWN] = {0, 0, -1},
			[magic.KEY_PAGEUP] = {0, 1, 0}, [magic.KEY_PAGEDOWN] = {0, -1, 0}})[key]
		if d then
			send({op = "move", id = e.id, pos = {e.pos[1] + d[1],
				e.pos[2] + d[2], e.pos[3] + d[3]}})
		end
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

function M.editor(options)
	O = options
	O.ground_y = O.ground_y or 0
	-- The scene's own one where it has it (the replicated scene does): the
	-- view draws the first
	O.debug = O.scene:GetComponent("DebugRenderer") or
			O.scene:CreateComponent("DebugRenderer")
	-- Kit's top bar: the tools and the server's state, a builder's; an
	-- app with a menu of its own leaves it out (bar = false)
	local w, tools_button, server_button
	local function bar()
		if not w then
			return
		end
		w.visible = E.can_edit
		local function set(b, s)
			b:GetChild(0):SetText(s)
			b.minWidth = b:GetChild(0).width + 16
		end
		set(tools_button, E.editing and "Play mode" or "Edit")
		set(server_button, E.running and "Stop" or "Play")
	end
	if O.bar ~= false then
		w = magic.ui.root:CreateChild("Window")
		if not magic.ui.root.defaultStyle then
			magic.ui.root.defaultStyle = STYLE
		end
		w:SetStyleAuto()
		w:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(4, 4, 4, 4))
		-- The middle: an app's corners have its own (accounts' Server button)
		w:SetAlignment(magic.HA_CENTER, magic.VA_TOP)
		w:SetPosition(0, 4)
		tools_button = button(w, "Edit", M.toggle_tools)
		server_button = button(w, "Play", function()
			if E.running then M.stop() else M.play() end
		end)
		bar()
	end

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
			if not E.editing then
				E.builders = {}
			end
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
		bar()
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
						table.concat(e.pos, ",") or "") .. " links " ..
						table.concat(links, " "))
			end
		end
		if E.sel and not find(E.sel) and E.editing then
			E.sel = nil
		end
		rebuild()
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
	buildat.sub_packet("kit:edit_refused", function(data)
		E.status = "Refused: " .. tostring(data)
		log:info("kit editor: refused: " .. tostring(data))
		if E.editing then
			rebuild()
		else
			ui_utils.show_notification(E.status, 4)
		end
	end)
	magic.SubscribeToEvent("KeyDown", function(_, data)
		local key = data:GetInt("Key")
		local f = magic.ui.focusElement
		if f ~= nil and f:GetTypeName() == "LineEdit" then
			return
		end
		if key == magic.KEY_F6 then
			return M.toggle_tools()
		end
		if E.editing then
			local q = data:GetInt("Qualifiers")
			key_down(key, q == magic.QUAL_CTRL)
		end
	end)
	magic.SubscribeToEvent("MouseButtonDown", function(_, data)
		if not E.editing or data:GetInt("Button") ~= magic.MOUSEB_LEFT then
			return
		end
		local m = magic.input:GetMousePosition()
		local sc = magic.ui.scale
		if over_windows(m.x / sc, m.y / sc) or (w and inside(w, m.x / sc,
				m.y / sc)) or ui_utils.dropdown_open() then
			return
		end
		click_view(m.x, m.y)
	end)
	magic.SubscribeToEvent("Update", function()
		draw()
		draw_builders(O.debug)
	end)
end

-- ---- Play: what every client sees of Kit, edit rights or not
-- A positional entity's node ("kit:<id>") carries its shared state (the
-- var "kit:<key>", JSON) and what its types show (the var "kit_show",
-- {look, hud}): a type's look (builtin/kit/api.h) is drawn where the
-- entity is, in both modes, from its state: a box (size: its sides,
-- offset: its middle from the entity's position, as the server made them
-- of its extent) or a sphere, its `when` over it while the state `state`
-- is true, a collision shape (a static body in the scene's physics) while
-- solid, its state `text` over it; a type's `hud = key` puts that state on
-- the screen.
-- kit.pointed(origin, dir, reach) -> the id of the entity nearest the ray
-- (its look's box, or near its cell), kit.use(id) uses it: the server
-- checks range and whether it is usable. The player's inventory (c:add,
-- c:take...) is a line on the screen. The Stop notice: "Your builds while
-- playing were discarded." (who built how many when others did too), and
-- for a builder "Keep them" (the tools' panel has it until the next Play).
-- For a drive (doc/client_commands.txt's event): "event kit_edit <json>"
-- sends an edit as the editor would, "event kit_use <id>" a use.
local replicate = require("buildat/extension/replicate")
local P = {nodes = {}, items = ""}

local function parse(v)
	if v:IsEmpty() then
		return nil
	end
	return network.parse_json(v:GetString())
end

local function shown(v)
	if v == nil then
		return ""
	end
	if type(v) == "table" then
		return network.write_json(v)
	end
	return tostring(v)
end

local function drop_look(n)
	if n.look then
		n.look:Remove()
	end
	n.look, n.body, n.mat, n.text, n.solid, n.box, n.on = nil, nil, nil,
			nil, nil, nil, nil
end

replicate.sub_sync_node_added({}, function(node)
	local id = tonumber(node:GetName():match("^kit:(%d+)$"))
	if id then
		P.nodes[id] = {node = node}
	end
end)
replicate.sub_sync_node_removed(function(node, node_id)
	for id, n in pairs(P.nodes) do
		if n.node:GetID() == node_id then
			drop_look(n)
			P.nodes[id] = nil
		end
	end
end)

-- A look's box as it is drawn now (on: its state is true): its sides, its
-- middle from the entity, whether it is solid and its colour
local function look_box(look, on)
	local size, off = {}, {0, 0, 0}
	if type(look.size) == "table" then
		for i = 1, 3 do
			size[i] = tonumber(look.size[i]) or 1
		end
	else
		local s = (tonumber(look.size) or 0.4) * 2
		size = {s, s, s}
	end
	if type(look.offset) == "table" then
		for i = 1, 3 do
			off[i] = tonumber(look.offset[i]) or 0
		end
	end
	local w = on and type(look.when) == "table" and look.when or {}
	local solid = look.solid == true
	if w.solid ~= nil then
		solid = w.solid == true
	end
	if type(w.scale) == "table" then
		for i = 1, 3 do
			local was = size[i]
			size[i] = size[i] * (tonumber(w.scale[i]) or 1)
			-- Its bottom kept
			if i == 2 then
				off[2] = off[2] - (was - size[2]) / 2
			end
		end
	end
	if w.swing then
		-- A quarter turn round its -x edge, towards +z
		local hinge, front = off[1] - size[1] / 2, off[3] - size[3] / 2
		size[1], size[3] = size[3], size[1]
		off[1], off[3] = hinge + size[1] / 2, front + size[3] / 2
	end
	return {size = size, off = off, solid = solid, color = w.color or look.color}
end

local function v3(t)
	return magic.Vector3(t[1], t[2], t[3])
end

-- The look drawn as its state has it: built the first time, changed as the
-- state changes
local function draw_look(id, n, look)
	local on = false
	if look.state then
		on = parse(n.node:GetVar("kit:" .. tostring(look.state))) == true
	end
	if n.look and n.on == on then
		return
	end
	n.on = on
	local b = look_box(look, on)
	n.box = b
	if not n.look then
		local scene = replicate.main_scene
		n.look = scene:CreateChild("kit_look")
		n.body = n.look:CreateChild("Body")
		local m = n.body:CreateComponent("StaticModel")
		m.model = magic.cache:GetResource("Model", "Models/" ..
				(look.shape == "sphere" and "Sphere" or "Box") .. ".mdl")
		n.mat = magic.Material:new()
		n.mat:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/NoTexture.xml"))
		n.mat:SetShaderParameter("MatSpecColor", magic.Color(0.05, 0.05, 0.05))
		m.material = n.mat
		m.castShadows = true
		if look.text then
			local l = n.look:CreateChild("Text")
			local t = l:CreateComponent("Text3D")
			t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 16)
			t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
			t.faceCameraMode = magic.FC_ROTATE_XYZ
			t.fixedScreenSize = true
			t.textEffect = magic.TE_STROKE
			t.effectColor = magic.Color(0, 0, 0, 0.8)
			n.text = t
			n.text_node = l
		end
		n.at = nil
	end
	n.body.scale = v3(b.size)
	n.body.position = v3(b.off)
	n.mat:SetShaderParameter("MatDiffColor", color(b.color,
			magic.Color(0.8, 0.8, 0.8)))
	if n.text_node then
		n.text_node.position = magic.Vector3(b.off[1], b.off[2] + b.size[2] / 2 +
				0.45, b.off[3])
	end
	-- Solid: a static body (no mass) the players' bodies meet
	if n.solid then
		n.solid:Remove()
		n.solid = nil
	end
	if b.solid then
		n.solid = n.look:CreateChild("Solid")
		n.solid.position = v3(b.off)
		n.solid:CreateComponent("RigidBody")
		n.solid:CreateComponent("CollisionShape"):SetBox(v3(b.size))
	end
	log:info(string.format("kit: entity %d drawn %gx%gx%g at %g,%g,%g%s", id,
			b.size[1], b.size[2], b.size[3], b.off[1], b.off[2], b.off[3],
			b.solid and ", solid" or ""))
end

local hud = nil
local function update_play()
	local lines = {}
	for id, n in pairs(P.nodes) do
		-- What it shows: again as an edit changes it
		local raw = n.node:GetVar("kit_show")
		raw = raw:IsEmpty() and "" or raw:GetString()
		if raw ~= n.show_raw then
			n.show_raw = raw
			n.show = network.parse_json(raw)
			drop_look(n)
			n.last_text = nil
		end
		local show = type(n.show) == "table" and n.show or {}
		if type(show.look) == "table" then
			draw_look(id, n, show.look)
		end
		if n.look then
			local p = n.node.position
			if not n.at or (n.at - p):Length() > 1e-4 then
				n.at = magic.Vector3(p.x, p.y, p.z)
				n.look.position = n.at
			end
		end
		if n.text then
			local v = shown(parse(n.node:GetVar("kit:" .. tostring(show.look.text))))
			if v ~= n.last_text then
				n.last_text = v
				n.text.text = v
				log:info("kit: entity " .. id .. " shows \"" .. v .. "\"")
			end
		end
		if type(show.hud) == "string" then
			local v = shown(parse(n.node:GetVar("kit:" .. show.hud)))
			if v ~= "" then
				lines[#lines + 1] = {id, v}
			end
		end
	end
	table.sort(lines, function(a, b) return a[1] < b[1] end)
	local t = {}
	for _, l in ipairs(lines) do
		t[#t + 1] = l[2]
	end
	if P.items ~= "" then
		t[#t + 1] = P.items
	end
	local text = table.concat(t, "\n")
	if text ~= P.hud_text then
		P.hud_text = text
		if not hud then
			hud = magic.ui.root:CreateChild("Text")
			hud:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
			hud:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
			hud:SetPosition(-12, 50)
		end
		hud:SetText(text)
		log:info("kit: the screen says \"" .. text:gsub("\n", " | ") .. "\"")
	end
	-- The Stop notice goes by itself
	if P.notice and buildat.get_time_us() > P.notice_until then
		P.notice:Remove()
		P.notice = nil
	end
end
magic.SubscribeToEvent("Update", update_play)

buildat.sub_packet("kit:items", function(data)
	local items = network.parse_json(data)
	local t = {}
	for k, v in pairs(type(items) == "table" and items or {}) do
		t[#t + 1] = tostring(k) .. " x" .. tostring(v)
	end
	table.sort(t)
	P.items = #t > 0 and "Items: " .. table.concat(t, ", ") or ""
	log:info("kit: items: " .. (#t > 0 and table.concat(t, ", ") or "none"))
end)

-- The Stop notice: the round's builds were discarded, who built them when
-- others did; a builder may keep them (here, or the tools' panel until the
-- next Play). Not a dialog: it takes no focus and goes by itself
local NOTICE_S = 15
buildat.sub_packet("kit:discarded", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or type(d.counts) ~= "table" then
		return
	end
	local list, others = {}, false
	for name, k in pairs(d.counts) do
		list[#list + 1] = (name == d.you and "you" or tostring(name)) .. " " ..
				tostring(k)
		others = others or name ~= d.you
	end
	table.sort(list)
	local s = others and "Builds while playing were discarded (" ..
			table.concat(list, ", ") .. ")." or
			"Your builds while playing were discarded."
	log:info("kit: builds discarded: " .. s)
	if P.notice then
		P.notice:Remove()
	end
	local w = magic.ui.root:CreateChild("Window")
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = STYLE
	end
	w:SetStyleAuto()
	w:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(8, 6, 8, 6))
	w:SetFocusMode(magic.FM_NOTFOCUSABLE)
	text(w, s)
	if d.can_keep == true then
		button(w, "Keep them", function()
			send({op = "keep"})
			if P.notice then
				P.notice:Remove()
				P.notice = nil
			end
		end)
	end
	w:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
	w:SetPosition(-10, 90)
	P.notice, P.notice_until = w, buildat.get_time_us() + NOTICE_S * 1000000
end)

-- The ray meets a look's box at t (nil: it does not)
local function ray_box(origin, dir, c, half)
	local t0, t1 = 0, math.huge
	local o = {origin.x, origin.y, origin.z}
	local d = {dir.x, dir.y, dir.z}
	for i = 1, 3 do
		local lo, hi = c[i] - half[i], c[i] + half[i]
		if math.abs(d[i]) < 1e-9 then
			if o[i] < lo or o[i] > hi then
				return nil
			end
		else
			local a, b = (lo - o[i]) / d[i], (hi - o[i]) / d[i]
			if a > b then
				a, b = b, a
			end
			t0, t1 = math.max(t0, a), math.min(t1, b)
			if t0 > t1 then
				return nil
			end
		end
	end
	return t0
end

function M.pointed(origin, dir, reach)
	local best, bd = nil, nil
	for id, n in pairs(P.nodes) do
		local p = n.node.position
		local t
		if n.box then
			-- Its look as drawn, a little larger (a thin button: as thick
			-- as most of a cell)
			local c, half = {}, {}
			for i, k in ipairs({"x", "y", "z"}) do
				c[i] = p[k] + n.box.off[i]
				half[i] = math.max(n.box.size[i] / 2, 0.3) + 0.05
			end
			t = ray_box(origin, dir, c, half)
		else
			local wx, wy, wz = p.x - origin.x, p.y - origin.y, p.z - origin.z
			local tt = wx * dir.x + wy * dir.y + wz * dir.z
			local dx, dy, dz = wx - dir.x * tt, wy - dir.y * tt, wz - dir.z * tt
			-- A cell's corner is 0.87 from its middle; a face's middle 0.5
			if tt > 0 and math.sqrt(dx * dx + dy * dy + dz * dz) <= 0.75 then
				t = tt
			end
		end
		if t and t <= reach + 0.5 and (not bd or t < bd) then
			best, bd = id, t
		end
	end
	return best
end

function M.use(id)
	log:info("kit: use " .. tostring(id))
	buildat.send_packet("kit:use", tostring(id))
end

magic.SubscribeToEvent("command_seq:kit_edit", function(_, data)
	local text = data:GetString("Param")
	log:info("kit editor: sent " .. text)
	buildat.send_packet("kit:edit", text)
end)
magic.SubscribeToEvent("command_seq:kit_use", function(_, data)
	M.use(data:GetString("Param"))
end)

return M
-- vim: set noet ts=4 sw=4:
