-- Buildat: extensions/blip/blip_gen.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **blip1's generator** ([BLIP], doc/plan/blip_plan.md): a sound's
-- parameters and a rate in, a buffer of samples out, made by a few calls
-- into the engine's synth blocks (buildat.synth, [SYNTH_BLOCKS]). Plain
-- Lua needing nothing but those: an app may copy this file into itself
-- and load it with buildat.run_script_file, if it would rather not
-- depend on blip.
--
--   local gen = <this file's return>
--   local buf = gen.render(gen.params("blip1:..."), 44100, buildat.synth)
--
-- **The parameters are sfxr's** (DrPetter's sfxr, 2007), as near as the
-- blocks have them, by the names jsfxr gives them without its "p_", so
-- sfxr's presets and sliders carry over: each is mapped onto a curve or
-- a block below. The sound is close to sfxr's and not the same: the
-- filters and the phaser are the blocks', not sfxr's.
--
-- **blip1 is frozen once released**: a blip1 sound sounds the same in
-- every later blip, which the blocks' own promise holds up
-- (doc/compatibility.txt). A change to how a sound is made is a blip2
-- beside this, never an edit of it; self_check() holds the hashes. So
-- the mapping uses + - * / sqrt and floor only, which every platform
-- rounds the same: no math.exp, log or pow, whose last bits differ
-- between the C libraries (LuaJIT natively, Lua 5.1 on the web).
local G = {}

G.VERSION = 1
G.WAVES = {"square", "saw", "sine", "noise", "triangle"}
-- Name, min, max, sfxr's default; in jsfxr's order, which the compact
-- format keeps
G.PARAMS = {
	{"env_attack", 0, 1, 0},
	{"env_sustain", 0, 1, 0.3},
	{"env_punch", 0, 1, 0},
	{"env_decay", 0, 1, 0.4},
	{"base_freq", 0, 1, 0.3},
	{"freq_limit", 0, 1, 0},
	{"freq_ramp", -1, 1, 0},
	{"freq_dramp", -1, 1, 0},
	{"vib_strength", 0, 1, 0},
	{"vib_speed", 0, 1, 0},
	{"arp_mod", -1, 1, 0},
	{"arp_speed", 0, 1, 0},
	{"duty", 0, 1, 0},
	{"duty_ramp", -1, 1, 0},
	{"repeat_speed", 0, 1, 0},
	{"pha_offset", -1, 1, 0},
	{"pha_ramp", -1, 1, 0},
	{"lpf_freq", 0, 1, 1},
	{"lpf_ramp", -1, 1, 0},
	{"lpf_resonance", 0, 1, 0},
	{"hpf_freq", 0, 1, 0},
	{"hpf_ramp", -1, 1, 0},
	{"volume", 0, 1, 0.5},
}
local SEED_MAX = 16777215 -- 24 bits, four characters of the compact form
local BY_NAME = {}
for _, d in ipairs(G.PARAMS) do
	BY_NAME[d[1]] = d
end
local WAVE_INDEX = {}
for i, w in ipairs(G.WAVES) do
	WAVE_INDEX[w] = i - 1
end

local floor, sqrt = math.floor, math.sqrt
local function clamp(x, lo, hi)
	return x < lo and lo or x > hi and hi or x
end
-- x^n for a whole n >= 0 by squaring: multiplications only
local function ipow(x, n)
	local r = 1
	while n > 0 do
		if n % 2 == 1 then
			r = r * x
		end
		x = x * x
		n = floor(n / 2)
	end
	return r
end

function G.defaults()
	local p = {v = G.VERSION, wave = "square", seed = 0}
	for _, d in ipairs(G.PARAMS) do
		p[d[1]] = d[4]
	end
	return p
end

-- The compact form: "blip1:", the wave as one character, each parameter
-- as two (4096 steps; a signed one in 4095, so that 0 is exact), the
-- seed as four
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64_INDEX = {}
for i = 1, 64 do
	B64_INDEX[B64:sub(i, i)] = i - 1
end
local function put(out, v, chars)
	for i = chars - 1, 0, -1 do
		local d = floor(v / ipow(64, i)) % 64
		out[#out + 1] = B64:sub(d + 1, d + 1)
	end
end
local function quantise(d, x)
	if d[2] < 0 then
		return floor(x * 2047 + 0.5) + 2047
	end
	return floor(x * 4095 + 0.5)
end
local function unquantise(d, q)
	if d[2] < 0 then
		return clamp((q - 2047) / 2047, -1, 1)
	end
	return q / 4095
end

function G.pack(p)
	local out = {"blip1:"}
	put(out, WAVE_INDEX[p.wave], 1)
	for _, d in ipairs(G.PARAMS) do
		put(out, quantise(d, p[d[1]]), 2)
	end
	put(out, p.seed, 4)
	return table.concat(out)
end

local COMPACT_LEN = 6 + 1 + 2 * #G.PARAMS + 4
function G.unpack(s)
	if type(s) ~= "string" or s:sub(1, 6) ~= "blip1:" then
		error("blip: not a blip1 sound: " .. tostring(s):sub(1, 40), 3)
	end
	if #s ~= COMPACT_LEN or s:find("[^%w%-_]", 7) then
		error("blip: a blip1 sound is " .. COMPACT_LEN ..
				" characters of A-Z a-z 0-9 - _", 3)
	end
	local pos = 7
	local function get(chars)
		local v = 0
		for _ = 1, chars do
			v = v * 64 + B64_INDEX[s:sub(pos, pos)]
			pos = pos + 1
		end
		return v
	end
	local p = {v = G.VERSION}
	p.wave = G.WAVES[get(1) + 1]
	if not p.wave then
		error("blip: a blip1 sound's wave is not one of blip1's", 3)
	end
	for _, d in ipairs(G.PARAMS) do
		p[d[1]] = unquantise(d, get(2))
	end
	p.seed = get(4)
	return p
end

-- Fields of a table checked onto p: known names, numbers in range
local function apply(p, t)
	for k, v in pairs(t) do
		if k == "v" then
			if v ~= G.VERSION then
				error("blip: v = " .. tostring(v) .. ", this is blip1", 3)
			end
		elseif k == "wave" then
			if WAVE_INDEX[v] == nil then
				error("blip: wave is " .. tostring(v) .. ", not one of " ..
						table.concat(G.WAVES, ", "), 3)
			end
			p.wave = v
		elseif k == "seed" then
			if type(v) ~= "number" or v ~= floor(v) or v < 0 or
					v > SEED_MAX then
				error("blip: seed is " .. tostring(v) .. ", not a whole 0.." ..
						SEED_MAX, 3)
			end
			p.seed = v
		elseif k ~= 1 then
			local d = BY_NAME[k]
			if not d then
				error("blip: no parameter " .. tostring(k), 3)
			end
			if type(v) ~= "number" or v ~= v then
				error("blip: " .. k .. " is not a number", 3)
			end
			p[k] = clamp(v, d[2], d[3])
		end
	end
	return p
end

-- A sound in any of blip1's forms, as a full table of its parameters:
--   "blip1:..."                     the compact form
--   {v = 1, wave = "square", ...}   the table, every field optional
--   {"blip1:...", volume = 0.3}     both: the table's fields override
function G.params(sound)
	if type(sound) == "string" then
		return G.unpack(sound)
	end
	if type(sound) ~= "table" then
		error("blip: a sound is a blip1 string or a table, not a " ..
				type(sound), 2)
	end
	local p = sound[1] ~= nil and G.unpack(sound[1]) or G.defaults()
	return apply(p, sound)
end

-- The table form: every field by name, for editing outside blip
function G.to_table(p)
	local t = {v = G.VERSION, wave = p.wave, seed = p.seed}
	for _, d in ipairs(G.PARAMS) do
		t[d[1]] = p[d[1]]
	end
	return t
end

-- As Lua source, in G.PARAMS' order, a field a line
function G.table_source(t, indent)
	indent = indent or "\t"
	local out = {"{", indent .. "v = " .. t.v .. ", wave = \"" .. t.wave ..
			"\", seed = " .. t.seed .. ","}
	for _, d in ipairs(G.PARAMS) do
		if t[d[1]] ~= nil then
			out[#out + 1] = indent .. d[1] .. " = " ..
					string.format("%.6g", t[d[1]]) .. ","
		end
	end
	out[#out + 1] = "}"
	return table.concat(out, "\n")
end

local SR = 44100   -- sfxr counts in samples at this rate
local SUB = SR * 8 -- and its oscillator and filters in eighths of them
local TWO_PI = 2 * 3.141592653589793
local MUL_MIN, MUL_MAX = 1e-6, 1e6 -- a curve's mul and accel

-- **When sfxr's frequency limit ends the sound**: sfxr stops as the
-- frequency falls through freq_limit. Its own recurrence on the period,
-- a block of 64 samples a step (sfxr's is a sample).
-- simplified: up to 64 samples late; a step a sample is the upgrade, and
-- costs a frame on the web for a long sound.
local function limit_end(p, total, arp, rep)
	local b, lim = p.base_freq, p.freq_limit
	local fpmax = 100 / (lim * lim + 0.001)
	local fdslide = -ipow(p.freq_dramp, 3) * 0.000001
	local function reset()
		return 100 / (b * b + 0.001), 1 - ipow(p.freq_ramp, 3) * 0.01, 0
	end
	local fp, fs, k_arp = reset()
	local k, k_rep, arp_done = 0, 0, false
	while k < total do
		if rep.limit > 0 and k_rep >= rep.limit then
			fp, fs, k_arp = reset()
			k_rep, arp_done = 0, false
		end
		if arp.limit > 0 and not arp_done and k_arp >= arp.limit then
			fp, arp_done = fp * arp.mod, true
		end
		local f = fs
		for _ = 1, 6 do
			f = f * f
		end
		fp = fp * f
		fs = fs + fdslide * 64
		if fp > fpmax then
			return k
		end
		k, k_rep, k_arp = k + 64, k_rep + 64, k_arp + 64
	end
	return total
end

-- **The chain**: p mapped onto the blocks, as data -- the number of
-- samples and the calls that make them -- so that the time spent here
-- (Lua) and in the calls (C++) can be told apart. sfxr's own arithmetic
-- is quoted beside each mapping.
function G.chain(p, rate)
	rate = rate or SR
	-- Envelope: sfxr's stages, len = x^2 * 100000 samples each, the
	-- sustain from 1 + 2 punch down to 1
	local la = floor(p.env_attack * p.env_attack * 100000)
	local ls = floor(p.env_sustain * p.env_sustain * 100000)
	local ld = floor(p.env_decay * p.env_decay * 100000)
	local a, s = la / SR, (ls + 1) / SR
	local d = (ld + 1) / SR
	-- The level: sfxr's 2 sound_vol, its master 0.05, the phaser's sum
	-- (2x even when off), and its WAV export's 4; a square is +-0.5 there
	local g = 0.8 * p.volume * (p.wave == "square" and 0.5 or 1)
	local env = {{0, 0}, {a, g}, {a, g * (1 + 2 * p.env_punch)},
		{a + s, g}, {a + s + d, 0}}
	-- Arpeggio: once, after arp_limit samples, the period times arp_mod
	local arp = {limit = 0, mod = 1}
	if p.arp_mod >= 0 then
		arp.mod = 1 - p.arp_mod * p.arp_mod * 0.9
	else
		arp.mod = 1 + p.arp_mod * p.arp_mod * 10
	end
	if p.arp_speed < 1 and arp.mod ~= 1 then
		arp.limit = floor((1 - p.arp_speed) * (1 - p.arp_speed) * 20000 + 32)
	end
	-- Repeat: every rep_limit samples, the frequency, the duty and the
	-- arpeggio back to their start
	local rep = {limit = 0}
	if p.repeat_speed > 0 then
		rep.limit = floor((1 - p.repeat_speed) * (1 - p.repeat_speed) *
				20000 + 32)
	end
	local total = la + ls + 1 + ld + 1
	if p.freq_limit > 0 then
		total = limit_end(p, total, arp, rep)
	end
	local n = clamp(floor(total / SR * rate + 0.5), 1, 2097152)
	local restart = rep.limit > 0 and rep.limit / SR or nil
	-- Frequency: sfxr's period 100 / (b^2 + 0.001) in eighths of a
	-- sample; slid by fslide = 1 - ramp^3 / 100 a sample, which changes by
	-- fdslide = -dramp^3 / 1e6 a sample; at most 44100 Hz (a period of 8)
	local b, lim = p.base_freq, p.freq_limit
	local fslide = 1 - p.freq_ramp * p.freq_ramp * p.freq_ramp * 0.01
	local fdslide = -p.freq_dramp * p.freq_dramp * p.freq_dramp * 0.000001
	local freq = {
		start = SUB * (b * b + 0.001) / 100,
		mul = clamp(ipow(1 / fslide, SR), MUL_MIN, MUL_MAX),
		accel = clamp(ipow(1 / (1 + fdslide), SR * SR), MUL_MIN, MUL_MAX),
		min = SUB * (lim * lim + 0.001) / 100,
		max = SR,
		restart = restart,
	}
	if arp.limit > 0 then
		freq.jumps = {{arp.limit / SR, 1 / arp.mod}}
	end
	-- Vibrato: the period times 1 + sin(phase) vib_strength / 2, the
	-- phase moving vib_speed^2 / 100 a sample
	if p.vib_strength > 0 then
		freq.wobble = p.vib_strength * 0.5
		freq.wobble_speed = p.vib_speed * p.vib_speed * 0.01 * SR / TWO_PI
	end
	local calls = {}
	if p.wave == "noise" then
		calls[1] = {"noise", {kind = "held", seed = p.seed, freq = freq,
			oversample = 8, rate = rate, n = n}}
	else
		-- Duty: high for 0.5 - duty / 2 of the period, moving
		-- -duty_ramp / 20000 a sample, within 0..0.5
		calls[1] = {"osc", {wave = p.wave, freq = freq, oversample = 8,
			duty = {start = 0.5 - p.duty * 0.5,
				slide = -p.duty_ramp * 0.00005 * SR, min = 0, max = 0.5,
				restart = restart},
			rate = rate, n = n}}
	end
	-- Low pass, off at lpf_freq 1: w = lpf^3 / 10 (in eighths), so the
	-- cutoff sqrt(w) 352800 / 2 pi Hz; w times 1 + lpf_ramp / 1e4 an
	-- eighth; the damping 5 / (1 + 20 res^2) (0.01 + w), so Q = sqrt(w) /
	-- damping, and the block's resonance 1 - 1 / 2Q
	if p.lpf_freq < 1 then
		local w = p.lpf_freq * p.lpf_freq * p.lpf_freq * 0.1
		local damp = math.min(0.8, 5 / (1 + p.lpf_resonance *
				p.lpf_resonance * 20) * (0.01 + w))
		calls[#calls + 1] = {"filter", {type = "low",
			cutoff = {start = sqrt(w) * SUB / TWO_PI,
				mul = clamp(ipow(1 + p.lpf_ramp * 0.0001, SUB / 2),
						MUL_MIN, MUL_MAX),
				min = 0, max = sqrt(0.1) * SUB / TWO_PI},
			resonance = clamp(1 - damp / (2 * sqrt(w)), 0, 0.99),
			rate = rate, n = n}}
	end
	-- High pass: a one-pole at h = hpf^2 / 10 (in eighths), so h 352800 /
	-- 2 pi Hz; h times 1 + hpf_ramp * 3 / 1e4 a sample, within 1e-5..0.1.
	-- At hpf_freq 0 and no rise it is below a hertz: left out.
	if p.hpf_freq > 0 or p.hpf_ramp > 0 then
		local h = math.max(p.hpf_freq * p.hpf_freq * 0.1, 0.00001)
		calls[#calls + 1] = {"filter", {type = "high",
			cutoff = {start = h * SUB / TWO_PI,
				mul = clamp(ipow(1 + p.hpf_ramp * 0.0003, SR), MUL_MIN,
						MUL_MAX),
				min = 0.00001 * SUB / TWO_PI, max = 0.1 * SUB / TWO_PI},
			rate = rate, n = n}}
	end
	-- Phaser: the sample plus itself offset^2 1020 eighths ago, the
	-- offset moving ramp^2 eighths a sample, at most 1023
	if p.pha_offset ~= 0 or p.pha_ramp ~= 0 then
		local off = p.pha_offset * p.pha_offset * 1020
		local ramp = p.pha_ramp * p.pha_ramp
		local same = (p.pha_offset < 0) == (p.pha_ramp < 0) or off == 0
		calls[#calls + 1] = {"delay", {
			delay = {start = off / SUB, slide = (same and 1 or -1) * ramp *
					SR / SUB, min = 0, max = 1023 / SUB},
			max_delay = 1024 / SUB, feedback = 0, mix = 0.5,
			rate = rate, n = n}}
	end
	calls[#calls + 1] = {"envelope", {points = env, rate = rate, n = n}}
	return n, calls
end

-- The chain run: a buffer of n samples
function G.run(n, calls, synth)
	local buf = synth.buffer(n)
	for _, c in ipairs(calls) do
		buf[c[1]](buf, c[2])
	end
	return buf
end

function G.render(p, rate, synth)
	local n, calls = G.chain(p, rate)
	return G.run(n, calls, synth)
end

-- **A random number generator of its own** (Park and Miller's), so a
-- preset at a seed is the same sound everywhere: math.random is not
-- the same between LuaJIT and Lua 5.1. Exact in doubles.
function G.rng(seed)
	local s = floor(seed or 1) % 2147483646 + 1
	local r = {}
	function r.frnd(range)
		s = (s * 16807) % 2147483647
		return (s - 1) / 2147483646 * range
	end
	-- 0..n, each as likely: sfxr's rnd(n)
	function r.rnd(n)
		return math.min(n, floor(r.frnd(n + 1)))
	end
	return r
end

-- **sfxr's generators**, its code with its numbers, on the generator
-- above; each sound gets a noise seed from it too
G.PRESETS = {"pickup", "laser", "explosion", "powerup", "hit", "jump",
	"blip"}
local PRESET = {}
function PRESET.pickup(p, frnd, rnd)
	p.base_freq = 0.4 + frnd(0.5)
	p.env_attack = 0
	p.env_sustain = frnd(0.1)
	p.env_decay = 0.1 + frnd(0.4)
	p.env_punch = 0.3 + frnd(0.3)
	if rnd(1) == 1 then
		p.arp_speed = 0.5 + frnd(0.2)
		p.arp_mod = 0.2 + frnd(0.4)
	end
end
function PRESET.laser(p, frnd, rnd)
	local w = rnd(2)
	if w == 2 and rnd(1) == 1 then
		w = rnd(1)
	end
	p.wave = G.WAVES[w + 1]
	p.base_freq = 0.5 + frnd(0.5)
	p.freq_limit = math.max(0.2, p.base_freq - 0.2 - frnd(0.6))
	p.freq_ramp = -0.15 - frnd(0.2)
	if rnd(2) == 0 then
		p.base_freq = 0.3 + frnd(0.6)
		p.freq_limit = frnd(0.1)
		p.freq_ramp = -0.35 - frnd(0.3)
	end
	if rnd(1) == 1 then
		p.duty = frnd(0.5)
		p.duty_ramp = frnd(0.2)
	else
		p.duty = 0.4 + frnd(0.5)
		p.duty_ramp = -frnd(0.7)
	end
	p.env_attack = 0
	p.env_sustain = 0.1 + frnd(0.2)
	p.env_decay = frnd(0.4)
	if rnd(1) == 1 then
		p.env_punch = frnd(0.3)
	end
	if rnd(2) == 0 then
		p.pha_offset = frnd(0.2)
		p.pha_ramp = -frnd(0.2)
	end
	if rnd(1) == 1 then
		p.hpf_freq = frnd(0.3)
	end
end
function PRESET.explosion(p, frnd, rnd)
	p.wave = "noise"
	if rnd(1) == 1 then
		p.base_freq = 0.1 + frnd(0.4)
		p.freq_ramp = -0.1 + frnd(0.4)
	else
		p.base_freq = 0.2 + frnd(0.7)
		p.freq_ramp = -0.2 - frnd(0.2)
	end
	p.base_freq = p.base_freq * p.base_freq
	if rnd(4) == 0 then
		p.freq_ramp = 0
	end
	if rnd(2) == 0 then
		p.repeat_speed = 0.3 + frnd(0.5)
	end
	p.env_attack = 0
	p.env_sustain = 0.1 + frnd(0.3)
	p.env_decay = frnd(0.5)
	if rnd(1) == 0 then
		p.pha_offset = -0.3 + frnd(0.9)
		p.pha_ramp = -frnd(0.3)
	end
	p.env_punch = 0.2 + frnd(0.6)
	if rnd(1) == 1 then
		p.vib_strength = frnd(0.7)
		p.vib_speed = frnd(0.6)
	end
	if rnd(2) == 0 then
		p.arp_speed = 0.6 + frnd(0.3)
		p.arp_mod = 0.8 - frnd(1.6)
	end
end
function PRESET.powerup(p, frnd, rnd)
	if rnd(1) == 1 then
		p.wave = "saw"
	else
		p.duty = frnd(0.6)
	end
	p.base_freq = 0.2 + frnd(0.3)
	if rnd(1) == 1 then
		p.freq_ramp = 0.1 + frnd(0.4)
		p.repeat_speed = 0.4 + frnd(0.4)
	else
		p.freq_ramp = 0.05 + frnd(0.2)
		if rnd(1) == 1 then
			p.vib_strength = frnd(0.7)
			p.vib_speed = frnd(0.6)
		end
	end
	p.env_attack = 0
	p.env_sustain = frnd(0.4)
	p.env_decay = 0.1 + frnd(0.4)
end
function PRESET.hit(p, frnd, rnd)
	local w = rnd(2)
	p.wave = w == 2 and "noise" or G.WAVES[w + 1]
	if p.wave == "square" then
		p.duty = frnd(0.6)
	end
	p.base_freq = 0.2 + frnd(0.6)
	p.freq_ramp = -0.3 - frnd(0.4)
	p.env_attack = 0
	p.env_sustain = frnd(0.1)
	p.env_decay = 0.1 + frnd(0.2)
	if rnd(1) == 1 then
		p.hpf_freq = frnd(0.3)
	end
end
function PRESET.jump(p, frnd, rnd)
	p.wave = "square"
	p.duty = frnd(0.6)
	p.base_freq = 0.3 + frnd(0.3)
	p.freq_ramp = 0.1 + frnd(0.2)
	p.env_attack = 0
	p.env_sustain = 0.1 + frnd(0.3)
	p.env_decay = 0.1 + frnd(0.2)
	if rnd(1) == 1 then
		p.hpf_freq = frnd(0.3)
	end
	if rnd(1) == 1 then
		p.lpf_freq = 1 - frnd(0.6)
	end
end
function PRESET.blip(p, frnd, rnd)
	p.wave = G.WAVES[rnd(1) + 1]
	if p.wave == "square" then
		p.duty = frnd(0.6)
	end
	p.base_freq = 0.2 + frnd(0.4)
	p.env_attack = 0
	p.env_sustain = 0.1 + frnd(0.1)
	p.env_decay = frnd(0.2)
	p.hpf_freq = 0.1
end

-- Every parameter into its range, as G.params does
local function settle(p)
	for _, d in ipairs(G.PARAMS) do
		p[d[1]] = clamp(p[d[1]], d[2], d[3])
	end
	return p
end

function G.preset(name, seed)
	local f = PRESET[name]
	if not f then
		error("blip: no preset " .. tostring(name), 2)
	end
	local r = G.rng(seed)
	local p = G.defaults()
	f(p, r.frnd, r.rnd)
	p.seed = floor(r.frnd(SEED_MAX + 1))
	return settle(p)
end

-- sfxr's RANDOMIZE, the wave kept. sfxr gives a parameter it squares a
-- negative value as often as not; here its size, as squaring it did.
function G.random(wave, seed)
	local r = G.rng(seed)
	local frnd, rnd = r.frnd, r.rnd
	local function sr()
		return frnd(2) - 1
	end
	local p = G.defaults()
	p.wave = wave or "square"
	p.base_freq = ipow(sr(), 2)
	if rnd(1) == 1 then
		p.base_freq = ipow(sr(), 3) + 0.5
	end
	p.freq_ramp = ipow(sr(), 5)
	if p.base_freq > 0.7 and p.freq_ramp > 0.2 then
		p.freq_ramp = -p.freq_ramp
	end
	if p.base_freq < 0.2 and p.freq_ramp < -0.05 then
		p.freq_ramp = -p.freq_ramp
	end
	p.freq_dramp = ipow(sr(), 3)
	p.duty = sr()
	p.duty_ramp = ipow(sr(), 3)
	p.vib_strength = ipow(sr(), 3)
	p.vib_speed = math.abs(sr())
	p.env_attack = math.abs(ipow(sr(), 3))
	p.env_sustain = ipow(sr(), 2)
	p.env_decay = math.abs(sr())
	p.env_punch = ipow(frnd(0.8), 2)
	if p.env_attack + p.env_sustain + p.env_decay < 0.2 then
		p.env_sustain = p.env_sustain + 0.2 + frnd(0.3)
		p.env_decay = p.env_decay + 0.2 + frnd(0.3)
	end
	p.lpf_resonance = math.abs(sr())
	p.lpf_freq = 1 - ipow(frnd(1), 3)
	p.lpf_ramp = ipow(sr(), 3)
	if p.lpf_freq < 0.1 and p.lpf_ramp < -0.05 then
		p.lpf_ramp = -p.lpf_ramp
	end
	p.hpf_freq = ipow(frnd(1), 5)
	p.hpf_ramp = ipow(sr(), 5)
	p.pha_offset = ipow(sr(), 3)
	p.pha_ramp = ipow(sr(), 3)
	p.repeat_speed = sr()
	p.arp_speed = sr()
	p.arp_mod = sr()
	p.seed = floor(frnd(SEED_MAX + 1))
	return settle(p)
end

-- sfxr's MUTATE: each parameter but the limit and the volume moved by
-- up to 0.05 half the time
function G.mutate(p, seed)
	local r = G.rng(seed)
	local q = {}
	for k, v in pairs(p) do
		q[k] = v
	end
	for _, d in ipairs(G.PARAMS) do
		local k = d[1]
		if k ~= "freq_limit" and k ~= "volume" and r.rnd(1) == 1 then
			q[k] = q[k] + r.frnd(0.1) - 0.05
		end
	end
	return settle(q)
end

-- **The self-check**: each preset at seed 1, at 44100 Hz, against the
-- hashes blip1 was released with. A change that moves one is a blip2.
-- -> true, or false and the presets that differ
G.HASHES = {
	pickup = "fa55c4ec3788b502",
	laser = "d314193a13cf6c67",
	explosion = "08bbd06b74e51dc8",
	powerup = "802e828ada2b9c74",
	hit = "37f2aa7f9f57a67d",
	jump = "ea815359c7b109da",
	blip = "98f8feb988e5004f",
}
function G.self_check(synth)
	local bad = {}
	for _, name in ipairs(G.PRESETS) do
		local h = G.render(G.preset(name, 1), SR, synth):hash()
		if h ~= G.HASHES[name] then
			bad[#bad + 1] = name .. " hashes " .. h .. ", not " ..
					G.HASHES[name]
		end
	end
	return #bad == 0, bad
end

return G
-- vim: set noet ts=4 sw=4:
