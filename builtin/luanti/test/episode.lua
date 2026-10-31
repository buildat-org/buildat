-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [AUTO_PLAYTEST] part 2: a compared episode. The same worldmod runs on
-- official Luanti's server and on this module, builds one well-defined
-- state with server-side API both have, lets the client do one scripted
-- thing for a few seconds, and logs a census the runner (episode.sh) diffs
-- between the two engines:
--
--   episode: ready dig
--   episode: census dig nodes=dirt:24,air:... inv=dirt:1 objs=1
--
-- The state: a 5x5 platform of the game's own dirt in the sky, the player
-- standing on its middle looking straight down, an entity beside them, an
-- empty inventory, ABMs, LBMs and the clock off, every HUD element gone.
-- The names come out of the registry at run time, so one file serves
-- devtest and VoxeLibre. What the client does is episode.sh's command
-- file; what is asserted is the census, never a coordinate.
--
-- EPISODE_NAME picks the episode; "dig" is the first. EPISODE_SECONDS is
-- how long after `ready` the census is taken; episode.sh writes the
-- client's action at `ready`.

local NAME = rawget(_G, "EPISODE_NAME") or "dig"
local SECONDS = tonumber(rawget(_G, "EPISODE_SECONDS")) or 20
-- The episodes in the pool, where gravity stays on and the census reads y
local POOL = {sink = true, swim = true, fall = true, dive = true,
		seaplace = true}
-- The ones where the body is in the pool and gravity stays on
local SWIMMING = {sink = true, swim = true, fall = true, dive = true}
local ORIGIN = {x = 0, y = 120, z = 0}

-- The first registered node whose name says what it is: a game's dirt
-- under any mod prefix, with nothing that is dirt with grass on it
local function node_named(word)
	local found = {}
	for name, def in pairs(core.registered_nodes) do
		if name:find(word, 1, true) and not name:find("with", 1, true)
				and def.drawtype == "normal" then
			found[#found + 1] = name
		end
	end
	table.sort(found)
	return found[1]
end

-- The first registered entity that is a mob or an item: something a
-- census can count and a punch can reach
local function some_entity()
	local found = {}
	for name, def in pairs(core.registered_entities) do
		if not name:find("^__builtin") and def.initial_properties and
				def.initial_properties.physical ~= nil then
			found[#found + 1] = name
		end
	end
	table.sort(found)
	return found[1]
end

local function freeze()
	core.settings:set("time_speed", "0")
	core.settings:set("mobs_spawn", "false")
	-- The dirt reaches six: a click straight down from the pool's top
	-- has the floor 4.6 away, past a hand's four (VoxeLibre's hand is
	-- mcl_meshhand's, per player, so the hand itself is not the one to
	-- override) ([POINTABLE])
	local d = node_named("dirt")
	if d then
		core.override_item(d, {range = 6})
	end
	for i = #core.registered_abms, 1, -1 do
		core.registered_abms[i] = nil
	end
	for i = #core.registered_lbms, 1, -1 do
		core.registered_lbms[i] = nil
	end
	-- And no entity walks: devtest's bigfoot paces ten nodes through the
	-- player, and where it is when the ray goes down is a matter of
	-- timing on each engine
	for _, def in pairs(core.registered_entities) do
		def.on_step = nil
	end
end
core.register_on_mods_loaded(freeze)

local dirt = nil
-- The game's water source, by name
local water = nil
local function stamp()
	dirt = node_named("dirt")
	local air = core.get_content_id("air")
	local cid = core.get_content_id(dirt)
	local p1 = vector.subtract(ORIGIN, 3)
	local p2 = vector.add(ORIGIN, 3)
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do
		data[i] = air
	end
	for x = -2, 2 do
		for z = -2, 2 do
			data[area:index(ORIGIN.x + x, ORIGIN.y, ORIGIN.z + z)] = cid
		end
	end
	for name, def in pairs(core.registered_nodes) do
		if def.drawtype == "liquid" and name:find("water", 1, true) and
				(water == nil or name < water) then
			water = name
		end
	end
	if POOL[NAME] then
		-- A pool three deep with dirt walls, the platform its floor, the
		-- game's own water source ([WATER_PARITY]): what the player's body
		-- does in it is what is compared
		local wid = core.get_content_id(water)
		for x = -2, 2 do
			for z = -2, 2 do
				for y = 1, 3 do
					local edge = (x == -2 or x == 2 or z == -2 or z == 2)
					data[area:index(ORIGIN.x + x, ORIGIN.y + y, ORIGIN.z + z)] =
							edge and cid or wid
				end
			end
		end
	end
	vm:set_data(data)
	vm:write_to_map()
end

-- The flood episode's cave, found by find_flood_spot(): the column dug
-- (x, z), the sea floor's y, the cave's top y, and the box counted
local flood = nil

local function census(player)
	local p1 = vector.subtract(ORIGIN, 3)
	local p2 = vector.add(ORIGIN, 3)
	if flood then
		p1, p2 = flood.p1, flood.p2
	end
	local names = {}
	for x = p1.x, p2.x do
		for y = p1.y, p2.y do
			for z = p1.z, p2.z do
				local n = core.get_node({x = x, y = y, z = z}).name
				names[n] = (names[n] or 0) + 1
			end
		end
	end
	local parts = {}
	for n, c in pairs(names) do
		parts[#parts + 1] = n .. ":" .. c
	end
	table.sort(parts)
	local inv = {}
	for _, stack in ipairs(player:get_inventory():get_list("main")) do
		if not stack:is_empty() then
			inv[#inv + 1] = stack:get_name() .. ":" .. stack:get_count()
		end
	end
	table.sort(inv)
	-- Objects by name, so a difference says which one: a dropped item
	-- and a mob are not the same "2"
	local objs = {}
	for _, obj in ipairs(core.get_objects_inside_radius(ORIGIN, 10)) do
		if not obj:is_player() then
			local le = obj:get_luaentity()
			local n = le and le.name or "?"
			objs[n] = (objs[n] or 0) + 1
		end
	end
	-- Every object of the world with where it is and what it hangs on,
	-- for reading a census that differs ([DIG_PARITY]); the player's
	-- own position beside
	local where = {}
	for _, obj in ipairs(core.get_objects_inside_radius(ORIGIN, 1000)) do
		local le = obj:get_luaentity()
		local p = obj:get_pos()
		local parent = obj.get_attach and obj:get_attach() or nil
		where[#where + 1] = string.format("%s@%.1f,%.1f,%.1f%s",
				obj:is_player() and "player" or (le and le.name or "?"),
				p.x, p.y, p.z, parent and "(attached)" or "")
	end
	core.log("action", "episode: objects " .. table.concat(where, " "))
	local olist = {}
	for n, c in pairs(objs) do
		olist[#olist + 1] = n .. ":" .. c
	end
	table.sort(olist)
	local out = "nodes=" .. table.concat(parts, ",") .. " inv=" ..
			table.concat(inv, ",") .. " objs=" .. table.concat(olist, ",")
	if SWIMMING[NAME] then
		-- Where the body ended, a tenth of a node coarse, and the breath:
		-- the pool episodes' measure
		local p = player:get_pos()
		out = out .. string.format(" y=%.1f breath=%d", p.y - ORIGIN.y,
				player:get_breath())
	end
	if NAME == "seaplace" then
		-- Where the dirt landed, relative to the pool's floor
		local at = {}
		for y = 1, 5 do
			local n = core.get_node({x = ORIGIN.x, y = ORIGIN.y + y, z = ORIGIN.z}).name
			if n == dirt then
				at[#at + 1] = tostring(y)
			end
		end
		out = out .. " dirt_at=" .. table.concat(at, ",")
	end
	if NAME == "pour" or NAME == "flood" then
		-- How far the poured source spread: the flowing nodes by level
		-- ([LIQUID_FLOW])
		local levels = {}
		for x = p1.x, p2.x do
			for y = p1.y, p2.y do
				for z = p1.z, p2.z do
					local n = core.get_node({x = x, y = y, z = z})
					local def = core.registered_nodes[n.name]
					if def and def.liquidtype == "flowing" then
						local l = n.param2 % 8
						levels[l] = (levels[l] or 0) + 1
					end
				end
			end
		end
		local parts = {}
		for l = 7, 0, -1 do
			if levels[l] then
				parts[#parts + 1] = l .. ":" .. levels[l]
			end
		end
		out = out .. " levels=" .. table.concat(parts, ",")
	end
	return out
end

-- The first column, ring by ring outward from the origin to 50, where the
-- sea stands over ground with a cave under it within 40 nodes: the sea floor
-- (the first non-water under the water) and, under it, an air run at
-- least 3 tall whose floor is stone or the like. Both engines run it on
-- the same seed and find the same column. Nil when there is none.
local function find_flood_spot()
	-- EPISODE_SPOT = "x,z" pins the column, when the two engines' searches
	-- would land on different caves
	local pin_x, pin_z = tostring(rawget(_G, "EPISODE_SPOT") or ""):match("^(-?%d+),(-?%d+)$")
	for r = 0, 50 do
		for x = -r, r do
			for z = -r, r do
				local pinned = pin_x and (x ~= tonumber(pin_x) or z ~= tonumber(pin_z))
				if math.max(math.abs(x), math.abs(z)) == r and not pinned then
					-- The sea's top in this column, if it is a sea column:
					-- the first water under the air from 80 down
					local y = 40
					while y > -60 and core.get_node({x = x, y = y, z = z}).name == "air" do
						y = y - 1
					end
					if core.get_node({x = x, y = y, z = z}).name == water then
						-- Down to the floor
						while core.get_node({x = x, y = y, z = z}).name == water and
								y > -90 do
							y = y - 1
						end
						local floor_y = y
						-- And on down, through ground, to an air run
						local yy = floor_y - 1
						while yy > floor_y - 40 do
							local name = core.get_node({x = x, y = yy, z = z}).name
							if name == "air" then
								local top = yy
								while core.get_node({x = x, y = yy - 1, z = z}).name == "air" do
									yy = yy - 1
								end
								-- A natural cave, not a mineshaft: nothing
								-- built within 3 of the column at its
								-- levels (the module generates no
								-- structures, official does)
								local built = core.find_nodes_in_area(
										{x = x - 6, y = yy - 2, z = z - 6},
										{x = x + 6, y = floor_y, z = z + 6},
										{"group:wood", "group:fence", "group:rail",
										"mcl_core:cobweb", "group:tree", "group:torch"})
								if top - yy >= 2 and #built == 0 then
									return {x = x, z = z, floor_y = floor_y,
											cave_top = top, cave_bottom = yy}
								end
							end
							yy = yy - 1
						end
					end
				end
			end
		end
	end
	return nil
end

core.register_on_joinplayer(function(player)
	core.after(3, function()
		if NAME == "flood" then
			-- No stage: the world's own sea and cave. The area is emerged
			-- first, then the spot found and the player put over it.
			for name, def in pairs(core.registered_nodes) do
				if def.drawtype == "liquid" and name:find("water", 1, true) and
						(water == nil or name < water) then
					water = name
				end
			end
			core.emerge_area({x = -52, y = -40, z = -52}, {x = 52, y = 40, z = 52},
					function(blockpos, action, remaining)
				if remaining > 0 then
					return
				end
				local spot = find_flood_spot()
				if not spot then
					core.log("action", "episode: FAILED no sea over a cave within 50")
					return
				end
				flood = spot
				flood.p1 = {x = spot.x - 6, y = spot.cave_bottom - 2, z = spot.z - 6}
				flood.p2 = {x = spot.x + 6, y = spot.floor_y, z = spot.z + 6}
				ORIGIN = {x = spot.x, y = spot.floor_y, z = spot.z}
				core.log("action", string.format(
						"episode: flood spot %d,%d: sea floor y=%d, cave y=%d..%d",
						spot.x, spot.z, spot.floor_y, spot.cave_top, spot.cave_bottom))
				player:set_physics_override({gravity = 0})
				for id, _ in pairs(player:hud_get_all()) do
					player:hud_remove(id)
				end
				player:set_pos({x = spot.x, y = 64, z = spot.z})
				core.log("action", "episode: state flood")
				core.after(1, function()
					core.log("action", "episode: ready " .. NAME)
					-- The column from the sea floor down into the cave, dug
					for y = spot.floor_y, spot.cave_top, -1 do
						core.set_node({x = spot.x, y = y, z = spot.z}, {name = "air"})
					end
					core.after(SECONDS, function()
						core.log("action", "episode: census " .. NAME .. " " ..
								census(player))
					end)
				end)
			end)
			return
		end
		-- In the pool's middle, a node under the surface, for the pool
		-- episodes; on the platform otherwise
		-- a node under the surface for sink and swim, four above it for
		-- the fall in
		local drop = NAME == "fall" and 8 or (SWIMMING[NAME] and 2 or
				(NAME == "seaplace" and 3.5 or 1))
		-- The player put there first and the stage emerged before it is
		-- stamped: a far spawn's player has its own sections generated
		-- first, and the stage's waited behind them -- stamped into a
		-- section not generated yet, its air was the mapgen's stone when
		-- it came (2026-10-31). Held there meanwhile.
		local stamped = false
		local function wait_there()
			if not stamped and player:is_player() then
				player:set_pos({x = ORIGIN.x, y = ORIGIN.y + drop, z = ORIGIN.z})
				core.after(0.5, wait_there)
			end
		end
		wait_there()
		core.emerge_area(vector.subtract(ORIGIN, 3), vector.add(ORIGIN, 3),
				function(blockpos, action, remaining)
			if remaining > 0 then
				return
			end
			stamped = true
			stamp()
			player:get_inventory():set_list("main", {})
			if NAME == "place" or NAME == "seaplace" then
				-- Ten of the dirt in the first slot, which is what the
				-- launcher's and the extension's hotbar select on join
				player:get_inventory():set_stack("main", 1,
						ItemStack(dirt .. " 10"))
			end
			-- Gravity stays on in the pool: sinking is the measure
			if not SWIMMING[NAME] then
				player:set_physics_override({gravity = 0})
			end
			for id, _ in pairs(player:hud_get_all()) do
				player:hud_remove(id)
			end
			player:hud_set_flags({hotbar = false, healthbar = false,
					breathbar = false, crosshair = false, minimap = false})
			player:set_look_horizontal(0)
			player:set_look_vertical(math.pi / 2)
			player:set_pos({x = ORIGIN.x, y = ORIGIN.y + drop, z = ORIGIN.z})
			local ent = some_entity()
			if ent then
				core.add_entity({x = ORIGIN.x + 2, y = ORIGIN.y + 1,
						z = ORIGIN.z}, ent)
			end
			core.log("action", "episode: state " .. NAME .. " dirt=" ..
					tostring(dirt) .. " entity=" .. tostring(ent) ..
					(water and (" water=" .. water .. " pointable=" ..
					tostring(core.registered_nodes[water].pointable)) or ""))
			-- Three seconds for the client to receive the stamp before it
			-- acts: the module's client had the pre-stamp air under its ray a
			-- second after the write
			core.after(3, function()
				-- Re-aimed, since the client had a say about the look; and
				-- re-put, since a client that got the place before the
				-- gravity override fell for a moment (the module's objects
				-- lane and its physics packet are two lanes)
				player:set_look_horizontal(0)
				player:set_look_vertical(math.pi / 2)
				if not SWIMMING[NAME] then
					player:set_pos({x = ORIGIN.x, y = ORIGIN.y + drop, z = ORIGIN.z})
				end
				if NAME == "seaplace" then
					-- Held over the pool: VoxeLibre's playerphysics rewrites
					-- the override every step, so gravity 0 does not hold and
					-- the body would sink into what it is placing on
					local hold
					hold = function()
						if player:is_player() then
							player:set_pos({x = ORIGIN.x, y = ORIGIN.y + drop, z = ORIGIN.z})
							core.after(0.5, hold)
						end
					end
					hold()
				end
				core.log("action", "episode: ready " .. NAME)
				if NAME == "pour" then
					-- The game's water source on the platform's middle; the
					-- census counts what it spread to ([LIQUID_FLOW])
					core.set_node({x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z},
							{name = water})
				end
				core.after(SECONDS, function()
					if not player:is_player() then
						core.log("action", "episode: FAILED the player left " ..
								"before the census")
						return
					end
					core.log("action", "episode: census " .. NAME .. " " ..
							census(player))
				end)
			end)
		end)
	end)
end)
