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
#include "interface/noise.h"
#include "interface/polyvox_std.h"
#include "interface/polyvox_cereal.h"
#include <cereal/archives/portable_binary.hpp>
#include <cmath>
#include <cstdio>
#include <sstream>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelVolume;
using main_context::SceneReference;

namespace main {

using namespace Urho3D;

// 2x2x2 sections of 64x64x64 voxels each, so the world is 128 voxels on a side
// and there are three section boundary planes through it, at x=64, y=64 and
// z=64. Everything below is placed against those planes: the point of this
// scene is that the light has to cross them.
static const int SECTIONS_PER_AXIS = 2;
static const int SECTION_SIZE = 64;
static const int WORLD_SIZE = SECTIONS_PER_AXIS * SECTION_SIZE;
// This is voxel_lighting's scene, unchanged, moved to a position in the larger
// world where the three section boundary planes cut through it awkwardly. The
// terrain keeps going past it to fill the rest of the world, which is the only
// thing that looks different: the same view of the same cave, with terrain
// running off the edges of the frame instead of a floating 64 voxel block.
//
// SCENE_OFFSET is where voxel_lighting's origin lands. It puts the planes at
// scene x=57, y=29 and z=28, which the cave crosses at a fortieth, an eighth
// and three quarters of its length: one boundary two voxels inside the mouth
// where the light gradient is steepest, one just under the surface there, and
// one far down the tunnel where there is almost no light left. The cave runs
// through four sections that way. Putting the mouth on the corner where all
// eight meet looks like the hardest case and is not, because the cave then
// leaves through one octant at once and spends the rest of its length in it.
static const int SCENE_SIZE = SECTION_SIZE;
static const int SCENE_OFFSET_X = 7;
static const int SCENE_OFFSET_Y = 35;
static const int SCENE_OFFSET_Z = 36;
// Terrain feature size, as in voxel_lighting: one hill and one valley per 64
static const int TERRAIN_SPREAD = SCENE_SIZE;

// The cave runs along the camera's view direction so the camera looks straight
// into it. Kept in sync with client_lua/init.lua by hand; there are only two
// of them and the client cannot tell the server what it is looking at.
static const float VIEW_DIR_X = -1.0f;
static const float VIEW_DIR_Y = -0.7f;
static const float VIEW_DIR_Z = -1.0f;

// Tuned so the surface keeps sky above it and rock below it across the volume.
// Retuned twice with voxel_lighting's and for the same reasons -- the noise
// hash, and then the shape the hash gives: the cave has to break out of a
// hillside, and with the old numbers the mouth stood on flat ground and the
// shaft's cap landed on the mouth. See voxel_lighting's own main.cpp, where
// the four knobs and the search that set them are written down.
static const float TERRAIN_AMPLITUDE = 22.0f;

// Shifts the terrain within the scene, as in voxel_lighting, where 15 puts
// the surface at roughly scene y=18..45. SCENE_OFFSET_Y does the moving here.
static const float GROUND_OFFSET = 15.0f;

// Which field the terrain is, and how far in from the far corner of the scene
// the cave's mouth sits. Both are voxel_lighting's, because this is the same
// scene spread over several sections.
static const int TERRAIN_SEED = 17;
static const int CAVE_MOUTH_INSET = 14;

// How far from the mouth's own column a tree has to stand; voxel_lighting's
// again, and for the same reason: a canopy in the doorway hides what both
// cave cameras are pointed at.
static const int TREE_MOUTH_CLEARANCE = 7;

static const float CAVE_RADIUS = 3.5f;
static const float CAVE_LENGTH = 62.0f;

// The cave is the view direction rotated about the vertical axis through the
// centre of the volume, so that it does not run straight away from the camera.
// Positive is clockwise seen from above.
static const float CAVE_YAW_DEGREES = 20.0f;

// The benchmark edits: a shaft dug straight up out of the cave to the open air,
// and a slab hung over the cave mouth. The shaft starts this far along the cave
// axis, which is deep enough that the skylight there is 0 before it is dug, so
// what the relight has to do is bring a whole column of daylight into a part of
// the scene that had none. It is also in front of benchmark camera 3, so the
// change shows from inside the cave as well as from above.
static const float BENCH_SHAFT_T = 20.0f;
static const int BENCH_SHAFT_W = 3;
static const int BENCH_SLAB_W = 5;
static const int BENCH_SLAB_H = 2;

static const uint8_t AIR_ID = 1;

// Trees are placed one per cell of a grid over the world rather than by a
// count per section, so that they do not depend on which section is being
// generated. The cell size is voxel_lighting's density: it put ten trees in a
// 64x64 section. TREE_MARGIN is how far a tree reaches out of its own column,
// and so how far outside a section one can still be rooted and reach into it.
static const int TREE_CELL = 20;
static const int TREE_MARGIN = 3;
static const int TREE_SEED = 777;

// Rounds towards minus infinity, which is what turns a world coordinate into
// the coordinate of the cell containing it on the negative side of the origin
static int floor_div(int a, int b)
{
	return (a >= 0) ? (a / b) : -(((-a) + b - 1) / b);
}

struct Worldgen: public worldgen::GeneratorInterface
{
	// The client places its benchmark cameras relative to the cave, so it is
	// told where the cave ended up rather than recomputing it from a copy of
	// these constants.
	bool cave_valid = false;
	float cave_mouth[3] = {0, 0, 0};
	float cave_dir[3] = {0, 0, 0};

	// Where the benchmark edits go. Both sit on the +X +Z side of the cave
	// mouth, which is the side both benchmark cameras look from, and the slab
	// floats above the sight line rather than across it.
	pv::Vector3DInt32 bench_shaft_centre;  // BENCH_SHAFT_W^2 x bench_shaft_h
	int bench_shaft_h = 0;
	pv::Vector3DInt32 bench_slab_centre;   // BENCH_SLAB_W x 2 x BENCH_SLAB_W
	bool bench_valid = false;

	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
		{
			const pv::Region region = volume.getEnclosingRegion();
			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();

			const int W = uc.getX() - lc.getX() + 1;
			const int H = uc.getY() - lc.getY() + 1;
			const int D = uc.getZ() - lc.getZ() + 1;

			// Everything is a function of world position rather than of
			// position in the section, so that the eight sections join up.
			// The noise is taken over a slightly larger area than the section,
			// so that a tree rooted just outside it can still be asked how
			// high the ground under it is.
			const int M = TREE_MARGIN;
			const int nx0 = lc.getX() - M, nz0 = lc.getZ() - M;
			const int nw = W + 2*M, nd = D + 2*M;

			// Digger's terrain, but with the low frequencies dropped. Digger
			// spreads its first octave over 160 voxels, which inside a 64
			// voxel box reads as a tilt rather than as terrain.
			interface::v3f spread(TERRAIN_SPREAD, TERRAIN_SPREAD,
					TERRAIN_SPREAD);
			// Digger's amplitude is set for its own much longer wavelength;
			// at this one it would swing the surface across the whole volume.
			interface::NoiseParams np(0, TERRAIN_AMPLITUDE, spread, 0, 5, 0.4);
			// Sampled at scene coordinates, so the terrain under the cave is
			// the terrain voxel_lighting's cave was carved into
			interface::Noise noise(&np, TERRAIN_SEED, nw, nd);
			noise.fbmMap2D(nx0 - SCENE_OFFSET_X + spread.X/2,
					nz0 - SCENE_OFFSET_Z + spread.Z/2);
			noise.transformNoiseMap();

			auto have_column = [&](int x, int z){
				return x >= nx0 && x < nx0 + nw && z >= nz0 && z < nz0 + nd;
			};
			auto surface_at = [&](int x, int z) -> float {
				size_t i = (size_t)(z - nz0) * nw + (x - nx0);
				return noise.result[i] + GROUND_OFFSET + SCENE_OFFSET_Y;
			};

			// TUNING: pick a cave mouth whose cave stays under the terrain
			if(section_p == pv::Vector3DInt16(0, 0, 0)){
				interface::Noise wn(&np, TERRAIN_SEED, WORLD_SIZE, WORLD_SIZE);
				wn.fbmMap2D(spread.X/2, spread.Z/2);
				wn.transformNoiseMap();
				auto wnoise = [&](int x, int z){
					if(x < 0 || x >= WORLD_SIZE || z < 0 || z >= WORLD_SIZE)
						return -1e9f;
					return wn.result[(size_t)z * WORLD_SIZE + x];
				};
				float ca2 = std::cos(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
				float sa2 = std::sin(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
				float rdx2 = VIEW_DIR_X * ca2 + VIEW_DIR_Z * sa2;
				float rdz2 = -VIEW_DIR_X * sa2 + VIEW_DIR_Z * ca2;
				float dl2 = std::sqrt(rdx2*rdx2 + VIEW_DIR_Y*VIEW_DIR_Y +
						rdz2*rdz2);
				float ddx = rdx2/dl2, ddy = VIEW_DIR_Y/dl2, ddz = rdz2/dl2;
				float best = -1e9f; int bx = 0, bz = 0;
				for(int x0 = SECTION_SIZE; x0 <= SECTION_SIZE + 8; x0++){
				for(int z0 = SECTION_SIZE + 8; z0 <= SECTION_SIZE + 24; z0++){
					float n0 = wnoise(x0, z0);
					float worst = 1e9f;
					for(float t = 6.0f; t <= CAVE_LENGTH; t += 1.0f){
						int px = (int)std::floor(x0 + ddx*t + 0.5f);
						int pz = (int)std::floor(z0 + ddz*t + 0.5f);
						float c = wnoise(px, pz) - n0 - CAVE_RADIUS - ddy*t;
						if(c < worst) worst = c;
					}
					if(worst > best){ best = worst; bx = x0; bz = z0; }
				}
				}
				log_v(MODULE, "TUNING: best mouth x=%i z=%i, worst clearance "
						"%.1f (x crosses t=%.1f, z crosses t=%.1f)", bx, bz,
						best, (bx - 64) / -ddx, (bz - 64) / -ddz);
			}

			const uint8_t AIR = AIR_ID;
			sv_<uint8_t> ids((size_t)W * H * D, AIR);
			auto idx = [&](int x, int y, int z) -> size_t {
				return ((size_t)(y - lc.getY()) * D + (z - lc.getZ())) * W +
						(x - lc.getX());
			};
			auto inside = [&](int x, int y, int z){
				return x >= lc.getX() && x <= uc.getX() &&
						y >= lc.getY() && y <= uc.getY() &&
						z >= lc.getZ() && z <= uc.getZ();
			};
			auto set_id = [&](int x, int y, int z, uint8_t id){
				if(inside(x, y, z))
					ids[idx(x, y, z)] = id;
			};

			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					float a = surface_at(x, z);
					for(int y = lc.getY(); y <= uc.getY(); y++){
						if(y < a + 5)
							set_id(x, y, z, 2);
						else if(y < a + 10)
							set_id(x, y, z, 3);
						else if(y < a + 11)
							set_id(x, y, z, 4);
						else
							set_id(x, y, z, AIR);
					}
				}
			}

			// Where the cave's mouth will be, before anything is planted:
			// nothing may grow in the doorway. The same arithmetic as the
			// cave's own below, on the scene box rather than on a section.
			int mouth_x, mouth_z;
			{
				float mca = std::cos(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
				float msa = std::sin(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
				float mcx = SCENE_OFFSET_X + SCENE_SIZE / 2.0f;
				float mcz = SCENE_OFFSET_Z + SCENE_SIZE / 2.0f;
				float mox = (SCENE_OFFSET_X + SCENE_SIZE - 1 -
						CAVE_MOUTH_INSET) - mcx;
				float moz = (SCENE_OFFSET_Z + SCENE_SIZE - 1 -
						CAVE_MOUTH_INSET) - mcz;
				mouth_x = (int)std::floor(mcx + mox * mca + moz * msa + 0.5f);
				mouth_z = (int)std::floor(mcz - mox * msa + moz * mca + 0.5f);
			}

			// Trees, for something that casts a shadow with a shape to it.
			// One per cell of a grid laid over the world, placed by a random
			// number seeded from the cell, so that a tree lands in the same
			// place whichever section is being generated and one growing over
			// a boundary comes out whole from both sides. Cells reaching a
			// little outside the section are visited for exactly that reason.
			for(int cz = floor_div(lc.getZ() - M, TREE_CELL);
					cz <= floor_div(uc.getZ() + M, TREE_CELL); cz++){
			for(int cx = floor_div(lc.getX() - M, TREE_CELL);
					cx <= floor_div(uc.getX() + M, TREE_CELL); cx++){
				auto pr = interface::PseudoRandom(
						TREE_SEED + cx * 73856093 + cz * 19349663);
				int x = cx * TREE_CELL + pr.range(0, TREE_CELL - 1);
				int z = cz * TREE_CELL + pr.range(0, TREE_CELL - 1);
				if(!have_column(x, z))
					continue;
				// A canopy is five voxels across, so this keeps the whole of
				// it out of the mouth rather than only its trunk
				if(std::abs(x - mouth_x) <= TREE_MOUTH_CLEARANCE &&
						std::abs(z - mouth_z) <= TREE_MOUTH_CLEARANCE)
					continue;
				int y = (int)(surface_at(x, z) + 11.0f);

				for(int y1 = y; y1 < y + 4; y1++)
					set_id(x, y1, z, 6);
				for(int x1 = x-2; x1 <= x+2; x1++)
					for(int y1 = y+3; y1 <= y+7; y1++)
						for(int z1 = z-2; z1 <= z+2; z1++)
							set_id(x1, y1, z1, 5);
			}
			}

			// Carve the cave with a sphere swept along the view direction
			// yawed by CAVE_YAW_DEGREES, starting in the air just above the
			// ground so that it breaks the surface and leaves a mouth instead
			// of a sealed pocket. The whole sweep is walked in every section
			// and clipped to it, which is what makes the cave one feature
			// rather than eight.
			float ca = std::cos(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
			float sa = std::sin(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
			float rdx = VIEW_DIR_X * ca + VIEW_DIR_Z * sa;
			float rdz = -VIEW_DIR_X * sa + VIEW_DIR_Z * ca;
			float dl = std::sqrt(rdx*rdx + VIEW_DIR_Y*VIEW_DIR_Y + rdz*rdz);
			float dx = rdx / dl, dy = VIEW_DIR_Y / dl, dz = rdz / dl;

			// voxel_lighting's mouth, worked out from the corner of the scene
			// box rather than of a section, since the scene is no longer one
			auto rot_x = [&](float x, float z){ return x * ca + z * sa; };
			auto rot_z = [&](float x, float z){ return -x * sa + z * ca; };
			float centre_x = SCENE_OFFSET_X + SCENE_SIZE / 2.0f;
			float centre_z = SCENE_OFFSET_Z + SCENE_SIZE / 2.0f;
			// mouth_x and mouth_z are the ones worked out above the trees,
			// which had to know where the doorway is before planting any

			// Every section carves the whole cave and clips it, so every one
			// of them needs the ground height at the mouth, which is only in
			// the noise map of the sections the mouth is over. One extra
			// sample of the same noise gives it to all of them.
			interface::Noise mouth_noise(&np, TERRAIN_SEED, 1, 1);
			mouth_noise.fbmMap2D(mouth_x - SCENE_OFFSET_X + spread.X/2,
					mouth_z - SCENE_OFFSET_Z + spread.Z/2);
			mouth_noise.transformNoiseMap();
			float mouth_surface = mouth_noise.result[0] + GROUND_OFFSET +
					SCENE_OFFSET_Y;

			float sx = mouth_x;
			float sz = mouth_z;
			float sy = mouth_surface + 11.0f + CAVE_RADIUS;

			size_t carved = 0;
			for(float t = 0.f; t <= CAVE_LENGTH; t += 0.5f){
				float cx = sx + dx * t, cy = sy + dy * t, cz = sz + dz * t;
				int x0 = (int)std::floor(cx - CAVE_RADIUS);
				int x1 = (int)std::ceil(cx + CAVE_RADIUS);
				int y0 = (int)std::floor(cy - CAVE_RADIUS);
				int y1 = (int)std::ceil(cy + CAVE_RADIUS);
				int z0 = (int)std::floor(cz - CAVE_RADIUS);
				int z1 = (int)std::ceil(cz + CAVE_RADIUS);
				for(int z = z0; z <= z1; z++){
					for(int y = y0; y <= y1; y++){
						for(int x = x0; x <= x1; x++){
							if(!inside(x, y, z))
								continue;
							float ddx = x - cx, ddy = y - cy, ddz = z - cz;
							if(ddx*ddx + ddy*ddy + ddz*ddz >
									CAVE_RADIUS * CAVE_RADIUS)
								continue;
							ids[idx(x, y, z)] = AIR;
							carved++;
						}
					}
				}
			}
			cave_mouth[0] = sx;
			cave_mouth[1] = sy;
			cave_mouth[2] = sz;
			cave_dir[0] = dx;
			cave_dir[1] = dy;
			cave_dir[2] = dz;
			cave_valid = true;

			// The shaft goes straight up out of the cave to the open air; the
			// slab caps it. Together they swap where the cave gets its light
			// from, which is the thing the relight has to get right. Worked
			// out in whichever sections have the noise for that column under
			// them, which all give the same answer.
			int shaft_x = (int)std::floor(sx + dx * BENCH_SHAFT_T + 0.5f);
			int shaft_z = (int)std::floor(sz + dz * BENCH_SHAFT_T + 0.5f);
			if(have_column(shaft_x, shaft_z)){
				int shaft_bottom =
						(int)std::floor(sy + dy * BENCH_SHAFT_T + 0.5f);
				// surface_at() + 11 is the first air voxel above the ground,
				// so this breaks the surface open rather than stopping under
				// it. The shaft goes one voxel past that, which is where the
				// cap sits, so digging it again cuts the cap out and the two
				// edits can be cycled for as long as anyone wants to watch.
				int shaft_top =
						(int)std::floor(surface_at(shaft_x, shaft_z)) + 11;
				if(shaft_top < shaft_bottom)
					shaft_top = shaft_bottom;
				// A box of height h centred at c covers c-(h/2) .. c+(h-1)/2
				bench_shaft_h = (shaft_top + 1) - shaft_bottom + 1;
				bench_shaft_centre = pv::Vector3DInt32(shaft_x,
						shaft_bottom + bench_shaft_h / 2, shaft_z);
				// The cap fills the two air voxels directly above the ground,
				// so the second edit takes back the light the first let in
				bench_slab_centre = pv::Vector3DInt32(shaft_x,
						shaft_top + 1, shaft_z);
				bench_valid = true;
				log_v(MODULE, "Bench: shaft " PV3I_FORMAT " h %i, cap "
						PV3I_FORMAT, PV3I_PARAMS(bench_shaft_centre),
						bench_shaft_h, PV3I_PARAMS(bench_slab_centre));
			}

			log_v(MODULE, "Section " PV3I_FORMAT " voxels " PV3I_FORMAT ".."
					PV3I_FORMAT ": %zu cave brush writes",
					PV3I_PARAMS(section_p), PV3I_PARAMS(lc), PV3I_PARAMS(uc),
					carved);

			// voxelworld keeps the skylight of every voxel up to date from
			// here on, so these go in as plain ids
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int z = lc.getZ(); z <= uc.getZ(); z++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						volume.setVoxelAt(pv::Vector3DInt32(x, y, z),
								VoxelInstance(ids[idx(x, y, z)]));
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
		m_server->sub_event(this, Event::t("worldgen:queue_modified"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:bench_shaft"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:bench_slab"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:verify_skylight"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("worldgen:queue_modified",
				on_worldgen_queue_modified, worldgen::QueueModifiedEvent)
		EVENT_TYPEN("network:packet_received/main:dig_voxel",
				on_dig_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:place_voxel",
				on_place_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:bench_shaft",
				on_bench_shaft, network::Packet)
		EVENT_TYPEN("network:packet_received/main:bench_slab",
				on_bench_slab, network::Packet)
		EVENT_TYPEN("network:packet_received/main:verify_skylight",
				on_verify_skylight, network::Packet)
	}

	// The six numbers after solid describe the surface; see interface/atlas.h
	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool solid, bool fully_empty,
			float roughness = 0.9f,
			float spec_strength = 1.0f, float bumpiness = 1.0f,
			float translucency = 0.0f, float spots = 0.0f,
			float static_spots = 0.0f)
	{
		interface::VoxelDefinition vdef;
		vdef.name.block_name = name;
		vdef.name.segment_x = 0;
		vdef.name.segment_y = 0;
		vdef.name.segment_z = 0;
		vdef.name.rotation_primary = 0;
		vdef.name.rotation_secondary = 0;
		vdef.handler_module = "";
		for(size_t i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = vdef.textures[i];
			seg.resource_name = texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
			seg.roughness = roughness;
			seg.spec_strength = spec_strength;
			seg.bumpiness = bumpiness;
			seg.translucency = translucency;
			seg.spots = spots;
			seg.static_spots = static_spots;
		}
		vdef.edge_material_id = solid ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		vdef.fully_empty = fully_empty;
		reg->add_voxel(vdef);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();
		});

		// Worldgen must be created before the voxelworld; otherwise initial
		// generation request events are lost
		worldgen::access(m_server, [&](worldgen::Interface *iworldgen)
		{
			iworldgen->create_instance(m_main_scene);
			m_worldgen = new Worldgen();
			iworldgen->get_instance(m_main_scene)->set_generator(m_worldgen);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			// 2x2x2 sections: the whole scene, never streamed
			pv::Region region(0, 0, 0, SECTIONS_PER_AXIS - 1,
					SECTIONS_PER_AXIS - 1, SECTIONS_PER_AXIS - 1);
			ivoxelworld->create_instance(m_main_scene, region);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			interface::VoxelRegistry *reg = ivoxelworld->
					get_instance(m_main_scene)->get_voxel_reg();
			// 0.6's cut, which its saves, its checks and its code were written
			// for
			reg->set_format(interface::VoxelFormat::buildat_legacy_06());
			add_voxel(reg, "air", "", false, true);              // id 1
			// Same surfaces as voxel_lighting; see its README
			add_voxel(reg, "rock", "main/rock.png", true, false,
					0.95f, 0.15f, 0.5f, 0.0f, 0.0f, 0.04f); // id 2
			add_voxel(reg, "dirt", "main/dirt.png", true, false,
					0.98f, 0.15f, 0.6f, 0.0f, 0.0f, 0.04f); // id 3
			add_voxel(reg, "grass", "main/grass.png", true, false,
					0.90f, 1.0f, 0.75f, 0.06f, 0.012f); // id 4
			add_voxel(reg, "leaves", "main/leaves.png", true, false,
					0.95f, 1.0f, 1.5f, 0.11f, 0.03f); // id 5
			add_voxel(reg, "tree", "main/tree.png", true, false,
					0.85f, 0.35f, 2.0f); // id 6

			// The whole point of this scene: let voxelworld light it
			ivoxelworld->get_instance(m_main_scene)->
					set_skylight_enabled(true);
		});

		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			instance->enable();
		});

		log_v(MODULE, "multisection_lighting: %ix%ix%i voxels in %ix%ix%i "
				"sections", WORLD_SIZE, WORLD_SIZE, WORLD_SIZE,
				SECTIONS_PER_AXIS, SECTIONS_PER_AXIS, SECTIONS_PER_AXIS);
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

	// "mx my mz dx dy dz"; the client turns it into camera positions
	ss_ cave_packet()
	{
		char buf[160];
		snprintf(buf, sizeof buf, "%f %f %f %f %f %f",
				m_worldgen->cave_mouth[0], m_worldgen->cave_mouth[1],
				m_worldgen->cave_mouth[2], m_worldgen->cave_dir[0],
				m_worldgen->cave_dir[1], m_worldgen->cave_dir[2]);
		return buf;
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
		network::access(m_server, [&](network::Interface *inetwork){
			// Generation normally finishes long before anyone connects; if it
			// has not, on_worldgen_queue_modified() sends this instead
			if(m_worldgen && m_worldgen->cave_valid)
				inetwork->send(event.recipient, "main:cave", cave_packet());
		});
	}

	void edit_voxel(const pv::Vector3DInt32 &p, uint32_t id)
	{
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			world->set_voxel(p, VoxelInstance(id));
		});
	}

	pv::Vector3DInt32 read_voxel_p(const network::Packet &packet)
	{
		pv::Vector3DInt32 p;
		std::istringstream is(packet.data, std::ios::binary);
		cereal::PortableBinaryInputArchive ar(is);
		ar(p);
		return p;
	}

	void on_dig_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 p = read_voxel_p(packet);
		log_v(MODULE, "C%i: dig " PV3I_FORMAT, packet.sender, PV3I_PARAMS(p));
		edit_voxel(p, AIR_ID);
	}

	void on_place_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 p = read_voxel_p(packet);
		log_v(MODULE, "C%i: place " PV3I_FORMAT, packet.sender, PV3I_PARAMS(p));
		edit_voxel(p, 2); // rock
	}

	// The two benchmark edits. Their positions come from worldgen so that they
	// stay next to the cave mouth whatever the terrain noise does.
	void bench_box(const pv::Vector3DInt32 &centre, int w, int h, int d,
			uint32_t id)
	{
		if(!m_worldgen || !m_worldgen->bench_valid){
			log_w(MODULE, "bench_box(): world is not generated yet");
			return;
		}
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int y = -(h/2); y <= (h-1)/2; y++)
			for(int z = -(d/2); z <= (d-1)/2; z++)
			for(int x = -(w/2); x <= (w-1)/2; x++){
				world->set_voxel(pv::Vector3DInt32(centre.getX() + x,
						centre.getY() + y, centre.getZ() + z),
						VoxelInstance(id), true);
			}
		});
		log_v(MODULE, "bench_box(): %ix%ix%i id %i at " PV3I_FORMAT,
				w, h, d, id, PV3I_PARAMS(centre));
	}

	void on_bench_shaft(const network::Packet &packet)
	{
		(void)packet;
		if(!m_worldgen) return;
		bench_box(m_worldgen->bench_shaft_centre, BENCH_SHAFT_W,
				m_worldgen->bench_shaft_h, BENCH_SHAFT_W, AIR_ID);
	}

	void on_bench_slab(const network::Packet &packet)
	{
		(void)packet;
		if(!m_worldgen) return;
		bench_box(m_worldgen->bench_slab_centre, BENCH_SLAB_W, BENCH_SLAB_H,
				BENCH_SLAB_W, 2); // rock
	}

	// Check voxelworld's incremental skylight against a flood fill done from
	// scratch over the whole scene. The scene is one section, so the whole
	// thing fits in memory and the two can be compared voxel by voxel; this is
	// what says whether an edit relit everything it should have.
	void verify_skylight()
	{
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			// The whole world, all eight sections of it, so that light which
			// should have crossed a boundary and did not shows up here
			pv::Region region(
					world->get_section_region_voxels(
							pv::Vector3DInt16(0, 0, 0)).getLowerCorner(),
					world->get_section_region_voxels(pv::Vector3DInt16(
							SECTIONS_PER_AXIS - 1, SECTIONS_PER_AXIS - 1,
							SECTIONS_PER_AXIS - 1)).getUpperCorner());
			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();
			const int W = uc.getX() - lc.getX() + 1;
			const int H = uc.getY() - lc.getY() + 1;
			const int D = uc.getZ() - lc.getZ() + 1;
			auto idx = [&](int x, int y, int z){
				return ((size_t)y * D + z) * W + x;
			};
			auto inside = [&](int x, int y, int z){
				return x >= 0 && x < W && y >= 0 && y < H && z >= 0 && z < D;
			};

			sv_<uint8_t> ids((size_t)W * H * D, 0);
			sv_<uint8_t> stored((size_t)W * H * D, 0);
			for(int y = 0; y < H; y++)
			for(int z = 0; z < D; z++)
			for(int x = 0; x < W; x++){
				VoxelInstance v = world->get_voxel(pv::Vector3DInt32(
						lc.getX() + x, lc.getY() + y, lc.getZ() + z), true);
				ids[idx(x, y, z)] = (uint8_t)v.legacy06_id();
				stored[idx(x, y, z)] = v.legacy06_skylight();
			}

			// Straight down at full strength until something stops it, then
			// one step lost per voxel in every direction
			const uint8_t SKY_MAX = VoxelInstance::SKYLIGHT_MAX;
			sv_<uint8_t> sky((size_t)W * H * D, 0);
			for(int z = 0; z < D; z++){
				for(int x = 0; x < W; x++){
					uint8_t l = SKY_MAX;
					for(int y = H - 1; y >= 0; y--){
						size_t i = idx(x, y, z);
						if(ids[i] != AIR_ID)
							l = 0;
						sky[i] = l;
					}
				}
			}
			static const int off[6][3] = {
				{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}
			};
			for(int level = SKY_MAX; level >= 2; level--){
				for(int y = 0; y < H; y++)
				for(int z = 0; z < D; z++)
				for(int x = 0; x < W; x++){
					if(sky[idx(x, y, z)] != level)
						continue;
					for(size_t k = 0; k < 6; k++){
						int nx = x + off[k][0], ny = y + off[k][1];
						int nz = z + off[k][2];
						if(!inside(nx, ny, nz))
							continue;
						size_t ni = idx(nx, ny, nz);
						if(ids[ni] != AIR_ID || sky[ni] >= level - 1)
							continue;
						sky[ni] = level - 1;
					}
				}
			}

			size_t mismatches = 0;
			pv::Vector3DInt32 first(0, 0, 0);
			uint8_t first_want = 0, first_got = 0;
			for(int y = 0; y < H; y++)
			for(int z = 0; z < D; z++)
			for(int x = 0; x < W; x++){
				size_t i = idx(x, y, z);
				uint8_t want = sky[i];
				if(ids[i] != AIR_ID){
					// Voxels that block light hold the brightest light next
					// to them instead
					want = 0;
					for(size_t k = 0; k < 6; k++){
						int nx = x + off[k][0], ny = y + off[k][1];
						int nz = z + off[k][2];
						if(!inside(nx, ny, nz))
							continue;
						size_t ni = idx(nx, ny, nz);
						if(ids[ni] == AIR_ID && sky[ni] > want)
							want = sky[ni];
					}
				}
				if(want == stored[i])
					continue;
				if(mismatches == 0){
					first = pv::Vector3DInt32(lc.getX() + x, lc.getY() + y,
							lc.getZ() + z);
					first_want = want;
					first_got = stored[i];
				}
				mismatches++;
			}
			if(mismatches == 0){
				log_v(MODULE, "skylight verify: ok");
			} else {
				log_w(MODULE, "skylight verify: %zu voxels differ from a "
						"fresh fill; first " PV3I_FORMAT " wants %i, has %i",
						mismatches, PV3I_PARAMS(first), first_want, first_got);
			}
		});
	}

	void on_verify_skylight(const network::Packet &packet)
	{
		(void)packet;
		verify_skylight();
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &event)
	{
		if(event.queue_size != 0 || !m_worldgen || !m_worldgen->cave_valid)
			return;
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &peer : inetwork->list_peers())
				inetwork->send(peer, "main:cave", cave_packet());
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
