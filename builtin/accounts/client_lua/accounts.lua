-- Buildat: builtin/accounts/client_lua/accounts.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The join, and the account calls a game's pages make ([VANILLA_PUBLIC] 2;
-- the server's side is builtin/accounts). A game loads this, sets the hooks
-- it wants, and calls start():
--
--   local ok, err, accounts = buildat.run_script_file("accounts/accounts.lua")
--   accounts.on_joined = function(name) ... end
--   accounts.start({title = "Floor planner", env = "BUILDAT_FP"})
--
-- Hooks, each optional:
--   on_joined(name)        in; what the game shows next is its own
--   on_users()             accounts.users changed (an admin's)
--   on_admin_result(text)  what an admin request did; also accounts.message
--   on_passwd(text)        "" when the password was changed, else why not
--   on_kicked(text)        before the server drops the connection
--   notice(text)           a line the game shows; the log's by default
-- A scripted client joins by the environment: <env>_NAME, <env>_PASSWORD,
-- <env>_CODE and <env>_TOTP, or by a Starport ID's token in <env>_STARPORT;
-- <env>_CREATE=1 makes the account (else an unknown name is refused).
-- (env is "BUILDAT_JOIN" by default).
local log = buildat.Logger("accounts")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local ui_utils = require("buildat/extension/ui_utils")
local rgb = (ui_utils.safe or ui_utils).rgb

local M = {
	hello = {},
	logged_in = false,
	name = nil,
	-- What the server said last of its accounts, invites, bans and
	-- registration (an admin's), and of the last admin request
	users = nil,
	message = nil,
}

local TEXT = {"object", {"text", "string"}}
-- [ACCOUNT_CREATE]: a leading version byte, then "create" at the end; add
-- version-gated fields rather than breaking the format again
local LOGIN = {"object", {"version", "byte"}, {"name", "string"},
		{"password", "string"}, {"code", "string"}, {"token", "string"},
		{"keep", "byte"}, {"totp", "string"}, {"starport", "string"},
		{"create", "byte"}}
local TOTP_REQ = {"object", {"cmd", "string"}, {"code", "string"}}
local TOTP_RESULT = {"object", {"error", "string"}, {"secret", "string"},
		{"uri", "string"}, {"on", "byte"}}
local LOGIN_RESULT = {"object", {"r", {"object", {"error", "string"},
		{"token", "string"}}}, {"name", "string"}}
local HELLO = {"object", {"local", "byte"}, {"setup", "byte"},
		{"open_registration", "byte"}, {"starport", "byte"},
		{"announce", "byte"}, {"version", "string"}}
local ADMIN = {"object", {"cmd", "string"}, {"name", "string"},
		{"arg", "string"}, {"on", "byte"}}
local USERS = {"object",
	{"users", {"array", {"object", {"name", "string"},
			{"privs", {"array", "string"}}, {"here", "byte"},
			{"id_only", "byte"}, {"level", "int32_t"},
			-- [FP_ABUSE] 5: what the apps keep for it
			{"storage", "string"}}}},
	-- Invite and AccessSettings are the stored records ([COMPAT_BREAK_07])
	{"invites", {"array", {"object", {"code", "string"},
			{"invite", {"record", 1, 0, {"object",
			{"privs", {"array", "string"}}, {"by", "string"}}}}}}},
	{"access", {"record", 1, 0, {"object", {"open_registration", "byte"}}}},
	{"bans", {"array", {"object", {"name", "string"}, {"address", "string"}}}},
	-- [STARPORT] 10g: Starport IDs off, anyone or approved; those waiting
	{"starport_ids", "string"},
	{"approvals", {"array", "string"}},
	-- [TRUST_LADDER] The viewer's level
	{"level", "int32_t"},
	-- [FP_ABUSE] 3: the storage budget in MB, and what all apps keep
	{"budget_mb", "int32_t"},
	{"storage", "string"},
}

-- [TRUST_LADDER] The trust levels' names, as builtin/accounts/api.h's
-- level_name() says them; changed together. An app's pages say them by
-- M.level_name.
local LEVEL_NAMES = {{40, "Host"}, {30, "Steward"}, {20, "Keeper"},
		{10, "Resident"}, {0, "Guest"}}
function M.level_name(lv)
	for _, x in ipairs(LEVEL_NAMES) do
		if lv >= x[1] then
			return x[2]
		end
	end
	return LEVEL_NAMES[#LEVEL_NAMES][2]
end

-- An app's JSON requests: "<p>:req" {cmd, id, ...} out, "<p>:res" {id, ok,
-- result or error} back. Returns req(cmd, args, on, on_error): on(result)
-- on success; a failure goes to on_error(why) when given, else fail(why).
-- log: each answer logged as "<p>: ...", for a check to read
function M.requester(p, fail, log_them)
	local write_json = require("buildat/extension/network").write_json
	local next_id, waiting = 1, {}
	buildat.sub_packet(p .. ":res", function(data)
		local res = buildat.parse_json(data)
		if type(res) ~= "table" then
			return
		end
		if log_them then
			log:info(p .. ": " .. data)
		end
		local on = waiting[res.id]
		waiting[res.id] = nil
		if not res.ok then
			return (on and on[2] or fail)(tostring(res.error))
		end
		if on then
			on[1](res.result)
		end
	end)
	return function(cmd, args, on, on_error)
		local q = args or {}
		q.cmd, q.id = cmd, next_id
		waiting[next_id] = {on or function() end, on_error}
		next_id = next_id + 1
		buildat.send_packet(p .. ":req", write_json(q))
	end
end

local opts = {}
local window = nil
-- The account page open, for the packets that redraw it; see M.users_page
local page_kind, page_back, users_page, passwd_page = nil, nil, nil, nil
local account_page
local ban_page
-- The Server window ([SERVER_ADMIN_PAGE]), below; its state and the
-- functions the pages above it call
local sw = {}
local draw_sidebar, server_element, server_close, sidebar_need, server_entries
local health_page, health_capture
-- The Starport panel open: "starports", "listing" or "ids"
local starport_page, sp_panel
-- [ACCOUNT_BUTTON]: the corner button, whether an app turned it off, and the
-- shower (forward-declared: the login handler above its definition calls it)
local account_button, account_button_off = nil, false
local show_account_button

local function notice(text)
	if M.notice then
		M.notice(text)
	else
		log:info(text)
	end
end

-- **Keep me logged in** ([ACC_KEEP]): the token a login asked to be kept
-- got, in the client's storage for this server, which the next hello logs
-- in with and asks nothing
local token_tried = false

-- The last login sent, for the TOTP code it may turn out to need
local last_login = nil

-- The ID token of a login that links it to the account ([ID_CLAIM_ACCOUNT]:
-- a name and a token both), or nil
local function claim_token()
	local l = last_login
	return l and (l[1] or "") ~= "" and (l[6] or "") ~= "" and l[6] or nil
end

-- What a field is for, for a browser's password manager: the web client
-- gives it to the page's input as its autocomplete ([LOGIN_UNLOADED])
local function purpose(e, what)
	e:SetVar("autocomplete", what)
end

-- **A login waiting on its TOTP code** ([LOGIN_UNLOADED]): the server's
-- token for it is kept in the client's storage at once, so a page the
-- browser unloaded while its user was in the authenticator app comes back
-- to the code page; the password is never kept
local function totp_wait()
	return buildat.storage_read("totp_wait") or ""
end

-- [ID_AUTO_JOIN]: the next join here asks, not the Starport ID
local function forget_id_here()
	local ok, starport = pcall(require, "buildat/extension/starport")
	if ok and starport.forget_id_here then
		starport.forget_id_here()
	end
end

local function send_login(name, password, code, token, keep, totp, starport,
		create)
	last_login = {name, password, code, token, keep, starport, create}
	buildat.send_packet("accounts:login", cereal.binary_output(
			{version = 1, name = name, password = password, code = code or "",
			token = token or "", keep = keep and 1 or 0, totp = totp or "",
			starport = starport or "", create = create and 1 or 0}, LOGIN))
end
M.send_login = send_login

-- simplified: never emptied (the sandbox has no weak tables); a handle
-- or two per page opened
local page_windows = {}

-- A window of the join: `width` wide, or the screen's width less a margin
-- on a narrow one ([FP_TOUCH] 2), and its texts wrap to it. `top`: at the
-- screen's top, its full width less the margin ([CHAT_FIELD_TOUCH])
local function page_window(width, top)
	local w = magic.ui.root:CreateChild("Window")
	-- Its own style, for a game whose root has none (vanilla's world); what
	-- is in it finds the style through it
	w.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	w:SetStyleAuto()
	-- Over a game's HUD, such as the Luanti hotbar (priority 10)
	w.priority = 100
	w:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(16, 16, 16, 16))
	w:SetAlignment(magic.HA_CENTER, top and magic.VA_TOP or magic.VA_CENTER)
	if top then
		w:SetPosition(0, 8)
		width = magic.ui.root.width
	end
	w:SetFixedWidth(math.min(width, magic.ui.root.width - 16))
	-- By the keyboard, every page of it ([MENU_KEYS])
	ui_utils.keyboard_page(w)
	page_windows[w] = true
	return w
end
M.page_window = page_window

local function page_text(w, t, color)
	local l = w:CreateChild("Text")
	l:SetStyleAuto()
	l:SetWordwrap(true)
	if page_windows[w] then
		l:SetFixedWidth(w.width - 32)
	end
	l:SetText(t)
	if color then
		l:SetColor(color)
	end
	return l
end
M.page_text = page_text

function M.close()
	if window then
		window:Remove()
		window = nil
	end
end

-- simplified: the join dialog is rebuilt on every error rather than
-- updated
-- **The TOTP code** ([STARPORT] 10a): asked after the password was right,
-- and sent with the same login again
local function show_totp(error_text)
	M.close()
	local w = page_window(380)
	window = w
	page_text(w, "Code from your authenticator app")
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	purpose(e, "one-time-code")
	if error_text and error_text ~= "" then
		page_text(w, error_text, magic.Color(rgb("error")))
	end
	local function go()
		if totp_wait() ~= "" then
			return send_login(M.name or "", "", "", totp_wait(),
					buildat.storage_read("keep") == "1", e:GetText(),
					claim_token())
		end
		local l = last_login
		send_login(l[1], l[2], l[3], l[4], l[5], e:GetText(), l[6], l[7])
	end
	magic.SubscribeToEvent(e, "TextFinished", go)
	local b = w:CreateChild("Button")
	b:SetStyle("PrimaryButton")
	b.minHeight = 30
	local bt = b:CreateChild("Text")
	bt:SetStyleAuto()
	bt:SetText("Join")
	bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	magic.SubscribeToEvent(b, "Released", go)
	e:SetFocus(true)
end

local show_create -- [ACCOUNT_CREATE]: defined after show_login
local show_login

-- **"That's my account"** ([ID_CLAIM_ACCOUNT]): a Starport ID whose name
-- here is an account of this server's links to it by one login with the
-- account's password; `token` is the refused login's ID token, sent with
-- the password (and the code the server asks after)
-- simplified: the name is a label, not a field, so a password manager on
-- the web gets no name with the password
local function show_claim(name, token, error_text)
	M.close()
	local w = page_window(380)
	window = w
	page_text(w, "Log in to " .. name .. " to link your Starport ID")
	page_text(w, "Password")
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textCopyable = false
	e.textSelectable = true
	e.echoCharacter = string.byte("*")
	purpose(e, "current-password")
	if error_text and error_text ~= "" then
		page_text(w, error_text, magic.Color(rgb("error")))
	end
	local function go()
		M.name = name
		send_login(name, e:GetText(), "", nil,
				buildat.storage_read("keep") == "1", "", token)
	end
	magic.SubscribeToEvent(e, "TextFinished", go)
	local r = w:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 8, magic.IntRect(0, 0, 0, 0))
	for _, b in ipairs({{"Join", go}, {"Back", function() show_login(nil) end}}) do
		local bb = r:CreateChild("Button")
		if b[1] == "Join" then
			bb:SetStyle("PrimaryButton")
		else
			bb:SetStyleAuto()
		end
		bb.minHeight = 30
		bb:SetFocusMode(magic.FM_FOCUSABLE)
		local bt = bb:CreateChild("Text")
		bt:SetStyleAuto()
		bt:SetText(b[1])
		bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		magic.SubscribeToEvent(bb, "Released", b[2])
	end
	e:SetFocus(true)
end

show_login = function(error_text)
	M.close()
	local is_local = M.hello["local"] == 1
	local w = page_window(380)
	window = w
	local function label(text)
		return page_text(w, text)
	end
	local function field(text, secret)
		local e = w:CreateChild("LineEdit")
		e:SetStyleAuto()
		e.minHeight = 26
		e.textCopyable = not secret
		e.textSelectable = true
		if secret then
			e.echoCharacter = string.byte("*")
		end
		e:SetText(text)
		return e
	end
	-- The game, and what it runs on: "Floor planner | Buildat 0.5.8-bafe9fd8"
	-- (user, 2026-09-30)
	local version, hash = buildat.version()
	label((opts.title or "Join") .. " v." .. tostring(version) ..
			(hash and hash ~= "" and ("-" .. hash) or ""))
	-- Declared here for the Starport ID's button, made before them
	local password, code, keep, sb = nil, nil, nil, nil
	-- [KEEP_ON_TOP] Kept logged in or not, chosen first: it is for
	-- either way in below
	if not is_local then
		keep = {on = buildat.storage_read("keep") == "1"}
		local kb = w:CreateChild("Button")
		kb:SetStyleAuto()
		kb.minHeight = 30
		local kt = kb:CreateChild("Text")
		kt:SetStyleAuto()
		kt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local function draw_keep()
			kt:SetText((keep.on and "[x] " or "[ ] ") .. "Keep me logged in")
		end
		-- **By the keyboard too** (user, 2026-10-01): Tab reaches it after
		-- the fields, and a focused button is pressed by Space or Enter
		kb:SetFocusMode(magic.FM_FOCUSABLE)
		draw_keep()
		-- Written at once: the Starport ID's way in keeps it too
		magic.SubscribeToEvent(kb, "Released", function()
			keep.on = not keep.on
			buildat.storage_write("keep", keep.on and "1" or "0")
			draw_keep()
		end)
	end
	-- [STARPORT] 10c: a Starport ID in place of an account here; the
	-- token comes from the client's own Starport extension, which asks
	-- the Starport, so the password never comes here
	if M.hello.starport == 1 and not is_local then
		sb = w:CreateChild("Button")
		sb:SetStyleAuto()
		sb.minHeight = 30
		sb:SetFocusMode(magic.FM_FOCUSABLE)
		local st = sb:CreateChild("Text")
		st:SetStyleAuto()
		st:SetText("Sign in with your Starport ID")
		st:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		magic.SubscribeToEvent(sb, "Released", function()
			local ok, starport = pcall(require, "buildat/extension/starport")
			if not ok or not starport.id_token_here then
				-- The require's own error says why ([WEB_ID_NO_EXT]: a
				-- parse error on the web's Lua 5.1 read as "none")
				return show_login("This client's Starport extension did " ..
						"not load" .. (ok and "" or ": " .. tostring(starport)))
			end
			starport.id_token_here(function(token, why)
				if not token then
					return show_login(why ~= "cancelled" and why or nil)
				end
				-- With the setup code, the first admin is an ID (10g); and
				-- kept logged in as a local login is
				send_login("", "", "", nil, keep and keep.on, "", token)
			end)
		end)
		label("or with an account of this server:")
	end
	label("Name")
	-- The name used last on this server, kept on the client; else the one
	-- the user gave the client for every game, unless that is the client's
	-- own default, which is nobody's name (user, the sixth round)
	local default = buildat.get_preference("default_username")
	local name = field(buildat.storage_read("name") or
			(default ~= "User" and default) or "", false)
	purpose(name, "username")
	-- Kept as it is typed: a page unloaded meanwhile comes back with it
	magic.SubscribeToEvent(name, "TextChanged", function()
		buildat.storage_write("name", name:GetText())
	end)
	if is_local then
		-- The saves are on this machine: no password to ask
		label("On this computer: no password needed")
	else
		-- [ACCOUNT_CREATE]: the login window logs in only; making an account
		-- is its own window (show_create), with the setup/invite code and a
		-- password typed twice
		label("Password")
		password = field("", true)
		purpose(password, "current-password")
		if not buildat.connection_encrypted() then
			local warn = label("The password is sent unencrypted: use a " ..
					"trusted network")
			warn:SetColor(magic.Color(rgb("warn")))
		end
	end
	if error_text then
		local e = label(error_text)
		e:SetColor(magic.Color(rgb("error")))
	end
	local button = w:CreateChild("Button")
	button:SetStyle("PrimaryButton")
	button.minHeight = 30
	local bt = button:CreateChild("Text")
	bt:SetStyleAuto()
	bt:SetText("Join")
	bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local function join()
		local n = name:GetText()
		buildat.storage_write("name", n)
		buildat.storage_write("keep", keep and keep.on and "1" or "0")
		M.name = n
		send_login(n, password and password:GetText() or "",
				code and code:GetText() or "", nil, keep and keep.on)
	end
	-- and Join after it
	button:SetFocusMode(magic.FM_FOCUSABLE)
	magic.SubscribeToEvent(button, "Released", function() join() end)
	magic.SubscribeToEvent(name, "TextFinished", function()
		if password then
			password:SetFocus(true)
		else
			join()
		end
	end)
	if password then
		magic.SubscribeToEvent(password, "TextFinished", function()
			if code then
				code:SetFocus(true)
			else
				join()
			end
		end)
	end
	if code then
		magic.SubscribeToEvent(code, "TextFinished", function() join() end)
	end
	-- [ACCOUNT_CREATE]: making an account is its own window
	if not is_local then
		local cb = w:CreateChild("Button")
		cb:SetStyleAuto()
		cb.minHeight = 30
		cb:SetFocusMode(magic.FM_FOCUSABLE)
		local ct = cb:CreateChild("Text")
		ct:SetStyleAuto()
		ct:SetText("Create a new account")
		ct:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		magic.SubscribeToEvent(cb, "Released", function() show_create(nil) end)
	end
	-- Signed in to a Starport already: its button, so Return signs in
	-- ([STARPORT_LOGIN_FOCUS]); else the name, to type into
	local ok, starport = pcall(require, "buildat/extension/starport")
	if sb and ok and type(starport) == "table" and starport.has_id and
			starport.has_id() then
		sb:SetFocus(true)
	else
		name:SetFocus(true)
	end
	-- What a check waits for before it types
	log:info("accounts: the login page shown")
end

-- [ACCOUNT_CREATE]: the account-making window -- name, the password twice,
-- and the setup or invite code; the server makes the account only on create=1
function show_create(error_text)
	M.close()
	local w = page_window(380)
	window = w
	local function label(text)
		return page_text(w, text)
	end
	local function field(text, secret)
		local e = w:CreateChild("LineEdit")
		e:SetStyleAuto()
		e.minHeight = 26
		e.textCopyable = not secret
		e.textSelectable = true
		if secret then
			e.echoCharacter = string.byte("*")
		end
		e:SetText(text)
		return e
	end
	label("Create a new account")
	label("Name")
	local name = field(buildat.storage_read("name") or "", false)
	label("Password (at least 6 characters)")
	local password = field("", true)
	label("Password again")
	local password2 = field("", true)
	purpose(name, "username")
	purpose(password, "new-password")
	purpose(password2, "new-password")
	-- The server's first admin claims it with the code in the server's log;
	-- while registration is closed a new account needs an invite
	local code = nil
	if M.hello.setup == 1 then
		label("Setup code (see the server's log)")
		code = field("", false)
	elseif M.hello.open_registration ~= 1 then
		label("Invite code (from an admin)")
		code = field("", false)
	end
	if not buildat.connection_encrypted() then
		local warn = label("The password is sent unencrypted: use a trusted "..
				"network")
		warn:SetColor(magic.Color(rgb("warn")))
	end
	if error_text then
		local e = label(error_text)
		e:SetColor(magic.Color(rgb("error")))
	end
	local function create()
		local n = name:GetText()
		local pw = password:GetText()
		if pw ~= password2:GetText() then
			return show_create("The two passwords are not the same")
		end
		buildat.storage_write("name", n)
		M.name = n
		-- create=1: the server makes the account; a plain login would refuse
		-- an unknown name
		send_login(n, pw, code and code:GetText() or "", nil, nil, "", "", true)
	end
	local button = w:CreateChild("Button")
	button:SetStyle("PrimaryButton")
	button.minHeight = 30
	button:SetFocusMode(magic.FM_FOCUSABLE)
	local bt = button:CreateChild("Text")
	bt:SetStyleAuto()
	bt:SetText("Create account")
	bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	magic.SubscribeToEvent(button, "Released", function() create() end)
	local back = w:CreateChild("Button")
	back:SetStyleAuto()
	back.minHeight = 30
	back:SetFocusMode(magic.FM_FOCUSABLE)
	local backt = back:CreateChild("Text")
	backt:SetStyleAuto()
	backt:SetText("Back to login")
	backt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	magic.SubscribeToEvent(back, "Released", function() show_login(nil) end)
	name:SetFocus(true)
end

-- [WEB_ID_TRUST]: the Starports this server is listed on, for a web
-- client's sign-in window (the extension takes them on the web only)
buildat.sub_packet("starport:where", function(data)
	-- The web checks wait for this line
	log:info("starport:where: " .. #data .. " bytes")
	local ok, starport = pcall(require, "buildat/extension/starport")
	if ok and starport.set_web_starports then
		starport.set_web_starports(buildat.parse_json(data))
	end
end)

buildat.sub_packet("accounts:hello", function(data)
	M.hello = cereal.binary_input(data, HELLO)
	if draw_sidebar then
		draw_sidebar()
	end
	log:info("hello: Starport IDs " ..
			(M.hello.starport == 1 and "taken" or "not taken"))
	if M.hello.starport == 1 then
		buildat.send_packet("starport:where_get", "")
	end
	-- Said again when an admin changes who may register: a user who has
	-- joined already has nothing to do with it
	if M.logged_in then
		return
	end
	-- A scripted or second client can skip the dialog
	local env = opts.env or "BUILDAT_JOIN"
	local auto_name = buildat.get_env(env .. "_NAME")
	-- A Starport ID's token, as a check gets one from the Starport's API
	local auto_starport = buildat.get_env(env .. "_STARPORT")
	-- With a name and a password too, "That's my account"'s login
	if auto_starport and auto_starport ~= "" and not M.auto_tried then
		M.auto_tried = true
		M.name = auto_name
		send_login(auto_name or "", buildat.get_env(env .. "_PASSWORD") or "",
				buildat.get_env(env .. "_CODE") or "", nil,
				buildat.get_env(env .. "_KEEP") == "1",
				buildat.get_env(env .. "_TOTP") or "", auto_starport)
		return
	end
	local token = buildat.storage_read("token") or ""
	if auto_name and not M.auto_tried then
		M.auto_tried = true
		M.name = auto_name
		send_login(auto_name, buildat.get_env(env .. "_PASSWORD") or "",
				buildat.get_env(env .. "_CODE") or "", nil,
				buildat.get_env(env .. "_KEEP") == "1",
				buildat.get_env(env .. "_TOTP") or "", "",
				buildat.get_env(env .. "_CREATE") == "1")
	elseif totp_wait() ~= "" then
		-- Back at the code, if the server still waits for it
		M.name = buildat.storage_read("name") or ""
		log:info("Asking whether the login as " .. M.name .. " waits for its code")
		send_login(M.name, "", "", totp_wait(),
				buildat.storage_read("keep") == "1")
	elseif token ~= "" and not token_tried then
		token_tried = true
		M.name = buildat.storage_read("name") or ""
		log:info("Logging in as " .. M.name .. " with the kept login")
		send_login(M.name, "", "", token)
	elseif M.hello.starport == 1 and M.hello["local"] ~= 1 and
			not M.id_join_tried then
		-- Joined by the client's own "Discuss", or the ID signed in here
		-- last time ([ID_AUTO_JOIN]): the Starport ID first, the dialog
		-- only when that does not give a token
		M.id_join_tried = true
		local ok, starport = pcall(require, "buildat/extension/starport")
		local discuss = ok and starport.take_id_join and starport.take_id_join()
		local used = ok and starport.id_used_here and starport.id_used_here()
		if not (discuss or used) then
			return show_login(nil)
		end
		log:info("Signing in with the Starport ID")
		starport.id_token_here(function(token, why)
			if not token then
				return show_login(why ~= "cancelled" and why or nil)
			end
			send_login("", "", "", nil, false, "", token)
		end)
	else
		show_login(nil)
	end
end)

buildat.sub_packet("accounts:login_result", function(data)
	local outer = cereal.binary_input(data, LOGIN_RESULT)
	local r = outer.r
	if outer.name ~= "" then
		M.name = outer.name
	end
	local err = r.error
	if err ~= "" then
		log:info("Login refused: " .. err)
		-- A kept login that did not work is forgotten
		if token_tried then
			buildat.storage_write("token", "")
		end
		-- The wait kept for a code until it is used or ended
		if r.token ~= "" and err:sub(1, 5) == "TOTP:" then
			buildat.storage_write("totp_wait", r.token)
			buildat.storage_write("name", M.name or "")
		elseif err:sub(1, 5) ~= "TOTP:" then
			buildat.storage_write("totp_wait", "")
		end
		if err:sub(1, 5) == "TOTP:" and (last_login or totp_wait() ~= "") then
			show_totp(err == "TOTP: enter the code from your authenticator "..
					"app" and "" or err:sub(7))
			return
		end
		-- A Starport ID whose name here is a local account's: another
		-- name for this community, asked here, and the login again
		if last_login and (last_login[6] or "") ~= "" and
				err:find("is taken on this server", 1, true) then
			local ok, starport = pcall(require, "buildat/extension/starport")
			if ok and starport.id_token_here then
				local code, keep = last_login[3], last_login[5]
				local refused = last_login[6]
				local name = err:match("^The name (%S+) is taken")
				starport.id_token_here(function(token, why)
					if why == "mine" and name then
						return show_claim(name, refused)
					end
					if not token then
						return show_login(why ~= "cancelled" and why or nil)
					end
					send_login("", "", code, nil, keep, "", token)
				end, "The name you have in this community is taken here by "..
						"an account of this server. Pick another; it is kept "..
						"for this community on the Starport. If that account "..
						"is yours, choose \"That's my account\" and log in "..
						"with its password: your ID is linked to it, and logs "..
						"in as it from then on.")
				return
			end
		end
		-- A wrong password of "That's my account" asks again there
		if claim_token() then
			return show_claim(last_login[1], claim_token(), err)
		end
		show_login(err)
		return
	end
	buildat.storage_write("totp_wait", "")
	if r.token ~= "" then
		buildat.storage_write("token", r.token)
		-- A Starport ID's name comes from the server
		buildat.storage_write("name", M.name or "")
	end
	M.logged_in = true
	M.close()
	magic.ui:SetFocusElement(nil)
	log:info("Joined as " .. tostring(M.name))
	-- A login that was not an ID's: the next join asks, not the ID
	-- ([ID_AUTO_JOIN])
	if last_login and (last_login[6] or "") == "" then
		forget_id_here()
	end
	-- A scripted admin's requests, a line each, "cmd name [arg]" -- what a
	-- check does as an admin (<env>_ADMIN; the server checks the admin);
	-- "setting open_registration on" turns a setting on
	local admin = buildat.get_env((opts.env or "BUILDAT_JOIN") .. "_ADMIN")
	if admin and admin ~= "" and not M.admin_sent then
		M.admin_sent = true
		for l in admin:gmatch("[^\n]+") do
			local cmd, name, arg = l:match("^(%S+)%s*(%S*)%s*(.*)$")
			if cmd then
				-- Each but "list" has one admin_result, counted for the
				-- check's "admin script: done"
				if cmd ~= "list" then
					M.admin_left = (M.admin_left or 0) + 1
				end
				M.admin(cmd, name, arg, cmd == "priv" or arg == "on")
			end
		end
	end
	-- A scripted client's ntfy requests, "cmd [url]" a line each
	-- (<env>_NTFY)
	local ntfy = buildat.get_env((opts.env or "BUILDAT_JOIN") .. "_NTFY")
	if ntfy and ntfy ~= "" and not M.ntfy_sent then
		M.ntfy_sent = true
		for l in ntfy:gmatch("[^\n]+") do
			local cmd, url = l:match("^(%S+)%s*(.*)$")
			if cmd then
				buildat.send_packet("accounts:ntfy", cereal.binary_output(
						{cmd, url}, {"array", "string"}))
			end
		end
	end
	if M.on_joined then
		M.on_joined(M.name)
	end
	-- [ACCOUNT_BUTTON]: the corner way in, unless the app placed its own
	-- (it calls M.no_account_button(), by now if so)
	show_account_button()
end)

buildat.sub_packet("accounts:users", function(data)
	M.users = cereal.binary_input(data, USERS)
	log:info(#M.users.users .. " accounts listed")
	if page_kind == "users" then
		users_page(page_back)
	end
	-- [ACCOUNT_BUTTON]: the list arriving means this client is an admin, so
	-- account_page can now show its "Accounts..." button
	if page_kind == "account" then
		account_page(page_back)
	end
	-- The list says admin: the Server window's Admin entries, and the
	-- page it was opened at if that was one
	if sw.frame then
		local wanted = sw.wanted
		sw.wanted = nil
		if not (wanted and M.server_show(wanted)) then
			draw_sidebar()
		end
	end
	if page_kind == "starport" and sp_panel == "ids" then
		starport_page(page_back, "ids")
	end
	if M.on_users then
		M.on_users()
	end
end)

buildat.sub_packet("accounts:admin_result", function(data)
	M.message = cereal.binary_input(data, TEXT).text
	log:info("admin result: " .. M.message)
	if (M.admin_left or 0) > 0 then
		M.admin_left = M.admin_left - 1
		if M.admin_left == 0 then
			log:info("admin script: done")
		end
	end
	if page_kind == "users" then
		users_page(page_back)
	end
	if page_kind == "health" then
		health_page(page_back)
	end
	if M.on_admin_result then
		M.on_admin_result(M.message)
	end
end)

buildat.sub_packet("accounts:passwd_result", function(data)
	local text = cereal.binary_input(data, TEXT).text
	if page_kind == "passwd" then
		passwd_page(page_back, text == "" and "The password was changed" or
				text)
	end
	if M.on_passwd then
		M.on_passwd(text)
	end
end)

buildat.sub_packet("accounts:link_result", function(data)
	local text = cereal.binary_input(data, TEXT).text
	text = text == "" and "The Starport ID is linked: it logs in as this "..
			"account now" or text
	log:info("link result: " .. text)
	if page_kind == "account" then
		account_page(page_back, text)
	else
		notice(text)
	end
end)

-- The Starports this account has IDs linked from ([ID_CLAIM_ACCOUNT] 5)
M.links = {}
buildat.sub_packet("accounts:links", function(data)
	M.links = {}
	for l in cereal.binary_input(data, TEXT).text:gmatch("[^\n]+") do
		M.links[#M.links + 1] = l
	end
	log:info("linked Starport IDs: " .. table.concat(M.links, " "))
	if page_kind == "account" then
		account_page(page_back)
	end
end)

buildat.sub_packet("accounts:kicked", function(data)
	local text = cereal.binary_input(data, TEXT).text
	notice(text)
	-- [LEAVE_WITH_REASON]: the server drops the connection next, and the
	-- client's leave to the launcher says this
	buildat.set_leave_reason(text)
	if M.on_kicked then
		M.on_kicked(text)
	end
end)

-- An admin's request: list, priv, kick, ban, unban, password, delete, add,
-- invite, uninvite, setting
function M.admin(cmd, name, arg, on)
	log:info("admin request: " .. cmd)
	buildat.send_packet("accounts:admin", cereal.binary_output({cmd = cmd,
			name = name or "", arg = arg or "", on = on and 1 or 0}, ADMIN))
end

-- Whether this client has a kept login on this server
function M.kept()
	return (buildat.storage_read("token") or "") ~= ""
end

-- The kept login ended, on the server and here, and the client off the
-- server, back to the launcher if it came from one: the next join asks
-- again
function M.logout()
	forget_id_here()
	local token = buildat.storage_read("token") or ""
	if token ~= "" then
		buildat.send_packet("accounts:logout",
				cereal.binary_output({text = token}, TEXT))
	end
	buildat.storage_write("token", "")
	buildat.storage_write("keep", "0")
	buildat.leave()
end

-- [STARPORT_CLOSE] An app's own way out: "Exit to launcher?", Exit
-- logging out. Only where leave() goes to a launcher (can_exit): on the
-- web page or a client started with -s there is nothing to exit to
function M.can_exit()
	return buildat.can_leave_to_launcher() == true
end
function M.ask_exit()
	M.asking_exit = true
	log:info("accounts: exit dialog")
	local confirm = (ui_utils.safe or ui_utils).show_confirm_dialog
	confirm("Exit to launcher?", M.logout,
			function()
				M.asking_exit = false
				-- What a check waits for
				log:info("accounts: the exit cancelled")
			end, "Exit", "Cancel",
			{yes_focused = true, yes_keys = {magic.KEY_E, magic.KEY_Q},
			priority = 200})
end

function M.passwd(old, new)
	buildat.send_packet("accounts:passwd", cereal.binary_output(
			{old = old, new = new}, {"object", {"old", "string"},
			{"new", "string"}}))
end

--
-- The account pages ([VANILLA_PUBLIC] 2): a user's own password, and an
-- admin's users, invites, bans and registration. Each game opens them from
-- its own pause menu, and `back` is what their Back goes to. M.page is the
-- page open, for the game's hit tests; M.close_page() closes it.
--
local function row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	return r
end

-- main: the screen's one main button, amber ([MENU_BRAND])
local function button(parent, text, on_click, main)
	local b = parent:CreateChild("Button")
	if main then b:SetStyle("PrimaryButton") else b:SetStyleAuto() end
	b.minHeight = 28
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(text)
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = t.width + 24
	magic.SubscribeToEvent(b, "Released", function() on_click() end)
	return b
end
-- For a game's own pages in the same look: vanilla's pause menu
M.page_button = button

-- on_finish: optional; value: the text it starts with
local function field(parent, label, secret, on_finish, value)
	local r = row(parent)
	local l = page_text(r, label)
	l:SetWordwrap(false)
	l.minWidth = 100
	local e = r:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.minWidth = 160
	e.textSelectable = true
	if secret then
		e.echoCharacter = string.byte("*")
	else
		e.textCopyable = true
	end
	if on_finish then
		magic.SubscribeToEvent(e, "TextFinished", function() on_finish() end)
	end
	e:SetText(value or "")
	return e
end
-- The same look for a game's pages: Starport's, Aitta's
M.page_row = row
M.page_field = field

local WARN = magic.Color(rgb("warn"))

--
-- "Open to LAN" ([SECURITY_RUN_1], the user's call; [ACCOUNTS_LAN]): the
-- launcher's server listens on this machine only until its owner opens it
-- here, from the Server window or an app's own page (M.lan_row(w)).
-- M.lan is nil, "opening", or what the server answered: "1", or why not.
--
M.lan = nil
-- The row shown last, filled again when the answer comes
local lan_shown = nil

local function lan_text()
	if M.lan == "opening" then
		return "Opening to the LAN..."
	elseif M.lan ~= "1" then
		return "Not opened to the LAN: " .. tostring(M.lan)
	end
	local port = buildat.local_server_state()
	local ip = buildat.lan_address()
	if ip and port then
		return "Open to the LAN at " .. ip .. ":" .. port
	end
	return "Open to the LAN" .. (port and (", port " .. port) or "")
end

local function lan_fill(r)
	r.el:RemoveAllChildren()
	local failed = M.lan ~= nil and M.lan ~= "1" and M.lan ~= "opening"
	if M.lan == nil or failed then
		button(r.el, "Open to LAN", function()
			M.lan = "opening"
			buildat.send_packet("accounts:open_lan", "")
			lan_fill(r)
		end)
	end
	if M.lan ~= nil then
		local l = page_text(r.el, lan_text(), failed and WARN or nil)
		if page_windows[r.w] then
			l:SetFixedWidth(r.w.width - 32)
		end
	end
end

-- The button, then what it came to, in `w`: a page of the Server window
-- or an app's own (vanilla's pause menu)
function M.lan_row(w)
	local el = w:CreateChild("UIElement")
	el:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	lan_shown = {el = el, w = w}
	lan_fill(lan_shown)
end

-- **Server, in the game's settings window** ([GAME_SETTINGS]): Open to
-- LAN for the owner, and the Server window, which comes back to it
buildat.add_game_settings_section("accounts", {title = "Server",
		draw = function(w, ui)
	if M.hello and M.hello["local"] == 1 then
		M.lan_row(w)
	end
	ui.button("Server...", function()
		ui.away(function(back)
			M.server_window(nil, back)
			-- Its Escape is its own here: the game opened the settings
			local sub
			sub = magic.SubscribeToEvent("KeyDown", function(_, data)
				if not M.frame then
					magic.UnsubscribeFromEvent("KeyDown", sub)
				elseif data:GetInt("Key") == magic.KEY_ESCAPE then
					M.back()
				end
			end)
		end)
	end)
end})

buildat.sub_packet("accounts:lan", function(data)
	M.lan = data
	log:info("Open to LAN: " .. lan_text())
	if lan_shown then
		-- simplified: a row since removed is filled to no effect
		pcall(lan_fill, lan_shown)
	end
end)

-- The Starport page's listing as being edited, kept over its redraws (a
-- dropdown's choice redraws it); nil to take the server's config again
local draft = nil
local DIM = magic.Color(rgb("dim"))

-- **A server's settings as rows** ([AITTA_SETTINGS_PAGE]): Starport's and
-- Aitta's Settings page. Each setting of `set` by name with its JSON in a
-- field, `notes[name]` a dim line under it; Enter gives save(name, value),
-- or bad(name, error) for a text that is not JSON.
function M.settings_rows(page, set, notes, save, bad)
	local encode = require("buildat/extension/network").write_json
	page_text(page, "Each value is JSON; Enter in a field saves it.", DIM)
	local keys = {}
	for k in pairs(set) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local r = row(page)
		local name = page_text(r, k)
		name:SetWordwrap(false)
		name.minWidth = 160
		local e = r:CreateChild("LineEdit")
		e:SetStyleAuto()
		e.minHeight = 26
		e.minWidth = 420
		e.textSelectable = true
		e.textCopyable = true
		e:SetText(encode(set[k]))
		magic.SubscribeToEvent(e, "TextFinished", function()
			local v, err = buildat.parse_json(e:GetText())
			if v == nil and e:GetText() ~= "null" then
				return bad(k, err)
			end
			save(k, v)
		end)
		if notes and notes[k] then
			page_text(page, notes[k], DIM)
		end
	end
end

local chat_list = nil
-- The width a line of the chat wraps to: the page's less its margins and
-- the list's scroll bar
local chat_width = 100

local function drop_page()
	-- What was typed on the Health page, kept over its redraws
	if page_kind == "health" then
		health_capture()
	end
	if M.page then
		-- An app may have removed the element already (its own page_element
		-- replaced it); a raw handle does not keep it alive, so Remove on the
		-- freed one must not abort the caller
		pcall(function() M.page:Remove() end)
		M.page = nil
	end
	page_kind = nil
	chat_list = nil
end

-- The page open closed; and the Server window, unless it is the app's own
-- (a game's "My account..." opened it)
function M.close_page()
	drop_page()
	if sw.frame and sw.on_close then
		server_close(true)
	end
end

-- `help`, a function, puts a Help button at the title's right; a nil
-- title puts none. `top`: page_window's.
local function open_page(kind, title, back, width, help, top)
	drop_page()
	page_kind, page_back = kind, back
	-- In the Server window while it is up; else an app with a window of
	-- its own for its pages sets M.page_parent(width) to give what a page
	-- is drawn into
	M.page = sw.frame and server_element() or M.page_parent and
			M.page_parent(width or 560) or page_window(width or 560, top)
	if not title then
	elseif help then
		local r = M.page:CreateChild("UIElement")
		r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
		local t = page_text(r, title)
		t:SetWordwrap(false)
		local b = button(r, "Help", help)
		b:SetFixedWidth(b.minWidth)
		-- The title takes the rest of the row, which puts Help at its end
		t:SetFixedWidth(M.page.width - 32 - b.minWidth - 4)
	else
		page_text(M.page, title)
	end
	return M.page
end

-- Nothing at the top of a Server window that is the app's own
local function go_back()
	local back = page_back
	if back then
		drop_page()
		M.message = nil
		back()
	end
end
-- [ESC_ACCOUNT]: My account, in the Server window, as the top right
-- Account button opens it; `back` is what its Back draws again (nothing:
-- it closes)
M.show_account = function(back)
	M.server_window("account", back or function() end)
end

-- A user's own password; `message` is what the last change came to
passwd_page = function(back, message)
	local w = open_page("passwd", "Change password", back)
	if message then
		page_text(w, message, WARN)
	end
	local old, new1, new2
	local function change()
		if new1:GetText() ~= new2:GetText() then
			return passwd_page(back, "The new passwords differ")
		end
		M.passwd(old:GetText(), new1:GetText())
	end
	old = field(w, "Old", true, function() new1:SetFocus(true) end)
	new1 = field(w, "New", true, function() new2:SetFocus(true) end)
	new2 = field(w, "New again", true, change)
	local r = row(w)
	button(r, "Change", change)
	button(r, "Back", go_back)
	old:SetFocus(true)
end
M.password_page = function(back) passwd_page(back) end

-- A QR code of `text` for an authenticator app's camera ([STARPORT] 10a),
-- drawn at 6 pixels a module with the quiet zone round it: scaled down by
-- the UI it stays readable
local function qr_image(parent, text)
	local bits, n = buildat.qr_code(text)
	if not bits then
		return nil
	end
	local px, quiet = 6, 4
	local side = (n + 2 * quiet) * px
	local rows = {}
	for y = 0, side - 1 do
		local row = {}
		local my = math.floor(y / px) - quiet
		for x = 0, side - 1 do
			local mx = math.floor(x / px) - quiet
			local dark = mx >= 0 and my >= 0 and mx < n and my < n and
					bits:byte(my * n + mx + 1) == 49
			row[#row + 1] = dark and "\0\0\0" or "\255\255\255"
		end
		rows[#rows + 1] = table.concat(row)
	end
	local img = magic.Image:new()
	img:SetSize(side, side, 3)
	magic.image_set_data(img, side, side, 3, table.concat(rows))
	local tex = magic.Texture2D:new()
	tex:SetData(img)
	local b = parent:CreateChild("BorderImage")
	b.texture = tex
	b:SetFixedSize(side, side)
	return b
end

-- **Two-step login** ([STARPORT] 10a): TOTP on the user's own account. The
-- server answers every request with whether it is on and, while turning it
-- on, the secret to give an authenticator app
local totp_page
local totp_state = {on = 0, secret = "", uri = "", error = ""}
totp_page = function(back)
	local w = open_page("totp", "Two-step login (TOTP)", back)
	local st = totp_state
	if st.error ~= "" then
		page_text(w, st.error, WARN)
	end
	if st.secret ~= "" then
		page_text(w, "Add this key to an authenticator app, then enter " ..
				"the code it shows:")
		local k = w:CreateChild("LineEdit")
		k:SetStyleAuto()
		k.minHeight = 26
		k.textCopyable = true
		k.textSelectable = true
		k:SetText(st.secret)
		qr_image(w, st.uri)
		local code = field(w, "Code", false, function() end)
		local r = row(w)
		button(r, "Turn on", function()
			buildat.send_packet("accounts:totp", cereal.binary_output(
					{cmd = "confirm", code = code:GetText()}, TOTP_REQ))
		end)
		button(r, "Back", go_back)
		return
	end
	page_text(w, st.on == 1 and "On: logging in asks for a code from your " ..
			"authenticator app." or "Off. With it on, logging in also asks " ..
			"for a code from an authenticator app on your phone.")
	if st.on == 1 then
		local code = field(w, "Code", false, function() end)
		local r = row(w)
		button(r, "Turn off", function()
			buildat.send_packet("accounts:totp", cereal.binary_output(
					{cmd = "off", code = code:GetText()}, TOTP_REQ))
		end)
		button(r, "Back", go_back)
	else
		local r = row(w)
		button(r, "Turn on...", function()
			buildat.send_packet("accounts:totp", cereal.binary_output(
					{cmd = "begin", code = ""}, TOTP_REQ))
		end)
		button(r, "Back", go_back)
	end
end
M.totp_page = function(back)
	totp_state = {on = 0, secret = "", uri = "", error = ""}
	buildat.send_packet("accounts:totp", cereal.binary_output(
			{cmd = "status", code = ""}, TOTP_REQ))
	totp_page(back)
end

-- **Pushes to one's phone** ([ADMIN_NOTIFY]): a Steward's or the Host's
-- ntfy topic URL, which reports and the server's trouble are POSTed to.
-- The server suggests a topic of its own making, a new one per server;
-- the ntfy app subscribes to it by the link or its QR code. ask: the
-- question after a login, above the rest until it is answered.
local ntfy_page
local ntfy_state = {url = "", suggest = "", note = "", may = "0"}
local function ntfy_send(cmd, url)
	buildat.send_packet("accounts:ntfy", cereal.binary_output({cmd, url or ""},
			{"array", "string"}))
end
ntfy_page = function(back)
	local w = open_page("ntfy", "Pushes to your phone (ntfy)", back)
	local st = ntfy_state
	if st.ask then
		page_text(w, "Get a push on your phone for reports and the " ..
				"server's trouble? It goes through ntfy, an app for " ..
				"Android and iOS; nothing is sent until you add it.")
		local r = row(w)
		button(r, "Add now", function()
			st.ask = false
			ntfy_page(back)
			log:info("accounts: ntfy: the address page after Add now")
		end, true)
		-- Answered: the window closed if a game opened it, else (an
		-- app's own) its first entry
		local function done()
			if sw.on_close then
				M.server_close()
			else
				M.server_show(server_entries()[1].items[1].key)
			end
		end
		button(r, "Later", function()
			ntfy_send("later")
			done()
		end)
		button(r, "Don't add", function()
			ntfy_send("never")
			done()
		end)
		page_text(w, "Don't add: not asked again. It stays in My account.",
				DIM)
		return
	end
	if st.note ~= "" then
		page_text(w, st.note, WARN)
	end
	if st.may ~= "1" then
		if back then
			button(w, "Back", go_back)
		end
		return
	end
	page_text(w, st.url ~= "" and "On: reports and the server's trouble " ..
			"are pushed to this ntfy topic, at most one push in 5 minutes." or
			"Off. Subscribe to this topic in the ntfy app, then Save. It is " ..
			"made for you on this server; the part before the topic is the " ..
			"ntfy server, ntfy.sh or your own.")
	page_text(w, "A push says what happened and how many are open, never " ..
			"who or what: anyone who knows a topic's name can read it.", DIM)
	-- A line of its own each: the whole address shows
	local function line(label, text)
		page_text(w, label)
		local e = w:CreateChild("LineEdit")
		e:SetStyleAuto()
		e.minHeight = 26
		e.textSelectable = true
		e.textCopyable = true
		e:SetText(text)
		e.cursorPosition = 0
		return e
	end
	local addr = st.url ~= "" and st.url or st.suggest
	local e = line("Address", addr)
	local sub = addr:gsub("^https://", "ntfy://")
	line("Subscribe in the ntfy app (or scan the code)", sub)
	qr_image(w, sub)
	local r = row(w)
	button(r, "Save", function()
		ntfy_send("set", e:GetText())
	end, true)
	if st.url ~= "" then
		button(r, "Test", function() ntfy_send("test") end)
		button(r, "Turn off", function() ntfy_send("set", "") end)
	end
	if back then
		button(r, "Back", go_back)
	end
end
M.ntfy_page = function(back)
	ntfy_state.note = ""
	ntfy_send("status")
	ntfy_page(back)
end
buildat.sub_packet("accounts:ntfy_result", function(data)
	local v = cereal.binary_input(data, {"array", "string"})
	ntfy_state.url, ntfy_state.suggest = v[1] or "", v[2] or ""
	ntfy_state.note, ntfy_state.may = v[3] or "", v[4] or "0"
	log:info("accounts: ntfy: url=" .. ntfy_state.url .. " suggest=" ..
			ntfy_state.suggest .. " note=" .. ntfy_state.note)
	if page_kind == "ntfy" then
		ntfy_page(page_back)
	end
end)
-- After a login, a Steward or the Host without one: the Server window at
-- the question
local function ntfy_ask(suggest)
	ntfy_state = {url = "", suggest = suggest, note = "", may = "1", ask = true}
	log:info("accounts: ntfy asked: " .. suggest)
	-- A window up already (an app's own, or one a game opened) is shown
	-- the question as it is, its on_close kept ([NTFY_ASK_OVER_GAME])
	if sw.frame then
		M.server_show("ntfy")
	else
		M.server_window("ntfy", function() end)
	end
end
buildat.sub_packet("accounts:ntfy_ask", function(data)
	ntfy_ask(cereal.binary_input(data, TEXT).text)
end)
-- A check's `event ntfy_ask`: the question as the server puts it, at any
-- time, over whatever the app has up ([NTFY_ASK_OVER_GAME])
magic.SubscribeToEvent("command_seq:ntfy_ask", function()
	ntfy_ask("https://ntfy.sh/buildat-check")
end)

-- **My account** (user, 2026-10-02): what a user does with their own
-- account, in one page, so that a game's menu has one button for it
-- ("My account...") and guidance that names these buttons is right in
-- every game. A game shows it where the account is the server's (not a
-- local game's).
account_page = function(back, message)
	local w = open_page("account", "My account", back)
	if M.name and M.name ~= "" then
		page_text(w, "Logged in as " .. M.name, DIM)
	end
	if message then
		page_text(w, message, WARN)
	end
	-- An app's own rows (Starport's contact e-mail)
	if M.account_extra then
		M.account_extra(w)
	end
	local here = function() account_page(back) end
	button(w, "Change password...", function() passwd_page(here) end)
	button(w, "Two-step login...", function() M.totp_page(here) end)
	if M.users and M.users.level >= 30 then
		button(w, "Notify me by ntfy...", function() M.ntfy_page(here) end)
	end
	-- [STARPORT] 10g: this account the one a Starport ID logs in as
	if M.hello.starport == 1 then
		page_text(w, "A linked Starport ID logs in as this account.", DIM)
		-- One per Starport ([ID_CLAIM_ACCOUNT] 5)
		for _, l in ipairs(M.links) do
			local r = row(w)
			local t = page_text(r, "Linked: an ID of " .. l)
			t:SetWordwrap(false)
			local b = button(r, "Unlink", function()
				buildat.send_packet("accounts:unlink_starport", l)
			end)
			b:SetFixedWidth(b.minWidth)
		end
		button(w, "Link a Starport ID...", function()
			local ok, starport = pcall(require, "buildat/extension/starport")
			if not ok or not starport.id_token_here then
				return account_page(back, "This client has no Starport "..
						"extension")
			end
			starport.id_token_here(function(token, why)
				if not token then
					return account_page(back, why ~= "cancelled" and why or
							nil)
				end
				buildat.send_packet("accounts:link_starport", token)
			end)
		end)
	end
	button(w, "Log out", M.logout)
	if back then
		button(w, "Back", go_back)
	end
end
-- A game's "My account...": the Server window at it; `back` is what
-- closing the window goes back to
M.account_page = function(back)
	M.server_window("account", back or function() end)
end

buildat.sub_packet("accounts:totp_result", function(data)
	local r = cereal.binary_input(data, TOTP_RESULT)
	totp_state = {on = r.on, secret = r.secret, uri = r.uri, error = r.error}
	if page_kind == "totp" then
		totp_page(page_back)
	end
end)

-- **A ban, its reason and whether it goes to the Starports** ([STARPORT]
-- 10d): ticked by itself for a reason others should know of; a house rule
-- stays here. Only a Starport ID's account is reported
local BAN_REASONS = {
	{"harassment", "Harassment or abuse", true},
	{"illegal", "Illegal content", true},
	{"csam", "Child sexual abuse material", true},
	{"scam", "Scam, phishing or malware", true},
	{"other", "Breaking this server's rules", false},
}
ban_page = function(name, back)
	local w = open_page("ask", "Ban " .. name, back)
	local reason, report = nil, false
	local rb = nil
	local function draw()
		rb:GetChild(0):SetText((report and "[x]" or "[ ]") ..
				" Report to Starport (a Starport ID only)")
	end
	local choices = {}
	for i, x in ipairs(BAN_REASONS) do
		choices[i] = {x[2], i}
	end
	ui_utils.dropdown(w, choices, nil, function(i)
		reason = BAN_REASONS[i][1]
		report = BAN_REASONS[i][3]
		draw()
	end, {label = "Reason", none = "(choose)"})
	rb = button(w, "", function()
		report = not report
		draw()
	end)
	draw()
	local r = row(w)
	button(r, "Ban", function()
		M.admin("ban", name, reason or "other", report)
		users_page(back)
	end)
	button(r, "Back", function() users_page(back) end)
end

-- [STARPORT_DEFAULT_URL]: "https://host[:port]", the address the admin
-- reached the server by, when it is under TLS and a public one -- not this
-- machine's or the LAN's, which no player elsewhere reaches. nil if not.
-- simplified: the private ranges by the host's text; a public name that
-- resolves to a LAN address passes
local function public_https(a)
	a = a:gsub("^%a+://", ""):gsub("/.*$", "")
	local host = (a:match("^%[(.-)%]") or a:match("^[^:]*")):lower()
	local port = a:match("^%[.-%]:(%d+)$") or a:match("^[^:]*:(%d+)$")
	local private = host == "" or host == "localhost" or host == "::1" or
			not host:find("[%.:]") or host:match("%.local$") or
			host:match("%.lan$") or host:match("^127%.") or
			host:match("^10%.") or host:match("^192%.168%.") or
			host:match("^169%.254%.") or host:match("^0%.") or
			host:match("^172%.1[6-9]%.") or host:match("^172%.2%d%.") or
			host:match("^172%.3[01]%.") or host:match("^f[cd]%x*:") or
			host:match("^fe80:")
	if private then
		return nil
	end
	if host:find(":") then
		host = "[" .. host .. "]"
	end
	return "https://" .. host .. ((port and port ~= "443") and ":" .. port or "")
end
assert(public_https("https://Forum.Example.org:443") == "https://forum.example.org")
assert(public_https("fp.example.org:8443") == "https://fp.example.org:8443")
assert(public_https("wss://[2001:db8::1]:30000/x") == "https://[2001:db8::1]:30000")
for _, a in ipairs({"127.0.0.1:443", "localhost", "192.168.1.5:80",
		"https://172.20.0.1", "[::1]:443", "[fd00::1]:5", "box.local", "box"}) do
	assert(public_https(a) == nil, a)
end
local function admin_public_address()
	return buildat.connection_encrypted() and
			public_https(buildat.server_address() or "") or nil
end

-- A page of fields under the users page: a password for an account, or a
-- new account's name and password
local function ask_page(title, labels, on_done)
	local w = open_page("ask", title, page_back)
	local back = page_back
	local es = {}
	local function done()
		local v = {}
		for i, e in ipairs(es) do
			v[i] = e:GetText()
		end
		on_done(v[1], v[2])
		users_page(back)
	end
	for i, l in ipairs(labels) do
		es[i] = field(w, l, l == "Password", function()
			if es[i + 1] then
				es[i + 1]:SetFocus(true)
			else
				done()
			end
		end)
	end
	local r = row(w)
	button(r, "OK", done)
	button(r, "Back", function() users_page(back) end)
	es[1]:SetFocus(true)
end

-- simplified: every user on one page, with no scrolling; a server with
-- more users than fit the screen needs a list that scrolls
users_page = function(back)
	local w = open_page("users", "Accounts", back)
	-- What the last request came to, on a line that is always there so
	-- that the buttons under it do not move when it appears; an invite's
	-- code in a field, to copy
	local message = M.message or ""
	local code = message:match("^Invite code: (%w+)$")
	if code then
		local r = row(w)
		page_text(r, "Invite code", WARN):SetWordwrap(false)
		local e = r:CreateChild("LineEdit")
		e:SetStyleAuto()
		e.minHeight = 26
		e.minWidth = 120
		e.textCopyable = true
		e.textSelectable = true
		e:SetText(code)
		button(r, "Copy", function()
			magic.ui:SetClipboardText(code)
			notice("Copied the invite code")
		end)
	else
		page_text(w, message ~= "" and message or " ", WARN).minHeight = 22
	end
	local u = M.users
	if not u then
		page_text(w, "Waiting for the server...")
		if back then
			button(w, "Back", go_back)
		end
		return
	end
	-- [STARPORT] 10g: admins that all log in by a Starport ID only are
	-- locked out while the Starport is away
	local admins, id_only_admins = 0, 0
	for _, user in ipairs(u.users) do
		for _, p in ipairs(user.privs) do
			if p == "admin" then
				admins = admins + 1
				if user.id_only == 1 then
					id_only_admins = id_only_admins + 1
				end
			end
		end
	end
	-- [TRUST_LADDER] A moderator's page has what does not change a login
	-- or the server
	local admin = u.level >= 40
	if admin and admins > 0 and id_only_admins == admins then
		page_text(w, "Every admin logs in only by a Starport ID: while the "..
				"Starport cannot be reached, nobody can manage this server. "..
				"Give an admin a local password (Password... on their row).",
				magic.Color(rgb("error")))
	end
	-- **The accounts, invites and bans** (user, 2026-09-30): a server's
	-- users are more than a phone's screen; they go into the page, which
	-- scrolls as one [STARPORT_LIST_FILL]
	local item_width = math.max(100, w.width - 32)
	local function item()
		local it = w:CreateChild("UIElement")
		it:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 2, 0, 2))
		it:SetFixedWidth(item_width)
		return it
	end
	-- [STARPORT] 10g: Starport IDs waiting for an admin
	for _, name in ipairs(u.approvals or {}) do
		local it = item()
		page_text(it, name .. ": a Starport ID waiting to be let in", WARN)
		local r = row(it)
		button(r, "Let in", function() M.admin("approve", name) end)
		button(r, "Turn away", function() M.admin("turn_away", name) end)
	end
	for _, user in ipairs(u.users) do
		local has = {}
		for _, p in ipairs(user.privs) do
			has[p] = true
		end
		-- The name over its buttons: five of them are a narrow window's
		-- width at the web client's scale
		local it = item()
		page_text(it, user.name .. " - " .. M.level_name(user.level) ..
				(user.here == 1 and " (here)" or "") ..
				(user.id_only == 1 and " (Starport ID only)" or "") ..
				(user.storage ~= "" and ", keeps " .. user.storage or ""))
		local r = row(it)
		local below = user.level < u.level
		if admin then
			button(r, has.admin and "Admin: yes" or "Admin: no", function()
				M.admin("priv", user.name, "admin", not has.admin)
			end)
		end
		if user.here == 1 and (admin or below) then
			button(r, "Kick", function() M.admin("kick", user.name) end)
		end
		if not has.admin and (admin or below) then
			button(r, "Ban...", function() ban_page(user.name, back) end)
		end
		-- [TRUST_LADDER] Each level below the viewer's, on a row of its own
		if below and user.level < 40 then
			local r2 = row(it)
			for _, lv in ipairs({10, 20, 30}) do
				-- "No longer" for the highest held only: it steps down one
				if lv < u.level and user.level < lv + 10 then
					local on = user.level >= lv
					button(r2, (on and "No longer a " or "Make a ") ..
							M.level_name(lv), function()
						M.admin("level", user.name,
								tostring(on and lv - 10 or lv))
					end)
				end
			end
		end
		if admin then
			button(r, "Password...", function()
				ask_page("A new password for " .. user.name, {"Password"},
						function(p) M.admin("password", user.name, p) end)
			end)
			button(r, "Delete...", function()
				local w2 = open_page("ask", "Delete the account " .. user.name ..
						"? Their session ends.", back)
				local r2 = row(w2)
				button(r2, "Delete", function()
					M.admin("delete", user.name)
					users_page(back)
				end)
				button(r2, "Back", function() users_page(back) end)
			end)
		end
	end
	if #u.invites > 0 then
		page_text(item(), "Invites (each makes one account):")
	end
	for _, inv in ipairs(u.invites) do
		local r = row(item())
		page_text(r, inv.code .. "  (" .. inv.invite.by .. ")"):SetWordwrap(false)
		button(r, "Delete", function() M.admin("uninvite", inv.code) end)
	end
	-- [VANILLA_PUBLIC] 4: a ban is of the account, and of where it joined
	-- from while registration is open
	if #(u.bans or {}) > 0 then
		page_text(item(), "Banned:")
		for _, b in ipairs(u.bans) do
			local r = row(item())
			page_text(r, b.name .. (b.address ~= "" and
					"  (" .. b.address .. ")" or "")):SetWordwrap(false)
			button(r, "Unban", function() M.admin("unban", b.name) end)
		end
	end
	local r = row(w)
	if admin then
		button(r, "Add a user...", function()
			ask_page("Add a user", {"Name", "Password"},
					function(n, p) M.admin("add", n, p) end)
		end)
	end
	button(r, "New invite", function() M.admin("invite") end)
	local a = u.access
	if admin then button(w, a.open_registration == 1 and
			"Local accounts: anyone can make one" or
			"Local accounts: invite only", function()
		M.admin("setting", "open_registration", "", a.open_registration ~= 1)
	end) end
	-- [FP_ABUSE] 3: past the budget an app takes no more from an untrusted
	-- account
	if admin then
		page_text(w, "Storage: " .. (u.storage ~= "" and u.storage or
				"nothing kept") .. " of a budget of " .. u.budget_mb ..
				" MB for untrusted accounts")
		button(w, "Storage budget...", function()
			ask_page("The storage budget in MB", {"MB"},
					function(mb) M.admin("setting", "storage_budget", mb) end)
		end)
	end
	if back then
		button(w, "Back", go_back)
	end
end
--
-- **The server's Starport page** ([STARPORT] 10g): starport.json, which
-- builtin/starport_announce writes and watches, and what each Starport last
-- answered. The admin's only; the server checks.
--
-- The keys whose values are lists, empty ones too (the sandbox has no
-- metatables to mark them by)
local ARRAY_KEYS = {starports = true, tags = true, languages = true}
local function encode(v, as_array)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" or t == "number" then
		return tostring(v)
	elseif t == "string" then
		return '"' .. v:gsub('[%c"\\]', function(c)
			local map = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
				['\r'] = '\\r', ['\t'] = '\\t'}
			return map[c] or string.format("\\u%04x", c:byte())
		end) .. '"'
	end
	local out = {}
	if as_array or v[1] ~= nil then
		for _, x in ipairs(v) do
			out[#out + 1] = encode(x)
		end
		return "[" .. table.concat(out, ",") .. "]"
	end
	if next(v) == nil then
		return "{}"
	end
	for k, x in pairs(v) do
		out[#out + 1] = encode(tostring(k)) .. ":" .. encode(x, ARRAY_KEYS[k])
	end
	return "{" .. table.concat(out, ",") .. "}"
end
assert(encode({a = {1, "x\n"}}) == '{"a":[1,"x\\n"]}')
assert(encode({starports = {}}) == '{"starports":[]}')

local starport_info = nil
local starport_help
buildat.sub_packet("starport:config", function(data)
	starport_info = buildat.parse_json(data)
	-- What the server has now is what is edited
	draft = nil
	-- Starport on or off changes whether IDs are taken: My account's link
	buildat.send_packet("accounts:get_hello", "")
	if page_kind == "starport" then
		starport_page(page_back, sp_panel)
	elseif page_kind == "health" then
		health_page(page_back)
	end
end)

-- The listing's text fields, and its choices ([STARPORT] 3): a choice not
-- made is a red "?", sent as it is, which the Starport refuses saying what
-- it wants
local TEXT_FIELDS = {
	{"name", "Name"}, {"description", "Description"},
	{"address", "Public address"},
	{"signup_url", "Sign-up address (access external)"},
	{"region", "Region"}, {"fleet", "Fleet (id:code)"}, {"pool", "Pool"},
	{"tags", "Tags"},
	{"languages", "Languages"},
}
local CHOICES = {
	{"kind", "Kind", {"world", "arena", "app", "other"}},
	{"audience", "Audience", {"everyone", "teen", "adult"}},
	-- Derived from the Accounts page unless one of the two the server
	-- cannot know (10g)
	{"access", "Access", {"auto", "password", "external"}},
}
local DESCRIPTORS = {
	{"violence", "Violence", {"none", "cartoon", "realistic"}},
	{"chat", "Chat", {"none", "moderated", "unmoderated"}},
	{"ugc", "Player content", {"none", "moderated", "unmoderated"}},
	{"language", "Bad language", {"no", "yes"}},
	{"sexual", "Sexual content", {"no", "yes"}},
	{"drugs", "Drugs", {"no", "yes"}},
	{"purchases", "Purchases", {"no", "yes"}},
	{"gambling", "Gambling", {"no", "yes"}},
	{"personal_data", "Personal data", {"no", "yes"}},
}
local ERROR = magic.Color(rgb("error"))


-- A dropdown: its label, and the value, a red "?" for none
local function dropdown(parent, label, choices, current, on_choose)
	local l = page_text(parent, label)
	l:SetWordwrap(false)
	l:SetFixedWidth(130)
	return ui_utils.dropdown(parent, choices, current, on_choose,
			{width = 118, none = "?"})
end

-- **What the Starport page is, and what goes in each field** ([STARPORT]
-- 10g): a window over the page, its text scrolling
local STARPORT_HELP = {
	"# What this page is",
	"Starports are directories of public servers: players find servers in "..
	"their lists, and log in with a Starport ID where a server allows it. "..
	"These panels decide whether this server is listed, on which Starports, "..
	"and what the listing says (Starports, The listing), and who may join by "..
	"a Starport ID: off, anyone, approved only (ID logins).",
	"Everything here is kept in this app's starport.json beside its saves. "..
	"The server reads that file again within seconds of a change, so it can "..
	"also be edited by hand or by a script, and nothing has to restart.",
	"# Starport: on / off",
	"Off: the server is on no list and takes no Starport IDs; the "..
	"Starports are told at once and keep the listing for when it comes "..
	"back on.",
	"# Unlisted",
	"Yes: the server stays off the public lists, and still takes Starport "..
	"IDs. For a private community that wants Starport logins without "..
	"advertising itself.",
	"# The Starports",
	"Each Starport the server announces to, with what it last answered: "..
	"listed; unlisted; unclaimed (an operator has not claimed it yet); "..
	"filtered out by that Starport's own rules; refused, with the reason "..
	"(a field it does not accept, for one); or unreachable.",
	"Listing id and claim code: to be listed, the listing is claimed by an "..
	"operator account on that Starport. Join the Starport app, set a "..
	"contact e-mail, and claim the listing there with this id and code. "..
	"Anyone with the code can claim it: keep it among this server's admins. "..
	"(A server in a fleet is claimed by the fleet line instead.)",
	"Accounts linked to its IDs: how many of this server's accounts log in "..
	"by an ID of that Starport. Removing the Starport stops their ID "..
	"logins; an admin can give them passwords on the Accounts page.",
	"Follows: the blocklists of that Starport this server subscribes to. "..
	"An ID they ban cannot join; its account here cannot log in by "..
	"password either, unless it is an admin or a moderator.",
	"Add a Starport: its address. A host name alone, like "..
	"starport.example.org, means http://starport.example.org:29595, "..
	"Starport's own port. A Starport behind an https proxy is written "..
	"https://starport.example.org. With none added, the field has "..
	"https://starport.buildat.org in it; turning Starport IDs on with none "..
	"added adds that one, unlisted.",
	"# The listing",
	"What the Starport shows of this server. Nothing is sent until Save the "..
	"listing; a dropdown with a red ? is a choice not made yet, which the "..
	"Starport refuses (its status then says which). Unlisted, they may be "..
	"left out: the name is then the server's address.",
	"Name: what the list shows, 1 to 60 characters. Example: Torkkola "..
	"builders' plans.",
	"Description: a sentence or two, up to 500 characters. Example: A shared "..
	"floor plan for the Torkkola house; visitors welcome to look.",
	"Public address: where players reach this server. Empty: the address "..
	"the announce comes from, and this server's own port. Behind a proxy "..
	"with TLS, its https:// address, which clients join by a secure "..
	"WebSocket; the Starport checks the server through it. Examples: "..
	"https://fp.example.org, fp.example.org:30000. Empty, and this page "..
	"reached by https at an address that is not this machine's or the "..
	"LAN's, the field has that address in it.",
	"Sign-up address: with access \"external\" only, where an account is "..
	"made before joining. Example: https://example.org/join.",
	"Region: where the server is, for players choosing a near one and for a "..
	"pool's choice. Example: eu, us-east.",
	"Fleet: puts this server in a fleet of one operator's servers, shown "..
	"together. The line is the fleet's id and code, from the Fleets page "..
	"of the Starport app. Example: 3312a3640de3:b7896830ad5df4c1.",
	"Pool: servers of a fleet with the same pool name are interchangeable "..
	"(they only split the load); players are sent to the least busy one. "..
	"Example: main. Empty: this server is its own entry.",
	"Tags: up to 8, lower case, comma separated, for search. Example: "..
	"creative, building, finnish.",
	"Languages: the languages spoken there, comma separated. Example: en, fi.",
	"# Kind",
	"world: a persistent world to come back to. arena: matches that start "..
	"and end. app: not a game -- a tool, a creative or social space (the "..
	"floor planner is one). other: none of these.",
	"# Audience",
	"The server's own rating, as an app store's. everyone: for all ages. "..
	"teen: 13 and over. adult: 18 and over. Starports may hide some "..
	"audiences (the official one leaves adult out), and a player's filters "..
	"and age decide what they see.",
	"# Access",
	"auto: what the Accounts page says (the page shows it), one of open "..
	"(anyone can make an account here), starport (local accounts are "..
	"invite only, and Starport IDs may join) or invite (invite only, no "..
	"Starport IDs).",
	"password: the players share a password to get in. external: an "..
	"account made somewhere else first, at the sign-up address.",
	"# The descriptors: what the server has",
	"Violence: none; cartoon (unrealistic, no blood); realistic.",
	"Chat between players: none; moderated (someone watches it and acts); "..
	"unmoderated.",
	"Player content (builds, images, text players make that others see): "..
	"none; moderated; unmoderated.",
	"Bad language: yes if swearing and the like is common or allowed.",
	"Sexual content: yes if there is any.",
	"Drugs: yes if drug use is shown or a theme.",
	"Purchases: yes if anything costs real money.",
	"Gambling: yes if there are paid random rewards (loot boxes and the "..
	"like) or betting.",
	"Personal data: yes if the server collects personal data beyond play, "..
	"such as e-mail addresses.",
	"An audience of everyone with unmoderated chat or player content is "..
	"looked at by the Starport's moderators. Moderators may relabel a "..
	"listing that says less than it has; its operator gets a statement of "..
	"reasons and can appeal.",
}
-- A heading is a line beginning with "# "

starport_help = function()
	if sw.help then
		sw.help:Remove()
	end
	local w = page_window(720)
	-- Over the Starport page (100) and its dropdowns (200)
	w.priority = 300
	-- A click on it is not one off the Server window
	sw.help = w
	page_text(w, "Starport: help")
	local list = w:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedHeight(math.max(160, math.floor(magic.ui.root.height * 0.7)))
	-- The list's inside, less its scroll bar, and a tenth less again:
	-- Urho3D's wrap measures a line a few percent short of what it draws,
	-- more so at some UI scales, and a fixed margin did not cover all
	local width = math.max(100, math.floor((w.width - 60) * 0.9))
	for i, t in ipairs(STARPORT_HELP) do
		if i > 1 and t:sub(1, 2) == "# " then
			local gap = list:CreateChild("UIElement")
			gap:SetFixedHeight(10)
			list:AddItem(gap)
		end
		local x = list:CreateChild("Text")
		x:SetStyleAuto()
		x:SetWordwrap(true)
		x:SetFixedWidth(width)
		if t:sub(1, 2) == "# " then
			x:SetText(t:sub(3))
			x:SetColor(WARN)
		else
			x:SetText(t)
		end
		list:AddItem(x)
	end
	button(w, "Close", function()
		w:Remove()
		sw.help = nil
	end)
end

-- **Split in three** ([SERVER_ADMIN_PAGE]; user: one page was long and
-- confusing): the Starports, the listing, and who logs in by an ID
local PANELS = {starports = "Starports", listing = "The listing",
	ids = "ID logins"}
starport_page = function(back, panel, confirm_remove)
	sp_panel = panel
	local w = open_page("starport", "Starport: " .. PANELS[panel], back, 840,
			starport_help)
	local function back_row()
		if back then
			button(w, "Back", go_back)
		end
	end
	if panel == "ids" then
		local u = M.users
		page_text(w, "Whether players log in here by their Starport ID, "..
				"made on a Starport this server is listed on. The Starports "..
				"are on the Starports panel.", DIM)
		if not u then
			page_text(w, "Waiting for the server...")
			return back_row()
		end
		-- [STARPORT] 10g: off, anyone, approved only
		local ids = u.starport_ids or "off"
		local next_ids = {off = "anyone", anyone = "approved", approved = "off"}
		button(w, ({off = "Starport IDs: off",
			anyone = "Starport IDs: anyone may join",
			approved = "Starport IDs: approved only"})[ids] or ids, function()
			-- Turned on: where the admin reached the server goes along, the
			-- public address of a starport.json that names no Starport yet
			local mode = next_ids[ids] or "off"
			local addr = ids == "off" and admin_public_address()
			M.admin("setting", "starport_ids", addr and mode .. " " .. addr or
					mode)
		end)
		page_text(w, "Approved only: an ID's first join waits for an admin "..
				"on the Accounts page.", DIM)
		if M.message and M.message ~= "" then
			page_text(w, M.message, WARN)
		end
		return back_row()
	end
	local info = starport_info
	if not info then
		page_text(w, "Waiting for the server...")
		return back_row()
	end
	local c = info.config or {}
	if type(c.starports) ~= "table" then
		c.starports = {}
	end
	local function save()
		buildat.send_packet("starport:config_set", encode(c))
	end
	if info.message and info.message ~= "" then
		page_text(w, info.message, WARN)
	end
	page_text(w, "Kept in the app's starport.json; an edit there counts too",
			DIM)
	if panel == "starports" then
		local r = row(w)
		button(r, c.enabled == false and "Starport: off" or "Starport: on",
				function()
			c.enabled = c.enabled == false
			save()
		end)
		button(r, c.unlisted and "Unlisted: yes (IDs, not in the list)" or
				"Unlisted: no", function()
			c.unlisted = not c.unlisted
			save()
		end)
		for i, s in ipairs(info.starports or {}) do
			page_text(w, tostring(s.url) .. ": " .. tostring(s.status ~= "" and
					s.status or "not announced yet"))
			-- Read-only fields, not text: the two are copied to the
			-- Starport's claim form
			local cr = row(w)
			for _, f in ipairs({{"Listing id", s.listing}, {"Claim code", s.claim}}) do
				local l = page_text(cr, f[1])
				l:SetWordwrap(false)
				l:SetFixedWidth(100)
				local e = cr:CreateChild("LineEdit")
				e:SetStyleAuto()
				e.minHeight = 26
				e.editable = false
				e.textCopyable = true
				e.textSelectable = true
				e:SetText(tostring(f[2] or "-"))
			end
			page_text(w, tostring(s.linked or 0) .. " accounts linked to its IDs" ..
					((s.subscribed and #s.subscribed > 0) and "; follows " ..
					table.concat(s.subscribed, ", ") or ""), DIM)
			if confirm_remove == s.url then
				page_text(w, "Remove it? Its listing is withdrawn at once, and "..
						tostring(s.linked or 0) .. " accounts cannot log in by "..
						"their IDs while it is gone (an admin can give them "..
						"passwords).", WARN)
				local rr = row(w)
				button(rr, "Remove", function()
					table.remove(c.starports, i)
					save()
				end)
				button(rr, "Keep it", function() starport_page(back, panel) end)
			else
				button(w, "Remove " .. tostring(s.url), function()
					starport_page(back, panel, s.url)
				end)
			end
		end
		local add = field(w, "Add a Starport", false, function() end)
		-- One press of Add while none is named ([STARPORT_DEFAULT_URL])
		add:SetText(#c.starports == 0 and info.default_starport or "https://")
		button(w, "Add", function()
			local url = add:GetText():gsub("/+$", "")
			if url:match("^https?://[%w%.%-]+[:%d]*$") then
				table.insert(c.starports, url)
				save()
			end
		end)
		return back_row()
	end
	-- The listing: what the server says it is ([STARPORT] 3)
	local function valid(v, choices)
		for _, x in ipairs(choices) do
			if x == v then
				return v
			end
		end
		return nil
	end
	if not draft then
		draft = {text = {}, choice = {}, desc = {}}
		for _, f in ipairs(TEXT_FIELDS) do
			local v = c[f[1]]
			draft.text[f[1]] = type(v) == "table" and table.concat(v, ", ") or
					tostring(v or "")
		end
		for _, f in ipairs(CHOICES) do
			draft.choice[f[1]] = valid(c[f[1]], f[3])
		end
		-- Offered, saved with the listing ([STARPORT_DEFAULT_URL])
		if draft.text.address == "" then
			draft.text.address = admin_public_address() or ""
		end
		-- Access is derived unless the file says one of its two
		if draft.choice.access == nil then
			draft.choice.access = "auto"
		end
		-- [APP_CATEGORY] the app's own kind unless the file says one
		if draft.choice.kind == nil then
			draft.choice.kind = valid(info.app_kind, CHOICES[1][3])
		end
		local d = type(c.descriptors) == "table" and c.descriptors or {}
		for _, f in ipairs(DESCRIPTORS) do
			draft.desc[f[1]] = valid(d[f[1]], f[3])
		end
	end
	-- The long ones a row each, the short ones two to a row
	local edits = {}
	local PAIRED = {region = true, pool = true, tags = true, languages = true}
	local pr, in_pr = nil, 0
	for _, f in ipairs(TEXT_FIELDS) do
		local e
		if PAIRED[f[1]] then
			if in_pr % 2 == 0 then
				pr = row(w)
			end
			in_pr = in_pr + 1
			local l = page_text(pr, f[2])
			l:SetWordwrap(false)
			l:SetFixedWidth(130)
			e = pr:CreateChild("LineEdit")
			e:SetStyleAuto()
			e.minHeight = 26
			e:SetFixedWidth(240)
			e.textSelectable = true
			e.textCopyable = true
		else
			e = field(w, f[2], false, function() end)
		end
		e:SetText(draft.text[f[1]])
		edits[f[1]] = e
	end
	-- What was typed, kept before a redraw
	local function take_text()
		for _, f in ipairs(TEXT_FIELDS) do
			draft.text[f[1]] = edits[f[1]]:GetText()
		end
	end
	page_text(w, "Access from the Accounts page is now: " ..
			tostring(info.access_now or "?"), DIM)
	-- Three to a row: the page is long, and wide enough for them
	local dr
	local n = 0
	local function next_row()
		if n % 3 == 0 then
			dr = row(w)
		end
		n = n + 1
	end
	for _, f in ipairs(CHOICES) do
		next_row()
		dropdown(dr, f[2], f[3], draft.choice[f[1]], function(v)
			take_text()
			draft.choice[f[1]] = v
			starport_page(back, panel)
		end)
	end
	for _, f in ipairs(DESCRIPTORS) do
		next_row()
		dropdown(dr, f[2], f[3], draft.desc[f[1]], function(v)
			take_text()
			draft.desc[f[1]] = v
			starport_page(back, panel)
		end)
	end
	local r3 = row(w)
	button(r3, "Save the listing", function()
		take_text()
		for _, f in ipairs(TEXT_FIELDS) do
			local v = draft.text[f[1]]
			if f[1] == "tags" or f[1] == "languages" then
				local list = {}
				for x in v:gmatch("[^,%s]+") do
					list[#list + 1] = x
				end
				c[f[1]] = list
			else
				c[f[1]] = v ~= "" and v or nil
			end
		end
		-- A choice not made goes as "?": the Starport says what it wants
		for _, f in ipairs(CHOICES) do
			c[f[1]] = draft.choice[f[1]] or "?"
		end
		if c.access == "auto" then
			c.access = nil
		end
		c.descriptors = {}
		for _, f in ipairs(DESCRIPTORS) do
			c.descriptors[f[1]] = draft.desc[f[1]] or "?"
		end
		save()
	end)
	if back then
		button(r3, "Back", go_back)
	end
end
M.starport_page = function(back, panel)
	starport_info = nil
	buildat.send_packet("starport:config_get", "")
	starport_page(back, panel or "starports")
end

-- A game's "Accounts...": the Server window at it
M.users_page = function(back)
	M.admin("list")
	M.server_window("accounts", back or function() end)
end

--
-- **An admin's Health page** ([SERVER_ADMIN_PAGE]): what keeps a server
-- working, each a reading or a button with its answer. The server sends
-- "accounts:health" JSON for M.admin("health"), the box checked when `on`;
-- a test mail's answer comes later in one of its own. An app adds rows by
-- M.health_rows(w).
--
local health = {}
-- The fields' text over the page's redraws
local hp = {draft = {}, edits = {}}
health_capture = function()
	for k, e in pairs(hp.edits) do
		hp.draft[k] = e:GetText()
	end
	hp.edits = {}
end
buildat.sub_packet("accounts:health", function(data)
	local v = buildat.parse_json(data)
	if type(v) ~= "table" then
		return
	end
	for k, x in pairs(v) do
		health[k] = x
	end
	if page_kind == "health" then
		health_page(page_back)
	end
end)

local function bytes(n)
	n = tonumber(n) or -1
	if n < 0 then
		return "?"
	elseif n >= 1e9 then
		return string.format("%.1f GB", n / 1e9)
	end
	return string.format("%.1f MB", n / 1e6)
end
assert(bytes(2.5e9) == "2.5 GB" and bytes(1234567) == "1.2 MB" and
		bytes(-1) == "?")

local function duration(s)
	s = math.floor(tonumber(s) or 0)
	if s >= 86400 then
		return string.format("%d d %d h", math.floor(s / 86400),
				math.floor(s % 86400 / 3600))
	end
	return string.format("%d h %d min", math.floor(s / 3600),
			math.floor(s % 3600 / 60))
end
assert(duration(90061) == "1 d 1 h" and duration(3720) == "1 h 2 min")

--
-- **Statistics** ([SERVER_STATS]): a moderator's and the admin's history of
-- the server, "accounts:stats" JSON for M.admin("stats"). Its rows are
-- [unit, minutes, min, average, max, joins, made, names, tick gap ms,
-- memory], the unit a unix hour or day (UTC).
--
local stats = nil
local stats_page
buildat.sub_packet("accounts:stats", function(data)
	local v = buildat.parse_json(data)
	if type(v) ~= "table" then
		return
	end
	stats = v
	local h = v.hours and v.hours[#v.hours]
	local t = v.top and v.top[1]
	log:info(string.format("stats: %d hours, %d days, %d accounts; the "..
			"hour in progress max %s; top %s made %s last %s",
			#(v.hours or {}), #(v.days or {}), tonumber(v.accounts) or 0,
			h and h[1] == v.hour and tostring(h[5]) or "-",
			t and t[1] or "-", t and tostring(t[2]) or "-",
			t and tostring(t[3]) or "-"))
	if page_kind == "stats" then
		stats_page(page_back)
	end
end)

-- A bar graph's pixels, RGB, `bw` a bar wide and `h` high: each bar
-- {min, average, max} -- the max faint, the average solid, the min a
-- line -- or false for a gap. Scaled to the highest max.
local G_BG, G_FAINT, G_SOLID, G_LINE = "\28\28\28", "\55\75\105",
		"\95\145\205", "\230\230\230"
local function bar_pixels(bars, bw, h)
	local top = 0
	for _, b in ipairs(bars) do
		if b and b[3] > top then
			top = b[3]
		end
	end
	top = top > 0 and top or 1
	local function px(v)
		return math.floor(v / top * h + 0.5)
	end
	local rows = {}
	for y = 0, h - 1 do
		local up = h - y
		local row = {}
		for i, b in ipairs(bars) do
			local c = G_BG
			if b then
				if px(b[2]) >= up then
					c = G_SOLID
				elseif px(b[3]) >= up then
					c = G_FAINT
				end
				if b[1] and math.max(px(b[1]), 1) == up then
					c = G_LINE
				end
			end
			row[i] = string.rep(c, bw)
		end
		rows[#rows + 1] = table.concat(row)
	end
	return table.concat(rows), top
end
assert(bar_pixels({{1, 2, 4}, false}, 1, 4) == G_FAINT .. G_BG .. G_FAINT ..
		G_BG .. G_SOLID .. G_BG .. G_LINE .. G_BG)

-- The page's graphs; the bar under the pointer has its line of text
local graphs = {}
magic.SubscribeToEvent("MouseMove", function()
	if page_kind ~= "stats" then
		return
	end
	local sc = magic.ui.scale or 1
	local m = magic.input:GetMousePosition()
	for _, g in ipairs(graphs) do
		local p = g.el.screenPosition
		local i = math.floor((m.x / sc - p.x) / g.bw) + 1
		local y = m.y / sc - p.y
		if i >= 1 and i <= g.n and y >= 0 and y < g.h then
			g.label:SetText(g.describe(i))
		end
	end
end)

-- A graph of `bars` into `parent`, the x axis marked under it: marks[i]
-- a label at bar i. describe(i) is the bar's line under the pointer.
-- The image is whole pixels a bar, stretched to `width`.
local function bar_graph(parent, bars, width, h, marks, describe)
	local bw = math.max(1, math.ceil(width / #bars))
	local w = bw * #bars
	local data = bar_pixels(bars, bw, h)
	local img = magic.Image:new()
	img:SetSize(w, h, 3)
	magic.image_set_data(img, w, h, 3, data)
	local tex = magic.Texture2D:new()
	tex:SetData(img)
	local box = parent:CreateChild("UIElement")
	box:SetFixedSize(width, h + (marks and 16 or 0))
	local b = box:CreateChild("BorderImage")
	b.texture = tex
	b:SetFixedSize(width, h)
	-- A bar's width as shown
	bw = width / #bars
	for i, text in pairs(marks or {}) do
		local tick = box:CreateChild("BorderImage")
		tick.color = magic.Color(0.6, 0.6, 0.6)
		tick:SetFixedSize(1, 4)
		tick.position = magic.IntVector2(math.floor((i - 1) * bw), h)
		local t = box:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(text)
		t.position = magic.IntVector2(math.floor((i - 1) * bw) + 2, h + 1)
		t:SetColor(DIM)
	end
	-- g.label: the line under the graphs, set by the page
	local g = {el = b, bw = bw, n = #bars, h = h, describe = describe}
	graphs[#graphs + 1] = g
	return g
end

-- The client's offset from UTC in seconds, from its local clock's hour and
-- minute against the wall clock's: the sandbox has no os.date
local function utc_offset()
	local now = math.floor(buildat.get_time_us() / 1e6)
	local _, h, m = buildat.get_local_time()
	local d = (h * 60 + m) - math.floor(now % 86400 / 60)
	d = (d + 720) % 1440 - 720
	return math.floor(d / 15 + 0.5) * 15 * 60
end

-- A unix day's year, month and day (Howard Hinnant's civil_from_days)
local function civil(days)
	local z = days + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) +
			math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	return yoe + era * 400 + (m <= 2 and 1 or 0), m, d
end
local WEEKDAYS = {"Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"}
local MONTHS = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug",
	"Sep", "Oct", "Nov", "Dec"}
-- A time in seconds, already local: "Sat 10 Oct 14:00", or the day only
local function when(t, day_only)
	local day = math.floor(t / 86400)
	local _, mo, d = civil(day)
	local s = string.format("%s %d %s", WEEKDAYS[day % 7 + 1], d, MONTHS[mo])
	if day_only then
		return s
	end
	return s .. string.format(" %02d:%02d", math.floor(t % 86400 / 3600),
			math.floor(t % 3600 / 60))
end
assert(when(0) == "Thu 1 Jan 00:00" and when(20736 * 86400 + 50400) ==
		"Sat 10 Oct 14:00" and when(11016 * 86400, true) == "Tue 29 Feb")

local function row_text(r, at, span)
	if not r or r[2] == 0 and r[6] == 0 and r[7] == 0 then
		return at .. ": nothing sampled"
	end
	return string.format("%s: players %d to %d, average %.1f; %d joins by "..
			"%d names, %d accounts made; tick gap at most %d ms, memory "..
			"%s; %d of %d minutes sampled", at, r[3], r[5], r[4], r[6], r[8],
			r[7], r[9], bytes(r[10]), r[2], span)
end

stats_page = function(back)
	local w = open_page("stats", "Statistics", back)
	graphs = {}
	local r0 = row(w)
	button(r0, "Refresh", function() M.admin("stats") end)
	local v = stats
	if not v then
		page_text(w, "Waiting for the server...")
		return
	end
	local width = w.width - 32
	local off = utc_offset()
	local function by_unit(rows)
		local t = {}
		for _, r in ipairs(rows or {}) do
			t[r[1]] = r
		end
		return t
	end

	page_text(w, "The week, by the hour (players: the most faint, the "..
			"average solid, the fewest a line)", WARN)
	local hours, hbars, gbars, hmarks = by_unit(v.hours), {}, {}, {}
	local first = v.hour - 167
	for i = 1, 168 do
		local r = hours[first + i - 1]
		local sampled = r and r[2] > 0
		hbars[i] = sampled and {r[3], r[4], r[5]} or false
		gbars[i] = sampled and {nil, r[9], r[9]} or false
		local t = (first + i - 1) * 3600 + off
		if t % 86400 < 3600 then
			hmarks[i] = when(t, true):sub(1, 3)
		end
	end
	local function hour_line(i)
		local t = (first + i - 1) * 3600 + off
		return row_text(hours[first + i - 1], when(t), 60)
	end
	local g1 = bar_graph(w, hbars, width, 110, hmarks, hour_line)
	page_text(w, "The longest tick gap in each hour", DIM)
	local g2 = bar_graph(w, gbars, width, 40, nil, hour_line)
	g1.label = page_text(w, "Point at a bar for its hour.", DIM)
	g2.label = g1.label

	page_text(w, "The half year, by the day", WARN)
	local days, dbars, nbars, mbars, dmarks = by_unit(v.days), {}, {}, {}, {}
	local dfirst = v.day - 181
	for i = 1, 182 do
		local r = days[dfirst + i - 1]
		local sampled = r and r[2] > 0
		dbars[i] = sampled and {r[3], r[4], r[5]} or false
		nbars[i] = r and {nil, r[8], r[8]} or false
		mbars[i] = r and {nil, r[7], r[7]} or false
		local _, _, d = civil(dfirst + i - 1)
		if d == 1 then
			local _, mo = civil(dfirst + i - 1)
			dmarks[i] = MONTHS[mo]
		end
	end
	local function day_line(i)
		local r = days[dfirst + i - 1]
		return row_text(r, when((dfirst + i - 1) * 86400, true), 1440)
	end
	local d1 = bar_graph(w, dbars, width, 110, dmarks, day_line)
	page_text(w, "Different players each day, and accounts made", DIM)
	local d2 = bar_graph(w, nbars, width, 40, nil, day_line)
	local d3 = bar_graph(w, mbars, width, 30, nil, day_line)
	d1.label = page_text(w, "Point at a bar for its day (UTC days).", DIM)
	d2.label, d3.label = d1.label, d1.label

	page_text(w, "Accounts", WARN)
	local parts = {}
	for name, n in pairs(v.levels or {}) do
		parts[#parts + 1] = n .. " " .. name
	end
	table.sort(parts)
	page_text(w, string.format("%d accounts: %s", tonumber(v.accounts) or 0,
			table.concat(parts, ", ")))
	page_text(w, string.format("Made in the last 30 days: %d. Not joined "..
			"in 90 days: %d.", tonumber(v.made_30) or 0,
			tonumber(v.idle_90) or 0))
	page_text(w, "The most time joined", WARN)
	for _, t in ipairs(v.top or {}) do
		page_text(w, string.format("%s: %s; last joined %s, made %s", t[1],
				duration(t[4]), t[3] > 0 and when(t[3] + off) or "never",
				t[2] > 0 and when(t[2] + off, true) or "before 0.6.75"))
	end
end
M.stats_page = function(back) stats_page(back) end

health_page = function(back)
	local w = open_page("health", "Health", back)
	local h = health
	local function head(t)
		page_text(w, t, WARN)
	end
	local r0 = row(w)
	button(r0, "Refresh", function() M.admin("health") end)
	if M.message and M.message ~= "" then
		page_text(r0, M.message, WARN):SetWordwrap(false)
	end
	if not h.running then
		page_text(w, "Waiting for the server...")
	end
	-- An app's own first (user: the app's sections first)
	if M.health_rows then
		M.health_rows(w)
	end

	head("Mail")
	local sm = type(h.smtp) == "table" and h.smtp or {}
	if sm.supported == false then
		page_text(w, "This server's libcurl cannot send mail (a minimal "..
				"build): install a full one.", ERROR)
	end
	page_text(w, "The server's mail server, for everything on it that "..
			"sends mail. smtp://host:587 (STARTTLS) or smtps://host:465.", DIM)
	local function edit(key, label, value, secret)
		local e = field(w, label, secret, function() end)
		e:SetText(hp.draft[key] or value or "")
		hp.edits[key] = e
		return e
	end
	local url = edit("url", "Server", sm.url)
	local from = edit("from", "From", sm.from)
	local user = edit("user", "User", sm.user)
	local pass = edit("password", "Password", "", true)
	page_text(w, sm.password_set and "A password is set; leave it empty to "..
			"keep it." or "No password set.", DIM)
	button(w, "Save the mail server", function()
		M.admin("smtp", "", encode({url = url:GetText(), from = from:GetText(),
				user = user:GetText(), password = pass:GetText()}))
		hp.draft.password = ""
	end)
	local to = edit("to", "Send to", "")
	button(w, "Send a test mail", function()
		M.admin("test_mail", "", to:GetText())
	end)
	if h.mail then
		page_text(w, h.mail, h.mail:sub(1, 5) == "Sent:" and nil or WARN)
	end
	page_text(w, "Only the mail server's answer is checked here. Whether "..
			"mail reaches inboxes (SPF, DKIM, DMARC) is for an online mail "..
			"tester: find one, send its address a test mail from here, and "..
			"read its report.", DIM)

	head("The server's sandbox")
	page_text(w, "Layers: " .. tostring(h.box ~= nil and h.box ~= "" and
			h.box or "?"))
	button(w, "Check the sandbox", function() M.admin("health", "", "", true) end)
	local bc = h.box_check
	if type(bc) == "table" then
		page_text(w, (bc.inside_ok and "OK: " or "FAIL: ") ..
				tostring(bc.inside), not bc.inside_ok and ERROR or nil)
		page_text(w, (bc.outside_refused and "OK: " or "FAIL: ") ..
				tostring(bc.outside), not bc.outside_refused and ERROR or nil)
	end

	if M.hello.announce == 1 then
		head("Starport listings")
		local info = starport_info
		for _, x in ipairs(info and info.starports or {}) do
			page_text(w, tostring(x.url) .. ": " .. tostring(x.status ~= "" and
					x.status or "not announced yet"))
		end
		if info and #(info.starports or {}) == 0 then
			page_text(w, "On no Starport (the Starports panel).", DIM)
		end
		button(w, "Announce now", function()
			M.admin("announce_now")
			-- The answers come in the next seconds
			buildat.send_packet("starport:config_get", "")
		end)
	end

	head("Address")
	local addr = buildat.server_address() or "?"
	local tls = buildat.connection_encrypted()
	page_text(w, "Reached at " .. tostring(addr) .. (tls and ", under TLS" or
			", not encrypted"))
	page_text(w, "Public address: " .. (admin_public_address() or
			"none (only an https address that is not this machine's or the "..
			"LAN's counts)"), DIM)

	head("Disk")
	page_text(w, tostring(h.disk_path or "?") .. ": " .. bytes(h.disk_used) ..
			" used, " .. bytes(h.disk_free) .. " free")
	if h.disk_saves then
		local limit = tonumber(h.disk_limit) or 0
		local used = h.disk_saves + h.disk_shared + h.disk_cache
		page_text(w, bytes(used) .. (limit > 0 and " of " .. bytes(limit) or
				" written, no limit") .. ": saves " .. bytes(h.disk_saves) ..
				", games and shared " .. bytes(h.disk_shared) .. ", cache " ..
				bytes(h.disk_cache), limit > 0 and used >= limit and ERROR or nil)
	end

	head("Running")
	local run = type(h.running) == "table" and h.running or {}
	page_text(w, "Buildat " .. tostring(run.version or "?") .. ", up " ..
			duration(run.uptime_s) .. ", " .. tostring(run.players or "?") ..
			" connected, ticks " .. string.format("%.0f ms (at most %.0f ms)",
			tonumber(run.tick_gap_ms_avg) or 0,
			tonumber(run.tick_gap_ms_max) or 0) .. ", memory " ..
			bytes(run.memory_bytes))

	head("Waiting on you")
	local n = tonumber(h.approvals) or 0
	if n > 0 then
		button(w, n .. " Starport ID(s) waiting to be let in", function()
			M.server_show("accounts")
		end)
	else
		page_text(w, "Nothing.", DIM)
	end

	head("The log: the last warnings and errors")
	local list = w:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedHeight(math.max(120, math.floor(magic.ui.root.height * 0.3)))
	-- A tenth less: the wrap measures short (starport_help's)
	local width = math.max(100, math.floor((w.width - 60) * 0.9))
	local lines = 0
	for line in tostring(h.log or ""):gmatch("[^\n]+") do
		local t = list:CreateChild("Text")
		t:SetStyleAuto()
		t:SetWordwrap(true)
		t:SetFixedWidth(width)
		t:SetText(line)
		if line:match("^%S+ %S+ E ") then
			t:SetColor(ERROR)
		end
		list:AddItem(t)
		lines = lines + 1
	end
	if lines == 0 then
		page_text(w, "None since the start.", DIM)
	end
	list.viewPosition = magic.IntVector2(0, 1000000)
	if back then
		button(w, "Back", go_back)
	end
end
M.health_page = function(back)
	M.admin("health")
	if M.hello.announce == 1 then
		buildat.send_packet("starport:config_get", "")
	end
	health_page(back)
end

--
-- **The Server window** ([SERVER_ADMIN_PAGE]; user, 2026-10-07): Starport's
-- window ([STARPORT_UI]) made builtin's. A sidebar of entries under grey
-- headers, each with a count of what waits on it; the page beside it,
-- scrolling inside the window, which keeps its size; under 560 px the
-- sidebar is a screen of its own ([STARPORT_UI_KEYS] for the keys).
-- builtin's entries are Mine / Account and an admin's Admin / Accounts,
-- the Starport panels (a server with starport_announce: never a Starport)
-- and Health. An app puts its own first:
--   accounts.server_menu = function(add)
--       add(header or nil, label, key, draw, count)
--   end
-- a header of the same name shared. Opened with on_close (a game's "My
-- account...") it has Close, its top page's Back closes it, and
-- M.close_page() closes it too; without, it is the app's own UI.
-- M.server_open(title, back) is an app's page in it, M.server_show(key)
-- an entry, M.server_sidebar() the sidebar drawn again, M.frame the
-- window (for a game's hit tests).
--
M.server_menu = nil

local function show_sidebar()
	drop_page()
	sw.app_back = nil
	sw.sidebar.visible = true
	sw.view.visible = false
end

-- What Back does at a page's top: the sidebar on a narrow screen; closing
-- a window a game opened
local function top_back()
	if sw.narrow then
		return show_sidebar
	end
	return sw.on_close and function() server_close() end or nil
end

server_entries = function()
	local list, by = {}, {}
	local function add(header, label, key, draw, count)
		local h = header or ""
		if not by[h] then
			by[h] = {header = header, items = {}}
			list[#list + 1] = by[h]
		end
		local items = by[h].items
		items[#items + 1] = {label = label, key = key, draw = draw,
			count = count}
	end
	if M.server_menu then
		M.server_menu(add)
	end
	add("Mine", "Account", "account", function()
		account_page(top_back())
	end)
	-- [ADMIN_NOTIFY] A Steward's or the Host's (the users list says so)
	if M.users and M.users.level >= 30 then
		add("Mine", "Pushes (ntfy)", "ntfy", function()
			if ntfy_state.ask then
				ntfy_page(top_back())
			else
				M.ntfy_page(top_back())
			end
		end)
	end
	if M.hello and M.hello["local"] == 1 then
		add("Mine", "Open to LAN", "lan", function()
			local w = M.server_open("Open to LAN")
			page_text(w, "Players on this network find the server in " ..
					"their launcher's \"On this network\" and join it; " ..
					"until then it listens on this computer only.")
			M.lan_row(w)
		end)
	end
	-- The users list arriving says a moderator or the admin (the server
	-- answers no one else); a moderator's is the Accounts page only
	if M.users then
		local admin = M.users.level >= 40
		add(admin and "Admin" or "Moderation", "Accounts", "accounts",
				function()
			M.admin("list")
			users_page(top_back())
		end, #(M.users.approvals or {}))
		if not admin then
			add("Moderation", "Statistics", "stats", function()
				M.admin("stats")
				stats_page(top_back())
			end)
		end
	end
	if M.users and M.users.level >= 40 then
		if M.hello.announce == 1 then
			for _, x in ipairs({{"Starports", "starports"},
					{"Listing", "listing"}, {"ID logins", "ids"}}) do
				add("Admin", x[1], x[2], function()
					M.starport_page(top_back(), x[2])
				end)
			end
		end
		add("Admin", "Statistics", "stats", function()
			M.admin("stats")
			stats_page(top_back())
		end)
		add("Admin", "Health", "health", function()
			M.health_page(top_back())
		end)
	end
	return list
end

local function side_button(label, color, on_click)
	local b = sw.sidebar:CreateChild("Button")
	b:SetStyleAuto()
	b:SetFixedHeight(26)
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(label)
	t:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
	t.position = magic.IntVector2(8, 0)
	if color then
		t:SetColor(color)
	end
	magic.SubscribeToEvent(b, "Released", function() on_click() end)
end

-- simplified: a count is "any waiting", in the highlight colour; per-item
-- seen times are the upgrade
-- The height the sidebar's entries take, and the window's margins
sidebar_need = function()
	local h, n = 16, 0
	for i = 0, sw.sidebar:GetNumChildren() - 1 do
		local c = sw.sidebar:GetChild(i)
		if c then
			h, n = h + c.height, n + 1
		end
	end
	return h + 2 * math.max(0, n - 1)
end

draw_sidebar = function()
	if not sw.frame then
		return
	end
	sw.sidebar:RemoveAllChildren()
	for _, sec in ipairs(server_entries()) do
		if sec.header then
			page_text(sw.sidebar, sec.header, DIM)
		end
		for _, e in ipairs(sec.items) do
			local count = tonumber(e.count) or 0
			side_button((e.key == sw.current and "> " or "") .. e.label ..
					(count > 0 and " (" .. count .. ")" or ""),
					count > 0 and WARN or nil, function()
				M.server_show(e.key)
			end)
		end
	end
	-- [SERVER_VERSION]: the server's Buildat and this client's, read-only
	-- fields to copy into a ticket
	local version, hash = buildat.version()
	for _, v in ipairs({{"Server", M.hello.version or "?"},
			{"This client", tostring(version) ..
				(hash and hash ~= "" and "-" .. hash or "")}}) do
		page_text(sw.sidebar, v[1], DIM)
		local e = sw.sidebar:CreateChild("LineEdit")
		e:SetStyleAuto()
		e:SetFixedHeight(22)
		e.editable = false
		e.textCopyable = true
		e.textSelectable = true
		-- Small enough for "0.6.75-ea7eb9e33-dirty" in the sidebar
		e.textElement:SetFontSize(9)
		e:SetText(v[2])
		e.cursorPosition = 0
		-- Once a window, for a check: the scan does not see this window
		if not sw.versions_logged then
			log:info("server window: " .. v[1] .. " Buildat " .. v[2])
		end
	end
	sw.versions_logged = true
	-- More entries than the window was made for (an admin's, with the
	-- users list): made again, the frame after
	if not sw.building and not sw.refit and sidebar_need() > sw.frame.height then
		sw.refit = true
		local sub
		sub = magic.SubscribeToEvent("Update", function()
			magic.UnsubscribeFromEvent("Update", sub)
			-- Closed meanwhile
			if not sw.refit then
				return
			end
			local key, on_close = sw.current, sw.on_close
			server_close(true)
			M.server_window(key, on_close)
		end)
	end
end
M.server_sidebar = function() draw_sidebar() end

local function build_frame()
	local root = magic.ui.root
	local f = page_window(880)
	f:SetLayout(magic.LM_HORIZONTAL, 8, magic.IntRect(8, 8, 8, 8))
	sw.frame = f
	M.frame = f
	sw.sidebar = f:CreateChild("UIElement")
	sw.sidebar:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	sw.building = true
	draw_sidebar()
	sw.building = nil
	-- **As tall as its sidebar** (user, 2026-10-09): on a phone turned or
	-- at a big UI size the entries ran off the screen's bottom. Taller
	-- than the screen, the client's fit (update_ui_fit) brings the UI's
	-- scale down for it, and the window takes the width that frees: the
	-- screen's shape at its height, less the black round it (50) and a
	-- margin. A scale does not change that shape, so the fit has nothing
	-- of its own to follow.
	local h = math.max(math.floor(root.height * 0.8), sidebar_need())
	f:SetFixedHeight(h)
	if h + 50 > root.height * 0.98 then
		f:SetFixedWidth(math.max(f.width, math.floor((h + 50) *
				root.width / root.height * 0.96) - 50))
	end
	local inner = f.width - 16
	sw.narrow = f.width < 544
	sw.sidebar:SetFixedWidth(sw.narrow and inner or 150)
	sw.view = f:CreateChild("ScrollView")
	sw.view:SetStyleAuto()
	sw.view:SetFixedWidth(sw.narrow and inner or inner - 150 - 8)
	sw.view.scrollBarsAutoVisible = true
	-- Less the vertical bar and a margin
	sw.width = sw.view.width - 24
	-- [STARPORT_UI_KEYS]: Up and Down in the sidebar or the page, Right
	-- and Left between them
	local columns = (ui_utils.safe or ui_utils).keyboard_columns
	columns(f, sw.sidebar, sw.view)
	if sw.narrow then
		sw.view.visible = false
	end
	-- Not on the stack, so its own on_close ([CLOSE_GLYPH])
	local glyph = (ui_utils.safe or ui_utils).close_glyph
	if sw.on_close then
		glyph(root, f, function() server_close() end)
	elseif sw.on_exit then
		-- An app's own window: the × is its on_exit ([STARPORT_CLOSE])
		glyph(root, f, function() sw.on_exit() end)
	end
end

-- The page's element in the window's right side, the last one gone
server_element = function()
	if sw.page then
		pcall(function() sw.page:Remove() end)
	end
	local p = sw.view:CreateChild("UIElement")
	p:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(4, 4, 8, 4))
	p:SetFixedWidth(sw.width)
	sw.view.contentElement = p
	sw.view.viewPosition = magic.IntVector2(0, 0)
	if sw.narrow then
		sw.sidebar.visible = false
		sw.view.visible = true
	end
	sw.page = p
	sw.app_back = nil
	return p
end

-- An app's page in the window: a Back over its title when there is
-- somewhere to go back to (`back`, a step inside the app's page)
function M.server_open(title, back)
	drop_page()
	local w = server_element()
	local b = back or top_back()
	sw.app_back = b
	if b then
		button(row(w), "Back", b)
	end
	page_text(w, title)
	return w
end

-- The entry `key` shown; false if there is none (yet)
function M.server_show(key)
	for _, sec in ipairs(server_entries()) do
		for _, e in ipairs(sec.items) do
			if e.key == key then
				sw.current = key
				draw_sidebar()
				e.draw()
				-- What a check waits for
				log:info("server window: the page " .. key)
				return true
			end
		end
	end
	return false
end

function M.server_current()
	return sw.current
end

-- The window up at `key`, or the first entry. An admin's entries come
-- with the users list; one asked for before it is shown when it comes
-- on_exit: for an app whose own UI this is, what its × does (it does not
-- close the window), M.ask_exit where there is a launcher
function M.server_window(key, on_close, on_exit)
	-- Before the frame: its sidebar has Close
	sw.on_close = on_close
	sw.on_exit = on_exit
	if not sw.frame then
		build_frame()
	end
	-- **Black behind a window a game opened** (user, 2026-10-07), 25 UI
	-- pixels round it: told apart from the game's UI under it
	if on_close and not sw.backdrop then
		local b = magic.ui.root:CreateChild("BorderImage")
		b.color = magic.Color(0, 0, 0, 1)
		-- Over the game's own windows (100), the window over it
		b.priority = 101
		sw.frame.priority = 102
		b.width = sw.frame.width + 50
		b.height = sw.frame.height + 50
		b.horizontalAlignment = magic.HA_CENTER
		b.verticalAlignment = magic.VA_CENTER
		b:SetPosition(0, 0)
		sw.backdrop = b
	end
	if not M.users and not M.list_asked then
		M.list_asked = true
		M.admin("list")
	end
	if not M.server_show(key or sw.current or "") then
		sw.wanted = key
		M.server_show(server_entries()[1].items[1].key)
	end
end

-- silent: not going back to what opened it (the game closes it itself)
server_close = function(silent)
	drop_page()
	local on_close = sw.on_close
	if sw.frame then
		sw.frame:Remove()
		log:info("server window: closed")
	end
	if sw.help then
		sw.help:Remove()
	end
	if sw.backdrop then
		sw.backdrop:Remove()
	end
	sw = {}
	M.frame = nil
	if on_close and not silent then
		on_close()
	end
end
M.server_close = function(silent) server_close(silent) end

-- **A click off a window a game opened closes it** (user, 2026-10-07),
-- as Close does; not a click on its dropdown or its help. On the
-- release, pressed off as well, so that the click that opened it does not
-- count. The app's own window (Starport's) stays.
local pressed_off = false
local function off_window()
	if not (sw.frame and sw.on_close) then
		return false
	end
	local sc = magic.ui.scale or 1
	local m = magic.input:GetMousePosition()
	local ux, uy = m.x / sc, m.y / sc
	for _, el in ipairs({sw.frame, sw.help or false}) do
		if el then
			local p, sz = el.screenPosition, el.size
			if ux >= p.x and uy >= p.y and ux < p.x + sz.x and
					uy < p.y + sz.y then
				return false
			end
		end
	end
	return true
end
magic.SubscribeToEvent("MouseButtonDown", function()
	-- A press off a dropdown's popup closes only that
	pressed_off = not ui_utils.dropdown_open() and off_window()
end)
magic.SubscribeToEvent("MouseButtonUp", function()
	if pressed_off and off_window() then
		server_close()
	end
	pressed_off = false
end)

-- Back from where the window or a page is, as a Back button: for a game's
-- Esc. False at the top of a window that is the app's own.
M.back = function()
	if ui_utils.dropdown_open() then
		return true
	end
	if M.page and page_back then
		go_back()
		return true
	end
	if sw.frame then
		if sw.app_back then
			sw.app_back()
			return true
		end
		if sw.narrow and sw.view.visible then
			show_sidebar()
			return true
		end
		if sw.on_close then
			server_close()
			return true
		end
	end
	return false
end

--
-- **The chat console** ([CHAT_CONSOLE]): the chat as a page of its own, a
-- log that scrolls and a line to type in, for a touchscreen, where there
-- is no key to open a game's chat line, and for reading back. The game
-- hands it every line with chat_add() and sets chat_send(text).
--
M.chat_lines = {}
M.chat_send = nil
local CHAT_KEEP = 200
-- **Chats by channel** ([FP_GROUP_CHAT]): an app with more than one sets
-- chat_channels() -> {{key =, label =}, ...} (keys are strings), the
-- first the default;
-- chat_add(line, key) files a line under a key, and chat_send(text, key)
-- gets the picked one. A channel not shown counts its new lines. With
-- none set, one chat (vanilla's): the key is nil.
M.chat_channels = nil
local chat_by = {}
local chat_unread = {}
-- The open page's dropdown labels made again, its popup reading them
local chat_relabel = nil
-- The picked channel, kept per server; the first when it is gone
local function chat_channel()
	local list = M.chat_channels and M.chat_channels() or {}
	if #list == 0 then
		return nil, list
	end
	local saved = buildat.storage_read("chat_channel")
	for _, c in ipairs(list) do
		if c.key == saved then
			return c.key, list
		end
	end
	return list[1].key, list
end

local function chat_row(text)
	local t = chat_list:CreateChild("Text")
	t:SetStyleAuto()
	t:SetWordwrap(true)
	t:SetFixedWidth(chat_width)
	t:SetText(text)
	chat_list:AddItem(t)
end

local function chat_to_end()
	chat_list.viewPosition = magic.IntVector2(0, 1000000)
end

-- The channel the chat page shows, nil with none
function M.chat_shown()
	return (chat_channel())
end

-- old: a line from before (a login's backlog), not counted as new
function M.chat_add(line, key, old)
	local lines = M.chat_lines
	if key ~= nil then
		chat_by[key] = chat_by[key] or {}
		lines = chat_by[key]
	end
	lines[#lines + 1] = line
	while #lines > CHAT_KEEP do
		table.remove(lines, 1)
	end
	local shown = chat_channel()
	if key ~= shown then
		if not old then
			chat_unread[key] = (chat_unread[key] or 0) + 1
			if chat_list and page_kind == "chat" and chat_relabel then
				chat_relabel()
			end
		end
	elseif chat_list then
		chat_row(line)
		chat_to_end()
	end
end

-- [CHAT_FIELD_TOUCH]: the screen's top half, as Luanti's chat console. A
-- keyboard over more than the lower half (a phone on its side) has the
-- field row first, with no title; the page is made again as the screen or
-- the keyboard changes, the field's text kept.
function M.chat_page(back, draft)
	local key, list = chat_channel()
	chat_relabel = nil
	local root = magic.ui.root
	local rw, rh = root.width, root.height
	local tall = buildat.keyboard_height() > rh / 2
	local w = open_page("chat", not tall and "Chat" or nil, back, nil, nil, true)
	local e
	local function field_row()
		local r = row(w)
		e = r:CreateChild("LineEdit")
		e:SetStyleAuto()
		e.minHeight = 28
		e.textCopyable = true
		e.textSelectable = true
		e:SetText(draft or "")
		local function send()
			local text = e:GetText()
			if text ~= "" and M.chat_send then
				M.chat_send(text, key)
			end
			e:SetText("")
		end
		magic.SubscribeToEvent(e, "TextFinished", send)
		local b = button(r, "Send", send)
		b:SetFixedWidth(b.minWidth)
	end
	if tall then
		field_row()
	end
	chat_width = math.max(100, w.width - 32 - 28)
	if key ~= nil then
		chat_unread[key] = nil
		-- "name" or "name: 3 new"; a name twice gets its key. Made again
		-- in place as lines come, so the popup reads the counts as they are
		local labels, by_label = {}, {}
		chat_relabel = function()
			local seen = {}
			for k in pairs(by_label) do
				by_label[k] = nil
			end
			for i, c in ipairs(list) do
				local l = c.label
				if seen[l] then
					l = l .. " #" .. tostring(c.key)
				end
				seen[c.label] = true
				local n = chat_unread[c.key]
				l = l .. (n and n > 0 and (": " .. n .. " new") or "")
				labels[i] = l
				by_label[l] = c.key
				if c.key == key then
					labels.current = l
				end
			end
		end
		chat_relabel()
		local b = dropdown(row(w), "Chat in", labels, labels.current,
				function(l)
			buildat.storage_write("chat_channel", by_label[l])
			M.chat_page(back, e and e:GetText())
		end)
		b:SetFixedWidth(math.max(118, math.min(300, w.width - 180)))
	end
	chat_list = w:CreateChild("ListView")
	chat_list:SetStyleAuto()
	chat_list:SetFixedHeight(40)
	for _, line in ipairs(key == nil and M.chat_lines or chat_by[key] or {}) do
		chat_row(line)
	end
	if not tall then
		field_row()
	end
	button(w, "Back", go_back)
	-- The log takes what the rest leaves of half the screen (8 above it)
	chat_list:SetFixedHeight(math.max(40, 40 + math.floor(rh / 2) - 8 - w.height))
	chat_to_end()
	e:SetFocus(true)
	local sub, told
	sub = magic.SubscribeToEvent("Update", function()
		if M.page ~= w then
			magic.UnsubscribeFromEvent("Update", sub)
			return
		end
		-- Where it is, a frame on, for a check
		if not told then
			told = true
			log:info(string.format("chat page: y %d to %d of %d, the field row %s",
					w.screenPosition.y, w.screenPosition.y + w.height, rh,
					tall and "first" or "last"))
		end
		if root.width ~= rw or root.height ~= rh or
				(buildat.keyboard_height() > root.height / 2) ~= tall then
			magic.UnsubscribeFromEvent("Update", sub)
			M.chat_page(back, e:GetText())
		end
	end)
end

-- [ACCOUNT_BUTTON]: a way into the account page the app does not have to
-- place. Drawn in a corner once joined, unless the app has its own entry and
-- turned it off. Aitta and Hearth, which place none, reach their accounts by
-- it. An admin goes on from account_page's "Accounts..." (users_page).
function M.no_account_button()
	account_button_off = true
	if account_button then
		account_button:Remove()
		account_button = nil
	end
end

show_account_button = function()
	if account_button_off or account_button then
		return
	end
	local b = magic.ui.root:CreateChild("Button")
	-- Its own style, like page_window, for a game whose root has none
	b.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	b:SetStyleAuto()
	b.minHeight = 28
	b.priority = 100
	b:SetFocusMode(magic.FM_FOCUSABLE)
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	-- "Server": it opens the Server window (user, 2026-10-07)
	t:SetText("Server")
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b:SetFixedWidth(t.width + 24)
	b:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
	b:SetPosition(-8, 8)
	magic.SubscribeToEvent(b, "Released", function()
		-- Closing the window is all; the app's own UI is under it
		M.server_window("account", function() end)
	end)
	account_button = b
end

-- The join: the server's hello brings the dialog, or the scripted login
function M.start(o)
	opts = o or {}
	buildat.send_packet("accounts:get_hello", "")
end

return M
-- vim: set noet ts=4 sw=4:
