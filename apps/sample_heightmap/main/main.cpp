// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [HEIGHTMAP_TERRAIN] A ball on generated hills: builtin/heightmap's map,
// 1 km a side at a metre, generated from a seed the first time and read
// from the save after; a flat sand pad in the middle that the ball is
// dropped on. WASD pushes the ball, C digs a crater under it. The physics
// is the server's (Bullet's heightfield); the client draws what it is told.
// [HEIGHTMAP_REST] Five materials: the generator's grass, rock and sand, a
// crater's dirt (3) and the pad's gravel (4). The server's memory for the
// map is logged (Linux: the resident set before and after; what other
// modules do meanwhile counts in it too, as network deflating web/).
// BUILDAT_HEIGHTMAP_SURFACE=valleys makes the hills Luanti's valleys mapgen
// sampled (luanti_mapgen::surface_map), its rivers off.
#include "core/log.h"
#include "client_file/api.h"
#include "heightmap/api.h"
#include "luanti_mapgen/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "storage/api.h"
#include "interface/module.h"
#include "interface/os.h"
#include "interface/server.h"
#include "interface/event.h"
#include <Scene.h>
#include <Node.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <unistd.h>
#define MODULE "main"

using interface::Event;
using main_context::SceneReference;
using namespace Urho3D;

namespace main {

static const uint32_t SEED = 1234;
static const int PAD_HALF = 12;
static const float BALL_RADIUS = 1.0f;
static const float PUSH = 40.0f;
static const int CRATER_RADIUS = 4;
static const float CRATER_DEPTH = 2.0f;
static const int MATERIALS = 5;
static const int DIRT = 3, GRAVEL = 4;

// The process's resident set in MB, -1 where /proc does not say
static float rss_mb()
{
	long pages = -1, resident = -1;
	FILE *f = fopen("/proc/self/statm", "r");
	if(!f)
		return -1;
	if(fscanf(f, "%ld %ld", &pages, &resident) != 2)
		resident = -1;
	fclose(f);
	return resident < 0 ? -1 :
			resident * (sysconf(_SC_PAGESIZE) / 1024) / 1024.0f;
}

static heightmap::Weights only(int material)
{
	heightmap::Weights w{};
	w[material] = 255;
	return w;
}

// The chunks written, as a snapshot would see them: once a chunk a commit
struct CountWrites: public heightmap::ChunkHook
{
	int *count;
	CountWrites(int *count): count(count){}
	void before_write(heightmap::Instance *map, int cx, int cz,
			const ss_ &old_data){ (*count)++; }
};

struct Module: public interface::Module
{
	int m_chunks_written = 0;
	interface::Server *m_server;
	SceneReference m_scene = nullptr;
	storage::Save *m_save = nullptr;
	uint m_ball_id = 0;
	int m_keys = 0; // bits: W A S D
	float m_still_s = 0;
	bool m_rest_said = false;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:input"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:crater"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:input",
				on_input, network::Packet)
		EVENT_TYPEN("network:packet_received/main:crater",
				on_crater, network::Packet)
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});
		storage::access(m_server, [&](storage::Interface *i){
			m_save = i->open("main");
			if(!m_save)
				m_save = i->create("main");
		});
		float pad_y = 0;
		heightmap::Size size;
		size.materials = MATERIALS;
		// BUILDAT_HEIGHTMAP_SURFACE=valleys: Luanti's valleys sampled, its
		// rivers off, the map from 128 m under its water
		const char *surface = getenv("BUILDAT_HEIGHTMAP_SURFACE");
		sv_<float> valleys;
		if(surface && ss_(surface) == "valleys"){
			size.base_y = -128;
			valleys = sample_valleys(size);
		}
		const float rss0 = rss_mb();
		heightmap::access(m_server, [&](heightmap::Interface *ih){
			heightmap::Instance *map = ih->create_instance(m_scene, size);
			map->add_chunk_hook(up_<heightmap::ChunkHook>(
					new CountWrites(&m_chunks_written)));
			if(!map->set_save(m_save, "main")){
				heightmap::GenerateParams params;
				params.seed = SEED;
				if(!valleys.empty()){
					const int sx = map->samples_x();
					const float cell = size.cell_size;
					params.height_fn = [&](float x, float z){
						return valleys[(size_t)std::round(z / cell) * sx +
								(size_t)std::round(x / cell)];
					};
					// Beaches: Luanti's water is at 1
					params.sand_below = 2.0f;
				}
				map->generate(params);
				make_pad(map);
			}
			pad_y = map->height_at(pad_x(map), pad_z(map));
			// The heightfield made now, to measure it
			map->commit();
		});
		log_i(MODULE, "sample_heightmap: the server's memory: %.1f MB before"
				" the map, %.1f MB with it", rss0, rss_mb());
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene);
			Node *n = scene->CreateChild("ball");
			m_ball_id = n->GetID();
			RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
			body->SetMass(5.0f);
			body->SetFriction(0.8f);
			body->SetRollingFriction(0.05f);
			body->SetLinearDamping(0.05f);
			body->SetAngularDamping(0.2f);
			n->CreateComponent<CollisionShape>(LOCAL)->SetSphere(
					BALL_RADIUS * 2);
		});
		drop_ball(pad_y);
	}

	void on_unload()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_scene);
		});
	}

	// The valleys mapgen's ground over the map's samples, out of its noise
	// (luanti_mapgen::surface_map), seed SEED, mgvalleys_river_size 0: the
	// valleys stay and no river bed is cut
	sv_<float> sample_valleys(const heightmap::Size &size)
	{
		const int sx = size.chunks_x * size.chunk_size;
		const int sz = size.chunks_z * size.chunk_size;
		sv_<float> h((size_t)sx * sz);
		bool ok = false;
		const int64_t t0 = interface::os::time_us();
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *i){
			luanti_mapgen::Params p;
			p.mgname = "valleys";
			p.seed = SEED;
			p.settings["mgvalleys_river_size"] = "0";
			// The ids every Luanti game has; no node is placed
			p.content_ids = {{"ignore", 0}, {"unknown", 1}, {"air", 2}};
			ok = i->surface_map(p, 0, 0, size.cell_size, sx, sz, h.data());
		});
		if(!ok)
			throw Exception("sample_heightmap: no valleys surface");
		float lo = h[0], hi = h[0];
		for(float v : h)
			lo = std::min(lo, v), hi = std::max(hi, v);
		log_i(MODULE, "sample_heightmap: the valleys surface sampled in %.0f"
				" ms: %.1f to %.1f m", (interface::os::time_us() - t0) /
				1000.0, lo, hi);
		return h;
	}

	float pad_x(heightmap::Instance *map)
	{
		return map->samples_x() / 2 * map->get_size().cell_size;
	}
	float pad_z(heightmap::Instance *map)
	{
		return map->samples_z() / 2 * map->get_size().cell_size;
	}

	// Flat gravel where the ball starts, at the middle's height
	void make_pad(heightmap::Instance *map)
	{
		const int cx = map->samples_x() / 2, cz = map->samples_z() / 2;
		const float h = map->get_height(cx, cz);
		for(int z = cz - PAD_HALF; z <= cz + PAD_HALF; z++)
			for(int x = cx - PAD_HALF; x <= cx + PAD_HALF; x++){
				map->set_height(x, z, h);
				map->set_weights(x, z, only(GRAVEL));
			}
	}

	void drop_ball(float pad_y)
	{
		heightmap::Instance *map = nullptr;
		float x = 0, z = 0;
		heightmap::access(m_server, [&](heightmap::Interface *ih){
			map = ih->get_instance(m_scene);
			x = pad_x(map), z = pad_z(map);
		});
		main_context::access(m_server, [&](main_context::Interface *imc){
			Node *n = imc->check_scene(m_scene)->GetNode(m_ball_id);
			n->SetPosition(Vector3(x, pad_y + 15.0f, z));
			RigidBody *body = n->GetComponent<RigidBody>();
			body->SetLinearVelocity(Vector3::ZERO);
			body->SetAngularVelocity(Vector3::ZERO);
			body->Activate();
		});
		m_still_s = 0;
		m_rest_said = false;
	}

	void on_tick(const interface::TickEvent &event)
	{
		Vector3 p, v;
		main_context::access(m_server, [&](main_context::Interface *imc){
			Node *n = imc->check_scene(m_scene)->GetNode(m_ball_id);
			if(!n)
				return;
			RigidBody *body = n->GetComponent<RigidBody>();
			p = n->GetPosition();
			v = body->GetLinearVelocity();
			if(m_keys){
				Vector3 f(((m_keys & 8) ? 1 : 0) - ((m_keys & 2) ? 1 : 0), 0,
						((m_keys & 1) ? 1 : 0) - ((m_keys & 4) ? 1 : 0));
				body->ApplyForce(f.Normalized() * PUSH * body->GetMass());
				body->Activate();
			}
		});
		// Said once a rest: the centre over the surface, which is the radius
		// when the heightfield holds the ball where the map says it is
		if(v.Length() < 0.02f)
			m_still_s += event.dtime;
		else
			m_still_s = 0, m_rest_said = false;
		if(m_still_s > 1.0f && !m_rest_said){
			m_rest_said = true;
			float ground = 0;
			heightmap::access(m_server, m_scene, [&](heightmap::Instance *map){
				ground = map->height_at(p.x_, p.z_);
			});
			log_i(MODULE, "sample_heightmap: the ball rests at (%.2f, %.3f,"
					" %.2f), %.3f over the ground at %.3f", p.x_, p.y_, p.z_,
					p.y_ - ground, ground);
		}
	}

	void on_input(const network::Packet &packet)
	{
		m_keys = packet.data.empty() ? 0 : (uint8_t)packet.data[0] & 15;
	}

	// A bowl of dirt under the ball, CRATER_DEPTH at the middle; the clients
	// get the rectangles it wrote and the ball falls in
	void on_crater(const network::Packet &packet)
	{
		Vector3 p;
		main_context::access(m_server, [&](main_context::Interface *imc){
			p = imc->check_scene(m_scene)->GetNode(m_ball_id)->GetPosition();
		});
		float bottom = 0;
		uint32_t hash = 0;
		m_chunks_written = 0;
		heightmap::access(m_server, m_scene, [&](heightmap::Instance *map){
			const float cell = map->get_size().cell_size;
			const int cx = (int)std::round(p.x_ / cell);
			const int cz = (int)std::round(p.z_ / cell);
			for(int z = cz - CRATER_RADIUS; z <= cz + CRATER_RADIUS; z++)
			for(int x = cx - CRATER_RADIUS; x <= cx + CRATER_RADIUS; x++){
				if(x < 0 || z < 0 || x >= map->samples_x() ||
						z >= map->samples_z())
					continue;
				const float d = std::sqrt((float)((x - cx) * (x - cx) +
						(z - cz) * (z - cz))) / CRATER_RADIUS;
				if(d > 1)
					continue;
				map->set_height(x, z, map->get_height(x, z) -
						CRATER_DEPTH * (1 - d * d));
				map->set_weights(x, z, only(DIRT));
			}
			// Now rather than at the module's tick: the ball is woken
			// below, onto the new heightfield
			map->commit();
			bottom = map->get_height(cx, cz);
			hash = map->content_hash();
			p.x_ = cx * cell, p.z_ = cz * cell;
		});
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->check_scene(m_scene)->GetNode(m_ball_id)->
					GetComponent<RigidBody>()->Activate();
		});
		m_still_s = 0;
		m_rest_said = false;
		char buf[100];
		snprintf(buf, sizeof buf, "%.2f %.2f %.3f", p.x_, p.z_, bottom);
		log_i(MODULE, "sample_heightmap: a crater at (%s): %i chunks written,"
				" the map saved with hash %08x", buf, m_chunks_written, hash);
		network::access(m_server, [&](network::Interface *inet){
			inet->send(packet.sender, "main:crater", buf);
		});
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *irep){
			irep->assign_scene_to_peer(m_scene, event.recipient);
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
