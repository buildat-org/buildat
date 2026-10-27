// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/voxel_selector.h"
#include "core/log.h"
#include "impl/liquid_corner.h"
#include "interface/os.h"
#include <cstdlib>
#include <PolyVoxCore/SimpleVolume.h>
#include <PolyVoxCore/SurfaceMesh.h>
#include <PolyVoxCore/CubicSurfaceExtractorWithNormals.h>
#include <Scene.h>
#include <Node.h>
#include <StaticModel.h>
#include <Model.h> // Resource parameter of StaticModel
#include <Geometry.h>
#include <IndexBuffer.h>
#include <VertexBuffer.h>
#include <CustomGeometry.h> // A Drawable similarly as StaticModel
#include <Material.h>
#include <Technique.h>
#include <Context.h>
#include <ResourceCache.h>
#include <Texture2D.h> // Allows cast to Texture
#include <CollisionShape.h>
#include <RigidBody.h>
#include <climits>
#include <cmath>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#define MODULE "mesh"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::VoxelInstance;
using interface::VoxelSample;
using interface::VoxelSampleView;
using interface::VoxelRegistry;

// The voxel format's fields, read out of the registry once per chunk instead
// of once per voxel; see VoxelFormat in interface/voxel.h. A format is set
// before the first voxel is added and never after, so nothing here needs the
// registry's lock and a copy of it stays true for as long as a mesh job.
struct VoxelFmt
{
	interface::VoxelField id, light_sky, light_lamp, param, color;
	float sky_div = 1.0f;
	float lamp_div = 1.0f;
	// The surface modifiers in the order a shader sees them, and what each
	// one's own width divides by to come out 0...1. n_surface of them are
	// bound; the rest read as zero.
	interface::VoxelField surface[interface::VOXEL_SURFACE_MODIFIERS];
	float surface_div[interface::VOXEL_SURFACE_MODIFIERS] = {
		1.0f, 1.0f, 1.0f, 1.0f
	};
	size_t n_surface = 0;
	// The tint, which is also surface[0] when it is bound -- it is the
	// first of the surface roles, so it takes the first slot. The engine
	// reads it as well as carrying it, because it is the one modifier that
	// changes the vertex colour instead of only reaching the shader.
	interface::VoxelField tint;
	float tint_div = 1.0f;
	interface::VoxelField sag_top, sag_bottom;
	float sag_top_div = 1.0f, sag_bottom_div = 1.0f;
	// The whole format and the look selector, for the questions that are not
	// one field; read once per chunk with the rest
	interface::VoxelFormat format;
	interface::VoxelSelector look;

	VoxelFmt(){}
	VoxelFmt(VoxelRegistry *voxel_reg)
	{
		const interface::VoxelFormat &f = voxel_reg->get_format();
		format = f;
		look = voxel_reg->get_look_selector();
		id = f.id;
		light_sky = f.light_sky;
		light_lamp = f.light_lamp;
		param = f.param;
		color = f.color;
		sky_div = light_sky.bound() ? (float)light_sky.mask() : 1.0f;
		lamp_div = light_lamp.bound() ? (float)light_lamp.mask() : 1.0f;
		n_surface = f.surface_modifiers(surface);
		for(size_t i = 0; i < n_surface; i++)
			surface_div[i] = (float)surface[i].mask();
		tint = f.tint;
		tint_div = tint.bound() ? (float)tint.mask() : 1.0f;
		sag_top = f.sag_top;
		sag_bottom = f.sag_bottom;
		sag_top_div = sag_top.bound() ? (float)sag_top.mask() : 1.0f;
		sag_bottom_div = sag_bottom.bound() ? (float)sag_bottom.mask() : 1.0f;
	}

	// Anything about a voxel other than its id and its light that the mesher
	// has to look the voxel up again for. Hoisted: a world that binds none
	// of this does not pay for the lookup.
	bool any_modifier() const
	{
		return n_surface != 0 || sag_top.bound() || sag_bottom.bound();
	}
	// The four scalars a shader is handed, 0...1 each
	void surface_of(const VoxelSample &v, float out[
			interface::VOXEL_SURFACE_MODIFIERS]) const
	{
		for(size_t i = 0; i < interface::VOXEL_SURFACE_MODIFIERS; i++){
			out[i] = i < n_surface ?
					(float)surface[i].get(v) / surface_div[i] : 0.0f;
		}
	}
	float tint_f(const VoxelSample &v) const
	{
		return tint.bound() ? (float)tint.get(v) / tint_div : 0.0f;
	}
	float sag_top_f(const VoxelSample &v) const
	{
		return sag_top.bound() ?
				(float)sag_top.get(v) / sag_top_div : 0.0f;
	}
	float sag_bottom_f(const VoxelSample &v) const
	{
		return sag_bottom.bound() ?
				(float)sag_bottom.get(v) / sag_bottom_div : 0.0f;
	}

	interface::VoxelTypeId id_of(const VoxelSample &v) const
	{
		return id.bound() ? (interface::VoxelTypeId)id.get(v) : 1;
	}
	// Which definition this voxel wears, which is the id role for a world
	// that has one and a threshold over fields for a world that does not.
	// What goes into PolyVox's per-face material, so that the geometry pass
	// finds the same definition the face-culling pass did.
	interface::VoxelTypeId look_id(const VoxelSample &v) const
	{
		return look.id_of(v, format);
	}
	// Nothing has generated this voxel yet. A format with no id bound has one
	// voxel type and no way to say that, so nothing is undefined there.
	bool undefined(const VoxelSample &v) const
	{
		return id_of(v) == interface::VOXELTYPEID_UNDEFINED;
	}
	float sky_f(const VoxelSample &v) const
	{
		return light_sky.bound() ?
				(float)light_sky.get(v) / sky_div : 0.0f;
	}
	float lamp_f(const VoxelSample &v) const
	{
		return light_lamp.bound() ?
				(float)light_lamp.get(v) / lamp_div : 0.0f;
	}
};

// Just do this; Urho3D's stuff doesn't really clash with anything in buildat
using namespace Urho3D;

namespace interface {
namespace mesh {

// Set custom geometry from 8-bit voxel data, using a voxel registry
void set_8bit_voxel_geometry(CustomGeometry *cg, Context *context,
		int w, int h, int d, const ss_ &source_data,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		const pv::Vector3DInt32 &uv_origin)
{
	if(w < 0 || h < 0 || d < 0)
		throw Exception("Negative dimension");
	if(w * h * d != (int)source_data.size())
		throw Exception("Mismatched data size");
	VoxelVolume volume(pv::Region(
			pv::Vector3DInt32(-1, -1, -1),
			pv::Vector3DInt32(w, h, d)));
	const VoxelFmt fmt(voxel_reg);
	size_t i = 0;
	for(int z = -1; z <= d; z++){
		for(int y = -1; y <= h; y++){
			for(int x = -1; x <= w; x++){
				VoxelSample v;
				if(!(z == -1 || y == -1 || x == -1 ||
						z == d || y == h || x == w))
					fmt.id.set(v, (uint8_t)source_data[i++]);
				// 8 bit data has no room for a light value, and this is a
				// model standing on its own rather than a piece of a world
				// that could light it, so it is lit as if it were out in the
				// open. Handing a voxel shader no light at all is not the
				// safe choice it looks like: with the ambient term zeroed,
				// what is left is the reflection, and every texel of the
				// derived normal map then reflects the sky in its own
				// direction, which comes out as speckle.
				fmt.light_sky.set(v, fmt.light_sky.mask());
				volume.set_sample_at(x, y, z, v);
			}
		}
	}

	return set_voxel_geometry(cg, context, volume, voxel_reg, atlas_reg, true,
			&uv_origin);
}

template<typename VoxelType>
		class IsQuadNeededByRegistry
{
	interface::VoxelRegistry *m_voxel_reg;
	VoxelFmt m_fmt;
	bool m_liquids_as_cubes = false;
	// NOTE: The voxel type id is used directly as PolyVox material value
public:
	// `liquids_as_cubes`: the LOD mesh's. A liquid is drawn by the near
	// mesher's own pass (its corners' heights) and has no cube faces
	// here, so a far chunk drew no sea at all; there it is a cube.
	// simplified: drawn with the LOD chunk's one opaque material, so a far
	// sea is solid and brighter than the near one's blend; a translucent
	// child node as the near mesher's would match it
	IsQuadNeededByRegistry(interface::VoxelRegistry *voxel_reg,
			bool liquids_as_cubes = false):
		m_voxel_reg(voxel_reg), m_fmt(voxel_reg),
		m_liquids_as_cubes(liquids_as_cubes)
	{}
	// simplified: every liquid shares one edge material, so no face is
	// drawn where water meets lava far away; a liquid's shape_group would
	// tell them apart if that is ever seen
	static constexpr interface::EdgeMaterialId LIQUID_EDGE = 2;
	interface::FaceDrawType draw_type(
			const interface::CachedVoxelDefinition *def) const
	{
		return m_liquids_as_cubes && def->is_liquid ?
				interface::FaceDrawType::ON_EDGE : def->face_draw_type;
	}
	interface::EdgeMaterialId edge(
			const interface::CachedVoxelDefinition *def) const
	{
		return m_liquids_as_cubes && def->is_liquid ?
				LIQUID_EDGE : def->edge_material_id;
	}
	IsQuadNeededByRegistry(): // PolyVox wants this
		m_voxel_reg(nullptr)
	{}
	bool operator()(VoxelType back, VoxelType front, uint32_t &materialToUse)
	{
		if(m_voxel_reg == nullptr)
			throw Exception("IsQuadNeededByRegistry not initialized");
		const interface::CachedVoxelDefinition *back_def =
				m_voxel_reg->get_cached(back);
		const interface::CachedVoxelDefinition *front_def =
				m_voxel_reg->get_cached(front);
		if(!back_def)
			throw Exception(ss_()+"Undefined voxel: back="+
					itos(m_fmt.id_of(back)));
		if(!front_def)
			throw Exception(ss_()+"Undefined voxel: front="+
					itos(m_fmt.id_of(front)));
		/*if(!back_def){
			return false;
		}*/
		else if(draw_type(back_def) == interface::FaceDrawType::NEVER){
			return false;
		}
		else if(draw_type(back_def) == interface::FaceDrawType::ALWAYS){
			materialToUse = m_fmt.look_id(back);
			return true;
		}
		// interface::FaceDrawType::ON_EDGE
		if(!front_def){
			materialToUse = m_fmt.look_id(back);
			return true;
		}
		// [LEAF_SOLID_FACES] A voxel that draws all of its faces -- Luanti's
		// allfaces, a tree's leaves -- is seen through, so the face against
		// it is drawn: with the edge material alone, ground beside leaves
		// was culled and the ground looked through.
		if(draw_type(front_def) == interface::FaceDrawType::ALWAYS){
			materialToUse = m_fmt.look_id(back);
			return true;
		}
		// A translucent voxel does not draw its face against an opaque one:
		// that surface is the opaque voxel's own, drawn by it and seen
		// through the water rather than under another blended layer of it.
		// This is Luanti's rule that the more solid of two nodes owns the
		// face between them.
		if(back_def->translucent && !front_def->translucent &&
				edge(front_def) != interface::EDGEMATERIALID_EMPTY){
			return false;
		}
		if(edge(back_def) != edge(front_def)){
			materialToUse = m_fmt.look_id(back);
			return true;
		}
		return false;
	}
};

// PolyVox extracts the faces of the padding voxels too, and a padding voxel's
// face pointing into the chunk is the same surface that the neighbouring chunk
// draws for its own voxel. Drawing both leaves a doubled, z-fighting layer
// along every chunk boundary, so faces owned by the padding are dropped. The
// face belongs to the voxel half a voxel behind it, against the normal.
static bool face_owned_by_padding(VoxelVolume &volume,
		const pv::Vector3DFloat *quad, const pv::Vector3DFloat &n)
{
	pv::Vector3DFloat centre(0, 0, 0);
	for(size_t i = 0; i < 4; i++)
		centre += quad[i];
	centre /= 4.0f;
	const pv::Region &region = volume.getEnclosingRegion();
	const pv::Vector3DInt32 lc = region.getLowerCorner();
	const pv::Vector3DInt32 uc = region.getUpperCorner();
	pv::Vector3DInt32 back(
			lc.getX() + (int)std::floor(centre.getX() - n.getX()*0.5f + 0.5f),
			lc.getY() + (int)std::floor(centre.getY() - n.getY()*0.5f + 0.5f),
			lc.getZ() + (int)std::floor(centre.getZ() - n.getZ()*0.5f + 0.5f));
	return back.getX() <= lc.getX() || back.getX() >= uc.getX() ||
			back.getY() <= lc.getY() || back.getY() >= uc.getY() ||
			back.getZ() <= lc.getZ() || back.getZ() >= uc.getZ();
}

// Vertex colors for skylit voxel geometry, decoded by a voxel shader as
//   ambient = cAmbientColor.rgb * color.a + color.rgb
// The zone's ambient color is the sky, so a world picks that itself; what is
// carried here is how much of the sky the surface sees, and the light bounced
// off nearby surfaces that reaches it regardless.
//
// The bounce color is a property of the rock and dirt a voxel world is made
// of, so it lives here rather than in a world's settings. It is close to
// neutral, which is what makes a cave read as grey while a face that is merely
// shaded from the sun keeps the sky's blue.
// A game can set its own (set_bounce_color()): extensions/luanti_client
// puts it in its pbr light units, where 0.055 lit a sealed cave eleven
// times vanilla's cave floor ([CAVE_EXPOSURE_FLOOR]). Atomic, since the
// workers read it while a client may set it.
static std::atomic<float> bounce_r{0.055f}, bounce_g{0.050f},
		bounce_b{0.045f};

void set_bounce_color(float r, float g, float b)
{
	bounce_r = r;
	bounce_g = g;
	bounce_b = b;
}

// What a voxel's lamplight looks like at full strength. White, because a lamp
// is as bright as a world says it is and its color belongs in the texture of
// whatever is emitting it; a world that wants warmer torches gives them a
// warmer texture. This is added to the vertex color's rgb, next to the bounce
// term, so a shader following the contract in interface/mesh.h needs to know
// nothing about it.
static const Color LAMP_COLOR(1.0f, 1.0f, 1.0f);

// Per-face brightness, for legibility rather than for physics: two faces of a
// voxel that happen to receive the same light have no visible edge between
// them, which in shadow is most of them. Top is brightest and bottom darkest,
// and the four sides are spread either side of 1.0 so that no two faces
// meeting at an edge carry the same value. Indexed by face_id: +Y -Y +X -X +Z -Z.
static const float FACE_SHADE[6] = {
	1.15f, 0.80f, 1.00f, 0.90f, 0.95f, 0.85f
};

// Ambient occlusion, indexed by the number of the three voxels around a quad
// corner that are solid. Applied to ambient only, which is where it is
// visible: a face in direct sun is shaped by the sun, not by this.
static const float AO_LEVELS[4] = {1.0f, 0.72f, 0.52f, 0.38f};
// The pbr path's own table ([SHADE_NIBBLE]): fitted per factor against
// the path trace's crease, which darkens harder than every game's table
// -- vp1's pit face read 1.4 to 1.6 times the render's with the table
// above ([PBR_FIT] 2c, contrast_dirt_pit). Chosen by the mode the client
// asked for, read here since the mesher runs in the client. simplified:
// only a mode asked for by name selects it -- unset, which the launcher
// takes as pbr, keeps every game's table, since the other games set
// nothing and their look must not move; the upgrade is the launcher
// telling the mesher through set_voxel_geometry().
// The deep entries lowered 2026-09-20 (0.26, 0.16 before; grass_occluded
// 2.2 -> 2.05 of the render, nothing else moved). The one-occluder entry
// is the open shade's as much as the corner's: at 0.30 the cliff top's
// shaded face fell to 0.37 of the render for a corner at 1.2, so the
// cave corner's 1.5 (cave_ao 0.49 against 0.128) is not this table's.
static const float AO_LEVELS_PBR[4] = {1.0f, 0.55f, 0.20f, 0.10f};
// [WATER_LIGHT]: every liquid's surface sits this far under the top of its
// node. Official draws a source flush as it ships, because
// enable_waving_water is off; with it on, its vertex shader moves every
// vertex of a waving liquid by (noise - 1) * water_wave_height * 5 units of
// ten -- the noise in 0..1, so the liquid sits between nought and half a node
// down and a quarter on average. **This is that look, static and less** (user,
// 2026-09-25): an eighth of a node, since a quarter is the room an animation
// needs and there is no animation; the constant grows with one if it is ever
// built.
//
// Taken off the corners by liquid_corner() once it has measured them, not off
// the levels it measures: those are compared against half a node to decide
// which corners a flow reaches, and a sag in them would misread that. Every
// vertex that sits on the surface follows the corner it stands at, so the
// sides come with it and nothing gapes at the bottom.
//
// **Every liquid, not only what official's waving = 3 would move, and no
// setting to turn it off**: the sag is the look (user, 2026-09-25). Source
// and flowing alike, so the flow's own dip still reads against the source.
static const float LIQUID_SAG = 1.0f / 8.0f;

static const bool PBR_MODE = getenv("BUILDAT_RENDER_MODE") != nullptr && (
		ss_(getenv("BUILDAT_RENDER_MODE")) == "pbr" ||
		ss_(getenv("BUILDAT_RENDER_MODE")) == "1" ||
		ss_(getenv("BUILDAT_RENDER_MODE")) == "pbr_debug_shadows");

// How much of that occlusion the bounce term takes. Occlusion is a statement
// about how much of the sky a corner can see, which is the wrong question to
// ask about light that came off the surrounding surfaces in the first place:
// inside a cave there is no sky to occlude, and taking it at full strength
// there darkens every pocket until the corners that stick out into the cave
// are the brightest thing in it.
static const float BOUNCE_AO = 0.70f;

static bool occludes(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		const pv::Vector3DInt32 &p)
{
	VoxelSample v = volume.sample_at(p);
	if(fmt.undefined(v))
		return false; // Unfilled chunk padding; assume open
	const interface::CachedVoxelDefinition *def = voxel_reg->get_cached(v);
	if(def == nullptr)
		return false;
	return def->edge_material_id != interface::EDGEMATERIALID_EMPTY;
}

// The same, for the hemisphere rays: a cutout -- leaves, a plant -- lets
// most of the sky through and does not block like rock. The corner table
// keeps occludes(): a leaf block against a face is a crease either way.
static bool occludes_sky(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		const pv::Vector3DInt32 &p)
{
	VoxelSample v = volume.sample_at(p);
	if(fmt.undefined(v))
		return false;
	const interface::CachedVoxelDefinition *def = voxel_reg->get_cached(v);
	if(def == nullptr)
		return false;
	return def->edge_material_id != interface::EDGEMATERIALID_EMPTY &&
			!def->alpha_masked;
}

// The vertex alpha, in the two layouts a client can ask for. Plain: the sky
// share, nibble times shade, as interface/mesh.h has had it. **Packed**, for
// a client that passes a horizon map: the nibble alone in the high four
// bits and the shade -- corner occlusion, the hemisphere rays, the terrain,
// the face's shade -- in the low four, sixteen levels each, so a shader can
// gate the sun by the nibble (a cave) without the shade taking the sun off
// a lit wall in a trench, which one number cannot help doing. See
// [PBR_FIT] 2c.
// 0.3 until 2026-09-20 21:30; 0.1 read better on every row it touches
// with the vertex terms live: the pit (contrast_dirt_pit 7.0 of 12, was
// 5.9), the corner (cave_ao_corner 0.85-1.23, was 1.25-1.97), the bore's
// walls (a shaft's rays are nought its whole length, so the floor is
// its level: 1.17/3.2/6.6 of the render at the near wall, was 2/5/11)
static const float SHADE_FLOOR = 0.1f;

// The packed layout's alpha without its rgb (set_alpha_nibbles()): what
// keeps the shade where no sky reaches, which sky times shade does not
static std::atomic<bool> alpha_nibbles{false};

void set_alpha_nibbles(bool on)
{
	alpha_nibbles = on;
}

static float sky_alpha(float sky_f, float shade, bool packed)
{
	if(!packed && !alpha_nibbles)
		return sky_f * shade;
	float s = shade / 1.15f; // FACE_SHADE's top, so a lit top is full
	if(s > 1.0f) s = 1.0f;
	if(s < 0.0f) s = 0.0f;
	int hi = (int)std::floor(sky_f * 15.0f + 0.5f);
	int lo = (int)std::floor(s * 15.0f + 0.5f);
	return (float)(hi * 16 + lo) / 255.0f;
}

// The voxel a face belongs to: half a voxel behind the face's centre, against
// the normal. The same arithmetic as face_owned_by_padding(), and what wants
// it is the face's own param, which PolyVox does not carry through.
// Where the voxel a face belongs to is, in the volume's own coordinates
static pv::Vector3DInt32 face_back_pos(VoxelVolume &volume,
		const pv::Vector3DFloat *quad, const pv::Vector3DFloat &n)
{
	pv::Vector3DFloat centre(0, 0, 0);
	for(size_t i = 0; i < 4; i++)
		centre += quad[i];
	centre /= 4.0f;
	const pv::Vector3DInt32 vlc = volume.getEnclosingRegion().getLowerCorner();
	return pv::Vector3DInt32(
			vlc.getX() + (int)std::floor(centre.getX() - n.getX()*0.5f + 0.5f),
			vlc.getY() + (int)std::floor(centre.getY() - n.getY()*0.5f + 0.5f),
			vlc.getZ() + (int)std::floor(centre.getZ() - n.getZ()*0.5f + 0.5f));
}

static VoxelSample face_back_voxel(VoxelVolume &volume,
		const pv::Vector3DFloat *quad, const pv::Vector3DFloat &n)
{
	return volume.sample_at(face_back_pos(volume, quad, n));
}

// How far a face has moved at one corner: the average sag of the up to four
// voxels that meet there and sag at all. x and z are the low corner of that
// two by two, y is the row of voxels the corner is the top or the bottom of,
// and all three are the volume's own coordinates.
//
// A voxel whose definition has no sag_extent is left out of the average
// rather than counted as zero, which is what makes a single sagging voxel
// sag all of its face instead of only its middle. The same rule is what
// liquid_corner_top() applies to columns that are not the same liquid.
//
// A voxel with something over it does not sag at its top however much its
// field says, and counts as zero rather than being left out: what is under a
// floor is not a surface, and a face that sank there would open a gap
// between two voxels of the same stuff. That is Luanti's rule for a liquid
// with the same liquid above it, which is the same situation. The bottom is
// the same the other way up.
static float sag_at_corner(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		int x, int y, int z, bool top)
{
	float sum = 0.0f;
	int n = 0;
	for(int ix = 0; ix < 2; ix++){
		for(int iz = 0; iz < 2; iz++){
			VoxelSample v = volume.sample_at(x + ix, y, z + iz);
			if(fmt.undefined(v))
				continue;
			const interface::CachedVoxelDefinition *def =
					voxel_reg->get_cached(v);
			if(def == nullptr || def->sag_extent == 0.0f)
				continue;
			n++;
			VoxelSample over = volume.sample_at(x + ix,
					y + (top ? 1 : -1), z + iz);
			const interface::CachedVoxelDefinition *over_def =
					fmt.undefined(over) ? nullptr : voxel_reg->get_cached(over);
			if(over_def != nullptr && !over_def->fully_empty)
				continue;
			sum += def->sag_extent *
					(top ? fmt.sag_top_f(v) : fmt.sag_bottom_f(v));
		}
	}
	return n == 0 ? 0.0f : sum / (float)n;
}

// A voxel's own colour multiplied into the light the mesher worked out. The
// packing is Urho3D's Color::ToUInt(), which is red in the low byte; the
// alpha is how much of the sky the surface sees and is left alone.
// A colour on its own, as the vertex format wants it: red in the low byte,
// and no sky at all in the alpha. What that says to a voxel shader is "this
// surface looks like this whatever the sky is doing", which is what a colour
// with no light behind it means -- see the vertex colour's split in
// interface/mesh.h.
static unsigned plain_color(uint32_t rgb)
{
	return ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff);
}

// Two colours multiplied, both plain 0xRRGGBB. What wants this is combining
// the tints a voxel has before any of them is packed for a vertex: packing
// swaps the byte order, so combining packed colours with the function below
// swaps it twice and comes out with red and blue exchanged.
static uint32_t mul_rgb(uint32_t a, uint32_t b)
{
	uint32_t r = ((a >> 16) & 0xff) * ((b >> 16) & 0xff) / 255;
	uint32_t g = ((a >> 8) & 0xff) * ((b >> 8) & 0xff) / 255;
	uint32_t bl = (a & 0xff) * (b & 0xff) / 255;
	return (r << 16) | (g << 8) | bl;
}

// The colour a tint modifier of t picks out of a definition's ramp, plain
// 0xRRGGBB. A definition that left both ends white is not tinted, whatever
// its field says, which is what lets one format serve a world where only
// some of the voxels care.
static uint32_t tint_ramp_color(const interface::CachedVoxelDefinition *def,
		float t)
{
	const uint32_t a = def->tint_ramp[0], b = def->tint_ramp[1];
	if(a == 0xffffff && b == 0xffffff)
		return 0xffffff;
	if(t < 0.0f)
		t = 0.0f;
	else if(t > 1.0f)
		t = 1.0f;
	uint32_t out = 0;
	for(int shift = 16; shift >= 0; shift -= 8){
		float ca = (float)((a >> shift) & 0xff);
		float cb = (float)((b >> shift) & 0xff);
		out |= (uint32_t)(ca + (cb - ca) * t + 0.5f) << shift;
	}
	return out;
}

// The tint colour as one number a vertex can carry, 5-6-5. Not 8-8-8: the
// four corners of a face carry the same value and the rasterizer interpolates
// it anyway, and a 24-bit integer is at the edge of what a 32-bit float
// interpolates back exactly, where a 16-bit one has three decimal digits to
// spare. Sixteen or thirty-two levels per channel is plenty for a ramp
// between two colours.
static float pack_tint565(uint32_t rgb)
{
	uint32_t r = ((rgb >> 16) & 0xff) >> 3;
	uint32_t g = ((rgb >> 8) & 0xff) >> 2;
	uint32_t b = (rgb & 0xff) >> 3;
	return (float)((r << 11) | (g << 5) | b);
}

// A plain 0xRRGGBB tint multiplied into a colour that is already packed for
// a vertex -- the light the mesher worked out. The alpha is how much of the
// sky the surface sees and is left alone.
static unsigned modulate_color(unsigned lit, uint32_t rgb)
{
	if(rgb == 0xffffff)
		return lit;
	unsigned r = (lit & 0xff) * ((rgb >> 16) & 0xff) / 255;
	unsigned g = ((lit >> 8) & 0xff) * ((rgb >> 8) & 0xff) / 255;
	unsigned b = ((lit >> 16) & 0xff) * (rgb & 0xff) / 255;
	return (lit & 0xff000000UL) | (b << 16) | (g << 8) | r;
}

// One color per corner of a quad. PolyVox vertex positions are region-relative
// and sit on voxel corners, so the average of a quad's four corners is the face
// center; half a voxel along the normal lands in the voxel the face looks into,
// and half a voxel against it in the solid voxel behind it.
//
// Chunk volumes are padded by one voxel, which the world fills from the chunks
// next to it. It cannot always: a neighbour that is not in memory leaves its
// side undefined. Those faces fall back to the skylight of the solid voxel,
// which the world stores as a per-voxel approximation for exactly this case.
// How much of the dome a face at world (x, y, z) sees past the terrain
// around it, out of the horizon map: eight directions, the highest
// elevation the terrain reaches in each within HORIZON_PAD columns, and the
// cap above it -- cos^2 of that elevation, which is the share of a uniform
// dome's irradiance on a horizontal face from above that angle. A wall
// takes the five directions of its facing half. 1 with no map.
static float terrain_sky(const HorizonMap *horizon,
		int wx, int wy, int wz, const pv::Vector3DFloat &n)
{
	if(!horizon)
		return 1.0f;
	static const int DX[8] = {1, 1, 0, -1, -1, -1, 0, 1};
	static const int DZ[8] = {0, 1, 1, 1, 0, -1, -1, -1};
	static const float LEN[8] = {1, 1.4142f, 1, 1.4142f, 1, 1.4142f, 1, 1.4142f};
	float sum = 0, weight = 0;
	for(int d = 0; d < 8; d++){
		// A wall sees only the half of the horizon it faces; a floor or
		// a ceiling sees all of it
		float facing = n.getX() * DX[d] + n.getZ() * DZ[d];
		if(std::fabs(n.getY()) < 0.5f && facing < -0.01f)
			continue;
		float tan_max = 0;
		// Doubling steps out to the map's edge: six looks per direction
		// rather than thirty-two, since a far ridge subtends about the
		// same angle a column either way and a near one is looked at
		// closely. Meshing with a look per column took long enough that
		// the far chunks were not in the frame by the time a reference
		// shot was taken.
		// From four columns out: nearer is the hemisphere rays' (reach
		// 4), and a tree crown one column away -- five wide, so the 3x3
		// erosion keeps it -- read as a wall at 83 degrees and left vp5's
		// snow field at a sixtieth of the open sky while the tree tops
		// beyond the forest read full: the field went black at 02:00,
		// the meter keyed on it and the far tops came out white
		// ([LOD_LIGHT]'s finding, at last).
		for(int k = 4; k <= HORIZON_PAD; k *= 2){
			int cx = wx + DX[d] * k - horizon->origin_x;
			int cz = wz + DZ[d] * k - horizon->origin_z;
			if(cx < 0 || cz < 0 || cx >= HORIZON_SIZE || cz >= HORIZON_SIZE)
				break;
			int16_t h = horizon->heights[cz * HORIZON_SIZE + cx];
			if(h == HORIZON_NONE)
				continue;
			float t = (float)(h - wy) / (LEN[d] * k);
			if(t > tan_max)
				tan_max = t;
		}
		// The share of the sky above the elevation, weighted toward the
		// horizon: 1 - sin(e), from its tangent. cos^2(e) is a uniform
		// dome's, and it left a terrace under a mountain flank at 0.9 of
		// an open one where the render reads 0.3 -- the light a low sun
		// leaves in the sky is in the horizon band the flank hides
		// ([PBR_FIT] 2c). simplified: one profile for every hour.
		float cap = 1.0f - tan_max / std::sqrt(1.0f + tan_max * tan_max);
		sum += cap;
		weight += 1;
	}
	return weight > 0 ? sum / weight : 1.0f;
}

// The pbr_debug_shadows render mode -- BUILDAT_RENDER_MODE on this client's
// process, the same variable the mode is asked with ([RENDER_MODES]) -- is
// the shadow-kind diagnostic ([PBR_FIT] 2c). Each occlusion term goes into
// its own channel of the vertex colour instead of into the shade -- the
// terrain cap in red, the corner table in green, the hemisphere rays in
// blue -- and the shader draws that colour as it is, with the albedo and
// the lights out (cShadowKinds). What the picture says is where a term is
// lost between here and the frame. Read here because the mesher runs in
// the client and the sandbox has no getenv.
// simplified: the custom-shape path (plants, stairs) is not coloured.
static const bool SHADOW_KINDS = getenv("BUILDAT_RENDER_MODE") != nullptr &&
		ss_(getenv("BUILDAT_RENDER_MODE")) == "pbr_debug_shadows";

static void face_vertex_colors(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		const pv::Vector3DFloat *quad,
		const pv::Vector3DFloat &n, uint face_id, unsigned out[4],
		const HorizonMap *horizon, int lod = 1)
{
	const Color BOUNCE_COLOR(bounce_r, bounce_g, bounce_b);
	pv::Vector3DFloat centre(0, 0, 0);
	for(size_t i = 0; i < 4; i++)
		centre += quad[i];
	centre /= 4.0f;

	const pv::Vector3DInt32 vlc = volume.getEnclosingRegion().getLowerCorner();
	auto voxel_at = [&](float s){
		return pv::Vector3DInt32(
				vlc.getX() + (int)std::floor(centre.getX() + n.getX()*s + 0.5f),
				vlc.getY() + (int)std::floor(centre.getY() + n.getY()*s + 0.5f),
				vlc.getZ() + (int)std::floor(centre.getZ() + n.getZ()*s + 0.5f));
	};
	const pv::Vector3DInt32 front_p = voxel_at(0.5f);
	VoxelSample front = volume.sample_at(front_p);
	VoxelSample lit = fmt.undefined(front) ?
			volume.sample_at(voxel_at(-0.5f)) : front;
	float sky_f = fmt.sky_f(lit);
	float lamp_f = fmt.lamp_f(lit);

	// The two axes of the face's own plane, to step around it in
	pv::Vector3DInt32 u(0, 1, 0), v(0, 0, 1);
	if(n.getY() != 0){
		u = pv::Vector3DInt32(1, 0, 0);
		v = pv::Vector3DInt32(0, 0, 1);
	} else if(n.getZ() != 0){
		u = pv::Vector3DInt32(1, 0, 0);
		v = pv::Vector3DInt32(0, 1, 0);
	}
	auto along = [&](const pv::Vector3DFloat &d, const pv::Vector3DInt32 &axis){
		float c = d.getX()*axis.getX() + d.getY()*axis.getY() +
				d.getZ()*axis.getZ();
		return c < 0 ? -1 : 1;
	};

	// How much of its hemisphere the face can see past the next few voxels:
	// the normal and the eight directions a step out from it along the face's
	// axes and diagonals, each walked HEMI_REACH voxels from the voxel in
	// front and stopped by the first solid one. A wall between a block and two
	// terraces sees a fifth of the sky, and the corner table below, which
	// looks one voxel along the face, said it saw all of it; the path-traced
	// reference is exact and read that wall at a third of what the corner
	// table lit it to ([PBR_FIT] 2c). Multiplied into the sky share, so the
	// corner table keeps the crease and this keeps the surroundings.
	// simplified: nine rays, four voxels; a cutout block (leaves, plants)
	// does not block, rock and anything else with an edge material does.
	// The packed layout's term only: the plain one is the parity modes',
	// and official Luanti's baked light has no such term -- with it the
	// shaded probes read at a third of official's ([PARITY_LEFTOVERS],
	// 2026-09-21: stone 18 against 61, the cave floor 23 against 46).
	static const int HEMI_REACH = 4;
	const pv::Vector3DInt32 ni((int)std::round(n.getX()),
			(int)std::round(n.getY()), (int)std::round(n.getZ()));
	const pv::Vector3DInt32 dirs[9] = {
		ni, ni + u, ni - u, ni + v, ni - v,
		ni + u + v, ni + u - v, ni - u + v, ni - u - v,
	};
	auto open_fraction = [&](int reach){
		int open = 0;
		for(const pv::Vector3DInt32 &d : dirs){
			bool blocked = false;
			pv::Vector3DInt32 p = front_p;
			for(int k = 0; k < reach && !blocked; k++){
				p += d;
				blocked = occludes_sky(volume, voxel_reg, fmt, p);
			}
			if(!blocked)
				open++;
		}
		return (float)open / 9.0f;
	};
	float hemi = 1.0f;
	if(horizon || SHADOW_KINDS)
		hemi = open_fraction(HEMI_REACH);
	// And the terrain beyond the chunk, out of the horizon map: the voxel
	// in front, in world coordinates. The volume's lower corner is the
	// chunk's origin less its padding, and the map's origin says where
	// the chunk is (its x and z less HORIZON_PAD). A LOD volume is the
	// chunk at one voxel per lod^3, so its offsets are times lod.
	float terrain = 1.0f;
	// Whether the face is under its own column's surface -- the map's
	// height there above the voxel in front -- which is the underground
	// rule ([STAIR_DARK]): the cap looks out from four columns and reads
	// a cave wall facing its mouth as open. Underground the packed g
	// carries nought, so the shader's ground term is the interior's
	// (the flood's nibble, [INTERIOR_FALLOFF]) and not the open's.
	bool under = false;
	if(horizon){
		const pv::Vector3DInt32 lc = volume.getEnclosingRegion().getLowerCorner();
		int wx = horizon->origin_x + HORIZON_PAD + (front_p.getX() - lc.getX() - 1) * lod;
		int wy = horizon->origin_y + (front_p.getY() - lc.getY() - 1) * lod;
		int wz = horizon->origin_z + HORIZON_PAD + (front_p.getZ() - lc.getZ() - 1) * lod;
		terrain = terrain_sky(horizon, wx, wy, wz, n);
		int cx = wx - horizon->origin_x, cz = wz - horizon->origin_z;
		if(cx >= 0 && cz >= 0 && cx < HORIZON_SIZE && cz < HORIZON_SIZE){
			int16_t h = horizon->heights[cz * HORIZON_SIZE + cx];
			under = h != HORIZON_NONE && h > wy;
		}
	}

	for(size_t i = 0; i < 4; i++){
		pv::Vector3DFloat d = quad[i] - centre;
		pv::Vector3DInt32 du = u * along(d, u);
		pv::Vector3DInt32 dv = v * along(d, v);
		bool s1 = occludes(volume, voxel_reg, fmt, front_p + du);
		bool s2 = occludes(volume, voxel_reg, fmt, front_p + dv);
		// Two solid sides bury the corner whatever is diagonally behind it
		int occluders = (s1 && s2) ? 3 : (s1 ? 1 : 0) + (s2 ? 1 : 0) +
				(occludes(volume, voxel_reg, fmt, front_p + du + dv) ? 1 : 0);
		float ao = (PBR_MODE ? AO_LEVELS_PBR : AO_LEVELS)[occluders];
		// The shade -- corners, rays, terrain cap -- multiplies the flood's
		// nibble, and in a one-wide shaft the rays and the cap are nought:
		// a wall the flood says sees 11 of 15 drew black, in both paths
		// ([STAIR_DARK], drive/5 2026-09-20). The nibble already carries an
		// interior's enclosure (one level a node), so the shade is floored
		// under it: a shaft's walls read nibble x 0.3, lit at the lip,
		// dimming with the flood, black at 0; the fitted probes stand
		// (pit_dirt's 0.55 x 0.63 = 0.35 is above the floor). simplified:
		// a constant, so a three-deep pit and a thirty-deep shaft get the
		// same floor and the double count stays; the principled version
		// takes the rays and the cap only at or above the column's surface.
		float enclosure = ao * hemi * terrain;
		if(enclosure < SHADE_FLOOR)
			enclosure = SHADE_FLOOR;
		float sky_shade = enclosure * FACE_SHADE[face_id];
		float bounce_shade = (1.0f - BOUNCE_AO + BOUNCE_AO * ao) *
				FACE_SHADE[face_id] * (1.0f - sky_f);
		// A lamp is shaded by the corner it sits in and the face, not by
		// the terrain cap: the cap is the hill on the sky, and under a
		// cave's roof it is zero, which put out every lamp in a cave
		// ([LAMP_REF]: the glowstone lit nothing).
		float lamp_shade = lamp_f * ao * hemi * FACE_SHADE[face_id];
		// A client with a horizon map lights the enclosed by its own bounce
		// term, in the sky's units of the hour; the constant here is in
		// display units and at night, when the sky is a fifty-thousandth of
		// it, it lit every canopy like a lamp ([NO_SPOTS_REF]'s check).
		if(horizon)
			bounce_shade = 0;
		if(SHADOW_KINDS){
			out[i] = Color(terrain, ao, hemi,
					sky_alpha(sky_f, sky_shade, horizon != nullptr)).ToUInt();
			continue;
		}
		// The packed layout's rgb: the lamp in r (LAMP_COLOR is white, so
		// one channel is the three), the terrain cap in g and the local
		// shade -- corner table, rays, face -- in b, so the shader can put
		// the local shade alone on the bounce and the ground: light from
		// the surroundings is blocked by the corner it sits in, not by the
		// mountain behind the ridge, and a cave wall under a terrain cap
		// of zero still bounces ([PBR_FIT] 2c, the shadow-kind run). The
		// alpha's low nibble keeps the product for the sky's share.
		if(horizon){
			// Floored like the enclosure above: a wall in a cave's fold has
			// all nine rays blocked, and at nought it took the bounce and
			// the ground with it and drew black where the render has the
			// mouth's bounce (vp7's right wall, 2026-09-20; [PBRI] owns the
			// level, the floor owns the black)
			float local_ao = ao * hemi;
			if(local_ao < SHADE_FLOOR)
				local_ao = SHADE_FLOOR;
			float local = local_ao * FACE_SHADE[face_id] / 1.15f;
			// The lamp's level alone, the shader's falloff takes it from
			// there: the rays put out every torch in a room narrower than
			// their reach, and lit only the spots that saw out
			// ([TORCH_LIGHT]). Smoothed as Luanti's corners are, over the
			// open voxels around the vertex -- the diagonal not past two
			// solid sides -- so the light has no step a node.
			float lamp_sum = lamp_f;
			int lamp_n = 1;
			const pv::Vector3DInt32 around[3] = {
				front_p + du, front_p + dv, front_p + du + dv};
			for(int k = 0; k < 3; k++){
				if(k == 2 && s1 && s2)
					break;
				if(k == 0 ? s1 : k == 1 ? s2 :
						occludes(volume, voxel_reg, fmt, around[k]))
					continue;
				VoxelSample a = volume.sample_at(around[k]);
				if(fmt.undefined(a))
					continue;
				lamp_sum += fmt.lamp_f(a);
				lamp_n++;
			}
			out[i] = Color(lamp_sum / lamp_n, under ? 0.0f : terrain,
					local > 1.0f ? 1.0f : local,
					sky_alpha(sky_f, sky_shade, true)).ToUInt();
			continue;
		}
		out[i] = Color(
				BOUNCE_COLOR.r_ * bounce_shade + LAMP_COLOR.r_ * lamp_shade,
				BOUNCE_COLOR.g_ * bounce_shade + LAMP_COLOR.g_ * lamp_shade,
				BOUNCE_COLOR.b_ * bounce_shade + LAMP_COLOR.b_ * lamp_shade,
				sky_alpha(sky_f, sky_shade, horizon != nullptr)).ToUInt();
	}
}

// The texture turned inside its own face, which is what
// VoxelDefinition::tile_turns asks for. In the segment's own 0...1 space a
// quarter turn is (s, t) -> (1 - t, s), which is what Luanti does to a tile
// with a rotation -- it lets the coordinates go negative and leans on the
// texture wrapping, where an atlas segment has to stay inside its own box.
static void turn_txcoord(const AtlasSegmentCache *aseg, uint8_t turns,
		CustomGeometryVertex &tg_vert)
{
	turns &= 3;
	if(turns == 0)
		return;
	const float w = aseg->coord1.x_ - aseg->coord0.x_;
	const float h = aseg->coord1.y_ - aseg->coord0.y_;
	if(w == 0.0f || h == 0.0f)
		return;
	float s = (tg_vert.texCoord_.x_ - aseg->coord0.x_) / w;
	float t = (tg_vert.texCoord_.y_ - aseg->coord0.y_) / h;
	for(uint8_t i = 0; i < turns; i++){
		const float s0 = s;
		s = 1.0f - t;
		t = s0;
	}
	tg_vert.texCoord_.x_ = aseg->coord0.x_ + s * w;
	tg_vert.texCoord_.y_ = aseg->coord0.y_ + t * h;
}

void assign_txcoords(size_t pv_vertex_i1, const AtlasSegmentCache *aseg,
		CustomGeometryVertex &tg_vert)
{
	if(tg_vert.normal_.z_ > 0){
		if(pv_vertex_i1 == 3){
			// Top left (n=Z+)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 1){
			// Top right (n=Z+)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 0){
			// Bottom right (n=Z+)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 2){
			// Bottom left (n=Z+)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		}
	} else if(tg_vert.normal_.x_ > 0){
		if(pv_vertex_i1 == 3){
			// Top right (n=X+)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 1){
			// Bottom right (n=X+)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 0){
			// Bottom left (n=X+)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 2){
			// Top left (n=X+)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		}
	} else if(tg_vert.normal_.x_ < 0){
		if(pv_vertex_i1 == 1){
			// Bottom left (n=X-)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 3){
			// Top left (n=X-)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 2){
			// Top right (n=X-)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 0){
			// Bottom right (n=X-)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		}
	} else {
		if(pv_vertex_i1 == 1){
			// Top left (n=Z-)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 3){
			// Top right (n=Z-)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord0.y_;
		} else if(pv_vertex_i1 == 2){
			// Bottom right (n=Z-)
			tg_vert.texCoord_.x_ = aseg->coord1.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		} else if(pv_vertex_i1 == 0){
			// Bottom left (n=Z-)
			tg_vert.texCoord_.x_ = aseg->coord0.x_;
			tg_vert.texCoord_.y_ = aseg->coord1.y_;
		}
	}
}

// See the note in interface/mesh.h. The cursor walks the same order the
// whole-volume version does, so a run that is interrupted and resumed
// covers exactly what one pass would have.
bool preload_textures_sliced(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg, bool with_lod,
		int64_t deadline_us, PreloadCursor &cursor)
{
	const VoxelFmt fmt(voxel_reg);
	auto region = volume.getEnclosingRegion();
	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();
	if(!cursor.started){
		cursor.x = lc.getX();
		cursor.y = lc.getY();
		cursor.z = lc.getZ();
		cursor.started = true;
	}
	// **The clock is read inside the row.** A voxel whose definition is
	// cached is a table lookup, but one seen for the first time has its
	// atlas segment built here -- image, normal map, surface map, upload
	// -- and that is milliseconds. A check every row let one row run to
	// 80 ms ([CLIENT_FRAME], measured 2026-09-26); every eighth voxel
	// costs a few thousand clock reads over a chunk and bounds it.
	const int CLOCK_EVERY = 8;
	// A run of the same sample is one lookup: the lookups were most of a
	// remesh's 2 ms in a browser ([WEB_MAIN_THREAD])
	VoxelSample last;
	bool have_last = false;
	for(; cursor.z <= uc.getZ(); cursor.z++){
		for(; cursor.y <= uc.getY(); cursor.y++){
			for(; cursor.x <= uc.getX(); cursor.x++){
				VoxelSample v = volume.sample_at(cursor.x, cursor.y, cursor.z);
				if(!have_last || memcmp(&v, &last, sizeof v) != 0){
					const interface::CachedVoxelDefinition *def =
							voxel_reg->get_cached(v, atlas_reg, with_lod);
					if(!def)
						throw Exception(ss_()+"Undefined voxel: "+
								itos(fmt.id_of(v)));
					last = v;
					have_last = true;
				}
				if(++cursor.since_clock >= CLOCK_EVERY){
					cursor.since_clock = 0;
					if(interface::os::time_us() >= deadline_us){
						cursor.x++;
						return false;
					}
				}
			}
			cursor.x = lc.getX();
		}
		cursor.y = lc.getY();
	}
	return true;
}

void preload_textures(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg, bool with_lod)
{
	const VoxelFmt fmt(voxel_reg);
	auto region = volume.getEnclosingRegion();
	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();

	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				VoxelSample v = volume.sample_at(x, y, z);
				const interface::CachedVoxelDefinition *def =
						voxel_reg->get_cached(v, atlas_reg, with_lod);
				if(!def)
					throw Exception(ss_()+"Undefined voxel: "+
							itos(fmt.id_of(v)));
			}
		}
	}
}

static void generate_voxel_shapes(sm_<uint, TemporaryGeometry> &result,
		VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result,
		sm_<uint, TemporaryGeometry> *masked_result,
		const HorizonMap *horizon, int z);

// Which of the three geometries a voxel's faces go in: the solid one, the
// blended one, or the one cut out by its texture. A definition is at most
// one of the two special kinds; being both is a game's mistake and
// translucent is what it gets.
static sm_<uint, TemporaryGeometry>& geometry_for(
		sm_<uint, TemporaryGeometry> &result,
		sm_<uint, TemporaryGeometry> *translucent_result,
		sm_<uint, TemporaryGeometry> *masked_result,
		const interface::CachedVoxelDefinition *def)
{
	if(translucent_result && def->translucent)
		return *translucent_result;
	if(masked_result && def->alpha_masked)
		return *masked_result;
	return result;
}

// **A cheap stand-in shape for the occlusion buffer** ([CLIENT_FRAME]).
// See interface/mesh.h for why, and for the promise this keeps: a cell
// counts only when every voxel in it is opaque and fills its own space,
// so the shape lies inside the solid it stands for and can never hide
// what is visible.
static const int OCC_CELL = 4;

// Does this voxel fill itself and stop light? A shape of its own (a
// slab, a plant, a fence) does not, whatever its edge material says, and
// neither does anything translucent or cut out with an alpha mask.
static bool occ_solid(const interface::CachedVoxelDefinition *def)
{
	return def != nullptr &&
			def->edge_material_id != interface::EDGEMATERIALID_EMPTY &&
			def->face_draw_type == interface::FaceDrawType::ON_EDGE &&
			!def->translucent && !def->alpha_masked && def->shape.empty();
}

void generate_occluder(PODVector<Vector3> &result,
		VoxelVolume &volume, VoxelRegistry *voxel_reg)
{
	result.Clear();
	const VoxelFmt fmt(voxel_reg);
	// The volume is padded by one voxel on each side; the chunk itself is
	// what is inside that, and PolyVox coordinate k + 1 is inner voxel k
	const int w = volume.getWidth() - 2;
	const int h = volume.getHeight() - 2;
	const int d = volume.getDepth() - 2;
	const int nx = w / OCC_CELL, ny = h / OCC_CELL, nz = d / OCC_CELL;
	if(nx < 1 || ny < 1 || nz < 1)
		return;
	const auto &lc = volume.getEnclosingRegion().getLowerCorner();

	// Which cells are wholly solid
	sv_<uint8_t> solid((size_t)nx * ny * nz, 0);
	auto cell = [&](int x, int y, int z) -> bool {
		if(x < 0 || y < 0 || z < 0 || x >= nx || y >= ny || z >= nz)
			return false;
		return solid[((size_t)z * ny + y) * nx + x] != 0;
	};
	bool any = false;
	for(int cz = 0; cz < nz; cz++)
	for(int cy = 0; cy < ny; cy++)
	for(int cx = 0; cx < nx; cx++){
		bool all = true;
		for(int z1 = 0; z1 < OCC_CELL && all; z1++)
		for(int y1 = 0; y1 < OCC_CELL && all; y1++)
		for(int x1 = 0; x1 < OCC_CELL && all; x1++){
			const VoxelSample v = volume.sample_at(
					lc.getX() + 1 + cx * OCC_CELL + x1,
					lc.getY() + 1 + cy * OCC_CELL + y1,
					lc.getZ() + 1 + cz * OCC_CELL + z1);
			if(fmt.undefined(v) || !occ_solid(voxel_reg->get_cached(v)))
				all = false;
		}
		if(all){
			solid[((size_t)cz * ny + cy) * nx + cx] = 1;
			any = true;
		}
	}
	if(!any)
		return;

	// The boundary of that set, a slice at a time, each slice's quads
	// merged greedily so that a chunk of solid rock is six of them rather
	// than six hundred
	const int dim[3] = {nx, ny, nz};
	const float span[3] = {(float)w, (float)h, (float)d};
	sv_<uint8_t> mask;
	for(int axis = 0; axis < 3; axis++){
		const int u = (axis + 1) % 3, v = (axis + 2) % 3;
		for(int side = 0; side < 2; side++){
			const int step = side ? 1 : -1;
			for(int s = 0; s < dim[axis]; s++){
				mask.assign((size_t)dim[u] * dim[v], 0);
				for(int b = 0; b < dim[v]; b++)
				for(int a = 0; a < dim[u]; a++){
					int c[3];
					c[axis] = s; c[u] = a; c[v] = b;
					if(!cell(c[0], c[1], c[2]))
						continue;
					c[axis] = s + step;
					if(cell(c[0], c[1], c[2]))
						continue;
					mask[(size_t)b * dim[u] + a] = 1;
				}
				// Greedy rectangles over the slice's mask
				for(int b = 0; b < dim[v]; b++)
				for(int a = 0; a < dim[u]; a++){
					if(!mask[(size_t)b * dim[u] + a])
						continue;
					int aw = 1;
					while(a + aw < dim[u] && mask[(size_t)b * dim[u] + a + aw])
						aw++;
					int bh = 1;
					for(; b + bh < dim[v]; bh++){
						bool row = true;
						for(int k = 0; k < aw && row; k++)
							if(!mask[(size_t)(b + bh) * dim[u] + a + k])
								row = false;
						if(!row)
							break;
					}
					for(int y1 = 0; y1 < bh; y1++)
						for(int x1 = 0; x1 < aw; x1++)
							mask[(size_t)(b + y1) * dim[u] + a + x1] = 0;
					// A boundary at inner index k sits at local k - span/2;
					// the face of cell s on this side is at s or s + 1
					const float p = (float)((side ? s + 1 : s) * OCC_CELL) -
							span[axis] / 2.0f;
					const float u0 = (float)(a * OCC_CELL) - span[u] / 2.0f;
					const float u1 = (float)((a + aw) * OCC_CELL) -
							span[u] / 2.0f;
					const float v0 = (float)(b * OCC_CELL) - span[v] / 2.0f;
					const float v1 = (float)((b + bh) * OCC_CELL) -
							span[v] / 2.0f;
					Vector3 corner[4];
					const float uu[4] = {u0, u1, u1, u0};
					const float vv[4] = {v0, v0, v1, v1};
					for(int i = 0; i < 4; i++){
						float c3[3];
						c3[axis] = p; c3[u] = uu[i]; c3[v] = vv[i];
						corner[i] = Vector3(c3[0], c3[1], c3[2]);
					}
					// Two triangles; the winding does not matter, the
					// buffer rasterises this shape from both sides
					static const int TRI[6] = {0, 1, 2, 0, 2, 3};
					for(int i = 0; i < 6; i++)
						result.Push(corner[TRI[i]]);
				}
			}
		}
	}
}

void generate_voxel_geometry(sm_<uint, TemporaryGeometry> &result,
		VoxelVolume &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result,
		sm_<uint, TemporaryGeometry> *masked_result,
		const HorizonMap *horizon,
		const pv::Vector3DInt32 *uv_origin)
{
	VoxelGeometryJob job;
	generate_voxel_geometry_step(job, INT64_MAX, result, volume, voxel_reg,
			atlas_reg, use_skylight, translucent_result, masked_result,
			horizon, uv_origin);
}

struct VoxelGeometryJob::State
{
	int stage = 0; // the voxels, the faces, the shapes, done
	int32_t z = 0;
	size_t face = 0;
	pv::SurfaceMesh<pv::PositionMaterialNormal> mesh;
};
VoxelGeometryJob::VoxelGeometryJob(){}
VoxelGeometryJob::~VoxelGeometryJob(){}

bool generate_voxel_geometry_step(VoxelGeometryJob &job, int64_t until_us,
		sm_<uint, TemporaryGeometry> &result,
		VoxelVolume &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result,
		sm_<uint, TemporaryGeometry> *masked_result,
		const HorizonMap *horizon,
		const pv::Vector3DInt32 *uv_origin)
{
	if(!job.s){
		job.s.reset(new VoxelGeometryJob::State());
		job.s->z = volume.getEnclosingRegion().getLowerCorner().getZ();
	}
	VoxelGeometryJob::State &st = *job.s;
	if(st.stage == 3)
		return true;
	const VoxelFmt fmt(voxel_reg);
	pv::SurfaceMesh<pv::PositionMaterialNormal> &pv_mesh = st.mesh;
	if(st.stage == 0){
		// A z layer at a time, which is the extractor's own outer loop:
		// a layer's faces come out as they would in one go, at positions
		// from the layer's corner, so they are moved back by its z
		IsQuadNeededByRegistry<VoxelSample> iqn(voxel_reg);
		VoxelSampleView view(&volume);
		const pv::Region r = volume.getEnclosingRegion();
		const pv::Vector3DInt32 &lc = r.getLowerCorner();
		const pv::Vector3DInt32 &uc = r.getUpperCorner();
		while(st.z < uc.getZ()){
			pv::SurfaceMesh<pv::PositionMaterialNormal> layer;
			pv::CubicSurfaceExtractorWithNormals<VoxelSampleView,
						IsQuadNeededByRegistry<VoxelSample>>
					surfaceExtractor(&view, pv::Region(
						pv::Vector3DInt32(lc.getX(), lc.getY(), st.z),
						pv::Vector3DInt32(uc.getX(), uc.getY(), st.z + 1)),
						&layer, iqn);
			surfaceExtractor.execute();
			const float dz = (float)(st.z - lc.getZ());
			const uint32_t base = pv_mesh.getNoOfVertices();
			for(pv::PositionMaterialNormal v : layer.getVertices()){
				v.position = pv::Vector3DFloat(v.position.getX(),
						v.position.getY(), v.position.getZ() + dz);
				pv_mesh.addVertex(v);
			}
			const sv_<uint32_t> &li = layer.getIndices();
			for(size_t i = 0; i + 2 < li.size(); i += 3)
				pv_mesh.addTriangleCubic(base + li[i], base + li[i + 1],
						base + li[i + 2]);
			st.z++;
			if(interface::os::time_us() >= until_us)
				return false;
		}
		st.stage = 1;
	}

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	int w = volume.getWidth() - 2;
	int h = volume.getHeight() - 2;
	int d = volume.getDepth() - 2;

	// Handle vertices face-by-face in order to copy indices at the same time
	const size_t first_face = st.face;
	for(; st.face < pv_vertices.size() / 4; st.face++){
		const size_t pv_face_i = st.face;
		if(pv_face_i != first_face && pv_face_i % 64 == 0 &&
				interface::os::time_us() >= until_us)
			return false;
		size_t pv_vertex_i0 = pv_face_i * 4;
		VoxelTypeId voxel_id0 = (VoxelTypeId)pv_vertices[pv_vertex_i0].material;
		// We need to get this definition only once per face
		const interface::CachedVoxelDefinition *voxel_def0 =
				voxel_reg->get_cached(voxel_id0);
		if(voxel_def0 == nullptr)
			throw Exception("Unknown voxel in generated geometry: "+
					itos(voxel_id0));
		// Figure out which face this is
		uint face_id = 0;
		const pv::Vector3DFloat &n = pv_vertices[pv_vertex_i0].normal;
		if(n.getY() > 0)
			face_id = 0;
		else if(n.getY() < 0)
			face_id = 1;
		else if(n.getX() > 0)
			face_id = 2;
		else if(n.getX() < 0)
			face_id = 3;
		else if(n.getZ() > 0)
			face_id = 4;
		else if(n.getZ() < 0)
			face_id = 5;
		pv::Vector3DFloat quad[4] = {
			pv_vertices[pv_vertex_i0 + 0].position,
			pv_vertices[pv_vertex_i0 + 1].position,
			pv_vertices[pv_vertex_i0 + 2].position,
			pv_vertices[pv_vertex_i0 + 3].position,
		};
		if(face_owned_by_padding(volume, quad, n))
			continue;
		// What this voxel's param says about drawing it, if its definition
		// has anything to say. The param is the one thing PolyVox does not
		// carry through the extractor, so the voxel is looked up again.
		const interface::VoxelVariant *variant = nullptr;
		uint32_t voxel_color = 0xffffff;
		// The surface modifiers of the voxel behind this face, which every
		// vertex of it carries to the shader
		float mods[interface::VOXEL_SURFACE_MODIFIERS] = {};
		if((fmt.param.bound() && !voxel_def0->variants.empty()) ||
				fmt.color.bound() || fmt.n_surface != 0){
			VoxelSample back = face_back_voxel(volume, quad, n);
			if(fmt.param.bound() && !voxel_def0->variants.empty())
				variant = voxel_def0->variant(fmt.param.get(back));
			if(fmt.color.bound())
				voxel_color = fmt.color.get(back) & 0xffffffUL;
			if(fmt.n_surface != 0){
				fmt.surface_of(back, mods);
				// The tint is the one modifier that is a colour rather than
				// a scalar: the field says how far along the definition's
				// own ramp this voxel is, and the ramp's answer travels in
				// the slot the tint took. It is an albedo tint, so the
				// shader is what applies it -- the vertex colour is light,
				// and a tint of the light vanishes in sunlight.
				if(fmt.tint.bound()){
					mods[0] = pack_tint565(
							tint_ramp_color(voxel_def0, fmt.tint_f(back)));
				}
			}
		}
		// Get texture coordinates (contained in AtlasSegmentCache)
		const uint tile = variant ? (variant->tile_order[face_id] < 6 ?
				variant->tile_order[face_id] : face_id) : face_id;
		// A variant that names textures of its own wears those; see
		// VoxelVariant::textures, which a palette entry is made of
		AtlasSegmentReference seg_ref =
				(variant && tile < variant->texture_refs.size()) ?
				variant->texture_refs[tile] : voxel_def0->textures[tile];
		if(seg_ref.atlas_id == interface::ATLAS_UNDEFINED){
			// This is usually intentional for invisible voxels
			//log_t(MODULE, "Voxel %i face %i atlas undefined", voxel_id0, face_id);
			continue;
		}
		const AtlasSegmentCache *aseg = atlas_reg->get_texture(seg_ref);
		if(aseg == nullptr)
			throw Exception("No atlas segment cache for voxel "+itos(voxel_id0)+
					" face "+itos(face_id));
		// Get or create the appropriate temporary geometry for this atlas
		sm_<uint, TemporaryGeometry> &into = geometry_for(
				result, translucent_result, masked_result, voxel_def0);
		TemporaryGeometry &tg = into[seg_ref.atlas_id];
		if(tg.vertex_data.Empty()){
			tg.atlas_id = seg_ref.atlas_id;
			tg.has_colors = use_skylight;
			tg.has_tangents = fmt.n_surface != 0;
			// It can't get larger than this and will only exist temporarily in
			// memory, so let's do only one big memory allocation
			tg.vertex_data.Reserve(pv_vertices.size() / 4 * 6);
		}
		unsigned corner_colors[4] = {
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff
		};
		if(use_skylight){
			face_vertex_colors(volume, voxel_reg, fmt, quad, n, face_id,
					corner_colors, horizon);
		}
		// The voxel's own colour, and then what its param says about it,
		// combined before either is packed
		if(voxel_color != 0xffffff || (variant &&
				variant->color != 0xffffff)){
			uint32_t tint = variant ?
					mul_rgb(voxel_color, variant->color) : voxel_color;
			for(size_t i = 0; i < 4; i++){
				corner_colors[i] = use_skylight ?
						modulate_color(corner_colors[i], tint) :
						plain_color(tint);
			}
			// Whatever the light is doing, these vertices now carry
			// something that has to reach the shader
			tg.has_colors = true;
		}
		// How far each corner of the face has moved, when the world has a
		// sag bound and anything around here sags. A corner is shared by
		// four voxels and they agree on it, which is what keeps a sagging
		// surface continuous across a voxel boundary.
		float sag[4] = {};
		if(fmt.sag_top.bound() || fmt.sag_bottom.bound()){
			const pv::Vector3DInt32 bp = face_back_pos(volume, quad, n);
			const pv::Vector3DInt32 vlc =
					volume.getEnclosingRegion().getLowerCorner();
			for(size_t i = 0; i < 4; i++){
				// The corners sit half a voxel out from the centres, so the
				// two by two that meets this one starts at the floor of it
				const int cx = vlc.getX() + (int)std::floor(quad[i].getX());
				const int cz = vlc.getZ() + (int)std::floor(quad[i].getZ());
				const float cy = (float)vlc.getY() + quad[i].getY();
				if(cy > (float)bp.getY()){
					// The top of the voxel this face belongs to: down
					sag[i] = -sag_at_corner(volume, voxel_reg, fmt,
							cx, bp.getY(), cz, true);
				} else {
					// Its bottom: up, into the voxel
					sag[i] = sag_at_corner(volume, voxel_reg, fmt,
							cx, bp.getY(), cz, false);
				}
			}
		}
		// **[WORLD_UV]: a texture that spans more than one voxel.** A face
		// repeats its texture once per voxel, so a feature larger than a
		// voxel cannot exist and a big wall reads as a grid of identical
		// stamps. At uv_scale > 1 a face takes its own slice of the
		// repeat from where the voxel sits in the world, and the voxel
		// beside it takes the next one, so the picture crosses them.
		//
		// The wrap falls on a voxel boundary and never inside a quad, so
		// the coordinates stay inside this segment's own rect and the
		// atlas is untouched.
		//
		// The world position comes from the horizon map when the mesher is
		// a world's, and from uv_origin when it is one block standing on
		// its own -- the client-side mesh call, which has no horizon.
		AtlasSegmentCache sliced;
		const AtlasSegmentCache *useg = aseg;
		// **Across and up are two numbers** ([SIGIL_ROUND], 2026-09-24):
		// a frieze along a wall is eight voxels across and one tall, and
		// wrapping both axes with one number made a slab's edge show one
		// eighth of the texture's height, picked by where the slab sat.
		const int uvn = voxel_def0->uv_scale < 1 ? 1 : voxel_def0->uv_scale;
		const int uvm = voxel_def0->uv_scale_v < 1 ? uvn :
				voxel_def0->uv_scale_v;
		if((uvn > 1 || uvm > 1) && (horizon != nullptr || uv_origin != nullptr)){
			const pv::Vector3DInt32 uvp = face_back_pos(volume, quad, n);
			const pv::Vector3DInt32 uvlc =
					volume.getEnclosingRegion().getLowerCorner();
			const int ox = horizon ? horizon->origin_x + HORIZON_PAD :
					uv_origin->getX();
			const int oy = horizon ? horizon->origin_y : uv_origin->getY();
			const int oz = horizon ? horizon->origin_z + HORIZON_PAD :
					uv_origin->getZ();
			const int wx = ox + (uvp.getX() - uvlc.getX() - 1);
			const int wy = oy + (uvp.getY() - uvlc.getY() - 1);
			const int wz = oz + (uvp.getZ() - uvlc.getZ() - 1);
			auto wrap = [](int v, int m){ return ((v % m) + m) % m; };
			int ui, vi;
			if(n.getY() != 0.0f){
				// A floor or a ceiling: the two axes are both across the
				// world, so the second number is the depth one
				ui = wrap(wx, uvn);
				vi = wrap(wz, uvm);
			} else if(n.getX() != 0.0f){
				ui = wrap(wz, uvn);
				// The segment's v grows downwards, so a voxel higher in
				// the world takes a slice further up the texture
				vi = uvm - 1 - wrap(wy, uvm);
			} else {
				ui = wrap(wx, uvn);
				vi = uvm - 1 - wrap(wy, uvm);
			}
			sliced = *aseg;
			const float du = (aseg->coord1.x_ - aseg->coord0.x_) / (float)uvn;
			const float dv = (aseg->coord1.y_ - aseg->coord0.y_) / (float)uvm;
			sliced.coord0.x_ = aseg->coord0.x_ + du * (float)ui;
			sliced.coord1.x_ = sliced.coord0.x_ + du;
			sliced.coord0.y_ = aseg->coord0.y_ + dv * (float)vi;
			sliced.coord1.y_ = sliced.coord0.y_ + dv;
			useg = &sliced;
		}
		// Go through indices of the face and mangle vertices according to them
		// into the temporary vertex buffer
		size_t pv_index_i0 = pv_face_i * 6;
		for(size_t pv_index_i1 = 0; pv_index_i1 < 6; pv_index_i1++){
			size_t pv_index_i = pv_index_i0 + pv_index_i1;
			size_t pv_vertex_i = pv_indices[pv_index_i];
			if(pv_index_i1 == 0 && pv_vertex_i0 != pv_vertex_i)
				throw Exception("First index of face does not point to first "
						"vertex of face");
			const auto &pv_vert = pv_vertices[pv_vertex_i];
			tg.vertex_data.Resize(tg.vertex_data.Size() + 1);
			CustomGeometryVertex &tg_vert = tg.vertex_data.Back();
			tg_vert.position_.x_ = pv_vert.position.getX() - w/2.0f - 0.5f;
			tg_vert.position_.y_ = pv_vert.position.getY() - h/2.0f - 0.5f;
			tg_vert.position_.y_ += sag[pv_vertex_i - pv_vertex_i0];
			tg_vert.position_.z_ = pv_vert.position.getZ() - d/2.0f - 0.5f;
			tg_vert.normal_.x_ = pv_vert.normal.getX();
			tg_vert.normal_.y_ = pv_vert.normal.getY();
			tg_vert.normal_.z_ = pv_vert.normal.getZ();
			// Figure out texture coordinates
			size_t pv_vertex_i1 = pv_vertex_i - pv_vertex_i0;
			assign_txcoords(pv_vertex_i1, useg, tg_vert);
			turn_txcoord(useg, variant ? variant->tile_turns[face_id] :
					voxel_def0->tile_turns[face_id], tg_vert);
			tg_vert.color_ = corner_colors[pv_vertex_i1];
			if(fmt.n_surface != 0){
				tg_vert.tangent_ = Vector4(mods[0], mods[1], mods[2],
						mods[3]);
			}
		}
	}

	if(st.stage == 1){
		st.stage = 2;
		st.mesh.clear();
		st.z = volume.getEnclosingRegion().getLowerCorner().getZ() + 1;
		if(interface::os::time_us() >= until_us)
			return false;
	}
	// The shaped voxels, a z layer at a time as well
	while(st.z <= volume.getEnclosingRegion().getUpperCorner().getZ() - 1){
		generate_voxel_shapes(result, volume, voxel_reg, fmt, atlas_reg,
				use_skylight, translucent_result, masked_result, horizon,
				st.z++);
		if(interface::os::time_us() >= until_us)
			return false;
	}
	st.stage = 3;
	return true;
}

// The four columns at a liquid voxel's corner, read for liquid_corner()
// (liquid_corner.h, which holds the rules)
static float liquid_corner_top(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt, int x, int y, int z,
		const interface::CachedVoxelDefinition *def, int dx, int dz)
{
	const int off[4][2] = {{0, 0}, {dx, 0}, {0, dz}, {dx, dz}};
	auto same = [&](int cx, int cy, int cz){
		VoxelSample v = volume.sample_at(cx, cy, cz);
		const interface::CachedVoxelDefinition *d =
				fmt.undefined(v) ? nullptr : voxel_reg->get_cached(v);
		return d != nullptr && d->is_liquid &&
				d->shape_group == def->shape_group;
	};
	LiquidColumn c[4];
	for(size_t i = 0; i < 4; i++){
		int cx = x + off[i][0];
		int cz = z + off[i][1];
		c[i].above = same(cx, y + 1, cz);
		VoxelSample cv = volume.sample_at(cx, y, cz);
		const interface::CachedVoxelDefinition *cdef =
				fmt.undefined(cv) ? nullptr : voxel_reg->get_cached(cv);
		if(cdef == nullptr)
			continue;
		if(cdef->is_liquid && cdef->shape_group == def->shape_group){
			// A source whose param2 is something else -- VoxeLibre's water
			// carries its palette index there -- used to be read as a
			// variant and averaged with the flow beside it, and the shore
			// sagged into the flow ([WATER_LIGHT] 3). How high a flowing
			// column stands is its own param's business: Luanti puts the
			// level in param2.
			const interface::VoxelVariant *cvar =
					cdef->liquid_is_source || !fmt.param.bound() ? nullptr :
					cdef->variant(fmt.param.get(cv));
			c[i].kind = cvar ? LiquidColumn::FLOW : LiquidColumn::SOURCE;
			if(cvar)
				c[i].top = cvar->liquid_top;
		} else if(cdef->fully_empty){
			c[i].kind = LiquidColumn::EMPTY;
			c[i].below = same(cx, y - 1, cz);
		}
	}
	return liquid_corner(c, LIQUID_SAG);
}

// Which of the six directions a connecting voxel's neighbours connect in, as
// a bit per face in the usual order. A shape's quad that names a direction is
// drawn only when that bit is set, which is how a fence gets a rail towards
// the fence next to it and no rail towards the air.
//
// Two voxels connect when the neighbour is in one of the families this one
// reaches out to -- one bit of connect_mask per family -- or, for a voxel
// that says so, when the neighbour is simply solid, which is how a fence
// reaches into a wall of stone. What the families are is the game's business;
// see interface/voxel.h.
static bool connects_to(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt, int x, int y, int z,
		const interface::CachedVoxelDefinition *def)
{
	VoxelSample nv = volume.sample_at(x, y, z);
	if(fmt.undefined(nv))
		return false;
	const interface::CachedVoxelDefinition *ndef = voxel_reg->get_cached(nv);
	if(ndef == nullptr)
		return false;
	if(ndef->connect_group != 0 && ndef->connect_group <= 32 &&
			(def->connect_mask & (1u << (ndef->connect_group - 1))) != 0)
		return true;
	if(def->connect_to_solid)
		return ndef->physically_solid && ndef->shape.empty();
	return false;
}

static uint connected_faces(VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt, int x, int y, int z,
		const interface::CachedVoxelDefinition *def, uint *stepped_up)
{
	static const int FACE_DIR[6][3] = {
		{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
		{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
	};
	uint faces = 0;
	for(size_t i = 0; i < 6; i++){
		if(connects_to(volume, voxel_reg, fmt, x + FACE_DIR[i][0],
				y + FACE_DIR[i][1], z + FACE_DIR[i][2], def))
			faces |= 1u << i;
	}
	if(stepped_up == nullptr)
		return faces;
	// A step up or down, for a voxel whose shape follows one: a rail runs
	// into the rail on the slope above it and the one below it as much as
	// into the one beside it, which is Luanti's own rule for them. The four
	// horizontal directions only, in Luanti's own order: +Z, -Z, -X, +X.
	static const int STEP_DIR[4][3] = {
		{0, 0, 1}, {0, 0, -1}, {-1, 0, 0}, {1, 0, 0},
	};
	*stepped_up = 0;
	for(size_t i = 0; i < 4; i++){
		if(connects_to(volume, voxel_reg, fmt, x + STEP_DIR[i][0], y + 1,
				z + STEP_DIR[i][2], def)){
			*stepped_up |= 1u << i;
			faces |= 1u << (i == 0 ? 4 : i == 1 ? 5 : i == 2 ? 3 : 2);
		} else if(connects_to(volume, voxel_reg, fmt, x + STEP_DIR[i][0], y - 1,
				z + STEP_DIR[i][2], def)){
			faces |= 1u << (i == 0 ? 4 : i == 1 ? 5 : i == 2 ? 3 : 2);
		}
	}
	return faces;
}

// The quads of the voxels that have a shape of their own, appended to the
// same temporary geometry the cubes went into.
//
// A voxel's quads are copied as they are, with the voxel's position added and
// the texture coordinates mapped into wherever the atlas put the tile. That
// is the whole point of shapes living in the voxel registry: a chunk full of
// stairs and fences costs what a chunk of cubes costs, where a scene node per
// stair would not.
//
// Only the voxels inside the chunk are drawn. The padding belongs to the
// neighbouring chunks, which draw it themselves; the padding is here so that
// the cube faces can be culled against it.
static void generate_voxel_shapes(sm_<uint, TemporaryGeometry> &result,
		VoxelVolume &volume,
		VoxelRegistry *voxel_reg, const VoxelFmt &fmt,
		AtlasRegistry *atlas_reg,
		bool use_skylight,
		sm_<uint, TemporaryGeometry> *translucent_result,
		sm_<uint, TemporaryGeometry> *masked_result,
		const HorizonMap *horizon, int z)
{
	const bool packed_alpha = horizon != nullptr;
	const pv::Region &region = volume.getEnclosingRegion();
	const pv::Vector3DInt32 lc = region.getLowerCorner();
	const pv::Vector3DInt32 uc = region.getUpperCorner();
	const float w = volume.getWidth() - 2;
	const float h = volume.getHeight() - 2;
	const float d = volume.getDepth() - 2;

	{
		for(int y = lc.getY() + 1; y <= uc.getY() - 1; y++){
			for(int x = lc.getX() + 1; x <= uc.getX() - 1; x++){
				VoxelSample v = volume.sample_at(x, y, z);
				const interface::CachedVoxelDefinition *def =
						voxel_reg->get_cached(v);
				if(def == nullptr)
					continue;
				// What this voxel's param says about drawing it: a shape of
				// its own, a colour, how high its liquid stands
				const interface::VoxelVariant *variant = fmt.param.bound() ?
						def->variant(fmt.param.get(v)) : nullptr;
				const sv_<interface::VoxelQuad> &own_shape =
						(variant && !variant->shape.empty()) ?
						variant->shape : def->shape;
				if(own_shape.empty() && def->shape_masked.empty())
					continue;
				const float liquid_top = variant ?
						variant->liquid_top : def->liquid_top;
				// The surface modifiers of this voxel, carried by every
				// vertex of every quad of its shape
				float mods[interface::VOXEL_SURFACE_MODIFIERS] = {};
				if(fmt.n_surface != 0){
					fmt.surface_of(v, mods);
					if(fmt.tint.bound()){
						mods[0] = pack_tint565(
								tint_ramp_color(def, fmt.tint_f(v)));
					}
				}
				// Where this voxel's centre is in the chunk's own model
				// coordinates; the same arithmetic the cube faces get
				const float cx = (x - lc.getX()) - w / 2.0f - 0.5f;
				const float cy = (y - lc.getY()) - h / 2.0f - 0.5f;
				const float cz = (z - lc.getZ()) - d / 2.0f - 0.5f;
				// A shaped voxel is lit by its own light rather than by the
				// voxel in front of each face: there is no "in front" for an
				// arbitrary quad, and a plant or a rail is lit by the air it
				// stands in, which is the voxel it is in.
				//
				// Unless the shape fills its voxel and stands in the one
				// above it -- a rooted plant -- in which case its own voxel
				// is solid ground and carries no light worth having; see
				// VoxelDefinition::shape_lit_from_above.
				//
				// And unless the shape *blocks* light, which a slab, a stair
				// and a snow layer do: light does not enter a voxel it
				// cannot pass through, so such a voxel's own light is zero
				// and the shape would be drawn black. A cube in the same
				// place is lit face by face from the voxel each face points
				// into; the nearest thing a shape has to that is the
				// brightest of the six around it, which is what a face of it
				// would have found. Measured in minetest_game: a snow slab
				// over lit ground under an open sky, own light 0 against the
				// 15 of the air on top of it.
				VoxelSample lv = def->shape_lit_from_above ?
						volume.sample_at(x, y + 1, z) : v;
				if(!def->shape_lit_from_above && !def->transmits_light){
					static const int NB[6][3] = {
						{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
						{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
					};
					float best = fmt.sky_f(lv) + fmt.lamp_f(lv);
					for(size_t k = 0; k < 6; k++){
						const VoxelSample nv = volume.sample_at(
								x + NB[k][0], y + NB[k][1], z + NB[k][2]);
						// Nothing generated there yet reads as full light
						// in both banks, and a snow layer at the edge of
						// the loaded world took it: the far tree tops of
						// vp5 at 02:00 drawn white ([LOD_LIGHT]'s finding)
						if(fmt.undefined(nv))
							continue;
						const float nb = fmt.sky_f(nv) + fmt.lamp_f(nv);
						if(nb > best){
							best = nb;
							lv = nv;
						}
					}
				}
				float sky_f = fmt.sky_f(lv);
				float lamp_f = fmt.lamp_f(lv);
				// The terrain beyond the chunk for a shape, as for a cube
				// face (face_vertex_colors()): the sea, a plant, a snow
				// layer under a mountain see the same horizon. Looked up
				// as a floor does, the whole ring, since a shape's quads
				// point every way. Without it the sea read as the most
				// occluded thing in the diagnostic's frame -- it was the
				// packed layout's terrain of one drawn cyan, not a reading
				// -- and had no cap at all in the light.
				float terrain = 1.0f;
				if(horizon){
					terrain = terrain_sky(horizon,
							horizon->origin_x + HORIZON_PAD + x - lc.getX() - 1,
							horizon->origin_y + y - lc.getY() - 1,
							horizon->origin_z + HORIZON_PAD + z - lc.getZ() - 1,
							pv::Vector3DFloat(0, 1, 0));
				}
				// Which directions this voxel connects in, once per voxel
				// rather than once per quad that asks. Only a voxel that
				// reaches out at all pays for it.
				// A voxel whose whole shape depends on what is around it --
				// a rail -- keeps one shape per mask of the four horizontal
				// connections, and four more for the slopes; the rest of
				// the loop walks that instead of `shape`.
				uint stepped_up = 0;
				const bool masked = !def->shape_masked.empty();
				const uint faces = (def->connect_mask != 0 ||
						def->connect_to_solid || masked) ?
						connected_faces(volume, voxel_reg, fmt, x, y, z, def,
								masked ? &stepped_up : nullptr) : 0;
				const interface::VoxelQuad *quads = own_shape.data();
				size_t quad_from = 0;
				size_t quad_to = own_shape.size();
				if(masked){
					// The four horizontal connections in Luanti's own bit
					// order for them: +Z is 1, -Z is 2, -X is 4, +X is 8
					uint m = ((faces >> 4) & 1) |
							(((faces >> 5) & 1) << 1) |
							(((faces >> 3) & 1) << 2) |
							(((faces >> 2) & 1) << 3);
					// A slope wins over the flat shapes, and the last
					// direction that has one wins between slopes, which is
					// what Luanti does with them
					for(uint i = 0; i < 4; i++){
						if(stepped_up & (1u << i))
							m = 16 + i;
					}
					quads = def->shape_masked.data();
					quad_from = def->shape_masked_begin[m];
					quad_to = def->shape_masked_begin[m + 1];
				}
				// A liquid's four top corners, once per voxel rather than
				// once per vertex that sits on one
				const bool liquid_corners = def->is_liquid;
				float corner[2][2] = {};
				if(liquid_corners){
					for(int ix = 0; ix < 2; ix++){
						for(int iz = 0; iz < 2; iz++){
							corner[ix][iz] = liquid_corner_top(volume,
									voxel_reg, fmt, x, y, z, def,
									ix == 0 ? -1 : 1, iz == 0 ? -1 : 1);
						}
					}
				}
				for(size_t quad_i = quad_from; quad_i < quad_to; quad_i++){
					const interface::VoxelQuad &quad = quads[quad_i];
					// A quad that belongs to one direction is drawn only
					// when that direction connects, and one that belongs to
					// standing alone only when none of them does; one past
					// 7 this does not know is drawn always, as 0
					if(quad.connect_dir == 7){
						if(faces != 0)
							continue;
					} else if(quad.connect_dir != 0 && quad.connect_dir < 7 &&
							!(faces & (1u << (quad.connect_dir - 1)))){
						continue;
					}
					// 0...5 is one of the voxel's faces and 6 and over is
					// one of its extra textures; see
					// VoxelDefinition::extra_textures
					AtlasSegmentReference seg_ref;
					if(variant && quad.tile < variant->texture_refs.size()){
						// The variant's own, which is a palette entry's
						// tinted tile; see VoxelVariant::textures
						seg_ref = variant->texture_refs[quad.tile];
					} else if(quad.tile < 6){
						seg_ref = def->textures[quad.tile];
					} else {
						const size_t i = quad.tile - 6;
						if(i >= def->extra_textures.size())
							continue;
						seg_ref = def->extra_textures[i];
					}
					if(seg_ref.atlas_id == interface::ATLAS_UNDEFINED)
						continue;
					const AtlasSegmentCache *aseg =
							atlas_reg->get_texture(seg_ref);
					if(aseg == nullptr)
						continue;
					// The quad's own normal, for the per-face brightness the
					// cubes get
					Vector3 e1(quad.p[1][0] - quad.p[0][0],
							quad.p[1][1] - quad.p[0][1],
							quad.p[1][2] - quad.p[0][2]);
					Vector3 e2(quad.p[2][0] - quad.p[0][0],
							quad.p[2][1] - quad.p[0][1],
							quad.p[2][2] - quad.p[0][2]);
					Vector3 n = e1.CrossProduct(e2).Normalized();
					uint face_id = 0;
					if(std::fabs(n.y_) >= std::fabs(n.x_) &&
							std::fabs(n.y_) >= std::fabs(n.z_))
						face_id = n.y_ >= 0 ? 0 : 1;
					else if(std::fabs(n.x_) >= std::fabs(n.z_))
						face_id = n.x_ >= 0 ? 2 : 3;
					else
						face_id = n.z_ >= 0 ? 4 : 5;
					// A quad of a grouped shape against a neighbour of the
					// same group is a face inside a body of it -- the water
					// inside a lake -- and is not drawn. Only an
					// axis-aligned quad is tested, and it is assumed to lie
					// on the voxel's boundary in that direction; a shape
					// whose quads do not is not what a group is for.
					// simplified: a face against a *lower* level of the same
					// liquid is dropped with the rest, which leaves a gap
					// where the surface steps down. Corner heights, which
					// make the surface continuous instead of stepped, are
					// what remove both.
					static const int FACE_AXIS[6] = {1, 1, 0, 0, 2, 2};
					static const int FACE_DIR[6][3] = {
						{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
						{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
					};
					if(def->shape_group != 0 &&
							std::fabs(n.Data()[FACE_AXIS[face_id]]) > 0.99f){
						VoxelSample nv = volume.sample_at(
								x + FACE_DIR[face_id][0],
								y + FACE_DIR[face_id][1],
								z + FACE_DIR[face_id][2]);
						const interface::CachedVoxelDefinition *ndef =
								fmt.undefined(nv) ? nullptr :
								voxel_reg->get_cached(nv);
						// The same group: a face inside a body of it. Or
						// something opaque: the face is that voxel's own, as
						// in IsQuadNeededByRegistry.
						if(ndef != nullptr &&
								(ndef->shape_group == def->shape_group ||
								(def->translucent && !ndef->translucent &&
								ndef->edge_material_id !=
								interface::EDGEMATERIALID_EMPTY)))
							continue;
					}
					sm_<uint, TemporaryGeometry> &into = geometry_for(
							result, translucent_result, masked_result, def);
					TemporaryGeometry &tg = into[seg_ref.atlas_id];
					if(tg.vertex_data.Empty()){
						tg.atlas_id = seg_ref.atlas_id;
						tg.has_colors = use_skylight;
						tg.has_tangents = fmt.n_surface != 0;
					}
					unsigned color = 0xffffffff;
					if(use_skylight){
						float shade = FACE_SHADE[face_id];
						// No constant bounce for a packed client; see
						// face_vertex_colors()
						float bshade = packed_alpha ? 0.0f : shade * (1.0f - sky_f);
						const Color BOUNCE_COLOR(bounce_r, bounce_g, bounce_b);
						// The packed layout as face_vertex_colors() writes
						// it: lamp, terrain, local shade; the sky's share
						// takes the terrain, the local shade does not
						color = SHADOW_KINDS ? Color(terrain, 1.0f, 1.0f,
								sky_alpha(sky_f, shade * terrain, true)).ToUInt() :
							packed_alpha ? Color(lamp_f, terrain,
								shade / 1.15f > 1.0f ? 1.0f : shade / 1.15f,
								sky_alpha(sky_f, shade * terrain, true)).ToUInt() : Color(
								BOUNCE_COLOR.r_ * bshade +
										LAMP_COLOR.r_ * lamp_f * shade,
								BOUNCE_COLOR.g_ * bshade +
										LAMP_COLOR.g_ * lamp_f * shade,
								BOUNCE_COLOR.b_ * bshade +
										LAMP_COLOR.b_ * lamp_f * shade,
								sky_alpha(sky_f, shade, packed_alpha)).ToUInt();
					}
					uint32_t tint = 0xffffff;
					if(fmt.color.bound())
						tint = fmt.color.get(v) & 0xffffffUL;
					if(variant)
						tint = mul_rgb(tint, variant->color);
					if(tint != 0xffffff){
						color = use_skylight ?
								modulate_color(color, tint) :
								plain_color(tint);
						tg.has_colors = true;
					}
					// Two triangles, and the same two the other way round
					// when the shape is drawn from both sides
					static const int WINDINGS[2][6] = {
						{0, 1, 2, 0, 2, 3},
						{0, 2, 1, 0, 3, 2},
					};
					int windings = def->shape_double_sided ? 2 : 1;
					for(int wi = 0; wi < windings; wi++){
						for(int i = 0; i < 6; i++){
							int c = WINDINGS[wi][i];
							tg.vertex_data.Resize(tg.vertex_data.Size() + 1);
							CustomGeometryVertex &tv = tg.vertex_data.Back();
							float py = quad.p[c][1];
							// A vertex on the liquid's own surface follows
							// the corner it stands at
							if(liquid_corners && std::fabs(
									py - liquid_top) < 1e-4f){
								py = corner[quad.p[c][0] >= 0.0f ? 1 : 0]
										[quad.p[c][2] >= 0.0f ? 1 : 0];
							}
							tv.position_ = Vector3(cx + quad.p[c][0],
									cy + py, cz + quad.p[c][2]);
							tv.normal_ = wi == 0 ? n : -n;
							tv.texCoord_ = Vector2(
									aseg->coord0.x_ + quad.uv[c][0] *
											(aseg->coord1.x_ - aseg->coord0.x_),
									aseg->coord0.y_ + quad.uv[c][1] *
											(aseg->coord1.y_ - aseg->coord0.y_));
							tv.color_ = color;
							if(fmt.n_surface != 0){
								tv.tangent_ = Vector4(mods[0], mods[1],
										mods[2], mods[3]);
							}
						}
					}
				}
			}
		}
	}
}

void set_voxel_geometry(CustomGeometry *cg, Context *context,
		const sm_<uint, TemporaryGeometry> &temp_geoms,
		AtlasRegistry *atlas_reg)
{
	ResourceCache *cache = context->GetSubsystem<ResourceCache>();

	cg->Clear();

	cg->SetNumGeometries(temp_geoms.size());
	Vector<PODVector<CustomGeometryVertex>> &cg_all_vertices = cg->GetVertices();

	unsigned cg_i = 0;
	for(auto &pair : temp_geoms){
		const TemporaryGeometry &tg = pair.second;
		const AtlasCache *atlas_cache =
				atlas_reg->get_atlas_cache(tg.atlas_id);
		if(atlas_cache == nullptr)
			throw Exception("atlas_cache == nullptr");
		if(atlas_cache->texture == nullptr)
			throw Exception("atlas_cache->texture == nullptr");
		cg->DefineGeometry(cg_i, TRIANGLE_LIST, tg.vertex_data.Size(),
				true, tg.has_colors, true, tg.has_tangents);
		PODVector<CustomGeometryVertex> &cg_vertices = cg_all_vertices[cg_i];
		cg_vertices = tg.vertex_data;
		Material *material = new Material(context);
		if(tg.has_colors){
			// No technique: the game picks one in its material callback, as
			// only it knows which shader reads the maps set up here. Skylit
			// geometry stays invisible until it does. See interface/atlas.h
			// for what the maps contain and interface/mesh.h for the rest of
			// what a shader is handed.
			//
			// The atlas derives a normal map and a surface map
			// from each segment's image, so the maps are the whole material
			// and these two constants are only added on top of them
			material->SetShaderParameter("Roughness", 0.0f);
			material->SetShaderParameter("Metallic", 0.0f);
			material->SetTexture(TU_NORMAL, atlas_cache->normal_texture);
			material->SetTexture(TU_SPECULAR, atlas_cache->spec_texture);
		} else {
			material->SetTechnique(0,
					cache->GetResource<Technique>("Techniques/Diff.xml"));
		}
		material->SetTexture(TU_DIFFUSE, atlas_cache->texture);
		cg->SetMaterial(cg_i, material);
		cg_i++;
	}

	cg->Commit();
}

// Set custom geometry from voxel volume, using a voxel registry
// Volume should be padded by one voxel on each edge
void set_voxel_geometry(CustomGeometry *cg, Context *context,
		VoxelVolume &volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight, const pv::Vector3DInt32 *uv_origin)
{
	preload_textures(volume, voxel_reg, atlas_reg);

	sm_<uint, TemporaryGeometry> temp_geoms;
	generate_voxel_geometry(temp_geoms, volume, voxel_reg, atlas_reg,
			use_skylight, nullptr, nullptr, nullptr, uv_origin);

	set_voxel_geometry(cg, context, temp_geoms, atlas_reg);
}

up_<VoxelVolume> generate_voxel_lod_volume(
		int lod, VoxelVolume&volume_orig,
		VoxelRegistry *voxel_reg)
{
	const VoxelFmt fmt(voxel_reg);
	pv::Region region_orig = volume_orig.getEnclosingRegion();
	auto &lc_orig = region_orig.getLowerCorner();
	auto &uc_orig = region_orig.getUpperCorner();

	pv::Region region(lc_orig / lod - pv::Vector3DInt32(1, 1, 1),
			uc_orig / lod + pv::Vector3DInt32(1, 1, 1));
	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();

	up_<VoxelVolume> volume(
			new VoxelVolume(region));
	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				VoxelSample v_orig;
				// The light of the block is the brightest light in it, not
				// the light of the voxel that won the look. A block with any
				// air in it is a block a face is lit through, and the voxel
				// that wins is a solid one with no light in it at all.
				uint8_t max_sky = 0, max_lamp = 0;
				for(int x1 = 0; x1 < lod; x1++){
					for(int y1 = 0; y1 < lod; y1++){
						for(int z1 = 0; z1 < lod; z1++){
							pv::Vector3DInt32 p_orig(
									x * lod + x1,
									y * lod + y1,
									z * lod + z1
							);
							if(!region_orig.containsPoint(p_orig))
								continue;
							VoxelSample v1 = volume_orig.sample_at(p_orig);
							if(fmt.undefined(v1))
								continue;
							// TODO: Prioritize voxel types better
							// Higher is probably more interesting
							// Which definition it wears rather than which
							// id it holds: a world with no id role has the
							// same one everywhere, and this is picking what
							// a block of voxels looks like from far away
							if(fmt.look_id(v1) > fmt.look_id(v_orig))
								v_orig = v1;
							if(fmt.light_sky.bound()){
								uint8_t l = fmt.light_sky.get(v1);
								if(l > max_sky) max_sky = l;
							}
							if(fmt.light_lamp.bound()){
								uint8_t l = fmt.light_lamp.get(v1);
								if(l > max_lamp) max_lamp = l;
							}
						}
					}
				}
				if(fmt.light_sky.bound())
					fmt.light_sky.set(v_orig, max_sky);
				if(fmt.light_lamp.bound())
					fmt.light_lamp.set(v_orig, max_lamp);
				volume->set_sample_at(x, y, z, v_orig);
			}
		}
	}
	return volume;
}

// Can be called from any thread
void generate_voxel_lod_geometry(int lod,
		sm_<uint, TemporaryGeometry> &result,
		VoxelVolume &lod_volume,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight, const HorizonMap *horizon)
{
	const VoxelFmt fmt(voxel_reg);
	IsQuadNeededByRegistry<VoxelSample> iqn(voxel_reg, true);
	pv::SurfaceMesh<pv::PositionMaterialNormal> pv_mesh;
	VoxelSampleView lod_view(&lod_volume);
	pv::CubicSurfaceExtractorWithNormals<VoxelSampleView,
				IsQuadNeededByRegistry<VoxelSample>>
			surfaceExtractor(&lod_view, lod_volume.getEnclosingRegion(), &pv_mesh, iqn);
	surfaceExtractor.execute();

	const sv_<uint32_t> &pv_indices = pv_mesh.getIndices();
	const sv_<pv::PositionMaterialNormal> &pv_vertices = pv_mesh.getVertices();

	int w = (lod_volume.getWidth() - 2) * lod - 2;
	int h = (lod_volume.getHeight() - 2) * lod - 2;
	int d = (lod_volume.getDepth() - 2) * lod - 2;

	// Handle vertices face-by-face in order to copy indices at the same time
	for(size_t pv_face_i = 0; pv_face_i < pv_vertices.size() / 4; pv_face_i++){
		size_t pv_vertex_i0 = pv_face_i * 4;
		VoxelTypeId voxel_id0 = (VoxelTypeId)pv_vertices[pv_vertex_i0].material;
		// We need to get this definition only once per face
		const interface::CachedVoxelDefinition *voxel_def0 =
				voxel_reg->get_cached(voxel_id0);
		if(voxel_def0 == nullptr)
			throw Exception("Unknown voxel in generated geometry: "+
					itos(voxel_id0));
		// Figure out which face this is
		uint face_id = 0;
		const pv::Vector3DFloat &n = pv_vertices[pv_vertex_i0].normal;
		if(n.getY() > 0)
			face_id = 0;
		else if(n.getY() < 0)
			face_id = 1;
		else if(n.getX() > 0)
			face_id = 2;
		else if(n.getX() < 0)
			face_id = 3;
		else if(n.getZ() > 0)
			face_id = 4;
		else if(n.getZ() < 0)
			face_id = 5;
		pv::Vector3DFloat quad[4] = {
			pv_vertices[pv_vertex_i0 + 0].position,
			pv_vertices[pv_vertex_i0 + 1].position,
			pv_vertices[pv_vertex_i0 + 2].position,
			pv_vertices[pv_vertex_i0 + 3].position,
		};
		if(face_owned_by_padding(lod_volume, quad, n))
			continue;
		// The voxel behind the face: which variant it wears, the colour it
		// is drawn in and its surface modifiers, read the way
		// generate_voxel_geometry() reads them.
		const interface::VoxelVariant *variant = nullptr;
		uint32_t voxel_color = 0xffffff;
		float mods[interface::VOXEL_SURFACE_MODIFIERS] = {};
		if((fmt.param.bound() && !voxel_def0->variants.empty()) ||
				fmt.color.bound() || fmt.n_surface != 0){
			VoxelSample back = face_back_voxel(lod_volume, quad, n);
			if(fmt.param.bound() && !voxel_def0->variants.empty())
				variant = voxel_def0->variant(fmt.param.get(back));
			if(fmt.color.bound())
				voxel_color = fmt.color.get(back) & 0xffffffUL;
			if(fmt.n_surface != 0){
				fmt.surface_of(back, mods);
				if(fmt.tint.bound()){
					mods[0] = pack_tint565(
							tint_ramp_color(voxel_def0, fmt.tint_f(back)));
				}
			}
		}
		// Get texture coordinates (contained in AtlasSegmentCache)
		size_t lod_i = lod - 2;
		if(lod_i >= interface::VOXELDEF_NUM_LOD)
			lod_i = interface::VOXELDEF_NUM_LOD - 1;
		// **A variant wears its own texture at every distance.** A palette
		// is a variant whose tiles are the definition's through a multiply
		// -- VoxeLibre colours every leaf and every blade of grass that way
		// -- and the definition's own LOD segments are the untinted ones,
		// so a LOD chunk drew the whole living world grey ([CLIENT_FRAME]).
		// There are no LOD segments for a variant's tiles: three of them
		// per palette entry per face is an atlas nobody can afford, and
		// what the LOD simulation buys -- a texture pre-averaged for
		// minification -- the mip chain buys again. So a variant's own
		// full-resolution tile is what a far chunk wears.
		const uint tile = variant ? (variant->tile_order[face_id] < 6 ?
				variant->tile_order[face_id] : face_id) : face_id;
		AtlasSegmentReference seg_ref =
				(variant && tile < variant->texture_refs.size()) ?
				variant->texture_refs[tile] :
				voxel_def0->lod_textures[lod_i][face_id];
		if(seg_ref.atlas_id == interface::ATLAS_UNDEFINED){
			// This is usually intentional for invisible voxels
			//log_t(MODULE, "Voxel %i face %i atlas undefined", voxel_id0, face_id);
			continue;
		}
		const AtlasSegmentCache *aseg = atlas_reg->get_texture(seg_ref);
		if(aseg == nullptr)
			throw Exception("No atlas segment cache for voxel "+itos(voxel_id0)+
					" face "+itos(face_id));
		// Get or create the appropriate temporary geometry for this atlas
		TemporaryGeometry &tg = result[seg_ref.atlas_id];
		if(tg.vertex_data.Empty()){
			tg.atlas_id = seg_ref.atlas_id;
			tg.has_colors = use_skylight;
			// A world that binds surface modifiers is drawn with a technique
			// that reads them out of the tangent. Without this the LOD
			// geometry has no tangent stream for that technique to read and
			// is not drawn at all -- which is what a world ending in a dome
			// a few chunks out looks like.
			tg.has_tangents = fmt.n_surface != 0;
			// It can't get larger than this and will only exist temporarily in
			// memory, so let's do only one big memory allocation
			tg.vertex_data.Reserve(pv_vertices.size() / 4 * 6);
		}
		unsigned corner_colors[4] = {
			0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff
		};
		if(use_skylight){
			face_vertex_colors(lod_volume, voxel_reg, fmt, quad, n, face_id,
					corner_colors, horizon, lod);
		}
		// The voxel's own colour and what its param says about it, combined
		// before either is packed -- generate_voxel_geometry()'s own lines
		if(voxel_color != 0xffffff ||
				(variant && variant->color != 0xffffff)){
			uint32_t tint = variant ?
					mul_rgb(voxel_color, variant->color) : voxel_color;
			for(size_t i = 0; i < 4; i++){
				corner_colors[i] = use_skylight ?
						modulate_color(corner_colors[i], tint) :
						plain_color(tint);
			}
			tg.has_colors = true;
		}
		// Go through indices of the face and mangle vertices according to them
		// into the temporary vertex buffer
		size_t pv_index_i0 = pv_face_i * 6;
		for(size_t pv_index_i1 = 0; pv_index_i1 < 6; pv_index_i1++){
			size_t pv_index_i = pv_index_i0 + pv_index_i1;
			size_t pv_vertex_i = pv_indices[pv_index_i];
			if(pv_index_i1 == 0 && pv_vertex_i0 != pv_vertex_i)
				throw Exception("First index of face does not point to first "
						"vertex of face");
			const auto &pv_vert = pv_vertices[pv_vertex_i];
			tg.vertex_data.Resize(tg.vertex_data.Size() + 1);
			CustomGeometryVertex &tg_vert = tg.vertex_data.Back();
			tg_vert.position_.x_ = pv_vert.position.getX() * lod
					- w/2.0f - 0.5f - lod/2.0f;
			tg_vert.position_.y_ = pv_vert.position.getY() * lod
					- h/2.0f - 0.5f - lod/2.0f;
			tg_vert.position_.z_ = pv_vert.position.getZ() * lod
					- d/2.0f - 0.5f - lod/2.0f;
			tg_vert.normal_.x_ = pv_vert.normal.getX();
			tg_vert.normal_.y_ = pv_vert.normal.getY();
			tg_vert.normal_.z_ = pv_vert.normal.getZ();
			// Figure out texture coordinates
			size_t pv_vertex_i1 = pv_vertex_i - pv_vertex_i0;
			assign_txcoords(pv_vertex_i1, aseg, tg_vert);
			tg_vert.color_ = corner_colors[pv_vertex_i1];
			if(fmt.n_surface != 0){
				tg_vert.tangent_ = Vector4(mods[0], mods[1], mods[2],
						mods[3]);
			}
		}
	}
}

void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
		const sm_<uint, TemporaryGeometry> &temp_geoms,
		AtlasRegistry *atlas_reg)
{
	ResourceCache *cache = context->GetSubsystem<ResourceCache>();

	cg->Clear();

	cg->SetNumGeometries(temp_geoms.size());
	Vector<PODVector<CustomGeometryVertex>> &cg_all_vertices = cg->GetVertices();

	unsigned cg_i = 0;
	for(auto &pair : temp_geoms){
		const TemporaryGeometry &tg = pair.second;
		const AtlasCache *atlas_cache =
				atlas_reg->get_atlas_cache(tg.atlas_id);
		if(atlas_cache == nullptr)
			throw Exception("atlas_cache == nullptr");
		if(atlas_cache->texture == nullptr)
			throw Exception("atlas_cache->texture == nullptr");
		cg->DefineGeometry(cg_i, TRIANGLE_LIST, tg.vertex_data.Size(),
				true, tg.has_colors, true, tg.has_tangents);
		PODVector<CustomGeometryVertex> &cg_vertices = cg_all_vertices[cg_i];
		cg_vertices = tg.vertex_data;
		Material *material = new Material(context);
		// Every LOD is lit the same way as the geometry next to it. An unlit
		// technique cannot match a scene lit in HDR and tonemapped, whatever
		// is baked into its texture, and a visible brightness step at the LOD
		// boundary is worse than the coarseness of the LOD itself.
		if(tg.has_colors){
			// The game sets the technique; see set_voxel_geometry()
			material->SetShaderParameter("Roughness", 0.0f);
			material->SetShaderParameter("Metallic", 0.0f);
			material->SetTexture(TU_NORMAL, atlas_cache->normal_texture);
			material->SetTexture(TU_SPECULAR, atlas_cache->spec_texture);
		} else {
			material->SetTechnique(0,
					cache->GetResource<Technique>("Techniques/Diff.xml"));
		}
		material->SetTexture(TU_DIFFUSE, atlas_cache->texture);
		cg->SetMaterial(cg_i, material);
		cg_i++;
	}

	cg->Commit();
}

// Set custom geometry from voxel volume, using a voxel registry
// Volume should be padded by one voxel on each edge
void set_voxel_lod_geometry(int lod, CustomGeometry *cg, Context *context,
		VoxelVolume &volume_orig,
		VoxelRegistry *voxel_reg, AtlasRegistry *atlas_reg,
		bool use_skylight)
{
	up_<VoxelVolume> lod_volume = generate_voxel_lod_volume(
			lod, volume_orig, voxel_reg);

	preload_textures(*lod_volume, voxel_reg, atlas_reg, true);

	sm_<uint, TemporaryGeometry> temp_geoms;
	generate_voxel_lod_geometry(
			lod, temp_geoms, *lod_volume, voxel_reg, atlas_reg, use_skylight);

	set_voxel_lod_geometry(lod, cg, context, temp_geoms, atlas_reg);
}

void generate_voxel_physics_boxes(
		sv_<TemporaryBox> &result_boxes,
		VoxelVolume &volume_orig,
		VoxelRegistry *voxel_reg)
{
	const VoxelFmt fmt(voxel_reg);
	int w = volume_orig.getWidth() - 2;
	int h = volume_orig.getHeight() - 2;
	int d = volume_orig.getDepth() - 2;

	auto region = volume_orig.getEnclosingRegion();
	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();

	// Create a new volume which only holds the solidity of the voxels.
	//
	// The padding is left out of it. A chunk volume carries one voxel of its
	// neighbours on each side so that faces can be culled against them, but
	// collision is not like drawing: the neighbour has its own body covering
	// those voxels, so including them gives every chunk boundary two
	// overlapping sets of boxes -- which is what Bullet's "static-static
	// collision" warning is about.
	//
	// The part that matters more: with the padding in, a chunk's box list
	// changes whenever a *neighbour* changes, so the collision is rebuilt
	// over and over while a world loads, and each rebuild takes the body out
	// of the physics world for a frame or more. Without it, the list depends
	// only on the chunk's own voxels and a neighbour arriving changes
	// nothing.
	pv::RawVolume<uint8_t> volume(region);
	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				if(x == lc.getX() || x == uc.getX() ||
						y == lc.getY() || y == uc.getY() ||
						z == lc.getZ() || z == uc.getZ()){
					volume.setVoxelAt(x, y, z, 0);
					continue;
				}
				VoxelSample v_orig = volume_orig.sample_at(x, y, z);
				const interface::CachedVoxelDefinition *def =
						voxel_reg->get_cached(v_orig);
				if(!def){
					throw Exception(ss_()+"Undefined voxel: "+
							itos(fmt.id_of(v_orig)));
				}
				uint8_t v = (def && def->physically_solid);
				volume.setVoxelAt(x, y, z, v);
			}
		}
	}

	// Create minimal number of boxes to fill the solid voxels. Boxes can
	// overlap. When a box is added, its voxels are set to value 2 in the
	// temporary volume.

	for(int z0 = lc.getZ(); z0 <= uc.getZ(); z0++){
		// Loop until this z0 plane is done, then handle the next one. The
		// search goes on from where it found the last voxel: a voxel only
		// ever goes from 1 to 2, so nothing before that is 1 any more, and
		// starting over at the plane's corner for every box was the most
		// of a chunk's cost on a VoxeLibre server ([VOXEL_PHYSICS_LAG])
		int sx = lc.getX(), sy = lc.getY();
		for(;;){
			// Find a solid non-covered voxel (v=1) on the z0 plane
			int x0 = INT_MAX;
			int y0 = INT_MAX;
			for(int x = sx; x <= uc.getX(); x++){
				for(int y = (x == sx ? sy : lc.getY()); y <= uc.getY(); y++){
					uint8_t v = volume.getVoxelAt(x, y, z0);
					if(v == 1){
						x0 = x;
						y0 = y;
						goto found_non_covered_voxel;
					}
				}
			}
			break; // Done
		found_non_covered_voxel:
			sx = x0;
			sy = y0;
			// Stretch this box first in x, then y and then z to be as large as
			// possible without covering any non-solid voxels
			int x1 = x0;
			int y1 = y0;
			int z1 = z0;
			for(;;){
				x1++;
				// getVoxelAt() past the region reads outside the volume's
				// data, so the plane loops below would happily accept
				// whatever is in that memory and stretch the box out of the
				// world. Stop at the region instead.
				if(x1 > uc.getX())
					goto x_plane_does_not_fit;
				for(int y = y0; y <= y1; y++){
					for(int z = z0; z <= z1; z++){
						uint8_t v = volume.getVoxelAt(x1, y, z);
						if(v == 0)
							goto x_plane_does_not_fit;
					}
				}
				continue; // Fits
			x_plane_does_not_fit:
				x1--;
				break;
			}
			for(;;){
				y1++;
				if(y1 > uc.getY())
					goto y_plane_does_not_fit;
				for(int x = x0; x <= x1; x++){
					for(int z = z0; z <= z1; z++){
						uint8_t v = volume.getVoxelAt(x, y1, z);
						if(v == 0)
							goto y_plane_does_not_fit;
					}
				}
				continue; // Fits
			y_plane_does_not_fit:
				y1--;
				break;
			}
			for(;;){
				z1++;
				if(z1 > uc.getZ())
					goto z_plane_does_not_fit;
				for(int x = x0; x <= x1; x++){
					for(int y = y0; y <= y1; y++){
						uint8_t v = volume.getVoxelAt(x, y, z1);
						if(v == 0)
							goto z_plane_does_not_fit;
					}
				}
				continue; // Fits
			z_plane_does_not_fit:
				z1--;
				break;
			}
			// Now we have a box; set the voxels to 2
			for(int x = x0; x <= x1; x++){
				for(int y = y0; y <= y1; y++){
					for(int z = z0; z <= z1; z++){
						volume.setVoxelAt(x, y, z, 2);
					}
				}
			}
			// Store the box in results
			TemporaryBox box;
			box.size = Vector3(
					x1 - x0 + 1,
					y1 - y0 + 1,
					z1 - z0 + 1
			);
			box.position = Vector3(
					(x0 + x1)/2.0f - w/2 + 0.5f,
					(y0 + y1)/2.0f - h/2 + 0.5f,
					(z0 + z1)/2.0f - d/2 + 0.5f
			);
			result_boxes.push_back(box);
		}
	}
}

void set_voxel_physics_boxes(Node *node, Context *context,
		const sv_<TemporaryBox> &boxes, bool do_update_mass)
{
	// Get previous shapes
	PODVector<CollisionShape*> previous_shapes;
	node->GetComponents<CollisionShape>(previous_shapes);
	// Number of previous shapes reused
	// (they are reused because deleting them is very expensive)
	size_t num_shapes_reused = 0;

	// Do this. Otherwise modifying CollisionShapes causes a massive CPU waste
	// when they call RigidBody::UpdateMass().
	RigidBody *body = node->GetComponent<RigidBody>();
	if(body)
		body->ReleaseBody();

	// Create the boxes (reuse previous shapes if possible)
	for(auto &box : boxes){
		CollisionShape *shape = nullptr;
		if(num_shapes_reused < previous_shapes.Size())
			shape = previous_shapes[num_shapes_reused++];
		else
			shape = node->CreateComponent<CollisionShape>(LOCAL);
		shape->SetBox(box.size);
		shape->SetPosition(box.position);
	}

	// Remove excess shapes
	for(size_t i = num_shapes_reused; i < previous_shapes.Size(); i++){
		node->RemoveComponent(previous_shapes[i]);
	}

	if(body && do_update_mass){
		// Call this to cause the private AddBodyToWorld() to be called, which
		// re-creates the internal btRigidBody and also calls UpdateMass()
		body->OnSetEnabled();
	}
}

void set_voxel_physics_boxes(Node *node, Context *context,
		VoxelVolume &volume,
		VoxelRegistry *voxel_reg)
{
	sv_<TemporaryBox> result_boxes;
	generate_voxel_physics_boxes(result_boxes, volume, voxel_reg);

	set_voxel_physics_boxes(node, context, result_boxes, true);
}

} // namespace mesh
} // namespace interface
// vim: set noet ts=4 sw=4:
