// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "boot/autodetect.h"
#include "core/log.h"
#include <cstdio>
#include <algorithm>
#include "interface/os.h"
#include "interface/fs.h"
#include "interface/process.h"
#include "interface/mutex.h"
#include "interface/debug.h"
#include <fstream>
#include <cstdlib> // getenv(), setenv()
#define MODULE "boot"

namespace boot {
namespace autodetect {

// Filesystem helpers

static bool check_file_readable(const ss_ &path)
{
	std::ifstream ifs(path);
	bool readable = ifs.good();
	if(!readable)
		log_d(MODULE, "File is not readable: [%s]", cs(path));
	else
		log_d(MODULE, "File is readable: [%s]", cs(path));
	return readable;
}

static bool check_file_writable(const ss_ &path)
{
	std::ofstream ofs(path);
	bool writable = ofs.good();
	if(!writable)
		log_d(MODULE, "File is not writable: [%s]", cs(path));
	else
		log_d(MODULE, "File is writable: [%s]", cs(path));
	return writable;
}

static set_<ss_> m_valid_commands;
static interface::Mutex m_valid_commands_mutex;

static bool check_runnable(const ss_ &command)
{
	interface::MutexScope ms(m_valid_commands_mutex);
	if(m_valid_commands.count(command))
		return true;

	// Probing a path that does not exist is the normal case -- the compiler
	// is looked for in a couple of places before PATH -- so neither the
	// shell's complaint about it nor the version banner of the one that
	// works is news. Only the shell_exec() on Linux runs the command through
	// a shell; the Windows one hands it to CreateProcess, where a redirection
	// would be an argument to the program instead.
#ifndef _WIN32
	ss_ run = command + " >/dev/null 2>&1";
#else
	ss_ run = command;
#endif
	int exit_status = interface::process::shell_exec(run);
	if(exit_status != 0){
		log_d(MODULE, "Command failed: [%s]", cs(command));
		return false;
	} else {
		log_d(MODULE, "Command succeeded: [%s]", cs(command));
		m_valid_commands.insert(command);
		return true;
	}
}

// Where the user's own things and the cache go when they are not beside the
// program. Always compiled, so that the self-check below runs in either build.
//
// The rule that sorts a path into one or the other: the cache is what the
// program can recreate by itself; the user path is what the user made, chose
// or fetched deliberately.

static ss_ env_or(const char *name, const ss_ &fallback)
{
	const char *v = getenv(name);
	if(v && v[0])
		return v;
	return fallback;
}

static ss_ home_path()
{
#ifdef _WIN32
	return env_or("USERPROFILE", ".");
#else
	return env_or("HOME", ".");
#endif
}

ss_ platform_user_path()
{
#if defined(_WIN32)
	return env_or("APPDATA", home_path()+"/AppData/Roaming")+"/buildat";
#elif defined(__APPLE__)
	return home_path()+"/Library/Application Support/buildat";
#else
	return env_or("XDG_DATA_HOME", home_path()+"/.local/share")+"/buildat";
#endif
}

ss_ platform_cache_path()
{
#if defined(_WIN32)
	return env_or("LOCALAPPDATA", home_path()+"/AppData/Local")+"/buildat/cache";
#elif defined(__APPLE__)
	return home_path()+"/Library/Caches/buildat";
#else
	return env_or("XDG_CACHE_HOME", home_path()+"/.cache")+"/buildat";
#endif
}

// A portable build keeps both beside the program, which is what the
// root-relative defaults in the PathDefinition tables do. A system build puts
// them where the platform says, and then they take no part in root detection:
// whether there is a writable cache beside share/ says nothing about where
// buildat's data belongs. A value that is already there came from -C or -D and
// wins over both.
// Whether the data goes where the platform says: a system build, or an
// installed copy of a portable one ([WIN_INSTALLER]: the installer puts
// bin/installed beside the exe, as its directory is replaced by an upgrade
// and emptied by the uninstall)
static bool platform_data_paths()
{
#ifdef BUILDAT_PORTABLE
	return interface::fs::path_exists(interface::fs::strip_file_name(
			interface::os::get_current_exe_path())+"/installed");
#else
	return true;
#endif
}

static void set_platform_data_paths(core::Config &config)
{
	// A check's own paths (util/check_lib.sh), so that a run never shares
	// the desk's; under -C and -D, over the rest
	// (set only when there: an empty one set reads as given)
	const ss_ env_cache = env_or("BUILDAT_CACHE_PATH", "");
	const ss_ env_user = env_or("BUILDAT_USER_PATH", "");
	if(!env_cache.empty() && config.get<ss_>("cache_path").empty())
		config.set("cache_path", env_cache);
	if(!env_user.empty() && config.get<ss_>("user_path").empty())
		config.set("user_path", env_user);
	if(platform_data_paths()){
		if(config.get<ss_>("cache_path").empty())
			config.set("cache_path", platform_cache_path());
		if(config.get<ss_>("user_path").empty())
			config.set("user_path", platform_user_path());
	}
	// "a/../b" collapsed: Urho3D's resource cache drops "../" out of a
	// name, so a cached file under a path given with one is never found and
	// the world draws black. simplified: only such a path is rewritten, so
	// a Windows path keeps its backslashes.
	// And a relative one ([CLIENT_RELATIVE_CACHE]): Urho3D's resource
	// paths and the client's own reads went from different directories,
	// and a relative -C found no served resource (the sky's cube nil).
	// simplified: not on Windows, where get_absolute_path() has no drive
	for(const char *k : {"cache_path", "user_path"}){
		const ss_ p = config.get<ss_>(k);
#ifndef _WIN32
		const bool relative = !p.empty() && p[0] != '/';
#else
		const bool relative = false;
#endif
		if(p.find("..") != ss_::npos || relative)
			config.set(k, interface::fs::get_absolute_path(p));
	}
}

#ifndef _WIN32
// Sets an environment variable and puts back what was there when it goes out
// of scope, so that the check below can look at both cases
struct ScopedEnv {
	ss_ name;
	bool had_old = false;
	ss_ old;
	ScopedEnv(const char *name_, const char *value): name(name_){
		const char *v = getenv(name_);
		if(v){
			had_old = true;
			old = v;
		}
		if(value)
			setenv(name_, value, 1);
		else
			unsetenv(name_);
	}
	~ScopedEnv(){
		if(had_old)
			setenv(cs(name), cs(old), 1);
		else
			unsetenv(cs(name));
	}
};
#endif

static void check_platform_data_paths()
{
#if !defined(_WIN32) && !defined(__APPLE__)
	{
		ScopedEnv h("HOME", "/home/u");
		ScopedEnv d("XDG_DATA_HOME", "/xdg/data");
		ScopedEnv c("XDG_CACHE_HOME", "/xdg/cache");
		if(platform_user_path() != "/xdg/data/buildat")
			throw Exception("platform_user_path: XDG_DATA_HOME");
		if(platform_cache_path() != "/xdg/cache/buildat")
			throw Exception("platform_cache_path: XDG_CACHE_HOME");
	}
	{
		ScopedEnv h("HOME", "/home/u");
		ScopedEnv d("XDG_DATA_HOME", nullptr);
		ScopedEnv c("XDG_CACHE_HOME", nullptr);
		if(platform_user_path() != "/home/u/.local/share/buildat")
			throw Exception("platform_user_path: fallback");
		if(platform_cache_path() != "/home/u/.cache/buildat")
			throw Exception("platform_cache_path: fallback");
	}
	{
		// An empty variable is not a path, whatever the shell thinks
		ScopedEnv h("HOME", "/home/u");
		ScopedEnv d("XDG_DATA_HOME", "");
		if(platform_user_path() != "/home/u/.local/share/buildat")
			throw Exception("platform_user_path: empty XDG_DATA_HOME");
	}
#endif
	// -C and -D win over whichever of the two builds this is
	core::Config config;
	config.set_default("cache_path", "");
	config.set_default("user_path", "");
	config.set("cache_path", "/given/cache");
	config.set("user_path", "/given/user");
	set_platform_data_paths(config);
	if(config.get<ss_>("cache_path") != "/given/cache" ||
			config.get<ss_>("user_path") != "/given/user")
		throw Exception("set_platform_data_paths: overrode -C/-D");
	// A Windows path has a drive: get_absolute_path() gives "/given" there
	// as "given"
#ifdef _WIN32
	const ss_ root = "C:";
#else
	const ss_ root = "";
#endif
	config.set("cache_path", root+"/given/Build/../cache");
	set_platform_data_paths(config);
	if(config.get<ss_>("cache_path") != root+"/given/cache")
		throw Exception("set_platform_data_paths: kept a \"..\": "+
				config.get<ss_>("cache_path"));
}

enum PathDefinitionType {PD_END, PD_READ, PD_WRITE, PD_RUN};
struct PathDefinition {
	PathDefinitionType type; // Type of check
	const char *path_name; // Name in configuration
	const char *default_subpath; // Default value is root + default_subpath
	const char *check_path; // Path to check under $path_name
	const char *description; // Description of this definition
};

static bool check_path(const core::Config &config, const PathDefinition &def,
		bool log_issues, bool enable_mkdir)
{
	ss_ base_path = config.get<ss_>(def.path_name);
	if(def.type == PD_READ){
		bool ok = check_file_readable(base_path + def.check_path);
		if(!ok && log_issues){
			log_e(MODULE, "%s not found in %s=[%s]",
					def.description, def.path_name, cs(base_path));
			log_e(MODULE, "* File is not readable: [%s]",
					cs(base_path + def.check_path));
		}
		return ok;
	} else if(def.type == PD_WRITE){
		// Create path
		if(enable_mkdir)
			interface::fs::create_directories(base_path);
		// Check path
		bool ok = check_file_writable(base_path + def.check_path);
		if(!ok && log_issues){
			log_e(MODULE, "%s not writable in %s=[%s]",
					def.description, def.path_name, cs(base_path));
			log_e(MODULE, "* File is not writable: [%s]",
					cs(base_path + def.check_path));
		}
		return ok;
	} else if(def.type == PD_RUN){
		bool ok = check_runnable(base_path + def.check_path);
		if(!ok && log_issues){
			log_e(MODULE, "%s not runnable in %s=[%s]",
					def.description, def.path_name, cs(base_path));
			log_e(MODULE, "* Command failed: [%s]",
					cs(base_path + def.check_path));
		}
		return ok;
	} else {
		throw Exception("Unknown PathDefinition::type "+itos(def.type));
	}
}

static bool check_paths(const core::Config &config, const PathDefinition *defs,
		bool log_issues)
{
	bool ok = true;
	const PathDefinition *def = defs;
	while(def->type != PD_END){
		// Don't create directories if something already failed
		bool enable_mkdir = ok;
		if(!check_path(config, *def, log_issues, enable_mkdir))
			ok = false;
		def++;
	}
	return ok;
}

static void set_default_subpaths(core::Config &config, const PathDefinition *defs,
		const ss_ &root)
{
	const PathDefinition *def = defs;
	while(def->type != PD_END){
		if(def->default_subpath[0] == '|') // Disables root
			config.set_default(def->path_name, &def->default_subpath[1]);
		else
			config.set_default(def->path_name, root + def->default_subpath);
		def++;
	}
}

// If not found, returns false and logs issues
static bool find_root(const sv_<ss_> &roots, const PathDefinition *defs,
		const char *description, const core::Config &base_config,
		ss_ &result)
{
	log_d(MODULE, "Searching root: %s", description);
	// Try to find root
	for(const ss_ &root : roots)
	{
		log_d(MODULE, "Checking root [%s]", cs(root));
		core::Config config;
		set_default_subpaths(config, defs, root);
		config.values = base_config.values;
		if(check_paths(config, defs, false)){
			log_d(MODULE, "-> Root [%s] matches (%s)", cs(root), description);
			result = root;
			return true;
		}
	}
	// Not found; Log issues and return
	log_e(MODULE, "Could not find root: %s", description);
	for(const ss_ &root : roots)
	{
		log_e(MODULE, "Checked [%s]:", cs(root));
		core::Config config;
		set_default_subpaths(config, defs, root);
		config.values = base_config.values;
		check_paths(config, defs, true);
	}
	return false;
}

static bool detect_paths(core::Config &config, const sv_<ss_> &roots,
		const PathDefinition *defs, const char *description)
{
	ss_ root;
	if(!find_root(roots, defs, description, config, root)){
		log_w(MODULE, "Could not determine %s path (tried %s)",
				description, cs(roots));
		return false;
	}

	log_v(MODULE, "%s detected: [%s]", description, cs(root));
	set_default_subpaths(config, defs, root);
	// The root itself, kept: what a child process is started in, and what
	// the log's first lines name ([WIN8_START])
	if(ss_(description).find("root") != ss_::npos &&
			config.get<ss_>("root_path").empty())
		config.set("root_path", root);
	return true;
}

// Common functions

static void generate_buildat_root_alternatives(sv_<ss_> &roots)
{
	// Use executable path to find root suggestions
	ss_ exe_path = interface::os::get_current_exe_path();
	ss_ exe_dir = interface::fs::strip_file_name(exe_path);
	ss_ root_path = exe_dir + "/..";
	root_path = interface::fs::get_absolute_path(root_path);
	roots.push_back(root_path);
	root_path = interface::fs::get_absolute_path(root_path+"/..");
	roots.push_back(root_path);

	//roots.push_back(".");
	//roots.push_back("..");
}

static void generate_urho3d_root_alternatives(sv_<ss_> &roots)
{
	sv_<ss_> buildat_roots;
	generate_buildat_root_alternatives(buildat_roots);

	for(const ss_ &buildat_root : buildat_roots){
		roots.push_back(buildat_root + "/3rdparty/Urho3D");
		roots.push_back(buildat_root + "/Urho3D");
		roots.push_back(buildat_root + "/../Urho3D");
	}
}

static void generate_compiler_binary_dir_alternatives(sv_<ss_> &roots)
{
	sv_<ss_> buildat_roots;
	generate_buildat_root_alternatives(buildat_roots);

	for(const ss_ &buildat_root : buildat_roots){
		// NOTE: These contain a trailing slash so that the command can be
		//       appended without a leading slash
		roots.push_back(buildat_root + "/compiler/bin/");
	}

	roots.push_back(""); // In case command is found in PATH (least priority)
}

// Server-only paths

PathDefinition server_paths[] = {
	{PD_READ, "share_path",
		"",
		"/builtin/network/network.cpp",
		"Static files"},
	{PD_READ, "interface_path",
		"/src/interface",
		"/event.h",
		"Interface files"},
	{PD_WRITE, "cache_path",
		"/cache",
		"/write.test",
		"Cache directory"},
	{PD_WRITE, "rccpp_build_path",
		"/cache/rccpp_build",
		"/write.test",
		"RCC++ build directory"},
	// Saves go here; see doc/plan/world_persistence_plan.md
	{PD_WRITE, "user_path",
		"/user",
		"/write.test",
		"User directory"},
	{PD_END, "", "", "", ""},
};

static bool detect_buildat_server_paths(core::Config &config)
{
	set_platform_data_paths(config);
	// The one thing the server keeps in the cache
	if(platform_data_paths() && config.get<ss_>("rccpp_build_path").empty())
		config.set("rccpp_build_path",
				config.get<ss_>("cache_path")+"/rccpp_build");
	sv_<ss_> roots;
	generate_buildat_root_alternatives(roots);
	return detect_paths(config, roots, server_paths, "Buildat server root");
}

// Compiler paths

// NOTE: For these, the root contains a trailing slash, and can be an empty string.
PathDefinition compiler_bin_paths[] = {
	{PD_RUN, "compiler_command",
		"c++",
		" --version",
		"Compiler command"},
	{PD_END, "", "", "", ""},
};

static bool detect_compiler_bin_paths(core::Config &config)
{
	sv_<ss_> roots;
	generate_compiler_binary_dir_alternatives(roots);
	if(!detect_paths(config, roots, compiler_bin_paths,
			"Compiler binary directory")){
		// The one line a player of an archive needs: the server compiles a
		// game's modules as it loads them, and on Linux the compiler is the
		// system's ([PACKAGING]); the Windows archive carries its own under
		// compiler/, so there this is a broken archive
#ifdef _WIN32
		// The "Luanti only" archive ships no compiler on purpose
		// ([LUANTI_BUILD]): its modules are prebuilt into its cache, and
		// the server starts; a compile it then needs fails with the line
		// rccpp prints. The full archive with compiler/ missing reads the
		// same, and that line says what to do.
		log_w(MODULE, "No C++ compiler found: this archive ships none (or "
				"its compiler/ directory is missing); a game whose modules "
				"are not prebuilt cannot be started with it");
		config.set("compiler_command", "");
		return true;
#else
		// Nor the Linux server archive ([LINUX_SERVER]), which carries every
		// shipped game's modules prebuilt: it starts on a box with no
		// compiler, and only a module that is not in its cache fails, with
		// the line rccpp prints
		log_w(MODULE, "No C++ compiler (c++) found in PATH. buildat compiles "
				"a game's modules as it loads them, and without one only a "
				"game whose modules are prebuilt in the cache starts. To "
				"install one:\n"
				"  Debian, Ubuntu:  sudo apt install build-essential\n"
				"  Fedora:          sudo dnf install gcc-c++\n"
				"  Arch:            sudo pacman -S gcc");
		config.set("compiler_command", "");
		return true;
#endif
	}
	// Said out loud because the probe is silent now, and which compiler is
	// going to build the runtime-compiled modules is worth knowing
	log_i(MODULE, "Compiler command: [%s]",
			cs(config.get<ss_>("compiler_command")));
	return true;
}

// Client-only paths

PathDefinition client_paths[] = {
	{PD_READ, "share_path",
		"",
		"/client/init.lua",
		"Static files"},
	{PD_WRITE, "cache_path",
		"/cache",
		"/write.test",
		"Cache directory"},
	// What the user made, chose or downloaded deliberately, as against what
	// the program can recreate by itself. See doc/plan/world_persistence_plan.md;
	// the platform paths and -DPORTABLE come with the saves.
	{PD_WRITE, "user_path",
		"/user",
		"/write.test",
		"User directory"},
	{PD_END, "", "", "", ""},
};

static bool detect_buildat_client_paths(core::Config &config)
{
	set_platform_data_paths(config);
	sv_<ss_> roots;
	generate_buildat_root_alternatives(roots);
	return detect_paths(config, roots, client_paths, "Buildat client root");
}

// Server Urho3D paths

PathDefinition server_urho3d_paths[] = {
	{PD_READ, "urho3d_path",
		"",
		"/bin/CoreData/Shaders/GLSL/Basic.glsl",
		"Urho3D path"},
	{PD_END, "", "", "", ""},
};

static bool detect_server_urho3d_paths(core::Config &config)
{
	sv_<ss_> roots;
	generate_urho3d_root_alternatives(roots);
	return detect_paths(config, roots, server_urho3d_paths, "Server Urho3D root");
}

// Client Urho3D paths

PathDefinition client_urho3d_paths[] = {
	{PD_READ, "urho3d_path",
		"",
		"/bin/CoreData/Shaders/GLSL/Basic.glsl",
		"Urho3D path"},
	{PD_END, "", "", "", ""},
};

static bool detect_client_urho3d_paths(core::Config &config)
{
	sv_<ss_> roots;
	generate_urho3d_root_alternatives(roots);
	return detect_paths(config, roots, client_urho3d_paths, "Client Urho3D root");
}

// Public interface

bool check_server_paths(const core::Config &config, bool log_issues)
{
	bool ok = true;
	if(!check_paths(config, server_paths, log_issues))
		ok = false;
	// An empty compiler_command is the archive without a compiler
	// ([LUANTI_BUILD]), which detect_compiler_bin_paths() let through;
	// checked again here it would stop the server after all
	if(config.get<ss_>("compiler_command") != "" &&
			!check_paths(config, compiler_bin_paths, log_issues))
		ok = false;
	if(!check_paths(config, server_urho3d_paths, log_issues))
		ok = false;
	return ok;
}

bool check_client_paths(const core::Config &config, bool log_issues)
{
	bool ok = true;
	if(!check_paths(config, client_paths, log_issues))
		ok = false;
	if(!check_paths(config, client_urho3d_paths, log_issues))
		ok = false;
	return ok;
}

ss_ open_log(core::Config &config, const ss_ &name, const ss_ &exe)
{
	ss_ path = config.get<ss_>("log_file");
	const ss_ cwd = interface::fs::get_cwd();
	const bool given = !path.empty();
	if(!given){
		const ss_ cache = config.get<ss_>("cache_path");
		if(!cache.empty()){
			interface::fs::create_directories(cache);
			path = cache+"/"+name+".log";
		}
	} else {
		// The one cwd-relative thing, made absolute here so that a child
		// given the same directory finds it
		path = interface::fs::get_absolute_path(path);
	}
	if(!path.empty()){
		// The run before, kept as <stem>_1<ext>: a report is the current
		// logs and the ones before, and nothing balloons. For the given
		// path too, so a client's -L and the server's beside it rotate
		// the same way.
		const size_t slash = path.find_last_of("/\\");
		const size_t dot = path.find_last_of('.');
		const bool has_ext = dot != ss_::npos &&
				(slash == ss_::npos || dot > slash);
		const ss_ old = (has_ext ? path.substr(0, dot) : path)+"_1"+
				(has_ext ? path.substr(dot) : ss_());
		std::remove(old.c_str());
		std::rename(path.c_str(), old.c_str());
		// The default tees: the terminal and a harness reading the stream
		// keep what they had; a given -L is the file alone, with stderr
		// into it for a crash's backtrace
		log_set_file(path.c_str(), !given);
		// At info unless -l asked for more (the terminal's default is
		// verbose, which balloons a file over a session)
		if(!given && !config.get<bool>("log_level_given"))
			log_set_max_level(CORE_INFO);
	}
	// Kept as given (empty for the default): a client passes its server
	// a log beside its own -L and nothing beside the default, which the
	// server then defaults on its own
	config.set("log_file", given ? path : ss_());
	config.set("log_path", path);
	// A crash's minidump into the cache ([WIN_MINIDUMP])
	interface::debug::set_crash_dump_dir(config.get<ss_>("cache_path"), name);
	log_i(MODULE, "%s: exe %s, root %s, cwd %s, log %s", cs(name), cs(exe),
			cs(config.get<ss_>("root_path")), cs(cwd),
			path.empty() ? "none" : cs(path));
	return path;
}

bool detect_server_paths(core::Config &config)
{
	bool ok = true;

	check_platform_data_paths();

	if(!detect_buildat_server_paths(config))
		ok = false;
	if(!detect_compiler_bin_paths(config))
		ok = false;
	if(!detect_server_urho3d_paths(config))
		ok = false;

	return ok;
}

bool detect_client_paths(core::Config &config)
{
	bool ok = true;

	check_platform_data_paths();

	if(!detect_buildat_client_paths(config))
		ok = false;
	if(!detect_client_urho3d_paths(config))
		ok = false;

	return ok;
}

}
}
// vim: set noet ts=4 sw=4:
