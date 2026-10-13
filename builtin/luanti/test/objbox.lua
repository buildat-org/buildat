-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [OBJECT_SELECTION_BOX]: a pig, a dropped item and a player-shaped
-- stand-in on a stone platform, three nodes east of the player; objbox.sh
-- points at each in turn and shoots the box drawn around it, then
-- punches the stand-in.
--
--   builtin/luanti/test/objbox.sh
core.register_entity(":objbox:dummy", {
	initial_properties = {
		visual = "mesh",
		mesh = "mcl_armor_character.b3d",
		textures = {"character.png", "blank.png", "blank.png"},
		-- VoxeLibre's standing player's (mcl_playerplus)
		collisionbox = {-0.312, 0, -0.312, 0.312, 1.8, 0.312},
		selectionbox = {-0.312, 0, -0.312, 0.312, 1.8, 0.312},
		physical = false,
	},
	on_punch = function(_, puncher)
		core.log("action", "objbox: dummy punched")
		-- The drive waits for this line
		if puncher and puncher:is_player() then
			core.chat_send_player(puncher:get_player_name(), "objbox: dummy punched")
		end
	end,
})
-- A dropped item as Luanti's builtin one draws it; VoxeLibre's own are not
-- pointable
core.register_entity(":objbox:item", {
	initial_properties = {
		visual = "item",
		wield_item = "mcl_core:tree",
		visual_size = {x = 0.4, y = 0.4},
		collisionbox = {-0.25, -0.25, -0.25, 0.25, 0.25, 0.25},
		selectionbox = {-0.21, -0.21, -0.21, 0.21, 0.21, 0.21},
		automatic_rotate = math.pi * 0.5,
		physical = false,
	},
})
core.register_on_joinplayer(function(player)
	core.set_timeofday(0.5)
	core.after(6, function()
		-- The first height over the spawn where the stage is all air
		local p = player:get_pos()
		local b = {x = math.floor(p.x), y = math.floor(p.y) + 4,
				z = math.floor(p.z)}
		for y = b.y, b.y + 60 do
			local clear = true
			for dz = -4, 4 do
				for dx = -5, 3 do
					for dy = -1, 3 do
						if core.get_node({x = b.x + dx, y = y + dy,
								z = b.z + dz}).name ~= "air" then
							clear = false
						end
					end
				end
			end
			if clear then b.y = y; break end
		end
		for dz = -4, 4 do
			for dx = -5, 3 do
				core.set_node({x = b.x + dx, y = b.y - 1, z = b.z + dz},
						{name = "mcl_core:stone"})
			end
		end
		-- Feet on the platform's top, which is b.y - 0.5
		local floor = b.y - 0.5
		player:set_pos({x = b.x - 3, y = floor, z = b.z})
		local pig = core.add_entity({x = b.x, y = floor, z = b.z}, "mobs_mc:pig")
		local le = pig and pig:get_luaentity()
		if le then
			-- Standing still (mcl_mobs' own fields)
			le.walk_chance = 0
			le.passive = true
			le.jump = false
		end
		core.add_entity({x = b.x, y = floor + 0.25, z = b.z + 2},
				"objbox:item")
		core.add_entity({x = b.x, y = floor, z = b.z - 2}, "objbox:dummy")
		core.after(3, function()
			-- Again, once the platform has reached the client: the first
			-- can arrive before the stone and fall through it
			player:set_pos({x = b.x - 3, y = floor + 0.2, z = b.z})
			player:set_look_horizontal(-math.pi / 2)
			-- And the pig back where the drive aims: it walks
			if pig then pig:set_pos({x = b.x, y = floor, z = b.z}) end
			core.log("action", "objbox: stage at " .. core.pos_to_string(b))
			core.chat_send_player(player:get_player_name(), "objbox: ready")
		end)
	end)
end)
