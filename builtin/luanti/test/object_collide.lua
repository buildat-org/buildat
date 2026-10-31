-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [CLIENT_FRAME]: the two halves of an object's collision with the map,
-- read off the server alone. A dropped item over a dirt platform must come
-- to rest on it, and one dropped over nothing must keep falling. What this
-- is for is the walkable test in entity.lua, which asks the map by content
-- id rather than by building a node table per voxel per axis per object per
-- step; a test that answered "walkable" for everything would rest both, and
-- one that answered "not walkable" would drop both.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_LUA=builtin/luanti/test/object_collide.lua \
--       bin/buildat_server -m ../apps/vanilla -D ../user -P 29791
core.register_on_mods_loaded(function()
	core.after(4, function()
		local O = {x = 0, y = 120, z = 0}
		-- The spot over nothing, a hundred away: generated air, not a
		-- section that is loaded and not yet generated, which reads as
		-- ignore -- and VoxeLibre's item stops its physics in ignore and
		-- keeps the velocity it was dropped with, rising (2026-10-31)
		local V = {x = 100, y = 122, z = 100}
		core.forceload_block(O)
		core.forceload_block(V)
		-- No player joins, so objects are stepped wherever they are
		core.__active_everywhere = true
		-- **Built until it stays built**: on a save that is being made,
		-- the mapgen reaches this section after the forceload and writes
		-- over whatever was put there, so the platform is laid again
		-- every second until a read-back finds it twice running. Without
		-- that the items fall through ground that was there when they
		-- were dropped (2026-09-26).
		local function lay()
			for x = -3, 3 do
				for z = -3, 3 do
					core.set_node({x = O.x + x, y = O.y, z = O.z + z},
							{name = "mcl_core:dirt"})
					for y = O.y + 1, O.y + 4 do
						core.set_node({x = O.x + x, y = y, z = O.z + z},
								{name = "air"})
					end
				end
			end
			-- The air over the platform and the fall cleared down to its
			-- section's floor: on a random seed a hill pushed the item on
			-- the platform up to 134.7 and a tree stopped the other at
			-- 117.7 (2026-10-31; the runner's seed is fixed since). And
			-- above it: the item drops in at V.y + 0.5, its box reaching
			-- into the node over V, which was solid once and made the item
			-- start inside it and be pushed upwards ([OBJECT_COLLIDE_EDGE])
			for y = 64, V.y + 2 do
				core.set_node({x = V.x, y = y, z = V.z}, {name = "air"})
			end
		end
		local on_floor, over_void
		local watch
		local t = 0
		local held = 0
		local function build()
			-- Read before this lay: a node just set reads back as set
			-- whatever becomes of it
			local ok = __luanti_section_state(O.x, O.y, O.z) == "generated" and
					core.get_node(O).name == "mcl_core:dirt" and
					__luanti_section_state(V.x, V.y, V.z) == "generated" and
					core.get_node(V).name == "air" and
					core.get_node({x = V.x, y = V.y + 1, z = V.z}).name == "air" and
					core.get_node({x = V.x, y = 64, z = V.z}).name == "air"
			lay()
			held = ok and (held + 1) or 0
			if held < 2 then
				core.after(1, build)
				return
			end
			core.log("warning", "collidecheck: the platform stayed")
			-- Over the platform's middle, and far enough from its edge
			-- that the random offset a dropped item takes cannot carry
			-- it off
			on_floor = core.add_item({x = 0, y = 122.5, z = 0},
					"mcl_core:dirt")
			-- And over nothing at all: the same height, a hundred away
			over_void = core.add_item({x = V.x, y = 122.5, z = V.z},
					"mcl_core:dirt")
			core.after(0.25, watch)
		end
		function watch()
			t = t + 0.25
			local a = on_floor and on_floor:get_pos()
			local b = over_void and over_void:get_pos()
			core.log("warning", string.format(
					"collidecheck: t=%.2f floor=%s void=%s", t,
					a and string.format("%.2f", a.y) or "gone",
					b and string.format("%.2f", b.y) or "gone"))
			if t < 3 then
				core.after(0.25, watch)
			else
				core.log("warning", "collidecheck: done")
			end
		end
		core.after(1, build)
	end)
end)
-- vim: set noet ts=4 sw=4:
