// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// demo_hillclimb ([HILLCLIMB], doc/plan/hillclimb_plan.md): a hill-climb
// time trial on generated voxel ground. The hill (hill.h) from its
// parameters, its textures made here, and the parameters the client
// lights it by (latitude, day, time of day); the car (car.h), whose
// chassis is a Bullet body here and whose tyres car.h works out, the
// server's physics authoritative. Nothing is saved: a track is generated
// from its parameters each time.
//
// The parameters, until the menu ([HILLCLIMB] 3): BUILDAT_HILLCLIMB_SEED,
// _STEEP (degrees), _LENGTH (the slope's run, m), _LATITUDE (degrees),
// _DAY (1..365), _TIME (hours, solar) and _PAYLOAD (kg).
//
// For the check, with no client: BUILDAT_HILLCLIMB_DRIVE, steps of
// "<seconds>:<keys>" from the car's start, each held until the next --
// W accelerator, S brake, A and D steering, 1 to 4 and R the gear, Q the
// server's end -- logging the car each second; and _START, "x z yaw"
// (m, m, degrees) for a start other than the bottom pad's.
#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "main_context/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/os.h"
#include "hill.h"
#include "car.h"
#include <PhysicsWorld.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <Scene.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <STB/stb_image_write.h>
#include <cstdlib>
#include <sstream>
#include <set>
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

// The hill's voxels, made once at the start: what the generator hands
// voxelworld and what the tyres stand on. Outside the hill's box the
// ground is flat at the bottom pad's level, as the client draws it.
// simplified: a copy beside voxelworld's, which is the ground that gives
// ([HILLCLIMB] 4) writing both
struct Grid: public car::Ground
{
	int sx, sy, sz;
	std::vector<uint8_t> v;
	Grid(const hill::Hill &h):
		sx(h.size_x()), sy(h.size_y()), sz(h.size_z()),
		v((size_t)sx * sy * sz)
	{
		for(int z = 0; z < sz; z++)
		for(int y = 0; y < sy; y++)
		for(int x = 0; x < sx; x++)
			v[((size_t)z * sy + y) * sx + x] = h.at(x, y, z);
	}
	bool inside(int x, int y, int z) const
	{
		return x >= 0 && y >= 0 && z >= 0 && x < sx && y < sy && z < sz;
	}
	hill::Voxel at(int x, int y, int z) const
	{
		return inside(x, y, z) ? (hill::Voxel)v[((size_t)z * sy + y) * sx + x] :
				hill::AIR;
	}
	bool solid(int x, int y, int z) const
	{
		return inside(x, y, z) ? at(x, y, z) != hill::AIR :
				y <= hill::Hill::BASE;
	}
};

struct Worldgen: public worldgen::GeneratorInterface
{
	const Grid &m_hill;
	Worldgen(const Grid &grid): m_hill(grid){}

	// On a worker thread: into the volume it is given
	void generate(SceneReference scene_ref, const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
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
	up_<Grid> m_grid;
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
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this,
				Event::t("network:packet_received/hillclimb:input"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("network:packet_received/hillclimb:input", on_input,
				network::Packet)
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
		// they run each other by, as demo_skeldat serves them
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
		const hill::Hill h(m_params);
		m_grid.reset(new Grid(h));
		main_context::access(m_server, [&](main_context::Interface *i){
			m_scene = i->create_scene();
		});
		// Before voxelworld, or its first generation requests are lost
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->create_instance(m_scene);
			i->get_instance(m_scene)->set_generator(new Worldgen(*m_grid));
		});
		// The whole hill, in sections of 64 voxels, never streamed
		const int S = 64;
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			i->create_instance(m_scene, pv::Region(0, 0, 0,
					(h.size_x() - 1) / S, (h.size_y() - 1) / S,
					(h.size_z() - 1) / S), true);
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
		worldgen::access(m_server, m_scene, [&](worldgen::Instance *i){
			i->enable();
		});
		log_i(MODULE, "hillclimb: the hill, seed %u, %.0f degrees, %.0f m "
				"long, %.1f m high; %dx%dx%d voxels", m_params.seed,
				m_params.steep_deg, m_params.length_m, h.rise / hill::U,
				h.size_x(), h.size_y(), h.size_z());
		create_car();
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
		main_context::access(m_server, [&](main_context::Interface *i){
			magic::Scene *scene = i->check_scene(m_scene);
			m_physics = scene->GetComponent<magic::PhysicsWorld>();
			// The car's substeps are this module's (on_tick); a world unit
			// is a voxel, so gravity is in voxels
			m_physics->SetUpdateEnabled(false);
			m_physics->SetMaxSubSteps(-1);
			m_physics->SetGravity(magic::Vector3(0, -9.81f * U, 0));
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
		bool any = false;
		for(auto &st : m_drive){
			if(st.first > m_t)
				break;
			keys = st.second;
			any = true;
		}
		if(!any)
			return;
		if(keys.find('Q') != ss_::npos){
			m_server->shutdown(0, "hillclimb: the drive is over");
			m_drive.clear();
			return;
		}
		m_input.accel = keys.find('W') != ss_::npos;
		m_input.brake = keys.find('S') != ss_::npos;
		m_input.left = keys.find('A') != ss_::npos;
		m_input.right = keys.find('D') != ss_::npos;
		for(char c : keys){
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
		const float U = hill::U;
		const float dt = 1.0f / SUBSTEPS_HZ;
		// simplified: a long tick is cut to a quarter second of substeps;
		// the car slows with the server rather than jumping
		int n = (int)std::lround(std::fmin(event.dtime, 0.25f) / dt);
		const uint64_t t0 = interface::os::time_us();
		main_context::access(m_server, [&](main_context::Interface *){
			for(int i = 0; i < n; i++){
				if(!m_drive.empty())
					drive_step();
				m_car->controls(m_input, dt);
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
				for(const car::Wheel &w : m_car->wheel){
					if(w.load <= 0)
						continue;
					m_body->ApplyForce(magic::Vector3(w.force.x, w.force.y,
							w.force.z) * U, magic::Vector3(w.at.x, w.at.y,
							w.at.z) * U - p);
				}
				m_physics->Update(dt);
				m_t += dt;
			}
		});
		m_step_us += interface::os::time_us() - t0;
		m_step_ticks++;
		if(!m_drive.empty() && m_t - m_logged >= 1){
			m_logged = m_t;
			log_car();
		}
		send_car();
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
				"tick_us=%d",
				m_t, p.x_, p.y_, p.z_, v.Length(), c.shaft / (2 * car::PI),
				c.wheel[0].spring, c.wheel[1].spring, c.wheel[2].spring,
				c.wheel[3].spring, c.wheel[0].slipping, c.wheel[1].slipping,
				c.wheel[2].slipping, c.wheel[3].slipping, (int)c.gear,
				(int)(m_step_us / std::max(1, m_step_ticks)));
		m_step_us = 0;
		m_step_ticks = 0;
	}

	// What the client draws, in voxels: the chassis' pose, the wheels'
	// spin and steering, each spring's compression; the shaft in rev/s and
	// the gear
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
				"%.4f %.4f %.3f %.3f %.3f %.3f %.3f %d", p.x_, p.y_, p.z_,
				q.w_, q.x_, q.y_, q.z_, c.spin, c.wheel[0].steer,
				c.wheel[1].steer, c.wheel[0].spring * U, c.wheel[1].spring * U,
				c.wheel[2].spring * U, c.wheel[3].spring * U,
				c.shaft / (2 * car::PI), (int)c.gear);
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
		if(reset && m_car){
			main_context::access(m_server, [&](main_context::Interface *){
				place_car();
			});
		}
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		m_peers.erase(old_client.info.id);
	}

	// What the client draws by: the hill's size and where the car starts,
	// in voxels, and the place and the hour
	ss_ hill_packet()
	{
		const hill::Hill h(m_params);
		char buf[256];
		snprintf(buf, sizeof buf, "%d %d %d %d %d %d %g %g %g",
				h.size_x(), h.size_y(), h.size_z(), h.size_x() / 2,
				hill::Hill::BASE + 1, hill::Hill::PAD / 2, m_latitude, m_day,
				m_time);
		return buf;
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		network::access(m_server, [&](network::Interface *i){
			i->send(event.recipient, "hillclimb:hill", hill_packet());
		});
		m_peers.insert(event.recipient);
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
