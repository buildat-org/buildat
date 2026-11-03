-- kit/health's client part ([KIT_TOOLS_1]): this player's own health on
-- their screen, a bar bottom left, while it is under max
-- simplified: a text bar; a drawn one comes with the HUD's look
local magic = require("buildat/extension/urho3d")
local text = nil

return {
	on_state = function(e, key)
		if not e.mine or (key ~= "hp" and key ~= "max") then
			return
		end
		if not text then
			text = magic.ui.root:CreateChild("Text")
			text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 18)
			text:SetAlignment(magic.HA_LEFT, magic.VA_BOTTOM)
			text:SetPosition(12, -60)
			text:SetColor(magic.Color(1, 0.35, 0.35))
		end
		local hp, max = tonumber(e.state.hp) or 0, tonumber(e.state.max) or 1
		local n = math.floor(20 * math.max(0, math.min(1, hp / max)) + 0.5)
		local s = string.format("%g/%g", hp, max)
		text:SetText(hp < max and "[" .. string.rep("#", n) ..
				string.rep(".", 20 - n) .. "] " .. s or "")
		e:log("your health " .. s)
	end,
}
