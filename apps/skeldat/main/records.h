// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **What every part of skeldat shares**: the node ids
// the registry fixes, the rules' constants, and the records kept and saved
// (Player, Furnace, Mob, Arrow, Drop).
// Included by main.cpp inside namespace skeldat, first
#pragma once

// Luanti's mapgens write these three as numbers (vendor/mapnode.h), so
// the registry has them at those ids: ignore is the registry's own
// undefined 0, and the game's nodes follow air
static const uint32_t ID_IGNORE = 0, ID_UNKNOWN = 1, ID_AIR = 2, ID_NODE0 = 3;
static const float REACH = 5.5f;       // a little over Luanti's 4 from the eye
// The eye over the feet, standing and lying on the board (player.lua's
// EYE_HEIGHT and PRONE_EYE)
static const float EYE = 1.625f, PRONE_EYE = 0.5f;
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
	// [SKELDAT_BOW_AIM] The speed between the last two wheres, and when
	// the last came (the server's clock)
	float speed = 0;
	double where_t = -1;
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
// [SKELDAT_BRIDGES_SEEN] The goal walk's waypoint WAYPOINT columns ahead,
// and one goal walk's search in the world every WALK_SEARCH_WAIT game
// seconds: each skeleton's own made the light step 15x dearer
static const int WAYPOINT = 12;
static const float WALK_SEARCH_WAIT = 1;
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
	// [SKELDAT_SKELETON_DRAW] Its bow's draw: seconds left, -1 none; and
	// the node's "skeldat_draw" as last set
	float draw_t = -1;
	int draw_sent = 0;
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
	// Since when it waits for a goal walk's search (0: it does not)
	double walk_want_t = 0;

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
static const float DROP_REACH = 3.0f;
// A drop's dropper walked this far from it, it is anyone's
static const float DROP_AWAY = 3.0f;

// Where something stands in a column (Module::ground())
struct Ground
{
	bool loaded = true, found = false, water = false;
	float y = 0; // the feet
	int sun = 0; // the sky's light there now
};
// vim: set noet ts=4 sw=4:
