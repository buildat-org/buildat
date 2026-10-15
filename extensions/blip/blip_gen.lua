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
-- filters and the phaser are the blocks', not sfxr's. Beyond sfxr's (user,
-- 2026-10-15): a sound is up to 16 such voices at offsets (layers), and a
-- voice has a tremolo, a crackle and a pluck, each off at 0.
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
	-- **Beyond sfxr** (user, 2026-10-15, for skelenti's sounds): off at
	-- 0, so a sound without them is made as before and packs as before
	{"trem_depth", 0, 1, 0},
	{"trem_speed", 0, 1, 0},
	{"crackle", 0, 1, 0},
	{"pluck", 0, 1, 0},
}
-- sfxr's own, the volume last: what sfxr's and jsfxr's files carry
G.SFXR_PARAMS = 23
-- A sound is up to this many layers, each a voice of the parameters
-- above at an offset (at, in seconds, at most 4.095)
G.MAX_LAYERS = 16
G.MAX_AT = 4.095
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

-- The compact form: "blip1:", then each layer: the wave as one
-- character, sfxr's parameters as two each (4096 steps; a signed one in
-- 4095, so that 0 is exact), the seed as four, and the parameters beyond
-- sfxr's as two each only when one of them is on. A layer after the
-- first is "+", its offset in milliseconds as two characters, then the
-- same.
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

local function extended(p)
	for i = G.SFXR_PARAMS + 1, #G.PARAMS do
		local d = G.PARAMS[i]
		if quantise(d, p[d[1]]) ~= quantise(d, d[4]) then
			return true
		end
	end
	return false
end
local function pack_voice(out, p)
	put(out, WAVE_INDEX[p.wave], 1)
	for i = 1, G.SFXR_PARAMS do
		local d = G.PARAMS[i]
		put(out, quantise(d, p[d[1]]), 2)
	end
	put(out, p.seed, 4)
	if extended(p) then
		for i = G.SFXR_PARAMS + 1, #G.PARAMS do
			local d = G.PARAMS[i]
			put(out, quantise(d, p[d[1]]), 2)
		end
	end
end
function G.pack(p)
	local out = {"blip1:"}
	pack_voice(out, p)
	for _, l in ipairs(p.layers or {}) do
		out[#out + 1] = "+"
		put(out, floor(l.at * 1000 + 0.5), 2)
		pack_voice(out, l)
	end
	return table.concat(out)
end

local VOICE_LEN = 1 + 2 * G.SFXR_PARAMS + 4
local VOICE_LEN_EXT = VOICE_LEN + 2 * (#G.PARAMS - G.SFXR_PARAMS)
local function unpack_voice(s)
	if (#s ~= VOICE_LEN and #s ~= VOICE_LEN_EXT) or s:find("[^%w%-_]") then
		error("blip: a blip1 layer is " .. VOICE_LEN .. " or " ..
				VOICE_LEN_EXT .. " characters of A-Z a-z 0-9 - _", 4)
	end
	local pos = 1
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
		error("blip: a blip1 sound's wave is not one of blip1's", 4)
	end
	for i = 1, G.SFXR_PARAMS do
		local d = G.PARAMS[i]
		p[d[1]] = unquantise(d, get(2))
	end
	p.seed = get(4)
	for i = G.SFXR_PARAMS + 1, #G.PARAMS do
		local d = G.PARAMS[i]
		p[d[1]] = #s == VOICE_LEN_EXT and unquantise(d, get(2)) or d[4]
	end
	return p
end
function G.unpack(s)
	if type(s) ~= "string" or s:sub(1, 6) ~= "blip1:" then
		error("blip: not a blip1 sound: " .. tostring(s):sub(1, 40), 3)
	end
	local parts = {}
	for part in (s:sub(7) .. "+"):gmatch("([^+]*)%+") do
		parts[#parts + 1] = part
	end
	if #parts > G.MAX_LAYERS then
		error("blip: more than " .. G.MAX_LAYERS .. " layers", 3)
	end
	local p = unpack_voice(parts[1])
	if #parts > 1 then
		p.layers = {}
		for i = 2, #parts do
			local l = unpack_voice(parts[i]:sub(3))
			local a, b = B64_INDEX[parts[i]:sub(1, 1)],
				B64_INDEX[parts[i]:sub(2, 2)]
			l.at = math.min(G.MAX_AT, ((a or 0) * 64 + (b or 0)) / 1000)
			p.layers[i - 1] = l
		end
	end
	return p
end

-- Fields of a table checked onto p: known names, numbers in range; a
-- layer's own offset (at), and the first layer's list of the others
local function apply(p, t, layer)
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
		elseif k == "at" and layer then
			if type(v) ~= "number" or v ~= v then
				error("blip: a layer's at is not a number", 3)
			end
			p.at = clamp(v, 0, G.MAX_AT)
		elseif k == "layers" and not layer then
			if type(v) ~= "table" or #v + 1 > G.MAX_LAYERS then
				error("blip: layers is a list of at most " ..
						(G.MAX_LAYERS - 1) .. " sounds", 3)
			end
			p.layers = {}
			for i, l in ipairs(v) do
				p.layers[i] = G.layer(l)
			end
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

-- One layer of a sound's layers, in any of the forms below, at = 0 if not
-- given; a layer has no layers of its own
function G.layer(sound)
	local p
	if type(sound) == "string" then
		p = G.unpack(sound)
	elseif type(sound) == "table" then
		p = sound[1] ~= nil and G.unpack(sound[1]) or G.defaults()
		apply(p, sound, true)
	else
		error("blip: a layer is a blip1 string or a table, not a " ..
				type(sound), 2)
	end
	if p.layers then
		error("blip: a layer with layers of its own", 2)
	end
	p.at = p.at or 0
	return p
end

-- A sound in any of blip1's forms, as a full table of its parameters:
--   "blip1:..."                     the compact form
--   {v = 1, wave = "square", ...}   the table, every field optional
--   {"blip1:...", volume = 0.3}     both: the table's fields override
-- Its first layer is the table itself and its others are in layers, each
-- with at: {..., layers = {{wave = "sine", ..., at = 0.05}, "blip1:..."}}
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
	local t = {v = G.VERSION, wave = p.wave, seed = p.seed, at = p.at}
	for _, d in ipairs(G.PARAMS) do
		t[d[1]] = p[d[1]]
	end
	if p.layers then
		t.layers = {}
		for i, l in ipairs(p.layers) do
			t.layers[i] = G.to_table(l)
		end
	end
	return t
end

-- As Lua source, in G.PARAMS' order, a field a line; the parameters
-- beyond sfxr's only when on; a layer's table nested depth deep
function G.table_source(t, indent, depth)
	indent = indent or "\t"
	depth = depth or 0
	local inner = indent:rep(depth + 1)
	local out = {"{", inner .. (t.at and "at = " ..
			string.format("%.6g", t.at) .. ", " or "") .. "v = " .. t.v ..
			", wave = \"" .. t.wave .. "\", seed = " .. t.seed .. ","}
	for i, d in ipairs(G.PARAMS) do
		local v = t[d[1]]
		if v ~= nil and (i <= G.SFXR_PARAMS or v ~= d[4]) then
			out[#out + 1] = inner .. d[1] .. " = " ..
					string.format("%.6g", v) .. ","
		end
	end
	if t.layers then
		out[#out + 1] = inner .. "layers = {"
		for _, l in ipairs(t.layers) do
			out[#out + 1] = indent:rep(depth + 2) ..
					G.table_source(l, indent, depth + 2) .. ","
		end
		out[#out + 1] = inner .. "},"
	end
	out[#out + 1] = indent:rep(depth) .. "}"
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

-- Points {t, v} (seconds, ascending, from 0) as envelope calls over n
-- samples: the block takes 256 points a call, so a long list is cut into
-- spans, each starting at the last point of the one before
local function envelopes(calls, pts, rate, n)
	local i = 1
	while true do
		local j = math.min(#pts, i + 255)
		local from = i == 1 and 0 or floor(pts[i][1] * rate)
		if from >= n then
			return
		end
		local to = j < #pts and math.min(n, floor(pts[j][1] * rate)) or n
		if to > from then
			local seg = {}
			for k = i, j do
				seg[#seg + 1] = {math.max(0, pts[k][1] - from / rate),
					pts[k][2]}
			end
			calls[#calls + 1] = {"envelope", {points = seg, rate = rate,
				from = from, n = to - from}}
		end
		if j == #pts then
			return
		end
		i = j
	end
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
		-- Oversampled against aliasing; a sine has no harmonics to alias,
		-- and eight lookups a sample made it the web's slowest wave
		calls[1] = {"osc", {wave = p.wave, freq = freq,
			oversample = p.wave == "sine" and 1 or 8,
			duty = {start = 0.5 - p.duty * 0.5,
				slide = -p.duty_ramp * 0.00005 * SR, min = 0, max = 0.5,
				restart = restart},
			rate = rate, n = n}}
	end
	-- **Pluck**: a string (Karplus-Strong) tuned to the start frequency,
	-- struck by the voice's first period; pluck is its feedback, so how
	-- long it rings, and the envelope below shapes what rings
	if p.pluck > 0 then
		local period = 1 / freq.start
		calls[#calls + 1] = {"envelope", {points = {{0, 1}, {period, 1},
			{period + 1 / rate, 0}}, rate = rate, n = n}}
		calls[#calls + 1] = {"delay", {delay = period,
			max_delay = period + 2 / rate, feedback = 0.99 * p.pluck,
			mix = 1, rate = rate, n = n}}
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
	local dur = n / rate
	-- **Crackle**: the sound let through in grains of 3 ms at random
	-- times, up to 400 a second (crackle^2 400); its own generator from
	-- the seed
	if p.crackle > 0 then
		local gap = 2 / (p.crackle * p.crackle * 400)
		local r = G.rng(p.seed + 1)
		local pts = {{0, 0}}
		local t = r.frnd(gap)
		while t < dur do
			pts[#pts + 1] = {t, 0}
			pts[#pts + 1] = {t + 0.0003, 1}
			pts[#pts + 1] = {t + 0.0027, 1}
			pts[#pts + 1] = {t + 0.003, 0}
			t = t + 0.003 + r.frnd(gap)
		end
		envelopes(calls, pts, rate, n)
	end
	-- **Tremolo**: the level down by trem_depth and back, a triangle at
	-- up to 50 Hz (trem_speed^2 50)
	local tf = p.trem_speed * p.trem_speed * 50
	if p.trem_depth > 0 and tf >= 0.01 then
		local half = 1 / (2 * tf)
		local pts = {}
		local k = 0
		while k * half <= dur + half do
			pts[#pts + 1] = {k * half, k % 2 == 0 and 1 or 1 - p.trem_depth}
			k = k + 1
		end
		envelopes(calls, pts, rate, n)
	end
	return n, calls
end

-- **A sound's layers**: each voice's chain and where it starts, in
-- samples, and the length of them all (at most a buffer's, the voices
-- cut to it)
local MAX_N = 2097152
function G.build(p, rate)
	rate = rate or SR
	local voices = {p}
	for _, l in ipairs(p.layers or {}) do
		voices[#voices + 1] = l
	end
	local parts, total = {}, 0
	for i, v in ipairs(voices) do
		local n, calls = G.chain(v, rate)
		local at = i == 1 and 0 or floor(v.at * rate + 0.5)
		parts[i] = {at = at, n = n, calls = calls}
		total = math.max(total, at + n)
	end
	if total > MAX_N then
		total = MAX_N
		for _, part in ipairs(parts) do
			part.n = math.max(0, math.min(part.n, total - part.at))
			for i = #part.calls, 1, -1 do
				local c = part.calls[i][2]
				local from = c.from or 0
				if from >= part.n then
					table.remove(part.calls, i)
				else
					c.n = math.min(c.n, part.n - from)
				end
			end
		end
	end
	return total, parts
end

-- The chain run: a buffer of n samples
function G.run(n, calls, synth)
	local buf = synth.buffer(n)
	for _, c in ipairs(calls) do
		buf[c[1]](buf, c[2])
	end
	return buf
end

-- One layer is its own buffer; more are mixed into one
function G.render(p, rate, synth)
	local total, parts = G.build(p, rate)
	if #parts == 1 then
		return G.run(parts[1].n, parts[1].calls, synth)
	end
	local out = synth.buffer(total)
	for _, part in ipairs(parts) do
		if part.n > 0 then
			out:mix(G.run(part.n, part.calls, synth), 0, part.at, part.n, 1)
		end
	end
	return out
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
	"blip", "thud", "knock", "crunch", "grunt", "squeal", "snort", "pluck",
	"rattle", "chime"}
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

-- **blip's own generators** (user, 2026-10-15), after skelenti's sounds
-- (dig, place, walk, a boar, a skeleton, a bow, a chime): a frequency in
-- Hz and a stage's length in seconds as the parameters that give them,
-- by sqrt only, so a preset is the same everywhere
local function hz(f)
	return sqrt(math.max(0, f / 3528 - 0.001))
end
local function secs(t)
	return sqrt(t / 2.268)
end
-- A short struck tone: wood, stone, a bone
local function knock(p, frnd, rnd, lo, span, len)
	p.wave = rnd(1) == 0 and "sine" or "triangle"
	p.base_freq = hz(lo + frnd(span))
	p.freq_ramp = -frnd(0.05)
	p.env_sustain = 0
	p.env_decay = secs(len + frnd(len * 2))
	p.env_punch = frnd(0.5)
end
-- A voice through a formant: a resonant low pass on a saw or a square
local function voiced(p, frnd, rnd, f, lpf)
	p.wave = rnd(1) == 0 and "saw" or "square"
	p.duty = frnd(0.4)
	p.base_freq = hz(f)
	p.freq_ramp = -0.03 - frnd(0.07)
	p.vib_strength = 0.05 + frnd(0.1)
	p.vib_speed = 0.4 + frnd(0.2)
	p.lpf_freq = lpf + frnd(0.08)
	p.lpf_resonance = 0.5 + frnd(0.4)
	p.env_attack = secs(0.01 + frnd(0.02))
	p.env_sustain = secs(0.1 + frnd(0.15))
	p.env_decay = secs(0.08 + frnd(0.1))
end
function PRESET.thud(p, frnd, rnd)
	if rnd(1) == 0 then
		-- A triangle's harmonics: a sine this low is lost on a small
		-- speaker
		p.wave = "triangle"
		p.base_freq = hz(80 + frnd(120))
		p.freq_ramp = -0.15 - frnd(0.2)
	else
		p.wave = "noise"
		p.base_freq = 0.15 + frnd(0.15)
		p.lpf_freq = 0.08 + frnd(0.1)
	end
	p.env_sustain = secs(0.01)
	p.env_decay = secs(0.05 + frnd(0.1))
	p.env_punch = 0.2 + frnd(0.4)
end
function PRESET.knock(p, frnd, rnd)
	knock(p, frnd, rnd, 300, 2200, 0.02)
	if rnd(1) == 1 then
		p.hpf_freq = 0.2
	end
end
function PRESET.crunch(p, frnd, rnd)
	p.wave = "noise"
	p.base_freq = 0.3 + frnd(0.3)
	p.crackle = 0.5 + frnd(0.5)
	p.lpf_freq = 0.25 + frnd(0.25)
	p.lpf_resonance = frnd(0.4)
	p.hpf_freq = 0.1 + frnd(0.2)
	p.env_sustain = secs(0.04 + frnd(0.06))
	p.env_decay = secs(0.06 + frnd(0.1))
end
function PRESET.grunt(p, frnd, rnd)
	voiced(p, frnd, rnd, 120 + frnd(70), 0.12)
	p.hpf_freq = 0.12
end
function PRESET.squeal(p, frnd, rnd)
	voiced(p, frnd, rnd, 350 + frnd(250), 0.22)
	p.hpf_freq = 0.2
end
function PRESET.snort(p, frnd, rnd)
	p.wave = "noise"
	p.base_freq = 0.25 + frnd(0.2)
	p.lpf_freq = 0.1 + frnd(0.06)
	p.lpf_resonance = 0.5 + frnd(0.3)
	p.hpf_freq = 0.12
	p.trem_depth = 0.5 + frnd(0.4)
	p.trem_speed = sqrt((24 + frnd(16)) / 50)
	p.env_attack = secs(0.02)
	p.env_sustain = secs(0.12 + frnd(0.12))
	p.env_decay = secs(0.06 + frnd(0.06))
end
function PRESET.pluck(p, frnd, rnd)
	p.wave = G.WAVES[rnd(3) + 1]
	p.base_freq = hz(70 + frnd(150))
	p.pluck = 0.93 + frnd(0.06)
	p.env_sustain = secs(0.1 + frnd(0.2))
	p.env_decay = secs(0.15 + frnd(0.25))
	p.lpf_freq = 0.3 + frnd(0.4)
	p.lpf_ramp = -frnd(0.15)
	-- One period struck rings at about half the level of a held tone
	p.volume = 0.9
end
-- Bones: a knock and a few more after it, each a layer
function PRESET.rattle(p, frnd, rnd)
	knock(p, frnd, rnd, 900, 2000, 0.01)
	p.volume = 0.5
	p.layers = {}
	for i = 1, 3 + rnd(6) do
		local l = G.defaults()
		knock(l, frnd, rnd, 900, 2000, 0.01)
		l.volume = 0.25 + frnd(0.25)
		l.at = floor(frnd(250)) / 1000
		p.layers[i] = l
	end
end
-- Two notes of a bell, the second a fifth, a fourth or an octave up
function PRESET.chime(p, frnd, rnd)
	local f = 600 + frnd(500)
	p.wave = "sine"
	p.base_freq = hz(f)
	p.env_sustain = secs(0.02)
	p.env_decay = secs(0.25 + frnd(0.2))
	p.env_punch = 0.3
	p.volume = 0.4
	local l = {}
	for k, v in pairs(p) do
		l[k] = v
	end
	l.base_freq = hz(f * ({1.5, 4 / 3, 2})[rnd(2) + 1])
	l.at = floor(50 + frnd(50)) / 1000
	p.layers = {l}
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
	for _, l in ipairs(p.layers or {}) do
		l.seed = floor(r.frnd(SEED_MAX + 1))
		settle(l)
	end
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
-- up to 0.05 half the time. One beyond sfxr's that is off stays off: a
-- little pluck or crackle is another sound, not a nearby one.
function G.mutate(p, seed)
	local r = G.rng(seed)
	local q = {}
	for k, v in pairs(p) do
		q[k] = v
	end
	for i, d in ipairs(G.PARAMS) do
		local k = d[1]
		if k ~= "freq_limit" and k ~= "volume" and r.rnd(1) == 1 and
				(i <= G.SFXR_PARAMS or q[k] ~= d[4]) then
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
	-- blip's own, with the layers and the parameters beyond sfxr's
	-- (2026-10-15)
	thud = "67ed7f9289e9bd33",
	knock = "f866eef78046803f",
	crunch = "adc2184869cfa34a",
	grunt = "9eb6d1a4ba4209d1",
	squeal = "8f80733bff062ec0",
	snort = "6d62325e002f06ad",
	pluck = "ce6bf7368270ebc0",
	rattle = "90c3fee99077fa2c",
	chime = "8bdfbfdf655a0c49",
}
function G.self_check(synth)
	local bad = {}
	for _, name in ipairs(G.PRESETS) do
		local h = G.render(G.preset(name, 1), SR, synth):hash()
		if h ~= G.HASHES[name] then
			bad[#bad + 1] = name .. " hashes " .. h .. ", not " ..
					tostring(G.HASHES[name])
		end
	end
	return #bad == 0, bad
end

return G
-- vim: set noet ts=4 sw=4:
