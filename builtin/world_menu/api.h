// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>
#include <map>

// **A world menu** ([WORLD_MENU]): an app's worlds, its saves not beginning
// with _ (those are the server's own), listed newest first; a new one
// named and given the app's options, a rename, a delete, and a play. Only
// the launcher's own client picks (builtin/accounts' is_local); another
// is told to wait for the host. The client half is client_lua/module.lua,
// which the server opens on the client itself: an app has nothing of the
// menu in its own client.
//
// The app configures it once, calls show(peer) for a client that has no
// world to be in, and starts the world it is told of by world_menu:play
// (Play). It then calls set_running(true), which closes every menu shown;
// a world it cannot start is said by calling show(peer) again.
// A world's options are kept in its save, store "world_menu", key the
// option's.
// [SKELDAT_WORLD_ADMIN] While a world runs, show_running(peer, name)
// shows a picker the list with that world marked: Play on another is
// world_menu:play as before (the app switches), on the running one the
// menu closes; the running one is not renamed or deleted; Close world is
// world_menu:close (Close). Back closes the menu.
//
// Packets, client to server: world_menu:get, world_menu:play ({name}),
// world_menu:create ({name, options: {key: value}}), world_menu:rename
// ({name, to}), world_menu:delete ({name}), world_menu:close. Server to
// client: world_menu:list (JSON: {title, may_pick, wait, running, note,
// fields: [{key, label, default, hint, ask, choices: [[value, label]]}],
// worlds: [{name, bytes, options}], presets: [{label, options}]}; wait:
// the progress text, if any; running: the running world's name, if the
// menu is shown in it; note: a refusal to say), world_menu:up.
// **Presets** ([SKELDAT_HIGH_SCORES]): option sets the app offers on the
// new world screen, as "From the high scores"; picking one fills the
// fields. None, no list.
namespace world_menu
{
	typedef size_t PeerId;

	// An option of the app's on a world, asked for when one is made, or
	// (show_only) one the app writes itself and the menu only shows
	// simplified: set when the world is made and shown after, not edited;
	// an app that needs to change one adds an edit to the options screen
	struct Field
	{
		ss_ key, label, def;
		// Said beside the field where a new world is named
		ss_ hint;
		// Left out of a brace list, false (C++11: no initializer here)
		bool show_only;
		// One of these (value, label) picked, the first the default; empty,
		// typed text ([SKELDAT_WORLD_SIZES])
		std::vector<std::pair<ss_, ss_>> choices;
	};

	struct Config
	{
		ss_ title;
		std::vector<Field> fields;
	};
	struct Preset
	{
		ss_ label;
		std::map<ss_, ss_> options;
	};

	// world_menu:play: `peer` picked the world `name`, made by this pick
	// when `created`
	struct Play: public interface::Event::Private
	{
		PeerId peer;
		ss_ name;
		bool created;
		std::map<ss_, ss_> options;
		Play(PeerId peer, const ss_ &name, bool created,
				const std::map<ss_, ss_> &options):
			peer(peer), name(name), created(created), options(options){}
	};

	// world_menu:close: `peer` closed the running world
	struct Close: public interface::Event::Private
	{
		PeerId peer;
		Close(PeerId peer): peer(peer){}
	};

	struct Interface
	{
		virtual void configure(const Config &config) = 0;
		// The menu to a client with no world to be in
		virtual void show(PeerId peer) = 0;
		// A world starting or running: no more picks, and the menus shown
		// close
		virtual void set_running(bool running) = 0;
		// A world being made: the menus shown say `text` and wait, and no
		// world is picked meanwhile; "" for none. set_running(true) ends it.
		virtual void progress(const ss_ &text) = 0;
		// The new world screen's presets, sent again to the menus shown
		virtual void set_presets(const std::vector<Preset> &presets) = 0;
		// The menu to a picker while the world `running` runs
		virtual void show_running(PeerId peer, const ss_ &running) = 0;
		// Whether the peer picks the worlds: the launcher's own client, or
		// an admin's account
		virtual bool is_picker(PeerId peer) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(world_menu::Interface*)> cb)
	{
		return server->access_module("world_menu",
				[&](interface::Module *module){
			cb((world_menu::Interface*)module->check_interface());
		});
	}
}
// vim: set noet ts=4 sw=4:
