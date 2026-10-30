// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] sample_kit: an app hosting Kit, with a few components of its own
// (kit/*.lua) composed in composition.json: a button that opens and closes
// a door (which owns its voxel), a counter of the door's moves, a button
// out of reach, a component that never returns, and two relays that are a
// loop. Players stand at (0, 1, 0) of the scene "world"; a client's "d"
// key is a dig at the door, a write routed to the door. util/kit_runtime_check.sh
// drives it. The first player to join is the owner, who edits with Kit's
// editor (util/kit_editor_check.sh).
#include "core/log.h"
#include "client_file/api.h"
#include "kit/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#define MODULE "main"

namespace sample_kit {

namespace pv = PolyVox;
using interface::Event;

static const pv::Vector3DInt32 DOOR(4, 1, 0);

struct Module: public interface::Module
{
	interface::Server *m_server;
	main_context::SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	ss_ m_door_voxel;
	// The owner: the first player to join this run, who has edit rights.
	// simplified: no builder grant and no owner kept over a restart;
	// accounts' admin, or a grant the owner makes, is the upgrade
	ss_ m_owner;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	void init()
	{
		sub(m_server, "core:start", &Module::on_start);
		sub(m_server, "core:tick", &Module::on_tick);
		sub(m_server, "client_file:files_transmitted", &Module::on_files);
		sub(m_server, "network:packet_received/main:dig", &Module::on_dig);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});
		storage::access(m_server, [&](storage::Interface *istorage){
			m_save = istorage->open("world");
			if(!m_save)
				m_save = istorage->create("world");
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			ivw->create_instance(m_scene, pv::Region(0, 0, 0, 0, 0, 0));
			voxelworld::Instance *world = ivw->get_instance(m_scene);
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			interface::VoxelFormat f;
			f.id = interface::VoxelField{0, 0, 16};
			reg->set_format(f);
			for(const char *name : {"air", "stone", "glass"}){
				interface::VoxelDefinition def;
				def.name.block_name = name;
				def.edge_material_id = interface::EDGEMATERIALID_GROUND;
				reg->add_voxel(def);
			}
			world->set_save(m_save, "main");
		});
		kit::Host h;
		h.types_path = m_server->get_module_path(MODULE)+"/kit";
		h.composition_path = m_server->get_module_path(MODULE)+
				"/composition.json";
		h.save = m_save;
		h.scenes["world"] = m_scene;
		if(!kit::host(m_server, h)){
			m_server->shutdown(1, "sample_kit: Kit is not hosted");
			return;
		}
		kit::access(m_server, [&](kit::Interface *k){
			log_i(MODULE, "sample_kit: at start the counter is %s, the door "
					"open %s", cs(k->get_state(5, 0, "count")),
					cs(k->get_state(4, 0, "open")));
		});
	}

	// The door's voxel as the world has it, logged when it changes
	void on_tick(const interface::TickEvent &)
	{
		ss_ name = m_door_voxel;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			if(!w->is_section_loaded(pv::Vector3DInt16(0, 0, 0)))
				return;
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			const interface::VoxelDefinition *def = reg->get(
					reg->get_format().id.get(w->get_voxel(DOOR).data));
			name = def ? def->name.block_name : "?";
		});
		if(name != m_door_voxel){
			m_door_voxel = name;
			log_i(MODULE, "sample_kit: the door's voxel is %s", cs(name));
		}
	}

	void on_files(const client_file::FilesTransmitted &event)
	{
		const size_t peer = event.recipient;
		replicate::assign_scene_to_peer(m_server, m_scene, peer);
		kit::access(m_server, [&](kit::Interface *k){
			k->set_peer(peer, "p"+itos(peer), "world", 0, 1, 0);
			if(m_owner.empty()){
				m_owner = "p"+itos(peer);
				k->set_editor(m_owner, true);
			}
		});
	}

	// A player digging at the door: not the game's own write, so routed
	void on_dig(const network::Packet &packet)
	{
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelName air;
			air.block_name = "air";
			const auto r = w->routed_set_voxel(DOOR, interface::VoxelInstance(
					w->get_voxel_reg()->get(air)->id),
					"player:p"+itos(packet.sender));
			log_i(MODULE, "sample_kit: a dig at the door: %s",
					r == voxelworld::Instance::ROUTED ? "routed to its owner" :
					r == voxelworld::Instance::WRITTEN ? "written" : "refused");
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
