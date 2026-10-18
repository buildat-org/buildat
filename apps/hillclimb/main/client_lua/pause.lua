-- Buildat: apps/hillclimb/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- hillclimb's pause menu ([HC_PAUSE_MENU]), Escape's, as skeldat's
-- pause.lua (its own copy: apps do not consume each other): Continue, The
-- hill... (the Tab menu), Chat..., Settings... and Leave the game. The
-- game goes on under it -- a shared server's clock and the other cars --
-- and init.lua sends no driving input while it is up (pause.held()).
--   local pause = run_script_file("main/pause.lua")(h)
-- h.hill_menu(): the Tab menu opened; h.chat(back): the chat page, back()
-- once it closes; h.keys(): the keys read again after the settings window
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local log = buildat.Logger("hillclimb")

return function(h)
	local M = {}
	local root = nil
	-- Settings or the chat opened from the menu, which comes back after
	local away = false
	-- The menu again next frame: the Escape that closed the settings
	-- window would otherwise close it again
	local pending = nil
	-- Frames counted, and the one it opened in: init.lua's Escape that
	-- frame is the one that closed the window it came back from
	local frame, opened = 0, -1
	magic.SubscribeToEvent("Update", function()
		frame = frame + 1
		if pending then
			local fn = pending
			pending = nil
			fn()
		end
	end)

	-- Up, or away in a window it comes back from: no driving, no keys
	function M.held()
		return root ~= nil or away
	end
	function M.shown()
		return root ~= nil
	end
	-- Whether this frame's Escape is the menu's to close it with
	function M.escape_closes()
		return root ~= nil and opened ~= frame
	end
	function M.close()
		if not root then
			return
		end
		uistack.main:pop(root)
		root = nil
		-- A clicked button stays the focus, and Space would press it again
		magic.ui:SetFocusElement(nil)
		log:info("pause: the menu closed")
	end
	local function back()
		away = false
		pending = M.open
	end
	function M.open()
		if root then
			return
		end
		root = uistack.main:push({desc = "pause"})
		opened = frame
		local menu = ui_utils.vertical_menu(root, {min_width = 260})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		menu:add("Continue", M.close, true)
		menu:add("The hill...", function()
			M.close()
			h.hill_menu()
		end)
		menu:add("Chat...", function()
			M.close()
			away = true
			h.chat(back)
		end)
		menu:add("Settings...", function()
			M.close()
			away = true
			log:info("pause: settings shown")
			buildat.show_game_settings{on_close = function()
				h.keys()
				log:info("pause: settings closed")
				back()
			end}
		end)
		menu:add("Leave the game", function()
			log:info("pause: leave")
			buildat.leave()
		end)
		log:info("pause: the menu shown")
	end
	return M
end
-- vim: set noet ts=4 sw=4:
