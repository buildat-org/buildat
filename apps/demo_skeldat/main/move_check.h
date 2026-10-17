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
// [SKELDAT_SKATEBOARD] A body on the board (Board) goes as fast as the
// height lost allows, v^2 <= v0^2 + 2 g drop, the start's speed the one
// the last passed check measured; steps up 2, jumps 4 voxels and what its
// speed would lift it, and crosses a gap in a line of open cells.
// simplified: the drop is between the two checks' heights and BOARD_DIP,
// so a valley between them gives no more than that; a board in the air
// is let hover up to BOARD_AIR checks.
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
// player.lua's pull: Luanti's gravity, doubled
static const float G = 2 * 9.81f;
// The board's jump, 2 x speed_jump (13): 13^2 / 2G is 4.3
static const float BOARD_JUMP = 5;
static const float BOARD_DIP = 1;
static const int BOARD_AIR = 6;
// The box's reach to either side of the board's move
static const int BOARD_SIDE = 8;

struct Board
{
	// On the board since the last check
	bool on = false;
	// The speed the last passed check measured
	float v0 = 0;
	// The checks running that had it in the air on the board
	int air = 0;
};

struct Verdict
{
	bool ok = true;
	// The body was in the air at `to`
	bool air = false;
	// The speed measured, capped at the most believed: the next v0
	float speed = 0;
	const char *why = "";
};

// fill(f): f's cells SOLID, CLIMB or OPEN, its box set already.
// was_air: the last passed check had the body in the air.
inline Verdict check(const std::function<void(Field&)> &fill,
		float fx, float fy, float fz, float tx, float ty, float tz,
		float dt, bool was_air, const Board &board = Board())
{
	Verdict v;
	float reach = WALK * LAG * dt + SLACK;
	float jump = JUMP;
	float vmax = WALK * LAG;
	if(board.on){
		const float drop = std::max(0.0f, fy - ty) + BOARD_DIP;
		vmax = std::max(vmax, std::sqrt(board.v0 * board.v0 + 2 * G * drop));
		reach = vmax * LAG * dt + SLACK;
		jump = BOARD_JUMP + vmax * vmax / (2 * G);
	}
	const float dist = std::hypot(tx - fx, tz - fz);
	v.speed = std::min(dist / dt, vmax);
	if(dist > reach){
		v.ok = false;
		v.why = "too far";
		return v;
	}
	// The box's height is the move's: up no more than a walk and a jump,
	// down no more than a second at the fall speed luanti_session believes
	// (200), or a client's y of 1e6 is a box of half a billion cells
	if(ty - fy > reach + jump || fy - ty > FALL * dt + DOWN){
		v.ok = false;
		v.why = "too far up or down";
		return v;
	}
	// A voxel's centre is at its integer coordinates (player.lua rounds x
	// and z the same way); the feet's y rounds down onto the ground, which
	// settle() lifts off
	const P a0((int)std::floor(fx + 0.5f), (int)std::floor(fy),
			(int)std::floor(fz + 0.5f));
	const P b0((int)std::floor(tx + 0.5f), (int)std::floor(ty),
			(int)std::floor(tz + 0.5f));
	const int r = (int)std::ceil(reach) + 1;
	const int y0 = std::min(a0.y, b0.y) - DOWN, y1 = std::max(a0.y, b0.y) + 3;
	Field f;
	if(board.on){
		// The board's move is long: the box round both ends, not a square
		// of its reach round the start
		const int s = BOARD_SIDE;
		const int x0 = std::min(a0.x, b0.x) - s, z0 = std::min(a0.z, b0.z) - s;
		f.resize(P(x0, y0, z0), std::max(a0.x, b0.x) + s - x0 + 1,
				y1 - y0 + 1, std::max(a0.z, b0.z) + s - z0 + 1);
	} else {
		f.resize(P(a0.x - r, y0, a0.z - r), 2 * r + 1, y1 - y0 + 1,
				2 * r + 1);
	}
	fill(f);
	Rules rules;
	rules.max_length = reach;
	if(board.on)
		rules.step_up = 2;
	P a = a0, b = b0;
	// A start that does not settle (a voxel placed into it since) is not
	// the mover's doing: nothing to judge
	const bool b_lands = settle(f, rules, b);
	if(!settle(f, rules, a)){
		// Though a board in the air too long is
		if(board.on && board.air >= BOARD_AIR &&
				(!b_lands || ty - (float)b.y > JUMP)){
			v.ok = false;
			v.why = "in the air";
		}
		return v;
	}
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
		// when it was in the air too. The board's flight is thrown: up to
		// what its speed lifts it, for a few checks.
		const bool high = board.on ?
				ty > (float)a.y + jump || board.air >= BOARD_AIR :
				was_air ? ty > fy - 0.5f : ty > (float)a.y + JUMP;
		if(high){
			v.ok = false;
			v.why = "in the air";
			return v;
		}
		if(!b_lands)
			return v;
	}
	const Result res = find(f, a, b, rules);
	if(!res.found && board.on){
		// Over a gap: a line of open cells from the body to the body
		const int n = (int)std::ceil(std::hypot(dist, ty - fy) * 2) + 1;
		bool open = true;
		for(int i = 0; i <= n && open; i++){
			const float u = (float)i / n;
			const int x = (int)std::floor(fx + (tx - fx) * u + 0.5f),
					y = (int)std::floor(fy + (ty - fy) * u + 1),
					z = (int)std::floor(fz + (tz - fz) * u + 0.5f);
			open = f.at(x, y, z) != SOLID;
		}
		if(open)
			return v;
	}
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
// The cases are written with a cell's centre at .5 (x 0.5 the middle of
// cell 0); check() has it at the integer
static Verdict at(const std::function<void(Field&)> &w, float fx,
		float fy, float fz, float tx, float ty, float tz, bool was_air)
{
	return check(w, fx - 0.5f, fy, fz - 0.5f, tx - 0.5f, ty, tz - 0.5f, 1,
			was_air);
}
static bool ok(const std::function<void(Field&)> &w, float fx,
		float fy, float fz, float tx, float ty, float tz, bool was_air = false)
{
	return at(w, fx, fy, fz, tx, ty, tz, was_air).ok;
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
	// Up to a wall on the -x side, 0.3 short of its face: x -2.2 is in
	// cell -2 (centre -2.0), not the wall's -3 (a floor() had it in the
	// wall, and an honest walk pulled back)
	auto west = world([](int x, int y, int){
		return x == -3 && y <= 2 ? SOLID : -1; });
	assert(check(west, 0, 0, 0, -2.2f, 0, 0, 1, false).ok);
	// The same wall with a gap: round it
	auto gap = world([](int x, int y, int z){
		return x == 3 && y <= 2 && z != 3 ? SOLID : -1; });
	assert(ok(gap, 0.5f, 0, 0.5f, 5.5f, 0, 0.5f));
	// Off a pillar ten high, landed and mid-fall
	auto pillar = world([](int x, int y, int){
		return x <= 1 && y < 10 ? SOLID : -1; });
	assert(ok(pillar, 0.5f, 10, 0.5f, 4.5f, 0, 0.5f));
	Verdict v = at(pillar, 0.5f, 10, 0.5f, 3.5f, 6, 0.5f, false);
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
	// [SKELDAT_SKATEBOARD] The board: down a slope of 30 as fast as the
	// drop allows, and not faster on the flat
	auto slope = world([](int x, int y, int){
		return y < 30 - std::max(0, std::min(30, x)) ? SOLID : -1; });
	Board bd;
	bd.on = true;
	bd.v0 = 4;
	Verdict s1 = check(slope, 0, 30, 0, 30, 0, 0, 1, false, bd);
	assert(s1.ok && s1.speed > 20);
	assert(!check(slope, 0, 30, 0, 30, 30, 0, 1, false, bd).ok);
	bd.v0 = 10;
	assert(check(flat, 0, 0, 0, 20, 0, 0, 1, false, bd).ok);
	assert(!check(flat, 0, 0, 0, 30, 0, 0, 1, false, bd).ok);
	// Walking would have been pulled back
	assert(!check(flat, 0, 0, 0, 20, 0, 0, 1, false).ok);
	// Onto a step of 2, not of 3
	assert(check(step2, 0, 0, 0, 6, 2, 0, 1, false, bd).ok);
	auto step3 = world([](int x, int y, int){
		return x >= 3 && y <= 2 ? SOLID : -1; });
	assert(!check(step3, 0, 0, 0, 6, 3, 0, 1, false, bd).ok);
	// The jump's 4, over a gap 6 wide and 20 deep, and not through a wall
	assert(check(flat, 0, 0, 0, 3, 4, 0, 1, false, bd).ok);
	auto gap6 = world([](int x, int y, int){
		return x >= 2 && x <= 7 && y < 0 && y >= -20 ? OPEN : -1; });
	assert(check(gap6, 0, 0, 0, 10, 0, 0, 1, false, bd).ok);
	assert(!check(wall, 0, 0, 0, 10, 0, 0, 1, false, bd).ok);
	// A hover: let for a few checks, not for ever
	Board up = bd;
	up.air = 1;
	assert(check(flat, 0, 4, 0, 1, 4, 0, 1, true, up).ok);
	up.air = BOARD_AIR;
	assert(!check(flat, 0, 4, 0, 1, 4, 0, 1, true, up).ok);
	assert(!check(gap6, 4, 2, 0, 5, 2, 0, 1, true, up).ok);
	printf("skeldat move_check.h: self test passed\n");
	return 0;
}
#endif
// vim: set noet ts=4 sw=4:
