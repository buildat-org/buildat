-- Brimstone Speedway's music on this client: a 12-bar boogie in A (I I I I
-- IV IV I I V IV I V), swung eighths, three parts each a blip1 sound a bar
-- long (its notes as layers: blip1's 16 at offsets): a boogie bass line, a
-- two-note rhythm guitar (plucked) and the drums (kick, snare, hats). A
-- bar's three are added to one blip stream together, so they stay in time
-- with each other; each bar is added when its start is under 0.25 s away,
-- `at` the time left less the mixer's lead (0.1 s), so a bar can start up to
-- a mixer block (23 ms) off the beat. The mood (the player's own: lobby the
-- bass and quiet drums, race all of it, off nothing) is read at each bar.
-- simplified: the bar grid is this client's own clock from its first frame,
-- not the shared time: two players hear the loop at different places.
local blip = require("buildat/extension/blip")
local RATE = 44100
local A, D, E = 110, 146.83, 164.81
local PROG = {A, A, A, A, D, D, A, A, E, D, A, E}
-- (a 12-bar's semitones: the boogie's root, 3rd, 5th, 6th, flat 7th)
local BASS = {0, 4, 7, 9, 10, 9, 7, 4}
local m = {}

local function bf(hz)
	return math.sqrt(hz / 3528 - 0.001)
end

local function semi(hz, s)
	return hz * 2 ^ (s / 12)
end

-- A bar's sound: its first note the table itself, the rest its layers
local function bar(notes)
	local first = notes[1]
	-- (the first is at 0: blip1 takes no `at` on the sound itself)
	first.at = nil
	first.layers = {}
	for i = 2, #notes do
		first.layers[#first.layers + 1] = notes[i]
	end
	return first
end

-- The eighths' starts, swung (the off-beat two thirds into the beat)
local function eighths(beat)
	local t = {}
	for k = 0, 3 do
		t[#t + 1] = k * beat
		t[#t + 1] = k * beat + beat * 2 / 3
	end
	return t
end

local function bass_bar(root, beat)
	local notes = {}
	for i, at in ipairs(eighths(beat)) do
		notes[i] = {wave = "saw", base_freq = bf(semi(root, BASS[i])), at = at,
			env_attack = 0, env_sustain = 0.28, env_decay = 0.22, env_punch = 0.2,
			lpf_freq = 0.42, lpf_resonance = 0.3, volume = 0.55}
	end
	return bar(notes)
end

local function guitar_bar(root, beat)
	local notes = {}
	for i, at in ipairs(eighths(beat)) do
		local top = i % 2 == 1 and 7 or 9
		for _, s in ipairs({0, top}) do
			notes[#notes + 1] = {wave = "square", duty = 0.4,
				base_freq = bf(semi(root * 2, s)), at = at, pluck = 0.85,
				env_attack = 0, env_sustain = 0.25, env_decay = 0.2,
				lpf_freq = 0.55, volume = 0.3}
		end
	end
	return bar(notes)
end

local function drum_bar(beat)
	local notes = {}
	for k = 0, 3 do
		if k % 2 == 0 then
			notes[#notes + 1] = {wave = "sine", base_freq = bf(130), at = k * beat,
				freq_ramp = -0.35, env_sustain = 0.08, env_decay = 0.3,
				env_punch = 0.6, volume = 0.9}
		else
			notes[#notes + 1] = {wave = "noise", base_freq = 0.55, at = k * beat,
				env_sustain = 0.05, env_decay = 0.24, env_punch = 0.3,
				hpf_freq = 0.12, volume = 0.45, seed = 3}
		end
	end
	for _, at in ipairs(eighths(beat)) do
		notes[#notes + 1] = {wave = "noise", base_freq = 0.95, at = at,
			env_sustain = 0, env_decay = 0.09, hpf_freq = 0.55, volume = 0.18,
			seed = 5}
	end
	return bar(notes)
end

local function made(e)
	local tempo = tonumber(e.state.tempo) or 168
	local beat = 60 / math.max(60, math.min(260, tempo))
	if m.tempo == tempo then
		return
	end
	m.tempo, m.beat, m.len = tempo, beat, beat * 4
	m.bass, m.guitar = {}, {}
	for _, root in ipairs({A, D, E}) do
		m.bass[root] = bass_bar(root, beat)
		m.guitar[root] = guitar_bar(root, beat)
	end
	m.drums = drum_bar(beat)
end

return {
	on_update = function(e, dt)
		local now = buildat.get_time_us() / 1e6
		made(e)
		if not m.out then
			m.out = blip.stream{type = "Music"}
			m.next, m.k, m.late = now + 0.3, 0, {}
			e:log("brim_music: a stream, " .. string.format("%.1f", m.len * 12) ..
					" s a loop")
		end
		local vol = math.max(0, math.min(1, tonumber(e.state.volume) or 0.5))
		while m.next - now < 0.25 do
			local mood = e:shown("mood")
			mood = (mood == "race" or mood == "off") and mood or "lobby"
			local root = PROG[m.k % 12 + 1]
			local at = math.max(0, m.next - now - 0.1)
			local t0 = buildat.get_time_us()
			if mood ~= "off" and vol > 0 then
				m.out:add(m.bass[root], at, vol)
				m.out:add(m.drums, at, vol * (mood == "race" and 1 or 0.45))
				if mood == "race" then
					m.out:add(m.guitar[root], at, vol * 0.8)
				end
			end
			local us = buildat.get_time_us() - t0
			-- (what a bar cost to add: its first time its sounds made)
			if m.k < 12 or m.k % 12 == 0 then
				e:log(string.format("brim_music: bar %d (%s) %s, %.1f ms to add, %.0f ms ahead",
						m.k + 1, root == A and "A" or root == D and "D" or "E", mood,
						us / 1000, (m.next - now) * 1000))
			end
			m.k, m.next = m.k + 1, m.next + m.len
		end
	end,
	on_remove = function()
		if m.out then
			m.out.stop()
		end
		m = {}
	end,
}
