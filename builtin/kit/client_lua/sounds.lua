-- Buildat: builtin/kit/client_lua/sounds.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [KIT_SOUNDS] The project's sounds on the client: "kit:sounds" (M.sounds,
-- {name: {params, author, name, version, package}}; M.on_sounds(cb) is
-- called as they come) and "kit:sound" {name, at}, a trigger's, played by
-- blip (extensions/blip) -- positional at `at` in the app's scene, heard
-- from its camera (a SoundListener put there with the first sound).
-- M.play_sound(name[, at]) plays one by name (the held item's swing and
-- shot at once, the editor's Play); "kit: sound <name> ..." is logged.
-- simplified: heard from the app's own camera (walking's), also while the
-- editor's 2D or 3D view draws
-- For a drive: "event kit_play_sound <name>"
return function(K)
local M, O, log = K.M, K.O, K.log
local magic = require("buildat/extension/urho3d")
local network = require("buildat/extension/network")
local blip = require("buildat/extension/blip")

M.sounds = {}
local cbs = {}
function M.on_sounds(cb)
	cbs[#cbs + 1] = cb
end

buildat.sub_packet("kit:sounds", function(data)
	local t = network.parse_json(data)
	M.sounds = type(t) == "table" and t or {}
	local n = 0
	for _ in pairs(M.sounds) do n = n + 1 end
	log:info("kit: " .. n .. " sounds")
	for _, cb in ipairs(cbs) do cb() end
end)

local listener = nil
function M.play_sound(name, at)
	local s = M.sounds[name or ""]
	if not s then
		return false
	end
	if not listener and O.camera then
		listener = O.camera:CreateComponent("SoundListener")
		if magic.audio then
			magic.audio.listener = listener
		end
	end
	-- Positional only in the app's scene, where the listener is
	at = O.scene and type(at) == "table" and at or nil
	local ok, err = pcall(blip.play_cached, s.params,
			{node = at and O.scene or nil, at = at})
	log:info("kit: sound " .. name .. (at and string.format(" at (%.1f,%.1f,%.1f)",
			at[1] or 0, at[2] or 0, at[3] or 0) or "") ..
			(ok and "" or ": not played, " .. tostring(err)))
	return ok
end

buildat.sub_packet("kit:sound", function(data)
	local d = network.parse_json(data)
	if type(d) == "table" and type(d.name) == "string" then
		M.play_sound(d.name, type(d.at) == "table" and d.at or nil)
	end
end)

magic.SubscribeToEvent("command_seq:kit_play_sound", function(_, data)
	M.play_sound(data:GetString("Param"))
end)
end
-- vim: set noet ts=4 sw=4:
