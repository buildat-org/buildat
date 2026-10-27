// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "core/config.h"

namespace boot
{
	namespace autodetect
	{
		// Return value: true if paths seem alright
		bool check_server_paths(const core::Config &config, bool log_issues);
		bool check_client_paths(const core::Config &config, bool log_issues);

		// The C++ compiler's command (the server's lookup: the root's
		// compiler/bin/, then PATH's c++), "" for none ([CLIENT_WASM])
		ss_ find_compiler_command();

		// Return value: true if succesful, false if failed
		bool detect_server_paths(core::Config &config);
		bool detect_client_paths(core::Config &config);

		// The log ([WIN8_START]): with no -L, <cache>/<name>.log at info,
		// the previous run's moved to <name>_1.log first; a relative -L is
		// made absolute against the cwd. Then the first lines: the exe,
		// the root, the cwd and the log's path. name is "buildat" or
		// "buildat_server". Returns the log's absolute path, "" for none.
		ss_ open_log(core::Config &config, const ss_ &name, const ss_ &exe);
	}
}
// vim: set noet ts=4 sw=4:
