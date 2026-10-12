// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/event.h"
#include <functional>

namespace Urho3D
{
	class Scene;
	class StringHash;
}

namespace server
{
	struct Config;
}

namespace interface
{
	namespace magic = Urho3D;

	struct ModuleInfo;
	struct Module;
	typedef server::Config ServerConfig;

	namespace thread_pool {
		struct ThreadPool;
	}

	struct TickEvent: public interface::Event::Private {
		float dtime;
		TickEvent(float dtime): dtime(dtime){}
	};

	struct ModuleModifiedEvent: public interface::Event::Private {
		ss_ name;
		ss_ path;
		ModuleModifiedEvent(const ss_ &name, const ss_ &path):
			name(name), path(path){}
	};

	struct ModuleLoadedEvent: public interface::Event::Private {
		ss_ name;
		ModuleLoadedEvent(const ss_ &name): name(name){}
	};

	struct ModuleUnloadedEvent: public interface::Event::Private {
		ss_ name;
		ModuleUnloadedEvent(const ss_ &name): name(name){}
	};

	struct Server
	{
		virtual ~Server(){}

		virtual void shutdown(int exit_status = 0, const ss_ &reason = "") = 0;

		virtual bool load_module(const interface::ModuleInfo &info) = 0;
		// How many modules the loader is about to load, for the STATUS
		// lines a start is followed by ([START_PROGRESS])
		virtual void set_module_count(size_t count) = 0;
		// [PARALLEL_COMPILE]: compile, side by side, those of the modules
		// whose build is not current, so that load_module() finds each one
		// current. false with the module's name if one did not compile.
		virtual bool compile_modules(const sv_<interface::ModuleInfo> &infos,
				ss_ *failed_module) = 0;
		virtual void unload_module(const ss_ &module_name) = 0;
		virtual void reload_module(const interface::ModuleInfo &info) = 0;
		virtual void reload_module(const ss_ &module_name) = 0;
		virtual ss_ get_modules_path() = 0;
		virtual ss_ get_builtin_modules_path() = 0;
		virtual ss_ get_module_path(const ss_ &module_name) = 0;
		virtual bool has_module(const ss_ &module_name) = 0;
		virtual sv_<ss_> get_loaded_modules() = 0;
		virtual bool access_module(const ss_ &module_name, // Always returns true
				std::function<void(interface::Module*)> cb) = 0;
		// False, and cb not called, when the module is not loaded
		bool access_module_optional(const ss_ &module_name,
				std::function<void(interface::Module*)> cb){
			if(!has_module(module_name))
				return false;
			return access_module(module_name, cb);
		}

		virtual void sub_event(struct Module *module, const Event::Type &type) = 0;
		virtual void emit_event(Event event) = 0;
		template<typename TypeT>
		void emit_event(const TypeT &type){
			emit_event(std::move(Event(type)));
		}
		template<typename TypeT, typename PrivateT>
		void emit_event(const TypeT &type, PrivateT *p){
			emit_event(std::move(Event(type, up_<Event::Private>(p))));
		}

		virtual void tmp_store_data(const ss_ &name, const ss_ &data) = 0;
		virtual ss_ tmp_restore_data(const ss_ &name) = 0;

		// Add resource file path (to make a mirror of the client)
		virtual void add_file_path(const ss_ &name, const ss_ &path) = 0;
		// Returns "" if not found
		virtual ss_ get_file_path(const ss_ &name) = 0;

		virtual const ServerConfig& get_config() = 0;

		// The last path component of -m: "minigame" for
		// -m ../apps/minigame. It namespaces what the server keeps under the
		// user path, so that one game cannot name another's saves.
		virtual ss_ get_app_id() = 0;

		virtual void access_thread_pool(std::function<void(
				interface::thread_pool::ThreadPool*pool)> cb) = 0;
	};
}
// vim: set noet ts=4 sw=4:
