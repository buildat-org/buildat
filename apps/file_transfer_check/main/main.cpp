// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/file_transfer_check's server half ([FILE_TRANSFER_LATENCY]):
// "main:ping" comes back as "main:pong", and "main:big" serves a file of
// BUILDAT_FTC_BYTES incompressible bytes (4 MB by default, 64 MB at most)
// as main/big.bin, which the connected client is told of and fetches
// while it pings.
#include "interface/module.h"
#include "interface/server.h"
#include "network/api.h"
#include "client_file/api.h"
#include "core/log.h"
#include <cstdlib>
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
		sub(m_server, "network:packet_received/main:big", &Module::on_big);
	}

	void on_ping(const network::Packet &packet)
	{
		network::send(m_server, packet.sender, "main:pong",
				packet.data.substr(0, 100));
	}

	void on_big(const network::Packet &packet)
	{
		const char *e = getenv("BUILDAT_FTC_BYTES");
		const size_t n = std::min<size_t>(e ? atol(e) : 4000000,
				64 * 1024 * 1024);
		ss_ content(n, '\0');
		uint64_t x = 0x9e3779b97f4a7c15ull + n;
		for(size_t i = 0; i < n; i++){
			x ^= x << 13; x ^= x >> 7; x ^= x << 17;
			content[i] = (char)(x >> 32);
		}
		log_i(MODULE, "file_transfer_check: serving %zu bytes", n);
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_content("main/big.bin", content);
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
