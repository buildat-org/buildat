-- Buildat: apps/blip_check/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [BLIP]'s check, run by util/blip_check.sh natively and on the web: the
-- self-check, the plays in each form, a WAV's header, and the speed
-- runner's readings. Each part logs a "blip check:" line.
local log = buildat.Logger("blip_check")
local blip = require("buildat/extension/blip")
local gen, mix = blip.gen, blip.mix
local now = buildat.get_time_us
-- What each part said, shown at the end: the launch grid lists the app
local said = {}
local function say(line)
	said[#said + 1] = line
	log:info("blip check: " .. line)
end

local ok, bad = blip.self_check()
say("self-check " .. (ok and "ok" or
		("FAILED: " .. table.concat(bad, "; "))))

-- Each form, played and cached; the log's "played" lines say each did
local compact = gen.pack(gen.preset("laser", 3))
local tbl = gen.to_table(gen.preset("jump", 4))
local both = {compact, volume = 0.2}
for _, s in ipairs({compact, tbl, both}) do
	blip.play(s, {gain = 0.5})
	blip.play_cached(s)
	blip.play_cached(s)
end
-- Layers and the parameters beyond sfxr's, in the compact form
for _, name in ipairs({"rattle", "pluck", "snort", "crunch"}) do
	blip.play(gen.pack(gen.preset(name, 2)), {gain = 0.5})
end
local stream = blip.stream()
stream:add(compact)
stream:add(tbl, 0.05, 0.5)
say("plays ok")

-- The WAV's header, read back
local w = blip.wav(compact)
local function u(at, bytes)
	local v = 0
	for i = bytes, 1, -1 do
		v = v * 256 + w:byte(at + i - 1)
	end
	return v
end
local samples = gen.chain(gen.params(compact), 44100)
assert(w:sub(1, 4) == "RIFF" and w:sub(9, 16) == "WAVEfmt " and
		w:sub(37, 40) == "data", "the WAV's tags")
assert(u(5, 4) == #w - 8 and u(41, 4) == samples * 2 and
		#w == 44 + samples * 2, "the WAV's lengths")
assert(u(21, 2) == 1 and u(23, 2) == 1 and u(25, 4) == 44100 and
		u(35, 2) == 16, "the WAV's format")
say("wav ok, " .. samples .. " samples")

-- **The speed runner**: each preset made 100 times, the chain's Lua and
-- the blocks' C++ timed apart; then the mixer's fill at 1, 8 and 32 voices
-- for 10 s of audio, on a stream that only counts (nothing is played)
local longest, longest_name, total_s = 0, nil, 0
local lua_us, cpp_us = 0, 0
for _, name in ipairs(gen.PRESETS) do
	local p = gen.preset(name, 1)
	local t0 = now()
	local n, parts
	for _ = 1, 100 do
		n, parts = gen.build(p, 44100)
	end
	local t1 = now()
	for _ = 1, 100 do
		for _, part in ipairs(parts) do
			gen.run(part.n, part.calls, buildat.synth)
		end
	end
	local t2 = now()
	lua_us, cpp_us = lua_us + (t1 - t0), cpp_us + (t2 - t1)
	total_s = total_s + 100 * n / 44100
	local each = (t2 - t0) / 100
	if each > longest then
		longest, longest_name = each, name
	end
end
say(string.format("speed presets: Lua %.1f ms, C++ %.1f" ..
		" ms per s of audio; the slowest (%s) made in %.2f ms",
		lua_us / 1000 / total_s, cpp_us / 1000 / total_s, longest_name,
		longest / 1000))

-- The engine's VectorBuffer, so to_shorts is timed too; a stream that
-- takes the data and drops it
local counting = {
	VectorBuffer = require("buildat/extension/urho3d").VectorBuffer,
	BufferedSoundStream = {new = function()
		return {SetFormat = function() end, AddData = function() end,
			bufferLength = 0}
	end},
}
local sounds = {}
for i, name in ipairs(gen.PRESETS) do
	sounds[i] = gen.render(gen.preset(name, 1), 44100, buildat.synth)
end
for _, voices in ipairs({1, 8, 32}) do
	local m = mix.new{magic = counting, synth = buildat.synth}
	local blocks = math.ceil(10 * 44100 / m.block)
	local t0 = now()
	for b = 0, blocks - 1 do
		-- Kept at `voices` playing: a new one each time one ends
		while #m.voices < voices do
			local s = sounds[(#m.voices + b) % #sounds + 1]
			m:add(s)
		end
		m:fill()
	end
	say(string.format("speed mixer: %d voices, %.1f ms " ..
			"per s of audio", voices, (now() - t0) / 1000 / 10))
end
say("done")
-- Escape, or a click or tap anywhere, goes back to the launcher
require("buildat/extension/ui_utils").show_message_dialog(
		"blip check\n" .. table.concat(said, "\n"), buildat.leave)
local magic = require("buildat/extension/urho3d")
magic.SubscribeToEvent("MouseButtonDown", function() buildat.leave() end)
magic.SubscribeToEvent("TouchBegin", function() buildat.leave() end)
