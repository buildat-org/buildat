// Buildat: apps/skeldat/main/main.cpp
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// skeldat ([SKELDAT]): skelenti made fresh in Buildat, no Luanti game under
// it. The rules are game.h's; this is the world they run in -- its own
// generator (terrain.h, mapgen.h: [SKELDAT_OWN_MAPGEN]) with skelenti's
// ground, ores and trees, voxelworld keeping the light and the saves -- and
// the players: where
// they are, what they carry, what they dig, place, craft and cook.
//
// The world: until one runs, a joining client gets builtin/world_menu and
// the launcher's own client picks a save to play or makes a new one, its
// seed asked for. The first save picked is the world for as long as the
// server runs, or until the picker switches or closes it from the pause
// menu ([SKELDAT_WORLD_ADMIN]). BUILDAT_SKELDAT_WORLD=<name> skips the menu
// (the checks; a server nobody sits at).
//
// The voxel word is Luanti's cut (VoxelFormat::luanti(): the id, the sky
// and the lamp light, param2), which is what the generator writes, and a
// second plane of 8 bits, "bones", whose low 4 are the bones field
// (bones.h): seeded by the generator in the danger zones, grown a section at
// a time, and drawn as skelenti's danger (the format's first modifier). The mobs, skelenti's,
// read the danger off it: where a skeleton spawns and whether the sun
// burns it.
//
// What the client says is trusted for now, apart from the reach and the
// time a dig takes: its position is taken as it comes until the movement
// check is in (stage 6).
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/os.h"
#include "interface/server_config.h"
#include "luanti/node_registry.h"
#include "luanti/media.h"
#include "luanti/session.h"
#include "accounts/api.h"
#include "chat/api.h"
#include "client_file/api.h"
#include "main_context/api.h"
#include "moderation/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "world_menu/api.h"
#include "game.h"
#include "bones.h"
#include "move_check.h"
#include "hazards.h"
#include "mapgen.h"
#include <Scene.h>
#include <Image.h>
#include <Node.h>
#include "core/json.h"
#include <cmath>
#include <ctime>
#include <algorithm>
#include <array>
#include <deque>
#include <atomic>
#include <functional>
#include <map>
#include <random>
#include <set>
#include <sstream>
#define MODULE "main"

namespace skeldat {

using interface::Event;
using interface::VoxelInstance;
using skeldat::Stack;
namespace pv = PolyVox;
using Urho3D::M_PI;
namespace vp = interface::voxel_path;
using Urho3D::M_RADTODEG;

#include "records.h"

#include "world_view.h"
#include "furnaces.h"
#include "drops.h"
#include "terrain.h"
#include "bones_growth.h"
#include "making_map.h"
#include "scores.h"
#include "mobs.h"
#include "players.h"
#include "admin.h"

struct Module: public interface::Module, public PlayersHost,
		public AdminHost
{
	interface::Server *m_server;
	const skeldat::Game m_game = skeldat::make_game();
	// The world as the parts see it (world_view.h)
	WorldView m_world{m_server, m_game};
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	bool m_starting = false;
	// The world started was new: "Making", else "Loading"
	bool m_making = false;
	int64_t m_start_us = interface::os::time_us();
	// worldgen's; read for its highest voxel only
	BonesGenerator *m_generator = nullptr;
	// [SKELDAT_HIGH_SCORES] Each player's seconds in this world ("played/"
	// in the skeldat store) and the world's name (the scores: scores.h)
	std::map<ss_, double> m_played;
	ss_ m_world_name;
	// [SKELDAT_RERUN] A re-run asked for: the module is reloading
	bool m_rerunning = false;
	// m_joining: sent the join, its login not yet in
	std::set<size_t> m_waiting, m_joining;
	// The furnaces and the lanterns (furnaces.h)
	Furnaces m_furnaces{m_world};
	// The bones' growth and the world's end (bones_growth.h)
	BonesGrowth m_growth{m_world, m_furnaces};
	// The high scores (scores.h)
	Scores m_scores{m_world, m_growth, m_save, m_store, m_world_name,
			m_played};
	float m_save_t = 0, m_send_t = 0, m_breath_t = 0,
			m_move_t = 0;
	size_t m_worldgen_queue = 0;
	// The stacks on the ground (drops.h)
	Drops m_drops{m_world};
	// The world's making (terrain.h)
	Terrain m_terrain{m_world, m_save, m_store, m_drops};
	// The players, what they do and the session (players.h)
	Players m_players{m_world, *this, m_save, m_mobs, m_drops, m_growth,
			m_furnaces};
	// The mobs, the arrows and the light skeletons (mobs.h)
	Mobs m_mobs{m_world, m_players.all, m_players, m_drops, m_growth,
			m_furnaces};
	// The role, the pause, the skip and the admin's menu (admin.h)
	Admin m_admin{m_world, *this, m_save, m_players, m_growth, m_terrain};
	// The outermost columns' mean top, once the world is in
	float m_edge_crest = 0;
	// The lowest of those tops ([SKELDAT_BACKDROP_LOW]), where the hills
	// beyond start under
	int m_edge_low = 0;
	// Asked of worldgen and not merged yet: a section is loaded (empty)
	// before it is generated
	std::set<ss_> m_awaiting;
	// Sections still to relight ([SKELDAT_OWN_MAPGEN], a new world), and
	// since when
	size_t m_relight_left = 0;
	int64_t m_relight_t0 = 0;
	// [SKELDAT_MAKING_MAP] The making as a map to the waiting (making_map.h)
	MakingMap m_making_map{m_world, m_growth, m_waiting, m_awaiting};
	// [SKELDAT_MINING_HAZARDS] The pockets' liquids and gases (hazards.h):
	// the rules read and write through m_hz_w, the access the step holds.
	// A change not the step's own (a dig, a placing) is pending until the
	// next step wakes the hazards in it and round it.
	skeldat::hazards::Hazards m_hazards;
	voxelworld::Instance *m_hz_w = nullptr;
	std::vector<uint64_t> m_hz_pending;
	// The sections the step changed, to be counted again (save_and_report)
	std::set<ss_> m_hz_recount;
	std::unordered_map<uint64_t, skeldat::hazards::Cell> m_hz_seen;
	// water_source lava gas_poison gas_volcanic pocket_water (stage 1's
	// worlds', read as water) stone water_spring water_drain lava_spring
	uint32_t m_hz_ids[9] = {};
	// The rules' time and with voxelworld's commit of their changes (most
	// of it: ~5 ms a second for 100 voxels changed, the step's 0.6 ms)
	int64_t m_hz_us = 0, m_hz_step_us = 0;
	double m_hz_next_t = 0;
	size_t m_hz_steps = 0;
	// A test's watched box (the "pocket" test): its water volume reported
	int m_hz_watch[6] = {0, 0, 0, -1, -1, -1};

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{
		m_world.format = interface::VoxelFormat::luanti();
		m_world.format.planes.push_back(interface::VoxelPlane("bones", 8));
		// The bones drawn as skelenti draws its danger: the first surface
		// modifier, which the client's VOXELDECAY technique reads as the
		// decay (AreaField.glsl). wetness is only the slot it rides in.
		m_world.format.wetness = m_world.bones;
		m_furnaces.changed = [this](const ss_ &at){ m_players.send_furnace(at); };
		bind_hazards();
		// [SKELDAT_MINING_HAZARDS] "pocket <water|lava|poison> dx dz w h d": a
		// box of the full kind on the ground at the player's offset, its
		// surroundings watched (water's volume in the report)
		m_mobs.test_more = [this](const ss_ &kind, std::istream &it,
				Player &p){
			if(kind != "pocket")
				return false;
			ss_ what;
			int dx = 0, dz = 0, bw = 2, bh = 2, bd = 2;
			it>>what>>dx>>dz>>bw>>bh>>bd;
			step_hazards(); // the ids
			const int x0 = (int)std::floor(p.x) + dx,
					z0 = (int)std::floor(p.z) + dz, y0 = (int)std::floor(p.y);
			const uint32_t id = what == "lava" ? m_hz_ids[1] :
					what == "poison" ? m_hz_ids[2] : m_hz_ids[0];
			const uint32_t param = what == "poison" ? 255 : what == "lava" ? 7 : 0;
			for(int x = x0; x < x0 + bw; x++)
			for(int y = y0; y < y0 + bh; y++)
			for(int z = z0; z < z0 + bd; z++)
				m_world.set_node(x, y, z, id, param);
			const int r = 12;
			const int box[6] = {x0 - r, y0 - r, z0 - r, x0 + bw + r, y0 + bh + r,
					z0 + bd + r};
			std::copy(box, box + 6, m_hz_watch);
			log_i(MODULE, "skeldat: test: a %s pocket %dx%dx%d at %d,%d,%d",
					what.c_str(), bw, bh, bd, x0, y0, z0);
			return true;
		};
		// What is kept by the voxel: the stuck arrows (saved), the marker
		// skulls a footprint, and the sections whose tops are counted
		// again (the top may have moved to another section of the column)
		m_world.on_set.push_back([this](int x, int y, int z, uint32_t old,
				uint32_t id){
			const uint32_t stuck = m_world.stuck_id;
			if(old != id && (old == stuck || id == stuck)){
				const ss_ k = pos_key(x, y, z);
				if(id == stuck)
					m_mobs.stuck.insert(k);
				else
					m_mobs.stuck.erase(k);
				if(m_store){
					if(id == stuck)
						m_store->set("stuck/"+k, "1");
					else
						m_store->remove("stuck/"+k);
				}
			}
			const uint32_t marker = m_world.marker;
			const long f = m_world.footprint(x, z);
			if(f >= 0 && old != id && (id == marker || old == marker)){
				m_mobs.markers[f] += (id == marker) - (old == marker);
				log_i(MODULE, "skeldat: %d marker skulls in the footprint at "
						"%ld %ld", m_mobs.markers[f], f % (2 * m_world.half) -
						m_world.half, f / (2 * m_world.half) - m_world.half);
			}
			// The count is by the ids: a liquid's eighths changing is not
			// counted again; the liquid step's own changes are counted
			// every 10 s ([SKELDAT_OWN_MAPGEN]: a river's every step)
			if(old == id)
				return;
			const int S = skeldat::bones::SECTION;
			std::set<ss_> &into = m_hz_w ? m_hz_recount : m_growth.recount;
			for(int sy = m_world.y0; sy <= m_world.y1; sy++)
				into.insert(pos_key(WorldView::floor_div(x, S), sy,
						WorldView::floor_div(z, S)));
		});
	}

	void init()
	{
		sub(m_server, "core:start", &Module::on_start);
		// [SKELDAT_RERUN] The module reloaded: the world closed, and on
		// again (a re-run's, or the start's)
		sub(m_server, "core:unload", &Module::on_unload);
		sub(m_server, "core:continue", &Module::on_continue);
		sub(m_server, "core:tick", &Module::on_tick);
		sub(m_server, "core:shutdown", &Module::save);
		sub(m_server, "client_file:files_transmitted",
				&Module::on_files_transmitted);
		sub(m_server, "network:client_disconnected",
				&Module::on_client_disconnected);
		sub(m_server, "accounts:login", &Module::on_login);
		sub(m_server, "worldgen:queue_modified",
				&Module::on_worldgen_queue_modified);
		sub(m_server, "voxelworld:section_loaded", &Module::on_section_loaded);
		sub(m_server, "voxelworld:generation_request",
				&Module::on_generation_request);
		sub(m_server, "worldgen:section_generated",
				&Module::on_section_generated);
		sub(m_server, "voxelworld:section_unloaded",
				&Module::on_section_unloaded);
		sub(m_server, "world_menu:play", &Module::on_world_play);
		sub(m_server, "world_menu:close", &Module::on_world_close);
		const ss_ game = "network:packet_received/skeldat:";
		sub<network::Packet>(m_server, game+"admin",
				[this](const network::Packet &p){ m_admin.on_admin(p); });
		// The rest of the game's packets go to one handler, by name
		for(const char *n : {"open", "close", "move", "drop_slot", "craft", "respawn",
				"bow", "intro", "scores", "rerun", "pause", "worlds", "skip"})
			sub(m_server, game+n, &Module::on_game_packet);
		// What a player does in the world: builtin/luanti's session
		// (luanti/session.h), its calls this Module's (Game, below)
		// [SKELDAT_WORLD_ADMIN] Paused, only the chat, the wield and the
		// world's arrival
		for(const char *n : luanti_session::PACKETS)
			sub<network::Packet>(m_server,
					ss_("network:packet_received/luanti:")+n,
					[this](const network::Packet &p){
				if((m_admin.paused || m_admin.skip_left > 0) && p.name != "luanti:chat" &&
						p.name != "luanti:wield" && p.name != "luanti:world_in"){
					m_admin.refused_paused(p);
					return;
				}
				m_players.session.packet(p);
			});
	}

	//
	// The world dialog
	//

	void on_start()
	{
		start(true);
	}

	// pick: start the world the environment or the launch names
	void start(bool pick)
	{
		// The day's schedule, luanti_client's ([SKY_RENDER_SHARED]: the sky's
		// render is extensions/sky_render, meta.json's client_extensions),
		// and Luanti's touch controls ([SKELDAT_TOUCH]), as builtin/luanti
		// serves them
		const ss_ res = m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res/";
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_path("luanti/sky_model.lua", res+"sky_model.lua");
			i->add_file_path("luanti/touch.lua", res+"touch.lua");
		});
		serve_media();
		world_menu::access(m_server, [&](world_menu::Interface *i){
			world_menu::Field size{"size", "Size", "", "", false};
			// [SKELDAT_WORLD_SIZES]: start_world() reads it; the first the
			// default ([SKELDAT_TUNE_256]: 256, the others in size order)
			size.choices = {{"256", "256 x 64 x 256"},
				{"128", "128 x 64 x 128"}, {"512", "512 x 128 x 512"},
				{"1024", "1024 x 128 x 1024"}};
			// [SKELDAT_BONE_SPEED]: start_world() reads it too
			world_menu::Field speed{"speed", "Bone speed", "", "", false};
			speed.choices = {{"1", "1x"}, {"2", "2x"}, {"5", "5x"},
				{"10", "10x"}};
			// [SKELDAT_OWN_MAPGEN] The form, the first the default
			world_menu::Field terrain{"terrain", "Terrain", "", "", false};
			terrain.choices = {{"rivers", "Rivers"}, {"plains", "Plains"},
				{"lake", "Lake"}, {"sea", "Sea"}};
			i->configure({"skeldat", {{"seed", "Seed", "", "empty: random"},
					size, speed, terrain,
					// The high score, written at the end (step_end())
					{"ended", "The surface all bones after", "", "", true},
					// Who played it, with their hours ([SKELDAT_HIGH_SCORES])
					{"players", "Players", "", "", true}}});
		});
		m_scores.send_presets();
		// The launcher's picked world ([SKELDAT_LAUNCH_WORLD]), the launch's
		// save=; BUILDAT_SKELDAT_WORLD, a check's, made if it is not there
		const char *name = getenv("BUILDAT_SKELDAT_WORLD");
		if(!pick){
		} else if(name && name[0]){
			start_world(name, true);
		} else {
			bool refused = false;
			const ss_ save = interface::launch_param(m_server->get_config().
					get<ss_>("untrusted_launch"), "save", &refused);
			if(refused)
				log_w(MODULE, "skeldat: the launch's save refused");
			if(!save.empty() && !start_world(save, false))
				log_w(MODULE, "skeldat: the launch's save \"%s\" is no world: "
						"the menu", cs(save));
			// [SKELDAT_RESUME_WORLD] No launcher at all (a dedicated
			// server): the world that ran at the last exit, if one did
			ss_ kept;
			storage::Store *srv = m_scores.db_store("server");
			if(m_server->get_config().get<ss_>("untrusted_launch").empty() &&
					srv && srv->get("running", kept) && !kept.empty()){
				if(start_world(kept, false)){
					log_i(MODULE, "skeldat: resumed the world %s", cs(kept));
				} else {
					log_w(MODULE, "skeldat: the world %s that ran at exit is "
							"gone: the menu", cs(kept));
					srv->remove("running");
				}
			}
		}
	}

	// The textures the way a Luanti game's are found ([SKELDAT_LUANTI_PARTS]
	// 7): a texture pack, a directory under
	// <user>/shared/skeldat/texture_packs named by
	// BUILDAT_SKELDAT_TEXTURE_PACK, over main/client_data, LabPBR sidecars
	// and all. The pack's files go out as texture_pack/<name> and the
	// registry's tiles name those: client_data serves main/<name> itself,
	// and after this whatever the order.
	// simplified: the pack is picked by the environment and covers the
	// nodes, not the items' images; a pick in the admin's menu is the upgrade
	std::set<ss_> m_pack_files;
	void serve_media()
	{
		const char *pack = getenv("BUILDAT_SKELDAT_TEXTURE_PACK");
		sv_<std::pair<ss_, ss_>> name_paths;
		for(const auto &pair : luanti_media::collect(
				luanti_media::texture_pack_dirs(
				m_server->get_config().get<ss_>("user_path")+
				"/shared/skeldat/texture_packs", pack ? pack : ""))){
			m_pack_files.insert(pair.first);
			name_paths.push_back(std::make_pair("texture_pack/"+pair.first,
					pair.second));
		}
		if(name_paths.empty())
			return;
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_paths(name_paths);
		});
	}
	struct PackMedia: luanti_registry::Media
	{
		const std::set<ss_> &pack;
		PackMedia(const std::set<ss_> &pack): pack(pack){}
		ss_ texture(const ss_ &tile)
		{
			if(tile.compare(0, 5, "main/") == 0 && pack.count(tile.substr(5)))
				return "texture_pack/"+tile.substr(5);
			return tile;
		}
	};

	// A number is itself, other text its FNV-1a hash
	static uint32_t seed_of(const ss_ &text)
	{
		if(text.size() <= 10 &&
				text.find_first_not_of("0123456789") == ss_::npos)
			return (uint32_t)std::stoull(text);
		uint32_t h = 2166136261u;
		for(unsigned char c : text)
			h = (h ^ c) * 16777619u;
		return h;
	}

	// A world picked or made in builtin/world_menu; one that does not start
	// is the menu again
	void on_world_play(const world_menu::Play &event)
	{
		auto seed = event.options.find("seed");
		if(m_save){
			// [SKELDAT_WORLD_ADMIN] Picked in a running world: a switch
			switch_world(event.peer, event.name, seed == event.options.end() ?
					"" : seed->second);
			return;
		}
		if(!start_world(event.name, false, seed == event.options.end() ?
				"" : seed->second))
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show(event.peer);
			});
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		const size_t peer = event.recipient;
		// [SKELDAT_LOGIN] On a public server every join logs in first,
		// whatever the world's state ([WORLD_MENU_ADMIN]: only an admin
		// picks a world, the first made with the setup code); on_login()
		// goes on from there. The launcher's own game lets its clients in
		// as "client<peer>". simplified: BUILDAT_SKELDAT_GUEST_JOIN=1 (the
		// server's environment, check.sh's) lets them in so too, for the
		// scripted clients' names
		bool joined = getenv("BUILDAT_SKELDAT_GUEST_JOIN") &&
				ss_(getenv("BUILDAT_SKELDAT_GUEST_JOIN")) == "1";
		accounts::access(m_server, [&](accounts::Interface *i){
			joined = joined || i->launched() || !i->name_of(peer).empty();
		});
		if(!joined){
			m_joining.insert(peer);
			network::send(m_server, peer, "core:run_script",
					"buildat.run_script_file(\"main/join.lua\")");
			return;
		}
		if(m_world.ready)
			m_players.show(peer);
		else
			menu_or_wait(peer);
	}

	void menu_or_wait(size_t peer)
	{
		if(m_waiting.insert(peer).second){
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show(peer);
			});
			// A world coming in: its map so far ([SKELDAT_MAKING_MAP])
			m_making_map.start(peer);
		}
	}

	// A join's login: the world if it runs, else the world menu (which
	// shows the list to an admin and the wait to the rest)
	void on_login(const accounts::Login &login)
	{
		if(!m_joining.erase(login.peer))
			return;
		if(m_world.ready)
			m_players.show(login.peer);
		else
			menu_or_wait(login.peer);
	}

	//
	// The world
	//

	// The save opened (made, when `create`), its seed `seed_text` when it
	// has none yet: a number, or any text hashed to one
	bool start_world(const ss_ &name, bool create, const ss_ &seed_text = "")
	{
		if(m_starting)
			return false;
		storage::access(m_server, [&](storage::Interface *i){
			if(!i->valid_name(name) || name[0] == '_')
				return;
			m_save = i->open(name);
			if(!m_save && create)
				m_save = i->create(name);
		});
		if(!m_save){
			log_w(MODULE, "skeldat: no world \"%s\"", cs(name));
			return false;
		}
		m_starting = true;
		m_store = m_save->store("skeldat");
		m_world_name = name;
		// [SKELDAT_RESUME_WORLD] What a dedicated server starts again; an
		// exit leaves it, a close removes it
		if(storage::Store *srv = m_scores.db_store("server"))
			srv->set("running", name);
		for(const ss_ &key : m_store->list("played/")){
			ss_ t;
			if(m_store->get(key, t))
				m_played[key.substr(7)] = atof(t.c_str());
		}
		// For a check: "name seconds; ..." added to the times
		if(const char *env = getenv("BUILDAT_SKELDAT_PLAYED")){
			std::istringstream ps(env);
			ss_ one;
			while(std::getline(ps, one, ';')){
				std::istringstream os(one);
				ss_ who;
				double secs = 0;
				if(os>>who>>secs)
					m_played[who] += secs;
			}
		}
		ss_ v;
		// A world with no seed yet is new, the world menu's made one too
		m_making = !m_store->get("seed", v);
		// The players wait for the whole world (world_in())
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->progress(m_making ? "Making the world..." :
					"Loading the world...");
		});
		uint32_t seed = m_world.rand();
		const char *env_seed = getenv("BUILDAT_SKELDAT_SEED");
		if(m_store->get("seed", v))
			seed = (uint32_t)std::stoul(v);
		else if(!seed_text.empty())
			seed = seed_of(seed_text);
		else if(env_seed && env_seed[0])
			seed = (uint32_t)std::stoul(env_seed);
		m_store->set("seed", itos(seed));
		// [SKELDAT_OWN_MAPGEN] The form: a world made before has none and
		// was made by Luanti's valleys; a new one's the menu's pick, or for
		// a check BUILDAT_SKELDAT_TERRAIN's, or rivers
		if(!m_store->get("terrain", m_terrain.form)){
			const char *env = getenv("BUILDAT_SKELDAT_TERRAIN");
			ss_ picked;
			m_save->store("world_menu")->get("terrain", picked);
			m_terrain.form = !m_making ? "legacy_valleys" :
					skeldat::mapgen::form_of(picked) >= 0 ? picked :
					env && skeldat::mapgen::form_of(env) >= 0 ? env : "rivers";
			m_store->set("terrain", m_terrain.form);
			m_save->store("world_menu")->set("terrain", m_terrain.form);
		}
		if(m_store->get("day", v))
			m_world.day = atof(v.c_str());
		m_world.marker = m_world.id_of("skeldat:marker_skull");
		m_world.sun_ids = {m_world.id_of("skeldat:bone_block"), m_world.id_of("skeldat:skull"),
				m_world.id_of("skeldat:skulls"), m_world.marker};
		m_world.stuck_id = m_world.id_of("skeldat:stuck_arrow");
		if(m_store->get("world_t", v))
			m_world.t = atof(v.c_str());
		else if(const char *env = getenv("BUILDAT_SKELDAT_WORLD_T"))
			m_world.t = atof(env); // for a check: a new world's age, seconds
		if(m_store->get("ended", v)){
			m_growth.ended = true;
			m_growth.end_days = atof(v.c_str());
			if(m_store->get("ended_rank", v))
				std::istringstream(v)>>m_scores.end_best>>m_scores.end_place;
			log_i(MODULE, "skeldat: the world \"%s\" ended after %.1f days",
					cs(name), m_growth.end_days);
		}
		// The size picked when it was made ([SKELDAT_WORLD_SIZES]): its
		// width; a world from before the choice is 1024, as it was made
		ss_ size = "1024";
		m_save->store("world_menu")->get("size", size);
		const int width = atoi(size.c_str());
		if(width == 512 || width == 1024)
			m_world.half = width / 128, m_world.y0 = -1, m_world.y1 = 0;
		else if(width == 256 || width == 128)
			m_world.half = width / 128, m_world.y0 = 0, m_world.y1 = 0;
		// For a check: a small world, "<half> <y0> <y1>" in sections
		const char *env_size = getenv("BUILDAT_SKELDAT_SIZE");
		if(env_size && env_size[0] && sscanf(env_size, "%d %d %d", &m_world.half,
				&m_world.y0, &m_world.y1) != 3)
			log_w(MODULE, "skeldat: BUILDAT_SKELDAT_SIZE=\"%s\" not read",
					env_size);
		// [SKELDAT_BONE_SPEED] Picked when it was made, or by the admin
		// since; none is 1x. BUILDAT_SKELDAT_SPEED for a check's new world.
		ss_ speed = "1";
		storage::Store *menu = m_save->store("world_menu");
		const char *env_speed = getenv("BUILDAT_SKELDAT_SPEED");
		if(!menu->get("speed", speed) && env_speed && env_speed[0]){
			speed = env_speed;
			menu->set("speed", speed);
		}
		m_growth.speed = BonesGrowth::valid_speed(atoi(speed.c_str())) ? atoi(speed.c_str()) : 1;
		m_growth.speed_low = m_growth.speed;
		if(m_store->get("speed_low", v) && BonesGrowth::valid_speed(atoi(v.c_str())))
			m_growth.speed_low = std::min(m_growth.speed, atoi(v.c_str()));
		m_store->set("speed_low", itos(m_growth.speed_low));
		if(const char *env = getenv("BUILDAT_SKELDAT_BUDGET"))
			m_growth.budget = std::max(0.001, atof(env));
		log_i(MODULE, "skeldat: the bones at %dx (the lowest %dx)", m_growth.speed,
				m_growth.speed_low);
		m_mobs.markers.assign(m_world.footprints(), 0);
		m_world.footprints_ready = true;
		if(m_store->get("holes", v)){
			std::istringstream is(v);
			long c;
			int day;
			while(is>>c>>day)
				m_mobs.hole_day[c] = day;
		}
		if(m_store->get("hazards_active", v)){
			std::istringstream is(v);
			uint64_t k;
			while(is>>k)
				m_hz_pending.push_back(k);
			log_i(MODULE, "skeldat: hazards: %zu active read back",
					m_hz_pending.size());
		}
		if(m_store->get("markers", v)){
			std::istringstream is(v);
			int all = 0;
			for(int &n : m_mobs.markers)
				is>>n, all += n;
			log_i(MODULE, "skeldat: %d marker skulls in the world", all);
		}
		if(const char *env = getenv("BUILDAT_SKELDAT_DAY"))
			if(atof(env) > 0)
				m_world.day_s = (float)atof(env);
		if(const char *env = getenv("BUILDAT_SKELDAT_LIGHT_STEP"))
			if(atof(env) > 0)
				m_mobs.light_step = (float)atof(env);
		if(const char *env = getenv("BUILDAT_SKELDAT_EXPAND"))
			if(atof(env) > 0)
				m_growth.section_period = atof(env);
		// For a check: the time of day it starts at, 0.5 noon
		const char *env_time = getenv("BUILDAT_SKELDAT_TIME");
		if(env_time && env_time[0])
			m_world.day = atof(env_time);
		m_furnaces.store = m_store;
		m_furnaces.load();
		for(const ss_ &key : m_store->list("mob/")){
			Mob m;
			const uint32_t k = (uint32_t)atol(key.c_str() + 4);
			if(m_store->get(key, v) && m.load(v)){
				m.light_t = m_world.rnd() * m_mobs.light_step;
				if(m.grass_t < 0)
					m.grass_t = m_world.t;
				m_mobs.all[k] = m;
				m_mobs.next_mob = std::max(m_mobs.next_mob, k + 1);
			}
		}
		for(const ss_ &key : m_store->list("stuck/"))
			m_mobs.stuck.insert(key.substr(6));
		m_drops.store = m_store;
		m_mobs.store = m_store;
		m_drops.load();
		if(const char *env = getenv("BUILDAT_SKELDAT_TEST"))
			m_mobs.test = env;
		log_i(MODULE, "skeldat: the world \"%s\" starts, seed %u, %zu "
				"furnaces, %zu mobs, %d x %d x %d, day %.4f", cs(name), seed,
				m_furnaces.all.size(), m_mobs.all.size(), 2 * m_world.half * 64,
				(m_world.y1 - m_world.y0 + 1) * 64, 2 * m_world.half * 64, m_world.day);
		create_world(seed);
		return true;
	}


	void create_world(uint32_t seed)
	{
		m_world.scene = main_context::create_scene(m_server);
		m_terrain.seed = seed;
		worldgen::GeneratorInterface *generator = m_terrain.make_generator();
		// Before the voxelworld, or its first requests are lost
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->create_instance(m_world.scene);
			BonesGenerator::PileIds ids;
			ids.block = m_world.id_of("skeldat:bone_block");
			ids.tops[0] = m_world.id_of("skeldat:skull");
			ids.tops[1] = m_world.id_of("skeldat:skulls");
			ids.tops[2] = m_world.id_of("skeldat:bone_lying");
			ids.ground[0] = m_world.id_of("skeldat:grass");
			ids.ground[1] = m_world.id_of("skeldat:dirt");
			ids.ground[2] = m_world.id_of("skeldat:sand");
			m_generator = new BonesGenerator(generator, m_world.format, m_world.bones,
					m_terrain.seed, ids);
			m_generator->m_stone = m_world.id_of("skeldat:stone");
			m_generator->m_pocket[0] = m_world.id_of("skeldat:water_source");
			m_generator->m_pocket[1] = m_world.id_of("skeldat:gas_poison");
			m_generator->m_pocket[2] = m_world.id_of("skeldat:lava");
			m_generator->m_lava_spring = m_world.id_of("skeldat:lava_spring");
			m_generator->m_water_level = m_terrain.water_level;
			const char *fill = getenv("BUILDAT_SKELDAT_FILL");
			m_generator->m_half_v = m_world.half * skeldat::bones::SECTION;
			m_generator->m_fill = !fill ? 0 : ss_(fill) == "1" ? 1 :
					ss_(fill) == "half" ? 2 : ss_(fill) == "surface" ? 3 : 0;
			i->get_instance(m_world.scene)->set_generator(m_generator);
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			// The world's bounds in sections ([SKELDAT_BOUNDED_WORLD])
			i->create_instance(m_world.scene, pv::Region(-m_world.half, m_world.y0, -m_world.half,
					m_world.half - 1, m_world.y1, m_world.half - 1));
		});
		// Before voxelworld's first tick, which loads a whole region that
		// has no load points
		update_load_points();
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			reg->set_format(m_world.format);
			build_registry(reg);
			w->set_save(m_save, "main");
			// The generator lights the columns down to the ground and a new
			// world is relit when it is in (world_in()); voxelworld keeps
			// it up as the world changes, the torches' too
			w->set_light_maintained(voxelworld::Instance::LIGHT_SKY, true);
			w->set_light_maintained(voxelworld::Instance::LIGHT_LAMP, true);
		});
		worldgen::access(m_server, m_world.scene, [&](worldgen::Instance *i){
			i->enable();
		});
	}

	// Luanti's unknown and air, then the nodes at their ids
	void build_registry(interface::VoxelRegistry *reg)
	{
		luanti_registry::Builder builder;
		PackMedia media(m_pack_files);
		for(uint32_t id = ID_UNKNOWN; id < ID_NODE0 + m_game.nodes.size();
				id++){
			luanti_registry::NodeDef d = m_terrain.luanti_def(id);
			interface::VoxelDefinition v = builder.build(d, media);
			const skeldat::NodeDef *n = m_world.node_of(id);
			// [SKELDAT_OWN_MAPGEN] Water drawn at its eighths: param2 1..7
			// the level below it, 0 (full) the top one
			if(n && n->name == "skeldat:water_source")
				for(int p = 0; p < 256; p++)
					v.variant_of_param[p] = (uint8_t)(p == 0 || p > 8 ? 7 : p - 1);
			// [SKELDAT_MINING_HAZARDS] A gas's share in four steps of its
			// alpha, param2's top two bits: <tile>_q0..2.png, then its own
			if(n && n->shape == skeldat::GAS){
				for(int q = 0; q < 4; q++){
					interface::VoxelVariant var;
					for(const auto &t : v.textures){
						var.textures.push_back(t);
						ss_ &r = var.textures.back().resource_name;
						if(q < 3 && r.size() > 4)
							r = r.substr(0, r.size() - 4)+"_q"+itos(q)+".png";
					}
					v.variants.push_back(var);
				}
				for(int p = 0; p < 256; p++)
					v.variant_of_param[p] = (uint8_t)(p >> 6);
			}
			const interface::VoxelTypeId got = reg->add_voxel(v);
			if(got != id)
				throw Exception("skeldat: voxel "+d.name+" is id "+
						itos(got)+", not "+itos(id));
		}
	}

	void update_load_points()
	{
		// The whole world, always ([SKELDAT_BOUNDED_WORLD]): the region
		// clips the radius
		sv_<voxelworld::LoadPoint> points;
		points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(0, 0, 0),
				m_world.half, std::max(-m_world.y0, m_world.y1), m_world.half, std::max(-m_world.y0, m_world.y1)));
		for(auto &pair : m_players.all){
			const Player &pl = pair.second;
			if(!pl.placed)
				continue;
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					(int)std::floor(pl.x), (int)std::floor(pl.y),
					(int)std::floor(pl.z)), 3, 2, 2, 1, pair.first));
		}
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			w->set_load_points(points);
			w->set_stream_budget(m_worldgen_queue >= 12 ? 0 : 2);
		});
		m_world.load_points_dirty = false;
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &e)
	{
		m_worldgen_queue = e.queue_size;
		m_world.load_points_dirty = true;
	}

	//
	// The bones (bones.h)
	//

	void on_section_loaded(const voxelworld::SectionLoaded &e)
	{
		if(e.scene != m_world.scene || !m_save || !m_world.in_world(e.section_p))
			return;
		m_growth.sections.insert(m_world.section_key(e.section_p));
		m_growth.recount.insert(m_world.section_key(e.section_p));
		if(!m_world.ready)
			m_making_map.loaded(e.section_p);
		// The world coming in ([SKELDAT_BOUNDED_WORLD]): a line every
		// sixteenth, and the time it took
		const size_t all = m_world.all_sections();
		if(m_growth.sections.size() % std::max<size_t>(1, all / 16) == 0 &&
				!m_world.ready){
			log_i(MODULE, "skeldat: %zu of %zu sections loaded, %.1f s, the "
					"highest voxel made at y %d", m_growth.sections.size(), all,
					(interface::os::time_us() - m_start_us) / 1e6,
					m_generator ? (int)m_generator->m_top : 0);
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->progress(ss_(m_making ? "Making" : "Loading")+
						" the world: "+itos(m_growth.sections.size())+
						" of "+itos(all)+" sections");
			});
		}
	}

	void on_generation_request(const voxelworld::GenerationRequest &e)
	{
		if(e.scene == m_world.scene && m_world.in_world(e.section_p))
			m_awaiting.insert(m_world.section_key(e.section_p));
	}

	void on_section_generated(const worldgen::SectionGenerated &e)
	{
		if(e.scene != m_world.scene || !m_world.in_world(e.section_p))
			return;
		m_awaiting.erase(m_world.section_key(e.section_p));
		m_growth.recount.insert(m_world.section_key(e.section_p));
	}

	// The whole world in: the spawn found on it and the players let in
	void world_in()
	{
		m_world.ready = true;
		m_terrain.find_spawn();
		const int64_t t0 = interface::os::time_us();
		// The top map's columns, made at the first section in
		// ([SKELDAT_MAKING_MAP]), and some of them swept since
		m_making_map.begin();
		size_t bench = 0;
		if(const char *env = getenv("BUILDAT_SKELDAT_SKELETONS"))
			bench = (size_t)atol(env);
		// For a check: "sx sz n", footprint (sx, sz)'s marker count, the
		// skulls themselves not placed
		int mx, mz, mn;
		if(const char *env = getenv("BUILDAT_SKELDAT_MARKERS"))
			if(sscanf(env, "%d %d %d", &mx, &mz, &mn) == 3 &&
					m_world.footprint(mx * skeldat::bones::SECTION,
					mz * skeldat::bones::SECTION) >= 0)
				m_mobs.markers[m_world.footprint(mx * skeldat::bones::SECTION,
						mz * skeldat::bones::SECTION)] = mn;
		size_t added = 0;
		// The edge made now, on a new world, changes the outermost
		// footprints' tops: those swept again
		ss_ edge_v;
		const bool edge_new = m_store && !m_store->get("edge", edge_v);
		m_terrain.make_edge();
		if(edge_new && m_terrain.form != "legacy_valleys")
			settle_water();
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			// [SKELDAT_OWN_MAPGEN] A new world's light worked out from what
			// is in it (caves, overhangs, the lava pockets' own), sections
			// at a time on the ticks
			if(edge_new){
				const int S = skeldat::bones::SECTION;
				w->relight_region_later(pv::Region(
						-m_world.half * S, m_world.y0 * S, -m_world.half * S,
						m_world.half * S - 1, (m_world.y1 + 1) * S - 1,
						m_world.half * S - 1));
				m_relight_left = 1;
				m_relight_t0 = interface::os::time_us();
			}
			// Those the making's map did not sweep ([SKELDAT_MAKING_MAP])
			const int n = 2 * m_world.half;
			for(size_t i = 0; i < m_world.footprints(); i++){
				const int sx = (int)(i % n), sz = (int)(i / n);
				const bool edge = sx == 0 || sz == 0 || sx == n - 1 ||
						sz == n - 1;
				if(m_making_map.state[i] != 2 || (edge_new && edge))
					m_making_map.sweep(w, i);
			}
			// For a check: that many more light skeletons, anywhere
		});
		{
			const int h = m_world.half * skeldat::bones::SECTION;
			double sum = 0;
			size_t n = 0;
			int low = 1 << 30;
			for(int a = -h; a < h; a++)
				for(const auto &xz : {std::make_pair(a, -h),
						std::make_pair(a, h - 1), std::make_pair(-h, a),
						std::make_pair(h - 1, a)}){
					const long c = m_world.column(xz.first, xz.second);
					if(c >= 0 && m_world.top_y[c] != NO_GROUND)
						sum += m_world.top_y[c], n++, low = std::min(low,
								(int)m_world.top_y[c]);
				}
			m_edge_crest = n ? (float)(sum / n) + 1 : 0;
			m_edge_low = n ? low : 0;
		}
		// Not in a check's own set of mobs (TEST: no spawning, unless it
		// names "populate"; the bench, 0 an empty world)
		if((m_mobs.test.empty() || m_mobs.test.find("populate") != ss_::npos) &&
				!getenv("BUILDAT_SKELDAT_SKELETONS"))
			m_mobs.populate();
		for(size_t t = 0; t < 8 * bench && added < bench; t++)
			added += m_mobs.add_skeleton(false);
		if(getenv("BUILDAT_SKELDAT_SURVEY"))
			m_terrain.survey();
		if(const char *env = getenv("BUILDAT_SKELDAT_LANTERNS")){
			m_furnaces.test_lanterns(env, m_world.day_s);
			m_furnaces.report = true;
		}
		log_i(MODULE, "skeldat: the columns swept in %.1f ms%s",
				(interface::os::time_us() - t0) / 1e3, bench ?
				cs(", "+itos(added)+" skeletons added") : "");
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->set_running(true);
		});
		log_i(MODULE, "skeldat: the world is in, %.1f s",
				(interface::os::time_us() - m_start_us) / 1e6);
		m_making_map.end();
		for(size_t peer : m_waiting)
			m_players.show(peer);
		m_waiting.clear();
	}

	void on_section_unloaded(const voxelworld::SectionUnloaded &e)
	{
		if(e.scene != m_world.scene || !m_save)
			return;
		m_growth.sections.erase(m_world.section_key(e.section_p));
	}

	//
	// The leave and the save (the players are players.h's)
	//

	void on_client_disconnected(const network::OldClient &old)
	{
		const size_t peer = old.info.id;
		auto it = m_players.all.find(peer);
		if(it != m_players.all.end()){
			m_players.save_player(it->second);
			m_players.all.erase(it);
		}
		m_players.session.left(peer);
		m_players.shown.erase(peer);
		m_waiting.erase(peer);
		m_joining.erase(peer);
		m_making_map.started.erase(peer);
		m_world.load_points_dirty = true;
	}

	void save()
	{
		if(!m_save)
			return;
		storage::Store *ps = m_save->store("skeldat_players");
		ps->batch([&](){
			for(auto &pair : m_players.all)
				if(pair.second.placed)
					ps->set(pair.second.name, pair.second.save());
		});
		m_store->batch([&](){
			std::ostringstream os;
			os<<m_world.day;
			m_store->set("day", os.str());
			m_store->set("world_t", dtos(m_world.t));
			for(const auto &pp : m_played)
				m_store->set("played/"+pp.first, dtos(pp.second));
			m_furnaces.save();
			for(auto &pair : m_mobs.all)
				m_store->set("mob/"+itos(pair.first), pair.second.save());
			m_drops.save();
			std::ostringstream ms;
			for(int n : m_mobs.markers)
				ms<<n<<" ";
			m_store->set("markers", ms.str());
			std::ostringstream hs;
			for(auto &kv : m_mobs.hole_day)
				hs<<kv.first<<" "<<kv.second<<" ";
			m_store->set("holes", hs.str());
			std::ostringstream as;
			for(uint64_t k : m_hazards.active)
				as<<k<<" ";
			for(uint64_t k : m_hz_pending)
				as<<k<<" ";
			m_store->set("hazards_active", as.str());
		});
	}

	//
	// What the players are sent of the world's run
	//

	// PlayersHost's, the admin's
	void update_role(size_t peer, Player &pl, bool tell)
	{
		m_admin.update_role(peer, pl, tell);
	}
	void joined(size_t peer, Player &pl){ m_admin.joined(peer, pl); }
	bool skipping(){ return m_admin.skipping(); }

	// The world's size and its edge's mean crest, for the client's
	// backdrop beyond the edge ([SKELDAT_EDGE_RIDGE]): "half y0 y1 crest
	// low water form", half in voxels, low the lowest edge column's top,
	// water the water line ([SKELDAT_OWN_MAPGEN])
	void send_world(size_t peer)
	{
		std::ostringstream os;
		os<<m_world.half * skeldat::bones::SECTION<<" "<<m_world.y0 * skeldat::bones::SECTION
				<<" "<<(m_world.y1 + 1) * skeldat::bones::SECTION - 1<<" "<<m_edge_crest
				<<" "<<m_edge_low<<" "<<m_terrain.water_level<<" "<<m_terrain.form;
		network::send(m_server, peer, "skeldat:world", os.str());
	}

	// [SKELDAT_INTRO] The days left, "about": from the uncovered columns'
	// rate over the last few game days (m_growth.bare_days), else the days a
	// world of this size takes at 1x, over the speed, less those gone; 0
	// once ended. The days measured free-running with no player
	// (2026-10-17): 128 at seeds 2-5 17.5, 36.1, 39.2, 19.9; 256 at seeds 2
	// and 3 24.5, 68.0; 512 and 1024 on that trend (x1.6 a doubling)
	// simplified: the history is not saved, a restarted world starts it
	// again from the constant
	void send_intro(size_t peer)
	{
		const double gone = m_world.t / m_world.day_s;
		double left;
		if(m_growth.ended){
			left = 0;
		} else if(m_growth.bare_days.size() >= 3 && m_growth.bare_days.front().second >
				m_growth.bare_days.back().second){
			const auto &a = m_growth.bare_days.front(), &b = m_growth.bare_days.back();
			left = b.second * (b.first - a.first) / (a.second - b.second);
		} else {
			const int width = m_world.half * 2 * skeldat::bones::SECTION;
			const double days = width <= 128 ? 28 : width <= 256 ? 46 :
					width <= 512 ? 75 : 120;
			left = days / m_growth.speed - gone;
		}
		const int n = m_growth.ended ? 0 : std::max(1, (int)std::lround(left));
		network::send(m_server, peer, "skeldat:intro", itos(n));
	}

	void send_end(size_t peer)
	{
		if(m_growth.ended)
			network::send(m_server, peer, "skeldat:end", dtos(m_growth.end_days)+" "+
					itos(m_growth.speed_low)+" "+dtos(m_scores.end_best)+" "+
					itos(m_scores.end_place));
	}

	//
	// [SKELDAT_RERUN] A re-run of an ended world: any player's, the same
	// seed, size and speed, as <name>_rerun (a _rerun world's own name
	// again). Everyone is sent off with the goodbye that says the server
	// restarts, which a client with a launcher rejoins by; the module
	// reloads, the old instance closing the world (on_unload), the new
	// one deleting the target and making it (on_continue), every member
	// fresh.
	// simplified: a client with no launcher under it (started with -s)
	// is only disconnected
	//

	void rerun(const Player &pl)
	{
		if(!m_growth.ended || m_rerunning){
			// The button is there only after the end: this is a stray
			log_i(MODULE, "skeldat: %s's re-run refused: %s", cs(pl.name),
					m_growth.ended ? "one is starting" : "the world has not ended");
			return;
		}
		const ss_ rr = "_rerun";
		const bool is_rerun = m_world_name.size() > rr.size() &&
				m_world_name.compare(m_world_name.size() - rr.size(), rr.size(),
				rr) == 0;
		const ss_ target = is_rerun ? m_world_name : m_world_name+rr;
		bool valid = false;
		storage::access(m_server, [&](storage::Interface *i){
			valid = i->valid_name(target);
		});
		if(!valid){
			chat::access(m_server, [&](chat::Interface *c){
				c->say("A re-run of "+m_world_name+" can't be named "+target);
			});
			return;
		}
		m_rerunning = true;
		const ss_ line = pl.name+" starts a re-run as "+target;
		log_i(MODULE, "skeldat: %s", cs(line));
		chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		ss_ seed = "0";
		m_store->get("seed", seed);
		m_server->tmp_store_data("skeldat:rerun", target+"\n"+seed+"\n"+
				itos(m_world.half * 2 * skeldat::bones::SECTION)+"\n"+
				itos(m_growth.speed_low)+"\n"+m_terrain.form);
		network::access(m_server, [&](network::Interface *i){
			for(network::PeerInfo::Id p : i->list_peers()){
				i->send(p, "network:goodbye", "1The world is being made again "
						"as "+target);
				i->disconnect(p);
			}
		});
		m_server->reload_module(MODULE);
	}

	// The old instance: the world saved and closed, out of every module
	// that held it
	void on_unload()
	{
		if(!m_world.scene)
			return;
		log_i(MODULE, "skeldat: the world \"%s\" closed for a reload, day "
				"%.4f", cs(m_world_name), m_world.day);
		save();
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			w->commit();
		});
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->delete_instance(m_world.scene);
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			i->delete_instance(m_world.scene);
		});
		main_context::access(m_server, [&](main_context::Interface *i){
			i->delete_scene(m_world.scene);
		});
		m_world.scene = nullptr;
		storage::access(m_server, [&](storage::Interface *i){
			if(m_save)
				i->close(m_save);
			if(m_scores.db)
				i->close(m_scores.db);
		});
		m_save = nullptr;
		m_scores.db = nullptr;
		// The menu picks again: a switch's world or a closed one's menu
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->set_running(false);
		});
	}

	// The new instance: a re-run's world made (the target deleted first,
	// the old world itself when it is the target), or the start's again
	void on_continue()
	{
		// [SKELDAT_WORLD_ADMIN] "play\n<name>\n<seed>" or "close"
		const ss_ sw = m_server->tmp_restore_data("skeldat:switch");
		if(!sw.empty()){
			std::istringstream ss(sw);
			ss_ how, name, seed;
			std::getline(ss, how);
			std::getline(ss, name);
			std::getline(ss, seed);
			start(false);
			if(how == "play" && start_world(name, false, seed)){
				log_i(MODULE, "skeldat: switched to \"%s\"", cs(name));
			} else {
				log_i(MODULE, "skeldat: no world runs: the world menu");
				if(storage::Store *srv = m_scores.db_store("server"))
					srv->remove("running");
			}
			return;
		}
		const ss_ data = m_server->tmp_restore_data("skeldat:rerun");
		std::istringstream is(data);
		ss_ name, seed, size, speed, terrain;
		std::getline(is, name);
		std::getline(is, seed);
		std::getline(is, size);
		std::getline(is, speed);
		std::getline(is, terrain);
		if(name.empty()){
			start(true);
			return;
		}
		storage::access(m_server, [&](storage::Interface *i){
			for(const storage::SaveInfo &info : i->list())
				if(info.name == name){
					i->remove(name);
					log_i(MODULE, "skeldat: re-run: deleted %s", cs(name));
				}
			storage::Save *save = i->create(name);
			if(save){
				storage::Store *menu = save->store("world_menu");
				menu->set("seed", seed);
				menu->set("size", size);
				menu->set("speed", speed);
				// A valleys world's re-run is made on rivers
				if(skeldat::mapgen::form_of(terrain) >= 0)
					menu->set("terrain", terrain);
				i->close(save);
			}
		});
		log_i(MODULE, "skeldat: re-run: %s, seed %s, %s wide, %sx", cs(name),
				cs(seed), cs(size), cs(speed));
		start(false);
		start_world(name, false, seed);
	}

	//
	// [SKELDAT_WORLD_ADMIN] The picker's (world_menu's: the launcher's own
	// client, an admin) Worlds..., a switch to another world and Close
	// world (the pause is admin.h's). A switch and a close are the
	// re-run's reload: the world saved and closed, every client sent off
	// with the goodbye and rejoining. A close's reload starts no world: the
	// menu to the picker, the wait to the rest.
	//

	void reload_for(const ss_ &line, const ss_ &data, const ss_ &goodbye)
	{
		m_rerunning = true;
		log_i(MODULE, "skeldat: %s", cs(line));
		chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		m_server->tmp_store_data("skeldat:switch", data);
		network::access(m_server, [&](network::Interface *i){
			for(network::PeerInfo::Id p : i->list_peers()){
				i->send(p, "network:goodbye", "1"+goodbye);
				i->disconnect(p);
			}
		});
		m_server->reload_module(MODULE);
	}

	void switch_world(size_t peer, const ss_ &name, const ss_ &seed)
	{
		if(m_rerunning || !m_admin.picker(peer) || name == m_world_name){
			log_w(MODULE, "skeldat: a switch to \"%s\" by %s refused",
					cs(name), cs(m_players.name_of(peer)));
			return;
		}
		reload_for(m_players.name_of(peer)+" switches the world to "+name,
				"play\n"+name+"\n"+seed,
				"The server switches to the world "+name);
	}

	void on_world_close(const world_menu::Close &event)
	{
		if(m_rerunning || !m_save || !m_admin.picker(event.peer)){
			log_w(MODULE, "skeldat: a close by %s refused",
					cs(m_players.name_of(event.peer)));
			return;
		}
		reload_for(m_players.name_of(event.peer)+" closes the world "+m_world_name,
				"close", "The world "+m_world_name+" was closed");
	}

	void on_game_packet(const network::Packet &packet)
	{
		auto it = m_players.all.find(packet.sender);
		if(it == m_players.all.end())
			return;
		const size_t peer = packet.sender;
		Player &pl = it->second;
		const ss_ what = packet.name.substr(8); // after "skeldat:"
		std::istringstream is(packet.data);
		if(what == "intro"){
			send_intro(peer);
			return;
		}
		if(what == "scores"){
			m_scores.send_scores(peer, packet.data);
			return;
		}
		if(what == "pause"){
			m_admin.on_pause(peer, packet.data);
			return;
		}
		if(what == "worlds"){
			if(!m_admin.picker(peer)){
				log_w(MODULE, "skeldat: %s's Worlds... refused: not the "
						"picker", cs(pl.name));
				return;
			}
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show_running(peer, m_world_name);
			});
			return;
		}
		// [SKELDAT_WORLD_ADMIN] Paused: the game's requests refused; the
		// node's window closed and the how-to and the scores read
		if(what == "skip"){
			m_admin.on_skip(peer, packet.data);
			return;
		}
		if((m_admin.paused || m_admin.skip_left > 0) && what != "close"){
			m_admin.refused_paused(packet);
			return;
		}
		if(what == "rerun"){
			rerun(pl);
			return;
		}
		if(what == "respawn"){
			if(pl.hp <= 0)
				m_players.respawn(peer, pl);
			return;
		}
		if(pl.hp <= 0)
			return; // the dead do nothing else
		if(what == "open"){
			int x, y, z;
			pl.open = "";
			if(is>>x>>y>>z && m_players.reaches(pl, x, y, z)){
				const skeldat::NodeDef *n = m_world.node_of(m_world.id_at(x, y, z));
				if(n && (n->name == "skeldat:table" || m_players.has_slots(n->name))){
					pl.open = pos_key(x, y, z);
					if(n->name != "skeldat:table"){
						m_furnaces.all[pl.open]; // one that predates its record
						m_players.send_furnace(pl.open);
					}
				}
			}
		} else if(what == "close"){
			pl.open = "";
		} else if(what == "move"){
			int count = 0, fi = 0, ti = 0;
			ss_ floc, flist, tloc, tlist;
			if(is>>count>>floc>>flist>>fi>>tloc>>tlist>>ti)
				m_players.move(peer, pl, count, floc, flist, fi, tloc, tlist, ti);
		} else if(what == "drop_slot"){
			int count = 0, i = 0;
			ss_ loc, list;
			if(is>>count>>loc>>list>>i)
				m_players.drop_slot(peer, pl, count, loc, list, i);
		} else if(what == "craft"){
			m_players.craft(peer, pl);
		} else if(what == "bow"){
			ss_ how;
			float dx = 0, dy = 0, dz = 0, e[3];
			is>>how>>dx>>dy>>dz;
			const bool eye = bool(is>>e[0]>>e[1]>>e[2]);
			m_players.bow(peer, pl, how, dx, dy, dz, eye ? e : nullptr);
		}
	}

	//
	// The skeletons over the whole world ([SKELDAT_SKELETON_SIM])
	//

	// [SKELDAT_BONE_SPEED] The admin's switch: in the save, the audit log
	// and everyone's chat
	void set_speed(int s, const ss_ &by)
	{
		if(!BonesGrowth::valid_speed(s) || s == m_growth.speed)
			return;
		m_growth.speed = s;
		m_growth.speed_low = std::min(m_growth.speed_low, s);
		m_save->store("world_menu")->set("speed", itos(s));
		m_store->set("speed_low", itos(m_growth.speed_low));
		m_admin.audit(by, "", "set", "bone speed "+itos(s)+"x");
		const ss_ line = "The bones now grow at "+itos(s)+"x";
		chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_world.scene)
			return;
		// [SKELDAT_MAKING_MAP] The footprints whose sections are all in,
		// on the tick for the same reason as below
		if(!m_world.ready && m_save)
			m_making_map.step();
		// Every section loaded and generated: on the tick, after the
		// requests the last loads made are in m_awaiting
		if(!m_world.ready && m_save && m_growth.sections.size() == m_world.all_sections() &&
				m_awaiting.empty())
			world_in();
		// A new world's relight, under a budget a tick (more for the
		// sections by a player)
		if(m_relight_left){
			voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
				m_relight_left = w->relight_stale(8000, 30000, 2);
			});
			if(!m_relight_left)
				log_i(MODULE, "skeldat: the world relit in %.1f s",
						(interface::os::time_us() - m_relight_t0) / 1e6);
		}
		// [SKELDAT_WORLD_ADMIN] Paused: the world's clock and every step of
		// the game stand; the sections load and send, the session takes
		// the joins
		if(m_admin.paused){
			m_players.session.tick(event.dtime);
			if(m_world.load_points_dirty)
				update_load_points();
			return;
		}
		m_players.session.tick(event.dtime);
		// [SKELDAT_SKIP_TIME] Skipping: the world's steps in sub-steps
		if(m_admin.skip_left > 0)
			m_admin.step_skip();
		else
			step_world(event.dtime);
		if(m_world.load_points_dirty)
			update_load_points();
		m_send_t += event.dtime;
		if(m_send_t >= 0.2f){
			m_send_t = 0;
			m_players.send_players();
		}
		m_move_t += event.dtime;
		if(m_move_t >= 1){
			m_move_t = 0;
			// The players held while skipping: no move to check
			if(m_admin.skip_left <= 0)
				m_players.check_moves();
			update_skeletons();
		}
		m_save_t += event.dtime;
		if(m_save_t >= 10){
			m_save_t = 0;
			save_and_report();
		}
	}

	// The bones a tick; a server behind says so in the chat
	void step_bones(float dtime)
	{
		m_growth.step(dtime, m_admin.skip_left > 0, !m_players.all.empty(),
				[&](const char *line){
			chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		});
	}

	// The end at no bare column: the score, the save, the players told
	void step_end()
	{
		if(!m_growth.count(m_world.ready, m_world.t / m_world.day_s))
			return;
		char days_c[40];
		// The lowest speed it was at: a lower one is the easier
		snprintf(days_c, sizeof days_c, "%.1f days at %dx", m_growth.end_days,
				m_growth.speed_low);
		const ss_ days = days_c;
		m_store->set("ended", dtos(m_growth.end_days));
		m_save->store("world_menu")->set("ended", days);
		m_scores.record_score();
		const int64_t under = m_growth.bare_under();
		log_i(MODULE, "skeldat: every column's top has bones: the world ends "
				"after %s; %lld voxels under the tops have none", cs(days),
				(long long)under);
		for(auto &pair : m_players.all)
			send_end(pair.first);
	}

	// The world's own steps over dtime of game time: the clock, the bones,
	// the end, the arrows, the drops, the mobs, the light, the spawns, the
	// breath and the furnaces
	void step_world(float dtime)
	{
		m_world.time += dtime;
		m_world.t += dtime;
		m_world.day = std::fmod(m_world.day + dtime / m_world.day_s, 1.0);
		if(!m_growth.ended)
			step_bones(dtime);
		if(!m_growth.ended && m_world.ready)
			for(auto &pair : m_players.all)
				if(pair.second.placed)
					m_played[pair.second.name] += dtime;
		step_end();
		m_mobs.step_arrows(dtime);
		if(m_world.ready)
			step_hazards();
		m_players.step_drops(dtime);
		m_mobs.ai_t += dtime;
		if(m_mobs.ai_t >= 0.1f){
			// A long tick in steps of 0.2 s, so it is no fall through the
			// ground and a body keeps up with its light form, which steps
			// by the clock; past a second (the world's first sweep, 1.7 s)
			// the rest is dropped
			for(float left = std::min(m_mobs.ai_t, 1.0f); left > 1e-4f; left -= 0.2f)
				m_mobs.step_mobs(std::min(left, 0.2f));
			m_mobs.ai_t = 0;
		}
		if(m_world.ready){
			m_mobs.step_light(dtime);
			m_mobs.far_t += dtime;
			if(m_mobs.far_t >= std::min(m_mobs.light_step, 1.0f)){
				m_mobs.far_t = 0;
				m_mobs.send_far();
			}
			m_mobs.sweep_t += dtime;
			if(m_mobs.sweep_t >= 1){
				m_mobs.sweep_t = 0;
				const int64_t t0 = interface::os::time_us();
				voxelworld::access(m_server, m_world.scene,
						[&](voxelworld::Instance *w){
					m_growth.sweep(w, m_mobs.sweep++ % m_world.footprints());
				});
				m_mobs.light_us += interface::os::time_us() - t0;
			}
			const int phase = m_world.day >= 0.25 && m_world.day < 0.75;
			// The first tick's too: a world that starts at night has its
			// night's work
			if(phase != m_mobs.phase)
				m_mobs.pick_footprints(phase == 0);
			m_mobs.phase = phase;
			m_mobs.hour_t += dtime;
			if(m_mobs.hour_t >= m_world.day_s / 24){
				m_mobs.hour_t = 0;
				m_mobs.step_population();
			}
		}
		m_mobs.spawn_t += dtime;
		if(!m_mobs.test.empty())
			m_mobs.stage_test();
		else if(m_mobs.spawn_t >= 4){
			m_mobs.spawn_t = 0;
			m_mobs.spawn();
		}
		m_breath_t += dtime;
		if(m_breath_t >= 1){
			m_breath_t = 0;
			m_players.step_breath();
		}
		m_furnaces.step(dtime, m_world.day_s);
	}

	// [SKELDAT_MINING_HAZARDS] The rules on the voxels: a voxel's cell by
	// its id (water's param2 its eighths, 0 full; lava's its eighths less
	// one; a gas's its share),
	// outside the world solid; a cell back as its id. Lava gone solid is
	// stone.
	void bind_hazards()
	{
		using namespace skeldat::hazards;
		m_hazards.get = [this](int x, int y, int z){
			// Read once a step: the rules read the same cells over and over
			auto hit = m_hz_seen.find(key(x, y, z));
			if(hit != m_hz_seen.end())
				return hit->second;
			Cell c = read_cell(x, y, z);
			m_hz_seen[key(x, y, z)] = c;
			return c;
		};
		m_hazards.set = [this](int x, int y, int z, const Cell &c){
			// A spring or a drain stays one: what is put in a drain is gone,
			// a water spring is full again; a lava spring keeps its eighths
			const uint32_t was = m_world.format.id.get(m_hz_w->get_voxel(
					pv::Vector3DInt32(x, y, z), true).data);
			if(was == m_hz_ids[6] || was == m_hz_ids[7])
				return;
			if(was == m_hz_ids[8]){
				const uint32_t eighths = c.kind == LAVA ? c.amount : 1;
				m_world.set_node_in(m_hz_w, x, y, z, was, eighths - 1);
				m_hz_seen[key(x, y, z)] = read_cell(x, y, z);
				return;
			}
			uint32_t id = ID_AIR, param = 0;
			switch(c.kind){
			case WATER: id = m_hz_ids[0], param = c.amount == 8 ? 0 : c.amount; break;
			case LAVA: id = m_hz_ids[1], param = c.amount - 1u; break;
			case POISON: id = m_hz_ids[2], param = c.amount; break;
			case VOLCANIC: id = m_hz_ids[3], param = c.amount; break;
			case SOLID: id = m_hz_ids[5]; break;
			default: break;
			}
			// [SKELDAT_OWN_MAPGEN] A liquid flowing into air takes the bones
			// of what it covers, and one emptied to air leaves its bones on
			// what it covered, so a running river's top is not bare again
			// each time its water moves (and a world with one can end)
			int b = -1;
			const pv::Vector3DInt32 under(x, y - 1, z);
			const bool liquid_was = was == m_hz_ids[0] || was == m_hz_ids[1];
			if(was == ID_AIR && (c.kind == WATER || c.kind == LAVA))
				b = (int)m_world.bones.get(m_hz_w->get_sample(under, true));
			else if(liquid_was && c.kind == AIR){
				const uint32_t mine = m_world.bones.get(m_hz_w->get_sample(
						pv::Vector3DInt32(x, y, z), true));
				interface::VoxelSample u = m_hz_w->get_sample(under, true);
				if(m_world.holds_bones(m_world.format.id.get(u.planes[0])) &&
						m_world.bones.get(u) < mine){
					m_world.bones.set(u, mine);
					m_hz_w->set_sample(under, u);
				}
			}
			m_world.set_node_in(m_hz_w, x, y, z, id, param, b);
			m_hz_seen[key(x, y, z)] = c;
		};
		// Any other change wakes what is there and round it
		m_world.on_set.push_back([this](int x, int y, int z, uint32_t old,
				uint32_t id){
			if(m_hz_w || old == id)
				return;
			m_hz_pending.push_back(key(x, y, z));
			for(const auto &d : SIX)
				m_hz_pending.push_back(key(x + d[0], y + d[1], z + d[2]));
		});
	}

	skeldat::hazards::Cell read_cell(int x, int y, int z)
	{
		using namespace skeldat::hazards;
		const int S = skeldat::bones::SECTION;
		if(m_world.column(x, z) < 0 || y < m_world.y0 * S ||
				y >= (m_world.y1 + 1) * S)
			return Cell(SOLID);
		const uint32_t d = m_hz_w->get_voxel(pv::Vector3DInt32(x, y, z),
				true).data;
		const uint32_t id = m_world.format.id.get(d),
				param = m_world.format.param.get(d);
		if(id == ID_AIR)
			return Cell(AIR, 0, (uint8_t)m_world.format.light_sky.get(d));
		// Water's eighths, 0 (an old world's) full
		if(id == m_hz_ids[0])
			return Cell(WATER, (uint8_t)(param == 0 || param > 8 ? 8 : param));
		if(id == m_hz_ids[4])
			return Cell(WATER, (uint8_t)(param % 8 + 1));
		// [SKELDAT_OWN_MAPGEN] A spring always full, a drain always room, a
		// lava spring its eighths (less one in param2, at least 1)
		if(id == m_hz_ids[6])
			return Cell(WATER, 8);
		if(id == m_hz_ids[7])
			return Cell(AIR);
		if(id == m_hz_ids[8]){
			Cell c(LAVA, (uint8_t)(param % 8 + 1));
			c.spring = true;
			return c;
		}
		if(id == m_hz_ids[1])
			return Cell(LAVA, (uint8_t)(param % 8 + 1));
		if(id == m_hz_ids[2] || id == m_hz_ids[3])
			return Cell(id == m_hz_ids[2] ? POISON : VOLCANIC,
					(uint8_t)std::max(1u, param));
		return Cell(SOLID);
	}

	void step_hazards()
	{
		using namespace skeldat::hazards;
		if(!m_hz_ids[5]){
			const char *names[9] = {"skeldat:water_source", "skeldat:lava",
					"skeldat:gas_poison", "skeldat:gas_volcanic",
					"skeldat:pocket_water", "skeldat:stone", "skeldat:water_spring",
					"skeldat:water_drain", "skeldat:lava_spring"};
			for(int i = 0; i < 9; i++)
				m_hz_ids[i] = m_world.id_of(names[i]);
		}
		// For a check of what stands in water, not of its flow: the step
		// off (the settling of a new world still runs)
		static const bool still = getenv("BUILDAT_SKELDAT_STILL_WATER");
		if(still)
			return;
		// Four times a second: a gas's cells come due at their own
		// offsets, and each access's commit writes out every chunk touched
		if(m_world.t < m_hz_next_t || (m_hz_pending.empty() &&
				(m_hazards.due.empty() || m_hazards.due.top().first > m_world.t)))
			return;
		m_hz_next_t = m_world.t + skeldat::hazards::TICK;
		const int64_t t0 = interface::os::time_us();
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			m_hz_w = w;
			m_hazards.now = m_world.t;
			// Only the hazards among the woken: air and rock never move
			for(uint64_t k : m_hz_pending){
				int x, y, z;
				unkey(k, x, y, z);
				const uint8_t kind = m_hazards.get(x, y, z).kind;
				if(liquid(kind) || gas(kind))
					m_hazards.wake(x, y, z);
			}
			m_hz_pending.clear();
			m_hz_steps += m_hazards.step(m_world.t);
			m_hz_step_us = std::max(m_hz_step_us, interface::os::time_us() - t0);
			m_hz_w = nullptr;
			m_hz_seen.clear();
		});
		m_hz_us += interface::os::time_us() - t0;
	}

	// The water's voxels and volume (out[0], out[1]) over the world; with
	// wake, those with room under or beside them woken (the count woken)
	size_t count_water(voxelworld::Instance *w, size_t *out, bool wake)
	{
		using namespace skeldat::hazards;
		const int S = skeldat::bones::SECTION;
		size_t woken = 0;
		for(int sz = -m_world.half; sz < m_world.half; sz++)
		for(int sy = m_world.y0; sy <= m_world.y1; sy++)
		for(int sx = -m_world.half; sx < m_world.half; sx++){
			const interface::VoxelVolume vol = w->get_volume(pv::Region(
					pv::Vector3DInt32(sx * S, sy * S, sz * S),
					pv::Vector3DInt32(sx * S + S - 1, sy * S + S - 1,
					sz * S + S - 1)));
			for(int z = sz * S; z < sz * S + S; z++)
			for(int y = sy * S; y < sy * S + S; y++)
			for(int x = sx * S; x < sx * S + S; x++){
				const uint32_t d = vol.getVoxelAt(x, y, z).data;
				if(m_world.format.id.get(d) != m_hz_ids[0])
					continue;
				const uint32_t p = m_world.format.param.get(d);
				out[0]++, out[1] += p == 0 || p > 8 ? 8 : p;
				if(!wake)
					continue;
				// Room under it or beside it (a voxel outside the
				// section read from the world)
				bool room = false;
				for(int i = 0; i < 6 && !room; i++){
					if(SIX[i][1] > 0)
						continue;
					const int nx = x + SIX[i][0], ny = y + SIX[i][1],
							nz = z + SIX[i][2];
					const bool out = nx < sx * S || ny < sy * S || nz < sz * S ||
							nx >= sx * S + S || nz >= sz * S + S;
					const uint32_t nd = out ? w->get_voxel(pv::Vector3DInt32(
							nx, ny, nz), true).data : vol.getVoxelAt(nx, ny, nz).data;
					const uint32_t nid = m_world.format.id.get(nd);
					const uint32_t np = m_world.format.param.get(nd);
					room = nid == ID_AIR || (nid == m_hz_ids[0] &&
							np != 0 && np < 8);
				}
				if(room)
					m_hazards.wake(x, y, z), woken++;
			}
		}
		return woken;
	}

	// [SKELDAT_OWN_MAPGEN] **The settling** of a new world's water: every
	// water voxel with room beside or under it woken, then the liquid step
	// with no cap a step, SETTLE_STEPS water steps (SETTLE_MS at most) or
	// until all are at rest, evaporation SETTLE_EVAPORATE times as fast;
	// what still moves goes on in the game at its cap. The water's voxels
	// and volume, before and after.
	void settle_water()
	{
		using namespace skeldat::hazards;
		step_hazards(); // the ids
		const int64_t t0 = interface::os::time_us();
		const int S = skeldat::bones::SECTION;
		size_t woken = 0, rounds = 0, left = 0;
		size_t before[2] = {0, 0}, after[2] = {0, 0};
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			m_hz_w = w;
			m_hazards.now = m_world.t;
			woken = count_water(w, before, true);
			m_hazards.evaporate_one_in = EVAPORATE_ONE_IN / SETTLE_EVAPORATE;
			double t = m_world.t;
			for(; rounds < (size_t)SETTLE_STEPS && !m_hazards.due.empty() &&
					interface::os::time_us() - t0 < SETTLE_MS * 1000; rounds++){
				t += WATER_PERIOD;
				m_hazards.step(t, (size_t)-1);
				m_hz_seen.clear();
			}
			m_hazards.evaporate_one_in = EVAPORATE_ONE_IN;
			// What still moves, due again from the game's clock
			left = m_hazards.active.size();
			for(uint64_t k : m_hazards.active)
				m_hz_pending.push_back(k);
			m_hazards.active.clear();
			m_hazards.due = decltype(m_hazards.due)();
			m_hazards.now = m_world.t;
			count_water(w, after, false);
			m_hz_w = nullptr;
		});
		log_i(MODULE, "skeldat: water: %zu voxels, %zu volume made; %zu voxels, "
				"%zu volume after the settling (%zu woken, %zu steps, %zu still "
				"moving, %.1f ms)", before[0], before[1], after[0], after[1],
				woken, rounds, left, (interface::os::time_us() - t0) / 1e3);
	}

	// The 10 s report: the set, the time, the watched box's water
	void report_hazards()
	{
		using namespace skeldat::hazards;
		if(m_hazards.active.empty() && !m_hz_steps && m_hz_watch[3] < 0)
			return;
		int volume = -1;
		if(m_hz_watch[3] >= 0)
			voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
				m_hz_w = w;
				volume = 0;
				for(int x = m_hz_watch[0]; x <= m_hz_watch[3]; x++)
				for(int y = m_hz_watch[1]; y <= m_hz_watch[4]; y++)
				for(int z = m_hz_watch[2]; z <= m_hz_watch[5]; z++){
					const Cell c = m_hazards.get(x, y, z);
					if(c.kind == WATER)
						volume += c.amount;
				}
				m_hz_w = nullptr;
				m_hz_seen.clear();
			});
		log_i(MODULE, "skeldat: hazards: %zu active, %zu stepped, a step %.3f ms "
				"at most, %.3f ms a second with the commits, water volume %d",
				m_hazards.active.size(), m_hz_steps, m_hz_step_us / 1e3,
				m_hz_us / 1e3 / 10, volume);
		m_hz_steps = 0, m_hz_us = 0, m_hz_step_us = 0;
	}

	void save_and_report()
	{
		save();
		// The pace, for whoever tunes it
		log_i(MODULE, "skeldat: bones: %zu expansions so far, %zu voxels "
				"changed, %zu grown, %zu sections loaded, %zu rule runs "
				"at %dx", m_growth.expansions, m_growth.expand_changed, m_growth.grown,
				m_growth.sections.size(), m_growth.rule_runs, m_growth.speed);
		size_t skeletons = 0, full = 0;
		for(auto &kv : m_mobs.all)
			if(kv.second.kind == SKELETON)
				skeletons++, full += kv.second.node_id != 0;
		log_i(MODULE, "skeldat: %zu skeletons, %zu full, %zu woken; %zu "
				"light steps and the sweep, %.2f ms a second; %zu bodies "
				"put back", skeletons, full, m_mobs.woken, m_mobs.light_steps,
				m_mobs.light_us / 1e3 / 10, m_mobs.body_puts);
		m_mobs.light_us = 0, m_mobs.light_steps = 0, m_mobs.woken = 0, m_mobs.body_puts = 0;
		report_hazards();
		m_growth.recount.insert(m_hz_recount.begin(), m_hz_recount.end());
		m_hz_recount.clear();
		// For a check: the world's water, a scan of every section
		if(getenv("BUILDAT_SKELDAT_WATER_REPORT") && m_world.ready){
			size_t n[2] = {0, 0};
			voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
				count_water(w, n, false);
			});
			log_i(MODULE, "skeldat: water: %zu voxels, %zu volume", n[0], n[1]);
		}
		if(m_furnaces.report)
			m_furnaces.report_lanterns();
		for(auto &pair : m_players.all)
			m_players.send_time(pair.first);
	}

	// [SKELDAT_SKELETON_PLAYERS] Who looks like a skeleton (bones.h's
	// skeleton_near()), admins too; a change logged, and it goes out in
	// m_players.send_players()
	void update_skeletons()
	{
		for(auto &pair : m_players.all){
			Player &pl = pair.second;
			if(!pl.placed)
				continue;
			const int x = (int)std::floor(pl.x + 0.5f),
					y = (int)std::floor(pl.y + 0.5f),
					z = (int)std::floor(pl.z + 0.5f);
			bool now = false;
			voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
				now = skeldat::bones::skeleton_near([&](int vx, int vy, int vz){
					return (int)m_world.bones.get(w->get_sample(
							pv::Vector3DInt32(vx, vy, vz), true));
				}, x, y, z);
			});
			if(now == pl.skeleton)
				continue;
			pl.skeleton = now;
			log_i(MODULE, "skeldat: %s looks like %s to the others",
					cs(pl.name), now ? "a skeleton" : "a player");
		}
	}


};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
