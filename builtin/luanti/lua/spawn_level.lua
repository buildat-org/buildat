-- Buildat: builtin/luanti/lua/spawn_level.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- core.get_spawn_level(): where a player can stand. Run by bootstrap.lua
-- with the one of its locals this reads ([FILE_SPLITS_1019]: moved out as
-- it was).

local region_names = ...

-- Where the ground is at a point, which is what a player who has never been
-- here starts on top of. nil means nobody can stand here.
--
-- Luanti asks two things in this order and so does this: first the mapgen,
-- which answers out of its own noise for a part of the world nobody has
-- generated -- Server::findSpawnPos() does that because at the moment a
-- player joins the map around the origin is half made, and a map read then
-- answers about the world as it was rather than as it will be -- and then
-- the map, for the two nodes of room a player needs. A mapgen that says
-- "not here" (a river, or a surface under water) is not argued with.
local SPAWN_SCAN_BOTTOM = -256
local SPAWN_SCAN_TOP = 320
-- How much room a player needs above the ground to stand in it
local SPAWN_HEADROOM = 2
-- How far above the mapgen's answer to look for that room, which is
-- Luanti's own number
local SPAWN_SEARCH_UP = 8

-- What a player can be inside: air, anything a game made unwalkable, and
-- ignore -- because an ungenerated part of the world has no obstruction in
-- it, which is Luanti's reasoning and what lets a spawn be chosen before
-- the ground below it exists.
local function is_empty_for_spawn(name)
	if name == "air" or name == "ignore" then
		return true
	end
	local def = core.registered_nodes[name]
	if def == nil then
		return false
	end
	return def.walkable == false or def.drawtype == "airlike"
end

-- The map's own answer: from y upwards, the first place with room for a
-- player, standing in the lower of the empty nodes. nil if the column has
-- no such place in reach.
local function spawn_level_in_map(x, y, z, up)
	local names = region_names(x, y, z, x, y + up, z)
	local room = 0
	for i = 1, #names do
		if is_empty_for_spawn(names[i]) then
			room = room + 1
			if room >= SPAWN_HEADROOM then
				-- The lower of the two: index i is at y + i - 1
				return y + i - SPAWN_HEADROOM
			end
		else
			room = 0
		end
	end
	return nil
end

-- The map's answer for a whole column: the surface, walked from the top so
-- that what is found is the ground and not the roof of the first cave. nil
-- if the column has no ground in it, which for an ungenerated column is
-- what it always says.
local function spawn_level_in_column(x, z)
	local names = region_names(x, SPAWN_SCAN_BOTTOM, z, x, SPAWN_SCAN_TOP, z)
	local room = 0
	for i = #names, 1, -1 do
		local name = names[i]
		local def = core.registered_nodes[name]
		if name == "ignore" or def == nil then
			-- Not generated, so nothing can be said about what is under it
			room = 0
		elseif def.walkable == false or name == "air" then
			room = room + 1
		else
			if room >= SPAWN_HEADROOM then
				-- The voxel above this one: index i is at
				-- SPAWN_SCAN_BOTTOM + i - 1, so this is standing on it
				return SPAWN_SCAN_BOTTOM + i
			end
			room = 0
		end
	end
	return nil
end

-- Where a player can stand above (x, z), or nil.
--
-- deep says whether the map's whole column may be walked when the mapgen's
-- answer does not match it. That walk is six hundred voxels of map read, so
-- the spawn search asks for it at a handful of points rather than at the
-- thousands it tries -- see find_spawn_pos() in lua/entity.lua.
function core.get_spawn_level(x, z, deep)
	x, z = math.floor(x + 0.5), math.floor(z + 0.5)
	local from_mapgen = __luanti_spawn_level and __luanti_spawn_level(x, z)
	if from_mapgen then
		local level = spawn_level_in_map(x, from_mapgen, z, SPAWN_SEARCH_UP)
		if level then
			return level
		end
		if not deep then
			return nil
		end
		-- The mapgen said where its own terrain is and the map does not
		-- agree. A game that builds its world in core.register_on_generated
		-- over what the mapgen made -- VoxeLibre does, and its ground can be
		-- tens of nodes from v7's -- is that case, so the column itself is
		-- asked. An ungenerated column answers nil and the search comes back
		-- to it once there is something there.
		return spawn_level_in_column(x, z)
	end
	if core.__mapgen_name() ~= "singlenode" then
		-- There is a mapgen and it said "not here", which is its answer to
		-- give: a river, or a surface under water
		return nil
	end
	-- No mapgen to ask -- a singlenode world, whose ground is whatever a
	-- mod built
	return spawn_level_in_column(x, z)
end
-- vim: set noet ts=4 sw=4:
