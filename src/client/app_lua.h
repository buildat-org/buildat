// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The Lua functions the client gives the launcher and the apps, included
// by app.cpp inside struct CApp ([SPLITS]: moved out as they were).

	// Apps-specific lua functions

	// connect_server(address: string) -> status: bool, error: string or nil
	static int l_connect_server(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ address = lua_bindings::lua_tocppstring(L, 1);

		self->remember_menu_ui();
		ss_ error;
		bool ok = self->m_state->connect(to_local_pipe(address), &error);
		lua_pushboolean(L, ok);
		if(ok)
			lua_pushnil(L);
		else
			lua_pushstring(L, error.c_str());
		return 2;
	}

	// connect_server_start(address: string): the same connect on a worker,
	// so that the frame keeps drawing while it runs ([BOX_PLAYTEST_2] 12).
	// connect_server_poll() is what says how it went.
	static int l_connect_server_start(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ address = lua_bindings::lua_tocppstring(L, 1);
		self->remember_menu_ui();
		self->m_state->connect_start(to_local_pipe(address));
		return 0;
	}

	// connect_server_poll() -> status: "pending"|"ok"|"failed",
	// error: string or nil
	static int l_connect_server_poll(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ error;
		const int r = self->m_state->connect_poll(&error);
		lua_pushstring(L, r == 0 ? "pending" : (r > 0 ? "ok" : "failed"));
		if(r < 0)
			lua_pushstring(L, error.c_str());
		else
			lua_pushnil(L);
		return 2;
	}

	// list_launchers() -> {{kind = "app"|"builtin"|"extension", name, path},
	// ...}: every apps/<name>, builtin/<name> and extensions/<name> in the
	// tree, with whether it ships launcher/init.lua as `launcher = true`.
	// Nothing else is scanned -- not a save, not a Luanti game's mods. The
	// menu draws the launch grid from this and runs the launcher files in
	// the sandbox ([LAUNCH_GRID]).
	static int l_list_launchers(lua_State *L)
	{
		const ss_ share = g_client_config.get<ss_>("share_path");
		const struct { const char *kind; const char *dir; } kinds[] = {
			{"app", "apps"}, {"builtin", "builtin"},
			{"extension", "extensions"}};
		lua_newtable(L);
		int i = 1;
		for(const auto &k : kinds){
			const ss_ dir = share+"/"+k.dir;
			auto nodes = interface::fs::list_directory(dir);
			sv_<ss_> names;
			for(const auto &n : nodes)
				if(n.is_directory && valid_app_name(n.name))
					names.push_back(n.name);
			std::sort(names.begin(), names.end());
			for(const ss_ &name : names){
				const ss_ path = interface::fs::get_absolute_path(dir+"/"+name);
				lua_newtable(L);
				lua_pushstring(L, k.kind);
				lua_setfield(L, -2, "kind");
				lua_pushstring(L, name.c_str());
				lua_setfield(L, -2, "name");
				lua_pushstring(L, path.c_str());
				lua_setfield(L, -2, "path");
				lua_pushboolean(L, interface::fs::path_exists(
						path+"/launcher/init.lua"));
				lua_setfield(L, -2, "launcher");
				lua_rawseti(L, -2, i++);
			}
		}
		// And the apps installed from releases, every version a tile
		sv_<ss_> ids = installed_app_ids();
		for(const ss_ &id : ids){
			const ss_ path = interface::fs::get_absolute_path(
					installed_app_dir(id));
			lua_newtable(L);
			lua_pushstring(L, "installed");
			lua_setfield(L, -2, "kind");
			lua_pushstring(L, id.c_str());
			lua_setfield(L, -2, "name");
			lua_pushstring(L, path.c_str());
			lua_setfield(L, -2, "path");
			lua_pushboolean(L, interface::fs::path_exists(
					path+"/launcher/init.lua"));
			lua_setfield(L, -2, "launcher");
			set_package_icon(L, path);
			lua_rawseti(L, -2, i++);
		}
		// And a reviewer's playtests ([AITTA_REVIEW]), as installed ones
		for(const ss_ &id : review_app_ids()){
			const ss_ path = interface::fs::get_absolute_path(
					review_app_dir(id));
			lua_newtable(L);
			lua_pushstring(L, "review");
			lua_setfield(L, -2, "kind");
			lua_pushstring(L, id.c_str());
			lua_setfield(L, -2, "name");
			lua_pushstring(L, path.c_str());
			lua_setfield(L, -2, "path");
			lua_pushboolean(L, interface::fs::path_exists(
					path+"/launcher/init.lua"));
			lua_setfield(L, -2, "launcher");
			set_package_icon(L, path);
			lua_rawseti(L, -2, i++);
		}
		// And an author's own ([AITTA_PUBLISH_UI]): an app with its
		// launcher, run as dev:<name>; an extension as an installed one
		for(const DevEntry &e : dev_entries()){
			if(e.kind == "extension" && e.client_name.empty())
				continue;
			const ss_ path = interface::fs::get_absolute_path(e.dir);
			lua_newtable(L);
			lua_pushstring(L, e.kind == "app" ? "dev" : "extension");
			lua_setfield(L, -2, "kind");
			lua_pushstring(L, (e.kind == "app" ? e.name : e.client_name).c_str());
			lua_setfield(L, -2, "name");
			lua_pushstring(L, path.c_str());
			lua_setfield(L, -2, "path");
			lua_pushboolean(L, e.kind == "app" && interface::fs::path_exists(
					path+"/launcher/init.lua"));
			lua_setfield(L, -2, "launcher");
			if(e.kind == "app")
				set_package_icon(L, path);
			lua_rawseti(L, -2, i++);
		}
		// And the installed extensions ([AITTA]), with no launcher: a
		// launcher launches apps, and one from Aitta launches only itself
		for(const ss_ &id : installed_app_ids(true)){
			const size_t dot = id.find('.'), at = id.find('@');
			const ss_ name = id.substr(0, dot)+"__"+
					id.substr(dot + 1, at - dot - 1);
			// The author's own of the same name is the one loaded
			if(installed_extension_dir(name) != installed_app_dir(id))
				continue;
			const ss_ path = interface::fs::get_absolute_path(
					installed_app_dir(id));
			lua_newtable(L);
			lua_pushstring(L, "extension");
			lua_setfield(L, -2, "kind");
			lua_pushstring(L, name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushstring(L, path.c_str());
			lua_setfield(L, -2, "path");
			lua_pushstring(L, id.substr(at + 1).c_str());
			lua_setfield(L, -2, "version");
			lua_pushboolean(L, false);
			lua_setfield(L, -2, "launcher");
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}

	// **A game's own icon, made reachable.** A Luanti game ships
	// menu/icon.png in its own directory under the user path, and a
	// resource dir may only be added under the cache path
	// (add_resource_dir()), so the file is copied there once, under
	// <cache>/installed_games/<app>/<name>.png -- namespaced by app and
	// game, so no two collide ([LAUNCH_API]). Returns the resource name to
	// draw it by, or "" where the game ships no icon.
	static ss_ installed_game_icon(lua_State *L, const ss_ &family,
			const ss_ &name)
	{
		const ss_ from = g_client_config.get<ss_>("user_path")+"/shared/"+
				family+"/games/"+name+"/menu/icon.png";
		if(!interface::fs::path_exists(from))
			return "";
		const ss_ root = g_client_config.get<ss_>("cache_path")+
				"/installed_games";
		const ss_ to = root+"/"+family+"/"+name+".png";
		// Copied when it is not there or the game's has changed size: a
		// game is installed rarely and this is asked every time the grid
		// is shown
		if(!interface::fs::path_exists(to) ||
				interface::fs::file_size(to) !=
				interface::fs::file_size(from)){
			interface::fs::create_directories(root+"/"+family);
			if(!interface::fs::copy_file(from, to)){
				log_w(MODULE, "installed_game_icon(): cannot copy %s",
						cs(from));
				return "";
			}
		}
		static std::set<ss_> added;
		if(added.insert(root).second){
			lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
			CApp *self = (CApp*)lua_touserdata(L, -1);
			lua_pop(L, 1);
			magic::ResourceCache *rc = self->GetSubsystem<
					magic::ResourceCache>();
			if(!rc->AddResourceDir(root.c_str()))
				log_w(MODULE, "installed_game_icon(): cannot add %s",
						cs(root));
		}
		return family+"/"+name+".png";
	}

	// [PACKAGE_MEDIA] An installed or dev app's own icon, its manifest's
	// "icon": checked and copied to <cache>/package_media/<sha256>.png, a
	// resource dir. The resource name, or "" for none
	static ss_ package_icon(lua_State *L, const ss_ &dir)
	{
		json::json_error_t e;
		const json::Value m = json::load_file((dir+"/meta.json").c_str(), &e);
		const ss_ name = m.get("icon").is_string() ?
				m.get("icon").as_string() : "";
		if(name.empty() || name.find("..") != ss_::npos)
			return "";
		std::ifstream f(dir+"/"+name, std::ios::binary);
		const ss_ data((std::istreambuf_iterator<char>(f)),
				std::istreambuf_iterator<char>());
		const ss_ why = interface::aitta::media_check("icon", data);
		if(!why.empty()){
			log_w(MODULE, "%s: %s", cs(dir), cs(why));
			return "";
		}
		const ss_ h = interface::sha256::hex(interface::sha256::calculate(data));
		const ss_ path = g_client_config.get<ss_>("cache_path")+
				"/package_media/"+h+".png";
		if(!interface::fs::path_exists(path)){
			std::ofstream o(path, std::ios::binary);
			o<<data;
			if(!o.good())
				return "";
		}
		return h+".png";
	}
	static void set_package_icon(lua_State *L, const ss_ &dir)
	{
		const ss_ icon = package_icon(L, dir);
		if(icon.empty())
			return;
		lua_pushstring(L, icon.c_str());
		lua_setfield(L, -2, "icon");
	}

	// list_installed_games(app) -> {{name =, size =, icon =}, ...}: the
	// directories under <user>/shared/<app>/games, for a launcher file that
	// offers a tile per game another engine's app installed -- "vanilla"
	// is the Luanti games ([PROCESS_SANDBOX]: what an app shares is
	// <user>/shared/<app>). In the sandbox: read-only and only that one
	// directory shape ([LAUNCH_GRID]).
	//
	// The size is the directory tree's, as list_apps() answers for a
	// buildat game, and it is what a launch action carries as its
	// significance ([LAUNCH_API]); the icon is the resource name of the
	// game's own menu/icon.png, or nil where the game ships none.
	static int l_list_installed_games(lua_State *L)
	{
		const ss_ family = lua_bindings::lua_tocppstring(L, 1);
		if(!valid_app_name(family))
			return luaL_error(L, "list_installed_games(): bad app");
		const ss_ dir = g_client_config.get<ss_>("user_path")+"/shared/"+
				family+"/games";
		sv_<ss_> names;
		for(const auto &n : interface::fs::list_directory(dir))
			if(n.is_directory && valid_app_name(n.name))
				names.push_back(n.name);
		std::sort(names.begin(), names.end());
		lua_newtable(L);
		int i = 1;
		for(const ss_ &name : names){
			lua_newtable(L);
			lua_pushstring(L, name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushnumber(L, (lua_Number)interface::fs::directory_tree_size(
					dir+"/"+name));
			lua_setfield(L, -2, "size");
			const ss_ icon = installed_game_icon(L, family, name);
			if(icon != ""){
				lua_pushstring(L, icon.c_str());
				lua_setfield(L, -2, "icon");
			}
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}

	// list_saves([app]) -> {{app =, name =, modified =}, ...}: every
	// save under <user>/apps/<app>/saves/<name>/save.sqlite, newest
	// first, for the whole tree or for one app. That path is the
	// storage module's own (builtin/storage/storage.cpp), and it is
	// enumerated here rather than asked of a server because a launcher
	// has no server to ask -- which is what [LAUNCH_WORLD] wanted it
	// for: a save is a thing on its floor, listed beside its games.
	//
	// Read-only, names only, and only that one directory shape, as
	// list_installed_games() is.
	// The three lines builtin/storage keeps for itself; one caller here
	// does not earn a place in the fs interface
	static int64_t save_modified_us(const ss_ &path)
	{
		struct stat st;
		if(stat(path.c_str(), &st) != 0)
			return 0;
		return (int64_t)st.st_mtime * 1000000;
	}

	static int l_list_saves(lua_State *L)
	{
		ss_ only_game;
		if(lua_gettop(L) >= 1 && !lua_isnil(L, 1)){
			only_game = lua_bindings::lua_tocppstring(L, 1);
			if(!valid_app_name(only_game))
				return luaL_error(L, "list_saves(): bad app name");
		}
		const ss_ games = g_client_config.get<ss_>("user_path")+"/apps";
		struct Row { ss_ game, name; int64_t modified; };
		sv_<Row> rows;
		for(const auto &g : interface::fs::list_directory(games)){
			if(!g.is_directory || !valid_app_name(g.name))
				continue;
			if(only_game != "" && g.name != only_game)
				continue;
			const ss_ dir = games+"/"+g.name+"/saves";
			for(const auto &n : interface::fs::list_directory(dir)){
				// _server is the server's accounts (builtin/accounts), and a
				// save beginning with _ is none of the player's
				if(!n.is_directory || !valid_app_name(n.name) ||
						n.name[0] == '_')
					continue;
				const ss_ db = dir+"/"+n.name+"/save.sqlite";
				if(!interface::fs::path_exists(db))
					continue;
				rows.push_back(Row{g.name, n.name,
						save_modified_us(db)});
			}
		}
		// The one played last is the one most likely wanted next, which
		// is the order the vanilla menu puts them in
		std::sort(rows.begin(), rows.end(), [](const Row &a, const Row &b){
			if(a.modified != b.modified)
				return a.modified > b.modified;
			return a.name < b.name;
		});
		lua_newtable(L);
		int i = 1;
		for(const Row &r : rows){
			lua_newtable(L);
			lua_pushstring(L, r.game.c_str());
			lua_setfield(L, -2, "app");
			lua_pushstring(L, r.name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushnumber(L, (double)r.modified);
			lua_setfield(L, -2, "modified");
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}

	// **The publish screen's file work** ([AITTA_PUBLISH_UI]), trusted
	// only (client/extensions/starport/publish.lua). aitta_dev(op, ...):
	//   "list"                  {{name, kind, path}} of <user>/dev_apps
	//   "new", name, kind       a minimal app or extension there -> its
	//                           path, or nil and why
	//   "check", json[, name]   why the manifest is refused, or ""; with
	//                           the dev package's name, its images too
	//   "engine_api"            the engine API a manifest says
	//   "keygen", author        <user>/aitta_keys/<author>.key made ->
	//                           the public key, or nil and why
	//   "public", author        that key's public half, or nil
	//   "files", name           what a pack of it takes, and the bytes
	//   "pack", name            packed and signed with its author's key
	//                           into <user>/aitta_releases -> the .zip's
	//                           path, or nil and why
	//   "page_read", name       [AITTA_PACKAGE_PAGE] its aitta_page/: the
	//                           description, {screenshot names} and the
	//                           directory's path
	//   "page_pack", name, text the description written there and the
	//                           page packed and signed -> the .zip's
	//                           path, or nil and why
	//   "open", path            the system's file manager there
	static bool plain_aitta_name(const ss_ &s)
	{
		if(s.empty() || s.size() > 40)
			return false;
		for(char c : s)
			if(!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
				return false;
		return true;
	}
	static void write_text(const ss_ &path, const ss_ &text)
	{
		std::ofstream f(path, std::ios::binary);
		f<<text;
		if(!f.good())
			throw Exception("cannot write "+path);
	}
	static ss_ read_text(const ss_ &path)
	{
		std::ifstream f(path, std::ios::binary);
		std::ostringstream os;
		os<<f.rdbuf();
		return os.str();
	}
	static int l_aitta_dev(lua_State *L)
	{
		const ss_ op = lua_bindings::lua_tocppstring(L, 1);
		const ss_ arg = lua_isstring(L, 2) ? lua_bindings::lua_tocppstring(L, 2) : "";
		const ss_ user = g_client_config.get<ss_>("user_path");
		const ss_ keys = user+"/aitta_keys";
		try {
			if(op == "list"){
				lua_newtable(L);
				int i = 1;
				for(const DevEntry &e : dev_entries()){
					lua_newtable(L);
					lua_pushstring(L, e.name.c_str());
					lua_setfield(L, -2, "name");
					lua_pushstring(L, e.kind.c_str());
					lua_setfield(L, -2, "kind");
					lua_pushstring(L, interface::fs::get_absolute_path(
							e.dir).c_str());
					lua_setfield(L, -2, "path");
					lua_rawseti(L, -2, i++);
				}
				return 1;
			}
			if(op == "new"){
				const ss_ kind = lua_isstring(L, 3) ?
						lua_bindings::lua_tocppstring(L, 3) : "app";
				if(!plain_aitta_name(arg) || (kind == "extension" &&
						(arg.front() == '_' || arg.back() == '_' ||
						arg.find("__") != ss_::npos)))
					throw Exception("A name is 1 to 40 of a-z, 0-9 and _"+
							ss_(kind == "extension" ? ", with no \"__\" and "
							"not starting or ending with _" : ""));
				const ss_ dir = dev_apps_path()+"/"+arg;
				if(interface::fs::path_exists(dir))
					throw Exception(arg+" is there already");
				// Its saves are under its name, as a bundled app's
				if(kind == "app" && interface::fs::path_exists(
						g_client_config.get<ss_>("share_path")+"/apps/"+arg))
					throw Exception(arg+" is the name of an app that comes "
							"with buildat");
				json::Value m = json::object();
				m.set("name", arg);
				m.set("version", "0.1.0");
				m.set("engine_api", (int64_t)interface::aitta::ENGINE_API);
				m.set("kind", kind);
				// simplified: written here and not copied from a template
				// in share/, as it is three small files
				if(kind == "extension"){
					interface::fs::create_directories(dir);
					write_text(dir+"/init.lua",
							"-- "+arg+": a client extension, run in the sandbox.\n"
							"-- An app's client Lua has it by require(), under\n"
							"-- the name \"<author>__"+arg+"\".\n"
							"local M = {safe = {}}\n\n"
							"function M.safe.hello()\n"
							"\treturn \"Hello from "+arg+"\"\n"
							"end\n\n"
							"return M\n");
				} else if(kind == "app"){
					interface::fs::create_directories(dir+"/launcher");
					interface::fs::create_directories(dir+"/main/client_lua");
					write_text(dir+"/launcher/init.lua",
							"-- The tile on the launch grid\n"
							"return function(ctx) return {{id = \"play\", label = \""+
							arg+"\",\n\trun = function() ctx.launch{app = \""+arg+
							"\"} end}} end\n");
					write_text(dir+"/main/meta.json",
							"{\n\t\"disable_cpp\": true,\n"
							"\t\"client_main\": \"init.lua\",\n"
							"\t\"dependencies\": [\n"
							"\t\t{\"module\": \"network\"},\n"
							"\t\t{\"module\": \"client_lua\"},\n"
							"\t\t{\"module\": \"client_data\"}\n"
							"\t]\n}\n");
					write_text(dir+"/main/client_lua/init.lua",
							"-- "+arg+": what the player sees. doc/client_api.txt\n"
							"local log = buildat.Logger(\""+arg+"\")\n"
							"local magic = require(\"buildat/extension/urho3d\")\n"
							"log:info(\""+arg+" started\")\n"
							"local t = magic.ui.root:CreateChild(\"Text\")\n"
							"t:SetStyleAuto()\n"
							"t.text = \"Hello from "+arg+"\"\n"
							"t:SetFont(magic.cache:GetResource(\"Font\", buildat.font_mono), 24)\n"
							"t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)\n");
				} else {
					throw Exception("kind: \"app\" or \"extension\"");
				}
				write_text(dir+"/meta.json", m.stringify()+"\n");
				lua_pushstring(L, interface::fs::get_absolute_path(dir).c_str());
				return 1;
			}
			if(op == "check"){
				json::json_error_t err;
				const json::Value m = json::load_string(arg.c_str(), &err);
				ss_ why = interface::aitta::check_manifest(m);
				// [PACKAGE_MEDIA] And its images, given the package's name
				const ss_ dir = lua_isstring(L, 3) ? dev_app_dir("dev:"+
						lua_bindings::lua_tocppstring(L, 3)) : "";
				if(why.empty() && !dir.empty())
					why = interface::aitta::check_media(m, dir);
				lua_pushstring(L, why.c_str());
				return 1;
			}
			if(op == "engine_api"){
				lua_pushinteger(L, interface::aitta::ENGINE_API);
				return 1;
			}
			if(op == "keygen" || op == "public"){
				if(!plain_aitta_name(arg))
					throw Exception("An author name is 1 to 40 of a-z, 0-9 and _");
				const ss_ path = keys+"/"+arg+".key";
				if(op == "public"){
					if(!interface::fs::path_exists(path))
						return 0;
					lua_pushstring(L, interface::aitta::public_of(
							read_text(path)).c_str());
					return 1;
				}
				if(interface::fs::path_exists(path))
					throw Exception(path+" is there already; a key is "
							"never overwritten");
				ss_ key, pub;
				interface::aitta::keygen(key, pub);
				interface::fs::create_directories(keys);
				write_text(path, key);
				lua_pushstring(L, pub.c_str());
				return 1;
			}
			if(op == "files" || op == "pack"){
				const ss_ dir = dev_app_dir("dev:"+arg);
				if(dir.empty() || !interface::fs::path_exists(dir))
					throw Exception("no "+arg+" in "+dev_apps_path());
				if(op == "files"){
					const sv_<ss_> names = interface::aitta::package_files(dir);
					lua_newtable(L);
					int i = 1;
					for(const ss_ &n : names){
						lua_pushstring(L, n.c_str());
						lua_rawseti(L, -2, i++);
					}
					lua_pushnumber(L, (lua_Number)
							interface::fs::directory_tree_size(dir));
					return 2;
				}
				json::json_error_t err;
				const json::Value m = json::load_file((dir+"/meta.json").c_str(),
						&err);
				const ss_ author = m.get("author").is_string() ?
						m.get("author").as_string() : "";
				const ss_ key = keys+"/"+author+".key";
				if(!plain_aitta_name(author) || !interface::fs::path_exists(key))
					throw Exception("no key for the author \""+author+"\" in "+
							keys);
				lua_pushstring(L, interface::aitta::pack(dir, key,
						user+"/aitta_releases").c_str());
				return 1;
			}
			if(op == "page_read" || op == "page_pack"){
				const ss_ dir = dev_app_dir("dev:"+arg);
				if(dir.empty() || !interface::fs::path_exists(dir))
					throw Exception("no "+arg+" in "+dev_apps_path());
				const ss_ page = dir+"/aitta_page";
				if(op == "page_read"){
					lua_pushstring(L, read_text(page+"/description.txt").c_str());
					sv_<ss_> shots;
					if(interface::fs::path_exists(page))
						for(const auto &n : interface::fs::list_directory(page))
							if(!n.is_directory && n.name != "description.txt" &&
									n.name[0] != '.')
								shots.push_back(n.name);
					std::sort(shots.begin(), shots.end());
					lua_newtable(L);
					for(size_t i = 0; i < shots.size(); i++){
						lua_pushstring(L, shots[i].c_str());
						lua_rawseti(L, -2, i + 1);
					}
					lua_pushstring(L, interface::fs::get_absolute_path(page).c_str());
					return 3;
				}
				json::json_error_t err;
				const json::Value m = json::load_file((dir+"/meta.json").c_str(),
						&err);
				const ss_ author = m.get("author").is_string() ?
						m.get("author").as_string() : "";
				const ss_ name = m.get("name").is_string() ?
						m.get("name").as_string() : "";
				const ss_ key = keys+"/"+author+".key";
				if(!plain_aitta_name(author) || !plain_aitta_name(name) ||
						!interface::fs::path_exists(key))
					throw Exception("no key for the author \""+author+"\" in "+
							keys);
				interface::fs::create_directories(page);
				write_text(page+"/description.txt", lua_isstring(L, 3) ?
						lua_bindings::lua_tocppstring(L, 3) : "");
				lua_pushstring(L, interface::aitta::pack_page(page, author+"/"+
						name, key, user+"/aitta_releases").c_str());
				return 1;
			}
			if(op == "open"){
				if(!interface::process::open_with_system(arg))
					throw Exception("cannot open "+arg);
				lua_pushboolean(L, true);
				return 1;
			}
		} catch(std::exception &e){
			lua_pushnil(L);
			lua_pushstring(L, e.what());
			return 2;
		}
		return luaL_error(L, "aitta_dev: no op \"%s\"", op.c_str());
	}

	// open_url(url) -> true, or nil and why: the system's opener on a link,
	// trusted only ([VERSION_CHECK]: a new version's, from a Starport)
	static int l_open_url(lua_State *L)
	{
		const ss_ url = lua_bindings::lua_tocppstring(L, 1);
		if(!open_url_ok(url)){
			lua_pushnil(L);
			lua_pushstring(L, "not a link this client opens");
			return 2;
		}
		if(!interface::process::open_with_system(url)){
			lua_pushnil(L);
			lua_pushstring(L, "the system's opener could not be run");
			return 2;
		}
		lua_pushboolean(L, true);
		return 1;
	}

	// open_log_folder() -> true, or nil and why: the system's file manager
	// on the folder the log is in ([LOG_REACH]). No argument: the path is
	// the native side's own, so nothing a script gives reaches the shell.
	// Trusted only: launch_menu's Settings.
	static int l_open_log_folder(lua_State *L)
	{
		ss_ dir = g_client_config.get<ss_>("log_path");
		const size_t slash = dir.find_last_of("/\\");
		dir = slash == ss_::npos ? ss_() : dir.substr(0, slash);
		// simplified: a path with a quote is refused rather than escaped
		// (the POSIX openers go through a shell)
		if(dir.empty() || dir.find_first_of("'\"\n") != ss_::npos){
			lua_pushnil(L);
			lua_pushstring(L, dir.empty() ? "no log file" :
					"the log's folder has a quote in its path");
			return 2;
		}
#ifdef _WIN32
		std::replace(dir.begin(), dir.end(), '/', '\\');
#endif
		if(!interface::process::open_with_system(dir)){
			lua_pushnil(L);
			lua_pushstring(L, "the system's opener could not be run");
			return 2;
		}
		lua_pushboolean(L, true);
		return 1;
	}

	// open_import_folder() -> true, or nil and why: the system's file
	// manager on <user>/shared/<the locally launched app>/import, made if
	// missing ([LUANTI_IMPORT_FOLDER]: vanilla's Luanti imports). No
	// argument, as open_log_folder: the path is the native side's own. An
	// app may call it (on the user's click), for its own local server only.
	// simplified: one fixed subdirectory per app; an app-chosen name under
	// its shared directory is the upgrade, when a second app wants one.
	static int l_open_import_folder(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ address = self->m_state ? self->m_state->get_address() : "";
		if(address.empty() || !connected_locally(address)){
			lua_pushnil(L);
			lua_pushstring(L, "not a local server");
			return 2;
		}
		ss_ dir = g_client_config.get<ss_>("user_path")+"/shared/"+
				g_local_server_app+"/import";
		if(dir.find_first_of("'\"\n") != ss_::npos){
			lua_pushnil(L);
			lua_pushstring(L, "the import folder has a quote in its path");
			return 2;
		}
		interface::fs::create_directories(dir);
#ifdef _WIN32
		std::replace(dir.begin(), dir.end(), '/', '\\');
#endif
		if(!interface::process::open_with_system(dir)){
			lua_pushnil(L);
			lua_pushstring(L, "the system's opener could not be run");
			return 2;
		}
		log_i(MODULE, "Opened the import folder %s", cs(dir));
		lua_pushboolean(L, true);
		return 1;
	}

	// aitta_install(zip, sig[, aitta[, review]]) -> the directory, or nil
	// and why: a release fetched from an Aitta, checked and installed under
	// <user>/installed ([AITTA_MVP]); with review, a reviewer's playtest
	// under <user>/review ([AITTA_REVIEW]). The Aitta, where given, in its
	// .aitta_from: where its tile's Report... goes ([AITTA_REPORTS]).
	// Trusted only: client/extensions/starport.
	static int l_aitta_install(lua_State *L)
	{
		const ss_ zip = lua_bindings::lua_tocppstring(L, 1);
		const ss_ sig = lua_bindings::lua_tocppstring(L, 2);
		const ss_ from = lua_isstring(L, 3) ?
				lua_bindings::lua_tocppstring(L, 3) : "";
		const bool review = lua_toboolean(L, 4);
		const ss_ tmp = g_client_config.get<ss_>("cache_path")+"/tmp/aitta-"+
				interface::sha256::hex(interface::bignum::random_bytes(8));
		try {
			interface::fs::create_directories(
					g_client_config.get<ss_>("cache_path")+"/tmp");
			for(const auto &f : {std::make_pair(tmp+".zip", zip),
					std::make_pair(tmp+".sig", sig)}){
				std::ofstream o(f.first, std::ios::binary);
				o<<f.second;
				if(!o.good())
					throw Exception("cannot write "+f.first);
			}
			const ss_ dir = interface::aitta::install(tmp+".zip", tmp+".sig",
					g_client_config.get<ss_>("user_path"), review);
			if(!from.empty()){
				std::ofstream o(dir+"/.aitta_from", std::ios::binary);
				o<<from<<"\n";
			}
			interface::fs::remove_all(tmp+".zip");
			interface::fs::remove_all(tmp+".sig");
			lua_pushstring(L, dir.c_str());
			return 1;
		} catch(std::exception &e){
			interface::fs::remove_all(tmp+".zip");
			interface::fs::remove_all(tmp+".sig");
			lua_pushnil(L);
			lua_pushstring(L, e.what());
			return 2;
		}
	}

	// remove_review(id) -> true, or nil and why: a playtest's tile gone
	// ([AITTA_REVIEW]), its directory with it. simplified: its saves stay
	// under <user>/apps/review.<author>__<name>, for a playtest again.
	// Trusted only: the grid.
	static int l_remove_review(lua_State *L)
	{
		const ss_ dir = review_app_dir(lua_bindings::lua_tocppstring(L, 1));
		if(dir.empty() || !interface::fs::path_exists(dir)){
			lua_pushnil(L);
			lua_pushstring(L, "no such playtest");
			return 2;
		}
		interface::fs::remove_all(dir);
		lua_pushboolean(L, true);
		return 1;
	}

	// list_apps() -> {{name=, size=, kind=}, ...}; kind is main/meta.json's
	// ([APP_CATEGORY]): world, arena, app, other, experiment, check or ""
	static int l_list_apps(lua_State *L)
	{
		ss_ games_dir = g_client_config.get<ss_>("share_path")+"/apps";
		auto nodes = interface::fs::list_directory(games_dir);
		sv_<ss_> names;
		for(const auto &n : nodes){
			if(!n.is_directory || !valid_app_name(n.name))
				continue;
			names.push_back(n.name);
		}
		std::sort(names.begin(), names.end());
		for(const ss_ &id : installed_app_ids())
			names.push_back(id);
		// And a reviewer's playtests ([AITTA_REVIEW])
		for(const ss_ &id : review_app_ids())
			names.push_back(id);
		// And an author's own ([AITTA_PUBLISH_UI])
		for(const DevEntry &e : dev_entries())
			if(e.kind == "app")
				names.push_back("dev:"+e.name);
		lua_newtable(L);
		int i = 1;
		for(const ss_ &name : names){
			ss_ game_path = app_dir(name);
			lua_newtable(L);
			lua_pushstring(L, name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushnumber(L, (lua_Number)interface::fs::directory_tree_size(
					game_path));
			lua_setfield(L, -2, "size");
			lua_pushstring(L, app_kind(game_path).c_str());
			lua_setfield(L, -2, "kind");
			lua_rawseti(L, -2, i++);
		}
		return 1;
	}

	// start_local_server(game: string [, launch: string]) -> status: bool,
	// error: string or nil. launch is what an untrusted launcher asked for,
	// key=value a line, handed to the server as -u ([LAUNCH_GRID]); never
	// the environment, since a sandboxed script choosing a child's
	// environment is a breach.
	static int l_start_local_server(lua_State *L)
	{
		ss_ game = lua_bindings::lua_tocppstring(L, 1);
		ss_ launch = lua_isstring(L, 2) ? lua_bindings::lua_tocppstring(L, 2) : "";
		ss_ game_path = app_dir(game);
		if(game_path.empty()){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Invalid app name");
			return 2;
		}
		// An app from a release is someone else's code: never started with
		// the box off ([AITTA_MVP])
		{
			const char *u = getenv("BUILDAT_UNCONFINED");
			const char *w = getenv("BUILDAT_WINDOWS_SANDBOX");
			if(!w)
				w = getenv("BUILDAT_WINDOWS_BOX");
			if((!installed_app_dir(game).empty() ||
					!review_app_dir(game).empty()) &&
					((u && ss_(u) == "1") || (w && ss_(w) == "0"))){
				lua_pushboolean(L, false);
				lua_pushstring(L, "An installed app runs only in the server's\n"
						"sandbox, and it is off here\n(BUILDAT_UNCONFINED=1 or "
						"BUILDAT_WINDOWS_SANDBOX=0).");
				return 2;
			}
		}

		if(!interface::fs::path_exists(game_path)){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Game not found");
			return 2;
		}

		adopt_pidfile();
		const ss_ launch_lines = launch.empty() ? ss_("launcher=1") :
				"launcher=1\n"+launch;
		if(g_local_server_reusable && g_local_server_app == server_app_id(game) &&
				interface::process::is_running(g_local_server)){
			log_i(MODULE, "Reusing the local server on port %s",
					cs(g_local_server_port));
			g_local_server_launch = launch_lines;
			lua_pushboolean(L, true);
			lua_pushnil(L);
			return 2;
		}
		if(interface::process::is_running(g_local_server)){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Previous local server is still running");
			return 2;
		}
		g_local_server.impl = 0;
		clear_pidfile();

		ss_ server_path = interface::os::get_sibling_exe_path("buildat_server");
		if(!interface::fs::path_exists(server_path)){
			lua_pushboolean(L, false);
			lua_pushstring(L, "buildat_server not found");
			return 2;
		}
#ifndef _WIN32
		// The server compiles a game's modules as it loads them, and on
		// Linux the compiler is the system's ([PACKAGING]): said here, in
		// the dialog, rather than as a server that exits at once
		if(interface::process::shell_exec("c++ --version >/dev/null 2>&1") != 0){
			lua_pushboolean(L, false);
			lua_pushstring(L, "No C++ compiler (c++) found in PATH.\n"
					"buildat compiles a game's modules as it loads them.\n"
					"Debian, Ubuntu:  sudo apt install build-essential\n"
					"Fedora:  sudo dnf install gcc-c++");
			return 2;
		}
#endif

		game_path = interface::fs::get_absolute_path(game_path);
		g_local_server_app = server_app_id(game);
		g_local_server_port = pick_free_local_port();
		log_i(MODULE, "Starting local server on port %s", cs(g_local_server_port));
		{
			const ss_ raw = interface::bignum::random_bytes(16);
			g_local_server_token.clear();
			static const char *hex = "0123456789abcdef";
			for(unsigned char c : raw){
				g_local_server_token += hex[c >> 4];
				g_local_server_token += hex[c & 15];
			}
#ifdef _WIN32
			_putenv_s("BUILDAT_OWNER_TOKEN", g_local_server_token.c_str());
#else
			setenv("BUILDAT_OWNER_TOKEN", g_local_server_token.c_str(), 1);
#endif
		}
		sv_<ss_> args{"-m", game_path, "-P", g_local_server_port,
				// This machine only, until its owner opens it to the LAN
				// from the pause menu (the user's call, [SECURITY_RUN_1])
				"-A", "127.0.0.1",
				// The client's own paths, so that a client started on other
				// paths than the build's (-D, -C, the same letters both sides: a test on empty ones,
				// [FIRST_RUN]) has its server on the same
				// Absolute, as the log path below is and for the same
				// reason: the child's cwd is not this process's, and a
				// relative -D then names a directory beside the tree
				// rather than the tree's own -- the server made its saves
				// somewhere the client never looks (2026-09-24)
				"-D", interface::fs::get_absolute_path(
						g_client_config.get<ss_>("user_path")),
				"-C", interface::fs::get_absolute_path(
						g_client_config.get<ss_>("cache_path"))};
		// The server the client starts writes beside the client's own log
		// when there is one: half of what a bug report is about happens over
		// there, and -L asked for a log of the session. Not the same file --
		// a line here is several fprintf calls and log_no_nl leaves one
		// unfinished on purpose, so two processes appending to one file
		// splice each other's halves.
		// And always one ([START_PROGRESS]): a player's client has no
		// -L, and its server then logged nowhere -- nothing to read after
		// a failed start, and nothing for the waiting screen to tail.
		// cache/local_server_<port>.log at info, truncated per start;
		// the port tells several clients' servers from one tree apart.
		// The server's log beside the client's: <log>_server.<ext>, and
		// the client's is absolute by now (boot::autodetect::open_log), so
		// the child finds it wherever it starts ([WIN8_START]: a relative
		// path resolved against the child's cwd, which on one box was
		// nowhere -- "Invalid file handle. Error is 3"). The previous one
		// is rotated to _1 beside it, as the client's own is. With the
		// client on its default log that is cache/buildat_server.log.
		// The server's log beside the client's -L: <log>_server.<ext>,
		// absolute by now (boot::autodetect::open_log), so the child finds
		// it wherever it starts ([WIN8_START]: a relative path resolved
		// against the child's cwd, which on one box was nowhere --
		// "Invalid file handle. Error is 3"). Rotation is the server's
		// own (open_log, the same for every path). With no -L the server
		// defaults to <cache>/buildat_server.log by itself.
		const ss_ log_file = g_client_config.get<ss_>("log_file");
		if(!log_file.empty()){
			const size_t slash = log_file.find_last_of("/\\");
			const size_t dot = log_file.find_last_of('.');
			const bool has_ext = dot != ss_::npos &&
					(slash == ss_::npos || dot > slash);
			g_local_server_log = (has_ext ? log_file.substr(0, dot) : log_file)+
					"_server"+(has_ext ? log_file.substr(dot) : ss_());
			args.push_back("-L");
			args.push_back(g_local_server_log);
			args.push_back("-l");
			args.push_back(itos(log_get_max_level()));
		} else {
			// The server's level from the preferences ([LOG_LEVEL_PREF]);
			// a -l given to this client for the run is handed on instead
			args.push_back("-l");
			args.push_back(itos(g_client_config.get<bool>("log_level_given") ?
					log_get_max_level() : g_server_log_level_pref));
			g_local_server_log = g_client_config.get<ss_>("cache_path")+
					"/buildat_server.log";
		}
		g_local_server_log_offset = 0;
		g_local_server_listening = false;
		g_local_server_started_s = (int64_t)time(NULL);
		g_local_server_status.clear();
		log_i(MODULE, "server log: %s", cs(g_local_server_log));
		// And whether that server restarts a module when its source
		// changes, which is off unless this client was asked for it
		if(g_client_config.get<bool>("reload_modules"))
			args.push_back("-R");
		// The server knows it is this launcher's: its own user joins by
		// name alone, and a game keeps its launcher-only doors open
		// (builtin/accounts, [VANILLA_PUBLIC] 1). Whoever else starts a
		// server gives it no -u, and it is a public one.
		args.push_back("-u");
		args.push_back(launch_lines);
		g_local_server_launch = launch_lines;
		g_local_server_reusable = false;
		// Started in the root, whatever the client's cwd: from bin/ (a
		// click on the exe) every path it forms would be off by one
		g_local_server = interface::process::start(server_path, args,
				g_client_config.get<ss_>("root_path"));
		// The child has it; nothing started later inherits it
#ifdef _WIN32
		_putenv_s("BUILDAT_OWNER_TOKEN", "");
#else
		unsetenv("BUILDAT_OWNER_TOKEN");
#endif
		if(!g_local_server.valid()){
			lua_pushboolean(L, false);
			lua_pushstring(L, "Failed to start server");
			return 2;
		}
		write_pidfile();
		lua_pushboolean(L, true);
		lua_pushnil(L);
		return 2;
	}

	// stop_local_server()
	static int l_stop_local_server(lua_State *L)
	{
		// Across frames ([QUIT_STALL]): the blocking one froze the
		// window for up to twelve seconds when a UI handler called it
		begin_stop_local_server();
		return 0;
	}

	// user_activated() -> bool: the window has the input and the user
	// pressed or let go of a key, a button or the screen within a second
	// -- what a browser calls user activation, for what may only follow
	// the user's own action (the clipboard's write, safe_classes.lua)
	static int l_user_activated(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_pushboolean(L, self->GetSubsystem<magic::Input>()->HasFocus() &&
				interface::os::time_us() - self->m_last_press_us < 1000000);
		return 1;
	}

	// set_ui_scale(scale: number)  -- <=0 restores auto/config
	static int l_set_ui_scale(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		double s = lua_tonumber(L, 1);
		// 0.25 to 8: a server's Lua asking for 1e308 made every glyph a
		// page of its own that failed, a frame in tens of seconds
		self->m_ui_scale_lua = (s > 0) ? (float)std::max(0.25, std::min(s, 8.0)) : 0.f;
		self->apply_ui_scale();
		return 0;
	}

	// logical_size() -> w, h: the frame a scan's and a sequence's pixels
	// are in -- the -w size in a scripted client ([SEQ_FIXED_SIZE]), the
	// window otherwise
	static int l_logical_size(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::Graphics *g = self->GetSubsystem<magic::Graphics>();
		if(self->logical_mode()){
			lua_pushinteger(L, self->m_logical_w);
			lua_pushinteger(L, self->m_logical_h);
		} else {
			lua_pushinteger(L, g ? g->GetWidth() : 0);
			lua_pushinteger(L, g ? g->GetHeight() : 0);
		}
		return 2;
	}

	// get_ui_scale() -> number
	static int l_get_ui_scale(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::UI *ui = self->GetSubsystem<magic::UI>();
		lua_pushnumber(L, ui ? ui->GetScale() : 1.0);
		return 1;
	}

	// keyboard_height() -> the on-screen keyboard's height in UI pixels,
	// 0 with none up and on a native client ([CHAT_FIELD_TOUCH]). The web
	// page reads it (buildatKeyboard in src/client/web/index.html).
	static int l_keyboard_height(lua_State *L)
	{
		int h = 0;
#ifdef __EMSCRIPTEN__
		h = EM_ASM_INT({
			return window.buildatKeyboard ? buildatKeyboard.height() : 0;
		});
#endif
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		magic::UI *ui = self->GetSubsystem<magic::UI>();
		lua_pushinteger(L, (int)(h / (ui ? ui->GetScale() : 1.0f)));
		return 1;
	}

	// display_density() -> device pixels per CSS pixel on the web
	// (devicePixelRatio), 1 natively ([HUD_DENSITY]).
	// simplified: natively 1; a desktop's reported DPI is often wrong. A
	// native mobile build would read the platform's.
	// received() -> the bytes read from the server since the connect, and
	// the seconds since the last came (nil before any, or with no server)
	// ([JOIN_PROGRESS])
	static int l_received(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		size_t bytes = 0;
		int64_t last_us = 0;
		if(self->m_state)
			self->m_state->get_received(&bytes, &last_us);
		lua_pushnumber(L, (double)bytes);
		if(last_us == 0)
			return 1;
		lua_pushnumber(L, (get_timeofday_us() - last_us) / 1e6);
		return 2;
	}

	// last_arrival() -> nil before anything came, else {t, kind, name |
	// x, y, z | what}: the last file, chunk or other packet from the
	// server, t on get_time_us()'s clock ([LOADING_STRIPES])
	static int l_last_arrival(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		if(!self->m_state)
			return 0;
		client::Arrival a = self->m_state->get_last_arrival();
		if(a.kind.empty())
			return 0;
		lua_newtable(L);
		lua_pushnumber(L, (double)a.t);
		lua_setfield(L, -2, "t");
		lua_pushstring(L, a.kind.c_str());
		lua_setfield(L, -2, "kind");
		if(a.kind == "chunk"){
			lua_pushinteger(L, a.x);
			lua_setfield(L, -2, "x");
			lua_pushinteger(L, a.y);
			lua_setfield(L, -2, "y");
			lua_pushinteger(L, a.z);
			lua_setfield(L, -2, "z");
		} else {
			lua_pushlstring(L, a.name.c_str(), a.name.size());
			lua_setfield(L, -2, a.kind == "file" ? "name" : "what");
		}
		return 1;
	}

	static int l_display_density(lua_State *L)
	{
		double d = 1;
#ifdef __EMSCRIPTEN__
		d = EM_ASM_DOUBLE({ return window.devicePixelRatio || 1; });
#endif
		lua_pushnumber(L, d > 0 ? d : 1);
		return 1;
	}

	// viewport_generation() -> number: how many times anybody has set
	// the preferred viewports in this run ([LAUNCH_WORLD]). A launch UI
	// records it when a launch commits and watches for it to change,
	// which is the game taking the screen; sandbox-safe, and a number
	// rather than a callback because the reader asks once a frame.
	static int l_viewport_generation(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_pushinteger(L, self->m_viewport_generation);
		return 1;
	}

	// get_preferred_render_scale() -> number
	static int l_get_preferred_render_scale(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_pushnumber(L, self->m_options.graphics.render_scale);
		return 1;
	}

	// The preferences a screen can show and change. Their values live in
	// app::Options and the C++ side is what parses, range checks and
	// persists them, so a screen is a page of widgets over these two calls
	// and knows nothing about the file.
	static const char** preference_names()
	{
		static const char *names[] = {"render_scale", "vsync", "max_fps",
				"multisampling", "sound_volume_db", "sound_mute", "ui_size", "lan_discovery",
				"launch_ui",
				"default_username",
#ifdef __EMSCRIPTEN__
				// Only where it does something
				"web_idle_fps",
				"web_address_bar",
				"screen_orientation",
#endif
				nullptr};
		return names;
	}

	// launch_ui_fell_back() -> the name of the launch UI that was asked
	// for and did not load, or nil. What the one that did load says to
	// the user, so a setting that quietly does nothing is not a thing
	// this slot can do ([LAUNCH_SANDBOX]).
	static int l_launch_ui_fell_back(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		if(self->m_launch_ui_fell_back.empty())
			lua_pushnil(L);
		else
			lua_pushstring(L, self->m_launch_ui_fell_back.c_str());
		return 1;
	}

	// crash_dump_untold() -> the path of a crash's minidump in the cache
	// that no start has told about yet, or nil ([WIN_MINIDUMP]; Windows
	// writes them, the local server's too). Told once: the first call
	// marks it.
	static int l_crash_dump_untold(lua_State *L)
	{
		static bool asked = false;
		static ss_ path;
		if(!asked){
			asked = true;
			path = interface::debug::crash_dump_untold(
					g_client_config.get<ss_>("cache_path"));
			if(!path.empty())
				log_w(MODULE, "A crash left a minidump: %s", cs(path));
		}
		if(path.empty())
			lua_pushnil(L);
		else
			lua_pushstring(L, path.c_str());
		return 1;
	}

	// get_preference(name) -> number, boolean or string, or nil for a name there is
	// no preference by
	static int l_get_preference(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ name = luaL_checkstring(L, 1);
		const app::Options &o = self->m_options;
		if(name == "render_scale" && o.graphics.render_scale_auto)
			lua_pushstring(L, "auto");
		else if(name == "render_scale")
			lua_pushnumber(L, o.graphics.render_scale);
		else if(name == "vsync")
			lua_pushboolean(L, o.graphics.vsync);
		else if(name == "max_fps")
			lua_pushinteger(L, o.graphics.max_fps);
		else if(name == "web_idle_fps")
			lua_pushinteger(L, o.graphics.web_idle_fps);
#ifdef __EMSCRIPTEN__
		// Unset is what the page makes of it: the bar hidden or shown
		else if(name == "web_address_bar")
			lua_pushstring(L, !o.graphics.web_address_bar.empty() ?
					o.graphics.web_address_bar.c_str() :
					EM_ASM_INT({ return Module['buildatHideBarByDefault'](); }) ?
					"hide" : "show");
		else if(name == "screen_orientation")
			lua_pushstring(L, o.graphics.screen_orientation.c_str());
		// Not a preference: why the page's last lock was refused, or nil
		else if(name == "screen_orientation_error"){
			char *e = (char*)EM_ASM_PTR({
				var e = Module['buildatOrientationError'];
				return e ? stringToNewUTF8(e) : 0;
			});
			if(!e)
				return 0;
			lua_pushstring(L, e);
			free(e);
		}
#endif
		else if(name == "multisampling")
			lua_pushinteger(L, o.graphics.multisampling);
		else if(name == "sound_volume_db")
			lua_pushnumber(L, o.sound_volume_db);
		else if(name == "lan_discovery")
			lua_pushboolean(L, o.lan_discovery);
		else if(name == "sound_mute")
			lua_pushboolean(L, o.sound_mute);
		else if(name == "ui_size" && o.ui_size_auto)
			lua_pushstring(L, "auto");
		else if(name == "ui_size")
			lua_pushnumber(L, o.ui_size);
		else if(name == "launch_ui")
			lua_pushstring(L, o.launch_ui.c_str());
		else if(name == "default_username")
			lua_pushstring(L, o.default_username.c_str());
		else if(name == "log_level")
			lua_pushinteger(L, o.log_level);
		else if(name == "server_log_level")
			lua_pushinteger(L, o.server_log_level);
		else
			lua_pushnil(L);
		return 1;
	}

	// set_preference(name, value) -> true, or false and why
	//
	// Through the same parser -o and the preferences file go through, so a
	// range check is written once and a screen cannot set something a flag
	// could not. What it changes takes effect now and is persisted, unless
	// this run was told not to remember anything -- a -o run, a -c run --
	// in which case it still takes effect and save_preferences() declines.
	static int l_set_preference(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ name = luaL_checkstring(L, 1);
		ss_ value;
		if(lua_isboolean(L, 2))
			value = lua_toboolean(L, 2) ? "1" : "0";
		else
			value = luaL_checkstring(L, 2);

		app::Options parsed = self->m_options;
		ss_ err;
		if(!app::parse_preference_options(name+"="+value, &parsed, &err)){
			lua_pushboolean(L, 0);
			lua_pushstring(L, err.c_str());
			return 2;
		}
		settle_render_scale(&parsed);
		const app::Options before = self->m_options;
		self->m_options = parsed;
		self->apply_changed_preferences(before);
		save_preferences(self->m_options);
		lua_pushboolean(L, 1);
		return 1;
	}

	// get_env(name) -> the environment variable, or nil when unset or when
	// the name does not start with BUILDAT_. A knob a harness sets on the
	// client's process, the way extensions/luanti_client reads its own
	// outside the sandbox; the prefix is the fence, so a game cannot read
	// the user's environment through this.
	// HTTP for the extension environment ([SERVER_LIST]: Luanti's official
	// server list): __buildat_http_get(url[, body]) starts a fetch -- a POST of JSON with a body -- on a thread of
	// its own and answers a job id; __buildat_http_poll(id) answers nil
	// while it runs, then (true, body) or (false, error) once, and forgets
	// the job. A redirect is not followed: (false, why, target) says where
	// it led, and the extension asks about that host as about any other. Who may fetch what is the network extension's question,
	// which gates this behind its permission dialog the way it gates a
	// socket; the sandbox never sees these two names.
	struct HttpJob {
		std::thread thread;
		std::atomic<bool> done{false};
		bool ok = false;
		ss_ result;
		ss_ redirect;
	};
	std::map<int, sp_<HttpJob>> m_http_jobs;
	int m_http_next_id = 1;

	// **JSON for the sandbox** ([URHO_SWEEP], 2026-09-25): a game that
	// fetched a body with `network.http_get` had no way to read it, and
	// Urho3D's own JSONValue is not the answer -- its GetRoot() hands
	// Lua a pointer into the file, which dangles the moment the file is
	// collected. The parse is the client's own (core/json.h, sajson) and
	// what comes back is **plain Lua**: tables, strings, numbers and
	// booleans, so nothing holds a C++ object and no lifetime crosses
	// the sandbox.
	//
	// null becomes nil, which in an array leaves a hole -- said in
	// client_api.txt, because a length that stops early is otherwise a
	// puzzle. A document deeper than this nests no further.
	static const int JSON_MAX_DEPTH = 64;
	static void push_json(lua_State *L, const json::Value &v, int depth)
	{
		if(depth > JSON_MAX_DEPTH){
			lua_pushnil(L);
			return;
		}
		switch(v.get_type()){
		case json::Value::T_BOOL:
			lua_pushboolean(L, v.as_boolean());
			break;
		case json::Value::T_INT:
			lua_pushnumber(L, (lua_Number)v.as_integer());
			break;
		case json::Value::T_FLOAT:
			lua_pushnumber(L, (lua_Number)v.as_real());
			break;
		case json::Value::T_STRING:
			lua_pushstring(L, v.as_cstring());
			break;
		case json::Value::T_ARRAY: {
			lua_newtable(L);
			const unsigned int n = v.size();
			for(unsigned int i = 0; i < n; i++){
				push_json(L, v.at(i), depth + 1);
				lua_rawseti(L, -2, (int)i + 1);
			}
			break;
		}
		case json::Value::T_OBJECT: {
			lua_newtable(L);
			for(json::Iterator it(v); it.valid(); it.next()){
				push_json(L, it.value(), depth + 1);
				lua_setfield(L, -2, it.ckey());
			}
			break;
		}
		default:
			lua_pushnil(L);
			break;
		}
	}

	// parse_json(text) -> value, or nil and why not
	static int l_parse_json(lua_State *L)
	{
		size_t len = 0;
		const char *text = luaL_checklstring(L, 1, &len);
		// A trust boundary: the body came off the network. sajson holds
		// the whole document in memory and the copy here doubles it, so
		// the size is capped rather than left to the fetch's own limits.
		if(len > 8u * 1024 * 1024){
			lua_pushnil(L);
			lua_pushstring(L, "parse_json: over 8 MB");
			return 2;
		}
		json::json_error_t err;
		const json::Value v = json::load_string(text, &err);
		if(v.get_type() == json::Value::T_UNDEFINED){
			lua_pushnil(L);
			lua_pushfstring(L, "parse_json: %s (line %d, column %d)",
					err.text, err.line, err.column);
			return 2;
		}
		push_json(L, v, 0);
		return 1;
	}

	static int l_http_get(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ url = luaL_checkstring(L, 1);
		// A second argument, a body, makes it a POST of JSON ([STARPORT])
		const bool post = lua_isstring(L, 2);
		const ss_ body = post ? lua_bindings::lua_tocppstring(L, 2) : ss_();
#ifdef __EMSCRIPTEN__
		// [WEB_ID_TRUST] (c): the browser's fetch(), under its rules -- the
		// other origin answers with CORS or the fetch fails. text/plain so
		// a POST is a simple request (no preflight; Starport reads the
		// body whatever its type). A redirect is not followed and says
		// no target: the browser does not tell it.
		const int id = self->m_http_next_id++;
		web_fetch(id, url.c_str(), post ? 1 : 0, body.data(), (int)body.size());
		lua_pushinteger(L, id);
		return 1;
#else
		sp_<HttpJob> job(new HttpJob());
		const int id = self->m_http_next_id++;
		self->m_http_jobs[id] = job;
		HttpJob *j = job.get();
		j->thread = std::thread([j, url, post, body](){
			try {
				j->result = post ? interface::http_post(url, body,
						"application/json", &j->redirect) :
						interface::http_get(url, &j->redirect);
				j->ok = j->redirect.empty();
				if(!j->ok)
					j->result = "redirected to "+j->redirect;
			} catch(std::exception &e){
				j->result = e.what();
			}
			j->done = true;
		});
		lua_pushinteger(L, id);
		return 1;
#endif
	}

	static int l_http_poll(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const int id = (int)luaL_checkinteger(L, 1);
#ifdef __EMSCRIPTEN__
		// -1 no such job, -2 running, else the length; ok in the sign of
		// a second call's answer
		const int len = EM_ASM_INT({
			var jobs = Module['buildatHttp'] || {};
			if(!(($0) in jobs)) return -1;
			var j = jobs[$0];
			return j ? j.data.length : -2;
		}, id);
		if(len == -2){
			lua_pushnil(L);
			return 1;
		}
		if(len == -1){
			lua_pushboolean(L, false);
			lua_pushstring(L, "no such fetch");
			return 2;
		}
		ss_ data(len, '\0');
		const int ok = EM_ASM_INT({
			var jobs = Module['buildatHttp'];
			var j = jobs[$0];
			delete jobs[$0];
			HEAPU8.set(j.data, $1);
			return j.ok ? 1 : 0;
		}, id, &data[0]);
		(void)self;
		lua_pushboolean(L, ok);
		lua_pushlstring(L, data.data(), data.size());
		return 2;
#else
		auto it = self->m_http_jobs.find(id);
		if(it == self->m_http_jobs.end()){
			lua_pushboolean(L, false);
			lua_pushstring(L, "no such fetch");
			return 2;
		}
		if(!it->second->done){
			lua_pushnil(L);
			return 1;
		}
		sp_<HttpJob> job = it->second;
		self->m_http_jobs.erase(it);
		job->thread.join();
		lua_pushboolean(L, job->ok);
		lua_pushlstring(L, job->result.c_str(), job->result.size());
		if(job->redirect.empty())
			return 2;
		lua_pushlstring(L, job->redirect.c_str(), job->redirect.size());
		return 3;
#endif
	}

	static int l_get_env(lua_State *L)
	{
		const ss_ name = luaL_checkstring(L, 1);
		if(name.compare(0, 8, "BUILDAT_") != 0){
			lua_pushnil(L);
			return 1;
		}
		const char *v = getenv(name.c_str());
		if(v)
			lua_pushstring(L, v);
		else
			lua_pushnil(L);
		return 1;
	}

	// is_scripted() -> true when a command sequence drives this client
	static int l_is_scripted(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_pushboolean(L, self->m_command_seq_active);
		return 1;
	}

	// [TAP_BACK] press_back(): Escape, pressed and let go, as the keyboard
	// would: every screen's own Escape handling is what Back does
	static int l_press_back(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		ss_ err;
		if(!client::command_seq::inject_key(
				self->GetSubsystem<magic::Input>(), "Escape", true, true, &err))
			log_w(MODULE, "press_back: %s", cs(err));
		return 0;
	}

	// [TAP_BACK] set_back_depth(n): how many screens the main stack holds,
	// which the web page's Back reads: above 1 Back is Escape, at 1 it
	// leaves the page
	static int l_set_back_depth(lua_State *L)
	{
		const int n = (int)luaL_checkinteger(L, 1);
#ifdef __EMSCRIPTEN__
		EM_ASM({ Module.buildatSetBackDepth($0); }, n);
#else
		(void)n;
#endif
		return 0;
	}

	// [HEARTH_WEB_BACK] leave_web_page(go) -> on the web, whether there is
	// a page before this one, and with go, back to it past the page's own
	// entries; nil natively
	static int l_leave_web_page(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		lua_pushboolean(L, EM_ASM_INT({ return Module.buildatLeavePage($0); },
				lua_toboolean(L, 1) ? 1 : 0));
		return 1;
#else
		(void)L;
		return 0;
#endif
	}

	// list_preferences() -> {name, ...}
	static int l_list_preferences(lua_State *L)
	{
		const char **names = preference_names();
		lua_newtable(L);
		for(int i = 0; names[i]; i++){
			lua_pushstring(L, names[i]);
			lua_rawseti(L, -2, i + 1);
		}
		return 1;
	}

	// request_stop_local_server()
	static int l_request_stop_local_server(lua_State *L)
	{
		request_stop_local_server();
		return 0;
	}

	// force_kill_local_server()
	static int l_force_kill_local_server(lua_State *L)
	{
		force_kill_local_server();
		return 0;
	}

	// The local server's log from where the last read left off, for its
	// "STATUS ..." lines; "STATUS Listening" is the one readiness reads
	static void tail_local_server_log()
	{
		if(g_local_server_log.empty())
			return;
		// Not the run before: a default log is rotated away by the child
		// when it starts, and until then the file here is the old one,
		// with an old "Listening" in it
		struct stat st;
		if(stat(g_local_server_log.c_str(), &st) != 0 ||
				(int64_t)st.st_mtime < g_local_server_started_s)
			return;
		std::ifstream f(g_local_server_log, std::ios::binary);
		if(!f.good())
			return;
		f.seekg(g_local_server_log_offset);
		ss_ line;
		while(std::getline(f, line)){
			g_local_server_log_offset += line.size() + 1;
			// A log written on Windows ends its lines in \r\n, and the
			// status read as "Listening\r" never matched ([WIN8_START] 12)
			if(!line.empty() && line[line.size() - 1] == '\r')
				line.erase(line.size() - 1);
			const size_t at = line.find("STATUS ");
			if(at != ss_::npos){
				g_local_server_status = line.substr(at + 7);
				if(g_local_server_status == "Listening")
					g_local_server_listening = true;
			}
		}
	}

	// local_server_ready() -> bool: the server runs and has logged that it
	// listens. Read from its log rather than by connecting to it: a probe
	// connect was a peer to the server, one that vanished before it said
	// anything, and the server warned about it twice per start
	// ([WIN8_START] 11). A server started by somebody else (the pidfile's)
	// has no log here and is probed.
	static int l_local_server_ready(lua_State *L)
	{
		adopt_pidfile();
		if(!interface::process::is_running(g_local_server)){
			lua_pushboolean(L, false);
			return 1;
		}
		if(g_local_server_log.empty()){
			lua_pushboolean(L, local_server_answers());
			return 1;
		}
		tail_local_server_log();
		// And the port itself, once the log says so: a "Listening" read
		// off a log the previous run left (the box's first ContentDB try,
		// 2026-09-21: the client then connected to a server still
		// loading and sat in the connect for good) is not a server. The
		// non-blocking probe is a peer to the server for a moment, which
		// is the price of not trusting a file.
		lua_pushboolean(L, g_local_server_listening && local_server_answers());
		return 1;
	}

	// local_server_status() -> string or nil: the last "STATUS ..." line
	// the local server logged, read from where the last call left off
	static int l_local_server_status(lua_State *L)
	{
		tail_local_server_log();
		if(g_local_server_status.empty())
			lua_pushnil(L);
		else
			lua_pushstring(L, g_local_server_status.c_str());
		return 1;
	}

	// local_server_log_tail(lines) -> path, text: the local server's log
	// file and its last lines, for a dialog about a server that died
	static int l_local_server_log_tail(lua_State *L)
	{
		const int want = luaL_optinteger(L, 1, 20);
		lua_pushstring(L, g_local_server_log.c_str());
		std::ifstream f(g_local_server_log, std::ios::binary);
		std::deque<ss_> lines;
		ss_ line;
		while(f.good() && std::getline(f, line)){
			if(!line.empty() && line[line.size() - 1] == '\r')
				line.erase(line.size() - 1);
			// The dialog does not wrap, and a file list can be a
			// thousand characters: the line's start is the part that
			// says what it was
			if(line.size() > 160)
				line = line.substr(0, 157) + "...";
			lines.push_back(line);
			if((int)lines.size() > want)
				lines.pop_front();
		}
		ss_ text;
		for(const ss_ &l : lines)
			text += l + "\n";
		lua_pushstring(L, text.c_str());
		return 2;
	}

	// local_server_port() -> string
	static int l_local_server_port(lua_State *L)
	{
		lua_pushstring(L, g_local_server_port.c_str());
		return 1;
	}

	// local_server_running() -> bool
	// game_storage_dir() -> the directory under the user path where the
	// game code of the server this client is connected to keeps what it
	// stores on the client, or nil when there is no server (a serverless
	// app's is its local server's, [SERVERLESS_PLAY]): like a web
	// page's localStorage, one per origin. A server this client started is
	// its game's (the port changes every launch); any other its address's,
	// so a server cannot read what another one, or a local game, stored.
	// server_address() -> the address the client is connected to, or nil.
	// Trusted only: client/extensions/starport's report of the server one is on
	static int l_server_address(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ address = self->m_state ? self->m_state->get_address() : "";
		if(address.empty())
			return 0;
		lua_pushlstring(L, address.c_str(), address.size());
		return 1;
	}

	// lan_address() -> "a.b.c.d" or nothing: this machine's address on the
	// LAN, for the pause menu's "Open to LAN" to say. Only while connected
	// to the server this client started: to any other, where this machine
	// is on its network is not that server's business.
	// keep_server_icon(png) -> its hash, or nil: a Starport listing's icon
	// ([SERVER_ICONS]), checked and kept as the handshake's is
	static int l_keep_server_icon(lua_State *L)
	{
		size_t n = 0;
		const char *d = luaL_checklstring(L, 1, &n);
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ sha = self->keep_icon(ss_(d, n), "a Starport");
		if(sha.empty())
			return 0;
		lua_pushstring(L, sha.c_str());
		return 1;
	}

	// keep_package_media(data, which) -> resource name, or nil and why:
	// an Aitta release's "icon" or "screenshot" ([PACKAGE_MEDIA]), checked
	// as Aitta checks it and kept under <cache>/package_media (a resource
	// dir) as <sha256>.png or .jpg
	static int l_keep_package_media(lua_State *L)
	{
		size_t n = 0;
		const char *d = luaL_checklstring(L, 1, &n);
		const ss_ which = lua_bindings::lua_tocppstring(L, 2);
		const ss_ data(d, n);
		ss_ type;
		const ss_ why = which == "icon" || which == "screenshot" ?
				interface::aitta::media_check(which, data, &type) :
				"not an icon or a screenshot";
		if(!why.empty()){
			lua_pushnil(L);
			lua_pushstring(L, why.c_str());
			return 2;
		}
		const ss_ name = interface::sha256::hex(interface::sha256::calculate(
				data))+(type == "image/png" ? ".png" : ".jpg");
		const ss_ path = g_client_config.get<ss_>("cache_path")+
				"/package_media/"+name;
		if(!interface::fs::path_exists(path)){
			std::ofstream f(path, std::ios::binary);
			f<<data;
			if(!f.good()){
				lua_pushnil(L);
				lua_pushstring(L, ("cannot write "+path).c_str());
				return 2;
			}
		}
		lua_pushstring(L, name.c_str());
		return 1;
	}

	static int l_lan_address(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ address = self->m_state ? self->m_state->get_address() : "";
		if(self->owner_token_for(address).empty())
			return 0;
		const ss_ lan = interface::local_lan_address();
		if(lan.empty())
			return 0;
		lua_pushlstring(L, lan.c_str(), lan.size());
		return 1;
	}

	// lan_servers() -> {{host, port, name, app, version, players,
	// account}, ...}: the servers announcing themselves on the LAN
	// ([LAN_DISCOVERY]), heard within 6 s. Empty while connected to a
	// server: what is on this machine's network is not a server's
	// business. An announcement is anyone's to send, so every field is
	// cleaned and capped, a sender is heard once a second, and the list
	// holds 32.
	// Nothing until lan_listen() ran: at the start or when lan_discovery
	// was turned on ([WIN_FIREWALL]).
	// simplified: the socket stays open once the launcher has asked; the
	// kernel drops what is not read. Closing it on a connect when a
	// game's long session makes that matter.
	void lan_listen()
	{
		if(m_lan_fd != -1 || m_lan_tried)
			return;
		m_lan_tried = true;
		m_lan_fd = interface::lan_socket(true);
		log_i(MODULE, "Listening for LAN games on %s:%i%s",
				interface::LAN_GROUP, interface::LAN_PORT,
				m_lan_fd == -1 ? ": cannot" :
#ifdef _WIN32
				" (Windows may ask whether to let this program hear "
				"the network: that is what for)"
#else
				""
#endif
				);
	}

	static ss_ lan_clean(const json::Value &v, size_t max, bool ident)
	{
		if(!v.is_string())
			return "";
		ss_ out;
		for(unsigned char c : v.as_string()){
			if(out.size() >= max)
				break;
			if(ident ? (isalnum(c) || c == '_' || c == '-' || c == '.' ||
					c == '+') : (c >= 0x20 && c != 0x7f))
				out += (char)c;
		}
		// A cut multibyte character goes
		while(!out.empty() && ((unsigned char)out.back() & 0xc0) == 0x80)
			out.pop_back();
		if(!out.empty() && ((unsigned char)out.back() & 0xc0) == 0xc0)
			out.pop_back();
		return out;
	}

	static int l_lan_servers(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		lua_newtable(L);
		if(self->m_state && !self->m_state->get_address().empty())
			return 1;
		const int64_t now = interface::os::time_us();
		ss_ data, from;
		for(int i = 0; i < 256 && self->m_lan_fd != -1 &&
				interface::lan_recv(self->m_lan_fd, &data, &from); i++){
			const json::Value v = json::load_string(data.c_str());
			if(!v.is_object() || !v.get("buildat_lan").is_integer() ||
					v.get("buildat_lan").as_integer() != 1 ||
					!v.get("port").is_integer())
				continue;
			const int64_t port = v.get("port").as_integer();
			if(port < 1 || port > 65535)
				continue;
			const ss_ key = interface::join_host_port(from, itos(port));
			auto it = self->m_lan.find(key);
			if(it == self->m_lan.end()){
				if(self->m_lan.size() >= 32){
					if(!self->m_lan_full_said)
						log_w(MODULE, "LAN list full (32): %s and others "
								"not shown", cs(key));
					self->m_lan_full_said = true;
					continue;
				}
			} else if(now - it->second.heard_us < 1000000){
				continue;
			}
			LanEntry &e = self->m_lan[key];
			e.name = lan_clean(v.get("name"), 64, false);
			e.app = lan_clean(v.get("app"), 32, true);
			e.version = lan_clean(v.get("version"), 32, true);
			const json::Value &pl = v.get("players");
			e.players = pl.is_integer() ? std::max<int64_t>(0,
					std::min<int64_t>(pl.as_integer(), 100000)) : 0;
			e.account = v.get("account").is_true();
			e.heard_us = now;
		}
		int n = 0;
		for(auto it = self->m_lan.begin(); it != self->m_lan.end();){
			if(now - it->second.heard_us > 6000000){
				it = self->m_lan.erase(it);
				continue;
			}
			const LanEntry &e = it->second;
			ss_ host, port;
			interface::split_host_port(it->first, &host, &port, "");
			lua_newtable(L);
			lua_pushstring(L, host.c_str());
			lua_setfield(L, -2, "host");
			lua_pushstring(L, port.c_str());
			lua_setfield(L, -2, "port");
			lua_pushstring(L, e.name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushstring(L, e.app.c_str());
			lua_setfield(L, -2, "app");
			lua_pushstring(L, e.version.c_str());
			lua_setfield(L, -2, "version");
			lua_pushinteger(L, e.players);
			lua_setfield(L, -2, "players");
			lua_pushboolean(L, e.account);
			lua_setfield(L, -2, "account");
			lua_rawseti(L, -2, ++n);
			++it;
		}
		return 1;
	}

	// set_client_keys(profiler, fullscreen, screenshot): key codes, 0 for
	// none
	static int l_set_client_keys(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		int k[3];
		for(int i = 0; i < 3; i++){
			k[i] = luaL_checkinteger(L, i + 1);
			if(k[i] == 0)
				k[i] = -1;
		}
		self->m_key_profiler = k[0];
		self->m_key_fullscreen = k[1];
		self->m_key_screenshot = k[2];
		return 0;
	}

	// Whether the client is connected to the local server it started
	static bool connected_locally(const ss_ &address)
	{
		adopt_pidfile();
		return !g_local_server_app.empty() &&
				interface::process::is_running(g_local_server) &&
				(address == "localhost:"+g_local_server_port ||
				address == "127.0.0.1:"+g_local_server_port ||
				(!local_pipe().empty() && address == "pipe:"+local_pipe()));
	}

	static int l_game_storage_dir(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		ss_ address = self->m_state ? self->m_state->get_address() : "";
		ss_ user = g_client_config.get<ss_>("user_path");
		if(address.empty() && !g_serverless_app.empty()){
			lua_pushstring(L, (user+"/apps/"+g_serverless_app+"/client").c_str());
			return 1;
		}
		if(address.empty())
			return 0;
		bool local = connected_locally(address);
		ss_ dir;
		if(local){
			dir = user+"/apps/"+g_local_server_app+"/client";
		} else {
			// One directory name: what is not a letter, a digit, - or . is _
			ss_ name = address;
			for(char &c : name)
				if(!(isalnum((unsigned char)c) || c == '-' || c == '.'))
					c = '_';
			dir = user+"/servers/"+name;
		}
		lua_pushstring(L, dir.c_str());
		return 1;
	}

	static int l_local_server_running(lua_State *L)
	{
		adopt_pidfile();
		lua_pushboolean(L, interface::process::is_running(g_local_server));
		return 1;
	}

	// [SERVERLESS_PLAY] serverless_start(app id) -> {"<module>/<script>",
	// ...} or nil and why: an app's client half with no server. Each
	// module's (a directory with a meta.json) client_lua and client_data
	// into the file table under the names a server announces, and its
	// client_main among those returned, for the caller to run. The storage
	// is the app's own, as with a local server, until leave_to_menu().
	// simplified: the modules in name order, not the loader's dependency
	// order, and no "base" app under it
	// Trusted only: client/api.lua
	static int l_serverless_start(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		const ss_ id = lua_bindings::lua_tocppstring(L, 1);
		const ss_ dir = app_dir(id);
		if(dir.empty() || !interface::fs::path_exists(dir+"/meta.json")){
			lua_pushnil(L);
			lua_pushstring(L, ("no app "+id).c_str());
			return 2;
		}
		sv_<ss_> modules;
		for(const auto &n : interface::fs::list_directory(dir))
			if(n.is_directory && interface::fs::path_exists(
					dir+"/"+n.name+"/meta.json"))
				modules.push_back(n.name);
		std::sort(modules.begin(), modules.end());
		sv_<std::pair<ss_, ss_>> files;
		sv_<ss_> mains;
		std::function<void(const ss_&, const ss_&)> data =
				[&](const ss_ &path, const ss_ &name){
			for(const auto &n : interface::fs::list_directory(path)){
				if(n.is_directory)
					data(path+"/"+n.name, name+n.name+"/");
				else
					files.push_back({name+n.name, path+"/"+n.name});
			}
		};
		for(const ss_ &m : modules){
			const ss_ md = dir+"/"+m;
			for(const auto &n : interface::fs::list_directory(md+"/client_lua"))
				if(!n.is_directory)
					files.push_back({m+"/"+n.name, md+"/client_lua/"+n.name});
			data(md+"/client_data", m+"/");
			json::json_error_t err;
			const json::Value meta = json::load_file(
					(md+"/meta.json").c_str(), &err);
			if(meta.get("client_main").is_string())
				mains.push_back(m+"/"+meta.get("client_main").as_string());
		}
		if(mains.empty()){
			lua_pushnil(L);
			lua_pushstring(L, (id+" has no client_main").c_str());
			return 2;
		}
		try {
			self->m_state->add_local_files(files);
		} catch(std::exception &e){
			lua_pushnil(L);
			lua_pushstring(L, e.what());
			return 2;
		}
		g_serverless_app = server_app_id(id);
		log_i(MODULE, "serverless_start(%s): %zu files, %zu to run",
				cs(id), files.size(), mains.size());
		lua_newtable(L);
		for(size_t i = 0; i < mains.size(); i++){
			lua_pushstring(L, mains[i].c_str());
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
	}

	// disconnect()
	// leave_to_menu(): a menu-only connection left for the launcher without
	// exiting the client ([MENU_CONTEXT]): the local server stopped, the
	// state made ready for another connection, and the sandbox's leavings
	// dropped (client/sandbox.lua). The UI stack is the launcher's to pop.
	static int l_leave_to_menu(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		log_i(MODULE, "leave_to_menu()");
		// **Across frames** ([QUIT_STALL], 2026-09-24): this is called
		// from a Lua UI handler -- it is what "quitting a game" runs --
		// and the blocking stop sleeps up to twelve seconds inside it,
		// with the window dead to the compositor for all of them. The
		// SIGTERM goes now and on_update() reaps the child and
		// force-kills it if it will not go; a menu-only server is gone
		// in a second anyway.
		// A server that holds no world stays for the next launch of
		// its app (launch:reusable)
		if(g_local_server_reusable)
			log_i(MODULE, "Local server kept: it holds no world");
		else
			begin_stop_local_server();
		self->m_state->reset();
		g_serverless_app.clear();
		self->m_lost_connection_us = 0;
		self->m_lost_remote = false;
		// **The last frame of the game goes with the game** ([MENU_LEAVE],
		// 2026-09-27). A game drawn through set_preferred_viewports() --
		// which is every game at a render scale -- is rendered into a
		// texture that a UI image shows, and `forget_game_ui()` skips
		// that image on purpose (it is the client's, not the game's). So
		// leaving emptied the scene and took the viewports away while the
		// image stayed, and the launcher's grid came up over the last
		// frame of the world: driven, the picture two seconds after the
		// leave was the same picture, to the pixel.
		self->drop_preferred_texture();
		self->m_preferred_viewports.clear();
		self->m_preferred_rects.clear();
		self->forget_game_ui();
		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_reset_sandbox");
		if(lua_isfunction(L, -1))
			error_logging_pcall(L, 0, 0);
		else
			lua_pop(L, 1);
		// **The game's sounds go with the game** ([MENU_MUSIC], 2026-10-04):
		// a SoundSource is mixed from its construction to its destruction,
		// scene or no scene, so a looped one whose node the reset took out
		// of the scene -- held by the game's Lua until a collection --
		// went on playing in the launch menu. Everything playing now is
		// the game's: the launch menu plays nothing.
		// simplified: all of them; a launch UI that plays its own sounds
		// through a game would need to keep those apart.
		if(magic::Audio *audio = self->GetSubsystem<magic::Audio>()){
			unsigned n = 0;
			for(magic::SoundSource *s : audio->GetSoundSources()){
				if(s->IsPlaying())
					n++;
				s->Stop();
			}
			log_i(MODULE, "leave_to_menu(): %u sounds stopped", n);
		}
		self->say_what_is_left("leave_to_menu");
		return 0;
	}

	// **What a leave leaves** ([MENU_LEAVE]): the scene the game filled,
	// the viewports that draw it and the camera they draw through, said
	// once at the end of a leave. The report is that the launcher's grid
	// comes up over a world that is still there, and a leave that says
	// what it did not take is the difference between reading that and
	// guessing at it.
	void say_what_is_left(const char *when)
	{
		ss_ line = ss_("what is left after ") + when + ": ";
		if(m_scene){
			const unsigned n = m_scene->GetNumChildren(false);
			line += "the scene holds " + itos(n) + " children";
			unsigned said = 0;
			for(unsigned i = 0; i < n && said < 8; i++){
				magic::Node *c = m_scene->GetChild(i);
				if(!c)
					continue;
				line += (said == 0 ? " (" : ", ");
				line += ss_(c->GetName().CString()) + "#" +
						itos(c->GetID()) + " " +
						itos(c->GetNumComponents()) + " components";
				said++;
			}
			if(said)
				line += n > said ? ", ..." : "";
			if(said)
				line += ")";
		} else {
			line += "no scene";
		}
		// The image the client shows a game's render target through: it
		// is the client's own element, so `forget_game_ui()` leaves it,
		// and it is the last frame of the world if it is still here
		line += ss_("; the preferred image is ") +
				(m_preferred_image ? "still here" : "gone");
		magic::Renderer *r = GetSubsystem<magic::Renderer>();
		if(r){
			line += "; " + itos(r->GetNumViewports()) + " viewports";
			for(unsigned i = 0; i < r->GetNumViewports(); i++){
				magic::Viewport *vp = r->GetViewport(i);
				if(!vp)
					continue;
				magic::Scene *sc = vp->GetScene();
				magic::Camera *cam = vp->GetCamera();
				line += ss_(", ") + itos(i) + ": scene " +
						(sc ? (sc == m_scene ? "the game's" : "another") :
						"none") + ", camera " +
						(cam ? (cam->GetNode() ?
						cam->GetNode()->GetName().CString() : "unnamed") :
						"none");
			}
		}
		log_i(MODULE, "%s", cs(line));
	}

	static int l_disconnect(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		// Exiting a game exits the client, also when started from the
		// launcher: the menu's Urho3D/Lua state is not resettable in place.
		self->shutdown();

		return 0;
	}

	// send_packet(name: string, data: string)
	static int l_send_packet(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);
		ss_ data = lua_bindings::lua_tocppstring(L, 2);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		try {
			self->m_state->send_packet(name, data);
			return 0;
		} catch(std::exception &e){
			log_w(MODULE, "Exception in send_packet: %s", e.what());
			return 0;
		}
	}

	// get_file_path(name: string) -> path, hash
	static int l_get_file_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ hash;
		ss_ path = self->m_state->get_file_path(name, &hash);
		if(path == "")
			return 0;
		lua_pushlstring(L, path.c_str(), path.size());
		lua_pushlstring(L, hash.c_str(), hash.size());
		return 2;
	}

	// get_file_content(name: string)
	static int l_get_file_content(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		try {
			ss_ content = self->m_state->get_file_content(name);
			lua_pushlstring(L, content.c_str(), content.size());
			return 1;
		} catch(std::exception &e){
			log_w(MODULE, "Exception in get_file_content: %s", e.what());
			return 0;
		}
	}

	// When calling Lua from C++, this is universally good
	static void error_logging_pcall(lua_State *L, int nargs, int nresults)
	{
		log_t(MODULE, "error_logging_pcall(): nargs=%i, nresults=%i",
				nargs, nresults);
		//log_d(MODULE, "stack 1: %s", cs(dump_stack(L)));
		int start_L = lua_gettop(L);
		lua_pushcfunction(L, lua_bindings::handle_error);
		lua_insert(L, start_L - nargs);
		int handle_error_L = start_L - nargs;
		//log_d(MODULE, "stack 2: %s", cs(dump_stack(L)));
		int r = lua_pcall(L, nargs, nresults, handle_error_L);
		lua_remove(L, handle_error_L);
		//log_d(MODULE, "stack 3: %s", cs(dump_stack(L)));
		if(r != 0){
			ss_ traceback = lua_bindings::lua_tocppstring(L, -1);
			lua_pop(L, 1);
			const char *msg =
					r == LUA_ERRRUN ? "runtime error" :
			r == LUA_ERRMEM ? "ran out of memory" :
			r == LUA_ERRERR ? "error handler failed" : "unknown error";
			//log_e(MODULE, "Lua %s: %s", msg, cs(traceback));
			throw Exception(ss_()+"Lua "+msg+":\n"+traceback);
		}
		//log_d(MODULE, "stack 4: %s", cs(dump_stack(L)));
	}

	static void call_global_if_exists(lua_State *L,
			const char *global_name, int nargs, int nresults)
	{
		log_t(MODULE, "call_global_if_exists(): \"%s\"", global_name);
		//log_d(MODULE, "stack 1: %s", cs(dump_stack(L)));
		int start_L = lua_gettop(L);
		lua_getfield(L, LUA_GLOBALSINDEX, global_name);
		if(lua_isnil(L, -1)){
			lua_pop(L, 1 + nargs);
			return;
		}
		lua_insert(L, start_L - nargs + 1);
		error_logging_pcall(L, nargs, nresults);
		//log_d(MODULE, "stack 2: %s", cs(dump_stack(L)));
	}

	// get_path(name: string)
	static int l_get_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		if(name == "share"){
			ss_ path = g_client_config.get<ss_>("share_path");
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		if(name == "cache"){
			ss_ path = g_client_config.get<ss_>("cache_path");
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		if(name == "user"){
			ss_ path = g_client_config.get<ss_>("user_path");
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		// The client's own log file ([LOG_REACH]); empty with none (the web)
		if(name == "log"){
			ss_ path = g_client_config.get<ss_>("log_path");
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		if(name == "tmp"){
			ss_ path = g_client_config.get<ss_>("cache_path")+"/tmp";
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		log_w(MODULE, "Unknown named path: \"%s\"", cs(name));
		return 0;
	}

	// set_reload_on_return(bool): on the web, whether a disconnect while
	// the page was away reloads it on the return, which is what a phone's
	// browser dropping a page in the background calls for. A light game
	// asks for it; a heavy one leaves the user to say, with the page's
	// reload button (user, 2026-09-30). Nothing natively.
	static int l_set_reload_on_return(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		EM_ASM({ Module['buildatReloadOnReturn'] = !!$0; },
				lua_toboolean(L, 1) ? 1 : 0);
#endif
		(void)L;
		return 0;
	}

	// set_web_fullscreen(bool): on a touchscreen's web page, whether the
	// page is fullscreen, which is what puts a phone browser's address bar
	// away. Entering waits for the next tap; nothing natively.
	static int l_set_web_fullscreen(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		self->push_web_address_bar();
		EM_ASM({
			Module['buildatFullscreen'] = !!$0;
			Module['buildatSyncFullscreen']();
		}, lua_toboolean(L, 1) ? 1 : 0);
#endif
		(void)L;
		return 0;
	}

	// [WEB_ID_TRUST] web_authorize(url) -> whether a window opened (the
	// browser blocks one not right after a click): a Starport's /authorize
	// page, which posts a token back to this page. web_authorized() -> the
	// message as JSON once that page has sent it, from that page's origin
	// only; nil until then. Trusted Lua's (the starport extension); nothing
	// natively.
	static int l_web_authorize(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		const char *url = luaL_checkstring(L, 1);
		int ok = EM_ASM_INT({
			// The page's own origin, so a page with no game of its own
			// (play.buildat.org, the Starport's web_clients) is told apart
			// After a "?" of its own, or one put there: the plain /id page
			// came as "/id&origin=", which the Starport has no call for
			var url = UTF8ToString($0);
			url += (url.indexOf('?') < 0 ? '?' : '&') + 'origin=' +
					encodeURIComponent(location.origin);
			Module['buildatAuthMsg'] = null;
			Module['buildatAuthOrigin'] = new URL(url).origin;
			if(!Module['buildatAuthListen']){
				Module['buildatAuthListen'] = true;
				window.addEventListener('message', function(e){
					var d = e.data;
					if(e.origin === Module['buildatAuthOrigin'] && d &&
							typeof d.buildat_starport_token === 'string')
						Module['buildatAuthMsg'] = JSON.stringify(d);
				});
			}
			return window.open(url, 'buildat_starport',
					'popup,width=480,height=680') ? 1 : 0;
		}, url);
		lua_pushboolean(L, ok);
#else
		(void)L;
		lua_pushboolean(L, 0);
#endif
		return 1;
	}
	static int l_web_authorized(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		char *msg = (char*)EM_ASM_PTR({
			var m = Module['buildatAuthMsg'];
			Module['buildatAuthMsg'] = null;
			return m ? stringToNewUTF8(m) : 0;
		});
		if(msg){
			lua_pushstring(L, msg);
			free(msg);
			return 1;
		}
#endif
		lua_pushnil(L);
		return 1;
	}

	// [PLAY_PAGE] (c) web_dgram(op, ...): the web's datagram socket (see
	// web_dgram_open above); trusted Lua's (the network extension).
	// ("open", url) -> id; ("send", id, data); ("recv", id) -> a datagram,
	// "" when none; ("state", id) -> "connecting", "open" or "closed: why";
	// ("ack_luanti", id): see network.cpp's ack_luanti; ("close", id).
	// Nothing natively.
	static int l_web_dgram(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		const ss_ op = luaL_checkstring(L, 1);
		if(op == "open"){
			lua_pushinteger(L, web_dgram_open(luaL_checkstring(L, 2)));
			return 1;
		}
		const int id = (int)luaL_checkinteger(L, 2);
		if(op == "send"){
			size_t n = 0;
			const char *p = luaL_checklstring(L, 3, &n);
			web_dgram_send(id, p, (int)n);
		} else if(op == "recv"){
			const int n = web_dgram_peek(id);
			ss_ d(n > 0 ? n : 0, '\0');
			if(n >= 0)
				web_dgram_take(id, &d[0]);
			lua_pushlstring(L, d.data(), d.size());
			return 1;
		} else if(op == "state"){
			char *s = web_dgram_state(id);
			lua_pushstring(L, s);
			free(s);
			return 1;
		} else if(op == "ack_luanti"){
			web_dgram_ack_luanti(id);
		} else if(op == "close"){
			web_dgram_close(id);
		}
#endif
		return 0;
	}

	// set_watchdog_seconds(n): how long without a frame before the
	// watchdog logs this thread's stack; 0 puts the default (10) back
	static int l_set_watchdog_seconds(lua_State *L)
	{
		int n = (int)luaL_optinteger(L, 1, 0);
		g_watchdog_seconds = n > 0 ? n : 10;
		return 0;
	}

	// create_directories(path) -> bool: the directory and its parents, for
	// trusted Lua keeping a file of its own under the user path (the
	// extension's settings made its directory with a shell's mkdir, which
	// Windows has no such of; [BOX_PLAYTEST_2] 1). Unsafe: not in the
	// sandbox, where a path is not a thing a game gets to name.
	static int l_create_directories(lua_State *L)
	{
		ss_ path = lua_bindings::lua_tocppstring(L, 1);
		lua_pushboolean(L, interface::fs::create_directories(path));
		return 1;
	}

	// count_files(path) -> the number of entries in the directory
	static int l_count_files(lua_State *L)
	{
		ss_ path = lua_bindings::lua_tocppstring(L, 1);
		lua_pushinteger(L, interface::fs::list_directory(path).size());
		return 1;
	}

	// take_screenshot() -> the file name it was saved under, or nil and why
	// not.
	//
	// **Safe, and this is the argument for it.** The caller says when, and
	// nothing else: the client picks the directory -- <user>/screenshots --
	// and the name, the date and the time it was taken. Sandboxed
	// code cannot choose a path, cannot read what it wrote, and cannot
	// overwrite an existing shot. What it can do is fill a directory with
	// pictures of the screen, which is what the screenshot key already does
	// and what a game the user is running can reasonably ask for -- a
	// comparison harness photographing itself is the case this was added
	// for; see [ONE_CYCLE] in doc/plan/rendering_plan.md.
	//
	// The file lands at the end of the frame, not inside this call: the
	// buffer is only whole once the frame is drawn, which is why the command
	// sequence's screenshot goes through the same pending slot. The name is
	// reserved by then, so it is the right one to report.
	static int l_take_screenshot(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		// One pending shot at a time: the command sequence uses the same
		// slot, and overwriting it would drop somebody else's picture
		if(!self->m_pending_screenshot.empty()){
			lua_pushnil(L);
			lua_pushstring(L, "a screenshot is already pending");
			return 2;
		}
		// **A run's worth** ([SECURITY_RUN_1]): one a frame was a server's
		// script filling the disk at a frame rate.
		// simplified: per client run, as save_file's
		static int s_shots = 0;
		if(s_shots >= 1000){
			lua_pushnil(L);
			lua_pushstring(L, "1000 screenshots taken already in this run");
			return 2;
		}
		s_shots++;
		const ss_ dir = g_client_config.get<ss_>("user_path")+"/screenshots";
		const ss_ name = client::command_seq::screenshot_name(dir);
		self->m_pending_screenshot = dir+"/"+name;
		lua_pushlstring(L, name.c_str(), name.size());
		return 1;
	}

	// **Files a game hands the user and takes from them** ([FP_EXPORT] 4).
	// The sandbox has no file access of its own, and gets none here: the
	// client picks where a file goes and where one may come from. On
	// native that is <user>/exports, found by the user as the screenshots
	// are; on the web, the browser's download and file picker (the page's
	// buildatFiles, src/client/web/index.html).
	static ss_ exports_dir()
	{
		return g_client_config.get<ss_>("user_path")+"/exports";
	}

	// A name of letters, digits, _ - and ., not hidden, as a file in there
	static ss_ user_file_name(const ss_ &in)
	{
		ss_ out;
		for(char c : in.substr(0, 100))
			out += isalnum((unsigned char)c) || c == '_' || c == '-' ||
					c == '.' ? c : '_';
		while(!out.empty() && out[0] == '.')
			out.erase(0, 1);
		return out.empty() ? "file" : out;
	}

	// save_file(name, data) -> where it went: the path on native, "" for the
	// web's download; or nil and why not. Native never overwrites: a name
	// taken gets _2, _3...
	static int l_save_file(lua_State *L)
	{
		size_t name_len = 0, len = 0;
		const char *name_c = luaL_checklstring(L, 1, &name_len);
		const char *data = luaL_checklstring(L, 2, &len);
		const ss_ name = user_file_name(ss_(name_c, name_len));
		// **A run's worth, not a disk's** ([SECURITY_RUN_1]): a server's
		// script saving in a loop filled the user's disk with no one
		// asking. Not the user's key or click as the clipboard's is: an
		// export is the server's answer, a round trip after the click.
		// simplified: per client run; a run that exports more starts again
		static size_t s_files = 0, s_bytes = 0;
		if(len > MAX_USER_FILE_BYTES || s_files >= 100 ||
				s_bytes + len > 4 * MAX_USER_FILE_BYTES){
			lua_pushnil(L);
			lua_pushstring(L, len > MAX_USER_FILE_BYTES ?
					"the file is over 64 MiB" :
					"100 files or 256 MiB saved already in this run");
			return 2;
		}
		s_files++;
		s_bytes += len;
#ifdef __EMSCRIPTEN__
		EM_ASM({
			if(window.buildatFiles)
				buildatFiles.save(UTF8ToString($0), HEAPU8.slice($1, $1 + $2));
		}, name.c_str(), data, len);
		lua_pushstring(L, "");
		return 1;
#else
		const ss_ dir = exports_dir();
		interface::fs::create_directories(dir);
		const size_t dot = name.find_last_of('.');
		const ss_ stem = dot == ss_::npos ? name : name.substr(0, dot);
		const ss_ ext = dot == ss_::npos ? "" : name.substr(dot);
		ss_ path = dir+"/"+name;
		for(int i = 2; interface::fs::path_exists(path); i++)
			path = dir+"/"+stem+"_"+itos(i)+ext;
		std::ofstream os(path, std::ios::binary);
		os.write(data, len);
		if(!os.good()){
			lua_pushnil(L);
			lua_pushstring(L, ("could not write "+path).c_str());
			return 2;
		}
		lua_pushlstring(L, path.c_str(), path.size());
		return 1;
#endif
	}

	// exported_files([dir]) -> the names of the files in <user>/exports;
	// none on the web, which has pick_file(). With dir, any folder's
	// entries but the hidden ones, a folder's name ending in "/": the
	// picker's browsing ([HEARTH_USABILITY]: a screenshot is not in the
	// exports). Trusted only, as read_exported is.
	static int l_exported_files(lua_State *L)
	{
		const ss_ dir = luaL_optstring(L, 1, "");
		lua_newtable(L);
#ifndef __EMSCRIPTEN__
		int i = 1;
		for(const auto &n : interface::fs::list_directory(
				dir.empty() ? exports_dir() : dir)){
			if(dir.empty() ? n.is_directory || n.name != user_file_name(n.name)
					: n.name.empty() || n.name[0] == '.')
				continue;
			const ss_ name = n.is_directory ? n.name+"/" : n.name;
			lua_pushlstring(L, name.c_str(), name.size());
			lua_rawseti(L, -2, i++);
		}
#endif
		return 1;
	}

	// read_exported(name, [dir]) -> the bytes of that file in
	// <user>/exports, or in dir; or nil and why not
	static int l_read_exported(lua_State *L)
	{
		const ss_ name = luaL_checkstring(L, 1);
		const ss_ dir = luaL_optstring(L, 2, "");
		const ss_ path = (dir.empty() ? exports_dir() : dir)+"/"+name;
		if((dir.empty() ? name != user_file_name(name) : name.empty() ||
				name.find_first_of("/\\") != ss_::npos || name == "..") ||
				!interface::fs::path_exists(path)){
			lua_pushnil(L);
			lua_pushstring(L, "no such file");
			return 2;
		}
		const uint64_t size = interface::fs::file_size(path);
		if(size > MAX_USER_FILE_BYTES){
			lua_pushnil(L);
			lua_pushstring(L, "the file is over 64 MiB");
			return 2;
		}
		// 0 is also what a folder or a device gives: /dev/zero read on
		// for ever. An empty file is no use to pick either.
		if(size == 0){
			lua_pushnil(L);
			lua_pushstring(L, "not a file, or an empty one");
			return 2;
		}
		std::ifstream is(path, std::ios::binary);
		std::ostringstream data;
		data<<is.rdbuf();
		const ss_ s = data.str();
		lua_pushlstring(L, s.data(), s.size());
		return 1;
	}

	// pick_file([accept]) -> whether a picker opened: the web's file picker,
	// accept as the input element's (".fpplan"). What it picks comes from
	// picked_file(). False on native, which has exported_files().
	static int l_pick_file(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		const char *accept = luaL_optstring(L, 1, "");
		EM_ASM({
			if(window.buildatFiles)
				buildatFiles.pick(UTF8ToString($0));
		}, accept);
		lua_pushboolean(L, 1);
#else
		lua_pushboolean(L, 0);
#endif
		return 1;
	}

	// picked_file() -> name, data once the picked file has been read; nil
	// until then; nil and why not for one that is too big
	static int l_picked_file(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		int len = EM_ASM_INT({
			var p = window.buildatFiles && buildatFiles.picked;
			return p ? p.data.length : -1;
		});
		if(len < 0){
			lua_pushnil(L);
			return 1;
		}
		if((size_t)len > MAX_USER_FILE_BYTES){
			EM_ASM({ buildatFiles.picked = null; });
			lua_pushnil(L);
			lua_pushstring(L, "the file is over 64 MiB");
			return 2;
		}
		ss_ data(len, '\0');
		char *name = (char*)EM_ASM_PTR({
			var p = buildatFiles.picked;
			buildatFiles.picked = null;
			HEAPU8.set(p.data, $0);
			return stringToNewUTF8(p.name);
		}, &data[0]);
		lua_pushstring(L, name);
		free(name);
		lua_pushlstring(L, data.data(), data.size());
		return 2;
#else
		lua_pushnil(L);
		return 1;
#endif
	}

	// **A file a part at a time** ([WORLD_TRIM_MOVE]): an exported world is
	// more than one Lua string or one packet holds. save_part_begin(name)
	// -> an id, the name taken as save_file() takes it;
	// save_part_add(id, data) -> true; save_part_end(id, keep) -> the path
	// ("" on the web) when kept, the parts dropped when not; nil and why
	// not on a failure, which drops the parts too. On native the parts go
	// into <name>.part beside where it lands; on the web the page holds
	// them and offers one Blob of them as the download.
	// simplified: a run's worth is 16 files and 16 GiB, as save_file's
	// limits for whole files
	struct SavePart {
		ss_ path;
		up_<std::ofstream> os;
	};
	static sm_<int, SavePart>& save_parts()
	{
		static sm_<int, SavePart> parts;
		return parts;
	}
	static uint64_t& part_bytes()
	{
		static uint64_t n = 0;
		return n;
	}
	static int l_save_part_begin(lua_State *L)
	{
		const ss_ name = user_file_name(luaL_checkstring(L, 1));
		static int s_next = 0;
		if(s_next >= 16){
			lua_pushnil(L);
			lua_pushstring(L, "16 files saved in parts already in this run");
			return 2;
		}
		const int id = ++s_next;
#ifdef __EMSCRIPTEN__
		EM_ASM({
			buildatFiles.parts = buildatFiles.parts || {};
			// In parentheses: a comma between braces splits the macro
			buildatFiles.parts[$0] = ({name: UTF8ToString($1), chunks: []});
		}, id, name.c_str());
		save_parts()[id] = SavePart();
#else
		const ss_ dir = exports_dir();
		interface::fs::create_directories(dir);
		const size_t dot = name.find_last_of('.');
		const ss_ stem = dot == ss_::npos ? name : name.substr(0, dot);
		const ss_ ext = dot == ss_::npos ? "" : name.substr(dot);
		ss_ path = dir+"/"+name;
		for(int i = 2; interface::fs::path_exists(path) ||
				interface::fs::path_exists(path+".part"); i++)
			path = dir+"/"+stem+"_"+itos(i)+ext;
		SavePart &part = save_parts()[id];
		part.path = path;
		part.os.reset(new std::ofstream(path+".part", std::ios::binary));
		if(!part.os->good()){
			save_parts().erase(id);
			lua_pushnil(L);
			lua_pushstring(L, ("could not write "+path+".part").c_str());
			return 2;
		}
#endif
		lua_pushinteger(L, id);
		return 1;
	}
	static void drop_save_part(int id)
	{
		auto it = save_parts().find(id);
		if(it == save_parts().end())
			return;
#ifdef __EMSCRIPTEN__
		EM_ASM({ delete buildatFiles.parts[$0]; }, id);
#else
		it->second.os.reset();
		interface::fs::remove_all(it->second.path+".part");
#endif
		save_parts().erase(it);
	}
	static int l_save_part_add(lua_State *L)
	{
		const int id = (int)luaL_checkinteger(L, 1);
		size_t len = 0;
		const char *data = luaL_checklstring(L, 2, &len);
		auto it = save_parts().find(id);
		const char *why = it == save_parts().end() ? "no such file" :
				part_bytes() + len > (uint64_t)16 * 1024 * 1024 * 1024 ?
				"16 GiB saved in parts already in this run" : nullptr;
		if(!why){
			part_bytes() += len;
#ifdef __EMSCRIPTEN__
			EM_ASM({
				buildatFiles.parts[$0].chunks.push(HEAPU8.slice($1, $1 + $2));
			}, id, data, len);
#else
			it->second.os->write(data, len);
			if(!it->second.os->good())
				why = "could not write the file";
#endif
		}
		if(why){
			drop_save_part(id);
			lua_pushnil(L);
			lua_pushstring(L, why);
			return 2;
		}
		lua_pushboolean(L, 1);
		return 1;
	}
	static int l_save_part_end(lua_State *L)
	{
		const int id = (int)luaL_checkinteger(L, 1);
		const bool keep = lua_toboolean(L, 2);
		auto it = save_parts().find(id);
		if(it == save_parts().end() || !keep){
			drop_save_part(id);
			lua_pushnil(L);
			lua_pushstring(L, keep ? "no such file" : "dropped");
			return 2;
		}
#ifdef __EMSCRIPTEN__
		EM_ASM({
			var p = buildatFiles.parts[$0];
			delete buildatFiles.parts[$0];
			buildatFiles.save(p.name, p.chunks);
		}, id);
		save_parts().erase(it);
		lua_pushstring(L, "");
		return 1;
#else
		const ss_ path = it->second.path;
		it->second.os->close();
		const bool ok = !it->second.os->fail() &&
				std::rename((path+".part").c_str(), path.c_str()) == 0;
		if(!ok){
			drop_save_part(id);
			lua_pushnil(L);
			lua_pushstring(L, ("could not write "+path).c_str());
			return 2;
		}
		save_parts().erase(it);
		lua_pushlstring(L, path.c_str(), path.size());
		return 1;
#endif
	}

	// read_exported_part(name, dir, offset, len) -> the bytes of that file
	// from offset, at most len (16 MiB), and its size; or nil and why not.
	// read_exported()'s rule for name and dir (dir nil: the exports), and
	// trusted only as it is: a game gets a reader of the one file the user
	// picked (client/api.lua)
	static int l_read_exported_part(lua_State *L)
	{
		const ss_ name = luaL_checkstring(L, 1);
		const ss_ dir = luaL_optstring(L, 2, "");
		const lua_Number offset = luaL_checknumber(L, 3);
		const lua_Number len = luaL_checknumber(L, 4);
		const ss_ path = (dir.empty() ? exports_dir() : dir)+"/"+name;
		if((dir.empty() ? name != user_file_name(name) : name.empty() ||
				name.find_first_of("/\\") != ss_::npos || name == "..") ||
				!interface::fs::path_exists(path) || offset < 0 || len < 0 ||
				len > 16 * 1024 * 1024){
			lua_pushnil(L);
			lua_pushstring(L, "no such file, or a part out of range");
			return 2;
		}
		std::ifstream is(path, std::ios::binary);
		is.seekg(0, std::ios::end);
		const int64_t size = is.tellg();
		if(size <= 0){
			lua_pushnil(L);
			lua_pushstring(L, "not a file, or an empty one");
			return 2;
		}
		ss_ data;
		if((int64_t)offset < size){
			data.resize((size_t)std::min<int64_t>((int64_t)len,
					size - (int64_t)offset));
			is.seekg((int64_t)offset);
			is.read(&data[0], data.size());
			data.resize(std::max<std::streamsize>(is.gcount(), 0));
		}
		lua_pushlstring(L, data.data(), data.size());
		lua_pushnumber(L, (lua_Number)size);
		return 2;
	}

	// picked_part(offset, len) -> the web's picked file from offset, at
	// most len (16 MiB), its size and name, the file kept for the next
	// part; nil when none is picked. picked_part(-1) lets it go.
	static int l_picked_part(lua_State *L)
	{
#ifdef __EMSCRIPTEN__
		const lua_Number offset = luaL_checknumber(L, 1);
		const lua_Number len = luaL_optnumber(L, 2, 0);
		if(offset < 0){
			EM_ASM({ buildatFiles.picked = null; });
			return 0;
		}
		const double size = EM_ASM_DOUBLE({
			var p = window.buildatFiles && buildatFiles.picked;
			return p ? p.data.length : -1;
		});
		if(size < 0 || len < 0 || len > 16 * 1024 * 1024){
			lua_pushnil(L);
			return 1;
		}
		const size_t n = (size_t)std::max(0.0, std::min((double)len,
				size - offset));
		ss_ data(n, '\0');
		char *name = (char*)EM_ASM_PTR({
			var p = buildatFiles.picked;
			HEAPU8.set(p.data.subarray($1, $1 + $2), $0);
			return stringToNewUTF8(p.name);
		}, n ? &data[0] : nullptr, (double)offset, n);
		lua_pushlstring(L, data.data(), data.size());
		lua_pushnumber(L, size);
		lua_pushstring(L, name);
		free(name);
		return 3;
#else
		lua_pushnil(L);
		return 1;
#endif
	}

	// dump_meshes([atlas_json]) -> the file name it was saved under, or nil
	// and why not. The optional string is written as <stem>_atlas.json
	// beside the dump: the atlas registry's own account of which resource
	// owns which tile, which the caller has and this does not.
	//
	// Same sandbox rule as take_screenshot(): the caller says when, the
	// client picks <user>/meshdumps and a dated name. Writes the scene's
	// CustomGeometry as one .obj in world space -- the meshes the client
	// already built, not a second voxel dump. For [PATH_TRACE_REF].
	static int l_dump_meshes(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		// Under the node given, else the scene the server replicates: a game
		// with a scene of its own hands over its root
		magic::Node *root = self->m_scene;
		if(lua_isuserdata(L, 2))
			root = (magic::Node*)tolua_tousertype(L, 2, 0);
		if(!root){
			lua_pushnil(L);
			lua_pushstring(L, "no scene");
			return 2;
		}
		// **A run's worth** ([SECURITY_RUN_1]): a whole scene a call, as
		// many calls as a server's script makes in a frame.
		// simplified: per client run, as save_file's
		static int s_dumps = 0;
		if(s_dumps >= 20){
			lua_pushnil(L);
			lua_pushstring(L, "20 mesh dumps made already in this run");
			return 2;
		}
		s_dumps++;

		const ss_ dir = g_client_config.get<ss_>("user_path")+"/meshdumps";
		if(!interface::fs::create_directories(dir)){
			lua_pushnil(L);
			lua_pushstring(L, "cannot create meshdumps");
			return 2;
		}
		char stamp[32] = {};
		const time_t t = time(nullptr);
		struct tm tmv;
#ifdef _WIN32
		localtime_s(&tmv, &t);
#else
		localtime_r(&t, &tmv);
#endif
		strftime(stamp, sizeof stamp, "%Y%m%d_%H%M%S", &tmv);
		// Gzipped as it is written: the raw text of a RANGE=150 dump is
		// ~800 MB and writing it held this thread past the server's
		// 30 s stall limit; through zlib at level 1 it is a sixth of that.
		ss_ name = ss_("meshdump_")+stamp+".obj.gz";
		for(int i = 2; i < 1000 &&
				interface::fs::path_exists(dir+"/"+name); i++)
			name = ss_("meshdump_")+stamp+"_"+itos(i)+".obj.gz";
		const ss_ path = dir+"/"+name;
		// The atlas account the caller hands over, written beside the dump
		// once the textures below are named: its last object is
		// "textures", the read-back file of each atlas texture by address
		const ss_ atlas_json = lua_isstring(L, 1) ? ss_(lua_tostring(L, 1)) : "";

		gzFile f = gzopen(path.c_str(), "wb1");
		if(!f){
			lua_pushnil(L);
			lua_pushstring(L, "cannot write dump");
			return 2;
		}
		// A gzprintf a line is what took a minute on ten million verts,
		// which is past the server's stall limit; a megabyte at a time
		// through gzwrite is seconds
		ss_ buf;
		buf.reserve(1 << 20);
		char line[256];
		auto put = [&](int n){
			if(n > 0)
				buf.append(line, (size_t)n);
			if(buf.size() >= (1 << 20) - 256){
				gzwrite(f, buf.data(), (unsigned)buf.size());
				buf.clear();
			}
		};

		magic::PODVector<magic::Camera*> cams;
		root->GetComponents<magic::Camera>(cams, true);
		if(!cams.Empty() && cams[0]->GetNode()){
			magic::Node *cn = cams[0]->GetNode();
			const magic::Vector3 p = cn->GetWorldPosition();
			const magic::Vector3 d = cn->GetWorldDirection();
			put(snprintf(line, sizeof line, "# camera_pos %g %g %g\n# camera_dir %g %g %g\n",
					p.x_, p.y_, p.z_, d.x_, d.y_, d.z_));
		}

		// The albedo: each batch's diffuse texture, read back once a session
		// and saved beside the dump as meshdump_texN.png, named by usemtl
		// so the render can put it on. The atlas is a handful of textures
		// for a whole world, which is why the read-back is keyed by texture
		// and not by batch or by dump.
		sm_<magic::Texture2D*, ss_> &tex_names = self->m_dumped_textures;
		// What this dump reads back, encoded and written on a thread of its
		// own once the .obj is out: the read-back is the GPU's and quick,
		// the encoding is what took a minute
		sv_<std::pair<ss_, magic::SharedPtr<magic::Image>>> to_write;
		auto material_of = [&](magic::Material *mat) -> ss_ {
			if(!mat)
				return "";
			magic::Texture2D *tex = dynamic_cast<magic::Texture2D*>(
					mat->GetTexture(magic::TU_DIFFUSE));
			if(!tex)
				return "";
			auto it = tex_names.find(tex);
			if(it != tex_names.end())
				return it->second;
			// Named by the session's count, not the dump's, so a texture
			// written for an earlier dump is the same file for this one
			const ss_ stem = "meshdump_tex"+itos(tex_names.size());
			const ss_ png = stem+".png";
			magic::SharedPtr<magic::Image> img = tex->GetImage();
			if(img)
				to_write.push_back(std::make_pair(dir+"/"+png, img));
			// The material maps the pbr shader reads beside the albedo --
			// the atlas's derived normal (spots in alpha) and surface
			// (roughness, spec strength, translucency, spots) -- as
			// <stem>_normal.png and <stem>_spec.png when the material has
			// them. [PT_MATERIALS]
			const struct { magic::TextureUnit unit; const char *suffix; }
					maps[] = {{magic::TU_NORMAL, "_normal"},
					{magic::TU_SPECULAR, "_spec"}};
			for(const auto &m : maps){
				magic::Texture2D *t2 = dynamic_cast<magic::Texture2D*>(
						mat->GetTexture(m.unit));
				magic::SharedPtr<magic::Image> mi = t2 ? t2->GetImage() :
						magic::SharedPtr<magic::Image>();
				if(mi)
					to_write.push_back(std::make_pair(
							dir+"/"+stem+m.suffix+".png", mi));
			}
			tex_names[tex] = png;
			return png;
		};
		auto write_atlas_json = [&](){
			if(atlas_json.empty())
				return;
			ss_ j = atlas_json;
			// Into the top-level object: replace its closing brace
			size_t end = j.rfind('}');
			if(end == ss_::npos)
				return;
			std::ostringstream os;
			os<<", \"textures\": {";
			bool first = true;
			for(const auto &p : tex_names){
				os<<(first ? "\n" : ",\n")<<"\""<<(uintptr_t)p.first<<"\": \""
						<<p.second<<"\"";
				first = false;
			}
			os<<"\n}}\n";
			j = j.substr(0, end) + os.str();
			FILE *af = fopen((dir+"/"+name.substr(0, name.size() - 7)+
					"_atlas.json").c_str(), "w");
			if(af){
				fwrite(j.data(), 1, j.size(), af);
				fclose(af);
			}
		};

		magic::PODVector<magic::CustomGeometry*> geoms;
		root->GetComponents<magic::CustomGeometry>(geoms, true);
		const int64_t t_start = interface::os::time_us();
		int64_t t_tex = 0;
		unsigned vbase = 1;
		unsigned ngeom = 0, nvert = 0, ntri = 0;
		magic::Vector3 eye(0, 0, 0);
		float far_clip = 1e9f; // not "far": a Windows macro
		if(!cams.Empty() && cams[0]->GetNode()){
			eye = cams[0]->GetNode()->GetWorldPosition();
			far_clip = cams[0]->GetFarClip();
		}
		for(unsigned gi = 0; gi < geoms.Size(); gi++){
			magic::CustomGeometry *cg = geoms[gi];
			magic::Node *node = cg->GetNode();
			if(!node)
				continue;
			// The dump is what the picture shows: skip chunks outside the
			// viewing range. +64 is one voxelworld section.
			if((node->GetWorldPosition() - eye).Length() > far_clip + 64.f)
				continue;
			const magic::Matrix3x4 &wt = node->GetWorldTransform();
			magic::Vector<magic::PODVector<magic::CustomGeometryVertex>>
					&batches = cg->GetVertices();
			for(unsigned b = 0; b < batches.Size(); b++){
				const magic::PODVector<magic::CustomGeometryVertex> &vs =
						batches[b];
				if(vs.Size() < 3)
					continue;
				ngeom++;
				magic::Geometry *geom = cg->GetLodGeometry(b, 0);
				magic::VertexBuffer *vb = geom ? geom->GetVertexBuffer(0) : nullptr;
				const bool has_tangent = vb &&
						(vb->GetElementMask() & magic::MASK_TANGENT);
				const int64_t t0 = interface::os::time_us();
				const ss_ mname = material_of(cg->GetMaterial(b));
				t_tex += interface::os::time_us() - t0;
				put(snprintf(line, sizeof line, "o geom_%u_%u\nusemtl %s\n", gi, b,
						mname.c_str()));
				for(unsigned i = 0; i < vs.Size(); i++){
					const magic::Vector3 wp = wt * vs[i].position_;
					// The tint, as the OBJ vertex colour after the position:
					// an albedo multiplier, which is what the shader does
					// with it. It is the 5-6-5 in the tangent's x
					// (pack_tint565 in impl/mesh.cpp) and only when the
					// buffer declares a tangent -- the mesher writes one
					// only for a format with a surface modifier, and for a
					// Luanti world the field is unwritten memory. White
					// otherwise. The vertex colour is the light and stays
					// out: Cycles makes its own; VoxeLibre's palette
					// colours are baked into atlas tiles and never a tint.
					float tr = 1.f, tg = 1.f, tb = 1.f;
					if(has_tangent){
						const unsigned t = (unsigned)(vs[i].tangent_.x_ + 0.5f);
						if(t > 0 && t < 65536){
							tr = (t >> 11) / 31.f;
							tg = ((t >> 5) & 63) / 63.f;
							tb = (t & 31) / 31.f;
						}
					}
					// No vn: the render takes the normal from the winding
					put(snprintf(line, sizeof line, "v %g %g %g %g %g %g\nvt %g %g\n",
							wp.x_, wp.y_, wp.z_, tr, tg, tb,
							vs[i].texCoord_.x_, vs[i].texCoord_.y_));
				}
				for(unsigned i = 0; i + 2 < vs.Size(); i += 3){
					const unsigned a = vbase + i;
					put(snprintf(line, sizeof line, "f %u/%u %u/%u %u/%u\n",
							a, a, a+1, a+1, a+2, a+2));
					ntri++;
				}
				vbase += vs.Size();
				nvert += vs.Size();
			}
		}
		if(!buf.empty())
			gzwrite(f, buf.data(), (unsigned)buf.size());
		gzclose(f);
		write_atlas_json();
		if(!to_write.empty())
			self->queue_textures(to_write);
		log_i(MODULE, "dump_meshes %s: %u geoms, %u verts, %u tris in %.1f s, "
				"%.1f s of it reading textures back; %zu textures being "
				"written behind it",
				cs(name), ngeom, nvert, ntri,
				(interface::os::time_us() - t_start) / 1e6, t_tex / 1e6,
				to_write.size());
		lua_pushlstring(L, name.c_str(), name.size());
		return 1;
	}

	// extension_path(name: string)
	// [EXTENSIONS_SANDBOXED]: the client's own extensions -- the sandbox
	// itself and what needs trust -- are in client/extensions and come
	// first, so that nothing in extensions/ takes one of their names
	static int l_extension_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);
		const ss_ share = g_client_config.get<ss_>("share_path");
		ss_ path = share+"/client/extensions/"+name;
		if(!interface::fs::path_exists(path+"/init.lua"))
			path = share+"/extensions/"+name;
		// One from Aitta; "__" is in no name of the tree's
		const ss_ installed = installed_extension_dir(name);
		if(!installed.empty())
			path = installed;
		// TODO: Check if extension actually exists and do something suitable if
		//       not
		lua_pushlstring(L, path.c_str(), path.size());
		return 1;
	}
