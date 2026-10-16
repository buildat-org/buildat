// Buildat: apps/demo_skelenti/main/main.cpp
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// skelenti ([LUANTI_APP_EXAMPLE]): an app that holds its Luanti game
// (game/), runs it in a save of the player's choosing and shows it with
// the module's client loop (client_lua/).
//
// The world: until one runs, a joining client gets the world dialog
// (client_lua/worlds.lua), whose choice -- a save to play, a new one to
// make, one to delete -- comes back as skelenti:world_* packets. The
// first save picked is the world for as long as the server runs; whoever
// joins after goes straight in. BUILDAT_SKELENTI_WORLD=<name> skips the
// dialog, the save opened or made at the start (the checks; a server
// nobody sits at). What is Buildat's own is here and in
// client_lua/: the HUD, the inventory's drawing, and the mobs.
//
// The mobs: a boar on grass by day, wandering and fleeing when hit, and a
// skeleton in the dark underground, keeping its distance and shooting
// arrows, burning in daylight. Their AI, spawning and arrows are here, as
// nodes in the luanti module's scene that replicate to every client;
// the client draws them as boxes (client_lua/mobs.lua). What they need of
// the world -- the ground, the light, the players, a hit's damage, the
// drops -- is the game's Lua through the bridge (game/mods/skelenti/
// mobs.lua). A mob is saved in the world's save; an arrow is not (a
// stuck one goes after a minute).
#include "core/log.h"
#include "core/json.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/record.h"
#include "luanti/api.h"
#include "accounts/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "client_file/api.h"
#include "storage/api.h"
#include "main_context/api.h"
#include <Scene.h>
#include <Node.h>
#include <cmath>
#include <cstdarg>
#include <fstream>
#include <map>
#include <random>
#include <set>
#include <sstream>
#define MODULE "main"

namespace demo_skelenti {

using interface::Event;
using namespace Urho3D;

enum Kind: uint8_t { BOAR = 0, SKELETON = 1 };
enum Mode: uint8_t { WANDER = 0, FLEE = 1, FIGHT = 2 };
static const char *KIND[] = {"boar", "skeleton"};
static const int MAX_HP[] = {10, 20};
static const int HEIGHT[] = {1, 2};
// Walking, and fleeing or fighting, in nodes a second
static const float SPEED[][2] = {{1.2f, 3.5f}, {1.0f, 1.8f}};
static const float GRAVITY = 20.0f, ARROW_GRAVITY = 9.81f, ARROW_SPEED = 18.0f;
// Awake within WAKE of a player, asleep (saved, not stepped) past SLEEP
static const float WAKE = 48, SLEEP = 64;
// simplified: one cap for the world and one per 64-node area; the world's
// would want a cap per area that is loaded. MAX_AREA and MAX_NEAR are a
// boar's; a skeleton's go by the place's danger (danger())
static const size_t MAX_MOBS = 120, MAX_AREA = 6, MAX_NEAR = 3;
// From this danger up a skeleton spawns under the open sky too, and the
// sun does not burn it (user, 2026-10-15)
static const float DAYLIGHT_DANGER = 0.5f;

// A mob is one record in the save's store "skelenti_mobs", key "mob/<n>"
struct Mob
{
	uint8_t kind = BOAR;
	float x = 0, y = 0, z = 0, yaw = 0;
	int32_t hp = 0;
	uint8_t mode = WANDER;
	float mode_t = 0; // seconds left of the mode
	// Not saved
	float vy = 0, speed = 0, shoot_t = 2, burn_t = 0, from_x = 0, from_z = 0;
	ss_ target;
	uint node_id = 0; // 0 asleep
	int hurt = 0, hurt_sent = 0;

	template<class Archive> void serialize(Archive &archive){
		interface::Record<Archive> r(archive, "SkelentiMob", 1, 0);
		r.ar(kind, x, y, z, yaw, hp, mode, mode_t);
		r.end();
	}
};

struct Arrow
{
	float x, y, z, vx, vy, vz, age = 0;
	bool stuck = false;
	uint node_id = 0;
};

struct Player
{
	ss_ name;
	float x, y, z;
	int hp;
};

static ss_ fmt(const char *f, ...)
{
	char buf[1000];
	va_list va;
	va_start(va, f);
	vsnprintf(buf, sizeof buf, f, va);
	va_end(va);
	return buf;
}

static float num(const json::Value &v)
{
	return v.is_number() ? (float)v.as_number() : 0.0f;
}

struct Module: public interface::Module
{
	interface::Server *m_server;
	luanti::SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	std::set<size_t> m_waiting, m_shown;
	bool m_starting = false;
	std::map<uint32_t, Mob> m_mobs;
	uint32_t m_next_key = 1;
	std::vector<Arrow> m_arrows;
	std::vector<Player> m_players;
	std::map<size_t, double> m_last_hit;
	double m_time = 0;
	float m_ai_t = 0, m_spawn_t = 0, m_save_t = 0, m_field_t = 0;
	// The middle of the danger grid each player was last sent, by name
	std::map<ss_, std::pair<int, int>> m_field;
	// The world's own danger field (danger()), kept in its save
	uint32_t m_salt = 0;
	std::mt19937 m_rand{std::random_device{}()};
	// BUILDAT_SKELENTI_TEST, for the checks: "boar 0 3; skeleton 0 9" -- no
	// spawning of its own, and the mobs named at x, z from the first
	// player in the world, once, standing still for half a minute
	// (BUILDAT_LUANTI_FORCE_TIME pins the hour)
	ss_ m_test = getenv("BUILDAT_SKELENTI_TEST") ?
			getenv("BUILDAT_SKELENTI_TEST") : "";
	bool m_test_done = false;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server){}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this,
				Event::t("network:packet_received/skelenti:punch"));
		for(const char *n : {"play", "create", "delete"})
			m_server->sub_event(this, Event::t(
					ss_("network:packet_received/skelenti:world_")+n));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_VOIDN("core:shutdown", on_shutdown)
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("network:packet_received/skelenti:world_play",
				on_world_play, network::Packet)
		EVENT_TYPEN("network:packet_received/skelenti:world_create",
				on_world_create, network::Packet)
		EVENT_TYPEN("network:packet_received/skelenti:world_delete",
				on_world_delete, network::Packet)
		EVENT_TYPEN("network:packet_received/skelenti:punch", on_punch,
				network::Packet)
	}

	void on_start()
	{
		const char *name = getenv("BUILDAT_SKELENTI_WORLD");
		if(name && name[0])
			start_world(name, true);
	}

	// A save a world may be: a valid name not beginning with _, which are
	// the server's own (_server, builtin/accounts')
	static bool is_world(storage::Interface *i, const ss_ &name)
	{
		return i->valid_name(name) && name[0] != '_';
	}

	// The save opened (or made, when `create`) and the game run in it;
	// false when the name is no save's
	bool start_world(const ss_ &name, bool create)
	{
		if(m_starting)
			return false;
		storage::access(m_server, [&](storage::Interface *i){
			if(!is_world(i, name))
				return;
			m_save = i->open(name);
			if(!m_save && create)
				m_save = i->create(name);
		});
		if(!m_save){
			log_w(MODULE, "skelenti: no world \"%s\"", cs(name));
			return false;
		}
		m_starting = true;
		log_i(MODULE, "skelenti: the world \"%s\" starts", cs(name));
		luanti::access(m_server, [&](luanti::Interface *i){
			// A file of Lua into the game before its mods, as vanilla's
			// BUILDAT_LUANTI_LUA: what a check stages its scene with
			const char *extra = getenv("BUILDAT_LUANTI_LUA");
			if(extra && extra[0]){
				std::ifstream ifs(extra, std::ios::binary);
				if(!ifs.good()){
					m_server->shutdown(1, ss_()+"Cannot read "+extra);
					return;
				}
				std::ostringstream os;
				os<<ifs.rdbuf();
				log_i(MODULE, "skelenti: loading %s into the game", extra);
				i->load_lua(os.str(), extra);
			}
			// The game's skelenti_* sounds are blip's, made by the client
			// (client_lua/sounds.lua, VARIANTS of each)
			i->set_generated_sounds("skelenti_", 8);
			i->run_game(m_server->get_module_path(MODULE)+"/game", m_save);
		});
		return true;
	}

	// The world dialog's list, to a peer waiting for a world: "list" and a
	// save name a line, or "wait" for one who may not pick
	void send_worlds(size_t peer)
	{
		ss_ data = "wait";
		if(is_owner(peer)){
			data = "list";
			storage::access(m_server, [&](storage::Interface *i){
				for(const storage::SaveInfo &info : i->list())
					if(is_world(i, info.name))
						data += "\n"+info.name;
			});
		}
		network::access(m_server, [&](network::Interface *i){
			i->send(peer, "skelenti:worlds", data);
		});
	}

	// A world packet is the dialog's, and only before a world runs
	bool may_pick(const network::Packet &packet)
	{
		if(m_starting || !is_owner(packet.sender)){
			log_w(MODULE, "skelenti: %s from peer %zu ignored",
					cs(packet.name), packet.sender);
			return false;
		}
		return true;
	}

	void on_world_play(const network::Packet &packet)
	{
		if(may_pick(packet) && !start_world(packet.data, false))
			send_worlds(packet.sender);
	}

	void on_world_create(const network::Packet &packet)
	{
		if(!may_pick(packet))
			return;
		bool exists = false;
		storage::access(m_server, [&](storage::Interface *i){
			for(const storage::SaveInfo &info : i->list())
				exists = exists || info.name == packet.data;
		});
		if(exists || !start_world(packet.data, true))
			send_worlds(packet.sender);
	}

	void on_world_delete(const network::Packet &packet)
	{
		if(!may_pick(packet))
			return;
		storage::access(m_server, [&](storage::Interface *i){
			if(is_world(i, packet.data)){
				log_i(MODULE, "skelenti: the world \"%s\" deleted",
						cs(packet.data));
				i->remove(packet.data);
			}
		});
		send_worlds(packet.sender);
	}

	// Who may pick, make and delete a world: the launcher's own client (its
	// owner token, not an address another user on this machine has too)
	bool is_owner(size_t peer)
	{
		bool owner = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			owner = i->is_local(peer);
		});
		return owner;
	}

	void on_game_loaded(const luanti::GameLoaded &event)
	{
		m_scene = event.scene;
		if(m_save){
			m_store = m_save->store("skelenti_mobs");
			ss_ salt;
			if(!m_store->get("salt", salt)){
				salt = itos(m_rand());
				m_store->set("salt", salt);
			}
			m_salt = (uint32_t)std::stoul(salt);
			// The mapgen's piles of bones work the danger out in Lua: the
			// salt, and three places it must agree on
			ss_ at;
			for(int i = 0; i < 3; i++){
				const float x = -437.0f + 311 * i, z = 129.0f - 173 * i;
				at += fmt("%s[%.0f, %.0f, %.4f]", i ? ", " : "", x, z,
						danger(x, z));
			}
			json::Value r = call("skelenti_salt", fmt(
					"{\"salt\": %u, \"at\": [%s]}", m_salt, cs(at)));
			if(!(r.is_boolean() && r.as_boolean()))
				log_w(MODULE, "skelenti: the mapgen's danger is not main.cpp's:"
						" %s", r.is_array() && r.size() == 1 &&
						r.at(0).is_string() ? cs(r.at(0).as_string()) : "?");
			for(const ss_ &key : m_store->list("mob/")){
				ss_ data;
				Mob m;
				uint32_t k = atoi(key.c_str() + 4);
				if(!m_store->get(key, data) || !storage::unpack(data, m) ||
						m.kind > SKELETON || k == 0){
					log_w(MODULE, "skelenti: %s is not a mob", cs(key));
					continue;
				}
				m_mobs[k] = m;
				m_next_key = std::max(m_next_key, k + 1);
			}
		}
		log_i(MODULE, "skelenti: the world is up, %zu mobs saved",
				m_mobs.size());
		for(size_t peer : m_waiting)
			show(peer);
		m_waiting.clear();
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		if(m_scene){
			show(event.recipient);
		} else if(m_waiting.insert(event.recipient).second){
			network::access(m_server, [&](network::Interface *i){
				i->send(event.recipient, "core:run_script",
						"buildat.run_script_file(\"main/worlds.lua\")");
			});
			send_worlds(event.recipient);
		}
	}

	// Once per peer: files_transmitted comes again after each batch
	void show(size_t peer)
	{
		if(!m_shown.insert(peer).second)
			return;
		network::access(m_server, [&](network::Interface *i){
			// The world dialog goes, where there was one
			i->send(peer, "skelenti:worlds", "up");
			i->send(peer, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
		// Every privilege for the launcher's own client (its owner token,
		// not just an address on this machine) and for a server admin,
		// as vanilla gives them ([SECURITY_RUN_1])
		// simplified: decided at join; an account made admin mid-game gets
		// them on its next join (vanilla's on_accounts_privs is the upgrade)
		bool admin = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			admin = i->is_local(peer) || i->is_admin(i->name_of(peer));
		});
		luanti::access(m_server, [&](luanti::Interface *i){
			i->join_player("player"+itos(peer), peer, admin);
		});
		replicate::access(m_server, [&](replicate::Interface *i){
			i->assign_scene_to_peer(m_scene, peer);
		});
	}

	void on_client_disconnected(const network::OldClient &old)
	{
		m_shown.erase(old.info.id);
		m_waiting.erase(old.info.id);
		m_field.erase("player"+itos(old.info.id));
		m_last_hit.erase(old.info.id);
	}

	void on_shutdown()
	{
		save();
	}

	float rnd(){ return std::uniform_real_distribution<float>(0, 1)(m_rand); }

	json::Value call(const char *name, const ss_ &arg)
	{
		ss_ r;
		luanti::access(m_server, [&](luanti::Interface *i){
			r = i->call_json(name, arg);
		});
		return json::load_string(r.empty() ? "null" : r.c_str());
	}

	// A moment's sound, by name, at a place: the clients' table says what
	// file it is (client_lua/mobs.lua)
	void sound(const char *moment, float x, float y, float z)
	{
		ss_ data = fmt("%s %.2f %.2f %.2f", moment, x, y, z);
		network::access(m_server, [&](network::Interface *i){
			for(size_t peer : m_shown)
				i->send(peer, "skelenti:sound", data);
		});
	}

	void save()
	{
		if(!m_store)
			return;
		m_store->batch([&](){
			for(auto &kv : m_mobs)
				m_store->set("mob/"+itos(kv.first), storage::pack(kv.second));
		});
	}

	const Player* nearest(float x, float y, float z, float &d)
	{
		const Player *best = nullptr;
		d = 1e9;
		for(const Player &p : m_players){
			float e = std::sqrt((p.x-x)*(p.x-x) + (p.y-y)*(p.y-y) +
					(p.z-z)*(p.z-z));
			if(p.hp > 0 && e < d){
				d = e;
				best = &p;
			}
		}
		return best;
	}

	void read_players()
	{
		m_players.clear();
		json::Value v = call("skelenti_players", "null");
		for(unsigned i = 0; v.is_array() && i < v.size(); i++){
			const json::Value &p = v.at(i);
			if(p.is_array() && p.size() == 5 && p.at(0).is_string())
				m_players.push_back({p.at(0).as_string(), num(p.at(1)),
						num(p.at(2)), num(p.at(3)), (int)num(p.at(4))});
		}
	}

	void with_scene(std::function<void(Scene*)> f)
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			f(imc->check_scene(m_scene));
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_scene)
			return;
		m_time += event.dtime;
		step_arrows(event.dtime);
		m_ai_t += event.dtime;
		if(m_ai_t >= 0.1f){
			step_mobs(m_ai_t);
			m_ai_t = 0;
		}
		m_spawn_t += event.dtime;
		if(!m_test.empty())
			stage_test();
		else if(m_spawn_t >= 4){
			m_spawn_t = 0;
			spawn();
		}
		m_field_t += event.dtime;
		if(m_field_t >= 1){
			m_field_t = 0;
			for(const Player &p : m_players)
				send_field(p);
		}
		m_save_t += event.dtime;
		if(m_save_t >= 10){
			m_save_t = 0;
			save();
		}
	}

	// **The danger of a place** (user, 2026-10-14): how full of
	// skeletons it gets, 0 to 1 -- value noise over 80-node cells, a
	// quarter of the world quiet -- and the fog over it is the warning
	float danger(float x, float z)
	{
		const float C = 80;
		const int ix = (int)std::floor(x / C), iz = (int)std::floor(z / C);
		auto smooth = [](float t){ return t * t * (3 - 2 * t); };
		const float tx = smooth(x / C - ix), tz = smooth(z / C - iz);
		auto h = [&](int a, int b){
			uint32_t v = (uint32_t)a * 73856093u ^ (uint32_t)b * 19349663u ^
					m_salt;
			v ^= v >> 13; v *= 0x5bd1e995u; v ^= v >> 15;
			return (v & 0xffff) / 65535.0f;
		};
		const float v = (h(ix, iz) * (1 - tx) + h(ix + 1, iz) * tx) * (1 - tz) +
				(h(ix, iz + 1) * (1 - tx) + h(ix + 1, iz + 1) * tx) * tz;
		return std::min(1.0f, std::max(0.0f, (v - 0.3f) / 0.6f));
	}

	// **The danger on the ground** ([SKELENTI_DANGER_LOOK]): the field
	// around a player, FIELD_N cells of FIELD_CELL nodes a side, which the
	// client hands to voxel_shading's set_area_field() and the voxel
	// shader draws as decay. Sent again when the player is a quarter of
	// it from its middle. "skelenti:field": "x0 z0 cell n\n" and n * n
	// bytes, row by row along +x, each the danger at a cell's middle.
	// simplified: a view range past a quarter of the grid (132 nodes)
	// sees the edge's value carried on; a bigger grid is the upgrade.
	static const int FIELD_CELL = 16, FIELD_N = 33;
	void send_field(const Player &p)
	{
		const int cx = (int)std::floor(p.x / FIELD_CELL);
		const int cz = (int)std::floor(p.z / FIELD_CELL);
		auto it = m_field.find(p.name);
		if(it != m_field.end() && std::abs(it->second.first - cx) <
				FIELD_N / 4 && std::abs(it->second.second - cz) < FIELD_N / 4)
			return;
		size_t peer = 0;
		if(p.name.compare(0, 6, "player") != 0 ||
				!(std::istringstream(p.name.substr(6)) >> peer))
			return;
		m_field[p.name] = {cx, cz};
		const int x0 = (cx - FIELD_N / 2) * FIELD_CELL;
		const int z0 = (cz - FIELD_N / 2) * FIELD_CELL;
		ss_ data = fmt("%i %i %i %i\n", x0, z0, FIELD_CELL, FIELD_N);
		for(int j = 0; j < FIELD_N; j++)
			for(int i = 0; i < FIELD_N; i++)
				data += (char)(uint8_t)std::lround(255 * danger(
						x0 + (i + 0.5f) * FIELD_CELL,
						z0 + (j + 0.5f) * FIELD_CELL));
		network::access(m_server, [&](network::Interface *inet){
			inet->send(peer, "skelenti:field", data);
		});
	}

	void spawn()
	{
		for(const Player &p : m_players){
			if(p.hp <= 0 || m_mobs.size() >= MAX_MOBS)
				continue;
			for(uint8_t kind : {BOAR, SKELETON}){
				size_t near = 0;
				for(auto &kv : m_mobs){
					const Mob &m = kv.second;
					if(m.kind == kind && m.node_id && std::fabs(m.x-p.x) < 32 &&
							std::fabs(m.z-p.z) < 32 && std::fabs(m.y-p.y) < 32)
						near++;
				}
				// A skeleton by the place's danger: more tries, more of them
				const float d = danger(p.x, p.z);
				if(near >= (kind == SKELETON ? 1 + (size_t)(5 * d) : MAX_NEAR))
					continue;
				if(kind == SKELETON && rnd() > 0.1f + 0.9f * d)
					continue;
				json::Value s = call("skelenti_spawn_spot", fmt(
						"{\"kind\": \"%s\", \"x\": %.2f, \"y\": %.2f, "
						"\"z\": %.2f, \"d\": %.2f}",
						KIND[kind], p.x, p.y, p.z, d));
				if(!s.is_array() || s.size() != 3)
					continue;
				Mob m;
				m.kind = kind;
				m.x = num(s.at(0)), m.y = num(s.at(1)), m.z = num(s.at(2));
				size_t area = 0;
				for(auto &kv : m_mobs)
					if(std::fabs(kv.second.x - m.x) < 32 &&
							std::fabs(kv.second.z - m.z) < 32)
						area++;
				if(area >= (kind == SKELETON ?
						2 + (size_t)(8 * danger(m.x, m.z)) : MAX_AREA))
					continue;
				m.hp = MAX_HP[kind];
				m.yaw = rnd() * 2 * M_PI;
				uint32_t k = m_next_key++;
				m_mobs[k] = m;
				log_i(MODULE, "skelenti: a %s (%u) spawns at %.1f,%.1f,%.1f",
						KIND[kind], k, m.x, m.y, m.z);
			}
		}
	}

	void stage_test()
	{
		if(m_test_done || m_players.empty())
			return;
		m_test_done = true;
		const Player &p = m_players[0];
		std::istringstream is(m_test);
		ss_ item;
		while(std::getline(is, item, ';')){
			std::istringstream it(item);
			ss_ kind;
			float dx = 0, dz = 0;
			it >> kind >> dx >> dz;
			Mob m;
			m.kind = kind == "skeleton" ? SKELETON : BOAR;
			m.x = p.x + dx, m.y = p.y, m.z = p.z + dz;
			json::Value s = call("skelenti_sense", fmt(
					"{\"g\": [[%.2f, %.2f, %.2f, %d]]}", m.x, m.y + 2, m.z,
					HEIGHT[m.kind])).get("g");
			if(s.is_array() && s.size() == 1 && s.at(0).at(0).is_number())
				m.y = num(s.at(0).at(0));
			m.hp = MAX_HP[m.kind];
			m.yaw = M_PI;
			m.mode_t = 30;
			uint32_t k = m_next_key++;
			m_mobs[k] = m;
			log_i(MODULE, "skelenti: test: a %s (%u) at %.1f,%.1f,%.1f",
					KIND[m.kind], k, m.x, m.y, m.z);
		}
	}

	void wake(Mob &m)
	{
		with_scene([&](Scene *scene){
			Node *n = scene->CreateChild(String("skelenti_")+KIND[m.kind]);
			n->SetPosition(Vector3(m.x, m.y, m.z));
			n->SetRotation(Quaternion(m.yaw * M_RADTODEG, Vector3::UP));
			n->SetVar(StringHash("skelenti_hurt"), Variant(m.hurt));
			m.node_id = n->GetID();
		});
	}

	void remove_node(uint &id)
	{
		with_scene([&](Scene *scene){
			if(Node *n = scene->GetNode(id))
				n->Remove();
		});
		id = 0;
	}

	void shoot(Mob &m, const Player &p)
	{
		float dx = p.x - m.x, dz = p.z - m.z;
		float h = std::sqrt(dx*dx + dz*dz);
		if(h < 0.5f)
			return;
		Arrow a;
		a.x = m.x + dx / h * 0.6f, a.y = m.y + 1.5f, a.z = m.z + dz / h * 0.6f;
		float t = h / ARROW_SPEED;
		a.vx = dx / h * ARROW_SPEED + (rnd() - 0.5f) * 0.8f;
		a.vz = dz / h * ARROW_SPEED + (rnd() - 0.5f) * 0.8f;
		a.vy = (p.y + 1.2f - a.y) / t + 0.5f * ARROW_GRAVITY * t +
				(rnd() - 0.5f) * 0.6f;
		with_scene([&](Scene *scene){
			Node *n = scene->CreateChild("skelenti_arrow");
			n->SetPosition(Vector3(a.x, a.y, a.z));
			a.node_id = n->GetID();
		});
		m_arrows.push_back(a);
		sound("bow", m.x, m.y + 1.5f, m.z);
		log_i(MODULE, "skelenti: a skeleton shoots at %s", cs(p.name));
	}

	std::vector<ss_> drops(const Mob &m)
	{
		std::vector<ss_> out;
		if(m.kind == BOAR){
			out.push_back("skelenti:meat_raw "+itos(1 + m_rand() % 2));
			return out;
		}
		int bones = m_rand() % 3, arrows = m_rand() % 3;
		if(bones)
			out.push_back("skelenti:bone "+itos(bones));
		if(arrows)
			out.push_back("skelenti:arrow "+itos(arrows));
		// The end game's part: only a deep skeleton has one
		if(m.y < -32 && rnd() < 0.34f)
			out.push_back("skelenti:skull");
		return out;
	}

	// hp off a mob, by a player or by the sun (by ""); it dies at 0
	void damage(uint32_t key, int hp, const ss_ &by, float bx, float bz)
	{
		Mob &m = m_mobs[key];
		m.hp -= hp;
		m.hurt++;
		if(m.kind == BOAR){
			m.mode = FLEE;
			m.mode_t = 5;
			m.from_x = bx, m.from_z = bz;
		} else if(!by.empty())
			m.target = by;
		if(m.hp > 0){
			sound(m.kind == BOAR ? "boar_hurt" : "skeleton_hurt", m.x, m.y, m.z);
			return;
		}
		std::vector<ss_> items = drops(m);
		ss_ list;
		for(const ss_ &s : items)
			list += (list.empty() ? "\"" : ", \"") + s + "\"";
		call("skelenti_drop", fmt("{\"x\": %.2f, \"y\": %.2f, \"z\": %.2f, "
				"\"items\": [%s]}", m.x, m.y, m.z, cs(list)));
		log_i(MODULE, "skelenti: the %s (%u) dies at %.1f,%.1f,%.1f, drops [%s]",
				KIND[m.kind], key, m.x, m.y, m.z, cs(list));
		sound(m.kind == BOAR ? "boar_death" : "skeleton_death", m.x, m.y, m.z);
		if(m.node_id)
			remove_node(m.node_id);
		if(m_store)
			m_store->remove("mob/"+itos(key));
		m_mobs.erase(key);
	}

	void step_mobs(float dt)
	{
		read_players();
		// Wake what a player is near, put to sleep what none is
		std::vector<uint32_t> awake;
		for(auto &kv : m_mobs){
			Mob &m = kv.second;
			float d;
			nearest(m.x, m.y, m.z, d);
			if(!m.node_id && d < WAKE)
				wake(m);
			else if(m.node_id && d > SLEEP){
				remove_node(m.node_id);
				log_v(MODULE, "skelenti: the %s (%u) sleeps", KIND[m.kind],
						kv.first);
			}
			if(m.node_id)
				awake.push_back(kv.first);
		}
		if(awake.empty())
			return;
		// What each wants: a heading and a speed
		std::vector<float> nx(awake.size()), nz(awake.size());
		ss_ q;
		for(size_t i = 0; i < awake.size(); i++){
			Mob &m = m_mobs[awake[i]];
			m.mode_t -= dt;
			float d;
			const Player *p = nearest(m.x, m.y, m.z, d);
			float move_yaw = m.yaw, speed = 0;
			if(m.kind == SKELETON && p && d < 16){
				m.mode = FIGHT;
				m.yaw = std::atan2(p->x - m.x, p->z - m.z);
				move_yaw = m.yaw;
				// Between 3 and 9 nodes off: a bow's distance that a
				// sword's reach (a hand's 4) can still close
				if(d > 9)
					speed = SPEED[SKELETON][1];
				else if(d < 3)
					speed = SPEED[SKELETON][1], move_yaw = m.yaw + M_PI;
				m.shoot_t -= dt;
				if(m.shoot_t <= 0 && d < 14){
					shoot(m, *p);
					m.shoot_t = 1.5f + rnd() * 1.5f;
				}
			} else if(m.mode == FLEE && m.mode_t > 0){
				m.yaw = move_yaw = std::atan2(m.x - m.from_x, m.z - m.from_z);
				speed = SPEED[m.kind][1];
			} else {
				if(m.mode != WANDER || m.mode_t <= 0){
					m.mode = WANDER;
					m.mode_t = 3 + rnd() * 4;
					m.speed = rnd() < 0.5f ? 0 : SPEED[m.kind][0];
					m.yaw = rnd() * 2 * M_PI;
				}
				move_yaw = m.yaw, speed = m.speed;
			}
			nx[i] = m.x + std::sin(move_yaw) * speed * dt;
			nz[i] = m.z + std::cos(move_yaw) * speed * dt;
			q += fmt("%s[%.2f, %.2f, %.2f, %d], [%.2f, %.2f, %.2f, %d]",
					i ? ", " : "", nx[i], m.y, nz[i], HEIGHT[m.kind],
					m.x, m.y, m.z, HEIGHT[m.kind]);
		}
		json::Value s = call("skelenti_sense", "{\"g\": ["+q+"]}");
		const json::Value &g = s.get("g");
		if(!g.is_array() || g.size() != awake.size() * 2)
			return;
		// Where it can go: a step up, or down to a fall; a wall or a
		// drop past three turns it
		std::vector<std::pair<uint32_t, int>> burnt;
		for(size_t i = 0; i < awake.size(); i++){
			Mob &m = m_mobs[awake[i]];
			const json::Value &to = g.at((int)(2*i)), &here = g.at((int)(2*i + 1));
			const json::Value *under = &here;
			// Where the map is not loaded yet, it waits
			if(here.size() > 3)
				continue;
			if(nx[i] != m.x || nz[i] != m.z){
				float gy = num(to.at(0));
				if(to.at(0).is_number() && gy <= m.y + 1.01f){
					m.x = nx[i], m.z = nz[i];
					m.y = std::max(m.y, gy);
					under = &to;
				} else if(m.mode == WANDER)
					m.yaw = rnd() * 2 * M_PI;
			}
			if(under->at(0).is_number()){
				float gy = num(under->at(0));
				if(m.y > gy + 0.001f){
					m.vy -= GRAVITY * dt;
					m.y = std::max(gy, m.y + m.vy * dt);
				}
				if(m.y <= gy)
					m.vy = 0;
			} else {
				m.vy -= GRAVITY * dt;
				m.y += m.vy * dt;
			}
			// The sun: the natural light where it stands, unless the
			// place's danger is high (user, 2026-10-15)
			if(m.kind == SKELETON && num(here.at(1)) >= 12 &&
					danger(m.x, m.z) < DAYLIGHT_DANGER){
				m.burn_t += dt;
				if(m.burn_t >= 1){
					m.burn_t = 0;
					burnt.push_back({awake[i], 2});
				}
			}
			if(m.y < -1000)
				burnt.push_back({awake[i], 1000});
		}
		for(auto &b : burnt){
			if(!m_mobs.count(b.first))
				continue;
			if(b.second < 1000)
				log_i(MODULE, "skelenti: the skeleton (%u) burns", b.first);
			damage(b.first, b.second, "", 0, 0);
		}
		with_scene([&](Scene *scene){
			for(auto &kv : m_mobs){
				Mob &m = kv.second;
				Node *n = m.node_id ? scene->GetNode(m.node_id) : nullptr;
				if(!n)
					continue;
				n->SetPosition(Vector3(m.x, m.y, m.z));
				n->SetRotation(Quaternion(m.yaw * M_RADTODEG, Vector3::UP));
				if(m.hurt != m.hurt_sent){
					n->SetVar(StringHash("skelenti_hurt"), Variant(m.hurt));
					m.hurt_sent = m.hurt;
				}
			}
		});
	}

	// Two points a tick on each flying arrow, the middle and the end: at
	// 18 nodes a second it goes 0.6 a tick, so a point every 0.3
	void step_arrows(float dt)
	{
		ss_ q;
		size_t flying = 0;
		for(Arrow &a : m_arrows){
			a.age += dt;
			if(a.stuck)
				continue;
			a.vy -= ARROW_GRAVITY * dt;
			for(float f : {0.5f, 1.0f})
				q += fmt("%s[%.2f, %.2f, %.2f]", flying++ ? ", " : "",
						a.x + a.vx * dt * f, a.y + a.vy * dt * f,
						a.z + a.vz * dt * f);
		}
		json::Value p;
		if(flying){
			p = call("skelenti_sense", "{\"p\": ["+q+"]}").get("p");
			if(!p.is_array() || p.size() != flying)
				return;
		}
		size_t j = 0;
		std::vector<Arrow> kept;
		for(Arrow &a : m_arrows){
			bool gone = a.age > (a.stuck ? 60 : 8);
			bool was_stuck = a.stuck;
			size_t base = j;
			if(!a.stuck)
				j += 2;
			for(int k = 0; !gone && !a.stuck && k < 2; k++){
				float f = k ? 1.0f : 0.5f;
				float x = a.x + a.vx * dt * f, y = a.y + a.vy * dt * f,
						z = a.z + a.vz * dt * f;
				for(const Player &pl : m_players){
					if(pl.hp > 0 && std::hypot(pl.x - x, pl.z - z) < 0.45f &&
							y > pl.y - 0.1f && y < pl.y + 1.85f){
						int hp = 2 + m_rand() % 3;
						json::Value r = call("skelenti_hurt", fmt(
								"{\"n\": \"%s\", \"hp\": %d}", cs(pl.name), hp));
						log_i(MODULE, "skelenti: an arrow hits %s for %d, hp %d",
								cs(pl.name), hp, (int)num(r));
						sound("arrow_hit", x, y, z);
						gone = true;
						break;
					}
				}
				if(gone)
					break;
				if(p.at((int)(base + k)).is_true()){
					a.stuck = true;
					a.age = 0;
					log_i(MODULE, "skelenti: an arrow sticks at %.1f,%.1f,%.1f",
							a.x, a.y, a.z);
					sound("arrow_hit", a.x, a.y, a.z);
				} else
					a.x = x, a.y = y, a.z = z;
			}
			if(gone){
				remove_node(a.node_id);
				continue;
			}
			if(!was_stuck){
				with_scene([&](Scene *scene){
					if(Node *n = scene->GetNode(a.node_id)){
						n->SetPosition(Vector3(a.x, a.y, a.z));
						if(!a.stuck){
							Quaternion r;
							r.FromLookRotation(Vector3(a.vx, a.vy, a.vz));
							n->SetRotation(r);
						}
					}
				});
			}
			kept.push_back(a);
		}
		m_arrows.swap(kept);
	}

	// A client's click at a mob: what the player holds hits it, from no
	// further than a hand reaches with room for the lag
	void on_punch(const network::Packet &packet)
	{
		uint id = atoi(packet.data.c_str());
		ss_ name = "player"+itos(packet.sender);
		const Player *p = nullptr;
		for(const Player &pl : m_players)
			if(pl.name == name)
				p = &pl;
		double &last = m_last_hit[packet.sender];
		if(!p || p->hp <= 0 || id == 0 || m_time - last < 0.35)
			return;
		for(auto &kv : m_mobs){
			Mob &m = kv.second;
			if(m.node_id != id)
				continue;
			float d = std::sqrt((p->x-m.x)*(p->x-m.x) + (p->z-m.z)*(p->z-m.z) +
					(p->y + 1.6f - m.y - HEIGHT[m.kind] / 2.0f) *
					(p->y + 1.6f - m.y - HEIGHT[m.kind] / 2.0f));
			if(d > 6)
				return;
			last = m_time;
			int dmg = (int)num(call("skelenti_hit", "{\"n\": \""+name+"\"}"));
			log_i(MODULE, "skelenti: %s hits the %s (%u) for %d, hp %d",
					cs(name), KIND[m.kind], kv.first, dmg, m.hp - dmg);
			damage(kv.first, dmg, name, p->x, p->z);
			return;
		}
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
