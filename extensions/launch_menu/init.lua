-- Buildat: extension/launch_menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch menu organized by what a player does ([LAUNCH_MENU_V2]):
-- Home is a Continue list of what was last used, the ways in, and one
-- search over every source, results grouped by kind; Browse is one list
-- per kind with a detail panel beside it holding the thing's actions.
-- It took the place of the old grid of tiles ([RETIRE_DEAD], 2026-10-09).
-- Runs in the sandbox; the screens it does not draw itself (the
-- connecting screen, the Engine settings) are screens.lua's here,
-- reached by verb.
--
-- Settings is one tree (Display and sound, Controls, Luanti, Developer),
-- and Controls edits the client's key store (client/api.lua's
-- declare_keys).
-- simplified: no pins and none of the actions that do not exist anywhere
-- yet (the plan's step 4, when someone asks for them).
local api = buildat.safe or buildat
local log = buildat.Logger("extension/launch_menu")
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
local uistack = require("buildat/extension/uistack")
uistack = uistack.main and uistack or uistack.safe
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.bind_button_menu and ui_utils or ui_utils.safe
local HA_LEFT, VA_CENTER, LM_VERTICAL, LM_HORIZONTAL =
		magic.HA_LEFT, magic.VA_CENTER, magic.LM_VERTICAL,
		magic.LM_HORIZONTAL
local KEY_ESCAPE, KEY_BACKSPACE = magic.KEY_ESCAPE, magic.KEY_BACKSPACE
local KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_TAB =
		magic.KEY_LEFT, magic.KEY_RIGHT, magic.KEY_UP, magic.KEY_DOWN,
		magic.KEY_TAB

local M = {safe = nil}

-- In a browser there are no local apps, saves, LAN or Quit: what cannot
-- work there is left out by this one check. "1" is an https page, which
-- reaches a server only through TLS.
local page = api.get_env("BUILDAT_PAGE_HTTPS")
local web = page ~= nil

local CONTINUE_MAX = 10
local SEARCH_MIN = 1
local SEARCH_CAP = 20
local SHORT_CAP = 5
local ROW_HEIGHT = 28
local PANEL_WIDTH = 300
local GAME_RUNNING = "empty (game is running)"

-- The kinds, in the order the results show them
local KINDS = {"app", "save", "server", "catalog", "action"}
local KIND_TITLE = {app = "Apps", save = "Saves", server = "Servers",
		catalog = "Get more", action = "Other"}
local PRIMARY = {app = "Play", save = "Continue", server = "Join",
		catalog = "Open", action = "Open"}
-- Launch actions that are a catalog to get more from, or a server's
-- address typed, rather than what their category says
local CATALOG_KEYS = {["extension/launch_menu/aitta"] = true,
		["app/vanilla/contentdb"] = true,
		["builtin/luanti/import_game"] = true,
		["builtin/luanti/import_world"] = true}
local SERVER_KEYS = {["extension/launch_menu/connect"] = true,
		["extension/luanti_client/connect"] = true,
		["extension/serverlist/refresh"] = true}
-- And the settings screens that are tiles, which the Settings tree has
local SETTINGS_KEYS = {["app/vanilla/settings"] = true,
		["extension/luanti_client/settings"] = true}

-- How well an entry matches what is typed: 2 its label starts with it, 1
-- it is in the label, the badge or the description (a server's address
-- is there), nil not at all
local function match(e, q)
	local at = e.label:lower():find(q, 1, true)
	if at == 1 then return 2 end
	if at or (e.badge or ""):lower():find(q, 1, true) or
			(e.description or ""):lower():find(q, 1, true) then
		return 1
	end
	return nil
end

-- The order of a list: "recent" is the player's own history first (most
-- recent), then the better match, then the label; "name" the label alone
local function sorted(list, by)
	table.sort(list, function(a, b)
		if by ~= "name" then
			local la, lb = a.e.last or 0, b.e.last or 0
			if la ~= lb then return la > lb end
			if a.m ~= b.m then return a.m > b.m end
		end
		return a.e.label:lower() < b.e.label:lower()
	end)
	local out = {}
	for _, x in ipairs(list) do out[#out + 1] = x.e end
	return out
end

-- The search: every entry that matches, grouped by kind in KINDS' order,
-- each group in `by`'s order. Pure, so the check below runs it.
local function search(entries, query, by)
	local q = query:lower()
	local by_kind = {}
	for _, e in ipairs(entries) do
		local m = match(e, q)
		if m then
			local list = by_kind[e.kind] or {}
			by_kind[e.kind] = list
			list[#list + 1] = {e = e, m = m}
		end
	end
	local out = {}
	for _, kind in ipairs(KINDS) do
		if by_kind[kind] then
			local group = sorted(by_kind[kind], by)
			group.kind = kind
			out[#out + 1] = group
		end
	end
	return out
end

-- Continue: what was used, the most recent first, at most n.
-- simplified: recency alone. The launch history keeps one line per key
-- (its last time), so frequency would need a count it does not have.
-- What has something new waiting (a Hearth's notifications) comes first
local function recent(entries, n)
	local used = {}
	for _, e in ipairs(entries) do
		if e.last or e.unseen then used[#used + 1] = e end
	end
	table.sort(used, function(a, b)
		if (a.unseen ~= nil) ~= (b.unseen ~= nil) then
			return a.unseen ~= nil
		end
		return (a.last or 0) > (b.last or 0)
	end)
	local out = {}
	for i = 1, math.min(n, #used) do out[i] = used[i] end
	return out
end

-- **The Servers list's filters** ([SERVER_FILTER]): All, the ones joined
-- before, then one per list the servers came from and one per network,
-- out of what the entries say rather than a fixed set, so an app's own
-- server tiles bring their own. In the user's order ([BROWSE_TWEAKS]);
-- any other after those, by name.
local FILTER_ORDER = {"Starport", "Luanti server list", "LAN", "Buildat",
	"Luanti"}
local function server_filters(list)
	-- This menu's own two lists are offered when they are empty too
	local seen = {Starport = true, LAN = not web or nil}
	for _, e in ipairs(list) do
		if e.listed_by then seen[e.listed_by] = true end
		if e.network then seen[e.network] = true end
	end
	local out, rest = {"All", "Previously connected"}, {}
	for _, f in ipairs(FILTER_ORDER) do
		if seen[f] then
			out[#out + 1] = f
			seen[f] = nil
		end
	end
	for f in pairs(seen) do rest[#rest + 1] = f end
	table.sort(rest)
	for _, f in ipairs(rest) do out[#out + 1] = f end
	return out
end
assert(table.concat(server_filters({{listed_by = "Zed", network = "Luanti"},
		{listed_by = "Luanti server list", network = "Buildat"},
		{listed_by = "Abc"}, {network = "Mine"}}), ",") == (web and
		"All,Previously connected,Starport,Luanti server list,Buildat,Luanti,Abc,Mine,Zed" or
		"All,Previously connected,Starport,Luanti server list,LAN,Buildat,Luanti,Abc,Mine,Zed"),
		"server_filters: the user's order, then by name")

local function passes(e, filter)
	if filter == "All" then return true end
	if filter == "Previously connected" then return e.last ~= nil end
	return e.listed_by == filter or e.network == filter
end

-- "3 h ago": when a thing was last used, for the panel
local function ago(t, now)
	local d = math.max(0, now - t)
	if d < 60 then return "just now" end
	if d < 3600 then return math.floor(d / 60) .. " min ago" end
	if d < 86400 then return math.floor(d / 3600) .. " h ago" end
	return math.floor(d / 86400) .. " days ago"
end

do
	local es = {
		{label = "Floor planner", kind = "app", last = 5},
		{label = "Fleet", kind = "server", badge = "Luanti"},
		{label = "flat", kind = "save", badge = "Floor planner", last = 9},
		{label = "A floor mat", kind = "app"},
		{label = "Engine settings", kind = "action"},
		{label = "Hearth of Oak", kind = "server", badge = "Buildat",
			description = "hearth.example:20000   3 playing"},
	}
	local r = search(es, "FL")
	assert(#r == 3 and r[1].kind == "app" and r[2].kind == "save" and
			r[3].kind == "server", "search: grouped by kind, in order")
	assert(r[1][1].label == "Floor planner" and r[1][2].label ==
			"A floor mat", "search: used first, then the match")
	r = search(es, "fl", "name")
	assert(r[1][1].label == "A floor mat", "search: by name")
	r = search(es, "planner")
	assert(#r == 2 and r[2][1].label == "flat", "search: badges match")
	r = search(es, "oak")
	assert(#r == 1 and r[1][1].label == "Hearth of Oak",
			"search: a server by a word of its name")
	r = search(es, "hearth.example")
	assert(#r == 1 and r[1][1].label == "Hearth of Oak",
			"search: a server by its address, in the description")
	assert(#search(es, "zz") == 0, "search: nothing")
	r = recent(es, 1)
	assert(#r == 1 and r[1].label == "flat", "recent: newest first")
	assert(ago(100, 100) == "just now" and ago(0, 7200) == "2 h ago" and
			ago(0, 3 * 86400) == "3 days ago", "ago")
end

-- **Notifications waiting** ([FORUM] 4): address -> count, from each
-- Buildat server this client keeps a login for (a Hearth answers),
-- asked at most once a minute
local unseen = {}
local unseen_asked = nil
local starport_fetched = false
-- Set when an app, save or server is run from here: a game's own way
-- out (luanti_client's leave) pops its screens without leave_app, so
-- Home comes back on top as drawn before it, and is drawn again then
local stale = false

-- Every source, as entries of one shape: {label, kind, badge,
-- description, last (unix s or nil), size, actions = {{label, run}}};
-- run is the first action's
local function gather()
	local entries = {}
	local function add(e)
		e.actions = e.actions or {}
		local run = e.run
		if e.kind ~= "action" then
			e.run = function() stale = true run() end
		end
		table.insert(e.actions, 1, {label = PRIMARY[e.kind], run = e.run})
		-- A server with no icon of its own ([GLYPH_ICONS])
		if e.kind == "server" and not e.icon then
			e.glyph = "🌐"
		end
		entries[#entries + 1] = e
		return e
	end
	local function warn_if(ok, why)
		if not ok then log:warning(tostring(why)) end
	end
	add({label = "Display and sound", kind = "action", badge = "Settings",
		icon = "launch_menu/res/icon_preferences.png",
		section = "Display and sound",
		description = "What every app honours: the window, the sound, " ..
				"the mouse, and which launch UI this is.",
		run = function() api.show_engine_settings() end})
	local console = require("buildat/extension/launch_console")
	console = console and (console.show and console or console.safe)
	if console and console.show then
		add({label = "Developer console", kind = "action",
			icon = "launch_menu/res/icon_console.png",
			badge = "Developer", section = "Developer",
			description = "A Lua console in the sandbox, with the API " ..
					"document beside it.",
			run = function() console.show(function() end) end})
	end
	-- [AITTA_PUBLISH_UI]: the trusted side's screen, which a page has not
	local starport = require("buildat/extension/starport")
	starport = starport and (starport.open_publish and starport or
			starport.safe)
	if not web and starport and starport.open_publish then
		add({label = "Publish an app or extension", kind = "action",
			icon = "launch_menu/res/icon_local.png",
			badge = "Developer", section = "Developer",
			description = "Make one in your user folder, try it, then " ..
					"pack, sign and publish it on an Aitta.",
			run = function() starport.open_publish() end})
	end
	-- The launch actions: apps, Luanti games, the server list, catalogs,
	-- tools. An app's other actions (vanilla's settings, an installed
	-- release's feedback) are its panel's as well as their own entries.
	local app_label = {vanilla = "Luanti"}
	local by_from = {}
	local actions = api.launch_actions()
	-- And an app's icon, for its saves: the first of its actions'
	local icon_of = {}
	for _, a in ipairs(actions) do
		local app = a.from:match("^app/(.+)$")
		if app and not app_label[app] then app_label[app] = a.label end
		icon_of[a.from] = icon_of[a.from] or a.icon
	end
	for _, a in ipairs(actions) do
		-- Locally started things need a local server, which a page has not.
		-- Apps from Aitta stays: it lists the serverless ones there
		-- ([AITTA_ON_WEB])
		if not (web and (a.kind ~= "extension" or
				a.key == "extension/launch_menu/local")) and
				-- Its lists are this menu's Apps and Servers
				a.key ~= "extension/launch_menu/local" then
			local cat = a.category or "action"
			local kind = CATALOG_KEYS[a.key] and "catalog" or
					SERVER_KEYS[a.key] and "server" or
					SETTINGS_KEYS[a.key] and "action" or
					(cat == "app" or cat == "game") and "app" or
					cat == "server" and "server" or "action"
			-- A server's network and list are its own to say
			-- ([SERVER_FILTER]); one that says none is Buildat's
			local network = kind == "server" and (a.network or "Buildat") or
					nil
			local badge = kind == "server" and network ..
					(a.listed_by and ", " .. a.listed_by or "") or
					cat == "game" and "Luanti" or
					a.kind == "installed" and "Aitta" or
					a.kind == "review" and "Playtest" or
					a.kind == "dev" and "Dev" or nil
			local e = add({label = a.label, kind = kind,
				network = network, listed_by = a.listed_by,
				badge = SETTINGS_KEYS[a.key] and "Settings" or badge,
				section = SETTINGS_KEYS[a.key] and "Luanti", key = a.key,
				from = a.from, icon = a.icon,
				id = a.from .. "/" .. tostring(a.id),
				size = kind == "app" and a.kind ~= "builtin" and
						a.significance or nil,
				description = a.description, last = a.last_launched,
				run = function() warn_if(api.launch(a.key)) end})
			if kind == "app" then
				by_from[a.from] = by_from[a.from] or e
			else
				e.sibling_of = a.from
			end
		end
	end
	for _, e in ipairs(entries) do
		local app = e.sibling_of and by_from[e.sibling_of]
		if app then
			app.actions[#app.actions + 1] = {label = e.label, run = e.run}
		end
	end
	if not web then
		-- The saves straight into their world; when one was last played
		-- is when it was launched or its file written, the later
		for _, sv in ipairs(api.list_saves()) do
			local parent = app_label[sv.app] or sv.app
			local last = math.max(sv.last_launched or 0, sv.modified and
					math.floor(sv.modified / 1000000) or 0)
			add({label = sv.name, kind = "save", badge = parent,
				icon = icon_of["app/" .. sv.app],
				description = "Continue this save of " .. parent .. ".",
				last = last > 0 and last or nil,
				run = function()
					warn_if(api.launch_save(sv.app, sv.name))
				end})
		end
		-- simplified: the LAN as heard at boot; the list is not polled
		for _, s in ipairs(api.lan_servers()) do
			local address = s.host .. ":" .. s.port
			add({label = s.name ~= "" and s.name or address,
				kind = "server", badge = "Buildat, LAN",
				network = "Buildat", listed_by = "LAN",
				description = address .. "   " .. tostring(s.app) .. ", " ..
						tostring(s.players) .. " playing",
				run = function() api.join_server(address) end})
		end
	end
	-- The Buildat servers this client has joined, last joined first; a
	-- Luanti one (udp) is luanti_client's tile, which is used when this
	-- was, though its dialog rather than the tile was the way in
	local by_key = {}
	for _, e in ipairs(entries) do
		if e.key then by_key[e.key] = e end
	end
	local known = {}
	-- Starport's public list as last fetched (the connect screen fetches
	-- it again): a joined server whose kept name is empty takes its name
	-- from there ([SEARCH_SERVER_NAMES]), and the rest are added below
	-- simplified: the kept list, not a fetch of this menu's own
	local starport = require("buildat/extension/starport")
	starport = starport and (starport.kept_rows and starport or
			starport.safe)
	local rows = starport and starport.kept_rows() or {}
	local listed_name = {}
	for _, row in ipairs(rows) do
		listed_name[tostring(row.address)] = tostring(row.name)
	end
	local net = require("buildat/extension/network")
	net = net.known_addresses and net or net.safe
	for _, a in ipairs(net.known_addresses()) do
		local host, port = a.uri:match("^%a+://(.-):(%d+)$")
		local tile = a.uri:sub(1, 6) == "udp://" and
				by_key["extension/luanti_client/s_" ..
					(host .. ":" .. tostring(port)):gsub("[^%w%.%-]", "_")]
		if tile and a.last_attempt > (tile.last or 0) then
			tile.last = a.last_attempt
		end
		-- One behind TLS is joined by its https address, which is also
		-- what Starport's row for it is ([JOINED_TLS_SERVERS])
		local tls = a.uri:sub(1, 8) == "https://"
		if host and a.accepted and (tls or a.uri:sub(1, 6) == "tcp://") then
			local address = (tls and "https://" or "") .. host .. ":" .. port
			known[address] = true
			add({label = a.name ~= "" and a.name or
					listed_name[address] or address,
				kind = "server", unseen = unseen[address],
				network = "Buildat",
				badge = unseen[address] and "Buildat, " .. unseen[address] ..
						" new" or "Buildat",
				description = address .. (a.description ~= "" and
						"   " .. a.description or ""),
				last = a.last_attempt > 0 and a.last_attempt or nil,
				run = function() api.join_server(address) end})
		end
	end
	-- And the Starport's servers not joined; on an https page only those
	-- behind TLS
	for _, row in ipairs(rows) do
		local address = tostring(row.address)
		if not known[address] and not (page == "1" and not row.tls) then
			add({label = tostring(row.name), kind = "server",
				badge = "Buildat, Starport",
				network = "Buildat", listed_by = "Starport",
				description = address .. "   " ..
						tostring(row.players or 0) .. " playing",
				run = function() api.join_server(address) end})
		end
	end
	return entries
end

-- The character a key types into the search, or nil: key codes are SDL's,
-- which are the lower case ASCII of what the key says
local entries = nil
-- What runs on the next frame rather than inside the event that asked
-- for it: a screen popped inside its own dropdown's ItemSelected stayed
-- drawn under the next one
local deferred = nil

-- c: a colour's name, ui_utils.rgb's
local function text(parent, s, size, c)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t.text = s
	if size then t:SetFontSize(size) end
	if c then t.color = magic.Color(ui_utils.rgb(c)) end
	return t
end

-- A screen: a window on a stack root, a version line, and the line that
-- says what is typed. The caller adds the rest.
local function screen(desc, width, heading, query)
	local root = uistack.main:push({desc = desc})
	root.defaultStyle = magic.cache:GetResource("XMLFile",
			"launch_menu/res/main_style.xml")
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 8, magic.IntRect(16, 12, 16, 12))
	window:SetAlignment(HA_LEFT, VA_CENTER)
	window:SetFixedWidth(width)
	local version, hash = api.version()
	text(window, "Buildat " .. version .. " " .. hash, 11, "dim")
	text(window, query == "" and heading or "Search: " .. query .. "_", 20,
			query == "" and "dim" or "text")
	-- The ×, but on the first screen, which has nothing under it
	-- ([2], not #: a sandbox's read-only view has no # on Lua 5.1)
	if uistack.main.stack[2] ~= nil then
		ui_utils.close_glyph(root, window)
	end
	return root, window
end

-- The keys a typed search takes besides its characters: Backspace, and
-- Escape to clear. Answers the new query, or nil for a key that is not
-- the search's.
local function search_key(key, query)
	-- simplified: on the web SDL's text input is off unless a text field
	-- has the focus (app.cpp, [WEB_KEYS]), so no TextInput comes and the
	-- character is the key code's, as it was: a-z, 0-9, space, "-" and
	-- "."; no shift, no layout. A hidden field taking the text would lift
	-- it.
	if web and magic.input:GetKeyPress(key) and ((key >= 97 and key <= 122) or
			(key >= 48 and key <= 57) or key == 45 or key == 46 or
			(key == 32 and query ~= "")) then
		return query .. string.char(key)
	end
	if key == KEY_BACKSPACE and query ~= "" then
		return query:sub(1, -2)
	elseif key == KEY_ESCAPE and query ~= "" then
		return ""
	end
	return nil
end

-- **The characters come from TextInput** ([V2_TYPING]): the layout and
-- shift make them, so "_" is Shift+"-" on a Finnish keyboard; KeyDown's
-- key code knew neither. A space only once something is typed: before
-- that Space is the selected row's, after it only Enter runs one
-- (spaced()). go(query) draws the screen again.
local function on_typed(root, query, go)
	root:SubscribeToStackEvent("TextInput", function(_, data)
		local focus = magic.ui.focusElement
		if focus and focus:GetTypeName() == "LineEdit" then return end
		if magic.input:GetQualifierDown(magic.QUAL_CTRL) then return end
		local t = data:GetString("Text")
		if t == "" or (t == " " and query == "") then return end
		uistack.main:pop(root)
		go(query .. t)
	end)
end

-- Whether a row's press is Space typed into a search, which is not a
-- press: a focused Button presses itself on Space (Urho3D's OnKey)
local function spaced(query)
	return query ~= "" and magic.input:GetKeyDown(magic.KEY_SPACE)
end

local browse, settings

local function home(query)
	local t0 = api.get_time_us()
	local width = math.min(magic.ui.root.width - 40, 760)
	-- Short on a narrow screen, where the long one stretched the window
	-- ([BROWSE_TWEAKS]; simplified: by the screen's width, not the text's)
	local root, window = screen("launch_menu", width,
			magic.ui.root.width < 760 and "Type to search" or
			"Type to search apps, saves and servers", query)
	local view = ui_utils.list_view(window, width - 32,
			magic.ui.root.height - 24 - 160)
	local items = {}
	local function row(e, badge, run)
		items[#items + 1] = {button = view:row(e, badge), entry = e,
			action = function()
				if spaced(query) then return end
				log:info("launch_menu: " .. e.kind .. " " .. e.label)
				run()
			end}
	end
	if #query < SEARCH_MIN then
		local cont = recent(entries, CONTINUE_MAX)
		if #cont > 0 then
			view:header("Continue")
			for _, e in ipairs(cont) do row(e, nil, e.run) end
		end
		-- The ways in: one list per kind
		view:header("Browse")
		for _, kind in ipairs({"app", "save", "server", "catalog"}) do
			local n = 0
			for _, e in ipairs(entries) do
				if e.kind == kind then n = n + 1 end
			end
			if n > 0 then
				row({label = KIND_TITLE[kind], kind = "browse",
					glyph = kind == "server" and "🌐" or nil,
					description = n .. " to choose from"}, tostring(n),
					function() browse(kind, "", "recent") end)
			end
		end
		view:header("Menu")
		row({label = "Settings", kind = "settings", description =
				"Display and sound, the keys, Luanti's, the developer's."},
				nil, function() settings() end)
	else
		-- At most SEARCH_CAP a kind, the best first; Browse has the rest.
		-- One character matches nearly everything, and a row is ~0.6 ms
		-- to make: a screenful then, SHORT_CAP a kind ([FRAME_WORK]: 68
		-- rows were 41 ms a keypress)
		local cap = #query < 2 and SHORT_CAP or SEARCH_CAP
		for _, group in ipairs(search(entries, query)) do
			view:header(KIND_TITLE[group.kind] .. (#group > cap and
					", " .. cap .. " of " .. #group or ""))
			for i = 1, math.min(#group, cap) do
				local e = group[i]
				row(e, nil, e.run)
			end
		end
		if #items == 0 then
			text(view.list, "Nothing matches \"" .. query ..
					"\" (Backspace, Escape)", nil, "dim")
		end
	end
	view:fit()

	-- The selection's description, under the list
	local desc = text(window, "", 13, "dim")
	desc:SetWordwrap(true)
	desc:SetFixedWidth(width - 32)
	desc:SetFixedHeight(40)

	local nav = ui_utils.bind_button_menu(root, items, function(key)
		local q = search_key(key, query)
		if q then
			uistack.main:pop(root)
			home(q)
			return true
		end
		if key == KEY_ESCAPE then
			-- On the web Escape on Home does nothing: the page is the
			-- launcher, and a browser tab has its own close
			if not web then
				ui_utils.show_confirm_dialog("Quit Buildat?",
						function() api.quit() end, nil, "Quit", nil,
						{yes_focused = true, yes_key = magic.KEY_Q})
			end
			return true
		end
	end)
	on_typed(root, query, home)
	nav:on_change(function(button, selected, index)
		local item = index and items[index]
		if not (selected and item) then return end
		local e = item.entry
		desc.text = (e.badge and e.badge .. ": " or "") ..
				(e.description or "")
		view:show(button)
	end)
	log:info("launch_menu: " .. #items .. " rows" ..
			(query ~= "" and " for \"" .. query .. "\"" or "") .. " in " ..
			math.floor((api.get_time_us() - t0) / 1000) .. " ms" ..
			(items[1] and items[1].entry and
				", first " .. tostring(items[1].entry.label) or ""))
end

-- One kind's list, searchable and sorted, with the selection's detail
-- panel beside it: Enter or a double-click runs the primary action, Right
-- or Tab moves into the panel's actions, Left or Escape back. On a narrow
-- screen the panel is under the list.
-- simplified: one scrolled list rather than pages; hundreds of rows are
-- hundreds of buttons, which is fine at this size.
browse = function(kind, query, by, filter, focus_filter)
	filter = filter or "All"
	local narrow = magic.ui.root.width < 760
	local width = math.min(magic.ui.root.width - 40, 1000)
	local list_w = narrow and width - 32 or width - 32 - PANEL_WIDTH - 12
	local root, window = screen("launch_menu " .. kind, width,
			narrow and KIND_TITLE[kind] .. " (type to search)" or
			KIND_TITLE[kind] .. "   (type to search; Ctrl+S sorts by " ..
			(by == "name" and "recent use" or "name") ..
			(kind == "server" and "; Ctrl+F filters" or "") .. ")", query)
	local of_kind = {}
	for _, e in ipairs(entries) do
		if e.kind == kind then of_kind[#of_kind + 1] = e end
	end
	local filters = kind == "server" and server_filters(of_kind) or nil
	if filters then
		log:info("launch_menu: filters " .. table.concat(filters, ", "))
	end
	local function refilter(f, focus_filter)
		uistack.main:pop(root)
		browse(kind, query, by, f, focus_filter)
	end
	local drop = nil
	if filters then
		drop = ui_utils.dropdown(window, filters, filter, function(f)
			deferred = function() refilter(f, true) end
		end, {width = 240, height = ROW_HEIGHT})
		local kept = {}
		for _, e in ipairs(of_kind) do
			if passes(e, filter) then kept[#kept + 1] = e end
		end
		of_kind = kept
	end
	local body = window:CreateChild("UIElement")
	body:SetLayout(narrow and LM_VERTICAL or LM_HORIZONTAL, 12,
			magic.IntRect(0, 0, 0, 0))
	local room = magic.ui.root.height - 24 - 120 - (narrow and 200 or 0)
	local view = ui_utils.list_view(body, list_w, room)
	local panel = body:CreateChild("UIElement")
	panel:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	panel:SetFixedWidth(narrow and width - 32 or PANEL_WIDTH)
	-- A height that holds any entry's panel, so the window, which is
	-- centred, does not move the rows under the mouse as the panel changes
	-- simplified: a description longer than five lines still grows it
	panel.minHeight = math.min(room, 220)

	local shown = search(of_kind, #query < SEARCH_MIN and "" or query,
			by)[1] or {}
	-- The LAN's servers first, whatever the order: they answered just now
	-- (user, 2026-10-06)
	if kind == "server" then
		local lan, rest = {}, {}
		for _, e in ipairs(shown) do
			table.insert(e.listed_by == "LAN" and lan or rest, e)
		end
		for _, e in ipairs(rest) do lan[#lan + 1] = e end
		shown = lan
	end
	local items = {}
	local action_buttons = {}
	local current = nil
	-- **A clicked row is locked** (user, 2026-10-06): amber, and the
	-- panel is its while the mouse crosses other rows on the way to the
	-- panel's buttons. Another click locks another; an arrow key lets go,
	-- and the panel follows the selection again.
	local locked = nil
	local lock
	local last_click = {}
	for _, e in ipairs(shown) do
		local item = {entry = e}
		item.button = view:row(e)
		-- Enter runs it; a click locks it and a second one runs it
		item.action = function()
			if spaced(query) then return end
			local t = api.get_time_us()
			local enter = magic.input:GetKeyDown(magic.KEY_RETURN) or
					magic.input:GetKeyDown(magic.KEY_KP_ENTER)
			if enter or (last_click[e] and t - last_click[e] < 500000) then
				log:info("launch_menu: " .. e.kind .. " " .. e.label)
				e.run()
			elseif not enter then
				lock(item)
			end
			last_click[e] = t
		end
		items[#items + 1] = item
	end
	if #items == 0 then
		text(view.list, query == "" and "Nothing here yet" or
				"Nothing matches \"" .. query .. "\" (Backspace, Escape)",
				nil, "dim")
	end
	view:fit()

	local now = os.time()
	local function fill(e)
		panel:RemoveAllChildren()
		action_buttons = {}
		text(panel, e.label, 18)
		text(panel, KIND_TITLE[kind] .. (e.badge and ", " .. e.badge or ""),
				12, "dim")
		if e.description and e.description ~= "" then
			local d = text(panel, e.description, 13, "dim")
			d:SetWordwrap(true)
			d:SetFixedWidth(narrow and width - 32 or PANEL_WIDTH)
		end
		if e.size then
			text(panel, string.format("Size: %.1f MB", e.size / 1048576),
					12, "dim")
		end
		text(panel, e.last and "Last used " .. ago(e.last, now) or
				"Not used yet", 12, "dim")
		for i, a in ipairs(e.actions) do
			local b = panel:CreateChild("Button")
			-- The first is the thing's own: Play, Continue, Join
			if i == 1 then b:SetStyle("PrimaryButton") else b:SetStyleAuto() end
			b:SetLayout(LM_VERTICAL, 0, magic.IntRect(10, 3, 10, 3))
			b:SetFixedHeight(ROW_HEIGHT)
			b:SetFocusMode(magic.FM_FOCUSABLE)
			local t = text(b, a.label)
			t:SetName("ButtonText")
			magic.SubscribeToEvent(b, "Released", function()
				log:info("launch_menu: " .. a.label .. " on " .. e.label)
				a.run()
			end)
			action_buttons[#action_buttons + 1] = b
		end
	end
	-- The locked row's label in the main button's amber. Not the
	-- PrimaryButton style: a style brings a size of its own, and the rows
	-- then overlapped
	local function amber(item, on)
		local label = item.button:GetChild("ButtonText")
		if label then
			label.color = magic.Color(ui_utils.rgb(on and "main" or "text"))
		end
	end
	lock = function(item)
		if item == locked then return end
		if locked then amber(locked, false) end
		locked = item
		if item then amber(item, true) end
		log:info("launch_menu: " .. (item and "locked " .. item.entry.label
				or "unlocked"))
		local subject = item or current
		if subject then fill(subject.entry) end
	end
	local function in_actions()
		for i, b in ipairs(action_buttons) do
			if b:HasFocus() then return i end
		end
		return nil
	end

	local nav = ui_utils.bind_button_menu(root, items, function(key)
		-- [V2_FILTER_KEYS]: the filter above the list, Up from its first
		-- row; Left and Right step it, Down goes back to the list
		if drop and drop:HasFocus() then
			if key == KEY_LEFT or key == KEY_RIGHT then
				local i = 1
				for j, f in ipairs(filters) do
					if f == filter then i = j end
				end
				refilter(filters[(i - 1 + (key == KEY_RIGHT and 1 or -1)) %
						#filters + 1], true)
				return true
			elseif key == KEY_DOWN then
				if items[1] then items[1].button:SetFocus(true) end
				return true
			elseif key == KEY_UP then
				return true
			end
		elseif drop and key == KEY_UP and items[1] and
				items[1].button:HasFocus() then
			drop:SetFocus(true)
			return true
		end
		local i = in_actions()
		-- Shift+Tab is Left, and Tab in the panel Down, as in a form
		-- ([BROWSE_TWEAKS])
		if key == KEY_TAB then
			if magic.input:GetQualifierDown(magic.QUAL_SHIFT) then
				key = KEY_LEFT
			elseif i then
				key = KEY_DOWN
			end
		end
		if i then
			-- In the panel: up and down between its actions, Left or
			-- Escape back to the row it is the panel of
			if key == KEY_UP or key == KEY_DOWN then
				local n = #action_buttons
				local j = (i - 1 + (key == KEY_DOWN and 1 or -1)) % n + 1
				action_buttons[j]:SetFocus(true)
				return true
			elseif key == KEY_LEFT or key == KEY_ESCAPE then
				local back = locked or current
				if back then back.button:SetFocus(true) end
				return true
			end
			return key == KEY_RIGHT or key == KEY_TAB
		end
		if (key == KEY_RIGHT or key == KEY_TAB) and action_buttons[1] then
			action_buttons[1]:SetFocus(true)
			return true
		end
		if key == KEY_LEFT then return true end
		if key == KEY_UP or key == KEY_DOWN or key == magic.KEY_PAGEUP or
				key == magic.KEY_PAGEDOWN then
			lock(nil)
		end
		if key == magic.KEY_S and
				magic.input:GetQualifierDown(magic.QUAL_CTRL) then
			uistack.main:pop(root)
			browse(kind, query, by == "name" and "recent" or "name", filter)
			return true
		end
		local q = search_key(key, query)
		if q then
			uistack.main:pop(root)
			browse(kind, q, by, filter)
			return true
		end
		if filters and key == magic.KEY_F and
				magic.input:GetQualifierDown(magic.QUAL_CTRL) then
			local i = 1
			for j, f in ipairs(filters) do
				if f == filter then i = j end
			end
			refilter(filters[i % #filters + 1])
			return true
		end
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end)
	on_typed(root, query, function(q) browse(kind, q, by, filter) end)
	nav:on_change(function(button, selected, index)
		local item = index and items[index]
		if not (selected and item) or item == current then return end
		current = item
		if not locked then fill(item.entry) end
		view:show(button)
	end)
	if focus_filter and drop then
		drop:SetFocus(true)
	end
	log:info("launch_menu: " .. kind .. ", " .. #items .. " rows" ..
			(query ~= "" and " for \"" .. query .. "\"" or "") ..
			", by " .. by .. (filters and ", " .. filter or ""))
end

-- **Logs and errors** ([LOG_REACH]): where the log is, and the caught
-- errors in full for a report -- a tester's Lua error could not be copied
-- off the red line, and the log is in a hidden folder
local function logs()
	local width = math.min(magic.ui.root.width - 40, 760)
	local root, window = screen("launch_menu logs", width,
			"Logs and errors", "")
	local path = api.log_path() or ""
	local where = text(window, path ~= "" and "The log: " .. path or
			"No log file here: the browser's console (F12) has it.", 14)
	where:SetWordwrap(true)
	where:SetFixedWidth(width - 32)
	local view = ui_utils.list_view(window, width - 32, 200)
	local status = text(window, "", 13, "dim")
	local items = {}
	local function row(e, run)
		items[#items + 1] = {button = view:row(e), action = function()
			local ok, why = run()
			status.text = ok and ok ~= true and ok or (ok and "Done" or
					tostring(why))
		end}
	end
	if path ~= "" then
		row({label = "Copy the path", glyph = "□"}, function()
			ui_utils.copy(path)
			return "The path is on the clipboard"
		end)
		if not web then
			row({label = "Open the log folder", glyph = "▶"}, function()
				local ok, why = api.open_log_folder()
				return ok and "Opened" or nil, why
			end)
		end
	end
	row({label = "Copy the last errors", glyph = "□"}, function()
		ui_utils.copy(api.recent_errors() or "")
		return "The last errors, with the version, are on the clipboard"
	end)
	view:fit()
	ui_utils.bind_button_menu(root, items, function(key)
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end)
end

-- **Settings**, one tree: each part once. The Keys screen is
-- preferences.lua's (api.show_key_settings), the game settings window's
-- keys page being the same.
settings = function()
	local width = math.min(magic.ui.root.width - 40, 760)
	local root, window = screen("launch_menu settings", width,
			"Settings", "")
	local view = ui_utils.list_view(window, width - 32,
			magic.ui.root.height - 200)
	local items = {}
	local function row(e, run)
		items[#items + 1] = {button = view:row(e), entry = e, action = run}
	end
	local by_section = {}
	for _, e in ipairs(entries) do
		if e.section then
			by_section[e.section] = by_section[e.section] or {}
			table.insert(by_section[e.section], e)
		end
	end
	for _, section in ipairs({"Display and sound", "Controls", "Luanti",
			"Logs and errors", "Developer"}) do
		if section == "Logs and errors" then
			view:header(section)
			row({label = "Logs and errors", glyph = "⌗", description =
					"Where the log is, and the errors caught since the " ..
					"client started, to copy into a report."}, logs)
		elseif section == "Controls" then
			view:header(section)
			row({label = "Keys", glyph = "⌨", description = "Every app's keys, the " ..
					"shared ones that bind them all at once, and the " ..
					"client's own."}, function() api.show_key_settings() end)
		elseif by_section[section] then
			view:header(section)
			for _, e in ipairs(by_section[section]) do row(e, e.run) end
		end
	end
	view:fit()
	local desc = text(window, "", 13, "dim")
	desc:SetWordwrap(true)
	desc:SetFixedWidth(width - 32)
	desc:SetFixedHeight(40)
	local nav = ui_utils.bind_button_menu(root, items, function(key)
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end)
	nav:on_change(function(button, selected, index)
		local item = index and items[index]
		if selected and item then
			desc.text = item.entry.description or ""
		end
	end)
end

-- launch_action is -a's kind/name/id, run over Home as picking it would
function M.boot(launch_action)
	stale = false
	entries = gather()
	home("")
	local net = require("buildat/extension/network")
	net = net.unseen_counts and net or net.safe
	local t = os.time()
	if not web and net.unseen_counts and
			(unseen_asked == nil or t - unseen_asked >= 60) then
		unseen_asked = t
		net.unseen_counts(function(address, n)
			local was = unseen[address]
			unseen[address] = n > 0 and n or nil
			log:info("launch_menu: " .. address .. " has " .. n .. " new")
			-- Home drawn again with the mark, if it is what is shown
			local top = uistack.main:top()
			if was ~= unseen[address] and top and
					top:GetName():find(": launch_menu$") then
				M.refresh()
			end
		end)
	end
	-- Starport's list fetched once a run, as the Servers screen does: a
	-- server listed since the last fetch is in no other source
	-- ([JOINED_TLS_SERVERS]). Only the Starports already accepted are
	-- asked; Home is drawn again if the list changed and Home is shown.
	if not starport_fetched then
		starport_fetched = true
		local sp = require("buildat/extension/starport")
		sp = sp and (sp.fetch and sp or sp.safe)
		if sp and sp.fetch and sp.kept_rows then
			local function said(rows)
				local t = {}
				for _, r in ipairs(rows) do
					t[#t + 1] = tostring(r.address) .. " " .. tostring(r.name)
				end
				return table.concat(t, "\n")
			end
			local before = said(sp.kept_rows())
			sp.fetch(function()
				local top = uistack.main:top()
				if said(sp.kept_rows()) ~= before and top and
						top:GetName():find(": launch_menu$") then
					M.refresh()
				end
			end)
		end
	end
	local fell_back = api.launch_ui_fell_back and api.launch_ui_fell_back()
	if fell_back then
		ui_utils.show_message_dialog("The launch UI \"" .. fell_back ..
				"\" did not load, so this is the menu.\n\n" ..
				"The log has the error.")
	end
	-- [WIN_MINIDUMP]: the last crash's dump, once
	local dump = api.crash_dump_untold and api.crash_dump_untold()
	if dump then
		ui_utils.show_message_dialog("Buildat crashed last time and left " ..
				"a crash dump:\n\n" .. dump .. "\n\nTo report it, attach " ..
				"that file and the log beside it.")
	end
	if launch_action then
		launch_action = launch_action:gsub("^game/", "app/")
		for _, e in ipairs(entries) do
			if e.key == launch_action or e.id == launch_action then
				log:info("Launch action: " .. launch_action)
				e.run()
				return
			end
		end
		log:warning("Launch action " .. launch_action .. " is not here")
	end
end

-- What the client asks a launch UI for: see launch_menu/init.lua's own,
-- which these are
function M.app_loading(what)
	log:info("launch_menu: the app is loading a " .. tostring(what))
end

function M.in_app()
	for _, e in ipairs(uistack.main.stack) do
		local ok, name = pcall(function() return e:GetName() end)
		if ok and name and name:find(GAME_RUNNING, 1, true) then
			return true
		end
	end
	return false
end

function M.show_dead_server(title, on_close)
	local path, tail = api.local_server_log_tail(20)
	ui_utils.show_message_dialog(title .. "\n\n" .. tail ..
			"\nThe full log is at " .. path, on_close)
end

local function to_home()
	if uistack.main.stack[1] then
		pcall(function()
			uistack.main:pop_to(uistack.main.stack[1], true)
		end)
	end
	M.boot()
end

-- Drawn again, as at boot: what it lists has changed under it
M.refresh = to_home

-- [CMD_EVENT] `event join <address>`: a scripted run joins as the Join
-- screen would, with the launcher under the game (apps/aitta/review_check.sh)
magic.SubscribeToEvent("command_seq:join", function(event_type, event_data)
	api.join_server(event_data:GetString("Param"))
end)

magic.SubscribeToEvent("Update", function()
	if deferred then
		local f = deferred
		deferred = nil
		f()
	end
	if not stale then return end
	local top = uistack.main:top()
	if top and top:GetName():find(": launch_menu$") then
		log:info("launch_menu: back on Home, drawn again")
		M.refresh()
	end
end)

function M.leave_app()
	if not M.in_app() and not api.local_server_running() then
		return false
	end
	-- The stack comes down before the sweep: the screens over Home are
	-- the app's own, and leave_to_menu takes their elements with it
	if uistack.main.stack[1] then
		pcall(function()
			uistack.main:pop_to(uistack.main.stack[1], true)
		end)
	end
	api.leave_to_menu()
	magic.input:SetMouseVisible(true, "back to the launcher")
	M.boot()
	log:info("launch_menu: back to Home")
	return true
end

return M
-- vim: set noet ts=4 sw=4:
