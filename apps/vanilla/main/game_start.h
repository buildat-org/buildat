// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [VANILLA_MODULAR] **Starting a world**: what the server runs at its
// start (the environment, the launch, a public server's choice), the
// launch an owner's client sends, and start_world(), which opens the
// save and hands builtin/luanti the game; a public server's switch to
// another world.
// Included by main.cpp inside namespace vanilla, after importer.h
#pragma once

struct GameStart
{
	// The Module's: the world starting or running and its save, the
	// public server's players and its restart
	interface::Server *m_server;
	luanti::SceneReference &m_scene;
	bool &m_starting;
	bool &m_public;
	ss_ &m_world_name;
	storage::Save *&m_world_save;
	float &m_restart_in;
	std::map<network::PeerInfo::Id, ss_> &m_names;
	Access &m_access;
	ContentDB &m_contentdb;
	GameSettings &m_game_settings;
	Importer &m_importer;

	GameStart(interface::Server *server, luanti::SceneReference &scene,
			bool &starting, bool &public_, ss_ &world_name,
			storage::Save *&world_save, float &restart_in,
			std::map<network::PeerInfo::Id, ss_> &names, Access &access,
			ContentDB &contentdb, GameSettings &game_settings,
			Importer &importer):
		m_server(server), m_scene(scene), m_starting(starting),
		m_public(public_), m_world_name(world_name), m_world_save(world_save),
		m_restart_in(restart_in), m_names(names), m_access(access),
		m_contentdb(contentdb), m_game_settings(game_settings),
		m_importer(importer)
	{}

	// The launch the owner's client last sent (launch:untrusted), which
	// stands for -u from then on: the launcher keeps a server that holds
	// no world and hands it the next launch of this app over the
	// connection rather than starting another
	ss_ m_launch;

	bool m_launch_sent = false;

	// Another world, by restarting: everyone is told, the choice is kept
	// for the next start, and the server exits with RESTART_STATUS, which
	// the script that runs it takes as start again at once
	void switch_world(const ss_ &name, network::PeerInfo::Id by)
	{
		if(name == m_world_name){
			menu_message(m_server, by, name+" is the world running");
			return;
		}
		write_public_world(m_server, name);
		log_i(MODULE, "%s switches the world to %s", cs(m_names[by]), cs(name));
		if(m_scene){
			luanti::access(m_server, [&](luanti::Interface *i){
				i->chat_send("", "The server switches to the world "+name+
						": join again in a moment");
			});
		}
		// A moment for that to reach everyone before the connections go
		m_restart_in = 1.5f;
	}

	// One key of what an untrusted launcher asked for, through the server's
	// -u ([LAUNCH_GRID]): read as a packet would be -- a value of the shape
	// a directory name has, or "" with a warning. The lines are key=value.
	ss_ launch_param(const ss_ &key_name)
	{
		bool refused = false;
		const ss_ v = interface::launch_param(m_launch_sent ? m_launch :
				m_server->get_config().get<ss_>("untrusted_launch"), key_name,
				&refused);
		if(refused)
			log_w(MODULE, "untrusted_launch: %s refused", cs(key_name));
		return v;
	}

	// The two lists the menu is: every save this game has, with the Luanti
	// game each one says it needs, and every Luanti game there is to choose
	// from. Flat, with the number of saves leading, because that is what one
	// array of strings can carry.
	// The same lines -u holds, read through launch_param() as those are;
	// the owner's alone, since anyone else's would choose for the owner
	void on_launch_untrusted(const network::Packet &packet)
	{
		if(m_public || !is_owner(m_server, packet.sender) ||
				packet.data.size() > 4096)
			return;
		m_launch = packet.data;
		m_launch_sent = true;
	}

	// Without one of these the game waits for a menu choice; with one it
	// runs what the environment says, which is what every check here does.
	void on_start()
	{
		// A transfer a stopped server was in the middle of
		m_importer.end_transfer();
		set_public();
		start_jobs_once();
		move_old_saves();
		set_send_policy();
		ss_ gameid, world_name;
		if(pick_world(gameid, world_name))
			start_world(gameid, world_name, 0);
	}

	// [VANILLA_PUBLIC] A server the launcher did not start is public
	void set_public()
	{
		m_public = launch_param("launcher") != "1";
		if(m_public)
			log_i(MODULE, "A public server: clients join by account, and the "
					"worlds are the admins'");
		// [VANILLA_CHAT_MIN] Who may talk, builtin/chat's setting: on a
		// public server Residents and up (a Guest is anyone who made an
		// account), on the launcher's own LAN game everyone (a friend
		// joining talks at once); a moderator's choice in the save over
		// either
		chat::access(m_server, [&](chat::Interface *i){
			i->set_default_min(m_public ? "member" : "everyone");
		});
	}

	// What the environment asks ContentDB for at the start, for a check
	void start_jobs_once()
	{
		// BUILDAT_LUANTI_FETCH_ONCE: one ContentDB listing at start, its
		// outcome logged and sent to nobody -- the smoke's way of running
		// http_get, whose std::call_once died on the box through a
		// winpthreads linked into Urho3D.dll ([WIN8_START] 16); a fetch
		// that errors is a fetch that ran
		if(getenv("BUILDAT_LUANTI_FETCH_ONCE")){
			ContentDB::Job *job = new ContentDB::Job();
			job->kind = ContentDB::Job::LIST;
			job->peer = 0;
			job->q = "";
			m_contentdb.start_job(job);
			log_i(MODULE, "contentdb: fetching once, for the log");
		}
		// BUILDAT_CONTENTDB_INSTALL_ONCE=author/name: an install at start,
		// its outcome logged ([SAVE_LIMIT]'s check)
		if(const char *once = getenv("BUILDAT_CONTENTDB_INSTALL_ONCE")){
			const ss_ q = once;
			const size_t slash = q.find('/');
			if(slash != ss_::npos)
				m_contentdb.contentdb_install(0, q.substr(0, slash),
						q.substr(slash + 1));
		}
	}

	// The game was games/luanti_launcher until 2026-09-20 and its saves
	// lived under that name: moved to this one on the first start
	// that finds the new directory absent, so nobody loses a world
	// ([LAUNCH_GRID]'s rename checklist)
	void move_old_saves()
	{
		const ss_ games = m_server->get_config().get<ss_>("user_path")+
				"/apps";
		const ss_ old_dir = games+"/luanti_launcher";
		const ss_ new_dir = games+"/vanilla";
		if(interface::fs::path_exists(old_dir) &&
				!interface::fs::path_exists(new_dir)){
			if(rename(old_dir.c_str(), new_dir.c_str()) == 0)
				log_i(MODULE, "Moved %s to %s", cs(old_dir), cs(new_dir));
			else
				log_w(MODULE, "Could not move %s to %s", cs(old_dir),
						cs(new_dir));
		}
	}

	// What this game does about a client that stops reading. Luanti's
	// own answer: a window of what may be in flight, and a timeout that
	// disconnects rather than a queue that grows without bound -- a
	// client that has been given eight megabytes and has read none of
	// it for half a minute is gone, not waited for. See SendPolicy in
	// builtin/network/api.h, and the master plan's "And the bottom of
	// it is a blocking socket write" for why this is a choice at all.
	//
	// Eight megabytes because one client taking a VoxeLibre world moves
	// about that much in its first seconds, so the window is "a world's
	// worth behind" rather than a number that a healthy client trips.
	void set_send_policy()
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->set_send_policy(network::SendPolicy::Disconnect,
					8 * 1024 * 1024, 30000000);
			// **The menus' answers go ahead of the world** ([NET_CHANNELS];
			// user, 2026-09-30: "Looking for saves..." counted past 100 s in
			// the world menu, behind the world streaming to a slow link).
			// Each answer is the whole of what it says, so a newer one
			// replacing an unsent one loses nothing, and they keep their
			// order among themselves (main:menu before main:saves). Only
			// answers to a script's own request: main:account and
			// main:join_title follow the run_script that starts their
			// reader, and ahead of it they would find nobody.
			for(const char *name : {"main:menu", "main:disk", "main:trash",
					"main:running_world", "main:saves",
					"main:save_info", "main:imports", "main:settings",
					"main:progress",
					"main:contentdb_list", "main:menu_message",
					"main:menu_error", "main:game_mapgens"})
				inetwork->declare(name,
						network::Interface::Channel::LatestOnly);
		});
	}

	// The world the start runs: a public server's choice, the
	// environment's or the launch's; false when there is none to run
	// yet, or the server is shutting down for want of it
	bool pick_world(ss_ &gameid, ss_ &world_name)
	{
		// A game by name: what the visual check runs, and what anyone wanting
		// the bundled game wants.
		const char *wanted_game = getenv("BUILDAT_LUANTI_GAME");
		const char *wanted_world = getenv("BUILDAT_LUANTI_WORLD");
		// Or what an untrusted launcher asked for, through the server's
		// -u ([LAUNCH_GRID]): read as a packet would be -- the one key this
		// takes, a game name of the shape a directory name has, and the
		// rest ignored. The environment, the shell's and the runners', wins.
		ss_ launched_game = launch_param("luanti_game");
		// menu=worlds with a game: the save list of that game rather than
		// its one implicit world -- the Luanti tile's world selection
		// ([LAUNCH_GRID]). The game goes to the client with the menu.
		if(launch_param("menu") == "worlds")
			launched_game = "";
		if(!(wanted_game && wanted_game[0]) && !launched_game.empty())
			wanted_game = launched_game.c_str();
		if(m_public && !read_public_world(m_server).empty() &&
				!gameid_of_save(m_server, read_public_world(m_server)).empty()){
			// The world an admin chose ([VANILLA_PUBLIC] 5), over the
			// environment, which is then the first boot's
			world_name = read_public_world(m_server);
			gameid = gameid_of_save(m_server, world_name);
		} else if(wanted_game && wanted_game[0]){
			gameid = wanted_game;
			// The save is named after the game unless something says
			// otherwise, which is what running two imports of the same game
			// into two saves needs.
			const char *wanted_save = getenv("BUILDAT_LUANTI_SAVE");
			world_name = (wanted_save && wanted_save[0]) ? wanted_save :
					gameid+"_world";
		} else if(wanted_world && wanted_world[0]){
			// A Luanti world directory, read for the one thing it knows that
			// nothing else does -- which game it wants. What is run is a
			// buildat save of the same name.
			for(const World &w : list_worlds(m_server)){
				if(w.name == wanted_world){
					gameid = w.gameid;
					world_name = w.name;
				}
			}
			if(gameid == ""){
				m_server->shutdown(1, ss_()+"No world called "+wanted_world);
				return false;
			}
		} else {
			// Whoever connects picks; see on_get_saves(). On a public
			// server that is an admin.
			log_i(MODULE, "Waiting for a save to be chosen");
			return false;
		}
		return true;
	}

	// Runs the game in the save, or says why it cannot. peer is who asked,
	// for the saying; zero is nobody, and then a failure is fatal because
	// nothing was there to ask.
	// automatic is a launch nobody clicked: it logs where a user's own
	// second click would be told, so a fault of this shape does not reach
	// the client as a dialog over a world that is loading fine
	void start_world(const ss_ &gameid, const ss_ &world_name,
			network::PeerInfo::Id peer, const ss_ &import_world_from = "",
			bool automatic = false)
	{
		if(m_starting){
			if(automatic)
				log_i(MODULE, "start_world: %s is already starting",
						cs(world_name));
			else
				menu_error(m_server, peer, "A world is already starting");
			return;
		}
		auto refuse = [&](const ss_ &message){
			// A public server waits for an admin rather than exiting,
			// which its runner would take as a crash to restart
			if(peer == 0 && m_public){
				log_e(MODULE, "%s; waiting for an admin", cs(message));
				return;
			}
			if(peer == 0){
				m_server->shutdown(1, message);
				return;
			}
			menu_error(m_server, peer, message);
		};
		ss_ game_path = find_game(m_server, gameid);
		if(game_path.empty()){
			refuse("World "+world_name+" wants game "+gameid+
					", which is not in "+
					m_access.where(luanti_path(m_server)+"/games"));
			return;
		}
		// [WORLD_MODS] A world whose mods cannot load does not start, and
		// the menu says why, as Luanti refuses it
		{
			ss_ save_path;
			const ss_ problem = save_dir(m_server, world_name, save_path) ?
					world_mods_problem(m_server, game_path, save_path) : "";
			if(!problem.empty()){
				refuse(world_name+": "+problem);
				return;
			}
		}
		m_starting = true;
		m_world_name = world_name;
		announce_world(world_name, game_path, peer);
		storage::Save *save = open_save(world_name);
		m_world_save = save;
		if(!save){
			ss_ message = "Could not open or create the save "+world_name;
			m_starting = false;
			if(peer == 0){
				m_server->shutdown(1, message);
				return;
			}
			menu_error(m_server, peer, message);
			return;
		}
		// Which game a save needs is the save's to remember, so that the
		// menu can say it without opening the game
		save->store("main")->set("gameid", gameid);
		log_i(MODULE, "Running world %s (game %s) in %s",
				cs(world_name), cs(gameid), cs(save->path()));
		if(!load_extra_lua())
			return;

		// A Luanti world's own map, read into the save once. The world
		// directory is opened read-only; what it says about which game it
		// wants is what chose the game above.
		// The menu's import names one; BUILDAT_LUANTI_IMPORT is the other
		// way in and is what every check here uses
		const char *env_import = getenv("BUILDAT_LUANTI_IMPORT");
		const ss_ import_from = !import_world_from.empty() ?
				import_world_from :
				ss_(env_import && env_import[0] ? env_import : "");
		if(!import_from.empty())
			import_world_mods(import_from, save, peer);
		run_game(game_path, save, import_from, peer);
	}

	// The world, told to whoever lists or shows it: the LAN, the
	// Starport, the browser tab
	void announce_world(const ss_ &world_name, const ss_ &game_path,
			network::PeerInfo::Id peer)
	{
		// Announced under the world's name once open to the LAN; who comes
		// in from there plays without an account (player_name_of())
		accounts::access(m_server, [&](accounts::Interface *i){
			i->set_lan_name(world_name, false);
		});
		// [HEARTH_VISITOR_FLOW] The game where it came from, for the
		// listing: what the ContentDB install wrote beside it
		ss_ source;
		std::getline(std::ifstream(game_path+"/.buildat_source"), source);
		const size_t slash = source.find('/');
		if(source.compare(0, 10, "contentdb:") != 0 || slash == ss_::npos ||
				slash <= 10 || slash + 1 >= source.size() ||
				source.find_first_not_of("abcdefghijklmnopqrstuvwxyz"
				"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-/", 10) != ss_::npos ||
				source.find('/', slash + 1) != ss_::npos)
			source.clear();
		starport_announce::access(m_server,
				[&](starport_announce::Interface *a){ a->set_game(source); });
		// A world is left by stopping the server, as a dedicated one's is
		if(peer != 0){
			network::send(m_server, peer, "launch:reusable", "0");
		}
		if(m_public)
			write_public_world(m_server, world_name);

		// [FAVICON] the game's own icon in the browser tab, when it has one,
		// and [PAGE_TITLE] its title on the tab
		{
			std::ifstream ic(game_path+"/menu/icon.png", std::ios::binary);
			ss_ png;
			if(ic.good()){
				std::ostringstream os(std::ios::binary);
				os<<ic.rdbuf();
				png = os.str();
			}
			const ss_ title = read_game_title(game_path);
			network::access(m_server, [&](network::Interface *inetwork){
				if(!png.empty())
					inetwork->set_favicon(png);
				inetwork->set_page_title(title, false);
			});
		}
	}

	// The world runs in a buildat save and never in a Luanti world
	// directory. Nothing here writes to user/luanti at any point: a
	// Luanti world is read, or imported, and that is all. It has to be
	// this way round rather than by being careful, because the writes do
	// not come from here -- devtest's testnodes mod writes a PNG through
	// core.get_worldpath() while it loads.
	storage::Save* open_save(const ss_ &world_name)
	{
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->open(world_name);
			if(!save){
				save = istorage->create(world_name);
				// BUILDAT_LUANTI_SEED: a new save's seed, the way the
				// menu's third value is, so a scripted run on both engines
				// is of one world
				const char *seed = getenv("BUILDAT_LUANTI_SEED");
				if(save && seed && seed[0])
					write_world_mt(save->path()+"/luanti/world.mt",
							{{"fixed_map_seed", seed}});
			}
		});
		return save;
	}

	// A file of Lua into the game's environment, before its mods load.
	// What this is for is a game of one's own on top of a Luanti game
	// -- which is what load_lua() is in the module's interface for --
	// and, while there is no such game here, for looking into one that
	// misbehaves.
	// false: the server is shutting down for want of it
	bool load_extra_lua()
	{
		const char *extra_lua = getenv("BUILDAT_LUANTI_LUA");
		if(extra_lua && extra_lua[0]){
			std::ifstream ifs(extra_lua, std::ios::binary);
			if(!ifs.good()){
				m_server->shutdown(1, ss_()+"Cannot read "+extra_lua);
				return false;
			}
			std::ostringstream os;
			os<<ifs.rdbuf();
			log_i(MODULE, "Loading %s into the Luanti environment",
					extra_lua);
			luanti::access(m_server, [&](luanti::Interface *i){
				i->load_lua(os.str(), extra_lua);
			});
		}
		return true;
	}

	// [WORLD_MODS] An imported world's choice of mods and its own
	// worldmods/ come with it, on its first start here
	void import_world_mods(const ss_ &import_from, storage::Save *save,
			network::PeerInfo::Id peer)
	{
		const ss_ wm = save->path()+"/luanti/worldmods";
		size_t done = 0;
		ss_ error;
		if(interface::fs::path_exists(import_from+"/worldmods") &&
				!interface::fs::path_exists(wm) &&
				!copy_tree(m_server, import_from+"/worldmods", wm, done, 0,
				peer, error))
			log_w(MODULE, "The world's mods: %s", cs(error));
		const ss_ mt_path = save->path()+"/luanti/world.mt";
		std::map<ss_, ss_> mine = read_world_mt(mt_path), set;
		for(const auto &kv : read_world_mt(import_from+"/world.mt"))
			if(kv.first.compare(0, 9, "load_mod_") == 0 &&
					!mine.count(kv.first))
				set[kv.first] = kv.second;
		if(!set.empty())
			write_world_mt(mt_path, set);
	}

	// The game run in the save, by builtin/luanti: what it is told before
	// the mods load, and what an import brings
	void run_game(const ss_ &game_path, storage::Save *save,
			const ss_ &import_from, network::PeerInfo::Id peer)
	{
		luanti::access(m_server, [&](luanti::Interface *i){
			// What the server is doing, to whoever is waiting for the world:
			// a game of 220 mods takes minutes, and "Creating <name>..."
			// left on the screen for that long looks hung. The handler runs
			// on this thread from inside run_game(), and a packet sent from
			// it reaches the client because network::send() writes to the
			// socket there and then.
			i->set_progress_handler([this, peer](const ss_ &line){
				if(peer == 0)
					return;
				const ss_ data = storage::pack(sv_<ss_>{line});
				network::send(m_server, peer, "main:progress", data);
			});
			// What the world is made out of goes in before it is made, and
			// so does the world itself: the map is read from inside
			// run_game(), between the game's nodes being registered and
			// the first section being asked for
			if(!import_from.empty()){
				i->import_world_settings(import_from, save);
				i->import_world(import_from);
			}
			// No singleplayer: its privileges are everyone's
			// ([VANILLA_PUBLIC] 3)
			if(m_public)
				i->load_lua("core.__public = true", "vanilla_public");
			// The mods world.mt's load_mod_ lines choose from ([WORLD_MODS])
			i->load_lua("core.__luanti_mods_path = [==["+mods_path(m_server)+
					"]==]", "vanilla_mods");
			m_game_settings.apply_default_preset(save->path());
			if(m_public)
				i->set_chat_limit(CHAT_BURST);
			interface::Server *server = m_server;
			i->set_chat_gate([server](size_t peer, const ss_ &name){
				return chat_refusal(server, peer, name);
			});
			luanti::Interface::Paths paths;
			paths.settings_file = luanti_path(m_server)+"/settings.json";
			paths.base_textures = luanti_path(m_server)+"/textures/base/pack";
			paths.texture_packs = luanti_path(m_server)+"/texture_packs";
			i->set_paths(paths);
			i->run_game(game_path, save);
		});
	}
};
// vim: set noet ts=4 sw=4:
