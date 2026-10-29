-- Buildat: extension/network/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- TCP and UDP sockets for scripts, with the user in the loop: the first
-- connection or datagram to an address in a week needs the user to accept the
-- address and name it. Answers are remembered in
-- user/network_addresses.csv, **one per asking server and address**
-- ([CONSENT_PER_SERVER]): what the user gave server A's scripts, server
-- B's ask for again. The client's own extensions (the `M.*` functions,
-- not `M.safe`) ask as the client, "".
--
--   local socket = require("buildat/core/network")
--   socket.udp_connect("localhost", 30001, function(sock, err)
--       if not sock then log:error(err) return end
--       sock:send("hello")
--       local data, err = sock:receive() -- nil, "timeout" if nothing yet
--   end)
--
-- The socket objects are LuaSocket's, as far as the safety layer allows:
--
-- * Opening a socket takes a callback, because the user has to answer the
--   dialog first, and the address comes with it: there is no socket.tcp() /
--   socket.udp() followed by connect() or setpeername().
-- * A socket only talks to the one address the user accepted. Listening
--   sockets and unconnected UDP do not exist here.
-- * The sockets are always non-blocking, as with settimeout(0); settimeout()
--   accepts 0 and warns about anything else.
-- * socket.select(), socket.sleep(), socket.dns and socket.bind() are not
--   provided. A game polls its sockets from an Update handler instead.

local log = buildat.Logger("extension/network")
local ui_utils = require("buildat/extension/ui_utils").safe
local uistack = require("buildat/core/uistack")
local magic = require("buildat/core/urho3d").safe
local M = {safe = {}}

local ACCEPTANCE_VALID_S = 7 * 24 * 3600

local store_path = __buildat_get_path("user").."/network_addresses.csv"

-- Addresses this session has already notified about
local notified = {}

-- The store
--
-- CSV, because there are a handful of rows, they want to be readable and
-- editable by hand, and there is no schema to migrate. Every field is quoted so
-- that a description can contain a comma or a quote.

local csv = dofile(__buildat_extension_path("network").."/csv.lua")

-- The server whose scripts are asking: a server this client started is
-- its game's, "local:<app>", as its port changes every launch (the same
-- origin as game_storage_dir); any other its address. "" for none.
local function asking_server()
	local dir = __buildat_game_storage_dir()
	if not dir then
		return ""
	end
	local app = dir:match("/apps/([^/]+)/client$")
	return app and "local:"..app or __buildat_server_address() or ""
end

local function key(server, uri)
	return server.." "..uri
end

-- key(server, uri) -> {accepted=, uri=, description=, created=,
-- last_attempt=, name=, icon=, server=}
-- name is the player name last used on that server ([BOX_PLAYTEST_2] 4),
-- "" for none. A row with no server column is from before
-- [CONSENT_PER_SERVER] and is dropped: it was every server's.
-- [USER_FILES_ATOMIC] Read once and kept: a request's check reads the
-- copy. A write reads the file again first (load_store(true)), so another
-- client's answers since are kept
local store_copy = nil
local function load_store(fresh)
	if store_copy and not fresh then
		return store_copy
	end
	local entries = {}
	store_copy = entries
	local file = io.open(store_path, "r")
	if not file then
		return entries
	end
	for line in file:lines() do
		if line ~= "" and not line:match("^accepted,") then
			local f = csv.parse_line(line)
			if f[2] and f[2] ~= "" and f[8] then
				entries[key(f[8], f[2])] = {
					accepted = (f[1] == "true"),
					uri = f[2],
					description = f[3] or "",
					created = tonumber(f[4]) or 0,
					last_attempt = tonumber(f[5]) or 0,
					name = f[6] or "",
					-- [LAUNCH_WORLD] (4): the sha256 of the icon the
					-- server sent at its last connect, under the cache's
					-- server_icons/; "" for none
					icon = f[7] or "",
					server = f[8],
				}
			end
		end
	end
	file:close()
	return entries
end

local function save_store(entries)
	local keys = {}
	for k, _ in pairs(entries) do
		table.insert(keys, k)
	end
	table.sort(keys)
	store_copy = entries
	local out = {"accepted,address,description,created,last_attempt,name,icon,server\n"}
	-- A row is a line: the reader splits on them, and a field with a line
	-- break in it -- a name a server's script set -- was a second row
	-- nobody accepted ([SECURITY_RUN_1])
	local function q(v)
		return csv.quote((tostring(v):gsub("[\r\n]", " ")))
	end
	for _, k in ipairs(keys) do
		local e = entries[k]
		out[#out + 1] = table.concat({
			q(e.accepted and "true" or "false"),
			q(e.uri),
			q(e.description),
			q(math.floor(e.created)),
			q(math.floor(e.last_attempt)),
			q(e.name or ""),
			q(e.icon or ""),
			q(e.server),
		}, ",").."\n"
	end
	local ok, err = buildat.write_file_atomic(store_path, table.concat(out))
	if not ok then
		log:error("Cannot write "..store_path..": "..tostring(err))
		return
	end
	-- What a check counts
	log:info("network: the consent store written")
end

local function store_answer(server, uri, accepted, description, old_entry)
	local entries = load_store(true)
	local now = os.time()
	entries[key(server, uri)] = {
		accepted = accepted,
		uri = uri,
		-- A description is one line of text
		description = tostring(description or ""):gsub("[\r\n]", " "),
		created = (old_entry and old_entry.created ~= 0) and old_entry.created or now,
		last_attempt = now,
		-- What the row had besides the answer is kept with it
		name = old_entry and old_entry.name or "",
		icon = old_entry and old_entry.icon or "",
		server = server,
	}
	save_store(entries)
end

-- A request's touch: written only when the stored one is over a day old
-- (the 7-day expiry the finest reader of it), not every icon fetch
local TOUCH_S = 24 * 3600
local function touch_entry(server, uri)
	local e = load_store()[key(server, uri)]
	if not e or os.time() - e.last_attempt <= TOUCH_S then
		return
	end
	local entries = load_store(true)
	e = entries[key(server, uri)]
	if e then
		e.last_attempt = os.time()
		save_store(entries)
	end
end
-- For a check: BUILDAT_TEST_CONSENT_TOUCH="<uri> <n>", n touches of the
-- row with no server at the start, as n icon fetches would
do
	local t = __buildat_get_env("BUILDAT_TEST_CONSENT_TOUCH")
	local uri, n = (t or ""):match("^(%S+) (%d+)$")
	for _ = 1, tonumber(n) or 0 do
		touch_entry("", uri)
	end
	if uri then
		log:info("network: " .. n .. " touches of " .. uri .. " done")
	end
end

-- The dialog

local function format_time(t)
	if not t or t == 0 then
		return "never"
	end
	return os.date("%Y-%m-%d %H:%M", t)
end

