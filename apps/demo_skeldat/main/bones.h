// Buildat: apps/demo_skeldat/main/bones.h
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
//   g++ -std=c++11 -DSKELDAT_BONES_TEST -x c++ apps/demo_skeldat/main/bones.h -o /tmp/skeldat_bones && /tmp/skeldat_bones
//   (one line)
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace skeldat {
namespace bones {

static const int MAX = 15;
static const int FLOOD = 8;
// A voxel with more than this drops nothing when dug (user, 2026-10-15:
// over 20%)
static const int NO_DROP = 3;
// From this danger up a fresh section is seeded, at danger * MAX
static const float SEED_DANGER = 0.5f;
// Seconds of game time between a section's expansions, on average
static const double SECTION_PERIOD = 150;
// The most expansions a section loaded after a long time away catches up
// with: a month away is not a stalled load
static const int CATCHUP_MAX = 16;
// Bones grow off a voxel at MAX with air over it (user, 2026-10-15): the
// chance a section's expansion grows one there, on top a bone block (to
// STACK_MAX high) or a skull, two or a bone lying (main.cpp's expand()).
// About two an expansion where a section's whole ground is at MAX.
static const int GROW_ONE_IN = 2048, STACK_MAX = 4;

// skelenti's danger of a place (apps/demo_skelenti/main/main.cpp): value
// noise over 80-node cells, 0 to 1, a quarter of the world quiet. Only the
// mapgen reads it, to seed a fresh section (user, 2026-10-15: "no danger
// zone on the client").
inline float danger(uint32_t salt, float x, float z)
{
	const float C = 80;
	const int ix = (int)std::floor(x / C), iz = (int)std::floor(z / C);
	auto smooth = [](float t){ return t * t * (3 - 2 * t); };
	const float tx = smooth(x / C - ix), tz = smooth(z / C - iz);
	auto h = [&](int a, int b){
		uint32_t v = (uint32_t)a * 73856093u ^ (uint32_t)b * 19349663u ^ salt;
		v ^= v >> 13; v *= 0x5bd1e995u; v ^= v >> 15;
		return (v & 0xffff) / 65535.0f;
	};
	const float v = (h(ix, iz) * (1 - tx) + h(ix + 1, iz) * tx) * (1 - tz) +
			(h(ix, iz + 1) * (1 - tx) + h(ix + 1, iz + 1) * tx) * tz;
	return std::min(1.0f, std::max(0.0f, (v - 0.3f) / 0.6f));
}

inline int seed_value(float danger)
{
	return danger >= SEED_DANGER ? (int)std::lround(danger * MAX) : 0;
}

// How many expansions a section owes for `seconds` away
inline int catch_up(double seconds)
{
	if(seconds <= 0)
		return 0;
	return (int)std::min((double)CATCHUP_MAX, std::floor(seconds /
			SECTION_PERIOD));
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
	// The seeding and the catch-up
	assert(seed_value(0.49f) == 0 && seed_value(0.5f) == 8 &&
			seed_value(1.0f) == MAX);
	assert(catch_up(-5) == 0 && catch_up(149) == 0 && catch_up(300) == 2 &&
			catch_up(1e9) == CATCHUP_MAX);
	int seeded = 0;
	for(int i = 0; i < 10000; i++)
		seeded += seed_value(danger(3, (float)(i % 100) * 7,
				(float)(i / 100) * 7)) > 0;
	printf("bones: self test passed; %d%% of a 700x700 area seeded, the "
			"front a voxel per 7 expansions (%.0f s)\n", seeded / 100,
			7 * SECTION_PERIOD);
	return 0;
}
#endif
// vim: set noet ts=4 sw=4:
