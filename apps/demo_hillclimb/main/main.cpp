// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// demo_hillclimb ([HILLCLIMB], doc/plan/hillclimb_plan.md): a hill-climb
// time trial on generated voxel ground. Stage 1: the hill (hill.h) from
// its parameters, its textures made here, and the parameters the client
// lights it by (latitude, day, time of day). Nothing is saved: a track is
// generated from its parameters each time.
//
// The parameters, until the menu ([HILLCLIMB] 3): BUILDAT_HILLCLIMB_SEED,
// _STEEP (degrees), _LENGTH (the slope's run, m), _LATITUDE (degrees),
// _DAY (1..365) and _TIME (hours, solar).
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
#include "hill.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <STB/stb_image_write.h>
#include <cstdlib>
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

struct Worldgen: public worldgen::GeneratorInterface
{
	hill::Hill m_hill;
	Worldgen(const hill::Params &p): m_hill(p){}

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
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
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
		main_context::access(m_server, [&](main_context::Interface *i){
			m_scene = i->create_scene();
		});
		// Before voxelworld, or its first generation requests are lost
		worldgen::access(m_server, [&](worldgen::Interface *i){
			i->create_instance(m_scene);
			i->get_instance(m_scene)->set_generator(new Worldgen(m_params));
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
