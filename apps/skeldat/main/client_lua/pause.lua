-- Buildat: apps/skeldat/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pause menu, Escape's: Continue, Chat, Settings and Leave; and the
-- death screen, up while the hit points are none, whose Respawn asks the
-- server for one. The chat is builtin/chat's, its console builtin/accounts'
-- (game.chat(), the chat key's) and its menu (mute, report) the chat's.
-- An admin has Admin...: the players, each one's inventory to give an
-- item to or take a stack from, invulnerability on and off, and the audit
-- log of them.
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

	local open
	-- [SKELDAT_DEATH_PAUSE] The death screen, {root, window}, under the
	-- menu and its pages in a root of its own; while it is up the hold
	-- goes back to it, its Escape the menu over it
	local death = nil
	local function unhold()
		if death then
			game.hold(function() open() end, death.window, true)
		else
			game.hold(nil)
		end
	end

	local function close()
		if not root then
			return
		end
		-- [SKELDAT_WORLD_ADMIN] A single player's pause ends with the
		-- menu (the server says whether it is one)
		game.send("pause", "auto off")
		uistack.main:pop(root)
		root = nil
		unhold()
		-- A clicked button stays the focus, and Space would press it again
		magic.ui:SetFocusElement(nil)
		log:info("pause: the menu closed")
		if death then
			log:info("pause: back to the death screen")
		end
	end

	-- The chat console over the world; Escape and its Back come back here
	-- when it was opened from the menu, to the world when by the key
	local function console(from_menu)
		if root then
			uistack.main:pop(root)
			root = nil
		end
		local function back()
			accounts.close_page()
			unhold()
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
		audit = {}, give = nil, start = {}}
	local function admin_send(cmd)
		game.send("admin", cmd)
	end
	-- Every item as a dropdown's choices, by name
	local function admin_item_choices()
		local names = {}
		for name in pairs(game.items) do
			names[#names + 1] = name
		end
		table.sort(names)
		local choices = {}
		for i, name in ipairs(names) do
			choices[i] = {game.items[name].desc or name, name}
		end
		return choices
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
			local choices = admin_item_choices()
			admin.give = admin.give or choices[1][2]
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
			-- No damage of any kind ([SKELDAT_INVULNERABLE])
			menu:add("Invulnerable: " .. (admin.invulnerable and "on" or "off"),
					function()
				admin_send(string.format("invulnerable %s %s", admin.name,
						admin.invulnerable and "off" or "on"))
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
		elseif admin.page == "start" then
			-- [SKELDAT_START_ITEMS] What a new player is given, changed
			-- here as a whole list
			local function set(list)
				local parts = {"set_start_items"}
				for _, st in ipairs(list) do
					parts[#parts + 1] = st[1] .. " " .. st[2]
				end
				admin_send(table.concat(parts, " "))
			end
			text("What a new player starts with")
			if admin.start_refused then
				text("Not an item: " .. admin.start_refused)
			end
			if #admin.start == 0 then
				text("Nothing.")
			end
			for i, st in ipairs(admin.start) do
				local item = game.items[st[1]]
				menu:add(string.format("Remove %s x%d", item and item.desc or
						st[1], st[2]), function()
					local list = {}
					for j, other in ipairs(admin.start) do
						if j ~= i then
							list[#list + 1] = other
						end
					end
					set(list)
				end)
			end
			local choices = admin_item_choices()
			admin.give = admin.give or choices[1][2]
			menu:add_dropdown("Item", choices, admin.give, function(v)
				admin.give = v
			end)
			menu:add("Add one", function()
				local list, found = {}, false
				for _, st in ipairs(admin.start) do
					local n = st[2]
					if st[1] == admin.give then
						n, found = n + 1, true
					end
					list[#list + 1] = {st[1], n}
				end
				if not found then
					list[#list + 1] = {admin.give, 1}
				end
				set(list)
			end)
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
			-- [SKELDAT_BONE_SPEED] The world's, switched here
			menu:add_dropdown("Bone speed", {{"1x", "1"}, {"2x", "2"},
					{"5x", "5"}, {"10x", "10"}}, admin.speed or "1", function(v)
				if v ~= admin.speed then
					admin_send("speed " .. v)
				end
			end)
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
			menu:add("New players' items", function()
				admin.page, admin.start_refused = "start", nil
				admin_send("start_items")
			end)
			back = function()
				admin.page = nil
				uistack.main:pop(root)
				root = nil
				unhold()
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
		if head:match("^players") then
			admin.players = lines
			admin.speed = head:match("^players (%d+)") or admin.speed
		elseif head == "audit" then
			admin.audit = lines
		elseif head:match("^start_items") then
			admin.start = {}
			for _, l in ipairs(lines) do
				local n, c = l:match("^(%S+) (%d+)$")
				if n then
					admin.start[#admin.start + 1] = {n, tonumber(c)}
				end
			end
			admin.start_refused = head:match("refused (%S+)")
		elseif head == "map" then
			admin.map = lines[1]
		elseif head:match("^inv ") then
			admin.main = {}
			local list = (lines[1] or ""):match("^main=(.*)$") or ""
			for part in (list .. "|"):gmatch("([^|]*)|") do
				admin.main[#admin.main + 1] = part
			end
			admin.invulnerable = lines[2] == "invulnerable=1"
		end
		local start = {}
		for _, st in ipairs(head:match("^start_items") and admin.start or {}) do
			start[#start + 1] = st[1] .. " " .. st[2]
		end
		log:info("pause: admin got " .. head ..
				(admin.invulnerable and head:match("^inv ") and
				", invulnerable" or "") .. (head:match("^start_items") and
				": " .. table.concat(start, ", ") or ""))
		if admin.page and root then
			admin_page()
		end
	end)
	-- For a check: "event skeldat_admin <command>" sends it as the menu
	-- would, one the menu cannot (an unknown item's name)
	magic.SubscribeToEvent("command_seq:skeldat_admin", function(_, d)
		admin_send(d:GetString("Param"))
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
				unhold()
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
		-- [SKELDAT_TOUCH] and the touch controls' own (init.lua's)
		buildat.show_game_settings{sections = game.settings_sections,
				on_close = function()
			declare_keys()
			pending = open
		end}
	end

	-- [SKELDAT_INTRO] The premise and the ways to fight back: the
	-- server's skeldat:intro (a new player's first entry, or How to
	-- play...), its days left in it
	local INTRO = {
		"Your score is how many days you hold out.",
		"Lanterns (iron and bones, filled with coal) stop the bones growing "
				.. "around them and slowly push them back. Skeletons will try "
				.. "to steal them.",
		"Skeletons burn in daylight away from the bones, and die in water. "
				.. "Killed, they drop bones and arrows.",
		"Marker skulls: a skeleton that sees you leaves a red skull. At dawn "
				.. "and dusk skeletons gather where the skulls are. Dig one and "
				.. "place it to lure them where you want.",
		"The bow (three sticks and three bones; arrows: a bone over a "
				.. "stick): hold the left button to draw, release to shoot.",
		"Walking fast down a step you ride a skateboard: it turns where "
				.. "you look; with forward held, left and right steer "
				.. "(Camera steer, in the settings). Back brakes, jump "
				.. "jumps (once more in the air), sneak lies flat.",
	}
	local function show_intro(days)
		close()
		root = uistack.main:push({desc = "intro"})
		-- [SKELDAT_TOUCH_HOW_TO_PLAY] As wide as a wide screen has room
		-- for, so as short: at the touch UI size one column of 440 was
		-- taller than a 1200x800 window
		local width = math.max(440, math.min(760, magic.ui.root.width - 60))
		local menu = ui_utils.vertical_menu(root, {min_width = width + 20})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local function line(text)
			local t = menu.window:CreateChild("Text")
			t:SetStyleAuto()
			t:SetFixedWidth(width)
			t:SetWordwrap(true)
			t:SetText(text)
		end
		line("In about " .. days .. " game days the world will be consumed "
				.. "by bones.")
		for _, text in ipairs(INTRO) do
			line(text)
		end
		menu:add("Close", close, true)
		game.hold(close, menu.window)
		log:info("pause: how to play shown, " .. days .. " days")
	end
	buildat.sub_packet("skeldat:intro", function(data)
		show_intro(data)
	end)

	-- [SKELDAT_HIGH_SCORES] The sets of parameters, best first, and a
	-- set's scores: the server's skeldat:scores, asked by "list" and
	-- "set <key>"
	local function scores_page(title, rows, back)
		close()
		root = uistack.main:push({desc = "scores"})
		local menu = ui_utils.vertical_menu(root, {min_width = 460})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(title)
		for _, r in ipairs(rows) do
			if r[2] then
				menu:add(r[1], r[2])
			else
				local l = menu.window:CreateChild("Text")
				l:SetStyleAuto()
				l:SetFixedWidth(440)
				l:SetWordwrap(true)
				l:SetText(r[1])
			end
		end
		menu:add("Back", back, true)
		game.hold(back, menu.window)
	end
	local function hours(s)
		return string.format("%.1f h", (tonumber(s) or 0) / 3600)
	end
	buildat.sub_packet("skeldat:scores", function(data)
		local j = buildat.parse_json(data) or {}
		if j.sets then
			local rows = {}
			for _, set in ipairs(j.sets) do
				rows[#rows + 1] = {string.format("%s: %d, %dx, seed %s: "
						.. "%.1f days", set.name or "?", set.size or 0,
						set.speed or 1, tostring(set.seed), set.best or 0),
						function() game.send("scores", "set " .. set.key) end}
			end
			if #rows == 0 then
				rows[1] = {"No world has ended yet."}
			end
			scores_page("High scores", rows, function()
				close()
				pending = open
			end)
			log:info("pause: high scores shown, " .. #j.sets .. " sets")
		elseif j.set then
			local set, rows = j.set, {}
			for i, sc in ipairs(set.scores or {}) do
				local who = {}
				for _, p in ipairs(sc.players or {}) do
					who[#who + 1] = tostring(p[1]) .. " " .. hours(p[2])
				end
				rows[#rows + 1] = {string.format("%d. %.1f days, %s, %s: %s", i,
						sc.days or 0, tostring(sc.date), tostring(sc.world),
						table.concat(who, ", "))}
			end
			scores_page(string.format("%s: %d, %dx, seed %s", set.name or "?",
					set.size or 0, set.speed or 1, tostring(set.seed)), rows,
					function() game.send("scores", "list") end)
			log:info("pause: scores of " .. tostring(set.key) .. " shown, " ..
					#rows .. " scores")
		end
	end)

	function open()
		if root then
			return
		end
		root = uistack.main:push({desc = "pause"})
		local menu = ui_utils.vertical_menu(root, {min_width = 260})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		menu:add("Continue", close, true)
		-- [SKELDAT_RERUN] The ended world again, as <name>_rerun
		if game.ended then
			menu:add("Play again", function()
				log:info("pause: play again")
				game.send("rerun", "")
				close()
			end)
		end
		menu:add("Chat...", function() console(true) end)
		menu:add("Who's in the chat...", chat_menu)
		-- [SKELDAT_PAUSE_ACCOUNT] accounts' own page, Log out on it; its
		-- Back to this menu
		local me = accounts.who()
		menu:add("My account" .. (me and me ~= "" and " (" .. me .. ")" or "")
				.. "...", function()
			uistack.main:pop(root)
			root = nil
			game.hold(function() end)
			log:info("pause: my account shown")
			accounts.account_page(function()
				unhold()
				pending = open
			end)
		end)
		if game.admin then
			menu:add("Admin...", open_admin)
		end
		-- [SKELDAT_WORLD_ADMIN] The picker's: the world menu over the
		-- running world (world_menu's client, its close back to the game),
		-- and the pause
		if game.picker then
			menu:add("Worlds...", function()
				close()
				local world_menu = require("buildat/module/world_menu")
				world_menu.on_close = function()
					world_menu.on_close = nil
					unhold()
					log:info("pause: the worlds closed")
				end
				game.hold(function() end)
				game.send("worlds", "")
				log:info("pause: worlds asked")
			end)
			-- The picker's own pause, not this menu's
			local held = game.paused and not game.paused_auto and
					not game.skipping
			menu:add(held and "Resume world" or "Pause world", function()
				game.send("pause", held and "off" or "on")
				close()
			end)
			-- [SKELDAT_SKIP_TIME] To the next sunset by day, sunrise by
			-- night, or Stop; [SKELDAT_SKIP_DAWN] the night's to 05:00
			-- (0.25 - 1/24), and the day's from there
			if game.skipping then
				menu:add("Stop skipping", function()
					game.send("skip", "stop")
					close()
				end)
			elseif not game.ended and not held then
				local d = game.day or 0.5
				local day = d >= 0.25 - 1 / 24 and d < 0.75
				menu:add(day and "Skip to sunset" or "Skip to sunrise", function()
					game.send("skip", "on")
					close()
				end)
			end
		end
		menu:add("Settings...", settings)
		menu:add("How to play...", function() game.send("intro", "") end)
		menu:add("High scores...", function() game.send("scores", "list") end)
		menu:add("Leave the game", function() buildat.leave() end)
		-- [SKELDAT_PAUSE_CLOSE] A click off the menu is Continue, in the
		-- click's own event (the gesture a browser grants a pointer lock
		-- from); on the web Escape keeps it (init.lua: no_escape)
		game.hold(close, menu.window, nil, {no_escape = true,
				click = function(x, y)
			local rp, sp = magic.ui.root.position, menu.window.screenPosition
			x, y = x + rp.x - sp.x, y + rp.y - sp.y
			if x < 0 or y < 0 or x >= menu.window.width or
					y >= menu.window.height then
				log:info("pause: a click off the menu")
				close()
			end
		end})
		game.send("pause", "auto on")
		log:info("pause: the menu shown")
	end

	local function show_death()
		close()
		local droot = uistack.main:push({desc = "death"})
		local menu = ui_utils.vertical_menu(droot, {min_width = 260})
		menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText("You died.")
		menu:add("Respawn", function()
			game.send("respawn", "")
		end, true)
		-- [SKELDAT_DEATH_MENU_BUTTON] What Escape does
		menu:add("Pause menu", function() open() end)
		menu:add("Leave the game", function() buildat.leave() end)
		-- Escape does not close it: the menu over it
		death = {root = droot, window = menu.window}
		unhold()
		log:info("pause: the death screen shown")
	end
	-- The respawn: the death screen and the menu over it, if up, gone
	local function hide_death()
		if death then
			uistack.main:pop(death.root)
			death = nil
		end
		if root then
			close()
		else
			game.hold(nil)
		end
	end

	local function follow()
		local now = game.stats.hp <= 0
		if now == dead then
			return
		end
		dead = now
		if dead then
			show_death()
		else
			hide_death()
		end
	end
	table.insert(game.listeners, follow)
	-- [SKELDAT_DEAD_REJOIN] The state as it is when this is made, not only
	-- its changes after
	follow()

	return open
end
-- vim: set noet ts=4 sw=4:
