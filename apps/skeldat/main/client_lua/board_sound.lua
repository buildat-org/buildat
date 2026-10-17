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
-- chunks, fed while the stream holds under 30 ms (above a 60 Hz frame's
-- 17 with room for a slow one), into a source buffer of 30 ms (STREAM_MS)
-- simplified: AHEAD a constant to raise if the underruns logged say so
M.CHUNK = 221 -- 10 ms
M.AHEAD = 0.03
M.STREAM_MS = 30
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
-- (a seed each), soft and hard (the plop and the spray louder), each 0.6 s
-- of the body's plop (a falling sine), the spray (noise low-passed from 3
-- kHz to 400 Hz) and 20 bubbles (rising sine chirps over the first 0.3 s).
-- -> {soft = {4 buffers}, hard = {4 buffers}}
-- simplified: the figures are first guesses, to tune by ear
local SPLASH = math.floor(0.6 * M.RATE)
function M.splashes(synth)
	local R = M.RATE
	local out = {soft = {}, hard = {}}
	for v = 1, 4 do
		local rnd = v * 7919
		local function rand()
			rnd = (rnd * 1103515245 + 12345) % 2147483648
			return rnd / 2147483648
		end
		local plop, spray = synth.buffer(SPLASH), synth.buffer(SPLASH)
		local n = math.floor(0.06 * R)
		plop:osc{wave = "sine", freq = {start = 130 + 15 * v, mul = 0.02},
				rate = R, n = n}
		plop:envelope{points = {{0, 1}, {0.06, 0}}, rate = R, n = n}
		spray:noise{kind = "white", seed = 2000 + v, rate = R}
		spray:filter{type = "low", cutoff = {start = 3000, slide = -6500,
				min = 400}, resonance = 0, rate = R}
		spray:envelope{points = {{0, 0}, {0.01, 1}, {0.5, 0}}, rate = R}
		local bubbles, chirp = synth.buffer(SPLASH), synth.buffer(SPLASH)
		for _ = 1, 20 do
			local len = (0.02 + 0.04 * rand())
			local k = math.floor(len * R)
			local f = 400 + 2600 * rand()
			chirp:osc{wave = "sine", freq = {start = f,
					slide = f * (0.2 + 0.3 * rand()) / len}, rate = R, n = k}
			chirp:envelope{points = {{0, 1}, {len, 0}}, rate = R, n = k}
			bubbles:mix(chirp, 0, math.floor(rand() * 0.3 * R), k, 0.3)
		end
		for kind, loud in pairs({soft = 1, hard = 2}) do
			local b = synth.buffer(SPLASH)
			b:mix(plop, 0, 0, n, 0.8 * loud)
			b:mix(spray, 0, 0, SPLASH, 0.4 * loud)
			b:mix(bubbles, 0, 0, SPLASH, 1)
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
		level = 0, scrape = 0, next_hit = 0,
		acc = synth.buffer(M.CHUNK + GRAIN),
		spare = synth.buffer(M.CHUNK + GRAIN),
		noise = synth.buffer(M.CHUNK + PRE)}
	r.out = r.acc
	function r:rand()
		self.rnd = (self.rnd * 1103515245 + 12345) % 2147483648
		return self.rnd / 2147483648
	end
	function r:filtered(type, cutoff)
		self.noise_seed = self.noise_seed % 4294967291 + 1
		self.noise:noise{kind = "white", seed = self.noise_seed, rate = M.RATE}
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
	source.streamBufferLength = M.STREAM_MS
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
	local underruns, said_t, fed = 0, buildat.get_time_us(), false
	-- -> the stream's length after it, s
	function p:feed(s, on_ground, brake)
		local guard = 0
		if fed and self.stream.bufferLength <= 0 then
			underruns = underruns + 1
		end
		fed = true
		local now = buildat.get_time_us()
		if log and now - said_t >= 60e6 then
			if underruns > 0 then
				log:info(string.format("skeldat: board sound: %d underruns "
						.. "this last minute", underruns))
			end
			underruns, said_t = 0, now
		end
		while self.stream.bufferLength < M.AHEAD and guard < 16 do
			self:render(s, on_ground, brake)
			self.out:to_shorts(self.vb, 0, M.CHUNK)
			self.stream:AddData(self.vb)
			guard = guard + 1
		end
		return self.stream.bufferLength
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
M.HASHES = "02cfd07dc33f6da3 d2fb62e9ce11b347 95b0afcb487297a5 " ..
		"02cfd07dc33f6da3 02cfd07dc33f6da3"
M.SPLASH_HASHES = "085d7de7da131b7d 31ebb910b1815737 1fd16cff43a8764b " ..
		"8b5536f8b417ffc6 5cc0da446564836a d9d78cce94d09c41 f07cb5ae5cd878e1 " ..
		"b811c6c15f4f5af6"
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
	local sp, splash = M.splashes(synth), {}
	for _, kind in ipairs({"soft", "hard"}) do
		for v = 1, 4 do
			splash[#splash + 1] = sp[kind][v]:hash()
		end
	end
	splash = table.concat(splash, " ")
	assert(splash == M.SPLASH_HASHES, "board sound: the splashes' hashes " ..
			splash .. ", committed " .. tostring(M.SPLASH_HASHES))
	return string.format("board sound: self test passed, %d and %d hits "
			.. "in 2 s at 4 and 8, hashes %s", rates[1], rates[2], got)
end

return M
