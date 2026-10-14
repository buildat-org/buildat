// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
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
#include "interface/voxel_selector.h"
#include <Scene.h>
#include <Context.h>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelVolume;
using interface::VoxelField;
using main_context::SceneReference;

namespace main
{

using namespace Urho3D;

// The look spike of doc/plan/aggregate_plan.md, step 2. A wall of samples with
// their fields set by hand: no simulation, no rules, nothing derived. The
// question it exists to answer is whether a mixture reads on screen -- can
// 70% rock / 30% sand be told from 30/70 at a glance -- and it is asked here,
// before the storage is rewritten to hold mixtures.
//
// It is also the first consumer of the modifier roles at all, so it is what
// says whether the tint and the sag work.

static const int VOLUME_SIZE = 64;
static const int FLOOR_TOP = 8;

// The only id in this world, written into every voxel so that voxelworld can
// tell a generated voxel from one nothing has got to yet. It says nothing
// about what the voxel is: that comes out of the rock and sand fractions
// through the registry's look rules, which is the thing demo_aggregate needs and
// this is the first world to use.
static const uint8_t PRESENT_ID = 1;

// The definitions the look rules choose between. They are still voxel types
// as far as the registry is concerned -- a definition is where every
// property lives -- but nothing stores one.
static const uint8_t AIR_DEF = 1;
static const uint8_t ROCK_DEF = 2;
static const uint8_t SAND_DEF = 3;

// The game's own fields, which no engine role covers: how much of a voxel is
// rock and how much is sand. Four bits each, in a plane of their own rather
// than in whatever is left of the first one -- which is what a mixture world
// wants, and is why planes exist. A chunk that has never had a mixture
// written into it does not carry the plane at all.
static const uint8_t MATERIAL_PLANE = 1;
static const interface::VoxelField F_ROCK(MATERIAL_PLANE, 0, 4);
static const interface::VoxelField F_SAND(MATERIAL_PLANE, 4, 4);

// A fraction of a voxel, in the four bits each of these gets. What reads on
// screen is which side of a threshold a mixture is on and not where in the
// range it sits -- this spike's own answer -- so the levels are for the
// arithmetic and not for the eye.
static const int FRACTION_MAX = 15;
// Over this much of a voxel and it is that material
static const int FRACTION_THRESHOLD = 8;

// The samples stand in a wall facing the camera: ten columns of a row run
// along x, the rows are stacked in y, and all of them sit at one z. A grid
// read like a chart rather than a scene, which is the point of a spike.
static const int COLUMNS = 10;
static const int ROWS = 5;
static const int SAMPLE_S = 3;
static const int SAMPLE_STEP_X = 5;
static const int SAMPLE_STEP_Y = 5;
static const int GRID_X0 = 8;
static const int GRID_Y0 = 11;
static const int GRID_Z0 = 34;

// A sample: what the fields of every voxel in one block are set to
struct Sample
{
	int rock = 0;
	int sand = 0;
	int tint = 0;
	int wetness = 0;
	int grain = 0;
	int gloss = 0;
	int sag_top = 0;
};

// Row 0  sag, on sand -- lowest, because it is the one whose top faces have
//        to be seen and the camera looks down on the wall
// Row 1  rock to sand, dry
// Row 2  rock to sand, soaked
// Row 3  dry to soaked, on sand
// Row 4  no binder to all binder, on sand
//
// The base look is chosen by a threshold over the rock fraction, which is
// what demo_aggregate itself will do; everything else about the sample is a
// modifier refining that base. So the ten columns of row 0 are two textures
// and eight refinements of them, and whether that reads is the question.
static Sample sample_at(int row, int col)
{
	// 0...1 across the row
	const float f = COLUMNS > 1 ? (float)col / (float)(COLUMNS - 1) : 0.0f;
	auto q = [](float v){
		int i = (int)(v * 15.0f + 0.5f);
		return i < 0 ? 0 : (i > 15 ? 15 : i);
	};
	auto frac = [](float v){
		int i = (int)(v * (float)FRACTION_MAX + 0.5f);
		return i < 0 ? 0 : (i > FRACTION_MAX ? FRACTION_MAX : i);
	};
	Sample s;
	// Every row but the two mixture ones is sand
	s.sand = FRACTION_MAX;
	switch(row){
	case 0:
		s.sag_top = q(f);
		break;
	case 1:
	case 2:
		// The sand fraction runs 0...1 and the rock's is what is left. No
		// id is written: which of the two definitions the voxel wears comes
		// out of the look rules, which are a threshold over these. The
		// grain says how much sand is in it whichever way the threshold
		// went.
		s.rock = frac(1.0f - f);
		s.sand = frac(f);
		s.grain = q(f);
		if(row == 2){
			s.tint = 15;
			s.wetness = 15;
		}
		break;
	case 3:
		s.tint = q(f);
		s.wetness = q(f);
		break;
	case 4:
		s.gloss = q(f);
		break;
	}
	return s;
}

// A sample's voxel, under the format below: the word of the first plane and
// the fractions of the second
static interface::VoxelSample voxel_of(const interface::VoxelFormat &f,
		const Sample &s)
{
	interface::VoxelSample v;
	f.id.set(v, PRESENT_ID);
	f.light_sky.set(v, f.light_sky.mask());
	f.tint.set(v, s.tint);
	f.wetness.set(v, s.wetness);
	f.grain.set(v, s.grain);
	f.gloss.set(v, s.gloss);
	f.sag_top.set(v, s.sag_top);
	F_ROCK.set(v, s.rock);
	F_SAND.set(v, s.sand);
	return v;
}

static interface::VoxelFormat look_format()
{
	interface::VoxelFormat f;
	f.id = VoxelField(0, 0, 4);
	f.light_sky = VoxelField(0, 4, 4);
	// Four surface modifiers, which is all there is room for, and one
	// geometry modifier, which does not count against them
	f.tint = VoxelField(0, 8, 4);
	f.wetness = VoxelField(0, 12, 4);
	f.grain = VoxelField(0, 16, 4);
	f.gloss = VoxelField(0, 20, 4);
	f.sag_top = VoxelField(0, 24, 4);
	// A second plane, eight bits, for the fractions. Nothing binds a role
	// to it: the rules below read it, and the game writes it.
	f.planes.push_back(interface::VoxelPlane("sample_material_wall:material", 8));
	return f;
}

// The look rules: which definition a voxel wears, as a threshold over the
// fractions rather than a type id to look up. Rock first, so a voxel that is
// half of each reads as the one that holds a structure up; then sand; then
// everything left, which is air.
static interface::VoxelSelector look_selector()
{
	interface::VoxelSelector s;
	s.kind = interface::VoxelSelector::RULES;
	s.fallback = AIR_DEF;
	{
		interface::VoxelRule r;
		r.clauses.push_back(interface::VoxelRuleClause(
				F_ROCK, FRACTION_THRESHOLD, FRACTION_MAX));
		r.result = ROCK_DEF;
		s.rules.push_back(r);
	}
	{
		interface::VoxelRule r;
		r.clauses.push_back(interface::VoxelRuleClause(
				F_SAND, FRACTION_THRESHOLD, FRACTION_MAX));
		r.result = SAND_DEF;
		s.rules.push_back(r);
	}
	return s;
}

struct Worldgen: public worldgen::GeneratorInterface
{
	interface::VoxelFormat m_format = look_format();

	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
		const pv::Region region = volume.getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();

		// The volume comes with the plane the engine's roles are in; the
		// fractions are this game's own and it asks for their plane here
		volume.add_planes(m_format.planes);

		Sample air;
		const interface::VoxelSample air_v = voxel_of(m_format, air);
		Sample floor;
		floor.rock = FRACTION_MAX;
		const interface::VoxelSample floor_v = voxel_of(m_format, floor);

		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					volume.set_sample_at(x, y, z,
							y < FLOOR_TOP ? floor_v : air_v);
				}
			}
		}

		for(int row = 0; row < ROWS; row++){
			for(int col = 0; col < COLUMNS; col++){
				const interface::VoxelSample v =
						voxel_of(m_format, sample_at(row, col));
				const int x0 = GRID_X0 + col * SAMPLE_STEP_X;
				const int y0 = GRID_Y0 + row * SAMPLE_STEP_Y;
				for(int dz = 0; dz < SAMPLE_S; dz++){
					for(int dy = 0; dy < SAMPLE_S; dy++){
						for(int dx = 0; dx < SAMPLE_S; dx++){
							const pv::Vector3DInt32 p(x0 + dx, y0 + dy,
									GRID_Z0 + dz);
							if(!region.containsPoint(p))
								continue;
							volume.set_sample_at(p.getX(), p.getY(),
									p.getZ(), v);
						}
					}
				}
			}
		}
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	SceneReference m_main_scene;
	Worldgen *m_worldgen = nullptr;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
	}

	// The six numbers after solid describe the surface; see interface/atlas.h
	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool solid,
			uint32_t tint_from = 0xffffff, uint32_t tint_to = 0xffffff,
			float sag_extent = 0.0f)
	{
		interface::VoxelDefinition vdef;
		vdef.name.block_name = name;
		vdef.handler_module = "";
		for(size_t i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = vdef.textures[i];
			seg.resource_name = texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
			seg.roughness = 0.9f;
			seg.spec_strength = 0.7f;
			seg.bumpiness = 0.8f;
		}
		vdef.edge_material_id = solid ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		vdef.fully_empty = !solid;
		vdef.tint_ramp[0] = tint_from;
		vdef.tint_ramp[1] = tint_to;
		vdef.sag_extent = sag_extent;
		reg->add_voxel(vdef);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();
		});

		worldgen::access(m_server, [&](worldgen::Interface *iworldgen)
		{
			iworldgen->create_instance(m_main_scene);
			m_worldgen = new Worldgen();
			iworldgen->get_instance(m_main_scene)->set_generator(m_worldgen);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			pv::Region region(0, 0, 0, 0, 0, 0);
			ivoxelworld->create_instance(m_main_scene, region, false);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world = ivoxelworld->
					get_instance(m_main_scene);
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			reg->set_format(look_format());
			add_voxel(reg, "air", "", false);                    // AIR_DEF
			// The tint darkens a material as it takes water. A sag of a
			// full field takes most of a voxel, so that it can be seen.
			add_voxel(reg, "rock", "main/rock.png", true,
					0xffffff, 0x6a7280, 0.8f);                   // ROCK_DEF
			add_voxel(reg, "sand", "main/sand.png", true,
					0xffffff, 0x8a7550, 0.8f);                   // SAND_DEF
			// After the definitions, because the rules point at them
			reg->set_look_selector(look_selector());

			world->set_skylight_enabled(true);
			log_v(MODULE, "sample_material_wall: %s",
					cs(reg->get_format().dump()));
		});

		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			instance->enable();
		});
	}

	void on_unload()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_main_scene);
		});
	}

	void on_continue()
	{
		on_start();
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
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
