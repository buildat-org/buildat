-- Buildat: builtin/kit/client_lua/music.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [MUSIC_SYNTH] kit/music on the client: "kit:music" {id, song, t0, now,
-- mood} (kit.cpp's music_tick()) played by jam (extensions/jam), which
-- renders it on the audio thread. A song starts at now - t0 on its
-- timeline, the place everyone hearing it is at; {id, mood} switches the
-- mood from the next bar; {id: 0} stops it. One player for the app's
-- whole run, so a scene change that keeps the song keeps it playing.
-- Once a second the place is compared with the server's clock and sought
-- back when it is half a second off (a stall on the web: jam renders a
-- second ahead there, [MUSIC_WEB_RING]). Logs "kit: music ...".
-- **Held while a scene loads** ([KIT_MUSIC_LOAD_HOLD], kit_plan 4z37h
-- (9)): from this player's entering a scene (kit:you: the join, a race's
-- scene, the generator's track made for it) until the world has settled,
-- no music: a few frames a second there made it sound broken. Back on the
-- song's timeline, where everyone else is, in its mood. Settled: a second
-- since, a chunk come (or 3 s), none of the world's files or chunks for a
-- second, nothing queued (idle_pending(): the meshes) and frames under 250 ms for half a second
-- (a few a second jam plays through, not a stall).
-- simplified: 30 s at most; a generator run with no scene entered (the
-- editor's Run) is not held
return function(K)
local log = K.log
local magic = require("buildat/extension/urho3d")
local network = require("buildat/extension/network")
local jam = require("buildat/extension/jam")
local now = buildat.get_time_us

-- {id, player (nil while held), song, info, mood, at (the timeline's
-- seconds when local, now_us)}
local cur = nil
-- The load's start (get_time_us()), or nil
local held = nil

local function bar_at(info, at)
	local from, to = info.loop[1], info.loop[2]
	if at >= to and to > from then
		at = from + (at - from) % (to - from)
	end
	return math.floor(at / info.bar)
end

local function stop()
	if cur then
		if cur.player then
			cur.player:stop()
		end
		log:info("kit: music " .. cur.id .. " stopped")
		cur = nil
	end
end

-- The place everyone is at now, by the server's clock
local function expected()
	return cur.at + (now() - cur.at_us) / 1e6
end

-- cur played from where everyone is
local function start()
	local at = expected()
	local p, err = jam.play(cur.song, {at = at})
	if not p then
		log:warning("kit: music " .. cur.id .. ": " .. tostring(err))
		return false
	end
	p:mood(cur.mood, true)
	cur.player = p
	return true
end

-- [KIT_MUSIC_LOAD_HOLD] a scene entered (module.lua's kit:you)
K.M.music_entered = function()
	held = now()
	if cur and cur.player then
		cur.player:stop()
		cur.player = nil
		log:info("kit: music " .. cur.id .. " held, the scene loading")
	end
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
		if not song then
			log:warning("kit: music " .. d.id .. ": " .. tostring(err))
			return
		end
		local at = math.max(0, (tonumber(d.now) or 0) - (tonumber(d.t0) or 0))
		cur = {id = d.id, song = song, info = song:info(), mood = mood, at = at,
			at_us = now()}
		if not held and not start() then
			cur = nil
			return
		end
		log:info(string.format("kit: music %d \"%s\" from %.2f s, bar %d, mood %s%s",
				d.id, cur.info.title, at, bar_at(cur.info, at), mood,
				held and ", held: the scene loading" or ""))
	elseif cur and cur.id == d.id then
		cur.mood = mood
		local ok = not cur.player or cur.player:mood(mood)
		log:info("kit: music " .. d.id .. " mood " .. mood ..
				(ok and "" or ": not in the song"))
	end
end)

-- [KIT_MUSIC_LOAD_HOLD] the load over: the world in and the frames quick
local quick_us = nil
local function settled(t, dt)
	if dt > 0.25 then
		quick_us = nil
	elseif not quick_us then
		quick_us = t
	end
	if t - held > 30e6 then
		return true
	end
	if t - held < 1e6 or not quick_us or t - quick_us < 0.5e6 then
		return false
	end
	-- (the world's first chunk may take a moment: 3 s without one)
	local a = buildat.last_arrival()
	if a and a.kind ~= "other" and t - a.t < 1e6 then
		return false
	end
	if t - held < 3e6 and not (a and a.kind == "chunk" and a.t > held) then
		return false
	end
	return buildat.idle_pending() == ""
end

local checked_us, last_pos = 0, nil
magic.SubscribeToEvent("Update", function(_, ev)
	if held and settled(now(), ev:GetFloat("TimeStep")) then
		local was = held
		held, quick_us, last_pos = nil, nil, nil
		log:info(string.format("kit: music: the scene loaded, held %.1f s",
				(now() - was) / 1e6))
		if cur and start() then
			log:info(string.format("kit: music %d on at %.2f s", cur.id,
					expected()))
		elseif cur then
			cur = nil
		end
	end
	if not cur or not cur.player or now() - checked_us < 1e6 then
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
