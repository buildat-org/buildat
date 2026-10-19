// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The world's making**: skeldat's own generator
// ([SKELDAT_OWN_MAPGEN], off mapgen.h's heightmap), the bones and piles
// on it, the nodes as Luanti's registry sees them, the spawn, and what the
// made world is reported as (the survey, the edge's check, the admin's
// map).
// Included by main.cpp inside namespace skeldat, after drops.h
#pragma once

// [SKELDAT_OWN_MAPGEN] A section off the whole world's heightmap
// (mapgen.h, shared and read only): stone, 3 of dirt and grass on top --
// sand for all 4 under water and on its shore, a river channel's bed
// gravel -- the bottom layer stone; the noodle caves carved (none in the
// bottom 2, none within 4 under water, and the ground voxel by the exact
// noise, the rest by a lattice every 4); the
// ores scattered by a hash of the section and the seed (Luanti's scatter:
// clusters of 3x3x3 by scarcity); the trees on grass, a tree's leaves only
// into air and its trunk over them, each section placing its own part of
// any tree within 2 of it (none within 2 of water). The water: a column
// the heightmap gives water filled with full water (param2 0) from over
// its ground up to its top (caves are under the ground and not filled);
// a river's inlet column springs, its outlet column drains. The sky's
// light down each column to its first voxel; the rest is voxelworld's
// relight of a new world.
struct SkeldatGenerator: public worldgen::GeneratorInterface
{
	struct Ids {
		uint32_t stone = 0, dirt = 0, grass = 0, sand = 0, tree = 0, leaves = 0,
				water = 0, gravel = 0, spring = 0, drain = 0, level_drain = 0;
	};
	struct Ore {
		uint32_t id;
		int scarcity, num, y_max;
	};
	interface::VoxelFormat m_format;
	std::shared_ptr<const mapgen::Heightmap> m_map;
	mapgen::Params m_p;
	Ids m_ids;
	sv_<Ore> m_ores;

	SkeldatGenerator(const interface::VoxelFormat &format,
			std::shared_ptr<const mapgen::Heightmap> map, const mapgen::Params &p,
			const Ids &ids, const sv_<Ore> &ores):
		m_format(format), m_map(map), m_p(p), m_ids(ids), m_ores(ores){}

	int ground(int x, int z) const { return (int)std::floor(m_map->at(x, z)); }
	uint8_t flags(int x, int z) const
	{
		return m_map->in(x, z) ? m_map->flags[m_map->index(x, z)] : 0;
	}
	// Caves may carve here: off the bottom 2 and not within 4 under water;
	// on flat not within FLAT_CAVE_ROOF under the ground
	bool carvable(int y, int g, uint8_t f) const
	{
		return y > m_p.bottom + 1 && !((f & mapgen::WATER) && y >= g - 4) &&
				!(m_p.form == mapgen::FLAT && y > g - mapgen::FLAT_CAVE_ROOF);
	}
	// A tree on the column: on grass, which is not carved, and not within
	// 2 of water; on flat none near the origin (the spawn)
	bool has_tree(int x, int z) const
	{
		if(!m_map->in(x, z) || !mapgen::tree_at(x, z, m_p.seed))
			return false;
		if(m_p.form == mapgen::FLAT && x * x + z * z <
				mapgen::FLAT_TREE_CLEAR * mapgen::FLAT_TREE_CLEAR)
			return false;
		const int g = ground(x, z);
		const uint8_t f = flags(x, z);
		return !(f & (mapgen::WATER | mapgen::SHORE | mapgen::NEAR_WATER)) &&
				!(carvable(g, g, f) && mapgen::cave((float)x, (float)g, (float)z,
				m_p.seed));
	}

	void generate(main_context::SceneReference scene,
			const pv::Vector3DInt16 &section_p, interface::VoxelVolume &volume)
	{
		const pv::Region &r = volume.getEnclosingRegion();
		const pv::Vector3DInt32 &lc = r.getLowerCorner(), &uc = r.getUpperCorner();
		auto word_of = [&](uint32_t id, int sky){
			uint32_t w = 0;
			m_format.id.set(w, id);
			m_format.light_sky.set(w, (uint32_t)sky);
			return w;
		};
		// The caves' noises on a lattice every 4 over the region: the
		// tunnels' two and their width's, the caverns'
		// ([SKELDAT_CAVES_ROOMY])
		const int G = 4;
		const int gx = (uc.getX() - lc.getX()) / G + 2,
				gy = (uc.getY() - lc.getY()) / G + 2,
				gz = (uc.getZ() - lc.getZ()) / G + 2;
		sv_<float> na((size_t)gx * gy * gz), nb(na.size()), nw(na.size()),
				nc(na.size());
		for(int k = 0; k < gz; k++)
		for(int j = 0; j < gy; j++)
		for(int i = 0; i < gx; i++){
			const float x = (float)(lc.getX() + i * G), y = (float)(lc.getY() + j * G),
					z = (float)(lc.getZ() + k * G);
			const size_t n = ((size_t)k * gy + j) * gx + i;
			na[n] = mapgen::fbm3(x / mapgen::CAVE_SPREAD_XZ, y / mapgen::CAVE_SPREAD_Y,
					z / mapgen::CAVE_SPREAD_XZ, m_p.seed + 7001, 2, 0.5f);
			nb[n] = mapgen::fbm3(x / mapgen::CAVE_SPREAD_XZ, y / mapgen::CAVE_SPREAD_Y,
					z / mapgen::CAVE_SPREAD_XZ, m_p.seed + 9103, 2, 0.5f);
			nw[n] = mapgen::cave_width_noise(x, y, z, m_p.seed);
			nc[n] = mapgen::cavern_noise(x, y, z, m_p.seed);
		}
		auto lerp3 = [&](const sv_<float> &v, int x, int y, int z){
			const int ox = x - lc.getX(), oy = y - lc.getY(), oz = z - lc.getZ();
			const int i = ox / G, j = oy / G, k = oz / G;
			const float tx = (ox % G) / (float)G, ty = (oy % G) / (float)G,
					tz = (oz % G) / (float)G;
			auto at = [&](int a, int b, int c){
				return v[((size_t)(k + c) * gy + (j + b)) * gx + (i + a)];
			};
			const float x00 = at(0, 0, 0) + (at(1, 0, 0) - at(0, 0, 0)) * tx,
					x10 = at(0, 1, 0) + (at(1, 1, 0) - at(0, 1, 0)) * tx,
					x01 = at(0, 0, 1) + (at(1, 0, 1) - at(0, 0, 1)) * tx,
					x11 = at(0, 1, 1) + (at(1, 1, 1) - at(0, 1, 1)) * tx;
			const float y0 = x00 + (x10 - x00) * ty, y1 = x01 + (x11 - x01) * ty;
			return y0 + (y1 - y0) * tz;
		};
		for(int z = lc.getZ(); z <= uc.getZ(); z++)
		for(int x = lc.getX(); x <= uc.getX(); x++){
			const bool in = m_map->in(x, z);
			const int g = in ? ground(x, z) : m_p.bottom;
			const uint8_t f = flags(x, z);
			const bool sandy = f & (mapgen::WATER | mapgen::SHORE);
			const int wt = f & mapgen::WATER ? m_map->water[m_map->index(x, z)] : g;
			const uint32_t water = f & mapgen::SPRING ? m_ids.spring :
					f & mapgen::DRAIN ? m_ids.drain : m_ids.water;
			// The sea's edge: a drain drawn as nothing over its water
			// ([SKELDAT_LOW_BANKS]: the sea flat into the backdrop's)
			const int drain_top = f & mapgen::LEVEL_DRAIN ? wt + 1 : wt;
			const uint32_t top = f & mapgen::CHANNEL ? m_ids.gravel :
					sandy ? m_ids.sand : m_ids.grass;
			for(int y = lc.getY(); y <= uc.getY(); y++){
				uint32_t id = y > g && y <= wt ? water :
						y > wt && y <= drain_top ? m_ids.level_drain : ID_AIR;
				if(y <= m_p.bottom)
					id = m_ids.stone;
				else if(y <= g){
					bool carved = false;
					if(carvable(y, g, f)){
						if(y == g)
							carved = mapgen::cave((float)x, (float)y, (float)z, m_p.seed);
						else {
							const float w = mapgen::cave_width(lerp3(nw, x, y, z));
							carved = (std::fabs(lerp3(na, x, y, z)) < w &&
									std::fabs(lerp3(nb, x, y, z)) < w) ||
									lerp3(nc, x, y, z) > mapgen::cavern_threshold(y,
									m_p.bottom, g);
						}
					}
					id = carved ? ID_AIR : y == g ? top :
							y >= g - 3 ? (sandy ? m_ids.sand : m_ids.dirt) : m_ids.stone;
				}
				volume.setVoxelAt(x, y, z, VoxelInstance(word_of(id, 0)));
			}
		}
		// The ores
		std::mt19937 rnd(m_p.seed ^ (uint32_t)(section_p.getX() * 73856093) ^
				(uint32_t)(section_p.getY() * 19349663) ^
				(uint32_t)(section_p.getZ() * 83492791));
		const size_t voxels = volume.voxel_count();
		for(const Ore &o : m_ores){
			const size_t clusters = voxels / (size_t)o.scarcity;
			for(size_t c = 0; c < clusters; c++){
				const int x0 = lc.getX() + (int)(rnd() % (uint32_t)(uc.getX() - lc.getX() - 1)),
						y0 = lc.getY() + (int)(rnd() % (uint32_t)(uc.getY() - lc.getY() - 1)),
						z0 = lc.getZ() + (int)(rnd() % (uint32_t)(uc.getZ() - lc.getZ() - 1));
				for(int i = 0; i < 27; i++){
					if((int)(rnd() % 27) >= o.num || y0 + i / 9 > o.y_max)
						continue;
					const int x = x0 + i % 3, y = y0 + i / 9, z = z0 + (i / 3) % 3;
					if(m_format.id.get(volume.getVoxelAt(x, y, z).data) == m_ids.stone)
						volume.setVoxelAt(x, y, z, VoxelInstance(word_of(o.id, 0)));
				}
			}
		}
		// The trees within 2 of the section: leaves first, then the trunks
		for(int pass = 2; pass >= 1; pass--)
		for(int tz = lc.getZ() - 2; tz <= uc.getZ() + 2; tz++)
		for(int tx = lc.getX() - 2; tx <= uc.getX() + 2; tx++){
			if(!has_tree(tx, tz))
				continue;
			const int g = ground(tx, tz);
			if(g + 6 < lc.getY() || g + 1 > uc.getY())
				continue;
			for(int dz = -2; dz <= 2; dz++)
			for(int dy = 0; dy < 6; dy++)
			for(int dx = -2; dx <= 2; dx++){
				const int x = tx + dx, y = g + 1 + dy, z = tz + dz;
				if(mapgen::tree_part(dx, dy, dz) != pass || !r.containsPoint(pv::Vector3DInt32(x, y, z)))
					continue;
				if(pass == 2 && m_format.id.get(volume.getVoxelAt(x, y, z).data) != ID_AIR)
					continue;
				volume.setVoxelAt(x, y, z, VoxelInstance(word_of(
						pass == 1 ? m_ids.tree : m_ids.leaves, 0)));
			}
		}
		// The sky down each column to its first voxel; a column whose
		// ground is over the section is dark in it
		for(int z = lc.getZ(); z <= uc.getZ(); z++)
		for(int x = lc.getX(); x <= uc.getX(); x++){
			if(m_map->in(x, z) && ground(x, z) > uc.getY())
				continue;
			for(int y = uc.getY(); y >= lc.getY(); y--){
				uint32_t w = volume.getVoxelAt(x, y, z).data;
				if(m_format.id.get(w) != ID_AIR)
					break;
				m_format.light_sky.set(w, 15);
				volume.setVoxelAt(x, y, z, VoxelInstance(w));
			}
		}
	}
};

// The section's voxels (SkeldatGenerator), skelenti's bone piles on its
// ground (bones.h's pile()), and its bones seeded by the place's danger: every voxel that is
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
	// [SKELDAT_MINING_HAZARDS] The pockets: stone, the kinds (water, poison
	// gas, lava) and the water level their depths are counted from
	uint32_t m_stone = 0, m_pocket[3] = {}, m_lava_spring = 0;
	int m_water_level = 1;
	std::atomic<int> m_pockets{0};

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

	// [SKELDAT_MINING_HAZARDS] At most one pocket a 32 cube (POCKET_CELL)
	// of the section: a blob of 4 to 20 voxels grown in stone, kept only
	// when every face round it is stone (sealed), made full (a liquid's
	// volume 8, a gas's share 255). Water and poison gas from POCKET_DEPTH
	// under the water level, lava too from POCKET_LAVA_DEPTH; a cell's
	// chance POCKET_CHANCE at POCKET_LAVA_DEPTH, by the depth. Seeded by
	// the cell, so a section made again is the same.
	// simplified: the depth from the water level, not the surface over it
	void pockets(interface::VoxelVolume &volume, const pv::Vector3DInt32 &lc,
			const pv::Vector3DInt32 &uc)
	{
		const int C = hazards::POCKET_CELL;
		for(int cz = lc.getZ(); cz + C - 1 <= uc.getZ(); cz += C)
		for(int cy = lc.getY(); cy + C - 1 <= uc.getY(); cy += C)
		for(int cx = lc.getX(); cx + C - 1 <= uc.getX(); cx += C)
			pocket(volume, pv::Vector3DInt32(cx, cy, cz),
					pv::Vector3DInt32(cx + C - 1, cy + C - 1, cz + C - 1));
	}

	void pocket(interface::VoxelVolume &volume, const pv::Vector3DInt32 &lc,
			const pv::Vector3DInt32 &uc)
	{
		const int cy = (lc.getY() + uc.getY()) / 2,
				depth = m_water_level - cy;
		if(depth < hazards::POCKET_DEPTH || !m_stone)
			return;
		std::mt19937 r(m_salt ^ (uint32_t)(lc.getX() * 73856093) ^
				(uint32_t)(lc.getY() * 19349663) ^ (uint32_t)(lc.getZ() * 83492791));
		std::uniform_real_distribution<float> u(0, 1);
		const float chance = std::min(0.9f,
				hazards::POCKET_CHANCE * depth / hazards::POCKET_LAVA_DEPTH);
		if(u(r) >= chance)
			return;
		const int kinds = depth >= hazards::POCKET_LAVA_DEPTH ? 3 : 2;
		const int kind = (int)(r() % kinds);
		auto id_at = [&](int x, int y, int z){
			return m_format.id.get(volume.getVoxelAt(x, y, z).data);
		};
		auto in = [&](int x, int y, int z){
			return x > lc.getX() && y > lc.getY() && z > lc.getZ() &&
					x < uc.getX() && y < uc.getY() && z < uc.getZ();
		};
		sv_<pv::Vector3DInt32> blob;
		std::set<std::tuple<int, int, int>> has;
		const int x0 = lc.getX() + 2 + (int)(r() % (uc.getX() - lc.getX() - 3)),
				y0 = lc.getY() + 2 + (int)(r() % (uc.getY() - lc.getY() - 3)),
				z0 = lc.getZ() + 2 + (int)(r() % (uc.getZ() - lc.getZ() - 3));
		if(!in(x0, y0, z0) || id_at(x0, y0, z0) != m_stone)
			return;
		blob.push_back(pv::Vector3DInt32(x0, y0, z0));
		has.insert(std::make_tuple(x0, y0, z0));
		static const int D[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
				{0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
		const size_t want = 4 + r() % 17;
		for(int tries = 0; tries < 200 && blob.size() < want; tries++){
			const pv::Vector3DInt32 b = blob[r() % blob.size()];
			const int *d = D[r() % 6];
			const int x = b.getX() + d[0], y = b.getY() + d[1], z = b.getZ() + d[2];
			if(!in(x, y, z) || id_at(x, y, z) != m_stone ||
					has.count(std::make_tuple(x, y, z)))
				continue;
			blob.push_back(pv::Vector3DInt32(x, y, z));
			has.insert(std::make_tuple(x, y, z));
		}
		if(blob.size() < 4)
			return;
		for(const pv::Vector3DInt32 &b : blob)
			for(const auto &d : D){
				const int x = b.getX() + d[0], y = b.getY() + d[1],
						z = b.getZ() + d[2];
				if(!has.count(std::make_tuple(x, y, z)) && id_at(x, y, z) != m_stone)
					return;
			}
		// [SKELDAT_OWN_MAPGEN] A lava pocket's first voxel a lava spring, one
		// pocket in LAVA_SPRING_ONE_IN
		const bool spring = kind == 2 && m_lava_spring &&
				r() % hazards::LAVA_SPRING_ONE_IN == 0;
		for(const pv::Vector3DInt32 &b : blob){
			uint32_t word = volume.getVoxelAt(b).data;
			m_format.id.set(word, spring && &b == &blob[0] ? m_lava_spring :
					m_pocket[kind]);
			// Full: water's 0, lava's 7 (eighths less one), a gas's 255
			m_format.param.set(word, kind == 1 ? 255u : kind == 2 ? 7u : 0u);
			volume.setVoxelAt(b, VoxelInstance(word));
		}
		m_pockets++;
		static const char *KIND[] = {"water", "poison gas", "lava"};
		log_i(MODULE, "skeldat: a %s pocket of %zu at %d,%d,%d%s", KIND[kind],
				blob.size(), x0, y0, z0, spring ? ", a lava spring" : "");
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
		pockets(volume, lc + pad, uc - pad);
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
	// The world's seed and water line ([SKELDAT_OWN_MAPGEN] set at its
	// start: 20 in a world 64 high, 1 in one 128 high) and its form
	// (mapgen.h's, or "legacy_valleys": made by Luanti's valleys before)
	uint32_t seed = 0;
	int water_level = 1;
	ss_ form;
	// The heightmap the generator reads (for the edge's cut and the rivers)
	std::shared_ptr<const mapgen::Heightmap> heightmap;
	bool spawn_ready = false;

	Terrain(WorldView &world, storage::Save *&save, storage::Store *&store,
			Drops &drops):
		world(world), save(save), store(store), drops(drops)
	{}

	// A voxel id's node as Luanti would have it defined, which is what
	// builtin/luanti's registry builder reads
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
		d.sunlight = n.shape == skeldat::NODEBOX || n.shape == skeldat::TORCH ||
				n.shape == skeldat::GAS;
		switch(n.shape){
		case skeldat::CUBE:
			break;
		case skeldat::ALLFACES:
			d.drawtype = "allfaces_optional";
			d.alpha_clip = true;
			break;
		case skeldat::LIQUID:
			// [SKELDAT_LOW_BANKS] The sea's edge drain: a liquid to the
			// game (the end, the routes), nothing to the eye and the sun
			if(n.name == "skeldat:level_drain"){
				d.drawtype = "airlike";
				d.walkable = false;
				d.pointable = 0;
				d.sunlight = true;
				break;
			}
			d.drawtype = n.flowing ? "flowingliquid" : "liquid";
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
		case skeldat::GAS:
			// Translucent; its faces against its own kind dropped, as glass's
			d.drawtype = "glasslike";
			d.alpha_blend = true;
			d.walkable = false;
			d.pointable = 0;
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

	// [SKELDAT_OWN_MAPGEN] The generator: the heightmap made now (once a
	// start, the same for the seed, the size and the form), the ids and
	// the ores' table (Luanti's scatter numbers, as the valleys had them)
	SkeldatGenerator *make_generator()
	{
		const int S = skeldat::bones::SECTION;
		const bool low = world.y0 >= 0;
		water_level = low ? 20 : 1;
		mapgen::Params p;
		p.seed = seed;
		p.half = world.half * S;
		p.bottom = world.y0 * S;
		p.top = (world.y1 + 1) * S - 1;
		p.water_level = water_level;
		p.form = std::max(0, mapgen::form_of(form));
		const int64_t t0 = interface::os::time_us();
		auto map = std::make_shared<const mapgen::Heightmap>(mapgen::make_heightmap(p));
		heightmap = map;
		// The water line: plains' water table (mapgen.h's water_line()), the
		// other forms' the base line (a world made before keeps the
		// valleys'); the pockets' depths and the spawn's dry ground are by it
		if(form == "plains"){
			p.water_level = mapgen::water_line(*map);
			water_level = p.water_level;
		}
		log_i(MODULE, "skeldat: the heightmap (%s) made in %.1f ms, the water "
				"line at %d", cs(form), (interface::os::time_us() - t0) / 1e3,
				water_level);
		SkeldatGenerator::Ids ids;
		ids.stone = world.id_of("skeldat:stone");
		ids.dirt = world.id_of("skeldat:dirt");
		ids.grass = world.id_of("skeldat:grass");
		ids.sand = world.id_of("skeldat:sand");
		ids.tree = world.id_of("skeldat:tree");
		ids.leaves = world.id_of("skeldat:leaves");
		ids.water = world.id_of("skeldat:water_source");
		ids.gravel = world.id_of("skeldat:gravel");
		ids.spring = world.id_of("skeldat:water_spring");
		ids.drain = world.id_of("skeldat:water_drain");
		ids.level_drain = world.id_of("skeldat:level_drain");
		sv_<SkeldatGenerator::Ore> ores = {
			{world.id_of("skeldat:coal_ore"), 8 * 8 * 8, 8, 64},
			// 64 high, each still under the surface (11 and up)
			{world.id_of("skeldat:iron_ore"), 10 * 10 * 10, 5, low ? 14 : 0},
			{world.id_of("skeldat:diamond_ore"), 15 * 15 * 15, 4, low ? 6 : -48},
			{world.id_of("skeldat:gravel"), 16 * 16 * 16, 20, 64},
			{world.id_of("skeldat:dirt"), 16 * 16 * 16, 20, low ? 4 : -32},
		};
		return new SkeldatGenerator(world.format, map, p, ids, ores);
	}

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
			std::mt19937 r(seed);
			for(int i = 0; i < 4000 && !spawn_ready; i++){
				const int range = std::min(32 + i / 4, world.half * SECTION - 16);
				const int x = (int)(r() % (2 * range)) - range;
				const int z = (int)(r() % (2 * range)) - range;
				int feet = 0;
				if(!ground(x, z, feet) || feet < water_level + 1 ||
						seed_value(skeldat::bones::danger(
						seed, (float)x, (float)z,
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
	// [SKELDAT_OWN_MAPGEN] Cut where a river's channel or the lake meets
	// it; on the sea none, its islands within SEA_BONES of the edge its
	// bone start (their top 3 at full bones).
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
					if(form == "sea"){
						// The sea's bone start: its islands within SEA_BONES
						// of the edge, their top 3 at full bones
						if(d >= mapgen::SEA_BONES)
							continue;
						int n = 0;
						for(int y = top; y > y0 && n < 3; y--){
							const uint32_t id = world.format.id.get(vol.sample_at(x, y, z));
							const skeldat::NodeDef *nd = world.node_of(id);
							if(id == ID_AIR || id == ID_IGNORE)
								continue;
							if(nd && nd->shape == skeldat::LIQUID)
								break;
							interface::VoxelSample s = vol.sample_at(x, y, z);
							world.bones.set(s, MAX);
							out.set_sample_at(x, y, z, s);
							changed++, blocks++, n++;
						}
						continue;
					}
					if(d >= EDGE_COLUMNS)
						continue;
					// [SKELDAT_OWN_MAPGEN] Cut where a river's channel meets it,
					// and where the lake does; none on the sea
					const uint8_t hf = heightmap && heightmap->in(x, z) ?
							heightmap->flags[heightmap->index(x, z)] : 0;
					if((hf & mapgen::CHANNEL) || (form == "lake" && (hf & mapgen::WATER)) ||
							form == "sea")
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
