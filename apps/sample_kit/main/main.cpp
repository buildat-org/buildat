// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] sample_kit: an app hosting Kit, with a few components of its own
// (kit/*.lua) composed in composition.json: a button that opens and closes
// a door (which owns its voxel), a counter of the door's moves, a button
// out of reach, a component that never returns, and two relays that are a
// loop, on a stone floor (y 0) with a stone at (6, 1, 2) for the editor
// to point at; and of Kit's own types beside them ([KIT] stage 4b): its
// door (two authors' "door"), an item giver and a key door, on the
// players' inventory that sample_kit's pouch provides (a second pouch
// refused). Players stand at (0, 1, 0) of the scene "world"; a client's "d"
// key is a dig at the door, a write routed to the door. util/kit_runtime_check.sh
// drives it. A player is "p<peer>", or their account's name once logged in
// (the client logs in when BUILDAT_JOIN_NAME is set); the server's admin
// and the builders edit with Kit's editor (util/kit_editor_check.sh).
// The floor is laid once a save, merged as a generator's voxels (the
// start, not play's: the server starts Running, [KIT] stage 4c); a
// client's "p" key digs the pillar, the player's own write (a build),
// a region's rules asked there ([KIT] stage 4j; kit/guard.lua an allow
// hook on the prefab guarded_region).
#include "core/log.h"
#include "accounts/api.h"
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
namespace magic = Urho3D;
using interface::Event;

static const pv::Vector3DInt32 DOOR(4, 1, 0);
static const pv::Vector3DInt32 PILLAR(6, 1, 2);

struct Module: public interface::Module
{
	interface::Server *m_server;
	main_context::SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	ss_ m_door_voxel;
	bool m_floor = false;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	void init()
	{
		sub(m_server, "core:start", &Module::on_start);
		sub(m_server, "core:tick", &Module::on_tick);
		sub(m_server, "client_file:files_transmitted", &Module::on_files);
		sub(m_server, "network:packet_received/main:dig", &Module::on_dig);
		sub(m_server, "accounts:login", &Module::on_login);
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
			// [KIT_VOXEL_FORMAT] Kit's: id, param, tint, sky light
			reg->set_format(kit::voxel_format());
			for(const ss_ name : {"air", "stone", "glass"}){
				interface::VoxelDefinition def;
				def.name.block_name = name;
				def.fully_empty = name == "air";
				if(name != "air"){
					def.edge_material_id = interface::EDGEMATERIALID_GROUND;
					for(auto &seg : def.textures){
						seg.resource_name = "main/"+name+".png";
						seg.total_segments = magic::IntVector2(1, 1);
						seg.select_segment = magic::IntVector2(0, 0);
					}
				}
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
		ss_ v;
		m_floor = m_save->store("main")->get("floor", v);
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
			// Something for Kit's editor to point at: a stone floor under
			// x, z 0...15 and a stone at PILLAR, a generator's (the start)
			if(!m_floor){
				m_floor = true;
				interface::VoxelName stone;
				stone.block_name = "stone";
				const interface::VoxelInstance v(reg->get(stone)->id);
				interface::VoxelVolume f(pv::Region(0, 0, 0, 15, 1, 15));
				for(int x = 0; x < 16; x++)
					for(int z = 0; z < 16; z++)
						f.setVoxelAt(x, 0, z, v);
				f.setVoxelAt(PILLAR, v);
				w->merge_volume(f, false);
				m_save->store("main")->set("floor", "1");
			}
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
		ss_ name;
		// None in the web client's own server (builtin/accounts is native)
		if(m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *a){
				name = a->name_of(peer);
			});
		kit::access(m_server, [&](kit::Interface *k){
			k->set_peer(peer, name.empty() ? "p"+itos(peer) : name, "world",
					0, 1, 0);
		});
	}

	// Kit's edit rights follow the account: the admin's, a builder's
	void on_login(const accounts::Login &login)
	{
		kit::access(m_server, [&](kit::Interface *k){
			k->set_peer(login.peer, login.name, "world", 0, 1, 0);
		});
		log_i(MODULE, "sample_kit: peer %zu is %s", (size_t)login.peer,
				cs(login.name));
	}

	// A player digging at the door (or "pillar": the pillar): not the
	// game's own write, so routed; one made is the player's build
	void on_dig(const network::Packet &packet)
	{
		const bool pillar = packet.data == "pillar";
		const pv::Vector3DInt32 p = pillar ? PILLAR : DOOR;
		// [KIT] stage 4j: in a region its rules (and its allow hook) say
		// whether a player may dig there, edit mode aside ([KIT_BUILDER_PLAY_RULES]); outside every
		// region sample_kit lets anyone dig
		bool allowed = true;
		ss_ why;
		kit::access(m_server, [&](kit::Interface *k){
			if(!k->is_editing(packet.sender) && k->region_of(packet.sender,
					p.getX(), p.getY(), p.getZ()))
				allowed = k->allows(packet.sender, "dig", p.getX(), p.getY(),
						p.getZ(), &why);
		});
		if(!allowed){
			log_i(MODULE, "sample_kit: a dig at the %s: refused: %s",
					pillar ? "pillar" : "door", cs(why));
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(packet.sender, "kit:warning", why);
			});
			return;
		}
		bool written = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelName air;
			air.block_name = "air";
			const auto r = w->routed_set_voxel(p, interface::VoxelInstance(
					w->get_voxel_reg()->get(air)->id),
					"player:p"+itos(packet.sender));
			written = r == voxelworld::Instance::WRITTEN;
			log_i(MODULE, "sample_kit: a dig at the %s: %s", pillar ? "pillar" :
					"door", r == voxelworld::Instance::ROUTED ?
					"routed to its owner" : written ? "written" : "refused");
		});
		if(written)
			kit::access(m_server, [&](kit::Interface *k){
				k->player_wrote(packet.sender, p.getX(), p.getY(), p.getZ());
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
