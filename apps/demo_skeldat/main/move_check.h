// Buildat: apps/demo_skeldat/main/move_check.h
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// The movement check ([SKELDAT] decision 13, stage 6): whether a player
// could have got from where the last check passed them to where they are
// now, walking at up to LAG times the walk speed, stepping up a voxel and
// falling, by the engine's voxel pathfinder (interface/voxel_path.h).
// What the pathfinder cannot see is a body in the air, which the client's
// positions often are (a jump, a fall): such a position is judged where it
// would land, and by a rule of its own -- a body in the air is at most a
// jump over the ground the check before had it on, and one in the air two
// checks running has come down since the first.
// simplified: a slow glide down passes the air rule; the box reaches DOWN
// voxels under the move, and a body over a deeper drop is judged only by
// the air rule.
// Pure: main.cpp hands it the cells. Self test:
//   g++ -std=c++11 -DSKELDAT_MOVE_TEST -Isrc -x c++ apps/demo_skeldat/main/move_check.h -x none src/impl/voxel_path.cpp -o /tmp/skeldat_move && /tmp/skeldat_move
//   (one line)
#pragma once
#include "interface/voxel_path.h"
#include <cmath>
#include <functional>

namespace skeldat {
namespace move_check {

using namespace interface::voxel_path;

// player.lua's speed_walk, in voxels a second
static const float WALK = 4;
// The network's lag: a second of positions may come in half of one
static const float LAG = 2;
// A body's width and the voxel rounding of both ends
static const float SLACK = 1.5f;
// How high a jump lifts the feet over the ground, with room (player.lua's
// jump peaks near 1.25)
static const float JUMP = 1.5f;
// How far under the move the box reaches for ground
static const int DOWN = 8;
// The fastest fall believed, voxels a second (luanti_session's on_fell cap)
static const float FALL = 200;

struct Verdict
{
	bool ok = true;
	// The body was in the air at `to`
	bool air = false;
	const char *why = "";
};

// fill(f): f's cells SOLID, CLIMB or OPEN, its box set already.
// was_air: the last passed check had the body in the air.
inline Verdict check(const std::function<void(Field&)> &fill,
		float fx, float fy, float fz, float tx, float ty, float tz,
		float dt, bool was_air)
{
	Verdict v;
	const float reach = WALK * LAG * dt + SLACK;
	if(std::hypot(tx - fx, tz - fz) > reach){
		v.ok = false;
		v.why = "too far";
		return v;
	}
	// The box's height is the move's: up no more than a walk and a jump,
	// down no more than a second at the fall speed luanti_session believes
	// (200), or a client's y of 1e6 is a box of half a billion cells
	if(ty - fy > reach + JUMP || fy - ty > FALL * dt + DOWN){
		v.ok = false;
		v.why = "too far up or down";
		return v;
	}
	const P a0((int)std::floor(fx), (int)std::floor(fy), (int)std::floor(fz));
	const P b0((int)std::floor(tx), (int)std::floor(ty), (int)std::floor(tz));
	const int r = (int)std::ceil(reach) + 1;
	const int y0 = std::min(a0.y, b0.y) - DOWN, y1 = std::max(a0.y, b0.y) + 3;
	Field f;
	f.resize(P(a0.x - r, y0, a0.z - r), 2 * r + 1, y1 - y0 + 1, 2 * r + 1);
	fill(f);
	Rules rules;
	rules.max_length = reach;
	P a = a0, b = b0;
	// A start that does not settle (a voxel placed into it since) is not
	// the mover's doing: nothing to judge
	if(!settle(f, rules, a))
		return v;
	const bool b_lands = settle(f, rules, b);
	// Sunk deeper than settle lifts: inside the ground (noclip)
	if(!b_lands && (f.at(b0.x, b0.y, b0.z) == SOLID ||
			f.at(b0.x, b0.y + 1, b0.z) == SOLID)){
		v.ok = false;
		v.why = "in a wall";
		return v;
	}
	v.air = !b_lands || ty - (float)b.y > JUMP;
	if(v.air){
		// Up to a jump over where the last check stood; down since then
		// when it was in the air too
		if(was_air ? ty > fy - 0.5f : ty > (float)a.y + JUMP){
			v.ok = false;
			v.why = "in the air";
			return v;
		}
		if(!b_lands)
			return v;
	}
	const Result res = find(f, a, b, rules);
	if(!res.found){
		v.ok = false;
		v.why = res.capped ? "too far to search" : "no way there";
	}
	return v;
}

} // namespace move_check
} // namespace skeldat

#ifdef SKELDAT_MOVE_TEST
#include <cassert>
#include <cstdio>
using namespace skeldat::move_check;
// Flat ground: y < 0 solid; the cells in `extra` as they say
static std::function<void(Field&)> world(
		std::function<int(int, int, int)> extra)
{
	return [=](Field &f){
		for(int y = f.origin.y; y < f.origin.y + f.h; y++)
		for(int z = f.origin.z; z < f.origin.z + f.d; z++)
		for(int x = f.origin.x; x < f.origin.x + f.w; x++){
			const int e = extra(x, y, z);
			f.set(x, y, z, e >= 0 ? (uint8_t)e : y < 0 ? SOLID : OPEN);
		}
	};
}
static bool ok(const std::function<void(Field&)> &w, float fx,
		float fy, float fz, float tx, float ty, float tz, bool was_air = false)
{
	return check(w, fx, fy, fz, tx, ty, tz, 1, was_air).ok;
}
int main()
{
	auto flat = world([](int, int, int){ return -1; });
	// A walk, twice the walk speed passes, three times does not
	assert(ok(flat, 0.5f, 0, 0.5f, 4.5f, 0, 0.5f));
	assert(ok(flat, 0.5f, 0, 0.5f, 8.5f, 0, 0.5f));
	assert(!ok(flat, 0.5f, 0, 0.5f, 12.5f, 0, 0.5f));
	// Onto a block of one, not of two
	auto step1 = world([](int x, int y, int){
		return x >= 3 && y == 0 ? SOLID : -1; });
	assert(ok(step1, 0.5f, 0, 0.5f, 4.5f, 1, 0.5f));
	auto step2 = world([](int x, int y, int){
		return x >= 3 && y <= 1 ? SOLID : -1; });
	assert(!ok(step2, 0.5f, 0, 0.5f, 4.5f, 2, 0.5f));
	// A wall three high across the way, no way round in the box
	auto wall = world([](int x, int y, int){
		return x == 3 && y <= 2 ? SOLID : -1; });
	assert(!ok(wall, 0.5f, 0, 0.5f, 5.5f, 0, 0.5f));
	// The same wall with a gap: round it
	auto gap = world([](int x, int y, int z){
		return x == 3 && y <= 2 && z != 3 ? SOLID : -1; });
	assert(ok(gap, 0.5f, 0, 0.5f, 5.5f, 0, 0.5f));
	// Off a pillar ten high, landed and mid-fall
	auto pillar = world([](int x, int y, int){
		return x <= 1 && y < 10 ? SOLID : -1; });
	assert(ok(pillar, 0.5f, 10, 0.5f, 4.5f, 0, 0.5f));
	Verdict v = check(pillar, 0.5f, 10, 0.5f, 3.5f, 6, 0.5f, 1, false);
	assert(v.ok && v.air);
	// Still falling the next check, and hanging there
	assert(ok(pillar, 3.5f, 6, 0.5f, 3.5f, 2, 0.5f, true));
	assert(!ok(pillar, 3.5f, 6, 0.5f, 3.5f, 6, 0.5f, true));
	// Down into the ground, three deep
	assert(!ok(flat, 0.5f, 0, 0.5f, 1.5f, -3, 0.5f));
	// A jump's height off the ground, not five
	assert(ok(flat, 0.5f, 0, 0.5f, 2.5f, 1.2f, 0.5f));
	assert(!ok(flat, 0.5f, 0, 0.5f, 2.5f, 5, 0.5f));
	// Up a column of water (CLIMB), not up the air beside it
	auto water = world([](int x, int y, int){
		return x == 2 && y >= 0 && y < 6 ? CLIMB : -1; });
	assert(ok(water, 2.5f, 0, 0.5f, 2.5f, 4, 0.5f));
	// A client's position a million up or down: refused before any box
	assert(!ok(flat, 0.5f, 0, 0.5f, 0.5f, 1e6f, 0.5f));
	assert(!ok(flat, 0.5f, 0, 0.5f, 0.5f, -1e6f, 0.5f));
	printf("skeldat move_check.h: self test passed\n");
	return 0;
}
#endif
// vim: set noet ts=4 sw=4:
