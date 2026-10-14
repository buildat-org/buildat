// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// [LUANTI_APP_GLUE] The player session: what a client's player does,
// from the app's join_player() to its leave. The input packets are
// luanti:* and handled here, each a decode and a call into the game, so
// an app that runs a game has a playable one without forwarding them.
// Included by luanti.cpp inside struct Module. (Were apps/vanilla's main:*
// handlers.)

	// Joined by the app, placed and loading, by the seconds waited; and in
	// the world, which the client's luanti:world_in or WORLD_IN_LIMIT does
	// ([JOIN_WHEN_LOADED])
	sm_<network::PeerInfo::Id, float> m_loading;
	std::set<network::PeerInfo::Id> m_in_world;
	// Whether the app said the player is an admin, applied once in
	std::set<network::PeerInfo::Id> m_join_admin;
	// Past the loading screen's own 60 s after the first chunk, which a
	// slow link reaches only after the scene's megabytes
	static constexpr float WORLD_IN_LIMIT = 180;
	// Lines a player may chat at once, then one a second; 0 is no limit
	// (set_chat_limit)
	double m_chat_burst = 0;
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

	void session_init()
	{
		for(const char *n : {"where", "fell", "chat", "wield", "drop", "dig",
				"dig_start", "punch_object", "place", "use", "world_in"})
			m_server->sub_event(this, Event::t(
					ss_("network:packet_received/luanti:")+n));
	}

	void join_player(const ss_ &name, size_t peer, bool admin)
	{
		place_player(name, peer);
		m_loading[peer] = 0;
		if(admin)
			m_join_admin.insert(peer);
	}

	bool player_in_world(size_t peer)
	{
		return m_in_world.count(peer) != 0;
	}

	void set_chat_limit(double burst)
	{
		m_chat_burst = burst;
	}

	void session_left(network::PeerInfo::Id peer)
	{
		const bool had = m_loading.count(peer) || m_in_world.count(peer);
		m_loading.erase(peer);
		m_in_world.erase(peer);
		m_join_admin.erase(peer);
		m_pending_where.erase(peer);
		m_where_age.erase(peer);
		m_chat_bucket.erase(peer);
		auto it = m_peer_players.find(peer);
		// A copy: remove_player() erases what it refers to
		const ss_ name = it == m_peer_players.end() ? ss_() : it->second;
		if(had && !name.empty())
			remove_player(name);
	}

	// A joined player's name, or "" for a peer whose packets are nobody's
	ss_ in_world_name(network::PeerInfo::Id peer)
	{
		if(!m_in_world.count(peer))
			return "";
		auto it = m_peer_players.find(peer);
		return it == m_peer_players.end() ? ss_() : it->second;
	}

	// The client's loading screen has ended: the player goes in, seen and
	// hit and their game's join callbacks run
	void on_world_in(const network::Packet &packet)
	{
		if(!m_loading.count(packet.sender))
			return;
		log_i(MODULE, "Client %u: luanti:world_in", (unsigned)packet.sender);
		put_in_world(packet.sender);
	}

	void put_in_world(network::PeerInfo::Id peer)
	{
		m_loading.erase(peer);
		auto it = m_peer_players.find(peer);
		if(it == m_peer_players.end())
			return;
		m_in_world.insert(peer);
		const ss_ name = it->second;
		add_player(name, peer);
		if(m_join_admin.count(peer))
			set_admin(name, true);
	}

	// The loading limit and the positions, from on_tick: one visit to the
	// game for every player who has moved since the last one, at the rate
	// a client sends at rather than the server's thirty a second
	void session_tick(float dtime)
	{
		for(auto it = m_loading.begin(); it != m_loading.end();){
			const network::PeerInfo::Id peer = it->first;
			it->second += dtime;
			++it;
			if(m_loading[peer] >= WORLD_IN_LIMIT){
				log_i(MODULE, "Client %u: no luanti:world_in in %.0f s; put in",
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
			auto it = m_peer_players.find(pair.first);
			if(it == m_peer_players.end())
				continue;
			const Where &w = pair.second;
			set_player_pos(it->second, (float)w.x, (float)w.y, (float)w.z,
					(float)w.look_h, (float)w.look_v, w.controls);
		}
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
			log_w(MODULE, "luanti:where: %s", e.what());
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
				log_i(MODULE, "where: the worst wait behind the wire in "
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
			log_w(MODULE, "luanti:%s: %s", what, e.what());
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
			log_w(MODULE, "luanti:fell: %s", e.what());
			return;
		}
		if(!(speed > 14.0))
			return;
		player_fell(name, (float)std::min(speed, 200.0));
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
				chat_send(name, "Too many lines: wait a moment");
				return;
			}
			b.first += 1;
		}
		chat_message(name, values[0]);
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
			set_wield_index(name, index);
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
		const bool dropped = drop_wielded(name, count < 0 ? 0 : count);
		log_v(MODULE, "C%u: luanti:drop %i: %s", (unsigned)packet.sender,
				count, dropped ? "dropped" : "nothing");
	}

	// A voxel position packet, or false with a warning
	static bool decode_voxel(const network::Packet &packet, const char *what,
			pv::Vector3DInt32 &p)
	{
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(p);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:%s: %s", what, e.what());
			return false;
		}
		return true;
	}

	// The dig, timed on the client (core.__dig_props()) and sent when it is
	// done: core.dig_node() hands the node to the vendored builtin, which
	// is where can_dig, the drops and every callback around a dig live
	void on_dig(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		pv::Vector3DInt32 p;
		if(name.empty() || !decode_voxel(packet, "dig", p))
			return;
		const bool dug = dig_node(p.getX(), p.getY(), p.getZ(), name);
		log_v(MODULE, "C%u: luanti:dig (%i, %i, %i): %s",
				(unsigned)packet.sender, p.getX(), p.getY(), p.getZ(),
				dug ? "dug" : "nothing");
	}

	// The button going down, where a held dig starts: the node is punched,
	// so a mod's on_punch runs on the way in
	void on_dig_start(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		pv::Vector3DInt32 p;
		if(name.empty() || !decode_voxel(packet, "dig_start", p))
			return;
		punch_node(p.getX(), p.getY(), p.getZ(), name);
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
		const bool punched = punch_object(id, name);
		log_v(MODULE, "C%u: luanti:punch_object %i: %s",
				(unsigned)packet.sender, id, punched ? "punched" : "nothing");
	}

	// The other button: the pointed node's on_rightclick if it has one and
	// the wielded item's on_place otherwise (place_node()). under is the
	// node pointed at and above the empty voxel in front of it; sneak is
	// whether the "build against this" key was held.
	void on_place(const network::Packet &packet)
	{
		const ss_ name = in_world_name(packet.sender);
		if(name.empty())
			return;
		pv::Vector3DInt32 under, above;
		uint8_t sneak = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(under, above, sneak);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:place: %s", e.what());
			return;
		}
		const bool placed = place_node(under.getX(), under.getY(),
				under.getZ(), above.getX(), above.getY(), above.getZ(), name,
				sneak != 0);
		log_v(MODULE, "C%u: luanti:place (%i, %i, %i): %s",
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
		const bool used = use_wielded(name);
		log_v(MODULE, "C%u: luanti:use: %s", (unsigned)packet.sender,
				used ? "used" : "nothing");
	}

// vim: set noet ts=4 sw=4:
