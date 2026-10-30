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
	listeners = {}, discarded = {}, always_keep = false, choose = false,
	group = {}, prefab_name = "", logs = {}, flows = {}}
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
	-- Under the menus (the pause menu over a wide inspector)
	w.priority = -1
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

local rebuild, people, show_log

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

local function inspector(w, e, is_made)
	if is_made then
		return inspect_made(w, e)
	end
	text(w, "Entity " .. e.id .. ": " .. tostring(e.name))
	if e.pos then
		text(w, string.format("at %g, %g, %g", e.pos[1], e.pos[2], e.pos[3]),
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
						typed(t, "outputs", o) .. ": select the entity to link to"
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
	-- [KIT] stage 4d: a prefab's copy, and the group a prefab is made of
	if type(e.prefab) == "table" then
		text(w, "Prefab " .. tostring(e.prefab.of) .. " " ..
				tostring(e.prefab.version), DIM)
	end
	button(w, E.group[e.id] and "In the group" or "Add to group", function()
		E.group[e.id] = not E.group[e.id] or nil
		rebuild()
	end)
end

rebuild = function()
	for _, w in ipairs(E.windows) do
		w:Remove()
	end
	E.windows = {}
	if not E.editing then
		people()
		show_log()
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
	-- And the prefabs ([KIT] stage 4d), after the types
	local n = #(E.state.palette or {})
	for i, p in ipairs(E.state.prefabs or {}) do
		if (n + i) % 3 == 1 then
			pr = row(w)
		end
		button(pr, "[" .. p .. "]", function()
			local c = E.cursor or {0, O.ground_y, 0}
			send({op = "place", prefab = p, pos = c})
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
	-- The group a prefab is saved of: "Add to group" in the inspector
	local ids = {}
	for id in pairs(E.group) do
		if find(id) then
			ids[#ids + 1] = id
		else
			E.group[id] = nil
		end
	end
	table.sort(ids)
	if #ids > 0 then
		local gr = row(w)
		label(gr, "Group: " .. table.concat(ids, " "))
		button(gr, "Clear", function()
			E.group = {}
			rebuild()
		end)
		local sr = row(w)
		label(sr, "Prefab name:")
		edit(sr, E.prefab_name, function(s)
			E.prefab_name = s
		end)
		button(sr, "Save prefab", function()
			send({op = "save_prefab", ids = ids, name = E.prefab_name})
		end)
	end
	people()
	local e, is_made = nil, false
	if E.sel then
		e, is_made = find(E.sel)
	end
	if e then
		inspector(window(magic.HA_RIGHT, -10), e, is_made)
	end
	show_log()
end

-- The selected entity's log ([KIT] stage 4d): its c:log lines and Kit's
-- about it, its last ones, below on the right. Rebuilt alone as it grows
show_log = function()
	if E.logwin then
		E.logwin:Remove()
		E.logwin = nil
	end
	local lines = E.editing and E.sel and E.logs[E.sel] or {}
	if #lines == 0 then
		return
	end
	local lw = window(magic.HA_RIGHT, -10, true)
	table.remove(E.windows)
	E.logwin = lw
	text(lw, "Log of " .. E.sel .. ":", DIM)
	for i = math.max(1, #lines - 7), #lines do
		text(lw, tostring(lines[i]))
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
	return (E.people ~= nil and inside(E.people, x, y)) or
			(E.logwin ~= nil and inside(E.logwin, x, y))
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
	local all = entities()
	for _, e in ipairs(made()) do
		if e.kind ~= "player" then
			all[#all + 1] = e
		end
	end
	for _, e in ipairs(all) do
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
	local now = buildat.get_time_us()
	-- The round's own entities, orange (players are drawn by the app)
	for _, e in ipairs(made()) do
		if e.pos and e.kind ~= "player" then
			local x, y, z = e.pos[1], e.pos[2], e.pos[3]
			dbg:AddBoundingBox(magic.BoundingBox(
					magic.Vector3(x - 0.35, y - 0.35, z - 0.35),
					magic.Vector3(x + 0.35, y + 0.35, z + 0.35)),
					e.id == E.sel and magic.Color(1, 0.9, 0.2) or
					magic.Color(1, 0.55, 0.1), false)
		end
	end
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
end

local function key_down(key, ctrl, shift)
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
		-- Shift: a quarter of a cell, off the voxels' grid ([KIT] 4d)
		local k = shift and 0.25 or 1
		if d then
			send({op = "move", id = e.id, pos = {e.pos[1] + d[1] * k,
				e.pos[2] + d[2] * k, e.pos[3] + d[3] * k}})
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
			key_down(key, q == magic.QUAL_CTRL, q == magic.QUAL_SHIFT)
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
-- {look, hud, client, shared, player}): a type's look (builtin/kit/api.h)
-- is drawn where the entity is, in both modes, from its state: a box
-- (size: its sides, offset: its middle from the entity's position, as the
-- server made them of its extent), a sphere or ([KIT] stage 4d) a wedge,
-- turned by its rotation, its material's, its `when` over it while the
-- state `state` is true (a swing a quarter turn round a hinge at its -x
-- edge), a collision shape (a static body in the scene's physics) while
-- solid, its state `text` over it; a type's `hud = key` puts that state on
-- the screen.
-- **A type's client part** ([KIT] stage 4d): <name>.client.lua beside the
-- type, sent at join, run as the client's own Lua is (this module's
-- sandbox); it returns a table of handlers, each given `e`, the entity as
-- this client has it:
--   on_add(e), on_state(e, key) (a shared state changed: e.state[key]),
--   on_update(e, dt) (each frame), on_use(e) (this player used it, before
--   the server hears of it), on_remove(e)
--   e.id, e.node (its replicated node), e.look, e.hinge, e.body (its look's
--   nodes: the body turns with the hinge), e.state (the server's), e.mine
--   (this player's own entity), e:shown(key) (the state as drawn),
--   e:near(d) (this player's entity within d of it),
--   e:predict(key, value, seconds) (drawn so at once, until the server's
--   value changes or the seconds, 1, pass), e:log(text)
-- kit.pointed(origin, dir, reach) -> the id of the entity nearest the ray
-- (its look's box, or near its cell), kit.use(id) uses it: the server
-- checks range and whether it is usable. The player's inventory (c:add,
-- c:take...) is a line on the screen. The Stop notice: "Your builds while
-- playing were discarded." (who built how many when others did too), and
-- for a builder "Keep them" (the tools' panel has it until the next Play).
-- For a drive (doc/client_commands.txt's event): "event kit_edit <json>"
-- sends an edit as the editor would, "event kit_use <id>" a use.
local replicate = require("buildat/extension/replicate")
local P = {nodes = {}, items = "", parts = {}, you = 0}

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

-- A state as it is drawn: the server's, or this client's prediction until
-- the server's value changes from what it was then, or its time is up
local function value(n, key)
	key = tostring(key)
	local server = parse(n.node:GetVar("kit:" .. key))
	local p = n.predicted and n.predicted[key]
	if p then
		if buildat.get_time_us() < p.till and shown(server) == p.was then
			return p.value
		end
		n.predicted[key] = nil
	end
	return server
end

local function drop_look(n)
	if n.look then
		n.look:Remove()
	end
	n.look, n.hinge, n.body, n.mat, n.text, n.solid, n.box, n.on = nil, nil,
			nil, nil, nil, nil, nil, nil
end

-- A client part's handler, protected: one that fails is left off for
-- that entity, logged
local function call(n, part, fn, ...)
	local f = part[fn]
	if type(f) ~= "function" or (n.failed and n.failed[part]) then
		return
	end
	local ok, err = pcall(f, n.e, ...)
	if not ok then
		n.failed = n.failed or {}
		n.failed[part] = true
		log:warning("kit: entity " .. tostring(n.e.id) .. "'s client part " ..
				fn .. ": " .. tostring(err))
	end
end

local function parts_of(n)
	local r = {}
	local show = type(n.show) == "table" and n.show or {}
	for _, t in ipairs(type(show.client) == "table" and show.client or {}) do
		if P.parts[t] then
			r[#r + 1] = P.parts[t]
		end
	end
	return r
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
			if n.added then
				for _, part in ipairs(parts_of(n)) do
					call(n, part, "on_remove")
				end
			end
			drop_look(n)
			P.nodes[id] = nil
		end
	end
end)

-- A look's box as it is drawn now (on: its state is true): its sides, its
-- middle from the entity, whether it is solid and its colour. A swing's
-- the box it is turned to (a quarter round its -x edge, towards +z)
local function look_box(look, on)
	local size, off = {}, {0, 0, 0}
	if type(look.size) == "table" then
		for i = 1, 3 do
			size[i] = math.max(0.02, math.min(64, tonumber(look.size[i]) or 1))
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
		local hinge, front = off[1] - size[1] / 2, off[3] - size[3] / 2
		size[1], size[3] = size[3], size[1]
		off[1], off[3] = hinge + size[1] / 2, front + size[3] / 2
	end
	return {size = size, off = off, solid = solid, color = w.color or look.color}
end

local function v3(t)
	return magic.Vector3(t[1], t[2], t[3])
end

-- A unit wedge (-0.5...0.5), its slope rising along +z to the full height
-- at its back
local function wedge(node)
	local cg = node:CreateComponent("CustomGeometry")
	cg:SetNumGeometries(1)
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	local a, b = -0.5, 0.5
	local function tri(p1, p2, p3, nrm)
		for _, p in ipairs({p1, p2, p3}) do
			cg:DefineVertex(magic.Vector3(p[1], p[2], p[3]))
			cg:DefineNormal(nrm)
			cg:DefineTexCoord(magic.Vector2(0, 0))
		end
	end
	local slope = magic.Vector3(0, 1, -1):Normalized()
	-- The slope, the bottom, the back, the two sides
	tri({a, a, a}, {a, b, b}, {b, b, b}, slope)
	tri({a, a, a}, {b, b, b}, {b, a, a}, slope)
	tri({a, a, a}, {b, a, a}, {b, a, b}, magic.Vector3(0, -1, 0))
	tri({a, a, a}, {b, a, b}, {a, a, b}, magic.Vector3(0, -1, 0))
	tri({a, a, b}, {b, a, b}, {b, b, b}, magic.Vector3(0, 0, 1))
	tri({a, a, b}, {b, b, b}, {a, b, b}, magic.Vector3(0, 0, 1))
	tri({a, a, a}, {a, a, b}, {a, b, b}, magic.Vector3(-1, 0, 0))
	tri({b, a, a}, {b, b, b}, {b, a, b}, magic.Vector3(1, 0, 0))
	cg:Commit()
	return cg
end

-- A look's material ([KIT] stage 4d): plain, metal, glass or glow
local TECHNIQUES = {glass = "Techniques/NoTextureAlpha.xml",
	glow = "Techniques/NoTextureUnlit.xml"}
local function material(name)
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			TECHNIQUES[name] or "Techniques/NoTexture.xml"))
	m:SetShaderParameter("MatSpecColor", name == "metal" and
			magic.Color(0.6, 0.6, 0.6, 30) or magic.Color(0.05, 0.05, 0.05))
	return m
end

-- The look drawn as its state has it: built the first time, changed as the
-- state changes
local function draw_look(id, n, look)
	local on = false
	if look.state then
		on = value(n, look.state) == true
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
		n.hinge = n.look:CreateChild("Hinge")
		n.body = n.hinge:CreateChild("Body")
		n.mat = material(look.material)
		if look.shape == "wedge" then
			wedge(n.body):SetMaterial(0, n.mat)
		else
			local m = n.body:CreateComponent("StaticModel")
			m.model = magic.cache:GetResource("Model", "Models/" ..
					(look.shape == "sphere" and "Sphere" or "Box") .. ".mdl")
			m.material = n.mat
			m.castShadows = true
		end
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
		local r = type(look.rotation) == "table" and look.rotation or {}
		n.look.rotation = magic.Quaternion(tonumber(r[1]) or 0,
				tonumber(r[2]) or 0, tonumber(r[3]) or 0)
		n.at = nil
	end
	-- A swing turns the body round its hinge: the middle of its thickness
	-- at its -x end, so the turned box is look_box's
	if type(look.when) == "table" and look.when.swing then
		local c = look_box(look, false)
		local px = c.off[1] - c.size[1] / 2 + c.size[3] / 2
		n.hinge.position = magic.Vector3(px, 0, c.off[3])
		n.hinge.rotation = magic.Quaternion(0, on and -90 or 0, 0)
		n.body.position = magic.Vector3(c.off[1] - px, c.off[2], 0)
		n.body.scale = v3(c.size)
	else
		n.body.position = v3(b.off)
		n.body.scale = v3(b.size)
	end
	local col = color(b.color, magic.Color(0.8, 0.8, 0.8))
	if look.material == "glass" then
		col = magic.Color(col.r, col.g, col.b, 0.4)
	end
	n.mat:SetShaderParameter("MatDiffColor", col)
	if n.text_node then
		n.text_node.position = magic.Vector3(b.off[1], b.off[2] + b.size[2] / 2 +
				0.45, b.off[3])
	end
	-- Solid: a static body (no mass) the players' bodies meet; a wedge's
	-- its slope and its back, thin
	if n.solid then
		n.solid:Remove()
		n.solid = nil
	end
	if b.solid then
		n.solid = n.look:CreateChild("Solid")
		local function box(pos, size, rot)
			local s = n.solid:CreateChild("Box")
			s.position = pos
			if rot then
				s.rotation = rot
			end
			s:CreateComponent("RigidBody")
			s:CreateComponent("CollisionShape"):SetBox(size)
		end
		if look.shape == "wedge" then
			local sy, sz = b.size[2], b.size[3]
			box(v3(b.off), magic.Vector3(b.size[1], 0.1,
					math.sqrt(sy * sy + sz * sz)), magic.Quaternion(
					-math.deg(math.atan2(sy, sz)), 0, 0))
			box(magic.Vector3(b.off[1], b.off[2], b.off[3] + sz / 2 - 0.05),
					magic.Vector3(b.size[1], sy, 0.1))
		else
			box(v3(b.off), v3(b.size))
		end
	end
	log:info(string.format("kit: entity %d drawn %gx%gx%g at %g,%g,%g%s", id,
			b.size[1], b.size[2], b.size[3], b.off[1], b.off[2], b.off[3],
			b.solid and ", solid" or "") ..
			(look.shape == "wedge" and ", a wedge" or ""))
end

-- The entity as its client parts have it
local function entity_view(id, n)
	local e = {id = id, node = n.node, state = {}}
	function e:shown(key)
		return value(n, key)
	end
	function e:predict(key, v, seconds)
		key = tostring(key)
		n.predicted = n.predicted or {}
		n.predicted[key] = {value = v, was = shown(parse(n.node:GetVar("kit:" ..
				key))), till = buildat.get_time_us() + (tonumber(seconds) or 1) *
				1000000}
		n.on = nil
		log:info("kit: entity " .. id .. " predicted " .. key .. " = " ..
				shown(v))
	end
	function e:log(text)
		log:info("kit: entity " .. id .. "'s client part: " .. tostring(text))
	end
	-- Whether this player's own entity is within d of it
	function e:near(d)
		local me = P.nodes[P.you]
		return me ~= nil and (me.node.position - n.node.position):Length() <=
				(tonumber(d) or 0)
	end
	return e
end

local hud = nil
local function update_play(_, data)
	local dt = data:GetFloat("TimeStep")
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
		-- Its client parts
		local parts = parts_of(n)
		if #parts > 0 then
			n.e = n.e or entity_view(id, n)
			local e = n.e
			e.look, e.hinge, e.body, e.mine = n.look, n.hinge, n.body,
					id == P.you
			if not n.added then
				n.added, n.vals = true, {}
				for _, part in ipairs(parts) do
					call(n, part, "on_add")
				end
			end
			for _, k in ipairs(type(show.shared) == "table" and show.shared or
					{}) do
				local v = n.node:GetVar("kit:" .. tostring(k))
				v = v:IsEmpty() and "" or v:GetString()
				if v ~= n.vals[k] then
					n.vals[k] = v
					e.state[k] = network.parse_json(v)
					for _, part in ipairs(parts) do
						call(n, part, "on_state", k)
					end
				end
			end
			for _, part in ipairs(parts) do
				call(n, part, "on_update", dt)
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

-- The types' client parts, run as this module's own Lua is ([KIT] 4d)
buildat.sub_packet("kit:client_parts", function(data)
	local parts = network.parse_json(data)
	for t, src in pairs(type(parts) == "table" and parts or {}) do
		if type(src) == "string" and not P.parts[t] then
			local ok, part = buildat.eval(src, tostring(t) .. ".client")
			if ok and type(part) == "table" then
				P.parts[t] = part
				log:info("kit: the client part of " .. tostring(t))
			else
				log:warning("kit: the client part of " .. tostring(t) ..
						" does not load: " .. tostring(part))
			end
		end
	end
end)

-- This player's own entity
buildat.sub_packet("kit:you", function(data)
	local y = network.parse_json(data)
	P.you = type(y) == "table" and tonumber(y.id) or 0
	log:info("kit: this player is entity " .. tostring(P.you))
end)

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
		if type(n.show) == "table" and n.show.player then
			-- a player's entity: the app draws the player
		elseif n.box then
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
	-- Its client parts first: what this player sees at once
	local n = P.nodes[tonumber(id) or -1]
	if n and n.e then
		for _, part in ipairs(parts_of(n)) do
			call(n, part, "on_use")
		end
	end
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
