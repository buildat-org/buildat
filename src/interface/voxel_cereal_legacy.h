// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/voxel.h"
#include "interface/voxel_selector.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>

// **What 0.6 wrote** ([COMPAT_BREAK_07] 8b), read only: a saved world's
// registry (format 2), name table and format table (version 1). The voxel
// records had no length then and were read by version branches; 0.7 reads
// them here once and writes the save again in records
// (voxel_cereal.h).
// simplified: kept until the next compatibility break, which can drop it
// once a save stamped by 0.7 is the oldest there is (8h)
namespace interface
{
namespace legacy06
{
	typedef cereal::PortableBinaryInputArchive In;

	template<class T, class F>
	void read_vector(In &ar, sv_<T> &v, F read_one)
	{
		cereal::size_type n = 0;
		ar(cereal::make_size_tag(n));
		v.resize(n);
		for(T &e : v)
			read_one(ar, e);
	}

	static inline void read(In &ar, AtlasSegmentDefinition &v)
	{
		uint8_t version = 0;
		ar(
				version,
				v.resource_name,
				v.total_segments,
				v.select_segment,
				v.lod_simulation,
				v.roughness,
				v.spec_strength,
				v.bumpiness,
				v.translucency,
				v.spots,
				v.static_spots
		);
	}

	static inline void read(In &ar, VoxelName &v)
	{
		uint8_t version = 0;
		ar(
				version,
				v.block_name,
				v.segment_x,
				v.segment_y,
				v.segment_z,
				v.rotation_primary,
				v.rotation_secondary
		);
	}

	static inline void read(In &ar, VoxelQuad &v)
	{
		for(size_t i = 0; i < 4; i++){
			ar(v.p[i][0], v.p[i][1], v.p[i][2]);
			ar(v.uv[i][0], v.uv[i][1]);
		}
		ar(v.tile, v.connect_dir);
	}

	static inline void read(In &ar, VoxelVariant &v)
	{
		uint8_t version = 0;
		ar(version);
		read_vector(ar, v.shape, [](In &a, VoxelQuad &q){ read(a, q); });
		ar(v.color, v.liquid_top);
		read_vector(ar, v.textures,
				[](In &a, AtlasSegmentDefinition &t){ read(a, t); });
		for(size_t i = 0; i < 6; i++)
			ar(v.tile_order[i], v.tile_turns[i]);
		if(version >= 3)
			ar(v.collision_boxes);
		if(version >= 4)
			ar(v.selection_boxes);
	}

	static inline void read(In &ar, VoxelDefinition &v)
	{
		uint8_t version = 0;
		ar(version);
		read(ar, v.name);
		ar(v.id);
		for(size_t i = 0; i < 6; i++)
			read(ar, v.textures[i]);
		ar(
				v.handler_module,
				v.face_draw_type,
				v.edge_material_id,
				v.physically_solid,
				v.fully_empty
		);
		read_vector(ar, v.shape, [](In &a, VoxelQuad &q){ read(a, q); });
		ar(
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
			ar(v.shape_masked_begin[i]);
		read_vector(ar, v.variants,
				[](In &a, VoxelVariant &x){ read(a, x); });
		if(!v.variants.empty()){
			for(size_t i = 0; i < 256; i++)
				ar(v.variant_of_param[i]);
		}
		if(version >= 10)
			ar(v.tint_ramp[0], v.tint_ramp[1], v.sag_extent);
		if(version >= 11){
			read_vector(ar, v.extra_textures,
					[](In &a, AtlasSegmentDefinition &t){ read(a, t); });
		}
		if(version >= 12)
			ar(v.shape_lit_from_above);
		if(version >= 13)
			ar(v.transmits_light);
		if(version >= 14)
			ar(v.alpha_masked);
		if(version >= 15)
			ar(v.climbable);
		if(version >= 16)
			ar(v.move_resistance);
		if(version >= 17)
			ar(v.light_source);
		if(version >= 18)
			ar(v.bouncy, v.slippery, v.disable_jump, v.disable_descend);
		if(version >= 19)
			ar(v.swimmable);
		if(version >= 20)
			ar(v.pointable);
		if(version >= 21)
			ar(v.liquid_is_source);
		if(version >= 22)
			ar(v.uv_scale);
		if(version >= 23)
			ar(v.uv_scale_v);
		if(version >= 24)
			ar(v.collision_boxes);
		if(version >= 25)
			ar(v.selection_boxes);
	}

	static inline void read(In &ar, VoxelField &v)
	{
		ar(v.plane, v.shift, v.width);
	}

	static inline void read(In &ar, VoxelSelector &v)
	{
		ar(v.kind);
		read_vector(ar, v.rules, [](In &a, VoxelRule &rule){
			read_vector(a, rule.clauses, [](In &b, VoxelRuleClause &c){
				read(b, c.field);
				b(c.lo, c.hi);
			});
			a(rule.result);
		});
		ar(v.fallback);
	}

	static inline void read(In &ar, VoxelFormat &v)
	{
		uint8_t version = 0;
		ar(version);
		read_vector(ar, v.planes,
				[](In &a, VoxelPlane &p){ a(p.name, p.bits); });
		read(ar, v.id);
		read(ar, v.light_sky);
		read(ar, v.light_lamp);
		read(ar, v.param);
		read(ar, v.color);
		if(version >= 3){
			read(ar, v.tint);
			read(ar, v.wetness);
			read(ar, v.grain);
			read(ar, v.gloss);
			read(ar, v.speckle);
			read(ar, v.emission);
			read(ar, v.sag_top);
			read(ar, v.sag_bottom);
		}
	}
}
}
// vim: set noet ts=4 sw=4:
