// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [VANILLA_MODULAR] **ContentDB** ([CONTENTDB]): its games, mods and
// texture packs listed and installed, a thread per job, the finished
// ones read from the tick.
// Included by main.cpp inside namespace vanilla, after world_mods.h
#pragma once

struct ContentDB
{
	// The Module's
	interface::Server *m_server;
	Access &m_access;

	ContentDB(interface::Server *server, Access &access):
		m_server(server), m_access(access)
	{}

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
		if(!m_access.may_manage(packet.sender))
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
			const ss_ game = find_game(m_server, values[2]);
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
		if(!m_access.may_manage(packet.sender))
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

	// The mod's hard dependencies that neither the world's game nor an
	// installed mod gives, found on a thread; poll_contentdb() asks the
	// client about them, or installs at once when there are none
	void mod_install_ask(network::PeerInfo::Id peer, const ss_ &author,
			const ss_ &name, const ss_ &gameid)
	{
		if(!contentdb_name_ok(author) || !contentdb_name_ok(name)){
			menu_error(m_server, peer,
					"Not a ContentDB name: "+author+"/"+name);
			return;
		}
		if(interface::fs::path_exists(mods_path(m_server)+"/"+name)){
			menu_error(m_server, peer, name+" is already installed");
			return;
		}
		Job *job = new Job();
		job->kind = Job::DEPS;
		job->peer = peer;
		job->q = author+"/"+name;
		job->gameid = gameid;
		sv_<ModInfo> mods;
		const ss_ game = find_game(m_server, gameid);
		if(!game.empty())
			scan_mods(game+"/mods", "", mods);
		scan_all_mods(m_server, mods);
		for(const ModInfo &m : mods)
			job->provided.insert(m.name);
		send_progress(m_server, peer,
				"Asking ContentDB what "+name+" needs...");
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
					menu_error(m_server, packet.sender,
							"Not a ContentDB name: "+*v);
					return;
				}
			}
		}
		const ss_ to = install_root(m_server, type)+"/"+name;
		if(interface::fs::path_exists(to)){
			menu_error(m_server, packet.sender,
					name+" is already installed. Remove "+
					m_access.where(to)+" yourself if you mean to replace it.");
			return;
		}
		const ss_ full = no_room(m_server);
		if(!full.empty()){
			menu_error(m_server, packet.sender,
					full+". Delete a world or a game first.");
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
		job->no_room = no_room(m_server, INT64_MAX);
		const ss_ cache = m_server->get_config().get<ss_>("cache_path")+
				"/luanti/contentdb";
		interface::fs::create_directories(cache);
		job->zip_path = cache+"/"+author+"_"+name+".zip";
		// A mod's outside mods/, where the loader would find it half done
		job->into_dir = type == "mod" ? luanti_path(m_server)+
				"/mods.installing/"+name : type == "txp" ? luanti_path(m_server)+
				"/texture_packs.installing/"+name : to+".installing";
		send_progress(m_server, packet.sender, "Fetching "+name+"...");
		start_job(job);
	}

	// The finished jobs answered, the running installs' progress told
	void poll_contentdb()
	{
		for(size_t i = 0; i < m_contentdb_jobs.size(); ){
			Job *job = m_contentdb_jobs[i];
			if(!job->done){
				if(job->kind == Job::INSTALL && job->phase == 1)
					send_progress(m_server, job->peer,
							"Unpacking "+job->name+"...");
				else if(job->kind == Job::INSTALL && job->phase == 2)
					send_progress(m_server, job->peer,
							"Installing "+job->name+"...");
				else if(job->kind == Job::INSTALL && job->total > 0){
					send_progress(m_server, job->peer,
							"Downloading "+job->name+": "+
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
				menu_error(m_server, job->peer, (job->kind == Job::LIST ?
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
				send_strings(m_server, job->peer, "main:contentdb_deps", flat);
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
				network::send(m_server, job->peer, "main:contentdb_picture",
						os.str());
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
			const ss_ to = install_root(m_server, job->type)+"/"+job->name;
			const bool at_top = interface::fs::path_exists(job->into_dir+
					"/init.lua") || interface::fs::path_exists(job->into_dir+
					"/modpack.conf") || interface::fs::path_exists(job->into_dir+
					"/game.conf") || interface::fs::path_exists(job->into_dir+
					"/texture_pack.conf");
			const ss_ from = tops == 1 && !at_top ? job->into_dir+"/"+top :
					job->into_dir;
			interface::fs::create_directories(interface::fs::strip_file_name(to));
			if(rename(from.c_str(), to.c_str()) != 0){
				menu_error(m_server, job->peer,
						"Installing "+job->name+" failed: cannot "
						"rename "+m_access.where(from));
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
			menu_message(m_server, job->peer,
					job->name+" installed from ContentDB");
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
			menu_error(m_server, peer,
					"ContentDB answered with something that is not "
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
		network::send(m_server, peer, "main:contentdb_list", os.str());
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
};


// BUILDAT_CONTENTDB_URL: a mirror in a test ([FIRST_RUN]: a directory
// served by python3 -m http.server, made by util/contentdb_mirror.sh),
// since the real one over the network in a daily run is a flake
const char *ContentDB::CONTENTDB = getenv("BUILDAT_CONTENTDB_URL") ?
		getenv("BUILDAT_CONTENTDB_URL") : "https://content.luanti.org";
// vim: set noet ts=4 sw=4:
