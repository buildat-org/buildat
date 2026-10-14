// Buildat: apps/luanti_glue_test/main/main.cpp
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [LUANTI_APP_GLUE]'s check: the least app that is a Luanti game. It runs
// the module's minimal_game, shows it to whoever connects with the
// module's client loop (client_lua/init.lua), and reaches the game's Lua
// through the bridge only: its own Lua hooks on_punchplayer and emits
// what it saw, and a call with an argument sets a player's hp and reads
// it back. See check.sh.
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "luanti/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "client_file/api.h"
#include "storage/api.h"
#include <set>
#define MODULE "main"

namespace luanti_glue_test {

using interface::Event;

// The app's own Lua in the game: a call for the C++, and a callback list
// hooked that tells the C++ of each entry
static const char *LUA = R"LUA(
function core.glue_set_hp(a)
	local p = core.get_player_by_name(a.name)
	if not p then return nil end
	p:set_hp(a.hp)
	-- And a punch, which the hook below sees
	p:punch(nil, 1, {full_punch_interval = 1, damage_groups = {fleshy = 2}},
			{x = 0, y = 0, z = 1})
	return {hp = p:get_hp()}
end
core.register_on_punchplayer(function(player, _, _, _, _, damage)
	core.buildat_emit("glue_punched",
			{name = player:get_player_name(), damage = damage})
end)
-- A hand that digs: minimal_game's has no groupcaps, and its floor is cracky
core.register_item(":", {type = "none", wield_image = "blank.png",
	tool_capabilities = {full_punch_interval = 1, max_drop_level = 0,
		groupcaps = {cracky = {times = {[3] = 0.5}, uses = 0}}}})
-- On the floor, which is 25x25 around the origin, in a free corner of it
core.register_on_joinplayer(function(player)
	player:set_pos({x = -10, y = 0.5, z = -10})
end)
-- For check.sh: what the player did, in the log; the floor mod's own
-- self-tests dig and place with nobody doing them
core.register_on_dignode(function(_, node, digger)
	if digger and digger:is_player() then
		core.log("action", "glue: dug " .. node.name)
	end
end)
core.register_on_placenode(function(_, node, placer)
	if placer and placer:is_player() then
		core.log("action", "glue: placed " .. node.name)
	end
end)
local since = 0
core.register_globalstep(function(dt)
	since = since + dt
	if since < 0.5 then return end
	since = 0
	for _, p in ipairs(core.get_connected_players()) do
		local q = p:get_pos()
		core.log("action", string.format("glue: at %.1f %.1f", q.x, q.z))
	end
end)
)LUA";

struct Module: public interface::Module
{
	interface::Server *m_server;
	luanti::SceneReference m_scene = nullptr;
	std::set<size_t> m_waiting, m_shown, m_called;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server){}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
		m_server->sub_event(this, Event::t("luanti:app:glue_punched"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
		EVENT_TYPEN("luanti:app:glue_punched", on_punched, luanti::AppEvent)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
	}

	void on_start()
	{
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *i){
			save = i->open("glue");
			if(!save)
				save = i->create("glue");
		});
		luanti::access(m_server, [&](luanti::Interface *i){
			i->load_lua(LUA, "glue");
			i->run_game(m_server->get_module_path("luanti")+"/minimal_game",
					save);
		});
	}

	void on_game_loaded(const luanti::GameLoaded &event)
	{
		m_scene = event.scene;
		log_i(MODULE, "glue: the world is up");
		for(size_t peer : m_waiting)
			show(peer);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		if(m_scene)
			show(event.recipient);
		else
			m_waiting.insert(event.recipient);
	}

	// Once per peer: files_transmitted comes again after each batch
	void show(size_t peer)
	{
		if(!m_shown.insert(peer).second)
			return;
		network::access(m_server, [&](network::Interface *i){
			i->send(peer, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
		luanti::access(m_server, [&](luanti::Interface *i){
			i->join_player("glue"+itos(peer), peer, false);
		});
		replicate::access(m_server, [&](replicate::Interface *i){
			i->assign_scene_to_peer(m_scene, peer);
		});
	}

	// The call, once a player is in the world
	void on_tick(const interface::TickEvent &event)
	{
		for(size_t peer : m_shown){
			luanti::access(m_server, [&](luanti::Interface *i){
				if(!i->player_in_world(peer) || !m_called.insert(peer).second)
					return;
				const ss_ r = i->call_json("glue_set_hp",
						"{\"name\": \"glue"+itos(peer)+"\", \"hp\": 7}");
				log_i(MODULE, "glue: set_hp 7 answered %s", cs(r));
			});
		}
	}

	void on_punched(const luanti::AppEvent &event)
	{
		log_i(MODULE, "glue: punched %s", cs(event.json));
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
