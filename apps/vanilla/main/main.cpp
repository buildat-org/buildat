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
	// Where each client last said its player is, applied on the next tick;
	// see on_where()
	// And what the player is holding down, in Luanti's own bit order; see
	// control_bits() in client_lua/init.lua and CONTROL_BITS in
	// builtin/luanti/lua/entity.lua
	struct Where {
		double x = 0, y = 0, z = 0, look_h = 0, look_v = 0;
		int32_t controls = 0;
		double sent_us = 0; // the client's clock, microseconds (cereal's
		                    // Lua side has doubles, not int64)
	};
	sm_<network::PeerInfo::Id, Where> m_pending_where;
	// How long a position update waited on the wire ([NET_SIM]): the
	// client's clock is not the server's, so the age is the excess over
	// the smallest (received - sent) seen from that peer -- the fastest
	// update sets the baseline, a lossy link shows as the rest lagging
	// it. The worst per five seconds is logged.
	struct WhereAge {
		int64_t base_us = 0; // the smallest received - sent, or 0
		int64_t worst_us = 0;
		int64_t window_from_us = 0;
	};
	sm_<network::PeerInfo::Id, WhereAge> m_where_age;
	float m_where_timer = 0.0f;
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
	static constexpr double CHAT_BURST = 5;
	// Who has joined, by the account name their player has
	std::map<network::PeerInfo::Id, ss_> m_names;
	std::set<network::PeerInfo::Id> m_join_sent;
	// [JOIN_WHEN_LOADED]: placed and loading, by the seconds waited; and in
	// the world, which the client's main:world_in or WORLD_IN_LIMIT does
	std::map<network::PeerInfo::Id, float> m_loading;
	std::set<network::PeerInfo::Id> m_in_world;
	// Past the loading screen's own 60 s after the first chunk, which a
	// slow link reaches only after the scene's megabytes
	static constexpr float WORLD_IN_LIMIT = 180;

	void init()
	{
		game_settings_self_check();
		perf_self_check();
		interface::launch_param_self_check();
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig_start"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:punch_object"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_saves"));
		m_server->sub_event(this, Event::t("storage:over_limit"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/launch:untrusted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:open"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:save_info"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:set_world_flags"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_game_settings"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:set_game_settings"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_perf_settings"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:set_perf_settings"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:delete"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:create"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_imports"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_settings"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:set_settings"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:contentdb_query"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:contentdb_install"));
		for(const char *n : {"get_world_mods", "set_world_mods", "remove_mod",
				"restart_world", "get_world_txp", "set_world_txp", "remove_txp",
				"stop_world", "trim", "export", "export_part", "import_begin",
				"import_data", "transfer_cancel", "world_in"})
			m_server->sub_event(this, Event::t(
					ss_("network:packet_received/main:")+n));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:import_game"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:import_world"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:where"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:fell"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:chat"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:wield"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:drop"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("accounts:login"));
		m_server->sub_event(this, Event::t("accounts:privs"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:dig", on_dig,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:dig_start", on_dig_start,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:punch_object",
				on_punch_object, network::Packet)
		EVENT_TYPEN("network:packet_received/main:place", on_place,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_saves", on_get_saves,
				network::Packet)
		EVENT_TYPEN("storage:over_limit", on_over_limit, storage::OverLimit)
		EVENT_TYPEN("network:packet_received/launch:untrusted",
				on_launch_untrusted, network::Packet)
		EVENT_TYPEN("network:packet_received/main:save_info", on_save_info,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:set_world_flags",
				on_set_world_flags, network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_game_settings",
				on_get_game_settings, network::Packet)
		EVENT_TYPEN("network:packet_received/main:set_game_settings",
				on_set_game_settings, network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_perf_settings",
				on_get_perf_settings, network::Packet)
		EVENT_TYPEN("network:packet_received/main:set_perf_settings",
				on_set_perf_settings, network::Packet)
		EVENT_TYPEN("network:packet_received/main:delete", on_delete,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:open", on_open,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:create", on_create,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_imports", on_get_imports,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_settings",
				on_get_settings, network::Packet)
		EVENT_TYPEN("network:packet_received/main:set_settings",
				on_set_settings, network::Packet)
		EVENT_TYPEN("network:packet_received/main:contentdb_query",
				on_contentdb_query, network::Packet)
		EVENT_TYPEN("network:packet_received/main:contentdb_install",
				on_contentdb_install, network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_world_mods",
				on_get_world_mods, network::Packet)
		EVENT_TYPEN("network:packet_received/main:set_world_mods",
				on_set_world_mods, network::Packet)
		EVENT_TYPEN("network:packet_received/main:remove_mod",
				on_remove_mod, network::Packet)
		EVENT_TYPEN("network:packet_received/main:restart_world",
				on_restart_world, network::Packet)
		EVENT_TYPEN("network:packet_received/main:stop_world",
				on_stop_world, network::Packet)
		EVENT_TYPEN("network:packet_received/main:trim", on_trim,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:export", on_export,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:export_part",
				on_export_part, network::Packet)
		EVENT_TYPEN("network:packet_received/main:import_begin",
				on_import_begin, network::Packet)
		EVENT_TYPEN("network:packet_received/main:import_data",
				on_import_data, network::Packet)
		EVENT_TYPEN("network:packet_received/main:transfer_cancel",
				on_transfer_cancel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_world_txp",
				on_get_world_txp, network::Packet)
		EVENT_TYPEN("network:packet_received/main:set_world_txp",
				on_set_world_txp, network::Packet)
		EVENT_TYPEN("network:packet_received/main:remove_txp",
				on_remove_txp, network::Packet)
		EVENT_TYPEN("network:packet_received/main:import_game",
				on_import_game, network::Packet)
		EVENT_TYPEN("network:packet_received/main:import_world",
				on_import_world, network::Packet)
		EVENT_TYPEN("network:packet_received/main:chat", on_chat,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:wield", on_wield,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:drop", on_drop,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:fell", on_fell,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:where", on_where,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:world_in", on_world_in,
				network::Packet)
		EVENT_TYPEN("accounts:login", on_accounts_login, accounts::Login)
		EVENT_TYPEN("accounts:privs", on_accounts_privs, accounts::Login)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
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
		if(m_named_peer == 0 && is_owner(peer))
			m_named_peer = peer;
		if(m_named_peer != peer)
			return "client"+itos(peer);
		return name;
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		m_shown_world.erase(old_client.info.id);
		m_shown_menu.erase(old_client.info.id);
		if(m_scene){
			luanti::access(m_server, [&](luanti::Interface *i){
				i->remove_player(player_name_of(old_client.info.id));
			});
		}
		if(m_named_peer == old_client.info.id)
			m_named_peer = 0;
		m_names.erase(old_client.info.id);
		m_join_sent.erase(old_client.info.id);
		m_loading.erase(old_client.info.id);
		m_in_world.erase(old_client.info.id);
		// A transfer cut off leaves nothing behind
		if(m_transfer.peer == old_client.info.id){
			log_i(MODULE, "The transfer's client left; its files removed");
			end_transfer();
		}
		m_chat_bucket.erase(old_client.info.id);
	}

	// Public mode ([VANILLA_PUBLIC])

	// A save a world may be: not _server, which is builtin/accounts', nor
	// any other name beginning with _
	static bool is_world_name(const ss_ &name)
	{
		return !name.empty() && name[0] != '_';
	}

	// The launcher's own client, on the launcher's server
	bool is_owner(network::PeerInfo::Id peer)
	{
		bool local = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			local = i->is_local(peer);
		});
		return local;
	}

	bool is_admin(network::PeerInfo::Id peer)
	{
		auto it = m_names.find(peer);
		if(it == m_names.end())
			return false;
		bool admin = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			admin = i->is_admin(it->second);
		});
		return admin;
	}

	// What the world menu may do: anything on the launcher's server, and an
	// admin's on a public one
	bool may_manage(network::PeerInfo::Id peer)
	{
		if(m_public ? is_admin(peer) : is_owner(peer))
			return true;
		menu_error(peer, "Only an admin manages this server's worlds");
		return false;
	}

	// The launcher's server's alone: the server's own disk and settings
	bool local_only(network::PeerInfo::Id peer)
	{
		if(!m_public && is_owner(peer))
			return true;
		menu_error(peer, m_public ? "Not on a public server" :
				"Only the player who started this game");
		return false;
	}

	// [VANILLA_PUBLIC] 5: the world a public server runs, which an admin
	// chose and it starts at boot
	ss_ public_world_file()
	{
		return m_server->get_config().get<ss_>("user_path")+"/apps/"+
				m_server->get_app_id()+"/public_world";
	}

	ss_ read_public_world()
	{
		std::ifstream f(public_world_file());
		ss_ name;
		std::getline(f, name);
		return is_world_name(name) ? name : "";
	}

	// note: [VANILLA_STOP] who stopped it, on the line after an empty name
	void write_public_world(const ss_ &name, const ss_ &note = "")
	{
		interface::fs::create_directories(
				interface::fs::strip_file_name(public_world_file()));
		std::ofstream f(public_world_file());
		f<<name<<"\n"<<note<<"\n";
	}
	ss_ read_stop_note()
	{
		std::ifstream f(public_world_file());
		ss_ name, note;
		std::getline(f, name);
		std::getline(f, note);
		return name.empty() ? note : "";
	}

	// Another world, by restarting: everyone is told, the choice is kept
	// for the next start, and the server exits with RESTART_STATUS, which
	// the script that runs it takes as start again at once
	void switch_world(const ss_ &name, network::PeerInfo::Id by)
	{
		if(name == m_world_name){
			menu_message(by, name+" is the world running");
			return;
		}
		write_public_world(name);
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

	// A path on the server, as a message says it: the launcher's own user
	// may be told where, and a public server's users are not
	ss_ where(const ss_ &path)
	{
		return m_public ? ss_("(on the server)") : path;
	}

	// A player's packets are a joined player's
	bool joined(network::PeerInfo::Id peer)
	{
		return (!m_public || m_names.count(peer)) && m_in_world.count(peer);
	}

	// In through the join: the world when there is one; else the world
	// menu for an admin, and for anyone else a wait until an admin has
	// chosen one
	void on_accounts_login(const accounts::Login &login)
	{
		if(!m_public)
			return;
		m_names[login.peer] = login.name;
		if(m_scene){
			show_world_to(login.peer);
			return;
		}
		m_waiting_peers.push_back(login.peer);
		if(is_admin(login.peer)){
			m_shown_menu.insert(login.peer);
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(login.peer, "core:run_script",
						"buildat.run_script_file(\"main/menu.lua\")");
			});
			return;
		}
		const ss_ note = read_stop_note();
		sv_<ss_> values{note.empty() ? "No world is running on this server "
				"yet: an admin chooses one. You are in as soon as they have." :
				note+". No world is running: you are in as soon as an admin "
				"starts one."};
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(login.peer, "main:join_wait", os.str());
		});
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
		sv_<ss_> values{m_public ? "1" : "0", is_admin(peer) ? "1" : "0",
				m_world_name, is_local ? "1" : "0",
				m_world_name.empty() ? "" : gameid_of_save(m_world_name)};
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:account", os.str());
		});
	}

	// A server admin has every privilege in the world ([VANILLA_PUBLIC] 3)
	void on_accounts_privs(const accounts::Login &login)
	{
		send_account(login.peer);
		if(!m_public || !m_scene || !m_in_world.count(login.peer))
			return;
		const bool admin = is_admin(login.peer);
		luanti::access(m_server, [&](luanti::Interface *i){
			i->set_admin(login.name, admin);
		});
	}

	// Where a client says its player is, five times a second each. Kept
	// rather than applied: going into the module for each one costs a wait
	// on whatever the module is doing -- a fifth of a second in a game the
	// size of VoxeLibre, and three seconds at its worst -- so five a second
	// per player is more than a second of waiting per second of play, and
	// this module's own queue then grows without bound. Everything a player
	// does afterwards waits behind that backlog: a click took twelve seconds
	// to arrive when this was measured.
	//
	// Only the newest matters anyway, which is what makes keeping it right
	// rather than merely cheap: a position is a heartbeat, like the tick
	// src/server/state.cpp coalesces for the same reason.
	// The loading screen's picture ([LOADING_SCREEN]): one of the running
	// game's menu/background.png and background.<n>.png, at random each
	// join, its name and bytes; none for a game without one. Sent behind
	// the script and ahead of the world, so that it is there from the start
	void send_loading_picture(network::PeerInfo::Id peer)
	{
		const ss_ game_path = find_game(gameid_of_save(m_world_name));
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
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:loading_picture", os.str());
		});
	}

	void on_where(const network::Packet &packet)
	{
		// From the placement on, while loading too: it is what the world
		// loads round ([JOIN_WHEN_LOADED]); the module moves nobody who is
		// not in it yet
		if(!m_in_world.count(packet.sender) && !m_loading.count(packet.sender))
			return;
		if(m_public && !m_names.count(packet.sender))
			return;
		Where w;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(w.x, w.y, w.z, w.look_h, w.look_v, w.controls, w.sent_us);
		} catch(std::exception &e){
			log_w(MODULE, "main:where: %s", e.what());
			return;
		}
		m_pending_where[packet.sender] = w;
		if(w.sent_us > 0){
			const int64_t now = interface::os::time_us();
			WhereAge &a = m_where_age[packet.sender];
			const int64_t d = now - (int64_t)w.sent_us;
			if(a.base_us == 0 || d < a.base_us)
				a.base_us = d;
			const int64_t age = d - a.base_us;
			if(age > a.worst_us)
				a.worst_us = age;
			if(a.window_from_us == 0)
				a.window_from_us = now;
			if(now - a.window_from_us >= 5000000){
				log_i(MODULE, "where: the worst wait behind the wire in "
						"five seconds %d ms (client %u)",
						(int)(a.worst_us / 1000), (unsigned)packet.sender);
				a.worst_us = 0;
				a.window_from_us = now;
			}
		}
	}

	// And the tick is where they are handed over: one visit to the module
	// for every player who has moved since the last one -- and not on every
	// tick, the server's being thirty a second, but at the rate a client
	// sends at. One visit per fifth of a second for the lot of them is what
	// this is for; thirty would be worse than what it replaced.
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
		poll_contentdb();
		for(auto it = m_loading.begin(); it != m_loading.end();){
			const network::PeerInfo::Id peer = it->first;
			it->second += event.dtime;
			++it;
			if(m_loading[peer] >= WORLD_IN_LIMIT){
				log_i(MODULE, "Client %u: no main:world_in in %.0f s; put in",
						(unsigned)peer, (double)WORLD_IN_LIMIT);
				put_in_world(peer);
			}
		}
		m_where_timer += event.dtime;
		if(m_where_timer < 0.2f)
			return;
		m_where_timer = 0.0f;
		if(m_pending_where.empty())
			return;
		sm_<network::PeerInfo::Id, Where> pending;
		pending.swap(m_pending_where);
		luanti::access(m_server, [&](luanti::Interface *i){
			for(const auto &pair : pending){
				i->set_player_pos(player_name_of(pair.first),
						(float)pair.second.x, (float)pair.second.y,
						(float)pair.second.z, (float)pair.second.look_h,
						(float)pair.second.look_v, pair.second.controls);
			}
		});
	}

	// How hard a player landed, which only their own client knows -- the
	// physics is the client's. What it costs is the module's, so this hands
	// over the speed and nothing else.
	//
	// The number is a client's word, so it is bounded here: below Luanti's
	// own tolerance it costs nothing, and nothing beyond terminal velocity
	// is believed. A client that lies about it can hurt nobody but itself,
	// which is what Luanti's own TOSERVER_DAMAGE is worth as well.
	void on_fell(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		double speed = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(speed);
		} catch(std::exception &e){
			log_w(MODULE, "main:fell: %s", e.what());
			return;
		}
		if(!(speed > 14.0))
			return;
		if(speed > 200.0)
			speed = 200.0;
		luanti::access(m_server, [&](luanti::Interface *i){
			i->player_fell(player_name_of(packet.sender), (float)speed);
		});
	}

	// A line a player typed. What it means is the module's: the callbacks
	// run, the "/" commands among them, and what nobody takes is said to
	// everyone.
	void on_chat(const network::Packet &packet)
	{
		// [VANILLA_STOP] With no world, a held player who logged in counts:
		// after the stop's restart nobody is in a world (2026-10-13: the
		// held page's chat went nowhere)
		if(!joined(packet.sender) &&
				!(m_public && !m_scene && m_names.count(packet.sender)))
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
		// **A public server's chat is limited** ([VANILLA_PUBLIC] 8): a
		// player's lines fill a bucket that empties one a second, and a
		// line into a full one is refused and the player told
		if(m_public){
			const int64_t now = interface::os::time_us();
			auto &b = m_chat_bucket[packet.sender];
			b.first = std::max(0.0, b.first - (now - b.second) / 1e6);
			b.second = now;
			if(b.first + 1 > CHAT_BURST){
				luanti::access(m_server, [&](luanti::Interface *i){
					i->chat_send(player_name_of(packet.sender),
							"Too many lines: wait a moment");
				});
				return;
			}
			b.first += 1;
		}
		// [VANILLA_STOP] No game running: the line to everyone in, as
		// Luanti says one
		if(!m_scene){
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar(sv_<ss_>{"<"+player_name_of(packet.sender)+"> "+message});
			}
			network::access(m_server, [&](network::Interface *inetwork){
				for(const auto &kv : m_names)
					inetwork->send(kv.first, "main:chat_line", os.str());
			});
			return;
		}
		luanti::access(m_server, [&](luanti::Interface *i){
			i->chat_message(player_name_of(packet.sender), message);
		});
	}

	// Which hotbar slot the player is holding. The keys and the wheel are
	// the client's, and what is in hand is what the next dig or place asks
	// the module about.
	void on_wield(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:wield: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		const int index = atoi(values[0].c_str());
		if(index < 1 || index > 32)
			return;
		luanti::access(m_server, [&](luanti::Interface *i){
			i->set_wield_index(player_name_of(packet.sender), index);
		});
	}

	// The drop key. The count is how many of the held stack go and zero is
	// all of them, which is what Luanti's Q and Ctrl-Q are.
	void on_drop(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:drop: %s", e.what());
			return;
		}
		const int count = values.empty() ? 0 : atoi(values[0].c_str());
		bool dropped = false;
		luanti::access(m_server, [&](luanti::Interface *i){
			dropped = i->drop_wielded(player_name_of(packet.sender),
					count < 0 ? 0 : count);
		});
		log_v(MODULE, "C%i: main:drop %i: %s", packet.sender, count,
				dropped ? "dropped" : "nothing");
	}

	// A click on the client, as the voxel it pointed at. What it means is
	// the module's to decide: core.dig_node() hands the node to the
	// vendored builtin, which is where can_dig, the drops and every
	// callback around a dig live.
	void on_dig(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		pv::Vector3DInt32 voxel_p;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		} catch(std::exception &e){
			log_w(MODULE, "main:dig: %s", e.what());
			return;
		}
		bool dug = false;
		luanti::access(m_server, [&](luanti::Interface *i){
			dug = i->dig_node(voxel_p.getX(), voxel_p.getY(), voxel_p.getZ(),
					player_name_of(packet.sender));
		});
		log_v(MODULE, "C%i: main:dig " PV3I_FORMAT ": %s", packet.sender,
				PV3I_PARAMS(voxel_p), dug ? "dug" : "nothing");
	}

	// The button going down, which is where a held dig starts: the node is
	// punched, so a mod's on_punch runs on the way in. How long the dig
	// takes is the client's to time -- see core.__dig_props() in the module
	// -- and main:dig is what it sends when it is done.
	void on_dig_start(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		pv::Vector3DInt32 voxel_p;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		} catch(std::exception &e){
			log_w(MODULE, "main:dig_start: %s", e.what());
			return;
		}
		luanti::access(m_server, [&](luanti::Interface *i){
			i->punch_node(voxel_p.getX(), voxel_p.getY(), voxel_p.getZ(),
					player_name_of(packet.sender));
		});
		log_v(MODULE, "C%i: main:dig_start " PV3I_FORMAT, packet.sender,
				PV3I_PARAMS(voxel_p));
	}

	// The same button, when what it was pointing at was an object rather
	// than a node: one punch per press, and no faster than the client's own
	// delay while it is held.
	void on_punch_object(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:punch_object: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		const int32_t id = atoi(values[0].c_str());
		bool punched = false;
		luanti::access(m_server, [&](luanti::Interface *i){
			punched = i->punch_object(id, player_name_of(packet.sender));
		});
		log_v(MODULE, "C%i: main:punch_object %i: %s", packet.sender, id,
				punched ? "punched" : "nothing");
	}

	// The other button. Luanti calls it place, and what it comes to is the
	// pointed node's on_rightclick if it has one and the wielded item's
	// on_place otherwise; which of the two is the module's to decide. under
	// is the node pointed at and above is the empty voxel in front of it,
	// which is where a node goes.
	void on_place(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		pv::Vector3DInt32 under, above;
		// Whether the player was holding the key that means "build against
		// this rather than use it"; see place_node() in luanti/api.h
		uint8_t sneak = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(under, above, sneak);
		} catch(std::exception &e){
			log_w(MODULE, "main:place: %s", e.what());
			return;
		}
		bool placed = false;
		luanti::access(m_server, [&](luanti::Interface *i){
			placed = i->place_node(under.getX(), under.getY(), under.getZ(),
					above.getX(), above.getY(), above.getZ(),
					player_name_of(packet.sender), sneak != 0);
		});
		log_v(MODULE, "C%i: main:place " PV3I_FORMAT ": %s", packet.sender,
				PV3I_PARAMS(above), placed ? "placed" : "nothing");
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
					const ss_ gameid = gameid_of_save(m_world_name);
					const ss_ game_path = find_game(gameid);
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
			if(m_public && !is_admin(event.recipient))
				return;
			if(!m_shown_menu.insert(event.recipient).second)
				return;
			m_waiting_peers.push_back(event.recipient);
			// Nothing to look at yet, so what the client draws is the menu:
			// which save, and which game it needs. A world that was chosen
			// before this client arrived is already on its way up, and the
			// menu says so rather than offering another.
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(event.recipient, "core:run_script",
						"buildat.run_script_file(\"main/menu.lua\")");
			});
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
		if(m_public || !is_owner(packet.sender) || packet.data.size() > 4096)
			return;
		m_launch = packet.data;
		m_launch_sent = true;
	}

	void on_get_saves(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		// Holding no world, the launcher may keep this server for its
		// next launch of the app (start_world() takes it back)
		if(!m_public && !m_starting && is_owner(packet.sender)){
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(packet.sender, "launch:reusable", "1");
			});
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
			if(save != "" && m_launched_param_save &&
					!m_in_world.count(packet.sender))
				return;
			if(save != "" && !m_launched_param_save){
				ss_ gameid = gameid_of_save(save);
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
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(packet.sender, "main:menu", menu);
				});
			}
		}
		// A public server's menu has no imports and no local settings, and
		// over a running world it goes back to it ([VANILLA_PUBLIC] 5)
		if(m_public){
			const ss_ menu = m_starting ? "public_running" : "public";
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(packet.sender, "main:menu", menu);
			});
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
			flat.push_back(gameid_of_save(saves[i]));
			flat.push_back(sizes[i]);
		}
		for(const ss_ &id : list_apps())
			flat.push_back(id);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		// Each game's mapgens for the new-world screen, ahead of the lists
		// that screen is reached from: [gameid, "v7,v5,...", ...]
		sv_<ss_> mapgens;
		for(const ss_ &id : list_apps()){
			const ss_ game_path = find_game(id);
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

	// A save records which Luanti game it needs, as a key in the save rather
	// than in a world.mt: which save and which game it needs were always two
	// facts pretending to be one.
	ss_ gameid_of_save(const ss_ &name)
	{
		ss_ gameid;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(name);
			if(!save)
				return;
			save->store("main")->get("gameid", gameid);
			istorage->close(save);
		});
		return gameid;
	}

	// world.mt's lines as key -> value; a missing file is empty
	static std::map<ss_, ss_> read_world_mt(const ss_ &path)
	{
		std::map<ss_, ss_> out;
		std::ifstream f(path);
		ss_ line;
		while(std::getline(f, line)){
			const size_t eq = line.find('=');
			if(eq == ss_::npos)
				continue;
			ss_ k = line.substr(0, eq), v = line.substr(eq + 1);
			auto trim = [](ss_ &t){
				while(!t.empty() && isspace((unsigned char)t.back())) t.pop_back();
				size_t i = 0;
				while(i < t.size() && isspace((unsigned char)t[i])) i++;
				t = t.substr(i);
			};
			trim(k); trim(v);
			if(!k.empty())
				out[k] = v;
		}
		return out;
	}
	// The file written back with these keys set, the other lines kept
	static void write_world_mt(const ss_ &path, const std::map<ss_, ss_> &set)
	{
		std::map<ss_, ss_> all = read_world_mt(path);
		for(const auto &kv : set)
			all[kv.first] = kv.second;
		interface::fs::create_directories(interface::fs::strip_file_name(path));
		std::ofstream f(path, std::ios::trunc);
		for(const auto &kv : all)
			f << kv.first << " = " << kv.second << "\n";
	}

	// [GAME_SETTINGS]: an option a game's mods declare in settingtypes.txt,
	// set per world in its world.mt, which core.settings reads
	struct GameSetting {
		ss_ name, label, type, dflt, min, max;
		sv_<ss_> values; // an enum's
	};
	// One line: "name (Label) type default", an int's or a float's
	// "min max" after it, an enum's "a,b,c". False for a comment, a
	// [section] and a type not offered here.
	// simplified: bool, int, float, enum and string; flags, v3f, noise
	// parameters and the rest are left to a conf until a game wants one
	static bool parse_setting_line(ss_ line, GameSetting &s)
	{
		while(!line.empty() && isspace((unsigned char)line.back()))
			line.pop_back();
		size_t i = 0;
		while(i < line.size() && isspace((unsigned char)line[i]))
			i++;
		line = line.substr(i);
		if(line.empty() || line[0] == '#' || line[0] == '[')
			return false;
		const size_t sp = line.find(' ');
		if(sp == ss_::npos)
			return false;
		s = GameSetting();
		s.name = line.substr(0, sp);
		// A world.mt key: nothing that could end the line or the key
		for(char c : s.name)
			if(!isalnum((unsigned char)c) && c != '_' && c != '.' && c != '-')
				return false;
		if(s.name.compare(0, 7, "secure.") == 0)
			return false;
		// The label ends at the first ')' a space follows, as Luanti's
		// pattern "%((.-)%)%s+(%S+)" reads it: a label may hold parentheses
		const size_t lp = line.find('(', sp);
		if(lp == ss_::npos)
			return false;
		size_t rp = lp;
		do
			rp = line.find(')', rp + 1);
		while(rp != ss_::npos && rp + 1 < line.size() &&
				!isspace((unsigned char)line[rp + 1]));
		if(rp == ss_::npos || rp + 1 >= line.size())
			return false;
		s.label = line.substr(lp + 1, rp - lp - 1);
		std::istringstream is(line.substr(rp + 1));
		is >> s.type;
		if(s.type == "string"){
			std::getline(is, s.dflt);
			while(!s.dflt.empty() && isspace((unsigned char)s.dflt[0]))
				s.dflt.erase(0, 1);
			return true;
		}
		if(!(is >> s.dflt))
			return false;
		if(s.type == "bool")
			return s.dflt == "true" || s.dflt == "false";
		if(s.type == "int" || s.type == "float"){
			is >> s.min >> s.max;
			return true;
		}
		if(s.type == "enum"){
			ss_ list, v;
			is >> list;
			std::istringstream ls(list);
			while(std::getline(ls, v, ','))
				if(!v.empty())
					s.values.push_back(v);
			return !s.values.empty();
		}
		return false;
	}
	// Whether a player's value is one the setting takes: the bounds a
	// game declared, and never a line break into world.mt
	static bool setting_value_ok(const GameSetting &s, const ss_ &v)
	{
		if(v.find_first_of("\r\n") != ss_::npos)
			return false;
		if(s.type == "bool")
			return v == "true" || v == "false";
		if(s.type == "enum")
			return std::find(s.values.begin(), s.values.end(), v) !=
					s.values.end();
		if(s.type == "int" || s.type == "float"){
			if(v.empty())
				return false;
			char *end = nullptr;
			const double d = s.type == "int" ?
					(double)strtoll(v.c_str(), &end, 10) :
					strtod(v.c_str(), &end);
			if(*end != 0 || !std::isfinite(d))
				return false;
			if(!s.min.empty() && d < atof(s.min.c_str()))
				return false;
			if(!s.max.empty() && d > atof(s.max.c_str()))
				return false;
			return true;
		}
		return s.type == "string";
	}
	static void game_settings_self_check()
	{
		GameSetting s;
		auto fail = [](const char *what){
			throw Exception(ss_("vanilla: settingtypes self-check: ")+what);
		};
		if(!parse_setting_line("mobs_spawn (Spawn mobs naturally) bool true", s) ||
				s.name != "mobs_spawn" || s.label != "Spawn mobs naturally" ||
				!setting_value_ok(s, "false") || setting_value_ok(s, "1"))
			fail("bool");
		if(!parse_setting_line("n (A (b)) int 5 0 10", s) || s.dflt != "5" ||
				!setting_value_ok(s, "10") || setting_value_ok(s, "11") ||
				setting_value_ok(s, "2x") || setting_value_ok(s, ""))
			fail("int");
		if(!parse_setting_line("m (Mode) enum b a,b,c", s) ||
				s.values.size() != 3 || setting_value_ok(s, "d"))
			fail("enum");
		if(!parse_setting_line("t (Text) string", s) || s.dflt != "" ||
				setting_value_ok(s, "a\nb = c"))
			fail("string");
		if(parse_setting_line("# c (x) bool true", s) ||
				parse_setting_line("[Section]", s) ||
				parse_setting_line("a=b (x) bool true", s) ||
				parse_setting_line("v (V) v3f (0, 0, 0)", s))
			fail("not a setting");
	}
	// Every setting of a game: its own settingtypes.txt and each mod's,
	// a modpack's mods too; the first of a name wins
	static sv_<GameSetting> game_settings(const ss_ &game_path)
	{
		sv_<GameSetting> out;
		std::set<ss_> seen;
		std::function<void(const ss_ &, int)> walk =
				[&](const ss_ &dir, int depth){
			std::ifstream f(dir+"/settingtypes.txt");
			ss_ line;
			GameSetting s;
			while(std::getline(f, line))
				if(parse_setting_line(line, s) && seen.insert(s.name).second)
					out.push_back(s);
			if(depth == 0)
				return;
			for(const interface::fs::Node &n :
					interface::fs::list_directory(dir))
				if(n.is_directory && n.name[0] != '.')
					walk(dir+"/"+n.name, depth - 1);
		};
		walk(game_path, 0);
		walk(game_path+"/mods", 3);
		return out;
	}
	// The save's directory, and its gameid when asked, or false
	bool save_dir(const ss_ &name, ss_ &path, ss_ *gameid = nullptr)
	{
		if(!is_world_name(name))
			return false;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(name);
			if(save){
				path = save->path();
				if(gameid)
					save->store("main")->get("gameid", *gameid);
				istorage->close(save);
			}
		});
		return !path.empty();
	}
	// The save's directory and its game's settings, or false
	bool save_settings(const ss_ &name, ss_ &path, sv_<GameSetting> &out)
	{
		ss_ gameid;
		if(!save_dir(name, path, &gameid))
			return false;
		const ss_ game_path = gameid.empty() ? "" : find_game(gameid);
		if(path.empty() || game_path.empty())
			return false;
		out = game_settings(game_path);
		return true;
	}
	sv_<ss_> read_packet_strings(const network::Packet &packet)
	{
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "%s: %s", cs(packet.name), e.what());
			values.clear();
		}
		return values;
	}
	// main:game_settings {name, note, then per setting name, label, type,
	// default, the enum's values or "min max", the world's value or ""}
	// main:perf_settings is the same, of perf_settings() ([SERVER_PRESETS])
	void send_game_settings(const network::Packet &packet, const ss_ &name,
			const ss_ &note, bool perf = false)
	{
		if(!is_world_name(name))
			return;
		ss_ path;
		sv_<GameSetting> settings;
		// An answer either way: the client waits on it
		const bool found = perf ? save_dir(name, path) :
				save_settings(name, path, settings);
		if(perf)
			settings = perf_settings();
		const std::map<ss_, ss_> mt = found ?
				read_world_mt(path+"/luanti/world.mt") :
				std::map<ss_, ss_>();
		sv_<ss_> flat{name, found ? note : perf ? "No such world." :
				"This world's game is not installed here."};
		for(const GameSetting &s : settings){
			ss_ extra;
			for(const ss_ &v : s.values)
				extra += (extra.empty() ? "" : ",")+v;
			if(s.type == "int" || s.type == "float")
				extra = s.min+" "+s.max;
			auto it = mt.find(s.name);
			for(const ss_ &x : {s.name, s.label, s.type, s.dflt, extra,
					it == mt.end() ? ss_() : it->second})
				flat.push_back(x);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, perf ? "main:perf_settings" :
					"main:game_settings", os.str());
		});
	}
	// main:get_game_settings {name}
	void on_get_game_settings(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(!values.empty())
			send_game_settings(packet, values[0], "");
	}
	// main:set_game_settings {name, key, value, ...}: into world.mt, each
	// key one the game declares and each value one it takes
	void on_set_game_settings(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path;
		sv_<GameSetting> settings;
		if(values.empty() || !save_settings(values[0], path, settings))
			return;
		std::map<ss_, ss_> set;
		ss_ refused;
		for(size_t i = 1; i + 1 < values.size(); i += 2){
			auto it = std::find_if(settings.begin(), settings.end(),
					[&](const GameSetting &s){ return s.name == values[i]; });
			if(it != settings.end() && setting_value_ok(*it, values[i + 1]))
				set[values[i]] = values[i + 1];
			else
				refused += (refused.empty() ? "" : ", ")+values[i];
		}
		if(!set.empty())
			write_world_mt(path+"/luanti/world.mt", set);
		log_i(MODULE, "%s: %zu game settings set%s", cs(values[0]), set.size(),
				refused.empty() ? "" : cs(", refused: "+refused));
		send_game_settings(packet, values[0], refused.empty() ?
				"Saved." : "Not saved, out of range: "+refused);
	}

	// [SERVER_PRESETS]: what a world costs its server, as a preset of
	// Luanti's own settings in world.mt or "Custom". Ranges are blocks of
	// 16 nodes, read in sections of 64 (luanti.cpp read_range_settings).
	// simplified: a first cut, to be tuned by a run with a few players on
	// a small machine
	static const sv_<ss_> &perf_keys()
	{
		static const sv_<ss_> k{"max_block_send_distance",
				"max_block_generate_distance", "active_object_send_range_blocks",
				"liquid_loop_max", "item_entity_ttl"};
		return k;
	}
	static const std::map<ss_, sv_<ss_>> &perf_presets()
	{
		static const std::map<ss_, sv_<ss_>> p{
			{"VPS / Raspberry Pi", {"4", "4", "4", "5000", "300"}},
			{"Dedicated server", {"8", "4", "8", "10000", "600"}},
			{"Desktop", {"12", "10", "12", "20000", "900"}},
		};
		return p;
	}
	// A world with no preset takes its context's: headless is a small
	// server, one the client starts has the machine to itself
	ss_ default_preset() const
	{
		return m_public ? "VPS / Raspberry Pi" : "Desktop";
	}
	// [SAVE_LIMIT] What the world gives up when the app is over the host's
	// limit, in world.mt beside the preset and not part of it
	static sv_<GameSetting> limit_settings()
	{
		GameSetting a;
		a.name = "buildat_forget_unchanged";
		a.label = "Forget land nobody changed when over the disk limit";
		a.type = "bool";
		a.dflt = "true";
		GameSetting b;
		b.name = "buildat_forget_builds_days";
		b.label = "Also forget builds nobody has visited in this many days "
				"(0: never; 90 is a fair choice)";
		b.type = "int";
		b.dflt = "0";
		b.min = "0";
		b.max = "36500";
		return {a, b};
	}
	sv_<GameSetting> perf_settings() const
	{
		const sv_<ss_> &dflt = perf_presets().at(default_preset());
		GameSetting p;
		p.name = "buildat_preset";
		p.label = "Preset";
		p.type = "enum";
		p.dflt = default_preset();
		for(const auto &kv : perf_presets())
			p.values.push_back(kv.first);
		p.values.push_back("Custom");
		sv_<GameSetting> out{p};
		const char *labels[] = {"Map send range, blocks of 16 nodes",
				"Map generate range, blocks of 16 nodes",
				"Object send range, blocks of 16 nodes",
				"Liquid updates per step", "Dropped item lifetime, s (-1: forever)"};
		const char *ranges[][2] = {{"4", "64"}, {"4", "64"}, {"4", "64"},
				{"100", "1000000"}, {"-1", "86400"}};
		for(size_t i = 0; i < perf_keys().size(); i++){
			GameSetting s;
			s.name = perf_keys()[i];
			s.label = labels[i];
			s.type = "int";
			s.dflt = dflt[i];
			s.min = ranges[i][0];
			s.max = ranges[i][1];
			out.push_back(s);
		}
		for(const GameSetting &s : limit_settings())
			out.push_back(s);
		return out;
	}
	// The preset's values with the edits over them, and the preset named
	// "Custom" when an edit differs from it. A world.mt with no preset is
	// its context's default, or "Custom" when it has values of its own.
	std::map<ss_, ss_> perf_resolve(const std::map<ss_, ss_> &mt,
			std::map<ss_, ss_> edits) const
	{
		const sv_<ss_> &keys = perf_keys();
		const bool own = std::any_of(keys.begin(), keys.end(),
				[&](const ss_ &k){ return mt.count(k) != 0; });
		ss_ preset = edits.count("buildat_preset") ? edits["buildat_preset"] :
				mt.count("buildat_preset") ? mt.at("buildat_preset") :
				own ? "Custom" : default_preset();
		edits.erase("buildat_preset");
		auto it = perf_presets().find(preset);
		if(it == perf_presets().end())
			preset = "Custom";
		const sv_<ss_> &dflt = perf_presets().at(default_preset());
		std::map<ss_, ss_> out;
		for(size_t i = 0; i < keys.size(); i++)
			out[keys[i]] = it != perf_presets().end() ? it->second[i] :
					mt.count(keys[i]) ? mt.at(keys[i]) : dflt[i];
		for(const auto &kv : edits){
			if(out[kv.first] != kv.second){
				out[kv.first] = kv.second;
				preset = "Custom";
			}
		}
		out["buildat_preset"] = preset;
		return out;
	}
	void perf_self_check() const
	{
		auto fail = [](const char *what){
			throw Exception(ss_("vanilla: preset self-check: ")+what);
		};
		std::map<ss_, ss_> r = perf_resolve({}, {});
		if(r["buildat_preset"] != default_preset())
			fail("a new world");
		r = perf_resolve({{"max_block_send_distance", "20"}}, {});
		if(r["buildat_preset"] != "Custom" || r["max_block_send_distance"] != "20")
			fail("values of its own");
		r = perf_resolve({{"buildat_preset", "Custom"}},
				{{"buildat_preset", "Dedicated server"}});
		if(r["buildat_preset"] != "Dedicated server" ||
				r["liquid_loop_max"] != "10000")
			fail("a preset chosen");
		r = perf_resolve({{"buildat_preset", "Desktop"}},
				{{"item_entity_ttl", "900"}, {"liquid_loop_max", "7000"}});
		if(r["buildat_preset"] != "Custom" || r["liquid_loop_max"] != "7000" ||
				r["max_block_send_distance"] != "12")
			fail("an edit");
	}
	// main:get_perf_settings {name}
	void on_get_perf_settings(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(!values.empty())
			send_game_settings(packet, values[0], "", true);
	}
	// [SAVE_LIMIT] Empty with room for need more bytes, else why not
	ss_ no_room(int64_t need = 0)
	{
		int64_t used = 0, limit = 0, room = 0;
		storage::access(m_server, [&](storage::Interface *i){
			used = i->used_bytes();
			limit = i->limit_bytes();
			room = i->room_bytes();
		});
		if(limit <= 0 || room > need)
			return "";
		char buf[100];
		snprintf(buf, sizeof buf, "Not enough room: %.1f of %.1f MB used",
				used / 1e6, limit / 1e6);
		return buf;
	}

	// storage:over_limit: the downloads in the cache first, then the running
	// world forgets land by its world.mt's settings, down to 90% of the
	// limit less everything else the app has written. A world not running
	// is not trimmed: deleting a world or a game is the admin's way out.
	void on_over_limit(const storage::OverLimit &event)
	{
		const ss_ cache = m_server->get_config().get<ss_>("cache_path")+
				"/luanti/contentdb";
		if(m_contentdb_jobs.empty()){
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
	static ss_ mb_text(int64_t bytes)
	{
		char buf[32];
		snprintf(buf, sizeof buf, "%.1f MB", bytes / 1000000.0);
		return buf;
	}
	void send_trim_info(network::PeerInfo::Id peer, const ss_ &save,
			const ss_ &note)
	{
		if(!m_scene || !m_world_save || save != m_world_name){
			send_strings(peer, "main:trim_info", {save, "Trimming works on "
					"the world running: start "+save+" first."});
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
		send_strings(peer, "main:trim_info", flat);
	}
	void on_trim(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
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
			send_strings(packet.sender, "main:trim_ask", flat);
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

	// [WORLD_TRIM_MOVE] 3-5: a world out as a zip and one in, in parts:
	// a world is more than a packet or a client's string holds. One at a
	// time, its files in one folder of the cache that is emptied when it
	// ends, whichever way (and at a start, after a server that stopped
	// mid-way).
	//   export: main:export {save} -> main:export_ready {save, bytes}; then
	//     main:export_part {offset} -> main:export_data {offset, bytes}
	//   import: main:import_begin {name, bytes} -> main:import_next
	//     {offset}; main:import_data {offset, bytes} -> import_next, and
	//     after the last a menu message or error
	// simplified: the copy and the zip are made on the server's thread; a
	// large world holds the game while they are made, as compacting does
	struct Transfer {
		network::PeerInfo::Id peer = 0;
		bool import = false;
		ss_ name;
		int64_t size = 0, done = 0;
	};
	Transfer m_transfer;
	enum { TRANSFER_PART = 1024 * 1024 };
	ss_ transfer_dir()
	{
		return m_server->get_config().get<ss_>("cache_path")+"/vanilla_transfer";
	}
	void end_transfer()
	{
		interface::fs::remove_all(transfer_dir());
		m_transfer = Transfer();
	}
	bool transfer_free(network::PeerInfo::Id peer)
	{
		if(m_transfer.peer == 0)
			return true;
		menu_error(peer, "Another transfer is running: "+ss_(m_transfer.import ?
				"an import" : "an export of "+m_transfer.name)+". Try again "
				"once it is done.");
		return false;
	}
	// Every file under dir, the archive's names under prefix
	static void list_files(const ss_ &dir, const ss_ &prefix,
			sv_<std::pair<ss_, ss_>> &out)
	{
		for(const auto &n : interface::fs::list_directory(dir)){
			if(n.is_directory)
				list_files(dir+"/"+n.name, prefix+n.name+"/", out);
			else
				out.push_back({prefix+n.name, dir+"/"+n.name});
		}
	}
	void on_export(const network::Packet &packet)
	{
		if(!may_manage(packet.sender) || !transfer_free(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path;
		if(values.empty() || !save_dir(values[0], path))
			return menu_error(packet.sender, "No such save");
		const ss_ save = values[0];
		const ss_ dir = transfer_dir();
		interface::fs::remove_all(dir);
		interface::fs::create_directories(dir+"/store");
		// The store as of now, consistent: the running world saved first
		// and copied by SQLite, not the live file and its WAL
		const ss_ copy = dir+"/store/save.sqlite";
		ss_ err;
		const int64_t t0 = interface::os::time_us();
		if(save == m_world_name && m_scene && m_world_save){
			voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
				w->save();
			});
			err = m_world_save->copy_to(copy);
		} else {
			storage::access(m_server, [&](storage::Interface *i){
				storage::Save *s = i->open(save);
				err = s ? s->copy_to(copy) : "cannot open it";
				if(s)
					i->close(s);
			});
		}
		sv_<std::pair<ss_, ss_>> files{{save+"/save.sqlite", copy}};
		sv_<std::pair<ss_, ss_>> rest;
		list_files(path, save+"/", rest);
		for(const auto &f : rest){
			const ss_ &n = f.first;
			// The store is the copy; its journal files are the live one's
			if(n == save+"/save.sqlite" || n.find(".sqlite-") != ss_::npos ||
					n.find(".sqlite.") != ss_::npos)
				continue;
			files.push_back(f);
		}
		const ss_ zip = dir+"/export.zip";
		if(err.empty()){
			try {
				interface::zip_write(zip, files);
			} catch(std::exception &e){
				err = e.what();
			}
		}
		interface::fs::remove_all(dir+"/store");
		if(!err.empty()){
			end_transfer();
			return menu_error(packet.sender, "Exporting "+save+" failed: "+err);
		}
		m_transfer.peer = packet.sender;
		m_transfer.name = save;
		m_transfer.size = interface::fs::file_size(zip);
		log_i(MODULE, "Exporting %s: %zu files, %lld kB, made in %d ms",
				cs(save), files.size(), (long long)(m_transfer.size / 1024),
				(int)((interface::os::time_us() - t0) / 1000));
		send_strings(packet.sender, "main:export_ready",
				{save, itos(m_transfer.size)});
	}
	void on_export_part(const network::Packet &packet)
	{
		if(m_transfer.import || m_transfer.peer != packet.sender)
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.empty())
			return;
		const int64_t offset = atoll(values[0].c_str());
		if(offset < 0 || offset >= m_transfer.size)
			return;
		ss_ data((size_t)std::min<int64_t>(TRANSFER_PART, m_transfer.size - offset), '\0');
		std::ifstream is(transfer_dir()+"/export.zip", std::ios::binary);
		is.seekg(offset);
		is.read(&data[0], data.size());
		if((size_t)is.gcount() != data.size()){
			end_transfer();
			return menu_error(packet.sender, "The export's file went away");
		}
		send_strings(packet.sender, "main:export_data", {itos(offset), data});
		if(offset + (int64_t)data.size() >= m_transfer.size){
			log_i(MODULE, "Exported %s", cs(m_transfer.name));
			end_transfer();
		}
	}
	void on_import_begin(const network::Packet &packet)
	{
		if(!may_manage(packet.sender) || !transfer_free(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.size() < 2)
			return;
		const int64_t size = atoll(values[1].c_str());
		const ss_ full = no_room(size);
		if(size <= 0 || !full.empty())
			return menu_error(packet.sender, size <= 0 ? ss_("An empty file") :
					full+"; the zip is "+mb_text(size)+". Delete a world or "
					"a game first.");
		// The save's name from the file's: letters, digits, _ and -
		ss_ name;
		for(char c : values[0].substr(0, values[0].find('.')))
			if(isalnum((unsigned char)c) || c == '_' || c == '-')
				name += c;
		if(name.compare(0, 1, "_") == 0 || name.empty())
			name = "imported"+name;
		const ss_ dir = transfer_dir();
		interface::fs::remove_all(dir);
		interface::fs::create_directories(dir);
		std::ofstream(dir+"/import.zip", std::ios::binary);
		m_transfer.peer = packet.sender;
		m_transfer.import = true;
		m_transfer.name = name.substr(0, 60);
		m_transfer.size = size;
		log_i(MODULE, "Importing %s: %lld kB coming", cs(values[0]),
				(long long)(size / 1024));
		send_strings(packet.sender, "main:import_next", {"0"});
	}
	void on_import_data(const network::Packet &packet)
	{
		if(!m_transfer.import || m_transfer.peer != packet.sender)
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.size() < 2 || atoll(values[0].c_str()) != m_transfer.done ||
				values[1].empty() || m_transfer.done +
				(int64_t)values[1].size() > m_transfer.size){
			end_transfer();
			return menu_error(packet.sender, "The import's parts came out "
					"of order; nothing was kept");
		}
		{
			std::ofstream os(transfer_dir()+"/import.zip",
					std::ios::binary | std::ios::app);
			os.write(values[1].data(), values[1].size());
		}
		m_transfer.done += values[1].size();
		if(m_transfer.done < m_transfer.size){
			send_strings(packet.sender, "main:import_next",
					{itos(m_transfer.done)});
			return;
		}
		const ss_ err = finish_import(packet.sender);
		end_transfer();
		if(!err.empty())
			menu_error(packet.sender, "Importing "+m_transfer_last+" failed: "+
					err+". Nothing was kept.");
	}
	ss_ m_transfer_last;
	// main:transfer_cancel: the client could not write or read its side
	void on_transfer_cancel(const network::Packet &packet)
	{
		if(m_transfer.peer != packet.sender)
			return;
		log_i(MODULE, "The client cancelled the transfer of %s",
				cs(m_transfer.name));
		end_transfer();
	}
	// The zip in: what it is, and it put where that goes. An error's text
	// or "" once done; the caller empties the folder either way
	ss_ finish_import(network::PeerInfo::Id peer)
	{
		const ss_ dir = transfer_dir(), zip = dir+"/import.zip";
		m_transfer_last = m_transfer.name;
		int64_t room = 0;
		storage::access(m_server, [&](storage::Interface *i){
			room = i->room_bytes();
		});
		// What the headers say it comes to, against the room; and the
		// extraction holds each entry to what it says and the whole to
		// the room, whatever they said
		uint64_t declared = 0;
		try {
			for(const auto &e : interface::zip_list(zip))
				declared += e.size;
			if((int64_t)declared > room)
				return "it unpacks to "+mb_text(declared)+", and there is "
						"room for "+mb_text(room);
			interface::zip_extract(zip, dir+"/x", (uint64_t)room);
		} catch(std::exception &e){
			return e.what();
		}
		interface::fs::remove_all(zip);
		// A Buildat save's save.sqlite or a Luanti world's world.mt, at the
		// top or one folder down
		ss_ root = dir+"/x";
		auto is_world = [](const ss_ &p){
			return interface::fs::path_exists(p+"/save.sqlite") ||
					interface::fs::path_exists(p+"/world.mt");
		};
		if(!is_world(root)){
			const auto top = interface::fs::list_directory(root);
			if(top.size() != 1 || !top[0].is_directory ||
					!is_world(root+"/"+top[0].name))
				return "no save.sqlite or world.mt at its top or one folder "
						"down: neither a Buildat save nor a Luanti world";
			root += "/"+top[0].name;
		}
		const bool buildat_save = interface::fs::path_exists(root+"/save.sqlite");
		// A world's own mods are code the server runs with all of its reach
		// -- the accounts store among it -- and a public server's admin is
		// not whoever owns the machine: a zip's are left out there
		// ([SECURITY_RUN_5]). The Mods menu's ContentDB ones stay.
		// simplified: left out, not offered; a confirm naming them is the
		// upgrade if an admin needs one
		if(m_public){
			for(const ss_ &p : {root+"/luanti/worldmods", root+"/worldmods"}){
				if(interface::fs::path_exists(p)){
					log_w(MODULE, "import: the zip's world mods left out");
					interface::fs::remove_all(p);
				}
			}
		}
		const ss_ name = free_save_name(m_transfer.name);
		if(name.empty())
			return "no free name for "+m_transfer.name;
		if(!buildat_save){
			// A Luanti world, of the backend that is read
			const auto mt = read_world_mt(root+"/world.mt");
			const auto it = mt.find("backend");
			const ss_ backend = it == mt.end() ? "sqlite3" : it->second;
			if(backend != "sqlite3")
				return "it is a Luanti world of the "+backend+" backend; "
						"only sqlite3 is read. Official Luanti converts it: "
						"luanti --migrate sqlite3 --world <path>";
			if(!interface::fs::path_exists(root+"/map.sqlite"))
				return "it is a Luanti world with no map.sqlite";
			const ss_ err = import_luanti_world(peer, root, m_transfer.name,
					name);
			return err;
		}
		// A Buildat save: moved in, opened once to see it reads
		const ss_ to = m_server->get_config().get<ss_>("user_path")+"/apps/"+
				m_server->get_app_id()+"/saves/"+name;
		for(const auto &n : interface::fs::list_directory(root))
			if(n.name.find(".sqlite-") != ss_::npos)
				interface::fs::remove_all(root+"/"+n.name);
		if(std::rename(root.c_str(), to.c_str()) != 0){
			// Another file system: copied
			size_t done = 0;
			ss_ err;
			if(!copy_tree(root, to, done, 0, peer, err)){
				interface::fs::remove_all(to);
				return "could not move it into the saves: "+err;
			}
		}
		ss_ gameid;
		storage::access(m_server, [&](storage::Interface *i){
			try {
				storage::Save *s = i->open(name);
				if(s){
					s->store("main")->get("gameid", gameid);
					i->close(s);
				}
			} catch(std::exception &e){
				log_w(MODULE, "import: %s: %s", cs(name), e.what());
			}
		});
		if(gameid.empty()){
			interface::fs::remove_all(to);
			return "its store does not read as a Buildat save";
		}
		storage::access(m_server, [&](storage::Interface *i){ i->remeasure(); });
		menu_message(peer, "Imported "+name+" (game "+gameid+")"+
				(find_game(gameid).empty() ? "; the game is not installed" : ""));
		return "";
	}
	// name, or name_2, _3... where no save is
	ss_ free_save_name(const ss_ &name)
	{
		ss_ path;
		for(int i = 1; i < 1000; i++){
			const ss_ n = i == 1 ? name : name+"_"+itos(i);
			bool valid = false;
			storage::access(m_server, [&](storage::Interface *istorage){
				valid = istorage->valid_name(n);
			});
			if(!valid)
				return "";
			path.clear();
			if(!save_dir(n, path) && !interface::fs::path_exists(
					m_server->get_config().get<ss_>("user_path")+"/apps/"+
					m_server->get_app_id()+"/saves/"+n))
				return n;
		}
		return "";
	}

	// main:set_perf_settings {name, key, value, ...}
	void on_set_perf_settings(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path;
		if(values.empty() || !save_dir(values[0], path))
			return;
		const sv_<GameSetting> settings = perf_settings();
		std::map<ss_, ss_> edits;
		ss_ refused;
		for(size_t i = 1; i + 1 < values.size(); i += 2){
			auto it = std::find_if(settings.begin(), settings.end(),
					[&](const GameSetting &s){ return s.name == values[i]; });
			if(it != settings.end() && setting_value_ok(*it, values[i + 1]))
				edits[values[i]] = values[i + 1];
			else
				refused += (refused.empty() ? "" : ", ")+values[i];
		}
		const ss_ mt_path = path+"/luanti/world.mt";
		std::map<ss_, ss_> own;
		for(const GameSetting &s : limit_settings()){
			if(edits.count(s.name)){
				own[s.name] = edits[s.name];
				edits.erase(s.name);
			}
		}
		if(refused.empty()){
			write_world_mt(mt_path, perf_resolve(read_world_mt(mt_path), edits));
			write_world_mt(mt_path, own);
		}
		const bool running = m_world_name == values[0] && m_starting;
		send_game_settings(packet, values[0], !refused.empty() ?
				"Not saved, out of range: "+refused : running ?
				"Saved. Takes effect when the server restarts." : "Saved.", true);
	}
	// A world with no preset gets its context's as it starts, so the form
	// and the world.mt say what the world runs with
	void apply_default_preset(const ss_ &save_path)
	{
		const ss_ mt_path = save_path+"/luanti/world.mt";
		const std::map<ss_, ss_> mt = read_world_mt(mt_path);
		if(mt.count("buildat_preset"))
			return;
		const std::map<ss_, ss_> set = perf_resolve(mt, {});
		write_world_mt(mt_path, set);
		log_i(MODULE, "%s: server preset %s", cs(save_path),
				cs(set.at("buildat_preset")));
	}

	// main:save_info <name>: what a save answers at a glance, as a flat
	// list of key, value pairs ([WORLD_LIST]) -- one open, a few keys, one
	// count. The section count is voxelworld's "main/s<x>,<y>,<z>/generated"
	// keys; the size the directory's.
	void on_save_info(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
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
			const ss_ game_path = find_game(gameid);
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
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "main:save_info", os.str());
		});
	}

	// main:set_world_flags <name> <creative_mode> <enable_damage>: into the
	// save's world.mt, which core.settings reads when the world loads
	void on_set_world_flags(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
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
		if(!may_manage(packet.sender))
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
			menu_error(packet.sender, "The world that is running is not "
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
			menu_error(packet.sender, "There is no save called "+values[0]);
			return;
		}
		const ss_ trash = interface::fs::strip_file_name(path)+"/trash";
		interface::fs::create_directories(trash);
		time_t now = time(NULL);
		char date[32];
		strftime(date, sizeof date, "%Y-%m-%d_%H%M%S", localtime(&now));
		const ss_ to = trash+"/"+values[0]+"-"+date;
		if(rename(path.c_str(), to.c_str()) != 0){
			menu_error(packet.sender, "Could not move "+where(path)+" to "+
					where(to));
			return;
		}
		log_i(MODULE, "Save %s moved to %s", cs(values[0]), cs(to));
		menu_message(packet.sender, values[0]+" moved to the trash");
	}

	sv_<ss_> list_apps()
	{
		sv_<ss_> out;
		ss_ dir = luanti_path()+"/games";
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(!n.is_directory || n.name == "." || n.name == "..")
				continue;
			if(interface::fs::path_exists(dir+"/"+n.name+"/game.conf"))
				out.push_back(n.name);
		}
		// The one buildat ships, so that there is something to choose
		// without a Luanti installation
		if(interface::fs::path_exists(bundled_game_path()+"/game.conf"))
			out.push_back("minimal");
		std::sort(out.begin(), out.end());
		return out;
	}

	//
	// Importing a game and a world from a real Luanti installation
	//
	// Nothing here writes to any of those directories: they are read, and a
	// game is copied out of one into buildat's own. See "The importer" in
	// doc/plan/master_plan.md.
	//

	// The launcher's settings, in the user path beside luanti/games and
	// luanti/worlds ([LAUNCH_GRID]): {"render_mode": "pbr", ...}, the mode
	// a session draws in when BUILDAT_RENDER_MODE says nothing (read by
	// builtin/luanti where the variable is), the view and the keys. Written
	// by hand and read with sajson. On the wire one list of "key=value"
	// strings. An old file's "import_paths" is ignored
	// ([LUANTI_IMPORT_FOLDER]).
	ss_ settings_path()
	{
		return luanti_path()+"/settings.json";
	}
	// One string value of settings.json's top level, or "" when absent
	ss_ read_setting(const ss_ &key)
	{
		std::ifstream f(settings_path());
		if(!f.good())
			return "";
		std::stringstream ss;
		ss << f.rdbuf();
		const ss_ text = ss.str();
		const sajson::document doc =
				sajson::parse(sajson::dynamic_allocation(),
					sajson::string(text.c_str(), text.size()));
		if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_OBJECT)
			return "";
		sajson::value root = doc.get_root();
		for(size_t i = 0; i < root.get_length(); i++){
			if(root.get_object_key(i).as_string() == key &&
					root.get_object_value(i).get_type() == sajson::TYPE_STRING)
				return root.get_object_value(i).as_string();
		}
		return "";
	}
	ss_ read_render_mode()
	{
		return read_setting("render_mode");
	}
	// The viewing range ([VIEW_RANGE]): "view_range": "<n>", 120 when
	// absent so a new install bets on no strong computer; 20..4000 as
	// official's
	// view_bobbing_amount ([VIEW_BOB]): 1 unless set, 0 off; BUILDAT_VIEW_BOBBING
	// for one run, which is how the reference shooters keep their probes still
	ss_ read_view_bobbing()
	{
		const char *env = getenv("BUILDAT_VIEW_BOBBING");
		const ss_ v = env ? ss_(env) : read_setting("view_bobbing_amount");
		const double n = atof(v.c_str());
		if(v.empty() || n < 0 || n > 7.9)
			return "1";
		char buf[16];
		snprintf(buf, sizeof buf, "%g", n);
		return buf;
	}
	// How far full detail reaches, as a share of the viewing range
	// ([CLIENT_FRAME]): "distant_detail": "full" | "half" | "third".
	// Beyond it voxelworld meshes chunks at a reduced LOD, which is how a
	// machine whose GPU is slower than its processor keeps its range --
	// LOD spends CPU to buy triangles back. "full" is the default (user,
	// 2026-10-08, [LOD_FULL_DEFAULT]): the reduced LOD's texture scale and
	// detail do not follow the distance as the voxels' do, and the sense
	// of scale goes. The key was "lod_detail", which every save of the
	// settings screen wrote as "half" while that was the default; it is
	// not read, so nobody keeps a reduction they never picked.
	ss_ read_lod_detail()
	{
		const char *env = getenv("BUILDAT_LOD_DETAIL");
		const ss_ v = env ? ss_(env) : read_setting("distant_detail");
		return (v == "half" || v == "third") ? v : ss_("full");
	}
	ss_ read_view_range()
	{
		// BUILDAT_VIEW_RANGE for one run: the reference shooters set their
		// range this way, over whatever the user's settings.json says
		const char *env = getenv("BUILDAT_VIEW_RANGE");
		const ss_ v = env ? ss_(env) : read_setting("view_range");
		const int n = atoi(v.c_str());
		return (n >= 20 && n <= 4000) ? itos(n) : ss_("120");
	}
	// "web_view_range": the web client's viewing range unless its player
	// chose one (user, 2026-09-30): a browser meshes on one thread and
	// loads a world slower. "" when not set, and the client's own default
	// (80, 60 on a touchscreen) holds; never over view_range either way.
	ss_ read_web_view_range()
	{
		const int n = atoi(read_setting("web_view_range").c_str());
		return (n >= 20 && n <= 4000) ? itos(n) : ss_();
	}
	// The key bindings ([KEY_BINDINGS]): settings.json's "keys" object,
	// action to key name, as "key.<action>=<name>" rows of the list
	sv_<ss_> read_key_rows()
	{
		sv_<ss_> out;
		std::ifstream f(settings_path());
		if(!f.good())
			return out;
		std::stringstream ss;
		ss << f.rdbuf();
		const ss_ text = ss.str();
		const sajson::document doc =
				sajson::parse(sajson::dynamic_allocation(),
					sajson::string(text.c_str(), text.size()));
		if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_OBJECT)
			return out;
		sajson::value root = doc.get_root();
		for(size_t i = 0; i < root.get_length(); i++){
			if(root.get_object_key(i).as_string() != "keys")
				continue;
			sajson::value keys = root.get_object_value(i);
			if(keys.get_type() != sajson::TYPE_OBJECT)
				continue;
			for(size_t j = 0; j < keys.get_length(); j++){
				sajson::value v = keys.get_object_value(j);
				if(v.get_type() == sajson::TYPE_STRING && !v.as_string().empty())
					out.push_back("key."+keys.get_object_key(j).as_string()+
							"="+v.as_string());
			}
		}
		return out;
	}
	static void write_json_string(std::ofstream &f, const ss_ &s)
	{
		f << '"';
		for(char c : s){
			if(c == '"' || c == '\\')
				f << '\\' << c;
			else if((unsigned char)c < 0x20)
				f << ' ';
			else
				f << c;
		}
		f << '"';
	}
	void write_settings(const ss_ &mode,
			const sv_<std::pair<ss_, ss_>> &keys, const ss_ &view_range,
			const ss_ &view_bobbing, const ss_ &shoulder,
			const ss_ &lod_detail)
	{
		// Set by hand only, so kept through the settings screen's save
		const ss_ web_range = read_web_view_range();
		interface::fs::create_directories(luanti_path());
		std::ofstream f(settings_path(), std::ios::trunc);
		f << "{\"render_mode\": \"" << mode << "\", \"view_range\": \""
				<< view_range << "\", ";
		if(!web_range.empty())
			f << "\"web_view_range\": \"" << web_range << "\", ";
		f << "\"distant_detail\": \""
				<< lod_detail << "\", \"view_bobbing_amount\": \""
				<< view_bobbing << "\", \"third_person_shoulder\": \""
				<< shoulder << "\", \"keys\": {";
		for(size_t i = 0; i < keys.size(); i++){
			f << (i ? ", " : "");
			write_json_string(f, keys[i].first);
			f << ": ";
			write_json_string(f, keys[i].second);
		}
		f << "}}\n";
		if(!f.good())
			log_w(MODULE, "could not write %s", cs(settings_path()));
	}
	void send_settings(network::PeerInfo::Id peer)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			sv_<ss_> list;
			ss_ mode = read_render_mode();
			list.push_back("render_mode="+(mode.empty() ? ss_("pbr") : mode));
			list.push_back("view_range="+read_view_range());
			const ss_ web_range = read_web_view_range();
			if(!web_range.empty())
				list.push_back("web_view_range="+web_range);
			list.push_back("lod_detail="+read_lod_detail());
			list.push_back("view_bobbing_amount="+read_view_bobbing());
			// The back view centred or over the shoulder ([OVER_SHOULDER])
			list.push_back("third_person_shoulder="+
					(read_setting("third_person_shoulder") == "1" ?
					ss_("1") : ss_("0")));
			for(const ss_ &row : read_key_rows())
				list.push_back(row);
			ar(list);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:settings", os.str());
		});
	}
	// ContentDB ([CONTENTDB]): a browser of its games, the server fetching
	// through libcurl on a thread per job -- a listing, an install -- and
	// on_tick() reading the finished ones. The listing is the API's
	// packages query, games only, sent to the client as five strings a
	// row; an install takes the newest release's zip into the cache and
	// extracts it under luanti/games/<name>, the way an import lands.
	static const char *CONTENTDB;
	struct Job : public interface::ThreadedThing {
		enum Kind { LIST, INSTALL, PICTURE, DEPS } kind;
		network::PeerInfo::Id peer;
		// LIST: the query; INSTALL, DEPS: author/name; PICTURE: the url
		ss_ q;
		// INSTALL: the directory; PICTURE: the client file; LIST: the game
		// whose mods are listed, as ContentDB's author/name or a gameid to
		// look up ([WORLD_MODS])
		ss_ name;
		// LIST, INSTALL: "game", "mod" or "txp"; DEPS, INSTALL: the world's game
		ss_ type = "game", gameid;
		// DEPS: the mod names already there, the game's and the server's;
		// the packages picked for the rest, author/name
		std::set<ss_> provided;
		sv_<ss_> picks;
		ss_ zip_path, into_dir;
		ss_ result, error;
		// INSTALL: what it may take ([SAVE_LIMIT]), and what to say past it
		int64_t room = INT64_MAX;
		ss_ no_room;
		std::atomic<uint64_t> got{0}, total{0};
		// INSTALL: 0 downloading, 1 unpacking, 2 installing -- the screen
		// says which, since the unpack of a big game is seconds of nothing
		// at "100 %" otherwise ([BOX_PLAYTEST_2] 5)
		std::atomic<int> phase{0};
		std::atomic<bool> done{false};
		interface::Thread *thread = nullptr;
		void run(interface::Thread *) override
		{
			try {
				if(kind == LIST){
					// Twenty, the most downloaded first: the whole list is
					// hundreds and the screen has no pages yet (the search
					// field narrows it). Mods for a game only, by the API's
					// game filter, which wants the game's package name: a
					// gameid not installed from ContentDB is looked up
					ss_ game = name;
					if(!game.empty() && game.find('/') == ss_::npos)
						game = find_package(game);
					result = interface::http_get(ss_(CONTENTDB)+
							"/api/packages/?type="+type+"&limit=20&sort=downloads"
							"&order=desc&q="+q+(game.empty() ? "" : "&game="+game));
				} else if(kind == DEPS){
					resolve_deps();
				} else if(kind == PICTURE){
					// A picture already fetched is not fetched again; the
					// cache path is the download's ([CONTENTDB_LIST])
					if(!interface::fs::path_exists(zip_path))
						interface::http_download(q, zip_path);
				} else {
					const ss_ rel = interface::http_get(ss_(CONTENTDB)+
							"/api/packages/"+q+"/releases/");
					const ss_ url = newest_release_url(rel);
					if(url.empty())
						throw Exception("no release to download");
					bool too_big = false;
					try {
						interface::http_download(url, zip_path,
								[&](uint64_t g, uint64_t t){
							got = g; total = t;
							too_big = (int64_t)std::max(g, t) > room;
							return !too_big;
						});
					} catch(std::exception &e){
						interface::fs::remove_all(zip_path);
						throw Exception(too_big ? no_room : ss_(e.what()));
					}
					phase = 1;
					interface::fs::remove_all(into_dir);
					interface::zip_extract(zip_path, into_dir);
					phase = 2;
					const int64_t took = (int64_t)interface::fs::
							directory_tree_size(into_dir) +
							(int64_t)interface::fs::file_size(zip_path);
					interface::fs::remove_all(zip_path);
					if(took > room){
						interface::fs::remove_all(into_dir);
						throw Exception(no_room);
					}
				}
			} catch(std::exception &e){
				error = e.what();
			}
			done = true;
		}
		void on_crash(interface::Thread *) override
		{
			error = "the fetch crashed";
			done = true;
		}
		// A game's package for its gameid: the type=game search's row of
		// that exact name, or ""
		static ss_ find_package(const ss_ &gameid)
		{
			const ss_ json = interface::http_get(ss_(CONTENTDB)+
					"/api/packages/?type=game&q="+gameid);
			const sajson::document doc =
					sajson::parse(sajson::dynamic_allocation(),
					sajson::string(json.c_str(), json.size()));
			if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_ARRAY)
				return "";
			for(size_t i = 0; i < doc.get_root().get_length(); i++){
				sajson::value r = doc.get_root().get_array_element(i);
				if(r.get_type() != sajson::TYPE_OBJECT)
					continue;
				ss_ author, name;
				for(size_t j = 0; j < r.get_length(); j++){
					sajson::value v = r.get_object_value(j);
					if(v.get_type() != sajson::TYPE_STRING)
						continue;
					if(r.get_object_key(j).as_string() == "author")
						author = v.as_string();
					else if(r.get_object_key(j).as_string() == "name")
						name = v.as_string();
				}
				if(name == gameid && !author.empty())
					return author+"/"+name;
			}
			return "";
		}
		// [WORLD_MODS] The hard dependencies of q that nothing provides, a
		// package picked for each, and theirs in turn. The API's answer
		// is keyed by package and holds the ones it would pick too; one
		// picked here that it does not hold is asked for. A package of
		// the dependency's name is picked first, by q's author before
		// others, else ContentDB's first; one with none is an error.
		void resolve_deps()
		{
			struct Dep { ss_ name; sv_<ss_> packages; };
			std::map<ss_, sv_<Dep>> known;
			auto fetch = [&](const ss_ &pkg){
				const ss_ json = interface::http_get(ss_(CONTENTDB)+
						"/api/packages/"+pkg+"/dependencies/?only_hard=1");
				const sajson::document doc =
						sajson::parse(sajson::dynamic_allocation(),
						sajson::string(json.c_str(), json.size()));
				if(!doc.is_valid() ||
						doc.get_root().get_type() != sajson::TYPE_OBJECT)
					throw Exception("ContentDB's dependencies of "+pkg+
							" are not readable");
				sajson::value root = doc.get_root();
				for(size_t i = 0; i < root.get_length(); i++){
					sv_<Dep> &deps = known[root.get_object_key(i).as_string()];
					deps.clear();
					sajson::value list = root.get_object_value(i);
					if(list.get_type() != sajson::TYPE_ARRAY)
						continue;
					for(size_t j = 0; j < list.get_length(); j++){
						sajson::value d = list.get_array_element(j);
						if(d.get_type() != sajson::TYPE_OBJECT)
							continue;
						Dep dep;
						bool optional = false;
						for(size_t k = 0; k < d.get_length(); k++){
							const ss_ key = d.get_object_key(k).as_string();
							sajson::value v = d.get_object_value(k);
							if(key == "name" && v.get_type() == sajson::TYPE_STRING)
								dep.name = v.as_string();
							else if(key == "is_optional")
								optional = v.get_type() == sajson::TYPE_TRUE;
							else if(key == "packages" &&
									v.get_type() == sajson::TYPE_ARRAY){
								for(size_t m = 0; m < v.get_length(); m++)
									if(v.get_array_element(m).get_type() ==
											sajson::TYPE_STRING)
										dep.packages.push_back(
												v.get_array_element(m).as_string());
							}
						}
						if(!optional && !dep.name.empty())
							deps.push_back(dep);
					}
				}
				if(!known.count(pkg))
					known[pkg];
			};
			const ss_ author = q.substr(0, q.find('/'));
			sv_<ss_> queue{q};
			for(size_t at = 0; at < queue.size(); at++){
				const ss_ pkg = queue[at];
				if(!known.count(pkg))
					fetch(pkg);
				for(const Dep &dep : known[pkg]){
					if(provided.count(dep.name))
						continue;
					if(dep.packages.empty())
						throw Exception(dep.name+", which "+pkg.substr(
								pkg.find('/') + 1)+" needs, is not on ContentDB");
					ss_ pick;
					for(int pass = 0; pass < 2 && pick.empty(); pass++)
						for(const ss_ &p : dep.packages)
							if(pick.empty() && p.substr(p.find('/') + 1) ==
									dep.name && (pass == 1 ||
									p.substr(0, p.find('/')) == author))
								pick = p;
					if(pick.empty())
						pick = dep.packages[0];
					provided.insert(dep.name);
					picks.push_back(pick);
					queue.push_back(pick);
				}
			}
		}
		// The releases list is newest first; "url" is the zip, absolute
		// or site-relative
		static ss_ newest_release_url(const ss_ &json)
		{
			const sajson::document doc =
					sajson::parse(sajson::dynamic_allocation(),
					sajson::string(json.c_str(), json.size()));
			if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_ARRAY ||
					doc.get_root().get_length() == 0)
				return "";
			sajson::value r = doc.get_root().get_array_element(0);
			if(r.get_type() != sajson::TYPE_OBJECT)
				return "";
			for(size_t i = 0; i < r.get_length(); i++){
				if(r.get_object_key(i).as_string() == "url" &&
						r.get_object_value(i).get_type() == sajson::TYPE_STRING){
					ss_ u = r.get_object_value(i).as_string();
					if(!u.empty() && u[0] == '/')
						u = ss_(CONTENTDB)+u;
					return u;
				}
			}
			return "";
		}
	};
	// The thread owns its Job (interface::Thread deletes the thing it
	// ran); this list is the jobs still to be read
	sv_<Job*> m_contentdb_jobs;

	static ss_ url_encode(const ss_ &s)
	{
		ss_ out;
		char buf[4];
		for(unsigned char c : s){
			if(isalnum(c) || c == '-' || c == '_' || c == '.')
				out += (char)c;
			else {
				snprintf(buf, sizeof buf, "%%%02X", c);
				out += buf;
			}
		}
		return out;
	}

	void start_job(Job *job)
	{
		job->thread = interface::createThread(job);
		job->thread->set_name("contentdb");
		job->thread->start();
		m_contentdb_jobs.push_back(job);
	}

	void on_contentdb_query(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:contentdb_query: %s", e.what());
			return;
		}
		Job *job = new Job();
		job->kind = Job::LIST;
		job->peer = packet.sender;
		job->q = url_encode(values.empty() ? "" : values[0].substr(0, 200));
		// [WORLD_MODS] {query, "mod", gameid}: mods, for that game when it
		// is installed here, by the package it came from if ContentDB's
		if(values.size() >= 3 && values[1] == "mod"){
			job->type = "mod";
			const ss_ game = find_game(values[2]);
			if(!game.empty()){
				std::ifstream f(game+"/.buildat_source");
				ss_ source;
				std::getline(f, source);
				job->name = source.compare(0, 10, "contentdb:") == 0 ?
						url_encode_path(source.substr(10)) : values[2];
			}
		}
		// [WORLD_TXP] {query, "txp"}: texture packs, for any game
		if(values.size() >= 2 && values[1] == "txp")
			job->type = "txp";
		start_job(job);
	}
	// author/name, each half encoded
	static ss_ url_encode_path(const ss_ &s)
	{
		const size_t slash = s.find('/');
		return slash == ss_::npos ? url_encode(s) :
				url_encode(s.substr(0, slash))+"/"+url_encode(s.substr(slash + 1));
	}

	void on_contentdb_install(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:contentdb_install: %s", e.what());
			return;
		}
		if(values.size() < 2)
			return;
		// [WORLD_MODS] {author, name, "mod", gameid}: what it needs is
		// asked about first; {..., "confirmed", author, name, ...}
		// installs it and those
		if(values.size() >= 4 && values[2] == "mod"){
			if(values.size() == 4){
				mod_install_ask(packet.sender, values[0], values[1], values[3]);
				return;
			}
			for(size_t i = 5; i + 1 < values.size(); i += 2)
				contentdb_install(packet.sender, values[i], values[i + 1], "mod");
			contentdb_install(packet.sender, values[0], values[1], "mod");
			return;
		}
		// [WORLD_TXP] {author, name, "txp"}
		contentdb_install(packet.sender, values[0], values[1],
				values.size() >= 3 && values[2] == "txp" ? "txp" : "game");
	}

	// A ContentDB name is a directory: letters, digits, _ and - only
	static bool contentdb_name_ok(const ss_ &v)
	{
		if(v.empty())
			return false;
		for(char c : v)
			if(!isalnum((unsigned char)c) && c != '_' && c != '-')
				return false;
		return true;
	}

	// The mod's hard dependencies that neither the world's game nor an
	// installed mod gives, found on a thread; poll_contentdb() asks the
	// client about them, or installs at once when there are none
	void mod_install_ask(network::PeerInfo::Id peer, const ss_ &author,
			const ss_ &name, const ss_ &gameid)
	{
		if(!contentdb_name_ok(author) || !contentdb_name_ok(name)){
			menu_error(peer, "Not a ContentDB name: "+author+"/"+name);
			return;
		}
		if(interface::fs::path_exists(mods_path()+"/"+name)){
			menu_error(peer, name+" is already installed");
			return;
		}
		Job *job = new Job();
		job->kind = Job::DEPS;
		job->peer = peer;
		job->q = author+"/"+name;
		job->gameid = gameid;
		sv_<ModInfo> mods;
		const ss_ game = find_game(gameid);
		if(!game.empty())
			scan_mods(game+"/mods", "", mods);
		scan_all_mods(mods);
		for(const ModInfo &m : mods)
			job->provided.insert(m.name);
		send_progress(peer, "Asking ContentDB what "+name+" needs...");
		start_job(job);
	}

	void contentdb_install(network::PeerInfo::Id peer, const ss_ &author,
			const ss_ &name, const ss_ &type = "game")
	{
		// Who asked, as the packet's handler had it
		const network::Packet packet(peer, "", "");
		// A name is a directory: letters, digits, _ and - only
		for(const ss_ *v : {&author, &name}){
			for(char c : *v){
				if(!isalnum((unsigned char)c) && c != '_' && c != '-'){
					menu_error(packet.sender, "Not a ContentDB name: "+*v);
					return;
				}
			}
		}
		const ss_ to = install_root(type)+"/"+name;
		if(interface::fs::path_exists(to)){
			menu_error(packet.sender, name+" is already installed. Remove "+
					where(to)+" yourself if you mean to replace it.");
			return;
		}
		const ss_ full = no_room();
		if(!full.empty()){
			menu_error(packet.sender, full+". Delete a world or a game first.");
			return;
		}
		Job *job = new Job();
		job->kind = Job::INSTALL;
		job->peer = packet.sender;
		job->q = author+"/"+name;
		job->name = name;
		job->type = type;
		storage::access(m_server, [&](storage::Interface *i){
			job->room = i->room_bytes();
		});
		job->no_room = no_room(INT64_MAX);
		const ss_ cache = m_server->get_config().get<ss_>("cache_path")+
				"/luanti/contentdb";
		interface::fs::create_directories(cache);
		job->zip_path = cache+"/"+author+"_"+name+".zip";
		// A mod's outside mods/, where the loader would find it half done
		job->into_dir = type == "mod" ? luanti_path()+"/mods.installing/"+
				name : type == "txp" ? luanti_path()+
				"/texture_packs.installing/"+name : to+".installing";
		send_progress(packet.sender, "Fetching "+name+"...");
		start_job(job);
	}

	// The finished jobs answered, the running installs' progress told
	void poll_contentdb()
	{
		for(size_t i = 0; i < m_contentdb_jobs.size(); ){
			Job *job = m_contentdb_jobs[i];
			if(!job->done){
				if(job->kind == Job::INSTALL && job->phase == 1)
					send_progress(job->peer, "Unpacking "+job->name+"...");
				else if(job->kind == Job::INSTALL && job->phase == 2)
					send_progress(job->peer, "Installing "+job->name+"...");
				else if(job->kind == Job::INSTALL && job->total > 0){
					send_progress(job->peer, "Downloading "+job->name+": "+
							itos(job->got * 100 / job->total)+"%");
				}
				i++;
				continue;
			}
			m_contentdb_jobs.erase(m_contentdb_jobs.begin() + i);
			job->thread->request_stop();
			job->thread->join();
			// The job's fields read before the thread (and with it the
			// job) is deleted at the end of the block
			struct Free { interface::Thread *t; ~Free(){ delete t; } } free{job->thread};
			if(job->peer == 0 && job->kind == Job::LIST){
				log_i(MODULE, "contentdb: fetched once: %s",
						job->error.empty() ? cs("ok, "+itos(job->result.size())+
						" bytes") : cs("error: "+job->error));
				continue;
			}
			if(!job->error.empty() && job->kind == Job::PICTURE){
				// A picture that does not come leaves its placeholder
				log_v(MODULE, "contentdb: no picture %s: %s", cs(job->name),
						cs(job->error));
				interface::fs::remove_all(job->zip_path);
				continue;
			}
			if(!job->error.empty()){
				if(job->kind == Job::INSTALL)
					log_i(MODULE, "Installing %s failed: %s", cs(job->name),
							cs(job->error));
				menu_error(job->peer, (job->kind == Job::LIST ?
						"ContentDB: " : "Installing "+job->name+" failed: ")+
						job->error);
				continue;
			}
			if(job->kind == Job::LIST){
				send_contentdb_list(job->peer, job->result);
				continue;
			}
			if(job->kind == Job::DEPS){
				const size_t slash = job->q.find('/');
				const ss_ author = job->q.substr(0, slash),
						name = job->q.substr(slash + 1);
				if(job->picks.empty()){
					contentdb_install(job->peer, author, name, "mod");
					continue;
				}
				// The question, with the picks: {author, name, gameid,
				// author, name, ...}
				sv_<ss_> flat{author, name, job->gameid};
				for(const ss_ &p : job->picks){
					flat.push_back(p.substr(0, p.find('/')));
					flat.push_back(p.substr(p.find('/') + 1));
				}
				log_i(MODULE, "contentdb: %s needs %zu more", cs(job->q),
						job->picks.size());
				send_strings(job->peer, "main:contentdb_deps", flat);
				continue;
			}
			if(job->kind == Job::PICTURE){
				// The file to every client, the name to the one that asked:
				// its row asks the cache for it until it has arrived
				client_file::access(m_server, [&](client_file::Interface *i){
					i->add_file_path(job->name, job->zip_path);
				});
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar(sv_<ss_>{job->name});
				}
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(job->peer, "main:contentdb_picture", os.str());
				});
				continue;
			}
			// The zip's one top-level directory is the game; renamed into
			// place, and the game shows on the grid as an imported one does.
			// A mod's zip may hold the mod at its top ([WORLD_MODS])
			ss_ top;
			size_t tops = 0;
			for(const auto &n : interface::fs::list_directory(job->into_dir)){
				// A dot-name is nobody's game: what a zip carries beside it,
				// or what something left ([CONTENTDB_FRESH])
				if(n.is_directory && !n.name.empty() && n.name[0] != '.'){
					top = n.name;
					tops++;
				}
			}
			const ss_ to = install_root(job->type)+"/"+job->name;
			const bool at_top = interface::fs::path_exists(job->into_dir+
					"/init.lua") || interface::fs::path_exists(job->into_dir+
					"/modpack.conf") || interface::fs::path_exists(job->into_dir+
					"/game.conf") || interface::fs::path_exists(job->into_dir+
					"/texture_pack.conf");
			const ss_ from = tops == 1 && !at_top ? job->into_dir+"/"+top :
					job->into_dir;
			interface::fs::create_directories(interface::fs::strip_file_name(to));
			if(rename(from.c_str(), to.c_str()) != 0){
				menu_error(job->peer, "Installing "+job->name+" failed: cannot "
						"rename "+where(from));
				continue;
			}
			if(from != job->into_dir)
				interface::fs::remove_all(job->into_dir);
			// Where it came from, for the client's Discuss to name the game
			// to a Hearth ([OVERLAY_DISCUSS])
			std::ofstream(to+"/.buildat_source") << "contentdb:" << job->q;
			log_i(MODULE, "Installed %s %s from ContentDB", cs(job->type),
					cs(job->name));
			storage::access(m_server, [&](storage::Interface *i){
				i->remeasure();
			});
			menu_message(job->peer, job->name+" installed from ContentDB");
		}
	}

	// Five strings a row: author, name, title, short_description, thumbnail
	void send_contentdb_list(network::PeerInfo::Id peer, const ss_ &json)
	{
		sv_<ss_> flat;
		const sajson::document doc =
				sajson::parse(sajson::dynamic_allocation(),
				sajson::string(json.c_str(), json.size()));
		if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_ARRAY){
			menu_error(peer, "ContentDB answered with something that is not "
					"a list");
			return;
		}
		sajson::value root = doc.get_root();
		for(size_t i = 0; i < root.get_length(); i++){
			sajson::value r = root.get_array_element(i);
			if(r.get_type() != sajson::TYPE_OBJECT)
				continue;
			ss_ f[5];
			static const char *keys[5] = {"author", "name", "title",
					"short_description", "thumbnail"};
			for(size_t j = 0; j < r.get_length(); j++){
				const ss_ k = r.get_object_key(j).as_string();
				sajson::value v = r.get_object_value(j);
				if(v.get_type() != sajson::TYPE_STRING)
					continue;
				for(size_t n = 0; n < 5; n++)
					if(k == keys[n])
						f[n] = v.as_string();
			}
			for(size_t n = 0; n < 5; n++)
				flat.push_back(f[n]);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:contentdb_list", os.str());
		});
		// The pictures after the list, one job each, so a slow one holds
		// nothing but its own row ([CONTENTDB_LIST]); on the wire the row
		// names its picture "contentdb/<author>_<name>.png"
		const ss_ cache = m_server->get_config().get<ss_>("cache_path")+
				"/luanti/contentdb";
		interface::fs::create_directories(cache);
		for(size_t i = 0; i + 4 < flat.size(); i += 5){
			ss_ url = flat[i + 4];
			if(url.empty())
				continue;
			if(url[0] == '/')
				url = ss_(CONTENTDB)+url;
			bool word = true;
			for(const ss_ *v : {&flat[i], &flat[i + 1]})
				for(char c : *v)
					if(!isalnum((unsigned char)c) && c != '_' && c != '-')
						word = false;
			if(!word)
				continue;
			Job *job = new Job();
			job->kind = Job::PICTURE;
			job->peer = peer;
			job->q = url;
			job->name = "contentdb/"+flat[i]+"_"+flat[i + 1]+".png";
			job->zip_path = cache+"/"+flat[i]+"_"+flat[i + 1]+".png";
			start_job(job);
		}
	}

	void send_strings(network::PeerInfo::Id peer, const ss_ &name,
			const sv_<ss_> &values)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, name, os.str());
		});
	}

	// Where ContentDB's installs of a type go
	ss_ install_root(const ss_ &type)
	{
		return type == "mod" ? mods_path() : type == "txp" ? txp_path() :
				luanti_path()+"/games";
	}

	// [WORLD_TXP] The server's texture packs, under luanti/texture_packs,
	// and each world's one of them in its world.mt as
	// buildat_texture_pack; the luanti module serves that one's files in
	// place of the game's (builtin/luanti/media.h)
	ss_ txp_path()
	{
		return luanti_path()+"/texture_packs";
	}
	sv_<ss_> worlds_with_txp(const ss_ &name)
	{
		sv_<ss_> out;
		sv_<storage::SaveInfo> infos;
		storage::access(m_server, [&](storage::Interface *istorage){
			infos = istorage->list();
		});
		for(const storage::SaveInfo &info : infos){
			ss_ path;
			if(info.name.empty() || info.name[0] == '_' ||
					!save_dir(info.name, path))
				continue;
			if(read_world_mt(path+"/luanti/world.mt")["buildat_texture_pack"] ==
					name)
				out.push_back(info.name);
		}
		return out;
	}
	// main:world_txp {save, note, the world's pack ("" none), whether
	// "Restart now" is offered, then the installed packs' names}
	void send_world_txp(network::PeerInfo::Id peer, const ss_ &save,
			const ss_ &note)
	{
		ss_ path;
		if(!save_dir(save, path)){
			send_strings(peer, "main:world_txp", {save, "No such world.",
					"", "0"});
			return;
		}
		sv_<ss_> flat{save, note,
				read_world_mt(path+"/luanti/world.mt")["buildat_texture_pack"],
				m_public && save == m_world_name ? "1" : "0"};
		sv_<ss_> names;
		for(const auto &n : interface::fs::list_directory(txp_path()))
			if(n.is_directory && contentdb_name_ok(n.name))
				names.push_back(n.name);
		std::sort(names.begin(), names.end());
		flat.insert(flat.end(), names.begin(), names.end());
		send_strings(peer, "main:world_txp", flat);
	}
	// main:get_world_txp {save}
	void on_get_world_txp(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(!values.empty())
			send_world_txp(packet.sender, values[0], "");
	}
	// main:set_world_txp {save, name or "" for none}: from the world's
	// next start, as a mod
	void on_set_world_txp(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path;
		if(values.size() < 2 || !save_dir(values[0], path))
			return;
		const ss_ &name = values[1];
		if(!name.empty() && (!contentdb_name_ok(name) ||
				!interface::fs::path_exists(txp_path()+"/"+name)))
			return send_world_txp(packet.sender, values[0], name+
					" is not installed.");
		write_world_mt(path+"/luanti/world.mt",
				{{"buildat_texture_pack", name}});
		log_i(MODULE, "World %s: texture pack %s", cs(values[0]),
				cs(name.empty() ? "none" : name));
		send_world_txp(packet.sender, values[0], (name.empty() ?
				ss_("No texture pack") : name)+" from the world's next start.");
	}
	// main:remove_txp {save, name}: to the trash, as a mod; not while a
	// world has it
	void on_remove_txp(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.size() < 2 || !contentdb_name_ok(values[1]))
			return;
		const ss_ dir = txp_path()+"/"+values[1];
		if(!interface::fs::path_exists(dir))
			return send_world_txp(packet.sender, values[0], values[1]+
					" is not installed.");
		ss_ users;
		for(const ss_ &w : worlds_with_txp(values[1]))
			users += (users.empty() ? "" : ", ")+w;
		if(!users.empty())
			return send_world_txp(packet.sender, values[0], values[1]+
					" is not removed: the texture pack of "+users+".");
		const ss_ trash = luanti_path()+"/trash";
		interface::fs::create_directories(trash);
		time_t now = time(NULL);
		char date[32];
		strftime(date, sizeof date, "%Y-%m-%d_%H%M%S", localtime(&now));
		const ss_ to = trash+"/txp_"+values[1]+"-"+date;
		if(rename(dir.c_str(), to.c_str()) != 0)
			return send_world_txp(packet.sender, values[0], "Could not move "+
					where(dir)+" to "+where(to));
		log_i(MODULE, "Texture pack %s moved to %s", cs(values[1]), cs(to));
		send_world_txp(packet.sender, values[0], values[1]+
				" moved to the trash.");
	}

	// [WORLD_MODS] The server's mods, under luanti/mods as the games are
	// under luanti/games, and each world's choice of them in its world.mt
	// as Luanti writes it: load_mod_<name> = true or false. The luanti
	// module's modloader.lua loads the chosen ones.
	ss_ mods_path()
	{
		return luanti_path()+"/mods";
	}
	struct ModInfo {
		ss_ name, pack, dir; // pack: the modpack's directory name, or ""
		sv_<ss_> depends;
		bool builtin = false; // comes with Buildat
	};
	// The mods that come with Buildat ([BUILDAT_WIELD_LIGHT]), then the
	// installed ones: what a world can turn on, as modloader.lua loads them
	void scan_all_mods(sv_<ModInfo> &out)
	{
		const size_t from = out.size();
		scan_mods(m_server->get_module_path("luanti")+"/mods", "", out);
		for(size_t i = from; i < out.size(); i++)
			out[i].builtin = true;
		scan_mods(mods_path(), "", out);
	}
	// The wield lights that write the map's light, which wield_light
	// replaces: a world with one is recommended wield_light
	static bool writes_wield_light(const ss_ &mod)
	{
		for(const char *n : {"vl_wieldlight", "mcl_wieldlight", "wielded_light",
				"cozylights", "illumination", "tph_wielditem", "nc_api_active"})
			if(mod == n)
				return true;
		return false;
	}
	// Every mod under path as modlist.lua finds them: a directory with an
	// init.lua is a mod, named by its mod.conf; any other is looked into.
	// simplified: a multi-line depends in mod.conf is read as its first
	// line (modlist.lua reads it whole, and loads by that)
	static void scan_mods(const ss_ &path, const ss_ &pack,
			sv_<ModInfo> &out, int depth = 0)
	{
		if(depth > 3)
			return;
		for(const auto &n : interface::fs::list_directory(path)){
			if(!n.is_directory || n.name.empty() || n.name[0] == '.')
				continue;
			const ss_ dir = path+"/"+n.name;
			if(!interface::fs::path_exists(dir+"/init.lua")){
				scan_mods(dir, depth == 0 ? n.name : pack, out, depth + 1);
				continue;
			}
			std::map<ss_, ss_> conf = read_world_mt(dir+"/mod.conf");
			ModInfo m;
			m.name = conf.count("name") ? conf["name"] : n.name;
			m.pack = pack;
			m.dir = dir;
			ss_ deps = conf["depends"];
			if(!conf.count("depends") && !conf.count("optional_depends")){
				std::ifstream f(dir+"/depends.txt");
				ss_ line;
				while(std::getline(f, line))
					if(line.find('?') == ss_::npos)
						deps += ","+line;
			}
			std::istringstream is(deps);
			ss_ d;
			while(std::getline(is, d, ',')){
				const size_t a = d.find_first_not_of(" \t\r");
				const size_t b = d.find_last_not_of(" \t\r");
				if(a != ss_::npos)
					m.depends.push_back(d.substr(a, b - a + 1));
			}
			if(mod_name_ok(m.name))
				out.push_back(m);
		}
	}
	static bool mod_name_ok(const ss_ &name)
	{
		return !name.empty() && name.find_first_not_of(
				"abcdefghijklmnopqrstuvwxyz0123456789_") == ss_::npos;
	}
	// The worlds whose world.mt turns the mod on
	sv_<ss_> worlds_enabling(const ss_ &mod)
	{
		sv_<ss_> out;
		sv_<storage::SaveInfo> infos;
		storage::access(m_server, [&](storage::Interface *istorage){
			infos = istorage->list();
		});
		for(const storage::SaveInfo &info : infos){
			ss_ path;
			if(info.name.empty() || info.name[0] == '_' ||
					!save_dir(info.name, path))
				continue;
			if(read_world_mt(path+"/luanti/world.mt")["load_mod_"+mod] == "true")
				out.push_back(info.name);
		}
		return out;
	}
	// main:world_mods {save, note, gameid, whether "Restart now" is
	// offered, then per row: name, modpack ("" for none, the pack's own
	// row has its own name), state ("1" on, "0" off, "pack", "missing"),
	// the hard dependencies the game does not give, comma-separated}
	void send_world_mods(network::PeerInfo::Id peer, const ss_ &save,
			const ss_ &note)
	{
		ss_ path, gameid;
		if(!save_dir(save, path, &gameid)){
			send_strings(peer, "main:world_mods", {save, "No such world.",
					"", "0"});
			return;
		}
		std::map<ss_, ss_> mt = read_world_mt(path+"/luanti/world.mt");
		std::set<ss_> game_mods;
		{
			sv_<ModInfo> g;
			const ss_ game = find_game(gameid);
			if(!game.empty())
				scan_mods(game+"/mods", "", g);
			for(const ModInfo &m : g)
				game_mods.insert(m.name);
		}
		sv_<ModInfo> mods;
		scan_all_mods(mods);
		std::sort(mods.begin(), mods.end(), [](const ModInfo &a,
				const ModInfo &b){
			return (a.pack.empty() ? a.name : a.pack+"/"+a.name) <
					(b.pack.empty() ? b.name : b.pack+"/"+b.name);
		});
		sv_<ss_> flat{save, note, gameid, m_public && save == m_world_name ?
				"1" : "0"};
		// The game's or a turned-on mod's own wield light, for the row of
		// the one that replaces it
		ss_ wield;
		for(const ss_ &n : game_mods)
			if(writes_wield_light(n))
				wield += (wield.empty() ? "" : ", ")+n;
		for(const ModInfo &m : mods)
			if(writes_wield_light(m.name) && mt["load_mod_"+m.name] == "true")
				wield += (wield.empty() ? "" : ", ")+m.name;
		std::set<ss_> installed;
		ss_ pack;
		for(const ModInfo &m : mods){
			installed.insert(m.name);
			// A builtin row: state "b1" or "b0", and in place of its
			// dependencies what it is recommended for
			if(m.builtin){
				const bool on = mt["load_mod_"+m.name] == "true";
				for(const ss_ &v : {m.name, ss_(), ss_(on ? "b1" : "b0"),
						ss_(m.name == "wield_light" && !wield.empty() ?
						wield : "")})
					flat.push_back(v);
				continue;
			}
			if(!m.pack.empty() && m.pack != pack)
				for(const ss_ &v : {m.pack, m.pack, ss_("pack"), ss_()})
					flat.push_back(v);
			pack = m.pack;
			ss_ deps;
			for(const ss_ &d : m.depends)
				if(!game_mods.count(d))
					deps += (deps.empty() ? "" : ",")+d;
			for(const ss_ &v : {m.name, m.pack,
					ss_(mt["load_mod_"+m.name] == "true" ? "1" : "0"), deps})
				flat.push_back(v);
		}
		for(const auto &kv : mt){
			if(kv.first.compare(0, 9, "load_mod_") != 0 || kv.second != "true")
				continue;
			const ss_ name = kv.first.substr(9);
			if(!installed.count(name) && !game_mods.count(name))
				for(const ss_ &v : {name, ss_(), ss_("missing"), ss_()})
					flat.push_back(v);
		}
		send_strings(peer, "main:world_mods", flat);
	}
	// What keeps a world's mods from loading: one with a game mod's name,
	// or a hard dependency nothing gives. "" when they load (a cycle is
	// left to modlist.lua to say).
	ss_ world_mods_problem(const ss_ &game_path, const ss_ &save_path)
	{
		sv_<ModInfo> game, extra, installed;
		scan_mods(game_path+"/mods", "", game);
		scan_mods(save_path+"/luanti/worldmods", "", extra);
		scan_all_mods(installed);
		std::map<ss_, ss_> mt = read_world_mt(save_path+"/luanti/world.mt");
		for(const ModInfo &m : installed)
			if(mt["load_mod_"+m.name] == "true")
				extra.push_back(m);
		std::set<ss_> names;
		for(const ModInfo &m : game)
			names.insert(m.name);
		for(const ModInfo &m : extra)
			if(names.count(m.name))
				return "the mod "+m.name+" has the name of one of the game's";
		for(const ModInfo &m : extra)
			names.insert(m.name);
		ss_ out;
		for(const ModInfo &m : extra)
			for(const ss_ &d : m.depends)
				if(!names.count(d))
					out += (out.empty() ? "" : "; ")+m.name+" needs "+d;
		return out.empty() ? "" : "its mods cannot load: "+out+
				", not installed or not turned on (Mods...)";
	}
	// main:get_world_mods {save}
	void on_get_world_mods(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(!values.empty())
			send_world_mods(packet.sender, values[0], "");
	}
	// main:set_world_mods {save, name, "1" or "0"}: a modpack's name turns
	// its every mod; turning one on turns on the installed mods it needs,
	// and one it needs that is not installed is said and nothing changes
	void on_set_world_mods(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path, gameid;
		if(values.size() < 3 || !save_dir(values[0], path, &gameid))
			return;
		const bool on = values[2] == "1";
		sv_<ModInfo> mods, game;
		scan_all_mods(mods);
		if(!find_game(gameid).empty())
			scan_mods(find_game(gameid)+"/mods", "", game);
		std::set<ss_> game_mods;
		for(const ModInfo &m : game)
			game_mods.insert(m.name);
		std::map<ss_, ss_> set;
		sv_<ss_> todo;
		for(const ModInfo &m : mods)
			if(m.name == values[1] || m.pack == values[1])
				todo.push_back(m.name);
		ss_ also, missing;
		for(size_t i = 0; i < todo.size(); i++){
			if(set.count("load_mod_"+todo[i]))
				continue;
			set["load_mod_"+todo[i]] = on ? "true" : "false";
			if(i > 0)
				also += (also.empty() ? "" : ", ")+todo[i];
			if(!on)
				continue;
			for(const ModInfo &m : mods){
				if(m.name != todo[i])
					continue;
				for(const ss_ &d : m.depends){
					bool have = game_mods.count(d) > 0;
					for(const ModInfo &o : mods)
						if(o.name == d){
							have = true;
							todo.push_back(d);
						}
					if(!have)
						missing += (missing.empty() ? "" : ", ")+d;
				}
			}
		}
		if(todo.empty())
			return send_world_mods(packet.sender, values[0], values[1]+
					" is not installed.");
		if(!missing.empty())
			return send_world_mods(packet.sender, values[0], values[1]+
					" needs "+missing+", not installed here. Nothing changed.");
		write_world_mt(path+"/luanti/world.mt", set);
		log_i(MODULE, "%s: mod %s %s%s", cs(values[0]), cs(values[1]),
				on ? "on" : "off", also.empty() ? "" : cs(", and "+also));
		send_world_mods(packet.sender, values[0], ss_(on ? "On" : "Off")+
				": "+values[1]+(also.empty() ? "" : ", with "+also)+
				". It takes effect at the world's next start.");
	}
	// main:remove_mod {save, name}: a mod or modpack under luanti/mods to
	// its trash, when no world turns it on
	void on_remove_mod(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.size() < 2)
			return;
		sv_<ModInfo> mods;
		scan_mods(mods_path(), "", mods);
		ss_ dir, users;
		for(const ModInfo &m : mods){
			if(m.name != values[1] && m.pack != values[1])
				continue;
			dir = m.pack.empty() ? m.dir : mods_path()+"/"+m.pack;
			for(const ss_ &w : worlds_enabling(m.name))
				users += (users.find(w) != ss_::npos ? "" :
						ss_(users.empty() ? "" : ", ")+w);
		}
		if(dir.empty())
			return send_world_mods(packet.sender, values[0], values[1]+
					" is not installed.");
		if(!users.empty())
			return send_world_mods(packet.sender, values[0], values[1]+
					" is not removed: on in "+users+".");
		const ss_ trash = luanti_path()+"/trash";
		interface::fs::create_directories(trash);
		time_t now = time(NULL);
		char date[32];
		strftime(date, sizeof date, "%Y-%m-%d_%H%M%S", localtime(&now));
		const ss_ to = trash+"/mod_"+values[1]+"-"+date;
		if(rename(dir.c_str(), to.c_str()) != 0)
			return send_world_mods(packet.sender, values[0], "Could not move "+
					where(dir)+" to "+where(to));
		log_i(MODULE, "Mod %s moved to %s", cs(values[1]), cs(to));
		send_world_mods(packet.sender, values[0], values[1]+
				" moved to the trash.");
	}
	// main:restart_world {save}: the running world of a public server
	// started again, as switch_world() does another
	// simplified: a launcher's own game is left and played again; a
	// restart of its process waits for [VANILLA_STOP]
	void on_restart_world(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
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
		if(!may_manage(packet.sender) || !m_public || !m_scene)
			return;
		const ss_ who = m_names[packet.sender];
		log_i(MODULE, "%s stops the world %s", cs(who), cs(m_world_name));
		luanti::access(m_server, [&](luanti::Interface *i){
			i->chat_send("", who+" stops the server's world");
		});
		write_public_world("", "Stopped by an admin ("+who+")");
		m_restart_in = 1.5f;
	}

	void on_get_settings(const network::Packet &packet)
	{
		send_settings(packet.sender);
	}
	// The whole list, replacing what was there: the screen adds and
	// removes, and sends the result
	void on_set_settings(const network::Packet &packet)
	{
		if(!local_only(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:set_settings: %s", e.what());
			return;
		}
		sv_<std::pair<ss_, ss_>> keys;
		ss_ mode = "pbr";
		ss_ view_range = "120";
		ss_ view_bobbing = "1";
		ss_ shoulder = "0";
		ss_ lod_detail = "full";
		for(const ss_ &v : values){
			if(v.compare(0, 22, "third_person_shoulder=") == 0){
				shoulder = v.substr(22) == "1" ? "1" : "0";
				continue;
			}
			if(v.compare(0, 20, "view_bobbing_amount=") == 0){
				const double n = atof(v.c_str() + 20);
				if(n >= 0 && n <= 7.9){
					char buf[16];
					snprintf(buf, sizeof buf, "%g", n);
					view_bobbing = buf;
				}
				continue;
			}
			if(v.compare(0, 12, "render_mode=") == 0){
				const ss_ m = v.substr(12);
				if(m == "unlit" || m == "shadows" || m == "pbr")
					mode = m;
			} else if(v.compare(0, 11, "view_range=") == 0){
				const int n = atoi(v.c_str() + 11);
				if(n >= 20 && n <= 4000)
					view_range = itos(n);
			} else if(v.compare(0, 11, "lod_detail=") == 0){
				const ss_ d = v.substr(11);
				if(d == "full" || d == "half" || d == "third")
					lod_detail = d;
			} else if(v.compare(0, 4, "key.") == 0){
				// key.<action>=<name>: the action a word, the name short
				const size_t eq = v.find('=');
				if(eq != ss_::npos && eq > 4 && v.size() - eq - 1 <= 32){
					const ss_ action = v.substr(4, eq - 4);
					bool word = true;
					for(char c : action)
						if(!isalnum((unsigned char)c) && c != '_')
							word = false;
					if(word)
						keys.push_back({action, v.substr(eq + 1)});
				}
			}
			// Anything else is ignored: the import search paths went with
			// the import folder ([LUANTI_IMPORT_FOLDER])
		}
		write_settings(mode, keys, view_range, view_bobbing, shoulder,
				lod_detail);
		log_i(MODULE, "settings: render_mode %s, view_range "
				"%s and %zu key bindings written to %s", cs(mode),
				cs(view_range), keys.size(), cs(settings_path()));
		send_settings(packet.sender);
	}

	ss_ import_folder()
	{
		return luanti_path()+"/import";
	}

	// Whether a directory can be listed: one the box denies lists as empty,
	// as an empty one does
	static bool listable(const ss_ &path)
	{
#ifdef _WIN32
		// simplified: not told apart on Windows, where an empty listing is
		// said as one; FindFirstFile's error is the upgrade
		(void)path;
		return true;
#else
		DIR *d = opendir(path.c_str());
		if(!d)
			return false;
		closedir(d);
		return true;
#endif
	}

	sv_<ss_> import_roots()
	{
		sv_<ss_> out;
		// Said out loud, every one of them: a wrong variable name, a typo, a
		// path that is not there and a directory at the wrong level of a
		// tree all look the same from the menu -- a short list and no
		// reason -- and that is what turns a one-word mistake into a bug
		// report. This is a menu action rather than a loop, so the lines
		// cost nothing.
		auto add = [&](const ss_ &path, const ss_ &from){
			if(path.empty())
				return;
			if(!interface::fs::path_exists(path)){
				log_i(MODULE, "import: %s: no such path (%s)", cs(path),
						cs(from));
				return;
			}
			for(const ss_ &had : out){
				if(had == path){
					log_i(MODULE, "import: %s: already looked at (%s)",
							cs(path), cs(from));
					return;
				}
			}
			const bool has_games =
					interface::fs::path_exists(path+"/games");
			const bool has_worlds =
					interface::fs::path_exists(path+"/worlds");
			if(!has_games && !has_worlds){
				// Which is what pointing the variable at the wrong level of
				// a tree looks like, and the likeliest mistake after the
				// name of the variable itself
				log_w(MODULE, "import: %s has neither games/ nor worlds/ in "
						"it; a Luanti user directory has both (%s)",
						cs(path), cs(from));
			} else {
				log_i(MODULE, "import: %s (%s)%s%s", cs(path), cs(from),
						has_games ? " games/" : "",
						has_worlds ? " worlds/" : "");
			}
			out.push_back(path);
		};
		// **The import folder** ([LUANTI_IMPORT_FOLDER]): the server's box
		// grants nothing under /home, so ~/.minetest and ~/.luanti are not
		// read; the user copies a game, a world or a whole Luanti user
		// directory in here. Then the variable, for the shell and the
		// runners, which reaches only what the box grants
		add(import_folder(), "the import folder");
		const char *extra = getenv("LUANTI_EXTRA_IMPORT_PATH");
		if(extra && extra[0]){
			// Several, separated the way every other path variable does it
			ss_ rest = extra;
			while(!rest.empty()){
				size_t colon = rest.find(':');
				ss_ one = colon == ss_::npos ? rest : rest.substr(0, colon);
				add(one, "LUANTI_EXTRA_IMPORT_PATH");
				rest = colon == ss_::npos ? "" : rest.substr(colon + 1);
			}
		}
		// The two variables are one word apart in meaning and that is the
		// trap: BUILDAT_LUANTI_IMPORT names one world to import at startup,
		// and a tree with worlds/ in it is somebody who meant the search
		// path
		const char *old_import = getenv("BUILDAT_LUANTI_IMPORT");
		if(old_import && old_import[0] &&
				interface::fs::path_exists(ss_(old_import)+"/worlds")){
			log_w(MODULE, "import: BUILDAT_LUANTI_IMPORT=%s has a worlds/ in "
					"it, so it names a Luanti installation rather than one "
					"world. The search path the import menu reads is "
					"LUANTI_EXTRA_IMPORT_PATH.", old_import);
		}
		return out;
	}

	// game.conf's name, which is the title to show; the directory's name is
	// the gameid and is what the game is installed as
	static ss_ read_game_title(const ss_ &game_path)
	{
		return read_conf_value(game_path+"/game.conf", {"name", "title"});
	}

	// The first of `keys` a Luanti .conf file sets, or ""
	static ss_ read_conf_value(const ss_ &file, const sv_<ss_> &keys)
	{
		std::ifstream f(file);
		if(!f.good())
			return "";
		ss_ line;
		while(std::getline(f, line)){
			size_t eq = line.find('=');
			if(eq == ss_::npos)
				continue;
			ss_ key = line.substr(0, eq);
			ss_ value = line.substr(eq + 1);
			auto trim = [](ss_ &s){
				while(!s.empty() && isspace((unsigned char)s.front()))
					s.erase(s.begin());
				while(!s.empty() && isspace((unsigned char)s.back()))
					s.pop_back();
			};
			trim(key);
			trim(value);
			if(std::find(keys.begin(), keys.end(), key) != keys.end())
				return value;
		}
		return "";
	}

	// The mapgens a new world of this game may have, the one it gets
	// unless told otherwise first: Luanti's world-creation dialog offers
	// game.conf's allowed_mapgens less its disallowed_mapgens and selects
	// the game's minetest.conf mg_name ([GAME_CONF_MAPGENS]). In the menu's
	// order, official's default first.
	static sv_<ss_> game_mapgens(const ss_ &game_path)
	{
		auto list = [&](const char *key){
			std::set<ss_> out;
			std::istringstream is(read_conf_value(game_path+"/game.conf", {key}));
			ss_ name;
			while(std::getline(is, name, ',')){
				name.erase(0, name.find_first_not_of(" \t"));
				name.erase(name.find_last_not_of(" \t") + 1);
				if(!name.empty())
					out.insert(name);
			}
			return out;
		};
		const std::set<ss_> allowed = list("allowed_mapgens");
		const std::set<ss_> disallowed = list("disallowed_mapgens");
		sv_<ss_> out;
		for(const char *name : {"v7", "v5", "valleys", "carpathian", "flat",
				"fractal", "v6", "singlenode"})
			if((allowed.empty() || allowed.count(name)) && !disallowed.count(name))
				out.push_back(name);
		const ss_ chosen = read_conf_value(game_path+"/minetest.conf", {"mg_name"});
		auto it = std::find(out.begin(), out.end(), chosen);
		if(it != out.end())
			std::rotate(out.begin(), it, it + 1);
		return out;
	}

	// A game to import, found by its id. The first root that has one wins,
	// which is the order import_roots() is in. Empty when there is none --
	// the client names what it wants and the server finds it again, because
	// a path that arrives over the network is not a path to copy.
	ss_ find_importable_game(const ss_ &gameid)
	{
		if(gameid.empty() || gameid.find('/') != ss_::npos ||
				gameid.find("..") != ss_::npos)
			return "";
		for(const ss_ &root : import_roots()){
			ss_ path = root+"/games/"+gameid;
			if(interface::fs::path_exists(path+"/game.conf"))
				return path;
		}
		return "";
	}

	// And a world, the same way
	ss_ find_importable_world(const ss_ &name)
	{
		if(name.empty() || name.find('/') != ss_::npos ||
				name.find("..") != ss_::npos)
			return "";
		for(const ss_ &root : import_roots()){
			ss_ path = root+"/worlds/"+name;
			if(interface::fs::path_exists(path+"/world.mt"))
				return path;
		}
		return "";
	}

	// What is out there to import, as one flat array: the count of games and
	// of worlds left out for having no gameid, then the games, then the
	// worlds. A game is its id, its title, whether it is installed already,
	// how big it is and the root it is in; a world is its name, the game it
	// wants, whether that game is installed, how big it is and its root.
	//
	// The size is there because buildat's own game menu shows one and
	// because it is what says whether a copy is a moment or a minute. The
	// whole search path is walked for it, which was measured at a third of a
	// second over two hundred and fifty directories.
	void on_get_imports(const network::Packet &packet)
	{
		if(!local_only(packet.sender))
			return;
		sv_<ss_> games;
		sv_<ss_> worlds;
		sv_<ss_> installed = list_apps();
		auto is_installed = [&](const ss_ &gameid){
			for(const ss_ &id : installed){
				if(id == gameid)
					return true;
			}
			return false;
		};
		sv_<ss_> seen_games, seen_worlds;
		size_t no_gameid = 0;
		// Made for the user to copy into, the shape of a Luanti user
		// directory
		interface::fs::create_directories(import_folder()+"/games");
		interface::fs::create_directories(import_folder()+"/worlds");
		auto seen = [](sv_<ss_> &list, const ss_ &name){
			for(const ss_ &had : list){
				if(had == name)
					return true;
			}
			list.push_back(name);
			return false;
		};
		const sv_<ss_> roots = import_roots();
		for(const ss_ &root : roots){
			for(const char *sub : {"/games", "/worlds"}){
				if(interface::fs::path_exists(root+sub) &&
						!listable(root+sub))
					log_w(MODULE, "import: %s%s cannot be read; its contents "
							"are not listed", cs(root), sub);
			}
			for(const interface::fs::Node &n :
					interface::fs::list_directory(root+"/games")){
				if(!n.is_directory || n.name == "." || n.name == "..")
					continue;
				ss_ path = root+"/games/"+n.name;
				if(!interface::fs::path_exists(path+"/game.conf"))
					continue;
				// The first root that has a game is the one that would be
				// copied, so a later one is not offered twice
				if(seen(seen_games, n.name))
					continue;
				games.push_back(n.name);
				games.push_back(read_game_title(path));
				games.push_back(is_installed(n.name) ? "installed" : "");
				games.push_back(itos(
						interface::fs::directory_tree_size(path)));
				games.push_back(root);
			}
			for(const interface::fs::Node &n :
					interface::fs::list_directory(root+"/worlds")){
				if(!n.is_directory || n.name == "." || n.name == "..")
					continue;
				ss_ path = root+"/worlds/"+n.name;
				ss_ gameid = read_gameid(path);
				if(gameid.empty()){
					log_i(MODULE, "import: %s has no gameid in world.mt; "
							"not listed", cs(path));
					no_gameid++;
					continue;
				}
				if(seen(seen_worlds, n.name))
					continue;
				worlds.push_back(n.name);
				worlds.push_back(gameid);
				worlds.push_back(is_installed(gameid) ? "installed" : "");
				worlds.push_back(itos(
						interface::fs::directory_tree_size(path)));
				worlds.push_back(root);
			}
		}
		// One line a user can read: "0 games and 0 worlds from 2 roots" says
		// in one go that it is the path and not the feature
		log_i(MODULE, "import: %zu games and %zu worlds from %zu roots, %zu "
				"worlds with no gameid", games.size() / 5, worlds.size() / 5,
				roots.size(), no_gameid);
		// The two counts, then five strings a game and five a world: its
		// id or name, its title or game, "installed" or "", its size and
		// the root it is in
		sv_<ss_> flat;
		flat.push_back(itos(games.size() / 5));
		flat.push_back(itos(no_gameid));
		for(const ss_ &v : games)
			flat.push_back(v);
		for(const ss_ &v : worlds)
			flat.push_back(v);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "main:imports", os.str());
		});
	}

	// One line to whoever is waiting, which is the same channel the mod
	// loading uses; see start_world()
	void send_progress(network::PeerInfo::Id peer, const ss_ &line)
	{
		if(peer == 0)
			return;
		sv_<ss_> values{line};
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		const ss_ data = os.str();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:progress", data);
		});
	}

	// Everything under from into to, saying how far along it is every so
	// often. Returns false on the first file it cannot write, because half a
	// game installed is worse than none.
	bool copy_tree(const ss_ &from, const ss_ &to, size_t &done, size_t total,
			network::PeerInfo::Id peer, ss_ &error)
	{
		if(!interface::fs::create_directories(to)){
			error = "cannot make "+to;
			return false;
		}
		for(const interface::fs::Node &n :
				interface::fs::list_directory(from)){
			if(n.name == "." || n.name == "..")
				continue;
			const ss_ src = from+"/"+n.name;
			const ss_ dst = to+"/"+n.name;
			if(n.is_directory){
				if(!copy_tree(src, dst, done, total, peer, error))
					return false;
				continue;
			}
			if(!interface::fs::copy_file(src, dst)){
				error = "cannot copy "+src;
				return false;
			}
			done++;
			// Not every file: a game is thousands of them and a line per
			// file is more work than the copying
			if(done % 200 == 0 || done == total){
				send_progress(peer, "Copying: "+itos(done)+"/"+itos(total)+
						" files");
			}
		}
		return true;
	}

	static size_t count_files(const ss_ &path)
	{
		size_t n = 0;
		for(const interface::fs::Node &node :
				interface::fs::list_directory(path)){
			if(node.name == "." || node.name == "..")
				continue;
			if(node.is_directory)
				n += count_files(path+"/"+node.name);
			else
				n++;
		}
		return n;
	}

	// A game is copied into buildat's own games directory, and **refuses to
	// overwrite one that is there**: removing an installed game is the
	// user's own business outside buildat. Copying over the top would leave
	// a file the game deleted upstream behind forever, and deleting first is
	// a recursive delete under user/ driven by a menu.
	void on_import_game(const network::Packet &packet)
	{
		if(!local_only(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:import_game: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		const ss_ gameid = values[0];
		const ss_ from = find_importable_game(gameid);
		if(from.empty()){
			menu_error(packet.sender, "There is no game called "+gameid+
					" to import");
			return;
		}
		const ss_ to = luanti_path()+"/games/"+gameid;
		if(interface::fs::path_exists(to)){
			menu_error(packet.sender, gameid+" is already installed. Remove "+
					to+" yourself if you mean to replace it.");
			return;
		}
		log_i(MODULE, "Importing game %s from %s", cs(gameid), cs(from));
		send_progress(packet.sender, "Copying "+gameid+"...");
		const size_t total = count_files(from);
		size_t done = 0;
		ss_ error;
		// Into a directory of its own beside the destination first, so that
		// a copy that fails half way does not look like an installed game
		const ss_ partial = to+".importing";
		if(!copy_tree(from, partial, done, total, packet.sender, error)){
			menu_error(packet.sender, "Importing "+gameid+" failed: "+error);
			return;
		}
		if(rename(partial.c_str(), to.c_str()) != 0){
			menu_error(packet.sender, "Importing "+gameid+" failed: cannot "
					"rename "+partial);
			return;
		}
		log_i(MODULE, "Imported game %s: %zu files", cs(gameid), done);
		menu_message(packet.sender, gameid+" imported: "+itos(done)+" files");
	}

	// A world is not copied: it becomes a save, through the importer that
	// BUILDAT_LUANTI_IMPORT already drives. What the button adds is the
	// picking and the name.
	void on_import_world(const network::Packet &packet)
	{
		if(!local_only(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:import_world: %s", e.what());
			return;
		}
		if(values.size() < 2)
			return;
		const ss_ world_name = values[0];
		const ss_ from = find_importable_world(world_name);
		if(from.empty()){
			menu_error(packet.sender, "There is no world called "+world_name+
					" to import");
			return;
		}
		const ss_ err = import_luanti_world(packet.sender, from, world_name,
				values[1]);
		if(!err.empty())
			menu_error(packet.sender, err);
	}
	// A Luanti world's folder into a new save, and the world started: the
	// import folder's and a zip's ([WORLD_TRIM_MOVE]). An error's text, or
	// "" once it is under way.
	ss_ import_luanti_world(network::PeerInfo::Id peer, const ss_ &from,
			const ss_ &world_name, const ss_ &save_name)
	{
		const ss_ gameid = read_gameid(from);
		if(find_game(gameid).empty())
			return world_name+" wants the game "+gameid+", which is not "
					"installed. Import that first.";
		bool valid = false;
		storage::access(m_server, [&](storage::Interface *istorage){
			valid = istorage->valid_name(save_name);
		});
		if(!valid)
			return "\""+save_name+"\" is not a name a save can have";
		const ss_ full = no_room();
		if(!full.empty())
			return full+". Delete a world or a game first.";
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->create(save_name);
			if(save){
				save->store("main")->set("gameid", gameid);
				istorage->close(save);
			}
		});
		if(!save)
			return "There is already a save called "+save_name;
		log_i(MODULE, "Importing world %s from %s into save %s",
				cs(world_name), cs(from), cs(save_name));
		start_world(gameid, save_name, peer, from);
		return "";
	}

	// Opening one that is there, and making one that is not. Split on
	// purpose: a typo in a name cannot silently start a new game instead of
	// opening the old one.
	void on_open(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
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
		ss_ gameid = gameid_of_save(name);
		if(gameid == ""){
			menu_error(packet.sender, "The save "+name+" does not say which"
					" game it needs");
			return;
		}
		if(m_public && m_starting){
			if(name == m_world_name)
				return menu_message(packet.sender, name+" is running already");
			return switch_world(name, packet.sender);
		}
		start_world(gameid, name, packet.sender);
	}

	// The mapgens Luanti ships. A world's mg_name comes from the menu, so
	// it is checked against this before it is written into world.mt
	// ([NEW_WORLD_FORM]).
	static bool is_mapgen_name(const ss_ &name)
	{
		for(const char *n : {"v7", "v5", "valleys", "carpathian", "flat",
				"fractal", "v6", "singlenode"}){
			if(name == n)
				return true;
		}
		return false;
	}

	void on_create(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
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
			menu_error(packet.sender, "\""+name+"\" is not a name a save can"
					" have");
			return;
		}
		if(find_game(gameid).empty()){
			menu_error(packet.sender, "There is no game called "+gameid);
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
				menu_error(packet.sender, "A seed is one line of text");
				return;
			}
		}
		const ss_ full = no_room();
		if(!full.empty()){
			menu_error(packet.sender, full+". Delete a world or a game first.");
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
			menu_error(packet.sender, "There is already a save called "+name);
			return;
		}
		// While a world runs, one world at a time: made, and run by
		// switching to it (a launcher's game: by the launcher, through
		// its menu's Play, [PAUSE_WORLDS_LOCAL])
		if(m_starting){
			menu_message(packet.sender, "The world "+name+" was made: run it "
					"to switch to it");
			return;
		}
		start_world(gameid, name, packet.sender);
	}

	// The same dialog for something that went right, which is not a warning
	// in the log and is otherwise the same thing
	// A message is news -- a game installed, a world imported -- shown
	// over the list it changed; an error is a dialog the user has to
	// close ([FIRST_RUN]: a driven run fails on any dialog, so news is
	// not one)
	void menu_message(network::PeerInfo::Id peer, const ss_ &message)
	{
		log_i(MODULE, "%s", cs(message));
		send_menu_message(peer, message, "main:menu_message");
	}

	void menu_error(network::PeerInfo::Id peer, const ss_ &message)
	{
		log_w(MODULE, "%s", cs(message));
		send_menu_message(peer, message, "main:menu_error");
	}

	void send_menu_message(network::PeerInfo::Id peer, const ss_ &message,
			const ss_ &packet = "main:menu_error")
	{
		if(peer == 0)
			return;
		sv_<ss_> values;
		values.push_back(message);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, packet, os.str());
		});
	}

	// The client's loading screen has ended (load_wait_end()): the player
	// goes in, seen and hit and their game's join callbacks run
	void on_world_in(const network::Packet &packet)
	{
		if(!m_loading.count(packet.sender))
			return;
		log_i(MODULE, "Client %u: main:world_in", (unsigned)packet.sender);
		put_in_world(packet.sender);
	}

	void put_in_world(network::PeerInfo::Id peer)
	{
		m_loading.erase(peer);
		m_in_world.insert(peer);
		const bool admin = m_public && is_admin(peer);
		luanti::access(m_server, [&](luanti::Interface *i){
			i->add_player(player_name_of(peer), peer);
			if(admin)
				i->set_admin(player_name_of(peer), true);
		});
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
		// ([JOIN_WHEN_LOADED]), see on_world_in()
		luanti::access(m_server, [&](luanti::Interface *i){
			i->place_player(player_name_of(peer), peer);
		});
		m_loading[peer] = 0;
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_scene, peer);
		});
	}

	// Under the user path, not the cache: a Luanti game the user installed
	// and a world they have played are things they chose, and the cache is
	// what the program can recreate by itself. See
	// doc/plan/world_persistence_plan.md. What vanilla shares with other
	// apps, read-only to them ([PROCESS_SANDBOX]): the games, the texture
	// packs, settings.json. Was <user>/luanti, moved at start by
	// interface::fs::migrate_user_apps().
	ss_ luanti_path()
	{
		return m_server->get_config().get<ss_>("user_path")+"/shared/vanilla";
	}
	// The imported Luanti worlds are vanilla's own: they hold their
	// players' password hashes
	ss_ worlds_path()
	{
		return m_server->get_config().get<ss_>("user_path")+"/apps/vanilla/worlds";
	}

	// world.mt's gameid, or "" for a directory that has no world.mt
	static ss_ read_gameid(const ss_ &world_path)
	{
		std::ifstream f(world_path+"/world.mt");
		if(!f.good())
			return "";
		ss_ line;
		while(std::getline(f, line)){
			size_t eq = line.find('=');
			if(eq == ss_::npos)
				continue;
			ss_ key = line.substr(0, eq);
			ss_ value = line.substr(eq + 1);
			auto trim = [](ss_ &s){
				while(!s.empty() && isspace((unsigned char)s.front()))
					s.erase(s.begin());
				while(!s.empty() && isspace((unsigned char)s.back()))
					s.pop_back();
			};
			trim(key);
			trim(value);
			// Minetest Game's worlds were made as "minetest", which is
			// minetest_game since 5.8, as Luanti reads it too
			// ([LUANTI_IMPORT_FOLDER])
			if(key == "gameid")
				return value == "minetest" ? ss_("minetest_game") : value;
		}
		return "";
	}

	sv_<World> list_worlds()
	{
		sv_<World> worlds;
		ss_ dir = worlds_path();
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(!n.is_directory || n.name == "." || n.name == "..")
				continue;
			World w;
			w.name = n.name;
			w.path = dir+"/"+n.name;
			w.gameid = read_gameid(w.path);
			if(w.gameid == ""){
				log_w(MODULE, "%s has no world.mt; skipping", cs(w.path));
				continue;
			}
			worlds.push_back(w);
		}
		return worlds;
	}

	// buildat ships one Luanti game of its own, so that the module can be run
	// and looked at without a Luanti installation. It is also what the visual
	// check uses, since a fixture somebody has to install is a fixture that
	// is different on every machine.
	ss_ bundled_game_path()
	{
		return m_server->get_module_path("luanti")+"/minimal_game";
	}

	ss_ find_game(const ss_ &gameid)
	{
		// A directory's name and nothing else: a client sends it, and
		// "../.." was any directory with a game.conf, whose mods then ran
		// ([SECURITY_RUN_1])
		if(gameid.empty() || gameid.find_first_not_of(
				"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
				"0123456789_-") != ss_::npos)
			return "";
		ss_ path = luanti_path()+"/games/"+gameid;
		if(interface::fs::path_exists(path+"/game.conf"))
			return path;
		if(gameid == "minimal"){
			path = bundled_game_path();
			if(interface::fs::path_exists(path+"/game.conf"))
				return path;
		}
		return "";
	}

	// Without one of these the game waits for a menu choice; with one it
	// runs what the environment says, which is what every check here does.
	void on_start()
	{
		// A transfer a stopped server was in the middle of
		end_transfer();
		m_public = launch_param("launcher") != "1";
		if(m_public)
			log_i(MODULE, "A public server: clients join by account, and the "
					"worlds are the admins'");
		// BUILDAT_LUANTI_FETCH_ONCE: one ContentDB listing at start, its
		// outcome logged and sent to nobody -- the smoke's way of running
		// http_get, whose std::call_once died on the box through a
		// winpthreads linked into Urho3D.dll ([WIN8_START] 16); a fetch
		// that errors is a fetch that ran
		if(getenv("BUILDAT_LUANTI_FETCH_ONCE")){
			Job *job = new Job();
			job->kind = Job::LIST;
			job->peer = 0;
			job->q = "";
			start_job(job);
			log_i(MODULE, "contentdb: fetching once, for the log");
		}
		// BUILDAT_CONTENTDB_INSTALL_ONCE=author/name: an install at start,
		// its outcome logged ([SAVE_LIMIT]'s check)
		if(const char *once = getenv("BUILDAT_CONTENTDB_INSTALL_ONCE")){
			const ss_ q = once;
			const size_t slash = q.find('/');
			if(slash != ss_::npos)
				contentdb_install(0, q.substr(0, slash), q.substr(slash + 1));
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
		if(m_public && !read_public_world().empty() &&
				!gameid_of_save(read_public_world()).empty()){
			// The world an admin chose ([VANILLA_PUBLIC] 5), over the
			// environment, which is then the first boot's
			world_name = read_public_world();
			gameid = gameid_of_save(world_name);
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
			for(const World &w : list_worlds()){
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
				menu_error(peer, "A world is already starting");
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
			menu_error(peer, message);
		};
		ss_ game_path = find_game(gameid);
		if(game_path.empty()){
			refuse("World "+world_name+" wants game "+gameid+
					", which is not in "+where(luanti_path()+"/games"));
			return;
		}
		// [WORLD_MODS] A world whose mods cannot load does not start, and
		// the menu says why, as Luanti refuses it
		{
			ss_ save_path;
			const ss_ problem = save_dir(world_name, save_path) ?
					world_mods_problem(game_path, save_path) : "";
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
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "launch:reusable", "0");
			});
		}
		if(m_public)
			write_public_world(world_name);

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
			menu_error(peer, message);
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
					!copy_tree(import_from+"/worldmods", wm, done, 0, peer,
					error))
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
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(peer, "main:progress", data);
				});
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
			i->load_lua("core.__luanti_mods_path = [==["+mods_path()+"]==]",
					"vanilla_mods");
			apply_default_preset(save->path());
			i->run_game(game_path, save);
		});
	}
};

// BUILDAT_CONTENTDB_URL: a mirror in a test ([FIRST_RUN]: a directory
// served by python3 -m http.server, made by util/contentdb_mirror.sh),
// since the real one over the network in a daily run is a flake
const char *Module::CONTENTDB = getenv("BUILDAT_CONTENTDB_URL") ?
		getenv("BUILDAT_CONTENTDB_URL") : "https://content.luanti.org";

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
