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
local STYLE = "own:ui_utils/res/style.xml"
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

-- **Servers** ([SERVERS_SCREEN], user 2026-11-03): servers only, in
-- sections in one list -- the LAN's, the ones joined before, the
-- Starports' public ones and Luanti's -- and beside it the shown one's
-- info: the row under the mouse, or the one Up and Down moved to. A click
-- (Enter, a tap) joins; a finger held on a row only shows it. Report arms:
-- the next public server clicked is reported instead of joined.
local PANEL_WIDTH = 300
local LONG_PRESS_US = 600000
-- The Luanti client's connect dialog, which a Luanti server's join opens
-- on its address (the name and password are asked there)
local LUANTI_CONNECT = "extension/luanti_client/connect"

-- An address's own row of the Starports' merged list as rows: a fleet's
-- pools and servers each a row, named "<fleet>: <pool>"
-- simplified: a fleet is not a level to open, its rows are listed flat
local function public_rows(rows, tls_only)
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
	local out = {}
	local function add(g, prefix)
		local x = g.server
		if tls_only and not x.tls then return end
		local row = {kind = "buildat", address = tostring(x.address),
			report = tostring(x.address),
			name = prefix .. (g.kind == "pool" and tostring(g.name) or
					tostring(x.name)),
			badge = (g.kind == "pool" and g.count .. " servers, " or "") ..
					g.players .. " playing" ..
					(x.updating == true and ", updating" or ""),
			info = tostring(x.address) .. "\n" ..
					tostring(x.description or "") .. "\n" .. categories(x) ..
					"\nListed by " .. table.concat(x.starports or {}, ", "),
			fallbacks = {}}
		-- [STARPORT] 3: said before the connect, not after
		if x.access == "external" then
			row.signup = tostring(x.signup_url or "")
			row.info = row.info .. "\nSign up at " .. row.signup .. " first"
		end
		-- A pool: its best first, the others to fall back on
		for i = 2, #g.servers do
			row.fallbacks[#row.fallbacks + 1] = g.servers[i].address
		end
		out[#out + 1] = row
	end
	for _, g in ipairs(starport.group(rows)) do
		if g.kind == "fleet" then
			for _, p in ipairs(starport.group(rows, g.fleet.id)) do
				add(p, tostring(g.name) .. ": ")
			end
		else
			add(g, "")
		end
	end
	return out
end

function M.show_servers()
	local root = uistack.main:push({desc = "servers"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)
	local page = buildat.get_env("BUILDAT_PAGE_HTTPS")
	-- A browser has no LAN; an https page reaches only servers behind TLS
	local web, tls_only = page ~= nil, page == "1"
	-- The Starport lock: its list the only way in ([STARPORT] 4)
	local direct = starport.direct_connect_allowed()

	local narrow = magic.ui.root.width < 760
	local width = math.min(magic.ui.root.width - 40, 1000)
	local list_w = narrow and width - 32 or width - 32 - PANEL_WIDTH - 12
	-- A fifth of the height to spare: a phone's browser bars take some of
	-- the page as it scrolls (playtest, 2026-10-07)
	local room = math.max(120, math.floor(magic.ui.root.height * 0.8) -
			130 - (narrow and 170 or 0))
	local outer = root:CreateChild("Window")
	outer:SetStyleAuto()
	outer:SetLayout(LM_VERTICAL, 8, magic.IntRect(16, 12, 16, 12))
	outer:SetAlignment(HA_LEFT, VA_CENTER)
	outer:SetFixedWidth(width)
	local title = outer:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Servers"
	title:SetFontSize(20)

	-- The filter's line: the filter, and Report
	local line = outer:CreateChild("UIElement")
	line:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(0, 0, 0, 0))
	line:SetFixedHeight(26)
	local filter_label = line:CreateChild("Text")
	filter_label:SetStyleAuto()
	filter_label.text = "Filter"
	filter_label:SetFixedWidth(50)
	filter_label.verticalAlignment = VA_CENTER
	local search = line:CreateChild("LineEdit")
	search:SetStyleAuto()
	search:SetFixedHeight(26)
	search:SetFixedWidth(math.min(240, width - 32 - 50 - 160 - 16))
	search.textCopyable = true
	search.textSelectable = true
	local report = make_button(line, "Report")
	report.minWidth = 0
	report:SetFixedSize(150, 26)

	local body = outer:CreateChild("UIElement")
	body:SetLayout(narrow and LM_VERTICAL or LM_HORIZONTAL, 12,
			magic.IntRect(0, 0, 0, 0))
	local left = body:CreateChild("UIElement")
	left:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(list_w)
	local view = ui_utils.list_view(left, list_w, room,
			{wheel = 40, follow_focus = true})
	local panel = body:CreateChild("UIElement")
	panel:SetFixedSize(narrow and width - 32 or PANEL_WIDTH,
			narrow and 130 or room)
	panel.clipChildren = true
	local under = left:CreateChild("UIElement")
	under:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(0, 0, 0, 0))
	under:SetFixedHeight(28)
	local by_address = nil
	if direct then
		by_address = make_button(under, "Join by address...")
		by_address.minWidth = 0
		by_address:SetFixedSize(180, 28)
	end
	local back = make_button(under, "Back")
	back.minWidth = 0
	back:SetFixedSize(100, 28)

	-- What the sections hold, and what an empty one says
	local lan_rows, recent_rows = {}, {}
	local sp_rows, sp_note = {}, "Asking the Starports..."
	local lt_rows, lt_note = {}, "Asking the Luanti server list..."
	local sp_ask, lt_ask = nil, nil
	local armed = false
	local shown_row = nil
	local row_ids = {} -- a row's button -> its id, for the focus
	local untouched = true
	local touch = {t0 = nil, moved = 0, clear = false}

	-- The shown server's info, placed by hand: a layout would share the
	-- spare height out between the lines
	local function show(row)
		shown_row = row
		panel:RemoveAllChildren()
		local y = 0
		local function text(s, size, color)
			local t = panel:CreateChild("Text")
			t:SetStyleAuto()
			t.text = s
			t:SetFontSize(size)
			if color then t.color = magic.Color(ui_utils.rgb(color)) end
			t:SetWordwrap(true)
			t:SetFixedWidth(panel.width)
			t:SetPosition(0, y)
			y = y + t.height + 4
		end
		text(row.name, 18)
		text(row.section .. (row.badge ~= "" and ", " .. row.badge or ""), 12,
				"dim")
		if row.info and row.info ~= "" then text(row.info, 13, "dim") end
	end

	local function set_armed(on)
		armed = on
		report:GetChild("ButtonText").text = on and "Report: Cancel" or
				"Report"
		report:GetChild("ButtonText").color = magic.Color(ui_utils.rgb(
				on and "main" or "text"))
		log:info("Servers: Report " .. (on and "armed" or "disarmed"))
	end

	local function join(row)
		log:info("Servers: join " .. row.name)
		if row.kind == "luanti" then
			local ok, why = api.launch(LUANTI_CONNECT, row.address)
			if not ok then show_error(why) end
			return
		end
		if row.signup and not row.told then
			row.told = true
			show_error("This server needs an account made at\n" ..
					row.signup .. " first.\nJoin again when you have one.")
			return
		end
		api.stop_local_server()
		connect_or_show_error(row.address, row.fallbacks)
	end

	-- A row's click, Enter or tap
	local function activate(row, button)
		-- A finger: dragged, the list scrolled; held, the row only shown
		if touch.t0 then
			local held = api.get_time_us() - touch.t0 >= LONG_PRESS_US
			local moved = touch.moved > 20
			touch.t0 = nil
			if moved then return end
			if held then
				button:SetFocus(true)
				show(row)
				log:info("Servers: shown " .. row.name)
				return
			end
		end
		if row.ask then
			row.ask()
		elseif armed then
			set_armed(false)
			if not (row.report and starport.open_report(row.report)) then
				show_error("Only the public Buildat servers can be reported.")
			end
		else
			join(row)
		end
	end

	local function matches(row, q)
		return q == "" or (row.name .. " " .. (row.badge or "") .. " " ..
				(row.info or "")):lower():find(q, 1, true) ~= nil
	end

	-- The list drawn again, its scroll and the focused row kept
	local function draw()
		local q = search:GetText():lower()
		local top = -view.list.position.y
		-- The row with the focus, by what it is
		local f = magic.ui.focusElement
		local focused = nil
		for b, id in pairs(row_ids) do
			if b == f then focused = id end
		end
		row_ids = {}
		view.list:RemoveAllChildren()
		-- Free while the rows go in: a vertical layout is redone for each
		-- one added (list_view's fit())
		view.list:SetLayout(magic.LM_FREE, 0, magic.IntRect(0, 0, 0, 0))
		view.list:SetPosition(0, 0)
		local refocus, first = nil, nil
		local function section(name, rows, empty, ask)
			view:header(name, 14, "text")
			local n = 0
			for _, row in ipairs(rows) do
				if matches(row, q) then
					n = n + 1
					row.section = name
					row.id = name .. "/" .. tostring(row.address)
					local b = view:row({label = row.name, glyph = "🌐"},
							row.badge)
					b:SetFocusMode(magic.FM_FOCUSABLE)
					magic.SubscribeToEvent(b, "HoverBegin", function()
						show(row)
					end)
					magic.SubscribeToEvent(b, "Focused", function()
						show(row)
					end)
					magic.SubscribeToEvent(b, "Released", function()
						activate(row, b)
					end)
					row_ids[b] = row.id
					if row.id == focused then refocus = b end
					first = first or b
				end
			end
			if n > 0 then return end
			-- The one line an empty section says; one that can ask is a row
			if ask and q == "" then
				local b = view:row({label = ask.name}, ask.badge)
				b:SetFocusMode(magic.FM_FOCUSABLE)
				magic.SubscribeToEvent(b, "Released", function()
					activate(ask, b)
				end)
			else
				-- Wrapped: a phone's list is narrower than the LAN's line
				local t = view.list:CreateChild("Text")
				t:SetStyleAuto()
				t.text = q ~= "" and "Nothing matches the filter" or empty
				t:SetFontSize(12)
				t.color = magic.Color(ui_utils.rgb("dim"))
				t:SetWordwrap(true)
				t:SetFixedWidth(list_w)
			end
		end
		if direct and not web then
			section("LAN", lan_rows, "No LAN games found. The host opens " ..
					"one from the pause menu: My account... > Open to LAN.")
		end
		if direct then
			section("Recent", recent_rows, "No servers joined yet.")
		end
		section("Public (Buildat)", sp_rows, sp_note, sp_ask)
		section("Public (Luanti)", lt_rows, lt_note, lt_ask)
		view:fit()
		-- The list's height stays: the window does not move under the
		-- mouse as rows come and go
		view.viewport:SetFixedSize(list_w, room)
		view:scroll(top)
		-- A focus the redraw took goes back to its row, or the first;
		-- until the player did anything, the first server has it
		if refocus or ((focused or untouched) and first) then
			(refocus or first):SetFocus(true)
		end
		return first
	end

	-- **Recent**: the servers this client joined, the last first
	local listed = {}
	for _, x in ipairs(starport.kept_rows()) do
		listed[tostring(x.address)] = x
	end
	for _, a in ipairs(network.known_addresses()) do
		local scheme, host, port = a.uri:match("^(%a+)://(.-):(%d+)$")
		if a.accepted and a.last_attempt > 0 and (scheme == "https" or
				scheme == "udp" or (scheme == "tcp" and not tls_only)) then
			local address = (scheme == "https" and "https://" or "") ..
					host .. ":" .. port
			local luanti = scheme == "udp"
			local x = listed[address]
			recent_rows[#recent_rows + 1] = {
				kind = luanti and "luanti" or "buildat", address = address,
				name = not luanti and a.name ~= "" and a.name or
						x and tostring(x.name) or address,
				badge = (luanti and "Luanti" or "Buildat") ..
						(x and ", " .. tostring(x.players or 0) ..
						" playing" or ""),
				info = address .. (luanti and a.name ~= "" and
						"\nJoined as " .. a.name or "") ..
						(a.description ~= "" and "\n" .. a.description or "")}
		end
	end

	-- **The LAN** ([LAN_DISCOVERY]): what announces itself there, asked
	-- every second, the list drawn again only when it changed. Listening
	-- from here on ([WIN_FIREWALL]): the firewall's question comes when
	-- the player looked. Anyone on the network can announce, so the join
	-- is the ordinary connect.
	if direct and not web then
		if not api.get_preference("lan_discovery") then
			local ok, err = api.set_preference("lan_discovery", true)
			if not ok then log:warning("lan_discovery: " .. tostring(err)) end
		end
		local heard, next_us = nil, 0
		root:SubscribeToStackEvent("Update", function()
			local now = api.get_time_us()
			if now < next_us then return end
			next_us = now + 1000000
			local rows = {}
			for _, e in ipairs(api.lan_servers()) do
				local address = e.host .. ":" .. e.port
				rows[#rows + 1] = {kind = "buildat", address = address,
					name = e.name ~= "" and e.name or address,
					badge = e.players .. " playing",
					info = address .. "\n" .. e.app .. " " .. e.version ..
							(e.account and "\nNeeds an account there" or "")}
			end
			table.sort(rows, function(a, b) return a.name < b.name end)
			local sig = {}
			for _, r in ipairs(rows) do
				sig[#sig + 1] = r.name .. r.badge .. r.info
			end
			sig = table.concat(sig, "\n")
			if sig ~= heard then
				heard = sig
				lan_rows = rows
				draw()
				-- What a check waits for
				log:info("LAN: " .. #rows .. " heard")
			end
		end)
	end

	-- A finger on the list: when it went down and how far it moved
	root:SubscribeToStackEvent("TouchBegin", function()
		touch.t0, touch.moved = api.get_time_us(), 0
		untouched = false
	end)
	root:SubscribeToStackEvent("TouchMove", function(_, d)
		touch.moved = touch.moved + math.abs(d:GetInt("DX")) +
				math.abs(d:GetInt("DY"))
	end)
	-- Forgotten the frame after it lifted, after the release's click
	root:SubscribeToStackEvent("TouchEnd", function() touch.clear = true end)
	root:SubscribeToStackEvent("Update", function()
		if touch.clear then touch.t0, touch.clear = nil, false end
	end)

	-- **The public lists, fetched as it opens**: the Starports and
	-- Luanti's list whose hosts the player accepted; the others are
	-- asked by a click on the section's line, which may ask the player
	local function still_open()
		for _, r in ipairs(uistack.main.stack) do
			if r == root then return true end
		end
		return false
	end
	local function fetch_public(ask)
		sp_note, sp_ask = "Asking the Starports...", nil
		starport.fetch(function(rows, info)
			-- The answer can come after the screen was closed
			if not still_open() then return end
			sp_rows = public_rows(rows, tls_only)
			sp_note = #info.errors > 0 and "The Starports did not answer." or
					"No public servers listed."
			for _, e in ipairs(info.errors) do log:warning(e) end
			if info.unasked > 0 then
				sp_ask = {name = "Ask for the lists",
					badge = info.unasked .. " Starport(s)",
					ask = function() fetch_public(true) end}
			end
			log:info("Servers: " .. #sp_rows .. " public Buildat servers")
			draw()
		end, ask)
	end
	fetch_public(false)
	local ok_sl, sl = pcall(require, "buildat/extension/serverlist")
	sl = ok_sl and type(sl) == "table" and (sl.fetch and sl or sl.safe)
	local function fetch_luanti(ask)
		lt_note, lt_ask = "Asking the Luanti server list...", nil
		sl.fetch(function(rows, err, unasked)
			if not still_open() then return end
			lt_rows = {}
			for _, s in ipairs(rows or {}) do
				lt_rows[#lt_rows + 1] = {kind = "luanti", address = s.address,
					name = s.name, badge = s.players .. " playing",
					info = s.address .. (s.game ~= "" and "\n" .. s.game or "")}
			end
			lt_note = err and "The Luanti server list did not come." or
					"No servers listed."
			if unasked then
				lt_ask = {name = "Ask for the list", badge = unasked,
					ask = function() fetch_luanti(true) end}
			end
			draw()
		end, ask)
	end
	if sl and sl.fetch then
		fetch_luanti(false)
	else
		lt_note = "No Luanti server list here."
	end

	magic.SubscribeToEvent(search, "TextChanged", function() draw() end)
	magic.SubscribeToEvent(report, "Released", function()
		set_armed(not armed)
	end)
	if by_address then
		magic.SubscribeToEvent(by_address, "Released", function()
			M.show_join_by_address()
		end)
	end
	magic.SubscribeToEvent(back, "Released", function()
		uistack.main:pop(root)
	end)
	draw()
	root:SubscribeToStackEvent("MouseButtonDown", function()
		untouched = false
	end)
	ui_utils.close_glyph(root, outer)
	-- Up and Down through the page: the filter, Report, the rows, the
	-- buttons under them
	ui_utils.keyboard_page(outer)
	root:SubscribeToStackEvent("KeyDown", function(_, d)
		untouched = false
		if d:GetInt("Key") == KEY_ESCAPE then
			if armed then
				set_armed(false)
			else
				uistack.main:pop(root)
			end
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
	-- The checks wait for this line
	log:info("Servers: shown")
end

-- **Join by address**: one field, the address with an optional port, and
-- which kind of server it is. A Luanti one opens the Luanti client's
-- connect dialog on it, for the name and password.
function M.show_join_by_address()
	local root = uistack.main:push({desc = "join_by_address"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 8, magic.IntRect(16, 12, 16, 12))
	window:SetAlignment(HA_CENTER, VA_CENTER)
	window:SetFixedWidth(math.min(magic.ui.root.width - 40, 400))
	local title = window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Join by address"
	title:SetFontSize(20)
	local address_edit = make_labeled_edit(window, "Address",
			"localhost:29500", 200)
	local kind = "Buildat"
	ui_utils.dropdown(window, {"Buildat", "Luanti"}, kind, function(k)
		kind = k
	end, {label = "Server", width = 160})
	local buttons = window:CreateChild("UIElement")
	buttons:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(0, 0, 0, 0))
	local join_button = make_button(buttons, "Join", true)
	join_button.minWidth = 0
	join_button:SetFixedSize(120, 28)
	local cancel = make_button(buttons, "Cancel")
	cancel.minWidth = 0
	cancel:SetFixedSize(120, 28)
	local function join()
		local address = address_edit:GetText():gsub("^%s+", ""):gsub("%s+$", "")
		if address == "" then
			show_error("Enter a server address")
			return
		end
		log:info("Join by address: " .. kind .. " " .. address)
		if kind == "Luanti" then
			local ok, why = api.launch(LUANTI_CONNECT, address)
			if not ok then show_error(why) end
			return
		end
		if not starport.direct_connect_allowed() then
			show_error("Joining by address is off in the Starport settings")
			return
		end
		api.stop_local_server()
		connect_or_show_error(address)
	end
	magic.SubscribeToEvent(join_button, "Released", join)
	magic.SubscribeToEvent(address_edit, "TextFinished", join)
	magic.SubscribeToEvent(cancel, "Released", function()
		uistack.main:pop(root)
	end)
	address_edit:SetFocus(true)
	ui_utils.close_glyph(root, window)
	ui_utils.keyboard_page(window)
	root:SubscribeToStackEvent("KeyDown", function(_, d)
		if d:GetInt("Key") == KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end)
	-- The checks wait for this line
	log:info("Join by address: shown")
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
