-- Buildat: extensions/blip/blip_mix.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **blip's mixer** ([BLIP]): one BufferedSoundStream, topped up each
-- frame as launch_world's synth does it, and the sounds added to it
-- mixed into it a block at a time by the engine's synth blocks
-- (buildat.synth): a call per voice per block, the samples in C++. Plain
-- Lua; an app may copy this file into itself, as blip_gen.lua.
--
--   local m = mix.new{magic = magic, synth = buildat.synth}
--   m:play(node)                 -- a SoundSource on the stream
--   m:add(buffer[, at, gain])    -- a buffer of the mixer's rate
--   m:update()                   -- each frame
--
-- A sound starts at the end of what is queued, `at` seconds after it:
-- up to `ahead` (0.1 s) and a block late.
-- simplified: mono, and a sound plays from where the queue ends. Stereo,
-- and a start counted from the playhead, are the upgrades when music
-- ([BLIP_MUSIC]) wants them.
local M = {}
local mixer = {}

function M.new(o)
	-- The methods copied in: the sandbox has no setmetatable
	local self = {}
	for k, f in pairs(mixer) do
		self[k] = f
	end
	self.magic, self.synth = o.magic, o.synth
	self.rate = o.rate or 44100
	self.block = o.block or 1024
	self.ahead = o.ahead or 0.1
	self.stream = self.magic.BufferedSoundStream:new()
	self.stream:SetFormat(self.rate, true, false)
	-- An underrun is a gap, not the end of the sound
	self.stream.stopAtEnd = false
	self.out = self.synth.buffer(self.block)
	self.shorts = self.magic.VectorBuffer:new()
	self.voices = {}
	self.t = 0 -- samples queued since the start
	return self
end

-- A SoundSource on node playing the stream; opts {gain, panning, type}
function mixer:play(node, opts)
	opts = opts or {}
	local source = node:CreateComponent("SoundSource")
	source.gain = opts.gain or 1
	source.panning = opts.panning or 0
	source.soundType = opts.type or "Effect"
	source:Play(self.stream)
	self.source = source
	return source
end

function mixer:add(buffer, at, gain)
	local v = {buf = buffer, len = buffer:len(), gain = gain or 1,
		start = self.t + math.floor((at or 0) * self.rate + 0.5)}
	self.voices[#self.voices + 1] = v
	return v
end

-- One block: each voice's part of it summed in, then queued
function mixer:fill()
	local t, b, out = self.t, self.block, self.out
	out:clear()
	local voices = self.voices
	for i = #voices, 1, -1 do
		local v = voices[i]
		local a = math.max(v.start, t)
		local e = math.min(v.start + v.len, t + b)
		if e > a then
			out:mix(v.buf, a - v.start, a - t, e - a, v.gain)
		end
		if v.start + v.len <= t + b then
			table.remove(voices, i)
		end
	end
	out:to_shorts(self.shorts)
	self.stream:AddData(self.shorts)
	self.t = t + b
end

function mixer:update()
	local guard = 0
	while self.stream.bufferLength < self.ahead and guard < 64 do
		self:fill()
		guard = guard + 1
	end
end

return M
-- vim: set noet ts=4 sw=4:
