// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include "interface/voxel_selector.h"
#include "interface/atlas_cereal.h"
#include "interface/record.h"
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>

// The voxel records, each an interface::Record (src/interface/record.h): a
// field is added at the end under a new minor, `if(r.minor >= N)` on the
// way in. What 0.6 wrote, in a saved world, is read by
// voxel_cereal_legacy.h.
namespace interface
{
	template<class Archive>
			void serialize(Archive &archive, VoxelName &v)
	{
		Record<Archive> r(archive, "VoxelName", 1, 0);
		r.ar(
				v.block_name,
				v.segment_x,
				v.segment_y,
				v.segment_z,
				v.rotation_primary,
				v.rotation_secondary
		);
		r.end();
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelQuad &v)
	{
		Record<Archive> r(archive, "VoxelQuad", 1, 0);
		for(size_t i = 0; i < 4; i++){
			r.ar(v.p[i][0], v.p[i][1], v.p[i][2]);
			r.ar(v.uv[i][0], v.uv[i][1]);
		}
		r.ar(v.tile, v.connect_dir);
		r.end();
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelVariant &v)
	{
		Record<Archive> r(archive, "VoxelVariant", 1, 0);
		r.ar(v.shape, v.color, v.liquid_top, v.textures);
		for(size_t i = 0; i < 6; i++)
			r.ar(v.tile_order[i], v.tile_turns[i]);
		r.ar(v.collision_boxes, v.selection_boxes);
		r.end();
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelDefinition &v)
	{
		Record<Archive> r(archive, "VoxelDefinition", 1, 0);
		r.ar(
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
			r.ar(v.shape_masked_begin[i]);
		r.ar(v.variants);
		if(!v.variants.empty()){
			for(size_t i = 0; i < 256; i++)
				r.ar(v.variant_of_param[i]);
		}
		r.ar(
				v.tint_ramp[0],
				v.tint_ramp[1],
				v.sag_extent,
				v.extra_textures,
				v.shape_lit_from_above,
				v.transmits_light,
				v.alpha_masked,
				v.climbable,
				v.move_resistance,
				v.light_source,
				v.bouncy,
				v.slippery,
				v.disable_jump,
				v.disable_descend,
				v.swimmable,
				v.pointable,
				v.liquid_is_source,
				v.uv_scale,
				v.uv_scale_v,
				v.collision_boxes,
				v.selection_boxes
		);
		r.end();
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelInstance &v)
	{
		archive(v.data);
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelField &v)
	{
		Record<Archive> r(archive, "VoxelField", 1, 0);
		r.ar(v.plane, v.shift, v.width);
		r.end();
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelRuleClause &v)
	{
		Record<Archive> r(archive, "VoxelRuleClause", 1, 0);
		r.ar(v.field, v.lo, v.hi);
		r.end();
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelRule &v)
	{
		Record<Archive> r(archive, "VoxelRule", 1, 0);
		r.ar(v.clauses, v.result);
		r.end();
	}

	// kind: VoxelSelector::Kind; one this does not know reads as FIELD, the
	// world's own id field
	template<class Archive>
			void serialize(Archive &archive, VoxelSelector &v)
	{
		Record<Archive> r(archive, "VoxelSelector", 1, 0);
		r.ar(v.kind, v.rules, v.fallback);
		r.end();
	}

	template<class Archive>
			void serialize(Archive &archive, VoxelPlane &v)
	{
		Record<Archive> r(archive, "VoxelPlane", 1, 0);
		r.ar(v.name, v.bits);
		r.end();
	}

	// The roles by name (VoxelFormat::roles()), the bound ones: a role a
	// newer build adds is read past by this one, and stays unbound here
	template<class Archive>
			void save(Archive &archive, const VoxelFormat &v)
	{
		Record<Archive> r(archive, "VoxelFormat", 1, 0);
		r.ar(v.planes);
		uint32_t n = 0;
		for(const VoxelFormat::Role &role : VoxelFormat::roles())
			n += (v.*(role.field)).bound() ? 1 : 0;
		r.ar(n);
		for(const VoxelFormat::Role &role : VoxelFormat::roles()){
			if((v.*(role.field)).bound())
				r.ar(ss_(role.name), v.*(role.field));
		}
		r.end();
	}

	template<class Archive>
			void load(Archive &archive, VoxelFormat &v)
	{
		Record<Archive> r(archive, "VoxelFormat", 1, 0);
		for(const VoxelFormat::Role &role : VoxelFormat::roles())
			v.*(role.field) = VoxelField();
		r.ar(v.planes);
		uint32_t n = 0;
		r.ar(n);
		for(uint32_t i = 0; i < n; i++){
			ss_ name;
			VoxelField field;
			r.ar(name, field);
			for(const VoxelFormat::Role &role : VoxelFormat::roles()){
				if(name == role.name)
					v.*(role.field) = field;
			}
		}
		r.end();
	}
}
// vim: set noet ts=4 sw=4:
