-- Buildat: apps/demo_skeldat/main/client_lua/ui.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- skeldat's HUD and inventory, skelenti's (apps/demo_skelenti) over the
-- lists main.cpp sends, which init.lua keeps in `game`:
--   local ui = run_script_file("main/ui.lua")(game)
-- The HUD: hearts, bubbles under water, the hotbar and
-- the crosshair. The inventory: the player's own with a 2x2 grid, a
-- crafting table's 3x3 (the same craft list of 9, its corner shown), a
-- furnace's slots, a lantern's coal. A click picks a stack up and the next one puts it
-- down; the right button picks up half and puts down one.
-- simplified: the stack picked up stays drawn in its slot, outlined, until
-- it is put down; no tooltips; the furnace shows no progress.
local magic = require("buildat/extension/urho3d")
local log = buildat.Logger("skeldat")

return function(game)
local M = {}

local function resource_tex(res)
	if not res or not magic.cache:Exists(res) then
		return nil
	end
	local t = magic.cache:GetResource("Texture2D", res)
	if t then
		t.filterMode = magic.FILTER_NEAREST
	end
	return t
end
local function tex(name) return resource_tex("main/" .. name) end

-- Each element over the one before: Urho3D sorts siblings by priority
-- with a sort that is not stable, so past sixteen of one priority a
-- slot's background came out over its item. Reset by each redraw.
local z = 0
local function image(parent, t, x, y, w, h, color)
	local e = parent:CreateChild("BorderImage")
	z = z + 1
	e.priority = z
	e.blendMode = magic.BLEND_ALPHA
	if t then
		e.texture = t
		e.imageRect = magic.IntRect(0, 0, t.width, t.height)
	end
	if color then
		e.color = color
	end
	e:SetPosition(math.floor(x), math.floor(y))
	e:SetFixedSize(math.floor(w), math.floor(h))
	return e
end

local function text(parent, s, x, y, size)
	local t = parent:CreateChild("Text")
	z = z + 1
	t.priority = z
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), size)
	t:SetTextEffect(magic.TE_SHADOW)
	t:SetText(s)
	t:SetPosition(math.floor(x), math.floor(y))
	return t
end

local function scale()
	local r = magic.ui.root
	return math.max(1, math.floor(math.min(r.width / 320, r.height / 220)))
end

-- An item in a 16-pixel square at x, y, its count at the corner
local function draw_stack(parent, str, x, y, s)
	local st = game.parse_stack(str)
	if not st then
		return
	end
	local t = resource_tex(game.item_texture(st.name))
	if t then
		image(parent, t, x, y, 16 * s, 16 * s)
	else
		text(parent, st.name:gsub("^skeldat:", ""):sub(1, 4), x, y, 5 * s)
	end
	if st.count > 1 then
		local c = text(parent, tostring(st.count), 0, 0, 6 * s)
		c:SetPosition(math.floor(x + 17 * s - c.width),
				math.floor(y + 17 * s - c.height))
	end
end

--
-- The HUD
--
local hud = magic.ui.root:CreateChild("UIElement")
hud:SetFixedSize(magic.ui.root.width, magic.ui.root.height)
local hud_drawn = nil

function M.draw_hud()
	local stats = game.stats
	local main = game.inv.main
	local r = magic.ui.root
	local shown = game.hud_visible() and stats.hp > 0
	local sig = table.concat({tostring(shown), stats.hp, stats.breath,
		game.wield, r.width, r.height, table.concat(main, "|", 1,
		math.min(9, #main)), game.item_texture("skeldat:stick") or "",
		tostring(game.held()), game.ended or ""}, ";")
	if sig == hud_drawn then
		return
	end
	hud_drawn = sig
	hud:RemoveAllChildren()
	z = 0
	hud:SetFixedSize(r.width, r.height)
	if not shown then
		return
	end
	local s = scale()
	if game.ended then
		local t = text(hud, game.ended, 0, 8 * s, 8 * s)
		t:SetPosition(math.floor((r.width - t.width) / 2), math.floor(8 * s))
	end
	local x0 = math.floor((r.width - 182 * s) / 2)
	local y0 = r.height - 23 * s
	image(hud, tex("hotbar.png"), x0, y0, 182 * s, 22 * s)
	image(hud, tex("hotbar_selected.png"),
			x0 + (20 * (game.wield - 1) - 1) * s, y0 - s, 24 * s, 24 * s)
	for i = 1, 9 do
		draw_stack(hud, main[i], x0 + (3 + 20 * (i - 1)) * s, y0 + 3 * s, s)
	end
	local heart, bubble = tex("heart.png"), tex("bubble.png")
	for j = 1, 10 do
		local x, y = x0 + 8 * s * (j - 1), y0 - 11 * s
		image(hud, heart, x, y, 9 * s, 9 * s, magic.Color(0.2, 0.2, 0.2, 0.8))
		if stats.hp >= 2 * j then
			image(hud, heart, x, y, 9 * s, 9 * s)
		elseif stats.hp == 2 * j - 1 and heart then
			local half = image(hud, heart, x, y, 5 * s, 9 * s)
			half.imageRect = magic.IntRect(0, 0, 5, 9)
		end
		if stats.breath < stats.breath_max and stats.breath >= j then
			image(hud, bubble, x0 + 182 * s - 9 * s - 8 * s * (j - 1), y,
					9 * s, 9 * s)
		end
	end
	if not game.held() then
		local c = 15 * s
		image(hud, tex("crosshair.png"), (r.width - c) / 2,
				(r.height - c) / 2, c, c)
	end
end

--
-- The inventory
--
local win = nil -- {mode, at, el, slots, sel}

local function lists_of(location)
	if location == "me" then
		return game.inv
	end
	return game.node_inv[location] or {}
end
local function stack_at(slot)
	local l = lists_of(slot.location)[slot.list]
	return l and l[slot.index] or ""
end

local function close()
	if not win then
		return
	end
	win.el:Remove()
	local at = win.at
	win = nil
	game.hold(nil)
	if at then
		game.send("close", "")
	end
	log:info("inventory: closed")
	hud_drawn = nil
end

local function draw()
	if not win then
		return
	end
	local s = scale()
	local u, pad = 18 * s, 8 * s
	local w, h = 9 * u + 2 * pad, 7.5 * u + 2 * pad
	local r = magic.ui.root
	win.el:RemoveAllChildren()
	z = 0
	win.el:SetFixedSize(w, h)
	win.el:SetPosition(math.floor((r.width - w) / 2),
			math.floor((r.height - h) / 2))
	image(win.el, nil, 0, 0, w, h, magic.Color(0.78, 0.78, 0.78, 0.97))
	win.slots = {}
	local function slot(location, list, index, x, y)
		local sl = {location = location, list = list, index = index,
			x = pad + x, y = pad + y}
		local sel = win.sel and win.sel.location == location and
				win.sel.list == list and win.sel.index == index
		if sel then
			image(win.el, nil, sl.x - s, sl.y - s, u, u,
					magic.Color(1, 1, 0.6, 1))
		end
		image(win.el, nil, sl.x, sl.y, u - 2 * s, u - 2 * s,
				magic.Color(0.545, 0.545, 0.545, 1))
		draw_stack(win.el, stack_at(sl), sl.x, sl.y, s)
		win.slots[#win.slots + 1] = sl
		return sl
	end
	local me = "me"
	if win.mode == "furnace" then
		local at = win.at
		slot(at, "src", 1, 2 * u, 0)
		image(win.el, tex("fire_bg.png"), pad + 2 * u, pad + u,
				14 * s, 14 * s)
		slot(at, "fuel", 1, 2 * u, 2 * u)
		image(win.el, tex("arrow_right.png"), pad + 3.5 * u,
				pad + u, 24 * s, 16 * s)
		slot(at, "dst", 1, 6 * u, u)
	elseif win.mode == "lantern" then
		-- Its coal alone ([SKELDAT_FIGHT_BACK])
		image(win.el, tex("fire_bg.png"), pad + 4 * u, pad + 0.2 * u,
				14 * s, 14 * s)
		slot(win.at, "fuel", 1, 4 * u, u)
	else
		local n = win.mode == "table" and 3 or 2
		for row = 0, n - 1 do
			for col = 0, n - 1 do
				slot(me, "craft", row * 3 + col + 1, (1 + col) * u,
						(row + (3 - n) / 2) * u)
			end
		end
		image(win.el, tex("arrow_right.png"), pad + 4.6 * u,
				pad + u * 1.05, 24 * s, 16 * s)
		-- The grid's answer: what the last craft made, else what it would
		local res = game.inv.craftresult
		if res and res[1] and res[1] ~= "" then
			slot(me, "craftresult", 1, 7 * u, u)
		else
			local sl = slot(me, "craftpreview", 1, 7 * u, u)
			sl.craft = true
		end
	end
	for i = 10, 36 do
		slot(me, "main", i, ((i - 10) % 9) * u,
				(3.4 + math.floor((i - 10) / 9)) * u)
	end
	for i = 1, 9 do
		slot(me, "main", i, (i - 1) * u, 6.6 * u)
	end
end

local function click(x, y, button)
	if not win then
		return false
	end
	local p = win.el.position
	x, y = x - p.x, y - p.y
	local u = 18 * scale()
	local hit = nil
	for _, sl in ipairs(win.slots) do
		if x >= sl.x and y >= sl.y and x < sl.x + u and y < sl.y + u then
			hit = sl
		end
	end
	if not hit then
		return true
	end
	local right = button == "right"
	if hit.craft then
		if stack_at(hit) ~= "" then
			game.send("craft", "")
			log:info("inventory: craft " .. stack_at(hit))
			win.sel = {location = hit.location, list = "craftresult",
				index = 1, count = 0}
		end
	elseif not win.sel then
		local st = game.parse_stack(stack_at(hit))
		if st then
			win.sel = {location = hit.location, list = hit.list,
				index = hit.index,
				count = right and math.ceil(st.count / 2) or st.count}
		end
	elseif win.sel.location == hit.location and win.sel.list == hit.list and
			win.sel.index == hit.index then
		win.sel = nil
	else
		local from = win.sel
		local st = game.parse_stack(stack_at(from))
		local count = right and 1 or (from.count > 0 and from.count or
				st and st.count or 0)
		if count > 0 then
			game.send("move", string.format("%d %s %s %d %s %s %d", count,
					from.location, from.list, from.index, hit.location,
					hit.list, hit.index))
			log:info(string.format("inventory: move %d %s %s:%d -> %s:%d",
					count, st and st.name or "?", from.list, from.index,
					hit.list, hit.index))
		end
		if right and st and st.count > 1 then
			from.count = math.max(0, from.count - 1)
		else
			win.sel = nil
		end
	end
	draw()
	return true
end

-- mode: "inventory", "table", "furnace" or "lantern"; at: the node's
-- "x,y,z"
function M.open(mode, at)
	if win then
		local same = win.mode == mode and win.at == at
		close()
		if same then
			return
		end
	end
	win = {mode = mode, at = at, el = magic.ui.root:CreateChild("UIElement")}
	draw()
	game.hold(close, win.el, false, {click = click, key = function(key)
		-- The inventory key closes it, as it opened it
		if key == game.key.inventory then
			close()
			return true
		end
		return false
	end})
	hud_drawn = nil
	log:info("inventory: " .. mode .. " opened" .. (at and " at " .. at or ""))
end

table.insert(game.listeners, function() hud_drawn = nil; draw() end)

-- For a drive: the open window's slots, where each is on the screen
function M.slots()
	if not win then
		return nil
	end
	local out = {}
	local p, h = win.el.position, 9 * scale()
	for _, sl in ipairs(win.slots) do
		out[#out + 1] = {list = sl.list, index = sl.index, x = p.x + sl.x + h,
			y = p.y + sl.y + h, stack = stack_at(sl)}
	end
	return out
end

return M
end
-- vim: set noet ts=4 sw=4:
