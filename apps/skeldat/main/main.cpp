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
// server runs, or until the picker switches or closes it from the pause
// menu ([SKELDAT_WORLD_ADMIN]). BUILDAT_SKELDAT_WORLD=<name> skips the menu
// (the checks; a server nobody sits at).
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

#include "world_view.h"
#include "furnaces.h"
#include "drops.h"
#include "bones_growth.h"
#include "mobs.h"

struct Module: public interface::Module, public luanti_session::Game,
		public MobsHost
{
	interface::Server *m_server;
	const skeldat::Game m_game = skeldat::make_game();
	// The world as the parts see it (world_view.h)
	WorldView m_world{m_server, m_game};
	storage::Save *m_save = nullptr;
	AuditHost m_audit;
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
	// [SKELDAT_WORLD_ADMIN] The world paused, by whom, and whether by a
	// single player's open pause menu (auto); the peers whose refused
	// requests were logged this pause
	bool m_paused = false, m_pause_auto = false;
	ss_ m_paused_by;
	std::set<size_t> m_pause_refused;
	// [SKELDAT_SKIP_TIME] A skip to sunrise or sunset: the game seconds
	// left of it (0: none) and in all, the wall time it started, whom by,
	// the expansions before it, and the last progress sent
	double m_skip_left = 0, m_skip_total = 0;
	int64_t m_skip_us = 0, m_skip_sent_us = 0;
	ss_ m_skip_to, m_skip_by;
	size_t m_skip_expansions = 0;
	// m_joining: sent the join, its login not yet in
	std::set<size_t> m_waiting, m_shown, m_joining;
	std::map<size_t, Player> m_players;
	// The furnaces and the lanterns (furnaces.h)
	Furnaces m_furnaces{m_world};
	// The bones' growth and the world's end (bones_growth.h)
	BonesGrowth m_growth{m_world, m_furnaces};
	luanti_mapgen::Params m_mapgen;
	bool m_spawn_ready = false;
	// Every section of the world in ([SKELDAT_BOUNDED_WORLD]): the players
	// wait for it
	bool m_world_ready = false;
	float m_spawn[3] = {0, 0, 0};
	float m_save_t = 0, m_send_t = 0, m_breath_t = 0,
			m_move_t = 0;
	size_t m_worldgen_queue = 0;
	bool m_load_points_dirty = true;
	// The stacks on the ground (drops.h)
	Drops m_drops{m_world};
	// The mobs, the arrows and the light skeletons (mobs.h)
	Mobs m_mobs{m_world, m_players, *this, m_drops, m_growth, m_furnaces};
	// The outermost columns' mean top, once the world is in
	float m_edge_crest = 0;
	// The lowest of those tops ([SKELDAT_BACKDROP_LOW]), where the hills
	// beyond start under
	int m_edge_low = 0;
	// Asked of worldgen and not merged yet: a section is loaded (empty)
	// before it is generated
	std::set<ss_> m_awaiting;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{
		m_world.format = interface::VoxelFormat::luanti();
		m_world.format.planes.push_back(interface::VoxelPlane("bones", 8));
		// The bones drawn as skelenti draws its danger: the first surface
		// modifier, which the client's VOXELDECAY technique reads as the
		// decay (AreaField.glsl). wetness is only the slot it rides in.
		m_world.format.wetness = m_world.bones;
		m_furnaces.changed = [this](const ss_ &at){ send_furnace(at); };
		// What is kept by the voxel: the stuck arrows (saved), the marker
		// skulls a footprint, and the sections whose tops are counted
		// again (the top may have moved to another section of the column)
		m_world.on_set.push_back([this](int x, int y, int z, uint32_t old,
				uint32_t id){
			const uint32_t stuck = m_world.stuck_id;
			if(old != id && (old == stuck || id == stuck)){
				const ss_ k = pos_key(x, y, z);
				if(id == stuck)
					m_mobs.stuck.insert(k);
				else
					m_mobs.stuck.erase(k);
				if(m_store){
					if(id == stuck)
						m_store->set("stuck/"+k, "1");
					else
						m_store->remove("stuck/"+k);
				}
			}
			const uint32_t marker = m_world.marker;
			const long f = m_world.footprint(x, z);
			if(f >= 0 && old != id && (id == marker || old == marker)){
				m_mobs.markers[f] += (id == marker) - (old == marker);
				log_i(MODULE, "skeldat: %d marker skulls in the footprint at "
						"%ld %ld", m_mobs.markers[f], f % (2 * m_world.half) -
						m_world.half, f / (2 * m_world.half) - m_world.half);
			}
			const int S = skeldat::bones::SECTION;
			for(int sy = m_world.y0; sy <= m_world.y1; sy++)
				m_growth.recount.insert(pos_key(WorldView::floor_div(x, S), sy,
						WorldView::floor_div(z, S)));
		});
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
		sub(m_server, "world_menu:close", &Module::on_world_close);
		const ss_ game = "network:packet_received/skeldat:";
		sub(m_server, game+"admin", &Module::on_admin);
		// The rest of the game's packets go to one handler, by name
		for(const char *n : {"open", "close", "move", "craft", "respawn",
				"bow", "intro", "scores", "rerun", "pause", "worlds", "skip"})
			sub(m_server, game+n, &Module::on_game_packet);
		// What a player does in the world: builtin/luanti's session
		// (luanti/session.h), its calls this Module's (Game, below)
		// [SKELDAT_WORLD_ADMIN] Paused, only the chat, the wield and the
		// world's arrival
		for(const char *n : luanti_session::PACKETS)
			sub<network::Packet>(m_server,
					ss_("network:packet_received/luanti:")+n,
					[this](const network::Packet &p){
				if((m_paused || m_skip_left > 0) && p.name != "luanti:chat" &&
						p.name != "luanti:wield" && p.name != "luanti:world_in"){
					refused_paused(p);
					return;
				}
				m_session.packet(p);
			});
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
		if(m_save){
			// [SKELDAT_WORLD_ADMIN] Picked in a running world: a switch
			switch_world(event.peer, event.name, seed == event.options.end() ?
					"" : seed->second);
			return;
		}
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
		uint32_t seed = m_world.rand();
		const char *env_seed = getenv("BUILDAT_SKELDAT_SEED");
		if(m_store->get("seed", v))
			seed = (uint32_t)std::stoul(v);
		else if(!seed_text.empty())
			seed = seed_of(seed_text);
		else if(env_seed && env_seed[0])
			seed = (uint32_t)std::stoul(env_seed);
		m_store->set("seed", itos(seed));
		if(m_store->get("day", v))
			m_world.day = atof(v.c_str());
		m_world.marker = m_world.id_of("skeldat:marker_skull");
		m_world.sun_ids = {m_world.id_of("skeldat:bone_block"), m_world.id_of("skeldat:skull"),
				m_world.id_of("skeldat:skulls"), m_world.marker};
		m_world.stuck_id = m_world.id_of("skeldat:stuck_arrow");
		if(m_store->get("world_t", v))
			m_world.t = atof(v.c_str());
		else if(const char *env = getenv("BUILDAT_SKELDAT_WORLD_T"))
			m_world.t = atof(env); // for a check: a new world's age, seconds
		if(m_store->get("ended", v)){
			m_growth.ended = true;
			m_growth.end_days = atof(v.c_str());
			if(m_store->get("ended_rank", v))
				std::istringstream(v)>>m_end_best>>m_end_place;
			log_i(MODULE, "skeldat: the world \"%s\" ended after %.1f days",
					cs(name), m_growth.end_days);
		}
		// The size picked when it was made ([SKELDAT_WORLD_SIZES]): its
		// width; a world from before the choice is 1024, as it was made
		ss_ size = "1024";
		m_save->store("world_menu")->get("size", size);
		const int width = atoi(size.c_str());
		if(width == 512 || width == 1024)
			m_world.half = width / 128, m_world.y0 = -1, m_world.y1 = 0;
		else if(width == 256 || width == 128)
			m_world.half = width / 128, m_world.y0 = 0, m_world.y1 = 0;
		// For a check: a small world, "<half> <y0> <y1>" in sections
		const char *env_size = getenv("BUILDAT_SKELDAT_SIZE");
		if(env_size && env_size[0] && sscanf(env_size, "%d %d %d", &m_world.half,
				&m_world.y0, &m_world.y1) != 3)
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
		m_growth.speed = BonesGrowth::valid_speed(atoi(speed.c_str())) ? atoi(speed.c_str()) : 1;
		m_growth.speed_low = m_growth.speed;
		if(m_store->get("speed_low", v) && BonesGrowth::valid_speed(atoi(v.c_str())))
			m_growth.speed_low = std::min(m_growth.speed, atoi(v.c_str()));
		m_store->set("speed_low", itos(m_growth.speed_low));
		if(const char *env = getenv("BUILDAT_SKELDAT_BUDGET"))
			m_growth.budget = std::max(0.001, atof(env));
		log_i(MODULE, "skeldat: the bones at %dx (the lowest %dx)", m_growth.speed,
				m_growth.speed_low);
		m_mobs.markers.assign(m_world.footprints(), 0);
		m_world.footprints_ready = true;
		if(m_store->get("holes", v)){
			std::istringstream is(v);
			long c;
			int day;
			while(is>>c>>day)
				m_mobs.hole_day[c] = day;
		}
		if(m_store->get("markers", v)){
			std::istringstream is(v);
			int all = 0;
			for(int &n : m_mobs.markers)
				is>>n, all += n;
			log_i(MODULE, "skeldat: %d marker skulls in the world", all);
		}
		if(const char *env = getenv("BUILDAT_SKELDAT_DAY"))
			if(atof(env) > 0)
				m_world.day_s = (float)atof(env);
		if(const char *env = getenv("BUILDAT_SKELDAT_LIGHT_STEP"))
			if(atof(env) > 0)
				m_mobs.light_step = (float)atof(env);
		if(const char *env = getenv("BUILDAT_SKELDAT_EXPAND"))
			if(atof(env) > 0)
				m_growth.section_period = atof(env);
		// For a check: the time of day it starts at, 0.5 noon
		const char *env_time = getenv("BUILDAT_SKELDAT_TIME");
		if(env_time && env_time[0])
			m_world.day = atof(env_time);
		m_furnaces.store = m_store;
		m_furnaces.load();
		for(const ss_ &key : m_store->list("mob/")){
			Mob m;
			const uint32_t k = (uint32_t)atol(key.c_str() + 4);
			if(m_store->get(key, v) && m.load(v)){
				m.light_t = m_world.rnd() * m_mobs.light_step;
				m_mobs.all[k] = m;
				m_mobs.next_mob = std::max(m_mobs.next_mob, k + 1);
			}
		}
		for(const ss_ &key : m_store->list("stuck/"))
			m_mobs.stuck.insert(key.substr(6));
		m_drops.store = m_store;
		m_mobs.store = m_store;
		m_drops.load();
		if(const char *env = getenv("BUILDAT_SKELDAT_TEST"))
			m_mobs.test = env;
		log_i(MODULE, "skeldat: the world \"%s\" starts, seed %u, %zu "
				"furnaces, %zu mobs, %d x %d x %d, day %.4f", cs(name), seed,
				m_furnaces.all.size(), m_mobs.all.size(), 2 * m_world.half * 64,
				(m_world.y1 - m_world.y0 + 1) * 64, 2 * m_world.half * 64, m_world.day);
		create_world(seed);
		return true;
	}


	void create_world(uint32_t seed)
	{
		m_world.scene = main_context::create_scene(m_server);
		m_mapgen = mapgen_params(seed);
		worldgen::GeneratorInterface *generator = nullptr;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *i){
			generator = i->create_generator(m_mapgen);
		});
		// Before the voxelworld, or its first requests are lost
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->create_instance(m_world.scene);
			BonesGenerator::PileIds ids;
			ids.block = m_world.id_of("skeldat:bone_block");
			ids.tops[0] = m_world.id_of("skeldat:skull");
			ids.tops[1] = m_world.id_of("skeldat:skulls");
			ids.tops[2] = m_world.id_of("skeldat:bone_lying");
			ids.ground[0] = m_world.id_of("skeldat:grass");
			ids.ground[1] = m_world.id_of("skeldat:dirt");
			ids.ground[2] = m_world.id_of("skeldat:sand");
			m_generator = new BonesGenerator(generator, m_world.format, m_world.bones,
					m_mapgen.seed, ids);
			const char *fill = getenv("BUILDAT_SKELDAT_FILL");
			m_generator->m_half_v = m_world.half * skeldat::bones::SECTION;
			m_generator->m_fill = !fill ? 0 : ss_(fill) == "1" ? 1 :
					ss_(fill) == "half" ? 2 : ss_(fill) == "surface" ? 3 : 0;
			i->get_instance(m_world.scene)->set_generator(m_generator);
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			// The world's bounds in sections ([SKELDAT_BOUNDED_WORLD])
			i->create_instance(m_world.scene, pv::Region(-m_world.half, m_world.y0, -m_world.half,
					m_world.half - 1, m_world.y1, m_world.half - 1));
		});
		// Before voxelworld's first tick, which loads a whole region that
		// has no load points
		update_load_points();
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			reg->set_format(m_world.format);
			build_registry(reg);
			w->set_save(m_save, "main");
			// The mapgen lights what it builds; voxelworld keeps it up as
			// the world changes, the torches' too
			w->set_light_maintained(voxelworld::Instance::LIGHT_SKY, true);
			w->set_light_maintained(voxelworld::Instance::LIGHT_LAMP, true);
		});
		worldgen::access(m_server, m_world.scene, [&](worldgen::Instance *i){
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
		const skeldat::NodeDef &n = m_world.node_of(id) ? *m_world.node_of(id) :
				*m_world.node_of(m_world.id_of("skeldat:stone"));
		d.name = m_world.node_of(id) ? n.name : "unknown";
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
		const bool low = m_world.y0 >= 0;
		const int wl = low ? 20 : 1, lift = wl - 1;
		mp.water_level = wl;
		mp.section_size = skeldat::bones::SECTION;
		// The terrain's spreads by the world's width, not under 128, so a
		// small world still has a valley and a hill
		const float width = 2.0f * m_world.half * skeldat::bones::SECTION,
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
		const uint32_t stone = m_world.id_of("skeldat:stone"),
				water = m_world.id_of("skeldat:water_source");
		mp.content_ids["mapgen_stone"] = stone;
		mp.content_ids["mapgen_water_source"] = water;
		mp.content_ids["mapgen_river_water_source"] = water;
		mp.content_ids["mapgen_cobble"] = m_world.id_of("skeldat:cobble");
		for(uint32_t id = ID_AIR; id < ID_NODE0 + m_game.nodes.size(); id++)
			if(id == ID_AIR || m_world.node_of(id))
				mp.node_props[id] = luanti_registry::mapgen_props(luanti_def(id));
		auto biome = [&](const ss_ &name, const ss_ &top, int depth_top,
				const ss_ &filler, int depth_filler, const ss_ &riverbed,
				int y_min, int y_max){
			luanti_mapgen::Params::Biome b;
			b.name = name;
			b.c_top = m_world.id_of(top);
			b.c_filler = m_world.id_of(filler);
			b.c_stone = stone;
			b.c_water_top = b.c_water = b.c_river_water = water;
			b.c_riverbed = riverbed.empty() ? stone : m_world.id_of(riverbed);
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
			o.c_ore = m_world.id_of(name);
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
		d.c_place_on = {m_world.id_of("skeldat:grass")};
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
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			// The feet's y on the column's top, or false for water or a tree
			const int y1 = (m_world.y1 + 1) * SECTION - 1, y0 = m_world.y0 * SECTION;
			auto ground = [&](int x, int z, int &feet){
				for(int y = y1 - 2; y > y0; y--){
					if(!m_world.walkable(w, x, y, z)){
						if(m_world.is_water(w, x, y, z))
							return false;
						continue;
					}
					const skeldat::NodeDef *n = m_world.node_of(m_world.wid(w, x, y, z));
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
				const int range = std::min(32 + i / 4, m_world.half * SECTION - 16);
				const int x = (int)(r() % (2 * range)) - range;
				const int z = (int)(r() % (2 * range)) - range;
				int feet = 0;
				if(!ground(x, z, feet) || feet < m_mapgen.water_level + 1 ||
						seed_value(skeldat::bones::danger(
						(uint32_t)m_mapgen.seed, (float)x, (float)z,
						m_world.half * SECTION)) > 0)
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
				m_drops.drop(Stack(i < 4 ? "skeldat:stick" : "skeldat:bone"),
						(float)x, (float)feet + 0.5f, (float)z);
			}
		});
		if(!m_spawn_ready){
			m_spawn[1] = (float)((m_world.y1 + 1) * SECTION - 1);
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
				m_world.half, std::max(-m_world.y0, m_world.y1), m_world.half, std::max(-m_world.y0, m_world.y1)));
		for(auto &pair : m_players){
			const Player &pl = pair.second;
			if(!pl.placed)
				continue;
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					(int)std::floor(pl.x), (int)std::floor(pl.y),
					(int)std::floor(pl.z)), 3, 2, 2, 1, pair.first));
		}
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
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

	void on_section_loaded(const voxelworld::SectionLoaded &e)
	{
		if(e.scene != m_world.scene || !m_save || !m_world.in_world(e.section_p))
			return;
		m_growth.sections.insert(m_world.section_key(e.section_p));
		m_growth.recount.insert(m_world.section_key(e.section_p));
		// The world coming in ([SKELDAT_BOUNDED_WORLD]): a line every
		// sixteenth, and the time it took
		const size_t all = m_world.all_sections();
		if(m_growth.sections.size() % std::max<size_t>(1, all / 16) == 0 &&
				!m_world_ready){
			log_i(MODULE, "skeldat: %zu of %zu sections loaded, %.1f s, the "
					"highest voxel made at y %d", m_growth.sections.size(), all,
					(interface::os::time_us() - m_start_us) / 1e6,
					m_generator ? (int)m_generator->m_top : 0);
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->progress(ss_(m_making ? "Making" : "Loading")+
						" the world: "+itos(m_growth.sections.size())+
						" of "+itos(all)+" sections");
			});
		}
	}

	void on_generation_request(const voxelworld::GenerationRequest &e)
	{
		if(e.scene == m_world.scene && m_world.in_world(e.section_p))
			m_awaiting.insert(m_world.section_key(e.section_p));
	}

	void on_section_generated(const worldgen::SectionGenerated &e)
	{
		if(e.scene != m_world.scene || !m_world.in_world(e.section_p))
			return;
		m_awaiting.erase(m_world.section_key(e.section_p));
		m_growth.recount.insert(m_world.section_key(e.section_p));
	}

	// The whole world in: the spawn found on it and the players let in
	void world_in()
	{
		m_world_ready = true;
		find_spawn();
		const int64_t t0 = interface::os::time_us();
		m_growth.flooded.assign(m_world.footprints(), 0);
		const size_t cols = m_world.footprints() * skeldat::bones::SECTION *
				skeldat::bones::SECTION;
		m_world.top_y.assign(cols, NO_GROUND);
		m_world.top_b.assign(cols, 0);
		size_t bench = 0;
		if(const char *env = getenv("BUILDAT_SKELDAT_SKELETONS"))
			bench = (size_t)atol(env);
		// For a check: "sx sz n", footprint (sx, sz)'s marker count, the
		// skulls themselves not placed
		int mx, mz, mn;
		if(const char *env = getenv("BUILDAT_SKELDAT_MARKERS"))
			if(sscanf(env, "%d %d %d", &mx, &mz, &mn) == 3 &&
					m_world.footprint(mx * skeldat::bones::SECTION,
					mz * skeldat::bones::SECTION) >= 0)
				m_mobs.markers[m_world.footprint(mx * skeldat::bones::SECTION,
						mz * skeldat::bones::SECTION)] = mn;
		size_t added = 0;
		make_edge();
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			for(size_t i = 0; i < m_world.footprints(); i++)
				m_growth.sweep(w, i);
			// For a check: that many more light skeletons, anywhere
		});
		{
			const int h = m_world.half * skeldat::bones::SECTION;
			double sum = 0;
			size_t n = 0;
			int low = 1 << 30;
			for(int a = -h; a < h; a++)
				for(const auto &xz : {std::make_pair(a, -h),
						std::make_pair(a, h - 1), std::make_pair(-h, a),
						std::make_pair(h - 1, a)}){
					const long c = m_world.column(xz.first, xz.second);
					if(c >= 0 && m_world.top_y[c] != NO_GROUND)
						sum += m_world.top_y[c], n++, low = std::min(low,
								(int)m_world.top_y[c]);
				}
			m_edge_crest = n ? (float)(sum / n) + 1 : 0;
			m_edge_low = n ? low : 0;
		}
		// Not in a check's own set of mobs (TEST: no spawning; the bench,
		// 0 an empty world)
		if(m_mobs.test.empty() && !getenv("BUILDAT_SKELDAT_SKELETONS"))
			m_mobs.populate();
		for(size_t t = 0; t < 8 * bench && added < bench; t++)
			added += m_mobs.add_skeleton(false);
		if(getenv("BUILDAT_SKELDAT_SURVEY"))
			survey();
		if(const char *env = getenv("BUILDAT_SKELDAT_LANTERNS")){
			m_furnaces.test_lanterns(env, m_world.day_s);
			m_furnaces.report = true;
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
		if(e.scene != m_world.scene || !m_save)
			return;
		m_growth.sections.erase(m_world.section_key(e.section_p));
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
		replicate::assign_scene_to_peer(m_server, m_world.scene, peer);
		if(!pl.placed)
			respawn(peer, pl);
		else
			send_position(peer, pl);
		send_inventory(peer, pl);
		send_stats(peer, pl);
		send_time(peer);
		send_end(peer);
		send_world(peer);
		// [SKELDAT_WORLD_ADMIN] Paused, said; a second player ends a single
		// player's pause
		if(m_pause_auto && m_players.size() > 1)
			set_paused(false, true, pl.name);
		send_paused(peer);
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
		m_drops.drop(out, pl->x, pl->y + 1.2f, pl->z, std::sin(yaw) * 3, 2,
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
		pl->dig_t0 = m_world.time;
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
		pl.check_t = m_world.time;
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
		os<<m_world.day<<" "<<(1.0 / m_world.day_s);
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
		auto it = m_furnaces.all.find(at);
		if(it == m_furnaces.all.end())
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
			os<<m_world.day;
			m_store->set("day", os.str());
			m_store->set("world_t", dtos(m_world.t));
			for(const auto &pp : m_played)
				m_store->set("played/"+pp.first, dtos(pp.second));
			m_furnaces.save();
			for(auto &pair : m_mobs.all)
				m_store->set("mob/"+itos(pair.first), pair.second.save());
			m_drops.save();
			std::ostringstream ms;
			for(int n : m_mobs.markers)
				ms<<n<<" ";
			m_store->set("markers", ms.str());
			std::ostringstream hs;
			for(auto &kv : m_mobs.hole_day)
				hs<<kv.first<<" "<<kv.second<<" ";
			m_store->set("holes", hs.str());
		});
	}

	//
	// What a player does
	//


	// The world's size and its edge's mean crest, for the client's
	// backdrop beyond the edge ([SKELDAT_EDGE_RIDGE]): "half y0 y1 crest
	// low", half in voxels, low the lowest edge column's top
	void send_world(size_t peer)
	{
		std::ostringstream os;
		os<<m_world.half * skeldat::bones::SECTION<<" "<<m_world.y0 * skeldat::bones::SECTION
				<<" "<<(m_world.y1 + 1) * skeldat::bones::SECTION - 1<<" "<<m_edge_crest
				<<" "<<m_edge_low;
		network::send(m_server, peer, "skeldat:world", os.str());
	}

	// [SKELDAT_INTRO] The days left, "about": from the uncovered columns'
	// rate over the last few game days (m_growth.bare_days), else the days a
	// world of this size takes at 1x, over the speed, less those gone; 0
	// once ended. The days measured free-running with no player
	// (2026-10-17): 128 at seeds 2-5 17.5, 36.1, 39.2, 19.9; 256 at seeds 2
	// and 3 24.5, 68.0; 512 and 1024 on that trend (x1.6 a doubling)
	// simplified: the history is not saved, a restarted world starts it
	// again from the constant
	void send_intro(size_t peer)
	{
		const double gone = m_world.t / m_world.day_s;
		double left;
		if(m_growth.ended){
			left = 0;
		} else if(m_growth.bare_days.size() >= 3 && m_growth.bare_days.front().second >
				m_growth.bare_days.back().second){
			const auto &a = m_growth.bare_days.front(), &b = m_growth.bare_days.back();
			left = b.second * (b.first - a.first) / (a.second - b.second);
		} else {
			const int width = m_world.half * 2 * skeldat::bones::SECTION;
			const double days = width <= 128 ? 28 : width <= 256 ? 46 :
					width <= 512 ? 75 : 120;
			left = days / m_growth.speed - gone;
		}
		const int n = m_growth.ended ? 0 : std::max(1, (int)std::lround(left));
		network::send(m_server, peer, "skeldat:intro", itos(n));
	}

	void send_end(size_t peer)
	{
		if(m_growth.ended)
			network::send(m_server, peer, "skeldat:end", dtos(m_growth.end_days)+" "+
					itos(m_growth.speed_low)+" "+dtos(m_end_best)+" "+
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
		if(!m_growth.ended || m_rerunning){
			// The button is there only after the end: this is a stray
			log_i(MODULE, "skeldat: %s's re-run refused: %s", cs(pl.name),
					m_growth.ended ? "one is starting" : "the world has not ended");
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
				itos(m_world.half * 2 * skeldat::bones::SECTION)+"\n"+
				itos(m_growth.speed_low));
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
		if(!m_world.scene)
			return;
		log_i(MODULE, "skeldat: the world \"%s\" closed for a reload, day "
				"%.4f", cs(m_world_name), m_world.day);
		save();
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			w->commit();
		});
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->delete_instance(m_world.scene);
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			i->delete_instance(m_world.scene);
		});
		main_context::access(m_server, [&](main_context::Interface *i){
			i->delete_scene(m_world.scene);
		});
		m_world.scene = nullptr;
		storage::access(m_server, [&](storage::Interface *i){
			if(m_save)
				i->close(m_save);
			if(m_scores)
				i->close(m_scores);
		});
		m_save = nullptr;
		m_scores = nullptr;
		// The menu picks again: a switch's world or a closed one's menu
		world_menu::access(m_server, [&](world_menu::Interface *i){
			i->set_running(false);
		});
	}

	// The new instance: a re-run's world made (the target deleted first,
	// the old world itself when it is the target), or the start's again
	void on_continue()
	{
		// [SKELDAT_WORLD_ADMIN] "play\n<name>\n<seed>" or "close"
		const ss_ sw = m_server->tmp_restore_data("skeldat:switch");
		if(!sw.empty()){
			std::istringstream ss(sw);
			ss_ how, name, seed;
			std::getline(ss, how);
			std::getline(ss, name);
			std::getline(ss, seed);
			start(false);
			if(how == "play" && start_world(name, false, seed)){
				log_i(MODULE, "skeldat: switched to \"%s\"", cs(name));
			} else {
				log_i(MODULE, "skeldat: no world runs: the world menu");
			}
			return;
		}
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
	// [SKELDAT_WORLD_ADMIN] The picker's (world_menu's: the launcher's own
	// client, an admin) Worlds..., a switch to another world, Close world,
	// and the pause. A switch and a close are the re-run's reload: the
	// world saved and closed, every client sent off with the goodbye and
	// rejoining. A close's reload starts no world: the menu to the picker,
	// the wait to the rest.
	//

	bool picker(size_t peer)
	{
		bool ok = false;
		world_menu::access(m_server, [&](world_menu::Interface *i){
			ok = i->is_picker(peer);
		});
		return ok;
	}

	ss_ name_of(size_t peer)
	{
		auto it = m_players.find(peer);
		return it != m_players.end() ? it->second.name : "client"+itos(peer);
	}

	void reload_for(const ss_ &line, const ss_ &data, const ss_ &goodbye)
	{
		m_rerunning = true;
		log_i(MODULE, "skeldat: %s", cs(line));
		chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		m_server->tmp_store_data("skeldat:switch", data);
		network::access(m_server, [&](network::Interface *i){
			for(network::PeerInfo::Id p : i->list_peers()){
				i->send(p, "network:goodbye", "1"+goodbye);
				i->disconnect(p);
			}
		});
		m_server->reload_module(MODULE);
	}

	void switch_world(size_t peer, const ss_ &name, const ss_ &seed)
	{
		if(m_rerunning || !picker(peer) || name == m_world_name){
			log_w(MODULE, "skeldat: a switch to \"%s\" by %s refused",
					cs(name), cs(name_of(peer)));
			return;
		}
		reload_for(name_of(peer)+" switches the world to "+name,
				"play\n"+name+"\n"+seed,
				"The server switches to the world "+name);
	}

	void on_world_close(const world_menu::Close &event)
	{
		if(m_rerunning || !m_save || !picker(event.peer)){
			log_w(MODULE, "skeldat: a close by %s refused",
					cs(name_of(event.peer)));
			return;
		}
		reload_for(name_of(event.peer)+" closes the world "+m_world_name,
				"close", "The world "+m_world_name+" was closed");
	}

	// A game request while paused: refused, logged once a peer a pause
	void refused_paused(const network::Packet &p)
	{
		if(m_pause_refused.insert(p.sender).second)
			log_i(MODULE, "skeldat: %s's %s refused: %s",
					cs(name_of(p.sender)), cs(p.name),
					m_paused ? "paused" : "skipping");
	}

	// "on" / "off" from the picker; "auto on" / "auto off" from a local
	// game's only client, its pause menu opened and closed
	void on_pause(size_t peer, const ss_ &how)
	{
		const bool is_auto = how.compare(0, 5, "auto ") == 0;
		const bool on = how == "on" || how == "auto on";
		if(is_auto){
			bool single = false;
			accounts::access(m_server, [&](accounts::Interface *i){
				single = i->is_local(peer);
			});
			network::access(m_server, [&](network::Interface *i){
				single = single && i->list_peers().size() == 1;
			});
			// A picker's own pause is not the menu's to end; a skip runs
			// with the menu open (its button is in it)
			if(!single || (m_paused && !m_pause_auto) || on == m_paused ||
					m_skip_left > 0)
				return;
		} else if(!picker(peer)){
			log_w(MODULE, "skeldat: %s's pause %s refused: not the picker",
					cs(name_of(peer)), cs(how));
			return;
		}
		// [SKELDAT_SKIP_TIME] A pause stops a skip first
		if(on && m_skip_left > 0)
			end_skip("stopped by the pause");
		set_paused(on, is_auto, name_of(peer));
	}

	// [SKELDAT_SKIP_TIME] "on": to the next sunset by day, sunrise by
	// night; "stop". The picker's, not after the end; a single player's
	// menu pause gives way to it.
	void on_skip(size_t peer, const ss_ &how)
	{
		if(!picker(peer)){
			log_w(MODULE, "skeldat: %s's skip refused: not the picker",
					cs(name_of(peer)));
			return;
		}
		if(how == "stop"){
			if(m_skip_left > 0)
				end_skip("stopped by "+name_of(peer));
			return;
		}
		if(how != "on" || m_growth.ended || m_skip_left > 0 || !m_world_ready ||
				(m_paused && !m_pause_auto)){
			log_w(MODULE, "skeldat: %s's skip refused: %s", cs(name_of(peer)),
					m_growth.ended ? "the world has ended" : m_skip_left > 0 ?
					"one runs" : "not now");
			return;
		}
		if(m_paused){
			m_paused = m_pause_auto = false;
			m_paused_by.clear();
		}
		const bool day = m_world.day >= 0.25 && m_world.day < 0.75;
		const double target = day ? 0.75 : 0.25;
		// A hair past it, so the phase turns in the skip
		m_skip_left = m_skip_total =
				(std::fmod(target - m_world.day + 1.0, 1.0) + 1e-5) * m_world.day_s;
		m_skip_to = day ? "sunset" : "sunrise";
		m_skip_by = name_of(peer);
		m_skip_us = m_skip_sent_us = interface::os::time_us();
		m_skip_expansions = m_growth.expansions;
		m_pause_refused.clear();
		const ss_ line = m_skip_by+" skips to "+m_skip_to;
		log_i(MODULE, "skeldat: %s: %.1f s of game time, day %.4f", cs(line),
				m_skip_total, m_world.day);
		chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		for(auto &pair : m_players)
			send_paused(pair.first);
	}

	// Sub-steps of 0.1 s of game time, as many as fit in 35 ms of the
	// tick's wall time; the progress to the clients four times a second
	void step_skip()
	{
		const int64_t t0 = interface::os::time_us();
		while(m_skip_left > 0 && interface::os::time_us() - t0 < 35000){
			const float dt = (float)std::min(0.1, m_skip_left);
			step_world(dt);
			m_skip_left -= dt;
		}
		const int64_t now = interface::os::time_us();
		if(m_skip_left <= 0){
			end_skip("done");
		} else if(now - m_skip_sent_us >= 250000){
			m_skip_sent_us = now;
			for(auto &pair : m_players){
				send_paused(pair.first);
				send_time(pair.first);
			}
		}
	}

	void end_skip(const ss_ &how)
	{
		const double done = m_skip_total - std::max(0.0, m_skip_left);
		const double rate = m_growth.sections.size() / m_growth.section_period;
		log_i(MODULE, "skeldat: the skip to %s %s: %.1f s of game time in "
				"%.2f s, day %.4f, %zu expansions (%.1f due)", cs(m_skip_to),
				cs(how), done, (interface::os::time_us() - m_skip_us) / 1e6, m_world.day,
				m_growth.expansions - m_skip_expansions, done * rate);
		m_skip_left = 0;
		// The lag notice's minute starts again
		m_growth.keep_up_us = 0, m_growth.ticked_s = 0, m_growth.dropped_n = 0;
		for(auto &pair : m_players){
			send_paused(pair.first);
			send_time(pair.first);
		}
	}

	void set_paused(bool on, bool is_auto, const ss_ &by)
	{
		if(on == m_paused && is_auto == m_pause_auto)
			return;
		const bool chat_line = !(on ? is_auto : m_pause_auto);
		m_paused = on;
		m_pause_auto = on && is_auto;
		m_paused_by = on ? by : "";
		m_pause_refused.clear();
		// The lag notice's minute starts again
		m_growth.keep_up_us = 0, m_growth.ticked_s = 0, m_growth.dropped_n = 0;
		const ss_ line = by+(on ? " paused the world" : " resumed the world")+
				(is_auto ? " (the pause menu)" : "");
		log_i(MODULE, "skeldat: %s, day %.4f, world_t %.1f", cs(line), m_world.day,
				m_world.t);
		if(chat_line)
			chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		for(auto &pair : m_players)
			send_paused(pair.first);
	}

	// "" running, else "<name>" or "auto <name>"; skipping, "skip <percent>
	// <sunrise|sunset>"
	void send_paused(size_t peer)
	{
		if(m_skip_left > 0){
			network::send(m_server, peer, "skeldat:paused", "skip "+itos((int)(
					100 * (1 - m_skip_left / m_skip_total)))+" "+m_skip_to);
			return;
		}
		network::send(m_server, peer, "skeldat:paused", !m_paused ? "" :
				(m_pause_auto ? "auto " : "")+m_paused_by);
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
			if(i < 10 || all[i].second > m_world.t / 2)
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
		const int size = m_world.half * 2 * skeldat::bones::SECTION;
		const ss_ key = "set/"+seed+"/"+itos(size)+"/"+itos(m_growth.speed_low);
		json::Value set = read_set(st, key);
		set.set("seed", json::Value(seed));
		set.set("size", json::Value((int64_t)size));
		set.set("speed", json::Value((int64_t)m_growth.speed_low));
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
		score.set("days", json::Value(m_growth.end_days));
		score.set("date", json::Value(ss_(date)));
		score.set("world", json::Value(m_world_name));
		score.set("players", players);
		// Best first: in before the first with fewer days
		const json::Value &old = set.get("scores");
		json::Value list = json::array();
		m_end_place = 0;
		for(unsigned i = 0; old.is_array() && i < old.size(); i++){
			if(!m_end_place && old.at(i).get("days").as_number() < m_growth.end_days){
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
				"(\"%s\"), best %.1f; players: %s", m_growth.end_days, m_end_place,
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

	// From the player's eyes to the middle of the voxel
	// Within reach, and inside the world above its bottom layer, which is
	// not dug ([SKELDAT_BOUNDED_WORLD])
	bool reaches(const Player &pl, int x, int y, int z)
	{
		if(m_growth.ended || !m_world.reaches_world(x, y, z))
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
		if(what == "intro"){
			send_intro(peer);
			return;
		}
		if(what == "scores"){
			send_scores(peer, packet.data);
			return;
		}
		if(what == "pause"){
			on_pause(peer, packet.data);
			return;
		}
		if(what == "worlds"){
			if(!picker(peer)){
				log_w(MODULE, "skeldat: %s's Worlds... refused: not the "
						"picker", cs(pl.name));
				return;
			}
			world_menu::access(m_server, [&](world_menu::Interface *i){
				i->show_running(peer, m_world_name);
			});
			return;
		}
		// [SKELDAT_WORLD_ADMIN] Paused: the game's requests refused; the
		// node's window closed and the how-to and the scores read
		if(what == "skip"){
			on_skip(peer, packet.data);
			return;
		}
		if((m_paused || m_skip_left > 0) && what != "close"){
			refused_paused(packet);
			return;
		}
		if(what == "rerun"){
			rerun(pl);
			return;
		}
		if(what == "respawn"){
			if(pl.hp <= 0)
				respawn(peer, pl);
			return;
		}
		if(pl.hp <= 0)
			return; // the dead do nothing else
		if(what == "open"){
			int x, y, z;
			pl.open = "";
			if(is>>x>>y>>z && reaches(pl, x, y, z)){
				const skeldat::NodeDef *n = m_world.node_of(m_world.id_at(x, y, z));
				if(n && (n->name == "skeldat:table" || has_slots(n->name))){
					pl.open = pos_key(x, y, z);
					if(n->name != "skeldat:table"){
						m_furnaces.all[pl.open]; // one that predates its record
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
					m_world.time : -1;
			if(pl.draw_t >= 0){
				log_i(MODULE, "skeldat: %s draws the bow", cs(pl.name));
				// [SKELDAT_BOW_SOUNDS] The others hear the draw play out
				sound("bow_draw", pl.x, pl.y + 1.5f, pl.z, peer);
			}
			return;
		}
		if(how != "release" || pl.draw_t < 0)
			return;
		const float draw = std::min(1.0f, (float)(m_world.time - pl.draw_t) / BOW_DRAW);
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
		main_context::access(m_server, m_world.scene, [&](Urho3D::Scene *scene){
			Urho3D::Node *n = scene->CreateChild("skeldat_arrow");
			n->SetPosition(Urho3D::Vector3(a.x, a.y, a.z));
			a.node_id = n->GetID();
		});
		m_mobs.arrows.push_back(a);
		// [SKELDAT_BOW_SOUND_TUNE] The shooter plays its own at the release
		sound("bow", a.x, a.y, a.z, peer);
		log_i(MODULE, "skeldat: %s shoots an arrow at %.1f (drawn %.2f)",
				cs(pl.name), speed, draw);
	}

	void hurt(size_t peer, Player &pl, int damage, const char *how)
	{
		if(damage <= 0 || pl.hp <= 0)
			return;
		// [SKELDAT_SKIP_TIME] Held through a skip, unharmed
		if(pl.invulnerable || m_skip_left > 0){
			log_i(MODULE, "skeldat: %s %s, %s", cs(pl.name), how,
					pl.invulnerable ? "invulnerable" : "held by a skip");
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
		if(pl.y < m_world.y0 * skeldat::bones::SECTION)
			return;
		sv_<Stack*> full;
		for(auto *l : {&pl.main, &pl.craft, &pl.craftresult})
			for(Stack &st : *l)
				if(!st.empty())
					full.push_back(&st);
		std::shuffle(full.begin(), full.end(), m_world.rand);
		const size_t n = (full.size() + 1) / 2;
		for(size_t i = 0; i < n; i++){
			m_drops.drop(*full[i], pl.x + m_world.rnd() - 0.5f, pl.y + 0.5f,
					pl.z + m_world.rnd() - 0.5f);
			*full[i] = Stack();
		}
		log_i(MODULE, "skeldat: %s dies at %.1f,%.1f,%.1f, dropping %zu of "
				"%zu stacks", cs(pl.name), pl.x, pl.y, pl.z, n, full.size());
	}

	// What does not fit the player's inventory, dropped at its feet
	void give_or_drop(Player &pl, const Stack &st)
	{
		m_drops.drop(m_game.add(pl.main, st), pl.x, pl.y + 0.5f, pl.z);
	}

	// The drops a tick; a living player within DROP_REACH takes what fits
	// (the drop key's not its dropper's until it has walked away from it)
	void step_drops(float dt)
	{
		// An unloaded voxel is ground to walkable(): not before the world
		if(!m_world_ready)
			return;
		// [SKELDAT_BOW_SOUNDS] One pickup sound a player a tick, at a drop
		// it took from
		std::map<size_t, Urho3D::Vector3> picked;
		m_drops.step(dt, m_world.day_s, [&](Drop &d){
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
				picked[pair.first] = Urho3D::Vector3(d.x, d.y, d.z);
				if(d.st.empty())
					break;
			}
		});
		for(auto &pair : picked)
			sound("pickup", pair.second.x_, pair.second.y_, pair.second.z_);
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
		const uint32_t id = m_world.id_at(x, y, z);
		const skeldat::NodeDef *n = m_world.node_of(id);
		Stack &tool = pl.main[pl.wield];
		// The bow digs nothing ([SKELDAT_BOW])
		if(tool.name == "skeldat:bow")
			return;
		const skeldat::Cap *cap = nullptr;
		const float time = n ? m_game.dig_time(tool.name, *n, &cap) : -1;
		// A quarter less than the time, for the network's lag
		if(!n || time < 0 || !reaches(pl, x, y, z) || pl.dig_at != at ||
				m_world.time - pl.dig_t0 < time * 0.75f){
			log_i(MODULE, "skeldat: %s's dig at %s refused", cs(pl.name),
					cs(at));
			return;
		}
		if(has_slots(n->name)){
			if(!m_furnaces.dug(at))
				return; // not while it holds anything
		}
		pl.dig_at = "";
		const int bones = m_world.bones_at(x, y, z);
		m_world.set_node(x, y, z, ID_AIR);
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
				m_world.rand() % n->drop_rarity == 0))
			drop = Stack::parse(n->drop);
		give_or_drop(pl, drop);
		// The arrows stuck into it, the digger's ([SKELDAT_BOW])
		static const int FACE[6][3] = {{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
				{-1, 0, 0}, {0, 0, 1}, {0, 0, -1}};
		for(int f = 0; f < 6; f++){
			const int ax = x - FACE[f][0], ay = y - FACE[f][1],
					az = z - FACE[f][2];
			if(m_world.id_at(ax, ay, az) == m_world.stuck_id &&
					m_world.param_at(ax, ay, az) == (uint32_t)f){
				m_world.set_node(ax, ay, az, ID_AIR);
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
		const uint32_t id = m_world.id_of(st.name);
		const skeldat::NodeDef *n = m_world.node_of(id);
		const skeldat::NodeDef *here = m_world.node_of(m_world.id_at(x, y, z));
		const uint32_t here_id = m_world.id_at(x, y, z);
		// Into air or water, beside something, out of everyone's way
		bool beside = false;
		static const int D[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
				{0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
		for(auto &d : D){
			const uint32_t b = m_world.id_at(x + d[0], y + d[1], z + d[2]);
			beside = beside || (b != ID_AIR && b != ID_IGNORE &&
					b != m_world.id_of("skeldat:water_source"));
		}
		if(!n || !(here_id == ID_AIR || here_id == m_world.stuck_id || (here &&
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
		m_world.set_node(x, y, z, id, param);
		log_i(MODULE, "skeldat: %s places %s at %s", cs(pl.name),
				cs(n->name), cs(pos_key(x, y, z)));
		if(n->name == "skeldat:furnace" || n->name == "skeldat:lantern")
			m_furnaces.placed(x, y, z, n->name == "skeldat:lantern");
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
		auto it = m_furnaces.all.find(loc);
		if(it == m_furnaces.all.end())
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
		return m_world.id_at(x, y, z) == m_world.id_of("skeldat:table");
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
	// The players as the mobs reach them (MobsHost; the mobs are mobs.h's)
	//

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
	// (but `except`, which plays it itself)
	void sound(const char *moment, float x, float y, float z,
			size_t except = (size_t)-1)
	{
		char buf[100];
		snprintf(buf, sizeof buf, "%s %.2f %.2f %.2f", moment, x, y, z);
		for(size_t peer : m_shown)
			if(peer != except)
				network::send(m_server, peer, "skeldat:sound", buf);
	}

	//
	// The skeletons over the whole world ([SKELDAT_SKELETON_SIM])
	//

	// For a check (BUILDAT_SKELDAT_SURVEY, [SKELDAT_WORLD_SIZES]): what was
	// made -- the tops' range, the ores, the edge's and the origin's bones
	// -- in a line, and the map into the save
	void survey()
	{
		const int S = skeldat::bones::SECTION, h = m_world.half * S;
		int lo = 1000, hi = -1000, edge = 0, edge_max = 0;
		for(int z = -h; z < h; z++)
		for(int x = -h; x < h; x++){
			const long c = m_world.column(x, z);
			if(m_world.top_y[c] != NO_GROUND)
				lo = std::min(lo, (int)m_world.top_y[c]),
				hi = std::max(hi, (int)m_world.top_y[c]);
			if(x == -h || x == h - 1 || z == -h || z == h - 1)
				edge++, edge_max += m_world.top_b[c] == skeldat::bones::MAX;
		}
		std::map<uint32_t, size_t> ores;
		// The trees' lowest trunk voxels, and those on grass
		// ([SKELDAT_TREE_DEPTH])
		const uint32_t trunk = m_world.id_of("skeldat:tree"),
				grass = m_world.id_of("skeldat:grass");
		size_t trunks = 0, on_grass = 0;
		for(const char *n : {"skeldat:coal_ore", "skeldat:iron_ore",
				"skeldat:diamond_ore"})
			ores[m_world.id_of(n)] = 0;
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			for(int sz = -m_world.half; sz < m_world.half; sz++)
			for(int sx = -m_world.half; sx < m_world.half; sx++){
				const interface::VoxelVolume vol = w->get_volume(pv::Region(
						pv::Vector3DInt32(sx * S, m_world.y0 * S, sz * S),
						pv::Vector3DInt32(sx * S + S - 1, m_world.y1 * S + S - 1,
						sz * S + S - 1)));
				for(int z = sz * S; z < sz * S + S; z++)
				for(int y = m_world.y0 * S; y < (m_world.y1 + 1) * S; y++)
				for(int x = sx * S; x < sx * S + S; x++){
					const uint32_t id = m_world.format.id.get(vol.sample_at(x, y, z));
					auto it = ores.find(id);
					if(it != ores.end())
						it->second++;
					if(id == trunk && y > m_world.y0 * S){
						const uint32_t under = m_world.format.id.get(
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
				ores[m_world.id_of("skeldat:coal_ore")],
				ores[m_world.id_of("skeldat:iron_ore")],
				ores[m_world.id_of("skeldat:diamond_ore")], edge_max, edge,
				(int)m_world.top_b[m_world.column(0, 0)], on_grass, trunks);
		write_map();
	}

	// [SKELDAT_BONE_SPEED] The admin's switch: in the save, the audit log
	// and everyone's chat
	void set_speed(int s, const ss_ &by)
	{
		if(!BonesGrowth::valid_speed(s) || s == m_growth.speed)
			return;
		m_growth.speed = s;
		m_growth.speed_low = std::min(m_growth.speed_low, s);
		m_save->store("world_menu")->set("speed", itos(s));
		m_store->set("speed_low", itos(m_growth.speed_low));
		audit(by, "", "set", "bone speed "+itos(s)+"x");
		const ss_ line = "The bones now grow at "+itos(s)+"x";
		chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
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
		const int S = SECTION, h = m_world.half * S, y0 = m_world.y0 * S,
				top = (m_world.y1 + 1) * S - 1;
		const uint32_t block = m_world.id_of("skeldat:bone_block"),
				wall = m_world.id_of("skeldat:bone_wall");
		size_t blocks = 0, walls = 0;
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			for(int sz = -m_world.half; sz < m_world.half; sz++)
			for(int sx = -m_world.half; sx < m_world.half; sx++){
				if(sx != -m_world.half && sx != m_world.half - 1 && sz != -m_world.half &&
						sz != m_world.half - 1)
					continue;
				const pv::Region r(pv::Vector3DInt32(sx * S, y0, sz * S),
						pv::Vector3DInt32(sx * S + S - 1, top, sz * S + S - 1));
				const interface::VoxelVolume vol = w->get_volume(r);
				interface::VoxelVolume out(r, m_world.format.planes);
				size_t changed = 0;
				auto put = [&](int x, int y, int z, uint32_t id){
					interface::VoxelSample s = vol.sample_at(x, y, z);
					s.planes[0] = 0;
					m_world.format.id.set(s.planes[0], id);
					m_world.bones.set(s, MAX);
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
						const uint32_t id = m_world.format.id.get(vol.sample_at(x, g, z));
						const skeldat::NodeDef *n = m_world.node_of(id);
						if(id != ID_AIR && id != ID_IGNORE &&
								!(n && n->shape == skeldat::LIQUID))
							break;
					}
					const int rise = edge_rise(d, top - 1 - g);
					for(int y = g + 1; y <= g + rise; y++){
						const uint32_t id = m_world.format.id.get(vol.sample_at(x, y, z));
						const skeldat::NodeDef *n = m_world.node_of(id);
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

	// A client's click at a mob: what the player holds hits it, from no
	// further than a hand reaches with room for the lag
	void punch(size_t peer, Player &pl, uint32_t id)
	{
		if(id == 0 || m_world.time - pl.last_hit < 0.35 ||
				pl.main[pl.wield].name == "skeldat:bow")
			return;
		for(auto &kv : m_mobs.all){
			Mob &m = kv.second;
			if(m.node_id != id)
				continue;
			const float dy = pl.y + 1.6f - m.y - MOB_HEIGHT[m.kind] / 2.0f;
			if(std::sqrt((pl.x-m.x)*(pl.x-m.x) + (pl.z-m.z)*(pl.z-m.z) +
					dy * dy) > 6)
				return;
			pl.last_hit = m_world.time;
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
			m_mobs.damage(kv.first, dmg, peer, pl.x, pl.z);
			return;
		}
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_world.scene)
			return;
		// Every section loaded and generated: on the tick, after the
		// requests the last loads made are in m_awaiting
		if(!m_world_ready && m_save && m_growth.sections.size() == m_world.all_sections() &&
				m_awaiting.empty())
			world_in();
		// [SKELDAT_WORLD_ADMIN] Paused: the world's clock and every step of
		// the game stand; the sections load and send, the session takes
		// the joins
		if(m_paused){
			m_session.tick(event.dtime);
			if(m_load_points_dirty)
				update_load_points();
			return;
		}
		m_session.tick(event.dtime);
		// [SKELDAT_SKIP_TIME] Skipping: the world's steps in sub-steps
		if(m_skip_left > 0)
			step_skip();
		else
			step_world(event.dtime);
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
			// The players held while skipping: no move to check
			if(m_skip_left <= 0)
				check_moves();
			update_skeletons();
		}
		m_save_t += event.dtime;
		if(m_save_t >= 10){
			m_save_t = 0;
			save_and_report();
		}
	}

	// The bones a tick; a server behind says so in the chat
	void step_bones(float dtime)
	{
		m_growth.step(dtime, m_skip_left > 0, !m_players.empty(),
				[&](const char *line){
			chat::access(m_server, [&](chat::Interface *c){ c->say(line); });
		});
	}

	// The end at no bare column: the score, the save, the players told
	void step_end()
	{
		if(!m_growth.count(m_world_ready, m_world.t / m_world.day_s))
			return;
		char days_c[40];
		// The lowest speed it was at: a lower one is the easier
		snprintf(days_c, sizeof days_c, "%.1f days at %dx", m_growth.end_days,
				m_growth.speed_low);
		const ss_ days = days_c;
		m_store->set("ended", dtos(m_growth.end_days));
		m_save->store("world_menu")->set("ended", days);
		record_score();
		const int64_t under = m_growth.bare_under();
		log_i(MODULE, "skeldat: every column's top has bones: the world ends "
				"after %s; %lld voxels under the tops have none", cs(days),
				(long long)under);
		for(auto &pair : m_players)
			send_end(pair.first);
	}

	// The world's own steps over dtime of game time: the clock, the bones,
	// the end, the arrows, the drops, the mobs, the light, the spawns, the
	// breath and the furnaces
	void step_world(float dtime)
	{
		m_world.time += dtime;
		m_world.t += dtime;
		m_world.day = std::fmod(m_world.day + dtime / m_world.day_s, 1.0);
		if(!m_growth.ended)
			step_bones(dtime);
		if(!m_growth.ended && m_world_ready)
			for(auto &pair : m_players)
				if(pair.second.placed)
					m_played[pair.second.name] += dtime;
		step_end();
		m_mobs.step_arrows(dtime);
		step_drops(dtime);
		m_mobs.ai_t += dtime;
		if(m_mobs.ai_t >= 0.1f){
			// A long tick in steps of 0.2 s, so it is no fall through the
			// ground and a body keeps up with its light form, which steps
			// by the clock; past a second (the world's first sweep, 1.7 s)
			// the rest is dropped
			for(float left = std::min(m_mobs.ai_t, 1.0f); left > 1e-4f; left -= 0.2f)
				m_mobs.step_mobs(std::min(left, 0.2f));
			m_mobs.ai_t = 0;
		}
		if(m_world_ready){
			m_mobs.step_light(dtime);
			m_mobs.far_t += dtime;
			if(m_mobs.far_t >= std::min(m_mobs.light_step, 1.0f)){
				m_mobs.far_t = 0;
				m_mobs.send_far();
			}
			m_mobs.sweep_t += dtime;
			if(m_mobs.sweep_t >= 1){
				m_mobs.sweep_t = 0;
				const int64_t t0 = interface::os::time_us();
				voxelworld::access(m_server, m_world.scene,
						[&](voxelworld::Instance *w){
					m_growth.sweep(w, m_mobs.sweep++ % m_world.footprints());
				});
				m_mobs.light_us += interface::os::time_us() - t0;
			}
			const int phase = m_world.day >= 0.25 && m_world.day < 0.75;
			// The first tick's too: a world that starts at night has its
			// night's work
			if(phase != m_mobs.phase)
				m_mobs.pick_footprints(phase == 0);
			m_mobs.phase = phase;
			m_mobs.hour_t += dtime;
			if(m_mobs.hour_t >= m_world.day_s / 24){
				m_mobs.hour_t = 0;
				m_mobs.step_population();
			}
		}
		m_mobs.spawn_t += dtime;
		if(!m_mobs.test.empty())
			m_mobs.stage_test();
		else if(m_mobs.spawn_t >= 4){
			m_mobs.spawn_t = 0;
			m_mobs.spawn();
		}
		m_breath_t += dtime;
		if(m_breath_t >= 1){
			m_breath_t = 0;
			step_breath();
		}
		m_furnaces.step(dtime, m_world.day_s);
	}

	void save_and_report()
	{
		save();
		// The pace, for whoever tunes it
		log_i(MODULE, "skeldat: bones: %zu expansions so far, %zu voxels "
				"changed, %zu grown, %zu sections loaded, %zu rule runs "
				"at %dx", m_growth.expansions, m_growth.expand_changed, m_growth.grown,
				m_growth.sections.size(), m_growth.rule_runs, m_growth.speed);
		size_t skeletons = 0, full = 0;
		for(auto &kv : m_mobs.all)
			if(kv.second.kind == SKELETON)
				skeletons++, full += kv.second.node_id != 0;
		log_i(MODULE, "skeldat: %zu skeletons, %zu full, %zu woken; %zu "
				"light steps and the sweep, %.2f ms a second; %zu bodies "
				"put back", skeletons, full, m_mobs.woken, m_mobs.light_steps,
				m_mobs.light_us / 1e3 / 10, m_mobs.body_puts);
		m_mobs.light_us = 0, m_mobs.light_steps = 0, m_mobs.woken = 0, m_mobs.body_puts = 0;
		if(m_furnaces.report)
			m_furnaces.report_lanterns();
		for(auto &pair : m_players)
			send_time(pair.first);
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
			ss_ out = "players "+itos(m_growth.speed)+"\n";
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

	ss_ write_map()
	{
		const int S = skeldat::bones::SECTION, W = 2 * m_world.half * S;
		sv_<unsigned char> rgb((size_t)W * W * 3, 0);
		const uint32_t grass = m_world.id_of("skeldat:grass");
		voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
			for(int sz = -m_world.half; sz < m_world.half; sz++)
			for(int sx = -m_world.half; sx < m_world.half; sx++)
			m_world.each_top(w, sx, sz, [&](int x, int z, int, uint32_t id,
					const interface::VoxelSample &v){
				const skeldat::NodeDef *n = m_world.node_of(id);
				const bool water = n && n->shape == skeldat::LIQUID;
				const float base[3] = {
					id == grass ? 60.f : water ? 40.f : 128.f,
					id == grass ? 140.f : water ? 80.f : 128.f,
					id == grass ? 60.f : water ? 200.f : 128.f};
				const float b = m_world.bones.get(v) / (float)skeldat::bones::MAX;
				const size_t i = ((size_t)(W - 1 - (z + m_world.half * S)) * W +
						(x + m_world.half * S)) * 3;
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
		// [SKELDAT_WORLD_ADMIN] And world_menu's picker
		network::send(m_server, peer, "skeldat:role", ss_(admin ? "admin" : "")+
				(picker(peer) ? " picker" : ""));
		log_i(MODULE, "skeldat: %s is %s", cs(pl.name),
				admin ? "an admin" : "a player");
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
			const float dt = (float)(m_world.time - pl.check_t);
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
				pl.check_t = m_world.time;
				pl.check_air = false;
				pl.check_v = 0;
				pl.board_air = 0;
				continue;
			}
			skeldat::move_check::Verdict v;
			voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
				v = skeldat::move_check::check([&](vp::Field &f){
					m_world.fill_cells(w, f);
				}, pl.cx, pl.cy, pl.cz, pl.x, pl.y, pl.z, dt, pl.check_air, bd);
			});
			if(v.ok){
				pl.cx = pl.x;
				pl.cy = pl.y;
				pl.cz = pl.z;
				pl.check_t = m_world.time;
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
			voxelworld::access(m_server, m_world.scene, [&](voxelworld::Instance *w){
				now = skeldat::bones::skeleton_near([&](int vx, int vy, int vz){
					return (int)m_world.bones.get(w->get_sample(
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
		const uint32_t water = m_world.id_of("skeldat:water_source");
		for(auto &pair : m_players){
			Player &pl = pair.second;
			if(!pl.placed || pl.hp <= 0)
				continue;
			const bool under = m_world.id_at((int)std::floor(pl.x + 0.5f),
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


};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
