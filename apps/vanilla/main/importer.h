// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [VANILLA_MODULAR] **A world in and out**: a save exported to the
// player as a zip and one imported from theirs, in parts over the
// connection (the one transfer at a time, m_transfer), and the games and
// worlds of a Luanti installation imported from its folder.
// Included by main.cpp inside namespace vanilla, after game_settings.h
#pragma once

static ss_ transfer_dir(interface::Server *server)
{
	return server->get_config().get<ss_>("cache_path")+"/vanilla_transfer";
}

// An error for the player without where on the server's disk
// ([SEC_RUN5_LEFTOVERS]): the cache and user directories cut out
static ss_ unpathed(interface::Server *server, ss_ err)
{
	for(const char *k : {"cache_path", "user_path"}){
		const ss_ p = server->get_config().get<ss_>(k);
		for(size_t i; !p.empty() && (i = err.find(p)) != ss_::npos;)
			err.replace(i, p.size(), "...");
	}
	return err;
}

// Every file under dir, the archive's names under prefix; a symlink is
// left out, not read through ([SEC_RUN5_LEFTOVERS])
static void list_files(const ss_ &dir, const ss_ &prefix,
		sv_<std::pair<ss_, ss_>> &out)
{
	for(const auto &n : interface::fs::list_directory(dir)){
#ifndef _WIN32
		// simplified: POSIX links only; a Windows junction is read
		// through (it takes the user to make one in a save)
		struct stat st;
		if(lstat((dir+"/"+n.name).c_str(), &st) != 0 || S_ISLNK(st.st_mode))
			continue;
#endif
		if(n.is_directory)
			list_files(dir+"/"+n.name, prefix+n.name+"/", out);
		else
			out.push_back({prefix+n.name, dir+"/"+n.name});
	}
}

static ss_ import_folder(interface::Server *server)
{
	return luanti_path(server)+"/import";
}

static sv_<ss_> import_roots(interface::Server *server)
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
	add(import_folder(server), "the import folder");
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

// A game to import, found by its id. The first root that has one wins,
// which is the order import_roots() is in. Empty when there is none --
// the client names what it wants and the server finds it again, because
// a path that arrives over the network is not a path to copy.
static ss_ find_importable_game(interface::Server *server, const ss_ &gameid)
{
	if(gameid.empty() || gameid.find('/') != ss_::npos ||
			gameid.find("..") != ss_::npos)
		return "";
	for(const ss_ &root : import_roots(server)){
		ss_ path = root+"/games/"+gameid;
		if(interface::fs::path_exists(path+"/game.conf"))
			return path;
	}
	return "";
}

// And a world, the same way
static ss_ find_importable_world(interface::Server *server, const ss_ &name)
{
	if(name.empty() || name.find('/') != ss_::npos ||
			name.find("..") != ss_::npos)
		return "";
	for(const ss_ &root : import_roots(server)){
		ss_ path = root+"/worlds/"+name;
		if(interface::fs::path_exists(path+"/world.mt"))
			return path;
	}
	return "";
}

struct Importer
{
	// The Module's, and the world starting or running, which an
	// export of it compacts first
	interface::Server *m_server;
	luanti::SceneReference &m_scene;
	bool &m_starting;
	bool &m_public;
	ss_ &m_world_name;
	storage::Save *&m_world_save;
	Access &m_access;
	// The Module's start_world(), which runs what was imported
	typedef std::function<void(const ss_ &gameid, const ss_ &world_name,
			network::PeerInfo::Id peer, const ss_ &import_world_from)>
			StartWorld;
	StartWorld start_world;

	Importer(interface::Server *server, luanti::SceneReference &scene,
			bool &starting, bool &public_, ss_ &world_name,
			storage::Save *&world_save, Access &access, StartWorld start_world):
		m_server(server), m_scene(scene), m_starting(starting),
		m_public(public_), m_world_name(world_name), m_world_save(world_save),
		m_access(access), start_world(start_world)
	{}

	// [WORLD_TRIM_MOVE] 3-5: a world out as a zip and one in, in parts:
	// a world is more than a packet or a client's string holds. One at a
	// time, its files in one folder of the cache that is emptied when it
	// ends, whichever way (and at a start, after a server that stopped
	// mid-way).
	//   export: main:export {save} -> main:export_ready {save, bytes}; then
	//     main:export_part {offset} -> main:export_data {offset, bytes}
	//   import: main:import_begin {name, bytes} -> main:import_next
	//     {offset}; main:import_data {offset, bytes} -> import_next, and
	//     after the last a menu message or error -- or, on a public server
	//     whose zip brings world mods, main:import_mods {name, mod...} ->
	//     main:import_mods_answer {"keep" or "drop"}, and then that
	// simplified: the copy and the zip are made on the server's thread; a
	// large world holds the game while they are made, as compacting does
	struct Transfer {
		network::PeerInfo::Id peer = 0;
		bool import = false;
		ss_ name;
		int64_t size = 0, done = 0;
		// The unpacked world's folder while its mods wait on the admin
		ss_ mods_root;
	};

	Transfer m_transfer;

	enum { TRANSFER_PART = 1024 * 1024 };

	void end_transfer()
	{
		interface::fs::remove_all(transfer_dir(m_server));
		m_transfer = Transfer();
	}

	bool transfer_free(network::PeerInfo::Id peer)
	{
		if(m_transfer.peer == 0)
			return true;
		menu_error(m_server, peer,
				"Another transfer is running: "+ss_(m_transfer.import ?
				"an import" : "an export of "+m_transfer.name)+". Try again "
				"once it is done.");
		return false;
	}

	void on_export(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender) || !transfer_free(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path;
		if(values.empty() || !save_dir(m_server, values[0], path))
			return menu_error(m_server, packet.sender, "No such save");
		const ss_ save = values[0];
		const ss_ dir = transfer_dir(m_server);
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
			return menu_error(m_server, packet.sender,
					"Exporting "+save+" failed: "+
					unpathed(m_server, err));
		}
		m_transfer.peer = packet.sender;
		m_transfer.name = save;
		m_transfer.size = interface::fs::file_size(zip);
		log_i(MODULE, "Exporting %s: %zu files, %lld kB, made in %d ms",
				cs(save), files.size(), (long long)(m_transfer.size / 1024),
				(int)((interface::os::time_us() - t0) / 1000));
		send_strings(m_server, packet.sender, "main:export_ready",
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
		std::ifstream is(transfer_dir(m_server)+"/export.zip",
				std::ios::binary);
		is.seekg(offset);
		is.read(&data[0], data.size());
		if((size_t)is.gcount() != data.size()){
			end_transfer();
			return menu_error(m_server, packet.sender,
					"The export's file went away");
		}
		send_strings(m_server, packet.sender, "main:export_data",
				{itos(offset), data});
		if(offset + (int64_t)data.size() >= m_transfer.size){
			log_i(MODULE, "Exported %s", cs(m_transfer.name));
			end_transfer();
		}
	}

	void on_import_begin(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender) || !transfer_free(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(values.size() < 2)
			return;
		const int64_t size = atoll(values[1].c_str());
		const ss_ full = no_room(m_server, size);
		if(size <= 0 || !full.empty())
			return menu_error(m_server, packet.sender,
					size <= 0 ? ss_("An empty file") :
					full+"; the zip is "+mb_text(size)+". Delete a world or "
					"a game first.");
		// The save's name from the file's: letters, digits, _ and -
		ss_ name;
		for(char c : values[0].substr(0, values[0].find('.')))
			if(isalnum((unsigned char)c) || c == '_' || c == '-')
				name += c;
		if(name.compare(0, 1, "_") == 0 || name.empty())
			name = "imported"+name;
		const ss_ dir = transfer_dir(m_server);
		interface::fs::remove_all(dir);
		interface::fs::create_directories(dir);
		std::ofstream(dir+"/import.zip", std::ios::binary);
		m_transfer.peer = packet.sender;
		m_transfer.import = true;
		m_transfer.name = name.substr(0, 60);
		m_transfer.size = size;
		log_i(MODULE, "Importing %s: %lld kB coming", cs(values[0]),
				(long long)(size / 1024));
		send_strings(m_server, packet.sender, "main:import_next", {"0"});
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
			return menu_error(m_server, packet.sender,
					"The import's parts came out "
					"of order; nothing was kept");
		}
		{
			std::ofstream os(transfer_dir(m_server)+"/import.zip",
					std::ios::binary | std::ios::app);
			os.write(values[1].data(), values[1].size());
		}
		m_transfer.done += values[1].size();
		if(m_transfer.done < m_transfer.size){
			send_strings(m_server, packet.sender, "main:import_next",
					{itos(m_transfer.done)});
			return;
		}
		const ss_ err = finish_import(packet.sender);
		if(err.empty() && !m_transfer.mods_root.empty())
			return; // the admin is asked about the world's mods
		end_import(packet.sender, err);
	}

	void end_import(network::PeerInfo::Id peer, const ss_ &err)
	{
		end_transfer();
		if(!err.empty())
			menu_error(m_server, peer, "Importing "+m_transfer_last+" failed: "+
					unpathed(m_server, err)+". Nothing was kept.");
	}

	// The admin's answer about the zip's world mods: kept, or removed
	void on_import_mods_answer(const network::Packet &packet)
	{
		if(m_transfer.peer != packet.sender || m_transfer.mods_root.empty())
			return;
		const ss_ root = m_transfer.mods_root;
		if(packet.data != "keep"){
			for(const ss_ &p : {root+"/luanti/worldmods", root+"/worldmods"})
				interface::fs::remove_all(p);
			log_i(MODULE, "import: the zip's world mods left out");
		} else {
			log_w(MODULE, "import: the zip's world mods kept by the admin");
		}
		end_import(packet.sender, import_root(packet.sender, root));
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
		const ss_ dir = transfer_dir(m_server), zip = dir+"/import.zip";
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
		// A world's own mods are code the server runs with all of its reach
		// -- the accounts store among it -- and a public server's admin is
		// not whoever owns the machine: there the admin is asked, the mods
		// named ([SECURITY_RUN_5], the user's call 2026-10-14). The Mods
		// menu's ContentDB ones are not asked about.
		if(m_public){
			sv_<ss_> mods = {m_transfer.name};
			for(const ss_ &p : {root+"/luanti/worldmods", root+"/worldmods"})
				for(const auto &e : interface::fs::list_directory(p))
					if(e.name != "." && e.name != "..")
						mods.push_back(e.name);
			if(mods.size() > 1){
				m_transfer.mods_root = root;
				send_strings(m_server, peer, "main:import_mods", mods);
				return "";
			}
		}
		return import_root(peer, root);
	}

	// The unpacked world at root put where it goes; an error's text or ""
	ss_ import_root(network::PeerInfo::Id peer, const ss_ &root)
	{
		const bool buildat_save = interface::fs::path_exists(root+"/save.sqlite");
		const ss_ name = free_save_name(m_server, m_transfer.name);
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
			if(!copy_tree(m_server, root, to, done, 0, peer, err)){
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
		menu_message(m_server, peer, "Imported "+name+" (game "+gameid+")"+
				(find_game(m_server, gameid).empty() ?
				"; the game is not installed" : ""));
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
		if(!m_access.local_only(packet.sender))
			return;
		sv_<ss_> games;
		sv_<ss_> worlds;
		sv_<ss_> installed = list_apps(m_server);
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
		interface::fs::create_directories(import_folder(m_server)+"/games");
		interface::fs::create_directories(import_folder(m_server)+"/worlds");
		auto seen = [](sv_<ss_> &list, const ss_ &name){
			for(const ss_ &had : list){
				if(had == name)
					return true;
			}
			list.push_back(name);
			return false;
		};
		const sv_<ss_> roots = import_roots(m_server);
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
		const ss_ packed = storage::pack(flat);
		network::send(m_server, packet.sender, "main:imports", packed);
	}

	// A game is copied into buildat's own games directory, and **refuses to
	// overwrite one that is there**: removing an installed game is the
	// user's own business outside buildat. Copying over the top would leave
	// a file the game deleted upstream behind forever, and deleting first is
	// a recursive delete under user/ driven by a menu.
	void on_import_game(const network::Packet &packet)
	{
		if(!m_access.local_only(packet.sender))
			return;
		sv_<ss_> values;
		if(!storage::unpack(packet.data, values)){
			log_w(MODULE, "main:import_game: could not be read");
			return;
		}
		if(values.empty())
			return;
		const ss_ gameid = values[0];
		const ss_ from = find_importable_game(m_server, gameid);
		if(from.empty()){
			menu_error(m_server, packet.sender,
					"There is no game called "+gameid+
					" to import");
			return;
		}
		const ss_ to = luanti_path(m_server)+"/games/"+gameid;
		if(interface::fs::path_exists(to)){
			menu_error(m_server, packet.sender,
					gameid+" is already installed. Remove "+
					to+" yourself if you mean to replace it.");
			return;
		}
		log_i(MODULE, "Importing game %s from %s", cs(gameid), cs(from));
		send_progress(m_server, packet.sender, "Copying "+gameid+"...");
		const size_t total = count_files(from);
		size_t done = 0;
		ss_ error;
		// Into a directory of its own beside the destination first, so that
		// a copy that fails half way does not look like an installed game
		const ss_ partial = to+".importing";
		if(!copy_tree(m_server, from, partial, done, total, packet.sender,
				error)){
			menu_error(m_server, packet.sender,
					"Importing "+gameid+" failed: "+error);
			return;
		}
		if(rename(partial.c_str(), to.c_str()) != 0){
			menu_error(m_server, packet.sender,
					"Importing "+gameid+" failed: cannot "
					"rename "+partial);
			return;
		}
		log_i(MODULE, "Imported game %s: %zu files", cs(gameid), done);
		menu_message(m_server, packet.sender,
				gameid+" imported: "+itos(done)+" files");
	}

	// A world is not copied: it becomes a save, through the importer that
	// BUILDAT_LUANTI_IMPORT already drives. What the button adds is the
	// picking and the name.
	void on_import_world(const network::Packet &packet)
	{
		if(!m_access.local_only(packet.sender))
			return;
		sv_<ss_> values;
		if(!storage::unpack(packet.data, values)){
			log_w(MODULE, "main:import_world: could not be read");
			return;
		}
		if(values.size() < 2)
			return;
		const ss_ world_name = values[0];
		const ss_ from = find_importable_world(m_server, world_name);
		if(from.empty()){
			menu_error(m_server, packet.sender,
					"There is no world called "+world_name+
					" to import");
			return;
		}
		const ss_ err = import_luanti_world(packet.sender, from, world_name,
				values[1]);
		if(!err.empty())
			menu_error(m_server, packet.sender, err);
	}

	// A Luanti world's folder into a new save, and the world started: the
	// import folder's and a zip's ([WORLD_TRIM_MOVE]). An error's text, or
	// "" once it is under way.
	ss_ import_luanti_world(network::PeerInfo::Id peer, const ss_ &from,
			const ss_ &world_name, const ss_ &save_name)
	{
		const ss_ gameid = read_gameid(from);
		if(find_game(m_server, gameid).empty())
			return world_name+" wants the game "+gameid+", which is not "
					"installed. Import that first.";
		bool valid = false;
		storage::access(m_server, [&](storage::Interface *istorage){
			valid = istorage->valid_name(save_name);
		});
		if(!valid)
			return "\""+save_name+"\" is not a name a save can have";
		const ss_ full = no_room(m_server);
		if(!full.empty())
			return full+". Delete a world or a game first.";
		// Before the save is made, which start_world would leave empty
		// ([SEC_RUN5_LEFTOVERS])
		if(m_starting)
			return "A world is already starting";
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
};
// vim: set noet ts=4 sw=4:
