#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "test1/api.h"
#include "core/log.h"
#define MODULE "test2"

using interface::Event;

namespace test2 {

struct Module: public interface::Module
{
	interface::Server *m_server;
	Event::Type m_EventType_core_start;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server),
		m_EventType_core_start(Event::t("core:start"))
	{
		log_v(MODULE, "test2 construct");
	}

	~Module()
	{
		log_v(MODULE, "test2 destruct");
	}

	void init()
	{
		log_v(MODULE, "test2 init");
		m_server->sub_event(this, m_EventType_core_start);
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		if(type == m_EventType_core_start){
			on_start();
		}
	}

	void on_start()
	{
		log_i(MODULE, "test2 start(): Calling test1");

		{ // Raw
			Event::Type type = Event::t("test1:thing");
			Event event(type, up_<Event::Private>(new test1::Thing("Nakki")));
			m_server->emit_event(std::move(event));
		}

		{ // Simplified raw
			Event event("test1:thing", new test1::Thing("Kebab"));
			m_server->emit_event(std::move(event));
		}

		{ // Even simpler
			m_server->emit_event("test1:thing", new test1::Thing("Pitsa"));
		}

		{ // Inline wrapper
			test1::do_thing(m_server, "Rulla");
		}
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_test2(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
