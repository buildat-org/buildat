// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MODULAR] **The bones' growth** (bones.h's rule): every loaded
// section expands every section_period on average, at the bones' speed;
// burning lanterns' spheres hold them off (Furnaces). And the world's end
// it leads to: the columns whose top has no bones, counted by section,
// and the end at none. What the end does to the players and the save is
// the Module's (count()).
// Included by main.cpp inside namespace skeldat, after furnaces.h
#pragma once

struct BonesGrowth
{
	WorldView &world;
	Furnaces &furnaces;
	// A voxel inside a player's box, which nothing grows into
	// ([SKELDAT_SPAWN_STUCK_2]); main.cpp's
	std::function<bool(int, int, int)> occupied;
	// The loaded sections: the whole world, once it is in
	// ([SKELDAT_BOUNDED_WORLD]: no catch-up, nothing is ever away)
	std::set<ss_> sections;
	// **The end** ([SKELDAT_BOUNDED_WORLD], [SKELDAT_SURFACE_END]): the
	// columns whose top -- the highest voxel that can hold bones -- has
	// none, by the section the top is in, counted again after an
	// expansion, a dig or a place; at none in all the world ends, its days
	// the high score, and nothing changes in it after. What is under the
	// tops does not count, nor a column whose top is a liquid (water,
	// lava: [SKELDAT_OWN_MAPGEN], the land alone).
	std::map<ss_, int64_t> bare;
	// The total of bare once a game day, the last few: (day, count)
	std::deque<std::pair<double, int64_t>> bare_days;
	std::set<ss_> recount;
	bool ended = false;
	double end_days = 0;
	// Seconds between a section's expansions; BUILDAT_SKELDAT_EXPAND for a
	// check
	double section_period = skeldat::bones::SECTION_PERIOD;
	// The columns whose top voxel has FLOOD bones or more, a section's
	// footprint each (x then z from -half), swept one a second; the
	// skeletons' count adjusted every game hour; and the columns whose top
	// is not a liquid ([SKELDAT_OWN_MAPGEN]: the share flooded is of the
	// land)
	sv_<int> flooded, land;
	// Expansions owed: due at random by the period
	double expand_due = 0;
	size_t expansions = 0, expand_changed = 0, grown = 0, grown_wet = 0;
	// [SKELDAT_BONE_SPEED] The bones' speed, 1, 2, 5 or 10: the rule's
	// runs in each expansion and the skeletons' bone work scaled by it;
	// the lowest the world has been at, which its score names; the rule's
	// runs so far. Over each minute of real time, the game seconds ticked
	// and the expansions the budget a tick dropped (BUILDAT_SKELDAT_BUDGET
	// for a check), against the minute's: the server behind, by a tick
	// late or an expansion dropped alike.
	int speed = 1, speed_low = 1;
	size_t rule_runs = 0;
	// The rule's runs in an expansion: the speed times bones::PACE
	// ([SKELDAT_MORE_FUN]), and what scales with it here
	int runs() const { return skeldat::bones::PACE * speed; }
	double ticked_s = 0, dropped_n = 0;
	int64_t keep_up_us = 0;
	// Expansions a tick at most, a fraction carried to the next tick
	double budget = 4, budget_left = 0;

	BonesGrowth(WorldView &world, Furnaces &furnaces):
		world(world), furnaces(furnaces)
	{}

	// Every loaded section expands every SECTION_PERIOD on average, picked
	// at random. skipping: [SKELDAT_SKIP_TIME]'s, which does all its
	// expansions, late or not. behind(line): the server behind, once a
	// minute of real time, while anyone plays
	void step(float dtime, bool skipping, bool anyone,
			const std::function<void(const char *line)> &behind)
	{
		if(sections.empty())
			return;
		const double rate = sections.size() / section_period;
		expand_due += dtime * rate;
		ticked_s += dtime;
		budget_left = std::min(budget_left + budget,
				std::max(budget, 1.0));
		int left = (int)budget_left;
		budget_left -= left;
		while(expand_due >= 1 && left-- > 0){
			expand_due -= 1;
			auto it = sections.begin();
			std::advance(it, world.rand() % sections.size());
			expand(*it);
		}
		// What the budget did not reach is dropped, not carried: a server
		// that falls behind grows the bones slower rather than in a burst
		if(expand_due > 1 && !skipping){
			dropped_n += expand_due - 1;
			expand_due = 1;
		}
		if(skipping)
			return;
		const int64_t now = interface::os::time_us();
		if(keep_up_us == 0)
			keep_up_us = now;
		if(now - keep_up_us < 60000000)
			return;
		const double due = (now - keep_up_us) / 1e6 * rate;
		const double ratio = due > 0 ?
				(ticked_s * rate - dropped_n) / due : 1;
		if(ratio < 0.95 && anyone && !ended){
			const double at = speed * ratio;
			char line[120];
			snprintf(line, sizeof line, "The server can't keep up with %dx "
					"bones: about %.*fx this last minute", speed,
					at < 2 ? 1 : 0, at);
			log_i(MODULE, "skeldat: %s", line);
			behind(line);
		}
		keep_up_us = now;
		ticked_s = dropped_n = 0;
	}

	// The counts kept up, a few sections a tick; true when the world ends
	// now (day: the game days it has run)
	bool count(bool world_ready, double day)
	{
		for(int left = 8; left > 0 && !recount.empty(); left--){
			const ss_ key = *recount.begin();
			recount.erase(recount.begin());
			count_section(key);
		}
		if(ended || !world_ready || !recount.empty() ||
				bare.size() < world.all_sections())
			return false;
		int64_t total = 0;
		for(auto &pair : bare)
			total += pair.second;
		// A game day's count, the last four kept ([SKELDAT_INTRO])
		if(bare_days.empty() || day - bare_days.back().first >= 1){
			bare_days.push_back({day, total});
			if(bare_days.size() > 4)
				bare_days.pop_front();
			log_i(MODULE, "skeldat: day %.1f, %lld columns bare", day,
					(long long)total);
		}
		if(total > 0)
			return false;
		ended = true;
		end_days = day;
		return true;
	}

	// The voxels under the tops that have no bones, which the end does not
	// wait for
	int64_t bare_under()
	{
		int64_t under = 0;
		voxelworld::access(world.server, world.scene,
				[&](voxelworld::Instance *w){
			for(const ss_ &key : sections){
				int sx, sy, sz;
				char c;
				std::istringstream is(key);
				if(!(is>>sx>>c>>sy>>c>>sz))
					continue;
				const pv::Vector3DInt16 sp(sx, sy, sz);
				if(!w->is_section_loaded(sp))
					continue;
				const interface::VoxelVolume vol = w->get_volume(
						w->get_section_region_voxels(sp));
				const pv::Region r = w->get_section_region_voxels(sp);
				const pv::Vector3DInt32 &lc = r.getLowerCorner(),
						&uc = r.getUpperCorner();
				for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
				for(int32_t y = lc.getY(); y <= uc.getY(); y++)
				for(int32_t x = lc.getX(); x <= uc.getX(); x++){
					const interface::VoxelSample v = vol.sample_at(x, y, z);
					under += world.holds_bones(world.format.id.get(v)) &&
							world.bones.get(v) == 0;
				}
			}
		});
		return under;
	}

	// One expansion of a section, written back in one set_volume of the
	// voxels it changed
	void expand(const ss_ &key)
	{
		int sx, sy, sz;
		char c;
		std::istringstream is(key);
		if(!(is>>sx>>c>>sy>>c>>sz))
			return;
		const pv::Vector3DInt16 sp(sx, sy, sz);
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			if(!w->is_section_loaded(sp))
				return;
			const pv::Region section = w->get_section_region_voxels(sp);
			pv::Region grown = section;
			grown.setLowerCorner(grown.getLowerCorner() -
					pv::Vector3DInt32(1, 1, 1));
			grown.setUpperCorner(grown.getUpperCorner() +
					pv::Vector3DInt32(1, 1, 1));
			interface::VoxelVolume vol = w->get_volume(grown);
			if(!vol.plane_is_materialised(1))
				return; // no bones in it nor around it
			const pv::Vector3DInt32 &lc = grown.getLowerCorner();
			skeldat::bones::Box box(vol.getWidth(), vol.getHeight(),
					vol.getDepth());
			bool any = false;
			for(int z = 0; z < box.d; z++)
			for(int y = 0; y < box.h; y++)
			for(int x = 0; x < box.w; x++){
				const interface::VoxelSample v = vol.sample_at(
						lc.getX() + x, lc.getY() + y, lc.getZ() + z);
				const uint32_t id = world.format.id.get(v);
				const size_t i = box.at(x, y, z);
				box.air[i] = !world.holds_bones(id);
				box.b[i] = (uint8_t)world.bones.get(v);
				// A liquid's or gas's bones from before
				// [SKELDAT_BONES_UNDERWATER]: gone, and flood nothing
				const skeldat::NodeDef *def = world.node_of(id);
				if(def && (def->shape == skeldat::LIQUID ||
						def->shape == skeldat::GAS))
					box.b[i] = 0;
				any = any || box.b[i] != 0;
			}
			if(!any)
				return;
			// Burning lanterns' spheres are air to the flood (nothing
			// gains, nothing floods through); in them the bones fall by
			// one now and then, and bone blocks go
			const sv_<pv::Vector3DInt32> lit = furnaces.lanterns_in(grown);
			const sv_<uint8_t> air = box.air;
			sv_<uint8_t> guard;
			if(!lit.empty()){
				guard.assign(box.b.size(), 0);
				const int R2 = LANTERN_RADIUS * LANTERN_RADIUS;
				for(int z = 0; z < box.d; z++)
				for(int y = 0; y < box.h; y++)
				for(int x = 0; x < box.w; x++)
				for(const pv::Vector3DInt32 &l : lit){
					const int dx = lc.getX() + x - l.getX(),
							dy = lc.getY() + y - l.getY(),
							dz = lc.getZ() + z - l.getZ();
					if(dx * dx + dy * dy + dz * dz <= R2){
						guard[box.at(x, y, z)] = 1;
						box.air[box.at(x, y, z)] = 1;
						break;
					}
				}
			}
			const sv_<uint8_t> before = box.b;
			expansions++;
			for(int k = 0; k < runs(); k++)
				skeldat::bones::expand(box);
			rule_runs += runs();
			const uint32_t block = world.id_of("skeldat:bone_block");
			sv_<pv::Vector3DInt32> decayed;
			if(!guard.empty()){
				for(int z = 1; z < box.d - 1; z++)
				for(int y = 1; y < box.h - 1; y++)
				for(int x = 1; x < box.w - 1; x++){
					const size_t i = box.at(x, y, z);
					if(!guard[i] || air[i])
						continue;
					const int retract = LANTERN_RETRACT * runs();
					box.b[i] = before[i] > retract ? before[i] - retract : 0;
					const pv::Vector3DInt32 p(lc.getX() + x, lc.getY() + y,
							lc.getZ() + z);
					if(world.format.id.get(vol.sample_at(p.getX(), p.getY(),
							p.getZ())) == block &&
							world.rnd() < 1 - std::pow(1 - 1.0 / LANTERN_DECAY_IN,
							runs()))
						decayed.push_back(p);
				}
			}
			recount.insert(key);
			interface::VoxelVolume out(section, world.format.planes);
			size_t changed = 0;
			for(int z = 1; z < box.d - 1; z++)
			for(int y = 1; y < box.h - 1; y++)
			for(int x = 1; x < box.w - 1; x++){
				const size_t i = box.at(x, y, z);
				if(box.b[i] == before[i])
					continue;
				const int32_t px = lc.getX() + x, py = lc.getY() + y,
						pz = lc.getZ() + z;
				interface::VoxelSample v = vol.sample_at(px, py, pz);
				world.bones.set(v, box.b[i]);
				out.set_sample_at(px, py, pz, v);
				changed++;
			}
			expand_changed += changed;
			// The light as it was read: nothing here changes it
			if(changed)
				w->set_volume(out, false, true);
			interface::VoxelSample gone;
			world.format.id.set(gone.planes[0], ID_AIR);
			if(!decayed.empty())
				recount.insert(key);
			for(const pv::Vector3DInt32 &p : decayed){
				w->set_sample(p, gone);
				world.rescan_column(w, p.getX(), p.getZ());
				log_i(MODULE, "skeldat: a bone block at %d,%d,%d goes",
						p.getX(), p.getY(), p.getZ());
			}
			grow(w, vol, box, guard);
		});
	}

	// Bones off the voxels at MAX with air, a liquid or a gas over them, now
	// and then (bones::GROW_ONE_IN): a bone block on a bone block stacks to
	// STACK_MAX; a skull, two or a bone tops nothing. Not into a burning
	// lantern's sphere (`guard`, empty when none reaches the box), nor into a
	// player (`occupied`). A liquid
	// or gas grown into is displaced as a placed voxel's is (set_node_in's
	// on_set, [SKELDAT_DISPLACE]), so a pile rises from a lake's bed
	void grow(voxelworld::Instance *w, const interface::VoxelVolume &vol,
			const skeldat::bones::Box &box, const sv_<uint8_t> &guard)
	{
		using namespace skeldat::bones;
		const uint32_t block = world.id_of("skeldat:bone_block");
		const uint32_t tops[3] = {world.id_of("skeldat:skull"),
				world.id_of("skeldat:skulls"), world.id_of("skeldat:bone_lying")};
		const pv::Vector3DInt32 lc = vol.getEnclosingRegion().getLowerCorner();
		for(int z = 1; z < box.d - 1; z++)
		for(int y = 1; y < box.h - 2; y++)
		for(int x = 1; x < box.w - 1; x++){
			const size_t i = box.at(x, y, z);
			if(box.b[i] < MAX || box.air[i] ||
					world.rand() % GROW_ONE_IN >= (uint32_t)runs() ||
					(!guard.empty() && guard[box.at(x, y + 1, z)]))
				continue;
			const int32_t px = lc.getX() + x, py = lc.getY() + y,
					pz = lc.getZ() + z;
			const uint32_t over = world.format.id.get(vol.sample_at(px, py + 1, pz));
			const skeldat::NodeDef *od = world.node_of(over);
			if(over != ID_AIR && !(od && (od->shape == skeldat::LIQUID ||
					od->shape == skeldat::GAS)))
				continue;
			if(occupied && occupied(px, py + 1, pz))
				continue;
			const uint32_t id = world.format.id.get(vol.sample_at(px, py, pz));
			if(id == tops[0] || id == tops[1] || id == tops[2])
				continue;
			int height = 0;
			while(height < STACK_MAX && py - height >= lc.getY() &&
					world.format.id.get(vol.sample_at(px, py - height, pz)) == block)
				height++;
			uint32_t top = block;
			if(height >= STACK_MAX || (height == 0 && world.rand() % 2))
				top = tops[world.rand() % 3];
			else if(height > 0 && world.rand() % 3 == 0)
				top = tops[world.rand() % 3];
			world.set_node_in(w, px, py + 1, pz, top,
					top == block ? 0 : world.rand() % 4, MAX);
			grown++;
			grown_wet += over != ID_AIR;
		}
	}

	// A section's columns whose top is in it and has no bones; the top
	// found from the world's top down
	void count_section(const ss_ &key)
	{
		int sx, sy, sz;
		char c;
		std::istringstream is(key);
		if(!(is>>sx>>c>>sy>>c>>sz))
			return;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			const int S = skeldat::bones::SECTION;
			// A column not all loaded yet: counted again later (a section
			// left out keeps the world from ending)
			for(int y = sy; y <= world.y1; y++)
				if(!w->is_section_loaded(pv::Vector3DInt16(sx, y, sz))){
					recount.insert(key);
					return;
				}
			const pv::Region r(pv::Vector3DInt32(sx * S, sy * S, sz * S),
					pv::Vector3DInt32(sx * S + S - 1, world.y1 * S + S - 1,
					sz * S + S - 1));
			interface::VoxelVolume vol = w->get_volume(r);
			int64_t n = 0;
			for(int z = sz * S; z < sz * S + S; z++)
			for(int x = sx * S; x < sx * S + S; x++)
			for(int y = world.y1 * S + S - 1; y >= sy * S; y--){
				const interface::VoxelSample v = vol.sample_at(x, y, z);
				const uint32_t id = world.format.id.get(v);
				// A liquid on top: the column is not the land's, and its bed
				// is not counted either; a gas is passed as air is
				const skeldat::NodeDef *def = world.node_of(id);
				if(def && def->shape == skeldat::LIQUID)
					break;
				if(!world.holds_bones(id))
					continue;
				n += y < sy * S + S && world.bones.get(v) == 0;
				break;
			}
			bare[key] = n;
		});
	}

	// Footprint i's columns into the top map, its columns at FLOOD or more
	// into flooded and those not topped by a liquid into land
	// also(x, z, y, id): each column's top as it is read
	// ([SKELDAT_MAKING_MAP]'s map, from the same one read)
	void sweep(voxelworld::Instance *w, size_t i,
			std::function<void(int, int, int, uint32_t)> also = nullptr)
	{
		const int sx = (int)(i % (2 * world.half)) - world.half,
				sz = (int)(i / (2 * world.half)) - world.half;
		const int S = skeldat::bones::SECTION;
		for(int z = sz * S; z < sz * S + S; z++)
		for(int x = sx * S; x < sx * S + S; x++)
			world.set_top(x, z, NO_GROUND, ID_IGNORE, 0);
		int n = 0, l = 0;
		world.each_top(w, sx, sz, [&](int x, int z, int y, uint32_t id,
				const interface::VoxelSample &v){
			const uint32_t b = world.bones.get(v);
			world.set_top(x, z, y, id, b);
			const skeldat::NodeDef *def = world.node_of(id);
			const bool liquid = def && def->shape == skeldat::LIQUID;
			// simplified: a gas on top counts as land with no bones (the
			// count passes it); the ground under it read when it matters
			n += (int)b >= skeldat::bones::FLOOD && world.holds_bones(id);
			l += !liquid;
			if(also)
				also(x, z, y, id);
		});
		flooded[i] = n;
		land[i] = l;
	}

	static bool valid_speed(int s)
	{
		return s == 1 || s == 2 || s == 5 || s == 10;
	}
};
// vim: set noet ts=4 sw=4:
