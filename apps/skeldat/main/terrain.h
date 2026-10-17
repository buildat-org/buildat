// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The world's making**: the generator's bones and
// piles on Luanti's mapgen, the mapgen's parameters and the nodes as
// Luanti sees them, the spawn, and what the made world is reported as
// (the survey, the edge's check, the admin's map).
// Included by main.cpp inside namespace skeldat, after drops.h
#pragma once

// The mapgen's section, skelenti's bone piles on its ground (bones.h's
// pile()), and its bones seeded by the place's danger: every voxel that is
// not air in a column at bones::SEED_DANGER or more, a pile's too. Runs on
// worldgen's worker thread, so it touches nothing but the volume.
struct BonesGenerator: public worldgen::GeneratorInterface
{
	// The nodes a pile is made of and stands on
	struct PileIds {
		uint32_t block = 0, tops[3] = {}, ground[3] = {};
	};
	up_<worldgen::GeneratorInterface> m_inner;
	interface::VoxelFormat m_format;
	interface::VoxelField m_bones;
	uint32_t m_salt;
	// The world's half in voxels, for the seeding's bias
	int m_half_v = skeldat::bones::HALF;
	// The highest voxel any section was made with
	std::atomic<int> m_top{-100000};
	// For a check: every voxel seeded at MAX (BUILDAT_SKELDAT_FILL), a
	// world that ends at once
	// For a check: every voxel at MAX (1), or those at x >= 0 (2), or
	// those with air over them, the surface (3)
	int m_fill = 0;
	PileIds m_ids;

	BonesGenerator(worldgen::GeneratorInterface *inner,
			const interface::VoxelFormat &format,
			const interface::VoxelField &bones, uint32_t salt,
			const PileIds &ids):
		m_inner(inner), m_format(format), m_bones(bones), m_salt(salt),
		m_ids(ids){}

	// The ground is the column's highest voxel in the section (lc..uc)
	// that is not air; the stack may rise into the padding above, which
	// the section over it takes as a tree's crown.
	// simplified: a pile whose stack would leave the volume is not made,
	// as a Luanti chunk's is not in skelenti, nor one on ground in the
	// section's top layer (what is over it is the next section's, unknown
	// here): about a sixteenth of them
	void piles(interface::VoxelVolume &volume, const pv::Vector3DInt32 &lc,
			const pv::Vector3DInt32 &uc, int32_t top)
	{
		auto id_at = [&](int32_t x, int32_t y, int32_t z){
			return m_format.id.get(volume.getVoxelAt(x, y, z).data);
		};
		int made = 0;
		for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int32_t x = lc.getX(); x <= uc.getX(); x++){
			skeldat::bones::Pile p;
			// FILL=half's clean side stays clean
			if((m_fill == 2 && x < 0) ||
					!skeldat::bones::pile(m_salt, x, z, p, m_half_v))
				continue;
			int32_t y = uc.getY();
			while(y >= lc.getY() && id_at(x, y, z) == ID_AIR)
				y--;
			if(y < lc.getY() || y == uc.getY() || y + 6 > top)
				continue;
			const uint32_t ground = id_at(x, y, z);
			if(ground != m_ids.ground[0] && ground != m_ids.ground[1] &&
					ground != m_ids.ground[2])
				continue;
			for(int i = 1; i <= p.height + 1; i++){
				uint32_t word = volume.getVoxelAt(x, y + i, z).data;
				const uint32_t here = m_format.id.get(word);
				if(here != ID_AIR && here != ID_IGNORE)
					break;
				if(i <= p.height){
					m_format.id.set(word, m_ids.block);
				} else if(p.top <= 3){
					m_format.id.set(word, m_ids.tops[p.top - 1]);
					m_format.param.set(word, (uint32_t)p.turn);
				} else {
					break;
				}
				volume.setVoxelAt(x, y + i, z, VoxelInstance(word));
			}
			made++;
		}
		// The first section with any, for check.sh; one a section would be
		// hundreds of lines
		static std::atomic<bool> told(false);
		if(made > 0 && !told.exchange(true))
			log_i(MODULE, "skeldat: the first bone piles, %d in the section "
					"at (%d, %d, %d)", made, lc.getX(), lc.getY(), lc.getZ());
	}

	pv::Vector3DInt32 get_padding_voxels()
	{
		return m_inner->get_padding_voxels();
	}

	void generate(main_context::SceneReference scene,
			const pv::Vector3DInt16 &section_p, interface::VoxelVolume &volume)
	{
		m_inner->generate(scene, section_p, volume);
		volume.add_planes(m_format.planes);
		const pv::Region &r = volume.getEnclosingRegion();
		const pv::Vector3DInt32 &lc = r.getLowerCorner(),
				&uc = r.getUpperCorner();
		const pv::Vector3DInt32 pad = m_inner->get_padding_voxels();
		piles(volume, lc + pad, uc - pad, uc.getY());
		// The highest voxel made, for the world's bounds' check
		for(int32_t y = uc.getY() - pad.getY(); y > m_top &&
				y >= lc.getY() + pad.getY(); y--){
			bool any = false;
			for(int32_t z = lc.getZ() + pad.getZ(); !any &&
					z <= uc.getZ() - pad.getZ(); z++)
			for(int32_t x = lc.getX() + pad.getX(); !any &&
					x <= uc.getX() - pad.getX(); x++){
				const uint32_t id = m_format.id.get(
						volume.getVoxelAt(x, y, z).data);
				any = id != ID_IGNORE && id != ID_AIR;
			}
			if(any){
				int top = m_top;
				while(y > top && !m_top.compare_exchange_weak(top, y)){}
				break;
			}
		}
		for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int32_t x = lc.getX(); x <= uc.getX(); x++){
			const int b = m_fill == 1 || m_fill == 3 ||
					(m_fill == 2 && x >= 0) ?
					skeldat::bones::MAX : m_fill == 2 ? 0 :
					skeldat::bones::seed_value(skeldat::bones::danger(m_salt,
					(float)x, (float)z, m_half_v));
			if(b == 0)
				continue;
			for(int32_t y = lc.getY(); y <= uc.getY(); y++){
				const uint32_t id = m_format.id.get(
						volume.getVoxelAt(x, y, z).data);
				if(id == ID_IGNORE || id == ID_AIR)
					continue;
				if(m_fill == 3){
					const uint32_t over = m_format.id.get(
							volume.getVoxelAt(x, y + 1, z).data);
					if(over != ID_AIR && over != ID_IGNORE)
						continue;
				}
				uint32_t word = volume.plane_at(1, x, y, z);
				m_bones.set(word, (uint32_t)b);
				volume.set_plane_at(1, x, y, z, word);
			}
		}
	}
};

struct Terrain
{
	WorldView &world;
	// The Module's, the world's save and its skeldat store while open
	storage::Save *&save;
	storage::Store *&store;
	Drops &drops;
	luanti_mapgen::Params mapgen;
	bool spawn_ready = false;

	Terrain(WorldView &world, storage::Save *&save, storage::Store *&store,
			Drops &drops):
		world(world), save(save), store(store), drops(drops)
	{}

	// A voxel id's node as Luanti would have it defined, which is what
	// builtin/luanti's registry builder and the mapgen read
	luanti_registry::NodeDef luanti_def(uint32_t id)
	{
		luanti_registry::NodeDef d;
		if(id == ID_AIR){
			d.name = "air";
			d.drawtype = "airlike";
			d.empty = true;
			d.walkable = false;
			d.pointable = 0;
			d.sunlight = true;
			d.param_type_light = true;
			d.floodable = true;
			return d;
		}
		// Never generated; drawn as stone if a save has one
		const skeldat::NodeDef &n = world.node_of(id) ? *world.node_of(id) :
				*world.node_of(world.id_of("skeldat:stone"));
		d.name = world.node_of(id) ? n.name : "unknown";
		d.groups = n.groups;
		d.light_source = (uint8_t)n.light_source;
		d.has_tiles = true;
		for(int i = 0; i < 6; i++)
			d.tiles[i] = n.tiles[i];
		d.param_type_light = n.shape != skeldat::CUBE;
		// Leaves let light in but not the sun, as Luanti's do
		d.sunlight = n.shape == skeldat::NODEBOX || n.shape == skeldat::TORCH;
		switch(n.shape){
		case skeldat::CUBE:
			break;
		case skeldat::ALLFACES:
			d.drawtype = "allfaces_optional";
			d.alpha_clip = true;
			break;
		case skeldat::LIQUID:
			d.drawtype = "liquid";
			d.liquid_group = n.name;
			d.walkable = false;
			d.swimmable = true;
			d.pointable = 0;
			break;
		case skeldat::NODEBOX:
			d.drawtype = "nodebox";
			d.node_box = d.selection_box = n.boxes;
			if(n.walkable)
				d.collision_box = n.boxes;
			else
				d.walkable = false;
			break;
		case skeldat::TORCH:
			d.drawtype = "torchlike";
			d.walkable = false;
			d.alpha_clip = true;
			d.selection_box = n.boxes;
			break;
		}
		// param2 0 to 3, the way the player looked when placing it
		if(n.facedir)
			d.facing = "4dir";
		if(n.wallmounted)
			d.facing = "wallmounted";
		return d;
	}

	luanti_mapgen::Params mapgen_params(uint32_t seed)
	{
		luanti_mapgen::Params mp;
		mp.mgname = "valleys";
		mp.seed = seed;
		// A world 64 high ([SKELDAT_WORLD_SIZES]) is y 0..63, its water at
		// 20; one 128 high is y -64..63, water at 1
		const bool low = world.y0 >= 0;
		const int wl = low ? 20 : 1, lift = wl - 1;
		mp.water_level = wl;
		mp.section_size = skeldat::bones::SECTION;
		// The terrain's spreads by the world's width, not under 128, so a
		// small world still has a valley and a hill
		const float width = 2.0f * world.half * skeldat::bones::SECTION,
				th_spread = std::max(128.0f, width),
				vd_spread = std::max(128.0f, width / 2);
		// The valleys squeezed into the world's 128 voxels of height
		// ([SKELDAT_BOUNDED_WORLD]): over 1024² at seeds 1-12 the top
		// solid voxel is at -6..54, where the defaults' is at -67..258.
		// Spreads, seeds, octaves and the rest are the mapgen's defaults.
		auto noise = [&](const char *name, float offset, float scale,
				float spread, int32_t seed, int32_t octaves, float persist){
			luanti_mapgen::Params::NoiseParams np;
			np.given = true;
			np.offset = offset;
			np.scale = scale;
			np.spread_x = np.spread_y = np.spread_z = spread;
			np.seed = seed;
			np.octaves = octaves;
			np.persist = persist;
			mp.noises[name] = np;
		};
		// 64 high: over seeds 1-12 the top solid voxel at 11..44 (the
		// survey as for the 128 one, at widths 256 and 128)
		if(low){
			noise("mgvalleys_np_terrain_height", 22, 10, th_spread, 5202, 6,
					0.4f);
			noise("mgvalleys_np_valley_depth", 1.5f, 0.8f, vd_spread, -1914,
					1, 1.0f);
		} else {
			noise("mgvalleys_np_terrain_height", 8, 12, th_spread, 5202, 6,
					0.4f);
			noise("mgvalleys_np_valley_depth", 2.5f, 1.2f, vd_spread, -1914,
					1, 1.0f);
		}
		noise("mgvalleys_np_inter_valley_slope", 0.3f, 0.3f, 128, 746, 1,
				1.0f);
		for(size_t i = 0; i < world.game.nodes.size(); i++)
			mp.content_ids[world.game.nodes[i].name] = (uint32_t)i + ID_NODE0;
		mp.content_ids["air"] = ID_AIR;
		mp.content_ids["ignore"] = ID_IGNORE;
		mp.content_ids["unknown"] = ID_UNKNOWN;
		const uint32_t stone = world.id_of("skeldat:stone"),
				water = world.id_of("skeldat:water_source");
		mp.content_ids["mapgen_stone"] = stone;
		mp.content_ids["mapgen_water_source"] = water;
		mp.content_ids["mapgen_river_water_source"] = water;
		mp.content_ids["mapgen_cobble"] = world.id_of("skeldat:cobble");
		for(uint32_t id = ID_AIR; id < ID_NODE0 + world.game.nodes.size(); id++)
			if(id == ID_AIR || world.node_of(id))
				mp.node_props[id] = luanti_registry::mapgen_props(luanti_def(id));
		auto biome = [&](const ss_ &name, const ss_ &top, int depth_top,
				const ss_ &filler, int depth_filler, const ss_ &riverbed,
				int y_min, int y_max){
			luanti_mapgen::Params::Biome b;
			b.name = name;
			b.c_top = world.id_of(top);
			b.c_filler = world.id_of(filler);
			b.c_stone = stone;
			b.c_water_top = b.c_water = b.c_river_water = water;
			b.c_riverbed = riverbed.empty() ? stone : world.id_of(riverbed);
			b.c_dust = b.c_dungeon = b.c_dungeon_alt = b.c_dungeon_stair =
					ID_IGNORE;
			b.depth_top = depth_top;
			b.depth_filler = depth_filler;
			b.depth_riverbed = riverbed.empty() ? 0 : 2;
			b.y_min = y_min;
			b.y_max = y_max;
			b.heat_point = b.humidity_point = 50;
			mp.biomes.push_back(b);
		};
		biome("grassland", "skeldat:grass", 1, "skeldat:dirt", 3,
				"skeldat:sand", 4 + lift, 31000);
		biome("beach", "skeldat:sand", 1, "skeldat:sand", 2, "skeldat:sand",
				-6 + lift, 3 + lift);
		biome("seabed", "skeldat:gravel", 1, "skeldat:sand", 2, "",
				-31000, -7 + lift);
		auto ore = [&](const ss_ &name, int scarcity, int num, int y_max,
				int y_min){
			luanti_mapgen::Params::Ore o;
			o.name = name;
			o.c_ore = world.id_of(name);
			o.c_wherein = {stone};
			o.clust_scarcity = scarcity;
			o.clust_num_ores = num;
			o.clust_size = 3;
			o.y_min = y_min;
			o.y_max = y_max;
			mp.ores.push_back(o);
		};
		ore("skeldat:coal_ore", 8 * 8 * 8, 8, 64, -31000);
		// 64 high, each still under the surface (11 and up)
		ore("skeldat:iron_ore", 10 * 10 * 10, 5, low ? 14 : 0, -31000);
		ore("skeldat:diamond_ore", 15 * 15 * 15, 4, low ? 6 : -48, -31000);
		ore("skeldat:gravel", 16 * 16 * 16, 20, 64, -31000);
		ore("skeldat:dirt", 16 * 16 * 16, 20, 64, low ? 4 : -32);
		// A tree, 5x6x5: a trunk of four, leaves around its top two and
		// over it
		luanti_mapgen::Params::Decoration d;
		d.name = "skeldat:tree";
		d.type = "schematic";
		d.c_place_on = {world.id_of("skeldat:grass")};
		d.sidelen = 16;
		d.fill_ratio = 0.006f;
		d.biomes = {"grassland"};
		d.y_min = 4 + lift;
		d.y_max = 200;
		d.flags = "place_center_x, place_center_z";
		// Luanti puts a schematic's layer 0 at the place_on node, and the
		// force-placed trunk took the grass: one up, the trunk on it
		// ([SKELDAT_TREE_DEPTH])
		d.place_offset_y = 1;
		d.rotation = "random";
		luanti_mapgen::Params::Schematic &s = d.schematic;
		s.given = true;
		s.size_x = 5; s.size_y = 6; s.size_z = 5;
		s.node_names = {"skeldat:tree", "skeldat:leaves", "air"};
		for(int z = 0; z < 5; z++) for(int y = 0; y < 6; y++)
		for(int x = 0; x < 5; x++){
			const bool trunk = x == 2 && z == 2 && y < 4;
			const bool edge = (x == 0 || x == 4) && (z == 0 || z == 4);
			const bool inner = x >= 1 && x <= 3 && z >= 1 && z <= 3;
			const bool leaf = ((y == 2 || y == 3) && !edge) ||
					(y == 4 && inner) ||
					(y == 5 && (x == 2 || z == 2) && inner);
			s.ids.push_back(trunk ? 0 : leaf ? 1 : 2);
			// Half the probability, and force_place in the high bit, as
			// a .mts file holds it
			s.param1.push_back(trunk ? 127 + 128 : leaf ? 127 : 0);
			s.param2.push_back(0);
		}
		mp.decorations.push_back(d);
		return mp;
	}

	// Luanti's spawn search: out from the origin until the mapgen says a
	// column is land, kept in the save so that it does not move
	// Where a player starts, found on the world once it is in: a dry
	// column near the origin with no bones, not a tree top, read off the
	// voxels (valleys' own spawn level refuses any ground over water level
	// + 16, half of this world's)
	void find_spawn()
	{
		using namespace skeldat::bones;
		ss_ v;
		if(store->get("spawn", v)){
			std::istringstream(v)>>world.spawn[0]>>world.spawn[1]>>world.spawn[2];
			spawn_ready = true;
			return;
		}
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			// The feet's y on the column's top, or false for water or a tree
			const int y1 = (world.y1 + 1) * SECTION - 1, y0 = world.y0 * SECTION;
			auto ground = [&](int x, int z, int &feet){
				for(int y = y1 - 2; y > y0; y--){
					if(!world.walkable(w, x, y, z)){
						if(world.is_water(w, x, y, z))
							return false;
						continue;
					}
					const skeldat::NodeDef *n = world.node_of(world.wid(w, x, y, z));
					if(n && (n->name.find("leaves") != ss_::npos ||
							n->name.find("tree") != ss_::npos))
						return false;
					feet = y + 1;
					return true;
				}
				return false;
			};
			// For a check: the spawn's column, the zones allowed, "x z" or
			// "x y z" (a place under the ground: a cave)
			const char *env = getenv("BUILDAT_SKELDAT_SPAWN");
			int ex = 0, ey = 0, ez = 0;
			const int got = env ? sscanf(env, "%d %d %d", &ex, &ey, &ez) : 0;
			if(got == 2){
				ez = ey;
				ey = y1;
				ground(ex, ez, ey);
			}
			if(got >= 2){
				world.spawn[0] = (float)ex;
				world.spawn[1] = (float)ey;
				world.spawn[2] = (float)ez;
				spawn_ready = true;
			}
			std::mt19937 r(mapgen.seed);
			for(int i = 0; i < 4000 && !spawn_ready; i++){
				const int range = std::min(32 + i / 4, world.half * SECTION - 16);
				const int x = (int)(r() % (2 * range)) - range;
				const int z = (int)(r() % (2 * range)) - range;
				int feet = 0;
				if(!ground(x, z, feet) || feet < mapgen.water_level + 1 ||
						seed_value(skeldat::bones::danger(
						(uint32_t)mapgen.seed, (float)x, (float)z,
						world.half * SECTION)) > 0)
					continue;
				world.spawn[0] = (float)x;
				world.spawn[1] = (float)feet;
				world.spawn[2] = (float)z;
				spawn_ready = true;
			}
			// [SKELDAT_STARTER_ITEMS]: a bow and 4 arrows' worth near a new
			// world's spawn, once (a stored spawn returned above); scattered
			// 3 to 6 voxels off, on the ground, else on the spawn's column
			const char *starter = getenv("BUILDAT_SKELDAT_STARTER");
			if(!spawn_ready || (starter && ss_(starter) == "0"))
				return;
			const int sx = (int)world.spawn[0], sz = (int)world.spawn[2];
			for(int i = 0; i < 8; i++){
				int x = sx, z = sz, feet = (int)world.spawn[1];
				for(int k = 0; k < 8; k++){
					const int dx = (int)(r() % 13) - 6, dz = (int)(r() % 13) - 6;
					int f = 0;
					if(std::max(std::abs(dx), std::abs(dz)) >= 3 &&
							ground(sx + dx, sz + dz, f)){
						x = sx + dx, z = sz + dz, feet = f;
						break;
					}
				}
				drops.drop(Stack(i < 4 ? "skeldat:stick" : "skeldat:bone"),
						(float)x, (float)feet + 0.5f, (float)z);
			}
		});
		if(!spawn_ready){
			world.spawn[1] = (float)((world.y1 + 1) * SECTION - 1);
			spawn_ready = true;
		}
		std::ostringstream os;
		os<<world.spawn[0]<<" "<<world.spawn[1]<<" "<<world.spawn[2];
		store->set("spawn", os.str());
		log_i(MODULE, "skeldat: spawn at %s", cs(os.str()));
	}

	// For a check (BUILDAT_SKELDAT_SURVEY, [SKELDAT_WORLD_SIZES]): what was
	// made -- the tops' range, the ores, the edge's and the origin's bones
	// -- in a line, and the map into the save
	void survey()
	{
		const int S = skeldat::bones::SECTION, h = world.half * S;
		int lo = 1000, hi = -1000, edge = 0, edge_max = 0;
		for(int z = -h; z < h; z++)
		for(int x = -h; x < h; x++){
			const long c = world.column(x, z);
			if(world.top_y[c] != NO_GROUND)
				lo = std::min(lo, (int)world.top_y[c]),
				hi = std::max(hi, (int)world.top_y[c]);
			if(x == -h || x == h - 1 || z == -h || z == h - 1)
				edge++, edge_max += world.top_b[c] == skeldat::bones::MAX;
		}
		std::map<uint32_t, size_t> ores;
		// The trees' lowest trunk voxels, and those on grass
		// ([SKELDAT_TREE_DEPTH])
		const uint32_t trunk = world.id_of("skeldat:tree"),
				grass = world.id_of("skeldat:grass");
		size_t trunks = 0, on_grass = 0;
		for(const char *n : {"skeldat:coal_ore", "skeldat:iron_ore",
				"skeldat:diamond_ore"})
			ores[world.id_of(n)] = 0;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			for(int sz = -world.half; sz < world.half; sz++)
			for(int sx = -world.half; sx < world.half; sx++){
				const interface::VoxelVolume vol = w->get_volume(pv::Region(
						pv::Vector3DInt32(sx * S, world.y0 * S, sz * S),
						pv::Vector3DInt32(sx * S + S - 1, world.y1 * S + S - 1,
						sz * S + S - 1)));
				for(int z = sz * S; z < sz * S + S; z++)
				for(int y = world.y0 * S; y < (world.y1 + 1) * S; y++)
				for(int x = sx * S; x < sx * S + S; x++){
					const uint32_t id = world.format.id.get(vol.sample_at(x, y, z));
					auto it = ores.find(id);
					if(it != ores.end())
						it->second++;
					if(id == trunk && y > world.y0 * S){
						const uint32_t under = world.format.id.get(
								vol.sample_at(x, y - 1, z));
						if(under != trunk)
							trunks++, on_grass += under == grass;
					}
				}
			}
		});
		log_i(MODULE, "skeldat: survey: tops %d..%d, coal %zu, iron %zu, "
				"diamond %zu, edge columns at full bones %d of %d, the "
				"origin's %d, trunks on grass %zu of %zu", lo, hi,
				ores[world.id_of("skeldat:coal_ore")],
				ores[world.id_of("skeldat:iron_ore")],
				ores[world.id_of("skeldat:diamond_ore")], edge_max, edge,
				(int)world.top_b[world.column(0, 0)], on_grass, trunks);
		write_map();
	}

	// **The world's edge** ([SKELDAT_EDGE_RIDGE]), once, when the world is
	// first in: over the last EDGE_COLUMNS of each side a hillside of bone
	// blocks from the column's ground (under water, its bed) by
	// bones::edge_rise(), and the outermost column bone_wall from the
	// bottom layer to the hillside's top, which nothing digs.
	// simplified: made here on the whole world, not in the generator,
	// which sees one 64-high section and not a ground in the one under it
	void make_edge()
	{
		using namespace skeldat::bones;
		std::string v;
		if(!store || store->get("edge", v))
			return;
		const int64_t t0 = interface::os::time_us();
		const int S = SECTION, h = world.half * S, y0 = world.y0 * S,
				top = (world.y1 + 1) * S - 1;
		const uint32_t block = world.id_of("skeldat:bone_block"),
				wall = world.id_of("skeldat:bone_wall");
		size_t blocks = 0, walls = 0;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			for(int sz = -world.half; sz < world.half; sz++)
			for(int sx = -world.half; sx < world.half; sx++){
				if(sx != -world.half && sx != world.half - 1 && sz != -world.half &&
						sz != world.half - 1)
					continue;
				const pv::Region r(pv::Vector3DInt32(sx * S, y0, sz * S),
						pv::Vector3DInt32(sx * S + S - 1, top, sz * S + S - 1));
				const interface::VoxelVolume vol = w->get_volume(r);
				interface::VoxelVolume out(r, world.format.planes);
				size_t changed = 0;
				auto put = [&](int x, int y, int z, uint32_t id){
					interface::VoxelSample s = vol.sample_at(x, y, z);
					s.planes[0] = 0;
					world.format.id.set(s.planes[0], id);
					world.bones.set(s, MAX);
					out.set_sample_at(x, y, z, s);
					changed++;
				};
				for(int z = sz * S; z < sz * S + S; z++)
				for(int x = sx * S; x < sx * S + S; x++){
					const int d = std::min(std::min(x + h, h - 1 - x),
							std::min(z + h, h - 1 - z));
					if(d >= EDGE_COLUMNS)
						continue;
					// The ground: the top voxel that is not air or water
					int g = top;
					for(; g > y0; g--){
						const uint32_t id = world.format.id.get(vol.sample_at(x, g, z));
						const skeldat::NodeDef *n = world.node_of(id);
						if(id != ID_AIR && id != ID_IGNORE &&
								!(n && n->shape == skeldat::LIQUID))
							break;
					}
					const int rise = edge_rise(d, top - 1 - g);
					for(int y = g + 1; y <= g + rise; y++){
						const uint32_t id = world.format.id.get(vol.sample_at(x, y, z));
						const skeldat::NodeDef *n = world.node_of(id);
						if(id == ID_AIR || (n && (n->shape == skeldat::LIQUID ||
								n->name == "skeldat:leaves")))
							put(x, y, z, block), blocks++;
					}
					if(d == 0)
						for(int y = y0; y <= g + rise; y++)
							put(x, y, z, wall), walls++;
				}
				if(changed)
					w->set_volume(out);
			}
		});
		store->set("edge", "1");
		log_i(MODULE, "skeldat: the edge made: %zu bone blocks, %zu wall "
				"voxels, %.1f ms", blocks, walls,
				(interface::os::time_us() - t0) / 1e3);
	}

	ss_ write_map()
	{
		const int S = skeldat::bones::SECTION, W = 2 * world.half * S;
		sv_<unsigned char> rgb((size_t)W * W * 3, 0);
		const uint32_t grass = world.id_of("skeldat:grass");
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			for(int sz = -world.half; sz < world.half; sz++)
			for(int sx = -world.half; sx < world.half; sx++)
			world.each_top(w, sx, sz, [&](int x, int z, int, uint32_t id,
					const interface::VoxelSample &v){
				const skeldat::NodeDef *n = world.node_of(id);
				const bool water = n && n->shape == skeldat::LIQUID;
				const float base[3] = {
					id == grass ? 60.f : water ? 40.f : 128.f,
					id == grass ? 140.f : water ? 80.f : 128.f,
					id == grass ? 60.f : water ? 200.f : 128.f};
				const float b = world.bones.get(v) / (float)skeldat::bones::MAX;
				const size_t i = ((size_t)(W - 1 - (z + world.half * S)) * W +
						(x + world.half * S)) * 3;
				for(int k = 0; k < 3; k++)
					rgb[i + k] = (unsigned char)(base[k] + (240 - base[k]) * b);
			});
		});
		const ss_ path = save->path()+"/map.png";
		bool ok = false;
		main_context::access(world.server, [&](main_context::Interface *imc){
			Urho3D::Image img(imc->get_context());
			ok = img.SetSize(W, W, 3);
			if(ok){
				img.SetData(rgb.data());
				ok = img.SavePNG(path.c_str());
			}
		});
		log_i(MODULE, "skeldat: the map %s %s", ok ? "written to" :
				"not written to", cs(path));
		return (ok ? "Written to " : "Not written to ")+path;
	}
};
// vim: set noet ts=4 sw=4:
