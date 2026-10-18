// Buildat: apps/skeldat/main/hazards.h
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// The mining hazards' rules ([SKELDAT_MINING_HAZARDS],
// [SKELDAT_LIQUID_PRESSURE]): liquids of constant volume, their pressure,
// gases that drift and halve, lava's volcanic gas. Only an active set is
// stepped -- the cells a change touched and their six neighbours -- each
// when it is due, at most a cap a call; a sealed pocket costs nothing.
// - A liquid (water, lava; lava slower): down first, as much as the cell
//   under has room for; then across, an eighth to each side that has 2
//   less; then the push. Volume moves, never made or lost.
// - The push ([SKELDAT_LIQUID_PRESSURE]): a full cell's felt surface is
//   the highest column top among the full cells of the same liquid
//   connected to it (a search through at most PRESSURE_REACH of them),
//   at most PRESSURE_MAX voxels over any cell on the way. Over its own
//   column's top, an eighth comes off that highest surface and goes on
//   its own column.
//   simplified: level-seeking, an eighth carried through the body, not a
//   pressure field; found when wanted, not handed on a cell a step (a
//   still pocket's cells are not stepped, and a surface they handed on
//   would go stale, and the plan's eighth pushed up out of the cell
//   itself fell straight back by the down rule).
// - A gas: a random neighbour; air -> both the gas at half the share,
//   the same gas -> both the mean; a share under GAS_MIN is air.
// - Lava beside water is stone; pocket water beside the sea is taken in;
//   lava beside air turns that air into volcanic gas, one step in
//   LAVA_GAS_ONE_IN.
// Pure: no Buildat, no module; main.cpp hands it the cells. Self test:
//   g++ -std=c++11 -DSKELDAT_HAZARDS_TEST -x c++ apps/skeldat/main/hazards.h -o /tmp/skeldat_hazards && /tmp/skeldat_hazards
//   (one line)
#pragma once
#include <algorithm>
#include <cstdint>
#include <functional>
#include <queue>
#include <random>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace skeldat {
namespace hazards {

// The tuning numbers (the user's to try): the steps' periods in seconds,
// the cells stepped a call at most, a gas thinned out of being under
// GAS_MIN of 255, lava's volcanic gas one step in LAVA_GAS_ONE_IN, the
// pressure's push at most PRESSURE_MAX voxels over a cell's own top
static const double WATER_PERIOD = 0.5, LAVA_PERIOD = 2.0, GAS_PERIOD = 2.0;
static const size_t STEP_CAP = 256;
// The server's step every TICK seconds, the cells due by then
static const double TICK = 0.25;
static const int GAS_MIN = 8, LAVA_GAS_ONE_IN = 600, PRESSURE_MAX = 4,
		PRESSURE_REACH = 64;

enum Kind: uint8_t { AIR, SOLID, WATER, LAVA, POISON, VOLCANIC, SEA };
// amount: a liquid's eighths (1..8), a gas's share (1..255)
struct Cell {
	uint8_t kind = SOLID;
	uint8_t amount = 0;
	Cell(){}
	Cell(uint8_t kind, uint8_t amount = 0): kind(kind), amount(amount){}
};
inline bool liquid(uint8_t k){ return k == WATER || k == LAVA; }
inline bool gas(uint8_t k){ return k == POISON || k == VOLCANIC; }

inline uint64_t key(int x, int y, int z)
{
	return ((uint64_t)(uint32_t)(x + 1048576) << 42) |
			((uint64_t)(uint32_t)(y + 1048576) << 21) | (uint32_t)(z + 1048576);
}
inline void unkey(uint64_t k, int &x, int &y, int &z)
{
	x = (int)(k >> 42) - 1048576;
	y = (int)((k >> 21) & 0x1fffff) - 1048576;
	z = (int)(k & 0x1fffff) - 1048576;
}

static const int SIDES[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
static const int SIX[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0},
		{0, 0, 1}, {0, 0, -1}};

struct Hazards
{
	// get(x, y, z) -> Cell; set(x, y, z, Cell), the world's change
	std::function<Cell(int, int, int)> get;
	std::function<void(int, int, int, const Cell &)> set;
	std::mt19937 rng{12345};
	std::unordered_set<uint64_t> active;
	typedef std::pair<double, uint64_t> Due;
	std::priority_queue<Due, std::vector<Due>, std::greater<Due>> due;
	double now = 0;
	size_t stepped = 0, gassed = 0;

	static double period(uint8_t k){
		return k == LAVA ? LAVA_PERIOD : gas(k) ? GAS_PERIOD : WATER_PERIOD;
	}

	// The cell and its six neighbours into the set, due after their period
	void touch(int x, int y, int z)
	{
		wake(x, y, z);
		for(const auto &d : SIX)
			wake(x + d[0], y + d[1], z + d[2]);
	}
	void wake(int x, int y, int z, double after = -1)
	{
		const uint64_t k = key(x, y, z);
		if(!active.insert(k).second)
			return;
		if(after < 0){
			const Cell c = get(x, y, z);
			after = period(c.kind);
			// A gas's own offset, so a cloud does not move in one beat
			if(gas(c.kind))
				after *= 0.5 + std::uniform_real_distribution<double>(0, 1)(rng);
		}
		due.push(Due(now + after, k));
	}
	void put(int x, int y, int z, const Cell &c)
	{
		set(x, y, z, c);
		touch(x, y, z);
	}

	// Steps what is due at time t, at most cap; the count stepped
	size_t step(double t, size_t cap = STEP_CAP)
	{
		now = t;
		size_t n = 0;
		while(n < cap && !due.empty() && due.top().first <= t){
			const uint64_t k = due.top().second;
			due.pop();
			active.erase(k);
			int x, y, z;
			unkey(k, x, y, z);
			n++;
			if(step_cell(x, y, z))
				wake(x, y, z);
		}
		stepped += n;
		return n;
	}

	// The surface over a liquid cell's column, in eighths (y * 8 + 8 a
	// full cell's top)
	int own_top(int x, int y, int z, uint8_t k)
	{
		for(int yy = y; yy <= y + 64; yy++){
			const Cell c = get(x, yy, z);
			if(c.kind != k)
				return yy * 8;
			if(c.amount < 8)
				return yy * 8 + c.amount;
		}
		return (y + 65) * 8;
	}

	// The felt surface at a cell of liquid k: the highest column top among
	// the full cells connected to it (itself if full, else those beside
	// and under it), each capped PRESSURE_MAX over the cells on its way;
	// from, where an eighth of that surface is (the partial cell over that
	// column's top, or its top full cell), -1 with none
	int felt_at(int x, int y, int z, uint8_t k, uint64_t *from = nullptr)
	{
		// Each cell's cap: the least of PRESSURE_MAX over each cell on the
		// way to it, kept at its best (a widest path), so a push through a
		// breach at a pocket's foot stands at most PRESSURE_MAX over it
		std::vector<uint64_t> todo;
		std::unordered_map<uint64_t, int> cap;
		auto add = [&](int a, int b, int c, int via){
			const Cell n = get(a, b, c);
			if(n.kind != k || n.amount != 8)
				return;
			const int v = std::min(via, b * 8 + 8 + PRESSURE_MAX * 8);
			auto it = cap.find(key(a, b, c));
			if(it != cap.end() && it->second >= v)
				return;
			cap[key(a, b, c)] = v;
			todo.push_back(key(a, b, c));
		};
		const int own = y * 8 + 8 + PRESSURE_MAX * 8;
		const Cell self = get(x, y, z);
		if(self.kind == k && self.amount == 8){
			add(x, y, z, own);
		} else {
			for(const auto &d : SIDES)
				add(x + d[0], y, z + d[1], own);
			add(x, y - 1, z, own);
		}
		int S = -1;
		for(size_t i = 0; i < todo.size() && i < (size_t)PRESSURE_REACH * 4; i++){
			int a, b, c;
			unkey(todo[i], a, b, c);
			const int via = cap[todo[i]];
			const Cell up = get(a, b + 1, c);
			if(up.kind != k || up.amount < 8){
				const bool part = up.kind == k;
				const int top = std::min(via, b * 8 + 8 + (part ? up.amount : 0));
				if(top > S){
					S = top;
					if(from)
						*from = part ? key(a, b + 1, c) : todo[i];
				}
			}
			if(cap.size() < (size_t)PRESSURE_REACH)
				for(const auto &d : SIX)
					add(a + d[0], b + d[1], c + d[2], via);
		}
		return S;
	}

	// One cell's step; true when it stays active
	bool step_cell(int x, int y, int z)
	{
		Cell c = get(x, y, z);
		if(liquid(c.kind))
			return step_liquid(x, y, z, c);
		if(gas(c.kind))
			return step_gas(x, y, z, c);
		return false;
	}

	bool step_liquid(int x, int y, int z, Cell c)
	{
		const uint8_t k = c.kind;
		bool moved = false;
		// Lava beside water is stone; pocket water beside the sea is
		// taken in
		for(const auto &d : SIX){
			const Cell n = get(x + d[0], y + d[1], z + d[2]);
			if(k == LAVA && (n.kind == WATER || n.kind == SEA)){
				put(x, y, z, Cell(SOLID));
				return false;
			}
			if(k == WATER && n.kind == SEA){
				put(x, y, z, Cell(AIR));
				return false;
			}
		}
		// Down
		const Cell below = get(x, y - 1, z);
		if(below.kind == AIR || (below.kind == k && below.amount < 8)){
			const int room = below.kind == AIR ? 8 : 8 - below.amount;
			const int m = std::min((int)c.amount, room);
			put(x, y - 1, z, Cell(k, (uint8_t)((below.kind == AIR ? 0 :
					below.amount) + m)));
			c.amount = (uint8_t)(c.amount - m);
			put(x, y, z, c.amount ? c : Cell(AIR));
			moved = true;
			if(!c.amount)
				return true;
		}
		// Across: an eighth to each side 2 lower
		int order[4] = {0, 1, 2, 3};
		std::shuffle(order, order + 4, rng);
		for(int i : order){
			if(c.amount <= 1)
				break;
			const int sx = x + SIDES[i][0], sz = z + SIDES[i][1];
			const Cell s = get(sx, y, sz);
			if(s.kind != AIR && s.kind != k)
				continue;
			const int sa = s.kind == AIR ? 0 : s.amount;
			if(c.amount - sa >= 2){
				put(sx, y, sz, Cell(k, (uint8_t)(sa + 1)));
				c.amount--;
				put(x, y, z, c);
				moved = true;
			}
		}
		// The push, at its column's surface: a partial cell, or a full one
		// with air or a partial cell over it. The felt surface over this
		// column's top: an eighth off the felt surface, onto it (into a
		// partial cell itself, over a full one)
		int top = -1, S = -1;
		const Cell up = get(x, y + 1, z);
		const bool surface = c.amount < 8 ||
				up.kind == AIR || (up.kind == k && up.amount < 8);
		if(surface){
			uint64_t from = 0;
			top = c.amount < 8 ? y * 8 + c.amount :
					y * 8 + 8 + (up.kind == k ? up.amount : 0);
			S = felt_at(x, y, z, k, &from);
			int fx, fy, fz;
			unkey(from, fx, fy, fz);
			Cell f = get(fx, fy, fz);
			// An eighth off the top of that column (from is its surface),
			// 2 over this one's as across, or one eighth goes to and fro
			if(S > top + 1 && f.kind == k && f.amount > 0 &&
					fy * 8 + f.amount > top + 1 && key(x, y, z) != from){
				f.amount--;
				put(fx, fy, fz, f.amount ? f : Cell(AIR));
				if(c.amount < 8){
					c.amount++;
					put(x, y, z, c);
				} else {
					put(x, y + 1, z, Cell(k, (uint8_t)((up.kind == AIR ? 0 :
							up.amount) + 1)));
				}
				moved = true;
			}
		}
		// Lava's volcanic gas into an air cell beside it
		if(k == LAVA){
			bool air = false;
			for(const auto &d : SIX)
				air = air || get(x + d[0], y + d[1], z + d[2]).kind == AIR;
			if(air && (int)(rng() % LAVA_GAS_ONE_IN) == 0){
				const auto &d = SIX[rng() % 6];
				if(get(x + d[0], y + d[1], z + d[2]).kind == AIR){
					put(x + d[0], y + d[1], z + d[2], Cell(VOLCANIC, 255));
					gassed++;
				}
			}
			if(air)
				return true;
		}
		// Kept while it moves, or while pressed (the surface it feels may
		// still give)
		return moved || S > top + 1;
	}

	bool step_gas(int x, int y, int z, Cell c)
	{
		if(c.amount < GAS_MIN){
			put(x, y, z, Cell(AIR));
			return false;
		}
		const auto &d = SIX[rng() % 6];
		const int nx = x + d[0], ny = y + d[1], nz = z + d[2];
		const Cell n = get(nx, ny, nz);
		if(n.kind == AIR){
			const uint8_t h = (uint8_t)(c.amount / 2);
			const Cell g = h < GAS_MIN ? Cell(AIR) : Cell(c.kind, h);
			put(x, y, z, g);
			put(nx, ny, nz, g);
			return g.kind != AIR;
		}
		if(n.kind == c.kind && n.amount != c.amount){
			const int sum = c.amount + n.amount;
			put(x, y, z, Cell(c.kind, (uint8_t)((sum + 1) / 2)));
			put(nx, ny, nz, Cell(c.kind, (uint8_t)(sum / 2)));
			return true;
		}
		// Still with something to mix with
		for(const auto &e : SIX){
			const Cell o = get(x + e[0], y + e[1], z + e[2]);
			if(o.kind == AIR || (o.kind == c.kind && o.amount != c.amount))
				return true;
		}
		return false;
	}
};

#ifdef SKELDAT_HAZARDS_TEST
}
}
#include <cassert>
#include <cstdio>
#include <map>
#include <tuple>
using namespace skeldat::hazards;
// A world of cells, solid where nothing is set
struct Map {
	std::map<std::tuple<int, int, int>, Cell> m;
	Cell get(int x, int y, int z) const {
		auto it = m.find(std::make_tuple(x, y, z));
		return it == m.end() ? Cell(SOLID) : it->second;
	}
	void set(int x, int y, int z, const Cell &c){ m[std::make_tuple(x, y, z)] = c; }
	int sum(uint8_t k) const {
		int s = 0;
		for(auto &p : m)
			if(p.second.kind == k)
				s += p.second.amount;
		return s;
	}
};
static Hazards bind(Map &m)
{
	Hazards h;
	h.get = [&m](int x, int y, int z){ return m.get(x, y, z); };
	h.set = [&m](int x, int y, int z, const Cell &c){ m.set(x, y, z, c); };
	return h;
}
static void run(Hazards &h, double secs)
{
	const double end = h.now + secs;
	for(double t = h.now; t < end; t += 0.05)
		h.step(t);
}
int main()
{
	setvbuf(stdout, nullptr, _IONBF, 0);
	// 1. A pocket of 8 water cells (2x2x2) opened into a tunnel 1 high
	// along x: its 64 eighths over 200 steps
	{
		Map m;
		for(int x = 0; x < 2; x++) for(int y = 0; y < 2; y++)
		for(int z = 0; z < 2; z++)
			m.set(x, y, z, Cell(WATER, 8));
		for(int x = 2; x < 20; x++)
			m.set(x, 0, 0, Cell(AIR));
		Hazards h = bind(m);
		h.touch(2, 0, 0);
		run(h, 100);
		assert(m.sum(WATER) == 64);
		int far = 0;
		for(int x = 2; x < 20; x++)
			far = m.get(x, 0, 0).kind == WATER ? x : far;
		assert(far >= 8);
		printf("hazards: 64 eighths kept, spread to x %d, %zu steps\n", far,
				h.stepped);
	}
	// 2. Gas: 255 beside air -> 127 and 127, then 63s; under 8 is air
	{
		Map m;
		m.set(0, 0, 0, Cell(POISON, 255));
		m.set(1, 0, 0, Cell(AIR));
		Hazards h = bind(m);
		h.touch(0, 0, 0);
		while(m.get(1, 0, 0).kind == AIR)
			h.step(h.now + 0.1);
		assert(m.get(0, 0, 0).amount == 127 && m.get(1, 0, 0).amount == 127);
		m.set(0, 0, 0, Cell(POISON, 7));
		m.set(1, 0, 0, Cell(SOLID));
		h.wake(0, 0, 0);
		for(int i = 0; i < 20 && m.get(0, 0, 0).kind != AIR; i++)
			h.step(h.now + 0.5);
		assert(m.get(0, 0, 0).kind == AIR);
		printf("hazards: gas 255 -> 127 + 127; a share of 7 is air\n");
	}
	// 3. Lava's volcanic gas: its chance a step over 10^6 steps
	{
		Map m;
		m.set(0, 0, 0, Cell(LAVA, 8));
		m.set(0, 1, 0, Cell(AIR));
		Hazards h = bind(m);
		int made = 0;
		const int N = 1000000;
		for(int i = 0; i < N; i++){
			h.step_cell(0, 0, 0);
			if(m.get(0, 1, 0).kind == VOLCANIC){
				made++;
				m.set(0, 1, 0, Cell(AIR));
			}
			h.active.clear();
			h.due = decltype(h.due)();
		}
		// One of the six sides is the air: 1 in 600 * 6
		const double want = (double)N / LAVA_GAS_ONE_IN / 6;
		assert(made > want * 0.9 && made < want * 1.1);
		printf("hazards: lava's gas %d in 10^6 steps (%.0f wanted)\n", made, want);
	}
	// 4. The pressure: a pocket 3 wide breached at its foot (one cell at
	// y 0) into a tunnel 2 long and 12 high: 4 high, the tunnel filled
	// over the breach (2 full within 4 of it); 10 high, no more than 4
	// over the breach; the sum the same
	for(int high : {4, 10}){
		Map m;
		for(int x = 0; x < 3; x++) for(int y = 0; y < high; y++)
			m.set(x, y, 0, Cell(WATER, 8));
		m.set(3, 0, 0, Cell(AIR));
		for(int x = 4; x < 6; x++) for(int y = 0; y < 12; y++)
			m.set(x, y, 0, Cell(AIR));
		const int before = m.sum(WATER);
		Hazards h = bind(m);
		h.touch(3, 0, 0);
		run(h, 300);
		assert(m.sum(WATER) == before);
		int high_at = 0, full = 0;
		for(int y = 0; y < 12; y++){
			if(m.get(5, y, 0).kind == WATER)
				high_at = y + 1;
			if(m.get(5, y, 0).kind == WATER && m.get(5, y, 0).amount == 8)
				full = y + 1;
		}
		printf("hazards: a pocket %d high breached at its foot: the tunnel's "
				"water %d high (%d full) 2 along, %zu cells active\n", high,
				high_at, full, h.active.size());
		if(high == 4)
			assert(full >= 2);
		else
			assert(high_at <= 1 + PRESSURE_MAX);
	}
	printf("hazards: self test passed\n");
	return 0;
}
#else
}
}
#endif
// vim: set noet ts=4 sw=4:
