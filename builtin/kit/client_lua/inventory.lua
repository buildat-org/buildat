-- Buildat: builtin/kit/client_lua/inventory.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_INVENTORY_PLAY] [KIT_HUD] Kit's own slots on the screen (the
-- server's "kit:slots" {slots, held, rules}: kit/game_rules' rules), as
-- skeldat draws its inventory (apps/skeldat/main/client_lua/ui.lua):
--   **The hotbar**: the first `hotbar` slots (0: none) at the bottom, the
--   held one framed, each item's picture (an item type's icon, a voxel's
--   side) or its name's start, and its count; under the held item its
--   uses and rounds left. The wheel (first person) and item_next/prev
--   step through it, the keys hotbar1...10 (1...0) pick a slot in
--   "inventory" building (the creative palette's keys otherwise), a tap
--   on a slot picks it (on a touchscreen a tap on the held one opens the
--   screen). "kit:hold" "#<n>" tells the server.
--   **The health bar** above it while the rule show_health is on (the
--   player's kit/health, its shared hp and max).
--   **The inventory screen** (the rule screen; the key inventory, E):
--   the slots in rows of nine, the hotbar's row apart at the bottom, an
--   open chest's above ("kit:chest" {id, name, size, slots}, as a chest
--   is used). A click picks a stack up and the next one puts it (the
--   right button: half of it up, one down); the same slot again lets it
--   go; a pick let go outside the window is dropped (the rule
--   drop_items), a click outside with none closes it, as do its key and
--   Escape (kit.close_screens()). The drop key (Q) drops one of the held
--   slot (Ctrl: the stack). The server moves ("kit:inv").
-- For a drive: "event kit_slot <n>" holds slot n, "event kit_inventory"
-- opens or closes the screen, "event kit_inv_click <p|c> <slot> [right]"
-- clicks a slot ("out": outside the window), "event kit_drop [all]".
-- simplified: the picked stack stays drawn in its slot, outlined, until
-- it is put down (skeldat's); no tooltips
return function(K)
local M, E, O, P = K.M, K.E, K.O, K.P
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = K.log
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"
local WEB = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
local U = 44 -- a slot's square (UI pixels) with its gap
local S = {slots = {}, held = 0, rules = {}, chest = nil, logged = nil}

local function hotbar_n()
	return math.max(0, math.min(10, math.floor(tonumber(S.rules.hotbar) or 0)))
end

function M.slots_own()
	return S.rules.own == true
end

function M.building()
	return S.rules.building or "inventory"
end

-- The rules for the rest (Workbench's placing, the health bar)
function M.game_rule(k)
	return S.rules[k]
end

local function item_of(i)
	local s = S.slots[i]
	return type(s) == "table" and type(s.item) == "string" and s.item or ""
end

-- ---- Drawing

local z = 0
local function box(parent, x, y, w, h, col)
	local e = parent:CreateChild("BorderImage")
	z = z + 1
	e.priority = z
	e.blendMode = magic.BLEND_ALPHA
	e.color = col
	e:SetPosition(math.floor(x), math.floor(y))
	e:SetFixedSize(math.floor(w), math.floor(h))
	return e
end

local function text(parent, s, x, y, size, col)
	local t = parent:CreateChild("Text")
	z = z + 1
	t.priority = z
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), size)
	t:SetTextEffect(magic.TE_SHADOW)
	t:SetText(s)
	t:SetPosition(math.floor(x), math.floor(y))
	if col then
		t:SetColor(col)
	end
	return t
end

local textures = {}
local function texture(res)
	if textures[res] == nil then
		local t = res ~= "" and magic.cache:Exists(res) and
				magic.cache:GetResource("Texture2D", res) or false
		if t then
			t.filterMode = magic.FILTER_NEAREST
		end
		textures[res] = t
	end
	return textures[res] or nil
end

-- An item's picture in a square of n at x, y: an item type's icon, a
-- voxel's side, else a box of its colour with its name's start
local function picture(parent, item, x, y, n)
	local sheet = M.item_types[item]
	local tex, rect = nil, nil
	if sheet and type(sheet.icon) == "string" and sheet.icon ~= "" then
		tex = texture(sheet.icon)
	elseif not sheet and K.voxel_def then
		local def = K.voxel_def(item)
		local seg = def and def.textures and (def.textures[3] or def.textures[1])
		tex = seg and texture(seg.resource_name or "")
		if tex and (seg.total_segments or 1) > 1 then
			local w = math.floor(tex.width / seg.total_segments)
			rect = magic.IntRect(w * seg.select_segment, 0,
					w * (seg.select_segment + 1), tex.height)
		end
	end
	if tex then
		local e = box(parent, x, y, n, n, magic.Color(1, 1, 1))
		e.texture = tex
		e.imageRect = rect or magic.IntRect(0, 0, tex.width, tex.height)
		return
	end
	box(parent, x + 2, y + 2, n - 4, n - 4, K.color(sheet and sheet.color,
			magic.Color(0.45, 0.45, 0.5)))
	local short = item:gsub("^[^/]*/", ""):sub(1, 5)
	text(parent, short, x + 3, y + 3, 10)
end

local function stack(parent, s, x, y, n)
	if type(s) ~= "table" or type(s.item) ~= "string" then
		return
	end
	picture(parent, s.item, x, y, n)
	local c = tonumber(s.n) or 1
	if c > 1 then
		local t = text(parent, tostring(c), 0, 0, 12)
		t:SetTextEffect(magic.TE_STROKE) -- readable over a light picture
		t:SetPosition(math.floor(x + n - t.width), math.floor(y + n - t.height))
	end
	-- Wear left as a bar (the first instance's uses of its type's)
	local sheet = M.item_types[s.item]
	local uses = sheet and tonumber(sheet.uses) or 0
	if uses > 0 and tonumber(s.wear) then
		local f = math.max(0, math.min(1, s.wear / uses))
		box(parent, x + 3, y + n - 5, (n - 6) * f, 3,
				magic.Color(1 - f, 0.4 + 0.6 * f, 0.2))
	end
end

-- ---- The HUD: the hotbar and the health bar
local hud = magic.ui.root:CreateChild("UIElement")
hud.priority = -1
local hud_sig = nil

local function shown()
	return M.slots_own() and not E.editing and P.hands
end

-- The hotbar's box (x, y of its first slot), nil without one
local function hotbar_box()
	local n = hotbar_n()
	if n == 0 or not shown() then
		return nil
	end
	local r = magic.ui.root
	local bottom = TOUCH and M.touch_bar_top and M.touch_bar_top() or r.height
	-- Clear of an app's line of keys at the bottom (Workbench's)
	return math.floor((r.width - n * U) / 2), bottom - U - (TOUCH and 8 or 30), n
end

local function hotbar_at(x, y)
	local x0, y0, n = hotbar_box()
	if not x0 or y < y0 or y >= y0 + U or x < x0 or x >= x0 + n * U then
		return nil
	end
	return math.floor((x - x0) / U) + 1
end

local function my_health()
	local me = P.nodes[P.you]
	if not me then
		return nil
	end
	local hv, mv = me.node:GetVar("kit:hp"), me.node:GetVar("kit:max")
	local hp = hv and not hv:IsEmpty() and tonumber(hv:GetString())
	local max = mv and not mv:IsEmpty() and tonumber(mv:GetString())
	if not hp or not max or max <= 0 then
		return nil
	end
	return hp, max
end

local function draw_hud()
	local r = magic.ui.root
	local hp, max = my_health()
	local health = shown() and S.rules.show_health ~= false and hp ~= nil
	local x0, y0, n = hotbar_box()
	local parts = {tostring(x0), tostring(y0), r.width, r.height,
		tostring(health), tostring(hp), tostring(max), S.held,
		network.write_json(S.slots), M.held_text and M.held_text() or ""}
	local sig = table.concat(parts, ";")
	if sig == hud_sig then
		return
	end
	hud_sig = sig
	hud:RemoveAllChildren()
	z = 0
	hud:SetFixedSize(r.width, r.height)
	if x0 then
		box(hud, x0 - 4, y0 - 4, n * U + 4, U + 4, magic.Color(0, 0, 0, 0.45))
		for i = 1, n do
			local x = x0 + (i - 1) * U
			if i == S.held then
				box(hud, x - 3, y0 - 3, U + 2, U + 2, magic.Color(1, 1, 1, 0.95))
			end
			box(hud, x, y0, U - 4, U - 4, magic.Color(0.2, 0.2, 0.22, 0.85))
			stack(hud, S.slots[i], x + 2, y0 + 2, U - 8)
		end
		local ht = M.held_text and M.held_text() or ""
		if ht ~= "" then
			local t = text(hud, ht:gsub("^ ", ""), 0, 0, 13)
			t:SetPosition(math.floor((r.width - t.width) / 2), y0 - 22)
		end
	end
	if health then
		local w = 200
		local hx = x0 and x0 or math.floor((r.width - w) / 2)
		local hy = (y0 or (r.height - 8)) - (x0 and 44 or 24)
		local f = math.max(0, math.min(1, hp / max))
		box(hud, hx, hy, w, 14, magic.Color(0, 0, 0, 0.55))
		box(hud, hx + 2, hy + 2, (w - 4) * f, 10, magic.Color(0.85, 0.15, 0.15))
		text(hud, string.format("%g/%g", hp, max), hx + w + 6, hy - 1, 12)
	end
	local line = "kit: hud: hotbar " .. (x0 and n .. " slots, held " ..
			S.held .. " " .. (item_of(S.held) ~= "" and item_of(S.held) or
			"(empty)") or "none") .. ", health " .. (health and
			string.format("%g/%g", hp, max) or "none")
	if line ~= S.logged then
		S.logged = line
		log:info(line)
	end
end

-- ---- Holding a slot

local function hold_slot(i)
	i = math.floor(tonumber(i) or 0)
	S.held = i
	M.hands_slot(item_of(i))
	log:info("kit: holds slot " .. i .. " (" .. (item_of(i) ~= "" and
			item_of(i) or "empty") .. ")")
	buildat.send_packet("kit:hold", "#" .. i)
end

-- The next (1) or the one before (-1): through the hotbar, or with none
-- through the slots with items and a hand
function M.pick_slot(step)
	local list = {}
	local n = hotbar_n()
	if n > 0 then
		for i = 1, n do list[#list + 1] = i end
	else
		list[1] = 0
		for i = 1, #S.slots do
			if item_of(i) ~= "" then list[#list + 1] = i end
		end
	end
	local at = 1
	for k, i in ipairs(list) do
		if i == S.held then at = k end
	end
	hold_slot(list[(at - 1 + step) % #list + 1])
end

buildat.sub_packet("kit:slots", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" then
		return
	end
	S.slots = type(d.slots) == "table" and d.slots or {}
	S.rules = type(d.rules) == "table" and d.rules or {}
	S.held = tonumber(d.held) or 0
	if M.slots_own() then
		M.hands_slot(item_of(S.held))
	end
	if M.inventory_redraw then
		M.inventory_redraw()
	end
	local t = {}
	for i, s in ipairs(S.slots) do
		if type(s) == "table" and s.item then
			t[#t + 1] = i .. ":" .. s.item .. " x" .. tostring(s.n)
		end
	end
	log:info("kit: slots: " .. (#t > 0 and table.concat(t, ", ") or "none") ..
			" (held " .. S.held .. ", " .. tostring(S.rules.building) .. ")")
end)

-- ---- The inventory screen
local W = nil -- {el, slots, sel = {where, index, count}}
local want = magic.ui.root:CreateChild("UIElement")
want.visible = false
ui_utils.wants_clicks(want)

local function list_of(where)
	return where == "c" and S.chest and S.chest.slots or S.slots
end

local function close()
	if not W then
		return
	end
	W.el:Remove()
	W = nil
	want.visible = false
	if S.chest then
		S.chest = nil
		buildat.send_packet("kit:inv", '{"op": "close"}')
	end
	log:info("kit: inventory screen closed")
	if O.capture then
		O.capture(true)
	end
end

-- Escape's first: an open screen closed (true)
function M.close_screens()
	if W then
		close()
		return true
	end
	return false
end

local function draw()
	if not W then
		return
	end
	local r = magic.ui.root
	local n = hotbar_n()
	local size = math.floor(tonumber(S.rules.slots) or 0)
	if size <= 0 then
		size = math.max(36, (math.floor(#S.slots / 9) + 1) * 9)
	end
	local cols = math.max(9, n)
	local main = size - n
	local main_rows = math.ceil(math.max(0, main) / cols)
	local csize = S.chest and tonumber(S.chest.size) or 0
	local chest_rows = math.ceil(csize / cols)
	local pad = 12
	local w = cols * U + 2 * pad
	local h = pad * 2 + (chest_rows > 0 and chest_rows * U + 30 or 0) + 22 +
			main_rows * U + (n > 0 and U + 10 or 0)
	W.el:RemoveAllChildren()
	z = 0
	W.el:SetFixedSize(w, h)
	W.el:SetPosition(math.floor((r.width - w) / 2), math.floor((r.height - h) / 2))
	box(W.el, 0, 0, w, h, magic.Color(0.12, 0.13, 0.16, 0.94))
	W.slots = {}
	local function slot(where, i, x, y)
		local sel = W.sel and W.sel.where == where and W.sel.index == i
		if sel then
			box(W.el, x - 3, y - 3, U + 2, U + 2, magic.Color(1, 1, 0.6))
		elseif where == "p" and i == S.held then
			box(W.el, x - 2, y - 2, U, U, magic.Color(1, 1, 1, 0.6))
		end
		box(W.el, x, y, U - 4, U - 4, magic.Color(0.3, 0.31, 0.34))
		stack(W.el, list_of(where)[i], x + 2, y + 2, U - 8)
		W.slots[#W.slots + 1] = {where = where, index = i, x = x, y = y}
	end
	local y = pad
	if chest_rows > 0 then
		text(W.el, tostring(S.chest.name), pad, y, 14)
		y = y + 22
		for i = 1, csize do
			slot("c", i, pad + ((i - 1) % cols) * U,
					y + math.floor((i - 1) / cols) * U)
		end
		y = y + chest_rows * U + 8
	end
	text(W.el, "Inventory", pad, y, 14)
	y = y + 22
	for i = n + 1, size do
		local k = i - n - 1
		slot("p", i, pad + (k % cols) * U, y + math.floor(k / cols) * U)
	end
	y = y + main_rows * U + 10
	for i = 1, n do
		slot("p", i, pad + (i - 1) * U, y)
	end
end
M.inventory_redraw = draw

local function open()
	if W or not M.slots_own() or S.rules.screen ~= true then
		return
	end
	W = {el = magic.ui.root:CreateChild("UIElement")}
	W.el.priority = 100
	want.visible = true
	local input = magic.input
	input:SetMouseVisible(true, "Kit's inventory screen")
	if WEB then
		input:SetMouseMode(magic.MM_ABSOLUTE)
	end
	draw()
	log:info("kit: inventory screen opened (" .. (#W.slots) .. " slots" ..
			(S.chest and ", chest " .. tostring(S.chest.id) or "") .. ")")
end

local function send_move(from, to, n)
	buildat.send_packet("kit:inv", network.write_json({op = "move",
		from = {from.where, from.index}, to = {to.where, to.index}, n = n}))
	log:info(string.format("kit: inventory move %d %s:%d -> %s:%d", n,
			from.where, from.index, to.where, to.index))
end

local function look_dir()
	local cam = O.camera
	local d = cam and cam.worldDirection or magic.Vector3(0, 0, 1)
	return {d.x, d.z}
end

local function drop(slot, n)
	if S.rules.drop_items ~= true or slot < 1 then
		return
	end
	buildat.send_packet("kit:inv", network.write_json({op = "drop", slot = slot,
		n = n, dir = look_dir()}))
	log:info("kit: drops " .. n .. " of slot " .. slot)
end

-- A click at x, y (UI pixels) on the screen ("right": the right button)
local function click(x, y, right)
	if not W then
		return false
	end
	local p = W.el.position
	x, y = x - p.x, y - p.y
	local hit = nil
	for _, sl in ipairs(W.slots) do
		if x >= sl.x and y >= sl.y and x < sl.x + U and y < sl.y + U then
			hit = sl
		end
	end
	local outside = x < 0 or y < 0 or x >= W.el.width or y >= W.el.height
	if outside then
		if W.sel then
			if W.sel.where == "p" then
				drop(W.sel.index, W.sel.count)
			end
			W.sel = nil
			draw()
		else
			close()
		end
		return true
	end
	if not hit then
		W.sel = nil
		draw()
		return true
	end
	local st = list_of(hit.where)[hit.index]
	local n = type(st) == "table" and tonumber(st.n) or 0
	if not W.sel then
		if n > 0 then
			W.sel = {where = hit.where, index = hit.index,
				count = right and math.ceil(n / 2) or n}
		end
	elseif W.sel.where == hit.where and W.sel.index == hit.index then
		W.sel = nil
	else
		send_move(W.sel, hit, right and 1 or W.sel.count)
		if right and W.sel.count > 1 then
			W.sel.count = W.sel.count - 1
		else
			W.sel = nil
		end
	end
	draw()
	return true
end

buildat.sub_packet("kit:chest", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or not d.id then
		if S.chest then
			S.chest = nil
			draw()
		end
		return
	end
	local was = S.chest and S.chest.id
	S.chest = {id = d.id, name = d.name, size = tonumber(d.size) or 0,
		slots = type(d.slots) == "table" and d.slots or {}}
	if not W then
		open()
	else
		draw()
	end
	if was ~= d.id then
		log:info("kit: chest " .. tostring(d.id) .. " open: " ..
				tostring(S.chest.size) .. " slots")
	end
end)

-- ---- Input
local function playing()
	return M.slots_own() and P.hands and not E.editing and
			magic.ui.focusElement == nil
end

magic.SubscribeToEvent("KeyDown", function(_, data)
	local key = data:GetInt("Key")
	if not playing() then
		return
	end
	if M.key("inventory", key) then
		if W then close() else open() end
		return
	end
	if M.key("drop", key) then
		local s = S.slots[S.held]
		local n = magic.input:GetQualifierDown(magic.QUAL_CTRL) and
				type(s) == "table" and tonumber(s.n) or 1
		drop(S.held, n)
		return
	end
	if M.building() ~= "inventory" then
		return
	end
	for i = 1, hotbar_n() do
		if M.key("hotbar" .. i, key) then
			hold_slot(i)
		end
	end
end)

local function press(x, y, right)
	if not playing() then
		return false
	end
	if W then
		return click(x, y, right)
	end
	local i = hotbar_at(x, y)
	if not i then
		return false
	end
	if TOUCH and i == S.held then
		open()
	else
		hold_slot(i)
	end
	return true
end

magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	local b = data:GetInt("Button")
	if TOUCH or (b ~= magic.MOUSEB_LEFT and b ~= magic.MOUSEB_RIGHT) or
			not (W or magic.input.mouseVisible) then
		return
	end
	local mp = magic.input:GetMousePosition()
	press(mp.x, mp.y, b == magic.MOUSEB_RIGHT)
end)

magic.SubscribeToEvent("TouchBegin", function(_, data)
	if TOUCH then
		press(data:GetInt("X"), data:GetInt("Y"), false)
	end
end)

-- The controls leave the hotbar and the screen alone
local ui_at = M.ui_at
function M.ui_at(x, y)
	if W or hotbar_at(x, y) then
		return true
	end
	return ui_at ~= nil and ui_at(x, y)
end

magic.SubscribeToEvent("Update", function()
	if W and (not playing() or not M.slots_own()) then
		close()
	end
	draw_hud()
end)

magic.SubscribeToEvent("command_seq:kit_slot", function(_, data)
	hold_slot(data:GetString("Param"))
end)
magic.SubscribeToEvent("command_seq:kit_inventory", function()
	if W then close() else open() end
end)
magic.SubscribeToEvent("command_seq:kit_drop", function(_, data)
	local s = S.slots[S.held]
	drop(S.held, data:GetString("Param") == "all" and type(s) == "table" and
			tonumber(s.n) or 1)
end)
magic.SubscribeToEvent("command_seq:kit_inv_click", function(_, data)
	local where, i, right = data:GetString("Param"):match(
			"^(%a+) ?(%d*) ?(%a*)$")
	if not W then
		log:info("kit: inventory click: no screen open")
		return
	end
	local p = W.el.position
	if where == "out" then
		click(p.x - 10, p.y - 10, false)
		return
	end
	for _, sl in ipairs(W.slots) do
		if sl.where == where and sl.index == tonumber(i) then
			click(p.x + sl.x + U / 2, p.y + sl.y + U / 2, right == "right")
			return
		end
	end
	log:info("kit: inventory click: no slot " .. tostring(where) .. " " ..
			tostring(i))
end)

end
-- vim: set noet ts=4 sw=4:
