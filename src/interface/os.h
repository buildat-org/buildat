// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <ctime>
#include <cstdlib>
#include <cstdio>
#if defined(__linux__) && !defined(__EMSCRIPTEN__)
#include <sys/prctl.h>
#include <signal.h>
#include <unistd.h>
#endif

namespace interface
{
	namespace os
	{
		int64_t time_us();
		// The calendar: time_us() plus an offset that only a server run
		// with --sim-clock moves ([SIM_CLOCK]). For dates, expiries and
		// limits per hour or day; time_us() for timeouts and budgets
		int64_t wall_us();
		void set_wall_offset_us(int64_t offset_us);
		// Seconds since the epoch as a UTC calendar
		inline struct tm utc_tm(int64_t t)
		{
			const time_t tt = (time_t)t;
			struct tm tmv = {};
#ifdef _WIN32
			gmtime_s(&tmv, &tt);
#else
			gmtime_r(&tt, &tmv);
#endif
			return tmv;
		}
		void sleep_us(int us);
		// [PROCESS_SANDBOX] What the environment says of the server's
		// sandbox, read here for the server and the client both
		// ([REWORK_SWEEP_1019] engine 4): BUILDAT_UNCONFINED=1 turns it
		// off on every system, BUILDAT_WINDOWS_SANDBOX=0 the Windows one
		// (BUILDAT_WINDOWS_BOX=0, its name before [SANDBOX_WORDING])
		inline bool unconfined_by_env()
		{
			const char *u = getenv("BUILDAT_UNCONFINED");
			return u && ss_(u) == "1";
		}
		// [AITTA_KIT_IN_RELEASE] The emsdk an Aitta's C++ kit
		// (BUILDAT_AITTA_CPP_KIT) builds with: $EMSDK, else ~/emsdk
		inline ss_ aitta_kit_emsdk()
		{
			const char *e = getenv("EMSDK");
			if(e && *e)
				return e;
			const char *h = getenv("HOME");
			return h && *h ? ss_(h)+"/emsdk" : "";
		}
		inline bool windows_sandbox_off_by_env()
		{
			const char *w = getenv("BUILDAT_WINDOWS_SANDBOX");
			if(!w)
				w = getenv("BUILDAT_WINDOWS_BOX");
			return w && ss_(w) == "0";
		}
		// [CHECK_SERVER_ORPHANS] Gone with the process that started it,
		// when BUILDAT_DIE_WITH_PARENT=1 asks (util/check_lib.sh exports
		// it): a check SIGKILLed past its trap left its server running.
		// SIGTERM, so the binary stops as on any SIGTERM. A death signal
		// already set is kept: the launcher's local server has SIGKILL
		// from process::start(). Linux only; checks run there. Exits if
		// the parent is already gone.
		// simplified: the direct parent only; under `timeout N` that is
		// timeout, which outlives a killed check by up to N seconds.
		// simplified: a parent dead before main() goes unseen (getppid is
		// already the reaper); pass the check's PID if that bites.
		inline void die_with_parent_if_asked()
		{
#if defined(__linux__) && !defined(__EMSCRIPTEN__)
			const char *v = getenv("BUILDAT_DIE_WITH_PARENT");
			if(!v || ss_(v) != "1")
				return;
			int sig = 0;
			if(prctl(PR_GET_PDEATHSIG, &sig) == 0 && sig != 0)
				return;
			const pid_t ppid = getppid();
			if(prctl(PR_SET_PDEATHSIG, SIGTERM) != 0)
				return;
			if(getppid() != ppid){
				fprintf(stderr, "The parent is gone; exiting\n");
				exit(1);
			}
#endif
		}
		ss_ get_current_exe_path();
		// name without extension; looks next to the current executable
		ss_ get_sibling_exe_path(const ss_ &name);
		// The process's resident memory in bytes, 0 if unknown
		// ([SERVER_HEALTH]; simplified: Linux and Windows, 0 on macOS)
		int64_t memory_bytes();
		// The bytes free to this process on the filesystem under path, -1
		// if unknown ([SERVER_ADMIN_PAGE])
		int64_t free_bytes(const ss_ &path);
	}
}

// vim: set noet ts=4 sw=4:
