-- kit/health's client part ([KIT_TOOLS_1]): this player's own health,
-- logged as it changes; [KIT_HUD] Kit's HUD (client_lua/inventory.lua)
-- draws it as a bar by kit/game_rules' show_health
return {
	on_state = function(e, key)
		if not e.mine or (key ~= "hp" and key ~= "max") then
			return
		end
		local hp, max = tonumber(e.state.hp) or 0, tonumber(e.state.max) or 1
		e:log(string.format("your health %g/%g", hp, max))
	end,
}
