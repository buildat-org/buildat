// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>
#include <fstream>

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}

namespace storage
{
	struct Save;
}

namespace luanti
{
	using main_context::SceneReference;

	// A Luanti .conf file's "key = value" lines (world.mt, game.conf,
	// map_meta.txt), in the file's order: each side trimmed of whitespace
	// as Luanti's Settings::parseConfigLine does, "#" comments and lines
	// with no "=" skipped; none for a missing file. One reader for vanilla
	// and the import ([REWORK_1019_FIXES] luanti 9).
	// simplified: no multi-line """ values, which no file read here has
	inline sv_<std::pair<ss_, ss_>> read_conf(const ss_ &path)
	{
		sv_<std::pair<ss_, ss_>> out;
		std::ifstream f(path);
		ss_ line;
		auto trim = [](const ss_ &s){
			size_t a = 0, b = s.size();
			while(a < b && isspace((unsigned char)s[a])) a++;
			while(b > a && isspace((unsigned char)s[b - 1])) b--;
			return s.substr(a, b - a);
		};
		while(std::getline(f, line)){
			const ss_ t = trim(line);
			const size_t eq = t.find('=');
			if(t.empty() || t[0] == '#' || eq == ss_::npos)
				continue;
			const ss_ k = trim(t.substr(0, eq));
			if(!k.empty())
				out.emplace_back(k, trim(t.substr(eq + 1)));
		}
		return out;
	}

	// The game's mods have loaded, the voxel registry is built and the map
	// exists. The scene is the module's own: it is what knows the world's
	// node ids and its light, so it is what owns them, and this is how
	// whoever started the game finds out where to put its peers.
	struct GameLoaded: public interface::Event::Private
	{
		SceneReference scene;

		GameLoaded(SceneReference scene): scene(scene){}
	};

	// [LUANTI_APP_GLUE] core.buildat_emit(name, value) in the game's Lua:
	// the event "luanti:app:<name>", the value as JSON. How an app's own
	// Lua (load_lua()) tells its C++ of any callback it hooked.
	struct AppEvent: public interface::Event::Private
	{
		ss_ name;
		ss_ json;

		AppEvent(const ss_ &name, const ss_ &json): name(name), json(json){}
	};

	// Nodes that are not the map's ([BODY_INTERACT]): a body that came off
	// the world keeps its voxels in the same coordinate space, in a region
	// far outside the map's bounds -- stacked in Y from REGION_Y, a
	// REGION_STRIDE apart -- so that a position in it is an ordinary
	// position to every mod. A module that owns such bodies gives the
	// luanti module one of these, and get_node()/set_node() at a position
	// past REGION_Y ask it instead of the map. Outside every body a
	// region position reads as ignore (get() false) and a write is
	// dropped. The words are the luanti voxel format's (id, the light
	// nibbles, param2).
	static const int32_t REGION_Y = 1000000;
	static const int32_t REGION_STRIDE = 4096;
	struct RegionMap
	{
		virtual ~RegionMap(){}
		virtual bool get(int32_t x, int32_t y, int32_t z, uint32_t &word) = 0;
		virtual bool set(int32_t x, int32_t y, int32_t z, uint32_t word) = 0;
		// Where a region position is in the world, through the body's
		// transform: what add_item(), add_entity(), a particle or a sound
		// at a body's voxel means. False outside every body.
		virtual bool to_world(float x, float y, float z,
				float &wx, float &wy, float &wz) = 0;
	};

	struct Interface
	{
		// The region map above, or nullptr for none; the owner keeps it
		// alive and unsets it before it goes
		virtual void set_region_map(RegionMap *map) = 0;

		// Load Luanti's builtin and the game's mods, and run them. The game
		// is a directory with a game.conf, under user_path/luanti and not in
		// anyone's Luanti install.
		//
		// The world is the save, and the save is the caller's to open and to
		// keep open: the map, the clock and everything else the world is go
		// into it. A Luanti world directory is never written to -- it is
		// read for which game it wants, or imported, and that is all.
		// core.get_worldpath() is a directory of the save's rather than the
		// save's own root, since a Luanti mod writing through it -- which is
		// normal, and which games depend on -- must not be able to land on
		// save.sqlite.
		//
		// Whatever extends the environment is registered before this is
		// called: Luanti loads its mods once, in order, and a late arrival
		// would be a different kind of thing entirely.
		// What the server is doing while a game loads, as a line of text at
		// a time: the game, each mod with its number out of the total, the
		// registry, the world. Registered before run_game(), because that
		// is what takes the minutes and does not return until it is done.
		//
		// It is called on the server's own thread from inside run_game();
		// buildat's network::send() writes to the socket there and then, so
		// a packet sent from the handler reaches a client whose own thread
		// is still running.
		virtual void set_progress_handler(
				std::function<void(const ss_ &)> handler) = 0;

		virtual void run_game(const ss_ &game_path, storage::Save *save) = 0;

		// Where the app keeps what the game reads beside itself, before
		// run_game() ([LUANTI_APP_GLUE]); each "" for none:
		// - settings_file: a JSON file whose "render_mode" the clients
		//   are told (vanilla's settings.json);
		// - base_textures: Luanti's own base textures, the user's copy,
		//   in front of the module's;
		// - texture_packs: the directory world.mt's buildat_texture_pack
		//   names one in.
		struct Paths {
			ss_ settings_file;
			ss_ base_textures;
			ss_ texture_packs;
		};
		virtual void set_paths(const Paths &paths) = 0;

		// What a Luanti world is made out of: its seed, which mapgen made it
		// and what that mapgen was told, read out of its map_meta.txt into
		// the save.
		//
		// Before run_game(), because the world is made when the game starts
		// and a mapgen told afterwards has already generated the ground the
		// player stands on. What the save already says is kept, so a world
		// that has been played here keeps its own terrain whatever it is
		// imported over. The rest of a Luanti world -- its map, its clock,
		// what its mods remembered -- is import_world(), which is after.
		virtual void import_world_settings(const ss_ &luanti_world_path,
				storage::Save *save) = 0;

		// Hand Lua into the Luanti environment. chunkname is what a traceback
		// calls it. An error after run_game(), for the reason above.
		virtual void load_lua(const ss_ &chunk, const ss_ &chunkname) = 0;

		// Read a Luanti world into the running game's world: the clock it
		// was left at, and as much of its map as this world has room for.
		// One direction: the Luanti world directory is opened read-only and
		// nothing is written back to it.
		//
		// Before run_game(), which is where it happens: the map is read
		// once the game's nodes are registered and before a generator has
		// been asked for any section, because a section that has been
		// generated is one whose generator writes over what is read into
		// it. A section the map reaches into is not generated at all after
		// this -- what the imported world did not hold is not there, the
		// way it was not there in the world it came from.
		//
		// A name this game does not register becomes "unknown" and is
		// counted. What comes over is the nodes and their two params, the
		// metadata hanging off them, the timer on a node that had one, the
		// entities the blocks were holding, the clock and what the mods
		// remembered.
		//
		// The mods have therefore already loaded when the storage arrives,
		// so a mod that read its storage while loading read the save's own
		// and sees the imported values from the next run. A value the save
		// already has is kept, so importing twice does not take a mod's
		// memory back to what the Luanti world had.
		virtual void import_world(const ss_ &luanti_world_path) = 0;

		// A client arriving, leaving, and saying where it is. A player is
		// what Luanti calls whoever is on the other end of a client: the
		// name is the caller's to choose and is what everything about the
		// player is keyed by, the join and leave callbacks a mod registers
		// run here, and core.get_connected_players() answers with them.
		//
		// The peer is which client it is, so that what a player is sent --
		// their inventory, and the formspecs after it -- has somewhere to
		// go. It is network::PeerInfo::Id, kept as a number here so that
		// this header does not have to know about the network module.
		//
		// Where a player is is their client's to say; nothing here moves
		// one. The angles are radians, horizontal measured the way
		// core.get_look_horizontal() means it.
		virtual void add_player(const ss_ &name, size_t peer) = 0;
		// Before add_player(): the client is told where it will be (the
		// spawn, or where the last run left the player) and the world loads
		// round there, but the player is not in it -- no object, no join
		// callbacks -- until add_player() ([JOIN_WHEN_LOADED]).
		// remove_player() before that leaves nothing behind.
		virtual void place_player(const ss_ &name, size_t peer) = 0;
		// A server admin has every privilege ([VANILLA_PUBLIC] 3); said
		// again whenever that changes. After luanti:game_loaded.
		virtual void set_admin(const ss_ &name, bool admin) = 0;
		// A line of the server's own to a player's chat, or everyone's when
		// `to` is "" (core.chat_send_player, core.chat_send_all). After
		// luanti:game_loaded.
		virtual void chat_send(const ss_ &to, const ss_ &text) = 0;
		virtual void remove_player(const ss_ &name) = 0;
		// controls is what the player is holding down, in Luanti's own bit
		// order -- PlayerControl::getKeysPressed(), which is what
		// get_player_control_bits() answers with and what
		// get_player_control() is unpacked from.
		virtual void set_player_pos(const ss_ &name, float x, float y,
				float z, float look_h, float look_v, int32_t controls) = 0;

		// How fast a player was going down when they hit something, in
		// nodes a second. The physics is the client's, so the landing is
		// its word; what it costs is worked out here, the way Luanti's
		// client environment works it out -- one hit point per node a
		// second over fourteen.
		virtual void player_fell(const ss_ &name, float speed) = 0;

		// What a click comes to. The node is dug the way core.dig_node()
		// digs one -- the pointed thing is handed to the vendored builtin,
		// so can_dig, after_dig_node and the drops are the builtin's own --
		// and the answer is whether anything happened.
		//
		// The player is who dug it and who the drops go to; a name that is
		// nobody's digs with no actor, and then what it drops lands on the
		// ground.
		virtual bool dig_node(int32_t x, int32_t y, int32_t z,
				const ss_ &player_name) = 0;

		// The same node, as the button goes down rather than when the dig
		// completes: what it comes to is core.node_punch(), so a mod's
		// on_punch runs. The dig itself is timed on the client -- see
		// core.__dig_props() -- and arrives as its own packet.
		virtual bool punch_node(int32_t x, int32_t y, int32_t z,
				const ss_ &player_name) = 0;

		// The other button. under is the node pointed at and above the empty
		// voxel in front of it; what it comes to is core.item_place(), so the
		// pointed node's on_rightclick wins if it has one and the player's
		// wielded item is placed otherwise -- and what comes back is whether
		// anything happened.
		//
		// sneak is whether the player was holding the key that means "build
		// against this, do not use it", which is the only way to put a node
		// down on top of a chest. It is remembered as the player's control
		// state, which is where a mod reads it.
		virtual bool place_node(int32_t under_x, int32_t under_y,
				int32_t under_z, int32_t above_x, int32_t above_y,
				int32_t above_z, const ss_ &player_name,
				bool sneak = false) = 0;

		// The other button with nothing pointed at: the wielded item's
		// on_secondary_use, which is where food is eaten ([TOUCH_EAT])
		virtual bool use_wielded(const ss_ &player_name) = 0;

		// [LUANTI_APP_GLUE] The player session: a client's player, by the
		// name the app gives it, placed now and in the world once its
		// client says it has the world loaded (luanti:world_in, or 180 s);
		// admin is set_admin() then. From here the client's luanti:*
		// input packets are the module's (session.h) and its leave
		// removes the player.
		virtual void join_player(const ss_ &name, size_t peer,
				bool admin) = 0;
		// Whether the peer's player is in the world, past its loading
		virtual bool player_in_world(size_t peer) = 0;
		// A player's chat lines at once, then one a second; 0, the
		// default, is no limit (a public server's flood guard)
		virtual void set_chat_limit(double burst) = 0;
		// [VANILLA_CHAT_MIN] Asked of a plain line before the game's
		// callbacks see it: "" lets it through, else the line is dropped
		// and the player told that text. A "/" command is not asked: the
		// game's privileges are its own. Called on this module's thread.
		virtual void set_chat_gate(
				std::function<ss_(size_t peer, const ss_ &name)> gate) = 0;

		// The drop key: what the player is holding goes into the world as
		// an object. count is how many of the stack go, and zero is all of
		// them -- the item's own on_drop is what does it.
		virtual bool drop_wielded(const ss_ &player_name, int count) = 0;

		// A click on an object rather than on a node: the entity's own
		// on_punch runs, and what the wielded item does to it is
		// core.get_hit_params(). The id is the one the client was sent with
		// the object's position.
		virtual bool punch_object(int32_t id, const ss_ &player_name) = 0;

		// Which hotbar slot the player is holding, one-based. It is the
		// client's to say -- the keys and the wheel are there -- and the
		// server reads it whenever a dig or a place asks what is in hand.
		virtual void set_wield_index(const ss_ &player_name, int index) = 0;

		// A line a player typed. What it comes to is the on_chat_message
		// callbacks -- the vendored builtin registers the one that runs a
		// "/" command among them -- and a line nobody takes is said to
		// everyone, which is what Luanti's own server does with it.
		virtual void chat_message(const ss_ &player_name,
				const ss_ &message) = 0;

		// The scene the map is in, or null until luanti:game_loaded
		virtual SceneReference get_scene() = 0;

		// core.<name>() called and its result read as a list of strings:
		// how a module beside this one asks the game's Lua a question of
		// its own -- a function it registered through load_lua() -- once
		// the game is loaded. Empty on an error, which is logged.
		virtual sv_<ss_> call_string_list(const ss_ &name) = 0;

		// [LUANTI_APP_GLUE] core.<name>(value) called, the value and the
		// result as JSON ("null" for none): the one way an app's C++ reaches
		// any of the game's functions -- its own, handed in by load_lua(),
		// calling what it likes. "" on an error, which is logged. The other
		// way is AppEvent.
		virtual ss_ call_json(const ss_ &name, const ss_ &json) = 0;

		// Whether the map's chunks get server-side collision shapes
		// (voxelworld's physics_enabled): off, since nothing of the game's
		// own collides on the server; a module that drops rigid bodies onto
		// the terrain asks before run_game() ([VOXEL_PHYSICS_SAMPLE]).
		virtual void set_server_physics(bool on) = 0;

		// [SKELENTI_SOUNDS] Sounds the app's client makes rather than the
		// game ships: a sound group whose name starts with prefix is
		// <group>.1.ogg .. .<count>.ogg (count up to 9) as if they were
		// served, picked from per play as files are. The client module
		// plays what the app handed it under those names
		// (set_sound in client_lua/module.lua). An empty prefix is none.
		virtual void set_generated_sounds(const ss_ &prefix, int count) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(luanti::Interface*)> cb)
	{
		return server->access_module("luanti", [&](interface::Module *module){
			auto *iface = (luanti::Interface*)module->check_interface();
			cb(iface);
		});
	}
}

// vim: set noet ts=4 sw=4:
