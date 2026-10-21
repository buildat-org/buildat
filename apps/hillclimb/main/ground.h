// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// The ground of hillclimb ([HILLCLIMB] 4): the hill's voxels as the
// tyres stand on them, and how they give. A game model -- plausible ruts,
// wheelspin and loose stones -- not a soil simulation. No engine types;
// main.cpp writes what changed into voxelworld and makes the stones that
// come loose bodies. The self test is -DGROUND_TEST.
//
// [HC_SAND_VOLUME] Sand is moved by volume: each sand voxel holds 1-8
// eighths (8 as the hill is made), a column's top voxel partly full.
// The tyres ride the fill (car.h's contact lowers a voxel by what it
// lacks); voxelworld draws a sand voxel while it is at least half full.
// simplified: drawn and driven differ by up to half a voxel; sand drawn
// at eight heights is the plan's B, if the look asks for it.
// Sand, under each tyre each substep:
// - **it gives under load**: the tyre's pressure on its patch over the
//   sand's bearing sinks the tyre, eighths at a time from the column
//   under the hub to a berm beside the tyre;
// - **a slipping tyre digs**: in proportion to how far the tread slides,
//   eighths off the highest sand under the patch are thrown along the
//   slide, landing spread over the 2x2 columns behind the tyre;
// - **it settles**: a column over its lowest neighbour by more than a
//   voxel (steeper than about 45 degrees; the hill's own slope is never
//   that), or over its neighbours' mean by more than half a voxel (a lone
//   lump), gives half the difference to the lowest, a few moves at most.
// [HC_WET_SAND] Under the loose top, wet packed sand: a tyre on it sinks
// by its own bearing (the cars' do not), digs it at a third of the rate,
// and what it digs is broken up: it lands as loose sand, and a wet voxel
// dug part away is loose sand once anything lands on it. A wet column
// settles only over its lowest neighbour by more than 4 voxels, so a
// rut's walls of it stand.
// Stones (hill.h's pebbles, a few voxels each, and [HC_STONE_KICK] the
// ones that came loose and rested, which the ground keeps a table of):
// one lying on the ground (touching sand at its sides by two faces or
// fewer) in a tyre's path is kicked loose by the push over its sliding
// friction; one in the sand comes out only under a slipping tyre, when
// its front along the push is open and the push beats its bed (user,
// 2026-10-20: the ones in the sand are not to plop out as you drive). Its voxels leave the grid
// as a Loose for main.cpp to make a body of.
#pragma once
#include "hill.h"
#include "car.h"
#include <vector>
#include <algorithm>
#include <unordered_map>
#include <cmath>

namespace ground {

using hill::Voxel;
using car::V3;

// The hill's voxels, made once per hill: what the generator hands
// voxelworld and what the tyres stand on. Outside the hill's box the
// ground is flat at the bottom pad's level, as the client draws it.
struct Grid: public car::Ground
{
	int sx, sy, sz;
	std::vector<uint8_t> v;
	std::vector<uint8_t> f;    // [HC_SAND_VOLUME] each voxel's eighths
	std::vector<int16_t> tops; // each column's highest solid y, -1 if none
	Grid(const hill::Hill &h):
		sx(h.size_x()), sy(h.size_y()), sz(h.size_z()),
		v((size_t)sx * sy * sz), f(v.size(), 0), tops((size_t)sx * sz, -1)
	{
		for(int z = 0; z < sz; z++)
		for(int y = 0; y < sy; y++)
		for(int x = 0; x < sx; x++){
			Voxel t = h.at(x, y, z);
			v[((size_t)z * sy + y) * sx + x] = t;
			if(t != hill::AIR){
				f[((size_t)z * sy + y) * sx + x] = 8;
				tops[(size_t)z * sx + x] = y;
			}
		}
	}
	int fill(int x, int y, int z) const
	{
		return inside(x, y, z) ? f[((size_t)z * sy + y) * sx + x] :
				solid(x, y, z) ? 8 : 0;
	}
	// What voxelworld draws: a sand voxel under half full is air
	Voxel drawn(int x, int y, int z) const
	{
		Voxel t = at(x, y, z);
		return (t == hill::SAND || t == hill::WET) && fill(x, y, z) < 4 ?
				hill::AIR : t;
	}
	// car.h's: how far a voxel's sphere is lowered by what it lacks
	float drop(int x, int y, int z) const override
	{
		return (8 - fill(x, y, z)) / 8.0f;
	}
	// A column's height in eighths over y 0's bottom: its top voxel's
	// fill counted
	int height8(int x, int z) const
	{
		const int t = top(x, z);
		return t < 0 ? 0 : t * 8 + fill(x, t, z);
	}
	bool inside(int x, int y, int z) const
	{
		return x >= 0 && y >= 0 && z >= 0 && x < sx && y < sy && z < sz;
	}
	Voxel at(int x, int y, int z) const
	{
		return inside(x, y, z) ? (Voxel)v[((size_t)z * sy + y) * sx + x] :
				hill::AIR;
	}
	bool solid(int x, int y, int z) const
	{
		return inside(x, y, z) ? at(x, y, z) != hill::AIR :
				y <= hill::Hill::BASE;
	}
	int top(int x, int z) const
	{
		return inside(x, 0, z) ? tops[(size_t)z * sx + x] : -1;
	}
	void set(int x, int y, int z, Voxel t)
	{
		if(!inside(x, y, z))
			return;
		v[((size_t)z * sy + y) * sx + x] = t;
		f[((size_t)z * sy + y) * sx + x] = t == hill::AIR ? 0 : 8;
		int16_t &top = tops[(size_t)z * sx + x];
		if(t != hill::AIR && y > top)
			top = y;
		if(t == hill::AIR && y == top){
			while(top >= 0 && at(x, top, z) == hill::AIR)
				top--;
		}
	}
};

// The sand's and the stones' numbers, tuned by driving; [HC_SOFT_DEFAULTS]
// the user's playtested set (main.cpp's knobs; 80 kPa, dig 2, a bed's mu
// 0.6 at 35% open before)
struct Soil
{
	float bearing = 30000;  // Pa: a 2 t car's tyres at about 65 kPa sink
	float sink_rate = 3;    // voxels a second at twice the bearing
	float dig_rate = 6;     // voxels per metre the tread slides
	float throw_m = 0.5f;   // past the tyre, where the dug sand lands
	float stone_kg = 5.1f;  // a voxel of stone, 2600 kg/m^3
	float mu_bed = 0.6f * 0.20f / 0.35f; // a stone on its bed
	float open_front = 0.20f; // of a stone's voxels, free along the push
	// [HC_WET_SAND] The wet sand's: its bearing, its digging's share of
	// the loose sand's, and the drop it stands to, eighths
	float wet_bearing = 150000;
	float wet_dig = 1 / 3.0f;
	int wet_drop8 = 4 * 8;
};

struct Change { int x, y, z; Voxel v; };

// A stone come loose, its voxels already out of the grid: where it is
// (voxels), how big and heavy, and how fast the tyre sends it (m/s)
struct Loose
{
	V3 centre;
	float radius = 1, kg = 0;
	V3 velocity;
	int voxels = 0;
	int tyre = -1;    // [HC_STONE_KICK] the tyre that kicked it, or dug
	float push = 0;   // N, what freed it
};

struct Ground
{
	Grid &g;
	const hill::Hill &h;
	Soil soil;
	struct Wheel { float sink = 0, dig = 0; int side = 1; } wheels[4];
	std::vector<Change> changes; // for voxelworld, main.cpp takes them
	std::vector<Loose> loose;    // for Bullet, main.cpp takes them
	// For the log: eighths dug, sunk and slid ([HC_SAND_VOLUME]), stones freed
	int dug = 0, sunk = 0, slid = 0, freed = 0;
	static const int SETTLE_BUDGET = 48;
	// What each changed voxel was when the hill was made, for restore():
	// its type, and its fill over 8 bits
	std::unordered_map<size_t, uint16_t> undo;
	// [HC_STONE_KICK] The stones that came loose and rested: each one's
	// voxels and radius, and which one a voxel is of (hill.h's pebble_of
	// knows the generated ones only)
	struct Stone { float r; std::vector<size_t> vox; };
	std::unordered_map<int, Stone> stones;
	std::unordered_map<size_t, int> stone_at;
	int next_stone = 1;
	size_t idx(int x, int y, int z) const
	{
		return ((size_t)z * g.sy + y) * g.sx + x;
	}

	Ground(Grid &grid, const hill::Hill &hill): g(grid), h(hill){}

	void set(int x, int y, int z, Voxel t)
	{
		if(!g.inside(x, y, z) || (g.at(x, y, z) == t &&
				g.fill(x, y, z) == (t == hill::AIR ? 0 : 8)))
			return;
		const Voxel was = g.drawn(x, y, z);
		keep_undo(x, y, z);
		g.set(x, y, z, t);
		if(was != t)
			changes.push_back(Change{x, y, z, t});
	}
	void keep_undo(int x, int y, int z)
	{
		undo.insert({idx(x, y, z), (uint16_t)(g.at(x, y, z) |
				g.fill(x, y, z) << 8)});
	}
	// [HC_SAND_VOLUME] A sand voxel's eighths, 0 its air; voxelworld
	// told when it crosses half. [HC_WET_SAND] A wet one stays wet
	void set_fill(int x, int y, int z, int n)
	{
		const Voxel cur = g.at(x, y, z);
		if(!g.inside(x, y, z) || (n > 0 && cur != hill::SAND &&
				cur != hill::WET && cur != hill::AIR))
			return;
		const Voxel was = g.drawn(x, y, z);
		keep_undo(x, y, z);
		g.set(x, y, z, n > 0 ? (cur == hill::WET ? hill::WET : hill::SAND) :
				hill::AIR);
		g.f[idx(x, y, z)] = (uint8_t)n;
		const Voxel now = g.drawn(x, y, z);
		if(now != was)
			changes.push_back(Change{x, y, z, now});
	}
	// Up to n eighths off a column's top sand, [HC_WET_SAND] the wet too
	// when `wet` (a dig, a wet wall's settling); what was taken
	int take(int x, int z, int n, bool wet = false)
	{
		int taken = 0;
		while(taken < n){
			const int t = g.top(x, z);
			if(t < 0 || !(g.at(x, t, z) == hill::SAND ||
					(wet && g.at(x, t, z) == hill::WET)))
				break;
			const int f = g.fill(x, t, z), k = std::min(f, n - taken);
			set_fill(x, t, z, f - k);
			taken += k;
		}
		return taken;
	}
	// Up to n eighths onto a column: its partly full top voxel first, then
	// new ones over it; what was put
	int put(int x, int z, int n)
	{
		int done = 0;
		while(done < n && g.inside(x, 0, z)){
			const int t = g.top(x, z);
			// [HC_WET_SAND] A wet voxel dug part away, broken up by what lands
			if(t >= 0 && g.at(x, t, z) == hill::WET && g.fill(x, t, z) < 8){
				const int f = g.fill(x, t, z);
				set_fill(x, t, z, 0);
				set_fill(x, t, z, f);
			}
			if(t >= 0 && g.at(x, t, z) == hill::SAND && g.fill(x, t, z) < 8){
				const int f = g.fill(x, t, z), k = std::min(8 - f, n - done);
				set_fill(x, t, z, f + k);
				done += k;
			} else if(t + 1 < g.sy){
				const int k = std::min(8, n - done);
				set_fill(x, t + 1, z, k);
				done += k;
			} else {
				break;
			}
		}
		return done;
	}
	// n eighths from one column to another; what moved (none lost: what
	// the other cannot take goes back)
	int move(int x, int z, int tx, int tz, int n, bool wet = false)
	{
		if(!g.inside(tx, 0, tz))
			return 0;
		const int taken = take(x, z, n, wet), done = put(tx, tz, taken);
		if(done < taken)
			put(x, z, taken - done);
		return done;
	}

	// Sand settles from (x, z) and its neighbours, a few moves at most: a
	// column over its lowest neighbour by more than a voxel, or over its
	// neighbours' mean by more than half (a lone lump; a stair of the hill
	// as made is level with its mean), gives half the difference
	void settle(int x, int z)
	{
		static const int D[4][2] = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}};
		int budget = SETTLE_BUDGET;
		std::vector<std::pair<int, int>> todo{{x, z}};
		for(auto &d : D)
			todo.push_back({x + d[0], z + d[1]});
		while(!todo.empty() && budget > 0){
			auto c = todo.back();
			todo.pop_back();
			if(g.top(c.first, c.second) < 0)
				continue;
			const int h8 = g.height8(c.first, c.second);
			int best = -1, low = 1 << 30, sum = 0, n = 0;
			for(int i = 0; i < 4; i++){
				const int nx = c.first + D[i][0], nz = c.second + D[i][1];
				if(!g.inside(nx, 0, nz))
					continue;
				const int nh = g.height8(nx, nz);
				sum += nh;
				n++;
				if(nh < low){
					low = nh;
					best = i;
				}
			}
			const int t = g.top(c.first, c.second);
			const bool wet = g.at(c.first, t, c.second) == hill::WET;
			if(best < 0 || (wet ? h8 - low <= soil.wet_drop8 :
					!(h8 - low > 8 || h8 * n - sum > 4 * n)))
				continue;
			int nx = c.first + D[best][0], nz = c.second + D[best][1];
			const int moved = move(c.first, c.second, nx, nz,
					std::max(1, (h8 - low) / 2), wet);
			if(moved == 0)
				continue;
			budget--;
			slid += moved;
			todo.push_back({nx, nz});
			todo.push_back(c);
			for(auto &d : D)
				todo.push_back({c.first + d[0], c.second + d[1]});
		}
	}

	// The columns under a tyre's patch: across it its width, along it the
	// patch's length, about the contact point (all in voxels)
	std::vector<std::pair<int, int>> patch(const V3 &at, const V3 &axle,
			float half_w, float half_l) const
	{
		std::vector<std::pair<int, int>> cols;
		V3 a = V3(axle.x, 0, axle.z).normalized();
		V3 f = V3(-a.z, 0, a.x);
		int r = (int)std::ceil(std::fmax(half_w, half_l)) + 1;
		int cx = (int)std::lround(at.x), cz = (int)std::lround(at.z);
		for(int z = cz - r; z <= cz + r; z++)
		for(int x = cx - r; x <= cx + r; x++){
			V3 d((float)x - at.x, 0, (float)z - at.z);
			if(std::fabs(d.dot(a)) <= half_w + 0.5f &&
					std::fabs(d.dot(f)) <= half_l + 0.5f)
				cols.push_back({x, z});
		}
		return cols;
	}

	// The stone a STONE voxel is of: its voxels and radius, and the rested
	// one's id (0 for a generated one)
	bool stone_of(int x, int y, int z, std::vector<Change> &stone, V3 &centre,
			float &r, int &id) const
	{
		stone.clear();
		if(g.at(x, y, z) != hill::STONE)
			return false;
		auto it = stone_at.find(idx(x, y, z));
		if(it != stone_at.end()){
			id = it->second;
			const Stone &st = stones.at(id);
			r = st.r;
			V3 sum;
			for(size_t i : st.vox){
				int px = (int)(i % g.sx), py = (int)(i / g.sx % g.sy),
						pz = (int)(i / g.sx / g.sy);
				stone.push_back(Change{px, py, pz, hill::STONE});
				sum = sum + V3((float)px, (float)py, (float)pz);
			}
			centre = sum * (1.0f / stone.size());
			return true;
		}
		id = 0;
		float cx, cy, cz;
		if(!h.pebble_of(x, y, z, cx, cy, cz, r))
			return false;
		centre = V3(cx, cy, cz);
		int R = (int)std::ceil(r) + 1;
		for(int k = -R; k <= R; k++)
		for(int j = -R; j <= R; j++)
		for(int i = -R; i <= R; i++){
			int px = (int)std::lround(cx) + i, py = (int)std::lround(cy) + j,
					pz = (int)std::lround(cz) + k;
			float a, b, c, rr;
			if(g.at(px, py, pz) == hill::STONE &&
					!stone_at.count(idx(px, py, pz)) &&
					h.pebble_of(px, py, pz, a, b, c, rr) &&
					a == cx && b == cy && c == cz)
				stone.push_back(Change{px, py, pz, hill::STONE});
		}
		return !stone.empty();
	}

	// [HC_STONE_KICK] How many of a stone's faces beside it touch solid
	// ground that is not the stone: two or fewer, it lies on the ground
	// rather than in it
	int contact(const std::vector<Change> &stone) const
	{
		static const int D[4][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 0, 1},
				{0, 0, -1}};
		int n = 0;
		for(const Change &s : stone)
			for(auto &d : D){
				int x = s.x + d[0], y = s.y + d[1], z = s.z + d[2];
				bool own = false;
				for(const Change &o : stone)
					own = own || (o.x == x && o.y == y && o.z == z);
				n += !own && g.solid(x, y, z);
			}
		return n;
	}

	// A stone at (x, y, z) pushed with `push` N along `dir`: loose if what
	// holds it gives -- lying on the ground, its sliding friction; in it,
	// its front open and its bed's friction, and never by a `kick`
	bool loosen(int x, int y, int z, const V3 &dir, float push,
			bool kick = false)
	{
		std::vector<Change> stone;
		V3 c;
		float r;
		int id;
		if(!stone_of(x, y, z, stone, c, r, id))
			return false;
		float kg = soil.stone_kg * stone.size();
		// simplified: lying loose, all its weight on the ground it slides on
		if(contact(stone) <= 2){
			if(push < soil.mu_bed * kg * 9.81f)
				return false;
		} else if(kick){
			return false;
		} else {
			// Open along the push: the voxel past each one is air or the stone
			int sx = std::fabs(dir.x) > std::fabs(dir.z) ? (dir.x > 0 ? 1 : -1) : 0;
			int sz = sx == 0 ? (dir.z > 0 ? 1 : -1) : 0;
			int open = 0;
			for(const Change &s : stone){
				Voxel past = g.at(s.x + sx, s.y, s.z + sz);
				open += past == hill::AIR || past == hill::STONE;
			}
			if(open < soil.open_front * stone.size() ||
					push < soil.mu_bed * kg * 9.81f)
				return false;
		}
		for(const Change &s : stone){
			set(s.x, s.y, s.z, hill::AIR);
			stone_at.erase(idx(s.x, s.y, s.z));
		}
		stones.erase(id);
		Loose l;
		l.centre = c;
		l.push = push;
		l.radius = r;
		l.kg = kg;
		l.voxels = (int)stone.size();
		loose.push_back(l);
		freed++;
		return true;
	}

	// One tyre, one substep (car.h's wheel after Car::step)
	void wheel(int i, const car::Wheel &w, const car::Spec &spec, float u,
			float dt)
	{
		if(w.load <= 0)
			return;
		Wheel &s = wheels[i];
		// The patch: the tyre's own deflection makes its length
		float defl = w.load / spec.k_tyre;
		float len = 2 * std::sqrt(2 * spec.tyre_r * defl);
		float pressure = w.load / (spec.tyre_w * std::fmax(len, 0.05f));
		V3 at = w.at * u;
		// [HC_WET_SAND] Wet sand under the hub: its bearing and digging
		const int hx = (int)std::lround(at.x), hz = (int)std::lround(at.z);
		const bool wet = g.at(hx, g.top(hx, hz), hz) == hill::WET;
		s.sink += std::fmax(0, pressure / (wet ? soil.wet_bearing :
				soil.bearing) - 1) * soil.sink_rate * dt;
		float speed = w.slide.length();
		if(w.slipping)
			s.dig += speed * dt * soil.dig_rate * (wet ? soil.wet_dig : 1);
		// [HC_STONE_KICK] A stone lying on the ground the tyre is on, from
		// its patch's back to its front: kicked along its travel with the
		// tyre's grip, slipping or not; one try a substep
		V3 hv(w.vel.x, 0, w.vel.z);
		const float tv = hv.length();
		if(tv > 0.3f){
			const V3 dir = hv * (1 / tv);
			const float back = len / 2 * u, front = spec.tyre_r * u;
			const int y0 = (int)std::floor(at.y) + 1,
					y1 = (int)std::floor(at.y + spec.tyre_r * u);
			bool tried = false;
			for(auto &c : patch(at + dir * ((front - back) / 2), w.axle,
					spec.tyre_w * u / 2, (front + back) / 2)){
				for(int y = y0; y <= y1 && !tried; y++){
					if(g.at(c.first, y, c.second) != hill::STONE)
						continue;
					tried = true;
					if(loosen(c.first, y, c.second, dir, spec.mu * w.load,
							true)){
						loose.back().velocity = dir * tv;
						loose.back().tyre = i;
					}
				}
				if(tried)
					break;
			}
		}
		// In eighths, a voxel's worth of each in a substep at most
		const int sink8 = std::min(8, (int)(s.sink * 8));
		if(sink8 >= 1){
			s.sink -= sink8 / 8.0f;
			int cx = (int)std::lround(at.x), cz = (int)std::lround(at.z);
			V3 a = V3(w.axle.x, 0, w.axle.z).normalized() *
					(s.side * (spec.tyre_w * u / 2 + 1.5f));
			s.side = -s.side;
			int tx = (int)std::lround(at.x + a.x), tz = (int)std::lround(at.z + a.z);
			if(const int m = move(cx, cz, tx, tz, sink8)){
				sunk += m;
				settle(cx, cz);
				settle(tx, tz);
			}
		}
		const int dig8 = std::min(8, (int)(s.dig * 8));
		if(dig8 >= 1 && speed > 1e-3f){
			s.dig -= dig8 / 8.0f;
			V3 dir = w.slide * (1 / speed);
			auto cols = patch(at, w.axle, spec.tyre_w * u / 2, len * u / 2);
			// The highest stone under the patch tried first; held, the sand
			// beside it is dug instead, which bares it further
			int bx = 0, bz = 0, by = -1, kx = 0, kz = 0, ky = -1;
			for(auto &c : cols){
				int t = g.top(c.first, c.second);
				Voxel v = g.at(c.first, t, c.second);
				if((v == hill::SAND || v == hill::WET) &&
						g.height8(c.first, c.second) > by){
					by = g.height8(c.first, c.second);
					bx = c.first;
					bz = c.second;
				}
				if(v == hill::STONE && t > ky){
					ky = t;
					kx = c.first;
					kz = c.second;
				}
			}
			if(ky >= 0 && ky * 8 + 8 >= by){
				// The tyre's grip, half of it on the stone
				if(loosen(kx, ky, kz, dir, spec.mu * w.load / 2)){
					loose.back().velocity = w.slide;
					return;
				}
			}
			if(by < 0)
				return;
			// Thrown and spread over the 2x2 columns about where it lands,
			// each its share by how near
			float d = (spec.tyre_r + soil.throw_m) * u;
			const float lx = at.x + dir.x * d, lz = at.z + dir.z * d;
			const int x0 = (int)std::floor(lx), z0 = (int)std::floor(lz);
			const float fx = lx - x0, fz = lz - z0;
			const int taken = take(bx, bz, dig8, true);
			int left = taken;
			const float wt[4] = {(1 - fx) * (1 - fz), fx * (1 - fz),
					(1 - fx) * fz, fx * fz};
			for(int k = 0; k < 4 && left > 0; k++){
				const int share = k == 3 ? left : std::min(left,
						(int)std::lround(taken * wt[k]));
				left -= put(x0 + (k & 1), z0 + (k >> 1), share);
			}
			if(left > 0)
				put(bx, bz, left);
			if(taken > left){
				dug += taken - left;
				settle(bx, bz);
				for(int k = 0; k < 4; k++)
					settle(x0 + (k & 1), z0 + (k >> 1));
			}
		}
	}

	// The hill as it was made: every changed voxel back (a run's restart)
	void restore()
	{
		for(auto &u : undo){
			int x = (int)(u.first % g.sx), y = (int)(u.first / g.sx % g.sy),
					z = (int)(u.first / g.sx / g.sy);
			g.set(x, y, z, (Voxel)(u.second & 0xff));
			g.f[u.first] = (uint8_t)(u.second >> 8);
			changes.push_back(Change{x, y, z, g.drawn(x, y, z)});
		}
		undo.clear();
		loose.clear();
		stones.clear();
		stone_at.clear();
		dug = sunk = slid = freed = 0;
		for(Wheel &w : wheels)
			w = Wheel();
	}
	bool changed() const { return !undo.empty(); }

	// A stone that has come to rest, back into the grid: its `voxels` (a
	// whole sphere of its radius if 0), the air nearest where it lies --
	// [HC_STONE_KICK] as many as it had, not every air voxel in its
	// sphere -- and in the table, to come loose again; how many it was
	int rest(const V3 &centre, float radius, int voxels = 0)
	{
		std::vector<std::pair<float, size_t>> air;
		int R = (int)std::ceil(radius) + 2;
		for(int k = -R; k <= R; k++)
		for(int j = -R; j <= R; j++)
		for(int i = -R; i <= R; i++){
			int x = (int)std::lround(centre.x) + i, y = (int)std::lround(centre.y) + j,
					z = (int)std::lround(centre.z) + k;
			V3 d = V3((float)x, (float)y, (float)z) - centre;
			if(g.inside(x, y, z) && g.at(x, y, z) == hill::AIR &&
					(voxels > 0 || d.length() <= radius))
				air.push_back({d.length(), idx(x, y, z)});
		}
		std::sort(air.begin(), air.end());
		if(voxels > 0 && (int)air.size() > voxels)
			air.resize(voxels);
		Stone st;
		st.r = radius;
		for(auto &a : air){
			int x = (int)(a.second % g.sx), y = (int)(a.second / g.sx % g.sy),
					z = (int)(a.second / g.sx / g.sy);
			set(x, y, z, hill::STONE);
			st.vox.push_back(a.second);
			stone_at[a.second] = next_stone;
		}
		const int n = (int)st.vox.size();
		if(n > 0)
			stones[next_stone++] = st;
		return n;
	}
};

} // namespace ground

#ifdef GROUND_TEST
#include <cassert>
#include <cstdio>
int main()
{
	using namespace ground;
	hill::Params p;
	hill::Hill h(p);
	Grid g(h);
	Ground gr(g, h);
	car::Spec spec;
	const float U = hill::U;
	// The tops follow the writes
	int x = 40, z = 20, t = g.top(x, z);
	assert(t == hill::Hill::BASE);
	g.set(x, t, z, hill::AIR);
	assert(g.top(x, z) == t - 1);
	g.set(x, t, z, hill::SAND);
	assert(g.top(x, z) == t);
	// A tyre spinning in place on the bottom pad digs a rut under it and
	// throws the sand behind
	car::Wheel w;
	w.load = 5000;
	w.slipping = true;
	w.at = car::V3(x / U, (t + 0.5f) / U, z / U);
	w.axle = car::V3(1, 0, 0);
	w.slide = car::V3(0, 0, -1.2f); // the tread backwards, m/s
	// [HC_SAND_VOLUME] All the sand's eighths, before and after, the
	// wet's with it ([HC_WET_SAND])
	auto sand = [&](){
		long long n = 0;
		for(size_t i = 0; i < g.v.size(); i++)
			if(g.v[i] == hill::SAND || g.v[i] == hill::WET)
				n += g.f[i];
		return n;
	};
	const long long sand0 = sand();
	for(int i = 0; i < 240 * 10; i++)
		gr.wheel(0, w, spec, U, 1.0f / 240);
	assert(sand() == sand0);
	int under = g.top(x, z), behind = -1;
	for(int dz = 4; dz < 12; dz++)
		behind = std::max(behind, g.top(x, z - dz));
	printf("ground.h: 10 s of spin: %d dug, %d slid; under the tyre %d -> %d, "
			"behind it up to %d\n", gr.dug, gr.slid, t, under, behind);
	assert(gr.dug > 10);
	assert(under <= t - 2);
	assert(behind >= t + 1);
	// No sand over a drop of two or more after the settling, about the rut
	for(int zz = z - 15; zz <= z + 5; zz++)
	for(int xx = x - 6; xx <= x + 6; xx++){
		int a = g.top(xx, zz);
		if(g.at(xx, a, zz) != hill::SAND)
			continue;
		for(int d = -1; d <= 1; d += 2){
			assert(a - g.top(xx + d, zz) < 2);
			assert(a - g.top(xx, zz + d) < 2);
		}
	}
	// A loaded tyre at rest sinks: twice the bearing for a second
	Ground g2(g, h);
	car::Wheel s;
	s.at = car::V3(30 / U, (hill::Hill::BASE + 0.5f) / U, 30 / U);
	s.axle = car::V3(1, 0, 0);
	s.load = 4 * 9810; // 4 t on one tyre
	int before = g.height8(30, 30);
	for(int i = 0; i < 240; i++)
		g2.wheel(0, s, spec, U, 1.0f / 240);
	printf("ground.h: a heavy tyre at rest: %d eighths sunk, the column %d -> "
			"%d eighths\n", g2.sunk, before, g.height8(30, 30));
	assert(g2.sunk >= 16 && g.height8(30, 30) < before);
	// The first ground back as it was made
	gr.restore();
	assert(g.top(x, z) == t && gr.undo.empty());
	for(int zz = 0; zz <= z + 5; zz++)
		assert(g.top(x, zz) == hill::Hill::BASE);
	// A stone rests back as voxels
	Ground g3(g, h);
	g3.rest(car::V3(20, 40, 100), 1.3f);
	assert(g.at(20, 40, 100) == hill::STONE && !g3.changes.empty());
	// [HC_SOFT_GROUND] The knobs' ends (main.cpp's KNOBS): an empty 2 t
	// car's tyre at rest for 2 s sinks in sand of 20 kPa, not of 100; a
	// tyre sliding 1 m/s for 2 s digs 4 times as much at 8 as at 2 (steps
	// of 1/256 s, which add up exactly)
	auto at_rest = [&](float kpa, int cx){
		Ground gk(g, h);
		gk.soil.bearing = kpa * 1000;
		car::Wheel w;
		w.at = car::V3(cx / U, (hill::Hill::BASE + 0.5f) / U, 30 / U);
		w.axle = car::V3(1, 0, 0);
		w.load = 2000 * 9.81f / 4;
		for(int i = 0; i < 512; i++)
			gk.wheel(0, w, spec, U, 1.0f / 256);
		return gk.sunk;
	};
	const int soft = at_rest(20, 25), firm = at_rest(100, 55);
	auto sliding = [&](float rate, int cx){
		Ground gk(g, h);
		gk.soil.dig_rate = rate;
		car::Wheel w;
		w.at = car::V3(cx / U, (hill::Hill::BASE + 0.5f) / U, 40 / U);
		w.axle = car::V3(1, 0, 0);
		w.load = 2000 * 9.81f / 4;
		w.slipping = true;
		w.slide = car::V3(0, 0, -1);
		for(int i = 0; i < 512; i++)
			gk.wheel(0, w, spec, U, 1.0f / 256);
		return gk.dug;
	};
	const int dug2 = sliding(2, 25), dug8 = sliding(8, 55);
	printf("ground.h: at rest, %d sunk at 20 kPa, %d at 100; sliding, %d dug "
			"at 2, %d at 8\n", soft, firm, dug2, dug8);
	assert(soft >= 1 && firm == 0);
	assert(dug2 > 0 && dug8 == 4 * dug2);
	// [HC_STONE_KICK] A rested stone keeps its count and comes loose again
	{
		const int B = hill::Hill::BASE;
		Ground gs(g, h);
		const int n = gs.rest(car::V3(40.2f, B + 1.3f, 34), 1.2f, 6);
		assert(n == 6 && gs.stones.size() == 1);
		assert(gs.loosen(40, B + 1, 34, car::V3(1, 0, 0), 1e4f));
		assert(gs.loose.back().voxels == 6 && gs.stones.empty() &&
				gs.stone_at.empty() && g.at(40, B + 1, 34) == hill::AIR);
		// One touching by a face: its sliding friction frees it, less not
		gs.rest(car::V3(46, B + 1, 34), 0.5f, 1);
		const float slide = gs.soil.mu_bed * gs.soil.stone_kg * 9.81f;
		assert(!gs.loosen(46, B + 1, 34, car::V3(1, 0, 0), slide * 0.9f));
		assert(gs.loosen(46, B + 1, 34, car::V3(1, 0, 0), slide * 1.1f));
		// A bedded one as before: its front shut, no push frees it
		bool found = false;
		std::vector<Change> st;
		car::V3 c;
		float r;
		int id;
		for(int z = 20; z < 44 && !found; z++)
		for(int x = 10; x < 70 && !found; x++)
		for(int y = g.top(x, z) - 2; y > g.top(x, z) - 8 && !found; y--){
			if(!gs.stone_of(x, y, z, st, c, r, id) || gs.contact(st) <= 2)
				continue;
			int open = 0;
			for(const Change &v : st)
				open += g.at(v.x + 1, v.y, v.z) == hill::AIR ||
						g.at(v.x + 1, v.y, v.z) == hill::STONE;
			if(open >= gs.soil.open_front * st.size())
				continue;
			found = true;
			assert(!gs.loosen(x, y, z, car::V3(1, 0, 0), 1e9f));
			assert(!gs.loosen(x, y, z, car::V3(1, 0, 0), 1e9f, true));
		}
		assert(found);
		// A tyre rolling at 2 m/s, not slipping, kicks a stone lying ahead
		gs.rest(car::V3(66, B + 1.3f, 32), 1.2f, 6);
		car::Wheel w;
		w.at = car::V3(66 / U, (B + 0.5f) / U, 30 / U);
		w.axle = car::V3(1, 0, 0);
		w.load = 2000 * 9.81f / 4;
		w.vel = car::V3(0, 0, 2);
		const size_t before = gs.loose.size();
		gs.wheel(1, w, spec, U, 1.0f / 256);
		assert(gs.loose.size() == before + 1 && gs.loose.back().tyre == 1 &&
				gs.loose.back().voxels == 6 && gs.loose.back().velocity.z > 1.9f);
		gs.restore();
		printf("ground.h: a rested stone (6 voxels) loose again; one by a face "
				"at %.0f N; a bedded one held; one kicked by a rolling tyre\n",
				slide);
	}
	// [HC_WET_SAND] On a hill wet to the top: an empty 2 t car's tyre at
	// rest does not sink at the default bearing; sliding 1 m/s for 2 s it
	// digs a third of what it digs in loose sand, the dug sand lands
	// loose, none lost; a 3-voxel wall of wet sand stands, one of loose
	// sand does not
	{
		const int B = hill::Hill::BASE;
		hill::Params wp = p, lp = p;
		wp.loose = 0;
		lp.loose = hill::Hill::SHELL;
		hill::Hill wh(wp), lh(lp);
		Grid wg(wh), lg(lh);
		auto run = [&](Grid &gg, const hill::Hill &hh, bool slide){
			Ground gk(gg, hh);
			car::Wheel w;
			w.at = car::V3(25 / U, (B + 0.5f) / U, 40 / U);
			w.axle = car::V3(1, 0, 0);
			w.load = 2000 * 9.81f / 4;
			w.slipping = slide;
			w.slide = car::V3(0, 0, slide ? -1 : 0);
			for(int i = 0; i < 512; i++)
				gk.wheel(0, w, spec, U, 1.0f / 256);
			return slide ? gk.dug : gk.sunk;
		};
		assert(wg.at(25, B, 40) == hill::WET && lg.at(25, B, 40) == hill::SAND);
		auto vol = [](const Grid &gg, Voxel t){
			long long n = 0;
			for(size_t i = 0; i < gg.v.size(); i++)
				if(gg.v[i] == t)
					n += gg.f[i];
			return n;
		};
		const long long w0 = vol(wg, hill::WET) + vol(wg, hill::SAND);
		const long long dry0 = vol(wg, hill::SAND);
		const int wet_sunk = run(wg, wh, false), wet_dug = run(wg, wh, true);
		const int loose_dug = run(lg, lh, true);
		assert(wet_sunk == 0);
		assert(wet_dug > 0 && wet_dug * 2 < loose_dug &&
				wet_dug * 4 > loose_dug);
		assert(vol(wg, hill::WET) + vol(wg, hill::SAND) == w0 &&
				vol(wg, hill::SAND) == dry0 + wet_dug);
		// The walls: a column 3 voxels over its neighbours at x 60, settled
		auto wall = [&](Grid &gg, const hill::Hill &hh){
			Ground gk(gg, hh);
			const Voxel t = gg.at(60, B, 60);
			for(int y = B + 1; y <= B + 3; y++)
				gg.set(60, y, 60, t);
			gk.settle(60, 60);
			return gg.top(60, 60) - B;
		};
		const int wet_wall = wall(wg, wh), loose_wall = wall(lg, lh);
		printf("ground.h: wet sand: %d sunk at rest, %d dug against %d in "
				"loose; a 3-voxel wall %d high wet, %d loose\n", wet_sunk,
				wet_dug, loose_dug, wet_wall, loose_wall);
		assert(wet_wall == 3 && loose_wall < 3);
	}
	// [HC_SAND_VOLUME] A voxel's worth dropped on flat ground spreads: no
	// column left over its neighbours' mean by more than half a voxel
	{
		const int B = hill::Hill::BASE;
		Ground gl(g, h);
		const long long s0 = sand();
		assert(gl.put(70, 12, 8) == 8);
		gl.settle(70, 12);
		int worst = 0;
		for(int z = 8; z <= 16; z++)
		for(int x = 66; x <= 74; x++){
			const int m = (g.height8(x + 1, z) + g.height8(x - 1, z) +
					g.height8(x, z + 1) + g.height8(x, z - 1)) / 4;
			worst = std::max(worst, g.height8(x, z) - m);
		}
		printf("ground.h: a voxel's worth on the flat: %d eighths over its "
				"neighbours at most, %d slid\n", worst, gl.slid);
		assert(worst <= 4 && sand() == s0 + 8);
		gl.restore();
		assert(g.height8(70, 12) == (B + 1) * 8 && sand() == s0);
		// A tyre over a voxel 2/8 full rises a quarter voxel (3 cm), over a
		// full one a voxel
		const float R = spec.tyre_r * U;
		const car::V3 hub(70, B + 0.5f + R - 0.05f, 12), axle(1, 0, 0);
		car::V3 n;
		auto depth = [&](){
			return car::Car::contact(g, U, hub, axle, spec.tyre_r, spec.tyre_w, n);
		};
		const float d0 = depth();
		gl.set_fill(70, B + 1, 12, 2);
		const float d2 = depth();
		gl.set_fill(70, B + 1, 12, 8);
		const float d8 = depth();
		gl.restore();
		printf("ground.h: a tyre over a voxel 2/8 full %.1f cm higher, over a "
				"full one %.1f cm\n", (d2 - d0) * 100, (d8 - d0) * 100);
		assert(std::fabs(d2 - d0 - 0.25f / U) < 0.005f &&
				std::fabs(d8 - d0 - 1.0f / U) < 0.005f);
	}
	printf("ground.h: self test passed\n");
	return 0;
}
#endif
