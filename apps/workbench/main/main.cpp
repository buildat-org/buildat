// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] Workbench: the blank app that only hosts Kit and its editor. The
// world is Kit's World ([KIT] stage 4e, kit/world on the app root): by
// default a flat stone floor 64x64 round the origin, its top at y 0
// (Kit's material set, biome "rock"), the players walking on it (their
// client's physics, as demo_digger's); its generator, size and surface
// the World's parameters in the editor. Kit's own components (its starter
// set, author "kit") to place, set and link in Kit's editor, and Kit's
// voxels (kit/stone...) and Workbench's own (glass, brick) to build with.
// Edit rights are Kit's: the server's admin
// (the launcher's own user) and the builders the admin makes. Those who
// have them also dig and place voxels in play (a write routed to an owner
// when a component owns the voxel), and so does anyone where a component
// grants it (Kit's can_dig/can_place: a dig zone); everyone else plays
// what was built. A player's dig or place is a build (Kit's
// player_wrote), which a builder's Stop discards unless kept. The server
// starts Running (Kit's, [KIT] stage 4c): the World is generated (merged,
// not play's), and a builder's Stop puts the start back, Play starts a
// round. One save, "world": the voxels, Kit's rows, a heightmap's map.
#include "core/log.h"
#include "core/json.h"
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
#include <cereal/archives/portable_binary.hpp>
#include <array>
#include <map>
#include <cmath>
#include <sstream>
#define MODULE "main"

namespace workbench {

namespace pv = PolyVox;
namespace magic = Urho3D;
using interface::Event;

// The cells a build may be at: Kit's World region (an infinite World
// reaches that far; voxelworld refuses a write where nothing is loaded)
static const int WORLD_XZ = kit::WORLD_SECTIONS_XZ * kit::WORLD_SECTION;
static const int WORLD_Y0 = kit::WORLD_SECTION_Y0 * kit::WORLD_SECTION,
		WORLD_Y1 = (kit::WORLD_SECTION_Y1 + 1) * kit::WORLD_SECTION - 1;
// A player's position as Kit takes it: the middle of the cell their feet
// are in, their body's centre this far over it when they stand (the
// client's capsule is 1.7 tall); a put is a little over that
static const double FEET_CELL = 0.35, PUT_OVER = 0.05;
// Workbench's own voxels (its textures). Kit's material set's are Kit's
// (register_voxels), and the builders' theirs ([KIT] stage 4g); a builder
// places any of them, "air" a dig
static const char *OWN_VOXELS[] = {"glass", "brick"};

struct Module: public interface::Module
{
	interface::Server *m_server;
	main_context::SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	sm_<size_t, ss_> m_names; // peer -> the name Kit knows them by
	// peer -> how many times the server has put them: a position the
	// client sent before it heard of the last is not taken (a teleport
	// would bounce back for a packet's time otherwise)
	sm_<size_t, int32_t> m_moves;
	// peer -> where Kit has them
	sm_<size_t, std::array<double, 3>> m_pos;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	void init()
	{
		sub(m_server, "core:start", &Module::on_start);
		sub(m_server, "client_file:files_transmitted", &Module::on_files);
		sub(m_server, "network:packet_received/main:player_pos",
				&Module::on_player_pos);
		sub(m_server, "network:packet_received/main:build", &Module::on_build);
		sub(m_server, "network:client_disconnected", &Module::on_left);
		sub(m_server, "accounts:login", &Module::on_login);
		sub(m_server, "kit:move_player", &Module::on_move);
		sub(m_server, "kit:spawn_player", &Module::on_spawn);
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
		if(!m_save){
			m_server->shutdown(1, "workbench: no save");
			return;
		}
		// Kit's World's region, loaded only where Kit's load points say
		const int XZ = kit::WORLD_SECTIONS_XZ;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			ivw->create_instance(m_scene, pv::Region(-XZ, kit::WORLD_SECTION_Y0,
					-XZ, XZ - 1, kit::WORLD_SECTION_Y1, XZ - 1));
		});
		interface::VoxelRegistry *reg = nullptr;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			w->set_load_points({});
			reg = w->get_voxel_reg();
			interface::VoxelFormat f;
			f.id = interface::VoxelField{0, 0, 16};
			reg->set_format(f);
			interface::VoxelDefinition air;
			air.name.block_name = "air";
			air.fully_empty = true;
			reg->add_voxel(air);
			for(const char *v : OWN_VOXELS){
				interface::VoxelDefinition def;
				def.name.block_name = ss_("workbench/")+v;
				def.physically_solid = true;
				def.edge_material_id = interface::EDGEMATERIALID_GROUND;
				for(auto &seg : def.textures){
					seg.resource_name = ss_("main/")+v+".png";
					seg.total_segments = magic::IntVector2(1, 1);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				reg->add_voxel(def);
			}
		});
		// Kit's voxels (its material set's); the registry is the world's
		// and takes them from any thread
		kit::access(m_server, [&](kit::Interface *k){
			k->register_voxels(reg);
		});
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			w->set_save(m_save, "main");
		});
		kit::Host h;
		h.composition_path = m_server->get_module_path(MODULE)+
				"/composition.json";
		h.save = m_save;
		h.scenes["world"] = m_scene;
		h.moves_players = true;
		// The World: Workbench's floor, stone, unless the composer says
		// otherwise
		h.world_scene = "world";
		h.defaults = "{\"kit/world\": {\"biome\": \"rock\"}}";
		if(!kit::host(m_server, h))
			m_server->shutdown(1, "workbench: Kit is not hosted");
	}

	// main:spawn: the player put at x, y, z (their body's centre), and
	// the count of the puts, which their positions carry back
	void send_spawn(size_t peer, double x, double y, double z)
	{
		const int32_t n = ++m_moves[peer];
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(x, y, z, n);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:spawn", os.str());
		});
	}

	// Kit's teleport (a component's, for the player who set it off): the
	// position is the cell the feet go in
	void on_move(const kit::MovePlayer &m)
	{
		log_i(MODULE, "workbench: %s moved to (%g, %g, %g)",
				cs(m_names[m.peer]), m.x, m.y, m.z);
		send_spawn(m.peer, m.x, m.y + FEET_CELL + PUT_OVER, m.z);
		place(m.peer, m.x, m.y, m.z);
	}

	void place(size_t peer, double x, double y, double z)
	{
		m_pos[peer] = {{x, y, z}};
		kit::access(m_server, [&](kit::Interface *k){
			k->set_peer(peer, m_names[peer], "world", x, y, z);
		});
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
		m_names[peer] = name.empty() ? "p"+itos(peer) : name;
		spawn(peer);
	}

	// The middle of the World, unless a spawner puts them elsewhere
	void spawn(size_t peer)
	{
		double x = 0.5, y = 1, z = 0.5;
		kit::access(m_server, [&](kit::Interface *k){
			k->world_spawn(x, y, z);
		});
		send_spawn(peer, x, y + FEET_CELL + PUT_OVER, z);
		place(peer, x, y, z);
	}

	// A round starts and no spawner places the player: the default
	void on_spawn(const kit::SpawnPlayer &s)
	{
		if(!m_names.count(s.peer))
			return;
		log_i(MODULE, "workbench: %s to the middle of the floor",
				cs(m_names[s.peer]));
		spawn(s.peer);
	}

	// Kit's edit rights follow the account: the admin's, a builder's
	void on_login(const accounts::Login &login)
	{
		m_names[login.peer] = login.name;
		log_i(MODULE, "workbench: peer %zu is %s", (size_t)login.peer,
				cs(login.name));
		// Kit knows them by the new name at once: what they do next is
		// theirs, not the old name's
		auto it = m_pos.find(login.peer);
		if(it != m_pos.end())
			place(login.peer, it->second[0], it->second[1], it->second[2]);
	}

	void on_left(const network::OldClient &old)
	{
		log_i(MODULE, "workbench: %s left", cs(m_names[old.info.id]));
		m_names.erase(old.info.id);
		m_moves.erase(old.info.id);
		m_pos.erase(old.info.id);
	}

	void on_player_pos(const network::Packet &packet)
	{
		double x = 0, y = 0, z = 0;
		int32_t n = 0;
		std::istringstream is(packet.data, std::ios::binary);
		cereal::PortableBinaryInputArchive ar(is);
		ar(x, y, z, n);
		if(!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z) ||
				!m_names.count(packet.sender) || n != m_moves[packet.sender])
			return;
		place(packet.sender, x, y - FEET_CELL, z);
	}

	// A builder's dig or place in play: {"p": [x, y, z], "voxel": name},
	// "air" a dig. Routed: a voxel a component owns goes to the component
	void on_build(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const json::Value j = packet.data.size() < 256 ?
				json::load_string(packet.data.c_str()) : json::null();
		const json::Value &p = j.get("p");
		const ss_ voxel = json::jstr(j, "voxel");
		bool ok = p.is_array() && p.size() == 3;
		int c[3] = {0, 0, 0};
		for(unsigned k = 0; ok && k < 3; k++){
			const double lo = k == 1 ? WORLD_Y0 : -WORLD_XZ,
					hi = k == 1 ? WORLD_Y1 : WORLD_XZ - 1;
			ok = p.at(k).is_number() && p.at(k).as_number() >= lo &&
					p.at(k).as_number() <= hi;
			c[k] = ok ? (int)std::floor(p.at(k).as_number()) : 0;
		}
		bool placeable = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelName n;
			n.block_name = voxel;
			placeable = w->get_voxel_reg()->get(n) != nullptr;
		});
		if(!ok || !placeable){
			log_i(MODULE, "workbench: a build by peer %zu refused: not a "
					"cell of the world and a voxel to build with", peer);
			return;
		}
		bool can = false;
		kit::access(m_server, [&](kit::Interface *k){
			can = k->can_edit(peer) || (voxel == "air" ?
					k->can_dig(peer, c[0], c[1], c[2]) :
					k->can_place(peer, c[0], c[1], c[2]));
		});
		if(!can){
			log_i(MODULE, "workbench: a build by %s refused: no edit rights "
					"and no grant at (%i,%i,%i)", cs(m_names[peer]), c[0], c[1],
					c[2]);
			return;
		}
		bool written = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelName n;
			n.block_name = voxel;
			const auto r = w->routed_set_voxel(pv::Vector3DInt32(c[0], c[1],
					c[2]), interface::VoxelInstance(w->get_voxel_reg()->
					get(n)->id), "player:"+m_names[peer]);
			written = r == voxelworld::Instance::WRITTEN;
			log_i(MODULE, "workbench: %s %s (%i,%i,%i): %s", cs(m_names[peer]),
					voxel == "air" ? "dug" : cs("placed "+voxel), c[0], c[1],
					c[2], r == voxelworld::Instance::ROUTED ? "routed to its "
					"owner" : written ? "written" : "refused");
		});
		// The player's own: a build
		if(written)
			kit::access(m_server, [&](kit::Interface *k){
				k->player_wrote(peer, c[0], c[1], c[2]);
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
