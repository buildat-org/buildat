// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The map as the game's Lua reads and writes it ([LUANTI_MODULAR]: a part
// of the Module, owning the write-behind buffer, the read cache and what a
// mapgen mod's on_generated wrote, with references to the server and the
// world's scene). read_node() and the writes are called per voxel from
// Lua: plain calls on state of its own.
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/server.h"
#include "interface/os.h"
#include "interface/voxel.h"
#include "voxelworld/api.h"
#include "main_context/api.h"
#include "luanti/api.h"
#include <unordered_map>
#include <algorithm>

namespace luanti {

namespace pv = PolyVox;

static inline int32_t floordiv(int32_t a, int32_t b)
{
	return (a >= 0) ? (a / b) : -((-a + b - 1) / b);
}

// 21 bits each, which covers Luanti's +-31000 map many times over
static inline int64_t pos_key(int32_t x, int32_t y, int32_t z)
{
	return ((int64_t)(x & 0x1fffff) << 42) |
			((int64_t)(y & 0x1fffff) << 21) |
			((int64_t)(z & 0x1fffff));
}

// Around what the engine calls for a player -- a dig, a place, a use, a
// chat command, a formspec's fields: what the game writes meanwhile is
// that player's. simplified: what it sets going (a fire, TNT's chain)
// is the world's own once the call returns.
struct PlayerCause {
	bool &flag, was;
	PlayerCause(bool &flag, bool on = true): flag(flag), was(flag)
	{
		flag = was || on;
	}
	~PlayerCause(){ flag = was; }
};

struct MapAccess
{
	interface::Server *&m_server;
	main_context::SceneReference &m_scene;

	MapAccess(interface::Server *&server, main_context::SceneReference &scene):
		m_server(server), m_scene(scene)
	{}

	// While a mapgen mod's on_generated runs: what it wrote, as a box, so
	// that the one relight it gets afterwards covers it ([STEP_SLICE])
	bool m_gen_writing = false;
	bool m_gen_wrote = false;
	pv::Region m_gen_bbox;
	void note_gen_write(const pv::Region &r)
	{
		if(!m_gen_writing)
			return;
		if(!m_gen_wrote){
			m_gen_bbox = r;
			m_gen_wrote = true;
			return;
		}
		const pv::Vector3DInt32 a = m_gen_bbox.getLowerCorner(),
				b = m_gen_bbox.getUpperCorner(),
				c = r.getLowerCorner(), d = r.getUpperCorner();
		m_gen_bbox = pv::Region(
				pv::Vector3DInt32(std::min(a.getX(), c.getX()),
					std::min(a.getY(), c.getY()), std::min(a.getZ(), c.getZ())),
				pv::Vector3DInt32(std::max(b.getX(), d.getX()),
					std::max(b.getY(), d.getY()), std::max(b.getZ(), d.getZ())));
	}
	// The write-behind buffer. core.set_node writes here and voxelworld sees
	// it once per Luanti step, inside a single access() -- one commit covers
	// every chunk the step touched, instead of a skylight pass and a 32^3
	// serialize-and-replicate per node placed. core.get_node reads through
	// it, because Luanti's semantics are that a write is visible immediately
	// and the callbacks in the same step will look.
	// by_player: written while a player's action was handled ([SAVE_LIMIT]),
	// which makes its section altered and keeps it out of a trim
	struct PendingNode { int32_t x, y, z; uint32_t word; bool by_player; };
	bool m_by_player = false;
	std::unordered_map<int64_t, PendingNode> m_node_writes;


	void flush_node_writes()
	{
		if(m_node_writes.empty() || !m_scene)
			return;
		drop_read_cache();
		size_t n = m_node_writes.size();
		const int64_t t0 = interface::os::time_us();
		int64_t t_set = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			// set_voxel() into a section that is not there does nothing and
			// says so in a warning. Luanti's set_node emerges the block it
			// writes into, so this does too -- and in a singlenode world
			// "generate" means nobody answers the request, which is what
			// makes the world void.
			pv::Vector3DInt16 size = world->get_section_size_voxels();
			for(const auto &pair : m_node_writes){
				const PendingNode &node = pair.second;
				pv::Vector3DInt16 section_p(
						floordiv(node.x, size.getX()),
						floordiv(node.y, size.getY()),
						floordiv(node.z, size.getZ()));
				// Loaded, not generated: a set_node past the generated
				// world -- a mapgen mod's structure into the next section
				// -- waits there for the generator, which keeps what stands
				if(!world->is_section_loaded(section_p))
					world->load_section_no_generate(section_p);
			}
			for(const auto &pair : m_node_writes){
				const PendingNode &node = pair.second;
				world->set_cause(node.by_player ? "a player" : "");
				world->set_voxel(pv::Vector3DInt32(node.x, node.y, node.z),
						interface::VoxelInstance(node.word), true);
			}
			world->set_cause("");
			t_set = interface::os::time_us();
		});
		m_node_writes.clear();
		// Split into the writes and the commit that follows them on the
		// way out of access(), since a step's flush is what is left of
		// its stall once the reads stopped flushing ([STEP_PEAK])
		const int64_t took = interface::os::time_us() - t0;
		if(took > 50000)
			log_v(MODULE, "Flushed %zu node writes in %.2f s: the writes "
					"%.2f, the commit %.2f", n, took / 1e6, (t_set - t0) / 1e6,
					(interface::os::time_us() - t_set) / 1e6);
		else
			log_d(MODULE, "Flushed %zu node writes", n);
	}

	RegionMap *m_region_map = nullptr;

	void buffer_node_write(int32_t x, int32_t y, int32_t z, uint32_t word)
	{
		if(!coord_ok(x) || !coord_ok(y) || !coord_ok(z))
			return;
		// A body's voxel ([BODY_INTERACT]): written straight to its owner,
		// which is not the map and has no buffer to land in
		if(y >= REGION_Y){
			// **And a write with no body under it says so** (2026-09-25):
			// a body's volume carries four voxels of air around it and a
			// place past that has nowhere to land, so it was dropped in
			// silence -- the node simply never appeared, and nothing in
			// any log said why. Growing the volume is the fix and it is
			// [BODY_INTERACT]'s own leftover; until then this is the
			// line that names it. Rate limited: a VoxelManip over a body
			// is a write per voxel and a mod that misses by one misses
			// by thousands.
			if(!m_region_map || !m_region_map->set(x, y, z, word)){
				// Counted rather than timed: this module has no clock of
				// its own in scope, and what a reader needs is the first
				// one and a sense of how many followed
				static uint64_t dropped = 0;
				dropped++;
				if(dropped == 1 || dropped % 1000 == 0){
					log_w(MODULE, "a write at %i,%i,%i is past every "
							"body's margin and is dropped (%llu so far)",
							(int)x, (int)y, (int)z,
							(unsigned long long)dropped);
				}
			}
			return;
		}
		PendingNode node;
		node.x = x;
		node.y = y;
		node.z = z;
		node.word = word;
		node.by_player = m_by_player;
		auto it = m_node_writes.find(pos_key(x, y, z));
		if(it != m_node_writes.end() && it->second.by_player)
			node.by_player = true;
		m_node_writes[pos_key(x, y, z)] = node;
		note_gen_write(pv::Region(pv::Vector3DInt32(x, y, z),
				pv::Vector3DInt32(x, y, z)));
	}

	// A read takes one voxelworld access(), which commits on the way out.
	// commit() is cheap with nothing dirty, but it is not free; what reads a
	// box reads it with read_region() below.
	uint32_t read_node(int32_t x, int32_t y, int32_t z)
	{
		// Ignore, past anything that can be there
		if(!coord_ok(x) || !coord_ok(y) || !coord_ok(z))
			return 0;
		// A buffered write answers with the word that went in. The read
		// used to flush the buffer first so that a mod placing a lamp and
		// asking what the room is lit by saw the flood -- but every flush
		// is a voxelworld commit with the skylight, and a mod that reads
		// and writes node by node (VoxeLibre's fix_foliage_missed over a
		// forest, its structure placers, any set_node, which reads first)
		// paid one per node: 31 s for one section's on_generated, 1.9
		// million skylight updates for a bench. So a read answers out of
		// the buffer for what is buffered and out of the world for the
		// rest, and the buffer lands at the end of the step or before a
		// region read.
		// simplified: the light of a voxel *next to* a buffered write is
		// the light before it, until the flush. A mod that needs the flood
		// in the same step reads a region (VoxelManip), which flushes.
		auto it = m_node_writes.find(pos_key(x, y, z));
		if(it != m_node_writes.end())
			return it->second.word;
		// A body's voxel ([BODY_INTERACT]), or ignore where no body is
		if(y >= REGION_Y){
			uint32_t word = 0;
			if(m_region_map && m_region_map->get(x, y, z, word))
				return word;
			return 0;
		}
		// Before the world exists -- the mods are loading -- everything
		// else is ignore; the buffer above still answers, which is what
		// a mod's own load-time check of set_node and place_node reads
		// (the minimal game's floor mod; [WIN_MAPGEN_BUILD] found it
		// failing since the guard stood ahead of the buffer)
		if(!m_scene)
			return 0;
		// And out of a cache of 16^3 blocks for the rest: an access() is
		// a handoff to voxelworld's thread and back, a quarter of a
		// millisecond whatever it reads, and what reads node by node is a
		// mod sweeping a box -- fix_foliage_missed read 171 thousand of
		// them in two minutes. One region read per block instead. The
		// cache is dropped whenever the world can have moved under it:
		// a flush, a region write, a step, a section generated.
		const int32_t bx = floordiv(x, 16), by = floordiv(y, 16),
				bz = floordiv(z, 16);
		const int64_t key = pos_key(bx, by, bz);
		auto c = m_read_cache.find(key);
		if(c == m_read_cache.end()){
			// The first read of a block is a single voxel; the block is
			// read whole on the second. A world generating drops the
			// cache every section, and a mod reading one node here and
			// one there paid a 4096-voxel region per read for nothing --
			// a second on devtest's world generation.
			if(m_read_seen.insert(key).second){
				uint32_t word = 0;
				voxelworld::access(m_server, m_scene,
						[&](voxelworld::Instance *world){
					word = world->get_voxel(pv::Vector3DInt32(x, y, z),
							true).data;
				});
				return word;
			}
			sv_<uint32_t> words;
			read_region_uncached(bx * 16, by * 16, bz * 16,
					bx * 16 + 15, by * 16 + 15, bz * 16 + 15, words);
			c = m_read_cache.emplace(key, std::move(words)).first;
		}
		return c->second[(size_t)((z - bz * 16) * 256 + (y - by * 16) * 16 +
				(x - bx * 16))];
	}

	// See read_node()
	std::unordered_map<int64_t, sv_<uint32_t>> m_read_cache;
	set_<int64_t> m_read_seen;
	void drop_read_cache()
	{
		m_read_cache.clear();
		m_read_seen.clear();
	}

	// Luanti's own cap on how much map a call may look at in one go
	// (MAX_WORKING_VOLUME). A mod asking for more than this has made a
	// mistake, and quietly building a table of that many numbers is not the
	// way to tell it so.
	static const size_t MAX_REGION_VOXELS = 4096000;
	// How far from the origin a node can be, the bodies' band at REGION_Y
	// included. Past it nothing is read or written: a coordinate from a
	// mod's arithmetic on what a client sent reached 2^30, where a box's
	// "y <= y1" loop never ended and wrote past its buffer, and past 2^21
	// a section's 16-bit index wraps ([SECURITY_RUN_1], util/fuzz).
	static const int32_t COORD_LIMIT = 2000000;
	static bool coord_ok(int32_t v)
	{
		return v >= -COORD_LIMIT && v <= COORD_LIMIT;
	}
	// A box: a node's 16^3 block or a mod's area round one, so a little
	// past COORD_LIMIT
	static bool box_ok(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1)
	{
		const int32_t L = COORD_LIMIT + 64;
		for(int32_t v : {x0, y0, z0, x1, y1, z1})
			if(v < -L || v > L)
				return false;
		return true;
	}

	// A box of voxel words in one access(), x fastest and then y and then z.
	//
	// This is what the region reads are for. Written a voxel at a time in
	// Lua they took one access_module() each -- a module lock acquired and
	// the lock hierarchy validated per voxel, 125 of them for a 5x5x5 box --
	// and the work inside voxelworld was nearly free by comparison, since
	// the commit on the way out early-outs with nothing dirty.
	void read_region(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1, sv_<uint32_t> &out)
	{
		// See box_ok(): every caller bounds its box first
		if(!box_ok(x0, y0, z0, x1, y1, z1) || x1 < x0 || y1 < y0 || z1 < z0){
			out.clear();
			return;
		}
		// What core.set_node has written and not yet flushed is part of the
		// map as far as a mod is concerned -- Luanti's semantics are that a
		// write is visible immediately. A small box has the buffer laid
		// over it, a lookup per voxel: a mod that alternates a
		// find_nodes_in_area of a few voxels with set_nodes (VoxeLibre's
		// geodes, per calcite node) paid a commit with the skylight per
		// read when every read flushed. A big box -- a section's
		// VoxelManip, a find over a chunk -- flushes first as before:
		// walking a buffer of tens of thousands per read, a hundred reads
		// a section, cost VoxeLibre's world generation a third.
		const size_t volume = (size_t)(x1 - x0 + 1) * (size_t)(y1 - y0 + 1) *
				(size_t)(z1 - z0 + 1);
		// A box in a body's region ([BODY_INTERACT]) is read voxel by
		// voxel off the body's owner; the map has nothing there. A box
		// across the line reads as ignore above it.
		if(y0 >= REGION_Y){
			out.assign(volume, 0);
			if(!m_region_map)
				return;
			size_t i = 0;
			for(int32_t z = z0; z <= z1; z++)
			for(int32_t y = y0; y <= y1; y++)
			for(int32_t x = x0; x <= x1; x++, i++){
				uint32_t word = 0;
				if(m_region_map->get(x, y, z, word))
					out[i] = word;
			}
			return;
		}
		if(volume > 4096)
			flush_node_writes();
		read_region_uncached(x0, y0, z0, x1, y1, z1, out);
		if(m_node_writes.empty())
			return;
		size_t i = 0;
		for(int32_t z = z0; z <= z1; z++)
		for(int32_t y = y0; y <= y1; y++)
		for(int32_t x = x0; x <= x1; x++, i++){
			auto it = m_node_writes.find(pos_key(x, y, z));
			if(it != m_node_writes.end())
				out[i] = it->second.word;
		}
	}

	void read_region_uncached(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1, sv_<uint32_t> &out)
	{
		// The callers bound it (box_ok() at the Lua entries, read_node()
		// for its block); a box past it here is a caller's bug, and an
		// empty answer is what a short read gets
		if(!box_ok(x0, y0, z0, x1, y1, z1) || x1 < x0 || y1 < y0 || z1 < z0){
			out.clear();
			return;
		}
		size_t w = (size_t)(x1 - x0 + 1);
		size_t h = (size_t)(y1 - y0 + 1);
		size_t d = (size_t)(z1 - z0 + 1);
		out.assign(w * h * d, 0);
		if(!m_scene)
			return;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			// One read for the box rather than one per voxel: what asks for
			// this is a sweep -- an ABM, a find_nodes_in_area -- and the
			// difference is a clip per chunk against a section and buffer
			// lookup per voxel
			interface::VoxelVolume vol = world->get_volume(pv::Region(
					pv::Vector3DInt32(x0, y0, z0),
					pv::Vector3DInt32(x1, y1, z1)));
			// A row at a time: the answer is an array of words and a row
			// of the volume is a run of them, so the only per-voxel work
			// left is the assembly out of the bytes. A sampler per voxel
			// was the top of a devtest profile with this underneath it.
			interface::VoxelVolume::Sampler src(&vol);
			size_t i = 0;
			for(int32_t z = z0; z <= z1; z++){
				for(int32_t y = y0; y <= y1; y++){
					if(vol.read_words(x0, y, z, w, &out[i])){
						i += w;
						continue;
					}
					src.setPosition(x0, y, z);
					for(int32_t x = x0; x <= x1; x++, src.movePositiveX()){
						out[i++] = src.getVoxel().data;
					}
				}
			}
		});
		// What has been written and not flushed is not in voxelworld yet, so
		// it goes over the top -- the same order read_node() reads in. The
		// buffer is emptied every Luanti step, so sweeping it is cheaper
		// than a lookup per voxel of the box.
		for(const auto &pair : m_node_writes){
			const PendingNode &n = pair.second;
			if(n.x < x0 || n.x > x1 || n.y < y0 || n.y > y1 ||
					n.z < z0 || n.z > z1)
				continue;
			out[(size_t)(n.x - x0) + (size_t)(n.y - y0) * w +
					(size_t)(n.z - z0) * w * h] = n.word;
		}
	}
};

}
// vim: set noet ts=4 sw=4:
