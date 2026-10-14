#include "interface/event.h"

namespace test1
{
	struct Thing: public interface::Event::Private
	{
		ss_ some_data;

		Thing(const ss_ &some_data = "default value"): some_data(some_data){}
	};

	inline void do_thing(interface::Server *server, const ss_ &some_data)
	{
		interface::Event event("test1:thing");
		event.p.reset(new test1::Thing(some_data));
		server->emit_event(std::move(event));
	}
}
// vim: set noet ts=4 sw=4:
