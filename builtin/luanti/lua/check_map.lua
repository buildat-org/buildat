-- Buildat: builtin/luanti/lua/check_map.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The one runnable check the map seam leaves behind: a node written, flushed
-- into voxelworld by the module between the two halves, and read back out of
-- it. The write-behind buffer makes a round trip that never leaves the buffer
-- prove nothing, which is why this is two functions and not one.
--
-- Run once at the end of run_game() under BUILDAT_LUANTI_SELFCHECKS=1, as
-- the checks set it (util/check_lib.sh); see start_check_map() in world.h.

-- Everything here happens this high up, which is above what any mapgen
-- builds and below the map's own limit: a world with terrain in it is a
-- world where the check's own nodes are written into ground that a
-- generator is still filling in another thread, and a generated voxel wins
-- over an empty one -- so the air this writes would stop being air under
-- it. Up here what a generator produces is air, which is what the check
-- wants anyway.
--
-- simplified: a game whose mapgen builds at twenty thousand fails this the
-- way a game whose mapgen builds at two does today. The upgrade path is to
-- wait for the sections the check uses to be generated before writing into
-- them, which needs the check to span steps.
local BASE_Y = 20000

local CHECK_POS = {x = 1, y = BASE_Y + 2, z = 3}
-- Down where a world is generated as soon as it is opened, because what
-- this position is for is what a *generated* voxel of empty space reads as
local EMPTY_POS = {x = 5, y = 6, z = 7}
local AREA_MIN = {x = 10, y = BASE_Y + 10, z = 10}
local AREA_MAX = {x = 14, y = BASE_Y + 14, z = 14}
-- A box that crosses a chunk boundary (every 32 voxels) and a section
-- boundary (every 64), because a region read is one read per chunk stitched
-- together and the stitching is the part that can be wrong. Four corners of
-- it get a node and the read has to find exactly those four.
local SEAM_MIN = {x = 30, y = BASE_Y + 2, z = 62}
local SEAM_MAX = {x = 34, y = BASE_Y + 2, z = 66}
local SEAM_CORNERS = {
	{x = 31, y = BASE_Y + 2, z = 63},
	{x = 32, y = BASE_Y + 2, z = 63},
	{x = 31, y = BASE_Y + 2, z = 64},
	{x = 32, y = BASE_Y + 2, z = 64},
}
local check_name = nil

-- The clock is pure Lua and needs no flush, so it is checked here rather than
-- in a file of its own.
--
-- Everything here is relative to where the clock stands and the whole of it
-- is put back afterwards, because the clock comes out of the save now: a
-- check that started from zero would fail on the second run, and one that
-- left the day it rolled behind would age a world by a day every start.
local function check_clock()
	local t0, g0, d0 = core.__get_clock()
	core.set_timeofday(0.25)
	if math.abs(core.get_timeofday() - 0.25) > 1e-6 then
		error("check_map: set_timeofday did not take")
	end
	-- A day is 24*60*60 game seconds, and time_speed is how many of them a
	-- real second is, so this is a whole day whatever the speed
	local speed = tonumber(core.settings:get("time_speed")) or 72
	-- Unless the clock is stopped, which BUILDAT_LUANTI_FORCE_TIME does on
	-- purpose: there is no length of step that rolls a day at speed zero,
	-- and the hour such a run is at is the point of it
	if speed <= 0 then
		core.__set_clock(t0, g0, d0)
		core.log("verbose", "check_map: the clock is pinned; not stepped")
		return
	end
	-- The clock only: a whole day through __step handed the mods'
	-- globalsteps and timers the day too, and they kept it after the
	-- clock was put back
	core.__advance_clock(24 * 60 * 60 / speed)
	if math.abs(core.get_timeofday() - 0.25) > 1e-3 then
		error("check_map: a whole day did not come back to the same hour: " ..
				tostring(core.get_timeofday()))
	end
	if core.get_day_count() ~= d0 + 1 then
		error("check_map: the day did not roll: " ..
				tostring(core.get_day_count()) .. " from " .. tostring(d0))
	end
	if core.get_gametime() <= g0 then
		error("check_map: game time did not advance")
	end
	core.__set_clock(t0, g0, d0)
	if core.get_day_count() ~= d0 then
		error("check_map: the clock did not go back where it was")
	end
end

-- core.after, which is a mod's way of doing something later and is the thing
-- every timer in a game is built on. It is a globalstep of the vendored
-- builtin's own, so what this checks is the whole path: a step runs the
-- registered globalsteps, after.lua's queue is one of them, and the callback
-- comes back with the arguments it was given.
--
-- Nothing is registered here that outlives the check: after.lua's globalstep
-- is already there and this only puts one job in its queue.
local function check_after()
	local fired, got = false, nil
	core.after(0.05, function(a) fired, got = true, a end, "argument")
	if fired then
		error("check_map: core.after fired before a step")
	end
	core.__step(0.1)
	if not fired then
		error("check_map: core.after did not fire in a step")
	end
	if got ~= "argument" then
		error("check_map: core.after lost its argument: " .. tostring(got))
	end
end

-- A node that is really in the world rather than a hole in it, so that what
-- comes back can be told apart from what an unwritten voxel reads as
-- What this check is about is the map: a voxel written is a voxel read, a
-- dig leaves air, a place leaves the node. So the node it does that with
-- has to be one that does nothing of its own -- and a game may give every
-- one of its nodes something. nodecore's first normal node is placed and is
-- gone the same tick, which failed this check and took the server down with
-- a game that is not broken at all.
local NOT_INERT = {
	"on_place", "after_place_node", "on_construct", "on_destruct",
	"after_destruct", "on_dig", "after_dig_node", "on_timer", "on_punch",
	"on_rightclick", "on_flood", "preserve_metadata", "drop",
}

local function inert(def)
	if def.buildable_to or def.floodable then
		return false
	end
	for _, key in ipairs(NOT_INERT) do
		if def[key] ~= nil then
			return false
		end
	end
	local groups = def.groups or {}
	-- One that falls, floats away or is knocked off is not still there to
	-- be read back either
	if (groups.falling_node or 0) ~= 0 or (groups.attached_node or 0) ~= 0 or
			(groups.float or 0) ~= 0 then
		return false
	end
	return true
end

local function pick_node()
	local names = {}
	local any = {}
	for name, def in pairs(core.registered_nodes) do
		-- The check's own nodes sort early and are not this game's
		-- content; what is written and read back has to be the game's
		if name ~= "air" and name ~= "ignore" and name ~= "unknown" and
				not name:match("^check_map:") and
				(def.drawtype == nil or def.drawtype == "normal") then
			any[#any + 1] = name
			if inert(def) then
				names[#names + 1] = name
			end
		end
	end
	table.sort(names)
	table.sort(any)
	-- A game every one of whose nodes does something still gets checked,
	-- because most of this is about reading and writing rather than placing
	return names[1] or any[1]
end

-- The box everything above is inside, which the module pins while the check
-- runs: nothing else keeps a section up here loaded, and a section the
-- streamer drops takes the check's own nodes with it.
function core.__check_map_box()
	return 0, BASE_Y, 0, 70, BASE_Y + 16, 70
end

function core.__check_map_write()
	check_name = pick_node()
	if not check_name then
		return false
	end
	core.set_node(CHECK_POS, {name = check_name, param2 = 3})
	-- Visible immediately, out of the buffer: the on_placenode callbacks in
	-- the same step will look
	local now = core.get_node(CHECK_POS)
	if now.name ~= check_name then
		error("check_map: the buffer did not answer with " .. check_name)
	end
	if now.param2 ~= 3 then
		error("check_map: param2 came back as " .. tostring(now.param2))
	end
	-- A 2x1x2 patch for the region reads to find, one voxel above the floor
	-- of the box they are asked about, so that a read that ignores its
	-- bounds shows up as the wrong count
	for x = AREA_MIN.x + 1, AREA_MIN.x + 2 do
		for z = AREA_MIN.z + 1, AREA_MIN.z + 2 do
			core.set_node({x = x, y = AREA_MIN.y + 1, z = z},
					{name = check_name})
			-- Air above it, so that find_nodes_in_area_under_air has
			-- something to be right about. The void reads as ignore, not as
			-- air, so without this it would be right by finding nothing.
			core.set_node({x = x, y = AREA_MIN.y + 2, z = z}, {name = "air"})
		end
	end
	for _, p in ipairs(SEAM_CORNERS) do
		core.set_node(p, {name = check_name})
	end
	check_clock()
	check_after()
	return true
end

-- The mapgen seam's map half: a VoxelManip round trip. What can be wrong
-- here and nowhere else is the indexing -- the arrays are x fastest and then
-- y and then z, which is what VoxelArea does its arithmetic in -- so the
-- nodes written are at positions that are all different in every axis and a
-- transposed index puts them somewhere this notices.
local VM_MIN = {x = 20, y = BASE_Y + 2, z = 24}
local VM_MAX = {x = 25, y = BASE_Y + 6, z = 27}
local VM_AT = {x = 21, y = BASE_Y + 3, z = 26}

local function check_vmanip()
	local vm = VoxelManip()
	local emin, emax = vm:read_from_map(VM_MIN, VM_MAX)
	if emin.x ~= VM_MIN.x or emax.z ~= VM_MAX.z then
		error("check_map: the VoxelManip emerged (" .. emin.x .. "," ..
				emin.y .. "," .. emin.z .. ")-(" .. emax.x .. "," ..
				emax.y .. "," .. emax.z .. ")")
	end
	local data = vm:get_data()
	local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
	local id = core.get_content_id(check_name)
	data[area:index(VM_AT.x, VM_AT.y, VM_AT.z)] = id
	vm:set_data(data)
	local param2 = vm:get_param2_data()
	param2[area:index(VM_AT.x, VM_AT.y, VM_AT.z)] = 3
	vm:set_param2_data(param2)
	vm:write_to_map()

	local node = core.get_node(VM_AT)
	if node.name ~= check_name then
		error("check_map: the VoxelManip wrote " .. node.name .. " where " ..
				check_name .. " was meant to go")
	end
	if node.param2 ~= 3 then
		error("check_map: the VoxelManip lost param2: " ..
				tostring(node.param2))
	end
	-- The same index read the other way round would land here
	local swapped = core.get_node({x = VM_AT.z, y = VM_AT.y, z = VM_AT.x})
	if swapped.name == check_name then
		error("check_map: the VoxelManip index is transposed")
	end

	-- And back out through a second one, which is the read half
	local vm2 = VoxelManip(VM_MIN, VM_MAX)
	local d2 = vm2:get_data()
	local a2 = VoxelArea:new{MinEdge = VM_MIN, MaxEdge = VM_MAX}
	if d2[a2:index(VM_AT.x, VM_AT.y, VM_AT.z)] ~= id then
		error("check_map: the VoxelManip read back " ..
				tostring(d2[a2:index(VM_AT.x, VM_AT.y, VM_AT.z)]) ..
				" instead of " .. id)
	end
	if vm2:get_node_at(VM_AT).name ~= check_name then
		error("check_map: get_node_at answered " ..
				vm2:get_node_at(VM_AT).name)
	end
	-- set_node_at and the write that carries it
	vm2:set_node_at(VM_AT, {name = "air"})
	vm2:write_to_map()
	if core.get_node(VM_AT).name ~= "air" then
		error("check_map: set_node_at left " .. core.get_node(VM_AT).name)
	end
end

-- The mapgen's other half: the noise a Lua mapgen shapes its world with.
-- What can be wrong here is that it answers a constant -- which is what the
-- stub did before there was one -- or that the map and the single value
-- disagree, which would make a mod's heightmap and its checks two different
-- worlds.
local function check_noise()
	local np = {offset = 0, scale = 1, seed = 71, octaves = 3,
			persistence = 0.6, spread = {x = 40, y = 40, z = 40}}
	local n = PerlinNoise(np)
	local a, b = n:get_2d({x = 0, y = 0}), n:get_2d({x = 137, y = -91})
	if a == b then
		error("check_map: the noise answers " .. tostring(a) ..
				" everywhere")
	end
	if a ~= a or math.abs(a) > 1000 then
		error("check_map: the noise answered " .. tostring(a))
	end
	-- The map is the same noise over a box, and its first value is the one
	-- at the corner it starts from
	local map = PerlinNoiseMap(np, {x = 4, y = 3, z = 1})
	local flat = map:get_2d_map_flat({x = 0, y = 0})
	if #flat ~= 12 then
		error("check_map: a 4x3 noise map has " .. #flat .. " values")
	end
	if math.abs(flat[1] - a) > 0.05 then
		error("check_map: the map says " .. tostring(flat[1]) ..
				" where the value says " .. tostring(a))
	end
	-- And the nested form is the flat one in rows of x
	local rows = map:get_2d_map({x = 0, y = 0})
	if #rows ~= 3 or #rows[1] ~= 4 then
		error("check_map: the nested noise map is " .. #rows .. " rows of " ..
				tostring(#(rows[1] or {})))
	end
	if rows[1][1] ~= flat[1] or rows[2][1] ~= flat[5] then
		error("check_map: the nested noise map is not the flat one")
	end
	-- One octave of it stays inside -1...1 and averages out to nothing,
	-- which is what makes an offset an offset and a scale a scale. The
	-- hash underneath overflows on purpose, and an overflow the compiler
	-- is allowed to assume away biases every octave upwards -- a terrain
	-- noise of offset 4 and scale 70 then answers 200 everywhere, which is
	-- a world with no surface in it.
	local one = PerlinNoise({offset = 0, scale = 1, seed = 91, octaves = 1,
			persistence = 0.5, spread = {x = 32, y = 32, z = 32}})
	local sum, lo, hi = 0, 1e9, -1e9
	local n_samples = 400
	for i = 1, n_samples do
		local v = one:get_2d({x = i * 13.7, y = i * -7.3})
		sum = sum + v
		lo = math.min(lo, v)
		hi = math.max(hi, v)
	end
	if lo < -1 or hi > 1 then
		error("check_map: one octave of noise ran from " .. tostring(lo) ..
				" to " .. tostring(hi))
	end
	if math.abs(sum / n_samples) > 0.15 then
		error("check_map: one octave of noise averages " ..
				tostring(sum / n_samples))
	end

	-- Two seeds are two worlds
	local other = PerlinNoise({offset = 0, scale = 1, seed = 72,
			octaves = 3, persistence = 0.6,
			spread = {x = 40, y = 40, z = 40}})
	if other:get_2d({x = 0, y = 0}) == a then
		error("check_map: the seed changes nothing")
	end
end

-- The light a node makes of its own, which a Luanti game's mechanics read:
-- what spawns where, what grows underground, what core.get_node_light()
-- answers. voxelworld floods it and this is the round trip -- a room with
-- nothing in it is dark, a torch in it lights the walls around it and dims
-- with distance, and taking the torch away makes it dark again.
--
-- A game with no glowing node of its own skips that half of it, which is
-- the same deal check_map gives a game with no node to write; the lamp
-- below is the check's own and every game gets it.

-- A lamp of the check's own, because the one thing a game's lamp does not
-- reliably have is a shape: one that makes light and lets none through. A
-- torch is that, and so is nodecore's player hand; devtest's lamps are
-- glasslike and transmit. The two go down different paths in voxelworld --
-- light a voxel does not transmit is not stored in it the way a lit voxel
-- stores it, the voxel wears the brightest light beside it so the mesher
-- has something to read off its faces -- and taking the blocking one away
-- has to know what it was making rather than what it holds.
--
-- Called from modloader.lua rather than registered here: this file is read
-- before the vendored builtin defines core.register_node, and the node has
-- to be in the registry with the game's own before the world is built.
function core.__register_check_nodes()
	-- The room the light check builds. It used to be built out of the
	-- game's own node, which is what the rest of the check writes -- and
	-- repixture's is a normal node with sunlight_propagates, so the sky
	-- came through the walls and the room was never dark. What a wall has
	-- to be is opaque, and that is the check's own business.
	core.register_node(":check_map:wall", {
		description = "check_map wall",
		drawtype = "normal",
		paramtype = "none",
		sunlight_propagates = false,
		groups = {not_in_creative_inventory = 1},
	})
	core.register_node(":check_map:lamp", {
		description = "check_map lamp",
		drawtype = "normal",
		paramtype = "light",
		sunlight_propagates = false,
		light_source = 14,
		groups = {not_in_creative_inventory = 1},
	})
end

local LIGHT_MIN = {x = 40, y = BASE_Y + 2, z = 40}
local LIGHT_MAX = {x = 46, y = BASE_Y + 8, z = 46}
local LIGHT_AT = {x = 43, y = BASE_Y + 5, z = 43}

-- The brightest thing in the game that is actually a lamp. "Brightest" on
-- its own is not enough: nodecore registers the player's *hand* as a node
-- with light_source 14 -- nc_player_hand:super, a mesh with paramtype
-- "none" -- and it came first, which is how this check ended up building a
-- room and putting a hand in it.
--
-- So: a node that keeps a light value of its own (paramtype "light", which
-- is what every real lamp sets), that is not a liquid, and that is not one
-- of the shapes a hand or a held thing is drawn as.
local function lamp_like(name, def)
	if name == "ignore" or (def.light_source or 0) <= 0 then
		return false
	end
	if def.drawtype == "liquid" or def.drawtype == "flowingliquid" or
			def.drawtype == "mesh" or def.drawtype == "airlike" then
		return false
	end
	-- The check's own lamp is not this game's content; it is tried
	-- separately
	return def.paramtype == "light" and name ~= "check_map:lamp"
end

local function brightest_node()
	local best, best_light = nil, 0
	local any, any_light = nil, 0
	for name, def in pairs(core.registered_nodes) do
		local l = def.light_source or 0
		local liquid = def.drawtype == "liquid" or
				def.drawtype == "flowingliquid"
		if lamp_like(name, def) and l > best_light then
			best, best_light = name, l
		end
		if l > any_light and name ~= "ignore" and not liquid then
			any, any_light = name, l
		end
	end
	if best then
		return best, best_light
	end
	return any, any_light
end

-- The room is built and dark already; this puts the check's own lamp in it
-- and takes it out again. A lamp that blocks light is the case a flood gets
-- wrong the easy way: the voxel left behind is holding the light the lamp
-- was making, and filling that hole from what it holds spreads the light
-- straight back out. Found through nodecore, whose player hand is exactly
-- this node, and reproduced here so that no particular game is needed.
local function check_blocking_lamp(beside)
	core.set_node(LIGHT_AT, {name = "check_map:lamp"})
	local near = core.get_node_light(beside)
	if near == nil or near < 13 then
		error("check_map: the blocking lamp lights 14 and its neighbour " ..
				"has " .. tostring(near))
	end
	core.set_node(LIGHT_AT, {name = "air"})
	local after = core.get_node_light(beside)
	if after ~= 0 then
		error("check_map: the light of the blocking lamp stayed after it " ..
				"went: " .. tostring(after) .. ". Where it was is now " ..
				core.get_node(LIGHT_AT).name .. ", and what is beside it " ..
				"is " .. core.get_node(beside).name)
	end
end

-- The hour the reading is asked for. Luanti blends the two light banks by
-- the day-night ratio, so what the sky puts on a node comes and goes with
-- the day and what a lamp puts on it does not -- which is what makes
-- get_node_light(pos, 0) mean "light from something other than the sun",
-- the question VoxeLibre's melting, freezing and spawning ABMs ask. See
-- [NODE_LIGHT_HOUR] in doc/plan/luanti_module_plan.md.
--
-- The check's own lamp goes back in the room for this, so `beside` is lit
-- by a lamp and nothing else, and the open air outside the box at BASE_Y is
-- lit by the sky and nothing else.
local function check_light_hour(beside)
	core.set_node(LIGHT_AT, {name = "check_map:lamp"})
	local noon = core.get_node_light(beside, 0.5)
	local midnight = core.get_node_light(beside, 0)
	core.set_node(LIGHT_AT, {name = "air"})
	if noon == nil or noon < 13 or midnight ~= noon then
		error("check_map: lamplight follows the hour -- " ..
				tostring(noon) .. " at noon and " .. tostring(midnight) ..
				" at midnight, where a lamp shines the same at both")
	end

	local outside = {x = LIGHT_MAX.x + 2, y = LIGHT_AT.y, z = LIGHT_AT.z}
	local sky = core.get_natural_light(outside)
	if sky ~= 15 then
		-- Not the hour's fault: something is standing in the open air above
		-- the box, and there is nothing here to ask about the sky
		core.log("verbose", "check_map: no open sky beside the light room")
		return
	end
	if core.get_node_light(outside, 0.5) ~= 15 then
		error("check_map: a node under open sky reads " ..
				tostring(core.get_node_light(outside, 0.5)) .. " at noon")
	end
	-- 175 thousandths of 15, Luanti's own floor; the point is that it is
	-- nowhere near the 12 the melting ABM wants
	if core.get_node_light(outside, 0) ~= 2 then
		error("check_map: a node under open sky reads " ..
				tostring(core.get_node_light(outside, 0)) .. " at midnight, " ..
				"where the sun is not shining on it")
	end
end

local function check_light()
	local lamp, level = brightest_node()
	if lamp and level < 3 then
		lamp = nil
	end
	if not lamp then
		core.log("verbose", "check_map: no node of this game makes light")
	end
	local wall = "check_map:wall"
	-- A solid box, hollowed out: somewhere the sky does not reach
	for x = LIGHT_MIN.x, LIGHT_MAX.x do
		for y = LIGHT_MIN.y, LIGHT_MAX.y do
			for z = LIGHT_MIN.z, LIGHT_MAX.z do
				local edge = (x == LIGHT_MIN.x or x == LIGHT_MAX.x or
						y == LIGHT_MIN.y or y == LIGHT_MAX.y or
						z == LIGHT_MIN.z or z == LIGHT_MAX.z)
				core.set_node({x = x, y = y, z = z},
						{name = edge and wall or "air"})
			end
		end
	end

	local beside = {x = LIGHT_AT.x + 1, y = LIGHT_AT.y, z = LIGHT_AT.z}
	local further = {x = LIGHT_AT.x + 2, y = LIGHT_AT.y + 1, z = LIGHT_AT.z}
	-- The room's relight is a tick's work under the tick's budget, and
	-- the liquids flooding a fresh world's caves keep that queue long
	-- ([LIQUID_FLOW]): the room's box relit now, then a few steps for
	-- what the flood may still carry into it
	core.fix_light(LIGHT_MIN, LIGHT_MAX)
	local dark = core.get_node_light(beside)
	for _ = 1, 50 do
		if dark ~= nil and dark == 0 then
			break
		end
		core.__step(0.01)
		dark = core.get_node_light(beside)
	end
	if dark == nil or dark > 0 then
		-- What the room is made of, for the line: a wall that is not
		-- there and a room that is not air are different faults
		local holes, filled = 0, {}
		for x = LIGHT_MIN.x, LIGHT_MAX.x do
			for y = LIGHT_MIN.y, LIGHT_MAX.y do
				for z = LIGHT_MIN.z, LIGHT_MAX.z do
					local edge = (x == LIGHT_MIN.x or x == LIGHT_MAX.x or
							y == LIGHT_MIN.y or y == LIGHT_MAX.y or
							z == LIGHT_MIN.z or z == LIGHT_MAX.z)
					local n = core.get_node({x = x, y = y, z = z}).name
					if edge and n ~= wall then
						holes = holes + 1
					elseif not edge and n ~= "air" then
						filled[n] = (filled[n] or 0) + 1
					end
				end
			end
		end
		local parts = {}
		for n, c in pairs(filled) do
			parts[#parts + 1] = n .. ":" .. c
		end
		error("check_map: a room with nothing in it is lit: " ..
				tostring(dark) .. " (" .. holes .. " holes in the walls; inside: " ..
				(#parts > 0 and table.concat(parts, ",") or "air") ..
				"; beside is " .. core.get_node(beside).name .. ")")
	end

	if lamp then
		core.set_node(LIGHT_AT, {name = lamp})
		-- The lamp's flood is voxelworld's at the write's commit, and a
		-- section whose light is stale takes it in the relight a tick
		-- later ([DIG_LIGHT]); a few steps, until the neighbour is lit
		-- or it plainly is not
		local near = core.get_node_light(beside)
		for _ = 1, 50 do
			if near ~= nil and near >= level - 1 then
				break
			end
			core.__step(0.01)
			near = core.get_node_light(beside)
		end
		local far = core.get_node_light(further)
		if near == nil or near < level - 1 then
			error("check_map: " .. lamp .. " lights " .. level ..
					" and its neighbour has " .. tostring(near))
		end
		if far == nil or far >= near or far == 0 then
			error("check_map: the light does not dim with distance: " ..
					tostring(near) .. " then " .. tostring(far))
		end

		-- And taking it away takes the light with it, which is the direction
		-- that needs the unlighting pass rather than the spreading one
		core.set_node(LIGHT_AT, {name = "air"})
		local after = core.get_node_light(beside)
		if after ~= 0 then
			-- Which of the two it is matters: a light that will not go is an
			-- engine fault, and a game that put something back where the lamp
			-- was is a game doing its job. set_node() runs on_destruct and
			-- on_construct, so a game gets a say in both.
			local ldef = core.registered_nodes[lamp] or {}
			error("check_map: the light stayed after the lamp went: " ..
					tostring(after) .. ". Where it was is now " ..
					core.get_node(LIGHT_AT).name .. ", and what is beside it is "
					.. core.get_node(beside).name .. ". The lamp was " .. lamp ..
					" (light_source " .. tostring(ldef.light_source) ..
					", drawtype " .. tostring(ldef.drawtype) ..
					", paramtype " .. tostring(ldef.paramtype) ..
					", sunlight_propagates " ..
					tostring(ldef.sunlight_propagates) ..
					"), and the wall is " .. tostring(wall))
		end
	end

	check_blocking_lamp(beside)
	check_light_hour(beside)

	for x = LIGHT_MIN.x, LIGHT_MAX.x do
		for y = LIGHT_MIN.y, LIGHT_MAX.y do
			for z = LIGHT_MIN.z, LIGHT_MAX.z do
				core.set_node({x = x, y = y, z = z}, {name = "air"})
			end
		end
	end
end

-- What a voxel nobody has built in reads as. A singlenode world is air
-- everywhere -- what Luanti's own MapgenSinglenode leaves, and what every
-- mod that looks before it places is written against -- so that is where
-- the claim is made; a world with a real mapgen has terrain there instead,
-- and what it has is that mapgen's business. Either way a voxel outside
-- the world altogether is ignore.
local function check_unbuilt()
	local mgname = core.settings:get("mg_name") or "singlenode"
	if mgname == "singlenode" then
		local before = core.get_node(EMPTY_POS)
		if before.name ~= "air" then
			error("check_map: an unbuilt voxel reads as " .. before.name)
		end
	end
	local outside = core.get_node({x = 0, y = 30000, z = 0})
	if outside.name ~= "ignore" then
		error("check_map: a voxel outside the world reads as " ..
				outside.name)
	end
end

function core.__check_map_read()
	check_unbuilt()
	local node = core.get_node(CHECK_POS)
	if node.name ~= check_name then
		error("check_map: voxelworld answered with " .. node.name ..
				" instead of " .. check_name)
	end
	if node.param2 ~= 3 then
		error("check_map: param2 was lost in the flush: " ..
				tostring(node.param2))
	end
	-- The id is the VoxelRegistry id, and the registry was built from the
	-- same numbering, so these have to agree or nothing else here is true
	local id = core.get_content_id(check_name)
	local raw_id = core.get_node_raw(CHECK_POS.x, CHECK_POS.y, CHECK_POS.z)
	if raw_id ~= id then
		error("check_map: content id " .. id .. " came back as " .. raw_id)
	end

	-- The region reads, over what the write half put there
	local found, counts = core.find_nodes_in_area(AREA_MIN, AREA_MAX,
			{check_name})
	if #found ~= 4 then
		error("check_map: find_nodes_in_area found " .. #found ..
				" of a patch of 4")
	end
	if counts[check_name] ~= 4 then
		error("check_map: the counts say " .. tostring(counts[check_name]))
	end
	for _, p in ipairs(found) do
		if p.y ~= AREA_MIN.y + 1 then
			error("check_map: a position came back at y=" .. p.y)
		end
	end
	local near = core.find_node_near(AREA_MIN, 4, {check_name})
	if not near then
		error("check_map: find_node_near found nothing")
	end
	if math.abs(near.x - (AREA_MIN.x + 1)) > 1 or
			math.abs(near.z - (AREA_MIN.z + 1)) > 1 then
		error("check_map: find_node_near came back with a far one")
	end
	-- Digging and placing, which are the builtin's own node_dig and
	-- item_place with nobody doing them. What is checked here is what they
	-- do to the map; that the callbacks around them run is checked in
	-- builtin/luanti/minimal_game, because a registered definition refuses
	-- new keys -- register.lua sets __newindex to ignore them, on purpose --
	-- so a callback has to be declared where the node is registered.
	do
		local p = {x = CHECK_POS.x + 4, y = CHECK_POS.y, z = CHECK_POS.z}
		-- The node under it is what item_place_node places against, and it
		-- has to be something rather than the void
		core.set_node({x = p.x, y = p.y - 1, z = p.z}, {name = check_name})
		core.set_node(p, {name = "air"})

		-- Whether the game let it happen is the game's business, and not
		-- every game lets a node be placed at all: nodecore governs
		-- placement itself and core.place_node() there leaves air, which is
		-- the game working rather than the map failing. What the map owes
		-- is set_node and get_node, and those are checked above and below
		-- this and are fatal. So a placement the game refused is said once
		-- and the rest of the check goes on -- with set_node putting the
		-- node there, so that what follows has something to dig.
		--
		-- And a game can throw rather than refuse, which is the same thing
		-- said less politely: nothing is digging here, so a mod that takes
		-- the digger for granted -- voxelgarden's physics indexes it on the
		-- first line -- errors where a player would have satisfied it.
		local ok, placed = pcall(core.place_node, p, {name = check_name})
		placed = ok and placed and core.get_node(p).name == check_name
		if not placed then
			core.log("warning", "check_map: this game does not let " ..
					check_name .. " be placed with core.place_node() -- it " ..
					(ok and ("left " .. core.get_node(p).name) or
					("threw " .. tostring(placed))) ..
					". That is a game's own rule and not a map fault; the " ..
					"rest of the check carries on with set_node().")
			core.set_node(p, {name = check_name})
		end
		if core.get_node(p).name ~= check_name then
			error("check_map: set_node could not put " .. check_name ..
					" down either; it left " .. core.get_node(p).name)
		end

		local ok_dig, dug = pcall(core.dig_node, p)
		dug = ok_dig and dug and core.get_node(p).name == "air"
		if not dug then
			core.log("warning", "check_map: this game does not let " ..
					check_name .. " be dug with core.dig_node() -- it " ..
					(ok_dig and ("left " .. core.get_node(p).name) or
					("threw " .. tostring(dug))) ..
					". The same goes: a game's own rule, not a map fault.")
			core.set_node(p, {name = "air"})
		end
		if core.get_node(p).name ~= "air" then
			error("check_map: set_node could not clear " .. check_name ..
					" either; it left " .. core.get_node(p).name)
		end

		core.swap_node(p, {name = check_name})
		if core.get_node(p).name ~= check_name then
			error("check_map: swap_node left " .. core.get_node(p).name)
		end

		core.set_node(p, {name = "air"})
		core.set_node({x = p.x, y = p.y - 1, z = p.z}, {name = "air"})
	end

	-- Nothing matches a name that is not there
	local none = core.find_nodes_in_area(AREA_MIN, AREA_MAX,
			{"check_map:nothing"})
	if #none ~= 0 then
		error("check_map: found " .. #none .. " of a node that does not exist")
	end
	-- Every one of the patch is under one of the air voxels above it, and
	-- this is the read whose indexing runs down a column rather than along
	-- the array
	local under = core.find_nodes_in_area_under_air(AREA_MIN, AREA_MAX,
			{check_name})
	if #under ~= 4 then
		error("check_map: find_nodes_in_area_under_air found " .. #under ..
				" of a patch of 4")
	end
	-- And a box whose top row is the patch itself: the air above it is
	-- outside the box, and the read has to look one row past it
	local top = core.find_nodes_in_area_under_air(AREA_MIN,
			{x = AREA_MAX.x, y = AREA_MIN.y + 1, z = AREA_MAX.z}, {check_name})
	if #top ~= 4 then
		error("check_map: find_nodes_in_area_under_air found " .. #top ..
				" of a patch of 4 on the box's top row")
	end
	for _, p in ipairs(under) do
		if p.y ~= AREA_MIN.y + 1 then
			error("check_map: under_air came back at y=" .. p.y)
		end
	end
	-- Nothing is said here about air under air: singlenode fills the world
	-- with it, so most of the box is exactly that. What the count above is
	-- for -- that the read keeps to the box it was given -- is what the
	-- patch of four proves.

	-- The four either side of a chunk and a section boundary, out of one
	-- read that spans both
	local seam = core.find_nodes_in_area(SEAM_MIN, SEAM_MAX, {check_name})
	if #seam ~= #SEAM_CORNERS then
		error("check_map: the read across a chunk and a section boundary " ..
				"found " .. #seam .. " of " .. #SEAM_CORNERS)
	end
	for _, want in ipairs(SEAM_CORNERS) do
		local got = false
		for _, p in ipairs(seam) do
			if p.x == want.x and p.y == want.y and p.z == want.z then
				got = true
			end
		end
		if not got then
			error("check_map: the read across the boundaries lost (" ..
					want.x .. "," .. want.y .. "," .. want.z .. ")")
		end
	end

	core.set_node(CHECK_POS, {name = "air"})
	for x = AREA_MIN.x + 1, AREA_MIN.x + 2 do
		for z = AREA_MIN.z + 1, AREA_MIN.z + 2 do
			core.set_node({x = x, y = AREA_MIN.y + 1, z = z}, {name = "air"})
		end
	end
	for _, p in ipairs(SEAM_CORNERS) do
		core.set_node(p, {name = "air"})
	end
	check_vmanip()
	check_noise()
	check_light()

	core.log("verbose", "check_map: " .. check_name ..
			" survived the flush, and the region reads found it")

	-- What only the game can check: anything that has to be registered while
	-- the mods load, since the registries freeze once they have. A game that
	-- defines this gets called here, with the map flushed and readable.
	if core.__game_check then
		-- Nobody is in the world, so nothing would be active; a game's
		-- rules, timers and objects step over the whole map for this
		core.__active_everywhere = true
		local ok, err = pcall(core.__game_check)
		core.__active_everywhere = false
		if not ok then
			error(err, 0)
		end
	end
end

-- vim: set noet ts=4 sw=4:
