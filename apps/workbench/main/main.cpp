// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] Workbench: the blank app that only hosts Kit and its editor. The
// world is Kit's World ([KIT] stage 4e, kit/world on the app root): by
// default a gentle grassland heightmap 64x64 for a project New made
// ([WB_NEW_PROJECT_GROUND]), a flat stone floor 64x64 round the origin,
// its top at y 0, for others (Kit's material set, biome "rock"), the
// players walking on it (Kit's
// controls, [KIT] stage 4h: kit/controls and kit/walker on the app root
// set them); its generator, size and surface
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
// round.
//
// [WORKBENCH_PROJECTS] A save is a project: the voxels, Kit's rows, a
// heightmap's map. Until one runs, a joining client gets builtin/world_menu
// (Manage, the projects: New, Rename, Delete, Open) and the launcher's own
// client or an admin picks one; the rest wait for it, a join logging in
// first (an admin's way to the list). The launch picks it: save= opens it,
// menu=projects shows Manage (project= selected), menu=new its New. With
// none of them (a server no launcher started) the project that ran last
// opens again. BUILDAT_WORKBENCH_PROJECT=<name> opens it, made if it is not
// there (the checks; a server nobody sits at). A project runs until the
// server stops.
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
#include "world_menu/api.h"
#include "interface/server_config.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include <array>
#include <map>
#include <set>
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
// Workbench's own voxels (its textures), Kit's materials as its material
// set's are (kit/world.h; [KIT_TINT_MATERIALS] their palettes, entry 0
// the texture's own look: the brick's mortar keeps its colour, masked by
// its alpha, and the glass is blended). Kit's material set's are Kit's
// (register_voxels), and the builders' theirs ([KIT] stage 4g); a builder
// places any of them, "air" a dig
static const char *OWN_VOXELS[] = {"glass", "brick"};
static const char *OWN_MATERIALS = R"({
	"workbench/glass": {"texture": "main/glass.png", "kind": "glass", "tint": [
		{"color": "#c4e4ee", "name": "clear"},
		{"color": "#f9801d", "name": "orange"},
		{"color": "#c74ebd", "name": "magenta"},
		{"color": "#3ab3da", "name": "light blue"},
		{"color": "#fed83d", "name": "yellow"},
		{"color": "#80c71f", "name": "lime"},
		{"color": "#f38baa", "name": "pink"},
		{"color": "#474f52", "name": "grey"},
		{"color": "#9d9d97", "name": "light grey"},
		{"color": "#169c9c", "name": "cyan"},
		{"color": "#8932b8", "name": "purple"},
		{"color": "#3c44aa", "name": "blue"},
		{"color": "#835432", "name": "brown"},
		{"color": "#5e7c16", "name": "green"},
		{"color": "#b02e26", "name": "red"},
		{"color": "#1d1d21", "name": "black"}]},
	"workbench/brick": {"texture": "main/brick.png", "tint": [
		{"color": "#a03c2d", "name": "clay red"},
		{"color": "#9f7f4c", "name": "yellow"},
		{"color": "#472e28", "name": "dark"},
		{"color": "#b2aea8", "name": "white-washed"},
		{"color": "#613f33", "name": "brown"},
		{"color": "#985933", "name": "orange"}]}
})";

struct Module: public interface::Module
{
	interface::Server *m_server;
	main_context::SceneReference m_scene = nullptr;
	// [KIT_SCENES] The composition's scenes by name ("world" m_scene; the
	// rest made as Kit asks), and the one each peer is in
	sm_<ss_, main_context::SceneReference> m_scenes;
	sm_<size_t, ss_> m_peer_scene;
	storage::Save *m_save = nullptr;
	sm_<size_t, ss_> m_names; // peer -> the name Kit knows them by
	// peer -> how many times the server has put them: a position the
	// client sent before it heard of the last is not taken (a teleport
	// would bounce back for a packet's time otherwise)
	// peer -> where Kit has them
	sm_<size_t, std::array<double, 3>> m_pos;
	// Peers logging in before they see Manage, peers shown Manage, peers
	// in the project (its client run)
	std::set<size_t> m_joining, m_waiting, m_in;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	void init()
	{
		sub(m_server, "core:start", &Module::on_start);
		sub(m_server, "client_file:files_transmitted", &Module::on_files);
		sub(m_server, "network:packet_received/main:build", &Module::on_build);
		sub(m_server, "network:client_disconnected", &Module::on_left);
		sub(m_server, "accounts:login", &Module::on_login);
		sub(m_server, "kit:spawn_player", &Module::on_spawn);
		sub(m_server, "kit:change_scene", &Module::on_change_scene);
		sub(m_server, "world_menu:play", &Module::on_project_play);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});
		// None in the web client's own server (accounts is native): the
		// one project, "world"
		if(!m_server->has_module("world_menu")){
			start_project("world", true);
			return;
		}
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->configure({"Workbench", {}, "project"});
		});
		const char *env = getenv("BUILDAT_WORKBENCH_PROJECT");
		if(env && env[0]){
			if(!start_project(env, true))
				m_server->shutdown(1, "workbench: no project");
			return;
		}
		const ss_ u = m_server->get_config().get<ss_>("untrusted_launch");
		bool refused = false;
		const ss_ save = interface::launch_param(u, "save", &refused);
		if(refused)
			log_w(MODULE, "workbench: the launch's save refused");
		if(!save.empty() && start_project(save, false))
			return;
		const ss_ menu = interface::launch_param(u, "menu");
		const ss_ want = interface::launch_param(u, "project");
		world_menu::access(m_server, [&](world_menu::Interface *i){
			if(menu == "new")
				i->open_new();
			else if(!want.empty())
				i->select(want);
		});
		// No launcher: the project that ran last
		ss_ last;
		if(u.empty() && server_store() &&
				server_store()->get("running", last) && !last.empty() &&
				!start_project(last, false))
			log_w(MODULE, "workbench: the project %s that ran last is gone",
					cs(last));
	}

	// The save "_workbench" (the server's own, no project): store "server",
	// "running" the project that ran last
	storage::Save *m_own = nullptr;
	storage::Store* server_store()
	{
		if(!m_own)
			storage::access(m_server, [&](storage::Interface *i){
				m_own = i->open("_workbench");
				if(!m_own)
					m_own = i->create("_workbench");
			});
		return m_own ? m_own->store("server") : nullptr;
	}

	// A project picked or made in Manage; one that does not start is
	// Manage again
	void on_project_play(const world_menu::Play &event)
	{
		if(!start_project(event.name, false, event.created))
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show(event.peer);
			});
	}

	// A scene's voxels: Kit's World's region, loaded only where Kit's load
	// points say, Kit's format, Workbench's voxels and Kit's -- the same in
	// every scene, in the same order ([KIT_SCENES]: one registry file
	// serves them all) -- and its save
	void setup_scene(main_context::SceneReference scene, const ss_ &save_name,
			kit::Interface *kit_in = nullptr)
	{
		const int XZ = kit::WORLD_SECTIONS_XZ;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			ivw->create_instance(scene, pv::Region(-XZ, kit::WORLD_SECTION_Y0,
					-XZ, XZ - 1, kit::WORLD_SECTION_Y1, XZ - 1));
		});
		interface::VoxelRegistry *reg = nullptr;
		voxelworld::access(m_server, scene, [&](voxelworld::Instance *w){
			w->set_load_points({});
			reg = w->get_voxel_reg();
			// [KIT_VOXEL_FORMAT] Kit's: id, param, tint, sky light
			reg->set_format(kit::voxel_format());
			interface::VoxelDefinition air;
			air.name.block_name = "air";
			air.fully_empty = true;
			reg->add_voxel(air);
		});
		// Workbench's own voxels, then Kit's (its material set's); the
		// registry is the world's and takes them from any thread
		auto reg_voxels = [&](kit::Interface *k){
			const json::Value own = json::load_string(OWN_MATERIALS);
			for(const char *v : OWN_VOXELS){
				const ss_ name = ss_("workbench/")+v;
				ss_ why;
				if(!k->register_material(reg, name, own.get(name.c_str()), &why))
					log_e(MODULE, "%s", cs(why));
			}
			k->register_voxels(reg);
		};
		if(kit_in)
			reg_voxels(kit_in);
		else
			kit::access(m_server, reg_voxels);
		voxelworld::access(m_server, scene, [&](voxelworld::Instance *w){
			w->set_save(m_save, save_name);
		});
	}

	// [KIT_SCENES] Kit's make_scene: a scene of the composition's, its
	// voxels saved as "scene_<name>"
	main_context::SceneReference make_scene(const ss_ &name,
			kit::Interface *k)
	{
		auto it = m_scenes.find(name);
		if(it != m_scenes.end())
			return it->second;
		// [KIT_SESSIONS_1] a session's: "<scene>~<id>"
		const size_t t = name.find('~');
		for(size_t i = 0; i < name.size(); i++)
			if(!isalnum((unsigned char)name[i]) && name[i] != '_' &&
					!(i == t && i > 0 && i + 1 < name.size() &&
					name.find_first_not_of("0123456789", t + 1) == ss_::npos))
				return nullptr;
		main_context::SceneReference ref = nullptr;
		main_context::access(m_server, [&](main_context::Interface *imc){
			ref = imc->create_scene();
		});
		setup_scene(ref, "scene_"+name, k);
		m_scenes[name] = ref;
		log_i(MODULE, "workbench: scene %s made", cs(name));
		return ref;
	}

	// [KIT_SESSIONS_1] Kit's drop_scene: a session's scene gone, its
	// voxels' rows with it (a scene from before a restart: the rows only)
	void drop_scene(const ss_ &name)
	{
		if(name.find('~') == ss_::npos)
			return;
		auto it = m_scenes.find(name);
		if(it != m_scenes.end()){
			main_context::SceneReference ref = it->second;
			for(auto &ps : m_peer_scene)
				if(ps.second == name){
					ps.second = "world";
					replicate::assign_scene_to_peer(m_server, m_scene, ps.first);
				}
			voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
				voxelworld::Instance *w = ivw->get_instance(ref);
				if(w)
					w->set_save(nullptr, "");
				ivw->delete_instance(ref);
			});
			main_context::access(m_server, [&](main_context::Interface *imc){
				imc->delete_scene(ref);
			});
			m_scenes.erase(it);
		}
		storage::Store *st = m_save ? m_save->store("voxelworld") : nullptr;
		if(st)
			st->batch([&](){
				for(const ss_ &k : st->list("scene_"+name+"/"))
					st->remove(k);
			});
		log_i(MODULE, "workbench: scene %s dropped", cs(name));
	}

	// [KIT_SCENES] Kit sends a player to another scene: replicate's scene
	// theirs, Kit told, the body put
	void on_change_scene(const kit::ChangeScene &c)
	{
		auto it = m_scenes.find(c.scene);
		if(it == m_scenes.end() || !m_names.count(c.peer))
			return;
		m_peer_scene[c.peer] = c.scene;
		replicate::assign_scene_to_peer(m_server, it->second, c.peer);
		log_i(MODULE, "workbench: %s to scene %s", cs(m_names[c.peer]),
				cs(c.scene));
		place(c.peer, c.x, c.y, c.z);
		kit::access(m_server, [&](kit::Interface *k){
			k->put_player(c.peer, c.x, c.y, c.z, c.yaw);
		});
	}

	// The scene a peer is in
	main_context::SceneReference scene_of(size_t peer)
	{
		auto it = m_peer_scene.find(peer);
		auto s = it == m_peer_scene.end() ? m_scenes.end() :
				m_scenes.find(it->second);
		return s == m_scenes.end() ? m_scene : s->second;
	}

	// The save `name` opened (made, when `create`) and Kit hosted in it.
	// [WB_NEW_PROJECT_GROUND] A project New made (`fresh`) starts on a
	// heightmap, the save's store "workbench" "ground" saying so from then
	// on; others (from before, BUILDAT_WORKBENCH_PROJECT's) on the stone
	// floor. BUILDAT_WORKBENCH_STONE=1: New's on stone too (the checks
	// built on it)
	bool start_project(const ss_ &name, bool create, bool fresh = false)
	{
		if(m_save)
			return false;
		storage::access(m_server, [&](storage::Interface *i){
			if(!i->valid_name(name) || name[0] == '_')
				return;
			m_save = i->open(name);
			if(!m_save && create)
				m_save = i->create(name);
		});
		if(!m_save){
			log_w(MODULE, "workbench: no project \"%s\"", cs(name));
			return false;
		}
		log_i(MODULE, "workbench: the project \"%s\" opens", cs(name));
		if(m_server->has_module("world_menu")){
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->set_running(true);
			});
			if(server_store())
				server_store()->set("running", name);
		}
		setup_scene(m_scene, "main");
		m_scenes["world"] = m_scene;
		kit::Host h;
		h.composition_path = m_server->get_module_path(MODULE)+
				"/composition.json";
		h.save = m_save;
		h.scenes["world"] = m_scene;
		h.make_scene = [this](const ss_ &name, kit::Interface *k){
			return make_scene(name, k);
		};
		h.drop_scene = [this](const ss_ &name){
			drop_scene(name);
		};
		h.controls = true;
		// [KIT_MATERIAL_SETS] a World may be made of a set package
		h.material_sets = true;
		// The World: Workbench's floor, unless the composer says otherwise:
		// a new project's a gentle grassland heightmap, 64x64 (its least
		// side), the player at its middle (world_spawn); before, stone
		const char *stone = getenv("BUILDAT_WORKBENCH_STONE");
		ss_ ground;
		if(fresh && !(stone && stone[0] == '1'))
			m_save->store("workbench")->set("ground", "heightmap");
		m_save->store("workbench")->get("ground", ground);
		h.world_scene = "world";
		h.defaults = ground == "heightmap" ?
				"{\"kit/world\": {\"surface\": \"heightmap\", \"biome\": "
				"\"grassland\", \"generator\": \"noise\", \"level\": 4, "
				"\"height\": 3, \"width\": 64, \"depth\": 64, "
				"\"decorations\": false}}" :
				"{\"kit/world\": {\"biome\": \"rock\"}}";
		if(!kit::host(m_server, h)){
			m_server->shutdown(1, "workbench: Kit is not hosted");
			return true;
		}
		for(size_t peer : m_waiting)
			enter(peer);
		m_waiting.clear();
		return true;
	}

	void place(size_t peer, double x, double y, double z)
	{
		m_pos[peer] = {{x, y, z}};
		kit::access(m_server, [&](kit::Interface *k){
			k->set_peer(peer, m_names[peer], m_peer_scene.count(peer) ?
					m_peer_scene[peer] : ss_("world"), x, y, z);
		});
	}

	// After a login ([WB_LAN]: everyone's, the launcher's own user's by
	// join.lua without the dialog), the project if it runs; else Manage,
	// where an admin picks
	void on_files(const client_file::FilesTransmitted &event)
	{
		const size_t peer = event.recipient;
		// None in the web client's own server (builtin/accounts is native)
		bool joined = !m_server->has_module("accounts");
		if(!joined)
			accounts::access(m_server, [&](accounts::Interface *a){
				joined = !a->name_of(peer).empty();
			});
		if(!joined){
			if(m_joining.insert(peer).second)
				network::send(m_server, peer, "core:run_script",
						"buildat.run_script_file(\"main/join.lua\")");
			return;
		}
		if(m_save)
			enter(peer);
		else
			manage(peer);
	}

	void manage(size_t peer)
	{
		if(m_waiting.insert(peer).second)
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show(peer);
			});
	}

	// Into the running project: its client once, the scene, the spawn
	void enter(size_t peer)
	{
		ss_ name;
		// None in the web client's own server (builtin/accounts is native)
		if(m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *a){
				name = a->name_of(peer);
			});
		if(m_in.insert(peer).second){
			network::send(m_server, peer, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
			// Logged in (join.lua's): the menu's accounts instance takes
			// the account's packets from here on; "" without accounts
			network::send(m_server, peer, "main:account", name.empty() ?
					"" : "1");
		}
		replicate::assign_scene_to_peer(m_server, m_scene, peer);
		m_peer_scene[peer] = "world";
		m_names[peer] = name.empty() ? "p"+itos(peer) : name;
		spawn(peer);
	}

	// The middle of the World, unless a spawner puts them elsewhere
	void spawn(size_t peer)
	{
		// [KIT_SCENES] the main scene's
		if(m_peer_scene.count(peer) && m_peer_scene[peer] != "world"){
			m_peer_scene[peer] = "world";
			replicate::assign_scene_to_peer(m_server, m_scene, peer);
		}
		double x = 0.5, y = 1, z = 0.5;
		kit::access(m_server, [&](kit::Interface *k){
			k->world_spawn(x, y, z);
		});
		// A peer's first placing: Kit puts their body there, or a spawner
		// elsewhere, which put_player() would undo
		const bool placed = m_pos.count(peer) != 0;
		place(peer, x, y, z);
		if(placed)
			kit::access(m_server, [&](kit::Interface *k){
				k->put_player(peer, x, y, z);
			});
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
		if(m_joining.erase(login.peer)){
			if(m_save)
				enter(login.peer);
			else
				manage(login.peer);
			return;
		}
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
		m_pos.erase(old.info.id);
		m_joining.erase(old.info.id);
		m_waiting.erase(old.info.id);
		m_in.erase(old.info.id);
		m_peer_scene.erase(old.info.id);
	}

	// A builder's dig or place in play: {"p": [x, y, z], "voxel": name,
	// "param": a shape's facing, "tint": 0..15}, "air" a dig. Routed: a voxel a component owns goes to the component
	void on_build(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		const json::Value j = packet.data.size() < 256 ?
				json::load_string(packet.data.c_str()) : json::null();
		const json::Value &p = j.get("p");
		const ss_ voxel = json::jstr(j, "voxel");
		// [KIT_VOXEL_FORMAT] a shape's facing (0..7) and a tint (0..15)
		const int64_t param = json::jint(j, "param", 0),
				tint = json::jint(j, "tint", 0);
		bool ok = p.is_array() && p.size() == 3 && param >= 0 &&
				param < 256 && tint >= 0 && tint < 16;
		int c[3] = {0, 0, 0};
		for(unsigned k = 0; ok && k < 3; k++){
			const double lo = k == 1 ? WORLD_Y0 : -WORLD_XZ,
					hi = k == 1 ? WORLD_Y1 : WORLD_XZ - 1;
			ok = p.at(k).is_number() && p.at(k).as_number() >= lo &&
					p.at(k).as_number() <= hi;
			c[k] = ok ? (int)std::floor(p.at(k).as_number()) : 0;
		}
		bool placeable = false;
		voxelworld::access(m_server, scene_of(peer), [&](voxelworld::Instance *w){
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
		ss_ why;
		kit::access(m_server, [&](kit::Interface *k){
			can = k->is_editing(peer) || k->allows(peer, voxel == "air" ? "dig" :
					"place", c[0], c[1], c[2], &why);
		});
		if(!can){
			log_i(MODULE, "workbench: a build by %s refused: not in edit mode "
					"and not allowed at (%i,%i,%i): %s", cs(m_names[peer]), c[0],
					c[1], c[2], cs(why));
			// [KIT] stage 4j: told why (a region's rule, its hook's reason)
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "kit:warning", why);
			});
			return;
		}
		bool written = false;
		voxelworld::access(m_server, scene_of(peer), [&](voxelworld::Instance *w){
			interface::VoxelName n;
			n.block_name = voxel;
			const auto r = w->routed_set_voxel(pv::Vector3DInt32(c[0], c[1],
					c[2]), interface::VoxelInstance(kit::voxel_word(
					w->get_voxel_reg()->get_format(), w->get_voxel_reg()->
					get(n)->id, (uint32_t)param, (uint32_t)tint)),
					"player:"+m_names[peer]);
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
