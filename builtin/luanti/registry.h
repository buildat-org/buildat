// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
//
// The voxel registry builder and what it reads the node definitions with,
// included by luanti.cpp inside struct Module ([SPLITS]: moved out as it
// was).

	// An edge material of its own for each kind of glass, so that the mesher
	// draws a face between glass and anything else and not between two of
	// the same glass -- which is what Luanti's glasslike is.
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
			log_w(MODULE, "More than 246 glasslike node types; the rest share "
					"an edge material and their faces merge into each other");
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
			log_w(MODULE, "More than 254 liquids; the rest share a shape "
					"group and draw no surface between each other");
		}
		m_liquid_shape_groups[group] = id;
		return id;
	}

	// One family per raillike group, because a rail reaches the rails of its
	// own group and no others. Fences have group 1; a connect group is five
	// bits of a thirty-two bit mask, so there are thirty-one left.
	uint8_t named_connect_group(const ss_ &name)
	{
		auto it = m_named_connect_groups.find(name);
		if(it != m_named_connect_groups.end())
			return it->second;
		uint8_t id = 32;
		if(m_next_rail_connect_group <= 32){
			id = (uint8_t)m_next_rail_connect_group++;
		} else if(!m_rail_connect_groups_exhausted){
			m_rail_connect_groups_exhausted = true;
			log_w(MODULE, "More than 31 connect groups; the rest share one "
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
		if(m_next_rail_connect_group <= 32){
			id = (uint8_t)m_next_rail_connect_group++;
		} else if(!m_rail_connect_groups_exhausted){
			m_rail_connect_groups_exhausted = true;
			log_w(MODULE, "More than 31 raillike groups; the rest share one "
					"and their rails connect to each other");
		}
		m_rail_connect_groups[raillike_group] = id;
		return id;
	}

	// A tile the client can load as it stands: a plain file name the game
	// shipped. Anything with a texture modifier in it -- ^ for an overlay,
	// [ for a generator, ( for a grouping -- has to be composed, and the
	// client is what composes it, which is the rest of M3.
	// One texture of a definition, with the surface numbers the shared
	// guess gave the node (extensions/luanti_client/surface.lua, through
	// bootstrap.lua's __voxel_defs(); see [VOXEL_MATERIALS]).
	// `frames` is how many animation frames the texture is a vertical strip
	// of: the segment is then the first of them, which is what the atlas's
	// own total_segments is for. One is a still texture.
	static interface::AtlasSegmentDefinition make_segment(const ss_ &texture,
			const interface::AtlasSegmentDefinition &surface,
			size_t frames = 1)
	{
		interface::AtlasSegmentDefinition seg = surface;
		seg.resource_name = texture;
		seg.total_segments = magic::IntVector2(
				texture.empty() ? 0 : 1,
				texture.empty() ? 0 : (int)(frames < 1 ? 1 : frames));
		seg.select_segment = magic::IntVector2(0, 0);
		return seg;
	}

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

	// "#rrggbb", which is what a texture modifier takes
	static ss_ hex_colour(uint32_t rgb)
	{
		char buf[8];
		snprintf(buf, sizeof buf, "#%02x%02x%02x",
				(rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
		return ss_(buf);
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
	// Where a paletted node's colour goes in a tile's expression. The Lua
	// side marks the place per layer -- see PALETTE_MARK in
	// lua/bootstrap.lua -- because **Luanti applies the node's colour to a
	// layer only when that layer has no colour of its own**, and the layers
	// are composed there while the palette is resolved here. A node with no
	// palette passes an empty mul and the marks come out.
	static ss_ with_palette(const ss_ &expr, const ss_ &mul)
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
		sv_<ss_> textures;
		size_t n_fallback = 0;
		size_t n_shaped = 0;
		size_t n_liquid = 0;
		size_t n_facing_nodes = 0;
		size_t n_palette_nodes = 0;
		size_t n_palette_variants = 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			ss_ name = table_string(L, "name");
			bool sunlight = table_boolean(L, "sunlight");
			// What the node's own colour multiplies its tiles by, where a
			// paletted node's slot colour would go ([WATER_LIGHT] 2)
			const ss_ node_mul = table_string(L, "node_mul");
			bool alpha_blend = table_boolean(L, "alpha_blend");
			bool alpha_clip = table_boolean(L, "alpha_clip");
			bool empty = table_boolean(L, "empty");
			bool walkable = table_boolean(L, "walkable");
			bool climbable = table_boolean(L, "climbable");
			double move_resistance = table_number(L, "move_resistance", 0);
			double bouncy = table_number(L, "bouncy", 0);
			double slippery = table_number(L, "slippery", 0);
			bool disable_jump = table_boolean(L, "disable_jump");
			bool disable_descend = table_boolean(L, "disable_descend");
			bool swimmable = table_boolean(L, "swimmable");
			double pointable = table_number(L, "pointable", 1);
			ss_ drawtype = table_string(L, "drawtype");
			const interface::AtlasSegmentDefinition surface = table_surface(L);
			float visual_scale = (float)table_number(L, "visual_scale", 1.0);
			ss_ tiles[6];
			bool has_tiles = table_six_strings(L, "tiles", tiles);
			// Which of them are a strip of animation frames, as the aspect
			// the frame count is worked out with; 0 is a still tile
			float tile_aspect[6] = {};
			table_six_numbers(L, "tile_frames", tile_aspect);
			sv_<float> boxes;
			table_numbers(L, "node_box", boxes);
			sv_<float> collision_boxes;
			table_numbers(L, "collision_box", collision_boxes);
			// What is pointed at: fixed boxes turned by the facing like
			// the collision boxes, or a wallmounted node's own per wall,
			// seven numbers a box with the wallmounted direction first
			sv_<float> selection_boxes, selection_walls;
			table_numbers(L, "selection_box", selection_boxes);
			table_numbers(L, "selection_box_wall", selection_walls);
			sv_<float> connected_boxes;
			table_numbers(L, "node_box_connected", connected_boxes);
			const ss_ connects = table_string(L, "node_box_connects");
			const ss_ own_groups = table_string(L, "node_box_groups");
			ss_ facing = table_string(L, "facing");
			ss_ overlay_tile = table_string(L, "overlay_tile");
			ss_ liquid_group = table_string(L, "liquid_group");
			ss_ palette = table_string(L, "palette");
			ss_ mesh = table_string(L, "mesh");
			int raillike_group = (int)table_number(L, "raillike_group", 0);
			int liquid_range = (int)table_number(L, "liquid_range",
					LIQUID_LEVELS);
			// What the node glows with, which is what lamp light floods
			// from; a Luanti game's mechanics read that light
			const uint8_t light_source = (uint8_t)std::min(15.0,
					std::max(0.0, table_number(L, "light_source", 0)));
			lua_pop(L, 1);

			// The shape, where the drawtype is one this builds. Everything
			// else is still a cube; see the M3 entry in the module plan for
			// which and in what order.
			sv_<interface::VoxelQuad> shape;
			bool double_sided = false;
			bool lit_from_above = false;
			// "torchlike" or "signlike": a shape that is built per
			// wallmounted direction rather than turned
			ss_ wall_shape;
			// Which family this reaches out to, and which families it
			// reaches; see connect_dir in interface/voxel.h
			uint8_t connect_group = 0;
			uint32_t connect_mask = 0;
			bool connect_to_solid = false;
			// A shape per mask of which neighbours the voxel reaches; see
			// VoxelDefinition::shape_masked
			sv_<interface::VoxelQuad> masked_shape;
			uint16_t masked_begin[21] = {};
			// The shape is drawn as well as the voxel's cube faces, not
			// instead of them
			bool shape_over_cube = false;
			if(drawtype == "mesh" && !mesh.empty()){
				// The model's own quads, in the node's own cube -- and the
				// parts of it that reach outside, which is how a model two
				// nodes tall is one node with an airlike one over it. A
				// format nothing here reads leaves the node the cube it had.
				shape = mesh_quads(mesh,
						visual_scale > 0.0f ? visual_scale : 1.0f);
				// A mesh node's tiles are two-sided unless one says
				// otherwise: Luanti's read_tiledef() sets default_culling
				// false for NDT_MESH the way it does for plantlike. Models
				// are authored for that -- VoxeLibre's sunflower gives the
				// front and the back of its flower head as two quads with
				// the same winding, so culling loses both of them and the
				// stem is left standing on its own.
				//
				// The extension has drawn them this way from the start --
				// see shapes.lua, NDT_MESH -- which is why its picture of
				// the same world has flowers on its sunflowers.
				//
				// simplified: a tile that sets backface_culling itself is
				// not heard, here or anywhere else; what that would take is
				// a flag per quad rather than per shape.
				double_sided = true;
			} else if(drawtype == "nodebox" && boxes.size() >= 6){
				for(size_t b = 0; b + 5 < boxes.size(); b += 6){
					add_box_quads(shape, boxes[b], boxes[b + 1], boxes[b + 2],
							boxes[b + 3], boxes[b + 4], boxes[b + 5]);
				}
			} else if(drawtype == "nodebox" && connected_boxes.size() >= 7){
				// A "connected" box: the fixed part, and a set per side
				// drawn when the neighbour there is one of its connects_to
				// groups or solid -- the fence's own rule with the game's
				// boxes. Its own group is the first of its connects_to it
				// belongs to, so a fence reaches fences and a pane panes.
				// simplified: a target group whose nodes are not solid and
				// were not registered as connected boxes themselves (a
				// fence gate) is not reached; connects_to is read as
				// "any solid" for the rest.
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
					std::istringstream is(connects);
					ss_ g;
					while(std::getline(is, g, ';'))
						if(!g.empty())
							targets.push_back(g);
				}
				for(const ss_ &g : targets){
					const uint8_t id = named_connect_group(g);
					connect_mask |= 1u << (id - 1);
					if(connect_group == 0 && (";" + own_groups + ";").find(
							";" + g + ";") != ss_::npos)
						connect_group = id;
				}
				if(connect_group == 0 && !targets.empty())
					connect_group = named_connect_group(targets[0]);
				connect_to_solid = true;
			} else if(drawtype == "plantlike"){
				add_plant_quads(shape, visual_scale > 0.0f ? visual_scale : 1.0f);
				double_sided = true;
			} else if(drawtype == "raillike"){
				// One quad, and which tile it wears and which way it is
				// turned is what its neighbours say -- so it is a shape per
				// mask rather than a shape. A rail reaches other rails of
				// its own raillike group and nothing else.
				add_rail_shapes(masked_shape, masked_begin);
				connect_group = rail_connect_group(raillike_group);
				connect_mask = 1u << (connect_group - 1);
			} else if(drawtype == "fencelike"){
				// A post and a pair of bars per direction that has
				// something to reach. It reaches other fences, whatever
				// kind, and anything solid -- which is Luanti's rule.
				add_fence_quads(shape);
				connect_group = FENCE_CONNECT_GROUP;
				connect_mask = 1u << (FENCE_CONNECT_GROUP - 1);
				connect_to_solid = true;
			} else if(drawtype == "firelike"){
				// Luanti's fire is quads leaning against whatever is around
				// it; crossed quads are what it comes to when nothing is,
				// and what the extension draws for it either way.
				add_plant_quads(shape, visual_scale > 0.0f ? visual_scale : 1.0f);
				double_sided = true;
			} else if(drawtype == "torchlike" || drawtype == "signlike"){
				// One quad, and which way it lies is the wallmounted
				// direction rather than a rotation of one base shape -- a
				// torch on the floor leans and a torch on a wall does not.
				// So the shape is built per variant below; this is what a
				// node whose param2 says nothing comes to.
				wall_shape = drawtype;
				add_wall_quads(wall_shape, shape,
						visual_scale > 0.0f ? visual_scale : 1.0f, 1);
				double_sided = true;
			} else if(drawtype == "plantlike_rooted"){
				// The plant stands in the voxel above the one it is rooted
				// in, and the cube it is rooted in is ground drawn by the
				// cube path -- so this shape is over the cube rather than
				// instead of it, and the plant takes the light of the voxel
				// it stands in and not the ground's own. That is what
				// shape_lit_from_above is for.
				add_plant_quads(shape,
						visual_scale > 0.0f ? visual_scale : 1.0f, 0.5f, 6);
				double_sided = true;
				lit_from_above = true;
				shape_over_cube = true;
			} else if(!liquid_group.empty()){
				// A full voxel of it. The faces inside a body of the same
				// liquid are dropped by the shape group, and the surface is
				// levelled by the variants below.
				add_box_quads(shape, -0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f);
			}

			// Which way the node faces, which is also param2: one variant
			// per direction, each permuting the definition's own six
			// textures rather than being a voxel type of its own.
			sv_<interface::VoxelVariant> facing_variants;
			const size_t n_facing = facing_variant_count(facing);
			for(size_t i = 0; i < n_facing; i++){
				interface::VoxelVariant var;
				const uint8_t d = facing_facedir(facing, i);
				for(size_t f = 0; f < 6; f++){
					var.tile_order[f] = FACEDIR_TILES[d][f];
					var.tile_turns[f] = FACEDIR_TURNS[d][f];
				}
				if(!wall_shape.empty()){
					// A torch or a sign: its own shape per wall, and the
					// variant index is the wallmounted direction itself
					add_wall_quads(wall_shape, var.shape,
							visual_scale > 0.0f ? visual_scale : 1.0f, i);
				} else if(facing == "meshoptions" && drawtype == "plantlike"){
					// The shape the param2 names, 1.4x with bit 4
					const float vs = visual_scale > 0.0f ? visual_scale : 1.0f;
					add_plant_quads(var.shape, (i & 8) ? vs * 1.4f : vs,
							-0.5f, 0, (unsigned)(i & 7));
				} else if(!shape.empty() && !shape_over_cube && d != 0){
					// A node that has a shape turns the shape too: a stair
					// facing the other way is the same quads rotated, and
					// the tile each quad names travels with it. Only for a
					// shape that is the node's own cube -- a rooted plant's
					// shape stands in the voxel above and turning it would
					// take it sideways out of that voxel.
					turn_quads(shape, d, var.shape);
				}
				// And what stops the player, turned the same way; empty for
				// the definition's own
				if(walkable && !empty && d != 0)
					turn_boxes(collision_boxes, d, var.collision_boxes);
				if(!selection_walls.empty()){
					// 6 and 7 are the ceiling and the floor turned
					const float w = (float)(i == 6 ? 0 : i == 7 ? 1 : i);
					for(size_t b = 0; b + 7 <= selection_walls.size(); b += 7)
						if(selection_walls[b] == w)
							var.selection_boxes.insert(var.selection_boxes.end(),
									&selection_walls[b + 1],
									&selection_walls[b + 7]);
				} else if(d != 0){
					turn_boxes(selection_boxes, d, var.selection_boxes);
				}
				facing_variants.push_back(var);
			}

			// A flowing liquid carries its level in param2, which is what
			// VoxelVariant is for: one per level, each a box with its own
			// top, and the mesher averages the four columns around each
			// corner so that the surface between them is continuous.
			sv_<interface::VoxelVariant> liquid_variants;
			if(drawtype == "flowingliquid" && !liquid_group.empty()){
				liquid_variants.resize(LIQUID_LEVELS);
				for(int level = 0; level < LIQUID_LEVELS; level++){
					interface::VoxelVariant &var = liquid_variants[level];
					var.liquid_top = liquid_level_top(level, liquid_range);
					add_box_quads(var.shape, -0.5f, -0.5f, -0.5f,
							0.5f, var.liquid_top, 0.5f);
				}
			}

			// The generated flat colour, for a node whose tiles the client
			// cannot load as they stand -- a texture modifier, or a name the
			// game did not ship. It is what every node wore before the
			// game's own media was served, and it stays until the client
			// resolves modifiers itself.
			ss_ fallback = empty ? "" : node_texture_name(name);
			ss_ face_textures[6];
			// How many animation frames each face's texture is a strip of;
			// the segment takes the first of them, so water is water and
			// not sixteen waters squeezed onto one face
			size_t face_frames[6] = {1, 1, 1, 1, 1, 1};
			bool any_fallback = false;
			for(size_t f = 0; f < 6; f++){
				if(empty)
					continue;
				ss_ texture = has_tiles ?
						texture_of_tile(with_palette(tiles[f], node_mul)) : "";
				if(!texture.empty()){
					face_textures[f] = texture;
					if(tile_aspect[f] > 0.0f)
						face_frames[f] = tile_frame_count(
								with_palette(tiles[f], node_mul),
								tile_aspect[f]);
				} else {
					face_textures[f] = fallback;
					any_fallback = true;
				}
			}
			// The plant of a rooted plant: a texture the cube it stands in
			// does not have, and the first of the definition's extra ones
			ss_ overlay_texture;
			if(!overlay_tile.empty() && !fallback.empty()){
				overlay_texture = texture_of_tile(
						with_palette(overlay_tile, node_mul));
				if(overlay_texture.empty()){
					overlay_texture = fallback;
					any_fallback = true;
				}
			}
			if(any_fallback && !fallback.empty()){
				textures.push_back(name);
				n_fallback++;
			}

			interface::VoxelDefinition vdef;
			vdef.name.block_name = name;
			vdef.name.segment_x = 0;
			vdef.name.segment_y = 0;
			vdef.name.segment_z = 0;
			vdef.name.rotation_primary = 0;
			vdef.name.rotation_secondary = 0;
			vdef.handler_module = "";
			for(size_t f = 0; f < 6; f++)
				vdef.textures[f] = make_segment(face_textures[f], surface,
						face_frames[f]);
			// The textures a shape's quads can wear beyond the six faces: a
			// rooted plant's plant, which is nothing the cube it stands in
			// has. Quad tile 6 is the first of these.
			if(!overlay_texture.empty())
				vdef.extra_textures.push_back(make_segment(overlay_texture,
						surface));
			// Which faces are drawn, as far as the edge material carries
			// Luanti's rules:
			//  - airlike is nothing at all, and nothing draws a face
			//    against it
			//  - glasslike gets an edge material of its own, so a face is
			//    drawn against anything except more of the same glass --
			//    a pane of it is a pane and a wall of it is a wall
			//  - allfaces draws every face, even between two of its own
			//    kind, which is what makes a tree's leaves look like leaves
			//  - everything else draws a face wherever the material changes
			//
			// Whether light gets past is a separate question now, and
			// transmits_light below is the answer to it.
			vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
			if(empty){
				vdef.edge_material_id = interface::EDGEMATERIALID_EMPTY;
			} else if(drawtype.compare(0, 9, "glasslike") == 0){
				vdef.edge_material_id = glass_edge_material(name);
			} else if(drawtype == "allfaces" ||
					drawtype == "allfaces_optional"){
				vdef.face_draw_type = interface::FaceDrawType::ALWAYS;
			}
			// An empty voxel already transmits light by being empty
			vdef.transmits_light = sunlight && !empty;
			vdef.light_source = light_source;
			vdef.physically_solid = walkable && !empty;
			// Nothing here draws differently for it; the client's own
			// physics is what reads it. See "the interaction gaps".
			vdef.climbable = climbable;
			if(walkable && !empty)
				turn_boxes(collision_boxes, 0, vdef.collision_boxes);
			turn_boxes(selection_boxes, 0, vdef.selection_boxes);
			vdef.move_resistance = (uint8_t)(move_resistance < 0 ? 0 :
					(move_resistance > 255 ? 255 : move_resistance));
			vdef.bouncy = (uint8_t)(bouncy < 0 ? 0 : (bouncy > 255 ? 255 : bouncy));
			vdef.slippery = (uint8_t)(slippery < 0 ? 0 :
					(slippery > 255 ? 255 : slippery));
			vdef.disable_jump = disable_jump;
			vdef.disable_descend = disable_descend;
			vdef.swimmable = swimmable;
			vdef.pointable = (uint8_t)(pointable < 0 ? 0 :
					(pointable > 2 ? 2 : pointable));
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
					// A shaped voxel draws its shape and not cube faces, and
					// its neighbours draw theirs against it
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
							facing_variant_of_param(facing, (uint8_t)p);
				}
				n_facing_nodes++;
			}
			// A palette: the node wears the colour its param2 picks, as its
			// own tiles through a modifier that multiplies them. Colours
			// multiply the directions rather than permuting with them, so
			// this is the facing variants once per colour -- eight colours
			// of a facedir node are 192 variants but 48 textures.
			//
			// A node whose tiles were not shipped wears a generated flat
			// colour and is left alone: there is no image for a modifier to
			// be applied to.
			if(!palette.empty() && !any_fallback){
				const sv_<uint32_t> &colours = palette_colours(palette);
				sv_<interface::VoxelVariant> base = vdef.variants;
				if(base.empty())
					base.push_back(interface::VoxelVariant());
				const size_t n_dirs = base.size();
				// Luanti stretches a palette over the 256 param2 values, so
				// what a param picks is the pixel at param * pixels / 256 --
				// which is also what leaves the direction bits alone,
				// because a sane palette has exactly as many colours as the
				// bits above the direction can count
				size_t slots = colours.size();
				if(slots > 256 / n_dirs)
					slots = 256 / n_dirs;
				if(slots > 0){
					sv_<interface::VoxelVariant> coloured;
					coloured.reserve(slots * n_dirs);
					for(size_t c = 0; c < slots; c++){
						// The tile through a modifier that multiplies it,
						// which is an expression like any other: the client
						// composes it and what the definition carries is the
						// name it composes it under
						const ss_ mul = "^[multiply:" + hex_colour(
								colours[c * colours.size() / slots]);
						ss_ tinted[7];
						for(size_t f = 0; f < 6; f++){
							if(has_tiles && !tiles[f].empty())
								tinted[f] = texture_of_tile(
										with_palette(tiles[f], mul));
						}
						if(!overlay_tile.empty())
							tinted[6] = texture_of_tile(
									with_palette(overlay_tile, mul));
						for(size_t i = 0; i < n_dirs; i++){
							interface::VoxelVariant var = base[i];
							for(size_t f = 0; f < 6; f++){
								var.textures.push_back(tinted[f].empty() ?
										interface::AtlasSegmentDefinition() :
										make_segment(tinted[f], surface,
										face_frames[f]));
							}
							if(!tinted[6].empty()){
								var.textures.push_back(
										make_segment(tinted[6], surface));
							}
							coloured.push_back(var);
						}
					}
					vdef.variants = coloured;
					for(size_t p = 0; p < 256; p++){
						const size_t c = palette_slot_of_param(slots,
								(uint8_t)p);
						vdef.variant_of_param[p] = (uint8_t)(c * n_dirs +
								(n_dirs > 1 ? facing_variant_of_param(
								facing, (uint8_t)p) : 0));
					}
					n_palette_nodes++;
					n_palette_variants += coloured.size();
				}
			}
			if(!liquid_group.empty()){
				vdef.is_liquid = true;
				vdef.liquid_is_source = (drawtype == "liquid");
				vdef.shape_group = liquid_shape_group(liquid_group);
				vdef.liquid_top = 0.5f;
				// param2's low three bits are the level; the rest of it is
				// flags this does not draw. Only a flowing liquid has them:
				// a source's param2 is whatever its own paramtype2 says,
				// which for VoxeLibre's water is the palette index its
				// colour comes from -- so assigning the levels over the
				// variants unconditionally took the sea's blue away.
				if(!liquid_variants.empty()){
					vdef.variants = liquid_variants;
					for(size_t p = 0; p < 256; p++)
						vdef.variant_of_param[p] = (uint8_t)(p % LIQUID_LEVELS);
				}
				n_liquid++;
			}
			// Which pass the faces go in. The mesher puts a translucent
			// voxel's faces on a child node of the chunk and
			// builtin/voxel_shading gives that one the blended technique.
			//
			// A liquid always, and anything the game asked to be blended
			// rather than alpha masked.
			vdef.translucent = alpha_blend || !liquid_group.empty();
			// And the cut-out ones, which are drawn with the solid world
			// with the holes in their pictures left out: a leaf, a plant, a
			// rail, a ladder. Luanti's default for every drawtype but the
			// five solid ones, so most of a game's nodes end up here.
			vdef.alpha_masked = alpha_clip && !vdef.translucent;
			reg->add_voxel(vdef);
		}
		lua_settop(L, base);

		serve_node_textures(textures);
		log_i(MODULE, "%zu node types in the voxel registry: %zu have a shape "
				"of their own, %zu of those are liquids, %zu turn with their "
				"param2, %zu wear a colour out of a palette (%zu variants), "
				"%zu wear a generated colour because a tile is a "
				"texture modifier or was not shipped",
				n, n_shaped, n_liquid, n_facing_nodes, n_palette_nodes,
				n_palette_variants, n_fallback);
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
