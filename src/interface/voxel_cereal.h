// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include "interface/voxel_selector.h"
#include "interface/atlas_cereal.h"
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>

namespace interface
{
	template<class Archive>
			void serialize(Archive &archive, VoxelName &v)
	{
		uint8_t version = 1;
		archive(
				version,
				v.block_name,
				v.segment_x,
				v.segment_y,
				v.segment_z,
				v.rotation_primary,
				v.rotation_secondary
		);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelQuad &v)
	{
		for(size_t i = 0; i < 4; i++){
			archive(v.p[i][0], v.p[i][1], v.p[i][2]);
			archive(v.uv[i][0], v.uv[i][1]);
		}
		archive(v.tile, v.connect_dir);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelVariant &v)
	{
		uint8_t version = 4;
		archive(version, v.shape, v.color, v.liquid_top, v.textures);
		for(size_t i = 0; i < 6; i++)
			archive(v.tile_order[i], v.tile_turns[i]);
		// Version 3 added what stops the player ([VL_STAIRS])
		if(version >= 3)
			archive(v.collision_boxes);
		// Version 4 added what is pointed at ([VL_RAIL_BOXES])
		if(version >= 4)
			archive(v.selection_boxes);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelDefinition &v)
	{
		uint8_t version = 25;
		archive(
				version,
				v.name,
				v.id,
				v.textures,
				v.handler_module,
				v.face_draw_type,
				v.edge_material_id,
				v.physically_solid,
				v.fully_empty,
				v.shape,
				v.shape_double_sided,
				v.translucent,
				v.shape_group,
				v.is_liquid,
				v.liquid_top,
				v.connect_group,
				v.connect_mask,
				v.connect_to_solid,
				v.shape_masked
		);
		for(size_t i = 0; i < 21; i++)
			archive(v.shape_masked_begin[i]);
		archive(v.variants);
		if(!v.variants.empty()){
			for(size_t i = 0; i < 256; i++)
				archive(v.variant_of_param[i]);
		}
		// Version 9 had no modifier parameters; see the note on VoxelFormat
		// below for why this branch reads as "10 or newer" and writes always
		if(version >= 10){
			archive(v.tint_ramp[0], v.tint_ramp[1], v.sag_extent);
		}
		// Version 11 added the textures a shape's quads can wear beyond the
		// six faces. A count and then that many, so a definition without
		// any pays one byte.
		if(version >= 11){
			archive(v.extra_textures);
		}
		// Version 12 added the flag that says a shape stands in the voxel
		// above its own
		if(version >= 12){
			archive(v.shape_lit_from_above);
		}
		// Version 13 split "light gets past this" out of the edge material
		if(version >= 13){
			archive(v.transmits_light);
		}
		// Version 14 added the alpha-masked class, which is drawn with the
		// solid world and cut out by its texture
		if(version >= 14){
			archive(v.alpha_masked);
		}
		// Version 15 added the ladder flag, which only the client's own
		// physics reads
		if(version >= 15){
			archive(v.climbable);
		}
		// Version 16 added how much a voxel holds a body back, which the
		// same physics reads
		if(version >= 16){
			archive(v.move_resistance);
		}
		// Version 17 added the light a voxel makes of its own, which a
		// client's mesh dump names for the path trace to emit from
		// ([LAMP_REF]); the server's flood had it, the client's registry
		// read it as zero
		if(version >= 17){
			archive(v.light_source);
		}
		// Version 18 added the standing node's physics groups, which the
		// client's physics reads ([PLAYER_PHYSICS])
		if(version >= 18){
			archive(v.bouncy, v.slippery, v.disable_jump, v.disable_descend);
		}
		// Version 19 added liquid_move_physics, what the player is in
		// ([WATER_PARITY])
		if(version >= 19){
			archive(v.swimmable);
		}
		// Version 20 added pointable, what the ray stops at ([POINTABLE])
		if(version >= 20){
			archive(v.pointable);
		}
		// Version 21 added whether a liquid is its source, which the
		// mesher's corner rule reads ([WATER_LIGHT] 3)
		if(version >= 21){
			archive(v.liquid_is_source);
		}
		// Version 22 added how many voxels a texture spans before it
		// repeats ([WORLD_UV])
		if(version >= 22){
			archive(v.uv_scale);
		}
		// Version 23 made that per-axis: 22's number is across and this
		// one is up, nought meaning "the same" ([SIGIL_ROUND])
		if(version >= 23){
			archive(v.uv_scale_v);
		}
		// Version 24 added what stops the player when it is not the cube
		// ([VL_STAIRS])
		if(version >= 24){
			archive(v.collision_boxes);
		}
		// Version 25 added what is pointed at ([VL_RAIL_BOXES])
		if(version >= 25){
			archive(v.selection_boxes);
		}
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelInstance &v)
	{
		archive(v.data);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelField &v)
	{
		archive(v.plane, v.shift, v.width);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelRuleClause &v)
	{
		archive(v.field, v.lo, v.hi);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelRule &v)
	{
		archive(v.clauses, v.result);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelSelector &v)
	{
		archive(v.kind, v.rules, v.fallback);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelPlane &v)
	{
		archive(v.name, v.bits);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelFormat &v)
	{
		uint8_t version = 3;
		archive(
				version,
				v.planes,
				v.id,
				v.light_sky,
				v.light_lamp,
				v.param,
				v.color
		);
		// Version 1 had no modifier roles and one plane of a fixed width.
		// Version 2 is not read: nothing on either side of a wire or a save
		// carried it for long enough to matter, and the plane list is not a
		// field that can be defaulted. The version is written from this
		// function and read back into it, so this branch is "2 or newer" on
		// the way in and always taken on the way out.
		if(version >= 3){
			archive(
					v.tint,
					v.wetness,
					v.grain,
					v.gloss,
					v.speckle,
					v.emission,
					v.sag_top,
					v.sag_bottom
			);
		}
	}
}
// vim: set noet ts=4 sw=4:
