// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// A finite heightmap surface ([HEIGHTMAP_TERRAIN]): a 2D grid of heights and
// per-sample material weights, in square chunks, saved in the app's save,
// sent to the clients (the whole map at join, the changed chunks after), and
// on both sides an Urho3D Terrain: on the server for Bullet's heightfield
// (CollisionShape::SetTerrain), on the client drawn with LOD per patch and
// splatted from the weights (TerrainBlend). One per scene.
//
// The grid is samples_x() x samples_z() heights, a sample every cell_size
// metres from the scene's origin: sample (x, z) is at world (x * cell_size,
// height, z * cell_size). The surface ends at the last sample; past it there
// is nothing (finite only; no holes).
//
// Heights are kept as 16 bits: base_y + n * HEIGHT_STEP, n 0..65535, so a
// map spans base_y .. base_y + 655.35 m in centimetres. A set height is
// rounded to that and clamped into it.
//
// A chunk's data, as saved and as sent (one format): a byte 1, then zstd of
// chunk_size^2 heights as big-endian uint16 (x fastest, then z), then
// chunk_size^2 weights as 3 bytes, one a material. Big-endian because that
// is the 2-component Image Urho3D's Terrain reads (R + G/256), which the
// client then fills without touching a byte.
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "interface/noise.h"
#include "storage/api.h"
#include <array>
#include <functional>

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}

namespace heightmap
{
	using main_context::SceneReference;

	// The materials a sample blends, which TerrainBlend's three detail
	// textures are: weights need not sum to anything, the shader divides
	// by the sum (0, 0, 0 reads as the first material)
	static const int NUM_MATERIALS = 3;
	typedef std::array<uint8_t, NUM_MATERIALS> Weights;

	static const float HEIGHT_STEP = 0.01f;

	struct Size
	{
		int chunks_x = 16;
		int chunks_z = 16;
		// Samples a chunk side; a multiple of the client's Terrain patch
		// (64), so a chunk's change rebuilds whole patches
		int chunk_size = 64;
		float cell_size = 1.0f;
		float base_y = 0.0f;
	};

	// generate(): height = height.offset + height.scale * fbm(x / spread),
	// in metres (interface/noise.h); material 0 (grass) where flat and
	// above sand_below, 1 (rock) where steeper than rock_slope (rise over
	// run), 2 (sand) below sand_below, blended over a metre or a tenth of
	// a slope. The same parameters and seed give the same map, byte for
	// byte, on the same build.
	struct GenerateParams
	{
		uint32_t seed = 0;
		interface::noise::NoiseParams height = {
			30.0f, 40.0f, 300.0f, 1.0f, 300.0f, 6, 0.5f};
		float sand_below = 14.0f;
		float rock_slope = 0.35f;
	};

	struct Instance;

	// [HEIGHTMAP_TERRAIN] The copy-on-write's place: before_write is called
	// once for a chunk the first time something writes it after the last
	// commit, with its data as it was (the format above), before the
	// write. A snapshot (Kit's Stop and origins) keeps that copy for the
	// chunks it has not got yet. Runs inside whatever module is writing.
	struct ChunkHook
	{
		virtual ~ChunkHook(){}
		virtual void before_write(Instance *map, int chunk_x, int chunk_z,
				const ss_ &old_data) = 0;
	};

	struct Instance
	{
		virtual const Size& get_size() = 0;
		virtual int samples_x() = 0;
		virtual int samples_z() = 0;

		// Out of the grid is an error (an exception), as voxelworld's is
		// not; a map is finite and its caller knows how big
		virtual float get_height(int x, int z) = 0;
		virtual void set_height(int x, int z, float height) = 0;
		virtual Weights get_weights(int x, int z) = 0;
		virtual void set_weights(int x, int z, const Weights &weights) = 0;

		// The surface's height at a world point, as the Terrain's triangles
		// have it (Urho3D Terrain::GetHeight's split); clamped to the grid
		virtual float height_at(float world_x, float world_z) = 0;

		// Every sample set from the noise; every chunk then written
		virtual void generate(const GenerateParams &params) = 0;

		// The save the map lives in, under name (store "heightmap", keys
		// "<name>/meta" and "<name>/<cx>,<cz>"): true when the save had a
		// map of this name and size and it was read, false when not, which
		// leaves the map as it was (the app generates). A map of another
		// size in the save is refused with a warning and false.
		virtual bool set_save(storage::Save *save, const ss_ &name) = 0;

		virtual void add_chunk_hook(up_<ChunkHook> hook) = 0;

		// What was written since the last commit: the server's Terrain and
		// heightfield rebuilt, the changed chunks sent to the clients on
		// the scene and written to the save. Done by the module each tick;
		// call it to have a change in the collision now
		virtual void commit() = 0;

		// FNV-1a over every chunk's raw heights and weights, x then z: what
		// a check compares between a generation, a save and a load
		virtual uint32_t content_hash() = 0;
	};

	struct Interface
	{
		// The map is flat at base_y until generated, loaded or set
		virtual Instance* create_instance(SceneReference scene,
				const Size &size) = 0;
		virtual void delete_instance(SceneReference scene) = 0;
		virtual Instance* get_instance(SceneReference scene) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(heightmap::Interface*)> cb)
	{
		return server->access_module("heightmap", [&](interface::Module *module){
			cb((heightmap::Interface*)module->check_interface());
		});
	}

	inline bool access(interface::Server *server, SceneReference scene,
			std::function<void(heightmap::Instance*)> cb)
	{
		return access(server, [&](heightmap::Interface *i){
			cb(check(i->get_instance(scene)));
		});
	}
}

// vim: set noet ts=4 sw=4:
