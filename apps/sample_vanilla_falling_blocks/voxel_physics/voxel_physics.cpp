// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// vanilla with voxel physics ([VOXEL_PHYSICS_SAMPLE]): what this game adds
// to apps/vanilla, which it is a variant of ([GAME_BASE]). A sample, not a
// serious game.
//
// The simulation is demo_undermine's (apps/demo_undermine/main/main.cpp): a support
// number per voxel -- how far it is from something holding it up, reaching
// sideways as far as its material spans -- and a load, the column above
// it against what it carries; both recomputed around a change and nowhere
// else, so generated matter is judged as it is when a player first digs
// into it. What demo_undermine reads from its material table is read here out
// of the game's node definitions by heuristics over their groups, and
// what fails does not fall voxel by voxel: the unsupported, connected
// portion comes off the world as one body with a rigid body, and falls
// under the scene's physics (apps/sample_falling_blocks's pieces). Where it goes
// when it lands is decided after the playtest: it lies where it stops.
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include "luanti/api.h"
#include "voxelworld/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include <cereal/archives/portable_binary.hpp>
#include <Scene.h>
#include <Node.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <deque>
#include <unordered_map>
#include <unordered_set>
#include <map>
#include <set>
#include <sstream>
#include <chrono>
#include <cmath>
#define MODULE "voxel_physics"

namespace pv = PolyVox;
using interface::Event;
using interface::VoxelInstance;
using interface::VoxelSample;
using main_context::SceneReference;

#include "interface/polyvox_std.h"

#include "interface/polyvox_cereal.h"

namespace voxel_physics {

using namespace Urho3D;

// The state plane: the low nibble how far from support (0 for nothing),
// the high nibble how loaded, 0...15 of what it carries
static const char *STATE_PLANE = "voxel_physics:state";
static const uint8_t SUPPORT_MAX = 15;
static const uint8_t BAND_MAX = 15;
static const uint8_t LOAD_MAX = 255;
// How far up a voxel is asked to carry; demo_undermine's LOAD_DEPTH and its
// simplification: the column immediately above and no further
static const int LOAD_DEPTH = 32;
// Everything at or under this is supported: VoxeLibre's overworld floor is
// -62 with bedrock to -58, and nothing a player undermines is deeper
// (decided, 2026-09-22)
static const int SUPPORTED_BELOW_Y = -60;
static const size_t SIM_PER_TICK = 2048;
// And how long one tick's relaxation may hold voxelworld; everything else
// in the server waits behind that lock
static const int64_t SIM_BUDGET_US = 20000;
// The most voxels one body takes with it; what is left over is looked at
// again on the next tick
static const size_t BODY_MAX_VOXELS = 4096;
static const uint16_t CONTENT_AIR = 2;
// A body's volume has this much air around its voxels, so a node can be
// placed on a body ([BODY_INTERACT]): a write into the margin is a body
// voxel like any other. A body's local origin is its lowest voxel less
// the margin; simplified: a place past the margin is dropped.
static const int BODY_MARGIN = 4;

// What the heuristics decided about a node; see the Lua below
struct Props
{
	bool structural = false;
	bool diggable = false;
	uint8_t span = 0;
	uint8_t density = 0;
	uint8_t capacity = 0;
};

// The heuristics, over the game's own definitions: which group a node
// digs as says roughly what it is made of. cracky is rock, choppy timber,
// crumbly dirt or sand (sand and gravel span nothing), snappy and leaves
// hang and weigh nothing, unbreakable is the bedrock role; what walks
// through -- air, liquids, plants -- takes no part. VoxeLibre digs by
// tool instead of by material -- pickaxey, shovely, axey -- and those
// read the same way. simplified: the per-game override table the plan
// names is not here yet.
static const char *PROPS_LUA = R"LUA(
function core.__voxel_physics_props()
	local out = {}
	for name, def in pairs(core.registered_nodes) do
		local g = def.groups or {}
		local rec = nil
		if def.walkable == false or def.drawtype == "airlike" or
				(def.liquidtype ~= nil and def.liquidtype ~= "none") then
			rec = nil
		elseif g.unbreakable or name:find("bedrock", 1, true) then
			rec = {0, 15, 0, 255}
		elseif g.snappy or g.leaves or g.leafdecay then
			rec = {1, 2, 0, 10}
		elseif g.cracky or g.pickaxey then
			rec = {1, 6, 3, 200}
		elseif g.choppy or g.axey then
			rec = {1, 8, 1, 30}
		elseif g.crumbly or g.shovely then
			if g.falling_node or name:find("sand", 1, true) or
					name:find("gravel", 1, true) then
				rec = {1, 0, 2, 40}
			else
				rec = {1, 2, 2, 60}
			end
		else
			rec = {1, 3, 3, 150}
		end
		if rec then
			out[#out + 1] = table.concat({core.get_content_id(name), rec[1],
					rec[2], rec[3], rec[4], name}, "\t")
		end
	end
	return out
end

-- A player's dig and place, told to the C++ ([LUANTI_APP_GLUE]'s bridge):
-- the voxels that wake the sim. A mod's own (a mushroom popping) do not:
-- they made hundreds of bodies out of what the world generated.
local function changed(pos, by)
	if by and by:is_player() then
		core.buildat_emit("voxel_physics_changed", {pos.x, pos.y, pos.z})
	end
end
core.register_on_dignode(function(pos, _, digger)
	changed(pos, digger)
end)
core.register_on_placenode(function(pos, _, placer, _, _, pointed)
	changed(pos, placer)
	if pointed and pointed.under then
		changed(pointed.under, placer)
	end
end)
)LUA";

struct Module: public interface::Module
{
	interface::Server *m_server;
	SceneReference m_scene = nullptr;
	int m_state_plane = -1;
	pv::Vector3DInt16 m_chunk_size = pv::Vector3DInt16(16, 16, 16);
	std::vector<Props> m_props; // By content id

	// The relaxation's queue and its scratch, as demo_undermine's
	std::deque<pv::Vector3DInt32> m_dirty;
	std::unordered_set<int64_t> m_dirty_set;
	struct Pending { pv::Vector3DInt32 p; VoxelSample v; };
	std::unordered_map<int64_t, Pending> m_scratch;
	std::vector<pv::Vector3DInt32> m_failing;
	std::unordered_set<int64_t> m_failing_set;
	size_t m_bodies = 0;
	sv_<uint> m_body_nodes;
	int m_ticks = 0;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		luanti::access(m_server, [&](luanti::Interface *i){
			i->set_region_map(nullptr);
		});
	}

	void init()
	{
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("luanti:app:voxel_physics_changed"));
		m_server->sub_event(this, Event::t("voxelworld:node_volume_updated"));
		m_regions.m = this;
		luanti::access(m_server, [&](luanti::Interface *i){
			i->set_region_map(&m_regions);
		});
		// Before the game runs: the luanti module keeps the chunk until
		// then and runs it with the builtin, so the function is there when
		// the game has loaded
		luanti::access(m_server, [&](luanti::Interface *i){
			i->load_lua(PROPS_LUA, "voxel_physics");
			// The bodies land on the terrain's server-side shapes; see
			// [VOXEL_PHYSICS_PERF] for what that costs
			i->set_server_physics(true);
		});
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("luanti:app:voxel_physics_changed", on_changed,
				luanti::AppEvent)
		EVENT_TYPEN("voxelworld:node_volume_updated", on_node_volume_updated,
				voxelworld::NodeVolumeUpdated)
	}

	// The world exists and the luanti module has set its format: the
	// state plane goes on beside it, and every chunk takes it on the
	// first time the sim writes into it
	void on_game_loaded(const luanti::GameLoaded &event)
	{
		m_scene = event.scene;
		voxelworld::access(m_server, m_scene,
				[&](voxelworld::Instance *world){
			m_state_plane = world->get_voxel_reg()->add_plane(STATE_PLANE, 8);
			m_chunk_size = world->get_chunk_size_voxels();
			log_i(MODULE, "%s is plane %i: %s", STATE_PLANE, m_state_plane,
					cs(world->get_voxel_reg()->get_format().dump()));
		});
		sv_<ss_> flat;
		luanti::access(m_server, [&](luanti::Interface *i){
			flat = i->call_string_list("__voxel_physics_props");
		});
		size_t structural = 0;
		for(const ss_ &line : flat){
			std::istringstream is(line);
			int id = 0, s = 0, span = 0, density = 0, capacity = 0;
			is >> id >> s >> span >> density >> capacity;
			if(id < 0 || id > 65535)
				continue;
			if(m_props.size() <= (size_t)id)
				m_props.resize(id + 1);
			Props &p = m_props[id];
			p.structural = true;
			p.diggable = s != 0;
			p.span = (uint8_t)span;
			p.density = (uint8_t)density;
			p.capacity = (uint8_t)capacity;
			structural++;
		}
		log_i(MODULE, "%zu node types take part in the physics", structural);
	}

	// The player's changes are what wake the sim (on_dignode and
	// on_placenode, through the bridge). Kept until the chunk they are in
	// is committed: the commit is the change having happened
	sv_<pv::Vector3DInt32> m_pending;

	void on_node_volume_updated(const voxelworld::NodeVolumeUpdated &event)
	{
		if(!event.is_static_chunk || m_pending.empty() || m_scene == nullptr)
			return;
		const pv::Vector3DInt16 &cs = m_chunk_size;
		sv_<pv::Vector3DInt32> left;
		for(const pv::Vector3DInt32 &p : m_pending){
			pv::Vector3DInt32 c(
					(int)std::floor((float)p.getX() / cs.getX()),
					(int)std::floor((float)p.getY() / cs.getY()),
					(int)std::floor((float)p.getZ() / cs.getZ()));
			if(c == event.chunk_p)
				mark_changed(p);
			else
				left.push_back(p);
		}
		m_pending.swap(left);
	}

	void on_changed(const luanti::AppEvent &event)
	{
		int x = 0, y = 0, z = 0;
		if(sscanf(event.json.c_str(), "[%d,%d,%d]", &x, &y, &z) == 3)
			m_pending.push_back(pv::Vector3DInt32(x, y, z));
	}

	// The simulation
	// --------------

	static int64_t pos_key(const pv::Vector3DInt32 &p)
	{
		return ((int64_t)(p.getX() & 0xfffff) << 40) |
				((int64_t)(p.getY() & 0xfffff) << 20) |
				(int64_t)(p.getZ() & 0xfffff);
	}

	const Props& props_of(uint32_t id)
	{
		static const Props none;
		return id < m_props.size() ? m_props[id] : none;
	}

	uint32_t id_of(voxelworld::Instance *world, const VoxelSample &v)
	{
		return world->get_voxel_reg()->get_format().id_of(v.planes[0]);
	}
	uint8_t support_of(const VoxelSample &v)
	{
		return v.planes[m_state_plane] & 0xf;
	}
	uint8_t band_of(const VoxelSample &v)
	{
		return (v.planes[m_state_plane] >> 4) & 0xf;
	}
	void set_state(VoxelSample &v, uint8_t support, uint8_t band)
	{
		v.planes[m_state_plane] = (uint32_t)(support & 0xf) |
				((uint32_t)(band & 0xf) << 4);
	}
	static uint8_t load_band(uint32_t load, uint8_t capacity)
	{
		if(capacity == 0)
			return 0;
		uint32_t band = load * (BAND_MAX + 1) / ((uint32_t)capacity + 1);
		return (uint8_t)(band > BAND_MAX ? BAND_MAX : band);
	}

	void mark_dirty(const pv::Vector3DInt32 &p)
	{
		if(m_dirty_set.insert(pos_key(p)).second)
			m_dirty.push_back(p);
	}

	// What has to be looked at again after the voxel at p changed: itself,
	// the six around it, and the LOAD_DEPTH voxels under it
	void mark_changed(const pv::Vector3DInt32 &p)
	{
		static const int OFF[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
		};
		mark_dirty(p);
		for(size_t k = 0; k < 6; k++)
			mark_dirty(pv::Vector3DInt32(p.getX() + OFF[k][0],
					p.getY() + OFF[k][1], p.getZ() + OFF[k][2]));
		for(int i = 1; i <= LOAD_DEPTH; i++)
			mark_dirty(pv::Vector3DInt32(p.getX(), p.getY() - i, p.getZ()));
	}

	void mark_failing(const pv::Vector3DInt32 &p)
	{
		if(m_failing_set.insert(pos_key(p)).second)
			m_failing.push_back(p);
	}

	VoxelSample peek(voxelworld::Instance *world, const pv::Vector3DInt32 &p)
	{
		auto it = m_scratch.find(pos_key(p));
		if(it != m_scratch.end())
			return it->second.v;
		return world->get_sample(p, true);
	}

	// How far the voxel at p is from something holding it up, 0 for
	// nothing. Standing on something supported is supported; otherwise it
	// reaches sideways from its neighbours, one step less per voxel and
	// never past its span. The edge of what is loaded, and everything
	// under SUPPORTED_BELOW_Y, holds.
	uint8_t compute_support(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p, const Props &m)
	{
		if(!m.diggable || p.getY() <= SUPPORTED_BELOW_Y)
			return SUPPORT_MAX;
		VoxelSample below = peek(world,
				pv::Vector3DInt32(p.getX(), p.getY() - 1, p.getZ()));
		uint32_t bid = id_of(world, below);
		if(bid == interface::VOXELTYPEID_UNDEFINED)
			return SUPPORT_MAX;
		const Props &bm = props_of(bid);
		if(bm.structural && (support_of(below) > 0 || !bm.diggable))
			return SUPPORT_MAX;
		// Generated matter carries no state until the sim has been by:
		// a neighbour nothing has judged reads as held up, so the front
		// spreads through what the change touched and stops at what it
		// did not (the sim wakes only around a change)
		if(bm.structural && !judged(below))
			return SUPPORT_MAX;
		if(m.span == 0)
			return 0;
		static const int SIDE[4][2] = {{1,0}, {-1,0}, {0,1}, {0,-1}};
		uint8_t best = 0;
		for(size_t k = 0; k < 4; k++){
			VoxelSample n = peek(world, pv::Vector3DInt32(
					p.getX() + SIDE[k][0], p.getY(), p.getZ() + SIDE[k][1]));
			uint32_t nid = id_of(world, n);
			if(nid == interface::VOXELTYPEID_UNDEFINED)
				return SUPPORT_MAX;
			const Props &nm = props_of(nid);
			if(!nm.structural)
				continue;
			uint8_t s = judged(n) ? support_of(n) : SUPPORT_MAX;
			if(s > best)
				best = s;
		}
		if(best == 0)
			return 0;
		uint8_t reach = best - 1;
		return reach < m.span ? reach : m.span;
	}

	// Whether the sim has written this voxel's state: a state of 0 is what
	// a voxel nothing wrote reads as, and it is never what the sim writes
	// for a structural voxel (a judged voxel with no support is failing,
	// and is marked with the band nibble's top bit)
	bool judged(const VoxelSample &v)
	{
		return v.planes[m_state_plane] != 0;
	}

	uint8_t compute_load(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p)
	{
		int carried = 0;
		for(int i = 1; i <= LOAD_DEPTH; i++){
			VoxelSample v = peek(world,
					pv::Vector3DInt32(p.getX(), p.getY() + i, p.getZ()));
			const Props &m = props_of(id_of(world, v));
			if(!m.structural)
				break;
			carried += m.density;
			if(carried >= LOAD_MAX)
				return LOAD_MAX;
		}
		return (uint8_t)carried;
	}

	void update_voxel(voxelworld::Instance *world, const pv::Vector3DInt32 &p)
	{
		VoxelSample v = peek(world, p);
		uint32_t id = id_of(world, v);
		if(id == interface::VOXELTYPEID_UNDEFINED)
			return;
		const Props &m = props_of(id);
		if(!m.structural)
			return;
		uint8_t support = compute_support(world, p, m);
		uint8_t load = compute_load(world, p);
		uint8_t band = load_band(load, m.capacity);
		bool fails = m.diggable && (support == 0 || load > m.capacity);
		// The band's top bit says "judged and failing", so a state is
		// never 0 once written; see judged()
		if(fails)
			band |= 8;
		// A voxel judged for the first time was read as fully supported
		// by whatever asked about it (see compute_support), so it moved
		// only when it is not: judging supported rock does not spread
		bool support_moved = judged(v) ? support != support_of(v) :
				support != SUPPORT_MAX;
		if(support_moved || band != band_of(v)){
			VoxelSample nv = v;
			set_state(nv, support, band);
			m_scratch[pos_key(p)] = Pending{p, nv};
		}
		if(support_moved){
			static const int OFF[6][3] = {
				{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
			};
			for(size_t k = 0; k < 6; k++)
				mark_dirty(pv::Vector3DInt32(p.getX() + OFF[k][0],
						p.getY() + OFF[k][1], p.getZ() + OFF[k][2]));
		}
		if(fails){
			log_v(MODULE, "fails: " PV3I_FORMAT " id=%u support=%i load=%i",
					PV3I_PARAMS(p), id, (int)support, (int)load);
			mark_failing(p);
		}
	}

	void flush_scratch(voxelworld::Instance *world)
	{
		for(auto &e : m_scratch)
			world->set_sample(e.second.p, e.second.v, true);
		m_scratch.clear();
	}

	// Bodies
	// ------

	// What comes off with a failing voxel: everything structural and
	// diggable connected to it that is failing or holds no support of its
	// own, and whatever stands directly on those -- a column standing on
	// what falls falls with it, whether or not the relaxation has got to
	// it yet
	void collect_body(voxelworld::Instance *world, const pv::Vector3DInt32 &start,
			std::vector<pv::Vector3DInt32> &out)
	{
		static const int OFF[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
		};
		std::unordered_set<int64_t> seen;
		std::deque<pv::Vector3DInt32> queue;
		queue.push_back(start);
		seen.insert(pos_key(start));
		while(!queue.empty() && out.size() < BODY_MAX_VOXELS){
			pv::Vector3DInt32 p = queue.front();
			queue.pop_front();
			out.push_back(p);
			for(size_t k = 0; k < 6; k++){
				pv::Vector3DInt32 n(p.getX() + OFF[k][0], p.getY() + OFF[k][1],
						p.getZ() + OFF[k][2]);
				if(!seen.insert(pos_key(n)).second)
					continue;
				VoxelSample v = world->get_sample(n, true);
				const Props &m = props_of(id_of(world, v));
				if(!m.structural || !m.diggable)
					continue;
				bool above = OFF[k][1] == 1;
				bool loose = judged(v) && (support_of(v) == 0 || (band_of(v) & 8));
				if(loose || above)
					queue.push_back(n);
			}
		}
	}

	// The body cut out of the world: the voxels into a volume of the
	// world's format with a one-voxel border (the mesher wants one), air
	// where they were, and a node at the volume's corner with a rigid
	// body and a box per voxel. The client half meshes the volume.
	void make_body(voxelworld::Instance *world,
			const std::vector<pv::Vector3DInt32> &voxels)
	{
		pv::Vector3DInt32 lo = voxels[0], hi = voxels[0];
		for(const pv::Vector3DInt32 &p : voxels){
			lo = pv::Vector3DInt32(std::min(lo.getX(), p.getX()),
					std::min(lo.getY(), p.getY()), std::min(lo.getZ(), p.getZ()));
			hi = pv::Vector3DInt32(std::max(hi.getX(), p.getX()),
					std::max(hi.getY(), p.getY()), std::max(hi.getZ(), p.getZ()));
		}
		lo = lo - pv::Vector3DInt32(BODY_MARGIN, BODY_MARGIN, BODY_MARGIN);
		hi = hi + pv::Vector3DInt32(BODY_MARGIN, BODY_MARGIN, BODY_MARGIN);
		pv::Vector3DInt32 size = hi - lo + pv::Vector3DInt32(1, 1, 1);
		sp_<interface::VoxelVolume> volume(new interface::VoxelVolume(
				pv::Region(pv::Vector3DInt32(-1, -1, -1), size),
				world->get_voxel_reg()->get_format().planes));
		m_format = world->get_voxel_reg()->get_format();
		float mass = 0;
		for(const pv::Vector3DInt32 &p : voxels){
			VoxelSample v = world->get_sample(p, true);
			set_state(v, SUPPORT_MAX, 0);
			volume->set_sample_at(p.getX() - lo.getX(), p.getY() - lo.getY(),
					p.getZ() - lo.getZ(), v);
			mass += props_of(id_of(world, v)).density;
			world->set_voxel(p, VoxelInstance(CONTENT_AIR), true);
			mark_changed(p);
		}
		fill_margin_with_air(*volume, size);
		ss_ data = interface::serialize_volume_compressed(*volume);
		m_bodies++;
		log_i(MODULE, "body %zu: %zu voxels from " PV3I_FORMAT " to "
				PV3I_FORMAT ", mass %.0f", m_bodies, voxels.size(),
				PV3I_PARAMS(lo), PV3I_PARAMS(hi), mass);
		// The node a few ticks later: the terrain's collision shapes are
		// rebuilt after the chunk's commit, and a body made on the same
		// tick sat in the roof's old boxes and never moved (2026-09-22)
		QueuedBody q;
		q.ticks = 3; q.lo = lo; q.size = size; q.data = data; q.mass = mass;
		q.voxels = voxels; q.volume = volume;
		m_queued_bodies.push_back(q);
	}

	// A body that came off the world, and where its voxels live for the
	// game's Lua ([BODY_INTERACT]): region k is the box from
	// (0, REGION_Y + k * REGION_STRIDE, 0), a body voxel's position is
	// base + local, and the luanti module's get_node()/set_node() there
	// come to get()/set() below. The volume is the one the node's
	// voxel_body_data was made from, with its one-voxel border, so local
	// (0, 0, 0) is the body's first voxel.
	struct Body
	{
		int k = 0;
		uint node_id = 0;
		pv::Vector3DInt32 size;
		up_<interface::VoxelVolume> volume;
	};
	std::map<int, Body> m_body_by_k;
	int m_next_k = 0;

	Body* body_at(int32_t x, int32_t y, int32_t z, pv::Vector3DInt32 *local)
	{
		if(y < luanti::REGION_Y)
			return nullptr;
		int k = (y - luanti::REGION_Y) / luanti::REGION_STRIDE;
		auto it = m_body_by_k.find(k);
		if(it == m_body_by_k.end())
			return nullptr;
		Body &b = it->second;
		pv::Vector3DInt32 l(x, y - luanti::REGION_Y - k * luanti::REGION_STRIDE, z);
		if(l.getX() < 0 || l.getY() < 0 || l.getZ() < 0 ||
				l.getX() >= b.size.getX() || l.getY() >= b.size.getY() ||
				l.getZ() >= b.size.getZ())
			return nullptr;
		*local = l;
		return &b;
	}

	struct Regions: public luanti::RegionMap
	{
		Module *m;
		bool get(int32_t x, int32_t y, int32_t z, uint32_t &word)
		{
			pv::Vector3DInt32 l;
			Body *b = m->body_at(x, y, z, &l);
			if(!b)
				return false;
			word = b->volume->sample_at(l).planes[0];
			return true;
		}
		bool set(int32_t x, int32_t y, int32_t z, uint32_t word)
		{
			pv::Vector3DInt32 l;
			Body *b = m->body_at(x, y, z, &l);
			if(!b)
				return false;
			VoxelSample v = b->volume->sample_at(l);
			v.planes[0] = word;
			b->volume->set_sample_at(l.getX(), l.getY(), l.getZ(), v);
			// Rebuilt on the tick, once for every write of the tick: a
			// VoxelManip over a body is a write per voxel
			m->m_dirty_bodies.insert(b->k);
			return true;
		}
		bool to_world(float x, float y, float z, float &wx, float &wy, float &wz)
		{
			pv::Vector3DInt32 l;
			Body *b = m->body_at((int32_t)std::floor(x), (int32_t)std::floor(y),
					(int32_t)std::floor(z), &l);
			if(!b)
				return false;
			// The fraction kept: a drop at the voxel's centre stays there
			float base_y = (float)(luanti::REGION_Y + b->k * luanti::REGION_STRIDE);
			Vector3 local(x, y - base_y, z);
			bool ok = false;
			main_context::access(m->m_server, [&](main_context::Interface *imc){
				Scene *scene = imc->check_scene(m->m_scene);
				Node *n = scene->GetNode(b->node_id);
				if(!n)
					return;
				Vector3 w = n->GetWorldTransform() * local;
				wx = w.x_; wy = w.y_; wz = w.z_;
				ok = true;
			});
			return ok;
		}
	} m_regions;

	// The margin around a body's voxels is air, not ignore: a mod placing
	// on a body asks get_node_or_nil() about the place first, and ignore
	// there is "unloaded"
	void fill_margin_with_air(interface::VoxelVolume &volume,
			const pv::Vector3DInt32 &size)
	{
		const interface::VoxelFormat &f = voxel_format();
		uint32_t air = 0;
		f.id.set(air, CONTENT_AIR);
		for(int z = 0; z < size.getZ(); z++)
		for(int y = 0; y < size.getY(); y++)
		for(int x = 0; x < size.getX(); x++){
			VoxelSample v = volume.sample_at(x, y, z);
			if(f.id_of(v.planes[0]) == interface::VOXELTYPEID_UNDEFINED){
				v.planes[0] = air;
				volume.set_sample_at(x, y, z, v);
			}
		}
	}

	// The node's mesh data and its shapes after a voxel of the body
	// changed: the pieces it is in now (split_body takes every one but
	// the largest into a body of its own), the whole volume again, and
	// a box per voxel left. A body with nothing left goes.
	//
	// The support relaxation is the world's and does not run inside a
	// body: a body is held together by being connected, not by standing
	// on anything, so what the sim would say of a voxel in free fall is
	// what the connectivity above already says. A node placed on a body
	// stays on it.
	void rebuild_body(Body &b)
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene);
			Node *n = scene->GetNode(b.node_id);
			if(!n)
				return;
			split_body(b, n);
			ss_ data = interface::serialize_volume_compressed(*b.volume);
			n->SetVar(StringHash("voxel_body_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)data.c_str(),
					data.size())));
			PODVector<CollisionShape*> shapes;
			n->GetComponents<CollisionShape>(shapes);
			for(CollisionShape *s : shapes)
				s->Remove();
			size_t left = 0;
			float mass = 0;
			const interface::VoxelFormat &f = voxel_format();
			for(int z = 0; z < b.size.getZ(); z++)
			for(int y = 0; y < b.size.getY(); y++)
			for(int x = 0; x < b.size.getX(); x++){
				uint32_t id = f.id_of(b.volume->sample_at(x, y, z).planes[0]);
				if(!props_of(id).structural)
					continue;
				CollisionShape *shape = n->CreateComponent<CollisionShape>(LOCAL);
				shape->SetBox(Vector3::ONE, Vector3(x + 0.5f, y + 0.5f, z + 0.5f));
				left++;
				mass += props_of(id).density;
			}
			RigidBody *body = n->GetComponent<RigidBody>();
			if(left == 0){
				log_i(MODULE, "body %d: nothing left; gone", b.k);
				n->Remove();
				m_body_by_k.erase(b.k);
				return;
			}
			if(body)
				body->SetMass(mass > 0 ? mass : 1.0f);
			log_v(MODULE, "body %d rebuilt: %zu voxels", b.k, left);
		});
		// The clients mesh it again: the var replicates on the next
		// network frame, and the packet says which node to look at. Sent
		// from the tick: this runs under the dig's own packet handler,
		// where the network module is not to be entered again.
		m_changed_bodies.push_back(b.node_id);
	}
	sv_<uint> m_changed_bodies;
	std::set<int> m_dirty_bodies;

	void rebuild_dirty_bodies()
	{
		std::set<int> dirty;
		dirty.swap(m_dirty_bodies);
		for(int k : dirty){
			auto it = m_body_by_k.find(k);
			if(it != m_body_by_k.end())
				rebuild_body(it->second);
		}
	}

	void send_body_changes()
	{
		if(m_changed_bodies.empty())
			return;
		sv_<uint> ids;
		ids.swap(m_changed_bodies);
		network::access(m_server, [&](network::Interface *inetwork){
			for(uint id : ids){
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar((int32_t)id);
				}
				for(network::PeerInfo::Id peer : inetwork->list_peers())
					inetwork->send(peer, "luanti:body_changed", os.str());
			}
		});
	}

	interface::VoxelFormat m_format;
	const interface::VoxelFormat& voxel_format() { return m_format; }

	struct QueuedBody
	{
		int ticks;
		pv::Vector3DInt32 lo;
		pv::Vector3DInt32 size;
		ss_ data;
		float mass;
		std::vector<pv::Vector3DInt32> voxels;
		sp_<interface::VoxelVolume> volume;
		// A part cut off another body ([BODY_INTERACT]'s split): placed
		// where it was in that body's frame, moving as it moved, rather
		// than at lo
		bool placed = false;
		Vector3 position;
		Quaternion rotation;
		Vector3 velocity;
	};
	std::vector<QueuedBody> m_queued_bodies;

	void spawn_body(const QueuedBody &b)
	{
		const pv::Vector3DInt32 &lo = b.lo;
		const ss_ &data = b.data;
		float mass = b.mass;
		const std::vector<pv::Vector3DInt32> &voxels = b.voxels;
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene);
			Node *n = scene->CreateChild("VoxelBody");
			if(b.placed){
				n->SetPosition(b.position);
				n->SetRotation(b.rotation);
			} else
				n->SetPosition(Vector3(lo.getX() - 0.5f, lo.getY() - 0.5f,
						lo.getZ() - 0.5f));
			n->SetVar(StringHash("voxel_body_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)data.c_str(),
					data.size())));
			RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
			body->SetFriction(0.8f);
			body->SetMass(mass > 0 ? mass : 1.0f);
			if(b.placed)
				body->SetLinearVelocity(b.velocity);
			m_body_nodes.push_back(n->GetID());
			// Its region, for the game's Lua ([BODY_INTERACT])
			Body &rec = m_body_by_k[m_next_k];
			rec.k = m_next_k++;
			rec.node_id = n->GetID();
			rec.size = b.size;
			rec.volume.reset(new interface::VoxelVolume(*b.volume));
			n->SetVar(StringHash("voxel_body_region"), Variant((int)rec.k));
			log_i(MODULE, "body node %u is region %d: its voxels at "
					"(0..%d, %d..%d, 0..%d)", n->GetID(), rec.k,
					b.size.getX() - 1, luanti::REGION_Y + rec.k * luanti::REGION_STRIDE,
					luanti::REGION_Y + rec.k * luanti::REGION_STRIDE + b.size.getY() - 1,
					b.size.getZ() - 1);
			for(const pv::Vector3DInt32 &p : voxels){
				CollisionShape *shape = n->CreateComponent<CollisionShape>(LOCAL);
				shape->SetBox(Vector3::ONE, Vector3(
						p.getX() - lo.getX() + 0.5f, p.getY() - lo.getY() + 0.5f,
						p.getZ() - lo.getZ() + 0.5f));
			}
		});
	}

	// The connected pieces of a body's solid voxels, in its local grid:
	// what a body cut through is made of after the cut
	std::vector<std::vector<pv::Vector3DInt32>> body_pieces(const Body &b)
	{
		const interface::VoxelFormat &f = voxel_format();
		auto solid = [&](int x, int y, int z){
			if(x < 0 || y < 0 || z < 0 || x >= b.size.getX() ||
					y >= b.size.getY() || z >= b.size.getZ())
				return false;
			return props_of(f.id_of(b.volume->sample_at(x, y, z).planes[0])).structural;
		};
		std::vector<std::vector<pv::Vector3DInt32>> pieces;
		std::unordered_set<int64_t> seen;
		static const int OFF[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
		};
		for(int z = 0; z < b.size.getZ(); z++)
		for(int y = 0; y < b.size.getY(); y++)
		for(int x = 0; x < b.size.getX(); x++){
			pv::Vector3DInt32 start(x, y, z);
			if(!solid(x, y, z) || !seen.insert(pos_key(start)).second)
				continue;
			std::vector<pv::Vector3DInt32> piece;
			std::deque<pv::Vector3DInt32> queue;
			queue.push_back(start);
			while(!queue.empty()){
				pv::Vector3DInt32 p = queue.front();
				queue.pop_front();
				piece.push_back(p);
				for(size_t k = 0; k < 6; k++){
					pv::Vector3DInt32 n(p.getX() + OFF[k][0], p.getY() + OFF[k][1],
							p.getZ() + OFF[k][2]);
					if(solid(n.getX(), n.getY(), n.getZ()) &&
							seen.insert(pos_key(n)).second)
						queue.push_back(n);
				}
			}
			pieces.push_back(piece);
		}
		return pieces;
	}

	// A body cut in two is two bodies: every piece but the largest is
	// taken out of this body's volume into a body of its own, placed
	// where the piece was in this body's frame and moving as it moved.
	// Called under main_context with the body's node.
	void split_body(Body &b, Node *n)
	{
		std::vector<std::vector<pv::Vector3DInt32>> pieces = body_pieces(b);
		if(pieces.size() < 2)
			return;
		size_t largest = 0;
		for(size_t i = 1; i < pieces.size(); i++)
			if(pieces[i].size() > pieces[largest].size())
				largest = i;
		const interface::VoxelFormat &f = voxel_format();
		RigidBody *rb = n->GetComponent<RigidBody>();
		for(size_t i = 0; i < pieces.size(); i++){
			if(i == largest)
				continue;
			const std::vector<pv::Vector3DInt32> &piece = pieces[i];
			pv::Vector3DInt32 lo = piece[0], hi = piece[0];
			for(const pv::Vector3DInt32 &p : piece){
				lo = pv::Vector3DInt32(std::min(lo.getX(), p.getX()),
						std::min(lo.getY(), p.getY()), std::min(lo.getZ(), p.getZ()));
				hi = pv::Vector3DInt32(std::max(hi.getX(), p.getX()),
						std::max(hi.getY(), p.getY()), std::max(hi.getZ(), p.getZ()));
			}
			lo = lo - pv::Vector3DInt32(BODY_MARGIN, BODY_MARGIN, BODY_MARGIN);
			hi = hi + pv::Vector3DInt32(BODY_MARGIN, BODY_MARGIN, BODY_MARGIN);
			pv::Vector3DInt32 size = hi - lo + pv::Vector3DInt32(1, 1, 1);
			sp_<interface::VoxelVolume> volume(new interface::VoxelVolume(
					pv::Region(pv::Vector3DInt32(-1, -1, -1), size),
					f.planes));
			float mass = 0;
			std::vector<pv::Vector3DInt32> voxels;
			for(const pv::Vector3DInt32 &p : piece){
				VoxelSample v = b.volume->sample_at(p);
				volume->set_sample_at(p.getX() - lo.getX(), p.getY() - lo.getY(),
						p.getZ() - lo.getZ(), v);
				mass += props_of(f.id_of(v.planes[0])).density;
				// Out of this body: air where it was
				VoxelSample air = v;
				air.planes[0] = 0;
				f.id.set(air.planes[0], CONTENT_AIR);
				b.volume->set_sample_at(p.getX(), p.getY(), p.getZ(), air);
				voxels.push_back(p - lo);
			}
			fill_margin_with_air(*volume, size);
			QueuedBody q;
			q.ticks = 1; q.lo = pv::Vector3DInt32(0, 0, 0); q.size = size;
			q.data = interface::serialize_volume_compressed(*volume);
			q.mass = mass; q.voxels = voxels; q.volume = volume;
			q.placed = true;
			q.position = n->GetWorldTransform() * Vector3(
					(float)lo.getX(), (float)lo.getY(), (float)lo.getZ());
			q.rotation = n->GetWorldRotation();
			q.velocity = rb ? rb->GetLinearVelocity() : Vector3::ZERO;
			m_queued_bodies.push_back(q);
			log_i(MODULE, "body %d: a piece of %zu voxels comes off", b.k,
					piece.size());
		}
	}

	void step_failing(voxelworld::Instance *world)
	{
		std::vector<pv::Vector3DInt32> failing;
		failing.swap(m_failing);
		m_failing_set.clear();
		for(const pv::Vector3DInt32 &p : failing){
			VoxelSample v = world->get_sample(p, true);
			const Props &m = props_of(id_of(world, v));
			// Dug, held up again, or gone with an earlier body
			if(!m.structural || !m.diggable || !judged(v))
				continue;
			if(support_of(v) != 0 && compute_load(world, p) <= m.capacity)
				continue;
			std::vector<pv::Vector3DInt32> voxels;
			collect_body(world, p, voxels);
			make_body(world, voxels);
		}
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(m_scene == nullptr)
			return;
		rebuild_dirty_bodies();
		send_body_changes();
		for(size_t i = 0; i < m_queued_bodies.size();){
			if(--m_queued_bodies[i].ticks > 0){
				i++;
				continue;
			}
			spawn_body(m_queued_bodies[i]);
			m_queued_bodies.erase(m_queued_bodies.begin() + i);
		}
		// Where the bodies are, now and then: the reading a playtest wants
		if(++m_ticks % 100 == 0 && !m_body_nodes.empty()){
			main_context::access(m_server, [&](main_context::Interface *imc){
				Scene *scene = imc->check_scene(m_scene);
				for(uint id : m_body_nodes){
					Node *n = scene->GetNode(id);
					if(!n)
						continue;
					Vector3 p = n->GetPosition();
					log_i(MODULE, "body node %u at %.1f, %.1f, %.1f", id,
							p.x_, p.y_, p.z_);
				}
			});
		}
		if(m_dirty.empty() && m_failing.empty())
			return;
		auto t0 = std::chrono::steady_clock::now();
		size_t done = 0;
		int64_t loop_us = 0, flush_us = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			auto t_in = std::chrono::steady_clock::now();
			// The world is locked here and everything else waits behind it
			// -- the module's own relight read as a step of a second
			// ([MAPGEN_STEP]) -- so the relaxation runs to a deadline as
			// well as to a count, and what is left is the next tick's
			while(!m_dirty.empty() && done < SIM_PER_TICK){
				if((done & 15) == 15 && std::chrono::duration_cast<
						std::chrono::microseconds>(
						std::chrono::steady_clock::now() - t_in).count() >
						SIM_BUDGET_US)
					break;
				pv::Vector3DInt32 p = m_dirty.front();
				m_dirty.pop_front();
				m_dirty_set.erase(pos_key(p));
				update_voxel(world, p);
				done++;
			}
			loop_us = std::chrono::duration_cast<std::chrono::microseconds>(
					std::chrono::steady_clock::now() - t_in).count();
			flush_scratch(world);
			// Once the front has settled: a body is cut out of what the
			// whole relaxation says, not half of it
			if(m_dirty.empty())
				step_failing(world);
			flush_us = std::chrono::duration_cast<std::chrono::microseconds>(
					std::chrono::steady_clock::now() - t_in).count() - loop_us;
		});
		log_v(MODULE, "sim: %zu done in %i us (the relaxation %i, the flush "
				"and the bodies %i), %zu dirty, %zu failing, %zu bodies",
				done, (int)std::chrono::duration_cast<
				std::chrono::microseconds>(
				std::chrono::steady_clock::now() - t0).count(),
				(int)loop_us, (int)flush_us,
				m_dirty.size(), m_failing.size(), m_bodies);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_voxel_physics(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
