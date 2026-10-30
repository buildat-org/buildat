// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] stage 4e: the World (types/world.lua, api.h's Host::world_scene)
// and the material set it is made of. Part of kit.cpp (one translation
// unit), included there.
//
// **A material set** (materials.json is Kit's own, Workbench's; an app
// gives its own as Host::materials):
//   {"format": "kit_materials", "author", "name",
//    "voxels": {"<author>/<name>": {"texture": t | "top", "side",
//        "bottom": t, "kind": "solid" (default) | "water" | "leaves",
//        "heightmap": the layer of builtin/heightmap's ground textures
//        that is its look}, ...},
//    "fallbacks": {role: role, ...},
//    "biomes": {name: {role: voxel, ..., "filler_depth": n}, ...}}
// The roles: stone, top, filler (its depth the biome's filler_depth),
// water, riverbed, dust, cave_floor, cave_wall. A role a biome does not
// bind falls back along "fallbacks" (top to filler to stone); one whose
// chain ends with nothing is missing, and a generator needing it refuses,
// naming it. No river water: a river, if any, is the sea's water.
// "voxels" is the set's own voxels, which register_voxels() adds (an app
// binding roles to voxels of its own leaves it out). A biome's
// decorations (prefabs: trees, a log with mushrooms) are [KIT] stage
// 4f's, with the scatter.
//
// **The generators** are native and fill a column from its top cell: the
// top role there (riverbed under the sea), filler below it, stone below
// that, water from over the ground up to sea_level. flat: the top at
// level; noise: level + height * fbm(x / spread, z / spread, seed);
// valleys: Luanti's valleys mapgen's surface (luanti_mapgen's
// surface_map, mgvalleys_river_size 0: its valleys, no river channels;
// its 3D fill left out, so no overhangs) + level. Each is a function of
// its parameters and seed alone (the same map, byte for byte, on the
// same build).
//
// **Finite** maps are width x depth cells round the origin, every section
// of them pinned (loaded, generated once, saved: baked; a later engine
// cannot change a published map). The border: void (nothing), wall (a
// ring of stone 4 over the highest ground), water (16 cells of sea round
// it, its bed 4 under sea_level). **Infinite** maps are generated where
// players go; a section nobody wrote is not saved
// (voxelworld::set_save_unaltered), the generator and its version pinned
// in Kit's row "world" (a build whose generator is another version
// refuses the save). **A heightmap surface**: builtin/heightmap's map,
// finite, from the origin (a side a multiple of 64), the same heights,
// its layers the biome's top, stone and riverbed's; no water on it yet.
//
// Changing the parameters generates again every section nobody wrote
// (voxelworld::set_writes_alter: any write but the generator's); the
// written ones stay and a warning names those beside regenerated ones,
// the seams. Size and surface of a heightmap apply at the next start.
// simplified: one biome a world (the parameter), no biome noise yet;
// no caves (the cave roles are for the brushes); no dust placed.
#pragma once
#include "worldgen/api.h"
#include "heightmap/api.h"
#include "luanti_mapgen/api.h"
#include "interface/noise.h"
#include <climits>

namespace kit {
namespace world {

namespace pv = PolyVox;

static const char *ROLES[] = {"stone", "top", "filler", "water", "riverbed",
	"dust", "cave_floor", "cave_wall"};
// The generators' versions: an infinite world pins its generator's in the
// save, and a build whose version differs refuses it (a finite one is
// baked and does not care)
static int generator_version(const ss_ &g)
{
	return g == "empty" || g == "flat" || g == "noise" || g == "valleys" ?
			1 : 0;
}
// A finite voxel map's side at most (a heightmap's is its own)
static const int MAX_FINITE_VOXELS = 512;
// Sea round a finite map with a water border, and its bed under sea level
static const int SEA_BORDER = 16, SEA_BED = 4;
// An infinite world's load points round each player, in sections
static const int LOAD_XZ = 2, GEN_XZ = 2, LOAD_Y = 1;

struct Material
{
	ss_ top, side, bottom, kind = "solid";
	int layer = -1; // the heightmap's
};

struct Biome
{
	sm_<ss_, ss_> roles;
	int filler_depth = 3;
};

struct MaterialSet
{
	ss_ name;
	sm_<ss_, Material> voxels;
	sm_<ss_, ss_> fallback;
	sm_<ss_, Biome> biomes;

	bool parse(const json::Value &j, ss_ &why)
	{
		if(!j.is_object() || json::jstr(j, "format") != "kit_materials"){
			why = "not a kit_materials set";
			return false;
		}
		name = json::jstr(j, "author")+"/"+json::jstr(j, "name");
		const json::Value &vs = j.get("voxels");
		if(vs.is_object())
			for(json::Iterator it(vs); it; ++it){
				Material m;
				const ss_ t = json::jstr(*it, "texture");
				m.top = json::jstr(*it, "top", t);
				m.side = json::jstr(*it, "side", t);
				m.bottom = json::jstr(*it, "bottom", t);
				m.kind = json::jstr(*it, "kind", "solid");
				m.layer = (int)json::jint(*it, "heightmap", -1);
				if(m.top.empty() || m.side.empty() || m.bottom.empty() ||
						(m.kind != "solid" && m.kind != "water" &&
						m.kind != "leaves")){
					why = "voxel "+it.key()+": a texture and a kind";
					return false;
				}
				voxels[it.key()] = m;
			}
		const json::Value &fb = j.get("fallbacks");
		if(fb.is_object())
			for(json::Iterator it(fb); it; ++it)
				if((*it).is_string())
					fallback[it.key()] = (*it).as_string();
		const json::Value &bs = j.get("biomes");
		if(!bs.is_object() || bs.size() == 0){
			why = "no biomes";
			return false;
		}
		for(json::Iterator it(bs); it; ++it){
			Biome b;
			b.filler_depth = (int)std::max<int64_t>(0, std::min<int64_t>(16,
					json::jint(*it, "filler_depth", 3)));
			for(const char *r : ROLES){
				const ss_ v = json::jstr(*it, r);
				if(!v.empty())
					b.roles[r] = v;
			}
			biomes[it.key()] = b;
		}
		return true;
	}

	// The voxel a role is in a biome, along its fallbacks ("": none)
	ss_ resolve(const Biome &b, ss_ role) const
	{
		for(int i = 0; i < 8 && !role.empty(); i++){
			auto it = b.roles.find(role);
			if(it != b.roles.end())
				return it->second;
			auto f = fallback.find(role);
			role = f == fallback.end() ? "" : f->second;
		}
		return "";
	}
};

// The World's parameters (types/world.lua)
struct Params
{
	ss_ generator = "flat", biome, size = "finite", border = "void",
			surface = "voxels";
	uint32_t seed = 0;
	int level = 0, height = 12, spread = 48, sea_level = 0, width = 64,
			depth = 64;

	void from(const json::Value &j)
	{
		generator = json::jstr(j, "generator", generator);
		biome = json::jstr(j, "biome");
		size = json::jstr(j, "size", size);
		border = json::jstr(j, "border", border);
		surface = json::jstr(j, "surface", surface);
		auto num = [&](const char *k, int &out){
			const json::Value &v = j.get(k);
			if(v.is_number())
				out = (int)std::floor(v.as_number());
		};
		const json::Value &sv = j.get("seed");
		seed = sv.is_number() ? (uint32_t)(int64_t)sv.as_number() : 0;
		num("level", level);
		num("height", height);
		num("spread", spread);
		num("sea_level", sea_level);
		num("width", width);
		num("depth", depth);
		spread = std::max(spread, 1);
	}
	bool finite() const { return size != "infinite"; }
	bool heightmap() const { return surface == "heightmap"; }
	int x0() const { return -width / 2; }
	int z0() const { return -depth / 2; }
	bool in_map(int x, int z) const
	{
		return !finite() || (x >= x0() && x < x0() + width &&
				z >= z0() && z < z0() + depth);
	}
};

// The ground's height over columns: continuous (a heightmap's), and the
// top cell of a voxel column (its floor). Asked from worldgen's thread
struct Heights
{
	Params p;
	up_<luanti_mapgen::SurfaceQuery> valleys;

	float at(float x, float z)
	{
		if(p.generator == "noise")
			return p.level + p.height * interface::noise::fbm2(
					x / p.spread, z / p.spread, p.seed, 4, 0.5f);
		if(p.generator == "valleys" && valleys){
			float h = 0;
			valleys->surface_map(x, z, 1, 1, 1, &h);
			return h + p.level;
		}
		if(p.generator == "empty")
			return (float)INT_MIN / 2;
		return (float)p.level;
	}
	// The top cells of w x d columns from (x0, z0), x fastest
	void tops(int x0, int z0, int w, int d, sv_<int> &out)
	{
		out.resize((size_t)w * d);
		if(p.generator == "valleys" && valleys){
			sv_<float> h((size_t)w * d);
			valleys->surface_map(x0, z0, 1, w, d, h.data());
			for(size_t i = 0; i < out.size(); i++)
				out[i] = (int)std::floor(h[i] + p.level);
			return;
		}
		for(int z = 0; z < d; z++)
			for(int x = 0; x < w; x++)
				out[(size_t)z * w + x] = p.generator == "empty" ? INT_MIN / 2 :
						(int)std::floor(at(x0 + x, z0 + z) + 0.5f);
	}
};

// The voxel ids a generator writes: the biome's roles, air
struct Ids
{
	interface::VoxelTypeId air = 0, top = 0, filler = 0, stone = 0,
			water = 0, riverbed = 0;
	int filler_depth = 3;
};

struct Generator: public worldgen::GeneratorInterface
{
	Params p;
	Ids ids;
	up_<Heights> h;
	// The highest ground of a finite map (its wall's top)
	int max_top = 0;

	void generate(main_context::SceneReference,
			const pv::Vector3DInt16 &, interface::VoxelVolume &volume)
	{
		const pv::Region r = volume.getEnclosingRegion();
		const pv::Vector3DInt32 lc = r.getLowerCorner(), uc = r.getUpperCorner();
		const int w = uc.getX() - lc.getX() + 1, d = uc.getZ() - lc.getZ() + 1;
		sv_<int> tops;
		h->tops(lc.getX(), lc.getZ(), w, d, tops);
		using interface::VoxelInstance;
		for(int z = lc.getZ(); z <= uc.getZ(); z++)
		for(int x = lc.getX(); x <= uc.getX(); x++){
			int top = tops[(size_t)(z - lc.getZ()) * w + (x - lc.getX())];
			bool wall = false, sea = p.sea_level > top;
			if(!p.in_map(x, z)){
				// Past the map: its border, then nothing
				const int ox = x < p.x0() ? p.x0() - x : x - (p.x0() + p.width - 1);
				const int oz = z < p.z0() ? p.z0() - z : z - (p.z0() + p.depth - 1);
				const int out = std::max(ox, oz);
				if(p.border == "wall" && out == 1){
					wall = true;
				} else if(p.border == "water" && out <= SEA_BORDER){
					top = p.sea_level - SEA_BED;
					sea = true;
				} else {
					top = INT_MIN / 2;
					sea = false;
				}
			}
			for(int y = lc.getY(); y <= uc.getY(); y++){
				interface::VoxelTypeId v = ids.air;
				if(wall)
					v = y <= max_top + 4 ? ids.stone : ids.air;
				else if(y > top)
					v = sea && y <= p.sea_level ? ids.water : ids.air;
				else if(y == top)
					v = top < p.sea_level ? ids.riverbed : ids.top;
				else if(y > top - 1 - ids.filler_depth)
					v = top < p.sea_level ? ids.riverbed : ids.filler;
				else
					v = ids.stone;
				volume.setVoxelAt(x, y, z, VoxelInstance(v));
			}
		}
	}
};

// FNV-1a over ints: the heights' hash a check compares
static uint32_t hash_ints(const sv_<int> &v)
{
	uint32_t hsh = 2166136261u;
	for(int x : v)
		for(int i = 0; i < 4; i++){
			hsh ^= (uint32_t)(x >> (i * 8)) & 0xff;
			hsh *= 16777619u;
		}
	return hsh;
}

}
}
// vim: set noet ts=4 sw=4:
