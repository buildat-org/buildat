-- Buildat: apps/hillclimb/main/client_lua/touch.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- hillclimb's touch controls ([HC_TOUCH]), on a touchscreen
-- (BUILDAT_TOUCH=1): one stick and three buttons, its own (not
-- luanti_client's touch.lua: Luanti's scheme, and apps do not consume
-- each other). A finger down anywhere but on a button is the stick,
-- centred where it landed; a second finger while one holds it does
-- nothing. Across steers, up is the accelerator in the gear picked by
-- how far, a little down brakes, a lot down reverses (M.map).
--   local touch = run_script_file("main/touch.lua")(o)
-- o: start(), chat(), menu() the buttons' actions; active() whether a
-- finger takes the stick (driving, and no menu or window up); visible()
-- whether the buttons show. touch.input is {accel, brake, steer, gear}
-- (gear nil: unchanged) while the stick is held, else nil.
local magic = require("buildat/extension/urho3d")
local log = buildat.Logger("hillclimb")

-- The ring's radius, HUD pixels: the full push
local R = 65
-- The steps up (first to fourth from the first), the brake's and
-- reverse's down; simplified: the first figures, not tuned by driving
local UP = {0.15, 0.35, 0.55, 0.75}
local BRAKE, REVERSE = -0.15, -0.6
local DEAD = 0.1

-- The stick's x (right) and y (up), each -1..1 -> accel, brake, steer
-- (-1..1), gear (0 reverse, 1..4, nil unchanged)
local function map(x, y)
	local steer = 0
	if math.abs(x) > DEAD then
		steer = (x > 0 and 1 or -1) * (math.abs(x) - DEAD) / (1 - DEAD)
	end
	if y < REVERSE then
		return true, false, steer, 0
	elseif y <= BRAKE then
		return false, true, steer, nil
	elseif y < UP[1] then
		return false, false, steer, nil
	end
	local g = 1
	for i = 2, 4 do
		if y >= UP[i] then g = i end
	end
	return true, false, steer, g
end

do
	local function is(x, y, accel, brake, steer, gear)
		local a, b, s, g = map(x, y)
		assert(a == accel and b == brake and math.abs(s - steer) < 0.01 and
				g == gear, string.format("touch: map(%g, %g) gave %s %s %g %s",
				x, y, tostring(a), tostring(b), s, tostring(g)))
	end
	is(0, 0.25, true, false, 0, 1)
	is(0, 0.9, true, false, 0, 4)
	is(0, -0.3, false, true, 0, nil)
	is(0, -0.8, true, false, 0, 0)
	is(0.5, 0, false, false, 0.44, nil)
	is(-0.05, 0.6, true, false, 0, 3)
end

return function(o)
	local M = {map = map, input = nil}
	local stick = nil -- {id, x0, y0} of the finger holding it
	local buttons = {}

	local function ui_point(x, y)
		local sc, rp = magic.ui.scale, magic.ui.root.position
		return x / sc - rp.x, y / sc - rp.y
	end

	-- The ring, its steps marked across it, and the knob
	local ring = magic.ui.root:CreateChild("BorderImage")
	ring:SetFixedSize(R * 2, R * 2)
	ring.color = magic.Color(1, 1, 1, 0.15)
	ring.priority = 49
	for _, y in ipairs({UP[1], UP[2], UP[3], UP[4], BRAKE, REVERSE}) do
		local m = ring:CreateChild("BorderImage")
		m:SetFixedSize(R, 2)
		m:SetPosition(R / 2, math.floor(R - y * R))
		m.color = magic.Color(1, 1, 1, 0.4)
	end
	ring.visible = false
	local knob = magic.ui.root:CreateChild("BorderImage")
	knob:SetFixedSize(48, 48)
	knob.color = magic.Color(1, 1, 1, 0.4)
	knob.priority = 49
	knob.visible = false

	local STYLE = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	-- A column at the right edge, clear of the HUD's lines at the left
	for i, b in ipairs({{"Start", o.start}, {"Chat", o.chat},
			{"Menu", o.menu}}) do
		local e = magic.ui.root:CreateChild("Button")
		e.defaultStyle = STYLE
		e:SetStyleAuto()
		e:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
		e:SetPosition(-16, 16 + (i - 1) * 56)
		e:SetFixedSize(90, 48)
		e.opacity = 0.7
		-- Never the focus: a focused button took the keys after it
		e:SetFocusMode(magic.FM_NOTFOCUSABLE)
		e.priority = 50
		local t = e:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(b[1])
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		magic.SubscribeToEvent(e, "Released", function()
			log:info("touch: " .. b[1])
			b[2]()
		end)
		buttons[#buttons + 1] = e
	end

	local function over_buttons(ux, uy)
		for _, b in ipairs(buttons) do
			local p, s = b.screenPosition, b.size
			if b.visible and ux >= p.x and uy >= p.y and ux < p.x + s.x and
					uy < p.y + s.y then
				return true
			end
		end
		return false
	end

	local function release()
		stick, M.input = nil, nil
		ring.visible, knob.visible = false, false
	end

	local function move(ux, uy)
		local dx, dy = ux - stick.x0, uy - stick.y0
		local d = math.sqrt(dx * dx + dy * dy)
		local k = d > R and R / d or 1
		local sx, sy = dx * k / R, -dy * k / R
		local accel, brake, steer, gear = map(sx, sy)
		M.input = {accel = accel, brake = brake, steer = steer, gear = gear}
		knob:SetPosition(math.floor(stick.x0 + dx * k - 24),
				math.floor(stick.y0 + dy * k - 24))
	end

	magic.SubscribeToEvent("TouchBegin", function(_, d)
		local ux, uy = ui_point(d:GetInt("X"), d:GetInt("Y"))
		if stick or not o.active() or over_buttons(ux, uy) then
			return
		end
		stick = {id = d:GetInt("TouchID"), x0 = ux, y0 = uy}
		ring:SetPosition(math.floor(ux - R), math.floor(uy - R))
		ring.visible, knob.visible = true, true
		move(ux, uy)
	end)
	magic.SubscribeToEvent("TouchMove", function(_, d)
		if stick and d:GetInt("TouchID") == stick.id then
			move(ui_point(d:GetInt("X"), d:GetInt("Y")))
		end
	end)
	magic.SubscribeToEvent("TouchEnd", function(_, d)
		if stick and d:GetInt("TouchID") == stick.id then
			release()
		end
	end)
	-- A menu or a window opened under a held stick lets it go; the
	-- buttons hide under them
	local shown = true
	magic.SubscribeToEvent("Update", function()
		if stick and not o.active() then
			release()
		end
		local want = o.visible()
		if want ~= shown then
			shown = want
			for _, b in ipairs(buttons) do
				b.visible = want
			end
		end
	end)
	log:info("hillclimb: touch controls on")
	return M
end
-- vim: set noet ts=4 sw=4:
