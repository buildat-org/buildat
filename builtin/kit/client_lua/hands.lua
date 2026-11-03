-- Buildat: builtin/kit/client_lua/hands.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [KIT_TOOLS_1] (stage 7c's first part) The hands: the item types
-- ("kit:item_types"), the hotbar -- this player's items in a line at the
-- bottom, the one held marked; the wheel (first person) and the keys
-- item_next and item_prev (none by default) pick, "kit:hold" tells the
-- server -- and what a held item does: a melee item's hit on a player or
-- an entity with health in its reach (M.hit_pick, play_target's "hit"):
-- the swing at once, here, the hit the server's ("kit:hit"); an item of
-- use kind "use" ("kit:item"). A dig the server says takes time
-- ("kit:digging") is asked again when due while the left button is held
-- (M.on_digging(cb): the app sends it).
-- For a drive: "event kit_hold <item>" ("" a hand), "event kit_hit <id>"
-- ("nearest": the nearest player or entity with health)
return function(K)
local M, E, P = K.M, K.E, K.P
local magic = require("buildat/extension/urho3d")
local network = require("buildat/extension/network")
local log = K.log
local entity_t = K.entity_t

M.item_types = {}
local items = {} -- {name: count}, as the server last sent
local held = ""
local bar = nil
local last_swing = 0
local dig_cbs, digging = {}, nil

buildat.sub_packet("kit:item_types", function(data)
	local t = network.parse_json(data)
	M.item_types = type(t) == "table" and t or {}
	local n = 0
	for _ in pairs(M.item_types) do n = n + 1 end
	log:info("kit: " .. n .. " item types")
end)

-- The held item's sheet (nil: a hand, or no item type)
function M.held_item()
	return held ~= "" and M.item_types[held] or nil, held
end

local function show()
	if not P.hands then
		if bar then bar.visible = false end
		return
	end
	if not bar then
		bar = magic.ui.root:CreateChild("Text")
		bar:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 14)
		bar:SetAlignment(magic.HA_CENTER, magic.VA_BOTTOM)
		bar:SetPosition(0, -64)
	end
	local s = {held == "" and "[hand]" or "hand"}
	local names = {}
	for k in pairs(items) do names[#names + 1] = k end
	table.sort(names)
	for _, k in ipairs(names) do
		local t = k .. (items[k] > 1 and " x" .. items[k] or "")
		s[#s + 1] = k == held and "[" .. t .. "]" or t
	end
	bar:SetText(table.concat(s, "  "))
	bar.visible = not E.editing
end

function M.hold(item)
	item = tostring(item or "")
	if item ~= "" and not items[item] then
		return
	end
	held = item
	log:info("kit: holds " .. (item == "" and "nothing" or item))
	buildat.send_packet("kit:hold", item)
	show()
end

-- The next (step 1) or the one before (-1) of the hand and the items
local function pick(step)
	local list = {""}
	for k in pairs(items) do list[#list + 1] = k end
	table.sort(list)
	local at = 1
	for i, k in ipairs(list) do
		if k == held then at = i end
	end
	M.hold(list[(at - 1 + step) % #list + 1])
end

-- module.lua's kit:items handler tells it
function M.hands_items(t)
	items = {}
	for k, v in pairs(type(t) == "table" and t or {}) do
		items[tostring(k)] = tonumber(v) or 1
	end
	if held ~= "" and not items[held] then
		held = ""
	end
	show()
end

-- The player or entity with health along the ray within the held melee
-- item's reach (from the body, a camera away from it reaching as far
-- past), and how far: nil without a melee item
function M.hit_pick(origin, dir, far)
	local sheet = M.held_item()
	if not sheet or sheet.use ~= "melee" then
		return nil
	end
	local reach = (tonumber(sheet.reach) or 3) + 0.5 + (far or 0)
	local best, bd = nil, nil
	for id, n in pairs(P.nodes) do
		local s = type(n.show) == "table" and n.show or {}
		local t
		if s.player and id ~= P.you then
			-- A body: 1.7 tall from its node's 0.5 down
			local p = n.node.position
			local wx, wy, wz = p.x - origin.x, p.y + 0.35 - origin.y,
					p.z - origin.z
			local tt = wx * dir.x + wy * dir.y + wz * dir.z
			local cx, cy, cz = wx - dir.x * tt, wy - dir.y * tt, wz - dir.z * tt
			if tt > 0 and math.abs(cy) <= 0.9 and
					math.sqrt(cx * cx + cz * cz) <= 0.55 then
				t = tt
			end
		elseif s.health and not s.player then
			t = entity_t(n, origin, dir)
		end
		if t and t <= reach and (not bd or t < bd) then
			best, bd = id, t
		end
	end
	return best, bd
end

-- A melee item's click: the swing here at once (its cooldown kept here
-- too), the hit on id (nil: a swing at nothing) the server's
function M.swing(id)
	local sheet, item = M.held_item()
	if not sheet then
		return false
	end
	local now = buildat.get_time_us()
	if now - last_swing < (tonumber(sheet.cooldown) or 0) * 1000000 then
		return true
	end
	last_swing = now
	-- simplified: the swing is a log line until the first-person item
	-- (7c-2) has a look to move
	log:info("kit: swing " .. item .. (id and " at " .. tostring(id) or ""))
	if id then
		buildat.send_packet("kit:hit", tostring(id))
	end
	return true
end

-- An item of use kind "use": its click, on the entity pointed at (0 none)
function M.use_item(id)
	local sheet, item = M.held_item()
	if not sheet or sheet.use ~= "use" then
		return false
	end
	log:info("kit: uses " .. item .. " on " .. tostring(id or 0))
	buildat.send_packet("kit:item", tostring(id or 0))
	return true
end

function M.on_digging(cb)
	dig_cbs[#dig_cbs + 1] = cb
end

buildat.sub_packet("kit:digging", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or type(d.cell) ~= "table" then
		return
	end
	local wait = tonumber(d.wait) or 0
	digging = {cell = d.cell, due = buildat.get_time_us() + wait * 1000000}
	log:info(string.format("kit: digging (%d,%d,%d): %.2f s",
			d.cell[1] or 0, d.cell[2] or 0, d.cell[3] or 0, wait))
end)

magic.SubscribeToEvent("Update", function()
	if bar and bar.visible == E.editing then
		show()
	end
	if not digging or buildat.get_time_us() < digging.due then
		return
	end
	local c = digging.cell
	digging = nil
	-- simplified: the button held is the dig going on; the pointer moved
	-- off the cell meanwhile still digs it (the server's reach decides)
	if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
		for _, cb in ipairs(dig_cbs) do cb(c) end
	end
end)

magic.SubscribeToEvent("MouseWheel", function(_, data)
	if not P.hands or E.editing or magic.ui.focusElement ~= nil or
			M.camera_mode() ~= "first_person" or M.pointer_free() then
		return
	end
	pick(data:GetInt("Wheel") > 0 and -1 or 1)
end)

magic.SubscribeToEvent("KeyDown", function(_, data)
	local key = data:GetInt("Key")
	if not P.hands or E.editing or magic.ui.focusElement ~= nil then
		return
	end
	if M.key("item_next", key) then
		pick(1)
	elseif M.key("item_prev", key) then
		pick(-1)
	end
end)

magic.SubscribeToEvent("command_seq:kit_hold", function(_, data)
	M.hold(data:GetString("Param"))
end)
magic.SubscribeToEvent("command_seq:kit_hit", function(_, data)
	local id = data:GetString("Param")
	if id == "nearest" then
		local me = P.nodes[P.you] and P.nodes[P.you].node.position
		local bd = nil
		for nid, n in pairs(P.nodes) do
			local s = type(n.show) == "table" and n.show or {}
			if me and nid ~= P.you and (s.player or s.health) then
				local d = (n.node.position - me):Length()
				if not bd or d < bd then
					id, bd = nid, d
				end
			end
		end
	end
	log:info("kit: hit " .. tostring(id))
	buildat.send_packet("kit:hit", tostring(id))
end)
end
-- vim: set noet ts=4 sw=4:
