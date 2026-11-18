-- Brimstone Speedway's race on this client: the left mouse button is the
-- fire key too (the race's action "fire" pressed and let go as the button
-- is), not while a screen of Kit's UI has the keys
local magic = require("buildat/extension/urho3d")
local kit = require("buildat/module/kit")
local held = false

return {
	on_update = function(e, dt)
		local down = magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) and
				not (kit.ui_keys and kit.ui_keys()) and true or false
		if down ~= held then
			held = down
			kit.press_action("fire", down)
		end
	end,
}
