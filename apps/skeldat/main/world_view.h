// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The world as every part of skeldat sees it**: the
// voxel format and the bones plane, the world's bounds in sections, the
// column caches (each column's top voxel and its bones), the time of day,
// the node ids the rules single out, and the voxel helpers. The Module
// owns one and hands it to each part. A part that keeps something by the
// voxel hears of every set_node() through on_set.
// Included by main.cpp inside namespace skeldat, after its constants
#pragma once

struct WorldView
{
	interface::Server *server;
	const skeldat::Game &game;
	main_context::SceneReference scene = nullptr;
	interface::VoxelFormat format;
	interface::VoxelField bones{1, 0, 4};
	// The bounds in sections: x and z from -half to half - 1, y from y0
	// to y1 ([SKELDAT_WORLD_SIZES] sets them at the world's start)
	int half = skeldat::bones::HALF / skeldat::bones::SECTION,
			y0 = skeldat::bones::Y0 / skeldat::bones::SECTION,
			y1 = skeldat::bones::Y1 / skeldat::bones::SECTION;
	// Each column's top voxel, its y (NO_GROUND for none, or water) and
	// its bones, from the sweep and every set_node: what a light skeleton
	// walks on. simplified: the top only, so a light skeleton in a cave
	// stays put until a player wakes it; a voxel read for each of its steps
	// was ~66 us, the world being too big for voxelworld's chunk buffers
	sv_<int8_t> top_y;
	// The top voxel's y whatever it is (water too): a change under it
	// leaves the column's top as it is ([SKELDAT_OWN_MAPGEN]: the liquid
	// step's writes)
	sv_<int8_t> top_any;
	sv_<uint8_t> top_b;
	bool footprints_ready = false;
	// The time of day, 0 to 1 (0.5 noon)
	double day = 0.25;
	// The ids the rules single out, known at the world's start
	uint32_t marker = ID_IGNORE, stuck_id = ID_IGNORE,
			lantern_ids[2] = {ID_IGNORE, ID_IGNORE};
	std::array<uint32_t, 4> sun_ids{};
	// set_node's listeners: (x, y, z, the old id, the new), inside the
	// voxel world's access
	sv_<std::function<void(int, int, int, uint32_t, uint32_t)>> on_set;
	// The random numbers every part draws from
	std::mt19937 rand{std::random_device{}()};
	// The server's clock, seconds; the world's own, seconds of game time
	// since it was made (kept in its save); a game day's length, seconds
	double time = 0, t = 0;
	float day_s = DAY_SECONDS;
	// The pathfinder's cell for a voxel id (fill_cells)
	sv_<uint8_t> cell_of;
	// Every section of the world in ([SKELDAT_BOUNDED_WORLD]): the players
	// wait for it
	bool ready = false;
	// Where a player (re)spawns
	float spawn[3] = {0, 0, 0};
	// A player moved or left: the sections loaded around them to pick again
	bool load_points_dirty = true;

	WorldView(interface::Server *server, const skeldat::Game &game):
		server(server), game(game)
	{}

	float rnd()
	{
		return std::uniform_real_distribution<float>(0, 1)(rand);
	}

	uint32_t id_of(const ss_ &name) const
	{
		for(size_t i = 0; i < game.nodes.size(); i++)
			if(game.nodes[i].name == name)
				return (uint32_t)i + ID_NODE0;
		return name == "air" ? ID_AIR : ID_IGNORE;
	}

	// [SKELDAT_MINING_HAZARDS] A second's harm by the voxels at the feet
	// and the head: lava at either 4; a gas at the head by its share,
	// poison ceil(4 * share / 255), volcanic one more (it burns). How it
	// hurt in how.
	int harm(uint32_t feet, uint32_t head, uint32_t head_param,
			const char **how) const
	{
		const uint32_t lava = id_of("skeldat:lava");
		if(feet == lava || head == lava){
			*how = "burns in lava";
			return hazards::LAVA_HARM;
		}
		const bool poison = head == id_of("skeldat:gas_poison");
		if(!poison && head != id_of("skeldat:gas_volcanic"))
			return 0;
		*how = poison ? "breathes poison gas" : "breathes volcanic gas";
		return (int)((hazards::GAS_HARM * head_param + 254) / 255) +
				(poison ? 0 : 1);
	}

	const skeldat::NodeDef* node_of(uint32_t id) const
	{
		return id >= ID_NODE0 && id - ID_NODE0 < game.nodes.size() ?
				&game.nodes[id - ID_NODE0] : nullptr;
	}

	size_t all_sections() const
	{
		return (size_t)(2 * half) * (2 * half) * (y1 - y0 + 1);
	}

	size_t footprints() const
	{
		return (size_t)(2 * half) * (2 * half);
	}

	static ss_ section_key(const pv::Vector3DInt16 &sp)
	{
		return pos_key(sp.getX(), sp.getY(), sp.getZ());
	}

	// Merged padding loads the sections around the world too
	bool in_world(const pv::Vector3DInt16 &sp) const
	{
		return sp.getX() >= -half && sp.getX() < half &&
				sp.getZ() >= -half && sp.getZ() < half &&
				sp.getY() >= y0 && sp.getY() <= y1;
	}

	// Inside the world above its bottom layer
	bool reaches_world(int x, int y, int z) const
	{
		using namespace skeldat::bones;
		const int h = half * SECTION;
		return x >= -h && x < h && z >= -h && z < h && y > y0 * SECTION &&
				y < (y1 + 1) * SECTION;
	}

	VoxelInstance voxel_at(int x, int y, int z)
	{
		return voxelworld::get_voxel(server, scene,
				pv::Vector3DInt32(x, y, z), true);
	}

	uint32_t id_at(int x, int y, int z)
	{
		return format.id.get(voxel_at(x, y, z).data);
	}

	uint32_t param_at(int x, int y, int z)
	{
		return format.param.get(voxel_at(x, y, z).data);
	}

	int bones_at(int x, int y, int z)
	{
		return (int)bones.get(voxelworld::get_sample(server, scene,
				pv::Vector3DInt32(x, y, z), true));
	}

	// The bones stay with what is there, and go with it when it is dug; the
	// parts hear of the change (on_set) before it is written
	void set_node(int x, int y, int z, uint32_t id, uint32_t param = 0,
			int bones_ = -1)
	{
		voxelworld::access(server, scene, [&](voxelworld::Instance *w){
			set_node_in(w, x, y, z, id, param, bones_);
		});
	}

	// set_node() inside an open access (the hazards' step, many at once)
	void set_node_in(voxelworld::Instance *w, int x, int y, int z, uint32_t id,
			uint32_t param = 0, int bones_ = -1)
	{
		const pv::Vector3DInt32 p(x, y, z);
		interface::VoxelSample v = w->get_sample(p, true);
		uint32_t &word = v.planes[0];
		const uint32_t old = format.id.get(word);
		word = 0;
		format.id.set(word, id);
		format.param.set(word, param);
		if(id == ID_AIR || id == marker || id == stuck_id)
			bones.set(v, 0);
		// A stuck arrow's voxel coming or going keeps no bones given
		if(!(old != id && (old == stuck_id || id == stuck_id)) && bones_ >= 0)
			bones.set(v, (uint32_t)bones_);
		for(auto &f : on_set)
			f(x, y, z, old, id);
		w->set_sample(p, v);
		// The top is by the ids, and a change under it leaves it
		const long c = column(x, z);
		if(old != id && (c < 0 || top_any.empty() || top_any[c] == NO_GROUND ||
				y >= top_any[c]))
			rescan_column(w, x, z);
	}

	static int floor_div(int a, int b){ return a >= 0 ? a / b : -((-a + b - 1) / b); }

	// The world as a mob sees it, inside one voxelworld access. An unloaded
	// voxel is a wall: nothing walks into the unknown.
	uint32_t wid(voxelworld::Instance *w, int x, int y, int z)
	{
		return format.id.get(w->get_voxel(pv::Vector3DInt32(x, y, z),
				true).data);
	}

	bool walkable(voxelworld::Instance *w, int x, int y, int z)
	{
		const uint32_t id = wid(w, x, y, z);
		if(id == ID_AIR)
			return false;
		const skeldat::NodeDef *n = node_of(id);
		return !n || (n->shape != skeldat::LIQUID &&
				n->shape != skeldat::TORCH && n->walkable);
	}

	bool is_water(voxelworld::Instance *w, int x, int y, int z)
	{
		const skeldat::NodeDef *n = node_of(wid(w, x, y, z));
		return n && n->shape == skeldat::LIQUID;
	}

	// The sky's light and the lamps', 0 to 15
	void light(voxelworld::Instance *w, int x, int y, int z, int &sky,
			int &lamp)
	{
		const uint32_t d = w->get_voxel(pv::Vector3DInt32(x, y, z), true).data;
		sky = (int)format.light_sky.get(d);
		lamp = (int)format.light_lamp.get(d);
	}

	// The sky's light now: none at night
	// simplified: day or night, not a ramp through dusk
	int sun(voxelworld::Instance *w, int x, int y, int z)
	{
		if(day < 0.23 || day > 0.77)
			return 0;
		int sky, lamp;
		light(w, x, y, z, sky, lamp);
		return sky;
	}

	// **The danger of a place is the bones around it** ([SKELDAT]: one
	// rule, two places), read as client_lua/init.lua's danger_here() reads
	// it for the fog and the music: the mean bones of the voxels that are
	// not empty in a box 9 across about the feet, every other voxel, 0 to 1
	float danger(voxelworld::Instance *w, float x, float y, float z)
	{
		const int fx = (int)std::floor(x + 0.5f), fy = (int)std::floor(y + 0.5f),
				fz = (int)std::floor(z + 0.5f);
		int sum = 0, n = 0;
		for(int dz = -4; dz <= 4; dz += 2)
		for(int dy = -4; dy <= 4; dy += 2)
		for(int dx = -4; dx <= 4; dx += 2){
			const interface::VoxelSample v = w->get_sample(
					pv::Vector3DInt32(fx + dx, fy + dy, fz + dz), true);
			const uint32_t id = format.id.get(v.planes[0]);
			if(id == ID_IGNORE || id == ID_AIR)
				continue;
			n++;
			sum += (int)bones.get(v);
		}
		return n ? (float)sum / (n * skeldat::bones::MAX) : 0.0f;
	}

	// [SKELDAT_SUN_IN_BONES] The sun does not burn a skeleton (user,
	// 2026-10-16) while the 3x4x3 box round its feet's voxel has a voxel of
	// bones over half -- bones::skeleton_near(), the rule a player looks
	// like one by -- or a bone block or a skull, counted as full bones.
	// -1 when the feet's voxel is not loaded.
	int sun_safe(voxelworld::Instance *w, float x, float y, float z)
	{
		const int fx = (int)std::floor(x + 0.5f), fy = (int)std::floor(y + 0.5f),
				fz = (int)std::floor(z + 0.5f);
		if(format.id.get(w->get_sample(pv::Vector3DInt32(fx, fy, fz),
				true).planes[0]) == ID_IGNORE)
			return -1;
		return skeldat::bones::skeleton_near([&](int vx, int vy, int vz){
			const interface::VoxelSample v = w->get_sample(
					pv::Vector3DInt32(vx, vy, vz), true);
			const uint32_t id = format.id.get(v.planes[0]);
			return std::find(sun_ids.begin(), sun_ids.end(), id) !=
					sun_ids.end() ? skeldat::bones::MAX : (int)bones.get(v);
		}, fx, fy, fz);
	}

	// Where something h voxels tall can stand in the column at x, z, from a
	// step up to three down from feet y. A voxel at integer y spans y-0.5
	// to y+0.5, so feet on the one at y are at y+0.5.
	Ground ground(voxelworld::Instance *w, float x, float y, float z, int h)
	{
		Ground g;
		const int cx = (int)std::floor(x + 0.5f), cy = (int)std::floor(y + 0.5f),
				cz = (int)std::floor(z + 0.5f);
		for(int c = cy - 4; c <= cy + h + 1; c++){
			if(wid(w, cx, c, cz) == ID_IGNORE){
				g.loaded = false;
				return g;
			}
		}
		for(int c = cy + 1; c >= cy - 3; c--){
			if(!walkable(w, cx, c - 1, cz))
				continue;
			bool free = true;
			for(int i = 0; i < h && free; i++)
				free = !walkable(w, cx, c + i, cz);
			if(free){
				g.found = true;
				g.y = c - 0.5f;
				g.sun = sun(w, cx, c, cz);
				g.water = is_water(w, cx, c, cz);
				return g;
			}
		}
		return g;
	}

	// A voxel that can have bones: not air, a marker skull or a lantern
	bool holds_bones(uint32_t id)
	{
		if(lantern_ids[0] == ID_IGNORE){
			lantern_ids[0] = id_of("skeldat:lantern");
			lantern_ids[1] = id_of("skeldat:lantern_active");
		}
		return id != ID_AIR && id != ID_IGNORE && id != marker &&
				id != lantern_ids[0] && id != lantern_ids[1] &&
				id != stuck_id;
	}

	// The footprint (x, z) is in, its index in a per-footprint list; -1
	// outside the world or before the world's start
	long footprint(int x, int z) const
	{
		const int S = skeldat::bones::SECTION;
		const int sx = floor_div(x, S) + half, sz = floor_div(z, S) + half;
		if(sx < 0 || sx >= 2 * half || sz < 0 || sz >= 2 * half ||
				!footprints_ready)
			return -1;
		return (long)sz * (2 * half) + sx;
	}

	// Column (x, z)'s place in top_y and top_b; -1 outside the world
	long column(int x, int z) const
	{
		const int h = half * skeldat::bones::SECTION;
		if(x < -h || x >= h || z < -h || z >= h || top_y.empty())
			return -1;
		return (long)(z + h) * (2 * h) + (x + h);
	}

	void set_top(int x, int z, int y, uint32_t id, uint32_t bones)
	{
		const long c = column(x, z);
		if(c < 0)
			return;
		const skeldat::NodeDef *n = node_of(id);
		const bool ground = !n || (n->shape != skeldat::LIQUID &&
				n->shape != skeldat::TORCH && n->shape != skeldat::GAS);
		top_y[c] = ground ? (int8_t)y : NO_GROUND;
		top_any[c] = (int8_t)y;
		top_b[c] = (uint8_t)bones;
	}

	// Column (x, z) read again, after a voxel of it changed
	void rescan_column(voxelworld::Instance *w, int x, int z)
	{
		const int S = skeldat::bones::SECTION;
		if(column(x, z) < 0)
			return;
		for(int y = y1 * S + S - 1; y >= y0 * S; y--){
			const interface::VoxelSample v = w->get_sample(
					pv::Vector3DInt32(x, y, z), true);
			const uint32_t id = format.id.get(v);
			if(id != ID_AIR && id != ID_IGNORE && id != stuck_id){
				set_top(x, z, y, id, bones.get(v));
				return;
			}
		}
		set_top(x, z, NO_GROUND, ID_IGNORE, 0);
	}

	// **The world from above** ([SKELDAT_BOUNDED_WORLD]), for the tuning: a
	// pixel a column, its top voxel's colour (grass, water, the rest grey)
	// whitened by its bones, +x right and +z up; map.png in the world's
	// save. What it says: where it went, or why not.
	// Each column of a section's footprint (sx, sz) with a voxel in it:
	// fn(x, z, its top voxel's y, id, the voxel)
	template<typename F>
	void each_top(voxelworld::Instance *w, int sx, int sz, F fn)
	{
		const int S = skeldat::bones::SECTION;
		const pv::Region r(pv::Vector3DInt32(sx * S, y0 * S, sz * S),
				pv::Vector3DInt32(sx * S + S - 1, y1 * S + S - 1,
				sz * S + S - 1));
		const interface::VoxelVolume vol = w->get_volume(r);
		for(int z = sz * S; z < sz * S + S; z++)
		for(int x = sx * S; x < sx * S + S; x++)
		for(int y = y1 * S + S - 1; y >= y0 * S; y--){
			const interface::VoxelSample v = vol.sample_at(x, y, z);
			const uint32_t id = format.id.get(v);
			if(id == ID_AIR || id == ID_IGNORE)
				continue;
			fn(x, z, y, id, v);
			break;
		}
	}
	// A pathfinder's box from one read of the voxels: walkable() is SOLID,
	// is_water() CLIMB, by the id
	void fill_cells(voxelworld::Instance *w, vp::Field &f)
	{
		const pv::Region region(
				pv::Vector3DInt32(f.origin.x, f.origin.y, f.origin.z),
				pv::Vector3DInt32(f.origin.x + f.w - 1, f.origin.y + f.h - 1,
						f.origin.z + f.d - 1));
		interface::VoxelVolume vol = w->get_volume(region);
		for(int y = f.origin.y; y < f.origin.y + f.h; y++)
		for(int z = f.origin.z; z < f.origin.z + f.d; z++)
		for(int x = f.origin.x; x < f.origin.x + f.w; x++){
			// Over the world's top is open air; past its sides, nothing
			// to walk in
			if(y >= (y1 + 1) * skeldat::bones::SECTION){
				f.cells[f.index(x, y, z)] = vp::OPEN;
				continue;
			}
			const uint32_t id = format.id.get(vol.sample_at(x, y, z));
			if(id >= cell_of.size()){
				const size_t from = cell_of.size();
				cell_of.resize(id + 1);
				for(size_t i = from; i <= id; i++){
					const skeldat::NodeDef *n = node_of(i);
					cell_of[i] = i == ID_AIR ? vp::OPEN :
							!n ? vp::SOLID : n->shape == skeldat::LIQUID ?
							vp::CLIMB : n->shape == skeldat::TORCH ||
							!n->walkable ? vp::OPEN :
							vp::SOLID;
				}
			}
			f.cells[f.index(x, y, z)] = cell_of[id];
		}
	}
};
// vim: set noet ts=4 sw=4:
