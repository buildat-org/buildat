// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The game's media as the clients get it ([LUANTI_MODULAR]: a part of the
// Module): the game's and its mods' files, the texture packs and Luanti's
// base textures, the generated node textures, the texture modifiers and
// the startup tables served as files, and the sound groups. It owns what
// it served and who has it, with references to the server, the game's Lua
// state, the app's paths and the mapgen's settings (the texture pack).
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/mutex.h"
#include "interface/server.h"
#include "interface/fs.h"
#include "network/api.h"
#include "client_file/api.h"
#include "luanti/api.h"
#include "luanti/media.h"
#include "luanti/lua_util.h"
#include "luanti/registry.h"
#include "luanti/mapgen_params.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
// stbi_write_png_to_func(): luanti.cpp includes STB/stb_image_write.h
// with its implementation, which a second inclusion would define again
#include <fstream>
#include <sstream>
#include <set>
extern "C" {
#include <lua.h>
}

namespace luanti {

// (width, height, components, pixel bytes) -> a PNG. The caller decided how
// many components the image wants; see core.encode_png in lua/png.lua.
static inline void png_write_cb(void *context, void *data, int size)
{
	ss_ *out = (ss_*)context;
	out->append((const char*)data, size);
}

struct Media
{
	interface::Server *&m_server;
	lua_State *&m_lua;
	interface::Mutex &m_lua_mutex;
	const Interface::Paths &m_paths;
	MapgenParams &m_mapgen;

	Media(interface::Server *&server, lua_State *&lua,
			interface::Mutex &lua_mutex, const Interface::Paths &paths,
			MapgenParams &mapgen):
		m_server(server), m_lua(lua), m_lua_mutex(lua_mutex), m_paths(paths),
		m_mapgen(mapgen)
	{}

	// The media the game shipped, name -> path: a tile naming one can be
	// handed to the client as it is, and a palette has to be read here
	sm_<ss_, ss_> m_served_media;
	// The texture modifier expressions the game's nodes are drawn with, by
	// the resource name each is composed under. The client is what composes
	// them; this is what it is sent when it asks.
	sm_<ss_, ss_> m_texmods;
	// Peers that asked for the texture modifiers while the game's media
	// was still on its way to them: the launcher's own client is
	// connected before the game is chosen, so the media is announced
	// after the join and composing over it fails until it has arrived
	// ([FIRST_RUN]). Answered on client_file:files_transmitted.
	std::set<network::PeerInfo::Id> m_texmods_waiting;
	std::set<network::PeerInfo::Id> m_files_transmitted;

	// The client half asks for these once it has loaded, rather than being
	// sent them when it connects: a packet that arrives before the script
	// that subscribes to it has nowhere to go.
	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		m_files_transmitted.insert(event.recipient);
		if(m_texmods_waiting.erase(event.recipient))
			send_texmods(event.recipient);
	}

	void on_get_texmods(const network::Packet &packet)
	{
		// A batch of media announced since this peer's last
		// files_transmitted is still on its way: the answer waits for it
		if(!m_files_transmitted.count(packet.sender)){
			m_texmods_waiting.insert(packet.sender);
			return;
		}
		send_texmods(packet.sender);
	}

	// The same flat array the packet carries: a resource name and the
	// expression it is for, in pairs
	ss_ texmods_blob()
	{
		sv_<ss_> flat;
		flat.reserve(m_texmods.size() * 2);
		for(const auto &pair : m_texmods){
			flat.push_back(pair.first);
			flat.push_back(pair.second);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		return os.str();
	}

	// And as a file, served by client_file ([BLOCKED_MODULE]): this module
	// answers nothing while a slow mapgen holds it -- realtest's sections
	// were 29.6 s each and the client drew 840 missing textures -- and
	// client_file is a module of its own with a queue of its own, so a file
	// reaches the client whatever this one is doing. The client reads it
	// before it asks, and the packet stays for what is added later.
	void serve_texmods_file()
	{
		if(m_texmods.empty())
			return;
		const ss_ blob = texmods_blob();
		client_file::access(m_server, [&](client_file::Interface *ifile){
			ifile->add_file_content("luanti_data/texmods.bin", blob);
		});
		log_v(MODULE, "%zu texture modifiers served as a file",
				m_texmods.size());
	}

	// The same for the tables the client's other startup requests read:
	// each is built at mod load and the request only reads it, so none of
	// them has any business waiting behind a mapgen ([BLOCKED_MODULE]).
	// The requests stay -- a game may add to a table while it runs.
	void serve_lua_table_file(const char *lua_fn, const ss_ &file_name,
			const char *what)
	{
		sv_<ss_> flat = string_list_from_lua(m_lua, m_lua_mutex, lua_fn);
		if(flat.empty())
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		const ss_ blob = os.str();
		client_file::access(m_server, [&](client_file::Interface *ifile){
			ifile->add_file_content(file_name, blob);
		});
		log_v(MODULE, "%zu %s served as a file", flat.size(), what);
	}

	void serve_startup_tables()
	{
		serve_texmods_file();
		serve_lua_table_file("__object_appearances",
				"luanti_data/object_props.bin", "object look fields");
		serve_lua_table_file("__dig_props", "luanti_data/dig_props.bin",
				"dig prop records");
		serve_lua_table_file("__translations",
				"luanti_data/translations.bin", "translated strings");
		serve_lua_table_file("__item_images", "luanti_data/item_images.bin",
				"item image fields");
		serve_lua_table_file("__item_palettes",
				"luanti_data/item_palettes.bin", "item palettes");
		serve_lua_table_file("__wield_meshes",
				"luanti_data/wield_meshes.bin", "wield meshes");
	}

	void send_texmods(network::PeerInfo::Id peer)
	{
		std::ostringstream os(std::ios::binary);
		os << texmods_blob();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "luanti:texmods", os.str());
		});
		log_v(MODULE, "C%zu: %zu texture modifiers", (size_t)peer,
				m_texmods.size());
	}

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
		return m_server->get_module_path(MODULE)+"/textures/base/pack";
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
		for(const ss_ &d : luanti_media::texture_pack_dirs(m_paths.texture_packs,
				m_mapgen.setting_string("buildat_texture_pack")))
			dirs.push_back(d);
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
		luanti_media::recursive_dirs(game_path+"/textures", dirs);
		// [MEDIA_OVERRIDE_ORDER] The mods in reverse load order, as
		// Luanti's getModsMediaPaths: a mod loaded later overrides a
		// dependency's media of the same name
		const sv_<ss_> mods = mod_paths_in_load_order();
		for(auto it = mods.rbegin(); it != mods.rend(); ++it)
			for(const ss_ &w : wanted)
				luanti_media::recursive_dirs(*it+"/"+w, dirs);
		// Last, so that the first-one-wins rule below leaves a game's own
		// version of a name in front of the engine's
		const ss_ base_path = base_textures_path();
		if(interface::fs::path_exists(base_path)){
			luanti_media::recursive_dirs(base_path, dirs);
		} else {
			log_w(MODULE, "No Luanti base textures at %s: a game's HUD asks "
					"for the engine's own textures -- blank.png, heart.png, "
					"bubble.png -- and they are not served. Copy Luanti's "
					"textures/base/pack there to have them.",
					cs(base_path));
		}
		const sm_<ss_, ss_> files = luanti_media::collect(dirs);
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

	// [SKELENTI_SOUNDS] See set_generated_sounds() in api.h
	ss_ m_generated_sound_prefix;
	int m_generated_sound_count = 0;
	void set_generated_sounds(const ss_ &prefix, int count)
	{
		m_generated_sound_prefix = prefix;
		m_generated_sound_count = std::max(0, std::min(count, 9));
	}
	// A sound group's files: Luanti's own suffixes, the plain name and
	// one digit, which is what its media lookup accepts. The names are
	// asked for rather than scanned for, because what the module serves
	// is a hash map. A generated group has .1 .. .<count>, made by the
	// app's client.
	sv_<ss_> sound_files(const ss_ &group)
	{
		sv_<ss_> files;
		if(group.empty())
			return files;
		if(!m_generated_sound_prefix.empty() &&
				group.compare(0, m_generated_sound_prefix.size(),
					m_generated_sound_prefix) == 0){
			for(int d = 1; d <= m_generated_sound_count; d++)
				files.push_back(group+"."+itos(d)+".ogg");
			return files;
		}
		if(m_served_media.count(group+".ogg"))
			files.push_back(group+".ogg");
		for(char d = '0'; d <= '9'; d++){
			const ss_ name = group+"."+d+".ogg";
			if(m_served_media.count(name))
				files.push_back(name);
		}
		return files;
	}
};

}
// vim: set noet ts=4 sw=4:
