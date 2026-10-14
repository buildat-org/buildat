// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
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
#include <Scene.h>
#include <Node.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <Context.h>
#include <cmath>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelVolume;
using main_context::SceneReference;

namespace main
{

using namespace Urho3D;

// One section, so the whole scene is 64x64x64 voxels at 0..63 on each axis
static const int VOLUME_SIZE = 64;

// The terrain is a bowl rather than demo_digger's noise: what this game is for is
// watching rigid bodies fall onto voxel terrain, and a bowl keeps them in
// frame without anything having to herd them back.
static const float BOWL_FLOOR_Y = 16.0f;
static const float BOWL_RIM_Y = 34.0f;
static const int GRASS_DEPTH = 1;

static const uint8_t AIR_ID = 1;
static const uint8_t ROCK_ID = 2;
static const uint8_t GRASS_ID = 3;
static const uint8_t PIECE_ID = 4;

// Pieces are dropped one at a time and the oldest is reused once there are
// this many, so the scene neither empties nor grows without bound
static const size_t NUM_PIECES = 24;
static const float DROP_INTERVAL = 0.7f;
static const float DROP_HEIGHT = 46.0f;
static const float DROP_SPREAD = 7.0f;

// Each piece is a random connected shape inside this box, so that what lands
// interlocks instead of stacking like boxes
static const int PIECE_S = 3;
static const int PIECE_MIN_VOXELS = 4;
static const int PIECE_MAX_VOXELS = 10;

static float bowl_surface(float x, float z)
{
	float c = VOLUME_SIZE / 2.0f;
	float dx = (x - c) / c, dz = (z - c) / c;
	float r2 = dx * dx + dz * dz;
	if(r2 > 1.0f)
		r2 = 1.0f;
	return BOWL_FLOOR_Y + (BOWL_RIM_Y - BOWL_FLOOR_Y) * r2;
}

struct Worldgen: public worldgen::GeneratorInterface
{
	// Runs in a worker thread with no module held, so it writes the voxels
	// into the volume it is given rather than into the world
	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
		const pv::Region region = volume.getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();

		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				float a = bowl_surface(x, z);
				for(int y = lc.getY(); y <= uc.getY(); y++){
					uint8_t id = AIR_ID;
					if(y < a - GRASS_DEPTH)
						id = ROCK_ID;
					else if(y < a)
						id = GRASS_ID;
					volume.setVoxelAt(pv::Vector3DInt32(x, y, z),
							VoxelInstance(id));
				}
			}
		}
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	SceneReference m_main_scene;
	Worldgen *m_worldgen = nullptr;
	sv_<uint> m_piece_node_ids;
	size_t m_next_piece = 0;
	float m_drop_timer = 0.0f;
	interface::PseudoRandom m_random{4242};

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

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
				"network:packet_received/main:reset"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:reset",
				on_reset, network::Packet)
	}

	// The six numbers after solid describe the surface; see interface/atlas.h
	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool solid, float roughness = 0.9f,
			float spec_strength = 1.0f, float bumpiness = 1.0f)
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
			seg.resource_name = texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
			seg.roughness = roughness;
			seg.spec_strength = spec_strength;
			seg.bumpiness = bumpiness;
		}
		vdef.edge_material_id = solid ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		// What is not solid here is air: the sky passes it and a merge
		// counts it as nothing standing there
		vdef.fully_empty = !solid;
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
			m_worldgen = new Worldgen();
			iworldgen->get_instance(m_main_scene)->set_generator(m_worldgen);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			// A single section: the whole scene, never streamed. Physics on,
			// so the chunk nodes get collision shapes: that is what the
			// pieces fall on, and this is the one game whose server
			// simulates something against the terrain.
			pv::Region region(0, 0, 0, 0, 0, 0);
			ivoxelworld->create_instance(m_main_scene, region, true);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world = ivoxelworld->
					get_instance(m_main_scene);
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			// 0.6's cut, which its saves, its checks and its code were written
			// for
			reg->set_format(interface::VoxelFormat::buildat_legacy_06());
			add_voxel(reg, "air", "", false);                        // id 1
			add_voxel(reg, "rock", "main/rock.png", true,
					0.95f, 0.15f, 0.5f);                             // id 2
			add_voxel(reg, "grass", "main/grass.png", true,
					0.90f, 1.0f, 0.75f);                             // id 3
			add_voxel(reg, "piece", "main/piece.png", true,
					0.60f, 1.0f, 1.0f);                              // id 4

			// Lets voxel_shading shade the terrain; the pieces are not part
			// of the voxel world and are lit by the scene's lights alone
			world->set_skylight_enabled(true);
		});

		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			instance->enable();
		});

		create_pieces();

		log_v(MODULE, "sample_falling_blocks: %ix%ix%i scene, %zu pieces",
				VOLUME_SIZE, VOLUME_SIZE, VOLUME_SIZE, NUM_PIECES);
	}

	void on_unload()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_main_scene);
		});
	}

	void on_continue()
	{
		on_start();
	}

	// A random connected shape inside a PIECE_S^3 box, grown from the middle
	// voxel by repeatedly adding a face neighbour of what is already there.
	// Grown rather than sampled and tested, so it cannot come out in two
	// pieces and there is nothing to retry.
	ss_ random_piece_data()
	{
		const int S = PIECE_S;
		ss_ data((size_t)S * S * S, (char)AIR_ID);
		auto idx = [&](int x, int y, int z){
			return (size_t)((z * S + y) * S + x);
		};
		int target = m_random.range(PIECE_MIN_VOXELS, PIECE_MAX_VOXELS);
		sv_<pv::Vector3DInt32> filled;
		pv::Vector3DInt32 p(S/2, S/2, S/2);
		data[idx(p.getX(), p.getY(), p.getZ())] = (char)PIECE_ID;
		filled.push_back(p);
		static const int off[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}
		};
		// Bounded because a shape that fills its box has nowhere left to grow
		for(int tries = 0; (int)filled.size() < target && tries < 200; tries++){
			const pv::Vector3DInt32 &f = filled[m_random.range(
					0, (int)filled.size() - 1)];
			const int *o = off[m_random.range(0, 5)];
			int x = f.getX() + o[0], y = f.getY() + o[1], z = f.getZ() + o[2];
			if(x < 0 || y < 0 || z < 0 || x >= S || y >= S || z >= S)
				continue;
			if(data[idx(x, y, z)] == (char)PIECE_ID)
				continue;
			data[idx(x, y, z)] = (char)PIECE_ID;
			filled.push_back(pv::Vector3DInt32(x, y, z));
		}
		return data;
	}

	// A piece is a voxel model on both sides: the client meshes it out of the
	// same voxel registry the terrain uses, and the server collides one box
	// per voxel. A convex hull would be quicker but wrong: the whole point of
	// these shapes is that they are not convex.
	void create_pieces()
	{
		m_piece_node_ids.clear();
		main_context::access(m_server, [&](main_context::Interface *imc)
		{
			Scene *scene = imc->check_scene(m_main_scene);

			for(size_t i = 0; i < NUM_PIECES; i++){
				ss_ data = random_piece_data();

				Node *n = scene->CreateChild("Piece");
				// Parked outside the volume until it is dropped, so that
				// nothing stands in the air waiting at the start
				n->SetPosition(Vector3(0.0f, -100.0f, 0.0f));

				n->SetVar(StringHash("simple_voxel_data"), Variant(
						PODVector<uint8_t>((const uint8_t*)data.c_str(),
						data.size())));
				n->SetVar(StringHash("simple_voxel_w"), Variant(PIECE_S));
				n->SetVar(StringHash("simple_voxel_h"), Variant(PIECE_S));
				n->SetVar(StringHash("simple_voxel_d"), Variant(PIECE_S));

				RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
				body->SetFriction(0.75f);
				body->SetMass(1.0f);
				// The mesher centers the model on the node, so voxel (x, y, z)
				// of a PIECE_S^3 box sits here
				for(int z = 0; z < PIECE_S; z++)
				for(int y = 0; y < PIECE_S; y++)
				for(int x = 0; x < PIECE_S; x++){
					if(data[(size_t)((z * PIECE_S + y) * PIECE_S + x)] !=
							(char)PIECE_ID)
						continue;
					CollisionShape *shape =
							n->CreateComponent<CollisionShape>(LOCAL);
					shape->SetBox(Vector3::ONE, Vector3(
							x - PIECE_S / 2.0f + 0.5f,
							y - PIECE_S / 2.0f + 0.5f,
							z - PIECE_S / 2.0f + 0.5f));
				}

				m_piece_node_ids.push_back(n->GetID());
			}
		});
		m_next_piece = 0;
	}

	interface::VoxelRegistry* get_voxel_reg()
	{
		interface::VoxelRegistry *reg = nullptr;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world){
			reg = world->get_voxel_reg();
		});
		return check(reg);
	}

	void drop_next_piece()
	{
		if(m_piece_node_ids.empty())
			return;
		uint node_id = m_piece_node_ids[m_next_piece];
		m_next_piece = (m_next_piece + 1) % m_piece_node_ids.size();

		float c = VOLUME_SIZE / 2.0f;
		float x = c + m_random.range(-1000, 1000) / 1000.0f * DROP_SPREAD;
		float z = c + m_random.range(-1000, 1000) / 1000.0f * DROP_SPREAD;

		main_context::access(m_server, [&](main_context::Interface *imc)
		{
			Scene *scene = imc->check_scene(m_main_scene);
			Node *n = scene->GetNode(node_id);
			if(!n)
				return;
			n->SetPosition(Vector3(x, DROP_HEIGHT, z));
			n->SetRotation(Quaternion(
					m_random.range(0, 360), m_random.range(0, 360),
					m_random.range(0, 360)));
			RigidBody *body = n->GetComponent<RigidBody>();
			if(body){
				body->SetLinearVelocity(Vector3::ZERO);
				body->SetAngularVelocity(Vector3::ZERO);
				// The body sleeps once its pile settles; a moved node does
				// not wake it by itself
				body->Activate();
			}
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		m_drop_timer += event.dtime;
		if(m_drop_timer < DROP_INTERVAL)
			return;
		m_drop_timer = 0.0f;
		drop_next_piece();
	}

	void on_reset(const network::Packet &packet)
	{
		log_v(MODULE, "C%i: reset", packet.sender);
		main_context::access(m_server, [&](main_context::Interface *imc)
		{
			Scene *scene = imc->check_scene(m_main_scene);
			for(uint node_id : m_piece_node_ids){
				Node *n = scene->GetNode(node_id);
				if(n)
					n->SetPosition(Vector3(0.0f, -100.0f, 0.0f));
			}
		});
		m_next_piece = 0;
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
