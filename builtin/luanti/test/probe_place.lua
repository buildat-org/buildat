-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Run by hand, by the command below; no runner references it.
-- What is actually at a place in the world, which a screenshot cannot say:
-- the node, its param2, the light on the face above it, and how far the sky
-- is open over it. No client needed -- the server answers and exits.
--
--   cd Build && BUILDAT_LUANTI_GAME=mineclone2 \
--     BUILDAT_LUANTI_SAVE=buildat_test_probe \
--     BUILDAT_LUANTI_IMPORT=../local/reference_worlds/<seed> \
--     BUILDAT_VOXELWORLD_KEEP_LOADED=1 \
--     BUILDAT_LUANTI_LUA=../builtin/luanti/test/probe_place.lua \
--     bin/buildat_server -m ../apps/vanilla -D ../user
--
-- The place and the node are the two constants below, edited per question:
-- a fixture that answers "what is here" has a different here every time, and
-- a setting for it would be a knob nobody but this file reads.
--
-- and the answer is on stdout as PROBE lines. Written for [GREEN_BIAS],
-- which spent a day reading colours off pictures of nodes nobody had asked
-- what they were: the grass under the reference set's fourth viewpoint is
-- `param2 = 14` everywhere, its neighbours are `air/0` and `dirt/0`, and
-- there are forty voxels of open sky over it. Each of those three ruled out
-- a different explanation of what was drawn.
-- The reference set's fourth viewpoint
local AT = {x = 432, z = -214}
-- What to look for, and how many of them are enough to see a pattern
local WANT = "mcl_core:dirt_with_grass"
local ENOUGH = 6
local SECTION = 64

local t, step = 0, 0
core.register_globalstep(function(dt)
	t = t + dt
	if step == 0 and t > 8 then
		step = 1
		-- Pinned, or the sections go away before the answer is read
		for bx = -1, 1 do
			for bz = -1, 1 do
				core.__forceload_block_raw({x = AT.x + bx * SECTION, y = 54,
						z = AT.z + bz * SECTION})
			end
		end
	elseif step == 1 and t > 20 then
		step = 2
		local found = 0
		for dx = 0, 6 do
			for dz = 0, 6 do
				local x, z = AT.x + dx * 3, AT.z + dz * 3
				for y = 70, 30, -1 do
					local n = core.get_node({x = x, y = y, z = z})
					if n.name == WANT then
						local open = 0
						for up = 1, 40 do
							if core.get_node({x = x, y = y + up, z = z}).name
									~= "air" then
								break
							end
							open = up
						end
						local below = core.get_node({x = x, y = y - 1, z = z})
						core.log("action", "PROBE " .. x .. "," .. y .. "," ..
								z .. " " .. n.name .. "/" ..
								tostring(n.param2) ..
								" below=" .. below.name .. "/" ..
								tostring(below.param2) ..
								" light_above=" .. tostring(
										core.get_node_light({x = x, y = y + 1,
										z = z}, 0.5)) ..
								" open_sky=" .. open)
						found = found + 1
						break
					end
				end
				if found >= ENOUGH then break end
			end
			if found >= ENOUGH then break end
		end
		core.log("action", "PROBE done, " .. found .. " of " .. WANT)
		core.request_shutdown()
	end
end)
