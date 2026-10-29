// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The players as the module keeps them ([LUANTI_MODULAR]: a part of the
// Module): which peer each is, where each is -- what the world streams
// around and what is active near -- and their rows in the save. It owns
// those, with references to the game's Lua state, the save and the
// world's sections; the save's writes go through the Module's checkpoint.
// What a player does is the Module's: the interface's calls, which run
// the game's Lua.
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/mutex.h"
#include "storage/api.h"
#include "luanti/map_access.h"
#include "luanti/world.h"
#include <functional>
#include <cassert>
extern "C" {
#include <lua.h>
}

namespace luanti {

namespace pv = PolyVox;

struct Players
{
	lua_State *&m_lua;
	interface::Mutex &m_lua_mutex;
	storage::Store *&m_store;
	const pv::Vector3DInt16 &m_section_size;
	// A value written to the save, now or with the next checkpoint (the
	// Module's)
	std::function<void(const ss_ &, const ss_ &)> store_set;

	Players(lua_State *&lua, interface::Mutex &lua_mutex,
			storage::Store *&store, const pv::Vector3DInt16 &section_size,
			std::function<void(const ss_ &, const ss_ &)> store_set):
		m_lua(lua), m_lua_mutex(lua_mutex), m_store(store),
		m_section_size(section_size), store_set(store_set)
	{}

	pv::Vector3DInt16 section_of(const pv::Vector3DInt32 &p)
	{
		return luanti::section_of(p, m_section_size);
	}

	// Whether the save has players in it; a world nobody has been in stays
	// that way
	bool m_had_players = false;
	// [COMPAT_BREAK_07] 8h: a players row this cannot read (a newer
	// Buildat's) is kept rather than written over
	bool m_players_unreadable = false;
	// Which client a player is, so that what is sent to one has somewhere to
	// go, and which player a client is, for what comes back. Whoever names a
	// player says which peer it is; see add_player().
	sm_<ss_, size_t> m_player_peers;
	sm_<size_t, ss_> m_peer_players;
	// Where each player is, in voxels. Written by set_player_pos() a few
	// times a second and read once a step; it is what the world streams
	// around, and what says which sections are active.
	sm_<ss_, pv::Vector3DInt32> m_player_pos;
	// What the last checkpoint wrote for them
	ss_ m_players_written;
	// [IMPORT_KEEPS_INVENTORIES] The row came with a save made elsewhere
	// (vanilla's import set "players_auth_foreign"): its auth entries --
	// privileges, passwords -- are not read, and the first write of the
	// row, without them, clears the mark in the same checkpoint
	bool m_auth_foreign = false;

	// The players, in the save beside the node metadata and written the same
	// way: what a player carries is item strings as well. lua/entity.lua says
	// what one row is.
	void save_players()
	{
		if(!m_store || !m_lua || m_players_unreadable)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__save_players");
		if(lua_pcall(L, 0, 2, 0) != 0){
			log_w(MODULE, "__save_players(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		size_t len = 0;
		const char *p = lua_tolstring(L, -2, &len);
		ss_ data(p ? p : "", p ? len : 0);
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		if(n == 0 && !m_had_players)
			return; // Nothing to write and nothing there to clear
		m_had_players = (n != 0);
		if(data == m_players_written)
			return; // A checkpoint with nobody moving
		m_players_written = data;
		store_set("players", data);
		if(m_auth_foreign){
			store_set("players_auth_foreign", "");
			m_auth_foreign = false;
		}
		log_v(MODULE, "Players written to the save: %i", n);
	}

	void load_players()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("players", data))
			return;
		ss_ foreign;
		m_auth_foreign = m_store->get("players_auth_foreign", foreign) &&
				foreign == "1";
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_players");
		lua_pushlstring(L, data.c_str(), data.size());
		lua_pushboolean(L, m_auth_foreign);
		// One this cannot read is kept as it is: the next checkpoint
		// would otherwise drop every player not online
		if(lua_pcall(L, 2, 1, 0) != 0 || lua_isnil(L, -1)){
			log_e(MODULE, "The save's players cannot be read (%s); they are "
					"not written over", lua_isstring(L, -1) ?
					lua_tostring(L, -1) : "a newer Buildat's, or broken");
			m_players_unreadable = true;
			lua_settop(L, base);
			return;
		}
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		m_had_players = (n != 0);
		if(m_auth_foreign)
			log_i(MODULE, "The save's players read without their privileges "
					"and passwords: it was made elsewhere");
		log_v(MODULE, "Players read from the save: %i", n);
	}

	// The active range is a section around a player and nothing where there
	// is none, which is what stops a furnace on the other side of the world
	// from firing into a section nobody has loaded
	void check_active_range()
	{
		sm_<ss_, pv::Vector3DInt32> saved;
		saved.swap(m_player_pos);
		assert(!is_section_active(pv::Vector3DInt16(0, 0, 0)));
		m_player_pos["__check"] = pv::Vector3DInt32(0, 0, 0);
		assert(is_section_active(pv::Vector3DInt16(0, 0, 0)));
		assert(is_section_active(pv::Vector3DInt16(1, 0, -1)));
		assert(!is_section_active(pv::Vector3DInt16(2, 0, 0)));
		// A player one voxel the other side of a boundary is in the section
		// that side of it, and the range goes with them
		m_player_pos["__check"] = pv::Vector3DInt32(-1, 0, 0);
		assert(is_section_active(pv::Vector3DInt16(-2, 0, 0)));
		assert(!is_section_active(pv::Vector3DInt16(1, 0, 0)));
		m_player_pos = saved;
		log_v(MODULE, "check_active_range: the range is where the players are");
	}

	// Luanti's active_block_range: what is near a player is what steps.
	// Nobody near it means nothing runs in it, which is Luanti's answer too
	// -- a world with no players in it is a world where nothing happens.
	bool is_section_active(const pv::Vector3DInt16 &section_p)
	{
		for(const auto &pair : m_player_pos){
			pv::Vector3DInt16 c = section_of(pair.second);
			if(std::abs((int32_t)section_p.getX() - c.getX()) <= World::ACTIVE_RADIUS &&
					std::abs((int32_t)section_p.getY() - c.getY()) <= World::ACTIVE_RADIUS &&
					std::abs((int32_t)section_p.getZ() - c.getZ()) <= World::ACTIVE_RADIUS)
				return true;
		}
		return false;
	}

	// Lua

	void place_peer(const ss_ &name, size_t peer)
	{
		m_player_peers[name] = peer;
		m_peer_players[peer] = name;
		// At the origin until the client says otherwise, which is where a
		// player is put anyway and what keeps the world around them loaded
		// from the moment they are one
		if(!m_player_pos.count(name))
			m_player_pos[name] = pv::Vector3DInt32(0, 0, 0);
	}
};

}
// vim: set noet ts=4 sw=4:
