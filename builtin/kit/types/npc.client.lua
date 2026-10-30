-- kit/npc's client part ([KIT] stage 4d): a line the NPC says is a
-- dialog at the bottom of the screen of each player near it, for a few
-- seconds
local magic = require("buildat/extension/urho3d")
local SHOW_S, NEAR = 5, 8
local box, till = nil, 0

return {
	on_state = function(e, key)
		if key ~= "line" then
			return
		end
		-- Its line as this client first sees it is no new one
		if not e.heard then
			e.heard = true
			return
		end
		if not e:near(NEAR) or tostring(e.state.line or "") == "" then
			return
		end
		if box then
			box:Remove()
		end
		if not magic.ui.root.defaultStyle then
			magic.ui.root.defaultStyle = magic.cache:GetResource("XMLFile",
					"ui_utils/res/style.xml")
		end
		box = magic.ui.root:CreateChild("Window")
		box:SetStyleAuto()
		box:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(12, 8, 12, 8))
		box:SetAlignment(magic.HA_CENTER, magic.VA_BOTTOM)
		box:SetPosition(0, -60)
		box.opacity = 0.9
		local t = box:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(tostring(e.state.line))
		till = buildat.get_time_us() + SHOW_S * 1000000
		e:log("dialog: " .. tostring(e.state.line))
	end,
	on_update = function(e)
		if box and buildat.get_time_us() > till then
			box:Remove()
			box = nil
		end
	end,
}
