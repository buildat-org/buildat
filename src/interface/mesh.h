// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include <PolyVoxCore/RawVolume.h>
#include <CustomGeometry.h>

namespace Urho3D
{
	class Context;
	class Model;
	class CustomGeometry;
	class Node;
}

namespace interface
{
	namespace mesh
	{
		using namespace Urho3D;
		namespace pv = PolyVox;

		// Create a model from a string; eg. (2, 2, 2, "11101111")
		Model* create_simple_voxel_model(Context *context, int w, int h, int d,
				const ss_ &source_data);

		// Create a model from 8-bit voxel data, using a voxel registry, without
		// textures or normals, based on the physically_solid flag.
		// Returns nullptr if there is no geometry
		Model* create_8bit_voxel_physics_model(Context *context,
				int w, int h, int d, const ss_ &source_data,
				VoxelRegistry *voxel_reg);

		// Set custom geometry from 8-bit voxel data, using a voxel registry.
		// uv_origin is where this block's (0, 0, 0) sits in the world, which
		// is what a voxel of uv_scale > 1 takes its slice of the repeat from
		// ([WORLD_UV]); without it every voxel gets the whole texture.
		void set_8bit_voxel_geometry(CustomGeometry *cg, Context *context,
				int w, int h, int d, const ss_ &source_data,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				const pv::Vector3DInt32 &uv_origin = pv::Vector3DInt32(0, 0, 0));

		// Create a model from voxel volume, using a voxel registry, without
		// textures or normals, based on the physically_solid flag.
		// Returns nullptr if there is no geometry
		// Volume should be padded by one voxel on each edge
		// NOTE: volume is non-const due to PolyVox deficiency
		Model* create_voxel_physics_model(Context *context,
				VoxelVolume &volume,
				VoxelRegistry *voxel_reg);

		// Voxel geometry generation

		struct TemporaryGeometry
		{
			uint atlas_id = 0;
			// Set when the generator wrote skylight into vertex colors
			bool has_colors = false;
			// Set when the generator wrote the voxel format's surface
			// modifiers into the vertex tangent; see VoxelFormat in
			// interface/voxel.h
			bool has_tangents = false;
			// CustomGeometry can't handle an index buffer
			PODVector<CustomGeometryVertex> vertex_data;
		};

		// with_lod also builds the atlas segments a LOD mesh samples; see
		// VoxelRegistry::get_cached()
		// **A chunk's preload, a slice at a time** ([CLIENT_FRAME],
		// 2026-09-26). Building an atlas segment for a voxel seen for the
		// first time is what a join's 858 to 1265 ms first chunk is made
		// of, and it happens on the thread that asked for the mesh. This
		// carries a cursor, does what it can before the deadline and says
		// whether it is done, so the caller can come back next frame.
		struct PreloadCursor
		{
			int x = 0, y = 0, z = 0;
			bool started = false;
			// Voxels done since the clock was last read: building one
			// voxel's atlas segment is milliseconds, so the deadline has
			// to be looked at inside a row and not only between rows
			int since_clock = 0;
		};
		bool preload_textures_sliced(VoxelVolume &volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool with_lod, int64_t deadline_us, PreloadCursor &cursor);

		void preload_textures(VoxelVolume &volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool with_lod = false);

		// What a voxel shader is handed, which is the whole interface between
		// this and a game's own rendering:
		//   TU_DIFFUSE   the atlas of the voxel textures
		//   TU_NORMAL    tangent space normal in rgb, static_spots in a
		//   TU_SPECULAR  a surface map, not Urho's specular: roughness in r
		//                and spec_strength, translucency and spots in gba
		//   vertex color ambient = cAmbientColor.rgb * a + rgb, when
		//                use_skylight. The alpha is how much of the sky the
		//                surface sees and the rgb is the light that reaches
		//                it regardless of the sky: bounced light, and the
		//                voxel's lamplight. See BOUNCE_COLOR and LAMP_COLOR
		//                in impl/mesh.cpp. cAmbientColor being the color of
		//                the sky, a world moves the sun by setting it and
		//                nothing has to be meshed again.
		//   vertex tangent  the voxel format's surface modifiers, one per
		//                component, when the world binds any. 0...1 each,
		//                except the tint, whose component carries the colour
		//                its ramp picked packed 5-6-5 and which the shader
		//                multiplies into the albedo.
		//                Which modifier is in which component is the format's
		//                own order -- tint, wetness, grain, gloss, speckle,
		//                emission, the bound ones packed towards x -- and a
		//                shader knows its own world's. There is no tangent
		//                to lose: a voxel face is axis-aligned, so a shader
		//                that wants one derives it from the normal.
		//   Roughness, Metallic  both 0; the maps carry these
		// interface/atlas.h says what fills the two maps. No technique is set:
		// a game picks one for its chunks in voxelworld.sub_material_update(),
		// and skylit geometry stays invisible until it does. The reference
		// implementation is PBRVoxel in apps/voxel_lighting.

		// A voxel whose definition has a shape contributes that shape's quads
		// instead of cube faces; see VoxelDefinition::shape in
		// interface/voxel.h. The LOD generators below do not do this, so a
		// world that uses LOD loses its shaped voxels in the distance.
		//
		// Can be called from any thread
		// use_skylight: light the geometry by the format's light_sky and
		// light_lamp of the voxel in front of each face, along with
		// per-vertex ambient occlusion and a per-face brightness, written
		// into vertex colors. Only worlds that actually fill those bits
		// should ask for it.
		//
		// translucent_result, when given, takes the faces of the voxels the
		// registry says are translucent -- water, and glass a game gave an
		// alpha to -- instead of the opaque result. They are a separate
		// drawable so that they can be drawn after the solid world, and so
		// that the renderer sorts them against the other chunks' by
		// distance. Left out, everything goes in one geometry as before.
		//
		// masked_result is the same arrangement for the voxels the registry
		// says are alpha masked -- leaves, a plant, anything whose picture
		// has holes in it. Those are drawn with the solid world and only
		// want a material of their own, and a material is per drawable.
		// The terrain's own occlusion of the sky, at the scale the corner
		// table and a chunk's padding cannot see: the highest solid voxel
		// of every column in a HORIZON_SIZE-square neighbourhood of the
		// chunk, world y, HORIZON_NONE where nothing is loaded, laid out
		// [z][x] from `origin` (the chunk's world origin minus HORIZON_PAD
		// on x and z; origin_y is the chunk's own). The mesher walks it eight ways from each face and
		// folds the dome's unobstructed cap into the sky share; a client
		// that passes none gets the whole dome. See [PBR_FIT] 2c.
		static const int HORIZON_PAD = 32;
		static const int HORIZON_SIZE = 32 + 2 * HORIZON_PAD;
		static const int16_t HORIZON_NONE = -32768;
		struct HorizonMap
		{
			int32_t origin_x = 0, origin_y = 0, origin_z = 0;
			int16_t heights[HORIZON_SIZE * HORIZON_SIZE];
		};

		void generate_voxel_geometry(sm_<uint, TemporaryGeometry> &result,
				VoxelVolume &volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool use_skylight = false,
				sm_<uint, TemporaryGeometry> *translucent_result = nullptr,
				sm_<uint, TemporaryGeometry> *masked_result = nullptr,
				const HorizonMap *horizon = nullptr,
				const pv::Vector3DInt32 *uv_origin = nullptr);

		// **A cheap stand-in shape for the occlusion buffer**
		// ([CLIENT_FRAME]). A chunk's drawn mesh is thousands of triangles
		// of surface detail saying what a few quads would, and Urho3D
		// rasterises occluders on the processor out of a triangle budget,
		// so the whole budget goes on the first chunk that comes along.
		// This is the same silhouette at four voxels to a cell: a cell
		// counts only when every voxel in it is opaque and fills itself,
		// so the shape lies *inside* the solid it stands for and can never
		// hide what is visible. A plain triangle list in the same local
		// space as the chunk's mesh, for
		// CustomGeometry::SetOcclusionGeometry(); empty when the chunk has
		// no solid worth the name.
		void generate_occluder(PODVector<Vector3> &result,
				VoxelVolume &volume, VoxelRegistry *voxel_reg);

		// The light the unpacked layout bakes into every face the sky does
		// not reach, in the vertex colour's units: 0.055, 0.050, 0.045 by
		// default. For every mesh made after the call, in this process.
		void set_bounce_color(float r, float g, float b);

		// The unpacked layout's alpha as the packed one's two nibbles, the
		// sky high and the shade low, its rgb as it is: a sealed cave's
		// corners for extensions/luanti_client's pbr ([CAVE_EXPOSURE_FLOOR]).
		// For every mesh made after the call, in this process.
		void set_alpha_nibbles(bool on);

		// A chunk's column heights for a HorizonMap: the local y of the
		// highest voxel with an edge material that is not a cutout, per
		// column, HORIZON_NONE where the column has none; w*d int16_t in
		// [z][x] order over the volume's inside (its padding left out).
		sv_<int16_t> column_heights(VoxelVolume &volume,
				VoxelRegistry *voxel_reg);

		void set_voxel_geometry(CustomGeometry *cg, Context *context,
				const sm_<uint, TemporaryGeometry> &temp_geoms,
				AtlasRegistry *atlas_reg);

		// Set custom geometry from voxel volume, using a voxel registry
		// Volume should be padded by one voxel on each edge
		// NOTE: volume is non-const due to PolyVox deficiency
		void set_voxel_geometry(CustomGeometry *cg, Context *context,
				VoxelVolume &volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool use_skylight = false,
				const pv::Vector3DInt32 *uv_origin = nullptr);

		// Voxel LOD geometry generation (lod=1 -> 1:1, lod=3 -> 1:3)

		// Can be called from any thread
		// voxel_reg is only read for its voxel format: which bits of a voxel
		// are the type id the downsampling picks by
		up_<VoxelVolume> generate_voxel_lod_volume(
				int lod, VoxelVolume&volume_orig,
				VoxelRegistry *voxel_reg);

		// Can be called from any thread
		void generate_voxel_lod_geometry(int lod,
				sm_<uint, TemporaryGeometry> &result,
				VoxelVolume &lod_volume,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool use_skylight = false,
				const HorizonMap *horizon = nullptr);

		void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
				const sm_<uint, TemporaryGeometry> &temp_geoms,
				AtlasRegistry *atlas_reg);

		void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
				VoxelVolume &volume_orig,
				VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
				bool use_skylight = false);

		// Voxel physics generation

		struct TemporaryBox
		{
			Vector3 size;
			Vector3 position;
		};

		// Can be called from any thread
		void generate_voxel_physics_boxes(
				sv_<TemporaryBox> &result_boxes,
				VoxelVolume &volume,
				VoxelRegistry *voxel_reg);

		void set_voxel_physics_boxes(Node *node, Context *context,
				const sv_<TemporaryBox> &boxes, bool do_update_mass);

		void set_voxel_physics_boxes(Node *node, Context *context,
				VoxelVolume &volume,
				VoxelRegistry *voxel_reg);
	}
}
// vim: set noet ts=4 sw=4:
