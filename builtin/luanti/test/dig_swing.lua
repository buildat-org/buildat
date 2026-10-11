-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [DIG_SWING_SOUND]: the stage for dig_swing.sh. A floor of obsidian,
-- which neither the hand nor the pickaxe digs in a hold, with the player
-- on it; "swing <stone|dirt>" in chat puts that node one ahead of
-- them, where looking diagonally down points, and a pickaxe or nothing in
-- their hand. VoxeLibre's nodes name their dig sounds; minetest_game's
-- are "__group".
local ORIGIN = {x = 8, y = 10, z = 8}
local GAMES = {
	{stone = "mcl_core:stone", dirt = "mcl_core:dirt", pick = "mcl_tools:pick_iron",
		floor = "mcl_core:obsidian"},
	{stone = "default:stone", dirt = "default:dirt", pick = "default:pick_steel",
		floor = "default:obsidian"},
}
local function names()
	for _, g in ipairs(GAMES) do
		if core.registered_nodes[g.stone] then
			return g
		end
	end
end

core.register_on_joinplayer(function(player)
	local g = names()
	core.set_player_privs(player:get_player_name(), {interact = true, shout = true})
	local air = core.get_content_id("air")
	local cid = core.get_content_id(g.floor)
	-- Air under the floor deeper than the reach, so that the node dug is
	-- the last thing pointed at
	local p1 = {x = ORIGIN.x - 6, y = ORIGIN.y - 8, z = ORIGIN.z - 6}
	local p2 = {x = ORIGIN.x + 6, y = ORIGIN.y + 6, z = ORIGIN.z + 6}
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do data[i] = air end
	for x = -6, 6 do
		for z = -6, 6 do
			data[area:index(ORIGIN.x + x, ORIGIN.y, ORIGIN.z + z)] = cid
		end
	end
	vm:set_data(data)
	vm:write_to_map()
	player:set_pos({x = ORIGIN.x, y = ORIGIN.y + 0.5, z = ORIGIN.z})
	core.chat_send_player(player:get_player_name(), "dig_swing: the stage is laid")
end)

core.register_on_chat_message(function(name, message)
	local what = message:match("^swing (%a+)$")
	local player = core.get_player_by_name(name)
	if not what or not player then
		return false
	end
	local g = names()
	core.set_node({x = ORIGIN.x + 1, y = ORIGIN.y, z = ORIGIN.z},
			{name = what == "stone" and g.stone or g.dirt})
	player:set_pos({x = ORIGIN.x, y = ORIGIN.y + 0.5, z = ORIGIN.z})
	player:get_inventory():set_stack("main", player:get_wield_index(),
			what == "stone" and ItemStack(g.pick) or ItemStack(""))
	core.chat_send_player(name, "dig_swing: " .. what .. " ready")
	return true
end)

core.register_on_dignode(function(pos, node, digger)
	if digger and digger.is_player and digger:is_player() then
		core.log("action", "dig_swing: dug " .. node.name)
	end
end)
