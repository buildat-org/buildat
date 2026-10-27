// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// The join's packets, as builtin/accounts/client_lua/accounts.lua has them:
// shared by accounts.cpp and the web server's stand-in, accounts_web.cpp
#pragma once
#include "core/types.h"
#include <cereal/types/string.hpp>
#include <cctype>

namespace accounts {

// Luanti's rule for a player name, which every game here keeps
inline bool valid_name(const ss_ &name)
{
	if(name.empty() || name.size() > 20)
		return false;
	for(char c : name)
		if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
			return false;
	return true;
}

struct Hello
{
	uint8_t local = 0;      // no password asked
	// The join asks for the setup code (the server has no admin), or says
	// a new name needs an invite (registration is not open)
	uint8_t setup = 0;
	uint8_t open_registration = 0;
	// [STARPORT] 10c: a Starport ID logs in here
	uint8_t starport = 0;
	// [SERVER_ADMIN_PAGE]: the server has starport_announce, so an admin's
	// Server window has its Starport panels (never on a Starport)
	uint8_t announce = 0;
	// [SERVER_VERSION]: "0.6.75-ea7eb9e33", for the Server window
	ss_ version;
	// [HC_GUEST_PLAY] the app lets a peer in as a guest (set_guests)
	uint8_t guests = 0;
	template<class Archive>
	void serialize(Archive &archive){
		archive(local, setup, open_registration, starport, announce, version,
				guests);
	}
};

struct LoginRequest
{
	ss_ name;
	ss_ password;
	ss_ code; // the setup code, or an invite code
	// [ACC_KEEP]: a token from a login that asked to be kept, in place of
	// the password; and whether this login asks for one
	ss_ token;
	uint8_t keep = 0;
	// [STARPORT] 10: the TOTP code, and a Starport ID's token for this
	// server in place of a name and a password
	ss_ totp;
	ss_ starport;
	// [ACCOUNT_CREATE]: this login is allowed to make the account if the name
	// does not exist; a plain login (0) refuses an unknown name instead
	uint8_t create = 0;
	// [FLEET_SUB_CARRY] (version 2): the player's answer to "keep your
	// account from before the server's move?": 0 not asked, 1 yes, 2 no
	uint8_t carry = 0;
	template<class Archive>
	void serialize(Archive &archive){
		// A leading version byte: add version-gated fields below it rather
		// than breaking the wire format again (voxel_cereal.h pattern)
		uint8_t version = 2;
		archive(version);
		archive(name, password, code, token, keep, totp, starport, create);
		if(version >= 2)
			archive(carry);
	}
};

}
// vim: set noet ts=4 sw=4:
