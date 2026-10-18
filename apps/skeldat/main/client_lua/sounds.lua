-- Buildat: apps/skeldat/main/client_lua/sounds.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- skelenti's sound effects, made with blip ([SKELENTI_SOUNDS]), copied: no
-- files. Each sound has takes (TAKES), one of them picked (PICK); at
-- startup make() renders VARIANTS of each picked one, nudged apart by
-- blip's vary(). init.lua plays the digging, placing and steps, mobs.lua
-- the mobs' moments (pick()).
local M = {}

M.VARIANTS = 8

-- A frequency in Hz, a stage in seconds and the filters' cutoffs in Hz as
-- blip's parameters (blip_gen.lua's chain says the mappings)
local sqrt = math.sqrt
local function hz(f) return sqrt(math.max(0, f / 3528 - 0.001)) end
local function secs(t) return sqrt(t / 2.268) end
local function lp(f) return (f / 17756) ^ (2 / 3) end
local function hp(f) return sqrt(f / 5615) end

-- A voice: sfxr's defaults sustain 0.3 and decay 0.4 are long, so a
-- voice here starts short and silent of both
local function v(t)
	t.env_sustain = t.env_sustain or 0
	t.env_decay = t.env_decay or secs(0.05)
	return t
end
-- Noise through a band: hp..lp Hz, held at a rate bright enough for it
local function burst(lo, hi, len, vol, t)
	t = t or {}
	t.wave = "noise"
	t.base_freq = t.base_freq or 0.5
	t.hpf_freq = lo and hp(lo) or nil
	t.lpf_freq = hi and lp(hi) or nil
	t.env_decay = secs(len * 3)
	t.volume = vol
	return v(t)
end
-- A struck tone, falling a little
local function tone(wave, f, len, vol, ramp)
	return v{wave = wave, base_freq = hz(f), freq_ramp = ramp or -0.05,
		env_decay = secs(len * 3), env_punch = 0.3, volume = vol}
end
-- A sound of layers: the first voice and the rest, each with its at
local function layers(first, ...)
	first.layers = {...}
	for _, l in ipairs(first.layers) do
		l.at = l.at or 0
	end
	return first
end
local function at(t, voice)
	voice.at = t
	return voice
end
-- A voice through a formant, its pitch falling from f
local function voiced(f, ramp, formant, len, vol, wave)
	return v{wave = wave or "saw", base_freq = hz(f), freq_ramp = ramp,
		lpf_freq = lp(formant), lpf_resonance = 0.6,
		vib_strength = 0.08, vib_speed = 0.5, hpf_freq = hp(80),
		env_attack = secs(0.015), env_sustain = secs(len * 0.6),
		env_decay = secs(len * 0.4), volume = vol}
end
-- Bones: n knocks over span seconds from t0, at lo Hz and up
local function clacks(t0, n, span, vol, lo, out)
	out = out or {}
	for i = 1, n do
		-- Spread by a fixed scatter: the variants move them a little
		local f = (i * 0.618) % 1
		out[#out + 1] = at(t0 + span * ((i - 1) / n + f / n),
				tone(i % 2 == 0 and "sine" or "triangle",
				(lo or 1500) + f * 1500, 0.012, vol * (0.6 + 0.4 * f), 0))
	end
	return out
end

M.TAKES = {
	-- Digging, a hit each swing; placing; a step -- by what the node is
	dig_stone = {a = layers(burst(1800, 4000, 0.03, 0.6),
			tone("triangle", 1400, 0.02, 0.4, 0))},
	dig_earth = {a = layers(burst(nil, 500, 0.06, 0.7, {base_freq = 0.3}),
			tone("sine", 130, 0.05, 0.4, -0.2))},
	dig_wood = {a = layers(tone("triangle", 320, 0.04, 0.6, -0.02),
			tone("triangle", 760, 0.03, 0.4, 0),
			burst(1000, 3000, 0.02, 0.3))},
	dig_leaves = {a = burst(2000, nil, 0.07, 0.6, {crackle = 0.8})},
	place_stone = {a = layers(burst(900, 2500, 0.02, 0.5),
			tone("triangle", 180, 0.06, 0.6, -0.08))},
	place_earth = {a = layers(tone("sine", 95, 0.08, 0.7, -0.15),
			burst(nil, 1200, 0.01, 0.3, {base_freq = 0.35}))},
	place_wood = {a = layers(tone("triangle", 320, 0.06, 0.6, -0.02),
			tone("triangle", 760, 0.04, 0.35, 0))},
	place_leaves = {a = burst(1500, 6000, 0.06, 0.7, {crackle = 0.6})},
	step_stone = {a = layers(burst(nil, 700, 0.02, 0.5, {base_freq = 0.35}),
			tone("triangle", 150, 0.025, 0.25, -0.1))},
	step_earth = {a = layers(burst(2500, nil, 0.05, 0.4),
			burst(nil, 300, 0.03, 0.4, {base_freq = 0.25}))},
	step_gravel = {a = layers(burst(1500, 3500, 0.06, 0.7, {crackle = 0.9}),
			burst(nil, 400, 0.02, 0.35, {base_freq = 0.3}))},
	step_wood = {a = layers(tone("triangle", 220, 0.03, 0.35, -0.03),
			burst(nil, 900, 0.015, 0.25, {base_freq = 0.35}))},
	-- A step on grass: the user's own ([SKELDAT_STEP_GRASS]), four
	-- layers, as made: not in M.PEAK
	step_grass = {a = "blip1:DJ2KrAAKrWKAAmJf_AAAAf_AAAAf_AAf_f_NIkgInDSd8PLHLCNAAAA__AA+AaDFVDsAAJ2WKAAmJf_AAAAf_AAAAf_AAf_f_PLkgInAAd8S4HLCN+ATDNiBpAARpWKAAf_f_AAAAf_AAAAf_AAf_f_ZBlUInGKZBGkHLCN+B3DNiBpAAL5WKAAf_f_AAAAf_AAAAf_AAf_f_ZBlUInGKZBLFHLCNAAAAVVAA"},

	-- Picking an item up: the user's own ([SKELDAT_PICKUP_TAKE]), as made:
	-- not in M.PEAK
	pickup = {a = "blip1:CAANiiDJCLFAAqPb5AAAA2CpuAAf_AAcVbP__gZAASDf_gAWw5O"},

	-- [SKELDAT_MINING_HAZARDS] The player hurt (gas, lava, drowning, a
	-- hit): a short grunt
	player_hurt = {a = layers(voiced(190, -0.12, 900, 0.16, 0.6),
		burst(300, 1200, 0.05, 0.25))},

	-- A boar hurt and dying
	boar_hurt = {
		a = voiced(150, -0.05, 650, 0.25, 0.6),
		b = voiced(420, -0.06, 1300, 0.3, 0.45, "square"),
		c = burst(250, 700, 0.08, 0.6, {base_freq = 0.3,
			lpf_resonance = 0.7, trem_depth = 0.4, trem_speed = sqrt(32 / 50),
			env_attack = secs(0.02), env_sustain = secs(0.18)}),
	},
	boar_death = {
		a = voiced(160, -0.12, 600, 0.7, 0.6),
		b = layers(voiced(450, -0.15, 1200, 0.6, 0.45, "square"),
			at(0.55, voiced(120, -0.08, 500, 0.4, 0.4))),
		c = layers(burst(250, 700, 0.08, 0.6, {base_freq = 0.3,
				lpf_resonance = 0.7, trem_depth = 0.4,
				trem_speed = sqrt(32 / 50), env_attack = secs(0.02),
				env_sustain = secs(0.18)}),
			at(0.3, burst(200, 600, 0.2, 0.45, {base_freq = 0.25,
				env_attack = secs(0.1), env_sustain = secs(0.15)}))),
	},

	-- A skeleton hurt and falling apart
	skeleton_hurt = {
		a = layers(tone("triangle", 1800, 0.012, 0.5, 0),
			unpack(clacks(0.02, 5, 0.2, 0.5))),
		b = layers(tone("triangle", 420, 0.05, 0.6, -0.03),
			unpack(clacks(0.04, 4, 0.15, 0.45))),
		c = layers(burst(1200, nil, 0.01, 0.7),
			at(0.02, burst(500, 1600, 0.12, 0.35, {base_freq = 0.35,
				env_attack = secs(0.05)}))),
	},
	skeleton_death = {
		a = layers(tone("triangle", 2600, 0.012, 0.6, 0),
			at(0.15, burst(nil, 250, 0.25, 0.5, {base_freq = 0.25})),
			unpack(clacks(0.02, 12, 0.6, 0.55, 1300))),
		b = layers(tone("triangle", 420, 0.06, 0.6, -0.03),
			unpack(clacks(0.05, 14, 0.8, 0.5, 900))),
		c = layers(burst(1200, nil, 0.01, 0.7),
			at(0.25, burst(nil, 180, 0.25, 0.6, {base_freq = 0.2})),
			unpack(clacks(0.2, 10, 0.5, 0.45, 600))),
	},

	-- [SKELDAT_BOW_SOUNDS] (simplified: first guesses, tuned by ear)
	-- The draw's squeak: stick-slip pulses, a saw rising 60 to 110 Hz
	-- (the ramp is per sample: 0.111^3 / 100 is 1.83x a second) through a
	-- 1500..3000 Hz band, louder as it bends, BOW_DRAW long.
	-- [SKELDAT_BOW_SOUND_TUNE] The mids cut: no resonant peak near 1 kHz
	-- and little wobble, which made it a voice
	bow_draw = {a = v{wave = "saw", base_freq = hz(60), freq_ramp = 0.111,
		hpf_freq = hp(1500), lpf_freq = lp(3000), lpf_resonance = 0.2,
		vib_strength = 0.03, vib_speed = 0.24, env_attack = secs(0.9),
		env_sustain = secs(0.1), env_decay = secs(0.05), volume = 0.5}},
	-- The release: the user's own ([SKELDAT_BOW_RELEASE_PICK]), as made:
	-- not in M.PEAK
	bow = {a = "blip1:DKQJcEhPmjsAAWJdHAAg0gzGkFVgRAAgZoMLf7dwZLFd8gAfstafl1sAAAA"},
	-- An arrow sticking: a thock with a body (400..2500 Hz noise, 60 ms;
	-- a 700 Hz triangle, 40 ms) and the shaft's quiver (300..600 Hz
	-- noise under a 30 Hz tremolo, 0.25 s)
	arrow_land = {a = layers(burst(400, 2500, 0.02, 0.8,
			{env_sustain = secs(0.03)}),
		tone("triangle", 700, 0.013, 0.6, 0),
		burst(300, 600, 0.083, 0.8, {trem_depth = 1,
			trem_speed = sqrt(30 / 50)}))},
	-- An arrow striking a mob or a player
	arrow_hit = {
		a = layers(tone("sine", 400, 0.1, 0.6, -0.3),
			burst(600, 4000, 0.02, 0.8, {env_sustain = secs(0.06)})),
		b = layers(tone("sine", 200, 0.07, 0.5, -0.3),
			at(0.02, v{wave = "sine", base_freq = hz(240),
				trem_depth = 1, trem_speed = sqrt(18 / 50),
				env_decay = secs(0.3), volume = 0.35})),
		c = layers(tone("triangle", 2400, 0.012, 0.5, 0),
			burst(2500, nil, 0.03, 0.3)),
	},
}

-- What plays: a take of each, the first options round's pick to come
-- ([SKELENTI_SOUNDS] under [USER_INPUT]); a sound with one take has it
M.PICK = {}
for name in pairs(M.TAKES) do
	M.PICK[name] = "a"
end
-- How far the variants are nudged apart (blip's vary: 0..1 of sfxr's
-- mutate step)
M.VARY = 0.15

-- [SKELDAT_BOW_SOUND_TUNE] These rendered and scaled to this peak (as
-- the board's grains are): the bow's and the arrow's, too faint as made.
-- Before that, driven to DRIVE times their peak through a soft clip
-- (tanh's): a noise burst's peak is one sample, and scaled by it alone
-- the rest stayed quiet
M.PEAK = {arrow_land = 0.9, arrow_hit = 0.9}
M.DRIVE = 4
M.RATE = 44100

-- name -> its Sounds, once make() has run
M.made = {}

local function peak_of(b)
	local m = 0
	for i = 0, b:len() - 1 do
		m = math.max(m, math.abs(b:get(i)))
	end
	return m
end
-- A take's samples, scaled to M.PEAK if it has one
function M.render(blip, synth, name, p)
	local b = blip.gen.render(p, M.RATE, synth)
	local peak = M.PEAK[name] and peak_of(b) or 0
	if peak > 0 then
		local k = M.DRIVE / peak
		for i = 0, b:len() - 1 do
			-- tanh's Pade form, 1 at 3, where it is held
			local x = math.max(-3, math.min(3, b:get(i) * k))
			b:set(i, x * (27 + x * x) / (27 + 9 * x * x))
		end
		b:gain(M.PEAK[name] / peak_of(b))
	end
	return b
end

-- Renders each picked take's variants. -> how many Sounds were made
-- magic and synth: for the takes scaled to a peak (blip.sound otherwise)
function M.make(blip, magic, synth)
	local gen, n = blip.gen, 0
	for name, takes in pairs(M.TAKES) do
		local p = gen.params(takes[M.PICK[name]])
		local list = {}
		for i = 1, M.VARIANTS do
			-- Variant 1 is the take as designed
			local pv = i == 1 and p or gen.vary(p, i, M.VARY)
			if M.PEAK[name] then
				local vb = magic.VectorBuffer:new()
				M.render(blip, synth, name, pv):to_shorts(vb)
				list[i] = magic.Sound:new()
				list[i]:SetFormat(M.RATE, true, false)
				list[i]:SetData(vb)
			else
				list[i] = blip.sound(pv)
			end
			n = n + 1
		end
		M.made[name] = list
	end
	return n
end

-- [SKELDAT_BOW_SOUND_TUNE] The self-check against the takes as they were
-- (6e73cfc08): arrow_land and arrow_hit at their peak and with 4 times
-- the RMS over the first 100 ms (arrow_hit 2: its old sine filled them
-- already, and 4 would be a square wave); bow_draw's share between 700
-- and 1500 Hz at most half. The bow's, the user's as made, hashed for the
-- log: not raised on, a platform's floats may render it otherwise.
-- -> a line for the log; raises on a failure
local LOUDER = {arrow_land = 4, arrow_hit = 2}
local WAS = {
	bow_draw = v{wave = "saw", base_freq = hz(60), freq_ramp = 0.111,
		hpf_freq = hp(900), lpf_freq = lp(1300), lpf_resonance = 0.7,
		vib_strength = 0.1, vib_speed = 0.24, env_attack = secs(0.9),
		env_sustain = secs(0.1), env_decay = secs(0.05), volume = 0.5},
	arrow_land = layers(tone("triangle", 900, 0.005, 0.6, 0),
		tone("triangle", 3000, 0.0017, 0.3, 0),
		v{wave = "sine", base_freq = hz(180), trem_depth = 1,
			trem_speed = sqrt(30 / 50), env_decay = secs(0.2), volume = 0.35}),
	arrow_hit = layers(tone("sine", 220, 0.1, 0.6, -0.3),
		burst(nil, 2000, 0.01, 0.4)),
}
function M.self_check(blip, synth)
	local gen, out, bad = blip.gen, {}, {}
	local function rms100(b)
		local n, e = math.min(b:len(), M.RATE / 10), 0
		for i = 0, n - 1 do
			e = e + b:get(i) ^ 2
		end
		return math.sqrt(e / n)
	end
	-- The user's own takes, hashed: the bow's release, the pickup and the
	-- step on grass
	for _, name in ipairs({"bow", "pickup", "step_grass"}) do
		local b = M.render(blip, synth, name,
				gen.params(M.TAKES[name][M.PICK[name]]))
		local h = 0
		for i = 0, b:len() - 1 do
			h = (h * 31 + math.floor(b:get(i) * 32767)) % 4294967296
		end
		out[#out + 1] = string.format("%s %08x (%d samples)", name, h, b:len())
	end
	for _, name in ipairs({"arrow_land", "arrow_hit"}) do
		local now = M.render(blip, synth, name,
				gen.params(M.TAKES[name][M.PICK[name]]))
		local was = gen.render(gen.params(WAS[name]), M.RATE, synth)
		local k, peak = rms100(now) / rms100(was), peak_of(now)
		out[#out + 1] = string.format("%s %.2fx", name, k)
		if k < LOUDER[name] or math.abs(peak - 0.9) > 0.01 then
			bad[#bad + 1] = string.format("%s %.2fx, peak %.2f", name, k, peak)
		end
	end
	local function mids(b)
		local band, e, eb = synth.buffer(b:len()), 0, 0
		band:mix(b, 0, 0, b:len(), 1)
		for _ = 1, 2 do
			band:filter{type = "high", cutoff = 700, resonance = 0, rate = M.RATE}
			band:filter{type = "low", cutoff = 1500, resonance = 0, rate = M.RATE}
		end
		for i = 0, b:len() - 1 do
			e, eb = e + b:get(i) ^ 2, eb + band:get(i) ^ 2
		end
		return eb / e
	end
	-- [SKELDAT_SOUNDS_HEARD] The pickup's level beside a step's and a
	-- dig's, read rather than guessed: the peak and the RMS of each
	local levels = {}
	for _, name in ipairs({"pickup", "step_wood", "dig_earth"}) do
		local b = M.render(blip, synth, name,
				gen.params(M.TAKES[name][M.PICK[name]]))
		local e = 0
		for i = 0, b:len() - 1 do
			e = e + b:get(i) ^ 2
		end
		levels[#levels + 1] = string.format("%s peak %.2f rms %.3f", name,
				peak_of(b), math.sqrt(e / math.max(1, b:len())))
	end
	out[#out + 1] = "levels: " .. table.concat(levels, ", ")
	local now = mids(gen.render(gen.params(M.TAKES.bow_draw[M.PICK.bow_draw]),
			M.RATE, synth))
	local was = mids(gen.render(gen.params(WAS.bow_draw), M.RATE, synth))
	out[#out + 1] = string.format("the draw's mids %.2f, were %.2f", now, was)
	if now > was / 2 then
		bad[#bad + 1] = out[#out]
	end
	assert(#bad == 0, "sounds: " .. table.concat(bad, "; "))
	return "sounds: self-check passed, " .. table.concat(out, ", ")
end

-- One of name's variants, or nil before make() or for a name it lacks
function M.pick(name)
	local list = M.made[name]
	return list and list[math.random(#list)]
end

return M
