// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/event.h"
#include <functional>
#include <type_traits>
#include <unordered_map>

#define BUILDAT_EXPORT __attribute__((visibility("default")))

namespace interface
{
	// Thrown by access_module() when the target module's thread has been asked
	// to stop, ie. the server is shutting down or the module is being reloaded
	// or unloaded. The module may already be deleted.
	struct ModuleAskedToStop: public Exception {
		ModuleAskedToStop(const ss_ &msg): Exception(msg){}
	};

	struct Server;

	struct Module
	{
		const char *m_module_name = "(unknown module)";
		Module(const char *name): m_module_name(name){}
		virtual ~Module(){}
		virtual void init() = 0;
		// The handlers sub() registered ([EVENT_SUB_ONCE]). A module that
		// lists its events itself -- sub_event() in init(), EVENT_TYPEN
		// here -- overrides this, as every module did before.
		virtual void event(const Event::Type &type, const Event::Private *p)
		{
			dispatch(type, p);
		}

		// **An event named once** ([EVENT_SUB_ONCE]), in init():
		//   sub(m_server, "core:tick", &Module::on_tick);
		// subscribes to it and has event() call the handler with the
		// event's parameter as the handler's type: a type that is no
		// Event::Private does not compile, and an event carrying another
		// throws as EVENT_TYPEN does. A handler with no parameter takes
		// none. One handler per event: a second sub() of a name throws.
		template<typename M, typename T>
		void sub(Server *server, const ss_ &name, void (M::*handler)(const T&))
		{
			M *self = static_cast<M*>(this);
			sub<T>(server, name, [self, handler](const T &t){
				(self->*handler)(t);
			});
		}
		template<typename M>
		void sub(Server *server, const ss_ &name, void (M::*handler)())
		{
			M *self = static_cast<M*>(this);
			add_handler(server, name, [self, handler](const Event::Private*){
				(self->*handler)();
			});
		}
		// A handler that is not this module's own method: another object's
		// (skeldat's Luanti session), named with its parameter type,
		//   sub<network::Packet>(m_server, name, [&](const network::Packet &p){...});
		template<typename T>
		void sub(Server *server, const ss_ &name, std::function<void(const T&)> f)
		{
			static_assert(std::is_base_of<Event::Private, T>::value,
					"an event's parameter is an Event::Private");
			add_handler(server, name, [f, name](const Event::Private *p){
				auto p0 = dynamic_cast<const T*>(p);
				if(!p0)
					throw Exception(ss_()+(p ? "Invalid" : "Missing")+
							" parameter to the handler of \""+name+"\"");
				f(*p0);
			});
		}

		// Calls the handler sub() registered for this type; false if none
		bool dispatch(const Event::Type &type, const Event::Private *p)
		{
			auto it = m_handlers.find(type);
			if(it == m_handlers.end())
				return false;
			it->second(p);
			return true;
		}
		virtual void* get_interface(){
			return NULL;
		}
		void* check_interface();

	private:
		std::unordered_map<Event::Type,
				std::function<void(const Event::Private*)>> m_handlers;
		// Subscribes too (module.cpp, which knows Server)
		void add_handler(Server *server, const ss_ &name,
				std::function<void(const Event::Private*)> f);
	};
}
// vim: set noet ts=4 sw=4:
