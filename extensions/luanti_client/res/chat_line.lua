-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The line the chat is typed into**: a small window with the field, Send
-- and Cancel, and on a touchscreen a Declutter checkbox. Above the hotbar
-- and the chat log, which are what is at the bottom of the screen; on a
-- touchscreen at the top, out from under the on-screen keyboard, over the
-- chat ([TOUCH_CHAT_CLUTTER]). One copy for both Luanti clients
-- ([VANILLA_CHAT_TOUCH]): luanti_client loads it from its res/, vanilla as
-- luanti/chat_line.lua (serve_shared_lua).
--
-- The field is a LineEdit rather than something built here: editing a
-- line -- the cursor, selection, backspace, paste -- is what Urho3D's own
-- already does. Enter arrives as its TextFinished, because a stack event
-- handler does not fire while it has the focus; Escape as a plain KeyDown
-- subscription, for the same reason.
--
--   line = <this file>(o)
-- o: touch() (whether on a touchscreen, asked at each opening),
-- send(text) for a line not empty, on_open() and on_close() after each,
-- declutter (a touchscreen's: {get = function() -> on, set = function(on)}),
-- page(d), Page Up (-1) or Down (1) while it is up ([SCROLL_PAGE_KEYS])
-- line: open(), close(), is_open(), text() (nil when closed), click(x, y)
-- in UI pixels: whether a box was hit, its action done
local magic = require("buildat/core/urho3d")
local log = buildat.Logger("luanti/chat_line")
local STYLE = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")

return function(o)
	local L = {}
	local window, input, input_cb, key_cb, buttons = nil, nil, nil, nil, nil

	function L.is_open()
		return input ~= nil
	end

	function L.text()
		return input and input:GetText()
	end

	function L.close()
		if not input then
			return
		end
		magic.UnsubscribeFromEvent(input, "TextFinished", input_cb)
		magic.UnsubscribeFromEvent("KeyDown", key_cb)
		input_cb, key_cb = nil, nil
		window:Remove()
		window, input, buttons = nil, nil, nil
		o.on_close()
	end

	local function send()
		local text = input:GetText()
		log:verbose("chat: sending \"" .. text .. "\"")
		L.close()
		if text ~= "" then
			o.send(text)
		end
	end

	function L.open()
		if input then
			return
		end
		local ui_root = magic.ui.root
		local w = math.min(560, ui_root.width - 40)
		local h = 96
		local ox = math.floor((ui_root.width - w) / 2)
		local touch = o.touch()
		local oy = touch and 8 or ui_root.height - h - 180

		-- No texture: a BorderImage without one is drawn in its colour
		window = ui_root:CreateChild("BorderImage")
		-- The style is inherited by everything under it, which is what the
		-- line edit's own text needs to have a font at all
		window.defaultStyle = STYLE
		window.color = magic.Color(0.10, 0.10, 0.13, 0.95)
		window.size = magic.IntVector2(w, h)
		window:SetPosition(ox, oy)
		-- Over the chat and the touch controls (50)
		window.priority = 60
		-- An element Urho3D has not been told is enabled is not hit by a
		-- click, and then no click event carries a position at all
		window.enabled = true

		local caption = window:CreateChild("Text")
		caption:SetStyleAuto()
		caption.text = "Say something (a line starting with / is a command)"
		caption:SetFontSize(12)
		caption:SetPosition(12, 10)
		caption.color = magic.Color(0.8, 0.8, 0.85)

		input = window:CreateChild("LineEdit")
		-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself
		-- ([NEW_WORLD_FORM])
		input.textCopyable = true
		input.textSelectable = true
		input:SetStyleAuto()
		input:SetPosition(12, 30)
		-- size rather than fixedWidth/fixedHeight: the parent has no
		-- layout to size it, and the element stays 0x0
		input.size = magic.IntVector2(w - 24, 26)
		input.enabled = true
		input:SetText("")
		input:SetFocus(true)

		-- The buttons, as boxes with a word in them: what a click landed
		-- on is worked out from the rectangles, the same way a form's
		-- buttons are, rather than from Urho3D's own button events, which
		-- do not reach the sandbox with a position
		buttons = {origin = {ox, oy}, items = {}}
		local bw, bh = 90, 26
		local by = h - bh - 10
		local labels = {{"Send", w - 12 - bw * 2 - 8, send},
				{"Cancel", w - 12 - bw, L.close}}
		-- The Declutter checkbox, a touchscreen's, at the left
		local declutter_text = nil
		local function declutter_label()
			return (o.declutter.get() and "[x]" or "[ ]") .. " Declutter"
		end
		if touch and o.declutter then
			labels[#labels + 1] = {declutter_label(), 12, function()
				o.declutter.set(not o.declutter.get())
				declutter_text.text = declutter_label()
			end, 110}
		end
		for _, b in ipairs(labels) do
			local bw = b[4] or bw
			local box = window:CreateChild("BorderImage")
			box.color = magic.Color(0.30, 0.30, 0.38, 0.95)
			box.size = magic.IntVector2(bw, bh)
			box:SetPosition(b[2], by)
			box.enabled = true
			local t = box:CreateChild("Text")
			t:SetStyleAuto()
			t.text = b[1]
			t:SetFontSize(13)
			t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
			if b[4] then
				declutter_text = t
			end
			buttons.items[#buttons.items + 1] =
					{x = b[2], y = by, w = bw, h = bh, action = b[3]}
		end

		-- Where it is, and Send in window pixels, for a check's tap: what a
		-- check waits for, the rest of the line is for it to read
		local sc = magic.ui.scale
		log:info(string.format("chat: the line opened, y %d to %d of %d; "
				.. "Send at %d, %d in window pixels", oy, oy + h,
				ui_root.height, math.floor((ox + w - 12 - bw * 2 - 8 + bw / 2) * sc + 0.5),
				math.floor((oy + by + bh / 2) * sc + 0.5)))
		input_cb = magic.SubscribeToEvent(input, "TextFinished", send)
		key_cb = magic.SubscribeToEvent("KeyDown", function(_, event_data)
			local key = event_data:GetInt("Key")
			if key == magic.KEY_ESCAPE then
				L.close()
			elseif o.page and (key == magic.KEY_PAGEUP or
					key == magic.KEY_PAGEDOWN) then
				o.page(key == magic.KEY_PAGEUP and -1 or 1)
			end
		end)
		o.on_open()
	end

	function L.click(x, y)
		if not buttons then
			return false
		end
		local lx, ly = x - buttons.origin[1], y - buttons.origin[2]
		for _, b in ipairs(buttons.items) do
			if lx >= b.x and lx < b.x + b.w and ly >= b.y and ly < b.y + b.h then
				log:info("chat: " .. (b.action == send and "Send" or
						b.action == L.close and "Cancel" or "Declutter"))
				b.action()
				return true
			end
		end
		return false
	end

	return L
end
-- vim: set noet ts=4 sw=4:
