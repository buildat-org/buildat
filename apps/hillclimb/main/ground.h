// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// The ground of hillclimb ([HILLCLIMB] 4): the hill's voxels as the
// tyres stand on them, and how they give. A game model -- plausible ruts,
// wheelspin and loose stones -- not a soil simulation. No engine types;
// main.cpp writes what changed into voxelworld and makes the stones that
// come loose bodies. The self test is -DGROUND_TEST.
//
// Sand, under each tyre each substep:
// - **it gives under load**: the tyre's pressure on its patch over the
//   sand's bearing sinks the tyre, a voxel at a time from the column
//   under the hub to a berm beside the tyre;
// - **a slipping tyre digs**: in proportion to how far the tread slides,
//   the highest sand under the patch is thrown along the slide, landing
//   behind the tyre;
// - **it settles**: a sand voxel over a drop of two voxels or more slides
//   down it (steeper than about 60 degrees on the grid; the hill's own
//   slope is never that), each move a few columns at most.
// Stones (hill.h's pebbles, a few voxels each): one under a slipping tyre
// comes loose whole when its front along the slide is open and the
// tyre's share of the push beats its friction on its bed; its voxels
// leave the grid as a Loose for main.cpp to make a body of.
#pragma once
#include "hill.h"
#include "car.h"
#include <vector>
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
	std::vector<int16_t> tops; // each column's highest solid y, -1 if none
	Grid(const hill::Hill &h):
		sx(h.size_x()), sy(h.size_y()), sz(h.size_z()),
		v((size_t)sx * sy * sz), tops((size_t)sx * sz, -1)
	{
		for(int z = 0; z < sz; z++)
		for(int y = 0; y < sy; y++)
		for(int x = 0; x < sx; x++){
			Voxel t = h.at(x, y, z);
			v[((size_t)z * sy + y) * sx + x] = t;
			if(t != hill::AIR)
				tops[(size_t)z * sx + x] = y;
		}
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
		int16_t &top = tops[(size_t)z * sx + x];
		if(t != hill::AIR && y > top)
			top = y;
		if(t == hill::AIR && y == top){
			while(top >= 0 && at(x, top, z) == hill::AIR)
				top--;
		}
	}
};

// The sand's and the stones' numbers, tuned by driving
struct Soil
{
	float bearing = 80000;  // Pa: a 2 t car's tyres at about 65 kPa do not
	                        // sink, with 2 t aboard at about 90 they do
	float sink_rate = 3;    // voxels a second at twice the bearing
	float dig_rate = 2;     // voxels per metre the tread slides
	float throw_m = 0.5f;   // past the tyre, where the dug sand lands
	float stone_kg = 5.1f;  // a voxel of stone, 2600 kg/m^3
	float mu_bed = 0.6f;    // a stone on its bed
	float open_front = 0.35f; // of a stone's voxels, free along the push
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
};

struct Ground
{
	Grid &g;
	const hill::Hill &h;
	Soil soil;
	struct Wheel { float sink = 0, dig = 0; int side = 1; } wheels[4];
	std::vector<Change> changes; // for voxelworld, main.cpp takes them
	std::vector<Loose> loose;    // for Bullet, main.cpp takes them
	int dug = 0, sunk = 0, slid = 0, freed = 0; // for the log
	static const int SETTLE_BUDGET = 48;
	// What each changed voxel was when the hill was made, for restore()
	std::unordered_map<size_t, uint8_t> undo;

	Ground(Grid &grid, const hill::Hill &hill): g(grid), h(hill){}

	void set(int x, int y, int z, Voxel t)
	{
		if(!g.inside(x, y, z) || g.at(x, y, z) == t)
			return;
		undo.insert({((size_t)z * g.sy + y) * g.sx + x, g.at(x, y, z)});
		g.set(x, y, z, t);
		changes.push_back(Change{x, y, z, t});
	}

	// The top voxel of a column moved onto another's top
	bool move_top(int x, int z, int tx, int tz)
	{
		int y = g.top(x, z);
		if(y < 0 || g.at(x, y, z) != hill::SAND || !g.inside(tx, 0, tz))
			return false;
		int ty = g.top(tx, tz) + 1;
		if(ty >= g.sy)
			return false;
		set(x, y, z, hill::AIR);
		set(tx, ty, tz, hill::SAND);
		return true;
	}

	// Sand over a drop of two or more slides down it, from (x, z) and its
	// neighbours, a few moves at most
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
			int t = g.top(c.first, c.second);
			if(t < 0)
				continue;
			int best = -1, low = t - 1;
			for(int i = 0; i < 4; i++){
				int nt = g.top(c.first + D[i][0], c.second + D[i][1]);
				if(g.inside(c.first + D[i][0], 0, c.second + D[i][1]) &&
						nt < low){
					low = nt;
					best = i;
				}
			}
			if(best < 0)
				continue;
			int nx = c.first + D[best][0], nz = c.second + D[best][1];
			if(!move_top(c.first, c.second, nx, nz))
				continue;
			budget--;
			slid++;
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

	// A stone at (x, y, z) under a slipping tyre pushing with `push` N
	// along `dir`: loose if its front is open and the push beats its bed
	bool loosen(int x, int y, int z, const V3 &dir, float push)
	{
		float cx, cy, cz, r;
		if(!h.pebble_of(x, y, z, cx, cy, cz, r))
			return false;
		std::vector<Change> stone;
		int R = (int)std::ceil(r) + 1;
		for(int k = -R; k <= R; k++)
		for(int j = -R; j <= R; j++)
		for(int i = -R; i <= R; i++){
			int px = (int)std::lround(cx) + i, py = (int)std::lround(cy) + j,
					pz = (int)std::lround(cz) + k;
			float a, b, c, rr;
			if(g.at(px, py, pz) == hill::STONE &&
					h.pebble_of(px, py, pz, a, b, c, rr) &&
					a == cx && b == cy && c == cz)
				stone.push_back(Change{px, py, pz, hill::STONE});
		}
		if(stone.empty())
			return false;
		// Open along the push: the voxel past each one is air or the stone
		int sx = std::fabs(dir.x) > std::fabs(dir.z) ? (dir.x > 0 ? 1 : -1) : 0;
		int sz = sx == 0 ? (dir.z > 0 ? 1 : -1) : 0;
		int open = 0;
		for(const Change &s : stone){
			Voxel past = g.at(s.x + sx, s.y, s.z + sz);
			open += past == hill::AIR || past == hill::STONE;
		}
		float kg = soil.stone_kg * stone.size();
		if(open < soil.open_front * stone.size() ||
				push < soil.mu_bed * kg * 9.81f)
			return false;
		for(const Change &s : stone)
			set(s.x, s.y, s.z, hill::AIR);
		Loose l;
		l.centre = V3(cx, cy, cz);
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
		s.sink += std::fmax(0, pressure / soil.bearing - 1) * soil.sink_rate * dt;
		float speed = w.slide.length();
		if(w.slipping)
			s.dig += speed * dt * soil.dig_rate;
		// A voxel at a time; a substep moves one of each at most
		if(s.sink >= 1){
			s.sink -= 1;
			int cx = (int)std::lround(at.x), cz = (int)std::lround(at.z);
			V3 a = V3(w.axle.x, 0, w.axle.z).normalized() *
					(s.side * (spec.tyre_w * u / 2 + 1.5f));
			s.side = -s.side;
			int tx = (int)std::lround(at.x + a.x), tz = (int)std::lround(at.z + a.z);
			if(move_top(cx, cz, tx, tz)){
				sunk++;
				settle(cx, cz);
				settle(tx, tz);
			}
		}
		if(s.dig >= 1 && speed > 1e-3f){
			s.dig -= 1;
			V3 dir = w.slide * (1 / speed);
			auto cols = patch(at, w.axle, spec.tyre_w * u / 2, len * u / 2);
			// The highest stone under the patch tried first; held, the sand
			// beside it is dug instead, which bares it further
			int bx = 0, bz = 0, by = -1, kx = 0, kz = 0, ky = -1;
			for(auto &c : cols){
				int t = g.top(c.first, c.second);
				Voxel v = g.at(c.first, t, c.second);
				if(v == hill::SAND && t > by){
					by = t;
					bx = c.first;
					bz = c.second;
				}
				if(v == hill::STONE && t > ky){
					ky = t;
					kx = c.first;
					kz = c.second;
				}
			}
			if(ky >= by && ky >= 0){
				// The tyre's grip, half of it on the stone
				if(loosen(kx, ky, kz, dir, spec.mu * w.load / 2)){
					loose.back().velocity = w.slide;
					return;
				}
			}
			if(by < 0)
				return;
			float d = (spec.tyre_r + soil.throw_m) * u;
			int tx = (int)std::lround(at.x + dir.x * d),
					tz = (int)std::lround(at.z + dir.z * d);
			if(move_top(bx, bz, tx, tz)){
				dug++;
				settle(bx, bz);
				settle(tx, tz);
			}
		}
	}

	// The hill as it was made: every changed voxel back (a run's restart)
	void restore()
	{
		for(auto &u : undo){
			int x = (int)(u.first % g.sx), y = (int)(u.first / g.sx % g.sy),
					z = (int)(u.first / g.sx / g.sy);
			g.set(x, y, z, (Voxel)u.second);
			changes.push_back(Change{x, y, z, (Voxel)u.second});
		}
		undo.clear();
		loose.clear();
		dug = sunk = slid = freed = 0;
		for(Wheel &w : wheels)
			w = Wheel();
	}
	bool changed() const { return !undo.empty(); }

	// A stone that has come to rest, back into the grid: the air within its
	// radius of where it lies; how many voxels that was
	int rest(const V3 &centre, float radius)
	{
		int n = 0;
		int R = (int)std::ceil(radius);
		for(int k = -R; k <= R; k++)
		for(int j = -R; j <= R; j++)
		for(int i = -R; i <= R; i++){
			int x = (int)std::lround(centre.x) + i, y = (int)std::lround(centre.y) + j,
					z = (int)std::lround(centre.z) + k;
			V3 d = V3((float)x, (float)y, (float)z) - centre;
			if(d.length() <= radius && g.inside(x, y, z) &&
					g.at(x, y, z) == hill::AIR){
				set(x, y, z, hill::STONE);
				n++;
			}
		}
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
	for(int i = 0; i < 240 * 10; i++)
		gr.wheel(0, w, spec, U, 1.0f / 240);
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
	int before = g.top(30, 30);
	for(int i = 0; i < 240; i++)
		g2.wheel(0, s, spec, U, 1.0f / 240);
	printf("ground.h: a heavy tyre at rest: %d sunk, the column %d -> %d\n",
			g2.sunk, before, g.top(30, 30));
	assert(g2.sunk >= 2 && g.top(30, 30) < before);
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
	printf("ground.h: self test passed\n");
	return 0;
}
#endif
