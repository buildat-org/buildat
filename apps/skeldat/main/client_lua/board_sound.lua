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
--   r:render(s, on_ground, brake) -- -> hits; the chunk in r.out[0, CHUNK)
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
M.SCRAPE_GAIN = 0.2
local GRAIN = 441 -- 20 ms
local PRE = 220 -- a filter's settling, cut off the front
local CLACK_GAP = 331 -- 15 ms

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
-- fast decay; and the jump's thud
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
	local thud = synth.buffer(GRAIN * 3)
	thud:osc{wave = "sine", freq = {start = 110, mul = 0.05}, rate = R}
	thud:envelope{points = {{0, 1}, {0.06, 0}}, rate = R}
	g.thud = thud
	return g
end

-- [SKELDAT_BOARD_WATER] The splash, on foot or on the board: 4 variants
-- (a seed each), soft and hard (the spray and the thump louder), each 0.6
-- s. [SKELDAT_SPLASH_NOISE] Mostly noise: the spray (noise low-passed
-- from 4 kHz to 600 Hz) and a hiss over 3 kHz at the front; the body's
-- thump (noise low-passed at 250 Hz, a falling sine under it); 8 short
-- bubbles (a sine and its band of noise, half each, barely rising); 4 to
-- 8 droplets (bursts of band noise) over 0.1 to 0.6 s.
-- -> {soft = {4 buffers}, hard = {4 buffers}, ratio = {soft = {4}, hard =
-- {4}}: the noise layers' energy over the tones', before the normalising}
-- simplified: the figures are first guesses, to tune by ear; the
-- droplets' band stops at the filter's 4.4 kHz (a fifth of the rate)
local SPLASH = math.floor(0.6 * M.RATE)
local function energy(b)
	local e = 0
	for i = 0, b:len() - 1 do
		e = e + b:get(i) ^ 2
	end
	return e
end
function M.splashes(synth)
	local R = M.RATE
	local out = {soft = {}, hard = {}, ratio = {soft = {}, hard = {}}}
	for v = 1, 4 do
		local rnd = v * 7919
		local function rand()
			rnd = (rnd * 1103515245 + 12345) % 2147483648
			return rnd / 2147483648
		end
		local seed = 2000 + 100 * v
		local function noise(b, from, n)
			seed = seed + 1
			b:noise{kind = "white", seed = seed, rate = R, from = from, n = n}
		end
		local spray, hiss, thump = synth.buffer(SPLASH), synth.buffer(SPLASH),
				synth.buffer(SPLASH)
		noise(spray)
		spray:filter{type = "low", cutoff = {start = 4000, slide = -5700,
				min = 600}, resonance = 0, rate = R}
		spray:envelope{points = {{0, 0}, {0.01, 1}, {0.6, 0}}, rate = R}
		noise(hiss)
		hiss:filter{type = "high", cutoff = 3000, resonance = 0, rate = R}
		hiss:envelope{points = {{0, 1}, {0.15, 0}}, rate = R}
		local n = math.floor(0.06 * R)
		noise(thump, 0, n)
		thump:filter{type = "low", cutoff = 250, resonance = 0, rate = R, n = n}
		thump:envelope{points = {{0, 1}, {0.05, 0}}, rate = R, n = n}
		local tone, noisy = synth.buffer(SPLASH), synth.buffer(SPLASH)
		local t = synth.buffer(SPLASH)
		t:osc{wave = "sine", freq = {start = 130 + 15 * v, mul = 0.02},
				rate = R, n = n}
		t:envelope{points = {{0, 1}, {0.06, 0}}, rate = R, n = n}
		tone:mix(t, 0, 0, n, 0.15)
		for _ = 1, 8 do
			local len = 0.005 + 0.01 * rand()
			local k = math.floor(len * R)
			local f = 1000 + 3000 * rand()
			local at = math.floor(rand() * 0.3 * R)
			t:osc{wave = "sine", freq = {start = f,
					slide = f * (0.05 + 0.1 * rand()) / len}, rate = R, n = k}
			t:envelope{points = {{0, 1}, {len, 0}}, rate = R, n = k}
			tone:mix(t, 0, at, k, 0.05)
			noise(t, 0, k)
			t:filter{type = "band", cutoff = f, resonance = 0.7, rate = R, n = k}
			t:envelope{points = {{0, 1}, {len, 0}}, rate = R, n = k}
			noisy:mix(t, 0, at, k, 0.05)
		end
		for _ = 1, 4 + math.floor(rand() * 5) do
			local len = 0.005 + 0.005 * rand()
			local k = math.floor(len * R)
			noise(t, 0, k)
			t:filter{type = "band", cutoff = 1500 + 2900 * rand(),
					resonance = 0.5, rate = R, n = k}
			t:envelope{points = {{0, 1}, {len, 0}}, rate = R, n = k}
			noisy:mix(t, 0, math.min(SPLASH - k,
					math.floor((0.1 + 0.5 * rand()) * R)), k, 0.15)
		end
		for kind, loud in pairs({soft = 1, hard = 1.5}) do
			local b = synth.buffer(SPLASH)
			b:mix(noisy, 0, 0, SPLASH, 1)
			b:mix(spray, 0, 0, SPLASH, loud)
			b:mix(hiss, 0, 0, SPLASH, 0.3)
			b:mix(thump, 0, 0, n, 0.6 * loud)
			out.ratio[kind][v] = energy(b) / math.max(1e-12, energy(tone))
			b:mix(tone, 0, 0, SPLASH, 1)
			normalise(b)
			out[kind][v] = b
		end
	end
	return out
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
		level = 0, scrape = 0, next_hit = 0, raw = {},
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
	function r:render(s, on_ground, brake)
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
		local scrape = (on_ground and brake) and math.min(1, s / M.TOP) or 0
		if self.scrape > 0 or scrape > 0 then
			self.acc:mix(self:filtered("band", 2000 + 250 * math.min(s, 8)),
					PRE, 0, N, M.SCRAPE_GAIN * self.scrape,
					M.SCRAPE_GAIN * scrape)
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
		self.level, self.scrape = level, scrape
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
	-- The pop and the clack out of the queue ([SKELDAT_BOARD_SOUND_LAG]):
	-- Sounds made once, played when they happen, behind the device only
	if not grains.pop_sound then
		local n = grains.thud:len()
		local pop, clack = synth.buffer(n), synth.buffer(n)
		pop:mix(grains[1], 0, 0, GRAIN, 2 * M.HIT_GAIN)
		pop:mix(grains.thud, 0, 0, n, 0.5)
		clack:mix(grains[2], 0, 0, GRAIN, 2 * M.HIT_GAIN)
		clack:mix(grains[3], 0, CLACK_GAP, GRAIN, 2 * M.HIT_GAIN)
		grains.pop_sound, grains.clack_sound = M.to_sound(magic, pop),
				M.to_sound(magic, clack)
	end
	local shot = node:CreateComponent(kind)
	shot.soundType = magic.SOUND_EFFECT
	function p:pop()
		shot.gain = 1
		shot:Play(grains.pop_sound)
	end
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
	function p:feed(s, on_ground, brake)
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
			self:render(s, on_ground, brake)
			self.out:to_shorts(self.vb, 0, M.CHUNK)
			self.stream:AddData(self.vb)
			guard = guard + 1
			len = self.stream.bufferLength
		end
		return len
	end
	-- Off the board: the next ride ramps in from silence
	function p:rest()
		self.level, self.scrape, fed = 0, 0, false
	end
	return p
end

-- The self-check: chunks at fixed seeds hashed against the committed
-- figures (the blocks are the same everywhere, src/lua_bindings/synth.cpp),
-- the hits a second within 10% of 25 s, and the air silent; and the
-- splashes' (SPLASH_HASHES, soft 1..4 then hard 1..4).
-- -> a line for the log; raises on a failure
-- At s 0, 4 and 8, then the two air runs' last chunks; 0 and the air are
-- the silent chunk's hash
M.HASHES = "02cfd07dc33f6da3 830566adb5d45b54 1406c9e09c71c22c " ..
		"02cfd07dc33f6da3 02cfd07dc33f6da3"
M.SPLASH_HASHES = "cbe50032a8c5a3d1 9e2e6ecc44aadd45 9b8f551c845b74b9 " ..
		"9725ca98b1d9e1f3 ebdf70e8c2806398 5e05b72237f62b2c 2216079b41d76eb5 " ..
		"e199da12b377d312"
function M.self_test(synth)
	local grains = M.grains(synth)
	local hashes = {}
	for _, s in ipairs({0, 4, 8}) do
		local r = M.new(synth, grains, 1)
		r:render(s, true, false)
		r:render(s, true, false)
		hashes[#hashes + 1] = r.out:hash()
	end
	local rates = {}
	for _, s in ipairs({4, 8}) do
		local r = M.new(synth, grains, 3)
		local hits, n = 0, math.floor(2 * M.RATE / M.CHUNK) -- 2 s
		for _ = 1, n do
			hits = hits + r:render(s, true, false)
		end
		local want = M.HITS_PER_SPEED * s * n * M.CHUNK / M.RATE
		assert(math.abs(hits - want) <= 0.1 * want, string.format(
				"board sound: %d hits at %d, want %.0f", hits, s, want))
		rates[#rates + 1] = hits
		-- Up: one chunk to ramp out and the last hits' tails
		for _ = 1, 1 + math.ceil(GRAIN / M.CHUNK) do
			r:render(s, false, false)
		end
		for _ = 1, 3 do
			r:render(s, false, false)
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
				r:render(s, true, false)
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
	local sp, splash = M.splashes(synth), {}
	for _, kind in ipairs({"soft", "hard"}) do
		for v = 1, 4 do
			splash[#splash + 1] = sp[kind][v]:hash()
		end
	end
	splash = table.concat(splash, " ")
	-- [SKELDAT_SPLASH_NOISE] Mostly noise: 3 times the tones' energy
	local least = math.huge
	for _, kind in ipairs({"soft", "hard"}) do
		for v = 1, 4 do
			least = math.min(least, sp.ratio[kind][v])
		end
	end
	assert(least >= 3, string.format("board sound: a splash's noise only "
			.. "%.1f times its tones' energy", least))
	assert(splash == M.SPLASH_HASHES, "board sound: the splashes' hashes " ..
			splash .. ", committed " .. tostring(M.SPLASH_HASHES))
	return string.format("board sound: self test passed, %d and %d hits "
			.. "in 2 s at 4 and 8, the seams %s of the steps inside, the "
			.. "splashes' noise at least %.0f times the tones, hashes %s",
			rates[1], rates[2], table.concat(seams, " and "), least, got)
end

return M
