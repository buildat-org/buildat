-- kit/radar's client part ([KIT_AIRSHIPS]): its contacts top right while
-- this player is within 12 m of it (on its ship)
local magic = require("buildat/extension/urho3d")
local text = nil
local shown = {} -- by radar id: its text as shown

local function line(e)
	local c = e.state.contacts
	return "Radar: " .. ((c == nil or c == "") and "no ships" or tostring(c))
end

return {
	on_update = function(e, dt)
		local near = e:near(12)
		if near and shown[e.id] ~= line(e) then
			if not text then
				text = magic.ui.root:CreateChild("Text")
				text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 16)
				text:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
				text:SetPosition(-12, 74)
				text:SetColor(magic.Color(0.6, 1, 0.6))
			end
			shown[e.id] = line(e)
			text:SetText(shown[e.id])
			text.visible = true
			e:log("radar shown: " .. shown[e.id]:gsub("\n", "; "))
		elseif not near and shown[e.id] then
			shown[e.id] = nil
			if text and next(shown) == nil then
				text.visible = false
			end
		end
	end,
	on_remove = function(e)
		shown[e.id] = nil
		if text and next(shown) == nil then
			text.visible = false
		end
	end,
}
