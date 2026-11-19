-- Buildat: extensions/jam/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **jam, music from text** ([MUSIC_SYNTH], kit_plan 4z37e): a song in the
-- jam1 format (doc/client_api.txt) synthesised as it plays, on the audio
-- thread (src/lua_bindings/jam.cpp). Sandboxed; an app reaches it as
-- require("buildat/extension/jam"):
--   jam.song(text[, tempo]) -> song, or nil and "line N: why"
--   jam.play(song or text[, opts]) -> player, or nil and why
--     opts {at, mood, gain, type, node}: from at seconds on the song's
--     timeline (0), in mood (every track), at gain (1), as sound type
--     type ("Music", so the client's music volume applies), on node (jam's
--     own otherwise)
--   player:mood(name[, now]) -> false: no such mood. From the next bar,
--     faded over a beat; "all" every track
--   player:seek(seconds), player:position() -> seconds, bar, mood_at,
--   player:stop(), player:playing()
--   song:info() -> {title, tempo, bar, loop = {from, to}, tracks, moods}
--   song:analyze([seconds[, mood[, track]]]) -> its measures as JSON
--   song:wav([seconds[, mood]]) -> a WAV file's bytes (16-bit stereo), the
--     play order once through (at most 300 s)
--   jam.songs: example songs' texts by name (songs.lua)
--   jam.editor(A): the music editor (music_edit.lua) made for a caller,
--     A {K, NT, magic, ui_utils, log[, log_prefix]}: Kit's helpers and
--     NT.mu its handle (builtin/kit/client_lua/editor.lua)
-- The launch tile runs the jam app ([JAM_APP], app.lua).
-- Its versioning is its format's (jam1), not the engine's.
local api = buildat.safe or buildat
local magic = require("buildat/core/urho3d")

local M = {safe = {songs = api.run_extension_file("songs.lua")}}

-- **Inert until called**: the scene and the node come with the first song
local state = {}
local function own_node()
	if not state.node then
		state.scene = magic.Scene()
		state.node = state.scene:CreateChild("jam")
	end
	return state.node
end

function M.safe.song(text, tempo)
	return api.jam.song(text, tempo)
end

function M.safe.play(song, opts)
	opts = type(opts) == "table" and opts or {}
	if type(song) == "string" then
		local err
		song, err = api.jam.song(song)
		if not song then
			return nil, err
		end
	end
	local source = (opts.node or own_node()):CreateComponent("SoundSource")
	source.gain = opts.gain or 1
	source.soundType = opts.type or "Music"
	source.autoRemoveMode = magic.REMOVE_COMPONENT
	local p = song:play(source, opts.at)
	if opts.mood and opts.mood ~= "all" and not p:mood(opts.mood, true) then
		p:stop()
		return nil, "no mood " .. tostring(opts.mood)
	end
	return p
end

-- [JAM_APP] One editor for Kit and the app: a new one a caller
function M.safe.editor(A)
	return api.run_extension_file("music_edit.lua")(A)
end

-- The launch tile's way in (launcher/init.lua): the jam app, made once
local open_app = nil
function M.on_untrusted_launch(request)
	open_app = open_app or api.run_extension_file("app.lua")(M.safe)
	open_app()
end

return M
