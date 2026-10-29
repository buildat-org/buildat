-- Buildat: client/core/aitta/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The client's side of Aitta** ([AITTA_MVP], doc/plan/aitta_plan.md):
-- the Apps from Aitta page and its installs, reports on a release, a
-- reviewer's playtest, serverless runs and publishing (publish.lua).
-- Which Aittas, and the filters that say whether unreviewed releases are
-- shown, are the Starport settings' (client/core/starport), as are
-- the dialogs this draws with.
local log = buildat.Logger("extension/aitta")
local network = require("buildat/core/network")
local uistack = require("buildat/core/uistack")
local magic = require("buildat/core/urho3d").safe
local starport = require("buildat/core/starport")
local effective = starport.effective
local d = starport.dialog
local open_window, is_open, reseal = d.open_window, d.is_open, d.reseal
local add_text, add_label, add_row, add_button, add_edit, add_dropdown =
		d.add_text, d.add_label, d.add_row, d.add_button, d.add_edit,
		d.add_dropdown
local WARN, DIM = d.WARN, d.DIM
local M = {safe = {}}

-- **Aitta's apps** ([AITTA_MVP]): the list from the Aitta in the
-- settings, each release with Install, or Update where an older version
-- of it is installed. Installing fetches the release and its signature
-- and checks both on this side (__buildat_aitta_install); a version is
-- installed beside the others, never over one. Where the filters hide
-- unreviewed content, reviewed releases only. `query`: only the releases whose
-- author/name or description has it, case aside.
local function aitta_installed()
	local have = {}
	for _, g in ipairs(buildat.list_apps() or {}) do
		local author, name, version = tostring(g.name):match("^([%w_]+)%.([%w_]+)@(.+)$")
		if author then
			local k = author .. "/" .. name
			have[k] = have[k] or {}
			have[k][version] = true
		end
	end
	for _, x in ipairs(buildat.list_launchers() or {}) do
		local author, name = tostring(x.name):match("^([%w_]-)__([%w_]+)$")
		if x.kind == "extension" and author and x.version then
			have[author .. "/" .. name] = {[x.version] = true}
		end
	end
	return have
end

-- **A release fetched and installed** ([REWORK_1019_FIXES] client 10):
-- its signature and archive from its Aitta, both checked by their look
-- before the install -- the signature JSON, the archive a zip ("PK"); a
-- refusal (a playtest's ticket gone, an error page) is said as `refused`.
-- done(dir) or done(nil, why, "fetch"|"install"). o: description (the
-- network's leave), query ("?ticket=..."), review (installed apart),
-- refused, world ({app, code}: a world as a new save of app, done(save)).
local function fetch_install(aitta, sha256, o, done)
	local base = aitta .. "/api/v1/aitta/archive/" .. tostring(sha256)
	local options = {description = o.description}
	local refused = o.refused or "the Aitta refused it"
	network.http_get(base .. ".sig" .. (o.query or ""), function(sig, e1)
		if not sig or not sig:match("^%s*{") then
			return done(nil, sig and refused or tostring(e1), "fetch")
		end
		network.http_get(base .. ".zip" .. (o.query or ""), function(zip, e2)
			if not zip or zip:sub(1, 2) ~= "PK" then
				return done(nil, zip and refused or tostring(e2), "fetch")
			end
			local dir, why = __buildat_aitta_install(zip, sig, aitta, o.review,
					o.world)
			done(dir, why, "install")
		end, options)
	end, options)
end

-- **A report on a release** ([AITTA_REPORTS]), to its Aitta: a reason
-- and what is wrong, with this client's report key for that Aitta where
-- the settings send keys (the Starport settings' report key, by the Aitta's address)
local AITTA_REASONS = {
	{"malware", "Malware or harmful code"},
	{"licence", "Licence or copyright violation"},
	{"broken", "Broken"},
	{"category", "Wrong audience"},
	{"illegal", "Illegal content"},
	{"csam", "Child sexual abuse material"},
	{"harassment", "Harassment or abuse"},
	{"scam", "Scam or phishing"},
	{"impersonation", "Impersonation"},
	{"spam", "Spam"},
	{"other", "Other"},
}
local function aitta_report(aitta, id)
	local root, w = open_window("aitta report", 620, nil, {close_glyph = false})
	add_text(w, "Report " .. id .. " to " .. aitta)
	add_text(w, "A moderator of that Aitta decides; the author is told " ..
			"what was done and why, not who reported it.", DIM)
	local reason
	local buttons = {}
	for _, r in ipairs(AITTA_REASONS) do
		buttons[#buttons + 1] = add_button(w, r[2], function()
			reason = r[1]
			for i, b in ipairs(buttons) do
				b:GetChild(0).text = (AITTA_REASONS[i][1] == reason and
						"> " or "") .. AITTA_REASONS[i][2]
			end
		end)
	end
	add_text(w, "What is wrong (optional):")
	local text = add_edit(w, "")
	local status = add_text(w, "")
	local r = add_row(w)
	add_button(r, "Send", function()
		if not reason then
			status.text = "Choose a reason"
			return
		end
		local body = {release = id, reason = reason, text = text:GetText()}
		body.key = starport.report_key(aitta)
		status.text = "Sending..."
		network.http_post(aitta .. "/api/v1/aitta/report", network.write_json(body),
				function(answer, err)
			local v = answer and network.parse_json(answer)
			if type(v) == "table" and v.ok then
				status.text = "Sent; receipt " .. tostring(v.receipt)
				log:info("aitta report: sent " .. id .. " " .. reason .. ": " ..
						tostring(v.receipt))
			else
				status.text = "Not sent: " .. tostring(type(v) == "table" and
						v.error or err)
			end
		end, {description = "Aitta"})
	end)
	add_button(r, "Close", function() uistack.main:pop(root) end)
	log:info("aitta report: " .. id)
end
-- For a tile's "Report..." (client/launch_grid.lua)
M.report_release = aitta_report

-- [AITTA_REPORTS] A release its Aitta delisted, installed here: a note in
-- its directory for its tile, from each fetch of the list; gone when it is
-- listed again. simplified: noted when the Aitta page fetches the list,
-- not on its own -- a check at the grid's start when a user asks
local function aitta_note(rel, why)
	local a, n, v = tostring(rel.author), tostring(rel.name),
			tostring(rel.version)
	if not (a:match("^[%w_]+$") and n:match("^[%w_]+$") and
			v:match("^[%w%.%-%+_]+$") and v ~= "." and v ~= "..") then
		return
	end
	local dir = __buildat_get_path("user") .. "/installed/" .. a .. "/" ..
			n .. "/" .. v
	local probe = io.open(dir .. "/meta.json", "rb")
	if not probe then
		return
	end
	probe:close()
	if not why then
		os.remove(dir .. "/.aitta_delisted")
		return
	end
	local f = io.open(dir .. "/.aitta_delisted", "wb")
	if f then
		f:write(tostring(why):sub(1, 500))
		f:close()
		log:info("aitta page: delisted " .. a .. "." .. n .. "@" .. v .. ": " ..
				tostring(why))
		-- The grid behind, its tile with the note
		local menu = buildat.menu_extension()
		if menu and type(menu.refresh) == "function" then
			menu.refresh()
		end
	end
end

-- on_discuss(release): "Discuss" on a release that names its home
-- Hearth ([PACKAGE_SUBJECT]); the grid connects there
-- **Aitta's page** ([AITTA_PAGE_LAYOUT]), laid out as launch_menu's
-- Browse: a package a row in a scrolling list, the selected one's
-- details and actions in the panel beside it (under it on a narrow
-- screen). A click or the keys select; Enter or a click on the selected
-- row runs its main action; Right into the panel, Left back
-- (keyboard_columns). The search filters as it is typed, the dropdown by
-- the package's state; Ctrl+S sorts by name or newest. Escape or a click
-- off the window closes it. A status line at the foot.
-- simplified: copied from browse() rather than shared: launch_menu's
-- layout is tied to its entries, and this page fetches and installs in
-- the trusted extension
-- simplified: no Play: an installed app is a tile on the grid behind
local AITTA_FILTERS = {"All", "Installed", "Updates", "Not installed"}
-- [SERVERLESS_PLAY] On the web there is no server to install an app onto:
-- Apps from Aitta lists the serverless ones, with Play only
local ON_WEB = GetPlatform() == "Web"

-- **A release this client runs** ([COMPAT_BREAK_07] 8c): nil, or why not
-- for a player. A package's newest is the newest it runs; one it runs none
-- of is shown with this and nothing to install or play.
local function cannot_run(rel)
	local api = tonumber(rel.engine_api) or 0
	if api < __buildat_aitta_dev("engine_api_min") then
		return "made for an older Buildat"
	elseif api > __buildat_aitta_dev("engine_api") then
		return "needs a newer Buildat"
	elseif rel.kind and rel.kind ~= "app" and rel.kind ~= "extension" and
			rel.kind ~= "world" then
		return "a kind of package this Buildat does not know"
	end
end

-- [WORLD_PACKAGES] The app a world is a save of, as its manifest names it
-- (the install checks it again), and whether that app here takes worlds:
-- its launcher's {code}, or nil and why not
local function world_app(rel)
	local app = type(rel.app) == "string" and rel.app or ""
	local wp = (buildat.world_packages() or {})[app]
	if not wp then
		return app, nil, app == "" and "it names no app" or app ..
				" is not here, or does not take worlds"
	end
	return app, wp
end

-- By SemVer; by the time an Aitta listed it for a version that is not one
local function newer_release(rel, old)
	local c = starport.semver_cmp(rel.version, old.version)
	if c then
		return c > 0
	end
	return (tonumber(rel.time) or 0) > (tonumber(old.time) or 0)
end

-- [WEB_LOCAL_AITTA] A release whose server runs in the page: its modules
-- are .wasm, which its Aitta built at publish ("web_wasm", the names the
-- page's server looks for and their sha256); or it has C++, linked into a
-- server of its own ("web_cpp", "web_server", [WEB_LOCAL_AITTA_CPP])
local function in_page(rel)
	return ON_WEB and rel.serverless ~= true and type(rel.web_wasm) == "table" and
			(rel.web == true or (rel.web_cpp == true and
			type(rel.web_server) == "table"))
end

-- [WEB_LOCAL_AITTA] An installed release run in the page: its .wasm
-- fetched from its Aitta, each checked against its sha256, kept under .web/
-- in its directory, and the page goes to ?local=<author>.<name>@<version>,
-- which runs the engine's server for packages on it (web/index.html)
local function go_in_page(key, rel)
	local ui = require("buildat/extension/ui_utils").safe
	local a, n, v = key:match("^([%w_]+)/([%w_]+)$")
	v = tostring(rel.version)
	if not a or not v:match("^[%w][%w%.%+%-]*$") then
		return
	end
	local id = a .. "." .. n .. "@" .. v
	local dir = __buildat_get_path("user") .. "/installed/" .. a .. "/" ..
			n .. "/" .. v .. "/.web"
	__buildat_create_directories(dir)
	local todo = {}
	for name, sha in pairs(rel.web_wasm) do
		if type(name) ~= "string" or type(sha) ~= "string" or
				not (name:match("^[%w_]+%.wasm$") or
				name:match("^[%w_]+%.server%.wasm$")) or
				not sha:match("^%x+$") or #sha ~= 64 then
			return ui.show_message_dialog("Could not start " .. key ..
					": its Aitta's list names a .wasm wrongly")
		end
		todo[#todo + 1] = {name = name, sha = sha:lower()}
	end
	-- [WEB_LOCAL_AITTA_CPP] Its own server .wasm, with its C++ modules,
	-- which its Aitta linked for the page's engine: server.engine.wasm, a
	-- name no module's .wasm has, and server.json, for the page (empty
	-- without one)
	local own = rel.web_server
	local server_json = ""
	if own ~= nil then
		local sha, js, shift = type(own) == "table" and own.wasm,
				type(own) == "table" and own.js,
				type(own) == "table" and tonumber(own.shift)
		if type(sha) ~= "string" or not sha:match("^%x+$") or #sha ~= 64 or
				type(js) ~= "string" or not js:match("^%x+$") or #js ~= 64 or
				not shift or shift ~= math.floor(shift) or
				math.abs(shift) >= 1e9 then
			return ui.show_message_dialog("Could not start " .. key ..
					": its Aitta's list names its server wrongly")
		end
		todo[#todo + 1] = {name = "server.engine.wasm", sha = sha:lower()}
		server_json = network.write_json({js = js:lower(),
				shift = string.format("%d", shift)})
	end
	local left = #todo
	local function next_one()
		if left == 0 then
			local f = io.open(dir .. "/server.json", "wb")
			if not f then
				return ui.show_message_dialog("Could not start " .. key ..
						": server.json could not be written")
			end
			f:write(server_json)
			f:close()
			log:info("aitta: play " .. id .. " in the page")
			return __buildat_web_go_local(id)
		end
		local w = todo[left]
		left = left - 1
		network.http_get(rel.aitta .. "/api/v1/aitta/wasm/" .. w.sha .. ".wasm",
				function(body, err)
			if not body or __buildat_hex(__buildat_sha256(body)) ~= w.sha then
				return ui.show_message_dialog("Could not start " .. key ..
						": " .. w.name .. " " .. (body and
						"is not the one its Aitta listed" or tostring(err)))
			end
			local f = io.open(dir .. "/" .. w.name, "wb")
			if not f then
				return ui.show_message_dialog("Could not start " .. key ..
						": " .. w.name .. " could not be written")
			end
			f:write(body)
			f:close()
			next_one()
		end, {description = "Aitta (install)"})
	end
	next_one()
end

-- An installed release's client half started with no server, the pages
-- over the launcher taken down first; one whose server runs in the page
-- (rel given), run there
local function play_installed(key, version, rel)
	if rel and in_page(rel) then
		return go_in_page(key, rel)
	end
	local id = key:gsub("/", ".", 1) .. "@" .. tostring(version)
	log:info("aitta: play " .. id .. " serverless")
	if uistack.main.stack[1] then
		pcall(function()
			uistack.main:pop_to(uistack.main.stack[1])
		end)
	end
	local ok, why = buildat.serverless_play(id)
	if not ok then
		log:warning("aitta: play " .. id .. ": " .. tostring(why))
		require("buildat/extension/ui_utils").safe.show_message_dialog(
				"Could not start " .. key .. ": " .. tostring(why))
	end
end

-- [PACKAGE_MEDIA] A release's "icon" or "screenshot" by its hash, from its
-- Aitta, checked and kept under the cache's package_media/: the resource
-- name, or nil where it has none or it is still on its way (got(name)
-- then, once)
local MEDIA_DIR = __buildat_get_path("cache") .. "/package_media/"
local media_asked = {}
local function aitta_media(rel, which, got)
	local h = type(rel[which]) == "string" and rel[which]:lower()
	if not h or not h:match("^%x+$") or #h ~= 64 then
		return nil
	end
	for _, ext in ipairs({".png", ".jpg"}) do
		local f = io.open(MEDIA_DIR .. h .. ext, "rb")
		if f then
			f:close()
			return h .. ext
		end
	end
	if not media_asked[h] then
		media_asked[h] = true
		network.http_get(tostring(rel.aitta) .. "/api/v1/aitta/media/" .. h,
				function(body, err)
			local name, why = nil, err
			if body then
				name, why = __buildat_keep_package_media(body, which)
			end
			if not name or name:sub(1, 64) ~= h then
				log:warning("aitta: " .. which .. " " .. h .. " not kept (" ..
						tostring(why or name) .. ")")
				return
			end
			log:info("aitta: " .. which .. " " .. name .. " kept")
			if got then
				got(name)
			end
		end, {description = "Aitta (images)"})
	end
	return nil
end

local function aitta_page(message, query, on_discuss, filter, by, chosen)
	filter = filter or "All"
	by = by or "name"
	local e = effective()
	local ui_utils = require("buildat/extension/ui_utils").safe
	local narrow = magic.ui.root.width < 760
	local width = math.min(magic.ui.root.width - 16, 1000)
	local panel_w = narrow and width - 24 or 360
	local list_w = narrow and width - 24 or width - 24 - panel_w - 12
	local room = math.max(120, magic.ui.root.height - 180 -
			(narrow and 250 or 0))
	local root, w = open_window("aitta", width)
	local function reopen(m, q, f, b, c)
		-- A call left over from a page already replaced does nothing
		-- ([AITTA_FILTER_POP])
		if uistack.main.stack[#uistack.main.stack] ~= root then
			return
		end
		uistack.main:pop(root)
		aitta_page(m, q, on_discuss, f, b, c)
	end
	add_text(w, "Apps from Aitta (" .. (#e.aittas > 0 and
			table.concat(e.aittas, ", ") or "none in the Starport settings") ..
			")")
	-- [AITTA_REVIEW]: under the lock, a package's newest reviewed release
	-- only, and none of a package with none
	local only_reviewed = not e.filters.unreviewed
	if only_reviewed then
		add_text(w, "This client's filters hide unreviewed releases.", DIM)
	end
	local top = add_row(w)
	local search = add_edit(top, query or "")
	search.minWidth = narrow and 140 or 300
	add_dropdown(top, AITTA_FILTERS, filter, function(f)
		reopen(nil, search:GetText(), f, by, chosen)
	end, {width = 160, height = 24})
	local body = w:CreateChild("UIElement")
	body:SetLayout(narrow and magic.LM_VERTICAL or magic.LM_HORIZONTAL, 12,
			magic.IntRect(0, 0, 0, 0))
	local view = ui_utils.list_view(body, list_w, room, {wheel = 28,
			label_share = 0.55})
	-- The panel scrolls too: a description and a changelog are the
	-- author's length
	local pview = ui_utils.list_view(body, panel_w, narrow and 240 or room,
			{wheel = 28, fill = true, spacing = 6})
	local panel = pview.list
	ui_utils.keyboard_columns(w, view.viewport, pview.viewport)
	local status = add_text(w, message or "Fetching the list...",
			message and WARN or DIM)
	if message then
		log:info("aitta status: " .. message)
	end
	local function say(s, color)
		log:info("aitta status: " .. s)
		status:SetText(s)
		status.color = color or DIM
		reseal(status)
	end
	root:SubscribeToStackEvent("KeyDown", function(_, data)
		if data:GetInt("Key") == magic.KEY_S and
				magic.input:GetQualifierDown(magic.QUAL_CTRL) then
			reopen(nil, search:GetText(), filter,
					by == "name" and "newest" or "name", chosen)
		end
	end)

	local packages = {}
	local have = {}
	local function state(p)
		local mine = have[p.key]
		return not mine and "Not installed" or
				mine[tostring(p.rel.version)] and "Installed" or "Updates"
	end
	local function ptext(s, color, size)
		local t = add_text(panel, s, color)
		t:SetFixedWidth(panel_w)
		if size then
			t:SetFontSize(size)
		end
		return t
	end
	local function install(p, play)
		local rel, k = p.rel, p.key
		-- [WORLD_PACKAGES] A world: a new save of its app each time, played
		local world = nil
		if rel.kind == "world" then
			local app, wp, why = world_app(rel)
			if not wp then
				return say("Not installed: " .. why, WARN)
			end
			world = {app = app, code = wp.code}
		end
		say("Fetching " .. k .. "...")
		fetch_install(rel.aitta, rel.sha256, {description = "Aitta (install)",
				world = world}, function(dir, why, stage)
			if stage == "fetch" then
				return say("Could not fetch: " .. why, WARN)
			end
			if world then
				if not dir then
					return say("Not installed: " .. tostring(why), WARN)
				end
				log:info("aitta: " .. k .. " " .. tostring(rel.version) ..
						" installed as the save " .. dir .. " of " .. world.app)
				pcall(function() uistack.main:pop_to(uistack.main.stack[1]) end)
				local menu = buildat.menu_extension()
				if menu and type(menu.refresh) == "function" then
					menu.refresh()
				end
				local ok, err = buildat.safe.launch_save(world.app, dir)
				if not ok then
					log:warning("aitta: play " .. dir .. ": " .. tostring(err))
				end
				return
			end
			if dir and play then
				return play_installed(k, rel.version, rel)
			end
			-- Read before the grid's refresh, which takes the page down
			local q = search:GetText()
			uistack.main:pop(root)
			-- The grid behind, with the new tile on it
			local menu = dir and buildat.menu_extension()
			if menu and type(menu.refresh) == "function" then
				menu.refresh()
			end
			aitta_page(dir and ("Installed " .. k .. " " ..
					tostring(rel.version) .. (rel.kind == "extension" and
					(": the extension " .. tostring(rel.author) .. "__" ..
					tostring(rel.name) .. ", in the sandbox") or
					": it is on the grid")) or
					("Not installed: " .. tostring(why)),
					q, on_discuss, filter, by, k)
		end)
	end
	local selected = nil
	local last_click = {}
	local function fill(p)
		selected = p
		panel:RemoveAllChildren()
		local rel = p.rel
		log:info("aitta panel: " .. p.key .. " " .. tostring(rel.version))
		ptext(p.key, nil, 18)
		ptext(tostring(rel.version) .. ", " .. (rel.kind == "extension" and
				"an extension" or rel.kind == "world" and "a world for " ..
				tostring(rel.app) .. (rel.app_version and " " ..
				tostring(rel.app_version) or "") or "an app") ..
				((rel.serverless == true or
				rel.web == true or rel.web_cpp == true) and
				", runs in the browser" or "") .. ", by " ..
				tostring(rel.author) .. "; " .. (rel.review == "reviewed" and
				"reviewed" or "unreviewed"), DIM)
		ptext(tostring(rel.license_code) .. " / " ..
				tostring(rel.license_media) .. ", " ..
				math.floor((tonumber(rel.size) or 0) / 1000) .. " kB", DIM)
		if rel.description and rel.description ~= "" then
			ptext(tostring(rel.description))
		end
		local why_not = cannot_run(rel)
		if why_not then
			ptext("Not for this Buildat: it is " .. why_not .. ".", WARN)
		end
		-- Its screenshot, the panel's width at most and 200 high
		local shot = aitta_media(rel, "screenshot", function()
			if selected == p and is_open(root) then
				fill(p)
			end
		end)
		local tex = shot and magic.cache:GetResource("Texture2D", shot)
		if tex and tex.width > 0 and tex.height > 0 then
			local img = panel:CreateChild("BorderImage")
			img.texture = tex
			local sw = math.min(panel_w, math.floor(200 * tex.width / tex.height))
			img:SetFixedSize(sw, math.floor(sw * tex.height / tex.width))
			reseal(img)
			log:info("aitta panel: screenshot " .. shot)
		end
		if rel.kind == "world" then
			local app, wp, why = world_app(rel)
			ptext(wp and "Installs as a new save of " .. app .. " and plays " ..
					"it: a save's data, no code." or "Cannot be installed: " ..
					why .. ".", wp and DIM or WARN)
		elseif rel.kind ~= "extension" then
			ptext("It runs in the server's sandbox: it cannot reach your " ..
					"files, only its own saves.", DIM)
		end
		local changelog = ptext("", DIM)
		local st = state(p)
		local actions = add_row(panel)
		-- [SERVERLESS_PLAY] Play: installed first where it is not; on the
		-- web, with no server to install onto, only Play
		if (rel.serverless == true or in_page(rel)) and not why_not then
			add_button(actions, "Play", function()
				if st == "Installed" then
					play_installed(p.key, rel.version, rel)
				else
					install(p, true)
				end
			end, true, true)
		end
		if not ON_WEB and not why_not and rel.kind == "world" then
			add_button(actions, "Install and play", function() install(p) end,
					select(2, world_app(rel)) ~= nil, true)
		elseif not ON_WEB and not why_not then
			add_button(actions, st == "Installed" and "Installed" or
					st == "Updates" and "Update" or "Install",
					function() install(p) end, st ~= "Installed",
					rel.serverless ~= true)
		end
		-- Without its own, the Hearth its Aitta's Starport recommends
		if not (type(rel.home_hearth) == "string" and
				rel.home_hearth:match("^https?://")) then
			rel.home_hearth = starport.safe.fallback_hearth(rel.aitta)
		end
		if on_discuss and rel.home_hearth then
			add_button(actions, "Discuss", function()
				uistack.main:pop(root)
				on_discuss(rel)
			end)
		end
		add_button(actions, "Report...", function()
			aitta_report(rel.aitta, p.key .. "/" .. tostring(rel.version))
		end)
		pview:fit()
		reseal(panel)
		local id = p.key .. "/" .. tostring(rel.version)
		network.http_get(rel.aitta .. "/api/v1/aitta/release?id=" .. id,
				function(body)
			local v = body and network.parse_json(body)
			if selected == p and type(v) == "table" and
					type(v.changelog) == "string" and v.changelog ~= "" then
				changelog:SetText("Changes:\n" .. v.changelog)
				pview:fit()
				reseal(changelog)
			end
		end, {description = "Aitta (app list)"})
	end
	local function show_rows()
		view.list:RemoveAllChildren()
		local q = search:GetText():lower()
		local shown = {}
		for _, p in ipairs(packages) do
			if (filter == "All" or state(p) == filter) and (q == "" or
					p.key:lower():find(q, 1, true) or tostring(
					p.rel.description or ""):lower():find(q, 1, true)) then
				shown[#shown + 1] = p
			end
		end
		-- [WORLD_PACKAGES] By name, a world under its app: after the app's
		-- row where the app is listed, else where its name sorts
		local function by_name(p)
			if p.rel.kind == "world" then
				return tostring(p.rel.app):gsub("%.", "/", 1):lower() ..
						"\1" .. p.key:lower()
			end
			return p.key:lower()
		end
		table.sort(shown, function(a, b)
			if by == "newest" then
				return (tonumber(a.rel.time) or 0) > (tonumber(b.rel.time) or 0)
			end
			return by_name(a) < by_name(b)
		end)
		local first
		for _, p in ipairs(shown) do
			local st = state(p)
			-- simplified: a long name cut by its length, about 10 units a
			-- character at the rows' size
			local most = math.floor(list_w * 0.55 / 10)
			local b = view:row({label = #p.key > most and
					p.key:sub(1, most - 3) .. "..." or p.key,
					icon = aitta_media(p.rel, "icon", function()
						if is_open(root) then
							show_rows()
						end
					end)},
					tostring(p.rel.version) ..
					(p.rel.kind == "world" and ", world for " ..
					tostring(p.rel.app) or "") ..
					(cannot_run(p.rel) and ", not for this Buildat" or
					st == "Installed" and ", installed" or
					st == "Updates" and ", update" or "") ..
					-- The panel says it where a row has no room
					((p.rel.review == "reviewed" or narrow) and "" or
					", unreviewed"))
			magic.SubscribeToEvent(b, "Focused", function()
				if selected ~= p then
					fill(p)
				end
			end)
			-- As Browse's: Enter or a second click within half a second
			-- runs it, a click selects it
			magic.SubscribeToEvent(b, "Released", function()
				local t = buildat.get_time_us()
				local enter = magic.input:GetKeyDown(magic.KEY_RETURN) or
						magic.input:GetKeyDown(magic.KEY_KP_ENTER)
				if (enter or t - (last_click[p] or 0) < 500000) and
						state(p) ~= "Installed" and not cannot_run(p.rel) then
					install(p)
				elseif selected ~= p then
					fill(p)
				end
				last_click[p] = t
			end)
			if p.key == chosen or not first then
				first = {p = p, b = b}
			end
		end
		if #shown == 0 then
			add_text(view.list, #packages == 0 and "No packages" or
					"Nothing matches", DIM)
		end
		view:fit()
		if first and (not selected or chosen == first.p.key) then
			fill(first.p)
			view:show(first.b)
		end
		reseal(w)
		return #shown
	end
	magic.SubscribeToEvent(search, "TextChanged", function()
		if #packages > 0 then
			local n = show_rows()
			say(n .. " of " .. #packages .. " packages")
		end
	end)
	-- Every Aitta's list, merged as Starports' are: a release shown once
	-- by author/name, version and key, from the first Aitta listing it;
	-- a package is its newest
	local lists, errors, waiting = {}, {}, #e.aittas
	local function show_all()
		local newest, order = {}, {}
		for _, a in ipairs(e.aittas) do
			for _, rel in ipairs(lists[a] or {}) do
				if type(rel) == "table" and (not only_reviewed or
						rel.review == "reviewed") and
						(rel.serverless == true or not ON_WEB or
						in_page(rel)) then
					-- The Aitta it came from, never the list's own word: a list
					-- naming another address sent this client's fetches there
					rel.aitta = a
					local k = tostring(rel.author) .. "/" .. tostring(rel.name)
					log:info("aitta page: " .. k .. " " ..
							tostring(rel.version) .. " " ..
							(rel.review == "reviewed" and "reviewed" or
							"unreviewed"))
					if not newest[k] then
						order[#order + 1] = k
					end
					local old = newest[k]
					local runs = not cannot_run(rel)
					local old_runs = old and not cannot_run(old)
					if not old or (runs and not old_runs) or
							(runs == old_runs and newer_release(rel, old)) then
						newest[k] = rel
					end
				end
			end
		end
		have = aitta_installed()
		for _, k in ipairs(order) do
			packages[#packages + 1] = {key = k, rel = newest[k]}
		end
		local n = show_rows()
		if not message then
			say(#packages .. " packages" .. (n < #packages and ", " .. n ..
					" shown" or "") .. (#errors > 0 and "; " ..
					table.concat(errors, "; ") or ""),
					#errors > 0 and WARN or DIM)
		end
	end
	for _, a in ipairs(e.aittas) do
		network.http_get(a .. "/api/v1/aitta/list", function(body, err)
			local v = body and network.parse_json(body)
			if type(v) == "table" and v.ok and type(v.releases) == "table" then
				lists[a] = v.releases
				for _, rel in ipairs(v.releases) do
					if type(rel) == "table" then
						aitta_note(rel, nil)
					end
				end
				for _, d in ipairs(type(v.delisted) == "table" and
						v.delisted or {}) do
					if type(d) == "table" then
						aitta_note(d, d.why ~= "" and d.why or "delisted")
					end
				end
			else
				errors[#errors + 1] = a .. ": " .. tostring(body and
						"the answer was not a list" or err)
			end
			waiting = waiting - 1
			if waiting == 0 then
				show_all()
			end
		end, {description = "Aitta (app list)"})
	end
	if waiting == 0 then
		say("No Aittas in the Starport settings")
	end
end

-- **A reviewer's playtest** ([AITTA_REVIEW]), offered by an Aitta's review
-- page (buildat.offer_playtest, client/api.lua) after leaving to the
-- launcher: asked here, in the launcher's own dialog; on yes the release
-- and its signature fetched by the ticket, checked as an install is, put
-- under <user>/review apart from the installed ones, and started with
-- start(app). A client whose filters hide unreviewed content says so.
function M.playtest(offer, start)
	local ui = require("buildat/extension/ui_utils").safe
	local id = offer.release
	if not effective().filters.unreviewed then
		log:info("playtest: refused by the filters")
		ui.show_message_dialog("This client's filters hide unreviewed " ..
				"content, so it cannot playtest " .. id .. ". A reviewer's " ..
				"client allows it: the Starport settings, Filters.")
		return
	end
	ui.show_confirm_dialog("Playtest " .. id .. " from " .. offer.aitta ..
			"? Not reviewed. It is installed apart, under your user " ..
			"folder's review/, and runs in the server's sandbox.", function()
		log:info("playtest: yes, " .. id)
		-- The network's own leave for the Aitta's address is asked as for
		-- any fetch, once
		fetch_install(offer.aitta, offer.sha256, {description = "Aitta (playtest)",
				query = "?ticket=" .. offer.ticket, review = true,
				refused = "the ticket was refused"}, function(dir, why)
			if not dir then
				log:warning("playtest: " .. id .. ": " .. tostring(why))
				return ui.show_message_dialog("Not installed: " .. tostring(why))
			end
			local author, name, version = id:match("^(.-)/(.-)/(.*)$")
			local app = "review:" .. author .. "." .. name .. "@" .. version
			log:info("playtest: installed " .. app .. " in " .. dir)
			local menu = buildat.menu_extension()
			if menu and type(menu.refresh) == "function" then
				menu.refresh()
			end
			start(app)
		end)
	end, function()
		log:info("playtest: no, " .. id)
	end, "Playtest", "Cancel")
end

-- [SERVERLESS_PLAY] BUILDAT_RUN=<author>/<name>, a play page's #run=: the
-- newest serverless release of it on the Aittas in the settings (or one
-- whose server runs in the page, [WEB_LOCAL_AITTA]), installed if it is
-- not (the signature checked) and played. With no answer from them, an
-- installed version of it is played with no server.
function M.run_serverless(key)
	local ui = require("buildat/extension/ui_utils").safe
	local e = effective()
	local function failed(why)
		log:warning("run " .. key .. ": " .. why)
		ui.show_message_dialog("Could not start " .. key .. ": " .. why)
	end
	local best, waiting, errors = nil, #e.aittas, {}
	local function decide()
		local have = aitta_installed()[key]
		if best and have and have[tostring(best.version)] then
			return play_installed(key, best.version, best)
		end
		if best then
			fetch_install(best.aitta, best.sha256, {description = "Aitta (install)"},
					function(dir, why)
				if not dir then
					return failed(tostring(why))
				end
				play_installed(key, best.version, best)
			end)
			return
		end
		for version, _ in pairs(have or {}) do
			return play_installed(key, version)
		end
		failed(#errors > 0 and table.concat(errors, "; ") or
				"no Aitta in the settings lists it as playable in the browser")
	end
	for _, a in ipairs(e.aittas) do
		network.http_get(a .. "/api/v1/aitta/list", function(body, err)
			local v = body and network.parse_json(body)
			if type(v) == "table" and type(v.releases) == "table" then
				for _, rel in ipairs(v.releases) do
					if type(rel) == "table" and (rel.serverless == true or
							in_page(rel)) and not cannot_run(rel) and
							tostring(rel.author) .. "/" ..
							tostring(rel.name) == key and
							(e.filters.unreviewed or rel.review == "reviewed")
							and (not best or newer_release(rel, best)) then
						rel.aitta = a
						best = rel
					end
				end
			else
				errors[#errors + 1] = a .. ": " .. tostring(err or
						"the answer was not a list")
			end
			waiting = waiting - 1
			if waiting == 0 then
				decide()
			end
		end, {description = "Aitta (app list)"})
	end
	if waiting == 0 then
		decide()
	end
end

function M.safe.open_aitta(on_discuss)
	aitta_page(nil, nil, type(on_discuss) == "function" and on_discuss or nil)
end

-- Whether Aitta's unreviewed releases are shown: the filters'
-- "unreviewed"; under the lock, only reviewed ones ([AITTA_REVIEW])
function M.safe.aitta_shown()
	return effective().filters.unreviewed == true
end

-- [AITTA_PUBLISH_UI]: the publish screen
dofile(__buildat_extension_path("aitta") .. "/publish.lua")({M = M,
	starport = starport, network = network, magic = magic, uistack = uistack,
	open_window = open_window, add_text = add_text, add_label = add_label,
	add_row = add_row, add_button = add_button, add_edit = add_edit,
	add_dropdown = add_dropdown, effective = effective, WARN = WARN,
	DIM = DIM})
-- The verb itself in this file, the extension's surface, which is what
-- the sandbox scan holds an extension's verbs to; publish.lua's is what
-- it calls
local open_publish = M.safe.open_publish
function M.safe.open_publish() open_publish() end
M.open_publish = M.safe.open_publish
M.open_aitta = M.safe.open_aitta
M.aitta_shown = M.safe.aitta_shown
return M
-- vim: set noet ts=4 sw=4:
