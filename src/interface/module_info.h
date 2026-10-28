// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	struct ModuleDependency
	{
		ss_ module;
		bool optional = false;
	};

	struct ModuleMeta
	{
		bool disable_cpp = false;
		// A client-side script the engine runs once per peer when the
		// client's files first arrive, named relative to the module
		// (e.g. "init.lua" runs "<module>/init.lua") ([ENGINE_LOADER])
		ss_ client_main;
		// Extensions (<share>/extensions/<name>) the server serves to its
		// clients for this module's client scripts, which run the served
		// copy: client_file::serve_extension()
		sv_<ss_> client_extensions;
		ss_ cxxflags;
		ss_ ldflags;
		ss_ cxxflags_linux;
		ss_ ldflags_linux;
		ss_ cxxflags_windows;
		ss_ ldflags_windows;
		sv_<ModuleDependency> dependencies;
		sv_<ModuleDependency> reverse_dependencies;
		// [SERVER_WASM] The module is a .wasm, not C++: built from this
		// directory of it (a Rust crate, or C and C++) and run sandboxed
		// (src/server/wasm_module.cpp). "" for a C++ module. meta.json:
		//   "server_wasm": {"source": "server", "imports": ["packets"],
		//       "callable": ["count"]}
		ss_ server_wasm;
		// The groups of interface/wasm_server_api.h's imports it is granted
		sv_<ss_> server_wasm_imports;
		// Its exports other wasm modules may call (buildat_call())
		sv_<ss_> server_wasm_callable;
	};

	struct ModuleInfo
	{
		ss_ name;
		ss_ path;
		ModuleMeta meta;
	};
}
// vim: set noet ts=4 sw=4:
