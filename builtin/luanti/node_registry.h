// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// A Luanti node definition as a plain struct, and what becomes of it: its
// voxel definition, its surface numbers and what a mapgen is told about it.
// builtin/luanti fills the struct from the game's Lua; any module may fill
// it itself and include this ("luanti/node_registry.h").
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/voxel.h"
#include "luanti/shapes.h"
#include "luanti_mapgen/api.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <sstream>

namespace luanti_registry
{
using namespace luanti_shapes;

// What the builder reads of a node, in Luanti's own words where it has
// them. builtin/luanti's bootstrap.lua (core.__voxel_defs()) says where each
// comes from in a game's definition.
struct NodeDef
{
	ss_ name;
	// "normal", "airlike", "liquid", "nodebox", "plantlike", ...
	ss_ drawtype = "normal";
	// sunlight_propagates; airlike is always
	bool sunlight = false;
	// paramtype == "light": light gets in, though the sun may not
	bool param_type_light = false;
	bool is_ground_content = true;
	bool floodable = false;
	// What the node's own colour multiplies its tiles by, where a paletted
	// node's slot colour would go
	ss_ node_mul;
	bool alpha_blend = false;
	bool alpha_clip = false;
	// airlike: nothing at all stands there
	bool empty = false;
	bool walkable = true;
	bool climbable = false;
	double move_resistance = 0;
	double bouncy = 0;
	double slippery = 0;
	bool disable_jump = false;
	bool disable_descend = false;
	bool swimmable = false;
	// 0 the ray goes through, 1 pointable, 2 blocking
	double pointable = 1;
	// The surface guess reads these; see guess_surface()
	sm_<ss_, int> groups;
	int waving = 0;
	// The surface numbers when the caller has them already; otherwise
	// guess_surface() gives them
	bool has_surface = false;
	interface::AtlasSegmentDefinition surface;
	float visual_scale = 1.0f;
	// +Y, -Y, +X, -X, +Z, -Z
	ss_ tiles[6];
	bool has_tiles = false;
	// Which tiles are a strip of animation frames, as the aspect the frame
	// count is worked out with (0 a still tile), and the seconds a loop
	// through them takes
	float tile_aspect[6] = {};
	float tile_length[6] = {};
	// Six numbers a box
	sv_<float> node_box;
	sv_<float> collision_box;
	sv_<float> selection_box;
	// A wallmounted node's own selection box per wall: seven numbers a box
	// with the wallmounted direction first
	sv_<float> selection_box_wall;
	// A "connected" node box: seven numbers a box, the side it belongs to
	// first (0 the fixed part)
	sv_<float> node_box_connected;
	// ";"-separated group names: what it connects to, and its own groups
	ss_ node_box_connects;
	ss_ node_box_groups;
	// "facedir", "4dir", "wallmounted", "meshoptions" or ""
	ss_ facing;
	// A rooted plant's plant, and its strip of frames as tile_aspect
	ss_ overlay_tile;
	float overlay_aspect = 0;
	float overlay_length = 0;
	// What says two liquid nodes are the same liquid: both name the source
	ss_ liquid_group;
	int liquid_range = LIQUID_LEVELS;
	ss_ palette;
	ss_ mesh;
	int raillike_group = 0;
	uint8_t light_source = 0;
};

// What a mapgen asks about a node.
// simplified: the liquid type is read off the drawtype, which is what it
// is in every game seen; a game whose liquidtype and drawtype disagree
// wants a field of its own here.
inline luanti_mapgen::Params::NodeProps mapgen_props(const NodeDef &d)
{
	luanti_mapgen::Params::NodeProps p;
	p.walkable = d.walkable;
	p.is_ground_content = d.is_ground_content;
	p.floodable = d.floodable;
	p.light_propagates = d.param_type_light;
	p.sunlight_propagates = d.sunlight;
	p.liquid_type = d.drawtype == "liquid" ? 2 :
			d.drawtype == "flowingliquid" ? 1 : 0;
	p.drawtype = d.drawtype;
	p.param_type_light = d.param_type_light;
	return p;
}

// What a node's surface is made of, guessed from its definition: the port
// of extensions/luanti_client/surface.lua's for_node(), which says why each
// number is what it is. builtin/luanti still takes surface.lua's own answer
// and compares this with it for every node at start, so the two cannot
// drift apart unseen.
inline interface::AtlasSegmentDefinition guess_surface(const NodeDef &d)
{
	// roughness, spec_strength, bumpiness, translucency, spots,
	// static_spots; -1 is "what it was"
	struct S { float v[6]; };
	static const S DEFAULT = {{0.95f, 0.2f, 0.3f, 0, 0, 0}};
	auto with = [](S s, const S &o){
		for(size_t i = 0; i < 6; i++)
			if(o.v[i] >= 0)
				s.v[i] = o.v[i];
		return s;
	};
	auto group = [&](const char *n){
		auto it = d.groups.find(n);
		return it == d.groups.end() ? 0 : it->second;
	};
	const ss_ &dt = d.drawtype;
	const bool liquid = dt == "liquid" || dt == "flowingliquid";
	S out = DEFAULT;
	if(liquid){
		out = with(DEFAULT, {{0.25f, 0.9f, 0, -1, 0.05f, -1}});
	} else if(dt == "plantlike" || dt == "plantlike_rooted" ||
			dt == "allfaces" || dt == "allfaces_optional"){
		out = with(DEFAULT, {{0.95f, 0.12f, 0.2f, 0.12f, 0.03f, -1}});
	} else if(dt == "glasslike" || dt == "glasslike_framed" ||
			dt == "glasslike_framed_optional" || d.alpha_blend){
		out = with(DEFAULT, {{0.10f, 1.0f, 0, -1, -1, 0.03f}});
	} else if(group("crumbly") > 0){
		out = with(DEFAULT, {{1.0f, 0.1f, 0.7f, -1, -1, -1}});
	} else if(group("cracky") > 0){
		out = with(DEFAULT, {{0.7f, 0.4f, 0.35f, -1, -1, -1}});
	} else if(group("snappy") > 0 || group("fleshy") > 0){
		out = with(DEFAULT, {{1.0f, 0.05f, 0.15f, -1, -1, -1}});
	} else if(group("choppy") > 0){
		out = with(DEFAULT, {{0.85f, 0.2f, 0.4f, -1, -1, -1}});
	}
	static const struct { const char *pattern; S s; } BY_NAME[] = {
		{"water", {{0.35f, 0.9f, 0, -1, 0.05f, -1}}},
		{"lava", {{0.6f, 0.3f, 0.2f, -1, -1, -1}}},
		{"ice", {{0.10f, 1.0f, 0.1f, -1, -1, 0.05f}}},
		{"glass", {{0.10f, 1.0f, 0, -1, -1, -1}}},
		{"crystal", {{0.15f, 0.9f, 0.1f, -1, -1, 0.06f}}},
		{"gem", {{0.15f, 0.9f, -1, -1, -1, 0.06f}}},
		{"diamond", {{0.12f, 1.0f, -1, -1, -1, 0.07f}}},
		{"mese", {{0.2f, 0.8f, -1, -1, -1, 0.06f}}},
		{"metal", {{0.35f, 0.8f, 0.1f, -1, -1, -1}}},
		{"steel", {{0.35f, 0.8f, 0.1f, -1, -1, -1}}},
		{"copper", {{0.40f, 0.7f, 0.1f, -1, -1, -1}}},
		{"bronze", {{0.40f, 0.7f, 0.1f, -1, -1, -1}}},
		{"tin", {{0.35f, 0.8f, 0.1f, -1, -1, -1}}},
		{"gold", {{0.30f, 0.9f, 0.1f, -1, -1, -1}}},
		{"snow", {{0.85f, 0.35f, 0.2f, -1, -1, 0.06f}}},
		{"sand", {{1.0f, 0.15f, 0.6f, -1, -1, 0.04f}}},
		{"ore", {{0.6f, 0.5f, -1, -1, -1, 0.05f}}},
		{"stone_with_", {{0.6f, 0.5f, -1, -1, -1, 0.05f}}},
		{"obsidian", {{0.2f, 0.8f, 0.15f, -1, -1, -1}}},
		{"quartz", {{0.35f, 0.6f, 0.1f, -1, -1, -1}}},
		{"prismarine", {{0.4f, 0.5f, 0.2f, -1, -1, 0.04f}}},
		{"slime", {{0.3f, 0.7f, 0, -1, -1, -1}}},
		{"honey", {{0.3f, 0.7f, 0, -1, -1, -1}}},
		{"emerald", {{0.15f, 0.9f, -1, -1, -1, 0.06f}}},
		{"lapis", {{0.5f, 0.4f, 0.2f, -1, -1, -1}}},
		{"wool", {{1.0f, 0.05f, 0.3f, -1, -1, -1}}},
		{"carpet", {{1.0f, 0.05f, 0.3f, -1, -1, -1}}},
		{"clay", {{0.95f, 0.1f, 0.2f, -1, -1, -1}}},
		{"mud", {{0.6f, 0.3f, 0.4f, -1, -1, -1}}},
	};
	for(const auto &e : BY_NAME){
		if(d.name.find(e.pattern) != ss_::npos){
			out = with(out, e.s);
			break;
		}
	}
	float &spec = out.v[1], &spots = out.v[4], &static_spots = out.v[5];
	if(d.light_source > 0){
		spots = 0;
		static_spots = 0;
		spec = std::min(spec, 0.1f);
	}
	if(d.waving == 0 && spots > 0 && !liquid){
		static_spots = std::max(static_spots, spots);
		spots = 0;
	}
	if(dt == "firelike"){
		spec = 0;
		spots = 0;
		static_spots = 0;
	}
	interface::AtlasSegmentDefinition s;
	s.roughness = out.v[0];
	s.spec_strength = out.v[1];
	s.bumpiness = out.v[2];
	s.translucency = out.v[3];
	s.spots = out.v[4];
	s.static_spots = out.v[5];
	return s;
}

// The cases surface.lua's own load-time asserts hold it to
inline void check_surface()
{
	auto node = [](const char *name, const char *drawtype,
			const sm_<ss_, int> &groups = {}){
		NodeDef d;
		d.name = name;
		d.drawtype = drawtype;
		d.groups = groups;
		return d;
	};
	NodeDef d = node("default:water_source", "liquid");
	const interface::AtlasSegmentDefinition water = guess_surface(d);
	assert(water.spots > 0 && water.roughness < 0.4f);
	d = node("default:leaves", "allfaces", {{"snappy", 3}});
	d.waving = 2;
	assert(guess_surface(d).translucency > 0.05f);
	d = node("default:dirt", "normal", {{"crumbly", 3}});
	assert(guess_surface(d).bumpiness > 0.5f &&
			guess_surface(d).spec_strength < 0.2f);
	d = node("default:sand", "normal", {{"crumbly", 3}});
	assert(guess_surface(d).static_spots > 0);
	d = node("default:torch", "torchlike");
	d.light_source = 14;
	assert(guess_surface(d).static_spots == 0 && guess_surface(d).spots == 0);
	d = node("default:glass", "glasslike");
	assert(guess_surface(d).roughness < 0.2f &&
			guess_surface(d).spec_strength > 0.9f);
	d = node("", "normal");
	assert(guess_surface(d).roughness == 0.95f && guess_surface(d).spots == 0);
	d = node("mcl_core:stone_with_iron", "normal", {{"cracky", 3}});
	assert(guess_surface(d).static_spots > 0);
	d = node("mcl_wool:red", "normal");
	assert(guess_surface(d).spec_strength < 0.1f);
	d = node("xpanes:pane", "nodebox");
	d.alpha_blend = true;
	assert(guess_surface(d).roughness < 0.2f);
}

// Where the builder gets what only the caller knows: the textures the
// client can draw, and the media a palette or a mesh is read from. What is
// not overridden is a module whose tiles are plain resource names.
struct Media
{
	virtual ~Media(){}
	// The resource name `tile` is drawn under; empty if the client cannot
	// draw it
	virtual ss_ texture(const ss_ &tile){ return tile; }
	// How many animation frames a strip of them holds
	virtual size_t frame_count(const ss_ &tile, float aspect){ return 1; }
	// The colours of a palette, row by row and at most 256 of them
	virtual sv_<uint32_t> palette(const ss_ &name){ return {}; }
	// The quads of a "mesh" node's model; empty leaves it a cube
	virtual sv_<interface::VoxelQuad> mesh(const ss_ &name, float scale)
	{ return {}; }
	// A generated flat colour for a node whose tiles cannot be drawn;
	// empty for none
	virtual ss_ fallback(const ss_ &node_name){ return ""; }
};

// "#rrggbb", which is what a texture modifier takes
inline ss_ hex_colour(uint32_t rgb)
{
	char buf[8];
	snprintf(buf, sizeof buf, "#%02x%02x%02x",
			(rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
	return ss_(buf);
}

// Where a paletted node's colour goes in a tile's expression. The Lua
// side marks the place per layer -- see PALETTE_MARK in
// builtin/luanti/lua/bootstrap.lua -- because **Luanti applies the node's
// colour to a layer only when that layer has no colour of its own**, and
// the layers are composed there while the palette is resolved here. A node
// with no palette passes an empty mul and the marks come out.
inline ss_ with_palette(const ss_ &expr, const ss_ &mul)
{
	static const ss_ mark = ss_("\1pal\1");
	ss_ out;
	out.reserve(expr.size());
	size_t at = 0;
	for(;;){
		const size_t found = expr.find(mark, at);
		if(found == ss_::npos){
			out += expr.substr(at);
			break;
		}
		out += expr.substr(at, found - at);
		out += mul;
		at = found + mark.size();
	}
	return out;
}

// One texture of a definition, with the surface numbers the node has.
// `frames` is how many animation frames the texture is a vertical strip
// of: the segment is then the first of them, which is what the atlas's
// own total_segments is for. One is a still texture. `length` is the
// seconds a loop through them takes, which the client's atlas plays
// ([NODE_ANIM]).
inline interface::AtlasSegmentDefinition make_segment(const ss_ &texture,
		const interface::AtlasSegmentDefinition &surface,
		size_t frames = 1, float length = 0.0f)
{
	interface::AtlasSegmentDefinition seg = surface;
	seg.resource_name = texture;
	seg.total_segments = Urho3D::IntVector2(
			texture.empty() ? 0 : 1,
			texture.empty() ? 0 : (int)(frames < 1 ? 1 : frames));
	seg.select_segment = Urho3D::IntVector2(0, 0);
	seg.animation_length = (frames > 1 && length > 0.0f) ? length : 0.0f;
	return seg;
}

// Which colour a param2 picks out of a palette of this many colours.
// Luanti stretches a palette over the 256 param2 values -- each pixel fills
// 256/pixels of them -- so the colour changes only every step, and the bits
// below it are the direction. A sane game ships exactly as many colours as
// the bits above the direction can count, and then this is those bits.
inline size_t palette_slot_of_param(size_t slots, uint8_t param)
{
	if(slots <= 1)
		return 0;
	size_t slot = (size_t)param / (256 / slots);
	return slot < slots ? slot : slots - 1;
}

// One family for every fence, because a fence reaches any other fence
// whatever kind it is -- which is Luanti's rule for them. Rails take one
// per raillike group; see connect_group in interface/voxel.h, which has
// thirty-two.
static const uint8_t FENCE_CONNECT_GROUP = 1;

// Node definitions into voxel definitions, one at a time and in id order.
// It keeps the numbering that spans nodes -- glass edge materials, liquid
// shape groups, connect groups -- so one builder builds one registry.
struct Builder
{
	// What build() saw, for the caller's log line
	size_t n_shaped = 0;
	size_t n_liquid = 0;
	size_t n_facing_nodes = 0;
	size_t n_palette_nodes = 0;
	size_t n_palette_variants = 0;
	// The nodes that wear Media::fallback() on a face
	sv_<ss_> fallback_nodes;

	// An edge material of its own for each kind of glass, so that the
	// mesher draws a face between glass and anything else and not between
	// two of the same glass -- which is what Luanti's glasslike is.
	//
	// simplified: 10 to 255 is what an EdgeMaterialId leaves free, so a game
	// with more than 246 glasslike node types shares the last one and its
	// panes merge into each other. Nothing that big has turned up; the
	// upgrade path is a wider EdgeMaterialId, which is an engine change.
	interface::EdgeMaterialId glass_edge_material(const ss_ &name)
	{
		auto it = m_glass_edge_materials.find(name);
		if(it != m_glass_edge_materials.end())
			return it->second;
		interface::EdgeMaterialId id = 255;
		if(m_next_glass_edge_material < 255){
			id = (interface::EdgeMaterialId)m_next_glass_edge_material++;
		} else if(!m_glass_edge_materials_exhausted){
			m_glass_edge_materials_exhausted = true;
			log_w("luanti", "More than 246 glasslike node types; the rest "
					"share an edge material and their faces merge into each "
					"other");
		}
		m_glass_edge_materials[name] = id;
		return id;
	}

	// One shape group per liquid, so that the mesher drops the faces inside
	// a body of it -- the water in the middle of a lake -- and keeps the
	// ones against everything else. A source and its flowing form share a
	// group because they both name the source.
	//
	// simplified: 1 to 255 is what a shape group has, and 0 means "not
	// grouped", so a game with more than 255 distinct liquids shares the
	// last one and two of its liquids stop drawing the surface between
	// them. Nothing that big has turned up.
	uint8_t liquid_shape_group(const ss_ &group)
	{
		auto it = m_liquid_shape_groups.find(group);
		if(it != m_liquid_shape_groups.end())
			return it->second;
		uint8_t id = 255;
		if(m_next_liquid_shape_group < 255){
			id = (uint8_t)m_next_liquid_shape_group++;
		} else if(!m_liquid_shape_groups_exhausted){
			m_liquid_shape_groups_exhausted = true;
			log_w("luanti", "More than 254 liquids; the rest share a shape "
					"group and draw no surface between each other");
		}
		m_liquid_shape_groups[group] = id;
		return id;
	}

	// One family per raillike group, because a rail reaches the rails of
	// its own group and no others. Fences have group 1; a connect group is
	// five bits of a thirty-two bit mask, so there are thirty-one left.
	uint8_t named_connect_group(const ss_ &name)
	{
		auto it = m_named_connect_groups.find(name);
		if(it != m_named_connect_groups.end())
			return it->second;
		uint8_t id = 32;
		if(m_next_connect_group <= 32){
			id = (uint8_t)m_next_connect_group++;
		} else if(!m_connect_groups_exhausted){
			m_connect_groups_exhausted = true;
			log_w("luanti", "More than 31 connect groups; the rest share one "
					"and connect to each other");
		}
		m_named_connect_groups[name] = id;
		return id;
	}

	uint8_t rail_connect_group(int raillike_group)
	{
		auto it = m_rail_connect_groups.find(raillike_group);
		if(it != m_rail_connect_groups.end())
			return it->second;
		uint8_t id = 32;
		if(m_next_connect_group <= 32){
			id = (uint8_t)m_next_connect_group++;
		} else if(!m_connect_groups_exhausted){
			m_connect_groups_exhausted = true;
			log_w("luanti", "More than 31 raillike groups; the rest share one "
					"and their rails connect to each other");
		}
		m_rail_connect_groups[raillike_group] = id;
		return id;
	}

	interface::VoxelDefinition build(const NodeDef &d, Media &media)
	{
		const interface::AtlasSegmentDefinition surface =
				d.has_surface ? d.surface : guess_surface(d);
		const ss_ &drawtype = d.drawtype;
		const float visual_scale = d.visual_scale > 0.0f ?
				d.visual_scale : 1.0f;
		const bool walkable = d.walkable;
		const bool empty = d.empty;

		// The shape, where the drawtype is one this builds. Everything else
		// is still a cube; see the M3 entry in the module plan for which and
		// in what order.
		sv_<interface::VoxelQuad> shape;
		bool double_sided = false;
		bool lit_from_above = false;
		// "torchlike" or "signlike": a shape that is built per wallmounted
		// direction rather than turned
		ss_ wall_shape;
		// Which family this reaches out to, and which families it reaches;
		// see connect_dir in interface/voxel.h
		uint8_t connect_group = 0;
		uint32_t connect_mask = 0;
		bool connect_to_solid = false;
		// A shape per mask of which neighbours the voxel reaches; see
		// VoxelDefinition::shape_masked
		sv_<interface::VoxelQuad> masked_shape;
		uint16_t masked_begin[21] = {};
		// The shape is drawn as well as the voxel's cube faces, not instead
		// of them
		bool shape_over_cube = false;
		if(drawtype == "mesh" && !d.mesh.empty()){
			// The model's own quads, in the node's own cube -- and the parts
			// of it that reach outside, which is how a model two nodes tall
			// is one node with an airlike one over it. A format nothing here
			// reads leaves the node the cube it had.
			shape = media.mesh(d.mesh, visual_scale);
			// A mesh node's tiles are two-sided unless one says otherwise:
			// Luanti's read_tiledef() sets default_culling false for
			// NDT_MESH the way it does for plantlike. Models are authored
			// for that -- VoxeLibre's sunflower gives the front and the back
			// of its flower head as two quads with the same winding, so
			// culling loses both of them and the stem is left standing on
			// its own.
			//
			// The extension has drawn them this way from the start -- see
			// shapes.lua, NDT_MESH -- which is why its picture of the same
			// world has flowers on its sunflowers.
			//
			// simplified: a tile that sets backface_culling itself is not
			// heard, here or anywhere else; what that would take is a flag
			// per quad rather than per shape.
			double_sided = true;
		} else if(drawtype == "nodebox" && d.node_box.size() >= 6){
			const sv_<float> &boxes = d.node_box;
			for(size_t b = 0; b + 5 < boxes.size(); b += 6){
				add_box_quads(shape, boxes[b], boxes[b + 1], boxes[b + 2],
						boxes[b + 3], boxes[b + 4], boxes[b + 5]);
			}
		} else if(drawtype == "nodebox" && d.node_box_connected.size() >= 7){
			// A "connected" box: the fixed part, and a set per side drawn
			// when the neighbour there is one of its connects_to groups or
			// solid -- the fence's own rule with the game's boxes. Its own
			// group is the first of its connects_to it belongs to, so a
			// fence reaches fences and a pane panes.
			// simplified: a target group whose nodes are not solid and were
			// not registered as connected boxes themselves (a fence gate) is
			// not reached; connects_to is read as "any solid" for the rest.
			const sv_<float> &connected_boxes = d.node_box_connected;
			for(size_t b = 0; b + 6 < connected_boxes.size(); b += 7){
				const size_t first = shape.size();
				add_box_quads(shape, connected_boxes[b + 1],
						connected_boxes[b + 2], connected_boxes[b + 3],
						connected_boxes[b + 4], connected_boxes[b + 5],
						connected_boxes[b + 6]);
				const uint8_t tag = (uint8_t)connected_boxes[b];
				if(tag != 0)
					for(size_t i = first; i < shape.size(); i++)
						shape[i].connect_dir = tag;
			}
			sv_<ss_> targets;
			{
				std::istringstream is(d.node_box_connects);
				ss_ g;
				while(std::getline(is, g, ';'))
					if(!g.empty())
						targets.push_back(g);
			}
			for(const ss_ &g : targets){
				const uint8_t id = named_connect_group(g);
				connect_mask |= 1u << (id - 1);
				if(connect_group == 0 && (";" + d.node_box_groups + ";").find(
						";" + g + ";") != ss_::npos)
					connect_group = id;
			}
			if(connect_group == 0 && !targets.empty())
				connect_group = named_connect_group(targets[0]);
			connect_to_solid = true;
		} else if(drawtype == "plantlike"){
			add_plant_quads(shape, visual_scale);
			double_sided = true;
		} else if(drawtype == "raillike"){
			// One quad, and which tile it wears and which way it is turned
			// is what its neighbours say -- so it is a shape per mask rather
			// than a shape. A rail reaches other rails of its own raillike
			// group and nothing else.
			add_rail_shapes(masked_shape, masked_begin);
			connect_group = rail_connect_group(d.raillike_group);
			connect_mask = 1u << (connect_group - 1);
		} else if(drawtype == "fencelike"){
			// A post and a pair of bars per direction that has something to
			// reach. It reaches other fences, whatever kind, and anything
			// solid -- which is Luanti's rule.
			add_fence_quads(shape);
			connect_group = FENCE_CONNECT_GROUP;
			connect_mask = 1u << (FENCE_CONNECT_GROUP - 1);
			connect_to_solid = true;
		} else if(drawtype == "firelike"){
			// Luanti's fire is quads leaning against whatever is around it;
			// crossed quads are what it comes to when nothing is, and what
			// the extension draws for it either way.
			add_plant_quads(shape, visual_scale);
			double_sided = true;
		} else if(drawtype == "torchlike" || drawtype == "signlike"){
			// One quad, and which way it lies is the wallmounted direction
			// rather than a rotation of one base shape -- a torch on the
			// floor leans and a torch on a wall does not. So the shape is
			// built per variant below; this is what a node whose param2
			// says nothing comes to.
			wall_shape = drawtype;
			add_wall_quads(wall_shape, shape, visual_scale, 1);
			double_sided = true;
		} else if(drawtype == "plantlike_rooted"){
			// The plant stands in the voxel above the one it is rooted in,
			// and the cube it is rooted in is ground drawn by the cube path
			// -- so this shape is over the cube rather than instead of it,
			// and the plant takes the light of the voxel it stands in and
			// not the ground's own. That is what shape_lit_from_above is
			// for.
			add_plant_quads(shape, visual_scale, 0.5f, 6);
			double_sided = true;
			lit_from_above = true;
			shape_over_cube = true;
		} else if(!d.liquid_group.empty()){
			// A full voxel of it. The faces inside a body of the same liquid
			// are dropped by the shape group, and the surface is levelled by
			// the variants below.
			add_box_quads(shape, -0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f);
		}

		// Which way the node faces, which is also param2: one variant per
		// direction, each permuting the definition's own six textures rather
		// than being a voxel type of its own.
		sv_<interface::VoxelVariant> facing_variants;
		const size_t n_facing = facing_variant_count(d.facing);
		for(size_t i = 0; i < n_facing; i++){
			interface::VoxelVariant var;
			const uint8_t dir = facing_facedir(d.facing, i);
			for(size_t f = 0; f < 6; f++){
				var.tile_order[f] = FACEDIR_TILES[dir][f];
				var.tile_turns[f] = FACEDIR_TURNS[dir][f];
			}
			if(!wall_shape.empty()){
				// A torch or a sign: its own shape per wall, and the variant
				// index is the wallmounted direction itself
				add_wall_quads(wall_shape, var.shape, visual_scale, i);
			} else if(d.facing == "meshoptions" && drawtype == "plantlike"){
				// The shape the param2 names, 1.4x with bit 4
				add_plant_quads(var.shape, (i & 8) ? visual_scale * 1.4f :
						visual_scale, -0.5f, 0, (unsigned)(i & 7));
			} else if(!shape.empty() && !shape_over_cube && dir != 0){
				// A node that has a shape turns the shape too: a stair facing
				// the other way is the same quads rotated, and the tile each
				// quad names travels with it. Only for a shape that is the
				// node's own cube -- a rooted plant's shape stands in the
				// voxel above and turning it would take it sideways out of
				// that voxel.
				turn_quads(shape, dir, var.shape);
			}
			// And what stops the player, turned the same way; empty for the
			// definition's own
			if(walkable && !empty && dir != 0)
				turn_boxes(d.collision_box, dir, var.collision_boxes);
			const sv_<float> &walls = d.selection_box_wall;
			if(!walls.empty()){
				// 6 and 7 are the ceiling and the floor turned
				const float w = (float)(i == 6 ? 0 : i == 7 ? 1 : i);
				for(size_t b = 0; b + 7 <= walls.size(); b += 7)
					if(walls[b] == w)
						var.selection_boxes.insert(var.selection_boxes.end(),
								&walls[b + 1], &walls[b + 7]);
			} else if(dir != 0){
				turn_boxes(d.selection_box, dir, var.selection_boxes);
			}
			facing_variants.push_back(var);
		}

		// A flowing liquid carries its level in param2, which is what
		// VoxelVariant is for: one per level, each a box with its own top,
		// and the mesher averages the four columns around each corner so
		// that the surface between them is continuous.
		sv_<interface::VoxelVariant> liquid_variants;
		if(drawtype == "flowingliquid" && !d.liquid_group.empty()){
			liquid_variants.resize(LIQUID_LEVELS);
			for(int level = 0; level < LIQUID_LEVELS; level++){
				interface::VoxelVariant &var = liquid_variants[level];
				var.liquid_top = liquid_level_top(level, d.liquid_range);
				add_box_quads(var.shape, -0.5f, -0.5f, -0.5f,
						0.5f, var.liquid_top, 0.5f);
			}
		}

		// The generated flat colour, for a node whose tiles the client
		// cannot load as they stand -- a texture modifier, or a name the
		// game did not ship.
		const ss_ fallback = empty ? "" : media.fallback(d.name);
		ss_ face_textures[6];
		// How many animation frames each face's texture is a strip of; the
		// segment takes the first of them, so water is water and not
		// sixteen waters squeezed onto one face
		size_t face_frames[6] = {1, 1, 1, 1, 1, 1};
		bool any_fallback = false;
		for(size_t f = 0; f < 6; f++){
			if(empty)
				continue;
			const ss_ tile = with_palette(d.tiles[f], d.node_mul);
			ss_ texture = d.has_tiles ? media.texture(tile) : "";
			if(!texture.empty()){
				face_textures[f] = texture;
				if(d.tile_aspect[f] > 0.0f)
					face_frames[f] = media.frame_count(tile, d.tile_aspect[f]);
			} else {
				face_textures[f] = fallback;
				any_fallback = true;
			}
		}
		// The plant of a rooted plant: a texture the cube it stands in does
		// not have, and the first of the definition's extra ones
		ss_ overlay_texture;
		size_t overlay_n = 1;
		if(!d.overlay_tile.empty() && !fallback.empty()){
			const ss_ tile = with_palette(d.overlay_tile, d.node_mul);
			overlay_texture = media.texture(tile);
			if(overlay_texture.empty()){
				overlay_texture = fallback;
				any_fallback = true;
			} else if(d.overlay_aspect > 0.0f){
				overlay_n = media.frame_count(tile, d.overlay_aspect);
			}
		}
		if(any_fallback && !fallback.empty())
			fallback_nodes.push_back(d.name);

		interface::VoxelDefinition vdef;
		vdef.name.block_name = d.name;
		vdef.name.segment_x = 0;
		vdef.name.segment_y = 0;
		vdef.name.segment_z = 0;
		vdef.name.rotation_primary = 0;
		vdef.name.rotation_secondary = 0;
		vdef.handler_module = "";
		for(size_t f = 0; f < 6; f++)
			vdef.textures[f] = make_segment(face_textures[f], surface,
					face_frames[f], d.tile_length[f]);
		// The textures a shape's quads can wear beyond the six faces: a
		// rooted plant's plant, which is nothing the cube it stands in has.
		// Quad tile 6 is the first of these.
		if(!overlay_texture.empty())
			vdef.extra_textures.push_back(make_segment(overlay_texture,
					surface, overlay_n, d.overlay_length));
		// Which faces are drawn, as far as the edge material carries
		// Luanti's rules:
		//  - airlike is nothing at all, and nothing draws a face against it
		//  - glasslike gets an edge material of its own, so a face is drawn
		//    against anything except more of the same glass -- a pane of it
		//    is a pane and a wall of it is a wall
		//  - allfaces draws every face, even between two of its own kind,
		//    which is what makes a tree's leaves look like leaves
		//  - everything else draws a face wherever the material changes
		//
		// Whether light gets past is a separate question now, and
		// transmits_light below is the answer to it.
		vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
		if(empty){
			vdef.edge_material_id = interface::EDGEMATERIALID_EMPTY;
		} else if(drawtype.compare(0, 9, "glasslike") == 0){
			vdef.edge_material_id = glass_edge_material(d.name);
		} else if(drawtype == "allfaces" || drawtype == "allfaces_optional"){
			vdef.face_draw_type = interface::FaceDrawType::ALWAYS;
		}
		// An empty voxel already transmits light by being empty
		vdef.transmits_light = d.sunlight && !empty;
		vdef.light_source = d.light_source;
		vdef.physically_solid = walkable && !empty;
		// Nothing here draws differently for it; the client's own physics
		// is what reads it. See "the interaction gaps".
		vdef.climbable = d.climbable;
		if(walkable && !empty)
			turn_boxes(d.collision_box, 0, vdef.collision_boxes);
		turn_boxes(d.selection_box, 0, vdef.selection_boxes);
		auto byte = [](double v, double hi){
			return (uint8_t)(v < 0 ? 0 : (v > hi ? hi : v));
		};
		vdef.move_resistance = byte(d.move_resistance, 255);
		vdef.bouncy = byte(d.bouncy, 255);
		vdef.slippery = byte(d.slippery, 255);
		vdef.disable_jump = d.disable_jump;
		vdef.disable_descend = d.disable_descend;
		vdef.swimmable = d.swimmable;
		vdef.pointable = byte(d.pointable, 2);
		vdef.fully_empty = empty;
		if(!masked_shape.empty()){
			vdef.shape_masked = masked_shape;
			for(size_t i = 0; i < 21; i++)
				vdef.shape_masked_begin[i] = masked_begin[i];
		}
		if(!shape.empty() || !masked_shape.empty()){
			vdef.shape = shape;
			vdef.shape_double_sided = double_sided;
			vdef.shape_lit_from_above = lit_from_above;
			if(!shape_over_cube){
				// A shaped voxel draws its shape and not cube faces, and its
				// neighbours draw theirs against it
				vdef.face_draw_type = interface::FaceDrawType::NEVER;
				vdef.edge_material_id = interface::EDGEMATERIALID_EMPTY;
			}
			n_shaped++;
		}
		vdef.connect_group = connect_group;
		vdef.connect_mask = connect_mask;
		vdef.connect_to_solid = connect_to_solid;
		if(!facing_variants.empty()){
			vdef.variants = facing_variants;
			for(size_t p = 0; p < 256; p++){
				vdef.variant_of_param[p] =
						facing_variant_of_param(d.facing, (uint8_t)p);
			}
			n_facing_nodes++;
		}
		// A palette: the node wears the colour its param2 picks, as its own
		// tiles through a modifier that multiplies them. Colours multiply
		// the directions rather than permuting with them, so this is the
		// facing variants once per colour -- eight colours of a facedir
		// node are 192 variants but 48 textures.
		//
		// A node whose tiles were not shipped wears a generated flat colour
		// and is left alone: there is no image for a modifier to be applied
		// to.
		if(!d.palette.empty() && !any_fallback){
			const sv_<uint32_t> colours = media.palette(d.palette);
			sv_<interface::VoxelVariant> base = vdef.variants;
			if(base.empty())
				base.push_back(interface::VoxelVariant());
			const size_t n_dirs = base.size();
			// Luanti stretches a palette over the 256 param2 values, so what
			// a param picks is the pixel at param * pixels / 256 -- which is
			// also what leaves the direction bits alone, because a sane
			// palette has exactly as many colours as the bits above the
			// direction can count
			size_t slots = colours.size();
			if(slots > 256 / n_dirs)
				slots = 256 / n_dirs;
			if(slots > 0){
				sv_<interface::VoxelVariant> coloured;
				coloured.reserve(slots * n_dirs);
				for(size_t c = 0; c < slots; c++){
					// The tile through a modifier that multiplies it, which
					// is an expression like any other: the client composes
					// it and what the definition carries is the name it
					// composes it under
					const ss_ mul = "^[multiply:" + hex_colour(
							colours[c * colours.size() / slots]);
					ss_ tinted[7];
					for(size_t f = 0; f < 6; f++){
						if(d.has_tiles && !d.tiles[f].empty())
							tinted[f] = media.texture(
									with_palette(d.tiles[f], mul));
					}
					if(!d.overlay_tile.empty())
						tinted[6] = media.texture(
								with_palette(d.overlay_tile, mul));
					for(size_t i = 0; i < n_dirs; i++){
						interface::VoxelVariant var = base[i];
						for(size_t f = 0; f < 6; f++){
							var.textures.push_back(tinted[f].empty() ?
									interface::AtlasSegmentDefinition() :
									make_segment(tinted[f], surface,
									face_frames[f], d.tile_length[f]));
						}
						if(!tinted[6].empty()){
							var.textures.push_back(
									make_segment(tinted[6], surface,
									overlay_n, d.overlay_length));
						}
						coloured.push_back(var);
					}
				}
				vdef.variants = coloured;
				for(size_t p = 0; p < 256; p++){
					const size_t c = palette_slot_of_param(slots, (uint8_t)p);
					vdef.variant_of_param[p] = (uint8_t)(c * n_dirs +
							(n_dirs > 1 ? facing_variant_of_param(
							d.facing, (uint8_t)p) : 0));
				}
				n_palette_nodes++;
				n_palette_variants += coloured.size();
			}
		}
		if(!d.liquid_group.empty()){
			vdef.is_liquid = true;
			vdef.liquid_is_source = (drawtype == "liquid");
			vdef.shape_group = liquid_shape_group(d.liquid_group);
			vdef.liquid_top = 0.5f;
			// param2's low three bits are the level; the rest of it is flags
			// this does not draw. Only a flowing liquid has them: a source's
			// param2 is whatever its own paramtype2 says, which for
			// VoxeLibre's water is the palette index its colour comes from
			// -- so assigning the levels over the variants unconditionally
			// took the sea's blue away.
			if(!liquid_variants.empty()){
				vdef.variants = liquid_variants;
				for(size_t p = 0; p < 256; p++)
					vdef.variant_of_param[p] = (uint8_t)(p % LIQUID_LEVELS);
			}
			n_liquid++;
		}
		// Which pass the faces go in. The mesher puts a translucent voxel's
		// faces on a child node of the chunk and builtin/voxel_shading gives
		// that one the blended technique.
		//
		// A liquid always, and anything the game asked to be blended rather
		// than alpha masked.
		vdef.translucent = d.alpha_blend || !d.liquid_group.empty();
		// And the cut-out ones, which are drawn with the solid world with
		// the holes in their pictures left out: a leaf, a plant, a rail, a
		// ladder. Luanti's default for every drawtype but the five solid
		// ones, so most of a game's nodes end up here.
		vdef.alpha_masked = d.alpha_clip && !vdef.translucent;
		return vdef;
	}

private:
	sm_<ss_, interface::EdgeMaterialId> m_glass_edge_materials;
	uint32_t m_next_glass_edge_material = 10;
	bool m_glass_edge_materials_exhausted = false;
	// Rails by raillike group and connected node boxes by group name share
	// the thirty-one connect groups fences leave
	sm_<int, uint8_t> m_rail_connect_groups;
	sm_<ss_, uint8_t> m_named_connect_groups;
	uint32_t m_next_connect_group = FENCE_CONNECT_GROUP + 1;
	bool m_connect_groups_exhausted = false;
	sm_<ss_, uint8_t> m_liquid_shape_groups;
	uint32_t m_next_liquid_shape_group = 1;
	bool m_liquid_shape_groups_exhausted = false;
};

// What check_surface() and the palette arithmetic hold to. builtin/luanti
// runs it once at start under BUILDAT_LUANTI_SELFCHECKS=1.
inline void check_registry()
{
	check_surface();
	// A palette is stretched over the 256 param2 values, so a colour
	// covers as many of them as the directions under it: devtest's
	// facedir palette is eight colours and its facedir is five bits.
	assert(palette_slot_of_param(8, 0) == 0);
	assert(palette_slot_of_param(8, 31) == 0);
	assert(palette_slot_of_param(8, 32) == 1);
	assert(palette_slot_of_param(8, 255) == 7);
	assert(palette_slot_of_param(64, 4) == 1);   // color4dir
	assert(palette_slot_of_param(32, 8) == 1);   // colorwallmounted
	assert(palette_slot_of_param(256, 137) == 137); // color
	assert(palette_slot_of_param(1, 255) == 0);
	// And a variant index stays inside the byte that indexes them: a
	// colour times a direction is never more than the param itself
	assert(palette_slot_of_param(8, 255) * 24 +
			facing_variant_of_param("facedir", 255) < 256);
	assert(palette_slot_of_param(64, 255) * 4 +
			facing_variant_of_param("4dir", 255) < 256);
	assert(palette_slot_of_param(32, 255) * 8 +
			facing_variant_of_param("wallmounted", 255) < 256);
}

}
// vim: set noet ts=4 sw=4:
