-- kit/score's client part ([KIT] stage 4d): this player's own score on
-- their screen, top left, while it is not 0
local magic = require("buildat/extension/urho3d")
local text = nil

return {
	on_state = function(e, key)
		if not e.mine or key ~= "score" then
			return
		end
		if not text then
			text = magic.ui.root:CreateChild("Text")
			text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 18)
			text:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
			text:SetPosition(12, 50)
		end
		local s = tonumber(e.state.score) or 0
		text:SetText(s ~= 0 and "Your score: " .. s or "")
		e:log("your score " .. s)
	end,
}
