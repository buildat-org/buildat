-- Buildat: apps/demo_skelenti/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pause menu, Escape's: Continue, Settings and Leave. Without one the
-- module's loop only lets go of the mouse, and nothing takes it back.
--   local open = run_script_file("main/pause.lua")
-- returns the client loop's pause hook (luanti.run_client's app.pause).
-- simplified: no account pages (skeldat's pause menu has them)
local magic = require("buildat/extension/urho3d")
local luanti = require("buildat/module/luanti")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local log = buildat.Logger("skelenti")

local root = nil
-- What runs next frame: the menu again after the settings window, which
-- would otherwise reopen in the Escape that closed the window
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
	luanti.hold(nil)
	-- A clicked button stays the focus, and Space would press it again
	magic.ui:SetFocusElement(nil)
	-- What a check waits for
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
	luanti.hold(function() end)
	log:info("pause: settings shown")
	buildat.show_game_settings{on_close = function() pending = open end}
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
	-- Escape is the hold's: the loop calls close for it
	luanti.hold(close, menu.window)
	log:info("pause: the menu shown")
end

return function()
	return open
end
-- vim: set noet ts=4 sw=4:
