#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "main_context/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include <Scene.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <ResourceCache.h>
#include <Context.h>
#include <StaticModel.h>
#include <Model.h>
#include <Material.h>
#include <Texture2D.h>
#include <Technique.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#define MODULE "main"

namespace geometry {

namespace magic = Urho3D;
using namespace Urho3D;
using interface::Event;
using main_context::SceneReference;

struct Module: public interface::Module
{
	interface::Server *m_server;
	uint m_slow_count = 0;
	sp_<interface::AtlasRegistry> m_atlas_reg;
	sp_<interface::VoxelRegistry> m_voxel_reg;

	SceneReference m_main_scene;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		m_voxel_reg.reset(interface::createVoxelRegistry());
		// 0.6's cut, which its saves, its checks and its code were written
		// for
		m_voxel_reg->set_format(interface::VoxelFormat::buildat_legacy_06());
	}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));

		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();

			Scene *scene = imc->check_scene(m_main_scene);
			Context *context = scene->GetContext();
			m_atlas_reg.reset(interface::createAtlasRegistry(context));
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "air";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "";
					seg.total_segments = magic::IntVector2(0, 0);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.edge_material_id = interface::EDGEMATERIALID_EMPTY;
				vdef.fully_empty = true;
				m_voxel_reg->add_voxel(vdef); // id 1
			}
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "ground";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "main/green_texture.png";
					seg.total_segments = magic::IntVector2(1, 1);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
				vdef.physically_solid = true;
				m_voxel_reg->add_voxel(vdef); // id 2
			}
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "testblock";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "main/pink_texture.png";
					seg.total_segments = magic::IntVector2(1, 1);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
				vdef.physically_solid = true;
				m_voxel_reg->add_voxel(vdef); // id 3
			}
		});
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc)
		{
			Scene *scene = imc->check_scene(m_main_scene);
			Context *context = scene->GetContext();
			ResourceCache *cache = context->GetSubsystem<ResourceCache>();

			{
				Node *node = scene->CreateChild("DirectionalLight");
				node->SetDirection(Vector3(-0.6f, -1.0f, 0.8f));
				Light *light = node->CreateComponent<Light>();
				light->SetLightType(LIGHT_DIRECTIONAL);
				light->SetCastShadows(true);
			}
			{
				Node *n = scene->CreateChild("Base");
			}
			{
				Node *n = scene->CreateChild("Testbox");
				n->SetPosition(Vector3(0.0f, 6.0f, 0.0f));
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));

				/*int w = 1, h = 1, d = 1;
				ss_ data = "1";*/
				int w = 2, h = 2, d = 1;
				ss_ data = "1333";

				// Convert data to the actually usable voxel type id namespace
				// starting from VOXELTYPEID_UNDEFINED=0
				for(size_t i = 0; i < data.size(); i++){
					data[i] = data[i] - '0';
				}

				// Crude way of dynamically defining a voxel model
				n->SetVar(StringHash("simple_voxel_data"), Variant(
						PODVector<uint8_t>((const uint8_t*)data.c_str(),
						data.size())));
				n->SetVar(StringHash("simple_voxel_w"), Variant(w));
				n->SetVar(StringHash("simple_voxel_h"), Variant(h));
				n->SetVar(StringHash("simple_voxel_d"), Variant(d));

				// Load the same model in here and give it to the physics
				// subsystem so that it can be collided to
				SharedPtr<Model> model(interface::mesh::
						create_8bit_voxel_physics_model(context, w, h, d, data,
						m_voxel_reg.get()));

				RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
				body->SetFriction(0.75f);
				body->SetMass(1.0);
				CollisionShape *shape = n->CreateComponent<CollisionShape>(
						LOCAL);
				shape->SetConvexHull(model, 0, Vector3::ONE);
				//shape->SetTriangleMesh(model, 0, Vector3::ONE);
				//shape->SetBox(Vector3::ONE);
			}
		});

		update_scene();
	}

	void on_continue()
	{
		update_scene();
	}

	void update_scene()
	{
		main_context::access(m_server, [&](main_context::Interface *imc)
		{
			Scene *scene = imc->check_scene(m_main_scene);
			Context *context = scene->GetContext();
			ResourceCache *cache = context->GetSubsystem<ResourceCache>();

			{
				Node *n = scene->GetChild("Base");
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
				//n->SetPosition(Vector3(0.0f, 0.5f, 0.0f));
				n->SetPosition(Vector3(0.0f, 0.5f, 0.0f));
				//n->SetRotation(Quaternion(0, 90, 0));

				int w = 10, h = 3, d = 10;
				ss_ data =
						"222222222211211111211111111111"
						"222222222211111111111111111111"
						"222222222211111111111111111111"
						"222222222211111111111111111111"
						"222222222211122111111112111111"
						"222233222211123111111112111111"
						"222233222211111111111111111111"
						"222222222211111111111111111111"
						"222222222211111111111111111111"
						"222222222211111111111111111111"
						;

				// Convert data to the actually usable voxel type id namespace
				// starting from VOXELTYPEID_UNDEFINED=0
				for(size_t i = 0; i < data.size(); i++){
					data[i] = data[i] - '0';
				}

				// Crude way of dynamically defining a voxel model
				n->SetVar(StringHash("simple_voxel_data"), Variant(
						PODVector<uint8_t>((const uint8_t*)data.c_str(),
						data.size())));
				n->SetVar(StringHash("simple_voxel_w"), Variant(w));
				n->SetVar(StringHash("simple_voxel_h"), Variant(h));
				n->SetVar(StringHash("simple_voxel_d"), Variant(d));

				// Load the same model in here and give it to the physics
				// subsystem so that it can be collided to
				SharedPtr<Model> model(interface::mesh::
						create_8bit_voxel_physics_model(context, w, h, d, data,
						m_voxel_reg.get()));

				RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
				body->SetFriction(0.75f);
				CollisionShape *shape = n->CreateComponent<CollisionShape>(
						LOCAL);
				shape->SetTriangleMesh(model, 0, Vector3::ONE);
			}
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		static uint a = 0;
		if(((a++) % 100) == 0){
			main_context::access(m_server, [&](main_context::Interface *imc){
				Scene *scene = imc->check_scene(m_main_scene);
				Node *n = scene->GetChild("Testbox");
				//n->SetPosition(Vector3(0.0f, 8.0f, 0.0f));
				n->SetRotation(Quaternion(30, 60, 90));
				//n->SetPosition(Vector3(0.0f, 6.0f, 0.0f));
				//n->SetPosition(Vector3(0.0f, 4.0f, 0.0f));
				n->SetPosition(Vector3(-0.5f, 8.0f, 0.0f));
			});
			return;
		}
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		// The client script is run by the engine (meta.json's client_main,
		// [ENGINE_LOADER]); this assigns the scene the script draws.
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
