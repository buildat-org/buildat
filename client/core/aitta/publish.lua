-- Buildat: client/core/aitta/publish.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Publishing without a terminal** ([AITTA_PUBLISH_UI],
-- doc/plan/aitta_plan.md): an author's app or extension in
-- <user>/dev_apps/<name>, its meta.json as a form, the publishing key in
-- <user>/aitta_keys/<author>.key, the key bound on an Aitta by a handover
-- to its page, and one button that packs, signs and uploads. Two pages,
-- so that each fits 800x600: the package and its manifest, then the key,
-- the Aitta and the publish. The file work is __buildat_aitta_dev's
-- (src/client/app.cpp); this side is the dialogs and the upload.
--
-- Picks named in the plan: a dev app's tile has the badge "Dev" and its
-- saves under its name, as a bundled app's; "New..." writes the few files
-- itself rather than copying a template; whether a key is bound is asked
-- of the Aitta (GET /api/v1/aitta/info?key=).
return function(h)
local M, network, magic, uistack = h.M, h.network, h.magic, h.uistack
local open_window, add_text, add_label, add_row, add_button, add_edit,
		add_dropdown = h.open_window, h.add_text, h.add_label, h.add_row,
		h.add_button, h.add_edit, h.add_dropdown
local WARN, DIM = h.WARN, h.DIM
local OK = magic.Color(0.5, 0.9, 0.5)
local log = buildat.Logger("extension/aitta")
local USER = __buildat_get_path("user")
local KEYS = USER .. "/aitta_keys"
local AUDIENCES = {"everyone", "teen", "adult"}
-- Before an Aitta has answered: the official instance's
local LICENCES = {"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause",
	"ISC", "Zlib", "MPL-2.0", "GPL-2.0", "GPL-3.0", "LGPL-2.1", "LGPL-3.0",
	"AGPL-3.0", "Unlicense", "CC0-1.0", "CC-BY-3.0", "CC-BY-4.0",
	"CC-BY-SA-3.0", "CC-BY-SA-4.0"}
-- The manifest's fields on the form, in order: key, label, kind
local FIELDS = {
	{"author", "Author", "edit"},
	{"name", "Name", "edit"},
	{"version", "Version", "edit"},
	{"description", "Description", "edit"},
	{"license_code", "Code licence", "licence"},
	{"license_media", "Media licence", "licence"},
	{"audience", "Audience", "choice"},
	{"home_hearth", "Home Hearth", "edit"},
	{"changelog", "Changelog file", "edit"},
	-- [PACKAGE_MEDIA] Files in the package, checked as Aitta does
	{"icon", "Icon (PNG)", "edit"},
	{"screenshot", "Screenshot", "edit"},
}
local PIECE = 60000

-- What the screen remembers between its pages and visits
local st = {selected = nil, aitta = nil, info = {}, result = nil}

local function read_meta(name)
	local f = io.open(USER .. "/dev_apps/" .. name .. "/meta.json", "rb")
	if not f then
		return {}
	end
	local m = network.parse_json(f:read("*a"))
	f:close()
	return type(m) == "table" and m or {}
end

-- The package's own engine_api, which its author bumps when it is ported;
-- this client's only where it says none
local function write_meta(name, m)
	m.engine_api = m.engine_api or __buildat_aitta_dev("engine_api")
	local text = assert(network.write_json(m, true))
	local ok, err = buildat.write_file_atomic(USER .. "/dev_apps/" .. name ..
			"/meta.json", text .. "\n")
	if not ok then
		return false, err
	end
	return true
end

local function find(list, v)
	for i, x in ipairs(list) do
		if x == v then
			return i
		end
	end
	return nil
end

-- A licence the Aitta takes: its list, "-only", "-or-later" and "+" aside
local function licence_ok(l, list)
	l = tostring(l):gsub("%-only$", ""):gsub("%-or%-later$", ""):gsub("%+$", "")
	return find(list, l) ~= nil
end

-- 1.0.0 -> 1.0.1, 1.2 -> 1.3, 2.0.0-beta -> 2.0.1-beta
local function raise(v)
	local out, n = tostring(v):gsub("(%d+)(%D*)$", function(d, rest)
		return tostring(tonumber(d) + 1) .. rest
	end, 1)
	return n == 1 and out or tostring(v) .. ".1"
end
assert(raise("1.0.0") == "1.0.1" and raise("1.9") == "1.10" and
		raise("2.0.0-beta") == "2.0.1-beta" and raise("x") == "x.1")

-- The address a client joins for an Aitta's URL (launch_grid's
-- hearth_address)
local function join_address(url)
	local scheme, host = tostring(url):match("^(https?)://([^/?#]+)")
	if not scheme then
		return nil
	end
	return scheme == "https" and "https://" .. host or
			(host:find(":%d+$") and host or host .. ":80")
end

local function aittas()
	return h.effective().aittas
end

local function refresh_menu()
	local menu = buildat.menu_extension()
	if menu and type(menu.refresh) == "function" then
		menu.refresh()
	end
end

local page_package, page_publish, page_page

-- "New app..." and "New extension...": the name, then the folder
local function ask_new(kind, back)
	local root, w = open_window("aitta new", 560, back,
			{close_glyph = false})
	add_text(w, "A new " .. kind .. " in " .. USER .. "/dev_apps/. Its name: " ..
			"a-z, 0-9 and _, 40 at most.")
	local e = add_edit(w, "")
	local why = add_text(w, "", WARN)
	local r = add_row(w)
	local function go()
		local name = e:GetText()
		local path, err = __buildat_aitta_dev("new", name, kind)
		if not path then
			why.text = tostring(err)
			log:info("aitta publish: not made: " .. why.text)
			return
		end
		uistack.main:pop(root)
		st.selected = name
		st.result = nil
		refresh_menu()
		page_package("Made " .. path .. (kind == "app" and
				": it is on the grid as a Dev tile, to play" or ""))
	end
	magic.SubscribeToEvent(e, "TextFinished", go)
	add_button(r, "Make it", go, nil, true)
	add_button(r, "Cancel", function()
		uistack.main:pop(root)
		back()
	end)
	e:SetFocus(true)
	log:info("aitta publish: a new " .. kind .. "'s name asked")
end

-- **Page 1: the package and its manifest.** Each field is checked as it
-- is typed, by the rules `aitta pack` applies (check_manifest(), through
-- __buildat_aitta_dev("check")) and the Aitta's licence list; the reason
-- shows under the field it is about.
page_package = function(message)
	local root, w = open_window("aitta publish", 780)
	local back = function() page_package() end
	add_text(w, "Publish an app or extension: 1. the package")
	if message then
		add_text(w, message, OK)
	end
	local entries = __buildat_aitta_dev("list") or {}
	-- The one worked on last, or the first there is
	local known = false
	for _, e in ipairs(entries) do
		known = known or e.name == st.selected
	end
	if not known then
		st.selected = entries[1] and entries[1].name
	end
	local pr = add_row(w)
	add_label(pr, #entries == 0 and "None yet in dev_apps:" or "Package:", 110)
	local names = {}
	for _, e in ipairs(entries) do
		names[#names + 1] = {e.name .. (e.kind == "extension" and
				" (ext.)" or e.kind == "world" and " (world)" or ""), e.name}
	end
	if #names > 0 then
		add_dropdown(pr, names, st.selected, function(name)
			uistack.main:pop(root)
			st.selected = name
			st.result = nil
			page_package()
		end)
	end
	local nr = add_row(w)
	add_button(nr, "New app...", function()
		uistack.main:pop(root)
		ask_new("app", back)
	end)
	add_button(nr, "New extension...", function()
		uistack.main:pop(root)
		ask_new("extension", back)
	end)
	add_button(nr, "Open folder", function()
		__buildat_create_directories(USER .. "/dev_apps")
		__buildat_aitta_dev("open", USER .. "/dev_apps" ..
				(st.selected and "/" .. st.selected or ""))
	end)
	local entry = nil
	for _, e in ipairs(entries) do
		if e.name == st.selected then
			entry = e
		end
	end
	log:info("aitta publish: the package page, " .. tostring(st.selected))
	if not entry then
		add_text(w, "Choose a package, or make a new one: an app is on " ..
				"the grid at once, to play before it is published.", DIM)
		return
	end
	local m = read_meta(entry.name)
	-- [WORLD_PACKAGES] A world says what it is a save of
	if entry.kind == "world" then
		add_text(w, "A world for " .. tostring(m.app) .. (m.app_version and
				" " .. tostring(m.app_version) or "") .. ", made with Buildat " ..
				tostring(m.buildat_version) .. ". Everything in the save " ..
				"goes in: the map, its settings, its players' names and " ..
				"inventories. Publish this world again on the save to copy " ..
				"it again.", DIM)
	end
	m.name = m.name or entry.name
	m.version = m.version or "0.1.0"
	m.audience = m.audience or "everyone"
	m.kind = entry.kind
	m.engine_api = m.engine_api or __buildat_aitta_dev("engine_api")
	local licences = st.info[st.aitta or aittas()[1] or ""] and
			st.info[st.aitta or aittas()[1]].licences or LICENCES
	local why_of = {}
	local general = nil
	local function recheck()
		local why = __buildat_aitta_dev("check", network.write_json(m),
				entry.name) or ""
		-- " ", so that each keeps its line and the form does not move
		-- under the pointer as reasons come and go
		for k, t in pairs(why_of) do
			t.text = " "
		end
		general.text = ""
		local field = why:match('^"([%w_]+)"')
		-- An image's reason starts with its file's name
		for _, k in ipairs({"icon", "screenshot"}) do
			if m[k] and m[k] ~= "" and why:sub(1, #m[k] + 2) == m[k] .. ": " then
				field = k
			end
		end
		if why ~= "" and why_of[field] then
			why_of[field].text = why
		elseif why ~= "" then
			general.text = why
		end
		for _, k in ipairs({"license_code", "license_media"}) do
			if field ~= k and m[k] and m[k] ~= "" and
					not licence_ok(m[k], licences) then
				why_of[k].text = m[k] .. " is not one this Aitta takes"
				why = why ~= "" and why or why_of[k].text
			end
		end
		return why
	end
	for _, f in ipairs(FIELDS) do
		local k, label, kind = f[1], f[2], f[3]
		local r = add_row(w)
		add_label(r, label, 140)
		if kind == "edit" then
			local e = add_edit(r, tostring(m[k] or ""))
			magic.SubscribeToEvent(e, "TextChanged", function()
				m[k] = e:GetText()
				if m[k] == "" and (k == "home_hearth" or k == "changelog" or
						k == "icon" or k == "screenshot") then
					m[k] = nil
				end
				recheck()
			end)
		else
			add_dropdown(r, kind == "licence" and licences or AUDIENCES,
					m[k], function(v)
				m[k] = v
				recheck()
			end, {min_width = 160, none = "(choose)"})
		end
		why_of[k] = add_text(w, " ", WARN)
	end
	general = add_text(w, "", WARN)
	recheck()
	local saved = add_text(w, "", OK)
	local r = add_row(w)
	local function save()
		local ok, err = write_meta(entry.name, m)
		saved.text = ok and "Saved " .. entry.path .. "/meta.json" or
				"Not saved: " .. tostring(err)
		return ok
	end
	add_button(r, "Save", save)
	add_button(r, "Next: key and publish", function()
		if not save() then
			return
		end
		local why = recheck()
		if why ~= "" then
			saved.text = ""
			general.text = "Not yet: " .. why
			return
		end
		uistack.main:pop(root)
		page_publish()
	end, nil, true)
end

-- What the chosen Aitta says of the key: its licences and whom the key is
-- bound to; nil while asking, {error =} for an Aitta without the call
local function ask_info(url, pub, done)
	network.http_get(url .. "/api/v1/aitta/info?key=" .. pub, function(body, err)
		local v = body and network.parse_json(body)
		if type(v) == "table" and v.ok then
			st.info[url] = {licences = type(v.licences) == "table" and
					v.licences or LICENCES, author = tostring(v.author or "")}
		else
			st.info[url] = {error = type(v) == "table" and tostring(v.error) or
					tostring(err or "no answer")}
		end
		done()
	end, {description = "Aitta (publishing)"})
end

-- The release up: its .sig, which says who signed what, then the archive
-- in pieces under the server's 64 KiB POST limit (`aitta publish`'s)
local function upload(url, zip_path, done)
	local function read(path)
		local f = io.open(path, "rb")
		if not f then
			return nil
		end
		local d = f:read("*a")
		f:close()
		return d
	end
	local zip, sig = read(zip_path), read(zip_path:gsub("%.zip$", ".sig"))
	local sv = sig and network.parse_json(sig)
	if not zip or type(sv) ~= "table" then
		return done(nil, "cannot read " .. zip_path)
	end
	local base = url .. "/api/v1/aitta/"
	local function call(what, body, next_step)
		network.http_post(base .. what, body, function(got, err)
			local v = got and network.parse_json(got)
			if type(v) ~= "table" then
				return done(nil, tostring(err or "the Aitta's answer was not JSON"))
			end
			if not v.ok then
				return done(nil, tostring(v.error))
			end
			next_step(v)
		end, {description = "Aitta (publishing)"})
	end
	local sha = tostring(sv.sha256)
	local function part(at)
		if at >= #zip then
			return call("upload_end?sha256=" .. sha, "", function(v)
				done(tostring(v.result), nil, v.warning and tostring(v.warning))
			end)
		end
		call("upload_part?sha256=" .. sha .. "&offset=" .. at,
				zip:sub(at + 1, at + PIECE), function() part(at + PIECE) end)
	end
	call("upload_begin?size=" .. #zip, sig, function() part(0) end)
end

-- **Page 2: the key, the Aitta, the publish**
page_publish = function(message)
	local name = st.selected
	local m = read_meta(name)
	local author = tostring(m.author or "")
	local root, w = open_window("aitta publish", 780)
	add_text(w, "Publish " .. author .. "/" .. tostring(m.name) .. " " ..
			tostring(m.version) .. ": 2. the key and the Aitta")
	if message then
		add_text(w, message, WARN)
	end
	-- The key
	local pub = __buildat_aitta_dev("public", author)
	add_text(w, "Your publishing key is who you are as a publisher: whoever " ..
			"has the file publishes as " .. author .. ". It is not encrypted. " ..
			"Copy it somewhere safe (a USB stick, a password manager) from " ..
			KEYS .. "/" .. author .. ".key; without it, no new version " ..
			"of your packages can be published.", DIM)
	local kr = add_row(w)
	if pub then
		add_label(kr, "Key: " .. author .. ".key  " .. pub:sub(1, 18) .. "...", 0)
	else
		add_button(kr, "Create my publishing key", function()
			local p, err = __buildat_aitta_dev("keygen", author)
			uistack.main:pop(root)
			page_publish(not p and tostring(err) or nil)
		end, nil, true)
	end
	add_button(kr, "Show the file", function()
		__buildat_create_directories(KEYS)
		__buildat_aitta_dev("open", KEYS)
	end)
	-- The Aitta: the client's list, picked when there are several
	local list = aittas()
	if #list == 0 then
		add_text(w, "No Aittas in the Starport settings: add one there.", WARN)
	end
	if not find(list, st.aitta) then
		st.aitta = list[1]
	end
	if #list > 1 then
		local ar = add_row(w)
		add_label(ar, "Publish on:", 110)
		add_dropdown(ar, list, st.aitta, function(a)
			st.aitta = a
			uistack.main:pop(root)
			page_publish()
		end)
	end
	local url = st.aitta
	local info = url and st.info[url]
	local status = add_text(w, "", DIM)
	local br = add_row(w)
	if url and pub then
		if not info or info.pub ~= pub then
			status.text = "Asking " .. url .. " about the key..."
			ask_info(url, pub, function()
				st.info[url].pub = pub
				uistack.main:pop(root)
				page_publish(message)
			end)
		elseif info.error then
			status.text = url .. " did not say whether the key is bound (" ..
					info.error .. "); publishing tells"
		elseif info.author == author then
			status.text = "The key is bound to " .. author .. " on " .. url
			status.color = OK
		elseif info.author ~= "" then
			status.text = "The key is bound to " .. info.author .. " on " ..
					url .. ", and the manifest says " .. author
			status.color = WARN
		else
			status.text = "The key is not bound on " .. url .. " yet: bind it " ..
					"there, logged in, then come back here"
		end
		if not (info and info.author == author) then
			add_button(br, "Bind on " .. url .. "...", function()
				local address = join_address(url)
				if not address then
					return
				end
				uistack.main:pop(root)
				buildat.set_feedback({address = address,
					bind = {author = author, key = pub}})
				st.info[url] = nil
				local sub
				sub = magic.SubscribeToEvent("Update", function()
					require("buildat/core/urho3d").unsafe.UnsubscribeFromEvent("Update", sub)
					if #h.starport.logged_in_ids() > 0 then
						h.starport.join_with_id(address)
					else
						buildat.safe.join_server(address)
					end
				end)
			end)
			add_button(br, "Check again", function()
				st.info[url] = nil
				uistack.main:pop(root)
				page_publish()
			end)
		end
	end
	-- Pack and publish
	local files, size = __buildat_aitta_dev("files", name)
	files = files or {}
	table.sort(files)
	add_text(w, "Goes in: " .. #files .. " files, " ..
			math.ceil((size or 0) / 1000) .. " kB (names starting with . " ..
			"are left out):", DIM)
	-- Every one, a line each, in about eight rows that the wheel scrolls,
	-- so that the buttons below stay on the page ([PUBLISH_FILES])
	local ui_utils = require("buildat/extension/ui_utils").safe
	local view = ui_utils.list_view(w, w.width - 24, 8 * 22,
			{row_height = 22, spacing = 0, wheel = 44})
	for _, f in ipairs(files) do
		view:header(f, 13, "text")
	end
	view:fit()
	local result = add_text(w, st.result or "", st.result_ok and OK or WARN)
	local pr = add_row(w)
	add_button(pr, "Back", function()
		uistack.main:pop(root)
		page_package()
	end)
	add_button(pr, "Pack and publish", function()
		local zip, err = __buildat_aitta_dev("pack", name)
		if not zip then
			result.text = "Not packed: " .. tostring(err)
			return
		end
		if not url then
			result.text = "Packed " .. zip .. "; no Aitta to publish on"
			return
		end
		result.text = "Packed " .. zip .. "; uploading to " .. url .. "..."
		result.color = DIM
		upload(url, zip, function(id, why, warning)
			log:info("aitta publish: " .. (id and "published " .. id or
					"not published: " .. tostring(why)))
			st.result_ok, st.raise = id ~= nil, false
			if id then
				st.result = "Published " .. id .. " on " .. url .. ". It is " ..
						"listed as unreviewed, under Apps from Aitta" ..
						" (an update waits out the Aitta's update delay)." ..
						(warning and "\n" .. warning or "")
			elseif tostring(why):find("here already", 1, true) then
				st.result = tostring(m.version) .. " is already published: " ..
						"raise the version"
				st.raise = true
			else
				st.result = "Not published: " .. tostring(why)
			end
			uistack.main:pop(root)
			page_publish()
		end)
	end, pub ~= nil, true)
	if st.raise and not st.result_ok then
		add_button(pr, "Raise the version", function()
			m.version = raise(m.version)
			write_meta(name, m)
			log:info("aitta publish: raised to " .. m.version)
			st.raise, st.result = nil, "The version is " .. m.version .. " now"
			st.result_ok = true
			uistack.main:pop(root)
			page_publish()
		end)
	end
	-- [AITTA_PACKAGE_PAGE] Its page on that Aitta, last in
	-- the row
	if url and pub then
		add_button(pr, "The page on " .. url .. "...", function()
			uistack.main:pop(root)
			page_page()
		end)
	end
	log:info("aitta publish: the key page, " .. (pub and status.text or "no key"))
end

-- **Page 3: the package's page on the Aitta** ([AITTA_PACKAGE_PAGE]): not
-- in any release, the same whichever is shown; its files in the package's
-- aitta_page/, which pack leaves out
page_page = function(message)
	local name, url = st.selected, st.aitta
	local m = read_meta(name)
	local pkg = tostring(m.author) .. "/" .. tostring(m.name)
	local root, w = open_window("aitta page", 780)
	add_text(w, "The page of " .. pkg .. " on " .. tostring(url))
	local desc, shots, dir = __buildat_aitta_dev("page_read", name)
	add_text(w, "On the package's page on the Aitta, not in any release. " ..
			"The description: 20000 characters at most, a blank line " ..
			"between paragraphs, an http(s):// address a link.", DIM)
	local e = add_edit(w, desc or "")
	e.multiLine = true
	e:SetFixedHeight(220)
	shots = shots or {}
	add_text(w, #shots .. " screenshots (PNG or JPEG, 8 at most, 1920 px " ..
			"and 2 MB each, in the order of their names) in " ..
			tostring(dir) .. (#shots > 0 and ": " ..
			table.concat(shots, ", ") or ""), DIM)
	local result = add_text(w, message or "", st.page_ok and OK or WARN)
	local r = add_row(w)
	add_button(r, "Back", function()
		uistack.main:pop(root)
		page_publish()
	end)
	add_button(r, "Show the folder", function()
		__buildat_create_directories(dir)
		__buildat_aitta_dev("open", dir)
	end)
	add_button(r, "Send", function()
		local zip, err = __buildat_aitta_dev("page_pack", name, e:GetText())
		if not zip then
			result.text = "Not sent: " .. tostring(err)
			result.color = WARN
			return
		end
		result.text = "Sending to " .. url .. "..."
		result.color = DIM
		upload(url, zip, function(id, why)
			st.page_ok = id ~= nil
			uistack.main:pop(root)
			page_page(id and "Sent: " .. id or "Not sent: " .. tostring(why))
		end)
	end, nil, true)
	log:info("aitta publish: the page of " .. pkg ..
			(message and ", " .. message or ""))
end

function M.safe.open_publish()
	page_package()
end

-- [WORLD_PACKAGES] "Publish this world" on a save of an app that takes
-- worlds (client/launch_grid.lua), code the paths it runs as code: the
-- save copied into a world package in dev_apps, made or refreshed, and the
-- screen opened on it. Trusted only.
function M.publish_world(app, save, code)
	local name, err = __buildat_aitta_dev("world_new", app, save, code or {})
	log:info("aitta publish: world " .. tostring(save) .. " of " ..
			tostring(app) .. ": " .. tostring(name or err))
	if not name then
		return require("buildat/extension/ui_utils").safe.show_message_dialog(
				"Could not publish " .. tostring(save) .. ": " .. tostring(err))
	end
	st.selected, st.result = name, nil
	page_package("The save " .. save .. " copied into " .. USER ..
			"/dev_apps/" .. name .. "/world")
end
end
-- vim: set noet ts=4 sw=4:
