-- Buildat: vanilla/client_lua/menu.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Which save, and which game it needs. The two were always two facts
-- pretending to be one in Luanti's own menu, and here they are two: a save
-- is listed with the game it says it needs, and a new one is named and given
-- a game to need.
--
-- The scan is the server's, because the server owns the filesystem; this
-- draws what it sends and sends back what was chosen. Once something is
-- chosen this goes away and main/init.lua is what arrives.
local log = buildat.Logger("vanilla")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local ui_utils = require("buildat/extension/ui_utils")
-- simplified: a client before 0.6.48 has no rgb and no SetStyle (this
-- file is the app's, sent to any client): it gets the old colours and
-- the plain button. Drop when old clients are refused.
local rgb = (ui_utils.safe or ui_utils).rgb or function(name)
	return unpack(({warn = {1, 0.8, 0.4}, error = {1, 0.4, 0.4},
			dim = {0.7, 0.7, 0.7}})[name])
end
local function main_style(b)
	if not pcall(function() b:SetStyle("PrimaryButton") end) then
		b:SetStyleAuto()
	end
end
local uistack = require("buildat/extension/uistack")

local root = nil
-- The one line the waiting screen shows, kept so that the next thing to say
-- is a text change rather than a screen built again: what the server says
-- while a game loads is one line per mod, and a game has a couple of hundred
local waiting_text = nil
local games = {}
-- Which page of the save list is on the screen; the list is redrawn when it
-- changes, which is what every other change to this menu does too
local page = 1
-- What the last save list said, so that a screen that goes back to it does
-- not have to ask the server again
local last_saves, last_save_games = {}, {}
-- [DISK_LIMIT_SHOWN] Each save's bytes on disk, by name, and main:disk's
-- numbers: used, limit (0 for none), saves, shared, cache
local save_bytes = {}
local disk = nil
-- Whole MB, 1000000 bytes: --max-disk-mb's unit
local function mb(bytes)
	return string.format("%d MB", math.floor((bytes + 500000) / 1000000))
end
-- What is out there to import, as main:imports last said: each entry is
-- {id or name, title or gameid, "installed" or "", size, the root it is in}
local import_games, import_worlds = {}, {}
-- The import screens' own ([LUANTI_IMPORT_FOLDER]): the worlds left out
-- for having no gameid, the row selected, and whether the folder was
-- opened (Look again shows then)
local imp = {skipped = 0, selected = nil, opened = false}
-- Which of the two import lists the next main:imports is for, and which page
-- of it is on the screen
local want_imports = nil
-- The screen a launch asked for, from the server's main:menu, until the
-- save list has opened it
local menu_wanted = nil
-- And the game the save list is for, when a tile asked for one game's
-- worlds ("worlds:<gameid>"): the list shows that game's saves and New
-- save is that game's ([LAUNCH_GRID])
local menu_game = nil
-- Which screen the launch asked for, kept: the tile that opened the
-- settings or ContentDB is a submenu of the launcher ([MENU_CONTEXT]), so
-- that screen's back goes to the grid, not to a save list nobody asked
-- for. A launch for a game's worlds goes back through the world screen.
local launched_for = nil
-- A public server's ([VANILLA_PUBLIC] 5): "public", or "public_running"
-- when this is opened over the world running, from the pause menu
local public = nil
-- What the pause menu gets back as when this goes back to the world
local M = {back = nil}
buildat.sub_packet("main:menu", function(data)
	local game = data:match("^worlds:(.+)$")
	if data:match("^public") then
		public = data
	elseif game then
		menu_game = game
		menu_wanted = nil
	else
		menu_wanted = data
		launched_for = data
	end
end)

-- **A width that fits the screen** (user, 2026-09-30: a phone): what the
-- menu asks for, or the screen's width less a margin; a narrow screen
-- stacks the world list's two columns
local function fit(px)
	return math.min(px, magic.ui.root.width - 40)
end
local function narrow()
	return magic.ui.root.width < 1000
end

-- What is typed into each list's filter box, kept across the redraws a page
-- turn or a filter change costs. See add_filter().
local save_filter = ""
local import_filter = ""
local game_filter = ""
-- Which page of the game list the new-save flow is on
local game_page = 1

local function close()
	-- A screen of another instance of this script: the media batch re-runs
	-- the client scripts, and the second instance's root is nil while the
	-- first's "Building the world" is still on top of the stack, held by
	-- nobody ([WIN_WORLD] (b), the box). The stack is the extension's, one
	-- for every instance, so the screen on top is closed by its name.
	if root == nil then
		local top = uistack.main.stack[#uistack.main.stack]
		if top and top:GetName():find(": vanilla menu: ", 1, true) then
			root = top
		end
	end
	if root then
		uistack.main:pop(root)
		root = nil
	end
	waiting_text = nil
end

-- The world came up while the menu was still asking for the save list: the
-- server was busy loading the game, so the answer it was asked for arrives
-- after it says the menu is done with. Without this the list draws itself
-- over the world the client is already in. And the guard the other way
-- round ([WIN8_START] 15): nothing here opens a screen once the world is
-- up, whatever packet asks -- a box kept "Building the world" over a
-- world the player was walking in.
local done = false

local function waiting(message)
	if done then
		log:info("menu: no waiting screen for " .. tostring(message) ..
				": the world is up")
		return
	end
	close()
	root = uistack.main:push({desc = "vanilla menu: waiting"})
	-- Over the HUD and the hotbar (priority 10) when over the world
	root.priority = 100
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText(message)
	waiting_text = text
	-- And the seconds under it, so the screen moves while the user can
	-- only wait ([FIRST_RUN]: a screen still for 4 s fails the driven
	-- first run); the message itself moves only when the server says
	local secs = menu.window:CreateChild("Text")
	secs:SetStyleAuto()
	local t0 = buildat.get_time_us()
	root:SubscribeToStackEvent("Update", function()
		secs:SetText(math.floor((buildat.get_time_us() - t0) / 1000000) .. " s")
	end)
end

-- A save is a button, and a new one is a game chosen and then named --
-- two screens, the way importing a world already is, because one button per
-- installed game is twenty-five buttons on this machine and a menu stops
-- being a menu somewhere around ten.
-- Declared first because a page button draws it again.
local draw
local draw_new_game
-- And the import screens, which go back to the save list
local draw_import_games
local draw_import_worlds
-- And the settings screen, drawn from the server's main:settings
local draw_settings
-- The key bindings editor, shared with the game's pause menu, and
-- whether it is the screen up now
local keys_open = false
local keys_editor = (function(ok, err, m)
	if not ok or type(m) ~= "table" then
		error("vanilla menu: could not load keys.lua: " .. tostring(err))
	end
	return m
end)(buildat.run_script_file("main/keys.lua"))
-- ContentDB's games ([CONTENTDB]): the server fetches, this asks and draws
local ask_contentdb, draw_contentdb
local contentdb_query = ""
-- [WORLD_MODS] What the page lists: "game", or "mod" for contentdb_game's
-- mods (the world's whose Mods... opened it)
local contentdb_kind, contentdb_game = "game", ""
-- And the name field of a new save, which the one-game list goes to
local draw_new_save_name

-- Does this line answer what was typed? Case-insensitive, and every word has
-- to be in it somewhere, so "vox cave" finds a VoxeLibre world called caves.
-- A plain find rather than a pattern: a world named "world (2)" is a name
-- here and not a pattern, and so is anything else somebody types.
local function matches(label, filter)
	label = label:lower()
	for word in filter:lower():gmatch("%S+") do
		if not label:find(word, 1, true) then
			return false
		end
	end
	return true
end

-- A filter box over a long list, and the line that says what it did.
--
-- **The sandbox has no scrolling container** -- ui_utils.add_paged() exists
-- because of that -- and two hundred and thirty-four worlds twelve to a page
-- is twenty pages, which is not a list anybody reads. Three characters typed
-- here take it down to the few worth looking at, which beats scrolling even
-- where scrolling exists.
--
-- simplified: it applies when Enter is pressed rather than as the letters
-- arrive, because TextChanged is not in client/extensions/urho3d/safe_events.lua
-- and a redraw per letter would take the field out from under the typing
-- anyway. The upgrade path is whitelisting that event and rebuilding only
-- the list of buttons instead of the screen.
local function add_filter(menu, filter, total, shown, on_change)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	if filter ~= "" then
		text:SetText("filter (enter to apply): " .. shown .. " of " ..
				total .. " shown")
	else
		text:SetText("filter (enter to apply), " .. total .. " in the list:")
	end
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText(filter)
	magic.SubscribeToEvent(edit, "TextFinished",
	function(self, event_type, event_data)
		on_change(edit:GetText())
	end)
	return edit
end

-- What is left of a list once the filter has had it, in the same order
local function filtered(items, filter)
	if filter == "" then
		return items
	end
	local out = {}
	for _, item in ipairs(items) do
		if matches(item.label, filter) then
			out[#out + 1] = item
		end
	end
	return out
end

do
	local items = {
		{label = "world   (minetest_game)"},
		{label = "caves   (voxelibre)  -- no such game"},
		{label = "world (2)   (nodecore)"},
	}
	assert(#filtered(items, "") == 3, "filter: an empty one takes nothing out")
	assert(#filtered(items, "WORLD") == 2, "filter: case")
	assert(filtered(items, "vox cave")[1] == items[2],
			"filter: every word, in any order")
	-- A name is a name and not a pattern, which is what a save called
	-- "world (2)" would be if this used one
	assert(#filtered(items, "world (2)") == 1, "filter: not a pattern")
	assert(#filtered(items, "nothing") == 0, "filter: no match is no rows")
end

-- The save the world screen has selected, and the panel's texts, filled
-- by the main:save_info answer ([WORLD_LIST])
local selected_save = nil
local panel = nil

-- A menu button under any parent, registered with the menu's keyboard
-- walk: the same shape ui_utils' menu:add(label) makes on its own window
-- main: the screen's main button, amber ([MENU_BRAND])
local function button_on(menu, parent, label, action, width, main)
	local b = parent:CreateChild("Button")
	if main then main_style(b) else b:SetStyleAuto() end
	b:SetName("Button")
	b:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	-- A fixed height, not the column's share of what is left: a vertical
	-- layout stretches an unfixed child
	b:SetFixedHeight(28)
	if width then
		b:SetFixedWidth(width)
	end
	local t = b:CreateChild("Text")
	t:SetName("ButtonText")
	t:SetStyleAuto()
	t:SetText(label)
	t:SetTextAlignment(magic.HA_CENTER)
	menu:add(b, action)
	return b
end

-- The world screen in two columns: the saves on the left as a list that
-- scrolls, the selected one's glance, its two world.mt flags, Play and
-- Delete on the right. A row's click selects it and asks the server for
-- the glance; a second click (or Enter on it) plays.
-- simplified: a row shows the name and the game, not when it was last
-- played -- that is in the panel, read on select; official's Configure,
-- Host and Announce are not here.
function draw(saves, save_games)
	last_saves, last_save_games = saves, save_games
	close()
	root = uistack.main:push({desc = "vanilla menu: saves"})
	-- Over the HUD and the hotbar (priority 10) when over the world
	root.priority = 100
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText(menu_game and (menu_game .. ": which world?") or
			"vanilla: which save?")

	local columns = menu.window:CreateChild("UIElement")
	columns:SetLayout(narrow() and magic.LM_VERTICAL or magic.LM_HORIZONTAL,
			16, magic.IntRect(0, 0, 0, 0))
	local left = columns:CreateChild("UIElement")
	left:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(fit(520))
	local right = columns:CreateChild("UIElement")
	right:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	right:SetFixedWidth(fit(420))

	-- Every save, newest first: the server sorts them by when each was
	-- last played
	local items = {}
	for i, name in ipairs(saves) do
		local gameid = save_games[i]
		-- No goto: the web client's Lua is 5.1
		if not menu_game or gameid == menu_game then
			local known = false
			for _, g in ipairs(games) do
				if g == gameid then
					known = true
				end
			end
			local label = menu_game and name or (name .. "   (" ..
					(gameid ~= "" and gameid or "game not recorded") .. ")")
			if gameid ~= "" and not known then
				-- Still listed: a save whose game is not installed is a
				-- save, and saying so is more use than hiding it
				label = label .. "  -- no such game"
			end
			if save_bytes[name] then
				label = label .. "   " .. mb(save_bytes[name])
			end
			items[#items + 1] = {label = label, name = name}
		end
	end
	local shown = filtered(items, save_filter)
	add_filter({window = left}, save_filter, #items, #shown, function(text)
		save_filter = text
		draw(saves, save_games)
	end)
	local list = left:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(520), narrow() and
			math.max(100, math.floor(magic.ui.root.height * 0.18)) or 520)
	if selected_save then
		local still = false
		for _, item in ipairs(shown) do
			if item.name == selected_save then
				still = true
			end
		end
		if not still then
			selected_save = nil
		end
	end
	local row_buttons = {}
	local function select(name)
		selected_save = name
		for n, b in pairs(row_buttons) do
			b.selected = (n == name)
		end
		buildat.send_packet("main:save_info",
				cereal.binary_output({name}, {"array", "string"}))
	end
	local function play(name)
		-- The menu is done choosing; a launch UI that paused something
		-- for it can carry on ([LAUNCH_API])
		buildat.launch_loading("world")
		waiting("Opening " .. name .. "...")
		buildat.send_packet("main:open",
				cereal.binary_output({name}, {"array", "string"}))
	end
	for _, item in ipairs(shown) do
		local row = list.contentElement:CreateChild("Button")
		row:SetStyleAuto()
		row:SetName("Button")
		row:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(8, 0, 8, 0))
		row:SetFixedWidth(fit(520) - 24)
		row.minHeight = 28
		local text = row:CreateChild("Text")
		text:SetName("ButtonText")
		text:SetStyleAuto()
		text:SetText(item.label)
		text:SetTextAlignment(magic.HA_LEFT)
		row_buttons[item.name] = row
		menu:add(row, function()
			if selected_save == item.name then
				play(item.name)
			else
				select(item.name)
			end
		end)
		list:AddItem(row)
	end
	if #shown == 0 then
		local none = left:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText(#items == 0 and "No saves yet" or "Nothing matches")
	end
	-- Under a limit only: a player's own local game has none
	if disk and disk[2] > 0 then
		local line = left:CreateChild("Text")
		line:SetStyleAuto()
		line:SetName("DiskLine")
		line:SetWordwrap(true)
		line:SetFixedWidth(fit(520))
		line:SetText("Disk: " .. mb(disk[1]) .. " of " ..
				mb(disk[2]) .. " (worlds " .. mb(disk[3]) .. ", games " ..
				mb(disk[4]) .. ", cache " .. mb(disk[5]) .. ")")
		if disk[1] >= disk[2] then
			line:SetColor(magic.Color(rgb("error")))
		end
	end

	-- One button rather than one per game: which game is a choice, and it
	-- goes on the same screen as the name it is being given
	local under = {add = function(_, label, action)
		return button_on(menu, left, label, action, fit(520))
	end}
	under:add(menu_game and "New world..." or "New save...", function()
		if menu_game then
			draw_new_save_name(menu_game)
			return
		end
		game_filter = ""
		game_page = 1
		draw_new_game()
	end)

	-- What the import folder has ([LUANTI_IMPORT_FOLDER]), which is where a
	-- game and a world come from until somebody has put one here by hand
	local function ask_for_imports(which)
		want_imports = which
		imp.selected = nil
		import_filter = ""
		waiting("Looking in the import folder...")
		buildat.send_packet("main:get_imports", "")
	end
	if public then
		-- A game from ContentDB is on the server for everyone, where an
		-- import is from this computer's Luanti
		under:add("Get a game from ContentDB...", function()
			ask_contentdb("")
		end)
	else
		under:add("Import a game from Luanti...", function()
			ask_for_imports("games")
		end)
		under:add("Import a world from Luanti...", function()
			ask_for_imports("worlds")
		end)
	end
	-- Back, by Escape or the × ([CLOSE_GLYPH]): to the world, or to the
	-- launcher's grid ([MENU_CONTEXT]); a client that came straight to this
	-- server leaves it instead
	local function back()
		if public == "public_running" then
			done = true
			close()
			if M.back then
				M.back()
			end
		else
			buildat.leave()
		end
	end
	menu:on_key(function(key)
		if key == magic.KEY_ESCAPE and magic.input:GetKeyPress(key) then
			back()
			return true
		end
	end)
	ui_utils.close_glyph(root, menu.window, back)

	-- The right column: the glance, the flags, Play and Delete
	panel = {lines = {}, flags = {}}
	local head = right:CreateChild("Text")
	head:SetStyleAuto()
	head:SetText(selected_save or (narrow() and "Pick a world above" or
			"Pick a world on the left"))
	panel.head = head
	-- On a narrow screen the glance is one line that wraps, so that the
	-- screen fits a phone's height
	for k = 1, narrow() and 1 or 7 do
		local line = right:CreateChild("Text")
		line:SetStyleAuto()
		line:SetText("")
		line:SetTextAlignment(magic.HA_LEFT)
		if narrow() then
			line:SetWordwrap(true)
			line:SetFixedWidth(fit(420))
		end
		panel.lines[k] = line
	end
	local function flag_row(key, label)
		local b = button_on(menu, right, "[ ] " .. label, function()
			if not selected_save or panel.flags[key] == nil then
				return
			end
			local f = panel.flags
			f[key] = not f[key]
			buildat.send_packet("main:set_world_flags",
					cereal.binary_output({selected_save,
					f.creative_mode and "true" or "false",
					f.enable_damage and "true" or "false"}, {"array", "string"}))
		end, fit(420))
		panel[key] = {button = b, label = label}
	end
	flag_row("creative_mode", "Creative mode")
	flag_row("enable_damage", "Enable damage")
	button_on(menu, right, "Game settings...", function()
		if selected_save then
			waiting("Reading the settings of " .. selected_save .. "...")
			buildat.send_packet("main:get_game_settings",
					cereal.binary_output({selected_save}, {"array", "string"}))
		end
	end, fit(420))
	-- [SERVER_PRESETS] the same form, of what the world costs its server
	button_on(menu, right, "Server performance...", function()
		if selected_save then
			waiting("Reading the settings of " .. selected_save .. "...")
			buildat.send_packet("main:get_perf_settings",
					cereal.binary_output({selected_save}, {"array", "string"}))
		end
	end, fit(420))
	-- [WORLD_MODS]
	button_on(menu, right, "Mods...", function()
		if selected_save then
			waiting("Reading the mods of " .. selected_save .. "...")
			buildat.send_packet("main:get_world_mods",
					cereal.binary_output({selected_save}, {"array", "string"}))
		end
	end, fit(420))
	-- [WORLD_TXP]
	button_on(menu, right, "Texture pack...", function()
		if selected_save then
			waiting("Reading the texture pack of " .. selected_save .. "...")
			buildat.send_packet("main:get_world_txp",
					cereal.binary_output({selected_save}, {"array", "string"}))
		end
	end, fit(420))
	button_on(menu, right, "Play", function()
		if selected_save then
			play(selected_save)
		end
	end, fit(420), true)
	button_on(menu, right, "Delete...", function()
		local name = selected_save
		if not name then
			return
		end
		ui_utils.show_confirm_dialog("Move the world \"" .. name ..
				"\" to the trash?", function()
			selected_save = nil
			waiting("Moving " .. name .. " to the trash...")
			buildat.send_packet("main:delete",
					cereal.binary_output({name}, {"array", "string"}))
		end, function() end, "Move to the trash")
	end, fit(420))
	if selected_save then
		select(selected_save)
	end

	magic.input:SetMouseVisible(true, "a menu screen")

	-- A launch that asked for an import screen goes straight to it, once
	-- the save list it comes back to is drawn ([LAUNCH_GRID])
	if menu_wanted == "import_game" then
		menu_wanted = nil
		ask_for_imports("games")
	elseif menu_wanted == "import_world" then
		menu_wanted = nil
		ask_for_imports("worlds")
	elseif menu_wanted == "settings" then
		menu_wanted = nil
		waiting("Reading the settings...")
		buildat.send_packet("main:get_settings", "")
	elseif menu_wanted == "contentdb" then
		menu_wanted = nil
		ask_contentdb("")
	end
end

-- How big it is, the way buildat's own game menu says it: see
-- format_bytes() in extensions/launch_menu/screens.lua, which this is the same
-- ladder as. A menu that says nothing about size is a menu that cannot tell
-- a moment's copy from a minute's.
local function format_bytes(n)
	n = math.floor(tonumber(n) or 0)
	if n < 1024 then
		return n .. " B"
	end
	local kb = n / 1024
	if kb < 1024 then
		if kb < 10 then
			return string.format("%.1f KB", kb)
		end
		return math.floor(kb + 0.5) .. " KB"
	end
	local mb = kb / 1024
	if mb < 1024 then
		if mb < 10 then
			return string.format("%.1f MB", mb)
		end
		return math.floor(mb + 0.5) .. " MB"
	end
	local gb = mb / 1024
	if gb < 10 then
		return string.format("%.1f GB", gb)
	end
	return math.floor(gb + 0.5) .. " GB"
end

-- The screen the two import buttons lead to. Both are a list of what was
-- found with a line each, and both can go back to the save list.
local function import_menu(title)
	close()
	root = uistack.main:push({desc = "vanilla menu: " .. title})
	-- Over the HUD and the hotbar (priority 10) when over the world
	root.priority = 100
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText(title)
	return menu
end

local function back_to_saves(menu, screen)
	if screen and launched_for == screen then
		menu:add("< back to the launcher", function()
			buildat.leave()
		end)
	else
		menu:add("< back", function()
			draw(last_saves, last_save_games)
		end)
	end
	magic.input:SetMouseVisible(true, "a menu screen")
end

-- The launcher's settings ([LAUNCH_GRID]), kept by the server in
-- user/shared/vanilla/settings.json and sent whole each way as a list of
-- "key=value" rows. The import search paths that were here went with the
-- import folder ([LUANTI_IMPORT_FOLDER]).
function draw_settings(paths)
	local menu = import_menu("Luanti settings")
	-- The render mode rides in the list as "render_mode=<mode>", and goes
	-- back with the paths. Key rows from before the client's key store
	-- are moved there (keys.lua's apply, which sends the list without
	-- them; the server's answer draws this again).
	if keys_editor.apply(paths) > 0 then
		return
	end
	local mode = "pbr"
	local view_range = "120"
	local view_bobbing = "1"
	local shoulder = "0"
	local lod_detail = "full"
	local kept = {}
	for _, p in ipairs(paths) do
		local m = p:match("^render_mode=(.*)$")
		local r = p:match("^view_range=(%d+)$")
		local b = p:match("^view_bobbing_amount=([%d.]+)$")
		local sh = p:match("^third_person_shoulder=([01])$")
		local ld = p:match("^lod_detail=(%a+)$")
		if sh then
			shoulder = sh
		elseif ld then
			lod_detail = ld
		elseif m then
			mode = m
		elseif r then
			view_range = r
		elseif b then
			view_bobbing = b
		else
			kept[#kept + 1] = p
		end
	end
	paths = kept
	local function send(list)
		waiting("Saving...")
		list[#list + 1] = "render_mode=" .. mode
		list[#list + 1] = "view_range=" .. view_range
		list[#list + 1] = "lod_detail=" .. lod_detail
		list[#list + 1] = "view_bobbing_amount=" .. view_bobbing
		list[#list + 1] = "third_person_shoulder=" .. shoulder
		buildat.send_packet("main:set_settings",
				cereal.binary_output(list, {"array", "string"}))
	end
	-- The keys: the client's page of them, as the pause menu's Settings
	-- window has ([SETTINGS_KEYS_PAGE]); keys.lua's own editor on a client
	-- without it. Back asks for the settings again.
	menu:add("Key bindings...", function()
		close()
		keys_open = true
		local function back()
			keys_open = false
			buildat.send_packet("main:get_settings", "")
			waiting("Loading settings...")
		end
		if buildat.show_game_keys then
			buildat.show_game_keys{on_close = back}
		else
			keys_editor.draw(back)
		end
	end)
	local function resend()
		local list = {}
		for _, p in ipairs(paths) do
			list[#list + 1] = p
		end
		send(list)
	end
	-- The mode a session draws in, unless BUILDAT_LUANTI_PBR says
	-- otherwise ([RENDER_MODES])
	menu:add_dropdown("Render mode (the next session's)",
			{"pbr", "shadows", "unlit"}, mode, function(m)
		mode = m
		resend()
	end)
	-- The viewing range ([VIEW_RANGE]): how far the server sends, the
	-- client meshes and the camera draws; 120 unless set, so a new
	-- install does not bet on a strong computer. Applied at once in a
	-- running world, and to the next one.
	-- simplified: the five picks; a number field for the rest when
	-- somebody wants 90.
	menu:add_dropdown("View range, in nodes (farther is slower)",
			{"60", "120", "200", "300", "400"}, view_range, function(r)
		view_range = r
		resend()
	end)
	-- How far full detail reaches, as a share of the range above
	-- ([CLIENT_FRAME]): past it a chunk is meshed from a downsampled
	-- volume -- a quarter of the triangles at the first step, and a
	-- coarser silhouette in the distance. It is the setting for a machine
	-- whose GPU is slower than its processor, which is most laptops: on
	-- this desk's Intel a made VoxeLibre world reads 30 fps at full and
	-- 55 at half, and on its Nvidia the same change is worth almost
	-- nothing. Full is the default, so nobody pays for the distance who
	-- is not short of GPU.
	menu:add_dropdown("Distant terrain detail (less is faster)",
			{{"Full", "full"}, {"Reduced past half range", "half"},
			{"Reduced past a third", "third"}}, lod_detail, function(d)
		lod_detail = d
		resend()
	end)
	-- View bobbing ([VIEW_BOB]): official's view_bobbing_amount, 1 or off
	-- simplified: on or off; the amount when somebody wants 0.5
	menu:add((view_bobbing ~= "0" and "[x] " or "[ ] ") .. "View bobbing",
			function()
		view_bobbing = view_bobbing ~= "0" and "0" or "1"
		local list = {}
		for _, p in ipairs(paths) do
			list[#list + 1] = p
		end
		send(list)
	end)
	back_to_saves(menu, "settings")
end

-- ContentDB's games, fetched by the server ([CONTENTDB]): a search field,
-- a line per game with its title, author and one-line description, and
-- Install on each, which the server answers with progress lines and a
-- message when the game is in place (it shows on the grid as an imported
-- game does). simplified: no thumbnails yet, and the first page only --
-- the query narrows it.
-- kind and gameid: mods for that game ([WORLD_MODS]); left out, games
function ask_contentdb(query, kind, gameid)
	contentdb_query = query
	contentdb_kind = kind or "game"
	contentdb_game = gameid or ""
	waiting("Asking ContentDB...")
	buildat.send_packet("main:contentdb_query",
			cereal.binary_output({query, contentdb_kind, contentdb_game},
			{"array", "string"}))
end

-- The pictures the rows wait for, by client file name; the server names
-- each as it lands and the row asks the cache until it is there
local pictures = {}

function draw_contentdb(flat)
	local mods = contentdb_kind == "mod"
	local txp = contentdb_kind == "txp"
	local menu = import_menu("ContentDB: " .. (mods and ("mods for " ..
			contentdb_game) or txp and "texture packs" or "games") ..
			(contentdb_query ~= "" and (" matching \"" .. contentdb_query .. "\"") or ""))
	if public and not txp then
		-- [VANILLA_PUBLIC] 7: a game's mods are Lua that runs on the server
		local warn = menu.window:CreateChild("Text")
		warn:SetStyleAuto()
		warn:SetText(mods and "A mod runs on this server: install only " ..
				"mods you trust." or "A game's mods run on this server: " ..
				"install only games you trust.")
		warn:SetColor(magic.Color(rgb("warn")))
	end
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText(contentdb_query)
	menu:add("Search", function()
		ask_contentdb((edit:GetText():gsub("^%s+", ""):gsub("%s+$", "")),
				contentdb_kind, contentdb_game)
	end)
	-- A row a game in a list that scrolls ([CONTENTDB_LIST]): the picture,
	-- the title and author over the description, left-aligned and
	-- wrapped, and Install at the right. The Install buttons are the
	-- menu's own, so the arrows and Enter walk them; the wheel scrolls.
	-- simplified: the arrows do not scroll the list to the selected row.
	local list = menu.window:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(860), math.min(620,
			math.floor(magic.ui.root.height * 0.6)))
	-- A phone's row has no room for the picture
	local row_w = fit(860) - 40
	local with_pic = row_w >= 600
	pictures = {}
	local n = 0
	for i = 1, #flat - 4, 5 do
		local author, name, title, desc = flat[i], flat[i + 1], flat[i + 2], flat[i + 3]
		n = n + 1
		local row = list.contentElement:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(4, 4, 4, 4))
		row:SetFixedWidth(row_w)
		if with_pic then
			local pic = row:CreateChild("Sprite")
			pic:SetFixedSize(96, 64)
			pic.color = magic.Color(0.3, 0.3, 0.3)
			pictures["contentdb/" .. author .. "_" .. name .. ".png"] = pic
		end
		local block_w = row_w - (with_pic and 106 or 0) - 120
		local block = row:CreateChild("UIElement")
		block:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
		block:SetFixedWidth(block_w)
		local head = block:CreateChild("Text")
		head:SetStyleAuto()
		head:SetText(title .. "  by " .. author)
		head:SetTextAlignment(magic.HA_LEFT)
		if desc ~= "" then
			local body = block:CreateChild("Text")
			body:SetStyleAuto()
			body:SetFixedWidth(block_w)
			body:SetWordwrap(true)
			body:SetText(desc)
			body:SetTextAlignment(magic.HA_LEFT)
		end
		-- In a cell of its own: the row's layout stretches a child to the
		-- picture's 64, and a button that tall draws its word at its top;
		-- the cell is stretched instead and the button sits in its middle
		local cell = row:CreateChild("UIElement")
		cell:SetFixedWidth(100)
		local button = cell:CreateChild("Button")
		button:SetStyleAuto()
		button:SetName("Button")
		button:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
		button:SetFixedSize(100, 28)
		button:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
		local label = button:CreateChild("Text")
		label:SetName("ButtonText")
		label:SetStyleAuto()
		label:SetText("Install")
		label:SetTextAlignment(magic.HA_CENTER)
		menu:add(button, function()
			waiting("Fetching " .. name .. "...")
			buildat.send_packet("main:contentdb_install",
					cereal.binary_output(mods and {author, name, "mod",
					contentdb_game} or txp and {author, name, "txp"} or
					{author, name}, {"array", "string"}))
		end)
		list:AddItem(row)
	end
	log:info("menu: ContentDB " .. contentdb_kind .. "s: " .. n .. " rows")
	if n == 0 then
		local none = menu.window:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText("Nothing found")
	end
	-- The pictures as they land: the file is announced before it has
	-- crossed, so a name is asked for each frame until the cache has it
	local pending = {}
	local pending_n = 0
	root:SubscribeToStackEvent("Update", function()
		if pending_n == 0 then
			return
		end
		for file, pic in pairs(pending) do
			local tex = magic.cache:GetResource("Texture2D", file)
			if tex then
				pic:SetTexture(tex)
				pic.color = magic.Color(1, 1, 1)
				pending[file] = nil
				pending_n = pending_n - 1
			end
		end
	end)
	pictures.__add = function(file)
		local pic = pictures[file]
		if pic and not pending[file] then
			pending[file] = pic
			pending_n = pending_n + 1
		end
	end
	back_to_saves(menu, "contentdb")
end

-- [WORLD_MODS] A mod that needs more than the game and the installed mods
-- give: {author, name, gameid, then author, name of each}, asked once
buildat.sub_packet("main:contentdb_deps", function(data)
	if done then
		return
	end
	local v = cereal.binary_input(data, {"array", "string"})
	local names = {}
	for i = 4, #v - 1, 2 do
		names[#names + 1] = v[i + 1] .. " by " .. v[i]
	end
	log:info("menu: " .. v[2] .. " needs " .. table.concat(names, ", "))
	ui_utils.show_confirm_dialog(v[2] .. " needs what this server does not " ..
			"have: " .. table.concat(names, ", ") .. ". Install them with it?",
			function()
		waiting("Fetching " .. v[2] .. "...")
		local out = {v[1], v[2], "mod", v[3], "confirmed"}
		for i = 4, #v do
			out[#out + 1] = v[i]
		end
		buildat.send_packet("main:contentdb_install",
				cereal.binary_output(out, {"array", "string"}))
	end, function()
		buildat.send_packet("main:get_saves", "")
	end, "Install all")
end)

buildat.sub_packet("main:contentdb_picture", function(data)
	local file = cereal.binary_input(data, {"array", "string"})[1]
	if file and pictures.__add then
		pictures.__add(file)
	end
end)

-- A new save, in the two steps importing a world already takes: which game,
-- and then what to call it. The name field is on the second screen with the
-- game it is for, rather than above a column of one button per game.
-- The mapgens Luanti ships, official's default first ([NEW_WORLD_FORM]):
-- what the world is made of is a choice made once, when it is made, and a
-- world made with the wrong one is a world made again.
--
-- simplified: a constant rather than core.get_mapgen_names(), which is the
-- engine's answer and there is no engine running while the menu is up. The
-- upgrade path is the luanti module answering a main:get_mapgens packet.
local MAPGENS = {"v7", "v5", "valleys", "carpathian", "flat", "fractal",
		"v6", "singlenode"}
-- What each game offers of them, the server's reading of its game.conf
-- and minetest.conf, the one to pick first ([GAME_CONF_MAPGENS])
local game_mapgens = {}
buildat.sub_packet("main:game_mapgens", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	game_mapgens = {}
	for i = 1, #values - 1, 2 do
		local list = {}
		for name in values[i + 1]:gmatch("[^,]+") do
			list[#list + 1] = name
		end
		game_mapgens[values[i]] = list
	end
end)

-- What the screen was holding when a create failed, so that a name already
-- taken does not throw the rest away ([NEW_WORLD_FORM]); nil when no create
-- is outstanding
local creating = nil

function draw_new_save_name(gameid, state)
	state = state or {}
	local menu = import_menu("New save, playing " .. gameid)
	-- Why the last create did not happen, on the screen rather than in a
	-- dialog: a dialog closes the screen and the name, the seed and the
	-- toggles go with it
	if state.error then
		local why = menu.window:CreateChild("Text")
		why:SetStyleAuto()
		why:SetText(state.error)
		why.color = magic.Color(rgb("error"))
	end
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText("named:")
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText(state.name or "world")
	-- The seed, beside the name: empty is a random one; a number is
	-- Luanti's fixed_map_seed for this world ([FIRST_RUN]: the driven
	-- first run types the seed it knows how to play)
	local seed_text = menu.window:CreateChild("Text")
	seed_text:SetStyleAuto()
	seed_text:SetText("seed (empty for a random one):")
	local seed_edit = menu.window:CreateChild("LineEdit")
	seed_edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	seed_edit.textCopyable = true
	seed_edit.textSelectable = true
	seed_edit.minHeight = 26
	seed_edit.enabled = true
	seed_edit:SetText(state.seed or "")
	-- The new world's two world.mt flags, official's defaults
	-- ([WORLD_LIST]); the buttons say their state
	local flags = state.flags or
			{creative_mode = false, enable_damage = true}
	for _, f in ipairs({{"creative_mode", "Creative mode"},
			{"enable_damage", "Enable damage"}}) do
		local b
		b = menu:add((flags[f[1]] and "[x] " or "[ ] ") .. f[2], function()
			flags[f[1]] = not flags[f[1]]
			b:GetChild("ButtonText"):SetText((flags[f[1]] and "[x] " or "[ ] ") .. f[2])
		end)
	end
	-- Which mapgen
	local offered = game_mapgens[gameid] or MAPGENS
	if #offered == 0 then
		offered = MAPGENS
	end
	local mapgen = state.mapgen or offered[1]
	menu:add_dropdown("Mapgen", offered, mapgen, function(name)
		mapgen = name
	end)
	-- Over a running world a new one is only made ([VANILLA_PUBLIC] 5)
	menu:add(public == "public_running" and "Create" or "Create and play",
			function()
		local name = edit:GetText()
		local seed = seed_edit:GetText()
		-- Kept, so that a create the server refuses comes back to this
		-- screen with what was typed still in it
		creating = {gameid = gameid, name = name, seed = seed,
				mapgen = mapgen, flags = flags}
		buildat.launch_loading("world")
		waiting("Creating " .. name .. "...")
		buildat.send_packet("main:create",
				cereal.binary_output({name, gameid, seed,
				flags.creative_mode and "true" or "false",
				flags.enable_damage and "true" or "false", mapgen},
				{"array", "string"}))
	end)
	menu:add("< back", function()
		draw_new_game()
	end)
	magic.input:SetMouseVisible(true, "a menu screen")
	-- The focus in the name, which is the field an error is usually about
	magic.ui:SetFocusElement(edit)
end

function draw_new_game()
	local menu = import_menu("New save: which game?")
	local items = {}
	for _, gameid in ipairs(games) do
		items[#items + 1] = {label = gameid, action = function()
			draw_new_save_name(gameid)
		end}
	end
	if #items == 0 then
		local none = menu.window:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText("No games installed. Import one from Luanti first.")
	end
	local shown = filtered(items, game_filter)
	add_filter(menu, game_filter, #items, #shown, function(text)
		game_filter = text
		game_page = 1
		draw_new_game()
	end)
	ui_utils.add_paged(menu, shown, {
		page = game_page,
		per_page = 12,
		redraw = function(new_page)
			game_page = new_page
			draw_new_game()
		end,
	})
	back_to_saves(menu)
end

-- **The two import screens** ([LUANTI_IMPORT_FOLDER]), as Browse: the
-- import folder's line and buttons, the list with its filter on the left,
-- the selected one's panel on the right (under it on a narrow screen). A
-- row's click selects it, a second imports. The server reads only the
-- import folder, <user>/shared/vanilla/import, which the box grants.
local function draw_imports(which)
	local worlds = which == "worlds"
	close()
	root = uistack.main:push({desc = "vanilla menu: import " .. which})
	root.priority = 100
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local function back()
		if launched_for == (worlds and "import_world" or "import_game") then
			buildat.leave()
		else
			draw(last_saves, last_save_games)
		end
	end
	menu:on_key(function(key)
		if key == magic.KEY_ESCAPE and magic.input:GetKeyPress(key) then
			back()
			return true
		end
	end)
	ui_utils.close_glyph(root, menu.window, back)
	local function text(parent, t, dim, width)
		local l = parent:CreateChild("Text")
		l:SetStyleAuto()
		l:SetText(t)
		if dim then l.color = magic.Color(rgb("dim")) end
		if width then
			l:SetWordwrap(true)
			l:SetFixedWidth(width)
		end
		return l
	end
	local title = text(menu.window, worlds and "Import a Luanti world" or
			"Import a Luanti game")
	title:SetFontSize(20)
	local wide = narrow() and fit(520) or fit(520) + 16 + fit(420)
	text(menu.window, "Copy a game's or a world's folder (or your whole " ..
			".minetest / .luanti folder) into the import folder.", true, wide)
	if buildat.open_import_folder then
		local row = menu.window:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 8, magic.IntRect(0, 0, 0, 0))
		button_on(menu, row, "Open the import folder", function()
			local ok, why = buildat.open_import_folder()
			if ok then
				imp.opened = true
				draw_imports(which)
			else
				ui_utils.show_message_dialog("The folder did not open: " ..
						tostring(why))
			end
		end, 220)
		if imp.opened then
			button_on(menu, row, "Look again", function()
				want_imports = which
				waiting("Looking in the import folder...")
				buildat.send_packet("main:get_imports", "")
			end, 140)
		end
	end

	local columns = menu.window:CreateChild("UIElement")
	columns:SetLayout(narrow() and magic.LM_VERTICAL or magic.LM_HORIZONTAL,
			16, magic.IntRect(0, 0, 0, 0))
	local left = columns:CreateChild("UIElement")
	left:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(fit(520))
	local right = columns:CreateChild("UIElement")
	right:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	right:SetFixedWidth(fit(420))

	local list_of = worlds and import_worlds or import_games
	local items = {}
	for _, e in ipairs(list_of) do
		local needs = worlds and e[3] ~= "installed"
		items[#items + 1] = {label = e[1] .. (worlds and "   " .. e[2] or
				(e[2] ~= "" and e[2] ~= e[1] and "   " .. e[2] or "")),
				entry = e, needs = needs}
	end
	local shown = filtered(items, import_filter)
	add_filter({window = left}, import_filter, #items, #shown, function(t)
		import_filter = t
		draw_imports(which)
	end)
	local list = left:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(520), narrow() and
			math.max(100, math.floor(magic.ui.root.height * 0.22)) or 400)

	-- The panel, filled by select()
	local head = text(right, narrow() and "Pick one above" or
			"Pick one on the left")
	local lines = {}
	for k = 1, 4 do lines[k] = text(right, "", true, fit(420)) end
	local name_label, name_edit
	if worlds then
		name_label = text(right, "As a save named:")
		name_edit = right:CreateChild("LineEdit")
		name_edit:SetStyleAuto()
		name_edit.textCopyable = true
		name_edit.textSelectable = true
		name_edit.minHeight = 26
		name_edit.enabled = true
		name_edit:SetFixedWidth(fit(420))
		name_edit:SetText("")
	end
	local selected = nil
	local function import()
		local e = selected and selected.entry
		if not e then return end
		if not worlds then
			if e[3] == "installed" then
				ui_utils.show_message_dialog(e[1] .. " is already installed." ..
						" Remove it yourself if you mean to replace it.")
				return
			end
			waiting("Copying " .. e[1] .. "...")
			buildat.send_packet("main:import_game",
					cereal.binary_output({e[1]}, {"array", "string"}))
			return
		end
		if e[3] ~= "installed" then
			-- The game screen with that game selected, if it is there
			for _, g in ipairs(import_games) do
				if g[1] == e[2] then
					imp.selected = g[1]
					import_filter = ""
					draw_imports("games")
					return
				end
			end
			ui_utils.show_message_dialog(e[1] .. " wants the game " .. e[2] ..
					", which is neither installed nor in the import folder.")
			return
		end
		local name = name_edit:GetText()
		waiting("Importing " .. e[1] .. " into " .. name .. "...")
		buildat.send_packet("main:import_world",
				cereal.binary_output({e[1], name}, {"array", "string"}))
	end
	local action
	local rows = {}
	local function select(item)
		selected = item
		imp.selected = item.entry[1]
		for it, b in pairs(rows) do b.selected = (it == item) end
		local e = item.entry
		head:SetText(e[1])
		if worlds then
			lines[1]:SetText("Game: " .. e[2] .. (e[3] == "installed" and
					"" or " (not installed)"))
		else
			lines[1]:SetText("Title: " .. (e[2] ~= "" and e[2] or e[1]))
		end
		lines[2]:SetText((worlds and "Name: " or "Id: ") .. e[1])
		lines[3]:SetText("Size: " .. format_bytes(e[4]))
		lines[4]:SetText("Found in: " .. (e[5] or ""))
		if name_edit then name_edit:SetText(e[1]) end
		action:GetChild("ButtonText"):SetText(item.needs and
				"Import " .. e[2] .. " first" or (not worlds and
				e[3] == "installed" and "Installed already" or "Import"))
		log:info("menu: import panel " .. e[1])
	end
	for _, item in ipairs(shown) do
		local row = list.contentElement:CreateChild("Button")
		row:SetStyleAuto()
		row:SetName("Button")
		row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(8, 0, 8, 0))
		row:SetFixedWidth(fit(520) - 24)
		row.minHeight = 28
		local t = row:CreateChild("Text")
		t:SetName("ButtonText")
		t:SetStyleAuto()
		t:SetText(item.label)
		if item.needs then t.color = magic.Color(rgb("dim")) end
		local badge = row:CreateChild("Text")
		badge:SetStyleAuto()
		badge:SetText((item.needs and "needs " .. item.entry[2] .. "  " or "") ..
				format_bytes(item.entry[4]))
		badge.color = magic.Color(rgb("dim"))
		badge:SetTextAlignment(magic.HA_RIGHT)
		rows[item] = row
		menu:add(row, function()
			if selected == item then import() else select(item) end
		end)
		list:AddItem(row)
	end
	if #items == 0 then
		text(left, "Nothing in the import folder yet.")
	elseif #shown == 0 then
		text(left, "Nothing matches")
	end
	if worlds and imp.skipped > 0 then
		text(left, "Not listed: " .. imp.skipped .. " world" ..
				(imp.skipped == 1 and "" or "s") ..
				" with no gameid in world.mt", true, fit(520))
	end
	action = button_on(menu, right, "Import", import, fit(420), true)
	for _, item in ipairs(shown) do
		if item.entry[1] == imp.selected then select(item) end
	end
	magic.input:SetMouseVisible(true, "a menu screen")
end
function draw_import_games() draw_imports("games") end
function draw_import_worlds() draw_imports("worlds") end

-- The selected save's glance, into the panel; the flags' buttons say
-- their state
-- [GAME_SETTINGS]: a world's options from its game's settingtypes.txt,
-- the world's own value over the declared default; the server keeps them
-- in the world's world.mt, which the game reads when the world starts.
-- What was changed and not saved yet outlives a redraw by the filter.
-- simplified: the label only; the comment lines above a setting in
-- settingtypes.txt, its help, are not read
local game_settings = {filter = "", changed = {}}
-- perf: main:perf_settings, the server's ([SERVER_PRESETS]), which
-- comes as the same list
local function draw_game_settings(flat, perf)
	local save, note = flat[1], flat[2]
	local menu = import_menu(save .. (perf and ": server performance" or
			": its game's settings"))
	if note ~= "" then
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(note)
		if note:sub(1, 6) ~= "Saved." then
			t.color = magic.Color(rgb("error"))
		end
	end
	local items = {}
	for i = 3, #flat - 5, 6 do
		items[#items + 1] = {name = flat[i], type = flat[i + 2],
				label = flat[i + 1] .. "  (" .. flat[i] .. ")",
				extra = flat[i + 4],
				value = flat[i + 5] ~= "" and flat[i + 5] or flat[i + 3]}
	end
	if #items == 0 and note == "" then
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText("This game declares no settings.")
	end
	local changed = game_settings.changed
	local edits = {}
	-- A field's text into `changed` where it differs from what was shown
	local function collect()
		for name, e in pairs(edits) do
			if e.edit:GetText() ~= e.shown then
				changed[name] = e.edit:GetText()
			end
		end
	end
	local shown = filtered(items, game_settings.filter)
	if #items > 0 then
		add_filter(menu, game_settings.filter, #items, #shown, function(f)
			collect()
			game_settings.filter = f
			draw_game_settings(flat, perf)
		end)
		local list = menu.window:CreateChild("ListView")
		list:SetStyleAuto()
		list:SetFixedSize(fit(860), math.min(520,
				math.floor(magic.ui.root.height * 0.55)))
		local row_w = fit(860) - 40
		local control_w = math.min(220, math.floor(row_w / 3))
		for _, it in ipairs(shown) do
			local value = changed[it.name] or it.value
			local row = list.contentElement:CreateChild("UIElement")
			row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(4, 2, 4, 2))
			row:SetFixedWidth(row_w)
			local label = row:CreateChild("Text")
			label:SetStyleAuto()
			label:SetFixedWidth(row_w - control_w - 20)
			label:SetWordwrap(true)
			label:SetText(it.label .. (changed[it.name] and "  *" or ""))
			label:SetTextAlignment(magic.HA_LEFT)
			if it.type == "bool" then
				-- A choice of two flips
				local b
				b = button_on(menu, row, value, function()
					local next_v = (changed[it.name] or it.value) == "true"
							and "false" or "true"
					changed[it.name] = next_v
					b:GetChild("ButtonText"):SetText(next_v)
					label:SetText(it.label .. "  *")
				end, control_w)
			elseif it.type == "enum" then
				local values = {}
				for v in it.extra:gmatch("[^,]+") do
					values[#values + 1] = v
				end
				menu:add(ui_utils.dropdown(row, values, value, function(v)
					changed[it.name] = v
					label:SetText(it.label .. "  *")
				end, {width = control_w}), function() end)
			else
				local edit = row:CreateChild("LineEdit")
				edit:SetStyleAuto()
				edit.textCopyable = true
				edit.textSelectable = true
				edit:SetFixedSize(control_w, 26)
				edit.enabled = true
				edit:SetText(value)
				edits[it.name] = {edit = edit, shown = value}
			end
		end
		menu:add("Save", function()
			collect()
			local out = {save}
			for name, v in pairs(changed) do
				out[#out + 1] = name
				out[#out + 1] = v
			end
			waiting("Saving the settings of " .. save .. "...")
			buildat.send_packet(perf and "main:set_perf_settings" or
					"main:set_game_settings",
					cereal.binary_output(out, {"array", "string"}))
		end)
	end
	menu:add("< back", function()
		draw(last_saves, last_save_games)
	end)
	magic.input:SetMouseVisible(true, "a menu screen")
end

buildat.sub_packet("main:game_settings", function(data)
	local flat = cereal.binary_input(data, {"array", "string"})
	-- What the server has now: a fresh screen, or one just saved
	game_settings.changed = {}
	if flat[2] == "" then
		game_settings.filter = ""
	end
	draw_game_settings(flat)
end)
buildat.sub_packet("main:perf_settings", function(data)
	local flat = cereal.binary_input(data, {"array", "string"})
	game_settings.changed = {}
	game_settings.filter = ""
	draw_game_settings(flat, true)
end)

-- [WORLD_MODS] A world's mods: every installed mod with a toggle, a
-- modpack as a row of its own over its mods (its toggle turns them all),
-- one world.mt turns on that is not installed shown missing with a way to
-- ContentDB, and Remove for what no world uses. A change takes effect at
-- the world's next start.
local function draw_world_mods(flat)
	local save, note, gameid, restart = flat[1], flat[2], flat[3], flat[4]
	local menu = import_menu(save .. ": mods")
	local t = menu.window:CreateChild("Text")
	t:SetStyleAuto()
	t:SetWordwrap(true)
	t:SetFixedWidth(fit(860))
	t:SetText(note ~= "" and note or "Turned on here, a mod runs when the " ..
			"world starts. It is Lua that runs on the server.")
	local function send(name, packet, on)
		waiting("Saving...")
		buildat.send_packet(packet, cereal.binary_output({save, name, on},
				{"array", "string"}))
	end
	local list = menu.window:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(860), math.min(460,
			math.floor(magic.ui.root.height * 0.5)))
	local row_w = fit(860) - 40
	local n = 0
	for i = 5, #flat - 3, 4 do
		local name, pack, state, deps = flat[i], flat[i + 1], flat[i + 2],
				flat[i + 3]
		n = n + 1
		local row = list.contentElement:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(4, 2, 4, 2))
		row:SetFixedWidth(row_w)
		local indent = (pack ~= "" and state ~= "pack") and "      " or ""
		if state == "missing" then
			local label = row:CreateChild("Text")
			label:SetStyleAuto()
			label:SetFixedWidth(row_w - 230)
			label:SetText(name .. "  -- missing: turned on, not installed")
			label:SetColor(magic.Color(rgb("error")))
			button_on(menu, row, "Get from ContentDB", function()
				ask_contentdb(name, "mod", gameid)
			end, 210)
		else
			-- A mod that comes with Buildat ("b1", "b0"): its deps is the
			-- game's or the world's own wield light it replaces
			local builtin = state == "b1" or state == "b0"
			local text
			if state == "pack" then
				text = name .. "  (modpack)"
			elseif builtin then
				text = (state == "b1" and "[x] " or "[ ] ") .. name ..
						"  -- comes with Buildat" .. (deps == "" and "" or
						state == "b1" and ("; " .. deps .. " light the map no more") or
						("; recommended: " .. deps .. " light the map, and the " ..
						"map is lit again at every step"))
			else
				text = (state == "1" and "[x] " or "[ ] ") .. name ..
						(deps ~= "" and ("  -- needs " .. deps) or "")
			end
			button_on(menu, row, indent .. text, function()
				if state == "pack" then
					-- The pack on unless every mod in it is on already
					local all = true
					for j = 5, #flat - 3, 4 do
						if flat[j + 1] == name and flat[j + 2] == "0" then
							all = false
						end
					end
					send(name, "main:set_world_mods", all and "0" or "1")
				else
					send(name, "main:set_world_mods",
							(state == "1" or state == "b1") and "0" or "1")
				end
			end, row_w - 150)
			if (pack == "" or state == "pack") and not builtin then
				button_on(menu, row, "Remove", function()
					ui_utils.show_confirm_dialog("Move " .. name ..
							" off the server, to its trash?", function()
						send(name, "main:remove_mod", "")
					end, function() end, "Remove")
				end, 130)
			end
		end
		list:AddItem(row)
	end
	if n == 0 then
		local none = menu.window:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText("No mods installed on this server")
	end
	menu:add("Get mods from ContentDB...", function()
		ask_contentdb("", "mod", gameid)
	end)
	if restart == "1" then
		menu:add("Restart the world now", function()
			buildat.send_packet("main:restart_world",
					cereal.binary_output({save}, {"array", "string"}))
		end)
	end
	menu:add("< back", function()
		draw(last_saves, last_save_games)
	end)
	magic.input:SetMouseVisible(true, "a menu screen")
end
buildat.sub_packet("main:world_mods", function(data)
	if done then
		return
	end
	local flat = cereal.binary_input(data, {"array", "string"})
	log:info("menu: world mods of " .. tostring(flat[1]) .. ": " ..
			tostring(flat[2]) .. " | " .. table.concat(flat, ",", 5))
	draw_world_mods(flat)
end)

-- [WORLD_TXP] A world's texture pack: None or one of the installed packs
-- (Luanti's one at a time), Remove for what no world uses. From the
-- world's next start.
local function draw_world_txp(flat)
	local save, note, chosen, restart = flat[1], flat[2], flat[3], flat[4]
	local menu = import_menu(save .. ": texture pack")
	local t = menu.window:CreateChild("Text")
	t:SetStyleAuto()
	t:SetWordwrap(true)
	t:SetFixedWidth(fit(860))
	t:SetText(note ~= "" and note or "The pack's images, models and sounds " ..
			"in place of the game's, from the world's next start. A pack's " ..
			"override.txt is not applied.")
	local function send(packet, name)
		waiting("Saving...")
		buildat.send_packet(packet, cereal.binary_output({save, name},
				{"array", "string"}))
	end
	local list = menu.window:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(860), math.min(460,
			math.floor(magic.ui.root.height * 0.5)))
	local row_w = fit(860) - 40
	local function row_of(name)
		local row = list.contentElement:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(4, 2, 4, 2))
		row:SetFixedWidth(row_w)
		button_on(menu, row, (chosen == name and "(o) " or "( ) ") ..
				(name == "" and "None: the game's own" or name), function()
			send("main:set_world_txp", name)
		end, row_w - 150)
		if name ~= "" then
			button_on(menu, row, "Remove", function()
				ui_utils.show_confirm_dialog("Move " .. name ..
						" off the server, to its trash?", function()
					send("main:remove_txp", name)
				end, function() end, "Remove")
			end, 130)
		end
		list:AddItem(row)
	end
	row_of("")
	for i = 5, #flat do
		row_of(flat[i])
	end
	menu:add("Get texture packs from ContentDB...", function()
		ask_contentdb("", "txp")
	end)
	if restart == "1" then
		menu:add("Restart the world now", function()
			buildat.send_packet("main:restart_world",
					cereal.binary_output({save}, {"array", "string"}))
		end)
	end
	menu:add("< back", function()
		draw(last_saves, last_save_games)
	end)
	magic.input:SetMouseVisible(true, "a menu screen")
end
buildat.sub_packet("main:world_txp", function(data)
	if done then
		return
	end
	local flat = cereal.binary_input(data, {"array", "string"})
	log:info("menu: world texture pack of " .. tostring(flat[1]) .. ": " ..
			tostring(flat[3]) .. " | " .. tostring(flat[2]) .. " | " ..
			table.concat(flat, ",", 5))
	draw_world_txp(flat)
end)

buildat.sub_packet("main:save_info", function(data)
	if done or not panel then
		return
	end
	local values = cereal.binary_input(data, {"array", "string"})
	local info = {}
	for i = 1, #values - 1, 2 do
		info[values[i]] = values[i + 1]
	end
	if info.name ~= selected_save then
		return
	end
	panel.head:SetText(info.name .. (info.title and info.title ~= "" and
			("  --  " .. info.title) or ""))
	local lines = {}
	if info.mapgen and info.mapgen ~= "" or info.seed and info.seed ~= "" then
		lines[#lines + 1] = "mapgen " .. (info.mapgen ~= "" and info.mapgen or "?") ..
				", seed " .. (info.seed or "?")
	end
	if info.day then
		lines[#lines + 1] = "day " .. info.day .. ", " .. (info.time or "") ..
				"; " .. (info.played or "?") .. " played"
	end
	if info.created_at then
		lines[#lines + 1] = "created " .. info.created_at
	end
	if info.played_at then
		lines[#lines + 1] = "last played " .. info.played_at
	end
	local sections = tonumber(info.sections) or 0
	lines[#lines + 1] = "explored: " .. sections .. " sections, " ..
			math.floor(math.sqrt(sections) * 64 + 0.5) .. " nodes across"
	lines[#lines + 1] = format_bytes(tonumber(info.bytes) or 0) .. " on disk"
	if #panel.lines == 1 then
		panel.lines[1]:SetText(table.concat(lines, "; "))
	else
		for k, line in ipairs(panel.lines) do
			line:SetText(lines[k] or "")
		end
	end
	panel.flags.creative_mode = info.creative_mode == "true"
	panel.flags.enable_damage = info.enable_damage == "true"
	for _, key in ipairs({"creative_mode", "enable_damage"}) do
		local b = panel[key]
		b.button:GetChild("ButtonText"):SetText((panel.flags[key] and "[x] " or
				"[ ] ") .. b.label)
	end
end)

buildat.sub_packet("main:disk", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	disk = {}
	for i = 1, 5 do
		disk[i] = tonumber(values[i]) or 0
	end
	log:info("menu: disk " .. disk[1] .. " of " .. disk[2])
end)

buildat.sub_packet("main:saves", function(data)
	if done then
		return
	end
	local values = cereal.binary_input(data, {"array", "string"})
	local n = tonumber(values[1]) or 0
	local saves = {}
	local save_games = {}
	save_bytes = {}
	for i = 1, n do
		saves[i] = values[i * 3 - 1] or ""
		save_games[i] = values[i * 3] or ""
		save_bytes[saves[i]] = tonumber(values[i * 3 + 1])
	end
	games = {}
	for i = n * 3 + 2, #values do
		games[#games + 1] = values[i]
	end
	log:info("menu: " .. #saves .. " saves, " .. #games .. " games")
	draw(saves, save_games)
end)

buildat.sub_packet("main:imports", function(data)
	if done then
		return
	end
	local values = cereal.binary_input(data, {"array", "string"})
	-- The two counts, then five strings an entry (main.cpp's on_get_imports)
	local n = tonumber(values[1]) or 0
	imp.skipped = tonumber(values[2]) or 0
	import_games = {}
	import_worlds = {}
	local at = 3
	for i = 1, n do
		import_games[i] = {values[at] or "", values[at + 1] or "",
				values[at + 2] or "", values[at + 3] or "0", values[at + 4] or ""}
		at = at + 5
	end
	while at + 4 <= #values do
		import_worlds[#import_worlds + 1] = {values[at], values[at + 1],
				values[at + 2], values[at + 3], values[at + 4]}
		at = at + 5
	end
	log:info("menu: " .. #import_games .. " games and " .. #import_worlds ..
			" worlds to import, " .. imp.skipped .. " without a gameid")
	if want_imports == "worlds" then
		draw_import_worlds()
	else
		draw_import_games()
	end
end)

buildat.sub_packet("main:contentdb_list", function(data)
	if done then
		return
	end
	draw_contentdb(cereal.binary_input(data, {"array", "string"}))
end)

buildat.sub_packet("main:settings", function(data)
	if done then
		return
	end
	local list = cereal.binary_input(data, {"array", "string"})
	-- The editor's own save comes back here: its rows, not a screen
	-- over it
	if keys_open then
		keys_editor.apply(list)
		return
	end
	draw_settings(list)
end)

-- What the server is doing while the game loads: 220 mods take minutes and
-- a line that says "Creating <name>..." for all of them looks hung. The
-- server names each mod as it loads it; see set_progress_handler() in
-- builtin/luanti/api.h.
buildat.sub_packet("main:progress", function(data)
	if done then
		return
	end
	local line = cereal.binary_input(data, {"array", "string"})[1]
	if line == nil then
		return
	end
	log:verbose("menu: progress " .. line)
	if waiting_text then
		waiting_text:SetText(line)
	else
		waiting(line)
	end
end)

-- News, not an error: the list it changed is asked for again and the
-- line shown over it for a moment
buildat.sub_packet("main:menu_message", function(data)
	if done then
		return
	end
	local message = cereal.binary_input(data, {"array", "string"})[1]
	log:info("menu: " .. tostring(message))
	buildat.send_packet("main:get_saves", "")
	ui_utils.show_notification(tostring(message), 4.0)
end)

buildat.sub_packet("main:menu_error", function(data)
	if done then
		return
	end
	local message = cereal.binary_input(data, {"array", "string"})[1]
	log:warning("menu: " .. tostring(message))
	-- A create that did not happen goes back to the screen it came from
	-- with the name, the seed, the toggles and the mapgen still in it
	-- ([NEW_WORLD_FORM]): a dialog here would close the screen and throw
	-- all of it away
	if creating then
		local state = creating
		creating = nil
		state.error = tostring(message)
		draw_new_save_name(state.gameid, state)
		return
	end
	-- The list is asked for again once the dialog is gone, not while it is
	-- up: the dialog is on top of the menu in the UI stack, and drawing the
	-- menu again takes the menu's own root out from under it
	ui_utils.show_message_dialog(tostring(message), function()
		buildat.send_packet("main:get_saves", "")
	end)
end)

-- The world is up and main/init.lua is what draws from here on
buildat.sub_packet("main:menu_done", function()
	creating = nil
	log:info("menu: done; the world is up")
	done = true
	waiting_text = nil
	close()
end)

buildat.send_packet("main:get_saves", "")
waiting("Looking for saves...")
return M
-- vim: set noet ts=4 sw=4:
