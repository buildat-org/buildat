// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// [SKELDAT_MAKING_MAP] **The world's making as a map** to the players
// waiting for it: the footprints the screen's dark, a footprint black once
// a section of it is in, and its map once all of them are -- swept into
// the top map then (bones_growth.h's sweep()) rather than all at once in
// world_in(), which sweeps only those not done. To the peers waiting
// (connected, not yet in the world), "skeldat:making_map":
//   "grid N"                    N footprints across (2 * half)
//   "loaded sx sz"              sx, sz from -half to half - 1
//   "map sx sz\n" + 4096 bytes  a column a byte, row by row from the
//                               footprint's least z, x least first: the
//                               class (0 nothing, 1 grass, 2 water, 3 the
//                               rest) in the high two bits, the top's
//                               height (y0..y1 in 64 steps) in the low six
//   "off"                       the world is in
// The client's half is client_lua/making_map.lua, which start() runs on
// each of them; a peer that comes to the wait part way gets what is there
// in one go.
// Included by main.cpp inside namespace skeldat, after bones_growth.h
#pragma once

struct MakingMap
{
	WorldView &world;
	BonesGrowth &growth;
	// The Module's: the peers waiting for the world, and the sections
	// asked of worldgen and not merged yet
	std::set<size_t> &waiting;
	std::set<ss_> &awaiting;
	// A footprint's state: 0 nothing in, 1 a section in, 2 swept
	std::vector<uint8_t> state;
	// A swept footprint's map, kept for the peers that come later
	std::vector<ss_> maps;
	// Footprints a section of came into: checked on the tick
	std::set<size_t> touched;
	// The peers the client half runs on
	std::set<size_t> started;
	bool on = false;

	MakingMap(WorldView &world, BonesGrowth &growth, std::set<size_t> &waiting,
			std::set<ss_> &awaiting):
		world(world), growth(growth), waiting(waiting), awaiting(awaiting)
	{}

	void send(size_t peer, const ss_ &data)
	{
		network::send(world.server, peer, "skeldat:making_map", data);
	}

	// The client half on `peer` and what there is so far
	void start(size_t peer)
	{
		if(!on || !started.insert(peer).second)
			return;
		network::send(world.server, peer, "core:run_script",
				"buildat.run_script_file(\"main/making_map.lua\")");
		send(peer, "grid "+itos(2 * world.half));
		for(size_t i = 0; i < state.size(); i++){
			const int sx = (int)(i % (2 * world.half)) - world.half,
					sz = (int)(i / (2 * world.half)) - world.half;
			if(state[i] == 2)
				send(peer, "map "+itos(sx)+" "+itos(sz)+"\n"+maps[i]);
			else if(state[i] == 1)
				send(peer, "loaded "+itos(sx)+" "+itos(sz));
		}
	}

	// The first section of the world in: the top map's columns made (the
	// sweeps write into them from here on) and the waiting told
	void begin()
	{
		if(on)
			return;
		on = true;
		const size_t cols = world.footprints() * skeldat::bones::SECTION *
				skeldat::bones::SECTION;
		world.top_y.assign(cols, NO_GROUND);
		world.top_b.assign(cols, 0);
		growth.flooded.assign(world.footprints(), 0);
		state.assign(world.footprints(), 0);
		maps.assign(world.footprints(), ss_());
		for(size_t peer : waiting)
			start(peer);
	}

	// Footprint (sx, sz)'s index, -1 outside
	long index(int sx, int sz) const
	{
		if(sx < -world.half || sx >= world.half || sz < -world.half ||
				sz >= world.half)
			return -1;
		return (long)(sz + world.half) * (2 * world.half) + (sx + world.half);
	}

	void loaded(const pv::Vector3DInt16 &sp)
	{
		begin();
		const long i = index(sp.getX(), sp.getZ());
		if(i < 0)
			return;
		touched.insert(i);
		if(state[i] != 0)
			return;
		state[i] = 1;
		for(size_t peer : started)
			send(peer, "loaded "+itos(sp.getX())+" "+itos(sp.getZ()));
	}

	// Each of its sections loaded and generated
	bool complete(size_t i) const
	{
		const int sx = (int)(i % (2 * world.half)) - world.half,
				sz = (int)(i / (2 * world.half)) - world.half;
		for(int sy = world.y0; sy <= world.y1; sy++){
			const ss_ key = pos_key(sx, sy, sz);
			if(!growth.sections.count(key) || awaiting.count(key))
				return false;
		}
		return true;
	}

	// Footprint i swept into the top map and its map made of the same read
	void sweep(voxelworld::Instance *w, size_t i)
	{
		const int S = skeldat::bones::SECTION;
		const int sx = (int)(i % (2 * world.half)) - world.half,
				sz = (int)(i / (2 * world.half)) - world.half;
		const int ybase = world.y0 * S, ys = (world.y1 - world.y0 + 1) * S;
		const uint32_t grass = world.id_of("skeldat:grass");
		ss_ m((size_t)S * S, '\0');
		growth.sweep(w, i, [&](int x, int z, int y, uint32_t id){
			const skeldat::NodeDef *n = world.node_of(id);
			const int cls = id == grass ? 1 :
					n && n->shape == skeldat::LIQUID ? 2 : 3;
			const int h = std::max(0, std::min(63, (y - ybase) * 64 / ys));
			m[(size_t)(z - sz * S) * S + (x - sx * S)] = (char)(cls << 6 | h);
		});
		if(state.size() > i){
			state[i] = 2;
			maps[i] = m;
			for(size_t peer : started)
				send(peer, "map "+itos(sx)+" "+itos(sz)+"\n"+m);
		}
	}

	// On the tick, while the world comes in: the footprints just completed,
	// two a tick at most (the rest are taken on the next ones, or by
	// world_in())
	void step()
	{
		if(!on || touched.empty())
			return;
		size_t n = 0;
		voxelworld::access(world.server, world.scene, [&](voxelworld::Instance *w){
			for(auto it = touched.begin(); it != touched.end() && n < 2;){
				if(state[*it] != 2 && complete(*it)){
					sweep(w, *it);
					n++;
					it = touched.erase(it);
				} else if(state[*it] == 2){
					it = touched.erase(it);
				} else {
					++it;
				}
			}
		});
	}

	// The world in: the client halves let go
	void end()
	{
		for(size_t peer : started)
			send(peer, "off");
		started.clear();
		touched.clear();
	}
};
// vim: set noet ts=4 sw=4:
