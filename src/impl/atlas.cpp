// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include <sstream>
#include "interface/atlas.h"
#include "core/log.h"
#include "core/json.h"
#include "interface/os.h"
#include <Context.h>
#include <ResourceCache.h>
#include <Texture2D.h>
#include <Graphics.h>
#include <Image.h>
#include <Vector3.h>
#include <cmath>
#include <cstring>
#include <mutex>
#include <atomic>
#define MODULE "atlas"

namespace interface {

bool AtlasSegmentDefinition::operator==(const AtlasSegmentDefinition &other) const
{
	return (
			resource_name == other.resource_name &&
			total_segments == other.total_segments &&
			select_segment == other.select_segment &&
			lod_simulation == other.lod_simulation &&
			roughness == other.roughness &&
			spec_strength == other.spec_strength &&
			bumpiness == other.bumpiness &&
			translucency == other.translucency &&
			spots == other.spots &&
			static_spots == other.static_spots &&
			animation_length == other.animation_length
	);
}

// Segments are added on the main thread while worker threads mesh chunks that
// read them, so every access goes through m_mutex, and the atlases live in
// deques: a pointer handed out by get_texture() stays valid across an
// add_segment(), which is not true of a vector.
struct CAtlasRegistry: public AtlasRegistry
{
	magic::Context *m_context;
	sd_<AtlasDefinition> m_defs;
	sd_<AtlasCache> m_cache;
	std::mutex m_mutex;
	// Held rather than allocated per segment; see upload_box()
	sv_<unsigned char> m_upload_buffer;
	// See set_surface_maps()
	bool m_surface_maps = true;
	// The animated segments and the frame each one shows; see update().
	// Each frame's box, as drawn the first time it showed: the diffuse,
	// normal and surface boxes one after the other.
	struct Animated {
		uint atlas_id;
		uint seg_id;
		int frame;
		sv_<ss_> drawn;
	};
	sv_<Animated> m_animated;

	CAtlasRegistry(magic::Context *context):
		m_context(context)
	{
		m_defs.resize(1); // id=0 is ATLAS_UNDEFINED
	}

	const AtlasSegmentReference add_segment(
			const AtlasSegmentDefinition &segment_def)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return add_segment_unlocked(segment_def);
	}

	const AtlasSegmentReference add_segment_unlocked(
			const AtlasSegmentDefinition &segment_def)
	{
		// Get Texture2D resource
		magic::ResourceCache *magic_cache =
				m_context->GetSubsystem<magic::ResourceCache>();
		magic::Image *seg_img = magic_cache->GetResource<magic::Image>(
				segment_def.resource_name.c_str());
		if(seg_img == nullptr)
			throw Exception("CAtlasRegistry::add_segment(): Couldn't "
					"find image \""+segment_def.resource_name+"\" when adding "
					"segment");
		// Get resolution of texture
		magic::IntVector2 seg_img_size(seg_img->GetWidth(), seg_img->GetHeight());
		// **What is looked for is the segment's size, not the image's**
		// ([CLIENT_FRAME], 2026-09-26). An atlas keeps the resolution of
		// one segment; an animated texture's image is a strip of all its
		// frames, so asking for an atlas whose segments are the size of
		// the whole strip never found one and made a new atlas instead --
		// three images of 2048 by 2048 allocated and uploaded, 60 to 70
		// ms and 48 MB each. `mcl_core:water_source` alone spent 893 ms
		// of the frame that first saw water making about thirteen of
		// them. A texture that is not animated has one segment, so this
		// is the same question it always was for those.
		const magic::IntVector2 wanted_seg_res(
				seg_img_size.x_ / segment_def.total_segments.x_,
				seg_img_size.y_ / segment_def.total_segments.y_);
		AtlasDefinition *atlas_def = nullptr;
		for(AtlasDefinition &def0 : m_defs){
			if(def0.id == ATLAS_UNDEFINED)
				continue;
			if(def0.segment_resolution == wanted_seg_res){
				size_t max = def0.total_segments.x_ * def0.total_segments.y_;
				if(def0.segments.size() >= max){
					log_d(MODULE, "add_segment(): Found atlas for segment size "
							"(%i, %i) %p, but it is full",
							wanted_seg_res.x_, wanted_seg_res.y_, &def0);
					continue; // Full
				}
				atlas_def = &def0;
				break;
			}
		}
		// If not found, create a texture atlas for this texture size
		if(atlas_def){
			log_d(MODULE, "add_segment(): Found atlas for segment size "
					"(%i, %i): %p", wanted_seg_res.x_, wanted_seg_res.y_,
					atlas_def);
		} else {
			// Create a new texture atlas
			m_defs.resize(m_defs.size()+1);
			atlas_def = &m_defs[m_defs.size()-1];
			log_d(MODULE, "add_segment(): Creating atlas for segment size "
					"(%i, %i): %p", seg_img_size.x_, seg_img_size.y_, atlas_def);
			atlas_def->id = m_defs.size()-1;
			if(segment_def.total_segments.x_ == 0 ||
					segment_def.total_segments.y_ == 0)
				throw Exception("segment_def.total_segments is zero");
			// Calculate segment resolution
			magic::IntVector2 seg_res(
					seg_img_size.x_ / segment_def.total_segments.x_,
					seg_img_size.y_ / segment_def.total_segments.y_
			);
			atlas_def->segment_resolution = seg_res;
			// Calculate total segments based on segment resolution
			const int max_res = 2048;
			atlas_def->total_segments = magic::IntVector2(
					max_res / seg_res.x_ / 2,
					max_res / seg_res.y_ / 2
			);
			magic::IntVector2 atlas_resolution(
					atlas_def->total_segments.x_ * seg_res.x_ * 2,
					atlas_def->total_segments.y_ * seg_res.y_ * 2
			);
			// Create images for new atlas. The normal and spec ones have the
			// same layout as the diffuse one and are filled from the same
			// source pixels, so a segment reference addresses all three.
			auto create_atlas_image = [&](){
				magic::Image *img = new magic::Image(m_context);
				img->SetSize(atlas_resolution.x_, atlas_resolution.y_, 4);
				return img;
			};
			// How many mip levels an atlas gets: as many as it takes for one
			// segment to become one texel, and no more. A level past that
			// averages texels of different textures together, which is the
			// bleeding an atlas is always accused of; and levels are what
			// upload_box() has to keep up to date per segment, so there is
			// no reason to have ones nothing can sample correctly.
			unsigned atlas_levels = 1;
			for(int box = seg_res.x_ * 2; box > 1; box /= 2)
				atlas_levels++;
			atlas_def->levels = atlas_levels;
			auto create_atlas_texture = [&](){
				magic::Texture2D *tex = new magic::Texture2D(m_context);
				// TODO: Make this configurable
				tex->SetFilterMode(magic::FILTER_NEAREST);
				tex->SetNumLevels(atlas_levels);
				// TODO: Use TEXTURE_STATIC or TEXTURE_DYNAMIC?
				tex->SetSize(atlas_resolution.x_, atlas_resolution.y_,
						magic::Graphics::GetRGBAFormat(), magic::TEXTURE_STATIC);
				return tex;
			};
			// Add new atlas to cache
			const auto &id = atlas_def->id;
			m_cache.resize(id+1);
			AtlasCache *cache = &m_cache[id];
			cache->image = create_atlas_image();
			cache->texture = create_atlas_texture();
			if(m_surface_maps){
				cache->normal_image = create_atlas_image();
				cache->normal_texture = create_atlas_texture();
				cache->spec_image = create_atlas_image();
				cache->spec_texture = create_atlas_texture();
			}
			cache->segment_resolution = atlas_def->segment_resolution;
			cache->total_segments = atlas_def->total_segments;
			cache->levels = atlas_def->levels;
			// One whole upload per atlas, of nothing, because that is what
			// allocates the mip levels: Urho3D's Create() makes level 0 and
			// no more, and a texture whose max level is set but whose levels
			// have no storage is incomplete -- it samples as black at every
			// level, near ones included. Segments write their own box in
			// every level after this; see upload_box().
			// **What this costs, said out loud** ([CLIENT_FRAME],
			// 2026-09-26): three whole atlases of 2048 by 2048 is 48 MB,
			// and it lands in whichever frame first met a texture of a
			// size no atlas had yet -- `mcl_core:water_source` measured
			// 812 ms inside one `get_cached()`.
			const int64_t alloc_t0 = interface::os::time_us();
			// **The blank levels are the card's to make** ([CLIENT_FRAME],
			// 2026-09-26). SetData(Image*) walks the mip chain on the
			// processor -- `Image::GetNextLevel()` halving 2048 by 2048
			// down to one texel, three times over -- and sends every level
			// through the driver, which measured 55 to 71 ms in whichever
			// frame first met a segment size no atlas had yet. The image
			// is blank, so level nought is one upload of nothing and
			// `glGenerateMipmap` fills the rest from it without the
			// processor touching a pixel.
			auto allocate_levels = [&](magic::Texture2D *tex,
					magic::Image *img){
				tex->SetData(0, 0, 0, atlas_resolution.x_,
						atlas_resolution.y_, img->GetData());
				magic::Graphics *g =
						m_context->GetSubsystem<magic::Graphics>();
				if(g && atlas_levels > 1){
					// OpenGL: the texture has to be bound for it to work
					g->SetTexture(0, tex);
					tex->RegenerateLevels();
					g->SetTexture(0, nullptr);
				}
			};
			allocate_levels(cache->texture, cache->image);
			if(m_surface_maps){
				allocate_levels(cache->normal_texture, cache->normal_image);
				allocate_levels(cache->spec_texture, cache->spec_image);
			}
			log_w(MODULE, "atlas %i for %ix%i segments: %i ms to allocate "
					"its levels", (int)id, atlas_def->segment_resolution.x_,
					atlas_def->segment_resolution.y_,
					(int)((interface::os::time_us() - alloc_t0) / 1000));
		}
		// Add this segment to the atlas definition
		uint seg_id = atlas_def->segments.size();
		atlas_def->segments.resize(seg_id + 1);
		atlas_def->segments[seg_id] = segment_def;
		// Update this segment in cache
		AtlasCache &atlas_cache = m_cache[atlas_def->id];
		atlas_cache.segments.resize(seg_id + 1);
		AtlasSegmentCache &seg_cache = atlas_cache.segments[seg_id];
		update_segment_cache(seg_id, seg_img, seg_cache, segment_def, atlas_cache);
		// simplified: a LOD's segment stays on its first frame; it is drawn
		// far off, and each animated segment is a redraw per frame change
		if(segment_def.animation_length > 0.0f &&
				segment_def.total_segments.y_ > 1 &&
				segment_def.lod_simulation == 0)
			m_animated.push_back({atlas_def->id, seg_id, 0, {}});
		// Return reference to new segment
		AtlasSegmentReference ref;
		ref.atlas_id = atlas_def->id;
		ref.segment_id = seg_id;
		return ref;
	}

	const AtlasSegmentReference find_or_add_segment(
			const AtlasSegmentDefinition &segment_def)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		// Find an atlas that contains this segment; return reference if found
		for(auto &atlas_def : m_defs){
			for(uint seg_id = 0; seg_id<atlas_def.segments.size(); seg_id++){
				auto &segment_def0 = atlas_def.segments[seg_id];
				if(segment_def0 == segment_def){
					AtlasSegmentReference ref;
					ref.atlas_id = atlas_def.id;
					ref.segment_id = seg_id;
					return ref;
				}
			}
		}
		// Segment was not found; add a new one
		return add_segment_unlocked(segment_def);
	}

	// Sends one box of an atlas image to its texture, at every mip level.
	//
	// SetData(image) would send the whole atlas, and there are three of them
	// -- diffuse, normal and surface -- so adding one 16x16 texture to a
	// 2048x2048 atlas moved 48 MB. A game with a few hundred textures spent
	// most of a second per chunk doing that. What actually changed is the one
	// segment, and Urho3D's SetData takes a rectangle.
	//
	// The mip levels have to be written too: Urho3D fills them when it is
	// handed a whole image, and a texture whose levels were never written
	// samples as black wherever it is minified. Each level averages the 2^n
	// texels of the level-0 image it stands for, which is what a box filter
	// is; the levels stop where a segment is one texel, so no level ever
	// mixes one texture with the next.
	void upload_box(magic::Texture2D *tex, magic::Image *img,
			const magic::IntVector2 &at, const magic::IntVector2 &size,
			unsigned levels)
	{
		if(size.x_ <= 0 || size.y_ <= 0)
			return;
		const unsigned char *src = img->GetData();
		if(src == nullptr){
			tex->SetData(img);
			return;
		}
		const size_t stride = (size_t)img->GetWidth() * 4;
		for(unsigned level = 0; level < levels; level++){
			const int step = 1 << level;
			const int w = size.x_ / step;
			const int h = size.y_ / step;
			if(w < 1 || h < 1)
				break;
			m_upload_buffer.resize((size_t)w * h * 4);
			for(int y = 0; y < h; y++){
				for(int x = 0; x < w; x++){
					// The texels of level 0 this one stands for
					unsigned sum[4] = {0, 0, 0, 0};
					for(int sy = 0; sy < step; sy++){
						const unsigned char *row = src +
								(size_t)(at.y_ + y * step + sy) * stride +
								(size_t)(at.x_ + x * step) * 4;
						for(int sx = 0; sx < step; sx++){
							for(int c = 0; c < 4; c++)
								sum[c] += row[sx * 4 + c];
						}
					}
					unsigned char *dst = &m_upload_buffer[
							((size_t)y * w + x) * 4];
					const unsigned n = (unsigned)step * step;
					for(int c = 0; c < 4; c++)
						dst[c] = (unsigned char)(sum[c] / n);
				}
			}
			tex->SetData(level, at.x_ / step, at.y_ / step, w, h,
					&m_upload_buffer[0]);
		}
	}

	void update_segment_cache(uint seg_id, magic::Image *seg_img,
			AtlasSegmentCache &cache, const AtlasSegmentDefinition &def,
			const AtlasCache &atlas)
	{

		// Check if atlas has too many segments
		size_t max_segments = atlas.total_segments.x_ * atlas.total_segments.y_;
		if(atlas.segments.size() > max_segments){
			throw Exception("Atlas has too many segments (segments.size()="+
					itos(atlas.segments.size())+", total_segments=("+
					itos(atlas.total_segments.x_)+", "+
					itos(atlas.total_segments.y_)+"))");
		}
		// Set segment texture
		cache.texture = atlas.texture;
		// Calculate segment's position in atlas texture
		magic::IntVector2 total_segs = atlas.total_segments;
		uint seg_iy = seg_id / total_segs.x_;
		uint seg_ix = seg_id - seg_iy * total_segs.x_;
		log_d(MODULE, "update_segment_cache(): seg_id=%i, seg_iy=%i, seg_ix=%i",
				seg_id, seg_iy, seg_ix);
		magic::IntVector2 seg_size = atlas.segment_resolution;
		magic::IntVector2 dst_p00(
				seg_ix * seg_size.x_ * 2,
				seg_iy * seg_size.y_ * 2
		);
		magic::IntVector2 dst_p0 = dst_p00 + seg_size / 2;
		magic::IntVector2 dst_p1 = dst_p0 + seg_size;
		// Set coordinates in cache
		cache.coord0 = magic::Vector2(
				(float)dst_p0.x_ / (float)(total_segs.x_ * seg_size.x_ * 2),
				(float)dst_p0.y_ / (float)(total_segs.y_ * seg_size.y_ * 2)
		);
		cache.coord1 = magic::Vector2(
				(float)dst_p1.x_ / (float)(total_segs.x_ * seg_size.x_ * 2),
				(float)dst_p1.y_ / (float)(total_segs.y_ * seg_size.y_ * 2)
		);
		// Draw segment into atlas image
		magic::IntVector2 seg_img_size(seg_img->GetWidth(), seg_img->GetHeight());
		magic::IntVector2 src_off(
				seg_img_size.x_ / def.total_segments.x_ * def.select_segment.x_,
				seg_img_size.y_ / def.total_segments.y_ * def.select_segment.y_
		);
		// Draw main texture
		if(def.lod_simulation == 0){
			for(int y = 0; y<seg_size.y_ * 2; y++){
				for(int x = 0; x<seg_size.x_ * 2; x++){
					magic::IntVector2 src_p = src_off + magic::IntVector2(
							(x + seg_size.x_ / 2) % seg_size.x_,
							(y + seg_size.y_ / 2) % seg_size.y_
					);
					magic::IntVector2 dst_p = dst_p00 + magic::IntVector2(x, y);
					magic::Color c = seg_img->GetPixel(src_p.x_, src_p.y_);
					atlas.image->SetPixel(dst_p.x_, dst_p.y_, c);
				}
			}
		} else {
			// One LOD voxel stands for lod voxels each way, so the segment has
			// to carry the texture tiled lod times as densely to keep the
			// texel density of LOD 1. The segment is not big enough to hold
			// that at full resolution, so each texel is the average of the
			// lod x lod source texels it stands for -- which is what those
			// voxels look like from the distance this LOD is drawn at anyway.
			// Picking one of them instead leaves a blotchy pattern that has
			// nothing to do with the texture and shimmers as the camera moves.
			//
			// The shading is left to the scene's lighting; the LOD geometry
			// keeps its real normals, so nothing is baked in here.
			int lod = def.lod_simulation;
			float inv = 1.0f / (lod * lod);
			for(int y = 0; y<seg_size.y_ * 2; y++){
				for(int x = 0; x<seg_size.x_ * 2; x++){
					int sx0 = (x + seg_size.x_ / 2) * lod;
					int sy0 = (y + seg_size.y_ / 2) * lod;
					magic::Color c(0.0f, 0.0f, 0.0f, 0.0f);
					for(int sy = 0; sy < lod; sy++){
						for(int sx = 0; sx < lod; sx++){
							magic::Color sc = seg_img->GetPixel(
									src_off.x_ + (sx0 + sx) % seg_size.x_,
									src_off.y_ + (sy0 + sy) % seg_size.y_);
							c.r_ += sc.r_ * inv;
							c.g_ += sc.g_ * inv;
							c.b_ += sc.b_ * inv;
							c.a_ += sc.a_ * inv;
						}
					}
					magic::IntVector2 dst_p = dst_p00 + magic::IntVector2(x, y);
					atlas.image->SetPixel(dst_p.x_, dst_p.y_, c);
				}
			}
		}
		// Derive the normal and roughness/metalness maps from the same source
		// pixels. The segment's image is read as a height field for the
		// normals and as a per-texel deviation from the segment's mean
		// roughness, which is enough to tell water from rock and to give
		// leaves the mix of waxy and matte parts they have -- unless a
		// texture pack authored them: <texture>_n.png and <texture>_s.png
		// beside the diffuse, in the LabPBR layout, override the derivation
		// texel by texel. See [VOXEL_MATERIALS] in doc/plan/rendering_plan.md.
		if(atlas.normal_image)
			draw_surface_maps(seg_img, def, atlas, src_off, dst_p00, seg_size,
					sidecar(def.resource_name, "_n"),
					sidecar(def.resource_name, "_s"));

		// Update the atlas textures from the atlas images, over the box this
		// segment wrote and no more; see upload_box()
		const magic::IntVector2 box = seg_size * 2;
		upload_box(atlas.texture, atlas.image, dst_p00, box, atlas.levels);
		if(atlas.normal_image){
			upload_box(atlas.normal_texture, atlas.normal_image, dst_p00, box,
					atlas.levels);
			upload_box(atlas.spec_texture, atlas.spec_image, dst_p00, box,
					atlas.levels);
		}

		// Debug: save atlas image to file
		/*ss_ atlas_img_name = "/tmp/atlas_"+itos(seg_size.x_)+"x"+
				itos(seg_size.y_)+".png";
		magic::File f(m_context, atlas_img_name.c_str(), magic::FILE_WRITE);
		atlas.image->Save(f);*/
	}

	// Luminance of a pixel of a segment, wrapped inside the segment so that a
	// tiling texture's derived maps tile too
	static float segment_luminance(magic::Image *seg_img,
			const magic::IntVector2 &src_off, const magic::IntVector2 &seg_size,
			int lx, int ly)
	{
		lx = ((lx % seg_size.x_) + seg_size.x_) % seg_size.x_;
		ly = ((ly % seg_size.y_) + seg_size.y_) % seg_size.y_;
		magic::Color c = seg_img->GetPixel(src_off.x_ + lx, src_off.y_ + ly);
		return 0.299f * c.r_ + 0.587f * c.g_ + 0.114f * c.b_;
	}

	// The authored map beside a texture, or nullptr: "foo.png" with "_n"
	// is "foo_n.png". Asked of the cache without an error line, since most
	// textures have none, and only for a texture with an extension -- a
	// composed texmod names no file a pack could put a sidecar beside.
	magic::Image* sidecar(const ss_ &resource_name, const char *suffix)
	{
		size_t dot = resource_name.rfind('.');
		if(dot == ss_::npos || resource_name.find('/', dot) != ss_::npos)
			return nullptr;
		ss_ name = resource_name.substr(0, dot) + suffix +
				resource_name.substr(dot);
		magic::ResourceCache *magic_cache =
				m_context->GetSubsystem<magic::ResourceCache>();
		if(!magic_cache->Exists(name.c_str()))
			return nullptr;
		magic::Image *img = magic_cache->GetResource<magic::Image>(name.c_str());
		if(img && (img->GetWidth() < 1 || img->GetHeight() < 1))
			return nullptr;
		return img;
	}

	// LabPBR's specular texel into the numbers the spec map carries:
	// r is perceptual smoothness, so roughness is (1 - r)^2; g is F0 up to
	// 229 and a metal from 230, folded into spec_strength as a fraction of
	// a dielectric's 0.04 until the base goes physical ([PBR_TARGET]);
	// b is porosity below 65 and subsurface from 65, which is the
	// translucency. The alpha is emission and is not carried.
	static void labpbr_specular(const magic::Color &s, float &roughness,
			float &spec_strength, float &translucency)
	{
		roughness = (1.0f - s.r_) * (1.0f - s.r_);
		if(roughness < 0.03f)
			roughness = 0.03f;
		const float g255 = s.g_ * 255.0f;
		if(g255 >= 229.5f)
			spec_strength = 1.0f;
		else
			spec_strength = std::min(1.0f, (g255 / 255.0f) / 0.04f);
		const float b255 = s.b_ * 255.0f;
		translucency = b255 >= 65.0f ? (b255 - 65.0f) / 190.0f : 0.0f;
	}

	static void check_labpbr()
	{
		float r, sp, t;
		// Smoothness 1 is a mirror at the floor, no F0 no highlight, no
		// subsurface no translucency
		labpbr_specular(magic::Color(1.0f, 0.0f, 0.0f, 0.0f), r, sp, t);
		assert(r < 0.031f && sp == 0.0f && t == 0.0f);
		// Smoothness 0 is chalk; a dielectric's 0.04 (10/255) is the full
		// strength; subsurface 255 is fully translucent
		labpbr_specular(magic::Color(0.0f, 10.0f / 255.0f, 1.0f, 0.0f),
				r, sp, t);
		assert(r == 1.0f && sp > 0.98f && sp <= 1.0f && t == 1.0f);
		// A metal is at full strength
		labpbr_specular(magic::Color(0.5f, 240.0f / 255.0f, 0.0f, 0.0f),
				r, sp, t);
		assert(sp == 1.0f && t == 0.0f);
	}

	void draw_surface_maps(magic::Image *seg_img,
			const AtlasSegmentDefinition &def, const AtlasCache &atlas,
			const magic::IntVector2 &src_off, const magic::IntVector2 &dst_p00,
			const magic::IntVector2 &seg_size, magic::Image *normal_img,
			magic::Image *spec_img)
	{
		static bool checked = false;
		if(!checked){
			checked = true;
			check_labpbr();
		}
		// A sidecar has to be laid out like the diffuse to be read at the
		// same offsets; one that is not is ignored with a line
		if(normal_img && (normal_img->GetWidth() != seg_img->GetWidth() ||
				normal_img->GetHeight() != seg_img->GetHeight())){
			log_w(MODULE, "%s: the normal sidecar is %ix%i against %ix%i; "
					"deriving instead", cs(def.resource_name),
					normal_img->GetWidth(), normal_img->GetHeight(),
					seg_img->GetWidth(), seg_img->GetHeight());
			normal_img = nullptr;
		}
		if(spec_img && (spec_img->GetWidth() != seg_img->GetWidth() ||
				spec_img->GetHeight() != seg_img->GetHeight())){
			log_w(MODULE, "%s: the specular sidecar is %ix%i against %ix%i; "
					"deriving instead", cs(def.resource_name),
					spec_img->GetWidth(), spec_img->GetHeight(),
					seg_img->GetWidth(), seg_img->GetHeight());
			spec_img = nullptr;
		}
		// LOD segments sample the source at a stride; the same stride has to
		// be used here or the maps would not line up with the diffuse texture
		int step = def.lod_simulation;
		if(step == 0)
			step = 1;
		// The mean is what def.roughness names, so a texel is only made
		// smoother or rougher by how far it is from its own segment's average
		float mean_lum = 0.0f;
		for(int ly = 0; ly<seg_size.y_; ly++)
			for(int lx = 0; lx<seg_size.x_; lx++)
				mean_lum += segment_luminance(seg_img, src_off, seg_size, lx, ly);
		mean_lum /= (float)(seg_size.x_ * seg_size.y_);
		// Enough that a texture with any contrast at all spans a visible range
		// of roughness, and little enough that a flat one stays flat. How
		// matte a surface is overall is spec_strength's job.
		const float ROUGHNESS_PER_LUM = -0.8f;
		// Which parts are catching the light is worked out in the shader from
		// the world position and the time; only the fraction is stored
		float spots = def.spots < 0.0f ? 0.0f :
				(def.spots > 1.0f ? 1.0f : def.spots);
		// Worked out from the world position too, so only how many there are
		// is stored; the normal map's alpha is the channel free to carry it
		float static_spots = def.static_spots < 0.0f ? 0.0f :
				(def.static_spots > 1.0f ? 1.0f : def.static_spots);
		for(int y = 0; y<seg_size.y_ * 2; y++){
			for(int x = 0; x<seg_size.x_ * 2; x++){
				int lx = ((x + seg_size.x_ / 2) * step) % seg_size.x_;
				int ly = ((y + seg_size.y_ / 2) * step) % seg_size.y_;
				magic::IntVector2 dst_p = dst_p00 + magic::IntVector2(x, y);
				// Central differences of the luminance height field. The
				// tangent frame in the shader is built from the derivatives of
				// the texture coordinate, so x is +u and y is +v here.
				float lum = segment_luminance(
						seg_img, src_off, seg_size, lx, ly);
				float dhdx = segment_luminance(
						seg_img, src_off, seg_size, lx + step, ly) -
						segment_luminance(
						seg_img, src_off, seg_size, lx - step, ly);
				float dhdy = segment_luminance(
						seg_img, src_off, seg_size, lx, ly + step) -
						segment_luminance(
						seg_img, src_off, seg_size, lx, ly - step);
				magic::Vector3 n(-dhdx * def.bumpiness, -dhdy * def.bumpiness,
						1.0f);
				if(normal_img){
					// LabPBR: the normal's x and y in r and g, z rebuilt;
					// b is ambient occlusion and a is height, both read and
					// unused until something wants them
					magic::Color a = normal_img->GetPixel(
							src_off.x_ + lx, src_off.y_ + ly);
					n.x_ = a.r_ * 2.0f - 1.0f;
					n.y_ = a.g_ * 2.0f - 1.0f;
					n.z_ = std::sqrt(std::max(0.0f,
							1.0f - n.x_ * n.x_ - n.y_ * n.y_));
				}
				n.Normalize();
				atlas.normal_image->SetPixel(dst_p.x_, dst_p.y_, magic::Color(
						n.x_ * 0.5f + 0.5f,
						n.y_ * 0.5f + 0.5f,
						n.z_ * 0.5f + 0.5f, static_spots));
				float roughness = def.roughness + (lum - mean_lum) *
						ROUGHNESS_PER_LUM;
				float spec_strength = def.spec_strength;
				float translucency = def.translucency;
				if(spec_img){
					labpbr_specular(spec_img->GetPixel(
							src_off.x_ + lx, src_off.y_ + ly),
							roughness, spec_strength, translucency);
				}
				if(roughness < 0.03f)
					roughness = 0.03f;
				if(roughness > 1.0f)
					roughness = 1.0f;
				atlas.spec_image->SetPixel(dst_p.x_, dst_p.y_,
						magic::Color(roughness, spec_strength,
						translucency, spots));
			}
		}
	}

	const AtlasCache* get_atlas_cache(uint atlas_id)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		return get_atlas_cache_unlocked(atlas_id);
	}

	const AtlasCache* get_atlas_cache_unlocked(uint atlas_id)
	{
		if(atlas_id == ATLAS_UNDEFINED)
			return nullptr;
		if(atlas_id >= m_cache.size()){
			// Cache is always up-to-date
			return nullptr;
		}
		return &m_cache[atlas_id];
	}

	// **A thread asks the lock once a segment** ([WEB_MESH_OFF_THREAD]):
	// this is asked for each face a mesher makes, from every worker at
	// once, and in WebKit a lock four threads share is slow (a lock and
	// unlock 40 times as long as one thread's). A segment is never
	// removed nor moved (the deques), and its coordinates are set before
	// it is handed out, so a pointer found once stays good: each thread
	// keeps the last ones it found, by the registry's serial (not its
	// address, which a new one can have again).
	const uint64_t m_serial = []{
		static std::atomic<uint64_t> next(1);
		return next++;
	}();
	const AtlasSegmentCache* get_texture(const AtlasSegmentReference &ref)
	{
		struct Memo {
			uint64_t serial = 0;
			uint atlas_id = 0, segment_id = 0;
			const AtlasSegmentCache *p = nullptr;
		};
		static thread_local Memo memo[64];
		Memo &m = memo[(ref.atlas_id * 31 + ref.segment_id) & 63];
		if(m.serial == m_serial && m.atlas_id == ref.atlas_id &&
				m.segment_id == ref.segment_id)
			return m.p;
		std::lock_guard<std::mutex> lock(m_mutex);
		const AtlasCache *cache = get_atlas_cache_unlocked(ref.atlas_id);
		if(cache == nullptr)
			return nullptr;
		if(ref.segment_id >= cache->segments.size()){
			// Cache is always up-to-date
			return nullptr;
		}
		const AtlasSegmentCache &seg_cache = cache->segments[ref.segment_id];
		m.serial = m_serial;
		m.atlas_id = ref.atlas_id;
		m.segment_id = ref.segment_id;
		m.p = &seg_cache;
		return &seg_cache;
	}

	ss_ describe_segments()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		std::ostringstream os;
		os<<"[";
		bool first = true;
		for(size_t a = 1; a < m_defs.size(); a++){
			const AtlasDefinition &def = m_defs[a];
			const magic::IntVector2 seg_size = def.segment_resolution;
			// The atlas's texture, by address: a mesh dump names the
			// textures it reads back by that same address (dump_meshes'
			// "textures"), which is how a reader joins a segment to its
			// meshdump_texN.png ([LAMP_REF])
			const AtlasCache *cache = a < m_cache.size() ? &m_cache[a] : nullptr;
			const uintptr_t tex = (cache && cache->texture) ?
					(uintptr_t)cache->texture.Get() : 0;
			for(size_t i = 0; i < def.segments.size(); i++){
				const AtlasSegmentDefinition &sd = def.segments[i];
				// The same placement upload_box() uses: a segment's cell is
				// twice its size and the image sits in the middle of it
				const int ix = i % def.total_segments.x_;
				const int iy = i / def.total_segments.x_;
				const int x0 = ix * seg_size.x_ * 2 + seg_size.x_ / 2;
				const int y0 = iy * seg_size.y_ * 2 + seg_size.y_ / 2;
				os<<(first ? "\n" : ",\n")<<"{\"atlas\":"<<a<<",\"texture\":"
						<<tex<<",\"segment\":"<<i<<",\"x\":"<<x0<<",\"y\":"<<y0<<",\"w\":"<<seg_size.x_
						<<",\"h\":"<<seg_size.y_<<",\"resource\":"
						<<json::Value(sd.resource_name).stringify()<<",\"select\":["
						<<sd.select_segment.x_<<","<<sd.select_segment.y_
						<<"],\"of\":["<<sd.total_segments.x_<<","
						<<sd.total_segments.y_<<"]}";
				first = false;
			}
		}
		os<<"\n]\n";
		return os.str();
	}

	void set_surface_maps(bool enabled)
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		m_surface_maps = enabled;
	}

	void update()
	{
		std::lock_guard<std::mutex> lock(m_mutex);
		// The animated tiles ([NODE_ANIM]): the frame of the moment drawn
		// into each one's place when it changes, as Luanti's own clock
		// picks it -- one loop every animation_length seconds, every tile
		// in step. What it costs (VoxeLibre's lava and water, 15
		// segments, 2026-10-15): a frame's first showing 0.7 ms a segment,
		// after that 0.23 ms, the three boxes' uploads at every level;
		// 1.6% of the main thread over a minute
		if(!m_animated.empty()){
			const double t = interface::os::time_us() / 1e6;
			magic::ResourceCache *magic_cache =
					m_context->GetSubsystem<magic::ResourceCache>();
			for(Animated &a : m_animated){
				const AtlasSegmentDefinition &def =
						m_defs[a.atlas_id].segments[a.seg_id];
				const int frames = def.total_segments.y_;
				const double len = def.animation_length;
				const int frame = (int)(std::fmod(t, len) / len * frames) %
						frames;
				if(frame == a.frame)
					continue;
				a.frame = frame;
				AtlasCache &cache = m_cache[a.atlas_id];
				// The segment's box in the atlas, as update_segment_cache()
				// places it
				const magic::IntVector2 seg = cache.segment_resolution;
				const uint iy = a.seg_id / cache.total_segments.x_;
				const uint ix = a.seg_id - iy * cache.total_segments.x_;
				const magic::IntVector2 at(ix * seg.x_ * 2, iy * seg.y_ * 2);
				const magic::IntVector2 box = seg * 2;
				magic::Image *imgs[3] = {cache.image, cache.normal_image,
						cache.spec_image};
				magic::Texture2D *texs[3] = {cache.texture,
						cache.normal_texture, cache.spec_texture};
				const size_t row = (size_t)box.x_ * 4;
				a.drawn.resize(frames);
				ss_ &drawn = a.drawn[frame];
				if(drawn.empty()){
					// The first time: drawn as any segment is, which is
					// slow (the surface maps, the sidecars looked for), and
					// kept
					magic::Image *img = magic_cache->GetResource<magic::Image>(
							def.resource_name.c_str());
					if(img == nullptr)
						continue;
					AtlasSegmentDefinition shown = def;
					shown.select_segment.y_ =
							(def.select_segment.y_ + frame) % frames;
					update_segment_cache(a.seg_id, img,
							cache.segments[a.seg_id], shown, cache);
					for(magic::Image *im : imgs){
						if(im == nullptr)
							continue;
						const size_t stride = (size_t)im->GetWidth() * 4;
						for(int y = 0; y < box.y_; y++)
							drawn.append((const char*)im->GetData() +
									(at.y_ + y) * stride + at.x_ * 4, row);
					}
					continue;
				}
				// Again: the kept box back in the images and up
				size_t off = 0;
				for(int i = 0; i < 3; i++){
					if(imgs[i] == nullptr)
						continue;
					const size_t stride = (size_t)imgs[i]->GetWidth() * 4;
					for(int y = 0; y < box.y_; y++, off += row)
						memcpy(imgs[i]->GetData() + (at.y_ + y) * stride +
								at.x_ * 4, drawn.data() + off, row);
					upload_box(texs[i], imgs[i], at, box, cache.levels);
				}
			}
		}
		// Re-create textures if a device reset has destroyed them
		for(uint atlas_id = ATLAS_UNDEFINED + 1;
		atlas_id < m_cache.size(); atlas_id++){
			AtlasCache &cache = m_cache[atlas_id];
			if(cache.texture->IsDataLost()){
				log_v(MODULE, "Atlas %i texture data lost - re-creating",
						atlas_id);
				cache.texture->SetData(cache.image);
				cache.texture->ClearDataLost();
				if(cache.normal_texture){
					cache.normal_texture->SetData(cache.normal_image);
					cache.normal_texture->ClearDataLost();
				}
				if(cache.spec_texture){
					cache.spec_texture->SetData(cache.spec_image);
					cache.spec_texture->ClearDataLost();
				}
			}
		}
	}
};

AtlasRegistry* createAtlasRegistry(magic::Context *context)
{
	return new CAtlasRegistry(context);
}

}
// vim: set noet ts=4 sw=4:
