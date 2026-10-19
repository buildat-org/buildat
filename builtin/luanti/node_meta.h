// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Node metadata in the save ([LUANTI_MODULAR]: a part of the Module,
// owning what the last checkpoint wrote and whether the save has any, with
// references to the game's Lua state, the save and the world's sections;
// a checkpoint's writes go through the Module's).
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
	// A value written to the save, now or with the next checkpoint (the
	// Module's)
	std::function<void(const ss_ &, const ss_ &)> store_set;
	// What the last checkpoint wrote for a loaded section's metadata, so an
	// unchanged one is not written again; a section that unloads writes its
	// own and leaves this
	std::map<ss_, ss_> m_meta_written;

	NodeMeta(interface::Server *&server, main_context::SceneReference &scene,
			lua_State *&lua, interface::Mutex &lua_mutex,
			storage::Store *&store, const pv::Vector3DInt16 &section_size,
			std::function<void(const ss_ &, const ss_ &)> store_set):
		m_server(server), m_scene(scene), m_lua(lua), m_lua_mutex(lua_mutex),
		m_store(store), m_section_size(section_size), store_set(store_set)
	{}

	// The metadata of every loaded section, left in memory (unlike
	// save_section_meta(), which is the section leaving)
	void copy_loaded_meta()
	{
		if(!m_store || !m_lua || !m_scene || m_section_size.getX() <= 0)
			return;
		sv_<pv::Vector3DInt16> sections;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			sections = world->get_loaded_sections();
		});
		std::map<ss_, ss_> now;
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__regroup_node_meta");
			lua_pushinteger(L, m_section_size.getX());
			if(lua_pcall(L, 1, 2, 0) != 0){
				log_w(MODULE, "__regroup_node_meta(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return;
			}
			if(lua_istable(L, -2)){
				const size_t count = lua_objlen(L, -2);
				for(size_t i = 1; i + 1 <= count; i += 2){
					size_t kl = 0, vl = 0;
					lua_rawgeti(L, -2, (int)i);
					const char *k = lua_tolstring(L, -1, &kl);
					lua_rawgeti(L, -3, (int)i + 1);
					const char *v = lua_tolstring(L, -1, &vl);
					now["node_meta/"+ss_(k ? k : "", kl)] = ss_(v ? v : "", vl);
					lua_pop(L, 2);
				}
			}
			lua_settop(L, base);
		}
		for(const pv::Vector3DInt16 &section_p : sections){
			const ss_ key = section_meta_key(section_p);
			auto it = now.find(key);
			const ss_ data = it == now.end() ? ss_() : it->second;
			auto was = m_meta_written.find(key);
			if(was != m_meta_written.end() && was->second == data)
				continue;
			// Not known yet and nothing here: clear only what the save has
			ss_ old;
			if(was == m_meta_written.end() && data.empty() &&
					(!m_store->get(key, old) || old.empty())){
				m_meta_written[key] = "";
				continue;
			}
			store_set(key, data);
			m_meta_written[key] = data;
		}
	}

	// What hangs off the voxels of one section, in the save under a key of
	// its own: a section that unloads takes its metadata with it and brings
	// it back when it returns, which is how Luanti keeps a block's metadata
	// with the block. See step 5c of doc/plan/world_persistence_plan.md.
	ss_ section_meta_key(const pv::Vector3DInt16 &p)
	{
		return ss_()+"node_meta/"+itos(p.getX())+","+itos(p.getY())+","+
				itos(p.getZ());
	}

	void save_section_meta(const pv::Vector3DInt16 &section_p)
	{
		if(!m_store || !m_lua || m_section_size.getX() <= 0)
			return;
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int32_t x0 = (int32_t)section_p.getX() * sx;
		const int32_t y0 = (int32_t)section_p.getY() * sy;
		const int32_t z0 = (int32_t)section_p.getZ() * sz;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__take_node_meta");
		lua_pushinteger(L, x0);
		lua_pushinteger(L, y0);
		lua_pushinteger(L, z0);
		lua_pushinteger(L, x0 + sx - 1);
		lua_pushinteger(L, y0 + sy - 1);
		lua_pushinteger(L, z0 + sz - 1);
		if(lua_pcall(L, 6, 2, 0) != 0){
			log_w(MODULE, "__take_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		size_t len = 0;
		const char *p = lua_tolstring(L, -2, &len);
		const ss_ data(p ? p : "", p ? len : 0);
		const int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		const ss_ key = section_meta_key(section_p);
		m_meta_written.erase(key);
		if(n == 0){
			// Nothing there, and what the save holds is older than that
			ss_ old;
			if(m_store->get(key, old))
				m_store->set(key, "");
			return;
		}
		m_store->set(key, data);
		log_v(MODULE, "%i node metadata written with section (%i, %i, %i)", n,
				(int)section_p.getX(), (int)section_p.getY(),
				(int)section_p.getZ());
	}

	void load_section_meta(const pv::Vector3DInt16 &section_p)
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get(section_meta_key(section_p), data) || data.empty())
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_node_meta");
		lua_pushlstring(L, data.c_str(), data.size());
		if(lua_pcall(L, 1, 1, 0) != 0){
			log_w(MODULE, "__load_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		}
		lua_settop(L, base);
	}

	// [SAVE_LIMIT] Trimmed sections' metadata goes with them
	void forget(const sv_<pv::Vector3DInt16> &sections)
	{
		m_store->batch([&](){
			for(const pv::Vector3DInt16 &p : sections){
				const ss_ key = section_meta_key(p);
				m_store->remove(key);
				m_meta_written.erase(key);
			}
		});
	}

	// Everything the Lua half holds, grouped by the section each position
	// is in and written; what is in memory is left there. What wants this
	// is the importer -- a world it read metadata for is mostly sections
	// nothing has loaded -- and the migration below.
	size_t write_all_node_meta()
	{
		if(!m_store || !m_lua || m_section_size.getX() <= 0)
			return 0;
		sv_<ss_> flat;
		int n = 0;
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__regroup_node_meta");
			lua_pushinteger(L, m_section_size.getX());
			if(lua_pcall(L, 1, 2, 0) != 0){
				log_w(MODULE, "__regroup_node_meta(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return 0;
			}
			n = (int)lua_tonumber(L, -1);
			if(lua_istable(L, -2)){
				const size_t count = lua_objlen(L, -2);
				for(size_t i = 1; i <= count; i++){
					lua_rawgeti(L, -2, (int)i);
					size_t len = 0;
					const char *p = lua_tolstring(L, -1, &len);
					flat.push_back(ss_(p ? p : "", p ? len : 0));
					lua_pop(L, 1);
				}
			}
			lua_settop(L, base);
		}
		for(size_t i = 0; i + 1 < flat.size(); i += 2)
			m_store->set("node_meta/"+flat[i], flat[i + 1]);
		log_v(MODULE, "%i node metadata over %zu sections", n,
				flat.size() / 2);
		return flat.size() / 2;
	}

	// A save written when the metadata was one blob for the whole world:
	// read it, write it out per section, and only then drop the blob, so
	// that a crash in the middle leaves the blob to be read again.
	void migrate_node_meta()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("node_meta", data) || data.empty())
			return;
		log_i(MODULE, "The save's node metadata is one blob; writing it out "
				"per section");
		load_node_meta();
		write_all_node_meta();
		m_store->set("node_meta", "");
	}

	void load_node_meta()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("node_meta", data))
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_node_meta");
		lua_pushlstring(L, data.c_str(), data.size());
		if(lua_pcall(L, 1, 1, 0) != 0){
			log_w(MODULE, "__load_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		log_v(MODULE, "Node metadata read from the save: %i positions", n);
	}
};

}
// vim: set noet ts=4 sw=4:
