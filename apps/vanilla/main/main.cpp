// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Runs a Luanti world and extends nothing. Games and worlds are scanned from
// user_path/luanti, which is buildat's own directory on purpose: nothing here
// reads the content of a real Luanti install, and nothing here can write to
// one. buildat's own minimal game is bundled with the module, so there is
// something to run without one.
//
// For now it runs the first world it finds, or the one BUILDAT_LUANTI_WORLD
// names. The menu the plan describes is a milestone of its own; what this is
// today is the fixture the module is tested against.
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "luanti/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "client_file/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "accounts/api.h"
#include "chat/api.h"
#include "starport_announce/api.h"
#include <cstdlib>
#include <cctype>
#include <sys/stat.h>
#ifndef _WIN32
#include <dirent.h>
#endif
#include <ctime>
#include <map>
#include <fstream>
#include <cctype>
#include <utility>
#include <set>
#include <sstream>
#include <algorithm>
#include <random>
#include <functional>
#include <cmath>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
#include "interface/polyvox_cereal.h"
#include "core/sajson.h"
#include "interface/http.h"
#include "interface/zip.h"
#include "interface/thread.h"
#include "interface/os.h"
#include <atomic>
#ifndef _WIN32
#include <sys/stat.h>
#endif
#include <PolyVoxCore/Vector.h>
#define MODULE "main"

using interface::Event;

namespace pv = PolyVox;

#include "interface/polyvox_std.h"

namespace vanilla {

struct World
{
	ss_ name;
	ss_ path;
	ss_ gameid;
};

// The Module's parts ([VANILLA_MODULAR]), each holding what only it uses
#include "common.h"
#include "access.h"
#include "world_mods.h"
#include "contentdb.h"
#include "game_settings.h"
#include "importer.h"
#include "game_start.h"
#include "saves.h"

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server){}

	// The scene belongs to builtin/luanti -- it is what knows the world's
	// node ids and its light -- and arrives with luanti:game_loaded. A client
	// that connected while the mods were still loading waits here until it
	// does.
	luanti::SceneReference m_scene = nullptr;
	sv_<network::PeerInfo::Id> m_waiting_peers;
	std::set<network::PeerInfo::Id> m_shown_world;
	// The menu is a script of its own and is run once per peer, for the
	// same reason show_world_to() is: files_transmitted comes again after
	// every batch announced, and the ContentDB screen announces a
	// thumbnail at a time -- twenty-one runs of main/menu.lua in five
	// seconds, each asking for the saves again and drawing the whole menu
	// again over the one on the screen ([CONTENTDB_SCAN])
	std::set<network::PeerInfo::Id> m_shown_menu;
	// Which client took the name BUILDAT_LUANTI_NAME asked for, if any;
	// see player_name_of()
	network::PeerInfo::Id m_named_peer = 0;
	// A world runs once: what a second choice would be is a second Luanti
	// environment in one server, which is not what the module is
	bool m_starting = false;
	// [VANILLA_PUBLIC] 1: a server the launcher did not start is public. A
	// client joins through builtin/accounts first, the worlds and ContentDB
	// are an admin's, and the server's imports and settings nobody's.
	bool m_public = false;
	// The world running, or starting
	ss_ m_world_name;
	// The running world's save, for what it takes on disk ([SAVE_LIMIT])
	storage::Save *m_world_save = nullptr;
	// [VANILLA_PUBLIC] 5: a switch to another world, which is a restart
	// when this reaches zero: the time left, in seconds, or below 0 for none
	float m_restart_in = -1;
	// The exit status that asks util/serve_latest_release.sh to start the
	// server again at once
	static const int RESTART_STATUS = 20;
	// A public server's chat: per peer, how full the bucket is and when it
	// was last looked at (see on_chat)
	std::map<network::PeerInfo::Id, std::pair<double, int64_t>> m_chat_bucket;
	// Who has joined, by the account name their player has
	std::map<network::PeerInfo::Id, ss_> m_names;
	std::set<network::PeerInfo::Id> m_join_sent;
	// [VANILLA_MODULAR] access.h's
	Access m_access{m_server, m_public, m_names};
	// [VANILLA_MODULAR] world_mods.h's
	WorldMods m_world_mods{m_server, m_public, m_world_name, m_access};
	// [VANILLA_MODULAR] contentdb.h's
	ContentDB m_contentdb{m_server, m_access};
	// [VANILLA_MODULAR] game_settings.h's
	GameSettings m_game_settings{m_server, m_starting, m_public, m_world_name,
			m_access};
	// [VANILLA_MODULAR] importer.h's
	Importer m_importer{m_server, m_scene, m_starting, m_public, m_world_name,
			m_world_save, m_access,
			[this](const ss_ &gameid, const ss_ &world_name,
					network::PeerInfo::Id peer, const ss_ &from){
				m_start.start_world(gameid, world_name, peer, from);
			}};
	// [VANILLA_MODULAR] game_start.h's
	GameStart m_start{m_server, m_scene, m_starting, m_public, m_world_name,
			m_world_save, m_restart_in, m_names, m_access, m_contentdb,
			m_game_settings, m_importer};
	// [VANILLA_MODULAR] saves.h's
	Saves m_saves{m_server, m_scene, m_starting, m_public, m_world_name,
			m_world_save, m_names, m_access, m_contentdb, m_start};

	void init()
	{
		game_settings_self_check();
		m_game_settings.perf_self_check();
		interface::launch_param_self_check();
		sub(m_server, "core:start", &Module::on_start);
		sub(m_server, "core:tick", &Module::on_tick);
		sub(m_server, "luanti:game_loaded", &Module::on_game_loaded);
		sub(m_server, "client_file:files_transmitted",
				&Module::on_files_transmitted);
		sub<storage::OverLimit>(m_server, "storage:over_limit",
				[this](const storage::OverLimit &event){
			m_saves.on_over_limit(event);
		});
		sub<network::Packet>(m_server,
				"network:packet_received/launch:untrusted",
				on(m_start, &GameStart::on_launch_untrusted));
		sub(m_server, "accounts:login", &Module::on_accounts_login);
		sub(m_server, "accounts:privs", &Module::on_accounts_privs);
		sub(m_server, "network:client_disconnected",
				&Module::on_client_disconnected);
		// The launcher's and the game's own packets, "main:<name>", the
		// parts' and the Module's
		const std::pair<const char*,
				std::function<void(const network::Packet&)>> PACKETS[] = {
			{"get_saves", on(m_saves, &Saves::on_get_saves)},
			{"save_info", on(m_saves, &Saves::on_save_info)},
			{"set_world_flags", on(m_saves, &Saves::on_set_world_flags)},
			{"get_game_settings",
					on(m_game_settings, &GameSettings::on_get_game_settings)},
			{"set_game_settings",
					on(m_game_settings, &GameSettings::on_set_game_settings)},
			{"get_perf_settings",
					on(m_game_settings, &GameSettings::on_get_perf_settings)},
			{"set_perf_settings",
					on(m_game_settings, &GameSettings::on_set_perf_settings)},
			{"delete", on(m_saves, &Saves::on_delete)},
			{"trash_delete", on(m_saves, &Saves::on_trash_delete)},
			{"trash_restore", on(m_saves, &Saves::on_trash_restore)},
			{"rename", on(m_saves, &Saves::on_rename)},
			{"open", on(m_saves, &Saves::on_open)},
			{"create", on(m_saves, &Saves::on_create)},
			{"get_imports", on(m_importer, &Importer::on_get_imports)},
			{"get_settings",
					on(m_game_settings, &GameSettings::on_get_settings)},
			{"set_settings",
					on(m_game_settings, &GameSettings::on_set_settings)},
			{"contentdb_query",
					on(m_contentdb, &ContentDB::on_contentdb_query)},
			{"contentdb_install",
					on(m_contentdb, &ContentDB::on_contentdb_install)},
			{"get_world_mods", on(m_world_mods, &WorldMods::on_get_world_mods)},
			{"set_world_mods", on(m_world_mods, &WorldMods::on_set_world_mods)},
			{"remove_mod", on(m_world_mods, &WorldMods::on_remove_mod)},
			{"restart_world", on(*this, &Module::on_restart_world)},
			{"stop_world", on(*this, &Module::on_stop_world)},
			{"trim", on(m_saves, &Saves::on_trim)},
			{"export", on(m_importer, &Importer::on_export)},
			{"export_part", on(m_importer, &Importer::on_export_part)},
			{"import_begin", on(m_importer, &Importer::on_import_begin)},
			{"import_data", on(m_importer, &Importer::on_import_data)},
			{"import_mods_answer",
					on(m_importer, &Importer::on_import_mods_answer)},
			{"transfer_cancel", on(m_importer, &Importer::on_transfer_cancel)},
			{"get_world_txp", on(m_world_mods, &WorldMods::on_get_world_txp)},
			{"set_world_txp", on(m_world_mods, &WorldMods::on_set_world_txp)},
			{"remove_txp", on(m_world_mods, &WorldMods::on_remove_txp)},
			{"import_game", on(m_importer, &Importer::on_import_game)},
			{"import_world", on(m_importer, &Importer::on_import_world)},
			{"chat", on(*this, &Module::on_chat)},
		};
		for(const auto &packet : PACKETS)
			sub<network::Packet>(m_server,
					ss_("network:packet_received/main:")+packet.first,
					packet.second);
	}

	// The world to run, or the wait for one (game_start.h)
	void on_start()
	{
		m_start.on_start();
	}

	// A part's packet handler, as sub() takes one
	template<typename P>
	static std::function<void(const network::Packet&)> on(P &part,
			void (P::*handler)(const network::Packet&))
	{
		return [&part, handler](const network::Packet &p){
			(part.*handler)(p);
		};
	}

	// A Luanti player per client. The name is this game's to choose and the
	// client does not send one, so it is the peer's number: what it is for
	// is to be the key everything about the player hangs off, and a mod
	// that prints it gets something it can tell apart.
	//
	// The first client that connects is "singleplayer", the name Luanti's
	// own singleplayer always plays as: games written for one player look
	// it up by that name (citadel's get_player_by_name("singleplayer")),
	// and an imported singleplayer world's own player is that one -- where
	// they stood, what they carry. BUILDAT_LUANTI_NAME names them instead,
	// spelled the way extensions/luanti_client spells it. Only the first
	// client gets the name, because a name is one player and two clients
	// cannot both be them; the next to connect after they leave gets it.
	//
	// simplified: an environment variable is not how a player picks
	// themselves. The menu lists the saves and a save knows its players, so
	// choosing one there is the shape this ends up as.
	ss_ player_name_of(network::PeerInfo::Id peer)
	{
		// A public server's players are its accounts ([VANILLA_PUBLIC] 3),
		// and so are a LAN game's but the singleplayer ([GUEST_NAME_REUSE]:
		// "client<peer>" came again after a restart, with the earlier
		// player's save)
		if(m_public || !is_named(peer)){
			auto it = m_names.find(peer);
			return it != m_names.end() ? it->second : "client"+itos(peer);
		}
		return named_name();
	}
	ss_ named_name()
	{
		const char *name = getenv("BUILDAT_LUANTI_NAME");
		return name == nullptr || name[0] == '\0' ? "singleplayer" : name;
	}
	// The singleplayer is the launcher's own client (its owner token,
	// builtin/accounts); anyone else who reaches the game -- another user
	// on this machine, or the LAN once it is opened -- is an ordinary
	// player ([SECURITY_RUN_1]), in by the join's login
	bool is_named(network::PeerInfo::Id peer)
	{
		if(m_named_peer == 0 && is_owner(m_server, peer))
			m_named_peer = peer;
		return m_named_peer == peer;
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		m_shown_world.erase(old_client.info.id);
		m_shown_menu.erase(old_client.info.id);
		// The player is the module's to remove (its session)
		if(m_named_peer == old_client.info.id)
			m_named_peer = 0;
		m_names.erase(old_client.info.id);
		m_join_sent.erase(old_client.info.id);
		// A transfer cut off leaves nothing behind
		if(m_importer.m_transfer.peer == old_client.info.id){
			log_i(MODULE, "The transfer's client left; its files removed");
			m_importer.end_transfer();
		}
		m_chat_bucket.erase(old_client.info.id);
	}

	// Public mode ([VANILLA_PUBLIC])

	// In through the join: the world when there is one; else the world
	// menu for an admin, and for anyone else a wait until an admin has
	// chosen one
	void on_accounts_login(const accounts::Login &login)
	{
		if(!m_public){
			on_lan_login(login);
			return;
		}
		m_names[login.peer] = login.name;
		chat::access(m_server, [&](chat::Interface *i){
			i->join(login.peer, login.name);
		});
		if(m_scene){
			show_world_to(login.peer);
			return;
		}
		m_waiting_peers.push_back(login.peer);
		if(m_access.is_admin(login.peer)){
			m_shown_menu.insert(login.peer);
			network::send(m_server, login.peer, "core:run_script",
					"buildat.run_script_file(\"main/menu.lua\")");
			return;
		}
		const ss_ note = read_stop_note(m_server);
		sv_<ss_> values{note.empty() ? "No world is running on this server "
				"yet: an admin chooses one. You are in as soon as they have." :
				note+". No world is running: you are in as soon as an admin "
				"starts one."};
		const ss_ packed = storage::pack(values);
		network::send(m_server, login.peer, "main:join_wait", packed);
	}

	// [GUEST_NAME_REUSE] A LAN player's join: the world under their
	// account's name, never the singleplayer's
	void on_lan_login(const accounts::Login &login)
	{
		if(!m_join_sent.count(login.peer) || m_names.count(login.peer))
			return;
		auto lower = [](ss_ s){
			for(char &c : s)
				c = (char)tolower((unsigned char)c);
			return s;
		};
		if(lower(login.name) == lower(named_name())){
			log_i(MODULE, "%s: the singleplayer's name, held", cs(login.name));
			const ss_ packed = storage::pack(sv_<ss_>{login.name+
					" is this game's own player: join with another account"});
			network::send(m_server, login.peer, "main:join_wait", packed);
			return;
		}
		m_names[login.peer] = login.name;
		if(m_scene){
			show_world_to(login.peer);
			return;
		}
		m_waiting_peers.push_back(login.peer);
		const ss_ packed = storage::pack(sv_<ss_>{"No world is running yet: "
				"you are in as soon as the host starts one."});
		network::send(m_server, login.peer, "main:join_wait", packed);
	}

	// What the client shows of the server's: whether it is a public one,
	// whether its user is an admin, the world running, and whether its user
	// is the launcher's own -- the pause menu's pages; and the world's
	// game id, for the client's Discuss ([OVERLAY_DISCUSS])
	void send_account(network::PeerInfo::Id peer)
	{
		bool is_local = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			is_local = i->is_local(peer);
		});
		sv_<ss_> values{m_public ? "1" : "0",
				m_access.is_admin(peer) ? "1" : "0",
				m_world_name, is_local ? "1" : "0", m_world_name.empty() ? "" :
				gameid_of_save(m_server, m_world_name)};
		const ss_ packed = storage::pack(values);
		network::send(m_server, peer, "main:account", packed);
	}

	// A server admin has every privilege in the world ([VANILLA_PUBLIC] 3)
	void on_accounts_privs(const accounts::Login &login)
	{
		send_account(login.peer);
		if(!m_public || !m_scene)
			return;
		const bool admin = m_access.is_admin(login.peer);
		luanti::access(m_server, [&](luanti::Interface *i){
			if(i->player_in_world(login.peer))
				i->set_admin(login.name, admin);
		});
	}

	// The loading screen's picture ([LOADING_SCREEN]): one of the running
	// game's menu/background.png and background.<n>.png, at random each
	// join, its name and bytes; none for a game without one. Sent behind
	// the script and ahead of the world, so that it is there from the start
	void send_loading_picture(network::PeerInfo::Id peer)
	{
		const ss_ game_path = find_game(m_server,
				gameid_of_save(m_server, m_world_name));
		const ss_ dir = game_path+"/menu";
		sv_<ss_> names;
		for(const auto &n : game_path.empty() ? sv_<interface::fs::Node>() :
				interface::fs::list_directory(dir)){
			if(!n.is_directory && n.name.compare(0, 10, "background") == 0 &&
					n.name.size() >= 14 &&
					n.name.compare(n.name.size() - 4, 4, ".png") == 0)
				names.push_back(n.name);
		}
		sv_<ss_> values;
		if(!names.empty()){
			std::sort(names.begin(), names.end());
			const ss_ name = names[std::random_device()() % names.size()];
			std::ifstream f(dir+"/"+name, std::ios::binary);
			std::ostringstream data;
			data << f.rdbuf();
			if(f.is_open() && !data.str().empty())
				values = {name, data.str()};
			log_i(MODULE, "loading picture: %s of %zu (%zu bytes)", cs(name),
					names.size(), values.empty() ? 0 : values[1].size());
		}
		const ss_ packed = storage::pack(values);
		network::send(m_server, peer, "luanti:loading_picture", packed);
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(m_restart_in >= 0){
			m_restart_in -= event.dtime;
			if(m_restart_in < 0){
				// The goodbye then says it restarts, and the clients wait
				// it out and join again (builtin/network's on_shutdown)
				std::ofstream(m_server->get_config().get<ss_>("user_path")+
						"/apps/"+m_server->get_app_id()+"/shutdown_reason")<<
						"the world changes\n";
				m_server->shutdown(RESTART_STATUS, "switching the world");
			}
		}
		m_contentdb.poll_contentdb();
	}

	// [VANILLA_STOP] A line a held player typed with no world running: to
	// everyone in, as Luanti says one. In a world chat is the module's
	// (luanti:chat), its limit set_chat_limit()'s.
	void on_chat(const network::Packet &packet)
	{
		if(!(m_public && !m_scene && m_names.count(packet.sender)))
			return;
		sv_<ss_> values;
		if(!storage::unpack(packet.data, values)){
			log_w(MODULE, "main:chat: could not be read");
			return;
		}
		if(values.empty() || values[0].empty())
			return;
		const ss_ &message = values[0];
		// [VANILLA_CHAT_MIN] builtin/chat says who may talk
		const ss_ why = chat_refusal(m_server, packet.sender,
				player_name_of(packet.sender));
		if(!why.empty()){
			const ss_ packed = storage::pack(sv_<ss_>{"("+why+")"});
			log_i(MODULE, "%s's line refused: %s",
					cs(player_name_of(packet.sender)), cs(why));
			network::send(m_server, packet.sender, "main:chat_line", packed);
			return;
		}
		// **A public server's chat is limited** ([VANILLA_PUBLIC] 8): a
		// player's lines fill a bucket that empties one a second, and a
		// line into a full one is refused
		const int64_t now = interface::os::time_us();
		auto &b = m_chat_bucket[packet.sender];
		b.first = std::max(0.0, b.first - (now - b.second) / 1e6);
		b.second = now;
		if(b.first + 1 > CHAT_BURST)
			return;
		b.first += 1;
		const ss_ packed = storage::pack(sv_<ss_>{"<"+player_name_of(packet.sender)+"> "+message});
		network::access(m_server, [&](network::Interface *inetwork){
			for(const auto &kv : m_names)
				inetwork->send(kv.first, "main:chat_line", packed);
		});
	}

	void on_game_loaded(const luanti::GameLoaded &event)
	{
		m_scene = event.scene;
		log_i(MODULE, "The world is up");
		for(network::PeerInfo::Id peer : m_waiting_peers)
			show_world_to(peer);
		m_waiting_peers.clear();
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		// A public server's client joins first ([VANILLA_PUBLIC] 2), as
		// does a LAN game's but the singleplayer ([GUEST_NAME_REUSE]), and
		// what it is shown after is on_accounts_login's
		if((m_public || !is_named(event.recipient)) &&
				!m_names.count(event.recipient)){
			if(m_join_sent.insert(event.recipient).second){
				// The join's title is the Luanti game running, which the
				// script waits for; "" before an admin has chosen a world
				ss_ title;
				if(!m_world_name.empty()){
					const ss_ gameid = gameid_of_save(m_server, m_world_name);
					const ss_ game_path = find_game(m_server, gameid);
					title = game_path.empty() ? gameid :
							read_game_title(game_path);
				}
				const ss_ packed = storage::pack(sv_<ss_>{title});
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(event.recipient, "core:run_script",
							"buildat.run_script_file(\"main/join.lua\")");
					inetwork->send(event.recipient, "main:join_title",
							packed);
				});
			}
			return;
		}
		if(!m_scene){
			// Waiting for an admin, or the host, to choose a world
			if(m_public ? !m_access.is_admin(event.recipient) :
					!is_named(event.recipient))
				return;
			if(!m_shown_menu.insert(event.recipient).second)
				return;
			m_waiting_peers.push_back(event.recipient);
			// Nothing to look at yet, so what the client draws is the menu:
			// which save, and which game it needs. A world that was chosen
			// before this client arrived is already on its way up, and the
			// menu says so rather than offering another.
			network::send(m_server, event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/menu.lua\")");
			return;
		}
		show_world_to(event.recipient);
	}

	//
	// Importing a game and a world from a real Luanti installation
	//
	// Nothing here writes to any of those directories: they are read, and a
	// game is copied out of one into buildat's own. See "The importer" in
	// doc/plan/master_plan.md.
	//

	// main:restart_world {save}: the running world of a public server
	// started again, as switch_world() does another
	// simplified: a launcher's own game is left and played again; a
	// restart of its process waits for [VANILLA_STOP]
	void on_restart_world(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.empty() || !m_public || values[0] != m_world_name)
			return;
		log_i(MODULE, "%s restarts the world %s", cs(m_names[packet.sender]),
				cs(m_world_name));
		if(m_scene){
			luanti::access(m_server, [&](luanti::Interface *i){
				i->chat_send("", m_names[packet.sender]+" restarts the "
						"server's world: back in a moment");
			});
		}
		m_restart_in = 1.5f;
	}
	// [VANILLA_STOP] main:stop_world: a public server's world stopped by
	// an admin. Everyone told, the world saved by the restart that leaves
	// the server with none, as at a first boot; an admin starts one
	// from the world menu, and the users are held until then.
	// simplified: no world loaded for maintenance while stopped (the trim
	// works on the running world); a launcher's own game is left instead
	void on_stop_world(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender) || !m_public || !m_scene)
			return;
		const ss_ who = m_names[packet.sender];
		log_i(MODULE, "%s stops the world %s", cs(who), cs(m_world_name));
		luanti::access(m_server, [&](luanti::Interface *i){
			i->chat_send("", who+" stops the server's world");
		});
		write_public_world(m_server, "", "Stopped by an admin ("+who+")");
		m_restart_in = 1.5f;
	}

	void show_world_to(network::PeerInfo::Id peer)
	{
		// Once per peer: files_transmitted comes again after every batch
		// of files announced (the game's media, once the world is up),
		// and a second showing initialised the peer's world twice
		// ("on_ready(): already ready", [FIRST_RUN])
		if(!m_shown_world.insert(peer).second)
			return;
		network::access(m_server, [&](network::Interface *inetwork){
			// The menu takes itself away first: it is a script of its own
			// and has no other way of knowing that it is done with. One
			// that came straight into a running world has none, and the
			// packet, held for a subscriber, would close the one the pause
			// menu's Worlds... opens later ([PAUSE_WORLDS_LOCAL])
			if(m_shown_menu.count(peer))
				inetwork->send(peer, "main:menu_done", "");
			inetwork->send(peer, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
		send_loading_picture(peer);
		// The player before the scene: the placement goes out ordered
		// behind the script that subscribes to it ([PLAYER_POS_RACE]), and
		// the scene brings voxelworld's registry, megabytes that over a
		// slow link held the placement -- and the client's input -- for
		// minutes ([NET_SIM]'s link cell)
		send_account(peer);
		// Placed only: in the world once the client has it loaded
		// ([JOIN_WHEN_LOADED]); the player is the module's from here
		const bool admin = m_public && m_access.is_admin(peer);
		luanti::access(m_server, [&](luanti::Interface *i){
			i->join_player(player_name_of(peer), peer, admin);
		});
		// A public server's player is in the chat from the join
		// (on_accounts_login)
		if(!m_public)
			chat::access(m_server, [&](chat::Interface *i){
				i->join(peer, player_name_of(peer));
			});
		replicate::assign_scene_to_peer(m_server, m_scene, peer);
	}

};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
