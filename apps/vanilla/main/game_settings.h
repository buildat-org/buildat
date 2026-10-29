// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [VANILLA_MODULAR] **The settings**: a game's own (its
// settingtypes.txt, per world in world.mt), the server's performance
// presets per world, and the client's Luanti settings (settings.json)
// that the launcher's settings page edits.
// Included by main.cpp inside namespace vanilla, after contentdb.h
#pragma once

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

// The save's directory and its game's settings, or false
static bool save_settings(interface::Server *server, const ss_ &name, ss_ &path,
		sv_<GameSetting> &out)
{
	ss_ gameid;
	if(!save_dir(server, name, path, &gameid))
		return false;
	const ss_ game_path = gameid.empty() ? "" : find_game(server, gameid);
	if(path.empty() || game_path.empty())
		return false;
	out = game_settings(game_path);
	return true;
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

// **A save someone else made, taken as this host's own**: a world package
// on its first open (game_start.h's adopt_world_package) and a Buildat save
// imported from a zip (importer.h). What in it would decide things for
// this host goes:
// - world.mt's settings that name an admin, hand out privileges or set a
//   password, and those that set what the world costs this host to run
//   (the server preset's, and Luanti's others of the kind) -- the host's
//   own preset is put in when it next starts (apply_default_preset);
// - its players' privileges and passwords (the auth entries in the luanti
//   store's players row), so nobody claims a name's privileges: with
//   keep_players (an import, likely the host's own world moved) the
//   players' inventories, positions and metadata stay and the row is
//   marked "players_auth_foreign", which builtin/luanti's load_players()
//   reads as "leave the auth entries out" -- parsed there, by the bounded
//   core.deserialize the row is always read with; without it (a world
//   package: a stranger's inventories would be tied to names here) the
//   whole row goes;
// - its forceloaded blocks, each of which would keep a section loaded.
// The map, the world's other settings and the mods' files stay.
// simplified: a list of the keys known to cost or to give; a game's own
// setting is kept whatever it does
static void take_strangers_save(interface::Server *server,
		const ss_ &save_name, const ss_ &save_path, bool keep_players)
{
	const ss_ mt = save_path+"/luanti/world.mt";
	if(interface::fs::path_exists(mt)){
		std::map<ss_, ss_> kept = read_world_mt(mt);
		sv_<ss_> drop{"name", "default_privs", "basic_privs",
				"default_password", "buildat_preset", "chunksize",
				"active_block_range", "active_block_mgmt_interval",
				"abm_interval", "max_objects_per_block",
				"max_forceloaded_blocks", "liquid_update",
				"dedicated_server_step", "server_map_save_interval",
				"enable_rollback_recording", "profiler.load"};
		for(const ss_ &k : perf_keys())
			drop.push_back(k);
		for(const ss_ &k : drop)
			kept.erase(k);
		for(auto it = kept.begin(); it != kept.end();)
			it = it->first.compare(0, 7, "secure.") == 0 ? kept.erase(it) :
					std::next(it);
		// Written a key a line, so a multi-line value cannot hide one of
		// them from this and show it to the Lua side's reader
		ss_ text;
		for(const auto &kv : kept)
			text += kv.first+" = "+kv.second+"\n";
		if(!interface::fs::write_file(mt, text))
			log_w(MODULE, "vanilla: cannot write %s", cs(mt));
	}
	interface::fs::remove_all(save_path+"/luanti/force_loaded.txt");
	storage::access(server, [&](storage::Interface *istorage){
		storage::Save *save = istorage->open(save_name);
		if(save){
			storage::Store *st = save->store("luanti");
			if(keep_players)
				st->set("players_auth_foreign", "1");
			else
				st->remove("players");
			istorage->close(save);
		}
	});
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

// The launcher's settings, in the user path beside luanti/games and
// luanti/worlds ([LAUNCH_GRID]): {"render_mode": "pbr", ...}, the mode
// a session draws in when BUILDAT_RENDER_MODE says nothing (read by
// builtin/luanti where the variable is), the view and the keys. Written
// by hand and read with sajson. On the wire one list of "key=value"
// strings. An old file's "import_paths" is ignored
// ([LUANTI_IMPORT_FOLDER]).
static ss_ settings_path(interface::Server *server)
{
	return luanti_path(server)+"/settings.json";
}

// One string value of settings.json's top level, or "" when absent
static ss_ read_setting(interface::Server *server, const ss_ &key)
{
	std::ifstream f(settings_path(server));
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

static ss_ read_render_mode(interface::Server *server)
{
	return read_setting(server, "render_mode");
}

// The viewing range ([VIEW_RANGE]): "view_range": "<n>", 120 when
// absent so a new install bets on no strong computer; 20..4000 as
// official's
// view_bobbing_amount ([VIEW_BOB]): 1 unless set, 0 off; BUILDAT_VIEW_BOBBING
// for one run, which is how the reference shooters keep their probes still
static ss_ read_view_bobbing(interface::Server *server)
{
	const char *env = getenv("BUILDAT_VIEW_BOBBING");
	const ss_ v = env ? ss_(env) : read_setting(server,
			"view_bobbing_amount");
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
static ss_ read_lod_detail(interface::Server *server)
{
	const char *env = getenv("BUILDAT_LOD_DETAIL");
	const ss_ v = env ? ss_(env) : read_setting(server, "distant_detail");
	return (v == "half" || v == "third") ? v : ss_("full");
}

static ss_ read_view_range(interface::Server *server)
{
	// BUILDAT_VIEW_RANGE for one run: the reference shooters set their
	// range this way, over whatever the user's settings.json says
	const char *env = getenv("BUILDAT_VIEW_RANGE");
	const ss_ v = env ? ss_(env) : read_setting(server, "view_range");
	const int n = atoi(v.c_str());
	return (n >= 20 && n <= 4000) ? itos(n) : ss_("120");
}

// "web_view_range": the web client's viewing range unless its player
// chose one (user, 2026-09-30): a browser meshes on one thread and
// loads a world slower. "" when not set, and the client's own default
// (80, 60 on a touchscreen) holds; never over view_range either way.
static ss_ read_web_view_range(interface::Server *server)
{
	const int n = atoi(read_setting(server, "web_view_range").c_str());
	return (n >= 20 && n <= 4000) ? itos(n) : ss_();
}

// The key bindings ([KEY_BINDINGS]): settings.json's "keys" object,
// action to key name, as "key.<action>=<name>" rows of the list
static sv_<ss_> read_key_rows(interface::Server *server)
{
	sv_<ss_> out;
	std::ifstream f(settings_path(server));
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

static void write_settings(interface::Server *server, const ss_ &mode,
		const sv_<std::pair<ss_, ss_>> &keys, const ss_ &view_range,
		const ss_ &view_bobbing, const ss_ &shoulder,
		const ss_ &lod_detail)
{
	// Set by hand only, so kept through the settings screen's save
	const ss_ web_range = read_web_view_range(server);
	interface::fs::create_directories(luanti_path(server));
	std::ofstream f(settings_path(server), std::ios::trunc);
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
		log_w(MODULE, "could not write %s", cs(settings_path(server)));
}

static void send_settings(interface::Server *server, network::PeerInfo::Id peer)
{
	sv_<ss_> list;
	ss_ mode = read_render_mode(server);
	list.push_back("render_mode="+(mode.empty() ? ss_("pbr") : mode));
	list.push_back("view_range="+read_view_range(server));
	const ss_ web_range = read_web_view_range(server);
	if(!web_range.empty())
		list.push_back("web_view_range="+web_range);
	list.push_back("lod_detail="+read_lod_detail(server));
	list.push_back("view_bobbing_amount="+read_view_bobbing(server));
	// The back view centred or over the shoulder ([OVER_SHOULDER])
	list.push_back("third_person_shoulder="+
			(read_setting(server, "third_person_shoulder") == "1" ?
			ss_("1") : ss_("0")));
	for(const ss_ &row : read_key_rows(server))
		list.push_back(row);
	network::send(server, peer, "main:settings", storage::pack(list));
}

struct GameSettings
{
	// The Module's, and the world starting or running: its
	// settings are the next start's
	interface::Server *m_server;
	bool &m_starting;
	bool &m_public;
	ss_ &m_world_name;
	Access &m_access;

	GameSettings(interface::Server *server, bool &starting, bool &public_,
			ss_ &world_name, Access &access):
		m_server(server), m_starting(starting), m_public(public_),
		m_world_name(world_name), m_access(access)
	{}

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
		const bool found = perf ? save_dir(m_server, name, path) :
				save_settings(m_server, name, path, settings);
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
		const ss_ packed = storage::pack(flat);
		network::send(m_server, packet.sender, perf ? "main:perf_settings" :
				"main:game_settings", packed);
	}

	// main:get_game_settings {name}
	void on_get_game_settings(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(!values.empty())
			send_game_settings(packet, values[0], "");
	}

	// main:set_game_settings {name, key, value, ...}: into world.mt, each
	// key one the game declares and each value one it takes
	void on_set_game_settings(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path;
		sv_<GameSetting> settings;
		if(values.empty() ||
				!save_settings(m_server, values[0], path, settings))
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

	// A world with no preset takes its context's: headless is a small
	// server, one the client starts has the machine to itself
	ss_ default_preset() const
	{
		return m_public ? "VPS / Raspberry Pi" : "Desktop";
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
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		if(!values.empty())
			send_game_settings(packet, values[0], "", true);
	}

	// main:set_perf_settings {name, key, value, ...}
	void on_set_perf_settings(const network::Packet &packet)
	{
		if(!m_access.may_manage(packet.sender))
			return;
		const sv_<ss_> values = read_packet_strings(packet);
		ss_ path;
		if(values.empty() || !save_dir(m_server, values[0], path))
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

	void on_get_settings(const network::Packet &packet)
	{
		send_settings(m_server, packet.sender);
	}

	// The whole list, replacing what was there: the screen adds and
	// removes, and sends the result
	void on_set_settings(const network::Packet &packet)
	{
		if(!m_access.local_only(packet.sender))
			return;
		sv_<ss_> values;
		if(!storage::unpack(packet.data, values)){
			log_w(MODULE, "main:set_settings: could not be read");
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
		write_settings(m_server, mode, keys, view_range, view_bobbing, shoulder,
				lod_detail);
		log_i(MODULE, "settings: render_mode %s, view_range "
				"%s and %zu key bindings written to %s", cs(mode),
				cs(view_range), keys.size(), cs(settings_path(m_server)));
		send_settings(m_server, packet.sender);
	}
};
// vim: set noet ts=4 sw=4:
