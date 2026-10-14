// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <Vector2.h>
#include <Ptr.h>

namespace Urho3D
{
	class Context;
	class Texture2D;
	class Image;
}

namespace interface
{
	namespace magic = Urho3D;

	static constexpr uint ATLAS_UNDEFINED = 0;

	struct AtlasSegmentReference
	{
		uint atlas_id = ATLAS_UNDEFINED; // 0 = undefined atlas
		uint segment_id = 0;
	};

	// LOD above this does not cast shadows. Every LOD is lit and shaded the
	// same way; only the shadow it casts on the rest of the scene is dropped,
	// which is not visible at the distance those LODs are drawn at.
	const int MAX_LOD_WITH_SHADOWS = 2;

	struct AtlasSegmentDefinition
	{
		ss_ resource_name; // If "", segment won't be added
		magic::IntVector2 total_segments;
		magic::IntVector2 select_segment;
		// LOD level: 0 is the texture as it is, n >= 2 samples it n texels at
		// a time so that one LOD voxel shows what n voxels of it would have.
		uint8_t lod_simulation = 0;
		// TODO: Rotation

		// The atlas derives the normal and surface maps from the segment's
		// image and these six numbers; nothing is authored. See impl/atlas.cpp.
		//   roughness      how wide the highlight is. Brighter texels than the
		//                  segment's mean come out a little smoother.
		//   spec_strength  how much of a highlight there is at all, against
		//                  the 0.08 a dielectric reflects head on. Roughness
		//                  only widens a highlight, so this is the only way to
		//                  make a surface matte. Spots ignore it.
		//   bumpiness      how much of the image's luminance is height. Sets
		//                  how grainy a surface looks, diffuse as much as
		//                  specular.
		//   translucency   how much light passes through from behind at a
		//                  spot, tinted by the surface's own color.
		//   spots          fraction of the surface that at any one moment is
		//                  turned off the face it is on, reflects at full
		//                  strength and passes translucency. Worked out in the
		//                  shader from world position and time, not stored.
		//   static_spots   the same, for spots that hold still: bigger, and on
		//                  or off with no fade.
		//
		// Gloss and transmission share one fraction because they are the same
		// event from two sides; the geometry decides which one shows.
		//
		// TODO: For a game that wants a surface these six numbers cannot
		// describe, add normal_resource_name and surface_resource_name here
		// and have atlas.cpp blit them in place of deriving them. Derivation
		// stays the default; a game that overrides both also decides what the
		// channels mean, and ships the shader that reads them.
		float roughness = 0.9f;
		float spec_strength = 1.0f;
		float bumpiness = 1.0f;
		float translucency = 0.0f;
		float spots = 0.0f;
		float static_spots = 0.0f;
		// An animated tile ([NODE_ANIM]): the seconds a loop through the
		// total_segments.y frames takes, drawn from select_segment.y on;
		// 0 is a still one. The atlas draws the frame of the moment into
		// the segment's place; see update() in impl/atlas.cpp.
		float animation_length = 0.0f;

		bool operator==(const AtlasSegmentDefinition &other) const;
	};

	struct AtlasSegmentCache
	{
		magic::Texture2D *texture = nullptr;
		magic::Vector2 coord0;
		magic::Vector2 coord1;
	};

	struct AtlasDefinition
	{
		uint id = ATLAS_UNDEFINED;
		magic::IntVector2 segment_resolution;
		magic::IntVector2 total_segments;
		// Mip levels, which stop where one segment is one texel; see
		// upload_box() in impl/atlas.cpp
		unsigned levels = 1;
		// A deque, so that a pointer into it survives a segment being added
		// while a worker thread is reading one; see impl/atlas.cpp
		sd_<AtlasSegmentDefinition> segments;
	};

	struct AtlasCache
	{
		magic::SharedPtr<magic::Image> image;
		magic::SharedPtr<magic::Texture2D> texture;
		// Derived from the segment images; same layout as the diffuse atlas.
		// normal: tangent space normal in rgb, static_spots in a.
		// spec: roughness in r, where Urho's PBR shaders read it from
		// sSpecMap, and spec_strength, translucency and spots in gba, which
		// only PBRVoxel reads.
		magic::SharedPtr<magic::Image> normal_image;
		magic::SharedPtr<magic::Texture2D> normal_texture;
		magic::SharedPtr<magic::Image> spec_image;
		magic::SharedPtr<magic::Texture2D> spec_texture;
		magic::IntVector2 segment_resolution;
		magic::IntVector2 total_segments;
		unsigned levels = 1;
		// A deque; see AtlasDefinition::segments
		sd_<AtlasSegmentCache> segments;
	};

	struct AtlasRegistry
	{
		virtual ~AtlasRegistry(){}

		// These two may only be called from Urho3D main thread
		virtual const AtlasSegmentReference add_segment(
				const AtlasSegmentDefinition &segment_def) = 0;
		virtual const AtlasSegmentReference find_or_add_segment(
				const AtlasSegmentDefinition &segment_def) = 0;

		virtual const AtlasDefinition* get_atlas_definition(
				uint atlas_id) = 0;
		virtual const AtlasSegmentDefinition* get_segment_definition(
				const AtlasSegmentReference &ref) = 0;

		virtual const AtlasCache* get_atlas_cache(uint atlas_id) = 0;

		virtual const AtlasSegmentCache* get_texture(
				const AtlasSegmentReference &ref) = 0;

		// Whether an atlas carries the normal and surface maps derived from
		// its segments' pixels. A game whose voxel shader samples neither
		// says false and gets a third of the work per segment and a third of
		// the memory. Say it before the first segment; a later change only
		// applies to atlases created after it.
		virtual void set_surface_maps(bool enabled) = 0;

		// Every segment of every atlas as a JSON array -- atlas id, pixel
		// rect in the atlas image, resource name, select_segment -- for
		// reading a dumped atlas back to the texture that owns a tile.
		// dump_meshes() writes it beside the dump.
		virtual ss_ describe_segments() = 0;

		virtual void update() = 0;
	};

	AtlasRegistry* createAtlasRegistry(magic::Context *context);
}
// vim: set noet ts=4 sw=4:
