-- kit/wallet's client part ([KIT_AIRSHIPS]): this player's own money on
-- their screen, top left under the score, and the last note under it
local magic = require("buildat/extension/urho3d")
local text = nil

return {
	on_state = function(e, key)
		if not e.mine or (key ~= "money" and key ~= "note") then
			return
		end
		if not text then
			text = magic.ui.root:CreateChild("Text")
			text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 18)
			text:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
			text:SetPosition(12, 74)
		end
		local m = tonumber(e.state.money) or 0
		local note = tostring(e.state.note or ""):gsub("^%d+:", "")
		text:SetText("Money: " .. m .. (note ~= "" and "\n" .. note or ""))
		if key == "money" then
			e:log("your money " .. m)
		else
			e:log("wallet note: " .. note)
		end
	end,
}
