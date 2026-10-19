// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The world's clock and seed ([LUANTI_MODULAR]: a part of the Module,
// owning the seed, whether the world is new and whether the save's clock
// could be read, with references to the game's Lua state, the save and the
// mapgen's settings; the clock is written through the Module's
// checkpoint).
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/mutex.h"
#include "interface/os.h"
#include "storage/api.h"
#include "luanti/lua_util.h"
#include "luanti/mapgen_params.h"
#include <cereal/archives/portable_binary.hpp>
#include <functional>
#include <sstream>
#include <cstdlib>
extern "C" {
#include <lua.h>
}

namespace luanti {

struct GameClock
{
	lua_State *&m_lua;
	interface::Mutex &m_lua_mutex;
	storage::Store *&m_store;
	MapgenParams &m_mapgen;
	// A value written to the save, now or with the next checkpoint (the
	// Module's)
	std::function<void(const ss_ &, const ss_ &)> store_set;

	GameClock(lua_State *&lua, interface::Mutex &lua_mutex,
			storage::Store *&store, MapgenParams &mapgen,
			std::function<void(const ss_ &, const ss_ &)> store_set):
		m_lua(lua), m_lua_mutex(lua_mutex), m_store(store), m_mapgen(mapgen),
		store_set(store_set)
	{}

	// The clock, in the save's object store beside the map: a world put down
	// at dusk is picked up at dusk. Luanti keeps the same three numbers in
	// its env_meta.txt.
	// Written with every checkpoint ([SAVE_CHECKPOINT]), as Luanti writes
	// its own with the map.
	// A newer Buildat's clock is kept rather than written over
	// ([COMPAT_BREAK_07] 8h)
	bool m_clock_unreadable = false;
	// The world's seed, which a mapgen is a function of. Luanti keeps it in
	// map_meta.txt and makes one up when a world is created; here it is in
	// the save beside the clock, and the importer takes the imported world's
	// if it has one. What reads it is core.get_mapgen_setting("seed") and
	// the block seed every on_generated is given.
	int64_t m_seed = 0;
	// Whether this save is one nobody has opened before; see load_seed()
	bool m_world_is_new = false;

	void load_seed()
	{
		ss_ data;
		if(m_store && m_store->get("seed", data) && !data.empty()){
			// Unsigned, because Luanti's is: a world's seed is a u64 there
			// and half of them do not fit in the signed one this keeps. The
			// bits are what a mapgen is a function of, so they are what is
			// kept.
			m_seed = (int64_t)strtoull(data.c_str(), nullptr, 10);
		} else {
			// The first thing a world is asked for is its seed, so a save
			// with none is a save nobody has played yet. What that decides
			// is what mapgen it gets; see MapgenParams::mapgen_name().
			m_world_is_new = true;
			// Luanti's own fixed_map_seed, which is what makes one world the
			// same world twice: a benchmark that generates terrain has to
			// generate the same terrain, and a bug report about a place has
			// to be able to name it. Read the way Luanti reads it -- only
			// when a world is being made, never over one that has a seed.
			const ss_ fixed = m_mapgen.setting_string("fixed_map_seed");
			if(!fixed.empty()){
				m_seed = (int64_t)strtoull(fixed.c_str(), nullptr, 10);
				log_i(MODULE, "The world's seed is fixed_map_seed, %s",
						cs(itos(m_seed)));
			} else {
				// Somewhere nobody has been before: the clock is what there
				// is to be random with here, and a world is seeded once
				m_seed = (int64_t)interface::os::time_us();
				m_seed ^= (int64_t)(size_t)this;
			}
			if(m_store)
				m_store->set("seed", itos(m_seed));
		}
		set_global_string(m_lua, "__luanti_world_seed", itos(m_seed));
		log_v(MODULE, "The world's seed is %s", cs(itos(m_seed)));
	}

	// A scripted run cannot wait for morning, and two pictures taken at
	// different hours are not comparable -- which is what the reference
	// comparison in doc/plan/luanti_module_plan.md is. Spelled the way
	// extensions/luanti_client spells them, because it is the other half of
	// that comparison: BUILDAT_LUANTI_FORCE_TIME is a Luanti time of day
	// (0..24000, so 9000 is mid-morning) and BUILDAT_LUANTI_FORCE_DAY is
	// noon without having to remember 12000.
	//
	// The clock stops as well as moves: a screenshot taken a minute into a
	// run should be the same picture as one taken at the start, and
	// time_speed is Luanti's own way of saying so.
	void force_clock()
	{
		const char *t = getenv("BUILDAT_LUANTI_FORCE_TIME");
		const char *d = getenv("BUILDAT_LUANTI_FORCE_DAY");
		double tod = -1.0;
		if(t != nullptr && t[0] != '\0')
			tod = atof(t) / 24000.0;
		else if(d != nullptr && d[0] != '\0')
			tod = 0.5;
		if(tod < 0.0)
			return;
		char buf[200];
		snprintf(buf, sizeof buf,
				"core.set_timeofday(%f) "
				"core.settings:set('time_speed', '0') "
				"core.__send_time()", tod);
		run_chunk_string(m_lua, m_lua_mutex, buf, "force_clock");
		log_i(MODULE, "The clock is pinned at %.0f of Luanti's 24000 and "
				"does not run", tod * 24000.0);
	}

	void load_clock()
	{
		if(!m_store)
			return;
		ss_ data;
		if(!m_store->get("clock", data))
			return;
		double time_of_day = 0.5, game_time = 0.0;
		int32_t day_count = 0;
		{
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			// A newer one is kept as it is, not reset to noon
			if(version != 1){
				log_e(MODULE, "The save's clock is version %i and this build "
						"reads 1; it is not written over", (int)version);
				m_clock_unreadable = true;
				return;
			}
			ar(time_of_day, game_time, day_count);
		}
		lua_State *L = m_lua;
		interface::MutexScope ms(m_lua_mutex);
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__set_clock");
		lua_pushnumber(L, time_of_day);
		lua_pushnumber(L, game_time);
		lua_pushnumber(L, day_count);
		if(lua_pcall(L, 3, 0, 0) != 0)
			log_w(MODULE, "__set_clock(): %s", lua_tostring(L, -1));
		lua_settop(L, base);
		log_v(MODULE, "Clock read from the save: day %i, time %.4f, "
				"%.0f seconds played", (int)day_count, time_of_day, game_time);
	}

	void save_clock()
	{
		if(!m_store || !m_lua || m_clock_unreadable)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__get_clock");
		if(lua_pcall(L, 0, 3, 0) != 0){
			log_w(MODULE, "__get_clock(): %s", lua_tostring(L, -1));
			lua_settop(L, base);
			return;
		}
		double time_of_day = lua_tonumber(L, -3);
		double game_time = lua_tonumber(L, -2);
		int32_t day_count = (int32_t)lua_tonumber(L, -1);
		lua_settop(L, base);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)1, time_of_day, game_time, day_count);
		}
		store_set("clock", os.str());
		log_v(MODULE, "Clock written to the save: day %i, time %.4f, "
				"%.0f seconds played", (int)day_count, time_of_day, game_time);
	}
};

}
// vim: set noet ts=4 sw=4:
