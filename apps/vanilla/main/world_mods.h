// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [VANILLA_MODULAR] **A world's mods and texture pack** ([WORLD_MODS],
// [WORLD_TXP]): the mods there are -- Buildat's, the installed ones, a
// game's -- as modloader.lua finds them (free functions), and the world
// menu's pages that turn them on and off per world and remove them.
// Included by main.cpp inside namespace vanilla, after access.h
#pragma once

static sv_<ss_> worlds_with_txp(interface::Server *server, const ss_ &name)
{
	sv_<ss_> out;
	sv_<storage::SaveInfo> infos;
	storage::access(server, [&](storage::Interface *istorage){
		infos = istorage->list();
	});
	for(const storage::SaveInfo &info : infos){
		ss_ path;
		if(info.name.empty() || info.name[0] == '_' ||
				!save_dir(server, info.name, path))
			continue;
		if(read_world_mt(path+"/luanti/world.mt")["buildat_texture_pack"] ==
				name)
			out.push_back(info.name);
	}
	return out;
}

struct ModInfo {
	ss_ name, pack, dir; // pack: the modpack's directory name, or ""
	sv_<ss_> depends;
	bool builtin = false; // comes with Buildat
};

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

static bool mod_name_ok(const ss_ &name)
{
	return !name.empty() && name.find_first_not_of(
			"abcdefghijklmnopqrstuvwxyz0123456789_") == ss_::npos;
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

// The mods that come with Buildat ([BUILDAT_WIELD_LIGHT]), then the
// installed ones: what a world can turn on, as modloader.lua loads them
static void scan_all_mods(interface::Server *server, sv_<ModInfo> &out)
{
	const size_t from = out.size();
	scan_mods(server->get_module_path("luanti")+"/mods", "", out);
	for(size_t i = from; i < out.size(); i++)
		out[i].builtin = true;
	scan_mods(mods_path(server), "", out);
}

// The worlds whose world.mt turns the mod on
static sv_<ss_> worlds_enabling(interface::Server *server, const ss_ &mod)
{
	sv_<ss_> out;
	sv_<storage::SaveInfo> infos;
	storage::access(server, [&](storage::Interface *istorage){
		infos = istorage->list();
	});
	for(const storage::SaveInfo &info : infos){
		ss_ path;
		if(info.name.empty() || info.name[0] == '_' ||
				!save_dir(server, info.name, path))
			continue;
		if(read_world_mt(path+"/luanti/world.mt")["load_mod_"+mod] == "true")
			out.push_back(info.name);
	}
	return out;
}

// What keeps a world's mods from loading: one with a game mod's name,
// or a hard dependency nothing gives. "" when they load (a cycle is
// left to modlist.lua to say).
static ss_ world_mods_problem(interface::Server *server, const ss_ &game_path,
		const ss_ &save_path)
{
	sv_<ModInfo> game, extra, installed;
	scan_mods(game_path+"/mods", "", game);
	scan_mods(save_path+"/luanti/worldmods", "", extra);
	scan_all_mods(server, installed);
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

struct WorldMods
{
	// The Module's, and the world running: its mods and its pack are
	// the next start's
	interface::Server *m_server;
	bool &m_public;
	ss_ &m_world_name;
	Access &m_access;

	WorldMods(interface::Server *server, bool &public_, ss_ &world_name,
			Access &access):
		m_server(server), m_public(public_), m_world_name(world_name),
		m_access(access)
	{}

	// main:world_txp {save, note, the world's pack ("" none), whether
	// "Restart now" is offered, then the installed packs' names}
	void send_world_txp(network::PeerInfo::Id peer, const ss_ &save,
			const ss_ &note)
	{
		ss_ path;
		if(!save_dir(m_server, save, path)){
			send_strings(m_server, peer, "main:world_txp",
					{save, "No such world.", "", "0"});
			return;
		}
		sv_<ss_> flat{save, note,
				read_world_mt(path+"/luanti/world.mt")["buildat_texture_pack"],
				m_public && save == m_world_name ? "1" : "0"};
		sv_<ss_> names;
		for(const auto &n : interface::fs::list_directory(txp_path(m_server)))
			if(n.is_directory && contentdb_name_ok(n.name))
				names.push_back(n.name);
		std::sort(names.begin(), names.end());
		flat.insert(flat.end(), names.begin(), names.end());
		send_strings(m_server, peer, "main:world_txp", flat);
	}

	// main:get_world_txp {save}
	void on_get_world_txp(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(!values.empty())
			send_world_txp(packet.sender, values[0], "");
	}

	// main:set_world_txp {save, name or "" for none}: from the world's
	// next start, as a mod
	void on_set_world_txp(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path;
		if(values.size() < 2 || !save_dir(m_server, values[0], path))
			return;
		const ss_ &name = values[1];
		if(!name.empty() && (!contentdb_name_ok(name) ||
				!interface::fs::path_exists(txp_path(m_server)+"/"+name)))
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
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.size() < 2 || !contentdb_name_ok(values[1]))
			return;
		const ss_ dir = txp_path(m_server)+"/"+values[1];
		if(!interface::fs::path_exists(dir))
			return send_world_txp(packet.sender, values[0], values[1]+
					" is not installed.");
		ss_ users;
		for(const ss_ &w : worlds_with_txp(m_server, values[1]))
			users += (users.empty() ? "" : ", ")+w;
		if(!users.empty())
			return send_world_txp(packet.sender, values[0], values[1]+
					" is not removed: the texture pack of "+users+".");
		const ss_ trash = luanti_path(m_server)+"/trash";
		interface::fs::create_directories(trash);
		time_t now = time(NULL);
		char date[32];
		strftime(date, sizeof date, "%Y-%m-%d_%H%M%S", localtime(&now));
		const ss_ to = trash+"/txp_"+values[1]+"-"+date;
		if(rename(dir.c_str(), to.c_str()) != 0)
			return send_world_txp(packet.sender, values[0], "Could not move "+
					m_access.where(dir)+" to "+m_access.where(to));
		log_i(MODULE, "Texture pack %s moved to %s", cs(values[1]), cs(to));
		send_world_txp(packet.sender, values[0], values[1]+
				" moved to the trash.");
	}

	// main:world_mods {save, note, gameid, whether "Restart now" is
	// offered, then per row: name, modpack ("" for none, the pack's own
	// row has its own name), state ("1" on, "0" off, "pack", "missing"),
	// the hard dependencies the game does not give, comma-separated}
	void send_world_mods(network::PeerInfo::Id peer, const ss_ &save,
			const ss_ &note)
	{
		ss_ path, gameid;
		if(!save_dir(m_server, save, path, &gameid)){
			send_strings(m_server, peer, "main:world_mods",
					{save, "No such world.", "", "0"});
			return;
		}
		std::map<ss_, ss_> mt = read_world_mt(path+"/luanti/world.mt");
		std::set<ss_> game_mods;
		{
			sv_<ModInfo> g;
			const ss_ game = find_game(m_server, gameid);
			if(!game.empty())
				scan_mods(game+"/mods", "", g);
			for(const ModInfo &m : g)
				game_mods.insert(m.name);
		}
		sv_<ModInfo> mods;
		scan_all_mods(m_server, mods);
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
		send_strings(m_server, peer, "main:world_mods", flat);
	}

	// main:get_world_mods {save}
	void on_get_world_mods(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
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
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path, gameid;
		if(values.size() < 3 || !save_dir(m_server, values[0], path, &gameid))
			return;
		const bool on = values[2] == "1";
		sv_<ModInfo> mods, game;
		scan_all_mods(m_server, mods);
		if(!find_game(m_server, gameid).empty())
			scan_mods(find_game(m_server, gameid)+"/mods", "", game);
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
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.size() < 2)
			return;
		sv_<ModInfo> mods;
		scan_mods(mods_path(m_server), "", mods);
		ss_ dir, users;
		for(const ModInfo &m : mods){
			if(m.name != values[1] && m.pack != values[1])
				continue;
			dir = m.pack.empty() ? m.dir : mods_path(m_server)+"/"+m.pack;
			for(const ss_ &w : worlds_enabling(m_server, m.name))
				users += (users.find(w) != ss_::npos ? "" :
						ss_(users.empty() ? "" : ", ")+w);
		}
		if(dir.empty())
			return send_world_mods(packet.sender, values[0], values[1]+
					" is not installed.");
		if(!users.empty())
			return send_world_mods(packet.sender, values[0], values[1]+
					" is not removed: on in "+users+".");
		const ss_ trash = luanti_path(m_server)+"/trash";
		interface::fs::create_directories(trash);
		time_t now = time(NULL);
		char date[32];
		strftime(date, sizeof date, "%Y-%m-%d_%H%M%S", localtime(&now));
		const ss_ to = trash+"/mod_"+values[1]+"-"+date;
		if(rename(dir.c_str(), to.c_str()) != 0)
			return send_world_mods(packet.sender, values[0], "Could not move "+
					m_access.where(dir)+" to "+m_access.where(to));
		log_i(MODULE, "Mod %s moved to %s", cs(values[1]), cs(to));
		send_world_mods(packet.sender, values[0], values[1]+
				" moved to the trash.");
	}
};
// vim: set noet ts=4 sw=4:
