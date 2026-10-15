-- Buildat: apps/demo_skeldat/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pause menu, Escape's: Continue, Settings and Leave (skelenti's); and
-- the death screen, up while the hit points are none, whose Respawn asks
-- the server for one.
--   local open = run_script_file("main/pause.lua")(game, declare_keys)
-- declare_keys: read the keys again after the settings window.
-- simplified: no account pages for the admin yet (stage 6 of [SKELDAT])
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local log = buildat.Logger("skeldat")

return function(game, declare_keys)
	local root = nil
	local dead = false
	-- What runs next frame: the menu again after the settings window,
	-- which would otherwise reopen in the Escape that closed the window
	local pending = nil
	magic.SubscribeToEvent("Update", function()
		if pending then
			local fn = pending
			pending = nil
			fn()
		end
	end)

	local function close()
		if not root then
			return
		end
		uistack.main:pop(root)
		root = nil
		game.hold(nil)
		-- A clicked button stays the focus, and Space would press it again
		magic.ui:SetFocusElement(nil)
		log:info("pause: the menu closed")
	end

	local open

	-- The client's settings window ([GAME_SETTINGS]): sound, video, the
	-- game's keys and the client's. The world stays held while it is up;
	-- its own Escape and Close shut it
	local function settings()
		uistack.main:pop(root)
		root = nil
		magic.ui:SetFocusElement(nil)
		game.hold(function() end)
		log:info("pause: settings shown")
		buildat.show_game_settings{on_close = function()
			declare_keys()
			pending = open
		end}
	end

	function open()
		if root then
			return
		end
		root = uistack.main:push({desc = "pause"})
		local menu = ui_utils.vertical_menu(root, {min_width = 260})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		menu:add("Continue", close, true)
		menu:add("Settings...", settings)
		menu:add("Leave the game", function() buildat.leave() end)
		game.hold(close, menu.window)
		log:info("pause: the menu shown")
	end

	local function show_death()
		close()
		root = uistack.main:push({desc = "death"})
		local menu = ui_utils.vertical_menu(root, {min_width = 260})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText("You died.")
		menu:add("Respawn", function()
			game.send("respawn", "")
		end, true)
		menu:add("Leave the game", function() buildat.leave() end)
		-- Escape does not close it
		game.hold(function() end, menu.window, true)
		log:info("pause: the death screen shown")
	end

	table.insert(game.listeners, function()
		local now = game.stats.hp <= 0
		if now == dead then
			return
		end
		dead = now
		if dead then
			show_death()
		else
			close()
		end
	end)

	return open
end
-- vim: set noet ts=4 sw=4:
