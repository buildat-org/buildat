#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "main_context/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
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

namespace sample_server_entities {

using namespace Urho3D;

using interface::Event;
using main_context::SceneReference;

struct Module: public interface::Module
{
	interface::Server *m_server;
	uint m_slow_count = 0;

	SceneReference m_main_scene;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		log_v(MODULE, "sample_server_entities construct");
	}

	~Module()
	{
		log_v(MODULE, "sample_server_entities destruct");
	}

	void init()
	{
		log_v(MODULE, "sample_server_entities init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();

			Scene *scene = imc->check_scene(m_main_scene);
			Context *context = scene->GetContext();
			ResourceCache *cache = context->GetSubsystem<ResourceCache>();
			auto *m = cache->GetResource<Material>("Materials/Stone.xml");
			// NOTE: Modified or created materials will not be replicated to the
			//       client. Make sure to always have a resource file or create
			//       the material on the client.
			/*m->SetTexture(TU_DIFFUSE,
					cache->GetResource<Texture2D>("main/green_texture.png"));*/
			/*Material *m = new Material(context);
			m->SetTexture(TU_DIFFUSE,
					cache->GetResource<Texture2D>("main/green_texture.png"));
			m->SetTechnique(0, cache->GetResource<Technique>(
					"Techniques/Diff.xml"));*/

			{
				Node *node = scene->CreateChild("DirectionalLight");
				node->SetDirection(Vector3(-0.6f, -1.0f, 0.8f));
				Light *light = node->CreateComponent<Light>();
				light->SetLightType(LIGHT_DIRECTIONAL);
				light->SetCastShadows(true);
			}
			{
				Node *n = scene->CreateChild("Plane");
				n->SetPosition(Vector3(0.0f, -0.5f, 0.0f));
				n->SetScale(Vector3(10.0f, 1.0f, 10.0f));
				RigidBody *body = n->CreateComponent<RigidBody>();
				CollisionShape *shape = n->CreateComponent<CollisionShape>();
				shape->SetBox(Vector3::ONE);
				body->SetFriction(0.75f);
				StaticModel *object = n->CreateComponent<StaticModel>();
				object->SetModel(cache->GetResource<Model>("Models/Box.mdl"));
				object->SetMaterial(m);
				object->SetCastShadows(true);
			}
			{
				Node *n = scene->CreateChild("Box");
				n->SetPosition(Vector3(0.0f, 6.0f, 0.0f));
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
				RigidBody *body = n->CreateComponent<RigidBody>();
				CollisionShape *shape = n->CreateComponent<CollisionShape>();
				shape->SetBox(Vector3::ONE);
				body->SetMass(1.0);
				body->SetFriction(0.75f);
				// Model and material is set on client
			}
			{
				Node *n = scene->CreateChild("Box2");
				n->SetPosition(Vector3(-0.4f, 8.0f, 0.0f));
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
				RigidBody *body = n->CreateComponent<RigidBody>();
				CollisionShape *shape = n->CreateComponent<CollisionShape>();
				shape->SetBox(Vector3::ONE);
				body->SetMass(1.0);
				body->SetFriction(0.75f);
				//body->SetUseGravity(true);
				//body->SetGravityOverride(Vector3(0.0, -1.0, 0.0));
				StaticModel *object = n->CreateComponent<StaticModel>();
				object->SetModel(cache->GetResource<Model>("Models/Box.mdl"));
				object->SetMaterial(m);
				object->SetCastShadows(true);
			}
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		log_d(MODULE, "sample_server_entities::on_tick");
		static uint a = 0;
		if(((a++) % 100) == 0){
			main_context::access(m_server, [&](main_context::Interface *imc){
				Scene *scene = imc->check_scene(m_main_scene);
				Node *n = scene->GetChild("Box");
				n->SetPosition(Vector3(0.0f, 6.0f, 0.0f));
				n->SetRotation(Quaternion(30, 60, 90));
				Node *n2 = scene->GetChild("Box2");
				n2->SetPosition(Vector3(-0.4f, 8.0f, 0.0f));
				n2->SetRotation(Quaternion(30, 60, 90));
				m_slow_count++;
				if(m_slow_count == 2){
					Node *n = scene->CreateChild("Box");
					n->SetPosition(Vector3(0.0f, 10.0f, 0.0f));
					n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
					RigidBody *body = n->CreateComponent<RigidBody>();
					CollisionShape *shape = n->CreateComponent<CollisionShape>();
					shape->SetBox(Vector3::ONE);
					body->SetMass(1.0);
					body->SetFriction(0.75f);
					// Model and material is set on client
				}
			});
			return;
		}
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_main_scene);
			Node *n = scene->GetChild("Box");
			//n->Translate(Vector3(0.1f, 0, 0));
			Vector3 p = n->GetPosition();
			log_v(MODULE, "Position: %s", p.ToString().CString());
		});
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
		log_v(MODULE, "sample_server_entities::on_client_connected: id=%zu",
				client_connected.info.id);
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		log_v(MODULE, "sample_server_entities::on_client_disconnected: id=%zu",
				old_client.info.id);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		log_v(MODULE, "on_files_transmitted(): recipient=%zu", event.recipient);

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
