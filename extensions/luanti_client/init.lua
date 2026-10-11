-- Buildat: extension/luanti_client/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- A Luanti client for buildat: connect to an unmodified Luanti server
-- and do the client's side of its protocol.
--
--   $ bin/buildat -m luanti_client
--
-- This is where it is at: the connection, the login and a status screen that
-- says what the server sent. Rendering the world, formspecs, the HUD and input
-- come next; see doc/luanti_client.txt.
local log = buildat.Logger("luanti_client")
local magic = require("buildat/extension/urho3d")
-- The engine's constants come from magic in the sandbox; globals of this
-- file's own environment, since as locals they took init.lua's big
-- functions past LuaJIT's 60 upvalues
HA_CENTER, HA_LEFT, HA_RIGHT, KEY_1, KEY_8, KEY_A, KEY_C,
		KEY_CTRL, KEY_D, KEY_ESCAPE, KEY_F1, KEY_F11, KEY_F12, KEY_F2, KEY_F3,
		KEY_F5, KEY_F10, KEY_H, KEY_I, KEY_K, KEY_Q, KEY_S, KEY_SHIFT,
		KEY_SPACE, KEY_T, KEY_V, KEY_W, KEY_Z, LM_HORIZONTAL, LM_VERTICAL,
		MOUSEB_LEFT, MOUSEB_MIDDLE, MOUSEB_RIGHT, VA_CENTER,
		VA_TOP =
	magic.HA_CENTER, magic.HA_LEFT, magic.HA_RIGHT, magic.KEY_1,
	magic.KEY_8, magic.KEY_A, magic.KEY_C, magic.KEY_CTRL, magic.KEY_D,
	magic.KEY_ESCAPE, magic.KEY_F1, magic.KEY_F11, magic.KEY_F12,
	magic.KEY_F2, magic.KEY_F3, magic.KEY_F5, magic.KEY_F10, magic.KEY_H,
	magic.KEY_I, magic.KEY_K, magic.KEY_Q, magic.KEY_S, magic.KEY_SHIFT,
	magic.KEY_SPACE, magic.KEY_T, magic.KEY_V, magic.KEY_W, magic.KEY_Z,
	magic.LM_HORIZONTAL, magic.LM_VERTICAL, magic.MOUSEB_LEFT,
	magic.MOUSEB_MIDDLE, magic.MOUSEB_RIGHT,
	magic.VA_CENTER, magic.VA_TOP
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local srp = buildat.run_extension_file("srp.lua")
local engine_test = buildat.run_extension_file("engine_test.lua")
local luanti = buildat.run_extension_file("client.lua")
-- The extension's settings file ([EXT_SETTINGS]); the BUILDAT_* variables
-- below stay one-run overrides
local settings = buildat.run_extension_file("settings.lua")
local SETTINGS = settings.load()
-- View bobbing as official's ([VIEW_BOB]), the module both clients share;
-- BUILDAT_VIEW_BOBBING is the amount for a run (the shooters' 0), 1 else
local camera_motion = buildat.run_extension_file("res/camera_motion.lua")
local VIEW_BOBBING = tonumber(buildat.get_env("BUILDAT_VIEW_BOBBING") or "") or SETTINGS.view_bobbing
local world = buildat.run_extension_file("world.lua")
local nodedef = buildat.run_extension_file("nodedef.lua")
local media = buildat.run_extension_file("media.lua")
local player = buildat.run_extension_file("player.lua")
local texmod = buildat.run_extension_file("res/texmod.lua")
local itemdef = buildat.run_extension_file("itemdef.lua")
local inventory = buildat.run_extension_file("inventory.lua")
local objmesh = buildat.run_extension_file("objmesh.lua")
local b3dmesh = buildat.run_extension_file("b3dmesh.lua")
local luanti_hud = buildat.run_extension_file("res/hud.lua")
luanti_hud.draw = buildat.run_extension_file("res/hud_draw.lua")
-- On the HUD module's table rather than a local of its own: the connect
-- callback below is at Lua's 60-upvalue line ([EXT_HUD_PARITY])
luanti_hud.minimap = buildat.run_extension_file("res/minimap.lua")
luanti_hud.hotbar = buildat.run_extension_file("res/hotbar.lua")
local sounds = buildat.run_extension_file("res/sounds.lua")
local formspec = buildat.run_extension_file("res/formspec.lua")
local formspec_ui = buildat.run_extension_file("res/formspec_ui.lua")
local objects = buildat.run_extension_file("objects.lua")
local M = {safe = nil}

-- BUILDAT_LUANTI_ADDRESS is for scripted runs (bin/buildat -c ...),
-- which cannot easily clear a text field
local DEFAULT_ADDRESS = buildat.get_env("BUILDAT_LUANTI_ADDRESS") or SETTINGS.address
-- [LUANTI_LISTED_JOIN]: a server is listed, for the Discuss buttons,
-- when its address is on Luanti's official list as last fetched -- the
-- dialog's Official tab this run, or the launcher's serverlist cache --
-- whichever tab or field it was joined from.
-- simplified: the dialog's fetch is kept for the run only; the cache
-- has the busiest servers only
-- listed(address) -> {name, game} or nil; game: the list's game id
local official_names = {}
local function listed(address)
	if official_names[address] then
		return official_names[address]
	end
	local ok, sl = pcall(require, "buildat/extension/serverlist")
	for _, r in ipairs(ok and type(sl) == "table" and sl.servers and
			sl.servers() or {}) do
		if r.address == address then
			return {name = r.name, game = r.game}
		end
	end
end
local DEFAULT_NAME = buildat.get_env("BUILDAT_LUANTI_NAME") or SETTINGS.name
-- The PBR checkbox's starting state. A scripted run has to hit the box by
-- pixel coordinates otherwise, and a miss looks like the shader not working
-- rather than like a missed click.
-- Which of the three rendering modes to draw in: "unlit", "shadows" or "pbr".
-- Unset means this client's own default, which is unlit; the numbers keep
-- working for whatever already passes them, 0 having been the unlit path and
-- 1 the PBR one before either had a name. builtin/luanti reads the same
-- variable with the same answers, its own default being pbr -- see
-- [RENDER_MODES] in doc/plan/rendering_plan.md.
local DEFAULT_MODE = (function()
	local v = buildat.get_env("BUILDAT_LUANTI_PBR") or ""
	if v == "" then
		return SETTINGS.mode
	elseif v == "0" then
		return "unlit"
	elseif v == "1" then
		return "pbr"
	elseif v == "unlit" or v == "shadows" or v == "pbr" then
		return v
	end
	log:warning("BUILDAT_LUANTI_PBR=\"" .. v .. "\" is not a mode; " ..
			"drawing unlit. Wanted unlit, shadows or pbr")
	return "unlit"
end)()

-- How far the camera sees, and how far out blocks are kept, in nodes. The
-- client asks the server for blocks by the same distance; see
-- WANTED_RANGE_BLOCKS in client.lua.
local FAR_CLIP = SETTINGS.view_range
local DROP_DISTANCE = 260
-- Degrees of look per pixel of mouse movement
local MOUSE_SENSITIVITY = 0.15

-- How far the player can reach when the item they are holding does not say,
-- which is Luanti's own default
local POINT_RANGE = 4

-- How long the dig button has to be held before it hits a pointed object
-- again, which is Luanti's object_hit_delay
local OBJECT_HIT_DELAY = 0.2

-- How many of the player's main slots the hotbar shows. Luanti's own default,
-- and what the number keys reach.
-- The textures Luanti's own client ships rather than receiving: a game names
-- them and nothing arrives for them. blank.png is the one that matters --
-- what a node whose shape is drawn by something else wears -- and the unknown
-- ones are what a client puts where it has nothing.
local BUILTIN_TEXTURES = {
	["blank.png"] = "luanti_client/res/blank.png",
	["unknown_node.png"] = "luanti_client/res/placeholder.png",
	["unknown_item.png"] = "luanti_client/res/placeholder.png",
	["unknown_object.png"] = "luanti_client/res/placeholder.png",
	-- The crack that grows over a node being dug is the client's own, not
	-- the game's: no server sends one. This is Luanti's, and res/LICENSE
	-- says so.
	["crack_anylength.png"] = "luanti_client/res/crack_anylength.png",
}

-- How many frames the crack strip holds is worked out from the image, which
-- is what "anylength" in its name means; this is what to fall back on if it
-- cannot be read, and is Luanti's own default.
local CRACK_FRAMES_DEFAULT = 5

-- What time it is, whatever the server says: how the sky at dawn or at night
-- gets looked at without waiting for the world to turn, or asking a server for
-- the privilege of setting its clock. BUILDAT_LUANTI_FORCE_DAY, in
-- daynight_ratio() below, is the same kind of thing for the light.
local FORCE_TIME = tonumber(buildat.get_env("BUILDAT_LUANTI_FORCE_TIME") or "")

local HOTBAR_SLOTS = 8

-- Media files are asked for in batches, so that one REQUEST_MEDIA does not
-- turn into hundreds of split chunks in one go
local MEDIA_PER_REQUEST = 200
-- The voxel registry is rebuilt when the media that was asked for has all
-- arrived, and after this long with nothing arriving whether it has or not: a
-- file the server never sends must not hold every other texture back forever
local MEDIA_WAIT_S = 15

-- Where the server's media goes. The whole directory is one resource dir and
-- the files inside it are addressed as "<server>/<name>", so two servers with
-- a same-named texture do not collide.
-- It is the extension's cache (buildat.cache_read and cache_write take
-- names under it).
local MEDIA_ROOT = buildat.get_cache_path().."/luanti_client"

-- What a form calls the inventory it is a form *of*: a chest writes
-- list[current_name;main;...] and a furnace list[context;src;...]. Luanti
-- treats the two as the same thing (guiFormSpecMenu.cpp: `location ==
-- "context" || location == "current_name"`), and a game that uses only one
-- of them is common enough that missing either means its slots cannot be
-- filled at all.
local FORM_OWN_INVENTORY = {["current_name"] = true, ["context"] = true}

-- The keys, in one place. move() and the key handler read this table and the
-- pause menu's "Key bindings" dialog lists it, so a binding cannot be in the
-- code and missing from the list -- which is the whole point of the table
-- rather than of the dialog. `name` is what the dialog shows, because a key
-- constant is not something to put in front of a player.
--
-- The keys here are the defaults; the client's key store has the say
-- (settings.apply_keys), and the F10 to F12 rows are the client's own keys.
local BINDINGS = {
	{action = "forward", key = KEY_W, name = "W", what = "Walk forward"},
	{action = "back", key = KEY_S, name = "S", what = "Walk back"},
	{action = "left", key = KEY_A, name = "A", what = "Walk left"},
	{action = "right", key = KEY_D, name = "D", what = "Walk right"},
	{action = "jump", key = KEY_SPACE, name = "Space", what = "Jump"},
	-- The same keys as apps/vanilla's, so one scripted episode drives both
	{action = "sneak", key = KEY_SHIFT, name = "Shift", what = "Sneak"},
	{action = "fast", key = KEY_CTRL, name = "Ctrl", what = "Move fast"},
	{action = "fly", key = KEY_K, name = "K", what = "Fly on and off"},
	{action = "camera", key = KEY_C, name = "C",
			what = "Camera: first person, behind, in front"},
	{action = "zoom", key = KEY_Z, name = "Z",
			what = "Zoom while held (the zoom privilege)"},
	{action = "fog", key = KEY_F3, name = "F3", what = "Fog on and off"},
	{action = "minimap", key = KEY_V, name = "V", what = "Minimap modes"},
	{action = "screenshot", key = KEY_F12, name = "F12",
			what = "A screenshot (the engine's)"},
	{action = "profiler", key = KEY_F10, name = "F10",
			what = "The engine's profiler on and off"},
	{action = "fullscreen", key = KEY_F11, name = "F11",
			what = "Fullscreen on and off (the engine's)"},
	{action = "noclip", key = KEY_H, name = "H",
			what = "Through walls on and off"},
	{action = "chat", key = KEY_T, name = "T", what = "Say something"},
	{action = "inventory", key = KEY_I, name = "I", what = "Inventory"},
	{action = "drop", key = KEY_Q, name = "Q",
			what = "Drop what is held - with Ctrl one of it"},
	{action = "hotbar", first = KEY_1, last = KEY_8, name = "1 - 8",
			what = "Pick a hotbar slot"},
	{action = "hud", key = KEY_F1, name = "F1", what = "The HUD on and off"},
	{action = "chatlog", key = KEY_F2, name = "F2",
			what = "The chat on and off"},
	{action = "debug", key = KEY_F5, name = "F5",
			what = "The debug line on and off"},
	{action = "menu", key = KEY_ESCAPE, name = "Escape",
			what = "Close what is open - or this menu"},
	-- Listed for the player's sake; the code for these is the mouse
	-- handling rather than a key lookup
	{action = "dig", name = "Left mouse", what = "Dig, or hit"},
	{action = "place", name = "Right mouse", what = "Place, or use"},
	{action = "wield", name = "Mouse wheel", what = "Pick a hotbar slot"},
}

-- Whether cancelling the connect dialog quits the client: it does when this
-- extension is the client's whole reason for running, and does not when
-- buildat's menu is underneath. See M.boot() and M.launch.
-- On SETTINGS rather than a local of its own: the session's callbacks
-- are at Lua's 60-upvalue line
SETTINGS.cancel_exits = true

-- action -> the entry, for the code that asks "which key is this?"
local BIND = {}
for _, b in ipairs(BINDINGS) do
	BIND[b.action] = b
	b.default_key = b.key
	b.default_name = b.name
end
-- What the settings say instead ([EXT_SETTINGS]), and the table for
-- the settings screen's editor
settings.apply_keys(BINDINGS)
settings.bindings = BINDINGS
local media_root_added = false

-- Luanti's day/night ratio, from its daynightratio.h: 0.175 at night, 1.0 in
-- the day, with a ramp between 4375 and 6125 and the same one mirrored around
-- 12000 for the evening.
local DAYNIGHT_RAMP = {
	{4375, 0.175}, {4625, 0.175}, {4875, 0.250}, {5125, 0.350},
	{5375, 0.500}, {5625, 0.675}, {5875, 0.875}, {6125, 1.000},
}

-- The light the sky has before the sun is up ([DAWN_LIGHT]):
-- res/sky_model.lua's predawn, opening at -18 degrees (where the stretched
-- day puts 4:00) rather than vanilla's -24, which meets its dusk band
local sky_model = buildat.run_extension_file("res/sky_model.lua")
local PREDAWN_LOW = -0.309

-- override is what a server said the light is whatever the time is, or nil.
-- BUILDAT_LUANTI_FORCE_DAY wins over it: a scripted run asked for daylight
-- and a game that overrides the ratio underground would take it away again.
local function daynight_ratio(time_of_day, override, height)
	-- A scripted run cannot wait for morning, and a screenshot of the world
	-- at night says little about how it looks
	-- An environment variable that is set but empty is a variable that is
	-- not set: a script that passes it through unconditionally passes an
	-- empty one, and "" is true in Lua
	local force = buildat.get_env("BUILDAT_LUANTI_FORCE_DAY")
	if force and force ~= "" then
		return 1.0
	end
	if override then
		return override
	end
	local t = time_of_day % 24000
	if t > 12000 then
		t = 24000 - t
	end
	local ratio = 1.0
	if t <= DAYNIGHT_RAMP[2][1] then
		ratio = DAYNIGHT_RAMP[1][2]
	else
		for i = 2, #DAYNIGHT_RAMP do
			if DAYNIGHT_RAMP[i][1] > t then
				local a, b = DAYNIGHT_RAMP[i - 1], DAYNIGHT_RAMP[i]
				local f = (t - a[1]) / (b[1] - a[1])
				ratio = a[2] + f * (b[2] - a[2])
				break
			end
		end
	end
	return math.max(ratio, sky_model.predawn(height, PREDAWN_LOW))
end

local function labeled_edit(parent, label, value)
	local text = parent:CreateChild("Text")
	text:SetStyleAuto()
	text.text = label
	-- Fixed, so a tall column's spare room does not go into the labels
	text:SetFixedHeight(text.height)
	local edit = parent:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	-- Fixed, not min: a column beside a tall list would stretch it
	edit:SetFixedHeight(26)
	edit.minWidth = 300
	edit:SetText(value or "")
	return edit
end

local function split_address(address)
	local host, port = address:match("^%[(.*)%]:(%d+)$")
	if not host then
		host, port = address:match("^([^:]+):(%d+)$")
	end
	if not host then
		return address, 30000
	end
	return host, tonumber(port)
end

-- Defined below; a session that ends before any of the game has arrived goes
-- back to it rather than closing the client
local show_connect_dialog

-- The screen that shows what the client is doing, and drives it every frame
-- mode: which of unlit, shadows and pbr to draw the world in; see the connect
-- dialog, where it is chosen, and world.lua for what it changes
-- origin: {name, address} of a server picked off Luanti's list, for the
-- pause menu's Discuss ([DISCUSS_SERVER]); on settings' table, as the
-- session callback below is at Lua's 60-upvalue line
local function show_client(host, port, name, password, mode, origin)
	settings.origin = origin
	-- A click on nothing over the world is the game's, not Back
	local root = uistack.main:push({desc="luanti_client", tap_outside = false})
	-- A world is on the screen from here on: a caught error is a notice
	-- line rather than a dialog, which under a session would take the
	-- mouse from the player ([MENU_ERRORS])
	if ui_utils.set_in_game then
		ui_utils.set_in_game(true)
	end
	-- Held rather than read back off the element: the sandbox hands out no
	-- resource it did not just wrap
	local style = magic.cache:GetResource(
			"XMLFile", "launch_menu/res/main_style.xml")
	root.defaultStyle = style

	-- Text in the top left corner rather than a window: the world is behind
	-- it. Under the UI's own root, like the chat below and for the same
	-- reason: the element this extension was given is only as big as what is
	-- in it, so an alignment inside it lands nowhere in particular.
	local status_text = magic.ui.root:CreateChild("Text")
	status_text.defaultStyle = style
	status_text:SetStyleAuto()
	status_text:SetAlignment(HA_LEFT, VA_TOP)
	status_text:SetPosition(8, 8)
	-- **The HUD's text under every screen** ([TOUCH_CHAT_CLUTTER]): a
	-- screen on uistack.main is a root child of priority 0, and Urho3D's
	-- sort of equals is not stable -- the pause menu was drawn under the
	-- chat
	status_text.priority = -1
	status_text.color = magic.Color(1.0, 1.0, 1.0)
	-- Hidden until F5 asks for it; see show_debug below
	status_text.visible = false

	-- What has been said, at the bottom of the screen where Luanti puts it.
	-- Under the UI's own root rather than the element this extension was
	-- given, because that one is only as big as what is in it and an
	-- alignment inside it lands nowhere in particular; taken away again when
	-- the client is left.
	local chat_text = magic.ui.root:CreateChild("Text")
	-- The style before SetStyleAuto, which is what reads it; the UI's root
	-- has none of its own
	chat_text.defaultStyle = style
	chat_text:SetStyleAuto()
	-- The top left corner, under the lines of detail, which is where a
	-- Luanti game expects it: what a game puts on the screen of its own is
	-- along the bottom, and chat down there lands on top of it. update_hud()
	-- moves it as those lines grow and when F5 takes them away.
	chat_text:SetAlignment(HA_LEFT, VA_TOP)
	chat_text:SetPosition(8, 8)
	chat_text:SetWordwrap(true)
	chat_text.color = magic.Color(1.0, 1.0, 0.9)
	chat_text.priority = -1

	-- Until the game's definitions and its media are in, the world is a field
	-- of placeholders and there is nothing worth showing: an opaque panel over
	-- all of it instead, saying how far along the loading is. A UI element is
	-- always in front of the world; the priority is what puts it behind the
	-- rest of the UI, because the lines in the corner are the detail of the
	-- same story. Removed when the loading is done, and by leave().
	local loading_panel = magic.ui.root:CreateChild("BorderImage")
	loading_panel.texture = magic.cache:GetResource(
			"Texture2D", "luanti_client/res/white.png")
	loading_panel.color = magic.Color(0.06, 0.07, 0.09)
	-- Behind the rest of the UI: a dialog -- the one that asks whether the
	-- network may be used, or the one that says why a session ended -- has to
	-- come out in front of this, and the lines in the corner are the detail
	-- of the same story. The hotbar is taken down while it is up instead.
	loading_panel.priority = -1000
	loading_panel.enabled = false
	-- The size it starts at, because the text inside is centred in it and a
	-- panel of no size centres that in the top left corner
	loading_panel.width = magic.ui.root.width
	loading_panel.height = magic.ui.root.height
	local loading_text = loading_panel:CreateChild("Text")
	loading_text.defaultStyle = style
	loading_text:SetStyleAuto()
	loading_text:SetAlignment(HA_CENTER, VA_CENTER)
	loading_text:SetTextAlignment(HA_CENTER)
	loading_text.text = "Connecting to "..host..":"..port

	-- Luanti paints a node's post_effect_color over the whole screen while the
	-- camera is inside it, which is what being under water looks like. In
	-- front of the world and behind the rest of the UI: the hotbar and the
	-- chat are not under the water.
	local tint_panel = magic.ui.root:CreateChild("BorderImage")
	tint_panel.texture = magic.cache:GetResource(
			"Texture2D", "luanti_client/res/white.png")
	tint_panel.priority = -900
	tint_panel.visible = false

	-- What the node being pointed at says about itself: its metadata's
	-- infotext, which is how a game labels a chest, a sign or a machine.
	-- Luanti draws it under the chat, a few lines at most, and takes it away
	-- with the rest of the HUD; update_hud() places it.
	local info_text = magic.ui.root:CreateChild("Text")
	info_text.defaultStyle = style
	info_text:SetStyleAuto()
	info_text:SetAlignment(HA_LEFT, VA_TOP)
	info_text:SetPosition(100, 8)
	info_text.color = magic.Color(1.0, 1.0, 1.0)
	info_text.priority = -1

	-- The crosshair, which is what says where the middle of the screen is
	-- when the mouse is captured. Two bars rather than a texture: it is two
	-- rectangles either way and this way there is no image to ship.
	local function crosshair_bar(w, h)
		local bar = magic.ui.root:CreateChild("BorderImage")
		bar.texture = magic.cache:GetResource(
				"Texture2D", "luanti_client/res/white.png")
		bar.width = w
		bar.height = h
		bar:SetAlignment(HA_CENTER, VA_CENTER)
		bar:SetPosition(0, 0)
		bar.color = magic.Color(1, 1, 1, 0.7)
		bar.enabled = false
		return bar
	end
	local crosshair = {crosshair_bar(13, 1), crosshair_bar(1, 13)}

	-- What F1, F2 and F5 turn on and off, which are the keys Luanti uses for
	-- them: the player's own HUD and the crosshair, what has been said, and
	-- the lines of detail in the corner.
	--
	-- The debug lines start hidden: a player who opens this wants to play,
	-- not to diagnose, and F5 brings them up whenever they are wanted --
	-- which the pause menu's key list says. A scripted run that wants to
	-- read them presses F5 like anyone else.
	local show_hud = true
	local show_chat = true
	-- F5's levels, as the module's ([EXT_HUD_PARITY]): 0 nothing, 1 the
	-- one-line row (the mode and where the player is, in official's
	-- words), 2 the whole block. Kept in the settings, F5's and the
	-- screen's ([DEBUG_INFO_SETTING])
	local show_debug = settings.load().debug_info
	status_text.visible = show_debug > 0
	log:info("debug info at start: " .. show_debug)

	-- A connect that fails before there is a session: said in a dialog
	-- and back to the connect screen, as a session that fails later is
	-- ([BOX_PLAYTEST_2] 2) -- a line in the corner of a screen nothing
	-- else happens on told nobody. Reached through add_line(text, true)
	-- rather than by name: the connect callback below is at Lua's
	-- 60-upvalue line.
	local function connect_failed(err)
		log:warning("Could not connect to "..host..":"..port..": "..
				tostring(err))
		chat_text:Remove()
		info_text:Remove()
		tint_panel:Remove()
		status_text:Remove()
		if loading_panel then
			loading_panel:Remove()
			loading_panel = nil
		end
		uistack.main:pop(root)
		ui_utils.show_message_dialog("Could not connect to "..host..":"..
				port..": "..tostring(err), function()
			show_connect_dialog(host..":"..port, name)
		end)
	end

	local lines = {"Luanti: "..host..":"..port}
	local function add_line(text, fatal)
		if fatal then
			return connect_failed(text)
		end
		lines[#lines + 1] = text
		while #lines > 10 do
			table.remove(lines, 2) -- Keep the address line
		end
		status_text.text = table.concat(lines, "\n")
	end

	add_line("Asking to connect...")

	-- What this connection is for, for the permission dialog's field
	-- ([NET_DESC]): the caller knows, the user still decides
	network.udp_connect(host, port, function(socket, err)
		if not socket then
			add_line(tostring(err), true)
			return
		end
		local client = luanti.new(socket, {
				name = name,
				password = password,
				on_status = add_line,
		}, log)

		-- Assigned further down, where the media store it reads the model
		-- out of exists; world.new wants the function now, so what it gets
		-- is a wrapper around whatever this holds by then
		local read_mesh
		-- Assigned with the rest of the media handling, further down; the
		-- palettes and the sky's own textures both want a texture asked for
		local media_texture
		-- How many times a texture or a model was wanted and had not arrived.
		-- An object or a form built while this went up wears a placeholder
		-- and is built again when media arrives; the rest are not: every
		-- object and the form rebuilt on every batch was a mob's model and
		-- an 80 ms form a frame on the web, the whole download long
		-- ([LUANTI_NO_WORLD])
		local media_misses = 0

		local view = world.new(magic, buildat, log, {
				far_clip = FAR_CLIP,
				mode = mode,
				read_image = buildat.read_image,
				read_mesh = function(def)
					return read_mesh and read_mesh(def) or nil
				end,
				media_texture = function(name)
					return media_texture and media_texture(name) or nil
				end,
		})

		-- Whether any of the game itself has arrived. A login that is refused
		-- is refused before the definitions come, and there is then nothing
		-- to go back to but the dialog the address was typed into; a session
		-- that ends after the game has arrived ends the client.
		local got_content = false

		-- Whether the definitions and the media are still coming in. Until
		-- they are in there is nothing worth drawing -- a world of
		-- placeholders is not the game -- so a panel covers it and says how
		-- far along it is, and the registry is free to spend the frame.
		local loading = true
		-- And then the world round the player ([JOIN_WHEN_LOADED]): the
		-- panel stays until the blocks within 2 of them are drawn, or 60 s
		-- after the first block came, as vanilla's loading screen
		local world_wait = false
		local first_block_us = nil
		local WORLD_WAIT_S = 60

		client.on_block = function(block)
			first_block_us = first_block_us or buildat.get_time_us()
			view:set_block(block)
		end

		client.on_node = function(x, y, z, param0, param1, param2)
			view:set_node(x, y, z, param0, param1, param2)
		end

		-- The server's media, and what the node definitions make of it
		local server_key = media.server_key(host, port)
		local store = media.new(buildat, log, server_key)
		-- One resource dir for all servers; see MEDIA_ROOT
		if not media_root_added then
			-- A file in it makes it: a resource dir has to exist
			buildat.cache_write("README.txt",
					"Luanti servers' media, a directory a server\n")
			buildat.add_resource_dir(MEDIA_ROOT)
			media_root_added = true
		end

		local node_defs = nil
		local node_by_name = {}
		local announced = nil
		local to_ask = {}
		-- Sound group name -> the media files in it, out of the
		-- announcement; a server asks for the group and one of its files is
		-- played
		local sound_groups = {}
		-- When the media last got anywhere: a file asked for, or a bunch
		-- arriving. The fallback below is a quiet spell rather than a fixed
		-- time after asking, because a game's whole media is tens of
		-- megabytes and takes longer than that to arrive.
		local media_progress_us = nil
		-- When the first file was asked for, until the last one is in
		local media_asked_us = nil
		local registry_stale = false

		-- Composed textures go beside the server's own files, under a name
		-- nothing the server sends can collide with: a media name is a file
		-- name and never a path.
		local COMPOSED_DIR = MEDIA_ROOT.."/"..server_key.."/composed"

		-- Expression -> the resource name it was composed under. The files
		-- outlive the run, so a second one composes nothing.
		local composed = {}
		local composed_count = 0

		local function hex_hash(s)
			return (buildat.sha1(s):gsub(".", function(c)
				return string.format("%02x", c:byte())
			end))
		end

		-- A tile's texture name -> a resource name, or nil for one that
		-- cannot be built. texmod.lua reads Luanti's modifier language and
		-- buildat.compose_image() does the pixels; a name with no modifiers
		-- in it is the file itself.
		local texmod_ctx = {
			resource = function(name)
				if not store:have_file(name) then
					-- A few names are the client's own in Luanti and no
					-- server sends them
					return BUILTIN_TEXTURES[name]
				end
				return server_key.."/"..name
			end,
			compose = function(expr, ops, size)
				local resource = composed[expr]
				if resource then
					return resource
				end
				local file = hex_hash(expr)..".png"
				resource = server_key.."/composed/"..file
				local path = COMPOSED_DIR.."/"..file
				if not buildat.cache_read(resource) then
					local ok, err = pcall(buildat.compose_image,
							{size = size, ops = ops, write = path})
					if not ok then
						log:warning("compose_image failed for \""..expr..
								"\": "..tostring(err))
						return nil
					end
					composed_count = composed_count + 1
				end
				composed[expr] = resource
				return resource
			end,
			-- The bytes of an image an expression carried itself, out of
			-- "[png:". Written beside the composed textures under a name
			-- that is its own hash, so the same image twice is one file.
			png = function(bytes)
				local file = "png_"..hex_hash(bytes)..".png"
				local resource = server_key.."/composed/"..file
				if buildat.cache_read(resource) then
					return resource
				end
				local ok, err = buildat.cache_write(resource, bytes)
				if not ok then
					log:warning("could not write "..resource..": "..
							tostring(err))
					return nil
				end
				return resource
			end,
		}

		-- The texture expression for one of a node's six faces.
		--
		-- Luanti draws a tile as up to two layers, the tile and an overlay
		-- over it, and each is drawn in a colour: its own when the game gave
		-- it one, and the node's otherwise. That is how a grass block's side
		-- is plain dirt with a green edge on top of it. Written as an
		-- expression, the two layers are a "^" chain and a colour is a
		-- [multiply, so texmod.lua does the work.
		--
		-- simplified: the node's colour is the one in its definition, not the
		-- one its paramtype2 picks out of a palette, so a node type is one
		-- colour everywhere rather than the biome's. Every palette node in
		-- this game also carries the colour it is mostly drawn in, which is
		-- why this looks right; the upgrade path is a voxel id per (node,
		-- param2) pair, which is also what a facedir needs.
		local function tile_expression(def, i, override)
			local function layer(tile)
				if not tile or tile.name == "" then
					return nil
				end
				-- A tile with a colour of its own keeps it; the override is
				-- what the voxel's param2 picked out of a palette, which
				-- stands in for the definition's own colour
				local color = tile.color or override or def.color
				if not color or (color[1] == 255 and color[2] == 255 and
						color[3] == 255) then
					return tile.name
				end
				return "("..tile.name.."^[multiply:"..
						string.format("#%02x%02x%02x", color[1], color[2],
						color[3])..")"
			end
			-- Index 7 and over is one of the node's special tiles, which is
			-- where Luanti keeps the parts of a node that are not one of
			-- its six faces: the plant of a rooted plant, and a liquid's
			-- own animated textures. They have no overlays.
			if i > 6 then
				return layer(def.special and def.special[i - 6])
			end
			local base = layer(def.tiles[i])
			if not base then
				return nil
			end
			local overlay = layer(def.overlays and def.overlays[i])
			if overlay then
				return base.."^"..overlay
			end
			return base
		end

		-- A tile whose texture is a strip of animation frames has to be cut
		-- down to one before it goes in an atlas; which frame it is on is
		-- not something this draws yet, so it is the first. How many frames
		-- there are is not in the definition -- Luanti works it out from the
		-- texture's own proportions -- so the crop asks for square cells.
		--
		-- simplified: the frame never advances, so water and lava and fire
		-- stand still. The upgrade path is one composed texture per frame
		-- and a voxel id per frame, or a shader that scrolls the atlas.
		local FIRST_FRAME = {
			key = "frame0",
			ops = {{op = "crop", grid = {1, 0}, cell = {0, 0}}},
		}

		local function resolve_tile(def, i, override)
			local expr = tile_expression(def, i, override)
			if not expr then
				return nil
			end
			local tile = i > 6 and def.special[i - 6] or def.tiles[i]
			local extra = nil
			if tile.animation and tile.animation.type == 1 then
				extra = FIRST_FRAME
			end
			return texmod.resolve(expr, texmod_ctx, extra)
		end

		-- A palette is an image a game indexes by param2 to say what colour a
		-- voxel is drawn in; Luanti stretches it to 256 entries by repeating
		-- each pixel, so a palette of n pixels is n distinct colours. What is
		-- kept here is the pixels, and the resolving of a name to an index is
		-- in world.lua where the voxel ids are.
		local palettes = {}

		local function palette_colors(name)
			if palettes[name] ~= nil then
				return palettes[name] or nil
			end
			local resource = media_texture(name)
			if not resource then
				return nil -- Not arrived yet; the registry is built again
			end
			local ok, w, h, rgba = pcall(buildat.read_image, resource)
			if not ok or w * h < 1 then
				log:warning("palette "..name.." could not be read")
				palettes[name] = false
				return nil
			end
			local colors = {}
			for i = 0, math.min(w * h, 256) - 1 do
				local r, g, b = rgba:byte(i * 4 + 1, i * 4 + 3)
				colors[#colors + 1] = {r, g, b}
			end
			palettes[name] = colors
			return colors
		end

		-- The model a "mesh" drawtype names, as the quads a voxel's shape is
		-- made of: the mesh's name and the scale it was asked for -> quads,
		-- or false for one that could not be read. Read once each; a game
		-- has a few dozen of them, two hundred definitions share them, and
		-- every voxel that faces a different way asks for the same one.
		-- The scale is part of the key because two definitions can draw one
		-- model at different sizes.
		local meshes = {}
		local meshes_read = 0

		read_mesh = function(def)
			local name = def.mesh
			if name == nil or name == "" then
				return nil
			end
			if not store:have_file(name) then
				media_misses = media_misses + 1
				return nil
			end
			local scale = def.visual_scale ~= 0 and def.visual_scale or 1
			local key = name.."@"..tostring(scale)
			local quads = meshes[key]
			if quads == nil then
				local lower = name:lower()
				-- .obj is text and .b3d is Blitz3D's chunks; the other
				-- formats Luanti takes (.x, .gltf, .glb) nothing here reads
				local read = nil
				if lower:match("%.obj$") then
					read = objmesh.parse
				elseif lower:match("%.b3d$") then
					read = b3dmesh.parse
				end
				if not read then
					meshes[key] = false
					return nil
				end
				local text = buildat.cache_read(server_key.."/"..name)
				if not text then
					meshes[key] = false
					return nil
				end
				local parsed, why, skipped = read(text)
				if not parsed or #parsed == 0 then
					log:warning("mesh "..name.." has no faces this reads"..
							(type(why) == "string" and ": "..why or ""))
					meshes[key] = false
					return nil
				end
				skipped = skipped or 0
				if skipped > 0 then
					log:info("mesh "..name..": "..skipped..
							" faces are neither triangles nor quads")
				end
				-- A material of the mesh wears the tile of the same number,
				-- which is how Luanti puts a node's tiles on one
				for _, q in ipairs(parsed) do
					q.tile = math.min(q.group, 6)
				end
				quads = objmesh.scale(parsed, scale)
				meshes[key] = quads
				meshes_read = meshes_read + 1
			end
			return quads or nil
		end

		-- The things in the world that are not nodes, by id
		local world_objects = {}

		-- What has been said, newest last, and the line being typed
		local CHAT_LINES = 8
		local chat = {}
		local chat_input = nil
		-- The key that opens chat arrives as text as well, and the line edit
		-- would get it: the dialog goes up on the next frame instead, when
		-- that text has gone nowhere
		local chat_wanted = false
		-- Assigned below, next to the rest of the chat dialog; the frame
		-- update is what puts it up
		local open_chat
		-- The pause menu, and the opener for a form this client draws for
		-- itself; both are defined further down, where their pieces are in
		-- scope
		local open_pause_menu
		local open_local_form

		-- The forms the server sends, and the one on screen
		local inventory_spec = nil
		local prepend = ""
		local detached = {}
		-- The form on the screen, res/form_session.lua's, made with the UI
		-- below; session.form is nil when there is none
		local session = nil
		local function form_on()
			return session and session.form
		end
		-- The form drawn again at the next frame: what is in it changed
		local function redraw_form()
			if session then
				session:redraw()
			end
		end
		local screen_was_above = false -- a stack screen over the session
		-- The cursor hidden for mouse look, or shown for a form, chat or a
		-- screen. **A browser holds the pointer only in relative mode**:
		-- Urho3D asks for the pointer lock with MM_RELATIVE and leaves it
		-- with anything else, where a hidden cursor is all a native window
		-- needs; the browser grants it just after a click or a key, so a
		-- click in the world asks again (MouseButtonDown below). The same
		-- as vanilla's keys.web_lock.
		local web = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
		local function mouse_look(enable, reason)
			-- A touchscreen's pointer stays: the UI takes a finger's taps
			-- only while it is shown, and the touch controls are UI
			magic.input:SetMouseVisible(not enable or settings.touch ~= nil,
					reason)
			if web then
				-- A grabbed pointer is one the UI takes no taps from
				magic.input:SetMouseMode((enable and not settings.touch) and
						magic.MM_RELATIVE or magic.MM_ABSOLUTE)
			end
		end
		-- **A lost lock pauses** ([WEB_LOCK_LOST], as vanilla's): on the web
		-- the mouse turns the view only while the browser holds the
		-- pointer, and with no lock and nothing over the game the pause
		-- menu opens; lost: at once, asked for and not given: in 0.5 s
		local lock = {was = false, unlocked_s = 0}
		-- Whether the form was drawn with a texture that had not arrived
		local form_missed = false

		-- Pointing, digging and placing
		local item_defs = nil
		local inv = nil
		-- Which hotbar slot is wielded, one-based, as the number keys set it
		local wield_index = 1
		local pointed_under, pointed_above = nil, nil
		-- The id of the object the ray hit, when it got there before any
		-- node did
		local pointed_object = nil
		local dig = nil
		local digging = false
		-- The client's own sounds ([DIG_SWING_SOUND]): the swing's phase,
		-- 3.5 a second while the dig button is held and finished after
		-- (official's Camera::step), a count for their ids, and where the
		-- last footstep was
		local own = {phase = 0, n = 0, foot = nil}
		-- 1 first person, 2 third from behind, 3 third from the front
		local camera_mode = 1
		local zoom_held = false
		local fog_on = true
		-- The bob's state for this session; the extension draws no hand, so
		-- only the camera's offset and roll are used of what it answers
		local motion = camera_motion.new()
		motion.amount = VIEW_BOBBING
		-- Time left before the held dig button hits a pointed object again;
		-- Luanti's object_hit_delay
		local hit_wait = 0

		-- Building the registry is two and a half thousand definitions with a
		-- texture expression each, and it happens while the world is already
		-- on screen: a slice a frame rather than one frame of a second and a
		-- half. registry_step is nil when nothing is being built.
		local REGISTRY_BUDGET_US = 4000
		-- Behind the loading panel there is nothing to keep smooth, and the
		-- budget is what decides how long the wait is: on a big game's
		-- definitions 4 ms a frame turned two seconds of work into fifteen
		-- of waiting
		local REGISTRY_LOADING_BUDGET_US = 50000
		local registry_step = nil
		local registry_started_us = nil
		local registry_spent_us = 0

		local function rebuild_registry()
			registry_stale = false
			if not node_defs then
				return
			end
			registry_step = view:begin_node_definitions(node_defs,
					resolve_tile, palette_colors)
			registry_started_us = buildat.get_time_us()
			registry_spent_us = 0
		end

		-- One slice, and the line when it is done
		local function step_registry()
			local t0 = buildat.get_time_us()
			local done, cubes = registry_step(loading and
					REGISTRY_LOADING_BUDGET_US or REGISTRY_BUDGET_US)
			registry_spent_us = registry_spent_us +
					(buildat.get_time_us() - t0)
			if not done then
				return
			end
			registry_step = nil
			local line = cubes.." voxel types have their own textures"..
					" ("..store:have_count().." files, "..composed_count..
					" composed, "..meshes_read.." meshes, "..
					math.floor(registry_spent_us / 1000).." ms over "..
					math.floor((buildat.get_time_us() - registry_started_us) /
					1000).." ms)"
			add_line(line)
			-- In the log as well as on the screen: this is the last thing
			-- before the world is there, which is what anything driving the
			-- client waits for
			log:info(line)
			-- A dropped node and a form's item are drawn from the registry:
			-- what was drawn before this build is drawn again
			for _, obj in pairs(world_objects) do
				obj.visual_stale = true
			end
			redraw_form()
			if loading then
				loading = false
				log:info("loading done")
				world_wait = true
				-- The minimap at the top right, official's own whether or
				-- not the game adds one, under the minimap HUD flag; V
				-- walks its modes ([EXT_HUD_PARITY]). The shared module,
				-- over this client's scene; on `view` for the local line.
				if not view.minimap then
					local size = math.floor(128 * magic.ui.root.width /
							math.max(1, buildat.logical_size() or
							magic.graphics.width))
					view.minimap = luanti_hud.minimap.new{magic = magic,
							scene = view.scene, parent = magic.ui.root,
							render_path = view.viewport.renderPath,
							w = size, h = size,
							height = math.floor(SETTINGS.view_range * 0.6)}
					view.minimap.view:SetAlignment(HA_RIGHT, VA_TOP)
					view.minimap.view:SetPosition(-10, 10)
				end
				-- A node whose texture expression cannot be built stays a
				-- placeholder, and this is the only thing that says why
				for mod_name, expr in pairs(texmod.unimplemented) do
					log:warning("texture modifier ["..mod_name..
							" is not implemented, as in "..expr)
				end
			end
		end

		-- The atlas textures the world is drawn with are filled in by hand
		-- rather than loaded from a file, and Urho3D can only bring back
		-- what it loaded: a change of screen mode takes the GL context with
		-- it and the world comes back black.
		--
		-- The atlas registry keeps the Image every segment was written
		-- into and puts it back when the texture says its data is lost
		-- (`AtlasRegistry::update()`, which voxelworld's client half calls
		-- every frame); this client never called it and rebuilt the whole
		-- registry on ScreenMode instead -- which on the box left the
		-- world black going into fullscreen and, in pbr, for good coming
		-- out of it, the rebuild filling textures the materials no longer
		-- drew with ([BOX_PLAYTEST_3] 1). The rebuild is gone; the
		-- per-frame update is in view:update().
		local screen_mode_cb = magic.SubscribeToEvent("ScreenMode",
				function()
					log:info("screen mode changed; the atlas restores itself")
				end)

		client.on_nodedef = function(data)
			got_content = true
			local defs, count = nodedef.parse(luanti.serialize, data, log)
			node_defs = defs
			node_by_name = {}
			for _, def in pairs(defs) do
				node_by_name[def.name] = def
			end
			local through, blocking = 0, 0
			for _, def in pairs(defs) do
				if def.pointable == 0 then through = through + 1 end
				if def.pointable == 2 then blocking = blocking + 1 end
			end
			add_line(count.." node definitions")
			log:info(count.." node definitions, "..through..
					" the ray goes through, "..blocking.." block it")
			registry_stale = true
			-- Starts the fallback clock: a server that never announces its
			-- media must not leave the loading panel up forever
			media_progress_us = media_progress_us or buildat.get_time_us()
		end

		-- Everything the server has that the cache does not, asked for at
		-- once: see media.lua. Working out which files a game's definitions
		-- actually reach means walking every texture expression, and a file
		-- found after the voxel registry was built costs another build of it.
		client.on_announce_media = function(files)
			announced = files
			for _, name in ipairs(store:plan(files)) do
				to_ask[#to_ask + 1] = name
			end
			-- A server asks for a sound by the name of a group, so what
			-- files are in which group has to be worked out from the
			-- announcement; see sounds.lua
			local names = {}
			for _, file in ipairs(files) do
				names[#names + 1] = file.name
			end
			sound_groups = sounds.groups(names)
			registry_stale = true
		end

		client.on_media = function(files)
			local _, missing = store:store(files)
			media_progress_us = buildat.get_time_us()
			-- How long the files took, which is the network's part of the
			-- wait ([ACK_OFF_FRAME] measured by it)
			if missing == 0 and media_asked_us then
				log:info("All media in, "..string.format("%.1f",
						(media_progress_us - media_asked_us) / 1000000)..
						" s after the first request")
				media_asked_us = nil
			end
			-- Everything announced was asked for before the registry was
			-- built the first time, so a file arriving after that is one the
			-- announcement did not cover -- a media push, or a name a form or
			-- an object asked for -- and the voxels may want it too
			if not loading then
				registry_stale = true
			end
			-- An object that was waiting for its texture can have it now
			for _, obj in pairs(world_objects) do
				if obj.media_missed then
					obj.visual_stale = true
				end
			end
			-- And so can a form: its textures are asked for when it is drawn
			if form_missed then
				redraw_form()
			end
		end

		-- The player's own box in the world. It asks the world what stops it;
		-- a node whose block has not arrived counts as solid, so the player
		-- stands still until the ground under them is there.
		local avatar = player.new(
				function(x, y, z) return view:is_solid(x, y, z) end,
				function(x, y, z) return view:is_liquid(x, y, z) end,
				nil,
				function(x, y, z) return view:resistance_at(x, y, z) end,
				function(x, y, z) return view:groups_at(x, y, z) end)
		client.on_movement = function(m)
			avatar.movement = m
			add_line("The game's movement constants arrived")
		end

		client.on_itemdef = function(data)
			-- The first of the game's content, which is the join having
			-- gone through: the name it went through with is kept for the
			-- server ([BOX_PLAYTEST_2] 4)
			if not got_content then
				settings.remember_server_name(host, port, name)
			end
			got_content = true
			local items, count = itemdef.parse(luanti.serialize, data, log,
					client.protocol_version)
			item_defs = items
			add_line(count.." item definitions")
		end

		-- A texture that is not part of a voxel definition: an object's, or
		-- one a formspec names. The media for those is not planned up front,
		-- because what wants them turns up long after the media was asked
		-- for, so what is missing is asked for when it is wanted and whatever
		-- was waiting gets it when it arrives.
		function media_texture(name)
			local resolved = texmod.resolve(name, texmod_ctx)
			if resolved then
				return resolved
			end
			local wanted = {}
			if texmod.sources(name, wanted) and announced then
				for _, missing in ipairs(store:plan(announced, wanted)) do
					to_ask[#to_ask + 1] = missing
				end
				-- Planning counts a file that is already in the cache as had,
				-- and then nothing will arrive to ask for a second look: what
				-- was on disk resolves now or not at all
				resolved = texmod.resolve(name, texmod_ctx)
			end
			if not resolved then
				media_misses = media_misses + 1
			end
			return resolved
		end

		-- Declared before what uses it; the definition is further down, with
		-- the rest of what a form needs
		local item_image

		-- The visuals whose first "texture" is an item name rather than a
		-- file: Luanti draws that item there, which is how a dropped item
		-- wears its own picture.
		local ITEM_VISUALS = {item = true, wielditem = true}

		-- What an object is drawn wearing. A mob and a player have textures
		-- of their own; a dropped item carries the item it is instead, and
		-- what that looks like is what it looks like in an inventory -- for
		-- a node, the little isometric cube, which is what Luanti's
		-- wielditem comes out as too.
		-- The six tiles of the node an item is, in Luanti's tile order, or
		-- nil for an item that is not a node or whose tiles are not all
		-- there yet. This is what makes a dropped node a small cube of its
		-- own textures rather than a picture of one.
		local function item_tiles(item)
			local item_name = item and item ~= "" and item:match("^(%S+)")
			if not item_name then
				return nil
			end
			local def = item_defs and item_defs[item_name]
			item_name = (def and def.name) or item_name
			if def and def.inventory_image and def.inventory_image ~= "" then
				-- A game that drew its own picture for the item means it
				return nil
			end
			local node = node_by_name[item_name]
			-- Only a plain cube: a node box or a plant is drawn as its own
			-- picture until an object can carry a real shape
			if not node or node.drawtype ~= 0 then
				return nil
			end
			local tiles = {}
			for i = 1, 6 do
				local resource = resolve_tile(node, i)
				if not resource then
					return nil
				end
				tiles[i] = resource
			end
			return tiles
		end

		local function object_resource(obj)
			local props = obj.props
			if not props then
				return nil
			end
			local textures = props.textures
			local function of_item(item)
				local name = item and item ~= "" and item:match("^(%S+)")
				return name and item_image(name) or nil
			end
			if ITEM_VISUALS[props.visual] then
				local item = textures and textures[1] ~= "" and
						textures[1] or props.wield_item
				return of_item(item), item_tiles(item)
			end
			-- An object drawn as its own model: the quads out of the .b3d
			-- or .obj, and one texture per material. A model this cannot
			-- read, or whose first texture has not arrived, falls back to
			-- the box below.
			if props.visual == "mesh" and props.mesh and props.mesh ~= "" then
				local quads = read_mesh({mesh = props.mesh, visual_scale = 1})
				if quads then
					local tiles = {}
					for i = 1, #(textures or {}) do
						tiles[i] = media_texture(textures[i])
					end
					if tiles[1] then
						-- The name is what the world keys one built mesh by,
						-- so that every mob of a kind is a copy of one
						return tiles[1], nil, {quads = quads, tiles = tiles,
								name = props.mesh}
					end
				end
			end
			if textures and textures[1] and textures[1] ~= "" then
				return media_texture(textures[1])
			end
			return of_item(props.wield_item)
		end

		-- Objects arrive a packetful at a time -- a crowd of mobs coming
		-- into range was 3795 bytes and 613 ms of one frame -- and what
		-- costs is not reading them but building each one's visual: the
		-- model read, the geometry built, the textures resolved. So an
		-- object that arrives is read and remembered here and its visual is
		-- built by flush_objects() on a budget, a few a frame. Until then it
		-- is not drawn.
		local object_queue = {}
		local object_head = 1
		local object_queued = {}
		local OBJECT_BUDGET_US = 3000

		local function queue_object(id)
			if object_queued[id] then
				return
			end
			object_queued[id] = true
			object_queue[#object_queue + 1] = id
		end

		-- Builds the visuals of the objects that are waiting, newest last,
		-- until the budget is out or a model has been read: reading one is
		-- tens of milliseconds of parsing with nothing to spread it over, so
		-- one of those is a frame's worth on its own.
		local function flush_objects()
			if object_head > #object_queue then
				return 0
			end
			local t0 = buildat.get_time_us()
			local reads = meshes_read
			local built = 0
			while object_head <= #object_queue do
				local id = object_queue[object_head]
				object_head = object_head + 1
				object_queued[id] = nil
				local obj = world_objects[id]
				-- Gone again, the player's own in first person, or riding
				-- on a bone this cannot follow ([OVER_SHOULDER]: an
				-- attached object drawn at its own position lands at the
				-- player's feet): nothing to draw
				if obj and obj.attached_to then
					view:remove_object(id)
				elseif obj and (not obj.is_self or camera_mode ~= 1) then
					local t1 = buildat.get_time_us()
					local misses = media_misses
					view:set_object(obj, object_resource)
					obj.media_missed = media_misses > misses
					built = built + 1
					-- One object that costs a frame of its own is worth a
					-- line: which it was, and whether its model had to be
					-- read, is what says where the time went
					local spent = buildat.get_time_us() - t1
					if spent > 20000 then
						log:info(string.format(
								"slow object: %s (%s, %s) took %.1f ms%s",
								tostring(obj.name or obj.id),
								tostring((obj.props or {}).visual),
								tostring((obj.props or {}).mesh),
								spent / 1000,
								meshes_read > reads and
										", model read" or ""))
					end
				end
				if meshes_read > reads or
						buildat.get_time_us() - t0 >= OBJECT_BUDGET_US then
					break
				end
			end
			if object_head > #object_queue then
				object_queue = {}
				object_head = 1
			end
			return built
		end

		client.on_object_add = function(id, object_type, data)
			local ok, obj = pcall(objects.parse_init, luanti.serialize, data)
			if not ok then
				log:warning("objects: could not read object "..id..": "..
						tostring(obj))
				return
			end
			obj.id = id
			world_objects[id] = obj
			log:verbose("object add "..id.." player="..
					tostring(obj.is_player).." name="..tostring(obj.name))
			-- The local player is drawn by nobody: the camera is inside it
			if obj.is_player and obj.name == name then
				obj.is_self = true
				return
			end
			queue_object(id)
		end

		-- Particles: the spawners a game leaves running -- smoke, fire,
		-- rain -- and the single ones it fires off, which is what digging
		-- and footsteps are. Both are drawn by the world; what this hands
		-- over is how to turn a texture string into a resource.
		client.on_particle_spawner = function(id, p)
			view:set_particle_spawner(id, p, media_texture)
		end

		client.on_particle = function(p)
			view:add_particle(p, media_texture)
		end

		client.on_object_remove = function(id)
			world_objects[id] = nil
			view:remove_object(id)
		end

		client.on_object_message = function(id, data)
			local obj = world_objects[id]
			if not obj then
				return
			end
			local r = luanti.serialize.reader(data)
			local ok, err = pcall(objects.apply_message, obj, r)
			-- The local player's own override goes to the avatar's physics
			if ok and obj.is_self and obj.physics_override and avatar then
				avatar.override = obj.physics_override
				obj.physics_override = nil
			end
			if not ok then
				-- One message this does not understand is not worth losing
				-- the object over; the rest still arrive
				return
			end
			if obj.visual_stale and (not obj.is_self or camera_mode ~= 1) then
				queue_object(id)
			end
		end

		-- The game changes the sky whenever it likes -- entering a biome, a
		-- cave, the nether -- so only the first one is worth a line
		local said_sky = false

		client.on_sky = function(sky)
			view:set_sky(sky)
			if not said_sky then
				said_sky = true
				add_line("The sky is a \""..(sky.type or "?").."\" one")
			end
		end

		-- A line in the chat log, which is where the player looks. What
		-- this client has to say for itself goes here rather than into the
		-- debug lines in the corner, because those start hidden.
		-- **Decluttered** ([TOUCH_CHAT_CLUTTER], a touchscreen's More and
		-- the chat dialog): only the DECLUTTER_LINES newest, each cut to
		-- DECLUTTER_CHARS characters, as drawn; the log stays whole.
		-- simplified: not saved, off at each join
		local DECLUTTER_LINES, DECLUTTER_CHARS = 3, 50
		local declutter = false
		-- s cut to n UTF-8 characters (the web's Lua 5.1 has no utf8)
		local function cut_chars(s, n)
			local count = 0
			for i = 1, #s do
				local b = s:byte(i)
				if b < 0x80 or b >= 0xC0 then
					count = count + 1
					if count > n then
						return s:sub(1, i - 1)
					end
				end
			end
			return s
		end
		local function show_chat_lines()
			if not declutter then
				chat_text.text = table.concat(chat, "\n")
				return
			end
			local shown = {}
			for i = math.max(1, #chat - DECLUTTER_LINES + 1), #chat do
				shown[#shown + 1] = cut_chars(chat[i], DECLUTTER_CHARS)
			end
			chat_text.text = table.concat(shown, "\n")
		end
		local function set_declutter(on)
			declutter = on
			log:info("chat: declutter " .. (on and "on" or "off"))
			show_chat_lines()
			if settings.touch and settings.touch.show_clutter then
				settings.touch.show_clutter(on)
			end
		end

		local function add_chat(line)
			chat[#chat + 1] = line
			while #chat > CHAT_LINES do
				table.remove(chat, 1)
			end
			show_chat_lines()
		end

		client.on_chat = function(text, sender)
			local line = formspec.strip_escapes(text)
			if sender ~= "" then
				line = "<"..formspec.strip_escapes(sender).."> "..line
			end
			-- In the log too, as vanilla's is: the one thing a fixture can
			-- put in the client's own log for a driven run to wait on
			log:info("chat: " .. line)
			add_chat(line)
		end

		client.on_inventory_formspec = function(spec)
			inventory_spec = spec
			local form = form_on()
			if form and form.source == "inventory" then
				-- The spec itself, not only what is in the slots: this is how
				-- a game changes the page of its own inventory
				form.spec = spec
				redraw_form()
			end
		end

		client.on_formspec_prepend = function(spec)
			prepend = spec
		end

		-- A chest somebody put something in: the form showing it is redrawn
		-- with what it holds now
		client.on_node_meta = function(entries)
			view:set_node_meta(entries)
			local form = form_on()
			if form then
				-- A node's form *is* the string in its metadata, and a game
				-- rewrites that string as the node works: a furnace's flame
				-- and its progress arrow are images whose [lowpart is
				-- redrawn every tick. Luanti's own client re-reads the
				-- string every frame (NodeMetadataFormSource); this one
				-- re-reads it when the metadata arrives, which is when it
				-- can have changed. The form's state -- the scroll, the
				-- stack in hand -- is kept: only the layout is new.
				if form.at then
					local meta = view:node_meta(form.at[1], form.at[2],
							form.at[3])
					local spec = meta and meta.fields and
							meta.fields.formspec
					if spec and spec ~= "" then
						form.spec = spec
					end
				end
				redraw_form()
			end
		end

		client.on_detached_inventory = function(name, data)
			detached[name] = data and inventory.parse(data, detached[name])
					or nil
			redraw_form()
		end

		client.on_inventory = function(data)
			local first = inv == nil
			inv = inventory.parse(data, inv)
			redraw_form()
			if first then
				local names = {}
				for name, list in pairs(inv) do
					names[#names + 1] = name.." "..list.size
				end
				table.sort(names)
				add_line("The inventory arrived: "..
						table.concat(names, ", "))
			end
		end

		-- The stack in the wielded slot, and the tool capabilities a dig
		-- goes by: the wielded item's own, the hand slot's when it has none,
		-- and the empty item's as the last resort. This game keeps a real
		-- item in the hand slot, so without it nothing could be dug.
		local function wielded()
			return inventory.slot(inv, "main", wield_index)
		end

		local function dig_capabilities()
			return (inventory.dig_capabilities(inv, wield_index, item_defs))
		end

		local function reach()
			local held = wielded()
			local def = held and item_defs and item_defs[held.name]
			if def and def.range and def.range > 0 then
				return def.range
			end
			local empty = item_defs and item_defs[""]
			if empty and empty.range and empty.range > 0 then
				return empty.range
			end
			return POINT_RANGE
		end

		local function node_def_at(p)
			local id = view:node_at(p[1], p[2], p[3])
			return id and node_defs and node_defs[id] or nil
		end

		-- The id a node name has here, for a predicted write. Air is not in
		-- the definitions the server sends; its id is the protocol's
		local function node_id_of(name)
			if name == "air" then
				return 126 -- CONTENT_AIR
			end
			local def = node_by_name[name]
			return def and def.id or nil
		end

		-- Dig prediction ([PREDICTION]): the node becomes its definition's
		-- node_dig_prediction the moment the dig completes (air unless the
		-- definition names another, "" for none), and the server's update
		-- overwrites whatever this got wrong -- official's Game::handleDigging
		local function predict_dig(p)
			local def = node_def_at(p)
			if not def then
				return
			end
			local want = def.node_dig_prediction
			if want == nil then
				want = "air"
			end
			if want == "" then
				return
			end
			local id = node_id_of(want)
			if id then
				view:set_node(p[1], p[2], p[3], id, nil, 0)
				log:info(string.format("predicted %s at (%d, %d, %d)", want,
						p[1], p[2], p[3]))
			end
		end

		-- Placement prediction: the wielded item's node_placement_prediction
		-- into above (or under when buildable_to), unless the pointed node
		-- takes the click (rightclickable and no sneak) or the item says ""
		-- (a custom on_place). simplified: only a node with no facedir or
		-- wallmounted paramtype2 is predicted; the others wait for the
		-- server's answer with the param2 it works out.
		local function predict_place(pointed_under, pointed_above, sneak)
			local held = wielded()
			local idef = held and item_defs and item_defs[held.name]
			local want = idef and idef.node_placement_prediction
			if want == nil then
				want = node_by_name[held and held.name or ""] and held.name or ""
			end
			if want == "" then
				return
			end
			local udef = node_def_at(pointed_under)
			if udef and udef.rightclickable and not sneak then
				return
			end
			local def = node_by_name[want]
			if not def or def.id == nil then
				return
			end
			-- ContentParamType2: 3 facedir, 4 wallmounted, 9 and 10 their
			-- coloured kinds, 13 and 14 the 4dir ones
			local pt2 = def.param_type_2 or 0
			if pt2 == 3 or pt2 == 4 or pt2 == 9 or pt2 == 10 or pt2 == 13 or
					pt2 == 14 then
				return
			end
			local at = (udef and udef.buildable_to) and pointed_under or pointed_above
			view:set_node(at[1], at[2], at[3], def.id, nil, 0)
			log:info(string.format("predicted %s at (%d, %d, %d)", want,
					at[1], at[2], at[3]))
		end

		-- The pointing ray, and what holding the dig button does to what it
		-- finds. Luanti's server wants a START_DIGGING at a node before a
		-- DIGGING_COMPLETED for it, and no sooner than the dig would have
		-- taken; the node then comes back as a REMOVENODE.
		-- One frame of the crack, as a resource name: the strip cut into
		-- frames by the same [verticalframe texmod.lua already does for an
		-- animated tile. Cut once per frame index and kept.
		-- **Counted from the file that is cut** ([CRACK_FRAMES]): a
		-- server's own crack_anylength.png goes before the client's
		-- five frames -- VoxeLibre's has ten, Repixture's eight -- and a
		-- strip cut into the wrong count is two cracks squeezed onto a
		-- face. Counted again, and the cut frames forgotten, when which
		-- file that is changes: the server's media arriving.
		local crack_file = nil
		local crack_frames = CRACK_FRAMES_DEFAULT
		local crack_resource = {}

		local function crack_frame_count()
			local file = texmod_ctx.resource("crack_anylength.png")
			if file ~= crack_file then
				crack_file = file
				crack_resource = {}
				local tex = file and magic.cache:GetResource("Texture2D", file)
				crack_frames = texmod.strip_frames(tex and tex.width,
						tex and tex.height, CRACK_FRAMES_DEFAULT)
				log:info("crack: " .. crack_frames .. " frames in " ..
						tostring(file))
			end
			return crack_frames
		end

		local function crack_texture(index)
			local resource = crack_resource[index]
			if resource == nil then
				resource = texmod.resolve("crack_anylength.png^[verticalframe:"..
						crack_frame_count()..":"..index, texmod_ctx) or false
				crack_resource[index] = resource
			end
			return resource or nil
		end

		-- How far into the dig the crack is, or nil when nothing is being
		-- dug: Luanti walks the frames over the time the node takes.
		local function update_crack()
			if not dig or not dig.time or dig.time <= 0 or dig.done then
				view:set_crack(nil, nil)
				return
			end
			local frames = crack_frame_count()
			local index = math.floor(dig.elapsed / dig.time * frames)
			if index < 0 then
				index = 0
			elseif index > frames - 1 then
				index = frames - 1
			end
			view:set_crack(dig.under, crack_texture(index))
		end

		-- A sound of the client's own, as official's client plays it: a
		-- footstep, a swing's and a dug node's, which the server leaves
		-- out for the player who made them. Through the server's sounds'
		-- own path, so a group is a random file of it. pos nil is in the
		-- player's head.
		local function own_sound(sound, pos, gain)
			if not sound or sound.name == "" or not client.on_play_sound then
				return nil
			end
			own.n = own.n + 1
			client.on_play_sound("own:"..own.n, {name = sound.name,
					gain = gain or sound.gain, pitch = sound.pitch,
					location = pos and sounds.POSITION or
							sounds.LOCAL,
					pos = pos or {0, 0, 0}, object_id = 0, fade = 0})
			return sound.name
		end

		-- The swing crossing 0.15 (SoundMaker::cameraPunchLeft): the dug
		-- node's dig sound, "__group" being default_dig_<the group the dig
		-- goes by> at 0.5, and the wielded item's use sound at something,
		-- its use_air one at nothing
		local function swing_sound()
			local d = nil
			if dig and dig.time and not dig.done and dig.def then
				local sd = dig.def.sound_dig
				if sd and sd.name == "__group" then
					d = dig.group and own_sound({name = "default_dig_"..dig.group,
							pitch = 1}, nil, 0.5)
				else
					d = own_sound(sd)
				end
			end
			local held = wielded()
			local idef = item_defs and item_defs[held and held.name or ""]
			local u = idef and own_sound((pointed_under or pointed_object) and
					idef.sound_use or idef.sound_use_air)
			log:debug(string.format("swing: at %.2f, dig %s, use %s",
					own.phase, tostring(d), tostring(u)))
		end

		local function update_dig(dtime)
			if form_on() then
				-- A form has the mouse; nothing is pointed at behind it
				view:set_pointed(nil, nil)
				pointed_under, pointed_above = nil, nil
				pointed_object = nil
				if dig then
					client:interact(luanti.INTERACT_STOP_DIGGING,
							wield_index - 1)
					dig = nil
				end
				update_crack()
				return
			end
			local node_t
			pointed_under, pointed_above, node_t = view:point_ray(reach())
			if not pointed_above then
				pointed_under = nil
			end
			-- An object in front of the node the ray would have stopped at
			-- takes the pointing; one whose pointable is 2 takes it away
			-- from the node without being pointed at itself
			local obj_id, obj_t = view:point_objects(reach(), world_objects)
			pointed_object = nil
			if obj_t and (not pointed_under or obj_t < node_t) then
				pointed_under, pointed_above = nil, nil
				pointed_object = obj_id
			end
			if pointed_object then
				local obj = world_objects[pointed_object]
				local props = obj and obj.props
				view:set_pointed_box({
					obj.position[1] + props.selection_min[1],
					obj.position[2] + props.selection_min[2],
					obj.position[3] + props.selection_min[3],
				}, {
					obj.position[1] + props.selection_max[1],
					obj.position[2] + props.selection_max[2],
					obj.position[3] + props.selection_max[3],
				})
			else
				view:set_pointed(pointed_under, pointed_above)
			end

			hit_wait = math.max(0, hit_wait - dtime)
			if pointed_object then
				-- Hitting an object rather than digging: one hit per press,
				-- and no faster than the delay while the button is held,
				-- which is what handlePointingAtObject() does
				if dig then
					client:interact(luanti.INTERACT_STOP_DIGGING,
							wield_index - 1)
					dig = nil
				end
				if digging and hit_wait <= 0 then
					client:interact(luanti.INTERACT_START_DIGGING,
							wield_index - 1, {object = pointed_object})
					hit_wait = OBJECT_HIT_DELAY
				end
				update_crack()
				return
			end

			if not digging or not pointed_under then
				if dig then
					client:interact(luanti.INTERACT_STOP_DIGGING,
							wield_index - 1)
					dig = nil
				end
				update_crack()
				return
			end
			if not dig or dig.under[1] ~= pointed_under[1] or
					dig.under[2] ~= pointed_under[2] or
					dig.under[3] ~= pointed_under[3] then
				local def = node_def_at(pointed_under)
				-- nil when what the player is holding cannot dig this at
				-- all, and then nothing is ever completed: the server would
				-- refuse it as digging the undiggable
				local time, group = nil, nil
				if def then
					time, group = itemdef.dig_time(def.groups, dig_capabilities())
				end
				dig = {
					under = pointed_under, above = pointed_above, elapsed = 0,
					time = time, group = group, def = def,
					name = def and def.name or "?",
				}
				client:interact(luanti.INTERACT_START_DIGGING,
						wield_index - 1, {under = dig.under,
						above = dig.above})
				update_crack()
				return
			end
			if dig.done then
				update_crack()
				return
			end
			dig.elapsed = dig.elapsed + dtime
			if dig.time and dig.elapsed >= dig.time then
				client:interact(luanti.INTERACT_DIGGING_COMPLETED,
						wield_index - 1, {under = dig.under,
						above = dig.above})
				dig.done = true
				predict_dig(dig.under)
				local dug = dig.def and own_sound(dig.def.sound_dug, dig.under)
				log:info("dug "..dig.name..": "..tostring(dug))
			end
			update_crack()
		end

		--
		-- Formspecs: the windows the server describes
		--

		-- What an item looks like: its own inventory image, or, for an item
		-- that places a node, the top of that node. Both are texture
		-- expressions.
		-- The items nothing could be made of, named once each: what is
		-- drawn for them is a marked square, and this is what says why
		local imageless = {}

		-- Which drawtypes are a cube, and so are drawn as the little cube an
		-- inventory shows a voxel as. A nodebox, a plant or a mesh is not:
		-- what those look like is their own shape, and their flat tile is a
		-- better lie than a cube would be. NDT_MESH is left out for the same
		-- reason even though the world draws it as its box.
		local CUBE_ITEM_DRAWTYPES = {
			[0] = true,  -- NDT_NORMAL
			[2] = true,  -- NDT_LIQUID
			[3] = true,  -- NDT_FLOWINGLIQUID
			[4] = true,  -- NDT_GLASSLIKE
			[5] = true,  -- NDT_ALLFACES
			[6] = true,  -- NDT_ALLFACES_OPTIONAL
			[13] = true, -- NDT_GLASSLIKE_FRAMED
			[15] = true, -- NDT_GLASSLIKE_FRAMED_OPTIONAL
		}

		-- How big the cube is drawn. It is scaled to the slot afterwards, so
		-- this only decides how much of the texture's detail survives. Nine
		-- times a unit, because that is what Luanti's own geometry is in;
		-- with a unit of eight a face's edge comes out 32 pixels.
		local CUBE_UNIT = 8
		local CUBE_SIZE = 9 * CUBE_UNIT

		-- A voxel as the cube Luanti draws in an inventory: the top face and
		-- the two the viewer would see, each a parallelogram, the sides
		-- darkened so that the three read as three faces.
		--
		-- Luanti renders the node with a camera; three sheared tiles is the
		-- picture that comes out of that, without a render target.
		local function inventory_cube(def)
			if not CUBE_ITEM_DRAWTYPES[def.drawtype] then
				return nil
			end
			-- Luanti's own geometry, from createInventoryCubeImage() in
			-- src/client/imagesource.cpp: on a canvas of nine units the cube
			-- is eight wide and nine tall, a face's horizontal edge runs
			-- four across and two down, and a side face's vertical edge runs
			-- five down. Being taller than it is wide is the point -- a cube
			-- that fills a square canvas reads as squashed.
			local k = CUBE_UNIT
			-- Tiles are +Y, -Y, +X, -X, +Z, -Z: the top and the two faces
			-- that point at a viewer standing off the +X +Z corner
			--
			-- A side is darkened by asking for the tile with a [multiply on
			-- it rather than by darkening the canvas: the expression
			-- language already does that, and a multiply over the canvas
			-- would darken the faces already drawn as well.
			-- The shades are Luanti's too: 214/256 and 171/256 of the top's
			-- own brightness, which as a [multiply is #d5d5d5 and #aaaaaa
			local faces = {
				{tile = 1, at = {4.5 * k, 0},
						u = {4 * k, 2 * k}, v = {-4 * k, 2 * k}},
				{tile = 5, at = {0.5 * k, 2 * k},
						u = {4 * k, 2 * k}, v = {0, 5 * k},
						shade = "#d5d5d5"},
				{tile = 3, at = {4.5 * k, 4 * k},
						u = {4 * k, -2 * k}, v = {0, 5 * k},
						shade = "#aaaaaa"},
			}
			local ops = {}
			local key = "\0cube"
			for _, face in ipairs(faces) do
				local expr = tile_expression(def, face.tile)
				if not expr then
					return nil
				end
				if face.shade then
					expr = expr.."^[multiply:"..face.shade
				end
				local resource = texmod.resolve(expr, texmod_ctx)
				if not resource then
					return nil
				end
				key = key.."\0"..expr
				ops[#ops + 1] = {op = "shear", src = resource,
						at = face.at, u = face.u, v = face.v}
			end
			return texmod_ctx.compose(def.name..key, ops,
					{CUBE_SIZE, CUBE_SIZE})
		end

		-- A node box's or a mesh's node as its shape, the way Luanti's
		-- inventory renders it (res/item_shape.lua); loaded here, as this
		-- function is at Lua's upvalue limit
		local item_shape = buildat.run_extension_file("res/item_shape.lua")
		local function inventory_shape(def)
			local quads = nil
			if def.drawtype == 12 and def.node_box and
					#def.node_box.boxes > 0 then -- NDT_NODEBOX
				quads = item_shape.box_quads(def.node_box.boxes)
			elseif def.drawtype == 16 then -- NDT_MESH
				quads = read_mesh(def)
			end
			if not quads then
				return nil
			end
			local key = "\0shape"
			local ops = item_shape.ops(quads, CUBE_UNIT, function(tile, shade)
				local expr = tile_expression(def, math.min(tile, 6))
				if not expr then
					return nil
				end
				if shade then
					expr = expr.."^[multiply:"..shade
				end
				key = key.."\0"..expr
				return texmod.resolve(expr, texmod_ctx)
			end)
			return ops and texmod_ctx.compose(def.name..key, ops,
					{CUBE_SIZE, CUBE_SIZE})
		end

		function item_image(item_name)
			-- The name an alias means, so that what is looked for below is
			-- the item itself
			local def = item_defs and item_defs[item_name]
			item_name = (def and def.name) or item_name
			if def and def.inventory_image and def.inventory_image ~= "" then
				return texmod.resolve(def.inventory_image, texmod_ctx)
			end
			local node = node_by_name[item_name]
			if node then
				-- A voxel with no inventory image of its own is the little
				-- cube, when it is a cube at all
				local cube = inventory_cube(node) or inventory_shape(node)
				if cube then
					return cube
				end
				local expr = tile_expression(node, 1)
				if expr then
					local resource = texmod.resolve(expr, texmod_ctx)
					if resource then
						return resource
					end
					if not imageless[item_name] then
						imageless[item_name] = true
						log:info("item: no image for \""..item_name..
								"\", whose tile is \""..expr.."\"")
					end
					return nil
				end
			end
			if not imageless[item_name] then
				imageless[item_name] = true
				log:info("item: no image for \""..item_name.."\": "..
						(def and def.inventory_image ~= "" and
						"inventory_image \""..def.inventory_image.."\"" or
						(node and "a node with no tile" or
						"no definition and no node")))
			end
			return nil
		end

		local ui = formspec_ui.new(magic, buildat, log, {
			texture = media_texture,
			item_image = item_image,
			style = style,
			white = "luanti_client/res/white.png",
			formspec = formspec,
			-- model[]: the mesh the server sent, wearing its textures;
			-- nothing until both have arrived (the form is drawn again as
			-- media arrives)
			model = function(parent, w, h, mesh, textures, rot_x, rot_y)
				local quads = read_mesh({mesh = mesh, visual_scale = 1})
				local tiles = {}
				for i, t in ipairs(textures) do
					tiles[i] = media_texture(t)
				end
				if not quads or not tiles[1] then
					return nil
				end
				return view:model_view(parent, w, h, quads, tiles, rot_x,
						rot_y)
			end,
			-- Where a list[] element's slots come from: the player's own
			-- inventory, one the server has detached, or the one that hangs
			-- off a voxel, which is what a chest's slots are.
			inventory = function(location, list_name)
				local lists = nil
				local form = form_on()
				if FORM_OWN_INVENTORY[location] and form and form.at then
					-- The form's own inventory, which for a form a node
					-- carries is that node's: a chest says
					-- list[current_name;main;...] and a furnace
					-- list[context;src;...]
					local meta = view:node_meta(form.at[1], form.at[2],
							form.at[3])
					lists = meta and meta.lists or nil
				elseif location == "current_player" or
						location:sub(1, 7) == "player:" then
					lists = inv
				else
					local x, y, z = location:match(
							"^nodemeta:(-?%d+),(-?%d+),(-?%d+)$")
					if x then
						local meta = view:node_meta(tonumber(x),
								tonumber(y), tonumber(z))
						lists = meta and meta.lists or nil
					else
						local name = location:match("^detached:(.*)$")
						lists = name and detached[name] or nil
					end
				end
				local list = lists and lists[list_name] or nil
				if not list then
					-- A list with nowhere to come from is drawn as nothing,
					-- and the form only looks emptier ([LUANTI_INV_LISTS])
					log:verbose("form: list[" .. location .. ";" ..
							list_name .. "] has no inventory")
				end
				return list
			end,
		})

		-- `event scan` beside a screenshot says where the camera and the
		-- player's own model were when the frame was drawn
		-- ([OVER_SHOULDER]'s open reading: the model's feet land as if the
		-- camera were nearer than the setback loop's last value, and the
		-- two have to be read in the same frame before anything moves)
		magic.SubscribeToEvent("command_seq:scan", function()
			log:info(view:camera_report())
		end)

		-- The health bar, remade when what it shows changes; the hotbar
		-- beside it is the row both clients share ([EXT_HOTBAR]) and keeps
		-- its own elements
		local hud = nil
		local hud_key = nil
		local hotbar_look = nil
		local function hud_texture(name)
			if not name or name == "" then
				return nil
			end
			local resource = media_texture(name)
			local tex = resource and
					magic.cache:GetResource("Texture2D", resource)
			if tex then
				tex.filterMode = magic.FILTER_NEAREST
			end
			return tex
		end
		local hotbar_row = luanti_hud.hotbar.new{
			magic = magic, buildat = buildat, log = log,
			white = magic.cache:GetResource("Texture2D",
					"luanti_client/res/white.png"),
			font = magic.cache:GetResource("Font", buildat.font_mono),
			texture = hud_texture,
			stack = function(stack)
				if not stack or stack.count == 0 then
					return nil, nil, nil
				end
				local resource = item_image(stack.name)
				local tex = resource and
						magic.cache:GetResource("Texture2D", resource)
				if tex then
					tex.filterMode = magic.FILTER_NEAREST
				end
				return tex, stack.count > 1 and tostring(stack.count) or "",
						stack.name
			end,
		}

		-- The game's own HUD: what the server said is on the screen, the
		-- element holding it, and whether that has to be built again. The
		-- flags are what a game turns this client's own hotbar, health bar,
		-- crosshair and chat off with, which a game that draws its own does.
		local hud_elements = {}
		local hud_flags = luanti_hud.FLAGS_DEFAULT
		-- Drawn by res/hud_draw.lua, the renderer both Luanti clients share
		-- ([LUANTI_SHARED]).
		-- simplified: no camera, yaw or minimap in its ctx, so a waypoint,
		-- an image waypoint, a compass and a game's minimap element are
		-- counted as not drawn; view.minimap is official's own
		local game_hud = luanti_hud.draw.new(magic, log, {
			hud = luanti_hud, formspec = formspec, parent = magic.ui.root,
			-- Luanti's m_scale_factor in this UI's units, which it
			-- multiplies a HUD element's sizes and offsets by: the
			-- hotbar's, so the HUD stays against it ([HUD_DENSITY])
			scale = function() return hotbar_row:scale() end,
			texture = hud_texture,
			font = magic.cache:GetResource("Font", buildat.font_mono),
			font_size = 14,
			white = magic.cache:GetResource("Texture2D",
					"luanti_client/res/white.png"),
			slots = function() return hotbar_row:metrics() end,
			inventory = function(list_name)
				local list = inv and inv[list_name]
				if not list then
					return nil
				end
				local out = {}
				for i = 1, list.size or #list.items do
					local stack = list.items[i]
					local resource = stack and stack.count > 0 and
							item_image(stack.name)
					local tex = resource and
							magic.cache:GetResource("Texture2D", resource)
					if tex then
						tex.filterMode = magic.FILTER_NEAREST
					end
					out[i] = {count = stack and stack.count or 0,
							texture = tex or nil}
				end
				return out
			end,
		})
		local game_hud_stale = true
		local game_hud_size = nil
		local game_hud_missing = false
		-- How many of them there are, for the counters line
		local hud_count = 0
		-- The sound groups a server asked for that are not in its media, so
		-- that each is said once
		local sound_missing = {}
		-- Where the chat lines are, so that they are only moved when the
		-- lines of detail above them changed height, and the same for the
		-- infotext under them
		local chat_at_y = nil
		local info_at_y = nil

		-- Every change to any of it, with the elements keyed by the server's
		-- own id; client.lua holds them because HUDCHANGE names one field of
		-- one element
		-- A server asks for a sound by group name; one of the files in that
		-- group is played, picked at random the way Luanti picks one, which
		-- is why a game ships three recordings of a footstep.
		client.on_play_sound = function(id, spec)
			local group = sound_groups[spec.name]
			if not group then
				if not sound_missing[spec.name] then
					sound_missing[spec.name] = true
					log:info("No sound group \""..spec.name.."\"")
				end
				return
			end
			-- Only the files that have actually arrived
			local have = {}
			for _, file in ipairs(group) do
				if store:have_file(file) then
					have[#have + 1] = file
				end
			end
			if #have == 0 then
				return
			end
			local file = have[math.random(#have)]
			view:play_sound(id, spec, server_key.."/"..file)
		end

		-- simplified: the field of view the client tells the server about
		-- does not change with this, so a zoomed-in player is still sent the
		-- blocks a 98-degree view needs. That is more blocks than it wants,
		-- never fewer.
		client.on_sun = function(sun)
			view:set_sky_body("sun", sun)
		end

		client.on_moon = function(moon)
			view:set_sky_body("moon", moon)
		end

		client.on_stars = function(stars)
			view:set_sky_body("stars", stars)
		end

		client.on_clouds = function(clouds)
			view:set_sky_body("clouds", clouds)
		end

		client.on_player_speed = function(x, y, z)
			avatar:add_velocity(x, y, z)
		end

		client.on_fov = function(fov, is_multiplier, transition_time)
			view:set_fov(fov, is_multiplier, transition_time)
		end

		client.on_stop_sound = function(id)
			view:stop_sound(id)
		end

		client.on_fade_sound = function(id, step, gain)
			view:fade_sound(id, step, gain)
		end

		client.on_hud = function(elements, flags, params)
			hud_elements = elements
			hud_flags = flags
			game_hud_stale = true
			hud_count = 0
			for _ in pairs(elements) do
				hud_count = hud_count + 1
			end
		end

		local function update_hud()
			local on = show_hud and not loading and not world_wait
			-- Nothing of the player's own while the loading panel is up: the
			-- panel is behind the rest of the UI, so a hotbar would float on
			-- top of it. F1 takes it away as well, crosshair and all, which
			-- is what that key is for.
			for _, bar in ipairs(crosshair) do
				bar.visible = on and
						luanti_hud.has_flag(hud_flags,
						luanti_hud.FLAG.crosshair)
			end
			chat_text.visible = show_chat and
					luanti_hud.has_flag(hud_flags, luanti_hud.FLAG.chat)
			local chat_y = 8
			if show_debug > 0 then
				chat_y = 8 + status_text.height + 8
			end
			if chat_y ~= chat_at_y then
				chat_at_y = chat_y
				chat_text:SetPosition(8, chat_y)
			end
			-- A line wraps at the screen's edge: one wider than the screen
			-- was taken by the UI fit as content and scaled everything down
			local chat_w = magic.ui.root.width - 16
			if chat_text.width ~= chat_w then
				chat_text.width = chat_w
			end
			-- Under the chat, which is where Luanti puts it
			info_text.visible = on
			local info_y = chat_y + chat_text.height + 8
			if info_y ~= info_at_y then
				info_at_y = info_y
				info_text:SetPosition(100, info_y)
			end

			-- The game's own elements, built again when the server changed
			-- any of them, the window changed size or the hotbar's scale
			-- changed with the slot count ([HUD_DENSITY])
			local ui_root = magic.ui.root
			local size = ui_root.width.."x"..ui_root.height.." "..
					hotbar_row:scale()
			if game_hud_stale or size ~= game_hud_size then
				game_hud_stale = false
				game_hud_size = size

				local missing, images = game_hud:draw(hud_elements)
				-- The lowest of the game's own image elements, which for a
				-- game that draws its hotbar's background itself is that
				-- background; the check reads it against the row
				-- ([EXT_HOTBAR])
				local low = nil
				for _, im in ipairs(images) do
					if not low or im.y + im.h > low.y + low.h then
						low = im
					end
				end
				if low then
					log:info("hud image lowest: \""..tostring(low.name)..
							"\" at "..low.x..","..low.y.." "..low.w.."x"..
							low.h)
				end
				if not game_hud_missing and next(missing) then
					game_hud_missing = true
					local names = {}
					for kind, count in pairs(missing) do
						names[#names + 1] = count.." "..kind
					end
					log:info("HUD element types not drawn: "..
							table.concat(names, ", "))
				end
			end
			game_hud.root.visible = on

			local show_hotbar = on and luanti_hud.has_flag(hud_flags,
					luanti_hud.FLAG.hotbar)
			local list = inv and inv.main or nil
			local healthbar = on and luanti_hud.has_flag(hud_flags,
					luanti_hud.FLAG.healthbar)
			-- The game's own two pictures for the row, which is what makes
			-- it look like the game's rather than like nothing
			-- ([EXT_HOTBAR]); a game that sends neither gets Luanti's own
			-- per-slot squares, as official does.
			local params = client.hud_params or {}
			local count = params[luanti_hud.PARAM_HOTBAR_ITEMCOUNT] or
					HOTBAR_SLOTS
			local key = tostring(wield_index).."/"..tostring(client.hp)..
					"/"..tostring(healthbar).."/"..tostring(show_hotbar)..
					"/"..tostring(count).."/"..size
			-- What is in the slots, as a string, so that the row is only
			-- drawn again when it would look different
			for i = 1, count do
				local stack = list and list.items[i] or nil
				key = key.."|"..(stack and
						(stack.name.." "..stack.count) or "")
			end
			if key == hud_key then
				return
			end
			hud_key = key
			hotbar_row:relayout()
			-- Said once per look, which is what a driven check reads: where
			-- the row landed against the game's own bars ([EXT_HOTBAR])
			local look = count.."/"..tostring(params[
					luanti_hud.PARAM_HOTBAR_IMAGE]).."/"..tostring(params[
					luanti_hud.PARAM_HOTBAR_SELECTED_IMAGE]).."/"..size
			if look ~= hotbar_look then
				hotbar_look = look
				local _, _, slot, margin = hotbar_row:metrics()
				log:info("hotbar: "..count.." slots, image \""..
						tostring(params[luanti_hud.PARAM_HOTBAR_IMAGE])..
						"\", marker \""..tostring(params[
						luanti_hud.PARAM_HOTBAR_SELECTED_IMAGE])..
						"\", row "..math.floor(
						(ui_root.width - count * slot) / 2)..","..
						(ui_root.height - margin - slot).." "..
						(count * slot).."x"..slot.." in "..size)
			end
			hotbar_row:draw{
				list = list and list.items or {},
				wield = wield_index, count = count, shown = show_hotbar,
				image = params[luanti_hud.PARAM_HOTBAR_IMAGE],
				selected_image =
						params[luanti_hud.PARAM_HOTBAR_SELECTED_IMAGE],
			}
			if hud then
				hud:Remove()
				hud = nil
			end
			if healthbar and show_hotbar and client.hp then
				-- Just above the row, which is where a game that draws its
				-- own bars against official's hotbar expects the space to
				-- be taken
				local _, _, slot, margin = hotbar_row:metrics()
				local width = count * slot
				hud = ui:health_bar(ui_root, client.hp, 20,
						math.floor((ui_root.width - width) / 2),
						ui_root.height - margin - slot, width, slot)
			end
		end

		-- What the server calls the inventory a slot is in. A form a node
		-- carries names its own inventory with one of FORM_OWN_INVENTORY's
		-- two names; an inventory action has to name the node itself.
		local function inv_location(location)
			local form = form_on()
			if FORM_OWN_INVENTORY[location] and form and form.at then
				return "nodemeta:"..form.at[1]..","..form.at[2]..","..
						form.at[3]
			end
			return location
		end

		-- Loaded here rather than at the top: this function is at Lua's
		-- upvalue limit
		local misses_before = 0
		session = buildat.run_extension_file("res/form_session.lua").new({
			magic = magic, log = log, formspec = formspec, ui = ui,
			-- To the player when the server showed the form, and to the
			-- node when it came out of the node's own metadata, which is
			-- what a chest's or a furnace's buttons want
			send_fields = function(form, fields)
				if form.at then
					client:send_nodemeta_fields(form.at[1], form.at[2],
							form.at[3], form.formname, fields)
				else
					client:send_inventory_fields(form.formname, fields)
				end
			end,
			move = function(count, from, to)
				client:send_inventory_move(count, inv_location(from.location),
						from.list, from.index, inv_location(to.location),
						to.list, to.index)
			end,
			craft = function(count, location)
				client:send_inventory_craft(count, inv_location(location))
			end,
			-- The game turns it into an item entity in front of the player
			drop = function(count, from)
				client:send_inventory_drop(count, inv_location(from.location),
						from.list, from.index)
			end,
			-- Only the first line: a game writes a whole paragraph into a
			-- description -- what the thing does, what it is worth -- and
			-- Luanti's own tooltip is the name of the item
			item_description = function(name)
				local def = item_defs and item_defs[name]
				return formspec.strip_escapes(def and def.description or "")
						:match("^[^\n]*")
			end,
			item_image = item_image,
			white = "luanti_client/res/white.png",
			style = style,
			escape_hook = true,
			prepare = function(spec)
				misses_before = media_misses
				-- The prepend goes in front unless the form says not to
				if not spec:find("no_prepend%[") then
					spec = prepend.."__prepend_end[]"..spec
				end
				log:verbose("FORMSPEC "..spec)
				return spec
			end,
			on_drawn = function(form)
				-- A form is drawn on the UI root and not on this session's
				-- own screen, so a scan of the stack does not reach it; this
				-- is what a driven run reads the form's elements through
				uistack.set_scan_extra(form.drawn.window)
				form_missed = media_misses > misses_before
			end,
			on_open = function()
				mouse_look(false, "a form opened")
			end,
			on_close = function()
				uistack.set_scan_extra(nil)
				mouse_look(true, "the form closed")
			end,
		})

		-- source says which form this is, which decides whether a new
		-- inventory formspec replaces it; at is the node the form came out
		-- of, for a form a node carries
		local function open_form(spec, formname, source, at)
			session:open(spec, formname, {source = source, at = at})
		end

		local function button_name(button)
			return button == MOUSEB_RIGHT and "right" or
					button == MOUSEB_MIDDLE and "middle" or "left"
		end

		-- A form this client draws for itself: the fields its buttons make
		-- go to handler instead of to the server. It is otherwise an
		-- ordinary form, so escape closes it and the inventory key replaces
		-- it, both of which are what a player expects.
		open_local_form = function(spec, handler)
			session:open(spec, "", {source = "client", handler = handler})
		end

		client.on_show_formspec = function(spec, formname)
			open_form(spec, formname, "server")
		end

		-- What the wielded item is pointed at, in the shape interact()
		-- takes, or nil for nothing at all
		local function pointed_thing()
			if pointed_object then
				return {object = pointed_object}
			end
			if pointed_under and pointed_above then
				return {under = pointed_under, above = pointed_above}
			end
			return nil
		end

		-- An item a game defines as usable does something of its own when
		-- the left button is pressed, and what is pointed at is the
		-- server's business rather than a dig: devtest's
		-- chest_of_everything:bag opens its own inventory, basenodes:apple
		-- is eaten. Luanti's rule is in src/client/game.cpp: a usable item
		-- takes the dig button, pointed at a node or at nothing.
		local function held_usable()
			local held = wielded()
			local def = held and item_defs and item_defs[held.name]
			return def and def.usable or false
		end

		-- Putting the wielded item where the ray came through the node it
		-- stopped at. What that means is the server's business: a node goes
		-- there, or the thing is used on what was pointed at, and either way
		-- what comes back is an ADDNODE or a formspec.
		local function place()
			if pointed_object then
				-- Right-clicking an object is what runs a game's
				-- on_rightclick for it
				client:interact(luanti.INTERACT_PLACE, wield_index - 1,
						{object = pointed_object})
				return
			end
			if not pointed_under or not pointed_above then
				return
			end
			-- A node that carries a formspec in its metadata -- a chest, a
			-- furnace, a sign being written -- opens it here rather than
			-- after a round trip to the server, which is what Luanti's own
			-- client does. The server still hears about the click when the
			-- node is rightclickable, because that is what runs the game's
			-- own on_rightclick.
			local meta = view:node_meta(pointed_under[1], pointed_under[2],
					pointed_under[3])
			local spec = meta and meta.fields and meta.fields.formspec
			if spec and spec ~= "" then
				local def = node_def_at(pointed_under)
				if def and def.rightclickable then
					client:interact(luanti.INTERACT_PLACE, wield_index - 1,
							{under = pointed_under, above = pointed_above})
				end
				open_form(spec, "", "nodemeta", pointed_under)
				return
			end
			-- Not into the player's own space, as Game::nodePlacement
			-- refuses: a walkable node that would land in the body's box
			-- -- into under when that is buildable_to, else into above --
			-- is not placed, and the server trusts the client on this
			-- ([POINTABLE])
			local held = wielded()
			local hdef = held and node_by_name and node_by_name[held.name]
			if hdef and hdef.walkable then
				local udef = node_def_at(pointed_under)
				local at = (udef and udef.buildable_to) and pointed_under or
						pointed_above
				if at[1] + 0.5 > avatar.x - 0.3 and at[1] - 0.5 < avatar.x + 0.3 and
						at[2] + 0.5 > avatar.y and at[2] - 0.5 < avatar.y + 1.75 and
						at[3] + 0.5 > avatar.z - 0.3 and at[3] - 0.5 < avatar.z + 0.3 then
					return
				end
			end
			client:interact(luanti.INTERACT_PLACE, wield_index - 1,
					{under = pointed_under, above = pointed_above})
			predict_place(pointed_under, pointed_above,
					magic.input:GetKeyDown(BIND.sneak.key))
		end

		-- The bottom line is remade every frame that F5 shows it;
		-- everything above it is the log of what happened
		local function set_counters()
			-- What is not handled yet is logged once per command by
			-- client.lua rather than shown here; it is a long line and the
			-- world is behind it
			-- What the pointed node says about itself, which is a game's own
			-- label for it. Only a few lines: Luanti cuts it at six.
			local info = ""
			if pointed_object then
				local obj = world_objects[pointed_object]
				local props = obj and obj.props
				local said = props and (props.infotext ~= "" and
						props.infotext or props.nametag) or nil
				if said and said ~= "" then
					info = formspec.strip_escapes(said)
				end
			elseif pointed_under then
				local meta = view:node_meta(pointed_under[1],
						pointed_under[2], pointed_under[3])
				local said = meta and meta.fields and
						meta.fields.infotext or nil
				if said and said ~= "" then
					info = formspec.strip_escapes(said)
					local lines_out = {}
					for line in info:gmatch("[^\n]+") do
						lines_out[#lines_out + 1] = line
						if #lines_out >= 6 then
							break
						end
					end
					info = table.concat(lines_out, "\n")
				end
			end
			if info ~= info_text.text then
				info_text.text = info
			end
			-- The rest is the debug line, which F5 shows
			if show_debug == 0 then
				return
			end
			local held = wielded()
			local holding = held and (held.name..
					(held.count > 1 and " x"..held.count or "")) or
					"nothing"
			local pointed = "pointing at nothing"
			if dig then
				pointed = (dig.done and "dug " or "digging ")..dig.name..
						(dig.time and string.format(" %.2f/%.2f",
						dig.elapsed, dig.time) or " (not by hand)")
			elseif pointed_under then
				local def = node_def_at(pointed_under)
				pointed = "pointing at "..(def and def.name or "?")
			elseif pointed_object then
				local obj = world_objects[pointed_object]
				local props = obj and obj.props
				pointed = "pointing at object "..pointed_object..
						(props and props.visual ~= "" and
						" ("..props.visual..")" or "")
			end
			local condition = ""
			if client.hp then
				condition = string.format(" | %d hp", client.hp)
				if client.breath and client.breath < 10 then
					condition = condition..string.format(", %d breath",
							client.breath)
				end
			end
			-- Only with the PBR path, which is the only thing that marches
			-- the sky: how much sky it has found straight up, and over how
			-- many blocks of voxels. A cave that still reads 1.00 is the
			-- marching not getting the data.
			local sky_vis, sky_blocks = view:sky_visibility()
			local reflections = sky_vis and string.format(
					" | sky %.2f up over %d blocks", sky_vis, sky_blocks) or ""

			-- Where the player is and looks, as official Luanti shows it:
			-- with the debug privilege or the game's basic_debug HUD flag,
			-- which is on until a game turns it off ([DEBUG_INFO_PRIV])
			local placed = (client.privileges and client.privileges.debug) or
					math.floor((client.hud_flags or 511) / 128) % 2 == 1
			-- Level 1 is one line and stays one line, as the module's:
			-- what makes a picture a picture of what it claims to be.
			-- Official's yaw is counter-clockwise from +Z and its pitch
			-- positive looking up; the words are the module's.
			if show_debug == 1 then
				local yaw = (360 - (client.yaw or 0)) % 360
				local cardinal = (yaw >= 45 and yaw < 135) and "West -X" or
						(yaw >= 135 and yaw < 225) and "South -Z" or
						(yaw >= 225 and yaw < 315) and "East +X" or "North +Z"
				status_text.text = string.format(
						"luanti_client | %s:%d | %s | %s%s",
						host, port, SETTINGS.mode, client.state, condition)..
						(placed and string.format(" | (%.1f, %.1f, %.1f)"..
						" | yaw: %.1f\194\176 %s | pitch: %.1f\194\176",
						avatar.x, avatar.y, avatar.z, yaw, cardinal,
						-(client.pitch or 0)) or "")
				return
			end
			-- Two lines rather than one: one line of this does not fit on a
			-- screen and what runs off the edge is the half that changes
			status_text.text = table.concat(lines, "\n").."\n"..
					string.format(
					"%s%s%s %s%s"..
					" | %d: %s | %s\n"..
					"%d objects | blocks: %d received,"..
					" %d in scene, %d to mesh | %d us to hand over"..
					" | %d commands waiting"..
					" | %d param2 pairs | %d hud | %d sounds"..
					" | %d particles"..
					" | media: %d files, %d to come%s",
					client.state, condition,
					placed and string.format(" | %.1f, %.1f, %.1f",
							avatar.x, avatar.y, avatar.z) or " |",
					avatar.fly and "flying" or
							(avatar.in_liquid and "swimming" or
							(avatar.on_ground and "on ground" or "falling")),
					placed and string.format(" | looking %.0f down, %.0f round",
							client.pitch or 0, client.yaw or 0) or "",
					wield_index, holding,
					pointed,
					view:object_count(),
					client.blocks_received, view:block_count(),
					view:dirty_count(), view.last_mesh_us,
					client.commands_waiting,
					view:pair_voxel_count(), hud_count,
					view:sound_count(), view:particle_count(),
					store:have_count(), store:missing_count(), reflections)
		end

		-- Mouse look, so the cursor is out of the way and does not stop at the
		-- edge of the window
		mouse_look(true, "the session started")


		-- WASD on the horizontal plane whatever the camera is pitched at,
		-- space to jump, ctrl to sneak, shift for a faster pace, and K to
		-- toggle flying. What comes out is where the client tells the server
		-- it is, so the server sends the blocks around it: the position is
		-- both the camera's and the player's.
		--
		-- MOVE_PLAYER -- the server putting the player somewhere, at the spawn
		-- or after its movement checks -- has to win over what the player is
		-- doing. client.position is what we told the server last frame, so it
		-- differing from where the player thinks it is means the server moved
		-- us.
		-- The tint of the node the camera is in, and only that node: Luanti
		-- takes it from the one the eye is in and blends nothing else in.
		-- simplified: post_effect_color_shaded, which dims the tint with the
		-- light where the camera is, is not read; the tint is the colour as
		-- given.
		local function update_tint()
			local pe = view:post_effect_at(
					math.floor(avatar.x + 0.5),
					math.floor(avatar.y + player.EYE_HEIGHT + 0.5),
					math.floor(avatar.z + 0.5))
			if pe == nil then
				tint_panel.visible = false
				return
			end
			tint_panel.visible = true
			tint_panel.width = magic.ui.root.width
			tint_panel.height = magic.ui.root.height
			tint_panel.color = magic.Color(pe.r / 255, pe.g / 255,
					pe.b / 255, pe.a / 255)
		end

		local function move(dtime)
			-- Where the server put us wins over where we think we are, and
			-- this has to happen before anything else: MOVE_PLAYER is the
			-- only thing that says where the player starts, and until the
			-- avatar has heard it we would be telling the server we are at
			-- the origin. That is what the server sends blocks around, so a
			-- form that is up from the first frame -- a death screen, which
			-- is what a server sends a player who joins dead -- would leave
			-- the whole session loading the wrong part of the world.
			local p = client.position
			if p.x ~= avatar.x or p.y ~= avatar.y or p.z ~= avatar.z then
				avatar:set_position(p.x, p.y, p.z)
			end
			-- A form or a chat line takes the mouse and the keys; the player
			-- stands still rather than walking blind behind it. So does a
			-- screen on the UI stack over the session's own -- the pause
			-- menu's settings and key screens -- with the cursor shown and
			-- free while one is up: on the box the view turned under them
			-- and the cursor vanished ([BOX_PLAYTEST_3] 2).
			local screen_above = uistack.main:top() ~= root
			if screen_above ~= screen_was_above then
				screen_was_above = screen_above
				if not form_on() and not chat_input then
					mouse_look(not screen_above, screen_above and
							"a screen over the game" or "back in the game")
				end
			end
			-- And behind the loading panel, which is a world not drawn yet
			if form_on() or chat_input or screen_above or loading_panel then
				lock.was, lock.unlocked_s = false, 0
				client:set_position(avatar.x, avatar.y, avatar.z)
				client:set_motion(0, 0, 0, 0)
				-- A drag on what is over the game turns nothing later
				if settings.touch then
					settings.touch.yaw, settings.touch.pitch = 0, 0
				end
				return
			end
			local dmouse = magic.input:GetMouseMove()
			if web and not settings.touch then
				local held = magic.input:IsMouseLocked()
				if held then
					lock.was, lock.unlocked_s = true, 0
				else
					dmouse = {x = 0, y = 0}
					lock.unlocked_s = lock.unlocked_s + dtime
					if lock.was or lock.unlocked_s > 0.5 then
						log:info("the pointer lock is not held: paused (" ..
								(lock.was and "lost" or "not given") .. ")")
						lock.was, lock.unlocked_s = false, 0
						open_pause_menu()
					end
				end
			end
			-- A touchscreen's finger turns the head (res/touch.lua), in
			-- degrees; the mouse SDL makes of it does not
			local touch = settings.touch
			local tyaw, tpitch = 0, 0
			if touch then
				dmouse = {x = 0, y = 0}
				tyaw, tpitch = touch.yaw, touch.pitch
				touch.yaw, touch.pitch = 0, 0
			end
			-- Luanti's yaw grows counterclockwise seen from above, so the
			-- mouse going right, which turns the player right, takes it down
			local yaw = client.yaw - dmouse.x * MOUSE_SENSITIVITY - tyaw
			-- Luanti's pitch is positive looking down, which is the way the
			-- mouse's own y goes
			local pitch = client.pitch + dmouse.y * MOUSE_SENSITIVITY + tpitch
			if pitch > 89 then pitch = 89 end
			if pitch < -89 then pitch = -89 end

			-- Where forward is, in world coordinates, for that yaw
			local yr = math.rad(yaw)
			local fx, fz = -math.sin(yr), math.cos(yr)
			local down = function(action)
				return magic.input:GetKeyDown(BIND[action].key) or
						(touch and touch.held[action]) or false
			end
			local wish = {x = 0, z = 0,
					jump = down("jump"),
					sneak = down("sneak"),
					fast = down("fast")}
			local keys = 0
			if down("forward") then
				wish.x, wish.z = wish.x + fx, wish.z + fz
				keys = keys + luanti.KEY_UP
			end
			if down("back") then
				wish.x, wish.z = wish.x - fx, wish.z - fz
				keys = keys + luanti.KEY_DOWN
			end
			if down("right") then
				wish.x, wish.z = wish.x + fz, wish.z - fx
				keys = keys + luanti.KEY_RIGHT
			end
			if down("left") then
				wish.x, wish.z = wish.x - fz, wish.z + fx
				keys = keys + luanti.KEY_LEFT
			end
			if wish.jump then keys = keys + luanti.KEY_JUMP end
			if wish.sneak then keys = keys + luanti.KEY_SNEAK end
			if wish.fast then keys = keys + luanti.KEY_AUX1 end
			-- Zoom while Z is held, behind the zoom privilege
			-- ([VIEW_KEYS]): the control bit goes to the server, the fov
			-- to the camera
			-- gated by the player's own zoom_fov property as official is
			-- (0 off, 15 in creative)
			local zoom_fov = 0
			for _, obj in pairs(world_objects) do
				if obj.is_self and obj.props then
					zoom_fov = obj.props.zoom_fov or 0
				end
			end
			local zooming = down("zoom") and zoom_fov > 0
			if zooming then keys = keys + luanti.KEY_ZOOM end
			if zooming ~= zoom_held then
				zoom_held = zooming
				view:set_zoom(zooming, zoom_fov)
			end

			local x, y, z = avatar:update(dtime, wish)
			-- **Fall damage** (ClientEnvironment::step): Luanti's client
			-- works out what a landing costs and sends that. A node a
			-- second over 14 is a point, scaled by the fall_damage_add_percent
			-- of the node landed on and of the player's armor.
			-- simplified: the node is the one under the feet after the
			-- step, not the one the collision hit; they differ only at an
			-- edge.
			if avatar.landed_at then
				local speed = avatar.landed_at
				avatar.landed_at = nil
				local armor = {}
				for _, obj in pairs(world_objects) do
					if obj.is_self then
						armor = obj.armor_groups or {}
					end
				end
				local node = view:groups_at(math.floor(x + 0.5),
						math.floor(y + 0.4), math.floor(z + 0.5)) or {}
				local factor = (1 + (node.fall_damage_add_percent or 0) / 100) *
						(1 + (armor.fall_damage_add_percent or 0) / 100)
				speed = speed * factor
				if speed > 14 and factor > 0 and (armor.immortal or 0) == 0 then
					local damage = math.min(math.floor(speed - 14 + 0.5), 65535)
					if damage > 0 then
						client:send_damage(damage)
					end
				end
			end
			client:set_position(x, y, z, pitch, yaw)
			client:set_motion(avatar.vx, avatar.vy, avatar.vz, keys)
			local speed_xz = math.sqrt(avatar.vx * avatar.vx + avatar.vz * avatar.vz)
			-- The swing, and its sounds as it crosses 0.15
			if digging or own.phase > 0 then
				local was = own.phase
				own.phase = own.phase + dtime * 3.5
				if was < 0.15 and own.phase >= 0.15 then
					swing_sound()
				end
				if own.phase >= 1 then
					own.phase = 0
				end
			end
			-- A footstep a stride, on what is under the feet
			if avatar.on_ground and speed_xz > 1 and (not own.foot or
					(x - own.foot[1]) ^ 2 + (z - own.foot[2]) ^ 2 > 1.9 ^ 2) then
				own.foot = {x, z}
				local under = view:node_at(math.floor(x + 0.5),
						math.floor(y - 0.5), math.floor(z + 0.5))
				local fdef = under and node_defs and node_defs[under]
				local f = fdef and own_sound(fdef.sound_footstep)
				log:debug("footstep on "..tostring(fdef and fdef.name)..": "..
						tostring(f))
			end
			local m = motion:update(dtime, {
				walking = speed_xz > 1 and avatar.on_ground,
				swimming = avatar.in_liquid and
						(speed_xz > 1 or math.abs(avatar.vy) > 1),
				climbing = avatar.climbing and math.abs(avatar.vy) > 1,
				flying = avatar.fly_active or avatar.fly,
				speed = math.sqrt(speed_xz * speed_xz + avatar.vy * avatar.vy),
				digging = digging or own.phase > 0,
				dig_anim = own.phase,
			})
			-- Sideways along the camera's right, and up; Luanti's yaw is
			-- counterclockwise from +Z seen from above
			local ry = math.rad(yaw)
			local cx = x + m.offset[1] * math.cos(ry)
			local cy = y + player.EYE_HEIGHT + m.offset[2]
			local cz = z + m.offset[1] * math.sin(ry)
			local cpitch, cyaw = pitch, yaw
			if camera_mode ~= 1 then
				-- The own model at the player's own feet, turned with the
				-- look ([BOX_PLAYTEST_4] 4, 5)
				view.self_pose = {x, y, z, yaw}
				-- Third person, official's Camera::update: back along the
				-- look (or ahead, turned round) up to 2.75 nodes, a fifth
				-- up, the height following the look past 1.2, half a node
				-- short of a solid node. Luanti's yaw is counterclockwise
				-- from +z: the look is (-sin yaw, -sin pitch, cos yaw)
				local rp = math.rad(pitch)
				local dx, dy, dz = -math.sin(ry) * math.cos(rp), -math.sin(rp),
						math.cos(ry) * math.cos(rp)
				if camera_mode == 3 then
					dx, dy, dz = -dx, -dy, -dz
				end
				local ex, ey, ez = cx, cy, cz
				cy = ey + 0.2
				for i = 10, 27 do
					local t = i / 10
					cx = ex - dx * t
					cz = ez - dz * t
					if i > 12 then
						cy = ey - dy * t
					end
					-- A block this client does not hold yet is not a wall:
					-- is_solid() answers "solid" for one, which behind a
					-- player who has just joined stopped the camera a node
					-- back and filled the frame with their own model
					-- ([BOX_PLAYTEST_4] 3's "wonky"). Official's camera
					-- reads its own map the same way.
					local bx, by, bz = math.floor(cx + 0.5),
							math.floor(cy + 0.5), math.floor(cz + 0.5)
					if view:node_at(bx, by, bz) ~= nil and
							view:is_solid(bx, by, bz) then
						cx, cy, cz = cx + dx * 0.5, cy + dy * 0.5, cz + dz * 0.5
						break
					end
				end
				if camera_mode == 3 then
					cpitch, cyaw = -pitch, yaw + 180
				end
			end
			-- Over the shoulder when the settings say so ([OVER_SHOULDER]):
			-- the eye to the right and a little up, the look and the
			-- pointing ray unchanged. Luanti's yaw is counterclockwise
			-- from +z, so the right is yaw - 90.
			if camera_mode == 2 and SETTINGS.shoulder ~= 0 then
				local rr = math.rad(yaw - 90)
				cx = cx - math.sin(rr) * 0.4
				cz = cz + math.cos(rr) * 0.4
				cy = cy + 0.15
			end
			view:set_camera(cx, cy, cz, cpitch, cyaw, m.roll)
		end

		-- Set once the session is over -- the server said no, the connection
		-- went away, or escape was pressed -- and everything this session put
		-- on the screen has been taken back. leave() is what does that; it is
		-- defined further down, where all of it is in scope.
		local left = false
		local leave

		-- A plain subscription rather than root:SubscribeToStackEvent(), which
		-- only fires while the UI element has focus; the world has to keep
		-- streaming whatever the UI is doing. Unsubscribed by leave().
		-- How often the network and map counters go in the log. A session
		-- that loaded badly is diagnosed from these afterwards and from
		-- nothing else, so they are at info rather than verbose.
		local NET_LINE_INTERVAL = 2.0
		local net_line_timer = 0

		-- Frame smoothness. A stutter is only worth a line when it is far
		-- above what the session is otherwise doing, so the means follow the
		-- session -- exponential, and slow enough that a spike does not move
		-- them much -- and a frame several times over gets a line saying
		-- what else it was doing. What to correlate with what is then in the
		-- log rather than in a guess.
		local SLOW_FRAME_FACTOR = 3
		-- Under this nothing is a stutter, whatever the mean is: three times
		-- half a millisecond is still a smooth frame
		local SLOW_FRAME_FLOOR_US = 3000
		-- And a burst of them says what one of them says, so they are rate
		-- limited and counted instead
		local SLOW_FRAME_INTERVAL = 0.2
		local mean_lua_us = nil
		local mean_hand_us = nil
		local slow_frames = 0
		local slow_frame_wait = 0

		-- What flush_objects() built last frame, for the slow-frame line
		local last_objects_built = 0

		local function slow_frame_check(dtime, frame_t0)
			local lua_us = buildat.get_time_us() - frame_t0
			local hand_us = view.last_frame_mesh_us or 0
			mean_lua_us = mean_lua_us and
					mean_lua_us * 0.98 + lua_us * 0.02 or lua_us
			mean_hand_us = mean_hand_us and
					mean_hand_us * 0.98 + hand_us * 0.02 or hand_us
			slow_frame_wait = slow_frame_wait - dtime
			local slow = (hand_us > SLOW_FRAME_FLOOR_US and
					hand_us > mean_hand_us * SLOW_FRAME_FACTOR) or
					(lua_us > SLOW_FRAME_FLOOR_US and
					lua_us > mean_lua_us * SLOW_FRAME_FACTOR)
			if not slow then
				return
			end
			slow_frames = slow_frames + 1
			if slow_frame_wait > 0 then
				return
			end
			slow_frame_wait = SLOW_FRAME_INTERVAL
			log:info(string.format(
					"slow frame %d: lua %.1f ms (mean %.1f), handover "..
					"%.1f ms (mean %.1f), %d blocks meshed (worst %.1f ms)"..
					", %d new param2 pairs, %d objects built, commands "..
					"%.1f ms (%d of them, "..
					"worst %s at %.1f ms), %d dirty, %d waiting, last "..
					"frame %.0f ms%s",
					slow_frames, lua_us / 1000, mean_lua_us / 1000,
					hand_us / 1000, mean_hand_us / 1000,
					view.last_frame_meshed or 0,
					(view.worst_mesh_us or 0) / 1000,
					view.last_frame_pairs or 0,
					last_objects_built,
					(client.last_command_us or 0) / 1000,
					client.last_commands or 0,
					tostring(client.worst_command),
					(client.worst_command_us or 0) / 1000,
					view:dirty_count(), client.commands_waiting,
					dtime * 1000,
					registry_step and ", registry building" or ""))
		end

		local update_cb = magic.SubscribeToEvent("Update",
				function(event_type, event_data)
			local dtime = event_data:GetFloat("TimeStep")
			local frame_t0 = buildat.get_time_us()
			client:update(dtime)
			net_line_timer = net_line_timer + dtime
			if net_line_timer >= NET_LINE_INTERVAL then
				net_line_timer = 0
				log:info(client:net_line())
			end
			-- The client may have found out during that update that the
			-- session is over, and leave() has then taken the screen apart:
			-- what is below here would put some of it back
			if left then
				return
			end
			move(dtime)
			update_tint()
			if settings.touch then
				digging = settings.touch.dig and not form_on()
			end
			update_dig(dtime)
			objects.interpolate(world_objects, dtime)
			for id, obj in pairs(world_objects) do
				if obj.visual_stale and not obj.is_self then
					queue_object(id)
				end
			end
			-- The player's own object, drawn in the third-person views: the server
			-- sends no position for it, so it stands where the avatar is, turned
			-- the way the player looks ([THIRD_PERSON])
			if camera_mode ~= 1 then
				for _, obj in pairs(world_objects) do
					if obj.is_self then
						obj.position = {avatar.x, avatar.y, avatar.z}
						obj.yaw = client.yaw
					end
				end
			end
			view:place_objects(world_objects, dtime)
			last_objects_built = flush_objects()
			-- The blocks whose light a node change may have moved. The
			-- server keeps track of what it has sent us, so saying we no
			-- longer have one is what makes it send that one again -- with
			-- the light it works out itself, which is not arithmetic this
			-- client does. The stale block is drawn until it arrives.
			local again = view:refresh_wanted(8)
			if #again > 0 then
				client:send_deleted_blocks(again)
			end
			view:update_particles(dtime, world_objects)
			view:update_sounds(dtime)
			view:update_fov(dtime)
			update_hud()
			if chat_wanted then
				chat_wanted = false
				open_chat()
			end
			session:frame(dtime)
			-- The clock the client carries on between the server's word for
			-- it, so that the day passes rather than arrives every few
			-- seconds; see client.lua's update(). Handing it over every
			-- frame costs nothing -- the world only records it, and draws
			-- the sky from it in its own update.
			local time_of_day = FORCE_TIME or client.time_of_day_f
			if time_of_day then
				-- A server can say what the light is whatever the time is,
				-- which is how a game lights another dimension; the sun
				-- still goes where the time says, as it does in Luanti.
				view:set_daylight(daynight_ratio(time_of_day,
						client.day_night_override,
						view:sun_height(time_of_day)), time_of_day)
			end
			-- Nothing is dropped until the server has said where the player
			-- is: until then the camera is at the origin and everything that
			-- has arrived looks far away, and a dropped block is one the
			-- server will not send again
			view:update(dtime, client.state == "ready" and DROP_DISTANCE or nil)
			if view.minimap then
				view.minimap.view.visible = show_hud and not loading and
						not world_wait and
						luanti_hud.has_flag(hud_flags, luanti_hud.FLAG.minimap)
						and luanti_hud.minimap.MODES[view.minimap.mode].nodes > 0
				view.minimap:follow(view.camera_node.worldPosition, dtime)
			end

			-- Media requests go out a batch a frame, and the registry is
			-- rebuilt once what was asked for has arrived
			if registry_step then
				step_registry()
			elseif #to_ask > 0 then
				local batch = {}
				for _ = 1, math.min(#to_ask, MEDIA_PER_REQUEST) do
					batch[#batch + 1] = table.remove(to_ask)
				end
				client:request_media(batch)
				media_progress_us = buildat.get_time_us()
				media_asked_us = media_asked_us or media_progress_us
			elseif registry_stale and node_defs then
				local waited = media_progress_us and
						(buildat.get_time_us() - media_progress_us) /
						1000000 or 0
				-- The announcement is waited for as well as the files it
				-- names: the definitions can arrive first, and a registry
				-- built before the media is a registry of placeholders that
				-- has to be built all over again
				local settled = store:missing_count() == 0 and
						(announced ~= nil or not loading)
				if settled or waited > MEDIA_WAIT_S then
					rebuild_registry()
				end
			end
			if world_wait then
				local drawn, waiting = false, nil
				if client.state == "ready" then
					drawn, waiting = view:drawn_around(avatar.x, avatar.y,
							avatar.z, 2)
				end
				local waited = first_block_us and
						(buildat.get_time_us() - first_block_us) / 1000000 or 0
				if drawn or waited >= WORLD_WAIT_S then
					world_wait = false
					log:info("loading: the world is in, "..(drawn and
							"drawn round the player" or
							string.format("%.0f s after the first block", waited)))
					if loading_panel then
						loading_panel:Remove()
						loading_panel = nil
					end
				elseif loading_panel then
					loading_text.text = "Loading "..host..":"..port..
							"\n\nthe world: "..(waiting and
							waiting.." blocks round you to draw" or
							"waiting for the spawn")
					loading_panel.width = magic.ui.root.width
					loading_panel.height = magic.ui.root.height
				end
			end
			if loading and loading_panel then
				local what = "waiting for the game's definitions"
				if registry_step then
					what = "building the voxel types"
				elseif announced then
					what = "media: "..store:have_count().." of "..
							#announced.." files, "..
							(#to_ask + store:missing_count()).." to come"
				end
				loading_text.text = "Loading "..host..":"..port.."\n\n"..what
				-- The root's size, every frame, because the window can be
				-- resized while this is up
				loading_panel.width = magic.ui.root.width
				loading_panel.height = magic.ui.root.height
			end
			set_counters()
			slow_frame_check(dtime, frame_t0)
		end)

		-- The line the player types in: a dialog with a text field and the
		-- two buttons a player expects, because a bare line edit at the
		-- bottom of the screen is not something anyone can find.
		--
		-- The field is a LineEdit rather than something built here: editing a
		-- line -- the cursor, selection, backspace, paste -- is what Urho3D's
		-- own already does. Enter arrives as its TextFinished, because a
		-- stack event handler does not fire while it has the focus.
		local chat_window = nil
		local chat_input_cb = nil
		local chat_key_cb = nil
		local chat_buttons = nil

		local function close_chat()
			if not chat_input then
				return
			end
			if chat_input_cb then
				magic.UnsubscribeFromEvent(chat_input, "TextFinished",
						chat_input_cb)
				chat_input_cb = nil
			end
			if chat_key_cb then
				magic.UnsubscribeFromEvent("KeyDown", chat_key_cb)
				chat_key_cb = nil
			end
			chat_window:Remove()
			chat_window = nil
			chat_input = nil
			chat_buttons = nil
			if not form_on() then
				mouse_look(true, "the chat closed")
			end
		end

		local function send_chat()
			local text = chat_input:GetText()
			log:verbose("chat: sending \""..text.."\"")
			close_chat()
			if text ~= "" then
				client:send_chat(text)
			end
		end

		function open_chat()
			if chat_input then
				return
			end
			log:info("chat: the line opened")
			local ui_root = magic.ui.root
			local w = math.min(560, ui_root.width - 40)
			local h = 96
			local ox = math.floor((ui_root.width - w) / 2)
			-- Above the hotbar and the chat log, which are what is at the
			-- bottom of the screen; on a touchscreen at the top, out from
			-- under the on-screen keyboard, over the chat
			-- ([TOUCH_CHAT_CLUTTER])
			local oy = ui_root.height - h - 180
			if settings.touch then
				oy = 8
			end

			chat_window = ui_root:CreateChild("BorderImage")
			-- The style is inherited by everything under it, which is what
			-- the line edit's own text needs to have a font at all
			chat_window.defaultStyle = style
			chat_window.texture = magic.cache:GetResource("Texture2D",
					"luanti_client/res/white.png")
			chat_window.color = magic.Color(0.10, 0.10, 0.13, 0.95)
			chat_window.size = magic.IntVector2(w, h)
			chat_window:SetPosition(ox, oy)
			-- Over the chat and the touch controls (50)
			chat_window.priority = 60
			-- An element Urho3D has not been told is enabled is not hit by a
			-- click, and then no click event carries a position at all
			chat_window.enabled = true

			local caption = chat_window:CreateChild("Text")
			caption.defaultStyle = style
			caption:SetStyleAuto()
			caption.text = "Say something (a line starting with / is a"..
					" command)"
			caption:SetFontSize(12)
			caption:SetPosition(12, 10)
			caption.color = magic.Color(0.8, 0.8, 0.85)

			chat_input = chat_window:CreateChild("LineEdit")
			-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
			chat_input.textCopyable = true
			chat_input.textSelectable = true
			chat_input.defaultStyle = style
			chat_input:SetStyleAuto()
			chat_input:SetPosition(12, 30)
			-- size rather than fixedWidth/fixedHeight: the parent has no
			-- layout to size it, and the element stays 0x0
			chat_input.size = magic.IntVector2(w - 24, 26)
			chat_input.enabled = true
			-- A box of its own, so the field is visible before anything has
			-- been typed into it
			chat_input.texture = magic.cache:GetResource("Texture2D",
					"luanti_client/res/white.png")
			chat_input.color = magic.Color(0.02, 0.02, 0.03, 0.9)
			chat_input:SetText("")
			chat_input:SetFocus(true)

			-- The two buttons, as boxes with a word in them: what a click
			-- landed on is worked out from the rectangles, the same way a
			-- form's buttons are, rather than from Urho3D's own button
			-- events, which do not reach the sandbox with a position
			chat_buttons = {origin = {ox, oy}, items = {}}
			local bw, bh = 90, 26
			local by = h - bh - 10
			local labels = {{"Send", w - 12 - bw * 2 - 8, send_chat},
					{"Cancel", w - 12 - bw, close_chat}}
			-- The Declutter checkbox, a touchscreen's, at the left
			if settings.touch then
				labels[#labels + 1] = {(declutter and "[x]" or "[ ]") ..
						" Declutter", 12, function()
					set_declutter(not declutter)
					local t = chat_buttons.declutter
					t.text = (declutter and "[x]" or "[ ]") .. " Declutter"
				end, 110}
			end
			for _, b in ipairs(labels) do
				local bw = b[4] or bw
				local box = chat_window:CreateChild("BorderImage")
				box.texture = magic.cache:GetResource("Texture2D",
						"luanti_client/res/white.png")
				box.color = magic.Color(0.30, 0.30, 0.38, 0.95)
				box.size = magic.IntVector2(bw, bh)
				box:SetPosition(b[2], by)
				box.enabled = true
				local t = box:CreateChild("Text")
				t.defaultStyle = style
				t:SetStyleAuto()
				t.text = b[1]
				t:SetFontSize(13)
				t:SetAlignment(HA_CENTER, VA_CENTER)
				if b[4] then
					chat_buttons.declutter = t
				end
				chat_buttons.items[#chat_buttons.items + 1] =
						{x = b[2], y = by, w = bw, h = bh, action = b[3]}
			end

			mouse_look(false, "the chat opened")
			chat_input_cb = magic.SubscribeToEvent(chat_input, "TextFinished",
					send_chat)
			-- Escape cancels. A plain subscription, because the line edit has
			-- the focus and the stack's own handler is then quiet.
			chat_key_cb = magic.SubscribeToEvent("KeyDown",
					function(event_type, event_data)
				if event_data:GetInt("Key") == KEY_ESCAPE then
					close_chat()
				end
			end)
		end

		local function chat_click(x, y)
			if not chat_buttons then
				return
			end
			local lx = x - chat_buttons.origin[1]
			local ly = y - chat_buttons.origin[2]
			for _, b in ipairs(chat_buttons.items) do
				if lx >= b.x and lx < b.x + b.w and
						ly >= b.y and ly < b.y + b.h then
					b.action()
					return
				end
			end
		end

		-- The right button's, and a touchscreen's tap
		local function place_or_activate()
			if pointed_object or (pointed_under and pointed_above) then
				place()
			else
				-- Pointing at nothing: the item's secondary action, which
				-- is what handlePointingAtNothing() sends
				client:interact(luanti.INTERACT_ACTIVATE, wield_index - 1)
			end
		end

		-- The dig button: the two events say whether it is held, and the
		-- press is when a use or a hit goes out (Input's
		-- GetMouseButtonDown would say the state, not the moment).
		local mouse_down_cb = magic.SubscribeToEvent("MouseButtonDown",
				function(event_type, event_data)
			-- A touchscreen's first finger is also the left button, which
			-- SDL makes of it: res/touch.lua says when a dig is held
			if form_on() or settings.touch then
				return -- The click goes to the form; see UIMouseClick
			end
			-- The pointer lock asked for again, which a browser grants on a
			-- click (lost to Escape, or asked for at the join with no click
			-- to go on); Urho3D asks only while it is not held
			if web and not chat_input and not screen_was_above then
				magic.input:SetMouseMode(magic.MM_RELATIVE)
			end
			if event_data:GetInt("Button") == MOUSEB_LEFT then
				if held_usable() then
					-- Once per press, which is what wasKeyPressed() gives
					-- Luanti: a held button must not eat the whole stack
					client:interact(luanti.INTERACT_USE, wield_index - 1,
							pointed_thing())
				else
					digging = true
					if pointed_object then
						-- The hit goes out on the way down rather than
						-- waiting for the next frame's update_dig: a click
						-- can be over before one runs
						client:interact(luanti.INTERACT_START_DIGGING,
								wield_index - 1, {object = pointed_object})
						hit_wait = OBJECT_HIT_DELAY
					end
				end
			end
		end)

		local mouse_move_cb = magic.SubscribeToEvent("MouseMove",
				function(event_type, event_data)
					-- Input reports window pixels; a form is laid out in
					-- the UI's own coordinates, which are those divided by
					-- the UI scale -- the same ones a click arrives in
					local scale = magic.ui:GetScale()
					if not scale or scale <= 0 then
						scale = 1
					end
					-- A scrollbar's thumb is dragged while the button is
					-- held over it ([FORMSPEC_SCROLL])
					session:hover(math.floor(event_data:GetInt("X") / scale),
							math.floor(event_data:GetInt("Y") / scale),
							magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT))
				end)

		-- Where a click landed, which MouseButtonDown does not say
		local ui_click_cb = magic.SubscribeToEvent("UIMouseClick",
				function(event_type, event_data)
			local button = event_data:GetInt("Button")
			-- A touchscreen's taps are clicked by res/touch.lua
			if settings.touch then
				return
			end
			if form_on() then
				session:click(event_data:GetInt("X"), event_data:GetInt("Y"),
						button_name(button))
			elseif chat_input and button == MOUSEB_LEFT then
				chat_click(event_data:GetInt("X"), event_data:GetInt("Y"))
			end
		end)
		-- The wheel scrolls what of a form it is over
		local mouse_wheel_cb = magic.SubscribeToEvent("MouseWheel",
				function(event_type, event_data)
					session:wheel(event_data:GetInt("Wheel"))
				end)

		local mouse_up_cb = magic.SubscribeToEvent("MouseButtonUp",
				function(event_type, event_data)
			if settings.touch then
				return
			end
			if event_data:GetInt("Button") == MOUSEB_LEFT then
				digging = false
				hit_wait = 0
			end
			-- A stack picked up by the press and let go over another
			-- slot: a drag
			session:release(button_name(event_data:GetInt("Button")))
			if event_data:GetInt("Button") == MOUSEB_RIGHT and
					not form_on() then
				-- On the way up rather than the way down, so that holding
				-- the button does not place a stack of nodes at once
				place_or_activate()
			end
		end)

		-- Everything this session put on the screen or subscribed to, taken
		-- back. What is left after it is the empty stack the connect dialog
		-- was pushed on.
		local exit_cb = nil
		leave = function()
			if left then
				return
			end
			left = true
			if ui_utils.set_in_game then
				ui_utils.set_in_game(false)
			end
			if buildat.set_running_game then
				buildat.set_running_game(nil)
			end
			magic.UnsubscribeFromEvent("Update", update_cb)
			magic.UnsubscribeFromEvent("MouseButtonDown", mouse_down_cb)
			magic.UnsubscribeFromEvent("MouseButtonUp", mouse_up_cb)
			magic.UnsubscribeFromEvent("MouseMove", mouse_move_cb)
			magic.UnsubscribeFromEvent("UIMouseClick", ui_click_cb)
			magic.UnsubscribeFromEvent("MouseWheel", mouse_wheel_cb)
			magic.UnsubscribeFromEvent("ScreenMode", screen_mode_cb)
			if exit_cb then
				magic.UnsubscribeFromEvent("ExitRequested", exit_cb)
				exit_cb = nil
			end
			session:close(false)
			ui:drop_tooltip()
			close_chat()
			chat_text:Remove()
			info_text:Remove()
			tint_panel:Remove()
			status_text:Remove()
			if view.minimap then
				view.minimap:destroy()
				view.minimap = nil
			end
			if loading_panel then
				loading_panel:Remove()
				loading_panel = nil
			end
			if hud then
				hud:Remove()
				hud = nil
			end
			game_hud:draw({})
			game_hud.root:Remove()
			for _, bar in ipairs(crosshair) do
				bar:Remove()
			end
			hotbar_row:destroy()
			if settings.touch then
				settings.touch.destroy()
				settings.touch = nil
			end
			mouse_look(false, "the session ended")
			client:disconnect()
			view:close()
			-- With what is over it: the pause menu, its key and settings
			-- screens, when the window is closed from under them
			uistack.main:pop_to(root, true)
		end

		-- The pause menu ([LUANTI_PAUSE]): settings.lua's screen on the UI
		-- stack, which holds the world as the key and settings screens do.
		-- Its Leave is the window's own close: the disconnect goes out, and
		-- from buildat's menu the grid underneath is what is left.
		-- The overlay's Discuss leaves through this ([OVERLAY_DISCUSS]),
		-- and has the server off the list and its game
		if buildat.set_running_game then
			buildat.set_running_game({leave = function() leave() end,
					claim = settings.origin,
					game = settings.origin and settings.origin.game})
		end
		open_pause_menu = function()
			settings.show_pause{bindings = BINDINGS, view = view,
					open_chat = open_chat, leave = function(stay)
				leave()
				if SETTINGS.cancel_exits and not stay then
					buildat.quit()
				end
			end}
		end

		-- The client is going away: the window was closed, or a command
		-- sequence ended, or something else asked the engine to exit. The
		-- one thing that has to happen is the disconnect leave() sends --
		-- Luanti's server keeps a player who vanishes without saying so
		-- until it times out, and refuses the next client to use that name
		-- meanwhile.
		exit_cb = magic.SubscribeToEvent("ExitRequested", function()
			leave()
		end)

		-- The server said no, or the connection went away. Whatever is on the
		-- screen is no use any more, and a client that writes a line in the
		-- corner and then sits there is not telling anybody anything: the
		-- reason goes in a dialog, and closing that closes the client.
		client.on_failed = function(text)
			log:info("Session ended: "..(text:gsub("\n", " ")))
			leave()
			ui_utils.show_message_dialog(text, function()
				-- Launched from buildat's menu the grid is underneath, and
				-- closing the client over it would be leaving the launcher
				-- for a server's refusal ([BOX_PLAYTEST_2] 2)
				if got_content and SETTINGS.cancel_exits then
					buildat.quit()
				else
					-- Nothing of the game ever arrived, so this was the
					-- address, the name or the password: back to where they
					-- are typed
					show_connect_dialog(host..":"..port, name)
				end
			end)
		end

		-- A key's action, which a touchscreen's buttons press as well
		local function on_key(key)
			if chat_input or chat_wanted then
				-- The dialog has the keys. Enter arrives as the line edit's
				-- TextFinished and escape as the plain subscription made in
				-- open_chat; a stack handler does not fire at all once the
				-- line edit has the focus.
				return
			end
			-- Luanti's own keys for these, out of BINDINGS at the top of
			-- this file. A server that does not give the player the fly and
			-- noclip privileges pulls them back.
			-- Official's camera mode key ([THIRD_PERSON]): first person,
			-- third from behind, third from the front, under the server's
			-- TOCLIENT_CAMERA restriction; the own model is drawn in the
			-- third views and taken back out in first
			if key == BIND.fog.key then
				fog_on = not fog_on
				view:set_fog(fog_on)
				add_chat(fog_on and "Fog enabled" or "Fog disabled")
			end
			if key == BIND.camera.key then
				local allowed = client.camera_mode_allowed or 0
				local next_mode = camera_mode % 3 + 1
				if allowed ~= 0 then
					next_mode = allowed
				end
				camera_mode = next_mode
				for id, obj in pairs(world_objects) do
					if obj.is_self then
						if camera_mode == 1 then
							view:remove_object(id)
						else
							queue_object(id)
						end
					end
				end
				add_chat(({"First person view", "Third person view",
						"Third person view (front)"})[camera_mode])
			end
			if key == BIND.fly.key then
				-- The server's own movement check pulls a player without
				-- the privilege back; saying so is the whole difference
				-- between that and the world feeling broken.
				if not avatar.fly and client.privileges and
						not client.privileges.fly then
					add_chat("Flying: the server has not given you the "..
							"\"fly\" privilege")
					return
				end
				avatar.fly = not avatar.fly
				add_chat(avatar.fly and "Flying" or "Walking")
			end
			-- T says something, which is Luanti's own key for it; a line
			-- starting with a slash is a command
			if key == BIND.chat.key and not chat_input then
				chat_wanted = true
				return
			end
			if key == BIND.inventory.key then
				if form_on() then
					session:close(true)
				else
					open_form(inventory_spec, "", "inventory")
				end
			end
			-- The number keys pick a hotbar slot, as they do in Luanti
			if key >= BIND.hotbar.first and key <= BIND.hotbar.last then
				wield_index = key - BIND.hotbar.first + 1
			end
			-- Q throws the wielded stack in front of the player, or one
			-- item of it while sneaking, which is Luanti's own key and its
			-- own rule
			if key == BIND.drop.key and not form_on() then
				local held_stack = wielded()
				if held_stack and held_stack.count > 0 then
					local single = magic.input:GetKeyDown(BIND.sneak.key)
					client:send_inventory_drop(single and 1 or 0,
							"current_player", "main", wield_index)
				end
			end
			-- Luanti's own keys for what is on the screen
			if key == BIND.hud.key then
				show_hud = not show_hud
				update_hud()
			end
			if key == BIND.chatlog.key then
				show_chat = not show_chat
			end
			if key == BIND.debug.key then
				show_debug = (show_debug + 1) % 3
				status_text.visible = show_debug > 0
				local kept = settings.load()
				kept.debug_info = show_debug
				settings.save(kept)
				-- In the log as well, as vanilla's: a check reads the text
				if show_debug > 0 then
					set_counters()
					log:info("F5: "..status_text.text:gsub("\n", " | "))
				end
			end
			if key == BIND.minimap.key and view.minimap then
				add_chat(view.minimap:next_mode())
			end
			if key == BIND.noclip.key then
				avatar.noclip = not avatar.noclip
				add_chat(avatar.noclip and "Through walls" or "Solid walls")
			end
			if key == BIND.menu.key then
				-- Whatever is open takes escape for itself: closing that is
				-- what a player means by it. With nothing open it is the
				-- pause menu, which is where leaving lives now -- escape no
				-- longer ends the session by itself. The chat line has a
				-- key handler of its own that closes it, so this only has
				-- to keep out of the way while it is up.
				if form_on() then
					session:close(true)
				elseif not chat_input then
					open_pause_menu()
				end
			end
		end
		root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
			on_key(event_data:GetInt("Key"))
		end)

		-- **Touch controls** on a touchscreen (res/touch.lua, vanilla's
		-- too); nil elsewhere, and then the mouse is what it always was
		if buildat.get_env("BUILDAT_TOUCH") == "1" then
			settings.touch = buildat.run_extension_file("res/touch.lua")({
				on_key = on_key,
				BIND = BIND,
				pause = function() open_pause_menu() end,
				-- Not through a screen over the game or the chat line
				place = function()
					if uistack.main:top() == root and not chat_input then
						place_or_activate()
					end
				end,
				set_wield = function(i) wield_index = i end,
				inventory = function() on_key(BIND.inventory.key) end,
				chat = function() on_key(BIND.chat.key) end,
				hotbar = function()
					local _, _, slot, margin = hotbar_row:metrics()
					return client.hud_params and client.hud_params[
							luanti_hud.PARAM_HOTBAR_ITEMCOUNT] or
							HOTBAR_SLOTS, slot, margin
				end,
				-- The chat line is a form to the fingers: a tap on its
				-- boxes (Send, Cancel, Declutter), no look and no place
				form_open = function() return form_on() or chat_input ~= nil end,
				form_press = function(x, y)
					if chat_input then
						chat_click(x, y)
					else
						session:hover(x, y, true)
						session:click(x, y, "left")
					end
				end,
				form_move = function(x, y)
					if not chat_input then
						session:hover(x, y, true)
					end
				end,
				form_release = function(x, y)
					if not chat_input then
						session:hover(x, y, false)
						session:release("left")
					end
				end,
				form_right = function(x, y)
					if not chat_input then
						session:click(x, y, "right")
					end
				end,
				clutter = function()
					set_declutter(not declutter)
					return declutter
				end,
			})
			settings.touch.sensitivity = settings.load().touch_sensitivity
			-- And Luanti's Android autojump
			avatar.autojump = true
			-- The session hid the pointer before these were here
			mouse_look(true, "touch controls on")
			log:info("touch controls on")
		end
	end, {description = "Luanti server at "..host..":"..port})
end

-- address and name are what to start the fields with; without them the
-- environment's own defaults. What passes them is a session that ended before
-- it got anywhere: whatever was wrong with them, they are what to fix.
show_connect_dialog = function(address, name)
	local root = uistack.main:push({desc="luanti_client connect"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "launch_menu/res/main_style.xml")

	-- **launch_menu's Servers layout** (playtest, 2026-10-07): a
	-- title, the source and the filter, the list, and beside it the
	-- picked server, the fields and Join
	local PANEL_WIDTH = 300
	local narrow = magic.ui.root.width < 760
	local width = math.min(magic.ui.root.width - 40, 1000)
	local list_w = narrow and width - 32 or width - 32 - PANEL_WIDTH - 12
	-- A fifth of the height to spare: a phone's browser bars take some of
	-- the page as it scrolls (playtest, 2026-10-07)
	local room = math.floor(magic.ui.root.height * 0.8) - 220 - (narrow and 330 or 0)
	local menu = ui_utils.vertical_menu(root, {spacing = 8,
			padding = magic.IntRect(16, 12, 16, 12)})
	local outer = menu.window
	outer:SetFixedWidth(width)

	local title = outer:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Join a Luanti server"
	title:SetFontSize(20)

	-- The list of servers on the left -- the addresses this client has
	-- used, or Luanti's official list -- and the fields on the right; a
	-- pick fills the address, a second pick connects ([SERVER_LIST])
	local sources = outer:CreateChild("UIElement")
	sources:SetLayout(LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
	local columns = outer:CreateChild("UIElement")
	columns:SetLayout(narrow and LM_VERTICAL or LM_HORIZONTAL, 12,
			magic.IntRect(0, 0, 0, 0))
	local left = columns:CreateChild("UIElement")
	left:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(list_w)
	local window = columns:CreateChild("UIElement")
	window:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	window:SetFixedWidth(narrow and width - 32 or PANEL_WIDTH)
	-- Made before the fields, so the picked server is described above them
	local pick
	local list = ui_utils.server_list(left, {width = list_w,
			height = math.max(120, room), panel = window},
			function(row, second) pick(row, second) end)

	local address_edit = labeled_edit(window, "Address",
			address or DEFAULT_ADDRESS)
	local name_edit = labeled_edit(window, "Player name", name or DEFAULT_NAME)
	local password_edit = labeled_edit(window, "Password", "")
	password_edit.echoCharacter = string.byte("*")

	-- The render mode is the settings screen's ([BOX_PLAYTEST_2] 3), fixed
	-- for the session before anything loads: the atlas's normal and
	-- surface maps have to be on from the first texture it builds. The
	-- checkbox that was here read its element after the screen was popped
	-- and threw, so the connect never started and the grid was what was
	-- left, with no word why (finding 2).
	-- The password is the field a second try is most likely about, and it is
	-- the one that is not filled in
	if address then
		password_edit:SetFocus(true)
	else
		address_edit:SetFocus(true)
	end

	-- Set below, once the dialog's buttons are there; connect() and cancel()
	-- both have to drop it
	local escape_cb = nil
	local function connect()
		-- Read before the pop below removes the field
		local address = address_edit:GetText()
		local host, port = split_address(address)
		local name = name_edit:GetText()
		if name == "" then
			ui_utils.show_message_dialog("A player name is needed")
			return
		end
		if escape_cb then
			magic.UnsubscribeFromEvent("KeyDown", escape_cb)
			escape_cb = nil
		end
		-- The address and the name kept for next time ([EXT_SETTINGS])
		local kept = settings.load()
		kept.address = address
		kept.name = name
		settings.save(kept)
		local password = password_edit:GetText()
		uistack.main:pop(root)
		local l = listed(address)
		show_client(host, port, name, password, DEFAULT_MODE,
				l and {name = l.name, address = address, game = l.game})
	end

	local function cancel()
		if escape_cb then
			magic.UnsubscribeFromEvent("KeyDown", escape_cb)
			escape_cb = nil
		end
		uistack.main:pop(root)
		-- Launched on its own there is nothing to go back to, so cancelling
		-- is quitting; launched from buildat's menu, that menu is what is
		-- underneath and cancelling belongs to it. See M.launch below.
		if SETTINGS.cancel_exits then
			buildat.quit()
		end
	end

	local function button(label, main)
		local b = window:CreateChild("Button")
		if main then b:SetStyle("PrimaryButton") else b:SetStyleAuto() end
		b:SetName("Button")
		b:SetLayout(LM_VERTICAL, 0, magic.IntRect(0, 0, 0, 0))
		b:SetFixedHeight(28)
		local t = b:CreateChild("Text")
		t:SetName("ButtonText")
		t:SetStyleAuto()
		t.text = label
		t:SetTextAlignment(HA_CENTER)
		return b
	end
	menu:add(button("Join", true), connect)
	ui_utils.close_glyph(root, outer, cancel)

	-- Enter in a field is the field's ([ONE_FOCUS]): on to the next one,
	-- and the password's connects
	magic.SubscribeToEvent(address_edit, "TextFinished", function()
		name_edit:SetFocus(true)
	end)
	magic.SubscribeToEvent(name_edit, "TextFinished", function()
		password_edit:SetFocus(true)
	end)
	magic.SubscribeToEvent(password_edit, "TextFinished", function()
		connect()
	end)

	-- The source row, then the filter beside it
	local source_buttons = {}
	local filter_edit
	local source = "recent"
	pick = function(row, second)
		address_edit:SetText(row.address)
		-- The name last used on that server ([BOX_PLAYTEST_2] 4)
		if row.player_name and row.player_name ~= "" then
			name_edit:SetText(row.player_name)
		end
		if second then
			connect()
		end
	end
	local official_rows = nil
	local status = left:CreateChild("Text")
	status:SetStyleAuto()
	local function matches(row, filter)
		local hay = (row.name .. " " .. (row.line or "") .. " " .. row.address):lower()
		for word in filter:lower():gmatch("%S+") do
			if not hay:find(word, 1, true) then
				return false
			end
		end
		return true
	end
	local function show()
		for name, b in pairs(source_buttons) do
			b.selected = (name == source)
			-- In the main button's amber, as launch_menu's locked row
			b:GetChild("ButtonText").color = magic.Color(ui_utils.rgb(
					name == source and "main" or "text"))
		end
		local rows = {}
		if source == "recent" then
			for _, e in ipairs(network.known_addresses()) do
				local host, port = e.uri:match("^udp://(.-):(%d+)$")
				if host and e.accepted then
					rows[#rows + 1] = {name = host .. ":" .. port,
							address = host .. ":" .. port,
							line = e.description ~= "" and e.description or nil,
							player_name = e.name}
				end
			end
			status.text = #rows == 0 and "No servers used yet" or ""
		else
			rows = official_rows or {}
			status.text = official_rows and (#rows .. " servers") or "Fetching the list..."
		end
		-- From 2 characters (user, 2026-10-07): one matches so much that
		-- the redraw lags at each key
		local filter = filter_edit:GetText()
		if #filter >= 2 then
			local kept = {}
			for _, r in ipairs(rows) do
				if matches(r, filter) then
					kept[#kept + 1] = r
				end
			end
			rows = kept
		end
		list:set_rows(rows)
	end
	-- Luanti's official list, fetched on each open of it: name, address
	-- and port, players of max, the description under; the flags as words
	local function fetch_official()
		official_rows = nil
		show()
		network.http_get("https://servers.luanti.org/list", function(body, err)
			if not body then
				status.text = "The list did not come: " .. tostring(err)
				official_rows = {}
				show()
				return
			end
			local data = network.parse_json(body)
			local rows = {}
			for _, srv in ipairs(data and data.list or {}) do
				-- simplified: a server older than this client can speak to
				-- (Minetest 0.4, protocol 27 at most) is left out, not
				-- shown greyed
				if (tonumber(srv.proto_max) or 99) >= 37 then
					local flags = {}
					if srv.creative then flags[#flags + 1] = "creative" end
					if srv.damage then flags[#flags + 1] = "damage" end
					if srv.pvp then flags[#flags + 1] = "pvp" end
					local addr = tostring(srv.address or "") .. ":" .. tostring(srv.port or 30000)
					official_names[addr] = {name = tostring(srv.name or addr),
						game = tostring(srv.gameid or ""):match("^[%w_]+$")}
					rows[#rows + 1] = {
						name = tostring(srv.name or addr),
						badge = string.format("%s/%s playing",
								tostring(srv.clients or 0), tostring(srv.clients_max or "?")),
						address = addr,
						-- Two lines of it; the whole is the server's own page
						line = addr .. "\n" ..
								tostring(srv.description or ""):sub(1, 150) ..
								(#tostring(srv.description or "") > 150 and "..." or "") ..
								(#flags > 0 and ("  [" .. table.concat(flags, ", ") .. "]") or "") ..
								(srv.version and ("  " .. srv.version) or ""),
					}
				end
			end
			official_rows = rows
			show()
		end, {description = "Luanti's official server list"})
	end
	local function source_button(name, label)
		local b = source_buttons[name]
		b = sources:CreateChild("Button")
		b:SetStyleAuto()
		b:SetName("Button")
		b:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
		b:SetFixedSize(150, 26)
		local t = b:CreateChild("Text")
		t:SetName("ButtonText")
		t:SetStyleAuto()
		t.text = label
		t:SetTextAlignment(HA_CENTER)
		magic.SubscribeToEvent(b, "Released", function()
			source = name
			if name == "official" then
				fetch_official()
			else
				show()
			end
		end)
		source_buttons[name] = b
	end
	source_button("recent", "Servers used")
	source_button("official", "Official list")
	-- The filter is put back as it was left ([BOX_PLAYTEST_2] 13b)
	local filter_label = sources:CreateChild("Text")
	filter_label:SetStyleAuto()
	filter_label.text = "  Filter"
	filter_edit = sources:CreateChild("LineEdit")
	filter_edit:SetStyleAuto()
	filter_edit.textCopyable = true
	filter_edit.textSelectable = true
	filter_edit:SetFixedSize(math.max(100, width - 32 - 2 * 156 - 60), 26)
	filter_edit:SetText(SETTINGS.server_filter or "")
	-- Filtered as it is typed, redrawn only when what it filters by
	-- changed; kept at Enter
	local filtered_by = #filter_edit:GetText() >= 2 and filter_edit:GetText() or ""
	magic.SubscribeToEvent(filter_edit, "TextChanged", function()
		local f = filter_edit:GetText()
		f = #f >= 2 and f or ""
		if f ~= filtered_by then
			filtered_by = f
			show()
		end
	end)
	magic.SubscribeToEvent(filter_edit, "TextFinished", function()
		-- Kept for the next time this screen opens
		local kept = settings.load()
		kept.server_filter = filter_edit:GetText()
		SETTINGS.server_filter = kept.server_filter
		settings.save(kept)
	end)
	show()

	-- Escape cancels. A plain subscription rather than the stack's own,
	-- because a LineEdit with the focus swallows the key and a stack handler
	-- then never fires -- which left this dialog with no way back to the
	-- menu but the mouse.
	escape_cb = magic.SubscribeToEvent("KeyDown",
			function(event_type, event_data)
		if event_data:GetInt("Key") == KEY_ESCAPE then
			cancel()
		end
	end)
end

local function self_tests()
	srp.self_test()
	log:info("srp: self-test ok")
	engine_test.self_test()
	log:info("engine primitives: self-test ok")
	world.self_test()
	log:info("world: self-test ok")
end

-- Launched as the client's whole reason for running: `buildat -m
-- luanti_client`, where cancelling the dialog quits.
function M.boot()
	SETTINGS.cancel_exits = true
	self_tests()
	-- A scripted run has nothing to click, and the dialog's focus is in a
	-- LineEdit that swallows Return. BUILDAT_LUANTI_CONNECT goes straight in
	-- with the address and the name the environment already supplies -- see
	-- DEFAULT_ADDRESS above, which says those two are for scripted runs. The
	-- reference shot harness is what wants it; a person still gets the dialog.
	if (buildat.get_env("BUILDAT_LUANTI_CONNECT") or "") ~= "" then
		local host, port = split_address(DEFAULT_ADDRESS)
		log:info("connecting to " .. host .. ":" .. port ..
				" without the dialog, as BUILDAT_LUANTI_CONNECT asks")
		show_client(host, port, DEFAULT_NAME,
				buildat.get_env("BUILDAT_LUANTI_PASSWORD") or "", DEFAULT_MODE)
		return
	end
	show_connect_dialog()
end

-- What makes this extension one of the things buildat's own menu offers: a
-- name to show, an icon, and what to do when it is picked. The menu keeps
-- the list of extensions it offers; an extension says how to launch itself.
-- See doc/architecture.txt, "The launch grid".
-- Entered from the launch grid ([LAUNCH_GRID]): the tile is
-- launcher/init.lua, sandboxed, and this is the one door it has. The name
-- says what the request is: treat request.params as a packet from a
-- server -- validate, default, ignore the rest. The menu is underneath,
-- so cancelling the dialog goes back to it rather than exiting.
function M.on_untrusted_launch(request)
	local params = type(request) == "table" and
			type(request.params) == "table" and request.params or {}
	if params.menu == "settings" then
		settings.show()
		return
	end
	local address = type(params.address) == "string" and
			#params.address <= 256 and params.address or nil
	local name = type(params.name) == "string" and #params.name <= 64 and
			params.name or nil
	SETTINGS.cancel_exits = false
	self_tests()
	show_connect_dialog(address, name)
end

return M
-- vim: set noet ts=4 sw=4:
