-- Buildat: extension/luanti_client/engine_test.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Checks the engine primitives this extension leans on, against the engine's
-- own other way of doing the same thing where there is one. init.lua runs it at
-- boot, so a broken binding shows up before the connection does.

local M = {}

local function check_compress()
	-- Something with enough structure to actually compress
	local data = string.rep("mapblock ", 200)..string.char(0, 1, 2, 253, 254, 255)
	for _, format in ipairs({"zlib", "zstd"}) do
		local packed = buildat.compress(data, format)
		assert(#packed < #data, format.." did not compress")
		local out, consumed = buildat.decompress(packed, format)
		assert(out == data, format.." did not survive a round trip")
		assert(consumed == #packed,
				format.." consumed "..consumed.." of "..#packed.." bytes")
		-- Two streams in a row: consumed is what says where the second begins,
		-- which is how a Luanti mapblock at serialization version 28 is read
		local out2, consumed2 = buildat.decompress(packed..packed, format)
		assert(out2 == data and consumed2 == #packed,
				format.." did not stop at the end of the first stream")
	end
	-- An empty string is a stream too, and levels are optional
	assert(buildat.decompress(buildat.compress("", "zstd"), "zstd") == "")
	assert(buildat.decompress(buildat.compress(data, "zstd", 1), "zstd") == data)
	assert(buildat.decompress(buildat.compress(data, "zlib", 9), "zlib") == data)
	-- There is no default format, for either
	assert(not pcall(buildat.decompress, buildat.compress(data, "zlib")),
			"decompress() without a format was allowed")
end

-- A volume packed by pack_voxel_volume() has to hold what the same data set
-- one voxel at a time through Volume holds. Volume:serialize() and
-- deserialize_volume() are the engine's other way round the same trip, so the
-- two answers are independent.
local function check_pack_voxel_volume()
	local safe = buildat
	-- 0.6's cut, which the accessors below read
	local legacy = safe.createVoxelRegistry()
	legacy:set_format("buildat_legacy_06")
	-- Samples that need every byte order and both fields: a 4x3x2 box of ids,
	-- and the same box's light. The numbers are made up but the layout is
	-- Luanti's: x fastest, then y, then z.
	local sx, sy, sz = 4, 3, 2
	local ids, lights = {}, {}
	for z = 0, sz - 1 do
		for y = 0, sy - 1 do
			for x = 0, sx - 1 do
				local i = x + y * sx + z * sx * sy
				ids[i] = (x * 100 + y * 10 + z) % 65536
				lights[i] = (x + y + z) % 16
			end
		end
	end
	local id_bytes, light_bytes = {}, {}
	for i = 0, sx * sy * sz - 1 do
		id_bytes[#id_bytes + 1] = string.char(math.floor(ids[i] / 256),
				ids[i] % 256)
		light_bytes[#light_bytes + 1] = string.char(lights[i] * 16 + lights[i])
	end
	id_bytes = table.concat(id_bytes)
	light_bytes = table.concat(light_bytes)

	-- A region one voxel bigger than the box on every side, so that the fill
	-- and the offset both get checked
	local FILL = 7
	local packed = buildat.pack_voxel_volume{
		registry = legacy,
		region = {-1, -1, -1, sx, sy, sz},
		fill = FILL,
		sources = {
			{
				data = id_bytes, format = "u16be",
				source_size = {sx, sy, sz},
				at = {0, 0, 0}, order = "xyz", field = "id",
			},
			{
				-- Luanti's param1 keeps the day light in the low nibble
				data = light_bytes, format = "u8",
				source_size = {sx, sy, sz},
				at = {0, 0, 0}, order = "xyz", field = "skylight",
				mask = 0x0f,
			},
			{
				-- and the light from light sources in the high one
				data = light_bytes, format = "u8",
				source_size = {sx, sy, sz},
				at = {0, 0, 0}, order = "xyz", field = "lamplight",
				shift = 4, mask = 0x0f,
			},
		},
	}

	-- The same thing the slow way
	local volume = safe.Volume(safe.Region(-1, -1, -1, sx, sy, sz))
	for z = -1, sz do
		for y = -1, sy do
			for x = -1, sx do
				volume:set_voxel_at(x, y, z, safe.VoxelInstance(FILL))
			end
		end
	end
	for z = 0, sz - 1 do
		for y = 0, sy - 1 do
			for x = 0, sx - 1 do
				local i = x + y * sx + z * sx * sy
				local v = safe.VoxelInstance(ids[i] + lights[i] * 0x1000000 +
						lights[i] * 0x10000000)
				volume:set_voxel_at(x, y, z, v)
			end
		end
	end
	assert(volume:serialize() == packed,
			"pack_voxel_volume() and Volume:serialize() disagree")

	-- And read back through the other door, to check that what came out is
	-- what the mesher would see
	local back = safe.deserialize_volume(packed)
	for z = -1, sz do
		for y = -1, sy do
			for x = -1, sx do
				local v = back:get_voxel_at(x, y, z)
				local inside = x >= 0 and x < sx and y >= 0 and y < sy and
						z >= 0 and z < sz
				local i = x + y * sx + z * sx * sy
				assert(v:get_id() == (inside and ids[i] or FILL),
						"id at "..x..","..y..","..z.." is "..v:get_id())
				assert(v:get_skylight() == (inside and lights[i] or 0),
						"skylight at "..x..","..y..","..z.." is "..
						v:get_skylight())
				assert(v:get_lamplight() == (inside and lights[i] or 0),
						"lamplight at "..x..","..y..","..z.." is "..
						v:get_lamplight())
			end
		end
	end

	-- order and map: the same ids the other way round in memory, mapped
	local zyx = {}
	for x = 0, sx - 1 do
		for y = 0, sy - 1 do
			for z = 0, sz - 1 do
				local id = ids[x + y * sx + z * sx * sy]
				zyx[#zyx + 1] = string.char(math.floor(id / 256), id % 256)
			end
		end
	end
	local map = {}
	for i = 0, sx * sy * sz - 1 do
		map[ids[i]] = 1000 + ids[i]
	end
	map[ids[0]] = nil -- One sample nothing maps, which leaves the fill alone
	local mapped = buildat.pack_voxel_volume{
		registry = legacy,
		region = {0, 0, 0, sx - 1, sy - 1, sz - 1},
		fill = FILL,
		sources = {{
			data = table.concat(zyx), format = "u16be",
			source_size = {sx, sy, sz}, order = "zyx", map = map,
		}},
	}
	local mapped_volume = safe.deserialize_volume(mapped)
	for z = 0, sz - 1 do
		for y = 0, sy - 1 do
			for x = 0, sx - 1 do
				local id = ids[x + y * sx + z * sx * sy]
				local expect = map[id] or FILL
				assert(mapped_volume:get_voxel_at(x, y, z):get_id() == expect,
						"mapped id at "..x..","..y..","..z.." is "..
						mapped_volume:get_voxel_at(x, y, z):get_id())
			end
		end
	end

	-- A source box that hangs over the edge of the region is clipped, not an
	-- error: that is how a neighbouring block's border slice arrives
	local clipped = buildat.pack_voxel_volume{
		registry = legacy,
		region = {0, 0, 0, 0, 0, 0},
		fill = FILL,
		sources = {{
			data = id_bytes, format = "u16be",
			source_size = {sx, sy, sz}, at = {-1, -1, -1},
		}},
	}
	assert(safe.deserialize_volume(clipped):get_voxel_at(0, 0, 0):get_id() ==
			ids[1 + 1 * sx + 1 * sx * sy], "clipping put the wrong voxel at 0")

	-- field = "light" writes both light channels at once and leaves the id
	-- alone, which is how a mapblock's param1 goes in
	local both = buildat.pack_voxel_volume{
		registry = legacy,
		region = {0, 0, 0, 0, 0, 0},
		fill = FILL,
		sources = {{
			data = string.char(0xa3), format = "u8", source_size = {1, 1, 1},
			field = "light",
		}},
	}
	local lit = safe.deserialize_volume(both):get_voxel_at(0, 0, 0)
	assert(lit:get_skylight() == 0x3 and lit:get_lamplight() == 0xa and
			lit:get_id() == FILL, "field = light wrote "..lit.data)

	-- A second sample array, read in lockstep: what a voxel looks like is a
	-- pair of samples, which is what Luanti's param0 and param2 are. The
	-- keys are far apart, so the map is a hash rather than an array.
	local pairs_ids = string.char(0, 5, 0, 5, 0, 7)
	local pairs_p2 = string.char(1, 2, 3)
	local pair_map = {
		[5 + 1 * 65536] = 11,
		[5 + 2 * 65536] = 22,
		-- 7 with param2 3 is not mapped, and gets the default
	}
	local paired = buildat.pack_voxel_volume{
		registry = legacy,
		region = {0, 0, 0, 2, 0, 0},
		fill = FILL,
		sources = {{
			data = pairs_ids, format = "u16be", source_size = {3, 1, 1},
			second = {data = pairs_p2, format = "u8", scale = 65536},
			map = pair_map, map_default = 33,
		}},
	}
	local pv = safe.deserialize_volume(paired)
	assert(pv:get_voxel_at(0, 0, 0):get_id() == 11,
			"paired id 0 is "..pv:get_voxel_at(0, 0, 0):get_id())
	assert(pv:get_voxel_at(1, 0, 0):get_id() == 22,
			"paired id 1 is "..pv:get_voxel_at(1, 0, 0):get_id())
	assert(pv:get_voxel_at(2, 0, 0):get_id() == 33,
			"paired id 2 is "..pv:get_voxel_at(2, 0, 0):get_id())
end

-- A voxel format is the game's own cut of the 32-bit voxel word, and every
-- field name pack_voxel_volume() takes means a role of it rather than a bit
-- range. There is no default: buildat_legacy_06 is the cut buildat had
-- before formats existed, and the assertion that matters is that reading
-- through it gives what VoxelInstance's own accessors give.
local function check_voxel_format()
	local safe = buildat

	-- 0.6's cut: nothing changed
	local plain = safe.createVoxelRegistry()
	plain:set_format("buildat_legacy_06")
	local packed = buildat.pack_voxel_volume{
		region = {0, 0, 0, 0, 0, 0},
		registry = plain,
		sources = {
			{data = string.char(0, 0, 4, 210), format = "u32be",
					source_size = {1, 1, 1}, field = "id"},
			{data = string.char(9), format = "u8", source_size = {1, 1, 1},
					field = "skylight"},
			{data = string.char(3), format = "u8", source_size = {1, 1, 1},
					field = "lamplight"},
		},
	}
	local v = safe.deserialize_volume(packed):get_voxel_at(0, 0, 0)
	assert(v:get_id() == 1234, "legacy id is "..v:get_id())
	assert(v:get_skylight() == 9, "legacy skylight is "..v:get_skylight())
	assert(v:get_lamplight() == 3, "legacy lamplight is "..v:get_lamplight())

	-- No registry, no format: an error, not 0.6's cut assumed
	assert(not pcall(buildat.pack_voxel_volume, {region = {0, 0, 0, 0, 0, 0}}),
			"pack_voxel_volume() without a registry was allowed")
	-- And a registry with no format takes no voxel
	local unset = safe.createVoxelRegistry()
	local undef = safe.VoxelDefinition()
	undef.name.block_name = "engine_test:unset"
	assert(not pcall(function() unset:add_voxel(undef) end),
			"add_voxel() with no format was allowed")
	-- A layout by name is the same cut as written out
	local blocks = safe.createVoxelRegistry()
	blocks:set_format("blocks")
	assert(blocks:dump_format() ==
			"VoxelFormat(32-bit, id=0...15, light_sky=16...19, param=20...27)",
			"blocks is "..blocks:dump_format())
	assert(not pcall(function() safe.createVoxelRegistry():set_format("none") end),
			"set_format() took a layout that does not exist")

	-- Luanti's own cut of the same word: a 16-bit id, param1 as two light
	-- nibbles, and param2. Which is what this extension wants, and the point
	-- of the whole exercise: param2 reaches the mesher instead of needing a
	-- voxel id per (definition, param2) pair.
	local luanti = safe.createVoxelRegistry()
	luanti:set_format{
		plane_bits = 32,
		id = {shift = 0, width = 16},
		light_sky = {shift = 16, width = 4},
		light_lamp = {shift = 20, width = 4},
		param = {shift = 24, width = 8},
	}
	local packed2 = buildat.pack_voxel_volume{
		region = {0, 0, 0, 0, 0, 0},
		registry = luanti,
		sources = {
			{data = string.char(0xab, 0xcd), format = "u16be",
					source_size = {1, 1, 1}, field = "id"},
			{data = string.char(7), format = "u8", source_size = {1, 1, 1},
					field = "skylight"},
			{data = string.char(9), format = "u8", source_size = {1, 1, 1},
					field = "lamplight"},
			{data = string.char(0x5e), format = "u8", source_size = {1, 1, 1},
					field = "param"},
		},
	}
	local v2 = safe.deserialize_volume(packed2):get_voxel_at(0, 0, 0)
	-- get_id() and the light accessors read 0.6's cut, so the word is
	-- what has to be checked here
	local word = v2.data % 4294967296
	assert(word == 0xab * 256 + 0xcd + 7 * 65536 + 9 * 1048576 +
			0x5e * 16777216, "luanti-format word is "..word)
	assert(luanti:dump_format() ==
			"VoxelFormat(32-bit, id=0...15, light_sky=16...19, "..
			"light_lamp=20...23, param=24...31)",
			"dump_format() says "..luanti:dump_format())

	-- 0.6's cut binds no param, so asking to write one is an error
	-- rather than bits landing somewhere unsaid
	local ok = pcall(function()
		buildat.pack_voxel_volume{
			region = {0, 0, 0, 0, 0, 0},
			registry = plain,
			sources = {{data = string.char(1), format = "u8",
					source_size = {1, 1, 1}, field = "param"}},
		}
	end)
	assert(not ok, "writing an unbound param was allowed")

	-- A format cannot arrive after the voxels it would reinterpret
	local late = safe.createVoxelRegistry()
	late:set_format("blocks")
	local def = safe.VoxelDefinition()
	def.name.block_name = "engine_test:late"
	def.edge_material_id = safe.VoxelDefinition.EDGEMATERIALID_GROUND
	late:add_voxel(def)
	local ok2 = pcall(function()
		late:set_format{id = {shift = 0, width = 16}}
	end)
	assert(not ok2, "set_format() after a voxel was allowed")
end

-- A definition's variants are what its param means: a shape, a tile order, a
-- tint, a liquid level per param value. They travel with the registry, so the
-- round trip through serialize/deserialize is what a client actually gets.
local function check_voxel_variants()
	local safe = buildat
	local reg = safe.createVoxelRegistry()
	reg:set_format{
		id = {shift = 0, width = 16},
		param = {shift = 24, width = 8},
	}
	local def = safe.VoxelDefinition()
	def.name.block_name = "engine_test:facing"
	def.edge_material_id = safe.VoxelDefinition.EDGEMATERIALID_GROUND
	def.variants = {
		-- A turned cube: the same six textures in another order
		-- The faces are 0...5, so this is the six textures rotated by one
		{tile_order = {1, 2, 3, 4, 5, 0}, tile_turns = {0, 0, 1, 3, 2, 0},
				params = {0, 4, 8}},
		-- A palette entry, and a liquid standing lower than full
		{color = 0x336699, liquid_top = 0.25, params = {1}},
	}
	reg:add_voxel(def)

	-- What the definition holds now, read back through the same property
	local got = def.variants
	assert(got[1] and got[2] and not got[3], "there are not two variants")
	assert(got[1].tile_order[1] == 1 and got[1].tile_order[6] == 0,
			"tile_order is "..got[1].tile_order[1]..".."..got[1].tile_order[6])
	assert(got[1].tile_turns[4] == 3,
			"tile_turns[4] is "..got[1].tile_turns[4])
	assert(#got[1].params == 3 and got[1].params[2] == 4,
			"variant 1 claims "..#got[1].params.." params")
	assert(got[2].color == 0x336699, "colour is "..got[2].color)
	assert(math.abs(got[2].liquid_top - 0.25) < 1e-6,
			"liquid_top is "..got[2].liquid_top)
	assert(#got[2].params == 1 and got[2].params[1] == 1,
			"variant 2 claims "..#got[2].params.." params")

	-- And what a client gets: the registry's own round trip, which is how
	-- both the format and the variants reach one
	local other = safe.createVoxelRegistry()
	other:deserialize(reg:serialize())
	assert(other:dump_format() == reg:dump_format(),
			"the format did not travel: "..other:dump_format())
	assert(other:serialize() == reg:serialize(),
			"the definitions did not survive the round trip")

	-- A variant nobody can reach is a mistake worth catching
	local def2 = safe.VoxelDefinition()
	def2.name.block_name = "engine_test:noparams"
	local ok = pcall(function()
		def2.variants = {{color = 0x112233}}
	end)
	assert(not ok, "a variant with no params was allowed")
end

-- The modifier roles: fields the mesher reads to change how a voxel is drawn
-- without a definition of its own. What can be checked without looking at a
-- screen is which formats are accepted, what the format says it is, and that
-- the definitions' own parameters reach a client.
local function check_voxel_modifiers()
	local safe = buildat
	local reg = safe.createVoxelRegistry()
	reg:set_format{
		id = {shift = 0, width = 8},
		light_sky = {shift = 8, width = 4},
		tint = {shift = 12, width = 4},
		wetness = {shift = 16, width = 4},
		sag_top = {shift = 20, width = 4},
	}
	assert(reg:dump_format() ==
			"VoxelFormat(32-bit, id=0...7, light_sky=8...11, tint=12...15, "..
			"wetness=16...19, sag_top=20...23)",
			"dump_format() says "..reg:dump_format())

	local def = safe.VoxelDefinition()
	def.name.block_name = "engine_test:damp"
	def.edge_material_id = safe.VoxelDefinition.EDGEMATERIALID_GROUND
	-- Dry at tint 0 and soaked at the top of the field
	def.tint_ramp = {0xffffff, 0x807060}
	def.sag_extent = 0.25
	reg:add_voxel(def)
	assert(def.tint_ramp[1] == 0xffffff and def.tint_ramp[2] == 0x807060,
			"tint_ramp is "..def.tint_ramp[1]..", "..def.tint_ramp[2])
	assert(math.abs(def.sag_extent - 0.25) < 1e-6,
			"sag_extent is "..def.sag_extent)

	-- Both travel to a client with the rest of the registry
	local other = safe.createVoxelRegistry()
	other:deserialize(reg:serialize())
	assert(other:dump_format() == reg:dump_format(),
			"the format did not travel: "..other:dump_format())
	assert(other:serialize() == reg:serialize(),
			"the definitions did not survive the round trip")

	-- A plane of a module's own, and a field inside it
	local planed = safe.createVoxelRegistry()
	planed:set_format{
		id = {shift = 0, width = 16},
		light_sky = {shift = 16, width = 4},
		planes = {{name = "engine_test:heat", bits = 8}},
		tint = {plane = 1, shift = 0, width = 4},
	}
	assert(planed:dump_format() ==
			"VoxelFormat(32-bit + engine_test:heat:8-bit, id=0...15, "..
			"light_sky=16...19, tint=0...3)",
			"dump_format() says "..planed:dump_format())

	-- A field cannot reach past its own plane, which is not the first one's
	local ok0 = pcall(function()
		safe.createVoxelRegistry():set_format{
			id = {shift = 0, width = 16},
			planes = {{name = "engine_test:heat", bits = 8}},
			tint = {plane = 1, shift = 4, width = 8},
		}
	end)
	assert(not ok0, "a field reaching past its plane was allowed")

	-- Only four surface modifiers reach the shader, so a fifth is refused
	-- rather than silently dropped. The two sag roles are not among them.
	local ok = pcall(function()
		safe.createVoxelRegistry():set_format{
			id = {shift = 0, width = 8},
			tint = {shift = 8, width = 2},
			wetness = {shift = 10, width = 2},
			grain = {shift = 12, width = 2},
			gloss = {shift = 14, width = 2},
			speckle = {shift = 16, width = 2},
		}
	end)
	assert(not ok, "a fifth surface modifier was allowed")
end

-- Look rules: which definition a voxel wears, for a world with no voxel type
-- id. The default is the id role, which is what the other checks here get.
local function check_voxel_look_rules()
	local safe = buildat
	local reg = safe.createVoxelRegistry()
	reg:set_format{
		id = {shift = 0, width = 4},
		light_sky = {shift = 4, width = 4},
		wetness = {shift = 8, width = 4},
	}
	for _, name in ipairs({"air", "rock", "sand"}) do
		local def = safe.VoxelDefinition()
		def.name.block_name = "engine_test:"..name
		if name == "air" then
			def.fully_empty = true
		else
			def.edge_material_id = safe.VoxelDefinition.EDGEMATERIALID_GROUND
		end
		reg:add_voxel(def)
	end

	-- Rock where the game's own field says so, sand where the role does,
	-- air for everything left
	reg:set_look_rules{
		fallback = 1,
		rules = {
			{result = 2, when = {{field = {shift = 12, width = 2}, lo = 2}}},
			{result = 3, when = {{field = "wetness", lo = 8}}},
		},
	}

	-- And a client gets it with the rest of the registry
	local other = safe.createVoxelRegistry()
	other:deserialize(reg:serialize())
	assert(other:serialize() == reg:serialize(),
			"the look rules did not survive the round trip")

	-- A rule that claims everything has to be the last one
	local ok = pcall(function()
		reg:set_look_rules{
			rules = {{result = 2}, {result = 3, when = {{field = "wetness"}}}},
		}
	end)
	assert(not ok, "an unreachable rule was allowed")

	-- And a rule cannot point at a voxel that is not there
	local ok2 = pcall(function()
		reg:set_look_rules{rules = {{result = 99}}}
	end)
	assert(not ok2, "a rule pointing at nothing was allowed")

	-- A clause naming something that is not a role is a typo, not a field
	local ok3 = pcall(function()
		reg:set_look_rules{
			rules = {{result = 2, when = {{field = "wetnes", lo = 1}}}},
		}
	end)
	assert(not ok3, "a clause on a misspelled role was allowed")
end

-- compose_image() writes a PNG, and Urho3D can read one back, so the pixels
-- can actually be checked. The files go where the client's own temporary
-- resources go, which is a resource dir, so they can be loaded by name.
local function check_compose_image()
	-- Read back through read_image(), which is the sandbox's: four bytes a
	-- pixel, row by row
	local dir = buildat.get_cache_path().."/tmp"
	local made = 0

	-- Composes ops and hands back the image it wrote
	local function compose(name, args)
		args.write = dir.."/buildat_image_test_"..name..".png"
		local w, h = buildat.compose_image(args)
		made = made + 1
		local iw, ih, rgba = buildat.read_image(
				"buildat_image_test_"..name..".png")
		assert(rgba, "compose_image: could not read back "..name)
		assert(iw == w and ih == h,
				"compose_image: "..name.." says "..w.."x"..h..
				" but the file is "..iw.."x"..ih)
		return {width = iw, height = ih, rgba = rgba}, w, h
	end

	local function pixel(img, x, y)
		local i = (y * img.width + x) * 4
		return {img.rgba:byte(i + 1, i + 4)}
	end

	local function same(img, x, y, want, what)
		local got = pixel(img, x, y)
		for i = 1, 4 do
			-- A PNG round trip is exact, so only the arithmetic's own
			-- rounding is allowed for
			assert(math.abs(got[i] - want[i]) <= 1,
					"compose_image: "..what.." at "..x..","..y.." is "..
					got[1]..","..got[2]..","..got[3]..","..got[4]..
					" and not "..want[1]..","..want[2]..","..want[3]..","..
					want[4])
		end
	end

	-- A 4x2 source: mostly one colour, with a different 2x1 corner
	local src = compose("src", {
		size = {4, 2},
		ops = {
			{op = "fill", color = {10, 20, 30, 255}, blend = "set"},
			{op = "fill", color = {200, 100, 50, 255}, at = {0, 0},
					size = {2, 1}, blend = "set"},
		},
	})
	same(src, 0, 0, {200, 100, 50, 255}, "fill")
	same(src, 2, 0, {10, 20, 30, 255}, "fill outside the corner")
	same(src, 0, 1, {10, 20, 30, 255}, "fill below the corner")

	local SRC = "buildat_image_test_src.png"

	-- No size: the first blit makes the canvas, so this is a copy
	local img = compose("copy", {ops = {{op = "blit", src = SRC}}})
	assert(img.width == 4 and img.height == 2,
			"compose_image: the copy is "..img.width.."x"..img.height)
	same(img, 0, 0, {200, 100, 50, 255}, "a plain blit")

	-- A rotation by 90 degrees swaps the dimensions, and the corner moves to
	-- where a counterclockwise turn puts it
	local rot, w, h = compose("rot", {ops = {
		{op = "blit", src = SRC},
		{op = "transform", transform = 1},
	}})
	assert(w == 2 and h == 4, "compose_image: R90 gave "..w.."x"..h)
	same(rot, 0, 2, {200, 100, 50, 255}, "R90")
	same(rot, 0, 0, {10, 20, 30, 255}, "R90 elsewhere")

	-- Two of the eight symmetries in a row are the identity
	local back = compose("back", {ops = {
		{op = "blit", src = SRC},
		{op = "transform", transform = 2},
		{op = "transform", transform = 2},
	}})
	same(back, 0, 0, {200, 100, 50, 255}, "180 twice")
	same(back, 3, 1, {10, 20, 30, 255}, "180 twice")

	-- One cell of a grid, which is what a stack of animation frames is
	local cell, cw, ch = compose("cell", {ops = {
		{op = "blit", src = SRC},
		{op = "crop", grid = {2, 1}, cell = {1, 0}},
	}})
	assert(cw == 2 and ch == 2, "compose_image: the cell is "..cw.."x"..ch)
	same(cell, 0, 0, {10, 20, 30, 255}, "the second cell")

	-- Scaling is nearest neighbour, so the colours are the source's own
	local big, bw, bh = compose("big", {ops = {
		{op = "blit", src = SRC},
		{op = "resize", size = {8, 4}},
	}})
	assert(bw == 8 and bh == 4, "compose_image: resize gave "..bw.."x"..bh)
	same(big, 1, 1, {200, 100, 50, 255}, "resize")
	same(big, 7, 3, {10, 20, 30, 255}, "resize")

	-- Multiply is per channel and takes the alpha with it; colorize blends
	-- towards a colour and leaves the alpha alone
	local mul = compose("mul", {ops = {
		{op = "blit", src = SRC},
		{op = "multiply", color = {128, 255, 255, 255}},
	}})
	same(mul, 0, 0, {100, 100, 50, 255}, "multiply")

	local col = compose("col", {ops = {
		{op = "blit", src = SRC},
		{op = "colorize", color = {0, 0, 0, 255}, ratio = 128},
	}})
	same(col, 0, 0, {100, 50, 25, 255}, "colorize halfway to black")

	-- A hue turned by 120 degrees takes red to green
	local red = compose("red", {size = {1, 1}, ops = {
		{op = "fill", color = {255, 0, 0, 255}, blend = "set"},
		{op = "hsl", hue = 120},
	}})
	same(red, 0, 0, {0, 255, 0, 255}, "a hue turned by 120 degrees")

	-- An overlay with fill covers the whole canvas whatever its own size is,
	-- and a fully transparent pixel leaves what is under it alone
	local over = compose("over", {
		size = {2, 2},
		ops = {
			{op = "fill", color = {0, 0, 255, 255}, blend = "set"},
			{op = "blit", src = SRC, fill = true},
		},
	})
	same(over, 0, 0, {200, 100, 50, 255}, "an overlay stretched to the canvas")

	local hole = compose("hole", {
		size = {2, 2},
		ops = {
			{op = "fill", color = {0, 0, 255, 255}, blend = "set"},
			{op = "fill", color = {255, 255, 255, 0}},
		},
	})
	same(hole, 0, 0, {0, 0, 255, 255}, "a transparent pixel on top")

	-- Alpha compositing: half-transparent white over blue
	local half = compose("half", {
		size = {1, 1},
		ops = {
			{op = "fill", color = {0, 0, 200, 255}, blend = "set"},
			{op = "fill", color = {255, 255, 255, 128}},
		},
	})
	local c = pixel(half, 0, 0)
	assert(c[4] == 255 and c[1] > 120 and c[1] < 135 and
			c[3] > 210 and c[3] < 240,
			"compose_image: half-transparent white over blue is "..c[1]..
			","..c[2]..","..c[3]..","..c[4])

	-- A mask is a bitwise and, which is what keeps a shape and drops the rest
	local mask = compose("mask", {ops = {
		{op = "blit", src = SRC},
		{op = "fill", color = {255, 0, 255, 255}, blend = "and"},
	}})
	same(mask, 0, 0, {200, 0, 50, 255}, "and")

	-- Setting the whole alpha channel
	local opaque = compose("opaque", {
		size = {1, 1},
		ops = {
			{op = "fill", color = {40, 50, 60, 0}, blend = "set"},
			{op = "alpha", value = 255},
		},
	})
	same(opaque, 0, 0, {40, 50, 60, 255}, "alpha")

	-- A shear maps the source's corners onto a parallelogram. Identity edge
	-- vectors are a plain copy; halving one and slanting it is what a face of
	-- an isometric cube is.
	local flat = compose("shear_flat", {
		size = {4, 2},
		ops = {{op = "shear", src = SRC, at = {0, 0},
				u = {4, 0}, v = {0, 2}}},
	})
	same(flat, 0, 0, {200, 100, 50, 255}, "shear as a copy")
	same(flat, 2, 0, {10, 20, 30, 255}, "shear as a copy, outside the corner")

	-- The source turned into a rhombus in an 8x8 canvas: the top corner and
	-- the middle are inside it, the canvas corners are not
	local rhombus = compose("shear_rhombus", {
		size = {8, 8},
		ops = {{op = "shear", src = SRC, at = {4, 0},
				u = {4, 4}, v = {-4, 4}}},
	})
	same(rhombus, 4, 4, {10, 20, 30, 255}, "the middle of a rhombus")
	same(rhombus, 0, 0, {0, 0, 0, 0}, "outside a rhombus")
	same(rhombus, 7, 7, {0, 0, 0, 0}, "outside a rhombus, far corner")
	-- The source's own 0,0 corner is the rhombus's top, and its colour is
	-- the 2x1 corner the source was given
	same(rhombus, 4, 1, {200, 100, 50, 255}, "a rhombus keeps its corner")

	-- Two parallelograms sharing an edge cover every pixel between them once:
	-- the left half and the right half of a canvas, and nothing left blank
	-- along the seam
	local seam = compose("shear_seam", {
		size = {8, 4},
		ops = {
			{op = "shear", src = SRC, at = {0, 0}, u = {4, 0}, v = {0, 4}},
			{op = "shear", src = SRC, at = {4, 0}, u = {4, 0}, v = {0, 4}},
		},
	})
	for y = 0, 3 do
		for x = 0, 7 do
			local got = pixel(seam, x, y)
			assert(got[4] == 255,
					"compose_image: a seam at "..x..","..y.." is blank")
		end
	end

	-- chromakey takes one exact colour out, which is what a texture saved
	-- over a solid background needs; a colour that is only close stays
	local keyed = compose("chromakey", {
		ops = {
			{op = "blit", src = SRC},
			{op = "chromakey", color = {10, 20, 30}},
		},
	})
	same(keyed, 2, 0, {10, 20, 30, 0}, "chromakey clears its colour")
	same(keyed, 0, 0, {200, 100, 50, 255}, "chromakey leaves the rest")

	-- A blit clipped to a rectangle given in fractions of the canvas: only
	-- the bottom half of a stretched overlay reaches it
	local low = compose("lowpart", {
		size = {4, 4},
		ops = {
			{op = "fill", color = {0, 0, 0, 255}, blend = "set"},
			{op = "blit", src = SRC, fill = true,
					clip = {0, 0.5, 1, 1}, blend = "set"},
		},
	})
	same(low, 0, 0, {0, 0, 0, 255}, "a clipped blit leaves the top alone")
	same(low, 0, 1, {0, 0, 0, 255}, "and the row just above the clip")
	-- The source is 4x2 stretched to 4x4, so both bottom rows come from its
	-- own second row
	same(low, 0, 2, {10, 20, 30, 255}, "a clipped blit writes the bottom")
	same(low, 0, 3, {10, 20, 30, 255}, "all of the bottom")

	-- An 8-bit RGB PNG with a tRNS chunk: transparency as a colour key
	-- rather than an alpha channel. stb_image expands the key into a real
	-- alpha channel, and the vendored copy is patched to report the channel
	-- count the buffer then has -- without that patch the image is read at
	-- the wrong stride and comes out as coloured stripes. See
	-- doc/magic.txt.
	local trns = compose("trns", {ops = {
		{op = "blit", src = "luanti_client/res/trns_test.png"},
	}})
	assert(trns.width == 2 and trns.height == 2,
			"compose_image: the tRNS source is "..trns.width.."x"..
			trns.height)
	same(trns, 0, 0, {200, 100, 50, 255}, "a tRNS PNG's opaque colour")
	same(trns, 1, 1, {200, 100, 50, 255}, "its other opaque texel")
	local keyed_out = pixel(trns, 1, 0)
	assert(keyed_out[4] == 0,
			"compose_image: a tRNS PNG's keyed colour has alpha "..
			keyed_out[4])

	assert(made == 20, "compose_image: made "..made.." images")
end

function M.self_test()
	check_compress()
	check_pack_voxel_volume()
	check_voxel_format()
	check_voxel_variants()
	check_voxel_modifiers()
	check_voxel_look_rules()
	check_compose_image()
end

return M
-- vim: set noet ts=4 sw=4:
