-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [UNDERGROUND_LIGHT] (3), the assertion the runner owed: **open air over
-- a surface reads 15 at noon, and still does after the light has been
-- worked out again**. The second half is the regression: a relight whose
-- flood had no sky source of its own zeroed the box it was given and could
-- not fill it back, so a played world went dark in patches and /fixlight
-- did not mend it ([SKY_COLUMN_CAVE]).
--
-- Driven by builtin/luanti/test/surface_light.sh.
core.settings:set("time_speed", "0")
-- The terrain this was written against: devtest's v7, which a new world
-- no longer gets by default (valleys)
core.settings:set("mg_name", "v7")
-- And one seed, whose spawn is on land by the origin: a random one put it
-- far off now and then, and twelve seconds did not load it
core.settings:set("fixed_map_seed", "3")
core.after(0, function() core.set_timeofday(0.5) end)

local COLUMNS = 9      -- a 3x3 of columns around the player
local SPACING = 4

-- The first non-air going down from well above, and the air over it
local function surface_at(x, z)
	for y = 60, -20, -1 do
		local n = core.get_node({x = x, y = y, z = z})
		if n.name ~= "air" and n.name ~= "ignore" then
			return y
		end
	end
	return nil
end

local function read(base)
	local out, missing = {}, 0
	local i = 0
	for dx = -1, 1 do
	for dz = -1, 1 do
		i = i + 1
		local x = math.floor(base.x + 0.5) + dx * SPACING
		local z = math.floor(base.z + 0.5) + dz * SPACING
		local top = surface_at(x, z)
		if top == nil then
			missing = missing + 1
			out[#out + 1] = string.format("c%d=none", i)
		else
			local l = core.get_node_light({x = x, y = top + 1, z = z}, 0.5)
			out[#out + 1] = string.format("c%d=%s", i, tostring(l))
		end
	end
	end
	return table.concat(out, " "), missing
end

core.register_on_joinplayer(function(player)
	local base = player:get_pos()
	-- Read once the ground has loaded: twelve seconds, then up to six
	-- more tries five apart while no column finds a surface
	local waits = 0
	local function measure()
		core.set_timeofday(0.5)
		local before, missing = read(base)
		if missing == COLUMNS and waits < 6 then
			waits = waits + 1
			core.after(5, measure)
			return
		end
		core.log("action", "surface_light: before " .. before)
		-- **The box's top has to be under the loaded column**, which is
		-- the shape the fault had: a relight with no sky source of its
		-- own could only borrow daylight from a lit neighbour, so a box
		-- reaching above the terrain was mended by the open air in it
		-- and said nothing. Two voxels over the surface is under
		-- everything the client has loaded above it.
		local here_top = surface_at(math.floor(base.x + 0.5),
				math.floor(base.z + 0.5)) or math.floor(base.y)
		local r = 24
		local p1 = {x = base.x - r, y = here_top - 30, z = base.z - r}
		local p2 = {x = base.x + r, y = here_top + 2, z = base.z + r}
		core.fix_light(p1, p2)
		core.log("action", "surface_light: fix_light over " ..
				core.pos_to_string(p1) .. " " .. core.pos_to_string(p2))
		core.after(8, function()
			core.set_timeofday(0.5)
			local after = read(base)
			core.log("action", "surface_light: after " .. after)
			core.log("action", "surface_light: done")
			core.chat_send_all("surface_light: done")
		end)
	end
	core.after(12, measure)
end)
