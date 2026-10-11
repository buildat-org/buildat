// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Most of the C functions the game's Lua calls, included by luanti.cpp
// inside struct Module ([SPLITS]: moved out as they were).

	// The two C functions the map goes through

	static Module* module_of(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__luanti_module");
		Module *self = (Module*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		return self;
	}

	// set_node(x, y, z, id, param1, param2)
	// The mapgen's noise, which is Luanti's own value noise: buildat
	// vendored it for its own generators and this is the same code the Lua
	// API is documented against. A mod's NoiseParams table, as the engine
	// wants it.
	static bool read_noise_params(lua_State *L, int idx,
			interface::NoiseParams &np)
	{
		if(!lua_istable(L, idx))
			return false;
		auto number = [&](const char *name, float def){
			lua_getfield(L, idx, name);
			float v = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : def;
			lua_pop(L, 1);
			return v;
		};
		np.offset = number("offset", 0.0f);
		np.scale = number("scale", 1.0f);
		np.seed = (int)number("seed", 0.0f);
		np.octaves = (int)number("octaves", 3.0f);
		// Luanti calls it persistence and took "persist" before that
		np.persist = number("persistence", number("persist", 0.6f));
		np.spread = interface::v3f(100.0f, 100.0f, 100.0f);
		lua_getfield(L, idx, "spread");
		if(lua_istable(L, -1)){
			const int t = lua_gettop(L);
			auto axis = [&](const char *name, float def){
				lua_getfield(L, t, name);
				float v = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) :
						def;
				lua_pop(L, 1);
				return v;
			};
			np.spread.X = axis("x", 100.0f);
			np.spread.Y = axis("y", np.spread.X);
			np.spread.Z = axis("z", np.spread.X);
		}
		lua_pop(L, 1);
		if(np.octaves < 1)
			np.octaves = 1;
		if(np.octaves > 16)
			np.octaves = 16;
		if(np.spread.X == 0.0f) np.spread.X = 1.0f;
		if(np.spread.Y == 0.0f) np.spread.Y = 1.0f;
		if(np.spread.Z == 0.0f) np.spread.Z = 1.0f;
		return true;
	}

	// __luanti_noise_value(np, seed, x, y [, z]) -> one value of it
	static int l_noise_value(lua_State *L)
	{
		interface::NoiseParams np;
		if(!read_noise_params(L, 1, np))
			return luaL_error(L, "noise: a NoiseParams table is wanted");
		const int seed = (int)luaL_checkinteger(L, 2) + np.seed;
		const float x = (float)luaL_checknumber(L, 3) / np.spread.X;
		const float y = (float)luaL_checknumber(L, 4) / np.spread.Y;
		float v;
		if(lua_isnoneornil(L, 5)){
			v = interface::noise2d_fbm(x, y, seed, np.octaves, np.persist);
		} else {
			const float z = (float)luaL_checknumber(L, 5) / np.spread.Z;
			v = interface::noise3d_fbm(x, y, z, seed, np.octaves, np.persist);
		}
		lua_pushnumber(L, np.offset + v * np.scale);
		return 1;
	}

	// __luanti_noise_map(np, seed, x, y, z, sx, sy, sz[, buffer]) -> a flat
	// array, x fastest and then y and then z. sz of 0 is the
	// two-dimensional map, where y is the second axis -- which is the
	// world's z, the way Luanti's own 2D maps are laid out. A buffer is
	// filled and returned, as Luanti fills the one a mod passes: a mod
	// that reads its buffer and not the return value got nothing from an
	// array made fresh (extra_ordinance's mapgen, 2026-10-03).
	static int l_noise_map(lua_State *L)
	{
		interface::NoiseParams np;
		if(!read_noise_params(L, 1, np))
			return luaL_error(L, "noise: a NoiseParams table is wanted");
		const int seed = (int)luaL_checkinteger(L, 2);
		const float x = (float)luaL_checknumber(L, 3);
		const float y = (float)luaL_checknumber(L, 4);
		const float z = (float)luaL_checknumber(L, 5);
		const int sx = (int)luaL_checkinteger(L, 6);
		const int sy = (int)luaL_checkinteger(L, 7);
		const int sz = (int)luaL_optinteger(L, 8, 0);
		if(sx < 1 || sy < 1 || sz < 0)
			return luaL_error(L, "noise: a map of %ix%ix%i", sx, sy, sz);
		const double n = (double)sx * sy * (sz > 0 ? sz : 1);
		// A cap so that a mod asking for a billion values says so rather
		// than taking the server with it. VoxeLibre's mcl_end_island asks
		// for 401 x 30 x 401 -- 4.8 million -- while it loads, which is what
		// this has to be bigger than; Luanti caps it nowhere and pays the
		// same memory. Lua's own formatter has no %.0f, so the number is
		// made into a string here.
		if(n > 16.0 * 1024 * 1024)
			return luaL_error(L, "noise: %s values is more than this makes "
					"at once", cs(itos((int64_t)n)));
		interface::Noise noise(&np, seed, sx, sy, sz > 0 ? sz : 1);
		float *result;
		if(sz > 0)
			result = noise.fbmMap3D(x, y, z);
		else
			result = noise.fbmMap2D(x, y);
		noise.transformNoiseMap();
		if(lua_istable(L, 9))
			lua_pushvalue(L, 9);
		else
			lua_createtable(L, (int)n, 0);
		for(int i = 0; i < (int)n; i++){
			lua_pushnumber(L, result[i]);
			lua_rawseti(L, -2, i + 1);
		}
		return 1;
	}

	// __luanti_get_region_data(x0, y0, z0, x1, y1, z1) -> ids, param1,
	// param2: three flat arrays, x fastest and then y and then z, which is
	// what VoxelArea indexes and what a VoxelManip holds.
	static int l_get_region_data(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t p[6];
		for(int i = 0; i < 6; i++)
			p[i] = luaL_checkinteger(L, i + 1);
		if(p[3] < p[0] || p[4] < p[1] || p[5] < p[2] ||
				!box_ok(p[0], p[1], p[2], p[3], p[4], p[5])){
			for(int i = 0; i < 3; i++)
				lua_newtable(L);
			return 3;
		}
		double volume = (double)(p[3] - p[0] + 1) * (double)(p[4] - p[1] + 1) *
				(double)(p[5] - p[2] + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			return luaL_error(L, "get_region_data(): %.0f voxels is more "
					"than the %d this reads at once", volume,
					(int)MAX_REGION_VOXELS);
		}
		sv_<uint32_t> words;
		self->read_region(p[0], p[1], p[2], p[3], p[4], p[5], words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		const int n = (int)words.size();
		lua_createtable(L, n, 0);
		lua_createtable(L, n, 0);
		lua_createtable(L, n, 0);
		for(int i = 0; i < n; i++){
			const uint32_t word = words[i];
			lua_pushinteger(L, (lua_Integer)f.id.get(word));
			lua_rawseti(L, -4, i + 1);
			lua_pushinteger(L, (lua_Integer)(f.light_sky.get(word) |
					(f.light_lamp.get(word) << 4)));
			lua_rawseti(L, -3, i + 1);
			lua_pushinteger(L, (lua_Integer)f.param.get(word));
			lua_rawseti(L, -2, i + 1);
		}
		return 3;
	}

	// __luanti_set_region_data(x0, y0, z0, x1, y1, z1, ids, param1, param2):
	// the other direction, and one write rather than a quarter of a million.
	// param1 and param2 may be nil, and then what is there is kept.
	//
	// A section the box reaches into that does not exist is created, because
	// a VoxelManip writing where nobody has been is a mapgen doing its job.
	static int l_set_region_data(lua_State *L)
	{
		Module *self = module_of(L);
		self->drop_read_cache();
		int32_t p[6];
		for(int i = 0; i < 6; i++)
			p[i] = luaL_checkinteger(L, i + 1);
		luaL_checktype(L, 7, LUA_TTABLE);
		const bool has_p1 = !lua_isnoneornil(L, 8);
		const bool has_p2 = !lua_isnoneornil(L, 9);
		if(p[3] < p[0] || p[4] < p[1] || p[5] < p[2] ||
				!box_ok(p[0], p[1], p[2], p[3], p[4], p[5]))
			return 0;
		const double volume = (double)(p[3] - p[0] + 1) *
				(double)(p[4] - p[1] + 1) * (double)(p[5] - p[2] + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			return luaL_error(L, "set_region_data(): %.0f voxels is more "
					"than the %d this writes at once", volume,
					(int)MAX_REGION_VOXELS);
		}
		if(!self->m_scene)
			return 0;
		// What is already buffered is part of the map; a region write that
		// went in before it would be overwritten by the older value
		self->flush_node_writes();
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		// Read what is there first when the caller is only replacing some of
		// the planes, so that the light and the param2 it left out survive
		sv_<uint32_t> words;
		if(!has_p1 || !has_p2)
			self->read_region(p[0], p[1], p[2], p[3], p[4], p[5], words);
		else
			words.assign((size_t)volume, 0);
		size_t i = 0;
		for(size_t n = words.size(); i < n; i++){
			lua_rawgeti(L, 7, (int)i + 1);
			const lua_Integer id = lua_tointeger(L, -1);
			lua_pop(L, 1);
			uint32_t word = words[i];
			f.id.set(word, (uint32_t)id & 0xffff);
			if(has_p1){
				lua_rawgeti(L, 8, (int)i + 1);
				const uint32_t param1 = (uint32_t)lua_tointeger(L, -1);
				lua_pop(L, 1);
				f.light_sky.set(word, param1 & 0x0f);
				f.light_lamp.set(word, (param1 >> 4) & 0x0f);
			}
			if(has_p2){
				lua_rawgeti(L, 9, (int)i + 1);
				const uint32_t param2 = (uint32_t)lua_tointeger(L, -1);
				lua_pop(L, 1);
				f.param.set(word, param2 & 0xff);
			}
			words[i] = word;
		}
		// A box in a body's region ([BODY_INTERACT]): the body's owner
		// takes the words voxel by voxel; the map has nothing there
		if(p[1] >= REGION_Y){
			if(self->m_region_map){
				i = 0;
				for(int32_t z = p[2]; z <= p[5]; z++)
				for(int32_t y = p[1]; y <= p[4]; y++)
				for(int32_t x = p[0]; x <= p[3]; x++, i++)
					self->m_region_map->set(x, y, z, words[i]);
			}
			return 0;
		}
		interface::VoxelVolume vol(pv::Region(
				pv::Vector3DInt32(p[0], p[1], p[2]),
				pv::Vector3DInt32(p[3], p[4], p[5])));
		self->note_gen_write(vol.getEnclosingRegion());
		i = 0;
		for(int32_t z = p[2]; z <= p[5]; z++)
		for(int32_t y = p[1]; y <= p[4]; y++)
		for(int32_t x = p[0]; x <= p[3]; x++, i++)
			vol.setVoxelAt(x, y, z, interface::VoxelInstance(words[i]));
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			world->set_cause(self->m_by_player ? "a player" : "");
			world->set_volume(vol, true);
			world->set_cause("");
		});
		return 0;
	}

	// __luanti_refshot_mark(token): tell every client that the state it is
	// looking at is complete as far as this server is concerned, and that it
	// should photograph it once it has drawn what it has been sent.
	//
	// **The ordering is the whole mechanism.** The channel is reliable and
	// ordered, so by the time the client's handler for this runs, every
	// chunk packet sent before it has already been handled -- which is what
	// turns "my mesh queue is empty" from a guess into a fact. See
	// [ONE_CYCLE] in doc/plan/rendering_plan.md.
	static int l_refshot_mark(lua_State *L)
	{
		Module *self = module_of(L);
		const int token = (int)luaL_checkinteger(L, 1);
		// And where the state looks from, so that the client's half of the
		// rule can be about that place rather than about its queue as a
		// whole -- see the comment on the client's handler
		sv_<ss_> flat;
		flat.push_back(itos(token));
		flat.push_back(ftos((float)luaL_optnumber(L, 2, 0.0)));
		flat.push_back(ftos((float)luaL_optnumber(L, 3, 0.0)));
		flat.push_back(ftos((float)luaL_optnumber(L, 4, 0.0)));
		// Optional fifth: "1" means dump the client's meshes too
		if(lua_gettop(L) >= 5 && lua_toboolean(L, 5))
			flat.push_back("1");
		sv_<ss_> names;
		for(const auto &pair : self->m_player_peers)
			names.push_back(pair.first);
		for(const ss_ &n : names)
			self->send_to_player(n, "luanti:refshot_mark", flat);
		lua_pushinteger(L, (lua_Integer)names.size());
		return 1;
	}

	static int l_set_node(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x = luaL_checkinteger(L, 1);
		int32_t y = luaL_checkinteger(L, 2);
		int32_t z = luaL_checkinteger(L, 3);
		uint32_t id = (uint32_t)luaL_checkinteger(L, 4);
		uint32_t param1 = (uint32_t)luaL_optinteger(L, 5, 0);
		uint32_t param2 = (uint32_t)luaL_optinteger(L, 6, 0);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		uint32_t word = 0;
		f.id.set(word, id);
		// param1 is the two light nibbles, which the format binds as two
		// fields; voxelworld owns the sky half, so a mod writing param1
		// writes the lamp half and its own sky value is overwritten by the
		// next flood. That is the same deal Luanti gives a mod.
		f.light_sky.set(word, param1 & 0x0f);
		f.light_lamp.set(word, (param1 >> 4) & 0x0f);
		f.param.set(word, param2 & 0xff);
		self->buffer_node_write(x, y, z, word);
		return 0;
	}

	// flush_node_writes(): what a light query calls before it reads,
	// since the flood a buffered lamp makes is only in the world once the
	// buffer has landed; see read_node()
	static int l_flush_node_writes(lua_State *L)
	{
		module_of(L)->flush_node_writes();
		return 0;
	}

	// __luanti_region_to_world(x, y, z) -> wx, wy, wz, or nil: a body's
	// region position as the world point it is drawn at ([BODY_INTERACT])
	static int l_region_to_world(lua_State *L)
	{
		Module *self = module_of(L);
		float x = (float)luaL_checknumber(L, 1);
		float y = (float)luaL_checknumber(L, 2);
		float z = (float)luaL_checknumber(L, 3);
		float wx, wy, wz;
		if(!self->m_region_map || y < REGION_Y ||
				!self->m_region_map->to_world(x, y, z, wx, wy, wz))
			return 0;
		lua_pushnumber(L, wx);
		lua_pushnumber(L, wy);
		lua_pushnumber(L, wz);
		return 3;
	}

	// get_node(x, y, z) -> id, param1, param2
	static int l_get_node(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x = luaL_checkinteger(L, 1);
		int32_t y = luaL_checkinteger(L, 2);
		int32_t z = luaL_checkinteger(L, 3);
		uint32_t word = self->read_node(x, y, z);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		lua_pushinteger(L, (lua_Integer)f.id.get(word));
		lua_pushinteger(L, (lua_Integer)(f.light_sky.get(word) |
				(f.light_lamp.get(word) << 4)));
		lua_pushinteger(L, (lua_Integer)f.param.get(word));
		return 3;
	}

	// __luanti_ids_at(flat) -> a flat array of content ids, one per position
	// in flat, which is x, y, z per position.
	//
	// The region reads answer "what is in this box"; this answers "what is
	// at each of these scattered places", which is the other shape a caller
	// has. One access() for the lot rather than one per position: a read
	// that crosses the Lua boundary costs a module lock and its hierarchy
	// validated, and the work inside voxelworld is nearly free beside it.
	// The emerge queue asks this of every request it is waiting on, once a
	// step.
	static int l_ids_at(lua_State *L)
	{
		Module *self = module_of(L);
		luaL_checktype(L, 1, LUA_TTABLE);
		const size_t n3 = lua_objlen(L, 1);
		const size_t n = n3 / 3;
		lua_createtable(L, (int)n, 0);
		if(n == 0 || !self->m_scene)
			return 1;
		// Whatever was written and not flushed is what a reader should see,
		// the same way read_node() does it
		self->flush_node_writes();
		sv_<int32_t> p(n3);
		for(size_t i = 0; i < n3; i++){
			lua_rawgeti(L, 1, (int)i + 1);
			p[i] = (int32_t)lua_tointeger(L, -1);
			lua_pop(L, 1);
		}
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		sv_<lua_Integer> ids(n);
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			for(size_t i = 0; i < n; i++){
				const uint32_t word = world->get_voxel(pv::Vector3DInt32(
						p[i * 3], p[i * 3 + 1], p[i * 3 + 2]), true).data;
				ids[i] = (lua_Integer)f.id.get(word);
			}
		});
		for(size_t i = 0; i < n; i++){
			lua_pushinteger(L, ids[i]);
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
	}

	// __luanti_section_state(x, y, z) -> "unloaded", "ungenerated" or
	// "generated", of the section a position is in: what the fuzz run's
	// hole check reads ([UNGENERATED_SAVED]).
	static int l_section_state(lua_State *L)
	{
		Module *self = module_of(L);
		if(!self->m_scene || self->m_section_size.getX() <= 0){
			lua_pushstring(L, "unloaded");
			return 1;
		}
		const pv::Vector3DInt16 sp = self->section_of(pv::Vector3DInt32(
				(int32_t)luaL_checknumber(L, 1),
				(int32_t)luaL_checknumber(L, 2),
				(int32_t)luaL_checknumber(L, 3)));
		const char *state = "unloaded";
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			if(world->is_section_generated(sp))
				state = "generated";
			else if(world->is_section_loaded(sp))
				state = "ungenerated";
		});
		lua_pushstring(L, state);
		return 1;
	}

	// __luanti_loaded_at(flat) -> a flat array of booleans, one per
	// position in flat: whether the section it is in is loaded. What the
	// emerge queue actually asks of its two thousand positions a step --
	// an ungenerated section reads as ignore everywhere -- answered per
	// section in one access(), where a get_voxel() per position was 0.4 s
	// of a step and a region read per block was worse.
	static int l_loaded_at(lua_State *L)
	{
		Module *self = module_of(L);
		luaL_checktype(L, 1, LUA_TTABLE);
		const size_t n3 = lua_objlen(L, 1);
		const size_t n = n3 / 3;
		lua_createtable(L, (int)n, 0);
		if(n == 0 || !self->m_scene || self->m_section_size.getX() <= 0)
			return 1;
		sv_<int32_t> p(n3);
		for(size_t i = 0; i < n3; i++){
			lua_rawgeti(L, 1, (int)i + 1);
			p[i] = (int32_t)lua_tointeger(L, -1);
			lua_pop(L, 1);
		}
		sv_<uint64_t> keys(n);
		sm_<uint64_t, bool> loaded;
		for(size_t i = 0; i < n; i++){
			keys[i] = section_key(self->section_of(pv::Vector3DInt32(
					p[i * 3], p[i * 3 + 1], p[i * 3 + 2])));
			loaded[keys[i]] = false;
		}
		// Generated, in a world with a mapgen: a section can be loaded
		// and not generated, holding only what a neighbour's padding
		// handed it -- the bare terrain under a chunk whose on_generated
		// has not run. A singlenode world's fill marks nothing generated,
		// and there loaded is all there is to wait for.
		const bool fill_only = (self->mapgen_name() == "singlenode");
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			for(auto &pair : loaded){
				const pv::Vector3DInt16 sp = section_from_key(pair.first);
				pair.second = fill_only ? world->is_section_loaded(sp) :
						world->is_section_generated(sp);
			}
		});
		for(size_t i = 0; i < n; i++){
			bool ready = loaded[keys[i]];
			if(ready && !self->m_chunks_pending.empty()){
				using luanti_mapgen::chunk_index;
				const int cx = chunk_index(p[i * 3]);
				const int cy = chunk_index(p[i * 3 + 1]);
				const int cz = chunk_index(p[i * 3 + 2]);
				if(self->m_chunks_pending.count(chunk_key(cx, cy, cz))){
					// Wanted now, so finished: what Luanti's emerge of a
					// block does with its chunk
					ready = false;
					voxelworld::access(self->m_server, self->m_scene,
							[&](voxelworld::Instance *world){
						if(self->ask_chunk(world, cx, cy, cz, true))
							self->m_chunks_to_run.push_back(
									pv::Vector3DInt16(cx, cy, cz));
					});
					if(self->m_load_points_changed){
						self->m_load_points_changed = false;
						self->update_load_points();
					}
				}
			}
			lua_pushboolean(L, ready ? 1 : 0);
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
	}

	// get_region(x0, y0, z0, x1, y1, z1) -> a flat array of content ids, x
	// fastest and then y and then z. Only the ids: what asks for a box asks
	// what is in it, and a table three times the size would be three times
	// the garbage.
	// __luanti_active_boxes() -> the voxel box of every loaded section, as
	// {x0,y0,z0,x1,y1,z1}. This is Luanti's active block list under another
	// name: a sweep over the map -- an ABM -- runs where the map is loaded,
	// and takes one section at a time because the whole world at once is
	// more voxels than one region read is allowed.
	static int l_active_boxes(lua_State *L)
	{
		Module *self = module_of(L);
		const pv::Vector3DInt16 &size = self->m_section_size;
		lua_newtable(L);
		if(size.getX() <= 0 || !self->m_scene)
			return 1;
		int n = 0;
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			for(const pv::Vector3DInt16 &section_p :
					world->get_loaded_sections()){
				if(!self->is_section_active(section_p))
					continue;
				pv::Region r = world->get_section_region_voxels(section_p);
				const int32_t v[6] = {
					r.getLowerCorner().getX(), r.getLowerCorner().getY(),
					r.getLowerCorner().getZ(), r.getUpperCorner().getX(),
					r.getUpperCorner().getY(), r.getUpperCorner().getZ(),
				};
				lua_createtable(L, 6, 0);
				for(int i = 0; i < 6; i++){
					lua_pushinteger(L, v[i]);
					lua_rawseti(L, -2, i + 1);
				}
				lua_rawseti(L, -2, ++n);
			}
		});
		return 1;
	}

	// Every loaded section as a voxel box, whether or not anybody is near
	// it: what core.get_loaded_blocks() answers out of. l_active_boxes()
	// above is the same list with the active range applied.
	static int l_loaded_boxes(lua_State *L)
	{
		Module *self = module_of(L);
		lua_newtable(L);
		if(!self->m_scene)
			return 1;
		int n = 0;
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			for(const pv::Vector3DInt16 &section_p :
					world->get_loaded_sections()){
				pv::Region r = world->get_section_region_voxels(section_p);
				const int32_t v[6] = {
					r.getLowerCorner().getX(), r.getLowerCorner().getY(),
					r.getLowerCorner().getZ(), r.getUpperCorner().getX(),
					r.getUpperCorner().getY(), r.getUpperCorner().getZ(),
				};
				lua_createtable(L, 6, 0);
				for(int i = 0; i < 6; i++){
					lua_pushinteger(L, v[i]);
					lua_rawseti(L, -2, i + 1);
				}
				lua_rawseti(L, -2, ++n);
			}
		});
		return 1;
	}

	// __luanti_show_objects_to(player_name, {id, x, y, z, sx, sy, sz, yaw,
	// ...}): where the objects within the player's send range are and how
	// big, to that player's client ([SERVER_PRESETS] 1). What one looks
	// like is the client half's, and __luanti_show_object_props_to says
	// which look it wears (kind, the shape the client half draws; see
	// appearance_of() in lua/entity.lua), sent when it changes or comes
	// into range rather than every step.
	static int l_show_objects_to(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		size_t n = lua_objlen(L, 2);
		sv_<double> v(n, 0.0);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			v[i] = lua_tonumber(L, -1);
			lua_pop(L, 1);
		}
		auto it = self->m_player_peers.find(ss_(name_p, name_len));
		if(it == self->m_player_peers.end())
			return 0;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(v);
		}
		network::access(self->m_server, [&](network::Interface *inetwork){
			inetwork->send(it->second, "luanti:objects", os.str());
		});
		return 0;
	}
	static int l_show_object_props_to(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(ss_(name_p, name_len), "luanti:object_props",
				flat);
		return 0;
	}

	// __luanti_send_inventory(player_name, {list, size, item, item, ...}):
	// what a player is carrying, to their own client. The strings are flat
	// -- a list's name, how many slots it has, and then that many item
	// strings -- because that is what a cereal array of strings is, and
	// because the client half reads them straight back into lists.
	static int l_send_inventory(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_inventory(name, flat);
		return 0;
	}

	// __luanti_relight(x0, y0, z0, x1, y1, z1[, now]): work the light out again in
	// the sections this box touches. A mod's mapgen writes a chunk of
	// terrain with no light in it and then asks Luanti to light it, which is
	// VoxelManip:calc_lighting(); this is that call's other half.
	static int l_relight(lua_State *L)
	{
		Module *self = module_of(L);
		self->drop_read_cache();
		int32_t p[6];
		for(int i = 0; i < 6; i++)
			p[i] = (int32_t)luaL_checknumber(L, i + 1);
		if(!self->m_scene || p[3] < p[0] || p[4] < p[1] || p[5] < p[2])
			return 0;
		// What is buffered is part of the map, and the light is worked out
		// from what is in the map
		self->flush_node_writes();
		const pv::Region region(pv::Vector3DInt32(p[0], p[1], p[2]),
				pv::Vector3DInt32(p[3], p[4], p[5]));
		// Later, under the tick's budget, not inside the mod's own step
		// ([STEP_SLICE]); a relight asked for by a fixture that reads the
		// light back at once wants BUILDAT_LUANTI_RELIGHT_NOW=1
		// The seventh argument true is core.fix_light: Luanti's is done
		// when it returns, and its callers read the light back at once
		static const bool now_env = getenv("BUILDAT_LUANTI_RELIGHT_NOW") != nullptr;
		const bool now = now_env || lua_toboolean(L, 7);
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			if(now)
				world->relight_region(region);
			else
				world->relight_region_later(region);
		});
		return 0;
	}

	// The level a player can stand at above (x, z), asked of the mapgen
	// rather than of the map: Luanti's spawn search does the same thing,
	// because at the moment a player joins the map around the origin is
	// half generated and answers about the world as it was rather than as
	// it will be. nil means the mapgen says this is no place to spawn -- a
	// river, or a surface under water -- or that there is no mapgen to ask.
	static int l_spawn_level(lua_State *L)
	{
		Module *self = module_of(L);
		const int x = (int)luaL_checknumber(L, 1);
		const int z = (int)luaL_checknumber(L, 2);
		int level = 0;
		bool ok = false;
		luanti_mapgen::access(self->m_server,
				[&](luanti_mapgen::Interface *im){
			ok = im->spawn_level(self->m_mapgen_params, x, z, level);
		});
		if(!ok)
			return 0;
		lua_pushinteger(L, level);
		return 1;
	}

	// __luanti_biome_at(x, y, z) -> index, heat, humidity, out of the
	// mapgen's own noise: which biome the world would have there, whether or
	// not anything has been generated. What asks is core.get_biome_data(),
	// and a game asks it a great deal -- VoxeLibre's weather and its sky
	// colour are per biome, and both ran into a nil every step without it.
	// The lookup object, taken once through access() and asked directly
	// after: an access() is a handoff to the mapgen module's thread and
	// back, a quarter of a millisecond, and VoxeLibre asks this for every
	// leaf it recolours. Dropped when luanti_mapgen unloads, and with a
	// new world's params.
	luanti_mapgen::BiomeQuery *m_biome_query = nullptr;

	void on_module_unloaded(const interface::ModuleUnloadedEvent &event)
	{
		if(event.name == "luanti_mapgen")
			m_biome_query = nullptr;
	}

	static int l_biome_at(lua_State *L)
	{
		Module *self = module_of(L);
		const int x = (int)luaL_checknumber(L, 1);
		const int y = (int)luaL_checknumber(L, 2);
		const int z = (int)luaL_checknumber(L, 3);
		size_t index = 0;
		float heat = 0.0f, humidity = 0.0f;
		bool ok = false;
		if(self->m_biome_query == nullptr){
			luanti_mapgen::access(self->m_server,
					[&](luanti_mapgen::Interface *im){
				self->m_biome_query = im->biome_query(self->m_mapgen_params);
			});
		}
		if(self->m_biome_query != nullptr)
			ok = self->m_biome_query->biome_at(x, y, z, index, heat, humidity);
		if(!ok)
			return 0;
		lua_pushinteger(L, (lua_Integer)index);
		lua_pushnumber(L, heat);
		lua_pushnumber(L, humidity);
		return 3;
	}

	// Where the server says the player is: the spawn, a teleport, a mod
	// moving them. Where the player walks is the client's own business and
	// arrives as set_player_pos(); this is the other direction, and without
	// it a player who was somewhere else last time starts wherever their
	// client felt like.
	static int l_send_player_pos(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		sv_<ss_> flat;
		for(int i = 2; i <= 4; i++){
			char buf[32];
			snprintf(buf, sizeof buf, "%.3f",
					(double)luaL_checknumber(L, i));
			flat.push_back(buf);
		}
		// And which object is the player's own; see tell_the_client()
		flat.push_back(itos((int64_t)luaL_optnumber(L, 5, 0)));
		// And which way they were facing, in Luanti's own angles: the
		// horizontal one counter-clockwise from +Z and the vertical one
		// positive downwards, both in radians, which is what
		// get_look_horizontal() and get_look_vertical() answer.
		// The client turns them into its own convention -- see send_where()
		// in apps/vanilla, which is this in reverse.
		for(int i = 6; i <= 7; i++){
			char buf[32];
			snprintf(buf, sizeof buf, "%.4f",
					(double)luaL_optnumber(L, i, 0));
			flat.push_back(buf);
		}
		self->send_to_player(name, "luanti:player_pos", flat);
		return 0;
	}

	// What time it is in the world, to everyone: the time of day as a
	// fraction of a day and how fast it runs, so a client can carry the
	// clock on between one of these and the next
	static int l_send_time(lua_State *L)
	{
		Module *self = module_of(L);
		sv_<ss_> flat;
		for(int i = 1; i <= 2; i++){
			char buf[32];
			snprintf(buf, sizeof buf, "%.6f",
					(double)luaL_checknumber(L, i));
			flat.push_back(buf);
		}
		// And when it was sent, the server's clock in microseconds, so
		// the client can read how long the packet waited behind bulk on
		// the way down ([NET_CHANNELS]; the up direction is main:where's)
		char stamp[32];
		snprintf(stamp, sizeof stamp, "%lld", (long long)interface::os::time_us());
		flat.push_back(stamp);
		sv_<ss_> names;
		for(const auto &pair : self->m_player_peers)
			names.push_back(pair.first);
		for(const ss_ &n : names)
			self->send_to_player(n, "luanti:time", flat);
		return 0;
	}

	// One change to a player's own HUD: what a game adds, changes and takes
	// away, as the flat list of strings lua/entity.lua builds
	static int l_send_hud(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:hud", flat);
		return 0;
	}

	// __luanti_send_privs(player_name, {priv, priv, ...}): what the player
	// may do, on join and whenever it changes; the client gates its fly,
	// fast and noclip on it ([FLY_MODES])
	static int l_send_privs(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:privs", flat);
		return 0;
	}

	// __luanti_send_physics(player_name, {name, value, name, value, ...}):
	// a player's physics override, which is what set_physics_override()
	// writes. The client's movement is its own constants times these, so a
	// game's speed boots and low gravity are these numbers arriving.
	static int l_send_physics(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:physics", flat);
		return 0;
	}

	// __luanti_send_modes(player_name, {"fly", "fast", "noclip"}): the
	// modes the player left on in this world, on join ([FLY_STATE_SAVE]).
	// See send_modes() in lua/entity.lua.
	static int l_send_modes(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		for(size_t i = 0; i < lua_objlen(L, 2); i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(ss_(name_p, name_len), "luanti:modes", flat);
		return 0;
	}

	// __luanti_send_camera(player_name, {fov, is_multiplier, transition,
	// eye_x, eye_y, eye_z}): how wide the view is and where the eyes are,
	// which are the client's to draw and the game's to decide. See
	// send_camera() in lua/entity.lua.
	static int l_send_camera(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:camera", flat);
		return 0;
	}

	// What the light should be for one player whatever the hour, or an
	// empty string for "the clock decides"
	// __luanti_send_sound(player_name, {...}): one sound's record at one
	// player; see lua/sound.lua for what the fields are
	static int l_send_sound(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:sound", flat);
		return 0;
	}

	// __luanti_send_particles(player_name, {...}): one particle record at
	// one player; see lua/particles.lua for what the fields are
	static int l_send_particles(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:particles", flat);
		return 0;
	}

	// __luanti_sound_file(group) -> one file of the group, or nil
	//
	// A game names a sound group and the media holds the files in it:
	// "default_dig_cracky" is default_dig_cracky.1.ogg and .2.ogg, and which
	// one plays is a choice per play. The module is what knows which files
	// it serves, which is why the pick is here rather than in the Lua.
	// __luanti_add_media(name, path) -> whether it was added: one more file
	// into what this game serves, while it runs. A mod that draws a picture
	// and hands it to core.dynamic_add_media() is what wants it --
	// VoxeLibre's maps are drawn per map item and per player.
	//
	// client_file announces a file to every connected client as it is added,
	// so nothing else has to be sent; the name is the game's own, the way
	// every other media file's is.
	static int l_add_media(lua_State *L)
	{
		Module *self = module_of(L);
		const ss_ name = luaL_checkstring(L, 1);
		const ss_ path = luaL_checkstring(L, 2);
		if(name.empty() || path.empty() || !interface::fs::path_exists(path)){
			lua_pushboolean(L, false);
			return 1;
		}
		client_file::access(self->m_server, [&](client_file::Interface *i){
			i->add_file_path(media_resource_name(name), path);
		});
		self->m_served_media[name] = path;
		lua_pushboolean(L, true);
		return 1;
	}

	static int l_sound_file(lua_State *L)
	{
		Module *self = module_of(L);
		size_t len = 0;
		const char *p = luaL_checklstring(L, 1, &len);
		ss_ group(p ? p : "", len);
		if(group.empty())
			return 0;
		sv_<ss_> files;
		// Luanti's own suffixes: the plain name and one digit, which is
		// what its media lookup accepts. The names are asked for rather
		// than scanned for, because what the module serves is a hash map.
		if(self->m_served_media.count(group+".ogg"))
			files.push_back(group+".ogg");
		for(char d = '0'; d <= '9'; d++){
			const ss_ name = group+"."+d+".ogg";
			if(self->m_served_media.count(name))
				files.push_back(name);
		}
		if(files.empty())
			return 0;
		const ss_ &pick = files[rand() % files.size()];
		lua_pushlstring(L, pick.c_str(), pick.size());
		return 1;
	}

	// __luanti_sound_files(group) -> {file, file, ...}, or nil
	//
	// The same lookup as __luanti_sound_file, without the pick: what a
	// client needs to play a sound of its own off a node's definition
	// ([NO_SOUND]'s footsteps), since the group is the module's to
	// resolve and the choice per step is the client's.
	static int l_sound_files(lua_State *L)
	{
		Module *self = module_of(L);
		size_t len = 0;
		const char *p = luaL_checklstring(L, 1, &len);
		ss_ group(p ? p : "", len);
		if(group.empty())
			return 0;
		sv_<ss_> files;
		if(self->m_served_media.count(group+".ogg"))
			files.push_back(group+".ogg");
		for(char d = '0'; d <= '9'; d++){
			const ss_ name = group+"."+d+".ogg";
			if(self->m_served_media.count(name))
				files.push_back(name);
		}
		if(files.empty())
			return 0;
		lua_newtable(L);
		for(size_t i = 0; i < files.size(); i++){
			lua_pushlstring(L, files[i].c_str(), files[i].size());
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
	}

	static int l_send_day_night(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0, v_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		const char *v_p = luaL_checklstring(L, 2, &v_len);
		sv_<ss_> flat{ss_(v_p ? v_p : "", v_len)};
		self->send_to_player(ss_(name_p ? name_p : "", name_len),
				"luanti:daynight", flat);
		return 0;
	}

	// The sky one player is under, as the flat key/value list
	// lua/entity.lua builds
	static int l_send_sky(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(ss_(name_p ? name_p : "", name_len),
				"luanti:sky", flat);
		return 0;
	}

	// [BUILDAT_WIELD_LIGHT] Every dynamic light, as the flat list
	// lua/buildat_api.lua builds
	static int l_send_lights(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(ss_(name_p ? name_p : "", name_len),
				"luanti:lights", flat);
		return 0;
	}

	// A line of chat to one player, or to everyone when the name is empty
	// __luanti_request_shutdown(message): the server stops, the message in
	// its reason; core.request_shutdown's delay and reconnect are Lua's
	static int l_request_shutdown(lua_State *L)
	{
		Module *self = module_of(L);
		size_t len = 0;
		const char *p = luaL_optlstring(L, 1, "", &len);
		self->m_server->shutdown(0, "a mod asked: "+ss_(p ? p : "", len));
		return 0;
	}

	static int l_send_chat(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0, msg_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		const char *msg_p = luaL_checklstring(L, 2, &msg_len);
		ss_ name(name_p ? name_p : "", name_len);
		sv_<ss_> flat{ss_(msg_p ? msg_p : "", msg_len)};
		if(name.empty()){
			// A copy, because a client that drops out while this is going
			// out would otherwise change the map underneath it
			sv_<ss_> names;
			for(const auto &pair : self->m_player_peers)
				names.push_back(pair.first);
			for(const ss_ &n : names)
				self->send_to_player(n, "luanti:chat", flat);
		} else {
			self->send_to_player(name, "luanti:chat", flat);
		}
		return 0;
	}

	void send_inventory(const ss_ &name, const sv_<ss_> &flat)
	{
		send_to_player(name, "luanti:inventory", flat);
	}

	// An array of strings to one player's client, or nowhere if that name is
	// not on the other end of one
	void send_to_player(const ss_ &name, const ss_ &packet_name,
			const sv_<ss_> &flat)
	{
		auto it = m_player_peers.find(name);
		if(it == m_player_peers.end())
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(it->second, packet_name, os.str());
		});
	}

	// __luanti_show_formspec(player_name, formname, spec): the window a mod
	// puts on a player's screen. An empty spec takes it away, which is what
	// core.close_formspec() is. The client draws it and sends back what was
	// pressed; see luanti:fields below.
	static int l_show_formspec(lua_State *L)
	{
		Module *self = module_of(L);
		sv_<ss_> flat;
		for(int i = 1; i <= 4; i++){
			size_t len = 0;
			const char *p = luaL_checklstring(L, i, &len);
			flat.push_back(ss_(p ? p : "", len));
		}
		ss_ name = flat[0];
		flat.erase(flat.begin());
		self->send_to_player(name, "luanti:formspec", flat);
		return 0;
	}

	// __luanti_send_node_inventory(player_name, {pos, list, size, item, ...}):
	// what is in the node the player's open form is about, to that one
	// client. The position leads because it is what says which node the
	// lists belong to; the rest is shaped the way a player's own lists are.
	static int l_send_node_inventory(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:node_inventory", flat);
		return 0;
	}

	// __luanti_player_formspec(player_name, spec): the form the player's own
	// inventory key opens, which is theirs until a mod changes it. Sent when
	// it changes rather than when it is asked for, because a client that has
	// it can open it without a round trip.
	static int l_player_formspec(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0, spec_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		const char *spec_p = luaL_checklstring(L, 2, &spec_len);
		sv_<ss_> flat;
		flat.push_back(ss_(spec_p ? spec_p : "", spec_len));
		self->send_to_player(ss_(name_p ? name_p : "", name_len),
				"luanti:player_formspec", flat);
		return 0;
	}
