-- Buildat: apps/aitta/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Aitta's own page** ([AITTA_MVP]): an author binds an author name to the
-- key `bin/buildat aitta keygen` printed, and sees the releases; the admin
-- delists. A reviewer (the server's moderators and admins) reviews them
-- ([AITTA_REVIEW]): a release's files, its diff against the package's
-- last reviewed version, a playtest by a ticket the launcher installs
-- apart, and the mark. Every action is a JSON "ai:req" {id, cmd, ...}, answered by
-- "ai:res" (main.cpp decides who may do what).
--
-- A scripted client sends BUILDAT_AITTA_REQS, JSON requests a line each,
-- after the join, and logs each answer as "ai: <json>".
local log = buildat.Logger("aitta")
local magic = require("buildat/extension/urho3d")
-- Light enough to load again by itself when a phone's browser dropped it in
-- the background (src/client/web/index.html, [WEB_RELOAD_APPS])
buildat.set_reload_on_return(true)

local _, accounts_err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("aitta: could not load accounts.lua: " .. tostring(accounts_err))
end

local message = nil
local home
local req = accounts.requester("ai", function(why)
	message = why
	home()
end, (buildat.get_env("BUILDAT_AITTA_REQS") or "") ~= "")
-- **From the launcher's publish screen** ([AITTA_PUBLISH_UI]): the
-- author name and key it made, to fill the form with
local offer = buildat.aitta_bind()

local YELLOW = magic.Color(1.0, 0.8, 0.4)
local GREY = magic.Color(0.7, 0.7, 0.7)
local text = accounts.page_text
local button = accounts.page_button

local function edit(parent, label)
	return accounts.page_field(parent, label)
end

-- **The review** ([AITTA_REVIEW]); each page logs what it shows, for a
-- check
local review_list, review_page
-- YYYY-MM-DD of a Unix time, UTC: the sandbox has no os.date (H. Hinnant's
-- civil_from_days)
local function date(t)
	local z = math.floor((tonumber(t) or 0) / 86400) + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) +
			math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	return string.format("%04d-%02d-%02d", yoe + era * 400 + (m <= 2 and 1 or 0),
			m, d)
end
local function lines_cut(s, max)
	local n, out = 0, {}
	for line in (s .. "\n"):gmatch("([^\n]*)\n") do
		n = n + 1
		if n <= max then
			out[#out + 1] = line
		end
	end
	if n > max then
		out[#out + 1] = "(... " .. n .. " lines in all)"
	end
	return table.concat(out, "\n")
end

local function file_page(id, path)
	req("review_file", {release = id, path = path}, function(t)
		local page = accounts.server_open(id .. ": " .. path,
				function() review_page(id) end)
		text(page, lines_cut(tostring(t), 400))
		log:info("aitta: file " .. id .. " " .. path)
	end)
end

local function diff_page(id)
	req("review_diff", {release = id}, function(d)
		local page = accounts.server_open(id .. (d.base ~= "" and
				", against " .. d.base or ", with no reviewed version before"),
				function() review_page(id) end)
		for _, f in ipairs(d.added) do
			text(page, "added: " .. f, YELLOW)
		end
		for _, f in ipairs(d.removed) do
			text(page, "removed: " .. f, YELLOW)
		end
		for _, c in ipairs(d.changed) do
			text(page, "changed: " .. c.path, YELLOW)
			text(page, lines_cut(c.diff, 300), GREY)
		end
		if #d.added + #d.removed + #d.changed == 0 then
			text(page, "No file changed.")
		end
		log:info("aitta: diff " .. id .. " against " .. (d.base ~= "" and
				d.base or "nothing") .. ": " .. #d.added .. " added, " ..
				#d.removed .. " removed, " .. #d.changed .. " changed")
	end)
end

local CHECKLIST = {
	"The licences fit the files.",
	"The audience is honest.",
	"The description says what it does.",
	"Nothing does harm beyond what the server's sandbox lets it: phoning home, " ..
			"mining, fetching code.",
	"No assets taken without a licence.",
}

review_page = function(id)
	req("review_release", {release = id}, function(v)
		local r = v.release
		local page = accounts.server_open("Review " .. id,
				function() review_list() end)
		local state = r.delisted and "delisted" or
				r.review == "reviewed" and "reviewed" or
				r.review == "needs_changes" and "needs changes" or "unreviewed"
		text(page, state .. ", " .. tostring(r.kind) .. ", for " ..
				((r.audience or "") ~= "" and r.audience or "no audience set") ..
				(r.audience_manifest and
				" (its meta.json says " .. r.audience_manifest .. ")" or "") ..
				", " .. math.floor(r.size / 1000) .. " kB", YELLOW)
		if (r.description or "") ~= "" then
			text(page, r.description)
		end
		text(page, "Licences: code " .. r.license_code .. ", media " ..
				r.license_media .. ((r.home_hearth or "") ~= "" and
				"; home " .. r.home_hearth or ""), GREY)
		if (r.review_note or "") ~= "" then
			text(page, "Note: " .. r.review_note, YELLOW)
		end
		if v.changelog ~= "" then
			text(page, "Changelog: " .. lines_cut(v.changelog, 30), GREY)
		end
		local top = accounts.page_row(page)
		button(top, v.base ~= "" and "Diff against " .. v.base or
				"Diff (no reviewed version before)", function() diff_page(id) end)
		button(top, "Playtest", function()
			req("playtest", {release = id}, function(t)
				log:info("aitta: playtest " .. id)
				buildat.offer_playtest{release = id, ticket = t.ticket,
						sha256 = t.sha256}
			end)
		end)
		text(page, #v.files .. " files:")
		for _, f in ipairs(v.files) do
			local row = accounts.page_row(page)
			local t = text(row, f.path .. "  " .. f.size .. " bytes", GREY)
			t:SetFixedWidth(page.width - 120)
			button(row, "View", function() file_page(id, f.path) end)
		end
		text(page, "Check:")
		for _, c in ipairs(CHECKLIST) do
			text(page, "- " .. c, GREY)
		end
		text(page, v.playtested and "You have playtested it." or
				"Not playtested by you.", GREY)
		local note = edit(page, "Note")
		local marks = accounts.page_row(page)
		local function mark(action, extra)
			local q = {release = id, action = action, note = note:GetText()}
			for k, x in pairs(extra or {}) do
				q[k] = x
			end
			req("review_mark", q, function()
				log:info("aitta: marked " .. id .. " " .. action)
				review_page(id)
			end)
		end
		button(marks, "Reviewed", function() mark("reviewed") end)
		button(marks, "Needs changes", function() mark("needs_changes") end)
		button(marks, "Delist", function() mark("delist") end)
		local relabel = accounts.page_row(page)
		text(relabel, "Relabel:")
		for _, a in ipairs({"everyone", "teen", "adult"}) do
			button(relabel, a, function() mark("relabel", {audience = a}) end)
		end
		for _, h in ipairs(v.history) do
			text(page, date(h.ts) .. " " .. h.by .. " " ..
					h.action .. " (" .. h.reason .. ")" ..
					(h.text ~= "" and ": " .. h.text or ""), GREY)
		end
		log:info("aitta: review " .. id .. ": " .. state .. ", " ..
				#v.files .. " files, base " .. (v.base ~= "" and v.base or
				"none"))
	end)
end

local review_filter = "unreviewed"
review_list = function()
	req("review_list", {filter = review_filter}, function(list)
		local page = accounts.server_open("Review: " .. review_filter ..
				", the oldest first", function() home() end)
		local filters = accounts.page_row(page)
		for _, f in ipairs({"unreviewed", "reviewed", "delisted", "all"}) do
			button(filters, f, function()
				review_filter = f
				review_list()
			end)
		end
		for _, r in ipairs(list) do
			local id = r.author .. "/" .. r.name .. "/" .. r.version
			local row = accounts.page_row(page)
			local t = text(row, id .. "  " .. date(r.time) ..
					(r.review == "needs_changes" and "  needs changes" or ""))
			t:SetFixedWidth(page.width - 120)
			button(row, "Open", function() review_page(id) end)
		end
		if #list == 0 then
			text(page, "None.", GREY)
		end
		log:info("aitta: review list " .. review_filter .. ": " .. #list)
	end)
end

-- **Reports** ([AITTA_REPORTS]): the moderators' queue, a group and its
-- decision, the appeals; an author's statements of reasons and their
-- appeal. Each page logs what it shows, for a check
local reports_page, group_page, appeals_page, statements_page

reports_page = function()
	req("mod_queue", nil, function(list)
		local page = accounts.server_open("Reports, the most urgent first",
				function() home() end)
		button(page, "Appeals", function() appeals_page() end)
		for _, g in ipairs(list) do
			local row = accounts.page_row(page)
			local t = text(row, tostring(g.listing) .. "  " ..
					tostring(g.reason) .. string.format(", weight %.2f, ",
					tonumber(g.weight) or 0) .. tostring(g.count) ..
					" reports" .. ((g.auto or "") ~= "" and ", " .. g.auto ..
					" automatically" or ""))
			t:SetFixedWidth(page.width - 120)
			button(row, "Open", function() group_page(g.id) end)
			log:info("aitta: report group " .. tostring(g.listing) .. " " ..
					tostring(g.reason) .. string.format(" %.2f",
					tonumber(g.weight) or 0) .. (g.auto and " " .. g.auto or ""))
		end
		if #list == 0 then
			text(page, "None open.", GREY)
		end
		log:info("aitta: reports: " .. #list)
	end)
end

group_page = function(gid)
	req("mod_group", {group = gid}, function(v)
		local g = v.group
		local page = accounts.server_open(tostring(g.listing) .. ": " ..
				tostring(g.reason), function() reports_page() end)
		text(page, string.format("Weight %.2f", tonumber(g.weight) or 0) ..
				((g.auto or "") ~= "" and "; " .. g.auto ..
				" automatically until decided" or ""), YELLOW)
		for _, r in ipairs(v.reports) do
			text(page, date(r.ts) .. string.format("  %.2f  ", tonumber(
					r.weight) or 0) .. (r.key ~= "" and "key " .. r.key or
					"anonymous") .. (r.state == "held" and "  held: " ..
					tostring(r.held) or "") .. ((r.text or "") ~= "" and
					": " .. r.text or ""), GREY)
		end
		for _, h in ipairs(v.history) do
			text(page, date(h.ts) .. " " .. (h.by ~= "" and h.by or "Aitta") ..
					" " .. h.action .. " (" .. h.reason .. ")" ..
					(h.text ~= "" and ": " .. h.text or ""), GREY)
		end
		text(page, "The release's own page: Review releases, all.", GREY)
		local note = edit(page, "To the author (the statement's text)")
		local days = edit(page, "A bar's days (none: until lifted)")
		local function decide(decision, action)
			req("mod_decide", {group = gid, decision = decision,
					action = action, text = note:GetText(),
					days = tonumber(days:GetText()) or 0}, function()
				log:info("aitta: decided " .. tostring(g.listing) .. " " ..
						decision .. (action and " " .. action or ""))
				reports_page()
			end)
		end
		local row = accounts.page_row(page)
		button(row, "Dismiss", function() decide("dismiss") end)
		for _, a in ipairs({{"unreview", "Unreview"}, {"delist", "Delist"},
				{"delist_package", "Delist package"},
				{"bar", "Bar the author"}}) do
			button(row, a[2], function() decide("uphold", a[1]) end)
		end
		log:info("aitta: report group page " .. tostring(g.listing) .. ": " ..
				#v.reports .. " reports")
	end)
end

appeals_page = function()
	req("mod_appeals", nil, function(list)
		local page = accounts.server_open("Appeals",
				function() reports_page() end)
		for _, a in ipairs(list) do
			local st = a.statement_text or {}
			text(page, tostring(a.listing) .. ": " .. tostring(st.action) ..
					" by " .. tostring(a.acted_by) .. " (" ..
					tostring(st.reason) .. ")", YELLOW)
			text(page, tostring(a.by) .. ": " .. tostring(a.text), GREY)
			local answer = edit(page, "Answer")
			local row = accounts.page_row(page)
			for _, o in ipairs({{"reverse", "Reverse"}, {"keep", "Keep"}}) do
				button(row, o[2], function()
					req("mod_decide_appeal", {appeal = a.id, outcome = o[1],
							text = answer:GetText()}, function()
						log:info("aitta: appeal " .. tostring(a.listing) ..
								" " .. o[1])
						appeals_page()
					end)
				end)
			end
		end
		if #list == 0 then
			text(page, "None open.", GREY)
		end
		log:info("aitta: appeals: " .. #list)
	end)
end

-- An author's: what was done to their releases and why, each with its
-- appeal
statements_page = function()
	req("statements", nil, function(list)
		local page = accounts.server_open("What was done to your releases",
				function() home() end)
		for _, st in ipairs(list) do
			text(page, date(st.ts) .. " " .. tostring(st.listing) .. ": " ..
					tostring(st.action) .. " (" .. tostring(st.reason) .. ")" ..
					((st.text or "") ~= "" and ": " .. st.text or ""), YELLOW)
			-- One open appeal a statement: the server says so to a second
			if st.action ~= "restored" then
				local why = edit(page, "Why it is wrong")
				button(page, "Appeal", function()
					req("appeal", {statement = st.id, text = why:GetText()},
							function()
						log:info("aitta: appealed " .. tostring(st.listing))
						statements_page()
					end)
				end)
			end
			log:info("aitta: statement " .. tostring(st.listing) .. ": " ..
					tostring(st.action))
		end
		if #list == 0 then
			text(page, "Nothing.", GREY)
		end
	end)
end

-- **The admin's Settings** ([AITTA_SETTINGS_PAGE]): each setting's JSON,
-- as on Starport's; what each does from main.cpp's default_settings()
local admin = false
local NOTES = {
	licences = "The licences a release may name (SPDX ids).",
	max_size = "The largest upload, in bytes.",
	update_delay = "Seconds before a package's next release is listed.",
	page_delay = "Seconds a release is listed before the page at / shows it.",
	public_url = "This Aitta's address as its pages give it in the " ..
			"commands; \"\" for the request's own host.",
	play_url = "The play server's page a serverless package's \"Play in " ..
			"the browser\" opens, <play_url>/#run=<author>/<name>; \"\" " ..
			"for no link.",
	app_hosting_provider = "A hosting provider's address: each app's " ..
			"\"Host at <domain>\" link, <provider>?aitta=<this>&package=" ..
			"<author>/<name>; \"\" for none.",
	anon_weight = "What an anonymous report weighs.",
	key_weight = "What a report with the client's report key weighs.",
	thresholds = "Reported past \"hide\", a release is out of the list " ..
			"until a moderator looks; past \"delist\", delisted. By reason.",
}
local function settings_page()
	req("settings", nil, function(set)
		local page = accounts.server_open("Settings")
		if message then
			text(page, message, YELLOW)
			log:info("aitta: message " .. message)
			message = nil
		end
		for k in pairs(set) do
			log:info("aitta: settings row " .. k)
		end
		accounts.settings_rows(page, set, NOTES, function(k, v)
			req("set_settings", {settings = {[k] = v}}, function()
				message = k .. " saved."
				log:info("aitta: setting " .. k .. " saved")
				settings_page()
			end)
		end, function(k, err)
			message = k .. ": " .. tostring(err)
			settings_page()
		end)
		log:info("aitta: settings page")
	end)
end

-- In builtin/accounts' Server window ([SERVER_ADMIN_PAGE]), an entry
-- before its Account, Accounts and Health
home = function()
	-- The window at once, not at the reply: the ntfy question at a login
	-- comes between, and is shown in it ([NTFY_ASK_OVER_GAME])
	if not accounts.frame then
		-- Its × "Exit to launcher?" from a launcher ([STARPORT_CLOSE])
		return accounts.server_window("aitta", nil,
				accounts.can_exit and accounts.can_exit() and
				accounts.ask_exit or nil)
	end
	req("me", nil, function(me)
		-- Another entry chosen meanwhile, or the question shown
		if not accounts.frame or accounts.server_current() ~= "aitta" then
			return
		end
		if me.admin ~= admin then
			admin = me.admin
			accounts.server_sidebar()
		end
		local page = accounts.server_open("Aitta, as " .. tostring(me.account))
		if message then
			text(page, message, YELLOW)
			message = nil
		end
		if me.author == "" then
			text(page, "Bind an author name to your key to publish. The key " ..
					(offer and "and the name are your launcher's, from its " ..
					"publish screen" or "is the line `bin/buildat aitta " ..
					"keygen <file>` printed; the name is what your " ..
					"releases' meta.json say as \"author\"") ..
					", and neither changes after.", GREY)
			local author = edit(page, "Author name (a-z, 0-9, _)")
			local key = edit(page, "Public key")
			if offer then
				author:SetText(offer.author)
				key:SetText(offer.key)
			end
			button(page, "Bind", function()
				req("bind", {author = author:GetText(), key = key:GetText()},
						function()
					message = offer and "Bound. Leave to the launcher and " ..
							"publish from Settings, Developer." or
							"Bound. Publish with: bin/buildat aitta " ..
							"publish <release .zip> <this server's address>"
					home()
				end)
			end)
		else
			text(page, "Author: " .. me.author .. "  key " ..
					me.key:sub(1, 16) .. "...", GREY)
		end
		-- Where the publish screen is ([AITTA_PUBLISH_UI])
		button(page, "Back to the launcher", function() buildat.leave() end)
		log:info("aitta: home, " .. (me.author ~= "" and "author " ..
				me.author or "no author"))
		if me.reviewer then
			button(page, "Review releases", function() review_list() end)
			button(page, "Reports", function() reports_page() end)
		end
		if me.author ~= "" then
			button(page, "What was done to my releases",
					function() statements_page() end)
		end
		text(page, #me.releases .. " releases:")
		-- **A row a release** ([AITTA_ADMIN_ROWS]): its id, its state and
		-- the admin's action as a button of its own, in columns of fixed
		-- widths; the rest on a dim line under it. A long id or address
		-- wraps in its column. simplified: plain rows on the Server
		-- window's page, which scrolls already; a list of its own
		-- (ui_utils.list_view) would fight it for the wheel
		local width = page.width - 12
		local state_w, button_w = 110, me.admin and 110 or 0
		local function column(parent, s, w, color)
			local t = text(parent, s, color)
			t:SetFixedWidth(w)
			return t
		end
		for _, r in ipairs(me.releases) do
			local id = r.author .. "/" .. r.name .. "/" .. r.version
			local box = page:CreateChild("UIElement")
			box:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
			local top = accounts.page_row(box)
			column(top, id, width - state_w - button_w - 8)
			local state = (r.delisted and "delisted" or "listed") ..
					(r.review == "reviewed" and ", reviewed" or
					r.review == "needs_changes" and ", needs changes" or "")
			column(top, state, state_w, r.delisted and YELLOW or nil)
			local action = r.delisted and "Relist" or "Delist"
			if me.admin then
				button(top, action, function()
					req(r.delisted and "relist" or "delist", {release = id}, home)
				end):SetFixedWidth(button_w)
			end
			if r.review == "needs_changes" then
				column(box, "Needs changes: " .. tostring(r.review_note), width,
						YELLOW)
			end
			column(box, r.license_code .. " / " .. r.license_media .. "  " ..
					math.floor(r.size / 1000) .. " kB" ..
					((r.home_hearth or "") ~= "" and "  home: " .. r.home_hearth
					or ""), width, GREY)
			-- For a check
			log:info("aitta: row " .. id .. ": " .. state ..
					(me.admin and ", " .. action or ""))
		end
	end)
end

accounts.on_joined = function()
	local script = buildat.get_env("BUILDAT_AITTA_REQS") or ""
	for line in script:gmatch("[^\n]+") do
		local q = buildat.parse_json(line)
		if type(q) == "table" then
			req(q.cmd, q)
		end
	end
	home()
end

accounts.server_menu = function(add)
	add(nil, "Aitta", "aitta", home)
	if admin then
		add("Admin", "Settings", "settings", settings_page)
	end
end
-- Its accounts are in the window; no corner button ([ACCOUNT_BUTTON])
accounts.no_account_button()
accounts.start({title = "Aitta", env = "BUILDAT_AITTA"})
-- vim: set noet ts=4 sw=4:
