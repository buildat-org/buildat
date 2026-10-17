// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

// **A shared chat** ([SKELDAT] stage 5): one chat for the players an app
// puts in it, with the trust ladder's say in it (builtin/accounts):
// - who may talk: a moderator sets the lowest level that may (everyone,
//   member, helper), for the whole server; helpers and up always can;
// - a moderator mutes a player below them, and unmutes;
// - a player reports another, the chat's last lines with it, into
//   builtin/moderation's queue, which the moderators decide from the
//   chat's menu: mute, or dismiss.
// Its state is in the server's save "_chat". The client half is
// client_lua/module.lua (require("buildat/module/chat")), which hooks
// builtin/accounts' chat console and has the menu.
//
// Packets, client to server: chat:say (text), chat:get, chat:set_min
// (everyone|member|helper), chat:mute and chat:unmute (name), chat:report
// (name), chat:queue, chat:decide ({group, decision: mute|dismiss}).
// Server to client: chat:line (text), chat:state (JSON: {min, may_talk,
// muted, moderator, people: [{name, muted}]}), chat:queue (JSON: the open
// groups, each with its reports' texts).
namespace chat
{
	struct Interface
	{
		// The app's players in the chat: a peer that has joined its world,
		// under the app's name for it (an account's name, or one the app
		// gives a player without; the level is the peer's account's, none
		// for one without).
		// One that disconnects is out.
		// simplified: a mute of a name without an account outlives the
		// player and falls on the next to get the name
		virtual void join(size_t peer, const ss_ &name) = 0;
		virtual void leave(size_t peer) = 0;
		// A line of the server's own to everyone in
		virtual void say(const ss_ &line) = 0;
		// [VANILLA_CHAT_MIN] The lowest level that may talk while the save
		// has none a moderator set (everyone|member|helper; everyone if no
		// app says)
		virtual void set_default_min(const ss_ &min) = 0;
		// Whether a peer may say a line as `name` (chat:state's may_talk:
		// the level, a mute); if not, *why is what to tell the player
		virtual bool may_talk(size_t peer, const ss_ &name, ss_ *why) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(chat::Interface*)> cb)
	{
		return server->access_module("chat", [&](interface::Module *module){
			cb((chat::Interface*)module->check_interface());
		});
	}
}
// vim: set noet ts=4 sw=4:
