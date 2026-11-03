// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [VOXEL_OBJECTS] Voxel houses standing turned on builtin/heightmap's hills:
// builtin/voxel_objects' models (a 16^3 house, a 40x20x40 keep of four
// chunks, a 16x1x2 beam), BUILDAT_VOXEL_OBJECTS_COPIES houses (100 unless
// set) each at its own yaw and a slight tilt, the keep, and a beam floating
// at 45 degrees over a flat pad with a ball dropped on its far end: the
// ball rests on the beam only if the beam's collision is turned with it.
// E edits both models in place: the house gets a chimney (every copy) and
// the beam loses its far end, so the ball falls to the pad. The voxel types
// are voxelworld's, a world that loads nothing, for the registry alone;
// the models and the map are saved.
#include "core/log.h"
#include "client_file/api.h"
#include "heightmap/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "voxel_objects/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include <Scene.h>
#include <Node.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#define MODULE "main"

using interface::Event;
using main_context::SceneReference;
using namespace Urho3D;
namespace pv = PolyVox;

namespace main {

static const uint32_t SEED = 77;
static const float BALL_RADIUS = 0.5f;
// Where the beam floats and the ball drops: a flat pad away from the houses
static const float BEAM_X = 300, BEAM_Z = 120, BEAM_OVER = 6;
static const float BEAM_YAW = 45;
static const int PAD_HALF = 14;
// The houses' grid
static const float GRID0 = 20, GRID_STEP = 21;
static const float KEEP_X = 360, KEEP_Z = 360;

struct Module: public interface::Module
{
	interface::Server *m_server;
	SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	uint m_ball_id = 0;
	float m_still_s = 0;
	bool m_rest_said = false;
	Vector3 m_beam_pos;
	float m_pad_y = 0;
	interface::VoxelTypeId m_cobble = 0, m_wood = 0, m_log = 0;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:edit"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:edit",
				on_edit, network::Packet)
	}

	interface::VoxelTypeId add_voxel(interface::VoxelRegistry *reg,
			const ss_ &name, const ss_ &texture)
	{
		interface::VoxelDefinition vdef;
		vdef.name.block_name = name;
		for(size_t i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = vdef.textures[i];
			seg.resource_name = texture;
			seg.total_segments = IntVector2(1, 1);
			seg.select_segment = IntVector2(0, 0);
		}
		vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
		vdef.physically_solid = true;
		return reg->add_voxel(vdef);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});
		storage::access(m_server, [&](storage::Interface *i){
			m_save = i->open("main");
			if(!m_save)
				m_save = i->create("main");
		});
		heightmap::Size size;
		size.chunks_x = size.chunks_z = 8; // 512 m a side
		size.materials = 5;
		heightmap::access(m_server, [&](heightmap::Interface *ih){
			heightmap::Instance *map = ih->create_instance(m_scene, size);
			if(!map->set_save(m_save, "main")){
				heightmap::GenerateParams params;
				params.seed = SEED;
				map->generate(params);
				make_pad(map);
			}
			m_pad_y = map->height_at(BEAM_X, BEAM_Z);
			map->commit();
		});
		// The registry's world: nothing loaded, ever
		voxelworld::access(m_server, [&](voxelworld::Interface *iv){
			iv->create_instance(m_scene, pv::Region(0, 0, 0, 0, 0, 0));
			voxelworld::Instance *w = iv->get_instance(m_scene);
			w->set_load_points({});
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			reg->set_format(interface::VoxelFormat::blocks());
			m_cobble = add_voxel(reg, "cobble", "main/cobble.png");
			m_wood = add_voxel(reg, "wood", "main/wood.png");
			m_log = add_voxel(reg, "log", "main/tree.png");
		});
		int copies = 100;
		if(const char *e = getenv("BUILDAT_VOXEL_OBJECTS_COPIES"))
			copies = std::max(0, atoi(e));
		voxel_objects::access(m_server, [&](voxel_objects::Interface *iv){
			voxel_objects::Instance *vo = iv->create_instance(m_scene);
			vo->set_save(m_save, "main");
			voxel_objects::Model *house = vo->create_model("house", 16, 16, 16);
			if(!house->loaded())
				build_house(house);
			voxel_objects::Model *keep = vo->create_model("keep", 40, 20, 40);
			if(!keep->loaded())
				build_keep(keep);
			voxel_objects::Model *beam = vo->create_model("beam", 16, 1, 2);
			if(!beam->loaded())
				for(int x = 0; x < 16; x++)
					for(int z = 0; z < 2; z++)
						beam->set_voxel(x, 0, z, m_wood);
			log_i(MODULE, "sample_voxel_objects: models %s: house %08x,"
					" keep %08x, beam %08x", house->loaded() ? "loaded" :
					"built", house->content_hash(), keep->content_hash(),
					beam->content_hash());
		});
		place_objects(copies);
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene);
			Node *n = scene->CreateChild("ball");
			m_ball_id = n->GetID();
			RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
			body->SetMass(1.0f);
			body->SetFriction(0.8f);
			body->SetRollingFriction(0.1f);
			body->SetAngularDamping(0.3f);
			n->CreateComponent<CollisionShape>(LOCAL)->SetSphere(
					BALL_RADIUS * 2);
		});
		drop_ball();
	}

	void on_unload()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_scene);
		});
	}

	// Flat gravel where the beam is
	void make_pad(heightmap::Instance *map)
	{
		const int cx = (int)BEAM_X, cz = (int)BEAM_Z;
		const float h = map->get_height(cx, cz);
		heightmap::Weights gravel{};
		gravel[4] = 255;
		for(int z = cz - PAD_HALF; z <= cz + PAD_HALF; z++)
			for(int x = cx - PAD_HALF; x <= cx + PAD_HALF; x++){
				map->set_height(x, z, h);
				map->set_weights(x, z, gravel);
			}
	}

	// A cobble house with log corners, a wood floor, a door, windows and a
	// gabled wood roof along x
	void build_house(voxel_objects::Model *m)
	{
		for(int z = 0; z < 16; z++)
		for(int x = 0; x < 16; x++){
			m->set_voxel(x, 0, z, m_wood);
			const bool edge_x = x == 0 || x == 15, edge_z = z == 0 || z == 15;
			if(!edge_x && !edge_z)
				continue;
			for(int y = 1; y <= 6; y++){
				const bool door = z == 0 && (x == 7 || x == 8) && y <= 3;
				const bool window = y >= 3 && y <= 4 && ((edge_x &&
						(z == 4 || z == 5 || z == 10 || z == 11)) ||
						(z == 15 && (x == 4 || x == 5 || x == 10 || x == 11)));
				if(door || window)
					continue;
				m->set_voxel(x, y, z, edge_x && edge_z ? m_log : m_cobble);
			}
		}
		for(int k = 0; k < 8; k++){
			const int y = 7 + k;
			for(int x = 0; x < 16; x++){
				m->set_voxel(x, y, k, m_wood);
				m->set_voxel(x, y, 15 - k, m_wood);
			}
			// The gables
			for(int z = k + 1; z < 15 - k; z++){
				m->set_voxel(0, y, z, m_cobble);
				m->set_voxel(15, y, z, m_cobble);
			}
		}
	}

	// A hollow keep over two chunks each way: walls, a floor, battlements
	void build_keep(voxel_objects::Model *m)
	{
		for(int z = 0; z < 40; z++)
		for(int x = 0; x < 40; x++){
			m->set_voxel(x, 0, z, m_cobble);
			const bool wall = x < 2 || x > 37 || z < 2 || z > 37;
			if(!wall)
				continue;
			const bool gate = z < 2 && x >= 18 && x <= 21;
			for(int y = 1; y < 18; y++)
				if(!(gate && y <= 6))
					m->set_voxel(x, y, z, y == 17 ? m_log : m_cobble);
			// Battlements: every other pair
			if(((x + z) / 2) % 2 == 0){
				m->set_voxel(x, 18, z, m_cobble);
				m->set_voxel(x, 19, z, m_cobble);
			}
		}
	}

	void place_objects(int copies)
	{
		// The ground's height at a few points under a footprint, the lowest
		sv_<Vector3> houses;
		float keep_y = 0;
		heightmap::access(m_server, m_scene, [&](heightmap::Instance *map){
			for(int i = 0; i < copies; i++){
				const float cx = GRID0 + (i % 10) * GRID_STEP + 8;
				const float cz = GRID0 + (i / 10) * GRID_STEP + 8;
				float y = map->height_at(cx, cz);
				for(int c = 0; c < 4; c++)
					y = std::min(y, map->height_at(cx + (c & 1 ? 7 : -7),
							cz + (c & 2 ? 7 : -7)));
				houses.push_back(Vector3(cx, y, cz));
			}
			keep_y = map->height_at(KEEP_X, KEEP_Z);
			for(int c = 0; c < 4; c++)
				keep_y = std::min(keep_y, map->height_at(
						KEEP_X + (c & 1 ? 20 : -20), KEEP_Z + (c & 2 ? 20 : -20)));
		});
		voxel_objects::access(m_server, m_scene, [&](voxel_objects::Instance *vo){
			for(size_t i = 0; i < houses.size(); i++){
				// Each its own yaw and a tilt of up to 4 degrees, about the
				// middle of its floor
				const Quaternion q((float)((i * 7) % 9) - 4.0f,
						(float)(i * 37 % 360), (float)((i * 5) % 9) - 4.0f);
				const Vector3 p = houses[i] - q * Vector3(8, 0.5f, 8);
				vo->create_object("house", p, q);
			}
			const Quaternion kq(0, 20, 0);
			vo->create_object("keep", Vector3(KEEP_X, keep_y - 1, KEEP_Z) -
					kq * Vector3(20, 0, 20), kq);
			// The beam's middle over the pad's middle
			const Quaternion bq(0, BEAM_YAW, 0);
			m_beam_pos = Vector3(BEAM_X, m_pad_y + BEAM_OVER, BEAM_Z) -
					bq * Vector3(8, 0, 1);
			vo->create_object("beam", m_beam_pos, bq);
			log_i(MODULE, "sample_voxel_objects: %zu objects placed",
					vo->num_objects());
		});
	}

	// Over the beam's far end: voxel (14, 0, 1)'s top middle, turned with
	// the beam. Unturned, that point is 11 m off the beam
	Vector3 drop_point()
	{
		return m_beam_pos + Quaternion(0, BEAM_YAW, 0) * Vector3(14.5f, 1, 1);
	}

	void drop_ball()
	{
		const Vector3 p = drop_point() + Vector3(0, 4, 0);
		main_context::access(m_server, [&](main_context::Interface *imc){
			Node *n = imc->check_scene(m_scene)->GetNode(m_ball_id);
			n->SetPosition(p);
			RigidBody *body = n->GetComponent<RigidBody>();
			body->SetLinearVelocity(Vector3::ZERO);
			body->SetAngularVelocity(Vector3::ZERO);
			body->Activate();
		});
		m_still_s = 0;
		m_rest_said = false;
	}

	void on_tick(const interface::TickEvent &event)
	{
		Vector3 p, v;
		main_context::access(m_server, [&](main_context::Interface *imc){
			Node *n = imc->check_scene(m_scene)->GetNode(m_ball_id);
			if(!n)
				return;
			p = n->GetPosition();
			v = n->GetComponent<RigidBody>()->GetLinearVelocity();
		});
		if(v.Length() < 0.02f)
			m_still_s += event.dtime;
		else
			m_still_s = 0, m_rest_said = false;
		if(m_still_s > 1.0f && !m_rest_said){
			m_rest_said = true;
			const float beam_top = drop_point().y_;
			log_i(MODULE, "sample_voxel_objects: the ball rests at (%.2f,"
					" %.3f, %.2f): %.3f over the beam's top, %.3f over the"
					" pad", p.x_, p.y_, p.z_, p.y_ - beam_top, p.y_ - m_pad_y);
			// [VOXEL_OBJECTS_UNLOAD_LOSS] check.sh's: the edit made and the
			// server stopped before a tick commits it
			if(getenv("BUILDAT_VOXEL_OBJECTS_EDIT_STOP")){
				edit(false);
				m_server->shutdown(0, "sample_voxel_objects: edited, stopping");
			}
		}
	}

	// The house's chimney and the beam's far end gone
	void edit(bool commit)
	{
		voxel_objects::access(m_server, m_scene, [&](voxel_objects::Instance *vo){
			voxel_objects::Model *house = vo->get_model("house");
			for(int y = 11; y < 16; y++)
				for(int x = 11; x <= 12; x++)
					house->set_voxel(x, y, 4, m_cobble);
			voxel_objects::Model *beam = vo->get_model("beam");
			for(int x = 10; x < 16; x++)
				for(int z = 0; z < 2; z++)
					beam->set_voxel(x, 0, z, 0);
			if(commit)
				vo->commit();
			log_i(MODULE, "sample_voxel_objects: edited: beam %08x, house"
					" %08x, keep %08x", beam->content_hash(),
					house->content_hash(),
					vo->get_model("keep")->content_hash());
		});
	}

	void on_edit(const network::Packet &packet)
	{
		edit(true);
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->check_scene(m_scene)->GetNode(m_ball_id)->
					GetComponent<RigidBody>()->Activate();
		});
		m_still_s = 0;
		m_rest_said = false;
		log_i(MODULE, "sample_voxel_objects: edited: a chimney, the beam's"
				" end gone");
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *irep){
			irep->assign_scene_to_peer(m_scene, event.recipient);
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
