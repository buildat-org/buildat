// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// A Luanti game's own Lua -- its builtin layer and a game's mods -- running
// inside buildat_server. Luanti's network protocol is nowhere in this; the
// game logic is Luanti's and everything around it is buildat's. See
// doc/luanti_module.txt and doc/plan/luanti_module_plan.md.
//
// This file is deliberately thin. Lua 5.1 comes with io and os, so reading
// files, splitting paths and running chunks all happen in Lua; the only
// things C++ has that Lua does not are a directory listing, the log and the
// clock. The arrangement -- what a mod is, what order mods load in, what the
// core table holds -- is in lua/ beside this file, where it can be read.
#include "luanti/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "luanti_mapgen/api.h"
#include "storage/api.h"
#include "main_context/api.h"
#include "client_file/api.h"
#include "network/api.h"
#include "accounts/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/voxel.h"
#include "interface/mutex.h"
#include "interface/sha1.h"
#include "interface/sha256.h"
#include "interface/compress.h"
#include "interface/noise.h"
#include "luanti/mapblock.h"
#include "luanti/shapes.h"
#include "luanti/node_registry.h"
#include "luanti/media.h"
#include "luanti/session.h"
#include <sqlite3.h>
#include <fstream>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <unordered_map>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
#include "interface/polyvox_cereal.h"
extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>
}
// LuaJIT's bit library, which Luanti's mods use as if it were part of the
// language. Luanti loads this same file -- Mike Pall's Lua BitOp -- when it
// is not running on LuaJIT, and the Lua here is Urho3D's 5.1, so it always
// does. A module is one translation unit, so the implementation comes in
// with the header.
#include "vendor/bitop/bit.h"
#include "vendor/bitop/bit.cpp"
// Luanti's core.encode_png() is a real function of its API and devtest checks
// what comes out of it, so it is written rather than stubbed. Urho3D ships
// stb_image_write but does not export it, so it is compiled in here; it is
// one header and the only C++ in this file that is not glue.
#include <Scene.h>
#include <Node.h>
#include <StaticModel.h>
#include <Model.h>
#include <Material.h>
#include <ResourceCache.h>
#include <Image.h>
#include <MemoryBuffer.h>
#include <Context.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <STB/stb_image_write.h>
#define MODULE "luanti"
// The Module's parts ([LUANTI_MODULAR]), after MODULE, which they log as
#include "luanti/lua_util.h"
#include "luanti/mapgen_params.h"
#include "luanti/registry.h"
#include "luanti/import.h"
#include "luanti/clock.h"
#include "luanti/node_meta.h"
#include "luanti/map_access.h"
#include "luanti/world.h"
#include "luanti/game_media.h"
#include "luanti/players.h"
#include "luanti/lua_lib.h"

using interface::Event;
namespace pv = PolyVox;
namespace magic = Urho3D;
using namespace luanti_shapes;
using namespace luanti_registry;

namespace luanti {


using main_context::SceneReference;

struct Module: public interface::Module, public luanti::Interface,
		public luanti_session::Game
{
	interface::Server *m_server;
	lua_State *m_lua = nullptr;
	// Two of this module's handlers can be inside Lua at once: a queued
	// core:tick runs on the module's own thread while core:shutdown is
	// emitted synchronously from another, and the server does not serialise
	// the two. One lua_State under two threads is a crash, and a step that
	// does real work -- the ABM sweep -- is long enough to hit it every
	// time. Everything that enters Lua takes this first.
	//
	// simplified: the engine is what should serialise a module's handlers,
	// and then this would be unnecessary. It is one mutex here against a
	// change to how every module is called; see ModuleThread::handle_event
	// in src/server/state.cpp, which takes no lock where emit_event_sync
	// takes the container's.
	interface::Mutex m_lua_mutex;
	// What the server is doing while a game loads; see set_progress_handler()
	std::function<void(const ss_ &)> m_progress;
	// Seconds until the startup tables are served as files a second time;
	// see the tick
	float m_startup_files_wait = 5.0f;
	bool m_game_running = false;
	// What load_lua() was handed before run_game(), in the order it came
	sv_<std::pair<ss_, ss_>> m_pending_lua;

	// The map. One voxelworld instance, in a scene of this module's own: the
	// module is what knows the Luanti world's shape, its node ids and its
	// light, so it is what owns them. The launcher is told about the scene by
	// luanti:game_loaded.
	SceneReference m_scene = nullptr;
	// The save the world is. Opened by whoever called run_game(), and theirs
	// to close; the store is this module's own namespace in it, holding what
	// is not the map -- the clock so far.
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	// The world's bounds in sections. A section is voxelworld's load and
	// unload unit and sixty-four voxels a side; Luanti's map limit is 31000
	// voxels in every direction, which is this many of them. Nothing outside
	// is ever loaded and the sky is above the top of it -- what is loaded is
	// what the load points below keep, which is far less.
	static const int32_t MAP_LIMIT_SECTIONS = 484;
	pv::Region m_section_region{
			pv::Vector3DInt32(-MAP_LIMIT_SECTIONS, -MAP_LIMIT_SECTIONS,
					-MAP_LIMIT_SECTIONS),
			pv::Vector3DInt32(MAP_LIMIT_SECTIONS, MAP_LIMIT_SECTIONS,
					MAP_LIMIT_SECTIONS)};
	pv::Vector3DInt16 m_section_size{0, 0, 0};
	// [LUANTI_MODULAR] players.h's
	Players m_players{m_lua, m_lua_mutex, m_store, m_section_size,
			[this](const ss_ &key, const ss_ &value){ store_set(key, value); }};
	// [LUANTI_MODULAR] map_access.h's
	MapAccess m_map{m_server, m_scene};
	void set_region_map(RegionMap *map)
	{
		m_map.m_region_map = map;
	}
	// [LUANTI_MODULAR] game_media.h's, and registry.h's with its maps
	Media m_media{m_server, m_lua, m_lua_mutex, m_paths, m_mapgen};
	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		m_media.on_files_transmitted(event);
	}
	void on_get_texmods(const network::Packet &packet)
	{
		m_media.on_get_texmods(packet);
	}
	Registry m_registry{m_server, m_lua, m_lua_mutex, m_media.m_served_media,
			m_media.m_texmods, [this](const sv_<ss_> &names){
				m_media.serve_node_textures(names);
			}};

	// How often the clients are told what time it is
	static constexpr float TIME_INTERVAL_S = 5.0f;
	float m_time_accum = 0.0f;
	float m_step_accum = 0.0f;
	// The longest step a game is told about. Luanti's own dedicated server
	// caps its dtime the same way: time nobody can make up is time to let
	// go of, and a mod that is handed ten seconds at once does something
	// silly with them.
	static constexpr float MAX_STEP_S = 0.5f;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		// The generator is luanti_mapgen's code and worldgen's to run.
		// Taken out while luanti_mapgen is still loaded -- it unloads
		// after this, and worldgen after both -- and set_generator()
		// waits for a generate() in progress to return.
		if(m_scene){
			worldgen::access(m_server, [&](worldgen::Interface *iw){
				worldgen::Instance *instance = iw->get_instance(m_scene);
				if(instance)
					instance->set_generator(nullptr);
			});
		}
		lua_prof_report();
		if(m_lua)
			lua_close(m_lua);
	}

	// The Lua the two Luanti clients share, from the extension's res,
	// served under the module's own client namespace so a game's client
	// half runs it by name ([VIEW_BOB]: camera_motion.lua; [EXT_SETTINGS]:
	// key_editor.lua; [EXT_HUD_PARITY]: minimap.lua; [EXT_HOTBAR]:
	// hotbar.lua; [LUANTI_SHARED]: texmod.lua, formspec.lua). At start rather
	// than with a game's media: a menu-only connection (the settings
	// screen, [MENU_CONTEXT]) runs no game and draws the key editor.
	void serve_shared_lua()
	{
		const ss_ shared = m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res";
		for(const char *name : {"camera_motion.lua", "key_editor.lua",
				"minimap.lua", "hotbar.lua", "texmod.lua",
				"formspec.lua", "formspec_ui.lua", "hud.lua", "hud_draw.lua",
				"sounds.lua", "particles.lua", "form_session.lua",
				"item_shape.lua", "sky_model.lua", "touch.lua", "skybox.lua",
				"chat_line.lua"}){
			const ss_ path = shared+"/"+name;
			if(interface::fs::path_exists(path)){
				client_file::access(m_server, [&](client_file::Interface *i){
					i->add_file_path(ss_("luanti/")+name, path);
				});
			} else
				log_w(MODULE, "shared client Lua not found: %s", cs(path));
		}
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:module_unloaded"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		// [USER_DIR_COPY] An operator's save_now: what shutdown saves
		m_server->sub_event(this, Event::t("core:save"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("worldgen:section_generated"));
		m_server->sub_event(this, Event::t("voxelworld:section_loaded"));
		m_server->sub_event(this, Event::t("voxelworld:section_unloaded"));
		m_server->sub_event(this, Event::t("voxelworld:sections_forgotten"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_texmods"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_item_images"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_item_palettes"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_wield_meshes"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_object_props"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_dig_props"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_world_info"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:refshot_shot"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_translations"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_model"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:fields"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:inv_action"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		for(const char *n : luanti_session::PACKETS)
			m_server->sub_event(this, Event::t(
					ss_("network:packet_received/luanti:")+n));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("core:module_unloaded", on_module_unloaded,
				interface::ModuleUnloadedEvent)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:shutdown", on_shutdown)
		EVENT_VOIDN("core:save", on_shutdown)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("worldgen:section_generated", on_section_generated,
				worldgen::SectionGenerated)
		EVENT_TYPEN("voxelworld:section_loaded", on_section_loaded,
				voxelworld::SectionLoaded)
		EVENT_TYPEN("voxelworld:section_unloaded", on_section_unloaded,
				voxelworld::SectionUnloaded)
		EVENT_TYPEN("voxelworld:sections_forgotten", on_sections_forgotten,
				voxelworld::SectionsForgotten)
		EVENT_TYPEN("network:packet_received/luanti:get_texmods",
				on_get_texmods, network::Packet)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/luanti:get_item_images",
				on_get_item_images, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_item_palettes",
				on_get_item_palettes, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_wield_meshes",
				on_get_wield_meshes, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_object_props",
				on_get_object_props, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_dig_props",
				on_get_dig_props, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_world_info",
				on_get_world_info, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_translations",
				on_get_translations, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_model",
				on_get_model, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:refshot_shot",
				on_refshot_shot, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:fields",
				on_fields, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:inv_action",
				on_inv_action, network::Packet)
		// [LUANTI_APP_GLUE] The player session's (session.h)
		for(const char *n : luanti_session::PACKETS){
			if(type == Event::t(ss_("network:packet_received/luanti:")+n)){
				m_session.packet(*dynamic_cast<const network::Packet*>(p));
				return;
			}
		}
	}

	void on_start()
	{
		serve_shared_lua();
		// What may go ahead of the queue and replace its own stale copy
		// ([NET_CHANNELS]): the player's own position, the clock, and the
		// objects -- whose packet is the whole list every time (the
		// client removes what is not in it), so the newest replaces an
		// older one whole and no key by id is needed.
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->declare("luanti:player_pos",
					network::Interface::Channel::LatestOnly);
			inetwork->declare("luanti:time",
					network::Interface::Channel::LatestOnly);
			inetwork->declare("luanti:objects",
					network::Interface::Channel::LatestOnly);
		});
	}
	void on_unload(){}
	void on_continue(){}

	// The last node writes and the clock. voxelworld has a core:shutdown
	// handler of its own and may have run it already -- subscribers are
	// called in the order the modules were loaded -- so this asks the world
	// to save rather than trusting that it has not saved yet. Asking twice
	// costs nothing: a section that has not changed is not written.
	void on_shutdown()
	{
		checkpoint();
	}

	// [SAVE_CHECKPOINT] Every save_interval_s and at shutdown: the node
	// writes, the clock, the players and the loaded sections' metadata,
	// and the world's changed sections, as one transaction -- so a copy of
	// the save taken at any moment has a chest's items in the chest or in
	// the inventory, never both or neither. The writes here are collected
	// on this thread and made by voxelworld inside its save, on its thread:
	// a batch() held here around world->save() would hold the save's lock
	// while voxelworld's thread waits for it.
	sv_<std::pair<ss_, ss_>> *m_save_sink = nullptr;
	float m_checkpoint_accum = 0.0f;

	void store_set(const ss_ &key, const ss_ &value)
	{
		if(m_save_sink)
			m_save_sink->push_back(std::make_pair(key, value));
		else
			m_store->set(key, value);
	}

	void checkpoint()
	{
		if(!m_game_running || !m_store)
			return;
		const int64_t t0 = interface::os::time_us();
		m_map.flush_node_writes();
		sv_<std::pair<ss_, ss_>> writes;
		m_save_sink = &writes;
		m_clock.save_clock();
		m_players.save_players();
		m_meta.copy_loaded_meta();
		m_save_sink = nullptr;
		const int64_t t1 = interface::os::time_us();
		storage::Store *store = m_store;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->save([&](){
				for(const auto &w : writes)
					store->set(w.first, w.second);
			});
		});
		const int64_t t2 = interface::os::time_us();
		if(t2 - t0 > 100000)
			log_w(MODULE, "checkpoint: %i ms (%i ms ours, %zu writes)",
					(int)((t2 - t0) / 1000), (int)((t1 - t0) / 1000),
					writes.size());
		else
			log_v(MODULE, "checkpoint: %i ms (%i ms ours, %zu writes)",
					(int)((t2 - t0) / 1000), (int)((t1 - t0) / 1000),
					writes.size());
	}

	// [LUANTI_MODULAR] node_meta.h's
	NodeMeta m_meta{m_server, m_scene, m_lua, m_lua_mutex, m_store,
			m_section_size,
			[this](const ss_ &key, const ss_ &value){ store_set(key, value); }};
	// [LUANTI_MODULAR] clock.h's and mapgen_params.h's, each with the
	// other's
	GameClock m_clock{m_lua, m_lua_mutex, m_store, m_mapgen,
			[this](const ss_ &key, const ss_ &value){ store_set(key, value); }};
	MapgenParams m_mapgen{m_lua, m_lua_mutex, m_store, m_clock.m_world_is_new};

	void on_section_loaded(const voxelworld::SectionLoaded &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		m_meta.load_section_meta(event.section_p);
	}

	void on_section_unloaded(const voxelworld::SectionUnloaded &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		m_meta.save_section_meta(event.section_p);
	}

	// [SAVE_LIMIT] A trimmed section's metadata goes with it
	void on_sections_forgotten(const voxelworld::SectionsForgotten &event)
	{
		if(!m_store || event.scene != m_scene)
			return;
		m_meta.forget(event.sections);
		// Made again, they are new terrain: a mod's on_generated runs over
		// their mapchunks again as it did the first time
		using luanti_mapgen::chunk_index;
		const int sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		for(const pv::Vector3DInt16 &p : event.sections){
			const int x0 = p.getX() * sx, y0 = p.getY() * sy,
					z0 = p.getZ() * sz;
			for(int cz = chunk_index(z0); cz <= chunk_index(z0 + sz - 1); cz++)
			for(int cy = chunk_index(y0); cy <= chunk_index(y0 + sy - 1); cy++)
			for(int cx = chunk_index(x0); cx <= chunk_index(x0 + sx - 1); cx++)
				m_world.m_chunks_run.erase(World::chunk_key(cx, cy, cz));
		}
	}

	// The server ticks at 30 Hz and Luanti steps at 0.09 s, so a tick's
	// dtime is accumulated into a step. A tick the server could not deliver
	// on time arrives with the time it was late by added to it -- see
	// push_event() in src/server/state.cpp -- so a game whose step costs
	// more than a tick interval, which VoxeLibre's 220 mods do, runs slow
	// rather than falling further behind on every tick.
	void on_tick(const interface::TickEvent &event)
	{
		if(!m_game_running)
			return;
		m_session.tick(event.dtime);
		m_step_accum += event.dtime;
		if(m_step_accum < STEP_S)
			return;
		float dtime = m_step_accum;
		if(dtime > MAX_STEP_S)
			dtime = MAX_STEP_S;
		m_step_accum = 0.0f;
		// The startup tables once more, a few seconds in: a game's entity
		// looks are not all registered when the voxel registry is built
		// (VoxeLibre had ten of them after and none at it), and a file
		// that is there before the next client connects is the point
		// ([BLOCKED_MODULE])
		if(m_startup_files_wait > 0.0f){
			m_startup_files_wait -= dtime;
			if(m_startup_files_wait <= 0.0f)
				m_media.serve_startup_tables();
		}
		// Other players' digs and the loader's unloads land between steps
		m_map.drop_read_cache();
		// The relights the mapgen mods' writes asked for, one or two a tick
		// rather than in the step that wrote them ([STEP_SLICE])
		if(m_scene){
			const int64_t t0 = interface::os::time_us();
			size_t left = 0;
			int64_t t_in = 0;
			voxelworld::access(m_server, m_scene,
					[&](voxelworld::Instance *world){
				t_in = interface::os::time_us();
				left = world->relight_stale(RELIGHT_BUDGET_US,
						RELIGHT_NEAR_BUDGET_US);
			});
			const int64_t took = interface::os::time_us() - t0;
			// What of it was waiting for voxelworld rather than lighting:
			// the relight's own budget is 20 ms (100 near) and a step of a
			// second in "relight" is another module holding the world --
			// the physics variant's does. A phase of its own says so
			// rather than reading as this one's cost ([MAPGEN_STEP]).
			const int64_t waited = t_in > t0 ? t_in - t0 : 0;
			if(took > 1000){
				m_map.drop_read_cache();
				char buf[96];
				snprintf(buf, sizeof buf,
						"core.__note_phase(\"%s\", %f)",
						waited * 2 > took ? "relight_wait" : "relight",
						(double)took / 1000000.0);
				run_chunk_string(buf, "relight");
				if(left > 0 || waited > 100000)
					log_v(MODULE, "relight: %i ms (%i waiting for "
							"voxelworld), %zu sections still stale",
							(int)(took / 1000), (int)(waited / 1000), left);
			}
		}
		m_world.update_load_points();
		if(m_game_running)
			m_world.run_completed_chunks();
		m_world.check_map_when_ready(dtime);
		step_environment(dtime);
		m_map.flush_node_writes();
		// The clock, now and then: a client carries it on by itself between
		// these, so this is a correction rather than a tick
		m_time_accum += dtime;
		if(m_time_accum >= TIME_INTERVAL_S){
			m_time_accum = 0.0f;
			run_chunk_string("core.__send_time()", "send_time");
		}
		const double interval = atof(m_server->get_config().get<ss_>(
				"save_interval_s").c_str());
		m_checkpoint_accum += dtime;
		if(interval > 0 && m_checkpoint_accum >= interval){
			m_checkpoint_accum = 0.0f;
			checkpoint();
		}
	}

	// One Luanti step: the clock now, the globalsteps and core.after later
	// How long a step may run before the watchdog says where it is. Long
	// enough that a world generating around a player -- which is seconds of
	// honest work -- says nothing, and short enough that a step that will
	// never come back is caught while somebody is still watching.
	static const int64_t STEP_WATCHDOG_US = 30000000;
	// How much of a tick the deferred relights may take; a section is
	// about 160 ms on VoxeLibre, so this is one a tick
	static const int64_t RELIGHT_BUDGET_US = 20000;
	// And while a stale section is within two of a player: the player's
	// own canopy black for twenty seconds was the small budget on
	// 250k-blocker sections ([SEED5_SETTLE])
	static const int64_t RELIGHT_NEAR_BUDGET_US = 100000;

	void step_environment(float dtime)
	{
		char buf[64];
		snprintf(buf, sizeof buf, "core.__step(%f)", (double)dtime);
		g_step_watch.started_us = interface::os::time_us();
		g_step_watch.deadline_us =
				g_step_watch.started_us + STEP_WATCHDOG_US;
		g_step_watch.warned = false;
		try {
			run_chunk_string(buf, "step");
		} catch(Exception &e){
			log_w(MODULE, "step: %s", e.what());
		}
		g_step_watch.deadline_us = 0;
	}

	// The map

	pv::Vector3DInt16 section_of(const pv::Vector3DInt32 &p)
	{
		return luanti::section_of(p, m_section_size);
	}

	ss_ module_path()
	{
		return m_server->get_module_path(MODULE);
	}

	// core.get_cache_path(): buildat's own cache, never the user's Luanti
	// install. The games and worlds themselves are under the user path; see
	// apps/vanilla.
	ss_ luanti_cache_path()
	{
		return m_server->get_config().get<ss_>("cache_path")+"/luanti";
	}

	void run_chunk_file(const ss_ &path)
	{
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		if(luaL_loadfile(L, path.c_str()) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: cannot load "+path+": "+err);
		}
		if(lua_pcall(L, 0, 0, base + 1) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: error in "+path+":\n"+err);
		}
		lua_settop(L, base);
	}

	void run_chunk_string(const ss_ &chunk, const ss_ &chunkname)
	{
		luanti::run_chunk_string(m_lua, m_lua_mutex, chunk, chunkname);
	}

	void set_global_string(const char *name, const ss_ &value)
	{
		lua_pushstring(m_lua, value.c_str());
		lua_setglobal(m_lua, name);
	}

	void set_global_cfunction(const char *name, lua_CFunction f)
	{
		lua_pushcfunction(m_lua, f);
		lua_setglobal(m_lua, name);
	}

	#include "game_run.h"

	// core.__voxel_defs() -> add_voxel(), in id order, with a solid colour
	// each until M3 brings the real tiles

	#include "lua_bindings.h"

	#include "requests.h"
	// [LUANTI_APP_GLUE] The player session (session.h), this the Game
	luanti_session::Session m_session{*this};
	void join_player(const ss_ &name, size_t peer, bool admin)
	{
		m_session.join(name, peer, admin);
	}
	bool player_in_world(size_t peer)
	{
		return m_session.in_world(peer);
	}
	void set_chat_limit(double burst)
	{
		m_session.set_chat_limit(burst);
	}
	void set_chat_gate(std::function<ss_(size_t peer, const ss_ &name)> gate)
	{
		m_session.set_chat_gate(gate);
	}

	// Interface

	// [LUANTI_MODULAR] import.h's
	Importer m_importer{m_server, m_scene, m_lua, m_lua_mutex, m_store,
			m_section_size, m_section_region, m_game_running, m_mapgen,
			[this](){ m_meta.write_all_node_meta(); }};
	// [LUANTI_MODULAR] world.h's
	World m_world{m_server, m_scene, m_lua, m_lua_mutex, m_section_size,
			m_players.m_player_pos, m_players.m_player_peers, m_game_running, m_map, m_clock,
			m_mapgen, m_importer,
			[this](const ss_ &chunk){ return node_action(chunk); }};
	void on_section_generated(const worldgen::SectionGenerated &event)
	{
		m_world.on_section_generated(event);
	}
	void import_world(const ss_ &luanti_world_path)
	{
		m_importer.import_world(luanti_world_path);
	}
	void import_world_settings(const ss_ &luanti_world_path,
			storage::Save *save)
	{
		m_importer.import_world_settings(luanti_world_path, save);
	}

	// A string that is going into a chunk of Lua as a quoted one. What the
	// caller hands over is a name from the network, and a chunk is code.
	static ss_ lua_quoted(const ss_ &s)
	{
		ss_ out;
		for(char c : s){
			if(c == '"' || c == '\\')
				out += '\\';
			if(c == '\n' || c == '\r')
				continue;
			out += c;
		}
		return out;
	}

	// A chunk of Lua run for its answer, which is how core.dig_node()
	// reaches a game's own click handler from outside Lua
	bool node_action(const ss_ &chunk)
	{
		if(!m_game_running)
			return false;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		if(luaL_loadbuffer(L, chunk.c_str(), chunk.size(), "node_action") != 0){
			log_w(MODULE, "node_action(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return false;
		}
		if(lua_pcall(L, 0, 1, base + 1) != 0){
			log_w(MODULE, "node_action(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return false;
		}
		bool ok = lua_toboolean(L, -1) != 0;
		lua_settop(L, base);
		return ok;
	}

	// A client arrives and leaves, and says where it is. A player is what
	// Luanti calls whoever is on the other end of one: the name is the
	// caller's to choose and is what everything about the player is keyed
	// by. The callbacks a mod registers for a join and a leave run here.
	void add_player(const ss_ &name, size_t peer)
	{
		m_players.place_peer(name, peer);
		node_action("core.__add_player(\""+lua_quoted(name)+"\") return true");
	}

	void place_player(const ss_ &name, size_t peer)
	{
		m_players.place_peer(name, peer);
		node_action("core.__place_player(\""+lua_quoted(name)+"\") return true");
	}

	void set_admin(const ss_ &name, bool admin)
	{
		node_action("core.__set_admin(\""+lua_quoted(name)+"\", "+
				(admin ? "true" : "false")+") return true");
	}

	void chat_send(const ss_ &to, const ss_ &text)
	{
		if(to.empty())
			node_action("core.chat_send_all(\""+lua_quoted(text)+
					"\") return true");
		else
			node_action("core.chat_send_player(\""+lua_quoted(to)+"\", \""+
					lua_quoted(text)+"\") return true");
	}

	void remove_player(const ss_ &name)
	{
		node_action("core.__remove_player(\""+lua_quoted(name)+
				"\") return true");
		auto it = m_players.m_player_peers.find(name);
		if(it != m_players.m_player_peers.end()){
			m_players.m_peer_players.erase(it->second);
			m_peer_mode.erase(it->second);
			m_players.m_player_peers.erase(it);
		}
		// The world stops being kept loaded around where they were
		m_players.m_player_pos.erase(name);
	}

	void set_player_pos(const ss_ &name, float x, float y, float z,
			float look_h, float look_v, int32_t controls)
	{
		// Off the network: a NaN or a 1e30 was undefined in the cast below
		// and "nan" or a cut-off chunk in the Lua one ([SECURITY_RUN_1]).
		// Luanti's world ends at 31007; past 32000 is no position.
		for(float v : {x, y, z, look_h, look_v}){
			if(!std::isfinite(v))
				return;
		}
		if(std::fabs(x) > 32000 || std::fabs(y) > 32000 ||
				std::fabs(z) > 32000 || std::fabs(look_h) > 1e6 ||
				std::fabs(look_v) > 1e6)
			return;
		// What the world streams around and what is active near; the step
		// reads it, so this only writes it down
		m_players.m_player_pos[name] = pv::Vector3DInt32(
				(int32_t)std::floor(x), (int32_t)std::floor(y),
				(int32_t)std::floor(z));
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__set_player_pos(\"%s\", %f, %f, %f, %f, %f, %d) "
				"return true",
				lua_quoted(name).c_str(), (double)x, (double)y, (double)z,
				(double)look_h, (double)look_v, (int)controls);
		node_action(buf);
	}

	void player_fell(const ss_ &name, float speed)
	{
		if(!std::isfinite(speed) || std::fabs(speed) > 1e6)
			return;
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__player_fell(\"%s\", %f) return true",
				lua_quoted(name).c_str(), (double)speed);
		node_action(buf);
	}

	bool use_wielded(const ss_ &player_name)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_map.m_by_player);
		return node_action("return core.__use_wielded(\""+
				lua_quoted(player_name)+"\")");
	}

	bool drop_wielded(const ss_ &player_name, int count)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_map.m_by_player);
		return node_action("return core.__drop_wielded(\""+
				lua_quoted(player_name)+"\", "+itos(count)+")");
	}

	bool punch_object(int32_t id, const ss_ &player_name)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_map.m_by_player);
		return node_action("return core.__punch_object(\""+
				lua_quoted(player_name)+"\", "+itos(id)+")");
	}

	void set_wield_index(const ss_ &player_name, int index)
	{
		node_action("core.__set_wield_index(\""+lua_quoted(player_name)+
				"\", "+itos(index)+") return true");
	}

	// A line a player typed, handed to the callbacks the way Luanti's own
	// server hands one over. The "/" commands are among those callbacks,
	// registered by the vendored builtin.
	void chat_message(const ss_ &player_name, const ss_ &message)
	{
		// Luanti's own limit on a chat line, and the reason for one here is
		// that this comes off the network
		static const size_t MAX_CHAT = 500;
		ss_ line = message.size() > MAX_CHAT ?
				message.substr(0, MAX_CHAT) : message;
		PlayerCause cause(m_map.m_by_player);
		node_action("core.__chat_message(\""+lua_quoted(player_name)+
				"\", \""+lua_quoted(line)+"\") return true");
	}

	bool dig_node(int32_t x, int32_t y, int32_t z, const ss_ &player_name)
	{
		// The digger is who the drops go to: core.handle_node_drops() puts
		// them in a player's inventory and on the ground for anyone else.
		// An empty name is nobody, which is what it was before there were
		// players.
		ss_ digger = player_name.empty() ? ss_("nil") :
				"core.get_player_by_name(\""+lua_quoted(player_name)+"\")";
		PlayerCause cause(m_map.m_by_player, !player_name.empty());
		return node_action("return core.__dig_node({x = "+itos(x)+
				", y = "+itos(y)+", z = "+itos(z)+"}, "+digger+")");
	}

	bool punch_node(int32_t x, int32_t y, int32_t z, const ss_ &player_name)
	{
		ss_ puncher = player_name.empty() ? ss_("nil") :
				"core.get_player_by_name(\""+lua_quoted(player_name)+"\")";
		PlayerCause cause(m_map.m_by_player, !player_name.empty());
		return node_action("return core.__punch_node({x = "+itos(x)+
				", y = "+itos(y)+", z = "+itos(z)+"}, "+puncher+")");
	}

	bool place_node(int32_t ux, int32_t uy, int32_t uz,
			int32_t ax, int32_t ay, int32_t az, const ss_ &player_name,
			bool sneak)
	{
		if(player_name.empty())
			return false;
		PlayerCause cause(m_map.m_by_player);
		return node_action("return core.__use_node(\""+
				lua_quoted(player_name)+"\", "
				"{x = "+itos(ux)+", y = "+itos(uy)+", z = "+itos(uz)+"}, "
				"{x = "+itos(ax)+", y = "+itos(ay)+", z = "+itos(az)+"}, "+
				(sneak ? "true" : "false")+")");
	}

	sv_<ss_> call_string_list(const ss_ &name)
	{
		return string_list_from_lua(name.c_str());
	}

	ss_ call_json(const ss_ &name, const ss_ &json)
	{
		interface::MutexScope ms(m_lua_mutex);
		if(!m_lua)
			return "";
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__call_json");
		lua_remove(L, -2);
		lua_pushlstring(L, name.c_str(), name.size());
		lua_pushlstring(L, json.c_str(), json.size());
		if(lua_pcall(L, 2, 1, base + 1) != 0){
			log_w(MODULE, "call_json(%s): %s", cs(name),
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return "";
		}
		size_t len = 0;
		const char *p = lua_tolstring(L, -1, &len);
		const ss_ r = p ? ss_(p, len) : "";
		lua_settop(L, base);
		return r;
	}

	Paths m_paths;
	void set_paths(const Paths &paths)
	{
		m_paths = paths;
	}

	void set_generated_sounds(const ss_ &prefix, int count)
	{
		m_media.set_generated_sounds(prefix, count);
	}

	bool m_server_physics = false;
	void set_server_physics(bool on)
	{
		m_server_physics = on;
	}

	SceneReference get_scene()
	{
		return m_scene;
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_luanti(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
