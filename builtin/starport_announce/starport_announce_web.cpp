// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// starport_announce in the server built for the web ([WEB_LOCAL_SERVER]),
// in place of starport_announce.cpp: a server in a browser is nobody's to
// list, and takes no Starport IDs. It is here so that an app that depends on
// the module builds unchanged. util/web_server.cmake builds this one; the
// native server never does.
#include "starport_announce/api.h"
#include "core/log.h"
#define MODULE "starport_announce"

namespace starport_announce {

struct Module: public interface::Module, public Interface
{
	Module(interface::Server *server):
		interface::Module(MODULE)
	{}

	void init(){}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	bool accepts_ids(){ return false; }
	ss_ ids_mode(){ return "off"; }
	sv_<ss_> starports(){ return {}; }
	void set_game(const ss_ &source){}
	ss_ set_ids_mode(const ss_ &mode, const ss_ &address)
	{
		return "a server in a browser is not on a Starport";
	}
	bool is_blocked(const ss_ &host, const ss_ &sub){ return false; }
	void announce_soon(){}
	ss_ verify_id_token(const ss_ &token, IdLogin *out)
	{
		return "a server in a browser takes no Starport IDs";
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_starport_announce(
			interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
