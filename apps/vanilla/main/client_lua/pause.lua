-- Buildat: apps/vanilla/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pause menu, a window of the client's own ([VANILLA_PUBLIC] 2): the
-- game is told nothing about it. Escape used to disconnect, which is a key
-- nobody was told about doing the one thing that cannot be undone.
--
-- On a public server it has the account pages, builtin/accounts' as the
-- floorplanner has them, and an admin's world menu, which is main/menu.lua
-- over the world. While any of it is up, luanti.hold() makes the world
-- keep its hands off the keys and the mouse, as a form does.
--
--   local open = run_script_file("main/pause.lua")(o)
-- o.keys: keys.lua's table, whose editor is the key bindings page.
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local luanti = require("buildat/module/luanti")
local ui_utils = require("buildat/extension/ui_utils")
local log = buildat.Logger("vanilla")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack

local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("vanilla: could not load accounts.lua: " .. tostring(err))
end
-- This instance has every accounts packet from here on: the join was
-- main/join.lua's, before the world
accounts.logged_in = true
-- The join's hello went to join.lua's copy; this one's My account reads it
buildat.send_packet("accounts:get_hello", "")
-- The chat console ([CHAT_CONSOLE]): Luanti's chat, what came before this
-- script and all that comes after
for _, line in ipairs(luanti.chat_lines or {}) do
	accounts.chat_add(line)
end
luanti.sub_chat(function(line)
	accounts.chat_add(line)
end)
accounts.chat_send = function(text)
	buildat.send_packet("main:chat",
			cereal.binary_output({text}, {"array", "string"}))
end

-- What the server said in main:account
local account = {public = false, admin = false, world = "", is_local = false}
local window = nil
local o = nil
local open

buildat.sub_packet("main:account", function(data)
	local v = cereal.binary_input(data, {"array", "string"})
	account = {public = v[1] == "1", admin = v[2] == "1", world = v[3] or "",
			is_local = v[4] == "1"}
	-- The world's game, for the client's Discuss in its overlay
	-- ([OVERLAY_DISCUSS]); a client from before it has no such verb
	if buildat.set_running_game and (v[5] or "") ~= "" then
		buildat.set_running_game({game = v[5]})
	end
	o.keys.public = account.public
	-- A menu up before this came (the web starts paused) is missing what
	-- the account adds to it
	if window then
		open()
	end
end)

local function close()
	if window then
		window:Remove()
		window = nil
	end
	accounts.close_page()
	luanti.hold(nil)
	-- A control clicked here stays the UI's focus element after its window
	-- is gone, and then Space and Enter work it from the world -- a jump
	-- cycled the volume and the view range ([PAUSE_VOLUME_KEYS])
	magic.ui:SetFocusElement(nil)
end

-- Held while a screen that takes Escape as its own Back is up (the key
-- editor, the world menu): the hold swallows the key
local function swallow()
	luanti.hold(swallow)
end

-- What such a screen's Back does, a frame later: the Escape that pressed
-- it is still going round, and the world's key handler would take it for
-- the pause menu's
local pending = nil
local function later(fn)
	pending = fn
end
-- **The address bar away while playing** ([WEB_ADDRESS_BAR]): on the web,
-- fullscreen asked for whenever nothing of this menu holds the world, and
-- the bar back while it does; the page does it only where the
-- preference says hide (by default on a phone), and entering waits for
-- a tap
local WEB = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
local fullscreen = nil
magic.SubscribeToEvent("Update", function()
	if pending then
		local fn = pending
		pending = nil
		fn()
	end
	local want = not luanti.held()
	if WEB and want ~= fullscreen then
		fullscreen = want
		buildat.set_web_fullscreen(want)
	end
end)

-- The pause window makes way for a page; Escape on an account page is its
-- Back, to the pause menu
local function page(show, escape)
	if window then
		window:Remove()
		window = nil
	end
	luanti.hold(escape or swallow)
	show()
end

-- The admin's world menu over the world: the world list, a new world and
-- ContentDB, as at the boot
local function worlds()
	page(function()
		local _, err2, menu = buildat.run_script_file("main/menu.lua")
		if type(menu) ~= "table" then
			luanti.hold(nil)
			error("vanilla: could not load menu.lua: " .. tostring(err2))
		end
		menu.back = function()
			later(function() luanti.hold(nil) end)
		end
	end)
end

open = function()
	close()
	local w = accounts.page_window(360)
	window = w
	-- **On the web Escape does not close it** (user, 2026-09-30): the
	-- world takes the mouse back as it closes, and a browser grants no
	-- pointer lock for an Escape -- Firefox took it and let it go, and
	-- the view spun with a mouse the game thought was its own. A click
	-- is what a lock can be asked for from: Continue, or anywhere off
	-- the menu.
	luanti.hold(close, w, buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil)
	accounts.page_text(w, "Paused")
	if account.world ~= "" then
		accounts.page_text(w, "World: " .. account.world)
	end
	-- Continuing is the first thing on it and the first thing a player
	-- wants: escape (natively) and a click off the menu do the same, but a
	-- menu whose only way back is a key nobody was told about is a menu
	-- that traps people
	accounts.page_button(w, "Continue playing", close, true)
	accounts.page_button(w, "Chat...", function()
		page(function() accounts.chat_page(open) end, open)
	end)
	-- The engine's settings, the keys and the logs: the client's window
	-- ([GAME_SETTINGS]), over the world; the keys read again after it.
	-- The keys are reached by it alone ([SETTINGS_KEYS_PAGE])
	if buildat.show_game_settings then
		accounts.page_button(w, "Settings...", function()
			page(function()
				buildat.show_game_settings{sections = o.keys.settings_sections,
						on_close = function()
					o.keys.declare()
					later(open)
				end}
			end)
		end)
	end
	-- **The viewing range, the player's own** (user, 2026-09-30), kept on
	-- this client for this server, never over what the server allows
	-- (keys.view in init.lua). A web client starts lower, and a fast one
	-- can go up.
	local view = o.keys.view
	if view then
		local steps = {}
		for _, n in ipairs({40, 60, 80, 120, 160, 240, 360, 500, 800}) do
			if n < view.ceiling then
				steps[#steps + 1] = tostring(n)
			end
		end
		steps[#steps + 1] = tostring(view.ceiling)
		ui_utils.dropdown(w, steps, tostring(view.current()), function(v)
			view.choose(tonumber(v))
		end, {label = "View range" ..
				((buildat.storage_read("view_range") or "") == "" and
				" (default)" or ""), fill = true, none = tostring(view.current())})
	end
	-- **The screen's orientation** on a touchscreen's web page
	-- ([SCREEN_ORIENTATION]): the pick's tap is the gesture the page's
	-- fullscreen entry, and so the lock, needs
	local turn = buildat.get_screen_orientation and
			buildat.get_screen_orientation()
	if o.keys.touch and turn then
		local names = {Auto = "auto", Landscape = "landscape",
				Portrait = "portrait"}
		local shown = {auto = "Auto", landscape = "Landscape",
				portrait = "Portrait"}
		ui_utils.dropdown(w, {"Auto", "Landscape", "Portrait"}, shown[turn],
				function(v)
			local ok, err = buildat.set_screen_orientation(names[v])
			log:info("pause: screen orientation " .. names[v] ..
					(ok and "" or ": " .. tostring(err)))
		end, {label = "Screen orientation", fill = true})
	end
	if account.public then
		-- My account... local or not ([ACCOUNT_BUTTON]); the way to
		-- Accounts... is through it now (account_page's own button)
		accounts.page_button(w, "My account...", function()
			page(function() accounts.account_page(open) end, open)
		end)
		if not account.is_local then
			-- To the Starports that list it ([STARPORT] 5); the dialog is
			-- the client's own
			accounts.page_button(w, "Report this server...", function()
				require("buildat/extension/starport").open_report_here()
			end)
		end
		if account.admin then
			accounts.page_button(w, "Worlds...", worlds)
		end
	end
	-- [DISCUSS_SERVER]: a server a Starport lists, its thread on a Hearth.
	-- The client decides where it goes and what it says, and whether there
	-- is somewhere (a client from before it has neither verb)
	if buildat.can_discuss_this_server and buildat.can_discuss_this_server() then
		accounts.page_button(w, "Discuss (leave server)", function()
			close()
			buildat.discuss_this_server()
		end)
	end
	if not account.public and account.is_local then
		accounts.lan_row(w)
	end
	-- A browser tab has no launcher to leave to, and is closed as a tab
	-- (only the web page sets BUILDAT_PAGE_HTTPS)
	if buildat.get_env("BUILDAT_PAGE_HTTPS") == nil then
		accounts.page_button(w, "Leave the game", function() buildat.leave() end)
	elseif account.public and not account.is_local then
		-- The tab's way out, which also ends a kept login ([ACC_KEEP])
		accounts.page_button(w, "Log out", accounts.logout)
	end
end

-- A click or a tap off the menu is Continue, and off an account page it
-- made way for (the chat, My account) that page's Back, as its Escape
-- ([PAGE_TAP_OUTSIDE]); a press off a dropdown's popup closes only that.
-- The key editor, the world menu and the settings are uistack screens,
-- whose tap on nothing is Back already ([TAP_BACK]). The UI's press, one
-- for a finger or a mouse (a finger's made-up mouse is not one); acted on
-- at the release, so that the world does not take the mouse with a button
-- held down and start digging with it.
local pressed_off = false
local function off_menu(x, y)
	local w = window or (luanti.held() and accounts.page)
	-- The Server window, whose sidebar is off its page, has its own test
	-- ([SERVER_WINDOW_CLICK])
	if not w or ui_utils.dropdown_open() or (not window and accounts.frame) then
		return false
	end
	local p, s = w.screenPosition, w.size
	return x < p.x or y < p.y or x >= p.x + s.x or y >= p.y + s.y
end
magic.SubscribeToEvent("UIMouseClick", function(_, d)
	pressed_off = off_menu(d:GetInt("X"), d:GetInt("Y"))
end)
-- A finger on the web lifts as a touch and as its mouse: the first one
local function released()
	if pressed_off then
		pressed_off = false
		log:info("pause: a press off the " .. (window and "menu" or "page"))
		if window then
			close()
		else
			uistack.press_back()
		end
	end
end
magic.SubscribeToEvent("MouseButtonUp", released)
magic.SubscribeToEvent("TouchEnd", released)

return function(options)
	o = options
	-- The chat console straight from the world, for the touch controls'
	-- Chat; its Back goes back to the world
	o.keys.open_chat = function()
		close()
		page(function() accounts.chat_page(close) end, close)
	end
	return open
end
-- vim: set noet ts=4 sw=4:
