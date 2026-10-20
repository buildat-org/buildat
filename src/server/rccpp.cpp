// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "rccpp.h"
#include <fstream>
#include "core/log.h"
#include "interface/server.h"
#include "interface/process.h"
#include "interface/fs.h"
#include <c55/filesys.h>
#include <vector>
#include <string>
#include <iostream>
#ifdef _WIN32
	#ifndef WIN32_LEAN_AND_MEAN
		#define WIN32_LEAN_AND_MEAN
	#endif
// Without this some of the network functions are not found on mingw
	#ifndef _WIN32_WINNT
		#define _WIN32_WINNT 0x0501
	#endif
	#include <windows.h>
#else
	#include <dlfcn.h>
#endif
#include <cstddef>
#include <vector>
#include <cassert>
#include <memory>
#include <string>
#include <unordered_map>
#include <algorithm>
#define MODULE "__rccpp"

namespace rccpp {

#ifdef _WIN32
static void* library_load(const char *filename){
	return LoadLibrary(filename);
}
static void library_unload(void *module){
	FreeLibrary((HMODULE)module);
}
static void* library_get_address(void *module, const char *name){
	// FARPROC {aka int (__attribute__((__stdcall__)) *)()}
	return (void*)GetProcAddress((HMODULE)module, name);
}
static const char* library_error(){
	DWORD last_error = GetLastError();
	if(!last_error)
		return "No error";
	static TCHAR buf[1000];
	FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM, NULL, last_error,
			MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), buf, 1000-1, NULL);
	return buf;
}
#else
static void* library_load(const char *filename){
	return dlopen(filename, RTLD_NOW);
}
static void library_unload(void *module){
	dlclose(module);
}
static void* library_get_address(void *module, const char *name){
	return dlsym(module, name);
}
static const char* library_error(){
	return dlerror();
}
#endif

typedef void*(*RCCPP_Constructor)(interface::Server * server);

struct RCCPP_Info {
	void *module;
	RCCPP_Constructor constructor;
};

// Without an -O flag gcc defaults to -O0, which in a voxel module is the
// difference between an array access and a function call per voxel: lighting a
// section measured 178 ms at -O0 and 40 ms here. -O2 gets that to 37 ms but
// costs a third more compile time on every module reload, which is the thing
// this engine does constantly.
ss_ cxxflags_optimize()
{
#ifdef BUILDAT_SANITIZE
	// A sanitizer build's modules are instrumented too: they are where a
	// client's packet is handled, and a fuzz run against an uninstrumented
	// module sees a crash and nothing short of one. In the module hash as
	// well, so neither build is handed the other's.
	return "-O1 -fsanitize=" BUILDAT_SANITIZE " -fno-omit-frame-pointer";
#else
	return "-O1";
#endif
}

struct CCompiler: public Compiler
{
	ss_ m_compiler_command;
	std::unordered_map<std::string, RCCPP_Info> m_module_info;

	CCompiler(const ss_ &compiler_command):
		m_compiler_command(compiler_command)
	{
	}

	bool compile(const std::string &in_path, const std::string &out_path,
			const ss_ &extra_cxxflags, const ss_ &extra_ldflags)
	{
		if(m_compiler_command.empty()){
			// [LUANTI_BUILD]: the archive without a compiler
			log_e(MODULE, "%s: no C++ compiler, and this module is not "
					"prebuilt in the cache: a game with C++ modules that are "
					"not prebuilt needs one (on Linux, the system's c++; on "
					"Windows, the full archive's compiler/)", cs(in_path));
			return false;
		}
		ss_ command = m_compiler_command;
		// Without an -O flag gcc defaults to -O0, which for a voxel module is
		// the difference between an array access and a function call per
		// voxel. Modules are compiled once at startup, so the extra compile
		// time is paid once and the code runs for the life of the server.
		command += " -DRCCPP "+cxxflags_optimize()+" -g -fPIC -fvisibility=hidden -shared";
		command += " -std=c++11";
		if(extra_cxxflags != "")
			command += ss_()+" "+extra_cxxflags;

		for(const std::string &dir : include_directories) command += " -I"+dir;
		for(const std::string &dir : library_directories) command += " -L"+dir;

		command += " -o"+out_path;
		command += " "+in_path;

		if(extra_ldflags != "")
			command += ss_()+" "+extra_ldflags;

		for(const std::string &lib : libraries) command += " "+lib;

		interface::process::ExecOptions exec_opts;
#ifdef _WIN32
		// If compiler_command looks like a path, add the directory part of it to
		// PATH. This seems to be required on Wine for running mingw g++, in which
		// case the DLLs are in the directory of the called executable, but the
		// called executable calls another executable in a directory that does not
		// contain the DLLs.
		if(m_compiler_command.find("/") != ss_::npos ||
				m_compiler_command.find("\\") != ss_::npos){
			ss_ command_dir = interface::fs::strip_file_name(m_compiler_command);
			exec_opts.env["PATH"] = command_dir + ";" +
					interface::process::get_environment_variable("PATH");
			log_d(MODULE, "Using PATH=%s", cs(exec_opts.env["PATH"]));
		}
		// GCC wants TMPDIR, TMP or TEMP for its temporary files and, given
		// none, falls back to C:\WINDOWS\, which a desktop refuses -- the
		// first module build of the 0.3.0 archive failed on it ([WIN_TMP]).
		// The compiler inherits the desktop's environment now; a desktop
		// that sets none gets a tmp/ beside the out path (the cache).
		if(interface::process::get_environment_variable("TEMP").empty() &&
				interface::process::get_environment_variable("TMP").empty() &&
				interface::process::get_environment_variable("TMPDIR").empty()){
			const ss_ tmp = interface::fs::strip_file_name(out_path) + "/tmp";
			interface::fs::create_directories(tmp);
			exec_opts.env["TEMP"] = tmp;
			exec_opts.env["TMP"] = tmp;
			log_i(MODULE, "No TEMP in the environment; the compiler gets %s",
					cs(tmp));
		}
#endif
		// What the compiler said goes to a file beside the output, and
		// into the log at warning when the build failed: a box with no
		// console had "Failed to build module" and nothing else
		// ([WIN8_START] 9)
		exec_opts.output_path = out_path + ".compile.log";
		int exit_status = interface::process::shell_exec(command, exec_opts);
		// [WIN_PACKAGE_052] gcc's own start of one of its programs failing
		// ("cannot execute 'as'" / "...cc1plus.exe': CreateProcess"), the
		// same compiler having built the modules before it: Wine's
		// process start, now and then (the v0.7.31 prebuild, the v0.7.52
		// smoke). Once more, logged; a second failure is the failure.
		if(exit_status != 0){
			std::ifstream f(exec_opts.output_path);
			const ss_ said((std::istreambuf_iterator<char>(f)),
					std::istreambuf_iterator<char>());
			if(said.find("cannot execute") != ss_::npos){
				log_w(MODULE, "The compiler could not start a program of its "
						"own; once more: %s", cs(out_path));
				exit_status = interface::process::shell_exec(command, exec_opts);
			}
		}
		if(exit_status != 0){
			log_w(MODULE, "Compile failed (exit %i): %s", exit_status,
					cs(command));
			std::ifstream f(exec_opts.output_path);
			ss_ line;
			int n = 0;
			while(std::getline(f, line) && n++ < 80)
				log_w(MODULE, "  %s", cs(line));
			if(n >= 80)
				log_w(MODULE, "  ... (the rest in %s)", cs(exec_opts.output_path));
		}
		return exit_status == 0;
	}

	bool build(const std::string &module_name,
			const std::string &in_path, const std::string &out_path,
			const ss_ &extra_cxxflags, const ss_ &extra_ldflags,
			bool skip_compile)
	{
		log_nd(MODULE, "Building %s: %s -> %s... ", cs(module_name), cs(in_path),
				cs(out_path));

		std::string out_dir = c55fs::stripFilename(out_path);
		c55fs::CreateAllDirs(out_dir);

		if(skip_compile){
			log_d(MODULE, "Skipped");
		} else {
			if(!compile(in_path, out_path, extra_cxxflags, extra_ldflags)){
				log_d(MODULE, "Failed!");
				return false;
			}
			log_d(MODULE, "Success!");
		}

		void *new_module = library_load(out_path.c_str());
		if(new_module == NULL){
			log_i(MODULE, "Failed to load compiled library: %s (path: %s)",
					library_error(), cs(out_path));
			return false;
		}

		ss_ constructor_name = ss_()+"createModule_"+module_name;
		RCCPP_Constructor constructor = (RCCPP_Constructor)library_get_address(
				new_module, constructor_name.c_str());
		if(constructor == nullptr){
			log_i(MODULE, "%s is missing from the library", cs(constructor_name));
			return false;
		}

		auto it = m_module_info.find(module_name);
		if(it != m_module_info.end()){
			RCCPP_Info &funcs = it->second;
			funcs.constructor = constructor;
			funcs.module = new_module;
		} else {
			RCCPP_Info funcs;
			funcs.constructor = constructor;
			funcs.module = new_module;
			m_module_info.emplace(module_name, std::move(funcs));
		}
		return true;
	}

	void* construct(const char *name, interface::Server *server)
	{
		auto it = m_module_info.find(name);
		if(it == m_module_info.end()){
			log_w(MODULE, "construct(%s): Module is not loaded", name);
			return NULL;
		}

		RCCPP_Info &info = it->second;
		RCCPP_Constructor constructor = info.constructor;

		return constructor(server);
	}

	void unload(const std::string &module_name)
	{
		auto it = m_module_info.find(module_name);
		if(it == m_module_info.end()){
			assert(nullptr && "Failed to get class info");
			return;
		}
		void *module = it->second.module;
		library_unload(module);
		m_module_info.erase(module_name);
	}
};

Compiler* createCompiler(const ss_ &compiler_command)
{
	return new CCompiler(compiler_command);
}

} // rccpp
// vim: set noet ts=4 sw=4:
