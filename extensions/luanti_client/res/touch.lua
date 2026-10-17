-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Touch controls** (user, 2026-09-30), official Luanti's
-- (src/gui/touchcontrols.cpp) by its defaults ([TOUCH_PARITY]):
-- - a finger put down in the left third is a stick centred where it
--   landed, analog: how far it is pushed is how fast one walks;
-- - any other finger turns the view;
-- - a tap places or uses, and a finger held still digs, at the finger
--   (touch_interaction_style = tap; aim says where), or the other way
--   round for an item whose touch_interaction says so (short_dig);
-- - Jump and Sneak at the lower right are held;
-- - Menu, Inventory, Chat and More along the top, More opening the rest:
--   drop, fly, fast, noclip, the camera and the minimap;
-- - a tap on the hotbar picks the slot;
-- - on an open form one finger is the left button, its press, its moves
--   and its lift, and a second finger's tap is a right click where the
--   first is (GUIModalMenu::preprocessEvent).
-- One copy for both Luanti clients ([LC_TOUCH]): luanti_client loads it
-- from its res/, vanilla as luanti/touch.lua (serve_shared_lua). The client
-- reads what this holds: held[action] is key_down()'s (the stick's four
-- directions among them), dig is the left button's, yaw and pitch are
-- degrees to turn, taken each frame, stick is {x, y} (right and down,
-- 0..1 long) while a stick is held, and aim is the UI point of the last
-- finger on the world, for a client that points there.
--
-- simplified: a hotbar of more than one row is tapped as one.
--
--   touch = <this file>(o)
-- o: on_key(key), BIND, pause(), place(), set_wield(i), inventory(),
--    chat(), hotbar() -> count, slot_size, margin, form_open(),
--    form_press(x, y), form_move(x, y), form_release(x, y) and
--    form_right(x, y): a finger on an open form, in UI pixels;
--    short_dig() (optional: a short tap digs and a long one places, the
--    wielded item's touch_interaction for what is pointed at), clutter()
--    (optional: the chat's Declutter toggled, -> whether it is on; a
--    "Clutter" button in More, and T.show_clutter(on) for its look),
--    more (optional: {{label, fn}, ...}, buttons of the client's own at
--    the end of More's column). An action of More's that BIND lacks has
--    no button.
local magic = require("buildat/core/urho3d")
local log = buildat.Logger("luanti/touch")

-- How long a finger is held still before it digs, and how far it may move
-- and still be a tap: Luanti's touch_long_tap_delay and
-- touchscreen_threshold, the latter in UI pixels (Luanti's are the
-- screen's, which a phone's density makes about the same)
local LONG_TAP_US = 400000
local THRESHOLD = 20
-- Degrees the view turns for a UI pixel: Luanti's touchscreen_sensitivity
-- (T.sensitivity, 0.2 unless the client sets the player's
-- [TOUCH_LOOK_SETTING]) times its 6, over the display's density, which a
-- UI pixel already is. simplified: Luanti's field of view factor (1 at 72
-- degrees) is not applied.
-- How far the stick is pushed for the full speed: Luanti's button size,
-- 65 at a density of 1
local STICK = 65
local STYLE = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")

return function(o)
	local T = {held = {}, dig = false, yaw = 0, pitch = 0, sensitivity = 0.2}
	local fingers = {}
	local buttons = {}
	local more = nil

	local function screen()
		local sc = magic.ui.scale
		return magic.ui.root.width, magic.ui.root.height, sc
	end

	-- A button of the controls: a label at a corner, `at` its offset from
	-- it in UI pixels; `hold` makes it an action held while pressed
	local function button(text, ha, va, x, y, w, h, on_tap, hold)
		local b = magic.ui.root:CreateChild("Button")
		b.defaultStyle = STYLE
		b:SetStyleAuto()
		b:SetAlignment(ha, va)
		b:SetPosition(x, y)
		b:SetFixedSize(w, h)
		b.opacity = 0.7
		-- Never the focus: a focused button took the keys after it, and
		-- the client's own (T, Escape) went quiet
		b:SetFocusMode(magic.FM_NOTFOCUSABLE)
		-- Under the pause menu and the pages (100), over the HUD
		b.priority = 50
		local t = b:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(text)
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		if hold then
			magic.SubscribeToEvent(b, "Pressed", function()
				T.held[hold] = true
			end)
			magic.SubscribeToEvent(b, "Released", function()
				T.held[hold] = nil
			end)
		else
			magic.SubscribeToEvent(b, "Released", function()
				log:info("touch: " .. text)
				on_tap()
			end)
		end
		buttons[#buttons + 1] = b
		return b
	end

	local function key(action)
		return function()
			local b = o.BIND[action]
			if b and b.key then
				o.on_key(b.key)
			end
		end
	end

	local S = 64
	-- Under the status line and the chat's first lines
	local TOP = 72
	button("Jump", magic.HA_RIGHT, magic.VA_BOTTOM, -16, -96, S * 1.5, S,
			nil, "jump")
	button("Sneak", magic.HA_RIGHT, magic.VA_BOTTOM, -16 - S * 1.5 - 12, -96,
			S * 1.5, S, nil, "sneak")
	local top = {{"Menu", o.pause}, {"Inventory", o.inventory},
		{"Chat", o.chat}}
	local x = -16
	button("More", magic.HA_RIGHT, magic.VA_TOP, x, TOP, 90, 44,
			function()
		if more then
			for _, b in ipairs(more) do
				b.visible = not b.visible
			end
		end
	end)
	x = x - 90 - 8
	for i = #top, 1, -1 do
		local w = #top[i][1] * 10 + 30
		button(top[i][1], magic.HA_RIGHT, magic.VA_TOP, x, TOP, w, 44,
				top[i][2])
		x = x - w - 8
	end
	-- More's column, under it
	more = {}
	local rest = {{"Drop", "drop"}, {"Fly", "fly"}, {"Fast", "fast"},
		{"Noclip", "noclip"}, {"Camera", "camera"}, {"Minimap", "minimap"}}
	-- Clutter: the chat overlay cut down ([TOUCH_CHAT_CLUTTER]), its text
	-- yellow while it is
	local clutter_text = nil
	for i = #rest, 1, -1 do
		if not o.BIND[rest[i][2]] then
			table.remove(rest, i)
		end
	end
	if o.clutter then
		rest[#rest + 1] = {"Clutter", nil, function()
			T.show_clutter(o.clutter())
		end, true}
	end
	for _, r in ipairs(o.more or {}) do
		rest[#rest + 1] = {r[1], nil, r[2]}
	end
	for i, r in ipairs(rest) do
		local b = button(r[1], magic.HA_RIGHT, magic.VA_TOP, -16,
				TOP + i * 52, 90, 44, r[3] or key(r[2]))
		b.visible = false
		more[#more + 1] = b
		if r[4] then
			clutter_text = b:GetChild(0)
		end
	end
	function T.show_clutter(on)
		if clutter_text then
			clutter_text.color = on and magic.Color(1, 0.85, 0.3) or
					magic.Color(1, 1, 1)
		end
	end

	-- The stick's base and knob, where the finger landed
	local base = magic.ui.root:CreateChild("BorderImage")
	base:SetFixedSize(STICK * 2, STICK * 2)
	base.color = magic.Color(1, 1, 1, 0.15)
	base.priority = 49
	base.visible = false
	local knob = magic.ui.root:CreateChild("BorderImage")
	knob:SetFixedSize(48, 48)
	knob.color = magic.Color(1, 1, 1, 0.35)
	knob.priority = 49
	knob.visible = false

	local function over_buttons(ux, uy)
		for _, b in ipairs(buttons) do
			if b.visible then
				local p, s = b.screenPosition, b.size
				if ux >= p.x and uy >= p.y and ux < p.x + s.x and
						uy < p.y + s.y then
					return true
				end
			end
		end
		return false
	end

	-- The hotbar's slot under a point, or nil
	local function hotbar_slot(ux, uy)
		local count, slot, margin = o.hotbar()
		local w, h = screen()
		if uy < h - margin - slot or uy > h then
			return nil
		end
		local left = (w - count * slot) / 2
		local i = math.floor((ux - left) / slot) + 1
		if i >= 1 and i <= count then
			return i
		end
		return nil
	end

	-- Luanti's: nothing within the threshold, the full speed at STICK and
	-- no more past it (virtual_joystick_triggers_aux1 is off)
	local function stick_to(f, ux, uy)
		local dx, dy = ux - f.ux0, uy - f.uy0
		local d = math.sqrt(dx * dx + dy * dy)
		local k = d > THRESHOLD and 1 / math.max(d, STICK) or 0
		T.stick = {x = dx * k, y = dy * k}
		-- The four keys too, for what reads keys (the server's controls,
		-- luanti_client's walk)
		T.held.forward = T.stick.y < -0.3 or nil
		T.held.back = T.stick.y > 0.3 or nil
		T.held.left = T.stick.x < -0.3 or nil
		T.held.right = T.stick.x > 0.3 or nil
		local m = math.min(d, STICK) / math.max(d, 1)
		knob:SetPosition(math.floor(f.ux0 + dx * m - 24),
				math.floor(f.uy0 + dy * m - 24))
	end

	-- A tap's or a long press's action: a place, or a dig as short as a
	-- click (dig_until), or one held while the finger is
	local function tap_action(long, f)
		local short_dig = o.short_dig ~= nil and o.short_dig() == true
		if long == short_dig then
			o.place()
		elseif long then
			f.digging = true
			T.dig = true
		else
			T.dig = true
			T.dig_until = buildat.get_time_us() + 100000
		end
	end

	local function ui_point(x, y)
		local _, _, sc = screen()
		local rp = magic.ui.root.position
		return x / sc - rp.x, y / sc - rp.y
	end

	local on_touchbegin = magic.SubscribeToEvent("TouchBegin", function(_, data)
		local id = data:GetInt("TouchID")
		local ux, uy = ui_point(data:GetInt("X"), data:GetInt("Y"))
		local f = {id = id, ux0 = ux, uy0 = uy, ux = ux, uy = uy,
				t0 = buildat.get_time_us()}
		if o.form_open() then
			-- A form of Luanti's has the finger as the left button: the UI
			-- sends no click of a finger's (UIMouseClick is the mouse's).
			-- One already on it makes this the second, a right click at
			-- the first's point when it lifts.
			for _, g in pairs(fingers) do
				if g.form and not g.second then
					f.second = g
				end
			end
			fingers[id] = f
			f.form = true
			if not f.second then
				o.form_press(ux, uy)
			end
			return
		end
		fingers[id] = f
		if over_buttons(ux, uy) then
			f.ui = true
			return
		end
		local slot = hotbar_slot(ux, uy)
		if slot then
			f.ui = true
			o.set_wield(slot)
			log:info("touch: hotbar slot " .. slot)
			return
		end
		local w, h = screen()
		local stick_taken = false
		for _, g in pairs(fingers) do
			stick_taken = stick_taken or g.stick
		end
		if not stick_taken and ux < w / 3 then
			f.stick = true
			base:SetPosition(math.floor(ux - STICK), math.floor(uy - STICK))
			base.visible, knob.visible = true, true
			stick_to(f, ux, uy)
			return
		end
		f.look = true
		T.aim = {x = ux, y = uy}
	end)

	local on_touchmove = magic.SubscribeToEvent("TouchMove", function(_, data)
		local f = fingers[data:GetInt("TouchID")]
		if not f or f.ui or f.second then
			return
		end
		local ux, uy = ui_point(data:GetInt("X"), data:GetInt("Y"))
		f.ux, f.uy = ux, uy
		if f.form then
			if o.form_open() then
				o.form_move(ux, uy)
			end
			return
		end
		if f.stick then
			stick_to(f, ux, uy)
			return
		end
		local _, _, sc = screen()
		local turn = T.sensitivity * 6
		T.yaw = T.yaw + data:GetInt("DX") / sc * turn
		T.pitch = T.pitch + data:GetInt("DY") / sc * turn
		T.aim = {x = ux, y = uy}
		if (ux - f.ux0) ^ 2 + (uy - f.uy0) ^ 2 > THRESHOLD ^ 2 then
			f.moved = true
		end
	end)

	local on_touchend = magic.SubscribeToEvent("TouchEnd", function(_, data)
		local id = data:GetInt("TouchID")
		local f = fingers[id]
		fingers[id] = nil
		if not f then
			return
		end
		if f.second then
			-- Over the form still, with the first finger still down
			if o.form_open() and fingers[f.second.id] == f.second then
				o.form_right(f.second.ux, f.second.uy)
			end
		elseif f.form then
			if o.form_open() then
				local ux, uy = ui_point(data:GetInt("X"), data:GetInt("Y"))
				o.form_release(ux, uy)
			end
		elseif f.stick then
			T.held.forward, T.held.back = nil, nil
			T.held.left, T.held.right = nil, nil
			T.stick = nil
			base.visible, knob.visible = false, false
		elseif f.look then
			if f.digging then
				T.dig = false
			elseif not f.moved and not f.long and not o.form_open() then
				tap_action(false, f)
			end
		end
		-- A held button whose release was never seen (the finger slid
		-- off it) is let go with the last finger
		if next(fingers) == nil then
			T.held.jump, T.held.sneak = nil, nil
			-- A short tap's dig ends on its own
			T.dig = T.dig_until ~= nil
		end
	end)

	-- A finger held still digs, and goes on digging when it then moves;
	-- the controls hide while a form or the pause menu is up
	local shown = true
	local on_update = magic.SubscribeToEvent("Update", function()
		local now = buildat.get_time_us()
		for _, f in pairs(fingers) do
			if f.look and not f.moved and not f.long and
					now - f.t0 > LONG_TAP_US then
				f.long = true
				tap_action(true, f)
			end
		end
		if T.dig_until and now >= T.dig_until then
			T.dig, T.dig_until = false, nil
		end
		local want = not o.form_open()
		if want ~= shown then
			shown = want
			for _, b in ipairs(buttons) do
				b.visible = want
			end
			-- More's column starts closed again
			for _, b in ipairs(more) do
				b.visible = false
			end
		end
	end)

	-- The controls taken down, for a client whose session ends while it
	-- runs (luanti_client's back to its connect dialog)
	function T.destroy()
		magic.UnsubscribeFromEvent("TouchBegin", on_touchbegin)
		magic.UnsubscribeFromEvent("TouchMove", on_touchmove)
		magic.UnsubscribeFromEvent("TouchEnd", on_touchend)
		magic.UnsubscribeFromEvent("Update", on_update)
		for _, b in ipairs(buttons) do
			b:Remove()
		end
		base:Remove()
		knob:Remove()
	end

	return T
end
-- vim: set noet ts=4 sw=4:
