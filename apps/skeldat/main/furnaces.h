// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The furnaces and the lanterns**: a lantern is a
// furnace with the fuel slot alone ([SKELDAT_FIGHT_BACK]). Each by "x,y,z",
// saved as "furnace/<x,y,z>"; a second of each at a time, the node lit or
// not as it burns. The lanterns' spheres are what the bones' growth, the
// skeletons' lure and their theft ask about. Who has a furnace open is
// the players' (changed() tells the Module).
// Included by main.cpp inside namespace skeldat, after world_view.h
#pragma once

struct Furnaces
{
	WorldView &world;
	// The world's save, from its start
	storage::Store *store = nullptr;
	std::map<ss_, Furnace> all;
	// A furnace's slots changed: the players with it open told
	std::function<void(const ss_ &at)> changed;
	// For a check (BUILDAT_SKELDAT_LANTERNS): each lantern's sphere logged
	// every game hour
	bool report = false;
	float t = 0;

	Furnaces(WorldView &world): world(world) {}

	void load()
	{
		ss_ v;
		for(const ss_ &key : store->list("furnace/"))
			if(store->get(key, v))
				all[key.substr(8)].load(v);
	}
	void save()
	{
		for(auto &pair : all)
			store->set("furnace/"+pair.first, pair.second.save());
	}

	// A furnace or a lantern placed at x, y, z
	void placed(int x, int y, int z, bool lantern)
	{
		Furnace f;
		f.lantern = lantern;
		all[pos_key(x, y, z)] = f;
	}
	// Dug: false while it holds anything
	bool dug(const ss_ &at)
	{
		auto f = all.find(at);
		if(f != all.end() && !(f->second.src.empty() &&
				f->second.fuel.empty() && f->second.dst.empty()))
			return false;
		all.erase(at);
		if(store)
			store->remove("furnace/"+at);
		return true;
	}

	// Every furnace and lantern a second
	void step(float dtime, float day_s)
	{
		t += dtime;
		if(t < 1)
			return;
		t = 0;
		for(auto &pair : all)
			if(pair.second.lantern)
				step_lantern(pair.first, pair.second, day_s);
			else
				step_furnace(pair.first, pair.second);
	}

	// A second of a furnace: fuel taken when there is something to cook,
	// the cooking done when its time is up
	void step_furnace(const ss_ &at, Furnace &f)
	{
		const skeldat::Game &game = world.game;
		const skeldat::Cooking *c = f.src.empty() ? nullptr :
				game.cooks(f.src.name);
		const bool cookable = c && (f.dst.empty() || (f.dst.name == c->output
				&& f.dst.count < game.stack_max(c->output)));
		const bool before = f.fuel_left > 0;
		bool changes = false;
		if(cookable && f.fuel_left <= 0){
			auto fuel = game.fuel.find(f.fuel.name);
			if(!f.fuel.empty() && fuel != game.fuel.end()){
				f.fuel_left = fuel->second;
				f.fuel.take(1);
				changes = true;
			}
		}
		float ft = 0;
		if(f.fuel_left > 0){
			f.fuel_left -= 1;
			if(cookable){
				ft = f.src_time + 1;
				if(ft >= c->time){
					if(f.dst.empty())
						f.dst = Stack(c->output);
					else
						f.dst.count++;
					f.src.take(1);
					log_i(MODULE, "skeldat: the furnace at %s made %s",
							cs(at), cs(c->output));
					ft = 0;
					changes = true;
				}
			}
		}
		f.src_time = ft;
		if(changes)
			changed(at);
		if(before != (f.fuel_left > 0)){
			int x, y, z;
			if(!parse_pos(at, x, y, z))
				return;
			// The front lit or not, the way it faces kept
			const VoxelInstance v = world.voxel_at(x, y, z);
			const uint32_t id = world.format.id.get(v.data);
			const uint32_t want = world.id_of(f.fuel_left > 0 ?
					"skeldat:furnace_active" : "skeldat:furnace");
			if(id != want && (id == world.id_of("skeldat:furnace") ||
					id == world.id_of("skeldat:furnace_active")))
				world.set_node(x, y, z, want, world.format.param.get(v.data));
		}
	}

	// A lantern a second: its coal burning down, the next taken from its
	// slot, the node lit while one burns
	void step_lantern(const ss_ &at, Furnace &f, float day_s)
	{
		const bool before = f.fuel_left > 0;
		if(f.fuel_left > 0)
			f.fuel_left -= 1;
		if(f.fuel_left <= 0 && f.fuel.name == "skeldat:coal" &&
				!f.fuel.empty()){
			f.fuel_left = day_s / 24 * LANTERN_HOURS;
			f.fuel.take(1);
			changed(at);
		}
		const bool lit = f.fuel_left > 0;
		int x, y, z;
		if(before == lit || !parse_pos(at, x, y, z))
			return;
		const uint32_t id = world.id_at(x, y, z);
		if(id == world.id_of("skeldat:lantern") ||
				id == world.id_of("skeldat:lantern_active"))
			world.set_node(x, y, z, world.id_of(lit ?
					"skeldat:lantern_active" : "skeldat:lantern"));
		log_i(MODULE, "skeldat: the lantern at %s %s", cs(at),
				lit ? "is lit" : "goes out");
	}

	static bool parse_pos(const ss_ &at, int &x, int &y, int &z)
	{
		char c;
		std::istringstream is(at);
		return (bool)(is>>x>>c>>y>>c>>z);
	}

	// The burning lanterns whose spheres reach into `r`
	sv_<pv::Vector3DInt32> lanterns_in(const pv::Region &r)
	{
		sv_<pv::Vector3DInt32> out;
		const pv::Vector3DInt32 &lc = r.getLowerCorner(),
				&uc = r.getUpperCorner();
		for(auto &pair : all){
			int x, y, z;
			if(!pair.second.lantern || pair.second.fuel_left <= 0 ||
					!parse_pos(pair.first, x, y, z))
				continue;
			if(x + LANTERN_RADIUS >= lc.getX() && x - LANTERN_RADIUS <=
					uc.getX() && y + LANTERN_RADIUS >= lc.getY() &&
					y - LANTERN_RADIUS <= uc.getY() &&
					z + LANTERN_RADIUS >= lc.getZ() &&
					z - LANTERN_RADIUS <= uc.getZ())
				out.push_back(pv::Vector3DInt32(x, y, z));
		}
		return out;
	}

	// The burning lanterns by footprint
	std::map<long, sv_<pv::Vector3DInt32>> lanterns_by_footprint()
	{
		std::map<long, sv_<pv::Vector3DInt32>> out;
		for(auto &pair : all){
			int x, y, z;
			if(pair.second.lantern && pair.second.fuel_left > 0 &&
					parse_pos(pair.first, x, y, z) && world.footprint(x, z) >= 0)
				out[world.footprint(x, z)].push_back(pv::Vector3DInt32(x, y, z));
		}
		return out;
	}

	// A burning lantern within a column of (x, z) and two voxels of y
	bool lantern_at_hand(float x, float y, float z, pv::Vector3DInt32 &at)
	{
		for(auto &pair : all){
			int lx, ly, lz;
			if(pair.second.lantern && pair.second.fuel_left > 0 &&
					parse_pos(pair.first, lx, ly, lz) &&
					std::fabs(lx - x) <= 1.5f && std::fabs(lz - z) <= 1.5f &&
					std::fabs(ly - y) <= 2.5f){
				at = pv::Vector3DInt32(lx, ly, lz);
				return true;
			}
		}
		return false;
	}

	// The lantern at `at` taken out of the world, put out: the coal in it,
	// or -1 when there is none there
	int take_lantern(const pv::Vector3DInt32 &at)
	{
		const ss_ k = pos_key(at.getX(), at.getY(), at.getZ());
		auto it = all.find(k);
		if(it == all.end())
			return -1;
		const int coal = it->second.fuel.name == "skeldat:coal" ?
				it->second.fuel.count : 0;
		all.erase(it);
		if(store)
			store->remove("furnace/"+k);
		world.set_node(at.getX(), at.getY(), at.getZ(), ID_AIR);
		return coal;
	}

	// A lantern left unlit with `coal` where something died at mx, my, mz:
	// on the first air of the three voxels from its feet up
	void leave_lantern(float mx, float my, float mz, int coal)
	{
		const int x = (int)std::floor(mx + 0.5f),
				z = (int)std::floor(mz + 0.5f);
		int y = (int)std::floor(my + 0.5f);
		while(y < (int)std::floor(my + 0.5f) + 3 && world.id_at(x, y, z) != ID_AIR)
			y++;
		if(!world.reaches_world(x, y, z) || world.id_at(x, y, z) != ID_AIR){
			log_i(MODULE, "skeldat: the lantern lost at %d,%d,%d", x, y, z);
			return;
		}
		world.set_node(x, y, z, world.id_of("skeldat:lantern"));
		Furnace f;
		f.lantern = true;
		if(coal > 0)
			f.fuel = Stack("skeldat:coal", coal);
		all[pos_key(x, y, z)] = f;
		log_i(MODULE, "skeldat: the lantern left at %s, %d coal in it",
				cs(pos_key(x, y, z)), coal);
	}

	// For a check: each lantern's sphere, its voxels with bones, their
	// mean and its bone blocks, a line each
	void report_lanterns()
	{
		const uint32_t block = world.id_of("skeldat:bone_block");
		const int R = LANTERN_RADIUS;
		for(auto &pair : all){
			int lx, ly, lz;
			if(!pair.second.lantern || !parse_pos(pair.first, lx, ly, lz))
				continue;
			int n = 0, with = 0, blocks = 0;
			double sum = 0;
			voxelworld::access(world.server, world.scene,
					[&](voxelworld::Instance *w){
				for(int z = -R; z <= R; z++)
				for(int y = -R; y <= R; y++)
				for(int x = -R; x <= R; x++){
					if(x * x + y * y + z * z > R * R)
						continue;
					const interface::VoxelSample v = w->get_sample(
							pv::Vector3DInt32(lx + x, ly + y, lz + z), true);
					const uint32_t id = world.format.id.get(v);
					if(!world.holds_bones(id))
						continue;
					const uint32_t b = world.bones.get(v);
					n++, with += b > 0, sum += b, blocks += id == block;
				}
			});
			log_i(MODULE, "skeldat: the lantern at %s %s: %d voxels in %d, "
					"%d with bones, mean %.2f, %d bone blocks", cs(pair.first),
					pair.second.fuel_left > 0 ? "burning" : "out", n, R, with,
					n ? sum / n : 0.0, blocks);
		}
	}

	// For a check, BUILDAT_SKELDAT_LANTERNS="x z coal [block]; ...": a
	// lantern on each column's top with that many coal, and with block 1
	// a bone block two to its +x
	void test_lanterns(const char *spec, float day_s)
	{
		std::istringstream is(spec);
		ss_ item;
		const uint32_t block = world.id_of("skeldat:bone_block");
		while(std::getline(is, item, ';')){
			int x, z, coal, with_block = 0;
			if(sscanf(item.c_str(), "%d %d %d %d", &x, &z, &coal,
					&with_block) < 3)
				continue;
			const long c = world.column(x, z), c2 = world.column(x + 2, z);
			if(c < 0 || c2 < 0 || world.top_y[c] == NO_GROUND ||
					world.top_y[c2] == NO_GROUND){
				log_w(MODULE, "skeldat: test: no ground for a lantern at %d %d",
						x, z);
				continue;
			}
			const int y = world.top_y[c] + 1;
			// Lit already, a coal of them burning
			world.set_node(x, y, z, world.id_of(coal > 0 ?
					"skeldat:lantern_active" : "skeldat:lantern"));
			Furnace f;
			f.lantern = true;
			if(coal > 0)
				f.fuel_left = day_s / 24 * LANTERN_HOURS;
			if(coal > 1)
				f.fuel = Stack("skeldat:coal", coal - 1);
			all[pos_key(x, y, z)] = f;
			if(with_block)
				world.set_node(x + 2, world.top_y[c2] + 1, z, block, 0,
						skeldat::bones::MAX);
			log_i(MODULE, "skeldat: test: a lantern at %s with %d coal",
					cs(pos_key(x, y, z)), coal);
		}
	}
};
// vim: set noet ts=4 sw=4:
