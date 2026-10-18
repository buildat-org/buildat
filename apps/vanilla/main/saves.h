// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [VANILLA_MODULAR] **The saves**: the world menu's list of them and a
// save's page, a world created, opened, renamed, deleted and trimmed, and
// the disk's limit ([SAVE_LIMIT]).
// Included by main.cpp inside namespace vanilla, after game_start.h
#pragma once

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
				if(s1 < std::min(b[a], b[a + 3]) ||
						s0 > std::max(b[a], b[a + 3]))
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

struct Saves
{
	// The Module's: the world starting or running, and its save
	interface::Server *m_server;
	luanti::SceneReference &m_scene;
	bool &m_starting;
	bool &m_public;
	ss_ &m_world_name;
	storage::Save *&m_world_save;
	std::map<network::PeerInfo::Id, ss_> &m_names;
	Access &m_access;
	ContentDB &m_contentdb;
	GameStart &m_start;

	Saves(interface::Server *server, luanti::SceneReference &scene,
			bool &starting, bool &public_, ss_ &world_name,
			storage::Save *&world_save,
			std::map<network::PeerInfo::Id, ss_> &names, Access &access,
			ContentDB &contentdb, GameStart &start):
		m_server(server), m_scene(scene), m_starting(starting),
		m_public(public_), m_world_name(world_name), m_world_save(world_save),
		m_names(names), m_access(access), m_contentdb(contentdb), m_start(start)
	{}

	// The launch param's save is opened by the first main:get_saves packet
	// and by no later one: vanilla's client sends that packet more than
	// once, and a repeat is not a user asking twice
	bool m_launched_param_save = false;

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
			ss_ save = m_start.launch_param("save");
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
					m_start.start_world(gameid, save, packet.sender, "", true);
					return;
				}
			}
		}
		// A launch that asked for one of the menu's screens -- import_game,
		// import_world -- says so before the lists, and the client opens
		// that screen over them ([LAUNCH_GRID])
		{
			ss_ menu = m_start.launch_param("menu");
			if(menu == "worlds"){
				ss_ game = m_start.launch_param("luanti_game");
				// One world's options, from a launcher's menu on its save
				// ([SAVE_CONTEXT_MENU])
				ss_ world = m_start.launch_param("world");
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
			return m_start.switch_world(name, packet.sender);
		}
		m_start.start_world(gameid, name, packet.sender);
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
		m_start.start_world(gameid, name, packet.sender);
	}
};
// vim: set noet ts=4 sw=4:
