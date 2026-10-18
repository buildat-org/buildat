// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Making the world and keeping it loaded ([LUANTI_MODULAR]: a part of the
// Module): where the world stays loaded and how far it is made out, a
// singlenode world's fill, a game's on_generated over each mapchunk, and
// the map's self-check. It owns the load points' radii, the forceloads,
// the chunks run and the check's state, with references to the game's Lua
// state, the world's scene and sections, the players' positions and the
// parts it asks: the map, the clock's seed, the mapgen's settings and the
// importer's ids. A mod's on_generated is run through the Module's
// node_action().
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/mutex.h"
#include "interface/server.h"
#include "interface/os.h"
#include "interface/voxel.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "luanti_mapgen/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "luanti/lua_util.h"
#include "luanti/map_access.h"
#include "luanti/mapgen_params.h"
#include "luanti/import.h"
#include "luanti/clock.h"
#include <functional>
#include <set>
extern "C" {
#include <lua.h>
}

namespace luanti {

namespace pv = PolyVox;

// Luanti steps at dedicated_server_step (0.09 s), buildat ticks at 30 Hz;
// a mod's globalstep dtime is written against the former
static constexpr float STEP_S = 0.09f;

struct World
{
	interface::Server *&m_server;
	main_context::SceneReference &m_scene;
	lua_State *&m_lua;
	interface::Mutex &m_lua_mutex;
	const pv::Vector3DInt16 &m_section_size;
	// Where each player is, and their peer (the Module's)
	const sm_<ss_, pv::Vector3DInt32> &m_player_pos;
	const sm_<ss_, size_t> &m_player_peers;
	const bool &m_game_running;
	MapAccess &m_map;
	GameClock &m_clock;
	MapgenParams &m_mapgen;
	Importer &m_importer;
	// A chunk of the game's Lua run as a node action (the Module's)
	std::function<bool(const ss_ &)> node_action;

	World(interface::Server *&server, main_context::SceneReference &scene,
			lua_State *&lua, interface::Mutex &lua_mutex,
			const pv::Vector3DInt16 &section_size,
			const sm_<ss_, pv::Vector3DInt32> &player_pos,
			const sm_<ss_, size_t> &player_peers, const bool &game_running,
			MapAccess &map, GameClock &clock, MapgenParams &mapgen,
			Importer &importer, std::function<bool(const ss_ &)> node_action):
		m_server(server), m_scene(scene), m_lua(lua), m_lua_mutex(lua_mutex),
		m_section_size(section_size), m_player_pos(player_pos),
		m_player_peers(player_peers), m_game_running(game_running),
		m_map(map), m_clock(clock), m_mapgen(mapgen), m_importer(importer),
		node_action(node_action)
	{}

	pv::Vector3DInt16 section_of(const pv::Vector3DInt32 &p)
	{
		return luanti::section_of(p, m_section_size);
	}

	// The voxel a generated section is filled with; see
	// on_generation_request(). Zero until the first section is generated,
	// which is after the mods have loaded and named it.
	uint32_t m_singlenode_word = 0;
	// What the world's generator was built from, kept for the questions a
	// mapgen can answer without generating: where the ground is
	luanti_mapgen::Params m_mapgen_params;

	// Luanti's three ranges, in the same descending order and for the same
	// reasons, in sections rather than its blocks of sixteen voxels:
	// max_block_send_distance (12 blocks) is the client's own and capped by
	// the load radius, max_block_generate_distance (10) is what is filled,
	// and active_block_range (4 blocks, which is exactly one section) is
	// what the ABM and LBM sweeps touch.
	// **How far out is the server's to decide, not the client's**
	// (user, 2026-09-26): a player who asks for a view range of four
	// hundred is asking this machine to keep and to make that much world,
	// and a public server has to be able to say no. So the two radii are
	// Luanti's own settings -- `max_block_send_distance` (12 blocks of
	// sixteen nodes, which is the 3 sections this used to hard-code) and
	// `max_block_generate_distance` (10 blocks, the old 2) -- read once
	// when the mods have loaded. A client's request is capped by the load
	// radius in voxelworld, which sends the smaller of the two.
	int16_t m_load_radius_xz = 3;
	int16_t m_generate_radius_xz = 2;
	// **Y does not grow with XZ.** Terrain worth generating at three
	// hundred nodes out is the band the player's eye is in; a mapgen asked
	// for a sphere spends most of it on sky and on stone a hundred and
	// fifty nodes down that nobody at that distance will look at. Which
	// band is right is the mapgen's business and this is a heuristic, not
	// a truth (user, 2026-09-26), so the vertical radii stay where they
	// are while the horizontal ones follow the setting.
	static const int16_t LOAD_RADIUS_Y = 2;
	static const int16_t GENERATE_RADIUS_Y = 1;
	static const int32_t ACTIVE_RADIUS = 1;
	// The world around the origin, which is where a mod puts things while
	// the game loads and where a player with nowhere else to be spawns. It
	// is what the world was in its entirety before it streamed.
	static const int16_t SPAWN_RADIUS = 1;
	// Taller than it is wide, because what the spawn needs is the ground
	// under the origin and a mapgen can put that a long way down -- an ocean
	// trench, a deep valley. A column too short is a player left in the air
	// at the origin with nothing under them to stand on.
	static const int16_t SPAWN_RADIUS_Y = 2;
	// How many sections a streaming pass may take on, which goes down while
	// a mod's mapgen is slow; see run_on_generated(), and is nothing at all
	// while a world is being imported into this one
	size_t m_stream_budget = 2;

	// The map check, which waits for the sections it uses; see
	// start_check_map()
	bool m_check_map_pending = false;
	float m_check_map_waited = 0.0f;
	sv_<pv::Vector3DInt16> m_check_sections;
	sv_<uint64_t> m_check_pinned;
	// Sections a generator has been over and whose voxels have arrived;
	// kept only while the check is waiting for its own
	std::set<uint64_t> m_generated_sections;

	// Luanti's forceload: a block a mod wants kept whatever nobody is near
	// it, which is a load point with no radius at all. Kept by section,
	// because that is what loads and unloads here; a mod asking for a
	// block gets the section it is in.
	//
	// Nothing here is written down, and nothing needs to be: the vendored
	// builtin's forceloading.lua keeps the ones that are not transient in
	// force_loaded.txt beside the world and asks for them again when it
	// loads, which is where Luanti keeps them too.
	// Section key -> how many holds: a game's forceload_block() per
	// mapblock (VoxeLibre makes and frees thousands) and the map check's
	// pin share this, and one owner's free took the other's hold with it
	// (the check read its room out of an unloaded section, 2026-09-21)
	sm_<uint64_t, int> m_forceloaded;


	// Where the world stays loaded: every player, and the origin whether or
	// not anybody is there. A player's point is tagged with their peer,
	// which is what makes it the point the world is sent to them from.
	void update_load_points()
	{
		if(!m_scene)
			return;
		sv_<voxelworld::LoadPoint> points;
		points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(0, 0, 0),
				SPAWN_RADIUS, SPAWN_RADIUS_Y,
				SPAWN_RADIUS, SPAWN_RADIUS_Y));
		for(const auto &pair : m_player_pos){
			size_t peer = 0;
			auto it = m_player_peers.find(pair.first);
			if(it != m_player_peers.end())
				peer = it->second;
			points.push_back(voxelworld::LoadPoint(pair.second,
					m_load_radius_xz, LOAD_RADIUS_Y,
					m_generate_radius_xz, GENERATE_RADIUS_Y, peer));
		}
		// A forceloaded section is a point with no radius at all
		for(const auto &pair : m_forceloaded){
			const pv::Vector3DInt16 sp = section_from_key(pair.first);
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					(int32_t)sp.getX() * m_section_size.getX(),
					(int32_t)sp.getY() * m_section_size.getY(),
					(int32_t)sp.getZ() * m_section_size.getZ()),
					0, 0, 0, 0));
		}
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_load_points(points);
			world->set_stream_budget(m_stream_budget);
		});
	}

	// Luanti's own two settings, read once the mods have loaded and
	// turned from its blocks of sixteen nodes into this world's sections
	// of sixty-four. The defaults are Luanti's: 12 blocks sent, 10
	// generated, which are the 3 and 2 sections this carried before.
	void read_range_settings()
	{
		run_chunk_string(m_lua, m_lua_mutex,
				"__buildat_send_blocks = tonumber(core.settings:get("
				"'max_block_send_distance')) or 12 "
				"__buildat_generate_blocks = tonumber(core.settings:get("
				"'max_block_generate_distance')) or 10",
				"read_range_settings");
		auto sections_of = [&](const char *global, int fallback) -> int16_t {
			lua_getglobal(m_lua, global);
			const int blocks = lua_isnumber(m_lua, -1) ?
					(int)lua_tonumber(m_lua, -1) : fallback;
			lua_pop(m_lua, 1);
			// Sixteen nodes to a block, sixty-four to a section; never
			// nothing, and never so much that one player's setting can ask
			// the machine for a world of thousands of sections
			const int sections = blocks * 16 / 64;
			return (int16_t)(sections < 1 ? 1 : (sections > 16 ? 16 :
					sections));
		};
		m_load_radius_xz = sections_of("__buildat_send_blocks", 12);
		m_generate_radius_xz = sections_of("__buildat_generate_blocks", 10);
		log_i(MODULE, "world kept %i sections out and generated %i "
				"(max_block_send_distance, max_block_generate_distance)",
				(int)m_load_radius_xz, (int)m_generate_radius_xz);
	}

	// The mapgen, which at singlenode is one node everywhere: Luanti's own
	// MapgenSinglenode fills a generated block with whatever
	// "mapgen_singlenode" names, or with air when a game does not name one,
	// and sets the sunlight. So a generated section here is air as well --
	// what a mod reads out of a part of the world nobody has built in is
	// "air" and not "ignore", which is what every mod that looks before it
	// places is written against.
	//
	// merge_volume() and not set_volume(): this is a generator, and the
	// priorities in voxelworld's api.h are exactly what a generator wants --
	// anything a mod has already put there stays.
	//
	// simplified: the section is filled at once rather than a chunk at a
	// time as voxelworld asks, because a singlenode section is one word
	// repeated and the whole of it costs a few milliseconds. A real mapgen
	// is the milestone where that stops being true.
	uint32_t singlenode_word()
	{
		if(m_singlenode_word == 0){
			bool known = false;
			uint32_t id = m_importer.import_content_id("mapgen_singlenode", known);
			if(!known)
				id = m_importer.import_content_id("air", known);
			const interface::VoxelFormat f = interface::VoxelFormat::luanti();
			uint32_t word = 0;
			f.id.set(word, id);
			// Lit, because a world with nothing in it is a world the sky
			// reaches everywhere in -- and because this is written before
			// voxelworld's skylight is turned on, so nothing else will put
			// the light there. Luanti's MapgenSinglenode sets the same
			// sunlight for the same reason.
			f.light_sky.set(word, f.light_sky.mask());
			m_singlenode_word = word;
		}
		return m_singlenode_word;
	}

	void generate_section(voxelworld::Instance *world,
			const pv::Vector3DInt16 &section_p)
	{
		pv::Region region = world->get_section_region_voxels(section_p);
		interface::VoxelVolume vol(region);
		vol.fill(interface::VoxelInstance(singlenode_word()));
		world->merge_volume(vol, false);
	}

	// worldgen has filled a section and merged it into the world. The
	// callbacks a mod registered run here, on the main thread, over terrain
	// that is already in the map -- which is the same order Luanti gives
	// them: its mapgen has written the chunk by the time they see it.
	void on_section_generated(const worldgen::SectionGenerated &event)
	{
		m_map.drop_read_cache();
		if(m_check_map_pending)
			m_generated_sections.insert(section_key(event.section_p));
		if(!m_game_running || event.scene != m_scene)
			return;
		for(const pv::Vector3DInt16 &c : chunks_completed(event.section_p))
			run_on_generated_chunk(c);
	}

	// The chunks run_on_generated_chunk() has been over in this run. Not
	// saved: a chunk is complete when its last section is generated, and
	// that happens once, or once more after a trim forgot it.
	std::set<int64_t> m_chunks_run;
	// The chunks a generated section is in that are still missing one,
	// so their on_generated has not run: emerge_area() does not call a
	// block of one there yet, as Luanti calls it after on_generated.
	// simplified: a section between its merge and its event here reads
	// as there already; the window is one event dispatch.
	std::set<int64_t> m_chunks_pending;
	// Sections asked for only to complete a chunk. One of them arriving
	// completes what it can and asks for nothing more: asking again would
	// complete the next chunk out, and the next, without end.
	std::set<uint64_t> m_completion_sections;
	// A pending chunk's sections, pinned the way a forceload pins one
	// until its on_generated has run: the streamer unloads what no point
	// holds, and the game's writes into an unloaded section are dropped --
	// VoxeLibre's bedrock and void were, under the box a test asked for.
	sm_<int64_t, sv_<uint64_t>> m_chunk_pins;

	static int64_t chunk_key(int x, int y, int z)
	{
		return ((int64_t)(int16_t)x << 32) | ((int64_t)(uint16_t)y << 16) |
				(int64_t)(uint16_t)z;
	}

	// Luanti runs a game's on_generated once per mapchunk, over all of
	// it, and a game's chances and boxes are written against that. A
	// chunk is in up to eight sections; this returns the ones this section
	// completed. Near a player or the spawn, the sections a chunk is still
	// missing are asked for too, so the ground there is finished; anywhere
	// else a chunk waits until something wants a block of it (see
	// ask_chunk() in l_loaded_at). Completing every chunk a section touches
	// is what Luanti does not do -- an emerge there generates one chunk --
	// and with VoxeLibre's dungeons, which emerge their own surroundings,
	// it never stopped spreading.
	sv_<pv::Vector3DInt16> chunks_completed(const pv::Vector3DInt16 &section_p)
	{
		using luanti_mapgen::chunk_index;
		sv_<pv::Vector3DInt16> out;
		const int sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		if(sx <= 0)
			return out;
		const int x0 = section_p.getX() * sx, y0 = section_p.getY() * sy,
				z0 = section_p.getZ() * sz;
		const bool asked = m_completion_sections.erase(section_key(section_p));
		// Forceloaded too: Luanti emerges a forceloaded block's whole
		// mapchunk, and with nobody near the sections of it outside the
		// forceload were left to unload before it completed
		const bool may_ask = !asked && (near_a_point(section_p) ||
				m_forceloaded.count(section_key(section_p)));
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(int cz = chunk_index(z0); cz <= chunk_index(z0 + sz - 1); cz++)
			for(int cy = chunk_index(y0); cy <= chunk_index(y0 + sy - 1); cy++)
			for(int cx = chunk_index(x0); cx <= chunk_index(x0 + sx - 1); cx++){
				if(m_chunks_run.count(chunk_key(cx, cy, cz)))
					continue;
				if(ask_chunk(world, cx, cy, cz, may_ask))
					out.push_back(pv::Vector3DInt16(cx, cy, cz));
			}
		});
		if(m_load_points_changed){
			m_load_points_changed = false;
			update_load_points();
		}
		return out;
	}

	// Whether a chunk not yet run has all its sections generated; true
	// marks it run, and the caller runs it. With ask, the missing ones are
	// asked for -- from the save, which is synchronous, or from the
	// generator, whose answer comes back through on_section_generated().
	bool ask_chunk(voxelworld::Instance *world, int cx, int cy, int cz,
			bool ask)
	{
		using luanti_mapgen::CHUNK_NODES;
		using luanti_mapgen::CHUNK_OFFSET;
		const int sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int nx = cx * CHUNK_NODES + CHUNK_OFFSET;
		const int ny = cy * CHUNK_NODES + CHUNK_OFFSET;
		const int nz = cz * CHUNK_NODES + CHUNK_OFFSET;
		const int64_t key = chunk_key(cx, cy, cz);
		bool complete = true;
		const bool pin = ask && !m_chunk_pins.count(key);
		for(int z = floordiv(nz, sz); z <= floordiv(nz + CHUNK_NODES - 1, sz); z++)
		for(int y = floordiv(ny, sy); y <= floordiv(ny + CHUNK_NODES - 1, sy); y++)
		for(int x = floordiv(nx, sx); x <= floordiv(nx + CHUNK_NODES - 1, sx); x++){
			const pv::Vector3DInt16 sp(x, y, z);
			if(pin){
				m_forceloaded[section_key(sp)]++;
				m_chunk_pins[key].push_back(section_key(sp));
				m_load_points_changed = true;
			}
			if(world->is_section_generated(sp))
				continue;
			if(ask){
				world->load_or_generate_section(sp);
				if(world->is_section_generated(sp))
					continue;
				m_completion_sections.insert(section_key(sp));
			}
			complete = false;
		}
		if(complete){
			m_chunks_run.insert(key);
			m_chunks_pending.erase(key);
		} else {
			m_chunks_pending.insert(key);
		}
		return complete;
	}

	// Inside the generate radius of the spawn's point or a player's
	bool near_a_point(const pv::Vector3DInt16 &sp)
	{
		auto in_reach = [&](const pv::Vector3DInt16 &c, int rxz, int ry){
			return std::abs(sp.getX() - c.getX()) <= rxz &&
					std::abs(sp.getZ() - c.getZ()) <= rxz &&
					std::abs(sp.getY() - c.getY()) <= ry;
		};
		if(in_reach(pv::Vector3DInt16(0, 0, 0), SPAWN_RADIUS, SPAWN_RADIUS_Y))
			return true;
		for(const auto &pair : m_player_pos){
			if(in_reach(section_of(pair.second), m_generate_radius_xz,
					GENERATE_RADIUS_Y))
				return true;
		}
		return false;
	}

	// Chunks an emerge completed, run on the next tick: l_loaded_at is
	// called from Lua, and a mod's on_generated is not run inside it
	sv_<pv::Vector3DInt16> m_chunks_to_run;
	// Pins changed inside a voxelworld access, where the points cannot be
	// pushed: whoever made the access pushes them after it
	bool m_load_points_changed = false;

	void run_completed_chunks()
	{
		sv_<pv::Vector3DInt16> list;
		list.swap(m_chunks_to_run);
		for(const pv::Vector3DInt16 &c : list)
			run_on_generated_chunk(c);
	}

	// A mod's on_generated over one mapchunk, as Luanti calls it: the
	// chunk's corners, the blockseed its mapgen used, and what the mapgen
	// reported and mapped there
	void run_on_generated_chunk(const pv::Vector3DInt16 &c)
	{
		using luanti_mapgen::CHUNK_NODES;
		using luanti_mapgen::CHUNK_OFFSET;
		sv_<luanti_mapgen::GennotifyEvent> events;
		luanti_mapgen::SectionMaps maps;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *im){
			im->take_gennotify(c.getX(), c.getY(), c.getZ(), events);
			im->take_maps(c.getX(), c.getY(), c.getZ(), maps);
		});
		const int x0 = c.getX() * CHUNK_NODES + CHUNK_OFFSET;
		const int y0 = c.getY() * CHUNK_NODES + CHUNK_OFFSET;
		const int z0 = c.getZ() * CHUNK_NODES + CHUNK_OFFSET;
		run_on_generated_box(x0, y0, z0, x0 + CHUNK_NODES - 1,
				y0 + CHUNK_NODES - 1, z0 + CHUNK_NODES - 1,
				luanti_mapgen::chunk_blockseed(c.getX(), c.getY(), c.getZ(),
						m_clock.m_seed),
				gennotify_string(events), maps);
		auto pins = m_chunk_pins.find(chunk_key(c.getX(), c.getY(), c.getZ()));
		if(pins != m_chunk_pins.end()){
			for(uint64_t k : pins->second){
				auto it = m_forceloaded.find(k);
				if(it != m_forceloaded.end() && --it->second <= 0)
					m_forceloaded.erase(it);
			}
			m_chunk_pins.erase(pins);
		}
	}

	// The world create_instance() just made, asked for before anything reads
	// it, and -- in a singlenode world only -- filled here as well.
	//
	// The fill is what makes a singlenode world a world: nobody answers a
	// generation request there, so without it the map is void rather than
	// air. A world with a mapgen must not have it. Its air would be written
	// into sections the generator has not reached yet, and air that is
	// already in the map is terrain as far as anything else is concerned --
	// which is how a v7 world came to have a room the size of this loop
	// under its surface (2026-09-13, and see "What the first playtest of a
	// generated world found" in doc/plan/luanti_module_plan.md).
	//
	// The sections are still asked for either way: worldgen answers in its
	// own thread and the answers arrive after run_game() has returned, but
	// asking early is what gets the ground near the origin on its way
	// before a player is standing on it.
	void generate_world()
	{
		const bool fill = (m_mapgen.mapgen_name() == "singlenode");
		const pv::Vector3DInt32 p0(-SPAWN_RADIUS, -SPAWN_RADIUS_Y,
				-SPAWN_RADIUS);
		const pv::Vector3DInt32 p1(SPAWN_RADIUS, SPAWN_RADIUS_Y,
				SPAWN_RADIUS);
		size_t n = 0, already = 0;
		sv_<pv::Vector3DInt16> generated;
		int64_t t0 = interface::os::time_us();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(int32_t z = p0.getZ(); z <= p1.getZ(); z++)
			for(int32_t y = p0.getY(); y <= p1.getY(); y++)
			for(int32_t x = p0.getX(); x <= p1.getX(); x++){
				pv::Vector3DInt16 section_p(x, y, z);
				// voxelworld makes the region's sections on its first tick
				// rather than when the instance is created, so that a game
				// has its chance to name a save first; that has happened by
				// now, and what is read next is the map, so they are asked
				// for here
				if(!world->is_section_loaded(section_p))
					world->load_or_generate_section(section_p);
				if(!fill)
					continue;
				// A section that has been generated already holds this
				// node everywhere nothing else was built, so one voxel of
				// it says whether the fill has been here -- and a section
				// out of a save is not walked again for nothing. A save
				// from before there was a fill reads as undefined and gets
				// one, which is the migration.
				pv::Region r = world->get_section_region_voxels(section_p);
				if(world->get_voxel(r.getLowerCorner(), true).data != 0){
					already++;
					continue;
				}
				generate_section(world, section_p);
				generated.push_back(section_p);
				n++;
			}
		});
		if(fill){
			log_v(MODULE, "The world: %zu sections filled with one node in "
					"%i ms, %zu already there", n,
					(int)((interface::os::time_us() - t0) / 1000), already);
		} else {
			log_v(MODULE, "The world: the sections around the origin asked "
					"for in %i ms; the mapgen fills them",
					(int)((interface::os::time_us() - t0) / 1000));
		}
		// Outside the access: a mod's on_generated reads and writes the map
		// through a VoxelManip, which is voxelworld again
		for(const pv::Vector3DInt16 &section_p : generated)
			run_on_generated(section_p);
	}

	// A mod's core.register_on_generated, over the section that has just
	// been filled. Luanti runs these after its mapgen has written a chunk
	// and before the block is put in the map; here the fill is already in
	// the map and a mod writes over it, which is the same order from a
	// mod's point of view -- what it reads is the generated terrain and
	// what it writes lands on top.
	//
	// Not inside a voxelworld access: what a mod does here is a VoxelManip,
	// which reaches into voxelworld itself.
	//
	// simplified: per section, with a section's own blockseed. What calls
	// this is a singlenode world's fill, where there is no mapgen chunk;
	// a generated world runs run_on_generated_chunk() instead.
	void run_on_generated(const pv::Vector3DInt16 &section_p)
	{
		if(!m_scene || m_section_size.getX() <= 0)
			return;
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int32_t x0 = (int32_t)section_p.getX() * sx;
		const int32_t y0 = (int32_t)section_p.getY() * sy;
		const int32_t z0 = (int32_t)section_p.getZ() * sz;
		run_on_generated_box(x0, y0, z0, x0 + sx - 1, y0 + sy - 1,
				z0 + sz - 1, (uint32_t)block_seed(section_p), "",
				luanti_mapgen::SectionMaps());
	}

	void run_on_generated_box(int x0, int y0, int z0, int x1, int y1, int z1,
			uint32_t blockseed, const ss_ &gennotify,
			const luanti_mapgen::SectionMaps &maps)
	{
		if(!m_scene)
			return;
		{
			interface::MutexScope ms(m_lua_mutex);
			set_global_string(m_lua, "__luanti_gennotify", gennotify);
			set_global_maps(maps);
		}
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__run_on_generated(%i, %i, %i, %i, %i, %i, %u)",
				x0, y0, z0, x1, y1, z1, (unsigned)blockseed);
		// Timed because it is a mod's code over a quarter of a million
		// voxels on the server's own thread: Luanti generates on an emerge
		// thread of its own, and this module has one Lua state and no
		// thread to put it on. A mapgen that takes longer than a step is
		// what makes that a problem rather than a note.
		const int64_t t0 = interface::os::time_us();
		// No light flood for what the mods write here: the box they
		// touched is relit once, later, under the tick's budget, and the
		// flood from a cave-carving section was 550 ms of the same work
		// ([STEP_SLICE])
		m_map.m_gen_writing = true;
		m_map.m_gen_wrote = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_deferred(true);
		});
		node_action(buf);
		m_map.flush_node_writes();
		m_map.m_gen_writing = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_deferred(false);
			if(m_map.m_gen_wrote)
				world->relight_region_later(m_map.m_gen_bbox);
		});
		const int64_t took = interface::os::time_us() - t0;
		if(took > 1000){
			log_v(MODULE, "on_generated (%i, %i, %i): %i ms",
					x0, y0, z0, (int)(took / 1000));
		}
		// A generator that takes longer than a step is one the streamer
		// should ask less of: one section a pass instead of two, until it
		// is quick again. This is what set_stream_budget() is for, and only
		// this module can see how long its own mods took.
		m_stream_budget = (took > (int64_t)(STEP_S * 1000000.0)) ? 1 : 2;
	}

	// What the mapgen made in a chunk and was asked to report, as a
	// line per event: the name, and where it is. A string because that is
	// the boundary the rest of this crossing uses, and because a section
	// with three hundred decorations in it is ten kilobytes of it.
	static ss_ gennotify_string(
			const sv_<luanti_mapgen::GennotifyEvent> &events)
	{
		ss_ out;
		for(const luanti_mapgen::GennotifyEvent &e : events){
			out += e.name;
			out += " "+itos(e.x)+" "+itos(e.y)+" "+itos(e.z)+"\n";
		}
		return out;
	}

	// __luanti_mapgen_maps = {size_x, size_z, heightmap = {...}, biomemap,
	// heatmap, humiditymap}: the section's maps as Lua arrays, x fastest
	// then z, 1-based; a map the mapgen did not make is absent, and the
	// whole table nil when there are none
	void set_global_maps(const luanti_mapgen::SectionMaps &maps)
	{
		lua_State *L = m_lua;
		if(maps.heightmap.empty() && maps.biomemap.empty()){
			lua_pushnil(L);
			lua_setglobal(L, "__luanti_mapgen_maps");
			return;
		}
		lua_newtable(L);
		lua_pushinteger(L, maps.size_x);
		lua_setfield(L, -2, "size_x");
		lua_pushinteger(L, maps.size_z);
		lua_setfield(L, -2, "size_z");
		auto push_ints = [&](const char *name, const int16_t *p16,
				const uint16_t *pu16, size_t n){
			if(n == 0)
				return;
			lua_createtable(L, (int)n, 0);
			for(size_t i = 0; i < n; i++){
				lua_pushinteger(L, p16 ? (int)p16[i] : (int)pu16[i]);
				lua_rawseti(L, -2, (int)i + 1);
			}
			lua_setfield(L, -2, name);
		};
		auto push_floats = [&](const char *name, const sv_<float> &v){
			if(v.empty())
				return;
			lua_createtable(L, (int)v.size(), 0);
			for(size_t i = 0; i < v.size(); i++){
				lua_pushnumber(L, v[i]);
				lua_rawseti(L, -2, (int)i + 1);
			}
			lua_setfield(L, -2, name);
		};
		push_ints("heightmap", maps.heightmap.data(), nullptr,
				maps.heightmap.size());
		push_ints("biomemap", nullptr, maps.biomemap.data(),
				maps.biomemap.size());
		push_floats("heatmap", maps.heatmap);
		push_floats("humiditymap", maps.humidmap);
		lua_setglobal(L, "__luanti_mapgen_maps");
	}

	// Luanti's get_blockseed2, which is what a mapgen's randomness starts
	// from: the world's seed and where the block is
	int32_t block_seed(const pv::Vector3DInt16 &p)
	{
		return (int32_t)(uint32_t)((uint64_t)m_clock.m_seed % 0x100000000ULL) +
				(int32_t)p.getZ() * 38134234 +
				(int32_t)p.getY() * 42123 +
				(int32_t)p.getX() * 23;
	}

	// lua/check_map.lua, with the flush this module does between its two
	// halves: a round trip that never leaves the write-behind buffer would
	// prove nothing about voxelworld.
	// The check works above where any mapgen builds, in sections that
	// nothing else keeps: a player's point is elsewhere, the streamer
	// unloads what no point holds, and a generator that arrives after the
	// check has written its room owns that section and writes over it. So
	// the sections are pinned the way a forceload pins one, asked for, and
	// the round trip waits until a generator has been over every one of
	// them -- which is what anything writing terrain of its own has to do.
	void start_check_map()
	{
		m_check_sections = check_map_sections();
		for(const pv::Vector3DInt16 &sp : m_check_sections){
			const uint64_t k = section_key(sp);
			m_forceloaded[k]++;
			m_check_pinned.push_back(k);
		}
		update_load_points();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(const pv::Vector3DInt16 &sp : m_check_sections){
				if(!world->is_section_loaded(sp))
					world->load_or_generate_section(sp);
			}
		});
		m_check_map_pending = true;
		m_check_map_waited = 0.0f;
	}

	// Once a generator has been over all of them; see start_check_map()
	void check_map_when_ready(float dtime)
	{
		if(!m_check_map_pending)
			return;
		m_check_map_waited += dtime;
		// Every section a generator has actually been over, which is what
		// on_section_generated() records. voxelworld calls a section
		// generated as soon as it has asked for one, and the volume arrives
		// later -- so waiting on that would have the check writing its room
		// just before the generator wrote over it.
		bool ready = true;
		for(const pv::Vector3DInt16 &sp : m_check_sections){
			if(m_generated_sections.count(section_key(sp)) == 0){
				ready = false;
				break;
			}
		}
		if(!ready){
			// A world whose generator never answers is a world this cannot
			// check; it is said once and the check is dropped rather than
			// waited for forever
			if(m_check_map_waited < 20.0f)
				return;
			log_w(MODULE, "check_map: the sections it uses were not "
					"generated in %.0f seconds; skipping the check",
					(double)m_check_map_waited);
			m_check_map_pending = false;
			unpin_check_map();
			return;
		}
		m_check_map_pending = false;
		m_generated_sections.clear();
		check_map_round_trip();
		unpin_check_map();
	}

	void unpin_check_map()
	{
		for(uint64_t k : m_check_pinned){
			auto it = m_forceloaded.find(k);
			if(it != m_forceloaded.end() && --it->second <= 0)
				m_forceloaded.erase(it);
		}
		m_check_pinned.clear();
		update_load_points();
	}

	void check_map_round_trip()
	{
		run_chunk_string(m_lua, m_lua_mutex, "if not core.__check_map_write() then\n"
				"    core.log('verbose', 'check_map: no node to write')\n"
				"    core.__check_map_read = function() end\n"
				"end\n", "check_map_write");
		m_map.flush_node_writes();
		// A self-check that fails is a warning, not the end of a running
		// game: it has read `ignore` back once under a 6.8 s emerge step
		// with a player in the world, and took the server with it. What
		// it found is logged and stays open -- [CHECK_MAP_FLAKE] in
		// doc/plan/luanti_module_plan.md.
		try {
			run_chunk_string(m_lua, m_lua_mutex, "core.__check_map_read()",
					"check_map_read");
		} catch(std::exception &e){
			log_w(MODULE, "check_map: the round trip failed and the game "
					"goes on: %s", e.what());
		}
		// The check puts air back where it wrote; that has to land too, or
		// the world starts with a block of cobble nobody asked for
		m_map.flush_node_writes();
	}

	// The sections core.__check_map_box() reaches into
	sv_<pv::Vector3DInt16> check_map_sections()
	{
		sv_<pv::Vector3DInt16> out;
		if(!m_lua || m_section_size.getX() <= 0)
			return out;
		int32_t b[6] = {};
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__check_map_box");
			if(lua_pcall(L, 0, 6, 0) != 0){
				log_w(MODULE, "__check_map_box(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return out;
			}
			for(int i = 0; i < 6; i++)
				b[i] = (int32_t)lua_tonumber(L, -6 + i);
			lua_settop(L, base);
		}
		const pv::Vector3DInt16 p0 = section_of(
				pv::Vector3DInt32(b[0], b[1], b[2]));
		const pv::Vector3DInt16 p1 = section_of(
				pv::Vector3DInt32(b[3], b[4], b[5]));
		for(int16_t z = p0.getZ(); z <= p1.getZ(); z++)
		for(int16_t y = p0.getY(); y <= p1.getY(); y++)
		for(int16_t x = p0.getX(); x <= p1.getX(); x++)
			out.push_back(pv::Vector3DInt16(x, y, z));
		return out;
	}
};

}
// vim: set noet ts=4 sw=4:
