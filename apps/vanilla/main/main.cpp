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
	// The launch param's save is opened by the first main:get_saves packet
	// and by no later one: vanilla's client sends that packet more than
	// once, and a repeat is not a user asking twice
	bool m_launched_param_save = false;
	// The launch the owner's client last sent (launch:untrusted), which
	// stands for -u from then on: the launcher keeps a server that holds
	// no world and hands it the next launch of this app over the
	// connection rather than starting another
	ss_ m_launch;
	bool m_launch_sent = false;
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
				start_world(gameid, world_name, peer, from);
			}};

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
		sub(m_server, "storage:over_limit", &Module::on_over_limit);
		sub(m_server, "network:packet_received/launch:untrusted",
				&Module::on_launch_untrusted);
		sub(m_server, "accounts:login", &Module::on_accounts_login);
		sub(m_server, "accounts:privs", &Module::on_accounts_privs);
		sub(m_server, "network:client_disconnected",
				&Module::on_client_disconnected);
		// The launcher's and the game's own packets, "main:<name>", the
		// parts' and the Module's
		const std::pair<const char*,
				std::function<void(const network::Packet&)>> PACKETS[] = {
			{"get_saves", on(*this, &Module::on_get_saves)},
			{"save_info", on(*this, &Module::on_save_info)},
			{"set_world_flags", on(*this, &Module::on_set_world_flags)},
			{"get_game_settings",
					on(m_game_settings, &GameSettings::on_get_game_settings)},
			{"set_game_settings",
					on(m_game_settings, &GameSettings::on_set_game_settings)},
			{"get_perf_settings",
					on(m_game_settings, &GameSettings::on_get_perf_settings)},
			{"set_perf_settings",
					on(m_game_settings, &GameSettings::on_set_perf_settings)},
			{"delete", on(*this, &Module::on_delete)},
			{"rename", on(*this, &Module::on_rename)},
			{"open", on(*this, &Module::on_open)},
			{"create", on(*this, &Module::on_create)},
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
			{"trim", on(*this, &Module::on_trim)},
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
		// A public server's players are its accounts ([VANILLA_PUBLIC] 3)
		if(m_public){
			auto it = m_names.find(peer);
			return it != m_names.end() ? it->second : "client"+itos(peer);
		}
		const char *name = getenv("BUILDAT_LUANTI_NAME");
		if(name == nullptr || name[0] == '\0')
			name = "singleplayer";
		// The singleplayer is the launcher's own client (its owner token,
		// builtin/accounts); anyone else who reaches the game -- another
		// user on this machine, or the LAN once it is opened -- is an
		// ordinary player ([SECURITY_RUN_1])
		if(m_named_peer == 0 && is_owner(m_server, peer))
			m_named_peer = peer;
		if(m_named_peer != peer)
			return "client"+itos(peer);
		return name;
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

	// In through the join: the world when there is one; else the world
	// menu for an admin, and for anyone else a wait until an admin has
	// chosen one
	void on_accounts_login(const accounts::Login &login)
	{
		if(!m_public)
			return;
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
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::send(m_server, login.peer, "main:join_wait", os.str());
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
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::send(m_server, peer, "main:account", os.str());
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
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::send(m_server, peer, "luanti:loading_picture", os.str());
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
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:chat: %s", e.what());
			return;
		}
		if(values.empty() || values[0].empty())
			return;
		const ss_ &message = values[0];
		// [VANILLA_CHAT_MIN] builtin/chat says who may talk
		const ss_ why = chat_refusal(m_server, packet.sender,
				player_name_of(packet.sender));
		if(!why.empty()){
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar(sv_<ss_>{"("+why+")"});
			}
			log_i(MODULE, "%s's line refused: %s",
					cs(player_name_of(packet.sender)), cs(why));
			network::send(m_server, packet.sender, "main:chat_line", os.str());
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
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(sv_<ss_>{"<"+player_name_of(packet.sender)+"> "+message});
		}
		network::access(m_server, [&](network::Interface *inetwork){
			for(const auto &kv : m_names)
				inetwork->send(kv.first, "main:chat_line", os.str());
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
		// A public server's client joins first ([VANILLA_PUBLIC] 2), and
		// what it is shown after is on_accounts_login's
		if(m_public && !m_names.count(event.recipient)){
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
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar(sv_<ss_>{title});
				}
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(event.recipient, "core:run_script",
							"buildat.run_script_file(\"main/join.lua\")");
					inetwork->send(event.recipient, "main:join_title",
							os.str());
				});
			}
			return;
		}
		if(!m_scene){
			// Waiting for an admin to choose a world
			if(m_public && !m_access.is_admin(event.recipient))
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

	void on_get_saves(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		// Holding no world, the launcher may keep this server for its
		// next launch of the app (start_world() takes it back)
		if(!m_public && !m_starting && is_owner(m_server, packet.sender)){
			network::send(m_server, packet.sender, "launch:reusable", "1");
		}
		// **A launch that named a save opens it and never draws a menu**
		// ([LAUNCH_WORLD]: a save opened through ctx.launch's params).
		// The launcher hands "save=<name>" to the server's -u, which is
		// the same door "menu" and "luanti_game" come through, and the
		// save says itself which game it needs.
		{
			ss_ save = launch_param("save");
			// [PAUSE_WORLDS_LOCAL] One from a player in the world is the
			// pause menu's Worlds..., which lists them
			bool in_world = false;
			if(m_scene){
				luanti::access(m_server, [&](luanti::Interface *i){
					in_world = i->player_in_world(packet.sender);
				});
			}
			if(save != "" && m_launched_param_save && !in_world)
				return;
			if(save != "" && !m_launched_param_save){
				ss_ gameid = gameid_of_save(m_server, save);
				if(gameid == ""){
					log_w(MODULE, "untrusted_launch: save %s does not say"
							" which game it needs", cs(save));
				} else {
					log_i(MODULE, "untrusted_launch: opening save %s",
							cs(save));
					m_launched_param_save = true;
					start_world(gameid, save, packet.sender, "", true);
					return;
				}
			}
		}
		// A launch that asked for one of the menu's screens -- import_game,
		// import_world -- says so before the lists, and the client opens
		// that screen over them ([LAUNCH_GRID])
		{
			ss_ menu = launch_param("menu");
			if(menu == "worlds"){
				ss_ game = launch_param("luanti_game");
				// One world's options, from a launcher's menu on its save
				// ([SAVE_CONTEXT_MENU])
				ss_ world = launch_param("world");
				if(game != "")
					menu += ":"+game;
				else if(is_world_name(world))
					menu = "world:"+world;
			}
			if(menu != ""){
				network::send(m_server, packet.sender, "main:menu", menu);
			}
		}
		// A public server's menu has no imports and no local settings, and
		// over a running world it goes back to it ([VANILLA_PUBLIC] 5)
		if(m_public){
			const ss_ menu = m_starting ? "public_running" : "public";
			network::send(m_server, packet.sender, "main:menu", menu);
		}
		sv_<ss_> flat;
		sv_<ss_> saves;
		sv_<ss_> sizes;
		// [DISK_LIMIT_SHOWN] What the app has written against
		// --max-disk-mb, for the line under the list: used, limit (0 for
		// none), saves, shared, cache, in bytes
		sv_<ss_> disk;
		storage::access(m_server, [&](storage::Interface *istorage){
			const storage::Usage u = istorage->usage();
			for(int64_t v : {u.total(), istorage->limit_bytes(), u.saves,
					u.shared, u.cache})
				disk.push_back(itos(v));
			sv_<storage::SaveInfo> infos = istorage->list();
			// The one played last is the one most likely wanted next
			std::sort(infos.begin(), infos.end(),
					[](const storage::SaveInfo &a, const storage::SaveInfo &b){
				return a.modified_us > b.modified_us;
			});
			// _server is builtin/accounts', and _ is not a world's
			for(const storage::SaveInfo &info : infos)
				if(!info.name.empty() && info.name[0] != '_'){
					saves.push_back(info.name);
					sizes.push_back(itos(info.bytes));
				}
		});
		flat.push_back(itos(saves.size()));
		for(size_t i = 0; i < saves.size(); i++){
			flat.push_back(saves[i]);
			flat.push_back(gameid_of_save(m_server, saves[i]));
			flat.push_back(sizes[i]);
		}
		for(const ss_ &id : list_apps(m_server))
			flat.push_back(id);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		// Each game's mapgens for the new-world screen, ahead of the lists
		// that screen is reached from: [gameid, "v7,v5,...", ...]
		sv_<ss_> mapgens;
		for(const ss_ &id : list_apps(m_server)){
			const ss_ game_path = find_game(m_server, id);
			if(game_path.empty())
				continue;
			ss_ joined;
			for(const ss_ &m : game_mapgens(game_path))
				joined += (joined.empty() ? "" : ",")+m;
			mapgens.push_back(id);
			mapgens.push_back(joined);
		}
		std::ostringstream mos(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(mos);
			ar(mapgens);
		}
		std::ostringstream dos(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(dos);
			ar(disk);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "main:game_mapgens", mos.str());
			inetwork->send(packet.sender, "main:disk", dos.str());
			// [WORLDS_SELECTED] The world running, "" for none: the menu
			// selects it
			inetwork->send(packet.sender, "main:running_world",
					m_starting ? m_world_name : ss_());
			inetwork->send(packet.sender, "main:saves", os.str());
		});
	}

	// storage:over_limit: the downloads in the cache first, then the running
	// world forgets land by its world.mt's settings, down to 90% of the
	// limit less everything else the app has written. A world not running
	// is not trimmed: deleting a world or a game is the admin's way out.
	void on_over_limit(const storage::OverLimit &event)
	{
		const ss_ cache = m_server->get_config().get<ss_>("cache_path")+
				"/luanti/contentdb";
		if(m_contentdb.m_contentdb_jobs.empty()){
			for(const auto &n : interface::fs::list_directory(cache)){
				const ss_ &f = n.name;
				if(!n.is_directory && f.size() > 4 &&
						f.compare(f.size() - 4, 4, ".zip") == 0)
					interface::fs::remove_all(cache+"/"+f);
			}
		}
		if(!m_scene || !m_world_save)
			return;
		const std::map<ss_, ss_> mt =
				read_world_mt(m_world_save->path()+"/luanti/world.mt");
		auto it = mt.find("buildat_forget_unchanged");
		if(it != mt.end() && it->second == "false")
			return;
		it = mt.find("buildat_forget_builds_days");
		const int days = it == mt.end() ? 0 : atoi(it->second.c_str());
		const int64_t own = m_world_save->bytes();
		const int64_t target = event.limit / 10 * 9 -
				(event.usage.total() - own);
		size_t n = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			n = w->trim_to(std::max<int64_t>(target, 0), days > 0 ? days : -1);
		});
		log_i(MODULE, "trimmed: %zu sections of %s forgotten, %lld kB of "
				"%lld kB written", n, cs(m_world_name),
				(long long)(event.usage.total() / 1024),
				(long long)(event.limit / 1024));
	}

	// [WORLD_TRIM_MOVE] 2: trimming the running world from the world menu.
	// main:trim {save, verb, ...}: "info"; "ask" or "do", then "size" and
	// the target in MB, or "box", two corners' x y z and "1" to take the
	// player builds outside too. "ask" answers main:trim_ask {save, what
	// would go, then the request again}; "info" and "do" main:trim_info
	// {save, note, bytes, sections, altered, the default box's six}.
	// simplified: the running world alone (a save no game has open would
	// want voxelworld without a scene); the size's order is the furthest
	// from the origin first, picked here rather than by trim_to()
	struct TrimPick {
		sv_<pv::Vector3DInt16> list;
		int64_t bytes = 0;
		size_t altered = 0, loaded = 0;
	};
	static TrimPick trim_pick(const sv_<voxelworld::SectionStat> &stats,
			const pv::Vector3DInt16 &size, const sv_<ss_> &req,
			int64_t have)
	{
		TrimPick out;
		set_<uint64_t> altered;
		auto key = [](int x, int y, int z){
			return ((uint64_t)(uint16_t)x << 32) | ((uint64_t)(uint16_t)y << 16) |
					(uint64_t)(uint16_t)z;
		};
		for(const auto &st : stats)
			if(st.altered)
				altered.insert(key(st.p.getX(), st.p.getY(), st.p.getZ()));
		auto near_altered = [&](const pv::Vector3DInt16 &p){
			for(int dz = -1; dz <= 1; dz++)
			for(int dy = -1; dy <= 1; dy++)
			for(int dx = -1; dx <= 1; dx++)
				if(altered.count(key(p.getX() + dx, p.getY() + dy, p.getZ() + dz)))
					return true;
			return false;
		};
		if(req.size() >= 2 && req[0] == "size"){
			const int64_t target = (int64_t)(atof(req[1].c_str()) * 1000000);
			sv_<const voxelworld::SectionStat*> c;
			for(const auto &st : stats){
				if(!st.generated || st.altered || near_altered(st.p))
					continue;
				if(st.loaded){
					out.loaded++;
					continue;
				}
				c.push_back(&st);
			}
			auto d2 = [&](const voxelworld::SectionStat *st){
				const double x = (st->p.getX() + 0.5) * size.getX(),
						y = (st->p.getY() + 0.5) * size.getY(),
						z = (st->p.getZ() + 0.5) * size.getZ();
				return x * x + y * y + z * z;
			};
			std::sort(c.begin(), c.end(), [&](const voxelworld::SectionStat *a,
					const voxelworld::SectionStat *b){ return d2(a) > d2(b); });
			for(const auto *st : c){
				if(have - out.bytes <= target)
					break;
				out.list.push_back(st->p);
				out.bytes += st->bytes;
			}
		} else if(req.size() >= 8 && req[0] == "box"){
			int b[6];
			for(int i = 0; i < 6; i++)
				b[i] = atoi(req[1 + i].c_str());
			const bool builds = req[7] == "1";
			for(const auto &st : stats){
				bool inside = true;
				for(int a = 0; a < 3; a++){
					const int s0 = (a == 0 ? st.p.getX() : a == 1 ? st.p.getY() :
							st.p.getZ()) * (a == 0 ? size.getX() : a == 1 ?
							size.getY() : size.getZ());
					const int s1 = s0 + (a == 0 ? size.getX() : a == 1 ?
							size.getY() : size.getZ()) - 1;
					if(s1 < std::min(b[a], b[a + 3]) || s0 > std::max(b[a], b[a + 3]))
						inside = false;
				}
				if(inside || !st.generated || (st.altered && !builds))
					continue;
				if(st.loaded){
					out.loaded++;
					continue;
				}
				out.list.push_back(st.p);
				out.bytes += st.bytes;
				if(st.altered)
					out.altered++;
			}
		}
		return out;
	}
	void send_trim_info(network::PeerInfo::Id peer, const ss_ &save,
			const ss_ &note)
	{
		if(!m_scene || !m_world_save || save != m_world_name){
			send_strings(m_server, peer, "main:trim_info", {save,
					"Trimming works on the world running: start "+save+
					" first."});
			return;
		}
		sv_<voxelworld::SectionStat> stats;
		pv::Vector3DInt16 size(16, 16, 16);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			stats = w->section_stats();
			size = w->get_section_size_voxels();
		});
		// The default box: every altered section and one section round it
		int lo[3] = {0, 0, 0}, hi[3] = {0, 0, 0};
		size_t altered = 0;
		for(const auto &st : stats){
			if(!st.altered)
				continue;
			const int p[3] = {st.p.getX(), st.p.getY(), st.p.getZ()};
			for(int a = 0; a < 3; a++){
				lo[a] = altered == 0 ? p[a] : std::min(lo[a], p[a]);
				hi[a] = altered == 0 ? p[a] : std::max(hi[a], p[a]);
			}
			altered++;
		}
		const int sz[3] = {size.getX(), size.getY(), size.getZ()};
		sv_<ss_> flat{save, note, itos(m_world_save->bytes()),
				itos(stats.size()), itos(altered)};
		for(int a = 0; a < 3; a++)
			flat.push_back(itos((lo[a] - 1) * sz[a]));
		for(int a = 0; a < 3; a++)
			flat.push_back(itos((hi[a] + 2) * sz[a] - 1));
		send_strings(m_server, peer, "main:trim_info", flat);
	}
	void on_trim(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.size() < 2)
			return;
		const ss_ &save = values[0], &verb = values[1];
		if(verb == "info" || !m_scene || !m_world_save || save != m_world_name)
			return send_trim_info(packet.sender, save, "");
		const sv_<ss_> req(values.begin() + 2, values.end());
		const int64_t have = m_world_save->bytes();
		TrimPick pick;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			pick = trim_pick(w->section_stats(), w->get_section_size_voxels(),
					req, have);
		});
		const ss_ skipped = pick.loaded == 0 ? ss_() : " "+itos(pick.loaded)+
				" loaded for players are kept.";
		if(verb == "ask"){
			sv_<ss_> flat{save, pick.list.empty() ? "Nothing to forget."+
					skipped : itos(pick.list.size())+" sections would be "
					"forgotten, about "+mb_text(pick.bytes)+(pick.altered ?
					", "+itos(pick.altered)+" of them with player builds" :
					ss_())+"; generated again if visited."+skipped};
			flat.insert(flat.end(), req.begin(), req.end());
			send_strings(m_server, packet.sender, "main:trim_ask", flat);
			return;
		}
		if(verb != "do")
			return;
		size_t n = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			n = w->forget_sections(pick.list);
		});
		const int64_t t0 = interface::os::time_us();
		const ss_ err = m_world_save->compact();
		const int64_t after = m_world_save->bytes();
		log_i(MODULE, "%s trims %s: %zu sections forgotten, %lld kB to %lld kB, "
				"compacted in %d ms%s", cs(m_names[packet.sender].empty() ?
				ss_("the owner") : m_names[packet.sender]), cs(save), n,
				(long long)(have / 1024), (long long)(after / 1024),
				(int)((interface::os::time_us() - t0) / 1000),
				err.empty() ? "" : cs(": "+err));
		send_trim_info(packet.sender, save, itos(n)+" sections forgotten; "+
				mb_text(have)+" to "+mb_text(after)+"."+skipped+(err.empty() ?
				ss_() : " Not compacted: "+err));
	}

	// main:save_info <name>: what a save answers at a glance, as a flat
	// list of key, value pairs ([WORLD_LIST]) -- one open, a few keys, one
	// count. The section count is voxelworld's "main/s<x>,<y>,<z>/generated"
	// keys; the size the directory's.
	void on_save_info(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:save_info: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		const ss_ name = values[0];
		if(!is_world_name(name))
			return;
		sv_<ss_> flat{"name", name};
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(name);
			if(!save)
				return;
			ss_ gameid, seed, mg_name, clock, created;
			save->store("main")->get("gameid", gameid);
			save->store("main")->get("created", created);
			storage::Store *lu = save->store("luanti");
			lu->get("seed", seed);
			lu->get("mg_name", mg_name);
			lu->get("clock", clock);
			const size_t sections =
					save->store("voxelworld")->list("main/s").size();
			const ss_ path = save->path();
			istorage->close(save);
			flat.push_back("game"); flat.push_back(gameid);
			const ss_ game_path = find_game(m_server, gameid);
			flat.push_back("title");
			flat.push_back(game_path.empty() ? gameid : read_game_title(game_path));
			flat.push_back("seed"); flat.push_back(seed);
			flat.push_back("mapgen"); flat.push_back(mg_name);
			if(clock.size() > 1){
				try {
					std::istringstream is(clock, std::ios::binary);
					cereal::PortableBinaryInputArchive ar(is);
					uint8_t version = 0; double tod = 0, gt = 0; int32_t days = 0;
					ar(version, tod, gt, days);
					flat.push_back("day"); flat.push_back(itos(days));
					char buf[16];
					snprintf(buf, sizeof buf, "%02d:%02d", (int)(tod * 24) % 24,
							(int)(tod * 24 * 60) % 60);
					flat.push_back("time"); flat.push_back(buf);
					// As text: the sandbox has no os.date and no clock
					char played[32];
					if(gt >= 3600)
						snprintf(played, sizeof played, "%.1f h", gt / 3600);
					else
						snprintf(played, sizeof played, "%d min", (int)(gt / 60));
					flat.push_back("played"); flat.push_back(played);
				} catch(std::exception &){}
			}
			flat.push_back("sections"); flat.push_back(itos((int64_t)sections));
			flat.push_back("bytes");
			flat.push_back(itos((int64_t)interface::fs::directory_tree_size(path)));
			struct stat st;
			auto date_of = [](time_t t){
				char buf[32];
				strftime(buf, sizeof buf, "%Y-%m-%d %H:%M", localtime(&t));
				return ss_(buf);
			};
			if(stat((path+"/save.sqlite").c_str(), &st) == 0){
				flat.push_back("played_at"); flat.push_back(date_of(st.st_mtime));
			}
			// The save's own "created" from on_create; a save from before
			// it has the oldest of its files' times, which a rewritten
			// world.mt or database moves (a directory's ctime is its last
			// change on Linux, not its birth)
			if(!created.empty()){
				flat.push_back("created_at");
				flat.push_back(date_of((time_t)atoll(created.c_str())));
			} else if(stat((path+"/save.sqlite").c_str(), &st) == 0){
				time_t oldest = st.st_ctime;
				for(const interface::fs::Node &n :
						interface::fs::list_directory(path)){
					struct stat s2;
					if(stat((path+"/"+n.name).c_str(), &s2) == 0 &&
							s2.st_mtime < oldest)
						oldest = s2.st_mtime;
				}
				flat.push_back("created_at"); flat.push_back(date_of(oldest));
			}
			const std::map<ss_, ss_> mt = read_world_mt(path+"/luanti/world.mt");
			auto flag = [&](const char *key, const char *dflt){
				auto it = mt.find(key);
				flat.push_back(key);
				flat.push_back(it == mt.end() ? ss_(dflt) : it->second);
			};
			flag("creative_mode", "false");
			flag("enable_damage", "true");
		});
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::send(m_server, packet.sender, "main:save_info", os.str());
	}

	// main:set_world_flags <name> <creative_mode> <enable_damage>: into the
	// save's world.mt, which core.settings reads when the world loads
	void on_set_world_flags(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:set_world_flags: %s", e.what());
			return;
		}
		if(values.size() < 3 || !is_world_name(values[0]))
			return;
		ss_ path;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(values[0]);
			if(save){
				path = save->path();
				istorage->close(save);
			}
		});
		if(path.empty())
			return;
		std::map<ss_, ss_> set;
		set["creative_mode"] = values[1] == "true" ? "true" : "false";
		set["enable_damage"] = values[2] == "true" ? "true" : "false";
		write_world_mt(path+"/luanti/world.mt", set);
		log_i(MODULE, "%s: creative_mode %s, enable_damage %s", cs(values[0]),
				cs(set["creative_mode"]), cs(set["enable_damage"]));
		on_save_info(packet); // the panel re-reads
	}

	// main:delete <name>: the save's directory moved to saves/trash/<name>-
	// <date>, not removed; the list is sent again
	void on_delete(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:delete: %s", e.what());
			return;
		}
		if(values.empty() || !is_world_name(values[0]))
			return;
		if(m_starting && values[0] == m_world_name){
			menu_error(m_server, packet.sender,
					"The world that is running is not "
					"deleted");
			return;
		}
		ss_ path;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(values[0]);
			if(save){
				path = save->path();
				istorage->close(save);
			}
		});
		if(path.empty()){
			menu_error(m_server, packet.sender,
					"There is no save called "+values[0]);
			return;
		}
		const ss_ trash = interface::fs::strip_file_name(path)+"/trash";
		interface::fs::create_directories(trash);
		time_t now = time(NULL);
		char date[32];
		strftime(date, sizeof date, "%Y-%m-%d_%H%M%S", localtime(&now));
		const ss_ to = trash+"/"+values[0]+"-"+date;
		if(rename(path.c_str(), to.c_str()) != 0){
			menu_error(m_server, packet.sender,
					"Could not move "+m_access.where(path)+" to "+
					m_access.where(to));
			return;
		}
		log_i(MODULE, "Save %s moved to %s", cs(values[0]), cs(to));
		menu_message(m_server, packet.sender, values[0]+" moved to the trash");
	}

	// [WORLD_MENU] [name, to]
	void on_rename(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:rename: %s", e.what());
			return;
		}
		if(values.size() != 2 || !is_world_name(values[0]) ||
				!is_world_name(values[1]))
			return;
		if(m_starting && values[0] == m_world_name){
			menu_error(m_server, packet.sender,
					"The world that is running is not "
					"renamed");
			return;
		}
		bool ok = false;
		storage::access(m_server, [&](storage::Interface *istorage){
			ok = istorage->rename(values[0], values[1]);
		});
		if(!ok){
			menu_error(m_server, packet.sender, values[0]+" was not renamed: "
					"is there a save called "+values[1]+" already?");
			return;
		}
		log_i(MODULE, "Save %s renamed %s", cs(values[0]), cs(values[1]));
		menu_message(m_server, packet.sender, values[0]+" renamed "+values[1]);
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

	// Opening one that is there, and making one that is not. Split on
	// purpose: a typo in a name cannot silently start a new game instead of
	// opening the old one.
	void on_open(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:open: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		ss_ name = values[0];
		if(!is_world_name(name))
			return;
		ss_ gameid = gameid_of_save(m_server, name);
		if(gameid == ""){
			menu_error(m_server, packet.sender,
					"The save "+name+" does not say which"
					" game it needs");
			return;
		}
		if(m_public && m_starting){
			if(name == m_world_name)
				return menu_message(m_server, packet.sender,
						name+" is running already");
			return switch_world(name, packet.sender);
		}
		start_world(gameid, name, packet.sender);
	}

	void on_create(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:create: %s", e.what());
			return;
		}
		if(values.size() < 2)
			return;
		ss_ name = values[0], gameid = values[1];
		bool valid = is_world_name(name);
		storage::access(m_server, [&](storage::Interface *istorage){
			valid = valid && istorage->valid_name(name);
		});
		if(!valid){
			menu_error(m_server, packet.sender,
					"\""+name+"\" is not a name a save can"
					" have");
			return;
		}
		if(find_game(m_server, gameid).empty()){
			menu_error(m_server, packet.sender,
					"There is no game called "+gameid);
			return;
		}
		// A third value is the seed the menu was given, or empty for a
		// random one: Luanti's own fixed_map_seed, written into the world's
		// world.mt where the module reads it when the world is made
		const ss_ seed = values.size() > 2 ? values[2] : "";
		// One line of world.mt: a line break was a key of the sender's
		// choosing after it
		for(char c : seed){
			if((unsigned char)c < 0x20 || c == 0x7f){
				menu_error(m_server, packet.sender,
						"A seed is one line of text");
				return;
			}
		}
		const ss_ full = no_room(m_server);
		if(!full.empty()){
			menu_error(m_server, packet.sender,
					full+". Delete a world or a game first.");
			return;
		}
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->create(name);
			if(save){
				save->store("main")->set("gameid", gameid);
				save->store("main")->set("created", itos((int64_t)time(NULL)));
				if(!seed.empty()){
					const ss_ dir = save->path()+"/luanti";
					interface::fs::create_directories(dir);
					std::ofstream f(dir+"/world.mt", std::ios::app);
					f<<"fixed_map_seed = "<<seed<<"\n";
				}
				// The fourth and fifth are the new world's Creative mode
				// and Enable damage ([WORLD_LIST]); official's defaults
				// when absent
				if(values.size() > 4){
					std::map<ss_, ss_> set;
					set["creative_mode"] = values[3] == "true" ? "true" : "false";
					set["enable_damage"] = values[4] == "true" ? "true" : "false";
					// The sixth is which mapgen the world is made with
					// ([NEW_WORLD_FORM]), written before the first load
					// because a world is made with one mapgen once. Only
					// a name out of the list the menu offers, because
					// this goes into the world's own settings file.
					if(values.size() > 5 && is_mapgen_name(values[5]))
						set["mg_name"] = values[5];
					write_world_mt(save->path()+"/luanti/world.mt", set);
				}
				istorage->close(save);
			}
		});
		if(!save){
			menu_error(m_server, packet.sender,
					"There is already a save called "+name);
			return;
		}
		// While a world runs, one world at a time: made, and run by
		// switching to it (a launcher's game: by the launcher, through
		// its menu's Play, [PAUSE_WORLDS_LOCAL])
		if(m_starting){
			menu_message(m_server, packet.sender,
					"The world "+name+" was made: run it "
					"to switch to it");
			return;
		}
		start_world(gameid, name, packet.sender);
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

	// Without one of these the game waits for a menu choice; with one it
	// runs what the environment says, which is what every check here does.
	void on_start()
	{
		// A transfer a stopped server was in the middle of
		m_importer.end_transfer();
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
		// The game was games/luanti_launcher until 2026-09-20 and its saves
		// lived under that name: moved to this one on the first start
		// that finds the new directory absent, so nobody loses a world
		// ([LAUNCH_GRID]'s rename checklist)
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
			for(const char *name : {"main:menu", "main:disk",
					"main:running_world", "main:saves",
					"main:save_info", "main:imports", "main:settings",
					"main:progress",
					"main:contentdb_list", "main:menu_message",
					"main:menu_error", "main:game_mapgens"})
				inetwork->declare(name,
						network::Interface::Channel::LatestOnly);
		});

		ss_ gameid;
		ss_ world_name;

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
				return;
			}
		} else {
			// Whoever connects picks; see on_get_saves(). On a public
			// server that is an admin.
			log_i(MODULE, "Waiting for a save to be chosen");
			return;
		}
		start_world(gameid, world_name, 0);
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

		// The world runs in a buildat save and never in a Luanti world
		// directory. Nothing here writes to user/luanti at any point: a
		// Luanti world is read, or imported, and that is all. It has to be
		// this way round rather than by being careful, because the writes do
		// not come from here -- devtest's testnodes mod writes a PNG through
		// core.get_worldpath() while it loads.
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->open(world_name);
			if(!save){
				save = istorage->create(world_name);
				// BUILDAT_LUANTI_SEED: a new save's seed, the way the
				// menu's third value is, so a scripted run on both engines
				// is of one world
				const char *seed = getenv("BUILDAT_LUANTI_SEED");
				if(save && seed && seed[0]){
					const ss_ dir = save->path()+"/luanti";
					interface::fs::create_directories(dir);
					std::ofstream f(dir+"/world.mt", std::ios::app);
					f<<"fixed_map_seed = "<<seed<<"\n";
				}
			}
		});
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
		// A file of Lua into the game's environment, before its mods load.
		// What this is for is a game of one's own on top of a Luanti game
		// -- which is what load_lua() is in the module's interface for --
		// and, while there is no such game here, for looking into one that
		// misbehaves.
		const char *extra_lua = getenv("BUILDAT_LUANTI_LUA");
		if(extra_lua && extra_lua[0]){
			std::ifstream ifs(extra_lua, std::ios::binary);
			if(!ifs.good()){
				m_server->shutdown(1, ss_()+"Cannot read "+extra_lua);
				return;
			}
			std::ostringstream os;
			os<<ifs.rdbuf();
			log_i(MODULE, "Loading %s into the Luanti environment",
					extra_lua);
			luanti::access(m_server, [&](luanti::Interface *i){
				i->load_lua(os.str(), extra_lua);
			});
		}

		// A Luanti world's own map, read into the save once. The world
		// directory is opened read-only; what it says about which game it
		// wants is what chose the game above.
		// The menu's import names one; BUILDAT_LUANTI_IMPORT is the other
		// way in and is what every check here uses
		const char *env_import = getenv("BUILDAT_LUANTI_IMPORT");
		const ss_ import_from = !import_world_from.empty() ?
				import_world_from :
				ss_(env_import && env_import[0] ? env_import : "");
		// [WORLD_MODS] An imported world's choice of mods and its own
		// worldmods/ come with it, on its first start here
		if(!import_from.empty()){
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
				sv_<ss_> values{line};
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar(values);
				}
				const ss_ data = os.str();
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

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
