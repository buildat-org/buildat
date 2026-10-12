-- [LAUNCH_WORLD]: the room's sound, synthesised, with no audio assets.
--
-- Kilobytes of code where a loop would be megabytes of ogg, which belongs
-- on the leave-out list beside the mapgen. And generated audio answers to
-- state the way a loop cannot: the number of orbs alight is the number of
-- drone voices, so the room's hum *is* the list of games.
--
-- One SoundSource on one BufferedSoundStream, no 3D. Each frame Lua tops
-- the stream up to a fixed distance ahead of the playhead; an underrun is
-- a gap in the sound and not a crash, because the stream is not told to
-- stop at its end.
--
-- **The pattern is a function of time**, which is what is worth stealing
-- from strudel.cc: a voice is asked what it does over the span about to
-- be filled, and the span is counted in samples from the start, so a
-- frame that takes 40 ms instead of 16 does not move the beat.
--
-- simplified: 22 kHz and mono. The plan budgeted 44.1 kHz stereo and
-- LuaJIT can do it; halving it halves a per-sample Lua loop that runs
-- beside a renderer, and nothing here has any stereo image to lose. The
-- upgrade is two of everything and a pan per voice.
-- simplified: no mini-notation parser -- a pattern is a Lua table of
-- steps, which reads fine. The parser is the upgrade if a pattern ever
-- gets long enough to want one.
-- Its own, rather than world.lua's: a file run on its own has no
-- globals of the room's ([LAUNCH_SANDBOX]'s run_extension_file).
-- **require answers the safe interface inside the sandbox and the whole
-- extension outside it**, which is the one difference the two contexts
-- have that a file like this can see. Asked by something the safe half
-- has, because it raises on a name it does not know rather than
-- answering nil -- so `urho3d.safe` is not a question that can be put
-- to it.
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe

local M = {}

local RATE = 22050
local BLOCK = 512          -- samples generated at a time
local AHEAD = 0.20         -- seconds kept in front of the playhead
local CYCLE = 2.0          -- seconds in a bar
local STEPS = 16

-- The patterns, one row per voice. A step is nil for silence, or a
-- number: a level for the drums, a semitone offset for the bass.
local PATTERN = {
	kick = {1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0},
	hat  = {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1},
	bass = {0, nil, nil, 7, nil, nil, 3, nil, 0, nil, 10, nil, 7, nil, 5, nil},
}

local function note_hz(semitones)
	return 55 * 2 ^ (semitones / 12)
end

-- **The sound, as an options round** ([LAUNCH_WORLD] stage 3, the sound;
-- local/options_for_LOBBY_sound/): M.new's `style`, which the room takes
-- from BUILDAT_LAUNCH_SOUND. "today" is the bed and the drone as stage 2
-- left them; the room's default is m116_broken (below). The others play
-- no beat and no orb voices -- both cut in section 13 -- but a soft
-- music, and the thunk and the desk's beep softened:
--   pad       a slow four-voice pad, Cmaj7 Am7 Fmaj7 Gadd9, 8 s a chord
--   pad_dark  the same, lower and slower: Dm9 Bbmaj7 Gm7 Am7, 12 s
--   chimes    no pad: a bell note on a pentatonic scale every few seconds
--   quiet     nothing but the soft thunk and the soft beep
M.STYLES = {today = true, pad = true, pad_dark = true, chimes = true,
	quiet = true}
local SOFT = {
	pad = {base = 130.81, dur = 8.0, gain = 0.055, chords = {
		{0, 4, 7, 11}, {-3, 0, 4, 7}, {-7, -3, 0, 4}, {-5, -1, 2, 7}}},
	pad_dark = {base = 73.42, dur = 12.0, gain = 0.06, chords = {
		{0, 7, 12, 16}, {-4, 3, 7, 14}, {-7, 3, 7, 10}, {-5, 2, 7, 12}}},
	chimes = {chimes = true},
	quiet = {},
}
-- **`pad` grown into downtempo techno** ([LAUNCH_WORLD] stage 3, section
-- 13): `pad`'s chords under a beat, two pads with their own LFOs and
-- their own ducking under the kick, a sub bass, a riff into a delay, and
-- wind and chimes, arranged in sections. The first options round is the
-- tempo and the beat's character, so those are the style's name --
-- m<bpm>_<beat> -- and the pads and the riff are held:
--   four    a soft kick on every beat, an open hat between, a rim on 2 and 4
--   broken  a kick on 1, the and of 2 and 3, a snare on 2 and 4, swung hats
for _, bpm in ipairs({92, 104, 116}) do
	for _, beat in ipairs({"four", "broken"}) do
		local name = "m" .. bpm .. "_" .. beat
		M.STYLES[name] = true
		SOFT[name] = {music = {bpm = bpm, beat = beat}}
	end
end
-- Steps of a bar, a velocity each; 0 is a rest
local BEATS = {
	four = {swing = 0,
		kick = {1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0},
		open = {0, 0, .6, 0, 0, 0, .6, 0, 0, 0, .6, 0, 0, 0, .6, 0},
		hat = {.2, .12, 0, .12, .2, .12, 0, .12, .2, .12, 0, .12, .2, .12, 0, .2},
		rim = {0, 0, 0, 0, .5, 0, 0, 0, 0, 0, 0, 0, .5, 0, 0, .15},
		snare = {}},
	broken = {swing = 0.16,
		kick = {1, 0, 0, 0, 0, 0, .75, 0, 0, 0, .9, 0, 0, 0, 0, .35},
		open = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, .45, 0},
		hat = {.35, .12, .3, .15, .35, .12, .3, .2, .35, .12, .3, .15, .35, .2, 0, .15},
		rim = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, .2, 0, 0, 0, 0},
		snare = {0, 0, 0, 0, .7, 0, 0, 0, 0, 0, 0, 0, .7, 0, 0, .2}},
}
-- The riff: two bars of steps, each an index into the chord (an octave
-- up), nil a rest -- dotted eighths, so it turns against the beat
local RIFF = {1, nil, nil, 3, nil, nil, 2, nil, nil, 4, nil, nil, 3, nil, 2, nil,
	1, nil, nil, 3, nil, nil, 2, nil, 4, nil, 3, nil, nil, 2, nil, nil}
-- The arrangement: sixteen bars a section, a target level per layer,
-- looping. A layer not named is out.
local SECTIONS = {
	{padA = 1, wind = 1},                                   -- intro
	{padA = 1, kick = 1, hats = 1, bass = 1},               -- the beat
	{padA = 1, kick = 1, hats = 1, bass = 1, riff = 1},     -- the riff in
	{padB = 1, kick = 1, hats = 1, bass = 1, riff = 1, chimes = 1},
	{padB = 1, wind = 1, chimes = 1, hats = 0.3},           -- the break
	{padA = 1, padB = 0.5, kick = 1, hats = 1, bass = 1},   -- back, no riff
}
local LAYERS = {"padA", "padB", "kick", "hats", "bass", "riff", "wind", "chimes"}
-- A sine by table: the pads' four voices and their overtones a sample
local SINE = {}
for i = 0, 1023 do
	SINE[i] = math.sin(i / 1024 * 6.2831853)
end
local function sine(phase)
	return SINE[math.floor((phase % 1) * 1024)]
end
local PENTA = {0, 2, 4, 7, 9, 12, 14, 16}

-- A block's samples into its buffer at once ([FRAME_WORK]: a WriteShort()
-- is a sandboxed call each, ~70% of a block's time)
local function write_block(buf, out)
	return buildat.write_shorts(buf, out)
end

