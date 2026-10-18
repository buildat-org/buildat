-- Buildat: extensions/luanti_client/settings.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The extension's own settings ([EXT_SETTINGS]), in
-- <user>/luanti_client/settings.json: the render mode, the view range,
-- the view bobbing amount, the player name and the last address. Read at
-- load; the BUILDAT_* environment variables stay one-run overrides for the
-- harness (init.lua reads those first). The screen is show(), a trusted
-- menu on the UI stack: back pops it, no server behind it.
--
-- The key bindings are init.lua's table, resolved by the client's key
-- store at load (apply_keys), and the editor is the one apps/vanilla
-- shares (res/key_editor.lua).

local M = {}

local log = buildat.Logger("luanti_client/settings")
local uistack = require("buildat/core/uistack")
local ui_utils = require("buildat/extension/ui_utils")
local magic = require("buildat/core/urho3d")
-- The engine's constants come from magic in the sandbox
local KEY_ESCAPE =
	magic.KEY_ESCAPE

-- The JSON reader and writer the network extension carries
local network = require("buildat/core/network")
local json = {parse = network.parse_json, write = network.write_json}

-- In the extension's own storage: <user>/luanti_client/settings.json
local path = "settings.json"

-- The initial player name is made up once, two words ([BOX_PLAYTEST_2]
-- 4): every player called "buildat" on a public server is a name taken
local ADJECTIVES = {"quiet", "bright", "swift", "mossy", "amber", "brave",
		"clever", "dusty", "eager", "gentle", "hardy", "jolly", "keen", "lucky",
		"merry", "nimble", "plain", "rusty", "sunny", "witty"}
local NOUNS = {"otter", "heron", "badger", "finch", "lynx", "marten", "newt",
		"osprey", "pike", "raven", "stoat", "tern", "vole", "wren", "beaver",
		"crane", "dace", "elk", "fox", "grouse"}
local function random_name()
	local a, n = buildat.random_bytes(2):byte(1, 2)
	return ADJECTIVES[a % #ADJECTIVES + 1] .. "-" .. NOUNS[n % #NOUNS + 1]
end

M.DEFAULTS = {mode = "unlit", view_range = 120, view_bobbing = 1,
		shoulder = 0, name = random_name(), address = "localhost:30000",
		-- What was typed in the server list's filter last time: a player
		-- filters for the same server every time ([BOX_PLAYTEST_2] 13b)
		server_filter = "", keys = {},
		-- Luanti's touchscreen_sensitivity ([TOUCH_LOOK_SETTING])
		touch_sensitivity = 0.2,
		-- F5's level, 0 off, 1 basic, 2 full ([DEBUG_INFO_SETTING])
		debug_info = 0}

-- The bindings table, for the screen's "Key bindings..." row; init.lua
-- sets it
M.bindings = nil

function M.load()
	local out = {}
	for k, v in pairs(M.DEFAULTS) do
		out[k] = type(v) == "table" and {} or v
	end
	local text = buildat.storage_read(path)
	if text then
		local data = json.parse(text)
		for k, _ in pairs(M.DEFAULTS) do
			if data and data[k] ~= nil and type(data[k]) == type(M.DEFAULTS[k]) then
				out[k] = data[k]
			end
		end
	end
	return out
end

function M.save(settings)
	local ok, err = buildat.storage_write(path, json.write(settings, true))
	if not ok then
		log:warning("cannot write "..path..": "..tostring(err))
		return false
	end
	return true
end

-- **The keys are the client's key store's** ([LAUNCH_MENU_V2] step 3),
-- as the app "luanti_client", its common actions under the shared names.
-- The engine's own rows are the client's keys, listed and not bindable
-- here. A "keys" map left in settings.json from before is moved into the
-- store once.
-- simplified: its own app beside vanilla's rather than one "Luanti" app:
-- the two tables differ ("fast" is a held key here and a toggle there);
-- the shared names are what binds both at once
local editor = buildat.run_extension_file("res/key_editor.lua")
local KEY_APP = "luanti_client"
local SHARED = {forward = "move.forward", back = "move.back",
	left = "move.left", right = "move.right", jump = "jump",
	sneak = "sneak", fast = "sprint", fly = "fly", noclip = "noclip",
	camera = "camera", zoom = "zoom", chat = "chat",
	inventory = "inventory", drop = "drop", hud = "hud", menu = "menu"}
local ENGINE = {screenshot = true, profiler = true, fullscreen = true}
local function bindable(b)
	return b.default_key ~= nil and not ENGINE[b.action]
end
function M.apply_keys(bindings)
	editor.declare(magic, KEY_APP, "Luanti client", bindings, bindable,
			SHARED)
	local s = M.load()
	if type(s.keys) == "table" and next(s.keys) then
		buildat.set_app_keys(KEY_APP, s.keys)
		s.keys = nil
		M.save(s)
		log:info("key bindings moved from settings.json to the key store")
		editor.declare(magic, KEY_APP, "Luanti client", bindings, bindable,
				SHARED)
	end
end

-- The shared editor over the bindings table; a change goes to the
-- store. on_back is what the back row does.
function M.show_keys(bindings, on_back)
	return editor.draw{magic = magic, uistack = uistack, ui_utils = ui_utils,
			bindings = bindings, bindable = bindable,
			save = function()
				editor.store(KEY_APP, bindings, bindable)
			end,
			on_back = on_back or function() end}
end

-- The name a join went through with, kept on the server's row in the
-- network extension's address store ([BOX_PLAYTEST_2] 4); the connect
-- screen fills it in when that server is picked again. Here rather than
-- in init.lua's session callback, which is at Lua's 60-upvalue line.
function M.remember_server_name(host, port, name)
	local uri = "udp://" .. host .. ":" .. port
	local ok = require("buildat/core/network").set_address_name(uri, name)
	log:info("player name " .. name .. (ok and " kept for " or " not kept for ") .. uri)
end

-- **Look sensitivity on a touchscreen** ([TOUCH_LOOK_SETTING]): a row
-- of the settings screen and the pause menu while the touch controls are
-- up (M.touch, res/touch.lua's, set by init.lua), and applied to them.
-- simplified: steps in a dropdown, as every other row, not Luanti's slider
M.SENSITIVITIES = {0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1}
function M.add_sensitivity(menu, s)
	if not M.touch then
		return
	end
	local list = {}
	for i, v in ipairs(M.SENSITIVITIES) do
		list[i] = {tostring(v), v}
	end
	menu:add_dropdown("Look sensitivity", list, s.touch_sensitivity,
			function(v)
		s.touch_sensitivity = v
		M.save(s)
		if M.touch then
			M.touch.sensitivity = v
		end
		log:info("touch look sensitivity " .. v)
	end)
end

local MODES = {"unlit", "shadows", "pbr"}
local RANGES = {60, 120, 200, 300, 400}

-- The screen: every row changes its value and saves; back pops
function M.show()
	local s = M.load()
	local root = uistack.main:push({desc = "luanti_client settings"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Luanti client settings"
	local function labeled_edit(label, value)
		local text = menu.window:CreateChild("Text")
		text:SetStyleAuto()
		text.text = label
		local edit = menu.window:CreateChild("LineEdit")
		edit:SetStyleAuto()
		-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
		edit.textCopyable = true
		edit.textSelectable = true
		edit:SetFixedHeight(26)
		edit.minWidth = 300
		edit:SetText(value or "")
		return edit
	end
	local name_edit = labeled_edit("Player name", s.name)
	local address_edit = labeled_edit("Last address", s.address)
	local rows = {}
	local function redraw_rows()
		rows.bob:GetChild("ButtonText"):SetText("View bobbing: "..
				(s.view_bobbing ~= 0 and "on" or "off"))
		rows.shoulder:GetChild("ButtonText"):SetText(
				"Third person: "..(s.shoulder ~= 0 and "over the shoulder"
				or "centred"))
	end
	local function save()
		s.name = name_edit:GetText()
		s.address = address_edit:GetText()
		M.save(s)
		redraw_rows()
	end
	menu:add_dropdown("Render mode (next session)", MODES, s.mode, function(v)
		s.mode = v
		save()
	end)
	local ranges = {}
	for i, n in ipairs(RANGES) do
		ranges[i] = {tostring(n), n}
	end
	menu:add_dropdown("View range (next session)", ranges, s.view_range,
			function(v)
		s.view_range = v
		save()
	end)
	M.add_sensitivity(menu, s)
	menu:add_dropdown("Debug info (F5)", {{"Off", 0}, {"Basic", 1},
			{"Full", 2}}, s.debug_info, function(v)
		s.debug_info = v
		save()
	end)
	rows.bob = menu:add("", function()
		s.view_bobbing = s.view_bobbing ~= 0 and 0 or 1
		save()
	end)
	rows.shoulder = menu:add("", function()
		s.shoulder = s.shoulder ~= 0 and 0 or 1
		save()
	end)
	redraw_rows()
	if M.bindings then
		menu:add("Key bindings...", function()
			save()
			M.show_keys(M.bindings)
		end)
	end
	menu:add("Save", save)
	menu:add("Back", function()
		save()
		uistack.main:pop(root)
	end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			save()
			uistack.main:pop(root)
			log:info("settings: closed")
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
	-- What a check waits for
	log:info("settings: the screen shown")
end

-- The pause menu ([LUANTI_PAUSE]), as vanilla's apps/vanilla pause.lua
-- is: a screen on the UI stack over the session, which holds the world
-- as any screen over it does (init.lua's screen_above). Escape and a
-- click off it are Continue.
-- o: {bindings, view = world.lua's, open_chat(), leave()}
-- simplified: the sound and render scale steps are copies of vanilla's,
-- which is served to older clients and cannot require a shared one
local SCALES = {1, 0.75, 0.67, 0.5, 0.33, 0.25}
function M.show_pause(o)
	local root = uistack.main:push({desc = "luanti_client pause"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	local menu = ui_utils.vertical_menu(root, {min_width = 360})
	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Paused"
	local function close()
		uistack.main:pop(root)
		log:info("pause: closed")
	end
	menu:add("Continue playing", close, true)
	menu:add("Key bindings", function()
		close()
		M.show_keys(o.bindings, function() M.show_pause(o) end)
	end)
	menu:add("Chat...", function()
		close()
		o.open_chat()
	end)
	-- The player's ear, the client's preference: muted, or 0 dB down to
	-- -30 in 6 dB steps ([VOLUME_LAW])
	local sounds = {{"muted", "muted"}}
	for db = 0, -30, -6 do
		sounds[#sounds + 1] = {(ui_utils.safe or ui_utils).db_text(db), db}
	end
	local mute, db = buildat.get_sound()
	menu:add_dropdown("Sound", sounds, mute and "muted" or db, function(v)
		buildat.set_sound(v == "muted", v == "muted" and 0 or v)
	end)
	-- The 3D at a share of the window's pixels, or the client's own choice
	local scales = {{"automatic", "auto"}}
	local now, auto = buildat.get_render_scale()
	local scale = auto and "auto" or nil
	for _, v in ipairs(SCALES) do
		scales[#scales + 1] = {math.floor(v * 100 + 0.5) .. " %", v}
		if not auto and math.abs(v - now) < 0.005 then
			scale = v
		end
	end
	menu:add_dropdown("Render scale", scales, scale, function(v)
		buildat.set_render_scale(v)
	end)
	-- The settings' view range, now and for the next session.
	-- simplified: the server's own limit is not known to the client (Luanti
	-- sends none); past what it sends there is just fog
	local s = M.load()
	local ranges = {}
	for i, n in ipairs(RANGES) do
		ranges[i] = {tostring(n), n}
	end
	menu:add_dropdown("View range", ranges, s.view_range, function(v)
		s.view_range = v
		M.save(s)
		o.view:set_far_clip(v)
		log:info("view range " .. v .. ", saved")
	end)
	-- [FOV_SETTING] The user's, vanilla's too (its game settings window)
	local fov = buildat.get_preference("fov.luanti") or 72
	local fovs = {}
	for _, v in ipairs({60, 66, 72, 80, 90, 100, 110, 120}) do
		fovs[#fovs + 1] = {v .. " degrees", v}
	end
	menu:add_dropdown("Field of view", fovs, fov, function(v)
		buildat.set_preference("fov.luanti", v)
		o.view.set_base_fov(v)
		log:info("field of view " .. v)
	end)
	M.add_sensitivity(menu, s)
	menu:add("Settings...", function()
		close()
		M.show()
	end)
	-- [DISCUSS_SERVER]: a server picked off Luanti's list, its thread on a
	-- Hearth; the client says whether there is one to go to (a Starport
	-- ID logged in, a Hearth recommended). The label says the place goes.
	local origin = M.origin
	if origin and buildat.can_discuss_this_server(origin) then
		menu:add("Discuss (leave server)", function()
			close()
			o.leave(true)
			local ok, why = buildat.discuss_this_server(origin)
			if not ok then
				ui_utils.show_message_dialog("Not discussed: " .. tostring(why))
			end
		end)
	end
	menu:add("Leave the game", function()
		close()
		o.leave()
	end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			close()
			return true
		end
	end)
	-- What a check waits for
	log:info("pause: the menu shown")
	return root
end

return M
-- vim: set noet ts=4 sw=4:
