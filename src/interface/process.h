#pragma once
#ifdef BUILDAT_WEB_MODULE
// [WEB_LOCAL_SERVER]: a module of the server built for the web has no
// sockets, HTTP or processes (doc/server_api.txt, "The web API")
#error "interface/process.h is not in the web server's module API"
#endif
#include "core/types.h"

namespace interface
{
	namespace process
	{
		// I have no idea why ss_ doesn't work here in mingw-w64

		std::string get_environment_variable(const std::string &name);

		struct ExecOptions {
			sm_<ss_, ss_> env;
			// A file the child's stdout and stderr go into, when set: what
			// a failed compile said, for the log ([WIN8_START] 9)
			ss_ output_path;
		};

		int shell_exec(const std::string &command,
				const ExecOptions &opts = ExecOptions());

		// The system's opener on a link or a folder: ShellExecute on
		// Windows (no cmd.exe; its "start" is not a program), open on
		// macOS, xdg-open elsewhere, not waited for. False where it could
		// not be handed over (logged); a target with a quote in it is
		// refused, since the POSIX ones go through a shell.
		bool open_with_system(const std::string &target);

		// Long-running child. Does not wait. path is the executable.
		struct Handle {
			intptr_t impl = 0;
			bool valid() const;
		};

		// cwd: the child's working directory, or the parent's when empty
		// ([WIN8_START]: a server started from bin/ formed its paths from
		// there)
		Handle start(const std::string &path, const sv_<ss_> &args,
				const ss_ &cwd = "");
		// SIGTERM (or equivalent). Does not wait. Handle stays valid until
		// the process exits or kill_force() is used.
		void request_terminate(Handle &h);
		// SIGKILL and reap. Clears the handle.
		void kill_force(Handle &h);
		// request_terminate, wait up to 10s, then kill_force.
		void terminate(Handle &h);
		bool is_running(const Handle &h);
		// **Reap it if it has already gone**, without waiting for it:
		// true when the handle is now invalid, which is what a caller
		// stopping a server a frame at a time asks each frame
		// ([QUIT_STALL]). A child that has exited but not been reaped
		// still answers kill(pid, 0), so is_running() alone reads a
		// zombie as a running server.
		bool reap(Handle &h);
	}
}
// vim: set noet ts=4 sw=4:
