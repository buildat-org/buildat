-- Buildat: extensions/luanti_client/res/sound_play.lua
-- (vanilla's client runs it too, served as luanti/sound_play.lua)
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **The sounds played**: one Urho3D SoundSource per sound the server
-- started, at a place in the world, on an object it follows, or in the
-- player's own head, which is Luanti's own three. The fades run here, and a
-- source that has finished takes its node with it. One copy for both Luanti
-- clients ([LUANTI_SHARED_1019]); what differs is how each gets the record,
-- which sounds.lua reads off the wire for luanti_client and lua/sound.lua
-- sends vanilla.
--
-- A positioned sound at Luanti's gain ([SOUND_GAIN_LUANTI]): three times
-- the asked one, over the distance from 1 node out (OpenAL's inverse
-- distance, clamped), never over 1 (AL_MAX_GAIN) -- the world against the
-- music as in Luanti. Urho3D's own attenuation is off (near and far beyond
-- any world), its panning kept.
--
-- simplified: start_time is ignored, because seeking is not in the
-- sandbox's SoundSource. A game uses it for background music a player
-- rejoins in the middle of.
--
--   play = <this file>(o)
-- o: magic; sounds (res/sounds.lua: the locations, fade_step); scene() ->
-- the scene to play in, or nil (nothing plays); object_pos(id) -> a
-- Vector3, or nil for an object this client does not have.
-- The record (sounds.lua's read_play): gain, pitch, loop, fade, location
-- (sounds.LOCAL, POSITION or OBJECT), pos {x, y, z} in nodes, object_id.
-- play.play(id, spec, sound) -> the source, or nil: sound is the Sound,
-- picking which file is the caller's; play.stop(id); play.fade(id, step,
-- gain): FADE_SOUND; play.update(dtime, ear), every frame, ear where the
-- listener is; play.count() -> how many are playing.
return function(o)
	local magic, sounds = o.magic, o.sounds
	local NO_ATTENUATION = 1e9
	local P = {}
	local playing = {}
	local ear = nil

	local function heard(entry)
		if not entry.positional or not ear then
			return entry.gain
		end
		local d = (entry.node.position - ear):Length()
		return math.min(1, 3 * entry.gain / math.max(d, 1))
	end

	function P.stop(id)
		local entry = playing[id]
		if entry == nil then
			return
		end
		playing[id] = nil
		entry.source:Stop()
		entry.node:Remove()
	end

	function P.play(id, spec, sound)
		local scene = o.scene()
		if scene == nil or sound == nil then
			return nil
		end
		sound.looped = spec.loop and true or false
		local node = scene:CreateChild("sound")
		local source
		-- A sound attached to an object starts where the object is and
		-- follows it, which is what a mob's own noises want; one at a
		-- position stays there; one that is neither is in the player's own
		-- head and has no position at all
		local follows = spec.location == sounds.OBJECT and
				spec.object_id ~= 0 and spec.object_id ~= "0" and
				spec.object_id or nil
		if spec.location == sounds.LOCAL then
			source = node:CreateComponent("SoundSource")
		else
			node.position = follows and o.object_pos(follows) or
					magic.Vector3(spec.pos[1], spec.pos[2], spec.pos[3])
			source = node:CreateComponent("SoundSource3D")
			source.nearDistance = NO_ATTENUATION
			source.farDistance = NO_ATTENUATION
		end
		source.soundType = magic.SOUND_EFFECT
		local gain = spec.gain or 1
		local entry = {node = node, source = source, started = false,
				object_id = follows,
				positional = spec.location ~= sounds.LOCAL}
		-- A fade on the packet means it starts silent and comes up to the
		-- gain it asked for
		if spec.fade and spec.fade > 0 then
			entry.target = gain
			entry.step = spec.fade
			gain = 0
		end
		entry.gain = gain
		source.gain = heard(entry)
		if spec.pitch and spec.pitch > 0 and spec.pitch ~= 1 then
			source.frequency = sound.frequency * spec.pitch
		end
		source:Play(sound)
		-- A sound the server gave no id keeps none: it said it will not
		-- talk about it again, and the update below takes the node away
		-- when it has finished
		P.stop(id)
		playing[id] = entry
		return source
	end

	-- FADE_SOUND: gain moves by step a second until it is at gain, and a
	-- sound faded to nothing stops
	function P.fade(id, step, gain)
		local entry = playing[id]
		if entry then
			entry.step = step
			entry.target = gain
		end
	end

	-- The fades, the sounds that follow an object, and the nodes of the ones
	-- that have finished
	function P.update(dtime, at)
		ear = at or ear
		for id, entry in pairs(playing) do
			local follow = entry.object_id and o.object_pos(entry.object_id)
			if follow then
				entry.node.position = follow
			end
			if entry.target then
				local gain, done = sounds.fade_step(entry.gain, entry.target,
						entry.step, dtime)
				entry.gain = gain
				if done then
					entry.target = nil
					if gain <= 0 then
						P.stop(id)
					end
				end
			end
			-- Not on the frame it started: a source has not been mixed yet
			-- and says it is not playing
			if playing[id] then
				entry.source.gain = heard(entry)
				if entry.started and not entry.source.playing then
					P.stop(id)
				end
				entry.started = true
			end
		end
	end

	function P.count()
		local n = 0
		for _ in pairs(playing) do
			n = n + 1
		end
		return n
	end

	return P
end
-- vim: set noet ts=4 sw=4:
