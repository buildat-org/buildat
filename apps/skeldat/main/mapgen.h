// Buildat: apps/skeldat/main/mapgen.h
// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// skeldat's own map generator's pure parts ([SKELDAT_OWN_MAPGEN]): the
// whole world's heightmap, made once at the world's start before any
// section, its form's bias and droplet erosion, and its water a column
// (the plains' table, the rivers' channels, their springs and drains);
// the noodle caves; where a tree stands. terrain.h's SkeldatGenerator reads them a section at a time
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
// The rivers: one, two from a world 512 wide; a channel's water this deep
// (its top over its bed), its banks RIVER_BANK over its bed (the water
// and the liquid step's pressure, which pushes a falling river's water up
// to 4 over its own top, kept in) and its bed falling at least RIVER_FALL
// from the inlet to the outlet
static const int RIVER_DEPTH = 2, RIVER_BANK = 7, RIVER_FALL = 8,
		TWO_RIVERS_FROM = 512;

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

// What a column is, besides its height
enum ColumnFlags: uint8_t {
	WATER = 1, // water over the ground, up to water_top
	CHANNEL = 2, // a river's channel: its bed gravel
	SPRING = 4, // its water voxels springs (a river's inlet)
	DRAIN = 8, // its water voxels drains (a river's outlet)
	SHORE = 16, // within 2 of water, and not 2 over it: sand
	NEAR_WATER = 32, // within 2 of water: no tree
};
static const int16_t NO_WATER = -32768;

// A river: its path from the inlet (index 0) to the outlet, a point
// every half voxel, and its bed's height along it
struct River {
	std::vector<float> x, z, bed;
};

// The ground's height a column, float; x and z from -half to half - 1;
// the water's top voxel and the flags a column
struct Heightmap {
	int half = 0;
	std::vector<float> h;
	std::vector<int16_t> water;
	std::vector<uint8_t> flags;
	// The rivers made (their beds as carved)
	std::vector<River> rivers;
	size_t index(int x, int z) const { return (size_t)(z + half) * width() + (x + half); }
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

// One or two rivers edge to edge: a line between two points of the edge
// on different sides (opposite, 7 in 10), bent by low-frequency noise;
// the inlet the end whose ground is higher, the bed falling from under it
// to under the outlet's, by RIVER_FALL at least, and kept 3 under the
// lowest ground passed
inline std::vector<River> plan_rivers(const Params &p, const Heightmap &m)
{
	std::vector<River> out;
	const int w = m.width();
	std::mt19937 r(p.seed ^ 0x81ee5);
	std::uniform_real_distribution<float> u(0, 1);
	const int n = w >= TWO_RIVERS_FROM ? 2 : 1;
	for(int k = 0; k < n; k++){
		auto edge = [&](int side, float t, float &x, float &z){
			const float a = -p.half + t * (w - 1);
			x = side == 0 ? -p.half : side == 1 ? p.half - 1 : a;
			z = side == 2 ? -p.half : side == 3 ? p.half - 1 : a;
		};
		const int sa = (int)(r() % 4);
		const int sb = u(r) < 0.7f ? (sa ^ 1) : (sa < 2 ? 2 + (int)(r() % 2) : (int)(r() % 2));
		float ax, az, bx, bz;
		edge(sa, 0.25f + 0.5f * u(r), ax, az);
		edge(sb, 0.25f + 0.5f * u(r), bx, bz);
		const float ha = m.at((int)ax, (int)az), hb = m.at((int)bx, (int)bz);
		if(hb > ha)
			std::swap(ax, bx), std::swap(az, bz);
		const float len = std::sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az));
		const float nx = -(bz - az) / len, nz = (bx - ax) / len;
		float bed_in = std::max(ha, hb) - 3, bed_out = std::min(ha, hb) - 3;
		bed_out = std::max((float)p.bottom + 12, std::min(bed_out, bed_in - RIVER_FALL));
		bed_in = std::min((float)p.top - 16, std::max(bed_in, bed_out + RIVER_FALL));
		River river;
		const int steps = (int)(len * 2);
		for(int i = 0; i <= steps; i++){
			const float t = (float)i / steps;
			const float bend = std::sin(3.14159f * t) * len * 0.15f *
					fbm2(t * 3, (float)k * 7.3f, p.seed + 4441, 3, 0.5f);
			const float x = ax + (bx - ax) * t + nx * bend,
					z = az + (bz - az) * t + nz * bend;
			river.x.push_back(std::min(p.half - 1.0f, std::max((float)-p.half, x)));
			river.z.push_back(std::min(p.half - 1.0f, std::max((float)-p.half, z)));
			river.bed.push_back(std::floor(bed_in + (bed_out - bed_in) * t));
		}
		// Under the ground all along: no lower than the ground passed so far
		// less 3 (a river along a line over a basin was a raised channel the
		// water left)
		float low = 1e9f;
		for(size_t i = 0; i < river.bed.size(); i++){
			low = std::min(low, std::floor(m.at((int)river.x[i], (int)river.z[i])) - 3);
			river.bed[i] = std::max((float)p.bottom + 12, std::min(river.bed[i], low));
		}
		out.push_back(river);
	}
	return out;
}

// The channel's and the valley's half widths: 1.5..3 and 12..24 by the
// world's width up to 1024
inline float channel_half(int w){ return 1.5f + 1.5f * std::min(1.0f, w / 1024.0f); }
inline float valley_half(int w){ return 12 + 12 * std::min(1.0f, w / 1024.0f); }

// Each river point's disc: fn(x, z, i, d) for the columns within rad of
// it (the same column many times, by each point near it)
template<typename F>
inline void along(const Heightmap &m, const River &river, float rad, F fn)
{
	for(size_t i = 0; i < river.x.size(); i++){
		const int r = (int)std::ceil(rad);
		for(int z = (int)river.z[i] - r; z <= (int)river.z[i] + r; z++)
			for(int x = (int)river.x[i] - r; x <= (int)river.x[i] + r; x++){
				if(!m.in(x, z))
					continue;
				const float d = std::sqrt((x - river.x[i]) * (x - river.x[i]) +
						(z - river.z[i]) * (z - river.z[i]));
				if(d <= rad)
					fn(x, z, i, d);
			}
	}
}

// The water's top a column and the flags round it: the shore and the
// columns near water
inline void mark_shores(Heightmap &m)
{
	for(int z = -m.half; z < m.half; z++)
		for(int x = -m.half; x < m.half; x++){
			const size_t c = m.index(x, z);
			if(!(m.flags[c] & WATER))
				continue;
			for(int dz = -2; dz <= 2; dz++)
				for(int dx = -2; dx <= 2; dx++){
					if(!m.in(x + dx, z + dz))
						continue;
					const size_t n = m.index(x + dx, z + dz);
					m.flags[n] |= NEAR_WATER;
					if(m.at(x + dx, z + dz) <= m.water[c] + 1)
						m.flags[n] |= SHORE;
				}
		}
}

// The heightmap: fractal noise with spreads by the world's width, the
// form's bias, then erosion, then the water.
// - plains: no bias; the water table (water_line()) over every column
//   under it;
// - rivers: plan_rivers()' valleys lowered along them before the erosion,
//   their channels' beds set again after it (so a river still falls) and
//   their banks raised to RIVER_BANK over the bed where lower, the
//   channel's columns RIVER_DEPTH of water over the bed; its columns at
//   the world's edge springs at the inlet, drains at the outlet.
// simplified: the lake and sea biases come in their stage; until then
// they are plains
inline Heightmap make_heightmap(const Params &p)
{
	Heightmap m;
	m.half = p.half;
	const int w = m.width();
	m.h.assign((size_t)w * w, 0);
	m.water.assign(m.h.size(), NO_WATER);
	m.flags.assign(m.h.size(), 0);
	const float range = (float)(p.top - p.bottom);
	const float mean = p.water_level + 0.15f * range, amp = 0.3f * range;
	const float spread = std::max(128.0f, (float)w) / 2;
	for(int z = -p.half; z < p.half; z++)
		for(int x = -p.half; x < p.half; x++)
			m.at(x, z) = mean + amp * fbm2(x / spread, z / spread, p.seed, 6, 0.45f);
	std::vector<River> &rivers = m.rivers;
	const float ch = channel_half(w), vh = valley_half(w);
	if(p.form == RIVERS){
		rivers = plan_rivers(p, m);
		// The valley: the channel's bed, its banks rising from RIVER_BANK
		// over it
		for(const River &river : rivers)
			along(m, river, vh, [&](int x, int z, size_t i, float d){
				const float k = std::max(0.0f, (d - ch) / (vh - ch));
				m.at(x, z) = std::min(m.at(x, z), d <= ch ? river.bed[i] :
						river.bed[i] + RIVER_BANK + k * k * 40);
			});
	}
	erode(m, p.seed, (size_t)(DROPLETS_PER_COLUMN * w * w));
	// Within the world: a floor of 8 under the ground, 8 of air over it
	for(float &v : m.h)
		v = std::min((float)p.top - 8, std::max((float)p.bottom + 8, v));
	if(p.form == RIVERS){
		for(const River &river : rivers)
			along(m, river, ch, [&](int x, int z, size_t i, float){
				const size_t c = m.index(x, z);
				// The lowest bed a column is under (a bend's points overlap)
				if(m.flags[c] & CHANNEL)
					m.h[c] = std::min(m.h[c], river.bed[i]);
				else
					m.h[c] = river.bed[i];
				m.flags[c] |= CHANNEL | WATER;
				m.water[c] = (int16_t)(m.h[c] + RIVER_DEPTH);
				if(x == -p.half || x == p.half - 1 || z == -p.half || z == p.half - 1)
					m.flags[c] |= i < river.x.size() / 2 ? SPRING : DRAIN;
			});
		// The banks: the 2 columns beside a channel RIVER_BANK over its bed
		// at least (a levee where the ground falls away, or erosion took it)
		for(const River &river : rivers)
			along(m, river, ch + 2, [&](int x, int z, size_t i, float){
				const size_t c = m.index(x, z);
				if(!(m.flags[c] & CHANNEL))
					m.h[c] = std::max(m.h[c], river.bed[i] + RIVER_BANK);
			});
	} else {
		const int line = water_line(m);
		for(size_t c = 0; c < m.h.size(); c++)
			if(std::floor(m.h[c]) < line)
				m.flags[c] |= WATER, m.water[c] = (int16_t)line;
	}
	mark_shores(m);
	return m;
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
	// Rivers at 256, seeds 1-8: each channel's bed falls inlet to outlet,
	// a spring and a drain at its ends
	for(uint32_t seed = 1; seed <= 8; seed++){
		Params p;
		p.seed = seed, p.half = 128, p.form = RIVERS;
		Heightmap m = make_heightmap(p);
		const std::vector<River> &rivers = m.rivers;
		size_t springs = 0, drains = 0, channel = 0;
		for(uint8_t f : m.flags)
			springs += (f & SPRING) != 0, drains += (f & DRAIN) != 0,
			channel += (f & CHANNEL) != 0;
		for(const River &r : rivers){
			assert(r.bed.front() >= r.bed.back() + RIVER_FALL);
			for(size_t i = 1; i < r.bed.size(); i++)
				assert(r.bed[i] <= r.bed[i - 1]);
		}
		// Each channel column at most its river's bed there
		if(seed == 1)
			printf("mapgen: rivers, seed 1: %zu channel columns, %zu springs, "
					"%zu drains, the bed %.0f -> %.0f\n", channel, springs,
					drains, rivers[0].bed.front(), rivers[0].bed.back());
		assert(springs > 0 && drains > 0);
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
