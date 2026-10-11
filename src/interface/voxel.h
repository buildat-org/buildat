// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/atlas.h"
#include <PolyVoxCore/Vector.h>

namespace interface
{
	namespace pv = PolyVox;

	typedef uint32_t VoxelTypeId;
	static constexpr VoxelTypeId VOXELTYPEID_MAX = 1398101-1;
	static constexpr VoxelTypeId VOXELTYPEID_UNDEFINED = 0;

	struct VoxelName
	{
		ss_ block_name; // Name of the block this was instanced from
		uint8_t segment_x = 0; // Which segment of the block this was instanced from
		uint8_t segment_y = 0;
		uint8_t segment_z = 0;
		// 4 possible rotations when looking at a face
		uint8_t rotation_primary = 0;
		// 6 possible directions for a face to point to
		uint8_t rotation_secondary = 0;

		ss_ dump() const;
		bool operator==(const VoxelName &other) const;
	};

	enum class FaceDrawType {
		NEVER = 0,
		ALWAYS = 1,
		ON_EDGE = 2,
	};

	// A thing that allows distinguishing which voxel faces generate edges
	typedef uint8_t EdgeMaterialId;
	static constexpr EdgeMaterialId EDGEMATERIALID_EMPTY = 0;
	static constexpr EdgeMaterialId EDGEMATERIALID_GROUND = 1;
	// Values at and above 10 are freely usable.

	// One quad of a shape a voxel has instead of being a cube.
	//
	// The corners are in the voxel's own cube, which runs -0.5...0.5 on each
	// axis, wound so that the quad faces the way its winding says. The
	// texture coordinates are in the tile's own 0...1, with 0,0 at its top
	// left, and the mesher maps them into wherever the atlas put that tile.
	// tile is which of the voxel's six textures this quad wears.
	//
	// This is deliberately not a box, a mesh name or anything else with a
	// shape of its own: a game that wants stairs, fences, plants, rails or a
	// pane of glass builds the quads it wants and the mesher copies them.
	struct VoxelQuad
	{
		float p[4][3] = {};
		float uv[4][2] = {};
		uint8_t tile = 0;
		// When this quad is drawn at all:
		//   0     always
		//   1...6 only when the neighbour in that direction connects, the
		//         faces in their usual order, so 1 is +Y and 6 is -Z
		//   7     only when none of the six connects
		// What wants it is a fence, which is a post plus a rail per
		// direction that has something to reach, and a pane, which is a
		// short post when it stands alone. See connect_group below for what
		// "connects" means.
		uint8_t connect_dir = 0;
	};

	// What a voxel's param changes about how it is drawn.
	//
	// The engine hands a definition the param and the definition answers with
	// one of these; what the param *means* is the game's business, and the
	// engine's job stops at "look it up and draw that". This is what keeps a
	// voxel that faces one of twenty-four directions, or wears one of eight
	// palette colours, from needing a voxel type of its own for every case.
	//
	// A variant permutes the definition's own textures -- tile_order[f] is
	// which of them face f wears -- because a turned cube wears the same
	// textures as an unturned one, in a different order. It can also name
	// textures of its own, which is what a palette needs; see
	// VoxelVariant::textures.
	struct VoxelVariant
	{
		// Quads of the voxel's own instead of the definition's; empty for
		// the definition's own shape. See VoxelDefinition::shape.
		sv_<VoxelQuad> shape;
		uint8_t tile_order[6] = {0, 1, 2, 3, 4, 5};
		uint8_t tile_turns[6] = {};
		// Textures of the variant's own, indexed the way a tile is
		// everywhere else: 0...5 are the voxel's six faces and 6 and over
		// are the definition's extra_textures. As many as the variant
		// replaces and no more; empty for a variant that only turns, which
		// is most of them, and an empty vector costs nothing.
		//
		// What wants them is a palette. A voxel that wears the colour its
		// param names wears its own tiles through a modifier that
		// multiplies them, and the colour is albedo rather than light, so
		// it cannot be the vertex colour below. The atlas then grows with
		// distinct tiles times palette entries and not with directions,
		// because directions permute what a variant names and colours
		// multiply it: eight colours of a facedir node are 192 variants and
		// 48 textures.
		sv_<AtlasSegmentDefinition> textures;
		// The same, resolved into the atlas. Filled by the registry when it
		// builds the cached definition, and empty in a definition a game
		// hands over.
		sv_<AtlasSegmentReference> texture_refs;
		// Multiplied into the vertex colour, 0xRRGGBB.
		//
		// The vertex colour is light, not albedo -- the mesher packs it as
		// interface/mesh.h says -- so this tints the light a voxel receives
		// and *not* its texture. What that is right for is a voxel that
		// glows or sits in coloured shade. What it is not right for is a
		// palette: a palette multiplies the texture, and the sky's own
		// contribution to the lighting is a scalar here and cannot be
		// tinted, so a palette entry would show in shade and vanish in
		// sunlight. An albedo tint wants a channel of its own; see
		// doc/plan/voxel_data_model_plan.md.
		uint32_t color = 0xffffff;
		// Where a liquid's surface stands in the voxel; see
		// VoxelDefinition::liquid_top. Luanti's flowing liquids put their
		// level in param2.
		float liquid_top = 0.5f;
		// What stops the player, as VoxelDefinition::collision_boxes; empty
		// for the definition's own
		sv_<float> collision_boxes;
		// What is pointed at, as VoxelDefinition::selection_boxes; empty
		// for the definition's own
		sv_<float> selection_boxes;
	};

	struct VoxelDefinition
	{
		VoxelName name;
		VoxelTypeId id = VOXELTYPEID_UNDEFINED;
		// Textures (voxels have 6 sides)
		// These must be definitions (not references) because each client has to
		// be able to construct their atlases from different texture sizes
		AtlasSegmentDefinition textures[6];
		// Textures a quad of the voxel's own shape can wear instead of one
		// of the six. A quad's tile is 0...5 for a face texture and 6 and
		// over for one of these, so a shape that is more than one thing --
		// a plant standing in a cube of ground, wearing the ground's
		// texture and its own -- has somewhere to put the rest of them.
		//
		// Empty for nearly every voxel, and an empty vector costs nothing;
		// the six stay an array so that the cube mesher's inner loop is
		// unchanged and pays no indirection.
		sv_<AtlasSegmentDefinition> extra_textures;
		// Quarter turns anticlockwise to give each face's texture inside the
		// face, 0...3. What wants this is a voxel that faces a direction: the
		// texture of the top of a turned cube is turned with it, and the same
		// texture is shared with the cube that is not turned, so the turn
		// belongs to the face rather than to the atlas segment.
		uint8_t tile_turns[6] = {};
		// **How many voxels a texture spans before it repeats** ([WORLD_UV]).
		// A voxel face repeats its texture once per voxel, so a feature
		// larger than one voxel cannot exist and a big surface reads as a
		// grid of identical stamps. At 1 -- which is every voxel that says
		// nothing -- nothing changes. Above it, a face takes its own slice
		// of the repeat from where the voxel is in the world, and the
		// neighbour continues the sequence.
		//
		// It costs nothing in the atlas: the wrap falls on a voxel boundary
		// and never inside a quad, so a face's coordinates stay inside its
		// own segment rect.
		uint8_t uv_scale = 1;
		// **How many voxels it spans upwards**, where uv_scale is across
		// ([SIGIL_ROUND], 2026-09-24: a frieze that runs along a wall is
		// eight voxels across and one tall, and one number for both axes
		// made a slab's edge show one eighth of the texture's height,
		// chosen by where the slab sat in the world). Nought means "the
		// same as uv_scale", which is every definition written before
		// this and the square case.
		uint8_t uv_scale_v = 0;
		// Other properties
		ss_ handler_module;
		FaceDrawType face_draw_type = FaceDrawType::ON_EDGE;
		EdgeMaterialId edge_material_id = EDGEMATERIALID_EMPTY;
		bool physically_solid = false;
		// Nothing whatsoever occupies this voxel: it is air, or something
		// that behaves as air and only differs in what the game makes of it.
		//
		// This is not the same as EDGEMATERIALID_EMPTY, which only says that
		// the cube faces against this voxel are not drawn; a voxel can do
		// that and still hold a mesh of its own shape inside itself. What
		// wants to know whether a voxel is free is this flag.
		bool fully_empty = false;
		// Light passes through this voxel although it is something. A voxel
		// whose edge material is EDGEMATERIALID_EMPTY already transmits
		// light -- nothing is there -- and this is the other case: glass, a
		// pane, a plant, anything the sky is seen through and which is still
		// drawn.
		//
		// It exists because the edge material is one test doing two jobs:
		// whether a face is drawn against this voxel, and whether light gets
		// past it. Luanti splits them -- a glasslike node has faces and
		// sunlight_propagates -- and this is that split, added rather than
		// substituted so that a game that says nothing keeps the behaviour
		// it had.
		bool transmits_light = false;
		// How much light this voxel emits of its own, 0...15, for a world
		// that maintains lamp light: a torch, a lava flow, a glowing
		// mushroom. 0 for nearly everything.
		//
		// Only a world whose format binds light_lamp *and* asks for it to
		// be maintained reads this; see set_light_maintained() in
		// voxelworld/api.h. A game whose lamps are lights in the scene
		// leaves it at zero and the shader does that work instead.
		//
		// Not serialized: the client does not need it -- what it draws is
		// the light already stored in each voxel -- and keeping it off the
		// wire means a save written before it existed still reads.
		uint8_t light_source = 0;
		// A shape of the voxel's own instead of a cube. Empty for a cube,
		// which is what most voxels are and the fast path the voxel mesher
		// exists for; a voxel with quads has them copied into the chunk's
		// mesh, which costs about what its own faces would have.
		//
		// A voxel with a shape usually wants face_draw_type NEVER and
		// edge_material_id EMPTY as well: the cube faces it would otherwise
		// have are not what it looks like, and its neighbours should draw
		// their faces against it.
		sv_<VoxelQuad> shape;
		// Draw the shape's quads from both sides. What wants it is a shape
		// made of single quads -- a plant, a rail, a sign -- which is
		// otherwise invisible from behind. A shape made of boxes does not.
		bool shape_double_sided = false;
		// The shape fills its own voxel and stands in the one above it: a
		// rooted plant, whose cube is the ground and whose plant is drawn
		// into the space over it. A shaped voxel is otherwise lit by its own
		// light, which for a voxel that is solid ground is not the light
		// anything on it is under; this takes the light of the voxel above
		// for the whole shape instead.
		bool shape_lit_from_above = false;
		// The voxel's faces are alpha blended rather than opaque or alpha
		// masked, so they belong in a pass drawn after the solid world and
		// back to front: water, and glass a game gave an alpha to. The
		// mesher puts them in a geometry of their own; what technique that
		// gets is the game's business, as with the rest of the materials.
		bool translucent = false;
		// The voxel's faces are opaque where its texture is and not there at
		// all where it is not: leaves, a plant, a ladder, anything whose
		// picture has holes in it. It is drawn with the solid world -- depth
		// and shadows and no sorting -- with the texture's alpha cutting the
		// holes out, which is what Luanti's use_texture_alpha = "clip"
		// means and what an alpha-masked technique does.
		//
		// The mesher puts these faces in a geometry of their own as well,
		// for the same reason the translucent ones get one: a material is
		// per drawable, so a pass of its own needs a drawable of its own.
		// Everything else about them is the opaque rules -- a face against
		// one of these is hidden exactly as it would be against a solid
		// voxel, which is what Luanti does too.
		bool alpha_masked = false;
		// Which family of shapes this voxel's shape belongs to, or 0 for
		// none. A shape's quad is not drawn when the neighbour it faces has
		// the same group: that is what keeps the faces inside a body of water
		// out of the mesh, where the cube case has edge_material_id for the
		// same job. Water and lava are different groups, so the face between
		// them is drawn.
		//
		// Only an axis-aligned quad on the voxel's own boundary is tested;
		// the neighbour looked at is the one the quad's normal points into.
		uint8_t shape_group = 0;
		// A liquid, and where its surface stands inside the voxel:
		// -0.5...0.5, which is 0.5 for a liquid drawn as a full cube. Two
		// liquid voxels are the same liquid when their shape_group matches.
		//
		// A liquid that has a shape gets the top corners of that shape moved
		// to the average of the surfaces around each corner, so that a
		// sloping surface is continuous rather than stepped. That is Luanti's
		// getCornerLevel, and it is the one thing here the mesher works out
		// per voxel instead of per definition.
		bool is_liquid = false;
		// Whether this is the liquid's source rather than one of its
		// flowing levels ([WATER_LIGHT] 3). Luanti's getCornerLevel()
		// answers a corner that any source touches with the full height of
		// the voxel, without averaging: a shore where a flow meets a pool
		// stands level with the pool, it does not sag into the flow.
		bool liquid_is_source = false;
		float liquid_top = 0.5f;
		// A ladder, a vine, a rope: something a player holds on to instead
		// of falling past. Luanti's own climbable, and the client's physics
		// is what does anything with it -- nothing here draws differently
		// for it.
		bool climbable = false;
		// What stops a player in a physically solid voxel when it is not
		// the whole cube, a stair or a slab: boxes of six numbers each, x0
		// y0 z0 x1 y1 z1 in the voxel's own -0.5...0.5. Empty is the cube.
		// A variant can have its own; see VoxelVariant. Only the client's
		// physics reads it ([VL_STAIRS]).
		sv_<float> collision_boxes;
		// What a pointing ray stops at and the frame is drawn round, the
		// same way; empty is the cube ([VL_RAIL_BOXES])
		sv_<float> selection_boxes;
		// How much this voxel holds a body back, 0 for not at all. Luanti's
		// own move_resistance, which defaults to liquid_viscosity: water is
		// 1 and lava is 7, and a game can put it on anything. The client's
		// physics is the only thing that reads it.
		uint8_t move_resistance = 0;
		// What the node stood on does to a player, Luanti's node groups of
		// the same names ([PLAYER_PHYSICS]): the bouncy rating, the
		// slippery rating, and whether jumping or descending is refused.
		// The client's physics is the only reader.
		uint8_t bouncy = 0;
		uint8_t slippery = 0;
		bool disable_jump = false;
		bool disable_descend = false;
		// What a player is in when standing in this: Luanti's
		// liquid_move_physics, which defaults to "it is a liquid" and a
		// game may set either way -- a swimmable non-liquid, a liquid
		// walked through ([WATER_PARITY]). is_liquid stays the drawing.
		bool swimmable = false;
		// Whether a ray stops here: Luanti's pointable -- 1 true, 0 false
		// (the ray goes through: water in most games, decor), 2 "blocking"
		// (the ray stops with nothing pointed). Objects carry the same
		// field on their own ([POINTABLE]).
		uint8_t pointable = 1;
		// Which family of connecting voxels this one belongs to, 1...32, or
		// 0 for one nothing reaches out to; and which families this one
		// reaches out to, as a bit per family. A fence and its gates are one
		// family, a wall another, panes and bars a third.
		//
		// The mesher looks at the six neighbours of a voxel whose shape has
		// quads with a connect_dir and draws each of those quads only when
		// its own direction connects. The cost of that is the same whatever
		// the families are, and the mask is where the two ends meet: the
		// game works out the families once, from whatever its own rules are,
		// and the mesher only tests a bit.
		uint8_t connect_group = 0;
		uint32_t connect_mask = 0;
		// A whole shape per neighbour mask, for a voxel that does not gain a
		// piece per direction but changes altogether: a rail, which is one
		// quad wearing one of four tiles turned one of four ways. When this
		// is not empty it is used instead of `shape`.
		//
		// Masks 0...15 are the four horizontal connections, in Luanti's own
		// bit order for them: +Z is 1, -Z is 2, -X is 4 and +X is 8. Masks
		// 16...19 are for a voxel that has one of itself a step up in that
		// direction -- +Z, -Z, -X, +X in that order -- which is what a rail
		// climbing a slope is; they win over the flat ones.
		//
		// The quads of mask m are shape_masked[begin[m]...begin[m + 1] - 1],
		// which is one vector and twenty-one offsets rather than twenty
		// vectors: this struct is read by the mesher a definition at a time
		// and wants to stay in cache.
		sv_<VoxelQuad> shape_masked;
		uint16_t shape_masked_begin[21] = {};
		// Also connect to any neighbour that is solid, whatever family it is
		// in. Luanti's connect_sides, which is how a fence reaches into the
		// stone next to it.
		//
		// simplified: Luanti says which of the six sides may be reached that
		// way and this is all of them.
		bool connect_to_solid = false;
		// What the voxel's param does to how it is drawn, if anything. Empty
		// means the param is ignored here, which is the common case and the
		// one the mesher hoists out of its inner loop.
		//
		// variant_of_param maps a param value to an entry of variants, so
		// that the twenty-four turns of a facedir are twenty-four variants
		// behind two hundred and fifty-six bytes of index rather than two
		// hundred and fifty-six variants. Only a param up to 8 bits wide is
		// looked up this way; a wider one is storage for the game to read
		// itself, not something the mesher indexes.
		sv_<VoxelVariant> variants;
		uint8_t variant_of_param[256] = {};
		// The two ends of the colour the tint modifier moves between, each
		// 0xRRGGBB: tint 0 is the first and a full tint is the second. The
		// colour multiplies the texture, and the shader is what applies it;
		// see VoxelFormat::tint.
		//
		// This is a ramp rather than a per-voxel colour because a colour
		// would eat three of the four scalars that reach the shader, and one
		// scalar along a ramp the definition holds covers a palette, wet
		// dirt darkening and a mixture's own colour alike. A definition that
		// leaves both ends white is not tinted whatever the field says.
		//
		// As with VoxelVariant::color the vertex colour is light rather than
		// albedo, so this tints the light the voxel receives.
		uint32_t tint_ramp[2] = {0xffffff, 0xffffff};
		// How far a full-value sag modifier moves a face, in voxels. 0 for a
		// voxel that does not sag, which is most of them.
		//
		// What the sag itself means is the game's: a liquid's surface
		// standing partway down its voxel, a floor giving under a load,
		// snow lying shallow. The mesher only moves the face and averages
		// the sag of the voxels that meet at each corner, so that a sagging
		// surface runs continuously instead of stepping.
		float sag_extent = 0.0f;
		// TODO: Flag for whether all faces should be always drawn (in case the
		//       textures contain holes)
	};

	static constexpr size_t VOXELDEF_NUM_LOD = 3;

	// This definition should be as small as practical so that large portions of
	// the definition array can fit in CPU cache
	// (the absolute maximum number of these is VOXELTYPEID_MAX+1)
	struct CachedVoxelDefinition
	{
		bool valid = false;
		ss_ handler_module;
		FaceDrawType face_draw_type = FaceDrawType::ON_EDGE;
		EdgeMaterialId edge_material_id = EDGEMATERIALID_EMPTY;
		bool physically_solid = false;
		bool fully_empty = false;
		// Copied from the definition; see VoxelDefinition::transmits_light
		bool transmits_light = false;
		// Copied from the definition; see VoxelDefinition::light_source
		uint8_t light_source = 0;
		// Copied from the definition; see VoxelDefinition::shape
		sv_<VoxelQuad> shape;
		bool shape_double_sided = false;
		bool shape_lit_from_above = false;
		bool translucent = false;
		// Copied from the definition; see VoxelDefinition::alpha_masked
		bool alpha_masked = false;
		uint8_t shape_group = 0;
		// [WORLD_UV]; see VoxelDefinition::uv_scale
		uint8_t uv_scale = 1;
		// [SIGIL_ROUND]; see VoxelDefinition::uv_scale_v. Nought is "the
		// same as uv_scale"
		uint8_t uv_scale_v = 0;
		bool is_liquid = false;
		// Copied from the definition; see VoxelDefinition::liquid_is_source
		bool liquid_is_source = false;
		float liquid_top = 0.5f;
		// Copied from the definition; see VoxelDefinition::climbable
		bool climbable = false;
		// Copied from the definition; see VoxelDefinition::move_resistance
		uint8_t move_resistance = 0;
		// Copied from the definition; see VoxelDefinition::swimmable
		bool swimmable = false;
		// Copied from the definition; see VoxelDefinition::pointable
		uint8_t pointable = 1;
		uint8_t connect_group = 0;
		uint32_t connect_mask = 0;
		bool connect_to_solid = false;
		// Copied from the definition; see VoxelDefinition::shape_masked
		sv_<VoxelQuad> shape_masked;
		uint16_t shape_masked_begin[21] = {};
		// Copied from the definition; see VoxelDefinition::variants
		sv_<VoxelVariant> variants;
		uint8_t variant_of_param[256] = {};
		// Copied from the definition
		uint32_t tint_ramp[2] = {0xffffff, 0xffffff};
		float sag_extent = 0.0f;

		uint8_t tile_turns[6] = {};

		// What a param value says about drawing this voxel, or nullptr when
		// the param changes nothing about it
		const VoxelVariant* variant(uint32_t param) const {
			if(variants.empty())
				return nullptr;
			size_t i = variant_of_param[param & 0xff];
			return i < variants.size() ? &variants[i] : nullptr;
		}

		bool textures_valid = false;
		AtlasSegmentReference textures[6];
		// See VoxelDefinition::extra_textures. Built with the six, and
		// there are no LOD segments for them: a LOD mesh draws cubes.
		sv_<AtlasSegmentReference> extra_textures;
		// The LOD segments are only built for a volume that is actually
		// meshed at a LOD: building one is a texture loaded, scaled and drawn
		// into an atlas, and there are VOXELDEF_NUM_LOD of them per face
		bool lod_textures_valid = false;
		AtlasSegmentReference lod_textures[VOXELDEF_NUM_LOD][6];
	};

	// The most planes a format can have. Small on purpose: a voxel's planes
	// are read together into a VoxelSample, which is on the stack of every
	// loop that asks a question of a voxel, and a world with eight fields
	// that do not fit in one word each is not the shape this is for.
	static constexpr size_t VOXEL_MAX_PLANES = 8;

	// One array over a chunk, holding the same bits of every voxel in it.
	// bits is 8, 16 or 32; name is empty for the game's own first plane and
	// is what a module's own field is found by.
	struct VoxelPlane
	{
		ss_ name;
		uint8_t bits = 32;

		VoxelPlane(){}
		VoxelPlane(const ss_ &name, uint8_t bits): name(name), bits(bits){}

		bool operator==(const VoxelPlane &o) const {
			return name == o.name && bits == o.bits;
		}
	};

	// One voxel's planes, read together. What a loop that asks several
	// questions of one voxel works from: the planes are separate arrays, so
	// reading one field at a time from a volume is several indexings where
	// this is one.
	struct VoxelSample
	{
		uint32_t planes[VOXEL_MAX_PLANES] = {};
	};

	// Where one of the engine's roles lives inside a voxel.
	//
	// width 0 means the role is not bound at all, which is not the same as a
	// role that is always zero: a world with no light bound is not a dark
	// world, it is one where nothing asks about light.
	struct VoxelField
	{
		uint8_t plane = 0;
		uint8_t shift = 0;
		uint8_t width = 0;

		// Not an aggregate: the members have initializers and this is C++11
		VoxelField(){}
		VoxelField(uint8_t plane, uint8_t shift, uint8_t width):
			plane(plane), shift(shift), width(width){}

		bool bound() const { return width != 0; }

		uint32_t mask() const {
			return width >= 32 ? 0xffffffffUL : ((1UL << width) - 1);
		}

		uint32_t get(uint32_t word) const {
			return (word >> shift) & mask();
		}

		// The same, out of a voxel's whole set of planes
		uint32_t get(const VoxelSample &v) const {
			return get(v.planes[plane]);
		}

		void set(VoxelSample &v, uint32_t value) const {
			set(v.planes[plane], value);
		}

		void set(uint32_t &word, uint32_t value) const {
			uint32_t m = mask() << shift;
			word = (word & ~m) | ((value << shift) & m);
		}

		bool operator==(const VoxelField &o) const {
			return plane == o.plane && shift == o.shift && width == o.width;
		}
	};

	// How many surface modifiers reach the shader at once; see VoxelFormat.
	// Four, because that is what fits in the one thing a voxel vertex has
	// spare -- CustomGeometryVertex's tangent, which the voxel mesher has
	// never written and an axis-aligned face does not need.
	static constexpr size_t VOXEL_SURFACE_MODIFIERS = 4;

	// How a game cuts up a voxel: which bits are the type id, which are
	// light, which are a parameter the definitions interpret, which are a
	// colour, and what is left over for the game's own use.
	//
	// A format belongs to a VoxelRegistry, is set before the first voxel is
	// added to it and never after, and travels to clients with it. So a
	// volume plus its world's registry is self-describing, and nothing that
	// takes a volume needs to take a format as well.
	//
	// The default is legacy(), which is the cut the engine had before this
	// existed, bit for bit. A game that says nothing keeps it.
	struct VoxelFormat
	{
		VoxelField id;
		// What use_skylight reads. A game binds the light it actually
		// fills and no more.
		//
		// light_lamp is for a world that computes the light a voxel gets
		// from something other than the sky and stores it per voxel, which
		// is what a Luanti server does and sends to its clients. A game
		// whose lamps are lights in the scene does not want it: the shader
		// lights the geometry from those, nothing writes the field, and
		// binding it spends bits on zeroes. Of the games in this tree only
		// the Luanti client binds it.
		VoxelField light_sky;
		VoxelField light_lamp;
		// What a definition's own rule interprets: which way a voxel faces,
		// how high a liquid stands in it, which entry of a palette it wears.
		// The engine hands it to the definition and the definition says what
		// it means; see VoxelDefinition::variants.
		VoxelField param;
		// A colour multiplied into the vertex colour: 0xRRGGBB in the low 24
		// bits of a field 24 or 32 bits wide. What wants it is a game whose
		// voxels are colours rather than types.
		//
		// As with VoxelVariant::color, the vertex colour is light rather
		// than albedo, so this tints the light a voxel receives and not its
		// texture. For a game whose voxels are unlit colour that is the same
		// thing; for one that wants a palette over a texture it is not. See
		// doc/plan/voxel_data_model_plan.md.
		VoxelField color;

		// Modifiers: fields the mesher reads to change how a voxel is drawn
		// without a definition of its own. Where a role above says what a
		// voxel *is*, a modifier says how much of something it has, as a
		// value the mesher normalises against the field's own width -- so a
		// 4-bit field and an 8-bit one both run 0...1 and a game can widen
		// one without touching its shader.
		//
		// The surface modifiers are the first four bound of tint, wetness,
		// grain, gloss, speckle and emission, in that order. They reach the
		// shader as four numbers in a slot of the vertex and nowhere else:
		// the engine promises the four and their order, and what they look
		// like is the game's shader's business.
		//
		// Three of them are scalars. The tint is the exception: it is an
		// albedo tint, so what its slot carries is the colour the field
		// picked out of the definition's tint_ramp, packed 5-6-5. It has to
		// be albedo and it has to go this way round, because the vertex
		// colour is light -- a tint of the light shows in shade and vanishes
		// in sunlight, which is not what tinting a material means.
		//
		// The order being fixed rather than the order they were bound in is
		// what makes the slots the same in two worlds that bind the same
		// roles, and what keeps a Lua table's iteration order out of a
		// shader contract.
		VoxelField tint;
		VoxelField wetness;
		VoxelField grain;
		VoxelField gloss;
		VoxelField speckle;
		VoxelField emission;
		// The geometry modifiers: how far the top and the bottom faces of a
		// voxel move into it, scaled by the definition's sag_extent. These
		// are not carried to the shader -- they move vertices, which is
		// something the mesher has to do because a corner is shared by four
		// voxels and only the mesher can see all four.
		VoxelField sag_top;
		VoxelField sag_bottom;

		// What the voxel's bits are stored in. A plane is one array over a
		// whole chunk, holding the same bits of every voxel in it -- so a
		// world's voxels are several arrays and not one array of words,
		// which is what lets a chunk hold a field only once something
		// writes it, lets a simulation sweep a field without a call per
		// voxel, and lets a field be added without asking the game for room
		// in a word it has already spent.
		//
		// A format has one 32-bit plane unless it says otherwise, which is
		// every game in this tree and is the same bits in the same order as
		// before planes existed.
		//
		// A named plane is one a module asked for by name; the first is the
		// game's own and has no name.
		sv_<VoxelPlane> planes = {VoxelPlane()};

		// How wide plane p is, and how many there are
		uint8_t plane_bits(uint8_t plane = 0) const {
			return plane < planes.size() ? planes[plane].bits : 0;
		}
		size_t plane_count() const { return planes.size(); }
		// Which plane has this name, or -1
		int plane_of_name(const ss_ &name) const {
			for(size_t i = 0; i < planes.size(); i++){
				if(planes[i].name == name)
					return (int)i;
			}
			return -1;
		}

		// Every engine role in one list, for code that has to treat them
		// all the same way rather than by name. What wants it is a
		// migration moving a saved chunk from the cut it was written in to
		// the cut the game is running now; nothing else has needed it.
		//
		// The name is what a warning calls the role by. The order is the
		// declaration order above and is not part of any format -- nothing
		// is stored by it.
		struct Role
		{
			const char *name;
			VoxelField VoxelFormat::*field;
		};
		static const sv_<Role>& roles();

		static VoxelFormat legacy()
		{
			VoxelFormat f;
			f.id = VoxelField{0, 0, 21};
			f.light_sky = VoxelField{0, 24, 4};
			f.light_lamp = VoxelField{0, 28, 4};
			return f;
		}

		// Luanti's own cut, which fits the same word exactly: a 16-bit node
		// id, param1 as two light nibbles, and param2.
		static VoxelFormat luanti()
		{
			VoxelFormat f;
			f.id = VoxelField{0, 0, 16};
			f.light_sky = VoxelField{0, 16, 4};
			f.light_lamp = VoxelField{0, 20, 4};
			f.param = VoxelField{0, 24, 8};
			return f;
		}

		// The type id of a voxel. A format with no id bound has exactly one
		// voxel type -- what wants that is a painter, whose voxels are all
		// the same kind of thing wearing a colour -- and it is type 1 rather
		// than 0 because 0 is VOXELTYPEID_UNDEFINED, which means "nothing
		// has generated this yet".
		VoxelTypeId id_of(uint32_t word) const {
			return id.bound() ? (VoxelTypeId)id.get(word) : 1;
		}

		// Both light roles as one field, for a caller that writes them
		// together (pack_voxel_volume's "light"). Only when they are
		// adjacent in the same plane with the sky light in the low bits,
		// which is the only arrangement that can be one write.
		bool light_pair(VoxelField *out) const;

		// The bound surface modifiers in role order, which is the order a
		// shader sees them in. Fills out[] with them and returns how many;
		// the rest are left unbound.
		size_t surface_modifiers(VoxelField out[VOXEL_SURFACE_MODIFIERS]) const;

		bool any_surface_modifier() const {
			VoxelField slots[VOXEL_SURFACE_MODIFIERS];
			return surface_modifiers(slots) != 0;
		}

		// The same cut: the same planes, and every role in the same place.
		// What asks is a save, deciding whether the chunks it holds are in
		// the format the world is running now.
		bool operator==(const VoxelFormat &o) const {
			if(planes != o.planes)
				return false;
			for(const Role &r : roles()){
				if(!(this->*(r.field) == o.*(r.field)))
					return false;
			}
			return true;
		}
		bool operator!=(const VoxelFormat &o) const { return !(*this == o); }

		// Every bound field is inside its plane, no two overlap, and the id
		// fits VOXELTYPEID_MAX. why, when given, gets the first reason it
		// did not.
		bool validate(ss_ *why = nullptr) const;

		ss_ dump() const;
	};

	// Asserts the invariants of VoxelField and VoxelFormat: the accessors
	// round-trip, the built-in formats validate, malformed ones do not, and
	// legacy() read through a format agrees with VoxelInstance's own
	// hardcoded cut. Runs once, from createVoxelRegistry().
	bool voxel_format_self_test();

	struct VoxelInstance;
	struct VoxelSelector;

	struct VoxelRegistry
	{
		virtual ~VoxelRegistry(){}

		virtual void clear() = 0;
		virtual sv_<VoxelDefinition> get_all() = 0;
		// How many voxel types there are, without copying any of them. What
		// asks is a line of detail on a screen: a client whose count is not
		// the server's has a registry fault and nothing else is worth
		// looking at yet.
		virtual size_t get_count() = 0;

		// How many types are registered, so that walking the ids is a loop
		// with an end rather than one that asks for the id after the last
		// and reads the warning as its answer. Ids run 1..num_voxels().
		virtual VoxelTypeId num_voxels() = 0;

		// How a voxel word is cut up; see VoxelFormat. The default is
		// VoxelFormat::legacy().
		//
		// set_format() may only be called while the registry holds no voxel
		// definitions, which in practice means before a world generates
		// anything: everything saved in the world, and every volume on its
		// way to a client, is bits under this format, and there is no
		// migration for changing it underneath them. It throws on a format
		// that does not validate and on one that arrives too late.
		virtual const VoxelFormat& get_format() = 0;
		virtual void set_format(const VoxelFormat &format) = 0;

		// A named plane of a module's own appended to the format, whatever
		// module set the format and whenever it does: the plane is added
		// now and again to every format set_format() is given after this,
		// so a variant's module can ask before the base game has said what
		// its cut is ([GAME_BASE]). Nothing bound reads it -- it is the
		// module's bits, read and written by name through the sample API.
		// A chunk takes the plane on the first time it is written after
		// this, so it is allowed after the world exists; a plane of that
		// name already there (of the same width) is left as it is. Returns
		// the plane's index.
		virtual int add_plane(const ss_ &name, uint8_t bits) = 0;

		// How a voxel's definition is found; see VoxelSelector in
		// interface/voxel_selector.h. The default is the id role of the
		// format, which is what every game in this tree does.
		//
		// Unlike the format this may be set at any time, and a world that
		// changes it has to have everything meshed again -- the same as
		// changing a definition. What it may not do is point at a
		// definition the registry does not have, which is what it is
		// checked for.
		virtual const VoxelSelector& get_look_selector() = 0;
		virtual void set_look_selector(const VoxelSelector &selector) = 0;

		virtual VoxelTypeId add_voxel(const VoxelDefinition &def) = 0;
		// The same for a whole registry at once, which is how one arrives
		// over the network: the definitions are moved out of the vector
		// rather than copied, the room for them is taken in one go and the
		// lock is taken once. A join's 28 MB of registry spent 121 ms of
		// the client's frame in add_voxel() before this ([CLIENT_FRAME]).
		virtual void add_voxels(sv_<VoxelDefinition> &defs) = 0;

		virtual const VoxelDefinition* get(const VoxelTypeId &id) = 0;
		virtual const VoxelDefinition* get(const VoxelName &name) = 0;

		// Every method is safe to call from a worker thread while the main
		// thread adds voxels, and a pointer handed out stays valid; the
		// contents of a definition do not change once it has been added.
		//
		// atlas_reg may only be supplied when called from Urho3D main thread.
		// with_lod also builds the segments a LOD mesh samples, which is
		// most of the cost of a voxel type's textures.
		virtual const CachedVoxelDefinition* get_cached(const VoxelTypeId &id,
				AtlasRegistry *atlas_reg = nullptr, bool with_lod = false) = 0;
		virtual const CachedVoxelDefinition* get_cached(const VoxelSample &v,
				AtlasRegistry *atlas_reg = nullptr, bool with_lod = false) = 0;
		virtual const CachedVoxelDefinition* get_cached(const VoxelInstance &v,
				AtlasRegistry *atlas_reg = nullptr, bool with_lod = false) = 0;

		virtual bool is_dirty() = 0;
		virtual void clear_dirty() = 0;

		void serialize(std::ostream &os);
		void deserialize(std::istream &is);
		ss_  serialize();
		void deserialize(const ss_ &s);
	};

	VoxelRegistry* createVoxelRegistry();

	// One voxel, as the engine's default format cuts it up.
	//
	// The accessors below are that format's bit ranges written out by hand,
	// and they are only right for a world that kept it. Anything that reads
	// a voxel of a world whose format the game chose goes through
	// VoxelFormat instead -- get_format() on the world's registry -- and the
	// mesher does. What is left using these is code that only ever sees the
	// default cut: the sample games, and the modules built for them.
	struct VoxelInstance
	{
		uint32_t data;

		VoxelInstance(){}
		// Create voxel from raw data (MSBs are preserved)
		VoxelInstance(uint32_t id): data(id){}

		VoxelTypeId get_id() const {return data & 0x001fffff; }
		uint8_t getMSB() const {return (data>>24) & 0xff; }

		// Bits 24..27 hold skylight. It is only meaningful in transparent
		// voxels: the mesher reads it from the voxel in front of each face.
		// Nothing computes it by default; a world opts in by filling it.
		static const uint8_t SKYLIGHT_MAX = 15;
		uint8_t get_skylight() const {return (data>>24) & 0x0f; }
		void set_skylight(uint8_t l){
			data = (data & ~0x0f000000UL) | ((uint32_t)(l & 0x0f) << 24);
		}

		// Bits 28..31 hold lamplight: light that reaches the voxel from
		// something other than the sky, which is a torch or a lava flow or
		// whatever else a world has. Read the same way as skylight, and
		// separate from it because the sky's contribution changes with the
		// time of day and a lamp's does not: a shader that is handed both can
		// move the sun without anything being meshed again.
		static const uint8_t LAMPLIGHT_MAX = 15;
		uint8_t get_lamplight() const {return (data>>28) & 0x0f; }
		void set_lamplight(uint8_t l){
			data = (data & ~0xf0000000UL) | ((uint32_t)(l & 0x0f) << 28);
		}
	};
}
// vim: set noet ts=4 sw=4:
