-- Buildat: extension/launch_menu/screens.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The screens a game is started through: the local game list, connecting
-- to a server, a local server stopping and starting, and one that died.
-- Every launch UI's game starts end here -- client/launch_grid.lua runs
-- this file for a tile's or a save's launch -- so it runs in the sandbox
-- and reaches the server through the safe API's verbs only. It keeps no
-- state: whether a game runs is the stack's placeholder, so any number
-- of copies of this file agree.
local api = buildat.safe or buildat
local log = buildat.Logger("extension/launch_menu/screens")
local urho3d = require("buildat/core/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
local uistack = require("buildat/core/uistack")
uistack = uistack.main and uistack or uistack.safe
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.bind_button_menu and ui_utils or ui_utils.safe
local network = require("buildat/core/network")
network = network.safe or network
local starport = require("buildat/core/starport")
starport = starport.safe or starport
local HA_CENTER, HA_LEFT, HA_RIGHT, KEY_ESCAPE, LM_HORIZONTAL, LM_VERTICAL, VA_CENTER =
		magic.HA_CENTER, magic.HA_LEFT, magic.HA_RIGHT, magic.KEY_ESCAPE, magic.LM_HORIZONTAL, magic.LM_VERTICAL, magic.VA_CENTER
local STYLE = "ui_utils/res/style.xml"
-- The stack's placeholder while a game runs; uistack's scan stands aside
-- for a top of this name
local GAME_RUNNING = "empty (game is running)"
local M = {}

local function show_error(message)
	ui_utils.show_message_dialog(message)
end

local format_bytes = ui_utils.format_bytes

local MENU_BUTTON_WIDTH = 200

local function make_button(parent, label, main)
	local button = parent:CreateChild("Button")
	if main then button:SetStyle("PrimaryButton") else button:SetStyleAuto() end
	button:SetName("Button")
	button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	button.minHeight = 24
	button.minWidth = MENU_BUTTON_WIDTH
	local text = button:CreateChild("Text")
	text:SetName("ButtonText")
	text:SetStyleAuto()
	text.text = label
	text:SetTextAlignment(HA_CENTER)
	return button
end

-- Name + size as separate texts so the size can be smaller and duller
local function make_game_button(parent, name, size)
	local button = parent:CreateChild("Button")
	button:SetStyleAuto()
	button:SetName("Button")
	button:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(12, 2, 12, 2))
	button.minHeight = 24
	button.minWidth = MENU_BUTTON_WIDTH
	local text = button:CreateChild("Text")
	text:SetName("ButtonText")
	text:SetStyleAuto()
	text.text = name
	if text.width > 0 then
		-- So the size beside it does not squeeze the name: a function
		-- because the fixedWidth property has no setter in the bindings
		text:SetFixedWidth(text.width)
	end
	local size_text = button:CreateChild("Text")
	size_text:SetStyleAuto()
	size_text.text = format_bytes(size)
	size_text:SetFontSize(12)
	size_text.color = magic.Color(ui_utils.rgb("dim"))
	size_text:SetTextAlignment(HA_RIGHT)
	return button
end

local function make_labeled_edit(parent, label, value, width)
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
	edit.minWidth = width or 300
	edit:SetText(value)
	return edit
end

-- A screen of one window with a line of text in it
local function push_status_screen(desc, text)
	local root = uistack.main:push({desc = desc})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)
	local status = window:CreateChild("Text")
	status:SetStyleAuto()
	status.text = text
	return root, window, status
end

-- Whether a game runs under the launcher's screens ([MENU_ERRORS] reads
-- it: a dialog before a join, a notice line in a game)
function M.in_app()
	for _, e in ipairs(uistack.main.stack) do
		local ok, name = pcall(function() return e:GetName() end)
		if ok and name and name:find(GAME_RUNNING, 1, true) then
			return true
		end
	end
	return false
end

M.show_dead_server = ui_utils.show_dead_server

-- The connect runs on a worker and this screen polls it
-- ([BOX_PLAYTEST_2] 12): a blocking connect froze the frame
-- `fallbacks`: the addresses to try next when this one fails, a pool's
-- other servers ([STARPORT] 2b)
local function connect_or_show_error(address, fallbacks)
	local ok, why = api.connect_start(address)
	if not ok then
		-- The start's stripes, handed to a join that is not coming
		-- ([START_STRIPES_ETA])
		pcall((ui_utils.safe or ui_utils).join_screen, "left")
		show_error(why)
		return
	end
	local root, _, status = push_status_screen("connecting",
			"Connecting to "..address.."...")
	-- What a check waits for
	log:info("connect_server(): to " .. address)
	local t0 = api.get_time_us()
	local done = false
	root:SubscribeToStackEvent("Update", function()
		if done then
			return
		end
		local state, err = api.connect_poll()
		if state == "pending" then
			-- The seconds, so that the screen says it is still going
			status.text = "Connecting to "..address.."...  "..
					math.floor((api.get_time_us() - t0) / 1000000).." s"
			return
		end
		done = true
		uistack.main:pop(root)
		if state == "ok" then
			log:info("connect_server() ok")
			M.game_running()
		elseif fallbacks and #fallbacks > 0 then
			log:info("connect_server() failed; the pool's next server")
			local rest = {}
			for i = 2, #fallbacks do
				rest[#rest + 1] = fallbacks[i]
			end
			connect_or_show_error(fallbacks[1], rest)
		else
			log:info("connect_server() failed")
			pcall((ui_utils.safe or ui_utils).join_screen, "left")
			show_error(err)
		end
	end)
end

-- **Back to a server whose connection went** ([SERVE_UPDATE_SMOOTH] 6),
-- from client/api.lua's leave. One that said it restarts is tried every
-- 3 s for up to 5 minutes, with Cancel; any other only when asked, as a
-- crash or the network gives no telling when it comes back. A rejoin is
-- a join: the app logs in with the kept login and does what it does then.
-- simplified: Cancel during a try lets that try finish, and one that got
-- through is joined
function M.reconnect(address, why, restarting)
	if not restarting then
		ui_utils.show_confirm_dialog(why, function()
			M.reconnect(address, why, true)
		end, nil, "Reconnect", "Back")
		return
	end
	local root, window, status = push_status_screen("reconnecting", why)
	local cancel = make_button(window, "Cancel")
	local t0 = api.get_time_us()
	local next_try, trying, done = 0, false, false
	local function close()
		done = true
		uistack.main:pop(root)
	end
	ui_utils.bind_button_menu(root, {{cancel, function()
		log:info("reconnect: cancelled")
		if trying then
			cancel:SetVisible(false)
			status.text = why .. "\n\nCancelling..."
			done = "cancel"
		else
			close()
		end
	end}})
	cancel:SetFocus(true)
	root:SubscribeToStackEvent("Update", function()
		if done == true then
			return
		end
		local now = api.get_time_us()
		if trying then
			local state = api.connect_poll()
			if state == "pending" then
				return
			end
			trying = false
			if state == "ok" then
				log:info("reconnect: joined " .. address)
				close()
				uistack.main:push({desc = GAME_RUNNING, tap_outside = false})
				magic.ui:SetFocusElement(nil)
				return
			end
		end
		if done == "cancel" then
			close()
			return
		end
		local s = math.floor((now - t0) / 1000000)
		if s >= 300 then
			log:info("reconnect: not back in 5 minutes")
			close()
			show_error(why .. "\n\nNot back in 5 minutes.")
			return
		end
		status.text = why .. "\n\nReconnecting... (" .. s .. " s)"
		if now >= next_try then
			next_try = now + 3000000
			trying = api.connect_start(address)
		end
	end)
end

-- A connect asked for by the launch grid ("Feedback..." on an app)
-- **The placeholder goes on the stack whichever launcher this is**
-- ([MENU_LEAVE]): the launcher's screens are not drawn through the world,
-- and the scan a driven run reads stands aside only for a top named "game
-- is running". A launcher leaving a game pops the whole stack. After a
-- connect, and under a serverless app ([SERVERLESS_PLAY])
function M.game_running()
	uistack.main:push({desc = GAME_RUNNING, tap_outside = false})
	magic.ui:SetFocusElement(nil)
end

function M.connect(address)
	api.stop_local_server()
	connect_or_show_error(address)
end

-- **[PLAY_LINKS] A link's server**: the play page's ?server=, joined
-- when a Starport in the settings lists it -- and on an https page, with
-- TLS -- so that a link cannot send a visitor's browser into any server
-- under the page's name. Otherwise the menu stays, with why.
function M.join_listed(address)
	local https = buildat.get_env("BUILDAT_PAGE_HTTPS") == "1"
	log:info("A link asks to join " .. address)
	starport.fetch(function(rows, info)
		for _, x in ipairs(rows) do
			-- A row's address is "https://host:port" behind TLS
			local a = tostring(x.address)
			if a:gsub("^https://", ""):lower() == address:lower() and
					(x.tls or not https) then
				M.connect(a)
				return
			end
		end
		log:info("A link's " .. address .. " is not listed; not joined")
		show_error("The link asked to join " .. address .. ", which " ..
				"no Starport in the settings lists" ..
				(https and " with TLS" or "") .. ", so this page does " ..
				"not join it.\nThe servers it can join are under Servers." ..
				(#info.errors > 0 and "\n\n" .. table.concat(info.errors,
				"\n") or ""))
	-- Asking: the link was the user's click, and a Starport not asked yet
	-- is the permission dialog rather than a "not listed"
	end, true)
end

-- **Join a Buildat server**: launch_menu's Servers layout
-- (playtest, 2026-10-07): a title, the servers in one list, sectioned,
-- and a column beside it with the picked one, the address fields and Join
local PANEL_WIDTH = 300

function M.show_connect_to_server()
	api.stop_local_server()
	local root = uistack.main:push({desc="connect_to_server"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)

	local narrow = magic.ui.root.width < 760
	local width = math.min(magic.ui.root.width - 40, 1000)
	local list_w = narrow and width - 32 or width - 32 - PANEL_WIDTH - 12
	-- A fifth of the height to spare: a phone's browser bars take some of
	-- the page as it scrolls (playtest, 2026-10-07)
	local room = math.floor(magic.ui.root.height * 0.8) - 220 - (narrow and 300 or 0)
	local outer = root:CreateChild("Window")
	outer:SetStyleAuto()
	outer:SetLayout(LM_VERTICAL, 8, magic.IntRect(16, 12, 16, 12))
	outer:SetAlignment(HA_LEFT, VA_CENTER)
	outer:SetFixedWidth(width)
	local title = outer:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Join a Buildat server"
	title:SetFontSize(20)
	-- What the Starports said; an error is long and wraps
	local sp_title = outer:CreateChild("Text")
	sp_title:SetStyleAuto()
	sp_title.text = "Public servers: asking the Starports..."
	sp_title.color = magic.Color(ui_utils.rgb("dim"))
	sp_title:SetWordwrap(true)
	sp_title:SetFixedWidth(width - 32)

	local body = outer:CreateChild("UIElement")
	body:SetLayout(narrow and LM_VERTICAL or LM_HORIZONTAL, 12,
			magic.IntRect(0, 0, 0, 0))
	local left = body:CreateChild("UIElement")
	left:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(list_w)
	local window = body:CreateChild("UIElement")
	window:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	window:SetFixedWidth(narrow and width - 32 or PANEL_WIDTH)

	-- The tabs, which list is shown, and a filter of it
	local search_row = left:CreateChild("UIElement")
	search_row:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(0, 0, 0, 0))
	local tabs = search_row:CreateChild("UIElement")
	tabs:SetLayout(LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
	local search_label = search_row:CreateChild("Text")
	search_label:SetStyleAuto()
	search_label.text = "Filter"
	search_label:SetFixedWidth(60)
	local search = search_row:CreateChild("LineEdit")
	search:SetStyleAuto()
	search:SetFixedHeight(26)
	search.textCopyable = true
	search.textSelectable = true
	-- A typed address, and the servers used, unless the Starport lock
	-- says the list is the only way in ([STARPORT] 4)
	local direct = starport.direct_connect_allowed()
	local address_edit, port_edit
	local do_connect
	local picked = nil
	-- The fleet open, or nil for the top ([STARPORT] 2b); the list's
	-- drawing, which a fleet's row opens
	local open_fleet, redraw = nil, nil
	local function pick(row, second)
		if row.back or row.fleet_id then
			open_fleet = row.fleet_id
			picked = row.fleet_id and row or nil
			redraw()
			return
		end
		picked = row
		if row.host and direct then
			address_edit:SetText(row.host)
			port_edit:SetText(row.port)
		end
		if second and not row.native_only then
			do_connect()
		end
	end
	-- One list, of the tab's servers: the ones used, the Starports'
	-- public ones, or this network's (playtest, 2026-10-07)
	local list = ui_utils.server_list(left, {width = list_w,
			height = math.max(120, room), panel = window,
			hint = not direct and "Pick a server from the list" or nil}, pick)

	if direct then
		address_edit = make_labeled_edit(window, "Address", "localhost",
				PANEL_WIDTH)
		port_edit = make_labeled_edit(window, "Port (optional)", "29500",
				PANEL_WIDTH)
		address_edit:SetFocus(true)
	end

	-- [PLAY_PAGE] (b): an https page reaches a server by a secure
	-- WebSocket only, so one with no TLS in front is the native client's
	local web_tls_only = buildat.get_env("BUILDAT_PAGE_HTTPS") == "1"

	-- **Public servers** from the Starports in the settings, merged and
	-- filtered by the extension; the filter narrows what came
	local sp_rows = {}
	local lan_rows, used_rows = {}, {}
	local function categories(x)
		local d = {}
		for k, v in pairs(x.descriptors or {}) do
			if v ~= "no" and v ~= "none" then
				d[#d + 1] = k .. " " .. tostring(v)
			end
		end
		table.sort(d)
		return tostring(x.kind) .. ", " .. tostring(x.audience) .. ", " ..
				tostring(x.access) ..
				(#d > 0 and " (" .. table.concat(d, ", ") .. ")" or "")
	end
	local function public_rows(q)
		local shown = {}
		for _, x in ipairs(sp_rows) do
			local f = type(x.fleet) == "table" and x.fleet or {}
			local hay = (tostring(x.name) .. " " .. tostring(x.description) ..
					" " .. table.concat(x.tags or {}, " ") .. " " ..
					tostring(f.name or "")):lower()
			if q == "" or hay:find(q, 1, true) then
				shown[#shown + 1] = x
			end
		end
		local rows = {}
		if open_fleet then
			rows[1] = {name = "< All public servers", back = true}
		end
		for _, g in ipairs(starport.group(shown, open_fleet)) do
			local x = g.server
			local row = {group = g}
			if g.kind == "fleet" then
				row.name = tostring(g.name)
				row.badge = "fleet of " .. g.count .. ", " .. g.players ..
						" playing"
				row.line = tostring(g.description or "")
				row.fleet_id = g.fleet.id
			else
				row.host, row.port = x.address:match("^(.*):(%d+)$")
				row.address = x.address
				row.name = g.kind == "pool" and tostring(g.name) or
						tostring(x.name)
				row.badge = (g.kind == "pool" and g.count .. " servers, " or
						"") .. g.players .. " playing" ..
						(x.updating == true and ", updating" or "")
				row.line = tostring(x.description or "") .. "\n" ..
						categories(x) .. "  via " ..
						table.concat(x.starports or {}, ", ")
				-- [STARPORT] 3: said before the connect, not after
				if x.access == "external" then
					row.signup = tostring(x.signup_url or "")
					row.line = row.line .. "\nSign up at " .. row.signup ..
							" first"
				end
				if web_tls_only and not x.tls then
					row.native_only = true
					row.badge = row.badge .. ", native client only"
					row.line = "Native client only: no TLS in front of " ..
							"it, which a web page needs\n" .. row.line
				end
				-- A pool: its best first, the others to fall back on
				row.fallbacks = {}
				for i = 2, #g.servers do
					row.fallbacks[#row.fallbacks + 1] = g.servers[i].address
				end
			end
			rows[#rows + 1] = row
		end
		return rows
	end
	-- Without direct connects there is only the Starports' list
	local tab = "starport"
	local tab_buttons = {}
	-- **From 2 characters** (user, 2026-10-07): one matches so much that
	-- the list's redraw lags at each key
	local function filter_text()
		local q = search:GetText():lower()
		return #q >= 2 and q or ""
	end
	redraw = function()
		local q = filter_text()
		for name, b in pairs(tab_buttons) do
			b.selected = (name == tab)
			-- In the main button's amber, as launch_menu's locked row
			b:GetChild("ButtonText").color = magic.Color(ui_utils.rgb(
					name == tab and "main" or "text"))
		end
		local rows
		if tab == "starport" then
			rows = public_rows(q)
		else
			rows = {}
			for _, r in ipairs(tab == "lan" and lan_rows or used_rows) do
				if q == "" or (r.name .. " " .. (r.line or "")):lower():find(q,
						1, true) then
					rows[#rows + 1] = r
				end
			end
		end
		if #rows == 0 then
			rows[1] = {header = q ~= "" and "Nothing matches the filter" or
					tab == "used" and "No servers used yet" or
					tab == "lan" and "Nothing heard on this network yet" or
					"No public servers"}
		elseif tab == "lan" then
			-- Anyone on the network can announce
			table.insert(rows, 1, {header = "As announced:"})
		end
		list:set_rows(rows)
	end
	if direct then
		for _, t in ipairs({{"used", "Servers used"},
				{"starport", "Starports"}, {"lan", "This network"}}) do
			local b = make_button(tabs, t[2])
			b.minWidth = 0
			b:SetFixedSize(120, 26)
			magic.SubscribeToEvent(b, "Released", function()
				tab = t[1]
				-- Listening on the LAN from here on ([WIN_FIREWALL]): the
				-- firewall's question comes when the player looked
				if tab == "lan" and not api.get_preference("lan_discovery") then
					local ok, err = api.set_preference("lan_discovery", true)
					if not ok then
						log:warning("lan_discovery: " .. tostring(err))
					end
				end
				redraw()
			end)
			tab_buttons[t[1]] = b
		end
	end
	-- Filtered as it is typed, redrawn only when what it filters by changed
	local filtered_by = ""
	magic.SubscribeToEvent(search, "TextChanged", function()
		if filter_text() ~= filtered_by then
			filtered_by = filter_text()
			redraw()
		end
	end)
	local function refresh(ask)
		starport.fetch(function(rows, info)
			-- The answer can come after the screen was closed, and its
			-- elements are gone then
			local open = false
			for _, r in ipairs(uistack.main.stack) do
				if r == root then open = true end
			end
			if not open then return end
			sp_rows = rows
			sp_title.text = "Public servers: " .. #rows ..
					(info.hidden > 0 and ", " .. info.hidden ..
					" hidden by your filters" or "") ..
					(info.unasked > 0 and "; Refresh asks " .. info.unasked ..
					" more Starport(s)" or "") ..
					(info.stale > 0 and "; kept from " ..
					math.floor(info.stale / 60) .. " min ago" or "") ..
					(#info.errors > 0 and "\n" .. table.concat(info.errors,
					"\n") or "")
			if tab == "starport" then redraw() end
		end, ask)
	end

	-- **On this network** ([LAN_DISCOVERY]): what announces itself on
	-- the LAN, asked every second; redrawn only when it changed, so a
	-- pick and the scroll stay. Anyone on the network can announce, so
	-- it is said as heard, and the join is the ordinary connect.
	if direct then
		local shown, next_us = nil, 0
		root:SubscribeToStackEvent("Update", function()
			local now = api.get_time_us()
			if now < next_us then
				return
			end
			next_us = now + 1000000
			local rows = {}
			for _, e in ipairs(api.lan_servers()) do
				rows[#rows + 1] = {host = e.host, port = e.port,
						name = e.name ~= "" and e.name or e.host,
						badge = e.players .. " playing",
						line = e.app .. " " .. e.version .. "  at " .. e.host ..
						":" .. e.port .. (e.account and
						"; needs an account there" or "")}
			end
			table.sort(rows, function(a, b) return a.name < b.name end)
			local sig = {}
			for _, r in ipairs(rows) do
				sig[#sig + 1] = r.name .. r.badge .. r.line
			end
			sig = table.concat(sig, "\n")
			if sig ~= shown then
				shown = sig
				lan_rows = rows
				if tab == "lan" then redraw() end
				-- What a check waits for
				log:info("This network: " .. #rows .. " heard")
			end
		end)

		for _, e in ipairs(network.known_addresses()) do
			local host, port = e.uri:match("^%a+://(.-):(%d+)$")
			-- A Luanti server (udp://) is the Luanti client's to list
			if e.uri:match("^udp://") then host = nil end
			if host and e.accepted then
				-- One behind TLS is joined by its https address
				if e.uri:match("^https://") then host = "https://" .. host end
				used_rows[#used_rows + 1] = {name = host .. ":" .. port,
						host = host, port = port,
						line = e.description ~= "" and e.description or nil}
			end
		end
		if #used_rows > 0 then tab = "used" end
	end
	redraw()
	refresh(false)

	do_connect = function()
		if not direct then
			if not picked then
				show_error("Pick a server from the list")
				return
			end
			if not picked.host then
				show_error("Pick a server of the fleet")
				return
			end
			if picked.signup and not picked.told then
				picked.told = true
				show_error("This server needs an account made at\n" ..
						picked.signup .. " first.\nConnect again when you "..
						"have one.")
				return
			end
			connect_or_show_error(picked.host .. ":" .. picked.port,
					picked.fallbacks)
			return
		end
		local host = address_edit:GetText()
		local port = port_edit:GetText()
		if host == "" then
			show_error("Enter a server address")
			return
		end
		local address = host
		if port ~= "" then
			address = host..":"..port
		end
		if picked and picked.address == address and picked.signup and
				not picked.told then
			picked.told = true
			show_error("This server needs an account made at\n" ..
					picked.signup .. " first.\nConnect again when you have one.")
			return
		end
		connect_or_show_error(address, picked and
				picked.address == address and picked.fallbacks or nil)
	end

	local connect_button = make_button(window, "Join", true)
	connect_button:SetFixedHeight(28)
	magic.SubscribeToEvent(connect_button, "Released", function()
		do_connect()
	end)
	local sp_buttons = window:CreateChild("UIElement")
	sp_buttons:SetLayout(LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
	for _, b in ipairs({
		{"Refresh", function() refresh(true) end},
		{"Report...", function()
			local address = picked and (picked.address or (picked.group and
					picked.group.servers[1].address))
			if not address or not starport.open_report(address) then
				show_error("Pick a public server to report")
			end
		end},
	}) do
		local button = make_button(sp_buttons, b[1])
		button.minWidth = 0
		button:SetFixedHeight(26)
		magic.SubscribeToEvent(button, "Released", b[2])
	end
	if direct then
		magic.SubscribeToEvent(address_edit, "TextFinished", function()
			do_connect()
		end)
		magic.SubscribeToEvent(port_edit, "TextFinished", function()
			do_connect()
		end)
	end

	ui_utils.close_glyph(root, outer)

	-- [JOIN_BUILDAT_KEYS]: Up and Down in the list or the column beside
	-- it, Right and Left between them
	ui_utils.keyboard_page(outer)
	ui_utils.keyboard_columns(outer, left, window)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		if event_data:GetInt("Key") == KEY_ESCAPE then
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
	-- The checks wait for this line
	log:info("Join a Buildat server: shown")
end

local function show_starting(game)
	-- [START_STRIPES_ETA] The wait in the loading screen's stripes: stripe
	-- one "Starting <game>..." and the compile's percentage, stripe two the
	-- server's stage off its STATUS lines ([START_PROGRESS]) and its
	-- seconds. The join takes the same screen over (release()), so there
	-- is no frame between this and the game's own. The stack's root is
	-- for its keys and its Update.
	local root = uistack.main:push({desc = "starting_local_server"})
	local screen = (ui_utils.safe or ui_utils).load_screen()
	local title = "Starting "..game.."..."
	screen.line(title)
	local shown = title
	log:info("launch_menu: start: "..title)

	local t0 = api.get_time_us()
	local last_stage, last_stage_at, last_poll = nil, t0, 0
	local percent = nil
	local done = false
	local function finish()
		done = true
		uistack.main:pop(root)
		screen.close()
	end
	root:SubscribeToStackEvent("Update", function()
		if done then
			return
		end
		local port, line = api.local_server_state()
		if port then
			done = true
			-- **This screen goes when the game comes** ([MENU_LEAVE]):
			-- left on the stack, its root's Escape stopped the server
			-- instead of pausing. The stripes stay for the join.
			uistack.main:pop(root)
			screen.release()
			connect_or_show_error("localhost:"..port)
			return
		end
		if not api.local_server_running() then
			finish()
			M.show_dead_server("The server exited while starting")
			return
		end
		local now = api.get_time_us()
		if now - last_poll > 250000 then
			last_poll = now
			-- "Compiling a, b (2 of 9, 45%)": the stage less its share
			local p = line and line:match(", (%d+)%%%)$")
			local stage = line and line:gsub(", %d+%%%)$", ")")
			percent = p and tonumber(p) or percent
			if stage ~= last_stage then
				last_stage, last_stage_at = stage, now
			end
		end
		local one = percent and title.." "..percent.."%" or title
		if one ~= shown then
			shown = one
			screen.line(one)
			log:info("launch_menu: start: "..one..(percent and " (compiling)" or ""))
		end
		-- The seconds since the stage began, always: a screen that sits
		-- still while the user can only wait is the failure [FIRST_RUN]'s
		-- run looks for
		local secs = math.floor((now - last_stage_at) / 1000000)
		screen.stage((last_stage or "Waiting for the server").."  "..secs.." s")
		-- Not a fixed wait: a fresh compile of every module can outlast
		-- one on a slow machine. A hang is no new stage for 120 s: the
		-- percentage moving every second is not progress by itself.
		if now - last_stage_at > 120 * 1000000 then
			api.stop_local_server()
			finish()
			show_error("Server did not start: no progress for 120 s"..
					(last_stage and (", last at \""..last_stage.."\"") or ""))
		end
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		-- Only while there is still a start to cancel ([MENU_LEAVE])
		if done then
			return
		end
		if event_data:GetInt("Key") == KEY_ESCAPE then
			api.stop_local_server()
			finish()
			-- **The launcher hears the cancel** ([RELEASE_RED] core.sh,
			-- 2026-10-04): the room had stood down for the launch and
			-- stayed stood down, its input with nobody, until told
			api.leave()
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

local function do_start_local_game(game, launch)
	local ok, err = api.start_local_server(game, launch)
	if not ok then
		show_error(err)
		return
	end
	show_starting(game)
end

local function show_waiting_for_old_server(game, launch)
	local root = push_status_screen("stopping_old_server",
			"Stopping previous server...")
	local t0 = api.get_time_us()
	local done = false
	root:SubscribeToStackEvent("Update", function()
		if done then
			return
		end
		if not api.local_server_running() then
			done = true
			uistack.main:pop(root)
			do_start_local_game(game, launch)
			return
		end
		if api.get_time_us() - t0 > 10 * 1000000 then
			done = true
			uistack.main:pop(root)
			ui_utils.show_confirm_dialog(
				"The previous local server is still running.\n"..
				"It may be saving. Force kill it?",
				function()
					api.stop_local_server(true)
					do_start_local_game(game, launch)
				end,
				function()
				end, "Force kill")
		end
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		if event_data:GetInt("Key") == KEY_ESCAPE then
			done = true
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

-- A game by name, with launch: key=value lines for the server's -u, or
-- nil. What a tile on the launch grid ends in ([LAUNCH_GRID]).
function M.start_local_app(game, launch)
	-- A server of this app that holds no world takes the launch as it is
	-- (launch:reusable); start refuses any other running one
	if api.local_server_running() and api.start_local_server(game, launch) then
		show_starting(game)
		return
	end
	api.stop_local_server()
	if not api.local_server_running() then
		do_start_local_game(game, launch)
		return
	end
	show_waiting_for_old_server(game, launch)
end

-- [APP_CATEGORY] the apps by what they say they are (main/meta.json's
-- kind), in this order; none or an unknown one is "Other"
local GROUPS = {
	{"Games", {world = true, arena = true}},
	{"Apps", {app = true}},
	{"Other", nil},
	{"Experiments", {experiment = true}},
	{"Checks", {check = true}},
}
local function group_of(kind)
	for i, g in ipairs(GROUPS) do
		if g[2] and g[2][kind] then
			return i
		end
	end
	return 3
end

-- Pages of rows, {header = title} or {app = entry}, at most per_page rows
-- each: a group starts a new page unless all of it fits on this one, and
-- a group longer than a page goes on with its header again
local function app_pages(apps, per_page)
	local by_group = {}
	for _, a in ipairs(apps) do
		local g = group_of(a.kind)
		by_group[g] = by_group[g] or {}
		table.insert(by_group[g], a)
	end
	local pages, cur = {}, {}
	for i, g in ipairs(GROUPS) do
		local list = by_group[i]
		if list then
			if #cur > 0 and #cur + 1 + #list > per_page then
				pages[#pages + 1], cur = cur, {}
			end
			cur[#cur + 1] = {header = g[1]}
			for _, a in ipairs(list) do
				if #cur >= per_page then
					pages[#pages + 1], cur = cur, {{header = g[1]}}
				end
				cur[#cur + 1] = {app = a}
			end
		end
	end
	if #cur > 0 then
		pages[#pages + 1] = cur
	end
	return pages
end
do
	local p = app_pages({{name = "c1", kind = "check"},
			{name = "v", kind = "world"}, {name = "x"}, {name = "c2",
			kind = "check"}}, 4)
	assert(#p == 2 and p[1][1].header == "Games" and p[1][2].app.name == "v"
			and p[1][3].header == "Other" and p[2][1].header == "Checks" and
			#p[2] == 3)
	p = app_pages({{kind = "app"}, {kind = "app"}, {kind = "app"}}, 3)
	assert(#p == 2 and p[2][1].header == "Apps" and #p[2] == 2)
end

function M.show_local_apps(page)
	local root = uistack.main:push({desc="local_game"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)

	local menu = ui_utils.vertical_menu(root, {min_width = MENU_BUTTON_WIDTH})

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Local app"

	local games = api.list_apps()
	if #games == 0 then
		local empty = menu.window:CreateChild("Text")
		empty:SetStyleAuto()
		empty.text = "No apps found"
	else
		-- A page at a time: at 720 px high the whole list ran off the
		-- screen, Back with it
		-- simplified: 15 rows a page; a window under ~600 px high still
		-- clips one, and the height read from the window is the upgrade
		local all = app_pages(games, 15)
		local pages = #all
		page = math.max(1, math.min(page or 1, pages))
		for _, r in ipairs(all[page]) do
			if r.header then
				local h = menu.window:CreateChild("Text")
				h:SetStyleAuto()
				h.text = r.header
			else
				local name = r.app.name
				local button = make_game_button(menu.window, name, r.app.size)
				menu:add(button, function()
					M.start_local_app(name)
				end)
			end
		end
		local function redraw(p)
			uistack.main:pop(root)
			M.show_local_apps(p)
		end
		if page > 1 then
			menu:add("^ previous   (page " .. (page - 1) .. " of " .. pages .. ")",
					function() redraw(page - 1) end)
		end
		if page < pages then
			menu:add("v more   (page " .. (page + 1) .. " of " .. pages .. ")",
					function() redraw(page + 1) end)
		end
	end

	menu:add("Back", function()
		uistack.main:pop(root)
	end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
