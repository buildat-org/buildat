#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "test1/api.h"
#include "client_file/api.h"
#include "network/api.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#define MODULE "test1"

using interface::Event;

namespace test1 {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		log_v(MODULE, "test1 construct");
	}

	~Module()
	{
		log_v(MODULE, "test1 destruct");
	}

	void init()
	{
		log_v(MODULE, "test1 init");
		sub(m_server, "test1:thing", &Module::on_thing);
		sub(m_server, "network:client_connected", &Module::on_client_connected);
		sub(m_server, "client_file:files_transmitted",
				&Module::on_files_transmitted);
		sub(m_server, "network:packet_received", &Module::on_packet_received);
	}

	void on_thing(const Thing &thing)
	{
		log_i(MODULE, "test1.thing: some_data=%s", cs(thing.some_data));
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
		log_v(MODULE, "test1::on_client_connected: id=%zu",
				client_connected.info.id);

		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(client_connected.info.id, "test1:dummy",
					"dummy data");
		});
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		log_v(MODULE, "on_files_transmitted(): recipient=%zu", event.recipient);

		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"test1/init.lua\")");
		});

		network::access(m_server, [&](network::Interface *inetwork){
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar(1.0, 1.0, 1.0);
				ar(0.0, 0.5, 0.0);
			}
			inetwork->send(event.recipient, "test1:add_box", os.str());
		});

		network::access(m_server, [&](network::Interface *inetwork){
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				sv_<int32_t> array = {1, 2, 3, 4, 5};
				ar(array);
			}
			inetwork->send(event.recipient, "test1:array", os.str());
		});
	}

	void on_packet_received(const network::Packet &packet)
	{
		log_i(MODULE, "test1::on_packet_received: name=%s, size=%zu",
				cs(packet.name), packet.data.size());
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_test1(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
