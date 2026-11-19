-- Buildat: extensions/jam/app.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- [JAM_APP] **The jam app** (kit_plan 4z37k): the music editor
-- (music_edit.lua, Kit's own) on a song of the user's, beside blip's and
-- weave's designers on the launch grid (launcher/init.lua). A fourth row
-- over the editor's views: New from template (jam.songs), Open... (a .jam
-- file: the exports natively, the browser's picker on the web), Save (the
-- song's jam1 text as <title>.jam: <user>/exports natively, a download on
-- the web) and Export WAV (the play order once through, in the preview's
-- mood). Leaving a changed song (a template, a file, Close, Escape) asks
-- first. Logs "app: ..." (the editor's lines too).
-- simplified: one song open; no touch mode (the editor's desktop sizes on a
-- phone); a WAV is rendered on the main thread (Scrap Heat's 2 minutes in
-- about 3 s: the window stalls, "rendering" shown first)
local api = buildat.safe or buildat
local magic = require("buildat/core/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local log = buildat.Logger("jam")

return function(jam)
-- Kit's helpers the editor draws with (builtin/kit/client_lua/module.lua's)
local K = {DIM = magic.Color(0.7, 0.7, 0.7), WARN = magic.Color(1.0, 0.55, 0.45),
	STYLE = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")}
function K.row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	return r
end
function K.text(parent, s, c)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(s)
	if c then
		t:SetColor(c)
	end
	return t
end
function K.button(parent, s, fn, down)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b.minHeight = 24
	local t = K.text(b, s, down and magic.Color(1.0, 0.85, 0.3))
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = t.width + 16
	magic.SubscribeToEvent(b, "Released", function() fn() end)
	return b, t
end
function K.edit(parent, value, on_text)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minWidth = 120
	e.minHeight = 24
	e.clipBorder = magic.IntRect(4, 0, 4, 0)
	e:SetText(value)
	magic.SubscribeToEvent(e, "TextChanged", function() on_text(e:GetText()) end)
	return e
end
local NT = {sh = {on = function() return false end, touch_size = function() end}}
jam.editor({K = K, NT = NT, magic = magic, ui_utils = ui_utils, log = log,
	log_prefix = "app: "})
local MU = NT.mu

local TEMPLATES = {{"Launch Room", "launch_room"}, {"Slow Tide", "slow_tide"},
	{"Yard Vamp", "yard_vamp"}, {"Scrap Heat", "scrap_heat"}}
-- saved: the text as last opened or saved (a change asks before it goes)
local app = {status = "", saved = nil}

local function say(s)
	app.status = s
	log:info("app: " .. s)
	if app.status_text then
		app.status_text:SetText(s)
	end
end

-- The song's file name: its title's, as a file name
local function file_name(ext)
	local n = (MU.m.title ~= "" and MU.m.title or app.title):lower()
			:gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
	return (n ~= "" and n or "song") .. ext
end

-- After a yes when the song has changed since it was opened or saved
-- (not "Close": a back label, which Escape presses)
local function unless_changed(fn)
	if not MU.on() or MU.text == app.saved then
		return fn()
	end
	ui_utils.show_confirm_dialog("The song has changes that are not " ..
			"saved. Discard them?", fn, function()
		-- (the template list back on its placeholder: the same pick again
		-- is a pick)
		if app.drop then
			ui_utils.dropdown_set(app.drop, "")
		end
	end, "Discard", "Cancel")
end

local file_row
local function open_song(text, title)
	if MU.on() then
		app.switching = true
		MU.close(true)
		app.switching = false
	end
	app.saved, app.title = text, title
	-- (top: under the launcher's Starport buttons)
	MU.open({text = text, title = title, file_row = file_row, top = 36,
		on_text = function() end,
		may_close = function()
			if MU.text == app.saved then
				return true
			end
			unless_changed(function() MU.close(true) end)
			return false
		end,
		on_close = function()
			if not app.switching then
				log:info("app: closed")
			end
		end})
	say("opened " .. title .. ", " .. #text .. " bytes" ..
			(MU.err and ", Error: " .. MU.err or ""))
end

-- The fourth row: the files; buttons as wide as their text, as the editor's
local function button(r, s, fn)
	local b = K.button(r, s, fn)
	b.maxWidth = b.minWidth
	return b
end
function file_row(r)
	local list = {{"New from template...", ""}}
	for _, t in ipairs(TEMPLATES) do
		list[#list + 1] = {t[1], t[2]}
	end
	app.drop = ui_utils.dropdown(r, list, "", function(v, i)
		if v == "" then
			return
		end
		unless_changed(function()
			open_song(jam.songs[v], TEMPLATES[i - 1][1])
		end)
	end, {name = "jam template"})
	button(r, "Open...", function()
		unless_changed(function()
			app.picking = api.pick_file(".jam")
			say("picking a .jam file")
		end)
	end):SetName("jam open")
	button(r, "Save", function()
		local name = file_name(".jam")
		local path, why = api.save_file(name, MU.text)
		if path then
			app.saved = MU.text
			-- (the name it got: natively a taken one is name_2...)
			say("saved " .. (path ~= "" and path:match("[^/\\]+$") or name) ..
					", " .. #MU.text .. " bytes")
		else
			say("not saved: " .. tostring(why))
		end
	end):SetName("jam save")
	button(r, "Export WAV", function()
		if not MU.song then
			say("no WAV: " .. tostring(MU.err))
			return
		end
		say("rendering " .. file_name(".wav"))
		-- (two frames on: the line above drawn before the stall)
		app.wav_due = 2
	end):SetName("jam wav")
	app.status_text = K.text(r, "  " .. app.status, K.DIM)
end

local function export_wav()
	local song = jam.song(MU.text)
	local bytes, why = song and song:wav(0, MU.mood)
	if not bytes then
		say("no WAV: " .. tostring(why or MU.err))
		return
	end
	local name = file_name(".wav")
	local path, err = api.save_file(name, bytes)
	say(path and string.format("exported %s, %d bytes, %.2f s", path ~= "" and
			path:match("[^/\\]+$") or name, #bytes, (#bytes - 44) / 176400) or
			"no WAV: " .. tostring(err))
end

magic.SubscribeToEvent("Update", function()
	if app.wav_due then
		app.wav_due = app.wav_due - 1
		if app.wav_due <= 0 then
			app.wav_due = nil
			export_wav()
		end
	end
	if not app.picking then
		return
	end
	local name, data = api.picked_file()
	if not name then
		if data then
			app.picking = false
			say("nothing opened: " .. tostring(data))
		end
		return
	end
	app.picking = false
	-- A file from the disk: text of jam's size at most, Windows' line ends
	-- read as \n
	if #data > 65536 then
		say("not opened: " .. name .. " is " .. #data .. " bytes, 65536 at most")
		return
	end
	data = data:gsub("\r\n", "\n")
	-- (its title line's, else the file's name)
	local song = jam.song(data)
	local title = song and song:info().title or ""
	open_song(data, title ~= "" and title or (name:gsub("%.jam$", "")))
end)

return function()
	if MU.on() then
		return
	end
	open_song(jam.songs.launch_room, TEMPLATES[1][1])
end
end
-- vim: set noet ts=4 sw=4:
