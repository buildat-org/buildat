-- Buildat: apps/skeldat/main/client_lua/board_sound.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [SKELDAT_BOARD_SOUND] The board's roll, synthesized and streamed: the
-- wheels' hits on concrete's grain each knock the deck, at a rate rising
-- with the speed, over a low roar of the wheels. Every surface sounds as
-- concrete; the air is silent. One roll a stream, fed 10 ms chunks made
-- by buildat.synth's blocks, so the summing is C++'s.
--   local board_sound = load("main/board_sound.lua")
--   local grains = board_sound.grains(buildat.synth)
--   local r = board_sound.new(buildat.synth, grains, seed)
--   r:render(s, on_ground) -- -> hits; the chunk in r.out[0, CHUNK)
-- [SKELDAT_NO_SCRAPE] No brake sound: the roll quiets as the brake slows
-- the board (the scrape, band-filtered noise, sounded like a bus door)
local M = {}
M.RATE = 22050
-- [SKELDAT_BOARD_SOUND_LAG] What is queued is heard that much later: 10 ms
-- chunks. [SKELDAT_BOARD_SOUND_FAULT] The mixer takes a device buffer's
-- worth at once, so the queue is kept at the device's buffer and
-- MARGIN_MS more (a 60 Hz frame's 17 and some): less, and the rest of
-- each pull was silence. The source's own buffer holds a fragment's pull
-- and 10 ms (at least STREAM_MS). M.device(magic) -> device, fragment
-- ms; DEVICE_MS and FRAGMENT_MS when there is no device mode. A frame
-- longer than the queue lets it run dry: each time the queue grows by
-- RAISE_MS, to at most the device's and MAX_MARGIN_MS (logged).
-- simplified: it never shrinks again; a slow moment keeps it longer
M.RAISE_MS, M.MAX_MARGIN_MS = 5, 100
M.CHUNK = 221 -- 10 ms
M.MARGIN_MS = 20
M.STREAM_MS = 30
M.DEVICE_MS, M.FRAGMENT_MS = 46, 23
function M.device(magic)
	local a = magic.audio
	local d, f = a and a.bufferLengthMs or 0, a and a.fragmentLengthMs or 0
	return d > 0 and d or M.DEVICE_MS, f > 0 and f or M.FRAGMENT_MS
end
-- simplified: first figures, to tune by ear
M.HITS_PER_SPEED = 25 -- a second, per voxel a second
M.TOP = 8 -- the speed of the full level
M.HIT_GAIN = 0.25
M.ROAR_GAIN = 0.3
local GRAIN = 441 -- 20 ms
local PRE = 220 -- a filter's settling, cut off the front
M.CLACK_PEAK = 0.8

-- A grain's peak scaled to 1
local function normalise(b)
	local peak = 0
	for i = 0, b:len() - 1 do
		peak = math.max(peak, math.abs(b:get(i)))
	end
	if peak > 0 then
		b:gain(1 / peak)
	end
end

-- The knocks, made once: band-filtered noise and the deck's mode under a
-- fast decay
function M.grains(synth)
	local R = M.RATE
	local g = {}
	for i = 1, 4 do
		local b = synth.buffer(GRAIN)
		b:noise{kind = "white", seed = 1000 + i, rate = R}
		b:filter{type = "band", cutoff = 600 + 100 * (i - 1),
				resonance = 0.8, rate = R}
		normalise(b)
		local mode = synth.buffer(GRAIN)
		mode:osc{wave = "sine", freq = 170 + 30 * (i - 1), rate = R}
		b:mix(mode, 0, 0, GRAIN, 0.8)
		b:envelope{points = {{0, 1}, {0.003, 0.4}, {0.02, 0}}, rate = R}
		normalise(b)
		g[i] = b
	end
	return g
end

-- [SKELDAT_BOARD_WATER] The splash, on foot or on the board, rendered at
-- each entry ([SKELDAT_SPLASH_TAKES]): 4 variants (a seed each), soft and
-- hard (the body's layers louder). **Its onset as long as the body takes
-- to go in**: SPLASH_SIZE over the speed, 1 s at 1 voxel a second, 100
-- ms at 10 (clamped); the washes rise over it, the bubbles and droplets
-- spread across it and after, a plop or a thump at its end.
-- **The takes**, for the user to pick from (local/options_for_SKELDAT_SPLASH):
--   a  between the first splash and the noisy one: the spray low-passed
--      3 kHz down to 500 Hz, 14 bubbles rising 10 to 30%, the noise
--      thump at 0.3, 4 droplets
--   b  no mids: a rumble under 300 Hz (half gone 50 ms on) and a quieter fizz over 3 kHz, the
--      noise thump, 8 short high bubbles, droplets
--   c  bubbly: b's rumble, a quiet fizz, 30 bubbles of 300 Hz to 1.5 kHz
--      over the onset and 0.4 s after
--   d  the first splash (8ed80d008's figures)
--   e  the noisy one (9bace1b16's figures)
--   f  round 2 ([SKELDAT_SPLASH_RETAKE]): halfway between a and c, each
--      figure at its midpoint (a's spray at 0.35, c's rumble at 1.5, the
--      fizz 0.025, 22 bubbles of 300 Hz to 2.2 kHz rising 10 to 25%, the
--      thump 0.15, 2 droplets). simplified: the figures' midpoint, not
--      the sound's; the user's ear says which way to move
-- simplified: the figures are first guesses, to tune by ear; the
-- droplets' band stops at the filter's 4.4 kHz (a fifth of the rate)
-- The pick: f, the user's of round 2 ([SKELDAT_SPLASH_F])
M.SPLASH_TAKE = "f"
M.SPLASH_TAKES = {"a", "b", "c", "d", "e", "f"}
M.SPLASH_SIZE = 1
function M.splash_ramp(speed)
	return math.max(0.06, math.min(1.2, M.SPLASH_SIZE / math.max(speed, 0.01)))
end
-- [SKELDAT_SPLASH_F] Take f's noise (its washes and its thump) by the
-- speed into the water: whole from 10 a second, less energetic slower.
-- simplified: speed / 10, a straight line from the user's "ok at 10"; the
-- ear may want it steeper, or a floor other than 0.2
function M.splash_noise(speed)
	return math.max(0.2, math.min(1, speed / 10))
end
local function peak_of(b)
	local peak = 0
	for i = 0, b:len() - 1 do
		peak = math.max(peak, math.abs(b:get(i)))
	end
	return peak
end
local function energy(b)
	local e = 0
	for i = 0, b:len() - 1 do
		e = e + b:get(i) ^ 2
	end
	return e
end
-- take, v 1..4, ramp in seconds, hard, noise (f's: its noise's share,
-- 1 when nil) -> a buffer, its peak 1 at noise 1
function M.splash(synth, take, v, ramp, hard, noise)
	local R = M.RATE
	local L = math.floor((ramp + 0.7) * R)
	local r0 = math.floor(ramp * R)
	local loud = hard and 1.5 or 1
	local rnd = v * 7919
	local function rand()
		rnd = (rnd * 1103515245 + 12345) % 2147483648
		return rnd / 2147483648
	end
	local seed = 2000 + 100 * v
	local out, t = synth.buffer(L), synth.buffer(L)
	-- [SKELDAT_SPLASH_F] f's noise in a buffer of its own when it is cut:
	-- scaled as the whole would be, so that the bubbles keep their level
	noise = noise or 1
	local nb = take == "f" and noise < 1 and synth.buffer(L) or nil
	local noise_out = nb or out
	-- Noise rising over the onset and falling over decay; lo and hi the
	-- high and low passes, hi a number or {from, to, over} (seconds from
	-- the onset's end: the sweep is held at from until then); knee: down
	-- to half in that many seconds after the onset, then the rest
	local function wash(gain, lo, hi, decay, knee)
		local b = synth.buffer(L)
		seed = seed + 1
		b:noise{kind = "white", seed = seed, rate = R}
		if type(hi) == "table" then
			local slide = (hi[2] - hi[1]) / hi[3]
			b:filter{type = "low", cutoff = {start = hi[1] - slide * ramp,
					slide = slide, min = hi[2], max = hi[1]},
					resonance = 0, rate = R}
		elseif hi then
			b:filter{type = "low", cutoff = hi, resonance = 0, rate = R}
		end
		if lo then
			b:filter{type = "high", cutoff = lo, resonance = 0, rate = R}
		end
		b:envelope{points = knee and {{0, 0}, {ramp, 1}, {ramp + knee, 0.5},
				{ramp + decay, 0}} or {{0, 0}, {ramp, 1}, {ramp + decay, 0}},
				rate = R}
		noise_out:mix(b, 0, 0, L, gain)
	end
	-- A sine plop at the onset's end, falling
	local function plop(gain)
		local n = math.floor(0.06 * R)
		t:osc{wave = "sine", freq = {start = 130 + 15 * v, mul = 0.02},
				rate = R, n = n}
		t:envelope{points = {{0, 1}, {0.06, 0}}, rate = R, n = n}
		out:mix(t, 0, math.min(r0, L - n), n, gain)
	end
	-- Low noise, 50 ms, at the onset's end
	local function thump(gain)
		local n = math.floor(0.06 * R)
		seed = seed + 1
		t:noise{kind = "white", seed = seed, rate = R, n = n}
		t:filter{type = "low", cutoff = 250, resonance = 0, rate = R, n = n}
		t:envelope{points = {{0, 1}, {0.05, 0}}, rate = R, n = n}
		noise_out:mix(t, 0, math.min(r0, L - n), n, gain)
	end
	-- n rising chirps of len_lo..len_hi s at f_lo..f_hi Hz, rising by
	-- rise_lo..rise_hi of themselves, over the onset and after s more;
	-- noisy: half of each its band of noise
	local function bubbles(n, len_lo, len_hi, f_lo, f_hi, rise_lo, rise_hi,
			after, gain, noisy)
		for _ = 1, n do
			local len = len_lo + (len_hi - len_lo) * rand()
			local k = math.floor(len * R)
			local f = f_lo + (f_hi - f_lo) * rand()
			local at = math.min(L - k, math.floor(rand() * (ramp + after) * R))
			t:osc{wave = "sine", freq = {start = f, slide = f * (rise_lo +
					(rise_hi - rise_lo) * rand()) / len}, rate = R, n = k}
			t:envelope{points = {{0, 1}, {len, 0}}, rate = R, n = k}
			out:mix(t, 0, at, k, noisy and gain / 2 or gain)
			if noisy then
				seed = seed + 1
				t:noise{kind = "white", seed = seed, rate = R, n = k}
				t:filter{type = "band", cutoff = f, resonance = 0.7, rate = R,
						n = k}
				t:envelope{points = {{0, 1}, {len, 0}}, rate = R, n = k}
				out:mix(t, 0, at, k, gain / 2)
			end
		end
	end
	-- n bursts of band noise at lo..4.4 kHz, from the onset's middle to
	-- 0.5 s after its end
	local function droplets(n, lo, gain)
		for _ = 1, n do
			local len = 0.005 + 0.005 * rand()
			local k = math.floor(len * R)
			seed = seed + 1
			t:noise{kind = "white", seed = seed, rate = R, n = k}
			t:filter{type = "band", cutoff = lo + (4400 - lo) * rand(),
					resonance = 0.5, rate = R, n = k}
			t:envelope{points = {{0, 1}, {len, 0}}, rate = R, n = k}
			out:mix(t, 0, math.min(L - k, math.floor((ramp / 2 +
					(ramp / 2 + 0.5) * rand()) * R)), k, gain)
		end
	end
	if take == "a" then
		wash(0.7 * loud, nil, {3000, 500, 0.45}, 0.5)
		bubbles(14, 0.01, 0.04, 400, 3000, 0.1, 0.3, 0.3, 0.2)
		thump(0.3 * loud)
		droplets(4, 1500, 0.15)
	elseif take == "b" then
		-- White noise under 300 Hz keeps a sixth of its level, over 3 kHz
		-- most of it: the gains weigh that in
		wash(3.0 * loud, nil, 300, 0.5, 0.05)
		wash(0.1, 3000, nil, 0.3)
		thump(0.4 * loud)
		bubbles(8, 0.005, 0.015, 2500, 4000, 0.05, 0.15, 0.3, 0.05)
		droplets(6, 3000, 0.15)
	elseif take == "c" then
		wash(3.0 * loud, nil, 300, 0.6, 0.05)
		wash(0.05, 3000, nil, 0.3)
		bubbles(30, 0.01, 0.04, 300, 1500, 0.1, 0.2, 0.4, 0.12)
	elseif take == "f" then
		wash(0.35 * loud, nil, {3000, 500, 0.45}, 0.5)
		wash(1.5 * loud, nil, 300, 0.6, 0.05)
		wash(0.025, 3000, nil, 0.3)
		bubbles(22, 0.01, 0.04, 300, 2200, 0.1, 0.25, 0.3, 0.16)
		thump(0.15 * loud)
		droplets(2, 1500, 0.15)
	elseif take == "d" then
		plop(0.8 * loud)
		wash(0.4 * loud, nil, {3000, 400, 0.4}, 0.5)
		bubbles(20, 0.02, 0.06, 400, 3000, 0.2, 0.5, 0.3, 0.3)
	else
		wash(loud, nil, {4000, 600, 0.6}, 0.6)
		wash(0.3, 3000, nil, 0.15)
		thump(0.6 * loud)
		plop(0.15)
		bubbles(8, 0.005, 0.015, 1000, 4000, 0.05, 0.15, 0.3, 0.05, true)
		droplets(4 + math.floor(rand() * 5), 1500, 0.15)
	end
	if nb then
		local full = synth.buffer(L)
		full:mix(out, 0, 0, L, 1)
		full:mix(nb, 0, 0, L, 1)
		local peak = peak_of(full)
		out:mix(nb, 0, 0, L, noise)
		if peak > 0 then
			out:gain(1 / peak)
		end
	else
		normalise(out)
	end
	return out
end
-- A buffer as a 16-bit mono WAV file's bytes
function M.wav(b)
	local n, parts = b:len(), {}
	local function u32(x) return string.char(x % 256, math.floor(x / 256) % 256,
		math.floor(x / 65536) % 256, math.floor(x / 16777216) % 256) end
	local function u16(x) return string.char(x % 256, math.floor(x / 256) % 256) end
	parts[1] = "RIFF" .. u32(36 + n * 2) .. "WAVEfmt " .. u32(16) .. u16(1) ..
		u16(1) .. u32(M.RATE) .. u32(M.RATE * 2) .. u16(2) .. u16(16) ..
		"data" .. u32(n * 2)
	for i = 0, n - 1 do
		local x = math.floor(math.max(-1, math.min(1, b:get(i))) * 32767 + 0.5)
		parts[#parts + 1] = u16(x % 65536)
	end
	return table.concat(parts)
end
-- The splash's gain from the speed into the water: 0.2 at the walk's
-- (walk), 1 from 10 a second up; the hard variant from 6 up
function M.splash_gain(speed, walk)
	local g = 0.2 + 0.8 * (speed - walk) / math.max(0.1, 10 - walk)
	return math.max(0.1, math.min(1, g)), speed >= 6
end

-- A roll's state; seed makes its noise and its hits' times
function M.new(synth, grains, seed)
	local r = {grains = grains, rnd = seed or 1, noise_seed = (seed or 1) * 7,
		level = 0, next_hit = 0, raw = {},
		acc = synth.buffer(M.CHUNK + GRAIN),
		spare = synth.buffer(M.CHUNK + GRAIN),
		noise = synth.buffer(M.CHUNK + PRE)}
	r.out = r.acc
	function r:rand()
		self.rnd = (self.rnd * 1103515245 + 12345) % 2147483648
		return self.rnd / 2147483648
	end
	-- A filter's noise, [SKELDAT_BOARD_SOUND_FAULT]: each type's white
	-- noise goes on from the last chunk's, its last PRE samples the front
	-- of this one's, so the filter settles on the same input and the
	-- chunks join (a new noise a chunk ticked at 100 Hz)
	function r:filtered(type, cutoff)
		local N = M.CHUNK
		local raw = self.raw[type]
		if not raw then
			raw = synth.buffer(N + PRE)
			self.raw[type] = raw
		end
		raw:clear(0, PRE)
		raw:mix(raw, N, 0, PRE, 1)
		self.noise_seed = self.noise_seed % 4294967291 + 1
		raw:noise{kind = "white", seed = self.noise_seed, rate = M.RATE,
				from = PRE, n = N}
		self.noise:clear()
		self.noise:mix(raw, 0, 0, N + PRE, 1)
		self.noise:filter{type = type, cutoff = cutoff, resonance = 0,
				rate = M.RATE}
		return self.noise
	end
	-- The next chunk at speed s: -> the hits mixed in. A hit's tail runs
	-- into the next chunk (acc and spare swap, the tail carried).
	function r:render(s, on_ground)
		local N = M.CHUNK
		self.acc, self.spare = self.spare, self.acc
		self.acc:clear()
		self.acc:mix(self.spare, N, 0, self.acc:len() - N, 1)
		self.out = self.acc
		local level = on_ground and math.min(1, s / M.TOP) or 0
		if self.level > 0 or level > 0 then
			self.acc:mix(self:filtered("low", math.min(4000, 120 + 20 * s)),
					PRE, 0, N, M.ROAR_GAIN * self.level, M.ROAR_GAIN * level)
		end
		local hits = 0
		if on_ground and s > 0 then
			-- Gaps of 0.5 to 1.5 times the mean: each time jittered by up
			-- to half of it
			local gap = M.RATE / (M.HITS_PER_SPEED * s)
			local t = self.next_hit
			while t < N do
				local lv = self.level + (level - self.level) * t / N
				local g = self.grains[1 + math.floor(self:rand() * 4)]
				self.acc:mix(g, 0, math.floor(t), GRAIN,
						M.HIT_GAIN * lv * (0.3 + 0.7 * self:rand()))
				hits = hits + 1
				t = t + gap * (0.5 + self:rand())
			end
			self.next_hit = t - N
		else
			self.next_hit = 0
		end
		self.level = level
		return hits
	end
	return r
end

-- A buffer made a Sound, for a one-shot
function M.to_sound(magic, buf)
	local vb = magic.VectorBuffer:new()
	buf:to_shorts(vb)
	local sound = magic.Sound:new()
	sound:SetFormat(M.RATE, true, false)
	sound:SetData(vb)
	return sound
end

-- A roll played: a stream on a source of `kind` ("SoundSource" or
-- "SoundSource3D", p.source) in node, topped up by feed(). A rider off the
-- board feeds nothing, and its stream runs dry into silence. log: where
-- the underruns are said, once a minute (nil: not said)
function M.player(magic, synth, grains, seed, node, kind, log)
	local p = M.new(synth, grains, seed)
	local source = node:CreateComponent(kind)
	p.stream = magic.BufferedSoundStream:new()
	p.stream:SetFormat(M.RATE, true, false)
	p.stream.stopAtEnd = false
	p.vb = magic.VectorBuffer:new()
	p.source = source
	source.soundType = magic.SOUND_EFFECT
	local device, fragment = M.device(magic)
	p.device, p.fragment = device, fragment
	p.ahead = (device + M.MARGIN_MS) / 1000
	source.streamBufferLength = math.max(M.STREAM_MS, fragment + 10)
	source:Play(p.stream)
	-- The landing's clack out of the queue ([SKELDAT_BOARD_SOUND_LAG]): a
	-- Sound made once, played when it happens, behind the device only.
	-- [SKELDAT_BOARD_CLAP] One hit (grain 2) at a peak of CLACK_PEAK, some
	-- 3 to 4 times a roll hit's, so it is heard over the roll; no jump
	-- sound
	if not grains.clack_sound then
		local clack = synth.buffer(GRAIN)
		clack:mix(grains[2], 0, 0, GRAIN, M.CLACK_PEAK)
		grains.clack_sound = M.to_sound(magic, clack)
	end
	local shot = node:CreateComponent(kind)
	shot.soundType = magic.SOUND_EFFECT
	function p:clack(gain)
		shot.gain = math.max(0, math.min(1, gain))
		shot:Play(grains.clack_sound)
	end
	-- An underrun: the stream found dry at feed time, so a pull since got
	-- less than it wanted (silence for the rest). Not "under a fragment":
	-- after each pull a queue of device + MARGIN_MS sits under one, which
	-- counted ten a second on a clean roll. Counted from the first for
	-- 10 s, then said.
	local underruns, first_t, fed, fed_t, gap = 0, nil, false, nil, 0
	-- -> the stream's length after it, s
	function p:feed(s, on_ground)
		local guard = 0
		local now = buildat.get_time_us()
		if fed and self.stream.bufferLength <= 0 then
			underruns = underruns + 1
			first_t = first_t or now
			local top = (self.device + M.MAX_MARGIN_MS) / 1000
			if self.ahead < top then
				self.ahead = math.min(top, self.ahead + M.RAISE_MS / 1000)
				if log then
					log:info(string.format("skeldat: board sound: the queue "
							.. "raised to %d ms", self.ahead * 1000 + 0.5))
				end
			end
		end
		-- And the longest gap between two feeds (a frame's), for the line
		if fed and fed_t then
			gap = math.max(gap, now - fed_t)
		end
		fed, fed_t = true, now
		if first_t and now - first_t >= 10e6 then
			if log then
				log:info(string.format("skeldat: board sound: %d underruns in "
						.. "10 s, the device's buffer %d ms, the queue %d ms, "
						.. "the longest frame %d ms", underruns, self.device,
						self.ahead * 1000 + 0.5, gap / 1000))
			end
			underruns, first_t, gap = 0, nil, 0
		end
		-- The length the loop ended on: the mixer's thread may pull before
		-- a second read
		local len = self.stream.bufferLength
		while len < self.ahead and guard < 32 do
			self:render(s, on_ground)
			self.out:to_shorts(self.vb, 0, M.CHUNK)
			self.stream:AddData(self.vb)
			guard = guard + 1
			len = self.stream.bufferLength
		end
		return len
	end
	-- Off the board: the next ride ramps in from silence
	function p:rest()
		self.level, fed = 0, false
	end
	return p
end

-- The self-check: chunks at fixed seeds hashed against the committed
-- figures (the blocks are the same everywhere, src/lua_bindings/synth.cpp),
-- the hits a second within 10% of 25 s, and the air silent; and the
-- splashes' (SPLASH_HASHES, the pick at 3 a second with its noise, soft
-- 1..4 then hard 1..4).
-- -> a line for the log; raises on a failure
-- At s 0, 4 and 8, then the two air runs' last chunks; 0 and the air are
-- the silent chunk's hash
M.HASHES = "02cfd07dc33f6da3 830566adb5d45b54 1406c9e09c71c22c " ..
		"02cfd07dc33f6da3 02cfd07dc33f6da3"
M.SPLASH_HASHES = "efbdc5aac947d639 cf5616f66af7b981 5bd1699d4aac4ec5 " ..
		"b335e0b10cb67670 6c33ea2a5c1ed928 89159739cb4bac7e f5a2fdaf6a2b96b7 " ..
		"f0228ba8086abc51"
function M.self_test(synth)
	local grains = M.grains(synth)
	local hashes = {}
	for _, s in ipairs({0, 4, 8}) do
		local r = M.new(synth, grains, 1)
		r:render(s, true)
		r:render(s, true)
		hashes[#hashes + 1] = r.out:hash()
	end
	local rates = {}
	for _, s in ipairs({4, 8}) do
		local r = M.new(synth, grains, 3)
		local hits, n = 0, math.floor(2 * M.RATE / M.CHUNK) -- 2 s
		for _ = 1, n do
			hits = hits + r:render(s, true)
		end
		local want = M.HITS_PER_SPEED * s * n * M.CHUNK / M.RATE
		assert(math.abs(hits - want) <= 0.1 * want, string.format(
				"board sound: %d hits at %d, want %.0f", hits, s, want))
		rates[#rates + 1] = hits
		-- Up: one chunk to ramp out and the last hits' tails
		for _ = 1, 1 + math.ceil(GRAIN / M.CHUNK) do
			r:render(s, false)
		end
		for _ = 1, 3 do
			r:render(s, false)
			for i = 0, M.CHUNK - 1 do
				assert(r.out:get(i) == 0, "board sound: the air not silent")
			end
		end
		hashes[#hashes + 1] = r.out:hash()
	end
	local got = table.concat(hashes, " ")
	assert(got == M.HASHES,
			"board sound: the hashes " .. got .. ", committed " ..
			tostring(M.HASHES))
	-- [SKELDAT_BOARD_SOUND_FAULT] The seams: the roar alone (no hits) over
	-- 200 chunks, the largest step between two chunks within 1.5 times the
	-- largest inside one
	local seams = {}
	local hit_gain = M.HIT_GAIN
	M.HIT_GAIN = 0
	local ok, err = pcall(function()
		for _, s in ipairs({4, 8}) do
			local r = M.new(synth, grains, 5)
			local inner, seam, last = 0, 0, nil
			for c = 1, 200 do
				r:render(s, true)
				local o = r.out
				if c > 2 then
					seam = math.max(seam, math.abs(o:get(0) - last))
				end
				for i = 1, M.CHUNK - 1 do
					inner = math.max(inner, math.abs(o:get(i) - o:get(i - 1)))
				end
				last = o:get(M.CHUNK - 1)
			end
			seams[#seams + 1] = string.format("%.2f", seam / inner)
			assert(seam <= 1.5 * inner, string.format("board sound: a seam's "
					.. "step %.4f at %d, inside a chunk %.4f", seam, s, inner))
		end
	end)
	M.HIT_GAIN = hit_gain
	assert(ok, err)
	-- [SKELDAT_SPLASH_TAKES] Each take's onset: an RMS over a tenth of the
	-- ramp (25 ms at least: noise under 300 Hz swings over 10 ms more than
	-- its rise) reaching 90% of its peak at the ramp (+-20%) at 1 and 10
	-- voxels a second; b's and c's energy between 500 Hz and 2 kHz under
	-- 30% of the whole, f's between a's and c's ([SKELDAT_SPLASH_RETAKE]);
	-- the pick's hashes at 3 a second. Every figure first, then the
	-- failures together
	local onsets, mids, share_of, bad = {}, {}, {}, {}
	for _, take in ipairs(M.SPLASH_TAKES) do
		for _, speed in ipairs({1, 10}) do
			local ramp = M.splash_ramp(speed)
			local b = M.splash(synth, take, 1, ramp, false)
			local W = math.max(551, math.floor(ramp / 10 * M.RATE))
			local rms, peak = {}, 0
			for w = 0, math.floor((b:len() - W) / 110) do
				local e = 0
				for i = w * 110, w * 110 + W - 1 do
					e = e + b:get(i) ^ 2
				end
				rms[w] = math.sqrt(e / W)
				peak = math.max(peak, rms[w])
			end
			local at = 0
			for w = 0, #rms do
				if rms[w] >= 0.9 * peak then
					at = (w * 110 + W / 2) / M.RATE
					break
				end
			end
			onsets[#onsets + 1] = string.format("%s %.2f", take, at)
			if math.abs(at - ramp) > 0.2 * ramp then
				bad[#bad + 1] = string.format("take %s's onset at %.3f s, "
						.. "the ramp %.2f", take, at, ramp)
			end
		end
		if take == "a" or take == "b" or take == "c" or take == "f" then
			local b = M.splash(synth, take, 1, M.splash_ramp(3), false)
			local band = synth.buffer(b:len())
			band:mix(b, 0, 0, b:len(), 1)
			for _ = 1, 2 do
				band:filter{type = "high", cutoff = 500, resonance = 0,
						rate = M.RATE}
				band:filter{type = "low", cutoff = 2000, resonance = 0,
						rate = M.RATE}
			end
			local share = energy(band) / energy(b)
			mids[#mids + 1] = string.format("%s %.2f", take, share)
			share_of[take] = share
			if (take == "b" or take == "c") and share >= 0.3 then
				bad[#bad + 1] = string.format("take %s's mids %.2f of its "
						.. "energy", take, share)
			end
		end
	end
	local lo = math.min(share_of.a, share_of.c)
	local hi = math.max(share_of.a, share_of.c)
	if share_of.f <= lo or share_of.f >= hi then
		bad[#bad + 1] = string.format("take f's mids %.2f, not between a's "
				.. "and c's", share_of.f)
	end
	assert(#bad == 0, "board sound: " .. table.concat(bad, "; ") ..
			" (onsets " .. table.concat(onsets, ", ") .. ", mids " ..
			table.concat(mids, ", ") .. ")")
	-- [SKELDAT_SPLASH_F] At 10 a second f is as it was (noise 1); at 1 its
	-- energy under 300 Hz and over 3 kHz (the noise's) the noise figure
	-- squared of the whole's, +-20%, and the bubbles' band kept: what
	-- the noise left of it there within 1%. simplified: the bubbles are
	-- read in their band, not rendered alone
	do
		local r10 = M.splash_ramp(10)
		assert(M.splash(synth, "f", 1, r10, false, M.splash_noise(10)):hash()
				== M.splash(synth, "f", 1, r10, false):hash(),
				"board sound: f at 10 a second not as it was")
		local r1, n1 = M.splash_ramp(1), M.splash_noise(1)
		local was = M.splash(synth, "f", 1, r1, false)
		local now = M.splash(synth, "f", 1, r1, false, n1)
		local function band(b, lo, hi)
			local c = synth.buffer(b:len())
			c:mix(b, 0, 0, b:len(), 1)
			for _ = 1, 2 do
				if hi then
					c:filter{type = "low", cutoff = hi, resonance = 0, rate = M.RATE}
				end
				if lo then
					c:filter{type = "high", cutoff = lo, resonance = 0, rate = M.RATE}
				end
			end
			return energy(c)
		end
		local k = (band(now, nil, 300) + band(now, 3000, nil)) /
				(band(was, nil, 300) + band(was, 3000, nil))
		assert(k > 0.8 * n1 * n1 and k < 1.2 * n1 * n1, string.format(
				"board sound: f's noise at 1 a second %.3f of it, want %.3f",
				k, n1 * n1))
	end
	local splash = {}
	for _, hard in ipairs({false, true}) do
		for v = 1, 4 do
			splash[#splash + 1] = M.splash(synth, M.SPLASH_TAKE, v,
					M.splash_ramp(3), hard, M.splash_noise(3)):hash()
		end
	end
	splash = table.concat(splash, " ")
	assert(splash == M.SPLASH_HASHES, "board sound: the splashes' hashes " ..
			splash .. ", committed " .. tostring(M.SPLASH_HASHES))
	return string.format("board sound: self test passed, %d and %d hits "
			.. "in 2 s at 4 and 8, the seams %s of the steps inside, the "
			.. "splashes' onsets %s, mids %s, hashes %s",
			rates[1], rates[2], table.concat(seams, " and "),
			table.concat(onsets, ", "), table.concat(mids, ", "), got)
end

return M
