// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// What builtin/luanti reads the node definitions and the game's media with
// for node_registry.h's builder ([LUANTI_MODULAR]: a part of the Module,
// owning the palettes and the frame counts it has read, with references to
// the game's Lua state and the media the game run serves).
#pragma once
#include "core/types.h"
#include "core/log.h"
#include "interface/mutex.h"
#include "interface/server.h"
#include "interface/voxel.h"
#include "main_context/api.h"
#include "luanti/node_registry.h"
#include "luanti/lua_util.h"
#include <Image.h>
#include <MemoryBuffer.h>
#include <Context.h>
#include <fstream>
#include <sstream>
#include <functional>
extern "C" {
#include <lua.h>
}

namespace luanti {

namespace magic = Urho3D;

// A colour for a node that has no texture yet, from its name, so that two
// nodes are two colours and the same node is the same colour between runs.
// M3 replaces every one of these with the node's real tiles; until then a
// world is legible as blocks of colour, which is what M2 has to show.
static void node_colour(const ss_ &name, uint8_t rgb[3])
{
	uint32_t h = 2166136261u;
	for(char c : name){
		h ^= (uint8_t)c;
		h *= 16777619u;
	}
	// Kept well below white: these are albedo, and a game lighting a scene
	// in HDR with a tone curve over it turns anything near white into a
	// flat blown-out surface. 0.12 to 0.55 is roughly what the hand-drawn
	// voxel textures in this tree sit at.
	rgb[0] = 30 + (h & 0x6f);
	rgb[1] = 30 + ((h >> 8) & 0x6f);
	rgb[2] = 30 + ((h >> 16) & 0x6f);
}

// A media file's name as the client knows it. A namespace of its own, and
// not the module's own "luanti/", because that is where client_file serves a
// module's client_lua from: a game with a texture called module.lua would
// otherwise land on top of this module's client half.
static ss_ media_resource_name(const ss_ &file_name)
{
	return "luanti_media/"+file_name;
}

// A tile that is a texture modifier gets a name of its own, by what it is:
// the same expression in two node definitions is one texture. The client is
// what composes it; see the texmods packet.
static ss_ texmod_resource_name(const ss_ &expr)
{
	uint32_t h = 2166136261u;
	for(char c : expr){
		h ^= (uint8_t)c;
		h *= 16777619u;
	}
	char buf[48];
	snprintf(buf, sizeof buf, "luanti_texmod/%08x.png", h);
	return buf;
}

static ss_ node_texture_name(const ss_ &name)
{
	uint32_t h = 2166136261u;
	for(char c : name){
		h ^= (uint8_t)c;
		h *= 16777619u;
	}
	char buf[32];
	snprintf(buf, sizeof buf, "luanti_gen/node_%08x.png", (unsigned)h);
	return buf;
}



// One picture placed into a "[combine:WxH:x,y=file:x,y=file" expression
struct CombinePlace
{
	int x = 0, y = 0;
	ss_ name;
};

// What that expression says, or false if it is not one: no nesting, and
// what is placed is a file name rather than a modifier of its own. See
// palette_image(), which is the only thing that needs a modifier composed
// on this side at all.
static bool parse_combine(const ss_ &expr, int &w_out, int &h_out,
		sv_<CombinePlace> &out)
{
	static const ss_ COMBINE = "[combine:";
	if(expr.compare(0, COMBINE.size(), COMBINE) != 0)
		return false;
	sv_<ss_> parts;
	for(size_t at = COMBINE.size(); at <= expr.size(); ){
		size_t end = expr.find(':', at);
		if(end == ss_::npos)
			end = expr.size();
		parts.push_back(expr.substr(at, end - at));
		at = end + 1;
	}
	int w = 0, h = 0;
	if(parts.empty() || sscanf(cs(parts[0]), "%dx%d", &w, &h) != 2 ||
			w <= 0 || h <= 0 || w > 1024 || h > 1024)
		return false;
	sv_<CombinePlace> places;
	for(size_t i = 1; i < parts.size(); i++){
		CombinePlace place;
		int file_at = 0;
		if(sscanf(cs(parts[i]), "%d,%d=%n", &place.x, &place.y,
				&file_at) < 2 || file_at <= 0 ||
				(size_t)file_at >= parts[i].size())
			return false;
		place.name = parts[i].substr(file_at);
		places.push_back(place);
	}
	if(places.empty())
		return false;
	out = places;
	w_out = w;
	h_out = h;
	return true;
}

struct Registry
{
	interface::Server *&m_server;
	lua_State *&m_lua;
	interface::Mutex &m_lua_mutex;
	// The media the game shipped, name -> path, and the texture modifiers
	// the client composes, resource -> expression: the game run's
	sm_<ss_, ss_> &m_served_media;
	sm_<ss_, ss_> &m_texmods;
	// The tiles that wear a generated colour, served by the game run
	std::function<void(const sv_<ss_> &)> serve_node_textures;
	// The colours of each palette that has been read, by file name
	sm_<ss_, sv_<uint32_t>> m_palettes;
	// How many frames each animated tile's strip holds, by tile name
	sm_<ss_, size_t> m_frame_counts;

	Registry(interface::Server *&server, lua_State *&lua,
			interface::Mutex &lua_mutex, sm_<ss_, ss_> &served_media,
			sm_<ss_, ss_> &texmods,
			std::function<void(const sv_<ss_> &)> serve_node_textures):
		m_server(server), m_lua(lua), m_lua_mutex(lua_mutex),
		m_served_media(served_media), m_texmods(texmods),
		serve_node_textures(serve_node_textures)
	{}

	// A tile the client can load as it stands: a plain file name the game
	// shipped. Anything with a texture modifier in it -- ^ for an overlay,
	// [ for a generator, ( for a grouping -- has to be composed, and the
	// client is what composes it, which is the rest of M3.
	// The six surface numbers of the definition on top of the stack, as a
	// segment with no texture; what the guess did not say keeps the
	// numbers the module used to give every tile
	interface::AtlasSegmentDefinition table_surface(lua_State *L)
	{
		interface::AtlasSegmentDefinition s;
		s.roughness = 0.95f;
		s.spec_strength = 0.15f;
		s.bumpiness = 0.0f;
		lua_getfield(L, -1, "surface");
		if(lua_istable(L, -1)){
			s.roughness = (float)table_number(L, "roughness", s.roughness);
			s.spec_strength = (float)table_number(L, "spec_strength",
					s.spec_strength);
			s.bumpiness = (float)table_number(L, "bumpiness", s.bumpiness);
			s.translucency = (float)table_number(L, "translucency", 0);
			s.spots = (float)table_number(L, "spots", 0);
			s.static_spots = (float)table_number(L, "static_spots", 0);
		}
		lua_pop(L, 1);
		return s;
	}

	// The colours in a palette image, row by row and at most 256 of them,
	// which is the order Luanti reads one in. A node with a palette wears
	// the colour its param2 picks; Luanti stretches the palette over the
	// 256 param values, so an eight-colour palette changes every
	// thirty-two, and that stretching is done where the variants are built.
	//
	// Read here and not on the client because what the client is sent is a
	// texture name, and the name is the tile through a modifier that
	// multiplies it by one of these.
	// One shipped image, loaded. False and a warning if the game never sent
	// it or it is not a picture.
	bool load_media_image(const ss_ &name, magic::Image &img)
	{
		auto it = m_served_media.find(name);
		if(it == m_served_media.end()){
			log_w(MODULE, "image \"%s\" was not shipped", cs(name));
			return false;
		}
		std::ifstream ifs(it->second, std::ios::binary);
		std::ostringstream os;
		os<<ifs.rdbuf();
		const ss_ data = os.str();
		if(data.empty()){
			log_w(MODULE, "image \"%s\" is empty", cs(name));
			return false;
		}
		magic::MemoryBuffer buf(data.c_str(), (unsigned)data.size());
		if(!img.Load(buf)){
			log_w(MODULE, "image \"%s\" did not load", cs(name));
			return false;
		}
		return true;
	}

	// A palette is usually a file, but a game may name it as a texture
	// modifier instead, which Luanti composes through the same pipeline as
	// any other texture: VoxeLibre's vines ask for
	// "[combine:16x2:0,0=mcl_core_palette_foliage.png", which is that
	// palette's first two rows and nothing else.
	//
	// simplified: [combine and no other modifier, and what it places has to
	// be a file rather than a modifier of its own. Anything further warns
	// and the node goes without its palette; the upgrade is the client's own
	// texmod.lua evaluated over an Image rather than over a texture.
	// How many frames a strip of animation frames holds. Luanti works it out
	// of the image's own proportions and the aspect the definition gives --
	// TileDef::animation against the texture's width and height -- so this
	// reads the size out of the file's PNG header rather than decoding it.
	// A tile whose name is not a plain file, or is not a PNG, answers one
	// and is left as it is.
	size_t tile_frame_count(const ss_ &name, float aspect)
	{
		auto cached = m_frame_counts.find(name);
		if(cached != m_frame_counts.end())
			return cached->second;
		size_t frames = 1;
		auto media = m_served_media.find(name);
		if(media != m_served_media.end()){
			std::ifstream ifs(media->second, std::ios::binary);
			uint8_t hdr[24] = {};
			ifs.read((char*)hdr, sizeof hdr);
			static const uint8_t SIG[8] = {
				0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
			if(ifs.gcount() == (std::streamsize)sizeof hdr &&
					memcmp(hdr, SIG, 8) == 0 &&
					memcmp(hdr + 12, "IHDR", 4) == 0){
				const uint32_t w = ((uint32_t)hdr[16] << 24) |
						((uint32_t)hdr[17] << 16) |
						((uint32_t)hdr[18] << 8) | (uint32_t)hdr[19];
				const uint32_t h = ((uint32_t)hdr[20] << 24) |
						((uint32_t)hdr[21] << 16) |
						((uint32_t)hdr[22] << 8) | (uint32_t)hdr[23];
				if(w > 0 && h > 0 && aspect > 0.0f){
					const float n = (float)h / (float)w * aspect;
					if(n >= 1.5f && n < 1024.0f)
						frames = (size_t)(n + 0.5f);
				}
			}
		}
		m_frame_counts[name] = frames;
		return frames;
	}

	bool palette_image(const ss_ &name, magic::Image &img)
	{
		if(name.empty() || name[0] != '[')
			return load_media_image(name, img);
		int w = 0, h = 0;
		sv_<CombinePlace> places;
		if(!parse_combine(name, w, h, places)){
			log_w(MODULE, "palette \"%s\" is not a modifier this composes",
					cs(name));
			return false;
		}
		img.SetSize(w, h, 4);
		img.Clear(magic::Color(0, 0, 0, 0));
		for(const CombinePlace &place : places){
			magic::Image piece(img.GetContext());
			if(!load_media_image(place.name, piece))
				return false;
			for(int y = 0; y < piece.GetHeight(); y++){
				for(int x = 0; x < piece.GetWidth(); x++){
					if(place.x + x >= w || place.y + y >= h ||
							place.x + x < 0 || place.y + y < 0)
						continue;
					img.SetPixel(place.x + x, place.y + y,
							piece.GetPixel(x, y));
				}
			}
		}
		return true;
	}

	const sv_<uint32_t>& palette_colours(const ss_ &name)
	{
		auto cached = m_palettes.find(name);
		if(cached != m_palettes.end())
			return cached->second;
		sv_<uint32_t> &out = m_palettes[name];
		main_context::access(m_server, [&](main_context::Interface *imc){
			magic::Image img(imc->get_context());
			if(!palette_image(name, img))
				return;
			const int w = img.GetWidth(), h = img.GetHeight();
			for(int y = 0; y < h && (int)out.size() < 256; y++){
				for(int x = 0; x < w && (int)out.size() < 256; x++){
					magic::Color c = img.GetPixel(x, y);
					out.push_back(
							((uint32_t)(c.r_ * 255.0f + 0.5f) << 16) |
							((uint32_t)(c.g_ * 255.0f + 0.5f) << 8) |
							(uint32_t)(c.b_ * 255.0f + 0.5f));
				}
			}
		});
		log_v(MODULE, "palette \"%s\": %zu colours", cs(name), out.size());
		return out;
	}

	// The quads a "mesh" node is made of, read out of the model file the
	// game shipped. lua/mesh.lua picks the reader by extension; a format
	// nothing reads comes back empty and the node keeps its cube.
	//
	// Read here rather than on the client because a node's shape belongs in
	// its definition, where every other drawtype's shape is: the client is
	// sent quads and does not care where they came from.
	// frame < 0: the bind pose; otherwise the model posed at that frame of
	// its animation (b3d only; see lua/b3dmesh.lua)
	sv_<interface::VoxelQuad> mesh_quads(const ss_ &name, float scale,
			float frame = -1.0f)
	{
		sv_<interface::VoxelQuad> out;
		auto it = m_served_media.find(name);
		if(it == m_served_media.end()){
			log_v(MODULE, "mesh \"%s\" was not shipped", cs(name));
			return out;
		}
		std::ifstream ifs(it->second, std::ios::binary);
		std::ostringstream os;
		os<<ifs.rdbuf();
		const ss_ data = os.str();
		if(data.empty())
			return out;
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mesh_quads");
		lua_pushlstring(L, name.c_str(), name.size());
		lua_pushlstring(L, data.c_str(), data.size());
		lua_pushnumber(L, scale);
		lua_pushnumber(L, frame);
		if(lua_pcall(L, 4, 2, 0) != 0){
			log_w(MODULE, "__mesh_quads(\"%s\"): %s", cs(name),
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const int skipped = (int)lua_tonumber(L, -1);
		if(!lua_istable(L, -2)){
			lua_settop(L, base);
			return out;
		}
		// Twenty-one numbers a quad: the tile, four corners and four
		// texture coordinates
		const size_t n = lua_objlen(L, -2);
		out.reserve(n / 21);
		for(size_t i = 0; i + 20 < n; i += 21){
			interface::VoxelQuad quad;
			double v[21];
			for(size_t j = 0; j < 21; j++){
				lua_rawgeti(L, -2, (int)(i + j + 1));
				v[j] = lua_tonumber(L, -1);
				lua_pop(L, 1);
			}
			quad.tile = (uint8_t)v[0];
			for(size_t c = 0; c < 4; c++){
				for(size_t k = 0; k < 3; k++)
					quad.p[c][k] = (float)v[1 + c * 3 + k];
				for(size_t k = 0; k < 2; k++)
					quad.uv[c][k] = (float)v[13 + c * 2 + k];
			}
			out.push_back(quad);
		}
		lua_settop(L, base);
		log_v(MODULE, "mesh \"%s\": %zu quads%s", cs(name), out.size(),
				skipped > 0 ? cs(ss_()+", "+itos(skipped)+
				" faces are neither triangles nor quads") : "");
		return out;
	}

	bool plain_media_name(const ss_ &tile)
	{
		if(tile.empty())
			return false;
		if(is_texmod(tile))
			return false;
		return m_served_media.count(tile) != 0;
	}

	// A tile that is not a file name but an expression over them: "^" for an
	// overlay, "[" for a generator, "(" for a group. The client composes
	// these; what is left for the flat colour is a plain name the game did
	// not ship.
	static bool is_texmod(const ss_ &tile)
	{
		return !tile.empty() && tile.find_first_of("^[(&") != ss_::npos;
	}

	// The resource name a tile is drawn under, and what the client has to
	// compose to have it. Empty for a tile that is neither a file the game
	// shipped nor an expression.
	ss_ texture_of_tile(const ss_ &tile)
	{
		if(plain_media_name(tile))
			return media_resource_name(tile);
		if(is_texmod(tile)){
			ss_ resource = texmod_resource_name(tile);
			m_texmods[resource] = tile;
			return resource;
		}
		return "";
	}

	// The game's media, as node_registry.h's builder asks for it
	struct GameMedia: luanti_registry::Media
	{
		Registry *m;
		GameMedia(Registry *m): m(m){}
		ss_ texture(const ss_ &tile){ return m->texture_of_tile(tile); }
		size_t frame_count(const ss_ &tile, float aspect)
		{ return m->tile_frame_count(tile, aspect); }
		sv_<uint32_t> palette(const ss_ &name)
		{ return m->palette_colours(name); }
		sv_<interface::VoxelQuad> mesh(const ss_ &name, float scale)
		{ return m->mesh_quads(name, scale); }
		ss_ fallback(const ss_ &name){ return node_texture_name(name); }
	};

	// The definition on top of the stack, as core.__voxel_defs() wrote it
	luanti_registry::NodeDef read_node_def(lua_State *L)
	{
		luanti_registry::NodeDef d;
		d.name = table_string(L, "name");
		d.drawtype = table_string(L, "drawtype");
		d.sunlight = table_boolean(L, "sunlight");
		d.node_mul = table_string(L, "node_mul");
		d.alpha_blend = table_boolean(L, "alpha_blend");
		d.alpha_clip = table_boolean(L, "alpha_clip");
		d.empty = table_boolean(L, "empty");
		d.walkable = table_boolean(L, "walkable");
		d.climbable = table_boolean(L, "climbable");
		d.move_resistance = table_number(L, "move_resistance", 0);
		d.bouncy = table_number(L, "bouncy", 0);
		d.slippery = table_number(L, "slippery", 0);
		d.disable_jump = table_boolean(L, "disable_jump");
		d.disable_descend = table_boolean(L, "disable_descend");
		d.swimmable = table_boolean(L, "swimmable");
		d.pointable = table_number(L, "pointable", 1);
		lua_getfield(L, -1, "groups");
		if(lua_istable(L, -1)){
			lua_pushnil(L);
			while(lua_next(L, -2) != 0){
				if(lua_type(L, -2) == LUA_TSTRING && lua_isnumber(L, -1))
					d.groups[lua_tostring(L, -2)] = (int)lua_tonumber(L, -1);
				lua_pop(L, 1);
			}
		}
		lua_pop(L, 1);
		d.waving = (int)table_number(L, "waving", 0);
		d.surface = table_surface(L);
		d.has_surface = true;
		d.visual_scale = (float)table_number(L, "visual_scale", 1.0);
		d.has_tiles = table_six_strings(L, "tiles", d.tiles);
		table_six_numbers(L, "tile_frames", d.tile_aspect);
		table_six_numbers(L, "tile_lengths", d.tile_length);
		table_numbers(L, "node_box", d.node_box);
		table_numbers(L, "collision_box", d.collision_box);
		table_numbers(L, "selection_box", d.selection_box);
		table_numbers(L, "selection_box_wall", d.selection_box_wall);
		table_numbers(L, "node_box_connected", d.node_box_connected);
		d.node_box_connects = table_string(L, "node_box_connects");
		d.node_box_groups = table_string(L, "node_box_groups");
		d.facing = table_string(L, "facing");
		d.overlay_tile = table_string(L, "overlay_tile");
		d.overlay_aspect = (float)table_number(L, "overlay_frames", 0);
		d.overlay_length = (float)table_number(L, "overlay_length", 0);
		d.liquid_group = table_string(L, "liquid_group");
		d.palette = table_string(L, "palette");
		d.mesh = table_string(L, "mesh");
		d.raillike_group = (int)table_number(L, "raillike_group", 0);
		d.liquid_range = (int)table_number(L, "liquid_range",
				luanti_shapes::LIQUID_LEVELS);
		// What the node glows with, which is what lamp light floods from; a
		// Luanti game's mechanics read that light
		d.light_source = (uint8_t)std::min(15.0,
				std::max(0.0, table_number(L, "light_source", 0)));
		return d;
	}

	void build_voxel_registry(interface::VoxelRegistry *reg)
	{
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__voxel_defs");
		if(lua_pcall(L, 0, 1, 0) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: __voxel_defs(): "+err);
		}
		size_t n = lua_objlen(L, -1);
		luanti_registry::Builder builder;
		GameMedia media(this);
		// surface.lua's numbers are what the node wears; node_registry.h's
		// port of it is what a module without Lua gets, and it has to give
		// the same. BUILDAT_LUANTI_NO_SPOTS is bootstrap.lua's own.
		const char *no_spots = getenv("BUILDAT_LUANTI_NO_SPOTS");
		size_t n_surface_differs = 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			const luanti_registry::NodeDef d = read_node_def(L);
			lua_pop(L, 1);
			interface::AtlasSegmentDefinition guess =
					luanti_registry::guess_surface(d);
			if(no_spots && *no_spots)
				guess.spots = guess.static_spots = 0;
			const float a[6] = {d.surface.roughness, d.surface.spec_strength,
					d.surface.bumpiness, d.surface.translucency,
					d.surface.spots, d.surface.static_spots};
			const float b[6] = {guess.roughness, guess.spec_strength,
					guess.bumpiness, guess.translucency, guess.spots,
					guess.static_spots};
			for(size_t k = 0; k < 6; k++){
				if(std::fabs(a[k] - b[k]) > 1e-5f){
					if(n_surface_differs++ < 5)
						log_e(MODULE, "surface of %s: surface.lua's %g, "
								"node_registry.h's %g (number %zu)",
								cs(d.name), a[k], b[k], k);
					break;
				}
			}
			reg->add_voxel(builder.build(d, media));
		}
		lua_settop(L, base);
		if(n_surface_differs > 0)
			log_e(MODULE, "%zu nodes' surface guess differs between "
					"surface.lua and node_registry.h", n_surface_differs);

		serve_node_textures(builder.fallback_nodes);
		log_i(MODULE, "%zu node types in the voxel registry: %zu have a shape "
				"of their own, %zu of those are liquids, %zu turn with their "
				"param2, %zu wear a colour out of a palette (%zu variants), "
				"%zu wear a generated colour because a tile is a "
				"texture modifier or was not shipped",
				n, builder.n_shaped, builder.n_liquid, builder.n_facing_nodes,
				builder.n_palette_nodes, builder.n_palette_variants,
				builder.fallback_nodes.size());
		// What the registry actually holds, which is what the client is
		// sent and what its own line of detail counts. A definition that
		// went in under a name another one already had is one voxel type
		// rather than two, and the two ends disagreeing about the count is
		// the first thing a comparison notices; see
		// doc/plan/luanti_module_plan.md, "The numbers before the pixels".
		const size_t in_registry = reg->get_count();
		if(in_registry != n){
			log_w(MODULE, "%zu of those %zu are in the registry: the rest "
					"went in under a name one of them already had",
					in_registry, n);
		}
	}
};

}
// vim: set noet ts=4 sw=4:
