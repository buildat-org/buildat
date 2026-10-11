-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [WIELDLIGHT_STALE]: light placed and taken back quickly ends where
-- /fixlight would put it. A tunnel dug in the game's own stone 30
-- voxels under sea level, its walls made stone so that it is sealed, at
-- night; the player put a voxel further along it every 0.05 s, 118 voxels
-- out and back, a voxel aside each pass, three times, facing back the way
-- they came, with a torch in hand (VoxeLibre's vl_wieldlight writes its
-- light by VoxelManip), glowstone set and dug beside the path on some
-- steps; then the torch put away, and the lamp bank over the tunnel, its
-- walls included, compared voxel by voxel with the same box after
-- core.fix_light(), and again with the glowstone dug. Last, the lamp bank
-- around the player is logged for the client's scan_volume to be compared
-- with. "ws: shot N" in the player's chat along the way, for the client's
-- screenshots.
-- The tunnel's lowest air voxel at the origin; the player one above, on
-- the edges: a chunk's in y between -33 and -32 (a section's would be 0,
-- the surface, or -64, under the bedrock), a section's in z at 0, and the
-- path crosses x = 0 (a section's) and x = -32 and 32 (chunks')
local C = {x = 0, y = -33, z = 0}
local R = {x = 60, y = 3, z = 2} -- the inside: x -60..60, y 0..3, z -2..2
local P1 = vector.subtract(C, {x = R.x + 1, y = 1, z = R.z + 1})
local P2 = vector.add(C, {x = R.x + 1, y = R.y + 1, z = R.z + 1})
local SPAN = 2 * R.x - 2
local STEPS = tonumber(core.settings:get("ws_steps") or "") or 6 * SPAN
local function say(s) core.log("warning", "ws: " .. s) end

local function tunnel()
	local vm = VoxelManip(P1, P2)
	local e1, e2 = vm:get_emerged_area()
	local area = VoxelArea(e1, e2)
	local data = vm:get_data()
	local stone, air = core.get_content_id("mcl_core:stone"),
			core.get_content_id("air")
	for z = P1.z, P2.z do for y = P1.y, P2.y do for x = P1.x, P2.x do
		local inside = x > P1.x and x < P2.x and y > P1.y and y < P2.y and
				z > P1.z and z < P2.z
		local i = area:index(x, y, z)
		-- The game's own stone dug; a wall of anything else (a cave's air,
		-- ore, gravel) made stone
		if inside or data[i] ~= stone then
			data[i] = inside and air or stone
		end
	end end end
	vm:set_data(data)
	vm:write_to_map(true)
end

-- The lamp bank over the room, walls included
local function lamp()
	local vm = VoxelManip(P1, P2)
	local e1, e2 = vm:get_emerged_area()
	local area = VoxelArea(e1, e2)
	local l = vm:get_light_data()
	local out = {}
	for z = P1.z, P2.z do for y = P1.y, P2.y do for x = P1.x, P2.x do
		out[#out + 1] = math.floor(l[area:index(x, y, z)] / 16)
	end end end
	return out
end

-- A voxel's place in lamp()'s list
local function index(q)
	local w, h = P2.x - P1.x + 1, P2.y - P1.y + 1
	return (q.z - P1.z) * w * h + (q.y - P1.y) * w + (q.x - P1.x) + 1
end

local function compare(what)
	local before = lamp()
	core.fix_light(P1, P2)
	local after = lamp()
	local n, first = 0, nil
	local i = 0
	for z = P1.z, P2.z do for y = P1.y, P2.y do for x = P1.x, P2.x do
		i = i + 1
		if before[i] ~= after[i] then
			n = n + 1
			first = first or string.format("(%d,%d,%d) %d, fixed %d",
					x - C.x, y - C.y, z - C.z, before[i], after[i])
			-- The first few with their node and the six beside them, before
			-- and fixed: which of the two is right is the neighbours' to say
			if n <= 8 then
				local nb = {}
				for _, d in ipairs({{-1,0,0},{1,0,0},{0,-1,0},{0,1,0},{0,0,-1},{0,0,1}}) do
					local q = {x = x + d[1], y = y + d[2], z = z + d[3]}
					if q.x >= P1.x and q.x <= P2.x and q.y >= P1.y and q.y <= P2.y and
							q.z >= P1.z and q.z <= P2.z then
						local j = index(q)
						nb[#nb + 1] = string.format("%s %d/%d", core.get_node(q).name,
								before[j], after[j])
					else
						nb[#nb + 1] = "-"
					end
				end
				say(string.format("  (%d,%d,%d) %s %d/%d; -x +x -y +y -z +z: %s",
						x - C.x, y - C.y, z - C.z, core.get_node({x = x, y = y, z = z}).name,
						before[i], after[i], table.concat(nb, ", ")))
			end
		end
	end end end
	say(string.format("%s: %d voxels differ from fix_light%s", what, n,
			first and ", first " .. first or ""))
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(1, function()
		core.emerge_area(P1, P2, function(_, _, left)
			if left > 0 then return end
			tunnel()
			core.set_timeofday(0)
			local inv = player:get_inventory()
			inv:set_stack("main", 1, "mcl_torches:torch")
			player:set_wield_index(1)
			say("tunnel made")
			local step = 0
			local placed = {}
			local function walk()
				local p = core.get_player_by_name(name)
				if not p then return end
				step = step + 1
				-- Back and forth along x, one voxel a step
				local span = SPAN
				local k = step % (2 * span)
				local x = (k < span and k or 2 * span - k) - R.x + 1
				-- And a voxel aside in z each pass, so the path is not one line
				local zz = math.floor(step / (2 * span)) % 3 - 1
				-- Facing back the way they came, a little down: the camera
				-- on the light left behind. Luanti's yaw is counterclockwise
				-- from +Z, so +X is 3/2 pi and -X is 1/2 pi.
				p:set_look_horizontal(k < span and math.pi / 2 or 3 * math.pi / 2)
				p:set_look_vertical(0.25)
				p:set_pos({x = C.x + x, y = C.y + 1, z = C.z + zz})
				if step % (span / 2) == 0 then
					core.chat_send_player(name, "ws: shot " .. step)
				end
				-- A glowstone beside the path on some steps, dug on others
				if step % 7 == 0 then
					local g = {x = C.x + x, y = C.y + 1, z = C.z + (step % 14 == 0 and 2 or -2)}
					if core.get_node(g).name == "air" then
						core.set_node(g, {name = "mcl_nether:glowstone"})
						placed[#placed + 1] = g
					end
				elseif step % 5 == 0 and #placed > 0 then
					core.remove_node(table.remove(placed, 1))
				end
				if step % 150 == 0 then
					local pp = vector.round(p:get_pos())
					local vm = VoxelManip(pp, pp)
					local area = VoxelArea(vm:get_emerged_area())
					say(string.format("step %d: lamp %d at the player, wielding %s",
							step, math.floor(vm:get_light_data()[area:indexp(pp)] / 16),
							p:get_wielded_item():get_name()))
				end
				if step < STEPS then
					core.after(0.05, walk)
					return
				end
				say("walked " .. step)
				-- (Not compared with the torch in hand: fix_light would take
				-- the mod's light out from under it)
				core.after(2, function()
					-- The last two shots along the tunnel, not at its end wall
					p:set_look_horizontal(3 * math.pi / 2)
					p:set_pos(p:get_pos())
					p:get_inventory():set_stack("main", 1, "")
					core.after(8, function()
						compare("the torch put away")
						core.chat_send_player(name, "ws: shot away")
						for _, g in ipairs(placed) do core.remove_node(g) end
						core.after(5, function()
							compare("the glowstone dug")
							core.chat_send_player(name, "ws: shot dug")
							-- The lamp light around the player, as the client's
							-- scan_volume 8 lists it: what the client has is
							-- compared with it
							local c = vector.round(p:get_pos())
							local vm = VoxelManip(vector.offset(c, -8, -8, -8),
									vector.offset(c, 8, 8, 8))
							local area = VoxelArea(vm:get_emerged_area())
							local l = vm:get_light_data()
							for y = c.y - 8, c.y + 8 do for z = c.z - 8, c.z + 8 do
								local row = {}
								for x = c.x - 8, c.x + 8 do
									row[#row + 1] = tostring(math.floor(
											l[area:index(x, y, z)] / 16))
								end
								say(string.format("lamp y=%d z=%d x=%d: %s", y, z,
										c.x - 8, table.concat(row, " ")))
							end end
							say("done")
							core.chat_send_player(name, "ws: done")
						end)
					end)
				end)
			end
			core.after(3, walk)
		end)
	end)
end)
-- vim: set noet ts=4 sw=4:
