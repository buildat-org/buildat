// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// The maths car.h uses, one implementation for the server's native build
// and the clients' .wasm ([CLIENT_WASM] step 5), so the car's step gives
// the same bits on both: a libm's sinf is its own (glibc's, Emscripten's
// and MinGW's differ in the last bit now and then), and a .wasm has none.
// sqrt, floor, ceil and fabs are exact everywhere (an instruction, or a
// libm's exact one); fmin and fmax are comparisons. The rest is worked in
// double to well under a float's ulp and rounded once, so it is the
// correctly rounded float but for an input whose true value is within
// ~1e-16 of halfway between two floats. Measured against long double's
// rounded, every float in [0, 2] (2026-10-27): sin, cos and tan none
// off, atan one. glibc 2.42's (what the server's car used before) differ
// from these on 730109 of the 1.06e9 floats in [0, 0.6] for sinf (0.07%),
// 15988 for cosf, none for tanf and one for atanf: a steering angle on
// one of those turns its wheel by a float's last bit differently.
// simplified: the argument reduction of sin, cos and tan is two-part
// Cody-Waite in double, good for |x| up to ~1e5 (the car's are under 1);
// past it Payne-Hanek's is the upgrade.
#pragma once

namespace car_math {

static inline float sqrtf_(float x){ return __builtin_sqrtf(x); }
static inline float fabsf_(float x){ return __builtin_fabsf(x); }
static inline float floorf_(float x){ return __builtin_floorf(x); }
static inline float ceilf_(float x){ return __builtin_ceilf(x); }
static inline double floor_(double x){ return __builtin_floor(x); }
static inline double fabs_(double x){ return __builtin_fabs(x); }
// No NaN in the car; a signed zero may come out as the other one
static inline float fminf_(float a, float b){ return b < a ? b : a; }
static inline float fmaxf_(float a, float b){ return b > a ? b : a; }

// sin and cos of r, |r| <= pi/4, by their series to r^19 (the next term
// under 2e-19)
static inline double sin_poly(double r)
{
	const double r2 = r * r;
	double s = 1.0 / 121645100408832000.0; // 1/19!
	s = s * -r2 + 1.0 / 355687428096000.0;
	s = s * -r2 + 1.0 / 1307674368000.0;
	s = s * -r2 + 1.0 / 6227020800.0;
	s = s * -r2 + 1.0 / 39916800.0;
	s = s * -r2 + 1.0 / 362880.0;
	s = s * -r2 + 1.0 / 5040.0;
	s = s * -r2 + 1.0 / 120.0;
	s = s * -r2 + 1.0 / 6.0;
	return r - r * r2 * s;
}
static inline double cos_poly(double r)
{
	const double r2 = r * r;
	double c = 1.0 / 6402373705728000.0; // 1/18!
	c = c * -r2 + 1.0 / 20922789888000.0;
	c = c * -r2 + 1.0 / 87178291200.0;
	c = c * -r2 + 1.0 / 479001600.0;
	c = c * -r2 + 1.0 / 3628800.0;
	c = c * -r2 + 1.0 / 40320.0;
	c = c * -r2 + 1.0 / 720.0;
	c = c * -r2 + 1.0 / 24.0;
	c = c * -r2 + 0.5;
	return 1.0 - r2 * c;
}
// x as k quarter turns and r, |r| <= pi/4 (a little over at the seams)
static inline double reduce(float x, int &k)
{
	const double PIO2_HI = 1.57079632673412561417e+00; // 33 bits of pi/2
	const double PIO2_LO = 6.07710050650619224932e-11; // the rest
	const double q = floor_((double)x * 0.63661977236758134308 + 0.5);
	k = (int)q;
	return ((double)x - q * PIO2_HI) - q * PIO2_LO;
}
static inline float sinf_(float x)
{
	if(fabsf_(x) <= 0.78539816f)
		return (float)sin_poly(x);
	int k;
	const double r = reduce(x, k);
	switch(k & 3){
	case 0: return (float)sin_poly(r);
	case 1: return (float)cos_poly(r);
	case 2: return (float)-sin_poly(r);
	default: return (float)-cos_poly(r);
	}
}
static inline float cosf_(float x)
{
	if(fabsf_(x) <= 0.78539816f)
		return (float)cos_poly(x);
	int k;
	const double r = reduce(x, k);
	switch(k & 3){
	case 0: return (float)cos_poly(r);
	case 1: return (float)-sin_poly(r);
	case 2: return (float)-cos_poly(r);
	default: return (float)sin_poly(r);
	}
}
static inline float tanf_(float x)
{
	int k = 0;
	const double r = fabsf_(x) <= 0.78539816f ? (double)x : reduce(x, k);
	const double s = sin_poly(r), c = cos_poly(r);
	return (float)(k & 1 ? -c / s : s / c);
}
// atan of u, |u| <= tan(pi/8), by its series to u^45 (the next term under
// 1e-19)
static inline double atan_poly(double u)
{
	const double u2 = u * u;
	double a = 0;
	for(int n = 45; n >= 3; n -= 2)
		a = a * -u2 + 1.0 / n;
	return u - u * u2 * a;
}
static inline float atanf_(float x)
{
	const double PIO4 = 0.78539816339744830962, PIO2 = 1.57079632679489661923;
	const double TAN_PIO8 = 0.41421356237309504880;
	double t = fabs_(x), base = 0, sign = 1;
	// Past 1: pi/2 - atan(1/t); then past tan(pi/8): pi/4 + atan of the
	// difference's tangent
	if(t > 1){
		t = 1 / t;
		base = PIO2;
		sign = -1;
	}
	double a;
	if(t > TAN_PIO8)
		a = PIO4 + atan_poly((t - 1) / (t + 1));
	else
		a = atan_poly(t);
	const double r = base + sign * a;
	return (float)(x < 0 ? -r : r);
}
// The remainder of x / y, exact (as every fmod is): q*y and x - q*y are
// exact in double while |x / y| < 2^29.
// simplified: past that the remainder is off; the car's spin is under
// 2 * 2 pi
static inline float fmodf_(float x, float y)
{
	const double dx = x, dy = fabs_(y);
	double q = floor_(fabs_(dx) / dy);
	double r = fabs_(dx) - q * dy;
	if(r < 0)
		r += dy;
	else if(r >= dy)
		r -= dy;
	return (float)(dx < 0 ? -r : r);
}

} // namespace car_math
