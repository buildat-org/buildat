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
// where both noises are within it of 0: [SKELDAT_CAVES_ROOMY] a voxel's
// own, CAVE_WIDTH_MIN..MAX by a slow noise) and the spreads of their
// noises; the chance of a tree on a grass column; the plains' water
static const float DROPLETS_PER_COLUMN = 0.5f;
static const int DROPLET_STEPS = 48;
static const float CAVE_WIDTH_MIN = 0.035f, CAVE_WIDTH_MAX = 0.085f,
		CAVE_WIDTH_SPREAD = 90, CAVE_SPREAD_XZ = 80, CAVE_SPREAD_Y = 48;
// [SKELDAT_CAVES_ROOMY] The caverns: where a noise of these spreads is
// over CAVERN_THRESHOLD, in a band from CAVERN_FLOOR over the world's
// bottom to CAVERN_DEPTH under the ground, the threshold raised by
// CAVERN_TAPER_RISE over the band's top and bottom CAVERN_TAPER (closed
// before its ends). The numbers are the playtests' to correct (the user).
static const float CAVERN_SPREAD_XZ = 64, CAVERN_SPREAD_Y = 32,
		CAVERN_THRESHOLD = 0.4f, CAVERN_TAPER_RISE = 0.4f;
static const int CAVERN_FLOOR = 4, CAVERN_DEPTH = 12, CAVERN_TAPER = 6;
static const float TREE_CHANCE = 0.006f;
// The plains' water table: the height this share of the columns is under
static const float WATER_SHARE = 0.1f;
// The flat form (mostly for checks): its ground this far over the base
// water line, no tree within FLAT_TREE_CLEAR of the origin, no cave
// within FLAT_CAVE_ROOF under the ground
static const int FLAT_OVER_WATER = 4, FLAT_TREE_CLEAR = 24, FLAT_CAVE_ROOF = 4;
// The rivers: one, two from a world 512 wide; a channel's water this deep
// (its top over its bed), its banks RIVER_BANK over its bed (the water's
// top 1 under the ground beside: [SKELDAT_LOW_BANKS], an overflow where
// the liquid step's pressure pushes it over is fine) and its bed falling
// at least RIVER_FALL from the inlet to the outlet
static const int RIVER_DEPTH = 2, RIVER_BANK = RIVER_DEPTH + 1, RIVER_FALL = 8,
		TWO_RIVERS_FROM = 512;
// [SKELDAT_RIVER_RIFFLES] Riffles: where a noise along a river's path is
// over RIFFLE_THRESHOLD the bed rises to RIFFLE_UNDER under the water's
// intended top; the noise's spread from the rivers' whole length, about
// RIFFLES_PER_MAP on the map; none within RIFFLE_END of a river's ends.
// simplified: the rise all or nothing (RIVER_DEPTH 2 leaves one voxel to
// rise); a deeper river would want it to follow the noise
static const float RIFFLES_PER_MAP = 3, RIFFLE_THRESHOLD = 0.35f;
static const int RIFFLE_UNDER = 1, RIFFLE_END = 16;
// The lake: its bed SEA_DEPTH under the line at the middle; the edge
// raised but for LAKE_GAP of the perimeter. The sea: the edge's
// SEA_ZONE of the half width pushed to SEA_DEPTH under the line, an
// island forced a side ISLAND_FROM..+12 off the edge, a spring on one
// island in SPRING_ONE_IN over SPRING_ISLAND columns
static const int SEA_DEPTH = 8, ISLAND_FROM = 26, SPRING_ONE_IN = 4,
		SPRING_ISLAND = 64;
// The sea's bone start: its islands within SEA_BONES of the edge
static const int SEA_BONES = 48;
static const float LAKE_GAP = 0.125f, SEA_ZONE = 0.35f;
// The sea's and the lake's land at most this over its lowest neighbour
// (the water line the floor): [SKELDAT_COASTS], a walkable shore
static const float SHORE_SLOPE = 0.7f;

enum Form { RIVERS, PLAINS, LAKE, SEA, FLAT };
static const char *FORM_NAMES[] = {"rivers", "plains", "lake", "sea", "flat"};
inline int form_of(const std::string &name)
{
	for(int i = 0; i < 5; i++)
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
	LEVEL_DRAIN = 64, // the voxel over its water a drain (the sea's edge)
};
static const int16_t NO_WATER = -32768;

// A river: its path from the inlet (index 0) to the outlet, a point
// every half voxel, and its bed's height along it
struct River {
	std::vector<float> x, z, bed;
	// [SKELDAT_RIVER_RIFFLES] The noise's spread, and a riffle under the
	// point (on the path's line)
	float riffle_spread = 1;
	std::vector<uint8_t> riffle;
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

// [SKELDAT_RIVER_RIFFLES] Whether the river k's channel rises d off its
// path at the point i: the noise along the path (half a voxel a point), a
// little of d in it for an uneven crest
inline bool riffle_at(const River &r, int k, size_t i, float d, uint32_t seed)
{
	const float s = i * 0.5f;
	if(s < RIFFLE_END || s > (r.x.size() - 1) * 0.5f - RIFFLE_END)
		return false;
	return value2(s / r.riffle_spread, 0.5f + 0.08f * d, seed + 6007 +
			(uint32_t)k * 31) > RIFFLE_THRESHOLD;
}
// The spread: one-octave value noise is over the threshold in runs about
// q (1 - q) a lattice cell, q its share over it; 1.4 more for the ends
// left out and the runs that merge (a mean of 3.08 riffles over 36 maps
// measured, 1 to 6 a map)
inline void plan_riffles(std::vector<River> &rivers, uint32_t seed)
{
	float len = 0;
	for(const River &r : rivers)
		len += (r.x.size() - 1) * 0.5f;
	const float q = (1 - RIFFLE_THRESHOLD) / 2;
	for(size_t k = 0; k < rivers.size(); k++){
		River &r = rivers[k];
		r.riffle_spread = len * q * (1 - q) / RIFFLES_PER_MAP / 1.4f;
		r.riffle.assign(r.x.size(), 0);
		for(size_t i = 0; i < r.x.size(); i++)
			r.riffle[i] = riffle_at(r, (int)k, i, 0, seed);
	}
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
// form's bias, then erosion, a blur and (sea, lake) a slope limit, then
// the water.
// - plains: no bias; the water table (water_line()) over every column
//   under it;
// - rivers: plan_rivers()' valleys lowered along them before the erosion,
//   their channels' beds set again after it (so a river still falls) and
//   their banks raised to RIVER_BANK over the bed where lower, the
//   channel's columns RIVER_DEPTH of water over the bed; its columns at
//   the world's edge springs at the inlet, drains at the outlet.
// - lake: the middle pushed under the water line within a radius
//   shifted by noise, islands where two noises are over their
//   thresholds; the edge raised but for a gap
//   of LAKE_GAP of the perimeter; the water every column under the line
//   joined to the middle;
// - sea: all of it SEA_DEPTH under the line but the islands, large and
//   small by thresholds of two noises (fewer in the edge's SEA_ZONE,
//   none in its outer 6), and one a side forced near the edge; the water every column under the line
//   joined to the edge, the edge's columns level drains over it; a spring
//   on the highest column of some islands.
// - flat: one height, FLAT_OVER_WATER over the base water line; no
//   erosion and no water.
inline void bias_lake(const Params &p, Heightmap &m, float mean, float amp)
{
	const int w = m.width();
	std::mt19937 r(p.seed ^ 0x1a4e);
	const float gap_at = std::uniform_real_distribution<float>(0, 1)(r);
	const float line = (float)p.water_level;
	for(int z = -p.half; z < p.half; z++)
		for(int x = -p.half; x < p.half; x++){
			float &h = m.at(x, z);
			// [SKELDAT_COASTS] A radius shifted by noise: arms, bays and
			// peninsulas
			const float rr = std::sqrt((float)x * x + (float)z * z) / p.half;
			const float v = 0.65f - rr + 0.8f * fbm2(x / 45.0f, z / 45.0f,
					p.seed + 91, 4, 0.55f);
			const float k = std::max(0.0f, std::min(1.0f, v / 0.15f));
			h -= k * k * (3 - 2 * k) * (mean - line + SEA_DEPTH + 0.3f * amp);
			// Islands in it, larger and small
			const float big = fbm2(x / 40.0f, z / 40.0f, p.seed + 79, 3, 0.5f),
					small = fbm2(x / 14.0f, z / 14.0f, p.seed + 78, 2, 0.5f);
			if(v > 0.12f && big > 0.3f)
				h = std::max(h, line + 1 + (big - 0.3f) * 30);
			if(v > 0.12f && small > 0.6f)
				h = std::max(h, line + 1 + (small - 0.6f) * 30);
			// The edge's lift, but in the gap: the perimeter's coordinate
			const int e = std::min(std::min(x + p.half, p.half - 1 - x),
					std::min(z + p.half, p.half - 1 - z));
			const float s = (x == -p.half || z == p.half - 1) ?
					0.25f * (z + p.half) / w + (x == -p.half ? 0.0f : 0.25f) :
					std::atan2((float)z, (float)x) / 6.2832f + 0.5f;
			const float d = std::fabs(std::fmod(s - gap_at + 1.5f, 1.0f) - 0.5f);
			if(d > LAKE_GAP / 2 && e < w / 8)
				h += 12.0f * (1 - (float)e / (w / 8));
		}
}

inline void bias_sea(const Params &p, Heightmap &m)
{
	const int w = m.width();
	const float line = (float)p.water_level, bed = line - SEA_DEPTH;
	for(int z = -p.half; z < p.half; z++)
		for(int x = -p.half; x < p.half; x++){
			float &h = m.at(x, z);
			const int e = std::min(std::min(x + p.half, p.half - 1 - x),
					std::min(z + p.half, p.half - 1 - z));
			// The land: islands where either noise is over its threshold,
			// fewer toward the edge's SEA_ZONE and none in its outer 6
			const float big = fbm2(x / 60.0f, z / 60.0f, p.seed + 77, 3, 0.5f),
					small = fbm2(x / 16.0f, z / 16.0f, p.seed + 78, 2, 0.5f);
			const float zone = std::max(0.0f, 1 - e / (SEA_ZONE * p.half));
			float land = std::max((big - 0.1f - 0.2f * zone) / 0.25f,
					(small - 0.45f) / 0.2f);
			land = e <= 6 ? 0 : std::max(0.0f, std::min(1.0f, land));
			const float k = land * land * (3 - 2 * land);
			// The seabed a little uneven, the land its own height
			h = (bed + (h - line) * 0.1f) * (1 - k) +
					std::max(h, line + 2 + 6 * k) * k;
		}
	// One island a side, forced
	std::mt19937 r(p.seed ^ 0x15a1);
	std::uniform_real_distribution<float> u(0, 1);
	for(int side = 0; side < 4; side++){
		const float along = -p.half + (0.2f + 0.6f * u(r)) * w,
				off = ISLAND_FROM + 12 * u(r), rad = 8 + 6 * u(r);
		const float cx = side == 0 ? -p.half + off : side == 1 ? p.half - 1 - off : along,
				cz = side == 2 ? -p.half + off : side == 3 ? p.half - 1 - off : along;
		for(int z = (int)(cz - rad); z <= (int)(cz + rad); z++)
			for(int x = (int)(cx - rad); x <= (int)(cx + rad); x++){
				if(!m.in(x, z))
					continue;
				const float d = std::sqrt((x - cx) * (x - cx) + (z - cz) * (z - cz));
				if(d < rad)
					m.at(x, z) = std::max(m.at(x, z), line + 2 + 5 * (1 - d / rad));
			}
	}
}

// Every column under the line joined (4 ways) to the seeds: water to the
// line
inline void flood(Heightmap &m, int line, std::vector<size_t> todo)
{
	for(size_t c : todo)
		m.flags[c] |= WATER, m.water[c] = (int16_t)line;
	const int w = m.width();
	while(!todo.empty()){
		const size_t c = todo.back();
		todo.pop_back();
		const int x = (int)(c % w), z = (int)(c / w);
		const int nx[4] = {x + 1, x - 1, x, x}, nz[4] = {z, z, z + 1, z - 1};
		for(int i = 0; i < 4; i++){
			if(nx[i] < 0 || nz[i] < 0 || nx[i] >= w || nz[i] >= w)
				continue;
			const size_t n = (size_t)nz[i] * w + nx[i];
			if((m.flags[n] & WATER) || std::floor(m.h[n]) >= line)
				continue;
			m.flags[n] |= WATER, m.water[n] = (int16_t)line;
			todo.push_back(n);
		}
	}
}

// The sea's islands: a spring on the highest column of one in
// SPRING_ONE_IN of those over SPRING_ISLAND columns
inline size_t island_springs(Heightmap &m, int line, uint32_t seed)
{
	const int w = m.width();
	std::vector<uint8_t> seen(m.h.size(), 0);
	std::mt19937 r(seed ^ 0x5915);
	size_t springs = 0;
	for(size_t c0 = 0; c0 < m.h.size(); c0++){
		if(seen[c0] || std::floor(m.h[c0]) < line)
			continue;
		std::vector<size_t> todo = {c0};
		seen[c0] = 1;
		size_t n = 0, top = c0;
		while(!todo.empty()){
			const size_t c = todo.back();
			todo.pop_back();
			n++;
			if(m.h[c] > m.h[top])
				top = c;
			const int x = (int)(c % w), z = (int)(c / w);
			const int nx[4] = {x + 1, x - 1, x, x}, nz[4] = {z, z, z + 1, z - 1};
			for(int i = 0; i < 4; i++){
				if(nx[i] < 0 || nz[i] < 0 || nx[i] >= w || nz[i] >= w)
					continue;
				const size_t k = (size_t)nz[i] * w + nx[i];
				if(!seen[k] && std::floor(m.h[k]) >= line)
					seen[k] = 1, todo.push_back(k);
			}
		}
		if(n > (size_t)SPRING_ISLAND && r() % SPRING_ONE_IN == 0){
			m.flags[top] |= WATER | SPRING;
			m.water[top] = (int16_t)(std::floor(m.h[top]) + 1);
			springs++;
		}
	}
	return springs;
}

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
			m.at(x, z) = p.form == FLAT ? p.water_level + FLAT_OVER_WATER + 0.5f :
					mean + amp * fbm2(x / spread, z / spread, p.seed, 6, 0.45f);
	std::vector<River> &rivers = m.rivers;
	const float ch = channel_half(w), vh = valley_half(w);
	if(p.form == RIVERS){
		rivers = plan_rivers(p, m);
		plan_riffles(rivers, p.seed);
		// The valley: the channel's bed, its banks rising from RIVER_BANK
		// over it
		for(const River &river : rivers)
			along(m, river, vh, [&](int x, int z, size_t i, float d){
				const float k = std::max(0.0f, (d - ch) / (vh - ch));
				m.at(x, z) = std::min(m.at(x, z), d <= ch ? river.bed[i] :
						river.bed[i] + RIVER_BANK + k * k * 40);
			});
	}
	if(p.form == LAKE)
		bias_lake(p, m, mean, amp);
	if(p.form == SEA)
		bias_sea(p, m);
	if(p.form != FLAT)
		erode(m, p.seed, (size_t)(DROPLETS_PER_COLUMN * w * w));
	// [SKELDAT_COASTS] One 3x3 blur (1 2 1): the erosion's sub-voxel
	// ripples out of the contours, its change to the ground kept
	{
		const std::vector<float> eroded = m.h;
		for(int z = -p.half; z < p.half; z++)
			for(int x = -p.half; x < p.half; x++){
				float sum = 0, n = 0;
				for(int dz = -1; dz <= 1; dz++)
					for(int dx = -1; dx <= 1; dx++){
						if(!m.in(x + dx, z + dz))
							continue;
						const float k = (float)((2 - std::abs(dx)) * (2 - std::abs(dz)));
						sum += k * eroded[m.index(x + dx, z + dz)], n += k;
					}
				m.at(x, z) = sum / n;
			}
	}
	// The erosion's specks out: each column clamped into the min..max of
	// its four neighbours (a single cell's sub-voxel bump or pit rounds to
	// a voxel), what it carved kept (a blur would soften the channels)
	const std::vector<float> eroded = m.h;
	for(int z = -p.half; z < p.half; z++)
		for(int x = -p.half; x < p.half; x++){
			float lo = 1e9f, hi = -1e9f;
			for(int i = 0; i < 4; i++){
				const int nx = x + (i == 0) - (i == 1), nz = z + (i == 2) - (i == 3);
				if(!m.in(nx, nz))
					continue;
				lo = std::min(lo, eroded[m.index(nx, nz)]);
				hi = std::max(hi, eroded[m.index(nx, nz)]);
			}
			m.at(x, z) = std::min(hi, std::max(lo, m.at(x, z)));
		}
	// [SKELDAT_COASTS] The sea's and the lake's land no more than
	// SHORE_SLOPE over its lowest neighbour, a column under the line
	// counted at it: chamfer passes both ways until nothing changes
	// simplified: islands become cones and plateaus of that slope, no
	// cliff on them; a limit within some columns of the water alone is the
	// upgrade if the inland is wanted rougher
	if(p.form == SEA || p.form == LAKE)
		for(bool changed = true; changed;){
			changed = false;
			for(int pass = 0; pass < 2; pass++)
				for(int i = 0; i < w * w; i++){
					const int j = pass ? w * w - 1 - i : i;
					const int x = j % w - p.half, z = j / w - p.half;
					float lo = 1e9f;
					for(int d = 0; d < 4; d++){
						const int nx = x + (d == 0) - (d == 1), nz = z + (d == 2) - (d == 3);
						if(m.in(nx, nz))
							lo = std::min(lo, std::max((float)p.water_level, m.at(nx, nz)));
					}
					if(m.at(x, z) > lo + SHORE_SLOPE + 1e-4f)
						m.at(x, z) = lo + SHORE_SLOPE, changed = true;
				}
		}
	// Within the world: a floor of 8 under the ground, 8 of air over it
	for(float &v : m.h)
		v = std::min((float)p.top - 8, std::max((float)p.bottom + 8, v));
	if(p.form == RIVERS){
		// [SKELDAT_RIVER_RIFFLES] A channel column's riffle by its nearest
		// point, raised after its water top is set
		std::vector<float> near(m.h.size(), 1e9f);
		std::vector<uint8_t> rise(m.h.size(), 0);
		for(size_t k = 0; k < rivers.size(); k++)
			along(m, rivers[k], ch, [&](int x, int z, size_t i, float d){
				const size_t c = m.index(x, z);
				if(d < near[c])
					near[c] = d, rise[c] = riffle_at(rivers[k], (int)k, i, d, p.seed);
			});
		for(const River &river : rivers)
			along(m, river, ch, [&](int x, int z, size_t i, float){
				const size_t c = m.index(x, z);
				// The lowest bed a column is under (a bend's points overlap)
				if(m.flags[c] & CHANNEL)
					m.h[c] = std::min(m.h[c], river.bed[i]);
				else
					m.h[c] = river.bed[i];
				m.flags[c] |= CHANNEL | WATER;
				m.water[c] = (int16_t)std::floor(m.h[c] + RIVER_DEPTH);
				if(x == -p.half || x == p.half - 1 || z == -p.half || z == p.half - 1)
					m.flags[c] |= i < river.x.size() / 2 ? SPRING : DRAIN;
			});
		// The banks: the 2 columns beside a channel RIVER_BANK over the
		// highest bed passing (over every bed of the channel columns beside
		// it, whose points are within its reach), a levee where the ground
		// falls away or erosion took it, cut down where its sediment raised
		// it ([SKELDAT_LOW_BANKS])
		std::vector<float> bank(m.h.size(), -1e9f);
		for(const River &river : rivers)
			along(m, river, ch + 2, [&](int x, int z, size_t i, float){
				const size_t c = m.index(x, z);
				if(!(m.flags[c] & CHANNEL))
					bank[c] = std::max(bank[c], river.bed[i] + RIVER_BANK);
			});
		for(size_t c = 0; c < m.h.size(); c++)
			if(bank[c] > -1e9f)
				m.h[c] = bank[c];
		for(size_t c = 0; c < m.h.size(); c++)
			if(rise[c])
				m.h[c] = m.water[c] - RIFFLE_UNDER;
	} else if(p.form == LAKE || p.form == SEA){
		const int line = p.water_level;
		std::vector<size_t> seeds;
		if(p.form == LAKE){
			// The middle's lowest column within a sixth of the width
			size_t low = m.index(0, 0);
			for(int z = -w / 6; z < w / 6; z++)
				for(int x = -w / 6; x < w / 6; x++)
					if(m.at(x, z) < m.h[low])
						low = m.index(x, z);
			if(std::floor(m.h[low]) < line)
				seeds.push_back(low);
		} else {
			for(int a = -p.half; a < p.half; a++)
				for(size_t c : {m.index(a, -p.half), m.index(a, p.half - 1),
						m.index(-p.half, a), m.index(p.half - 1, a)})
					if(std::floor(m.h[c]) < line)
						seeds.push_back(c);
		}
		flood(m, line, seeds);
		if(p.form == SEA){
			for(int a = -p.half; a < p.half; a++)
				for(size_t c : {m.index(a, -p.half), m.index(a, p.half - 1),
						m.index(-p.half, a), m.index(p.half - 1, a)})
					if(m.flags[c] & WATER)
						m.flags[c] |= LEVEL_DRAIN;
			island_springs(m, line, p.seed);
		}
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
// [SKELDAT_CAVES_ROOMY] The tunnels' width at a voxel from its noise
// (cave_width_noise()): squeezes and wider stretches along a tunnel
inline float cave_width_noise(float x, float y, float z, uint32_t seed)
{
	return fbm3(x / CAVE_WIDTH_SPREAD, y / CAVE_WIDTH_SPREAD,
			z / CAVE_WIDTH_SPREAD, seed + 333, 2, 0.5f);
}
inline float cave_width(float n)
{
	return (CAVE_WIDTH_MIN + CAVE_WIDTH_MAX) / 2 + (CAVE_WIDTH_MAX -
			CAVE_WIDTH_MIN) / 2 * std::max(-1.0f, std::min(1.0f, 2 * n));
}
inline bool cave(float x, float y, float z, uint32_t seed)
{
	const float a = fbm3(x / CAVE_SPREAD_XZ, y / CAVE_SPREAD_Y,
			z / CAVE_SPREAD_XZ, seed + 7001, 2, 0.5f);
	if(std::fabs(a) >= CAVE_WIDTH_MAX)
		return false;
	const float w = cave_width(cave_width_noise(x, y, z, seed));
	if(std::fabs(a) >= w)
		return false;
	const float b = fbm3(x / CAVE_SPREAD_XZ, y / CAVE_SPREAD_Y,
			z / CAVE_SPREAD_XZ, seed + 9103, 2, 0.5f);
	return std::fabs(b) < w;
}
// [SKELDAT_CAVES_ROOMY] The caverns' noise, and its threshold at y in a
// column of ground g over a world from bottom (over 1 outside the band:
// none)
inline float cavern_noise(float x, float y, float z, uint32_t seed)
{
	return fbm3(x / CAVERN_SPREAD_XZ, y / CAVERN_SPREAD_Y,
			z / CAVERN_SPREAD_XZ, seed + 4441, 3, 0.5f);
}
inline float cavern_threshold(int y, int bottom, int g)
{
	const int lo = bottom + CAVERN_FLOOR, hi = g - CAVERN_DEPTH;
	if(y < lo || y > hi)
		return 2;
	const float d = (float)std::min(y - lo, hi - y);
	return CAVERN_THRESHOLD + CAVERN_TAPER_RISE * std::max(0.0f, 1 - d / CAVERN_TAPER);
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

// [SKELDAT_APPLE_TREES] Whether the tree on a column is an apple tree, one
// in share
inline bool apple_tree_at(int x, int z, uint32_t seed, int share)
{
	return (int)((lattice(x, 78, z, seed) + 1) * 0.5f * share) == 0;
}

// An apple tree's apples: 3 to 6 of the leaves on its crown's outside (its
// lower two layers, the outer ring but the corners, a side open to air),
// the ones whose hash is lowest for the tree at (tx, tz)
inline bool tree_fruit(int tx, int tz, uint32_t seed, int dx, int dy, int dz)
{
	auto outer = [](int dx, int dy, int dz){
		return (dy == 2 || dy == 3) && (std::abs(dx) == 2 || std::abs(dz) == 2) &&
				tree_part(dx, dy, dz) == 2;
	};
	if(!outer(dx, dy, dz))
		return false;
	auto h = [&](int dx, int dy, int dz){
		return lattice(tx * 8 + dx, 79 + dy, tz * 8 + dz, seed);
	};
	const int count = 3 + (int)((lattice(tx, 80, tz, seed) + 1) * 0.5f * 4) % 4;
	const float mine = h(dx, dy, dz);
	int below = 0;
	for(int y = 2; y <= 3; y++)
		for(int z = -2; z <= 2; z++)
			for(int x = -2; x <= 2; x++)
				below += outer(x, y, z) && h(x, y, z) < mine;
	return below < count;
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
	setvbuf(stdout, nullptr, _IONBF, 0);
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
	// Flat: one height, dry
	{
		Params p;
		p.seed = 1, p.half = 128, p.form = FLAT;
		const Heightmap m = make_heightmap(p);
		for(size_t c = 0; c < m.h.size(); c++)
			assert(m.h[c] == m.h[0] && !(m.flags[c] & WATER));
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
		// [SKELDAT_LOW_BANKS] A channel column's water top 1 under the
		// lowest ground beside it (its non-channel neighbours) or more, on
		// 95% of those that have one
		size_t low = 0, one = 0, sided = 0;
		for(int z = -128; z < 128; z++)
			for(int x = -128; x < 128; x++){
				if(!(m.flags[m.index(x, z)] & CHANNEL))
					continue;
				int beside = 1 << 30;
				for(int i = 0; i < 4; i++){
					const int nx = x + (i == 0) - (i == 1), nz = z + (i == 2) - (i == 3);
					if(m.in(nx, nz) && !(m.flags[m.index(nx, nz)] & CHANNEL))
						beside = std::min(beside, (int)std::floor(m.at(nx, nz)));
				}
				if(beside == 1 << 30)
					continue;
				sided++;
				low += m.water[m.index(x, z)] <= beside - 1;
				one += m.water[m.index(x, z)] == beside - 1;
			}
		if(seed <= 4)
			printf("mapgen: rivers, seed %u: the water 1 under the bank or more "
					"on %.1f%% of %zu bank columns, just 1 on %.1f%%\n", seed,
					100.0 * low / sided, sided, 100.0 * one / sided);
		assert(seed > 4 || low >= sided * 95 / 100);
		if(seed == 1)
			printf("mapgen: rivers, seed 1: %zu channel columns, %zu springs, "
					"%zu drains, the bed %.0f -> %.0f\n", channel, springs,
					drains, rivers[0].bed.front(), rivers[0].bed.back());
		assert(springs > 0 && drains > 0);
	}
	// [SKELDAT_RIVER_RIFFLES] Rivers at 128, 256 and 1024, seeds 1-4: 1 to
	// 6 riffles on a map and 2.5 to 4 on the mean, none at the ends, their
	// columns' ground RIFFLE_UNDER under the water's top
	size_t riffles = 0;
	for(int half : {64, 128, 512})
		for(uint32_t seed = 1; seed <= 4; seed++){
			Params p;
			p.seed = seed, p.half = half, p.form = RIVERS;
			const Heightmap m = make_heightmap(p);
			size_t n = 0, raised = 0;
			for(const River &r : m.rivers){
				for(size_t i = 0; i < r.riffle.size(); i++)
					n += r.riffle[i] && (i == 0 || !r.riffle[i - 1]);
				assert(!r.riffle.front() && !r.riffle.back());
			}
			for(size_t c = 0; c < m.h.size(); c++)
				if((m.flags[c] & CHANNEL) && std::floor(m.h[c]) == m.water[c] - RIFFLE_UNDER)
					raised++;
			printf("mapgen: rivers at %d, seed %u: %zu riffles, %zu columns\n",
					2 * half, seed, n, raised);
			assert(n >= 1 && n <= 6 && raised > 0);
			riffles += n;
		}
	assert(riffles >= 30 && riffles <= 48);
	// A sea's edge columns water over 90% of the perimeter, a lake's dry
	// over 7/8, at 256, seeds 1-4
	for(int form : {LAKE, SEA})
		for(uint32_t seed = 1; seed <= 4; seed++){
			Params p;
			p.seed = seed, p.half = 128, p.form = form;
			Heightmap m = make_heightmap(p);
			size_t wet = 0, all = 0, water = 0, springs = 0;
			for(int a = -128; a < 128; a++)
				for(size_t c : {m.index(a, -128), m.index(a, 127),
						m.index(-128, a), m.index(127, a)})
					wet += (m.flags[c] & WATER) != 0, all++;
			for(uint8_t f : m.flags)
				water += (f & WATER) != 0, springs += (f & SPRING) != 0;
			printf("mapgen: %s, seed %u: the edge %.0f%% wet, %.0f%% of the "
					"columns water, %zu springs\n", FORM_NAMES[form], seed,
					100.0 * wet / all, 100.0 * water / m.flags.size(), springs);
			if(form == SEA)
				assert(wet >= all * 9 / 10);
			else
				assert(wet <= all / 8 && water > m.flags.size() / 20);
		}
	// [SKELDAT_COASTS] Sea and lake at 256, seeds 1-4, both heights: no
	// land column within 4 of water a step of 2 or more over a land
	// neighbour (one at the line or over: a dry hollow under it is a pit
	// the limit does not see, as its floor is the line); the lake 15-45% water, its outer shore (islands filled,
	// an 8-voxel cell water when half its columns are) 1.4 times a
	// circle's of its area at least
	for(int form : {SEA, LAKE})
		for(uint32_t seed = 1; seed <= 4; seed++)
			for(bool tall : {true, false}){
				Params p;
				p.seed = seed, p.half = 128, p.form = form;
				p.bottom = tall ? -64 : 0, p.water_level = tall ? 1 : 20;
				const Heightmap m = make_heightmap(p);
				const int w = m.width();
				auto wet = [&](int x, int z){ return (m.flags[m.index(x, z)] & WATER) != 0; };
				size_t steep = 0, shore = 0, water = 0;
				for(int z = -128; z < 128; z++)
					for(int x = -128; x < 128; x++){
						water += wet(x, z);
						if(wet(x, z))
							continue;
						bool near = false;
						for(int dz = -4; dz <= 4 && !near; dz++)
							for(int dx = -4; dx <= 4 && !near; dx++)
								near = m.in(x + dx, z + dz) && wet(x + dx, z + dz);
						if(!near)
							continue;
						shore++;
						const int h = (int)std::floor(m.at(x, z));
						bool s = false;
						for(int d = 0; d < 4; d++){
							const int nx = x + (d == 0) - (d == 1), nz = z + (d == 2) - (d == 3);
							s = s || (m.in(nx, nz) && !wet(nx, nz) &&
									m.at(nx, nz) >= p.water_level &&
									h - (int)std::floor(m.at(nx, nz)) >= 2);
						}
						steep += s;
					}
				float ratio = 0;
				if(form == LAKE){
					// The 8-voxel cells, water joined to the edge-free
					// outside filled: what the outside does not reach is
					// the lake's, islands and all
					const int C = 8, n = w / C;
					std::vector<char> cell((size_t)n * n, 0), out((size_t)n * n, 0);
					for(int cz = 0; cz < n; cz++)
						for(int cx = 0; cx < n; cx++){
							int k = 0;
							for(int z = 0; z < C; z++)
								for(int x = 0; x < C; x++)
									k += wet(cx * C + x - 128, cz * C + z - 128);
							cell[(size_t)cz * n + cx] = k * 2 >= C * C;
						}
					std::vector<int> todo;
					for(int a = 0; a < n; a++)
						for(int c : {a, (n - 1) * n + a, a * n, a * n + n - 1})
							if(!cell[c] && !out[c])
								out[c] = 1, todo.push_back(c);
					while(!todo.empty()){
						const int c = todo.back();
						todo.pop_back();
						const int cx = c % n, cz = c / n;
						for(int d = 0; d < 4; d++){
							const int nx = cx + (d == 0) - (d == 1), nz = cz + (d == 2) - (d == 3);
							if(nx < 0 || nz < 0 || nx >= n || nz >= n)
								continue;
							const int k = nz * n + nx;
							if(!cell[k] && !out[k])
								out[k] = 1, todo.push_back(k);
						}
					}
					size_t area = 0, edges = 0;
					for(int cz = 0; cz < n; cz++)
						for(int cx = 0; cx < n; cx++){
							if(out[(size_t)cz * n + cx])
								continue;
							area++;
							for(int d = 0; d < 4; d++){
								const int nx = cx + (d == 0) - (d == 1), nz = cz + (d == 2) - (d == 3);
								edges += nx < 0 || nz < 0 || nx >= n || nz >= n ||
										out[(size_t)nz * n + nx];
							}
						}
					ratio = area ? edges / (2 * std::sqrt(3.14159f * area)) : 0;
				}
				printf("mapgen: %s, seed %u, %s: %zu of %zu shore columns steep, "
						"%.0f%% water, the shore %.2f a circle's\n", FORM_NAMES[form],
						seed, tall ? "tall" : "short", steep, shore,
						100.0 * water / m.h.size(), ratio);
				assert(steep == 0);
				if(form == LAKE)
					assert(water * 100 >= m.h.size() * 15 && water * 100 <= m.h.size() * 45 &&
							ratio >= 1.4f);
			}
	// [SKELDAT_COASTS] Contours: a plains column's floor over or under both
	// its x neighbours' (a wobble) on 1% of the columns at most, at 256,
	// seeds 1-3: measured 2026-10-19 unblurred 2.9-3.6%, blurred 0.44-0.69%
	// (the plan's count read 1.28-1.44 and 0.18-0.28)
	for(uint32_t seed = 1; seed <= 3; seed++){
		Params p;
		p.seed = seed, p.half = 128;
		const Heightmap m = make_heightmap(p);
		size_t wobbles = 0;
		for(int z = -128; z < 128; z++)
			for(int x = -127; x < 127; x++){
				const int h = (int)std::floor(m.at(x, z)),
						a = (int)std::floor(m.at(x - 1, z)), b = (int)std::floor(m.at(x + 1, z));
				wobbles += (h > a && h > b) || (h < a && h < b);
			}
		printf("mapgen: plains, seed %u: wobbles on %.2f%% of the columns\n",
				seed, 100.0 * wobbles / m.h.size());
		assert(wobbles * 100 <= m.h.size());
	}
	// No specks: a plains column's voxel over or under all its four
	// neighbours' is a ridge's or a pit's end, rare
	{
		Params p;
		p.seed = 1, p.half = 128;
		const Heightmap m = make_heightmap(p);
		size_t specks = 0;
		for(int z = -p.half + 1; z < p.half - 1; z++)
			for(int x = -p.half + 1; x < p.half - 1; x++){
				const int h = (int)std::floor(m.at(x, z));
				int over = 0, under = 0;
				for(int i = 0; i < 4; i++){
					const int n = (int)std::floor(m.at(x + (i == 0) - (i == 1),
							z + (i == 2) - (i == 3)));
					over += h > n, under += h < n;
				}
				specks += over == 4 || under == 4;
			}
		printf("mapgen: plains, seed 1: %zu specks\n", specks);
		assert(specks < (size_t)m.width() * m.width() / 1000);
	}
	// [SKELDAT_CAVES_ROOMY] The tunnels, a 256 x 48 x 256 block at seeds
	// 1-3: the rock hollowed 1-5%, their floor (a cave voxel on solid) 3
	// wide (its narrower run of x and z) and 3 high on 55% of it or more.
	// Measured 2026-10-19: 1.46-3.99%, 64-79% (the old caves 1.4-2.5%,
	// 20-27%; the plan's 0.04-0.10 hollowed 2.0-5.6%, so the widths are
	// 0.035-0.085 to keep the rock about as it was)
	for(uint32_t seed = 1; seed <= 3; seed++){
		const int W = 256, H = 48;
		std::vector<char> v((size_t)W * H * W);
		auto at = [&](int x, int y, int z) -> char & {
			return v[((size_t)z * H + y) * W + x];
		};
		size_t hollow = 0;
		for(int z = 0; z < W; z++)
			for(int y = 0; y < H; y++)
				for(int x = 0; x < W; x++)
					hollow += at(x, y, z) = cave((float)x, (float)y - 60, (float)z, seed);
		size_t floor = 0, roomy = 0;
		for(int z = 1; z < W - 1; z++)
			for(int y = 1; y < H - 1; y++)
				for(int x = 1; x < W - 1; x++){
					if(!at(x, y, z) || at(x, y - 1, z))
						continue;
					floor++;
					auto run = [&](int dx, int dy, int dz){
						int n = 1;
						for(int s : {-1, 1})
							for(int i = 1;; i++){
								const int a = x + s * dx * i, b = y + s * dy * i, c = z + s * dz * i;
								if(a < 0 || b < 0 || c < 0 || a >= W || b >= H || c >= W ||
										!at(a, b, c))
									break;
								n++;
							}
						return n;
					};
					roomy += std::min(run(1, 0, 0), run(0, 0, 1)) >= 3 && run(0, 1, 0) >= 3;
				}
		printf("mapgen: caves, seed %u: %.2f%% of the rock, their floor 3 wide "
				"and 3 high on %.0f%%\n", seed, 100.0 * hollow / v.size(),
				100.0 * roomy / floor);
		assert(hollow * 100 >= v.size() && hollow * 100 <= v.size() * 5 &&
				roomy * 100 >= floor * 55);
	}
	// [SKELDAT_CAVES_ROOMY] The caverns, a band 40 high (the ground well
	// over it) 256 across at seeds 1-3: 0.7-10% of it, 4 rooms of 500
	// voxels or more. Measured 2026-10-19 at seeds 1-3: 2.65, 7.35, 1.32%,
	// the largest rooms 44k, 148k, 19k voxels (the lowest octave, 64
	// across, sets the share; at 0.45, seeds 1-8: 0.7-6%)
	for(uint32_t seed = 1; seed <= 3; seed++){
		const int W = 256, H = 40, bottom = -64;
		std::vector<char> v((size_t)W * H * W);
		auto idx = [&](int x, int y, int z){ return ((size_t)z * H + y) * W + x; };
		size_t n = 0;
		for(int z = 0; z < W; z++)
			for(int y = 0; y < H; y++)
				for(int x = 0; x < W; x++){
					const int wy = bottom + CAVERN_FLOOR + y;
					n += v[idx(x, y, z)] = cavern_noise((float)x, (float)wy, (float)z, seed) >
							cavern_threshold(wy, bottom, bottom + CAVERN_FLOOR + H - 1 + CAVERN_DEPTH);
				}
		size_t rooms = 0, largest = 0;
		std::vector<size_t> todo;
		for(size_t i = 0; i < v.size(); i++){
			if(v[i] != 1)
				continue;
			size_t size = 0;
			todo.assign(1, i), v[i] = 2;
			while(!todo.empty()){
				const size_t c = todo.back();
				todo.pop_back(), size++;
				const int x = (int)(c % W), y = (int)(c / W % H), z = (int)(c / W / H);
				for(int d = 0; d < 6; d++){
					const int a = x + (d == 0) - (d == 1), b = y + (d == 2) - (d == 3),
							e = z + (d == 4) - (d == 5);
					if(a < 0 || b < 0 || e < 0 || a >= W || b >= H || e >= W ||
							v[idx(a, b, e)] != 1)
						continue;
					v[idx(a, b, e)] = 2, todo.push_back(idx(a, b, e));
				}
			}
			rooms += size >= 500, largest = std::max(largest, size);
		}
		printf("mapgen: caverns, seed %u: %.2f%% of the band, %zu rooms of 500 "
				"voxels or more, the largest %zu\n", seed, 100.0 * n / v.size(),
				rooms, largest);
		assert(n * 1000 >= v.size() * 7 && n * 10 <= v.size() && rooms >= 4);
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
	// [SKELDAT_APPLE_TREES] About one tree in 4 an apple tree, each with 3
	// to 6 apples on its crown's outside
	{
		size_t apple = 0, all = 0, fruit_min = 99, fruit_max = 0;
		for(int z = 0; z < 2000; z += 3)
			for(int x = 0; x < 2000; x += 3){
				if(!tree_at(x, z, 2))
					continue;
				all++;
				if(!apple_tree_at(x, z, 2, 4))
					continue;
				apple++;
				size_t f = 0;
				for(int dy = 0; dy < 6; dy++)
					for(int dz = -2; dz <= 2; dz++)
						for(int dx = -2; dx <= 2; dx++)
							f += tree_fruit(x, z, 2, dx, dy, dz);
				fruit_min = std::min(fruit_min, f), fruit_max = std::max(fruit_max, f);
			}
		printf("mapgen: %zu of %zu trees apple trees, %zu to %zu apples each\n",
				apple, all, fruit_min, fruit_max);
		assert(apple * 5 > all && apple * 3 < all && fruit_min == 3 && fruit_max == 6);
	}
	printf("mapgen: self test passed\n");
	return 0;
}
#endif
// vim: set noet ts=4 sw=4:
