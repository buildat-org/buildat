// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

// **Starport ID logins** ([STARPORT] 10c): a Starport signs a token for this
// server's listing with the listing's secret, which only this module holds;
// builtin/accounts asks it whether a token is good.
namespace starport_announce
{
	struct IdLogin
	{
		ss_ sub;      // the ID's identity in this server's fleet
		ss_ name;     // the name the player picked for the fleet
		ss_ starport; // the Starport's host
		bool adult = false; // "18 or over", told only to an adult listing
		// [FLEET_SUB_CARRY]: the server moved fleets; the ID's identity
		// in the scope before, and where it was and is now, for the player
		ss_ prev_sub;
		ss_ moved_from;
		ss_ moved_to;
	};

	struct Interface
	{
		// Whether starport.json lets Starport IDs in (10g: "ids" is off,
		// anyone or approved; Starport off is off)
		virtual bool accepts_ids() = 0;
		virtual ss_ ids_mode() = 0;
		// The Starports this server announces to, as URLs; none while
		// announcing is off ([HEARTH_VISITOR_FLOW]: Hearth reads their
		// lists)
		virtual sv_<ss_> starports() = 0;
		// The Luanti game the server's world is, as its installer named
		// where it came from ("contentdb:author/name"; "" for none): a
		// Hearth's thread about the game links the servers running it
		virtual void set_game(const ss_ &source) = 0;
		// Writes "ids" into starport.json; what it did ("" for nothing to
		// tell), else why not. IDs on with no Starport named adds the
		// default one, unlisted, and `address` (the admin's, or "") as
		// the public address if the file has none ([STARPORT_DEFAULT_URL])
		virtual ss_ set_ids_mode(const ss_ &mode, const ss_ &address) = 0;
		// 10g: whether a blocklist this server follows bans the identity
		// `sub` of the Starport at `host`
		virtual bool is_blocked(const ss_ &host, const ss_ &sub) = 0;
		// 10g: something the listing is derived from changed (who may make
		// an account): announce now rather than at the next interval
		virtual void announce_soon() = 0;
		// "" when the token is good, else why not
		virtual ss_ verify_id_token(const ss_ &token, IdLogin *out) = 0;
	};

	// False, and cb not called, where the app does not have the module:
	// builtin/accounts asks on every server, Starport's own among them
	inline bool access(interface::Server *server,
			std::function<void(starport_announce::Interface*)> cb)
	{
		return server->access_module_optional("starport_announce",
				[&](interface::Module *module){
			cb((starport_announce::Interface*)module->check_interface());
		});
	}
}
// vim: set noet ts=4 sw=4:
