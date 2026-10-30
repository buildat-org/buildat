-- Buildat: builtin/kit/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 3, Kit's editor on the client (builtin/kit/api.h says what
-- the server takes). An app hosting Kit turns it on with
--   local kit = require("buildat/module/kit")
--   kit.editor{scene = scene, camera = camera_node, ground_y = 1}
-- An "Edit" button (and F6) asks the server for edit mode; with edit
-- rights the server answers with the palette and the authored tree:
--   - a click on the view selects the entity there, or puts the cursor on
--     the ground (y = ground_y) where "Place <type>" puts a new one; Tab
--     selects the next entity
--   - the arrows move the selected one on the ground, Page Up and Down up
--     and down; Delete deletes it; Ctrl+Z undoes this editor's last edit
--   - the inspector: the selected entity's instances, their parameters in
--     ui_utils' settings_form, "Apply" sends them; "Link <output>" and then
--     another entity's "To <input>" links them
--   - every entity drawn as a box, the selected one yellow, links as lines,
--     and a type's gizmo (a sphere or a box), in edit mode only
-- kit.selected(): the id last selected, kept after edit mode.
-- simplified: placed on a ground plane, a nudge by keys and no drag, the
-- windows rebuilt whole on each state; picking against the voxels, a drag
-- and a gizmo per handle are the upgrades
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = buildat.Logger("kit")

local M = {}
local E = {editing = false, state = nil, sel = nil, link = nil,
	cursor = nil, pending = {}, status = "", windows = {}}
local O = nil -- the app's options

local WARN = magic.Color(1.0, 0.55, 0.45)
local DIM = magic.Color(0.7, 0.7, 0.7)
local STYLE = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")

function M.selected()
	return E.sel
end

local function send(t)
	local text = network.write_json(t)
	log:info("kit editor: sent " .. tostring(text))
	buildat.send_packet("kit:edit", text)
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

local function center(e)
	return magic.Vector3(e.pos[1] + 0.5, e.pos[2] + 0.5, e.pos[3] + 0.5)
end

local function color(hex, fallback)
	local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then
		return fallback
	end
	return magic.Color(tonumber(r, 16) / 255, tonumber(g, 16) / 255,
			tonumber(b, 16) / 255)
end

-- ---- The windows

local function window(halign, x)
	local w = magic.ui.root:CreateChild("Window")
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = STYLE
	end
	w:SetStyleAuto()
	w:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(6, 6, 6, 6))
	w:SetAlignment(halign, magic.VA_TOP)
	w:SetPosition(x, 40)
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

local rebuild

local function inspector(w, e)
	text(w, "Entity " .. e.id .. ": " .. tostring(e.name))
	if e.pos then
		text(w, string.format("at %d, %d, %d", e.pos[1], e.pos[2], e.pos[3]),
				DIM)
	end
	for ci, c in ipairs(e.components or {}) do
		local t = type_of(c.type)
		text(w, c.type, magic.Color(1.0, 0.85, 0.3))
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
		return
	end
	local w = window(magic.HA_LEFT, 10)
	text(w, "Edit mode", magic.Color(1.0, 0.85, 0.3))
	text(w, "Click: select, or the cursor. Tab: next.", DIM)
	text(w, "Arrows, PgUp/PgDn: move. Del. Ctrl+Z.", DIM)
	for _, t in ipairs(E.state.palette or {}) do
		button(w, "Place " .. t, function()
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
	local e = E.sel and find(E.sel)
	if e then
		inspector(window(magic.HA_RIGHT, -10), e)
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
	return false
end

local function select(id)
	E.sel = id
	local e = id and find(id)
	log:info("kit editor: selected " .. tostring(id) .. " (" ..
			tostring(e and e.name) .. ")")
	rebuild()
end

-- The ground cell (y = ground_y) under a point of the screen (fractions)
local function ground_at(fx, fy)
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
	local t = math.abs(vy) > 1e-6 and (O.ground_y - o.y) / vy or -1
	if t <= 0 then
		return nil
	end
	return {math.floor(o.x + vx * t), O.ground_y, math.floor(o.z + vz * t)}
end

-- A click on the view: the entity drawn there (its box's centre near, or
-- its cell the ground's under the pointer), else the cursor on the ground
local function click_view(mx, my)
	local cam = O.camera:GetComponent("Camera")
	local sc = magic.ui.scale
	local fx = mx / sc / magic.ui.root.width
	local fy = my / sc / magic.ui.root.height
	local g = ground_at(fx, fy)
	local best, bd = nil, 0.03 * 0.03
	for _, e in ipairs(entities()) do
		if e.pos then
			local p = cam:WorldToScreenPoint(center(e))
			local d = (p.x - fx) * (p.x - fx) + (p.y - fy) * (p.y - fy)
			if g and e.pos[1] == g[1] and e.pos[2] == g[2] and e.pos[3] == g[3] then
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
					magic.Vector3(x + 0.1, y + 0.1, z + 0.1),
					magic.Vector3(x + 0.9, y + 0.9, z + 0.9)),
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
		dbg:AddCross(magic.Vector3(E.cursor[1] + 0.5, E.cursor[2],
				E.cursor[3] + 0.5), 0.8, magic.Color(1, 0.4, 1), false)
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

function M.editor(options)
	O = options
	O.ground_y = O.ground_y or 0
	-- The scene's own one where it has it (the replicated scene does): the
	-- view draws the first
	O.debug = O.scene:GetComponent("DebugRenderer") or
			O.scene:CreateComponent("DebugRenderer")
	local toggle = function()
		send({op = "mode", on = not E.editing})
	end
	local w = magic.ui.root:CreateChild("Window")
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = STYLE
	end
	w:SetStyleAuto()
	w:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(4, 4, 4, 4))
	w:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
	w:SetPosition(-10, 4)
	local edit_button = button(w, "Edit", toggle)
	local edit_text = edit_button:GetChild(0)

	buildat.sub_packet("kit:edit_state", function(data)
		local s = network.parse_json(data)
		if type(s) ~= "table" then
			return
		end
		local was = E.editing
		E.editing = s.editing == true
		E.state = E.editing and s or nil
		if was ~= E.editing then
			log:info("kit editor: edit mode " .. (E.editing and "on" or "off"))
			E.link, E.status = nil, ""
		end
		edit_text:SetText(E.editing and "Leave edit mode" or "Edit")
		edit_button.minWidth = edit_text.width + 16
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
			return toggle()
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
		if over_windows(m.x / sc, m.y / sc) or inside(w, m.x / sc, m.y / sc) or
				ui_utils.dropdown_open() then
			return
		end
		click_view(m.x, m.y)
	end)
	magic.SubscribeToEvent("Update", draw)
end

return M
-- vim: set noet ts=4 sw=4:
