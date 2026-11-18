// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [MUSIC_SYNTH] jam, the music engine (interface/jam.h): a port of the
// approved prototype (local/music_proto's synth.lua and seq.lua, kit_plan
// 4z37d), its voices and effects as they were, sample by sample in blocks
// of 256.
//
// **The same samples everywhere**: nothing here calls libm past what IEEE
// makes exact (floor, frexp, ldexp, sqrt); sines, exp2 and log2 come from
// this file's tables, made by series at the first use, and the file is built
// without contracted floating point (-ffp-contract=off in CMakeLists.txt).
// Denormals are flushed by hand where a tail decays (wasm has no
// flush-to-zero, so the code does it the same everywhere). The jam1 hashes
// are in util/jam_check.sh; a change that moves them is a jam2.
//
// **A trust boundary**: the text is a builder's, parsed on every client and
// on the server. Every number is read by this file's own parser (no locale),
// checked against its range, and the song's size, events and voices are
// capped, so no text makes the engine slow, unbounded or undefined.
#include "interface/jam.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>

namespace interface {
namespace jam {

static const int BLOCK = 256;
static const size_t MAX_VOICES = 64; // simplified: a new note past it is not played
static const size_t MAX_TRACKS = 32, MAX_INSTS = 64, MAX_PATTERNS = 512,
		MAX_EVENTS = 60000, MAX_LANE = 4096, MAX_NOTES = 8, MAX_CHORD = 8;
static const double MAX_SECONDS = 1800; // a song's play order

// ---- The arithmetic every platform does the same

static const double PI = 3.14159265358979323846, TAU = 2 * PI;
static const double LN2 = 0.69314718055994530942;
static const double LOG2_10 = 3.32192809488736234787;

// e^x: x = k ln2 + r, a series for e^r and 2^k exact (synth.cpp's)
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

// ln x for x > 0 by the atanh series (synth.cpp's)
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

static double d_pow(double b, double e)
{
	if(b <= 0)
		return 0;
	return d_exp(d_ln(b) * e);
}

// sin x for setup (biquads, pan): x reduced to -pi..pi, a series
static double d_sin(double x)
{
	x = x - TAU * std::floor(x / TAU + 0.5);
	double x2 = x * x, term = x, sum = 0;
	for(int k = 1; k < 30; k += 2){
		sum = sum + term;
		term = -term * x2 / ((k + 1) * (k + 2));
	}
	return sum;
}
static double d_cos(double x) { return d_sin(x + PI / 2); }

// The tables, made once: a quarter sine, 2^f over 0..1, log2 over 1..2
static const int TN = 4096;
struct Tables
{
	double sine[TN + 1], ex2[TN + 1], lg2[TN + 1];
	Tables()
	{
		for(int i = 0; i <= TN; i++){
			sine[i] = d_sin(PI / 2 * i / TN);
			ex2[i] = d_exp(LN2 * i / TN);
			lg2[i] = d_ln(1 + (double)i / TN) / LN2;
		}
	}
};
static const Tables &tables()
{
	static const Tables t;
	return t;
}
static const Tables &T = tables();

// sin(2 pi ph)
static inline double sin_ph(double ph)
{
	ph = ph - std::floor(ph);
	double q = ph * 4;
	int quadrant = (int)q;
	double f = (q - quadrant) * TN;
	if(quadrant == 1 || quadrant == 3)
		f = TN - f;
	int i = (int)f;
	if(i >= TN) i = TN - 1;
	if(i < 0) i = 0;
	double v = T.sine[i] + (T.sine[i + 1] - T.sine[i]) * (f - i);
	return quadrant >= 2 ? -v : v;
}

static inline double exp2_(double x)
{
	if(x > 1000) x = 1000;
	if(x < -1000) return 0;
	double k = std::floor(x);
	double f = (x - k) * TN;
	int i = (int)f;
	if(i >= TN) i = TN - 1;
	double v = T.ex2[i] + (T.ex2[i + 1] - T.ex2[i]) * (f - i);
	return std::ldexp(v, (int)k);
}

static inline double log2_(double x)
{
	int e = 0;
	double m = std::frexp(x, &e) * 2 - 1;
	double f = m * TN;
	int i = (int)f;
	if(i >= TN) i = TN - 1;
	if(i < 0) i = 0;
	return T.lg2[i] + (T.lg2[i + 1] - T.lg2[i]) * (f - i) + (e - 1);
}

static double db(double x) { return d_exp(x / 20 * LN2 * LOG2_10); }
static double midi_hz(double m) { return 440 * exp2_((m - 69) / 12); }
// A per-sample multiplier that falls 60 dB in sec seconds
static double t60(double sec)
{
	if(sec <= 0)
		return 0;
	return d_exp(-6.907755 / (sec * RATE));
}
// A tanh-like soft clip, +-1 at |x| >= 3
static inline double sat(double x)
{
	if(x >= 3) return 1;
	if(x <= -3) return -1;
	double x2 = x * x;
	return x * (27 + x2) / (27 + 9 * x2);
}
static inline double flush(double x) { return (x < 1e-20 && x > -1e-20) ? 0 : x; }

// The prototype's seed from integers (LuaJIT's 32-bit bit ops)
static int32_t hash3(int64_t a, int64_t b, int64_t c)
{
	int32_t h = 0x2545F491;
	const int64_t v[3] = {a, b, c};
	for(int i = 0; i < 3; i++){
		int32_t x = h ^ (int32_t)(uint32_t)(uint64_t)v[i];
		h = (int32_t)(uint32_t)(uint64_t)((int64_t)x * 40503);
		h = h ^ (int32_t)((uint32_t)h >> 15);
	}
	return h == 0 ? 1 : h;
}
// Lua's floor modulo of an int32
static inline int64_t fmod_i(int64_t a, int64_t m) { return ((a % m) + m) % m; }

// xorshift32 as LuaJIT's signed bit ops: -1..1
static inline double rnd(int32_t &s)
{
	uint32_t u = (uint32_t)s;
	u ^= u << 13;
	u ^= u >> 17;
	u ^= u << 5;
	s = (int32_t)u;
	return s * (1.0 / 2147483648.0);
}

// PolyBLEP
static inline double blep(double t, double dt)
{
	if(t < dt){ t = t / dt; return t + t - t * t - 1; }
	if(t > 1 - dt){ t = (t - 1) / dt; return t * t + t + t + 1; }
	return 0;
}
// wave: 1 saw, 2 pulse, 3 triangle, 4 sine, 0 none
static inline double osc(int w, double ph, double dt, double pw)
{
	if(w == 1)
		return 2 * ph - 1 - blep(ph, dt);
	if(w == 2){
		double t2 = ph - pw;
		if(t2 < 0) t2 = t2 + 1;
		return (ph < pw ? 1 : -1) + blep(ph, dt) - blep(t2, dt);
	}
	if(w == 3)
		return ph < 0.5 ? 4 * ph - 1 : 3 - 4 * ph;
	if(w == 4)
		return sin_ph(ph);
	return 0;
}

// A state-variable filter's coefficients (Zavalishin's TPT form)
struct Svf { double a1 = 0, a2 = 0, a3 = 0, k = 0; };
static inline Svf svf_coef(double fc, double res)
{
	if(fc > RATE * 0.45) fc = RATE * 0.45;
	else if(fc < 10) fc = 10;
	double ph = fc / (2.0 * RATE);
	double g = sin_ph(ph) / sin_ph(ph + 0.25);
	Svf s;
	s.k = 2 - 2 * std::min(res, 0.98);
	s.a1 = 1 / (1 + g * (g + s.k));
	s.a2 = g * s.a1;
	s.a3 = g * g * s.a1;
	return s;
}
static void svf_run(double *st, double *buf, int n, int mode, const Svf &c)
{
	double ic1 = st[0], ic2 = st[1];
	for(int i = 0; i < n; i++){
		double v0 = buf[i];
		double v3 = v0 - ic2;
		double v1 = c.a1 * ic1 + c.a2 * v3;
		double v2 = ic2 + c.a2 * ic1 + c.a3 * v3;
		ic1 = 2 * v1 - ic1;
		ic2 = 2 * v2 - ic2;
		buf[i] = mode == 1 ? v2 : mode == 2 ? v1 : v0 - c.k * v1 - v2;
	}
	st[0] = ic1;
	st[1] = ic2;
}

// RBJ biquads (transposed direct form II)
struct Biquad { double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0; };
enum BqKind { BQ_PEAK, BQ_LOW, BQ_HIGH, BQ_LP, BQ_HP };
static Biquad biquad(int kind, double f, double q, double gain_db)
{
	double A = d_exp(gain_db / 40 * LN2 * LOG2_10);
	double w = TAU * f / RATE;
	double cw = d_cos(w), sw = d_sin(w);
	double al = sw / (2 * q);
	double b0 = 1, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
	if(kind == BQ_PEAK){
		b0 = 1 + al * A; b1 = -2 * cw; b2 = 1 - al * A;
		a0 = 1 + al / A; a1 = -2 * cw; a2 = 1 - al / A;
	} else if(kind == BQ_LOW || kind == BQ_HIGH){
		double sa = 2 * std::sqrt(A) * al;
		double s = kind == BQ_LOW ? 1 : -1;
		b0 = A * ((A + 1) - s * (A - 1) * cw + sa);
		b1 = s * 2 * A * ((A - 1) - s * (A + 1) * cw);
		b2 = A * ((A + 1) - s * (A - 1) * cw - sa);
		a0 = (A + 1) + s * (A - 1) * cw + sa;
		a1 = -s * 2 * ((A - 1) + s * (A + 1) * cw);
		a2 = (A + 1) + s * (A - 1) * cw - sa;
	} else if(kind == BQ_LP){
		b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2;
		a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al;
	} else {
		b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2;
		a0 = 1 + al; a1 = -2 * cw; a2 = 1 - al;
	}
	Biquad q2;
	q2.b0 = b0 / a0; q2.b1 = b1 / a0; q2.b2 = b2 / a0;
	q2.a1 = a1 / a0; q2.a2 = a2 / a0;
	return q2;
}
static void bq_run(Biquad &q, double *buf, int n)
{
	double b0 = q.b0, b1 = q.b1, b2 = q.b2, a1 = q.a1, a2 = q.a2, z1 = q.z1,
			z2 = q.z2;
	for(int i = 0; i < n; i++){
		double x = buf[i];
		double y = b0 * x + z1;
		z1 = b1 * x - a1 * y + z2;
		z2 = b2 * x - a2 * y;
		buf[i] = y;
	}
	// a decaying tail would reach denormals, ~10x slower on x86
	if(std::fabs(z1) < 1e-15) z1 = 0;
	if(std::fabs(z2) < 1e-15) z2 = 0;
	q.z1 = z1;
	q.z2 = z2;
}

// ---- The song: instruments, tracks, buses, as the text gives them

enum Src { S_OSC, S_PLUCK, S_FM, S_KICK, S_SNARE, S_TOM, S_HAT, S_CYMBAL };
static const char *SRC_NAMES[] = {"osc", "pluck", "fm", "kick", "snare", "tom",
	"hat", "cymbal"};

struct Inst
{
	int src = S_OSC;
	double gain = 0, vels = 0.7, a = 0.002, d = 0.3, s = 1, r = 0.08,
			gate = 0.92, glide = 0.05, vib = 0, vibrate = 5.5, vibdelay = 0.25,
			tune = 0, strum = 0, spread = 0;
	sv_<double> chord;
	int wave = 1, wave2 = 0;
	double mix2 = 0.5, detune2 = 7, oct2 = 0, pw = 0.5, pwm = 0, pwmrate = 0.5,
			sub = 0, noise = 0;
	double bright = 0.7, decay = 3, pick = 0.15, mdecay = 0.18, mbright = 0.25,
			rdecay = 0.05;
	double ratio = 1, index = 2, idecay = 0.6, ifloor = 0.3, tine = 0.3,
			tratio = 7, tdecay = 0.08;
	double tone = 50, pdrop = 3, pdecay = 0.04, click = 0.4, snappy = 0.7,
			ndecay = 0.15, nfreq = 3000, metal = 1, odecay = 0.4, bell = 0;
	int ftype = 0, poles = 2;
	double cut = 2000, res = 0.2, fenv = 0, fa = 0.002, fd = 0.3, fs = 0,
			fr = 0.1, ktrack = 0.5, velf = 0.5, drive = 0;
	bool drum() const
	{
		return src == S_KICK || src == S_SNARE || src == S_HAT ||
				src == S_CYMBAL;
	}
};

struct NumKey
{
	const char *name;
	double Inst::*field;
	double lo, hi;
};
static const NumKey INST_KEYS[] = {
	{"gain", &Inst::gain, -60, 24}, {"vels", &Inst::vels, 0, 1},
	{"a", &Inst::a, 0, 30}, {"d", &Inst::d, 0, 60}, {"s", &Inst::s, 0, 1},
	{"r", &Inst::r, 0, 60}, {"gate", &Inst::gate, 0, 4},
	{"glide", &Inst::glide, 0, 10}, {"vib", &Inst::vib, 0, 1200},
	{"vibrate", &Inst::vibrate, 0, 50}, {"vibdelay", &Inst::vibdelay, 0, 30},
	{"tune", &Inst::tune, -1200, 1200}, {"strum", &Inst::strum, 0, 1},
	{"spread", &Inst::spread, -100, 100}, {"mix2", &Inst::mix2, 0, 1},
	{"detune2", &Inst::detune2, -1200, 1200}, {"oct2", &Inst::oct2, -4, 4},
	{"pw", &Inst::pw, 0, 1}, {"pwm", &Inst::pwm, 0, 1},
	{"pwmrate", &Inst::pwmrate, 0, 50}, {"sub", &Inst::sub, 0, 2},
	{"noise", &Inst::noise, 0, 2}, {"bright", &Inst::bright, 0, 1},
	{"decay", &Inst::decay, 0.01, 60}, {"pick", &Inst::pick, 0, 0.5},
	{"mdecay", &Inst::mdecay, 0.01, 60}, {"mbright", &Inst::mbright, 0, 1},
	{"rdecay", &Inst::rdecay, 0.001, 60}, {"ratio", &Inst::ratio, 0, 32},
	{"index", &Inst::index, 0, 50}, {"idecay", &Inst::idecay, 0, 60},
	{"ifloor", &Inst::ifloor, 0, 1}, {"tine", &Inst::tine, 0, 2},
	{"tratio", &Inst::tratio, 0, 64}, {"tdecay", &Inst::tdecay, 0, 60},
	{"tone", &Inst::tone, 1, 20000}, {"pdrop", &Inst::pdrop, 1, 20},
	{"pdecay", &Inst::pdecay, 0, 10}, {"click", &Inst::click, 0, 4},
	{"snappy", &Inst::snappy, 0, 1}, {"ndecay", &Inst::ndecay, 0, 10},
	{"nfreq", &Inst::nfreq, 20, 20000}, {"metal", &Inst::metal, 0, 4},
	{"odecay", &Inst::odecay, 0, 20}, {"bell", &Inst::bell, 0, 4},
	{"cut", &Inst::cut, 10, 20000}, {"res", &Inst::res, 0, 0.98},
	{"fenv", &Inst::fenv, -10, 10}, {"fa", &Inst::fa, 0, 30},
	{"fd", &Inst::fd, 0, 60}, {"fs", &Inst::fs, 0, 1}, {"fr", &Inst::fr, 0, 60},
	{"ktrack", &Inst::ktrack, -2, 2}, {"velf", &Inst::velf, -4, 4},
	{"drive", &Inst::drive, 0, 60},
};

struct TrackP
{
	int inst = 0;
	std::set<ss_> given;
	double gain = 0, pan = 0, rev = 0, dly = 0, mono = 0, choke = 0,
			transpose = 0, tune = 0, hum = 0, velr = 0, seed = 0, trem = 0,
			tremsteps = 2, hp = 0, lp = 0, lo = 0, hi = 0, lof = 150, hif = 5000,
			comp = 0, ratio = 4, catk = 0.005, crel = 0.1, makeup = 0, amp = 0,
			bias = 0.2, tight = 90, hump = 6, mid = 850, fizz = 6500, cab = 4800,
			thump = 4, thumpf = 120, mud = 3, presence = 3, ampout = -8, blend = 1;
	bool has(const char *k) const { return given.count(k) != 0; }
};
struct TrackKey
{
	const char *name;
	double TrackP::*field;
	double lo, hi;
};
static const TrackKey TRACK_KEYS[] = {
	{"gain", &TrackP::gain, -60, 24}, {"pan", &TrackP::pan, -1, 1},
	{"rev", &TrackP::rev, 0, 2}, {"dly", &TrackP::dly, 0, 2},
	{"mono", &TrackP::mono, 0, 1}, {"choke", &TrackP::choke, 0, 1},
	{"transpose", &TrackP::transpose, -48, 48},
	{"tune", &TrackP::tune, -1200, 1200}, {"hum", &TrackP::hum, 0, 100},
	{"velr", &TrackP::velr, 0, 1}, {"seed", &TrackP::seed, 0, 1e9},
	{"trem", &TrackP::trem, 0, 1}, {"tremsteps", &TrackP::tremsteps, 0.25, 256},
	{"hp", &TrackP::hp, 10, 20000}, {"lp", &TrackP::lp, 10, 20000},
	{"lo", &TrackP::lo, -24, 24}, {"hi", &TrackP::hi, -24, 24},
	{"lof", &TrackP::lof, 20, 20000}, {"hif", &TrackP::hif, 20, 20000},
	{"comp", &TrackP::comp, -60, 0}, {"ratio", &TrackP::ratio, 1, 20},
	{"catk", &TrackP::catk, 0.0001, 5}, {"crel", &TrackP::crel, 0.001, 5},
	{"makeup", &TrackP::makeup, -24, 24}, {"amp", &TrackP::amp, 0, 60},
	{"bias", &TrackP::bias, -2, 2}, {"tight", &TrackP::tight, 10, 2000},
	{"hump", &TrackP::hump, -24, 24}, {"mid", &TrackP::mid, 100, 10000},
	{"fizz", &TrackP::fizz, 500, 20000}, {"cab", &TrackP::cab, 500, 20000},
	{"thump", &TrackP::thump, -24, 24}, {"thumpf", &TrackP::thumpf, 20, 1000},
	{"mud", &TrackP::mud, -24, 24}, {"presence", &TrackP::presence, -24, 24},
	{"ampout", &TrackP::ampout, -60, 24}, {"blend", &TrackP::blend, 0, 1},
};

// reverb, delay and master: each a list of keys, defaults and ranges
struct BusKey { const char *name; double def, lo, hi; };
static const BusKey REVERB_KEYS[] = {{"size", 0.8, 0.1, 1.4},
	{"decay", 1.6, 0.1, 20}, {"damp", 0.4, 0, 1}, {"predelay", 0.012, 0, 0.18},
	{"lowcut", 180, 20, 2000}, {"gain", 0, -60, 12}};
static const BusKey DELAY_KEYS[] = {{"time", 3, 0, 64},
	{"feedback", 0.35, 0, 0.95}, {"tone", 2500, 20, 20000},
	{"gain", 0, -60, 12}};
static const BusKey MASTER_KEYS[] = {{"comp", 0, -60, 0}, {"ratio", 2, 1, 20},
	{"catk", 0.01, 0.0001, 5}, {"crel", 0.15, 0.001, 5},
	{"ceiling", -1, -24, 0}, {"gain", 0, -60, 24}, {"release", 0.08, 0.001, 2}};

struct Event
{
	int64_t t = 0;
	int track = 0, inst = 0, nn = 0;
	double notes[MAX_NOTES] = {0};
	double vel = 0, len = 0;
	bool mute = false, slide = false, stacc = false, glide = false, open = false;
};

struct Song
{
	ss_ title;
	double tempo = 120, swing = 0;
	int steps = 16, beat = 4;
	std::map<ss_, double> reverb, delay, master;
	bool master_comp = false;
	sv_<Inst> insts; // the named ones, then the per-step params' copies
	std::map<ss_, int> inst_index;
	sv_<ss_> track_names;
	sv_<TrackP> tracks;
	std::map<ss_, sv_<double>> moods; // a gain a track (0: off)
	sv_<Event> events;
	int64_t loop_t = 0, end_t = 0;
	double step_len = 0, bar_len = 0;
	size_t loop_ei = 0;
};

// ---- The parser

namespace {
struct Tok { ss_ s; int line; };
struct Pattern
{
	ss_ name;
	int bars = 1, len = 16, line = 0;
	sv_<ss_> order;
	std::map<ss_, sv_<Tok>> lanes, params;
};
struct Entry { sv_<ss_> layer; int rep = 1; };

struct Error
{
	ss_ msg;
};

struct Parser
{
	Song &song;
	int ln = 0;
	std::map<ss_, Pattern> patterns;
	std::map<ss_, sv_<Entry>> sections;
	std::map<ss_, ss_> defs;
	sv_<ss_> play;
	ss_ loop;
	int loop_line = 0;
	explicit Parser(Song &s): song(s) {}

	[[noreturn]] void err(const ss_ &m)
	{
		char b[32];
		snprintf(b, sizeof b, "line %d: ", ln);
		throw Error{b + m.substr(0, 200)};
	}

	// A number as written (digits, a point, an exponent), no locale
	static bool number(const ss_ &s, double *out)
	{
		size_t i = 0, n = s.size();
		bool neg = false;
		if(i < n && (s[i] == '-' || s[i] == '+'))
			neg = s[i++] == '-';
		double m = 0;
		int digits = 0, scale = 0;
		while(i < n && isdigit((unsigned char)s[i])){
			if(digits < 18) m = m * 10 + (s[i] - '0'); else scale++;
			digits++;
			i++;
		}
		if(i < n && s[i] == '.'){
			i++;
			while(i < n && isdigit((unsigned char)s[i])){
				if(digits < 18){ m = m * 10 + (s[i] - '0'); scale--; }
				digits++;
				i++;
			}
		}
		if(digits == 0)
			return false;
		if(i < n && (s[i] == 'e' || s[i] == 'E')){
			i++;
			bool en = false;
			if(i < n && (s[i] == '-' || s[i] == '+'))
				en = s[i++] == '-';
			int e = 0, ed = 0;
			while(i < n && isdigit((unsigned char)s[i])){
				if(e < 1000) e = e * 10 + (s[i] - '0');
				ed++;
				i++;
			}
			if(ed == 0)
				return false;
			scale += en ? -e : e;
		}
		if(i != n || scale > 300 || scale < -300)
			return false;
		double p = 1;
		for(int k = 0; k < (scale < 0 ? -scale : scale); k++)
			p = p * 10;
		*out = (neg ? -1 : 1) * (scale < 0 ? m / p : m * p);
		return true;
	}

	double num(const ss_ &v, const ss_ &what, double lo, double hi)
	{
		double x;
		if(!number(v, &x))
			err(what + ": a number expected, not \"" + v.substr(0, 32) + "\"");
		if(x < lo || x > hi){
			char b[160];
			snprintf(b, sizeof b, "%s: %.6g is not %.6g..%.6g", what.c_str(), x,
					lo, hi);
			err(b);
		}
		return x;
	}

	static sv_<ss_> words(const ss_ &s)
	{
		sv_<ss_> w;
		size_t i = 0;
		while(i < s.size()){
			while(i < s.size() && isspace((unsigned char)s[i])) i++;
			size_t j = i;
			while(j < s.size() && !isspace((unsigned char)s[j])) j++;
			if(j > i)
				w.push_back(s.substr(i, j - i));
			i = j;
		}
		return w;
	}

	// "k=v ..." -> pairs; a word without = is refused
	sv_<std::pair<ss_, ss_>> kv(const sv_<ss_> &w, size_t from, const ss_ &what)
	{
		sv_<std::pair<ss_, ss_>> out;
		for(size_t i = from; i < w.size(); i++){
			size_t eq = w[i].find('=');
			if(eq == ss_::npos || eq == 0 || eq + 1 == w[i].size())
				err(what + ": \"" + w[i].substr(0, 32) + "\" is not key=value");
			out.push_back({w[i].substr(0, eq), w[i].substr(eq + 1)});
		}
		return out;
	}

	void bus(const sv_<ss_> &w, const BusKey *keys, size_t nk,
			std::map<ss_, double> &into)
	{
		for(auto &p : kv(w, 1, w[0])){
			const BusKey *k = nullptr;
			for(size_t i = 0; i < nk; i++)
				if(p.first == keys[i].name)
					k = &keys[i];
			if(!k)
				err(w[0] + ": unknown parameter " + p.first);
			into[p.first] = num(p.second, w[0] + " " + p.first, k->lo, k->hi);
		}
	}

	static int wave_of(const ss_ &v)
	{
		if(v == "none") return 0;
		if(v == "saw") return 1;
		if(v == "square" || v == "pulse") return 2;
		if(v == "tri") return 3;
		if(v == "sine") return 4;
		return -1;
	}
	static int ftype_of(const ss_ &v)
	{
		if(v == "none") return 0;
		if(v == "lp") return 1;
		if(v == "bp") return 2;
		if(v == "hp") return 3;
		return -1;
	}

	// An instrument's parameter set; false: no such parameter
	bool inst_param(Inst &p, const ss_ &k, const ss_ &v, const ss_ &what)
	{
		for(const NumKey &nk : INST_KEYS)
			if(k == nk.name){
				p.*nk.field = num(v, what + " " + k, nk.lo, nk.hi);
				return true;
			}
		if(k == "wave" || k == "wave2"){
			int w = wave_of(v);
			if(w < 0)
				err(what + " " + k + ": saw, square, pulse, tri, sine or none");
			(k == "wave" ? p.wave : p.wave2) = w;
		} else if(k == "ftype"){
			int f = ftype_of(v);
			if(f < 0)
				err(what + " ftype: none, lp, bp or hp");
			p.ftype = f;
		} else if(k == "poles"){
			double x = num(v, what + " poles", 2, 4);
			if(x != 2 && x != 4)
				err(what + " poles: 2 or 4");
			p.poles = (int)x;
		} else if(k == "chord"){
			p.chord.clear();
			size_t i = 0;
			while(i <= v.size()){
				size_t j = v.find(',', i);
				if(j == ss_::npos) j = v.size();
				if(p.chord.size() >= MAX_CHORD)
					err(what + " chord: " + std::to_string(MAX_CHORD) +
							" intervals at most");
				p.chord.push_back(num(v.substr(i, j - i), what + " chord", -48,
						48));
				i = j + 1;
			}
		} else if(k == "src"){
			int s = -1;
			for(int i = 0; i < 8; i++)
				if(v == SRC_NAMES[i])
					s = i;
			if(s < 0)
				err(what + ": unknown source " + v);
			p.src = s;
		} else
			return false;
		return true;
	}

	void line(const ss_ &raw)
	{
		// "#" at the start or after a space is a comment ("C#3" a note)
		ss_ s = raw;
		for(size_t i = 0; i < s.size(); i++)
			if(s[i] == '#' && (i == 0 || isspace((unsigned char)s[i - 1]))){
				s = s.substr(0, i);
				break;
			}
		sv_<ss_> w = words(s);
		if(w.empty())
			return;
		const ss_ &w1 = w[0];
		if(w1 == "title"){
			size_t at = s.find("title") + 5;
			size_t a = s.find_first_not_of(" \t\r", at);
			size_t b = s.find_last_not_of(" \t\r");
			song.title = a == ss_::npos ? "" : s.substr(a, b - a + 1).substr(0, 80);
		} else if(w1 == "tempo" || w1 == "steps" || w1 == "beat" ||
				w1 == "swing"){
			if(w.size() != 2)
				err(w1 + ": one number");
			if(w1 == "tempo") song.tempo = num(w[1], "tempo", 20, 400);
			else if(w1 == "swing") song.swing = num(w[1], "swing", 0, 0.5);
			else{
				double x = num(w[1], w1, 1, 64);
				if(x != std::floor(x))
					err(w1 + ": a whole number");
				(w1 == "steps" ? song.steps : song.beat) = (int)x;
			}
		} else if(w1 == "reverb"){
			bus(w, REVERB_KEYS, sizeof REVERB_KEYS / sizeof *REVERB_KEYS,
					song.reverb);
		} else if(w1 == "delay"){
			bus(w, DELAY_KEYS, sizeof DELAY_KEYS / sizeof *DELAY_KEYS, song.delay);
		} else if(w1 == "master"){
			bus(w, MASTER_KEYS, sizeof MASTER_KEYS / sizeof *MASTER_KEYS,
					song.master);
		} else if(w1 == "inst"){
			if(w.size() < 3)
				err("inst NAME SRC|INST k=v ...");
			const ss_ &name = w[1], &base = w[2];
			if(!song.inst_index.count(name) && song.insts.size() >= MAX_INSTS)
				err("more than " + std::to_string(MAX_INSTS) + " instruments");
			Inst p;
			auto from = song.inst_index.find(base);
			if(from != song.inst_index.end())
				p = song.insts[from->second];
			else if(!inst_param(p, "src", base, "inst " + name))
				err("inst " + name + ": unknown source " + base);
			for(auto &kvp : kv(w, 3, "inst " + name))
				if(!inst_param(p, kvp.first, kvp.second, "inst " + name))
					err("inst " + name + ": unknown parameter " + kvp.first);
			auto it = song.inst_index.find(name);
			if(it != song.inst_index.end())
				song.insts[it->second] = p;
			else{
				song.inst_index[name] = (int)song.insts.size();
				song.insts.push_back(p);
			}
		} else if(w1 == "track"){
			if(w.size() < 2)
				err("track NAME inst=INST k=v ...");
			const ss_ &name = w[1];
			TrackP t;
			bool has_inst = false;
			for(auto &p : kv(w, 2, "track " + name)){
				if(p.first == "inst"){
					auto it = song.inst_index.find(p.second);
					if(it == song.inst_index.end())
						err("track " + name + ": no inst " + p.second);
					t.inst = it->second;
					has_inst = true;
					continue;
				}
				const TrackKey *k = nullptr;
				for(const TrackKey &tk : TRACK_KEYS)
					if(p.first == tk.name)
						k = &tk;
				if(!k)
					err("track " + name + ": unknown parameter " + p.first);
				t.*k->field = num(p.second, "track " + name + " " + p.first,
						k->lo, k->hi);
				t.given.insert(p.first);
			}
			if(!has_inst)
				err("track " + name + ": no inst=");
			size_t i = std::find(song.track_names.begin(), song.track_names.end(),
					name) - song.track_names.begin();
			if(i == song.track_names.size()){
				if(i >= MAX_TRACKS)
					err("more than " + std::to_string(MAX_TRACKS) + " tracks");
				song.track_names.push_back(name);
				song.tracks.push_back(t);
			} else
				song.tracks[i] = t;
		} else if(w1 == "def"){
			if(w.size() != 3)
				err("def NAME TOKEN");
			defs[w[1]] = w[2];
		} else if(w1 == "pattern"){
			if(w.size() < 2)
				err("pattern NAME [bars=N]");
			if(patterns.size() >= MAX_PATTERNS && !patterns.count(w[1]))
				err("more than " + std::to_string(MAX_PATTERNS) + " patterns");
			Pattern p;
			p.name = w[1];
			p.line = ln;
			for(auto &kvp : kv(w, 2, "pattern " + w[1])){
				if(kvp.first != "bars")
					err("pattern " + w[1] + ": unknown parameter " + kvp.first);
				double b = num(kvp.second, "pattern " + w[1] + " bars", 1, 64);
				if(b != std::floor(b))
					err("pattern " + w[1] + " bars: a whole number");
				p.bars = (int)b;
			}
			p.len = p.bars * song.steps;
			patterns[p.name] = p;
			current = &patterns[p.name];
		} else if(w1 == "section"){
			size_t colon = s.find(':');
			ss_ name = colon == ss_::npos ? "" : s.substr(0, colon);
			sv_<ss_> nw = words(name);
			if(nw.size() != 2 || nw[0] != "section")
				err("section NAME: entries");
			name = nw[1];
			for(char c : name)
				if(!isalnum((unsigned char)c) && c != '_')
					err("section NAME: letters, digits and _");
			sv_<Entry> sec;
			for(const ss_ &e : words(s.substr(colon + 1))){
				Entry en;
				ss_ body = e;
				size_t star = e.rfind('*');
				if(star != ss_::npos){
					body = e.substr(0, star);
					double r = num(e.substr(star + 1), "section " + name +
							" repeat", 1, 64);
					if(r != std::floor(r))
						err("section " + name + ": a whole repeat");
					en.rep = (int)r;
				}
				size_t i = 0;
				while(i <= body.size()){
					size_t j = body.find('+', i);
					if(j == ss_::npos) j = body.size();
					ss_ pn = body.substr(i, j - i);
					if(!patterns.count(pn))
						err("no pattern " + pn);
					en.layer.push_back(pn);
					i = j + 1;
				}
				sec.push_back(en);
			}
			if(sec.empty())
				err("section " + name + ": no entries");
			sections[name] = sec;
			current = nullptr;
		} else if(w1 == "play"){
			for(size_t i = 1; i < w.size(); i++){
				if(!sections.count(w[i]))
					err("no section " + w[i]);
				if(play.size() >= 256)
					err("play: 256 sections at most");
				play.push_back(w[i]);
			}
		} else if(w1 == "loop"){
			if(w.size() != 2)
				err("loop SECTION");
			loop = w[1];
			loop_line = ln;
		} else if(w1 == "mood"){
			if(w.size() < 2)
				err("mood NAME TRACK=off|dB ...");
			if(w[1] == "all" || song.moods.size() >= 64)
				err("mood " + w[1] + ": \"all\" is every track at 0 dB, and 64"
						" moods at most");
			sv_<double> g(song.tracks.size(), 1.0);
			for(auto &p : kv(w, 2, "mood " + w[1])){
				size_t i = std::find(song.track_names.begin(),
						song.track_names.end(), p.first) - song.track_names.begin();
				if(i == song.track_names.size())
					err("mood " + w[1] + ": no track " + p.first);
				g[i] = p.second == "off" ? 0 : db(num(p.second, "mood " + w[1] +
						" " + p.first, -60, 24));
			}
			song.moods[w[1]] = g;
		} else if(w1.size() > 1 && w1.back() == ':' && current){
			lane(w1.substr(0, w1.size() - 1), s.substr(s.find(':') + 1));
		} else
			err("unknown line: " + w1.substr(0, 40));
	}

	Pattern *current = nullptr;

	void lane(const ss_ &lane_name, const ss_ &rest)
	{
		Pattern &pat = *current;
		size_t tilde = lane_name.find('~');
		ss_ tr = tilde == ss_::npos ? lane_name : lane_name.substr(0, tilde);
		ss_ param = tilde == ss_::npos ? "" : lane_name.substr(tilde + 1);
		size_t ti = std::find(song.track_names.begin(), song.track_names.end(),
				tr) - song.track_names.begin();
		if(ti == song.track_names.size())
			err("no track " + tr);
		if(!param.empty()){
			Inst probe;
			bool known = false;
			for(const NumKey &nk : INST_KEYS)
				known = known || param == nk.name;
			if(!known && param != "wave" && param != "wave2" && param != "ftype")
				err(lane_name + ": no instrument parameter " + param);
			(void)probe;
		}
		sv_<Tok> toks;
		sv_<ss_> w = words(rest);
		const ss_ copy = w.size() == 2 && w[0] == "=" ? w[1] : w.size() == 1 &&
				w[0].size() > 1 && w[0][0] == '=' ? w[0].substr(1) : "";
		if(!copy.empty()){
			auto it = pat.lanes.find(copy);
			if(it == pat.lanes.end())
				err("no lane " + copy + " above");
			for(const Tok &t : it->second)
				toks.push_back({t.s, ln});
		} else if(param.empty() && song.insts[song.tracks[ti].inst].drum()){
			for(char c : rest)
				if(!isspace((unsigned char)c) && c != '|')
					toks.push_back({ss_(1, c), ln});
		} else {
			for(const ss_ &x : w){
				size_t i = 0;
				while(i <= x.size()){
					size_t j = x.find('|', i);
					if(j == ss_::npos) j = x.size();
					if(j > i)
						toks.push_back({x.substr(i, j - i), ln});
					i = j + 1;
				}
			}
		}
		auto &into = param.empty() ? pat.lanes : pat.params;
		const ss_ key = param.empty() ? tr : lane_name;
		if(!into.count(key) && param.empty())
			pat.order.push_back(tr);
		sv_<Tok> &dst = into[key];
		if(dst.size() + toks.size() > MAX_LANE)
			err(lane_name + ": " + std::to_string(MAX_LANE) + " steps at most");
		dst.insert(dst.end(), toks.begin(), toks.end());
	}

	void finish()
	{
		for(auto &pp : patterns){
			Pattern &p = pp.second;
			for(auto *set : {&p.lanes, &p.params})
				for(auto &l : *set){
					size_t n = l.second.size();
					if(n == 0 || p.len % n != 0){
						ln = p.line;
						err("pattern " + p.name + " lane " + l.first + ": " +
								std::to_string(n) + " steps, the pattern has " +
								std::to_string(p.len));
					}
					for(size_t i = n; i < (size_t)p.len; i++)
						l.second.push_back(l.second[i - n]);
				}
		}
		if(play.empty())
			err("no play line");
		if(loop.empty())
			loop = play[0];
		else if(std::find(play.begin(), play.end(), loop) == play.end()){
			ln = loop_line;
			err("loop " + loop + ": not in the play line");
		}
		for(auto &m : song.moods)
			m.second.resize(song.tracks.size(), 1.0);
	}

	// A melodic token -> notes, velocity, flags
	void token(const Tok &tk0, Event &e)
	{
		ss_ tk = tk0.s;
		for(size_t k = tk.size(); k >= 1; k--){
			auto d = defs.find(tk.substr(0, k));
			if(d != defs.end()){
				tk = d->second + tk.substr(k);
				break;
			}
		}
		static const int NOTE[] = {9, 11, 0, 2, 4, 5, 7}; // A..G
		size_t pos = 0;
		e.nn = 0;
		while(pos < tk.size() && tk[pos] >= 'A' && tk[pos] <= 'G'){
			size_t p = pos + 1;
			int acc = 0;
			if(p < tk.size() && (tk[p] == '#' || tk[p] == 'b')){
				acc = tk[p] == '#' ? 1 : -1;
				p++;
			}
			bool neg = false;
			if(p < tk.size() && tk[p] == '-'){
				neg = true;
				p++;
			}
			if(p >= tk.size() || !isdigit((unsigned char)tk[p]))
				break;
			int oct = (tk[p] - '0') * (neg ? -1 : 1);
			p++;
			if(e.nn >= (int)MAX_NOTES){
				ln = tk0.line;
				err("token " + tk0.s.substr(0, 40) + ": " +
						std::to_string(MAX_NOTES) + " notes at most");
			}
			e.notes[e.nn++] = 12 * (oct + 1) + NOTE[tk[pos] - 'A'] + acc;
			pos = p;
			if(pos < tk.size() && tk[pos] == '+')
				pos++;
		}
		if(e.nn == 0){
			ln = tk0.line;
			err("bad token " + tk0.s.substr(0, 40));
		}
		ss_ mods = tk.substr(pos);
		e.vel = 0.8;
		if(mods.find('!') != ss_::npos) e.vel = 1;
		if(mods.find('?') != ss_::npos) e.vel = 0.5;
		size_t at = mods.find('@');
		if(at != ss_::npos){
			size_t j = at + 1;
			while(j < mods.size() && (isdigit((unsigned char)mods[j]) ||
					mods[j] == '.'))
				j++;
			double v;
			if(j > at + 1 && number(mods.substr(at + 1, j - at - 1), &v))
				e.vel = v; // (capped at 1 after the velocity's random part)
		}
		for(char c : mods)
			if(!strchr("!?@.0123456789m~'", c)){
				ln = tk0.line;
				err("token " + tk0.s.substr(0, 40) + ": unknown modifier " +
						ss_(1, c));
			}
		e.mute = mods.find('m') != ss_::npos;
		e.slide = mods.find('~') != ss_::npos;
		e.stacc = mods.find('\'') != ss_::npos;
	}

	// The per-step params' copy of an instrument, made once
	std::map<ss_, int> over_index;
	int inst_with(int base, const std::map<ss_, Tok> &over)
	{
		if(over.empty())
			return base;
		ss_ key = std::to_string(base);
		for(auto &o : over)
			key += "\n" + o.first + "=" + o.second.s;
		auto it = over_index.find(key);
		if(it != over_index.end())
			return it->second;
		Inst p = song.insts[base];
		for(auto &o : over){
			ln = o.second.line;
			inst_param(p, o.first, o.second.s, "~" + o.first);
		}
		if(song.insts.size() >= 1024)
			err("more than 1024 instruments with per-step parameters");
		song.insts.push_back(p);
		return over_index[key] = (int)song.insts.size() - 1;
	}

	void compile(int rate)
	{
		const double step_len = (double)rate * 60 / song.tempo / song.beat;
		const double swing = song.swing * step_len;
		auto st = [&](int64_t s){
			return s * step_len + (s % 2 == 1 ? swing : 0);
		};
		sv_<Event> &events = song.events;
		int64_t cursor = 0, loop_step = -1;
		auto emit = [&](const Pattern &pat, int64_t base, int len){
			for(const ss_ &tr : pat.order){
				int ti = (int)(std::find(song.track_names.begin(),
						song.track_names.end(), tr) - song.track_names.begin());
				const TrackP &tp = song.tracks[ti];
				const Inst &inst = song.insts[tp.inst];
				const sv_<Tok> &toks = pat.lanes.at(tr);
				const int64_t seed = tp.has("seed") ? (int64_t)tp.seed : ti + 1;
				const double hum = tp.hum * rate / 1000;
				auto jitter = [&](int64_t s, int64_t k){
					return (double)fmod_i(hash3(seed, base + s, k), 10007) / 10007;
				};
				std::map<ss_, Tok> over;
				bool glide = false;
				for(int i = 0; i < len; i++){
					int s = i % pat.len;
					const Tok &tk = toks[s];
					for(auto &pl : pat.params){
						size_t tl = pl.first.find('~');
						if(pl.first.substr(0, tl) == tr && pl.second[s].s != ".")
							over[pl.first.substr(tl + 1)] = pl.second[s];
					}
					double t0 = st(base + i) + hum * jitter(i, 0);
					double vr = tp.velr * (2 * jitter(i, 1) - 1);
					if(events.size() + 2 > MAX_EVENTS){
						ln = tk.line;
						err("more than " + std::to_string(MAX_EVENTS) + " notes");
					}
					Event e;
					e.track = ti;
					if(inst.drum()){
						if(tk.s == "." || tk.s == "-")
							continue;
						const char c = tk.s[0];
						double vel = c == 'X' ? 1 : c == 'x' ? 0.75 : c == 'g' ?
								0.4 : c == 'o' ? 0.8 : c == 'O' ? 1 : c == 'f' ?
								0.75 : -1;
						if(vel < 0){
							ln = tk.line;
							err("track " + tr + ": bad hit " + tk.s);
						}
						e.inst = inst_with(tp.inst, over);
						e.nn = 1;
						e.notes[0] = 60;
						e.len = 1e12;
						if(c == 'f'){
							Event f = e;
							f.vel = 0.35 + vr;
							events.push_back(f);
							times.push_back({events.size() - 1, t0});
							t0 = t0 + 0.014 * rate;
						}
						e.vel = std::min(1.0, vel + vr);
						e.open = c == 'o' || c == 'O';
						events.push_back(e);
						times.push_back({events.size() - 1, t0});
					} else if(tk.s != "." && tk.s != "-"){
						token(tk, e);
						int j = i + 1;
						while(j < len && toks[j % pat.len].s == "-")
							j++;
						double span = st(base + j) - st(base + i);
						double gate = e.stacc ? 0.5 * step_len : span * inst.gate;
						if(e.slide)
							gate = span + 0.06 * rate;
						e.glide = glide;
						glide = e.slide;
						e.vel = std::min(1.0, e.vel + vr);
						e.len = gate;
						e.inst = inst_with(tp.inst, over);
						events.push_back(e);
						times.push_back({events.size() - 1, t0});
					} else if(tk.s == ".")
						glide = false;
				}
			}
		};
		for(const ss_ &name : play){
			if(name == loop && loop_step < 0)
				loop_step = cursor;
			for(const Entry &e : sections.at(name))
				for(int r = 0; r < e.rep; r++){
					int len = 0;
					for(const ss_ &pn : e.layer)
						len = std::max(len, patterns.at(pn).len);
					for(const ss_ &pn : e.layer)
						emit(patterns.at(pn), cursor, len);
					cursor += len;
					if(cursor * step_len > MAX_SECONDS * rate){
						ln = 0;
						err("the play order is over " +
								std::to_string((int)MAX_SECONDS / 60) + " minutes");
					}
				}
		}
		const int64_t end_t = (int64_t)std::floor(cursor * step_len + 0.5);
		for(auto &ft : times){
			int64_t t = (int64_t)std::floor(ft.second + 0.5);
			events[ft.first].t = std::min(t, end_t - 1);
		}
		std::stable_sort(events.begin(), events.end(),
				[](const Event &a, const Event &b){ return a.t < b.t; });
		song.step_len = step_len;
		song.bar_len = step_len * song.steps;
		song.end_t = end_t;
		song.loop_t = (int64_t)std::floor((loop_step < 0 ? 0 : loop_step) *
				step_len + 0.5);
		song.loop_ei = events.size();
		for(size_t i = 0; i < events.size(); i++)
			if(events[i].t >= song.loop_t){
				song.loop_ei = i;
				break;
			}
		if(end_t <= song.loop_t)
			err("the song is empty");
	}
	// each event's time before rounding
	sv_<std::pair<size_t, double>> times;
};
} // namespace

std::shared_ptr<const Song> parse(const ss_ &text, ss_ *error, double tempo)
{
	auto song = std::make_shared<Song>();
	Parser p(*song);
	try{
		if(text.size() > MAX_TEXT)
			throw Error{"the text is " + std::to_string(text.size()) +
					" bytes, " + std::to_string(MAX_TEXT) + " at most"};
		size_t i = 0;
		while(i <= text.size()){
			size_t j = text.find('\n', i);
			if(j == ss_::npos) j = text.size();
			p.ln++;
			p.line(text.substr(i, j - i));
			i = j + 1;
		}
		p.finish();
		if(tempo > 0)
			song->tempo = std::max(20.0, std::min(400.0, tempo));
		p.compile(RATE);
	} catch(Error &e){
		if(error)
			*error = e.msg;
		return nullptr;
	}
	return song;
}

Info info(const Song &s)
{
	Info i;
	i.title = s.title;
	i.tempo = s.tempo;
	i.bar_len = s.bar_len;
	i.loop_start = s.loop_t;
	i.end = s.end_t;
	i.events = s.events.size();
	i.tracks = s.track_names;
	for(auto &m : s.moods)
		i.moods.push_back(m.first);
	return i;
}

int64_t song_sample(const Song &s, int64_t at)
{
	if(at < 0)
		return 0;
	if(at < s.end_t)
		return at;
	return s.loop_t + (at - s.loop_t) % (s.end_t - s.loop_t);
}

int64_t bar_of(const Song &s, int64_t at)
{
	return (int64_t)std::floor(song_sample(s, at) / s.bar_len);
}

// ---- Voices

struct Voice
{
	const Inst *p = nullptr;
	double midi = 0, vel = 0, lf = 0, lt = 0, gate = 0, t = 0, iv = 0;
	int32_t rng = 1;
	bool mute = false, open = false, killed = false, done = false;
	int64_t offset = 0;
	double level = 0, env = 0, ainc = 0, dc = 0, rc = 0, dg = 0;
	int stage = 1;
	int fmode = 0, fstage = 1;
	double fic[4] = {0, 0, 0, 0}, fenv = 0, finc = 0, fdc = 0, frc = 0;
	// osc
	int w1 = 0, w2 = 0;
	double ph1 = 0, ph2 = 0, ph3 = 0, r2 = 1;
	// pluck
	sv_<double> ks, exc;
	int ne = 0, wi = 0;
	double lp = 0, c = 0;
	// fm
	double pc = 0, pm = 0, pt = 0, ie = 1, te = 1;
	// kick, snare
	double ph = 0, pe = 1, ce = 1, c1 = 0, c2 = 0, be = 1, nenv = 1, nl = 0;
	double nst[2] = {0, 0};
	Svf nsvf;
	// hat
	double mph[6] = {0}, st1[2] = {0, 0}, st2[2] = {0, 0}, bph = 0, bel = 1;
	Svf hc1, hc2;
};

static const double METAL[6] = {205.3, 304.4, 369.6, 522.7, 540.0, 800.0};

static void voice_init(Voice &v, const Inst *p, double midi, double vel,
		double len, int32_t seed, bool mute, bool open)
{
	v.p = p;
	v.midi = midi;
	v.vel = vel;
	v.lf = v.lt = midi + p->tune / 100;
	v.gate = len;
	v.t = 0;
	v.rng = seed;
	v.mute = mute;
	v.open = open;
	v.killed = v.done = false;
	v.offset = 0;
	v.iv = 0;
	v.level = (1 + p->vels * (vel - 1)) * db(p->gain);
	v.env = 0;
	v.stage = 1;
	v.ainc = 1 / std::max(1.0, p->a * RATE);
	v.dc = t60(p->d);
	v.rc = t60(p->r);
	v.fmode = p->ftype;
	if(v.fmode){
		for(double &x : v.fic) x = 0;
		v.fenv = 0;
		v.fstage = 1;
		v.finc = 1 / std::max(1.0, p->fa * RATE);
		v.fdc = t60(p->fd / 16);
		v.frc = t60(p->fr / 16);
	}
	v.dg = p->drive > 0 ? db(p->drive) : 0;
	switch(p->src){
	case S_OSC:
		v.w1 = p->wave;
		v.w2 = p->wave2;
		v.ph1 = 0;
		v.ph2 = (double)fmod_i(v.rng, 1000) / 1000;
		v.ph3 = 0;
		v.r2 = exp2_((p->detune2 / 100 + 12 * p->oct2) / 12);
		break;
	case S_PLUCK: {
		std::fill(v.ks.begin(), v.ks.end(), 0.0);
		v.wi = 0;
		v.lp = 0;
		double f = midi_hz(v.lf);
		int P = std::max(4, (int)std::floor(RATE / f + 0.5));
		if(P > 2048) P = 2048;
		double br = v.mute ? p->mbright : p->bright;
		double e = 0.05 + 0.95 * br * (0.4 + 0.6 * v.vel);
		int32_t s = v.rng;
		double y = 0, sum = 0;
		for(int i = 0; i < P; i++){
			double x = rnd(s);
			y = y + e * (x - y);
			v.exc[i] = y;
			sum = sum + y;
		}
		int pk = (int)std::floor(p->pick * P);
		for(int i = P; i >= 1; i--) // pick position: a comb on the burst
			v.exc[i - 1] = v.exc[i - 1] - sum / P -
					((i > pk && pk > 0) ? v.exc[i - pk - 1] * 0.9 : 0);
		v.ne = P;
		v.rng = s;
		v.c = 0.15 + 0.85 * br;
		break;
	}
	case S_FM:
		v.pc = v.pm = v.pt = 0;
		v.ie = 1;
		v.te = 1;
		break;
	case S_KICK:
		v.ph = 0; v.pe = 1; v.ce = 1; v.c1 = 0; v.c2 = 0;
		break;
	case S_SNARE:
	case S_TOM:
		v.ph1 = v.ph2 = 0;
		v.pe = v.be = v.nenv = 1;
		v.nst[0] = v.nst[1] = 0;
		v.nl = 0;
		v.nsvf = svf_coef(p->nfreq * (0.7 + 0.3 * v.vel), 0.15);
		break;
	case S_HAT:
	case S_CYMBAL: {
		for(int i = 0; i < 6; i++)
			v.mph[i] = (double)fmod_i(hash3(v.rng, i, 0), 1000) / 1000;
		v.st1[0] = v.st1[1] = v.st2[0] = v.st2[1] = 0;
		double f = p->nfreq * (0.85 + 0.15 * v.vel);
		v.hc1 = svf_coef(f, 0.35);
		v.hc2 = svf_coef(f * 0.7, 0.1);
		v.bph = 0;
		v.bel = 1;
		if(v.open)
			v.dc = t60(p->odecay);
		break;
	}
	}
}

// Stop at once (a choke, a mono track's new note): a 6 ms release
static void voice_kill(Voice &v)
{
	if(v.gate > 0) v.gate = 0;
	v.rc = t60(0.006);
	v.killed = true;
}

static void src_osc(Voice &v, double *buf, const double *fb, int n)
{
	const Inst &p = *v.p;
	int w1 = v.w1, w2 = v.w2;
	double r2 = v.r2, ph1 = v.ph1, ph2 = v.ph2, ph3 = v.ph3;
	int32_t s = v.rng;
	double m2 = w2 > 0 ? p.mix2 : 0, m1 = 1 - m2, sub = p.sub, nz = p.noise;
	double pwm = p.pwm, pwr = p.pwmrate / RATE, t = v.t;
	for(int i = 0; i < n; i++){
		double dt = fb[i] / RATE;
		double pw = p.pw + pwm * 0.45 * sin_ph(pwr * (t + i));
		double y = m1 * osc(w1, ph1, dt, pw);
		ph1 = ph1 + dt; if(ph1 >= 1) ph1 = ph1 - 1;
		if(w2 > 0){
			y = y + m2 * osc(w2, ph2, dt * r2, pw);
			ph2 = ph2 + dt * r2; if(ph2 >= 1) ph2 = ph2 - 1;
		}
		if(sub > 0){
			y = y + sub * osc(2, ph3, dt * 0.5, 0.5);
			ph3 = ph3 + dt * 0.5; if(ph3 >= 1) ph3 = ph3 - 1;
		}
		if(nz > 0) y = y + nz * rnd(s);
		buf[i] = y;
	}
	v.ph1 = ph1; v.ph2 = ph2; v.ph3 = ph3; v.rng = s;
}

// Karplus-Strong: a burst into a delay line of one period, a one-pole
// low-pass in the loop; a palm mute is a darker, shorter loop; the gate's
// end damps the string
static void src_pluck(Voice &v, double *buf, const double *fb, int n)
{
	const Inst &p = *v.p;
	double *ks = v.ks.data();
	const double *exc = v.exc.data();
	int w = v.wi;
	double lp = v.lp, t = v.t, gate = v.gate;
	double f0 = fb[0];
	double dec = v.mute ? p.mdecay : p.decay;
	double rho = d_pow(0.001, 1 / (dec * f0));
	double rrho = d_pow(0.001, 1 / (p.rdecay * f0));
	double c = v.c;
	if(v.killed) rrho = d_pow(0.001, 1 / (0.006 * f0));
	double comp = (1 - c) / c;
	for(int i = 0; i < n; i++){
		double g = i >= gate ? rrho : rho;
		double D = RATE / fb[i] - comp;
		if(D < 2) D = 2;
		if(D > 2046) D = 2046;
		double rp = w - D;
		double rf = std::floor(rp);
		int ri = (int)rf;
		double fr = rp - rf;
		double y = ks[ri & 2047] * (1 - fr) + ks[(ri + 1) & 2047] * fr;
		lp = lp + c * (y - lp);
		double s = g * lp;
		int64_t k = (int64_t)t + i + 1;
		if(k <= v.ne) s = s + exc[k - 1];
		ks[w] = s;
		w = (w + 1) & 2047;
		buf[i] = s;
	}
	v.wi = w;
	v.lp = flush(lp);
}

static void src_fm(Voice &v, double *buf, const double *fb, int n)
{
	const Inst &p = *v.p;
	double pc = v.pc, pm = v.pm, pt = v.pt, ie = v.ie, te = v.te;
	double ic = t60(p.idecay);
	double idx = p.index * (0.5 + 0.5 * v.vel);
	double tl = p.tine * v.vel, tc = t60(p.tdecay);
	for(int i = 0; i < n; i++){
		double dt = fb[i] / RATE;
		double I = idx * (p.ifloor + (1 - p.ifloor) * ie);
		buf[i] = sin_ph(pc + I * sin_ph(pm) / TAU) + tl * te * sin_ph(pt);
		pc = pc + dt; pm = pm + dt * p.ratio; pt = pt + dt * p.tratio;
		if(pc >= 1) pc = pc - 1;
		if(pm >= 1) pm = pm - 1;
		if(pt >= 1) pt = pt - 1;
		ie = ie * ic; te = te * tc;
	}
	v.pc = pc; v.pm = pm; v.pt = pt; v.ie = flush(ie); v.te = flush(te);
}

static void src_kick(Voice &v, double *buf, const double *, int n)
{
	const Inst &p = *v.p;
	double ph = v.ph, pe = v.pe, ce = v.ce, c1 = v.c1, c2 = v.c2;
	int32_t s = v.rng;
	double pc = t60(p.pdecay * 7), cc = t60(0.03);
	double f0 = p.tone, dr = p.pdrop - 1, cl = p.click * v.vel;
	for(int i = 0; i < n; i++){
		double f = f0 * (1 + dr * pe);
		ph = ph + f / RATE; if(ph >= 1) ph = ph - 1;
		double x = rnd(s);
		c1 = c1 + 0.5 * (x - c1); c2 = c2 + 0.13 * (x - c2);
		buf[i] = sin_ph(ph) + 3 * cl * ce * (c1 - c2);
		pe = pe * pc; ce = ce * cc;
	}
	v.ph = ph; v.pe = flush(pe); v.ce = flush(ce); v.rng = s; v.c1 = c1; v.c2 = c2;
}

// snare and tom: two sine modes with a pitch drop, noise through a band
// pass (the wires); a tom's pitch is its note
static void src_snare(Voice &v, double *buf, const double *fb, int n)
{
	const Inst &p = *v.p;
	double ph1 = v.ph1, ph2 = v.ph2, pe = v.pe, be = v.be, ne = v.nenv;
	int32_t s = v.rng;
	double pc = t60(p.pdecay * 7), bc = t60(p.d * 0.5), nc = t60(p.ndecay);
	double f0 = p.src == S_TOM ? fb[0] : p.tone;
	double dr = p.pdrop - 1, sn = p.snappy;
	const Svf &cf = v.nsvf;
	double ic1 = v.nst[0], ic2 = v.nst[1];
	double nl = v.nl, lc = 1 - d_exp(-TAU * 9000 / RATE);
	for(int i = 0; i < n; i++){
		double f = f0 * (1 + dr * pe);
		ph1 = ph1 + f / RATE; if(ph1 >= 1) ph1 = ph1 - 1;
		ph2 = ph2 + 1.59 * f / RATE; if(ph2 >= 1) ph2 = ph2 - 1;
		double x = rnd(s);
		double v3 = x - ic2;
		double v1 = cf.a1 * ic1 + cf.a2 * v3;
		double v2 = ic2 + cf.a2 * ic1 + cf.a3 * v3;
		ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2;
		double body = (0.75 * sin_ph(ph1) + 0.35 * sin_ph(ph2)) * be;
		nl = nl + lc * (1.3 * v1 + 0.35 * (x - cf.k * v1 - v2) - nl);
		buf[i] = body * (1 - 0.4 * sn) + nl * ne * sn * 1.6;
		pe = pe * pc; be = be * bc; ne = ne * nc;
	}
	v.nst[0] = ic1; v.nst[1] = ic2;
	v.nl = nl;
	v.ph1 = ph1; v.ph2 = ph2; v.pe = flush(pe); v.be = flush(be);
	v.nenv = flush(ne); v.rng = s;
}

// hat and cymbal: six squares at the TR-808's ratios and noise, through a
// band and a high pass; an open hat decays by odecay; a bell partial
static void src_hat(Voice &v, double *buf, const double *, int n)
{
	const Inst &p = *v.p;
	int32_t s = v.rng;
	double m = p.metal, nz = p.noise;
	double sc = p.tone / 50;
	double bel = v.bel, bph = v.bph, bc = t60(1.2), bl = p.bell;
	for(int i = 0; i < n; i++){
		double y = 0;
		for(int j = 0; j < 6; j++){
			double ph = v.mph[j] + METAL[j] * sc / RATE;
			if(ph >= 1) ph = ph - 1;
			v.mph[j] = ph;
			y = y + (ph < 0.5 ? 1 : -1);
		}
		double x = rnd(s);
		buf[i] = y * m * 0.18 + x * nz;
	}
	svf_run(v.st1, buf, n, 2, v.hc1);
	svf_run(v.st2, buf, n, 3, v.hc2);
	if(bl > 0){
		double bf = 2350 * sc / RATE;
		for(int i = 0; i < n; i++){
			buf[i] = buf[i] + bl * bel * sin_ph(bph);
			bph = bph + bf; if(bph >= 1) bph = bph - 1;
			bel = bel * bc;
		}
	}
	v.rng = s; v.bel = flush(bel); v.bph = bph;
}

// Adds n samples into out from out[0]
static void voice_render(Voice &v, double *out, int n, double *fbuf,
		double *sbuf)
{
	const Inst &p = *v.p;
	double lf = v.lf, lt = v.lt;
	double gk = p.glide > 0 ? 1 - d_exp(-1 / (p.glide * 0.3 * RATE)) : 1;
	double vib = p.vib / 100, vr = p.vibrate / RATE, vd = p.vibdelay * RATE;
	double t = v.t;
	if(lf == lt && vib == 0){
		double f = midi_hz(lf);
		for(int i = 0; i < n; i++) fbuf[i] = f;
	} else {
		for(int i = 0; i < n; i++){
			lf = lf + (lt - lf) * gk;
			double m = lf;
			if(vib != 0 && t + i > vd){
				double ramp = std::min(1.0, (t + i - vd) / (0.3 * RATE));
				m = m + vib * ramp * sin_ph(vr * (t + i));
			}
			fbuf[i] = midi_hz(m);
		}
		v.lf = lf;
	}
	switch(p.src){
	case S_OSC: src_osc(v, sbuf, fbuf, n); break;
	case S_PLUCK: src_pluck(v, sbuf, fbuf, n); break;
	case S_FM: src_fm(v, sbuf, fbuf, n); break;
	case S_KICK: src_kick(v, sbuf, fbuf, n); break;
	case S_SNARE: case S_TOM: src_snare(v, sbuf, fbuf, n); break;
	default: src_hat(v, sbuf, fbuf, n); break;
	}
	// the voice's filter, its cutoff stepped every 16 samples
	if(v.fmode){
		const int mode = v.fmode, poles = p.poles;
		double ic1 = v.fic[0], ic2 = v.fic[1], ic3 = v.fic[2], ic4 = v.fic[3];
		double fenv = v.fenv, gate = v.gate;
		int fst = v.fstage;
		double key = p.ktrack * (v.midi - 60) / 12 + p.velf * (v.vel - 1);
		Svf c;
		for(int i = 0; i < n; i++){
			if((i & 15) == 0){
				if(i >= gate && fst < 4) fst = 4;
				if(fst == 1){
					fenv = fenv + v.finc * 16;
					if(fenv >= 1){ fenv = 1; fst = 2; }
				} else if(fst == 2)
					fenv = p.fs + (fenv - p.fs) * v.fdc;
				else
					fenv = fenv * v.frc;
				c = svf_coef(p.cut * exp2_(p.fenv * fenv + key), p.res);
			}
			double v0 = sbuf[i];
			double v3 = v0 - ic2;
			double v1 = c.a1 * ic1 + c.a2 * v3;
			double v2 = ic2 + c.a2 * ic1 + c.a3 * v3;
			ic1 = 2 * v1 - ic1; ic2 = 2 * v2 - ic2;
			double y = mode == 1 ? v2 : mode == 2 ? v1 : v0 - c.k * v1 - v2;
			if(poles == 4){
				v3 = y - ic4;
				v1 = c.a1 * ic3 + c.a2 * v3;
				v2 = ic4 + c.a2 * ic3 + c.a3 * v3;
				ic3 = 2 * v1 - ic3; ic4 = 2 * v2 - ic4;
				y = mode == 1 ? v2 : mode == 2 ? v1 : y - c.k * v1 - v2;
			}
			sbuf[i] = y;
		}
		v.fic[0] = ic1; v.fic[1] = ic2; v.fic[2] = ic3; v.fic[3] = ic4;
		v.fenv = flush(fenv);
		v.fstage = fst;
	}
	// the amp ADSR, the drive, the level; added into out
	double env = v.env, gate = v.gate;
	int st = v.stage;
	const double ainc = v.ainc, dc = v.dc, rc = v.rc, sus = p.s, dg = v.dg,
			level = v.level;
	for(int i = 0; i < n; i++){
		if(i >= gate && st < 4) st = 4;
		if(st == 1){
			env = env + ainc;
			if(env >= 1){ env = 1; st = 2; }
		} else if(st == 2)
			env = sus + (env - sus) * dc;
		else if(st == 4)
			env = env * rc;
		double x = sbuf[i];
		if(dg > 0) x = sat(x * dg);
		out[i] = out[i] + x * env * level;
	}
	v.env = env;
	v.stage = st;
	v.gate = gate - n;
	v.t = t + n;
	if(((st == 4 || (st == 2 && sus == 0)) && env < 1e-4) || v.t > RATE * 30)
		v.done = true;
}

// ---- Tracks and buses

struct Comp
{
	double thr = 0, sl = 0, env = 0, ac = 0, rc = 0, mk = 1, gr = 0;
	void init(double t, double ratio, double attack, double release, double makeup)
	{
		thr = t;
		sl = 1 - 1 / ratio;
		env = 0;
		ac = d_exp(-1 / (attack * RATE));
		rc = d_exp(-1 / (release * RATE));
		mk = db(makeup);
	}
	void run(double *L, double *R, int n)
	{
		double e2 = env;
		for(int i = 0; i < n; i++){
			double e = std::fabs(L[i]);
			if(R) e = std::max(e, std::fabs(R[i]));
			if(e > e2) e2 = ac * e2 + (1 - ac) * e;
			else e2 = rc * e2 + (1 - rc) * e;
			double g = mk;
			if(e2 > 1e-6){
				double over = 20 * log2_(e2) * LN2 / 2.302585 - thr;
				if(over > 0){
					g = mk * exp2_(-over * sl / 20 * LOG2_10);
					if(over * sl > gr) gr = over * sl;
				}
			}
			L[i] = L[i] * g;
			if(R) R[i] = R[i] * g;
		}
		env = flush(e2);
	}
};

struct Track
{
	const TrackP *tp = nullptr;
	double bus[BLOCK], dry[BLOCK];
	sv_<Voice*> voices;
	double mood = 1, mood_to = 1, mood_fade = 1;
	int ramp_from = 0;
	int64_t idle = 0;
	double gl = 0, gr = 0, rev = 0, dly = 0, trem = 0, trem_period = 1;
	int64_t seed = 0;
	bool solo_off = false;
	bool amp = false;
	double g1 = 0, g2 = 0, bias = 0, blend = 1, ampo = 1, x1 = 0, y1 = 0, d1 = 0;
	Biquad pre[3], post[6];
	sv_<Biquad> eq;
	bool has_comp = false;
	Comp comp;
	float tapbuf[BLOCK];
};

struct Reverb
{
	sv_<double> lines, ap, pre;
	int lens[8], apl[4];
	double g[8], lp[8], o[8];
	double damp = 0, mix = 0;
	int prel = 0;
	int64_t w = 0;
	Biquad hp;
	void init(const std::map<ss_, double> &p)
	{
		static const int RLEN[8] = {1031, 1327, 1523, 1783, 2011, 2269, 2503,
			2777};
		static const int APLEN[4] = {142, 107, 379, 277};
		auto get = [&](const char *k, double d){
			auto it = p.find(k);
			return it == p.end() ? d : it->second;
		};
		double size = get("size", 0.8), decay = get("decay", 1.6);
		lines.assign(8 * 4096, 0.0);
		for(int i = 0; i < 8; i++){
			lens[i] = (int)std::floor(RLEN[i] * size * RATE / 44100.0);
			g[i] = d_exp(-3 * lens[i] / (decay * RATE) * LN2 * LOG2_10);
			lp[i] = 0;
			o[i] = 0;
		}
		damp = 1 - get("damp", 0.4);
		w = 0;
		ap.assign(4 * 1024, 0.0);
		for(int i = 0; i < 4; i++)
			apl[i] = (int)std::floor(APLEN[i] * size * RATE / 44100.0);
		pre.assign(8192, 0.0);
		prel = (int)std::floor(get("predelay", 0.012) * RATE);
		mix = db(get("gain", 0)) * 0.3;
		hp = biquad(BQ_HP, get("lowcut", 180), 0.7, 0);
	}
	void run(double *inp, double *L, double *R, int n)
	{
		bq_run(hp, inp, n);
		for(int i = 0; i < n; i++){
			int64_t wi = w;
			pre[wi & 8191] = inp[i];
			double x = pre[(wi - prel) & 8191];
			for(int a = 0; a < 4; a++){
				int base = a * 1024;
				double d = ap[base + ((wi - apl[a]) & 1023)];
				double u = flush(x + 0.6 * d);
				ap[base + (wi & 1023)] = u;
				x = d - 0.6 * u;
			}
			double sum = 0;
			for(int j = 0; j < 8; j++){
				double y = lines[j * 4096 + ((wi - lens[j]) & 4095)];
				double l = lp[j] + damp * (y - lp[j]);
				lp[j] = l;
				l = l * g[j];
				o[j] = l;
				sum = sum + l;
			}
			sum = sum * 0.25;
			for(int j = 0; j < 8; j++)
				lines[j * 4096 + (wi & 4095)] = flush(x * ((j % 2 == 0) ? 1 : -1) +
						o[j] - sum);
			L[i] = L[i] + (o[0] - o[2] + o[4] - o[6]) * mix;
			R[i] = R[i] + (o[1] - o[3] + o[5] - o[7]) * mix;
			w = w + 1;
		}
		for(double &x : lp) x = flush(x);
	}
};

struct Delay
{
	sv_<double> bl, br;
	int len = 0;
	double fb = 0, c = 0, lpl = 0, lpr = 0, mix = 0;
	int64_t w = 0;
	void init(const std::map<ss_, double> &p, double step_len)
	{
		auto get = [&](const char *k, double d){
			auto it = p.find(k);
			return it == p.end() ? d : it->second;
		};
		bl.assign(131072, 0.0);
		br.assign(131072, 0.0);
		len = (int)std::min(131000.0, std::floor(get("time", 3) * step_len));
		fb = get("feedback", 0.35);
		c = 1 - d_exp(-TAU * get("tone", 2500) / RATE);
		lpl = lpr = 0;
		w = 0;
		mix = db(get("gain", 0));
	}
	void run(double *inp, double *L, double *R, int n)
	{
		for(int i = 0; i < n; i++){
			int64_t r = (w - len) & 131071;
			lpl = lpl + c * (bl[r] - lpl);
			lpr = lpr + c * (br[r] - lpr);
			bl[w & 131071] = flush(inp[i] + fb * lpr);
			br[w & 131071] = flush(fb * lpl);
			L[i] = L[i] + lpl * mix;
			R[i] = R[i] + lpr * mix;
			w = w + 1;
		}
		lpl = flush(lpl);
		lpr = flush(lpr);
	}
};

// The limiter: 63 samples of lookahead, a 64-sample window minimum,
// box-smoothed; the detector also reads the midpoints between samples
struct Limiter
{
	static const int LA = 64;
	double ceil_ = 1, rc = 0, sum = LA, g = 1, gmin = 1;
	double dl[LA], dr[LA], req[LA], box[LA], h[6];
	int w = 0, dw = 0, below = 0; // below: entries of req under 1
	void init(double ceiling, double release)
	{
		ceil_ = db(ceiling);
		rc = d_exp(-1 / (release * RATE));
		reset();
	}
	void reset()
	{
		for(int i = 0; i < LA; i++){
			dl[i] = dr[i] = 0;
			req[i] = box[i] = 1;
		}
		for(double &x : h) x = 0;
		sum = LA;
		g = 1;
		w = dw = below = 0;
	}
	void run(double *L, double *R, int n)
	{
		for(int i = 0; i < n; i++){
			double xl = L[i], xr = R[i];
			double ml = (9 * (h[0] + h[1]) - h[2] - xl) * 0.0625;
			double mr = (9 * (h[3] + h[4]) - h[5] - xr) * 0.0625;
			h[2] = h[1]; h[1] = h[0]; h[0] = xl;
			h[5] = h[4]; h[4] = h[3]; h[3] = xr;
			double pk = std::max(std::max(std::fabs(xl), std::fabs(xr)),
					std::max(std::fabs(ml), std::fabs(mr)));
			below -= req[w] < 1;
			req[w] = pk > ceil_ ? ceil_ / pk : 1;
			below += req[w] < 1;
			double m = 1;
			if(below > 0)
				for(int j = 0; j < LA; j++)
					if(req[j] < m) m = req[j];
			sum = sum - box[w] + m;
			box[w] = m;
			double tgt = sum / LA;
			if(tgt < g) g = tgt; else g = tgt + (g - tgt) * rc;
			if(g < gmin) gmin = g;
			w = w + 1; if(w == LA) w = 0;
			double ol = dl[dw], orr = dr[dw];
			dl[dw] = xl; dr[dw] = xr;
			dw = dw + 1; if(dw == LA - 1) dw = 0;
			ol = ol * g; orr = orr * g;
			if(ol > ceil_) ol = ceil_; else if(ol < -ceil_) ol = -ceil_;
			if(orr > ceil_) orr = ceil_; else if(orr < -ceil_) orr = -ceil_;
			// (a NaN from anywhere is silence, not undefined in a cast later)
			L[i] = ol == ol ? ol : 0;
			R[i] = orr == orr ? orr : 0;
		}
	}
};

// ---- The engine

struct EngineImpl
{
	std::shared_ptr<const Song> song;
	const Song &S;
	sv_<Track> tracks;
	sv_<Voice> pool;
	sv_<Voice*> free_voices;
	Reverb reverb;
	Delay delay;
	bool has_comp = false;
	Comp comp;
	double gain = 1;
	Limiter limiter;
	double L[BLOCK], R[BLOCK], rin[BLOCK], din[BLOCK], fbuf[BLOCK], sbuf[BLOCK];
	float outL[BLOCK], outR[BLOCK];
	int out_at = BLOCK; // the next unread sample of out
	int64_t pos = 0, abs = 0; // the song's sample, the timeline's
	size_t ei = 0;
	bool pending = false;
	int64_t pending_at = 0, mood_at = -1;
	sv_<double> pending_gains;
	bool tapping = false;

	explicit EngineImpl(std::shared_ptr<const Song> s): song(s), S(*s)
	{
		pool.resize(MAX_VOICES);
		for(Voice &v : pool){
			v.ks.assign(2048, 0.0);
			v.exc.assign(2048, 0.0);
			free_voices.push_back(&v);
		}
		std::reverse(free_voices.begin(), free_voices.end());
		tracks.resize(S.tracks.size());
		for(size_t i = 0; i < S.tracks.size(); i++)
			init_track(tracks[i], S.tracks[i], (int)i);
		reverb.init(S.reverb);
		delay.init(S.delay, S.step_len);
		auto mget = [&](const char *k, double d){
			auto it = S.master.find(k);
			return it == S.master.end() ? d : it->second;
		};
		has_comp = S.master.count("comp") != 0;
		if(has_comp)
			comp.init(mget("comp", 0), mget("ratio", 2), mget("catk", 0.01),
					mget("crel", 0.15), 0);
		gain = db(mget("gain", 0));
		limiter.init(mget("ceiling", -1), mget("release", 0.08));
	}

	void init_track(Track &t, const TrackP &tp, int index)
	{
		t.tp = &tp;
		t.voices.reserve(MAX_VOICES);
		double g = db(tp.gain);
		t.gl = d_cos((tp.pan + 1) * PI / 4) * g;
		t.gr = d_sin((tp.pan + 1) * PI / 4) * g;
		t.rev = tp.rev;
		t.dly = tp.dly;
		t.seed = tp.has("seed") ? (int64_t)tp.seed : index + 1;
		t.trem = tp.has("trem") ? tp.trem : 0;
		t.trem_period = tp.tremsteps * S.step_len;
		t.amp = tp.has("amp");
		if(t.amp){
			double ga = db(tp.amp);
			t.g1 = d_pow(ga, 0.6);
			t.g2 = d_pow(ga, 0.4);
			t.bias = tp.bias;
			t.blend = tp.blend;
			t.pre[0] = biquad(BQ_HP, tp.tight, 0.7, 0);
			t.pre[1] = biquad(BQ_PEAK, tp.mid, 0.8, tp.hump);
			t.pre[2] = biquad(BQ_LP, tp.fizz, 0.7, 0);
			t.post[0] = biquad(BQ_HP, 70, 0.7, 0);
			t.post[1] = biquad(BQ_PEAK, tp.thumpf, 1.0, tp.thump);
			t.post[2] = biquad(BQ_PEAK, 420, 1.0, -tp.mud);
			t.post[3] = biquad(BQ_PEAK, 2300, 1.2, tp.presence);
			t.post[4] = biquad(BQ_LP, tp.cab, 0.9, 0);
			t.post[5] = biquad(BQ_LP, tp.cab, 0.6, 0);
			t.ampo = db(tp.ampout);
		}
		t.eq.clear();
		if(tp.has("hp")) t.eq.push_back(biquad(BQ_HP, tp.hp, 0.7, 0));
		if(tp.has("lo")) t.eq.push_back(biquad(BQ_LOW, tp.lof, 0.7, tp.lo));
		if(tp.has("hi")) t.eq.push_back(biquad(BQ_HIGH, tp.hif, 0.7, tp.hi));
		if(tp.has("lp")) t.eq.push_back(biquad(BQ_LP, tp.lp, 0.7, 0));
		t.has_comp = tp.has("comp");
		if(t.has_comp)
			t.comp.init(tp.comp, tp.ratio, tp.catk, tp.crel, tp.makeup);
		t.x1 = t.y1 = t.d1 = 0;
		t.idle = 0;
	}

	void release(Track &t, size_t i)
	{
		free_voices.push_back(t.voices[i]);
	}

	// A soft clip stage at 2x: the midpoint and the sample both shaped,
	// averaged down (simplified: a 3-tap decimator, as the prototype)
	void run_amp(Track &t, double *buf, int n)
	{
		if(t.blend < 1)
			memcpy(t.dry, buf, n * sizeof(double));
		for(Biquad &q : t.pre) bq_run(q, buf, n);
		double g1 = t.g1, g2 = t.g2, bias = t.bias, x1 = t.x1, y1 = t.y1,
				d1 = t.d1;
		double sb = sat(bias);
		for(int i = 0; i < n; i++){
			double x = buf[i];
			double xm = 0.5 * (x + x1); x1 = x;
			double u1 = sat(xm * g1 + bias) - sb;
			double u2 = sat(x * g1 + bias) - sb;
			y1 = y1 + 0.55 * (u1 - y1); double w1 = sat(y1 * g2);
			y1 = y1 + 0.55 * (u2 - y1); double w2 = sat(y1 * g2);
			buf[i] = 0.25 * d1 + 0.5 * w1 + 0.25 * w2;
			d1 = w2;
		}
		if(std::fabs(y1) < 1e-15) y1 = 0;
		t.x1 = x1; t.y1 = y1; t.d1 = d1;
		for(Biquad &q : t.post) bq_run(q, buf, n);
		double o = t.ampo, bl = t.blend;
		for(int i = 0; i < n; i++)
			buf[i] = buf[i] * o * bl + (1 - bl) * t.dry[i];
	}

	void process(Track &t, int n)
	{
		double *bus = t.bus;
		for(int i = 0; i < n; i++) bus[i] = 0;
		size_t keep = 0;
		for(size_t i = 0; i < t.voices.size(); i++){
			Voice *v = t.voices[i];
			if(v->offset < n){
				int off = (int)v->offset;
				v->offset = 0;
				voice_render(*v, bus + off, n - off, fbuf, sbuf);
			} else
				v->offset -= n;
			if(!v->done)
				t.voices[keep++] = v;
			else
				free_voices.push_back(v);
		}
		t.voices.resize(keep);
		if(tapping)
			for(int i = 0; i < n; i++) t.tapbuf[i] = 0;
		if(t.mood == 0 && t.mood_to == 0)
			return;
		// a track idle for half a second skips its inserts: a silent
		// track costs nothing
		if(keep == 0){
			t.idle += n;
			if(t.idle > RATE / 2)
				return;
		} else
			t.idle = 0;
		if(t.amp) run_amp(t, bus, n);
		for(Biquad &q : t.eq) bq_run(q, bus, n);
		if(t.has_comp) t.comp.run(bus, nullptr, n);
		if(t.trem > 0){
			double d = t.trem;
			for(int i = 0; i < n; i++)
				bus[i] = bus[i] * (1 - d * 0.5 + d * 0.5 *
						sin_ph((double)(abs + i) / t.trem_period));
		}
		double gl = t.gl, gr = t.gr, rv = t.rev, dl = t.dly;
		double m = t.mood, mt = t.mood_to;
		double mstep = (mt - m) / std::max(1.0, t.mood_fade);
		for(int i = 0; i < n; i++){
			if(m != mt && i >= t.ramp_from){
				m = m + mstep;
				if((mstep > 0 && m > mt) || (mstep < 0 && m < mt)) m = mt;
			}
			double x = bus[i] * m;
			L[i] = L[i] + x * gl;
			R[i] = R[i] + x * gr;
			rin[i] = rin[i] + x * rv;
			din[i] = din[i] + x * dl;
			if(tapping) t.tapbuf[i] = (float)x;
		}
		t.mood = m;
		t.ramp_from = 0;
	}

	size_t voices_alive() const { return MAX_VOICES - free_voices.size(); }

	void spawn(const Event &e, int64_t offset)
	{
		Track &tr = tracks[e.track];
		const TrackP &tp = S.tracks[e.track];
		const Inst *inst = &S.insts[e.inst];
		if(e.glide){
			for(Voice *v : tr.voices)
				if(v->gate > 0 && !v->killed){
					v->lt = e.notes[0] + v->iv + v->p->tune / 100;
					v->gate = e.len;
				}
			return;
		}
		if(tp.mono != 0 || tp.choke != 0)
			for(Voice *v : tr.voices)
				voice_kill(*v);
		static const sv_<double> ZERO = {0};
		const sv_<double> &chord = inst->chord.empty() ? ZERO : inst->chord;
		int k = 0;
		const int nv = e.nn * (int)chord.size();
		for(int ni = 0; ni < e.nn; ni++)
			for(double iv : chord){
				k++;
				if(free_voices.empty())
					return;
				Voice *v = free_voices.back();
				free_voices.pop_back();
				double midi = e.notes[ni] + iv + tp.transpose;
				voice_init(*v, inst, midi, e.vel, e.len, hash3(tr.seed, e.t, k),
						e.mute, e.open);
				double cents = tp.tune + inst->spread * (k - (nv + 1) / 2.0);
				v->lf = v->lf + cents / 100;
				v->lt = v->lt + cents / 100;
				v->iv = iv + tp.transpose + cents / 100;
				v->offset = offset + (int64_t)std::floor((k - 1) * inst->strum *
						RATE);
				tr.voices.push_back(v);
			}
	}

	void block()
	{
		const int n = BLOCK;
		for(int i = 0; i < n; i++)
			L[i] = R[i] = rin[i] = din[i] = 0;
		if(pending && pending_at < abs + n){
			int off = (int)std::max<int64_t>(0, pending_at - abs);
			for(size_t i = 0; i < tracks.size(); i++){
				Track &t = tracks[i];
				if(t.solo_off)
					continue;
				t.mood_to = pending_gains[i];
				t.mood_fade = S.step_len * S.beat;
				t.ramp_from = off;
			}
			mood_at = abs + off;
			pending = false;
		}
		// the events, sample-exact, the loop wrapping inside the block
		const sv_<Event> &evs = S.events;
		int k = 0;
		while(k < n){
			int64_t chunk = std::min<int64_t>(n - k, S.end_t - pos);
			int64_t lim = pos + chunk;
			while(ei < evs.size() && evs[ei].t < lim){
				spawn(evs[ei], k + evs[ei].t - pos);
				ei++;
			}
			pos = lim;
			k += (int)chunk;
			if(pos >= S.end_t){
				pos = S.loop_t;
				ei = S.loop_ei;
			}
		}
		for(Track &t : tracks) process(t, n);
		reverb.run(rin, L, R, n);
		delay.run(din, L, R, n);
		if(has_comp) comp.run(L, R, n);
		for(int i = 0; i < n; i++){
			L[i] = L[i] * gain;
			R[i] = R[i] * gain;
		}
		limiter.run(L, R, n);
		for(int i = 0; i < n; i++){
			outL[i] = (float)L[i];
			outR[i] = (float)R[i];
		}
		abs += n;
	}

	void seek(int64_t at)
	{
		if(at < 0) at = 0;
		for(Track &t : tracks){
			for(Voice *v : t.voices)
				free_voices.push_back(v);
			t.voices.clear();
			const TrackP &tp = *t.tp;
			double m = t.mood_to;
			bool solo = t.solo_off;
			init_track(t, tp, (int)(&t - &tracks[0]));
			t.mood = t.mood_to = m;
			t.solo_off = solo;
		}
		reverb.init(S.reverb);
		delay.init(S.delay, S.step_len);
		if(has_comp)
			comp.env = 0;
		limiter.reset();
		if(pending){
			for(size_t i = 0; i < tracks.size(); i++)
				if(!tracks[i].solo_off)
					tracks[i].mood = tracks[i].mood_to = pending_gains[i];
			pending = false;
		}
		abs = at;
		pos = song_sample(S, at);
		ei = std::lower_bound(S.events.begin(), S.events.end(), pos,
				[](const Event &e, int64_t p){ return e.t < p; }) -
				S.events.begin();
		out_at = BLOCK;
	}
};

Engine::Engine(std::shared_ptr<const Song> song): m(new EngineImpl(song)) {}
Engine::~Engine() { delete m; }

void Engine::render(float *left, float *right, size_t n)
{
	size_t done = 0;
	while(done < n){
		if(m->out_at >= BLOCK){
			m->block();
			m->out_at = 0;
		}
		size_t k = std::min(n - done, (size_t)(BLOCK - m->out_at));
		memcpy(left + done, m->outL + m->out_at, k * sizeof(float));
		memcpy(right + done, m->outR + m->out_at, k * sizeof(float));
		m->out_at += (int)k;
		done += k;
	}
}

bool Engine::set_mood(const ss_ &name, bool now)
{
	const Song &S = m->S;
	sv_<double> g(S.tracks.size(), 1.0);
	if(name != "" && name != "all"){
		auto it = S.moods.find(name);
		if(it == S.moods.end())
			return false;
		g = it->second;
	}
	// (from the block being rendered next: the song's place there)
	int64_t at = m->abs;
	if(!now){
		double into = (double)m->pos - std::floor(m->pos / S.bar_len) * S.bar_len;
		if(into > 0)
			at = at + (int64_t)std::floor(S.bar_len - into + 0.5);
	}
	m->pending = true;
	m->pending_at = at;
	m->pending_gains = g;
	if(now && m->out_at >= BLOCK)
		for(size_t i = 0; i < m->tracks.size(); i++)
			if(!m->tracks[i].solo_off)
				m->tracks[i].mood = m->tracks[i].mood_to = g[i];
	return true;
}

void Engine::seek(int64_t at) { m->seek(at); }
int64_t Engine::position() const { return m->abs - (BLOCK - m->out_at); }
int64_t Engine::mood_at() const { return m->mood_at; }
size_t Engine::voices() const { return m->voices_alive(); }
size_t Engine::block_size() const { return BLOCK; }

void Engine::solo(const sv_<ss_> &names)
{
	for(size_t i = 0; i < m->tracks.size(); i++){
		bool on = std::find(names.begin(), names.end(), m->S.track_names[i]) !=
				names.end();
		m->tracks[i].solo_off = !on;
		if(!on)
			m->tracks[i].mood = m->tracks[i].mood_to = 0;
	}
}

void Engine::tap(bool on) { m->tapping = on; }
const float* Engine::tapped(size_t i) const { return m->tracks[i].tapbuf; }

// ---- Measured

static ss_ hex64(uint64_t h)
{
	char b[17];
	snprintf(b, sizeof b, "%016llx", (unsigned long long)h);
	return b;
}

static void fnv(uint64_t &h, const float *s, size_t n)
{
	for(size_t i = 0; i < n; i++){
		uint32_t u;
		memcpy(&u, &s[i], 4);
		for(int k = 0; k < 4; k++){
			h ^= (u >> (k * 8)) & 0xff;
			h *= 1099511628211ull;
		}
	}
}

namespace {
// ITU-R BS.1770: K-weighted, 400 ms blocks a 100 ms hop, gated; one or two
// channels summed
struct Loudness
{
	Biquad s1[2], s2[2];
	double acc = 0;
	int64_t in_block = 0;
	sv_<double> blocks; // 100 ms sub-blocks' mean square
	double peak = 0;
	double band_e[5] = {0}, total_e = 0;
	Biquad bands[2][8];
	bool want_bands;
	explicit Loudness(bool bands_too): want_bands(bands_too)
	{
		for(int c = 0; c < 2; c++){
			double k = d_sin(PI * 1681.974450955533 / RATE) /
					d_cos(PI * 1681.974450955533 / RATE);
			double q = 0.7071752369554196;
			double vh = d_exp(3.999843853973347 / 20 * LN2 * LOG2_10);
			double vb = d_pow(vh, 0.4996667741545416);
			double a0 = 1 + k / q + k * k;
			s1[c].b0 = (vh + vb * k / q + k * k) / a0;
			s1[c].b1 = 2 * (k * k - vh) / a0;
			s1[c].b2 = (vh - vb * k / q + k * k) / a0;
			s1[c].a1 = 2 * (k * k - 1) / a0;
			s1[c].a2 = (1 - k / q + k * k) / a0;
			k = d_sin(PI * 38.13547087602444 / RATE) /
					d_cos(PI * 38.13547087602444 / RATE);
			q = 0.5003270373238773;
			a0 = 1 + k / q + k * k;
			s2[c].b0 = 1; s2[c].b1 = -2; s2[c].b2 = 1;
			s2[c].a1 = 2 * (k * k - 1) / a0;
			s2[c].a2 = (1 - k / q + k * k) / a0;
		}
		// the bands, each a pair of 2nd-order filters: sub < 60, low
		// 60..250, mid 250..2000, high 2000..6000, air > 6000
		static const double EDGE[4] = {60, 250, 2000, 6000};
		for(int c = 0; c < 1; c++)
			for(int b = 0; b < 4; b++){
				bands[c][b * 2] = biquad(BQ_LP, EDGE[b], 0.7071, 0);
				bands[c][b * 2 + 1] = biquad(BQ_HP, EDGE[b], 0.7071, 0);
			}
	}
	void add(const float *l, const float *r, int n)
	{
		double a[BLOCK], b[BLOCK], mono[BLOCK];
		for(int c = 0; c < (r ? 2 : 1); c++){
			const float *x = c == 0 ? l : r;
			for(int i = 0; i < n; i++){
				a[i] = x[i];
				double ax = std::fabs(a[i]);
				if(ax > peak) peak = ax;
			}
			bq_run(s1[c], a, n);
			bq_run(s2[c], a, n);
			for(int i = 0; i < n; i++)
				b[i] = (c == 0 ? 0 : b[i]) + a[i] * a[i];
		}
		for(int i = 0; i < n; i++){
			acc += b[i];
			if(++in_block == RATE / 10){
				blocks.push_back(acc / in_block);
				acc = 0;
				in_block = 0;
			}
		}
		if(!want_bands)
			return;
		for(int i = 0; i < n; i++)
			mono[i] = r ? 0.5 * (l[i] + r[i]) : l[i];
		// each band: what is under its upper edge less what is under its
		// lower one, run as low passes of the rest
		double rest[BLOCK];
		memcpy(rest, mono, sizeof rest);
		for(int bnd = 0; bnd < 4; bnd++){
			double lo[BLOCK], hi[BLOCK];
			memcpy(lo, rest, n * sizeof(double));
			memcpy(hi, rest, n * sizeof(double));
			bq_run(bands[0][bnd * 2], lo, n);
			bq_run(bands[0][bnd * 2 + 1], hi, n);
			for(int i = 0; i < n; i++)
				band_e[bnd] += lo[i] * lo[i];
			memcpy(rest, hi, n * sizeof(double));
		}
		for(int i = 0; i < n; i++){
			band_e[4] += rest[i] * rest[i];
			total_e += mono[i] * mono[i];
		}
	}
	double integrated() const
	{
		sv_<double> l;
		for(size_t i = 0; i + 4 <= blocks.size(); i++){
			double ms = (blocks[i] + blocks[i + 1] + blocks[i + 2] +
					blocks[i + 3]) / 4;
			l.push_back(ms);
		}
		auto lufs = [](double ms){
			return -0.691 + 10 * d_ln(std::max(ms, 1e-12)) / d_ln(10);
		};
		sv_<double> g;
		for(double ms : l)
			if(lufs(ms) > -70) g.push_back(ms);
		if(g.empty())
			return -99;
		double mean = 0;
		for(double ms : g) mean += ms;
		double rel = lufs(mean / g.size()) - 10;
		double s = 0;
		size_t c = 0;
		for(double ms : g)
			if(lufs(ms) > rel){ s += ms; c++; }
		return c ? lufs(s / c) : -99;
	}
	// short-term (3 s) loudness, its lowest and highest
	void short_term(double *lo, double *hi) const
	{
		*lo = 99; *hi = -99;
		for(size_t i = 0; i + 30 <= blocks.size(); i += 5){
			double s = 0;
			for(size_t k = 0; k < 30; k++) s += blocks[i + k];
			double v = -0.691 + 10 * d_ln(std::max(s / 30, 1e-12)) / d_ln(10);
			*lo = std::min(*lo, v);
			*hi = std::max(*hi, v);
		}
	}
};

ss_ fmt(const char *f, double v)
{
	char b[64];
	snprintf(b, sizeof b, f, v);
	return b;
}
ss_ quoted(const ss_ &s)
{
	ss_ o = "\"";
	for(char c : s){
		if(c == '"' || c == '\\') o += '\\';
		if((unsigned char)c >= 32) o += c;
	}
	return o + "\"";
}
double dbfs(double x) { return x > 1e-9 ? 20 * d_ln(x) / d_ln(10) : -180; }
ss_ bands_json(const Loudness &L)
{
	static const char *NAMES[5] = {"sub", "low", "mid", "high", "air"};
	ss_ o = "{";
	double tot = 0;
	for(double e : L.band_e) tot += e;
	for(int b = 0; b < 5; b++)
		o += ss_(b ? ", " : "") + "\"" + NAMES[b] + "\": " +
				fmt("%.1f", tot > 0 ? 100 * L.band_e[b] / tot : 0);
	return o + "}";
}
} // namespace

ss_ analyze(const Song &song0, double seconds, const ss_ &mood,
		const ss_ &track)
{
	auto copy = std::make_shared<Song>(song0);
	const Song &song = *copy;
	Engine e(copy);
	if(!e.set_mood(mood, true))
		return "{\"error\": " + quoted("no mood " + mood) + "}";
	size_t only = song.tracks.size();
	if(!track.empty()){
		auto it = std::find(song.track_names.begin(), song.track_names.end(),
				track);
		if(it == song.track_names.end())
			return "{\"error\": " + quoted("no track " + track) + "}";
		only = it - song.track_names.begin();
		e.solo({track});
	}
	e.tap(true);
	// the whole play order and 0.1 s past the loop's join
	const int64_t join = song.end_t;
	int64_t n = seconds > 0 ? (int64_t)(std::min(seconds, 600.0) * RATE) :
			std::min<int64_t>(join + RATE / 10, 600 * RATE);
	Loudness all(true);
	sv_<Loudness> per;
	for(size_t i = 0; i < song.tracks.size(); i++)
		per.emplace_back(true);
	float l[BLOCK], r[BLOCK];
	uint64_t h = 1469598103934665603ull;
	size_t peak_voices = 0;
	// the join: the steps and the 2nd difference's energy in 5 ms windows
	const int W = RATE / 200;
	double prev[2][2] = {{0, 0}, {0, 0}}, win_e = 0, join_e = -1, join_step = -1;
	int64_t win = -1000000; // the window from the join (0: centred on it)
	sv_<double> steps, wins;
	double cpu = 0;
	for(int64_t done = 0; done < n; done += BLOCK){
		int k = (int)std::min<int64_t>(BLOCK, n - done);
		auto c0 = std::chrono::steady_clock::now();
		e.render(l, r, BLOCK); // (one block of the engine's: tapped() is it)
		cpu += std::chrono::duration<double>(std::chrono::steady_clock::now() -
				c0).count();
		peak_voices = std::max(peak_voices, e.voices());
		fnv(h, l, k);
		fnv(h, r, k);
		all.add(l, r, k);
		for(size_t i = 0; i < per.size(); i++)
			if(only == song.tracks.size() || i == only)
				per[i].add(e.tapped(i), nullptr, k);
		for(int i = 0; i < k; i++){
			int64_t at = done + i;
			double step = std::max(std::fabs(l[i] - prev[0][0]),
					std::fabs(r[i] - prev[1][0]));
			double d2 = 0;
			for(int c = 0; c < 2; c++){
				double x = c ? r[i] : l[i];
				double dd = x - 2 * prev[c][0] + prev[c][1];
				d2 += dd * dd;
				prev[c][1] = prev[c][0];
				prev[c][0] = x;
			}
			if(at > 1){
				if(at == join) join_step = step;
				else if(at % 8 == 0) steps.push_back(step);
			}
			int64_t d = at - join + W / 2;
			int64_t wk = d >= 0 ? d / W : -((-d + W - 1) / W);
			if(wk != win){
				if(win == 0) join_e = win_e;
				else if(win != -1000000) wins.push_back(win_e);
				win_e = 0;
				win = wk;
			}
			win_e += d2;
		}
	}
	auto median = [](sv_<double> v){
		if(v.empty()) return 0.0;
		std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
		return v[v.size() / 2];
	};
	double lo, hi;
	all.short_term(&lo, &hi);
	ss_ o = "{";
	o += "\"title\": " + quoted(song.title);
	o += ", \"tempo\": " + fmt("%.6g", song.tempo);
	o += ", \"seconds\": " + fmt("%.2f", (double)n / RATE);
	o += ", \"loop\": [" + fmt("%.3f", (double)song.loop_t / RATE) + ", " +
			fmt("%.3f", (double)song.end_t / RATE) + "]";
	o += ", \"bar_seconds\": " + fmt("%.4f", song.bar_len / RATE);
	o += ", \"mood\": " + quoted(mood.empty() ? "all" : mood);
	if(!track.empty())
		o += ", \"solo\": " + quoted(track);
	o += ", \"lufs\": " + fmt("%.1f", all.integrated());
	o += ", \"short_term_lufs\": [" + fmt("%.1f", lo) + ", " + fmt("%.1f", hi) +
			"]";
	o += ", \"peak_dbfs\": " + fmt("%.1f", dbfs(all.peak));
	o += ", \"bands_percent\": " + bands_json(all);
	if(join_step >= 0)
		o += ", \"loop_join\": {\"step\": " + fmt("%.5f", join_step) +
				", \"median_step\": " + fmt("%.5f", median(steps)) +
				", \"d2_energy_5ms\": " + fmt("%.3e", join_e) +
				", \"median_d2_energy_5ms\": " + fmt("%.3e", median(wins)) + "}";
	o += ", \"tracks\": {";
	bool first = true;
	for(size_t i = 0; i < per.size(); i++){
		if(only != song.tracks.size() && i != only)
			continue;
		o += ss_(first ? "" : ", ") + quoted(song.track_names[i]) + ": {\"lufs\": " +
				fmt("%.1f", per[i].integrated()) + ", \"peak_dbfs\": " +
				fmt("%.1f", dbfs(per[i].peak)) + ", \"bands_percent\": " +
				bands_json(per[i]) + "}";
		first = false;
	}
	o += "}";
	o += ", \"peak_voices\": " + std::to_string(peak_voices);
	o += ", \"cpu_ms_per_s\": " + fmt("%.2f", 1000 * cpu / ((double)n / RATE));
	o += ", \"hash\": " + quoted(hex64(h));
	return o + "}";
}

}
}
// vim: set noet ts=4 sw=4:
