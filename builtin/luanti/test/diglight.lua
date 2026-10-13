-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [DIG_LIGHT]: is the light under a dig right, and on which copy? A pit
-- one deep beside the player at t=10 (from a few seconds after the join), a
-- twenty-step stair from it by t=100, the player put at its bottom at
-- t=105, and each second the server's reading at the pit's air and at
-- the stair's bottom, as core.get_node_light(pos, 0.5) (the sun's share
-- alone, so the hour is out of it). The client's half is diglight.sh:
-- `scan` and `scan_volume ... light` at t=15, t=70 and t=115.
-- The pit should read a level under the air over it (logged before the
-- dig) and the stair's bottom 0 on both; whichever copy differs names
-- the fault.
local seed = rawget(_G, "FUZZ_SEED")
if seed then
	core.settings:set("fixed_map_seed", tostring(seed))
end
local pit, bottom, t = nil, nil, 0

-- The ground under the player's feet level: the first node down that is
-- neither air nor a plant nor a tree or its leaves (the spawn may be a
-- jungle). By name: the fixture's environment has no node definitions.
local PLANT = {"leaves", "tree", "vine", "flowers:", "tallgrass",
		"flower", "cocoa", "sapling", "mushroom"}
local function ground_at(x, z, y0)
	for y = y0, y0 - 40, -1 do
		local n = core.get_node({x = x, y = y, z = z}).name
		local plant = false
		for _, w in ipairs(PLANT) do
			if n:find(w) then plant = true end
		end
		if n ~= "air" and n ~= "ignore" and not plant then
			return y
		end
	end
end

core.register_on_joinplayer(function(player)
	-- Once the spawn's sections are generated, which is a few seconds in
	local tries = 0
	local function start()
		local p = vector.round(player:get_pos())
		local x, z = p.x + 2, p.z
		local gy = ground_at(x, z, p.y)
		tries = tries + 1
		-- The ground is under the feet or nearly: a hit far below is a
		-- column not yet in memory read as nothing
		if gy ~= nil and gy < p.y - 3 then
			gy = nil
		end
		if gy == nil then
			core.log("action", "diglight: no ground beside the player at " ..
					core.pos_to_string(p) .. " (" .. tries .. ")")
			if tries < 40 then
				core.after(1, start)
			end
			return
		end
		pit = {x = x, y = gy, z = z}
		-- What the pit is judged against: the light of the air over the
		-- ground node before the dig -- seed 5 spawns in a jungle, and a
		-- pit under a canopy reads the canopy's light, not 14 (user)
		local above = {x = x, y = gy + 1, z = z}
		core.log("action", "diglight: player " .. core.pos_to_string(p) ..
				", the pit at " .. core.pos_to_string(pit) .. ", the air over it " ..
				tostring(core.get_node_light(above, 0.5)))
		local function tick()
			t = t + 1
			if t == 10 then
				core.remove_node(pit)
				core.log("action", "diglight: pit dug")
			end
			if t >= 20 and t < 100 and (t - 20) % 4 == 0 then
				local i = (t - 20) / 4 + 1
				bottom = {x = x + i, y = gy - i, z = z}
				core.remove_node(bottom)
				core.remove_node({x = x + i, y = gy - i + 1, z = z})
				core.log("action", "diglight: step " .. i .. " at " ..
						core.pos_to_string(bottom))
			end
			core.log("action", string.format("diglight: t=%d pit=%s bottom=%s",
					t, tostring(core.get_node_light(pit, 0.5)),
					bottom and tostring(core.get_node_light(bottom, 0.5)) or "-"))
			-- Then the player is put at the bottom for the client's read
			-- Not the bottom: step three, where the flood says 5-9 and a
			-- wall must read lit ([STAIR_DARK]); the bottom is 0 and black
			if t == 105 and bottom then
				player:set_pos({x = x + 3, y = gy - 3 + 0.5, z = z})
				core.log("action", "diglight: player moved to step 3")
			end
			-- And back to the lip at t=125, for the same shot as t=70 with
			-- the client's remesh queue long drained ([STAIR_DARK])
			if t == 125 then
				player:set_pos({x = p.x, y = p.y + 0.5, z = p.z})
				core.log("action", "diglight: player moved back to the start")
			end
			-- The client's reads are on these, its "chat: diglight: t=15" lines
			local name = player:get_player_name()
			if t == 15 or t == 70 or t == 115 or t == 135 then
				core.chat_send_player(name, "diglight: t=" .. t)
			end
			if t < 145 then
				core.after(1, tick)
			else
				core.after(10, function()
					core.chat_send_player(name, "diglight: t=155")
				end)
			end
		end
		core.after(1, tick)
	end
	core.after(3, start)
end)
