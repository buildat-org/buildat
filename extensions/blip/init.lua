-- Buildat: extensions/blip/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **blip, a sound designer and player** ([BLIP], doc/plan/blip_plan.md):
-- sfxr's sounds made with the engine's synth blocks. Sandboxed; an app
-- reaches it as require("buildat/extension/blip"):
--   blip.play(sound[, opts])         made and played, not kept
--   blip.play_cached(sound[, opts])  made once into a Sound, played again
--   blip.stream([opts]) -> mixer     mixer:add(sound[, at, gain]) mixes
--                                    it into one stream
--   blip.wav(sound) -> the bytes of a 16-bit WAV file
-- A sound is any of blip1's forms (blip_gen.lua's params()); opts is
-- {gain, panning, type, node}, type the SoundSource's sound type
-- ("Effect"), so the client's volume settings apply, node one of the
-- caller's to play on (blip's own otherwise). blip.gen and blip.mix are
-- the generator and the mixer, which an app may also copy into itself.
-- Its versioning is its formats' (blip1), not the engine's.
local api = buildat.safe or buildat
local log = buildat.Logger("blip")
local magic = require("buildat/core/urho3d")
local gen = api.run_extension_file("blip_gen.lua")
local mix = api.run_extension_file("blip_mix.lua")
local RATE = 44100
-- The engine's constants come from magic in the sandbox
local KEY_ESCAPE, LM_HORIZONTAL, LM_VERTICAL =
	magic.KEY_ESCAPE, magic.LM_HORIZONTAL, magic.LM_VERTICAL

local M = {safe = {gen = gen, mix = mix}}

-- **Inert until called** (an extension loads with the client): the
-- scene, the node and the frame's handler come with the first sound
local state = {mixers = {}, cache = {}, cached = 0}
local function own_node()
	if not state.node then
		state.scene = magic.Scene()
		state.node = state.scene:CreateChild("blip")
	end
	return state.node
end

local function tick()
	if state.ticking then
		return
	end
	state.ticking = true
	magic.SubscribeToEvent("Update", function()
		for i = #state.mixers, 1, -1 do
			local m = state.mixers[i]
			if m.stopped then
				table.remove(state.mixers, i)
			else
				m.mixer:update()
			end
		end
		if state.on_update then
			state.on_update()
		end
	end)
end

local function to_sound(buf)
	local shorts = magic.VectorBuffer:new()
	buf:to_shorts(shorts)
	local sound = magic.Sound:new()
	sound:SetFormat(RATE, true, false)
	sound:SetData(shorts)
	return sound
end

local function play_on(sound, opts)
	opts = opts or {}
	local source = (opts.node or own_node()):CreateComponent("SoundSource")
	source.gain = opts.gain or 1
	source.panning = opts.panning or 0
	source.soundType = opts.type or "Effect"
	source.autoRemoveMode = magic.REMOVE_COMPONENT
	source:Play(sound)
	return source
end

-- Every parameter at full precision: two tables that differ below the
-- compact form's steps are two sounds
local function key_of(p)
	local out = {p.wave, p.seed}
	for _, d in ipairs(gen.PARAMS) do
		out[#out + 1] = string.format("%.17g", p[d[1]])
	end
	return table.concat(out, " ")
end

function M.safe.play(sound, opts)
	local p = gen.params(sound)
	local source = play_on(to_sound(gen.render(p, RATE, buildat.synth)), opts)
	log:info("played " .. gen.pack(p))
	return source
end

-- simplified: at most 64 Sounds kept, all dropped when a 65th comes; a
-- least-recently-used order is the upgrade if a game plays more
function M.safe.play_cached(sound, opts)
	local p = gen.params(sound)
	local key = key_of(p)
	local s = state.cache[key]
	local made = s == nil
	if made then
		if state.cached >= 64 then
			state.cache, state.cached = {}, 0
		end
		s = to_sound(gen.render(p, RATE, buildat.synth))
		state.cache[key], state.cached = s, state.cached + 1
	end
	log:info("played cached " .. gen.pack(p) .. (made and " (made)" or ""))
	return play_on(s, opts)
end

-- A mixer playing on its own stream; its add() takes a sound in any form
-- and makes it at the mixer's rate (22050 for a cheaper stream)
function M.safe.stream(opts)
	opts = opts or {}
	local m = mix.new{magic = magic, synth = buildat.synth,
		rate = opts.rate or RATE}
	local entry = {mixer = m}
	local buffers = {}
	m:play(opts.node or own_node(), opts)
	state.mixers[#state.mixers + 1] = entry
	tick()
	local out = {}
	function out.add(_, sound, at, gain)
		local p = gen.params(sound)
		local key = key_of(p)
		buffers[key] = buffers[key] or gen.render(p, m.rate, buildat.synth)
		m:add(buffers[key], at, gain)
		log:info("mixed " .. gen.pack(p))
	end
	function out.stop()
		entry.stopped = true
		if m.source then
			m.source:Stop()
		end
	end
	return out
end

-- A 16-bit mono WAV of the sound at 44100 Hz: its 44-byte header, then
-- the samples as to_shorts() rounds them
local function le(v, bytes)
	local out = {}
	for i = 1, bytes do
		out[i] = string.char(v % 256)
		v = math.floor(v / 256)
	end
	return table.concat(out)
end
function M.safe.wav(sound)
	local buf = gen.render(gen.params(sound), RATE, buildat.synth)
	local n = buf:len()
	local parts = {"RIFF", le(36 + n * 2, 4), "WAVEfmt ", le(16, 4),
		le(1, 2), le(1, 2), le(RATE, 4), le(RATE * 2, 4), le(2, 2), le(16, 2),
		"data", le(n * 2, 4)}
	local floor, char = math.floor, string.char
	local chunk = {}
	for i = 0, n - 1 do
		local v = floor(buf:get(i) * 32767 + 0.5)
		v = v < -32768 and -32768 or v > 32767 and 32767 or v
		if v < 0 then
			v = v + 65536
		end
		chunk[#chunk + 1] = char(v % 256, floor(v / 256))
		if #chunk == 4096 then
			parts[#parts + 1] = table.concat(chunk)
			chunk = {}
		end
	end
	parts[#parts + 1] = table.concat(chunk)
	return table.concat(parts)
end

M.safe.params = gen.params
M.safe.pack = gen.pack
M.safe.preset = gen.preset

-- **The designer** (the launch tile's): sfxr's generators, a mutate and
-- a random, a slider a parameter and a play on every change; the export
-- row and the imports
local SNIPPET_USES = {
	{"Play", "play"}, {"Play cached", "play_cached"},
	{"Add to a stream", "stream"},
}
local FORMATS = {{"Compact", "compact"}, {"Table", "table"},
	{"Both", "both"}, {"Raw engine calls", "raw"}}

-- A value as Lua source: a number in the fewest digits that read back
-- the same, so the raw calls make the same samples as blip
local function lua_value(v, indent)
	if type(v) == "number" then
		local s = string.format("%.15g", v)
		return tonumber(s) == v and s or string.format("%.17g", v)
	elseif type(v) ~= "table" then
		return string.format("%q", v)
	end
	local inner = indent .. "\t"
	local out = {}
	if #v > 0 then
		for _, x in ipairs(v) do
			out[#out + 1] = lua_value(x, inner)
		end
		return "{" .. table.concat(out, ", ") .. "}"
	end
	local keys = {}
	for k in pairs(v) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		out[#out + 1] = inner .. k .. " = " .. lua_value(v[k], inner) .. ","
	end
	return "{\n" .. table.concat(out, "\n") .. "\n" .. indent .. "}"
end

-- **The raw engine calls**: the sound built with buildat.synth and played
-- with magic's classes, no blip; magic and node are the app's own
local function raw_calls(p)
	local n, calls = gen.chain(p, RATE)
	local out = {"local buf = buildat.synth.buffer(" .. n .. ")"}
	for _, c in ipairs(calls) do
		out[#out + 1] = "buf:" .. c[1] .. "(" .. lua_value(c[2], "") .. ")"
	end
	return out
end
local function raw_snippet(p, use)
	local out = raw_calls(p)
	table.insert(out, 1, "-- " .. gen.pack(p) .. " as the engine's calls, no blip")
	out[#out + 1] = "local shorts = magic.VectorBuffer:new()"
	out[#out + 1] = "buf:to_shorts(shorts)"
	if use == "stream" then
		-- simplified: one sound queued on a stream; mixing several into
		-- one is what blip_mix.lua does
		out[#out + 1] = "local stream = magic.BufferedSoundStream:new()"
		out[#out + 1] = "stream:SetFormat(44100, true, false)"
		out[#out + 1] = "stream:AddData(shorts)"
		out[#out + 1] = "node:CreateComponent(\"SoundSource\"):Play(stream)"
	else
		out[#out + 1] = "local sound = magic.Sound:new()" ..
				(use == "play_cached" and "  -- kept: Play(sound) again" or "")
		out[#out + 1] = "sound:SetFormat(44100, true, false)"
		out[#out + 1] = "sound:SetData(shorts)"
		out[#out + 1] = "node:CreateComponent(\"SoundSource\"):Play(sound)"
	end
	return table.concat(out, "\n") .. "\n"
end

local function sound_source(p, format)
	if format == "compact" then
		return string.format("%q", gen.pack(p))
	elseif format == "table" then
		return gen.table_source(gen.to_table(p))
	end
	return string.format("{%q, volume = %.4g}", gen.pack(p), p.volume)
end

local function snippet(p, format, use, files)
	if format == "raw" then
		return raw_snippet(p, use)
	end
	local s = sound_source(p, format)
	if files then
		-- blip_gen.lua and blip_mix.lua copied into the app's main
		-- module's client_lua; magic and node are the app's own
		local head = "-- blip_gen.lua and blip_mix.lua in main/client_lua\n" ..
				"local _, _, gen = buildat.run_script_file(" ..
				"\"main/blip_gen.lua\")\n"
		local body = "local buf = gen.render(gen.params(" .. s ..
				"), 44100, buildat.synth)\n"
		if use == "stream" then
			return head .. "local _, _, mix = buildat.run_script_file(" ..
					"\"main/blip_mix.lua\")\n" ..
					"local m = mix.new{magic = magic, synth = buildat.synth}\n" ..
					"m:play(node)  -- and m:update() each frame\n" ..
					body .. "m:add(buf)\n"
		end
		return head .. body ..
				"local shorts = magic.VectorBuffer:new()\n" ..
				"buf:to_shorts(shorts)\n" ..
				"local sound = magic.Sound:new()  -- keep it for a replay\n" ..
				"sound:SetFormat(44100, true, false)\n" ..
				"sound:SetData(shorts)\n" ..
				"node:CreateComponent(\"SoundSource\"):Play(sound)\n"
	end
	local head = "local blip = require(\"buildat/extension/blip\")\n"
	if use == "stream" then
		return head .. "local mixer = blip.stream()\nmixer:add(" .. s ..
				")\n"
	end
	return head .. "blip." .. use .. "(" .. s .. ")\n"
end

-- And the designer's raw engine calls, run, make the same samples
M.safe.self_check = function()
	local ok, bad = gen.self_check(buildat.synth)
	for _, name in ipairs(gen.PRESETS) do
		local code = table.concat(raw_calls(gen.preset(name, 1)), "\n") ..
				"\nreturn buf:hash()"
		local ran, h = api.eval(code, "blip raw calls")
		if not ran or h ~= gen.HASHES[name] then
			ok = false
			bad[#bad + 1] = name .. "'s raw calls: " .. tostring(h)
		end
	end
	return ok, bad
end

local designer = nil

local function open_designer()
	if designer then
		return
	end
	local uistack = require("buildat/core/uistack")
	local ui_utils = require("buildat/extension/ui_utils")
	local import = api.run_extension_file("import.lua")(gen)
	local d = {p = gen.preset("pickup", 1), seed = 1, format = "compact",
		use = "play"}
	designer = d
	local root = uistack.main:push({desc = "blip"})
	root.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	local win = root:CreateChild("Window")
	win:SetStyleAuto()
	win:SetLayout(LM_VERTICAL, 6, magic.IntRect(10, 10, 10, 10))
	-- **A second column on a landscape screen with room for it**: the
	-- code that plays the sound, as Copy makes it, in both forms
	-- simplified: decided as the designer opens; a window turned or
	-- resized while it is open keeps the layout it opened with
	local ui_w, ui_h = magic.ui.root.width, magic.ui.root.height
	local col, code_col = win, nil
	if ui_w >= 820 and ui_w > ui_h then
		win:SetLayout(LM_HORIZONTAL, 12, magic.IntRect(10, 10, 10, 10))
		-- On the left, the layout's order; filled below
		code_col = win:CreateChild("UIElement")
		col = win:CreateChild("UIElement")
		col:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	end
	local function close()
		state.on_update = nil
		designer = nil
		uistack.main:pop(root)
		log:info("designer closed")
	end
	ui_utils.close_glyph(root, win, close)
	-- The menu's keys and clicks; Escape closes it unless a dropdown's
	-- popup is open, which takes it
	local nav = ui_utils.bind_button_menu(root, nil, function(key)
		if key == KEY_ESCAPE and magic.input:GetKeyPress(key) and
				not ui_utils.dropdown_open() then
			close()
			return true
		end
	end)

	local function text(parent, s, width)
		local t = parent:CreateChild("Text")
		t:SetStyleAuto()
		t.text = s
		if width then
			t:SetFixedWidth(width)
		end
		return t
	end
	local function row(parent)
		local r = (parent or col):CreateChild("UIElement")
		r:SetLayout(LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
		return r
	end
	local function button(parent, label, fn)
		local b = parent:CreateChild("Button")
		b:SetStyleAuto()
		b:SetName(label)
		b:SetFixedHeight(28)
		b:SetLayout(LM_HORIZONTAL, 0, magic.IntRect(8, 2, 8, 2))
		local t = b:CreateChild("Text")
		t:SetStyleAuto()
		t.text = label
		nav:add(b, fn)
		return b
	end
	text(col, "blip: sfxr's sounds, made by the engine's synth")
	local status = nil
	local function say(s)
		status.text = s
		log:info("designer: " .. s)
	end

	-- Play on every change; while a slider moves, the next play waits
	-- for half of the last sound (its length is the envelope's, or less
	-- where the frequency limit ends it), and at least 0.15 s
	local dirty, last, wait_us = false, 0, 0
	local code = nil
	local function show_code()
		if code then
			-- Text draws no tabs
			code.text = (d.format == "raw" and
					snippet(d.p, "raw", d.use, false) or ("-- Compact\n" ..
					snippet(d.p, "compact", d.use, false) .. "\n-- Table\n" ..
					snippet(d.p, "table", d.use, false))):gsub("\t", "    ")
		end
	end
	local function play_now()
		show_code()
		dirty = false
		last = api.get_time_us()
		wait_us = math.max(150000, gen.chain(d.p, RATE) / RATE * 500000)
		M.safe.play(d.p)
	end
	local function changed()
		dirty = true
	end
	tick()
	state.on_update = function()
		if dirty and api.get_time_us() - last > wait_us then
			play_now()
		end
	end

	-- The sliders, in a view of its own
	local sliders = {}
	local updating = false
	local function show_values()
		updating = true
		for _, sl in ipairs(sliders) do
			local dd = sl.def
			sl.slider.value = (d.p[dd[1]] - dd[2]) / (dd[3] - dd[2])
			sl.value.text = string.format("%.3f", d.p[dd[1]])
		end
		d.wave_dropdown_set(d.p.wave)
		updating = false
	end
	local function set_sound(p, what)
		d.p = p
		show_values()
		play_now()
		say(what .. ": " .. gen.pack(p))
	end

	-- The generators, sfxr's seven, then mutate and random
	local gens = row()
	local gens2 = row()
	for i, name in ipairs(gen.PRESETS) do
		button(i <= 4 and gens or gens2, name, function()
			d.seed = d.seed + 1
			set_sound(gen.preset(name, d.seed), name)
		end)
	end
	button(gens2, "mutate", function()
		d.seed = d.seed + 1
		set_sound(gen.mutate(d.p, d.seed), "mutated")
	end)
	button(gens2, "random", function()
		d.seed = d.seed + 1
		set_sound(gen.random(d.p.wave, d.seed), "random")
	end)
	local wave_row = row()
	local waves = {}
	for i, w in ipairs(gen.WAVES) do
		waves[i] = {w, w}
	end
	local dropdown = ui_utils.dropdown(wave_row, waves, d.p.wave, function(w)
		if updating then
			return
		end
		d.p.wave = w
		changed()
	end, {label = "Wave"})
	function d.wave_dropdown_set(w)
		for i, name in ipairs(gen.WAVES) do
			if name == w then
				dropdown:SetSelection(i - 1)
			end
		end
	end
	button(wave_row, "Play", play_now)

	local view = col:CreateChild("ScrollView")
	view:SetStyleAuto()
	view.scrollBarsAutoVisible = true
	local page = view:CreateChild("UIElement")
	page:SetLayout(LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	view.contentElement = page
	view:SetFixedSize(360, math.min(260,
			math.max(120, magic.ui.root.height - 330)))
	for _, def in ipairs(gen.PARAMS) do
		local r = row(page)
		r:SetFixedHeight(20)
		text(r, def[1], 110)
		local slider = r:CreateChild("Slider")
		slider:SetStyleAuto()
		slider.range = 1
		slider:SetFixedSize(150, 16)
		local value = text(r, "", 50)
		local sl = {def = def, slider = slider, value = value}
		sliders[#sliders + 1] = sl
		magic.SubscribeToEvent(slider, "SliderChanged", function(_, _, data)
			if updating then
				return
			end
			d.p[def[1]] = def[2] + data:GetFloat("Value") * (def[3] - def[2])
			value.text = string.format("%.3f", d.p[def[1]])
			changed()
		end)
	end

	-- The export row
	local ex = row()
	button(ex, "Save WAV", function()
		local name = "blip_" .. gen.pack(d.p):sub(7, 14) .. ".wav"
		local path, why = api.save_file(name, M.safe.wav(d.p))
		-- The name alone: the whole path does not fit the window
		say(path and ("saved " .. name) or ("not saved: " .. tostring(why)))
	end)
	ui_utils.dropdown(ex, FORMATS, d.format, function(v)
		d.format = v
		show_code()
	end)
	ui_utils.dropdown(ex, SNIPPET_USES, d.use, function(v)
		d.use = v
		show_code()
	end)
	local ex2 = row()
	button(ex2, "Copy", function()
		ui_utils.copy(snippet(d.p, d.format, d.use, false))
		say("copied, " .. d.format .. ", " .. d.use)
	end)
	button(ex2, "Copy for the files", function()
		ui_utils.copy(snippet(d.p, d.format, d.use, true))
		say("copied for blip_gen.lua and blip_mix.lua, " .. d.format ..
				", " .. d.use)
	end)
	button(ex2, "Save the files", function()
		local saved = {}
		for _, f in ipairs({"blip_gen.lua", "blip_mix.lua"}) do
			local path = api.save_file(f, api.read_extension_file(f))
			saved[#saved + 1] = path and f or (f .. " not saved")
		end
		say("saved " .. table.concat(saved, ", "))
	end)

	-- The imports: an .sfs picked, or jsfxr's string or JSON pasted
	local im = row()
	local picking = false
	button(im, "Import .sfs", function()
		picking = api.pick_file(".sfs")
	end)
	local edit = im:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.textCopyable = true
	edit.textSelectable = true
	edit:SetFixedSize(150, 26)
	local function imported(p, dropped, from)
		if not p then
			say("not imported from " .. from .. ": " .. tostring(dropped))
			return
		end
		set_sound(p, "imported from " .. from)
		status.text = status.text .. "\nClose to " .. from ..
				"'s sound, not the same" .. (#dropped > 0 and
				("; dropped " .. table.concat(dropped, ", ")) or "")
	end
	button(im, "Import jsfxr", function()
		local p, dropped = import.text(edit:GetText())
		imported(p, dropped, "jsfxr")
	end)
	local on_update = state.on_update
	state.on_update = function()
		on_update()
		if picking then
			local name, data = api.picked_file()
			if name then
				picking = false
				local p, dropped = import.sfs(data)
				imported(p, dropped, "sfxr")
			elseif data then
				picking = false
				say("no file: " .. tostring(data))
			end
		end
	end

	status = text(col, "")
	status:SetFixedWidth(360)
	if code_col then
		-- As tall as the controls beside it: a horizontal layout gives a
		-- child with no fixed height the window's. As wide as the room
		-- beside them allows, 360 to 720 (the controls' 360, the window's
		-- borders and spacing, and a margin take 460)
		code_col:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
		text(code_col, "Code for the sound, as Copy makes it")
		local code_view = code_col:CreateChild("ScrollView")
		code_view:SetStyleAuto()
		code_view.scrollBarsAutoVisible = true
		code_view:SetFixedWidth(math.max(360, math.min(720, ui_w - 460)))
		code = code_view:CreateChild("Text")
		code:SetStyleAuto()
		code_view.contentElement = code
	end
	show_values()
	show_code()
	log:info("designer shown")
end

-- The launch tile's way in (launcher/init.lua); params as a server's
-- packet would be
function M.on_untrusted_launch(request)
	open_designer()
end

return M
-- vim: set noet ts=4 sw=4:
