// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// The network module of the server built for the web ([WEB_LOCAL_SERVER]),
// in place of network.cpp, which listens on a socket a browser does not
// have. util/web_server.cmake builds this one; the native server never does.
// simplified: nobody gets in yet; the in-page stream from the client is
// what comes here next (step 2)
#include "network/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#define MODULE "network"

namespace network {

struct Module: public interface::Module, public network::Interface
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		log_i(MODULE, "network: the web server's, which accepts no "
				"connection yet");
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	void send(PeerInfo::Id recipient, const ss_ &name, const ss_ &data){}
	sv_<PeerInfo::Id> list_peers(){ return {}; }
	size_t pending_bytes(PeerInfo::Id peer){ return 0; }
	void set_send_policy(SendPolicy policy, size_t max_queue_bytes,
			int64_t grace_us){}
	void declare(const ss_ &packet_name, Channel channel){}
	void disconnect(PeerInfo::Id peer){}
	void http_respond(PeerInfo::Id peer, int status, const ss_ &content_type,
			const ss_ &body, const ss_ &extra_headers){}
	bool listen_on(const ss_ &address, ss_ *error)
	{
		*error = "a server in a browser listens on nothing";
		return false;
	}
	void claim_http_path(const ss_ &prefix){}
	void claim_ws_path(const ss_ &prefix){}
	void set_page_has_no_game(){}
	void ws_send(PeerInfo::Id peer, const ss_ &data){}
	void ws_close(PeerInfo::Id peer, const ss_ &reason){}
	void set_favicon(const ss_ &png){}
	void set_page_title(const ss_ &name, bool admin){}
	void lan_announce(const ss_ &name, bool account){}
	void set_ws_origins(const ss_ &by, const sv_<ss_> &origins){}
	ss_ health_json(){ return "{}"; }
	void set_has_admin(bool admin){}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
