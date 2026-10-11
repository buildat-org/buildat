-- Buildat: builtin/luanti/lua/vmanip.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- VoxelManip, and the mapgen seam it is the map half of.
--
-- A VoxelManip is a box of the map in three flat arrays -- the content ids,
-- param1 and param2 -- read in one call and written in one. That is what
-- makes a Lua mapgen affordable: a chunk is a quarter of a million voxels,
-- and reading them one at a time across the Lua boundary is a module lock
-- each. The arrays are x fastest and then y and then z, which is what
-- VoxelArea indexes and what voxelworld's region calls already produce, so
-- a mod's own VoxelArea arithmetic goes straight through.
--
-- simplified: no emerging. Luanti reads whole mapblocks around the box asked
-- for and hands back the corners it really read; here the box is the box,
-- and a mod that uses the corners it is given -- which is every mod, because
-- that is the documented way -- does not notice. What it costs is that a
-- write cannot straddle what was never read.

local VoxelManipRef = {}
VoxelManipRef.__index = VoxelManipRef

-- Set while the on_generated callbacks run; see update_liquids()
local in_on_generated = false

local function to_xyz(p)
	if p == nil then
		return nil
	end
	return math.floor(p.x or p[1] or 0), math.floor(p.y or p[2] or 0),
			math.floor(p.z or p[3] or 0)
end

local function sorted_box(p1, p2)
	local x1, y1, z1 = to_xyz(p1)
	local x2, y2, z2 = to_xyz(p2)
	if x1 > x2 then x1, x2 = x2, x1 end
	if y1 > y2 then y1, y2 = y2, y1 end
	if z1 > z2 then z1, z2 = z2, z1 end
	return x1, y1, z1, x2, y2, z2
end

function VoxelManipRef:read_from_map(p1, p2)
	local x1, y1, z1, x2, y2, z2 = sorted_box(p1, p2)
	self.emin = {x = x1, y = y1, z = z1}
	self.emax = {x = x2, y = y2, z = z2}
	self.ystride = x2 - x1 + 1
	self.zstride = (x2 - x1 + 1) * (y2 - y1 + 1)
	self.ids, self.param1, self.param2 =
			__luanti_get_region_data(x1, y1, z1, x2, y2, z2)
	self.modified = false
	return self.emin, self.emax
end

-- Luanti 5.13's: the box cleared and resized, every node `node` or
-- ignore. vl_wieldlight moves its manipulator this way to the player's
-- new place after a jump of more than 16 voxels; without it the mod
-- stopped there on every step and its light stayed where it had been.
function VoxelManipRef:initialize(p1, p2, node)
	local x1, y1, z1, x2, y2, z2 = sorted_box(p1, p2)
	self.emin = {x = x1, y = y1, z = z1}
	self.emax = {x = x2, y = y2, z = z2}
	self.ystride = x2 - x1 + 1
	self.zstride = (x2 - x1 + 1) * (y2 - y1 + 1)
	local id = node and core.get_content_id(node.name) or core.CONTENT_IGNORE
	local p1v, p2v = node and node.param1 or 0, node and node.param2 or 0
	local ids, param1, param2 = {}, {}, {}
	for i = 1, self.zstride * (z2 - z1 + 1) do
		ids[i], param1[i], param2[i] = id, p1v, p2v
	end
	self.ids, self.param1, self.param2 = ids, param1, param2
	self.modified = false
	return self.emin, self.emax
end

function VoxelManipRef:get_emerged_area()
	return self.emin, self.emax
end

-- Luanti fills the buffer it is given and returns it; the table here is the
-- VoxelManip's own either way, so a mod that changes it in place and never
-- calls set_data() still gets what it meant.
function VoxelManipRef:get_data(buffer)
	if buffer ~= nil and buffer ~= self.ids then
		-- In C, because a mapgen chunk is half a million entries and a mod
		-- reusing one buffer is doing what Luanti's documentation tells it
		-- to. Written as a Lua loop it was a third of all the Lua time a
		-- VoxeLibre world spent in its first fifteen seconds with a player
		-- in it.
		return __luanti_copy_ints(buffer, self.ids)
	end
	return self.ids
end

function VoxelManipRef:set_data(data)
	self.ids = data
	self.modified = true
end

-- The buffer is filled the same way: vl_wieldlight hands one in and reads
-- it, never the return value, and an unfilled buffer was a nil at every
-- index once the player carried a torch
function VoxelManipRef:get_light_data(buffer)
	if buffer ~= nil and buffer ~= self.param1 then
		return __luanti_copy_ints(buffer, self.param1)
	end
	return self.param1
end

function VoxelManipRef:set_light_data(data)
	self.param1 = data
	self.modified = true
end

function VoxelManipRef:get_param2_data(buffer)
	if buffer ~= nil and buffer ~= self.param2 then
		return __luanti_copy_ints(buffer, self.param2)
	end
	return self.param2
end

function VoxelManipRef:set_param2_data(data)
	self.param2 = data
	self.modified = true
end

function VoxelManipRef:index(x, y, z)
	return (z - self.emin.z) * self.zstride +
			(y - self.emin.y) * self.ystride + (x - self.emin.x) + 1
end

function VoxelManipRef:contains(x, y, z)
	return x >= self.emin.x and x <= self.emax.x and
			y >= self.emin.y and y <= self.emax.y and
			z >= self.emin.z and z <= self.emax.z
end

function VoxelManipRef:get_node_at(pos)
	local x, y, z = to_xyz(pos)
	if not self:contains(x, y, z) then
		return {name = "ignore", param1 = 0, param2 = 0}
	end
	local i = self:index(x, y, z)
	return {name = core.get_name_from_content_id(self.ids[i] or 0),
			param1 = self.param1[i] or 0, param2 = self.param2[i] or 0}
end

function VoxelManipRef:set_node_at(pos, node)
	local x, y, z = to_xyz(pos)
	if not self:contains(x, y, z) then
		return
	end
	local i = self:index(x, y, z)
	self.ids[i] = core.get_content_id(node.name)
	self.param1[i] = node.param1 or 0
	self.param2[i] = node.param2 or 0
	self.modified = true
end

function VoxelManipRef:write_to_map(light)
	if self.emin == nil then
		return
	end
	-- Told not to light it, the light written is the mod's own work and
	-- is taken as it is, its 0s too ([WIELDLIGHT_STALE]) -- unless
	-- calc_lighting() asked for the box to be lit after, as VoxeLibre's
	-- mapgen does before its write_to_map(false)
	__luanti_set_region_data(self.emin.x, self.emin.y, self.emin.z,
			self.emax.x, self.emax.y, self.emax.z,
			self.ids, self.param1, self.param2,
			light == false and self.relight == nil)
	self.modified = false
	-- What calc_lighting() asked for, now that there is terrain to work it
	-- out from. Luanti's own write_to_map(light) does the same thing when
	-- it is not told otherwise.
	local r = self.relight
	if r == nil and light ~= false then
		r = {x1 = self.emin.x, y1 = self.emin.y, z1 = self.emin.z,
				x2 = self.emax.x, y2 = self.emax.y, z2 = self.emax.z}
	end
	if r ~= nil then
		self.relight = nil
		__luanti_relight(r.x1, r.y1, r.z1, r.x2, r.y2, r.z2)
	end
	if self.liquids_pending then
		self.liquids_pending = nil
		self:update_liquids()
	end
end

function VoxelManipRef:was_modified()
	return self.modified and true or false
end

-- The light is voxelworld's, which is what makes these two different from
-- Luanti's: there the manipulator works the light out into its own param1
-- and writes it with the rest, and here the world floods it once the
-- terrain is in the map. So calc_lighting() records the box and the flood
-- happens after write_to_map(), which is the only order in which there is
-- terrain to work from.
--
-- A mod that writes a chunk of its own terrain needs this: what it wrote
-- carries no light, and a write with no light in it takes the light that
-- was there -- which, where the mod has just replaced the mapgen's terrain,
-- is nothing. VoxeLibre's world was black until this did something.
function VoxelManipRef:calc_lighting(p1, p2, propagate_shadow)
	if self.emin == nil then
		return
	end
	if p1 ~= nil and p2 ~= nil then
		local x1, y1, z1, x2, y2, z2 = sorted_box(p1, p2)
		self.relight = {x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2}
	else
		self.relight = {x1 = self.emin.x, y1 = self.emin.y,
				z1 = self.emin.z, x2 = self.emax.x, y2 = self.emax.y,
				z2 = self.emax.z}
	end
end

-- simplified: set_lighting() does write what it is told, because a mod that
-- fills a cave with its own value means it.

function VoxelManipRef:set_lighting(light, p1, p2)
	if type(light) ~= "table" or self.emin == nil then
		return
	end
	local value = (light.day or 0) + (light.night or 0) * 16
	local x1, y1, z1, x2, y2, z2
	if p1 ~= nil and p2 ~= nil then
		x1, y1, z1, x2, y2, z2 = sorted_box(p1, p2)
	else
		x1, y1, z1 = self.emin.x, self.emin.y, self.emin.z
		x2, y2, z2 = self.emax.x, self.emax.y, self.emax.z
	end
	for z = z1, z2 do
		for y = y1, y2 do
			for x = x1, x2 do
				if self:contains(x, y, z) then
					self.param1[self:index(x, y, z)] = value
				end
			end
		end
	end
	self.modified = true
end

-- The liquids in the box queued to flow, which is what Luanti's does for
-- the liquid nodes a mod wrote: the map's own edge scan over the box,
-- once the data is in the map -- now if it is, else after the next
-- write_to_map()
function VoxelManipRef:update_liquids()
	if self.emin == nil then
		return
	end
	if self.modified then
		self.liquids_pending = true
		return
	end
	-- Inside on_generated the chunk's own scan follows the callbacks
	-- (core.__run_on_generated); VoxeLibre calls this on every chunk
	if in_on_generated then
		return
	end
	core.__liquid_scan_generated(self.emin.x, self.emin.y, self.emin.z,
			self.emax.x, self.emax.y, self.emax.z)
end

function VoxelManipRef:update_map()
end

function VoxelManipRef:close()
	self.ids, self.param1, self.param2 = nil, nil, nil
end

local function new_vmanip(p1, p2)
	local vm = setmetatable({ids = {}, param1 = {}, param2 = {},
			modified = false}, VoxelManipRef)
	if p1 ~= nil and p2 ~= nil then
		vm:read_from_map(p1, p2)
	end
	return vm
end

function core.get_voxel_manip(p1, p2)
	return new_vmanip(p1, p2)
end

function VoxelManip(p1, p2)
	return new_vmanip(p1, p2)
end

--
-- The mapgen seam
--

-- What core.get_mapgen_object("voxelmanip") hands out while a generation
-- callback runs, and nothing outside one. Luanti gives a mod the VoxelManip
-- its mapgen just filled and writes back whatever the mod does to it when
-- the callback returns; so does this.
local mapgen_vm = nil
-- What the mapgen reported for the section being run over; see
-- core.__run_on_generated()
local mapgen_gennotify = nil

function core.get_mapgen_object(name)
	if name == "voxelmanip" then
		if mapgen_vm == nil then
			return nil
		end
		return mapgen_vm, mapgen_vm.emin, mapgen_vm.emax
	end
	if name == "gennotify" then
		-- Always a table, which is what Luanti answers: the mapgen reports
		-- what it made into it, and a mod indexes it without asking whether
		-- it is there -- VoxeLibre's mcl_mapgen_core does, and an answer of
		-- nil took its whole generator down every chunk. It is empty unless
		-- a mod asked with core.set_gen_notify() and this is a section the
		-- mapgen made something it was asked about in.
		return mapgen_gennotify or {}
	end
	-- The mapgen's own workings over the section's columns, x fastest
	-- then z, 1-based, the biomes by their index (core.get_biome_name):
	-- what the generator left for this section (luanti.cpp
	-- set_global_maps, taken once). Luanti answers nil for an object
	-- the running mapgen does not produce -- singlenode has none --
	-- which is what a mod checks for.
	if name == "heightmap" or name == "biomemap" or name == "heatmap" or
			name == "humiditymap" then
		local maps = mapgen_vm and __luanti_mapgen_maps
		return maps and maps[name] or nil
	end
	return nil
end

-- Called by the module once a section has been filled, with the box it
-- filled and the seed that box's randomness starts from.
-- What the mapgen reported for the section being run over, in Luanti's
-- shape: a name to the list of positions it happened at. Read from the line
-- per event the module leaves in __luanti_gennotify; see gennotify_of() in
-- luanti.cpp.
local function parse_gennotify(text)
	if text == nil or text == "" then
		return {}
	end
	local out = {}
	for name, x, y, z in text:gmatch("(%S+) (-?%d+) (-?%d+) (-?%d+)") do
		local list = out[name]
		if list == nil then
			list = {}
			out[name] = list
		end
		list[#list + 1] = vector.new(tonumber(x), tonumber(y), tonumber(z))
	end
	return out
end

-- BUILDAT_LUANTI_BINDPROF=1: every __luanti_* binding wrapped with a
-- timer, so a slow section's line below says which of the module's C
-- calls the mod's code spent its time in -- the instruction sampler
-- (BUILDAT_LUANTI_LUAPROF) cannot see inside a C function ([STEP_SLICE])
local bind_us = nil
if os.getenv("BUILDAT_LUANTI_BINDPROF") == "1" then
	bind_us = {}
	local names = {}
	for name, f in pairs(_G) do
		if type(f) == "function" and type(name) == "string" and
				name:sub(1, 9) == "__luanti_" and name ~= "__luanti_log" then
			names[#names + 1] = name
		end
	end
	for _, name in ipairs(names) do
		local f = _G[name]
		_G[name] = function(...)
			local t = core.get_us_time()
			local a, b, c, d = f(...)
			bind_us[name] = (bind_us[name] or 0) + core.get_us_time() - t
			return a, b, c, d
		end
	end
end
local function bind_top(n)
	if not bind_us then
		return ""
	end
	local list = {}
	for name, us in pairs(bind_us) do
		list[#list + 1] = {name, us}
	end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	local parts = {}
	for i = 1, math.min(n, #list) do
		parts[i] = string.format("%s %.0f", list[i][1]:sub(10), list[i][2] / 1000)
	end
	return "; bindings ms: " .. table.concat(parts, ", ")
end

-- What each mod's on_generated handlers have cost since the world came up,
-- and how many sections they have been called for ([MAPGEN_STEP]: which
-- structures cost VoxeLibre's 1.6-3.9 s a step). The worst of one section
-- says which mod to look at once; this says where a run's minutes went.
local mod_us, mod_n = {}, {}
local mod_sections = 0

-- The costliest few, as "<mod> <ms> in <n>"
local function mod_top(n)
	local list = {}
	for name, us in pairs(mod_us) do
		list[#list + 1] = {name, us}
	end
	table.sort(list, function(a, b) return a[2] > b[2] end)
	local parts = {}
	for i = 1, math.min(n, #list) do
		parts[i] = string.format("%s %.0f in %d", list[i][1],
				list[i][2] / 1000, mod_n[list[i][1]] or 0)
	end
	return table.concat(parts, ", ")
end

local run_on_generated_mods

function core.__run_on_generated(x0, y0, z0, x1, y1, z1, blockseed)
	local callbacks = core.registered_on_generateds
	if callbacks ~= nil and #callbacks > 0 then
		in_on_generated = true
		local ok, err = pcall(run_on_generated_mods, callbacks,
				x0, y0, z0, x1, y1, z1, blockseed)
		in_on_generated = false
		if not ok then
			error(err, 0)
		end
	end
	-- After the mods' writes: the liquids that have somewhere to flow are
	-- queued, as the mapgen's own would be ([LIQUID_FLOW], lua/liquid.lua)
	if core.__liquid_scan_generated then
		core.__liquid_scan_generated(x0, y0, z0, x1, y1, z1)
	end
end

run_on_generated_mods = function(callbacks, x0, y0, z0, x1, y1, z1, blockseed)
	mapgen_gennotify = parse_gennotify(__luanti_gennotify)
	-- Vectors and not plain tables: a mod calls vector methods on what it
	-- is given, which is what Luanti hands it
	local minp = vector.new(x0, y0, z0)
	local maxp = vector.new(x1, y1, z1)
	-- Read lazily: a mod that only places a few nodes with core.set_node
	-- should not pay for a quarter of a million voxels crossing the
	-- boundary twice. The first core.get_mapgen_object() call is what
	-- reads them.
	mapgen_vm = setmetatable({ids = {}, param1 = {}, param2 = {},
			modified = false}, VoxelManipRef)
	local read = false
	-- Where a slow section's time went, for the line below: the read of
	-- the section into Lua tables, the mods' code, the write back and
	-- the relight ([STEP_SLICE])
	local read_us, write_us = 0, 0
	local real_get = core.get_mapgen_object
	core.get_mapgen_object = function(name)
		if name == "voxelmanip" and not read then
			read = true
			local t = core.get_us_time()
			mapgen_vm:read_from_map(minp, maxp)
			read_us = read_us + core.get_us_time() - t
		end
		return real_get(name)
	end
	local t_all = core.get_us_time()
	local worst, worst_mod = 0, "?"
	if bind_us then
		bind_us = {}
	end
	for i = 1, #callbacks do
		local callback = callbacks[i]
		local origin = core.callback_origins and
				core.callback_origins[callback]
		if origin then
			core.set_last_run_mod(origin.mod)
		end
		local t_cb = core.get_us_time()
		local ok, err
		if core.__mapgen_env_callbacks[callback] then
			-- Registered by a core.register_mapgen_script(), whose
			-- environment hands the callback the VoxelManip first. There is
			-- one Lua state here, so which environment a callback came from
			-- is remembered rather than enforced.
			if not read then
				read = true
				local t = core.get_us_time()
				mapgen_vm:read_from_map(minp, maxp)
				read_us = read_us + core.get_us_time() - t
			end
			ok, err = pcall(callback, mapgen_vm, minp, maxp, blockseed)
		else
			ok, err = pcall(callback, minp, maxp, blockseed)
		end
		if not ok then
			core.log("error", "on_generated: " .. tostring(err))
		end
		local took = core.get_us_time() - t_cb
		local mod = origin and origin.mod or "?"
		mod_us[mod] = (mod_us[mod] or 0) + took
		mod_n[mod] = (mod_n[mod] or 0) + 1
		if took > worst then
			worst, worst_mod = took, mod
		end
	end
	core.get_mapgen_object = real_get
	-- Into the step peak with the phase named by the mod: this runs on
	-- the server's thread between steps and starves everything the same
	-- way a long step does. See [STEP_PEAK].
	local callbacks_us = core.get_us_time() - t_all
	core.__note_phase("on_generated " .. worst_mod, callbacks_us / 1000000)
	-- The running totals now and then, which is what says where a whole
	-- run's mapgen time went rather than one section's ([MAPGEN_STEP])
	mod_sections = mod_sections + 1
	if mod_sections % 25 == 0 then
		core.log("action", string.format(
				"on_generated by mod after %d sections: %s", mod_sections,
				mod_top(8)))
	end
	-- What a mod did to the mapgen's own VoxelManip is written back when
	-- the callback returns, which is Luanti's rule for that one
	if read and mapgen_vm:was_modified() then
		local t = core.get_us_time()
		mapgen_vm:write_to_map()
		write_us = core.get_us_time() - t
	end
	if callbacks_us + write_us >= 200000 then
		core.log("verbose", string.format(
				"on_generated at %d,%d,%d: read %.0f ms, mods %.0f ms " ..
				"(worst %s %.0f ms), write and relight %.0f ms%s", x0, y0, z0,
				read_us / 1000, (callbacks_us - read_us) / 1000, worst_mod,
				worst / 1000, write_us / 1000, bind_top(8)))
	end
	mapgen_vm = nil
	mapgen_gennotify = nil
end

--
-- What the mapgen is, as far as anything can ask
--

function core.get_mapgen_setting(name)
	if name == "seed" then
		return tostring(__luanti_world_seed)
	end
	if name == "mg_name" then
		-- What this world is actually generated with, which is written into
		-- the save the first time it is opened. It said "singlenode" here
		-- while that was all there was, and a game reads this to decide
		-- what to register: VoxeLibre registers no biomes at all for a
		-- singlenode world. An imported world's mapgen is its
		-- map_meta.txt's and is in no setting here, so the module's answer
		-- comes first and the settings are the fallback.
		return rawget(_G, "__luanti_mapgen_name") or core.__mapgen_name()
	end
	if name == "chunksize" then
		return tostring(core.get_mapgen_chunksize().x)
	end
	if name == "water_level" and rawget(_G, "__luanti_water_level") then
		-- The world's own, which is what it was made with: a save keeps it
		-- the way Luanti's map_meta.txt does, and the settings are only
		-- where it comes from the first time
		return tostring(__luanti_water_level)
	end
	return core.settings:get("mg" .. name) or core.settings:get(name)
end

function core.set_mapgen_setting(name, value, override_meta)
	core.settings:set(name, tostring(value))
end

function core.get_mapgen_params()
	-- Deprecated in Luanti and still called; the fields are the ones it
	-- answers with
	return {
		mgname = rawget(_G, "__luanti_mapgen_name") or core.__mapgen_name(),
		seed = tonumber(__luanti_world_seed) or 0,
		water_level = tonumber(__luanti_water_level) or
				tonumber(core.settings:get("water_level")) or 1,
		chunksize = core.get_mapgen_chunksize().x,
		flags = core.settings:get("mg_flags") or "",
	}
end

function core.set_mapgen_params(params)
end

-- In mapblocks of sixteen. Five, Luanti's default: luanti_mapgen generates
-- in Luanti's chunks and cuts the sections out of them, and VoxeLibre works
-- its world's edges out of this.
-- simplified: the chunksize setting is not read; the generator's
-- CHUNK_BLOCKS is what to make of it if a game ever sets one.
function core.get_mapgen_chunksize()
	return vector.new(5, 5, 5)
end

-- Luanti's get_mapgen_edges (mapgen.cpp), exactly: the outermost whole
-- chunks inside the mapgen limit, per axis
function core.get_mapgen_edges(mapgen_limit, chunksize)
	local limit = tonumber(core.settings:get("mapgen_limit")) or 31007
	if type(mapgen_limit) == "number" then
		limit = math.floor(mapgen_limit)
	end
	local cs = core.get_mapgen_chunksize()
	if type(chunksize) == "number" then
		cs = vector.new(chunksize, chunksize, chunksize)
	elseif type(chunksize) == "table" then
		cs = chunksize
	end
	local limit_b = math.floor(math.max(0, math.min(limit, 31007)) / 16)
	local limit_min = -limit_b * 16
	local limit_max = (limit_b + 1) * 16 - 1
	local function calculate(c)
		local ccoff_b = -math.floor(c / 2)
		local csize_n = c * 16
		local ccmin = ccoff_b * 16
		local ccmax = ccmin + csize_n - 1
		local numcmin = math.max(math.floor((ccmin - 16 - limit_min) / csize_n), 0)
		local numcmax = math.max(math.floor((limit_max - ccmax - 16) / csize_n), 0)
		return ccmin - numcmin * csize_n, ccmax + numcmax * csize_n
	end
	local x0, x1 = calculate(cs.x)
	local y0, y1 = calculate(cs.y)
	local z0, z1 = calculate(cs.z)
	return vector.new(x0, y0, z0), vector.new(x1, y1, z1)
end

-- vim: set noet ts=4 sw=4:
