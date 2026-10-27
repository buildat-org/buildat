// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_ui's server half: answers the client's "main:click"
// and "main:key" (sent by its .wasm) with "main:echo", which the default
// client_main hands back to the .wasm as an event.
#include "interface/module.h"
#include "interface/server.h"
#include "network/api.h"
#include "core/log.h"
#define MODULE "echo"

namespace echo {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		sub(m_server, "network:packet_received/main:click", &Module::on_click);
		sub(m_server, "network:packet_received/main:key", &Module::on_key);
	}

	void answer(const network::Packet &packet, const ss_ &what)
	{
		log_i(MODULE, "%s from the client's wasm: %s", cs(what),
				cs(packet.data.substr(0, 100)));
		network::send(m_server, packet.sender, "main:echo",
				what+" "+packet.data.substr(0, 100));
	}
	void on_click(const network::Packet &packet){ answer(packet, "click"); }
	void on_key(const network::Packet &packet){ answer(packet, "key"); }
};

extern "C" {
	BUILDAT_EXPORT void* createModule_echo(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
