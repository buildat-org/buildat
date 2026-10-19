// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_APPLE_TREES] **Leaf decay and the saplings' growth.**
// - Decay: a log or a leaf voxel (leaves, apple leaves, an apple, an apple
//   branch) changed is a centre; a centre's 9x9x9 box queues its leaf
//   voxels, and a queued one with no log within DECAY_RANGE goes, its
//   drops at it. One centre and one test a second (DECAY_PER_SECOND): the
//   slowness is the cost's cap. Placed leaves (param2 1) never decay.
// - Growth: the saplings, grown saplings and apple branches are kept as a
//   set of places; at each midnight a branch is an apple again, a sapling
//   off soil is gone, one on soil under the open sky (sky light 15)
//   grows a stage: a grown one into a tree of its kind, the generator's
//   shape, the trunk's 4 voxels free or it waits a night.
// Saved as "decay/<x,y,z>" ("c" a centre, "q" queued) and
// "sapling/<x,y,z>".
// Included by main.cpp inside namespace skeldat, after drops.h
#pragma once

struct Trees
{
	WorldView &world;
	Drops &drops;
	storage::Store *store = nullptr;
	uint32_t seed = 0;
	std::set<ss_> centres, queue, saplings;
	uint32_t tree = 0, leaves = 0, apple_leaves = 0, fruit = 0, branch = 0,
			dirt = 0, grass = 0, sapling[2] = {}, grown[2] = {};
	float t = 0;
	// Since the last report: voxels queued and gone, the step's time
	size_t queued = 0, gone = 0;
	int64_t us = 0;

	Trees(WorldView &world, Drops &drops): world(world), drops(drops) {}

	void init()
	{
		tree = world.id_of("skeldat:tree");
		leaves = world.id_of("skeldat:leaves");
		apple_leaves = world.id_of("skeldat:apple_leaves");
		fruit = world.id_of("skeldat:apple_fruit");
		branch = world.id_of("skeldat:apple_branch");
		dirt = world.id_of("skeldat:dirt");
		grass = world.id_of("skeldat:grass");
		sapling[0] = world.id_of("skeldat:sapling");
		sapling[1] = world.id_of("skeldat:apple_sapling");
		grown[0] = world.id_of("skeldat:sapling_grown");
		grown[1] = world.id_of("skeldat:apple_sapling_grown");
		ss_ v;
		for(const ss_ &key : store->list("decay/"))
			if(store->get(key, v))
				(v == "c" ? centres : queue).insert(key.substr(6));
		for(const ss_ &key : store->list("sapling/"))
			saplings.insert(key.substr(8));
	}

	bool leafy(uint32_t id) const
	{
		return id == leaves || id == apple_leaves || id == fruit || id == branch;
	}
	bool kept(uint32_t id) const
	{
		return id == branch || id == sapling[0] || id == sapling[1] ||
				id == grown[0] || id == grown[1];
	}
	static bool parse(const ss_ &k, int &x, int &y, int &z)
	{
		return sscanf(k.c_str(), "%d,%d,%d", &x, &y, &z) == 3;
	}

	// world.on_set's
	void on_set(int x, int y, int z, uint32_t old, uint32_t id)
	{
		if(old == id || !store)
			return;
		const ss_ k = pos_key(x, y, z);
		if((old == tree || leafy(old)) && centres.insert(k).second)
			store->set("decay/"+k, "c");
		if(kept(id)){
			if(saplings.insert(k).second)
				store->set("sapling/"+k, "1");
		} else if(kept(old) && saplings.erase(k))
			store->remove("sapling/"+k);
	}

	// Any of the set, at random
	static ss_ take(std::set<ss_> &s, WorldView &world)
	{
		auto it = s.begin();
		std::advance(it, world.rand() % s.size());
		const ss_ k = *it;
		s.erase(it);
		return k;
	}

	void step(float dt)
	{
		t += dt;
		if(t < 1 / DECAY_PER_SECOND)
			return;
		t = 0;
		if(centres.empty() && queue.empty())
			return;
		const int64_t t0 = interface::os::time_us();
		const int R = DECAY_RANGE;
		int x, y, z;
		ss_ goes;
		uint32_t goes_id = 0;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			auto vox = [&](int x, int y, int z){
				return w->get_voxel(pv::Vector3DInt32(x, y, z), true).data;
			};
			if(!centres.empty()){
				const ss_ c = take(centres, world);
				store->remove("decay/"+c);
				if(parse(c, x, y, z))
					for(int dz = -R; dz <= R; dz++)
					for(int dy = -R; dy <= R; dy++)
					for(int dx = -R; dx <= R; dx++){
						const uint32_t d = vox(x + dx, y + dy, z + dz);
						if(!leafy(world.format.id.get(d)) || world.format.param.get(d) & 1)
							continue;
						const ss_ k = pos_key(x + dx, y + dy, z + dz);
						if(queue.insert(k).second){
							store->set("decay/"+k, "q");
							queued++;
						}
					}
			}
			if(queue.empty())
				return;
			const ss_ k = take(queue, world);
			store->remove("decay/"+k);
			if(!parse(k, x, y, z))
				return;
			const uint32_t d = vox(x, y, z);
			const uint32_t id = world.format.id.get(d);
			if(!leafy(id) || world.format.param.get(d) & 1)
				return;
			for(int dz = -R; dz <= R; dz++)
			for(int dy = -R; dy <= R; dy++)
			for(int dx = -R; dx <= R; dx++)
			{
				// An unloaded voxel counts as a log: no decay on a guess
				const uint32_t n = world.format.id.get(vox(x + dx, y + dy, z + dz));
				if(n == tree || n == ID_IGNORE)
					return;
			}
			goes = k, goes_id = id;
		});
		if(!goes.empty()){
			world.set_node(x, y, z, ID_AIR);
			gone++;
			Stack st;
			if(goes_id == fruit)
				st = Stack("skeldat:apple");
			else if(goes_id != branch && world.rand() % 20 == 0)
				st = Stack(goes_id == apple_leaves ? "skeldat:apple_sapling" :
						"skeldat:sapling");
			drops.drop(st, (float)x, (float)y, (float)z);
		}
		us += interface::os::time_us() - t0;
	}

	// "leaf decay: N queued, M gone" every 10 s while there is any
	void report(float span)
	{
		if(queued == 0 && gone == 0)
			return;
		log_i(MODULE, "skeldat: leaf decay: %zu queued, %zu gone, %zu waiting; "
				"%.3f ms a second", queued, gone, queue.size() + centres.size(),
				us / 1e3 / span);
		queued = gone = 0, us = 0;
	}

	// Whether a voxel takes a tree's part: air, leaves, a plant
	bool free(uint32_t id) const
	{
		const skeldat::NodeDef *n = world.node_of(id);
		return id == ID_AIR || leafy(id) || kept(id) ||
				(n && n->shape == skeldat::NODEBOX && !n->walkable);
	}

	// A tree of its kind from a grown sapling's voxel; false if its trunk
	// is not free
	bool grow_tree(int x, int y, int z, bool apple)
	{
		for(int dy = 1; dy < 4; dy++)
			if(!free(world.id_at(x, y + dy, z)))
				return false;
		size_t apples = 0;
		for(int pass = 1; pass <= 2; pass++)
			for(int dy = 0; dy < 6; dy++)
			for(int dz = -2; dz <= 2; dz++)
			for(int dx = -2; dx <= 2; dx++){
				if(mapgen::tree_part(dx, dy, dz) != pass)
					continue;
				const int vx = x + dx, vy = y + dy, vz = z + dz;
				if(pass == 2 && !free(world.id_at(vx, vy, vz)))
					continue;
				const bool f = pass == 2 && apple &&
						mapgen::tree_fruit(x, z, seed, dx, dy, dz);
				apples += f;
				world.set_node(vx, vy, vz, pass == 1 ? tree : !apple ? leaves :
						f ? fruit : apple_leaves);
			}
		log_i(MODULE, "skeldat: %s tree grew at %s, %zu apples", apple ?
				"an apple" : "a", cs(pos_key(x, y, z)), apples);
		return true;
	}

	void midnight()
	{
		size_t grew = 0, trees = 0, apples = 0, lost = 0, waiting = 0;
		const std::set<ss_> all = saplings;
		for(const ss_ &k : all){
			int x, y, z;
			if(!parse(k, x, y, z))
				continue;
			const uint32_t id = world.id_at(x, y, z);
			if(id == branch){
				world.set_node(x, y, z, fruit);
				apples++;
				continue;
			}
			const int kind = id == sapling[1] || id == grown[1];
			const uint32_t under = world.id_at(x, y - 1, z);
			if(under != dirt && under != grass){
				world.set_node(x, y, z, ID_AIR);
				lost++;
				continue;
			}
			int sky = 0, lamp = 0;
			voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
				world.light(w, x, y, z, sky, lamp);
			});
			if(sky < 15){
				waiting++;
				continue;
			}
			if(id == sapling[kind]){
				world.set_node(x, y, z, grown[kind]);
				grew++;
			} else if(grow_tree(x, y, z, kind == 1)){
				grew++, trees++;
			} else
				waiting++;
		}
		log_i(MODULE, "skeldat: %zu saplings grew at midnight (%zu trees); %zu "
				"apples again, %zu off soil gone, %zu waiting", grew, trees, apples,
				lost, waiting);
	}
};
// vim: set noet ts=4 sw=4:
