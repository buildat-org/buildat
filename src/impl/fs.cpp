// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include <c55/filesys.h>
#include <c55/string_util.h>
#include <fstream>
#include <cstdio>
#include <atomic>
#include <string>
#include "core/log.h"
#define MODULE "fs"
#ifdef _WIN32
	#include "ports/windows_minimal.h"
#else
	#include <unistd.h>
#endif

namespace interface {
namespace fs {

bool rename(const ss_ &from, const ss_ &to)
{
#ifdef _WIN32
	// std::rename there refuses an existing target
	return MoveFileExA(from.c_str(), to.c_str(), MOVEFILE_REPLACE_EXISTING) != 0;
#else
	return std::rename(from.c_str(), to.c_str()) == 0;
#endif
}

// [FS_TMP_SHARED] The temporary file is this process's and this call's
// own: with one name for all, two clients writing the same file in a
// shared cache (the same hash: the checks' clients, two clients on one
// machine) wrote one inode, and the first's rename put the second's
// truncated write in place, read empty
// (VOXEL_REG_EMPTY_FLAKE). simplified: one left by a crash stays
bool write_file(const ss_ &path, const ss_ &data)
{
	static std::atomic<uint64_t> serial(0);
#ifdef _WIN32
	const uint64_t pid = GetCurrentProcessId();
#else
	const uint64_t pid = getpid();
#endif
	const ss_ tmp = path+"."+std::to_string(pid)+"."+
			std::to_string(serial++)+".tmp";
	{
		std::ofstream f(tmp, std::ios::binary | std::ios::trunc);
		f<<data;
		f.close();
		if(!f.good()){
			std::remove(tmp.c_str());
			return false;
		}
	}
	return rename(tmp, path);
}

// [PROCESS_SANDBOX]: <user>/luanti was a family's directory that every
// app could write. What vanilla shares -- the Luanti games, texture packs,
// textures and settings.json -- is <user>/shared/vanilla, which the other
// apps can only read; the worlds hold their players' password hashes and
// are vanilla's own, <user>/apps/vanilla/worlds. Moved entry by entry, and
// one whose new place is taken stays where it is.
static void migrate_user_luanti(const ss_ &user_path)
{
	const ss_ from = user_path+"/luanti";
	if(!path_exists(from))
		return;
	const ss_ shared = user_path+"/shared/vanilla";
	const ss_ own = user_path+"/apps/vanilla";
	create_directories(shared);
	create_directories(own);
	for(const Node &n : list_directory(from)){
		if(n.name == "." || n.name == "..")
			continue;
		const ss_ to = (n.name == "worlds" ? own : shared)+"/"+n.name;
		if(path_exists(to)){
			log_w(MODULE, "Not moving %s/%s: %s is there already",
					cs(from), cs(n.name), cs(to));
		} else if(rename(from+"/"+n.name, to)){
			log_i(MODULE, "Moved %s/%s to %s", cs(from), cs(n.name), cs(to));
		} else {
			log_w(MODULE, "Could not move %s/%s to %s",
					cs(from), cs(n.name), cs(to));
		}
	}
	// Only if it is empty now: rmdir refuses one that is not
#ifdef _WIN32
	RemoveDirectoryA(from.c_str());
#else
	rmdir(from.c_str());
#endif
}

void migrate_user_apps(const ss_ &user_path)
{
	const ss_ from = user_path+"/games";
	const ss_ to = user_path+"/apps";
	if(path_exists(from) && !path_exists(to)){
		if(rename(from, to))
			log_i(MODULE, "Moved %s to %s: apps were called games", cs(from), cs(to));
		else
			log_w(MODULE, "Could not move %s to %s", cs(from), cs(to));
	}
	migrate_user_luanti(user_path);
}

bool check_file_extension(const char *path, const char *ext)
{
	return c55fs::checkFileExtension(path, ext);
}

ss_ strip_file_extension(const ss_ &path)
{
	return c55fs::stripFileExtension(path);
}

ss_ strip_file_name(const ss_ &path)
{
	return c55fs::stripFilename(path);
}

sv_<Node> list_directory(const ss_ &path)
{
	sv_<Node> result;
	auto list = c55fs::GetDirListing(path);
	for(auto n2 : list){
		Node n;
		n.name = n2.name;
		n.is_directory = n2.dir;
		result.push_back(n);
	}
	return result;
}
bool create_directories(const ss_ &path)
{
	return c55fs::CreateAllDirs(get_absolute_path(path));
}
ss_ get_cwd()
{
	char path[10000];
#ifdef _WIN32
	GetCurrentDirectory(10000, path);
#else
	getcwd(path, 10000);
#endif
	return path;
}
// Doesn't collapse .. and .
ss_ get_basic_absolute_path(const ss_ &path0)
{
	ss_ path = c55::trim(path0);
#ifdef _WIN32
	if(path.size() >= 2 && path.substr(0, 2) == "\\\\")
		return path;
	if(path.size() >= 1 && (path[0] == '/' || path[0] == '\\'))
		return path;
	if(path.size() >= 2 && path[1] == ':')
		return path;
	return get_cwd()+"/"+path;
#else
	if(path.size() >= 1 && path[0] == '/')
		return path;
	return get_cwd()+"/"+path;
#endif
}
// Collapses .. and .
ss_ get_absolute_path(const ss_ &path0)
{
	ss_ path = get_basic_absolute_path(path0);
	for(size_t i = 0; i<path.size(); i++){
		if(path[i] == '\\')
			path[i] = '/';
	}
	sv_<ss_> path_parts;
	c55::Strfnd f(path);
	for(;;){
		if(f.atend())
			break;
		ss_ part = f.next("/");
		if(part == ""){
			// Nop
		} else if(part == "."){
			// Nop
		} else if(part == ".."){
			// A path that climbs past the root stays at the root, which is
			// what every filesystem answers and what keeps this from
			// walking off the front of the list
			if(!path_parts.empty())
				path_parts.pop_back();
		} else {
			path_parts.push_back(part);
		}
	}
	ss_ path2;
	for(const ss_ &part : path_parts){
		path2 += "/" + part;
	}
#ifdef _WIN32
	if(path.size() >= 2 && path.substr(0, 2) == "//"){
		// Preserve network path
		path2 = "\\\\"+path2.substr(1);
	} else {
		// Path will be in a silly format like "/Z:/home/"; the root alone
		// is empty here, and substr(1) of it throws
		if(!path2.empty())
			path2 = path2.substr(1);
	}
#endif
	return path2;
}

bool path_exists(const ss_ &path)
{
	return c55fs::PathExists(path);
}

static bool is_inside_path_unchecked(const ss_ &path0, const ss_ &dir0)
{
	ss_ path = get_absolute_path(path0);
	ss_ dir = get_absolute_path(dir0);
	if(dir.empty())
		return false;
	// A directory of its own counts as inside itself; anything else has to
	// be under it and not merely start with its name, or "/cache_evil"
	// would pass for "/cache"
	if(path == dir)
		return true;
	if(path.size() <= dir.size())
		return false;
	if(path.substr(0, dir.size()) != dir)
		return false;
	return path[dir.size()] == '/' || dir[dir.size() - 1] == '/';
}

// The one runnable check this leaves behind. It decides what sandboxed code
// is allowed to write to, so what it is checked for is the paths that look
// like they are inside and are not.
static bool is_inside_path_self_test()
{
	struct Case { const char *path; const char *dir; bool want; };
	static const Case cases[] = {
		{"/cache/a", "/cache", true},
		{"/cache", "/cache", true},
		{"/cache/", "/cache", true},
		{"/cache/a/b/c.png", "/cache", true},
		{"/cache/a/../b", "/cache", true},
		{"/cache/a", "/cache/", true},
		{"/cache_evil/a", "/cache", false},
		{"/cacheevil", "/cache", false},
		{"/cache/../etc/passwd", "/cache", false},
		{"/cache/a/../../etc", "/cache", false},
		{"/etc/passwd", "/cache", false},
		{"/", "/cache", false},
		{"/cache/a", "", false},
	};
	for(const Case &c : cases){
		bool got = is_inside_path_unchecked(c.path, c.dir);
		if(got != c.want){
			log_w(MODULE, "is_inside_path(\"%s\", \"%s\") is %s and should "
					"be %s", c.path, c.dir, got ? "true" : "false",
					c.want ? "true" : "false");
			return false;
		}
	}
	return true;
}

bool is_inside_path(const ss_ &path0, const ss_ &dir0)
{
	// Cheap, once per process, and every caller passes through here
	static const bool tested = is_inside_path_self_test();
	if(!tested)
		return false; // Nothing is inside anything if the rule is broken
	return is_inside_path_unchecked(path0, dir0);
}

bool copy_file(const ss_ &from, const ss_ &to)
{
	if(from == to)
		return true;
	std::ifstream in(from.c_str(), std::ios::binary);
	if(!in)
		return false;
	std::ofstream out(to.c_str(), std::ios::binary);
	if(!out)
		return false;
	// An empty file is copied as one: << of a buffer with nothing in it
	// sets failbit, and an open plan's empty write-ahead log was a failed
	// copy ([FP_PLANS])
	if(in.peek() == std::ifstream::traits_type::eof())
		return true;
	out << in.rdbuf();
	return (bool)out;
}

bool remove_all(const ss_ &path)
{
	return c55fs::RecursiveDelete(path);
}

uint64_t directory_tree_size(const ss_ &path)
{
	uint64_t total = 0;
	for(const Node &n : list_directory(path)){
		ss_ child = path + "/" + n.name;
		if(n.is_directory)
			total += directory_tree_size(child);
		else
			total += file_size(child);
	}
	return total;
}

bool icon_png_ok(const ss_ &data, unsigned max_side)
{
	// IHDR's width and height, big-endian, at 16 and 20
	if(data.size() < 24 || data.size() > 64 * 1024 ||
			data.compare(0, 8, "\x89PNG\r\n\x1a\n") != 0 ||
			data.compare(12, 4, "IHDR") != 0)
		return false;
	auto be32 = [&](size_t at){
		const unsigned char *d = (const unsigned char*)data.data() + at;
		return (uint32_t)d[0] << 24 | (uint32_t)d[1] << 16 |
				(uint32_t)d[2] << 8 | (uint32_t)d[3];
	};
	const uint32_t w = be32(16), h = be32(20);
	return w >= 1 && h >= 1 && (max_side == 0 || (w <= max_side && h <= max_side));
}

ss_ read_icon_png(const ss_ &path, unsigned max_side)
{
	std::ifstream f(path, std::ios::binary);
	if(!f.good())
		return "";
	ss_ data((std::istreambuf_iterator<char>(f)),
			std::istreambuf_iterator<char>());
	if(!icon_png_ok(data, max_side)){
		log_w("fs", "%s is not a PNG of 64 KB or less%s; not the server's icon",
				cs(path), max_side ? (" and "+itos((int64_t)max_side)+" pixels a side").c_str() : "");
		return "";
	}
	return data;
}

}
}
// vim: set noet ts=4 sw=4:
