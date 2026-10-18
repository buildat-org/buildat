// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// What a vendored mapgen is told: the game's nodes, biomes, ores and
// decorations and the world's mapgen settings, read from Lua
// ([LUANTI_MODULAR]: a part of the Module, with references to the game's
// Lua state, the save's store and whether the world is new).
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/mutex.h"
#include "storage/api.h"
#include "luanti_mapgen/api.h"
#include "luanti/lua_util.h"
#include <map>
extern "C" {
#include <lua.h>
}

namespace luanti {

struct MapgenParams
{
	lua_State *&m_lua;
	interface::Mutex &m_lua_mutex;
	storage::Store *&m_store;
	const bool &m_world_is_new;

	MapgenParams(lua_State *&lua, interface::Mutex &lua_mutex,
			storage::Store *&store, const bool &world_is_new):
		m_lua(lua), m_lua_mutex(lua_mutex), m_store(store),
		m_world_is_new(world_is_new)
	{}

	// Every node name the game registered and the id it got, which is what
	// a vendored mapgen is told to build with: it asks for "mapgen_stone"
	// and the game's own aliases say what that is here.
	//
	// simplified: all of them, because the whole table is a few hundred
	// short strings and which ones a mapgen wants depends on the mapgen.
	// What a mapgen asks about a node, nine values each: the id, then
	// walkable, is_ground_content, floodable, light_propagates,
	// sunlight_propagates, the liquid type, the drawtype as the game's own
	// word for it, and whether the node stores light. The same order
	// core.__mapgen_node_props() writes them in.
	sm_<uint32_t, luanti_mapgen::Params::NodeProps> mapgen_node_props()
	{
		sm_<uint32_t, luanti_mapgen::Params::NodeProps> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_node_props");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__mapgen_node_props(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const size_t n = lua_istable(L, -1) ? lua_objlen(L, -1) : 0;
		for(size_t i = 1; i + 8 <= n; i += 9){
			lua_Integer v[9];
			ss_ drawtype = "normal";
			for(int k = 0; k < 9; k++){
				lua_rawgeti(L, -1, (int)(i + k));
				if(k == 7){
					const char *word = lua_tostring(L, -1);
					if(word)
						drawtype = word;
					v[k] = 0;
				} else {
					v[k] = lua_tointeger(L, -1);
				}
				lua_pop(L, 1);
			}
			luanti_mapgen::Params::NodeProps p;
			p.walkable = v[1] != 0;
			p.is_ground_content = v[2] != 0;
			p.floodable = v[3] != 0;
			p.light_propagates = v[4] != 0;
			p.sunlight_propagates = v[5] != 0;
			p.liquid_type = (int)v[6];
			p.drawtype = drawtype;
			p.param_type_light = v[8] != 0;
			out[(uint32_t)v[0]] = p;
		}
		lua_settop(L, base);
		return out;
	}

	// The biomes a game registered, as core.__mapgen_biomes() builds them:
	// one table each, with the node names already the ids they mean
	sv_<luanti_mapgen::Params::Biome> mapgen_biomes()
	{
		sv_<luanti_mapgen::Params::Biome> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_biomes");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__mapgen_biomes(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const size_t n = lua_istable(L, -1) ? lua_objlen(L, -1) : 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			luanti_mapgen::Params::Biome b;
			b.name = table_string(L, "name");
			b.c_top = (uint32_t)table_number(L, "c_top", 0);
			b.c_filler = (uint32_t)table_number(L, "c_filler", 0);
			b.c_stone = (uint32_t)table_number(L, "c_stone", 0);
			b.c_water_top = (uint32_t)table_number(L, "c_water_top", 0);
			b.c_water = (uint32_t)table_number(L, "c_water", 0);
			b.c_river_water = (uint32_t)table_number(L, "c_river_water", 0);
			b.c_riverbed = (uint32_t)table_number(L, "c_riverbed", 0);
			b.c_dust = (uint32_t)table_number(L, "c_dust", 0);
			b.c_dungeon = (uint32_t)table_number(L, "c_dungeon", 0);
			b.c_dungeon_alt = (uint32_t)table_number(L, "c_dungeon_alt", 0);
			b.c_dungeon_stair =
					(uint32_t)table_number(L, "c_dungeon_stair", 0);
			b.depth_top = (int32_t)table_number(L, "depth_top", 0);
			b.depth_filler = (int32_t)table_number(L, "depth_filler", 0);
			b.depth_water_top =
					(int32_t)table_number(L, "depth_water_top", 0);
			b.depth_riverbed = (int32_t)table_number(L, "depth_riverbed", 0);
			b.y_min = (int32_t)table_number(L, "y_min", -31000);
			b.y_max = (int32_t)table_number(L, "y_max", 31000);
			b.x_min = (int32_t)table_number(L, "x_min", -31000);
			b.x_max = (int32_t)table_number(L, "x_max", 31000);
			b.z_min = (int32_t)table_number(L, "z_min", -31000);
			b.z_max = (int32_t)table_number(L, "z_max", 31000);
			b.heat_point = (float)table_number(L, "heat_point", 0);
			b.humidity_point = (float)table_number(L, "humidity_point", 0);
			b.vertical_blend = (int32_t)table_number(L, "vertical_blend", 0);
			b.weight = (float)table_number(L, "weight", 1);
			out.push_back(b);
			lua_pop(L, 1);
		}
		lua_settop(L, base);
		log_i(MODULE, "%zu biomes for the mapgen", out.size());
		return out;
	}

	// A noise as a mod wrote it, off the table the Lua side built
	luanti_mapgen::Params::NoiseParams read_np(lua_State *L,
			const char *field)
	{
		luanti_mapgen::Params::NoiseParams np;
		lua_getfield(L, -1, field);
		if(lua_istable(L, -1)){
			np.given = table_boolean(L, "given");
			np.offset = (float)table_number(L, "offset", 0);
			np.scale = (float)table_number(L, "scale", 1);
			np.spread_x = (float)table_number(L, "spread_x", 250);
			np.spread_y = (float)table_number(L, "spread_y", 250);
			np.spread_z = (float)table_number(L, "spread_z", 250);
			np.seed = (int32_t)table_number(L, "seed", 0);
			np.octaves = (int32_t)table_number(L, "octaves", 3);
			np.persist = (float)table_number(L, "persist", 0.6);
			np.lacunarity = (float)table_number(L, "lacunarity", 2);
			np.flags = table_string(L, "flags");
		}
		lua_pop(L, 1);
		return np;
	}

	// What the game asked the mapgen to report, which is what
	// core.set_gen_notify() has been told. Read once, when the world's
	// generator is made.
	//
	// simplified: a mod that calls core.set_gen_notify() after the world
	// has started is not heard -- the generator holds a copy and runs in
	// another thread. Every mod that asks does it while it loads, which is
	// before this is read. Telling the generator later would be a message
	// to luanti_mapgen and a lock around the flags in every mapgen.
	void mapgen_gen_notify(ss_ &flags_out, sv_<uint32_t> &deco_ids_out)
	{
		if(!m_lua)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "get_gen_notify");
		if(lua_pcall(L, 0, 2, 0) != 0){
			log_w(MODULE, "get_gen_notify(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		if(lua_isstring(L, -2))
			flags_out = lua_tostring(L, -2);
		if(lua_istable(L, -1)){
			const size_t n = lua_objlen(L, -1);
			for(size_t i = 1; i <= n; i++){
				lua_rawgeti(L, -1, (int)i);
				deco_ids_out.push_back((uint32_t)lua_tonumber(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
	}

	// The ores the game registered, in the shape luanti_mapgen builds its
	// OreManager out of. The same crossing as the biomes, one layer down.
	sv_<luanti_mapgen::Params::Ore> mapgen_ores()
	{
		sv_<luanti_mapgen::Params::Ore> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_ores");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__mapgen_ores(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const size_t n = lua_istable(L, -1) ? lua_objlen(L, -1) : 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			luanti_mapgen::Params::Ore o;
			o.name = table_string(L, "name");
			o.type = table_string(L, "type");
			o.c_ore = (uint32_t)table_number(L, "c_ore", 0);
			o.clust_scarcity = (int32_t)table_number(L, "clust_scarcity", 1);
			o.clust_num_ores = (int32_t)table_number(L, "clust_num_ores", 1);
			o.clust_size = (int32_t)table_number(L, "clust_size", 0);
			o.y_min = (int32_t)table_number(L, "y_min", -31000);
			o.y_max = (int32_t)table_number(L, "y_max", 31000);
			o.ore_param2 = (int32_t)table_number(L, "ore_param2", 0);
			o.flags = table_string(L, "flags");
			o.nthresh = (float)table_number(L, "nthresh", 0);
			o.column_height_min =
					(int32_t)table_number(L, "column_height_min", 1);
			o.column_height_max =
					(int32_t)table_number(L, "column_height_max", 0);
			o.column_midpoint_factor =
					(float)table_number(L, "column_midpoint_factor", 0.5);
			o.random_factor = (float)table_number(L, "random_factor", 1);
			o.stratum_thickness =
					(int32_t)table_number(L, "stratum_thickness", 8);
			o.np = read_np(L, "np");
			o.np_puff_top = read_np(L, "np_puff_top");
			o.np_puff_bottom = read_np(L, "np_puff_bottom");
			o.np_stratum_thickness = read_np(L, "np_stratum_thickness");
			lua_getfield(L, -1, "c_wherein");
			if(lua_istable(L, -1)){
				const size_t m = lua_objlen(L, -1);
				for(size_t j = 1; j <= m; j++){
					lua_rawgeti(L, -1, (int)j);
					o.c_wherein.push_back((uint32_t)lua_tonumber(L, -1));
					lua_pop(L, 1);
				}
			}
			lua_pop(L, 1);
			lua_getfield(L, -1, "biomes");
			if(lua_istable(L, -1)){
				const size_t m = lua_objlen(L, -1);
				for(size_t j = 1; j <= m; j++){
					lua_rawgeti(L, -1, (int)j);
					const char *p = lua_tostring(L, -1);
					if(p)
						o.biomes.push_back(ss_(p));
					lua_pop(L, 1);
				}
			}
			lua_pop(L, 1);
			out.push_back(o);
			lua_pop(L, 1);
		}
		lua_settop(L, base);
		log_i(MODULE, "%zu ores for the mapgen", out.size());
		return out;
	}

	// A list of numbers off a table field, for the id lists a decoration and
	// an ore cross with
	static void read_id_list(lua_State *L, const char *field,
			sv_<uint32_t> &out)
	{
		lua_getfield(L, -1, field);
		if(lua_istable(L, -1)){
			const size_t n = lua_objlen(L, -1);
			for(size_t i = 1; i <= n; i++){
				lua_rawgeti(L, -1, (int)i);
				out.push_back((uint32_t)lua_tonumber(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_pop(L, 1);
	}

	static void read_int_list(lua_State *L, const char *field,
			sv_<int32_t> &out)
	{
		lua_getfield(L, -1, field);
		if(lua_istable(L, -1)){
			const size_t n = lua_objlen(L, -1);
			for(size_t i = 1; i <= n; i++){
				lua_rawgeti(L, -1, (int)i);
				out.push_back((int32_t)lua_tonumber(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_pop(L, 1);
	}

	static void read_string_list(lua_State *L, const char *field,
			sv_<ss_> &out)
	{
		lua_getfield(L, -1, field);
		if(lua_istable(L, -1)){
			const size_t n = lua_objlen(L, -1);
			for(size_t i = 1; i <= n; i++){
				lua_rawgeti(L, -1, (int)i);
				const char *p = lua_tostring(L, -1);
				if(p)
					out.push_back(ss_(p));
				lua_pop(L, 1);
			}
		}
		lua_pop(L, 1);
	}

	// The decorations the game registered, in the shape luanti_mapgen builds
	// its DecorationManager out of
	sv_<luanti_mapgen::Params::Decoration> mapgen_decorations()
	{
		sv_<luanti_mapgen::Params::Decoration> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_decorations");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__mapgen_decorations(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const size_t n = lua_istable(L, -1) ? lua_objlen(L, -1) : 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			luanti_mapgen::Params::Decoration d;
			d.name = table_string(L, "name");
			d.type = table_string(L, "type");
			d.sidelen = (int32_t)table_number(L, "sidelen", 8);
			d.fill_ratio = (float)table_number(L, "fill_ratio", 0.02);
			d.y_min = (int32_t)table_number(L, "y_min", -31000);
			d.y_max = (int32_t)table_number(L, "y_max", 31000);
			d.flags = table_string(L, "flags");
			d.nspawnby = (int32_t)table_number(L, "nspawnby", -1);
			d.place_offset_y = (int32_t)table_number(L, "place_offset_y", 0);
			d.check_offset = (int32_t)table_number(L, "check_offset", -1);
			d.deco_height = (int32_t)table_number(L, "deco_height", 1);
			d.deco_height_max =
					(int32_t)table_number(L, "deco_height_max", 0);
			d.deco_param2 = (int32_t)table_number(L, "deco_param2", 0);
			d.deco_param2_max =
					(int32_t)table_number(L, "deco_param2_max", 0);
			d.rotation = table_string(L, "rotation");
			d.np = read_np(L, "np");
			read_id_list(L, "c_place_on", d.c_place_on);
			read_id_list(L, "c_spawnby", d.c_spawnby);
			read_id_list(L, "c_decos", d.c_decos);
			read_string_list(L, "biomes", d.biomes);
			lua_getfield(L, -1, "ltree");
			if(lua_istable(L, -1)){
				luanti_mapgen::Params::Decoration::LTree &t = d.ltree;
				t.given = table_boolean(L, "given");
				t.axiom = table_string(L, "axiom");
				t.rules_a = table_string(L, "rules_a");
				t.rules_b = table_string(L, "rules_b");
				t.rules_c = table_string(L, "rules_c");
				t.rules_d = table_string(L, "rules_d");
				t.c_trunk = (uint32_t)table_number(L, "c_trunk", 0);
				t.c_leaves = (uint32_t)table_number(L, "c_leaves", 0);
				t.c_leaves2 = (uint32_t)table_number(L, "c_leaves2", 0);
				t.c_fruit = (uint32_t)table_number(L, "c_fruit", 0);
				t.leaves2_chance =
						(int32_t)table_number(L, "leaves2_chance", 0);
				t.angle = (int32_t)table_number(L, "angle", 0);
				t.iterations = (int32_t)table_number(L, "iterations", 2);
				t.random_level = (int32_t)table_number(L, "random_level", 0);
				t.trunk_type = table_string(L, "trunk_type");
				t.thin_branches = table_boolean(L, "thin_branches");
				t.fruit_chance = (int32_t)table_number(L, "fruit_chance", 0);
				t.seed = (int32_t)table_number(L, "seed", 0);
				t.explicit_seed = table_boolean(L, "explicit_seed");
			}
			lua_pop(L, 1);
			lua_getfield(L, -1, "schematic");
			if(lua_istable(L, -1)){
				luanti_mapgen::Params::Schematic &sch = d.schematic;
				sch.given = table_boolean(L, "given");
				sch.file = table_string(L, "file");
				sch.size_x = (int32_t)table_number(L, "size_x", 0);
				sch.size_y = (int32_t)table_number(L, "size_y", 0);
				sch.size_z = (int32_t)table_number(L, "size_z", 0);
				read_string_list(L, "node_names", sch.node_names);
				read_id_list(L, "ids", sch.ids);
				read_int_list(L, "param1", sch.param1);
				read_int_list(L, "param2", sch.param2);
				read_int_list(L, "yslice_prob", sch.yslice_prob);
				lua_getfield(L, -1, "replacements");
				if(lua_istable(L, -1)){
					lua_pushnil(L);
					while(lua_next(L, -2) != 0){
						const char *k = lua_tostring(L, -2);
						const char *v = lua_tostring(L, -1);
						if(k && v)
							sch.replacements[ss_(k)] = ss_(v);
						lua_pop(L, 1);
					}
				}
				lua_pop(L, 1);
			}
			lua_pop(L, 1);
			out.push_back(d);
			lua_pop(L, 1);
		}
		lua_settop(L, base);
		log_i(MODULE, "%zu decorations for the mapgen", out.size());
		return out;
	}

	sm_<ss_, uint32_t> content_ids_by_name()
	{
		sm_<ss_, uint32_t> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__content_ids_by_name");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__content_ids_by_name(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		if(lua_istable(L, -1)){
			lua_pushnil(L);
			while(lua_next(L, -2) != 0){
				size_t len = 0;
				const char *name = lua_tolstring(L, -2, &len);
				const lua_Integer id = lua_tointeger(L, -1);
				if(name && id >= 0)
					out[ss_(name, len)] = (uint32_t)id;
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
		return out;
	}

	// The game's aliases whose target is a node, for the save's names
	// (voxelworld's set_name_aliases(), [FEATURE_SWEEP_1009])
	std::map<ss_, ss_> node_aliases()
	{
		std::map<ss_, ss_> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__aliases");
		lua_getfield(L, -2, "__content_ids");
		if(lua_istable(L, -2) && lua_istable(L, -1)){
			lua_pushnil(L);
			while(lua_next(L, -3) != 0){
				// lua_tostring on a number key would break lua_next
				if(lua_type(L, -2) == LUA_TSTRING &&
						lua_type(L, -1) == LUA_TSTRING){
					const char *from = lua_tostring(L, -2);
					const char *to = lua_tostring(L, -1);
					// A name that is registered is that node, alias or not,
					// as in Luanti ([SAVE_CHECKPOINT]: VoxeLibre has one,
					// and it cost every section saved a recompression)
					lua_getfield(L, -3, from);
					const bool registered = !lua_isnil(L, -1);
					lua_pop(L, 1);
					lua_getfield(L, -3, to);
					if(!registered && !lua_isnil(L, -1))
						out[from] = to;
					lua_pop(L, 1);
				}
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
		return out;
	}

	// What the world's own settings call the mapgen. This is Luanti's
	// map_meta.txt: the mapgen a world was made with belongs to the world
	// and not to the configuration, so it is written into the save the
	// first time and read from there afterwards -- otherwise a world grows
	// a second kind of terrain the day the default changes.
	//
	// A save nobody has opened gets what the settings say and, failing
	// that, what Luanti gives a new world: v7. A save that was played
	// before any of this was written down gets what it was played with,
	// which was singlenode.
	void publish_lbm_introduced()
	{
		ss_ names;
		if(m_store)
			m_store->get("lbm_introduced", names);
		lua_pushstring(m_lua, names.c_str());
		lua_setglobal(m_lua, "__luanti_lbm_introduced");
	}

	ss_ mapgen_name()
	{
		ss_ stored;
		if(m_store && m_store->get("mg_name", stored) && !stored.empty())
			return stored;
		ss_ out = mapgen_name_from_settings();
		if(out.empty())
			out = m_world_is_new ? "valleys" : "singlenode";
		if(m_store)
			m_store->set("mg_name", out);
		log_i(MODULE, "mapgen %s, stored for this world", out.c_str());
		return out;
	}

	// Where the water line is, which every mapgen builds around. Luanti
	// keeps it in map_meta.txt beside the mapgen's name, so it is the
	// world's and not the configuration's: the save's own if it has one,
	// then what the game's settings say, and then Luanti's default.
	int mapgen_water_level()
	{
		ss_ stored;
		if(m_store && m_store->get("water_level", stored) && !stored.empty())
			return atoi(stored.c_str());
		ss_ from_settings = setting_string("water_level");
		const int out = from_settings.empty() ? 1 :
				atoi(from_settings.c_str());
		if(m_store)
			m_store->set("water_level", itos(out));
		return out;
	}

	// And which of the things a mapgen makes it is told to make: caves,
	// dungeons, the light, the decorations, the biomes, the ores. Luanti's
	// own words, and the same place as the water level.
	ss_ mapgen_flags()
	{
		ss_ stored;
		if(m_store && m_store->get("mg_flags", stored) && !stored.empty())
			return stored;
		ss_ out = setting_string("mg_flags");
		if(out.empty())
			out = "caves,dungeons,light,decorations,biomes,ores";
		if(m_store)
			m_store->set("mg_flags", out);
		return out;
	}

	// One of the world's settings as Lua has it, which is world.mt over the
	// defaults the vendored settingtypes.txt carries
	ss_ setting_string(const ss_ &name)
	{
		if(!m_lua)
			return "";
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "settings");
		lua_getfield(L, -1, "get");
		lua_pushvalue(L, -2);
		lua_pushlstring(L, name.c_str(), name.size());
		ss_ out;
		if(lua_pcall(L, 2, 1, 0) == 0){
			size_t len = 0;
			const char *str = lua_tolstring(L, -1, &len);
			if(str && len)
				out = ss_(str, len);
		}
		lua_settop(L, base);
		return out;
	}

	ss_ mapgen_name_from_settings()
	{
		if(!m_lua)
			return "";
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_name");
		lua_pushboolean(L, m_world_is_new);
		ss_ out;
		if(lua_pcall(L, 1, 1, 0) == 0){
			size_t len = 0;
			const char *s = lua_tolstring(L, -1, &len);
			if(s && len)
				out = ss_(s, len);
		}
		lua_settop(L, base);
		return out;
	}
};

}
// vim: set noet ts=4 sw=4:
