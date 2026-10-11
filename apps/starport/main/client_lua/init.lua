-- Buildat: apps/starport/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Starport's own pages** ([STARPORT] 1, 2a, 6): what an operator, a
-- moderator and the admin see after joining. Every page asks the server
-- with a JSON "sp:req" {id, cmd, ...} and draws its "sp:res"; the server
-- (main.cpp) decides who may do what.
--
-- **One window** ([STARPORT_UI]): builtin/accounts' Server window
-- ([SERVER_ADMIN_PAGE]), Starport's pages put in its sidebar before
-- builtin's (Mine / Account, Admin / Accounts, Health). The Overview
-- comes first.
--
-- A scripted client sends BUILDAT_SP_REQS, JSON requests a line each, in
-- order after the join, and logs each answer as "sp: <json>".
local log = buildat.Logger("starport")
local magic = require("buildat/extension/urho3d")
local ui = require("buildat/extension/ui_utils")
ui = ui.safe or ui
-- Light enough to load again by itself when a phone's browser dropped it in
-- the background (src/client/web/index.html, [WEB_RELOAD_APPS])
buildat.set_reload_on_return(true)

local _, accounts_err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("starport: could not load accounts.lua: " .. tostring(accounts_err))
end

--
-- Requests
--
local redraw = nil   -- the page open, drawn again
local page_back = nil -- its Back, for a page inside a page
local message = nil  -- a line for the top of the next page drawn

-- on(result) on success; a failure is shown on the page that asked
local req = accounts.requester("sp", function(why)
	message = why
	if redraw then
		redraw()
	end
end, (buildat.get_env("BUILDAT_SP_REQS") or "") ~= "")

--
-- Pages
--
local YELLOW = magic.Color(1.0, 0.8, 0.4)
local GREY = magic.Color(0.7, 0.7, 0.7)
local text = accounts.page_text
local button = accounts.page_button

local row = accounts.page_row
local function edit(parent, label, value)
	return accounts.page_field(parent, label, false, nil, value)
end

-- [STARPORT_COPY_IDS]: an id or line the operator pastes elsewhere (a
-- fleet's join line, a listing id, a blocklist scope), as a read-only but
-- selectable/copyable field with a Copy button (accounts.lua's pattern).
-- Fills the row `r`; copy_field makes the row under `parent` first.
local function copy_into(r, label, value, maxw)
	value = value == nil and "" or tostring(value)
	if label then
		local l = text(r, label)
		l:SetWordwrap(false)
		l.minWidth = 100
	end
	local e = r:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.minWidth = math.min(maxw or 260, 260)
	e.editable = false
	e.textCopyable = true
	e.textSelectable = true
	e:SetText(value)
	button(r, "Copy", function() magic.ui:SetClipboardText(value) end)
	return e
end
local function copy_field(parent, label, value)
	return copy_into(row(parent), label, value)
end

-- A page: drawn into the window's right side, with the title, a Back for
-- a step inside a page (`back`), and the message the last request left.
-- `draw` draws it again, as after a failed request
local function open(title, draw, back)
	local w = accounts.server_open(title, back)
	redraw, page_back = draw, back
	if message then
		text(w, message, YELLOW)
		message = nil
	end
	return w
end

-- A page's rows, wrapping to its width. They go into the page itself,
-- and the Server window's own view is the one scroll, as on Health
-- ([STARPORT_LIST_FILL]: a list of a fixed share of the screen left a
-- margin under it, or a second scroll bar in the first)
local function list(w)
	local add = {}
	function add.text(t, color)
		return text(w, t, color)
	end
	function add.button(t, on)
		local r = row(w)
		button(r, t, on)
		return r
	end
	function add.row()
		return row(w)
	end
	-- [STARPORT_COPY_IDS]: a copyable id/line as a row
	function add.copy(label, value)
		return copy_into(row(w), label, value)
	end
	return add
end

local function s(v)
	return v == nil and "" or tostring(v)
end
-- "YYYY-MM-DD HH:MM" in UTC; the sandbox has no os.date (days to a date:
-- Howard Hinnant's civil_from_days)
local function when(ts)
	ts = math.floor(tonumber(ts) or 0)
	local z = math.floor(ts / 86400) + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) +
			math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	local y = yoe + era * 400 + (m <= 2 and 1 or 0)
	local sec = ts % 86400
	return string.format("%04d-%02d-%02d %02d:%02d", y, m, d,
			math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end
assert(when(0) == "1970-01-01 00:00" and
		when(1790926649) == "2026-10-02 07:37" and
		when(951782400) == "2000-02-29 00:00")

-- The evidence a report carries, back to the JPEG it was
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_AT = {}
for i = 1, 64 do
	B64_AT[B64:sub(i, i)] = i - 1
end
local function unbase64(text)
	local out = {}
	local n, bits = 0, 0
	for c in text:gmatch("[%w%+/]") do
		n = n * 64 + B64_AT[c]
		bits = bits + 6
		if bits >= 8 then
			bits = bits - 8
			local byte = math.floor(n / 2 ^ bits)
			out[#out + 1] = string.char(byte)
			n = n - byte * 2 ^ bits
		end
	end
	return table.concat(out)
end
assert(unbase64("TWFu") == "Man" and unbase64("TWE=") == "Ma" and
		unbase64("TQ==") == "M")

local function categories(l)
	local d = {}
	for k, v in pairs(l.descriptors or {}) do
		if v ~= "no" and v ~= "none" then
			d[#d + 1] = k .. ": " .. s(v)
		end
	end
	table.sort(d)
	return s(l.kind) .. ", " .. s(l.audience) .. ", " .. s(l.access) ..
			(#d > 0 and " (" .. table.concat(d, ", ") .. ")" or "")
end

local home, queue_page, group_page, listings_page, listing_page
local audit_page, appeals_page, settings_page, appeal_page, fleets_page
local sites_page
local blocklists_page

-- What a moderator does to a listing ([STARPORT] 6), for a group's
-- reports (decide) or on its own (act)
local function action_rows(w, on_action)
	local why = edit(w, "Statement", "")
	local days = edit(w, "Days (0: open)", "0")
	local audience = edit(w, "Relabel audience", "")
	local r = row(w)
	local function go(action, extra)
		local q = {action = action, text = why:GetText(),
			days = tonumber(days:GetText()) or 0}
		for k, v in pairs(extra or {}) do
			q[k] = v
		end
		on_action(q)
	end
	button(r, "Relabel", function()
		go("relabel", {fields = {audience = audience:GetText()}})
	end)
	button(r, "Hide", function() go("hide") end)
	button(r, "Delist", function() go("delist") end)
	button(r, "Ban", function() go("ban") end)
	button(r, "Ban + account", function() go("ban", {ban_account = true}) end)
	button(r, "Illegal (CSAM)", function() go("csam") end)
	button(r, "Restore", function() go("restore") end)
end

-- The last "me": the sidebar's entries and counts, and the Overview's
local me = {}
local overview_page, servers_page

-- The entries, before builtin's: a count of what waits on each
accounts.server_menu = function(add)
	add(nil, "Overview", "overview", overview_page, me.unseen_events)
	add("Mine", "Servers", "servers", servers_page)
	add("Mine", "Fleets", "fleets", function() fleets_page(me) end)
	add("Mine", "Sites", "sites", function() sites_page(me) end)
	add("Mine", "Blocklists", "blocklists", function() blocklists_page(me) end,
			me.blocklist_offers)
	if me.moderator then
		add("Moderation", "Queue", "queue", queue_page, me.queue)
		add("Moderation", "Listings", "listings",
				function() listings_page("") end)
		add("Moderation", "Appeals", "appeals", appeals_page, me.open_appeals)
		add("Moderation", "Audit log", "audit", audit_page)
	end
	if me.admin then
		add("Admin", "Settings", "settings", settings_page)
	end
end

-- "me" asked again, the sidebar drawn with it, and `draw` after
local function refresh(draw)
	req("me", {}, function(r)
		me = r
		if not accounts.frame then
			accounts.server_window("overview", nil,
					accounts.can_exit and accounts.can_exit() and
					accounts.ask_exit or nil)
		else
			accounts.server_sidebar()
			if draw then
				draw()
			end
		end
	end)
end

-- The page open drawn again, with "me" asked again first
home = function()
	local key = accounts.server_current()
	refresh(function() accounts.server_show(key) end)
end

overview_page = function()
	req("overview", {}, function(ov)
		local w = open("Overview", overview_page)
		local n = me.notice
		if type(n) == "table" and s(n.text) ~= "" then
			text(w, "Admin notice: " .. n.text,
					n.priority == "high" and YELLOW or nil)
		end
		-- The standing
		text(w, s(me.starport) .. " account " .. s(me.name) ..
				(me.suspended and ", suspended until " ..
				when(me.suspended_until) or ", in good standing") ..
				". Two-step login " .. (me.totp and "on" or "off") ..
				". E-mail " .. (s(me.email_pending) ~= "" and
				"not confirmed yet" or s(me.email) ~= "" and "confirmed" or
				"not set") .. ".", GREY)
		-- What waits: while it lasts, never as an event
		local waiting = {}
		local function wait(t, key, open_it)
			waiting[#waiting + 1] = {t, open_it or function()
				accounts.server_show(key)
			end}
		end
		for _, st in ipairs(me.statements or {}) do
			if not st.appealed then
				wait(s(st.listing_name) .. ": " .. s(st.action) ..
						" -- a statement you may appeal", nil, function()
					appeal_page(st)
				end)
			end
		end
		if (tonumber(me.blocklist_offers) or 0) > 0 then
			wait(me.blocklist_offers .. " offer(s) to your blocklists",
					"blocklists")
		end
		if s(me.email_pending) ~= "" then
			wait("Your e-mail is not confirmed", "account")
		end
		for _, x in ipairs(me.listings or {}) do
			if s(x.served) ~= "listed" or x.pool_mismatch then
				wait(s(x.name) .. ": " .. (x.pool_mismatch and
						"differs from its pool" or s(x.served)), "servers")
			end
		end
		if me.moderator then
			if (tonumber(me.queue) or 0) > 0 then
				wait(me.queue .. " report group(s) in the queue", "queue")
			end
			if (tonumber(me.open_appeals) or 0) > 0 then
				wait(me.open_appeals .. " open appeal(s)", "appeals")
			end
			if not me.totp then
				-- [STARPORT] 10a: recommended to whoever moderates
				wait("Turn two-step login on", "account")
			end
		end
		if #waiting > 0 then
			text(w, "Waiting for you")
			for _, x in ipairs(waiting) do
				button(row(w), x[1], x[2])
			end
		end
		text(w, "Recent events")
		local l = list(w)
		for _, e in ipairs(ov.events or {}) do
			l.text(when(e.ts) .. "  " .. s(e.text),
					(tonumber(e.ts) or 0) > (tonumber(ov.seen) or 0) and
					YELLOW or nil)
		end
		if #(ov.events or {}) == 0 then
			l.text("Nothing yet.", GREY)
		end
		if (tonumber(me.unseen_events) or 0) > 0 then
			me.unseen_events = 0
			accounts.server_sidebar()
		end
	end)
end

-- The operator's servers ([STARPORT] 2a): claiming, the listings and
-- their statements
servers_page = function()
	local w = open("Servers", servers_page)
	text(w, "Claiming a listing: its id and claim code are in "..
			"starport_claim.txt beside the server's starport.json.", GREY)
	text(w, "A server with a new key: the listing it replaces too.",
			GREY)
	local cl = edit(w, "Listing id", "")
	local cc = edit(w, "Claim code", "")
	local cr = edit(w, "Replaces (optional)", "")
	button(row(w), "Claim", function()
		req("claim", {listing = cl:GetText(), code = cc:GetText(),
			replaces = cr:GetText()}, function()
			message = "Claimed."
			home()
		end)
	end)
	local l = list(w)
	for _, x in ipairs(me.listings or {}) do
		l.text(s(x.name) .. " (" .. s(x.host) .. ":" ..
				s(x.port) .. "): " .. s(x.served) ..
				(s(x.fleet) ~= "" and "; fleet " .. x.fleet ..
				(s(x.pool) ~= "" and ", pool " .. x.pool or "") ..
				(x.pool_mismatch and " (differs from its pool)" or "")
				or ""))
		l.copy("listing id", s(x.id))
		if s(x.fleet) ~= "" then
			l.button("Remove from the fleet", function()
				req("fleet_remove_server", {listing = x.id}, home)
			end)
		end
	end
	for _, st in ipairs(me.statements or {}) do
		l.text(when(st.ts) .. " " .. s(st.listing_name) .. ": " ..
				s(st.action) .. " for " .. s(st.reason) .. ". " ..
				s(st.text), YELLOW)
		l.button(st.appealed and "Appeal again" or "Appeal", function()
			appeal_page(st)
		end)
	end
end

-- The contact e-mail ([STARPORT] 2a), on builtin's Account page (the
-- password, two-step login, logging out)
accounts.account_extra = function(w)
	redraw, page_back = home, nil
	if message then
		text(w, message, YELLOW)
		message = nil
	end
	if s(me.email) ~= "" then
		text(w, "Contact e-mail (not shown to users): " .. me.email, GREY)
	end
	local email = edit(w, "Contact e-mail", s(me.email_pending) ~= "" and
			me.email_pending or me.email)
	button(row(w), "Set e-mail", function()
		req("set_email", {email = email:GetText()}, function(how)
			message = how == "sent" and "A code went to that address;"..
					" enter it below." or "Set."
			home()
		end)
	end)
	if s(me.email_pending) ~= "" then
		local code = edit(w, "Code from the mail", "")
		button(row(w), "Confirm", function()
			req("confirm_email", {code = code:GetText()}, function()
				message = "Confirmed."
				home()
			end)
		end)
	end
end

-- An operator's fleets ([STARPORT] 2b): a server joins one by the line
-- shown here in its starport.json
fleets_page = function(me)
	local w = open("Fleets", function() fleets_page(me) end)
	text(w, "A server joins a fleet by a line in its starport.json; "..
			"servers that only split the load also name the same pool.",
			GREY)
	local l = list(w)
	for _, f in ipairs(me.fleets or {}) do
		l.text(s(f.name) .. ": " .. s(f.description) .. " " .. s(f.link))
		l.copy("starport.json line", '"fleet": "' .. s(f.id) .. ":" ..
				s(f.code) .. '", "pool": "main"')
		local r = l.row()
		button(r, "New code (servers with the old one leave)", function()
			req("fleet_new_code", {fleet = f.id}, function()
				req("me", {}, fleets_page)
			end)
		end)
	end
	local name = edit(w, "Name", "")
	local description = edit(w, "Description", "")
	local link = edit(w, "Link", "")
	local r = row(w)
	button(r, "Make a fleet", function()
		req("fleet_create", {name = name:GetText(),
			description = description:GetText(), link = link:GetText()},
				function()
			req("me", {}, fleets_page)
		end)
	end)
end

-- [STARPORT_SITE_LOGIN] An operator's websites: each signs its visitors
-- in by a Starport ID, in this Starport's window, the token sent to the
-- site's origin and signed with its secret (doc/starport.txt)
sites_page = function(me)
	local w = open("Sites", function() sites_page(me) end)
	text(w, "A website signs its visitors in by opening this Starport's "..
			"/authorize?site=<id> in a window; the token comes back to the "..
			"site's origin by postMessage, and the site checks it with the "..
			"secret (doc/starport.txt). A visitor's name there is their own "..
			"for the site.", GREY)
	local l = list(w)
	for _, f in ipairs(me.sites or {}) do
		l.text(s(f.name) .. " at " .. s(f.origin) .. ", id " .. s(f.id))
		l.copy("Secret", s(f.secret))
		local r = l.row()
		button(r, "New secret (tokens signed with the old fail)", function()
			req("site_new_secret", {site = f.id}, function()
				req("me", {}, sites_page)
			end)
		end)
		button(r, "Remove", function()
			req("site_remove", {site = f.id}, function()
				req("me", {}, sites_page)
			end)
		end)
	end
	local name = edit(w, "Name", "")
	local origin = edit(w, "Origin (https://host[:port])", "")
	button(row(w), "Register a site", function()
		req("site_create", {name = name:GetText(), origin = origin:GetText()},
				function()
			req("me", {}, sites_page)
		end)
	end)
end

-- 10d: blocklists, public within the Starport. A server publishes its
-- reported bans to a list (its owner's at once, another's when accepted)
-- and subscribes to any list for its bans
blocklists_page = function(me)
	req("blocklists", {}, function(lists)
		local w = open("Blocklists", function() blocklists_page(me) end)
		-- The account's own fleets and servers, as the scope to act for
		local scopes = {}
		for _, f in ipairs(me.fleets or {}) do
			scopes[#scopes + 1] = "fleet:" .. s(f.id)
		end
		for _, x in ipairs(me.listings or {}) do
			if s(x.fleet) == "" then
				scopes[#scopes + 1] = "listing:" .. s(x.id)
			end
		end
		if #scopes > 0 then
			text(w, "Yours (copy one into Acting for):", GREY)
			for _, sc in ipairs(scopes) do
				copy_field(w, nil, sc)
			end
		else
			text(w, "Yours: no fleets or servers", GREY)
		end
		local scope = edit(w, "Acting for", scopes[1] or "")
		local l = list(w)
		for _, b in ipairs(lists) do
			l.text(s(b.name) .. " (" .. s(b.owner) .. "): " .. s(b.bans) ..
					" bans; publishers " .. table.concat(b.publishers or {},
					", ") .. "; subscribers " .. #(b.subscribers or {}))
			local r = l.row()
			local function go(cmd, extra)
				local q = {list = b.id, scope = scope:GetText()}
				for k, v in pairs(extra or {}) do
					q[k] = v
				end
				req(cmd, q, function()
					req("me", {}, blocklists_page)
				end)
			end
			button(r, "Publish to it", function() go("blocklist_publish") end)
			button(r, "Stop", function() go("blocklist_unpublish") end)
			button(r, "Subscribe", function() go("blocklist_subscribe") end)
			button(r, "Unsubscribe", function()
				go("blocklist_subscribe", {on = false})
			end)
			if b.owner == me.name then
				for _, o in ipairs(b.offers or {}) do
					local rr = l.row()
					button(rr, "Accept " .. o, function()
						go("blocklist_accept", {scope = o})
					end)
					button(rr, "Refuse", function()
						go("blocklist_drop", {scope = o})
					end)
				end
			end
		end
		local name = edit(w, "New list's name", "")
		local r = row(w)
		button(r, "Make a list", function()
			req("blocklist_create", {name = name:GetText()}, function()
				req("me", {}, blocklists_page)
			end)
		end)
	end)
end

appeal_page = function(st)
	local w = open("Appeal: " .. s(st.listing_name) .. ", " .. s(st.action),
			function() appeal_page(st) end, home)
	text(w, s(st.text))
	local why = edit(w, "Why", "")
	local r = row(w)
	button(r, "Send", function()
		req("appeal", {statement = st.id, text = why:GetText()}, function()
			message = "Appeal sent; another moderator decides."
			home()
		end)
	end)
end

queue_page = function()
	req("queue", {}, function(groups)
		local w = open("Report queue", queue_page)
		local l = list(w)
		if #groups == 0 then
			l.text("Nothing waiting.", GREY)
		end
		for _, g in ipairs(groups) do
			l.button(string.format("%s: %s, %d report(s), weight %.2f%s",
					s(g.listing_name), s(g.reason), g.count or 0,
					g.weight or 0, g.auto ~= "" and ", auto " .. g.auto or ""),
					function() group_page(g.id) end)
			if s(g.note) ~= "" then
				l.text(g.note, GREY)
			end
		end
	end)
end

group_page = function(gid)
	req("group", {group = gid}, function(r)
		local g, x = r.group, r.listing or {}
		local w = open("Reports of " .. s(g.reason) .. ": " .. s(x.name),
				function() group_page(gid) end, queue_page)
		text(w, s(x.id) .. " " .. s(x.host) .. ":" .. s(x.port) .. ", " ..
				categories(x) .. "; " .. s(x.served) .. ". " ..
				s(x.description), GREY)
		local l = list(w)
		if s(g.fleet) ~= "" then
			text(w, "Reports of the whole fleet " .. g.fleet ..
					": an action applies to all its servers.", YELLOW)
		end
		for _, rep in ipairs(r.reports or {}) do
			l.text(string.format("%s weight %.2f%s%s: %s", when(rep.ts),
					rep.weight or 0, rep.trusted and ", trusted flagger" or "",
					rep.state ~= "open" and ", " .. s(rep.state) or "",
					s(rep.text)))
			local rr = l.row()
			if s(rep.evidence) ~= "" then
				button(rr, "Save the screenshot", function()
					local path = buildat.save_file("evidence_" .. rep.id ..
							".jpg", unbase64(rep.evidence))
					message = path and "Saved: " .. path or
							"Could not save it"
					group_page(gid)
				end)
			end
			if s(rep.key) ~= "" and not rep.trusted then
				button(rr, "Trust this reporter (admin)", function()
					req("trust_reporter", {report = rep.id}, function()
						message = "Their reports now go first."
						group_page(gid)
					end)
				end)
			end
		end
		for _, a in ipairs(r.history or {}) do
			l.text(when(a.ts) .. " " .. s(a.action) .. " by " ..
					(s(a.by) ~= "" and a.by or "Starport") .. ": " ..
					s(a.text), GREY)
		end
		if r.id then
			-- 10d: a Starport ID that servers banned; only a moderator
			-- suspends it, with a statement it gets
			text(w, "Starport ID " .. s(r.id.name) .. ", age " ..
					s(r.id.band) .. ((tonumber(r.id.suspended_until) or 0) >
					0 and ", suspended" or ""), YELLOW)
			local why = edit(w, "Statement", "")
			local days = edit(w, "Days (0: until lifted)", "30")
			button(row(w), "Suspend the ID", function()
				req("decide", {group = gid, decision = "uphold",
					action = "suspend", text = why:GetText(),
					days = tonumber(days:GetText()) or 0}, queue_page)
			end)
		else
			action_rows(w, function(q)
				q.group, q.decision = gid, "uphold"
				req("decide", q, queue_page)
			end)
		end
		local b = row(w)
		button(b, "Dismiss", function()
			req("decide", {group = gid, decision = "dismiss"}, queue_page)
		end)
	end)
end

-- **Listings as columns** ([STARPORT_LISTINGS_VIEW]; user, 2026-10-07):
-- name, address, kind, a status letter and the last announce, each cut to
-- its column; a row opens the listing's page. The status is main.cpp's
-- served_status, long but for "listed", as a letter by its first word
local STATUS_LETTERS = {
	{"L", "listed", "listed"},
	{"H", "hidden", "hidden from filtered views"},
	{"U", "unlisted", "unlisted by its server: in no list, takes IDs"},
	{"O", "offline", "offline: no announce in 15 minutes"},
	{"W", "withdrawn", "withdrawn by its server"},
	{"F", "filtered", "filtered out by this instance's filter"},
	{"C", "unclaimed", "unclaimed: no operator has claimed it"},
	{"V", "unverified", "unverified: its address being checked, or failed"},
	{"D", "delisted", "delisted"},
	{"B", "banned", "banned"},
}
local function status_letter(served)
	local first = s(served):match("^%a+") or ""
	for _, x in ipairs(STATUS_LETTERS) do
		if x[2] == first then
			return x[1]
		end
	end
	return "?"
end
-- At most n characters, the last one "…" when cut
local function cut(v, n)
	local chars = {}
	for c in s(v):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = c
	end
	return #chars <= n and s(v) or table.concat(chars, "", 1, n - 1) .. "…"
end
assert(status_letter("unverified: being checked") == "V" and
		status_letter("listed") == "L" and cut("abcdef", 4) == "abc…" and
		cut("abcd", 4) == "abcd")

listings_page = function(search)
	req("listings", {search = search}, function(ls)
		local w = open("Listings", function() listings_page(search) end)
		local e = edit(w, "Search", search)
		magic.SubscribeToEvent(e, "TextFinished", function()
			listings_page(e:GetText())
		end)
		-- A window of its own over the page (100), as accounts' Starport
		-- help is
		button(row(w), "Legend", function()
			local lw = accounts.page_window(460)
			lw.priority = 300
			text(lw, "The status column")
			for _, x in ipairs(STATUS_LETTERS) do
				text(lw, x[1] .. "   " .. x[3], GREY)
			end
			button(row(lw), "Close", function() lw:Remove() end)
		end)
		-- The columns' shares of the width, and the characters each takes
		-- simplified: the characters are for the default font's average
		-- width (7 px); a long run of wide letters can still overflow
		-- Inside the page's margins (4 and 8)
		local width = w.width - 12
		local cols = {{"Name", 0.30}, {"Address", 0.27}, {"Kind", 0.12},
			{"St", 0.05}, {"Last announce", 0.26}}
		local function line(parent, values, color)
			local r = parent:CreateChild("UIElement")
			r:SetLayout(magic.LM_HORIZONTAL, 0, magic.IntRect(8, 0, 8, 0))
			r:SetFixedHeight(24)
			for i, c in ipairs(cols) do
				local cw = math.floor((width - 16) * c[2])
				local t = r:CreateChild("Text")
				t:SetStyleAuto()
				t:SetText(cut(values[i], math.max(2, math.floor(cw / 7) - 1)))
				t:SetFixedWidth(cw)
				t:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
				if color then t:SetColor(color) end
			end
			return r
		end
		local head = {}
		for i, c in ipairs(cols) do head[i] = c[1] end
		line(w, head, GREY)
		-- The rows in the page, which the window's view scrolls
		-- ([STARPORT_LIST_FILL])
		for _, x in ipairs(ls) do
			local b = w:CreateChild("Button")
			b:SetStyleAuto()
			b:SetFixedSize(width, 24)
			b:SetFocusMode(magic.FM_FOCUSABLE)
			local r = line(b, {x.name, s(x.host) .. ":" .. s(x.port), x.kind,
					status_letter(x.served),
					(tonumber(x.last_announce) or 0) > 0 and
					when(x.last_announce) or "never"})
			r:SetFixedWidth(width)
			magic.SubscribeToEvent(b, "Released", function() listing_page(x) end)
		end
		if #ls == 0 then
			text(w, search ~= "" and "Nothing matches the search" or
					"No listings", GREY)
		end
	end)
end

listing_page = function(x)
	local w = open(s(x.name), function() listing_page(x) end,
			function() listings_page("") end)
	text(w, s(x.id) .. " " .. s(x.host) .. ":" .. s(x.port) .. ", app " ..
			s(x.app) .. ", operator " .. s(x.owner) .. "\n" .. categories(x) ..
			"\n" .. s(x.served) .. "\n" .. s(x.description), GREY)
	local reason = edit(w, "Reason", "other")
	local whole = false
	if s(x.fleet) ~= "" then
		local fb
		fb = button(row(w), "[ ] On the whole fleet " .. x.fleet, function()
			whole = not whole
			fb:GetChild(0):SetText((whole and "[x]" or "[ ]") ..
					" On the whole fleet " .. x.fleet)
		end)
	end
	action_rows(w, function(q)
		q.listing, q.reason = x.id, reason:GetText()
		if whole then
			q.fleet = x.fleet
			return req("act", q, function(n)
				message = "Done on " .. s(n) .. " server(s)."
				listings_page("")
			end)
		end
		req("act", q, function(nx)
			message = "Done."
			listing_page(nx)
		end)
	end)
end

audit_page = function()
	req("audit", {}, function(as)
		local w = open("Audit log", audit_page)
		local l = list(w)
		for _, a in ipairs(as) do
			l.text(when(a.ts) .. " " .. s(a.listing) .. " " .. s(a.action) ..
					(a.auto and " (automatic)" or "") .. " " ..
					s(a.reason) .. " by " .. (s(a.by) ~= "" and a.by or
					"Starport") .. ": " .. s(a.text))
		end
	end)
end

appeals_page = function()
	req("appeals", {}, function(as)
		local w = open("Appeals", appeals_page)
		local answer = edit(w, "Answer", "")
		local l = list(w)
		if #as == 0 then
			l.text("No open appeals.", GREY)
		end
		for _, a in ipairs(as) do
			local st = a.statement_text or {}
			l.text(when(a.ts) .. " " .. s(a.by) .. " on " ..
					s(st.listing_name) .. " (" .. s(st.action) .. " by " ..
					s(a.acted_by) .. "): " .. s(a.text))
			local r = l.row()
			for _, o in ipairs({"reverse", "keep"}) do
				button(r, o == "reverse" and "Reverse" or "Keep", function()
					req("decide_appeal", {appeal = a.id, outcome = o,
						text = answer:GetText()}, appeals_page)
				end)
			end
		end
	end)
end

-- The instance's settings ([STARPORT] 5a, 7, 8), each as its JSON
settings_page = function()
	req("settings", {}, function(set)
		local w = open("Settings", settings_page)
		accounts.settings_rows(w, set, nil, function(k, v)
			req("set_settings", {settings = {[k] = v}}, function()
				message = k .. " saved."
				settings_page()
			end)
		end, function(k, err)
			message = k .. ": " .. s(err)
			settings_page()
		end)
	end)
end

accounts.on_joined = function()
	local script = buildat.get_env("BUILDAT_SP_REQS") or ""
	if script ~= "" then
		for line in script:gmatch("[^\n]+") do
			local q = buildat.parse_json(line)
			if type(q) == "table" then
				req(q.cmd, q)
			end
		end
	end
	refresh()
end

-- [ESC_ACCOUNT]: Escape is Back -- a page's, a page's inside a page, the
-- sidebar's on a narrow screen -- and at the top builtin's Account
-- (user, 2026-10-07), from a launcher "Exit to launcher?" ([STARPORT_CLOSE])
magic.SubscribeToEvent("KeyDown", function(_, d)
	if d:GetInt("Key") ~= magic.KEY_ESCAPE or not accounts.frame or
			not accounts.frame.visible then
		return
	end
	-- The exit dialog's Escape is its own Cancel
	if accounts.asking_exit or accounts.back() then
		return
	end
	if accounts.can_exit and accounts.can_exit() then
		accounts.ask_exit()
	else
		accounts.server_show("account")
	end
end)

-- Starport has its own account pages; no corner button ([ACCOUNT_BUTTON])
accounts.no_account_button()
accounts.start({title = "Starport", env = "BUILDAT_SP"})
-- vim: set noet ts=4 sw=4:
