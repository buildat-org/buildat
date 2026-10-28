-- Buildat: apps/demo_skelenti/main/client_lua/sounds.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- skelenti's sound effects, made with blip ([SKELENTI_SOUNDS]): no
-- files. Each sound has takes (TAKES), one of them picked (PICK); at
-- startup make() renders VARIANTS of each picked one, nudged apart by
-- blip's vary(), and hands them to the luanti client module as
-- skelenti_<name>.<1..8>.ogg -- the media names the server resolves a
-- skelenti_ sound group to (main.cpp's set_generated_sounds). The game's
-- Lua names the groups as any Luanti game would; the mobs' moments play
-- from the same Sounds (play()).
local M = {}

M.VARIANTS = 8 -- as main.cpp's set_generated_sounds() says

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
	-- A step on grass: the user's own (skeldat's, [SKELDAT_STEP_GRASS]),
	-- four layers, as made: not in M.PEAK
	step_grass = {a = "blip1:DJ2KrAAKrWKAAmJf_AAAAf_AAAAf_AAf_f_NIkgInDSd8PLHLCNAAAA__AA+AaDFVDsAAJ2WKAAmJf_AAAAf_AAAAf_AAf_f_PLkgInAAd8S4HLCN+ATDNiBpAARpWKAAf_f_AAAAf_AAAAf_AAf_f_ZBlUInGKZBGkHLCN+B3DNiBpAAL5WKAAf_f_AAAAf_AAAAf_AAf_f_ZBlUInGKZBLFHLCNAAAAVVAA"},

	-- Picking an item up: the user's own (skeldat's, [SKELDAT_PICKUP_TAKE]),
	-- as made: not in M.PEAK
	pickup = {a = "blip1:CAANiiDJCLFAAqPb5AAAA2CpuAAf_AAcVbP__gZAASDf_gAWw5O"},

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

	-- A bow loosed: the user's own (skeldat's, [SKELDAT_BOW_RELEASE_PICK]),
	-- as made: not in M.PEAK
	bow = {a = "blip1:DKQJcEhPmjsAAWJdHAAg0gzGkFVgRAAgZoMLf7dwZLFd8gAfstafl1sAAAA"},
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
-- Round 2's boar_hurt c, the user's pick ([SKELENTI_SOUNDS_3]), as skeldat's
M.PICK.boar_hurt = "c"
-- How far the variants are nudged apart (blip's vary: 0..1 of sfxr's
-- mutate step)
M.VARY = 0.15

-- As skeldat's: these rendered and scaled to this peak, driven to DRIVE
-- times their peak through a soft clip (tanh's) first: a noise burst's
-- peak is one sample, and scaled by it alone the rest stayed quiet
M.PEAK = {arrow_hit = 0.9}
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

-- Renders each picked take's variants and hands them to the luanti
-- client module. -> how many Sounds were made
-- magic and synth: for the takes scaled to a peak (blip.sound otherwise)
function M.make(blip, luanti, magic, synth)
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
			luanti.set_sound("skelenti_" .. name .. "." .. i .. ".ogg",
					list[i])
			n = n + 1
		end
		M.made[name] = list
	end
	return n
end

-- One of name's variants, or nil before make() or for a name it lacks
function M.pick(name)
	local list = M.made[name]
	return list and list[math.random(#list)]
end

return M
