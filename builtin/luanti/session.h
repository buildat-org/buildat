// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// [LUANTI_APP_GLUE] The player session: what a client's player does,
// from the app's join_player() to its leave. The input packets are
// luanti:* and handled here, each a decode and a call into the Game, so
// an app that runs a game has a playable one without forwarding them.
// (Were apps/vanilla's main:* handlers.) A plain header any module
// includes ([SKELDAT_LUANTI_PARTS] 8): builtin/luanti's Module is the Game
// that is Luanti's Lua, skeldat's its own C++ rules. The owner
// subscribes to PACKETS and hands those to packet(), calls tick() from its
// tick and left() at a disconnect. Logs as "luanti".
#pragma once
#include "core/types.h"
#include "network/api.h"
#include "interface/os.h"
#include "interface/polyvox_cereal.h"
#include <cereal/archives/portable_binary.hpp>
#include <functional>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
#include <sstream>

namespace luanti_session
{

// What a session calls on, by the player's name. A player is placed at
// the join and in the world once its client has it loaded.
struct Game
{
	virtual ~Game(){}
	virtual void place_player(const ss_ &name, size_t peer) = 0;
	virtual void add_player(const ss_ &name, size_t peer) = 0;
	virtual void remove_player(const ss_ &name) = 0;
	virtual void set_admin(const ss_ &name, bool admin) = 0;
	// Off the network: the Game bounds them
	virtual void set_player_pos(const ss_ &name, float x, float y, float z,
			float look_h, float look_v, int32_t controls) = 0;
	virtual void player_fell(const ss_ &name, float speed) = 0;
	virtual void chat_message(const ss_ &name, const ss_ &message) = 0;
	// To one player; "" is everyone
	virtual void chat_send(const ss_ &to, const ss_ &text) = 0;
	// One-based
	virtual void set_wield_index(const ss_ &name, int index) = 0;
	virtual bool drop_wielded(const ss_ &name, int count) = 0;
	virtual bool dig_node(int32_t x, int32_t y, int32_t z,
			const ss_ &name) = 0;
	virtual bool punch_node(int32_t x, int32_t y, int32_t z,
			const ss_ &name) = 0;
	virtual bool punch_object(int32_t id, const ss_ &name) = 0;
	virtual bool place_node(int32_t under_x, int32_t under_y,
			int32_t under_z, int32_t above_x, int32_t above_y,
			int32_t above_z, const ss_ &name, bool sneak) = 0;
	virtual bool use_wielded(const ss_ &name) = 0;
};

// The packets a session takes, after "luanti:"
static const char *const PACKETS[] = {"where", "fell", "chat", "wield",
		"drop", "dig", "dig_start", "punch_object", "place", "use",
		"world_in"};

struct Session
{
	Game &m_game;
	Session(Game &game): m_game(game){}

	// Joined by the app, placed and loading, by the seconds waited; and in
	// the world, which the client's luanti:world_in or WORLD_IN_LIMIT does
	// ([JOIN_WHEN_LOADED])
	sm_<network::PeerInfo::Id, float> m_loading;
	std::set<network::PeerInfo::Id> m_in_world;
	sm_<network::PeerInfo::Id, ss_> m_names;
	// Whether the app said the player is an admin, applied once in
	std::set<network::PeerInfo::Id> m_join_admin;
	// Past the loading screen's own 60 s after the first chunk, which a
	// slow link reaches only after the scene's megabytes
	static constexpr float WORLD_IN_LIMIT = 180;
	// Lines a player may chat at once, then one a second; 0 is no limit
	// (set_chat_limit)
	double m_chat_burst = 0;
	// [VANILLA_CHAT_MIN] Who may say a plain line: "" for yes, else what
	// the player is told (set_chat_gate); a "/" command runs either way
	std::function<ss_(size_t peer, const ss_ &name)> m_chat_gate;
	sm_<network::PeerInfo::Id, std::pair<double, int64_t>> m_chat_bucket;

	// Where a client says its player is, five times a second each, and
	// what it holds down, in Luanti's own bit order (CONTROL_BITS in
	// lua/entity.lua). Kept rather than applied: each one into the game
	// is a wait on the Lua -- a fifth of a second in a game the size of
	// VoxeLibre, three seconds at its worst -- and a click behind that
	// backlog took twelve seconds to arrive when this was measured. Only
	// the newest matters anyway: a position is a heartbeat, like the tick
	// src/server/state.cpp coalesces for the same reason.
	struct Where {
		double x = 0, y = 0, z = 0, look_h = 0, look_v = 0;
		int32_t controls = 0;
		double sent_us = 0; // the client's clock, microseconds (cereal's
		                    // Lua side has doubles, not int64)
	};
	sm_<network::PeerInfo::Id, Where> m_pending_where;
	// How long a position update waited on the wire ([NET_SIM]): the
	// client's clock is not the server's, so the age is the excess over
	// the smallest (received - sent) seen from that peer -- the fastest
	// update sets the baseline, a lossy link shows as the rest lagging
	// it. The worst per five seconds is logged.
	struct WhereAge {
		int64_t base_us = 0; // the smallest received - sent, or 0
		int64_t worst_us = 0;
		int64_t window_from_us = 0;
	};
	sm_<network::PeerInfo::Id, WhereAge> m_where_age;
	float m_where_timer = 0.0f;

	void join(const ss_ &name, size_t peer, bool admin)
	{
		// A name back on a new peer before its old peer's leave was taken
		// (the module busy in a long tick): that leave first, or it would
		// come after and remove the new player by its name
		for(auto &it : m_names){
			if(it.second == name && it.first != peer){
				left(it.first);
				break;
			}
		}
		m_names[peer] = name;
		m_game.place_player(name, peer);
		m_loading[peer] = 0;
		if(admin)
			m_join_admin.insert(peer);
	}

	bool in_world(size_t peer)
	{
		return m_in_world.count(peer) != 0;
	}

	void set_chat_limit(double burst)
	{
		m_chat_burst = burst;
	}

	void set_chat_gate(std::function<ss_(size_t peer, const ss_ &name)> gate)
	{
		m_chat_gate = gate;
	}

	void left(network::PeerInfo::Id peer)
	{
		const bool had = m_loading.count(peer) || m_in_world.count(peer);
		m_loading.erase(peer);
		m_in_world.erase(peer);
		m_join_admin.erase(peer);
		m_pending_where.erase(peer);
		m_where_age.erase(peer);
		m_chat_bucket.erase(peer);
		auto it = m_names.find(peer);
		if(it == m_names.end())
			return;
		const ss_ name = it->second;
		m_names.erase(it);
		if(had)
			m_game.remove_player(name);
	}

	// A joined player's name, or "" for a peer whose packets are nobody's
	ss_ in_world_name(network::PeerInfo::Id peer)
	{
		if(!m_in_world.count(peer))
			return "";
		auto it = m_names.find(peer);
		return it == m_names.end() ? ss_() : it->second;
	}

	// A luanti:* packet of PACKETS; false for any other
	bool packet(const network::Packet &packet)
	{
		if(packet.name.compare(0, 7, "luanti:") != 0)
			return false;
		const ss_ n = packet.name.substr(7);
		if(n == "where") on_where(packet);
		else if(n == "fell") on_fell(packet);
		else if(n == "chat") on_chat(packet);
		else if(n == "wield") on_wield(packet);
		else if(n == "drop") on_drop(packet);
		else if(n == "dig") on_dig(packet);
		else if(n == "dig_start") on_dig_start(packet);
		else if(n == "punch_object") on_punch_object(packet);
		else if(n == "place") on_place(packet);
		else if(n == "use") on_use(packet);
		else if(n == "world_in") on_world_in(packet);
		else return false;
		return true;
	}

	// The client's loading screen has ended: the player goes in, seen and
	// hit and their game's join callbacks run
	void on_world_in(const network::Packet &packet)
	{
		if(!m_loading.count(packet.sender))
			return;
		log_i("luanti", "Client %u: luanti:world_in", (unsigned)packet.sender);
		put_in_world(packet.sender);
	}

	void put_in_world(network::PeerInfo::Id peer)
	{
		m_loading.erase(peer);
		auto it = m_names.find(peer);
		if(it == m_names.end())
			return;
		m_in_world.insert(peer);
		const ss_ name = it->second;
		m_game.add_player(name, peer);
		if(m_join_admin.count(peer))
			m_game.set_admin(name, true);
	}

	// The loading limit and the positions, from the owner's tick: one
	// visit to the game for every player who has moved since the last
	// one, at the rate a client sends at rather than the server's thirty
	// a second
	void tick(float dtime)
	{
		for(auto it = m_loading.begin(); it != m_loading.end();){
			const network::PeerInfo::Id peer = it->first;
			it->second += dtime;
			++it;
			if(m_loading[peer] >= WORLD_IN_LIMIT){
				log_i("luanti", "Client %u: no luanti:world_in in %.0f s; put in",
						(unsigned)peer, (double)WORLD_IN_LIMIT);
				put_in_world(peer);
			}
		}
		m_where_timer += dtime;
		if(m_where_timer < 0.2f)
			return;
		m_where_timer = 0.0f;
		sm_<network::PeerInfo::Id, Where> pending;
		pending.swap(m_pending_where);
		for(const auto &pair : pending){
			auto it = m_names.find(pair.first);
			if(it == m_names.end())
				continue;
			const Where &w = pair.second;
			m_game.set_player_pos(it->second, (float)w.x, (float)w.y,
					(float)w.z, (float)w.look_h, (float)w.look_v, w.controls);
		}
	}

	// A peer's where that came since the last 0.2 s apply, applied now:
	// for a game that needs the place at once ([SKELDAT_BOW_AIM]: the
	// bow's release follows a where of its own)
	void apply_where(network::PeerInfo::Id peer)
	{
		auto p = m_pending_where.find(peer);
		auto it = m_names.find(peer);
		if(p == m_pending_where.end() || it == m_names.end())
			return;
		const Where w = p->second;
		m_pending_where.erase(p);
		m_game.set_player_pos(it->second, (float)w.x, (float)w.y,
				(float)w.z, (float)w.look_h, (float)w.look_v, w.controls);
	}

	void on_where(const network::Packet &packet)
	{
		// From the placement on, while loading too: it is what the world
		// loads round; nobody is moved who is not in it yet
		if(!m_in_world.count(packet.sender) && !m_loading.count(packet.sender))
			return;
		Where w;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(w.x, w.y, w.z, w.look_h, w.look_v, w.controls, w.sent_us);
		} catch(std::exception &e){
			log_w("luanti", "luanti:where: %s", e.what());
			return;
		}
		m_pending_where[packet.sender] = w;
		if(w.sent_us > 0){
			const int64_t now = interface::os::time_us();
			WhereAge &a = m_where_age[packet.sender];
			const int64_t d = now - (int64_t)w.sent_us;
			if(a.base_us == 0 || d < a.base_us)
				a.base_us = d;
			const int64_t age = d - a.base_us;
			if(age > a.worst_us)
				a.worst_us = age;
			if(a.window_from_us == 0)
				a.window_from_us = now;
			if(now - a.window_from_us >= 5000000){
				log_i("luanti", "where: the worst wait behind the wire in "
						"five seconds %d ms (client %u)",
						(int)(a.worst_us / 1000), (unsigned)packet.sender);
				a.worst_us = 0;
				a.window_from_us = now;
			}
		}
	}

	// A packet of strings, or false with a warning
	static bool decode_strings(const network::Packet &packet, const char *what,
			sv_<ss_> &values)
	{
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w("luanti", "luanti:%s: %s", what, e.what());
			return false;
		}
		return true;
	}

	// How hard a player landed, which only their own client knows -- the
	// physics is the client's. The number is a client's word, so it is
	// bounded: below Luanti's own tolerance it costs nothing, and nothing
	// beyond terminal velocity is believed. A client that lies about it can
	// hurt nobody but itself, which is what Luanti's own TOSERVER_DAMAGE is
	// worth as well.
	void on_fell(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		if(name.empty())
			return;
		double speed = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(speed);
		} catch(std::exception &e){
			log_w("luanti", "luanti:fell: %s", e.what());
			return;
		}
		if(!(speed > 14.0))
			return;
		m_game.player_fell(name, (float)std::min(speed, 200.0));
	}

	// A line a player typed: the callbacks run, the "/" commands among
	// them, and what nobody takes is said to everyone. With a limit
	// (set_chat_limit), a player's lines fill a bucket that empties one a
	// second, and a line into a full one is refused and the player told.
	void on_chat(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		sv_<ss_> values;
		if(name.empty() || !decode_strings(packet, "chat", values) ||
				values.empty() || values[0].empty())
			return;
		if(m_chat_burst > 0){
			const int64_t now = interface::os::time_us();
			auto &b = m_chat_bucket[packet.sender];
			b.first = std::max(0.0, b.first - (now - b.second) / 1e6);
			b.second = now;
			if(b.first + 1 > m_chat_burst){
				m_game.chat_send(name, "Too many lines: wait a moment");
				return;
			}
			b.first += 1;
		}
		// [SECURITY_RUN_7] A command is not chat, but /me and /msg are
		// simplified: a game's own commands that speak are not gated
		const ss_ &line = values[0];
		const bool speaks = line[0] != '/' || line == "/me" ||
				line.compare(0, 4, "/me ") == 0 || line.compare(0, 5, "/msg ") == 0;
		if(m_chat_gate && speaks){
			const ss_ why = m_chat_gate(packet.sender, name);
			if(!why.empty()){
				log_i("luanti", "%s's line refused: %s", cs(name), cs(why));
				m_game.chat_send(name, why);
				return;
			}
		}
		m_game.chat_message(name, values[0]);
	}

	// Which hotbar slot the player is holding: what the next dig or place
	// asks about
	void on_wield(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		sv_<ss_> values;
		if(name.empty() || !decode_strings(packet, "wield", values) ||
				values.empty())
			return;
		const int index = atoi(values[0].c_str());
		if(index >= 1 && index <= 32)
			m_game.set_wield_index(name, index);
	}

	// The drop key: how many of the held stack go, zero all of them, which
	// is what Luanti's Q and Ctrl-Q are
	void on_drop(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		sv_<ss_> values;
		if(name.empty() || !decode_strings(packet, "drop", values))
			return;
		const int count = values.empty() ? 0 : atoi(values[0].c_str());
		const bool dropped = m_game.drop_wielded(name, count < 0 ? 0 : count);
		log_v("luanti", "C%u: luanti:drop %i: %s", (unsigned)packet.sender,
				count, dropped ? "dropped" : "nothing");
	}

	// A voxel position packet, or false with a warning
	static bool decode_voxel(const network::Packet &packet, const char *what,
			PolyVox::Vector3DInt32 &p)
	{
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(p);
		} catch(std::exception &e){
			log_w("luanti", "luanti:%s: %s", what, e.what());
			return false;
		}
		return true;
	}

	// The dig, timed on the client and sent when it is done
	void on_dig(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		PolyVox::Vector3DInt32 p;
		if(name.empty() || !decode_voxel(packet, "dig", p))
			return;
		const bool dug = m_game.dig_node(p.getX(), p.getY(), p.getZ(), name);
		log_v("luanti", "C%u: luanti:dig (%i, %i, %i): %s",
				(unsigned)packet.sender, p.getX(), p.getY(), p.getZ(),
				dug ? "dug" : "nothing");
	}

	// The button going down, where a held dig starts: the node is punched
	void on_dig_start(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		PolyVox::Vector3DInt32 p;
		if(name.empty() || !decode_voxel(packet, "dig_start", p))
			return;
		m_game.punch_node(p.getX(), p.getY(), p.getZ(), name);
	}

	// The same button at an object: one punch per press, and no faster than
	// the client's own delay while it is held
	void on_punch_object(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		sv_<ss_> values;
		if(name.empty() || !decode_strings(packet, "punch_object", values) ||
				values.empty())
			return;
		const int32_t id = atoi(values[0].c_str());
		const bool punched = m_game.punch_object(id, name);
		log_v("luanti", "C%u: luanti:punch_object %i: %s",
				(unsigned)packet.sender, id, punched ? "punched" : "nothing");
	}

	// The other button: under is the node pointed at and above the empty
	// voxel in front of it; sneak is whether the "build against this" key
	// was held
	void on_place(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		if(name.empty())
			return;
		PolyVox::Vector3DInt32 under, above;
		uint8_t sneak = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(under, above, sneak);
		} catch(std::exception &e){
			log_w("luanti", "luanti:place: %s", e.what());
			return;
		}
		const bool placed = m_game.place_node(under.getX(), under.getY(),
				under.getZ(), above.getX(), above.getY(), above.getZ(), name,
				sneak != 0);
		log_v("luanti", "C%u: luanti:place (%i, %i, %i): %s",
				(unsigned)packet.sender, above.getX(), above.getY(),
				above.getZ(), placed ? "placed" : "nothing");
	}

	// The other button at nothing: the wielded item's secondary use, which
	// is how food is eaten ([TOUCH_EAT])
	void on_use(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		if(name.empty())
			return;
		const bool used = m_game.use_wielded(name);
		log_v("luanti", "C%u: luanti:use: %s", (unsigned)packet.sender,
				used ? "used" : "nothing");
	}
};

}

// vim: set noet ts=4 sw=4:
