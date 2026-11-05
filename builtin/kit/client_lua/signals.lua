-- Buildat: builtin/kit/client_lua/signals.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_SIGNALS_VIEW] The editor's Signals view (F5): a composition's links as
-- a table, over the whole window under the top bar (a flag with 18 links did
-- not fit the inspector). editor.lua runs this file and puts it at NT.sg.
--   - Left: the entities as a tree, as the Entities tab's (all three of its
--     lists in one), a filter over them (id, name, type); the symbol of one with
--     a link, either way, in the signals' cyan
--   - Middle: the selected one's name to edit, and its links, in both
--     directions, Inputs first: a row a link, flowing left to right as
--     object.member on both sides, the arrow after what it carries (the type,
--     none for a trigger), a gap between entities. Either signal, by either button, opens the link's menu
--     (Delete); the checkbox is whether it is shown in play; an entity's name
--     selects it. "+ Add link" picks an output, a target and an input here
--     (dropdowns)
--   - Right: the inspector (editor.lua's: in this view its parameters and Try
--     alone), under it a View3D of the scene from a camera of its own, on
--     the selected entity; one with no position (or none): what the walk
--     camera sees. With an entity of a HUD element selected, Kit's HUD is laid
--     out in that rectangle (ui.lua's hud_box, by kit.hud_area()) and over it,
--     shown and not clicked, the element on an amber rectangle
--   - Where an entity is listed its name stands after its id; one still
--     named as placed ("kit/flag 16", or nothing) reads as its type
--   - [KIT_SIGNALS_TOGGLE] Under 1500 UI pixels of width the links and the
--     inspector with its viewport share one slot beside the list, the bar's
--     Links and Inspector buttons saying which
--   - A narrow window (a phone): one column at a time, by the bar's buttons
--     (S.touch too); the viewport under the inspector, or none in a short window.
--     Fingers scroll them
-- The world's clicks and keys are not taken here (NT.world_off()), as in the
-- HUD view; Ctrl+Z undoes, Escape goes back. The panels fill the window, so the
-- world is drawn once, in the View3D; under the panels a viewport of an empty
-- scene, on the same render path: what reads the renderer's first viewport
-- (voxel_light's, the sky's parameters) reaches the View3D's picture through it.
-- simplified: the camera jumps to the selected entity from one fixed angle,
-- no orbit or zoom, and may stand in a wall; a drag in it is the upgrade.
-- The View3D's texture is in UI units, soft under a UI scale above 1.
-- The entity's log window is not shown in this view.
-- The HUD in the viewport is shown, not clicked or dragged; the HUD view is for
-- that. A dropdown's list has no scrollbar past half a window: the wheel scrolls
-- it; a scrollbar or a filter of its own is the upgrade.
return function(A)
local K, S, W, NT, IV = A.K, A.S, A.W, A.NT, A.IV
local M, E, O, P = K.M, K.E, K.O, K.P
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local log = K.log
local send, window, find, type_of, typed = A.send, A.window, A.find, A.type_of,
		A.typed
local row, text, label, button, edit = K.row, K.text, K.label, K.button, K.edit
local WARN, DIM = K.WARN, K.DIM

-- filter: the list's; hud: the HUD in the viewport as logged; add: the Add link form ({id, out, to,
-- input}); tab: the column in the slot of a window too narrow for all; area: where the viewport is
local SG = {filter = "", hud = false, add = nil, tab = "links", area = nil}
NT.sg = SG

local MARGIN = 6
-- The longest name a list writes
local NAME_CHARS = 22
-- Under this root width the links and the inspector take turns
local THREE_COLUMNS = 1500

local function kit_short(ty)
	return (tostring(ty):gsub("^kit/", ""))
end

local function main_type(e)
	return e.components and e.components[1] and e.components[1].type or
			e.kind or "?"
end

-- The name a builder gave it, nil for the one it was placed with
local function own_name(e)
	local n, ty = tostring(e.name or ""), main_type(e)
	if n == "" or n == ty or n:match("^(.*) %d+$") == ty then
		return nil
	end
	return n
end

-- "26 ui_bar" or "26 Home's bar"
local function short_name(e)
	return e.id .. " " .. (own_name(e) or kit_short(main_type(e)))
end

-- The first n bytes, not ending inside a character, and ".."
local function cut(s, n)
	return (s:sub(1, n):gsub("[\192-\255][\128-\191]*$", "")) .. ".."
end

local function clipped(s)
	return #s > NAME_CHARS and cut(s, NAME_CHARS - 2) or s
end

-- How an entity reads wherever it is shown: "◆ 21 ui_text", "◆ 21 Prep text"
function NT.entity_label(e)
	return K.ENTITY .. short_name(e)
end

-- As it is shown: its mark, and no longer than a list writes
local function shown_name(e)
	return K.ENTITY .. clipped(short_name(e))
end

-- A column: a window with a ScrollView; its body put in by put_body
local function column(key)
	local w = window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	W[key] = w
	return w
end

local function new_view(w)
	local view = w:CreateChild("ScrollView")
	view:SetStyleAuto()
	view:SetFocusMode(magic.FM_NOTFOCUSABLE)
	view.scrollBarsAutoVisible = true
	return view
end

-- A new body for the view, kept scrolled where it was
local function put_body(view, build)
	local y = view.viewPosition.y
	local body = view:CreateChild("UIElement")
	body:SetLayout(magic.LM_VERTICAL, 3, magic.IntRect(0, 0, 2, 0))
	build(body)
	-- Its width first: wider than the view, a sideways bar comes for a moment
	-- and leaves the view's position past the top
	SG.body_w(view, body)
	view.contentElement = body
	body:SetPosition(0, 0)
	view.viewPosition = magic.IntVector2(0, y)
	return body
end

-- A button no wider than its text, its text at the left
local function tight(parent, s, fn, down)
	local b, t = button(parent, s, fn, down)
	b.maxWidth = b.minWidth
	return b, t
end

-- A thing in a list rather than an action: no button's bevel, a fill under the
-- pointer, the selected one's fill of its own
local function item(parent, s, fn, color, selected)
	local b, t = button(parent, s, fn)
	b:SetStyle(selected and "ListItemSelected" or "ListItem")
	b.blendMode = magic.BLEND_ALPHA
	t:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
	t:SetPosition(4, 0)
	if color then
		t:SetColor(color)
	end
	return b, t
end

-- ---- The list
local function matches(e)
	local f = SG.filter:lower()
	if f == "" then
		return true
	end
	local s = (e.id .. " " .. tostring(e.name) .. " " ..
			main_type(e)):lower()
	return s:find(f, 1, true) ~= nil
end

-- The ids with a link, from or to them, in order
local function linked_ids()
	local set, ids = {}, {}
	for _, e in ipairs(A.all_entities()) do
		for _, c in ipairs(e.components or {}) do
			for _, l in ipairs(c.links or {}) do
				set[e.id], set[l.to] = true, true
			end
		end
	end
	for id in pairs(set) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return set, ids
end

function SG.rows()
	local tabs, indent = NT.entity_lists()
	local ids = {}
	local linked, linked_list = linked_ids()
	SG.list_body = put_body(SG.list_view, function(body)
		for _, name in ipairs({"Game-wide", "Scene", "Positioned"}) do
			local head = false
			for _, e in ipairs(tabs[name]) do
				if matches(e) then
					if not head then
						text(body, name, DIM)
						head = true
					end
					local d = indent[e.id] or 0
					local on = e.id == S.primary
					local own_color = on and magic.Color(1.0, 0.85, 0.3) or nil
					local b, t = item(body, clipped(short_name(e)), function()
						M.select(e.id)
					end, own_color, on)
					-- The symbol a Text of its own, for its own colour
					local m = text(b, K.ENTITY, linked[e.id] and
							magic.Color(ui_utils.rgb("focus")) or own_color)
					m:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
					m:SetPosition(4 + d * 12, 0)
					t:SetPosition(4 + d * 12 + m.width, 0)
					b.minWidth = m.width + t.width + 12 + d * 12
					-- For a driven click by whose it is
					b:SetName("select " .. e.id)
					ids[#ids + 1] = d > 0 and string.rep(">", d) .. e.id or e.id
				end
			end
		end
		if #ids == 0 then
			text(body, "None", DIM)
		end
	end)
	local said = "kit editor: signals: list \"" .. SG.filter .. "\" (" .. #ids ..
			"): " .. table.concat(ids, ", ")
	if said ~= SG.list_said then
		SG.list_said = said
		log:info(said)
	end
	said = "kit editor: signals: linked marks: " .. table.concat(linked_list, ", ")
	if said ~= SG.marks_said then
		SG.marks_said = said
		log:info(said)
	end
end

-- ---- The links
local function link_key(id, l)
	return id .. "." .. l.output .. " " .. l.to .. "." .. l.input
end

local function unlink(id, ci, l)
	log:info("kit editor: signals: unlinked " .. id .. "." .. l.output ..
			" -> " .. l.to .. "." .. l.input)
	send({op = "unlink", id = id, comp = ci - 1, output = l.output, to = l.to,
		input = l.input})
end

local function toggle_visible(id, ci, l)
	log:info("kit editor: signals: " .. id .. "." .. l.output .. " -> " .. l.to ..
			"." .. l.input .. (l.visible and " hidden" or " shown") .. " in play")
	send({op = "link_visible", id = id, comp = ci - 1, output = l.output,
		to = l.to, input = l.input, visible = not l.visible})
end

-- A link's menu, under the signal: both of a row's signals open it, by either
-- button (the right one's press in SG.pressed)
local function link_menu(c)
	if W.ctx then
		W.ctx:Remove()
	end
	local p = c.b.screenPosition
	local w = window(magic.HA_LEFT, magic.VA_TOP, p.x, p.y + c.b.height)
	W.ctx = w
	w.priority = 10
	text(w, c.l.output .. " → " .. c.l.input, DIM)
	button(w, "Delete", function()
		W.ctx:Remove()
		W.ctx = nil
		unlink(c.id, c.ci, c.l)
	end)
	-- On the screen whole
	local root = magic.ui.root
	w:SetPosition(math.max(0, math.min(p.x, root.width - w.width)),
			math.max(0, math.min(p.y + c.b.height, root.height - w.height)))
	log:info("kit editor: signals: the menu of " .. link_key(c.id, c.l))
end

local function at(e, x, y)
	local p = e.screenPosition
	return x >= p.x and y >= p.y and x < p.x + e.width and y < p.y + e.height
end

-- A press anywhere: past the menu it closes it; the right button on a signal
-- opens that link's (a Button's Released is the left button's alone)
function SG.pressed(x, y, right)
	if not NT.sig() then
		return
	end
	local sc = magic.ui.scale
	x, y = x / sc, y / sc
	if W.ctx and not at(W.ctx, x, y) then
		W.ctx:Remove()
		W.ctx = nil
	end
	if right and SG.links_view and at(SG.links_view, x, y) then
		for _, c in ipairs(SG.cells or {}) do
			if at(c.b, x, y) then
				return link_menu(c)
			end
		end
	end
end
magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	local m = magic.input:GetMousePosition()
	SG.pressed(m.x, m.y, data:GetInt("Button") == magic.MOUSEB_RIGHT)
end)
magic.SubscribeToEvent("TouchBegin", function(_, data)
	SG.pressed(data:GetInt("X"), data:GetInt("Y"), false)
end)

-- Shown in play: a checkbox and its label, both the button
local function shown_check(r, id, ci, l)
	local b, t = item(r, "Shown", function() toggle_visible(id, ci, l) end)
	b:SetName("visible " .. link_key(id, l))
	local c = b:CreateChild("CheckBox")
	c:SetStyleAuto()
	c.checked = l.visible and true or false
	-- The button under it takes the click
	c.enabled = false
	c:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
	c:SetPosition(4, 0)
	t:SetPosition(24, 0)
	return b, t, t.width + 28
end

-- What a link passes on: the output's type, or the input's where the output
-- says any; "" where the input takes no value (a trigger, whatever is sent)
local function carries(x)
	local c = x.from and x.from.components and x.from.components[x.ci]
	local out = c and A.signal_kind(type_of(c.type), "outputs", x.l.output) or
			"any"
	local inn = "any"
	for _, tc in ipairs(x.to and x.to.components or {}) do
		local kind = A.signal_kind(type_of(tc.type), "inputs", x.l.input)
		if kind then
			inn = kind
			break
		end
	end
	if inn == "none" then
		return ""
	end
	return out == "any" and inn or out
end

-- The links as a table, a link to a row, flowing left to right, as
-- object.member: "◆ 18 timer.done  number →  ◆ 16 bar.value  [ ] Shown". Inputs and
-- outputs alike, the selected entity repeated on each. The names stand against
-- their dots, the dots in a column; the arrow has spare room on both sides and
-- the checkbox the right edge. rows: {first = a new other entity, from, from_id,
-- to, to_id, ci, l}.
-- simplified: a window too narrow for that writes the selected entity as its id
-- alone, drops the checkbox's label and shortens the other names, then scrolls
-- sideways.
local function link_table(body, rows, self_id)
	local DOT, ARROW, INDENT = 5, 20, 8
	local widest = {lname = 0, lsig = 0, kind = 0, rname = 0, rsig = 0, check = 0}
	local built = {}
	for i, x in ipairs(rows) do
		if x.first and i > 1 then
			body:CreateChild("UIElement"):SetFixedHeight(10)
		end
		local r = row(body)
		r:SetLayout(magic.LM_HORIZONTAL, 0, magic.IntRect(INDENT, 0, 0, 0))
		local cells = {}
		local function entity(e, id, key)
			local goal = e and e.id or id
			local c = {s = e and NT.entity_label(e) or K.ENTITY .. tostring(id),
				own = goal == self_id, short = K.ENTITY .. tostring(goal)}
			c.b, c.t = item(r, e and shown_name(e) or c.s, function()
				M.select(goal)
			end)
			c.t:SetAlignment(magic.HA_RIGHT, magic.VA_CENTER)
			c.t:SetPosition(-1, 0)
			if goal == self_id then
				-- It is what the page is about: nothing to go to
				c.b.enabled = false
			else
				c.b:SetName("goto " .. tostring(goal))
			end
			cells[key] = c
			widest[key] = math.max(widest[key], c.t.width + 5)
		end
		local function signal(s, key, name)
			local c = {id = x.from_id, ci = x.ci, l = x.l}
			c.b, c.t = item(r, s, function() link_menu(c) end,
					magic.Color(ui_utils.rgb("focus")))
			c.t:SetPosition(1, 0)
			c.b:SetName(name .. link_key(x.from_id, x.l))
			SG.cells[#SG.cells + 1] = c
			cells[key] = c
			widest[key] = math.max(widest[key], c.t.width + 5)
		end
		local function dot()
			text(r, "."):SetFixedWidth(DOT)
		end
		entity(x.from, x.from_id, "lname")
		dot()
		signal(x.l.output, "lsig", "signal ")
		cells.gap1 = r:CreateChild("UIElement")
		x.kind = carries(x)
		-- (a space's width from the arrow)
		cells.kind = text(r, x.kind == "" and "" or x.kind .. " ", DIM)
		cells.kind:SetTextAlignment(magic.HA_RIGHT)
		if x.kind ~= "" then
			-- (minWidth: its text's own, the row may have stretched it)
			widest.kind = math.max(widest.kind, cells.kind.minWidth + 4)
		end
		text(r, "→"):SetFixedWidth(ARROW)
		cells.gap2 = r:CreateChild("UIElement")
		entity(x.to, x.to_id, "rname")
		dot()
		signal(x.l.input, "rsig", "signal in ")
		cells.gap3 = r:CreateChild("UIElement")
		local check, t, w = shown_check(r, x.from_id, x.ci, x.l)
		cells.check, cells.check_t = check, t
		widest.check = math.max(widest.check, w)
		built[i] = cells
		if x.kind ~= "" then
			SG.kinds[#SG.kinds + 1] = x.l.output .. ">" .. x.l.input .. " " .. x.kind
		end
	end
	local function spare_now()
		return SG.links_w - (INDENT + widest.lname + widest.lsig + widest.kind +
				widest.rname + widest.rsig + 2 * DOT + ARROW + widest.check)
	end
	-- Too narrow: the selected entity's name, on every row, as its id alone
	if spare_now() < 0 then
		for _, key in ipairs({"lname", "rname"}) do
			if built[1][key].own then
				widest[key] = 0
				for _, cells in ipairs(built) do
					local c = cells[key]
					c.t:SetText(c.short)
					widest[key] = math.max(widest[key], c.t.width + 5)
				end
			end
		end
	end
	-- Then the checkbox alone: a name says more than a label on every row
	if spare_now() < 0 then
		widest.check = 26
		for _, cells in ipairs(built) do
			cells.check_t.visible = false
		end
	end
	-- Then the other names shorter, down to what still tells them apart
	local over = -spare_now()
	if over > 0 then
		local key = built[1].lname.own and "rname" or "lname"
		local w = math.max(60, widest[key] - over)
		for _, cells in ipairs(built) do
			local c = cells[key]
			for n = #c.s - 2, 4, -1 do
				if c.t.width + 5 <= w then
					break
				end
				c.t:SetText(cut(c.s, n))
			end
		end
		widest[key] = w
	end
	local spare = math.max(0, spare_now())
	local around = math.floor(spare * 0.25)
	for _, cells in ipairs(built) do
		for _, key in ipairs({"lname", "lsig", "rname", "rsig"}) do
			cells[key].b:SetFixedWidth(widest[key])
		end
		cells.gap1:SetFixedWidth(around)
		cells.kind:SetFixedWidth(widest.kind)
		cells.gap2:SetFixedWidth(around)
		cells.gap3:SetFixedWidth(spare - 2 * around)
		cells.check:SetFixedWidth(widest.check)
	end
	if #rows == 0 then
		text(body, "None", DIM)
	end
	return #rows
end

-- This entity's links, by target and then by input, in the order first met
local function outputs(body, e)
	local order, targets = {}, {}
	for ci, c in ipairs(e.components or {}) do
		for _, l in ipairs(c.links or {}) do
			local g = targets[l.to]
			if not g then
				g = {to = l.to, inputs = {}, by = {}}
				targets[l.to] = g
				order[#order + 1] = g
			end
			local i = g.by[l.input]
			if not i then
				i = {}
				g.by[l.input] = i
				g.inputs[#g.inputs + 1] = i
			end
			i[#i + 1] = {ci = ci, l = l}
		end
	end
	local rows = {}
	for _, g in ipairs(order) do
		local to, first = find(g.to), true
		for _, i in ipairs(g.inputs) do
			for _, x in ipairs(i) do
				rows[#rows + 1] = {first = first, from = e, from_id = e.id, to = to,
					to_id = g.to, ci = x.ci, l = x.l}
				first = false
			end
		end
	end
	return link_table(body, rows, e.id)
end

-- The links into this entity, by source
local function inputs(body, e)
	local rows = {}
	for _, src in ipairs(A.all_entities()) do
		local first = true
		for ci, c in ipairs(src.components or {}) do
			for _, l in ipairs(c.links or {}) do
				if l.to == e.id then
					rows[#rows + 1] = {first = first, from = src, from_id = src.id,
						to = e, to_id = e.id, ci = ci, l = l}
					first = false
				end
			end
		end
	end
	return link_table(body, rows, e.id)
end

-- The outputs it has, {label, "<comp index> <output>"}
local function output_choices(e)
	local r = {}
	for ci, c in ipairs(e.components or {}) do
		local t = type_of(c.type)
		for _, o in ipairs(t.outputs or {}) do
			r[#r + 1] = {o .. typed(t, "outputs", o), (ci - 1) .. " " .. o}
		end
	end
	return r
end

local function input_choices(e)
	local r, seen = {}, {}
	for _, c in ipairs(e and e.components or {}) do
		local t = type_of(c.type)
		for _, i in ipairs(t.inputs or {}) do
			if not seen[i] then
				seen[i] = true
				r[#r + 1] = {i .. typed(t, "inputs", i), i}
			end
		end
	end
	return r
end

local function pick(body, what, choices, current, fn)
	local d = ui_utils.dropdown(body, choices, current, fn, {label = what,
		fill = true, label_width = 62, none = #choices > 0 and "Choose" or nil})
	-- A popup goes as tall as its list and past the window's edge: the list
	-- scrolled within half a window
	d.listView.maxHeight = math.floor(magic.ui.root.height / 2)
end

local function add_form(body, e)
	local a = SG.add
	local outs = output_choices(e)
	a.out = a.out or (outs[1] and outs[1][2])
	pick(body, "Output", outs, a.out, function(v)
		a.out = v
		log:info("kit editor: signals: add link: output " .. tostring(v))
	end)
	local targets = {}
	for _, x in ipairs(A.entities()) do
		if x.id ~= e.id and x.kind ~= "scene" and #input_choices(x) > 0 then
			targets[#targets + 1] = {NT.entity_label(x), x.id}
		end
	end
	pick(body, "Target", targets, a.to, function(v)
		a.to = v
		a.input = nil
		log:info("kit editor: signals: add link: target " .. tostring(v))
		SG.links()
	end)
	local inputs = a.to and input_choices(find(a.to)) or {}
	a.input = a.input or (inputs[1] and inputs[1][2])
	pick(body, "Input", inputs, a.input, function(v)
		a.input = v
		log:info("kit editor: signals: add link: input " .. tostring(v))
	end)
	local r = row(body)
	tight(r, "Link", function()
		local comp, output = tostring(a.out):match("^(%d+) (.*)$")
		if not (comp and a.to and a.input) then
			E.status = "Add link: an output, a target and an input"
			return SG.status()
		end
		E.status = ""
		log:info("kit editor: signals: linked " .. e.id .. "." .. output .. " -> " ..
				a.to .. "." .. a.input)
		send({op = "link", id = e.id, comp = tonumber(comp), output = output,
			to = a.to, input = a.input})
	end)
	tight(r, "Done", function()
		SG.add = nil
		SG.links()
	end)
end

function SG.links()
	local e, is_made = nil, false
	if S.primary then
		e, is_made = find(S.primary)
	end
	local title = "Select an entity on the left"
	if e then
		local own = own_name(e)
		title = "Signals of " .. K.ENTITY .. e.id .. " " .. (own and own .. " (" ..
				main_type(e) .. ")" or main_type(e))
	end
	if SG.add and (not e or SG.add.id ~= e.id) then
		SG.add = nil
	end
	SG.cells, SG.links_drawn_w, SG.kinds = {}, SG.links_w, {}
	SG.links_body = put_body(SG.links_view, function(body)
		text(body, title, magic.Color(1.0, 0.85, 0.3))
		SG.status_text = text(body, E.status or "", WARN)
		SG.status_text.visible = (E.status or "") ~= ""
		if not e then
			return
		end
		if is_made then
			text(body, "Made in play or a player: its links are not edited", DIM)
			return
		end
		-- Its name, what is typed kept as the table is drawn again
		local nr = row(body)
		local nl = label(nr, "Name")
		nl:SetFixedWidth(nl.minWidth + 6)
		if SG.name_of ~= e.id then
			SG.name_of, SG.name_text = e.id, nil
		end
		local function rename()
			log:info("kit editor: signals: renamed " .. e.id .. " to \"" ..
					tostring(SG.name_text or own_name(e) or "") .. "\"")
			send({op = "rename", id = e.id,
				name = SG.name_text or own_name(e) or ""})
			SG.name_text = nil
		end
		local f = edit(nr, SG.name_text or own_name(e) or "", function(s)
			SG.name_text = s
		end)
		f:SetName("signals name")
		magic.SubscribeToEvent(f, "TextFinished", rename)
		tight(nr, "Rename", rename)
		body:CreateChild("UIElement"):SetFixedHeight(8)
		text(body, "Inputs", magic.Color(ui_utils.rgb("text")))
		local inn = inputs(body, e)
		body:CreateChild("UIElement"):SetFixedHeight(12)
		local head = row(body)
		local ol = label(head, "Outputs")
		ol:SetFixedWidth(ol.minWidth + 12)
		local b = tight(head, SG.add and "+ Add link: close" or "+ Add link",
				function()
			SG.add = not SG.add and {id = e.id} or nil
			log:info("kit editor: signals: add link " ..
					(SG.add and "open" or "closed"))
			SG.links()
		end, SG.add ~= nil)
		b:SetName("add link")
		if SG.add then
			add_form(body, e)
		end
		local out = outputs(body, e)
		local said = "kit editor: signals: " .. e.id .. " " .. short_name(e) ..
				": " .. out .. " out, " .. inn .. " in; " ..
				table.concat(SG.kinds, ", ")
		if said ~= SG.links_said then
			SG.links_said = said
			log:info(said)
		end
	end)
end

-- A refusal or what a form lacks, as people() would have said it
function SG.status()
	if SG.status_text then
		SG.status_text.text = E.status or ""
		SG.status_text.visible = (E.status or "") ~= ""
	end
end

-- Escape: the form first; true when taken
function SG.escape()
	if SG.add then
		SG.add = nil
		SG.links()
		return true
	end
	return false
end

-- A view's key while typing in the filter
function SG.view_key(key, keys)
	if not NT.sig() then
		return false
	end
	for _, action in pairs(keys) do
		if M.key(action, key) then
			return true
		end
	end
	return false
end

-- ---- The viewport
function SG.node()
	if not SG.cam_node then
		SG.cam_node = O.scene:CreateChild("kit_camera_signals")
		SG.cam = SG.cam_node:CreateComponent("Camera")
	end
	return SG.cam_node
end

-- Made once and kept, hidden out of this view (hidden it draws nothing): the
-- lighting (kit.lit_viewport) holds on to the viewports. What the window's
-- viewports are to be in this view
function SG.world_viewport()
	if SG.under then
		return SG.under
	end
	local w = window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	w.visible = false
	-- Under the HUD drawn over it (kit/ui_*: down to -1040; markers -1500),
	-- over the client's own picture of the world (-10000)
	w.priority = -9000
	w.opacity = 1
	SG.view_win = w
	local v = w:CreateChild("View3D")
	v:SetFixedSize(160, 120)
	v:SetView(O.scene, (SG.node() and SG.cam), false)
	SG.view3d = v
	local vp = v:GetViewport()
	local scene = magic.Scene.new()
	scene:CreateComponent("Octree")
	local zone = scene:CreateChild("zone"):CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.fogColor = magic.Color(0, 0, 0)
	SG.under_scene = scene
	SG.under = magic.Viewport:new(scene,
			scene:CreateChild("camera"):CreateComponent("Camera"))
	if O.viewport then
		local rp = O.viewport().renderPath
		SG.under.renderPath = rp
		vp.renderPath = rp
	else
		M.lit_viewport(SG.under, "signals", function(rp)
			vp.renderPath = rp
		end, SG.cam_node)
	end
	return SG.under
end

function M.hud_area()
	local n = SG.area and M.selected and P.nodes[M.selected()]
	local on = n and type(n.show) == "table" and type(n.show.ui) == "table"
	if (on or false) ~= SG.hud then
		SG.hud = on or false
		log:info("kit editor: signals: the HUD in the viewport " ..
				(SG.hud and "on" or "off"))
	end
	return on and SG.area or nil
end

-- Each frame: the camera; the layout as the window or the bar changes
function SG.tick()
	if not NT.sig() or not SG.view3d then
		return
	end
	SG.layout()
	local walk = O.camera
	local wc = walk:GetComponent("Camera")
	SG.cam.fov, SG.cam.nearClip, SG.cam.farClip = wc.fov, wc.nearClip, wc.farClip
	local e = S.primary and find(S.primary)
	local shows
	if e and e.pos then
		local at = A.drawn_at(e)
		local q = magic.Quaternion(32, 40, 0)
		SG.cam_node.rotation = q
		SG.cam_node.position = at + q * magic.Vector3(0, 0, -6)
		shows = "entity " .. e.id
	else
		SG.cam_node.position = walk.worldPosition
		SG.cam_node.direction = walk.worldDirection
		shows = "what the walk camera shows"
	end
	if shows ~= SG.shows then
		SG.shows = shows
		local p = SG.cam_node.worldPosition
		log:info(string.format("kit editor: signals: the viewport shows %s, " ..
				"from %.2f %.2f %.2f", shows, p.x, p.y, p.z))
	end
end

-- ---- The columns
-- simplified: the columns' shares fixed; dragging their edges is the upgrade
local function fit(win, view, body, x, y, w, h, above)
	win:SetPosition(x, y)
	win:SetFixedSize(w, h)
	-- Sized from the root: not to hold the client's fit down (update_ui_fit)
	win:SetVar("FollowsRoot", "1")
	if view then
		-- The body first: wider than a narrowed view, a sideways bar comes for
		-- a moment and leaves the view's position past the top
		SG.body_w(view, body, w - 12)
		view:SetFixedSize(w - 12, h - 12 - (above or 0))
	end
end

function SG.body_w(view, body, view_w)
	if body then
		-- Room for its bar
		local w = (view_w or view.width) - view.verticalScrollBar.width - 8
		body.minWidth = w
		-- A narrower window: the layout keeps a width it had
		body.width = w
	end
end

-- What the window has room for: "wide" all three columns, "two" the list and
-- one of the others, "narrow" one column
local function mode_now()
	if A.narrow() then
		return "narrow"
	end
	return magic.ui.root.width < THREE_COLUMNS and "two" or "wide"
end

-- The column in the slot: "two" has the list up anyway
local function tab_now(mode)
	return mode == "two" and SG.tab == "list" and "links" or SG.tab
end

-- Whether a column is up
local function shown(tab)
	local mode = SG.mode
	return mode == "wide" or (mode == "two" and tab == "list") or
			tab_now(mode) == tab
end

function SG.layout(force)
	local root, bar = magic.ui.root, W.bar
	local top = bar and bar.screenPosition.y + bar.height + MARGIN or 40
	local rw, rh = root.width, root.height
	local was_mode = SG.mode
	SG.mode = mode_now()
	SG.is_narrow = SG.mode == "narrow"
	local key = table.concat({rw, rh, top, SG.mode, tab_now(SG.mode)}, " ")
	if key == SG.laid and not force then
		SG.area_update()
		return
	end
	SG.laid = key
	local h = rh - top - MARGIN
	local lx, lw, mx, mw, rx, rcw
	if SG.is_narrow then
		lx, mx, rx = MARGIN, MARGIN, MARGIN
		lw, mw, rcw = rw - 2 * MARGIN, rw - 2 * MARGIN, rw - 2 * MARGIN
	elseif SG.mode == "two" then
		lw = math.floor(math.max(180, math.min(360, rw * 0.18)))
		mw = rw - lw - 3 * MARGIN
		rcw = mw
		lx, mx, rx = MARGIN, 2 * MARGIN + lw, 2 * MARGIN + lw
	else
		lw = math.floor(math.max(180, math.min(360, rw * 0.18)))
		rcw = math.floor(math.max(420, math.min(640, rw * 0.36)))
		mw = rw - lw - rcw - 4 * MARGIN
		lx, mx, rx = MARGIN, 2 * MARGIN + lw, 3 * MARGIN + lw + mw
	end
	SG.links_w = mw - 12 - 20
	if W.sg_list then
		W.sg_list.visible = shown("list")
		fit(W.sg_list, SG.list_view, SG.list_body, lx, top, lw, h, SG.filter_h)
	end
	if W.sg_links then
		W.sg_links.visible = shown("links")
		fit(W.sg_links, SG.links_view, SG.links_body, mx, top, mw, h)
	end
	-- The viewport's height: a 4:3 picture of the column, at most 45 percent
	local vh = math.floor(math.min(h * 0.45, (rcw - 12) * 0.75)) + 12
	local on_right = shown("inspector")
	-- A short narrow window (a phone held sideways): the inspector alone
	local no_view = SG.is_narrow and h < 320
	if no_view then
		vh = -MARGIN
	end
	if W.sg_view then
		W.sg_view.visible = on_right and not no_view
		fit(W.sg_view, nil, nil, rx, top + h - vh, rcw, vh)
		SG.view3d:SetFixedSize(rcw - 12, math.max(1, vh - 12))
	end
	if W.inspector and IV.view then
		W.inspector.visible = on_right
		fit(W.inspector, IV.view, IV.view.contentElement, rx, top, rcw, h - vh - MARGIN)
	end
	SG.area_update()
	if SG.links_view and SG.links_drawn_w and SG.links_drawn_w ~= SG.links_w then
		SG.links()
	end
	-- The inspector's fields are made at a width: made again at a new one
	local was = SG.inspector_w
	SG.inspector_w = rcw
	-- A new mode too: the bar's buttons with it (the refresh's layout finds both
	-- the same)
	if (was and was ~= rcw) or (was_mode and was_mode ~= SG.mode) then
		A.refresh()
	end
	local r = {}
	for _, k in ipairs({"sg_list", "sg_links", "inspector", "sg_view"}) do
		local w = W[k]
		if w and w.visible then
			r[#r + 1] = string.format("%s %d %d %d %d", k, w.position.x, w.position.y,
					w.width, w.height)
		end
	end
	local said = "kit editor: signals: columns in " .. rw .. "x" .. rh ..
			" under " .. top .. ": " .. table.concat(r, ", ")
	if said ~= SG.columns_said then
		SG.columns_said = said
		log:info(said)
	end
end

function SG.area_update()
	local w = SG.view_win
	if not (NT.sig() and w and w.visible) then
		SG.area = nil
		return
	end
	local v, a = SG.view3d, SG.area or {}
	local p = v.screenPosition
	a.x, a.y, a.w, a.h, a.node, a.cam = p.x, p.y, v.width, v.height, SG.cam_node,
			SG.cam
	SG.area = a
end

-- The inspector just built into its window (editor.lua's inspector_window)
function SG.inspector(win, view)
	view.scrollBarsAutoVisible = true
	SG.laid = nil
	SG.layout(true)
end

-- The columns that take turns, in the bar
function SG.bar(bar_button)
	local mode = mode_now()
	if mode == "wide" then
		return
	end
	for _, c in ipairs({{"list", "Entities"}, {"links", "Links"},
			{"inspector", "Inspector"}}) do
		if mode == "narrow" or c[1] ~= "list" then
			bar_button(c[2], nil, function()
				SG.tab = c[1]
				log:info("kit editor: signals: the column " .. c[2])
				A.refresh()
			end, tab_now(mode) == c[1])
		end
	end
end

local function close()
	-- The ordinary inspector counts for the fit again
	if W.inspector then
		W.inspector:SetVar("FollowsRoot", "")
	end
	if W.sg_list then
		W.sg_list:Remove()
		W.sg_list, SG.list_view, SG.list_body = nil, nil, nil
	end
	if W.sg_links then
		W.sg_links:Remove()
		W.sg_links, SG.links_view, SG.links_body, SG.status_text = nil, nil, nil,
				nil
	end
	if SG.view_win then
		SG.view_win.visible = false
		W.sg_view = nil
	end
	SG.area, SG.laid, SG.shows, SG.cells, SG.links_drawn_w = nil, nil, nil, nil, nil
	SG.inspector_w, SG.mode = nil, nil
	SG.add = nil
end

-- With the editor's other windows, on every state
function SG.refresh()
	if not NT.sig() then
		return close()
	end
	if not W.sg_list then
		local w = column("sg_list")
		local r = row(w)
		r:SetFixedHeight(26)
		local fl = label(r, "Filter")
		fl:SetFixedWidth(fl.minWidth + 6)
		local f = edit(r, SG.filter, function(s)
			SG.filter = s
			SG.rows()
		end)
		f:SetName("signals filter")
		f.minWidth = 40
		SG.filter_h = 30
		SG.list_view = new_view(w)
	end
	if not W.sg_links then
		SG.links_view = new_view(column("sg_links"))
	end
	SG.world_viewport()
	W.sg_view = SG.view_win
	SG.view_win.visible = true
	SG.layout(true)
	SG.rows()
	SG.links()
	SG.layout(true)
end
end
-- vim: set noet ts=4 sw=4:
