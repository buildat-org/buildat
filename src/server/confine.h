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

	// [AITTA_BUILD_MEM] The cgroup of --build-wasm's builds, where the
	// server's own is delegated to it (Linux): made before confine() and
	// before the camera's launcher is forked, while the server is alone in
	// its cgroup. Sets or unsets BUILDAT_BUILD_CGROUP, which confine()
	// reads.
	void make_build_cgroup();

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
	// [WEB_LOCAL_AITTA_CPP] SDK: the engine's server for packages as parts
	// (util/aitta_cpp_build.py), read in the box with the emsdk at $EMSDK,
	// else ~/emsdk (interface::os::aitta_sdk_emsdk());
	// with one, the release's C++ modules linked into a server of its own,
	// <job>/bin/buildat_server.{js,wasm}, by the SDK's build.py.
	int build_wasm_job(const ss_ &job, const ss_ &interface_path,
			const ss_ &sdk = "");

	// [KIT_AGENT_NEXT_1] **The server's camera's launcher**: a process
	// forked from main() before the box and before any thread (Linux
	// only), which starts the camera client Kit asks for -- this
	// install's bin/buildat, headless, connecting to this server's own
	// port on 127.0.0.1 -- in a box of its own: it reads the system and
	// the install (the server's user and cache paths cut out), writes
	// only <user>/camera/<app> (made fresh at each start; outside the
	// server's own box) and connects to the server's port only. The boxed
	// server cannot start it itself: its seccomp takes unix sockets
	// (X11's), and its Landlock lets it connect to its own port nowhere.
	// Requests on config "camera_launcher"'s first fd, a line each:
	// "start <offscreen|x11> <w> <h> <secret>", "cmd <drive command>"
	// (the client's -c - input), "stop"; answers on its second
	// (non-blocking): "started <pid>", "refused <why>", "exited (status
	// <n>)" or "exited (signal <n>)", then ": <the last error it logged>"
	// if any. The display for x11 is config "camera_display" (":N", the
	// host's: --camera-display, BUILDAT_CAMERA_DISPLAY), never the
	// server's own DISPLAY. The launcher and the client die with the
	// server (PR_SET_PDEATHSIG). Nothing a request says is run but that
	// client with those few values checked; the secret goes by its
	// environment (BUILDAT_AGENT_TOKEN, which it unsets at once).
	void start_camera_launcher(core::Config &config, const ss_ &module_path);

	// [PROCESS_SANDBOX] B: a boxed child's start, a step at a time, flushed
	// to the file its parent named in BUILDAT_BOXED_STEPS as well as to
	// the log, so a hang names its step even where the log's pipe holds
	// lines back. Nothing where no file was named.
	void boxed_step(const char *what);

	// The app's name, which get_app_id() answers: the directory's name, or
	// for an app installed from a release ([AITTA_MVP]),
	// .../installed/<fp>/<name>/<version>, "<fp>.<name>" (fp its key's
	// fingerprint, [AITTA_KEY_IDENTITY]) -- every version one app, with
	// one save directory, and no tree app's name has a dot in it; a
	// playtest's "review.<fp>__<name>"
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
		// .../review/<fp>__<name>/<version>: its saves apart
		if(n >= 3 && parts[n - 3] == "review" &&
				parts[n - 2].find("__") != ss_::npos)
			return "review."+parts[n - 2];
		if(n == 0 || parts[n - 1] == "..")
			return "unnamed";
		return parts[n - 1];
	}
}
// vim: set noet ts=4 sw=4:
