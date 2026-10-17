-- Buildat: apps/skeldat/main/client_lua/music.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- skelenti's music ([SKELENTI_SOUNDS]), copied: three moods, two takes of
-- 48 s each, made in Lua sample by sample (the first options round's sfx.lua,
-- picked whole by the user, 2026-10-15). A take is made when its mood is
-- first wanted, a slice a frame -- the sandbox has no coroutine.yield, so
-- each recipe queues its voices as jobs and pump() runs them -- then
-- played looped on a Music source; a mood's two takes alternate, each
-- starting as the other fades out. update(dt, mood) is the whole of it.
local M = {}
local RATE = 22050
local LEN = 48
-- Each take fades in and out over its first and last 4 s, so the next
-- one starts this far before the end
local OVERLAP = 4
local SLICE_US = 3000 -- the making's time a frame, in 2000-sample steps
local FADE = 3 -- s, a mood's music going out
local sin, exp, pi, floor = math.sin, math.exp, math.pi, math.floor
local TAU = 2 * pi

-- A noise of its own, so a take is the same every time
local seed = 1
local function rnd()
	seed = (seed * 1103515245 + 12345) % 2147483648
	return seed / 2147483648
end
local function noise() return rnd() * 2 - 1 end

-- One pole each way, and a state-variable band pass
local function lowpass(hz)
	local a, y = 1 - exp(-TAU * hz / RATE), 0
	return function(x) y = y + a * (x - y) return y end
end
local function bandpass(hz, q)
	local f = 2 * sin(pi * hz / RATE)
	local low, band = 0, 0
	return function(x)
		low = low + f * band
		local high = x - low - band / q
		band = band + f * high
		return band
	end
end

-- The take being made: its samples and its queued jobs
local out, jobs
-- A voice into out from t0 (s): fn(i, t) per sample for dur seconds
local function add(t0, dur, fn)
	jobs[#jobs + 1] = {s0 = floor(t0 * RATE), n = floor(dur * RATE), i = 0,
		fn = fn}
end
-- A feedback echo over the whole take, after the voices
local function echo(delay, feedback, mix)
	local d = floor(delay * RATE)
	jobs[#jobs + 1] = {s0 = 0, n = #out - d, i = 0, echo = true,
		fn = function(i)
			local k = i + d + 1
			out[k] = out[k] + out[k - d] * feedback * mix
		end}
end

local function hz(semis) return 220 * 2 ^ (semis / 12) end
-- A sine sweeping from f0 to f1 over dur, decaying by tau (s)
local function blip(t0, dur, f0, f1, tau, gain)
	local ph = 0
	add(t0, dur, function(_, t)
		ph = ph + TAU * (f0 + (f1 - f0) * t / dur) / RATE
		return sin(ph) * exp(-t / tau) * gain * math.min(1, t * 400)
	end)
end
-- Noise through a filter, decaying by tau
local function burst(t0, dur, filter, tau, gain)
	add(t0, dur, function(_, t)
		return filter(noise()) * exp(-t / tau) * gain * math.min(1, t * 1000)
	end)
end
-- A struck resonance: a click into a band pass
local function knock(t0, f, q, tau, gain)
	local bp = bandpass(f, q)
	add(t0, tau * 6, function(i, t)
		return bp(i < 20 and noise() or 0) * exp(-t / tau) * gain
	end)
end
local function clacks(t0, n, span, gain)
	for _ = 1, n do
		knock(t0 + rnd() * span, 1500 + rnd() * 1500, 14, 0.008,
				gain * (0.5 + rnd() * 0.5))
	end
end
-- A slow pad chord: sines detuned in pairs, swelling in and out
local function pad(t0, dur, notes, gain, bright)
	for _, n in ipairs(notes) do
		for _, det in ipairs({-0.003, 0.003}) do
			local f = hz(n) * (1 + det)
			add(t0, dur, function(_, t)
				local env = math.min(1, t / 2.5) * math.min(1, (dur - t) / 2.5)
				local s = sin(TAU * f * t)
				if bright then s = s + 0.25 * sin(TAU * 2 * f * t) end
				return s * env * gain
			end)
		end
	end
end
local function bell(t0, n, gain, tau)
	local f = hz(n)
	tau = tau or 1.2
	add(t0, tau * 4, function(_, t)
		return (sin(TAU * f * t) + 0.3 * sin(TAU * 2.76 * f * t) *
				exp(-t / 0.3)) * exp(-t / tau) * gain * math.min(1, t * 300)
	end)
end
local function drone(notes, gain, wobble)
	for _, n in ipairs(notes) do
		local f = hz(n)
		local lp = lowpass(400)
		local ph = 0
		add(0, LEN, function(_, t)
			local env = math.min(1, t / 4) * math.min(1, (LEN - t) / 4)
			ph = (ph + f * (1 + wobble * sin(TAU * 0.07 * t)) / RATE) % 1
			return lp(ph * 2 - 1) * env * gain
		end)
	end
end

local TAKES = {sunrise = {}, danger = {}, caves = {}}
TAKES.sunrise[1] = function() -- warm chords, a slow arpeggio of bells
	local chords = {{-9, -5, -2, 2}, {-4, 0, 3, 7}, {-7, -3, 0, 5},
		{-5, -1, 2, 7}}
	for i = 0, 3 do pad(i * 12, 14, chords[i + 1], 0.03, true) end
	local scale = {3, 7, 10, 14, 15, 19}
	for b = 0, 47, 1.5 do
		if rnd() < 0.7 then
			bell(b, scale[floor(rnd() * #scale) + 1], 0.07, 1.5)
		end
	end
end
TAKES.sunrise[2] = function() -- a drone, a flute-like tune over it
	drone({-12, -5}, 0.05, 0.002)
	local tune = {7, 10, 12, 14, 12, 10, 7, 5, 7, 3, 2, 3, 5, 7}
	local t = 2
	for i, n in ipairs(tune) do
		local d = (i % 4 == 0) and 3.2 or 1.6
		local f = hz(n + 12)
		add(t, d, function(_, tt)
			local env = math.min(1, tt / 0.15) * math.min(1, (d - tt) / 0.4)
			return (sin(TAU * f * tt + 0.3 * sin(TAU * 5 * tt)) +
					0.05 * noise()) * env * 0.07
		end)
		t = t + d
		if t > 44 then break end
	end
	echo(0.42, 0.35, 1)
end
TAKES.danger[1] = function() -- a low tritone and a heartbeat
	drone({-24, -18}, 0.07, 0.004)
	for b = 1, 47, 0.9 do
		blip(b, 0.15, 60, 45, 0.05, 0.25)
		blip(b + 0.22, 0.15, 55, 42, 0.05, 0.18)
	end
end
TAKES.danger[2] = function() -- a sour pad, wind, bones far off
	for i = 0, 3 do pad(i * 12, 14, {-13, -12, -6, -1}, 0.022, false) end
	local bp = bandpass(600, 1.2)
	add(0, LEN, function(_, t)
		return bp(noise()) * (0.5 + 0.5 * sin(TAU * 0.05 * t)) * 0.12 *
				math.min(1, t / 3)
	end)
	for _ = 1, 9 do clacks(2 + rnd() * 44, 3, 0.15, 0.12) end
	echo(0.31, 0.4, 1)
end
TAKES.caves[1] = function() -- drips in a big space over a deep drone
	drone({-29}, 0.08, 0.001)
	for _ = 1, 40 do
		local t = rnd() * 46
		blip(t, 0.08, 1400 + rnd() * 1600, 2200 + rnd() * 1200, 0.015, 0.2)
	end
	echo(0.37, 0.55, 1)
end
TAKES.caves[2] = function() -- low tones that hang, a rumble now and then
	local notes = {-17, -14, -10, -12, -19, -17}
	for i, n in ipairs(notes) do bell((i - 1) * 8, n, 0.12, 3.5) end
	for _ = 1, 4 do burst(rnd() * 44, 3, lowpass(90), 1.0, 0.5) end
	echo(0.53, 0.5, 1)
end
M.TAKES = TAKES

-- Runs up to budget samples of the queued jobs. -> whether all are done
local function pump(budget)
	while jobs[1] and budget > 0 do
		local j = jobs[1]
		local stop = math.min(j.n, j.i + budget)
		local fn, s0, rate = j.fn, j.s0, RATE
		if j.echo then
			for i = j.i, stop - 1 do fn(i) end
		else
			for i = j.i, stop - 1 do
				local k = s0 + i + 1
				local x = fn(i, i / rate)
				if out[k] then out[k] = out[k] + x end
			end
		end
		budget = budget - (stop - j.i)
		j.i = stop
		if stop >= j.n then table.remove(jobs, 1) end
	end
	return jobs[1] == nil
end

-- The Sound of a finished take, normalised to a peak of -1 dBFS (the
-- first round's level; the source's gain sets the music's)
local function to_sound(magic)
	local peak = 0
	for i = 1, #out do peak = math.max(peak, math.abs(out[i])) end
	local g = 0.89 * 32767 / math.max(peak, 1e-9)
	for i = 1, #out do out[i] = out[i] * g end
	local buf = magic.VectorBuffer:new()
	buildat.write_shorts(buf, out)
	local sound = magic.Sound:new()
	sound:SetFormat(RATE, true, false)
	sound:SetData(buf)
	return sound
end

-- The state: made[mood][take] = Sound; making = {mood, take} in progress;
-- playing = {mood, take, source, t, gain}, the newest last
local made = {sunrise = {}, danger = {}, caves = {}}
local making
local playing = {}
local scene
M.GAIN = 0.35

-- scene: where the sources' nodes go (a source outside one is not heard)
function M.new(magic, log, the_scene)
	M.magic, M.log, scene = magic, log, the_scene
end

-- The next take to make: the wanted mood's first, then its second
local function want_made(mood)
	for k = 1, 2 do
		if not made[mood][k] then return k end
	end
end

local function start(mood, take)
	local node = scene:CreateChild("music")
	local src = node:CreateComponent("SoundSource")
	src.soundType = "Music"
	src.gain = 0
	src:Play(made[mood][take])
	playing[#playing + 1] = {mood = mood, take = take, node = node,
		source = src, t = 0, gain = 0}
	M.log:info(string.format("skeldat: music %s %s", mood,
			take == 1 and "a" or "b"))
end

-- mood: "sunrise", "danger", "caves" or nil for none
function M.update(dt, mood)
	-- Make what the mood needs, a slice a frame
	if not making and mood then
		local k = want_made(mood)
		if k then
			seed, out, jobs = 1, {}, {}
			for i = 1, LEN * RATE do out[i] = 0 end
			TAKES[mood][k]()
			making = {mood = mood, take = k, t0 = buildat.get_time_us()}
		end
	end
	local until_us = buildat.get_time_us() + SLICE_US
	local done = false
	while making and not done and buildat.get_time_us() < until_us do
		done = pump(2000)
	end
	if making and done then
		made[making.mood][making.take] = to_sound(M.magic)
		M.log:info(string.format("skeldat: music %s %s made in %.1f s",
				making.mood, making.take == 1 and "a" or "b",
				(buildat.get_time_us() - making.t0) / 1e6))
		out, jobs, making = nil, nil, nil
	end
	-- The newest of the mood keeps going: the other take when it nears
	-- its end (or the same one while the other is being made)
	local last = playing[#playing]
	if mood and made[mood][1] and (not last or last.mood ~= mood or
			last.t >= LEN - OVERLAP and not last.next_started) then
		if last and last.mood == mood then
			last.next_started = true
		end
		local k = (last and last.mood == mood) and (last.take % 2 + 1) or 1
		start(mood, made[mood][k] and k or 1)
	end
	-- Each one up to its gain, or down and gone once it is not the
	-- mood's newest; a take that has ended is gone too
	for i = #playing, 1, -1 do
		local p = playing[i]
		p.t = p.t + dt
		local newest = i == #playing and p.mood == mood
		local current = newest or (p.mood == mood and p.t < LEN)
		p.gain = current and math.min(1, p.gain + dt / FADE) or
				math.max(0, p.gain - dt / FADE)
		if p.t >= LEN or (p.gain <= 0 and not current) then
			p.source:Stop()
			p.node:Remove()
			table.remove(playing, i)
		else
			p.source.gain = p.gain * M.GAIN
		end
	end
end

return M
