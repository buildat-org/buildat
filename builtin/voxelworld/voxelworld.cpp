// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "voxelworld/api.h"
#include "storage/api.h"
#include "network/api.h"
#include "client_file/api.h"
#include "replicate/api.h"
#include "main_context/api.h"
#include "core/log.h"
#include <chrono>
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/block.h"
#include "interface/voxel_volume.h"
#include "interface/voxel_cereal.h"
#include "interface/polyvox_numeric.h"
#include "interface/polyvox_cereal.h"
#include "interface/polyvox_std.h"
#include "interface/os.h"
#include "interface/fs.h"
#include "interface/server_config.h"
#include "interface/compress.h"
#include <cstring>
#include <set>
#include <PolyVoxCore/RawVolume.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <Node.h>
#include <Scene.h>
#include <Model.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <Context.h>
#include <ResourceCache.h>
#include <Light.h>
#include <Geometry.h>
#include <Zone.h>
#include <deque>
#include <mutex>
#include <map>
#include <algorithm>
#define MODULE "voxelworld"

// What a voxel type the game no longer registers is tinted with, so that a
// player or a developer sees it rather than finding out the hard way. It
// multiplies the vertex colour, which is light; see adopt_unknown_voxel().
static const uint32_t UNKNOWN_VOXEL_TINT = 0xff60ff;

using interface::Event;
namespace magic = Urho3D;
namespace pv = PolyVox;
using namespace Urho3D;
using interface::VoxelInstance;
using interface::VoxelVolume;
using interface::container_coord;
using interface::container_coord16;

namespace voxelworld {

struct ChunkBuffer
{
	pv::Vector3DInt32 chunk_p; // For logging
	up_<VoxelVolume> volume;
	bool dirty = false; // If false, buffer has only been read from so far
	int64_t last_accessed_us = 0;

	ChunkBuffer(){}
	void timer_reset(const pv::Vector3DInt32 &chunk_p_){
		chunk_p = chunk_p_;
		last_accessed_us = interface::os::time_us();
	}
	bool unload_if_old(int64_t timeout_us){ // True if not loaded
		if(!volume)
			return true;
		// A buffer that has changes in it has nowhere to put them: what
		// writes them out is commit(), which runs at the end of the access
		// that made them. Dropping it here would lose whatever was written
		// into it -- which is what happened to a caller that wrote more
		// buffers in one access() than the limit allows. It stays until it
		// is committed, and the limit is exceeded until then.
		if(dirty)
			return false;
		if(interface::os::time_us() < last_accessed_us + timeout_us)
			return false;
		log_t(MODULE, "Unloading chunk " PV3I_FORMAT, PV3I_PARAMS(chunk_p));
		volume.reset();
		dirty = false;
		return true;
	}
};

struct Section
{
	SceneReference m_scene_ref;
	pv::Vector3DInt16 section_p; // Position in sections
	pv::Vector3DInt16 chunk_size;
	pv::Region contained_chunks; // Position and size in chunks
	// Static voxel nodes (each contains one chunk); Initialized to 0.
	sp_<pv::RawVolume<uint32_t>> node_ids;
	size_t num_chunks = 0;
	// Cache these for speed
	int w_chunks = 0;
	int h_chunks = 0;
	int d_chunks = 0;

	// Chunk buffers (index using get_chunk_i())
	sv_<ChunkBuffer> chunk_buffers;

	// TODO: Specify what exactly do these mean and how they are used
	bool loaded = false;
	bool save_enabled = false;
	bool generated = false;
	// The generator's own merge has been over it. generated is set when
	// the generation is asked for; between the two, what stands in the
	// section was put there by a write (a game's set_node past the
	// generated world) and the generator's merge keeps it.
	bool arrived = false;
	// Asked for and not arrived yet: generated is true already, and what
	// is in the section is not the generator's. is_section_generated()
	// says no until the merge lands, and a save does not mark it generated
	// -- a section saved in between came back as terrain nobody made.
	bool awaiting = false;
	// Something has changed since this section was read from the save, or it
	// was never in one. A section is written only when this is set, which is
	// what keeps saving a world nobody is digging in free.
	bool modified = false;
	// [SAVE_LIMIT] The index row: changed by a player since the generator's
	// merge (set_cause()), the bytes last written, the day it was last
	// loaded for a player, and a row to write though nothing else changed
	bool altered = false;
	int64_t saved_bytes = 0;
	int32_t visited_day = -1;
	bool index_dirty = false;

	Section(): // Needed for containers
		chunk_size(0, 0, 0) // This is used to detect uninitialized instance
	{}
	Section(SceneReference scene_ref,
			pv::Vector3DInt16 section_p,
			pv::Vector3DInt16 chunk_size,
			pv::Region contained_chunks):
		m_scene_ref(scene_ref),
		section_p(section_p),
		chunk_size(chunk_size),
		contained_chunks(contained_chunks),
		node_ids(new pv::RawVolume<uint32_t>(contained_chunks)),
		num_chunks(contained_chunks.getWidthInVoxels() *
				contained_chunks.getHeightInVoxels() *
				contained_chunks.getDepthInVoxels())
	{
		chunk_buffers.resize(num_chunks);
		// Cache these for speed
		w_chunks = contained_chunks.getWidthInVoxels();
		h_chunks = contained_chunks.getHeightInVoxels();
		d_chunks = contained_chunks.getDepthInVoxels();
	}

	size_t get_chunk_i(const pv::Vector3DInt32 &chunk_p); // global chunk_p
	pv::Vector3DInt32 get_chunk_p(size_t chunk_p);

	ChunkBuffer& get_buffer(const pv::Vector3DInt32 &chunk_p,
			interface::Server *server, size_t *total_buffers_loaded);
};

size_t Section::get_chunk_i(const pv::Vector3DInt32 &chunk_p) // global chunk_p
{
	auto &lc = contained_chunks.getLowerCorner();
	// NOTE: pv::Vector3DInt32 operators and getters are too slow
	int local_x = chunk_p.getX() - lc.getX();
	int local_y = chunk_p.getY() - lc.getY();
	int local_z = chunk_p.getZ() - lc.getZ();
	const int &w = w_chunks;
	const int &h = h_chunks;
	size_t i = local_z * h * w + local_y * w + local_x;
	if(i >= num_chunks) // NOTE: This is not accurate but it is safe and fast
		throw Exception(ss_()+"get_chunk_i: Section "+cs(section_p)+
				" does not contain chunk"+cs(chunk_p));
	return i;
}

pv::Vector3DInt32 Section::get_chunk_p(size_t chunk_i)
{
	const int &w = w_chunks;
	const int &h = h_chunks;
	pv::Vector3DInt32 p;
	p.setZ(chunk_i / h / w);
	p.setY(chunk_i / w - p.getZ() * h);
	p.setX(chunk_i - p.getZ() * h * w - p.getY() * w);
	return contained_chunks.getLowerCorner() + p;
}

ChunkBuffer& Section::get_buffer(const pv::Vector3DInt32 &chunk_p,
		interface::Server *server, size_t *total_buffers_loaded)
{
	size_t chunk_i = get_chunk_i(chunk_p);
	ChunkBuffer &buf = chunk_buffers[chunk_i];
	buf.timer_reset(chunk_p);
	// If loaded, return right away
	if(buf.volume)
		return buf;
	// Not loaded.
	// Get the static voxel node from the scene and read the volume from it
	int32_t node_id = node_ids->getVoxelAt(chunk_p);
	if(node_id == 0){
		log_w(MODULE, "Section::get_buffer(): No node found for chunk "
				PV3I_FORMAT " in section " PV3I_FORMAT,
				PV3I_PARAMS(chunk_p), PV3I_PARAMS(section_p));
		return buf;
	}
	log_t(MODULE, "Loading chunk " PV3I_FORMAT " (node %i)",
			PV3I_PARAMS(chunk_p), node_id);

	main_context::access(server, [&](main_context::Interface *imc)
	{
		Scene *scene = imc->check_scene(m_scene_ref);
		Node *n = scene->GetNode(node_id);
		if(!n){
			log_w(MODULE,
					"Section::get_buffer(): Node %i not found in scene "
					"for chunk " PV3I_FORMAT " in section " PV3I_FORMAT,
					node_id, PV3I_PARAMS(chunk_p), PV3I_PARAMS(section_p));
			return;
		}
		const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
		const PODVector<unsigned char> &rawbuf = var.GetBuffer();
		ss_ data((const char*)&rawbuf[0], rawbuf.Size());
		buf.volume = interface::deserialize_volume(data);
		if(!buf.volume){
			log_w(MODULE,
					"Section::get_buffer(): Voxel volume could not be "
					"loaded from node %i for chunk "
					PV3I_FORMAT " in section " PV3I_FORMAT,
					node_id, PV3I_PARAMS(chunk_p), PV3I_PARAMS(section_p));
			return;
		}
	});
	(*total_buffers_loaded)++;
	return buf;
}

// See m_keep_loaded in CInstance: a run that never unloads anything, for the
// reference shots. A free function because the instance and the module both
// ask, and because it is read once per object rather than per step.
static bool keep_loaded_wanted()
{
	const char *v = getenv("BUILDAT_VOXELWORLD_KEEP_LOADED");
	return v != nullptr && v[0] != '\0' && ss_(v) != "0";
}

struct QueuedNodePhysicsUpdate
{
	uint node_id = 0;
	// TODO bool is_static_chunk = false;
	// TODO pv::Vector3DInt32 chunk_p; // Only set if is_static_chunk == true

	QueuedNodePhysicsUpdate(const uint &node_id):
		node_id(node_id){}
	bool operator>(const QueuedNodePhysicsUpdate &other) const {
		return node_id > other.node_id;
	}
};

// Skylight neighbour offsets. The last pair is +Y and -Y; LIGHT_DOWN is
// straight down, the one direction light falls through without losing any.
static const int LIGHT_OFF[6][3] = {
	{1,0,0}, {-1,0,0}, {0,0,1}, {0,0,-1}, {0,1,0}, {0,-1,0}
};
static const size_t LIGHT_DOWN = 5;

struct CInstance: public voxelworld::Instance
{
	interface::Server *m_server;

	SceneReference m_scene_ref;

	// Clients that are ready to receive things (by peer id)
	set_<int> m_clients_initialized;
	// [REGISTRY_FILE] Whether the registry's file has been served yet
	bool m_registry_served = false;

	// Accessing any of these outside of Server::access_scene is disallowed
	sp_<interface::AtlasRegistry> m_atlas_reg;
	sp_<interface::VoxelRegistry> m_voxel_reg;
	sp_<interface::BlockRegistry> m_block_reg;

	sv_<up_<CommitHook>> m_commit_hooks;

	// One node holds one chunk of voxels (eg. 24x24x24)
	pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(32, 32, 32);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(24, 24, 24);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(16, 16, 16);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(8, 8, 8);

	// The world is loaded and unloaded by sections (eg. 2x2x2)
	pv::Vector3DInt16 m_section_size_chunks = pv::Vector3DInt16(2, 2, 2);

	int64_t m_buffer_unload_timeout = 5000000;
	size_t m_max_buffers_loaded = 50;

	// **A run that never unloads anything**, for the reference shots:
	// BUILDAT_VOXELWORLD_KEEP_LOADED=1. The fixture forceloads the sections
	// it will photograph, which stops those being dropped as distant -- but
	// the buffers go anyway, on a five second timeout that does not ask
	// whether anything wants them, so a camera coming back to a viewpoint
	// still waits for them to be read and sent again. That wait is a hole in
	// the picture, and a hole does not look like a missing chunk: it looks
	// like a rendering fault.
	//
	// **It changes retention and nothing else.** What is ready changes; what
	// is drawn is still bounded by the client's far clip and its fog exactly
	// as before, so a picture taken with this on is comparable with one taken
	// without. A mode that quietly drew more would be worse than the missing
	// meshes. Memory is why it is not the default: a run of five viewpoints
	// is bounded, and a session that wandered would grow without limit, which
	// is what the timeout is for.
	// See [KEEP_LOADED] in doc/plan/rendering_plan.md.
	const bool m_keep_loaded = keep_loaded_wanted();

	// Sections (this(y,z)=sector, sector(x)=section)
	sm_<pv::Vector<2, int16_t>, sm_<int16_t, Section>> m_sections;
	// Cache of last used sections (add to end, remove from beginning)
	std::deque<Section*> m_last_used_sections;

	// Set of sections that have buffers allocated
	// (as a sorted array in descending order)
	std::vector<Section*> m_sections_with_loaded_buffers;
	size_t m_total_buffers_loaded = 0;
	size_t m_total_buffers_dirty = 0;

	// Set of nodes by node_id that need set_voxel_physics_boxes()
	// (as a sorted array in descending node_id order)
	std::vector<QueuedNodePhysicsUpdate> m_nodes_needing_physics_update;

	// The light fields this world maintains, and the changes each of them
	// has to be brought up to date after. Off unless the world asks; see
	// set_light_maintained() in api.h.
	static const size_t NUM_LIGHT_FIELDS = 2;
	bool m_light_maintained[NUM_LIGHT_FIELDS] = {false, false};
	bool m_physics_enabled;
	// The world region in sections, so that the top of it can be found. Light
	// enters from above that; everything outside is a barrier.
	pv::Region m_section_region;
	// Voxels that started or stopped transmitting light since the last commit,
	// with what they were before, because the new voxel has already replaced
	// the old light value by the time this is looked at.
	struct SkylightSeed
	{
		pv::Vector3DInt32 p;
		uint8_t old_level;
		bool was_transparent;
		// What the voxel that was there made of its own light. A blocker
		// wears the brightest light beside it rather than real propagated
		// light, so its stored level does not say whether a lamp went.
		uint8_t old_emitted;
		// **Put here by a relight, not by an edit or by the generator.**
		// Only a relight asks the sky column where the daylight is, and
		// the reason is that only a relight has a whole world under it:
		// during worldgen the column above a voxel is half made, and
		// open_sky_from() then calls a cave open sky, seeds it at fifteen
		// and loses the lot when the rock above arrives and the
		// neighbourhood is zeroed together with nothing left holding
		// light to spread back. apps/voxel_lighting, 2026-09-28: the
		// column asked at generation left 87802 voxels darker than a
		// fresh fill, the same number at 9, 30, 60 and 90 seconds, where
		// without it the scene reads ok ([SKY_COLUMN_CAVE]).
		bool from_relight;
	};
	std::vector<SkylightSeed> m_light_seeds[NUM_LIGHT_FIELDS];

	// The world region's own sections have not been created yet; see the
	// constructor
	bool m_initial_sections_pending = true;
	// How long the first sections wait for a game to say where it wants
	// them. A game sets its load points in its own good time -- often one
	// event after the world is made -- and the first tick can land in
	// between; a world too big to fill has to wait for them rather than
	// give up on the first tick it sees. At 30 Hz these are a tenth of a
	// second and ten seconds.
	int m_initial_sections_waited = 0;
	static const int INITIAL_SECTIONS_WARN_TICKS = 3;
	static const int INITIAL_SECTIONS_GIVE_UP_TICKS = 300;
	static const int64_t MAX_INITIAL_SECTIONS = 4096;

	// Streaming: the points the world is kept loaded around, and how much
	// one pass may do. Empty and off until a game sets load points; until
	// then the world is its region and stays there.
	sv_<voxelworld::LoadPoint> m_load_points;
	bool m_streaming = false;
	size_t m_stream_budget = 2;
	uint m_stream_tick = 0;
	// Sections the save was asked for and does not have; see load_saved_only()
	set_<uint64_t> m_save_misses;

	// What the send filter answers from. replicate asks it from its own
	// thread, so this much is behind a lock of its own -- a small one, and
	// never held while reaching into another module.
	std::mutex m_send_mutex;
	// Chunk node id -> the chunk it holds. A node that is not in here is
	// not this world's and the filter says nothing about it.
	sm_<uint, pv::Vector3DInt32> m_chunk_node_chunk_p;
	// The load point of each peer that has one of its own
	sm_<replicate::PeerId, voxelworld::LoadPoint> m_peer_points;
	// How much world each client asked for, in sections. A peer that never
	// asked is not in here and gets everything its load point keeps.
	sm_<replicate::PeerId, int> m_peer_send_radius;
	// Where a peer was when replicate last reconsidered what it has
	sm_<replicate::PeerId, pv::Vector3DInt16> m_peer_section;

	// Persistence. Null until a game calls set_save(); a world that never
	// does is generated and forgotten, which is what every game did before
	// this existed and what an arena game wants.
	storage::Store *m_store = nullptr;
	ss_ m_world_name;
	// [SERVER_CAPS], [SAVE_LIMIT]: the operator's max_disk_mb, against what
	// storage measured the app has written, every ten seconds; at the cap
	// nothing new is generated, and what is there -- the players' edits
	// too -- is saved as before. The game trims (trim_to()) to get under.
	// simplified: the bytes on disk, so what is generated and not yet
	// saved (a checkpoint's interval of it) goes over by that much
	ss_ m_save_path;
	storage::Save *m_save = nullptr;
	int64_t m_visits_marked_us = 0;
	bool m_world_full = false;
	int64_t m_world_measured_us = 0;
	// [SAVE_CHECKPOINT]: whether the game saves with its own writes (see
	// save(also)), and when this saved the world by itself last
	bool m_game_checkpoints = false;
	int64_t m_checkpoint_us = 0;
	// What a save's sections cost, by part: waiting for the scene, copying
	// the chunks out of it, renumbering them, and the rows written; the
	// commit is the checkpoint's own. Reset when a checkpoint begins.
	struct SaveTimes {
		int64_t wait = 0, copy = 0, compress = 0, write = 0;
		size_t sections = 0, bytes = 0;
	} m_save_times;
	ss_ save_times(int64_t commit_us)
	{
		char buf[160];
		snprintf(buf, sizeof buf, "%zu sections, %zu kB; waiting for the "
				"scene %i ms, copy %i, renumber %i, rows %i, commit %i",
				m_save_times.sections, m_save_times.bytes / 1024,
				(int)(m_save_times.wait / 1000), (int)(m_save_times.copy / 1000),
				(int)(m_save_times.compress / 1000),
				(int)(m_save_times.write / 1000), (int)(commit_us / 1000));
		return buf;
	}
	// The save's voxel name table: save id -> name, append-only and never
	// renumbered. The running game owns the numbering and the save stores
	// names -- the game is the only thing that can decide whether a name
	// still means what it meant, and a save has nothing to contribute to
	// that question. See doc/plan/world_persistence_plan.md.
	sv_<interface::VoxelName> m_save_names;
	std::map<ss_, interface::VoxelTypeId> m_save_id_of_name;
	bool m_save_names_dirty = false;
	// save id -> session id and back. Both are the identity in the common
	// case -- the same game, registering the same types in the same order --
	// and then a chunk is the byte copy of the save's row that it was before
	// any of this existed.
	sv_<interface::VoxelTypeId> m_save_to_session;
	sv_<interface::VoxelTypeId> m_session_to_save;
	bool m_id_map_identity = true;
	bool m_logged_remap = false;
	// set_name_aliases(): old block name -> new; and the save ids read
	// through one, which are never written to
	std::map<ss_, ss_> m_name_aliases;
	std::set<size_t> m_aliased_save_ids;
	// Session ids up to here are in the name table, and the registry row on
	// disk was written when the table reached the second of these. They are
	// what keeps both of those from being redone on every section.
	interface::VoxelTypeId m_names_synced_to = 0;
	interface::VoxelTypeId m_registry_saved_to = (interface::VoxelTypeId)-1;
	// The definitions the save carries, for a type the game has stopped
	// registering. Loaded on the first one that turns up and not before.
	up_<interface::VoxelRegistry> m_saved_reg;
	sv_<interface::VoxelName> m_unknown_voxels;
	// The formats the save's chunks are in, indexed by the tag a chunk row
	// carries, and which of them new chunks are written in
	sv_<interface::VoxelFormat> m_save_formats;
	uint16_t m_write_format = 0;

	CInstance(interface::Server *server, SceneReference scene_ref,
			const pv::Region &region, bool physics_enabled):
		m_server(server),
		m_scene_ref(scene_ref),
		m_section_region(region),
		m_physics_enabled(physics_enabled)
	{
		m_voxel_reg.reset(interface::createVoxelRegistry());
		m_block_reg.reset(interface::createBlockRegistry(m_voxel_reg.get()));

		main_context::access(m_server, [&](main_context::Interface *imc){
			Context *context = imc->get_context();

			m_atlas_reg.reset(interface::createAtlasRegistry(context));
		});

		// The region's sections are created on the first tick and not here.
		// A game creates the world, registers its voxels and calls
		// set_save() in one core:start, in that order, and a section that
		// comes out of a save must not be generated -- so nothing may be
		// loaded before the game has had the chance to say whether there is
		// a save to look in.

		check_streaming();
		check_index();

		// Which chunks reach which peer. Nothing is filtered until a game
		// gives its peers load points of their own; see peer_wants_node().
		replicate::access(m_server, [&](replicate::Interface *irep){
			irep->set_node_filter(m_scene_ref,
					[this](replicate::PeerId peer, uint node_id){
				return peer_wants_node(peer, node_id);
			});
			irep->set_node_priority(m_scene_ref,
					[this](replicate::PeerId peer, uint node_id){
				return node_priority(peer, node_id);
			});
		});

		// Find peers that already are on the scene and iniitalize them
		sv_<replicate::PeerId> peers;
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			peers = ireplicate->find_peers_on_scene(m_scene_ref);
		});
		ss_ peers_s = dump(peers);
		log_v(MODULE, "Existing peers on scene: %s", cs(peers_s));
		for(auto &peer : peers){
			initialize_peer(peer);
		}
	}

	~CInstance()
	{
		// The filter holds this; it must not outlive it
		replicate::access(m_server, [&](replicate::Interface *irep){
			irep->set_node_filter(m_scene_ref, nullptr);
			irep->set_node_priority(m_scene_ref, nullptr);
		});
	}

	// Returns false while it is still waiting for the game to say where it
	// wants sections; see the tick.
	bool create_initial_sections()
	{
		auto lc = m_section_region.getLowerCorner();
		auto uc = m_section_region.getUpperCorner();
		int64_t num = (int64_t)(uc.getX() - lc.getX() + 1) *
				(uc.getY() - lc.getY() + 1) * (uc.getZ() - lc.getZ() + 1);
		// The bounds of a world that streams are far larger than anything
		// anyone wants loaded at once, and creating them would be the rest
		// of the day. Such a world has to stream, so what this does is wait
		// for the load points that make it stream -- and say so, and then
		// give up, if they never come.
		if(num > MAX_INITIAL_SECTIONS){
			m_initial_sections_waited++;
			if(m_initial_sections_waited == INITIAL_SECTIONS_WARN_TICKS)
				log_w(MODULE, "The region is %s sections; waiting for "
						"set_load_points(), because a world with bounds "
						"bigger than it wants loaded has to stream",
						cs(itos(num)));
			if(m_initial_sections_waited < INITIAL_SECTIONS_GIVE_UP_TICKS)
				return false;
			throw Exception(ss_()+"voxelworld: the region is "+itos(num)+
					" sections and nothing called set_load_points(); a world "
					"with bounds bigger than it wants loaded has to stream");
		}
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					load_or_generate_section(pv::Vector3DInt16(x, y, z));
				}
			}
		}
		return true;
	}

	// Streaming. One pass loads, generates or unloads a few sections at
	// most, nearest first, so that a player waiting for the ground under
	// them does not wait for the horizon.

	static uint64_t section_key(const pv::Vector3DInt16 &p)
	{
		return (uint64_t)(uint16_t)p.getX() |
				((uint64_t)(uint16_t)p.getY() << 16) |
				((uint64_t)(uint16_t)p.getZ() << 32);
	}

	pv::Vector3DInt16 section_of_voxel(const pv::Vector3DInt32 &p)
	{
		return container_coord16(
				container_coord(p, m_chunk_size_voxels),
				m_section_size_chunks);
	}

	bool is_in_bounds(const pv::Vector3DInt16 &sp)
	{
		auto lc = m_section_region.getLowerCorner();
		auto uc = m_section_region.getUpperCorner();
		return sp.getX() >= lc.getX() && sp.getX() <= uc.getX() &&
				sp.getY() >= lc.getY() && sp.getY() <= uc.getY() &&
				sp.getZ() >= lc.getZ() && sp.getZ() <= uc.getZ();
	}

	// Inside some point's load radius, which is what lets a section stay
	static int dist(int a, int b){ return a > b ? a - b : b - a; }

	bool is_wanted_loaded(const pv::Vector3DInt16 &sp)
	{
		for(const voxelworld::LoadPoint &lp : m_load_points){
			pv::Vector3DInt16 c = section_of_voxel(lp.p);
			if(dist(sp.getX(), c.getX()) <= lp.load_xz &&
					dist(sp.getZ(), c.getZ()) <= lp.load_xz &&
					dist(sp.getY(), c.getY()) <= lp.load_y)
				return true;
		}
		return false;
	}

	// Which chunks a peer is sent: the ones its own load point keeps near
	// it, as far out as its client asked for. replicate calls this from its
	// own sync, so it reaches into nothing and holds only m_send_mutex.
	//
	// A node this world did not make, or a peer whose position nobody
	// declared, is none of this filter's business and passes.
	bool peer_wants_node(replicate::PeerId peer, uint node_id)
	{
		std::lock_guard<std::mutex> lock(m_send_mutex);
		auto it = m_chunk_node_chunk_p.find(node_id);
		if(it == m_chunk_node_chunk_p.end())
			return true;
		auto pit = m_peer_points.find(peer);
		if(pit == m_peer_points.end())
			return true;
		const voxelworld::LoadPoint &lp = pit->second;
		int radius = lp.load_xz;
		auto rit = m_peer_send_radius.find(peer);
		// A peer that has not said how much it wants wants nothing yet:
		// the client says 0 until its game's textures are composed
		// ([TEXMOD_RACE]), and a "0" sent before this module knew the
		// peer (the launcher's client joins before the world exists) was
		// dropped, so the world streamed and was meshed with no textures
		// ([FIRST_RUN]). It says its distance again when ready.
		if(rit == m_peer_send_radius.end())
			return false;
		if(rit->second < radius)
			radius = rit->second;
		pv::Vector3DInt16 sp = container_coord16(it->second,
				m_section_size_chunks);
		pv::Vector3DInt16 c = section_of_voxel(lp.p);
		return dist(sp.getX(), c.getX()) <= radius &&
				dist(sp.getZ(), c.getZ()) <= radius &&
				dist(sp.getY(), c.getY()) <= lp.load_y;
	}

	// [LOAD_OWN_CHUNK] A chunk's squared distance in voxels from the peer's
	// load point, its centre's: the nearest are synced first. A node this
	// world did not make, or a peer with no point, goes before all of them.
	float node_priority(replicate::PeerId peer, uint node_id)
	{
		std::lock_guard<std::mutex> lock(m_send_mutex);
		auto it = m_chunk_node_chunk_p.find(node_id);
		if(it == m_chunk_node_chunk_p.end())
			return -1.0f;
		auto pit = m_peer_points.find(peer);
		if(pit == m_peer_points.end())
			return -1.0f;
		const pv::Vector3DInt32 &c = it->second;
		const auto &s = m_chunk_size_voxels;
		const auto &p = pit->second.p;
		float dx = c.getX() * s.getX() + s.getX() / 2 - p.getX();
		float dy = c.getY() * s.getY() + s.getY() / 2 - p.getY();
		float dz = c.getZ() * s.getZ() + s.getZ() / 2 - p.getZ();
		return dx * dx + dy * dy + dz * dz;
	}

	// The client says how much world it wants; what it gets is that or the
	// load radius, whichever is smaller. Only the client knows what its
	// computer can draw, and loading more than it will look at is the
	// server's memory spent on nothing.
	void on_set_send_distance(const network::Packet &packet)
	{
		if(!m_clients_initialized.count(packet.sender))
			return;
		int distance_voxels = atoi(packet.data.c_str());
		if(distance_voxels < 0)
			return;
		// A client's number: past a million voxels the sum below wrapped
		// (the radius is clamped to what is loaded further on anyway)
		if(distance_voxels > 1000000)
			distance_voxels = 1000000;
		// [SERVER_CAPS]: the operator's max_view_range, 0 none
		const int64_t cap =
				atoll(m_server->get_config().get<ss_>("max_view_range").c_str());
		if(cap > 0 && distance_voxels > cap)
			distance_voxels = (int)cap;
		int section_w = m_chunk_size_voxels.getX() *
				m_section_size_chunks.getX();
		// A section the point is anywhere in is one the client can see into;
		// nought is nothing at all, not the section the point is in -- a
		// client that has not said it may have the world yet ([TEXMOD_RACE])
		int radius = distance_voxels == 0 ? -1 :
				(distance_voxels + section_w - 1) / section_w;
		log_v(MODULE, "C%zu: wants %i voxels of world, which is %i sections",
				(size_t)packet.sender, distance_voxels, radius);
		{
			std::lock_guard<std::mutex> lock(m_send_mutex);
			m_peer_send_radius[packet.sender] = radius;
		}
		replicate::access(m_server, [&](replicate::Interface *irep){
			irep->refresh_peer_nodes(m_scene_ref, packet.sender);
		});
	}

	void measure_world()
	{
		const int64_t now = interface::os::time_us();
		if(m_save_path.empty() || now - m_world_measured_us < 10000000)
			return;
		m_world_measured_us = now;
		int64_t used = 0, limit = 0;
		storage::access(m_server, [&](storage::Interface *i){
			used = i->used_bytes();
			limit = i->limit_bytes();
		});
		const bool full = limit > 0 && used >= limit;
		if(full != m_world_full)
			log_w(MODULE, full ? "World \"%s\": the app is at max_disk_mb: "
					"nothing new is generated" : "World \"%s\": the app is "
					"under max_disk_mb again", cs(m_world_name));
		m_world_full = full;
	}

	// [SAVE_LIMIT] The day each section a player has loaded was last seen,
	// for trim_to(): checked each minute
	void mark_visits()
	{
		const int64_t now = interface::os::time_us();
		if(!m_store || now - m_visits_marked_us < 60000000)
			return;
		m_visits_marked_us = now;
		const int32_t day = today();
		for(const voxelworld::LoadPoint &lp : m_load_points){
			if(lp.peer == 0)
				continue;
			for_each_section_around(section_of_voxel(lp.p), lp.load_xz,
					lp.load_y, [&](const pv::Vector3DInt16 &p, int, int){
				Section *section = get_section(p);
				if(section && section->loaded && section->visited_day != day){
					section->visited_day = day;
					section->index_dirty = true;
				}
				return true;
			});
		}
	}

	void stream_pass()
	{
		measure_world();
		mark_visits();
		size_t budget = m_stream_budget;
		for(const voxelworld::LoadPoint &lp : m_load_points){
			if(budget == 0)
				return;
			stream_around(lp, budget);
		}
		if(budget == 0)
			return;
		unload_distant_sections(budget);
	}

	// The sections of a box around c, ring by ring outward, so that the
	// nearest section that is missing something is the one that gets it. The
	// callback is given the ring it is on -- which is its distance in XZ --
	// and stops the walk by returning false.
	template<typename F>
	static void for_each_section_around(const pv::Vector3DInt16 &c,
			int load_xz, int load_y, F f)
	{
		for(int r = 0; r <= load_xz; r++){
			for(int dy = -load_y; dy <= load_y; dy++){
				for(int dz = -r; dz <= r; dz++){
					for(int dx = -r; dx <= r; dx++){
						// The ring and not the square: what is inside it was
						// walked by a smaller r already
						if(r > 0 && dx != r && dx != -r &&
								dz != r && dz != -r)
							continue;
						if(!f(pv::Vector3DInt16(c.getX() + dx, c.getY() + dy,
								c.getZ() + dz), r, dy))
							return;
					}
				}
			}
		}
	}

	void stream_around(const voxelworld::LoadPoint &lp, size_t &budget)
	{
		for_each_section_around(section_of_voxel(lp.p), lp.load_xz, lp.load_y,
				[&](const pv::Vector3DInt16 &sp, int r, int dy) -> bool
		{
			if(!is_in_bounds(sp))
				return true;
			bool generate = (r <= lp.generate_xz &&
					dist(dy, 0) <= lp.generate_y && !m_world_full);
			if(!stream_section(sp, generate))
				return true;
			return --budget != 0;
		});
	}

	// The rings cover the box exactly once, nearest first, and the ring a
	// section is on is its distance -- which is what decides whether it is
	// generated as well as loaded
	static void check_streaming()
	{
		const int R = 3, RY = 1;
		const pv::Vector3DInt16 c(10, -2, 7);
		set_<uint64_t> seen;
		int last_r = 0;
		size_t n = 0;
		for_each_section_around(c, R, RY,
				[&](const pv::Vector3DInt16 &sp, int r, int dy) -> bool
		{
			bool fresh = seen.insert(section_key(sp)).second;
			assert(fresh);
			(void)fresh;
			assert(r >= last_r);
			last_r = r;
			assert(r == std::max(dist(sp.getX(), c.getX()),
					dist(sp.getZ(), c.getZ())));
			assert(dy == sp.getY() - c.getY());
			assert(dist(sp.getY(), c.getY()) <= RY);
			n++;
			return true;
		});
		assert(n == (size_t)(2*R+1) * (2*R+1) * (2*RY+1));
		// And it stops where it is told
		size_t stopped_after = 0;
		for_each_section_around(c, R, RY,
				[&](const pv::Vector3DInt16 &sp, int r, int dy) -> bool
		{
			return ++stopped_after < 5;
		});
		assert(stopped_after == 5);
		log_v(MODULE, "check_streaming: the rings cover the box once");
	}

	// True if this section wanted something and got it
	bool stream_section(const pv::Vector3DInt16 &sp, bool generate)
	{
		Section *section = get_section(sp);
		if(section && section->loaded && (section->generated || !generate))
			return false;
		if(generate){
			load_or_generate_section(sp);
			return true;
		}
		return load_saved_only(sp);
	}

	// What the save already holds, without generating what it does not: the
	// terrain a player sees far away is the terrain that is already there.
	bool load_saved_only(const pv::Vector3DInt16 &sp)
	{
		if(!m_store)
			return false;
		// The save was asked once and does not have it; asking again every
		// pass would be a query per section of the load radius per pass
		if(m_save_misses.count(section_key(sp)))
			return false;
		Section &section = force_get_section(sp);
		if(section.loaded)
			return true;
		if(load_saved_section(section)){
			section.loaded = true;
			m_server->emit_event("voxelworld:section_loaded",
					new SectionLoaded(m_scene_ref, sp));
			return true;
		}
		m_save_misses.insert(section_key(sp));
		forget_section(sp);
		return false;
	}

	// Drop a section nothing was put in. Not unload_section(): there is
	// nothing to write, no nodes to remove and no buffers to free.
	void forget_section(const pv::Vector3DInt16 &sp)
	{
		Section *section = get_section(sp);
		if(!section)
			return;
		forget_cached(section);
		pv::Vector<2, int16_t> p_yz(sp.getY(), sp.getZ());
		auto sector_it = m_sections.find(p_yz);
		if(sector_it == m_sections.end())
			return;
		sector_it->second.erase(sp.getX());
		if(sector_it->second.empty())
			m_sections.erase(sector_it);
	}

	void unload_distant_sections(size_t &budget)
	{
		if(m_keep_loaded)
			return;
		sv_<pv::Vector3DInt16> drop;
		for(auto &sector : m_sections){
			for(auto &pair : sector.second){
				Section &section = pair.second;
				if(!section.loaded)
					continue;
				if(is_wanted_loaded(section.section_p))
					continue;
				drop.push_back(section.section_p);
				if(drop.size() >= budget)
					break;
			}
			if(drop.size() >= budget)
				break;
		}
		for(const pv::Vector3DInt16 &sp : drop)
			unload_section(sp);
		budget -= drop.size();
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("replicate:peer_joined_scene", on_peer_joined_scene,
				replicate::PeerJoinedScene);
		EVENT_TYPEN("replicate:peer_left_scene", on_peer_left_scene,
				replicate::PeerLeftScene);
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/voxelworld:set_send_distance",
				on_set_send_distance, network::Packet)
		/*EVENT_TYPEN("network:packet_received/voxelworld:get_section",
				on_get_section, network::Packet)*/
	}

	// How long one tick may spend building chunks' collision boxes; see
	// the loop that reads it
	static const int64_t PHYSICS_BUDGET_US = 100000;

	void on_tick(const interface::TickEvent &event)
	{
		// Where a long tick went ([BLOCKED_MODULE]): this tick holds
		// main_context while it runs and replicate, the relight and a
		// game's own module queue behind it -- 1.9 s of it under a world
		// being generated and walked. The phases are timed so the next
		// reading names one instead of the tick.
		const int64_t tick_t0 = interface::os::time_us();
		int64_t t_announce = 0, t_initial = 0, t_stream = 0, t_scene = 0,
				t_unload = 0;
		size_t physics_nodes = 0;
		// What the commits since the last tick wrote, told to replicate and
		// the clients in one go. It is here rather than at the end of the
		// commit because a commit runs inside whatever module asked for
		// voxelworld, and this part of it reaches into replicate and
		// network -- so a mod writing a node used to wait for both, once
		// per node. Now it waits for neither, and the tick pays once.
		announce_committed_nodes();
		t_announce = interface::os::time_us() - tick_t0;


		// A flood the commit's budget left is carried on here when no game
		// does it by relight_stale() (luanti does, every step): a world
		// generated in one piece stayed dark below the sky's seeds, its
		// flood pending for good ([VOXEL_LIGHTING_CAVE])
		if(m_relight_pending &&
				tick_t0 - m_relight_stale_us > RELIGHT_IDLE_US)
			relight_continue(tick_t0 + TICK_RELIGHT_BUDGET_US);

		if(m_initial_sections_pending){
			// A world that streams says where it wants sections; the region
			// is then its bounds and its sky and not a thing to fill
			if(m_streaming)
				m_initial_sections_pending = false;
			else if(create_initial_sections())
				m_initial_sections_pending = false;
		}

		t_initial = interface::os::time_us() - tick_t0 - t_announce;

		// Every fourth tick: often enough that a running player stays ahead
		// of the edge, seldom enough that the work is not the tick
		if(m_streaming && ((m_stream_tick++) % 4) == 0)
			stream_pass();
		t_stream = interface::os::time_us() - tick_t0 - t_announce - t_initial;

		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->find_scene(m_scene_ref);
			if(!scene){
				// Scene was deleted; hope that Module deletes us at some point
				return;
			}

			Context *context = imc->get_context();

			// Update node collision boxes
			if(!m_nodes_needing_physics_update.empty()){
				physics_nodes = m_nodes_needing_physics_update.size();
				log_v(MODULE, "Updating physics of %zu nodes",
						physics_nodes);
			}
			// A chunk's collision boxes are 50-70 ms of deserializing its
			// volume and building a box per solid voxel, and this holds
			// main_context while it runs: forty of them in a tick was 1.8 s
			// with replicate, the relight and a game's own module waiting
			// behind it ([BLOCKED_MODULE]). At most PHYSICS_BUDGET_US of
			// them a tick; the rest keep their place in the queue and the
			// chunk they are for is without its boxes for a tick or two.
			const int64_t physics_t0 = interface::os::time_us();
			size_t physics_done = 0;
			for(QueuedNodePhysicsUpdate &update: m_nodes_needing_physics_update){
				if(physics_done > 0 && interface::os::time_us() - physics_t0 >
						PHYSICS_BUDGET_US)
					break;
				physics_done++;
				uint node_id = update.node_id;
				Node *n = scene->GetNode(node_id);
				if(!n){
					log_w(MODULE, "on_tick(): Node physics update: "
							"Node %i not found", node_id);
					continue;
				}
				// Get volume
				const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
				const PODVector<unsigned char> &rawbuf = var.GetBuffer();
				ss_ data((const char*)&rawbuf[0], rawbuf.Size());
				up_<VoxelVolume> volume =
						interface::deserialize_volume(data);
				// Update collision shape
				interface::mesh::set_voxel_physics_boxes(n, context, *volume,
						m_voxel_reg.get());
			}
			m_nodes_needing_physics_update.erase(
					m_nodes_needing_physics_update.begin(),
					m_nodes_needing_physics_update.begin() + physics_done);
			if(!m_nodes_needing_physics_update.empty())
				log_v(MODULE, "Node physics: %zu done, %zu left for the next "
						"tick", physics_done,
						m_nodes_needing_physics_update.size());
		});

		t_scene = interface::os::time_us() - tick_t0 - t_announce - t_initial -
				t_stream;

		// Unload stuff if needed
		maintain_maximum_buffer_limit();
		t_unload = interface::os::time_us() - tick_t0 - t_announce -
				t_initial - t_stream - t_scene;

		// Send updated voxel registry if needed
		send_voxel_registry_if_dirty();
		checkpoint_if_due();
		const int64_t tick_us = interface::os::time_us() - tick_t0;
		if(tick_us > 100000)
			log_w(MODULE, "on_tick(): %i ms -- announce %i, initial %i, "
					"stream %i, the scene %i (%zu nodes' physics), unload %i, "
					"the registry %i", (int)(tick_us / 1000),
					(int)(t_announce / 1000), (int)(t_initial / 1000),
					(int)(t_stream / 1000), (int)(t_scene / 1000),
					physics_nodes, (int)(t_unload / 1000),
					(int)((tick_us - t_announce - t_initial - t_stream -
					t_scene - t_unload) / 1000));
	}

	// [SAVE_CHECKPOINT] A hard stop loses what is not on disk, and a section
	// is written when it unloads: where players are, never. A game that
	// checkpoints itself (luanti) is left to it.
	void checkpoint_if_due()
	{
		if(m_game_checkpoints || !m_store)
			return;
		const double interval = atof(m_server->get_config().get<ss_>(
				"save_interval_s").c_str());
		const int64_t now = interface::os::time_us();
		if(interval <= 0 || now - m_checkpoint_us < (int64_t)(interval * 1e6))
			return;
		if(m_checkpoint_us == 0){ // The first interval starts now
			m_checkpoint_us = now;
			return;
		}
		m_checkpoint_us = now;
		storage::Store *store = m_store;
		int64_t t_commit = 0;
		m_save_times = SaveTimes();
		store->batch([&](){
			save();
			t_commit = interface::os::time_us();
		});
		const int64_t end = interface::os::time_us();
		const ss_ parts = save_times(end - t_commit);
		if(end - now > 100000)
			log_w(MODULE, "checkpoint: %i ms: %s", (int)((end - now) / 1000),
					cs(parts));
		else
			log_v(MODULE, "checkpoint: %i ms: %s", (int)((end - now) / 1000),
					cs(parts));
	}

	void on_peer_joined_scene(const replicate::PeerJoinedScene &event)
	{
		initialize_peer(event.peer);
	}

	void on_peer_left_scene(const replicate::PeerLeftScene &event)
	{
		m_clients_initialized.erase(event.peer);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
	}

	// TODO: How should nodes be filtered for replication?
	// TODO: Generally the client wants roughly one section, but isn't
	//       positioned at the middle of a section
	/*void on_get_section(const network::Packet &packet)
	{
		pv::Vector3DInt16 section_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(section_p);
		}
		log_v(MODULE, "C%i: on_get_section(): " PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(section_p));
	}*/

	void initialize_peer(replicate::PeerId peer)
	{
		log_v(MODULE, "Initializing peer %i", peer);
		// Load the client-side module (can be called multiple times)
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "core:run_script",
					"require(\"buildat/module/voxelworld\")");
		});
		// Send initialization data and tell the client that it is now ready
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(m_chunk_size_voxels);
			ar(m_section_size_chunks);
		}
		// The registry is a file of client_file's ([REGISTRY_FILE]): cached
		// by its hash, so a join that has it transfers none of it
		// (VoxeLibre's is 30 MB). The script that reads it waits for the
		// files still coming, and ready waits for the script: nothing is
		// meshed before the registry is in.
		serve_voxel_registry();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "voxelworld:init", os.str());
			inetwork->send(peer, "core:run_script", REGISTRY_SCRIPT);
			inetwork->send(peer, "voxelworld:ready", "");
		});
		m_clients_initialized.insert(peer);
	}

	static constexpr const char *REGISTRY_FILE = "voxelworld/voxel_registry.bin";
	static constexpr const char *REGISTRY_SCRIPT =
			"require(\"buildat/module/voxelworld\").registry_from_file()";

	// The file served again when the registry changed; false when it had
	// not. Replacing it announces it to every connected client.
	bool serve_voxel_registry()
	{
		if(m_registry_served && !m_voxel_reg->is_dirty())
			return false;
		m_voxel_reg->clear_dirty();
		const ss_ data = m_voxel_reg->serialize();
		client_file::access(m_server, [&](client_file::Interface *ifile){
			ifile->add_file_content(REGISTRY_FILE, data);
		});
		if(!m_registry_served){
			std::ostringstream os(std::ios::binary);
			interface::compress_zstd(data, os);
			log_i(MODULE, "The voxel registry served as %s: %zu bytes, "
					"%zu with zstd", REGISTRY_FILE, data.size(),
					os.str().size());
		}
		m_registry_served = true;
		return true;
	}

	void unload_node(Scene *scene, uint node_id)
	{
		log_d(MODULE, "Unloading node %i", node_id);
		{
			std::lock_guard<std::mutex> lock(m_send_mutex);
			m_chunk_node_chunk_p.erase(node_id);
		}
		Node *n = scene->GetNode(node_id);
		if(!n){
			log_w(MODULE, "Cannot unload node %i: Not found in scene", node_id);
			return;
		}
		// Remove RigidBody first to speed up removal of CollisionShapes
		RigidBody *body = n->GetComponent<RigidBody>();
		if(body)
			n->RemoveComponent(body);
		// Remove everything else
		n->RemoveAllComponents();
		n->Remove();
	}

	// A changed registry's file to the joined clients, read again as it
	// arrives ([REGISTRY_FILE]). With nobody joined it waits for the next
	// join: a client in the menu would fetch every version of a game's
	// loading.
	// NOTE: This probably really only supports additions
	void send_voxel_registry_if_dirty()
	{
		if(m_clients_initialized.empty() || !serve_voxel_registry())
			return;
		log_v(MODULE, "Sending updated voxel registry to peers");
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &peer: m_clients_initialized)
				inetwork->send(peer, "core:run_script", REGISTRY_SCRIPT);
		});
	}

	// Get section if exists
	Section* get_section(const pv::Vector3DInt16 &section_p)
	{
		// Check cache
		for(Section *section : m_last_used_sections){
			if(section->section_p == section_p)
				return section;
		}
		// Not in cache
		pv::Vector<2, int16_t> p_yz(section_p.getY(), section_p.getZ());
		auto sector_it = m_sections.find(p_yz);
		if(sector_it == m_sections.end())
			return nullptr;
		sm_<int16_t, Section> &sector = sector_it->second;
		auto section_it = sector.find(section_p.getX());
		if(section_it == sector.end())
			return nullptr;
		Section &section = section_it->second;
		// Add to cache and return
		m_last_used_sections.push_back(&section);
		if(m_last_used_sections.size() > 2) // 2 is maybe optimal-ish
			m_last_used_sections.pop_front();
		return &section;
	}

	// Get a section; allocate it if it doesn't exist yet
	Section& force_get_section(const pv::Vector3DInt16 &section_p)
	{
		pv::Vector<2, int16_t> p_yz(section_p.getY(), section_p.getZ());
		sm_<int16_t, Section> &sector = m_sections[p_yz];
		Section &section = sector[section_p.getX()];
		if(section.chunk_size.getX() == 0){
			// Initialize newly created section properly
			pv::Region contained_chunks(
					section_p.getX() * m_section_size_chunks.getX(),
					section_p.getY() * m_section_size_chunks.getY(),
					section_p.getZ() * m_section_size_chunks.getZ(),
					(section_p.getX()+1) * m_section_size_chunks.getX() - 1,
					(section_p.getY()+1) * m_section_size_chunks.getY() - 1,
					(section_p.getZ()+1) * m_section_size_chunks.getZ() - 1
			);
			section = Section(m_scene_ref, section_p, m_chunk_size_voxels,
					contained_chunks);
		}
		return section;
	}

	// saved_data is a chunk read back out of a save: the same bytes this
	// wrote there, which are the same bytes replication sends, so nothing
	// about the on-disk format was designed -- it is the volume format.
	void create_chunk_node(Scene *scene, Section &section, int x, int y, int z,
			const ss_ *saved_data = nullptr)
	{
		Context *context = scene->GetContext();

		pv::Vector3DInt16 section_p = section.section_p;
		pv::Vector3DInt32 chunk_p(
				section_p.getX() * m_section_size_chunks.getX() + x,
				section_p.getY() * m_section_size_chunks.getY() + y,
				section_p.getZ() * m_section_size_chunks.getZ() + z
		);

		Vector3 node_p(
				chunk_p.getX() * m_chunk_size_voxels.getX() +
				m_chunk_size_voxels.getX() / 2.0f - 0.5f,
				chunk_p.getY() * m_chunk_size_voxels.getY() +
				m_chunk_size_voxels.getY() / 2.0f - 0.5f,
				chunk_p.getZ() * m_chunk_size_voxels.getZ() +
				m_chunk_size_voxels.getZ() / 2.0f - 0.5f
		);

		ss_ name = "static_"+dump(chunk_p);

		log_t(MODULE, "create_chunk_node(): node_p=(%f, %f, %f), name=\"%s\"",
				node_p.x_, node_p.y_, node_p.z_, cs(name));

		Node *n = scene->CreateChild(name.c_str());
		if(n->GetID() == 0)
			throw Exception("Can't handle static node id=0");
		section.node_ids->setVoxelAt(chunk_p, n->GetID());
		{
			// What the send filter answers from; see peer_wants_node()
			std::lock_guard<std::mutex> lock(m_send_mutex);
			m_chunk_node_chunk_p[n->GetID()] = chunk_p;
		}

		// Distinguish static voxel nodes from others
		n->SetVar(StringHash("buildat_static"), Variant(true));

		int w = m_chunk_size_voxels.getX();
		int h = m_chunk_size_voxels.getY();
		int d = m_chunk_size_voxels.getZ();

		// This makes sure the node will be found when searched from the octree,
		// both on the server and the client. It is a marker and nothing else:
		// a zone mask of zero is what keeps it out of the renderer's zone
		// assignment, and that matters because what a drawable was last in is
		// cached on the drawable itself as a plain pointer. A chunk's node is
		// unloaded while the drawables around it stay, and Urho3D only clears
		// that pointer in the drawables its box still covers, so one that has
		// moved out since keeps a pointer into freed memory and the renderer
		// follows it on a worker thread.
		Zone *node_zone = n->CreateComponent<Zone>();
		node_zone->SetZoneMask(0);
		node_zone->SetPriority(-1000);
		node_zone->SetBoundingBox(BoundingBox(
				Vector3(-w/2, -h/2, -d/2), Vector3(w/2, h/2, d/2)));

		n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
		n->SetPosition(node_p);

		// NOTE: These volumes have one extra voxel at each edge in order to
		//       make proper meshes without gaps
		// TODO: Is this needed anymore?
		pv::Region region(-1, -1, -1, w, h, d);
		sp_<VoxelVolume> volume(
				new VoxelVolume(region));

		// Every plane of a new volume reads as zero and none of them is
		// allocated, so a chunk of nothing but VOXELTYPEID_UNDEFINED costs
		// its planes nothing at all

		// A loaded chunk has had the in_thread hooks run on it already, on
		// the way in to the save
		if(!saved_data)
			run_commit_hooks_in_thread(chunk_p, *volume);

		ss_ data = saved_data ? *saved_data :
				interface::serialize_volume_compressed(*volume);
		n->SetVar(StringHash("buildat_voxel_data"), Variant(
				PODVector<uint8_t>((const uint8_t*)data.c_str(), data.size())));

		run_commit_hooks_in_scene(chunk_p, n);

		m_server->emit_event("voxelworld:node_volume_updated",
				new NodeVolumeUpdated(m_scene_ref, n->GetID(), true, chunk_p));

		// There are no collision shapes initially, but add the rigid body now
		if(m_physics_enabled){
			RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
			body->SetFriction(0.75f);
		}
	}

	void create_section(Section &section)
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			auto lc = section.contained_chunks.getLowerCorner();
			auto uc = section.contained_chunks.getUpperCorner();
			for(int z = 0; z <= uc.getZ() - lc.getZ(); z++){
				for(int y = 0; y <= uc.getY() - lc.getY(); y++){
					for(int x = 0; x <= uc.getX() - lc.getX(); x++){
						create_chunk_node(scene, section, x, y, z);
					}
				}
			}
		});
	}

	// One chunk, one row. The section is the load and unload unit, but the
	// chunk is what a node holds and what the volume format describes, so a
	// key per chunk means no container format had to be invented for the
	// eight of them.
	ss_ chunk_key(const pv::Vector3DInt32 &chunk_p)
	{
		return m_world_name+"/"+itos(chunk_p.getX())+","+
				itos(chunk_p.getY())+","+itos(chunk_p.getZ());
	}

	// The generated mark, beside the section's chunks: "1" once a
	// generator has been over the section. A section a neighbour's
	// generator spilled into is saved before it is generated, and without
	// the mark it came back as generated and never was -- a hole in the
	// world ([UNGENERATED_SAVED] in doc/plan/world_persistence_plan.md).
	// A save from before the key has chunks and no mark, and those were
	// all generated for real.
	ss_ generated_key(const pv::Vector3DInt16 &section_p)
	{
		return m_world_name+"/s"+itos(section_p.getX())+","+
				itos(section_p.getY())+","+itos(section_p.getZ())+"/generated";
	}

	// [SAVE_LIMIT] The mark became the section's index: "i1 <generated>
	// <altered> <bytes> <day>". A mark from before ("1", "0") is altered
	// with its day unknown: nothing in an old save is forgotten until it has
	// been seen again.
	static ss_ index_row(bool generated, bool altered, int64_t bytes,
			int32_t day)
	{
		char buf[64];
		snprintf(buf, sizeof buf, "i1 %i %i %lld %i", generated ? 1 : 0,
				altered ? 1 : 0, (long long)bytes, (int)day);
		return buf;
	}
	static voxelworld::SectionStat parse_index_row(const ss_ &v)
	{
		voxelworld::SectionStat r;
		int g = 0, a = 0, d = -1;
		long long b = 0;
		if(v.compare(0, 3, "i1 ") == 0 &&
				sscanf(v.c_str() + 3, "%i %i %lld %i", &g, &a, &b, &d) == 4){
			r.generated = g != 0;
			r.altered = a != 0;
			r.bytes = b;
			r.day = d;
			return r;
		}
		r.generated = (v == "1");
		return r;
	}
	static int32_t today()
	{
		return (int32_t)(interface::os::time_us() / 86400000000LL);
	}

	// What trim_to() takes, of stats, for need bytes: an unaltered section
	// none of whose 26 neighbours is altered, least recently visited first
	// and of a day the farthest from what is loaded; then, altered_days >=
	// 0, altered ones not visited in that many days, oldest first. Never a
	// loaded one, nor one not generated yet.
	static sv_<pv::Vector3DInt16> choose_forget(
			const sv_<voxelworld::SectionStat> &stats, int32_t day,
			int64_t need, int altered_days)
	{
		set_<uint64_t> altered;
		for(const auto &s : stats)
			if(s.altered)
				altered.insert(section_key(s.p));
		auto near_altered = [&](const pv::Vector3DInt16 &p){
			for(int dz = -1; dz <= 1; dz++)
			for(int dy = -1; dy <= 1; dy++)
			for(int dx = -1; dx <= 1; dx++){
				if(altered.count(section_key(pv::Vector3DInt16(p.getX() + dx,
						p.getY() + dy, p.getZ() + dz))))
					return true;
			}
			return false;
		};
		sv_<const voxelworld::SectionStat*> plain, old;
		for(const auto &s : stats){
			if(s.loaded || !s.generated)
				continue;
			if(!s.altered && !near_altered(s.p))
				plain.push_back(&s);
			else if(s.altered && altered_days >= 0 && s.day >= 0 &&
					day - s.day > altered_days)
				old.push_back(&s);
		}
		sv_<pv::Vector3DInt16> loaded;
		for(const auto &s : stats)
			if(s.loaded)
				loaded.push_back(s.p);
		std::map<const voxelworld::SectionStat*, int> away;
		for(const auto *list : {&plain, &old}){
			for(const auto *s : *list){
				int d = 0;
				for(size_t i = 0; i < loaded.size(); i++){
					const int e = std::max({std::abs(s->p.getX() -
							loaded[i].getX()), std::abs(s->p.getY() -
							loaded[i].getY()), std::abs(s->p.getZ() -
							loaded[i].getZ())});
					d = i == 0 ? e : std::min(d, e);
				}
				away[s] = d;
			}
		}
		auto by_day = [&](const voxelworld::SectionStat *a,
				const voxelworld::SectionStat *b){
			return a->day != b->day ? a->day < b->day : away[a] > away[b];
		};
		std::stable_sort(plain.begin(), plain.end(), by_day);
		std::stable_sort(old.begin(), old.end(), by_day);
		sv_<pv::Vector3DInt16> out;
		int64_t got = 0;
		for(const auto *list : {&plain, &old}){
			for(const auto *s : *list){
				if(got >= need)
					return out;
				out.push_back(s->p);
				got += std::max<int64_t>(s->bytes, 1);
			}
		}
		return out;
	}

	static void check_index()
	{
		auto check = [](bool ok){
			if(!ok)
				throw Exception("voxelworld: check_index failed");
		};
		auto r = parse_index_row(index_row(true, false, 1234, 20737));
		check(r.generated && !r.altered && r.bytes == 1234 && r.day == 20737);
		r = parse_index_row("1");
		check(r.generated && r.altered && r.day == -1);
		r = parse_index_row("0");
		check(!r.generated && r.altered);
		// Along x: 0 altered; 1 plain but beside 0, kept; 3 plain, visited
		// day 5; 5 plain, day 2; 7 altered, day 1; 9 plain but loaded; 11
		// plain, day 2, nearer 9 than 5 is
		sv_<voxelworld::SectionStat> g;
		auto add = [&](int x, bool alt, int day, bool loaded = false){
			voxelworld::SectionStat s;
			s.p = pv::Vector3DInt16(x, 0, 0);
			s.altered = alt;
			s.day = day;
			s.bytes = 100;
			s.loaded = loaded;
			g.push_back(s);
		};
		add(0, true, 9); add(1, false, 0); add(3, false, 5); add(5, false, 2);
		add(7, true, 1); add(9, false, 1, true); add(11, false, 2);
		auto pick = choose_forget(g, 10, 150, -1);
		check(pick.size() == 2 && pick[0].getX() == 5 && pick[1].getX() == 11);
		pick = choose_forget(g, 10, 1000, -1);
		check(pick.size() == 3 && pick[2].getX() == 3);
		pick = choose_forget(g, 10, 1000, 8);
		check(pick.size() == 4 && pick[3].getX() == 7); // 9 days unvisited
		pick = choose_forget(g, 10, 1000, 9);
		check(pick.size() == 3);
		log_v(MODULE, "check_index: rows round-trip, an old one is altered, "
				"the choice keeps the margin");
	}

	// A chunk's row in the save: a header naming the format the chunk was
	// written in, and then the blob replication already produces. The tag is
	// Luanti's MapBlock property and it buys what it buys there -- chunks
	// are independent of each other, so a save converges as sections are
	// touched instead of being rewritten in one go, and one unreadable chunk
	// is one unreadable chunk.
	static const size_t CHUNK_HEADER_SIZE = 6;

	ss_ chunk_row(const ss_ &blob)
	{
		ss_ row;
		row.reserve(CHUNK_HEADER_SIZE + blob.size());
		row += "BVC";
		row += (char)1;
		row += (char)(m_write_format & 0xff);
		row += (char)((m_write_format >> 8) & 0xff);
		row += blob;
		return row;
	}

	// A row without the header was written before there was one, and is in
	// the world's own format by definition -- there was only ever the one. A
	// cereal archive begins with an endianness byte and never with 'B', so
	// the two cannot be read for each other.
	bool split_chunk_row(const ss_ &row, uint16_t &format_out, ss_ &blob_out)
	{
		if(row.size() < CHUNK_HEADER_SIZE || row.compare(0, 3, "BVC") != 0){
			format_out = m_write_format;
			blob_out = row;
			return true;
		}
		if((uint8_t)row[3] != 1)
			return false;
		format_out = (uint16_t)(uint8_t)row[4] |
				((uint16_t)(uint8_t)row[5] << 8);
		blob_out = row.substr(CHUNK_HEADER_SIZE);
		return true;
	}

	// A chunk out of the save, in the cut and the numbering this world runs.
	// Byte for byte what was stored, in the common case.
	bool prepare_loaded_chunk(const pv::Vector3DInt32 &chunk_p,
			const ss_ &row, ss_ &data_out, bool &converted_out)
	{
		ss_ where = ss_("chunk ")+itos(chunk_p.getX())+","+
				itos(chunk_p.getY())+","+itos(chunk_p.getZ());
		uint16_t tag = 0;
		ss_ blob;
		if(!split_chunk_row(row, tag, blob)){
			refuse_save(where+" has a header this build does not know");
			return false;
		}
		if(tag == m_write_format && m_id_map_identity){
			data_out = blob;
			return true;
		}
		// What comes out is not what is on disk, so the section is written
		// back the next time it is unloaded: the save converges on the
		// world's own format as sections are touched, and nothing that was
		// not touched is rewritten
		converted_out = true;
		up_<VoxelVolume> volume = interface::deserialize_volume(blob);
		if(!volume){
			refuse_save(where+" is not in a volume format this build knows");
			return false;
		}
		const interface::VoxelFormat &format = m_voxel_reg->get_format();
		if(tag != m_write_format){
			if(tag >= m_save_formats.size()){
				refuse_save(where+" is tagged with format "+itos((int)tag)+
						", which the save's format table does not have");
				return false;
			}
			ss_ why;
			up_<VoxelVolume> moved = interface::migrate_volume(*volume,
					m_save_formats[tag], format, &why);
			if(!moved){
				refuse_save(where+" was written in "+
						m_save_formats[tag].dump()+" and this world is "+
						format.dump()+": "+why);
				return false;
			}
			volume = std::move(moved);
		}
		if(!m_id_map_identity)
			interface::remap_volume_ids(*volume, format, m_save_to_session);
		data_out = interface::serialize_volume_compressed(*volume);
		return true;
	}

	// A chunk on its way into the save, in the save's numbering
	ss_ prepare_saved_chunk(const ss_ &blob)
	{
		if(m_id_map_identity)
			return blob;
		up_<VoxelVolume> volume = interface::deserialize_volume(blob);
		if(!volume)
			return blob;
		interface::remap_volume_ids(*volume, m_voxel_reg->get_format(),
				m_session_to_save);
		return interface::serialize_volume_compressed(*volume);
	}

	// Somehow get the section's static nodes and possible other nodes, either
	// by loading from the save or by creating new ones
	void load_section(Section &section)
	{
		if(section.loaded)
			return;
		section.loaded = true;
		pv::Vector3DInt16 section_p = section.section_p;
		log_d(MODULE, "Loading section " PV3I_FORMAT, PV3I_PARAMS(section_p));

		if(!m_store || !load_saved_section(section)){
			create_section(section);
			section.altered = false;
			section.visited_day = today();
		}
		// A section whose light went stale while it was away is flooded
		// again from what is around it now
		relight_if_stale(section);
		// What a game keeps of its own per section comes back with it
		m_server->emit_event("voxelworld:section_loaded",
				new SectionLoaded(m_scene_ref, section_p));
	}

	// True if the whole section was in the save. All or nothing: a section
	// with some of its chunks saved and some not would have to be both loaded
	// and generated, and generation is by section.
	bool load_saved_section(Section &section)
	{
		update_id_maps();
		if(!m_store) // update_id_maps() can refuse the save
			return false;
		auto lc = section.contained_chunks.getLowerCorner();
		auto uc = section.contained_chunks.getUpperCorner();
		sv_<ss_> chunks;
		chunks.reserve(section.num_chunks);
		bool converted = false;
		for(int z = 0; z <= uc.getZ() - lc.getZ(); z++){
			for(int y = 0; y <= uc.getY() - lc.getY(); y++){
				for(int x = 0; x <= uc.getX() - lc.getX(); x++){
					pv::Vector3DInt32 chunk_p(
							lc.getX() + x, lc.getY() + y, lc.getZ() + z);
					ss_ row;
					if(!m_store->get(chunk_key(chunk_p), row))
						return false;
					ss_ data;
					if(!prepare_loaded_chunk(chunk_p, row, data, converted))
						return false;
					chunks.push_back(data);
				}
			}
		}
		log_v(MODULE, "Loading section " PV3I_FORMAT " from the save",
				PV3I_PARAMS(section.section_p));
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			size_t i = 0;
			for(int z = 0; z <= uc.getZ() - lc.getZ(); z++){
				for(int y = 0; y <= uc.getY() - lc.getY(); y++){
					for(int x = 0; x <= uc.getX() - lc.getX(); x++){
						create_chunk_node(scene, section, x, y, z,
								&chunks[i++]);
					}
				}
			}
		});
		// Generated if the save says so, or if it predates the mark. A
		// section that is loaded and not generated goes to the generator
		// from load_or_generate_section(), whose merge writes by priority:
		// the terrain fills in around what was spilled rather than over it.
		ss_ mark;
		voxelworld::SectionStat row;
		if(m_store->get(generated_key(section.section_p), mark))
			row = parse_index_row(mark);
		section.generated = row.generated;
		section.altered = row.altered;
		section.saved_bytes = row.bytes;
		section.visited_day = row.day;
		if(!section.generated)
			log_v(MODULE, "Section " PV3I_FORMAT " came out of the save "
					"ungenerated", PV3I_PARAMS(section.section_p));
		section.modified = converted;
		return true;
	}

	// Writes the section's chunks as one transaction. Called when a section
	// is unloaded and when the world is saved as a whole; both are moments
	// where the data is about to stop being reachable.
	//
	// A section nothing has touched since it was read is not written at all,
	// which is what keeps saving a world people are only walking through
	// free. The flag is per section rather than per chunk because a section
	// is what is read and written as a unit.
	void save_section(Section &section)
	{
		// What the light reached while a section was away is written with
		// the sections, since it is about them
		save_stale_sections();
		if(!m_store || !section.loaded)
			return;
		if(!section.modified){
			// A day of a visit and nothing else: the row alone
			if(section.index_dirty){
				m_store->set(generated_key(section.section_p), index_row(
						section.generated && !section.awaiting,
						section.altered, section.saved_bytes,
						section.visited_day));
				section.index_dirty = false;
			}
			return;
		}
		update_id_maps();
		if(!m_store) // update_id_maps() can refuse the save
			return;
		sv_<ss_> keys;
		sv_<ss_> values;
		keys.reserve(section.num_chunks);
		values.reserve(section.num_chunks);
		const int64_t t0 = interface::os::time_us();
		int64_t t_in = 0;
		main_context::access(m_server, [&](main_context::Interface *imc){
			t_in = interface::os::time_us();
			Scene *scene = imc->check_scene(m_scene_ref);
			auto lc = section.contained_chunks.getLowerCorner();
			auto uc = section.contained_chunks.getUpperCorner();
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int y = lc.getY(); y <= uc.getY(); y++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						uint id = section.node_ids->getVoxelAt(x, y, z);
						if(!id)
							continue;
						Node *n = scene->GetNode(id);
						if(!n)
							continue;
						const Variant &var =
								n->GetVar(StringHash("buildat_voxel_data"));
						const PODVector<unsigned char> &buf = var.GetBuffer();
						if(buf.Size() == 0)
							continue;
						keys.push_back(chunk_key(pv::Vector3DInt32(x, y, z)));
						values.push_back(
								ss_((const char*)&buf[0], buf.Size()));
					}
				}
			}
		});
		const int64_t t1 = interface::os::time_us();
		m_save_times.wait += t_in - t0;
		m_save_times.copy += t1 - t_in;
		if(keys.empty()){
			section.modified = false;
			return;
		}
		// Outside the scene lock: a chunk that has to be renumbered is
		// decompressed, rewritten and compressed again, and the scene is not
		// waiting for that
		for(ss_ &value : values)
			value = chunk_row(prepare_saved_chunk(value));
		const int64_t t2 = interface::os::time_us();
		m_save_times.compress += t2 - t1;
		m_save_times.sections++;
		int64_t bytes = 0;
		for(const ss_ &value : values)
			bytes += value.size();
		m_save_times.bytes += bytes;
		// One transaction: a row at a time outside one is the classic slow
		// save, and it is also what leaves half a section on disk after a
		// crash. The name table goes in with the chunks that made it grow,
		// so there is no window where a row names an id the table has not.
		m_store->batch([&](){
			for(size_t i = 0; i < keys.size(); i++)
				m_store->set(keys[i], values[i]);
			m_store->set(generated_key(section.section_p), index_row(
					section.generated && !section.awaiting, section.altered,
					bytes, section.visited_day));
			save_name_table();
			save_registry();
		});
		m_save_times.write += interface::os::time_us() - t2;
		section.modified = false;
		section.saved_bytes = bytes;
		section.index_dirty = false;
		// The save has it now, whatever the streamer was told earlier
		m_save_misses.erase(section_key(section.section_p));
	}

	bool is_section_generated(const pv::Vector3DInt16 &section_p)
	{
		Section *section = get_section(section_p);
		return section != nullptr && section->loaded && section->generated &&
				!section->awaiting;
	}

	// See api.h: what has been written into this section is all of it there
	// is going to be, so no generator is asked for one
	void set_section_generated(const pv::Vector3DInt16 &section_p)
	{
		Section &section = force_get_section(section_p);
		if(!section.loaded)
			load_section(section);
		if(section.generated)
			return;
		section.generated = true;
		// Marked rather than generated, and the mark belongs in the save
		// with the voxels: a section that came back without it would be
		// generated over on the next run
		section.modified = true;
	}

	// A section that was marked stale while it was not in memory: take the
	// light out of it and let it back in from its own sources and from the
	// neighbours that are here now. Nothing is asked of the neighbours that
	// are not -- what they hold marks this one stale again when they load.
	//
	// The whole section is walked, which is a quarter of a million voxels;
	// it happens once per section per time the world's light moved while
	// that section was away. Only its faces and the voxels that make their
	// own light are seeded, because the flood spreads inwards from them --
	// that is what a flood is for.
	// The blockers of a deferred relight whose flood stopped at its
	// deadline, for the pass that finishes it; see relight_if_stale()
	sv_<pv::Vector3DInt32> m_relight_blockers;
	// Where the blockers' pass got to when a deadline stopped it
	size_t m_relight_finish_f = 0;
	size_t m_relight_finish_i = 0;
	bool m_relight_pending = false;
	// Which section the pending relight belongs to, so that its stale mark
	// can be cleared when the flood actually finishes rather than when it
	// starts; 0 when nothing is pending. See relight_if_stale().
	uint64_t m_relight_key = 0;

	// The pass that ends a relight: what light does not pass through
	// wears the brightest light beside it, the way the flood leaves the
	// blockers it touched
	// The blockers' faces read off their lit neighbours, under the same
	// deadline as the flood: a section's blockers are its solid voxels,
	// tens of thousands, and this pass unsliced was the 110-170 ms every
	// relight call cost against a 20 ms budget ([STEP_SLICE], seed 7's
	// rerun: the pass 23 ms, the flood 11 ms, the rest unnamed). True
	// when done; false leaves m_relight_pending set for the next call.
	bool relight_finish(int64_t deadline_us = 0)
	{
		for(; m_relight_finish_f < NUM_LIGHT_FIELDS;
				m_relight_finish_f++, m_relight_finish_i = 0){
			const size_t f = m_relight_finish_f;
			if(!m_light_maintained[f])
				continue;
			m_light_running = (LightField)f;
			m_light_buf = nullptr;
			m_light_section = nullptr;
			for(size_t &i = m_relight_finish_i; i < m_relight_blockers.size(); i++){
				if(deadline_us != 0 && (i & 255) == 255 &&
						interface::os::time_us() >= deadline_us)
					return false;
				light_blocker_from_neighbours(m_relight_blockers[i]);
			}
		}
		m_relight_blockers.clear();
		m_relight_finish_f = 0;
		m_relight_finish_i = 0;
		m_relight_pending = false;
		// **And now the section is no longer stale**, which is the one
		// place that is true; see relight_if_stale()
		if(m_relight_key != 0){
			if(m_stale_sections.erase(m_relight_key) > 0)
				m_stale_dirty = true;
			m_relight_key = 0;
		}
		return true;
	}

	// Continues a relight whose flood a deadline stopped; true when done
	bool relight_continue(int64_t deadline_us)
	{
		if(!m_relight_pending)
			return true;
		if(!update_skylight_until(deadline_us))
			return false;
		return relight_finish(deadline_us);
	}

	void relight_if_stale(Section &section, int64_t deadline_us = 0)
	{
		const uint64_t key = section_key(section.section_p);
		if(m_stale_sections.count(key) == 0)
			return;
		// **The mark is not cleared here.** This pass zeroes the section's
		// flood before it re-floods it, and the flood stops at the tick's
		// deadline -- so between the two the section is dark and the only
		// record that it has to be finished is m_relight_pending, which is
		// memory. A world closed in that window kept a zeroed section with
		// no stale mark on it and never lit it again, which is a played
		// world going dark section by section as it is played
		// ([UNDERGROUND_LIGHT]'s playtest fault, 2026-09-28: a fuzz world
		// read daylight 0 in open air thirty nodes above its canopy, where
		// the same seed generated afresh reads 15). The mark goes when the
		// flood is done, in relight_finish(), and until then a restart
		// starts the section over -- which is the safe direction.
		auto clear_mark = [&](){
			if(m_stale_sections.erase(key) > 0)
				m_stale_dirty = true;
		};
		// A column's top may have moved since the last flood
		forget_open_sky();
		// One at a time: the pending state is a single section's, and
		// restarting this one would zero what the tick is carrying
		if(m_relight_pending && m_relight_key == key)
			return;
		bool any = false;
		for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++)
			any = any || m_light_maintained[f];
		if(!any){
			clear_mark();
			return;
		}

		pv::Region region = get_section_region_voxels(section.section_p);
		const pv::Vector3DInt32 lc = region.getLowerCorner();
		const pv::Vector3DInt32 uc = region.getUpperCorner();
		sv_<pv::Vector3DInt32> blockers;
		size_t seeded = 0;
		const int64_t t_seed = interface::os::time_us();
		for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++){
			const LightField lf = (LightField)f;
			if(!m_light_maintained[lf])
				continue;
			m_light_running = lf;
			m_light_buf = nullptr;
			m_light_section = nullptr;
			const bool first = blockers.empty();
			for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
			for(int32_t y = lc.getY(); y <= uc.getY(); y++)
			for(int32_t x = lc.getX(); x <= uc.getX(); x++){
				const pv::Vector3DInt32 p(x, y, z);
				VoxelInstance v = light_get(p);
				if(get_id(v) == interface::VOXELTYPEID_UNDEFINED)
					continue;
				if(flood_get(v) != 0)
					light_set(p, v, 0);
				if(!transmits_light_at(p)){
					if(first && emitted_at(p) == 0)
						blockers.push_back(p);
					if(emitted_at(p) == 0)
						continue;
				}
				const bool edge = (x == lc.getX() || x == uc.getX() ||
						y == lc.getY() || y == uc.getY() ||
						z == lc.getZ() || z == uc.getZ());
				if(!edge && emitted_at(p) == 0)
					continue;
				// "It was a blocker and is not any more" is the shape the
				// flood reads as "fill this one from what is around it",
				// which is what every one of these wants
				m_light_seeds[lf].push_back(SkylightSeed{p, 0, false, 0, true});
				seeded++;
			}
		}
		// BUILDAT_LIGHT_LOG=1: what a relight seeded and how much of it the
		// sky reaches, which is the one thing that decides whether the
		// flood has any daylight to put back. "0 of them under open sky"
		// is a relight that can only zero the section, and it is what a
		// world going dark looks like from in here ([UNDERGROUND_LIGHT]).
		if(getenv("BUILDAT_LIGHT_LOG")){
			size_t open = 0;
			for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++)
				for(const SkylightSeed &sd : m_light_seeds[f])
					if(is_below_open_sky(sd.p, true))
						open++;
			log_w(MODULE, "relight " PV3I_FORMAT ": %zu seeds, %zu of them "
					"under open sky, %zu blockers; the middle column opens "
					"at y %i and the section's top is y %i",
					PV3I_PARAMS(section.section_p), seeded, open,
					blockers.size(),
					(int)open_sky_from((lc.getX() + uc.getX()) / 2,
							(lc.getZ() + uc.getZ()) / 2), (int)uc.getY());
		}
		if(seeded == 0){
			clear_mark();
			return;
		}
		const int64_t t_flood = interface::os::time_us();
		m_relight_blockers = blockers;
		m_relight_finish_f = 0;
		m_relight_finish_i = 0;
		m_relight_pending = true;
		m_relight_key = key;
		bool done = update_skylight_until(deadline_us);
		const int64_t t_finish = interface::os::time_us();
		if(done)
			done = relight_finish(deadline_us);
		log_v(MODULE, "Section " PV3I_FORMAT ": light was stale, %zu seeds, "
				"%zu blockers; the pass %i ms, the flood %i ms, the faces "
				"%i ms%s",
				PV3I_PARAMS(section.section_p), seeded, blockers.size(),
				(int)((t_flood - t_seed) / 1000),
				(int)((t_finish - t_flood) / 1000),
				(int)((interface::os::time_us() - t_finish) / 1000),
				done ? "" : " so far, the rest next tick");
	}

	// Generate the section; requires static nodes to already exist
	void generate_section(Section &section)
	{
		if(section.generated)
			return;
		// What a generator writes is the light it writes; a stale mark from
		// before it existed means nothing
		if(m_stale_sections.erase(section_key(section.section_p)) > 0)
			m_stale_dirty = true;
		section.generated = true;
		section.awaiting = true;
		// Whatever the generator makes of it is not in the save, and a
		// generator that writes nothing at all still ran
		section.modified = true;
		pv::Vector3DInt16 section_p = section.section_p;
		log_v(MODULE, "Section will be generated: " PV3I_FORMAT,
				PV3I_PARAMS(section_p));
		m_server->emit_event("voxelworld:generation_request",
				new GenerationRequest(m_scene_ref, section_p));
	}

	void mark_node_for_physics_update(uint node_id)
	{
		if(!m_physics_enabled)
			return;
		QueuedNodePhysicsUpdate update(node_id);
		auto it = std::lower_bound(m_nodes_needing_physics_update.begin(),
				m_nodes_needing_physics_update.end(), update,
				std::greater<QueuedNodePhysicsUpdate>());
		if(it == m_nodes_needing_physics_update.end()){
			m_nodes_needing_physics_update.insert(it, update);
		} else if(it->node_id != node_id){
			m_nodes_needing_physics_update.insert(it, update);
		} else {
			*it = update;
		}
	}

	// Should be called before the volume is serialized so that the hook can
	// modify the volume
	void run_commit_hooks_in_thread(
			const pv::Vector3DInt32 &chunk_p,
			VoxelVolume &volume)
	{
		for(up_<CommitHook> &hook : m_commit_hooks)
			hook->in_thread(this, chunk_p, volume);
	}

	void run_commit_hooks_in_scene(
			const pv::Vector3DInt32 &chunk_p, Node *n)
	{
		for(up_<CommitHook> &hook : m_commit_hooks)
			hook->in_scene(this, chunk_p, n);
	}

	void unload_old_buffers(int64_t unload_timeout, size_t max_buffers)
	{
		if(m_keep_loaded)
			return;
		// Swap out the current set
		std::vector<Section*> sections_with_loaded_buffers;
		sections_with_loaded_buffers.swap(m_sections_with_loaded_buffers);
		// Allocate a new set to put back stuff that is still loaded
		m_sections_with_loaded_buffers.reserve(
				sections_with_loaded_buffers.size());
		// Go through the swapped set, putting back sections that are still loaded
		m_total_buffers_loaded = 0;
		m_total_buffers_dirty = 0;
		for(Section *section : sections_with_loaded_buffers){
			size_t num_loaded = 0;
			for(size_t i = 0; i < section->chunk_buffers.size(); i++){
				ChunkBuffer &chunk_buffer = section->chunk_buffers[i];
				bool unloaded = chunk_buffer.unload_if_old(unload_timeout);
				if(!unloaded){
					num_loaded++;
					m_total_buffers_loaded++;
					if(chunk_buffer.dirty)
						m_total_buffers_dirty++;
				}
			}
			if(num_loaded > 0)
				m_sections_with_loaded_buffers.push_back(section);
		}
		// Call recursively if too many buffers are still loaded
		if(unload_timeout > 1000 && m_total_buffers_loaded > max_buffers)
			unload_old_buffers(unload_timeout / 4, max_buffers);
	}

	void maintain_maximum_buffer_limit()
	{
		if(m_total_buffers_loaded > m_max_buffers_loaded)
			unload_old_buffers(m_buffer_unload_timeout, m_max_buffers_loaded);
	}

	// Interface

	interface::VoxelRegistry* get_voxel_reg()
	{
		return m_voxel_reg.get();
	}

	// Which bits of a voxel the sky light is in, which is the game's to
	// decide; see VoxelFormat in interface/voxel.h. A game sets its format
	// through get_voxel_reg()->set_format() before it generates anything,
	// so this is read rather than cached.
	const interface::VoxelField& light_field(
			voxelworld::Instance::LightField f = LIGHT_SKY)
	{
		const interface::VoxelFormat &fmt = m_voxel_reg->get_format();
		return (f == LIGHT_LAMP) ? fmt.light_lamp : fmt.light_sky;
	}

	const interface::VoxelField& sky_field()
	{
		return light_field(LIGHT_SKY);
	}

	uint8_t light_max(voxelworld::Instance::LightField f = LIGHT_SKY)
	{
		return (uint8_t)light_field(f).mask();
	}

	uint8_t sky_max()
	{
		return light_max(LIGHT_SKY);
	}

	// The voxel's type, through the format the game chose. Not
	// VoxelInstance::get_id(), which is the default format's bit range and
	// would read a game's own light, parameter and simulation bits as part
	// of the id.
	interface::VoxelTypeId get_id(const VoxelInstance &v)
	{
		return m_voxel_reg->get_format().id_of(v.data);
	}

	// One plane's word as a whole voxel, for a world that has only the one
	static interface::VoxelSample sample_of(const VoxelInstance &v)
	{
		interface::VoxelSample s;
		s.planes[0] = v.data;
		return s;
	}

	bool is_undefined(const VoxelInstance &v)
	{
		return get_id(v) == interface::VOXELTYPEID_UNDEFINED;
	}

	uint8_t get_light(const VoxelInstance &v,
			voxelworld::Instance::LightField f = LIGHT_SKY)
	{
		return (uint8_t)light_field(f).get(v.data);
	}

	void set_light(VoxelInstance &v, uint8_t level,
			voxelworld::Instance::LightField f = LIGHT_SKY)
	{
		light_field(f).set(v.data, level);
	}

	uint8_t get_sky(const VoxelInstance &v)
	{
		return get_light(v, LIGHT_SKY);
	}

	void set_sky(VoxelInstance &v, uint8_t level)
	{
		set_light(v, level, LIGHT_SKY);
	}

	void add_commit_hook(up_<CommitHook> hook)
	{
		m_commit_hooks.push_back(std::move(hook));
	}

	pv::Vector3DInt16 get_section_size_voxels()
	{
		return pv::Vector3DInt16(
				m_section_size_chunks.getX() * m_chunk_size_voxels.getX(),
				m_section_size_chunks.getY() * m_chunk_size_voxels.getY(),
				m_section_size_chunks.getZ() * m_chunk_size_voxels.getZ()
		);
	}

	pv::Region get_section_region_voxels(const pv::Vector3DInt16 &section_p)
	{
		pv::Vector3DInt32 p0 = pv::Vector3DInt32(
				section_p.getX() * m_section_size_chunks.getX() *
				m_chunk_size_voxels.getX(),
				section_p.getY() * m_section_size_chunks.getY() *
				m_chunk_size_voxels.getY(),
				section_p.getZ() * m_section_size_chunks.getZ() *
				m_chunk_size_voxels.getZ()
		);
		pv::Vector3DInt32 p1 = p0 + pv::Vector3DInt32(
				m_section_size_chunks.getX() * m_chunk_size_voxels.getX() - 1,
				m_section_size_chunks.getY() * m_chunk_size_voxels.getY() - 1,
				m_section_size_chunks.getZ() * m_chunk_size_voxels.getZ() - 1
		);
		return pv::Region(p0, p1);
	}

	const pv::Vector3DInt16& get_chunk_size_voxels()
	{
		return m_chunk_size_voxels;
	}

	pv::Region get_chunk_region_voxels(const pv::Vector3DInt32 &chunk_p)
	{
		pv::Vector3DInt32 p0 = pv::Vector3DInt32(
				chunk_p.getX() * m_chunk_size_voxels.getX(),
				chunk_p.getY() * m_chunk_size_voxels.getY(),
				chunk_p.getZ() * m_chunk_size_voxels.getZ()
		);
		pv::Vector3DInt32 p1 = p0 + pv::Vector3DInt32(
				m_chunk_size_voxels.getX() - 1,
				m_chunk_size_voxels.getY() - 1,
				m_chunk_size_voxels.getZ() - 1
		);
		return pv::Region(p0, p1);
	}

	void load_or_generate_section(const pv::Vector3DInt16 &section_p)
	{
		Section &section = force_get_section(section_p);
		if(!section.loaded)
			load_section(section);
		if(!section.generated)
			generate_section(section);
	}

	void load_section_no_generate(const pv::Vector3DInt16 &section_p)
	{
		// Not one the streamer will unload on its next pass: a mapgen
		// mod's write below the world's bottom section made two sections
		// of scene nodes for the streamer to take down at once, 500 ms in
		// the step ([STEP_SLICE]). What is written there is dropped, as
		// Luanti drops a vmanip's writes outside its emerged area.
		if(!m_load_points.empty() && !is_wanted_loaded(section_p)){
			log_v(MODULE, "A write into section " PV3I_FORMAT " outside the "
					"load range is dropped", PV3I_PARAMS(section_p));
			return;
		}
		Section &section = force_get_section(section_p);
		if(!section.loaded)
			load_section(section);
	}

	void set_load_points(const sv_<voxelworld::LoadPoint> &points)
	{
		m_load_points = points;
		m_streaming = true;
		// A peer whose point moved into another section is sent another set
		// of chunks, and replicate has no other way of knowing that it did
		sv_<replicate::PeerId> moved;
		{
			std::lock_guard<std::mutex> lock(m_send_mutex);
			m_peer_points.clear();
			for(const voxelworld::LoadPoint &lp : points){
				if(lp.peer == 0)
					continue;
				m_peer_points[lp.peer] = lp;
				pv::Vector3DInt16 sp = section_of_voxel(lp.p);
				auto it = m_peer_section.find(lp.peer);
				if(it != m_peer_section.end() && it->second == sp)
					continue;
				m_peer_section[lp.peer] = sp;
				moved.push_back(lp.peer);
			}
		}
		if(moved.empty())
			return;
		replicate::access(m_server, [&](replicate::Interface *irep){
			for(replicate::PeerId peer : moved)
				irep->refresh_peer_nodes(m_scene_ref, peer);
		});
	}

	sv_<pv::Vector3DInt16> get_loaded_sections()
	{
		sv_<pv::Vector3DInt16> result;
		for(auto &sector : m_sections){
			for(auto &pair : sector.second){
				if(pair.second.loaded)
					result.push_back(pair.second.section_p);
			}
		}
		return result;
	}

	void set_stream_budget(size_t sections_per_pass)
	{
		m_stream_budget = sections_per_pass;
	}

	void unload_section(const pv::Vector3DInt16 &section_p)
	{
		Section *section = get_section(section_p);
		if(!section || !section->loaded)
			return;

		log_v(MODULE, "Unloading section " PV3I_FORMAT, PV3I_PARAMS(section_p));

		// Before the voxels go, so that a game writing something of its own
		// out with the section still has the section to look at
		m_server->emit_event("voxelworld:section_unloaded",
				new SectionUnloaded(m_scene_ref, section_p));

		if(m_store){
			// What the nodes hold is what has been committed; the buffers
			// below are dropped without one
			commit();
			save_section(*section);
		}

		for(ChunkBuffer &buf : section->chunk_buffers){
			if(!buf.volume)
				continue;
			m_total_buffers_loaded--;
			if(buf.dirty)
				m_total_buffers_dirty--;
			buf.volume.reset();
			buf.dirty = false;
		}

		m_sections_with_loaded_buffers.erase(
				std::remove(m_sections_with_loaded_buffers.begin(),
				m_sections_with_loaded_buffers.end(), section),
				m_sections_with_loaded_buffers.end());

		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			auto lc = section->contained_chunks.getLowerCorner();
			auto uc = section->contained_chunks.getUpperCorner();
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int y = lc.getY(); y <= uc.getY(); y++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						uint id = section->node_ids->getVoxelAt(x, y, z);
						if(id)
							unload_node(scene, id);
					}
				}
			}
		});

		// Out of the caches only now, right before it goes: the access
		// above can come back here and look the section up, which puts it
		// in the cache again and left a freed section there to be read
		forget_cached(section);

		pv::Vector<2, int16_t> p_yz(section_p.getY(), section_p.getZ());
		auto sector_it = m_sections.find(p_yz);
		if(sector_it == m_sections.end())
			return;
		sector_it->second.erase(section_p.getX());
		if(sector_it->second.empty())
			m_sections.erase(sector_it);
	}

	// Every pointer to a section kept between calls
	void forget_cached(Section *section)
	{
		m_last_used_sections.erase(
				std::remove(m_last_used_sections.begin(),
				m_last_used_sections.end(), section),
				m_last_used_sections.end());
		if(m_light_section == section){
			m_light_section = nullptr;
			m_light_buf = nullptr;
		}
	}

	bool is_section_loaded(const pv::Vector3DInt16 &section_p)
	{
		Section *section = get_section(section_p);
		return section && section->loaded;
	}

	ss_ registry_key(){ return m_world_name+"/registry"; }
	ss_ names_key(){ return m_world_name+"/names"; }
	ss_ formats_key(){ return m_world_name+"/formats"; }
	ss_ stale_key(){ return m_world_name+"/light_stale"; }

	// Sections the light reached while they were not in memory. What they
	// hold may be wrong in either direction -- a blocker put up next to
	// them, or one taken away -- and they are re-flooded when they are
	// loaded. Persisted, because a world that is closed and opened again
	// has the same wrong light in it. See "Crossing a section boundary" in
	// doc/plan/voxel_data_model_plan.md.
	set_<uint64_t> m_stale_sections;
	bool m_stale_dirty = false;

	// Sections relight_region_later() has marked, in order; a section
	// loaded or unloaded meanwhile is simply not there when its turn comes
	std::deque<pv::Vector3DInt16> m_relight_queue;
	bool m_light_deferred = false;
	void set_light_deferred(bool on)
	{
		m_light_deferred = on;
	}

	void mark_section_stale(const pv::Vector3DInt16 &section_p)
	{
		if(m_stale_sections.insert(section_key(section_p)).second)
			m_stale_dirty = true;
	}

	// See relight_region() in api.h: every section the region touches has
	// its light taken out and let back in, now rather than when it is next
	// loaded.
	void relight_region(const pv::Region &region)
	{
		const pv::Vector3DInt16 lc = section_of_voxel(region.getLowerCorner());
		const pv::Vector3DInt16 uc = section_of_voxel(region.getUpperCorner());
		size_t n = 0;
		for(int16_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int16_t y = lc.getY(); y <= uc.getY(); y++)
		for(int16_t x = lc.getX(); x <= uc.getX(); x++){
			const pv::Vector3DInt16 section_p(x, y, z);
			Section *section = get_section(section_p);
			if(section == nullptr)
				continue;
			mark_section_stale(section_p);
			relight_if_stale(*section);
			n++;
		}
		if(n > 0)
			log_d(MODULE, "relight_region(): %zu sections", n);
	}

	void relight_region_later(const pv::Region &region)
	{
		const pv::Vector3DInt16 lc = section_of_voxel(region.getLowerCorner());
		const pv::Vector3DInt16 uc = section_of_voxel(region.getUpperCorner());
		for(int16_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int16_t y = lc.getY(); y <= uc.getY(); y++)
		for(int16_t x = lc.getX(); x <= uc.getX(); x++){
			const pv::Vector3DInt16 section_p(x, y, z);
			if(get_section(section_p) == nullptr)
				continue;
			mark_section_stale(section_p);
			m_relight_queue.push_back(section_p);
		}
	}

	// When a game last called relight_stale(): until a second after, the
	// tick leaves a pending flood to it
	int64_t m_relight_stale_us = 0;
	static const int64_t RELIGHT_IDLE_US = 1000000;
	static const int64_t TICK_RELIGHT_BUDGET_US = 20000;

	size_t relight_stale(int64_t budget_us, int64_t near_budget_us = 0,
			int near_sections = 2)
	{
		const int64_t t0 = interface::os::time_us();
		m_relight_stale_us = t0;
		int64_t deadline = t0 + budget_us;
		// The near budget while the nearest stale section is close to a
		// load point (the pending flood counts as near: it was picked so)
		if(near_budget_us > budget_us && !m_load_points.empty()){
			bool is_near = m_relight_pending;
			const int64_t r2 = (int64_t)near_sections * near_sections;
			for(size_t i = 0; i < m_relight_queue.size() && !is_near; i++){
				const pv::Vector3DInt16 &sp = m_relight_queue[i];
				for(const voxelworld::LoadPoint &lp : m_load_points){
					const pv::Vector3DInt16 lps = section_of_voxel(lp.p);
					int64_t dx = (int64_t)sp.getX() - lps.getX();
					int64_t dy = (int64_t)sp.getY() - lps.getY();
					int64_t dz = (int64_t)sp.getZ() - lps.getZ();
					if(dx * dx + dy * dy + dz * dz <= r2){
						is_near = true;
						break;
					}
				}
			}
			if(is_near)
				deadline = t0 + near_budget_us;
		}
		// A flood a previous tick left unfinished comes first
		if(!relight_continue(deadline))
			return m_relight_queue.size() + 1;
		size_t done = 0;
		while(!m_relight_queue.empty()){
			if(interface::os::time_us() >= deadline)
				break;
			// The section nearest a load point first, not the first queued:
			// a jungle spawn's own canopy sat black for a minute while the
			// relight worked through 185 sections in the order the mapgen
			// wrote them ([SEED5_SETTLE], 2026-09-20)
			size_t best = 0;
			if(!m_load_points.empty()){
				int64_t best_d = INT64_MAX;
				for(size_t i = 0; i < m_relight_queue.size(); i++){
					const pv::Vector3DInt16 &sp = m_relight_queue[i];
					int64_t d = INT64_MAX;
					for(const voxelworld::LoadPoint &lp : m_load_points){
						const pv::Vector3DInt16 lps = section_of_voxel(lp.p);
						int64_t dx = (int64_t)sp.getX() - lps.getX();
						int64_t dy = (int64_t)sp.getY() - lps.getY();
						int64_t dz = (int64_t)sp.getZ() - lps.getZ();
						int64_t dd = dx * dx + dy * dy + dz * dz;
						if(dd < d)
							d = dd;
					}
					if(d < best_d){
						best_d = d;
						best = i;
					}
				}
			}
			const pv::Vector3DInt16 section_p = m_relight_queue[best];
			m_relight_queue.erase(m_relight_queue.begin() + best);
			Section *section = get_section(section_p);
			if(section != nullptr){
				relight_if_stale(*section, deadline);
				done++;
				if(m_relight_pending)
					return m_relight_queue.size() + 1;
			}
		}
		if(done > 0)
			log_d(MODULE, "relight_stale(): %zu sections, %zu queued", done,
					m_relight_queue.size());
		return m_relight_queue.size();
	}

	void load_stale_sections()
	{
		m_stale_sections.clear();
		m_stale_dirty = false;
		if(!m_store)
			return;
		ss_ data;
		if(!m_store->get(stale_key(), data))
			return;
		std::istringstream is(data, std::ios::binary);
		cereal::PortableBinaryInputArchive ar(is);
		uint8_t version = 0;
		ar(version);
		if(version != 1)
			return;
		sv_<uint64_t> keys;
		ar(keys);
		for(uint64_t k : keys)
			m_stale_sections.insert(k);
		if(!m_stale_sections.empty())
			log_v(MODULE, "World \"%s\": %zu sections with stale light",
					cs(m_world_name), m_stale_sections.size());
	}

	void save_stale_sections()
	{
		if(!m_store || !m_stale_dirty)
			return;
		sv_<uint64_t> keys(m_stale_sections.begin(), m_stale_sections.end());
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)1, keys);
		}
		m_store->set(stale_key(), os.str());
		m_stale_dirty = false;
	}

	void set_name_aliases(const std::map<ss_, ss_> &aliases)
	{
		m_name_aliases = aliases;
	}

	void set_save(storage::Save *save, const ss_ &world_name)
	{
		m_aliased_save_ids.clear();
		m_save_path = save ? save->path() : ss_();
		m_save = save;
		m_world_full = false;
		m_world_measured_us = 0;
		if(!save){
			m_store = nullptr;
			m_world_name = "";
			m_save_names.clear();
			m_save_id_of_name.clear();
			m_save_to_session.clear();
			m_session_to_save.clear();
			m_save_formats.clear();
			m_saved_reg.reset();
			return;
		}
		m_store = save->store("voxelworld");
		m_world_name = world_name;
		load_name_table();
		load_format_table();
		load_stale_sections();
	}

	// The save holds something this build must not overwrite: a chunk in a
	// cut nothing here can move it out of, or a voxel type with no name this
	// game or the save can put to it. Stop touching the save altogether
	// rather than guess -- what is on disk is somebody's world, and a wrong
	// guess written over it cannot be undone.
	void refuse_save(const ss_ &why)
	{
		log_e(MODULE, "World \"%s\": %s. The save is neither read nor written "
				"any further; migrating it is the game's to do.",
				cs(m_world_name), cs(why));
		m_store = nullptr;
	}

	void load_name_table()
	{
		m_save_names.clear();
		m_save_id_of_name.clear();
		m_save_to_session.clear();
		m_session_to_save.clear();
		m_save_names_dirty = false;
		m_names_synced_to = 0;
		m_registry_saved_to = (interface::VoxelTypeId)-1;
		ss_ data;
		if(m_store->get(names_key(), data)){
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			if(version != 1)
				throw Exception(ss_()+"voxelworld: the name table of world \""+
						m_world_name+"\" is version "+itos(version)+
						" and this build writes 1");
			ar(m_save_names);
		}
		// Save id 0 is VOXELTYPEID_UNDEFINED under every format, and is not
		// a name
		if(m_save_names.empty())
			m_save_names.resize(1);
		// A save written before there was a name table carries the registry
		// it was written under instead, and that registry *is* the numbering
		// its chunks are in. Seeding the table from it is what keeps such a
		// save readable by a game that has since registered its types in
		// another order -- without this the ids would quietly mean something
		// else.
		if(m_save_names.size() == 1)
			seed_name_table_from_saved_registry();
		for(size_t i = 1; i < m_save_names.size(); i++)
			m_save_id_of_name[m_save_names[i].dump()] =
					(interface::VoxelTypeId)i;
	}

	void seed_name_table_from_saved_registry()
	{
		if(!load_saved_registry())
			return;
		interface::VoxelTypeId num = m_saved_reg->num_voxels();
		for(interface::VoxelTypeId id = 1; id <= num; id++){
			const interface::VoxelDefinition *def = m_saved_reg->get(id);
			if(!def)
				break;
			m_save_names.push_back(def->name);
		}
		if(m_save_names.size() > 1){
			m_save_names_dirty = true;
			log_v(MODULE, "World \"%s\": name table seeded with %zu names "
					"from the registry the save carries",
					cs(m_world_name), m_save_names.size() - 1);
		}
	}

	bool load_saved_registry()
	{
		if(m_saved_reg)
			return true;
		ss_ data;
		if(!m_store->get(registry_key(), data))
			return false;
		m_saved_reg.reset(interface::createVoxelRegistry());
		m_saved_reg->deserialize(data);
		return true;
	}

	void save_name_table()
	{
		if(!m_store || !m_save_names_dirty)
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)1, m_save_names);
		}
		m_store->set(names_key(), os.str());
		m_save_names_dirty = false;
	}

	// The save's id for a name, appending it if the save has not seen it.
	// The table only ever grows, which is what keeps a chunk written under
	// an older one valid.
	interface::VoxelTypeId save_id_of(const interface::VoxelName &name)
	{
		ss_ key = name.dump();
		auto it = m_save_id_of_name.find(key);
		if(it != m_save_id_of_name.end())
			return it->second;
		m_save_names.push_back(name);
		interface::VoxelTypeId id =
				(interface::VoxelTypeId)(m_save_names.size() - 1);
		m_save_id_of_name[key] = id;
		m_save_names_dirty = true;
		return id;
	}

	// A voxel type the save has and the game no longer registers. It gets a
	// session id of its own so that its word travels whole and it is written
	// back under the same name, and it is drawn with the definition the save
	// carries -- so a dropped type still looks like itself in an old world.
	//
	// What that would hide is that the game does not support it any more, so
	// every variant of it is tinted. Honest limitation: the tint multiplies
	// the vertex colour, which is light and not albedo, so in the dark an
	// unknown voxel looks like everything else.
	const interface::VoxelDefinition* adopt_unknown_voxel(
			const interface::VoxelName &name)
	{
		if(!load_saved_registry())
			return nullptr;
		const interface::VoxelDefinition *saved = m_saved_reg->get(name);
		if(!saved)
			return nullptr;
		interface::VoxelDefinition def = *saved;
		def.id = interface::VOXELTYPEID_UNDEFINED;
		// A definition with no variants has one now, which is the plain cube
		// with somewhere to put the tint; variant_of_param is all zeroes, so
		// every param value finds it
		if(def.variants.empty())
			def.variants.resize(1);
		for(interface::VoxelVariant &v : def.variants)
			v.color = UNKNOWN_VOXEL_TINT;
		interface::VoxelTypeId id = m_voxel_reg->add_voxel(def);
		log_w(MODULE, "World \"%s\": the save has voxel type %s, which this "
				"game does not register. It is kept and drawn with the "
				"definition the save carries, tinted.",
				cs(m_world_name), cs(name.dump()));
		m_unknown_voxels.push_back(name);
		return m_voxel_reg->get(id);
	}

	// save id -> session id and back, worked out by name.
	//
	// Called before a section is read or written rather than once, because
	// the game goes on registering voxel types after set_save(): a name that
	// does not resolve now may resolve later, and a type registered later
	// still has to reach the table before anything holding it is written.
	// Both loops normally do nothing at all.
	void update_id_maps()
	{
		// What cached_of() remembers is about a registry that may be about
		// to gain a type. Nothing that is already in it changes, but this is
		// the cheap place to be sure.
		m_def_memo = nullptr;
		// Every type the game has registered goes into the table first, so
		// that writing a chunk cannot come across a name the save has no id
		// for. Appending in id order is what keeps the identity case the
		// identity.
		interface::VoxelTypeId num = m_voxel_reg->num_voxels();
		for(interface::VoxelTypeId id = m_names_synced_to + 1; id <= num; id++){
			const interface::VoxelDefinition *def = m_voxel_reg->get(id);
			if(!def)
				break;
			interface::VoxelTypeId save_id = save_id_of(def->name);
			if(save_id >= m_save_to_session.size())
				m_save_to_session.resize(save_id + 1, 0);
			m_save_to_session[save_id] = id;
			m_names_synced_to = id;
		}
		// What is left is a name the save has and the game does not register
		m_save_to_session.resize(m_save_names.size(), 0);
		// A renamed type, registered or not (Luanti's register_alias_force
		// keeps the old one's id): the voxel its alias names, written back
		// under that name (the reverse map below skips this save id)
		for(size_t i = 1; !m_name_aliases.empty() &&
				i < m_save_names.size(); i++){
			auto al = m_name_aliases.find(m_save_names[i].block_name);
			if(al == m_name_aliases.end() || m_aliased_save_ids.count(i))
				continue;
			interface::VoxelName n = m_save_names[i];
			n.block_name = al->second;
			const interface::VoxelDefinition *d = m_voxel_reg->get(n);
			if(d){
				m_save_to_session[i] = d->id;
				m_aliased_save_ids.insert(i);
			}
		}
		for(size_t i = 1; i < m_save_names.size(); i++){
			if(m_save_to_session[i] != 0)
				continue; // Resolved once and for all: nothing is unregistered
			const interface::VoxelDefinition *def =
					adopt_unknown_voxel(m_save_names[i]);
			if(!def){
				refuse_save("the save holds voxel type "+
						m_save_names[i].dump()+", which this game does not "
						"register and the save's own definitions do not "
						"describe");
				return;
			}
			m_save_to_session[i] = def->id;
			if(def->id >= m_names_synced_to)
				m_names_synced_to = def->id;
		}
		m_session_to_save.assign(m_names_synced_to + 1, 0);
		for(size_t i = 1; i < m_save_to_session.size(); i++){
			interface::VoxelTypeId sid = m_save_to_session[i];
			if(m_aliased_save_ids.count(i))
				continue;
			if(sid != 0 && sid < m_session_to_save.size())
				m_session_to_save[sid] = (interface::VoxelTypeId)i;
		}
		m_id_map_identity = true;
		for(size_t i = 1; i < m_save_to_session.size(); i++){
			if(m_save_to_session[i] != i){
				m_id_map_identity = false;
				break;
			}
		}
		for(size_t i = 1; m_id_map_identity && i < m_session_to_save.size();
				i++){
			if(m_session_to_save[i] != i)
				m_id_map_identity = false;
		}
		if(!m_id_map_identity && !m_logged_remap){
			m_logged_remap = true;
			size_t n = 0;
			for(size_t i = 1; i < m_save_to_session.size(); i++)
				if(m_save_to_session[i] != i)
					n++;
			log_i(MODULE, "World \"%s\": the save's voxel numbering is not "
					"this run's; %zu of %zu names are read and written through "
					"the table", cs(m_world_name), n,
					m_save_names.size() - 1);
		}
	}

	// The formats the save's chunks are in. A save may hold a mix and that
	// is the point: chunks are independent, so nothing is rewritten that was
	// not modified, and one damaged chunk is one damaged chunk.
	void load_format_table()
	{
		m_save_formats.clear();
		m_write_format = 0;
		ss_ data;
		if(m_store->get(formats_key(), data)){
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			if(version != 1)
				throw Exception(ss_()+"voxelworld: the format table of world "
						"\""+m_world_name+"\" is version "+itos(version)+
						" and this build writes 1");
			ar(m_save_formats);
		}
		const interface::VoxelFormat &format = m_voxel_reg->get_format();
		for(size_t i = 0; i < m_save_formats.size(); i++){
			if(m_save_formats[i] == format){
				m_write_format = (uint16_t)i;
				return;
			}
		}
		m_save_formats.push_back(format);
		m_write_format = (uint16_t)(m_save_formats.size() - 1);
		save_format_table();
		if(m_save_formats.size() > 1)
			log_i(MODULE, "World \"%s\": %s is new to this save, which holds "
					"%zu formats now", cs(m_world_name), cs(format.dump()),
					m_save_formats.size());
	}

	void save_format_table()
	{
		if(!m_store)
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)1, m_save_formats);
		}
		m_store->set(formats_key(), os.str());
	}

	// The definitions themselves, so that a type the game stops registering
	// can still be drawn and still has a name. Not the authority on
	// numbering -- the name table is -- and written again whenever the game
	// has registered something since.
	void save_registry()
	{
		if(!m_store || m_registry_saved_to == m_names_synced_to)
			return;
		m_store->set(registry_key(), m_voxel_reg->serialize());
		m_registry_saved_to = m_names_synced_to;
	}

	sv_<interface::VoxelName> get_unknown_voxels()
	{
		return m_unknown_voxels;
	}

	void save()
	{
		if(!m_store)
			return;
		commit();
		save_stale_sections();
		size_t n = 0, total = 0;
		for(auto &sector_pair : m_sections){
			for(auto &section_pair : sector_pair.second){
				total++;
				if(!m_store) // A section can refuse the save
					continue;
				if(!section_pair.second.modified &&
						!section_pair.second.index_dirty)
					continue;
				save_section(section_pair.second);
				n++;
			}
		}
		log_v(MODULE, "World \"%s\": saved %zu sections of %zu",
				cs(m_world_name), n, total);
	}

	sv_<voxelworld::SectionStat> section_stats()
	{
		sv_<voxelworld::SectionStat> out;
		if(!m_store)
			return out;
		const ss_ prefix = m_world_name+"/s";
		const ss_ suffix = "/generated";
		for(const ss_ &key : m_store->list(prefix)){
			int x = 0, y = 0, z = 0;
			if(key.size() <= prefix.size() + suffix.size() ||
					key.compare(key.size() - suffix.size(), suffix.size(),
					suffix) != 0 ||
					sscanf(key.c_str() + prefix.size(), "%i,%i,%i",
					&x, &y, &z) != 3)
				continue;
			ss_ v;
			if(!m_store->get(key, v))
				continue;
			voxelworld::SectionStat s = parse_index_row(v);
			s.p = pv::Vector3DInt16(x, y, z);
			Section *section = get_section(s.p);
			if(section && section->loaded){
				s.loaded = true;
				s.altered = section->altered;
				s.day = section->visited_day;
			}
			out.push_back(s);
		}
		return out;
	}

	size_t forget_sections(const sv_<pv::Vector3DInt16> &list)
	{
		if(!m_store)
			return 0;
		sv_<pv::Vector3DInt16> gone;
		m_store->batch([&](){
			for(const pv::Vector3DInt16 &p : list){
				Section *section = get_section(p);
				if(section && section->loaded)
					continue;
				const pv::Vector3DInt32 lc(
						p.getX() * m_section_size_chunks.getX(),
						p.getY() * m_section_size_chunks.getY(),
						p.getZ() * m_section_size_chunks.getZ());
				for(int z = 0; z < m_section_size_chunks.getZ(); z++)
				for(int y = 0; y < m_section_size_chunks.getY(); y++)
				for(int x = 0; x < m_section_size_chunks.getX(); x++)
					m_store->remove(chunk_key(pv::Vector3DInt32(
							lc.getX() + x, lc.getY() + y, lc.getZ() + z)));
				m_store->remove(generated_key(p));
				if(m_stale_sections.erase(section_key(p)) > 0)
					m_stale_dirty = true;
				gone.push_back(p);
			}
			save_stale_sections();
		});
		if(gone.empty())
			return 0;
		log_v(MODULE, "World \"%s\": forgot %zu sections", cs(m_world_name),
				gone.size());
		m_server->emit_event("voxelworld:sections_forgotten",
				new SectionsForgotten(m_scene_ref, gone));
		return gone.size();
	}

	size_t trim_to(int64_t target_bytes, int altered_days)
	{
		if(!m_store || !m_save)
			return 0;
		const int64_t have = m_save->bytes();
		if(have <= target_bytes)
			return 0;
		const sv_<pv::Vector3DInt16> pick = choose_forget(section_stats(),
				today(), have - target_bytes, altered_days);
		const size_t n = forget_sections(pick);
		log_i(MODULE, "World \"%s\": %lld kB, trimmed toward %lld kB: %zu "
				"sections forgotten", cs(m_world_name), (long long)(have / 1024),
				(long long)(target_bytes / 1024), n);
		return n;
	}

	ss_ m_cause;
	void set_cause(const ss_ &player_name)
	{
		m_cause = player_name;
	}
	// A write while a player's action is handled. Into a section still
	// being generated too: what a player put there is kept either way.
	void note_cause(Section *section)
	{
		if(!m_cause.empty() && !section->altered){
			section->altered = true;
			section->index_dirty = true;
		}
	}

	void save(std::function<void()> also)
	{
		m_game_checkpoints = true;
		if(!m_store){
			also();
			return;
		}
		// save() can drop m_store (a refused save) half way
		storage::Store *store = m_store;
		const int64_t t0 = interface::os::time_us();
		int64_t t_commit = 0;
		m_save_times = SaveTimes();
		store->batch([&](){
			also();
			save();
			t_commit = interface::os::time_us();
		});
		const int64_t end = interface::os::time_us();
		log_v(MODULE, "save: %i ms: %s", (int)((end - t0) / 1000),
				cs(save_times(end - t_commit)));
	}

	void set_voxel_direct(const pv::Vector3DInt32 &p,
			const interface::VoxelInstance &v)
	{
		log_t(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i",
				PV3I_PARAMS(p), v.data);
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_w(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: No section "
					" " PV3I_FORMAT " for chunk " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return;
		}
		int32_t node_id = section->node_ids->getVoxelAt(chunk_p);
		if(node_id == 0){
			log_w(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: No node for "
					"chunk " PV3I_FORMAT " in section " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return;
		}

		note_cause(section);

		// Have to commit first so that this modification doesn't get
		// overwritten by some older one
		// TODO: Commit only the current chunk
		commit();

		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			Node *n = scene->GetNode(node_id);
			const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
			const PODVector<unsigned char> &buf = var.GetBuffer();
			ss_ data((const char*)&buf[0], buf.Size());
			up_<VoxelVolume> volume =
					interface::deserialize_volume(data);

			pv::Vector3DInt32 voxel_p(
					p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
					p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
					p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
			);
			log_t(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: "
					"Chunk " PV3I_FORMAT " in section " PV3I_FORMAT
					"; internal position " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p), PV3I_PARAMS(voxel_p));
			volume->setVoxelAt(voxel_p, v);

			run_commit_hooks_in_thread(chunk_p, *volume);

			ss_ new_data = interface::serialize_volume_compressed(*volume);

			n->SetVar(StringHash("buildat_voxel_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)new_data.c_str(),
					new_data.size())));

			run_commit_hooks_in_scene(chunk_p, n);
		});

		section->modified = true;

		// Mark node for collision box update
		mark_node_for_physics_update(node_id);

		m_server->emit_event("voxelworld:node_volume_updated",
				new NodeVolumeUpdated(m_scene_ref, node_id, true, chunk_p));
	}

	// The buffer a voxel is in and where in it, or nullptr. What set_voxel(),
	// set_sample() and get_sample() all start with; each of them used to
	// carry its own copy of this.
	ChunkBuffer* buffer_for(const pv::Vector3DInt32 &p,
			pv::Vector3DInt32 *voxel_p_out, bool disable_warnings,
			const char *what)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "%s() p=" PV3I_FORMAT ": No section "
					PV3I_FORMAT " for chunk " PV3I_FORMAT,
					what, PV3I_PARAMS(p), PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return nullptr;
		}

		maintain_maximum_buffer_limit();

		ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
				&m_total_buffers_loaded);
		if(!buf.volume){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "%s() p=" PV3I_FORMAT ": Couldn't get buffer "
					"volume for chunk " PV3I_FORMAT " in section "
					PV3I_FORMAT, what, PV3I_PARAMS(p), PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return nullptr;
		}
		*voxel_p_out = pv::Vector3DInt32(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
		);

		auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
				m_sections_with_loaded_buffers.end(), section,
				std::greater<Section*>());
		if(it == m_sections_with_loaded_buffers.end() || *it != section)
			m_sections_with_loaded_buffers.insert(it, section);

		return &buf;
	}

	void mark_buffer_dirty(ChunkBuffer &buf)
	{
		if(!buf.dirty){
			buf.dirty = true;
			m_total_buffers_dirty++;
		}
	}

	void set_sample(const pv::Vector3DInt32 &p,
			const interface::VoxelSample &v, bool disable_warnings)
	{
		pv::Vector3DInt32 voxel_p;
		ChunkBuffer *buf = buffer_for(p, &voxel_p, disable_warnings,
				"set_sample");
		if(buf == nullptr)
			return;
		// A chunk written before the world had these planes, or one that
		// has never had anything but the first written into it, takes them
		// on here. The size test is what keeps this off the hot path.
		const sv_<interface::VoxelPlane> &planes =
				m_voxel_reg->get_format().planes;
		if(buf->volume->planes().size() != planes.size())
			buf->volume->add_planes(planes);

		interface::VoxelSample nv = v;
		if(m_light_maintained[LIGHT_SKY]){
			interface::VoxelSample old = buf->volume->sample_at(voxel_p);
			VoxelInstance old_first(old.planes[0]);
			VoxelInstance first(nv.planes[0]);
			bool old_transparent = voxel_transmits_light(old);
			// A write that carries light means it: a generator knows what
			// the sky reaches in the world it just made, and that light is
			// the map's from then on. A write that carries none takes the
			// light that was there and is seeded, which is every ordinary
			// set_voxel. See "the light is stored" in voxelworld's api.h.
			const bool now_transparent = voxel_transmits_light(nv);
			for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++){
				const LightField lf = (LightField)f;
				if(!m_light_maintained[lf])
					continue;
				if(get_light(first, lf) != 0)
					continue;
				if(old_transparent != now_transparent ||
						(lf == LIGHT_LAMP &&
						voxel_light_source(old) != voxel_light_source(nv))){
					if(!m_light_deferred) m_light_seeds[lf].push_back(SkylightSeed{
							p, get_light(old_first, lf), old_transparent,
							(uint8_t)(lf == LIGHT_LAMP ?
							voxel_light_source(old) : 0), false});
				}
				// A dug blocker starts dark; see set_voxel()
				set_light(first, (!old_transparent && now_transparent) ? 0 :
						get_light(old_first, lf), lf);
			}
			nv.planes[0] = first.data;
		}

		buf->volume->set_sample_at(voxel_p.getX(), voxel_p.getY(),
				voxel_p.getZ(), nv);
		mark_buffer_dirty(*buf);
	}

	interface::VoxelSample get_sample(const pv::Vector3DInt32 &p,
			bool disable_warnings)
	{
		pv::Vector3DInt32 voxel_p;
		ChunkBuffer *buf = buffer_for(p, &voxel_p, disable_warnings,
				"get_sample");
		if(buf == nullptr)
			return interface::VoxelSample();
		return buf->volume->sample_at(voxel_p);
	}

	void set_voxel(const pv::Vector3DInt32 &p, const interface::VoxelInstance &v,
			bool disable_warnings)
	{
		// Don't log here; this is a too busy place for even ignored log calls
		/*log_t(MODULE, "set_voxel() p=" PV3I_FORMAT ", v=%i",
				PV3I_PARAMS(p), v.data);*/
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "set_voxel() p=" PV3I_FORMAT ", v=%i: No section "
					PV3I_FORMAT " for chunk " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return;
		}

		note_cause(section);

		// Unload stuff if needed
		maintain_maximum_buffer_limit();

		// Set in buffer
		ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
				&m_total_buffers_loaded);
		if(!buf.volume){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "set_voxel() p=" PV3I_FORMAT ", v=%i: Couldn't get "
					"buffer volume for chunk " PV3I_FORMAT " in section "
					PV3I_FORMAT, PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return;
		}
		pv::Vector3DInt32 voxel_p(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
		);
		VoxelInstance nv = v;
		if(m_light_maintained[LIGHT_SKY]){
			// The whole voxel, because which definition it wears can depend
			// on any of its planes; only the first one is being written
			interface::VoxelSample old = buf.volume->sample_at(voxel_p);
			interface::VoxelSample now = old;
			now.planes[0] = v.data;
			VoxelInstance old_first(old.planes[0]);
			bool old_transparent = voxel_transmits_light(old);
			// A voxel written with light of its own keeps it: that is a
			// generator saying what the sky reaches where it has just
			// built. Written without, the light is voxelworld's -- it is
			// carried over from the voxel that was there, because a caller
			// writing a plain voxel would otherwise wipe out the light of
			// one whose transparency did not change and nothing would put
			// it back, and the change is seeded so the flood can fix it.
			const bool now_transparent = voxel_transmits_light(now);
			for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++){
				const LightField lf = (LightField)f;
				if(!m_light_maintained[lf])
					continue;
				if(get_light(nv, lf) != 0)
					continue;
				if(old_transparent != now_transparent ||
						(lf == LIGHT_LAMP &&
						voxel_light_source(old) != voxel_light_source(now))){
					if(!m_light_deferred) m_light_seeds[lf].push_back(SkylightSeed{
							p, get_light(old_first, lf), old_transparent,
							(uint8_t)(lf == LIGHT_LAMP ?
							voxel_light_source(old) : 0), false});
				}
				// Not from a blocker that has just been dug out: what a
				// blocker wears is the brightest light beside it, for the
				// mesher's sake, and carried into the air it becomes the
				// flood spreads it on as the air's own -- a stair dug
				// sideways never dimmed, since each step's wall wore the
				// step's light and was then dug ([DIG_LIGHT]). Dark, and
				// the flood fills it from around it a level lower.
				set_light(nv, (!old_transparent && now_transparent) ? 0 :
						get_light(old_first, lf), lf);
			}
		}

		buf.volume->setVoxelAt(voxel_p, nv);

		// Set buffer dirty
		if(!buf.dirty){
			buf.dirty = true;
			m_total_buffers_dirty++;
		}

		// Set section buffer loaded flag
		auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
				m_sections_with_loaded_buffers.end(), section,
				std::greater<Section*>()); // position in descending order
		if(it == m_sections_with_loaded_buffers.end() || *it != section)
			m_sections_with_loaded_buffers.insert(it, section);
	}

	// The voxels of a region in one read, chunk by chunk rather than voxel
	// by voxel through get_voxel(): what a caller of this is doing is a
	// sweep, and a section is a quarter of a million voxels.
	//
	// What is not there -- a section that is not loaded, a chunk nothing has
	// written -- is left undefined, which is what get_voxel() answers for
	// one and what the volume already holds.
	VoxelVolume get_volume(const pv::Region &region)
	{
		const pv::Vector3DInt32 rlc = region.getLowerCorner();
		const pv::Vector3DInt32 ruc = region.getUpperCorner();
		VoxelVolume out(region);
		if(ruc.getX() < rlc.getX() || ruc.getY() < rlc.getY() ||
				ruc.getZ() < rlc.getZ())
			return out;
		pv::Vector3DInt32 chunk_lc = container_coord(rlc, m_chunk_size_voxels);
		pv::Vector3DInt32 chunk_uc = container_coord(ruc, m_chunk_size_voxels);

		for(int cz = chunk_lc.getZ(); cz <= chunk_uc.getZ(); cz++){
		for(int cy = chunk_lc.getY(); cy <= chunk_uc.getY(); cy++){
		for(int cx = chunk_lc.getX(); cx <= chunk_uc.getX(); cx++){
			pv::Vector3DInt32 chunk_p(cx, cy, cz);
			pv::Vector3DInt16 section_p =
					container_coord16(chunk_p, m_section_size_chunks);
			Section *section = get_section(section_p);
			if(section == nullptr || !section->loaded)
				continue;
			ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
					&m_total_buffers_loaded);
			if(!buf.volume)
				continue;

			// Whatever planes the chunk has, the answer gets: a caller
			// reading a world of more than one plane is reading all of it
			out.add_planes(buf.volume->planes());
			const size_t num_extra_planes = buf.volume->planes().size() > 1 ?
					buf.volume->planes().size() - 1 : 0;

			pv::Region chunk_region = get_chunk_region_voxels(chunk_p);
			pv::Vector3DInt32 lc = chunk_region.getLowerCorner();
			pv::Vector3DInt32 uc = chunk_region.getUpperCorner();
			if(lc.getX() < rlc.getX()) lc.setX(rlc.getX());
			if(lc.getY() < rlc.getY()) lc.setY(rlc.getY());
			if(lc.getZ() < rlc.getZ()) lc.setZ(rlc.getZ());
			if(uc.getX() > ruc.getX()) uc.setX(ruc.getX());
			if(uc.getY() > ruc.getY()) uc.setY(ruc.getY());
			if(uc.getZ() > ruc.getZ()) uc.setZ(ruc.getZ());

			pv::Vector3DInt32 chunk_off(
					chunk_p.getX() * m_chunk_size_voxels.getX(),
					chunk_p.getY() * m_chunk_size_voxels.getY(),
					chunk_p.getZ() * m_chunk_size_voxels.getZ());

			// A row at a time rather than a voxel at a time: a run along
			// x is contiguous in both volumes, so it is a memcpy per plane
			// -- and the sampler underneath the voxel-at-a-time version was
			// 12% of the server's whole CPU in a devtest profile. The old
			// walk is still here for the rows copy_run_from() will not
			// take, which is any that is not wholly inside both volumes.
			const size_t run = (size_t)(uc.getX() - lc.getX() + 1);
			VoxelVolume::Sampler src(buf.volume.get());
			VoxelVolume::Sampler dst(&out);
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				if(out.copy_run_from(*buf.volume,
						lc.getX() - chunk_off.getX(),
						y - chunk_off.getY(),
						z - chunk_off.getZ(),
						lc.getX(), y, z, run))
					continue;
				src.setPosition(
						lc.getX() - chunk_off.getX(),
						y - chunk_off.getY(),
						z - chunk_off.getZ());
				dst.setPosition(lc.getX(), y, z);
			for(int x = lc.getX(); x <= uc.getX(); x++,
					src.movePositiveX(), dst.movePositiveX()){
				dst.setVoxel(src.getVoxel());
				for(size_t pi = 1; pi <= num_extra_planes; pi++){
					out.set_plane_at((uint8_t)pi, x, y, z,
							buf.volume->plane_at((uint8_t)pi,
							x - chunk_off.getX(), y - chunk_off.getY(),
							z - chunk_off.getZ()));
				}
			}
			}
			}

			auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
					m_sections_with_loaded_buffers.end(), section,
					std::greater<Section*>());
			if(it == m_sections_with_loaded_buffers.end() || *it != section)
				m_sections_with_loaded_buffers.insert(it, section);
		}
		}
		}

		// Buffers were loaded above; keep to the limit once, not per voxel
		maintain_maximum_buffer_limit();
		return out;
	}

	// See the comment on Instance::merge_volume() in api.h for what the
	// priorities are. This is chunk by chunk rather than voxel by voxel
	// through set_voxel(): a section is a quarter of a million voxels, and
	// all of this is done while holding the module.
	void merge_volume(const VoxelVolume &volume,
			bool create_missing_sections, const pv::Region *owned)
	{
		write_volume(volume, create_missing_sections, false, owned);
	}

	// The same walk that overwrites instead, which is what everything that
	// is not a generator wants: an importer, a VoxelManip, a mod putting a
	// building down.
	void set_volume(const VoxelVolume &volume, bool create_missing_sections,
			bool exact_light)
	{
		write_volume(volume, create_missing_sections, true, nullptr,
				exact_light);
	}

	// overwrite tells the two apart: with it every defined voxel of the
	// volume is written, and without it the generator priorities in api.h
	// decide. A voxel that is undefined in the volume is skipped either
	// way, so a caller can leave holes.
	void write_volume(const VoxelVolume &volume,
			bool create_missing_sections, bool overwrite,
			const pv::Region *owned = nullptr, bool exact_light = false)
	{
		// exact_light: where the light changed, for the blockers beside
		std::vector<pv::Vector3DInt32> light_changed;
		const pv::Region region = volume.getEnclosingRegion();
		auto rlc = region.getLowerCorner();
		auto ruc = region.getUpperCorner();
		pv::Vector3DInt32 chunk_lc = container_coord(rlc, m_chunk_size_voxels);
		pv::Vector3DInt32 chunk_uc = container_coord(ruc, m_chunk_size_voxels);

		size_t num_written = 0;
		for(int cz = chunk_lc.getZ(); cz <= chunk_uc.getZ(); cz++){
		for(int cy = chunk_lc.getY(); cy <= chunk_uc.getY(); cy++){
		for(int cx = chunk_lc.getX(); cx <= chunk_uc.getX(); cx++){
			pv::Vector3DInt32 chunk_p(cx, cy, cz);
			pv::Vector3DInt16 section_p =
					container_coord16(chunk_p, m_section_size_chunks);
			Section *section = get_section(section_p);
			if(section == nullptr || !section->loaded){
				if(!create_missing_sections)
					continue;
				// And not outside the load range either, once there is
				// one; see load_section_no_generate()
				if(!m_load_points.empty() && !is_wanted_loaded(section_p))
					continue;
				// Created but not generated: the voxels are undefined apart
				// from what this volume writes, and generate_section() will
				// still ask for the rest when someone wants this section
				Section &new_section = force_get_section(section_p);
				if(!new_section.loaded)
					load_section(new_section);
				section = &new_section;
			}
			note_cause(section);
			ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
					&m_total_buffers_loaded);
			if(!buf.volume){
				log_d(MODULE, "merge_volume(): No buffer volume for chunk "
						PV3I_FORMAT, PV3I_PARAMS(chunk_p));
				continue;
			}

			// Whatever planes the incoming volume has, the chunk gets --
			// which is how a field a generator writes reaches storage
			// without voxelworld being told about it
			buf.volume->add_planes(volume.planes());
			const size_t num_extra_planes = volume.planes().size() > 1 ?
					volume.planes().size() - 1 : 0;

			pv::Region chunk_region = get_chunk_region_voxels(chunk_p);
			pv::Vector3DInt32 lc = chunk_region.getLowerCorner();
			pv::Vector3DInt32 uc = chunk_region.getUpperCorner();
			// The part of this chunk the volume actually covers
			if(lc.getX() < rlc.getX()) lc.setX(rlc.getX());
			if(lc.getY() < rlc.getY()) lc.setY(rlc.getY());
			if(lc.getZ() < rlc.getZ()) lc.setZ(rlc.getZ());
			if(uc.getX() > ruc.getX()) uc.setX(ruc.getX());
			if(uc.getY() > ruc.getY()) uc.setY(ruc.getY());
			if(uc.getZ() > ruc.getZ()) uc.setZ(ruc.getZ());

			pv::Vector3DInt32 chunk_off(
					chunk_p.getX() * m_chunk_size_voxels.getX(),
					chunk_p.getY() * m_chunk_size_voxels.getY(),
					chunk_p.getZ() * m_chunk_size_voxels.getZ());

			// Both volumes are walked by a sampler, which holds a pointer
			// into the data and moves it by one per step, rather than by
			// getVoxelAt()/setVoxelAt(), which work out the index from the
			// coordinates every time. Luanti's VoxelManipulator walks its
			// own index the same way, and for a whole section of voxels the
			// difference is the bulk of the work.
			VoxelVolume::Sampler src(
					const_cast<VoxelVolume*>(&volume));
			VoxelVolume::Sampler dst(buf.volume.get());
			// A generator over a section it has not merged before keeps
			// what stands there: the minimal game's floor, written while
			// its mods loaded, lost the chunk whose section was generated
			// after the write
			const bool keep_standing = owned != nullptr && !section->arrived;

			bool chunk_written = false;
			// The rows the copy below reads to see whether it can take them
			sv_<uint32_t> src_words, dst_words;
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
			// One stretch of a row, a voxel at a time: the general case, and
			// what the run copy after it falls back to.
			auto walk = [&](int x_from, int x_to){
				if(x_from > x_to)
					return;
				src.setPosition(x_from, y, z);
				dst.setPosition(
						x_from - chunk_off.getX(),
						y - chunk_off.getY(),
						z - chunk_off.getZ());
			for(int x = x_from; x <= x_to; x++,
					src.movePositiveX(), dst.movePositiveX()){
				VoxelInstance nv = src.getVoxel();
				if(is_undefined(nv))
					continue;
				VoxelInstance old = dst.getVoxel();
				bool old_undefined = is_undefined(old);
				// Which definition a voxel wears can depend on any of its
				// planes, so the questions below are asked of the whole
				// voxel and not of the word the sampler walks
				interface::VoxelSample src_v = num_extra_planes == 0 ?
						sample_of(nv) : volume.sample_at(x, y, z);
				interface::VoxelSample dst_v = num_extra_planes == 0 ?
						sample_of(old) : buf.volume->sample_at(
						x - chunk_off.getX(), y - chunk_off.getY(),
						z - chunk_off.getZ());
				// Inside what the writer owns, what it says goes; outside
				// it -- a generator's padding reaching into a neighbour --
				// the priorities below decide. See merge_volume() in api.h.
				const bool writer_owns = overwrite || (owned != nullptr &&
						x >= owned->getLowerCorner().getX() &&
						x <= owned->getUpperCorner().getX() &&
						y >= owned->getLowerCorner().getY() &&
						y <= owned->getUpperCorner().getY() &&
						z >= owned->getLowerCorner().getZ() &&
						z <= owned->getUpperCorner().getZ());
				if(keep_standing && !old_undefined &&
						!voxel_is_fully_empty(dst_v))
					continue;
				if(!writer_owns && !old_undefined){
					// Anything already standing here wins
					if(!voxel_is_fully_empty(dst_v))
						continue;
					// Empty stays empty unless something is put in it
					if(voxel_is_fully_empty(src_v))
						continue;
				}

				// Only the faces of the volume touch what was already in
				// the world: a voxel inside it that had no light and is
				// given none can neither lose light nor be reached by any,
				// because every neighbour that could reach it is part of
				// the same write. So the inside of a generated section
				// costs no seeds at all, and the light that does come from
				// outside enters over the faces and floods inwards from
				// there. A voxel that had light, or that makes its own,
				// still seeds wherever it is.
				const bool on_volume_face =
						x == rlc.getX() || x == ruc.getX() ||
						y == rlc.getY() || y == ruc.getY() ||
						z == rlc.getZ() || z == ruc.getZ();

				// Light that came with the volume is kept and needs no
				// seed; this is the generator's path and a generated world
				// arrives lit. See set_voxel() above.
				for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++){
					const LightField lf = (LightField)f;
					if(m_light_maintained[lf] && exact_light){
						// A change of what the voxel is still floods; the
						// light is the writer's
						if(voxel_transmits_light(dst_v) !=
								voxel_transmits_light(src_v) ||
								(lf == LIGHT_LAMP &&
								voxel_light_source(dst_v) !=
								voxel_light_source(src_v))){
							if(!m_light_deferred) m_light_seeds[lf].push_back(
									SkylightSeed{pv::Vector3DInt32(x, y, z),
									get_light(old, lf),
									voxel_transmits_light(dst_v),
									(uint8_t)(lf == LIGHT_LAMP ?
									voxel_light_source(dst_v) : 0), false});
						} else if(get_light(nv, lf) != get_light(old, lf)){
							light_changed.push_back(pv::Vector3DInt32(x, y, z));
						}
						continue;
					}
					if(!m_light_maintained[lf] || get_light(nv, lf) != 0)
						continue;
					if(!on_volume_face && get_light(old, lf) == 0 &&
							voxel_light_source(src_v) == 0){
						set_light(nv, 0, lf);
						continue;
					}
					bool old_transparent = voxel_transmits_light(dst_v);
					const bool now_transparent = voxel_transmits_light(src_v);
					if(old_transparent != now_transparent ||
							(lf == LIGHT_LAMP &&
							voxel_light_source(dst_v) !=
							voxel_light_source(src_v))){
						if(!m_light_deferred) m_light_seeds[lf].push_back(SkylightSeed{
								pv::Vector3DInt32(x, y, z),
								get_light(old, lf), old_transparent,
								(uint8_t)(lf == LIGHT_LAMP ?
								voxel_light_source(dst_v) : 0), false});
					}
					// A dug blocker starts dark; see set_voxel()
					set_light(nv, (!old_transparent && now_transparent) ? 0 :
							get_light(old, lf), lf);
				}

				dst.setVoxel(nv);
				// The sampler is plane 0; anything else the volume carries
				// is copied by position. Only a world that has more than
				// one plane pays for this.
				for(size_t pi = 1; pi <= num_extra_planes; pi++){
					buf.volume->set_plane_at((uint8_t)pi,
							x - chunk_off.getX(),
							y - chunk_off.getY(),
							z - chunk_off.getZ(),
							volume.plane_at((uint8_t)pi, x, y, z));
				}
				chunk_written = true;
				num_written++;
			}
			};

			// And the stretch that can be copied instead of walked.
			//
			// Every voxel the writer owns whose light came with it -- or
			// which is dark beside dark and makes none of its own -- ends
			// the walk above as "write the source voxel and seed nothing",
			// which for a run of them is a memcpy per plane. That is the
			// generator's own case over nearly the whole of its section.
			//
			// What it may not take: a voxel on a face of the volume, where
			// light crosses into what was already in the world; a voxel the
			// writer does not own, where what is already there may win; and
			// a run with anything undefined in it, which the walk skips.
			int copy_from = uc.getX() + 1, copy_to = uc.getX();
			int fx0 = lc.getX(), fx1 = uc.getX();
			bool row_owned = overwrite;
			if(!row_owned && owned != nullptr &&
					y >= owned->getLowerCorner().getY() &&
					y <= owned->getUpperCorner().getY() &&
					z >= owned->getLowerCorner().getZ() &&
					z <= owned->getUpperCorner().getZ()){
				if(fx0 < owned->getLowerCorner().getX())
					fx0 = owned->getLowerCorner().getX();
				if(fx1 > owned->getUpperCorner().getX())
					fx1 = owned->getUpperCorner().getX();
				row_owned = fx0 <= fx1;
			}
			// An exact write's light is the walk's: what changed is noted
			if(exact_light || y == rlc.getY() || y == ruc.getY() ||
					z == rlc.getZ() || z == ruc.getZ()){
				row_owned = false;
			} else {
				if(fx0 == rlc.getX())
					fx0++;
				if(fx1 == ruc.getX())
					fx1--;
				if(fx0 > fx1)
					row_owned = false;
			}
			if(row_owned){
				const size_t n = (size_t)(fx1 - fx0 + 1);
				src_words.resize(n);
				dst_words.resize(n);
				const int dx0 = fx0 - chunk_off.getX();
				const int dy0 = y - chunk_off.getY();
				const int dz0 = z - chunk_off.getZ();
				bool can_copy =
						volume.read_words(fx0, y, z, n, &src_words[0]) &&
						buf.volume->read_words(dx0, dy0, dz0, n,
								&dst_words[0]);
				for(size_t k = 0; k < n && can_copy; k++){
					const VoxelInstance sv(src_words[k]);
					if(is_undefined(sv) || (keep_standing &&
							!is_undefined(VoxelInstance(dst_words[k])))){
						can_copy = false;
						break;
					}
					for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++){
						const LightField lf = (LightField)f;
						if(!m_light_maintained[lf])
							continue;
						// It brought its own light, so nothing is decided
						// here; see the walk above
						if(get_light(sv, lf) != 0)
							continue;
						// Dark arriving where there was light, or a light of
						// its own arriving: both are the walk's business
						if(get_light(VoxelInstance(dst_words[k]), lf) != 0 ||
								voxel_light_source(sample_of(sv)) != 0){
							can_copy = false;
							break;
						}
					}
				}
				if(can_copy && buf.volume->copy_run_from(volume,
						fx0, y, z, dx0, dy0, dz0, n)){
					copy_from = fx0;
					copy_to = fx1;
					chunk_written = true;
					num_written += n;
				}
			}
			walk(lc.getX(), copy_from - 1);
			walk(copy_to + 1, uc.getX());
			}
			}

			if(chunk_written){
				if(!buf.dirty){
					buf.dirty = true;
					m_total_buffers_dirty++;
				}
				auto it = std::lower_bound(
						m_sections_with_loaded_buffers.begin(),
						m_sections_with_loaded_buffers.end(), section,
						std::greater<Section*>());
				if(it == m_sections_with_loaded_buffers.end() ||
						*it != section)
					m_sections_with_loaded_buffers.insert(it, section);
			}
		}
		}
		}

		// Buffers were loaded above; keep to the limit once, not per voxel
		if(owned != nullptr){
			Section *s = get_section(container_coord16(container_coord(
					owned->getLowerCorner(), m_chunk_size_voxels),
					m_section_size_chunks));
			// Generated by this, whatever the section's flag said: one
			// unloaded between asking and arriving was saved unmarked,
			// came back so, and waited for a generation already done
			if(s){
				s->arrived = true;
				s->awaiting = false;
				s->generated = true;
			}
		}
		// The voxels that block light beside a changed one, and the changed
		// ones themselves, wear the brightest light beside them again: the
		// writer's light is the air's, and what it wrote into a blocker is
		// what it read there
		if(!light_changed.empty()){
			for(size_t f = 0; f < NUM_LIGHT_FIELDS; f++){
				if(!m_light_maintained[f])
					continue;
				m_light_running = (LightField)f;
				m_light_buf = nullptr;
				m_light_section = nullptr;
				for(const pv::Vector3DInt32 &p : light_changed){
					light_blocker_from_neighbours(p);
					for(size_t k = 0; k < 6; k++)
						light_blocker_from_neighbours(pv::Vector3DInt32(
								p.getX() + LIGHT_OFF[k][0],
								p.getY() + LIGHT_OFF[k][1],
								p.getZ() + LIGHT_OFF[k][2]));
				}
			}
		}
		maintain_maximum_buffer_limit();

		log_d(MODULE, "%s: %zu voxels written",
				overwrite ? "set_volume()" : "merge_volume()", num_written);
	}

	// Read a voxel without loading anything or touching any bookkeeping, so
	// that it is safe to call while chunk buffers are being committed. A chunk
	// that is not in memory reads as undefined.
	VoxelInstance peek_voxel(const pv::Vector3DInt32 &p)
	{
		const VoxelInstance undefined(interface::VOXELTYPEID_UNDEFINED);
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr)
			return undefined;
		ChunkBuffer &buf =
				section->chunk_buffers[section->get_chunk_i(chunk_p)];
		if(!buf.volume)
			return undefined;
		return buf.volume->getVoxelAt(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ());
	}

	// Fill the one voxel of padding around a chunk from the chunks next to it.
	// The mesher needs it to see what is on the other side of a chunk edge;
	// with the padding left empty, every face there is meshed against nothing,
	// and anything the mesher reads per voxel, such as skylight or the
	// neighbours ambient occlusion counts, breaks along chunk boundaries.
	//
	// Taken from whatever is loaded; a neighbour that is not in memory leaves
	// its side undefined, which is what the mesher falls back on anyway.
	// Nothing is written back to the neighbours, so a voxel changed at a chunk
	// edge leaves the neighbour's copy of it stale until that neighbour is
	// committed in turn.
	void fill_chunk_padding(const pv::Vector3DInt32 &chunk_p,
			VoxelVolume &volume)
	{
		const pv::Region &region = volume.getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		const pv::Vector3DInt32 chunk_lc(
				chunk_p.getX() * m_chunk_size_voxels.getX(),
				chunk_p.getY() * m_chunk_size_voxels.getY(),
				chunk_p.getZ() * m_chunk_size_voxels.getZ());
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			bool z_edge = (z == lc.getZ() || z == uc.getZ());
			for(int y = lc.getY(); y <= uc.getY(); y++){
				bool y_edge = (y == lc.getY() || y == uc.getY());
				// Skip straight across the interior of each row
				int x_step = (z_edge || y_edge) ? 1 :
						uc.getX() - lc.getX();
				for(int x = lc.getX(); x <= uc.getX(); x += x_step){
					volume.setVoxelAt(x, y, z, peek_voxel(
							pv::Vector3DInt32(chunk_lc.getX() + x,
							chunk_lc.getY() + y, chunk_lc.getZ() + z)));
				}
			}
		}
	}

	#include "lighting.h"

	// Commit and unload chunk buffer
	void commit_chunk_buffer(Section *section, size_t chunk_i)
	{
		ChunkBuffer &chunk_buffer = section->chunk_buffers[chunk_i];
		if(!chunk_buffer.dirty){
			// No changes
			return;
		}
		section->modified = true;

		pv::Vector3DInt32 chunk_p = section->get_chunk_p(chunk_i);
		uint node_id = section->node_ids->getVoxelAt(chunk_p);

		log_d(MODULE, "Committing chunk " PV3I_FORMAT " (node %i)",
				PV3I_PARAMS(chunk_p), node_id);

		if(node_id == 0){
			log_w(MODULE, "commit_chunk_buffer() chunk_i=%zu: "
					"No node found for chunk " PV3I_FORMAT
					" in section " PV3I_FORMAT,
					chunk_i, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section->section_p));
			return;
		}

		fill_chunk_padding(chunk_p, *chunk_buffer.volume);

		run_commit_hooks_in_thread(chunk_p, *chunk_buffer.volume);

		const int64_t t_before_pack = interface::os::time_us();
		ss_ new_data = interface::serialize_volume_compressed(
				*chunk_buffer.volume);

		// What a commit is made of, because a commit that takes seconds for
		// one buffer is not taking them in zstd: this runs in voxelworld's
		// own thread and the scene belongs to the main one, so every buffer
		// written is a wait for whatever the main thread is doing. The two
		// are counted apart and commit() says which it was.
		const int64_t t_before_scene = interface::os::time_us();
		m_commit_pack_us += t_before_scene - t_before_pack;

		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			Context *context = scene->GetContext();

			Node *n = scene->GetNode(node_id);
			if(!n){
				log_w(MODULE, "commit_chunk_buffer(): Node %i not found",
						node_id);
				return;
			}
			const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
			if(var.GetType() != VAR_BUFFER){
				log_w(MODULE, "commit_chunk_buffer(): Node %i does not contain "
						"an existing buffer; assuming some kind of error",
						node_id);
				return;
			}

			n->SetVar(StringHash("buildat_voxel_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)new_data.c_str(),
					new_data.size())));

			run_commit_hooks_in_scene(chunk_p, n);
		});
		m_commit_scene_us += interface::os::time_us() - t_before_scene;

		// Mark node for collision box update
		mark_node_for_physics_update(node_id);

		// Reset dirty flag
		chunk_buffer.dirty = false;
		m_total_buffers_dirty--;

		// Telling replicate and the clients about it is the same work for
		// one node as for a hundred, and it is a hop into another module's
		// thread which itself hops into main_context's -- so it is done once
		// for the whole commit rather than once per buffer. See
		// announce_committed_nodes().
		m_committed_nodes.push_back(
				std::pair<uint, pv::Vector3DInt32>(node_id, chunk_p));
	}

	// What commit() tells the rest of the server about the buffers it wrote:
	// the voxel registry first, so that a client has the types before it is
	// given voxels of them, then one pass through replicate for every node,
	// then the packets and the events.
	//
	// Measured on a VoxeLibre world being generated (2026-09-15): one hop
	// per buffer cost between two and a half and five and a half seconds for
	// a single dirty buffer, all of it inside replicate::access(), because
	// replicate's own sync_node_immediate() waits for main_context in turn.
	// Everything that wants voxelworld waits behind that, which is what the
	// shutdown hang looks like from the outside.
	void announce_committed_nodes()
	{
		if(m_committed_nodes.empty())
			return;
		// First send updated voxel registry to clients so that they are ready
		// to generate stuff from the voxels
		const int64_t t_before_reg = interface::os::time_us();
		send_voxel_registry_if_dirty();

		// Then synchronize the nodes and notify clients about them
		const int64_t t_before_rep = interface::os::time_us();
		m_commit_registry_us += t_before_rep - t_before_reg;
		sv_<sv_<replicate::PeerId>> peers(m_committed_nodes.size());
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			for(size_t i = 0; i < m_committed_nodes.size(); i++){
				const uint node_id = m_committed_nodes[i].first;
				ireplicate->sync_node_immediate(m_scene_ref, node_id);
				peers[i] = ireplicate->find_peers_that_know_node(
						m_scene_ref, node_id);
			}
		});
		m_commit_replicate_us += interface::os::time_us() - t_before_rep;

		network::access(m_server, [&](network::Interface *inetwork){
			for(size_t i = 0; i < m_committed_nodes.size(); i++){
				const uint node_id = m_committed_nodes[i].first;
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar((int32_t)node_id);
				}
				for(auto &peer_id: peers[i]){
					if(!m_clients_initialized.count(peer_id))
						continue;
					inetwork->send(peer_id, "voxelworld:node_volume_updated",
							os.str());
				}
			}
		});

		for(const auto &pair : m_committed_nodes){
			m_server->emit_event("voxelworld:node_volume_updated",
					new NodeVolumeUpdated(m_scene_ref, pair.first, true,
					pair.second));
		}
		m_committed_nodes.clear();
	}

	size_t num_buffers_loaded()
	{
		return m_total_buffers_loaded;
	}

	void set_light_maintained(LightField field, bool maintained)
	{
		if(maintained && !light_field(field).bound()){
			throw Exception(ss_()+"voxelworld: this world's format has "
					"nowhere to put "+(field == LIGHT_LAMP ? "lamp" : "sky")+
					" light");
		}
		if(field == LIGHT_LAMP){
			m_light_maintained[LIGHT_LAMP] = maintained;
			return;
		}
		set_skylight_enabled_impl(maintained);
	}

	void set_skylight_enabled_impl(bool enabled)
	{
		if(enabled && !sky_field().bound())
			throw Exception(ss_()+"set_skylight_enabled(): there is nowhere "
					"to put it in "+m_voxel_reg->get_format().dump());
		m_light_maintained[LIGHT_SKY] = enabled;
	}

	// What the last commit() spent where; see commit_chunk_buffer()
	int64_t m_commit_pack_us = 0;
	int64_t m_commit_scene_us = 0;
	int64_t m_commit_registry_us = 0;
	int64_t m_commit_replicate_us = 0;
	// The nodes this commit wrote, for announce_committed_nodes()
	sv_<std::pair<uint, pv::Vector3DInt32>> m_committed_nodes;

	void commit()
	{
		const int64_t t0 = interface::os::time_us();
		m_commit_pack_us = 0;
		m_commit_scene_us = 0;
		m_commit_registry_us = 0;
		m_commit_replicate_us = 0;
		// Before anything is meshed, so that the light lands in the same
		// remesh as the voxels that changed it -- unless a deferred
		// relight's flood is under way, which relight_stale() carries on
		// under its own budget: finishing it here made the slicing moot,
		// since every access ends here ([STEP_SLICE]). Seeds from writes
		// made meanwhile wait on the end of that flood, a few ticks.
		// Under a budget ([FLOOD_STEP]): a liquid pass's thousands of
		// writes seeded a flood of 330 000 voxels that took 1.6 s of the
		// step. What the budget leaves is a pending relight with no
		// blockers of its own, carried on by relight_stale() under the
		// tick's budget as a section's deferred relight is; the light of
		// those writes lags a few ticks, the step does not.
		static const int64_t COMMIT_LIGHT_BUDGET_US = 50000;
		if(!m_relight_pending){
			if(!update_skylight_until(t0 + COMMIT_LIGHT_BUDGET_US)){
				m_relight_blockers.clear();
				m_relight_finish_f = 0;
				m_relight_finish_i = 0;
				m_relight_pending = true;
			}
		} else
			update_skylight_now();
		const int64_t t_light = interface::os::time_us();

		if(m_sections_with_loaded_buffers.empty())
			return;
		log_d(MODULE, "Committing %zu dirty buffers in %zu sections",
				m_total_buffers_dirty,
				m_sections_with_loaded_buffers.size());
		const size_t was_dirty = m_total_buffers_dirty;
		// Said while it is still going and not only when it is over: a
		// commit that never returns is what a hang looks like from the
		// outside, and a line per second saying how far it has got is what
		// tells that apart from a commit that is merely long.
		static const int64_t SAY_EVERY_US = 1000000;
		int64_t say_at = t0 + SAY_EVERY_US;
		size_t written = 0;
		for(Section *section : m_sections_with_loaded_buffers){
			for(size_t i = 0; i < section->chunk_buffers.size(); i++){
				if(section->chunk_buffers[i].dirty)
					written++;
				commit_chunk_buffer(section, i);
				const int64_t now = interface::os::time_us();
				if(now >= say_at){
					say_at = now + SAY_EVERY_US;
					log_w(MODULE, "commit(): %zu of %zu dirty buffers "
							"written after %.1f s", written, was_dirty,
							(now - t0) / 1e6);
				}
			}
		}
		// The nodes this wrote are announced on the next tick and not here;
		// see announce_committed_nodes() and on_tick().
		//
		// This runs at the end of every access into voxelworld -- see
		// voxelworld::access() in api.h -- so whatever it costs is what
		// every other module waits for before it can get in. A second of it
		// is a second of the game not answering.
		static const int64_t SLOW_COMMIT_US = 500000;
		const int64_t took = interface::os::time_us() - t0;
		if(took >= SLOW_COMMIT_US){
			log_w(MODULE, "commit(): %zu dirty buffers in %zu sections took "
					"%.1f s -- light %.1f, packing %.1f, the main thread "
					"%.1f, the voxel registry %.1f, replicate %.1f",
					was_dirty, m_sections_with_loaded_buffers.size(),
					took / 1e6, (t_light - t0) / 1e6,
					m_commit_pack_us / 1e6, m_commit_scene_us / 1e6,
					m_commit_registry_us / 1e6, m_commit_replicate_us / 1e6);
		}
	}

	VoxelInstance get_voxel(const pv::Vector3DInt32 &p, bool disable_warnings)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "get_voxel() p=" PV3I_FORMAT ": No section "
					PV3I_FORMAT " for chunk " PV3I_FORMAT,
					PV3I_PARAMS(p), PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return VoxelInstance(interface::VOXELTYPEID_UNDEFINED);
		}

		// Unload stuff if needed
		maintain_maximum_buffer_limit();

		// Get from buffer
		ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
				&m_total_buffers_loaded);
		if(!buf.volume){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "get_voxel() p=" PV3I_FORMAT ": Couldn't get "
					"buffer volume for chunk " PV3I_FORMAT " in section "
					PV3I_FORMAT, PV3I_PARAMS(p), PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return VoxelInstance(interface::VOXELTYPEID_UNDEFINED);
		}
		pv::Vector3DInt32 voxel_p(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
		);
		VoxelInstance v = buf.volume->getVoxelAt(voxel_p);

		// Set section buffer loaded flag
		auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
				m_sections_with_loaded_buffers.end(), section,
				std::greater<Section*>()); // position in descending order
		if(it == m_sections_with_loaded_buffers.end() || *it != section)
			m_sections_with_loaded_buffers.insert(it, section);

		return v;
	}
};

struct Module: public interface::Module, public voxelworld::Interface
{
	interface::Server *m_server;

	sm_<SceneReference, up_<CInstance>> m_instances;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		log_t(MODULE, "voxelworld construct");
	}

	~Module()
	{
		log_t(MODULE, "voxelworld destruct");
	}

	void init()
	{
		if(keep_loaded_wanted())
			log_i(MODULE, "BUILDAT_VOXELWORLD_KEEP_LOADED: nothing is "
					"unloaded this run");
		// NOTE: These also apply to CInstances
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		// [USER_DIR_COPY] An operator's save_now: what shutdown saves
		m_server->sub_event(this, Event::t("core:save"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("replicate:peer_joined_scene"));
		m_server->sub_event(this, Event::t("replicate:peer_left_scene"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("main_context:scene_deleted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/voxelworld:set_send_distance"));
		/*m_server->sub_event(this, Event::t(
					"network:packet_received/voxelworld:get_section"));*/
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		dispatch(type, p);
		for(auto &pair : m_instances){
			up_<CInstance> &instance = pair.second;
			instance->event(type, p);
		}
	}

	// The handlers' list, which returns at its match
	void dispatch(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:shutdown", on_shutdown)
		EVENT_VOIDN("core:save", on_shutdown)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("replicate:peer_joined_scene", on_peer_joined_scene,
				replicate::PeerJoinedScene);
		EVENT_TYPEN("replicate:peer_left_scene", on_peer_left_scene,
				replicate::PeerLeftScene);
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("main_context:scene_deleted", on_scene_deleted,
				main_context::SceneDeleted);
	}

	void on_start()
	{
	}

	void unload_node(Scene *scene, uint node_id)
	{
		log_d(MODULE, "Unloading node %i", node_id);
		Node *n = scene->GetNode(node_id);
		if(!n){
			log_w(MODULE, "Cannot unload node %i: Not found in scene", node_id);
			return;
		}
		// Remove RigidBody first to speed up removal of CollisionShapes
		RigidBody *body = n->GetComponent<RigidBody>();
		if(body)
			n->RemoveComponent(body);
		// Remove everything else
		n->RemoveAllComponents();
		n->Remove();
	}

	// The server is going away. A world with a save gets one last flush; one
	// without is unchanged by this, which is every game that has not asked
	// for persistence.
	void on_shutdown()
	{
		for(auto &pair : m_instances)
			pair.second->save();
	}

	void on_unload()
	{
		log_v(MODULE, "on_unload()");

		// TODO

		/*commit();

		// Remove everything managed by us from the scene
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene();
			size_t progress = 0;
			for(auto &sector_pair: m_sections){
				log_v(MODULE, "Unloading nodes... %i%%",
						100 * progress / m_sections.size());
				progress++;
				for(auto &section_pair: sector_pair.second){
					Section &section = section_pair.second;

					auto region = section.node_ids->getEnclosingRegion();
					auto lc = region.getLowerCorner();
					auto uc = region.getUpperCorner();
					for(int z = lc.getZ(); z <= uc.getZ(); z++){
						for(int y = lc.getY(); y <= uc.getY(); y++){
							for(int x = lc.getX(); x <= uc.getX(); x++){
								uint id = section.node_ids->getVoxelAt(x, y, z);
								section.node_ids->setVoxelAt(x, y, z, 0);
								unload_node(scene, id);
							}
						}
					}
				}
			}
			log_v(MODULE, "Unloading nodes... 100%%");
		});

		// Store voxel registry and stuff
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(m_voxel_reg->serialize());
		}
		m_server->tmp_store_data("voxelworld:restore_info", os.str());*/
	}

	void on_continue()
	{
		// TODO

		/*// Restore voxel registry and stuff
				ss_ data = m_server->tmp_restore_data("voxelworld:restore_info");
		ss_ voxel_reg_data;
		{
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_reg_data);
		}
		m_voxel_reg->deserialize(voxel_reg_data);*/

		// Start up normally
		on_start();
	}

	void on_tick(const interface::TickEvent &event)
	{
	}

	void on_peer_joined_scene(const replicate::PeerJoinedScene &event)
	{
	}

	void on_peer_left_scene(const replicate::PeerLeftScene &event)
	{
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
	}

	void on_scene_deleted(const main_context::SceneDeleted &event)
	{
		// Drop instance of the deleted scene (there should be only one, but
		// loop through all of them just for robustness)
		for(auto it = m_instances.begin(); it != m_instances.end();){
			auto current_it = it++;
			up_<CInstance> &instance = current_it->second;
			if(instance->m_scene_ref == event.scene){
				m_instances.erase(current_it);
			}
		}
	}

	/*// TODO: How should nodes be filtered for replication?
	// TODO: Generally the client wants roughly one section, but isn't
	//       positioned at the middle of a section
			void on_get_section(const network::Packet &packet)
	{
		pv::Vector3DInt16 section_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(section_p);
		}
		log_v(MODULE, "C%i: on_get_section(): " PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(section_p));
		}*/

	// Interface

	void create_instance(SceneReference scene_ref, const pv::Region &region,
			bool physics_enabled)
	{
		auto it = m_instances.find(scene_ref);
		// TODO: Is an exception the best way to handle this?
		if(it != m_instances.end())
			throw Exception("create_instance(): Scene already has a voxel"
					" world instance");

		up_<CInstance> instance(new CInstance(m_server, scene_ref, region,
				physics_enabled));
		m_instances[scene_ref] = std::move(instance);
	}

	void delete_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			throw Exception("delete_instance(): Scene does not have a voxel"
					" world instance");
		m_instances.erase(it);
	}

	Instance* get_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			return nullptr;
		return it->second.get();
	}

	void commit()
	{
		for(auto &pair : m_instances){
			up_<CInstance> &instance = pair.second;
			instance->commit();
		}
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_voxelworld(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