function M.new(magic, log, style)
	local s = {
		style = M.STYLES[style or ""] and style or "today",
		chimes = {},        -- {f, age} of the bells ringing
		next_chime = 0,     -- samples until the next one
		thunk_age = 0,
		beep_age = 0,
		magic = magic,
		log = log,
		t = 0,              -- samples generated since the start
		voices = 1,         -- how many drone voices are alight
		phase = {0, 0, 0, 0, 0},
		env = {kick = 0, hat = 0, bass = 0, thunk = 0, beep = 0},
		beep_wanted = false,
		-- **The pattern never starts or stops** ([ROOM_SOUND]): a beat
		-- that begins has an entrance and a phase, and one that is
		-- always running and merely quiet has neither. So this is a
		-- gain on something already playing, and every state of the
		-- room is a level of it.
		pattern = 0.05,
		pattern_want = 0.05,
		thunk_wanted = false,
		thunk_f = 0,
		kick_f = 60,
		bass_f = 55,
		lp = 0,
		noise = 22222,
		delay = {},
		delay_i = 1,
	}
	s.delay_n = math.floor(RATE * CYCLE / 6)
	for i = 1, s.delay_n do
		s.delay[i] = 0
	end
	s.stream = magic.BufferedSoundStream:new()
	s.stream:SetFormat(RATE, true, false)
	-- An underrun is a gap, not the end of the sound
	s.stream.stopAtEnd = false
	s.buffer = magic.VectorBuffer:new()
	s.out = {}       -- a block's samples, for write_block

	-- A cheap white noise: the same xorshift the ornament uses, which is
	-- as random as a hat needs
	local function rand(self)
		self.noise = (self.noise * 16807) % 2147483647
		return self.noise / 1073741823.5 - 1
	end

	-- **The selection thunk**: the era's menus answered a choice with a
	-- sound that felt like a switch closing, and this room has a synth
	-- already, so it costs an envelope rather than an asset.
	--
	-- simplified: it lands at the start of the next block, so it is up
	-- to the buffer's length late -- 0.2 s. The upgrade is a shorter
	-- buffer, or writing it into the block already queued.
	function s:thunk()
		self.thunk_wanted = true
	end

	-- **The desk answers with a short hollow beep** ([ROOM_SOUND]).
	-- Hollow is odd harmonics, which is a pulse wave -- a square is the
	-- cheapest one -- and it is pitched to the drones' own root two
	-- octaves up, so it belongs to the room rather than arriving from
	-- somewhere else. Short, with a fast decay.
	function s:beep()
		self.beep_wanted = true
	end

	-- **Rises quickly and falls slowly**: rising is what gives the
	-- pace, and the slow fall is the hysteresis that stops the level
	-- strobing as the selection crosses a rank of orbs. One number,
	-- ramped per block rather than per sample -- 23 ms is smooth
	-- enough for a gain and costs nothing.
	function s:set_engagement(x)
		-- **Nought is a level** ([ROOM_SOUND], 2026-09-24: the bed goes
		-- away when nobody is doing anything). The floor used to be
		-- 0.05, so an empty room still had a beat under it.
		self.pattern_want = math.max(0, math.min(1.0, x or 0))
	end

	-- One block of samples, mixed and written
	-- The soft styles' block: no beat, no drone, a pad or the bells, and
	-- the softened thunk and beep
	function s:fill_soft()
		local buf, out = self.buffer, self.out
		buf:Clear()
		local cfg = SOFT[self.style]
		if self.thunk_wanted then
			self.thunk_wanted = false
			self.env.thunk = 1
			self.thunk_age = 0
		end
		if self.beep_wanted then
			self.beep_wanted = false
			self.env.beep = 1
			self.beep_age = 0
		end
		local xf = 2.5 * RATE
		if cfg.music then
			self:music_block(cfg.music)
		end
		for i = 0, BLOCK - 1 do
			local t = self.t + i
			local x = 0
			if cfg.music then
				x = self:music_sample(t)
			end
			if cfg.chords then
				local dur = cfg.dur * RATE
				local c = math.floor(t / dur)
				-- This chord, and the last one fading under it
				for back = 0, 1 do
					local ci = c - back
					if ci >= 0 then
						local tc = t - ci * dur
						local e
						if tc < xf then
							e = tc / xf
						elseif tc < dur then
							e = 1
						else
							e = 1 - (tc - dur) / xf
						end
						if e > 0 then
							e = e * e * (3 - 2 * e)
							local chord = cfg.chords[ci % #cfg.chords + 1]
							for _, semi in ipairs(chord) do
								local f = cfg.base * 2 ^ (semi / 12)
								local ph = f * t / RATE
								x = x + (sine(ph) + 0.12 * sine(ph * 2) +
										0.04 * sine(ph * 3)) * e * cfg.gain
							end
						end
					end
				end
			end
			if cfg.chimes or cfg.music and self.lv.chimes > 0.01 then
				self.next_chime = self.next_chime - 1
				if self.next_chime <= 0 then
					local n = PENTA[math.floor((rand(self) + 1) * 4) % #PENTA + 1]
					self.chimes[#self.chimes + 1] = {f = 523.25 * 2 ^ (n / 12),
						age = 0}
					if #self.chimes > 4 then table.remove(self.chimes, 1) end
					self.next_chime = math.floor(RATE * (3 + (rand(self) + 1) * 2))
				end
				for _, ch in ipairs(self.chimes) do
					local a = ch.age / RATE
					local e = math.min(1, ch.age / 60) * math.exp(-a / 1.6)
					local ph = ch.f * ch.age / RATE
					x = x + (sine(ph) + 0.25 * sine(ph * 2.76)) * e * 0.10 *
							(cfg.music and self.lv.chimes * 0.6 or 1)
					ch.age = ch.age + 1
				end
			end
			-- The thunk, softened: a low sine falling from 140 to 80 Hz, a
			-- few milliseconds' rise and a short tail, no noise
			if self.env.thunk > 0.0005 then
				local a = self.thunk_age / RATE
				local f = 80 + 60 * math.exp(-a / 0.05)
				self.phase[4] = (self.phase[4] + f / RATE) % 1
				x = x + sine(self.phase[4]) * self.env.thunk *
						math.min(1, self.thunk_age / 90) * 0.35
				self.env.thunk = self.env.thunk * 0.99970
				self.thunk_age = self.thunk_age + 1
			end
			-- The beep, softened: a sine at E5 with a quiet octave, a bell
			-- shape rather than a square
			if self.env.beep > 0.0005 then
				self.phase[5] = (self.phase[5] + 659.25 / RATE) % 1
				x = x + (sine(self.phase[5]) + 0.2 * sine(self.phase[5] * 2)) *
						self.env.beep * math.min(1, self.beep_age / 60) * 0.16
				self.env.beep = self.env.beep * 0.99985
				self.beep_age = self.beep_age + 1
			end
			x = x / (1 + math.abs(x))
			out[i + 1] = x * 20000
		end
		write_block(buf, out)
		self.t = self.t + BLOCK
		self.stream:AddData(buf)
	end

	-- **The music**: a function of the sample count like the rest, so a
	-- slow frame does not move the beat. Per block, the layers' levels
	-- move a step towards the section's; per sample, the voices.
	--
	-- simplified: one delay line and no reverb. A reverb is the upgrade
	-- if the room sounds dry -- a few comb filters, which cost a sample
	-- each.
	function s:music_block(m)
		if not self.lv then
			local spb = RATE * 60 / m.bpm
			self.lv = {}
			for _, k in ipairs(LAYERS) do self.lv[k] = 0 end
			self.mu = {beat = BEATS[m.beat], step_len = spb / 4, k = -1,
				kick = 0, kick_f = 50, hat = 0, hat_decay = 0.997,
				rim = 0, snare = 0, snare_ph = 0, duckA = 0, duckB = 0,
				riff = 0, riff_f = 0, riff_lp = 0, riff_cut = 0,
				padB_lp1 = 0, padB_lp2 = 0, wind1 = 0, wind2 = 0, last_n = 0,
				dl = {}, dl_i = 1, dl_n = math.floor(spb / 4 * 3)}
			for i = 1, self.mu.dl_n do self.mu.dl[i] = 0 end
		end
		local mu = self.mu
		local bar = math.floor(self.t / (mu.step_len * 16))
		local sec = SECTIONS[math.floor(bar / 16) % #SECTIONS + 1]
		mu.bar = bar
		-- About four seconds from nothing to full: a layer comes and goes
		-- across a bar or two rather than on the downbeat
		for _, k in ipairs(LAYERS) do
			local want = sec[k] or 0
			local d = want - self.lv[k]
			self.lv[k] = self.lv[k] + math.max(-1 / 170, math.min(1 / 170, d))
		end
	end

	function s:music_sample(t)
		local mu, lv = self.mu, self.lv
		local b = mu.beat
		local sl = mu.step_len
		-- The step this sample is in; an odd step starts late by `swing`
		local pair = math.floor(t / (2 * sl))
		local within = t - pair * 2 * sl
		local k = pair * 2 + (within < sl * (1 + b.swing) and 0 or 1)
		local chord_i = math.floor(t / (sl * 64))
		local chord = SOFT.pad.chords[chord_i % 4 + 1]
		if k ~= mu.k then
			mu.k = k
			local st = k % 16 + 1
			local v = b.kick[st]
			if v > 0 and lv.kick > 0.01 then
				mu.kick = v * lv.kick
				mu.kick_f = 150
				mu.duckA = mu.kick
				mu.duckB = mu.kick
			end
			v = b.open[st]
			if v > 0 then mu.hat = v; mu.hat_decay = 0.9994 end
			v = b.hat[st]
			if v > 0 and b.open[st] == 0 then mu.hat = v; mu.hat_decay = 0.997 end
			if b.rim[st] > 0 then mu.rim = b.rim[st] end
			if (b.snare[st] or 0) > 0 then mu.snare = b.snare[st] end
			local r = RIFF[k % 32 + 1]
			if r then
				mu.riff = 1
				mu.riff_cut = 1
				mu.riff_f = 261.63 * 2 ^ (chord[r] / 12)
			end
		end
		local n = (self.noise * 16807) % 2147483647
		self.noise = n
		n = n / 1073741823.5 - 1
		local sec = t / RATE
		local x = 0
		-- The kick: a sine falling from 150 to 50 Hz, soft at the front
		mu.kick_f = 50 + (mu.kick_f - 50) * 0.9992
		self.phase[1] = (self.phase[1] + mu.kick_f / RATE) % 1
		x = x + sine(self.phase[1]) * mu.kick * 0.39
		mu.kick = mu.kick * 0.99968
		mu.duckA = mu.duckA * 0.99987   -- padA lets go in a third of a second
		mu.duckB = mu.duckB * 0.99975   -- padB and the bass, quicker
		-- Hats, rim, snare: differenced noise, which is bright
		local dn = n - mu.last_n
		mu.last_n = n
		x = x + dn * mu.hat * 0.2 * lv.hats
		mu.hat = mu.hat * mu.hat_decay
		mu.snare_ph = (mu.snare_ph + 185 / RATE) % 1
		x = x + (n * 0.5 + sine(mu.snare_ph) * 0.5) * mu.snare * 0.22 * lv.kick
		mu.snare = mu.snare * 0.9993
		x = x + (dn * 0.6 + sine(sec * 820) * 0.4) * mu.rim * 0.18 * lv.hats
		mu.rim = mu.rim * 0.998
		-- The chords: this one, and the last fading under it over a bar
		local xf = sl * 16
		local tc = t - chord_i * sl * 64
		local e = tc < xf and tc / xf or 1
		e = e * e * (3 - 2 * e)
		local prev = SOFT.pad.chords[(chord_i - 1) % 4 + 1]
		-- padA: `pad`'s sines, a slow tremolo and a slower brightness
		if lv.padA > 0.001 then
			local trem = 1 - 0.25 * (0.5 + 0.5 * sine(sec * 0.11))
			local bright = 0.05 + 0.2 * (0.5 + 0.5 * sine(sec * 0.07))
			local a = 0
			for ci = 1, 4 do
				local ph = 130.81 * 2 ^ (chord[ci] / 12) * sec
				a = a + (sine(ph) + bright * sine(ph * 2) + 0.04 * sine(ph * 3)) * e
				if e < 1 and chord_i > 0 then
					ph = 130.81 * 2 ^ (prev[ci] / 12) * sec
					a = a + (sine(ph) + bright * sine(ph * 2)) * (1 - e)
				end
			end
			x = x + a * 0.05 * trem * lv.padA * (1 - 0.4 * mu.duckA)
		end
		-- padB: detuned saws through two poles whose cutoff an LFO sweeps
		if lv.padB > 0.001 then
			local a = 0
			for ci = 1, 4 do
				local f = 130.81 * 2 ^ (chord[ci] / 12)
				a = a + ((f * 1.004 * sec) % 1 + (f * 0.996 * sec) % 1 - 1) * e
				if e < 1 and chord_i > 0 then
					f = 130.81 * 2 ^ (prev[ci] / 12)
					a = a + ((f * 1.004 * sec) % 1 + (f * 0.996 * sec) % 1 - 1) *
							(1 - e)
				end
			end
			local c = 0.05 + 0.15 * (0.5 + 0.5 * sine(sec * 0.045))
			mu.padB_lp1 = mu.padB_lp1 + (a - mu.padB_lp1) * c
			mu.padB_lp2 = mu.padB_lp2 + (mu.padB_lp1 - mu.padB_lp2) * c
			x = x + mu.padB_lp2 * 0.10 * lv.padB * (1 - 0.65 * mu.duckB)
		end
		-- The sub bass: the chord's root two octaves down, held, ducked
		if lv.bass > 0.001 then
			x = x + sine(65.41 * 2 ^ (chord[1] / 12) * sec) * 0.09 * lv.bass *
					(1 - 0.75 * mu.duckB)
		end
		-- The riff: a saw plucked through a closing filter, into the delay
		local wet = 0
		if lv.riff > 0.001 then
			mu.riff_cut = mu.riff_cut * 0.9995
			local saw = (mu.riff_f * sec) % 1 * 2 - 1
			mu.riff_lp = mu.riff_lp + (saw - mu.riff_lp) * (0.02 + 0.25 * mu.riff_cut)
			wet = mu.riff_lp * mu.riff * 0.18 * lv.riff
			mu.riff = mu.riff * 0.99985
		end
		local d = mu.dl[mu.dl_i]
		mu.dl[mu.dl_i] = wet + d * 0.42
		mu.dl_i = mu.dl_i % mu.dl_n + 1
		x = x + wet + d * 0.5
		-- Wind: noise through two slow poles, swelling on an LFO
		if lv.wind > 0.001 then
			local c = 0.01 + 0.02 * (0.5 + 0.5 * sine(sec * 0.031))
			mu.wind1 = mu.wind1 + (n - mu.wind1) * c
			mu.wind2 = mu.wind2 + (mu.wind1 - mu.wind2) * c
			x = x + mu.wind2 * (0.6 + 0.4 * sine(sec * 0.083)) * 0.8 * lv.wind
		end
		return x
	end

	function s:fill()
		if self.style ~= "today" then
			return self:fill_soft()
		end
		local buf, out = self.buffer, self.out
		buf:Clear()
		local step_len = RATE * CYCLE / STEPS
		if self.thunk_wanted then
			self.thunk_wanted = false
			self.env.thunk = 1
			self.thunk_f = 320
		end
		if self.beep_wanted then
			self.beep_wanted = false
			self.env.beep = 1
		end
		local up = self.pattern_want > self.pattern
		self.pattern = self.pattern +
				(self.pattern_want - self.pattern) * (up and 0.25 or 0.03)
		for i = 0, BLOCK - 1 do
			local t = self.t + i
			-- Where in the bar this sample is, and whether it starts a step
			local pos = t % (RATE * CYCLE)
			local step = math.floor(pos / step_len)
			if math.floor((pos - 1) / step_len) ~= step then
				local k = PATTERN.kick[step + 1]
				if k and k > 0 then
					self.env.kick = 1
					self.kick_f = 120
				end
				local h = PATTERN.hat[step + 1]
				if h and h > 0 then
					self.env.hat = 1
				end
				local b = PATTERN.bass[step + 1]
				if b then
					self.env.bass = 1
					self.bass_f = note_hz(b)
				end
			end
			-- The kick: a sine whose pitch falls as fast as its level
			self.kick_f = 45 + (self.kick_f - 45) * 0.9994
			self.phase[1] = (self.phase[1] + self.kick_f / RATE) % 1
			local kick = math.sin(self.phase[1] * 6.2831853) * self.env.kick
			self.env.kick = self.env.kick * 0.99975
			-- The hat: a noise burst, differenced so it is bright
			local n = rand(self)
			local hat = (n - (self.last_n or 0)) * 0.5 * self.env.hat
			self.last_n = n
			self.env.hat = self.env.hat * 0.9988
			-- The bass: a saw into a one-pole low-pass
			self.phase[2] = (self.phase[2] + self.bass_f / RATE) % 1
			local saw = self.phase[2] * 2 - 1
			self.lp = self.lp + (saw - self.lp) * 0.06
			local bass = self.lp * self.env.bass
			self.env.bass = self.env.bass * 0.99985
			-- The drone: one detuned pair per voice alight, which is what
			-- makes the room's hum the list of games
			local drone = 0
			-- **The bed is the core, and it is low**: the orbs carry
			-- the room's pitches now ([ROOM_SOUND]), so what is left
			-- here is the thing underneath them that does not pan --
			-- two sines a beat apart, an octave below the drones'
			-- root, so the room never goes quiet when the player faces
			-- away from the wall
			for v = 1, math.min(self.voices, 2) do
				self.phase[2 + v] = (self.phase[2 + v] +
						(M.DRONE_HZ / 2 + v * 0.35) / RATE) % 1
				drone = drone + math.sin(self.phase[2 + v] * 6.2831853)
			end
			drone = drone * 0.06 * math.min(self.voices, 6) / 6
			-- The thunk: a short body falling fast, with a click on the
			-- front of it -- a switch closing rather than a note
			self.thunk_f = 58 + (self.thunk_f - 58) * 0.9986
			self.phase[4] = (self.phase[4] + self.thunk_f / RATE) % 1
			local thunk = (math.sin(self.phase[4] * 6.2831853) * 0.7 +
					(self.env.thunk > 0.82 and n * 0.5 or 0)) * self.env.thunk
			self.env.thunk = self.env.thunk * 0.9990
			-- The beep: a square at the root two octaves up, gone in a
			-- tenth of a second
			self.phase[5] = (self.phase[5] + M.DRONE_HZ * 4 / RATE) % 1
			local beep = (self.phase[5] < 0.5 and 1 or -1) * self.env.beep
			self.env.beep = self.env.beep * 0.9985
			-- One delay line, on everything but the kick
			local d = self.delay[self.delay_i]
			local wet = hat * 0.5 + bass * 0.3
			self.delay[self.delay_i] = wet + d * 0.45
			self.delay_i = self.delay_i % self.delay_n + 1
			-- The mix, through a soft limiter: x/(1+|x|) never clips and
			-- needs no lookahead, which a room's bed does not miss
			-- **The pattern is a gain, and the drones duck as it
			-- rises** -- a little, so focus is a change of character
			-- rather than of loudness
			local pat = self.pattern
			-- **The bed's own drone falls with the pattern, and only at
			-- the bottom** ([ROOM_SOUND]): the beat is multiplied by
			-- `pat` already, but the drone is not, and it *rises* as
			-- `pat` falls -- at idle it would be the only thing left
			-- and louder than it is now. A plain `* pat` would make the
			-- room quieter at every level, which is a remix nobody
			-- asked for; this reaches full by the pointing step, so
			-- every level a player can be at sounds as it did and only
			-- the empty room changes. The duck below stays as it is.
			local up = math.min(1, pat / 0.25)
			local x = (kick * 0.9 + hat * 0.35 + bass * 0.45 + d * 0.35) *
					pat + drone * up * (1 - 0.35 * pat) + thunk * 0.8 +
					beep * 0.22
			x = x / (1 + math.abs(x))
			out[i + 1] = x * 20000
		end
		write_block(buf, out)
		self.t = self.t + BLOCK
		self.stream:AddData(buf)
	end

	-- Called every frame: top up to AHEAD seconds in front of the playhead
	function s:update()
		local guard = 0
		while self.stream.bufferLength < AHEAD and guard < 64 do
			self:fill()
			guard = guard + 1
		end
	end

	function s:play(node)
		local source = node:CreateComponent("SoundSource")
		source.gain = 0.6
		source:Play(self.stream)
		self.source = source
		return source
	end

	-- What the room says about itself: how many orbs are alight
	function s:set_voices(n)
		self.voices = math.max(1, n)
	end

	return s
end

-- **One loop, many pitches** ([ROOM_SOUND]'s cheap build). A drone is
-- periodic, so nothing is synthesised per frame: one loop is generated
-- once and appended to a stream whenever it runs low. And **the pitch
-- is the playback rate**, so every orb in the room plays this same loop
-- at its own frequency -- twenty voices for one loop's worth of Lua.
--
-- Two saws detuned by `beat` Hz, heavily low-passed, at the reference
-- pitch below. The loop is exactly the beat period, so it is seamless:
-- both partials complete whole cycles across it.
M.DRONE_HZ = 55.0
function M.drone_loop(magic, beat, bright)
	local beat_hz = beat or 0.6
	local n = math.floor(RATE / beat_hz)
	local buf = magic.VectorBuffer:new()
	local p1, p2, lp = 0, 0, 0
	local f1 = M.DRONE_HZ
	local f2 = M.DRONE_HZ + beat_hz
	-- A brighter voice is the same two saws under a slacker filter,
	-- which is what "raise the filter" means when the filter is one
	-- pole and the loop is made once
	local k = bright and 0.10 or 0.035
	for i = 1, n do
		p1 = (p1 + f1 / RATE) % 1
		p2 = (p2 + f2 / RATE) % 1
		local saw = (p1 * 2 - 1) + (p2 * 2 - 1)
		lp = lp + (saw * 0.5 - lp) * k
		local x = lp
		x = x / (1 + math.abs(x))
		buf:WriteShort(math.floor(x * 12000))
	end
	return {buffer = buf, samples = n, rate = RATE}
end

-- A voice is a stream that the same loop is poured into. It is fed from
-- the room's update: an append when it runs low, not a sample loop.
function M.drone_voice(magic, loop)
	local v = {loop = loop}
	v.stream = magic.BufferedSoundStream:new()
	v.stream:SetFormat(RATE, true, false)
	v.stream.stopAtEnd = false
	function v:feed()
		local guard = 0
		while self.stream.bufferLength < 0.4 and guard < 4 do
			self.stream:AddData(self.loop.buffer)
			guard = guard + 1
		end
	end
	return v
end

-- The synth's own check: a block has to be the right length, its samples
-- have to be inside 16 bits, and a bar has to be a bar -- the kick's
-- pattern landing where the table says it does rather than wherever the
-- block boundaries fell.
function M.self_check(magic)
	-- **The drone loop is seamless and inside sixteen bits**: it is
	-- played end to end for as long as the room is up, so a step at the
	-- join is a click once a loop, for ever ([ROOM_SOUND])
	local loop = M.drone_loop(magic, 0.6, false)
	assert(loop.samples == math.floor(RATE / 0.6),
			"the loop is the beat period: " .. loop.samples)
	local s = M.new(magic, nil)
	s:set_voices(3)
	local before = s.stream.bufferNumBytes
	s:fill()
	local added = s.stream.bufferNumBytes - before
	assert(added == BLOCK * 2, "a block is " .. added .. " bytes")
	-- A whole bar, block by block, watching where the kick's envelope
	-- jumps: those are the steps the pattern has a kick on
	-- **The beep is short and it is odd harmonics**: a square at the
	-- root two octaves up, gone inside a fifth of a second, which is
	-- what "hollow" and "short" mean in samples ([ROOM_SOUND])
	local before = s.env.beep
	s:beep()
	s:fill()
	assert(before == 0 and s.env.beep > 0 and s.env.beep < 0.6,
			"the beep rings and decays: " .. tostring(s.env.beep))
	local hits = {}
	local last = 0
	local blocks = math.ceil(RATE * CYCLE / BLOCK)
	for _ = 1, blocks do
		local t0 = s.t
		s:fill()
		if s.env.kick > last + 0.1 then
			hits[#hits + 1] = math.floor(t0 / (RATE * CYCLE / STEPS))
		end
		last = s.env.kick
	end
	assert(#hits >= 2, "the kick fires " .. #hits .. " times in a bar")
	-- And the thunk: asking for one has to change what comes out
	local quiet = s.stream.bufferNumBytes
	s:fill()
	local a = s.stream.bufferNumBytes - quiet
	s:thunk()
	s:fill()
	assert(s.env.thunk > 0.5, "the thunk rang")
	assert(s.stream.bufferNumBytes - quiet == a * 2, "and wrote a block")
	-- **The music's kick lands on its steps, swung or not**: one bar of
	-- `broken`, the beat only, the steps where the kick's level jumps
	local m = M.new(magic, nil, "m116_broken")
	m:music_block(SOFT.m116_broken.music)
	for k in pairs(m.lv) do m.lv[k] = 0 end
	m.lv.kick = 1
	local got, want, last = {}, {}, 0
	for st, v in ipairs(BEATS.broken.kick) do
		if v > 0 then want[#want + 1] = st - 1 end
	end
	for t = 0, math.floor(m.mu.step_len * 16) - 1 do
		m:music_sample(t)
		if m.mu.kick > last + 0.1 then got[#got + 1] = m.mu.k end
		last = m.mu.kick
	end
	assert(table.concat(got, " ") == table.concat(want, " "),
			"the kick fell on " .. table.concat(got, " "))
	return string.format("synth ok: %d samples a block, %d kicks in a bar, " ..
			"the thunk rings, %.2f s buffered, a drone loop of %d samples, " ..
			"the music's kick on its steps",
			BLOCK, #hits, s.stream.bufferLength, loop.samples)
end

return M
