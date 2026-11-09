// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [KIT] stage 4e: the World (types/terrain.lua, api.h's Host::world_scene)
// and the material set it is made of. Part of kit.cpp (one translation
// unit), included there.
//
// **A material set** (materials.json is Kit's own, Workbench's; an app
// gives its own as Host::materials):
//   {"format": "kit_materials", "author", "name",
//    "voxels": {"<author>/<name>": {"texture": t | "top", "side",
//        "bottom": t, "kind": "solid" (default) | "water" | "leaves" |
//        "plant" (two crossed quads, walked through) | "glass" (a solid
//        cube blended by its texture's alpha, [KIT_TINT_MATERIALS]),
//        "tint": its tint palette (TintPalette::parse; a name is one of
//        "palettes"), "heightmap": the
//        layer of builtin/heightmap's ground textures that is its look,
//        ([KIT] stage 4g) "solid": a cube that stops players (true by
//        default), "transparent": a cube cut out by its texture's alpha
//        (a leaves' always), "light": 0...15 it emits, "friction": 0...10
//        (1 by default) and "surface": a tag ("road", "ice", "mud";
//        letters, digits and _, none by default) for what moves on it,
//        [KIT_CTF] "blast_resist": 0...1000 (0 by default), the blast
//        strength it stands (Kit's c:explode, api.h),
//        [KIT_ENVIRONMENT] "seasons": {season: {"texture" | "top",
//        "side", "bottom"}, ...}: its look in that season (spring, summer,
//        autumn, winter; the faces not named its own), [KIT_SOUNDS]
//        "sound_dig", "sound_place": a project's sound's name,
//        [KIT_CTF] "drop": what its dig drops (a voxel or item type's
//        name, "<author>/<name>"; none: itself), [KIT_SPOTS] "spots",
//        "static_spots": 0...1, the share of its surface glinting under
//        physical lighting, moving (water, leaves) or still (sand's
//        stones, ore); none: by its kind and name, as skeldat's),
//        [KIT_NORMALS] "bumpiness": 0...1, how much of its texture's
//        brightness is relief under physical lighting (none: by kind and
//        name, as skeldat's: water and glass 0, sand 0.6, the rest 1)},
//        ...},
//    "palettes": {name: [entry, ...], ...} ([KIT_TINT_PALETTE]),
//    "fallbacks": {role: role, ...},
//    "structures": {name: {"voxel": v} | {"voxels": {letter: v, ...},
//        "origin": [x, y, z], "layers": [[row, ...], ...]}, ...},
//    "biomes": {name: {role: voxel, ..., "filler_depth": n,
//        "decorations": [{"structure", "on", "density"}, ...]}, ...}}
// The roles: stone, top, filler (its depth the biome's filler_depth),
// water, riverbed, dust, cave_floor, cave_wall. A role a biome does not
// bind falls back along "fallbacks" (top to filler to stone); one whose
// chain ends with nothing is missing, and a generator needing it refuses,
// naming it. No river water: a river, if any, is the sea's water.
// "voxels" is the set's own voxels, which register_voxels() adds (an app
// binding roles to voxels of its own leaves it out).
// [KIT_MATERIAL_SETS] **A set package** is a Kit package with
// materials.json (this format): its voxels "<its author>/<n>", installed
// as its voxel types (a face's texture "textures/<file>.png" in the
// archive), and "extends": "kit/default" or "<author>/<name>" of a set
// package it depends on (merge_sets(): the later set winning per voxel,
// palette, fallback, structure and biome role). The World's "materials"
// names one (kit.cpp material_json()).
// simplified: a set's voxel looks on a heightmap as one of Kit's ground
// layers ("heightmap": n), not as its own texture: a set's ground on a
// heightmap surface wears Kit's textures; the upgrade is heightmap
// layers made from package textures (the client's ground texture array)
// **Structures** ([KIT] stage 4f) are voxel structures a decoration puts
// down: layers bottom up, each its rows along z, a letter a cell along x
// ("." leaves it), the origin the cell that stands on the ground (a
// tree's lowest log). **Decorations** are a biome's scatter: a structure
// on the top of dry ground ("top"), on the ground under water ("water"),
// on a cave's floor ("cave") or in its wall ("cave_wall", the wall cell
// replaced), density the chance a column has it (a cave's: a floor or
// wall cell). Deterministic by the seed and the position. A cave's
// decorations are one cell (a structure's first).
//
// **The generators** are native and fill a column from its top cell: the
// top role there (riverbed under the sea and BEACH over it), filler below
// it, stone below that, water from over the ground up to sea_level. flat: the top at
// level; noise: level + height * fbm(x / spread, z / spread, seed);
// valleys: Luanti's valleys mapgen's surface (luanti_mapgen's
// surface_map, mgvalleys_river_size 0: its valleys, no river channels;
// its 3D fill left out, so no overhangs) + level. Each is a function of
// its parameters and seed alone (the same map, byte for byte, on the
// same build). ([KIT] stage 4f, version 2) Caves (the World's caves):
// tunnels where two 3D noises are both near nought and caverns where a
// third is high, 5 to 100 cells under the top; ([KIT_CAVE_MOUTHS]) a
// tunnel goes on up through the soil to the top where it rises, a mouth
// open to the sky, but not in a column under the sea, and no surface
// decoration stands on a mouth's column (cave_mouth()); the cell under a cave's air its biome's cave_floor, one beside or over
// it cave_wall. Then the biome's decorations (the World's decorations),
// each section placing every one whose structure reaches into it, in one
// order (z, then x), into air (water under water) only: a tree crossing
// a section's side is whole.
//
// **Finite** maps are width x depth cells round the origin, every section
// of them pinned (loaded, generated once, saved: baked; a later engine
// cannot change a published map). The border: void (nothing), wall (a
// ring of stone 4 over the highest ground), water (16 cells of sea round
// it, its bed 4 under sea_level). **Infinite** maps are generated where
// players go; a section nobody wrote is not saved
// (voxelworld::set_save_unaltered), the generator and its version pinned
// in Kit's row "world". **A heightmap surface**: builtin/heightmap's map,
// finite, on the voxels' finite area ([KIT_HM_ORIGIN] its origin x0(),
// z0(); a World saved before origins at the world's origin, its row's
// "hm_anchor" "corner") (a side a multiple of 64), the same heights, its layers the biome's
// top, stone and riverbed's; no water on it yet; its decorations voxel
// objects (kit.cpp).
//
// Changing the parameters generates again every section nobody wrote
// (voxelworld::set_writes_alter: any write but the generator's); the
// written ones stay and a warning names those beside regenerated ones,
// the seams. A change of the surface (or a heightmap's size) replaces the
// old ground at once: the heightmap made or deleted, the voxel sections
// nobody wrote forgotten.
// simplified: one biome a world (the parameter), no biome noise yet;
// no dust placed; a mouth's column keeps its uncarved top in Heights (the
// spawn skips mouths, a brush reads the voxels).
//
// **The brushes** ([KIT] stage 4f, Brush below) work on columns of a
// voxel surface: a column's top is the highest ground cell (a role's
// voxel of any biome) with no ground over it, within the dab's reach.
// They write ground, air, water and plant cells only, never what a
// builder put there or a tree.
#pragma once
#include <array>
#include "worldgen/api.h"
#include "heightmap/api.h"
#include "luanti_mapgen/api.h"
#include "interface/noise.h"
#include "luanti/shapes.h"
#include <algorithm>
#include <climits>
#include <functional>
#include <unordered_map>

namespace kit {
namespace world {

namespace pv = PolyVox;
using interface::VoxelTypeId;

static const char *ROLES[] = {"stone", "top", "filler", "water", "riverbed",
	"dust", "cave_floor", "cave_wall"};
// The generators' versions: an infinite world pins its generator's in the
// save, and a build whose version differs refuses it (a finite one is
// baked and does not care). 2: caves and decorations ([KIT] stage 4f)
static const int VERSION = 2;
static int generator_version(const ss_ &g)
{
	return g == "empty" || g == "flat" || g == "noise" || g == "valleys" ?
			VERSION : 0;
}
// [KIT_MATERIAL_SETS] A set's voxels and structures, and its biomes and
// a biome's decorations, at most
static const unsigned MAX_SET_VOXELS = 256, MAX_SET_BIOMES = 64;
// A finite voxel map's side at most (a heightmap's is its own)
static const int MAX_FINITE_VOXELS = 512;
// Sea round a finite map with a water border, and its bed under sea level
static const int SEA_BORDER = 16, SEA_BED = 4;
// [KIT_BEACH] How far over the sea's level a column's top is still the
// riverbed's (sand): the water's line backed by sand above it and below,
// not grass at the water's own level. A flat World has none (a flat ground
// at the sea's level would be all sand)
static const int BEACH = 2;
// An infinite world's load points round each player, in sections
static const int LOAD_XZ = 2, GEN_XZ = 2, LOAD_Y = 1;
// Caves: from this far under the top down to CAVE_DEEP under it
static const int CAVE_TOP = 5, CAVE_DEEP = 100;

// [KIT_TINT_PALETTE] "#rrggbb" -> 0xRRGGBB; false for anything else
inline bool parse_hex_color(const json::Value &v, uint32_t &out)
{
	const ss_ c = v.is_string() ? v.as_string() : "";
	bool hex = c.size() == 7 && c[0] == '#';
	for(size_t i = 1; hex && i < 7; i++)
		hex = isxdigit((unsigned char)c[i]);
	if(hex)
		out = (uint32_t)strtoul(c.c_str() + 1, nullptr, 16);
	return hex;
}
inline uint32_t lerp_color(uint32_t a, uint32_t b, double t)
{
	uint32_t out = 0;
	for(int shift = 16; shift >= 0; shift -= 8){
		const double ca = (a >> shift) & 0xff, cb = (b >> shift) & 0xff;
		out |= (uint32_t)(ca + (cb - ca) * t + 0.5) << shift;
	}
	return out;
}
// A tint palette: up to 16 colours, each maybe named
struct TintPalette
{
	sv_<uint32_t> colors;
	sv_<ss_> names;
	// [KIT_TINT_PALETTE] Kit's default (a material naming none): 0 its own
	// look, 1-5 towards brown, 6-10 from brown towards green, 11-15 from
	// green towards dark: dirty and weathered rather than darker
	static const TintPalette& standard()
	{
		static TintPalette p = []{
			TintPalette t;
			const uint32_t white = 0xffffff, brown = 0x7a5a3a,
					green = 0x6a7a40, dark = 0x2a2620;
			static const char *NAMES[16] = {"", "dusty", "very dusty", "muddy",
				"very muddy", "brown", "faintly mossy", "slightly mossy",
				"mossy", "very mossy", "green", "grimy", "very grimy", "sooty",
				"very sooty", "dark"};
			for(int i = 0; i < 16; i++){
				t.colors.push_back(i <= 5 ? lerp_color(white, brown, i / 5.0) :
						i <= 10 ? lerp_color(brown, green, (i - 5) / 5.0) :
						lerp_color(green, dark, (i - 10) / 5.0));
				t.names.push_back(NAMES[i]);
			}
			return t;
		}();
		return p;
	}
	// "tint" of a material set's voxel: ["#a", "#b"] (16 steps from the
	// first to the second), [entry...] (1 to 16, each "#rrggbb" or
	// {"color": "#rrggbb", "name": "savanna"}) or a palette's name in
	// `palettes` (the set's "palettes": {name: [entry...]})
	bool parse(const json::Value &j, const json::Value *palettes)
	{
		colors.clear();
		names.clear();
		if(j.is_string()){
			if(!palettes || !palettes->is_object() ||
					!palettes->get(j.as_string().c_str()).is_array())
				return false;
			return parse(palettes->get(j.as_string().c_str()), nullptr);
		}
		if(!j.is_array() || j.size() < 1 || j.size() > 16)
			return false;
		uint32_t a = 0, b = 0;
		if(j.size() == 2 && parse_hex_color(j.at(0u), a) &&
				parse_hex_color(j.at(1u), b)){
			for(int i = 0; i < 16; i++){
				colors.push_back(lerp_color(a, b, i / 15.0));
				names.push_back("");
			}
			return true;
		}
		for(unsigned i = 0; i < j.size(); i++){
			const json::Value &e = j.at(i);
			uint32_t c = 0;
			ss_ name;
			if(e.is_object()){
				if(!parse_hex_color(e.get("color"), c))
					return false;
				name = json::jstr(e, "name");
				if(name.size() > 32)
					return false;
			} else if(!parse_hex_color(e, c)){
				return false;
			}
			colors.push_back(c);
			names.push_back(name);
		}
		return true;
	}
};

struct Material
{
	ss_ top, side, bottom, kind = "solid";
	int layer = -1; // the heightmap's
	// [KIT] stage 4g: a cube's (solid, leaves): stops players, cut out
	// by its alpha; the light it emits
	bool solid = true, transparent = false;
	int light = 0;
	// For what moves on it (stage 4h's walker, ball and car): nothing reads
	// them yet. A heightmap's material's are its ground's
	double friction = 1;
	ss_ surface;
	// [KIT_SPOTS] Its glints under physical lighting (-1: by kind and name)
	double spots = -1, static_spots = -1;
	// [KIT_NORMALS] Its relief under physical lighting (-1: by kind and name)
	double bumpiness = -1;
	// [KIT_CTF] The blast strength it stands (c:explode: a cell goes to
	// air where the strength there is past it; 0: any blast)
	double blast_resist = 0;
	// [KIT_TOOLS_1] (stage 7c) Its material group (letters, digits and _;
	// "" none: dug at once and dropping nothing, as before) and its level
	// (0...15): a tool digs a group at its speed and drops it only at that
	// level or above
	ss_ group;
	int level = 0;
	// [KIT_CTF] What its dig drops by that rule: a voxel or item type's
	// name ("" itself)
	ss_ drop;
	// [KIT_SOUNDS] The sounds of its dig and its place: a project's sound's
	// name ("<author>/<name>"; "" none)
	ss_ sound_dig, sound_place;
	// [KIT_TINT_PALETTE] The tint field's palette (albedo multiplied),
	// entry 0 the material's own look: "tint" (TintPalette::parse), Kit's
	// standard one otherwise
	TintPalette tint = TintPalette::standard();
	// [KIT_ENVIRONMENT] Its look in a season (kit/environment's), by the
	// season's name: top, side, bottom textures (the client swaps them,
	// the voxels unchanged)
	sm_<ss_, std::array<ss_, 3>> seasons;

	// A set's voxel or a builder's ([KIT] stage 4g: the same fields);
	// palettes: the set's named ones
	bool parse(const json::Value &j, const json::Value *palettes = nullptr)
	{
		const ss_ t = json::jstr(j, "texture");
		top = json::jstr(j, "top", t);
		side = json::jstr(j, "side", t);
		bottom = json::jstr(j, "bottom", t);
		kind = json::jstr(j, "kind", "solid");
		layer = (int)json::jint(j, "heightmap", -1);
		solid = !j.get("solid").is_boolean() || j.get("solid").is_true();
		transparent = j.get("transparent").is_true();
		const json::Value &l = j.get("light");
		light = l.is_number() ? (int)l.as_number() : 0;
		const json::Value &f = j.get("friction");
		friction = f.is_number() ? f.as_number() : 1;
		const json::Value &br = j.get("blast_resist");
		blast_resist = br.is_number() ? br.as_number() : 0;
		surface = json::jstr(j, "surface");
		const json::Value &sp = j.get("spots"), &st = j.get("static_spots");
		spots = sp.is_number() ? sp.as_number() : -1;
		static_spots = st.is_number() ? st.as_number() : -1;
		const json::Value &bu = j.get("bumpiness");
		bumpiness = bu.is_number() ? bu.as_number() : -1;
		group = json::jstr(j, "group");
		sound_dig = json::jstr(j, "sound_dig");
		sound_place = json::jstr(j, "sound_place");
		drop = json::jstr(j, "drop");
		const double lv = j.get("level").is_number() ?
				j.get("level").as_number() : 0;
		level = lv >= 0 && lv <= 15 ? (int)lv : -1;
		seasons.clear();
		bool seasons_ok = true;
		const json::Value &ss = j.get("seasons");
		if(ss.is_object()){
			for(json::Iterator it(ss); it; ++it){
				const ss_ k = it.key();
				if(k != "spring" && k != "summer" && k != "autumn" &&
						k != "winter"){
					seasons_ok = false;
					continue;
				}
				const ss_ st = json::jstr(*it, "texture");
				std::array<ss_, 3> f = {{json::jstr(*it, "top",
						st.empty() ? top : st), json::jstr(*it, "side",
						st.empty() ? side : st), json::jstr(*it, "bottom",
						st.empty() ? bottom : st)}};
				seasons[k] = f;
			}
		} else if(!ss.is_undefined()){
			seasons_ok = false;
		}
		const json::Value &tr = j.get("tint");
		bool tint_ok = tr.is_undefined() || tr.is_null();
		if(!tint_ok)
			tint_ok = tint.parse(tr, palettes);
		bool tag_ok = surface.size() <= 32;
		for(char c : surface)
			tag_ok = tag_ok && (isalnum((unsigned char)c) || c == '_');
		tag_ok = tag_ok && group.size() <= 32 && level >= 0 && lv == level;
		for(char c : group)
			tag_ok = tag_ok && (isalnum((unsigned char)c) || c == '_');
		for(const ss_ *sn : {&sound_dig, &sound_place, &drop}){
			tag_ok = tag_ok && sn->size() <= 129 && (sn->empty() ||
					std::count(sn->begin(), sn->end(), '/') == 1);
			for(char c : *sn)
				tag_ok = tag_ok && (isalnum((unsigned char)c) || c == '_' ||
						c == '/');
		}
		return !top.empty() && !side.empty() && !bottom.empty() &&
				layer >= -1 && layer < heightmap::MAX_MATERIALS &&
				light >= 0 && light <= 15 && (kind == "solid" ||
				kind == "water" || kind == "leaves" || kind == "plant" ||
				kind == "glass") &&
				friction >= 0 && friction <= 10 && blast_resist >= 0 &&
				blast_resist <= 1000 && tag_ok && tint_ok &&
				seasons_ok && spots <= 1 && static_spots <= 1 &&
				(spots >= 0 || !sp.is_number()) &&
				(static_spots >= 0 || !st.is_number()) && bumpiness <= 1 &&
				(bumpiness >= 0 || !bu.is_number());
	}

	// Its properties as a builder's row has them, for a palette and
	// Interface::voxel_type()
	json::Value properties() const
	{
		json::Value v = json::object();
		v.set("kind", kind);
		v.set("solid", solid);
		v.set("transparent", transparent);
		v.set("light", (int64_t)light);
		v.set("friction", friction);
		v.set("blast_resist", blast_resist);
		v.set("surface", surface);
		if(spots >= 0)
			v.set("spots", spots);
		if(static_spots >= 0)
			v.set("static_spots", static_spots);
		if(bumpiness >= 0)
			v.set("bumpiness", bumpiness);
		v.set("group", group);
		v.set("level", (int64_t)level);
		v.set("sound_dig", sound_dig);
		v.set("sound_place", sound_place);
		v.set("drop", drop);
		// [KIT_TINT_PALETTE] its colours and their names ("" unnamed)
		json::Value t = json::array(), tn = json::array();
		for(size_t i = 0; i < tint.colors.size(); i++){
			char b[8];
			snprintf(b, sizeof b, "#%06x", (unsigned)(tint.colors[i] & 0xffffff));
			t.append(ss_(b));
			tn.append(i < tint.names.size() ? tint.names[i] : ss_());
		}
		v.set("tint", t);
		v.set("tint_names", tn);
		// The shapes it has ([KIT_VOXEL_FORMAT]): a solid cube's
		v.set("shapes", has_shapes());
		return v;
	}

	// [KIT_VOXEL_FORMAT] Whether its shapes are made (a solid cube's, a
	// glass one's too)
	bool has_shapes() const
	{
		return (kind == "solid" || kind == "glass") && solid && !transparent;
	}

	// Its definition in a voxel registry
	// simplified: light is the definition's light_source, which a world
	// maintaining lamp light reads; Workbench's does not (its format has
	// no light plane), so it draws nothing different. The upgrade:
	// light_lamp in the app's format, voxelworld's set_light_maintained
	// and a client technique lit by the vertex colours
	// A whole word of a name's (between '/' and '_'): kit/core is no ore,
	// kit/red_sand is sand
	static bool name_word(const ss_ &name, const char *w)
	{
		const size_t n = strlen(w);
		for(size_t i = name.find(w); i != ss_::npos; i = name.find(w, i + 1))
			if((i == 0 || name[i - 1] == '/' || name[i - 1] == '_') &&
					(i + n == name.size() || name[i + n] == '_'))
				return true;
		return false;
	}

	// [KIT_SPOTS] Its glints, moving and still: its own, else by kind and
	// name as luanti_client's surface.lua guesses skeldat's
	// simplified: a few names; materials.json's fields for the rest
	void glints(const ss_ &name, float &moving, float &still) const
	{
		auto has = [&](const char *w){ return name_word(name, w); };
		moving = kind == "water" ? 0.05f : kind == "leaves" ? 0.03f : 0;
		still = kind == "glass" ? 0.03f : 0;
		if(has("sand"))
			still = 0.04f;
		else if(has("snow") || has("diamond") || has("emerald") ||
				has("crystal") || has("gem") || has("mese"))
			still = 0.06f;
		else if(has("ice") || has("ore") || has("with"))
			still = 0.05f;
		if(spots >= 0)
			moving = (float)spots;
		if(static_spots >= 0)
			still = (float)static_spots;
	}

	// [KIT_NORMALS] Its relief: its own, else by kind and name as
	// surface.lua's (the atlas's normal map, its brightness as height)
	float relief(const ss_ &name) const
	{
		if(bumpiness >= 0)
			return (float)bumpiness;
		auto has = [&](const char *w){ return name_word(name, w); };
		if(kind == "water" || kind == "glass")
			return 0;
		if(kind == "leaves" || kind == "plant" || has("snow") || has("clay"))
			return 0.2f;
		if(has("ice"))
			return 0.1f;
		if(has("sand"))
			return 0.6f;
		return 1;
	}

	interface::VoxelDefinition definition(const ss_ &name) const
	{
		interface::VoxelDefinition def;
		def.name.block_name = name;
		float moving = 0, still = 0;
		glints(name, moving, still);
		const float bump = relief(name);
		// The faces: +y, -y, then the sides
		for(int f = 0; f < 6; f++){
			auto &seg = def.textures[f];
			seg.resource_name = f == 0 ? top : f == 1 ? bottom : side;
			seg.total_segments = Urho3D::IntVector2(1, 1);
			seg.select_segment = Urho3D::IntVector2(0, 0);
			seg.spots = moving;
			seg.static_spots = still;
			seg.bumpiness = bump;
			// [KIT_RELIEF_TINT] its default look (palette entry 0) as the
			// shader tints it: whole for what draws through KITTINT alone
			// (leaves, plants, water, glass), by the alpha for a solid cube
			// (KITTINTMASK), so the relief is of the colour drawn.
			// simplified: entry 0's; another entry's relief is the same
			if(!tint.colors.empty() && (tint.colors[0] & 0xffffff) != 0xffffff){
				seg.tint = tint.colors[0] & 0xffffff;
				seg.tint_mode = kind == "solid" && !transparent ?
						interface::AtlasSegmentDefinition::TINT_BY_ALPHA :
						interface::AtlasSegmentDefinition::TINT_WHOLE;
			}
		}
		def.light_source = (uint8_t)light;
		def.tint_palette = tint.colors;
		if(kind == "water"){
			// Passive: no flow (user, 2026-10-30)
			def.edge_material_id = 10;
			def.translucent = true;
			def.transmits_light = true;
		} else if(kind == "glass"){
			// [KIT_TINT_MATERIALS] Blended as water is, a cube that stops
			// players; its own edge material, so glass against glass draws
			// no face between
			def.edge_material_id = 11;
			def.physically_solid = solid;
			def.translucent = true;
			def.transmits_light = true;
		} else if(kind == "plant"){
			// [KIT] stage 4f: Luanti's plantlike, two quads a cell
			// across crossed on its diagonals, both sides drawn, cut out
			// by the texture's alpha; walked through
			def.face_draw_type = interface::FaceDrawType::NEVER;
			def.edge_material_id = interface::EDGEMATERIALID_EMPTY;
			def.alpha_masked = true;
			def.transmits_light = true;
			def.shape_double_sided = true;
			const float r = 0.5f * 0.70710678f;
			for(int i = 0; i < 2; i++){
				const float az = i ? r : -r;
				const float pts[4][3] = {{-r, -0.5f, az}, {r, -0.5f, -az},
					{r, 0.5f, -az}, {-r, 0.5f, az}};
				const float uv[4][2] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};
				interface::VoxelQuad q;
				for(int k = 0; k < 4; k++){
					for(int c = 0; c < 3; c++)
						q.p[k][c] = pts[k][c];
					q.uv[k][0] = uv[k][0];
					q.uv[k][1] = uv[k][1];
				}
				def.shape.push_back(q);
			}
		} else {
			def.edge_material_id = interface::EDGEMATERIALID_GROUND;
			def.physically_solid = solid;
			def.alpha_masked = kind == "leaves" || transparent;
			def.transmits_light = def.alpha_masked;
			// [KIT_LEAF_FACES] A cut-out cube draws all its faces, as
			// skeldat's leaves (Luanti's allfaces): a canopy thick with its
			// inner faces, fuller in its shadow, and the ground beside it
			// drawn (the mesher's LEAF_SOLID_FACES; with the edge material
			// alone it was culled and seen through)
			if(def.alpha_masked)
				def.face_draw_type = interface::FaceDrawType::ALWAYS;
		}
		return def;
	}
};

// **[KIT_VOXEL_FORMAT] Shapes** (stage 4g2): a solid cube material's shape
// types, made where the material is registered and named
// "<material>:<shape>" (ids stay stable in a save: it names them). A
// shape's param is its facing: 0...3 a quarter turn about +Y each (Luanti's
// facedir 0...3: the shape's back to +z, +x, -z, -x -- a stair's high side
// away from a player who looked that way placing it), 4...7 the same upside
// down (facedir 20...23; a slab at the cell's top, a stair hung from the
// ceiling). Their quads wear the material's textures cut to the boxes
// (luanti/shapes.h); they stop a player by their boxes (the variants'
// collision boxes, Kit's movement's cells' boxes) and let light through
// (the sky's, where it is maintained). The registry's id of a shape
// knows its material by the name: material_of().
struct ShapeDef
{
	const char *name;
	// x0 y0 z0 x1 y1 z1 each, the voxel's -0.5...0.5, facing 0
	sv_<float> boxes;
};
inline const sv_<ShapeDef>& shapes()
{
	static const sv_<ShapeDef> s = {
		{"slab", {-0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f}},
		{"stair", {-0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f,
			-0.5f, 0.0f, 0.0f, 0.5f, 0.5f, 0.5f}},
		{"inner_stair", {-0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f,
			-0.5f, 0.0f, 0.0f, 0.5f, 0.5f, 0.5f,
			-0.5f, 0.0f, -0.5f, 0.0f, 0.5f, 0.0f}},
		{"outer_stair", {-0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f,
			-0.5f, 0.0f, 0.0f, 0.0f, 0.5f, 0.5f}},
		{"panel", {-0.5f, -0.5f, 0.0f, 0.5f, 0.5f, 0.5f}},
		{"pillar", {-0.25f, -0.5f, -0.25f, 0.25f, 0.5f, 0.25f}},
	};
	return s;
}
static const int SHAPE_PARAMS = 8;
// The facedir of a shape's param
inline uint8_t shape_facedir(int param)
{
	param &= 7;
	return (uint8_t)(param < 4 ? param : 20 + (param - 4));
}
// Luanti's dir_to_facedir: the facing a look along (dx, dz) places
inline int shape_param_of_look(double dx, double dz, bool upside = false)
{
	int f = std::fabs(dx) > std::fabs(dz) ? (dx < 0 ? 3 : 1) :
			(dz < 0 ? 2 : 0);
	return f + (upside ? 4 : 0);
}
// "kit/stone:stair" -> "kit/stone" (a name with no shape: itself)
inline ss_ material_of(const ss_ &name)
{
	const size_t c = name.rfind(':');
	if(c == ss_::npos)
		return name;
	const ss_ sh = name.substr(c + 1);
	for(const ShapeDef &d : shapes())
		if(sh == d.name)
			return name.substr(0, c);
	return name;
}
// The shape of a name ("" for a full cube)
inline ss_ shape_of(const ss_ &name)
{
	const ss_ m = material_of(name);
	return m.size() == name.size() ? ss_() : name.substr(m.size() + 1);
}
// The shape types of a cube's definition `cube` (a solid one's)
inline sv_<interface::VoxelDefinition> shape_definitions(
		const interface::VoxelDefinition &cube)
{
	sv_<interface::VoxelDefinition> out;
	for(const ShapeDef &sd : shapes()){
		interface::VoxelDefinition def = cube;
		def.id = interface::VOXELTYPEID_UNDEFINED;
		def.name.block_name = cube.name.block_name+":"+sd.name;
		def.face_draw_type = interface::FaceDrawType::NEVER;
		def.edge_material_id = interface::EDGEMATERIALID_EMPTY;
		def.transmits_light = true;
		def.alpha_masked = false;
		def.shape.clear();
		def.variants.clear();
		for(int p = 0; p < SHAPE_PARAMS; p++){
			sv_<interface::VoxelQuad> q;
			for(size_t b = 0; b + 6 <= sd.boxes.size(); b += 6)
				luanti_shapes::add_box_quads(q, sd.boxes[b], sd.boxes[b + 1],
						sd.boxes[b + 2], sd.boxes[b + 3], sd.boxes[b + 4],
						sd.boxes[b + 5]);
			interface::VoxelVariant v;
			const uint8_t fd = shape_facedir(p);
			luanti_shapes::turn_quads(q, fd, v.shape);
			luanti_shapes::turn_boxes(sd.boxes, fd, v.collision_boxes);
			v.selection_boxes = v.collision_boxes;
			def.variants.push_back(v);
		}
		for(int p = 0; p < 256; p++)
			def.variant_of_param[p] = (uint8_t)(p & 7);
		def.shape = def.variants[0].shape;
		def.collision_boxes = def.variants[0].collision_boxes;
		def.selection_boxes = def.collision_boxes;
		out.push_back(def);
	}
	return out;
}

// [KIT] stage 4f: a voxel structure (a decoration's look): sx x sy x sz
// cells, x fastest, then z, then y; "" leaves a cell as it is. Its origin
// is the cell standing on the ground's top cell
struct Structure
{
	int sx = 1, sy = 1, sz = 1, ox = 0, oy = 0, oz = 0;
	sv_<ss_> cells;
};

// A biome's decoration: a structure, where, and the chance a column (a
// cave's: a floor or wall cell) has it
struct Decoration
{
	ss_ structure, on = "top";
	double density = 0;
};

struct Biome
{
	sm_<ss_, ss_> roles;
	int filler_depth = 3;
	sv_<Decoration> decorations;
};

struct MaterialSet
{
	ss_ name;
	sm_<ss_, Material> voxels;
	sm_<ss_, ss_> fallback;
	sm_<ss_, Biome> biomes;
	sm_<ss_, Structure> structures;

	static bool parse_structure(const json::Value &j, Structure &s, ss_ &why)
	{
		const ss_ one = json::jstr(j, "voxel");
		if(!one.empty()){
			s.cells = {one};
			return true;
		}
		const json::Value &vs = j.get("voxels"), &ls = j.get("layers"),
				&o = j.get("origin");
		if(!vs.is_object() || !ls.is_array() || ls.size() == 0 ||
				!ls.at(0).is_array() || ls.at(0).size() == 0 ||
				!ls.at(0).at(0).is_string()){
			why = "a voxel, or voxels and layers";
			return false;
		}
		s.sy = (int)ls.size();
		s.sz = (int)ls.at(0).size();
		s.sx = (int)ls.at(0).at(0).as_string().size();
		if(s.sx > 16 || s.sy > 32 || s.sz > 16){
			why = "16 x 32 x 16 cells at most";
			return false;
		}
		s.cells.assign((size_t)s.sx * s.sy * s.sz, "");
		for(int y = 0; y < s.sy; y++){
			const json::Value &layer = ls.at(y);
			if(!layer.is_array() || (int)layer.size() != s.sz){
				why = "layer "+itos(y)+": "+itos(s.sz)+" rows";
				return false;
			}
			for(int z = 0; z < s.sz; z++){
				const ss_ r = layer.at(z).is_string() ? layer.at(z).as_string() :
						ss_();
				if((int)r.size() != s.sx){
					why = "layer "+itos(y)+" row "+itos(z)+": "+itos(s.sx)+
							" letters";
					return false;
				}
				for(int x = 0; x < s.sx; x++){
					if(r[x] == '.' || r[x] == ' ')
						continue;
					const ss_ v = json::jstr(vs, ss_(1, r[x]).c_str());
					if(v.empty()){
						why = "no voxel for "+ss_(1, r[x]);
						return false;
					}
					s.cells[((size_t)y * s.sz + z) * s.sx + x] = v;
				}
			}
		}
		if(o.is_array() && o.size() == 3 && o.at(0).is_number() &&
				o.at(1).is_number() && o.at(2).is_number()){
			s.ox = (int)o.at(0).as_number();
			s.oy = (int)o.at(1).as_number();
			s.oz = (int)o.at(2).as_number();
		}
		if(s.ox < 0 || s.ox >= s.sx || s.oy < 0 || s.oy >= s.sy ||
				s.oz < 0 || s.oz >= s.sz){
			why = "the origin is one of its cells";
			return false;
		}
		return true;
	}

	bool parse(const json::Value &j, ss_ &why)
	{
		if(!j.is_object() || json::jstr(j, "format") != "kit_materials"){
			why = "not a kit_materials set";
			return false;
		}
		name = json::jstr(j, "author")+"/"+json::jstr(j, "name");
		const json::Value &vs = j.get("voxels");
		// [KIT_MATERIAL_SETS] an installed package's set is untrusted
		if(vs.size() > MAX_SET_VOXELS || j.get("structures").size() >
				MAX_SET_VOXELS || j.get("biomes").size() > MAX_SET_BIOMES){
			why = itos(MAX_SET_VOXELS)+" voxels, "+itos(MAX_SET_VOXELS)+
					" structures and "+itos(MAX_SET_BIOMES)+" biomes at most";
			return false;
		}
		// [KIT_TINT_PALETTE] palettes its voxels share by name
		const json::Value &pals = j.get("palettes");
		if(vs.is_object())
			for(json::Iterator it(vs); it; ++it){
				Material m;
				if(!m.parse(*it, &pals)){
					why = "voxel "+it.key()+": a texture, a kind, light 0...15, "
							"friction 0...10, a surface tag and a tint (two "
							"colours, 1 to 16 entries or a palette's name)";
					return false;
				}
				voxels[it.key()] = m;
			}
		const json::Value &fb = j.get("fallbacks");
		if(fb.is_object())
			for(json::Iterator it(fb); it; ++it)
				if((*it).is_string())
					fallback[it.key()] = (*it).as_string();
		const json::Value &ss = j.get("structures");
		if(ss.is_object())
			for(json::Iterator it(ss); it; ++it){
				Structure st;
				ss_ swhy;
				if(!parse_structure(*it, st, swhy)){
					why = "structure "+it.key()+": "+swhy;
					return false;
				}
				structures[it.key()] = st;
			}
		const json::Value &bs = j.get("biomes");
		if(!bs.is_object() || bs.size() == 0){
			why = "no biomes";
			return false;
		}
		for(json::Iterator it(bs); it; ++it){
			Biome b;
			b.filler_depth = (int)std::max<int64_t>(0, std::min<int64_t>(16,
					json::jint(*it, "filler_depth", 3)));
			for(const char *r : ROLES){
				const ss_ v = json::jstr(*it, r);
				if(!v.empty())
					b.roles[r] = v;
			}
			const json::Value &ds = (*it).get("decorations");
			if(ds.size() > MAX_SET_BIOMES){
				why = "biome "+it.key()+": "+itos(MAX_SET_BIOMES)+
						" decorations at most";
				return false;
			}
			for(unsigned i = 0; ds.is_array() && i < ds.size(); i++){
				Decoration d;
				d.structure = json::jstr(ds.at(i), "structure");
				d.on = json::jstr(ds.at(i), "on", "top");
				const json::Value &dv = ds.at(i).get("density");
				d.density = dv.is_number() ? dv.as_number() : 0;
				if(!structures.count(d.structure) || (d.on != "top" &&
						d.on != "water" && d.on != "cave" &&
						d.on != "cave_wall")){
					why = "biome "+it.key()+": decoration "+itos(i)+
							": a structure of the set, on top, water, cave "
							"or cave_wall";
					return false;
				}
				b.decorations.push_back(d);
			}
			biomes[it.key()] = b;
		}
		return true;
	}

	// The voxel a role is in a biome, along its fallbacks ("": none)
	ss_ resolve(const Biome &b, ss_ role) const
	{
		for(int i = 0; i < 8 && !role.empty(); i++){
			auto it = b.roles.find(role);
			if(it != b.roles.end())
				return it->second;
			auto f = fallback.find(role);
			role = f == fallback.end() ? "" : f->second;
		}
		return "";
	}
};

// [KIT_MATERIAL_SETS] A set extending another (materials.json's "extends"):
// `over` on `base`, the later winning per voxel, palette, fallback,
// structure and, in a biome both have, per role (and filler_depth and
// decorations, each a key of the biome)
inline json::Value merge_sets(const json::Value &base, const json::Value &over)
{
	json::Value out = base.deepcopy();
	for(const char *k : {"voxels", "palettes", "fallbacks", "structures",
			"biomes"}){
		const json::Value &o = over.get(k);
		if(!o.is_object())
			continue;
		json::Value d = out.get(k).is_object() ? out.get(k).deepcopy() :
				json::object();
		for(json::Iterator it(o); it; ++it){
			json::Value v = (*it).deepcopy();
			const json::Value &was = d.get(it.key());
			if(ss_(k) == "biomes" && was.is_object() && v.is_object()){
				json::Value b = was.deepcopy();
				for(json::Iterator r(v); r; ++r)
					b.set(r.key(), *r);
				v = b;
			}
			d.set(it.key(), v);
		}
		out.set(k, d);
	}
	for(const char *k : {"author", "name"})
		out.set(k, json::Value(json::jstr(over, k).c_str()));
	return out;
}

// The World's parameters (types/terrain.lua)
struct Params
{
	ss_ generator = "flat", biome, size = "finite", border = "void",
			surface = "voxels";
	uint32_t seed = 0;
	int level = 0, height = 12, spread = 48, sea_level = 0, width = 64,
			depth = 64;
	// [KIT] stage 4f: caves and the biome's decorations
	bool caves = false, decorations = true;

	// A column whose top is under this is the riverbed's (KIT_BEACH)
	int sand_to() const
	{
		return sea_level + (generator == "flat" ? 0 : BEACH);
	}

	void from(const json::Value &j)
	{
		generator = json::jstr(j, "generator", generator);
		biome = json::jstr(j, "biome");
		size = json::jstr(j, "size", size);
		border = json::jstr(j, "border", border);
		surface = json::jstr(j, "surface", surface);
		auto num = [&](const char *k, int &out){
			const json::Value &v = j.get(k);
			if(v.is_number())
				out = (int)std::floor(v.as_number());
		};
		const json::Value &sv = j.get("seed");
		seed = sv.is_number() ? (uint32_t)(int64_t)sv.as_number() : 0;
		num("level", level);
		num("height", height);
		num("spread", spread);
		num("sea_level", sea_level);
		num("width", width);
		num("depth", depth);
		spread = std::max(spread, 1);
		caves = j.get("caves").is_true();
		decorations = !j.get("decorations").is_boolean() ||
				j.get("decorations").is_true();
	}
	bool finite() const { return size != "infinite"; }
	bool heightmap() const { return surface == "heightmap"; }
	bool with_caves() const { return caves; }
	bool with_decorations() const { return decorations; }
	int x0() const { return -width / 2; }
	int z0() const { return -depth / 2; }
	bool in_map(int x, int z) const
	{
		return !finite() || (x >= x0() && x < x0() + width &&
				z >= z0() && z < z0() + depth);
	}
};

// The ground's height over columns: continuous (a heightmap's), and the
// top cell of a voxel column (its floor). Asked from worldgen's thread
struct Heights
{
	Params p;
	up_<luanti_mapgen::SurfaceQuery> valleys;

	float at(float x, float z)
	{
		if(p.generator == "noise")
			return p.level + p.height * interface::noise::fbm2(
					x / p.spread, z / p.spread, p.seed, 4, 0.5f);
		if(p.generator == "valleys" && valleys){
			float h = 0;
			valleys->surface_map(x, z, 1, 1, 1, &h);
			return h + p.level;
		}
		if(p.generator == "empty")
			return (float)INT_MIN / 2;
		return (float)p.level;
	}
	// The top cells of w x d columns from (x0, z0), x fastest
	void tops(int x0, int z0, int w, int d, sv_<int> &out)
	{
		out.resize((size_t)w * d);
		if(p.generator == "valleys" && valleys){
			sv_<float> h((size_t)w * d);
			valleys->surface_map(x0, z0, 1, w, d, h.data());
			for(size_t i = 0; i < out.size(); i++)
				out[i] = (int)std::floor(h[i] + p.level);
			return;
		}
		for(int z = 0; z < d; z++)
			for(int x = 0; x < w; x++)
				out[(size_t)z * w + x] = p.generator == "empty" ? INT_MIN / 2 :
						(int)std::floor(at(x0 + x, z0 + z) + 0.5f);
	}
};

// A structure as voxel ids (0: a cell left as it is)
struct StructIds
{
	ss_ name;
	int sx = 1, sy = 1, sz = 1, ox = 0, oy = 0, oz = 0;
	sv_<VoxelTypeId> ids;
	int reach() const
	{
		return std::max(std::max(ox, sx - 1 - ox), std::max(oz, sz - 1 - oz));
	}
	// Its cells turned by quarter turns about its origin, as offsets from
	// where the origin goes: f(dx, dy, dz, id)
	template<typename F> void each(int turns, F f) const
	{
		for(int y = 0; y < sy; y++)
		for(int z = 0; z < sz; z++)
		for(int x = 0; x < sx; x++){
			const VoxelTypeId id = ids[((size_t)y * sz + z) * sx + x];
			if(!id)
				continue;
			int dx = x - ox, dz = z - oz, t;
			for(int i = 0; i < (turns & 3); i++)
				t = dx, dx = -dz, dz = t;
			f(dx, y - oy, dz, id);
		}
	}
	VoxelTypeId first() const
	{
		for(VoxelTypeId id : ids)
			if(id)
				return id;
		return 0;
	}
};

// A decoration: its structure (an index of Ids::structs), where ('t' top,
// 'w' under water, 'c' a cave's floor, 'v' a cave's wall) and its density
struct DecorIds
{
	size_t s = 0;
	char on = 't';
	double density = 0;
};

// A biome's voxels by role, and its decorations
struct BiomeIds
{
	VoxelTypeId top = 0, filler = 0, stone = 0, water = 0, riverbed = 0,
			cave_floor = 0, cave_wall = 0;
	int filler_depth = 3;
	sv_<DecorIds> decors;
	// How far its surface decorations reach sideways from their columns
	int reach = 0;
};

// The voxel ids a generator writes: the biome's roles, air, structures
struct Ids: public BiomeIds
{
	VoxelTypeId air = 0;
	sv_<StructIds> structs;
};

// A biome's roles and decorations as ids (id(name): 0 if not registered)
static void resolve_biome(const MaterialSet &ms, const Biome &b,
		std::function<VoxelTypeId(const ss_&)> id, sv_<StructIds> &structs,
		BiomeIds &out)
{
	auto role = [&](const char *r){
		const ss_ v = ms.resolve(b, r);
		return v.empty() ? (VoxelTypeId)0 : id(v);
	};
	out.top = role("top");
	out.filler = role("filler");
	out.stone = role("stone");
	out.water = role("water");
	out.riverbed = role("riverbed");
	out.cave_floor = role("cave_floor");
	out.cave_wall = role("cave_wall");
	out.filler_depth = b.filler_depth;
	out.decors.clear();
	out.reach = 0;
	for(const Decoration &d : b.decorations){
		size_t si = structs.size();
		for(size_t i = 0; i < structs.size(); i++)
			if(structs[i].name == d.structure)
				si = i;
		if(si == structs.size()){
			const Structure &st = ms.structures.at(d.structure);
			StructIds s;
			s.name = d.structure;
			s.sx = st.sx, s.sy = st.sy, s.sz = st.sz;
			s.ox = st.ox, s.oy = st.oy, s.oz = st.oz;
			for(const ss_ &c : st.cells)
				s.ids.push_back(c.empty() ? 0 : id(c));
			structs.push_back(s);
		}
		DecorIds di;
		di.s = si;
		di.on = d.on == "top" ? 't' : d.on == "water" ? 'w' : d.on == "cave" ?
				'c' : 'v';
		di.density = d.density;
		out.decors.push_back(di);
		if(di.on == 't' || di.on == 'w')
			out.reach = std::max(out.reach, structs[si].reach());
	}
}

// ---- Deterministic chance by the seed and a position
static inline uint32_t mix32(uint32_t h)
{
	h ^= h >> 16;
	h *= 0x7feb352du;
	h ^= h >> 15;
	h *= 0x846ca68bu;
	h ^= h >> 16;
	return h;
}
static inline uint32_t hash_at(uint32_t seed, int x, int y, int z, uint32_t k)
{
	uint32_t h = mix32(seed + 0x9e3779b9u * (k + 1));
	h = mix32(h ^ (uint32_t)x);
	h = mix32(h ^ ((uint32_t)z * 0x85ebca6bu));
	return mix32(h ^ ((uint32_t)y * 0xc2b2ae35u));
}
static inline double unit(uint32_t h)
{
	return (h >> 8) / 16777216.0;
}
// The decorate brush's own draw: another than the generator's, so a
// stroke over generated ground adds to it
static const uint32_t BRUSH_SALT = 0x5bd1e995u;

// The surface decoration a column carries, by its top and the sea: the
// index of b.decors (-1: none) and its quarter turns. mult scales the
// densities (the decorate brush's strength)
static int pick_surface(const BiomeIds &b, uint32_t seed, int x, int z,
		int top, const Params &p, double mult, int &turns)
{
	for(size_t k = 0; k < b.decors.size(); k++){
		const DecorIds &d = b.decors[k];
		if(!((d.on == 't' && top >= p.sand_to()) ||
				(d.on == 'w' && top < p.sea_level)))
			continue;
		const uint32_t h = hash_at(seed, x, 0, z, (uint32_t)k);
		if(unit(h) < d.density * mult){
			turns = (int)(h >> 3) & 3;
			return (int)k;
		}
	}
	return -1;
}

// A cave's decoration at a floor ('c') or wall ('v') cell: its voxel (0:
// none)
static VoxelTypeId pick_cave(const BiomeIds &b, const sv_<StructIds> &structs,
		uint32_t seed, int x, int y, int z, char on, double mult)
{
	for(size_t k = 0; k < b.decors.size(); k++){
		const DecorIds &d = b.decors[k];
		if(d.on == on && unit(hash_at(seed, x, y, z, (uint32_t)k + 64)) <
				d.density * mult)
			return structs[d.s].first();
	}
	return 0;
}

// Whether a cell is a cave's: CAVE_TOP..CAVE_DEEP under its column's top,
// and with `open` ([KIT_CAVE_MOUTHS]) a tunnel's up through the soil to
// the top itself, where a tunnel rises to the surface: a mouth (a cavern
// stays under CAVE_TOP)
static bool cave_at(uint32_t seed, int x, int y, int z, int top,
		bool open = false)
{
	if(y > (open ? top : top - CAVE_TOP) || y < top - CAVE_DEEP)
		return false;
	using interface::noise::fbm3;
	const float fx = x / 28.0f, fy = y / 18.0f, fz = z / 28.0f;
	const float a = fbm3(fx, fy, fz, seed + 1101, 2, 0.5f);
	const float b = fbm3(fx, fy, fz, seed + 2202, 2, 0.5f);
	if(a * a + b * b < 0.012f)
		return true;
	if(y > top - CAVE_TOP)
		return false;
	return fbm3(x / 44.0f, y / 22.0f, z / 44.0f, seed + 3303, 2, 0.5f) > 0.66f;
}

// [KIT_CAVE_MOUTHS] Whether a column's caves may open to its top: a voxel
// World's with caves, the column dry (not under the sea: a hole there would
// be an air pocket under the water)
static bool cave_opens(const Params &p, int top)
{
	return p.with_caves() && !p.heightmap() && top >= p.sea_level;
}
// Whether a column's top cell is a cave mouth's (carved): no surface
// decoration stands on it
static bool cave_mouth(const Params &p, int x, int z, int top)
{
	return cave_opens(p, top) && cave_at(p.seed, x, top, z, top, true);
}

struct Generator: public worldgen::GeneratorInterface
{
	Params p;
	Ids ids;
	up_<Heights> h;
	// The highest ground of a finite map (its wall's top)
	int max_top = 0;

	void generate(main_context::SceneReference,
			const pv::Vector3DInt16 &, interface::VoxelVolume &volume)
	{
		const pv::Region r = volume.getEnclosingRegion();
		const pv::Vector3DInt32 lc = r.getLowerCorner(), uc = r.getUpperCorner();
		const int w = uc.getX() - lc.getX() + 1, d = uc.getZ() - lc.getZ() + 1,
				hy = uc.getY() - lc.getY() + 1;
		const bool decorate = p.with_decorations() && !ids.decors.empty();
		const bool caves = p.with_caves();
		// The tops round the section too: the decorations reaching in, the
		// caves' walls
		const int R = std::max(decorate ? ids.reach : 0, caves ? 1 : 0);
		const int ew = w + 2 * R, ed = d + 2 * R;
		sv_<int> tops;
		h->tops(lc.getX() - R, lc.getZ() - R, ew, ed, tops);
		auto top_at = [&](int x, int z){
			return tops[(size_t)(z - lc.getZ() + R) * ew + (x - lc.getX() + R)];
		};
		// The caves, a cell round the section
		sv_<uint8_t> cave;
		auto ci = [&](int x, int y, int z){
			return ((size_t)(y - lc.getY() + 1) * (d + 2) + (z - lc.getZ() + 1)) *
					(w + 2) + (x - lc.getX() + 1);
		};
		bool any_cave = false;
		if(caves){
			cave.assign((size_t)(w + 2) * (hy + 2) * (d + 2), 0);
			for(int z = lc.getZ() - 1; z <= uc.getZ() + 1; z++)
			for(int x = lc.getX() - 1; x <= uc.getX() + 1; x++){
				if(!p.in_map(x, z))
					continue;
				const int t = top_at(x, z);
				const bool open = cave_opens(p, t);
				const int y0 = std::max(lc.getY() - 1, t - CAVE_DEEP);
				const int y1 = std::min(uc.getY() + 1, open ? t : t - CAVE_TOP);
				for(int y = y0; y <= y1; y++)
					if(cave_at(p.seed, x, y, z, t, open)){
						cave[ci(x, y, z)] = 1;
						any_cave = true;
					}
			}
		}
		auto is_cave = [&](int x, int y, int z){
			return any_cave && cave[ci(x, y, z)];
		};
		using interface::VoxelInstance;
		for(int z = lc.getZ(); z <= uc.getZ(); z++)
		for(int x = lc.getX(); x <= uc.getX(); x++){
			int top = top_at(x, z);
			bool wall = false, sea = p.sea_level > top;
			if(!p.in_map(x, z)){
				// Past the map: its border, then nothing
				const int ox = x < p.x0() ? p.x0() - x : x - (p.x0() + p.width - 1);
				const int oz = z < p.z0() ? p.z0() - z : z - (p.z0() + p.depth - 1);
				const int out = std::max(ox, oz);
				if(p.border == "wall" && out == 1){
					wall = true;
				} else if(p.border == "water" && out <= SEA_BORDER){
					top = p.sea_level - SEA_BED;
					sea = true;
				} else {
					top = INT_MIN / 2;
					sea = false;
				}
			}
			for(int y = lc.getY(); y <= uc.getY(); y++){
				VoxelTypeId v = ids.air;
				if(wall)
					v = y <= max_top + 4 ? ids.stone : ids.air;
				else if(y > top)
					v = sea && y <= p.sea_level ? ids.water : ids.air;
				else if(is_cave(x, y, z))
					v = ids.air;
				else if(y == top)
					v = top < p.sand_to() ? ids.riverbed : ids.top;
				else if(y > top - 1 - ids.filler_depth)
					v = top < p.sand_to() ? ids.riverbed : ids.filler;
				else if(any_cave && ids.cave_floor && is_cave(x, y + 1, z))
					v = ids.cave_floor;
				else if(any_cave && ids.cave_wall && (is_cave(x, y - 1, z) ||
						is_cave(x - 1, y, z) || is_cave(x + 1, y, z) ||
						is_cave(x, y, z - 1) || is_cave(x, y, z + 1)))
					v = ids.cave_wall;
				else
					v = ids.stone;
				volume.setVoxelAt(x, y, z, VoxelInstance(v));
			}
		}
		if(!p.with_decorations())
			return;
		// A cave's decorations: on its floor, in its wall
		if(any_cave)
			for(int y = lc.getY(); y <= uc.getY(); y++)
			for(int z = lc.getZ(); z <= uc.getZ(); z++)
			for(int x = lc.getX(); x <= uc.getX(); x++){
				const uint32_t v = volume.getVoxelAt(x, y, z).data;
				VoxelTypeId put = 0;
				if(is_cave(x, y, z)){
					if(!is_cave(x, y - 1, z))
						put = pick_cave(ids, ids.structs, p.seed, x, y, z, 'c', 1);
				} else if(v != ids.air && v != ids.water && (is_cave(x, y - 1, z) ||
						is_cave(x - 1, y, z) || is_cave(x + 1, y, z) ||
						is_cave(x, y, z - 1) || is_cave(x, y, z + 1))){
					put = pick_cave(ids, ids.structs, p.seed, x, y, z, 'v', 1);
				}
				if(put)
					volume.setVoxelAt(x, y, z, VoxelInstance(put));
			}
		if(!decorate)
			return;
		// The surface's: every one reaching into the section, in one order
		for(int az = lc.getZ() - R; az <= uc.getZ() + R; az++)
		for(int ax = lc.getX() - R; ax <= uc.getX() + R; ax++){
			if(!p.in_map(ax, az))
				continue;
			const int t = top_at(ax, az);
			// [KIT_CAVE_MOUTHS] nothing floats over a mouth
			if(cave_mouth(p, ax, az, t))
				continue;
			int turns = 0;
			const int k = pick_surface(ids, p.seed, ax, az, t, p, 1,
					turns);
			if(k < 0)
				continue;
			const char on = ids.decors[k].on;
			ids.structs[ids.decors[k].s].each(turns, [&](int dx, int dy,
					int dz, VoxelTypeId id){
				const int x = ax + dx, y = t + 1 + dy, z = az + dz;
				if(x < lc.getX() || x > uc.getX() || y < lc.getY() ||
						y > uc.getY() || z < lc.getZ() || z > uc.getZ() ||
						!p.in_map(x, z))
					return;
				const uint32_t cur = volume.getVoxelAt(x, y, z).data;
				if(cur == ids.air || (on == 'w' && cur == ids.water))
					volume.setVoxelAt(x, y, z, VoxelInstance(id));
			});
		}
	}
};

// [KIT_AIRSHIPS_2] A kit/terrain_region's cells: a generator applied to a box
// of the world from its corner o (n cells each way), or to the ball
// inscribed in it. Each column's ground is the generator's (h, its level
// already the region's) cut by the shape: its highest cell in the shape the
// biome's top, filler under it, stone deeper; the shape's cells over it
// air. A column whose ground top lies in the shape gets the biome's surface
// decorations (into air only; they may reach out of the shape). No water,
// no caves. Cells packed by key()
struct Region
{
	int o[3] = {0, 0, 0}, n[3] = {1, 1, 1};
	bool sphere = false, decorate = true;
	uint32_t seed = 0;
	Ids ids;
	Heights *h = nullptr;

	static int64_t key(int x, int y, int z)
	{
		return ((int64_t)(x + (1 << 20)) << 42) | ((int64_t)(y + (1 << 20)) << 21) |
				(int64_t)(z + (1 << 20));
	}
	static void unkey(int64_t k, int &x, int &y, int &z)
	{
		x = (int)(k >> 42) - (1 << 20);
		y = (int)((k >> 21) & 0x1fffff) - (1 << 20);
		z = (int)(k & 0x1fffff) - (1 << 20);
	}
	// The shape's cells in column (x, z): y0...y1 (false: none)
	bool span(int x, int z, int &y0, int &y1) const
	{
		y0 = o[1], y1 = o[1] + n[1] - 1;
		if(!sphere)
			return true;
		const double dx = (x + 0.5 - o[0]) / n[0] * 2 - 1,
				dz = (z + 0.5 - o[2]) / n[2] * 2 - 1;
		const double r = 1 - dx * dx - dz * dz;
		if(r < 0)
			return false;
		const double hy = std::sqrt(r) * n[1] / 2, cy = o[1] + n[1] / 2.0;
		y0 = (int)std::ceil(cy - hy - 0.5);
		y1 = (int)std::floor(cy + hy - 0.5);
		return y0 <= y1;
	}
	void cells(std::unordered_map<int64_t, VoxelTypeId> &out)
	{
		sv_<int> tops;
		h->tops(o[0], o[2], n[0], n[2], tops);
		sv_<std::array<int, 3>> decor;
		for(int dz = 0; dz < n[2]; dz++)
		for(int dx = 0; dx < n[0]; dx++){
			const int x = o[0] + dx, z = o[2] + dz;
			int y0, y1;
			if(!span(x, z, y0, y1))
				continue;
			const int top = tops[(size_t)dz * n[0] + dx];
			const int g = std::min(top, y1);
			for(int y = y0; y <= y1; y++){
				VoxelTypeId v = ids.air;
				if(y <= g)
					v = y == g ? ids.top : y >= g - ids.filler_depth ?
							ids.filler : ids.stone;
				out[key(x, y, z)] = v ? v : ids.air;
			}
			if(decorate && top >= y0 && top < y1)
				decor.push_back({{x, top, z}});
		}
		Params nosea;
		nosea.sea_level = INT_MIN / 2;
		for(const auto &d : decor){
			int turns = 0;
			const int k = pick_surface(ids, seed, d[0], d[2], d[1], nosea,
					1, turns);
			if(k < 0)
				continue;
			ids.structs[ids.decors[k].s].each(turns, [&](int dx, int dy, int dz,
					VoxelTypeId id){
				const int64_t c = key(d[0] + dx, d[1] + 1 + dy, d[2] + dz);
				auto it = out.find(c);
				if(it == out.end() || it->second == ids.air)
					out[c] = id;
			});
		}
	}
};

// FNV-1a over ints: the heights' hash a check compares
static uint32_t hash_ints(const sv_<int> &v)
{
	uint32_t hsh = 2166136261u;
	for(int x : v)
		for(int i = 0; i < 4; i++){
			hsh ^= (uint32_t)(x >> (i * 8)) & 0xff;
			hsh *= 16777619u;
		}
	return hsh;
}

// The surface decorations over w x d columns from (x0, z0) (their tops):
// how many and their hash (x, z, the decoration, its turns), which a
// check compares by seed
static void scatter_hash(const Params &p, const BiomeIds &b,
		const sv_<int> &tops, int x0, int z0, int w, int d, size_t &n,
		uint32_t &hash)
{
	sv_<int> v;
	for(int z = 0; z < d; z++)
		for(int x = 0; x < w; x++){
			int turns = 0;
			const int t = tops[(size_t)z * w + x];
			if(cave_mouth(p, x0 + x, z0 + z, t))
				continue;
			const int k = pick_surface(b, p.seed, x0 + x, z0 + z, t, p, 1,
					turns);
			if(k < 0)
				continue;
			v.insert(v.end(), {x0 + x, z0 + z, k, turns});
		}
	n = v.size() / 4;
	hash = hash_ints(v);
}

// ---- [KIT] stage 4f: the brushes on a voxel surface
struct Brush
{
	Params p;
	VoxelTypeId air = 0;
	// The biomes by name, in the set's order, and the World's
	sv_<std::pair<ss_, BiomeIds>> biomes;
	BiomeIds world;
	sv_<StructIds> structs;
	// The kinds of cells: ground (a role's voxel of any biome), surface
	// ground (top, filler, riverbed: what lies over stone), soft (air,
	// water, plants: what a brush fills over), water
	std::set<VoxelTypeId> ground, surface, soft, water;
	// A cell's voxel (false: not loaded) and a write
	std::function<bool(int, int, int, VoxelTypeId&)> get;
	std::function<void(int, int, int, VoxelTypeId)> set;
	// Cells written by this dab
	size_t written = 0;

	bool is_ground(int x, int y, int z)
	{
		VoxelTypeId v = 0;
		return get(x, y, z, v) && ground.count(v);
	}
	// The top of a column between hi and lo (going down): the first ground
	// cell under a cell that is not ground
	bool top_of(int x, int z, int hi, int lo, int &top)
	{
		bool above = is_ground(x, hi + 1, z);
		for(int y = hi; y >= lo; y--){
			const bool g = is_ground(x, y, z);
			if(g && !above){
				top = y;
				return true;
			}
			above = g;
		}
		return false;
	}
	// The biome a column is by its top cell's voxel (then filler,
	// riverbed); else the World's
	const BiomeIds& biome_of(int x, int z, int top)
	{
		VoxelTypeId v = 0;
		if(get(x, top, z, v)){
			for(auto &b : biomes)
				if(b.second.top == v)
					return b.second;
			for(auto &b : biomes)
				if(b.second.filler == v)
					return b.second;
		}
		return world;
	}
	void put(int x, int y, int z, VoxelTypeId v)
	{
		VoxelTypeId cur = 0;
		if(!get(x, y, z, cur) || cur == v)
			return;
		set(x, y, z, v);
		written++;
	}
	// A column's top moved from h to h2 (the same: its layers only), its
	// layers made biome b's: the top cell top (riverbed under the sea),
	// filler under it to b's depth, the surface ground deeper stone; over
	// h2 air, water up to the sea level. Ground, air, water and plants
	// only
	void set_column(int x, int z, int h, int h2, const BiomeIds &b)
	{
		const int lo = std::min(h, h2) - b.filler_depth - 1;
		const int hi = std::max(h, h2) + 1;
		const bool under = h2 < p.sand_to();
		// [KIT_AIRSHIPS_2] A floating column (an island's: no ground in the 8
		// cells under the ones written) grows no ground under its old top:
		// lowered, it is dug from the top
		bool floating = true;
		for(int y = lo - 1; y >= lo - 8 && floating; y--)
			floating = !is_ground(x, y, z);
		for(int y = lo; y <= hi; y++){
			VoxelTypeId cur = 0;
			if(!get(x, y, z, cur))
				continue;
			const bool g = ground.count(cur) > 0, s = soft.count(cur) > 0;
			if(!g && !s)
				continue;
			if(floating && s && y <= h && y <= h2)
				continue;
			VoxelTypeId want = cur;
			if(y > h2){
				if(g || !water.count(cur))
					want = y <= p.sea_level && b.water ? b.water : air;
			} else if(y == h2){
				want = under ? b.riverbed : b.top;
			} else if(y >= h2 - b.filler_depth){
				want = under ? b.riverbed : b.filler;
			} else if(s || surface.count(cur)){
				want = b.stone;
			}
			if(want)
				put(x, y, z, want);
		}
	}
	// A structure's cells into soft cells only (water too under water)
	void place(const StructIds &s, int turns, int ax, int ay, int az,
			bool in_water)
	{
		s.each(turns, [&](int dx, int dy, int dz, VoxelTypeId id){
			VoxelTypeId cur = 0;
			const int x = ax + dx, y = ay + dy, z = az + dz;
			if(!p.in_map(x, z) || !get(x, y, z, cur))
				return;
			if(cur == air || (in_water && water.count(cur)))
				put(x, y, z, id);
		});
	}
};

}
}
// vim: set noet ts=4 sw=4:
