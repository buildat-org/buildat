// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "network/api.h"
#include <functional>
#include <map>

// **The server's accounts** ([VANILLA_PUBLIC] 2, from the floorplanner's
// [FP_ACCESS]): who may join and as whom, and who is an admin, for every
// game on the server. A client joins through this module before its game
// lets it in:
// - The accounts are in the server's own save, "_server" (a game leaves
//   saves beginning with _ out of its lists), store "accounts".
// - A password is PBKDF2-HMAC-SHA256 with a salt of its own; the
//   account record names the derivation and its iteration count.
// - A server with no admin prints a setup code; the first to join with it
//   is the admin. A new account needs an invite from an admin, unless
//   registration is open, which it is by default only on a server the
//   launcher started. Open registration takes at most 5 untrusted
//   accounts made in 30 days from one network (below LV_MEMBER).
// - The launcher's own user of a server it started (launch parameter
//   launcher=1, from 127.0.0.1 or ::1) joins by name alone, and is the
//   first admin.
// - Failed logins wait, doubling, per address's network; every login is
//   logged. A kept login lasts 90 days from its last use.
// - An admin kicks, bans and unbans, and manages the accounts and invites;
//   a moderator (LV_MODERATOR) does the same in the Server window's
//   Accounts page, beside deleting an account, resetting a password,
//   adding one and the settings.
//
// The client's side is builtin/accounts/client_lua/accounts.lua: the join
// dialog, and the calls a game's admin pages make.
namespace accounts
{
	typedef network::PeerInfo::Id PeerId;

	// accounts:login: a peer has joined as `name`. accounts:privs: a user's
	// admin changed; their game says so to their client. A peer leaves as
	// network:client_disconnected says. accounts:deleted: the account
	// `name` is gone (peer 0), and an app drops what was the account's
	// ([FP_ABUSE] 4).
	struct Login: public interface::Event::Private
	{
		PeerId peer = 0;
		ss_ name;
		Login(PeerId peer, const ss_ &name): peer(peer), name(name){}
	};

	// [TRUST_LADDER] The trust levels. Numbers with room between them for
	// more; their names are only shown, from level_name() and accounts.lua's
	// LEVEL_NAMES, which are changed together.
	static const int LV_NEW = 0, LV_MEMBER = 10, LV_HELPER = 20,
			LV_MODERATOR = 30, LV_ADMIN = 40;
	inline ss_ level_name(int lv)
	{
		return lv >= LV_ADMIN ? "Host" : lv >= LV_MODERATOR ? "Steward" :
				lv >= LV_HELPER ? "Keeper" : lv >= LV_MEMBER ? "Resident" :
				"Guest";
	}

	struct Interface
	{
		// The name a peer joined as, or "" before it has
		virtual ss_ name_of(PeerId peer) = 0;
		// The peer that has joined as `name`, or 0; the first, where the app
		// lets a name be here more than once
		virtual PeerId find_peer(const ss_ &name) = 0;
		// [FP_TWO_CLIENTS]: every peer joined as `name`
		virtual sv_<PeerId> find_peers(const ss_ &name) = 0;
		// Whether one name may be here from more than one client at once
		// (floorplanner: an editing client and a viewing one); off by
		// default, as for a Luanti player, who is one object per name. A
		// kick, a ban, a reset password and a deleted account then reach
		// every connection of the name.
		virtual void set_multiple_logins(bool on) = 0;
		// [HC_GUEST_PLAY] Whether a peer may join as a guest: no account,
		// "guest<n>" (the next free number this run), trust level LV_NEW,
		// the same accounts:login; the login window offers it. Off by
		// default
		virtual void set_guests(bool on) = 0;
		// Its address, as the network module has it (a trusted proxy's
		// X-Forwarded-For included)
		virtual ss_ address_of(PeerId peer) = 0;
		virtual bool is_admin(const ss_ &name) = 0;
		virtual bool exists(const ss_ &name) = 0;
		// Whether `token` is a kept login of `name` that stands
		// ([ACC_KEEP]): what the client holds for this server, for a
		// request that is not a join ([FORUM]'s notifications)
		virtual bool check_kept(const ss_ &name, const ss_ &token) = 0;
		virtual sv_<ss_> account_names() = 0;
		// The launcher's own user of a server it started
		virtual bool is_local(PeerId peer) = 0;
		// Whether the launcher started this server
		virtual bool launched() = 0;
		// [ACCOUNTS_LAN] the name the server is announced under once its
		// owner opens it to the LAN (the app id unless set), and whether
		// joining it needs an account; announced again if open already
		virtual void set_lan_name(const ss_ &name, bool account) = 0;
		// Off the server, told why
		virtual void kick(PeerId peer, const ss_ &why) = 0;
		// A ban by name, and by the address the name last joined from while
		// registration is open; until a time (wall_us() seconds; 0: until
		// lifted), when it lifts itself, and why, both said at a refused
		// join ([HEARTH_MOD_TOOLS]).
		// "" when done, else why not.
		virtual ss_ ban(const ss_ &name, const ss_ &by, int64_t until = 0,
				const ss_ &reason = "") = 0;
		// A name or an address; "" when done, else why not. With only_by,
		// only a ban that one made: a game's /unban lifts the game's bans
		// and not an admin's
		virtual ss_ unban(const ss_ &name_or_address,
				const ss_ &only_by = "") = 0;
		// "name|address" per ban, as Luanti's get_ban_list says them
		virtual sv_<ss_> ban_list() = 0;

		// [STARPORT] 10: a Starport ID is an account of the Starport's own
		// server, made and checked over its HTTP API. "" when done, else
		// why not.
		virtual ss_ create_account(const ss_ &name, const ss_ &password) = 0;
		virtual bool check_password(const ss_ &name, const ss_ &password) = 0;
		virtual ss_ set_password(const ss_ &name, const ss_ &password) = 0;
		virtual ss_ delete_account(const ss_ &name) = 0;
		// TOTP (RFC 6238), for any account: whether it is on; a code, good
		// once; a new secret (base32), pending until confirmed by a code;
		// off by a code
		virtual bool totp_on(const ss_ &name) = 0;
		virtual bool check_totp(const ss_ &name, const ss_ &code) = 0;
		virtual ss_ totp_begin(const ss_ &name) = 0;
		virtual ss_ totp_confirm(const ss_ &name, const ss_ &code) = 0;
		virtual ss_ totp_off(const ss_ &name, const ss_ &code) = 0;
		virtual ss_ totp_uri(const ss_ &name, const ss_ &secret_base32) = 0;
		// 10d: the bans reported to Starports, "host|sub|reason" each: the
		// Starport ID accounts banned with "Report to Starport", for
		// starport_announce to send. A ban gone is gone from this too.
		virtual sv_<ss_> reported_bans() = 0;
		// 10g: whether anyone may make a local account (else invites only),
		// which a listing's access is derived from
		virtual bool registration_open() = 0;
		// 10g: how many accounts are linked to IDs of the Starport at host
		virtual size_t linked_count(const ss_ &host) = 0;
		// [SERVER_ADMIN_PAGE] **The server's mail**: the admin's SMTP
		// setting, one for the server (user, 2026-10-07), set on the Server
		// window's Health page. Whether it is set and libcurl speaks SMTP
		virtual bool can_mail() = 0;
		// A mail to `to` -- one address, which the caller checked has
		// nothing in it that ends a header line -- on a thread of its own.
		// done(error), "" when the SMTP server took it, is called on that
		// thread, so it holds only copies.
		virtual void mail(const ss_ &to, const ss_ &subject, const ss_ &text,
				std::function<void(const ss_ &error)> done) = 0;
		// [TRUST_LADDER] An account's trust level, a number (LV_*): the
		// admin's is LV_ADMIN; the others' are saved, and go with the
		// account. LV_MEMBER and up is trusted, which frees its place in
		// open registration's quota of untrusted accounts per network.
		virtual int level(const ss_ &name) = 0;
		// "" when done, else why not. With `by`, as by does it: one sets only
		// below one's own level, and from LV_MODERATOR. LV_ADMIN is made in
		// the Server window only.
		virtual ss_ set_level(const ss_ &name, int lv, const ss_ &by = "") = 0;
		// [FP_ABUSE] 5: what an app keeps for each account, in bytes, the
		// whole of it each time (an account left out uses nothing); the
		// Server window's Accounts page shows the sum and each app's
		virtual void report_storage(const ss_ &app,
				const std::map<ss_, uint64_t> &bytes) = 0;
		// [FP_ABUSE] 3: the server-wide budget the admin sets in the
		// Server window, 2 GB unless set: past it an app takes no more from
		// an untrusted account (below LV_MEMBER)
		virtual uint64_t storage_budget() = 0;
		// [ADMIN_NOTIFY] A push to the ntfy address of each account at
		// min_level or above that set one: text as "Hearth: a new report,
		// 3 open", and a link to the page. At most one a person per 5
		// minutes, the rest counted into the next. No reporter, name or
		// message text in it: a topic is readable by whoever knows it.
		virtual void notify(int min_level, const ss_ &text,
				const ss_ &link = "") = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(accounts::Interface*)> cb)
	{
		return server->access_module("accounts", [&](interface::Module *module){
			cb((accounts::Interface*)module->check_interface());
		});
	}
	// An account's level (LV_*), LV_NEW without the accounts module; the
	// admin's is LV_ADMIN, so `level(...) >= LV_MODERATOR` is a Steward or
	// the Host
	inline int level(interface::Server *server, const ss_ &name)
	{
		int lv = LV_NEW;
		access(server, [&](Interface *a){ lv = a->level(name); });
		return lv;
	}
}

// vim: set noet ts=4 sw=4:
