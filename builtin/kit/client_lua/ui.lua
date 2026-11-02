-- Buildat: builtin/kit/client_lua/ui.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_UI_COMPONENTS] (stage 4m) UI as screen-space components: an
-- entity whose type has a `ui` (builtin/kit/api.h; kit/ui_text, ui_bar,
-- ui_button, ui_panel) is drawn on this player's screen from its node's
-- "kit_show" ui (its parameters) and its state: `shown` and `value`,
-- everyone's, under this player's own ("own", a per_player state the
-- server sends only to them, "kit:mine"). module.lua runs it after the
-- editor and the controls.
--   **Layout**: `anchor` (top_left, top, top_right, left, center, right,
--   bottom_left, bottom, bottom_right) and x, y UI units in from it (from
--   the centre: right and down), in the UI root (the client's UI fit
--   scales it) or in its `panel`'s box; kept inside the box it is in (a
--   text wraps to it, a panel no bigger than it), so nothing goes off a
--   narrow screen. On a touchscreen a bottom anchor is above Kit's touch
--   bars (kit.touch_bar_top()).
--   **Play**: shown while the server is Running and this player is out of
--   the tools (Stopped, the components do not run: none shown); a button's press is the action's (kit.press_action) or
--   "kit:ui" "<id> 1|0", the server checking it is on this player's
--   screen; while a panel with a button is up the pointer is free
--   (ui_utils.wants_clicks) for a player in mouse look.
--   **Edit mode**: every one drawn where it would be (one hidden dimmed),
--   framed (the selected one in kit.HOVER) with its id; a click selects
--   it, a drag moves it (its x and y set, one edit each).
-- The text a builder wrote is drawn as plain text (a Text element: no
-- markup), its {value} the signal's value cut at 200 characters.
--   kit.ui_at(x, y) -> whether the pointer (pixels) is on a UI component
--     that takes clicks (a button or a panel in play; any in edit mode),
--     which the controls and the editor leave alone
return function(K)
local M, E, P = K.M, K.E, K.P
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = K.log
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"
local WEB = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
local FONT = buildat.font_sans

-- id -> {kind, raw (its ui's JSON), ui, el, t, fill, edge, parent, log}
local U = {}
-- [id][key] = this player's own of a per_player state
local mine = {}
-- Up while a panel with a button is (the pointer freed): an element of
-- its own, so edit mode's overlay never counts
local want = magic.ui.root:CreateChild("UIElement")
want.visible = false
ui_utils.wants_clicks(want)
local drag = nil
local bars_at = nil

buildat.sub_packet("kit:mine", function(data)
	local m = network.parse_json(data)
	if type(m) ~= "table" then
		return
	end
	if m.all then
		mine = {}
	end
	for _, o in ipairs(type(m.list) == "table" and m.list or {}) do
		local id = tonumber(o.id)
		if id and type(o.key) == "string" then
			mine[id] = mine[id] or {}
			mine[id][o.key] = o.value
		end
	end
end)

local function color(hex, fallback)
	local r, g, b = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)$")
	if not r then
		return fallback
	end
	return magic.Color(tonumber(r, 16) / 255, tonumber(g, 16) / 255,
			tonumber(b, 16) / 255)
end

local function num(v, d, lo, hi)
	v = tonumber(v) or d
	return math.max(lo, math.min(hi, v))
end

-- The state as this player sees it: theirs over everyone's
local function state(n, id, key)
	local own = mine[id] and mine[id].own
	if type(own) == "table" and own[key] ~= nil then
		return own[key]
	end
	local v = n.node:GetVar("kit:" .. key)
	if v:IsEmpty() then
		return nil
	end
	return network.parse_json(v:GetString())
end

local function shown_text(s, value)
	local v = value
	if type(v) == "table" then
		v = network.write_json(v)
	end
	v = tostring(v == nil and "" or v):sub(1, 200)
	s = tostring(s or ""):gsub("{value}", function() return v end)
	return M.key_text((s:gsub("|", "\n")))
end

local function drop(r)
	if r.el then
		pcall(function() r.el:Remove() end)
	end
	r.el, r.t, r.fill, r.edge = nil, nil, nil, nil
end

local function make(r, id, parent)
	local u, el = r.ui, nil
	if u.kind == "button" then
		el = parent:CreateChild("Button")
		el.defaultStyle = K.STYLE
		el:SetStyleAuto()
		magic.SubscribeToEvent(el, "Pressed", function()
			r.press(true)
		end)
		magic.SubscribeToEvent(el, "Released", function()
			r.press(false)
		end)
	else
		el = parent:CreateChild("BorderImage")
	end
	-- Under the editor's panels (-1); a panel over the rest
	el.priority = u.kind == "panel" and -2 or -3
	el.bringToFront = false
	r.el, r.wrap = el, nil
	if u.kind == "bar" then
		el.color = magic.Color(0.1, 0.1, 0.12)
		r.fill = el:CreateChild("BorderImage")
		r.fill:SetPosition(2, 2)
	end
	r.t = el:CreateChild("Text")
	r.t:SetFont(magic.cache:GetResource("Font", FONT), math.floor(num(u.size,
			u.kind == "panel" and 16 or 15, 8, 64)))
	r.t:SetTextEffect(magic.TE_SHADOW)
	if u.kind == "text" then
		r.t:SetColor(color(u.color, magic.Color(1, 1, 1)))
		local bg = color(u.background, nil)
		el.color = bg or magic.Color(0, 0, 0, 0)
		el.opacity = bg and 0.85 or 1
	elseif u.kind == "panel" then
		el.color = color(u.color, magic.Color(0.13, 0.19, 0.25))
		el.opacity = 0.92
	end
	-- Edit mode's frame: four bars
	r.edge = {}
	for i = 1, 4 do
		local b = el:CreateChild("BorderImage")
		b.priority = 10
		b.visible = false
		r.edge[i] = b
	end
	el.enabled = true
	r.press = function(down)
		if E.editing then
			return
		end
		local a = tostring(u.action or "")
		if a ~= "" then
			M.press_action(a, down)
		else
			buildat.send_packet("kit:ui", id .. (down and " 1" or " 0"))
		end
		if down then
			log:info("kit: ui button " .. id .. " pressed" ..
					(a ~= "" and " (action " .. a .. ")" or ""))
		end
	end
end

-- Where an element of w x h goes in a box of pw x ph by its anchor and
-- x, y: kept in the box. lift: the bottom's room taken (touch bars)
local function place(u, w, h, pw, ph, lift)
	local a = tostring(u.anchor or "top_left")
	local x, y = num(u.x, 0, -4000, 4000), num(u.y, 0, -4000, 4000)
	local px, py
	if a:find("left") then
		px = x
	elseif a:find("right") then
		px = pw - w - x
	else
		px = (pw - w) / 2 + x
	end
	if a:find("top") then
		py = y
	elseif a:find("bottom") then
		py = ph - h - y
		if lift > 0 then
			py = math.min(py, ph - lift - h - 4)
		end
	else
		py = (ph - h) / 2 + y
	end
	px = math.max(0, math.min(pw - w, px))
	py = math.max(0, math.min(ph - h, py))
	return math.floor(px), math.floor(py)
end

-- What x, y put it at px, py (a drag's end).
-- simplified: a bottom one as if no touch bars lifted it
local function from_place(u, w, h, pw, ph, px, py)
	local a = tostring(u.anchor or "top_left")
	local x, y
	if a:find("left") then
		x = px
	elseif a:find("right") then
		x = pw - w - px
	else
		x = px - (pw - w) / 2
	end
	if a:find("top") then
		y = py
	elseif a:find("bottom") then
		y = ph - h - py
	else
		y = py - (ph - h) / 2
	end
	return math.floor(x + 0.5), math.floor(y + 0.5)
end

local function panel_of(r)
	local p = tonumber(r.ui.panel) or 0
	return p >= 1 and math.floor(p) or nil
end

local function update()
	local root = magic.ui.root
	local play = E.running and not E.editing
	-- The ones there now; a panel before what is in it
	local list = {}
	for id, n in pairs(P.nodes) do
		local raw = n.show_raw
		local show = type(n.show) == "table" and n.show or nil
		if show and type(show.ui) == "table" then
			local r = U[id]
			if not r or r.raw ~= raw or r.node ~= n.node then
				if r then
					drop(r)
				end
				r = {raw = raw, ui = show.ui, kind = tostring(show.ui.kind),
					node = n.node, comp = tonumber(show.ui.comp) or 0}
				U[id] = r
			end
			r.n, r.seen = n, true
			list[#list + 1] = id
		end
	end
	for id, r in pairs(U) do
		if not r.seen then
			drop(r)
			U[id] = nil
		end
		r.seen = nil
	end
	local function depth(id)
		local d, r = 0, U[id]
		while r and panel_of(r) and d < 8 do
			d = d + 1
			r = U[panel_of(r)]
		end
		return d
	end
	table.sort(list, function(a, b)
		local da, db = depth(a), depth(b)
		if da ~= db then
			return da < db
		end
		return a < b
	end)
	local lift = 0
	if TOUCH and M.touch_bar_top then
		local top = M.touch_bar_top()
		lift = top and math.max(0, root.height - top) or 0
		-- simplified: the whole width's bottom, though the bars are at
		-- the lower right only; the bars' own rectangle is the upgrade
		if top ~= bars_at then
			bars_at = top
			log:info("kit: ui touch bars at y " .. tostring(top))
		end
	end
	local sel = M.selected and M.selected() or nil
	local wants = false
	for _, id in ipairs(list) do
		local r = U[id]
		local u = r.ui
		local pid = panel_of(r)
		local pr = pid and U[pid] or nil
		-- In a panel only while it is drawn
		local parent = root
		if pid then
			parent = pr and pr.kind == "panel" and pr.el or nil
		end
		-- (its panel's element, the same object while it is there; the
		-- root's wrapper is a new one each time it is read)
		local key = pid and parent or false
		if r.el and r.pkey ~= key then
			drop(r)
		end
		if parent and not r.el then
			make(r, id, parent)
			r.pkey = key
		end
		if r.el then
			local shown = state(r.n, id, "shown") == true
			local value = state(r.n, id, "value")
			r.on = shown and (not pr or pr.on)
			local pw = parent == root and root.width or parent.width
			local ph = parent == root and root.height or parent.height
			local top = 0
			if parent ~= root then
				-- Under its panel's title, inside its edge
				top = pr.title_h or 0
				pw, ph = pw - 12, ph - 12 - top
			end
			local text = shown_text(u.text, value)
			if u.kind == "button" and text == "" and tostring(u.action or "")
					~= "" then
				for _, a in ipairs(M.world_actions()) do
					if a.name == u.action then
						text = a.label ~= "" and a.label or a.name
					end
				end
			end
			-- Its natural width, wrapped to the box past it
			if r.wrap ~= text .. "|" .. pw then
				r.wrap = text .. "|" .. pw
				r.t:SetWordwrap(false)
				r.t.text = ""
				r.t.text = text
				-- (its minWidth: its width read 0 a frame after)
				r.tw = r.t.minWidth
				if u.kind ~= "panel" and r.tw > pw - 12 then
					r.t:SetWordwrap(true)
					r.tw = math.max(8, pw - 12)
				end
			end
			r.t.width = r.tw
			local w, h
			if u.kind == "panel" then
				w = math.min(num(u.width, 320, 40, 4000), pw)
				h = math.min(num(u.height, 160, 30, 4000), ph)
				r.t:SetPosition(8, 6)
				r.title_h = text ~= "" and r.t.height + 8 or 0
			else
				w = math.min(pw, math.max(r.tw + 12, u.kind ~= "text" and
						num(u.width, 0, 0, 4000) or 0))
				h = r.t.height + (u.kind == "text" and 4 or 10)
				if u.kind == "bar" then
					h = math.max(h, 22)
				elseif u.kind == "button" then
					h = math.max(h, TOUCH and 36 or 26)
				end
				r.t:SetPosition(math.floor((w - r.tw) / 2),
						math.floor((h - r.t.height) / 2))
			end
			local x, y = place(u, w, h, pw, ph, parent == root and lift or 0)
			if parent ~= root then
				x, y = x + 6, y + 6 + top
			end
			r.from_place = function(px, py)
				if parent ~= root then
					px, py = px - 6, py - 6 - top
				end
				return from_place(u, w, h, pw, ph, px, py)
			end
			if drag and drag.id == id and drag.at then
				x, y = drag.at[1], drag.at[2]
			end
			r.el:SetPosition(x, y)
			r.el:SetFixedSize(math.floor(w), math.floor(h))
			if r.fill then
				local lo, hi = tonumber(u.min) or 0, tonumber(u.max) or 100
				local f = hi ~= lo and ((tonumber(value) or lo) - lo) / (hi - lo)
						or 0
				f = math.max(0, math.min(1, f))
				r.fill.color = color(u.color, magic.Color(0.8, 0.25, 0.25))
				r.fill:SetFixedSize(math.max(0, math.floor((w - 4) * f)), h - 4)
				r.fill.visible = f > 0
				r.frac = f
			end
			-- Play: as its state says; edit mode: all, a hidden one dimmed,
			-- framed
			r.el.visible = (play and r.on) or E.editing
			r.el.enabled = E.editing or r.kind ~= "text"
			if E.editing then
				r.el.opacity = r.on and 0.95 or 0.45
			elseif r.kind == "panel" or (r.kind == "text" and
					color(u.background, nil)) then
				r.el.opacity = r.kind == "panel" and 0.92 or 0.85
			else
				r.el.opacity = 1
			end
			local col = sel == id and M.HOVER or magic.Color(0.8, 0.8, 0.8)
			local bars = {{0, 0, w, 1}, {0, h - 1, w, 1}, {0, 0, 1, h},
				{w - 1, 0, 1, h}}
			for i, b in ipairs(r.edge) do
				b.visible = E.editing
				if E.editing then
					b.color = col
					b:SetPosition(bars[i][1], bars[i][2])
					b:SetFixedSize(math.max(1, math.floor(bars[i][3])),
							math.max(1, math.floor(bars[i][4])))
				end
			end
			if play and r.on and r.kind == "panel" then
				for _, o in pairs(U) do
					if o.kind == "button" and panel_of(o) == id then
						wants = true
					end
				end
			end
			-- Said as it changes: where it is and what it shows
			local sw, sh = root.width, root.height
			local sp = r.el.screenPosition
			local line = string.format("kit: ui %d %s at %d,%d %dx%d in %dx%d" ..
					" %s%s%s: \"%s\"", id, r.kind, sp.x, sp.y, w, h, sw, sh,
					r.el.visible and "shown" or "hidden",
					E.editing and (r.on and ", edit mode" or
					", edit mode, hidden in play") or "",
					r.frac and string.format(", %.2f full", r.frac) or "",
					text:gsub("\n", " | "))
			if line ~= r.log then
				r.log = line
				local off = sp.x < 0 or sp.y < 0 or sp.x + w > sw or
						sp.y + h > sh
				log:info(line .. (off and " OFF SCREEN" or ""))
			end
		end
	end
	-- A panel with a button up: the pointer this player's to click with
	-- (as builtin/accounts' Server window frees it); ui_utils' mouse look
	-- takes it back after
	if wants and not want.visible then
		local input = magic.input
		if not input.mouseVisible or (WEB and input:IsMouseLocked()) then
			input:SetMouseVisible(true, "a Kit panel with a button")
			if WEB then
				input:SetMouseMode(magic.MM_ABSOLUTE)
			end
			log:info("kit: ui: the pointer freed for a panel's button")
		end
	end
	want.visible = wants
end
magic.SubscribeToEvent("Update", function()
	local ok, err = pcall(update)
	if not ok then
		log:warning("kit: ui: " .. tostring(err))
	end
end)

-- For a drive: "event kit_ui_flood <id> <n>" sends n presses and releases
-- of a UI button at once, as a misbehaving client would
magic.SubscribeToEvent("command_seq:kit_ui_flood", function(_, data)
	local id, n = data:GetString("Param"):match("^(%d+) (%d+)$")
	log:info("kit: flooding " .. tostring(n) .. " presses of ui " ..
			tostring(id))
	for _ = 1, math.min(tonumber(n) or 0, 100000) do
		buildat.send_packet("kit:ui", id .. " 1")
		buildat.send_packet("kit:ui", id .. " 0")
	end
end)

-- The one at x, y (pixels): the innermost, of those the smallest
local own_check = false
local function hit(x, y)
	if own_check then
		return nil
	end
	local sc = magic.ui.scale
	x, y = x / sc, y / sc
	local best, area = nil, nil
	for id, r in pairs(U) do
		if r.el and r.el.visible and (E.editing or r.kind ~= "text") then
			local ok, a = pcall(function()
				local p, s = r.el.screenPosition, r.el.size
				return x >= p.x and y >= p.y and x < p.x + s.x and
						y < p.y + s.y and s.x * s.y
			end)
			if ok and a and (not area or a < area) then
				best, area = id, a
			end
		end
	end
	return best
end

function M.ui_at(x, y)
	return hit(x, y) ~= nil
end

-- Edit mode: a press on one selects it, a drag moves it (the mouse's or a
-- finger's), unless the editor's own panels are over it there
local function press(x, y)
	if not E.editing then
		return
	end
	own_check = true
	local over = M.over_ui and M.over_ui(x, y)
	own_check = false
	local id = not over and hit(x, y)
	local r = id and U[id]
	if not r then
		return
	end
	if M.select then
		M.select(id)
	end
	drag = {id = id, x0 = x, y0 = y, px = r.el.position.x,
		py = r.el.position.y}
end
local function move(x, y)
	if not drag or not E.editing then
		return
	end
	local sc = magic.ui.scale
	local dx, dy = (x - drag.x0) / sc, (y - drag.y0) / sc
	if drag.at or math.abs(dx) + math.abs(dy) > 4 then
		drag.at = {math.floor(drag.px + dx), math.floor(drag.py + dy)}
	end
end
local function release()
	local d = drag
	drag = nil
	local r = d and U[d.id]
	if not r or not d.at or not E.editing or not r.from_place then
		return
	end
	-- Back from the place to x and y from its anchor.
	-- simplified: two edits, two undos; an op setting several parameters
	-- at once is the upgrade
	local ox, oy = r.from_place(d.at[1], d.at[2])
	log:info("kit: ui " .. d.id .. " dragged to " .. ox .. ", " .. oy)
	K.send({op = "set", id = d.id, comp = r.comp, param = "x", value = ox})
	K.send({op = "set", id = d.id, comp = r.comp, param = "y", value = oy})
end
magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	if data:GetInt("Button") == magic.MOUSEB_LEFT and not TOUCH then
		local mp = magic.input:GetMousePosition()
		press(mp.x, mp.y)
	end
end)
magic.SubscribeToEvent("MouseMove", function(_, data)
	if not TOUCH then
		move(data:GetInt("X"), data:GetInt("Y"))
	end
end)
magic.SubscribeToEvent("MouseButtonUp", function(_, data)
	if data:GetInt("Button") == magic.MOUSEB_LEFT and not TOUCH then
		local mp = magic.input:GetMousePosition()
		move(mp.x, mp.y)
		release()
	end
end)
if TOUCH then
	local finger = nil
	magic.SubscribeToEvent("TouchBegin", function(_, data)
		if not finger then
			finger = data:GetInt("TouchID")
			press(data:GetInt("X"), data:GetInt("Y"))
		end
	end)
	magic.SubscribeToEvent("TouchMove", function(_, data)
		if data:GetInt("TouchID") == finger then
			move(data:GetInt("X"), data:GetInt("Y"))
		end
	end)
	magic.SubscribeToEvent("TouchEnd", function(_, data)
		if data:GetInt("TouchID") == finger then
			finger = nil
			release()
		end
	end)
end
end
-- vim: set noet ts=4 sw=4:
