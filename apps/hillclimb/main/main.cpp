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
// The time trial: the clock starts on the first W after the car is put
// at the start and stops when its rear axle crosses the top pad's line;
// the time is kept in the save "ranking" under the hill's parameters and
// the payload. The client's menu picks them (hillclimb:params); the hill
// is then made again in the same world. The parameters the server starts
// with: BUILDAT_HILLCLIMB_SEED, _STEEP (degrees), _LENGTH (the slope's
// run, m), _LATITUDE (degrees), _DAY (1..365), _TIME (hours, solar) and
// _PAYLOAD (kg).
//
// For the check, with no client: BUILDAT_HILLCLIMB_DRIVE, steps of
// "<seconds>:<keys>" from the car's start, each held until the next --
// W accelerator, S brake, A and D steering, 1 to 4 and R the gear, B the
// car back at the start, H<steep>/<length> another hill, K a stone dropped
// on the slope, Q the server's end -- logging the car each second; and _START, "x z yaw" (m, m,
// degrees) for a start other than the bottom pad's.
#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "main_context/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "storage/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/os.h"
#include "hill.h"
#include "car.h"
#include "ground.h"
#include <PhysicsWorld.h>
#include <BulletDynamics/Dynamics/btDiscreteDynamicsWorld.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <Scene.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <STB/stb_image_write.h>
#include <cstdlib>
#include <sstream>
#include <set>
#include <memory>
#include <mutex>
#define MODULE "main"

namespace pv = PolyVox;
namespace magic = Urho3D;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelVolume;
using main_context::SceneReference;

namespace main
{

// The registry's ids are hill::Voxel's plus one: 0 is "not generated"
static uint32_t id_of(hill::Voxel v){ return (uint32_t)v + 1; }

static float env_or(const char *name, float def)
{
	const char *v = getenv(name);
	return v && v[0] ? (float)atof(v) : def;
}

// What a player may pick ([HILLCLIMB] 3), which the server holds a
// client's pick to; the world's region is the largest of these hills
static const int STEEP_MIN = 5, STEEP_MAX = 40;
static const int LENGTH_MIN = 20, LENGTH_MAX = 60;
static const int PAYLOADS[] = {0, 500, 1000, 2000};

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
		// The light is the generator's to write (voxelworld's
		// set_light_maintained): every air voxel here is open sky, the hill
		// having no overhang, and the rest is dark. Left to the flood, a
		// section generated before the one above it stayed dark.
		const uint32_t sky = interface::VoxelFormat::blocks().light_sky.mask();
		for(int z = lc.getZ(); z <= uc.getZ(); z++)
		for(int y = lc.getY(); y <= uc.getY(); y++)
		for(int x = lc.getX(); x <= uc.getX(); x++){
			const hill::Voxel v = m_hill.at(x, y, z);
			uint32_t word = id_of(v);
			if(v == hill::AIR)
				interface::VoxelFormat::blocks().light_sky.set(word, sky);
			volume.setVoxelAt(pv::Vector3DInt32(x, y, z), VoxelInstance(word));
		}
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
	float m_latitude = 60, m_day = 172, m_time = 14;
	up_<hill::Hill> m_hill;
	std::shared_ptr<ground::Grid> m_grid;
	Worldgen *m_worldgen = nullptr; // worldgen's to delete
	// The ground that gives ([HILLCLIMB] 4), live once worldgen has made
	// every section: its workers read the grid until then
	up_<ground::Ground> m_ground;
	bool m_ground_live = false;
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
	};
	sv_<Rock> m_rocks;
	sv_<ground::Loose> m_loose;
	int m_next_rock = 1;
	bool m_rocks_sent = false;
	// A pick from the menu, made when worldgen has nothing queued
	bool m_pending = false;
	hill::Params m_pending_params;
	float m_pending_look[3] = {0, 0, 0};
	float m_pending_payload = 0;
	// The time trial
	enum Race { READY, RUNNING, FINISHED } m_race = READY;
	float m_race_t = 0;
	storage::Save *m_save = nullptr;
	int m_last_rank = -1;
	bool m_reset = false;
	// The car: car.h's model and its chassis' body
	up_<car::Car> m_car;
	magic::RigidBody *m_body = nullptr;
	magic::PhysicsWorld *m_physics = nullptr;
	car::Input m_input;
	float m_payload = 0;
	float m_start_x = 0, m_start_z = 0, m_start_yaw = 0; // m, m, degrees
	bool m_start_set = false;
	std::set<network::PeerInfo::Id> m_peers;
	// The check's drive (BUILDAT_HILLCLIMB_DRIVE)
	sv_<std::pair<float, ss_>> m_drive;
	int m_drive_step = -1;
	float m_t = 0, m_logged = -1;
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
		m_params.seed = (uint32_t)env_or("BUILDAT_HILLCLIMB_SEED", 1);
		m_params.steep_deg = env_or("BUILDAT_HILLCLIMB_STEEP", 22);
		m_params.length_m = env_or("BUILDAT_HILLCLIMB_LENGTH", 50);
		m_latitude = env_or("BUILDAT_HILLCLIMB_LATITUDE", 60);
		m_day = env_or("BUILDAT_HILLCLIMB_DAY", 172);
		m_time = env_or("BUILDAT_HILLCLIMB_TIME", 14);
		m_payload = std::fmax(0, std::fmin(2000,
				env_or("BUILDAT_HILLCLIMB_PAYLOAD", 0)));
		if(const char *s = getenv("BUILDAT_HILLCLIMB_START")){
			std::istringstream is(s);
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
		// builtin/luanti's sky and its pbr light's rules, under the names
		// they run each other by, as skeldat serves them
		const ss_ res = m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res/";
		const ss_ own = m_server->get_builtin_modules_path()+
				"/luanti/client_lua/";
		static const uint8_t SAND[3] = {196, 174, 128};
		static const uint8_t STONE[3] = {128, 124, 116};
		static const uint8_t FILL[3] = {120, 98, 72};
		static const uint8_t BANK[3] = {96, 92, 86};
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_path("luanti/sky_model.lua", res+"sky_model.lua");
			i->add_file_path("luanti/sky_dome.lua", own+"sky_dome.lua");
			i->add_file_path("luanti/sky_light.lua", own+"sky_light.lua");
			i->add_file_content("main/sand.png", texture(1, SAND, 14));
			i->add_file_content("main/stone.png", texture(2, STONE, 18));
			i->add_file_content("main/fill.png", texture(3, FILL, 10));
			i->add_file_content("main/bank.png", texture(4, BANK, 22));
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
		most.steep_deg = STEEP_MAX;
		most.length_m = LENGTH_MAX;
		const hill::Hill big(most);
		const int S = 64;
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			i->create_instance(m_scene, pv::Region(0, 0, 0,
					(big.size_x() - 1) / S, (big.size_y() - 1) / S,
					(big.size_z() - 1) / S), true);
		});
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			interface::VoxelRegistry *reg = w->get_voxel_reg();
			reg->set_format(interface::VoxelFormat::blocks());
			add_voxel(reg, "air", "", false, 1);             // hill::AIR
			add_voxel(reg, "sand", "main/sand.png", true, 0.95f);
			add_voxel(reg, "stone", "main/stone.png", true, 0.7f);
			add_voxel(reg, "fill", "main/fill.png", true, 0.95f);
			add_voxel(reg, "bank", "main/bank.png", true, 0.8f);
			w->set_skylight_enabled(true);
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
		create_car();
	}

	// The hill of m_params, in the world in place of the one there: the
	// sections of the old one unloaded and the new one's pinned, which
	// generates them from the new grid
	// simplified: the grid is made on the main thread, a quarter of a
	// second for the default hill (-O1)
	void make_hill()
	{
		m_hill.reset(new hill::Hill(m_params));
		const hill::Hill &h = *m_hill;
		m_grid = std::make_shared<ground::Grid>(h);
		m_worldgen->set(m_grid);
		m_ground.reset(new ground::Ground(*m_grid, h));
		m_ground_live = false;
		clear_rocks();
		const int S = 64;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *w){
			for(const pv::Vector3DInt16 &sp : w->get_loaded_sections())
				w->unload_section(sp);
			sv_<voxelworld::LoadPoint> pins;
			for(int z = 0; z <= (h.size_z() - 1) / S; z++)
			for(int y = 0; y <= (h.size_y() - 1) / S; y++)
			for(int x = 0; x <= (h.size_x() - 1) / S; x++)
				pins.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
						x * S + S / 2, y * S + S / 2, z * S + S / 2), 0, 0, 0, 0));
			w->set_load_points(pins);
		});
		log_i(MODULE, "hillclimb: the hill, seed %u, %.0f degrees, %.0f m "
				"long, %.1f m high; %dx%dx%d voxels", m_params.seed,
				m_params.steep_deg, m_params.length_m, h.rise / hill::U,
				h.size_x(), h.size_y(), h.size_z());
	}

	//
	// The car
	//

	// Where it starts: on the bottom pad facing up the hill, or the
	// check's _START, a little over the ground to settle
	void place_car()
	{
		const float U = hill::U;
		const hill::Hill h(m_params);
		float x = m_start_set ? m_start_x : h.size_x() / 2.0f / U;
		float z = m_start_set ? m_start_z : hill::Hill::PAD / 2.0f / U;
		const car::Spec &s = m_car->spec;
		float y = (hill::Hill::BASE + 0.5f) / U + s.tyre_r + s.droop -
				s.mount_y + 0.05f;
		magic::Node *n = m_body->GetNode();
		n->SetWorldPosition(magic::Vector3(x * U, y * U, z * U));
		n->SetWorldRotation(magic::Quaternion(m_start_set ? m_start_yaw : 0,
				magic::Vector3::UP));
		m_body->SetLinearVelocity(magic::Vector3::ZERO);
		m_body->SetAngularVelocity(magic::Vector3::ZERO);
		m_body->Activate();
		m_car->shaft = m_car->pedal = m_car->brake = m_car->steer = 0;
	}

	void create_car()
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
			m_car.reset(new car::Car(car::Spec(), m_payload));
			const car::Spec &s = m_car->spec;
			// Local: the client draws the car from hillclimb:car
			magic::Node *n = scene->CreateChild("Car", magic::LOCAL);
			m_body = n->CreateComponent<magic::RigidBody>(magic::LOCAL);
			m_body->SetMass(m_car->mass());
			m_body->SetFriction(0.6f);
			auto *shape = n->CreateComponent<magic::CollisionShape>(
					magic::LOCAL);
			shape->SetBox(magic::Vector3(s.box_w, s.box_h, s.box_l) * U);
			// A floor for the chassis at the bottom pad's surface, the
			// ground's level all round (Grid::solid): the tyres' contact
			// is shallow, and a car off the top or over a bank sank into
			// the ground with nothing to stop it at the end of its fall
			magic::Node *floor = scene->CreateChild("Floor", magic::LOCAL);
			floor->SetPosition(magic::Vector3(0,
					hill::Hill::BASE + 0.5f, 0));
			floor->CreateComponent<magic::RigidBody>(magic::LOCAL);
			floor->CreateComponent<magic::CollisionShape>(magic::LOCAL)->
					SetStaticPlane();
		});
		place_car();
		log_i(MODULE, "hillclimb: the car, %.0f kg with %.0f kg of payload",
				m_car->spec.mass, m_payload);
	}

	// The check's drive: the keys of the step whose time has come
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
			if(keys.find('B') != ss_::npos)
				reset_race();
			// A stone dropped on the slope's lower third, a metre in from
			// the left bank: clear of a car on the track's middle
			if(keys.find('K') != ss_::npos){
				ground::Loose l;
				int x = hill::Hill::BANK_W + hill::U, z = m_hill->slope_z0() +
						m_hill->run / 3;
				l.centre = car::V3((float)x, m_hill->surface(x, z) + 3.0f,
						(float)z);
				l.radius = 1.3f;
				l.kg = 9 * m_ground->soil.stone_kg;
				m_loose.push_back(l);
			}
			size_t h = keys.find('H');
			int steep = 0, length = 0;
			if(h != ss_::npos && sscanf(keys.c_str() + h + 1, "%d/%d", &steep,
					&length) == 2){
				on_params(network::Packet(0, "hillclimb:params", itos(
						m_params.seed) + " " + itos(steep) + " " + itos(length) +
						" " + itos((int)m_payload) + " 60 172 14"));
			}
		}
		if(keys.find('Q') != ss_::npos){
			m_server->shutdown(0, "hillclimb: the drive is over");
			m_drive.clear();
			return;
		}
		m_input.accel = keys.find('W') != ss_::npos;
		m_input.brake = keys.find('S') != ss_::npos;
		m_input.left = keys.find('A') != ss_::npos;
		m_input.right = keys.find('D') != ss_::npos;
		for(char c : keys.substr(0, keys.find('H'))){
			if(c >= '1' && c <= '4')
				m_input.gear = (car::Gear)(car::G1 + (c - '1'));
			if(c == 'R')
				m_input.gear = car::REVERSE;
		}
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_car)
			return;
		if(m_pending)
			apply_pending();
		if(m_reset)
			do_reset();
		const float U = hill::U;
		const float dt = 1.0f / SUBSTEPS_HZ;
		// simplified: a long tick is cut to a quarter second of substeps;
		// the car slows with the server rather than jumping
		int n = (int)std::lround(std::fmin(event.dtime, 0.25f) / dt);
		const uint64_t t0 = interface::os::time_us();
		main_context::access(m_server, [&](main_context::Interface *){
			for(int i = 0; i < n; i++){
				if(!m_drive.empty() && m_ground_live)
					drive_step();
				// Held on the brake until the hill is made: the ground gives
				// only then, and a run is on the ground that gives
				car::Input held;
				held.brake = true;
				held.gear = m_input.gear;
				m_car->controls(m_ground_live ? m_input : held, dt);
				magic::Node *node = m_body->GetNode();
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
				m_car->step(*m_grid, U, pose, [&](const car::V3 &at){
					// Relative to the body, as ApplyForce's position
					magic::Vector3 v = m_body->GetVelocityAtPoint(
							magic::Vector3(at.x, at.y, at.z) * U - p);
					return v3(v / U);
				}, dt);
				if(m_ground_live){
					for(int k = 0; k < 4; k++)
						m_ground->wheel(k, m_car->wheel[k], m_car->spec, U, dt);
					// Made bodies after the flush that takes their voxels out
					// of the world's boxes (ground_tick), not inside them
					for(const ground::Loose &l : m_ground->loose)
						m_loose.push_back(l);
					m_ground->loose.clear();
				}
				for(const car::Wheel &w : m_car->wheel){
					if(w.load <= 0)
						continue;
					m_body->ApplyForce(magic::Vector3(w.force.x, w.force.y,
							w.force.z) * U, magic::Vector3(w.at.x, w.at.y,
							w.at.z) * U - p);
				}
				m_physics->Update(dt);
				if(m_ground_live){
					m_t += dt;
					race_step(dt);
				}
			}
		});
		m_step_us += interface::os::time_us() - t0;
		m_step_ticks++;
		ground_tick(n * dt);
		if(!m_drive.empty() && m_t - m_logged >= 1){
			m_logged = m_t;
			log_car();
		}
		send_car();
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
		}
		const float U = hill::U;
		main_context::access(m_server, [&](main_context::Interface *){
			for(size_t i = 0; i < m_rocks.size();){
				Rock &r = m_rocks[i];
				r.age += dt;
				bool still = r.body->GetLinearVelocity().Length() < 0.1f * U &&
						r.body->GetAngularVelocity().Length() < 1.0f;
				r.still = still ? r.still + dt : 0;
				magic::Vector3 p = r.node->GetWorldPosition();
				// simplified: one that has not stopped in 8 s (held under the
				// car, rocking) rests where it is
				if(r.still < 1 && r.age < 8 && p.y_ > -U){
					i++;
					continue;
				}
				int n = m_ground->rest(car::V3(p.x_, p.y_, p.z_), r.radius);
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
					// Written without light: voxelworld floods it from the
					// change
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
		magic::Scene *scene = m_body->GetNode()->GetScene();
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
			m_rocks.push_back(r);
			log_i(MODULE, "hillclimb: rock %d loose at %.2f,%.2f,%.2f m, %d "
					"voxels, %.0f kg", r.id, l.centre.x / U, l.centre.y / U,
					l.centre.z / U, l.voxels, l.kg);
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

	void race_step(float dt)
	{
		if(m_race == READY && m_input.accel){
			m_race = RUNNING;
			m_race_t = 0;
		}
		if(m_race != RUNNING)
			return;
		m_race_t += dt;
		// The rear axle over the top pad's first voxel
		const hill::Hill h(m_params);
		magic::Node *n = m_body->GetNode();
		magic::Vector3 rear = n->GetWorldPosition() + n->GetWorldRotation() *
				magic::Vector3(0, 0, -m_car->spec.wheelbase / 2 * hill::U);
		if(rear.z_ >= h.top_z0() - 0.5f)
			finish();
	}

	// The ranking's keys: the parameter set and the payload, then the time
	// in milliseconds, zero-padded so the store's order is the ranking's
	ss_ ranking_prefix() const
	{
		char buf[128];
		snprintf(buf, sizeof buf, "seed%u/steep%d/length%d/sand/payload%d/",
				m_params.seed, (int)m_params.steep_deg, (int)m_params.length_m,
				(int)m_payload);
		return buf;
	}

	sv_<float> ranking(size_t max)
	{
		sv_<float> times;
		if(!m_save)
			return times;
		const ss_ prefix = ranking_prefix();
		for(const ss_ &key : m_save->store("times")->list(prefix)){
			if(times.size() >= max)
				break;
			times.push_back(atoi(key.c_str() + prefix.size()) / 1000.0f);
		}
		return times;
	}

	static ss_ seconds(float t)
	{
		char buf[32];
		snprintf(buf, sizeof buf, "%.3f", t);
		return buf;
	}

	void finish()
	{
		m_race = FINISHED;
		const int ms = (int)std::lround(m_race_t * 1000);
		m_last_rank = -1;
		if(m_save){
			char key[64];
			snprintf(key, sizeof key, "%09d/%lld", ms,
					(long long)interface::os::time_us());
			const ss_ prefix = ranking_prefix();
			m_save->store("times")->set(prefix + key, "");
			const sv_<ss_> keys = m_save->store("times")->list(prefix);
			for(size_t i = 0; i < keys.size(); i++)
				if(keys[i] == prefix + key)
					m_last_rank = (int)i;
		}
		ss_ list;
		for(float t : ranking(10))
			list += " " + seconds(t);
		log_i(MODULE, "hillclimb: finish %.3f s on %s, rank %d; the ranking:%s",
				ms / 1000.0f, cs(ranking_prefix()), m_last_rank, cs(list));
		send_ranking();
	}

	// The best ten under the hill and payload, and where the last finish
	// is among all of them (-1 if none)
	void send_ranking()
	{
		ss_ data = itos(m_last_rank);
		for(float t : ranking(10))
			data += " " + seconds(t);
		network::access(m_server, [&](network::Interface *i){
			for(auto peer : m_peers)
				i->send(peer, "hillclimb:ranking", data);
		});
	}

	// Each run on the hill as it was made
	// Done at the next tick's start (do_reset), outside any module's
	// access: making the hill again reaches voxelworld
	void reset_race()
	{
		m_race = READY;
		m_race_t = 0;
		m_last_rank = -1;
		m_reset = true;
	}
	void do_reset()
	{
		m_reset = false;
		// The ground as the hill was made (flushed with the next changes)
		if(m_ground && m_ground->changed())
			m_ground->restore();
		clear_rocks();
		main_context::access(m_server, [&](main_context::Interface *){
			place_car();
		});
	}

	// The deepest the track is under the hill's generated surface, in
	// voxels: the ruts dug and sunk
	int rut() const
	{
		int deepest = 0;
		for(int z = 0; z < m_hill->size_z(); z++)
		for(int x = hill::Hill::BANK_W; x < hill::Hill::BANK_W +
				hill::Hill::TRACK_W; x++)
			deepest = std::max(deepest, m_hill->surface(x, z) - m_grid->top(x, z));
		return deepest;
	}

	// The check reads these: the centre of mass in metres, the speed, the
	// shaft, each spring's compression and whether its tyre slides
	void log_car()
	{
		const float U = hill::U;
		magic::Node *n = m_body->GetNode();
		magic::Vector3 p = n->GetWorldPosition() / U;
		magic::Vector3 v = m_body->GetLinearVelocity() / U;
		const car::Car &c = *m_car;
		log_i(MODULE, "hillclimb: car t=%.1f pos=%.3f,%.3f,%.3f v=%.2f "
				"shaft=%.3f springs=%.3f,%.3f,%.3f,%.3f slip=%d%d%d%d gear=%d "
				"tick_us=%d race=%d/%.2f ground=%d/%d/%d/%d rocks=%d rut=%d "
				"commits=%d",
				m_t, p.x_, p.y_, p.z_, v.Length(), c.shaft / (2 * car::PI),
				c.wheel[0].spring, c.wheel[1].spring, c.wheel[2].spring,
				c.wheel[3].spring, c.wheel[0].slipping, c.wheel[1].slipping,
				c.wheel[2].slipping, c.wheel[3].slipping, (int)c.gear,
				(int)(m_step_us / std::max(1, m_step_ticks)), (int)m_race,
				m_race_t, m_ground->dug, m_ground->sunk, m_ground->slid,
				m_ground->freed, (int)m_rocks.size(), rut(), m_flushes);
		m_flushes = 0;
		m_step_us = 0;
		m_step_ticks = 0;
	}

	// What the client draws, in voxels: the chassis' pose, the wheels'
	// spin and steering, each spring's compression; the shaft in rev/s,
	// the gear, the race (0 ready, 1 running, 2 finished, 3 the hill still
	// being made) and its time
	void send_car()
	{
		if(m_peers.empty())
			return;
		const float U = hill::U;
		magic::Node *n = m_body->GetNode();
		magic::Vector3 p = n->GetWorldPosition();
		magic::Quaternion q = n->GetWorldRotation();
		const car::Car &c = *m_car;
		char buf[512];
		snprintf(buf, sizeof buf, "%.3f %.3f %.3f %.5f %.5f %.5f %.5f %.4f "
				"%.4f %.4f %.3f %.3f %.3f %.3f %.3f %d %d %.3f", p.x_, p.y_, p.z_,
				q.w_, q.x_, q.y_, q.z_, c.spin, c.wheel[0].steer,
				c.wheel[1].steer, c.wheel[0].spring * U, c.wheel[1].spring * U,
				c.wheel[2].spring * U, c.wheel[3].spring * U,
				c.shaft / (2 * car::PI), (int)c.gear,
				m_ground_live ? (int)m_race : 3, m_race_t);
		network::access(m_server, [&](network::Interface *i){
			for(auto peer : m_peers)
				i->send(peer, "hillclimb:car", buf);
		});
	}

	// "accel brake left right gear reset", each a number
	// simplified: one car, driven by whoever sends; more cars are later
	void on_input(const network::Packet &packet)
	{
		std::istringstream is(packet.data);
		int a = 0, b = 0, l = 0, r = 0, g = 1, reset = 0;
		if(!(is >> a >> b >> l >> r >> g >> reset) || g < car::REVERSE ||
				g >= car::GEARS)
			return;
		m_input.accel = a != 0;
		m_input.brake = b != 0;
		m_input.left = l != 0;
		m_input.right = r != 0;
		m_input.gear = (car::Gear)g;
		if(reset && m_car)
			reset_race();
	}

	// "seed steep length payload latitude day hour" from the menu, held to
	// what a player may pick; made when worldgen is idle (on_tick)
	void on_params(const network::Packet &packet)
	{
		std::istringstream is(packet.data);
		long long seed = 0;
		int steep = 0, length = 0, payload = -1;
		float lat = 0, day = 0, hour = 0;
		if(!(is >> seed >> steep >> length >> payload >> lat >> day >> hour))
			return;
		bool payload_ok = false;
		for(int w : PAYLOADS)
			payload_ok = payload_ok || w == payload;
		if(seed < 1 || seed > 999999 || steep < STEEP_MIN || steep > STEEP_MAX ||
				length < LENGTH_MIN || length > LENGTH_MAX || !payload_ok ||
				!(lat >= -80 && lat <= 80) || !(day >= 1 && day <= 365) ||
				!(hour >= 0 && hour <= 24))
			return;
		m_pending_params.seed = (uint32_t)seed;
		m_pending_params.steep_deg = (float)steep;
		m_pending_params.length_m = (float)length;
		m_pending_payload = (float)payload;
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
				np.length_m != m_params.length_m;
		m_params = np;
		m_latitude = m_pending_look[0];
		m_day = m_pending_look[1];
		m_time = m_pending_look[2];
		m_payload = m_pending_payload;
		if(hill_changed)
			make_hill();
		main_context::access(m_server, [&](main_context::Interface *){
			m_car->payload = m_payload;
			m_body->SetMass(m_car->mass());
		});
		reset_race();
		network::access(m_server, [&](network::Interface *i){
			for(auto peer : m_peers)
				i->send(peer, "hillclimb:hill", hill_packet());
		});
		send_ranking();
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		m_peers.erase(old_client.info.id);
	}

	// What the client draws by: the hill's size and where the car starts,
	// in voxels, the place and the hour, and the menu's picks: the seed,
	// the steepness, the length and the payload
	ss_ hill_packet()
	{
		const hill::Hill h(m_params);
		char buf[256];
		snprintf(buf, sizeof buf, "%d %d %d %d %d %d %g %g %g %u %d %d %d",
				h.size_x(), h.size_y(), h.size_z(), h.size_x() / 2,
				hill::Hill::BASE + 1, hill::Hill::PAD / 2, m_latitude, m_day,
				m_time, m_params.seed, (int)m_params.steep_deg,
				(int)m_params.length_m, (int)m_payload);
		return buf;
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		network::access(m_server, [&](network::Interface *i){
			i->send(event.recipient, "hillclimb:hill", hill_packet());
		});
		m_peers.insert(event.recipient);
		send_ranking();
		replicate::access(m_server, [&](replicate::Interface *i){
			i->assign_scene_to_peer(m_scene, event.recipient);
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
