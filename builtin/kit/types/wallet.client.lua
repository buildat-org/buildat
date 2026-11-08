-- kit/wallet's client part ([KIT_AIRSHIPS]): this player's own money on
-- their screen, top left under the score, and the last note under it
local magic = require("buildat/extension/urho3d")
local text = nil

return {
	on_state = function(e, key)
		if not e.mine or (key ~= "money" and key ~= "note" and key ~= "part" and
				key ~= "free") then
			return
		end
		-- Every player has a wallet: nothing shown until it is used (a
		-- game without money shows no "Money: 0")
		if not text and (tonumber(e.state.money) or 0) == 0 and
				tostring(e.state.part or "") == "" and e.state.free ~= true and
				tostring(e.state.note or ""):gsub("^%d+:", "") == "" then
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
		-- [KIT_AIRSHIPS] a part held to put on a ship
		local part = tostring(e.state.part or "")
		local held = part:gsub("^.*/", ""):gsub("^airship_", ""):gsub("_", " ")
		-- [KIT_AIRSHIPS_2] free purchases out of a round
		local free = e.state.free == true
		-- [KIT_WALLET_NOTE_OVERLAP] wrapped before the top centre, where a
		-- kit/arena's status is (400 wide at most)
		-- simplified: the width when the text changes, not on a resize; a
		-- screen under 824 wide still wraps at 200 and may reach under it
		text:SetWordwrap(true)
		text.width = math.max(200, math.floor(magic.ui.root.width / 2) - 200 - 12)
		text:SetText("Money: " .. (free and "free" or m) ..
				(part ~= "" and "\nHolding: " .. held ..
				" (right click a face of your ship)" or "") ..
				(note ~= "" and "\n" .. note or ""))
		if key == "part" then
			e:log("holding part " .. part)
		elseif key == "money" then
			e:log("your money " .. m)
		elseif key == "free" then
			e:log(free and "purchases free" or "purchases paid")
		else
			e:log("wallet note: " .. note)
		end
	end,
}
