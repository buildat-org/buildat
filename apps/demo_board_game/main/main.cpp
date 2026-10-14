#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "client_file/api.h"
#include "network/api.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#include <cstdlib>
#define MODULE "main"

using interface::Event;

namespace demo_board_game {

struct Playfield
{
	size_t w = 0;
	size_t h = 0;
	sv_<int> tiles;
	Playfield(size_t w, size_t h): w(w), h(h){
		tiles.resize(w * h);
	}
	int get(int x, int y){
		size_t i = y * w + x;
		if(i > tiles.size())
			return 0;
		return tiles[i];
	}
	void set(int x, int y, int v){
		size_t i = y * w + x;
		if(i > tiles.size())
			return;
		if(!inside_field(x, y))
			return;
		tiles[i] = v;
	}

	bool inside_field(int x, int y){
		if(x >= w || x < 0)
			return false;
		if(y >= h || y < 0)
			return false;
		return true;
	}

	template<class Archive>
	void serialize(Archive &archive){
		archive((int32_t)w, (int32_t)h);
		archive(tiles);
	}
};

struct Player
{
	int peer = 0;
	int x = 0;
	int y = 0;

	Player(int peer = 0, int x = 0, int y = 0): peer(peer), x(x), y(y){}

	template<class Archive>
	void serialize(Archive &archive){
		archive((int32_t)peer, (int32_t)x, (int32_t)y);
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	Playfield m_playfield;
	sm_<int, Player> m_players;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server),
		m_playfield(10, 10)
	{
		log_v(MODULE, "demo_board_game construct");
	}

	~Module()
	{
		log_v(MODULE, "demo_board_game destruct");
	}

	void init()
	{
		log_v(MODULE, "demo_board_game init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("network:packet_received/demo_board_game:move"));
		m_server->sub_event(this,
				Event::t("network:packet_received/demo_board_game:clear_field"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/demo_board_game:move", on_packet_move,
				network::Packet)
		EVENT_TYPEN("network:packet_received/demo_board_game:clear_field",
				on_packet_clear_field, network::Packet)
	}

	void on_start()
	{
	}

	void send_update(int peer)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((int32_t)peer);
			ar(m_players);
			ar(m_playfield);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "demo_board_game:update", os.str());
		});
	}

	void create_new_player(int peer)
	{
		m_players[peer] = Player(peer, rand() % 10, rand() % 10);

		for(auto &pair : m_players)
			send_update(pair.second.peer);
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
		log_v(MODULE, "demo_board_game::on_client_connected: id=%zu",
				client_connected.info.id);

		int peer = client_connected.info.id;

		create_new_player(peer);
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		log_v(MODULE, "demo_board_game::on_client_disconnected: id=%zu",
				old_client.info.id);

		int peer = old_client.info.id;

		m_players.erase(peer);

		for(auto &pair : m_players)
			send_update(pair.second.peer);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		log_v(MODULE, "on_files_transmitted(): recipient=%zu", event.recipient);


		send_update(event.recipient);
	}

	void on_packet_move(const network::Packet &packet)
	{
		log_i(MODULE, "demo_board_game::on_packet_move: name=%zu, size=%zu",
				cs(packet.name), packet.data.size());
		auto it = m_players.find(packet.sender);
		if(it == m_players.end()){
			// This can occur when this module has been reloaded
			// TODO: Should store and restore by using m_server->tmp_store_data()
			log_w(MODULE, "Player not found: %i; creating new", packet.sender);
			create_new_player(packet.sender);
			return;
		}
		Player &player = it->second;
		if(packet.data == "up")
			player.x -= 1;
		if(packet.data == "down")
			player.x += 1;
		if(packet.data == "left")
			player.y -= 1;
		if(packet.data == "right")
			player.y += 1;
		if(packet.data == "place"){
			m_playfield.set(player.x, player.y,
					m_playfield.get(player.x, player.y) + 1);
		}

		for(auto &pair : m_players)
			send_update(pair.second.peer);
	}

	void on_packet_clear_field(const network::Packet &packet)
	{
		log_i(MODULE, "demo_board_game::on_packet_clear_field: name=%zu, size=%zu",
				cs(packet.name), packet.data.size());

		for(size_t y = 0; y < m_playfield.h; y++)
		for(size_t x = 0; x < m_playfield.w; x++)
			m_playfield.set(x, y, 0);

		for(auto &pair : m_players)
			send_update(pair.second.peer);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
