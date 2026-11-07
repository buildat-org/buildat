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
// server stops, or until an admin switches or closes it.
//
// [WORKBENCH_SWITCH_PROJECT] An admin (world_menu's picker: the launcher's
// own client, an admin's account) has Projects... in the pause menu: Manage
// over the running project, it marked. Play on another (New's too) and
// Close are skeldat's [SKELDAT_WORLD_ADMIN] reload: every client sent off
// with the goodbye that says the server goes on (a launcher rejoins at
// once), Kit and this module reloaded, the old instance's scenes saved and
// taken down once Kit is gone (its rows saved at its core:unload), the
// new one starting the picked project or, for a close, none (Manage to
// the picker, the wait to the rest, and no project reopened at a restart).
// Drafts and sessions go as at a server stop.
//
// [KIT_TEMPLATES] New's "Start from": Empty, ours (templates/ beside this
// module's directory), then those installed. A project from one has its
// composition as its first start (Kit's Host::composition_path), Stopped, the
// first builder in the tools.
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
#include "voxel_objects/api.h"
#include "heightmap/api.h"
#include "worldgen/api.h"
#include "world_menu/api.h"
#include "interface/aitta.h"
#include "interface/fs.h"
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
	ss_ m_project; // m_save's name
	sm_<size_t, ss_> m_names; // peer -> the name Kit knows them by
	// peer -> how many times the server has put them: a position the
	// client sent before it heard of the last is not taken (a teleport
	// would bounce back for a packet's time otherwise)
	// peer -> where Kit has them
	sm_<size_t, std::array<double, 3>> m_pos;
	// Peers logging in before they see Manage, peers shown Manage, peers
	// in the project (its client run)
	std::set<size_t> m_joining, m_waiting, m_in;
	// [WORKBENCH_SWITCH_PROJECT] A switch or a close under way: this
	// instance is reloaded, and takes its scenes down as it goes
	bool m_switching = false;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	// [WORKBENCH_SWITCH_PROJECT] Kit is unloaded by now (it was asked
	// first), so nothing ticks on the scenes or writes to the save: each
	// scene's voxels saved and its instances gone (a heightmap's map saved
	// as it goes), then the saves closed; the generators went at
	// on_unload()
	~Module()
	{
		if(!m_switching)
			return;
		for(auto &s : m_scenes){
			main_context::SceneReference ref = s.second;
			heightmap::access(m_server, [&](heightmap::Interface *i){
				i->delete_instance(ref);
			});
			voxel_objects::access(m_server, [&](voxel_objects::Interface *i){
				if(i->get_instance(ref))
					i->delete_instance(ref);
			});
			voxelworld::access(m_server, [&](voxelworld::Interface *i){
				voxelworld::Instance *w = i->get_instance(ref);
				if(!w)
					return;
				w->commit();
				w->save();
				w->set_save(nullptr, "");
				i->delete_instance(ref);
			});
			main_context::access(m_server, [&](main_context::Interface *i){
				i->delete_scene(ref);
			});
		}
		storage::access(m_server, [&](storage::Interface *i){
			if(m_save)
				i->close(m_save);
			if(m_own)
				i->close(m_own);
		});
		log_i(MODULE, "workbench: the project \"%s\" closed for the switch",
				cs(m_project));
	}

	// The generators are Kit's (its code): gone while Kit is loaded, at
	// the reload's core:unload (Kit's comes first, so its rows are saved)
	void on_unload()
	{
		if(!m_switching)
			return;
		for(auto &s : m_scenes)
			worldgen::access(m_server, [&](worldgen::Interface *i){
				if(i->get_instance(s.second))
					i->delete_instance(s.second);
			});
	}

	void init()
	{
		sub(m_server, "core:start", &Module::on_start);
		sub(m_server, "core:continue", &Module::on_continue);
		sub(m_server, "core:unload", &Module::on_unload);
		sub(m_server, "world_menu:close", &Module::on_project_close);
		sub(m_server, "network:packet_received/main:projects",
				&Module::on_projects);
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
		configure_menu();
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

	// [KIT_TEMPLATES] What New starts from, New's "Start from": Empty, ours
	// (templates/ beside this module: there with no Aitta) and then what is
	// installed (<user>/installed/<fp>/<name>/<newest version>, its manifest
	// and files checked as the install did, for a directory is a directory).
	// By the choice's value, its directory
	sm_<ss_, ss_> m_templates;
	void configure_menu()
	{
		world_menu::Field f{"template", "Start from", "", "", false};
		f.choices.push_back({"empty", "Empty"});
		f.notes["empty"] = "Ground to build on and nothing else.";
		m_templates.clear();
		auto add = [&](const ss_ &value, const ss_ &dir, const ss_ &who){
			json::json_error_t e;
			const json::Value m = json::load_file((dir+"/meta.json").c_str(), &e);
			if(interface::aitta::kind_of(m) != "template")
				return;
			ss_ why = interface::aitta::check_manifest(m);
			if(why.empty())
				why = interface::aitta::template_refusal(dir);
			if(!why.empty()){
				log_w(MODULE, "workbench: the template in %s: %s", cs(dir), cs(why));
				return;
			}
			const ss_ title = m.get("title").as_string();
			f.choices.push_back({value, who == "" ? title :
					title+" ("+m.get("author").as_string()+who+")"});
			f.notes[value] = json::jstr(m, "description");
			m_templates[value] = dir;
		};
		namespace fs = interface::fs;
		const ss_ ours = m_server->get_module_path(MODULE)+"/../templates";
		for(const auto &n : fs::list_directory(ours))
			if(n.is_directory)
				add(n.name, ours+"/"+n.name, "");
		const ss_ user = m_server->get_config().get<ss_>("user_path");
		const ss_ in = user+"/installed";
		for(const auto &k : fs::list_directory(in)){
			if(!k.is_directory || !interface::aitta::fingerprint_ok(k.name))
				continue;
			for(const auto &n : fs::list_directory(in+"/"+k.name)){
				ss_ best;
				for(const auto &v : fs::list_directory(in+"/"+k.name+"/"+n.name))
					if(v.is_directory && (best.empty() ||
							interface::aitta::version_less(best, v.name)))
						best = v.name;
				if(!best.empty())
					add(k.name+"/"+n.name, in+"/"+k.name+"/"+n.name+"/"+best,
							interface::aitta::installed_vouch(user, k.name).empty() ?
							", installed, unverified" : ", installed");
			}
		}
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->configure({"Workbench", {f}, "project"});
		});
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
		auto t = event.options.find("template");
		const ss_ from = t == event.options.end() ? "" : t->second;
		if(m_save){
			// [WORKBENCH_SWITCH_PROJECT] Picked over a running project
			if(m_switching || !picker(event.peer) || event.name == m_project){
				log_w(MODULE, "workbench: a switch to \"%s\" by %s refused",
						cs(event.name), cs(m_names[event.peer]));
				return;
			}
			reload_for(m_names[event.peer]+" switches the project to "+
					event.name, "play\n"+event.name+"\n"+
					(event.created ? "1" : "0")+"\n"+from,
					"The server switches to the project "+event.name);
			return;
		}
		if(!start_project(event.name, false, event.created, from))
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show(event.peer);
			});
	}

	// [WORKBENCH_SWITCH_PROJECT] world_menu's picker
	bool picker(size_t peer)
	{
		bool ok = false;
		world_menu::access(m_server, [&](world_menu::Interface *i){
			ok = i->is_picker(peer);
		});
		return ok;
	}

	// Projects...: Manage over the running project, to the picker only
	void on_projects(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		if(!m_save || m_switching || !m_in.count(peer) || !picker(peer)){
			log_w(MODULE, "workbench: %s's Projects... refused: not an "
					"admin", cs(m_names[peer]));
			return;
		}
		configure_menu();
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->show_running(peer, m_project);
		});
	}

	// Tells a peer in the project whether they have Projects...
	void send_picker(size_t peer)
	{
		if(m_server->has_module("world_menu"))
			network::send(m_server, peer, "main:picker", picker(peer) ? "1" :
					"");
	}

	void on_project_close(const world_menu::Close &event)
	{
		if(!m_save || m_switching || !picker(event.peer)){
			log_w(MODULE, "workbench: a close by %s refused",
					cs(m_names[event.peer]));
			return;
		}
		reload_for(m_names[event.peer]+" closes the project "+m_project,
				"close", "The project "+m_project+" was closed");
	}

	// skeldat's reload_for: Kit's rows saved at its core:unload, this
	// instance's scenes at its destruction (~Module), the next instance
	// told what to start (on_continue)
	void reload_for(const ss_ &line, const ss_ &data, const ss_ &goodbye)
	{
		m_switching = true;
		log_i(MODULE, "workbench: %s", cs(line));
		m_server->tmp_store_data("workbench:switch", data);
		network::access(m_server, [&](network::Interface *i){
			for(network::PeerInfo::Id p : i->list_peers()){
				i->send(p, "network:goodbye", "1"+goodbye);
				i->disconnect(p);
			}
		});
		m_server->reload_module("kit");
		m_server->reload_module(MODULE);
	}

	// The new instance: the switch's project, or none after a close.
	// simplified: a reload of this module alone (a source edit's, -R) has
	// no data and starts nothing: Kit still has the old instance's
	// scenes; a restart is the way
	void on_continue()
	{
		const ss_ sw = m_server->tmp_restore_data("workbench:switch");
		if(sw.empty()){
			log_w(MODULE, "workbench: reloaded alone: restart the server");
			return;
		}
		// [REJOIN_FAST_CLICK] skeldat's: a client back before the reload
		// tells again when its files are in, to this instance
		network::access(m_server, [&](network::Interface *i){
			for(network::PeerInfo::Id p : i->list_peers())
				i->send(p, "core:tell_after_all_files_transferred", "");
		});
		std::istringstream ss(sw);
		ss_ how, name, created, from;
		std::getline(ss, how);
		std::getline(ss, name);
		std::getline(ss, created);
		std::getline(ss, from);
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});
		configure_menu();
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->set_running(false);
		});
		if(how == "play" && start_project(name, false, created == "1", from)){
			log_i(MODULE, "workbench: switched to \"%s\"", cs(name));
			return;
		}
		log_i(MODULE, "workbench: no project runs: Manage");
		if(server_store())
			server_store()->remove("running");
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
					-XZ, XZ - 1, kit::WORLD_SECTION_Y1, XZ - 1), false, true);
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
		// [KIT_CTF] Into another session ("<scene>~<id>"): Kit puts the
		// body as they join there, unless the join put them already (a
		// team's teleport), which a put here would undo
		auto session = [](const ss_ &s){
			const size_t t = s.find('~');
			return t == ss_::npos ? ss_() : s.substr(t + 1);
		};
		const bool joins = !m_peer_scene.count(c.peer) ||
				session(m_peer_scene[c.peer]) != session(c.scene);
		m_peer_scene[c.peer] = c.scene;
		replicate::assign_scene_to_peer(m_server, it->second, c.peer);
		log_i(MODULE, "workbench: %s to scene %s", cs(m_names[c.peer]),
				cs(c.scene));
		place(c.peer, c.x, c.y, c.z);
		if(!joins)
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
	// [KIT_TEMPLATES] `from`: a template of m_templates, the composition of a
	// fresh project, which opens in edit mode with what it says (the World its
	// own). simplified: one that Kit refuses all the same (a type of a newer
	// Kit) shuts the server down as any composition's refusal does, saying why;
	// the project then opens empty
	bool start_project(const ss_ &name, bool create, bool fresh = false,
			const ss_ &from = "")
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
		m_project = name;
		// [WB_LAN_NAME] Announced to the LAN as the project, as vanilla's
		// world; a joiner there logs in
		if(m_server->has_module("accounts"))
			accounts::access(m_server, [&](accounts::Interface *i){
				i->set_lan_name(name, true);
			});
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
		const auto tmpl = fresh ? m_templates.find(from) : m_templates.end();
		if(tmpl != m_templates.end()){
			h.composition_path = tmpl->second+"/composition.json";
			h.opens_in_edit = true;
			log_i(MODULE, "workbench: the project from the template %s", cs(from));
		}
		h.save = m_save;
		h.scenes["world"] = m_scene;
		h.make_scene = [this](const ss_ &name, kit::Interface *k){
			return make_scene(name, k);
		};
		h.drop_scene = [this](const ss_ &name){
			drop_scene(name);
		};
		h.controls = true;
		// [KIT_CTF] A check's own component types (a directory), as the
		// app's; never set but by a check
		const char *types = getenv("BUILDAT_WORKBENCH_TYPES");
		if(types && types[0])
			h.types_path = types;
		// [KIT_MATERIAL_SETS] a World may be made of a set package
		h.material_sets = true;
		// The World: Workbench's floor, unless the composer says otherwise:
		// a new project's a gentle grassland heightmap, 64x64 (its least
		// side), the player at its middle (world_spawn); before, stone
		const char *stone = getenv("BUILDAT_WORKBENCH_STONE");
		ss_ ground;
		if(fresh && tmpl == m_templates.end() && !(stone && stone[0] == '1'))
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
		// [WORKBENCH_SWITCH_PROJECT] A rejoin before the reload: the next
		// instance's (on_continue())
		if(m_switching)
			return;
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
		configure_menu();
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
			// [WB_EDITOR_VIEW_MEMORY] the editor's memory on the client
			// is keyed by the project
			network::send(m_server, peer, "main:project", m_project);
			send_picker(peer);
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
		if(m_switching)
			return;
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
		if(m_in.count(login.peer))
			send_picker(login.peer);
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
			can = k->is_editing(peer) || (k->allows(peer, voxel == "air" ?
					"dig" : "place", c[0], c[1], c[2], &why) &&
					// [KIT_INVENTORY_PLAY] one of the held slot's
					(voxel == "air" || k->place_ready(peer, voxel, &why)));
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
		// [KIT_TOOLS_1] A dig takes its time by the voxel's material group
		// and the held item; the client asks again when Kit says
		ss_ was;
		if(voxel == "air"){
			voxelworld::access(m_server, scene_of(peer),
					[&](voxelworld::Instance *w){
				interface::VoxelRegistry *reg = w->get_voxel_reg();
				const interface::VoxelDefinition *def = reg->get(
						reg->get_format().id.get(w->get_voxel(
						pv::Vector3DInt32(c[0], c[1], c[2]), true).data));
				was = def ? def->name.block_name : "";
			});
			bool ready = true;
			kit::access(m_server, [&](kit::Interface *k){
				double wait = 0;
				ready = k->dig_ready(peer, c[0], c[1], c[2], was, &wait);
			});
			if(!ready)
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
				if(voxel == "air")
					k->dug(peer, c[0], c[1], c[2], was);
				else
					k->placed(peer, c[0], c[1], c[2], voxel);
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
