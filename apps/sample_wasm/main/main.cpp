// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm's server half: answers the client's wasm module's
// "main:ping" with "main:pong", the packet round trip of [CLIENT_WASM]
// step 2's check.
#include "interface/module.h"
#include "interface/server.h"
#include "network/api.h"
#include "core/log.h"
#define MODULE "main"

namespace main_ {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		sub(m_server, "network:packet_received/main:ping", &Module::on_ping);
	}

	void on_ping(const network::Packet &packet)
	{
		log_i(MODULE, "ping from the client's wasm: %s",
				cs(packet.data.substr(0, 100)));
		network::send(m_server, packet.sender, "main:pong",
				"pong: "+packet.data.substr(0, 100));
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
