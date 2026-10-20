// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Value noise for generators ([NOISE_API]), skeldat's as it was written
// there: a hash per lattice point, a smoothstep between them, octaves
// summed and scaled back. Header only, free functions, seeds as uint32_t.
// What Luanti's games ask for is Luanti's own noise, luanti_mapgen's
// vendored copy; this one is Buildat's.
#pragma once
#include <cmath>
#include <cstdint>
#include <vector>

namespace interface {
namespace noise {

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
// Ridged: each octave's magnitude, 0..1
inline float fbm2_abs(float x, float z, uint32_t seed, int octaves,
		float persist)
{
	float sum = 0, amp = 1, norm = 0, f = 1;
	for(int i = 0; i < octaves; i++){
		sum += std::fabs(value2(x * f, z * f, seed + (uint32_t)i * 101)) * amp;
		norm += amp, amp *= persist, f *= 2;
	}
	return sum / norm;
}
inline float fbm3_abs(float x, float y, float z, uint32_t seed, int octaves,
		float persist)
{
	float sum = 0, amp = 1, norm = 0, f = 1;
	for(int i = 0; i < octaves; i++){
		sum += std::fabs(value3(x * f, y * f, z * f,
				seed + (uint32_t)i * 101)) * amp;
		norm += amp, amp *= persist, f *= 2;
	}
	return sum / norm;
}

// fbm in world units: offset + scale * fbm(p / spread). Plain, for a
// brace list in C++11: {offset, scale, spread_x, spread_y, spread_z,
// octaves, persist}
struct NoiseParams {
	float offset, scale;
	float spread_x, spread_y, spread_z;
	int octaves;
	float persist;
};
inline float noise2(const NoiseParams &p, uint32_t seed, float x, float z)
{
	return p.offset + p.scale * fbm2(x / p.spread_x, z / p.spread_z, seed,
			p.octaves, p.persist);
}
inline float noise3(const NoiseParams &p, uint32_t seed, float x, float y,
		float z)
{
	return p.offset + p.scale * fbm3(x / p.spread_x, y / p.spread_y,
			z / p.spread_z, seed, p.octaves, p.persist);
}
// A region's values, a sample every 1 from (x0, z0), x fastest
inline void fill2(const NoiseParams &p, uint32_t seed, float x0, float z0,
		int sx, int sz, std::vector<float> &out)
{
	out.resize((size_t)sx * sz);
	size_t i = 0;
	for(int z = 0; z < sz; z++)
		for(int x = 0; x < sx; x++)
			out[i++] = noise2(p, seed, x0 + x, z0 + z);
}
// x fastest, then y, then z
inline void fill3(const NoiseParams &p, uint32_t seed, float x0, float y0,
		float z0, int sx, int sy, int sz, std::vector<float> &out)
{
	out.resize((size_t)sx * sy * sz);
	size_t i = 0;
	for(int z = 0; z < sz; z++)
		for(int y = 0; y < sy; y++)
			for(int x = 0; x < sx; x++)
				out[i++] = noise3(p, seed, x0 + x, y0 + y, z0 + z);
}

}
}
// vim: set noet ts=4 sw=4:
