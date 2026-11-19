-- Buildat: apps/jam_check/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [MUSIC_SYNTH]'s check, run by util/jam_check.sh natively and on the web:
-- parse errors by line, jam.songs' hashes and render cost, then a player:
-- a mood landing on a bar, the stream going on through a main-thread
-- stall, stop. Each part logs a "jam check:" line; the script compares.
local log = buildat.Logger("jam_check")
local jam = require("buildat/extension/jam")
local magic = require("buildat/extension/urho3d")
local now = buildat.get_time_us
local function say(line)
	log:info("jam check: " .. line)
end

-- **Errors by line**: {text, its line, a piece of the message}
local BAD = {
	{"tempo fast", 1, "tempo: a number expected"},
	{"title x\ninst a osc foo=1", 2, "unknown parameter foo"},
	{"reverb size=9", 1, "reverb size: 9 is not"},
	{"\n\nwobble", 3, "unknown line: wobble"},
	{"inst a osc\ntrack t inst=a\npattern p\nt: C4 . .\nsection s: p\nplay s",
		3, "lane t: 3 steps, the pattern has 16"},
	{"inst a osc\ntrack t inst=a\npattern p\nt: C4 . . zz\nsection s: p\n" ..
		"play s", 4, "bad token zz"},
	{"inst a osc\ntrack t inst=a\nmood m t=loud", 3, "a number expected"},
	{"inst d kick\ntrack k inst=d\npattern p\nk: X..Q\nsection s: p\nplay s",
		4, "bad hit Q"},
}
local bad = 0
for i, b in ipairs(BAD) do
	local s, err = jam.song(b[1])
	if s or not err or not err:find("^line " .. b[2] .. ": ") or
			not err:find(b[3], 1, true) then
		bad = bad + 1
		say("error " .. i .. " FAILED: " .. tostring(err))
	end
end
say(bad == 0 and ("errors ok, " .. #BAD) or "errors FAILED")

-- **The hashes and the cost**: the first 10 s of each song (and one in a
-- mood), the samples' hash and the render's milliseconds a second
local songs = {}
for _, h in ipairs({{"scrap_heat"}, {"scrap_heat", "calm"}, {"yard_vamp"}}) do
	local s = assert(jam.song(jam.songs[h[1]]))
	songs[h[1]] = s
	local a = s:analyze(10, h[2])
	say(string.format("hash %s%s %s, %s ms per s, %s LUFS", h[1],
			h[2] and ("/" .. h[2]) or "", a:match('"hash": "(%x+)"'),
			a:match('"cpu_ms_per_s": ([%d.]+)'), a:match('"lufs": ([-%d.]+)')))
end

-- **The player**, a step a frame: started mid-bar, a mood asked for, the
-- main thread stalled, stopped
local song = songs.scrap_heat
local bar = song:info().bar
local p = assert(jam.play(song, {at = 2.3}))
local steps, wait_until = {}, nil
local function step(f) steps[#steps + 1] = f end
step(function()
	-- the audio thread has begun
	local at = p:position()
	if at < 2.35 then
		return now() > wait_until + 5e6 and "no audio: the player's parts" ..
				" SKIPPED" or false
	end
	say(string.format("playing from %.2f s, bar %d", at, select(2,
			p:position())))
	assert(p:mood("calm"))
	assert(not p:mood("nonesuch"))
	return true
end)
step(function()
	local at, _, mood_at = p:position()
	if not mood_at then
		return at > 2.3 + 3 * bar and "mood FAILED: not switched" or false
	end
	local k = math.floor(mood_at / bar + 0.5)
	local off = math.abs(mood_at - k * bar) * 44100
	say(string.format("mood %s: at %.4f s, bar %d, %.2f samples off",
			off < 1.5 and "on a bar" or "FAILED", mood_at, k, off))
	return true
end)
step(function()
	-- the main thread stalled a second
	local p0, t0 = p:position(), now()
	while now() - t0 < 1e6 do end
	local p1 = p:position()
	say(string.format("stall 1.00 s: the stream went on %.2f s", p1 - p0))
	p:stop()
	return true
end)
step(function()
	say(p:playing() and "stop FAILED" or "stopped")
	return true
end)

wait_until = now()
magic.SubscribeToEvent("Update", function()
	if #steps == 0 then
		return
	end
	local r = steps[1]()
	if r then
		table.remove(steps, 1)
		if type(r) == "string" then
			say(r)
			steps = {}
		end
		if #steps == 0 then
			say("done")
		end
	end
end)
