// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/sample_wasm_only's server half, a module of its own so that the
// Rust twin (apps/sample_wasm_only_rust, a variant of this app) has it
// too: answers the client's "main:key" (sent by its .wasm) with
// "main:echo", which the default client_main hands back to the .wasm as
// an event.
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
		sub(m_server, "network:packet_received/main:key", &Module::on_key);
	}

	void on_key(const network::Packet &packet)
	{
		log_i(MODULE, "key from the client's wasm: %s",
				cs(packet.data.substr(0, 100)));
		network::send(m_server, packet.sender, "main:echo",
				"colour "+packet.data.substr(0, 100));
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_echo(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
