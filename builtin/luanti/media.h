// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The game's media and the texture packs, served to the client; included
// by luanti.cpp inside struct Module ([SPLITS]: moved out as it was).

	// The game's own media, named the way Luanti names it: by basename and
	// nothing else, because a tile string says "default_stone.png" and says
	// nothing about where it came from. A clash between two mods is the
	// game's to avoid, which is the deal Luanti gives them too.
	//
	// Luanti draws no line between a texture, a model, a sound and a
	// translation: whatever sits under a mod's media directories and ends in
	// an extension on the whitelist is media and goes to the client. What
	// the client makes of it is the game's business, not the server's.
	// Luanti's own textures -- the heart, the bubble, the blank tile a HUD
	// draws on, the crack over a node being dug. They are the engine's
	// rather than a game's, so Luanti's client has them built in and never
	// sends them; here the client is buildat's and gets everything from the
	// server, so they are served like any other media if the user has put
	// them where this looks.
	//
	// Not vendored: Luanti's textures are CC BY-SA with their authors listed
	// in its LICENSE.txt, and nothing here copies them into the tree. What
	// the user does is put the pack in buildat's own directory, which is the
	// same rule the games follow -- see apps/vanilla.
	// The render mode the app's settings screen wrote (Paths'
	// settings_file, e.g. vanilla's settings.json), "" when there is none.
	// Read here with no JSON parser: the file is the app's own, one line,
	// and the key's value is a bare word.
	ss_ settings_render_mode()
	{
		if(m_paths.settings_file.empty())
			return "";
		std::ifstream f(m_paths.settings_file);
		if(!f.good())
			return "";
		std::stringstream ss;
		ss << f.rdbuf();
		const ss_ text = ss.str();
		const size_t k = text.find("\"render_mode\"");
		if(k == ss_::npos)
			return "";
		const size_t q1 = text.find('"', k + 13);
		const size_t q2 = q1 == ss_::npos ? ss_::npos : text.find('"', q1 + 1);
		if(q2 == ss_::npos)
			return "";
		return text.substr(q1 + 1, q2 - q1 - 1);
	}

	// Luanti's own base textures -- blank.png, heart.png, bubble.png,
	// what a game's HUD asks the engine for: the copy under the module
	// (textures/base, with its licence), or the user's own if the app
	// names one (Paths' base_textures), which wins
	ss_ base_textures_path()
	{
		const ss_ user = m_paths.base_textures;
		if(!user.empty() && interface::fs::path_exists(user))
			return user;
		return module_path()+"/textures/base/pack";
	}

	// The world's texture pack ([WORLD_TXP]): the one world.mt names as
	// buildat_texture_pack, a directory under Paths' texture_packs, where
	// the app installs them (vanilla: user/shared/vanilla/texture_packs). It
	// goes in front of everything else, because first-one-wins is the rule
	// below and a pack's whole point is to override what the game ships --
	// including the LabPBR sidecars the atlas reads ([VOXEL_MATERIALS]
	// layer 2). None named, none served: a pack is the admin's choice for
	// the world, not every installed one at once.
	// simplified: its override.txt is not applied (vanilla's menu says so)
	void collect_texture_packs(sv_<ss_> &dirs)
	{
		const ss_ name = setting_string("buildat_texture_pack");
		if(name.empty() || m_paths.texture_packs.empty())
			return;
		const ss_ path = m_paths.texture_packs+"/"+name;
		// A directory's name, as vanilla writes it: no path in it
		if(name.find_first_not_of("abcdefghijklmnopqrstuvwxyz"
				"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != ss_::npos ||
				!interface::fs::path_exists(path)){
			log_w(MODULE, "texture pack %s: not installed", cs(name));
			return;
		}
		recursive_dirs(path, dirs, 0);
		log_i(MODULE, "texture pack: %s", cs(name));
	}

	void serve_game_media(const ss_ &game_path)
	{
		// Luanti's directories, in Luanti's order (src/server/mods.cpp)
		static const sv_<ss_> wanted = {"textures", "sounds", "media",
				"models", "locale", "fonts"};
		sv_<ss_> dirs;
		// The player's packs first: what they hold wins
		collect_texture_packs(dirs);
		// The game's own textures/, beside its mods' (src/server.cpp)
		recursive_dirs(game_path+"/textures", dirs, 0);
		// [MEDIA_OVERRIDE_ORDER] The mods in reverse load order, as
		// Luanti's getModsMediaPaths: a mod loaded later overrides a
		// dependency's media of the same name
		const sv_<ss_> mods = mod_paths_in_load_order();
		for(auto it = mods.rbegin(); it != mods.rend(); ++it)
			for(const ss_ &w : wanted)
				recursive_dirs(*it+"/"+w, dirs, 0);
		// Last, so that the first-one-wins rule below leaves a game's own
		// version of a name in front of the engine's
		const ss_ base_path = base_textures_path();
		if(interface::fs::path_exists(base_path)){
			recursive_dirs(base_path, dirs, 0);
		} else {
			log_w(MODULE, "No Luanti base textures at %s: a game's HUD asks "
					"for the engine's own textures -- blank.png, heart.png, "
					"bubble.png -- and they are not served. Copy Luanti's "
					"textures/base/pack there to have them.",
					cs(base_path));
		}
		sm_<ss_, ss_> files;
		for(const ss_ &dir : dirs)
			collect_files(dir, files);
		// One announce for the lot: a client already connected (the
		// launcher's own, [FIRST_RUN]) fetches them as one batch
		sv_<std::pair<ss_, ss_>> name_paths;
		name_paths.reserve(files.size());
		for(const auto &pair : files)
			name_paths.push_back(std::make_pair(
					media_resource_name(pair.first), pair.second));
		// Every connected peer has this batch on its way now, and its
		// texture modifiers wait for the batch's files_transmitted
		m_files_transmitted.clear();
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_paths(name_paths);
		});
		for(const auto &pair : files)
			m_served_media[pair.first] = pair.second;
		log_i(MODULE, "%zu media files from %zu directories under %s",
				files.size(), dirs.size(), cs(game_path));
	}

	// The mods' directories in the order lua/modloader.lua loaded them
	sv_<ss_> mod_paths_in_load_order()
	{
		sv_<ss_> paths;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mod_names");
		lua_getfield(L, -2, "__mod_paths");
		if(lua_istable(L, -2) && lua_istable(L, -1)){
			for(int i = 1; ; i++){
				lua_rawgeti(L, -2, i);
				if(!lua_isstring(L, -1))
					break;
				lua_gettable(L, -2);
				if(lua_isstring(L, -1))
					paths.push_back(lua_tostring(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
		return paths;
	}

	// Luanti's fs::GetRecursiveDirs: a directory before its subfolders,
	// and a subfolder whose name starts with '_' or '.' left out
	void recursive_dirs(const ss_ &dir, sv_<ss_> &out, int depth)
	{
		if(depth > 4 || !interface::fs::path_exists(dir))
			return;
		out.push_back(dir);
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(n.is_directory && !n.name.empty() && n.name[0] != '.' &&
					n.name[0] != '_')
				recursive_dirs(dir+"/"+n.name, out, depth + 1);
		}
	}

	// Luanti's media whitelist: a plain name, and an extension the client
	// knows what to do with (Server::addMediaFile in src/server.cpp)
	static bool is_media_name(const ss_ &name)
	{
		if(name.find_first_not_of("abcdefghijklmnopqrstuvwxyz"
				"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != ss_::npos)
			return false;
		static const char *exts[] = {
			"png", "jpg", "tga",
			"ogg",
			"x", "b3d", "obj", "gltf", "glb",
			"tr", "po", "mo", // translations
			"ttf", "woff", // fonts
			nullptr
		};
		for(const char **ext = exts; *ext; ext++)
			if(interface::fs::check_file_extension(cs(name), *ext))
				return true;
		return false;
	}

	static void check_media_names()
	{
		assert(is_media_name("default_stone.png"));
		assert(is_media_name("gltf_frog.gltf"));
		assert(is_media_name("default_cobble.x"));
		assert(is_media_name("soundstuff_mono.ogg"));
		// A mod's code, its documentation and its stray files stay home
		assert(!is_media_name("init.lua"));
		assert(!is_media_name("README.txt"));
		assert(!is_media_name("model.blend"));
		// An extension is not a name, and a name is not a path
		assert(!is_media_name("png"));
		assert(!is_media_name("a name with spaces.png"));
		assert(!is_media_name("../outside.png"));
		log_v(MODULE, "check_media_names: the whitelist holds");
	}

	// The first one under a name wins, which is what Luanti does with a
	// clash as well; a directory's own files only, its subfolders being
	// in the list after it (recursive_dirs)
	void collect_files(const ss_ &dir, sm_<ss_, ss_> &files)
	{
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(n.is_directory)
				continue;
			if(!is_media_name(n.name))
				continue;
			auto it = files.find(n.name);
			if(it != files.end()){
				log_v(MODULE, "media %s: %s, not %s/%s", cs(n.name),
						cs(it->second), cs(dir), cs(n.name));
				continue;
			}
			files[n.name] = dir+"/"+n.name;
		}
	}

	// One flat PNG per node, generated and handed to client_file rather than
	// written to disk: there is no file behind these and there should not be
	// one. What still uses one is a node whose tile the client cannot load
	// as it stands.
	void serve_node_textures(const sv_<ss_> &names)
	{
		sm_<ss_, ss_> files;
		for(const ss_ &name : names){
			ss_ resource = node_texture_name(name);
			if(files.count(resource))
				continue;
			uint8_t rgb[3];
			node_colour(name, rgb);
			const int size = 16;
			ss_ pixels;
			pixels.reserve(size * size * 3);
			for(int i = 0; i < size * size; i++){
				pixels.push_back((char)rgb[0]);
				pixels.push_back((char)rgb[1]);
				pixels.push_back((char)rgb[2]);
			}
			ss_ png;
			if(!stbi_write_png_to_func(png_write_cb, &png, size, size, 3,
					pixels.c_str(), size * 3)){
				log_w(MODULE, "Could not encode a texture for %s", cs(name));
				continue;
			}
			files[resource] = png;
		}
		client_file::access(m_server, [&](client_file::Interface *ifile){
			for(const auto &pair : files)
				ifile->add_file_content(pair.first, pair.second);
		});
		log_v(MODULE, "%zu node textures served", files.size());
	}
