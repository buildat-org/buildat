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
		Record<Archive> r(archive, "AtlasSegmentDefinition", 1, 0);
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
		r.end();
	}
}
// vim: set noet ts=4 sw=4:
