-- Buildat: apps/demo_skeldat/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pause menu, Escape's: Continue, Chat, Settings and Leave; and the
-- death screen, up while the hit points are none, whose Respawn asks the
-- server for one. The chat is builtin/chat's, its console builtin/accounts'
-- (game.chat(), the chat key's) and its menu (mute, report) the chat's.
-- An admin has Admin...: the players, each one's inventory to give an
-- item to or take a stack from, and the audit log of both.
--   local open = run_script_file("main/pause.lua")(game, declare_keys)
-- declare_keys: read the keys again after the settings window.
-- simplified: no account pages for the admin; the admin's give is one or
-- a stack of an item from a list, its take a whole stack
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local log = buildat.Logger("skeldat")
local chat = require("buildat/module/chat")

local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("skeldat: could not load accounts.lua: " .. tostring(err))
end
-- The join was the boot's; this instance has the packets from here on
accounts.logged_in = true
chat.attach(accounts)

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

	-- The chat console over the world; Escape and its Back come back here
	-- when it was opened from the menu, to the world when by the key
	local function console(from_menu)
		if root then
			uistack.main:pop(root)
			root = nil
		end
		local function back()
			accounts.close_page()
			game.hold(nil)
			magic.ui:SetFocusElement(nil)
			log:info("pause: the chat closed")
			if from_menu then
				pending = open
			end
		end
		game.hold(back)
		accounts.chat_page(back)
		log:info("pause: the chat shown")
	end
	function game.chat()
		console(false)
	end

	-- The admin's menu: the server's answers redraw the page they are for
	local admin = {page = nil, players = {}, name = nil, main = {},
		audit = {}, give = nil}
	local function admin_send(cmd)
		game.send("admin", cmd)
	end
	local function admin_page()
		if root then
			uistack.main:pop(root)
		end
		root = uistack.main:push({desc = "admin"})
		local menu = ui_utils.vertical_menu(root, {min_width = 360})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local function text(str)
			local t = menu.window:CreateChild("Text")
			t:SetStyleAuto()
			t:SetText(str)
		end
		local back
		if admin.page == "inv" then
			text(admin.name .. "'s inventory")
			for i, str in ipairs(admin.main) do
				local st = game.parse_stack(str)
				if st then
					local item = game.items[st.name]
					menu:add(string.format("Take %s x%d",
							item and item.desc or st.name, st.count), function()
						admin_send(string.format("take %s %d", admin.name, i - 1))
					end)
				end
			end
			local names = {}
			for name in pairs(game.items) do
				names[#names + 1] = name
			end
			table.sort(names)
			local choices = {}
			for i, name in ipairs(names) do
				choices[i] = {game.items[name].desc or name, name}
			end
			admin.give = admin.give or names[1]
			menu:add_dropdown("Item", choices, admin.give, function(v)
				admin.give = v
			end)
			menu:add("Give one", function()
				admin_send(string.format("give %s %s 1", admin.name, admin.give))
			end)
			menu:add("Give a stack", function()
				admin_send(string.format("give %s %s 99", admin.name,
						admin.give))
			end)
			back = function()
				admin.page = "players"
				admin_send("players")
			end
		elseif admin.page == "map" then
			text("The world from above, +x right and +z up; the whiter, the" ..
					" more bones")
			text(admin.map or "Writing...")
			back = function()
				admin.page = "players"
				admin_send("players")
			end
		elseif admin.page == "audit" then
			text("The audit log, the newest first")
			text(#admin.audit == 0 and "Nothing yet." or
					table.concat(admin.audit, "\n"))
			back = function()
				admin.page = "players"
				admin_send("players")
			end
		else
			text("Players")
			for _, name in ipairs(admin.players) do
				menu:add(name, function()
					admin.page, admin.name = "inv", name
					admin_send("view " .. name)
				end)
			end
			menu:add("The world's map", function()
				admin.page, admin.map = "map", nil
				admin_send("map")
			end)
			menu:add("The audit log", function()
				admin.page = "audit"
				admin_send("audit")
			end)
			back = function()
				admin.page = nil
				uistack.main:pop(root)
				root = nil
				game.hold(nil)
				pending = open
			end
		end
		menu:add("Back", back, true)
		game.hold(back, menu.window)
		log:info("pause: admin " .. (admin.page or "players") .. " shown")
	end
	buildat.sub_packet("skeldat:admin", function(data)
		local head, rest = data:match("^([^\n]*)\n?(.*)$")
		local lines = {}
		for l in rest:gmatch("[^\n]+") do
			lines[#lines + 1] = l
		end
		if head == "players" then
			admin.players = lines
		elseif head == "audit" then
			admin.audit = lines
		elseif head == "map" then
			admin.map = lines[1]
		elseif head:match("^inv ") then
			admin.main = {}
			local list = (lines[1] or ""):match("^main=(.*)$") or ""
			for part in (list .. "|"):gmatch("([^|]*)|") do
				admin.main[#admin.main + 1] = part
			end
		end
		log:info("pause: admin got " .. head)
		if admin.page and root then
			admin_page()
		end
	end)
	local function open_admin()
		admin.page = "players"
		admin_send("players")
		admin_page()
	end

	local function chat_menu()
		uistack.main:pop(root)
		root = nil
		chat.open(function(close_chat, window)
			if close_chat then
				game.hold(close_chat, window)
			else
				game.hold(nil)
				pending = open
			end
		end)
	end

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
		menu:add("Chat...", function() console(true) end)
		menu:add("Who's in the chat...", chat_menu)
		if game.admin then
			menu:add("Admin...", open_admin)
		end
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
