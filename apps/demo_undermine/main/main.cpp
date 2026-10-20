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
#include <random>
#include "interface/voxel_volume.h"
#include <Scene.h>
#include <Context.h>
#include <StaticModel.h>
#include <Material.h>
#include <Texture2D.h>
#include <Technique.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#include <sstream>
#include <deque>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <chrono>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelVolume;
using main_context::SceneReference;

#include "interface/polyvox_std.h"

#include "interface/polyvox_cereal.h"

namespace main {

// A number in [a, b] ([NOISE_API]: what PseudoRandom::range was)
static int range(std::mt19937 &r, int a, int b)
{
	return a + (int)(r() % (uint32_t)(b - a + 1));
}

using namespace Urho3D;

// Everything at or below this that the terrain did not fill is water. The
// generator's surface runs from about y=13 to y=100 over the generated area,
// and this line puts water in the lowest 6% of it: a handful of ponds in the
// hollows rather than a sea with islands in it.
static const int WATER_LEVEL = 25;

// The bottom of the world, and the only thing in it that cannot be dug:
// where support ultimately comes from.
static const int BEDROCK_TOP = -60;

// demo_undermine's own cut of a voxel word, which is the point of the game
// existing. See doc/plan/undermine_plan.md.
//
//   id      0...7    up to 255 materials; there are twelve, and nature and
//                    everything else it will grow have room
//   sky     8...11   light, as voxelworld maintains it
//   moisture 20...23 how near this voxel is to water, 0 for dry
//   param  12...19   both of the simulation's numbers, packed:
//                      high nibble  how much of what this voxel can carry is
//                                   already on it, 0...15
//                      low nibble   how far it is from something holding it
//                                   up, 0...15
//
// One field rather than two, and bound as the engine's `param` role, because
// the role is the only thing the mesher can read -- and the views need both
// numbers. A view is then a registry whose definitions decode these eight
// bits its own way: the high nibble, the low nibble, or the worse of the
// two. See build_view_registry().
//
// The load is stored as a fraction of the voxel's own capacity rather than
// as a weight, which is the normalisation a view needs anyway and is what
// lets one nibble do. Nothing needs the weight itself: compute_load() works
// it out from the column whenever the rules ask.
//
// No lamp light. Nothing in this world bakes light into a voxel except the
// sky: a lamp here is a real light in the scene, which is what the player's
// own lamp already is, and the shader lights the geometry from it. The role
// exists for a world whose *server* computed the lamp light per voxel and
// sends it -- which is what a Luanti server does -- and binding it here
// would spend four bits on a field nothing writes.
//
// support is not a role: the engine knows nothing about it, which is what
// the design note means by a game's simulation fields being its own
// business. Bits 24...31 are spare, which is exactly the eight the plan's
// phase 3 wants for moisture and not one more.
// One source of truth for the layout: the format is built out of these, and
// the simulation reads and writes through them.
static const interface::VoxelField F_ID(0, 0, 8);
static const interface::VoxelField F_LIGHT_SKY(0, 8, 4);
static const interface::VoxelField F_PARAM(0, 12, 8);
// Added after the game was already playable, and it cost nothing at all to
// add: moisture is the game's own business rather than one of the engine's
// roles, so the format below did not change and neither did anything the
// engine does. Bits 24...31 are still spare.
static const interface::VoxelField F_MOISTURE(0, 20, 4);

static interface::VoxelFormat undermine_format()
{
	interface::VoxelFormat f;
	f.id = F_ID;
	f.light_sky = F_LIGHT_SKY;
	// The simulation's own state is the param role, so that the mesher can
	// read it and the views can be made out of it
	f.param = F_PARAM;
	return f;
}

static const uint8_t SUPPORT_MAX = 15;
static const uint8_t LOAD_MAX = 255;
// How many steps of "how loaded is it" fit in the nibble, and so how many
// bands a view has
static const uint8_t BAND_MAX = 15;
// How far water reaches into what is porous. A distance rather than a
// wetness: a voxel next to water is at the maximum and each step away is one
// less, so water appearing wets what is around it and water going away dries
// it, both by the same relaxation and with no timers anywhere.
static const uint8_t MOISTURE_MAX = 5;

// How far up a voxel is asked to carry.
//
// simplified: the weight on a voxel is the column immediately above it and
// no further, so nothing carries the whole mountain and a prop's failure
// depends on what is locally above it. That is what makes the number local
// enough to work out anywhere, including at generation time, and stable
// enough that digging far overhead does not change it. The upgrade path, if
// a game wants the real thing, is a load that accumulates down the column
// without a limit -- which means the whole column has to be recomputed
// whenever anything in it changes.
static const int LOAD_DEPTH = 32;

static interface::VoxelTypeId id_of(const VoxelInstance &v)
{
	return (interface::VoxelTypeId)F_ID.get(v.data);
}

static uint8_t moisture_of(const VoxelInstance &v)
{
	return (uint8_t)F_MOISTURE.get(v.data);
}

static uint8_t support_of(const VoxelInstance &v)
{
	return (uint8_t)(F_PARAM.get(v.data) & 0x0f);
}

// How much of what this voxel can carry is already on it, 0...15
static uint8_t band_of(const VoxelInstance &v)
{
	return (uint8_t)(F_PARAM.get(v.data) >> 4);
}

static void set_state(VoxelInstance &v, uint8_t support, uint8_t band)
{
	F_PARAM.set(v.data, (uint32_t)((band & 0x0f) << 4) | (support & 0x0f));
}

// A weight, as the fraction of a capacity that a nibble can hold. Rounded
// down, so a band of 15 means "at or over what it can carry" only when the
// weight really is; the rules test the weight itself and not this.
static uint8_t load_band(uint32_t load, uint8_t capacity)
{
	if(capacity == 0)
		return 0;
	uint32_t band = load * (BAND_MAX + 1) / ((uint32_t)capacity + 1);
	return (uint8_t)(band > BAND_MAX ? BAND_MAX : band);
}

// The materials. Ids are assigned in this order by add_voxel() below, and
// nothing may be inserted in the middle: a saved world holds these numbers.
enum Material {
	M_AIR = 1,
	M_BEDROCK,
	M_ROCK,
	M_DIRT,
	M_GRASS,
	M_SAND,
	M_RUBBLE,
	M_TIMBER,
	M_BRICK,
	M_WATER,
	M_TRUNK,
	M_LEAVES,
	M_WET_DIRT,
	M_COUNT
};

// What the simulation reads about a material.
//
//   span      how far it reaches out over nothing before it fails, which is
//             what decides how wide a tunnel it will roof
//   density   what one voxel of it weighs, in the same units as capacity
//   capacity  how much weight it carries before it is crushed
//
// Timber spans far and carries little, brick spans little and carries a
// mountain: that pair is most of the game. A material with span 0 holds
// nothing up but itself, and one with structural false takes no part at all.
// falls_as is what a voxel of this becomes once it has come apart and is on
// its way down. Something that was holding a shape up and stops is rubble;
// something that was already a loose heap is still that heap, which is why
// dirt falls as dirt and sand as sand rather than everything turning into
// the same grey pile.
// porous says whether water gets into it, and so whether it turns into
// something wetter. What that something is, is wet_of.
struct MaterialProps
{
	bool structural;
	bool diggable;
	uint8_t span;
	uint8_t density;
	uint8_t capacity;
	int falls_as;
	bool porous;
	int wet_of;   // what it becomes when wet, or 0 for nothing
	int dry_of;   // what it goes back to when it dries, or 0
};

static const MaterialProps MATERIAL[M_COUNT] = {
	{false, false,  0, 0,   0, 0, false, 0, 0},  // (0 is UNDEFINED)
	{false, false,  0, 0,   0, 0, false, 0, 0},  // air
	{true,  false, 15, 0, 255, M_BEDROCK, false, 0, 0},  // bedrock
	{true,  true,   6, 3, 200, M_RUBBLE, false, 0, 0},   // rock
	{true,  true,   2, 2,  60, M_DIRT, true, M_WET_DIRT, 0}, // dirt
	// Turf that has come off and landed is dirt, not turf; turf that has
	// been under water is not turf either
	{true,  true,   2, 2,  60, M_DIRT, true, M_WET_DIRT, 0}, // grass
	{true,  true,   0, 2,  40, M_SAND, true, 0, 0},      // sand
	{true,  true,   0, 2,  50, M_RUBBLE, true, 0, 0},    // rubble
	{true,  true,   8, 1,  30, M_TIMBER, false, 0, 0},   // timber
	{true,  true,   3, 4, 255, M_RUBBLE, false, 0, 0},   // brick
	{false, false,  0, 0,   0, 0, false, 0, 0},  // water
	// A standing tree is held up by the ground under it like anything else,
	// so cutting through the trunk drops what is above the cut
	{true,  true,   6, 1,  25, M_TRUNK, false, 0, 0},    // trunk
	// Leaves hang off the trunk rather than standing on anything, which is
	// what the span is for: a canopy two voxels out from the trunk holds,
	// and comes down with the trunk. Weightless, so a tree does not crush
	// itself, and nothing crushes leaves.
	{true,  true,   3, 0, 255, M_LEAVES, false, 0, 0},   // leaves
	// Dirt that has taken water: it holds nothing out over a gap and carries
	// half of what dry dirt does, which is what makes digging under a pond a
	// bad idea
	{true,  true,   0, 2,  30, M_WET_DIRT, true, 0, M_DIRT}, // wet dirt
};

static const MaterialProps& material_of(interface::VoxelTypeId id)
{
	return MATERIAL[id < M_COUNT ? id : 0];
}

struct Worldgen: public worldgen::GeneratorInterface
{
	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
		{
			const pv::Region region = volume.getEnclosingRegion();

			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();

			log_t(MODULE, "on_generation_request(): lc: (%i, %i, %i)",
					lc.getX(), lc.getY(), lc.getZ());
			log_t(MODULE, "on_generation_request(): uc: (%i, %i, %i)",
					uc.getX(), uc.getY(), uc.getZ());

			const float spread = 160;
			// Retuned 2026-09-14 with demo_digger's, which this is; see the note
			// there about the noise hash
			// [NOISE_API] The scale times the octaves' sum (1.664): the old fbm
			// was not scaled back to -1..1
			interface::noise::NoiseParams np = {47, 61.6, spread, spread, spread,
					7, 0.4};

			int w = uc.getX() - lc.getX() + 1;
			int d = uc.getZ() - lc.getZ() + 1;

			sv_<float> noise;
			interface::noise::fill2(np, 3, lc.getX() + spread/2,
					lc.getZ() + spread/2, w, d, noise);

			size_t noise_i = 0;
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					double a = noise[noise_i];
					noise_i++;
					// Where the ground stops, in the same terms the layers
					// below are written in
					const int surface = (int)(a + 11.0);
					for(int y = lc.getY(); y <= uc.getY(); y++){
						pv::Vector3DInt32 p(x, y, z);
						int m;
						if(y <= BEDROCK_TOP){
							m = M_BEDROCK;
						} else if(y < a + 5){
							m = M_ROCK;
						} else if(y < a + 10){
							m = M_DIRT;
						} else if(y < a + 11){
							// A shore is sand rather than grass: it is what
							// gives the ponds an edge that behaves
							// differently when it is dug
							m = (surface <= WATER_LEVEL + 1) ?
									M_SAND : M_GRASS;
						} else if(y <= WATER_LEVEL){
							m = M_WATER;
						} else {
							m = M_AIR;
						}
						volume.setVoxelAt(p, VoxelInstance(m));
					}
				}
			}

			// Trees, for something to look at above ground -- and for
			// something whose trunk can be cut through, which the support
			// rule makes an event rather than a decoration
			auto extent = uc - lc + pv::Vector3DInt32(1, 1, 1);
			int area = extent.getX() * extent.getZ();
			std::mt19937 pr(13241);
			for(int i = 0; i < area / 100; i++){
				int x = range(pr, lc.getX(), uc.getX());
				int z = range(pr, lc.getZ(), uc.getZ());
				size_t ni = (z - lc.getZ()) * d + (x - lc.getX());
				int y = (int)(noise[ni] + 11.0);
				if(y < lc.getY() - 5 || y > uc.getY() - 5)
					continue;
				// The trunk would start in a pond
				if(y <= WATER_LEVEL + 1)
					continue;
				for(int y1 = y; y1 < y + 4; y1++)
					volume.setVoxelAt(pv::Vector3DInt32(x, y1, z),
							VoxelInstance(M_TRUNK));
				for(int x1 = x - 2; x1 <= x + 2; x1++){
					for(int y1 = y + 3; y1 <= y + 7; y1++){
						for(int z1 = z - 2; z1 <= z + 2; z1++){
							pv::Vector3DInt32 p(x1, y1, z1);
							if(id_of(volume.getVoxelAt(p)) == M_TRUNK)
								continue;
							volume.setVoxelAt(p, VoxelInstance(M_LEAVES));
						}
					}
				}
			}

			// What the simulation starts from. Generated terrain is a
			// heightfield standing on bedrock, so every solid voxel of it is
			// held up -- there are no overhangs to work out -- and the one
			// number that has to be computed is the weight each voxel
			// carries. Both are exact here except within LOAD_DEPTH of the
			// top of the volume, where the column above is in a section this
			// generator cannot see; digging near one fixes it locally.
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					// The densities of the LOAD_DEPTH voxels above the one
					// being written, as a ring: what leaves the window is
					// subtracted rather than the whole column being summed
					// again per voxel
					int window[LOAD_DEPTH] = {};
					int carried = 0;
					int depth = 0;
					for(int y = uc.getY(); y >= lc.getY(); y--){
						pv::Vector3DInt32 p(x, y, z);
						VoxelInstance v = volume.getVoxelAt(p);
						const MaterialProps &m = material_of(id_of(v));
						if(!m.structural){
							carried = 0;
							depth = 0;
							continue;
						}
						set_state(v, SUPPORT_MAX,
								load_band(carried > LOAD_MAX ?
										LOAD_MAX : carried, m.capacity));
						volume.setVoxelAt(p, v);
						int &slot = window[depth % LOAD_DEPTH];
						carried -= slot;
						slot = m.density;
						carried += slot;
						depth++;
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

	static const int SPAWN_X = -5;
	static const int SPAWN_Z = 257;
	static const int SPAWN_Y_MAX = 127;
	static const int SPAWN_Y_MIN = -64;
	static constexpr float PLAYER_HEIGHT = 1.7f;

	bool m_spawn_ready = false;
	float m_spawn_y = 0;

	// Voxels whose support and load have to be worked out again, and the
	// ones that have already been found to be failing. The set is what keeps
	// a queue from filling up with the same position: a cave-in reaches the
	// same voxel from several directions.
	std::deque<pv::Vector3DInt32> m_dirty;
	std::unordered_set<int64_t> m_dirty_set;
	std::vector<pv::Vector3DInt32> m_falling;
	std::unordered_set<int64_t> m_falling_set;

	// What the relaxation has worked out but not written into the world yet.
	//
	// A voxel's support walks down through every intermediate value on its
	// way to the answer -- 15, then 6, then 5 -- and writing each one costs
	// a chunk re-serialized, sent and remeshed, for a number that is about
	// to change again. So the relaxation reads and writes here and the world
	// gets one write per voxel, once the front has passed.
	// Keyed by position, and carrying the position, so that flushing does not
	// have to take a key apart again
	struct Pending { pv::Vector3DInt32 p; VoxelInstance v; };
	std::unordered_map<int64_t, Pending> m_scratch;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place_structure"));
		m_server->sub_event(this, Event::t("worldgen:queue_modified"));
		m_server->sub_event(this, Event::t("core:tick"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:place_voxel",
				on_place_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:dig_voxel",
				on_dig_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:place_structure",
				on_place_structure, network::Packet)
		EVENT_TYPEN("worldgen:queue_modified",
				on_worldgen_queue_modified, worldgen::QueueModifiedEvent);
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent);
	}

	// The six numbers after solid describe the surface; see interface/atlas.h.
	// visible is the edge material: an invisible voxel is also one light
	// passes through. top_texture, when given, goes on the +Y and -Y faces.
	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool visible, bool solid,
			bool fully_empty, float roughness = 0.9f, float spec_strength = 1.0f,
			float bumpiness = 1.0f, float translucency = 0.0f,
			float spots = 0.0f, float static_spots = 0.0f,
			const ss_ &top_texture = "")
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
			seg.resource_name = (i < 2 && !top_texture.empty()) ?
					top_texture : texture;
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
		vdef.edge_material_id = visible ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		vdef.fully_empty = fully_empty;
		reg->add_voxel(vdef);
	}

	// The views
	// ---------
	//
	// A view is a registry with the same voxel format and different
	// definitions: every material wears sixteen bands of a gradient instead
	// of its texture, and which band a voxel gets is decoded from the param
	// -- which carries both of the simulation's numbers, see the layout at
	// the top of this file.
	//
	// It costs no storage at all, which is the trick worth knowing. The
	// param is a role, so the mesher already has it per voxel; a
	// definition's variants are indexed by it; and variant_of_param is per
	// definition, so anything that depends on the material -- which is all
	// of the normalisation -- falls out of the table rather than being
	// computed anywhere.
	//
	// The client meshes with one of these instead of the playing registry
	// and turns skylight off while it does, so the vertex colour is the band
	// and nothing else. In the playing registry no definition has variants
	// at all, so the mesher hoists the param out of its loop and normal play
	// pays nothing for any of this.
	static const size_t VIEW_BANDS = 16;

	enum ViewMode {
		VIEW_LOAD = 0,   // how much of what it can carry is on it
		VIEW_SUPPORT,    // how far it is from something holding it up
		VIEW_DANGER,     // the worse of the two
		VIEW_COUNT
	};

	// Green through yellow to red: nothing the matter, through about to go.
	static uint32_t band_color(size_t band)
	{
		float t = (float)band / (float)(VIEW_BANDS - 1);
		float r = t < 0.5f ? t * 2.0f : 1.0f;
		float g = t < 0.5f ? 1.0f : (1.0f - t) * 2.0f;
		uint32_t ri = (uint32_t)(r * 255.0f + 0.5f);
		uint32_t gi = (uint32_t)(g * 255.0f + 0.5f);
		return (ri << 16) | (gi << 8) | 0x18;
	}

	// What this view makes of a voxel whose param says this. Both nibbles are
	// 0...15 already, so a view is nothing but a choice between them.
	static size_t view_band(int mode, uint8_t param)
	{
		size_t load = param >> 4;
		size_t support = param & 0x0f;
		size_t from_support = SUPPORT_MAX - support;
		switch(mode){
		case VIEW_SUPPORT: return from_support;
		case VIEW_DANGER: return load > from_support ? load : from_support;
		default: return load;
		}
	}

	void build_view_registry(interface::VoxelRegistry *reg, int mode)
	{
		reg->set_format(undermine_format());
		// Air first, as in the playing registry: the ids have to agree,
		// because they are what the voxels in the world hold
		add_voxel(reg, "air", "", false, false, true);
		static const char *NAME[] = {
			"", "", "bedrock", "rock", "dirt", "grass", "sand", "rubble",
			"timber", "brick", "water", "trunk", "leaves", "wet_dirt",
		};
		for(int id = M_BEDROCK; id < M_COUNT; id++){
			const MaterialProps &m = MATERIAL[id];
			if(!m.structural){
				// Water, and anything else the rules do not touch, keeps
				// what it looks like
				add_voxel(reg, NAME[id], "main/water.png",
						true, false, false, 0.28f, 1.0f, 6.0f, 0.0f, 0.05f);
				continue;
			}
			interface::VoxelDefinition vdef;
			vdef.name.block_name = ss_("view_") + NAME[id];
			vdef.handler_module = "";
			for(size_t i = 0; i < 6; i++){
				interface::AtlasSegmentDefinition &seg = vdef.textures[i];
				seg.resource_name = "main/white.png";
				seg.total_segments = magic::IntVector2(1, 1);
				seg.select_segment = magic::IntVector2(0, 0);
				seg.roughness = 1.0f;
				seg.spec_strength = 0.0f;
				seg.bumpiness = 0.0f;
			}
			vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
			vdef.physically_solid = true;
			for(size_t band = 0; band < VIEW_BANDS; band++){
				interface::VoxelVariant var;
				var.color = band_color(band);
				vdef.variants.push_back(var);
			}
			for(size_t param = 0; param < 256; param++){
				size_t band = view_band(mode, (uint8_t)param);
				vdef.variant_of_param[param] = (uint8_t)(
						band < VIEW_BANDS ? band : VIEW_BANDS - 1);
			}
			reg->add_voxel(vdef);
		}
	}

	void send_view_registries(network::PeerInfo::Id peer)
	{
		for(int mode = 0; mode < VIEW_COUNT; mode++){
			sp_<interface::VoxelRegistry> reg(
					interface::createVoxelRegistry());
			build_view_registry(reg.get(), mode);
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar((int32_t)mode, reg->serialize());
			}
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(peer, "main:view_registry", os.str());
			});
		}
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

			auto instance = iworldgen->get_instance(m_main_scene);
			instance->set_generator(new Worldgen());
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			//pv::Region region(0, 0, 0, 0, 0, 0); // Use this for valgrind
			//pv::Region region(-1, 0, -1, 1, 0, 1);
			//pv::Region region(-1, -1, -1, 1, 1, 1);
			//pv::Region region(-2, -1, -2, 2, 1, 2);
			//pv::Region region(-3, -1, -3, 3, 1, 3);
			pv::Region region(-5, -1, 0, 0, 1, 5);
			//pv::Region region(-5, -1, -5, 5, 1, 5);
			//pv::Region region(-6, -1, -6, 6, 1, 6);
			//pv::Region region(-8, -1, -8, 8, 1, 8);
			ivoxelworld->create_instance(m_main_scene, region);
		});

		// Define voxels on core:start (woxelworld will restore them on reload)
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world =
					ivoxelworld->get_instance(m_main_scene);
			interface::VoxelRegistry *voxel_reg = world->get_voxel_reg();
			// roughness, spec_strength, bumpiness, translucency, spots,
			// static_spots; see interface/atlas.h. The values are
			// sample_lighting_scene's, which is where they were chosen.
			// The game's own cut of a voxel word, before anything is
			// added: everything saved in this world is bits under it
			voxel_reg->set_format(undermine_format());
			log_i(MODULE, "Voxel format: %s",
					cs(voxel_reg->get_format().dump()));

			// In Material's order, and nothing may be inserted in the
			// middle. The six numbers after solid describe the surface; see
			// interface/atlas.h.
			add_voxel(voxel_reg, "air", "", false, false, true);
			add_voxel(voxel_reg, "bedrock", "main/bedrock.png",
					true, true, false,
					0.98f, 0.10f, 0.7f, 0.0f, 0.0f, 0.02f);
			add_voxel(voxel_reg, "rock", "main/rock.png", true, true, false,
					0.95f, 0.15f, 0.5f, 0.0f, 0.0f, 0.04f);
			add_voxel(voxel_reg, "dirt", "main/dirt.png", true, true, false,
					0.98f, 0.15f, 0.6f, 0.0f, 0.0f, 0.04f);
			add_voxel(voxel_reg, "grass", "main/grass.png", true, true, false,
					0.90f, 1.0f, 0.75f, 0.06f, 0.012f);
			add_voxel(voxel_reg, "sand", "main/sand.png", true, true, false,
					0.96f, 0.25f, 0.45f, 0.0f, 0.0f, 0.03f);
			add_voxel(voxel_reg, "rubble", "main/rubble.png",
					true, true, false,
					0.97f, 0.20f, 1.1f, 0.0f, 0.0f, 0.05f);
			add_voxel(voxel_reg, "timber", "main/timber.png",
					true, true, false,
					0.85f, 0.35f, 1.4f, 0.0f, 0.0f, 0.0f);
			add_voxel(voxel_reg, "brick", "main/brick.png", true, true, false,
					0.92f, 0.30f, 0.9f, 0.0f, 0.0f, 0.02f);
			// Walked into rather than stood on: the player sinks to the pond
			// floor and can dig or climb out. Nothing simulates flow, so a
			// dug shore leaves a hole in the water rather than draining it.
			add_voxel(voxel_reg, "water", "main/water.png", true, false, false,
					0.28f, 1.0f, 6.0f, 0.0f, 0.05f);
			add_voxel(voxel_reg, "trunk", "main/tree.png", true, true, false,
					0.85f, 0.35f, 2.0f, 0.0f, 0.0f, 0.0f,
					"main/tree_top.png");
			add_voxel(voxel_reg, "leaves", "main/leaves.png",
					true, true, false,
					0.95f, 1.0f, 1.5f, 0.11f, 0.03f);
			add_voxel(voxel_reg, "wet_dirt", "main/wet_dirt.png",
					true, true, false,
					0.80f, 0.45f, 0.6f, 0.0f, 0.0f, 0.04f);

			world->set_skylight_enabled(true);
		});

		// Enable world generation now that the voxels are defined
		worldgen::access(m_server, m_main_scene, [&](worldgen::Instance *instance)
		{
			instance->enable();
		});
	}

	void on_unload()
	{
		// TODO: Store main scene reference
		// Just do this for now
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_main_scene);
		});
	}

	void on_continue()
	{
		// TODO: Restore main scene reference
		// Just do this for now
		on_start();
	}

	// Standing-height air along -X (player facing). No path check; long enough
	// that it is likely to hit a slope, pocket, or the world edge.
	void carve_spawn_tunnel(int floor_y)
	{
		const int length = 96;
		const int height = 3;
		const int half_w = 1;
		const int back = 2;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int dx = -back; dx < length; dx++){
				int x = SPAWN_X - dx;
				for(int dz = -half_w; dz <= half_w; dz++){
					int z = SPAWN_Z + dz;
					for(int dy = 1; dy <= height; dy++){
						world->set_voxel(
								pv::Vector3DInt32(x, floor_y + dy, z),
								VoxelInstance(M_AIR), true);
					}
				}
			}
		});
		log_i(MODULE, "Spawn tunnel: x=%i..%i y=%i..%i z=%i..%i",
				SPAWN_X + back, SPAWN_X - (length - 1),
				floor_y + 1, floor_y + height,
				SPAWN_Z - half_w, SPAWN_Z + half_w);
	}

	void send_spawn(network::PeerInfo::Id peer)
	{
		if(!m_spawn_ready)
			return;
		std::ostringstream os(std::ios::binary);
		cereal::PortableBinaryOutputArchive ar(os);
		double x = SPAWN_X;
		double y = m_spawn_y;
		double z = SPAWN_Z;
		ar(x, y, z);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:spawn", os.str());
		});
		log_v(MODULE, "Sent spawn (%.2f, %.2f, %.2f) to peer %zu",
				x, y, z, peer);
	}

	// The surface the player stands on: the first of the terrain materials
	// looking down. Air and water are not stood on.
	void try_resolve_spawn()
	{
		if(m_spawn_ready)
			return;
		int surface_y = SPAWN_Y_MIN - 1;
		bool column_ready = true;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			const interface::VoxelFormat &fmt =
					world->get_voxel_reg()->get_format();
			for(int y = SPAWN_Y_MAX; y >= SPAWN_Y_MIN; y--){
				VoxelInstance v = world->get_voxel(
						pv::Vector3DInt32(SPAWN_X, y, SPAWN_Z), true);
				// Through the format, not VoxelInstance::legacy06_id(), which is
				// buildat_legacy_06() and would read this game's light and load
				// as part of the id
				interface::VoxelTypeId id = fmt.id_of(v.data);
				if(id == interface::VOXELTYPEID_UNDEFINED){
					column_ready = false;
					return;
				}
				if(material_of(id).structural){
					surface_y = y;
					return;
				}
			}
		});
		if(!column_ready)
			return;
		if(surface_y < SPAWN_Y_MIN){
			log_w(MODULE, "Spawn column (%i, *, %i) has no terrain",
					SPAWN_X, SPAWN_Z);
			return;
		}
		carve_spawn_tunnel(surface_y);
		// Voxel n is a 1x1x1 cube centered at n; stand on its top face.
		m_spawn_y = (float)surface_y + 0.5f + PLAYER_HEIGHT / 2.0f + 0.05f;
		m_spawn_ready = true;
		log_i(MODULE, "Spawn at (%i, %.2f, %i) (terrain y=%i)",
				SPAWN_X, m_spawn_y, SPAWN_Z, surface_y);

		network::access(m_server, [&](network::Interface *inetwork){
			std::ostringstream os(std::ios::binary);
			cereal::PortableBinaryOutputArchive ar(os);
			double x = SPAWN_X;
			double y = m_spawn_y;
			double z = SPAWN_Z;
			ar(x, y, z);
			ss_ data = os.str();
			for(auto peer : inetwork->list_peers())
				inetwork->send(peer, "main:spawn", data);
		});
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
		size_t queue_size = 0;
		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			queue_size = instance->get_num_sections_queued();
		});
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "main:worldgen_queue_size",
					itos(queue_size));
		});
		send_view_registries(event.recipient);
		send_spawn(event.recipient);
	}


	// The simulation
	// --------------
	//
	// One queue of voxels whose support and load are out of date, walked with
	// a budget per tick. Recomputing a voxel is a pure function of its
	// neighbours, so a change spreads outward by whatever it actually
	// changes: a dig into solid rock settles in a handful of voxels, and a
	// dig that takes a roof away walks as far as the roof reached.
	//
	// Support goes down rather than up when what was holding it goes away,
	// which the same relaxation handles by running to a fixed point: with no
	// source left, each round takes another step off what is left, so the
	// front dies out after at most SUPPORT_MAX rounds. That is why there is
	// no separate take-it-back-out pass of the kind update_skylight() needs
	// -- support is cheap to be wrong about for a tick, and light is not.
	static const size_t SIM_PER_TICK = 2048;
	static const size_t FALL_PER_TICK = 256;

	static int64_t pos_key(const pv::Vector3DInt32 &p)
	{
		// The world is far smaller than 2^20 on any axis
		return ((int64_t)(p.getX() & 0xfffff) << 40) |
				((int64_t)(p.getY() & 0xfffff) << 20) |
				(int64_t)(p.getZ() & 0xfffff);
	}

	void mark_dirty(const pv::Vector3DInt32 &p)
	{
		if(m_dirty_set.insert(pos_key(p)).second)
			m_dirty.push_back(p);
	}

	// What has to be looked at again after the voxel at p changed: itself,
	// the six around it -- support reaches sideways and up -- and the
	// LOAD_DEPTH voxels under it, which are the ones carrying it.
	void mark_changed(const pv::Vector3DInt32 &p)
	{
		static const int OFF[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
		};
		mark_dirty(p);
		for(size_t k = 0; k < 6; k++)
			mark_dirty(pv::Vector3DInt32(p.getX() + OFF[k][0],
					p.getY() + OFF[k][1], p.getZ() + OFF[k][2]));
		for(int i = 1; i <= LOAD_DEPTH; i++)
			mark_dirty(pv::Vector3DInt32(p.getX(), p.getY() - i, p.getZ()));
	}

	void mark_falling(const pv::Vector3DInt32 &p)
	{
		if(m_falling_set.insert(pos_key(p)).second)
			m_falling.push_back(p);
	}

	// The voxel at p as the simulation currently understands it: what the
	// relaxation has worked out, or what the world holds if it has not been
	// touched.
	VoxelInstance peek(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p)
	{
		auto it = m_scratch.find(pos_key(p));
		if(it != m_scratch.end())
			return it->second.v;
		return world->get_voxel(p, true);
	}

	// How far the voxel at p is from something holding it up, 0 for nothing.
	//
	// A voxel standing on something supported is supported itself, whatever
	// it is made of: a column carries straight down and does not span
	// anything. Otherwise it reaches out sideways from its neighbours,
	// losing one step per voxel and never further than its material's span,
	// which is what decides how wide a tunnel a material will roof.
	uint8_t compute_support(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p, const MaterialProps &m)
	{
		if(!m.diggable)
			return SUPPORT_MAX; // Bedrock, and anything else immovable
		VoxelInstance below = peek(world,
				pv::Vector3DInt32(p.getX(), p.getY() - 1, p.getZ()));
		const MaterialProps &bm = material_of(id_of(below));
		if(bm.structural && support_of(below) > 0)
			return SUPPORT_MAX;
		if(m.span == 0)
			return 0;
		static const int SIDE[4][2] = {{1,0}, {-1,0}, {0,1}, {0,-1}};
		uint8_t best = 0;
		for(size_t k = 0; k < 4; k++){
			VoxelInstance n = peek(world, pv::Vector3DInt32(
					p.getX() + SIDE[k][0], p.getY(),
					p.getZ() + SIDE[k][1]));
			if(!material_of(id_of(n)).structural)
				continue;
			uint8_t s = support_of(n);
			if(s > best)
				best = s;
		}
		if(best == 0)
			return 0;
		uint8_t reach = best - 1;
		return reach < m.span ? reach : m.span;
	}

	// How near the voxel at p is to water: MOISTURE_MAX next to it, one less
	// per step through anything porous, 0 anywhere water cannot reach. The
	// same shape of relaxation as the support, and it dries by running back
	// down when the water goes away.
	uint8_t compute_moisture(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p, const MaterialProps &m)
	{
		if(!m.porous)
			return 0;
		static const int OFF[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
		};
		uint8_t best = 0;
		for(size_t k = 0; k < 6; k++){
			VoxelInstance n = peek(world, pv::Vector3DInt32(
					p.getX() + OFF[k][0], p.getY() + OFF[k][1],
					p.getZ() + OFF[k][2]));
			interface::VoxelTypeId nid = id_of(n);
			if(nid == M_WATER)
				return MOISTURE_MAX;
			const MaterialProps &nm = material_of(nid);
			if(!nm.porous)
				continue;
			uint8_t through = moisture_of(n);
			if(through > 1 && (uint8_t)(through - 1) > best)
				best = through - 1;
		}
		return best;
	}

	// The weight resting on the voxel at p: the column immediately above it,
	// as far as LOAD_DEPTH. See LOAD_DEPTH for why it stops.
	uint8_t compute_load(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p)
	{
		int carried = 0;
		for(int i = 1; i <= LOAD_DEPTH; i++){
			VoxelInstance v = peek(world,
					pv::Vector3DInt32(p.getX(), p.getY() + i, p.getZ()));
			const MaterialProps &m = material_of(id_of(v));
			if(!m.structural)
				break;
			carried += m.density;
			if(carried >= LOAD_MAX)
				return LOAD_MAX;
		}
		return (uint8_t)carried;
	}

	// Work out one voxel again, write it if either number moved, and say
	// whether anything around it has to be looked at as a result.
	void update_voxel(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p)
	{
		VoxelInstance v = peek(world, p);
		interface::VoxelTypeId id = id_of(v);
		if(id == interface::VOXELTYPEID_UNDEFINED)
			return; // Not generated yet; whoever generates it computes both
		const MaterialProps &m = material_of(id);
		if(!m.structural)
			return;
		// What water has done to it, and what that makes it. A material
		// change is the only way the mesher can see this -- both nibbles of
		// the param are spoken for -- and it is the right way round anyway:
		// wet dirt is a different thing from dirt, with its own numbers.
		uint8_t moisture = compute_moisture(world, p, m);
		interface::VoxelTypeId want = id;
		if(moisture > 0 && m.wet_of != 0)
			want = (interface::VoxelTypeId)m.wet_of;
		else if(moisture == 0 && m.dry_of != 0)
			want = (interface::VoxelTypeId)m.dry_of;
		const MaterialProps &wm = material_of(want);

		uint8_t support = compute_support(world, p, wm);
		uint8_t load = compute_load(world, p);
		uint8_t band = load_band(load, wm.capacity);
		bool support_moved = support != support_of(v);
		bool wetness_moved = moisture != moisture_of(v) || want != id;
		if(want != id){
			log_t(MODULE, "wet: " PV3I_FORMAT " %i -> %i (moisture %i)",
					PV3I_PARAMS(p), (int)id, (int)want, (int)moisture);
		}
		if(support_moved || wetness_moved || band != band_of(v)){
			VoxelInstance nv = v;
			F_ID.set(nv.data, want);
			F_MOISTURE.set(nv.data, moisture);
			set_state(nv, support, band);
			m_scratch[pos_key(p)] = Pending{p, nv};
		}
		// A support that moved changes what the voxels around it can reach,
		// and so does water arriving or leaving
		if(support_moved || wetness_moved){
			static const int OFF[6][3] = {
				{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
			};
			for(size_t k = 0; k < 6; k++)
				mark_dirty(pv::Vector3DInt32(p.getX() + OFF[k][0],
						p.getY() + OFF[k][1], p.getZ() + OFF[k][2]));
		}
		// Nothing holds it, or what does cannot carry what is on it
		if(wm.diggable && (support == 0 || load > wm.capacity)){
			log_t(MODULE, "fails: " PV3I_FORMAT " id=%i support=%i load=%i",
					PV3I_PARAMS(p), (int)id, (int)support, (int)load);
			mark_falling(p);
		}
	}

	// Move what is falling down one voxel, or turn it to rubble where it
	// stops. Lowest first, so a column comes down without opening a gap in
	// the middle of itself.
	size_t m_moved = 0;
	size_t m_landed = 0;

	void step_falling(voxelworld::Instance *world)
	{
		if(m_falling.empty())
			return;
		std::sort(m_falling.begin(), m_falling.end(),
				[](const pv::Vector3DInt32 &a, const pv::Vector3DInt32 &b){
			return a.getY() < b.getY();
		});
		size_t n = m_falling.size() < FALL_PER_TICK ?
				m_falling.size() : FALL_PER_TICK;
		std::vector<pv::Vector3DInt32> rest(m_falling.begin() + n,
				m_falling.end());
		std::vector<pv::Vector3DInt32> batch(m_falling.begin(),
				m_falling.begin() + n);
		m_falling = rest;
		for(const pv::Vector3DInt32 &p : batch){
			m_falling_set.erase(pos_key(p));
			VoxelInstance v = world->get_voxel(p, true);
			interface::VoxelTypeId id = id_of(v);
			const MaterialProps &m = material_of(id);
			// It may have been dug, or held up again, since it was queued
			if(!m.structural || !m.diggable)
				continue;
			// The weight itself, not the band: the band is a sixteenth of a
			// capacity coarse and this is the test that decides whether
			// something comes down
			if(support_of(v) != 0 &&
					compute_load(world, p) <= m.capacity)
				continue;
			pv::Vector3DInt32 down(p.getX(), p.getY() - 1, p.getZ());
			VoxelInstance bv = world->get_voxel(down, true);
			interface::VoxelTypeId bid = id_of(bv);
			if(bid == interface::VOXELTYPEID_UNDEFINED)
				continue; // Falling out of the loaded world; leave it be
			if(bid == M_AIR || bid == M_WATER){
				// Down one. What it lands in is displaced rather than
				// simulated: nothing here flows.
				//
				// What it becomes on the way down; see MaterialProps.
				// Rubble spans nothing, so a pile of it holds no roof up,
				// which is what makes a cave-in carry on rather than plug
				// itself -- and the materials that are already loose heaps
				// stay themselves.
				VoxelInstance nv((uint32_t)(m.falls_as != 0 ?
						m.falls_as : (int)id));
				set_state(nv, 0, 0);
				world->set_voxel(down, nv, true);
				world->set_voxel(p, VoxelInstance(M_AIR), true);
				mark_changed(p);
				mark_changed(down);
				mark_falling(down);
				m_moved++;
			} else {
				// It has come to rest on something. It keeps whatever it
				// became on the way down.
				m_landed++;
			}
		}
	}

	// Everything the relaxation worked out, into the world in one go.
	//
	// simplified: the whole scratch goes at once rather than on a budget. It
	// is one set_voxel() per voxel the front passed over, which is the work
	// that used to happen several times each.
	void flush_scratch(voxelworld::Instance *world)
	{
		if(m_scratch.empty())
			return;
		for(auto &e : m_scratch)
			world->set_voxel(e.second.p, e.second.v, true);
		m_wrote += m_scratch.size();
		m_scratch.clear();
	}

	size_t m_wrote = 0;

	void on_tick(const interface::TickEvent &event)
	{
		if(m_dirty.empty() && m_falling.empty())
			return;
		auto t0 = std::chrono::steady_clock::now();
		size_t done = 0;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			while(!m_dirty.empty() && done < SIM_PER_TICK){
				pv::Vector3DInt32 p = m_dirty.front();
				m_dirty.pop_front();
				m_dirty_set.erase(pos_key(p));
				update_voxel(world, p);
				done++;
			}
			// Into the world once the front has passed, or when something
			// is about to move and the relaxation's answers are needed
			if(m_dirty.empty() || !m_falling.empty() ||
					m_scratch.size() > 8192)
				flush_scratch(world);
			step_falling(world);
		});
		if(done >= SIM_PER_TICK || !m_falling.empty()){
			log_v(MODULE, "sim: %zu done in %i us, %zu dirty, %zu pending, "
					"%zu falling, %zu fell, %zu came to rest, %zu written",
					done, (int)std::chrono::duration_cast<
							std::chrono::microseconds>(
							std::chrono::steady_clock::now() - t0).count(),
					m_dirty.size(), m_scratch.size(), m_falling.size(),
					m_moved, m_landed, m_wrote);
		}
	}


	// Structures
	// ----------
	//
	// Finding out what happens when a pillar is cut should not start with an
	// hour of bricklaying, so the game can put a building up for you. Each is
	// a loop rather than a table of voxels: parametric, a few dozen lines,
	// and no data to keep in step with the material ids.
	//
	// A structure carries its own air. A cathedral inside a hill is no use,
	// so the footprint is cleared as it is written -- which is why this is
	// set_voxel() per voxel and not Instance::merge_volume(), whose whole
	// contract is that it does not overwrite what is already there.
	//
	// Everything is written first and only then handed to the simulation.
	// Halfway through, a cathedral is an unsupported roof, and it would come
	// down while it was being built.
	struct Build
	{
		std::vector<std::pair<pv::Vector3DInt32, int>> voxels;

		void box(int x0, int y0, int z0, int x1, int y1, int z1, int material)
		{
			for(int y = y0; y <= y1; y++)
				for(int z = z0; z <= z1; z++)
					for(int x = x0; x <= x1; x++)
						voxels.push_back(
								{pv::Vector3DInt32(x, y, z), material});
		}
	};

	// A hollow room with a flat roof, wide enough that rock cannot span it:
	// the middle of the roof has nothing to reach and comes down as soon as
	// the simulation looks at it. The smallest thing that shows the rules
	// working, and the one to place first when they change.
	static void build_chamber(Build &b, const pv::Vector3DInt32 &o)
	{
		const int half = 7; // 15 across, and rock spans 6
		const int height = 5;
		const int x0 = o.getX(), y0 = o.getY(), z0 = o.getZ();
		b.box(x0 - half, y0, z0 - half,
				x0 + half, y0 + height, z0 + half, M_AIR);
		b.box(x0 - half - 1, y0 - 1, z0 - half - 1,
				x0 + half + 1, y0 - 1, z0 + half + 1, M_BRICK);
		b.box(x0 - half - 1, y0 + height + 1, z0 - half - 1,
				x0 + half + 1, y0 + height + 1, z0 + half + 1, M_ROCK);
		for(int y = y0; y <= y0 + height; y++){
			b.box(x0 - half - 1, y, z0 - half - 1,
					x0 - half - 1, y, z0 + half + 1, M_ROCK);
			b.box(x0 + half + 1, y, z0 - half - 1,
					x0 + half + 1, y, z0 + half + 1, M_ROCK);
			b.box(x0 - half - 1, y, z0 - half - 1,
					x0 + half + 1, y, z0 - half - 1, M_ROCK);
			b.box(x0 - half - 1, y, z0 + half + 1,
					x0 + half + 1, y, z0 + half + 1, M_ROCK);
		}
	}

	// A nave with a row of brick pillars down each side carrying a rock roof,
	// and timber tie beams across between the pillars. The pillars are what
	// hold it up: cut one and the roof over it has to reach the next one,
	// which is further than rock spans.
	static void build_cathedral(Build &b, const pv::Vector3DInt32 &o)
	{
		const int half_w = 6;   // 13 across inside
		const int length = 28;
		const int height = 10;
		const int spacing = 4;  // pillars this far apart along the nave
		const int x0 = o.getX(), y0 = o.getY(), z0 = o.getZ();
		b.box(x0 - half_w - 1, y0, z0 - 1,
				x0 + half_w + 1, y0 + height + 2, z0 + length + 1, M_AIR);
		b.box(x0 - half_w - 1, y0 - 1, z0 - 1,
				x0 + half_w + 1, y0 - 1, z0 + length + 1, M_BRICK);
		for(int z = z0; z <= z0 + length; z += spacing){
			for(int side = -1; side <= 1; side += 2){
				int x = x0 + side * half_w;
				b.box(x, y0, z, x, y0 + height, z, M_BRICK);
			}
			// A tie beam across, which is what a timber prop is for: long
			// span, and it carries only the roof over the nave
			b.box(x0 - half_w + 1, y0 + height, z,
					x0 + half_w - 1, y0 + height, z, M_TIMBER);
		}
		b.box(x0 - half_w, y0 + height + 1, z0,
				x0 + half_w, y0 + height + 1, z0 + length, M_ROCK);
	}

	// A deck on piers. Saw through a pier and the deck over it is left
	// spanning twice the distance, which rock will not do.
	static void build_bridge(Build &b, const pv::Vector3DInt32 &o)
	{
		const int length = 40;
		const int half_w = 2;
		const int spacing = 10;
		const int depth = 12; // how far down the piers reach for ground
		const int x0 = o.getX(), y0 = o.getY(), z0 = o.getZ();
		b.box(x0 - half_w, y0 + 1, z0,
				x0 + half_w, y0 + 4, z0 + length, M_AIR);
		b.box(x0 - half_w, y0, z0, x0 + half_w, y0, z0 + length, M_ROCK);
		// Parapets, so it reads as a bridge from on it
		b.box(x0 - half_w, y0 + 1, z0,
				x0 - half_w, y0 + 1, z0 + length, M_BRICK);
		b.box(x0 + half_w, y0 + 1, z0,
				x0 + half_w, y0 + 1, z0 + length, M_BRICK);
		for(int z = z0; z <= z0 + length; z += spacing)
			b.box(x0 - 1, y0 - depth, z, x0 + 1, y0 - 1, z, M_BRICK);
	}

	// A mineshaft: a corridor with a timber prop frame every few voxels,
	// which is what the game teaches you to build by hand.
	static void build_mineshaft(Build &b, const pv::Vector3DInt32 &o)
	{
		const int length = 40;
		const int half_w = 2;   // 5 across, which dirt cannot roof alone
		const int height = 3;
		const int spacing = 3;
		const int x0 = o.getX(), y0 = o.getY(), z0 = o.getZ();
		b.box(x0 - half_w, y0, z0,
				x0 + half_w, y0 + height, z0 + length, M_AIR);
		for(int z = z0; z <= z0 + length; z += spacing){
			b.box(x0 - half_w, y0, z, x0 - half_w, y0 + height, z, M_TIMBER);
			b.box(x0 + half_w, y0, z, x0 + half_w, y0 + height, z, M_TIMBER);
			b.box(x0 - half_w, y0 + height, z,
					x0 + half_w, y0 + height, z, M_TIMBER);
		}
	}

	void on_place_structure(const network::Packet &packet)
	{
		ss_ name;
		pv::Vector3DInt32 p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(name, p);
		}
		Build b;
		if(name == "chamber")
			build_chamber(b, p);
		else if(name == "cathedral")
			build_cathedral(b, p);
		else if(name == "bridge")
			build_bridge(b, p);
		else if(name == "mineshaft")
			build_mineshaft(b, p);
		else {
			log_w(MODULE, "C%i: no structure called \"%s\"",
					packet.sender, cs(name));
			return;
		}
		log_i(MODULE, "C%i: %s at " PV3I_FORMAT ", %zu voxels",
				packet.sender, cs(name), PV3I_PARAMS(p), b.voxels.size());

		// simplified: the whole thing goes in on one tick. A cathedral is a
		// few thousand set_voxel() calls, which is a hitch and not a stall,
		// and it is a deliberate action rather than something that happens
		// while playing. A budget over ticks is the upgrade path, and it
		// would have to keep the simulation off the footprint until the last
		// voxel is in.
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(auto &vp : b.voxels){
				VoxelInstance v((uint32_t)vp.second);
				// Held up until the simulation says otherwise, so that the
				// building does not fall over as it is written
				set_state(v, SUPPORT_MAX, 0);
				world->set_voxel(vp.first, v, true);
			}
		});
		// And now let it stand or fall as a whole
		for(auto &vp : b.voxels)
			mark_changed(vp.first);

		// What it takes up, so that a client in free move can put itself
		// somewhere the whole thing is in frame instead of the player having
		// to fly around looking for it
		pv::Vector3DInt32 lc = b.voxels[0].first, uc = b.voxels[0].first;
		for(auto &vp : b.voxels){
			lc.setX(std::min(lc.getX(), vp.first.getX()));
			lc.setY(std::min(lc.getY(), vp.first.getY()));
			lc.setZ(std::min(lc.getZ(), vp.first.getZ()));
			uc.setX(std::max(uc.getX(), vp.first.getX()));
			uc.setY(std::max(uc.getY(), vp.first.getY()));
			uc.setZ(std::max(uc.getZ(), vp.first.getZ()));
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(lc, uc);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "main:structure_placed", os.str());
		});
	}

	void on_place_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 voxel_p;
		int32_t material = M_ROCK;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p, material);
		}
		// Water is placeable even though the rules do not treat it as
		// structural: pouring some next to dirt is how you find out what
		// water does to dirt, which is most of what there is to find out.
		if(material <= M_AIR || material >= M_COUNT ||
				(!material_of(material).structural &&
						material != M_WATER)){
			log_w(MODULE, "C%i: on_place_voxel(): material %i is not one to "
					"build with", packet.sender, material);
			return;
		}
		log_v(MODULE, "C%i: on_place_voxel(): p=" PV3I_FORMAT " material=%i",
				packet.sender, PV3I_PARAMS(voxel_p), material);

		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *instance)
		{
			VoxelInstance v((uint32_t)material);
			// Something just placed is held up by whatever it was placed
			// against until the simulation says otherwise, which keeps a
			// prop from falling in the tick before it is looked at
			set_state(v, SUPPORT_MAX, 0);
			instance->set_voxel(voxel_p, v);
		});
		mark_changed(voxel_p);
	}

	void on_dig_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 voxel_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		}
		log_v(MODULE, "C%i: on_dig_voxel(): p=" PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(voxel_p));

		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *instance)
		{
			const interface::VoxelFormat &fmt =
					instance->get_voxel_reg()->get_format();
			VoxelInstance old = instance->get_voxel(voxel_p, true);
			if(!material_of(fmt.id_of(old.data)).diggable){
				log_v(MODULE, "C%i: on_dig_voxel(): not diggable",
						packet.sender);
				return;
			}
			instance->set_voxel(voxel_p, VoxelInstance(M_AIR));
		});
		mark_changed(voxel_p);
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &event)
	{
		log_t(MODULE, "on_worldgen_queue_modified()");
		network::access(m_server, [&](network::Interface *inetwork){
			sv_<network::PeerInfo::Id> peers = inetwork->list_peers();
			for(auto &peer: peers){
				inetwork->send(peer, "main:worldgen_queue_size",
						itos(event.queue_size));
			}
		});
		if(event.queue_size == 0)
			try_resolve_spawn();
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
