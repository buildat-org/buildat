// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// apps/drive_waits_check's server half ([DRIVE_WAITS]): "main:act" is
// answered with "main:acted" half a second later, handled in this
// module's own thread, so a network:sync sent after it is answered only
// once the answer is out.
#include "interface/module.h"
#include "interface/server.h"
#include "network/api.h"
#include <chrono>
#include <thread>
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
		sub(m_server, "network:packet_received/main:act", &Module::on_act);
	}

	void on_act(const network::Packet &packet)
	{
		std::this_thread::sleep_for(std::chrono::milliseconds(500));
		network::send(m_server, packet.sender, "main:acted", "");
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
