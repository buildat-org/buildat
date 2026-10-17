// Buildat: apps/skeldat/main/bones.h
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// The bones field ([SKELDAT] stage 3): how much bone a voxel embeds, 0 to
// 15, in 4 bits of the voxel's second plane. It grows and floods; nothing
// takes it back yet (user, 2026-10-15: "the bones take over the world").
// The rule, its constants all here:
// - an expansion of a section first floods in from its neighbours: a voxel
//   just outside with FLOOD or more gives each voxel of the section beside
//   it that is not air-like and has none a bones of 1;
// - then every voxel of the section with bones gets 1 more, up to MAX;
// - then every voxel of the section with FLOOD or more does the same
//   flood to its six neighbours inside the section.
// So a voxel seeded at 1 floods its neighbours on the 7th expansion after,
// and the front moves a voxel per 7 expansions of its section. A section
// expands on average every SECTION_PERIOD seconds: a voxel per 1050 s,
// which is 0.875 of a day (1200 s).
// Pure: no Buildat, no module; main.cpp hands it the voxels. Self test:
//   g++ -std=c++11 -DSKELDAT_BONES_TEST -x c++ apps/skeldat/main/bones.h -o /tmp/skeldat_bones && /tmp/skeldat_bones
//   (one line)
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace skeldat {
namespace bones {

// The world ([SKELDAT_BOUNDED_WORLD]): x and z -HALF to HALF - 1, y Y0 to
// Y1, in sections of SECTION
static const int HALF = 512, Y0 = -64, Y1 = 63, SECTION = 64;

static const int MAX = 15;
static const int FLOOD = 8;
// A voxel with more than this drops nothing when dug (user, 2026-10-15:
// over 20%)
static const int NO_DROP = 3;
// From this danger up a fresh section is seeded, 1 here to MAX at 1
static const float SEED_DANGER = 0.5f;
// Seconds of game time between a section's expansions, on average
static const double SECTION_PERIOD = 150;
// Bones grow off a voxel at MAX with air over it (user, 2026-10-15): the
// chance a section's expansion grows one there, on top a bone block (to
// STACK_MAX high) or a skull, two or a bone lying (main.cpp's expand()).
// About two an expansion where a section's whole ground is at MAX.
static const int GROW_ONE_IN = 2048, STACK_MAX = 4;

// skelenti's hash of two integers, 0 to 1 (mobs.lua's hash)
inline float hash(int32_t a, int32_t b, uint32_t salt)
{
	uint32_t v = (uint32_t)a * 73856093u ^ (uint32_t)b * 19349663u ^ salt;
	v ^= v >> 13; v *= 0x5bd1e995u; v ^= v >> 15;
	return (v & 0xffff) / 65535.0f;
}

// skelenti's danger of a place (apps/demo_skelenti/main/main.cpp): value
// noise over 80-node cells, 0 to 1, a quarter of the world quiet. Only the
// mapgen reads it, to seed a fresh section (user, 2026-10-15: "no danger
// zone on the client"). **Biased by the distance from the origin**
// ([SKELDAT_BOUNDED_WORLD], user: "increase to 100% when reaching the world
// edges"): the noise weighed from 0 near the origin to all of it, and a
// rise to 1 at the edge, by t, the column's distance to the nearer edge
// line over HALF -- so the spawn is clean, the middle has patches and the
// border is solid bones.
inline float noise_danger(uint32_t salt, float x, float z);
// half: the world's, in voxels ([SKELDAT_WORLD_SIZES]: the size picked)
inline float danger(uint32_t salt, float x, float z, int half = HALF)
{
	auto step = [](float a, float b, float t){
		t = std::min(1.0f, std::max(0.0f, (t - a) / (b - a)));
		return t * t * (3 - 2 * t);
	};
	const float t = std::max(std::fabs(x + 0.5f), std::fabs(z + 0.5f)) / half;
	return std::max(noise_danger(salt, x, z) * step(0.2f, 0.9f, t),
			step(0.85f, 0.99f, t));
}
inline float noise_danger(uint32_t salt, float x, float z)
{
	const float C = 80;
	const int ix = (int)std::floor(x / C), iz = (int)std::floor(z / C);
	auto smooth = [](float t){ return t * t * (3 - 2 * t); };
	const float tx = smooth(x / C - ix), tz = smooth(z / C - iz);
	auto h = [&](int a, int b){ return hash(a, b, salt); };
	const float v = (h(ix, iz) * (1 - tx) + h(ix + 1, iz) * tx) * (1 - tz) +
			(h(ix, iz + 1) * (1 - tx) + h(ix + 1, iz + 1) * tx) * tz;
	return std::min(1.0f, std::max(0.0f, (v - 0.3f) / 0.6f));
}

// **A pile at map generation** ([SKELDAT_BONES_LOOK], skelenti's
// on_generated in mobs.lua): on the ground of a column now and then, more
// often the higher the danger from PILE_FROM, a stack of bone blocks
// `height` high with top on it -- 1 a skull, 2 two, 3 a bone lying, 4
// nothing -- turned by `turn`. False for a column with none.
static const float PILE_FROM = 0.3f;
struct Pile { int height = 0, top = 0, turn = 0; };
inline bool pile(uint32_t salt, int32_t x, int32_t z, Pile &p,
		int half = HALF)
{
	const float d = danger(salt, (float)x, (float)z, half);
	if(!(d > PILE_FROM) || hash(x, z, salt + 7) >= 0.15f *
			std::pow((d - PILE_FROM) / (1 - PILE_FROM), 1.5f))
		return false;
	// Below the chance, spread anew: the height and the top
	const float q = hash(z, x, salt + 13);
	p.height = (int)std::floor(q * q * (1 + 5 * d));
	p.top = 1 + (int)std::floor(hash(x + z, x - z, salt) * 4);
	p.turn = (int)std::floor(q * 97) % 4;
	return true;
}

// [SKELDAT_SKELETON_PLAYERS] A player looks like a skeleton to the others
// while a voxel in the 3x4x3 box round the voxel its feet are in (x, y, z)
// -- one below the feet to one over the head -- has bones over half
// (user, 2026-10-15). bones_at(x, y, z) is a voxel's bones. The same box
// keeps the sun off a skeleton ([SKELDAT_SUN_IN_BONES]), its bones_at
// giving a bone block or a skull MAX.
static const int SKELETON_BONES = 8;
template<typename F>
inline bool skeleton_near(F bones_at, int x, int y, int z)
{
	for(int dy = -1; dy <= 2; dy++)
	for(int dz = -1; dz <= 1; dz++)
	for(int dx = -1; dx <= 1; dx++)
		if(bones_at(x + dx, y + dy, z + dz) >= SKELETON_BONES)
			return true;
	return false;
}

inline int seed_value(float danger)
{
	// [SKELDAT_BONES_SEEN] Ramped from 1 at SEED_DANGER to MAX at 1, so a
	// fresh zone shades in from its edge rather than starting at 8
	return danger >= SEED_DANGER ? 1 + (int)std::lround((danger -
			SEED_DANGER) * (MAX - 1) / (1 - SEED_DANGER)) : 0;
}


// A section and one voxel around it, x fastest: the bones and whether a
// voxel is air-like (nothing floods into it)
struct Box
{
	int w = 0, h = 0, d = 0;
	std::vector<uint8_t> b, air;

	Box(int w, int h, int d): w(w), h(h), d(d),
		b((size_t)w * h * d, 0), air((size_t)w * h * d, 0){}
	size_t at(int x, int y, int z) const {
		return (size_t)x + (size_t)y * w + (size_t)z * w * h;
	}
	bool inside(int x, int y, int z) const {
		return x >= 1 && y >= 1 && z >= 1 && x < w - 1 && y < h - 1 &&
				z < d - 1;
	}
};

// One expansion of the section inside the box; returns whether any voxel
// of it changed
inline bool expand(Box &box)
{
	static const int D[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0},
			{0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
	bool changed = false;
	auto flood_from = [&](int x, int y, int z){
		for(auto &d : D){
			const int nx = x + d[0], ny = y + d[1], nz = z + d[2];
			if(!box.inside(nx, ny, nz))
				continue;
			const size_t n = box.at(nx, ny, nz);
			if(!box.air[n] && box.b[n] == 0){
				box.b[n] = 1;
				changed = true;
			}
		}
	};
	// In from the neighbours: the shell around the section
	for(int z = 0; z < box.d; z++)
	for(int y = 0; y < box.h; y++)
	for(int x = 0; x < box.w; x++){
		if(!box.inside(x, y, z) && box.b[box.at(x, y, z)] >= FLOOD)
			flood_from(x, y, z);
	}
	// Up by one; the air-like keep what they have, if anything wrote it
	for(int z = 1; z < box.d - 1; z++)
	for(int y = 1; y < box.h - 1; y++)
	for(int x = 1; x < box.w - 1; x++){
		const size_t i = box.at(x, y, z);
		if(box.b[i] > 0 && box.b[i] < MAX && !box.air[i]){
			box.b[i]++;
			changed = true;
		}
	}
	// And out inside. A voxel this sets has 1, so it floods nothing
	// before the next expansion.
	for(int z = 1; z < box.d - 1; z++)
	for(int y = 1; y < box.h - 1; y++)
	for(int x = 1; x < box.w - 1; x++){
		if(box.b[box.at(x, y, z)] >= FLOOD && !box.air[box.at(x, y, z)])
			flood_from(x, y, z);
	}
	return changed;
}

// The world's edge ([SKELDAT_EDGE_RIDGE]): a hillside of bone blocks over
// the last EDGE_COLUMNS columns of each side, rising EDGE_HEIGHT by a
// smoothstep towards the edge (d the column's distance to it, 0 the
// outermost); room, the voxels free over the column's ground under the
// world's top, caps it
static const int EDGE_COLUMNS = 16, EDGE_HEIGHT = 12;
inline int edge_rise(int d, int room)
{
	if(d < 0 || d >= EDGE_COLUMNS)
		return 0;
	const float t = 1.0f - (float)d / EDGE_COLUMNS;
	const int h = (int)std::lround(EDGE_HEIGHT * t * t * (3 - 2 * t));
	return std::max(0, std::min(h, room));
}

// [SKELDAT_SURFACE_END] A deep hole: a column whose top (y, bones) is
// more than DEEP_HOLE under the lowest of its eight neighbours' tops and
// has no bones -- a shaft dug to keep a column bare, or a natural pit. A
// skeleton beside one drops a skull into it in one of HOLE_ONE_IN steps.
static const int DEEP_HOLE = 4, HOLE_ONE_IN = 20;
inline bool deep_hole(int top, int bones, const int around[8])
{
	int low = around[0];
	for(int i = 1; i < 8; i++)
		low = std::min(low, around[i]);
	return bones == 0 && top < low - DEEP_HOLE;
}

} // namespace bones
} // namespace skeldat

#ifdef SKELDAT_BONES_TEST
#include <cassert>
#include <cstdio>
#include <cstdlib>
using namespace skeldat::bones;
// The furthest a voxel with bones is from (cx, cy, cz), in steps
static int front(const Box &box, int cx, int cy, int cz)
{
	int far = -1;
	for(int z = 1; z < box.d - 1; z++)
	for(int y = 1; y < box.h - 1; y++)
	for(int x = 1; x < box.w - 1; x++){
		if(box.b[box.at(x, y, z)] > 0)
			far = std::max(far, std::abs(x - cx) + std::abs(y - cy) +
					std::abs(z - cz));
	}
	return far;
}
int main()
{
	// One voxel at FLOOD in a solid section: its neighbours at once, and
	// a step further every 7 expansions (distance d at 1 + 7 (d - 1))
	{
		Box box(18, 18, 18);
		box.b[box.at(9, 9, 9)] = FLOOD;
		for(int n = 1; n <= 22; n++){
			expand(box);
			const int want = 1 + (n - 1) / 7;
			if(front(box, 9, 9, 9) != want){
				printf("FAIL: after %d expansions the front is %d, not %d\n",
						n, front(box, 9, 9, 9), want);
				return 1;
			}
		}
		assert(box.b[box.at(9, 9, 9)] == MAX);
	}
	// In from a neighbour: a voxel of the shell at FLOOD seeds the one
	// beside it inside, which gets its 1 and then the increment
	{
		Box box(6, 6, 6);
		box.b[box.at(0, 3, 3)] = FLOOD;
		expand(box);
		assert(box.b[box.at(1, 3, 3)] == 2);
		assert(box.b[box.at(2, 3, 3)] == 0);
		// The shell is the neighbour's; nothing here writes it
		assert(box.b[box.at(0, 3, 3)] == FLOOD);
	}
	// Air-like voxels are not flooded, nor grow
	{
		Box box(5, 5, 5);
		box.b[box.at(2, 2, 2)] = MAX;
		box.air[box.at(3, 2, 2)] = 1;
		box.air[box.at(1, 2, 2)] = 1;
		box.b[box.at(1, 2, 2)] = 3; // a dug voxel's leftovers
		expand(box);
		assert(box.b[box.at(3, 2, 2)] == 0 && box.b[box.at(2, 3, 2)] == 1);
		assert(box.b[box.at(1, 2, 2)] == 3);
	}
	// Nothing to do in a section with no bones near it
	{
		Box box(6, 6, 6);
		assert(!expand(box));
	}
	// The skeleton's box: 8 in it, at its corners, makes one; 7 does not,
	// nor 8 just outside
	{
		int at[3] = {0, 0, 0}, value = 0;
		auto f = [&](int x, int y, int z){
			return x == at[0] && y == at[1] && z == at[2] ? value : 0;
		};
		auto put = [&](int x, int y, int z, int v){
			at[0] = x; at[1] = y; at[2] = z; value = v;
		};
		put(1, -1, 1, 8); assert(skeleton_near(f, 0, 0, 0));
		put(-1, 2, -1, 8); assert(skeleton_near(f, 0, 0, 0));
		put(0, 1, 0, 7); assert(!skeleton_near(f, 0, 0, 0));
		put(0, 3, 0, 15); assert(!skeleton_near(f, 0, 0, 0));
		put(0, -2, 0, 15); assert(!skeleton_near(f, 0, 0, 0));
		put(2, 0, 0, 15); assert(!skeleton_near(f, 0, 0, 0));
	}
	// The edge's hillside: its full height at the edge, falling to none
	// past EDGE_COLUMNS, never more than the room, at most 1.1 a column
	assert(edge_rise(0, 100) == EDGE_HEIGHT && edge_rise(EDGE_COLUMNS, 100) == 0 &&
			edge_rise(-1, 100) == 0 && edge_rise(0, 5) == 5 &&
			edge_rise(3, 0) == 0);
	for(int d = 0; d + 1 < EDGE_COLUMNS; d++)
		assert(edge_rise(d, 100) >= edge_rise(d + 1, 100) &&
				edge_rise(d, 100) - edge_rise(d + 1, 100) <= 2);
	// The seeding
	assert(seed_value(0.49f) == 0 && seed_value(0.5f) == 1 &&
			seed_value(0.75f) == 8 && seed_value(1.0f) == MAX);
	// The bias: nothing round the origin, every edge column MAX
	for(uint32_t salt = 1; salt < 20; salt++){
		for(int a = -60; a < 60; a++)
			assert(danger(salt, (float)a, (float)(a * 7 % 60)) == 0);
		// The smallest world's (half 64) clean middle: t under 0.2
		for(int a = -10; a < 10; a++)
			assert(danger(salt, (float)a, (float)(a * 3 % 10), 64) == 0);
		// Every size's edge ([SKELDAT_WORLD_SIZES])
		for(int half : {HALF, 256, 128, 64})
		for(int a = -half; a < half; a++)
			for(float e : {(float)-half, (float)(half - 1)})
				assert(seed_value(danger(salt, (float)a, e, half)) == MAX &&
						seed_value(danger(salt, e, (float)a, half)) == MAX);
	}
	int seeded = 0;
	for(int i = 0; i < 10000; i++)
		seeded += seed_value(danger(3, (float)(i % 100) * 7,
				(float)(i / 100) * 7)) > 0;
	// The piles: none under PILE_FROM, more in the deep zone than at its
	// edge, never over six blocks
	int piles_low = 0, piles_high = 0, columns_low = 0, columns_high = 0;
	for(int32_t z = -400; z < 400; z++)
	for(int32_t x = -400; x < 400; x++){
		const float d = danger(3, (float)x, (float)z);
		Pile p;
		const bool has = pile(3, x, z, p);
		assert(!has || (d > PILE_FROM && p.height >= 0 && p.height <= 6 &&
				p.top >= 1 && p.top <= 4 && p.turn >= 0 && p.turn < 4));
		if(d > 0.3f && d < 0.5f){ columns_low++; piles_low += has; }
		if(d > 0.9f){ columns_high++; piles_high += has; }
	}
	assert(columns_low && columns_high &&
			piles_high * columns_low > 5 * piles_low * columns_high);
	// A 1-wide shaft 6 deep is a deep hole, a dip of 3 is not, nor the
	// shaft with bones, nor one with a neighbour as deep (a trench's end)
	{
		const int around[8] = {10, 10, 10, 10, 10, 10, 10, 10};
		assert(deep_hole(4, 0, around));
		assert(!deep_hole(7, 0, around));
		assert(!deep_hole(4, 1, around));
		const int trench[8] = {10, 10, 10, 4, 10, 10, 10, 10};
		assert(!deep_hole(4, 0, trench));
	}
	printf("bones: self test passed; %d%% of a 700x700 area seeded, the "
			"front a voxel per 7 expansions (%.0f s); piles on %.2f%% of "
			"the columns over 0.9, %.3f%% at 0.3-0.5\n", seeded / 100,
			7 * SECTION_PERIOD, 100.0 * piles_high / columns_high,
			100.0 * piles_low / columns_low);
	return 0;
}
#endif
// vim: set noet ts=4 sw=4:
