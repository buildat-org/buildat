// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Node metadata in the save ([LUANTI_MODULAR]: a part of the Module, with
// references to the game's Lua state, the save and the world's sections).
// [KIT] Saved as voxelworld's voxel owners: an entry per position.
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/mutex.h"
#include "interface/server.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "main_context/api.h"
#include <functional>
#include <map>
#include <set>
extern "C" {
#include <lua.h>
}

namespace luanti {

namespace pv = PolyVox;

struct NodeMeta
{
	interface::Server *&m_server;
	main_context::SceneReference &m_scene;
	lua_State *&m_lua;
	interface::Mutex &m_lua_mutex;
	storage::Store *&m_store;
	const pv::Vector3DInt16 &m_section_size;
	// [KIT] The owner name the metadata has on voxelworld's voxel owners,
	// which is where it is saved: an entry per position, its data the
	// position's fields and inventory lists as core.serialize() writes
	// them. The Lua half holds the live objects of the sections it has
	// taken in; voxelworld has them as of the last checkpoint or unload.
	// simplified: a position is owned in voxelworld from the next
	// checkpoint on, not from the moment a mod writes to it; a routed
	// write that has to see it at once wants core.get_meta() to write
	// through.
	static constexpr const char *OWNER = "luanti";
	// The sections whose metadata the Lua half has taken in (their
	// section_loaded heard, or a position in them reached; see take_in()),
	// the only ones a checkpoint writes: one not taken in has its metadata
	// in voxelworld alone, and writing the Lua half's nothing over it
	// would lose it. Under m_lua_mutex.
	std::set<pv::Vector3DInt16> m_taken_in;

	NodeMeta(interface::Server *&server, main_context::SceneReference &scene,
			lua_State *&lua, interface::Mutex &lua_mutex,
			storage::Store *&store, const pv::Vector3DInt16 &section_size):
		m_server(server), m_scene(scene), m_lua(lua), m_lua_mutex(lua_mutex),
		m_store(store), m_section_size(section_size)
	{}

	static int32_t floor_div(int32_t a, int32_t b)
	{
		return a >= 0 ? a / b : -((-a + b - 1) / b);
	}

	pv::Vector3DInt16 section_of(const pv::Vector3DInt32 &p)
	{
		return pv::Vector3DInt16(
				floor_div(p.getX(), m_section_size.getX()),
				floor_div(p.getY(), m_section_size.getY()),
				floor_div(p.getZ(), m_section_size.getZ()));
	}

	// core.<fn>(ints..., blob) -> a flat list x, y, z, data, ... appended
	// to out; false if the call failed
	bool call_flat(const char *fn, const sv_<int32_t> &ints,
			const ss_ *blob, voxelworld::OwnedList &out)
	{
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, fn);
		for(int32_t i : ints)
			lua_pushinteger(L, i);
		if(blob)
			lua_pushlstring(L, blob->c_str(), blob->size());
		if(lua_pcall(L, (int)ints.size() + (blob ? 1 : 0), 1, 0) != 0){
			log_w(MODULE, "%s(): %s", fn,
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return false;
		}
		if(lua_istable(L, -1)){
			const size_t count = lua_objlen(L, -1);
			for(size_t i = 1; i + 3 <= count; i += 4){
				int32_t c[3];
				for(int k = 0; k < 3; k++){
					lua_rawgeti(L, -1, (int)i + k);
					c[k] = (int32_t)lua_tointeger(L, -1);
					lua_pop(L, 1);
				}
				lua_rawgeti(L, -1, (int)i + 3);
				size_t len = 0;
				const char *d = lua_tolstring(L, -1, &len);
				out.push_back(std::make_pair(
						pv::Vector3DInt32(c[0], c[1], c[2]),
						ss_(d ? d : "", d ? len : 0)));
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
		return true;
	}

	std::map<pv::Vector3DInt16, voxelworld::OwnedList> by_section(
			const voxelworld::OwnedList &all)
	{
		std::map<pv::Vector3DInt16, voxelworld::OwnedList> out;
		for(const auto &e : all)
			out[section_of(e.first)].push_back(e);
		return out;
	}

	// under: what is there already wins over these (a migration's), else
	// these replace it
	void put_all(const voxelworld::OwnedList &all, bool under = false)
	{
		auto groups = by_section(all);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(auto &g : groups){
				if(under){
					voxelworld::OwnedList have =
							world->get_section_owned(g.first, OWNER);
					std::set<pv::Vector3DInt32> taken;
					for(const auto &e : have)
						taken.insert(e.first);
					for(const auto &e : g.second)
						if(!taken.count(e.first))
							have.push_back(e);
					g.second = have;
				}
				world->set_section_owned(g.first, OWNER, g.second);
			}
		});
	}

	// The checkpoint's: the metadata of every section taken in, onto
	// voxelworld, whose save writes what changed in the same transaction.
	// What is in memory is left there (unlike save_section_meta(), which
	// is the section leaving).
	void copy_loaded_meta()
	{
		interface::MutexScope ms(m_lua_mutex);
		if(!m_lua || !m_scene || m_section_size.getX() <= 0 ||
				m_taken_in.empty())
			return;
		voxelworld::OwnedList all;
		if(!call_flat("__dump_node_meta", {}, nullptr, all))
			return;
		auto groups = by_section(all);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(const pv::Vector3DInt16 &sp : m_taken_in)
				world->set_section_owned(sp, OWNER, groups[sp]);
		});
	}

	// A section that has left: its metadata out of the Lua half and onto
	// voxelworld, which writes it into the save (the section has gone from
	// its memory by the time this hears of it). Luanti keeps a block's
	// metadata with the block the same way.
	void save_section_meta(const pv::Vector3DInt16 &section_p)
	{
		interface::MutexScope ms(m_lua_mutex);
		if(!m_lua || m_section_size.getX() <= 0)
			return;
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int32_t x0 = (int32_t)section_p.getX() * sx;
		const int32_t y0 = (int32_t)section_p.getY() * sy;
		const int32_t z0 = (int32_t)section_p.getZ() * sz;
		voxelworld::OwnedList entries;
		if(!call_flat("__take_node_meta", {x0, y0, z0, x0 + sx - 1,
				y0 + sy - 1, z0 + sz - 1}, nullptr, entries))
			return;
		// One the Lua half never took in has nothing in it: every path to
		// a position's metadata takes its section in first
		if(!m_taken_in.erase(section_p))
			return;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_section_owned(section_p, OWNER, entries);
		});
		log_v(MODULE, "%zu node metadata written with section (%i, %i, %i)",
				entries.size(), (int)section_p.getX(), (int)section_p.getY(),
				(int)section_p.getZ());
	}

	// [LUANTI_META_FAR_WRITE] A section's saved metadata into the Lua half,
	// once: on its section_loaded, or earlier when a position in it is
	// reached (core.get_meta(), set_node()'s clearing; core.__take_in_meta)
	// while it is unloaded or not heard of yet, so that what the Lua half
	// holds of a section is all of it. One taken in already is left alone:
	// what the Lua half has is newer than the save. Lua mutex, then
	// voxelworld, the order a Lua call into voxelworld has.
	void load_section_meta(const pv::Vector3DInt16 &section_p)
	{
		interface::MutexScope ms(m_lua_mutex);
		if(!m_lua || !m_scene || m_section_size.getX() <= 0 ||
				!m_taken_in.insert(section_p).second)
			return;
		voxelworld::OwnedList entries;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			entries = world->get_section_owned(section_p, OWNER);
		});
		if(entries.empty())
			return;
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_node_meta");
		lua_createtable(L, (int)entries.size() * 4, 0);
		int i = 1;
		for(const auto &e : entries){
			lua_pushinteger(L, e.first.getX());
			lua_rawseti(L, -2, i++);
			lua_pushinteger(L, e.first.getY());
			lua_rawseti(L, -2, i++);
			lua_pushinteger(L, e.first.getZ());
			lua_rawseti(L, -2, i++);
			lua_pushlstring(L, e.second.c_str(), e.second.size());
			lua_rawseti(L, -2, i++);
		}
		if(lua_pcall(L, 1, 1, 0) != 0){
			log_w(MODULE, "__load_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		}
		lua_settop(L, base);
	}

	// [SAVE_LIMIT] Trimmed sections: voxelworld's forget_sections() took
	// their metadata with their other voxel owners; one the Lua half took
	// in without it loading lets go of it too, or it would come back
	void forget(const sv_<pv::Vector3DInt16> &sections)
	{
		interface::MutexScope ms(m_lua_mutex);
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		for(const pv::Vector3DInt16 &p : sections){
			if(!m_taken_in.erase(p) || !m_lua)
				continue;
			voxelworld::OwnedList dropped;
			call_flat("__take_node_meta", {p.getX() * sx, p.getY() * sy,
					p.getZ() * sz, (p.getX() + 1) * sx - 1,
					(p.getY() + 1) * sy - 1, (p.getZ() + 1) * sz - 1},
					nullptr, dropped);
		}
	}

	// Everything the Lua half holds, grouped by the section each position
	// is in and handed to voxelworld; what is in memory is left there. What
	// wants this is the importer: a world it read metadata for is mostly
	// sections nothing has loaded.
	size_t write_all_node_meta()
	{
		if(!m_lua || !m_scene || m_section_size.getX() <= 0)
			return 0;
		voxelworld::OwnedList all;
		if(!call_flat("__dump_node_meta", {}, nullptr, all))
			return 0;
		put_all(all);
		log_v(MODULE, "%zu node metadata written", all.size());
		return all.size();
	}

	// [KIT] What older saves hold in this module's own store, moved onto
	// voxelworld's voxel owners: the one blob for the whole world
	// ("node_meta") and the blob per section after it ("node_meta/x,y,z").
	// The world is saved before the old rows go, so a crash in the middle
	// leaves them to be moved again.
	void migrate_node_meta()
	{
		if(!m_store || !m_lua || !m_scene || m_section_size.getX() <= 0)
			return;
		// The one blob first: a position in both is the newer row's
		sv_<ss_> keys;
		ss_ data;
		if(m_store->get("node_meta", data))
			keys.push_back("node_meta");
		for(const ss_ &key : m_store->list("node_meta/"))
			keys.push_back(key);
		if(keys.empty())
			return;
		voxelworld::OwnedList all;
		for(const ss_ &key : keys){
			if(!m_store->get(key, data) || data.empty())
				continue;
			if(!call_flat("__split_node_meta", {}, &data, all)){
				log_e(MODULE, "The node metadata in the save's %s did not "
						"read; it is left there", cs(key));
				return;
			}
		}
		log_i(MODULE, "Moving %zu node metadata out of %zu rows of the save "
				"onto the world's voxel owners", all.size(), keys.size());
		// Under what the owners have already: an older build's rows
		// left beside a newer one's entries are the older
		put_all(all, true);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->save();
		});
		m_store->batch([&](){
			for(const ss_ &key : keys)
				m_store->remove(key);
		});
	}
};

}
// vim: set noet ts=4 sw=4:
