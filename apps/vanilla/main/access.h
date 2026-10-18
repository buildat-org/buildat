// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [VANILLA_MODULAR] **Who may do what** ([VANILLA_PUBLIC]): the launcher's
// owner on its own server, an admin on a public one, and what a public
// server's users are not told (where()).
// Included by main.cpp inside namespace vanilla, after common.h
#pragma once

struct Access
{
	// The Module's: whether this is a public server, and who has
	// joined by their account's name
	interface::Server *m_server;
	bool &m_public;
	std::map<network::PeerInfo::Id, ss_> &m_names;

	Access(interface::Server *server, bool &public_,
			std::map<network::PeerInfo::Id, ss_> &names):
		m_server(server), m_public(public_), m_names(names)
	{}

	bool is_admin(network::PeerInfo::Id peer)
	{
		auto it = m_names.find(peer);
		if(it == m_names.end())
			return false;
		bool admin = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			admin = i->is_admin(it->second);
		});
		return admin;
	}

	// What the world menu may do: anything on the launcher's server, and an
	// admin's on a public one
	bool may_manage(network::PeerInfo::Id peer)
	{
		if(m_public ? is_admin(peer) : is_owner(m_server, peer))
			return true;
		menu_error(m_server, peer,
				"Only an admin manages this server's worlds");
		return false;
	}

	// The launcher's server's alone: the server's own disk and settings
	bool local_only(network::PeerInfo::Id peer)
	{
		if(!m_public && is_owner(m_server, peer))
			return true;
		menu_error(m_server, peer, m_public ? "Not on a public server" :
				"Only the player who started this game");
		return false;
	}

	// A path on the server, as a message says it: the launcher's own user
	// may be told where, and a public server's users are not
	ss_ where(const ss_ &path)
	{
		return m_public ? ss_("(on the server)") : path;
	}
};
// vim: set noet ts=4 sw=4:
