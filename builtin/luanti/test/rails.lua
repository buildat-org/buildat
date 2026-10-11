-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [VL_RAIL_BOXES]: the stage for rails.sh. A stone floor at y 199 with
-- VoxeLibre's rails on it -- a line along z, one along x crossing it in a
-- tee, a slope up a step -- and a slab, a torch and a rail in a row to
-- frame, and a rail on a pillar with a wall behind to point over. The
-- player has interact and shout only, as on a public server: no fly and
-- no noclip, which is what the anticheat holds a player to.
--
-- The drive says "rails <phase>" in chat; the player is put at the
-- phase's start, the position they ended the last one at logged first:
-- "rails: <last phase> ended at x,y,z".
local PHASES = {
	along_z = {0, 199.5, -2, 0},
	across = {-2, 199.5, 3, 3 * math.pi / 2},
	along_x = {-3, 199.5, 8, 3 * math.pi / 2},
	back_x = {4, 199.5, 8, math.pi / 2},
	off = {0, 199.6, 8, 0},
	slope = {-6, 199.5, -2, 0},
	side = {-1, 199.6, 8, 3 * math.pi / 2},
	frames = {5, 199.5, -0.5, 0},
	over = {8, 199.5, -0.5, 0},
}
local last = "start"

local function lay()
	for x = -8, 8 do
		for z = -4, 14 do
			core.set_node({x = x, y = 199, z = z}, {name = "mcl_core:stone"})
			for y = 200, 203 do
				core.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
	local rails = {}
	for z = 0, 7 do rails[#rails + 1] = {x = 0, y = 200, z = z} end
	for x = -2, 3 do rails[#rails + 1] = {x = x, y = 200, z = 8} end
	-- The slope: up a step of stone at z 4
	for z = 4, 8 do core.set_node({x = -6, y = 200, z = z}, {name = "mcl_core:stone"}) end
	for z = 0, 3 do rails[#rails + 1] = {x = -6, y = 200, z = z} end
	for z = 4, 8 do rails[#rails + 1] = {x = -6, y = 201, z = z} end
	-- To frame
	core.set_node({x = 4, y = 200, z = 2}, {name = "mcl_stairs:slab_stone"})
	core.set_node({x = 5, y = 200, z = 2}, {name = "mcl_torches:torch", param2 = 1})
	rails[#rails + 1] = {x = 6, y = 200, z = 2}
	-- To point over: a rail on a pillar, the wall two nodes behind it
	core.set_node({x = 8, y = 200, z = 2}, {name = "mcl_core:stone"})
	rails[#rails + 1] = {x = 8, y = 201, z = 2}
	for y = 200, 202 do
		core.set_node({x = 8, y = y, z = 4}, {name = "mcl_core:stone"})
	end
	for _, r in ipairs(rails) do
		core.set_node(r, {name = "mcl_minecarts:rail_v2"})
	end
	for _, r in ipairs(rails) do
		mcl_minecarts.update_rail_connections(r)
	end
end

core.register_on_chat_message(function(name, message)
	local phase = message:match("^rails (%S+)$")
	local player = core.get_player_by_name(name)
	if not phase or not player then
		return false
	end
	local p = player:get_pos()
	core.log("action", string.format("rails: %s ended at %.2f,%.2f,%.2f",
			last, p.x, p.y, p.z))
	last = phase
	local at = PHASES[phase]
	if at then
		player:set_pos({x = at[1], y = at[2], z = at[3]})
		player:set_look_horizontal(at[4])
		player:set_look_vertical(0)
	end
	core.chat_send_player(name, "rails: " .. phase .. " ready")
	return true
end)

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.set_player_privs(name, {interact = true, shout = true})
	core.after(3, function()
		lay()
		player:set_pos({x = 0, y = 199.5, z = -2})
		for _, q in ipairs({{0, 200, 0}, {0, 200, 8}, {3, 200, 8}, {-6, 200, 3},
				{-6, 201, 4}, {6, 200, 2}, {8, 201, 2}}) do
			local n = core.get_node({x = q[1], y = q[2], z = q[3]})
			core.log("action", string.format("rails: node %d,%d,%d %s %d",
					q[1], q[2], q[3], n.name, n.param2))
		end
		core.chat_send_player(name, "rails: the stage is laid")
	end)
end)
