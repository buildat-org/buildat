-- Buildat: builtin/kit/client_lua/music.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [MUSIC_SYNTH] kit/music on the client: "kit:music" {id, song, t0, now,
-- mood} (kit.cpp's music_tick()) played by jam (extensions/jam), which
-- renders it on the audio thread. A song starts at now - t0 on its
-- timeline, the place everyone hearing it is at; {id, mood} switches the
-- mood from the next bar; {id: 0} stops it. One player for the app's
-- whole run, so a scene change that keeps the song keeps it playing.
-- The web's audio runs on the main thread, where a long frame stalls it:
-- once a second the place is compared with the server's clock and sought
-- back when it is half a second off. Logs "kit: music ...".
return function(K)
local log = K.log
local magic = require("buildat/extension/urho3d")
local network = require("buildat/extension/network")
local jam = require("buildat/extension/jam")
local now = buildat.get_time_us

-- {id, player, info, at (the timeline's seconds when local, now_us)}
local cur = nil

local function bar_at(info, at)
	local from, to = info.loop[1], info.loop[2]
	if at >= to and to > from then
		at = from + (at - from) % (to - from)
	end
	return math.floor(at / info.bar)
end

local function stop()
	if cur then
		cur.player:stop()
		log:info("kit: music " .. cur.id .. " stopped")
		cur = nil
	end
end

-- The place everyone is at now, by the server's clock
local function expected()
	return cur.at + (now() - cur.at_us) / 1e6
end

buildat.sub_packet("kit:music", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or type(d.id) ~= "number" then
		return
	end
	local mood = type(d.mood) == "string" and d.mood ~= "" and d.mood or "all"
	if d.id == 0 then
		stop()
	elseif type(d.song) == "string" then
		stop()
		local song, err = jam.song(d.song)
		local at = math.max(0, (tonumber(d.now) or 0) - (tonumber(d.t0) or 0))
		local p = song and jam.play(song, {at = at})
		if not p then
			log:warning("kit: music " .. d.id .. ": " .. tostring(err))
			return
		end
		p:mood(mood, true)
		cur = {id = d.id, player = p, info = song:info(), at = at, at_us = now()}
		log:info(string.format("kit: music %d \"%s\" from %.2f s, bar %d, mood %s",
				d.id, cur.info.title, at, bar_at(cur.info, at), mood))
	elseif cur and cur.id == d.id then
		local ok = cur.player:mood(mood)
		log:info("kit: music " .. d.id .. " mood " .. mood ..
				(ok and "" or ": not in the song"))
	end
end)

local checked_us, last_pos = 0, nil
magic.SubscribeToEvent("Update", function()
	if not cur or now() - checked_us < 1e6 then
		return
	end
	checked_us = now()
	-- (only while the audio runs: it renders ahead by its buffer)
	local pos = cur.player:position()
	if pos ~= last_pos and last_pos and cur.player:playing() then
		local off = pos - expected()
		if math.abs(off) > 0.5 then
			cur.player:seek(expected())
			log:info(string.format("kit: music %d sought %.2f s %s", cur.id,
					math.abs(off), off < 0 and "on" or "back"))
		end
	end
	last_pos = pos
end)
end
-- vim: set noet ts=4 sw=4:
