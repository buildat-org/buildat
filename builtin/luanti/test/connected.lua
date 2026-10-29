-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Are "connected" node boxes drawn with their connections? ([FEATURE_SWEEP]
-- 2026-09-21: VoxeLibre's fences, panes and chorus plants are this kind)
--
--   FIXTURE=connected builtin/luanti/test/mobmesh.sh
--
-- On a stone platform over the spawn: a run of oak fences with a corner, a
-- fence ending against a stone block, a run of glass panes, and a lone
-- fence post. What the shot shows is bars between the fences and to the
-- stone, panes joined edge to edge, and the lone post with no bars.
core.register_on_joinplayer(function(player)
	core.after(6, function()
		local p = player:get_pos()
		-- The first height over the spawn where the whole stage and three
		-- above it are air: a forest's canopy and a hill are what a fixed
		-- height ran into
		local base = {x = math.floor(p.x), y = math.floor(p.y) + 4, z = math.floor(p.z)}
		for y = base.y, base.y + 60 do
			local clear = true
			for dz = -6, 6 do
				for dx = -8, 6 do
					for dy = -1, 3 do
						if core.get_node({x = base.x + dx, y = y + dy,
								z = base.z + dz}).name ~= "air" then
							clear = false
						end
					end
				end
			end
			if clear then
				base.y = y
				break
			end
		end
		for dz = -6, 6 do
			for dx = -8, 6 do
				core.set_node({x = base.x + dx, y = base.y - 1, z = base.z + dz},
						{name = "mcl_core:stone"})
			end
		end
		-- The fence run along z with a corner turning +x, ending on stone
		for dz = -4, 0 do
			core.set_node({x = base.x, y = base.y, z = base.z + dz},
					{name = "mcl_fences:fence"})
		end
		for dx = 1, 3 do
			core.set_node({x = base.x + dx, y = base.y, z = base.z},
					{name = "mcl_fences:fence"})
		end
		core.set_node({x = base.x + 4, y = base.y, z = base.z},
				{name = "mcl_core:stone"})
		-- Panes along z, two nodes over
		for dz = 2, 5 do
			core.set_node({x = base.x + 2, y = base.y, z = base.z + dz},
					{name = "xpanes:pane_natural"})
		end
		-- The lone post
		core.set_node({x = base.x - 3, y = base.y, z = base.z + 4},
				{name = "mcl_fences:fence"})
		player:set_pos({x = base.x - 6, y = base.y + 2.5, z = base.z})
		-- Facing east, as the drive will look: the turn is the line the
		-- client logs for the stage ("the server put the player at ...
		-- looking 90"), told apart from the spawn's placing
		player:set_look_horizontal(3 * math.pi / 2)
		core.after(16, function()
			player:set_pos({x = base.x - 2.5, y = base.y + 1.5, z = base.z - 4})
		end)
		core.log("action", "connected: the fences, the panes and the post are placed")
	end)
end)