-- **What the user sees is what they answer** ([SECURITY_RUN_1]): a
-- dialog is in the UI tree every script shares and on the stack they
-- read, so a server's script could rewrite the address it shows, swap
-- the buttons' labels, or make Accept invisible over a Decline of its
-- own. The dialog is taken down to its raw elements once laid out --
-- what each shows, where, how visible, how many children -- and
-- compared every frame and at the answer; on_changed is called on any
-- change. Read fresh from the root each time, so an element a script
-- removed is never touched; a field's own text is the user's and not
-- read. -> {intact(), stop()}
-- An element named PICKER_LIST is a list_view's list, which its scrolling
-- moves: its position is not compared, what it holds is.
local PICKER_LIST = "buildat_picker_list"
local function guard_dialog(root, on_changed)
	local function picture()
		local m = getmetatable(root)
		if not m or m.dead or not m.unsafe then
			return nil
		end
		local out = {}
		local function walk(e, depth)
			local t = e:GetTypeName()
			local rec = {t, tostring(e:IsVisible()),
					string.format("%.3f", e:GetOpacity()), e:GetPriority(),
					e:GetNumChildren(false)}
			if depth >= 2 and e:GetName() ~= PICKER_LIST then
				-- The root fills the screen and the window is centred on
				-- it: those two move with a resize, what is in them does not
				local p = e:GetPosition()
				rec[#rec + 1] = p.x .. "," .. p.y
			end
			if depth >= 1 then
				rec[#rec + 1] = e:GetWidth() .. "x" .. e:GetHeight()
			end
			if t == "Text" then
				local c = e:GetColor(C_TOPLEFT)
				rec[#rec + 1] = string.format("%s %.2f,%.2f,%.2f,%.2f",
						e:GetText(), c.r, c.g, c.b, c.a)
			end
			out[#out + 1] = table.concat(rec, "|")
			if t == "LineEdit" then
				return
			end
			for i = 0, e:GetNumChildren(false) - 1 do
				walk(e:GetChild(i), depth + 1)
			end
		end
		walk(m.unsafe, 0)
		return table.concat(out, "\n")
	end
	local seen = nil  -- the picture once laid out
	local frames = 0
	local sub = nil
	local function stop()
		if sub then
			require("buildat/core/urho3d").unsafe.UnsubscribeFromEvent("Update", sub)
			sub = nil
		end
	end
	sub = magic.SubscribeToEvent("Update", function()
		frames = frames + 1
		-- Laid out by then: a layout settles in the first frame or two
		if frames == 3 then
			seen = picture()
		elseif frames > 3 and picture() ~= seen then
			stop()
			on_changed()
		end
	end)
	return {
		intact = function() return seen ~= nil and picture() == seen end,
		stop = stop,
	}
end

-- Off the stack whatever was put over a dialog since: a script can push
-- a screen of its own on top, and pop() takes the top only
local function close_dialog(root)
	local st = uistack.main.stack
	if st[#st] == root then
		uistack.main:pop(root)
	else
		for _, e in ipairs(st) do
			if e == root then
				uistack.main:pop_to(root, true)
				break
			end
		end
	end
end

-- on_answer(accepted: boolean, description: string). suggested is the
-- caller's own description ([NET_DESC]): the field starts with it --
-- what the caller is asking for is what the caller knows -- editable,
-- and the accept or the decline is still the user's. An entry's own
-- description wins: that is what the user left there.
local function ask_user(server, uri, entry, on_answer, suggested)
	local answer
	-- [AITTA_NET_DESC] So that the next caller without one is found
	if (suggested or "") == "" then
		log:warning("no description from the caller for "..uri)
	end
	local root = uistack.main:push({desc="network permission dialog"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "own:ui_utils/res/style.xml")
	-- Over whatever a server draws (a join window is at 100): the user has
	-- to see what they are asked
	root.priority = 1000

	local menu = ui_utils.vertical_menu(root, {min_width = 400})
	local window = menu.window

	local function add_text(text)
		local t = window:CreateChild("Text")
		t:SetStyleAuto()
		t.text = text
		t:SetTextAlignment(HA_LEFT)
		return t
	end

	-- **Who is asking** ([CONSENT_PER_SERVER]): the answer is that
	-- server's alone
	if server == "" then
		add_text("Buildat itself")
	elseif server:match("^local:") then
		add_text("Your local game "..server:sub(7))
	else
		add_text("A script of the server")
		add_text("  "..server)
	end
	add_text("wants to use the network:")
	add_text("  "..uri)
	if entry then
		add_text("You have seen this address before:")
		add_text("  Answer: "..(entry.accepted and "accepted" or "declined"))
		add_text("  Description: "..entry.description)
		add_text("  First asked: "..format_time(entry.created))
		add_text("  Last attempt: "..format_time(entry.last_attempt))
	end
	add_text("Description (what is this peer?):")

	local edit = window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	edit.minHeight = 24
	edit.minWidth = 380
	edit:SetText((entry and entry.description ~= "" and entry.description) or
			suggested or "")

	local guard = guard_dialog(root, function()
		log:warning("The permission dialog for "..uri.." was changed "..
				"while it was up; declined")
		answer(false)
	end)

	local answered = false
	function answer(accepted)
		if answered then
			return
		end
		answered = true
		if accepted and not guard.intact() then
			log:warning("The permission dialog for "..uri.." was changed "..
					"while it was up; taken as declined")
			accepted = false
		end
		guard.stop()
		local description = edit:GetText()
		close_dialog(root)
		on_answer(accepted, description)
		-- What a check waits for
		log:info("The user " .. (accepted and "accepted " or "declined ") .. uri)
	end

	local accept = menu:add("Accept", function() answer(true) end)
	-- Return in the field accepts what is typed, empty too, as Accept
	-- does ([AITTA_NET_DESC])
	magic.SubscribeToEvent(edit, "TextFinished", function() answer(true) end)
	menu:add("Decline", function() answer(false) end)
	-- ([ACCEPT_FOCUS]) A description already there leaves Enter to accept
	-- it; an empty one wants typing first
	if edit:GetText() ~= "" then
		accept:SetFocus(true)
	else
		edit:SetFocus(true)
	end
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			answer(false)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

-- **A file picked by the user** ([SECURITY_RUN_1]): <user>/exports holds
-- what every server's game exported and whatever the user put there, and
-- a game listing and reading it all read another server's exports. A
-- game gets the one file the user picks here, the web's file picker on
-- native (buildat.safe.pick_file, client/api.lua). It starts in the
-- exports and browses the disk from there ([HEARTH_USABILITY]: a
-- screenshot to post was in <user>/screenshots or the user's pictures),
-- in the client's own window rather than the system's dialog, which is a
-- window of its own. Beside the network dialog for its guard. cb(name,
-- data), or cb(nil, why); accept is the end of a file's name (".fpplan"),
-- "" for any.
-- parts: cb(name, reader) instead, reader.size and reader.read(offset,
-- len) over the file ([WORLD_TRIM_MOVE]: one larger than a string holds).
-- simplified: at most MAX_ROWS rows a folder, in name order; a folder of
-- more wants a search field
local MAX_ROWS = 300
function M.pick_export(accept, cb, dir, back, parts)
	local exports = __buildat_get_path("user") .. "/exports"
	dir = dir or exports
	-- What had the focus, which has it again once the picker is gone
	-- (uistack's pop focuses a plain element: the keys went nowhere)
	back = back or magic.ui.focusElement
	-- The checks wait for this line
	log:info("The file picker at " .. dir)
	local root = uistack.main:push({desc="file picker"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "own:ui_utils/res/style.xml")
	root.priority = 1000
	local width = math.min(560, magic.ui.root.width - 40)
	local menu = ui_utils.vertical_menu(root, {min_width = width})
	local function add_text(text)
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t:SetWordwrap(true)
		t:SetFixedWidth(width)
		t.text = text
		t:SetTextAlignment(HA_LEFT)
	end
	local guard
	local finished = false
	-- name: a file in dir; to: a folder to go to instead
	local function finish(name, to)
		if finished then
			return
		end
		finished = true
		if (name or to) and not guard.intact() then
			log:warning("The file picker was changed while it was up; "..
					"nothing picked")
			name, to = nil, nil
		end
		guard.stop()
		close_dialog(root)
		if to then
			return M.pick_export(accept, cb, to, back, parts)
		end
		pcall(function() back:SetFocus(true) end)
		if not name then
			log:info("The file picker closed; nothing picked")
			return cb(nil, "no file picked")
		end
		local data, why
		if parts then
			local d = dir ~= exports and dir or nil
			log:info("The user picked "..name.." to read in parts")
			local none, size = __buildat_read_exported_part(name, d, 0, 0)
			if not none then
				return cb(nil, size)
			end
			return cb(name, {size = size,
				read = function(offset, len)
					return (__buildat_read_exported_part(name, d, offset, len))
				end,
				close = function() end})
		end
		if dir == exports then
			log:info("The user picked "..name.." from the exports")
			data, why = __buildat_read_exported(name)
		else
			log:info("The user picked "..dir.."/"..name)
			data, why = __buildat_read_exported(name, dir)
		end
		cb(data and name or nil, data or why)
	end
	add_text("A game asks for a file. Pick one from " .. (dir == exports and
			"<user>/exports" or dir) .. ":")
	-- The places a file to hand over is likely in, and the folder above
	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	local places = {{"Exports", exports}, {"Screenshots",
			__buildat_get_path("user") .. "/screenshots"}}
	if home then
		places[#places + 1] = {"Home folder", home}
		if __buildat_count_files(home .. "/Pictures") > 0 then
			places[#places + 1] = {"Pictures", home .. "/Pictures"}
		end
	end
	local up = dir:match("^(.*)[/\\][^/\\]+$")
	if up then
		-- "C:" is the drive's working folder; "C:/" its root
		places[#places + 1] = {"Up", (up == "" or up:match("^%a:$")) and
				up .. "/" or up}
	end
	local bar = menu.window:CreateChild("UIElement")
	bar:SetLayout(LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	for _, pl in ipairs(places) do
		if pl[2] ~= dir then
			local b = bar:CreateChild("Button")
			b:SetStyleAuto()
			b:SetLayout(LM_HORIZONTAL, 0, magic.IntRect(6, 2, 6, 2))
			local t = b:CreateChild("Text")
			t:SetStyleAuto()
			t.text = pl[1]
			menu:add(b, function() finish(nil, pl[2]) end)
		end
	end
	local entries = __buildat_exported_files(dir ~= exports and dir or nil)
	table.sort(entries, function(x, y)
		local dx, dy = x:sub(-1) == "/", y:sub(-1) == "/"
		if dx ~= dy then
			return dx
		end
		return x:lower() < y:lower()
	end)
	local rows = {}
	for _, f in ipairs(entries) do
		if f:sub(-1) == "/" or accept == "" or f:sub(-#accept) == accept then
			rows[#rows + 1] = f
		end
	end
	if #rows == 0 then
		add_text("(none" .. (accept ~= "" and " ending in " .. accept or "") ..
				")")
	else
		-- fit() takes the list's own height under this: a guess of a
		-- row's left the last of six rows out of view
		local view = ui_utils.list_view(menu.window, width,
				math.floor(magic.ui.root.height * 0.6),
				{wheel = 40, follow_focus = true})
		view.list:SetName(PICKER_LIST)
		for i = 1, math.min(#rows, MAX_ROWS) do
			local f = rows[i]
			local folder = f:sub(-1) == "/"
			local b = menu:add(view:row({label = f,
					glyph = folder and "📁" or nil}), function()
				if folder then
					finish(nil, (dir:sub(-1) == "/" and dir or dir .. "/") ..
							f:sub(1, -2))
				else
					finish(f)
				end
			end)
			-- The keys start in the list, the places a key Up above it
			if i == 1 then
				b:SetFocus(true)
			end
		end
		view:fit()
		if #rows > MAX_ROWS then
			add_text("(" .. (#rows - MAX_ROWS) .. " more not shown)")
		end
	end
	menu:add("Cancel", function() finish(nil) end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			-- Not the screen's under it as well (Hearth's Back, the menu)
			uistack.safe.take_key(KEY_ESCAPE)
			finish(nil)
			return true
		end
	end)
	guard = guard_dialog(root, function()
		log:warning("The file picker was changed while it was up; closed")
		finish(nil)
	end)
end

-- The sockets
--
-- The interface is LuaSocket's, as far as the safety layer allows: opening a
-- socket takes a callback because the user has to answer first, and there are
-- no listening sockets and no unconnected UDP. Everything after opening --
-- send, receive, patterns, error strings, timeouts -- works like LuaSocket
-- with settimeout(0).

-- LuaSocket's word for why receive() or send() got nothing done
local function socket_error(socket)
	if socket:good() then
		return "timeout"
	end
	local err = socket:error()
	if err == "" then
		return "closed"
	end
	return err
end

-- Plain Lua wrapper; the socket object from C++ is not sandbox-safe, and this
-- is where the first-packet notification happens.
local function wrap_common(socket, uri, is_udp)
	local w = {}

	local function notify()
		if notified[uri] then
			return
		end
		notified[uri] = true
		ui_utils.show_notification("Connected to "..socket:address())
	end
	if not is_udp then
		notify() -- The connection itself is the event for TCP
	end

	-- send(data [, i [, j]]) -> index of the last byte sent
	function w:send(data, i, j)
		local first = i or 1
		if first < 0 then
			first = #data + first + 1
		end
		local part = data:sub(first, j or -1)
		local sent = socket:send(part)
		if sent > 0 then
			notify()
		end
		if sent < 0 then
			return nil, socket_error(socket)
		end
		if is_udp then
			-- A datagram goes whole or not at all
			if sent < #part then
				return nil, socket_error(socket)
			end
			return 1
		end
		if sent == #part then
			return first + sent - 1
		end
		return nil, "timeout", first + sent - 1
	end

	function w:close()
		socket:close()
		return 1
	end

	function w:getpeername()
		return socket:peer_ip(), socket:peer_port()
	end

	function w:getsockname()
		return socket:local_ip(), socket:local_port()
	end

	-- simplified: the sockets are always non-blocking, which is what
	-- settimeout(0) asks for. Upgrade path if a script needs to wait: select()
	-- around the recv() in src/lua_bindings/network.cpp.
	function w:settimeout(value, mode)
		if value ~= nil and value ~= 0 then
			log:warning("settimeout("..tostring(value)..
					"): only 0 is supported; staying non-blocking")
		end
		return 1
	end

	function w:setoption(option, value)
		return nil, "setoption() is not supported"
	end

	-- Not LuaSocket's, but the address as the user accepted it
	function w:address()
		return socket:address()
	end

	return w
end

local function wrap_tcp(socket, uri)
	local w = wrap_common(socket, uri, false)
	local buffer = ""

	local function pump()
		while true do
			local data = socket:receive()
			if data == "" then
				return
			end
			buffer = buffer..data
		end
	end

	local function take_all()
		local data = buffer
		buffer = ""
		return data
	end

	-- receive([pattern [, prefix]]): a number of bytes, "*a" until the peer
	-- closes the connection, or "*l" one line (the default). What was read
	-- before a timeout comes back as the third value; pass it back as prefix.
	function w:receive(pattern, prefix)
		prefix = prefix or ""
		pattern = pattern or "*l"
		pump()
		if type(pattern) == "number" then
			if #buffer >= pattern then
				local data = buffer:sub(1, pattern)
				buffer = buffer:sub(pattern + 1)
				return prefix..data
			end
			return nil, socket_error(socket), prefix..take_all()
		end
		if pattern == "*a" then
			local data = prefix..take_all()
			if socket:good() then
				return nil, "timeout", data
			end
			if socket:error() == "closed" then
				return data
			end
			return nil, socket:error(), data
		end
		if pattern == "*l" then
			local i = buffer:find("\n", 1, true)
			if i then
				local line = buffer:sub(1, i - 1)
				buffer = buffer:sub(i + 1)
				if line:sub(-1) == "\r" then
					line = line:sub(1, -2)
				end
				return prefix..line
			end
			return nil, socket_error(socket), prefix..take_all()
		end
		error("receive(): unknown pattern "..tostring(pattern))
	end

	return w
end

local function wrap_udp(socket, uri)
	local w = wrap_common(socket, uri, true)

	-- receive([size]): one datagram, truncated to size if given. An empty
	-- datagram is indistinguishable from no datagram.
	function w:receive(size)
		local data = socket:receive()
		if data == "" then
			return nil, socket_error(socket)
		end
		if size and #data > size then
			return data:sub(1, size)
		end
		return data
	end

	-- Not LuaSocket's: Luanti's reliable packets acked as they arrive,
	-- off the game's frame ([ACK_OFF_FRAME]); true if the socket does it
	function w:ack_luanti()
		return socket:ack_luanti()
	end

	function w:receivefrom(size)
		local data, err = w.receive(self, size)
		if not data then
			return nil, err
		end
		return data, socket:peer_ip(), socket:peer_port()
	end

	-- The socket only talks to the address the user accepted
	function w:sendto(data, ip, port)
		if ip ~= socket:peer_ip() or tonumber(port) ~= socket:peer_port() then
			return nil, "this socket is connected to "..socket:address()
		end
		return w.send(self, data)
	end

	function w:setpeername(ip, port)
		return nil, "the peer is set when the socket is opened"
	end

	function w:setsockname(ip, port)
		return nil, "listening sockets are not supported"
	end

	return w
end

-- [PLAY_PAGE] (c): on apps/play's page a datagram socket is a WebSocket to
-- the page's own server, which sends each message on as a datagram to
-- host:port -- if that is on Luanti's list. The methods are the native
-- socket's (src/lua_bindings/network.cpp) that the wrappers above use.
local function web_dgram(bridge, host, port)
	local id = __buildat_web_dgram("open", bridge.."?to="..host..":"..port)
	local function state()
		return __buildat_web_dgram("state", id)
	end
	local s = {}
	function s:good() return state():sub(1, 6) ~= "closed" end
	function s:error()
		local st = state()
		return st:sub(1, 6) == "closed" and st:sub(9) or ""
	end
	function s:address() return host..":"..port end
	function s:peer_ip() return host end
	function s:peer_port() return tonumber(port) end
	function s:local_ip() return "" end
	function s:local_port() return 0 end
	function s:send(data)
		if not s:good() then
			return -1
		end
		__buildat_web_dgram("send", id, data)
		return #data
	end
	function s:receive() return __buildat_web_dgram("recv", id) end
	function s:ack_luanti()
		__buildat_web_dgram("ack_luanti", id)
		return true
	end
	function s:close() __buildat_web_dgram("close", id) end
	return s
end

local TCP_OPEN_WAIT_S = 10
local function open_socket(is_udp, host, port, cb)
	local bridge = is_udp and __buildat_get_env("BUILDAT_LUANTI_BRIDGE")
	local socket = bridge and web_dgram(bridge, host, tostring(port)) or
			is_udp and __buildat_udp_connect(host, tostring(port)) or
			__buildat_tcp_connect(host, tostring(port))
	if not socket:good() then
		cb(nil, socket:error())
		return
	end
	local uri = (is_udp and "udp://" or "tcp://")..host..":"..port
	local function done()
		cb(is_udp and wrap_udp(socket, uri) or wrap_tcp(socket, uri))
	end
	-- [WEB_TCP_CONNECT_FALSE] The web's TCP is a WebSocket that opens a
	-- moment later or fails: answered when it does, a frame at a time
	local state = not is_udp and socket.connect_state and
			socket:connect_state() or "open"
	if state == "open" then
		done()
		return
	end
	local since, sub = os.time(), nil
	sub = magic.SubscribeToEvent("Update", function()
		state = socket:connect_state()
		if state == "pending" and os.time() - since < TCP_OPEN_WAIT_S then
			return
		end
		require("buildat/core/urho3d").unsafe.UnsubscribeFromEvent("Update", sub)
		if state == "open" then
			done()
		else
			socket:close()
			cb(nil, state == "pending" and "connect: no answer in "..
					TCP_OPEN_WAIT_S.." s" or state)
		end
	end)
end

-- cb(socket, error): socket is nil if the connection was not made or the user
-- declined the address
local function connect(server, is_udp, host, port, cb, options)
	if type(host) ~= "string" or not tonumber(port) or type(cb) ~= "function" then
		error("network: connect(host: string, port: number, cb: function)")
	end
	local suggested = type(options) == "table" and
			type(options.description) == "string" and options.description or nil
	local uri = (is_udp and "udp://" or "tcp://")..host..":"..port
	local entry = load_store()[key(server, uri)]
	if entry and entry.accepted and
			os.time() - entry.last_attempt < ACCEPTANCE_VALID_S then
		touch_entry(server, uri)
		open_socket(is_udp, host, port, cb)
		return
	end
	log:info("Asking the user about "..uri.." for \""..server.."\"")
	ask_user(server, uri, entry, function(accepted, description)
		store_answer(server, uri, accepted, description, entry)
		if not accepted then
			cb(nil, "Declined by user: "..uri)
			return
		end
		open_socket(is_udp, host, port, cb)
	end, suggested)
end

function M.safe.tcp_connect(host, port, cb, options)
	connect(asking_server(), false, host, port, cb, options)
end

function M.safe.udp_connect(host, port, cb, options)
	connect(asking_server(), true, host, port, cb, options)
end

function M.tcp_connect(host, port, cb, options)
	connect("", false, host, port, cb, options)
end

function M.udp_connect(host, port, cb, options)
	connect("", true, host, port, cb, options)
end

-- http_get(url, cb): the body of a GET over HTTPS, cb(body) or
-- cb(nil, error), asked of the user through the same dialog and file as a
-- socket is -- the uri is the url's scheme and host ([SERVER_LIST]:
-- Luanti's official server list). Fetched on a thread in the client
-- (__buildat_http_get); read back on Update.
local http_pending = {}
local http_polling = false
-- The web client's is the browser's fetch() ([WEB_ID_TRUST] (c)): what it
-- fetches answers with CORS (Starport, Aitta) or it fails.
local function http_start(url, cb, body)
	local id = __buildat_http_get(url, body)
	http_pending[id] = cb
	if not http_polling then
		http_polling = true
		magic.SubscribeToEvent("Update", function()
			-- The callbacks run after the walk: one that starts a fetch
			-- adds to http_pending, and a key added during pairs() can
			-- rehash the table under next() ("invalid key to 'next'")
			local finished = {}
			for jid, callback in pairs(http_pending) do
				local ok, body, redirect = __buildat_http_poll(jid)
				if ok ~= nil then
					http_pending[jid] = nil
					table.insert(finished, {callback, ok, body, redirect})
				end
			end
			for _, f in ipairs(finished) do
				if f[2] then
					f[1](f[3])
				else
					f[1](nil, f[3], f[4])
				end
			end
		end)
	end
end

-- **The built-in default hosts** ([LIVELY_MENU], user, 2026-10-29): the
-- default Starport, Aitta and Hearth (client/core/starport sets them)
-- count as accepted for the client's own fetches -- M.http_get and
-- M.http_post, the trusted side's, never M.safe's -- while it is on no
-- server (the launcher's Home, Apps from Aitta), so a fresh user sees what
-- is going on without a dialog. A host the managed file names or the user
-- typed is asked about as before. Sandboxed code gets nothing from this:
-- off a server with no storage of its own it asks as "" too, so the asker
-- does not say who is trusted; the entry point does.
local default_origins = {}
function M.set_default_hosts(urls)
	default_origins = {}
	for _, u in ipairs(urls) do
		local origin = tostring(u):match("^(https?://[^/?#]+)")
		if origin then default_origins[origin] = true end
	end
end
local function by_default(trusted, uri)
	return trusted == true and default_origins[uri] == true and
			__buildat_server_address() == nil
end
-- Whether a url's host is a default one that counts as accepted now
function M.is_default_host(url)
	local origin = tostring(url):match("^(https?://[^/?#]+)")
	return origin ~= nil and by_default(true, origin)
end

-- The user's leave for the url's host, then the fetch: a GET, or with a
-- body a POST of JSON
local function gated_http(server, url, cb, options, body, hops, trusted)
	-- The authority is what libcurl connects to, so it is what the user is
	-- asked about, port included: a host and a port and nothing else. A
	-- `user@` part or a backslash was read as one host here and another
	-- by libcurl ([SECURITY_RUN_1]).
	local scheme, authority = url:match("^(https?)://([^/?#]*)")
	if not scheme or authority == "" or
			not authority:match("^[%w%.%-]+$") and
			not authority:match("^[%w%.%-]+:%d+$") and
			not authority:match("^%[[%x:%.]+%]$") and
			not authority:match("^%[[%x:%.]+%]:%d+$") then
		cb(nil, "not an http(s) url with a plain host: "..url)
		return
	end
	local uri = scheme.."://"..authority
	-- A redirect is the engine's to report and ours to follow, through
	-- this same gate: libcurl following it went to a host the user never
	-- saw ([SECURITY_RUN_1]). GETs only, 8 at most; a POST's is an error.
	local user_cb = cb
	cb = function(got, err, redirect)
		if got or not redirect or body or (hops or 0) >= 8 then
			return user_cb(got, err)
		end
		local to = redirect
		if not to:match("^https?://") then
			return user_cb(nil, "a redirect to "..to.." is not followed")
		end
		gated_http(server, to, user_cb, options, nil, (hops or 0) + 1,
				trusted)
	end
	if by_default(trusted, uri) then
		http_start(url, cb, body)
		return
	end
	local entry = load_store()[key(server, uri)]
	if entry and entry.accepted and
			os.time() - entry.last_attempt < ACCEPTANCE_VALID_S then
		touch_entry(server, uri)
		http_start(url, cb, body)
		return
	end
	log:info("Asking the user about "..uri.." for \""..server.."\"")
	ask_user(server, uri, entry, function(accepted, description)
		store_answer(server, uri, accepted, description, entry)
		if not accepted then
			cb(nil, "Declined by user: "..uri)
			return
		end
		http_start(url, cb, body)
	end, type(options) == "table" and options.description or nil)
end

local function http_get(server, url, cb, options, trusted)
	if type(url) ~= "string" or type(cb) ~= "function" then
		error("network: http_get(url: string, cb: function)")
	end
	gated_http(server, url, cb, options, nil, nil, trusted)
end
function M.safe.http_get(url, cb, options)
	http_get(asking_server(), url, cb, options)
end
function M.http_get(url, cb, options)
	http_get("", url, cb, options, true)
end

-- http_post(url, body, cb[, options]): http_get's, a POST of the JSON
-- `body` ([STARPORT]: a report)
local function http_post(server, url, body, cb, options, trusted)
	if type(url) ~= "string" or type(body) ~= "string" or
			type(cb) ~= "function" then
		error("network: http_post(url: string, body: string, cb: function)")
	end
	gated_http(server, url, cb, options, body, nil, trusted)
end
function M.safe.http_post(url, body, cb, options)
	http_post(asking_server(), url, body, cb, options)
end
function M.http_post(url, body, cb, options)
	http_post("", url, body, cb, options, true)
end

-- The addresses this client has used, for a list to pick from: the
-- store's entries as {uri, description, created, last_attempt, accepted},
-- the last used first, an address once -- its last used row
-- simplified: an address another server's scripts were refused shows as
-- refused if that was the last asking; the list is the user's own, and
-- the consent is still asked per server.
function M.safe.known_addresses()
	local out = {}
	local latest = {}
	for _, e in pairs(load_store()) do
		local l = latest[e.uri]
		if not l or e.last_attempt > l.last_attempt then
			latest[e.uri] = e
		end
	end
	for uri, e in pairs(latest) do
		out[#out + 1] = {uri = uri, description = e.description or "",
				created = e.created or 0, last_attempt = e.last_attempt or 0,
				accepted = e.accepted and true or false, name = e.name or "",
				icon = e.icon or ""}
	end
	table.sort(out, function(a, b) return a.last_attempt > b.last_attempt end)
	return out
end

-- unseen_counts(cb): **the notifications waiting** on each server this
-- client keeps a login for ([FORUM] 4, the launcher's way in): a POST of
-- the kept login (the accounts builtin's "name" and "token", in the
-- server's storage) to the server's /unseen, which a Hearth answers;
-- cb(address, count) for each that does. Only to the address that gave
-- the login, so no dialog; a server that is not a Hearth answers 404.
-- simplified: native only -- the web's fetch needs CORS from the Hearth
-- -- and the addresses joined by tcp, not a local app's
function M.safe.unseen_counts(cb)
	local user = __buildat_get_path("user")
	local function read(path)
		local f = io.open(path, "rb")
		if not f then return "" end
		local s = f:read("*a") or ""
		f:close()
		return s
	end
	for _, a in ipairs(M.safe.known_addresses()) do
		local address = a.uri:match("^tcp://(.+)$")
		if address and a.accepted then
			local dir = user .. "/servers/" ..
					address:gsub("[^%w%-%.]", "_")
			local name, token = read(dir .. "/name"), read(dir .. "/token")
			if name ~= "" and token ~= "" then
				http_start("http://" .. address .. "/unseen", function(body)
					local r = body and M.safe.parse_json(body)
					if type(r) == "table" and type(r.unseen) == "number" then
						cb(address, r.unseen)
					end
				end, M.safe.write_json({name = name, token = token}))
			end
		end
	end
end

-- remember_server(uri[, sha]): a server the client joined, its row made
-- if the address has none and touched if it has ([JOINED_TLS_SERVERS]):
-- "tcp://host:port", or "https://host:port" behind TLS. sha is the icon
-- the client kept under the cache at connect ([LAUNCH_WORLD] (4)). The
-- trusted side's alone: a server's script must not name what a row wears.
function M.remember_server(uri, sha)
	if type(uri) ~= "string" or not (uri:match("^tcp://[%w%.%-:%[%]]+$") or
			uri:match("^https://[%w%.%-:%[%]]+$")) or (sha ~= nil and
			(type(sha) ~= "string" or not sha:match("^%x+$") or #sha ~= 64)) then
		return false
	end
	local entries = load_store(true)
	local e = entries[key("", uri)]
	local now = os.time()
	if not e then
		e = {accepted = true, uri = uri, description = "", created = now,
				name = "", icon = "", server = ""}
		entries[key("", uri)] = e
	end
	e.last_attempt = now
	if sha then
		e.icon = sha
	end
	save_store(entries)
	-- What a check waits for: the row is in the file
	log:info("network: the server " .. uri .. " remembered")
	return true
end

-- set_address_name(uri, name): the player name used on a server, kept on
-- its rows for the next connect screen; a uri with no row is ignored
function M.safe.set_address_name(uri, name)
	if type(uri) ~= "string" or type(name) ~= "string" or #name > 64 then
		return false
	end
	local entries = load_store(true)
	local found = false
	for _, e in pairs(entries) do
		if e.uri == uri then
			e.name = name
			found = true
		end
	end
	if found then
		save_store(entries)
	end
	return found
end

-- parse_json(text) -> table or nil, error: the module's own reader
-- (json.lua beside this file), which defines onto a `core` table
local parse_json, write_json
do
	local saved = rawget(_G, "core")
	rawset(_G, "core", {log = function(_, message) log:warning(message) end})
	dofile(__buildat_extension_path("network").."/json.lua")
	parse_json, write_json = core.parse_json, core.write_json
	rawset(_G, "core", saved)
end
function M.safe.parse_json(text)
	return parse_json(text, nil, true)
end
-- write_json(value[, styled]) -> text, or nil and why not; styled is
-- indented, for a file a person reads
function M.safe.write_json(value, styled)
	return write_json(value, styled == true)
end

-- LuaSocket's socket.gettime()
function M.safe.gettime()
	return buildat.get_time_us() / 1000000
end

M.gettime = M.safe.gettime
M.known_addresses = M.safe.known_addresses
M.set_address_name = M.safe.set_address_name
M.parse_json = M.safe.parse_json
M.write_json = M.safe.write_json

return M
-- vim: set noet ts=4 sw=4:
