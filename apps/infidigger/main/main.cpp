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

		interface::v3f spread_h(280, 280, 280);
		// Retuned 2026-09-14: the noise hash used to multiply in signed
		// arithmetic, so it came back biased and with about twice the swing
		// -- the same numbers now give a terrain half as tall and much
		// lower. The offset and the scale are what put the old ground back;
		// the spawn line says where it landed, and it said y=61 before.
		interface::NoiseParams np_h(27.4, 26, spread_h, 0, 5, 0.45);
		interface::Noise noise_h(&np_h, 3, w, d);
		noise_h.fbmMap2D(lc.getX() + spread_h.X/2,
				lc.getZ() + spread_h.Z/2);
		noise_h.transformNoiseMap();

		interface::v3f spread_b(48, 48, 48);
		interface::NoiseParams np_b(6.4, 6.3, spread_b, 11, 3, 0.5);
		interface::Noise noise_b(&np_b, 3, w, d);
		noise_b.fbmMap2D(lc.getX() + spread_b.X/2,
				lc.getZ() + spread_b.Z/2);
		noise_b.transformNoiseMap();

		size_t noise_i = 0;
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				float surface = 16.f + noise_h.result[noise_i] +
						noise_b.result[noise_i];
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
		auto pr = interface::PseudoRandom(
				13241 + section_p.getX() * 131 +
				section_p.getZ() * 9176);
		for(int i = 0; i < area / 110; i++){
			int x = pr.range(lc.getX(), uc.getX());
			int z = pr.range(lc.getZ(), uc.getZ());
			size_t ti = (z-lc.getZ())*w + (x-lc.getX());
			int ground_y = (int)std::floor(16.f + noise_h.result[ti] +
					noise_b.result[ti]);
			int y = ground_y + 1;
			// A tree grows from the ground of this section; one whose ground
			// is in the next section is that section's to place
			if(y < lc.getY() || y > uc.getY())
				continue;

			int trunk = 3 + pr.range(0, 2);
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

	static const int SPAWN_X = -5;
	static const int SPAWN_Z = 257;
	static const int SPAWN_Y_MAX = 127;
	static const int SPAWN_Y_MIN = -64;
	static constexpr float PLAYER_HEIGHT = 1.7f;

	// chunk 32 * section 2; matches voxelworld defaults
	static const int SECTION_SIZE_VOXELS = 64;
	// Radius 5 fills a ~320-voxel view; sections live until 7, so walking
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
	float m_spawn_y = 0;
	size_t m_worldgen_queue = 0;

	sm_<network::PeerInfo::Id, pv::Vector3DInt32> m_player_voxel_p;
	// Sections somebody has dug or built in. Nothing here is saved, so a
	// section that unloads loses what was done to it; these stay.
	set_<uint64_t> m_pinned_sections;
	// The points are pushed on the next tick rather than where they change:
	// a dig changes them from inside voxelworld's own access, and a runway
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
				"network:packet_received/main:place_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:player_pos"));
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
		EVENT_TYPEN("network:packet_received/main:place_voxel",
				on_place_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:dig_voxel",
				on_dig_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:player_pos",
				on_player_pos, network::Packet)
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
			// walk, three sections tall. Nothing is loaded until the load
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
			// static_spots; see interface/atlas.h. The values are
			// voxel_lighting's, which is where they were chosen.
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

			// Skylight, which is what the voxel shading reads to tell a dug
			// tunnel apart from a shadow. Enabled after the voxels are
			// defined, as it needs their edge materials to know what blocks
			// light.
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

	void pin_section_at_voxel(const pv::Vector3DInt32 &p)
	{
		if(m_pinned_sections.insert(section_key_at_voxel(p)).second)
			m_load_points_dirty = true;
	}

	// Where the world stays loaded: every player, the spawn while there is
	// nobody, and every section somebody has changed. voxelworld does the
	// loading, the generating and the unloading from these.
	void update_load_points()
	{
		sv_<voxelworld::LoadPoint> points;
		if(m_player_voxel_p.empty()){
			points.push_back(voxelworld::LoadPoint(
					pv::Vector3DInt32(SPAWN_X, 20, SPAWN_Z),
					LOAD_RADIUS_XZ, RADIUS_Y,
					GENERATE_RADIUS_XZ, RADIUS_Y));
		}
		for(auto &pair : m_player_voxel_p){
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
		if(m_load_points_dirty)
			update_load_points();
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

	// Terrain ids: 2 rock, 3 dirt, 4 grass. Skip air (1), trees/leaves (5, 6).
	// Unloaded voxels are UNDEFINED; skip them so spawn can resolve as soon
	// as the surface section exists, while further sections still generate.
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
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int dx = -2; dx <= 2; dx++){
				for(int dz = -2; dz <= 2; dz++){
					for(int dy = 1; dy <= 3; dy++){
						world->set_voxel(
								pv::Vector3DInt32(SPAWN_X + dx,
								surface_y + dy, SPAWN_Z + dz),
								VoxelInstance(1), true);
					}
				}
			}
		});
		// Voxel n is a 1x1x1 cube centered at n; stand on its top face.
		m_spawn_y = (float)surface_y + 0.5f + PLAYER_HEIGHT / 2.0f + 0.05f;
		m_spawn_ready = true;
		log_i(MODULE, "Spawn at (%i, %.2f, %i) (terrain y=%i)",
				SPAWN_X, m_spawn_y, SPAWN_Z, surface_y);

		network::access(m_server, [&](network::Interface *inetwork){
			std::ostringstream os(std::ios::binary);
			cereal::PortableBinaryOutputArchive ar(os);
			double x = SPAWN_X;
			double y = m_spawn_y;
			double z = SPAWN_Z;
			ar(x, y, z);
			ss_ data = os.str();
			for(auto peer : inetwork->list_peers())
				inetwork->send(peer, "main:spawn", data);
		});
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

	void on_place_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 voxel_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		}
		log_v(MODULE, "C%i: on_place_voxel(): p=" PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(voxel_p));

		pin_section_at_voxel(voxel_p);
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *instance)
		{
			instance->set_voxel(voxel_p, VoxelInstance(2));
		});
	}

	void on_dig_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 voxel_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		}
		log_v(MODULE, "C%i: on_dig_voxel(): p=" PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(voxel_p));

		pin_section_at_voxel(voxel_p);
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *instance)
		{
			instance->set_voxel(voxel_p, VoxelInstance(1));
		});
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &event)
	{
		log_t(MODULE, "on_worldgen_queue_modified()");
		m_worldgen_queue = event.queue_size;
		m_load_points_dirty = true;
		network::access(m_server, [&](network::Interface *inetwork){
			sv_<network::PeerInfo::Id> peers = inetwork->list_peers();
			for(auto &peer: peers){
				inetwork->send(peer, "main:worldgen_queue_size",
						itos(event.queue_size));
			}
		});
		try_resolve_spawn();
	}

	void on_player_pos(const network::Packet &packet)
	{
		double x, y, z;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(x, y, z);
		}
		m_player_voxel_p[packet.sender] = pv::Vector3DInt32(
				(int32_t)std::floor(x), (int32_t)std::floor(y),
				(int32_t)std::floor(z));
		m_load_points_dirty = true;
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		m_player_voxel_p.erase(old_client.info.id);
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
