// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [VANILLA_MODULAR] **What every part of vanilla reaches for**: the
// paths under user/luanti and the games and worlds there, a save's
// directory and its world.mt, the menu's messages and a packet's strings,
// the room left on the disk, the public server's chosen world. Free
// functions, of the server alone.
// Included by main.cpp inside namespace vanilla, after struct World
#pragma once

// A public server's chat: the lines a player may send at once before
// the limit, one a second after (on_chat(), and the world's own,
// set_chat_limit())
static constexpr double CHAT_BURST = 5;

// A save a world may be: not _server, which is builtin/accounts', nor
// any other name beginning with _
static bool is_world_name(const ss_ &name)
{
	return !name.empty() && name[0] != '_';
}

// The launcher's own client, on the launcher's server
static bool is_owner(interface::Server *server, network::PeerInfo::Id peer)
{
	bool local = false;
	accounts::access(server, [&](accounts::Interface *i){
		local = i->is_local(peer);
	});
	return local;
}

// [VANILLA_PUBLIC] 5: the world a public server runs, which an admin
// chose and it starts at boot
static ss_ public_world_file(interface::Server *server)
{
	return server->get_config().get<ss_>("user_path")+"/apps/"+
			server->get_app_id()+"/public_world";
}

static ss_ read_public_world(interface::Server *server)
{
	std::ifstream f(public_world_file(server));
	ss_ name;
	std::getline(f, name);
	return is_world_name(name) ? name : "";
}

// note: [VANILLA_STOP] who stopped it, on the line after an empty name
static void write_public_world(interface::Server *server, const ss_ &name,
		const ss_ &note = "")
{
	interface::fs::create_directories(
			interface::fs::strip_file_name(public_world_file(server)));
	std::ofstream f(public_world_file(server));
	f<<name<<"\n"<<note<<"\n";
}

static ss_ read_stop_note(interface::Server *server)
{
	std::ifstream f(public_world_file(server));
	ss_ name, note;
	std::getline(f, name);
	std::getline(f, note);
	return name.empty() ? note : "";
}

// What a player who may not talk is told, "" if they may. Static: the
// world's chat asks it on builtin/luanti's thread
static ss_ chat_refusal(interface::Server *server, size_t peer,
		const ss_ &name)
{
	ss_ why;
	chat::access(server, [&](chat::Interface *i){
		i->may_talk(peer, name, &why);
	});
	return why;
}

// A save records which Luanti game it needs, as a key in the save rather
// than in a world.mt: which save and which game it needs were always two
// facts pretending to be one.
static ss_ gameid_of_save(interface::Server *server, const ss_ &name)
{
	ss_ gameid;
	storage::access(server, [&](storage::Interface *istorage){
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

// The save's directory, and its gameid when asked, or false
static bool save_dir(interface::Server *server, const ss_ &name, ss_ &path,
		ss_ *gameid = nullptr)
{
	if(!is_world_name(name))
		return false;
	storage::access(server, [&](storage::Interface *istorage){
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

static sv_<ss_> read_packet_strings(const network::Packet &packet)
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

// [SAVE_LIMIT] Empty with room for need more bytes, else why not
static ss_ no_room(interface::Server *server, int64_t need = 0)
{
	int64_t used = 0, limit = 0, room = 0;
	storage::access(server, [&](storage::Interface *i){
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

static ss_ mb_text(int64_t bytes)
{
	char buf[32];
	snprintf(buf, sizeof buf, "%.1f MB", bytes / 1000000.0);
	return buf;
}

// name, or name_2, _3... where no save is
static ss_ free_save_name(interface::Server *server, const ss_ &name)
{
	ss_ path;
	for(int i = 1; i < 1000; i++){
		const ss_ n = i == 1 ? name : name+"_"+itos(i);
		bool valid = false;
		storage::access(server, [&](storage::Interface *istorage){
			valid = istorage->valid_name(n);
		});
		if(!valid)
			return "";
		path.clear();
		if(!save_dir(server, n, path) && !interface::fs::path_exists(
				server->get_config().get<ss_>("user_path")+"/apps/"+
				server->get_app_id()+"/saves/"+n))
			return n;
	}
	return "";
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

static void send_strings(interface::Server *server, network::PeerInfo::Id peer,
		const ss_ &name,
		const sv_<ss_> &values)
{
	std::ostringstream os(std::ios::binary);
	{
		cereal::PortableBinaryOutputArchive ar(os);
		ar(values);
	}
	network::send(server, peer, name, os.str());
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

// game.conf's name, which is the title to show; the directory's name is
// the gameid and is what the game is installed as
static ss_ read_game_title(const ss_ &game_path)
{
	return read_conf_value(game_path+"/game.conf", {"name", "title"});
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
	for(const char *name : {"valleys", "v7", "v5", "carpathian", "flat",
			"fractal", "v6", "singlenode"})
		if((allowed.empty() || allowed.count(name)) && !disallowed.count(name))
			out.push_back(name);
	const ss_ chosen = read_conf_value(game_path+"/minetest.conf", {"mg_name"});
	auto it = std::find(out.begin(), out.end(), chosen);
	if(it != out.end())
		std::rotate(out.begin(), it, it + 1);
	return out;
}

// One line to whoever is waiting, which is the same channel the mod
// loading uses; see start_world()
static void send_progress(interface::Server *server, network::PeerInfo::Id peer,
		const ss_ &line)
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
	network::send(server, peer, "main:progress", data);
}

// Everything under from into to, saying how far along it is every so
// often. Returns false on the first file it cannot write, because half a
// game installed is worse than none.
static bool copy_tree(interface::Server *server, const ss_ &from, const ss_ &to,
		size_t &done, size_t total,
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
			if(!copy_tree(server, src, dst, done, total, peer, error))
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
			send_progress(server, peer, "Copying: "+itos(done)+"/"+
					itos(total)+" files");
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

static void send_menu_message(interface::Server *server,
		network::PeerInfo::Id peer, const ss_ &message,
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
	network::send(server, peer, packet, os.str());
}

// The same dialog for something that went right, which is not a warning
// in the log and is otherwise the same thing
// A message is news -- a game installed, a world imported -- shown
// over the list it changed; an error is a dialog the user has to
// close ([FIRST_RUN]: a driven run fails on any dialog, so news is
// not one)
static void menu_message(interface::Server *server, network::PeerInfo::Id peer,
		const ss_ &message)
{
	log_i(MODULE, "%s", cs(message));
	send_menu_message(server, peer, message, "main:menu_message");
}

static void menu_error(interface::Server *server, network::PeerInfo::Id peer,
		const ss_ &message)
{
	log_w(MODULE, "%s", cs(message));
	send_menu_message(server, peer, message, "main:menu_error");
}

// Under the user path, not the cache: a Luanti game the user installed
// and a world they have played are things they chose, and the cache is
// what the program can recreate by itself. See
// doc/plan/world_persistence_plan.md. What vanilla shares with other
// apps, read-only to them ([PROCESS_SANDBOX]): the games, the texture
// packs, settings.json. Was <user>/luanti, moved at start by
// interface::fs::migrate_user_apps().
static ss_ luanti_path(interface::Server *server)
{
	return server->get_config().get<ss_>("user_path")+"/shared/vanilla";
}

// [WORLD_TXP] The server's texture packs, under luanti/texture_packs,
// and each world's one of them in its world.mt as
// buildat_texture_pack; the luanti module serves that one's files in
// place of the game's (builtin/luanti/media.h)
static ss_ txp_path(interface::Server *server)
{
	return luanti_path(server)+"/texture_packs";
}

// [WORLD_MODS] The server's mods, under luanti/mods as the games are
// under luanti/games, and each world's choice of them in its world.mt
// as Luanti writes it: load_mod_<name> = true or false. The luanti
// module's modloader.lua loads the chosen ones.
static ss_ mods_path(interface::Server *server)
{
	return luanti_path(server)+"/mods";
}

// Where ContentDB's installs of a type go
static ss_ install_root(interface::Server *server, const ss_ &type)
{
	return type == "mod" ? mods_path(server) : type == "txp" ?
			txp_path(server) : luanti_path(server)+"/games";
}

// The imported Luanti worlds are vanilla's own: they hold their
// players' password hashes
static ss_ worlds_path(interface::Server *server)
{
	return server->get_config().get<ss_>("user_path")+"/apps/vanilla/worlds";
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

static sv_<World> list_worlds(interface::Server *server)
{
	sv_<World> worlds;
	ss_ dir = worlds_path(server);
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
static ss_ bundled_game_path(interface::Server *server)
{
	return server->get_module_path("luanti")+"/minimal_game";
}

static sv_<ss_> list_apps(interface::Server *server)
{
	sv_<ss_> out;
	ss_ dir = luanti_path(server)+"/games";
	for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
		if(!n.is_directory || n.name == "." || n.name == "..")
			continue;
		if(interface::fs::path_exists(dir+"/"+n.name+"/game.conf"))
			out.push_back(n.name);
	}
	// The one buildat ships, so that there is something to choose
	// without a Luanti installation
	if(interface::fs::path_exists(bundled_game_path(server)+"/game.conf"))
		out.push_back("minimal");
	std::sort(out.begin(), out.end());
	return out;
}

static ss_ find_game(interface::Server *server, const ss_ &gameid)
{
	// A directory's name and nothing else: a client sends it, and
	// "../.." was any directory with a game.conf, whose mods then ran
	// ([SECURITY_RUN_1])
	if(gameid.empty() || gameid.find_first_not_of(
			"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
			"0123456789_-") != ss_::npos)
		return "";
	ss_ path = luanti_path(server)+"/games/"+gameid;
	if(interface::fs::path_exists(path+"/game.conf"))
		return path;
	if(gameid == "minimal"){
		path = bundled_game_path(server);
		if(interface::fs::path_exists(path+"/game.conf"))
			return path;
	}
	return "";
}
// vim: set noet ts=4 sw=4:
