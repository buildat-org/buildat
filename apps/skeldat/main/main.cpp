// Buildat: apps/skeldat/main/main.cpp
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// skeldat ([SKELDAT]): skelenti made fresh in Buildat, no Luanti game under
// it. The rules are game.h's; this is the world they run in -- Luanti's own
// valleys mapgen (builtin/luanti_mapgen) fed skelenti's biomes, ores and
// trees, voxelworld keeping the light and the saves -- and the players: where
// they are, what they carry, what they dig, place, craft and cook.
//
// The world: until one runs, a joining client gets builtin/world_menu and
// the launcher's own client picks a save to play or makes a new one, its
// seed asked for. The first save picked is the world for as long as the
// server runs. BUILDAT_SKELDAT_WORLD=<name> skips the menu (the checks; a
// server nobody sits at).
//
// The voxel word is Luanti's cut (VoxelFormat::luanti(): the id, the sky
// and the lamp light, param2), which is what the mapgen writes, and a
// second plane of 8 bits, "bones", whose low 4 are the bones field
// (bones.h): seeded by the mapgen in the danger zones, grown a section at
// a time, and drawn as skelenti's danger (the format's first modifier). The mobs, skelenti's,
// read the danger off it: where a skeleton spawns and whether the sun
// burns it.
//
// What the client says is trusted for now, apart from the reach and the
// time a dig takes: its position is taken as it comes until the movement
// check is in (stage 6).
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/os.h"
#include "interface/server_config.h"
#include "luanti/node_registry.h"
#include "luanti/media.h"
#include "luanti/session.h"
#include "accounts/api.h"
#include "chat/api.h"
#include "client_file/api.h"
#include "luanti_mapgen/api.h"
#include "main_context/api.h"
#include "moderation/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "world_menu/api.h"
#include "game.h"
#include "bones.h"
#include "move_check.h"
#include <Scene.h>
#include <Image.h>
#include <Node.h>
#include "core/json.h"
#include <cmath>
#include <ctime>
#include <algorithm>
#include <array>
#include <deque>
#include <atomic>
#include <functional>
#include <map>
#include <random>
#include <set>
#include <sstream>
#define MODULE "main"

namespace skeldat {

using interface::Event;
using interface::VoxelInstance;
using skeldat::Stack;
namespace pv = PolyVox;
using Urho3D::M_PI;
namespace vp = interface::voxel_path;
using Urho3D::M_RADTODEG;

// Luanti's mapgens write these three as numbers (vendor/mapnode.h), so
// the registry has them at those ids: ignore is the registry's own
// undefined 0, and the game's nodes follow air
static const uint32_t ID_IGNORE = 0, ID_UNKNOWN = 1, ID_AIR = 2, ID_NODE0 = 3;
static const float REACH = 5.5f;       // a little over Luanti's 4 from the eye
// A day in seconds, Luanti's time_speed 72; BUILDAT_SKELDAT_DAY for a check
static const float DAY_SECONDS = 1200;
static const int HP_MAX = 20, BREATH_MAX = 10;
// [SKELDAT_SKATEBOARD] The bit of luanti:where's controls that says the
// player is on the board (player.lua's board, init.lua sends it)
static const int32_t BOARD_BIT = 1 << 16;
// [SKELDAT_BOARD_PRONE] And lying flat on it (player.lua's prone)
static const int32_t PRONE_BIT = 1 << 17;
// And the low byte: the count of skeldat:position packets the client has
// had, so a report from before the last is known
static const int32_t PLACES_MASK = 0xff;

static ss_ pos_key(int x, int y, int z)
{
	return itos(x)+","+itos(y)+","+itos(z);
}

static ss_ dtos(double v)
{
	char buf[32];
	snprintf(buf, sizeof buf, "%.3f", v);
	return buf;
}

struct Player
{
	ss_ name;
	float x = 0, y = 0, z = 0, yaw = 0;
	bool placed = false; // the client has its position
	int hp = HP_MAX, breath = BREATH_MAX;
	sv_<Stack> main = sv_<Stack>(36), craft = sv_<Stack>(9),
			craftresult = sv_<Stack>(1);
	int wield = 0;
	// The table or the furnace whose window is open, by "x,y,z"
	ss_ open;
	// The dig under way: where, and since when
	ss_ dig_at;
	double dig_t0 = 0;
	double last_hit = -1; // the last hit at a mob
	double draw_t = -1; // the bow's draw started, -1 none ([SKELDAT_BOW])
	// The movement check's: where the last check passed the player, when,
	// and whether in the air
	float cx = 0, cy = 0, cz = 0;
	double check_t = 0;
	bool check_air = false;
	// [SKELDAT_SKATEBOARD] On the board now (the client's where), at any
	// time since the last check, the speed that check measured and its
	// checks in the air running on the board
	bool board = false, board_seen = false;
	// [SKELDAT_BOARD_PRONE] Lying flat now, and at any time since the check
	bool prone = false, prone_seen = false;
	float check_v = 0;
	int board_air = 0;
	// A place sent (send_position) that the client has not reported yet:
	// what it reports meanwhile is from before, and is not taken. The
	// places sent, counted; the client's where says how many it has had
	// (PLACES_MASK)
	bool moved = false;
	int32_t places = 0;
	// fly, fast and noclip, and no movement check (accounts' admin)
	bool admin = false;
	// Seen as a skeleton by the others (update_skeletons())
	bool skeleton = false;
	// No damage of any kind, the admin's toggle ([SKELDAT_INVULNERABLE])
	bool invulnerable = false;
	// [SKELDAT_INTRO] New to the world (no save of it): the opening dialog
	// once it is in; not with BUILDAT_SKELDAT_INTRO=0 (the checks' drives)
	bool intro = false;
	// The last skeldat:far sent ([SKELDAT_FAR_SKELETONS]); none yet is not
	// the empty list
	ss_ far_sent = "-";

	ss_ save() const {
		std::ostringstream os;
		os<<x<<" "<<y<<" "<<z<<" "<<yaw<<" "<<hp<<" "<<breath<<" "
				<<invulnerable<<"\n";
		for(auto *l : {&main, &craft, &craftresult}){
			for(size_t i = 0; i < l->size(); i++)
				os<<(i ? "|" : "")<<(*l)[i].str();
			os<<"\n";
		}
		return os.str();
	}
	void load(const ss_ &s){
		std::istringstream is(s);
		ss_ line;
		std::getline(is, line);
		std::istringstream(line)>>x>>y>>z>>yaw>>hp>>breath>>invulnerable;
		for(auto *l : {&main, &craft, &craftresult}){
			std::getline(is, line);
			std::istringstream ls(line);
			ss_ one;
			for(size_t i = 0; i < l->size() && std::getline(ls, one, '|'); i++)
				(*l)[i] = Stack::parse(one);
		}
		placed = true;
	}
};

struct Furnace
{
	Stack src, fuel, dst;
	float fuel_left = 0, src_time = 0;
	// A lantern's: the fuel slot alone ([SKELDAT_FIGHT_BACK])
	bool lantern = false;

	ss_ save() const {
		std::ostringstream os;
		os<<src.str()<<"|"<<fuel.str()<<"|"<<dst.str()<<"|"<<fuel_left<<"|"
				<<src_time<<"|"<<lantern;
		return os.str();
	}
	void load(const ss_ &s){
		std::istringstream is(s);
		ss_ a[6];
		for(ss_ &p : a)
			std::getline(is, p, '|');
		src = Stack::parse(a[0]);
		fuel = Stack::parse(a[1]);
		dst = Stack::parse(a[2]);
		fuel_left = (float)atof(a[3].c_str());
		src_time = (float)atof(a[4].c_str());
		lantern = a[5] == "1";
	}
};

// The mobs, skelenti's: a boar on grass under the open sky by day,
// wandering and fleeing when hit, and a skeleton where it is dark or the
// bones are thick, keeping its distance and shooting arrows, burning in
// daylight unless the bones around it are thick. Nodes in the scene that
// replicate to every client (client_lua/mobs.lua dresses them). A mob is
// saved in the store as "mob/<n>", "kind x y z yaw hp"; an arrow is not.
enum MobKind: uint8_t { BOAR = 0, SKELETON = 1 };
enum MobMode: uint8_t { WANDER = 0, FLEE = 1, FIGHT = 2 };
static const char *MOB_KIND[] = {"boar", "skeleton"};
static const int MOB_HP[] = {10, 20};
static const int MOB_HEIGHT[] = {1, 2};
// Walking, and fleeing or fighting, in voxels a second
static const float MOB_SPEED[][2] = {{1.2f, 3.5f}, {1.0f, 1.8f}};
static const float GRAVITY = 20.0f, ARROW_GRAVITY = 9.81f,
		ARROW_SPEED = 18.0f;
// [SKELDAT_BOW] A player's bow: full drawn in BOW_DRAW s, the arrow at
// the draw times BOW_SPEED, none under BOW_MIN; its hit BOW_DAMAGE a
// voxel a second; BOW_USES shots. A stuck arrow, anyone's, is picked up
// within ARROW_REACH, and after ARROW_STUCK s is a stuck_arrow voxel
static const float BOW_DRAW = 1, BOW_SPEED = 30, BOW_MIN = 0.1f,
		BOW_DAMAGE = 0.3f, ARROW_REACH = 1.5f, ARROW_STUCK = 60;
static const int BOW_USES = 250;
// Awake within WAKE of a player, asleep (saved, not stepped) past SLEEP
static const float WAKE = 48, SLEEP = 64;
// A skeleton near a player ([SKELDAT_LIGHT_PRIMARY]): its light form's
// step, the body's speed after it (faster than the light form's, so it
// keeps up) and how far behind the body is put back on it (across; up or
// down three times that)
static const float NEAR_STEP = 0.5f, BODY_SPEED = 2.6f, BODY_LAG = 3;
// simplified: one cap for the awake ones and one per 64-voxel area;
// MAX_AREA and MAX_NEAR are a boar's, a skeleton's go by the danger
static const size_t MAX_MOBS = 120, MAX_AREA = 6, MAX_NEAR = 3;
// The skeletons over the whole world ([SKELDAT_SKELETON_SIM]): from
// SKELETONS_MIN on clean ground to SKELETONS_MAX with every column's top
// at FLOOD, in a world of 1024 x 1024 columns (a smaller one has fewer);
// asleep ("light"), one steps a voxel every LIGHT_STEP seconds
// (BUILDAT_SKELDAT_LIGHT_STEP for a check); at night it places 1 to
// NIGHT_BLOCKS bone blocks on clean ground within SEED_RANGE columns
static const float SKELETONS_MIN = 500, SKELETONS_MAX = 2000,
		LIGHT_STEP = 1;
static const int NIGHT_BLOCKS = 3, SEED_RANGE = 24;
// [SKELDAT_BONE_BRIDGES] A skeleton's way to a target it must stand next
// to and cannot walk to, built with bone blocks: a block costs BUILD_COST
// walks in the search, the target within BUILD_RANGE columns, a search
// at most every BUILD_WAIT game seconds a skeleton, BUILD_CAP cells
// expanded (one that hits it builds nothing)
static const float BUILD_COST = 6, BUILD_WAIT = 5;
static const int BUILD_RANGE = 32;
static const size_t BUILD_CAP = 20000;
// A burning lantern's sphere ([SKELDAT_FIGHT_BACK]): no bones grow in it,
// each of its section's expansions takes LANTERN_RETRACT off a voxel
// (three times the growth: full bones gone in 5) and a bone block goes in
// one of LANTERN_DECAY_IN ([SKELDAT_LANTERN_RATE]); a coal lasts
// LANTERN_HOURS game hours
// simplified: paced by the section's own expansions (about every 150 s,
// at random); a lantern's own tick if that reads uneven
static const int LANTERN_RADIUS = 8, LANTERN_RETRACT = 3,
		LANTERN_DECAY_IN = 2;
static const float LANTERN_HOURS = 4;
// A burning lantern lures skeletons as LANTERN_LURE marker skulls do
static const int LANTERN_LURE = 5;
static const int8_t NO_GROUND = -128;
// From this danger up a skeleton spawns in the light too, and the sun
// does not burn it
static const float DAYLIGHT_DANGER = 0.5f;

struct Mob
{
	uint8_t kind = BOAR;
	float x = 0, y = 0, z = 0, yaw = 0;
	int hp = 0;
	// Not saved
	uint8_t mode = WANDER;
	float mode_t = 0; // seconds left of the mode
	float vy = 0, speed = 0, shoot_t = 2, burn_t = 0, from_x = 0, from_z = 0;
	uint32_t node_id = 0; // 0 asleep
	float light_t = 0; // to the next light step
	// Saved: the game day of its last marker skull; the coal in the
	// lantern it carries, -1 none ([SKELDAT_FIGHT_BACK])
	double marker_day = -1e9;
	int carry_coal = -1;
	// Not saved, a light one's: the footprint picked at sunrise or sunset
	// (-1 none), the night's bone blocks left and the column of the next
	int goal_fp = -1, quota = 0, seed_x = 0, seed_z = 0;
	int detour = 0; // steps left on a heading round what blocked it
	bool seeding = false;
	int hurt = 0, hurt_sent = 0;
	// A skeleton's body, awake ([SKELDAT_LIGHT_PRIMARY]): x, y, z are its
	// light form, which decides; the body walks after it, put there when
	// BODY_LAG behind. Not saved
	float bx = 0, by = 0, bz = 0, bvy = 0;
	// [SKELDAT_BONE_BRIDGES] The cells it walks to its target, the last
	// one over the block it builds when build is set; the game time of
	// its next search. Not saved
	sv_<interface::voxel_path::P> route;
	interface::voxel_path::P build_at;
	bool build = false, built = false;
	double search_t = 0;

	ss_ save() const {
		std::ostringstream os;
		os<<(int)kind<<" "<<x<<" "<<y<<" "<<z<<" "<<yaw<<" "<<hp<<" "<<
				marker_day<<" "<<carry_coal;
		return os.str();
	}
	bool load(const ss_ &s){
		int k = -1;
		std::istringstream(s)>>k>>x>>y>>z>>yaw>>hp>>marker_day>>carry_coal;
		kind = (uint8_t)k;
		return (k == BOAR || k == SKELETON) && hp > 0;
	}
};

struct Arrow
{
	float x, y, z, vx, vy, vz, age = 0;
	bool stuck = false;
	uint32_t node_id = 0;
	// A player's ([SKELDAT_BOW]): it hits mobs, not players
	bool by_player = false;
	size_t peer = 0;
	// Stuck: the voxel it went into and the one it sticks out into
	int sx = 0, sy = 0, sz = 0, fx = 0, fy = 0, fz = 0;
};

// A stack on the ground ([SKELDAT_DEATH_DROPS]): it falls until it rests
// on a voxel (through water to the bed), a living player within
// DROP_REACH takes what fits, and it is gone a game day after the drop;
// "skeldat_drop" in the scene, its item in the var "skeldat_item". Saved
// as "drop/<n>", "x y z age stack"
struct Drop
{
	Stack st;
	float x = 0, y = 0, z = 0, vx = 0, vy = 0, vz = 0, age = 0;
	bool resting = false;
	// The drop key's: not its dropper's until it has walked away from it
	ss_ owner;
	uint32_t node_id = 0;
	// [SKELDAT_SURFACE_END] A skull a skeleton dropped down a deep hole:
	// not picked up, and resting it is a skull voxel
	bool seed = false;
};
static const float DROP_REACH = 1.5f;

// Where something stands in a column (Module::ground())
struct Ground
{
	bool loaded = true, found = false, water = false;
	float y = 0; // the feet
	int sun = 0; // the sky's light there now
};

// The mapgen's section, skelenti's bone piles on its ground (bones.h's
// pile()), and its bones seeded by the place's danger: every voxel that is
// not air in a column at bones::SEED_DANGER or more, a pile's too. Runs on
// worldgen's worker thread, so it touches nothing but the volume.
struct BonesGenerator: public worldgen::GeneratorInterface
{
	// The nodes a pile is made of and stands on
	struct PileIds {
		uint32_t block = 0, tops[3] = {}, ground[3] = {};
	};
	up_<worldgen::GeneratorInterface> m_inner;
	interface::VoxelFormat m_format;
	interface::VoxelField m_bones;
	uint32_t m_salt;
	// The world's half in voxels, for the seeding's bias
	int m_half_v = skeldat::bones::HALF;
	// The highest voxel any section was made with
	std::atomic<int> m_top{-100000};
	// For a check: every voxel seeded at MAX (BUILDAT_SKELDAT_FILL), a
	// world that ends at once
	// For a check: every voxel at MAX (1), or those at x >= 0 (2), or
	// those with air over them, the surface (3)
	int m_fill = 0;
	PileIds m_ids;

	BonesGenerator(worldgen::GeneratorInterface *inner,
			const interface::VoxelFormat &format,
			const interface::VoxelField &bones, uint32_t salt,
			const PileIds &ids):
		m_inner(inner), m_format(format), m_bones(bones), m_salt(salt),
		m_ids(ids){}

	// The ground is the column's highest voxel in the section (lc..uc)
	// that is not air; the stack may rise into the padding above, which
	// the section over it takes as a tree's crown.
	// simplified: a pile whose stack would leave the volume is not made,
	// as a Luanti chunk's is not in skelenti, nor one on ground in the
	// section's top layer (what is over it is the next section's, unknown
	// here): about a sixteenth of them
	void piles(interface::VoxelVolume &volume, const pv::Vector3DInt32 &lc,
			const pv::Vector3DInt32 &uc, int32_t top)
	{
		auto id_at = [&](int32_t x, int32_t y, int32_t z){
			return m_format.id.get(volume.getVoxelAt(x, y, z).data);
		};
		int made = 0;
		for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int32_t x = lc.getX(); x <= uc.getX(); x++){
			skeldat::bones::Pile p;
			// FILL=half's clean side stays clean
			if((m_fill == 2 && x < 0) ||
					!skeldat::bones::pile(m_salt, x, z, p, m_half_v))
				continue;
			int32_t y = uc.getY();
			while(y >= lc.getY() && id_at(x, y, z) == ID_AIR)
				y--;
			if(y < lc.getY() || y == uc.getY() || y + 6 > top)
				continue;
			const uint32_t ground = id_at(x, y, z);
			if(ground != m_ids.ground[0] && ground != m_ids.ground[1] &&
					ground != m_ids.ground[2])
				continue;
			for(int i = 1; i <= p.height + 1; i++){
				uint32_t word = volume.getVoxelAt(x, y + i, z).data;
				const uint32_t here = m_format.id.get(word);
				if(here != ID_AIR && here != ID_IGNORE)
					break;
				if(i <= p.height){
					m_format.id.set(word, m_ids.block);
				} else if(p.top <= 3){
					m_format.id.set(word, m_ids.tops[p.top - 1]);
					m_format.param.set(word, (uint32_t)p.turn);
				} else {
					break;
				}
				volume.setVoxelAt(x, y + i, z, VoxelInstance(word));
			}
			made++;
		}
		// The first section with any, for check.sh; one a section would be
		// hundreds of lines
		static std::atomic<bool> told(false);
		if(made > 0 && !told.exchange(true))
			log_i(MODULE, "skeldat: the first bone piles, %d in the section "
					"at (%d, %d, %d)", made, lc.getX(), lc.getY(), lc.getZ());
	}

	pv::Vector3DInt32 get_padding_voxels()
	{
		return m_inner->get_padding_voxels();
	}

	void generate(main_context::SceneReference scene,
			const pv::Vector3DInt16 &section_p, interface::VoxelVolume &volume)
	{
		m_inner->generate(scene, section_p, volume);
		volume.add_planes(m_format.planes);
		const pv::Region &r = volume.getEnclosingRegion();
		const pv::Vector3DInt32 &lc = r.getLowerCorner(),
				&uc = r.getUpperCorner();
		const pv::Vector3DInt32 pad = m_inner->get_padding_voxels();
		piles(volume, lc + pad, uc - pad, uc.getY());
		// The highest voxel made, for the world's bounds' check
		for(int32_t y = uc.getY() - pad.getY(); y > m_top &&
				y >= lc.getY() + pad.getY(); y--){
			bool any = false;
			for(int32_t z = lc.getZ() + pad.getZ(); !any &&
					z <= uc.getZ() - pad.getZ(); z++)
			for(int32_t x = lc.getX() + pad.getX(); !any &&
					x <= uc.getX() - pad.getX(); x++){
				const uint32_t id = m_format.id.get(
						volume.getVoxelAt(x, y, z).data);
				any = id != ID_IGNORE && id != ID_AIR;
			}
			if(any){
				int top = m_top;
				while(y > top && !m_top.compare_exchange_weak(top, y)){}
				break;
			}
		}
		for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int32_t x = lc.getX(); x <= uc.getX(); x++){
			const int b = m_fill == 1 || m_fill == 3 ||
					(m_fill == 2 && x >= 0) ?
					skeldat::bones::MAX : m_fill == 2 ? 0 :
					skeldat::bones::seed_value(skeldat::bones::danger(m_salt,
					(float)x, (float)z, m_half_v));
			if(b == 0)
				continue;
			for(int32_t y = lc.getY(); y <= uc.getY(); y++){
				const uint32_t id = m_format.id.get(
						volume.getVoxelAt(x, y, z).data);
				if(id == ID_IGNORE || id == ID_AIR)
					continue;
				if(m_fill == 3){
					const uint32_t over = m_format.id.get(
							volume.getVoxelAt(x, y + 1, z).data);
					if(over != ID_AIR && over != ID_IGNORE)
						continue;
				}
				uint32_t word = volume.plane_at(1, x, y, z);
				m_bones.set(word, (uint32_t)b);
				volume.set_plane_at(1, x, y, z, word);
			}
		}
	}
};

// moderation::Host for the audit log alone (the admin's give and take): a
// subject is a player's name, and nothing is reported or decided here
struct AuditHost: public moderation::Host
{
	storage::Save *m_save = nullptr;
	storage::Save* save(){ return m_save; }
	ss_ name(){ return "skeldat"; }
	json::Value subject(const ss_ &id)
	{
		json::Value s = json::object();
		s.set("id", id);
		s.set("name", id);
		s.set("owner", id);
		s.set("players", 1);
		return s;
	}
	sv_<ss_> members(const json::Value &group){ return {}; }
	int severity(const ss_ &reason){ return 1; }
	json::Value thresholds(const json::Value &group){ return json::object(); }
	ss_ held(const json::Value &report){ return ""; }
	ss_ bucket(const json::Value &report){ return ""; }
	json::Value auto_act(const json::Value &group, const ss_ &id,
			const ss_ &want){ return json::Value(); }
	void uphold(moderation::Interface *m, const ss_ &by,
			const json::Value &group, const json::Value &q){}
	bool undo_auto(const ss_ &id, const json::Value &group){ return false; }
	void reverse(moderation::Interface *m, const ss_ &by,
			const json::Value &appeal, const ss_ &text){}
	void decided(const json::Value &report, bool upheld){}
	void event(const sv_<ss_> &to, const ss_ &by, const ss_ &text){}
	void notify(const json::Value &statement){}
};

struct Module: public interface::Module, public luanti_session::Game
{
	interface::Server *m_server;
	const skeldat::Game m_game = skeldat::make_game();
	main_context::SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	AuditHost m_audit;
	// The pathfinder's cell for a voxel id (fill_cells)
	sv_<uint8_t> m_cell_of;
	storage::Store *m_store = nullptr;
	bool m_starting = false;
	// The world started was new: "Making", else "Loading"
	bool m_making = false;
	int64_t m_start_us = interface::os::time_us();
	// worldgen's; read for its highest voxel only
	BonesGenerator *m_generator = nullptr;
	// [SKELDAT_HIGH_SCORES] Each player's seconds in this world ("played/"
	// in the skeldat store), the world's name, and the scores outside the
	// worlds: the save "_skeldat", store "scores", a key a parameter set
	std::map<ss_, double> m_played;
	ss_ m_world_name;
	storage::Save *m_scores = nullptr;
	// The ended world's set's best days and this score's place in it
	double m_end_best = 0;
	int m_end_place = 0;
	// [SKELDAT_RERUN] A re-run asked for: the module is reloading
	bool m_rerunning = false;
	// m_joining: sent the join, its login not yet in
	std::set<size_t> m_waiting, m_shown, m_joining;
	std::map<size_t, Player> m_players;
	std::map<ss_, Furnace> m_furnaces;
	luanti_mapgen::Params m_mapgen;
	bool m_spawn_ready = false;
	// Every section of the world in ([SKELDAT_BOUNDED_WORLD]): the players
	// wait for it
	bool m_world_ready = false;
	// The world's sections: x and z -m_half..m_half-1, y m_y0..m_y1;
	// BUILDAT_SKELDAT_SIZE="<half> <y0> <y1>" for a check's small world
	int m_half = skeldat::bones::HALF / skeldat::bones::SECTION,
			m_y0 = skeldat::bones::Y0 / skeldat::bones::SECTION,
			m_y1 = skeldat::bones::Y1 / skeldat::bones::SECTION;
	size_t all_sections() const
	{
		return (size_t)(2 * m_half) * (2 * m_half) * (m_y1 - m_y0 + 1);
	}
	// **The end** ([SKELDAT_BOUNDED_WORLD], [SKELDAT_SURFACE_END]): the
	// columns whose top -- the highest voxel that can hold bones -- has
	// none, by the section the top is in, counted again after an
	// expansion, a dig or a place; at none in all the world ends, its days
	// the high score, and nothing changes in it after. What is under the
	// tops does not count.
	std::map<ss_, int64_t> m_bare;
	// The total of m_bare once a game day, the last few: (day, count)
	std::deque<std::pair<double, int64_t>> m_bare_days;
	std::set<ss_> m_recount;
	bool m_ended = false;
	double m_end_days = 0;
	float m_spawn[3] = {0, 0, 0};
	double m_time = 0;
	// The time of day, 0 to 1 with 0.5 noon; a new world starts at 6:00
	double m_day = 0.25;
	float m_day_s = DAY_SECONDS, m_light_step = LIGHT_STEP;
	// Seconds between a section's expansions; BUILDAT_SKELDAT_EXPAND for a
	// check
	double m_section_period = skeldat::bones::SECTION_PERIOD;
	bool m_lantern_report = false;
	// Day 1, night 0, -1 before the world is in; the night's bone blocks
	int m_phase = -1;
	size_t m_night_blocks = 0;
	float m_save_t = 0, m_furnace_t = 0, m_send_t = 0, m_breath_t = 0,
			m_move_t = 0;
	size_t m_worldgen_queue = 0;
	bool m_load_points_dirty = true;
	interface::VoxelFormat m_format;
	interface::VoxelField m_bones{1, 0, 4};
	std::mt19937 m_rand{std::random_device{}()};
	// The world's own clock, seconds of game time since it was made, kept
	// in its save
	double m_world_t = 0;
	// The mobs, by key; the arrows in flight or stuck
	std::map<uint32_t, Mob> m_mobs;
	uint32_t m_next_mob = 1;
	std::vector<Arrow> m_arrows;
	std::vector<Drop> m_drops;
	// Bodies put back on their light form, for the report
	size_t m_body_puts = 0;
	float m_far_t = 0;
	// The outermost columns' mean top, once the world is in
	float m_edge_crest = 0;
	// The lowest of those tops ([SKELDAT_BACKDROP_LOW]), where the hills
	// beyond start under
	int m_edge_low = 0;
	// Each skeldat:far's count logged, for a check (BUILDAT_SKELDAT_FAR=1)
	bool m_far_report = getenv("BUILDAT_SKELDAT_FAR") != nullptr;
	float m_ai_t = 0, m_spawn_t = 0;
	// The columns whose top voxel has FLOOD bones or more, a section's
	// footprint each (x then z from -m_half), swept one a second; the
	// skeletons' count adjusted every game hour
	sv_<int> m_flooded;
	// Each column's top voxel, its y (NO_GROUND for none, or water) and
	// its bones, from the sweep and every set_node: what a light skeleton
	// walks on. simplified: the top only, so a light skeleton in a cave
	// stays put until a player wakes it; a voxel read for each of its steps
	// was ~66 us, the world being too big for voxelworld's chunk buffers
	// Marker skulls a footprint, kept by set_node, saved as "markers"
	sv_<int> m_markers;
	// [SKELDAT_SURFACE_END] The game day a skull was last dropped down a
	// deep hole, by column; saved as "holes"
	std::map<long, int> m_hole_day;
	// The nodes that keep the sun off a skeleton beside them
	std::array<uint32_t, 4> m_sun_ids{};
	// [SKELDAT_BOW] The stuck_arrow voxels, by "x,y,z", kept by set_node()
	// and saved as "stuck/<x,y,z>"
	uint32_t m_stuck_id = ID_IGNORE;
	std::set<ss_> m_stuck;
	uint32_t m_marker = ID_IGNORE, m_lantern_ids[2] = {ID_IGNORE, ID_IGNORE};
	sv_<int8_t> m_top_y;
	sv_<uint8_t> m_top_b;
	size_t m_sweep = 0;
	float m_sweep_t = 0, m_hour_t = 0;
	double m_light_us = 0;
	size_t m_light_steps = 0, m_woken = 0;
	// BUILDAT_SKELDAT_TEST, for the checks: "boar 0 3; skeleton 0 9" -- no
	// spawning of its own, and the mobs named at x, z from the first
	// player placed, once, standing still for half a minute; "bones 1 0 8"
	// sets the bones of the ground voxel at x, z
	ss_ m_test;
	bool m_test_done = false;
	// The loaded sections: the whole world, once it is in
	// ([SKELDAT_BOUNDED_WORLD]: no catch-up, nothing is ever away)
	std::set<ss_> m_sections;
	// Asked of worldgen and not merged yet: a section is loaded (empty)
	// before it is generated
	std::set<ss_> m_awaiting;
	// Expansions owed: due at random by the period
	double m_expand_due = 0;
	size_t m_expansions = 0, m_expand_changed = 0, m_grown = 0;
	// [SKELDAT_BONE_SPEED] The bones' speed, 1, 2, 5 or 10: the rule's
	// runs in each expansion and the skeletons' bone work scaled by it;
	// the lowest the world has been at, which its score names; the rule's
	// runs so far. Over each minute of real time, the game seconds ticked
	// and the expansions the budget a tick dropped (BUILDAT_SKELDAT_BUDGET
	// for a check), against the minute's: the server behind, by a tick
	// late or an expansion dropped alike.
	int m_speed = 1, m_speed_low = 1;
	size_t m_rule_runs = 0;
	double m_ticked_s = 0, m_dropped_n = 0;
	int64_t m_keep_up_us = 0;
	// Expansions a tick at most, a fraction carried to the next tick
	double m_budget = 4, m_budget_left = 0;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{
		m_format = interface::VoxelFormat::luanti();
		m_format.planes.push_back(interface::VoxelPlane("bones", 8));
		// The bones drawn as skelenti draws its danger: the first surface
		// modifier, which the client's VOXELDECAY technique reads as the
		// decay (AreaField.glsl). wetness is only the slot it rides in.
		m_format.wetness = m_bones;
	}

	void init()
	{
		sub(m_server, "core:start", &Module::on_start);
		// [SKELDAT_RERUN] The module reloaded: the world closed, and on
		// again (a re-run's, or the start's)
		sub(m_server, "core:unload", &Module::on_unload);
		sub(m_server, "core:continue", &Module::on_continue);
		sub(m_server, "core:tick", &Module::on_tick);
		sub(m_server, "core:shutdown", &Module::save);
		sub(m_server, "client_file:files_transmitted",
				&Module::on_files_transmitted);
		sub(m_server, "network:client_disconnected",
				&Module::on_client_disconnected);
		sub(m_server, "accounts:login", &Module::on_login);
		sub(m_server, "worldgen:queue_modified",
				&Module::on_worldgen_queue_modified);
		sub(m_server, "voxelworld:section_loaded", &Module::on_section_loaded);
		sub(m_server, "voxelworld:generation_request",
				&Module::on_generation_request);
		sub(m_server, "worldgen:section_generated",
				&Module::on_section_generated);
		sub(m_server, "voxelworld:section_unloaded",
				&Module::on_section_unloaded);
		sub(m_server, "world_menu:play", &Module::on_world_play);
		const ss_ game = "network:packet_received/skeldat:";
		sub(m_server, game+"admin", &Module::on_admin);
		// The rest of the game's packets go to one handler, by name
		for(const char *n : {"open", "close", "move", "craft", "respawn",
				"bow", "intro", "scores", "rerun"})
			sub(m_server, game+n, &Module::on_game_packet);
		// What a player does in the world: builtin/luanti's session
		// (luanti/session.h), its calls this Module's (Game, below)
		for(const char *n : luanti_session::PACKETS)
			sub<network::Packet>(m_server,
					ss_("network:packet_received/luanti:")+n,
					[this](const network::Packet &p){ m_session.packet(p); });
	}

	//
	// The world dialog
	//

	void on_start()
	{
		start(true);
	}

	// pick: start the world the environment or the launch names
	void start(bool pick)
	{
		// The day's schedule, luanti_client's ([SKY_RENDER_SHARED]: the sky's
		// render is extensions/sky_render, meta.json's client_extensions),
		// and Luanti's touch controls ([SKELDAT_TOUCH]), as builtin/luanti
		// serves them
		const ss_ res = m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res/";
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_path("luanti/sky_model.lua", res+"sky_model.lua");
			i->add_file_path("luanti/touch.lua", res+"touch.lua");
		});
		serve_media();
		world_menu::access(m_server, [&](world_menu::Interface *i){
			world_menu::Field size{"size", "Size", "", "", false};
			// [SKELDAT_WORLD_SIZES]: start_world() reads it; the first the
			// default ([SKELDAT_TUNE_256]: 256, the others in size order)
			size.choices = {{"256", "256 x 64 x 256"},
				{"128", "128 x 64 x 128"}, {"512", "512 x 128 x 512"},
				{"1024", "1024 x 128 x 1024"}};
			// [SKELDAT_BONE_SPEED]: start_world() reads it too
			world_menu::Field speed{"speed", "Bone speed", "", "", false};
			speed.choices = {{"1", "1x"}, {"2", "2x"}, {"5", "5x"},
				{"10", "10x"}};
			i->configure({"skeldat", {{"seed", "Seed", "", "empty: random"},
					size, speed,
					// The high score, written at the end (step_end())
					{"ended", "The surface all bones after", "", "", true},
					// Who played it, with their hours ([SKELDAT_HIGH_SCORES])
					{"players", "Players", "", "", true}}});
		});
		send_presets();
		// The launcher's picked world ([SKELDAT_LAUNCH_WORLD]), the launch's
		// save=; BUILDAT_SKELDAT_WORLD, a check's, made if it is not there
		const char *name = getenv("BUILDAT_SKELDAT_WORLD");
		if(!pick){
		} else if(name && name[0]){
			start_world(name, true);
		} else {
			bool refused = false;
			const ss_ save = interface::launch_param(m_server->get_config().
					get<ss_>("untrusted_launch"), "save", &refused);
			if(refused)
				log_w(MODULE, "skeldat: the launch's save refused");
			if(!save.empty() && !start_world(save, false))
				log_w(MODULE, "skeldat: the launch's save \"%s\" is no world: "
						"the menu", cs(save));
		}
	}

	// The textures the way a Luanti game's are found ([SKELDAT_LUANTI_PARTS]
	// 7): a texture pack, a directory under
	// <user>/shared/skeldat/texture_packs named by
	// BUILDAT_SKELDAT_TEXTURE_PACK, over main/client_data, LabPBR sidecars
	// and all. The pack's files go out as texture_pack/<name> and the
	// registry's tiles name those: client_data serves main/<name> itself,
	// and after this whatever the order.
	// simplified: the pack is picked by the environment and covers the
	// nodes, not the items' images; a pick in the admin's menu is the upgrade
	std::set<ss_> m_pack_files;
	void serve_media()
	{
		const char *pack = getenv("BUILDAT_SKELDAT_TEXTURE_PACK");
		sv_<std::pair<ss_, ss_>> name_paths;
		for(const auto &pair : luanti_media::collect(
				luanti_media::texture_pack_dirs(
				m_server->get_config().get<ss_>("user_path")+
				"/shared/skeldat/texture_packs", pack ? pack : ""))){
			m_pack_files.insert(pair.first);
			name_paths.push_back(std::make_pair("texture_pack/"+pair.first,
					pair.second));
		}
		if(name_paths.empty())
			return;
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_paths(name_paths);
		});
	}
	struct PackMedia: luanti_registry::Media
	{
		const std::set<ss_> &pack;
		PackMedia(const std::set<ss_> &pack): pack(pack){}
		ss_ texture(const ss_ &tile)
		{
			if(tile.compare(0, 5, "main/") == 0 && pack.count(tile.substr(5)))
				return "texture_pack/"+tile.substr(5);
			return tile;
		}
	};

	// A number is itself, other text its FNV-1a hash
	static uint32_t seed_of(const ss_ &text)
	{
		if(text.size() <= 10 &&
				text.find_first_not_of("0123456789") == ss_::npos)
			return (uint32_t)std::stoull(text);
		uint32_t h = 2166136261u;
		for(unsigned char c : text)
			h = (h ^ c) * 16777619u;
		return h;
	}

	// A world picked or made in builtin/world_menu; one that does not start
	// is the menu again
	void on_world_play(const world_menu::Play &event)
	{
		auto seed = event.options.find("seed");
		if(!start_world(event.name, false, seed == event.options.end() ?
				"" : seed->second))
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show(event.peer);
			});
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		const size_t peer = event.recipient;
		if(m_world_ready){
			show(peer);
			return;
		}
		// [WORLD_MENU_ADMIN] On a public server, while no world is picked,
		// the join first: only an admin picks one, and the first admin is
		// made with the setup code. on_login() goes on from there. A world
		// being made lets a guest wait for it, as a running one lets it in
		bool joined = m_starting;
		accounts::access(m_server, [&](accounts::Interface *i){
			joined = joined || i->launched() || !i->name_of(peer).empty();
		});
		if(!joined){
			m_joining.insert(peer);
			network::send(m_server, peer, "core:run_script",
					"buildat.run_script_file(\"main/join.lua\")");
			return;
		}
		menu_or_wait(peer);
	}

	void menu_or_wait(size_t peer)
	{
		if(m_waiting.insert(peer).second){
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show(peer);
			});
		}
	}

	// A join's login: the world if it runs, else the world menu (which
	// shows the list to an admin and the wait to the rest)
	void on_login(const accounts::Login &login)
	{
		if(!m_joining.erase(login.peer))
			return;
		if(m_world_ready)
			show(login.peer);
		else
			menu_or_wait(login.peer);
	}

	//
	// The world
	//

	// The save opened (made, when `create`), its seed `seed_text` when it
	// has none yet: a number, or any text hashed to one
	bool start_world(const ss_ &name, bool create, const ss_ &seed_text = "")
	{
		if(m_starting)
			return false;
		storage::access(m_server, [&](storage::Interface *i){
			if(!i->valid_name(name) || name[0] == '_')
				return;
			m_save = i->open(name);
			if(!m_save && create)
				m_save = i->create(name);
		});
		if(!m_save){
			log_w(MODULE, "skeldat: no world \"%s\"", cs(name));
			return false;
		}
		m_starting = true;
		m_store = m_save->store("skeldat");
		m_world_name = name;
		for(const ss_ &key : m_store->list("played/")){
			ss_ t;
			if(m_store->get(key, t))
				m_played[key.substr(7)] = atof(t.c_str());
		}
		// For a check: "name seconds; ..." added to the times
		if(const char *env = getenv("BUILDAT_SKELDAT_PLAYED")){
			std::istringstream ps(env);
			ss_ one;
			while(std::getline(ps, one, ';')){
				std::istringstream os(one);
				ss_ who;
				double secs = 0;
				if(os>>who>>secs)
					m_played[who] += secs;
			}
		}
		ss_ v;
		// A world with no seed yet is new, the world menu's made one too
		m_making = !m_store->get("seed", v);
		// The players wait for the whole world (world_in())
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->progress(m_making ? "Making the world..." :
					"Loading the world...");
		});
		uint32_t seed = m_rand();
		const char *env_seed = getenv("BUILDAT_SKELDAT_SEED");
		if(m_store->get("seed", v))
			seed = (uint32_t)std::stoul(v);
		else if(!seed_text.empty())
			seed = seed_of(seed_text);
		else if(env_seed && env_seed[0])
			seed = (uint32_t)std::stoul(env_seed);
		m_store->set("seed", itos(seed));
		if(m_store->get("day", v))
			m_day = atof(v.c_str());
		m_marker = id_of("skeldat:marker_skull");
		m_sun_ids = {id_of("skeldat:bone_block"), id_of("skeldat:skull"),
				id_of("skeldat:skulls"), m_marker};
		m_stuck_id = id_of("skeldat:stuck_arrow");
		if(m_store->get("world_t", v))
			m_world_t = atof(v.c_str());
		else if(const char *env = getenv("BUILDAT_SKELDAT_WORLD_T"))
			m_world_t = atof(env); // for a check: a new world's age, seconds
		if(m_store->get("ended", v)){
			m_ended = true;
			m_end_days = atof(v.c_str());
			if(m_store->get("ended_rank", v))
				std::istringstream(v)>>m_end_best>>m_end_place;
			log_i(MODULE, "skeldat: the world \"%s\" ended after %.1f days",
					cs(name), m_end_days);
		}
		// The size picked when it was made ([SKELDAT_WORLD_SIZES]): its
		// width; a world from before the choice is 1024, as it was made
		ss_ size = "1024";
		m_save->store("world_menu")->get("size", size);
		const int width = atoi(size.c_str());
		if(width == 512 || width == 1024)
			m_half = width / 128, m_y0 = -1, m_y1 = 0;
		else if(width == 256 || width == 128)
			m_half = width / 128, m_y0 = 0, m_y1 = 0;
		// For a check: a small world, "<half> <y0> <y1>" in sections
		const char *env_size = getenv("BUILDAT_SKELDAT_SIZE");
		if(env_size && env_size[0] && sscanf(env_size, "%d %d %d", &m_half,
				&m_y0, &m_y1) != 3)
			log_w(MODULE, "skeldat: BUILDAT_SKELDAT_SIZE=\"%s\" not read",
					env_size);
		// [SKELDAT_BONE_SPEED] Picked when it was made, or by the admin
		// since; none is 1x. BUILDAT_SKELDAT_SPEED for a check's new world.
		ss_ speed = "1";
		storage::Store *menu = m_save->store("world_menu");
		const char *env_speed = getenv("BUILDAT_SKELDAT_SPEED");
		if(!menu->get("speed", speed) && env_speed && env_speed[0]){
			speed = env_speed;
			menu->set("speed", speed);
		}
		m_speed = valid_speed(atoi(speed.c_str())) ? atoi(speed.c_str()) : 1;
		m_speed_low = m_speed;
		if(m_store->get("speed_low", v) && valid_speed(atoi(v.c_str())))
			m_speed_low = std::min(m_speed, atoi(v.c_str()));
		m_store->set("speed_low", itos(m_speed_low));
		if(const char *env = getenv("BUILDAT_SKELDAT_BUDGET"))
			m_budget = std::max(0.001, atof(env));
		log_i(MODULE, "skeldat: the bones at %dx (the lowest %dx)", m_speed,
				m_speed_low);
		m_markers.assign(footprints(), 0);
		if(m_store->get("holes", v)){
			std::istringstream is(v);
			long c;
			int day;
			while(is>>c>>day)
				m_hole_day[c] = day;
		}
		if(m_store->get("markers", v)){
			std::istringstream is(v);
			int all = 0;
			for(int &n : m_markers)
				is>>n, all += n;
			log_i(MODULE, "skeldat: %d marker skulls in the world", all);
		}
		if(const char *env = getenv("BUILDAT_SKELDAT_DAY"))
			if(atof(env) > 0)
				m_day_s = (float)atof(env);
		if(const char *env = getenv("BUILDAT_SKELDAT_LIGHT_STEP"))
			if(atof(env) > 0)
				m_light_step = (float)atof(env);
		if(const char *env = getenv("BUILDAT_SKELDAT_EXPAND"))
			if(atof(env) > 0)
				m_section_period = atof(env);
		// For a check: the time of day it starts at, 0.5 noon
		const char *env_time = getenv("BUILDAT_SKELDAT_TIME");
		if(env_time && env_time[0])
			m_day = atof(env_time);
		for(const ss_ &key : m_store->list("furnace/"))
			if(m_store->get(key, v))
				m_furnaces[key.substr(8)].load(v);
		for(const ss_ &key : m_store->list("mob/")){
			Mob m;
			const uint32_t k = (uint32_t)atol(key.c_str() + 4);
			if(m_store->get(key, v) && m.load(v)){
				m.light_t = rnd() * m_light_step;
				m_mobs[k] = m;
				m_next_mob = std::max(m_next_mob, k + 1);
			}
		}
		for(const ss_ &key : m_store->list("stuck/"))
			m_stuck.insert(key.substr(6));
		for(const ss_ &key : m_store->list("drop/")){
			Drop d;
			ss_ item;
			std::istringstream is;
			if(m_store->get(key, v) && (is.str(v), is>>d.x>>d.y>>d.z>>d.age) &&
					std::getline(is>>std::ws, item) &&
					!(d.st = Stack::parse(item)).empty())
				m_drops.push_back(d);
		}
		if(!m_drops.empty())
			log_i(MODULE, "skeldat: %zu drops on the ground", m_drops.size());
		if(const char *env = getenv("BUILDAT_SKELDAT_TEST"))
			m_test = env;
		log_i(MODULE, "skeldat: the world \"%s\" starts, seed %u, %zu "
				"furnaces, %zu mobs, %d x %d x %d", cs(name), seed,
				m_furnaces.size(), m_mobs.size(), 2 * m_half * 64,
				(m_y1 - m_y0 + 1) * 64, 2 * m_half * 64);
		create_world(seed);
		return true;
	}

	uint32_t id_of(const ss_ &name) const
	{
		for(size_t i = 0; i < m_game.nodes.size(); i++)
			if(m_game.nodes[i].name == name)
				return (uint32_t)i + ID_NODE0;
		return name == "air" ? ID_AIR : ID_IGNORE;
	}
	const skeldat::NodeDef* node_of(uint32_t id) const
	{
		return id >= ID_NODE0 && id - ID_NODE0 < m_game.nodes.size() ?
				&m_game.nodes[id - ID_NODE0] : nullptr;
	}

	void create_world(uint32_t seed)
	{
		m_scene = main_context::create_scene(m_server);
		m_mapgen = mapgen_params(seed);
		worldgen::GeneratorInterface *generator = nullptr;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *i){
			generator = i->create_generator(m_mapgen);
		});
		// Before the voxelworld, or its first requests are lost
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->create_instance(m_scene);
			BonesGenerator::PileIds ids;
			ids.block = id_of("skeldat:bone_block");
			ids.tops[0] = id_of("skeldat:skull");
			ids.tops[1] = id_of("skeldat:skulls");
			ids.tops[2] = id_of("skeldat:bone_lying");
			ids.ground[0] = id_of("skeldat:grass");
			ids.ground[1] = id_of("skeldat:dirt");
			ids.ground[2] = id_of("skeldat:sand");
			m_generator = new BonesGenerator(generator, m_format, m_bones,
					m_mapgen.seed, ids);
			const char *fill = getenv("BUILDAT_SKELDAT_FILL");
			m_generator->m_half_v = m_half * skeldat::bones::SECTION;
			m_generator->m_fill = !fill ? 0 : ss_(fill) == "1" ? 1 :
					ss_(fill) == "half" ? 2 : ss_(fill) == "surface" ? 3 : 0;
			i->get_instance(m_scene)->set_generator(m_generator);
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			// The world's bounds in sections ([SKELDAT_BOUNDED_WORLD])
			i->create_instance(m_scene, pv::Region(-m_half, m_y0, -m_half,
					m_half - 1, m_y1, m_half - 1));
		});
		// Before voxelworld's first tick, which loads a whole region that
		// has no load points
		update_load_points();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			reg->set_format(m_format);
			build_registry(reg);
			w->set_save(m_save, "main");
			// The mapgen lights what it builds; voxelworld keeps it up as
			// the world changes, the torches' too
			w->set_light_maintained(voxelworld::Instance::LIGHT_SKY, true);
			w->set_light_maintained(voxelworld::Instance::LIGHT_LAMP, true);
		});
		worldgen::access(m_server, m_scene, [&](worldgen::Instance *i){
			i->enable();
		});
	}

	// Luanti's unknown and air, then the nodes at their ids
	void build_registry(interface::VoxelRegistry *reg)
	{
		luanti_registry::Builder builder;
		PackMedia media(m_pack_files);
		for(uint32_t id = ID_UNKNOWN; id < ID_NODE0 + m_game.nodes.size();
				id++){
			luanti_registry::NodeDef d = luanti_def(id);
			interface::VoxelDefinition v = builder.build(d, media);
			const interface::VoxelTypeId got = reg->add_voxel(v);
			if(got != id)
				throw Exception("skeldat: voxel "+d.name+" is id "+
						itos(got)+", not "+itos(id));
		}
	}

	// A voxel id's node as Luanti would have it defined, which is what
	// builtin/luanti's registry builder and the mapgen read
	luanti_registry::NodeDef luanti_def(uint32_t id)
	{
		luanti_registry::NodeDef d;
		if(id == ID_AIR){
			d.name = "air";
			d.drawtype = "airlike";
			d.empty = true;
			d.walkable = false;
			d.pointable = 0;
			d.sunlight = true;
			d.param_type_light = true;
			d.floodable = true;
			return d;
		}
		// Never generated; drawn as stone if a save has one
		const skeldat::NodeDef &n = node_of(id) ? *node_of(id) :
				*node_of(id_of("skeldat:stone"));
		d.name = node_of(id) ? n.name : "unknown";
		d.groups = n.groups;
		d.light_source = (uint8_t)n.light_source;
		d.has_tiles = true;
		for(int i = 0; i < 6; i++)
			d.tiles[i] = n.tiles[i];
		d.param_type_light = n.shape != skeldat::CUBE;
		// Leaves let light in but not the sun, as Luanti's do
		d.sunlight = n.shape == skeldat::NODEBOX || n.shape == skeldat::TORCH;
		switch(n.shape){
		case skeldat::CUBE:
			break;
		case skeldat::ALLFACES:
			d.drawtype = "allfaces_optional";
			d.alpha_clip = true;
			break;
		case skeldat::LIQUID:
			d.drawtype = "liquid";
			d.liquid_group = n.name;
			d.walkable = false;
			d.swimmable = true;
			d.pointable = 0;
			break;
		case skeldat::NODEBOX:
			d.drawtype = "nodebox";
			d.node_box = d.selection_box = n.boxes;
			if(n.walkable)
				d.collision_box = n.boxes;
			else
				d.walkable = false;
			break;
		case skeldat::TORCH:
			d.drawtype = "torchlike";
			d.walkable = false;
			d.alpha_clip = true;
			d.selection_box = n.boxes;
			break;
		}
		// param2 0 to 3, the way the player looked when placing it
		if(n.facedir)
			d.facing = "4dir";
		if(n.wallmounted)
			d.facing = "wallmounted";
		return d;
	}

	luanti_mapgen::Params mapgen_params(uint32_t seed)
	{
		luanti_mapgen::Params mp;
		mp.mgname = "valleys";
		mp.seed = seed;
		// A world 64 high ([SKELDAT_WORLD_SIZES]) is y 0..63, its water at
		// 20; one 128 high is y -64..63, water at 1
		const bool low = m_y0 >= 0;
		const int wl = low ? 20 : 1, lift = wl - 1;
		mp.water_level = wl;
		mp.section_size = skeldat::bones::SECTION;
		// The terrain's spreads by the world's width, not under 128, so a
		// small world still has a valley and a hill
		const float width = 2.0f * m_half * skeldat::bones::SECTION,
				th_spread = std::max(128.0f, width),
				vd_spread = std::max(128.0f, width / 2);
		// The valleys squeezed into the world's 128 voxels of height
		// ([SKELDAT_BOUNDED_WORLD]): over 1024² at seeds 1-12 the top
		// solid voxel is at -6..54, where the defaults' is at -67..258.
		// Spreads, seeds, octaves and the rest are the mapgen's defaults.
		auto noise = [&](const char *name, float offset, float scale,
				float spread, int32_t seed, int32_t octaves, float persist){
			luanti_mapgen::Params::NoiseParams np;
			np.given = true;
			np.offset = offset;
			np.scale = scale;
			np.spread_x = np.spread_y = np.spread_z = spread;
			np.seed = seed;
			np.octaves = octaves;
			np.persist = persist;
			mp.noises[name] = np;
		};
		// 64 high: over seeds 1-12 the top solid voxel at 11..44 (the
		// survey as for the 128 one, at widths 256 and 128)
		if(low){
			noise("mgvalleys_np_terrain_height", 22, 10, th_spread, 5202, 6,
					0.4f);
			noise("mgvalleys_np_valley_depth", 1.5f, 0.8f, vd_spread, -1914,
					1, 1.0f);
		} else {
			noise("mgvalleys_np_terrain_height", 8, 12, th_spread, 5202, 6,
					0.4f);
			noise("mgvalleys_np_valley_depth", 2.5f, 1.2f, vd_spread, -1914,
					1, 1.0f);
		}
		noise("mgvalleys_np_inter_valley_slope", 0.3f, 0.3f, 128, 746, 1,
				1.0f);
		for(size_t i = 0; i < m_game.nodes.size(); i++)
			mp.content_ids[m_game.nodes[i].name] = (uint32_t)i + ID_NODE0;
		mp.content_ids["air"] = ID_AIR;
		mp.content_ids["ignore"] = ID_IGNORE;
		mp.content_ids["unknown"] = ID_UNKNOWN;
		const uint32_t stone = id_of("skeldat:stone"),
				water = id_of("skeldat:water_source");
		mp.content_ids["mapgen_stone"] = stone;
		mp.content_ids["mapgen_water_source"] = water;
		mp.content_ids["mapgen_river_water_source"] = water;
		mp.content_ids["mapgen_cobble"] = id_of("skeldat:cobble");
		for(uint32_t id = ID_AIR; id < ID_NODE0 + m_game.nodes.size(); id++)
			if(id == ID_AIR || node_of(id))
				mp.node_props[id] = luanti_registry::mapgen_props(luanti_def(id));
		auto biome = [&](const ss_ &name, const ss_ &top, int depth_top,
				const ss_ &filler, int depth_filler, const ss_ &riverbed,
				int y_min, int y_max){
			luanti_mapgen::Params::Biome b;
			b.name = name;
			b.c_top = id_of(top);
			b.c_filler = id_of(filler);
			b.c_stone = stone;
			b.c_water_top = b.c_water = b.c_river_water = water;
			b.c_riverbed = riverbed.empty() ? stone : id_of(riverbed);
			b.c_dust = b.c_dungeon = b.c_dungeon_alt = b.c_dungeon_stair =
					ID_IGNORE;
			b.depth_top = depth_top;
			b.depth_filler = depth_filler;
			b.depth_riverbed = riverbed.empty() ? 0 : 2;
			b.y_min = y_min;
			b.y_max = y_max;
			b.heat_point = b.humidity_point = 50;
			mp.biomes.push_back(b);
		};
		biome("grassland", "skeldat:grass", 1, "skeldat:dirt", 3,
				"skeldat:sand", 4 + lift, 31000);
		biome("beach", "skeldat:sand", 1, "skeldat:sand", 2, "skeldat:sand",
				-6 + lift, 3 + lift);
		biome("seabed", "skeldat:gravel", 1, "skeldat:sand", 2, "",
				-31000, -7 + lift);
		auto ore = [&](const ss_ &name, int scarcity, int num, int y_max,
				int y_min){
			luanti_mapgen::Params::Ore o;
			o.name = name;
			o.c_ore = id_of(name);
			o.c_wherein = {stone};
			o.clust_scarcity = scarcity;
			o.clust_num_ores = num;
			o.clust_size = 3;
			o.y_min = y_min;
			o.y_max = y_max;
			mp.ores.push_back(o);
		};
		ore("skeldat:coal_ore", 8 * 8 * 8, 8, 64, -31000);
		// 64 high, each still under the surface (11 and up)
		ore("skeldat:iron_ore", 10 * 10 * 10, 5, low ? 14 : 0, -31000);
		ore("skeldat:diamond_ore", 15 * 15 * 15, 4, low ? 6 : -48, -31000);
		ore("skeldat:gravel", 16 * 16 * 16, 20, 64, -31000);
		ore("skeldat:dirt", 16 * 16 * 16, 20, 64, low ? 4 : -32);
		// A tree, 5x6x5: a trunk of four, leaves around its top two and
		// over it
		luanti_mapgen::Params::Decoration d;
		d.name = "skeldat:tree";
		d.type = "schematic";
		d.c_place_on = {id_of("skeldat:grass")};
		d.sidelen = 16;
		d.fill_ratio = 0.006f;
		d.biomes = {"grassland"};
		d.y_min = 4 + lift;
		d.y_max = 200;
		d.flags = "place_center_x, place_center_z";
		// Luanti puts a schematic's layer 0 at the place_on node, and the
		// force-placed trunk took the grass: one up, the trunk on it
		// ([SKELDAT_TREE_DEPTH])
		d.place_offset_y = 1;
		d.rotation = "random";
		luanti_mapgen::Params::Schematic &s = d.schematic;
		s.given = true;
		s.size_x = 5; s.size_y = 6; s.size_z = 5;
		s.node_names = {"skeldat:tree", "skeldat:leaves", "air"};
		for(int z = 0; z < 5; z++) for(int y = 0; y < 6; y++)
		for(int x = 0; x < 5; x++){
			const bool trunk = x == 2 && z == 2 && y < 4;
			const bool edge = (x == 0 || x == 4) && (z == 0 || z == 4);
			const bool inner = x >= 1 && x <= 3 && z >= 1 && z <= 3;
			const bool leaf = ((y == 2 || y == 3) && !edge) ||
					(y == 4 && inner) ||
					(y == 5 && (x == 2 || z == 2) && inner);
			s.ids.push_back(trunk ? 0 : leaf ? 1 : 2);
			// Half the probability, and force_place in the high bit, as
			// a .mts file holds it
			s.param1.push_back(trunk ? 127 + 128 : leaf ? 127 : 0);
			s.param2.push_back(0);
		}
		mp.decorations.push_back(d);
		return mp;
	}

	// Luanti's spawn search: out from the origin until the mapgen says a
	// column is land, kept in the save so that it does not move
	// Where a player starts, found on the world once it is in: a dry
	// column near the origin with no bones, not a tree top, read off the
	// voxels (valleys' own spawn level refuses any ground over water level
	// + 16, half of this world's)
	void find_spawn()
	{
		using namespace skeldat::bones;
		ss_ v;
		if(m_store->get("spawn", v)){
			std::istringstream(v)>>m_spawn[0]>>m_spawn[1]>>m_spawn[2];
			m_spawn_ready = true;
			return;
		}
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			// The feet's y on the column's top, or false for water or a tree
			const int y1 = (m_y1 + 1) * SECTION - 1, y0 = m_y0 * SECTION;
			auto ground = [&](int x, int z, int &feet){
				for(int y = y1 - 2; y > y0; y--){
					if(!walkable(w, x, y, z)){
						if(is_water(w, x, y, z))
							return false;
						continue;
					}
					const skeldat::NodeDef *n = node_of(wid(w, x, y, z));
					if(n && (n->name.find("leaves") != ss_::npos ||
							n->name.find("tree") != ss_::npos))
						return false;
					feet = y + 1;
					return true;
				}
				return false;
			};
			// For a check: the spawn's column, the zones allowed, "x z" or
			// "x y z" (a place under the ground: a cave)
			const char *env = getenv("BUILDAT_SKELDAT_SPAWN");
			int ex = 0, ey = 0, ez = 0;
			const int got = env ? sscanf(env, "%d %d %d", &ex, &ey, &ez) : 0;
			if(got == 2){
				ez = ey;
				ey = y1;
				ground(ex, ez, ey);
			}
			if(got >= 2){
				m_spawn[0] = (float)ex;
				m_spawn[1] = (float)ey;
				m_spawn[2] = (float)ez;
				m_spawn_ready = true;
			}
			std::mt19937 r(m_mapgen.seed);
			for(int i = 0; i < 4000 && !m_spawn_ready; i++){
				const int range = std::min(32 + i / 4, m_half * SECTION - 16);
				const int x = (int)(r() % (2 * range)) - range;
				const int z = (int)(r() % (2 * range)) - range;
				int feet = 0;
				if(!ground(x, z, feet) || feet < m_mapgen.water_level + 1 ||
						seed_value(skeldat::bones::danger(
						(uint32_t)m_mapgen.seed, (float)x, (float)z,
						m_half * SECTION)) > 0)
					continue;
				m_spawn[0] = (float)x;
				m_spawn[1] = (float)feet;
				m_spawn[2] = (float)z;
				m_spawn_ready = true;
			}
			// [SKELDAT_STARTER_ITEMS]: a bow and 4 arrows' worth near a new
			// world's spawn, once (a stored spawn returned above); scattered
			// 3 to 6 voxels off, on the ground, else on the spawn's column
			const char *starter = getenv("BUILDAT_SKELDAT_STARTER");
			if(!m_spawn_ready || (starter && ss_(starter) == "0"))
				return;
			const int sx = (int)m_spawn[0], sz = (int)m_spawn[2];
			for(int i = 0; i < 8; i++){
				int x = sx, z = sz, feet = (int)m_spawn[1];
				for(int k = 0; k < 8; k++){
					const int dx = (int)(r() % 13) - 6, dz = (int)(r() % 13) - 6;
					int f = 0;
					if(std::max(std::abs(dx), std::abs(dz)) >= 3 &&
							ground(sx + dx, sz + dz, f)){
						x = sx + dx, z = sz + dz, feet = f;
						break;
					}
				}
				drop(Stack(i < 4 ? "skeldat:stick" : "skeldat:bone"),
						(float)x, (float)feet + 0.5f, (float)z);
			}
		});
		if(!m_spawn_ready){
			m_spawn[1] = (float)((m_y1 + 1) * SECTION - 1);
			m_spawn_ready = true;
		}
		std::ostringstream os;
		os<<m_spawn[0]<<" "<<m_spawn[1]<<" "<<m_spawn[2];
		m_store->set("spawn", os.str());
		log_i(MODULE, "skeldat: spawn at %s", cs(os.str()));
	}

	void update_load_points()
	{
		// The whole world, always ([SKELDAT_BOUNDED_WORLD]): the region
		// clips the radius
		sv_<voxelworld::LoadPoint> points;
		points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(0, 0, 0),
				m_half, std::max(-m_y0, m_y1), m_half, std::max(-m_y0, m_y1)));
		for(auto &pair : m_players){
			const Player &pl = pair.second;
			if(!pl.placed)
				continue;
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					(int)std::floor(pl.x), (int)std::floor(pl.y),
					(int)std::floor(pl.z)), 3, 2, 2, 1, pair.first));
		}
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			w->set_load_points(points);
			w->set_stream_budget(m_worldgen_queue >= 12 ? 0 : 2);
		});
		m_load_points_dirty = false;
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &e)
	{
		m_worldgen_queue = e.queue_size;
		m_load_points_dirty = true;
	}

	//
	// The bones (bones.h)
	//

	static ss_ section_key(const pv::Vector3DInt16 &sp)
	{
		return pos_key(sp.getX(), sp.getY(), sp.getZ());
	}

	// Merged padding loads the sections around the world too
	bool in_world(const pv::Vector3DInt16 &sp) const
	{
		return sp.getX() >= -m_half && sp.getX() < m_half &&
				sp.getZ() >= -m_half && sp.getZ() < m_half &&
				sp.getY() >= m_y0 && sp.getY() <= m_y1;
	}

	void on_section_loaded(const voxelworld::SectionLoaded &e)
	{
		if(e.scene != m_scene || !m_save || !in_world(e.section_p))
			return;
		m_sections.insert(section_key(e.section_p));
		m_recount.insert(section_key(e.section_p));
		// The world coming in ([SKELDAT_BOUNDED_WORLD]): a line every
		// sixteenth, and the time it took
		const size_t all = all_sections();
		if(m_sections.size() % std::max<size_t>(1, all / 16) == 0 &&
				!m_world_ready){
			log_i(MODULE, "skeldat: %zu of %zu sections loaded, %.1f s, the "
					"highest voxel made at y %d", m_sections.size(), all,
					(interface::os::time_us() - m_start_us) / 1e6,
					m_generator ? (int)m_generator->m_top : 0);
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->progress(ss_(m_making ? "Making" : "Loading")+
						" the world: "+itos(m_sections.size())+
						" of "+itos(all)+" sections");
			});
		}
	}

	void on_generation_request(const voxelworld::GenerationRequest &e)
	{
		if(e.scene == m_scene && in_world(e.section_p))
			m_awaiting.insert(section_key(e.section_p));
	}

	void on_section_generated(const worldgen::SectionGenerated &e)
	{
		if(e.scene != m_scene || !in_world(e.section_p))
			return;
		m_awaiting.erase(section_key(e.section_p));
		m_recount.insert(section_key(e.section_p));
	}

	// The whole world in: the spawn found on it and the players let in
	void world_in()
	{
		m_world_ready = true;
		find_spawn();
		const int64_t t0 = interface::os::time_us();
		m_flooded.assign(footprints(), 0);
		const size_t cols = footprints() * skeldat::bones::SECTION *
				skeldat::bones::SECTION;
		m_top_y.assign(cols, NO_GROUND);
		m_top_b.assign(cols, 0);
		size_t bench = 0;
		if(const char *env = getenv("BUILDAT_SKELDAT_SKELETONS"))
			bench = (size_t)atol(env);
		// For a check: "sx sz n", footprint (sx, sz)'s marker count, the
		// skulls themselves not placed
		int mx, mz, mn;
		if(const char *env = getenv("BUILDAT_SKELDAT_MARKERS"))
			if(sscanf(env, "%d %d %d", &mx, &mz, &mn) == 3 &&
					footprint(mx * skeldat::bones::SECTION,
					mz * skeldat::bones::SECTION) >= 0)
				m_markers[footprint(mx * skeldat::bones::SECTION,
						mz * skeldat::bones::SECTION)] = mn;
		size_t added = 0;
		make_edge();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(size_t i = 0; i < footprints(); i++)
				sweep(w, i);
			// For a check: that many more light skeletons, anywhere
		});
		{
			const int h = m_half * skeldat::bones::SECTION;
			double sum = 0;
			size_t n = 0;
			int low = 1 << 30;
			for(int a = -h; a < h; a++)
				for(const auto &xz : {std::make_pair(a, -h),
						std::make_pair(a, h - 1), std::make_pair(-h, a),
						std::make_pair(h - 1, a)}){
					const long c = column(xz.first, xz.second);
					if(c >= 0 && m_top_y[c] != NO_GROUND)
						sum += m_top_y[c], n++, low = std::min(low,
								(int)m_top_y[c]);
				}
			m_edge_crest = n ? (float)(sum / n) + 1 : 0;
			m_edge_low = n ? low : 0;
		}
		// Not in a check's own set of mobs (TEST: no spawning; the bench,
		// 0 an empty world)
		if(m_test.empty() && !getenv("BUILDAT_SKELDAT_SKELETONS"))
			populate();
		for(size_t t = 0; t < 8 * bench && added < bench; t++)
			added += add_skeleton(false);
		if(getenv("BUILDAT_SKELDAT_SURVEY"))
			survey();
		if(const char *env = getenv("BUILDAT_SKELDAT_LANTERNS")){
			test_lanterns(env);
			m_lantern_report = true;
		}
		log_i(MODULE, "skeldat: the columns swept in %.1f ms%s",
				(interface::os::time_us() - t0) / 1e3, bench ?
				cs(", "+itos(added)+" skeletons added") : "");
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->set_running(true);
		});
		log_i(MODULE, "skeldat: the world is in, %.1f s",
				(interface::os::time_us() - m_start_us) / 1e6);
		for(size_t peer : m_waiting)
			show(peer);
		m_waiting.clear();
	}

	void on_section_unloaded(const voxelworld::SectionUnloaded &e)
	{
		if(e.scene != m_scene || !m_save)
			return;
		m_sections.erase(section_key(e.section_p));
	}

	// Every loaded section expands every SECTION_PERIOD on average, picked
	// at random
	void step_bones(float dtime)
	{
		if(m_sections.empty())
			return;
		const double rate = m_sections.size() / m_section_period;
		m_expand_due += dtime * rate;
		m_ticked_s += dtime;
		m_budget_left = std::min(m_budget_left + m_budget,
				std::max(m_budget, 1.0));
		int budget = (int)m_budget_left;
		m_budget_left -= budget;
		while(m_expand_due >= 1 && budget-- > 0){
			m_expand_due -= 1;
			auto it = m_sections.begin();
			std::advance(it, m_rand() % m_sections.size());
			expand(*it);
		}
		// What the budget did not reach is dropped, not carried: a server
		// that falls behind grows the bones slower rather than in a burst
		if(m_expand_due > 1){
			m_dropped_n += m_expand_due - 1;
			m_expand_due = 1;
		}
		// Behind, said once a minute of real time to everyone
		const int64_t now = interface::os::time_us();
		if(m_keep_up_us == 0)
			m_keep_up_us = now;
		if(now - m_keep_up_us < 60000000)
			return;
		const double due = (now - m_keep_up_us) / 1e6 * rate;
		const double ratio = due > 0 ?
				(m_ticked_s * rate - m_dropped_n) / due : 1;
		if(ratio < 0.95 && !m_players.empty() && !m_ended){
			const double at = m_speed * ratio;
			char line[120];
			snprintf(line, sizeof line, "The server can't keep up with %dx "
					"bones: about %.*fx this last minute", m_speed,
					at < 2 ? 1 : 0, at);
			log_i(MODULE, "skeldat: %s", line);
			chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		}
		m_keep_up_us = now;
		m_ticked_s = m_dropped_n = 0;
	}

	// One expansion of a section, written back in one set_volume of the
	// voxels it changed
	void expand(const ss_ &key)
	{
		int sx, sy, sz;
		char c;
		std::istringstream is(key);
		if(!(is>>sx>>c>>sy>>c>>sz))
			return;
		const pv::Vector3DInt16 sp(sx, sy, sz);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			if(!w->is_section_loaded(sp))
				return;
			const pv::Region section = w->get_section_region_voxels(sp);
			pv::Region grown = section;
			grown.setLowerCorner(grown.getLowerCorner() -
					pv::Vector3DInt32(1, 1, 1));
			grown.setUpperCorner(grown.getUpperCorner() +
					pv::Vector3DInt32(1, 1, 1));
			interface::VoxelVolume vol = w->get_volume(grown);
			if(!vol.plane_is_materialised(1))
				return; // no bones in it nor around it
			const pv::Vector3DInt32 &lc = grown.getLowerCorner();
			skeldat::bones::Box box(vol.getWidth(), vol.getHeight(),
					vol.getDepth());
			bool any = false;
			for(int z = 0; z < box.d; z++)
			for(int y = 0; y < box.h; y++)
			for(int x = 0; x < box.w; x++){
				const interface::VoxelSample v = vol.sample_at(
						lc.getX() + x, lc.getY() + y, lc.getZ() + z);
				const uint32_t id = m_format.id.get(v);
				const size_t i = box.at(x, y, z);
				box.air[i] = !holds_bones(id);
				box.b[i] = (uint8_t)m_bones.get(v);
				any = any || box.b[i] != 0;
			}
			if(!any)
				return;
			// Burning lanterns' spheres are air to the flood (nothing
			// gains, nothing floods through); in them the bones fall by
			// one now and then, and bone blocks go
			const sv_<pv::Vector3DInt32> lit = lanterns_in(grown);
			const sv_<uint8_t> air = box.air;
			sv_<uint8_t> guard;
			if(!lit.empty()){
				guard.assign(box.b.size(), 0);
				const int R2 = LANTERN_RADIUS * LANTERN_RADIUS;
				for(int z = 0; z < box.d; z++)
				for(int y = 0; y < box.h; y++)
				for(int x = 0; x < box.w; x++)
				for(const pv::Vector3DInt32 &l : lit){
					const int dx = lc.getX() + x - l.getX(),
							dy = lc.getY() + y - l.getY(),
							dz = lc.getZ() + z - l.getZ();
					if(dx * dx + dy * dy + dz * dz <= R2){
						guard[box.at(x, y, z)] = 1;
						box.air[box.at(x, y, z)] = 1;
						break;
					}
				}
			}
			const sv_<uint8_t> before = box.b;
			m_expansions++;
			for(int k = 0; k < m_speed; k++)
				skeldat::bones::expand(box);
			m_rule_runs += m_speed;
			const uint32_t block = id_of("skeldat:bone_block");
			sv_<pv::Vector3DInt32> decayed;
			if(!guard.empty()){
				for(int z = 1; z < box.d - 1; z++)
				for(int y = 1; y < box.h - 1; y++)
				for(int x = 1; x < box.w - 1; x++){
					const size_t i = box.at(x, y, z);
					if(!guard[i] || air[i])
						continue;
					const int retract = LANTERN_RETRACT * m_speed;
					box.b[i] = before[i] > retract ? before[i] - retract : 0;
					const pv::Vector3DInt32 p(lc.getX() + x, lc.getY() + y,
							lc.getZ() + z);
					if(m_format.id.get(vol.sample_at(p.getX(), p.getY(),
							p.getZ())) == block &&
							rnd() < 1 - std::pow(1 - 1.0 / LANTERN_DECAY_IN,
							m_speed))
						decayed.push_back(p);
				}
			}
			m_recount.insert(key);
			interface::VoxelVolume out(section, m_format.planes);
			size_t changed = 0;
			for(int z = 1; z < box.d - 1; z++)
			for(int y = 1; y < box.h - 1; y++)
			for(int x = 1; x < box.w - 1; x++){
				const size_t i = box.at(x, y, z);
				if(box.b[i] == before[i])
					continue;
				const int32_t px = lc.getX() + x, py = lc.getY() + y,
						pz = lc.getZ() + z;
				interface::VoxelSample v = vol.sample_at(px, py, pz);
				m_bones.set(v, box.b[i]);
				out.set_sample_at(px, py, pz, v);
				changed++;
			}
			m_expand_changed += changed;
			// The light as it was read: nothing here changes it
			if(changed)
				w->set_volume(out, false, true);
			interface::VoxelSample gone;
			m_format.id.set(gone.planes[0], ID_AIR);
			if(!decayed.empty())
				m_recount.insert(key);
			for(const pv::Vector3DInt32 &p : decayed){
				w->set_sample(p, gone);
				rescan_column(w, p.getX(), p.getZ());
				log_i(MODULE, "skeldat: a bone block at %d,%d,%d goes",
						p.getX(), p.getY(), p.getZ());
			}
			grow(w, vol, box, guard);
		});
	}

	// Bones off the voxels at MAX with air over them, now and then
	// (bones::GROW_ONE_IN): a bone block on a bone block stacks to
	// STACK_MAX; a skull, two or a bone tops nothing. Not into a burning
	// lantern's sphere (`guard`, empty when none reaches the box)
	void grow(voxelworld::Instance *w, const interface::VoxelVolume &vol,
			const skeldat::bones::Box &box, const sv_<uint8_t> &guard)
	{
		using namespace skeldat::bones;
		const uint32_t block = id_of("skeldat:bone_block");
		const uint32_t tops[3] = {id_of("skeldat:skull"),
				id_of("skeldat:skulls"), id_of("skeldat:bone_lying")};
		const pv::Vector3DInt32 lc = vol.getEnclosingRegion().getLowerCorner();
		for(int z = 1; z < box.d - 1; z++)
		for(int y = 1; y < box.h - 2; y++)
		for(int x = 1; x < box.w - 1; x++){
			const size_t i = box.at(x, y, z);
			if(box.b[i] < MAX || box.air[i] ||
					m_rand() % GROW_ONE_IN >= (uint32_t)m_speed ||
					(!guard.empty() && guard[box.at(x, y + 1, z)]))
				continue;
			const int32_t px = lc.getX() + x, py = lc.getY() + y,
					pz = lc.getZ() + z;
			if(m_format.id.get(vol.sample_at(px, py + 1, pz)) != ID_AIR)
				continue;
			const uint32_t id = m_format.id.get(vol.sample_at(px, py, pz));
			if(id == tops[0] || id == tops[1] || id == tops[2])
				continue;
			int height = 0;
			while(height < STACK_MAX && py - height >= lc.getY() &&
					m_format.id.get(vol.sample_at(px, py - height, pz)) == block)
				height++;
			uint32_t grown = block;
			if(height >= STACK_MAX || (height == 0 && m_rand() % 2))
				grown = tops[m_rand() % 3];
			else if(height > 0 && m_rand() % 3 == 0)
				grown = tops[m_rand() % 3];
			interface::VoxelSample v;
			m_format.id.set(v.planes[0], grown);
			m_format.param.set(v.planes[0], grown == block ? 0 : m_rand() % 4);
			m_bones.set(v, MAX);
			w->set_sample(pv::Vector3DInt32(px, py + 1, pz), v);
			m_grown++;
		}
	}

	//
	// The players
	//

	// Once per peer: files_transmitted comes again after each batch
	void show(size_t peer)
	{
		if(!m_shown.insert(peer).second)
			return;
		ss_ name;
		accounts::access(m_server, [&](accounts::Interface *i){
			name = i->name_of(peer);
		});
		// A peer without an account is "client<peer>", which accounts keeps
		// from new accounts (reserved_name()): "player<peer>" was any
		// account's of that name, its inventory and its chat name
		if(name.empty())
			name = "client"+itos(peer);
		m_session.join(name, peer, false);
	}

	//
	// The session's calls (luanti_session::Game), by the player's name.
	// Placed at the join; in the world when the client says it has the
	// world loaded (luanti:world_in), which changes nothing here.
	// The leave is on_client_disconnected's.
	//

	luanti_session::Session m_session{*this};

	void place_player(const ss_ &name, size_t peer)
	{
		Player &pl = m_players[peer];
		pl.name = name;
		ss_ v;
		if(m_save->store("skeldat_players")->get(name, v))
			pl.load(v);
		else
			pl.intro = !getenv("BUILDAT_SKELDAT_INTRO") ||
					ss_(getenv("BUILDAT_SKELDAT_INTRO")) != "0";
		network::send(m_server, peer, "core:run_script",
				"buildat.run_script_file(\"main/init.lua\")");
		network::send(m_server, peer, "skeldat:items", items_text());
		update_role(peer, pl, true);
		chat::access(m_server, [&](chat::Interface *c){ c->join(peer, name); });
		replicate::assign_scene_to_peer(m_server, m_scene, peer);
		if(!pl.placed)
			respawn(peer, pl);
		else
			send_position(peer, pl);
		send_inventory(peer, pl);
		send_stats(peer, pl);
		send_time(peer);
		send_end(peer);
		send_world(peer);
		m_load_points_dirty = true;
		log_i(MODULE, "skeldat: %s joins at (%.1f, %.1f, %.1f)", cs(name),
				pl.x, pl.y, pl.z);
	}

	void add_player(const ss_ &name, size_t peer)
	{
		log_i(MODULE, "skeldat: %s is in the world", cs(name));
		auto it = m_players.find(peer);
		if(it != m_players.end() && it->second.intro){
			it->second.intro = false;
			send_intro(peer);
		}
	}
	void remove_player(const ss_ &name){}
	// accounts' admin is update_role()'s
	void set_admin(const ss_ &name, bool admin){}
	// Chat is builtin/chat's
	void chat_message(const ss_ &name, const ss_ &message){}
	void chat_send(const ss_ &to, const ss_ &text){}
	// The drop key: count of the held stack, 0 all of it, thrown ahead
	bool drop_wielded(const ss_ &name, int count)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(!pl || pl->main[pl->wield].empty())
			return false;
		Stack &st = pl->main[pl->wield];
		const int n = count <= 0 || count > st.count ? st.count : count;
		Stack out = st;
		out.count = n;
		st.take(n);
		const float yaw = pl->yaw * (float)M_PI / 180;
		drop(out, pl->x, pl->y + 1.2f, pl->z, std::sin(yaw) * 3, 2,
				std::cos(yaw) * 3, pl->name);
		send_inventory(peer, *pl);
		return true;
	}

	// The living player by name; the dead do nothing but respawn, which is
	// skeldat:respawn
	// simplified: a walk over the players, a handful at most
	Player *alive(const ss_ &name, size_t &peer)
	{
		for(auto &pair : m_players){
			if(pair.second.name == name){
				peer = pair.first;
				return pair.second.hp > 0 ? &pair.second : nullptr;
			}
		}
		return nullptr;
	}

	void set_player_pos(const ss_ &name, float x, float y, float z,
			float look_h, float look_v, int32_t controls)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(!pl)
			return;
		for(float v : {x, y, z, look_h})
			if(!std::isfinite(v) || std::fabs(v) > 1e6f)
				return;
		// A lagging client's places from before the one sent: a pull back
		// of each would only queue more of them
		if(pl->moved){
			if((controls & PLACES_MASK) != pl->places)
				return;
			pl->moved = false;
		}
		auto section = [](const Player &pl){
			return std::make_tuple((int)std::floor(pl.x / 16),
					(int)std::floor(pl.y / 16), (int)std::floor(pl.z / 16));
		};
		const auto was = section(*pl);
		pl->x = x;
		pl->y = y;
		pl->z = z;
		pl->board = (controls & BOARD_BIT) != 0;
		pl->board_seen = pl->board_seen || pl->board;
		pl->prone = (controls & PRONE_BIT) != 0;
		pl->prone_seen = pl->prone_seen || pl->prone;
		// Luanti's horizontal look turns the other way from Urho's yaw
		pl->yaw = -look_h * 180 / (float)M_PI;
		if(section(*pl) != was)
			m_load_points_dirty = true;
	}

	// [SKELDAT_NO_FALL_DAMAGE] A fall does not hurt (user, 2026-10-17):
	// getting back up is its cost
	void player_fell(const ss_ &name, float speed)
	{
		log_i(MODULE, "skeldat: %s lands at %.1f, no damage", cs(name), speed);
	}

	void set_wield_index(const ss_ &name, int index)
	{
		size_t peer;
		if(Player *pl = alive(name, peer)){
			const int w = std::max(0, std::min(8, index - 1));
			// A switch ends the bow's draw unshot
			if(w != pl->wield)
				pl->draw_t = -1;
			pl->wield = w;
		}
	}

	bool dig_node(int32_t x, int32_t y, int32_t z, const ss_ &name)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(pl)
			dig(peer, *pl, x, y, z);
		return pl != nullptr;
	}

	// Where a held dig starts: dig() wants it to have taken its time
	bool punch_node(int32_t x, int32_t y, int32_t z, const ss_ &name)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(!pl)
			return false;
		pl->dig_at = pos_key(x, y, z);
		pl->dig_t0 = m_time;
		return true;
	}

	bool punch_object(int32_t id, const ss_ &name)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(pl)
			punch(peer, *pl, (uint32_t)id);
		return pl != nullptr;
	}

	// Into above; under is what was pointed at, and the table's and the
	// furnace's windows are skeldat:open
	bool place_node(int32_t under_x, int32_t under_y, int32_t under_z,
			int32_t above_x, int32_t above_y, int32_t above_z,
			const ss_ &name, bool sneak)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(pl)
			place(peer, *pl, above_x, above_y, above_z);
		return pl != nullptr;
	}

	// Food is eaten
	bool use_wielded(const ss_ &name)
	{
		size_t peer;
		Player *pl = alive(name, peer);
		if(!pl)
			return false;
		Stack &st = pl->main[pl->wield];
		const skeldat::ItemDef *d = m_game.item(st.name);
		if(!d || d->eat <= 0 || pl->hp >= HP_MAX)
			return false;
		pl->hp = std::min(HP_MAX, pl->hp + d->eat);
		st.take(1);
		log_i(MODULE, "skeldat: %s eats %s", cs(pl->name), cs(d->name));
		send_inventory(peer, *pl);
		send_stats(peer, *pl);
		return true;
	}

	void respawn(size_t peer, Player &pl)
	{
		pl.x = m_spawn[0];
		pl.y = m_spawn[1];
		pl.z = m_spawn[2];
		pl.hp = HP_MAX;
		pl.breath = BREATH_MAX;
		pl.placed = true;
		send_position(peer, pl);
		send_stats(peer, pl);
	}

	// Where the server puts the player: the movement check's base too
	void send_position(size_t peer, Player &pl)
	{
		// Its range follows ([SKELDAT_RESPAWN_LOAD]): the moves' own check
		// sees no section change, the place having been set here already,
		// and a respawned player's range stayed where it died
		m_load_points_dirty = true;
		pl.cx = pl.x;
		pl.cy = pl.y;
		pl.cz = pl.z;
		pl.check_t = m_time;
		pl.check_air = false;
		pl.moved = true;
		pl.places = (pl.places + 1) & PLACES_MASK;
		std::ostringstream os;
		os<<pl.x<<" "<<pl.y<<" "<<pl.z<<" "<<pl.yaw;
		network::send(m_server, peer, "skeldat:position", os.str());
	}

	void send_stats(size_t peer, const Player &pl)
	{
		network::send(m_server, peer, "skeldat:stats",
				itos(pl.hp)+" "+itos(pl.breath));
	}

	void send_time(size_t peer)
	{
		std::ostringstream os;
		os<<m_day<<" "<<(1.0 / m_day_s);
		network::send(m_server, peer, "skeldat:time", os.str());
	}

	static ss_ list_text(const ss_ &name, const sv_<Stack> &l)
	{
		ss_ s = name+"=";
		for(size_t i = 0; i < l.size(); i++)
			s += (i ? "|" : "")+l[i].str();
		return s+"\n";
	}

	void send_inventory(size_t peer, const Player &pl)
	{
		Stack grid[9];
		for(int i = 0; i < 9; i++)
			grid[i] = pl.craft[i];
		const skeldat::Recipe *r = m_game.craft(grid);
		sv_<Stack> preview(1);
		if(r)
			preview[0] = Stack::parse(r->output);
		network::send(m_server, peer, "skeldat:inv", list_text("main", pl.main)+
				list_text("craft", pl.craft)+
				list_text("craftresult", pl.craftresult)+
				list_text("craftpreview", preview));
	}

	void send_furnace(const ss_ &at)
	{
		auto it = m_furnaces.find(at);
		if(it == m_furnaces.end())
			return;
		const Furnace &f = it->second;
		std::ostringstream os;
		os<<at<<"\n"<<list_text("src", {f.src})<<list_text("fuel", {f.fuel})
				<<list_text("dst", {f.dst});
		for(auto &pair : m_players)
			if(pair.second.open == at)
				network::send(m_server, pair.first, "skeldat:node_inv",
						os.str());
	}

	// What the client needs to know of the items: what they look like, how
	// they stack, what they dig and how fast; and the groups of the nodes
	// for the dig times. A line each, tab-separated.
	ss_ items_text()
	{
		auto caps = [](const sv_<skeldat::Cap> &cs){
			std::ostringstream os;
			for(const skeldat::Cap &c : cs)
				os<<c.group<<":"<<c.times[1]<<","<<c.times[2]<<","
						<<c.times[3]<<":"<<c.uses<<";";
			return os.str();
		};
		std::ostringstream os;
		os<<"hand\t"<<caps(m_game.hand.caps)<<"\n";
		for(auto &pair : m_game.items){
			const skeldat::ItemDef &d = pair.second;
			os<<"item\t"<<d.name<<"\t"<<d.desc<<"\t"<<d.image<<"\t"
					<<d.stack_max<<"\t"<<caps(d.caps)<<"\t"<<d.eat<<"\n";
		}
		for(const skeldat::NodeDef &n : m_game.nodes){
			os<<"node\t"<<n.name<<"\t";
			for(auto &g : n.groups)
				os<<g.first<<"="<<g.second<<";";
			os<<"\n";
		}
		return os.str();
	}

	void on_client_disconnected(const network::OldClient &old)
	{
		const size_t peer = old.info.id;
		auto it = m_players.find(peer);
		if(it != m_players.end()){
			save_player(it->second);
			m_players.erase(it);
		}
		m_session.left(peer);
		m_shown.erase(peer);
		m_waiting.erase(peer);
		m_joining.erase(peer);
		m_load_points_dirty = true;
	}

	void save_player(const Player &pl)
	{
		if(m_save && pl.placed)
			m_save->store("skeldat_players")->set(pl.name, pl.save());
	}

	void save()
	{
		if(!m_save)
			return;
		storage::Store *ps = m_save->store("skeldat_players");
		ps->batch([&](){
			for(auto &pair : m_players)
				if(pair.second.placed)
					ps->set(pair.second.name, pair.second.save());
		});
		m_store->batch([&](){
			std::ostringstream os;
			os<<m_day;
			m_store->set("day", os.str());
			m_store->set("world_t", dtos(m_world_t));
			for(const auto &pp : m_played)
				m_store->set("played/"+pp.first, dtos(pp.second));
			for(auto &pair : m_furnaces)
				m_store->set("furnace/"+pair.first, pair.second.save());
			for(auto &pair : m_mobs)
				m_store->set("mob/"+itos(pair.first), pair.second.save());
			for(const ss_ &key : m_store->list("drop/"))
				m_store->remove(key);
			for(size_t i = 0; i < m_drops.size(); i++){
				const Drop &d = m_drops[i];
				std::ostringstream ds;
				ds<<d.x<<" "<<d.y<<" "<<d.z<<" "<<d.age<<" "<<d.st.str();
				m_store->set("drop/"+itos(i), ds.str());
			}
			std::ostringstream ms;
			for(int n : m_markers)
				ms<<n<<" ";
			m_store->set("markers", ms.str());
			std::ostringstream hs;
			for(auto &kv : m_hole_day)
				hs<<kv.first<<" "<<kv.second<<" ";
			m_store->set("holes", hs.str());
		});
	}

	//
	// What a player does
	//

	VoxelInstance voxel_at(int x, int y, int z)
	{
		return voxelworld::get_voxel(m_server, m_scene,
				pv::Vector3DInt32(x, y, z), true);
	}
	uint32_t id_at(int x, int y, int z)
	{
		return m_format.id.get(voxel_at(x, y, z).data);
	}
	uint32_t param_at(int x, int y, int z)
	{
		return m_format.param.get(voxel_at(x, y, z).data);
	}
	int bones_at(int x, int y, int z)
	{
		return (int)m_bones.get(voxelworld::get_sample(m_server, m_scene,
				pv::Vector3DInt32(x, y, z), true));
	}
	// The bones stay with what is there, and go with it when it is dug
	void set_node(int x, int y, int z, uint32_t id, uint32_t param = 0,
			int bones = -1)
	{
		const pv::Vector3DInt32 p(x, y, z);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelSample v = w->get_sample(p, true);
			uint32_t &word = v.planes[0];
			const uint32_t old = m_format.id.get(word);
			word = 0;
			m_format.id.set(word, id);
			m_format.param.set(word, param);
			if(id == ID_AIR || id == m_marker || id == m_stuck_id)
				m_bones.set(v, 0);
			if(old != id && (old == m_stuck_id || id == m_stuck_id)){
				const ss_ k = pos_key(x, y, z);
				if(id == m_stuck_id)
					m_stuck.insert(k);
				else
					m_stuck.erase(k);
				if(m_store){
					if(id == m_stuck_id)
						m_store->set("stuck/"+k, "1");
					else
						m_store->remove("stuck/"+k);
				}
			}
			else if(bones >= 0)
				m_bones.set(v, (uint32_t)bones);
			const long f = footprint(x, z);
			if(f >= 0 && old != id && (id == m_marker || old == m_marker)){
				m_markers[f] += (id == m_marker) - (old == m_marker);
				log_i(MODULE, "skeldat: %d marker skulls in the footprint at "
						"%ld %ld", m_markers[f], f % (2 * m_half) - m_half,
						f / (2 * m_half) - m_half);
			}
			w->set_sample(p, v);
			rescan_column(w, x, z);
		});
		// The top may have moved to another section of the column
		const int S = skeldat::bones::SECTION;
		for(int sy = m_y0; sy <= m_y1; sy++)
			m_recount.insert(pos_key(floor_div(x, S), sy, floor_div(z, S)));
	}
	static int floor_div(int a, int b){ return a >= 0 ? a / b : -((-a + b - 1) / b); }

	// A section's columns whose top is in it and has no bones; the top
	// found from the world's top down
	void count_section(const ss_ &key)
	{
		int sx, sy, sz;
		char c;
		std::istringstream is(key);
		if(!(is>>sx>>c>>sy>>c>>sz))
			return;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			const int S = skeldat::bones::SECTION;
			for(int y = sy; y <= m_y1; y++)
				if(!w->is_section_loaded(pv::Vector3DInt16(sx, y, sz)))
					return;
			const pv::Region r(pv::Vector3DInt32(sx * S, sy * S, sz * S),
					pv::Vector3DInt32(sx * S + S - 1, m_y1 * S + S - 1,
					sz * S + S - 1));
			interface::VoxelVolume vol = w->get_volume(r);
			int64_t bare = 0;
			for(int z = sz * S; z < sz * S + S; z++)
			for(int x = sx * S; x < sx * S + S; x++)
			for(int y = m_y1 * S + S - 1; y >= sy * S; y--){
				const interface::VoxelSample v = vol.sample_at(x, y, z);
				if(!holds_bones(m_format.id.get(v)))
					continue;
				bare += y < sy * S + S && m_bones.get(v) == 0;
				break;
			}
			m_bare[key] = bare;
		});
	}

	// The counts kept up, a few sections a tick, and the end at none
	void step_end()
	{
		for(int budget = 8; budget > 0 && !m_recount.empty(); budget--){
			const ss_ key = *m_recount.begin();
			m_recount.erase(m_recount.begin());
			count_section(key);
		}
		if(m_ended || !m_world_ready || !m_recount.empty() ||
				m_bare.size() < all_sections())
			return;
		int64_t total = 0;
		for(auto &pair : m_bare)
			total += pair.second;
		// A game day's count, the last four kept ([SKELDAT_INTRO])
		const double day = m_world_t / m_day_s;
		if(m_bare_days.empty() || day - m_bare_days.back().first >= 1){
			m_bare_days.push_back({day, total});
			if(m_bare_days.size() > 4)
				m_bare_days.pop_front();
			log_i(MODULE, "skeldat: day %.1f, %lld columns bare", day,
					(long long)total);
		}
		if(total > 0)
			return;
		m_ended = true;
		m_end_days = m_world_t / m_day_s;
		char days_c[40];
		// The lowest speed it was at: a lower one is the easier
		snprintf(days_c, sizeof days_c, "%.1f days at %dx", m_end_days,
				m_speed_low);
		const ss_ days = days_c;
		m_store->set("ended", dtos(m_end_days));
		m_save->store("world_menu")->set("ended", days);
		record_score();
		// What the end did not wait for, once: the voxels under the tops
		// that have no bones
		int64_t under = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(const ss_ &key : m_sections){
				int sx, sy, sz;
				char c;
				std::istringstream is(key);
				if(!(is>>sx>>c>>sy>>c>>sz))
					continue;
				const pv::Vector3DInt16 sp(sx, sy, sz);
				if(!w->is_section_loaded(sp))
					continue;
				const interface::VoxelVolume vol = w->get_volume(
						w->get_section_region_voxels(sp));
				const pv::Region r = w->get_section_region_voxels(sp);
				const pv::Vector3DInt32 &lc = r.getLowerCorner(),
						&uc = r.getUpperCorner();
				for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
				for(int32_t y = lc.getY(); y <= uc.getY(); y++)
				for(int32_t x = lc.getX(); x <= uc.getX(); x++){
					const interface::VoxelSample v = vol.sample_at(x, y, z);
					under += holds_bones(m_format.id.get(v)) &&
							m_bones.get(v) == 0;
				}
			}
		});
		log_i(MODULE, "skeldat: every column's top has bones: the world ends "
				"after %s; %lld voxels under the tops have none", cs(days),
				(long long)under);
		for(auto &pair : m_players)
			send_end(pair.first);
	}

	// The world's size and its edge's mean crest, for the client's
	// backdrop beyond the edge ([SKELDAT_EDGE_RIDGE]): "half y0 y1 crest
	// low", half in voxels, low the lowest edge column's top
	void send_world(size_t peer)
	{
		std::ostringstream os;
		os<<m_half * skeldat::bones::SECTION<<" "<<m_y0 * skeldat::bones::SECTION
				<<" "<<(m_y1 + 1) * skeldat::bones::SECTION - 1<<" "<<m_edge_crest
				<<" "<<m_edge_low;
		network::send(m_server, peer, "skeldat:world", os.str());
	}

	// [SKELDAT_INTRO] The days left, "about": from the uncovered columns'
	// rate over the last few game days (m_bare_days), else the days a
	// world of this size takes at 1x, over the speed, less those gone; 0
	// once ended. The days measured free-running with no player
	// (2026-10-17): 128 at seeds 2-5 17.5, 36.1, 39.2, 19.9; 256 at seeds 2
	// and 3 24.5, 68.0; 512 and 1024 on that trend (x1.6 a doubling)
	// simplified: the history is not saved, a restarted world starts it
	// again from the constant
	void send_intro(size_t peer)
	{
		const double gone = m_world_t / m_day_s;
		double left;
		if(m_ended){
			left = 0;
		} else if(m_bare_days.size() >= 3 && m_bare_days.front().second >
				m_bare_days.back().second){
			const auto &a = m_bare_days.front(), &b = m_bare_days.back();
			left = b.second * (b.first - a.first) / (a.second - b.second);
		} else {
			const int width = m_half * 2 * skeldat::bones::SECTION;
			const double days = width <= 128 ? 28 : width <= 256 ? 46 :
					width <= 512 ? 75 : 120;
			left = days / m_speed - gone;
		}
		const int n = m_ended ? 0 : std::max(1, (int)std::lround(left));
		network::send(m_server, peer, "skeldat:intro", itos(n));
	}

	void send_end(size_t peer)
	{
		if(m_ended)
			network::send(m_server, peer, "skeldat:end", dtos(m_end_days)+" "+
					itos(m_speed_low)+" "+dtos(m_end_best)+" "+
					itos(m_end_place));
	}

	//
	// [SKELDAT_RERUN] A re-run of an ended world: any player's, the same
	// seed, size and speed, as <name>_rerun (a _rerun world's own name
	// again). Everyone is sent off with the goodbye that says the server
	// restarts, which a client with a launcher rejoins by; the module
	// reloads, the old instance closing the world (on_unload), the new
	// one deleting the target and making it (on_continue), every member
	// fresh.
	// simplified: a client with no launcher under it (started with -s)
	// is only disconnected
	//

	void rerun(const Player &pl)
	{
		if(!m_ended || m_rerunning){
			// The button is there only after the end: this is a stray
			log_i(MODULE, "skeldat: %s's re-run refused: %s", cs(pl.name),
					m_ended ? "one is starting" : "the world has not ended");
			return;
		}
		const ss_ rr = "_rerun";
		const bool is_rerun = m_world_name.size() > rr.size() &&
				m_world_name.compare(m_world_name.size() - rr.size(), rr.size(),
				rr) == 0;
		const ss_ target = is_rerun ? m_world_name : m_world_name+rr;
		bool valid = false;
		storage::access(m_server, [&](storage::Interface *i){
			valid = i->valid_name(target);
		});
		if(!valid){
			chat::access(m_server, [&](chat::Interface *c){
				c->say("A re-run of "+m_world_name+" can't be named "+target);
			});
			return;
		}
		m_rerunning = true;
		const ss_ line = pl.name+" starts a re-run as "+target;
		log_i(MODULE, "skeldat: %s", cs(line));
		chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		ss_ seed = "0";
		m_store->get("seed", seed);
		m_server->tmp_store_data("skeldat:rerun", target+"\n"+seed+"\n"+
				itos(m_half * 2 * skeldat::bones::SECTION)+"\n"+
				itos(m_speed_low));
		network::access(m_server, [&](network::Interface *i){
			for(network::PeerInfo::Id p : i->list_peers()){
				i->send(p, "network:goodbye", "1The world is being made again "
						"as "+target);
				i->disconnect(p);
			}
		});
		m_server->reload_module(MODULE);
	}

	// The old instance: the world saved and closed, out of every module
	// that held it
	void on_unload()
	{
		if(!m_scene)
			return;
		log_i(MODULE, "skeldat: the world \"%s\" closed for a reload",
				cs(m_world_name));
		save();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			w->commit();
		});
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->delete_instance(m_scene);
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			i->delete_instance(m_scene);
		});
		main_context::access(m_server, [&](main_context::Interface *i){
			i->delete_scene(m_scene);
		});
		m_scene = nullptr;
		storage::access(m_server, [&](storage::Interface *i){
			if(m_save)
				i->close(m_save);
			if(m_scores)
				i->close(m_scores);
		});
		m_save = nullptr;
		m_scores = nullptr;
	}

	// The new instance: a re-run's world made (the target deleted first,
	// the old world itself when it is the target), or the start's again
	void on_continue()
	{
		const ss_ data = m_server->tmp_restore_data("skeldat:rerun");
		std::istringstream is(data);
		ss_ name, seed, size, speed;
		std::getline(is, name);
		std::getline(is, seed);
		std::getline(is, size);
		std::getline(is, speed);
		if(name.empty()){
			start(true);
			return;
		}
		storage::access(m_server, [&](storage::Interface *i){
			for(const storage::SaveInfo &info : i->list())
				if(info.name == name){
					i->remove(name);
					log_i(MODULE, "skeldat: re-run: deleted %s", cs(name));
				}
			storage::Save *save = i->create(name);
			if(save){
				storage::Store *menu = save->store("world_menu");
				menu->set("seed", seed);
				menu->set("size", size);
				menu->set("speed", speed);
				i->close(save);
			}
		});
		log_i(MODULE, "skeldat: re-run: %s, seed %s, %s wide, %sx", cs(name),
				cs(seed), cs(size), cs(speed));
		start(false);
		start_world(name, false, seed);
	}

	//
	// [SKELDAT_HIGH_SCORES] The scores, outside the worlds
	//

	storage::Store* scores()
	{
		if(!m_scores){
			storage::access(m_server, [&](storage::Interface *i){
				m_scores = i->open("_skeldat");
				if(!m_scores)
					m_scores = i->create("_skeldat");
			});
		}
		return m_scores ? m_scores->store("scores") : nullptr;
	}

	// A set's JSON: {name, seed, size, speed, scores: [{days, date, world,
	// players: [[name, seconds]]}]}, best first
	json::Value read_set(storage::Store *st, const ss_ &key)
	{
		ss_ v;
		if(st && st->get(key, v)){
			const json::Value j = json::load_string(v.c_str());
			if(j.is_object())
				return j;
		}
		return json::object();
	}

	// Who played this world: the most time first, ten, and after them each
	// one in for more than half the world's time
	sv_<std::pair<ss_, double>> players_kept()
	{
		sv_<std::pair<ss_, double>> all(m_played.begin(), m_played.end());
		std::sort(all.begin(), all.end(), [](const std::pair<ss_, double> &a,
				const std::pair<ss_, double> &b){ return a.second > b.second; });
		sv_<std::pair<ss_, double>> kept;
		for(size_t i = 0; i < all.size(); i++)
			if(i < 10 || all[i].second > m_world_t / 2)
				kept.push_back(all[i]);
		return kept;
	}

	// The end's score into its set (seed, size, the lowest speed), the set
	// named after the last world not "_rerun" to end with it; the world's
	// own Players field; the presets again
	void record_score()
	{
		const sv_<std::pair<ss_, double>> kept = players_kept();
		std::ostringstream names;
		json::Value players = json::array();
		for(size_t i = 0; i < kept.size(); i++){
			char h[32];
			snprintf(h, sizeof h, "%.1f h", kept[i].second / 3600);
			names<<(i ? ", " : "")<<kept[i].first<<" "<<h;
			json::Value p = json::array();
			p.append(json::Value(kept[i].first));
			p.append(json::Value(kept[i].second));
			players.append(p);
		}
		m_save->store("world_menu")->set("players", names.str());
		storage::Store *st = scores();
		if(!st)
			return;
		ss_ seed = "0";
		m_store->get("seed", seed);
		const int size = m_half * 2 * skeldat::bones::SECTION;
		const ss_ key = "set/"+seed+"/"+itos(size)+"/"+itos(m_speed_low);
		json::Value set = read_set(st, key);
		set.set("seed", json::Value(seed));
		set.set("size", json::Value((int64_t)size));
		set.set("speed", json::Value((int64_t)m_speed_low));
		const ss_ rerun = "_rerun";
		const bool is_rerun = m_world_name.size() > rerun.size() &&
				m_world_name.compare(m_world_name.size() - rerun.size(),
				rerun.size(), rerun) == 0;
		if(!is_rerun)
			set.set("name", json::Value(m_world_name));
		else if(json::jstr(set, "name").empty())
			set.set("name", json::Value(m_world_name.substr(0,
					m_world_name.size() - rerun.size())));
		char date[16];
		const time_t now = time(nullptr);
		strftime(date, sizeof date, "%Y-%m-%d", localtime(&now));
		json::Value score = json::object();
		score.set("days", json::Value(m_end_days));
		score.set("date", json::Value(ss_(date)));
		score.set("world", json::Value(m_world_name));
		score.set("players", players);
		// Best first: in before the first with fewer days
		const json::Value &old = set.get("scores");
		json::Value list = json::array();
		m_end_place = 0;
		for(unsigned i = 0; old.is_array() && i < old.size(); i++){
			if(!m_end_place && old.at(i).get("days").as_number() < m_end_days){
				list.append(score);
				m_end_place = list.size();
			}
			list.append(old.at(i));
		}
		if(!m_end_place){
			list.append(score);
			m_end_place = list.size();
		}
		set.set("scores", list);
		m_end_best = list.at(0u).get("days").as_number();
		st->set(key, set.stringify());
		m_store->set("ended_rank", dtos(m_end_best)+" "+itos(m_end_place));
		log_i(MODULE, "skeldat: the score %.1f days is %d. of %u in %s "
				"(\"%s\"), best %.1f; players: %s", m_end_days, m_end_place,
				list.size(), cs(key), cs(json::jstr(set, "name")), m_end_best,
				cs(names.str()));
		send_presets();
	}

	// The sets, best first: [{key, name, seed, size, speed, best}]
	json::Value list_sets()
	{
		json::Value out = json::array();
		storage::Store *st = scores();
		if(!st)
			return out;
		sv_<std::pair<double, json::Value>> sets;
		for(const ss_ &key : st->list("set/")){
			const json::Value set = read_set(st, key);
			const json::Value &sc = set.get("scores");
			if(!sc.is_array() || sc.size() == 0)
				continue;
			json::Value v = json::object();
			v.set("key", json::Value(key));
			v.set("name", json::Value(json::jstr(set, "name")));
			v.set("seed", json::Value(json::jstr(set, "seed")));
			v.set("size", json::Value(json::jint(set, "size")));
			v.set("speed", json::Value(json::jint(set, "speed")));
			const double best = sc.at(0u).get("days").as_number();
			v.set("best", json::Value(best));
			sets.push_back({best, v});
		}
		std::stable_sort(sets.begin(), sets.end(), [](
				const std::pair<double, json::Value> &a,
				const std::pair<double, json::Value> &b){
			return a.first > b.first; });
		for(const auto &p : sets)
			out.append(p.second);
		return out;
	}

	// The world menu's "From the high scores": each set's parameters
	void send_presets()
	{
		const json::Value sets = list_sets();
		std::vector<world_menu::Preset> presets;
		for(unsigned i = 0; i < sets.size() && i < 20; i++){
			const json::Value &v = sets.at(i);
			char label[200];
			snprintf(label, sizeof label, "%s: %d, %dx, seed %s, best %.1f days",
					cs(json::jstr(v, "name")), (int)json::jint(v, "size"),
					(int)json::jint(v, "speed"), cs(json::jstr(v, "seed")),
					v.get("best").as_number());
			world_menu::Preset p;
			p.label = label;
			p.options["seed"] = json::jstr(v, "seed");
			p.options["size"] = itos(json::jint(v, "size"));
			p.options["speed"] = itos(json::jint(v, "speed"));
			presets.push_back(p);
		}
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->set_presets(presets);
		});
	}

	// skeldat:scores: "list", the sets; "set <key>", one set's best ten
	void send_scores(size_t peer, const ss_ &ask)
	{
		json::Value out = json::object();
		if(ask.compare(0, 4, "set ") == 0){
			const ss_ key = ask.substr(4);
			json::Value set = read_set(scores(), key);
			const json::Value &sc = set.get("scores");
			json::Value best = json::array();
			for(unsigned i = 0; sc.is_array() && i < sc.size() && i < 10; i++)
				best.append(sc.at(i));
			set.set("scores", best);
			set.set("key", json::Value(key));
			out.set("set", set);
		} else {
			out.set("sets", list_sets());
		}
		network::send(m_server, peer, "skeldat:scores", out.stringify());
	}

	// Inside the world above its bottom layer
	bool reaches_world(int x, int y, int z) const
	{
		using namespace skeldat::bones;
		const int h = m_half * SECTION;
		return x >= -h && x < h && z >= -h && z < h && y > m_y0 * SECTION &&
				y < (m_y1 + 1) * SECTION;
	}

	// From the player's eyes to the middle of the voxel
	// Within reach, and inside the world above its bottom layer, which is
	// not dug ([SKELDAT_BOUNDED_WORLD])
	bool reaches(const Player &pl, int x, int y, int z)
	{
		if(m_ended || !reaches_world(x, y, z))
			return false;
		const float dx = x - pl.x, dy = y - (pl.y + 1.625f), dz = z - pl.z;
		return std::sqrt(dx * dx + dy * dy + dz * dz) <= REACH;
	}

	void on_game_packet(const network::Packet &packet)
	{
		auto it = m_players.find(packet.sender);
		if(it == m_players.end())
			return;
		const size_t peer = packet.sender;
		Player &pl = it->second;
		const ss_ what = packet.name.substr(8); // after "skeldat:"
		std::istringstream is(packet.data);
		if(what == "respawn"){
			if(pl.hp <= 0)
				respawn(peer, pl);
			return;
		}
		if(what == "intro"){
			send_intro(peer);
			return;
		}
		if(what == "scores"){
			send_scores(peer, packet.data);
			return;
		}
		if(what == "rerun"){
			rerun(pl);
			return;
		}
		if(pl.hp <= 0)
			return; // the dead do nothing else
		if(what == "open"){
			int x, y, z;
			pl.open = "";
			if(is>>x>>y>>z && reaches(pl, x, y, z)){
				const skeldat::NodeDef *n = node_of(id_at(x, y, z));
				if(n && (n->name == "skeldat:table" || has_slots(n->name))){
					pl.open = pos_key(x, y, z);
					if(n->name != "skeldat:table"){
						m_furnaces[pl.open]; // one that predates its record
						send_furnace(pl.open);
					}
				}
			}
		} else if(what == "close"){
			pl.open = "";
		} else if(what == "move"){
			int count = 0, fi = 0, ti = 0;
			ss_ floc, flist, tloc, tlist;
			if(is>>count>>floc>>flist>>fi>>tloc>>tlist>>ti)
				move(peer, pl, count, floc, flist, fi, tloc, tlist, ti);
		} else if(what == "craft"){
			craft(peer, pl);
		} else if(what == "bow"){
			ss_ how;
			float dx = 0, dy = 0, dz = 0;
			is>>how>>dx>>dy>>dz;
			bow(peer, pl, how, dx, dy, dz);
		}
	}

	// [SKELDAT_BOW] "start": the draw begins with the bow held and an
	// arrow in the main inventory; "release dx dy dz": timed here, the
	// arrow shot from the eye along the look at the draw's speed, one
	// arrow taken and the bow worn; under BOW_MIN nothing
	void bow(size_t peer, Player &pl, const ss_ &how, float dx, float dy,
			float dz)
	{
		Stack &held = pl.main[pl.wield];
		auto arrow = std::find_if(pl.main.begin(), pl.main.end(),
				[](const Stack &st){ return st.name == "skeldat:arrow"; });
		if(how == "start"){
			pl.draw_t = held.name == "skeldat:bow" && arrow != pl.main.end() ?
					m_time : -1;
			if(pl.draw_t >= 0)
				log_i(MODULE, "skeldat: %s draws the bow", cs(pl.name));
			return;
		}
		if(how != "release" || pl.draw_t < 0)
			return;
		const float draw = std::min(1.0f, (float)(m_time - pl.draw_t) / BOW_DRAW);
		pl.draw_t = -1;
		const float l = std::sqrt(dx * dx + dy * dy + dz * dz);
		if(held.name != "skeldat:bow" || arrow == pl.main.end() ||
				!(l > 0.5f && l < 2)){
			return;
		}
		if(draw < BOW_MIN){
			log_i(MODULE, "skeldat: %s lets the bow go undrawn (%.2f)",
					cs(pl.name), draw);
			return;
		}
		dx /= l, dy /= l, dz /= l;
		arrow->take(1);
		held.wear += skeldat::WEAR_MAX / BOW_USES;
		if(held.wear >= skeldat::WEAR_MAX)
			held = Stack();
		send_inventory(peer, pl);
		const float speed = draw * BOW_SPEED;
		Arrow a;
		a.x = pl.x + dx * 0.5f, a.y = pl.y + 1.6f + dy * 0.5f,
				a.z = pl.z + dz * 0.5f;
		a.vx = dx * speed, a.vy = dy * speed, a.vz = dz * speed;
		a.by_player = true;
		a.peer = peer;
		main_context::access(m_server, m_scene, [&](Urho3D::Scene *scene){
			Urho3D::Node *n = scene->CreateChild("skeldat_arrow");
			n->SetPosition(Urho3D::Vector3(a.x, a.y, a.z));
			a.node_id = n->GetID();
		});
		m_arrows.push_back(a);
		sound("bow", a.x, a.y, a.z);
		log_i(MODULE, "skeldat: %s shoots an arrow at %.1f (drawn %.2f)",
				cs(pl.name), speed, draw);
	}

	void hurt(size_t peer, Player &pl, int damage, const char *how)
	{
		if(damage <= 0 || pl.hp <= 0)
			return;
		if(pl.invulnerable){
			log_i(MODULE, "skeldat: %s %s, invulnerable", cs(pl.name), how);
			return;
		}
		pl.hp = std::max(0, pl.hp - damage);
		log_i(MODULE, "skeldat: %s %s, %d hp left", cs(pl.name), how, pl.hp);
		if(pl.hp == 0){
			death_drops(pl);
			send_inventory(peer, pl);
		}
		send_stats(peer, pl);
	}

	// Half the non-empty stacks, rounded up, picked at random, dropped
	// where the player died; nothing below the world
	void death_drops(Player &pl)
	{
		if(pl.y < m_y0 * skeldat::bones::SECTION)
			return;
		sv_<Stack*> full;
		for(auto *l : {&pl.main, &pl.craft, &pl.craftresult})
			for(Stack &st : *l)
				if(!st.empty())
					full.push_back(&st);
		std::shuffle(full.begin(), full.end(), m_rand);
		const size_t n = (full.size() + 1) / 2;
		for(size_t i = 0; i < n; i++){
			drop(*full[i], pl.x + rnd() - 0.5f, pl.y + 0.5f,
					pl.z + rnd() - 0.5f);
			*full[i] = Stack();
		}
		log_i(MODULE, "skeldat: %s dies at %.1f,%.1f,%.1f, dropping %zu of "
				"%zu stacks", cs(pl.name), pl.x, pl.y, pl.z, n, full.size());
	}

	void drop(const Stack &st, float x, float y, float z, float vx = 0,
			float vy = 0, float vz = 0, const ss_ &owner = "")
	{
		if(st.empty())
			return;
		Drop d;
		d.st = st;
		d.x = x, d.y = y, d.z = z, d.vx = vx, d.vy = vy, d.vz = vz;
		d.owner = owner;
		m_drops.push_back(d);
		log_i(MODULE, "skeldat: a drop of %s at %.1f,%.1f,%.1f", cs(st.str()),
				x, y, z);
	}

	// What does not fit the player's inventory, dropped at its feet
	void give_or_drop(Player &pl, const Stack &st)
	{
		drop(m_game.add(pl.main, st), pl.x, pl.y + 0.5f, pl.z);
	}

	void step_drops(float dt)
	{
		// An unloaded voxel is ground to walkable(): not before the world
		if(m_drops.empty() || !m_world_ready)
			return;
		sv_<Drop> kept;
		sv_<uint32_t> gone;
		sv_<pv::Vector3DInt32> seeds;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(Drop &d : m_drops){
				d.age += dt;
				if(d.age > m_day_s){
					log_i(MODULE, "skeldat: the drop of %s at %.1f,%.1f,%.1f "
							"is gone", cs(d.st.str()), d.x, d.y, d.z);
					gone.push_back(d.node_id);
					continue;
				}
				// Its ground dug away
				if(d.resting && !walkable(w, (int)std::floor(d.x + 0.5f),
						(int)std::floor(d.y), (int)std::floor(d.z + 0.5f)))
					d.resting = false, d.vy = 0;
				if(!d.resting){
					d.vy = std::max(d.vy - GRAVITY * dt, -30.0f);
					const float nx = d.x + d.vx * dt, nz = d.z + d.vz * dt;
					if(walkable(w, (int)std::floor(nx + 0.5f),
							(int)std::floor(d.y + 0.5f),
							(int)std::floor(nz + 0.5f)))
						d.vx = d.vz = 0;
					else
						d.x = nx, d.z = nz;
					const float ny = d.y + d.vy * dt;
					const int vy = (int)std::floor(ny + 0.5f);
					if(d.vy < 0 && walkable(w, (int)std::floor(d.x + 0.5f), vy,
							(int)std::floor(d.z + 0.5f))){
						d.y = vy + 0.5f;
						d.resting = true;
						log_i(MODULE, "skeldat: the drop of %s rests at "
								"%.1f,%.1f,%.1f", cs(d.st.str()), d.x, d.y, d.z);
					} else
						d.y = ny;
					// simplified: below the world it is lost at once
					if(d.y < m_y0 * skeldat::bones::SECTION - 8){
						gone.push_back(d.node_id);
						continue;
					}
				}
				if(d.seed){
					if(d.resting){
						// Over what it rests on, if that is free
						const pv::Vector3DInt32 at((int)std::floor(d.x + 0.5f),
								(int)std::floor(d.y + 0.5f),
								(int)std::floor(d.z + 0.5f));
						if(wid(w, at.getX(), at.getY(), at.getZ()) == ID_AIR)
							seeds.push_back(at);
						gone.push_back(d.node_id);
						continue;
					}
					kept.push_back(d);
					continue;
				}
				for(auto &pair : m_players){
					Player &pl = pair.second;
					if(!pl.placed || pl.hp <= 0)
						continue;
					const float dist = std::sqrt((pl.x - d.x) * (pl.x - d.x) +
							(pl.y + 0.5f - d.y) * (pl.y + 0.5f - d.y) +
							(pl.z - d.z) * (pl.z - d.z));
					if(pl.name == d.owner){
						if(dist > 2 * DROP_REACH)
							d.owner.clear();
						continue;
					}
					if(dist > DROP_REACH)
						continue;
					const Stack left = m_game.add(pl.main, d.st);
					if(left.count == d.st.count)
						continue;
					log_i(MODULE, "skeldat: %s picks up %d %s", cs(pl.name),
							d.st.count - left.count, cs(d.st.name));
					d.st = left;
					send_inventory(pair.first, pl);
					if(d.st.empty())
						break;
				}
				if(d.st.empty()){
					gone.push_back(d.node_id);
					continue;
				}
				kept.push_back(d);
			}
		});
		const uint32_t skull = seeds.empty() ? ID_IGNORE : id_of("skeldat:skull");
		for(const pv::Vector3DInt32 &p : seeds){
			set_node(p.getX(), p.getY(), p.getZ(), skull, 0,
					skeldat::bones::MAX);
			log_i(MODULE, "skeldat: a dropped skull is a voxel at %d,%d,%d",
					p.getX(), p.getY(), p.getZ());
		}
		main_context::access(m_server, m_scene, [&](Urho3D::Scene *scene){
			for(uint32_t id : gone)
				if(Urho3D::Node *n = id ? scene->GetNode(id) : nullptr)
					n->Remove();
			for(Drop &d : kept){
				Urho3D::Node *n = d.node_id ? scene->GetNode(d.node_id) : nullptr;
				if(!n){
					n = scene->CreateChild("skeldat_drop");
					n->SetVar(Urho3D::StringHash("skeldat_item"),
							Urho3D::Variant(Urho3D::String(d.st.name.c_str())));
					d.node_id = n->GetID();
				}
				if(n->GetPosition() != Urho3D::Vector3(d.x, d.y, d.z))
					n->SetPosition(Urho3D::Vector3(d.x, d.y, d.z));
			}
		});
		m_drops.swap(kept);
	}

	void dig(size_t peer, Player &pl, int x, int y, int z)
	{
		const ss_ at = pos_key(x, y, z);
		// Reach first: a client's y of 5e8 made voxelworld throw, and each
		// throw logged a backtrace ([SECURITY_RUN_6])
		if(!reaches(pl, x, y, z)){
			log_i(MODULE, "skeldat: %s's dig at %s refused", cs(pl.name),
					cs(at));
			return;
		}
		const uint32_t id = id_at(x, y, z);
		const skeldat::NodeDef *n = node_of(id);
		Stack &tool = pl.main[pl.wield];
		// The bow digs nothing ([SKELDAT_BOW])
		if(tool.name == "skeldat:bow")
			return;
		const skeldat::Cap *cap = nullptr;
		const float time = n ? m_game.dig_time(tool.name, *n, &cap) : -1;
		// A quarter less than the time, for the network's lag
		if(!n || time < 0 || !reaches(pl, x, y, z) || pl.dig_at != at ||
				m_time - pl.dig_t0 < time * 0.75f){
			log_i(MODULE, "skeldat: %s's dig at %s refused", cs(pl.name),
					cs(at));
			return;
		}
		if(has_slots(n->name)){
			auto f = m_furnaces.find(at);
			if(f != m_furnaces.end() && !(f->second.src.empty() &&
					f->second.fuel.empty() && f->second.dst.empty()))
				return; // not while it holds anything
			m_furnaces.erase(at);
			if(m_store)
				m_store->remove("furnace/"+at);
		}
		pl.dig_at = "";
		const int bones = bones_at(x, y, z);
		set_node(x, y, z, ID_AIR);
		if(cap && cap->uses > 0){
			tool.wear += skeldat::WEAR_MAX / cap->uses;
			if(tool.wear >= skeldat::WEAR_MAX)
				tool = Stack();
		}
		// What it drops goes straight into the inventory, what does not
		// fit to the ground
		Stack drop;
		if(bones > skeldat::bones::NO_DROP)
			; // bone-ridden: nothing
		else if(n->drop == "")
			drop = Stack(n->name);
		else if(n->drop != "-" && (n->drop_rarity <= 1 ||
				m_rand() % n->drop_rarity == 0))
			drop = Stack::parse(n->drop);
		give_or_drop(pl, drop);
		// The arrows stuck into it, the digger's ([SKELDAT_BOW])
		static const int FACE[6][3] = {{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
				{-1, 0, 0}, {0, 0, 1}, {0, 0, -1}};
		for(int f = 0; f < 6; f++){
			const int ax = x - FACE[f][0], ay = y - FACE[f][1],
					az = z - FACE[f][2];
			if(id_at(ax, ay, az) == m_stuck_id &&
					param_at(ax, ay, az) == (uint32_t)f){
				set_node(ax, ay, az, ID_AIR);
				give_or_drop(pl, Stack("skeldat:arrow"));
			}
		}
		log_i(MODULE, "skeldat: %s digs %s at %s, bones %d%s", cs(pl.name),
				cs(n->name), cs(at), bones, bones > skeldat::bones::NO_DROP ?
				", dropping nothing" : "");
		send_inventory(peer, pl);
	}

	void place(size_t peer, Player &pl, int x, int y, int z)
	{
		if(!reaches(pl, x, y, z))
			return;
		Stack &st = pl.main[pl.wield];
		const uint32_t id = id_of(st.name);
		const skeldat::NodeDef *n = node_of(id);
		const skeldat::NodeDef *here = node_of(id_at(x, y, z));
		const uint32_t here_id = id_at(x, y, z);
		// Into air or water, beside something, out of everyone's way
		bool beside = false;
		static const int D[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
				{0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
		for(auto &d : D){
			const uint32_t b = id_at(x + d[0], y + d[1], z + d[2]);
			beside = beside || (b != ID_AIR && b != ID_IGNORE &&
					b != id_of("skeldat:water_source"));
		}
		if(!n || !(here_id == ID_AIR || here_id == m_stuck_id || (here &&
				here->shape == skeldat::LIQUID)) || !beside ||
				!reaches(pl, x, y, z))
			return;
		if(n->shape != skeldat::TORCH){
			for(auto &pair : m_players){
				const Player &o = pair.second;
				if(o.hp > 0 && x + 0.5f > o.x - 0.3f && x - 0.5f < o.x + 0.3f &&
						z + 0.5f > o.z - 0.3f && z - 0.5f < o.z + 0.3f &&
						y + 0.5f > o.y && y - 0.5f < o.y + 1.75f)
					return;
			}
		}
		// Facing the player: the yaw is the client's, 0 towards +z
		uint32_t param = 0;
		if(n->facedir){
			const int q = ((int)std::floor((pl.yaw + 45) / 90) % 4 + 4) % 4;
			// Looking towards +z the front faces -z, which is facedir 0
			static const uint32_t FACE[4] = {0, 1, 2, 3};
			param = FACE[q];
		}
		set_node(x, y, z, id, param);
		log_i(MODULE, "skeldat: %s places %s at %s", cs(pl.name),
				cs(n->name), cs(pos_key(x, y, z)));
		if(n->name == "skeldat:furnace" || n->name == "skeldat:lantern"){
			Furnace f;
			f.lantern = n->name == "skeldat:lantern";
			m_furnaces[pos_key(x, y, z)] = f;
		}
		st.take(1);
		send_inventory(peer, pl);
	}

	// A furnace or a lantern, lit or not: m_furnaces holds its slots
	static bool has_slots(const ss_ &name)
	{
		return name.compare(0, 15, "skeldat:furnace") == 0 ||
				name.compare(0, 15, "skeldat:lantern") == 0;
	}

	// A slot by where it is: "me" and a list of the player's own, or
	// "x,y,z" and a list of the furnace the player has open
	Stack* slot(Player &pl, const ss_ &loc, const ss_ &list, int index,
			bool put)
	{
		index--;
		if(loc == "me"){
			if(list == "main" && index >= 0 && index < 36)
				return &pl.main[index];
			// Outside the inventory's own 2x2 only at a table
			if(list == "craft" && index >= 0 && index < 9 &&
					(index % 3 < 2 && index / 3 < 2 || at_table(pl)))
				return &pl.craft[index];
			if(list == "craftresult" && index == 0 && !put)
				return &pl.craftresult[0];
			return nullptr;
		}
		if(loc != pl.open || index != 0)
			return nullptr;
		auto it = m_furnaces.find(loc);
		if(it == m_furnaces.end())
			return nullptr;
		if(it->second.lantern && list != "fuel")
			return nullptr;
		if(list == "src")
			return &it->second.src;
		if(list == "fuel")
			return &it->second.fuel;
		if(list == "dst" && !put)
			return &it->second.dst;
		return nullptr;
	}

	bool at_table(Player &pl)
	{
		if(pl.open.empty())
			return false;
		int x, y, z;
		char c;
		std::istringstream is(pl.open);
		if(!(is>>x>>c>>y>>c>>z) || !reaches(pl, x, y, z))
			return false;
		return id_at(x, y, z) == id_of("skeldat:table");
	}

	void move(size_t peer, Player &pl, int count, const ss_ &floc,
			const ss_ &flist, int fi, const ss_ &tloc, const ss_ &tlist,
			int ti)
	{
		Stack *from = slot(pl, floc, flist, fi, false);
		Stack *to = slot(pl, tloc, tlist, ti, true);
		if(!from || !to || !m_game.move(*from, *to, count))
			return;
		send_inventory(peer, pl);
		if(floc != "me")
			send_furnace(floc);
		if(tloc != "me" && tloc != floc)
			send_furnace(tloc);
	}

	void craft(size_t peer, Player &pl)
	{
		Stack grid[9];
		bool outside = false;
		for(int i = 0; i < 9; i++){
			grid[i] = pl.craft[i];
			outside = outside || (!grid[i].empty() && (i % 3 == 2 || i / 3 == 2));
		}
		const skeldat::Recipe *r = m_game.craft(grid);
		if(!r || (outside && !at_table(pl)))
			return;
		Stack out = Stack::parse(r->output);
		Stack &res = pl.craftresult[0];
		if(!res.empty() && (res.name != out.name ||
				res.count + out.count > m_game.stack_max(out.name)))
			return;
		for(Stack &s : pl.craft)
			if(!s.empty())
				s.take(1);
		if(res.empty())
			res = out;
		else
			res.count += out.count;
		log_i(MODULE, "skeldat: %s crafts %s, the result %s", cs(pl.name),
				cs(out.str()), cs(res.str()));
		send_inventory(peer, pl);
	}

	//
	// Time
	//

	//
	// The mobs (skelenti's, main.cpp there), the world read in C++
	//

	float rnd()
	{
		return std::uniform_real_distribution<float>(0, 1)(m_rand);
	}

	// The world as a mob sees it, inside one voxelworld access. An unloaded
	// voxel is a wall: nothing walks into the unknown.
	uint32_t wid(voxelworld::Instance *w, int x, int y, int z)
	{
		return m_format.id.get(w->get_voxel(pv::Vector3DInt32(x, y, z),
				true).data);
	}
	bool walkable(voxelworld::Instance *w, int x, int y, int z)
	{
		const uint32_t id = wid(w, x, y, z);
		if(id == ID_AIR)
			return false;
		const skeldat::NodeDef *n = node_of(id);
		return !n || (n->shape != skeldat::LIQUID &&
				n->shape != skeldat::TORCH && n->walkable);
	}
	bool is_water(voxelworld::Instance *w, int x, int y, int z)
	{
		const skeldat::NodeDef *n = node_of(wid(w, x, y, z));
		return n && n->shape == skeldat::LIQUID;
	}
	// The sky's light and the lamps', 0 to 15
	void light(voxelworld::Instance *w, int x, int y, int z, int &sky,
			int &lamp)
	{
		const uint32_t d = w->get_voxel(pv::Vector3DInt32(x, y, z), true).data;
		sky = (int)m_format.light_sky.get(d);
		lamp = (int)m_format.light_lamp.get(d);
	}
	// The sky's light now: none at night
	// simplified: day or night, not a ramp through dusk
	int sun(voxelworld::Instance *w, int x, int y, int z)
	{
		if(m_day < 0.23 || m_day > 0.77)
			return 0;
		int sky, lamp;
		light(w, x, y, z, sky, lamp);
		return sky;
	}

	// **The danger of a place is the bones around it** ([SKELDAT]: one
	// rule, two places), read as client_lua/init.lua's danger_here() reads
	// it for the fog and the music: the mean bones of the voxels that are
	// not empty in a box 9 across about the feet, every other voxel, 0 to 1
	float danger(voxelworld::Instance *w, float x, float y, float z)
	{
		const int fx = (int)std::floor(x + 0.5f), fy = (int)std::floor(y + 0.5f),
				fz = (int)std::floor(z + 0.5f);
		int sum = 0, n = 0;
		for(int dz = -4; dz <= 4; dz += 2)
		for(int dy = -4; dy <= 4; dy += 2)
		for(int dx = -4; dx <= 4; dx += 2){
			const interface::VoxelSample v = w->get_sample(
					pv::Vector3DInt32(fx + dx, fy + dy, fz + dz), true);
			const uint32_t id = m_format.id.get(v.planes[0]);
			if(id == ID_IGNORE || id == ID_AIR)
				continue;
			n++;
			sum += (int)m_bones.get(v);
		}
		return n ? (float)sum / (n * skeldat::bones::MAX) : 0.0f;
	}

	// [SKELDAT_SUN_IN_BONES] The sun does not burn a skeleton (user,
	// 2026-10-16) while the 3x4x3 box round its feet's voxel has a voxel of
	// bones over half -- bones::skeleton_near(), the rule a player looks
	// like one by -- or a bone block or a skull, counted as full bones.
	// -1 when the feet's voxel is not loaded.
	int sun_safe(voxelworld::Instance *w, float x, float y, float z)
	{
		const int fx = (int)std::floor(x + 0.5f), fy = (int)std::floor(y + 0.5f),
				fz = (int)std::floor(z + 0.5f);
		if(m_format.id.get(w->get_sample(pv::Vector3DInt32(fx, fy, fz),
				true).planes[0]) == ID_IGNORE)
			return -1;
		return skeldat::bones::skeleton_near([&](int vx, int vy, int vz){
			const interface::VoxelSample v = w->get_sample(
					pv::Vector3DInt32(vx, vy, vz), true);
			const uint32_t id = m_format.id.get(v.planes[0]);
			return std::find(m_sun_ids.begin(), m_sun_ids.end(), id) !=
					m_sun_ids.end() ? skeldat::bones::MAX : (int)m_bones.get(v);
		}, fx, fy, fz);
	}

	// Where something h voxels tall can stand in the column at x, z, from a
	// step up to three down from feet y. A voxel at integer y spans y-0.5
	// to y+0.5, so feet on the one at y are at y+0.5.
	Ground ground(voxelworld::Instance *w, float x, float y, float z, int h)
	{
		Ground g;
		const int cx = (int)std::floor(x + 0.5f), cy = (int)std::floor(y + 0.5f),
				cz = (int)std::floor(z + 0.5f);
		for(int c = cy - 4; c <= cy + h + 1; c++){
			if(wid(w, cx, c, cz) == ID_IGNORE){
				g.loaded = false;
				return g;
			}
		}
		for(int c = cy + 1; c >= cy - 3; c--){
			if(!walkable(w, cx, c - 1, cz))
				continue;
			bool free = true;
			for(int i = 0; i < h && free; i++)
				free = !walkable(w, cx, c + i, cz);
			if(free){
				g.found = true;
				g.y = c - 0.5f;
				g.sun = sun(w, cx, c, cz);
				g.water = is_water(w, cx, c, cz);
				return g;
			}
		}
		return g;
	}

	// The nearest player placed and alive, and how far
	Player* nearest(float x, float y, float z, float &d,
			size_t *peer_out = nullptr)
	{
		Player *best = nullptr;
		d = 1e9f;
		for(auto &pair : m_players){
			Player &p = pair.second;
			const float e = std::sqrt((p.x-x)*(p.x-x) + (p.y-y)*(p.y-y) +
					(p.z-z)*(p.z-z));
			if(p.placed && p.hp > 0 && e < d){
				d = e;
				best = &p;
				if(peer_out)
					*peer_out = pair.first;
			}
		}
		return best;
	}

	// A moment's sound at a place, to everyone in the world; what it sounds
	// like is the client's (client_lua/sounds.lua)
	void sound(const char *moment, float x, float y, float z)
	{
		char buf[100];
		snprintf(buf, sizeof buf, "%s %.2f %.2f %.2f", moment, x, y, z);
		for(size_t peer : m_shown)
			network::send(m_server, peer, "skeldat:sound", buf);
	}

	// A place for a kind to spawn near a player, 12 to 24 voxels off: a
	// boar on grass under the open sky, a skeleton on a floor no light
	// reaches -- or on any floor where the danger d is DAYLIGHT_DANGER or
	// more
	bool spawn_spot(voxelworld::Instance *w, uint8_t kind, const Player &p,
			float d, float out[3])
	{
		const uint32_t grass = id_of("skeldat:grass");
		for(int i = 0; i < 8; i++){
			const float r = 12 + rnd() * 12, t = rnd() * 2 * (float)M_PI;
			const int x = (int)std::floor(p.x + r * std::cos(t) + 0.5f),
					z = (int)std::floor(p.z + r * std::sin(t) + 0.5f),
					y0 = (int)std::floor(p.y + 0.5f);
			for(int y = y0 + 12; y >= y0 - 16; y--){
				const uint32_t below = wid(w, x, y - 1, z);
				if(below == ID_IGNORE || !walkable(w, x, y - 1, z) ||
						walkable(w, x, y, z) || walkable(w, x, y + 1, z) ||
						is_water(w, x, y, z))
					continue;
				int sky, lamp;
				light(w, x, y, z, sky, lamp);
				if(kind == BOAR ? below == grass && sky == 15 :
						d >= DAYLIGHT_DANGER || std::max(sky, lamp) <= 3){
					out[0] = (float)x, out[1] = y - 0.5f, out[2] = (float)z;
					return true;
				}
			}
		}
		return false;
	}

	void spawn()
	{
		for(auto &pair : m_players){
			const Player &p = pair.second;
			if(!p.placed || p.hp <= 0)
				continue;
			float d = 0;
			voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
				d = danger(w, p.x, p.y, p.z);
			});
			size_t awake = 0;
			for(auto &kv : m_mobs)
				awake += kv.second.node_id != 0;
			for(uint8_t kind : {BOAR, SKELETON}){
				if(awake >= MAX_MOBS)
					return;
				if(kind == BOAR && (m_day < 0.25 || m_day > 0.75))
					continue;
				size_t near = 0;
				for(auto &kv : m_mobs){
					const Mob &m = kv.second;
					if(m.kind == kind && m.node_id && std::fabs(m.x-p.x) < 32 &&
							std::fabs(m.z-p.z) < 32 && std::fabs(m.y-p.y) < 32)
						near++;
				}
				// A skeleton by the danger: more tries, more of them
				if(near >= (kind == SKELETON ? 1 + (size_t)(5 * d) : MAX_NEAR))
					continue;
				if(kind == SKELETON && rnd() > 0.1f + 0.9f * d)
					continue;
				float s[3];
				bool found = false;
				voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
					found = spawn_spot(w, kind, p, d, s);
				});
				if(!found)
					continue;
				size_t area = 0;
				for(auto &kv : m_mobs)
					if(std::fabs(kv.second.x - s[0]) < 32 &&
							std::fabs(kv.second.z - s[2]) < 32)
						area++;
				if(area >= (kind == SKELETON ? 2 + (size_t)(8 * d) : MAX_AREA))
					continue;
				Mob m;
				m.kind = kind;
				m.x = s[0], m.y = s[1], m.z = s[2];
				m.hp = MOB_HP[kind];
				m.yaw = rnd() * 2 * (float)M_PI;
				const uint32_t k = m_next_mob++;
				m_mobs[k] = m;
				awake++;
				log_i(MODULE, "skeldat: a %s (%u) spawns at %.1f,%.1f,%.1f, "
						"danger %.2f", MOB_KIND[kind], k, m.x, m.y, m.z, d);
			}
		}
	}

	void stage_test()
	{
		if(m_test_done)
			return;
		Player *p = nullptr;
		size_t peer = 0;
		for(auto &pair : m_players)
			if(pair.second.placed)
				p = &pair.second, peer = pair.first;
		if(!p)
			return;
		m_test_done = true;
		std::istringstream is(m_test);
		ss_ item;
		while(std::getline(is, item, ';')){
			std::istringstream it(item);
			ss_ kind;
			it>>kind;
			if(kind == "place"){
				// "place x z": the player moved onto that column's top
				int x = 0, z = 0;
				it>>x>>z;
				int y = (m_y1 + 1) * skeldat::bones::SECTION - 1;
				while(y > m_y0 * skeldat::bones::SECTION &&
						id_at(x, y - 1, z) == ID_AIR)
					y--;
				p->x = (float)x, p->y = (float)y, p->z = (float)z;
				send_position(peer, *p);
				log_i(MODULE, "skeldat: test: %s placed at %d,%d,%d",
						cs(p->name), x, y, z);
				continue;
			}
			if(kind == "give"){
				// "give item n k": k stacks of n into the player's main
				int n = 0, k = 1;
				ss_ name;
				it>>name>>n>>k;
				for(int i = 0; i < k && m_game.item(name); i++)
					m_game.add(p->main, Stack(name, n));
				send_inventory(peer, *p);
				log_i(MODULE, "skeldat: test: %d of %s given", k, cs(name));
				continue;
			}
			if(kind == "craft"){
				// "craft i item n": the player's craft slot i (1-9) holds n
				int i = 0, n = 0;
				ss_ name;
				it>>i>>name>>n;
				if(i >= 1 && i <= 9 && m_game.item(name)){
					p->craft[i - 1] = Stack(name, n);
					send_inventory(peer, *p);
					log_i(MODULE, "skeldat: test: %s in craft %d", cs(name), i);
				}
				continue;
			}
			float dx = 0, dz = 0;
			it>>dx>>dz;
			if(kind == "marker"){
				// "marker dx dz [node [dy]]": a marker skull, or the node,
				// on the ground there, or dy over that (-1 the ground's top)
				ss_ name;
				int dy = -1000;
				it>>name>>dy;
				const uint32_t id = name.empty() ? m_marker : id_of(name);
				const int x = (int)std::floor(p->x + dx + 0.5f),
						z = (int)std::floor(p->z + dz + 0.5f);
				int y = (int)std::floor(p->y + 0.5f) + 2;
				while(y > (int)std::floor(p->y + 0.5f) - 3 &&
						id_at(x, y - 1, z) == ID_AIR)
					y--;
				if(dy > -1000)
					y += dy;
				set_node(x, y, z, id);
				log_i(MODULE, "skeldat: test: %s at %s", name.empty() ?
						"a marker skull" : cs(name), cs(pos_key(x, y, z)));
				continue;
			}
			if(kind == "course"){
				// [SKELDAT_SKATEBOARD] "course dx dz": a board's course of
				// stone from there along +x, 5 wide, its heights over the
				// player's ground: a platform of 12, a slope down to 0, a
				// ramp of 2 at 1:2, a flat, a wall of 3 at 64 with a hole
				// one high at its middle ([SKELDAT_BOARD_PRONE]) and one
				// at 70 without; and off
				// x 64..69 a slope down 8 along +z and a flat 70 long. The
				// player put on the platform.
				const int X = (int)std::floor(p->x + dx + 0.5f),
						Z = (int)std::floor(p->z + dz + 0.5f),
						B = (int)std::floor(p->y + 0.5f);
				const uint32_t stone = id_of("skeldat:stone");
				auto column = [&](int i, int j, int h){
					const int lo = B + std::min(h, 0) - 3;
					for(int y = lo; y <= std::max(h, 0) + B + 6; y++)
						set_node(X + i, y, Z + j, y < B + h ? stone : ID_AIR);
				};
				for(int i = -3; i <= 75; i++)
				for(int j = -2; j <= 2; j++){
					const int h = i < 4 ? 12 : i < 16 ? 15 - i :
							i >= 36 && i < 40 ? (i - 34) / 2 :
							(i >= 70 && i <= 72) || i == 64 || i == 65 ? 3 : 0;
					column(i, j, h);
					if((i == 64 || i == 65) && j == 0)
						set_node(X + i, B, Z, ID_AIR);
				}
				for(int i = 64; i <= 69; i++)
				for(int j = 3; j <= 78; j++)
					column(i, j, std::max(-8, 2 - j));
				p->x = (float)X, p->y = (float)(B + 12), p->z = (float)Z;
				send_position(peer, *p);
				log_i(MODULE, "skeldat: test: a course at %d,%d,%d", X, B, Z);
				continue;
			}
			if(kind == "lantern"){
				// "lantern dx dz coal": as BUILDAT_SKELDAT_LANTERNS, after
				// what the knobs before it built
				int coal = 1;
				it>>coal;
				test_lanterns((itos((int)std::floor(p->x + dx + 0.5f))+" "+
						itos((int)std::floor(p->z + dz + 0.5f))+" "+
						itos(coal)).c_str());
				continue;
			}
			if(kind == "bones"){
				// "bones dx dz value": the ground's voxel there
				int value = 0;
				it>>value;
				const int x = (int)std::floor(p->x + dx + 0.5f),
						y = (int)std::floor(p->y + 0.5f) - 1,
						z = (int)std::floor(p->z + dz + 0.5f);
				voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
					const pv::Vector3DInt32 v(x, y, z);
					interface::VoxelSample sample = w->get_sample(v, true);
					m_bones.set(sample, (uint32_t)value);
					w->set_sample(v, sample);
				});
				log_i(MODULE, "skeldat: test: bones %d at %d,%d,%d", value,
						x, y, z);
				continue;
			}
			Mob m;
			m.kind = kind == "skeleton" ? SKELETON : BOAR;
			m.x = p->x + dx, m.y = p->y, m.z = p->z + dz;
			voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
				Ground g = ground(w, m.x, m.y + 2, m.z, MOB_HEIGHT[m.kind]);
				if(g.found)
					m.y = g.y;
			});
			// Not near the player's height: on its column's top
			const long c = column((int)std::floor(m.x + 0.5f),
					(int)std::floor(m.z + 0.5f));
			if(m.y == p->y && c >= 0 && m_top_y[c] != NO_GROUND)
				m.y = m_top_y[c] + 0.5f;
			m.hp = MOB_HP[m.kind];
			m.yaw = (float)M_PI;
			m.mode_t = 30;
			// "... marked": its marker skull placed today, so it places
			// none beside itself, which would keep the sun off it.
			// "... seed dx dz n": n night's blocks, the first at that
			// column off the player
			ss_ flag;
			while(it>>flag){
				if(flag == "marked")
					m.marker_day = m_world_t / m_day_s;
				if(flag == "lure")
					m.goal_fp = (int)footprint((int)std::floor(m.x + 0.5f),
							(int)std::floor(m.z + 0.5f));
				if(flag == "seed"){
					float sx = 0, sz = 0;
					it>>sx>>sz>>m.quota;
					m.seed_x = (int)std::floor(p->x + sx + 0.5f);
					m.seed_z = (int)std::floor(p->z + sz + 0.5f);
					m.seeding = true;
				}
			}
			const uint32_t k = m_next_mob++;
			m_mobs[k] = m;
			log_i(MODULE, "skeldat: test: a %s (%u) at %.1f,%.1f,%.1f",
					MOB_KIND[m.kind], k, m.x, m.y, m.z);
		}
	}

	// Woken, it has seen nothing yet
	void wake(Mob &m)
	{
		if(m.mode == FIGHT)
			m.mode = WANDER, m.mode_t = 0;
		m.bx = m.x, m.by = m.y, m.bz = m.z, m.bvy = 0;
		m_woken++;
		main_context::access(m_server, m_scene, [&](Urho3D::Scene *scene){
			Urho3D::Node *n = scene->CreateChild(
					Urho3D::String("skeldat_")+MOB_KIND[m.kind]);
			n->SetPosition(Urho3D::Vector3(m.x, m.y, m.z));
			n->SetRotation(Urho3D::Quaternion(m.yaw * M_RADTODEG,
					Urho3D::Vector3::UP));
			n->SetVar(Urho3D::StringHash("skeldat_hurt"), Urho3D::Variant(m.hurt));
			m.node_id = n->GetID();
		});
	}

	void remove_node(uint32_t &id)
	{
		main_context::access(m_server, m_scene, [&](Urho3D::Scene *scene){
			if(Urho3D::Node *n = scene->GetNode(id))
				n->Remove();
		});
		id = 0;
	}

	void shoot(const Mob &m, const Player &p)
	{
		const float dx = p.x - m.x, dz = p.z - m.z;
		const float h = std::sqrt(dx*dx + dz*dz);
		if(h < 0.5f)
			return;
		Arrow a;
		a.x = m.x + dx / h * 0.6f, a.y = m.y + 1.5f, a.z = m.z + dz / h * 0.6f;
		const float t = h / ARROW_SPEED;
		a.vx = dx / h * ARROW_SPEED + (rnd() - 0.5f) * 0.8f;
		a.vz = dz / h * ARROW_SPEED + (rnd() - 0.5f) * 0.8f;
		a.vy = (p.y + 1.2f - a.y) / t + 0.5f * ARROW_GRAVITY * t +
				(rnd() - 0.5f) * 0.6f;
		main_context::access(m_server, m_scene, [&](Urho3D::Scene *scene){
			Urho3D::Node *n = scene->CreateChild("skeldat_arrow");
			n->SetPosition(Urho3D::Vector3(a.x, a.y, a.z));
			a.node_id = n->GetID();
		});
		m_arrows.push_back(a);
		sound("bow", m.x, m.y + 1.5f, m.z);
		log_i(MODULE, "skeldat: a skeleton shoots at %s", cs(p.name));
	}

	sv_<Stack> drops(const Mob &m)
	{
		sv_<Stack> out;
		if(m.kind == BOAR){
			out.push_back(Stack("skeldat:meat_raw", 1 + m_rand() % 2));
			return out;
		}
		const int bones = 1 + m_rand() % 2, arrows = m_rand() % 3;
		if(bones)
			out.push_back(Stack("skeldat:bone", bones));
		if(arrows)
			out.push_back(Stack("skeldat:arrow", arrows));
		// The end game's part: only a deep skeleton has one
		if(m.y < -32 && rnd() < 0.34f)
			out.push_back(Stack("skeldat:skull"));
		if(m.carry_coal >= 0){
			out.push_back(Stack("skeldat:lantern"));
			if(m.carry_coal > 0)
				out.push_back(Stack("skeldat:coal", m.carry_coal));
		}
		return out;
	}

	// hp off a mob, by a player's hit or by the sun (by NOBODY); it dies at
	// 0, and what it drops goes into the killer's inventory, what does not
	// fit to the ground at the killer
	static const size_t NOBODY = (size_t)-1;
	// ground_drops: with no killer, its drops left on the ground
	void damage(uint32_t key, int hp, size_t by, float bx, float bz,
			bool ground_drops = false)
	{
		Mob &m = m_mobs[key];
		m.hp -= hp;
		m.hurt++;
		if(m.kind == BOAR){
			m.mode = FLEE;
			m.mode_t = 5;
			m.from_x = bx, m.from_z = bz;
		}
		if(m.hp > 0){
			sound(m.kind == BOAR ? "boar_hurt" : "skeleton_hurt", m.x, m.y, m.z);
			return;
		}
		ss_ list;
		auto killer = m_players.find(by);
		const sv_<Stack> dropped = drops(m);
		for(const Stack &s : dropped)
			list += (list.empty() ? "" : ", ") + s.str();
		if(killer != m_players.end()){
			for(const Stack &s : dropped)
				give_or_drop(killer->second, s);
			send_inventory(by, killer->second);
		} else {
			if(ground_drops)
				for(const Stack &s : dropped)
					drop(s, m.x + rnd() - 0.5f, m.y + 0.5f, m.z + rnd() - 0.5f);
			leave_lantern(m);
		}
		log_i(MODULE, "skeldat: the %s (%u) dies at %.1f,%.1f,%.1f, drops [%s]",
				MOB_KIND[m.kind], key, m.x, m.y, m.z, cs(list));
		sound(m.kind == BOAR ? "boar_death" : "skeleton_death", m.x, m.y, m.z);
		if(m.node_id)
			remove_node(m.node_id);
		if(m_store)
			m_store->remove("mob/"+itos(key));
		m_mobs.erase(key);
	}

	// The nearest free ground to a mob within three columns, not its own:
	// an air voxel on a walkable one, round the feet's height
	bool marker_spot(voxelworld::Instance *w, const Mob &m, int out[3])
	{
		const int mx = (int)std::floor(m.x + 0.5f),
				my = (int)std::floor(m.y + 0.5f),
				mz = (int)std::floor(m.z + 0.5f);
		for(int r = 1; r <= 3; r++)
		for(int dz = -r; dz <= r; dz++)
		for(int dx = -r; dx <= r; dx++){
			if(std::max(std::abs(dx), std::abs(dz)) != r)
				continue;
			const int x = mx + dx, z = mz + dz;
			for(int y = my + 1; y >= my - 2; y--){
				if(wid(w, x, y, z) == ID_AIR && walkable(w, x, y - 1, z) &&
						reaches_world(x, y, z)){
					out[0] = x, out[1] = y, out[2] = z;
					return true;
				}
			}
		}
		return false;
	}

	// The body after its light form ([SKELDAT_LIGHT_PRIMARY]): toward it
	// at BODY_SPEED, a step up as a jump, falling; put on it when BODY_LAG
	// off. It faces the player it fights, else the way it goes
	void step_body(voxelworld::Instance *w, Mob &m, const Player *p, float dt)
	{
		const int h = MOB_HEIGHT[SKELETON];
		const float dx = m.x - m.bx, dz = m.z - m.bz,
				flat = std::sqrt(dx * dx + dz * dz);
		// Behind on the ground; a fall to the floor under it is no lag
		if(flat > BODY_LAG || std::fabs(m.y - m.by) > 3 * BODY_LAG){
			m.bx = m.x, m.by = m.y, m.bz = m.z, m.bvy = 0;
			m_body_puts++;
		}
		else if(flat > 0.05f){
			const float k = std::min(1.0f, BODY_SPEED * dt / flat);
			const float nx = m.bx + dx * k, nz = m.bz + dz * k;
			const Ground to = ground(w, nx, m.by, nz, h);
			// Water is a wall to it ([SKELDAT_SKELETON_WATER])
			if(to.found && !to.water && to.y <= m.by + 1.01f){
				m.bx = nx, m.bz = nz;
				if(to.y > m.by)
					m.by = to.y, m.bvy = 0;
			}
			m.yaw = std::atan2(dx, dz);
		}
		const Ground under = ground(w, m.bx, m.by, m.bz, h);
		if(under.found && m.by <= under.y + 0.001f)
			m.bvy = 0, m.by = under.y;
		else {
			m.bvy -= GRAVITY * dt;
			m.by += m.bvy * dt;
			if(under.found)
				m.by = std::max(m.by, under.y);
		}
		// Together and the body on its ground, the light form stands there
		// too: one saved or stepped over a cave's mouth floats otherwise
		if(flat <= 0.05f && under.found && m.bvy == 0)
			m.y = m.by;
		if(p && m.mode == FIGHT)
			m.yaw = std::atan2(p->x - m.bx, p->z - m.bz);
	}

	void step_mobs(float dt)
	{
		// Wake what a player is near, put to sleep what none is
		sv_<uint32_t> awake;
		size_t full = 0;
		for(auto &kv : m_mobs)
			full += kv.second.node_id != 0;
		for(auto &kv : m_mobs){
			Mob &m = kv.second;
			float d;
			nearest(m.x, m.y, m.z, d);
			// simplified: the first in key order past MAX_MOBS wait
			if(!m.node_id && d < WAKE && full < MAX_MOBS){
				wake(m);
				full++;
			}
			else if(m.node_id && d > SLEEP){
				remove_node(m.node_id);
				log_v(MODULE, "skeldat: the %s (%u) sleeps", MOB_KIND[m.kind],
						kv.first);
			}
			if(m.node_id)
				awake.push_back(kv.first);
		}
		if(awake.empty())
			return;
		sv_<std::pair<uint32_t, int>> burnt;
		sv_<uint32_t> drowned;
		sv_<std::pair<uint32_t, size_t>> shots;
		struct Mark { uint32_t key; int p[3]; ss_ seen; };
		sv_<Mark> marks;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(uint32_t key : awake){
				Mob &m = m_mobs[key];
				const int h = MOB_HEIGHT[m.kind];
				// Where the map is not loaded yet, it waits
				const Ground here = ground(w, m.x, m.y, m.z, h);
				if(!here.loaded)
					continue;
				// What it wants: a heading and a speed
				m.mode_t -= dt;
				float d;
				size_t peer = 0;
				const Player *p = nearest(m.x, m.y, m.z, d, &peer);
				if(m.kind == SKELETON){
					// The light form decides (step_light()); here the
					// fight's sight and bow, and the body after it
					if(p && d < 16){
						// Its first sight of a player: a marker skull, one
						// a game day ([SKELDAT_SKELETON_SIM])
						if(m.mode != FIGHT && !m_ended){
							int at[3];
							if(m_world_t / m_day_s - m.marker_day < 1.0 / m_speed)
								log_i(MODULE, "skeldat: a skeleton (%u) sees "
										"%s, its marker placed today", key,
										cs(p->name));
							else if(marker_spot(w, m, at)){
								marks.push_back({key, {at[0], at[1], at[2]},
										p->name});
								m.marker_day = m_world_t / m_day_s;
							}
						}
						m.mode = FIGHT;
						m.shoot_t -= dt;
						if(m.shoot_t <= 0 && d < 14){
							shots.push_back({key, peer});
							m.shoot_t = 1.5f + rnd() * 1.5f;
						}
					} else if(m.mode == FIGHT)
						m.mode = WANDER;
					step_body(w, m, p, dt);
					// [SKELDAT_SKELETON_WATER] Its body in water, the feet's
					// voxel or the one over them: dead at once
					const int bx = (int)std::floor(m.bx + 0.5f),
							by = (int)std::floor(m.by + 0.5f),
							bz = (int)std::floor(m.bz + 0.5f);
					if(is_water(w, bx, by, bz) || is_water(w, bx, by + 1, bz)){
						drowned.push_back(key);
						continue;
					}
					// The sun burns it, unless bones are round its light
					// form
					if(here.sun >= 12){
						m.burn_t += dt;
						if(m.burn_t >= 1){
							m.burn_t = 0;
							if(sun_safe(w, m.x, m.y, m.z) == 0)
								burnt.push_back({key, 2});
						}
					}
					if(m.y < -1000)
						burnt.push_back({key, 1000});
					continue;
				}
				float move_yaw = m.yaw, speed = 0;
				if(m.mode == FLEE && m.mode_t > 0){
					m.yaw = move_yaw = std::atan2(m.x - m.from_x, m.z - m.from_z);
					speed = MOB_SPEED[m.kind][1];
				} else {
					if(m.mode != WANDER || m.mode_t <= 0){
						m.mode = WANDER;
						m.mode_t = 3 + rnd() * 4;
						m.speed = rnd() < 0.5f ? 0 : MOB_SPEED[m.kind][0];
						m.yaw = rnd() * 2 * (float)M_PI;
					}
					move_yaw = m.yaw, speed = m.speed;
				}
				// Where it can go: a step up, or down to a fall; a wall or a
				// drop past three turns it
				const float nx = m.x + std::sin(move_yaw) * speed * dt,
						nz = m.z + std::cos(move_yaw) * speed * dt;
				Ground to;
				const Ground *under = &here;
				if(speed > 0){
					to = ground(w, nx, m.y, nz, h);
					if(to.found && to.y <= m.y + 1.01f){
						m.x = nx, m.z = nz;
						m.y = std::max(m.y, to.y);
						under = &to;
					} else if(m.mode == WANDER)
						m.yaw = rnd() * 2 * (float)M_PI;
				}
				if(under->found){
					if(m.y > under->y + 0.001f){
						m.vy -= GRAVITY * dt;
						m.y = std::max(under->y, m.y + m.vy * dt);
					}
					if(m.y <= under->y)
						m.vy = 0;
				} else {
					m.vy -= GRAVITY * dt;
					m.y += m.vy * dt;
				}
				if(m.y < -1000)
					burnt.push_back({key, 1000});
			}
		});
		for(uint32_t key : awake){
			auto it = m_mobs.find(key);
			pv::Vector3DInt32 at;
			if(it != m_mobs.end() && it->second.kind == SKELETON &&
					it->second.carry_coal < 0 &&
					lantern_at_hand(it->second.x, it->second.y, it->second.z, at))
				take_lantern(key, it->second, at);
		}
		for(const Mark &k : marks){
			set_node(k.p[0], k.p[1], k.p[2], m_marker);
			log_i(MODULE, "skeldat: a skeleton (%u) places a marker skull at "
					"%d,%d,%d on seeing %s", k.key, k.p[0], k.p[1], k.p[2],
					cs(k.seen));
		}
		for(auto &s : shots){
			auto m = m_mobs.find(s.first);
			auto p = m_players.find(s.second);
			if(m == m_mobs.end() || p == m_players.end())
				continue;
			// From the body
			Mob b = m->second;
			b.x = b.bx, b.y = b.by, b.z = b.bz;
			shoot(b, p->second);
		}
		for(uint32_t key : drowned){
			log_i(MODULE, "skeldat: the skeleton (%u) is in water", key);
			Mob &m = m_mobs[key];
			m.x = m.bx, m.y = m.by, m.z = m.bz;
			damage(key, 1000, NOBODY, 0, 0, true);
		}
		for(auto &b : burnt){
			if(!m_mobs.count(b.first))
				continue;
			if(b.second < 1000)
				log_i(MODULE, "skeldat: the skeleton (%u) burns", b.first);
			damage(b.first, b.second, NOBODY, 0, 0);
		}
		main_context::access(m_server, m_scene, [&](Urho3D::Scene *scene){
			for(auto &kv : m_mobs){
				Mob &m = kv.second;
				Urho3D::Node *n = m.node_id ? scene->GetNode(m.node_id) : nullptr;
				if(!n)
					continue;
				if(m.kind == SKELETON)
					n->SetPosition(Urho3D::Vector3(m.bx, m.by, m.bz));
				else
					n->SetPosition(Urho3D::Vector3(m.x, m.y, m.z));
				n->SetRotation(Urho3D::Quaternion(m.yaw * M_RADTODEG,
						Urho3D::Vector3::UP));
				if(m.hurt != m.hurt_sent){
					n->SetVar(Urho3D::StringHash("skeldat_hurt"),
							Urho3D::Variant(m.hurt));
					m.hurt_sent = m.hurt;
				}
			}
		});
	}

	//
	// The skeletons over the whole world ([SKELDAT_SKELETON_SIM])
	//

	size_t footprints() const
	{
		return (size_t)(2 * m_half) * (2 * m_half);
	}

	// For a check (BUILDAT_SKELDAT_SURVEY, [SKELDAT_WORLD_SIZES]): what was
	// made -- the tops' range, the ores, the edge's and the origin's bones
	// -- in a line, and the map into the save
	void survey()
	{
		const int S = skeldat::bones::SECTION, h = m_half * S;
		int lo = 1000, hi = -1000, edge = 0, edge_max = 0;
		for(int z = -h; z < h; z++)
		for(int x = -h; x < h; x++){
			const long c = column(x, z);
			if(m_top_y[c] != NO_GROUND)
				lo = std::min(lo, (int)m_top_y[c]),
				hi = std::max(hi, (int)m_top_y[c]);
			if(x == -h || x == h - 1 || z == -h || z == h - 1)
				edge++, edge_max += m_top_b[c] == skeldat::bones::MAX;
		}
		std::map<uint32_t, size_t> ores;
		// The trees' lowest trunk voxels, and those on grass
		// ([SKELDAT_TREE_DEPTH])
		const uint32_t trunk = id_of("skeldat:tree"),
				grass = id_of("skeldat:grass");
		size_t trunks = 0, on_grass = 0;
		for(const char *n : {"skeldat:coal_ore", "skeldat:iron_ore",
				"skeldat:diamond_ore"})
			ores[id_of(n)] = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(int sz = -m_half; sz < m_half; sz++)
			for(int sx = -m_half; sx < m_half; sx++){
				const interface::VoxelVolume vol = w->get_volume(pv::Region(
						pv::Vector3DInt32(sx * S, m_y0 * S, sz * S),
						pv::Vector3DInt32(sx * S + S - 1, m_y1 * S + S - 1,
						sz * S + S - 1)));
				for(int z = sz * S; z < sz * S + S; z++)
				for(int y = m_y0 * S; y < (m_y1 + 1) * S; y++)
				for(int x = sx * S; x < sx * S + S; x++){
					const uint32_t id = m_format.id.get(vol.sample_at(x, y, z));
					auto it = ores.find(id);
					if(it != ores.end())
						it->second++;
					if(id == trunk && y > m_y0 * S){
						const uint32_t under = m_format.id.get(
								vol.sample_at(x, y - 1, z));
						if(under != trunk)
							trunks++, on_grass += under == grass;
					}
				}
			}
		});
		log_i(MODULE, "skeldat: survey: tops %d..%d, coal %zu, iron %zu, "
				"diamond %zu, edge columns at full bones %d of %d, the "
				"origin's %d, trunks on grass %zu of %zu", lo, hi,
				ores[id_of("skeldat:coal_ore")],
				ores[id_of("skeldat:iron_ore")],
				ores[id_of("skeldat:diamond_ore")], edge_max, edge,
				(int)m_top_b[column(0, 0)], on_grass, trunks);
		write_map();
	}

	static bool valid_speed(int s)
	{
		return s == 1 || s == 2 || s == 5 || s == 10;
	}

	// [SKELDAT_BONE_SPEED] The admin's switch: in the save, the audit log
	// and everyone's chat
	void set_speed(int s, const ss_ &by)
	{
		if(!valid_speed(s) || s == m_speed)
			return;
		m_speed = s;
		m_speed_low = std::min(m_speed_low, s);
		m_save->store("world_menu")->set("speed", itos(s));
		m_store->set("speed_low", itos(m_speed_low));
		audit(by, "", "set", "bone speed "+itos(s)+"x");
		const ss_ line = "The bones now grow at "+itos(s)+"x";
		chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
	}

	// A voxel that can have bones: not air, a marker skull or a lantern
	bool holds_bones(uint32_t id)
	{
		if(m_lantern_ids[0] == ID_IGNORE){
			m_lantern_ids[0] = id_of("skeldat:lantern");
			m_lantern_ids[1] = id_of("skeldat:lantern_active");
		}
		return id != ID_AIR && id != ID_IGNORE && id != m_marker &&
				id != m_lantern_ids[0] && id != m_lantern_ids[1] &&
				id != m_stuck_id;
	}

	// The footprint (x, z) is in, its index in m_flooded and m_markers; -1
	// outside the world
	long footprint(int x, int z) const
	{
		const int S = skeldat::bones::SECTION;
		const int sx = floor_div(x, S) + m_half, sz = floor_div(z, S) + m_half;
		if(sx < 0 || sx >= 2 * m_half || sz < 0 || sz >= 2 * m_half ||
				m_markers.empty())
			return -1;
		return (long)sz * (2 * m_half) + sx;
	}

	// Column (x, z)'s place in m_top_y and m_top_b; -1 outside the world
	long column(int x, int z) const
	{
		const int h = m_half * skeldat::bones::SECTION;
		if(x < -h || x >= h || z < -h || z >= h || m_top_y.empty())
			return -1;
		return (long)(z + h) * (2 * h) + (x + h);
	}

	void set_top(int x, int z, int y, uint32_t id, uint32_t bones)
	{
		const long c = column(x, z);
		if(c < 0)
			return;
		const skeldat::NodeDef *n = node_of(id);
		const bool ground = !n || (n->shape != skeldat::LIQUID &&
				n->shape != skeldat::TORCH);
		m_top_y[c] = ground ? (int8_t)y : NO_GROUND;
		m_top_b[c] = (uint8_t)bones;
	}

	// Footprint i's columns into the top map, and its columns at FLOOD or
	// more into m_flooded
	void sweep(voxelworld::Instance *w, size_t i)
	{
		const int sx = (int)(i % (2 * m_half)) - m_half,
				sz = (int)(i / (2 * m_half)) - m_half;
		const int S = skeldat::bones::SECTION;
		for(int z = sz * S; z < sz * S + S; z++)
		for(int x = sx * S; x < sx * S + S; x++)
			set_top(x, z, NO_GROUND, ID_IGNORE, 0);
		int n = 0;
		each_top(w, sx, sz, [&](int x, int z, int y, uint32_t id,
				const interface::VoxelSample &v){
			const uint32_t b = m_bones.get(v);
			set_top(x, z, y, id, b);
			n += (int)b >= skeldat::bones::FLOOD;
		});
		m_flooded[i] = n;
	}

	// Column (x, z) read again, after a voxel of it changed
	void rescan_column(voxelworld::Instance *w, int x, int z)
	{
		const int S = skeldat::bones::SECTION;
		if(column(x, z) < 0)
			return;
		for(int y = m_y1 * S + S - 1; y >= m_y0 * S; y--){
			const interface::VoxelSample v = w->get_sample(
					pv::Vector3DInt32(x, y, z), true);
			const uint32_t id = m_format.id.get(v);
			if(id != ID_AIR && id != ID_IGNORE && id != m_stuck_id){
				set_top(x, z, y, id, m_bones.get(v));
				return;
			}
		}
		set_top(x, z, NO_GROUND, ID_IGNORE, 0);
	}

	// A light skeleton on a random column past SLEEP of every player: on
	// one at FLOOD, its footprint picked by its flooded columns, or
	// anywhere (on_bones false)
	bool add_skeleton(bool on_bones)
	{
		const int S = skeldat::bones::SECTION;
		int64_t total = 0;
		for(int n : m_flooded)
			total += n;
		if(on_bones && total == 0)
			return false;
		size_t i = m_rand() % footprints();
		if(on_bones){
			int64_t r = (int64_t)(m_rand() % (uint64_t)total);
			for(i = 0; r >= m_flooded[i]; i++)
				r -= m_flooded[i];
		}
		const int x = ((int)(i % (2 * m_half)) - m_half) * S + m_rand() % S,
				z = ((int)(i / (2 * m_half)) - m_half) * S + m_rand() % S;
		const long c = column(x, z);
		if(c < 0 || m_top_y[c] == NO_GROUND ||
				(on_bones && m_top_b[c] < skeldat::bones::FLOOD))
			return false;
		const float y = m_top_y[c] + 0.5f;
		float d;
		nearest((float)x, y, (float)z, d);
		if(d < SLEEP)
			return false;
		Mob m;
		m.kind = SKELETON;
		m.x = (float)x, m.y = y, m.z = (float)z;
		m.hp = MOB_HP[SKELETON];
		m.yaw = rnd() * 2 * (float)M_PI;
		m.light_t = rnd() * m_light_step;
		m_mobs[m_next_mob++] = m;
		return true;
	}

	// The nearest column to (x, z) within SEED_RANGE, not (x, z), whose
	// top is ground with no bones and air above, inside the nine footprints
	// round `fp`
	// simplified: SEED_RANGE, not the whole nine footprints, for the cost
	// of 2000 searches at sunset
	bool clean_column(int x, int z, long fp, int &ox, int &oz)
	{
		const int w = 2 * m_half;
		for(int r = 1; r <= SEED_RANGE; r++)
		for(int dz = -r; dz <= r; dz++)
		for(int dx = -r; dx <= r; dx += (std::abs(dz) == r ? 1 : 2 * r)){
			const long c = column(x + dx, z + dz), f = footprint(x + dx, z + dz);
			if(c < 0 || m_top_y[c] == NO_GROUND || m_top_b[c] != 0 ||
					m_top_y[c] >= (m_y1 + 1) * skeldat::bones::SECTION - 1 ||
					std::abs(f % w - fp % w) > 1 || std::abs(f / w - fp / w) > 1)
				continue;
			ox = x + dx, oz = z + dz;
			return true;
		}
		return false;
	}

	// At sunrise and sunset each skeleton picks, of its footprint and the
	// eight round it, the one with the most marker skulls: its own on a
	// tie, a random one when all have none; at sunset its night's bone
	// blocks too
	void pick_footprints(bool sunset)
	{
		const int w = 2 * m_half;
		size_t moving = 0, n = 0;
		// What lures: the marker skulls, and a burning lantern as
		// LANTERN_LURE of them
		sv_<int> lure = m_markers;
		for(auto &pair : lanterns_by_footprint())
			lure[pair.first] += LANTERN_LURE * (int)pair.second.size();
		for(auto &kv : m_mobs){
			Mob &m = kv.second;
			if(m.kind != SKELETON)
				continue;
			n++;
			const long own = footprint((int)std::floor(m.x + 0.5f),
					(int)std::floor(m.z + 0.5f));
			if(own < 0)
				continue;
			long best = own;
			sv_<long> all;
			for(int dz = -1; dz <= 1; dz++)
			for(int dx = -1; dx <= 1; dx++){
				const long fx = own % w + dx, fz = own / w + dz;
				if(fx < 0 || fx >= w || fz < 0 || fz >= w)
					continue;
				all.push_back(fz * w + fx);
				if(lure[fz * w + fx] > lure[best])
					best = fz * w + fx;
			}
			if(lure[best] == 0)
				best = all[m_rand() % all.size()];
			m.goal_fp = (int)best;
			moving += best != own;
			m.quota = sunset ? (1 + m_rand() % NIGHT_BLOCKS) * m_speed : 0;
			m.seeding = false;
		}
		long most = 0;
		for(size_t i = 0; i < footprints(); i++)
			if(lure[i] > lure[most])
				most = (long)i;
		size_t there = 0;
		for(auto &kv : m_mobs)
			there += kv.second.kind == SKELETON && footprint(
					(int)std::floor(kv.second.x + 0.5f),
					(int)std::floor(kv.second.z + 0.5f)) == most;
		log_i(MODULE, "skeldat: %s: %zu of %zu skeletons to another "
				"footprint; the one with the most markers (%d, at %ld %ld) has "
				"%zu; %zu bone blocks placed since", sunset ? "sunset" :
				"sunrise", moving, n, lure[most], most % w - m_half,
				most / w - m_half, there, m_night_blocks);
		m_night_blocks = 0;
	}

	// Every light skeleton a column each light step, on the top map: at
	// night to its next clean column and a bone block there, else to its
	// footprint, else wandering inside it; on, or a new heading where the
	// next column's top is not within one up and two down
	// [SKELDAT_SURFACE_END] A skeleton's step at (x, z): a deep hole
	// within 2 columns (bones.h's deep_hole(), on the column tops) gets a
	// skull dropped into it in one of HOLE_ONE_IN, at most once a game day
	// a hole; from the lowest rim's height, falling as a drop does
	void drop_into_holes(int x, int z)
	{
		// Once in 1/speed of a day, each step's chance times the speed
		const int day = (int)(m_world_t / m_day_s * m_speed);
		for(int dz = -2; dz <= 2; dz++)
		for(int dx = -2; dx <= 2; dx++){
			const long c = column(x + dx, z + dz);
			if(c < 0 || m_top_y[c] == NO_GROUND || m_top_b[c] != 0)
				continue;
			int around[8], n = 0;
			for(int bz = -1; bz <= 1; bz++)
			for(int bx = -1; bx <= 1; bx++){
				if(bx == 0 && bz == 0)
					continue;
				const long b = column(x + dx + bx, z + dz + bz);
				around[n++] = b < 0 || m_top_y[b] == NO_GROUND ? NO_GROUND :
						m_top_y[b];
			}
			if(!skeldat::bones::deep_hole(m_top_y[c], 0, around))
				continue;
			auto it = m_hole_day.find(c);
			if((it != m_hole_day.end() && it->second == day) ||
					m_rand() % skeldat::bones::HOLE_ONE_IN >= (uint32_t)m_speed)
				continue;
			m_hole_day[c] = day;
			int rim = around[0];
			for(int v : around)
				rim = std::min(rim, v);
			Drop d;
			d.st = Stack("skeldat:skull");
			d.seed = true;
			d.x = (float)(x + dx), d.y = rim + 1.5f, d.z = (float)(z + dz);
			m_drops.push_back(d);
			log_i(MODULE, "skeldat: a skeleton drops a skull into the hole at "
					"%d,%d,%d", x + dx, m_top_y[c], z + dz);
		}
	}

	void step_light(float dt)
	{
		const int64_t t0 = interface::os::time_us();
		const int S = skeldat::bones::SECTION;
		const uint32_t block = id_of("skeldat:bone_block");
		struct Block { int x, y, z; };
		sv_<Block> blocks;
		struct Take { uint32_t key; pv::Vector3DInt32 at; };
		sv_<Take> takes;
		const auto lanterns = lanterns_by_footprint();
		// The light form's next feet at (x, z): the column's top, or for
		// one with a body the ground round its own height (a cave, an
		// overhang), as the body walks; -1e9 for none
		auto next_y = [&](const Mob &m, int x, int z){
			if(m.node_id){
				Ground g;
				voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
					g = ground(w, (float)x, m.y, (float)z, MOB_HEIGHT[SKELETON]);
				});
				// Water a wall ([SKELDAT_SKELETON_WATER]); the column tops
				// have none, a water top being NO_GROUND
				return g.found && !g.water ? g.y : -1e9f;
			}
			const long c = column(x, z);
			return c < 0 || m_top_y[c] == NO_GROUND ? -1e9f :
					m_top_y[c] + 0.5f;
		};
		for(auto &kv : m_mobs){
			Mob &m = kv.second;
			if(m.kind != SKELETON)
				continue;
			// Every skeleton is its light form ([SKELDAT_LIGHT_PRIMARY]);
			// one with a body steps often enough for the body to walk
			const float step = m.node_id ? std::min(NEAR_STEP, m_light_step) :
					m_light_step;
			m.light_t = std::min(m.light_t - dt, step);
			if(m.light_t > 0)
				continue;
			m.light_t += step;
			m_light_steps++;
			const int mx = (int)std::floor(m.x + 0.5f),
					mz = (int)std::floor(m.z + 0.5f);
			if(!m_ended)
				drop_into_holes(mx, mz);
			// Fighting: a bow's distance, between 3 and 9, that a sword's
			// reach can still close
			if(m.node_id && m.mode == FIGHT){
				float d;
				const Player *p = nearest(m.x, m.y, m.z, d);
				if(!p || (d >= 3 && d <= 9))
					continue;
				m.yaw = std::atan2(p->x - m.x, p->z - m.z) +
						(d < 3 ? (float)M_PI : 0);
				const int x = (int)std::floor(m.x + std::sin(m.yaw) + 0.5f),
						z = (int)std::floor(m.z + std::cos(m.yaw) + 0.5f);
				const float y = next_y(m, x, z);
				if(y <= m.y + 1.01f && y >= m.y - 2.01f)
					m.x = (float)x, m.z = (float)z, m.y = y;
				continue;
			}
			// With a body and nothing to do, it stands half the time, as
			// a wandering skeleton did
			if(m.node_id && m.goal_fp < 0 && m.quota <= 0 && rnd() < 0.5f)
				continue;
			const long own = footprint(mx, mz);
			bool to = false;
			int tx = 0, tz = 0;
			// What it must stand next to, for a way built to it: -1e9 for
			// a footprint's middle, which is no such target
			int ty = -1000000000;
			// A burning lantern in its footprint: to it, and taken
			// Or on its way built to one, which may cross out of it
			const bool home = own >= 0 && (own == m.goal_fp ||
					(!m.route.empty() && m.goal_fp >= 0));
			auto lit = lanterns.find(home ? m.goal_fp : own);
			if(m.carry_coal < 0 && home && lit != lanterns.end()){
				const pv::Vector3DInt32 &l = lit->second[0];
				pv::Vector3DInt32 at;
				if(lantern_at_hand(m.x, m.y, m.z, at)){
					takes.push_back({kv.first, at});
					continue;
				}
				to = true, tx = l.getX(), tz = l.getZ(), ty = l.getY();
			}
			if(!to && m.quota > 0 && !m_ended && own >= 0){
				if(!m.seeding && !clean_column(mx, mz, own, m.seed_x,
						m.seed_z))
					m.quota = 0;
				else
					m.seeding = true;
				if(m.seeding && std::abs(m.seed_x - mx) <= 1 &&
						std::abs(m.seed_z - mz) <= 1 &&
						(m.seed_x != mx || m.seed_z != mz)){
					const long c = column(m.seed_x, m.seed_z);
					if(m_top_y[c] != NO_GROUND && m_top_b[c] == 0){
						blocks.push_back({m.seed_x, m_top_y[c] + 1, m.seed_z});
						if(m.built)
							log_i(MODULE, "skeldat: a skeleton (%u) places its "
									"night's block at %d,%d,%d, by the way it "
									"built", kv.first, m.seed_x, m_top_y[c] + 1,
									m.seed_z);
					}
					m.built = false;
					m.seeding = false;
					m.quota--;
				} else if(m.seeding){
					to = true, tx = m.seed_x, tz = m.seed_z;
					const long c = column(tx, tz);
					if(m_top_y[c] != NO_GROUND)
						ty = m_top_y[c] + 1;
				}
			}
			if(!to || ty < -1000)
				m.route.clear();
			if(!m.route.empty()){
				follow_route(kv.first, m);
				continue;
			}
			if(!to && m.goal_fp >= 0 && own != m.goal_fp){
				const int w = 2 * m_half;
				to = true;
				tx = (m.goal_fp % w - m_half) * S + S / 2;
				tz = (m.goal_fp / w - m_half) * S + S / 2;
			}
			if(m.detour > 0)
				m.detour--;
			else if(to)
				m.yaw = std::atan2((float)(tx - mx), (float)(tz - mz)) +
						(rnd() - 0.5f) * 0.6f;
			else if(rnd() < 0.2f)
				m.yaw = rnd() * 2 * (float)M_PI;
			const int x = (int)std::floor(m.x + std::sin(m.yaw) + 0.5f),
					z = (int)std::floor(m.z + std::cos(m.yaw) + 0.5f);
			const float y = next_y(m, x, z);
			// Wandering, it keeps to its footprint
			const bool stray = !to && m.goal_fp >= 0 && own == m.goal_fp &&
					footprint(x, z) != m.goal_fp;
			if(!stray && y <= m.y + 1.01f && y >= m.y - 2.01f)
				m.x = (float)x, m.z = (float)z, m.y = y;
			else if(to && ty > -1000 && m_world_t >= m.search_t &&
					search_way(kv.first, m, vp::P(tx, ty, tz)))
				m.detour = 0;
			else {
				m.yaw = rnd() * 2 * (float)M_PI;
				if(to)
					m.detour = 4 + m_rand() % 12;
			}
		}
		m_light_us += interface::os::time_us() - t0;
		for(const Block &b : blocks){
			set_node(b.x, b.y, b.z, block, 0, skeldat::bones::MAX);
			m_night_blocks++;
		}
		for(const Take &t : takes)
			take_lantern(t.key, m_mobs[t.key], t.at);
	}

	// [SKELDAT_BONE_BRIDGES] A way for m to stand at goal (a feet voxel):
	// a walking one, or one with bone blocks to build, its route up to the
	// first of them. false for none, and it waits BUILD_WAIT to look again.
	// A light form with no body walks the column tops, so under them is
	// solid to it
	bool search_way(uint32_t key, Mob &m, const vp::P &goal)
	{
		m.search_t = m_world_t + BUILD_WAIT;
		const vp::P from((int)std::floor(m.x + 0.5f),
				(int)std::floor(m.y + 1.0f), (int)std::floor(m.z + 0.5f));
		if(std::abs(goal.x - from.x) > BUILD_RANGE ||
				std::abs(goal.z - from.z) > BUILD_RANGE)
			return false;
		// The two and 4 round them, 12 under the lower and 8 over the higher
		const int M = 4, DOWN = 12, UP = 8;
		vp::Field f;
		f.resize(vp::P(std::min(from.x, goal.x) - M,
				std::min(from.y, goal.y) - DOWN, std::min(from.z, goal.z) - M),
				std::abs(goal.x - from.x) + 2 * M + 1,
				std::abs(goal.y - from.y) + DOWN + UP + 1,
				std::abs(goal.z - from.z) + 2 * M + 1);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			fill_cells(w, f);
		});
		// Water is no way for a skeleton ([SKELDAT_SKELETON_WATER])
		for(uint8_t &c : f.cells)
			if(c == vp::CLIMB)
				c = vp::LIQUID;
		// One with no body walks the column tops: solid under them
		if(!m.node_id)
			for(int z = f.origin.z; z < f.origin.z + f.d; z++)
			for(int x = f.origin.x; x < f.origin.x + f.w; x++){
				const long c = column(x, z);
				if(c < 0 || m_top_y[c] == NO_GROUND)
					continue;
				for(int y = f.origin.y; y < m_top_y[c]; y++)
					f.set(x, y, z, vp::SOLID);
			}
		// The target (a lantern) taken as room: it is beside it a step
		// before, where it acts
		f.set(goal.x, goal.y, goal.z, vp::OPEN);
		f.set(goal.x, goal.y + 1, goal.z, vp::OPEN);
		vp::Rules r;
		r.body_height = MOB_HEIGHT[SKELETON];
		r.step_up = 1;
		r.max_fall = 2;
		r.build_cost = BUILD_COST;
		r.max_expanded = BUILD_CAP;
		const vp::Result res = vp::find(f, from, goal, r);
		if(!res.found || res.path.size() < 2)
			return false;
		m.route.assign(res.path.begin() + 1, res.path.end());
		m.build = !res.blocks.empty();
		if(m.build){
			m.build_at = res.blocks[0];
			const vp::P over(m.build_at.x, m.build_at.y + 1, m.build_at.z);
			auto it = std::find(m.route.begin(), m.route.end(), over);
			if(it == m.route.end())
				return m.route.clear(), false;
			m.route.erase(it + 1, m.route.end());
		}
		log_i(MODULE, "skeldat: a skeleton (%u) finds a way to %d,%d,%d: "
				"%zu steps, %zu bone blocks", key, goal.x, goal.y, goal.z,
				res.path.size() - 1, res.blocks.size());
		return true;
	}

	// A step along m's route; at its block's cell, the block built (the
	// night's, or a try at the lantern) and the route done
	void follow_route(uint32_t key, Mob &m)
	{
		const vp::P n = m.route.front();
		if(m.build && m.route.size() == 1){
			const vp::P &b = m.build_at;
			const uint32_t id = id_at(b.x, b.y, b.z);
			const skeldat::NodeDef *def = node_of(id);
			if(id == ID_AIR || (def && def->shape == skeldat::LIQUID)){
				set_node(b.x, b.y, b.z, id_of("skeldat:bone_block"), 0,
						skeldat::bones::MAX);
				m_night_blocks++;
				m.built = true;
				if(m.seeding && m.quota > 0)
					m.quota--;
				log_i(MODULE, "skeldat: a skeleton (%u) builds a bone block "
						"at %d,%d,%d", key, b.x, b.y, b.z);
			}
			m.route.clear();
			m.search_t = 0;
			return;
		}
		const int mx = (int)std::floor(m.x + 0.5f),
				mz = (int)std::floor(m.z + 0.5f);
		float y = -1e9f;
		if(m.node_id){
			Ground g;
			voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
				g = ground(w, (float)n.x, m.y, (float)n.z, MOB_HEIGHT[SKELETON]);
			});
			if(g.found && !g.water)
				y = g.y;
		} else {
			const long c = column(n.x, n.z);
			if(c >= 0 && m_top_y[c] != NO_GROUND)
				y = m_top_y[c] + 0.5f;
		}
		// The world changed under it, or a column top that is not the way
		if(std::abs(n.x - mx) > 1 || std::abs(n.z - mz) > 1 ||
				std::fabs(y - (n.y - 0.5f)) > 0.01f){
			m.route.clear();
			return;
		}
		m.yaw = std::atan2((float)(n.x - mx), (float)(n.z - mz));
		m.x = (float)n.x, m.z = (float)n.z, m.y = y;
		m.route.erase(m.route.begin());
	}

	// A game hour: the count toward its target, added at night on bone
	// columns, let die in the morning on clean ground
	// The bodiless skeletons within FAR_DRAW of each player, to be drawn
	// ([SKELDAT_FAR_SKELETONS]): "x y z yaw" a line, the place rounded to
	// the voxel and the yaw to a sixteenth of a turn; sent when it differs
	void send_far()
	{
		static const float FAR_DRAW = 160;
		for(auto &pair : m_players){
			Player &pl = pair.second;
			if(!pl.placed)
				continue;
			std::ostringstream os;
			size_t n = 0;
			for(auto &kv : m_mobs){
				const Mob &m = kv.second;
				if(m.kind != SKELETON || m.node_id ||
						std::fabs(m.x - pl.x) > FAR_DRAW ||
						std::fabs(m.z - pl.z) > FAR_DRAW ||
						std::hypot(m.x - pl.x, m.z - pl.z) > FAR_DRAW)
					continue;
				const int yaw = ((int)std::lround(m.yaw / (2 * M_PI) * 16) %
						16 + 16) % 16;
				os<<(int)std::floor(m.x + 0.5f)<<" "<<m.y<<" "
						<<(int)std::floor(m.z + 0.5f)<<" "<<yaw<<"\n";
				n++;
			}
			const ss_ s = os.str();
			if(s == pl.far_sent)
				continue;
			pl.far_sent = s;
			network::send(m_server, pair.first, "skeldat:far", s);
			if(m_far_report)
				log_i(MODULE, "skeldat: %zu far skeletons to %s", n,
						cs(pl.name));
		}
	}

	// **The world's edge** ([SKELDAT_EDGE_RIDGE]), once, when the world is
	// first in: over the last EDGE_COLUMNS of each side a hillside of bone
	// blocks from the column's ground (under water, its bed) by
	// bones::edge_rise(), and the outermost column bone_wall from the
	// bottom layer to the hillside's top, which nothing digs.
	// simplified: made here on the whole world, not in the generator,
	// which sees one 64-high section and not a ground in the one under it
	void make_edge()
	{
		using namespace skeldat::bones;
		std::string v;
		if(!m_store || m_store->get("edge", v))
			return;
		const int64_t t0 = interface::os::time_us();
		const int S = SECTION, h = m_half * S, y0 = m_y0 * S,
				top = (m_y1 + 1) * S - 1;
		const uint32_t block = id_of("skeldat:bone_block"),
				wall = id_of("skeldat:bone_wall");
		size_t blocks = 0, walls = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(int sz = -m_half; sz < m_half; sz++)
			for(int sx = -m_half; sx < m_half; sx++){
				if(sx != -m_half && sx != m_half - 1 && sz != -m_half &&
						sz != m_half - 1)
					continue;
				const pv::Region r(pv::Vector3DInt32(sx * S, y0, sz * S),
						pv::Vector3DInt32(sx * S + S - 1, top, sz * S + S - 1));
				const interface::VoxelVolume vol = w->get_volume(r);
				interface::VoxelVolume out(r, m_format.planes);
				size_t changed = 0;
				auto put = [&](int x, int y, int z, uint32_t id){
					interface::VoxelSample s = vol.sample_at(x, y, z);
					s.planes[0] = 0;
					m_format.id.set(s.planes[0], id);
					m_bones.set(s, MAX);
					out.set_sample_at(x, y, z, s);
					changed++;
				};
				for(int z = sz * S; z < sz * S + S; z++)
				for(int x = sx * S; x < sx * S + S; x++){
					const int d = std::min(std::min(x + h, h - 1 - x),
							std::min(z + h, h - 1 - z));
					if(d >= EDGE_COLUMNS)
						continue;
					// The ground: the top voxel that is not air or water
					int g = top;
					for(; g > y0; g--){
						const uint32_t id = m_format.id.get(vol.sample_at(x, g, z));
						const skeldat::NodeDef *n = node_of(id);
						if(id != ID_AIR && id != ID_IGNORE &&
								!(n && n->shape == skeldat::LIQUID))
							break;
					}
					const int rise = edge_rise(d, top - 1 - g);
					for(int y = g + 1; y <= g + rise; y++){
						const uint32_t id = m_format.id.get(vol.sample_at(x, y, z));
						const skeldat::NodeDef *n = node_of(id);
						if(id == ID_AIR || (n && (n->shape == skeldat::LIQUID ||
								n->name == "skeldat:leaves")))
							put(x, y, z, block), blocks++;
					}
					if(d == 0)
						for(int y = y0; y <= g + rise; y++)
							put(x, y, z, wall), walls++;
				}
				if(changed)
					w->set_volume(out);
			}
		});
		m_store->set("edge", "1");
		log_i(MODULE, "skeldat: the edge made: %zu bone blocks, %zu wall "
				"voxels, %.1f ms", blocks, walls,
				(interface::os::time_us() - t0) / 1e3);
	}

	// The skeletons' count and its target by the flooded share f
	size_t skeleton_target(size_t &n, double &f)
	{
		n = 0;
		for(auto &kv : m_mobs)
			n += kv.second.kind == SKELETON;
		int64_t flooded = 0;
		for(int c : m_flooded)
			flooded += c;
		const double columns = (double)footprints() *
				skeldat::bones::SECTION * skeldat::bones::SECTION;
		f = flooded / columns;
		return (size_t)std::lround((SKELETONS_MIN +
				(SKELETONS_MAX - SKELETONS_MIN) * f) * columns / (1024. * 1024.));
	}

	// A world's skeletons there from the start ([SKELDAT_START_SKELETONS]):
	// once a world is in, the first time (a new world, or one made before
	// this), the count up to its target at once, on bone columns (anywhere
	// in a world with none); no player is placed yet, so none is too near
	void populate()
	{
		std::string v;
		if(!m_store || m_store->get("populated", v))
			return;
		size_t n;
		double f;
		const size_t target = skeleton_target(n, f);
		const bool any = std::any_of(m_flooded.begin(), m_flooded.end(),
				[](int c){ return c > 0; });
		size_t added = 0;
		const size_t want = target > n ? target - n : 0;
		for(size_t t = 0; t < 8 * want && added < want; t++)
			added += add_skeleton(any);
		m_store->set("populated", "1");
		log_i(MODULE, "skeldat: populated: %zu skeletons added, %zu in all, "
				"the target %zu", added, n + added, target);
	}

	void step_population()
	{
		size_t n;
		double f;
		const size_t target = skeleton_target(n, f);
		const size_t k = 1 + (n > target ? n - target : target - n) / 10;
		size_t added = 0, died = 0;
		const bool night = m_day < 0.25 || m_day >= 0.75,
				morning = m_day >= 0.25 && m_day < 0.4;
		{
			if(night && n < target){
				const size_t want = std::min(k, target - n);
				// On bones; anywhere in a world with none
				const bool any = std::any_of(m_flooded.begin(),
						m_flooded.end(), [](int c){ return c > 0; });
				for(size_t t = 0; t < 8 * want && added < want; t++)
					added += add_skeleton(any);
			}
			if(morning && n > target){
				const size_t want = std::min(k, n - target);
				for(auto it = m_mobs.begin(); it != m_mobs.end() &&
						died < want;){
					const Mob &m = it->second;
					const long c = column((int)std::floor(m.x + 0.5f),
							(int)std::floor(m.z + 0.5f));
					// By the sun's rule from its voxels; where they are not
					// loaded, the column top's bones.
					// simplified: unloaded, a bone block or skull beside it
					// does not count
					int safe = -1;
					if(m.kind == SKELETON && !m.node_id && c >= 0)
						voxelworld::access(m_server, m_scene,
								[&](voxelworld::Instance *w){
							safe = sun_safe(w, m.x, m.y, m.z);
						});
					if(safe < 0 && c >= 0)
						safe = m_top_b[c] >= skeldat::bones::FLOOD;
					if(m.kind != SKELETON || m.node_id || c < 0 || safe){
						++it;
						continue;
					}
					if(m_store)
						m_store->remove("mob/"+itos(it->first));
					leave_lantern(it->second);
					it = m_mobs.erase(it);
					died++;
				}
			}
		}
		log_i(MODULE, "skeldat: %zu skeletons, the target %zu (%.3f of the "
				"columns flooded); %zu added, %zu let die", n + added - died,
				target, f, added, died);
	}

	// Two points a tick on each flying arrow, the middle and the end: at
	// 18 voxels a second it goes 0.6 a tick, so a point every 0.3
	void step_arrows(float dt)
	{
		pick_stuck();
		if(m_arrows.empty())
			return;
		sv_<char> solid;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(Arrow &a : m_arrows){
				if(a.stuck)
					continue;
				for(float f : {0.5f, 1.0f}){
					const float vy = a.vy - ARROW_GRAVITY * dt;
					solid.push_back(walkable(w,
							(int)std::floor(a.x + a.vx * dt * f + 0.5f),
							(int)std::floor(a.y + vy * dt * f + 0.5f),
							(int)std::floor(a.z + a.vz * dt * f + 0.5f)));
				}
			}
		});
		size_t j = 0;
		sv_<Arrow> kept;
		struct Hit { uint32_t key; int dmg; size_t peer; float x, z; };
		sv_<Hit> hits;
		for(Arrow &a : m_arrows){
			a.age += dt;
			bool gone = !a.stuck && a.age > 8;
			// [SKELDAT_BOW] Stuck: a living player near takes it if it fits;
			// after ARROW_STUCK it is a voxel, or gone where there is no air
			if(a.stuck && (picked(a.x, a.y, a.z) || a.age > ARROW_STUCK)){
				if(a.age > ARROW_STUCK)
					stick_voxel(a);
				remove_node(a.node_id);
				continue;
			}
			const bool was_stuck = a.stuck;
			const size_t base = j;
			if(!a.stuck){
				j += 2;
				a.vy -= ARROW_GRAVITY * dt;
			}
			for(int k = 0; !gone && !a.stuck && k < 2; k++){
				const float f = k ? 1.0f : 0.5f;
				const float x = a.x + a.vx * dt * f, y = a.y + a.vy * dt * f,
						z = a.z + a.vz * dt * f;
				// A player's hits the mobs, as a hit by the player
				if(a.by_player){
					for(auto &kv : m_mobs){
						const Mob &m = kv.second;
						const bool sk = m.kind == SKELETON;
						const float mx = sk ? m.bx : m.x, my = sk ? m.by : m.y,
								mz = sk ? m.bz : m.z;
						if(m.node_id && std::hypot(mx - x, mz - z) < 0.5f &&
								y > my - 0.1f && y < my + MOB_HEIGHT[m.kind] + 0.1f){
							const float v = std::sqrt(a.vx * a.vx + a.vy * a.vy +
									a.vz * a.vz);
							hits.push_back({kv.first, std::max(1, (int)std::lround(
									BOW_DAMAGE * v)), a.peer, x, z});
							sound("arrow_hit", x, y, z);
							gone = true;
							break;
						}
					}
				}
				for(auto &pair : m_players){
					Player &pl = pair.second;
					if(!a.by_player && pl.placed && pl.hp > 0 &&
							std::hypot(pl.x - x, pl.z - z) < 0.45f &&
							y > pl.y - 0.1f && y < pl.y + 1.85f){
						hurt(pair.first, pl, 2 + m_rand() % 3,
								"is hit by an arrow");
						sound("arrow_hit", x, y, z);
						gone = true;
						break;
					}
				}
				if(gone)
					break;
				if(solid[base + k]){
					a.stuck = true;
					a.age = 0;
					a.sx = (int)std::floor(x + 0.5f), a.sy = (int)std::floor(y + 0.5f),
							a.sz = (int)std::floor(z + 0.5f);
					a.fx = (int)std::floor(a.x + 0.5f), a.fy = (int)std::floor(a.y + 0.5f),
							a.fz = (int)std::floor(a.z + 0.5f);
					log_i(MODULE, "skeldat: an arrow sticks at %.1f,%.1f,%.1f",
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
				main_context::access(m_server, m_scene, [&](Urho3D::Scene *scene){
					if(Urho3D::Node *n = scene->GetNode(a.node_id)){
						n->SetPosition(Urho3D::Vector3(a.x, a.y, a.z));
						if(!a.stuck){
							Urho3D::Quaternion r;
							r.FromLookRotation(Urho3D::Vector3(a.vx, a.vy, a.vz));
							n->SetRotation(r);
						}
					}
				});
			}
			kept.push_back(a);
		}
		m_arrows.swap(kept);
		for(const Hit &h : hits){
			if(!m_mobs.count(h.key))
				continue;
			auto pl = m_players.find(h.peer);
			log_i(MODULE, "skeldat: an arrow from %s hits the %s (%u) for %d",
					pl != m_players.end() ? cs(pl->second.name) : "?",
					MOB_KIND[m_mobs[h.key].kind], h.key, h.dmg);
			damage(h.key, h.dmg, h.peer, h.x, h.z);
		}
	}

	// [SKELDAT_BOW] A living player within ARROW_REACH of (x, y, z) with
	// room takes an arrow: true when one did
	bool picked(float x, float y, float z)
	{
		for(auto &pair : m_players){
			Player &pl = pair.second;
			if(!pl.placed || pl.hp <= 0 || std::hypot(pl.x - x, pl.z - z) >=
					ARROW_REACH || y < pl.y - 1 || y > pl.y + 2.5f)
				continue;
			if(!m_game.add(pl.main, Stack("skeldat:arrow")).empty())
				continue;
			send_inventory(pair.first, pl);
			sound("pickup", x, y, z);
			log_i(MODULE, "skeldat: %s picks up an arrow at %.1f,%.1f,%.1f",
					cs(pl.name), x, y, z);
			return true;
		}
		return false;
	}

	// A stuck arrow kept for good: a stuck_arrow voxel where it sticks
	// out, turned to the face it went into (wallmounted's param2 toward
	// that voxel); none where that is not air
	void stick_voxel(const Arrow &a)
	{
		int d[3] = {a.sx - a.fx, a.sy - a.fy, a.sz - a.fz};
		int axis = 0;
		for(int i = 1; i < 3; i++)
			if(std::abs(d[i]) > std::abs(d[axis]))
				axis = i;
		if(d[axis] == 0 || id_at(a.fx, a.fy, a.fz) != ID_AIR)
			return;
		// 0 +y, 1 -y, 2 +x, 3 -x, 4 +z, 5 -z
		const uint32_t param = axis == 1 ? (d[1] > 0 ? 0 : 1) :
				axis == 0 ? (d[0] > 0 ? 2 : 3) : (d[2] > 0 ? 4 : 5);
		set_node(a.fx, a.fy, a.fz, m_stuck_id, param);
		log_i(MODULE, "skeldat: a stuck arrow kept at %d,%d,%d, facing %u",
				a.fx, a.fy, a.fz, param);
	}

	// The stuck_arrow voxels near a living player, picked up as arrows
	void pick_stuck()
	{
		if(m_stuck.empty() || m_players.empty())
			return;
		sv_<ss_> taken;
		for(const ss_ &k : m_stuck){
			int x, y, z;
			if(parse_pos(k, x, y, z) && picked((float)x, (float)y, (float)z))
				taken.push_back(k);
		}
		for(const ss_ &k : taken){
			int x, y, z;
			parse_pos(k, x, y, z);
			set_node(x, y, z, ID_AIR);
		}
	}

	// A client's click at a mob: what the player holds hits it, from no
	// further than a hand reaches with room for the lag
	void punch(size_t peer, Player &pl, uint32_t id)
	{
		if(id == 0 || m_time - pl.last_hit < 0.35 ||
				pl.main[pl.wield].name == "skeldat:bow")
			return;
		for(auto &kv : m_mobs){
			Mob &m = kv.second;
			if(m.node_id != id)
				continue;
			const float dy = pl.y + 1.6f - m.y - MOB_HEIGHT[m.kind] / 2.0f;
			if(std::sqrt((pl.x-m.x)*(pl.x-m.x) + (pl.z-m.z)*(pl.z-m.z) +
					dy * dy) > 6)
				return;
			pl.last_hit = m_time;
			Stack &st = pl.main[pl.wield];
			const skeldat::ItemDef *def = m_game.item(st.name);
			const int dmg = def ? def->fleshy : m_game.hand.fleshy;
			if(def && def->tool){
				st.wear += skeldat::WEAR_MAX /
						(st.name.find("sword") != ss_::npos ? 200 : 100);
				if(st.wear >= skeldat::WEAR_MAX)
					st = Stack();
				send_inventory(peer, pl);
			}
			log_i(MODULE, "skeldat: %s hits the %s (%u) for %d, hp %d",
					cs(pl.name), MOB_KIND[m.kind], kv.first, dmg, m.hp - dmg);
			damage(kv.first, dmg, peer, pl.x, pl.z);
			return;
		}
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_scene)
			return;
		m_time += event.dtime;
		m_world_t += event.dtime;
		m_session.tick(event.dtime);
		m_day = std::fmod(m_day + event.dtime / m_day_s, 1.0);
		// Every section loaded and generated: on the tick, after the
		// requests the last loads made are in m_awaiting
		if(!m_world_ready && m_save && m_sections.size() == all_sections() &&
				m_awaiting.empty())
			world_in();
		if(!m_ended)
			step_bones(event.dtime);
		if(!m_ended && m_world_ready)
			for(auto &pair : m_players)
				if(pair.second.placed)
					m_played[pair.second.name] += event.dtime;
		step_end();
		step_arrows(event.dtime);
		step_drops(event.dtime);
		m_ai_t += event.dtime;
		if(m_ai_t >= 0.1f){
			// A long tick in steps of 0.2 s, so it is no fall through the
			// ground and a body keeps up with its light form, which steps
			// by the clock; past a second (the world's first sweep, 1.7 s)
			// the rest is dropped
			for(float left = std::min(m_ai_t, 1.0f); left > 1e-4f; left -= 0.2f)
				step_mobs(std::min(left, 0.2f));
			m_ai_t = 0;
		}
		if(m_world_ready){
			step_light(event.dtime);
			m_far_t += event.dtime;
			if(m_far_t >= std::min(m_light_step, 1.0f)){
				m_far_t = 0;
				send_far();
			}
			m_sweep_t += event.dtime;
			if(m_sweep_t >= 1){
				m_sweep_t = 0;
				const int64_t t0 = interface::os::time_us();
				voxelworld::access(m_server, m_scene,
						[&](voxelworld::Instance *w){
					sweep(w, m_sweep++ % footprints());
				});
				m_light_us += interface::os::time_us() - t0;
			}
			const int phase = m_day >= 0.25 && m_day < 0.75;
			// The first tick's too: a world that starts at night has its
			// night's work
			if(phase != m_phase)
				pick_footprints(phase == 0);
			m_phase = phase;
			m_hour_t += event.dtime;
			if(m_hour_t >= m_day_s / 24){
				m_hour_t = 0;
				step_population();
			}
		}
		m_spawn_t += event.dtime;
		if(!m_test.empty())
			stage_test();
		else if(m_spawn_t >= 4){
			m_spawn_t = 0;
			spawn();
		}
		if(m_load_points_dirty)
			update_load_points();
		m_send_t += event.dtime;
		if(m_send_t >= 0.2f){
			m_send_t = 0;
			send_players();
		}
		m_move_t += event.dtime;
		if(m_move_t >= 1){
			m_move_t = 0;
			check_moves();
			update_skeletons();
		}
		m_breath_t += event.dtime;
		if(m_breath_t >= 1){
			m_breath_t = 0;
			step_breath();
		}
		m_furnace_t += event.dtime;
		if(m_furnace_t >= 1){
			m_furnace_t = 0;
			for(auto &pair : m_furnaces)
				if(pair.second.lantern)
					step_lantern(pair.first, pair.second);
				else
					step_furnace(pair.first, pair.second);
		}
		m_save_t += event.dtime;
		if(m_save_t >= 10){
			m_save_t = 0;
			save();
			// The pace, for whoever tunes it
			log_i(MODULE, "skeldat: bones: %zu expansions so far, %zu voxels "
					"changed, %zu grown, %zu sections loaded, %zu rule runs "
					"at %dx", m_expansions, m_expand_changed, m_grown,
					m_sections.size(), m_rule_runs, m_speed);
			size_t skeletons = 0, full = 0;
			for(auto &kv : m_mobs)
				if(kv.second.kind == SKELETON)
					skeletons++, full += kv.second.node_id != 0;
			log_i(MODULE, "skeldat: %zu skeletons, %zu full, %zu woken; %zu "
					"light steps and the sweep, %.2f ms a second; %zu bodies "
					"put back", skeletons, full, m_woken, m_light_steps,
					m_light_us / 1e3 / 10, m_body_puts);
			m_light_us = 0, m_light_steps = 0, m_woken = 0, m_body_puts = 0;
			if(m_lantern_report)
				report_lanterns();
			for(auto &pair : m_players)
				send_time(pair.first);
		}
	}

	// The admin's menu ([SKELDAT] decision 4): a player's inventory viewed,
	// an item given to it or taken from it, each in moderation's audit log
	// of the world's save. "skeldat:admin" both ways, a command a line:
	//   players                    -> players\n<name> a line
	//   view <name>                -> inv <name>\nmain=<list_text's>
	//                                 invulnerable=0|1 (a line)
	//   give <name> <item> <count> -> the view again
	//   take <name> <slot>         -> the view again
	//   invulnerable <name> on|off -> the view again
	//   audit                      -> audit\n<ts by action whom text> a line
	// simplified: the players on the server now, not the save's others
	void on_admin(const network::Packet &packet)
	{
		const size_t peer = packet.sender;
		auto me = m_players.find(peer);
		if(me == m_players.end() || !m_save || !is_admin(peer))
			return;
		std::istringstream is(packet.data);
		ss_ cmd, name;
		is>>cmd>>name;
		if(cmd == "speed"){
			set_speed(atoi(name.c_str()), me->second.name);
			cmd = "players";
		}
		if(cmd == "players"){
			ss_ out = "players "+itos(m_speed)+"\n";
			for(auto &pair : m_players)
				out += pair.second.name+"\n";
			network::send(m_server, peer, "skeldat:admin", out);
			return;
		}
		if(cmd == "map"){
			network::send(m_server, peer, "skeldat:admin", "map\n"+write_map());
			return;
		}
		if(cmd == "audit"){
			std::ostringstream os;
			os<<"audit\n";
			moderation::access(m_server, [&](moderation::Interface *m){
				m_audit.m_save = m_save;
				const json::Value l = m->audit_log(&m_audit);
				for(unsigned i = 0; i < l.size() && i < 50; i++){
					const json::Value &a = l.at(i);
					os<<json::jstr(a, "by")<<" "<<json::jstr(a, "action")<<" "
							<<json::jstr(a, "listing")<<": "
							<<json::jstr(a, "text")<<"\n";
				}
			});
			network::send(m_server, peer, "skeldat:admin", os.str());
			return;
		}
		size_t to = 0;
		Player *pl = nullptr;
		for(auto &pair : m_players){
			if(pair.second.name == name){
				to = pair.first;
				pl = &pair.second;
			}
		}
		if(!pl)
			return;
		const ss_ by = me->second.name;
		if(cmd == "give"){
			ss_ item;
			int count = 0;
			const skeldat::ItemDef *d = nullptr;
			if(!(is>>item>>count) || !(d = m_game.item(item)))
				return;
			count = std::max(1, std::min(count,
					m_game.stack_max(item)));
			const Stack left = m_game.add(pl->main, Stack(item, count));
			const int given = count - left.count;
			if(given > 0)
				audit(by, name, "give", itos(given)+" "+item);
		} else if(cmd == "take"){
			int slot = -1;
			if(!(is>>slot) || slot < 0 || slot >= (int)pl->main.size() ||
					pl->main[slot].empty())
				return;
			const ss_ what = pl->main[slot].str();
			pl->main[slot] = Stack();
			audit(by, name, "take", what);
		} else if(cmd == "invulnerable"){
			ss_ v;
			is>>v;
			if(v != "on" && v != "off")
				return;
			pl->invulnerable = v == "on";
			audit(by, name, "set", "invulnerable "+v);
		} else if(cmd != "view"){
			return;
		}
		if(cmd != "view")
			send_inventory(to, *pl);
		network::send(m_server, peer, "skeldat:admin", "inv "+name+"\n"+
				list_text("main", pl->main)+"invulnerable="+
				(pl->invulnerable ? "1" : "0"));
	}

	// **The world from above** ([SKELDAT_BOUNDED_WORLD]), for the tuning: a
	// pixel a column, its top voxel's colour (grass, water, the rest grey)
	// whitened by its bones, +x right and +z up; map.png in the world's
	// save. What it says: where it went, or why not.
	// Each column of a section's footprint (sx, sz) with a voxel in it:
	// fn(x, z, its top voxel's y, id, the voxel)
	template<typename F>
	void each_top(voxelworld::Instance *w, int sx, int sz, F fn)
	{
		const int S = skeldat::bones::SECTION;
		const pv::Region r(pv::Vector3DInt32(sx * S, m_y0 * S, sz * S),
				pv::Vector3DInt32(sx * S + S - 1, m_y1 * S + S - 1,
				sz * S + S - 1));
		const interface::VoxelVolume vol = w->get_volume(r);
		for(int z = sz * S; z < sz * S + S; z++)
		for(int x = sx * S; x < sx * S + S; x++)
		for(int y = m_y1 * S + S - 1; y >= m_y0 * S; y--){
			const interface::VoxelSample v = vol.sample_at(x, y, z);
			const uint32_t id = m_format.id.get(v);
			if(id == ID_AIR || id == ID_IGNORE)
				continue;
			fn(x, z, y, id, v);
			break;
		}
	}

	ss_ write_map()
	{
		const int S = skeldat::bones::SECTION, W = 2 * m_half * S;
		sv_<unsigned char> rgb((size_t)W * W * 3, 0);
		const uint32_t grass = id_of("skeldat:grass");
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(int sz = -m_half; sz < m_half; sz++)
			for(int sx = -m_half; sx < m_half; sx++)
			each_top(w, sx, sz, [&](int x, int z, int, uint32_t id,
					const interface::VoxelSample &v){
				const skeldat::NodeDef *n = node_of(id);
				const bool water = n && n->shape == skeldat::LIQUID;
				const float base[3] = {
					id == grass ? 60.f : water ? 40.f : 128.f,
					id == grass ? 140.f : water ? 80.f : 128.f,
					id == grass ? 60.f : water ? 200.f : 128.f};
				const float b = m_bones.get(v) / (float)skeldat::bones::MAX;
				const size_t i = ((size_t)(W - 1 - (z + m_half * S)) * W +
						(x + m_half * S)) * 3;
				for(int k = 0; k < 3; k++)
					rgb[i + k] = (unsigned char)(base[k] + (240 - base[k]) * b);
			});
		});
		const ss_ path = m_save->path()+"/map.png";
		bool ok = false;
		main_context::access(m_server, [&](main_context::Interface *imc){
			Urho3D::Image img(imc->get_context());
			ok = img.SetSize(W, W, 3);
			if(ok){
				img.SetData(rgb.data());
				ok = img.SavePNG(path.c_str());
			}
		});
		log_i(MODULE, "skeldat: the map %s %s", ok ? "written to" :
				"not written to", cs(path));
		return (ok ? "Written to " : "Not written to ")+path;
	}

	void audit(const ss_ &by, const ss_ &whom, const ss_ &action,
			const ss_ &text)
	{
		moderation::access(m_server, [&](moderation::Interface *m){
			m_audit.m_save = m_save;
			m->audit(&m_audit, by, whom, action, "admin", text, false, false);
		});
		log_i(MODULE, "skeldat: %s %ss %s: %s", cs(by), cs(action), cs(whom),
				cs(text));
	}

	bool is_admin(size_t peer)
	{
		bool admin = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			admin = i->is_local(peer) ||
					i->level(i->name_of(peer)) >= accounts::LV_ADMIN;
		});
		return admin;
	}

	// accounts' admin, or the launcher's own client (its owner token): fly,
	// fast and noclip on the client, no movement check here. Sent as it
	// changes, and always when `tell`.
	void update_role(size_t peer, Player &pl, bool tell)
	{
		const bool admin = is_admin(peer);
		if(admin == pl.admin && !tell)
			return;
		pl.admin = admin;
		network::send(m_server, peer, "skeldat:role", admin ? "admin" : "");
		log_i(MODULE, "skeldat: %s is %s", cs(pl.name),
				admin ? "an admin" : "a player");
	}

	// A pathfinder's box from one read of the voxels: walkable() is SOLID,
	// is_water() CLIMB, by the id
	void fill_cells(voxelworld::Instance *w, vp::Field &f)
	{
		const pv::Region region(
				pv::Vector3DInt32(f.origin.x, f.origin.y, f.origin.z),
				pv::Vector3DInt32(f.origin.x + f.w - 1, f.origin.y + f.h - 1,
						f.origin.z + f.d - 1));
		interface::VoxelVolume vol = w->get_volume(region);
		for(int y = f.origin.y; y < f.origin.y + f.h; y++)
		for(int z = f.origin.z; z < f.origin.z + f.d; z++)
		for(int x = f.origin.x; x < f.origin.x + f.w; x++){
			// Over the world's top is open air; past its sides, nothing
			// to walk in
			if(y >= (m_y1 + 1) * skeldat::bones::SECTION){
				f.cells[f.index(x, y, z)] = vp::OPEN;
				continue;
			}
			const uint32_t id = m_format.id.get(vol.sample_at(x, y, z));
			if(id >= m_cell_of.size()){
				const size_t from = m_cell_of.size();
				m_cell_of.resize(id + 1);
				for(size_t i = from; i <= id; i++){
					const skeldat::NodeDef *n = node_of(i);
					m_cell_of[i] = i == ID_AIR ? vp::OPEN :
							!n ? vp::SOLID : n->shape == skeldat::LIQUID ?
							vp::CLIMB : n->shape == skeldat::TORCH ||
							!n->walkable ? vp::OPEN :
							vp::SOLID;
				}
			}
			f.cells[f.index(x, y, z)] = m_cell_of[id];
		}
	}

	// The movement check (move_check.h), every second for each player not
	// an admin: a move that could not have been made is pulled back to
	// where the last check passed
	// simplified: every player in the same tick, under a millisecond each
	// (2026-10-15); spread them over the second when there are many
	void check_moves()
	{
		for(auto &pair : m_players){
			const size_t peer = pair.first;
			Player &pl = pair.second;
			update_role(peer, pl, false);
			if(!pl.placed)
				continue;
			const float dt = (float)(m_time - pl.check_t);
			skeldat::move_check::Board bd;
			bd.on = pl.board_seen;
			bd.v0 = pl.check_v;
			bd.air = pl.board_air;
			bd.prone = pl.prone_seen;
			pl.board_seen = pl.board;
			pl.prone_seen = pl.prone;
			if(pl.admin || pl.hp <= 0 || dt <= 0 || pl.moved){
				pl.cx = pl.x;
				pl.cy = pl.y;
				pl.cz = pl.z;
				pl.check_t = m_time;
				pl.check_air = false;
				pl.check_v = 0;
				pl.board_air = 0;
				continue;
			}
			skeldat::move_check::Verdict v;
			voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
				v = skeldat::move_check::check([&](vp::Field &f){
					fill_cells(w, f);
				}, pl.cx, pl.cy, pl.cz, pl.x, pl.y, pl.z, dt, pl.check_air, bd);
			});
			if(v.ok){
				pl.cx = pl.x;
				pl.cy = pl.y;
				pl.cz = pl.z;
				pl.check_t = m_time;
				pl.check_air = v.air;
				pl.check_v = v.speed;
				pl.board_air = bd.on && v.air ? bd.air + 1 : 0;
				continue;
			}
			log_i(MODULE, "skeldat: %s pulled back from (%.1f, %.1f, %.1f) to "
					"(%.1f, %.1f, %.1f): %s%s", cs(pl.name), pl.x, pl.y, pl.z,
					pl.cx, pl.cy, pl.cz, v.why, bd.on ? " (on the board)" : "");
			// The client's board stops where it is put
			pl.check_v = 0;
			pl.board_air = 0;
			pl.x = pl.cx;
			pl.y = pl.cy;
			pl.z = pl.cz;
			const bool air = pl.check_air;
			send_position(peer, pl);
			pl.check_air = air;
		}
	}

	// [SKELDAT_SKELETON_PLAYERS] Who looks like a skeleton (bones.h's
	// skeleton_near()), admins too; a change logged, and it goes out in
	// send_players()
	void update_skeletons()
	{
		for(auto &pair : m_players){
			Player &pl = pair.second;
			if(!pl.placed)
				continue;
			const int x = (int)std::floor(pl.x + 0.5f),
					y = (int)std::floor(pl.y + 0.5f),
					z = (int)std::floor(pl.z + 0.5f);
			bool now = false;
			voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
				now = skeldat::bones::skeleton_near([&](int vx, int vy, int vz){
					return (int)m_bones.get(w->get_sample(
							pv::Vector3DInt32(vx, vy, vz), true));
				}, x, y, z);
			});
			if(now == pl.skeleton)
				continue;
			pl.skeleton = now;
			log_i(MODULE, "skeldat: %s looks like %s to the others",
					cs(pl.name), now ? "a skeleton" : "a player");
		}
	}

	// Where the others are, to everyone: "name x y z yaw skeleton" a line,
	// skeleton 1 or 0
	void send_players()
	{
		for(auto &to : m_players){
			std::ostringstream os;
			for(auto &pair : m_players){
				const Player &o = pair.second;
				if(pair.first != to.first && o.placed && o.hp > 0)
					os<<o.name<<" "<<o.x<<" "<<o.y<<" "<<o.z<<" "<<o.yaw
							<<" "<<(o.skeleton ? 1 : 0)<<" "<<(o.board ? 1 : 0)
							<<" "<<(o.prone ? 1 : 0)<<"\n";
			}
			network::send(m_server, to.first, "skeldat:players", os.str());
		}
	}

	// Drowning: a breath a second with the head in water, then a hit
	// point; two breaths back a second out of it
	void step_breath()
	{
		const uint32_t water = id_of("skeldat:water_source");
		for(auto &pair : m_players){
			Player &pl = pair.second;
			if(!pl.placed || pl.hp <= 0)
				continue;
			const bool under = id_at((int)std::floor(pl.x + 0.5f),
					(int)std::floor(pl.y + 1.6f + 0.5f),
					(int)std::floor(pl.z + 0.5f)) == water;
			const int was = pl.breath;
			if(under && pl.breath > 0)
				pl.breath--;
			else if(under)
				hurt(pair.first, pl, 1, "drowns");
			else
				pl.breath = std::min(BREATH_MAX, pl.breath + 2);
			if(pl.breath != was)
				send_stats(pair.first, pl);
		}
	}

	// A second of a furnace: fuel taken when there is something to cook,
	// the cooking done when its time is up
	void step_furnace(const ss_ &at, Furnace &f)
	{
		const skeldat::Cooking *c = f.src.empty() ? nullptr :
				m_game.cooks(f.src.name);
		const bool cookable = c && (f.dst.empty() || (f.dst.name == c->output
				&& f.dst.count < m_game.stack_max(c->output)));
		const bool before = f.fuel_left > 0;
		bool changed = false;
		if(cookable && f.fuel_left <= 0){
			auto fuel = m_game.fuel.find(f.fuel.name);
			if(!f.fuel.empty() && fuel != m_game.fuel.end()){
				f.fuel_left = fuel->second;
				f.fuel.take(1);
				changed = true;
			}
		}
		float t = 0;
		if(f.fuel_left > 0){
			f.fuel_left -= 1;
			if(cookable){
				t = f.src_time + 1;
				if(t >= c->time){
					if(f.dst.empty())
						f.dst = Stack(c->output);
					else
						f.dst.count++;
					f.src.take(1);
					log_i(MODULE, "skeldat: the furnace at %s made %s",
							cs(at), cs(c->output));
					t = 0;
					changed = true;
				}
			}
		}
		f.src_time = t;
		if(changed)
			send_furnace(at);
		if(before != (f.fuel_left > 0)){
			int x, y, z;
			char ch;
			std::istringstream is(at);
			if(!(is>>x>>ch>>y>>ch>>z))
				return;
			// The front lit or not, the way it faces kept
			const VoxelInstance v = voxel_at(x, y, z);
			const uint32_t id = m_format.id.get(v.data);
			const uint32_t want = id_of(f.fuel_left > 0 ?
					"skeldat:furnace_active" : "skeldat:furnace");
			if(id != want && (id == id_of("skeldat:furnace") ||
					id == id_of("skeldat:furnace_active")))
				set_node(x, y, z, want, m_format.param.get(v.data));
		}
	}

	//
	// Lanterns ([SKELDAT_FIGHT_BACK])
	//

	// A lantern a second: its coal burning down, the next taken from its
	// slot, the node lit while one burns
	void step_lantern(const ss_ &at, Furnace &f)
	{
		const bool before = f.fuel_left > 0;
		if(f.fuel_left > 0)
			f.fuel_left -= 1;
		if(f.fuel_left <= 0 && f.fuel.name == "skeldat:coal" &&
				!f.fuel.empty()){
			f.fuel_left = m_day_s / 24 * LANTERN_HOURS;
			f.fuel.take(1);
			send_furnace(at);
		}
		const bool lit = f.fuel_left > 0;
		int x, y, z;
		if(before == lit || !parse_pos(at, x, y, z))
			return;
		const uint32_t id = id_at(x, y, z);
		if(id == id_of("skeldat:lantern") ||
				id == id_of("skeldat:lantern_active"))
			set_node(x, y, z, id_of(lit ? "skeldat:lantern_active" :
					"skeldat:lantern"));
		log_i(MODULE, "skeldat: the lantern at %s %s", cs(at),
				lit ? "is lit" : "goes out");
	}

	static bool parse_pos(const ss_ &at, int &x, int &y, int &z)
	{
		char c;
		std::istringstream is(at);
		return (bool)(is>>x>>c>>y>>c>>z);
	}

	// The burning lanterns whose spheres reach into `r`
	sv_<pv::Vector3DInt32> lanterns_in(const pv::Region &r)
	{
		sv_<pv::Vector3DInt32> out;
		const pv::Vector3DInt32 &lc = r.getLowerCorner(),
				&uc = r.getUpperCorner();
		for(auto &pair : m_furnaces){
			int x, y, z;
			if(!pair.second.lantern || pair.second.fuel_left <= 0 ||
					!parse_pos(pair.first, x, y, z))
				continue;
			if(x + LANTERN_RADIUS >= lc.getX() && x - LANTERN_RADIUS <=
					uc.getX() && y + LANTERN_RADIUS >= lc.getY() &&
					y - LANTERN_RADIUS <= uc.getY() &&
					z + LANTERN_RADIUS >= lc.getZ() &&
					z - LANTERN_RADIUS <= uc.getZ())
				out.push_back(pv::Vector3DInt32(x, y, z));
		}
		return out;
	}

	// The burning lanterns by footprint
	std::map<long, sv_<pv::Vector3DInt32>> lanterns_by_footprint()
	{
		std::map<long, sv_<pv::Vector3DInt32>> out;
		for(auto &pair : m_furnaces){
			int x, y, z;
			if(pair.second.lantern && pair.second.fuel_left > 0 &&
					parse_pos(pair.first, x, y, z) && footprint(x, z) >= 0)
				out[footprint(x, z)].push_back(pv::Vector3DInt32(x, y, z));
		}
		return out;
	}

	// A burning lantern within a column of (x, z) and two voxels of y
	bool lantern_at_hand(float x, float y, float z, pv::Vector3DInt32 &at)
	{
		for(auto &pair : m_furnaces){
			int lx, ly, lz;
			if(pair.second.lantern && pair.second.fuel_left > 0 &&
					parse_pos(pair.first, lx, ly, lz) &&
					std::fabs(lx - x) <= 1.5f && std::fabs(lz - z) <= 1.5f &&
					std::fabs(ly - y) <= 2.5f){
				at = pv::Vector3DInt32(lx, ly, lz);
				return true;
			}
		}
		return false;
	}

	// A skeleton takes the lantern at `at`: out of the world, put out, its
	// coal with it
	void take_lantern(uint32_t key, Mob &m, const pv::Vector3DInt32 &at)
	{
		const ss_ k = pos_key(at.getX(), at.getY(), at.getZ());
		auto it = m_furnaces.find(k);
		if(it == m_furnaces.end() || m.carry_coal >= 0)
			return;
		m.carry_coal = it->second.fuel.name == "skeldat:coal" ?
				it->second.fuel.count : 0;
		m_furnaces.erase(it);
		if(m_store)
			m_store->remove("furnace/"+k);
		set_node(at.getX(), at.getY(), at.getZ(), ID_AIR);
		log_i(MODULE, "skeldat: a skeleton (%u) takes the lantern at %s, %d "
				"coal in it", key, cs(k), m.carry_coal);
	}

	// A skeleton dead with no one to take what it had: its lantern left
	// where it died, unlit, with its coal
	void leave_lantern(Mob &m)
	{
		if(m.carry_coal < 0)
			return;
		const int x = (int)std::floor(m.x + 0.5f),
				z = (int)std::floor(m.z + 0.5f);
		int y = (int)std::floor(m.y + 0.5f);
		while(y < (int)std::floor(m.y + 0.5f) + 3 && id_at(x, y, z) != ID_AIR)
			y++;
		if(!reaches_world(x, y, z) || id_at(x, y, z) != ID_AIR){
			log_i(MODULE, "skeldat: the lantern lost at %d,%d,%d", x, y, z);
			m.carry_coal = -1;
			return;
		}
		set_node(x, y, z, id_of("skeldat:lantern"));
		Furnace f;
		f.lantern = true;
		if(m.carry_coal > 0)
			f.fuel = Stack("skeldat:coal", m.carry_coal);
		m_furnaces[pos_key(x, y, z)] = f;
		log_i(MODULE, "skeldat: the lantern left at %s, %d coal in it",
				cs(pos_key(x, y, z)), m.carry_coal);
		m.carry_coal = -1;
	}

	// For a check: each lantern's sphere, its voxels with bones, their
	// mean and its bone blocks, a line each
	void report_lanterns()
	{
		const uint32_t block = id_of("skeldat:bone_block");
		const int R = LANTERN_RADIUS;
		for(auto &pair : m_furnaces){
			int lx, ly, lz;
			if(!pair.second.lantern || !parse_pos(pair.first, lx, ly, lz))
				continue;
			int n = 0, with = 0, blocks = 0;
			double sum = 0;
			voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
				for(int z = -R; z <= R; z++)
				for(int y = -R; y <= R; y++)
				for(int x = -R; x <= R; x++){
					if(x * x + y * y + z * z > R * R)
						continue;
					const interface::VoxelSample v = w->get_sample(
							pv::Vector3DInt32(lx + x, ly + y, lz + z), true);
					const uint32_t id = m_format.id.get(v);
					if(!holds_bones(id))
						continue;
					const uint32_t b = m_bones.get(v);
					n++, with += b > 0, sum += b, blocks += id == block;
				}
			});
			log_i(MODULE, "skeldat: the lantern at %s %s: %d voxels in %d, "
					"%d with bones, mean %.2f, %d bone blocks", cs(pair.first),
					pair.second.fuel_left > 0 ? "burning" : "out", n, R, with,
					n ? sum / n : 0.0, blocks);
		}
	}

	// For a check, BUILDAT_SKELDAT_LANTERNS="x z coal [block]; ...": a
	// lantern on each column's top with that many coal, and with block 1
	// a bone block two to its +x
	void test_lanterns(const char *spec)
	{
		std::istringstream is(spec);
		ss_ item;
		const uint32_t block = id_of("skeldat:bone_block");
		while(std::getline(is, item, ';')){
			int x, z, coal, with_block = 0;
			if(sscanf(item.c_str(), "%d %d %d %d", &x, &z, &coal,
					&with_block) < 3)
				continue;
			const long c = column(x, z), c2 = column(x + 2, z);
			if(c < 0 || c2 < 0 || m_top_y[c] == NO_GROUND ||
					m_top_y[c2] == NO_GROUND){
				log_w(MODULE, "skeldat: test: no ground for a lantern at %d %d",
						x, z);
				continue;
			}
			const int y = m_top_y[c] + 1;
			// Lit already, a coal of them burning
			set_node(x, y, z, id_of(coal > 0 ? "skeldat:lantern_active" :
					"skeldat:lantern"));
			Furnace f;
			f.lantern = true;
			if(coal > 0)
				f.fuel_left = m_day_s / 24 * LANTERN_HOURS;
			if(coal > 1)
				f.fuel = Stack("skeldat:coal", coal - 1);
			m_furnaces[pos_key(x, y, z)] = f;
			if(with_block)
				set_node(x + 2, m_top_y[c2] + 1, z, block, 0,
						skeldat::bones::MAX);
			log_i(MODULE, "skeldat: test: a lantern at %s with %d coal",
					cs(pos_key(x, y, z)), coal);
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
