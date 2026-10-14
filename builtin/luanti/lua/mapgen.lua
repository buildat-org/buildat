-- Buildat: builtin/luanti/lua/mapgen.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- What a vendored mapgen is told: which mapgen, the node properties, the
-- biomes, ores and decorations, gennotify. Run by bootstrap.lua with the
-- four of its locals this reads ([SPLITS]: moved out as it was).

local DEFAULTS, game_path, parse_conf, read_file = ...

-- And for a new world, what its game asks for: Luanti's world-creation
-- dialog offers only game.conf's allowed_mapgens and none of its
-- disallowed_mapgens, with the game's minetest.conf choice selected, and
-- prang and citadel name singlenode nowhere else.
local function game_mapgen_name()
	local conf = parse_conf(read_file(game_path .. "/game.conf"))
	local function list(s)
		local out = {}
		for name in (s or ""):gmatch("[^,%s]+") do
			out[#out + 1] = name
		end
		return out
	end
	local allowed, disallowed = list(conf.allowed_mapgens),
			list(conf.disallowed_mapgens)
	local function ok(name)
		for _, d in ipairs(disallowed) do
			if d == name then return false end
		end
		if #allowed == 0 then return true end
		for _, a in ipairs(allowed) do
			if a == name then return true end
		end
		return false
	end
	-- The dialog's order, valleys first as the default
	local candidates = {DEFAULTS["mg_name"], "valleys", "v7", "carpathian",
			"v5", "flat", "fractal", "singlenode", "v6"}
	for _, name in ipairs(candidates) do
		if ok(name) then return name end
	end
end

function core.__mapgen_name(world_is_new)
	return core.settings.values["mg_name"] or
			(world_is_new and game_mapgen_name()) or ""
end

-- What a mapgen asks about a node, by content id. Without these the shim on
-- the other side guesses from the name -- everything that is not air is
-- solid ground -- and a cave carved through a chest is what that guess
-- costs. Flat, nine values a node -- eight numbers and the drawtype -- in
-- the order luanti_mapgen reads them.
function core.__mapgen_node_props()
	local out = {}
	for id, name in pairs(core.__content_names) do
		local def = core.registered_nodes[name]
		if def then
			local liquid = 0
			if def.liquidtype == "flowing" then
				liquid = 1
			elseif def.liquidtype == "source" then
				liquid = 2
			end
			out[#out + 1] = id
			out[#out + 1] = (def.walkable ~= false) and 1 or 0
			out[#out + 1] = (def.is_ground_content ~= false) and 1 or 0
			out[#out + 1] = def.floodable and 1 or 0
			-- Luanti's own rule, as no definition carries the field: light
			-- passes what stores it. Read as a field, it was false for
			-- every node, air included, and the mapgen's spread lit
			-- nothing sideways -- the ground under a tree was black
			out[#out + 1] = (def.paramtype == "light" or
					def.sunlight_propagates) and 1 or 0
			out[#out + 1] = def.sunlight_propagates and 1 or 0
			out[#out + 1] = liquid
			out[#out + 1] = def.drawtype or "normal"
			out[#out + 1] = (def.paramtype == "light") and 1 or 0
		end
	end
	return out
end

-- Which biome is which, by the number the mapgen's own manager gave it; see
-- core.__mapgen_biomes() below, which is where the numbering is decided.
local biome_name_of_index = {[0] = "default"}
local biome_index_of_name = {}

-- An ore's or a decoration's biomes as names, from whatever Luanti's
-- get_biome_list takes: nil, one name, one biome table, a biome number, or
-- a list of those. A single name read as nothing would put the thing in
-- every biome.
local function biome_names(v)
	local function one(b)
		if type(b) == "number" then
			return biome_name_of_index[b]
		elseif type(b) == "table" then
			return b.name
		end
		return b
	end
	if v == nil then
		return {}
	elseif type(v) ~= "table" or v.name ~= nil then
		return {one(v)}
	end
	local out = {}
	for _, b in pairs(v) do
		out[#out + 1] = one(b)
	end
	return out
end

-- Where the mapgen's noise puts a biome, whether or not anything has been
-- generated there -- which is what Luanti answers too, its own
-- get_biome_data() asking the biome generator rather than the map.
function core.get_biome_data(pos)
	if __luanti_biome_at == nil then
		return nil
	end
	-- Rounded the way every position here is, and written out rather than
	-- through to_pos(), which is declared further down this file
	local index, heat, humidity = __luanti_biome_at(
			math.floor(pos.x + 0.5), math.floor(pos.y + 0.5),
			math.floor(pos.z + 0.5))
	if index == nil then
		return nil
	end
	return {biome = index, heat = heat, humidity = humidity}
end

function core.get_biome_name(index)
	return biome_name_of_index[index]
end

function core.get_biome_id(name)
	return biome_index_of_name[name]
end

function core.get_heat(pos)
	local data = core.get_biome_data(pos)
	return data and data.heat or nil
end

function core.get_humidity(pos)
	local data = core.get_biome_data(pos)
	return data and data.humidity or nil
end

-- The biomes a game registered, with every node name already turned into
-- the id it means: what the mapgen builds its world out of.
--
-- A node the biome does not name falls back the way Luanti's
-- Biome::resolveNodeNames() falls back -- to a mapgen alias, and only then
-- to air or to ignore. This is not a nicety: generateBiomes() writes
-- c_stone down the whole column under the surface, so a biome whose c_stone
-- came out as ignore erases the terrain the mapgen just made. devtest names
-- only node_top, node_filler and node_riverbed.
function core.__mapgen_biomes()
	local ids = core.__content_ids_by_name()
	local air = ids["air"] or 0
	local ignore = 0
	-- The name the biome gave, then the alias Luanti falls back to, then
	-- the last resort. A name that resolves to nothing is said out loud,
	-- because a world made of the wrong node is hard to read backwards.
	local function id_of(name, alias, last_resort)
		if name ~= nil and name ~= "" then
			local id = ids[name]
			if id then
				return id
			end
			core.log("warning", "Biome node \"" .. name ..
					"\" is not registered; falling back to " ..
					(alias or tostring(last_resort)))
		end
		if alias and ids[alias] then
			return ids[alias]
		end
		return last_resort
	end
	local out = {}
	-- The order they cross in is the order the manager numbers them in, and
	-- the manager's own default biome is index 0 -- so a game's first is 1.
	-- Nothing else knows that mapping, which is why it is kept here for
	-- core.get_biome_name() and core.get_biome_id().
	biome_name_of_index = {[0] = "default"}
	biome_index_of_name = {}
	for _, b in ipairs(core.__mapgen_registered.biome) do
		local index = #out + 1
		local min_pos, max_pos = b.min_pos or {}, b.max_pos or {}
		biome_name_of_index[index] = b.name or ""
		biome_index_of_name[b.name or ""] = index
		out[#out + 1] = {
			name = b.name or "",
			c_top = id_of(b.node_top, "mapgen_stone", air),
			c_filler = id_of(b.node_filler, "mapgen_stone", air),
			c_stone = id_of(b.node_stone, "mapgen_stone", air),
			c_water_top = id_of(b.node_water_top, "mapgen_water_source", air),
			c_water = id_of(b.node_water, "mapgen_water_source", air),
			c_river_water = id_of(b.node_river_water,
					"mapgen_river_water_source", air),
			c_riverbed = id_of(b.node_riverbed, "mapgen_stone", air),
			-- The dust and the dungeon nodes fall back to ignore, which
			-- is what Luanti does with them: a dungeon whose biome names
			-- no wall takes the mapgen_cobble alias instead, and that
			-- choice is the mapgen's rather than the biome's
			c_dust = id_of(b.node_dust, nil, ignore),
			c_dungeon = id_of(b.node_dungeon, nil, ignore),
			c_dungeon_alt = id_of(b.node_dungeon_alt, nil, ignore),
			c_dungeon_stair = id_of(b.node_dungeon_stair, nil, ignore),
			depth_top = b.depth_top or 0,
			depth_filler = b.depth_filler or 0,
			depth_water_top = b.depth_water_top or 0,
			depth_riverbed = b.depth_riverbed or 0,
			-- As Luanti: min_pos and max_pos bound a biome on all three
			-- axes, and y_min and y_max replace their Y. VoxeLibre's End
			-- island is bounded only by them; read as unbounded it is a
			-- biome of air at the overworld's origin.
			x_min = min_pos.x or -31000,
			x_max = max_pos.x or 31000,
			y_min = b.y_min or min_pos.y or -31000,
			y_max = b.y_max or max_pos.y or 31000,
			z_min = min_pos.z or -31000,
			z_max = max_pos.z or 31000,
			heat_point = b.heat_point or 0,
			humidity_point = b.humidity_point or 0,
			vertical_blend = b.vertical_blend or 0,
			weight = b.weight or 1,
		}
	end
	return out
end

-- The ores a game registered, for the manager a mapgen asks after it has
-- made the terrain. The node names are turned into ids here, the way the
-- biomes' are; the biome names are left alone, because which number a biome
-- is depends on the order they cross in and that is the other side's to
-- know.
function core.__mapgen_ores()
	local ids = core.__content_ids_by_name()
	local function id_of(name)
		if name == nil or name == "" then
			return nil
		end
		return ids[name]
	end
	-- A noise as a mod wrote it, with the fields Luanti's read_noiseparams
	-- reads and its defaults where a mod left one out
	local function np_of(np)
		if type(np) ~= "table" then
			return {given = false}
		end
		local spread = np.spread or {}
		return {
			given = true,
			offset = np.offset or 0,
			scale = np.scale or 1,
			spread_x = spread.x or 250,
			spread_y = spread.y or 250,
			spread_z = spread.z or 250,
			seed = np.seed or 0,
			octaves = np.octaves or 3,
			persist = np.persist or np.persistence or 0.6,
			lacunarity = np.lacunarity or 2,
			flags = np.flags or "defaults",
		}
	end
	local out = {}
	for _, o in ipairs(core.__mapgen_registered.ore) do
		local c_ore = id_of(o.ore)
		if c_ore == nil then
			core.log("warning", "Ore \"" .. tostring(o.ore) ..
					"\" is not a registered node; the ore is dropped")
		else
			local wherein = {}
			local names = o.wherein
			if type(names) == "string" then
				names = {names}
			end
			for _, name in ipairs(names or {}) do
				local group = string.match(name, "^group:(.*)$")
				if group then
					for _, id in ipairs(core.__group_ids(group)) do
						wherein[#wherein + 1] = id
					end
				else
					local id = id_of(name)
					if id then
						wherein[#wherein + 1] = id
					end
				end
			end
			local biomes = biome_names(o.biomes)
			out[#out + 1] = {
				-- Only the name the mod gave, as in Luanti: the manager
				-- refuses a second ore by one name, and a game registers
				-- the same node as several ores
				name = o.name or "",
				type = o.ore_type or "scatter",
				c_ore = c_ore,
				c_wherein = wherein,
				clust_scarcity = o.clust_scarcity or 1,
				clust_num_ores = o.clust_num_ores or 1,
				clust_size = o.clust_size or 0,
				-- height_min and height_max are what Luanti called these
				-- before it called them y_min and y_max
				y_min = o.y_min or o.height_min or -31000,
				y_max = o.y_max or o.height_max or 31000,
				ore_param2 = o.ore_param2 or 0,
				flags = o.flags or "",
				nthresh = o.noise_threshold or o.noise_threshhold or 0,
				np = np_of(o.noise_params),
				biomes = biomes,
				column_height_min = o.column_height_min or 1,
				column_height_max = o.column_height_max or 0,
				column_midpoint_factor = o.column_midpoint_factor or 0.5,
				np_puff_top = np_of(o.np_puff_top),
				np_puff_bottom = np_of(o.np_puff_bottom),
				random_factor = o.random_factor or 1,
				np_stratum_thickness = np_of(o.np_stratum_thickness),
				stratum_thickness = o.stratum_thickness or 8,
			}
		end
	end
	return out
end

-- The decorations a game registered: what grows on the terrain once the
-- biomes and the ores are done with it. A schematic is either a .mts file,
-- which the other side's vendored reader opens, or the arrays a mod wrote in
-- Lua, which cross as ids and probabilities.
function core.__mapgen_decorations()
	local ids = core.__content_ids_by_name()
	local function id_of(name)
		if name == nil or name == "" then
			return nil
		end
		return ids[name]
	end
	-- "group:grass_block" is every node in the group, which is how
	-- VoxeLibre names what its trees stand on
	local function id_list(names)
		if type(names) == "string" then
			names = {names}
		end
		local out = {}
		for _, name in ipairs(names or {}) do
			local group = string.match(name, "^group:(.*)$")
			if group then
				for _, id in ipairs(core.__group_ids(group)) do
					out[#out + 1] = id
				end
			else
				local id = id_of(name)
				if id then
					out[#out + 1] = id
				end
			end
		end
		return out
	end
	local function np_of(np)
		if type(np) ~= "table" then
			return {given = false}
		end
		local spread = np.spread or {}
		return {
			given = true,
			offset = np.offset or 0,
			scale = np.scale or 1,
			spread_x = spread.x or 250,
			spread_y = spread.y or 250,
			spread_z = spread.z or 250,
			seed = np.seed or 0,
			octaves = np.octaves or 3,
			persist = np.persist or np.persistence or 0.6,
			lacunarity = np.lacunarity or 2,
			flags = np.flags or "defaults",
		}
	end
	-- A schematic as a mod gave it: a file name, a table of its own, or a
	-- handle we do not keep. Luanti's node data is x fastest and then y and
	-- then z, which is the order a mod writes its "data" array in.
	local function schematic_of(sch, replacements)
		local out = {given = false}
		-- A handle, which is what core.register_schematic() answered with:
		-- Luanti keeps the schematic and hands back an integer, and a mod
		-- that builds one in Lua uses that wherever a schematic goes. This
		-- is the shape nodecore's trees arrive in, through its own
		-- ezschematic() helper.
		if type(sch) == "number" then
			local kept = core.__registered_schematics[sch]
			if kept == nil then
				return out
			end
			-- The registration's own replacements are under whatever the
			-- caller asks for now, which is the order Luanti reads them in
			local merged = {}
			for from, to in pairs(kept.replacements or {}) do
				merged[from] = to
			end
			for from, to in pairs(replacements or {}) do
				merged[from] = to
			end
			sch = kept.schematic
			replacements = merged
		end
		if type(sch) == "string" then
			out.given = true
			out.file = sch
		elseif type(sch) == "table" and sch.size and sch.data then
			out.given = true
			out.size_x = sch.size.x
			out.size_y = sch.size.y
			out.size_z = sch.size.z
			-- The names, and one index into them per node: the condensed
			-- form a .mts file holds, so that the other side resolves an
			-- inline schematic through the same resolver a file goes
			-- through -- which is what gives it the node definitions it
			-- needs when it is placed
			out.node_names = {}
			out.ids = {}
			out.param1 = {}
			out.param2 = {}
			local index_of = {}
			for i, node in ipairs(sch.data) do
				local name = node.name or "air"
				local index = index_of[name]
				if index == nil then
					out.node_names[#out.node_names + 1] = name
					index = #out.node_names - 1
					index_of[name] = index
				end
				out.ids[i] = index
				-- A table's prob is 0-255 and the byte is half of it, with
				-- force_place as the byte's high bit (read_schematic_def:
				-- `param1 >>= 1`, then the flag); 255 handed on whole read
				-- as always-and-force, and every such node was placed over
				-- whatever stood there (2026-09-22)
				local prob = node.param1 or node.prob or 255
				out.param1[i] = math.floor(math.min(255, prob) / 2) +
						(node.force_place and 128 or 0)
				out.param2[i] = node.param2 or 0
			end
			out.yslice_prob = {}
			for _, slice in ipairs(sch.yslice_prob or {}) do
				if slice.ypos ~= nil then
					out.yslice_prob[slice.ypos + 1] =
							math.floor(math.min(255, slice.prob or 255) / 2)
				end
			end
		end
		out.replacements = {}
		for from, to in pairs(replacements or {}) do
			out.replacements[tostring(from)] = tostring(to)
		end
		return out
	end
	-- An L-system tree's own definition, with its nodes resolved to ids the
	-- way everything else here crosses. It is the same definition
	-- core.spawn_tree() takes; what places it is the vendored generator's
	-- own treegen, on the generator's thread.
	local function ltree_of(t)
		if type(t) ~= "table" then
			return {given = false}
		end
		local id_of = function(name)
			local id = core.__content_ids[core.__aliases[name] or name or ""]
			return id or 0
		end
		return {
			given = true,
			axiom = tostring(t.axiom or ""),
			rules_a = tostring(t.rules_a or ""),
			rules_b = tostring(t.rules_b or ""),
			rules_c = tostring(t.rules_c or ""),
			rules_d = tostring(t.rules_d or ""),
			c_trunk = id_of(t.trunk),
			c_leaves = id_of(t.leaves),
			c_leaves2 = id_of(t.leaves2 or t.leaves),
			c_fruit = id_of(t.fruit),
			leaves2_chance = t.leaves2_chance or 0,
			angle = t.angle or 0,
			iterations = t.iterations or 2,
			random_level = t.random_level or 0,
			trunk_type = tostring(t.trunk_type or "single"),
			thin_branches = t.thin_branches and true or false,
			fruit_chance = t.fruit_chance or 0,
			seed = t.seed or 0,
			explicit_seed = t.seed ~= nil,
		}
	end
	local out = {}
	for _, d in ipairs(core.__mapgen_registered.decoration) do
		out[#out + 1] = {
			name = d.name or "",
			type = d.deco_type or "simple",
			c_place_on = id_list(d.place_on),
			sidelen = d.sidelen or 8,
			fill_ratio = d.fill_ratio or 0.02,
			y_min = d.y_min or d.height_min or -31000,
			y_max = d.y_max or d.height_max or 31000,
			flags = d.flags or "",
			np = np_of(d.noise_params),
			biomes = biome_names(d.biomes),
			c_spawnby = id_list(d.spawn_by),
			nspawnby = d.num_spawn_by or -1,
			place_offset_y = d.place_offset_y or 0,
			check_offset = d.check_offset or -1,
			c_decos = id_list(d.decoration),
			deco_height = d.height or 1,
			deco_height_max = d.height_max or 0,
			deco_param2 = d.param2 or 0,
			deco_param2_max = d.param2_max or 0,
			rotation = tostring(d.rotation or "0"),
			schematic = schematic_of(d.schematic, d.replacements),
			ltree = ltree_of(d.treedef),
		}
	end
	return out
end

-- What the mapgen is asked to report about what it made. Luanti keeps the
-- flags and the two id sets on its EmergeManager and the mapgen fills a
-- table with where each thing landed; the flags here cross to the
-- generator when the world's is made, and what it reported comes back in
-- core.get_mapgen_object("gennotify") -- see core.__run_on_generated() in
-- lua/vmanip.lua.
--
-- simplified: "custom" is kept and never reported. A mapgen's custom data
-- is a mod's own mapgen script writing into the notifier, which is a Lua
-- environment on the generator's thread and not something this has.
local GENNOTIFY_FLAGS = {"dungeon", "temple", "cave_begin", "cave_end",
		"large_cave_begin", "large_cave_end", "decoration", "custom"}
local gennotify_on = {}
local gennotify_deco_ids = {}
local gennotify_custom_ids = {}
local gennotify_warned = false

function core.set_gen_notify(flags, deco_ids, custom_ids)
	if type(flags) == "string" then
		-- The written form: "decoration,custom" and "nodungeon" to turn one
		-- off, which is how Luanti's flag strings read everywhere
		local as_table = {}
		for word in flags:gmatch("[^%s,]+") do
			local off = word:match("^no(.*)$")
			if off then
				as_table[off] = false
			else
				as_table[word] = true
			end
		end
		flags = as_table
	end
	if type(flags) == "table" then
		for _, name in ipairs(GENNOTIFY_FLAGS) do
			if flags[name] ~= nil then
				gennotify_on[name] = flags[name] and true or false
			end
		end
	end
	for _, id in ipairs(deco_ids or {}) do
		gennotify_deco_ids[id] = true
	end
	for _, id in ipairs(custom_ids or {}) do
		gennotify_custom_ids[id] = true
	end
	-- Luanti drops the ids when the flag they are for goes off
	if not gennotify_on["decoration"] then
		gennotify_deco_ids = {}
	end
	if not gennotify_on["custom"] then
		gennotify_custom_ids = {}
	end
	-- The flags reach the generator when the world's is made, which is
	-- after every mod has loaded; one set after that is not heard. See
	-- mapgen_gen_notify() in luanti.cpp.
	if core.__mods_loaded and not gennotify_warned then
		gennotify_warned = true
		core.log("warning", "core.set_gen_notify() after the mods loaded: "
				.. "the mapgen was told what to report before this and "
				.. "does not hear it")
	end
end

function core.get_gen_notify()
	local names = {}
	for _, name in ipairs(GENNOTIFY_FLAGS) do
		if gennotify_on[name] then
			names[#names + 1] = name
		end
	end
	local decos, customs = {}, {}
	for id in pairs(gennotify_deco_ids) do
		decos[#decos + 1] = id
	end
	for id in pairs(gennotify_custom_ids) do
		customs[#customs + 1] = id
	end
	table.sort(decos)
	table.sort(customs)
	return table.concat(names, ","), decos, customs
end

-- Which decoration a name is, for a mod that wants to hear about its own
-- when a chunk is generated. Luanti answers the handle its register call
-- returned, which here is the order it was registered in -- and the order
-- it crosses in, so the number means the same thing on both sides.
function core.get_decoration_id(name)
	-- Luanti's id is the decoration's own index and counts from zero, and
	-- what the mapgen reports in gennotify is that number; the handle a
	-- registration answered with counts from one, as Luanti's opaque handle
	-- does.
	local handle = core.__mapgen_handles.decoration[name]
	return handle and (handle - 1) or nil
end

-- Every name a mapgen can ask about: the nodes, and the aliases a game
-- registers for them -- "mapgen_stone" is an alias and is what a vendored
-- mapgen looks up.
function core.__content_ids_by_name()
	local out = {}
	for id, name in pairs(core.__content_names) do
		out[name] = id
	end
	for alias, target in pairs(core.registered_aliases or {}) do
		local id = out[target]
		if id then
			out[alias] = id
		end
	end
	return out
end

-- The ids of every node in a group, for a "group:name" where a mapgen
-- definition takes node names
function core.__group_ids(group)
	local out = {}
	for id, name in pairs(core.__content_names) do
		local def = core.registered_nodes[name]
		if def and def.groups and (def.groups[group] or 0) > 0 then
			out[#out + 1] = id
		end
	end
	return out
end
-- vim: set noet ts=4 sw=4:
