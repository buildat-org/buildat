-- Buildat: extensions/pause_menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 4c: a game's pause menu, Escape's, shared (Workbench's and
-- skeldat's): Continue, Chat..., Settings... and Leave the game, and the
-- app's own items and pages among them in the order it gives;
-- kit.add_menu_items(menu) adds Kit's (builtin/kit). The app's server
-- serves it (meta.json's "client_extensions": ["pause_menu"]), so a client
-- built without it runs the server's copy:
--   local _, err, pause_menu = buildat.run_script_file("pause_menu/init.lua")
--   local menu = pause_menu.new{...}
-- (require("buildat/extension/pause_menu") gives the client's own.)
-- Options, each optional:
--   capture(on)   the app's mouse: on back in play, off while the menu or
--                 a page of it is up (ui_utils.mouse_look(on) without it)
--   hold(close, window, on)  an app's own window rule (skeldat's
--                 game.hold): a window is up, Escape calls close, on.click
--                 (x, y) gets the clicks, on.no_escape keeps the menu on
--                 the web (the browser grants a pointer lock only for a
--                 click); hold(nil) is play again. Without it the menu
--                 keeps that rule itself, capture() follows it and the app
--                 calls menu.escape() for each Escape it does not use
--   on_open(), on_close()  the menu shown; play resumed
--   accounts      the app's builtin/accounts instance, chat.attach()ed to
--                 builtin/chat: Chat... (none without)
--   settings      show_game_settings' sections, or a function giving them
--   on_settings_closed()
-- menu.add(label, action[, {order = n, keep = true, page = true}]):
--   label a string, or a function giving one or nil (not shown then);
--   order: Continue 0, Chat 20, Settings 80, Leave 100, an app's 50 if not
--   given, equal ones as added. The menu closes before action(); keep: it
--   stays up; page: it is taken down but play does not resume -- the app
--   shows its page (menu.hold() for its Escape), whose back calls
--   menu.back() (the menu again, next frame) or menu.close() (play)
-- menu.open(), menu.close(), menu.back(), menu.refresh() (drawn again if
-- up), menu.chat() (the chat over the world, its back to play),
-- menu.shown() (the menu up), menu.held() (the menu or a page of it),
-- menu.escape() (true: taken), menu.on_escape(fn): fn() first for an
-- Escape in play, true taking it (Kit's pending link)
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.safe or ui_utils
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local log = buildat.Logger("pause_menu")
local web = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil

local M = {safe = {}}

-- The app's menu: one at a time, the events below its
local cur = nil
magic.SubscribeToEvent("Update", function()
	if cur and cur.pending then
		local fn = cur.pending
		cur.pending = nil
		fn()
	end
end)
-- A click on nothing: one on another window's button (accounts' Server
-- window over the menu) has made it the focus, and is that window's
magic.SubscribeToEvent("UIMouseClick", function(_, d)
	if cur and cur.held and cur.held_on.click and
			magic.ui.focusElement == nil then
		local rp = magic.ui.root.position
		cur.held_on.click(d:GetInt("X") - rp.x, d:GetInt("Y") - rp.y)
	end
end)

function M.safe.new(o)
	o = o or {}
	local S = {pending = nil, held = nil, held_on = {}}
	cur = S
	local menu = {}
	local items, n = {}, 0
	local root, state = nil, nil -- state: "open", "away" (a page) or nil
	local escapes = {}

	function menu.hold(close, window, on)
		if o.hold then
			return o.hold(close, window, on)
		end
		S.held, S.held_on = close, on or {}
		if o.capture then
			o.capture(close == nil)
		else
			ui_utils.mouse_look(close == nil)
		end
	end

	function menu.add(label, action, opts)
		opts = opts or {}
		n = n + 1
		items[#items + 1] = {label = label, action = action, n = n,
			order = opts.order or 50, keep = opts.keep, page = opts.page}
		menu.refresh()
	end

	function menu.on_escape(fn)
		escapes[#escapes + 1] = fn
	end

	local function take_down()
		if root then
			uistack.main:pop(root)
			root = nil
		end
		-- A clicked button stays the focus, and Space would press it again
		magic.ui:SetFocusElement(nil)
	end

	function menu.close()
		if not state then
			return
		end
		take_down()
		state = nil
		menu.hold(nil)
		if o.on_close then
			o.on_close()
		end
		log:info("pause: the menu closed")
	end

	-- Down for a page: play does not resume
	local function away()
		take_down()
		state = "away"
	end

	function menu.back()
		S.pending = menu.open
	end

	local function run(item)
		if item.keep then
		elseif item.page then
			away()
		else
			menu.close()
		end
		item.action()
	end

	local function draw()
		root = uistack.main:push({desc = "pause"})
		local vm = ui_utils.vertical_menu(root, {min_width = 260})
		local w = vm.window
		w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local list = {}
		for _, it in ipairs(items) do
			local label = it.label
			if type(label) == "function" then
				label = label()
			end
			if label then
				list[#list + 1] = {it = it, label = label}
			end
		end
		table.sort(list, function(a, b)
			if a.it.order ~= b.it.order then
				return a.it.order < b.it.order
			end
			return a.it.n < b.it.n
		end)
		for _, l in ipairs(list) do
			vm:add(l.label, function() run(l.it) end, l.it.order == 0)
		end
		-- A click off the menu is Continue, in the click's own event (the
		-- gesture a browser grants a pointer lock from)
		menu.hold(menu.close, w, {no_escape = true, click = function(x, y)
			local rp, sp = magic.ui.root.position, w.screenPosition
			x, y = x + rp.x - sp.x, y + rp.y - sp.y
			if x < 0 or y < 0 or x >= w.width or y >= w.height then
				log:info("pause: a click off the menu")
				menu.close()
			end
		end})
	end

	function menu.open()
		if state == "open" then
			return
		end
		state = "open"
		draw()
		if o.on_open then
			o.on_open()
		end
		log:info("pause: the menu shown")
	end

	function menu.refresh()
		if state == "open" then
			take_down()
			draw()
		end
	end

	function menu.shown()
		return state == "open"
	end
	function menu.held()
		return state ~= nil
	end

	-- The chat: from the menu its back is the menu, from the world play
	local function chat(from_menu)
		if from_menu then
			away()
		end
		local function back()
			o.accounts.close_page()
			magic.ui:SetFocusElement(nil)
			log:info("pause: the chat closed")
			if from_menu then
				menu.back()
			else
				menu.hold(nil)
			end
		end
		menu.hold(back)
		o.accounts.chat_page(back)
		log:info("pause: the chat shown")
	end
	function menu.chat()
		if o.accounts and not state then
			chat(false)
		end
	end

	function menu.escape()
		if S.held then
			if web and S.held_on.no_escape then
				log:info("pause: Escape kept on the web: click Continue or " ..
						"off the menu")
			else
				S.held()
			end
			return true
		end
		for _, fn in ipairs(escapes) do
			if fn() then
				return true
			end
		end
		menu.open()
		return true
	end

	menu.add("Continue", function() end, {order = 0})
	if o.accounts then
		menu.add("Chat...", function() chat(true) end, {order = 20, keep = true})
	end
	menu.add("Settings...", function()
		menu.hold(function() end)
		log:info("pause: settings shown")
		local s = o.settings
		if type(s) == "function" then
			s = s()
		end
		buildat.show_game_settings{sections = s, on_close = function()
			if o.on_settings_closed then
				o.on_settings_closed()
			end
			menu.back()
		end}
	end, {order = 80, page = true})
	menu.add("Leave the game", function()
		log:info("pause: leave")
		buildat.leave()
	end, {order = 100})
	return menu
end
M.new = M.safe.new

return M
-- vim: set noet ts=4 sw=4:
