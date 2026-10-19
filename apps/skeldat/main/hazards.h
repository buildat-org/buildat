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
// - A lava spring regains an eighth a step while under 8 (the binding
//   keeps a water spring full and a drain empty: [SKELDAT_OWN_MAPGEN]).
// - Lava beside water is stone; water under open sky (air over it at
//   the sky's light 15) loses an eighth, one step in evaporate_one_in
//   ([SKELDAT_OWN_MAPGEN]); lava beside air turns that air into volcanic gas, one step in
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
// The harm a second (WorldView::harm()): lava at the feet or the head
// LAVA_HARM; a gas at the head GAS_HARM at 255 (ceil by the share),
// volcanic one more
static const int LAVA_HARM = 4, GAS_HARM = 4;
// Water under open sky loses an eighth one step in EVAPORATE_ONE_IN
// (an active cell's: a pond at rest stays); the world's settling at its
// making is SETTLE_STEPS water steps with evaporation SETTLE_EVAPORATE
// times as fast ([SKELDAT_OWN_MAPGEN])
static const int EVAPORATE_ONE_IN = 2000, SETTLE_STEPS = 2000,
		SETTLE_EVAPORATE = 10;
// The settling stops after SETTLE_MS of the server's time as well (what
// still moves goes on in the game)
static const int SETTLE_MS = 5000;
// [SKELDAT_DISPLACE] A placed voxel's liquid or gas looks for room in at
// most DISPLACE_CAP voxels
static const size_t DISPLACE_CAP = 64;
// A lava pocket has a lava spring one in LAVA_SPRING_ONE_IN
static const int LAVA_SPRING_ONE_IN = 8;
// The pockets in the rock (terrain.h): water and poison gas from
// POCKET_DEPTH under the water level, lava from POCKET_LAVA_DEPTH; at most
// one a POCKET_CELL cube, its chance POCKET_CHANCE at POCKET_LAVA_DEPTH
// (about one in a 32 cube), more deeper, at most 0.9
static const int POCKET_DEPTH = 8, POCKET_LAVA_DEPTH = 24, POCKET_CELL = 32;
static const float POCKET_CHANCE = 1.0f;

enum Kind: uint8_t { AIR, SOLID, WATER, LAVA, POISON, VOLCANIC };
// amount: a liquid's eighths (1..8), a gas's share (1..255); sky: air's
// light from the sky, 0..15; spring: a lava or water spring's (read,
// never written: the binding keeps what the voxel is); drain: air that
// takes what is put in it and keeps none (the same); torch: a torch's
// voxel, air to a liquid (which puts it out: the binding's) and solid to
// a gas ([SKELDAT_WATER_TORCH])
struct Cell {
	uint8_t kind = SOLID;
	uint8_t amount = 0;
	uint8_t sky = 0;
	bool spring = false, drain = false, torch = false;
	Cell(){}
	Cell(uint8_t kind, uint8_t amount = 0, uint8_t sky = 0):
		kind(kind), amount(amount), sky(sky){}
};
inline bool liquid(uint8_t k){ return k == WATER || k == LAVA; }
inline bool gas(uint8_t k){ return k == POISON || k == VOLCANIC; }
// Air a gas goes into: not a torch's
inline bool open_air(const Cell &c){ return c.kind == AIR && !c.torch; }

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
	int evaporate_one_in = EVAPORATE_ONE_IN;
	std::unordered_set<uint64_t> active;
	typedef std::pair<double, uint64_t> Due;
	std::priority_queue<Due, std::vector<Due>, std::greater<Due>> due;
	double now = 0;
	size_t stepped = 0, gassed = 0;
	// [SKELDAT_DISPLACE] Eighths or shares that found no room, all told
	size_t lost = 0;

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

	// **[SKELDAT_DISPLACE] A placed voxel's liquid or gas, c, pushed aside**
	// from (x, y, z): out through the six neighbours, passing only through
	// the same kind (anything else, a drain and the world's edge stop it),
	// a distance at a time, a liquid's higher voxels of a distance first
	// (a displaced pond rises): the same kind with room takes what fits,
	// air the rest (a liquid 8 at most, a gas all of it) and is not
	// passed through; DISPLACE_CAP voxels looked at at most. What is left
	// is lost, counted in lost, and returned.
	// simplified: to the nearest room, not spread evenly; the step levels it
	int displace(int x, int y, int z, const Cell &c)
	{
		if(!liquid(c.kind) && !gas(c.kind))
			return 0;
		const int full = liquid(c.kind) ? 8 : 255;
		int left = c.amount;
		std::unordered_set<uint64_t> seen{key(x, y, z)};
		std::vector<uint64_t> ring, next;
		auto round = [&](int a, int b, int d){
			for(const auto &o : SIX)
				if(seen.insert(key(a + o[0], b + o[1], d + o[2])).second)
					next.push_back(key(a + o[0], b + o[1], d + o[2]));
		};
		round(x, y, z);
		size_t looked = 0;
		while(left > 0 && !next.empty() && looked < DISPLACE_CAP){
			ring.swap(next);
			next.clear();
			if(liquid(c.kind))
				std::stable_sort(ring.begin(), ring.end(), [](uint64_t a, uint64_t b){
					int ax, ay, az, bx, by, bz;
					unkey(a, ax, ay, az), unkey(b, bx, by, bz);
					return ay > by;
				});
			for(uint64_t k : ring){
				if(left == 0 || looked == DISPLACE_CAP)
					break;
				looked++;
				int a, b, d;
				unkey(k, a, b, d);
				Cell n = get(a, b, d);
				if(n.drain || (n.torch && gas(c.kind)))
					continue;
				if(n.kind == AIR){
					const int m = std::min(left, full);
					put(a, b, d, Cell(c.kind, (uint8_t)m));
					left -= m;
				} else if(n.kind == c.kind){
					const int m = std::min(left, full - n.amount);
					if(m > 0){
						n.amount = (uint8_t)(n.amount + m);
						put(a, b, d, n);
						left -= m;
					}
					round(a, b, d);
				}
			}
		}
		lost += left;
		return left;
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
		// A water spring pushes from itself alone: the river under it does
		// not feel its height ([SKELDAT_LOW_BANKS], low pressure)
		auto add = [&](int a, int b, int c, int via){
			const Cell n = get(a, b, c);
			if(n.kind != k || n.amount != 8 || (n.spring && k == WATER &&
					!(a == x && b == y && c == z)))
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
		// A lava spring ([SKELDAT_OWN_MAPGEN]) regains an eighth a step of
		// its own: only what moved out of it (a water spring is the
		// binding's: always full)
		if(c.spring && c.amount < 8){
			c.amount++;
			put(x, y, z, c);
			step_liquid(x, y, z, c);
			return true;
		}
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
		// Lava beside water is stone
		if(k == LAVA)
			for(const auto &d : SIX)
				if(get(x + d[0], y + d[1], z + d[2]).kind == WATER){
					put(x, y, z, Cell(SOLID));
					return false;
				}
		// Water under open sky evaporates
		if(k == WATER){
			const Cell over = get(x, y + 1, z);
			if(over.kind == AIR && over.sky >= 15 &&
					(int)(rng() % (uint32_t)evaporate_one_in) == 0){
				c.amount--;
				put(x, y, z, c.amount ? c : Cell(AIR));
				if(!c.amount)
					return false;
				moved = true;
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
				air = air || open_air(get(x + d[0], y + d[1], z + d[2]));
			if(air && (int)(rng() % LAVA_GAS_ONE_IN) == 0){
				const auto &d = SIX[rng() % 6];
				if(open_air(get(x + d[0], y + d[1], z + d[2]))){
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
		if(open_air(n)){
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
			if(open_air(o) || (o.kind == c.kind && o.amount != c.amount))
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
	// Evaporation: under the sky's 15 a woken cell loses its eighths; under
	// less it keeps them
	{
		Map m;
		m.set(0, 0, 0, Cell(WATER, 8));
		m.set(0, 1, 0, Cell(AIR, 0, 15));
		m.set(3, 0, 0, Cell(WATER, 8));
		m.set(3, 1, 0, Cell(AIR, 0, 14));
		Hazards h = bind(m);
		h.evaporate_one_in = 1;
		for(int i = 0; i < 20; i++){
			h.wake(0, 0, 0), h.wake(3, 0, 0);
			h.step(h.now + 1);
		}
		assert(m.get(0, 0, 0).kind == AIR && m.get(3, 0, 0).amount == 8);
		printf("hazards: evaporation under the open sky only\n");
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
	// 5. [SKELDAT_DISPLACE] A basin 3x3 inside, 2 deep, the bottom full,
	// the top half: a bottom voxel stone, its 8 in the rest
	{
		Map m;
		for(int x = 0; x < 3; x++) for(int z = 0; z < 3; z++){
			m.set(x, 0, z, Cell(WATER, 8));
			m.set(x, 1, z, Cell(WATER, 4));
			for(int y = 2; y < 4; y++)
				m.set(x, y, z, Cell(AIR));
		}
		const int before = m.sum(WATER);
		Hazards h = bind(m);
		const Cell c = m.get(1, 0, 1);
		m.set(1, 0, 1, Cell(SOLID));
		assert(h.displace(1, 0, 1, c) == 0 && m.sum(WATER) == before);
		// A full sealed 3x3x3 but for an air voxel at its top: the air
		// takes it
		Map s;
		for(int x = 0; x < 3; x++) for(int y = 0; y < 3; y++)
		for(int z = 0; z < 3; z++)
			s.set(x, y, z, Cell(WATER, 8));
		s.set(1, 2, 1, Cell(AIR));
		Hazards hs = bind(s);
		s.set(1, 0, 1, Cell(SOLID));
		assert(hs.displace(1, 0, 1, Cell(WATER, 8)) == 0 &&
				s.get(1, 2, 1).kind == WATER && s.get(1, 2, 1).amount == 8);
		// 128 of poison in a room of air: 128 in a neighbour
		Map g;
		for(int x = 0; x < 3; x++) for(int y = 0; y < 3; y++)
		for(int z = 0; z < 3; z++)
			g.set(x, y, z, Cell(AIR));
		g.set(1, 1, 1, Cell(SOLID));
		Hazards hg = bind(g);
		assert(hg.displace(1, 1, 1, Cell(POISON, 128)) == 0 && g.sum(POISON) == 128);
		// A full sealed pocket of 27: the middle's 8 lost and counted
		s.set(1, 2, 1, Cell(WATER, 8));
		s.set(1, 0, 1, Cell(WATER, 8));
		s.set(1, 1, 1, Cell(SOLID));
		assert(hs.displace(1, 1, 1, Cell(WATER, 8)) == 8 && hs.lost == 8 &&
				s.sum(WATER) == 26 * 8);
		// A drain stops it and takes nothing
		Map dr;
		dr.set(0, 0, 0, Cell(WATER, 8));
		Cell drain(AIR);
		drain.drain = true;
		dr.set(1, 0, 0, drain);
		Hazards hd = bind(dr);
		dr.set(0, 0, 0, Cell(SOLID));
		assert(hd.displace(0, 0, 0, Cell(WATER, 8)) == 8);
		// [SKELDAT_WATER_TORCH] Water flows into a torch beside it; poison
		// beside one does not
		Map tm;
		tm.set(0, 0, 0, Cell(WATER, 8));
		tm.set(0, 0, 5, Cell(POISON, 255));
		Cell torch(AIR);
		torch.torch = true;
		tm.set(1, 0, 0, torch);
		tm.set(1, 0, 5, torch);
		Hazards ht = bind(tm);
		ht.touch(0, 0, 0), ht.touch(0, 0, 5);
		run(ht, 20);
		assert(tm.get(1, 0, 0).kind == WATER && tm.get(1, 0, 5).torch &&
				tm.sum(POISON) == 255);
		printf("hazards: displaced: a pond's sum kept, a sealed box's air "
				"filled, a gas into air, a full pocket's 8 lost, a drain no room; "
				"water into a torch, poison not\n");
	}
	printf("hazards: self test passed\n");
	return 0;
}
#else
}
}
#endif
// vim: set noet ts=4 sw=4:
