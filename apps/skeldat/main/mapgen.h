// Buildat: apps/skeldat/main/mapgen.h
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// skeldat's own map generator's pure parts ([SKELDAT_OWN_MAPGEN]): the
// whole world's heightmap, made once at the world's start before any
// section, its form's bias and droplet erosion; the noodle caves; where a
// tree stands. terrain.h's SkeldatGenerator reads them a section at a time
// on worldgen's workers (read only, so shared).
// Pure: no Buildat, no module. Self test:
//   g++ -std=c++11 -O2 -DSKELDAT_MAPGEN_TEST -x c++ apps/skeldat/main/mapgen.h -o /tmp/skeldat_mapgen && /tmp/skeldat_mapgen
//   (one line)
#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <random>
#include <string>
#include <vector>

namespace skeldat {
namespace mapgen {

// The tuning numbers (the user's to try): erosion's droplets a column and
// a droplet's steps at most; the caves' threshold (a voxel is a tunnel
// where both noises are within it of 0) and the spreads of their noises;
// the chance of a tree on a grass column; the plains' water
static const float DROPLETS_PER_COLUMN = 0.5f;
static const int DROPLET_STEPS = 48;
static const float CAVE_WIDTH = 0.05f, CAVE_SPREAD_XZ = 40, CAVE_SPREAD_Y = 24;
static const float TREE_CHANCE = 0.006f;
// The plains' water table: the height this share of the columns is under
static const float WATER_SHARE = 0.1f;

enum Form { RIVERS, PLAINS, LAKE, SEA };
static const char *FORM_NAMES[] = {"rivers", "plains", "lake", "sea"};
inline int form_of(const std::string &name)
{
	for(int i = 0; i < 4; i++)
		if(name == FORM_NAMES[i])
			return i;
	return -1;
}

// A lattice point's value, -1 to 1
inline float lattice(int32_t x, int32_t y, int32_t z, uint32_t seed)
{
	uint32_t h = seed * 0x9E3779B1u;
	h ^= (uint32_t)x * 0x85EBCA6Bu;
	h = (h ^ (h >> 15)) * 0x2C1B3C6Du;
	h ^= (uint32_t)y * 0xC2B2AE35u;
	h = (h ^ (h >> 13)) * 0x297A2D39u;
	h ^= (uint32_t)z * 0x27D4EB2Fu;
	h = (h ^ (h >> 16)) * 0x7FEB352Du;
	h ^= h >> 15;
	return (h & 0xffffff) / (float)0x7fffff - 1.0f;
}
inline float ease(float t){ return t * t * (3 - 2 * t); }

// Value noise, -1 to 1, a lattice point every 1
inline float value3(float x, float y, float z, uint32_t seed)
{
	const float fx = std::floor(x), fy = std::floor(y), fz = std::floor(z);
	const int32_t ix = (int32_t)fx, iy = (int32_t)fy, iz = (int32_t)fz;
	const float tx = ease(x - fx), ty = ease(y - fy), tz = ease(z - fz);
	float c[2][2];
	for(int dz = 0; dz < 2; dz++)
		for(int dy = 0; dy < 2; dy++){
			const float a = lattice(ix, iy + dy, iz + dz, seed),
					b = lattice(ix + 1, iy + dy, iz + dz, seed);
			c[dz][dy] = a + (b - a) * tx;
		}
	const float y0 = c[0][0] + (c[0][1] - c[0][0]) * ty,
			y1 = c[1][0] + (c[1][1] - c[1][0]) * ty;
	return y0 + (y1 - y0) * tz;
}
inline float value2(float x, float z, uint32_t seed)
{
	const float fx = std::floor(x), fz = std::floor(z);
	const int32_t ix = (int32_t)fx, iz = (int32_t)fz;
	const float tx = ease(x - fx), tz = ease(z - fz);
	const float a = lattice(ix, 0, iz, seed), b = lattice(ix + 1, 0, iz, seed),
			c = lattice(ix, 0, iz + 1, seed), d = lattice(ix + 1, 0, iz + 1, seed);
	const float ab = a + (b - a) * tx, cd = c + (d - c) * tx;
	return ab + (cd - ab) * tz;
}
// Octaves summed, each twice the frequency and persist the amplitude,
// scaled back to -1..1
inline float fbm2(float x, float z, uint32_t seed, int octaves, float persist)
{
	float sum = 0, amp = 1, norm = 0, f = 1;
	for(int i = 0; i < octaves; i++){
		sum += value2(x * f, z * f, seed + (uint32_t)i * 101) * amp;
		norm += amp, amp *= persist, f *= 2;
	}
	return sum / norm;
}
inline float fbm3(float x, float y, float z, uint32_t seed, int octaves,
		float persist)
{
	float sum = 0, amp = 1, norm = 0, f = 1;
	for(int i = 0; i < octaves; i++){
		sum += value3(x * f, y * f, z * f, seed + (uint32_t)i * 101) * amp;
		norm += amp, amp *= persist, f *= 2;
	}
	return sum / norm;
}

// The world's shape: half its width (voxels), its bottom and top voxel,
// the water line, the form
struct Params {
	uint32_t seed = 0;
	int half = 64, bottom = -64, top = 63, water_level = 1;
	int form = PLAINS;
};

// The ground's height a column, float; x and z from -half to half - 1
struct Heightmap {
	int half = 0;
	std::vector<float> h;
	int width() const { return 2 * half; }
	float &at(int x, int z){ return h[(size_t)(z + half) * width() + (x + half)]; }
	float at(int x, int z) const { return h[(size_t)(z + half) * width() + (x + half)]; }
	bool in(int x, int z) const { return x >= -half && x < half && z >= -half && z < half; }
	// Bilinear, for the droplets: (x, z) in cells from the corner
	float sample(float gx, float gz) const
	{
		const int w = width();
		const int ix = std::min(w - 2, std::max(0, (int)gx)),
				iz = std::min(w - 2, std::max(0, (int)gz));
		const float tx = gx - ix, tz = gz - iz;
		const float a = h[(size_t)iz * w + ix], b = h[(size_t)iz * w + ix + 1],
				c = h[(size_t)(iz + 1) * w + ix], d = h[(size_t)(iz + 1) * w + ix + 1];
		return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * tz;
	}
};

// Droplet erosion: a droplet run downhill picks up by its speed and the
// slope and drops where it slows or climbs; what it carries at its end
// is left there, so the ground's sum is kept (but for what leaves the
// world's side)
// What it takes comes off a 3x3 brush round its cell (a cell's own
// would cut one-cell gullies the voxels show as pits); what it drops
// goes on the four corners of its cell.
inline void erode(Heightmap &m, uint32_t seed, size_t droplets)
{
	const int w = m.width();
	std::mt19937 r(seed ^ 0x5eed);
	std::uniform_real_distribution<float> u(0, 1);
	const float inertia = 0.1f, capacity_k = 4, min_slope = 0.01f,
			erode_k = 0.3f, deposit_k = 0.3f, evaporate = 0.02f, gravity = 4;
	auto add = [&](float gx, float gz, float v){
		const int ix = (int)gx, iz = (int)gz;
		const float tx = gx - ix, tz = gz - iz;
		m.h[(size_t)iz * w + ix] += v * (1 - tx) * (1 - tz);
		m.h[(size_t)iz * w + ix + 1] += v * tx * (1 - tz);
		m.h[(size_t)(iz + 1) * w + ix] += v * (1 - tx) * tz;
		m.h[(size_t)(iz + 1) * w + ix + 1] += v * tx * tz;
	};
	for(size_t d = 0; d < droplets; d++){
		float x = u(r) * (w - 2), z = u(r) * (w - 2), dx = 0, dz = 0;
		float speed = 1, water = 1, sediment = 0;
		for(int step = 0; step < DROPLET_STEPS; step++){
			const int ix = (int)x, iz = (int)z;
			const float tx = x - ix, tz = z - iz;
			const float a = m.h[(size_t)iz * w + ix], b = m.h[(size_t)iz * w + ix + 1],
					c = m.h[(size_t)(iz + 1) * w + ix],
					e = m.h[(size_t)(iz + 1) * w + ix + 1];
			const float gx = (b - a) * (1 - tz) + (e - c) * tz,
					gz = (c - a) * (1 - tx) + (e - b) * tx;
			const float here = (a + (b - a) * tx) + ((c + (e - c) * tx) -
					(a + (b - a) * tx)) * tz;
			dx = dx * inertia - gx * (1 - inertia);
			dz = dz * inertia - gz * (1 - inertia);
			const float len = std::sqrt(dx * dx + dz * dz);
			if(len < 1e-6f)
				break;
			dx /= len, dz /= len;
			const float nx = x + dx, nz = z + dz;
			if(nx < 0 || nz < 0 || nx >= w - 1 || nz >= w - 1){
				// Off the world's side, with what it carried
				sediment = 0;
				break;
			}
			const float dh = m.sample(nx, nz) - here;
			const float cap = std::max(-dh, min_slope) * speed * water * capacity_k;
			if(dh > 0 || sediment > cap){
				const float put = dh > 0 ? std::min(dh, sediment) :
						(sediment - cap) * deposit_k;
				sediment -= put;
				add(x, z, put);
			} else {
				const float take = std::min((cap - sediment) * erode_k, -dh);
				sediment += take;
				const int cx = std::min(w - 2, std::max(1, ix)),
						cz = std::min(w - 2, std::max(1, iz));
				for(int bz = -1; bz <= 1; bz++)
					for(int bx = -1; bx <= 1; bx++)
						m.h[(size_t)(cz + bz) * w + cx + bx] -= take *
								(bx ? 0.5f : 1.0f) * (bz ? 0.5f : 1.0f) / 4;
			}
			speed = std::sqrt(std::max(0.0f, speed * speed - dh * gravity));
			water *= 1 - evaporate;
			x = nx, z = nz;
		}
		if(sediment > 0)
			add(std::min(x, w - 1.001f), std::min(z, w - 1.001f), sediment);
	}
}

// The heightmap: fractal noise with spreads by the world's width, the
// form's bias, then erosion. Plains: no bias.
// simplified: the rivers, lake and sea biases come in their stages; until
// then every form is plains
inline Heightmap make_heightmap(const Params &p)
{
	Heightmap m;
	m.half = p.half;
	const int w = m.width();
	m.h.assign((size_t)w * w, 0);
	const float range = (float)(p.top - p.bottom);
	const float mean = p.water_level + 0.15f * range, amp = 0.3f * range;
	const float spread = std::max(128.0f, (float)w) / 2;
	for(int z = -p.half; z < p.half; z++)
		for(int x = -p.half; x < p.half; x++)
			m.at(x, z) = mean + amp * fbm2(x / spread, z / spread, p.seed, 6, 0.45f);
	erode(m, p.seed, (size_t)(DROPLETS_PER_COLUMN * w * w));
	// Within the world: a floor of 8 under the ground, 8 of air over it
	for(float &v : m.h)
		v = std::min((float)p.top - 8, std::max((float)p.bottom + 8, v));
	return m;
}

// The water line: plains' water table, the height a WATER_SHARE of the
// columns are under (the plan's "a third up the ground's range" put half
// a 128 world under one lake; the user's plains have ponds)
inline int water_line(const Heightmap &m)
{
	std::vector<float> h = m.h;
	const size_t i = (size_t)(WATER_SHARE * (h.size() - 1));
	std::nth_element(h.begin(), h.begin() + i, h.end());
	return (int)std::floor(h[i]);
}

// A noodle cave's voxel: two 3D noises both near 0
inline bool cave(float x, float y, float z, uint32_t seed)
{
	const float a = fbm3(x / CAVE_SPREAD_XZ, y / CAVE_SPREAD_Y,
			z / CAVE_SPREAD_XZ, seed + 7001, 2, 0.5f);
	if(std::fabs(a) >= CAVE_WIDTH)
		return false;
	const float b = fbm3(x / CAVE_SPREAD_XZ, y / CAVE_SPREAD_Y,
			z / CAVE_SPREAD_XZ, seed + 9103, 2, 0.5f);
	return std::fabs(b) < CAVE_WIDTH;
}

// Whether a tree stands on the column's ground (if that is grass)
inline bool tree_at(int x, int z, uint32_t seed)
{
	return (lattice(x, 77, z, seed) + 1) * 0.5f < TREE_CHANCE;
}

// The tree: 5x6x5 round its trunk (dx, dz -2..2, dy 0..5 over the
// ground): 1 trunk, 2 leaves, 0 nothing
inline int tree_part(int dx, int dy, int dz)
{
	const int x = dx + 2, z = dz + 2;
	if(x == 2 && z == 2 && dy < 4)
		return 1;
	const bool edge = (x == 0 || x == 4) && (z == 0 || z == 4);
	const bool inner = x >= 1 && x <= 3 && z >= 1 && z <= 3;
	const bool leaf = ((dy == 2 || dy == 3) && !edge) || (dy == 4 && inner) ||
			(dy == 5 && (x == 2 || z == 2) && inner);
	return leaf ? 2 : 0;
}

} // namespace mapgen
} // namespace skeldat

#ifdef SKELDAT_MAPGEN_TEST
#include <cassert>
#include <cstdio>
#include <ctime>
int main()
{
	using namespace skeldat::mapgen;
	// The noise in -1..1, and the same twice
	for(int i = 0; i < 100000; i++){
		const float v = fbm3(i * 0.37f, i * 0.11f, i * 0.73f, 5, 3, 0.5f);
		assert(v >= -1.0001f && v <= 1.0001f);
	}
	assert(fbm2(3.3f, 4.4f, 9, 6, 0.45f) == fbm2(3.3f, 4.4f, 9, 6, 0.45f));
	// Erosion keeps the sum: a droplet's sediment is put back but for
	// what leaves the side
	{
		Params p;
		p.half = 64;
		Heightmap m;
		m.half = 64;
		m.h.assign(128 * 128, 0);
		for(int z = -64; z < 64; z++)
			for(int x = -64; x < 64; x++)
				m.at(x, z) = 20 + 15 * fbm2(x / 40.f, z / 40.f, 3, 5, 0.5f);
		double before = 0, after = 0;
		for(float v : m.h) before += v;
		float rough_before = 0, rough_after = 0;
		for(int z = -63; z < 63; z++)
			for(int x = -63; x < 63; x++)
				rough_before += std::fabs(m.at(x + 1, z) - m.at(x, z));
		erode(m, 3, 128 * 128 / 2);
		for(float v : m.h) after += v;
		for(int z = -63; z < 63; z++)
			for(int x = -63; x < 63; x++)
				rough_after += std::fabs(m.at(x + 1, z) - m.at(x, z));
		printf("mapgen: erosion: the sum %.0f -> %.0f, the roughness %.0f -> %.0f\n",
				before, after, rough_before, rough_after);
		assert(std::fabs(after - before) < 0.02 * std::fabs(before));
	}
	// The heightmap within the world at both heights, seeds 1-4, at 256
	for(int tall = 0; tall < 2; tall++)
		for(uint32_t seed = 1; seed <= 4; seed++){
			Params p;
			p.seed = seed, p.half = 128;
			p.bottom = tall ? -64 : 0, p.top = 63, p.water_level = tall ? 1 : 20;
			const clock_t t0 = clock();
			Heightmap m = make_heightmap(p);
			float lo = 1e9, hi = -1e9;
			size_t under = 0;
			for(float v : m.h)
				lo = std::min(lo, v), hi = std::max(hi, v), under += v < p.water_level;
			printf("mapgen: %s, seed %u: heights %.1f..%.1f, %.0f%% under the "
					"water line, %.0f ms\n", tall ? "128 high" : "64 high", seed, lo,
					hi, 100.0 * under / m.h.size(),
					(clock() - t0) * 1000.0 / CLOCKS_PER_SEC);
			assert(lo >= p.bottom + 8 && hi <= p.top - 8 && hi - lo > 16);
		}
	// The caves: a few percent of the rock, the same twice
	{
		size_t n = 0, all = 0;
		for(int y = -60; y < 0; y += 2)
			for(int z = 0; z < 128; z += 2)
				for(int x = 0; x < 128; x += 2)
					n += cave((float)x, (float)y, (float)z, 2), all++;
		printf("mapgen: caves %.2f%% of the voxels\n", 100.0 * n / all);
		assert(n > all / 400 && n < all / 10);
		assert(cave(10, -20, 30, 2) == cave(10, -20, 30, 2));
	}
	// The trees about TREE_CHANCE of the columns
	{
		size_t n = 0;
		for(int z = 0; z < 500; z++)
			for(int x = 0; x < 500; x++)
				n += tree_at(x, z, 2);
		printf("mapgen: trees on %.3f%% of the columns\n", n / 2500.0);
		assert(n > 250000 * TREE_CHANCE * 0.7 && n < 250000 * TREE_CHANCE * 1.3);
	}
	printf("mapgen: self test passed\n");
	return 0;
}
#endif
// vim: set noet ts=4 sw=4:
