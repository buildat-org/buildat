// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/atlas.h"
#include "interface/urho3d_cereal.h"
#include "interface/record.h"
#include <cereal/types/string.hpp>

namespace interface
{
	template<class Archive>
			void serialize(Archive &archive, AtlasSegmentDefinition &v)
	{
		Record<Archive> r(archive, "AtlasSegmentDefinition", 1, 1);
		r.ar(
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
		// 1.1: an animated tile's loop
		if(r.minor >= 1)
			r.ar(v.animation_length);
		r.end();
	}
}
// vim: set noet ts=4 sw=4:
