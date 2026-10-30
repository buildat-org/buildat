// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] Workbench: the blank app that only hosts Kit and its editor. A
// flat stone floor (FLOOR_HALF each way from the origin, y 0) in a world of
// 2x2 sections, the players walking on it (their client's physics, as
// demo_digger's), Kit's own components (its starter set, author "kit",
// their voxels filled by DEFAULTS) to place, set and link in Kit's editor,
// and the voxels to build with. Edit rights are Kit's: the server's admin
// (the launcher's own user) and the builders the admin makes. Those who
// have them also dig and place voxels in play (a write routed to an owner
// when a component owns the voxel), and so does anyone where a component
// grants it (Kit's can_dig/can_place: a dig zone); everyone else plays
// what was built. The server starts Stopped (Kit's, [KIT] stage 4c): the
// floor is laid in the start, and a builder's Play starts a round, Stop
// puts the start back. One save, "world": the voxels, Kit's rows.
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
#include <cmath>
#include <sstream>
#define MODULE "main"

namespace workbench {

namespace pv = PolyVox;
namespace magic = Urho3D;
using interface::Event;

// The floor's cells run -FLOOR_HALF...FLOOR_HALF-1 in x and z; the world
// is the four sections round the origin (64 voxels each way)
static const int FLOOR_HALF = 32;
static const int WORLD_MIN = -64, WORLD_MAX = 63;
// A player's position as Kit takes it: the middle of the cell their feet
// are in, their body's centre this far over it when they stand (the
// client's capsule is 1.7 tall); a put is a little over that
static const double FEET_CELL = 0.35, PUT_OVER = 0.05;
// The voxels: what a builder places (the first PLACEABLE) and what the
// starter set's components show their state with
struct VoxelDef { const char *name; bool solid; };
static const VoxelDef VOXELS[] = {
	{"air", false}, {"stone", true}, {"glass", true}, {"wood", true},
	{"brick", true}, {"grass", true},
	{"button", true}, {"button_pressed", true}, {"lever_off", true},
	{"lever_on", true}, {"door", true}, {"gate", true},
};
static const size_t PLACEABLE = 6; // air is not placed, it is a dig
// Kit's types' voxels, Workbench's
static const char DEFAULTS[] = R"({
	"kit/button": {"up": "button", "down": "button_pressed"},
	"kit/door": {"closed": "door"},
	"kit/key_door": {"closed": "door"},
	"kit/gate": {"closed": "gate"},
	"kit/lever": {"off_voxel": "lever_off", "on_voxel": "lever_on"}
})";

struct Module: public interface::Module
{
	interface::Server *m_server;
	main_context::SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	bool m_floor = false;
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
		sub(m_server, "core:tick", &Module::on_tick);
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
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			ivw->create_instance(m_scene, pv::Region(-1, 0, -1, 0, 0, 0));
			voxelworld::Instance *world = ivw->get_instance(m_scene);
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			interface::VoxelFormat f;
			f.id = interface::VoxelField{0, 0, 16};
			reg->set_format(f);
			for(const VoxelDef &v : VOXELS){
				interface::VoxelDefinition def;
				def.name.block_name = v.name;
				def.fully_empty = !v.solid;
				def.physically_solid = v.solid;
				if(v.solid){
					def.edge_material_id = interface::EDGEMATERIALID_GROUND;
					for(auto &seg : def.textures){
						seg.resource_name = ss_("main/")+v.name+".png";
						seg.total_segments = magic::IntVector2(1, 1);
						seg.select_segment = magic::IntVector2(0, 0);
					}
				}
				reg->add_voxel(def);
			}
			world->set_save(m_save, "main");
		});
		ss_ v;
		m_floor = m_save->store("main")->get("floor", v);
		kit::Host h;
		h.defaults = DEFAULTS;
		h.composition_path = m_server->get_module_path(MODULE)+
				"/composition.json";
		h.save = m_save;
		h.scenes["world"] = m_scene;
		h.moves_players = true;
		if(!kit::host(m_server, h))
			m_server->shutdown(1, "workbench: Kit is not hosted");
	}

	// The floor, once in the save's life: what was dug out of it stays dug
	void on_tick(const interface::TickEvent &)
	{
		if(m_floor)
			return;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(int x = -1; x <= 0; x++)
				for(int z = -1; z <= 0; z++)
					if(!w->is_section_loaded(pv::Vector3DInt16(x, 0, z)))
						return;
			interface::VoxelName stone;
			stone.block_name = "stone";
			const interface::VoxelInstance s(w->get_voxel_reg()->get(stone)->id);
			for(int x = -FLOOR_HALF; x < FLOOR_HALF; x++)
				for(int z = -FLOOR_HALF; z < FLOOR_HALF; z++)
					w->set_voxel(pv::Vector3DInt32(x, 0, z), s);
			m_floor = true;
		});
		if(m_floor){
			m_save->store("main")->set("floor", "1");
			log_i(MODULE, "workbench: the floor laid, %ix%i",
					FLOOR_HALF * 2, FLOOR_HALF * 2);
		}
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

	// The middle of the floor, unless a spawner puts them elsewhere
	void spawn(size_t peer)
	{
		send_spawn(peer, 0.5, 1 + FEET_CELL + PUT_OVER, 0.5);
		place(peer, 0.5, 1, 0.5);
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
			ok = p.at(k).is_number() && p.at(k).as_number() >= WORLD_MIN &&
					p.at(k).as_number() <= WORLD_MAX;
			c[k] = ok ? (int)std::floor(p.at(k).as_number()) : 0;
		}
		ok = ok && c[1] >= 0;
		bool placeable = false;
		for(size_t i = 0; i < PLACEABLE; i++)
			placeable = placeable || voxel == VOXELS[i].name;
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
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelName n;
			n.block_name = voxel;
			const auto r = w->routed_set_voxel(pv::Vector3DInt32(c[0], c[1],
					c[2]), interface::VoxelInstance(w->get_voxel_reg()->
					get(n)->id), "player:"+m_names[peer]);
			log_i(MODULE, "workbench: %s %s (%i,%i,%i): %s", cs(m_names[peer]),
					voxel == "air" ? "dug" : cs("placed "+voxel), c[0], c[1],
					c[2], r == voxelworld::Instance::ROUTED ? "routed to its "
					"owner" : r == voxelworld::Instance::WRITTEN ? "written" :
					"refused");
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
