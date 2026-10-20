// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/event.h"
#include <functional>

namespace interface
{
	struct ModuleInfo;
	struct Module;

	namespace thread_pool {
		struct ThreadPool;
	}
}

namespace server
{
	struct ServerShutdownRequest: public Exception {
		ServerShutdownRequest(const ss_ &msg): Exception(msg){}
	};

	struct ModuleNotFoundException: public Exception {
		ModuleNotFoundException(const ss_ &msg): Exception(msg){}
	};

	// [COMPILE_SLOTS] The compile slots this user's servers share, opened
	// before the box (which has no /tmp); see state.cpp
	void open_compile_slots();

	struct State
	{
		virtual ~State(){}
		virtual void thread_request_stop() = 0;
		virtual void thread_join() = 0;

		virtual void shutdown(int exit_status = 0, const ss_ &reason = "") = 0;
		virtual bool is_shutdown_requested(int *exit_status = nullptr,
				ss_ *reason = nullptr) = 0;
		virtual bool load_module(const interface::ModuleInfo &info) = 0;
		virtual void load_modules(const ss_ &path) = 0;
		virtual interface::Module* get_module(const ss_ &module_name) = 0;
		virtual interface::Module* check_module(const ss_ &module_name) = 0;
		virtual void sub_event(struct interface::Module *module,
				const interface::Event::Type &type) = 0;
		virtual void emit_event(interface::Event event) = 0;
		// Runs every subscriber's handler in the calling thread before
		// returning. What "core:shutdown" needs: after it, the main loop is
		// over and a queued event would never be handled.
		virtual void emit_event_synchronously(interface::Event event) = 0;

		virtual void handle_events() = 0;

		// Add resource file path (to make a mirror of the client)
		virtual void add_file_path(const ss_ &name, const ss_ &path) = 0;
		// Returns "" if not found
		virtual ss_ get_file_path(const ss_ &name) = 0;

		virtual void access_thread_pool(std::function<void(
				interface::thread_pool::ThreadPool*pool)> cb) = 0;
	};

	State* createState();
}
// vim: set noet ts=4 sw=4:
