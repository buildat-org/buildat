// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [SYNTH_BLOCKS]: sample buffers, curves and DSP blocks for sandboxed Lua.
// Lua builds a chain and this runs it a block at a time, so the web's
// interpreted Lua makes a few calls a sound, not one a sample.
//
// **The same samples everywhere**: a block's output for given inputs is the
// same natively and on the web, and in every release. So nothing in here
// calls libm past what IEEE makes exact (floor, ldexp, frexp): the exp, the
// log and the sine are this file's own, from + - * / alone, and the file is
// built without contracted floating point (-ffp-contract=off in
// CMakeLists.txt), so x86, ARM and WebAssembly round the same way. A change
// to a block's output is a new block or a new `version`, never an edit; the
// self-check below holds the hashes.
//
// **A trust boundary**: sandboxed code calls every function here. A buffer
// is a userdata the sandbox cannot forge, every index and length is checked
// against it, every number is checked finite and in range, and one call's
// work is bounded by the buffer cap times the oversampling cap.
#include "lua_bindings/util.h"
#include "core/log.h"
#include <tolua++.h>
#include <IO/VectorBuffer.h>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <cstdio>
#include <vector>
#include <algorithm>
#define MODULE "synth"

using namespace Urho3D;

namespace lua_bindings {
namespace synth {

// One buffer's samples and all the buffers alive: 8 MiB of floats is 47 s
// at 44100 Hz
static const size_t BUFFER_MAX = 2 * 1024 * 1024;
static const size_t TOTAL_MAX = 16 * 1024 * 1024;
static const int OVERSAMPLE_MAX = 16;
static const double RATE_MIN = 1000, RATE_MAX = 192000;
static const double DELAY_MAX = 2.0; // seconds
static size_t g_total = 0;

// The arithmetic every platform does the same

static const double LN2 = 0.69314718055994530942;

// e^x: x = k ln2 + r, |r| <= ln2/2, a series for e^r and 2^k exact
static double d_exp(double x)
{
	if(x > 700) x = 700;
	if(x < -700) return 0;
	double k = std::floor(x / LN2 + 0.5);
	double r = x - k * LN2;
	double term = 1, sum = 1;
	for(int i = 1; i < 18; i++){
		term = term * r / i;
		sum = sum + term;
	}
	return std::ldexp(sum, (int)k);
}

// ln x for x > 0: x = m 2^e, m in [0.5, 1), ln m by the atanh series
static double d_ln(double x)
{
	int e = 0;
	double m = std::frexp(x, &e);
	if(m < 0.70710678118654752){
		m = m * 2;
		e = e - 1;
	}
	double s = (m - 1) / (m + 1), s2 = s * s, term = s, sum = 0;
	for(int i = 1; i < 40; i += 2){
		sum = sum + term / i;
		term = term * s2;
	}
	return 2 * sum + e * LN2;
}

static double d_pow(double base, double exponent)
{
	return d_exp(d_ln(base) * exponent);
}

// sin(2 pi phase) from a table of a quarter wave and a line between its
// entries; the table is a Taylor series, so it is the same everywhere
static const int SINE_N = 4096;
static double g_sine[SINE_N + 1];

static void make_sine()
{
	const double PI = 3.14159265358979323846;
	for(int i = 0; i <= SINE_N; i++){
		double x = PI / 2 * i / SINE_N, x2 = x * x, term = x, sum = 0;
		for(int k = 1; k < 30; k += 2){
			sum = sum + term;
			term = -term * x2 / ((k + 1) * (k + 2));
		}
		g_sine[i] = sum;
	}
}

static double sine(double phase)
{
	phase = phase - std::floor(phase);
	double q = phase * 4;
	int quadrant = (int)q;
	double f = (q - quadrant) * SINE_N;
	if(quadrant == 1 || quadrant == 3)
		f = SINE_N - f;
	int i = (int)f;
	if(i >= SINE_N) i = SINE_N - 1;
	double v = g_sine[i] + (g_sine[i + 1] - g_sine[i]) * (f - i);
	return quadrant >= 2 ? -v : v;
}

// xorshift32, its state never 0
struct Random
{
	uint32_t x;
	explicit Random(uint32_t seed): x(seed ? seed : 0x9e3779b9u) {}
	double next() // -1 .. 1
	{
		x ^= x << 13;
		x ^= x >> 17;
		x ^= x << 5;
		return (x >> 8) * (2.0 / 16777216.0) - 1.0;
	}
};

// Reading the arguments: a refusal says which call and what

static double number_at(lua_State *L, int index, const char *what)
{
	if(lua_type(L, index) != LUA_TNUMBER)
		throw Exception(ss_("synth: ")+what+" is not a number");
	double v = lua_tonumber(L, index);
	if(!(v == v) || v > 1e30 || v < -1e30)
		throw Exception(ss_("synth: ")+what+" is not a finite number");
	return v;
}

static double in_range(double v, double lo, double hi, const char *what)
{
	if(v < lo || v > hi){
		char b[200];
		snprintf(b, sizeof b, "synth: %s is %.10g, not %.10g..%.10g", what, v, lo, hi);
		throw Exception(b);
	}
	return v;
}

static size_t whole(double v, double lo, double hi, const char *what)
{
	in_range(v, lo, hi, what);
	if(v != std::floor(v))
		throw Exception(ss_("synth: ")+what+" is not a whole number");
	return (size_t)v;
}

// A table's field without its metatable: a sandbox's table can have an
// __index that raises, and a Lua error through these C++ frames would skip
// their destructors
static void raw_field(lua_State *L, int t, const char *name)
{
	lua_pushstring(L, name);
	lua_rawget(L, t);
}

// A field of the table at index, or def when it is not there
static double field(lua_State *L, int t, const char *name, double def,
		double lo, double hi)
{
	raw_field(L, t, name);
	double v = def;
	if(!lua_isnil(L, -1))
		v = in_range(number_at(L, -1, name), lo, hi, name);
	lua_pop(L, 1);
	return v;
}

// A curve: a value over time, evaluated per sample. The spec is a number
// (constant) or a table, every rate in it per second:
//   start         the value at t 0
//   slide         added per second
//   mul           multiplied in per second (> 0)
//   accel         mul's own multiplier per second (> 0): sfxr's delta slide
//   wobble, wobble_speed  multiplied by 1 + wobble sin(2 pi speed t)
//   jumps         {{t, factor}, ...}: multiplied by factor at t
//   restart       every this many seconds back to the start, jumps too
//   min, max      the value clamped
struct Curve
{
	double start = 0, v = 0, f = 1, f0 = 1, accel = 1, slide = 0;
	double wobble = 0, wobble_inc = 0, wobble_phase = 0;
	double lo = -1e30, hi = 1e30;
	std::vector<std::pair<size_t, double>> jumps; // sample, factor
	size_t jump_i = 0;
	size_t restart = 0, k = 0;

	void read(lua_State *L, int index, double rate, const char *what)
	{
		if(lua_type(L, index) == LUA_TNUMBER){
			start = v = number_at(L, index, what);
			return;
		}
		if(lua_type(L, index) != LUA_TTABLE)
			throw Exception(ss_("synth: ")+what+" is not a number or a curve");
		int t = index;
		start = v = field(L, t, "start", 0, -1e9, 1e9);
		slide = field(L, t, "slide", 0, -1e9, 1e9) / rate;
		double mul = field(L, t, "mul", 1, 1e-6, 1e6);
		f = f0 = d_pow(mul, 1 / rate);
		double a = field(L, t, "accel", 1, 1e-6, 1e6);
		accel = d_pow(a, 1 / (rate * rate));
		wobble = field(L, t, "wobble", 0, 0, 1);
		wobble_inc = field(L, t, "wobble_speed", 0, 0, 1e4) / rate;
		lo = field(L, t, "min", -1e30, -1e30, 1e30);
		hi = field(L, t, "max", 1e30, -1e30, 1e30);
		restart = (size_t)std::floor(
				field(L, t, "restart", 0, 0, 3600) * rate + 0.5);
		raw_field(L, t, "jumps");
		if(lua_istable(L, -1)){
			int jt = lua_gettop(L);
			for(int i = 1; ; i++){
				lua_rawgeti(L, jt, i);
				if(lua_isnil(L, -1)){
					lua_pop(L, 1);
					break;
				}
				if(i > 64)
					throw Exception("synth: more than 64 jumps");
				if(!lua_istable(L, -1))
					throw Exception("synth: a jump is not {t, factor}");
				lua_rawgeti(L, -1, 1);
				double jt_s = in_range(number_at(L, -1, "a jump's t"), 0,
						3600, "a jump's t");
				lua_rawgeti(L, -2, 2);
				double jf = in_range(number_at(L, -1, "a jump's factor"),
						-1e6, 1e6, "a jump's factor");
				lua_pop(L, 3);
				jumps.push_back({(size_t)std::floor(jt_s * rate + 0.5), jf});
			}
			std::stable_sort(jumps.begin(), jumps.end(),
					[](const std::pair<size_t, double> &a,
					const std::pair<size_t, double> &b){
						return a.first < b.first;
					});
		}
		lua_pop(L, 1);
	}

	double next()
	{
		if(restart && k == restart){
			k = 0;
			v = start;
			f = f0;
			jump_i = 0;
		}
		while(jump_i < jumps.size() && jumps[jump_i].first == k)
			v = v * jumps[jump_i++].second;
		double out = v;
		if(wobble != 0){
			out = out * (1 + wobble * sine(wobble_phase));
			wobble_phase = wobble_phase + wobble_inc;
			wobble_phase = wobble_phase - std::floor(wobble_phase);
		}
		v = v * f + slide;
		f = f * accel;
		if(v > 1e9) v = 1e9;
		if(v < -1e9) v = -1e9;
		k++;
		return out < lo ? lo : out > hi ? hi : out;
	}
};

struct Buffer
{
	static constexpr const char *class_name = "buildat.SynthBuffer";
	std::vector<float> s;

	// The userdata at narg is a buffer: its metatable is this file's
	static Buffer* check(lua_State *L, int narg)
	{
		void *p = lua_touserdata(L, narg);
		if(p && lua_getmetatable(L, narg)){
			luaL_getmetatable(L, class_name);
			bool same = lua_rawequal(L, -1, -2);
			lua_pop(L, 2);
			if(same)
				return *(Buffer**)p;
		}
		throw Exception("synth: not a buffer");
	}

	// from and n of a call, checked against the buffer
	void span(lua_State *L, int i_from, int i_n, size_t *from, size_t *n)
	{
		*from = lua_isnoneornil(L, i_from) ? 0 :
				whole(number_at(L, i_from, "from"), 0, s.size(), "from");
		*n = lua_isnoneornil(L, i_n) ? s.size() - *from :
				whole(number_at(L, i_n, "n"), 0, s.size() - *from, "n");
	}

	// A block's {rate, from, n} out of its table
	void block_span(lua_State *L, int t, double *rate, size_t *from,
			size_t *n)
	{
		*rate = field(L, t, "rate", 44100, RATE_MIN, RATE_MAX);
		raw_field(L, t, "from");
		raw_field(L, t, "n");
		int top = lua_gettop(L);
		span(L, top - 1, top, from, n);
		lua_pop(L, 2);
	}
};

static int l_buffer(lua_State *L)
{
	size_t n = whole(number_at(L, 1, "a buffer's length"), 1, BUFFER_MAX,
			"a buffer's length");
	if(g_total + n > TOTAL_MAX){
		char b[200];
		snprintf(b, sizeof b, "synth: the buffers alive hold %zu samples,"
				" and %zu more is over the %zu", g_total, n, TOTAL_MAX);
		throw Exception(b);
	}
	Buffer *o = new Buffer();
	o->s.assign(n, 0.0f);
	g_total += n;
	*(Buffer**)lua_newuserdata(L, sizeof(Buffer*)) = o;
	luaL_getmetatable(L, Buffer::class_name);
	lua_setmetatable(L, -2);
	return 1;
}

static int gc_buffer(lua_State *L)
{
	Buffer *o = *(Buffer**)lua_touserdata(L, 1);
	g_total -= o->s.size();
	delete o;
	return 0;
}

static int l_len(lua_State *L)
{
	lua_pushinteger(L, Buffer::check(L, 1)->s.size());
	return 1;
}

static int l_get(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	size_t i = whole(number_at(L, 2, "i"), 0, b->s.size() - 1, "i");
	lua_pushnumber(L, b->s[i]);
	return 1;
}

static int l_set(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	size_t i = whole(number_at(L, 2, "i"), 0, b->s.size() - 1, "i");
	b->s[i] = (float)number_at(L, 3, "a sample");
	return 0;
}

static int l_clear(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	size_t from, n;
	b->span(L, 2, 3, &from, &n);
	std::fill(b->s.begin() + from, b->s.begin() + from + n, 0.0f);
	return 0;
}

// gain(g[, g_to, from, n]): multiplied by g, ramped to g_to over the span
static int l_gain(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	double g = in_range(number_at(L, 2, "gain"), -1e6, 1e6, "gain");
	double g_to = lua_isnoneornil(L, 3) ? g :
			in_range(number_at(L, 3, "gain_to"), -1e6, 1e6, "gain_to");
	size_t from, n;
	b->span(L, 4, 5, &from, &n);
	for(size_t i = 0; i < n; i++)
		b->s[from + i] = (float)(b->s[from + i] * (g + (g_to - g) * i / n));
	return 0;
}

// mix(src, src_from, dst_from, n, gain[, gain_to]): src summed in, the gain
// ramped so that a cut does not click
static int l_mix(lua_State *L)
{
	Buffer *dst = Buffer::check(L, 1);
	Buffer *src = Buffer::check(L, 2);
	size_t sf = whole(number_at(L, 3, "src_from"), 0, src->s.size(),
			"src_from");
	size_t df = whole(number_at(L, 4, "dst_from"), 0, dst->s.size(),
			"dst_from");
	size_t n = whole(number_at(L, 5, "n"), 0,
			std::min(src->s.size() - sf, dst->s.size() - df), "n");
	double g = in_range(number_at(L, 6, "gain"), -1e6, 1e6, "gain");
	double g_to = lua_isnoneornil(L, 7) ? g :
			in_range(number_at(L, 7, "gain_to"), -1e6, 1e6, "gain_to");
	if(src == dst && sf < df + n && df < sf + n)
		throw Exception("synth: mix(): a buffer into an overlapping part"
				" of itself");
	for(size_t i = 0; i < n; i++)
		dst->s[df + i] = (float)(dst->s[df + i] +
				src->s[sf + i] * (g + (g_to - g) * i / n));
	return 0;
}

// The VectorBuffer a sandbox passes: its wrapper's metatable holds the
// unsafe instance (client/core/magic_sandbox), and tolua says what that
// is, which no table the sandbox makes can pass for
static VectorBuffer* vector_buffer_at(lua_State *L, int index)
{
	VectorBuffer *vb = nullptr;
	if(lua_type(L, index) == LUA_TTABLE && lua_getmetatable(L, index)){
		raw_field(L, lua_gettop(L), "unsafe");
		tolua_Error err;
		if(tolua_isusertype(L, -1, "VectorBuffer", 0, &err))
			vb = (VectorBuffer*)tolua_tousertype(L, -1, 0);
		lua_pop(L, 2);
	}
	if(vb == nullptr)
		throw Exception("synth: not a VectorBuffer");
	return vb;
}

// to_shorts(vector_buffer[, from, n]): the samples, -1..1, as 16-bit ones
// in the VectorBuffer, replacing what was in it: what a
// BufferedSoundStream's AddData and a Sound's SetData take
static int l_to_shorts(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	VectorBuffer *vb = vector_buffer_at(L, 2);
	size_t from, n;
	b->span(L, 3, 4, &from, &n);
	vb->Clear();
	vb->Resize(n * 2);
	unsigned char *d = vb->GetModifiableData();
	for(size_t i = 0; i < n; i++){
		double v = std::floor(b->s[from + i] * 32767.0 + 0.5);
		int16_t x = (int16_t)(v < -32768 ? -32768 : v > 32767 ? 32767 : v);
		d[i * 2] = (unsigned char)(x & 0xff);
		d[i * 2 + 1] = (unsigned char)((uint16_t)x >> 8);
	}
	return 0;
}

// from_shorts(vector_buffer[, dst_from]): 16-bit samples into the buffer,
// as many as the VectorBuffer has and fit
static int l_from_shorts(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	VectorBuffer *vb = vector_buffer_at(L, 2);
	size_t df = lua_isnoneornil(L, 3) ? 0 :
			whole(number_at(L, 3, "dst_from"), 0, b->s.size(), "dst_from");
	size_t n = std::min((size_t)vb->GetSize() / 2, b->s.size() - df);
	const unsigned char *d = vb->GetData();
	for(size_t i = 0; i < n; i++){
		int16_t x = (int16_t)(uint16_t)(d[i * 2] | (d[i * 2 + 1] << 8));
		b->s[df + i] = (float)(x / 32767.0);
	}
	lua_pushinteger(L, n);
	return 1;
}

// hash() -> 16 hex digits: FNV-1a over the samples' bits
static ss_ hash_of(const std::vector<float> &s)
{
	uint64_t h = 1469598103934665603ull;
	for(float f : s){
		uint32_t u;
		memcpy(&u, &f, 4);
		for(int i = 0; i < 4; i++){
			h ^= (u >> (i * 8)) & 0xff;
			h *= 1099511628211ull;
		}
	}
	char b[17];
	snprintf(b, sizeof b, "%016llx", (unsigned long long)h);
	return b;
}

static int l_hash(lua_State *L)
{
	ss_ h = hash_of(Buffer::check(L, 1)->s);
	lua_pushlstring(L, h.c_str(), h.size());
	return 1;
}

// The blocks: buf:<block>{...}, each over {rate (44100), from, n}

static void check_table(lua_State *L, const char *block)
{
	if(!lua_istable(L, 2))
		throw Exception(ss_("synth: ")+block+"{...} takes a table");
}

// A curve field of the block's table; def when absent
static Curve curve_field(lua_State *L, const char *name, double def,
		double rate)
{
	Curve c;
	raw_field(L, 2, name);
	if(lua_isnil(L, -1))
		c.start = c.v = def;
	else
		c.read(L, lua_gettop(L), rate, name);
	lua_pop(L, 1);
	return c;
}

// osc{wave, freq, duty, oversample}: written over the span. wave is
// "square" (duty 0..1), "saw", "triangle" or "sine"; freq in Hz.
// oversample 1..16 subsamples averaged, so a square high up does not alias.
static int l_osc(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	check_table(L, "osc");
	double rate;
	size_t from, n;
	b->block_span(L, 2, &rate, &from, &n);
	raw_field(L, 2, "wave");
	ss_ wave = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
	lua_pop(L, 1);
	int w = wave == "square" ? 0 : wave == "saw" ? 1 :
			wave == "triangle" ? 2 : wave == "sine" ? 3 : -1;
	if(w < 0)
		throw Exception("synth: osc's wave is not square, saw, triangle or"
				" sine");
	int os = (int)whole(field(L, 2, "oversample", 1, 1, OVERSAMPLE_MAX), 1,
			OVERSAMPLE_MAX, "oversample");
	double phase = field(L, 2, "phase", 0, 0, 1);
	Curve freq = curve_field(L, "freq", 440, rate);
	Curve duty = curve_field(L, "duty", 0.5, rate);
	double sub_rate = rate * os;
	for(size_t i = 0; i < n; i++){
		double fr = freq.next();
		fr = fr < 0 ? 0 : fr > sub_rate / 2 ? sub_rate / 2 : fr;
		double du = duty.next();
		du = du < 0 ? 0 : du > 1 ? 1 : du;
		double inc = fr / sub_rate, sum = 0;
		for(int k = 0; k < os; k++){
			double v;
			if(w == 0) v = phase < du ? 1 : -1;
			else if(w == 1) v = 1 - 2 * phase;
			else if(w == 2) v = phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase;
			else v = sine(phase);
			sum = sum + v;
			phase = phase + inc;
			phase = phase - std::floor(phase);
		}
		b->s[from + i] = (float)(sum / os);
	}
	return 0;
}

// noise{kind, seed, freq, oversample}: "white", a new value a sample, or
// "held", sfxr's: 32 values a period of freq, each held until the next
static int l_noise(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	check_table(L, "noise");
	double rate;
	size_t from, n;
	b->block_span(L, 2, &rate, &from, &n);
	raw_field(L, 2, "kind");
	ss_ kind = lua_isstring(L, -1) ? lua_tostring(L, -1) : "white";
	lua_pop(L, 1);
	if(kind != "white" && kind != "held")
		throw Exception("synth: noise's kind is not white or held");
	Random r((uint32_t)whole(field(L, 2, "seed", 1, 0, 4294967295.0), 0,
			4294967295.0, "seed"));
	if(kind == "white"){
		for(size_t i = 0; i < n; i++)
			b->s[from + i] = (float)r.next();
		return 0;
	}
	int os = (int)whole(field(L, 2, "oversample", 1, 1, OVERSAMPLE_MAX), 1,
			OVERSAMPLE_MAX, "oversample");
	Curve freq = curve_field(L, "freq", 440, rate);
	double sub_rate = rate * os, phase = 0, held = r.next();
	int slot = 0;
	for(size_t i = 0; i < n; i++){
		double fr = freq.next();
		fr = fr < 0 ? 0 : fr > sub_rate / 64 ? sub_rate / 64 : fr;
		double inc = fr / sub_rate, sum = 0;
		for(int k = 0; k < os; k++){
			sum = sum + held;
			phase = phase + inc;
			phase = phase - std::floor(phase);
			int now = (int)(phase * 32);
			if(now != slot){
				slot = now;
				held = r.next();
			}
		}
		b->s[from + i] = (float)(sum / os);
	}
	return 0;
}

// filter{type, cutoff, resonance}: in place. A state-variable filter run
// twice a sample; type "low", "high" or "band"; cutoff in Hz, up to a fifth
// of the rate; resonance 0..1 (0.99 rings)
static int l_filter(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	check_table(L, "filter");
	double rate;
	size_t from, n;
	b->block_span(L, 2, &rate, &from, &n);
	raw_field(L, 2, "type");
	ss_ type = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
	lua_pop(L, 1);
	int t = type == "low" ? 0 : type == "high" ? 1 : type == "band" ? 2 : -1;
	if(t < 0)
		throw Exception("synth: filter's type is not low, high or band");
	Curve cutoff = curve_field(L, "cutoff", 1000, rate);
	Curve res = curve_field(L, "resonance", 0, rate);
	double low = 0, band = 0;
	for(size_t i = 0; i < n; i++){
		double fc = cutoff.next();
		fc = fc < 0 ? 0 : fc > rate / 5 ? rate / 5 : fc;
		double re = res.next();
		re = re < 0 ? 0 : re > 0.99 ? 0.99 : re;
		// 2 sin(pi fc / (2 rate)): the coefficient at the doubled rate
		double f = 2 * sine(fc / (4 * rate));
		double q = 2 * (1 - re);
		double x = b->s[from + i], high = 0;
		for(int k = 0; k < 2; k++){
			low = low + f * band;
			high = x - low - q * band;
			band = band + f * high;
		}
		if(low > 1e6) low = 1e6;
		if(low < -1e6) low = -1e6;
		if(band > 1e6) band = 1e6;
		if(band < -1e6) band = -1e6;
		b->s[from + i] = (float)(t == 0 ? low : t == 1 ? high : band);
	}
	return 0;
}

// delay{delay, max_delay, feedback, mix}: in place. delay in seconds (a
// curve, up to max_delay, at most 2); feedback -0.99..0.99; mix 0..1, the
// delayed part. A phaser, a flanger or an echo.
// simplified: the line starts empty each call; a stream processed a block
// at a time loses its tail between blocks. A delay object kept between
// calls is the upgrade when music wants one.
static int l_delay(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	check_table(L, "delay");
	double rate;
	size_t from, n;
	b->block_span(L, 2, &rate, &from, &n);
	double max_delay = field(L, 2, "max_delay", 0.5, 0, DELAY_MAX);
	double feedback = field(L, 2, "feedback", 0, -0.99, 0.99);
	double mix = field(L, 2, "mix", 0.5, 0, 1);
	Curve delay = curve_field(L, "delay", 0.1, rate);
	size_t size = (size_t)(max_delay * rate) + 2;
	std::vector<double> line(size, 0.0);
	size_t w = 0;
	for(size_t i = 0; i < n; i++){
		// At least a sample: the slot being written is not read
		double d = delay.next() * rate;
		d = d < 1 ? 1 : d > size - 2 ? size - 2 : d;
		size_t di = (size_t)d;
		double fr = d - di;
		size_t r0 = (w + size - di) % size, r1 = (w + size - di - 1) % size;
		double x = b->s[from + i];
		double delayed = line[r0] + (line[r1] - line[r0]) * fr;
		line[w] = x + delayed * feedback;
		w = (w + 1) % size;
		b->s[from + i] = (float)(x * (1 - mix) + delayed * mix);
	}
	return 0;
}

// envelope{points = {{t, v}, ...}}: multiplied in, linear between the
// points (t in seconds, ascending), the first before them and the last
// after
static int l_envelope(lua_State *L)
{
	Buffer *b = Buffer::check(L, 1);
	check_table(L, "envelope");
	double rate;
	size_t from, n;
	b->block_span(L, 2, &rate, &from, &n);
	std::vector<std::pair<double, double>> p;
	raw_field(L, 2, "points");
	if(!lua_istable(L, -1))
		throw Exception("synth: envelope's points is not a table");
	int pt = lua_gettop(L);
	for(int i = 1; ; i++){
		lua_rawgeti(L, pt, i);
		if(lua_isnil(L, -1)){
			lua_pop(L, 1);
			break;
		}
		if(i > 256)
			throw Exception("synth: more than 256 envelope points");
		if(!lua_istable(L, -1))
			throw Exception("synth: an envelope point is not {t, v}");
		lua_rawgeti(L, -1, 1);
		double t = in_range(number_at(L, -1, "a point's t"), 0, 3600,
				"a point's t");
		lua_rawgeti(L, -2, 2);
		double v = in_range(number_at(L, -1, "a point's v"), -1e6, 1e6,
				"a point's v");
		lua_pop(L, 3);
		if(!p.empty() && t * rate < p.back().first)
			throw Exception("synth: envelope points are not in order of t");
		p.push_back({t * rate, v});
	}
	lua_pop(L, 1);
	if(p.empty())
		throw Exception("synth: an envelope without points");
	size_t j = 0;
	for(size_t i = 0; i < n; i++){
		double s = (double)i;
		while(j + 1 < p.size() && p[j + 1].first <= s)
			j++;
		double v;
		if(s <= p[0].first) v = p[0].second;
		else if(j + 1 >= p.size()) v = p.back().second;
		else v = p[j].second + (p[j + 1].second - p[j].second) *
				(s - p[j].first) / (p[j + 1].first - p[j].first);
		b->s[from + i] = (float)(b->s[from + i] * v);
	}
	return 0;
}

// The self-check: every block and curve feature at fixed inputs, hashed.
// The hashes are the promise above; one that moves is a block whose output
// changed, which is a new block and not an edit. Logged, not asserted: a
// client that disagrees still runs, and util/synth_check.sh reads the line
// natively and on the web.
static const char *EXPECTED[][2] = {
	{"osc square", "d84a62b419967753"},
	{"osc saw", "798100d9e93e9339"},
	{"osc triangle", "af5d83f490d0e635"},
	{"osc sine", "5c75960b058149fe"},
	{"noise white", "fec4d9a405db44cb"},
	{"noise held", "6799232b2be7f15d"},
	{"filter low", "94755856887d2b3a"},
	{"filter high", "b90d4755f0922097"},
	{"filter band", "fe7b7ac2b29d0c9f"},
	{"delay", "3e247bf82a9cc20b"},
	{"envelope", "8f5f42cafab7c447"},
	{"mix gain", "85684895068aacfe"},
};

static const char *SELF_CHECK_LUA =
	"local b = __buildat_synth_buffer\n"
	"local function run(f) local x = b(4096); f(x); return x:hash() end\n"
	"local curve = {start = 220, mul = 3, accel = 0.5, slide = 40,\n"
	"	wobble = 0.1, wobble_speed = 6, jumps = {{0.03, 1.5}},\n"
	"	restart = 0.07, min = 50, max = 4000}\n"
	"local duty = {start = 0.2, slide = 4, max = 0.8}\n"
	"local function src(x) x:osc{wave = 'saw', freq = curve} end\n"
	"return {\n"
	" run(function(x) x:osc{wave = 'square', freq = curve, duty = duty,\n"
	"	oversample = 8} end),\n"
	" run(function(x) x:osc{wave = 'saw', freq = curve, oversample = 4} end),\n"
	" run(function(x) x:osc{wave = 'triangle', freq = curve, rate = 22050}"
	" end),\n"
	" run(function(x) x:osc{wave = 'sine', freq = curve, phase = 0.25} end),\n"
	" run(function(x) x:noise{kind = 'white', seed = 7} end),\n"
	" run(function(x) x:noise{kind = 'held', seed = 7, freq = curve,\n"
	"	oversample = 2} end),\n"
	" run(function(x) src(x) x:filter{type = 'low', cutoff = {start = 3000,\n"
	"	mul = 0.1}, resonance = 0.6} end),\n"
	" run(function(x) src(x) x:filter{type = 'high', cutoff = 800,\n"
	"	resonance = {start = 0, slide = 9}} end),\n"
	" run(function(x) src(x) x:filter{type = 'band', cutoff = 1200} end),\n"
	" run(function(x) src(x) x:delay{delay = {start = 0.002, wobble = 0.5,\n"
	"	wobble_speed = 3}, max_delay = 0.01, feedback = 0.6, mix = 0.5} end),\n"
	" run(function(x) src(x) x:envelope{points = {{0, 0}, {0.01, 1},\n"
	"	{0.05, 0.4}, {0.09, 0}}} end),\n"
	" run(function(x) local y = b(1000) y:osc{wave = 'sine', freq = 300}\n"
	"	src(x) x:gain(0.5, 1, 100, 3000) x:mix(y, 10, 2000, 900, 1, 0) end),\n"
	"}\n";

static void self_check(lua_State *L)
{
	if(luaL_loadstring(L, SELF_CHECK_LUA) != 0 || lua_pcall(L, 0, 1, 0) != 0){
		log_e(MODULE, "synth self-check: %s", lua_tostring(L, -1));
		lua_pop(L, 1);
		return;
	}
	int bad = 0;
	size_t n = sizeof EXPECTED / sizeof EXPECTED[0];
	for(size_t i = 0; i < n; i++){
		lua_rawgeti(L, -1, (int)i + 1);
		ss_ got = lua_isstring(L, -1) ? lua_tostring(L, -1) : "?";
		lua_pop(L, 1);
		if(got != EXPECTED[i][1]){
			log_e(MODULE, "synth self-check: %s hashes %s, not %s",
					EXPECTED[i][0], got.c_str(), EXPECTED[i][1]);
			bad++;
		}
	}
	lua_pop(L, 1);
	lua_gc(L, LUA_GCCOLLECT, 0);
	if(bad == 0)
		log_i(MODULE, "synth self-check: ok, %zu hashes", n);
}

} // namespace synth

void init_synth(lua_State *L)
{
	using namespace synth;
	make_sine();
	luaL_newmetatable(L, Buffer::class_name);
	int mt = lua_gettop(L);
	// The sandbox gets the userdata itself: getmetatable() on it says
	// nothing, and the methods are reached only by name
	lua_pushliteral(L, "__metatable");
	lua_pushboolean(L, 0);
	lua_settable(L, mt);
	lua_pushliteral(L, "__gc");
	lua_pushcfunction(L, gc_buffer);
	lua_settable(L, mt);
	lua_newtable(L);
#define SYNTH_METHOD(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setfield(L, -2, #name); \
}
	SYNTH_METHOD(len);
	SYNTH_METHOD(get);
	SYNTH_METHOD(set);
	SYNTH_METHOD(clear);
	SYNTH_METHOD(gain);
	SYNTH_METHOD(mix);
	SYNTH_METHOD(to_shorts);
	SYNTH_METHOD(from_shorts);
	SYNTH_METHOD(hash);
	SYNTH_METHOD(osc);
	SYNTH_METHOD(noise);
	SYNTH_METHOD(filter);
	SYNTH_METHOD(delay);
	SYNTH_METHOD(envelope);
#undef SYNTH_METHOD
	lua_setfield(L, mt, "__index");
	lua_pop(L, 1);
	lua_pushcfunction(L, guarded<l_buffer>);
	lua_setglobal(L, "__buildat_synth_buffer");
	self_check(L);
}

} // namespace lua_bindings

// vim: set noet ts=4 sw=4:
