// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// hillclimb ([HILLCLIMB], doc/plan/hillclimb_plan.md): a hill-climb
// time trial on generated voxel ground. The hill (hill.h) from its
// parameters, its textures made here, and the parameters the client
// lights it by (latitude, day, time of day); the car (car.h), whose
// chassis is a Bullet body here and whose tyres car.h works out, the
// server's physics authoritative. Nothing is saved: a track is generated
// from its parameters each time.
//
// The time trial: a player's clock starts on their first W after their
// car is put at the start and stops when its rear axle crosses the top
// pad's line; the time is kept in the save "ranking" under the hill's
// parameters and the payload, with the player's name and how worn the
// hill was. The client's menu picks them (hillclimb:params); the hill is
// then made again in the same world. The parameters the server starts
// with: BUILDAT_HILLCLIMB_SEED, _STEEP (degrees), _STEEP_VAR (degrees, its
// variance over the slope, [HC_STEEP_NOISE]), _LENGTH (the slope's
// run, m), _LATITUDE (degrees), _DAY (1..365), _TIME (hours, solar) and
// _PAYLOAD (kg); _FEATURES=0, no pits or rocks; _INTERVAL, the rounds'
// in seconds (a check's).
//
// [HC_CIRCUIT] _MODE=circuit: a loop of lanes on a wider hill (hill.h),
// _WIDTH, _LANE (m) and _SWITCHBACKS (%) its own, and the circuit's
// defaults for the rest. No finish: a run is the round's, ranked by its
// laps, ties by when the last was made. P in a drive steers its cars round
// the loop (the extra cars slower).
//
// [HC_MULTIPLAYER] A car each: every player in has one, driven by their
// own input; the cars do not touch each other (a collision layer of their
// own), the ground is the one hill's. On a public server (no launch
// parameter launcher=1) a player joins through builtin/accounts, and the
// hill's parameters are an admin's. Rounds: at an interval (never, or 1
// to 30 minutes; 10 by default), counted from the
// first player's drive, the players still driving get an extra interval
// and the rest observe; then the results, and the hill made anew: its
// worn ground as generated, the same parameters and seed ([HC_SCORES]:
// the seed is 1 at the start, BUILDAT_HILLCLIMB_SEED for a check, and
// changes only by the hill menu).
//
// For the check, with no client: BUILDAT_HILLCLIMB_DRIVE, steps of
// "<seconds>:<keys>" from the car's start, each held until the next --
// W accelerator, S brake, A and D steering, 1 to 4 and R the gear, B the
// car back at the start, H<steep>/<length> another hill, K a stone dropped
// on the slope, J one thrown off its left edge ([HC_OPEN_EDGES]), G one on
// the bottom pad, Q the
// server's end -- driving a car of its own (peer 0,
// "drive"), logging it each second; _CARS=<n>, n - 1 more cars driven by
// the same keys (the step's cost); and _START, "x z yaw" (m, m, degrees)
// for a start other than the bottom pad's.
//
// [HC_OPEN_EDGES] No banks: the voxel area's whole width is the track,
// and outside it hill.h's outside() is the ground, which the client
// draws from the heights sent (hillclimb:outside). Nothing collides with
// it: a car whose tyre or chassis corner touches it is put back to its
// pose 2 to 3 s before (each further one in a row 2 s further back,
// [HC_PUT_BACK_FURTHER]), and a stone that leaves the area is removed.
#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "main_context/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "storage/api.h"
#include "accounts/api.h"
#include "chat/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/os.h"
#include "core/json.h"
#include "hill.h"
#include "car.h"
#include "ground.h"
#include <PhysicsWorld.h>
#include <BulletDynamics/Dynamics/btDiscreteDynamicsWorld.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <Scene.h>
// Linked into the web server, the engine's Image.cpp has it already
#ifndef BUILDAT_STATIC_MODULES
#define STB_IMAGE_WRITE_IMPLEMENTATION
#endif
#define STBI_WRITE_NO_STDIO
#include <STB/stb_image_write.h>
#include <cstdlib>
#include <sstream>
#include <set>
#include <memory>
#include <deque>
#include <cctype>
#include <algorithm>
#include <mutex>
#include <map>
#include <tuple>
#include <ctime>
#define MODULE "main"

namespace pv = PolyVox;
namespace magic = Urho3D;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelVolume;
using main_context::SceneReference;

namespace main
{

// The registry's ids are hill::Voxel's plus one: 0 is "not generated".
// Every voxel in full sky light: no caves, no roofs, so the light is not
// maintained (on_start) and every write carries it
static uint32_t id_of(hill::Voxel v)
{
	uint32_t word = (uint32_t)v + 1;
	const auto &sky = interface::VoxelFormat::blocks().light_sky;
	sky.set(word, sky.mask());
	return word;
}

static float env_or(const char *name, float def)
{
	const char *v = getenv(name);
	return v && v[0] ? (float)atof(v) : def;
}

// What a player may pick ([HILLCLIMB] 3), which the server holds a
// client's pick to; the world's region is the largest of these hills
static const int STEEP_MIN = 5, STEEP_MAX = 40;
static const int VAR_MIN = 0, VAR_MAX = 10; // [HC_STEEP_NOISE]
static const int LENGTH_MIN = 20, LENGTH_MAX = 60;
// [HC_CIRCUIT] The circuit's width and lanes, m
static const int WIDTH_MIN = 12, WIDTH_MAX = 60, LANE_MIN = 4, LANE_MAX = 12;
static const int PAYLOADS[] = {0, 500, 1000, 2000};
// [HC_MULTIPLAYER] The rounds' intervals, seconds: never, or minutes
static const int INTERVALS[] = {0, 60, 120, 180, 300, 600, 900, 1800};
// [HC_SOFT_GROUND] How the ground gives and how the car drives into it,
// the hill menu's: the sand's bearing (kPa), digging (voxels per metre
// slid), the engine's power (% of the gears' torque), grip (the tyres'
// mu, hundredths) and the stones' looseness (% of a stone's front open
// to come free; its bed's mu with it). Grip works against the ruts: a
// tyre that slips less digs less. The defaults are ground.h's Soil and
// half again car.h's torque ([HC_SOFT_DEFAULTS]: the user's playtested set;
// 80 kPa, dig 2, 100% and 35% before).
// [HC_WET_SAND] And the layers: the loose sand's depth (voxels, 0 to 1 m)
// over the wet, and the wet sand's bearing (kPa); "bearing" and "dig" are
// the loose sand's. A new loose depth makes the hill anew.
// `old`: the firm soil before [HC_SOFT_DEFAULTS], what a ranking key with
// no part for the knob was driven on; the layers' are their defaults, the
// key's version (v7) telling the all-loose hill's times apart.
// [HC_LOOSE_DEFAULT] The loose sand one voxel deep by default; 3 before,
// what a v7 key with no "loose" part was driven on
struct Knob { const char *name; int def, min, max, old; };
static const Knob KNOBS[] = {{"bearing", 30, 20, 100, 80}, {"dig", 6, 1, 8, 2},
		{"power", 150, 50, 200, 100}, {"grip", 60, 40, 100, 60},
		{"stones", 20, 15, 50, 35}, {"loose", 1, 0, 8, 3},
		{"wet", 150, 50, 300, 150}};
static const int N_KNOBS = 7;
static const int KNOB_LOOSE = 5;
struct Knobs
{
	int v[N_KNOBS];
	Knobs(){ for(int i = 0; i < N_KNOBS; i++) v[i] = KNOBS[i].def; }
	bool operator!=(const Knobs &o) const
	{
		return !std::equal(v, v + N_KNOBS, o.v);
	}
	void soil(ground::Soil &s) const
	{
		const ground::Soil d;
		s.bearing = v[0] * 1000.0f;
		s.dig_rate = (float)v[1];
		s.open_front = v[4] / 100.0f;
		s.mu_bed = d.mu_bed * (v[4] / 100.0f) / d.open_front;
		s.wet_bearing = v[6] * 1000.0f;
	}
	void spec(car::Spec &s) const
	{
		const car::Spec d;
		for(int i = 0; i < car::GEARS; i++)
			s.gear_torque[i] = d.gear_torque[i] * v[2] / 100.0f;
		s.mu = v[3] / 100.0f;
	}
	// The ranking key's parts after "sand/": the ones off the old firm
	// soil's, so the times driven on it keep their keys
	ss_ key() const
	{
		ss_ k;
		for(int i = 0; i < N_KNOBS; i++)
			if(v[i] != KNOBS[i].old)
				k += ss_(KNOBS[i].name) + itos(v[i]) + "/";
		return k;
	}
	ss_ text() const
	{
		char buf[128];
		snprintf(buf, sizeof buf, "sand %d kPa, dig %d, power %d%%, grip %.2f, "
				"stones %d%%, loose %d, wet %d kPa", v[0], v[1], v[2],
				v[3] / 100.0f, v[4], v[5], v[6]);
		return buf;
	}
};
// The cars' collision layer: they touch the world and the stones, not
// each other
static const unsigned CAR_LAYER = 2;
// [HC_SCORES] The ranking's key version: v6 has no seed in it; v7 the
// layered sand's ([HC_WET_SAND]), v6's hill all loose
static const char *SCORES_VERSION = "v7";

struct Worldgen: public worldgen::GeneratorInterface
{
	// Swapped by the main thread when the hill changes
	std::mutex m_mutex;
	std::shared_ptr<const ground::Grid> m_grid;
	void set(const std::shared_ptr<const ground::Grid> &grid)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		m_grid = grid;
	}

	// On a worker thread: into the volume it is given
	void generate(SceneReference scene_ref, const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
		std::shared_ptr<const ground::Grid> grid;
		{
			std::lock_guard<std::mutex> lock(m_mutex);
			grid = m_grid;
		}
		const ground::Grid &m_hill = *grid;
		const pv::Region region = volume.getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		for(int z = lc.getZ(); z <= uc.getZ(); z++)
		for(int y = lc.getY(); y <= uc.getY(); y++)
		for(int x = lc.getX(); x <= uc.getX(); x++)
			volume.setVoxelAt(pv::Vector3DInt32(x, y, z),
					VoxelInstance(id_of(m_hill.drawn(x, y, z))));
	}
};

static void png_write_cb(void *context, void *data, int size)
{
	((ss_*)context)->append((const char*)data, size);
}

struct Module: public interface::Module
{
	interface::Server *m_server;
	SceneReference m_scene = nullptr;
	hill::Params m_params;
	Knobs m_knobs;
	float m_latitude = 60, m_day = 172, m_time = 14;
	up_<hill::Hill> m_hill;
	std::shared_ptr<ground::Grid> m_grid;
	// [HC_OPEN_EDGES] The ground outside, as sent (outside_packet)
	ss_ m_outside, m_fences;
	Worldgen *m_worldgen = nullptr; // worldgen's to delete
	// The ground that gives ([HILLCLIMB] 4), live once worldgen has made
	// every section: its workers read the grid until then
	up_<ground::Ground> m_ground;
	bool m_ground_live = false;
	uint64_t m_made_us = 0; // when make_hill queued the sections
	float m_flush_t = 0;
	int m_flushes = 0; // since the last car line: commits, so remeshes
	// The stones come loose, as bodies until they rest
	struct Rock
	{
		int id;
		magic::Node *node;
		magic::RigidBody *body;
		float radius, still = 0, age = 0;
		magic::Vector3 from;
		// [HC_STONE_KICK] Its voxels to rest as and its mass; a tyre on it
		// this tick, and whether a push was logged
		int voxels = 0;
		float kg = 0;
		bool touched = false, pushed = false;
		float pushed_t = -1; // when a tyre last pushed it
	};
	sv_<Rock> m_rocks;
	sv_<ground::Loose> m_loose;
	int m_next_rock = 1;
	bool m_rocks_sent = false;
	// A pick from the menu, made when worldgen has nothing queued
	bool m_pending = false;
	hill::Params m_pending_params;
	Knobs m_pending_knobs;
	float m_pending_look[3] = {0, 0, 0};
	float m_pending_payload = 0;
	// The time trial; OUT: the round ended the run ("did not finish")
	enum Race { READY, RUNNING, FINISHED, OUT };
	storage::Save *m_save = nullptr;
	// [HC_MULTIPLAYER] A player and their car: car.h's model, its
	// chassis' body, their input and their run. Peer 0 and up from
	// BOT_PEER are the check's drive's (no client).
	struct Player
	{
		size_t peer = 0;
		int id = 0;
		ss_ name;
		up_<car::Car> car;
		magic::RigidBody *body = nullptr;
		car::Input input;
		Race race = READY;
		float race_t = 0;
		int last_rank = -1;
		bool reset = false, observing = false;
		// [HC_RESET_KEEP_GROUND] This reset only moves the car
		bool keep_ground = false;
		// The hill's ended runs when this run started
		int fin_at = 0, unfin_at = 0;
		// [HC_OPEN_EDGES] Its pose once a second while its four tyres are
		// over the voxel area; [HC_PUT_BACK_FURTHER] the ones over 30 s old
		// dropped only at a checkpoint. The put-backs in a row since the
		// last checkpoint, and when the first of them was; the straight
		// hill's last 10 m mark passed
		// [HC_LAP_TURNS] With the lap as it was there, which a put-back
		// takes back with the pose
		struct Snap { magic::Vector3 p; magic::Quaternion q; float t;
				hill::Hill::Lap lap; };
		std::deque<Snap> snaps;
		float snap_t = -1;
		int series = 0;
		float series_t = 0;
		int mark = -1;
		// [HC_CIRCUIT] Its laps, and the round's clock at the last
		hill::Hill::Lap lap;
		// [HC_MISSED_TURN_MARK] The turn it went past without passing,
		// marked on its client until it is driven or the car put back; 0
		// none
		size_t missed = 0;
		float lap_t = 0;
	};
	static const size_t BOT_PEER = 1000000000;
	std::map<size_t, Player> m_players;
	int m_next_id = 1;
	magic::PhysicsWorld *m_physics = nullptr;
	float m_payload = 0;
	// The runs ended on this hill since it was made
	int m_hill_finished = 0, m_hill_unfinished = 0;
	// The rounds: the interval (0 never), the phase and its time
	enum Round { R_WAITING, R_RUNNING, R_EXTRA, R_RESULTS } m_round = R_WAITING;
	float m_interval = 0, m_round_t = 0, m_round_sent = 0;
	bool m_public = true;
	// Sent the join (accounts), not yet in
	std::set<size_t> m_joining;
	float m_start_x = 0, m_start_z = 0, m_start_yaw = 0; // m, m, degrees
	bool m_start_set = false;
	std::set<network::PeerInfo::Id> m_peers;
	// The check's drive (BUILDAT_HILLCLIMB_DRIVE)
	sv_<std::pair<float, ss_>> m_drive;
	int m_drive_step = -1;
	float m_t = 0, m_logged = -1;
	// [HC_STONE_WALL] When a stone's refused kick was last logged
	std::map<std::tuple<int, int, int>, float> m_held_t;
	// The physics' time per tick since the last car line, for the check
	uint64_t m_step_us = 0;
	int m_step_ticks = 0;
	static const int SUBSTEPS_HZ = 240;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		// The circuit by default; _MODE=straight the climb
		const char *mode = getenv("BUILDAT_HILLCLIMB_MODE");
		const bool c = !(mode && ss_(mode) == "straight");
		m_params.circuit = c;
		m_params.seed = (uint32_t)env_or("BUILDAT_HILLCLIMB_SEED", 1);
		m_params.steep_deg = env_or("BUILDAT_HILLCLIMB_STEEP", c ? 18 : 27);
		m_params.steep_var_deg = std::fmin(VAR_MAX, std::fmax(VAR_MIN,
				(int)env_or("BUILDAT_HILLCLIMB_STEEP_VAR", 4)));
		m_params.length_m = env_or("BUILDAT_HILLCLIMB_LENGTH", c ? 40 : 50);
		m_params.width_m = env_or("BUILDAT_HILLCLIMB_WIDTH", 40);
		m_params.lane_m = std::fmin(m_params.width_m / 2,
				env_or("BUILDAT_HILLCLIMB_LANE", 7));
		m_params.switchbacks = (int)env_or("BUILDAT_HILLCLIMB_SWITCHBACKS", 50);
		// [HC_SOFT_GROUND] _BEARING, _DIG, _POWER, _GRIP, _STONES
		for(int i = 0; i < N_KNOBS; i++){
			ss_ e = "BUILDAT_HILLCLIMB_" + ss_(KNOBS[i].name);
			std::transform(e.begin(), e.end(), e.begin(), ::toupper);
			m_knobs.v[i] = std::max(KNOBS[i].min, std::min(KNOBS[i].max,
					(int)env_or(e.c_str(), (float)KNOBS[i].def)));
		}
		// For the car's checks: a hill with no pits or rocks
		m_params.features = env_or("BUILDAT_HILLCLIMB_FEATURES", 1) != 0;
		m_latitude = env_or("BUILDAT_HILLCLIMB_LATITUDE", 60);
		m_day = env_or("BUILDAT_HILLCLIMB_DAY", 172);
		m_time = env_or("BUILDAT_HILLCLIMB_TIME", 14);
		m_payload = std::fmax(0, std::fmin(2000,
				env_or("BUILDAT_HILLCLIMB_PAYLOAD", 0)));
		if(const char *s = getenv("BUILDAT_HILLCLIMB_START")){
			// "x z yaw", or "x,z,yaw" where a space would split the variable
			ss_ v = s;
			std::replace(v.begin(), v.end(), ',', ' ');
			std::istringstream is(v);
			m_start_set = (bool)(is >> m_start_x >> m_start_z >> m_start_yaw);
		}
		if(const char *s = getenv("BUILDAT_HILLCLIMB_DRIVE")){
			std::istringstream is(s);
			ss_ step;
			while(is >> step){
				size_t c = step.find(':');
				if(c != ss_::npos)
					m_drive.push_back(std::make_pair(
							(float)atof(step.substr(0, c).c_str()),
							step.substr(c + 1)));
			}
		}
		sub(m_server, "core:start", &Module::on_start);
		sub(m_server, "core:tick", &Module::on_tick);
		sub(m_server, "client_file:files_transmitted",
				&Module::on_files_transmitted);
		sub(m_server, "network:client_disconnected",
				&Module::on_client_disconnected);
		sub(m_server, "network:packet_received/hillclimb:input",
				&Module::on_input);
		sub(m_server, "network:packet_received/hillclimb:params",
				&Module::on_params);
		sub(m_server, "accounts:login", &Module::on_login);
		sub(m_server, "network:packet_received/hillclimb:scores",
				&Module::on_scores);
	}

	// A texture of 16 pixels square, a colour and a grain, no file behind it
	// (minimal assets: [HILLCLIMB])
	static ss_ texture(uint32_t salt, const uint8_t rgb[3], int grain)
	{
		const int S = 16;
		uint8_t px[S * S * 3];
		for(int i = 0; i < S * S; i++){
			int d = (int)(hill::Hill::hash(i, salt, 3, 5) % (2 * grain + 1)) -
					grain;
			for(int c = 0; c < 3; c++){
				int v = rgb[c] + d;
				px[i * 3 + c] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v);
			}
		}
		ss_ png;
		stbi_write_png_to_func(png_write_cb, &png, S, S, 3, px, S * 3);
		return png;
	}

	void serve_media()
	{
		// The day's schedule, luanti_client's, as skeldat serves it (the
		// sky's render is extensions/sky_render, [SKY_RENDER_SHARED])
		const ss_ res = m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res/";
		static const uint8_t SAND[3] = {196, 174, 128};
		static const uint8_t STONE[3] = {128, 124, 116};
		static const uint8_t FILL[3] = {120, 98, 72};
		static const uint8_t WET[3] = {150, 122, 84}; // [HC_WET_SAND]
		// [HC_OPEN_EDGES] The fence's ribbon: red and white diagonal
		// stripes, 4 pixels wide
		const int S = 16;
		uint8_t px[S * S * 3];
		for(int i = 0; i < S * S; i++){
			const bool red = ((i % S + i / S) / 4) % 2 == 0;
			px[i * 3] = red ? 200 : 240;
			px[i * 3 + 1] = red ? 30 : 240;
			px[i * 3 + 2] = red ? 30 : 236;
		}
		ss_ ribbon;
		stbi_write_png_to_func(png_write_cb, &ribbon, S, S, 3, px, S * 3);
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_path("luanti/sky_model.lua", res+"sky_model.lua");
			i->add_file_content("main/sand.png", texture(1, SAND, 14));
			i->add_file_content("main/stone.png", texture(2, STONE, 18));
			i->add_file_content("main/fill.png", texture(3, FILL, 10));
			i->add_file_content("main/wet_sand.png", texture(4, WET, 12));
			i->add_file_content("main/ribbon.png", ribbon);
		});
	}

	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool solid, float roughness)
	{
		interface::VoxelDefinition d;
		d.name.block_name = name;
		for(size_t i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = d.textures[i];
			seg.resource_name = texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
			seg.roughness = roughness;
		}
		d.edge_material_id = solid ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		d.physically_solid = solid;
		d.fully_empty = !solid;
		reg->add_voxel(d);
	}

	void on_start()
	{
		serve_media();
		// [HC_GUEST_PLAY] "Play as a guest" on the login window
		accounts::access(m_server, [&](accounts::Interface *i){
			i->set_guests(true);
		});
		m_scene = main_context::create_scene(m_server);
		// Before voxelworld, or its first generation requests are lost
		m_worldgen = new Worldgen();
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->create_instance(m_scene);
			i->get_instance(m_scene)->set_generator(m_worldgen);
		});
		// The region is the largest hill's, in sections of 64 voxels; the
		// hill's own are pinned (make_hill)
		hill::Params most;
		// [HC_STEEP_NOISE] As steep as a variance can make it, all of it;
		// [HC_CIRCUIT] as wide as a circuit
		most.steep_deg = STEEP_MAX + VAR_MAX;
		most.length_m = LENGTH_MAX;
		most.circuit = true;
		most.width_m = WIDTH_MAX;
		most.features = false;
		const hill::Hill big(most);
		const int S = 64;
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			i->create_instance(m_scene, pv::Region(0, 0, 0,
					(big.size_x() - 1) / S, (big.size_y() - 1) / S,
					(big.size_z() - 1) / S), true);
		});
		// Streaming at once: the region is the largest hill's bounds, not a
		// thing to fill, and its first tick filled it all before make_hill's
		// points (a circuit's 60 m made the straight hill 6 s slower)
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			w->set_load_points({});
		});
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			reg->set_format(interface::VoxelFormat::blocks());
			add_voxel(reg, "air", "", false, 1);             // hill::AIR
			add_voxel(reg, "sand", "main/sand.png", true, 0.95f);
			add_voxel(reg, "stone", "main/stone.png", true, 0.7f);
			add_voxel(reg, "fill", "main/fill.png", true, 0.95f);
			add_voxel(reg, "wet_sand", "main/wet_sand.png", true, 0.9f);
			w->set_skylight_enabled(false); // id_of(): all in the sky's
		});
		// The grid before worldgen runs: its workers read it
		make_hill();
		worldgen::access(m_server, m_scene, [&](worldgen::Instance *i){
			i->enable();
		});
		storage::access(m_server, [&](storage::Interface *i){
			m_save = i->open("ranking");
			if(!m_save)
				m_save = i->create("ranking");
		});
		if(!m_save)
			log_w(MODULE, "hillclimb: no ranking: the save would not open");
		read_old_scores();
		// [HC_MULTIPLAYER] A public server is one not started by the
		// launcher for its own client, as vanilla works it out
		bool refused = false;
		m_public = interface::launch_param(m_server->get_config().get<ss_>(
				"untrusted_launch"), "launcher", &refused) != "1";
		// The interval: a check's, the admin's kept, or the default
		ss_ kept;
		const char *env = getenv("BUILDAT_HILLCLIMB_INTERVAL");
		if(env && env[0])
			m_interval = (float)atof(env);
		else if(m_save && m_save->store("settings")->get("interval", kept))
			m_interval = (float)atof(kept.c_str());
		else
			m_interval = 600;
		// [HC_CIRCUIT] Laps are counted to a round's end
		if(m_params.circuit && m_interval <= 0)
			m_interval = 600;
		log_i(MODULE, "hillclimb: %s server, rounds every %.0f s", m_public ?
				"a public" : "a local", m_interval);
		setup_physics();
		if(!m_drive.empty()){
			const int cars = std::max(1, (int)env_or("BUILDAT_HILLCLIMB_CARS", 1));
			add_player(0, "drive");
			for(int i = 1; i < cars; i++)
				add_player(BOT_PEER + i, "drive"+itos(i));
		}
	}

	// The hill of m_params, in the world in place of the one there: the
	// sections of the old one unloaded and the new one's pinned, which
	// generates them from the new grid
	// simplified: the grid is made on the main thread, a quarter of a
	// second for the default hill (-O1)
	void make_hill()
	{
		m_params.loose = m_knobs.v[KNOB_LOOSE];
		m_hill.reset(new hill::Hill(m_params));
		const hill::Hill &h = *m_hill;
		m_grid = std::make_shared<ground::Grid>(h);
		m_worldgen->set(m_grid);
		m_ground.reset(new ground::Ground(*m_grid, h));
		m_knobs.soil(m_ground->soil);
		m_outside = outside_packet(h);
		m_fences = fences_packet(h);
		m_ground_live = false;
		m_made_us = interface::os::time_us();
		clear_rocks();
		const int S = 64;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(const pv::Vector3DInt16 &sp : w->get_loaded_sections())
				w->unload_section(sp);
			// [HC_HOLLOW_MIDDLE] A circuit's middle, off every lane, is left
			// out: never loaded, generated or sent; the client draws the
			// land there
			sv_<voxelworld::LoadPoint> pins;
			int hollow = 0;
			for(int z = 0; z <= (h.size_z() - 1) / S; z++)
			for(int x = 0; x <= (h.size_x() - 1) / S; x++){
				if(h.hollow_section(x, z)){
					hollow++;
					continue;
				}
				for(int y = 0; y <= (h.size_y() - 1) / S; y++)
					pins.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
							x * S + S / 2, y * S + S / 2, z * S + S / 2), 0, 0, 0, 0));
			}
			if(hollow)
				log_i(MODULE, "hillclimb: %d section columns of the middle left "
						"out", hollow);
			w->set_load_points(pins);
			// Asked for now, not by the streamer's later passes: the ground
			// goes live when worldgen's queue is empty
			for(const voxelworld::LoadPoint &lp : pins)
				w->load_or_generate_section(pv::Vector3DInt16(lp.p.getX() / S,
						lp.p.getY() / S, lp.p.getZ() / S));
		});
		log_i(MODULE, "hillclimb: the hill, seed %u, %.0f degrees +-%.0f, %.0f m "
				"long, %.1f m high; %dx%dx%d voxels; %s", m_params.seed,
				m_params.steep_deg, m_params.steep_var_deg, m_params.length_m,
				h.rise / hill::U,
				h.size_x(), h.size_y(), h.size_z(), cs(m_knobs.text()));
		if(m_params.circuit)
			log_i(MODULE, "hillclimb: a circuit %.0f m wide, lanes of %.1f m, "
					"switchbacks %d%%: %zu turns, %zu fences", m_params.width_m,
					h.lane / hill::U, m_params.switchbacks, h.path.size() - 1,
					h.fences.size());
	}

	//
	// The car
	//

	// Where it starts: on the bottom pad facing up the hill, or the
	// check's _START, a little over the ground to settle
	void place_car(Player &pl)
	{
		const float U = hill::U;
		const hill::Hill &h = *m_hill;
		float x = m_start_x, z = m_start_z, yaw = m_start_yaw;
		if(!m_start_set){
			h.start(x, z, yaw);
			x /= U, z /= U;
		}
		const car::Spec &s = pl.car->spec;
		// On the surface under it (the pad's is BASE), the floor's off the
		// area ([HC_OPEN_EDGES]: a check's start on the slope)
		const int ground = h.over(x * U, z * U) ? h.surface((int)std::lround(x * U),
				(int)std::lround(z * U)) : hill::Hill::BASE;
		float y = (ground + 0.5f) / U + s.tyre_r + s.droop - s.mount_y + 0.05f;
		magic::Node *n = pl.body->GetNode();
		n->SetWorldPosition(magic::Vector3(x * U, y * U, z * U));
		n->SetWorldRotation(magic::Quaternion(yaw, magic::Vector3::UP));
		pl.body->SetLinearVelocity(magic::Vector3::ZERO);
		pl.body->SetAngularVelocity(magic::Vector3::ZERO);
		pl.body->Activate();
		pl.car->shaft = pl.car->pedal = pl.car->brake = pl.car->steer = 0;
		pl.snaps.clear();
		pl.snap_t = -1;
		pl.series = 0;
		pl.mark = -1;
		set_missed(pl, 0);
	}
	// [HC_MISSED_TURN_MARK] To its client: "N x0 z0 x1 z1 y", turn N's
	// square in voxels and the ground there, marked; "ok ..." the same
	// driven at last; "" none
	void set_missed(Player &pl, size_t turn, bool ok = false)
	{
		const size_t was = pl.missed;
		pl.missed = turn;
		const size_t n = turn ? turn : was;
		if(n == 0 || pl.peer == 0 || pl.peer >= BOT_PEER)
			return;
		ss_ s;
		if(turn || ok){
			const hill::Hill::Box b = m_hill->turn_square(n);
			const int y = m_hill->surface((int)std::lround((b.x0 + b.x1) / 2),
					(int)std::lround((b.z0 + b.z1) / 2));
			char buf[100];
			snprintf(buf, sizeof buf, "%zu %.1f %.1f %.1f %.1f %d", n, b.x0, b.z0,
					b.x1, b.z1, y);
			s = (ok ? "ok " : "")+ss_(buf);
		}
		network::send(m_server, pl.peer, "hillclimb:missed", s);
	}
	// [HC_PUT_BACK_FURTHER] A checkpoint passed (a circuit's turn, the
	// straight hill's every 10 m of slope): the poses over 30 s old
	// dropped, the put-backs' count from zero again
	void checkpoint(Player &pl)
	{
		while(!pl.snaps.empty() && m_t - pl.snaps.front().t > 30)
			pl.snaps.pop_front();
		pl.series = 0;
	}

	// [HC_OPEN_EDGES] The car's tyres' hubs (each at its spring's
	// compression) and its chassis' corners, in voxels
	sv_<magic::Vector3> car_points(Player &pl, bool corners)
	{
		const float U = hill::U;
		magic::Node *n = pl.body->GetNode();
		const magic::Vector3 p = n->GetWorldPosition();
		const magic::Quaternion q = n->GetWorldRotation();
		const car::Spec &s = pl.car->spec;
		sv_<magic::Vector3> out;
		for(const car::Wheel &w : pl.car->wheel)
			out.push_back(p + q * magic::Vector3(w.local.x, w.local.y + w.spring,
					w.local.z) * U);
		for(int i = 0; corners && i < 8; i++)
			out.push_back(p + q * magic::Vector3((i & 1 ? 0.5f : -0.5f) * s.box_w,
					(i & 2 ? 0.5f : -0.5f) * s.box_h,
					(i & 4 ? 0.5f : -0.5f) * s.box_l) * U);
		return out;
	}
	// A tyre's bottom or a corner at or under the ground outside the area
	bool touches_outside(Player &pl)
	{
		const float U = hill::U;
		const sv_<magic::Vector3> pts = car_points(pl, true);
		for(size_t i = 0; i < pts.size(); i++){
			const magic::Vector3 &c = pts[i];
			const float low = c.y_ - (i < 4 ? pl.car->spec.tyre_r * U : 0);
			if(!m_hill->on_track(c.x_, c.z_) && low <= m_hill->outside(c.x_, c.z_))
				return true;
		}
		return false;
	}
	// A tyre's sphere at full droop over a solid voxel's centre
	bool tyre_in_ground(Player &pl)
	{
		const float U = hill::U;
		magic::Node *n = pl.body->GetNode();
		const magic::Vector3 p = n->GetWorldPosition();
		const magic::Quaternion q = n->GetWorldRotation();
		const float r = pl.car->spec.tyre_r * U + 0.5f;
		for(const car::Wheel &w : pl.car->wheel){
			const magic::Vector3 c = p + q * magic::Vector3(w.local.x,
					w.local.y, w.local.z) * U;
			for(int z = (int)std::floor(c.z_ - r); z <= (int)std::ceil(c.z_ + r); z++)
			for(int y = (int)std::floor(c.y_ - r); y <= (int)std::ceil(c.y_ + r); y++)
			for(int x = (int)std::floor(c.x_ - r); x <= (int)std::ceil(c.x_ + r); x++)
				if(m_grid->solid(x, y, z) && (magic::Vector3((float)x, (float)y,
						(float)z) - c).Length() < r)
					return true;
		}
		return false;
	}
	// Each substep: a pose kept a second after the last while every tyre
	// is over the area; touching the outside (a tyre's hub over the edge
	// is: its bottom is the ground's height there), the car put back to
	// the pose 2 s before (4, 6 ... s for the next in a row,
	// [HC_PUT_BACK_FURTHER]), still, lifted a voxel at a time out of the ground (it may
	// have been dug since) and a voxel more; with none, the start. The run
	// goes on. In main_context's access.
	void edges_step(Player &pl)
	{
		const float U = hill::U;
		magic::Node *n = pl.body->GetNode();
		if(m_t - pl.snap_t >= 1){
			bool over = true;
			for(const magic::Vector3 &c : car_points(pl, false))
				over = over && m_hill->on_track(c.x_, c.z_);
			if(over){
				pl.snap_t = m_t;
				pl.snaps.push_back(Player::Snap{n->GetWorldPosition(),
						n->GetWorldRotation(), m_t, pl.lap});
				// simplified: an hour's poses at most with no checkpoint
				// passed (a car parked); past it the oldest go
				if(pl.snaps.size() > 3600)
					pl.snaps.pop_front();
			}
		}
		// [HC_LAP_TURNS] A circuit's car whose middle is on the track but
		// out of its lap's lanes went past its next turn without passing
		// it. [HC_MISSED_TURN_MARK] That turn marked on its client, and the
		// car put back only once it is past the turn after it: the mark
		// seen for a whole lane first. Driven through, the mark is green
		// for a second and gone.
		const magic::Vector3 mid = n->GetWorldPosition();
		const magic::Vector3 off = mid / U;
		bool crossed = false;
		if(m_params.circuit && pl.race == RUNNING){
			if(pl.missed && pl.lap.next != pl.missed){
				log_i(MODULE, "hillclimb: %s drove the missed turn %zu at "
						"%.2f,%.2f m", cs(pl.name), pl.missed, off.x_, off.z_);
				set_missed(pl, 0, true);
			}
			const bool track = m_hill->on_track(mid.x_, mid.z_);
			if(!pl.missed && track && !m_hill->in_lap_lanes(pl.lap, mid.x_, mid.z_)){
				log_i(MODULE, "hillclimb: %s missed turn %zu, past it at %.2f,%.2f m",
						cs(pl.name), pl.lap.next, off.x_, off.z_);
				set_missed(pl, pl.lap.next);
			}
			if(pl.missed){
				hill::Hill::Lap ahead = pl.lap;
				ahead.next = pl.missed + 1;
				crossed = m_hill->lap_step(ahead, mid.x_, mid.z_) ||
						ahead.next != pl.missed + 1 ||
						(track && !m_hill->in_lap_lanes(ahead, mid.x_, mid.z_));
			}
		}
		if(!crossed && !touches_outside(pl))
			return;
		const size_t missed = crossed ? pl.missed : 0;
		if(crossed)
			log_i(MODULE, "hillclimb: %s past the turn after the missed %zu at "
					"%.2f,%.2f m", cs(pl.name), missed, off.x_, off.z_);
		// For a missed turn, the newest pose before it, in the lane to it:
		// one put-back ([HC_MISSED_TURN_MARK]), not a series past it
		const Player::Snap *before_turn = nullptr;
		for(const Player::Snap &c : pl.snaps)
			if(missed && c.lap.next == missed &&
					m_hill->in_lane(missed - 1, c.p.x_, c.p.z_))
				before_turn = &c;
		int back = -1;
		if(pl.snaps.empty()){
			place_car(pl);
			pl.lap.next = 1;
			pl.lap.at = false;
			log_i(MODULE, "hillclimb: %s's car put back to the start, off the "
					"track at %.2f,%.2f m", cs(pl.name), off.x_, off.z_);
		} else {
			// The k-th put-back in a row to the pose about 2k s before the
			// first of them, none newer; with none that old, the oldest
			if(pl.series++ == 0 || before_turn)
				pl.series_t = m_t;
			const float before = pl.series_t - 2 * pl.series;
			Player::Snap s = pl.snaps.front();
			for(const Player::Snap &c : pl.snaps)
				if(c.t <= before)
					s = c;
			if(before_turn){
				s = *before_turn;
				pl.series = 0;
			}
			n->SetWorldPosition(s.p);
			n->SetWorldRotation(s.q);
			pl.lap = s.lap;
			int lifted = 0;
			while(lifted < 8 * U && tyre_in_ground(pl)){
				n->SetWorldPosition(n->GetWorldPosition() + magic::Vector3(0, 1, 0));
				lifted++;
			}
			n->SetWorldPosition(n->GetWorldPosition() + magic::Vector3(0, 1, 0));
			pl.body->SetLinearVelocity(magic::Vector3::ZERO);
			pl.body->SetAngularVelocity(magic::Vector3::ZERO);
			pl.body->Activate();
			pl.car->shaft = 0;
			const magic::Vector3 to = n->GetWorldPosition() / U;
			log_i(MODULE, "hillclimb: %s's car put back (%d in a row), the "
					"pose %.1f s before the first, off the track at %.2f,%.2f m, "
					"to %.2f,%.2f,%.2f m, lifted %d voxels", cs(pl.name), pl.series,
					pl.series_t - s.t, off.x_, off.z_, to.x_, to.y_, to.z_, lifted);
			// The poses kept as they are (lifted again if it is put back
			// to one again), the next a second from here
			pl.snap_t = m_t;
			back = (int)std::lround(pl.series_t - s.t);
		}
		// The lap is the pose's: what it owes is what it shows
		set_missed(pl, 0);
		// [HC_LAP_TURNS] A missed turn named, the HUD quiet otherwise; the
		// turn itself was marked from where it was missed
		const ss_ what = crossed ? "Missed turn "+itos(missed) :
				ss_("Off the track");
		if(pl.peer != 0 && pl.peer < BOT_PEER)
			network::send(m_server, pl.peer, "hillclimb:note", back < 0 ? what :
					what+": back "+itos(back)+" s");
	}

	void setup_physics()
	{
		const float U = hill::U;
		main_context::access(m_server, m_scene, [&](magic::Scene *scene){
			m_physics = scene->GetComponent<magic::PhysicsWorld>();
			// The car's substeps are this module's (on_tick); a world unit
			// is a voxel, so gravity is in voxels
			m_physics->SetUpdateEnabled(false);
			m_physics->SetMaxSubSteps(-1);
			m_physics->SetGravity(magic::Vector3(0, -9.81f * U, 0));
			// Only what moves gets its bounds worked out each step: the
			// voxels' boxes are many and still, and updating them all
			// was half the physics' time
			m_physics->GetWorld()->setForceUpdateAllAabbs(false);
			// A floor for the chassis at the bottom pad's surface, the
			// ground's level all round (Grid::solid): the tyres' contact
			// is shallow, and a car off the top sank into the ground with
			// nothing to stop it at the end of its fall (now put back as
			// it leaves the area: the floor is the drives' flat, _START)
			magic::Node *floor = scene->CreateChild("Floor", magic::LOCAL);
			floor->SetPosition(magic::Vector3(0,
					hill::Hill::BASE + 0.5f, 0));
			floor->CreateComponent<magic::RigidBody>(magic::LOCAL);
			floor->CreateComponent<magic::CollisionShape>(magic::LOCAL)->
					SetStaticPlane();
		});
	}

	// A player in, a car of their own at the start; their client told
	// which car is theirs
	void add_player(size_t peer, const ss_ &name)
	{
		if(m_players.count(peer))
			return;
		const float U = hill::U;
		Player &pl = m_players[peer];
		pl.peer = peer;
		pl.id = m_next_id++;
		pl.name = name;
		pl.input.gear = car::G2;
		// A run cannot start in a round's extra time
		pl.observing = m_round == R_EXTRA || m_round == R_RESULTS;
		main_context::access(m_server, m_scene, [&](magic::Scene *scene){
			car::Spec spec;
			m_knobs.spec(spec);
			pl.car.reset(new car::Car(spec, m_payload));
			const car::Spec &s = pl.car->spec;
			// Local: the client draws the car from hillclimb:car
			magic::Node *n = scene->CreateChild("Car", magic::LOCAL);
			pl.body = n->CreateComponent<magic::RigidBody>(magic::LOCAL);
			pl.body->SetMass(pl.car->mass());
			pl.body->SetFriction(0.6f);
			pl.body->SetCollisionLayerAndMask(CAR_LAYER, 0xffff & ~CAR_LAYER);
			auto *shape = n->CreateComponent<magic::CollisionShape>(
					magic::LOCAL);
			shape->SetBox(magic::Vector3(s.box_w, s.box_h, s.box_l) * U);
			place_car(pl);
		});
		log_i(MODULE, "hillclimb: %s's car (%d), %.0f kg with %.0f kg of "
				"payload; %zu cars", cs(name), pl.id, pl.car->spec.mass,
				m_payload, m_players.size());
		if(peer != 0 && peer < BOT_PEER){
			network::send(m_server, peer, "hillclimb:you", itos(pl.id));
			send_hill(peer);
			chat::access(m_server, [&](chat::Interface *c){ c->join(peer, name); });
			send_ranking(peer);
		}
	}

	void remove_player(size_t peer)
	{
		auto it = m_players.find(peer);
		if(it == m_players.end())
			return;
		Player &pl = it->second;
		if(pl.race == RUNNING)
			m_hill_unfinished++;
		main_context::access(m_server, [&](main_context::Interface *){
			pl.body->GetNode()->Remove();
		});
		log_i(MODULE, "hillclimb: %s's car (%d) gone", cs(pl.name), pl.id);
		m_players.erase(it);
	}

	// The check's drive: the keys of the step whose time has come, for
	// each of its cars
	void drive_step()
	{
		ss_ keys;
		int step = -1;
		for(size_t i = 0; i < m_drive.size(); i++){
			if(m_drive[i].first > m_t)
				break;
			keys = m_drive[i].second;
			step = (int)i;
		}
		if(step < 0)
			return;
		// What a step does once, when it comes
		if(step != m_drive_step){
			m_drive_step = step;
			// L: the High scores page's answers logged ([HC_SCORES])
			if(keys.find('L') != ss_::npos){
				log_i(MODULE, "hillclimb: scores sets %s", cs(scores_answer(
						"sets").stringify()));
				log_i(MODULE, "hillclimb: scores set %s", cs(scores_answer(
						"set "+ranking_prefix()).stringify()));
			}
			// O: where each drive car is, its next turn and the lanes it
			// is in ([HC_BACKTRACK]'s check)
			if(keys.find('O') != ss_::npos && m_params.circuit)
				for(auto &kv : m_players){
					if((kv.first != 0 && kv.first < BOT_PEER) || !kv.second.body)
						continue;
					const magic::Vector3 q = kv.second.body->GetNode()->
							GetWorldPosition();
					ss_ in;
					for(size_t i = 0; i < m_hill->lanes.size(); i++)
						if(m_hill->in_lane(i, q.x_, q.z_))
							in += " " + itos(i);
					log_i(MODULE, "hillclimb: %s at %.2f,%.2f m, turn %zu next, "
							"lanes%s", cs(kv.second.name), q.x_ / hill::U,
							q.z_ / hill::U, kv.second.lap.next, cs(in));
				}
			// V: the sand's volume, and the bottom pad behind the start's
			// columns a voxel over all their neighbours ([HC_SAND_VOLUME]);
			// [HC_WET_SAND] the deepest column under the hill as made, eighths
			if(keys.find('V') != ss_::npos && m_grid){
				const ground::Grid &g = *m_grid;
				long long eighths = 0;
				for(size_t i = 0; i < g.v.size(); i++)
					if(g.v[i] == hill::SAND || g.v[i] == hill::WET)
						eighths += g.f[i];
				int lone = 0;
				for(int z = 1; z < hill::Hill::PAD / 2; z++)
				for(int x = 1; x + 1 < g.sx; x++){
					const int h = g.height8(x, z);
					lone += h - std::max(std::max(g.height8(x + 1, z),
							g.height8(x - 1, z)), std::max(g.height8(x, z + 1),
							g.height8(x, z - 1))) >= 8;
				}
				int deepest = 0;
				for(int z = 0; z < g.sz; z++)
				for(int x = 0; x < g.sx; x++)
					deepest = std::max(deepest, (m_hill->surface(x, z) + 1) * 8 -
							g.height8(x, z));
				log_i(MODULE, "hillclimb: sand %lld eighths; behind the start %d "
						"columns a voxel over their neighbours; the deepest %d "
						"eighths under the hill as made, loose %d", eighths, lone,
						deepest, m_params.loose);
			}
			// Z: each drive car's Backspace as a player's ([HC_RESET_KEEP_GROUND])
			if(keys.find('Z') != ss_::npos)
				for(auto &kv : m_players)
					if(kv.first == 0 || kv.first >= BOT_PEER)
						backspace(kv.second);
			if(keys.find('B') != ss_::npos)
				for(auto &kv : m_players)
					if(kv.first == 0 || kv.first >= BOT_PEER)
						reset_race(kv.second);
			// A stone dropped on the slope's lower third, a metre in from
			// the left edge: clear of a car on the track's middle
			if(keys.find('K') != ss_::npos || keys.find('J') != ss_::npos){
				ground::Loose l;
				int x = hill::U, z = m_hill->slope_z0() +
						m_hill->run / 3;
				l.centre = car::V3((float)x, m_hill->surface(x, z) + 3.0f,
						(float)z);
				l.radius = 1.3f;
				l.kg = 9 * m_ground->soil.stone_kg;
				l.voxels = 9;
				// J: thrown toward the left edge, a metre off, at 3 m/s
				if(keys.find('J') != ss_::npos)
					l.velocity = car::V3(-3, 0, 0);
				m_loose.push_back(l);
			}
			// G: one dropped on the flat bottom pad, 2 m in from the left
			// edge, where it cannot roll off: it comes to rest
			if(keys.find('G') != ss_::npos){
				ground::Loose l;
				int x = 2 * hill::U, z = hill::Hill::PAD / 2;
				l.centre = car::V3((float)x, m_hill->surface(x, z) + 3.0f,
						(float)z);
				l.radius = 1.3f;
				l.kg = 9 * m_ground->soil.stone_kg;
				l.voxels = 9;
				m_loose.push_back(l);
			}
			// E: one dropped on the bottom pad ahead of the car's left
			// wheels, 2.5 m ahead of its centre ([HC_STONE_KICK]'s check)
			if(keys.find('E') != ss_::npos){
				ground::Loose l;
				int x = m_hill->size_x() / 2 - (int)(0.8f * hill::U),
						z = hill::Hill::PAD / 2 + (int)(2.5f * hill::U);
				l.centre = car::V3((float)x, m_hill->surface(x, z) + 3.0f,
						(float)z);
				l.radius = 1.3f;
				l.kg = 9 * m_ground->soil.stone_kg;
				l.voxels = 9;
				m_loose.push_back(l);
			}
			size_t h = keys.find('H');
			int steep = 0, length = 0;
			if(h != ss_::npos && sscanf(keys.c_str() + h + 1, "%d/%d", &steep,
					&length) == 2){
				on_params(network::Packet(0, "hillclimb:params", itos(
						m_params.seed) + " " + itos(steep) + " " + itos(length) +
						" " + itos((int)m_payload) + " 60 172 14 -1 " +
						itos((int)m_params.steep_var_deg) + " " +
						itos(m_params.circuit) + " " + itos((int)m_params.width_m) +
						" " + itos((int)m_params.lane_m) + " " +
						itos(m_params.switchbacks)));
			}
		}
		if(keys.find('Q') != ss_::npos){
			m_server->shutdown(0, "hillclimb: the drive is over");
			m_drive.clear();
			return;
		}
		const bool pilot = keys.find('P') != ss_::npos && m_params.circuit;
		for(auto &kv : m_players){
			if(kv.first != 0 && kv.first < BOT_PEER)
				continue;
			car::Input &in = kv.second.input;
			if(pilot){
				autopilot(kv.second, kv.first == 0 ? 3.0f : 1.4f);
				continue;
			}
			in.accel = keys.find('W') != ss_::npos;
			in.brake = keys.find('S') != ss_::npos;
			in.steer = (keys.find('D') != ss_::npos) -
					(keys.find('A') != ss_::npos);
			for(char c : keys.substr(0, keys.find('H'))){
				if(c >= '1' && c <= '4')
					in.gear = (car::Gear)(car::G1 + (c - '1'));
				if(c == 'R')
					in.gear = car::REVERSE;
			}
		}
	}

	// [HC_CIRCUIT] The check's P: steered at the loop's centre line 3 m
	// ahead of the nearest point on it, in second, held to a speed (m/s)
	// by the pedal and the brake.
	// simplified: no slowing for a turn; at 3.4 m/s it went off the first
	void autopilot(Player &pl, float speed)
	{
		const float U = hill::U;
		const std::vector<hill::Hill::V2> &path = m_hill->path;
		magic::Node *n = pl.body->GetNode();
		const magic::Vector3 p = n->GetWorldPosition();
		const magic::Vector3 fw = n->GetWorldRotation() * magic::Vector3::FORWARD;
		size_t best = 0;
		float best_d = 1e30f, best_t = 0;
		for(size_t i = 0; i < path.size(); i++){
			const hill::Hill::V2 a = path[i], b = path[(i + 1) % path.size()];
			const float dx = b.x - a.x, dz = b.z - a.z, l2 = dx * dx + dz * dz;
			const float t = car::clampf(((p.x_ - a.x) * dx + (p.z_ - a.z) * dz) /
					l2, 0, 1);
			const float ex = a.x + dx * t - p.x_, ez = a.z + dz * t - p.z_;
			if(ex * ex + ez * ez < best_d)
				best = i, best_d = ex * ex + ez * ez, best_t = t;
		}
		// Along the path from there
		float left = 3 * U;
		size_t i = best;
		hill::Hill::V2 at = path[i], b = path[(i + 1) % path.size()];
		at = {at.x + (b.x - at.x) * best_t, at.z + (b.z - at.z) * best_t};
		for(;;){
			const float dx = b.x - at.x, dz = b.z - at.z,
					l = std::sqrt(dx * dx + dz * dz);
			if(l >= left){
				at = {at.x + dx / l * left, at.z + dz / l * left};
				break;
			}
			left -= l;
			at = b;
			i = (i + 1) % path.size();
			b = path[(i + 1) % path.size()];
		}
		const float tx = at.x - p.x_, tz = at.z - p.z_;
		const float angle = std::atan2(fw.z_ * tx - fw.x_ * tz, fw.x_ * tx + fw.z_ * tz);
		const float v = pl.body->GetLinearVelocity().Length() / U;
		car::Input &in = pl.input;
		in.steer = car::clampf(angle / 0.5f, -1, 1);
		in.accel = v < speed;
		in.brake = v > speed + 1;
		in.gear = car::G2;
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_physics)
			return;
		if(m_pending)
			apply_pending();
		for(auto &kv : m_players)
			if(kv.second.reset)
				do_reset(kv.second);
		const float U = hill::U;
		const float dt = 1.0f / SUBSTEPS_HZ;
		// simplified: a long tick is cut to a quarter second of substeps;
		// the car slows with the server rather than jumping
		int n = (int)std::lround(std::fmin(event.dtime, 0.25f) / dt);
		// A check's drive: a 30 Hz tick's substeps whatever the tick took,
		// so the ground's once-a-tick work (stones resting, commits) falls
		// at the same times under load, and a drive goes the same way
		if(!m_drive.empty())
			n = SUBSTEPS_HZ / 30;
		const uint64_t t0 = interface::os::time_us();
		main_context::access(m_server, [&](main_context::Interface *){
			for(int i = 0; i < n; i++){
				if(!m_drive.empty() && m_ground_live)
					drive_step();
				for(auto &kv : m_players)
					step_car(kv.second, dt);
				m_physics->Update(dt);
				if(m_ground_live){
					m_t += dt;
					for(auto &kv : m_players){
						race_step(kv.second, dt);
						edges_step(kv.second);
					}
				}
			}
		});
		if(m_ground_live)
			step_round(n * dt);
		m_step_us += interface::os::time_us() - t0;
		m_step_ticks++;
		ground_tick(n * dt);
		if(!m_drive.empty() && m_t - m_logged >= 1 && m_players.count(0)){
			m_logged = m_t;
			log_car(m_players[0]);
		}
		send_cars();
	}

	// One substep of a player's car: its tyres from its input, the ground
	// under them, the forces on its body
	void step_car(Player &pl, float dt)
	{
		const float U = hill::U;
		// Held on the brake until the hill is made (the ground gives only
		// then, and a run is on the ground that gives), and while observing
		car::Input held;
		held.brake = true;
		held.gear = pl.input.gear;
		pl.car->controls(m_ground_live && !pl.observing ? pl.input : held, dt);
		magic::Node *node = pl.body->GetNode();
		const magic::Vector3 p = node->GetWorldPosition();
		const magic::Quaternion q = node->GetWorldRotation();
		auto v3 = [&](const magic::Vector3 &v){
			return car::V3(v.x_, v.y_, v.z_);
		};
		car::Pose pose;
		pose.pos = v3(p / U);
		pose.right = v3(q * magic::Vector3::RIGHT);
		pose.up = v3(q * magic::Vector3::UP);
		pose.forward = v3(q * magic::Vector3::FORWARD);
		pl.car->step(*m_grid, U, pose, [&](const car::V3 &at){
			// Relative to the body, as ApplyForce's position
			magic::Vector3 v = pl.body->GetVelocityAtPoint(
					magic::Vector3(at.x, at.y, at.z) * U - p);
			return v3(v / U);
		}, dt);
		if(m_ground_live){
			for(int k = 0; k < 4; k++)
				m_ground->wheel(k, pl.car->wheel[k], pl.car->spec, U, dt);
			push_rocks(pl, dt);
			// Made bodies after the flush that takes their voxels out of
			// the world's boxes (ground_tick), not inside them
			for(const ground::Loose &l : m_ground->loose)
				m_loose.push_back(l);
			m_ground->loose.clear();
			// [HC_STONE_WALL] A kick refused, once a second a stone
			for(const ground::Held &h : m_ground->held){
				float &t = m_held_t[std::make_tuple((int)std::floor(h.centre.x),
						(int)std::floor(h.centre.y), (int)std::floor(h.centre.z))];
				if(t > 0 && m_t - t < 1)
					continue;
				t = m_t;
				log_i(MODULE, "hillclimb: stone at %.2f,%.2f,%.2f m held against "
						"tyre %d: its contact %d of %d faces, its centre %.2f "
						"voxels over the sand, a push of %.0f N against %.0f "
						"(-1: in the sand)", h.centre.x / U, h.centre.y / U,
						h.centre.z / U, h.tyre, h.contact, h.faces, h.over,
						h.push, h.need);
			}
			m_ground->held.clear();
		}
		for(const car::Wheel &w : pl.car->wheel){
			if(w.load <= 0)
				continue;
			pl.body->ApplyForce(magic::Vector3(w.force.x, w.force.y,
					w.force.z) * U, magic::Vector3(w.at.x, w.at.y,
					w.at.z) * U - p);
		}
	}

	// [HC_STONE_KICK] A loose stone a tyre is pushing -- its body within
	// the tyre's radius and its own of the hub, ahead along the tyre's
	// travel -- goes ahead at the tyre's speed; the car takes the stone's
	// sliding friction back at the tyre, and as the push starts what
	// bringing it to the tyre's speed took, so a 30 kg stone slows a 2 t
	// car a little and one of its weight stops it. Not that again each
	// substep: a stone wedged in a rut, sent off and stopped every
	// substep, was a wall.
	// simplified: a contact force at the tyre, not a collision shape for it
	void push_rocks(Player &pl, float dt)
	{
		const float U = hill::U;
		const car::Spec &s = pl.car->spec;
		const magic::Vector3 p = pl.body->GetNode()->GetWorldPosition();
		for(Rock &r : m_rocks){
			const magic::Vector3 rp = r.node->GetWorldPosition() / U;
			for(int k = 0; k < 4; k++){
				const car::Wheel &w = pl.car->wheel[k];
				if(w.load <= 0)
					continue;
				const car::V3 hub = w.at + w.normal * s.tyre_r;
				const car::V3 d = car::V3(rp.x_, rp.y_, rp.z_) - hub;
				if(d.length() > s.tyre_r + r.radius / U)
					continue;
				r.touched = true;
				const car::V3 hv(w.vel.x, 0, w.vel.z);
				const float tv = hv.length();
				if(tv < 0.3f)
					continue;
				const car::V3 dir = hv * (1 / tv);
				if(d.dot(dir) <= 0)
					continue;
				const magic::Vector3 md(dir.x, 0, dir.z);
				const magic::Vector3 rv = r.body->GetLinearVelocity() / U;
				// At most the tyre's own speed to give it: one coming at the
				// tyre is stopped and carried, not thrown back
				const float dv = std::fmax(0, tv - std::fmax(0, rv.DotProduct(md)));
				if(dv > 0){
					r.body->SetLinearVelocity((rv + md * dv) * U);
					r.body->Activate();
				}
				const bool starts = m_t - r.pushed_t > 2.5f * dt;
				r.pushed_t = m_t;
				const float back = (starts ? r.kg * dv / dt : 0) +
						m_ground->soil.mu_bed * r.kg * 9.81f;
				pl.body->ApplyForce(-md * back * U,
						magic::Vector3(w.at.x, w.at.y, w.at.z) * U - p);
				if(!r.pushed){
					r.pushed = true;
					log_i(MODULE, "hillclimb: rock %d pushed by %s's tyre %d, "
							"%.0f kg, %.0f N back", r.id, cs(pl.name), k, r.kg,
							back);
				}
			}
		}
	}

	//
	// The ground
	//

	// Once a tick: the ground live when worldgen is done, the changes into
	// the world at most five times a second (each a commit, which remeshes
	// what it touched), the stones that have come to rest back to voxels
	void ground_tick(float dt)
	{
		if(!m_ground_live){
			size_t queued = 1;
			worldgen::access(m_server, m_scene, [&](worldgen::Instance *i){
				queued = i->get_num_sections_queued();
			});
			m_ground_live = queued == 0;
			if(m_ground_live)
				log_i(MODULE, "hillclimb: the ground generated in %.2f s",
						(interface::os::time_us() - m_made_us) / 1e6);
		}
		const float U = hill::U;
		main_context::access(m_server, [&](main_context::Interface *){
			for(size_t i = 0; i < m_rocks.size();){
				Rock &r = m_rocks[i];
				r.age += dt;
				bool still = r.body->GetLinearVelocity().Length() < 0.1f * U &&
						r.body->GetAngularVelocity().Length() < 1.0f;
				magic::Vector3 p = r.node->GetWorldPosition();
				// [HC_STONE_KICK] Not while a tyre or a chassis touches it
				bool touching = r.touched;
				r.touched = false;
				for(auto &kv : m_players){
					const car::Spec &s = kv.second.car->spec;
					const float reach = 0.5f * std::sqrt(s.box_w * s.box_w +
							s.box_h * s.box_h + s.box_l * s.box_l) * U + r.radius;
					touching = touching || (kv.second.body->GetNode()->
							GetWorldPosition() - p).Length() < reach;
				}
				r.still = still && !touching ? r.still + dt : 0;
				// [HC_OPEN_EDGES] Off the voxel area: gone, nothing out
				// there to rest in
				if(!m_hill->over(p.x_, p.z_)){
					log_i(MODULE, "hillclimb: rock %d left the area at %.2f,%.2f m, "
							"removed", r.id, p.x_ / U, p.z_ / U);
					r.node->Remove();
					m_rocks.erase(m_rocks.begin() + i);
					continue;
				}
				// simplified: one that has not stopped in 8 s (rocking) rests
				// where it is, but not under a car ([HC_STONE_KICK]: still
				// 2 s, 1 before)
				if(p.y_ > -U && (touching || (r.still < 2 && r.age < 8))){
					i++;
					continue;
				}
				int n = m_ground->rest(car::V3(p.x_, p.y_, p.z_), r.radius,
						r.voxels);
				log_i(MODULE, "hillclimb: rock %d rests at %.2f,%.2f,%.2f m, "
						"%.2f m from where it came loose, %d voxels", r.id,
						p.x_ / U, p.y_ / U, p.z_ / U, (p - r.from).Length() / U, n);
				r.node->Remove();
				m_rocks.erase(m_rocks.begin() + i);
			}
		});
		m_flush_t += dt;
		if(m_flush_t >= 0.2f){
			m_flush_t = 0;
			if(!m_ground->changes.empty()){
				voxelworld::access(m_server, m_scene,
						[&](voxelworld::Instance *w){
					for(const ground::Change &c : m_ground->changes)
						w->set_voxel(pv::Vector3DInt32(c.x, c.y, c.z),
								VoxelInstance(id_of(c.v)), true);
				});
				m_ground->changes.clear();
				m_flushes++;
			}
			for(const ground::Loose &l : m_loose)
				main_context::access(m_server, [&](main_context::Interface *){
					add_rock(l);
				});
			m_loose.clear();
		}
		send_rocks();
	}

	// A stone's voxels gone from the grid: a sphere of its size thrown
	// along the tread's slide. In main_context's access.
	void add_rock(const ground::Loose &l)
	{
		const float U = hill::U;
		magic::Scene *scene = m_physics->GetScene();
		{
			Rock r;
			r.id = m_next_rock++;
			r.radius = l.radius;
			r.node = scene->CreateChild("Rock", magic::LOCAL);
			r.from = magic::Vector3(l.centre.x, l.centre.y, l.centre.z);
			r.node->SetWorldPosition(r.from);
			r.body = r.node->CreateComponent<magic::RigidBody>(magic::LOCAL);
			r.body->SetMass(l.kg);
			r.body->SetFriction(0.8f);
			r.body->SetRollingFriction(0.05f);
			r.body->SetRestitution(0.1f);
			r.node->CreateComponent<magic::CollisionShape>(magic::LOCAL)->
					SetSphere(2 * l.radius);
			r.body->SetLinearVelocity(magic::Vector3(l.velocity.x,
					l.velocity.y, l.velocity.z) * U);
			r.voxels = l.voxels;
			r.kg = l.kg;
			m_rocks.push_back(r);
			log_i(MODULE, "hillclimb: rock %d loose at %.2f,%.2f,%.2f m, %d "
					"voxels, %.0f kg", r.id, l.centre.x / U, l.centre.y / U,
					l.centre.z / U, l.voxels, l.kg);
			if(l.tyre >= 0)
				log_i(MODULE, "hillclimb: rock %d kicked by tyre %d, %.0f kg, "
						"a push of %.0f N", r.id, l.tyre, l.kg, l.push);
		}
	}

	void clear_rocks()
	{
		m_loose.clear();
		main_context::access(m_server, [&](main_context::Interface *){
			for(Rock &r : m_rocks)
				r.node->Remove();
		});
		m_rocks.clear();
	}

	// "id x y z qw qx qy qz radius" per stone in flight, in voxels, ";"
	// between them; once more empty when the last has come to rest
	void send_rocks()
	{
		if(m_peers.empty() || (m_rocks.empty() && !m_rocks_sent))
			return;
		ss_ data;
		for(const Rock &r : m_rocks){
			magic::Vector3 p = r.node->GetWorldPosition();
			magic::Quaternion q = r.node->GetWorldRotation();
			char buf[160];
			snprintf(buf, sizeof buf, "%s%d %.3f %.3f %.3f %.4f %.4f %.4f %.4f "
					"%.3f", data.empty() ? "" : ";", r.id, p.x_, p.y_, p.z_, q.w_,
					q.x_, q.y_, q.z_, r.radius);
			data += buf;
		}
		m_rocks_sent = !m_rocks.empty();
		network::access(m_server, [&](network::Interface *i){
			for(auto peer : m_peers)
				i->send(peer, "hillclimb:rocks", data);
		});
	}

	//
	// The time trial
	//

	// A run starts on its first W, not while observing; the round's clock
	// with the first run on the hill
	void race_step(Player &pl, float dt)
	{
		if(pl.race == READY && pl.input.accel && !pl.observing){
			pl.race = RUNNING;
			pl.race_t = 0;
			pl.fin_at = m_hill_finished;
			pl.unfin_at = m_hill_unfinished;
			pl.lap = hill::Hill::Lap();
			pl.lap_t = 0;
			if(m_interval > 0 && m_round == R_WAITING){
				m_round = R_RUNNING;
				m_round_t = 0;
				log_i(MODULE, "hillclimb: round: %s's drive starts the clock "
						"(%.0f s)", cs(pl.name), m_interval);
			}
		}
		if(pl.race != RUNNING)
			return;
		pl.race_t += dt;
		magic::Node *n = pl.body->GetNode();
		if(m_params.circuit){
			// [HC_CIRCUIT] The car's middle round the loop
			const magic::Vector3 p = n->GetWorldPosition();
			const size_t was = pl.lap.next;
			if(m_hill->lap_step(pl.lap, p.x_, p.z_)){
				checkpoint(pl);
				pl.lap_t = m_round_t;
				log_i(MODULE, "hillclimb: %s's lap %d at %.2f s of the round",
						cs(pl.name), pl.lap.laps, pl.lap_t);
			} else if(pl.lap.next != was){
				checkpoint(pl);
				log_i(MODULE, "hillclimb: %s passed turn %zu of %zu", cs(pl.name),
						was, m_hill->path.size() - 1);
			}
			return;
		}
		// The rear axle over the top pad's first voxel
		const hill::Hill &h = *m_hill;
		magic::Vector3 rear = n->GetWorldPosition() + n->GetWorldRotation() *
				magic::Vector3(0, 0, -pl.car->spec.wheelbase / 2 * hill::U);
		const int mark = (int)std::floor((n->GetWorldPosition().z_ -
				h.slope_z0()) / (10 * hill::U));
		if(mark > pl.mark){
			if(pl.mark >= 0)
				log_i(MODULE, "hillclimb: %s passed %d m", cs(pl.name), mark * 10);
			pl.mark = mark;
			checkpoint(pl);
		}
		if(rear.z_ >= h.top_z0() - 0.5f)
			finish(pl);
	}

	// The ranking's keys: the parameter set and the payload, then the time
	// in milliseconds, zero-padded so the store's order is the ranking's.
	// v2 ([HC_PITS_ROCKS], [HC_POWER]): a hill with pits and rocks, a car
	// of twice the power. v3 ([HC_MULTIPLAYER]): an entry's value is
	// "name\tdate\tfinished\tunfinished", the runs ended on the hill before
	// it started. v4 ([HC_OPEN_EDGES]): the track 10 m wide, no banks. v5
	// ([HC_STEEP_NOISE]): the steepness's variance in the key. v6
	// ([HC_SCORES]): no seed in it, the race's kind; the seed in the entry,
	// "name\tdate\tfinished\tunfinished\tseed". The times before are kept
	// under the old keys, shown on the High scores page; v4's and v5's read
	// into v6 (scores.h). v7 ([HC_WET_SAND]): the sand in two layers, their
	// knobs in the key.
	// [HC_CIRCUIT] A circuit's: every parameter that shapes it and the
	// round's interval; its keys then the laps, most first, and the round's
	// clock at the last lap
	ss_ ranking_prefix() const
	{
		char buf[192];
		if(m_params.circuit){
			snprintf(buf, sizeof buf, "%s/circuit/steep%d/var%d/length%d/width%d/"
					"lane%d/switch%d/round%d/sand/%spayload%d/", SCORES_VERSION,
					(int)m_params.steep_deg, (int)m_params.steep_var_deg,
					(int)m_params.length_m, (int)m_params.width_m,
					(int)m_params.lane_m, m_params.switchbacks, (int)m_interval,
					cs(m_knobs.key()), (int)m_payload);
			return buf;
		}
		snprintf(buf, sizeof buf, "%s/straight/steep%d/var%d/length%d/sand/"
				"%spayload%d/", SCORES_VERSION, (int)m_params.steep_deg,
				(int)m_params.steep_var_deg, (int)m_params.length_m,
				cs(m_knobs.key()), (int)m_payload);
		return buf;
	}

	struct Entry
	{
		float t;
		ss_ name, date;
		int fin = 0, unfin = 0, laps = -1;
	};
	sv_<Entry> ranking(size_t max)
	{
		sv_<Entry> out;
		if(!m_save)
			return out;
		const ss_ prefix = ranking_prefix();
		storage::Store *st = m_save->store("times");
		for(const ss_ &key : st->list(prefix)){
			if(out.size() >= max)
				break;
			Entry e;
			const char *k = key.c_str() + prefix.size();
			if(m_params.circuit){
				e.laps = 999999 - atoi(k);
				k = strchr(k, '/') ? strchr(k, '/') + 1 : k;
			}
			e.t = atoi(k) / 1000.0f;
			ss_ v;
			st->get(key, v);
			std::istringstream is(v);
			std::getline(is, e.name, '\t');
			std::getline(is, e.date, '\t');
			is >> e.fin >> e.unfin;
			out.push_back(e);
		}
		return out;
	}

	static ss_ seconds(float t)
	{
		char buf[32];
		snprintf(buf, sizeof buf, "%.3f", t);
		return buf;
	}

	// A run over: the top reached, or a circuit's round ended with its laps
	void finish(Player &pl)
	{
		pl.race = FINISHED;
		const int ms = (int)std::lround((m_params.circuit ? pl.lap_t :
				pl.race_t) * 1000);
		pl.last_rank = -1;
		if(m_save && (!m_params.circuit || pl.lap.laps > 0)){
			char key[64];
			if(m_params.circuit)
				snprintf(key, sizeof key, "%06d/%09d/%lld", 999999 - pl.lap.laps,
						ms, (long long)interface::os::time_us());
			else
				snprintf(key, sizeof key, "%09d/%lld", ms,
						(long long)interface::os::time_us());
			char date[16];
			const std::time_t now = std::time(nullptr);
			std::strftime(date, sizeof date, "%Y-%m-%d", std::gmtime(&now));
			const ss_ prefix = ranking_prefix();
			m_save->store("times")->set(prefix + key, pl.name+"\t"+date+"\t"+
					itos(pl.fin_at)+"\t"+itos(pl.unfin_at)+"\t"+itos(m_params.seed));
			const sv_<ss_> keys = m_save->store("times")->list(prefix);
			for(size_t i = 0; i < keys.size(); i++)
				if(keys[i] == prefix + key)
					pl.last_rank = (int)i;
		}
		m_hill_finished++;
		ss_ list;
		for(const Entry &e : ranking(10))
			list += " " + seconds(e.t);
		log_i(MODULE, "hillclimb: finish %.3f s on %s, rank %d; the ranking:%s",
				ms / 1000.0f, cs(ranking_prefix()), pl.last_rank, cs(list));
		log_i(MODULE, "hillclimb: %s finished in %.3f s after %d runs (%d "
				"finished), %d laps", cs(pl.name), ms / 1000.0f, pl.fin_at +
				pl.unfin_at, pl.fin_at, pl.lap.laps);
		for(size_t peer : m_peers)
			send_ranking(peer);
	}

	// The best ten under the hill and payload: the first line where the
	// peer's last finish is among all of them (-1 if none), then one each,
	// "time laps finished unfinished date name", laps -1 on the straight hill
	void send_ranking(size_t peer)
	{
		auto it = m_players.find(peer);
		ss_ data = itos(it != m_players.end() ? it->second.last_rank : -1);
		for(const Entry &e : ranking(10))
			data += "\n" + seconds(e.t) + " " + itos(e.laps) + " " + itos(e.fin) + " " +
					itos(e.unfin) + " " + (e.date.empty() ? "-" : e.date) +
					" " + (e.name.empty() ? "?" : e.name);
		network::send(m_server, peer, "hillclimb:ranking", data);
	}

	// Each run on the hill as it was made, for one car
	// Done at the next tick's start (do_reset), outside any module's
	// access
	void reset_race(Player &pl)
	{
		if(pl.race == RUNNING)
			m_hill_unfinished++;
		// In the extra time a run ended is an observer's
		if(m_round == R_EXTRA)
			pl.observing = true;
		pl.race = READY;
		pl.race_t = 0;
		pl.last_rank = -1;
		pl.reset = true;
		pl.keep_ground = false;
	}
	void do_reset(Player &pl)
	{
		pl.reset = false;
		// One car: the hill as it was made again, as before there were
		// more; with more the ground is everyone's ([HC_MULTIPLAYER] 1).
		// Not when only the car goes back ([HC_RESET_KEEP_GROUND])
		const bool keep = pl.keep_ground;
		pl.keep_ground = false;
		if(m_players.size() == 1 && !keep){
			if(m_ground && m_ground->changed())
				m_ground->restore();
			clear_rocks();
		}
		main_context::access(m_server, [&](main_context::Interface *){
			place_car(pl);
		});
		if(keep){
			const magic::Vector3 q = pl.body->GetNode()->GetWorldPosition() /
					hill::U;
			log_i(MODULE, "hillclimb: %s back to the start at %.2f,%.2f m, the "
					"ground kept: %d laps, %zu voxels changed", cs(pl.name), q.x_,
					q.z_, pl.lap.laps, m_ground ? m_ground->undo.size() : 0);
		}
	}

	//
	// [HC_MULTIPLAYER] The rounds
	//

	void step_round(float dt)
	{
		if(m_interval <= 0)
			return;
		m_round_sent += dt;
		if(m_round_sent >= 0.5f){
			m_round_sent = 0;
			send_round();
		}
		if(m_round == R_WAITING)
			return;
		m_round_t += dt;
		bool driving = false;
		for(auto &kv : m_players)
			driving = driving || kv.second.race == RUNNING;
		if(m_round == R_RUNNING && m_round_t >= m_interval && m_params.circuit){
			// [HC_CIRCUIT] No extra time: the laps are the round's
			end_round();
		} else if(m_round == R_RUNNING && m_round_t >= m_interval){
			m_round = R_EXTRA;
			m_round_t = 0;
			for(auto &kv : m_players)
				if(kv.second.race != RUNNING)
					kv.second.observing = true;
			log_i(MODULE, "hillclimb: round: the extra time");
			send_round();
		} else if(m_round == R_EXTRA){
			for(auto &kv : m_players)
				if(kv.second.race != RUNNING)
					kv.second.observing = true;
			if(m_round_t >= m_interval || !driving)
				end_round();
		} else if(m_round == R_RESULTS && m_round_t >= 5){
			// The hill anew: as it was made, the seed kept
			m_pending_params = m_params;
			m_pending_payload = m_payload;
			m_pending_knobs = m_knobs;
			m_pending_look[0] = m_latitude;
			m_pending_look[1] = m_day;
			m_pending_look[2] = m_time;
			m_pending = true;
			m_round = R_WAITING;
			m_round_t = 0;
			send_round();
		}
	}

	// The runs still going have no time; the results to everyone
	void end_round()
	{
		if(m_params.circuit){
			end_circuit_round();
			return;
		}
		ss_ results;
		sv_<std::pair<float, ss_>> done;
		for(auto &kv : m_players){
			Player &pl = kv.second;
			if(pl.race == RUNNING){
				pl.race = OUT;
				m_hill_unfinished++;
				results += "\n- " + pl.name;
			} else if(pl.race == FINISHED){
				done.push_back(std::make_pair(pl.race_t, pl.name));
			}
		}
		std::sort(done.begin(), done.end());
		ss_ head;
		for(const auto &d : done)
			head += "\n" + seconds(d.first) + " " + d.second;
		results = head + results;
		log_i(MODULE, "hillclimb: round over:%s", cs(ss_(results.empty() ?
				" no runs" : results)));
		m_round = R_RESULTS;
		m_round_t = 0;
		for(size_t peer : m_peers)
			network::send(m_server, peer, "hillclimb:results", results);
		send_round();
	}

	// [HC_CIRCUIT] Every run's laps kept, the results by them: a line
	// each, "<laps> laps <the round's clock at the last> <name>", most
	// first, ties by the earlier last lap
	void end_circuit_round()
	{
		sv_<Player*> ran;
		for(auto &kv : m_players){
			Player &pl = kv.second;
			if(pl.race == RUNNING){
				finish(pl);
				ran.push_back(&pl);
			}
			pl.observing = true;
		}
		std::sort(ran.begin(), ran.end(), [](Player *a, Player *b){
			return a->lap.laps != b->lap.laps ? a->lap.laps > b->lap.laps :
					a->lap_t < b->lap_t;
		});
		ss_ results;
		for(Player *pl : ran)
			results += "\n" + itos(pl->lap.laps) + " laps " + seconds(pl->lap_t) +
					" " + pl->name;
		log_i(MODULE, "hillclimb: round over:%s", cs(ss_(results.empty() ?
				" no runs" : results)));
		m_round = R_RESULTS;
		m_round_t = 0;
		for(size_t peer : m_peers)
			network::send(m_server, peer, "hillclimb:results", results);
		send_round();
	}

	// "phase left": 0 no rounds, 1 waiting for a drive, 2 the round, 3
	// its extra time, 4 the results; the seconds left of the phase
	void send_round()
	{
		const int phase = m_interval <= 0 ? 0 : 1 + (int)m_round;
		const float left = m_round == R_RESULTS ? 5 - m_round_t :
				m_round == R_WAITING ? m_interval : m_interval - m_round_t;
		char buf[64];
		snprintf(buf, sizeof buf, "%d %.1f", phase, std::max(0.0f, left));
		for(size_t peer : m_peers)
			network::send(m_server, peer, "hillclimb:round", buf);
	}

	//
	// The deepest the track is under the hill's generated surface, in
	// voxels: the ruts dug and sunk
	int rut() const
	{
		int deepest = 0;
		for(int z = 0; z < m_hill->size_z(); z++)
		for(int x = 0; x < m_hill->size_x(); x++)
			deepest = std::max(deepest, m_hill->surface(x, z) - m_grid->top(x, z));
		return deepest;
	}

	// The check reads these: the centre of mass in metres, the speed, the
	// shaft, each spring's compression and whether its tyre slides; and
	// the cars there are, whose step tick_us is
	void log_car(Player &pl)
	{
		const float U = hill::U;
		magic::Node *n = pl.body->GetNode();
		magic::Vector3 p = n->GetWorldPosition() / U;
		magic::Vector3 v = pl.body->GetLinearVelocity() / U;
		const car::Car &c = *pl.car;
		log_i(MODULE, "hillclimb: car t=%.1f pos=%.3f,%.3f,%.3f v=%.2f "
				"shaft=%.3f springs=%.3f,%.3f,%.3f,%.3f slip=%d%d%d%d gear=%d "
				"tick_us=%d race=%d/%.2f ground=%d/%d/%d/%d rocks=%d rut=%d "
				"commits=%d cars=%zu",
				m_t, p.x_, p.y_, p.z_, v.Length(), c.shaft / (2 * car::PI),
				c.wheel[0].spring, c.wheel[1].spring, c.wheel[2].spring,
				c.wheel[3].spring, c.wheel[0].slipping, c.wheel[1].slipping,
				c.wheel[2].slipping, c.wheel[3].slipping, (int)c.gear,
				(int)(m_step_us / std::max(1, m_step_ticks)), (int)pl.race,
				pl.race_t, m_ground->dug, m_ground->sunk, m_ground->slid,
				m_ground->freed, (int)m_rocks.size(), rut(), m_flushes,
				m_players.size());
		m_flushes = 0;
		m_step_us = 0;
		m_step_ticks = 0;
	}

	// What the client draws, each car: its id and its player's name, then
	// in voxels the chassis' pose, the wheels' spin and steering, each
	// spring's compression; the shaft in rev/s, the gear, the race (0
	// ready, 1 running, 2 finished, 3 the hill still being made, 4 out of
	// time), its time, whether the player observes and its laps
	void send_cars()
	{
		if(m_peers.empty())
			return;
		const float U = hill::U;
		sv_<ss_> lines;
		for(auto &kv : m_players){
			const Player &pl = kv.second;
			magic::Node *n = pl.body->GetNode();
			magic::Vector3 p = n->GetWorldPosition();
			magic::Quaternion q = n->GetWorldRotation();
			const car::Car &c = *pl.car;
			char buf[640];
			snprintf(buf, sizeof buf, "%d %s %.3f %.3f %.3f %.5f %.5f %.5f %.5f "
					"%.4f %.4f %.4f %.3f %.3f %.3f %.3f %.3f %d %d %.3f %d %d", pl.id,
					cs(pl.name), p.x_, p.y_, p.z_, q.w_, q.x_, q.y_, q.z_, c.spin,
					c.wheel[0].steer, c.wheel[1].steer, c.wheel[0].spring * U,
					c.wheel[1].spring * U, c.wheel[2].spring * U,
					c.wheel[3].spring * U, c.shaft / (2 * car::PI), (int)c.gear,
					m_ground_live ? (int)pl.race == OUT ? 4 : (int)pl.race : 3,
					pl.race_t, pl.observing ? 1 : 0, pl.lap.laps);
			lines.push_back(buf);
		}
		network::access(m_server, [&](network::Interface *i){
			for(auto peer : m_peers)
				for(const ss_ &l : lines)
					i->send(peer, "hillclimb:car", l);
		});
	}

	// "accel brake left right gear reset [steer]", each a number, to the
	// sender's own car; steer -100..100 ([HC_TOUCH]) over left and right
	void on_input(const network::Packet &packet)
	{
		auto it = m_players.find(packet.sender);
		if(it == m_players.end())
			return;
		Player &pl = it->second;
		std::istringstream is(packet.data);
		int a = 0, b = 0, l = 0, r = 0, g = 1, reset = 0;
		if(!(is >> a >> b >> l >> r >> g >> reset) || g < car::REVERSE ||
				g >= car::GEARS)
			return;
		pl.input.accel = a != 0;
		pl.input.brake = b != 0;
		int steer = 0;
		pl.input.steer = (is >> steer) ? car::clampf(steer / 100.0f, -1, 1) :
				(r != 0) - (l != 0);
		pl.input.gear = (car::Gear)g;
		if(reset)
			backspace(pl);
	}
	// [HC_CIRCUIT] A circuit's run is the round's: the car back at the
	// start with its laps, the lap under way from its first turn, and
	// ([HC_RESET_KEEP_GROUND]) the ground as it is: a way to get unstuck.
	// Otherwise a new run, on the hill as it was made.
	void backspace(Player &pl)
	{
		if(pl.reset)
			return;
		if(m_params.circuit && pl.race == RUNNING){
			pl.lap.next = 1;
			pl.lap.at = false;
			pl.keep_ground = true;
			pl.reset = true;
		} else {
			reset_race(pl);
		}
	}

	// [HC_MULTIPLAYER] 2: who picks the hill: anyone in a local game, an
	// admin on a public server (the check's drive, peer 0, too)
	bool may_pick(size_t peer)
	{
		if(!m_public || peer == 0)
			return true;
		bool ok = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			ok = i->is_local(peer) ||
					i->level(i->name_of(peer)) >= accounts::LV_ADMIN;
		});
		return ok;
	}

	// "seed steep length payload latitude day hour [interval [var [circuit
	// width lane switchbacks [bearing dig power grip stones loose wet]]]]" from the menu, held to what a player may
	// pick; made when worldgen is idle (on_tick). On a public server the
	// seed is the round's: kept. [HC_CIRCUIT] A circuit's rounds never
	// "never"; its lanes at most half its width.
	void on_params(const network::Packet &packet)
	{
		if(!may_pick(packet.sender)){
			auto it = m_players.find(packet.sender);
			log_w(MODULE, "hillclimb: params from %s refused: not an admin",
					cs(it != m_players.end() ? it->second.name :
					"peer "+itos(packet.sender)));
			return;
		}
		std::istringstream is(packet.data);
		long long seed = 0;
		int steep = 0, length = 0, payload = -1, interval = -1,
				var = (int)m_params.steep_var_deg;
		float lat = 0, day = 0, hour = 0;
		if(!(is >> seed >> steep >> length >> payload >> lat >> day >> hour))
			return;
		int circuit = m_params.circuit, width = (int)m_params.width_m,
				lane = (int)m_params.lane_m, sw = m_params.switchbacks;
		Knobs knobs = m_knobs;
		if(is >> interval && is >> var && is >> circuit >> width >> lane >> sw){
			Knobs k;
			bool all = true;
			for(int i = 0; i < N_KNOBS && all; i++)
				all = !!(is >> k.v[i]);
			if(all)
				knobs = k;
		}
		for(int i = 0; i < N_KNOBS; i++)
			if(knobs.v[i] < KNOBS[i].min || knobs.v[i] > KNOBS[i].max)
				return;
		if(circuit && interval == -1 && m_interval <= 0)
			interval = 600;
		if((circuit != 0 && circuit != 1) || width < WIDTH_MIN ||
				width > WIDTH_MAX || lane < LANE_MIN || lane > LANE_MAX ||
				lane * 2 > width || sw < 0 || sw > 100 || (circuit && interval == 0))
			return;
		bool payload_ok = false, interval_ok = interval == -1;
		for(int w : PAYLOADS)
			payload_ok = payload_ok || w == payload;
		for(int w : INTERVALS)
			interval_ok = interval_ok || w == interval;
		if(seed < 1 || seed > 999999 || steep < STEEP_MIN || steep > STEEP_MAX ||
				var < VAR_MIN || var > VAR_MAX ||
				length < LENGTH_MIN || length > LENGTH_MAX || !payload_ok ||
				!interval_ok || !(lat >= -80 && lat <= 80) ||
				!(day >= 1 && day <= 365) || !(hour >= 0 && hour <= 24))
			return;
		if(interval >= 0 && interval != (int)m_interval){
			m_interval = (float)interval;
			if(m_save)
				m_save->store("settings")->set("interval", itos(interval));
			m_round = R_WAITING;
			m_round_t = 0;
			log_i(MODULE, "hillclimb: rounds every %d s", interval);
			send_round();
		}
		m_pending_params.seed = m_public && packet.sender != 0 ?
				m_params.seed : (uint32_t)seed;
		m_pending_params.steep_deg = (float)steep;
		m_pending_params.steep_var_deg = (float)var;
		m_pending_params.length_m = (float)length;
		m_pending_params.features = m_params.features;
		m_pending_params.circuit = circuit;
		m_pending_params.width_m = (float)width;
		m_pending_params.lane_m = (float)lane;
		m_pending_params.switchbacks = sw;
		m_pending_payload = (float)payload;
		m_pending_knobs = knobs;
		m_pending_look[0] = lat;
		m_pending_look[1] = day;
		m_pending_look[2] = hour;
		m_pending = true;
	}

	void apply_pending()
	{
		size_t queued = 0;
		worldgen::access(m_server, m_scene, [&](worldgen::Instance *i){
			queued = i->get_num_sections_queued();
		});
		// A section still being made from the old grid would come back
		// with the old hill in it
		if(queued > 0)
			return;
		m_pending = false;
		const hill::Params &np = m_pending_params;
		bool hill_changed = np.seed != m_params.seed ||
				np.steep_deg != m_params.steep_deg ||
				np.steep_var_deg != m_params.steep_var_deg ||
				np.length_m != m_params.length_m || np.circuit != m_params.circuit ||
				np.width_m != m_params.width_m || np.lane_m != m_params.lane_m ||
				np.switchbacks != m_params.switchbacks ||
				m_pending_knobs.v[KNOB_LOOSE] != m_knobs.v[KNOB_LOOSE];
		m_params = np;
		m_latitude = m_pending_look[0];
		m_day = m_pending_look[1];
		m_time = m_pending_look[2];
		m_payload = m_pending_payload;
		m_knobs = m_pending_knobs;
		if(hill_changed){
			make_hill();
		} else {
			// The same hill as it was made: the ground smoothed, the stones
			// gone (a round's end, [HC_SCORES])
			if(m_ground && m_ground->changed())
				m_ground->restore();
			clear_rocks();
			m_knobs.soil(m_ground->soil);
			log_i(MODULE, "hillclimb: the hill as it was made, seed %u; %s",
					m_params.seed, cs(m_knobs.text()));
		}
		// Every car at the start, nobody observing, the round waiting
		for(auto &kv : m_players){
			Player &pl = kv.second;
			main_context::access(m_server, [&](main_context::Interface *){
				pl.car->payload = m_payload;
				m_knobs.spec(pl.car->spec);
				pl.body->SetMass(pl.car->mass());
			});
			reset_race(pl);
			pl.observing = false;
		}
		// A fresh hill counts its own runs, the ones cut short above not
		m_hill_finished = m_hill_unfinished = 0;
		m_round = R_WAITING;
		m_round_t = 0;
		for(size_t peer : m_peers){
			send_hill(peer);
			send_ranking(peer);
		}
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		m_peers.erase(old_client.info.id);
		m_joining.erase(old_client.info.id);
		remove_player(old_client.info.id);
	}

	// What the client draws by: the hill's size and where the car starts,
	// in voxels, the place and the hour, and the menu's picks: the seed,
	// the steepness, the length and the payload; whether this peer may
	// pick, the rounds' interval in seconds and the steepness's variance;
	// [HC_CIRCUIT] whether a circuit, its width, lanes and switchbacks;
	// [HC_SOFT_GROUND] the knobs
	ss_ hill_packet(size_t peer)
	{
		const hill::Hill &h = *m_hill;
		float sx, sz, yaw;
		h.start(sx, sz, yaw);
		char buf[256];
		snprintf(buf, sizeof buf, "%d %d %d %d %d %d %g %g %g %u %d %d %d %d %d %d "
				"%d %d %d %d", h.size_x(), h.size_y(), h.size_z(), (int)sx,
				hill::Hill::BASE + 1, (int)sz, m_latitude, m_day,
				m_time, m_params.seed, (int)m_params.steep_deg,
				(int)m_params.length_m, (int)m_payload, may_pick(peer) ? 1 : 0,
				(int)m_interval, (int)m_params.steep_var_deg, m_params.circuit ? 1 : 0,
				(int)m_params.width_m, (int)m_params.lane_m, m_params.switchbacks);
		ss_ out = buf;
		for(int i = 0; i < N_KNOBS; i++)
			out += " " + itos(m_knobs.v[i]);
		return out;
	}
	// The fences (hill.h): a line of posts each, 2 m apart at most, on the
	// ground, "x y z" in voxels each, ";" between the lines
	static ss_ fences_packet(const hill::Hill &h)
	{
		std::ostringstream os;
		char buf[64];
		for(const hill::Hill::Fence &f : h.fences){
			const float len = std::fabs(f.x1 - f.x0) + std::fabs(f.z1 - f.z0);
			const int n = std::max(1, (int)std::ceil(len / (2 * hill::U)));
			if(os.tellp() > 0)
				os << ";";
			for(int i = 0; i <= n; i++){
				const float x = f.x0 + (f.x1 - f.x0) * i / n,
						z = f.z0 + (f.z1 - f.z0) * i / n;
				const int cx = std::min(h.size_x() - 1, std::max(0, (int)std::lround(x))),
						cz = std::min(h.size_z() - 1, std::max(0, (int)std::lround(z)));
				snprintf(buf, sizeof buf, "%s%.1f %.1f %.1f", i ? " " : "", x,
						h.surface(cx, cz) + 0.5f, z);
				os << buf;
			}
		}
		return os.str();
	}

	// [HC_OPEN_EDGES] The ground outside for the client to draw, from the
	// outside() the cars are put back by: "nx nz", nx lines across x and
	// nz along z, then the heights row by row along z, all in voxels. Lines
	// at the area's edges (-0.5 and size - 0.5), 2 m apart inside it and
	// out to 20 m, 4 m to 60 m, 8 m to 150 m. [HC_HOLLOW_MIDDLE]: inside,
	// a line on every section's edge too, and at the end "n sx sz ...",
	// the section columns left out, which the client draws as land
	static ss_ outside_packet(const hill::Hill &h)
	{
		const float M = hill::U;
		sv_<float> out;
		for(float d = 2 * M; d <= 150 * M + 0.01f;
				d += d < 20 * M ? 2 * M : d < 60 * M ? 4 * M : 8 * M)
			out.push_back(d);
		auto lines = [&](float e0, float e1){
			sv_<float> v;
			for(size_t i = out.size(); i-- > 0;)
				v.push_back(e0 - out[i]);
			const int n = std::max(1, (int)std::lround((e1 - e0) / (2 * M)));
			sv_<float> in;
			for(int i = 0; i <= n; i++)
				in.push_back(e0 + (e1 - e0) * i / n);
			const int S = hill::Hill::SECTION;
			for(int k = 1; k * S - 0.5f < e1; k++)
				in.push_back(k * S - 0.5f);
			std::sort(in.begin(), in.end());
			in.erase(std::unique(in.begin(), in.end()), in.end());
			v.insert(v.end(), in.begin(), in.end());
			for(float d : out)
				v.push_back(e1 + d);
			return v;
		};
		const sv_<float> xs = lines(-0.5f, h.size_x() - 0.5f);
		const sv_<float> zs = lines(-0.5f, h.size_z() - 0.5f);
		std::ostringstream os;
		os << xs.size() << " " << zs.size();
		char buf[32];
		for(float x : xs){ snprintf(buf, sizeof buf, " %.2f", x); os << buf; }
		for(float z : zs){ snprintf(buf, sizeof buf, " %.2f", z); os << buf; }
		for(float z : zs)
		for(float x : xs){
			snprintf(buf, sizeof buf, " %.1f", h.outside(x, z));
			os << buf;
		}
		const int S = hill::Hill::SECTION;
		std::ostringstream hs;
		int n = 0;
		for(int z = 0; z <= (h.size_z() - 1) / S; z++)
		for(int x = 0; x <= (h.size_x() - 1) / S; x++)
			if(h.hollow_section(x, z))
				hs << " " << x << " " << z, n++;
		os << " " << n << hs.str();
		return os.str();
	}
	void send_hill(size_t peer)
	{
		network::send(m_server, peer, "hillclimb:hill", hill_packet(peer));
		network::send(m_server, peer, "hillclimb:outside", m_outside);
		network::send(m_server, peer, "hillclimb:fences", m_fences);
	}

	// [HC_MULTIPLAYER] 6: on a public server, the join through accounts
	// first (main/join.lua); in a local game, in at once
	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		const size_t peer = event.recipient;
		m_peers.insert(peer);
		send_hill(peer);
		replicate::access(m_server, [&](replicate::Interface *i){
			i->assign_scene_to_peer(m_scene, peer);
		});
		ss_ name;
		accounts::access(m_server, [&](accounts::Interface *i){
			name = i->name_of(peer);
		});
		if(m_public && name.empty()){
			m_joining.insert(peer);
			network::send(m_server, peer, "core:run_script",
					"buildat.run_script_file(\"main/join.lua\")");
			return;
		}
		// A peer without an account is "client<peer>", which accounts keeps
		// from new accounts (skeldat's rule)
		add_player(peer, name.empty() ? "client"+itos(peer) : name);
	}

	void on_login(const accounts::Login &login)
	{
		if(m_joining.erase(login.peer))
			add_player(login.peer, login.name);
	}

#include "scores.h"
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
