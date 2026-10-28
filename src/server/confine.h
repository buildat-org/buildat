// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace core {
	struct Config;
}

namespace server
{
	// [PROCESS_SANDBOX]: the server confines itself before it loads an
	// app, so an app from an untrusted source and a malicious client reach
	// nothing of the user's beyond what the app keeps. Called once, from
	// main(), with the paths settled and no thread started. Points the
	// config's cache_path and rccpp_build_path at the app's own cache
	// first.
	//
	// Linux: Landlock (the filesystem by an allow-list; abstract unix
	// sockets and signals scoped where the kernel has it) and seccomp
	// (no unix socket, no io_uring). Returns "" when the box is made, or
	// why not.
	//
	// Windows: an AppContainer per app and a job object. The process
	// started unboxed is a thin parent: it starts itself again in the box
	// (its own command line and --boxed), carries the child's output into its own log
	// and sets *exit_code to the child's; started --boxed, it checks it is
	// in its container. Elsewhere *exit_code is left alone.
	ss_ confine(core::Config &config, const ss_ &module_path,
			int *exit_code);

	// [WEB_LOCAL_AITTA] The box of a publish's build of a release's
	// .wasm (build_wasm_job() below): Linux only. Reads the
	// system's programs and libraries and read_dirs, writes job_dir only;
	// no socket, no TCP. Called once, with no thread started. "" or why
	// not (then nothing is built).
	ss_ confine_build(const sv_<ss_> &read_dirs, const ss_ &job_dir);

	// [WEB_LOCAL_AITTA] Aitta's build of a release's .wasm at publish, the
	// server started as `buildat_server --build-wasm <job> <interface
	// path>` (Linux), the engine's headers and crates there: the
	// release unpacked in <job>/src, each module's server .wasm built to
	// <job>/out/<module>.server.wasm and its wasm/ to <module>.wasm, as
	// wasm_build.h's build_module_wasm() builds them, in confine_build()'s
	// box and under its limits; what it said in <job>/log. 0 when each was
	// built; nothing is built outside the box.
	// [WEB_LOCAL_AITTA_CPP] kit: the engine's server for packages as parts
	// (util/aitta_cpp_build.py), read in the box with the emsdk at $EMSDK,
	// else ~/emsdk (interface::os::aitta_kit_emsdk());
	// with one, the release's C++ modules linked into a server of its own,
	// <job>/bin/buildat_server.{js,wasm}, by the kit's build.py.
	int build_wasm_job(const ss_ &job, const ss_ &interface_path,
			const ss_ &kit = "");

	// [PROCESS_SANDBOX] B: a boxed child's start, a step at a time, flushed
	// to the file its parent named in BUILDAT_BOXED_STEPS as well as to
	// the log, so a hang names its step even where the log's pipe holds
	// lines back. Nothing where no file was named.
	void boxed_step(const char *what);

	// The app's name, which get_app_id() answers: the directory's name, or
	// for an app installed from a release ([AITTA_MVP]),
	// .../installed/<author>/<name>/<version>, "<author>.<name>" -- every
	// version one app, with one save directory, and no tree app's name
	// has a dot in it; a playtest's "review.<author>__<name>"
	inline ss_ app_of(const ss_ &module_path)
	{
		sv_<ss_> parts;
		ss_ part;
		for(char c : module_path + "/"){
			if(c == '/' || c == '\\'){
				if(!part.empty() && part != ".")
					parts.push_back(part);
				part.clear();
			} else {
				part += c;
			}
		}
		const size_t n = parts.size();
		if(n >= 4 && parts[n - 4] == "installed")
			return parts[n - 3]+"."+parts[n - 2];
		// A reviewer's playtest ([AITTA_REVIEW]),
		// .../review/<author>__<name>/<version>: its saves apart
		if(n >= 3 && parts[n - 3] == "review" &&
				parts[n - 2].find("__") != ss_::npos)
			return "review."+parts[n - 2];
		if(n == 0 || parts[n - 1] == "..")
			return "unnamed";
		return parts[n - 1];
	}
}
// vim: set noet ts=4 sw=4:
