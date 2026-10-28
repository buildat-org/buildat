// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface {
	struct Module;
	struct Server;
	struct ModuleInfo;
}

namespace server
{
	// [SERVER_WASM] A module whose meta.json names a "server_wasm": the
	// .wasm at wasm_path (wasm_build.cpp built it) read, checked against
	// what the module is granted and metered, as a module the server runs
	// on its own thread as it runs a C++ one. Null with why when it is
	// refused; nothing of it has run then.
	interface::Module* create_wasm_module(interface::Server *server,
			const interface::ModuleInfo &info, const ss_ &wasm_path,
			const ss_ &cache_root, ss_ &why);
}
// vim: set noet ts=4 sw=4:
