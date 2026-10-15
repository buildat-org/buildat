// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// Media the way Luanti finds it: the directories under a mod or a pack,
// the files in them that are media, the first under a name winning, and a
// texture pack picked by name. builtin/luanti serves a game's media with
// these and any module may include them ("luanti/media.h").
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/fs.h"
#include <cassert>

namespace luanti_media
{

// Luanti's fs::GetRecursiveDirs: a directory before its subfolders,
// and a subfolder whose name starts with '_' or '.' left out
inline void recursive_dirs(const ss_ &dir, sv_<ss_> &out, int depth = 0)
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
inline bool is_media_name(const ss_ &name)
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

inline void check_media_names()
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
}

// The first one under a name wins, which is what Luanti does with a
// clash as well; a directory's own files only, its subfolders being
// in the list after it (recursive_dirs)
inline void collect_files(const ss_ &dir, sm_<ss_, ss_> &files)
{
	for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
		if(n.is_directory)
			continue;
		if(!is_media_name(n.name))
			continue;
		auto it = files.find(n.name);
		if(it != files.end()){
			log_v("luanti", "media %s: %s, not %s/%s", cs(n.name),
					cs(it->second), cs(dir), cs(n.name));
			continue;
		}
		files[n.name] = dir+"/"+n.name;
	}
}

// The files under these directories, by name, the first one under a name
// winning: so a texture pack's directories go first
inline sm_<ss_, ss_> collect(const sv_<ss_> &dirs)
{
	sm_<ss_, ss_> files;
	for(const ss_ &dir : dirs)
		collect_files(dir, files);
	return files;
}

// A texture pack's directories, the pack being a directory called `name`
// under `packs`, and nothing for a name that is not a plain directory name
// or a pack that is not installed
inline sv_<ss_> texture_pack_dirs(const ss_ &packs, const ss_ &name)
{
	sv_<ss_> dirs;
	if(name.empty() || packs.empty())
		return dirs;
	const ss_ path = packs+"/"+name;
	// A directory's name, as vanilla writes it: no path in it
	if(name.find_first_not_of("abcdefghijklmnopqrstuvwxyz"
			"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != ss_::npos ||
			!interface::fs::path_exists(path)){
		log_w("luanti", "texture pack %s: not installed", cs(name));
		return dirs;
	}
	recursive_dirs(path, dirs);
	log_i("luanti", "texture pack: %s", cs(name));
	return dirs;
}

}
// vim: set noet ts=4 sw=4:
