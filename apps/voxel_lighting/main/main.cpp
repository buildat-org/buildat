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
#include "interface/server_config.h"
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

// The scene is 64x64x64 voxels, one section. The launch param sections=8
// (the server's -u, a launcher tile's params) puts it in a world of 2x2x2
// sections instead, 128 voxels on a side, so that everything it checks has
// to work across the three section boundary planes at x=64, y=64 and z=64.
// Set at core:start, before worldgen is enabled, and only read after.
static const int SECTION_SIZE = 64;
static const int SCENE_SIZE = SECTION_SIZE;
static int g_sections_per_axis = 1;
// Where the scene's origin lands in the world. With eight sections it puts
// the planes at scene x=57, y=29 and z=28, which the cave crosses at a
// fortieth, an eighth and three quarters of its length: one boundary two
// voxels inside the mouth where the light gradient is steepest, one just
// under the surface there, and one far down the tunnel where there is almost
// no light left. The cave runs through four sections that way. Putting the
// mouth on the corner where all eight meet looks like the hardest case and
// is not, because the cave then leaves through one octant at once and spends
// the rest of its length in it.
static int g_scene_offset[3] = {0, 0, 0};
static const int MULTI_SCENE_OFFSET[3] = {7, 35, 36};
static bool multi(){ return g_sections_per_axis > 1; }

// The cave runs along the camera's view direction so the camera looks straight
// into it. Kept in sync with client_lua/init.lua by hand; there are only two
// of them and the client cannot tell the server what it is looking at.
static const float VIEW_DIR_X = -1.0f;
static const float VIEW_DIR_Y = -0.7f;
static const float VIEW_DIR_Z = -1.0f;

// Tuned so the surface keeps sky above it and rock below it across the volume.
//
// Retuned twice. First on 2026-09-14, when the noise hash stopped multiplying
// in signed arithmetic: the same numbers that gave a surface at 19..45 gave
// one at 7..17, and the amplitude and offset put the band back. That was not
// enough -- the band was right and the *shape* was not, and the scene is
// about a shape: the cave has to break out of a hillside, both because a
// mouth in flat ground is a hole in a floor and because the gradient is what
// these scenes exist to photograph. With the field the fixed hash gives, the
// mouth stood on flat ground (eight voxels along the cave the ground rose by
// one) and the shaft that should break out well up the slope came out *below*
// the mouth, so its cap sat on the mouth instead of up the hill.
//
// So the seed and the mouth's own corner are knobs here now, and the four of
// them were searched together rather than derived: the field is
// interface::Noise, which __luanti_noise_map() hands to Lua, so a probe can
// try thousands of sets against what the scene needs -- a surface inside the
// volume, a mouth part way up it, a cave that stays in the volume to its end,
// a pond with a rim just above its water line, and ground that climbs at the
// mouth. These are what came out: a surface at 18..45 where it used to be
// 19..45, the ground climbing eight voxels over the first eight of the cave,
// and the shaft breaking out thirteen voxels above the mouth.
static const float TERRAIN_AMPLITUDE = 22.0f;

// Shifts the terrain up or down in the volume. With the noise below, 15 puts
// the surface at roughly y=18..45, averaging the middle of the volume. The
// generator logs the range it actually got, so retune this by reading that.
static const float GROUND_OFFSET = 15.0f;

// Which field the terrain is. One number of a different field is one scene of
// a different shape, and the shape is what is being chosen here; see above.
static const int TERRAIN_SEED = 17;

// How far in from the far corner of the volume the cave's mouth sits, before
// the whole cave is rotated about the middle. It decides which part of the
// hill the mouth lands in, so it is searched with the terrain rather than set
// once.
static const int CAVE_MOUTH_INSET = 14;

// How far from the mouth's own column a tree has to stand. A canopy is five
// voxels across and both cave cameras look at the mouth, so one growing in
// the doorway hides what the picture is of.
static const int TREE_MOUTH_CLEARANCE = 7;

static const float CAVE_RADIUS = 3.5f;
// A pond, for a surface smooth enough to reflect the sky where everything else
// in the scene is matte. This terrain has no basin to fill: it is one slope,
// so a water line drawn across it puts the water along the edge of the volume
// and it reads as a sea that the world runs out of rather than as a pond. So a
// basin is dug for it instead, on the flattest ground the generator's surface
// map shows, well away from the cave.
static const int POND_CENTRE_X = 50;
static const int POND_CENTRE_Z = 12;
static const int POND_RADIUS = 9;
static const int POND_DEPTH = 4;
static const int WATER_LEVEL = 31;
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

// With eight sections trees are placed one per cell of a grid over the world
// rather than by a count per section, so that they do not depend on which
// section is being generated and one growing over a boundary comes out whole
// from both sides. The cell size is the one-section density: ten trees in a
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
	bool tree_valid = false;
	float tree_centre[3] = {0, 0, 0};
	bool water_valid = false;
	// Benchmark 4's camera and what it looks at. Worked out here rather than
	// on the client because it needs the terrain height to stay above ground.
	float water_eye[3] = {0, 0, 0};
	float water_target[3] = {0, 0, 0};
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

			const int ox = g_scene_offset[0], oy = g_scene_offset[1];
			const int oz = g_scene_offset[2];
			// Everything is a function of world position rather than of
			// position in the section, so that eight sections join up. With
			// eight the noise is taken over a slightly larger area than the
			// section, so that a tree rooted just outside it can still be
			// asked how high the ground under it is.
			const int M = multi() ? TREE_MARGIN : 0;
			const int nx0 = lc.getX() - M, nz0 = lc.getZ() - M;
			int w = uc.getX() - lc.getX() + 1 + 2*M;
			int d = uc.getZ() - lc.getZ() + 1 + 2*M;

			// Digger's terrain, but with the low frequencies dropped. Digger
			// spreads its first octave over 160 voxels, which inside a 64
			// voxel box reads as a tilt rather than as terrain. Starting at a
			// wavelength of exactly the volume size puts one hill and one
			// valley in the scene, and the octaves below it supply the detail.
			interface::v3f spread(SCENE_SIZE, SCENE_SIZE, SCENE_SIZE);
			// Digger's amplitude is set for its own much longer wavelength;
			// at this one it would swing the surface across the whole volume.
			interface::NoiseParams np(0, TERRAIN_AMPLITUDE, spread, 0, 5, 0.4);
			interface::Noise noise(&np, TERRAIN_SEED, w, d);
			// Sampled at scene coordinates, so the terrain under the cave is
			// the same whichever world the scene is in
			noise.fbmMap2D(nx0 - ox + spread.X/2, nz0 - oz + spread.Z/2);
			noise.transformNoiseMap();

			// Reported so GROUND_OFFSET and TERRAIN_AMPLITUDE can be retuned
			// by reading it, rather than by deriving them at runtime
			float nmin = 1e9f, nmax = -1e9f;
			for(int i = 0; i < w * d; i++){
				float n = noise.result[i];
				if(n < nmin) nmin = n;
				if(n > nmax) nmax = n;
			}
			// Digger draws the topmost solid voxel at a+10, so a+11 is ground
			log_v(MODULE, "noise [%.1f, %.1f] -> surface %.0f..%.0f",
					nmin, nmax, nmin + GROUND_OFFSET + 11.0f,
					nmax + GROUND_OFFSET + 11.0f);

			auto have_column = [&](int x, int z){
				return x >= nx0 && x < nx0 + w && z >= nz0 && z < nz0 + d;
			};
			auto surface_at = [&](int x, int z) -> float {
				size_t i = (size_t)(z - nz0) * w + (x - nx0);
				return noise.result[i] + GROUND_OFFSET + oy;
			};

			// Everything is built into a local array first so that skylight
			// can be flood filled over the finished shape, and so that each
			// voxel is written to the world exactly once, with its light.
			const int W = uc.getX() - lc.getX() + 1;
			const int H = uc.getY() - lc.getY() + 1;
			const int D = uc.getZ() - lc.getZ() + 1;
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

			// Where the cave's mouth will be. Worked out before anything is
			// planted, because nothing may grow in the doorway: the tree
			// that does hides the thing both cave cameras are pointed at.
			float ca = std::cos(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
			float sa = std::sin(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
			auto rot_x = [&](float x, float z){ return x * ca + z * sa; };
			auto rot_z = [&](float x, float z){ return -x * sa + z * ca; };
			// The corner of the scene box, not of a section
			float centre_x = ox + SCENE_SIZE / 2.0f;
			float centre_z = oz + SCENE_SIZE / 2.0f;
			float mox = (ox + SCENE_SIZE - 1 - CAVE_MOUTH_INSET) - centre_x;
			float moz = (oz + SCENE_SIZE - 1 - CAVE_MOUTH_INSET) - centre_z;
			int mouth_x = (int)std::floor(centre_x + rot_x(mox, moz) + 0.5f);
			int mouth_z = (int)std::floor(centre_z + rot_z(mox, moz) + 0.5f);

			// Trees, for something that casts a shadow with a shape to it.
			// Digger's density is a forest; here it would hide the terrain.
			auto plant = [&](int x, int y, int z){
				for(int y1 = y; y1 < y + 4; y1++)
					set_id(x, y1, z, 6);
				for(int x1 = x-2; x1 <= x+2; x1++)
					for(int y1 = y+3; y1 <= y+7; y1++)
						for(int z1 = z-2; z1 <= z+2; z1++)
							set_id(x1, y1, z1, 5);
			};
			// A canopy is five voxels across, so this keeps the whole of it
			// out of the mouth rather than only its trunk
			auto in_doorway = [&](int x, int z){
				return std::abs(x - mouth_x) <= TREE_MOUTH_CLEARANCE &&
						std::abs(z - mouth_z) <= TREE_MOUTH_CLEARANCE;
			};
			if(multi()){
				// One per cell of a grid laid over the world, placed by a
				// random number seeded from the cell. Cells reaching a little
				// outside the section are visited for the trees that reach in.
				for(int cz = floor_div(lc.getZ() - M, TREE_CELL);
						cz <= floor_div(uc.getZ() + M, TREE_CELL); cz++){
				for(int cx = floor_div(lc.getX() - M, TREE_CELL);
						cx <= floor_div(uc.getX() + M, TREE_CELL); cx++){
					auto pr = interface::PseudoRandom(
							TREE_SEED + cx * 73856093 + cz * 19349663);
					int x = cx * TREE_CELL + pr.range(0, TREE_CELL - 1);
					int z = cz * TREE_CELL + pr.range(0, TREE_CELL - 1);
					if(!have_column(x, z) || in_doorway(x, z))
						continue;
					plant(x, (int)(surface_at(x, z) + 11.0f), z);
				}
				}
			} else {
				auto pr = interface::PseudoRandom(TREE_SEED);
				for(int i = 0; i < W * D / 400; i++){
					int x = pr.range(lc.getX() + 3, uc.getX() - 3);
					int z = pr.range(lc.getZ() + 3, uc.getZ() - 3);
					int y = (int)(surface_at(x, z) + 11.0f);
					if(y < lc.getY() || y > uc.getY() - 8)
						continue;
					if(in_doorway(x, z))
						continue;
					plant(x, y, z);

					// Keep the most central tree for benchmark 5, which looks
					// at a canopy with the sun behind it. Central so that the
					// camera it puts on the far side of the tree is still in
					// the scene.
					float cdx = x - (lc.getX() + SCENE_SIZE / 2.0f);
					float cdz = z - (lc.getZ() + SCENE_SIZE / 2.0f);
					float bdx = tree_centre[0] - (lc.getX() + SCENE_SIZE / 2.0f);
					float bdz = tree_centre[2] - (lc.getZ() + SCENE_SIZE / 2.0f);
					if(!tree_valid ||
							cdx * cdx + cdz * cdz < bdx * bdx + bdz * bdz){
						tree_centre[0] = x;
						tree_centre[1] = y + 5;
						tree_centre[2] = z;
						tree_valid = true;
					}
				}
			}

			// Dig the basin and fill it. Done before the cave is carved, so
			// the cave stays dry however far below the water line it runs.
			// The floor is a bowl that meets the water line at the rim, which
			// leaves a shoreline instead of a wall of water. One section's
			// scene only: the pond and its benchmark are the materials', and
			// eight sections are for the light across boundaries.
			if(!multi())
			for(int z = POND_CENTRE_Z - POND_RADIUS;
					z <= POND_CENTRE_Z + POND_RADIUS; z++){
				for(int x = POND_CENTRE_X - POND_RADIUS;
						x <= POND_CENTRE_X + POND_RADIUS; x++){
					float dx = x - POND_CENTRE_X, dz = z - POND_CENTRE_Z;
					float d2 = (dx * dx + dz * dz) /
							(float)(POND_RADIUS * POND_RADIUS);
					if(d2 > 1.0f)
						continue;
					int floor_y = WATER_LEVEL -
							(int)(POND_DEPTH * (1.0f - d2) + 0.5f);
					for(int y = floor_y; y < WATER_LEVEL; y++)
						set_id(x, y, z, 7);
					for(int y = WATER_LEVEL; y <= uc.getY(); y++){
						if(!inside(x, y, z) || ids[idx(x, y, z)] == AIR)
							break;
						set_id(x, y, z, AIR);
					}
				}
			}

			// Benchmark 4 looks across the water at a grazing angle, which is
			// where a reflection is strongest and so where the environment
			// cube map either shows up or does not. The camera sits over the
			// far edge of the pond, which is the one place near it that no
			// tree can grow into, and looks back across it towards the middle
			// of the volume.
			if(!multi()){
				float ux = POND_CENTRE_X - (lc.getX() + SCENE_SIZE / 2.0f);
				float uz = POND_CENTRE_Z - (lc.getZ() + SCENE_SIZE / 2.0f);
				float ul = std::sqrt(ux * ux + uz * uz);
				if(ul < 0.001f){ ux = 0.0f; uz = 1.0f; ul = 1.0f; }
				ux /= ul;
				uz /= ul;
				water_eye[0] = POND_CENTRE_X + ux * POND_RADIUS * 0.7f;
				water_eye[1] = WATER_LEVEL + 4.0f;
				water_eye[2] = POND_CENTRE_Z + uz * POND_RADIUS * 0.7f;
				water_target[0] = POND_CENTRE_X - ux * POND_RADIUS * 0.9f;
				water_target[1] = WATER_LEVEL;
				water_target[2] = POND_CENTRE_Z - uz * POND_RADIUS * 0.9f;
				water_valid = true;
				log_v(MODULE, "pond at (%i, %i, %i) r %i; camera "
						"(%.1f, %.1f, %.1f)", POND_CENTRE_X, WATER_LEVEL,
						POND_CENTRE_Z, POND_RADIUS, water_eye[0],
						water_eye[1], water_eye[2]);
			}

			// Carve the cave with a sphere swept along the view direction
			// yawed by CAVE_YAW_DEGREES, starting in the air above the near
			// corner so that it breaks the surface and leaves a mouth instead
			// of a sealed pocket. Both the axis and its starting point are
			// rotated about the centre of the volume, so the whole cave turns
			// rather than just pivoting at the mouth.
			float rdx = rot_x(VIEW_DIR_X, VIEW_DIR_Z);
			float rdz = rot_z(VIEW_DIR_X, VIEW_DIR_Z);
			float dl = std::sqrt(rdx*rdx + VIEW_DIR_Y*VIEW_DIR_Y + rdz*rdz);
			float dx = rdx / dl, dy = VIEW_DIR_Y / dl, dz = rdz / dl;

			float sx = mouth_x;
			float sz = mouth_z;
			// Every section carves the whole cave and clips it, so every one
			// of them needs the ground height at the mouth, which is only in
			// the noise map of the sections the mouth is over. One extra
			// sample of the same noise gives it to all of them -- all, since
			// a map's value and a lone sample's differ in the last bits, and
			// two sections carving from two heights leave a seam.
			float mouth_surface;
			if(!multi()){
				mouth_surface = surface_at(mouth_x, mouth_z);
			} else {
				interface::Noise mouth_noise(&np, TERRAIN_SEED, 1, 1);
				mouth_noise.fbmMap2D(mouth_x - ox + spread.X/2,
						mouth_z - oz + spread.Z/2);
				mouth_noise.transformNoiseMap();
				mouth_surface = mouth_noise.result[0] + GROUND_OFFSET + oy;
			}
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
				log_v(MODULE, "Bench: shaft " PV3I_FORMAT " h %i, slab "
						PV3I_FORMAT, PV3I_PARAMS(bench_shaft_centre),
						bench_shaft_h, PV3I_PARAMS(bench_slab_centre));
			}

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
		bool refused = false;
		const ss_ sections = interface::launch_param(m_server->get_config().
				get<ss_>("untrusted_launch"), "sections", &refused);
		g_sections_per_axis = sections == "8" ? 2 : 1;
		if(refused || (sections != "" && sections != "1" && sections != "8"))
			log_w(MODULE, "sections: 1 or 8; one section it is");
		for(int i = 0; i < 3; i++)
			g_scene_offset[i] = multi() ? MULTI_SCENE_OFFSET[i] : 0;

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
			// The whole world, never streamed
			const int n = g_sections_per_axis - 1;
			pv::Region region(0, 0, 0, n, n, n);
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
			// roughness, spec_strength, bumpiness, translucency, spots,
			// static_spots. The README says why these values.
			// static_spots: eight sections' were never raised with one's,
			// and their look is kept as it is
			const float rock_spots = multi() ? 0.04f : 0.25f;
			add_voxel(reg, "rock", "main/rock.png", true, false,
					0.95f, 0.15f, 0.5f, 0.0f, 0.0f, rock_spots); // id 2
			add_voxel(reg, "dirt", "main/dirt.png", true, false,
					0.98f, 0.15f, 0.6f, 0.0f, 0.0f, rock_spots); // id 3
			add_voxel(reg, "grass", "main/grass.png", true, false,
					0.90f, 1.0f, 0.75f, 0.06f, 0.012f); // id 4
			add_voxel(reg, "leaves", "main/leaves.png", true, false,
					0.95f, 1.0f, 1.5f, 0.11f, 0.03f); // id 5
			add_voxel(reg, "tree", "main/tree.png", true, false,
					0.85f, 0.35f, 2.0f); // id 6
			if(!multi())
				add_voxel(reg, "water", "main/water.png", true, false,
						0.28f, 1.0f, 6.0f, 0.0f, 0.05f); // id 7

			// The whole point of this scene: let voxelworld light it
			ivoxelworld->get_instance(m_main_scene)->
					set_skylight_enabled(true);
		});

		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			instance->enable();
		});

		const int world_size = g_sections_per_axis * SECTION_SIZE;
		log_v(MODULE, "voxel_lighting: %ix%ix%i voxels in %i section(s)",
				world_size, world_size, world_size, g_sections_per_axis *
				g_sections_per_axis * g_sections_per_axis);
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

	// "x y z", the middle of the canopy benchmark 5 looks at
	ss_ tree_packet()
	{
		char buf[80];
		snprintf(buf, sizeof buf, "%f %f %f", m_worldgen->tree_centre[0],
				m_worldgen->tree_centre[1], m_worldgen->tree_centre[2]);
		return buf;
	}

	// "ex ey ez tx ty tz": benchmark 4's camera and what it looks at
	ss_ water_packet()
	{
		char buf[160];
		snprintf(buf, sizeof buf, "%f %f %f %f %f %f",
				m_worldgen->water_eye[0], m_worldgen->water_eye[1],
				m_worldgen->water_eye[2], m_worldgen->water_target[0],
				m_worldgen->water_target[1], m_worldgen->water_target[2]);
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
			// Before anything that places a camera
			char scene[48];
			snprintf(scene, sizeof scene, "%i %i %i", g_scene_offset[0],
					g_scene_offset[1], g_scene_offset[2]);
			inetwork->send(event.recipient, "main:scene", scene);
			if(m_worldgen && m_worldgen->cave_valid)
				inetwork->send(event.recipient, "main:cave", cave_packet());
			if(m_worldgen && m_worldgen->water_valid)
				inetwork->send(event.recipient, "main:water", water_packet());
			if(m_worldgen && m_worldgen->tree_valid)
				inetwork->send(event.recipient, "main:tree", tree_packet());
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
	// scratch over the whole world. It is at most eight sections, so the whole
	// thing fits in memory and the two can be compared voxel by voxel; this is
	// what says whether an edit relit everything it should have, and light
	// that should have crossed a boundary and did not shows up here.
	void verify_skylight()
	{
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			const int16_t n = g_sections_per_axis - 1;
			pv::Region region(
					world->get_section_region_voxels(
							pv::Vector3DInt16(0, 0, 0)).getLowerCorner(),
					world->get_section_region_voxels(
							pv::Vector3DInt16(n, n, n)).getUpperCorner());
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
			// Which way they are wrong is the reading, not how many:
			// light that is too high where the sky does not reach is a
			// cave that the shader then treats as outdoors
			size_t too_bright = 0, too_dark = 0;
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
				if(stored[i] > want)
					too_bright++;
				else
					too_dark++;
				if(mismatches == 0){
					first = pv::Vector3DInt32(lc.getX() + x, lc.getY() + y,
							lc.getZ() + z);
					first_want = want;
					first_got = stored[i];
				}
				mismatches++;
			}
			if(mismatches == 0){
				log_i(MODULE, "skylight verify: ok");
			} else {
				log_w(MODULE, "skylight verify: %zu voxels differ from a "
						"fresh fill, %zu of them brighter and %zu darker; "
						"first " PV3I_FORMAT " wants %i, has %i",
						mismatches, too_bright, too_dark, PV3I_PARAMS(first),
						first_want, first_got);
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
			for(auto &peer : inetwork->list_peers()){
				inetwork->send(peer, "main:cave", cave_packet());
				if(m_worldgen->water_valid)
					inetwork->send(peer, "main:water", water_packet());
				if(m_worldgen->tree_valid)
					inetwork->send(peer, "main:tree", tree_packet());
			}
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
