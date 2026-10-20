#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "main_context/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/noise.h"
#include <random>
#include "interface/voxel_volume.h"
#include "interface/polyvox_numeric.h"
#include "interface/polyvox_cereal.h"
#include "interface/polyvox_std.h"
#include <Scene.h>
#include <Context.h>
#include <cereal/archives/portable_binary.hpp>
#include <sstream>
#include <cmath>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelVolume;
using main_context::SceneReference;

namespace main {

// A number in [a, b] ([NOISE_API]: what PseudoRandom::range was)
static int range(std::mt19937 &r, int a, int b)
{
	return a + (int)(r() % (uint32_t)(b - a + 1));
}

using namespace Urho3D;

struct Worldgen: public worldgen::GeneratorInterface
{
	// A tree stands two voxels out from its trunk, and a trunk of five with
	// four voxels of leaves on top reaches nine above the ground it grows
	// from, which can be the topmost voxel of the section
	pv::Vector3DInt32 get_padding_voxels()
	{
		return pv::Vector3DInt32(2, 9, 2);
	}

	// Only the voxels of the section itself get terrain; the padding carries
	// the parts of a tree that cross into the next section, and everything
	// else in it is left undefined for that section's own generation.
	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
		const pv::Region padded = volume.getEnclosingRegion();
		pv::Vector3DInt32 pad = get_padding_voxels();
		pv::Region region(padded.getLowerCorner() + pad,
				padded.getUpperCorner() - pad);

		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();

		int w = uc.getX() - lc.getX() + 1;
		int d = uc.getZ() - lc.getZ() + 1;

		const float spread_h = 280;
		// Retuned 2026-09-14: the noise hash used to multiply in signed
		// arithmetic, so it came back biased and with about twice the swing
		// -- the same numbers now give a terrain half as tall and much
		// lower. The offset and the scale are what put the old ground back;
		// the spawn line says where it landed, and it said y=61 before.
		// [NOISE_API] The scale times the octaves' sum (1.785): the old fbm
		// was not scaled back to -1..1
		interface::noise::NoiseParams np_h = {27.4, 46.4, spread_h, spread_h,
				spread_h, 5, 0.45};
		sv_<float> noise_h;
		interface::noise::fill2(np_h, 3, lc.getX() + spread_h/2,
				lc.getZ() + spread_h/2, w, d, noise_h);

		const float spread_b = 48;
		// [NOISE_API] The scale times the octaves' sum (1.750): the old fbm
		// was not scaled back to -1..1
		interface::noise::NoiseParams np_b = {6.4, 11.0, spread_b, spread_b,
				spread_b, 3, 0.5};
		sv_<float> noise_b;
		interface::noise::fill2(np_b, 3 + 11, lc.getX() + spread_b/2,
				lc.getZ() + spread_b/2, w, d, noise_b);

		size_t noise_i = 0;
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				float surface = 16.f + noise_h[noise_i] +
						noise_b[noise_i];
				noise_i++;
				int ground_y = (int)std::floor(surface);
				for(int y = lc.getY(); y <= uc.getY(); y++){
					pv::Vector3DInt32 p(x, y, z);
					if(y < ground_y - 4){
						volume.setVoxelAt(p, VoxelInstance(2));
					} else if(y < ground_y){
						volume.setVoxelAt(p, VoxelInstance(3));
					} else if(y == ground_y){
						volume.setVoxelAt(p, VoxelInstance(4));
					} else {
						volume.setVoxelAt(p, VoxelInstance(1));
					}
				}
			}
		}

		auto extent = uc - lc + pv::Vector3DInt32(1, 1, 1);
		int area = extent.getX() * extent.getZ();
		std::mt19937 pr(
				13241 + section_p.getX() * 131 +
				section_p.getZ() * 9176);
		for(int i = 0; i < area / 110; i++){
			int x = range(pr, lc.getX(), uc.getX());
			int z = range(pr, lc.getZ(), uc.getZ());
			size_t ti = (z-lc.getZ())*w + (x-lc.getX());
			int ground_y = (int)std::floor(16.f + noise_h[ti] +
					noise_b[ti]);
			int y = ground_y + 1;
			// A tree grows from the ground of this section; one whose ground
			// is in the next section is that section's to place
			if(y < lc.getY() || y > uc.getY())
				continue;

			int trunk = 3 + range(pr, 0, 2);
			for(int y1 = y; y1 < y + trunk; y1++){
				set_if_inside(volume, pv::Vector3DInt32(x, y1, z),
						VoxelInstance(6));
			}
			int leaves_y0 = y + trunk - 1;
			int leaves_y1 = y + trunk + 3;
			for(int x1 = x-2; x1 <= x+2; x1++){
				for(int y1 = leaves_y0; y1 <= leaves_y1; y1++){
					for(int z1 = z-2; z1 <= z+2; z1++){
						set_if_inside(volume,
								pv::Vector3DInt32(x1, y1, z1),
								VoxelInstance(5));
					}
				}
			}
		}
	}

	// A tree at the very top of a section reaches past even the padding
	static void set_if_inside(VoxelVolume &volume,
			const pv::Vector3DInt32 &p, const VoxelInstance &v)
	{
		if(!volume.getEnclosingRegion().containsPoint(p))
			return;
		volume.setVoxelAt(p, v);
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;

	SceneReference m_main_scene;

	// Runway start; the drone spawns here and accelerates towards +X
	static const int SPAWN_X = -5;
	static const int SPAWN_Z = 257;
	static const int SPAWN_Y_MAX = 127;
	static const int SPAWN_Y_MIN = -64;

	static const int RUNWAY_LENGTH = 32;
	static const int RUNWAY_HALF_WIDTH = 2; // 5 voxels wide
	// Airspace: cleared above the runway and past its end, so a takeoff does
	// not need the terrain to happen to be flat around the strip
	static const int AIRSPACE_HEIGHT = 24;
	static const int AIRSPACE_MARGIN = 6;

	// chunk 32 * section 2; matches voxelworld defaults
	static const int SECTION_SIZE_VOXELS = 64;
	// Radius 5 fills a ~320-voxel view; sections live until 7, so flying
	// back and forth over the edge does not generate the same one twice.
	// Three sections of world is all the height there is.
	static const int GENERATE_RADIUS_XZ = 5;
	static const int LOAD_RADIUS_XZ = 7;
	static const int RADIUS_Y = 1;
	static const int SECTION_Y_MIN = -1;
	static const int SECTION_Y_MAX = 1;
	// The generator runs in a thread and its queue says how far behind it
	// is; the streamer waits instead of piling more on
	static const size_t STREAM_QUEUE_SOFT_MAX = 12;
	static const size_t STREAM_SECTIONS_PER_PASS = 2;

	bool m_spawn_ready = false;
	// The runway is built once every section it touches is loaded. A write
	// into a section that is not there does nothing, and since the world
	// started streaming those sections arrive a few at a time -- so the far
	// end of the runway used to be written into nothing and lost.
	bool m_runway_pending = false;
	int m_runway_y = 0;
	size_t m_sent_worldgen_queue = (size_t)-1;
	float m_spawn_y = 0;
	size_t m_worldgen_queue = 0;
	uint m_queue_send_tick = 0;

	sm_<network::PeerInfo::Id, pv::Vector3DInt32> m_drone_voxel_p;
	// Sections the runway and the bombs have changed. Nothing here is
	// saved, so a section that unloads loses what was done to it.
	set_<uint64_t> m_pinned_sections;
	// The points are pushed on the next tick rather than where they change:
	// a bomb changes them from inside voxelworld's own access, and a runway
	// would push a thousand times for one set of sections.
	bool m_load_points_dirty = true;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:explode"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:drone_pos"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("worldgen:queue_modified"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:explode",
				on_explode, network::Packet)
		EVENT_TYPEN("network:packet_received/main:drone_pos",
				on_drone_pos, network::Packet)
		EVENT_TYPEN("network:client_disconnected",
				on_client_disconnected, network::OldClient)
		EVENT_TYPEN("worldgen:queue_modified",
				on_worldgen_queue_modified, worldgen::QueueModifiedEvent);
	}

	// The six numbers after solid describe the surface; see interface/atlas.h.
	// visible is the edge material: an invisible voxel is also one light
	// passes through. top_texture, when given, goes on the +Y and -Y faces.
	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool visible, bool solid,
			bool fully_empty, float roughness = 0.9f, float spec_strength = 1.0f,
			float bumpiness = 1.0f, float translucency = 0.0f,
			float spots = 0.0f, float static_spots = 0.0f,
			const ss_ &top_texture = "")
	{
		interface::VoxelDefinition vdef;
		vdef.name.block_name = name;
		vdef.name.segment_x = 0;
		vdef.name.segment_y = 0;
		vdef.name.segment_z = 0;
		vdef.name.rotation_primary = 0;
		vdef.name.rotation_secondary = 0;
		vdef.handler_module = "";
		for(size_t i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = vdef.textures[i];
			seg.resource_name = (i < 2 && !top_texture.empty()) ?
					top_texture : texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
			seg.roughness = roughness;
			seg.spec_strength = spec_strength;
			seg.bumpiness = bumpiness;
			seg.translucency = translucency;
			seg.spots = spots;
			seg.static_spots = static_spots;
		}
		vdef.edge_material_id = visible ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		vdef.fully_empty = fully_empty;
		reg->add_voxel(vdef);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();
		});

		// Worldgen must be created before the voxelworld; otherwise initial
		// generation request events are lost
		worldgen::access(m_server, [&](worldgen::Interface *iworldgen)
		{
			iworldgen->create_instance(m_main_scene);

			auto instance = iworldgen->get_instance(m_main_scene);
			instance->set_generator(new Worldgen());
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			// The world's bounds in sections: as wide as anyone will ever
			// fly, three sections tall. Nothing is loaded until the load
			// points below say where; the sky is above the top of this.
			pv::Region region(-30000, SECTION_Y_MIN, -30000,
					30000, SECTION_Y_MAX, 30000);
			ivoxelworld->create_instance(m_main_scene, region);
		});

		// Define voxels on core:start (voxelworld will restore them on reload)
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world =
					ivoxelworld->get_instance(m_main_scene);
			interface::VoxelRegistry *voxel_reg = world->get_voxel_reg();
			// 0.6's cut, which its saves, its checks and its code were written
			// for
			voxel_reg->set_format(interface::VoxelFormat::buildat_legacy_06());
			// roughness, spec_strength, bumpiness, translucency, spots,
			// static_spots; see interface/atlas.h
			add_voxel(voxel_reg, "air", "", false, false, true);     // id 1
			add_voxel(voxel_reg, "rock", "main/rock.png", true, true, false,
					0.95f, 0.15f, 0.5f, 0.0f, 0.0f, 0.04f);    // id 2
			add_voxel(voxel_reg, "dirt", "main/dirt.png", true, true, false,
					0.98f, 0.15f, 0.6f, 0.0f, 0.0f, 0.04f);    // id 3
			add_voxel(voxel_reg, "grass", "main/grass.png", true, true, false,
					0.90f, 1.0f, 0.75f, 0.06f, 0.012f);        // id 4
			add_voxel(voxel_reg, "leaves", "main/leaves.png", true, true, false,
					0.95f, 1.0f, 1.5f, 0.11f, 0.03f);          // id 5
			add_voxel(voxel_reg, "tree", "main/tree.png", true, true, false,
					0.85f, 0.35f, 2.0f, 0.0f, 0.0f, 0.0f,
					"main/tree_top.png");                      // id 6

			// Skylight, which is what the voxel shading reads to tell a bomb
			// crater apart from a shadow
			world->set_skylight_enabled(true);
		});

		// Enable world generation now that the voxels are defined
		worldgen::access(m_server, m_main_scene, [&](worldgen::Instance *instance)
		{
			instance->enable();
		});

		update_load_points();
	}

	void on_unload()
	{
		// TODO: Store main scene reference
		// Just do this for now
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_main_scene);
		});
	}

	void on_continue()
	{
		// TODO: Restore main scene reference
		// Just do this for now
		on_start();
	}

	static uint64_t section_key(int16_t x, int16_t y, int16_t z)
	{
		return (uint64_t)(uint16_t)x |
				((uint64_t)(uint16_t)y << 16) |
				((uint64_t)(uint16_t)z << 32);
	}

	static pv::Vector3DInt16 section_from_key(uint64_t k)
	{
		return pv::Vector3DInt16(
				(int16_t)k,
				(int16_t)(k >> 16),
				(int16_t)(k >> 32));
	}

	static uint64_t section_key_at_voxel(const pv::Vector3DInt32 &p)
	{
		return section_key(
				interface::container_coord(p.getX(), SECTION_SIZE_VOXELS),
				interface::container_coord(p.getY(), SECTION_SIZE_VOXELS),
				interface::container_coord(p.getZ(), SECTION_SIZE_VOXELS));
	}

	// Modified voxels only exist in memory; a section that unloads would come
	// back as freshly generated terrain, so keep the modified ones loaded.
	void pin_section_at_voxel(const pv::Vector3DInt32 &p)
	{
		if(m_pinned_sections.insert(section_key_at_voxel(p)).second)
			m_load_points_dirty = true;
	}

	// Where the world stays loaded: every drone, the spawn while there is
	// none, and every section the runway or a bomb has changed. voxelworld
	// does the loading, the generating and the unloading from these.
	void update_load_points()
	{
		sv_<voxelworld::LoadPoint> points;
		if(m_drone_voxel_p.empty()){
			points.push_back(voxelworld::LoadPoint(
					pv::Vector3DInt32(SPAWN_X, 20, SPAWN_Z),
					LOAD_RADIUS_XZ, RADIUS_Y,
					GENERATE_RADIUS_XZ, RADIUS_Y));
		}
		for(auto &pair : m_drone_voxel_p){
			// Tagged with the peer, which is what makes it the point the
			// world is sent to that client from
			points.push_back(voxelworld::LoadPoint(pair.second,
					LOAD_RADIUS_XZ, RADIUS_Y,
					GENERATE_RADIUS_XZ, RADIUS_Y, pair.first));
		}
		// A pin is a point with no radius at all
		for(uint64_t k : m_pinned_sections){
			pv::Vector3DInt16 sp = section_from_key(k);
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					sp.getX() * SECTION_SIZE_VOXELS,
					sp.getY() * SECTION_SIZE_VOXELS,
					sp.getZ() * SECTION_SIZE_VOXELS), 0, 0, 0, 0));
		}
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			world->set_load_points(points);
			// Backpressure: only this module can see how far behind the
			// generator is, so it is the one that tells the streamer to wait
			world->set_stream_budget(
					m_worldgen_queue >= STREAM_QUEUE_SOFT_MAX ? 0 :
					STREAM_SECTIONS_PER_PASS);
		});
		m_load_points_dirty = false;
	}

	void on_tick(const interface::TickEvent &event)
	{
		try_build_runway();
		if(m_load_points_dirty)
			update_load_points();
		if(((m_queue_send_tick++) % 10) == 0)
			send_worldgen_queue_size();
		try_resolve_spawn();
	}

	void send_spawn(network::PeerInfo::Id peer)
	{
		if(!m_spawn_ready)
			return;
		std::ostringstream os(std::ios::binary);
		cereal::PortableBinaryOutputArchive ar(os);
		double x = SPAWN_X;
		double y = m_spawn_y;
		double z = SPAWN_Z;
		ar(x, y, z);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:spawn", os.str());
		});
		log_v(MODULE, "Sent spawn (%.2f, %.2f, %.2f) to peer %zu",
				x, y, z, peer);
	}

	// Every voxel the runway and its airspace touch, so that the sections
	// can be asked for before anything is written into them and looked at
	// again to see whether they have arrived.
	template<typename F> void over_runway(int runway_y, F f)
	{
		for(int dx = -AIRSPACE_MARGIN; dx < RUNWAY_LENGTH + AIRSPACE_MARGIN;
				dx++){
			for(int dz = -RUNWAY_HALF_WIDTH - AIRSPACE_MARGIN;
					dz <= RUNWAY_HALF_WIDTH + AIRSPACE_MARGIN; dz++){
				const int x = SPAWN_X + dx;
				const int z = SPAWN_Z + dz;
				f(pv::Vector3DInt32(x, runway_y - 4, z));
				f(pv::Vector3DInt32(x, runway_y, z));
				f(pv::Vector3DInt32(x, runway_y + AIRSPACE_HEIGHT, z));
			}
		}
	}

	// Is there terrain in all of them yet? A section that exists is not the
	// same as a section that has been generated: the generator writes the
	// whole section when it is done and what it writes wins, so a runway
	// laid before that is laid into nothing. An undefined voxel is how a
	// section with nothing in it yet reads, which is the same test
	// try_resolve_spawn() makes.
	bool runway_ground_ready(voxelworld::Instance *world, int runway_y)
	{
		bool all = true;
		over_runway(runway_y, [&](const pv::Vector3DInt32 &p){
			if(!all)
				return;
			if(world->get_voxel(p, true).legacy06_id() ==
					interface::VOXELTYPEID_UNDEFINED)
				all = false;
		});
		return all;
	}

	// The strip itself is rock, the ground under it dirt so a runway laid over
	// a dip does not float, and everything above it air out to a margin so
	// takeoff has somewhere to go.
	void build_runway(voxelworld::Instance *world, int runway_y)
	{
		for(int dx = -AIRSPACE_MARGIN; dx < RUNWAY_LENGTH + AIRSPACE_MARGIN;
				dx++){
			for(int dz = -RUNWAY_HALF_WIDTH - AIRSPACE_MARGIN;
					dz <= RUNWAY_HALF_WIDTH + AIRSPACE_MARGIN; dz++){
				int x = SPAWN_X + dx;
				int z = SPAWN_Z + dz;
				bool on_strip = (dx >= 0 && dx < RUNWAY_LENGTH &&
						dz >= -RUNWAY_HALF_WIDTH && dz <= RUNWAY_HALF_WIDTH);
				pin_section_at_voxel(pv::Vector3DInt32(x, runway_y, z));
				if(on_strip){
					world->set_voxel(pv::Vector3DInt32(x, runway_y, z),
							VoxelInstance(2), true);
					for(int dy = -1; dy >= -4; dy--){
						world->set_voxel(
								pv::Vector3DInt32(x, runway_y + dy, z),
								VoxelInstance(3), true);
					}
				}
				for(int dy = 1; dy <= AIRSPACE_HEIGHT; dy++){
					pv::Vector3DInt32 p(x, runway_y + dy, z);
					pin_section_at_voxel(p);
					world->set_voxel(p, VoxelInstance(1), true);
				}
			}
		}
	}

	// Terrain ids: 2 rock, 3 dirt, 4 grass. Skip air (1), trees/leaves (5, 6).
	// Unloaded voxels are UNDEFINED; skip them so spawn can resolve as soon
	// as the surface section exists, while further sections still generate.
	// The runway, once every section it touches has arrived. Until then
	// there is nothing to write into: voxelworld says so in a warning and
	// drops the write, which is how the far half of the runway went missing
	// when the world started streaming.
	void try_build_runway()
	{
		if(!m_runway_pending)
			return;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			if(!runway_ground_ready(world, m_runway_y))
				return;
			build_runway(world, m_runway_y);
			m_runway_pending = false;
			log_i(MODULE, "Runway built at y=%i", m_runway_y);
		});
	}

	void try_resolve_spawn()
	{
		if(m_spawn_ready)
			return;
		int surface_y = SPAWN_Y_MIN - 1;
		bool saw_defined = false;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int y = SPAWN_Y_MAX; y >= SPAWN_Y_MIN; y--){
				VoxelInstance v = world->get_voxel(
						pv::Vector3DInt32(SPAWN_X, y, SPAWN_Z), true);
				auto id = v.legacy06_id();
				if(id == interface::VOXELTYPEID_UNDEFINED)
					continue;
				saw_defined = true;
				if(id != 2 && id != 3 && id != 4)
					continue;
				VoxelInstance above = world->get_voxel(
						pv::Vector3DInt32(SPAWN_X, y + 1, SPAWN_Z), true);
				auto above_id = above.legacy06_id();
				if(above_id == interface::VOXELTYPEID_UNDEFINED)
					return;
				if(above_id != 1 && above_id != 5 && above_id != 6)
					continue;
				surface_y = y;
				return;
			}
		});
		if(!saw_defined)
			return;
		if(surface_y < SPAWN_Y_MIN)
			return;
		// The sections it will be written into are asked for here and the
		// strip itself is built once they are all loaded; see
		// try_build_runway() on the tick.
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			over_runway(surface_y, [&](const pv::Vector3DInt32 &p){
				pin_section_at_voxel(p);
			});
		});
		m_runway_y = surface_y;
		m_runway_pending = true;
		// Voxel n is a 1x1x1 cube centered at n; sit on its top face
		m_spawn_y = (float)surface_y + 0.5f + 0.4f;
		m_spawn_ready = true;
		log_i(MODULE, "Runway at (%i, %i, %i), spawn y=%.2f",
				SPAWN_X, surface_y, SPAWN_Z, m_spawn_y);

		sv_<network::PeerInfo::Id> peers;
		network::access(m_server, [&](network::Interface *inetwork){
			peers = inetwork->list_peers();
		});
		for(auto peer : peers)
			send_spawn(peer);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "main:worldgen_queue_size",
					itos(m_worldgen_queue));
		});
		send_spawn(event.recipient);
	}

	// A bomb hit: delete a sphere of voxels. The client decides where and how
	// large; there is nothing to cheat for in a single-player-shaped game.
	void on_explode(const network::Packet &packet)
	{
		double x, y, z, diameter;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(x, y, z, diameter);
		}
		if(!(diameter > 0.0 && diameter <= 64.0)){
			log_w(MODULE, "C%i: on_explode(): bad diameter %.2f",
					packet.sender, diameter);
			return;
		}
		float r = diameter / 2.0f;
		int ri = (int)std::ceil(r);
		int cx = (int)std::floor(x + 0.5), cy = (int)std::floor(y + 0.5),
				cz = (int)std::floor(z + 0.5);
		log_v(MODULE, "C%i: on_explode(): (%i, %i, %i) d=%.1f",
				packet.sender, cx, cy, cz, diameter);
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int dx = -ri; dx <= ri; dx++){
				for(int dy = -ri; dy <= ri; dy++){
					for(int dz = -ri; dz <= ri; dz++){
						if(dx*dx + dy*dy + dz*dz > r*r)
							continue;
						pv::Vector3DInt32 p(cx + dx, cy + dy, cz + dz);
						pin_section_at_voxel(p);
						world->set_voxel(p, VoxelInstance(1), true);
					}
				}
			}
		});
	}

	// Only take the number here. Reaching into the network module from a
	// worldgen event can deadlock against the thread that is already in it,
	// and the queue changes far too often to be worth a packet each time.
	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &event)
	{
		log_t(MODULE, "on_worldgen_queue_modified()");
		m_worldgen_queue = event.queue_size;
		m_load_points_dirty = true;
		try_resolve_spawn();
	}

	void send_worldgen_queue_size()
	{
		if(m_worldgen_queue == m_sent_worldgen_queue)
			return;
		m_sent_worldgen_queue = m_worldgen_queue;
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &peer : inetwork->list_peers()){
				inetwork->send(peer, "main:worldgen_queue_size",
						itos(m_worldgen_queue));
			}
		});
	}

	void on_drone_pos(const network::Packet &packet)
	{
		double x, y, z;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(x, y, z);
		}
		m_drone_voxel_p[packet.sender] = pv::Vector3DInt32(
				(int32_t)std::floor(x), (int32_t)std::floor(y),
				(int32_t)std::floor(z));
		m_load_points_dirty = true;
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		m_drone_voxel_p.erase(old_client.info.id);
		m_load_points_dirty = true;
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
