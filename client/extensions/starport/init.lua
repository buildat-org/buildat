-- Buildat: client/extensions/starport/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The client's side of Starport** ([STARPORT] 4, 5, 5b, 5c;
-- doc/plan/starport_plan.md): the Starports this client asks, its key on
-- each, the filters and their lock, the list merged from all of them, and
-- reports with their receipts.
--
-- The safe half is what the connect screen (sandboxed) and any server's
-- Lua may call: fetch the list, and open this side's own dialogs. A
-- report and a setting are made only in those dialogs, which this side
-- draws, so a server's script cannot report in the player's name or turn
-- a filter off.
--
--   <user>/starport.json          the settings, the keys, the receipts
--   <user>/starport_keys.json     export and import of the keys (5c)
--   /etc/buildat/starport.json    the managed file (Windows:
--                                 %ProgramData%\buildat\starport.json;
--                                 BUILDAT_STARPORT_MANAGED overrides):
--                                 what it sets cannot be changed here
local log = buildat.Logger("extension/starport")
local network = require("buildat/extension/network")
local uistack = require("buildat/extension/uistack")
local magic = require("buildat/extension/urho3d").safe
local rgb = require("buildat/extension/ui_utils").safe.rgb
local group = dofile(__buildat_extension_path("starport") .. "/group.lua")
local M = {safe = {}}

local DEFAULT_STARPORT = "https://starport.buildat.org"
-- [AITTA_MVP]: the registry of apps this client browses
local DEFAULT_AITTA = "https://aitta.buildat.org"
local STATE_PATH = __buildat_get_path("user") .. "/starport.json"
local EXPORT_PATH = __buildat_get_path("user") .. "/starport_keys.json"
local STYLE = "launch_menu/res/main_style.xml"

local AUDIENCES = {"everyone", "teen", "adult"}
local KINDS = {"world", "arena", "app", "other"}
local ACCESSES = {"open", "invite", "starport", "password", "external"}
-- The last list each Starport gave, for when it cannot be reached
-- ([STARPORT] 4): {url = {ts, servers}}
local LIST_CACHE = __buildat_get_path("cache") .. "/starport_list.json"
-- A descriptor the filter can hide, and the values it hides at
local DESCRIPTORS = {
	{"violence", "realistic violence", {realistic = true}},
	{"chat", "unmoderated chat", {unmoderated = true}},
	{"ugc", "unmoderated content", {unmoderated = true}},
	{"language", "strong language", {yes = true}},
	{"sexual", "sexual content", {yes = true}},
	{"drugs", "drugs", {yes = true}},
	{"purchases", "purchases", {yes = true}},
	{"gambling", "gambling", {yes = true}},
	{"personal_data", "collects personal data", {yes = true}},
}
local REASONS = {
	{"category", "Wrong category or rating"},
	{"illegal", "Illegal content"},
	{"csam", "Child sexual abuse material"},
	{"harassment", "Harassment or abuse"},
	{"scam", "Scam, phishing or malware"},
	{"impersonation", "Impersonation"},
	{"spam", "Spam listing"},
	{"other", "Other"},
}

--
-- State
--

-- Everything an `everyone` audience and a teen one may see; adult hidden
-- until the user says they want it (a self-declared choice, not an age check)
local function default_filters()
	return {
		audience = {everyone = true, teen = true, adult = false},
		kind = {world = true, arena = true, app = true, other = true},
		access = {open = true, invite = true, starport = true,
			password = true, external = true},
		hide = {},
		languages = "",
		-- [AITTA_MVP]: Aitta lists unreviewed apps, so it is a filter too,
		-- and the lock covers it
		unreviewed = true,
	}
end

-- **A Starport's address with no port is on 29595** ([STARPORT] 10g):
-- "host" and "http://host" are http://host:29595, as the server takes them
-- (builtin/starport_announce); https:// is a proxy's, on 443
local function normalize_url(u)
	u = tostring(u):gsub("/+$", "")
	if not u:find("://", 1, true) then
		u = "http://" .. u
	end
	if u:sub(1, 7) == "http://" then
		local hostport = u:sub(8)
		local after = hostport:sub(1, 1) == "[" and
				(hostport:match("^%[.-%](.*)$") or "") or hostport
		if not after:find(":", 1, true) then
			u = u .. ":29595"
		end
	end
	return u
end
assert(normalize_url("host") == "http://host:29595" and
		normalize_url("http://host/") == "http://host:29595" and
		normalize_url("http://host:80") == "http://host:80" and
		normalize_url("https://host") == "https://host" and
		normalize_url("http://[::1]") == "http://[::1]:29595")

local function normalize_urls(list)
	local out = {}
	for i, u in ipairs(list) do
		out[i] = normalize_url(u)
	end
	return out
end

local function read_json(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local v = network.parse_json(text)
	return type(v) == "table" and v or nil
end

local function write_json_file(path, v)
	local text = assert(network.write_json(v))
	local f, err = io.open(path .. ".tmp", "wb")
	if not f then
		log:warning("Cannot write " .. path .. ": " .. tostring(err))
		return false
	end
	f:write(text)
	f:close()
	os.remove(path)
	return os.rename(path .. ".tmp", path)
end

local function managed_path()
	local env = buildat.get_env("BUILDAT_STARPORT_MANAGED")
	if env and env ~= "" then
		return env
	end
	local pd = os.getenv("ProgramData")
	if pd and pd ~= "" then
		return pd .. "\\buildat\\starport.json"
	end
	return "/etc/buildat/starport.json"
end

local state = nil

local function load_state()
	if state then
		return state
	end
	state = read_json(STATE_PATH) or {}
	state.starports = type(state.starports) == "table" and state.starports or
			{DEFAULT_STARPORT}
	state.filters = type(state.filters) == "table" and state.filters or
			default_filters()
	for k, v in pairs(default_filters()) do
		if state.filters[k] == nil then
			state.filters[k] = v
		elseif type(v) == "table" and type(state.filters[k]) == "table" then
			-- A value added since these were saved (access external) is
			-- the default's; a managed file's lists are taken as written
			for kk, vv in pairs(v) do
				if state.filters[k][kk] == nil then
					state.filters[k][kk] = vv
				end
			end
		end
	end
	if state.send_key == nil then
		state.send_key = true
	end
	if state.direct_connect == nil then
		state.direct_connect = true
	end
	state.keys = type(state.keys) == "table" and state.keys or {}
	state.receipts = type(state.receipts) == "table" and state.receipts or {}
	state.pin = state.pin or ""
	-- [STARPORT_RECOMMENDS]: the Aittas, a list since one `aitta`; those
	-- removed or not taken when offered; and what each Starport
	-- recommends, by Starport: {hearth =, aittas = {...}}
	if type(state.aittas) ~= "table" then
		state.aittas = {type(state.aitta) == "string" and state.aitta or
				DEFAULT_AITTA}
	end
	state.aitta = nil
	state.ignored_aittas = type(state.ignored_aittas) == "table" and
			state.ignored_aittas or {}
	state.recommends = type(state.recommends) == "table" and
			state.recommends or {}
	-- [STARPORT] 10: the Starport IDs logged in, by Starport: {session,
	-- name, band, key}
	state.ids = type(state.ids) == "table" and state.ids or {}
	return state
end

local function save_state()
	write_json_file(STATE_PATH, state)
end

-- The managed file's word over the user's, read every time: an
-- administrator's change counts without a restart
local function managed()
	return read_json(managed_path()) or {}
end

-- [WEB_ID_TRUST]: where the server says it is listed (set_web_starports)
local web_starports = {}

-- What is in effect: the user's settings, under the managed file's, and
-- on the web the Starports the server is listed on
local function effective()
	local s, m = load_state(), managed()
	local starports = normalize_urls(type(m.starports) == "table" and
			m.starports or s.starports)
	for _, r in ipairs(web_starports) do
		local have = false
		for _, u in ipairs(starports) do
			have = have or u == normalize_url(r.url)
		end
		if not have then
			starports[#starports + 1] = normalize_url(r.url)
		end
	end
	local filters = s.filters
	if type(m.filters) == "table" then
		-- What the file leaves out is the default's, not the user's
		filters = default_filters()
		for k, v in pairs(m.filters) do
			filters[k] = v
		end
	end
	-- The managed file's "aittas", or its "aitta" of before the list
	local m_aittas = type(m.aittas) == "table" and m.aittas or
			type(m.aitta) == "string" and {m.aitta} or nil
	return {
		starports = starports,
		filters = filters,
		direct_connect = (m.direct_connect == nil) and s.direct_connect or
				m.direct_connect == true,
		send_key = s.send_key,
		aittas = normalize_urls(m_aittas or s.aittas),
		managed = {starports = m.starports ~= nil, filters = m.filters ~= nil,
			direct_connect = m.direct_connect ~= nil, aittas = m_aittas ~= nil},
	}
end

-- Onto the list, and off the ignored one
local function add_aitta(url)
	local s = load_state()
	for i = #s.ignored_aittas, 1, -1 do
		if normalize_url(s.ignored_aittas[i]) == url then
			table.remove(s.ignored_aittas, i)
		end
	end
	for _, a in ipairs(s.aittas) do
		if normalize_url(a) == url then
			return
		end
	end
	table.insert(s.aittas, url)
end

-- [STARPORT_RECOMMENDS]: what a Starport answered in /api/list or an ID's
-- "me", kept; set below, with the dialog that offers it
local note_recommends
local note_version

local function hex(bytes)
	return (bytes:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- simplified: the PIN as an unsalted SHA-256; a four-digit PIN is found
-- by trying them all whatever the hash, and the lock is the client's
-- only ([STARPORT] 4 says so to the user)
local function pin_hash(pin)
	return hex(buildat.sha256("buildat starport pin:" .. pin))
end

-- This client's key on a Starport, made the first time it is needed
local function key_for(url)
	local s = load_state()
	-- [STARPORT] 10a: an ID holds the key, and logging in brings it
	local id = s.ids and s.ids[url]
	if id and type(id.key) == "string" and #id.key == 64 then
		return id.key
	end
	if not s.keys[url] then
		s.keys[url] = hex(buildat.random_bytes(32))
		save_state()
	end
	return s.keys[url]
end

--
-- The list
--

local last_rows = {}

-- The last fetch's row of an address
local function row_of(address)
	for _, x in ipairs(last_rows) do
		if x.address == address then
			return x
		end
	end
	return nil
end

-- Whether the filters let a listing through
-- [STARPORT] 10b: the youngest band of the IDs logged in caps what is
-- shown: under 13 sees `everyone`, 13 to 17 also `teen`
local function band_allows(audience)
	local s = load_state()
	for _, id in pairs(s.ids or {}) do
		-- Not said yet counts as the youngest
		if (id.band == "under 13" or id.band == "not said") and
				audience ~= "everyone" then
			return false
		end
		if id.band == "13-17" and audience == "adult" then
			return false
		end
	end
	return true
end

local function passes(f, x)
	if not f.audience[x.audience] or not f.kind[x.kind] or
			not f.access[x.access] or not band_allows(x.audience) then
		return false
	end
	for _, d in ipairs(DESCRIPTORS) do
		-- A server whose version does not know a descriptor says
		-- "unknown", which a filter hiding it hides too ([STARPORT] 3)
		local v = (x.descriptors or {})[d[1]] or "unknown"
		if f.hide[d[1]] and (d[3][v] or v == "unknown") then
			return false
		end
	end
	if f.languages ~= "" then
		local want = {}
		for l in f.languages:gmatch("[^,%s]+") do
			want[l:lower()] = true
		end
		local any = false
		for _, l in ipairs(x.languages or {}) do
			any = any or want[tostring(l):lower()] or false
		end
		if not any then
			return false
		end
	end
	-- A listing a moderator hid is left out of a filtered view: any
	-- filter that hides something
	if x.restricted then
		for _, a in ipairs(AUDIENCES) do
			if not f.audience[a] then
				return false
			end
		end
	end
	return true
end

-- A server behind a proxy with TLS (its listing's tls) is joined by
-- "https://host:port", the port always said, so that the address a client
-- is connected to finds its row however it was typed
local function canonical(address)
	local host, rest = tostring(address):match("^https://([^/]-)(:?%d*)/?$")
	if not host then
		return address
	end
	return "https://" .. host .. ":" .. (rest ~= "" and rest:sub(2) or "443")
end
M.canonical_address = canonical

-- simplified: one server on two Starports is one row by its address; its
-- listings there are separate keys, as each Starport made its own secret
local function merge(by_starport)
	local rows, at = {}, {}
	for _, pair in ipairs(by_starport) do
		local url, servers = pair[1], pair[2]
		for _, x in ipairs(servers) do
			if type(x) == "table" and x.host and x.port then
				local addr = (x.tls and "https://" or "") .. tostring(x.host) ..
						":" .. tostring(x.port)
				local row = at[addr]
				if not row then
					row = {}
					for k, v in pairs(x) do
						row[k] = v
					end
					row.address = addr
					row.ids = {}
					row.starports = {}
					at[addr] = row
					rows[#rows + 1] = row
				end
				row.ids[url] = x.id
				row.starports[#row.starports + 1] = url:gsub("^%a+://", "")
			end
		end
	end
	table.sort(rows, function(a, b)
		return (tonumber(a.players) or 0) > (tonumber(b.players) or 0)
	end)
	return rows
end

-- The outcome of this client's open reports, asked of each Starport by
-- the key that made them
local function poll_receipts()
	local s = load_state()
	if not s.send_key then
		return
	end
	local by_url = {}
	for _, r in ipairs(s.receipts) do
		if r.state ~= "upheld" and r.state ~= "rejected" and r.keyed then
			by_url[r.starport] = by_url[r.starport] or {}
			table.insert(by_url[r.starport], r.receipt)
		end
	end
	for url, ids in pairs(by_url) do
		network.http_post(url .. "/api/report_status", network.write_json(
				{key = key_for(url), receipts = ids}), function(body)
			local v = body and network.parse_json(body)
			if type(v) ~= "table" or type(v.reports) ~= "table" then
				return
			end
			for _, o in ipairs(v.reports) do
				for _, r in ipairs(s.receipts) do
					if r.receipt == o.receipt and r.starport == url then
						r.state, r.outcome = o.state, o.outcome
					end
				end
			end
			save_state()
		end, {description = "Starport"})
	end
end

-- Whether the network extension has the user's yes for a url's host
-- `fresh`: and not asked again at the next request (network's
-- ACCEPTANCE_VALID_S, a week)
local function accepted(url, fresh)
	local origin = url:match("^(https?://[^/]+)")
	for _, a in ipairs(network.known_addresses()) do
		if a.uri == origin and a.accepted and (not fresh or
				os.time() - a.last_attempt < 7 * 24 * 3600) then
			return true
		end
	end
	return false
end

-- **A listing's icon** ([SERVER_ICONS]): its hash in the list, the PNG
-- at /api/icon/<hash>, fetched once into the cache's server_icons/ where
-- the handshake's go, checked there the same way; the lobby's floor
-- wears it. One that does not hash to its name is not kept.
local ICON_DIR = __buildat_get_path("cache") .. "/server_icons/"
local icon_asked = {}
local function fetch_icons(url, servers)
	for _, x in ipairs(servers) do
		local sha = type(x) == "table" and type(x.icon) == "string" and
				x.icon:match("^%x+$") and #x.icon == 64 and x.icon:lower()
		local f = sha and not icon_asked[sha] and io.open(ICON_DIR .. sha .. ".png", "rb")
		if f then
			f:close()
		elseif sha and not icon_asked[sha] then
			icon_asked[sha] = true
			network.http_get(url .. "/api/icon/" .. sha, function(body)
				local got = body and __buildat_keep_server_icon(body)
				if got ~= sha then
					log:warning("Starport " .. url .. ": icon " .. sha ..
							" not kept (" .. tostring(got) .. ")")
				end
			end, {description = "Starport (server icon)"})
		end
	end
end

-- The merged rows of the lists kept from the last fetch, the filters'
-- way, without asking anything: the lobby's floor, built in one frame
function M.safe.kept_rows()
	local e = effective()
	local kept = read_json(LIST_CACHE) or {}
	local ordered = {}
	for _, url in ipairs(e.starports) do
		local k = kept[url]
		if type(k) == "table" and type(k.servers) == "table" then
			ordered[#ordered + 1] = {url, k.servers}
		end
	end
	local shown = {}
	for _, row in ipairs(merge(ordered)) do
		if passes(e.filters, row) then
			shown[#shown + 1] = {name = row.name, address = row.address,
				icon = type(row.icon) == "string" and row.icon:lower() or nil,
				players = row.players, tls = row.tls == true}
		end
	end
	return shown
end

-- fetch(cb[, ask]): cb(rows, info) once every Starport has answered or
-- failed; rows the merged list the filters let through, info {hidden = n,
-- unasked = n, errors = {"url: why", ...}}. Without `ask`, a Starport
-- whose host the user has not accepted yet is left out rather than put
-- in front of them as a permission dialog (as extensions/serverlist does)
function M.safe.fetch(cb, ask, extra)
	local e = effective()
	-- The settings' Starports, and any the caller adds (a report asks the
	-- Starports the player's IDs come from too)
	local starports, have = {}, {}
	for _, url in ipairs(e.starports) do
		starports[#starports + 1] = url
		have[url] = true
	end
	for _, url in ipairs(extra or {}) do
		if not have[url] then
			starports[#starports + 1] = url
			have[url] = true
		end
	end
	local urls, unasked = {}, 0
	for _, url in ipairs(starports) do
		if ask or accepted(url) then
			urls[#urls + 1] = url
		else
			unasked = unasked + 1
		end
	end
	local results, errors, waiting = {}, {}, #urls
	local kept = read_json(LIST_CACHE) or {}
	-- The oldest kept list shown, in seconds; 0 when all are fresh
	local stale = 0
	local function use_kept(url)
		local k = kept[url]
		if type(k) == "table" and type(k.servers) == "table" then
			results[url] = k.servers
			stale = math.max(stale, os.time() - (tonumber(k.ts) or 0))
		end
	end
	-- One not asked yet shows what it said last time
	for _, url in ipairs(starports) do
		if not (ask or accepted(url)) then
			use_kept(url)
		end
	end
	if waiting == 0 then
		local ordered = {}
		for _, url in ipairs(starports) do
			if results[url] then
				ordered[#ordered + 1] = {url, results[url]}
			end
		end
		last_rows = merge(ordered)
		local shown, hidden = {}, 0
		for _, row in ipairs(last_rows) do
			if passes(e.filters, row) then
				local copy = {}
				for k, v in pairs(row) do
					copy[k] = v
				end
				shown[#shown + 1] = copy
			else
				hidden = hidden + 1
			end
		end
		cb(shown, {hidden = hidden, unasked = unasked, stale = stale,
				errors = #starports == 0 and
				{"No Starports in the settings"} or {}})
		return
	end
	local function done()
		waiting = waiting - 1
		if waiting > 0 then
			return
		end
		-- In the settings' order, whichever answered first
		local ordered = {}
		for _, url in ipairs(starports) do
			if results[url] then
				ordered[#ordered + 1] = {url, results[url]}
			end
		end
		write_json_file(LIST_CACHE, kept)
		last_rows = merge(ordered)
		local shown, hidden = {}, 0
		for _, row in ipairs(last_rows) do
			if passes(e.filters, row) then
				local copy = {}
				for k, v in pairs(row) do
					copy[k] = v
				end
				shown[#shown + 1] = copy
			else
				hidden = hidden + 1
			end
		end
		cb(shown, {hidden = hidden, unasked = unasked, stale = stale,
				errors = errors})
		poll_receipts()
	end
	for _, url in ipairs(urls) do
		local function got(body, err)
			local v = body and network.parse_json(body)
			if type(v) == "table" and v.ok and type(v.servers) == "table" then
				note_recommends(url, v.recommends)
				note_version(url, v.version)
				results[url] = v.servers
				kept[url] = {ts = os.time(), servers = v.servers}
				fetch_icons(url, v.servers)
			else
				errors[#errors + 1] = url .. ": " .. tostring(
						type(v) == "table" and v.error or err or "no answer")
				use_kept(url)
			end
			done()
		end
		local options = {description = "Starport (server list)"}
		if e.send_key then
			network.http_post(url .. "/api/list", network.write_json(
					{key = key_for(url)}), got, options)
		else
			network.http_get(url .. "/api/list", got, options)
		end
	end
end

-- Whether a server may be connected to by a typed address
function M.safe.direct_connect_allowed()
	return effective().direct_connect
end

--
-- Dialogs: this side's own, so only the player fills them in
--

-- **A dialog a script added to is closed** ([TRUST_COLOR]): the trust
-- colour tells a look-alike window from this side's own, but a script can
-- reach this side's own through the UI stack and put a field of its own
-- beside a coloured one. Each dialog is taken down to its shape -- types,
-- names, children, every element's opacity and visibility but the root's,
-- which the stack hides under a newer screen -- and compared every frame;
-- what this file adds or shows re-seals it (reseal()), and any other
-- change closes the dialog. No text and no size: a status line changes
-- both, and the window centres itself again. A field's insides are its
-- own (the cursor blinks), and so is what a dropdown shows of its insides
-- (its texts come and go with the choice, the arrows' included).
local guards = {} -- {root = wrapper, raw = unsafe, seen = picture}
local function raw_of(w)
	local m = getmetatable(w)
	return m and m.unsafe
end
local function shape(e, depth, out, in_drop)
	local t = e:GetTypeName()
	out[#out + 1] = table.concat({depth, t, e:GetName(),
			e:GetNumChildren(false), string.format("%.3f", e:GetOpacity()),
			depth > 0 and not in_drop and tostring(e:IsVisible()) or ""}, "|")
	if t == "LineEdit" then
		return
	end
	for i = 0, e:GetNumChildren(false) - 1 do
		shape(e:GetChild(i), depth + 1, out, in_drop or t == "DropDownList")
	end
end
-- Whether a window open_window() gave is still open
local function is_open(root)
	local m = getmetatable(root)
	return m ~= nil and not m.dead
end
local function picture(g)
	if not is_open(g.root) then
		return nil
	end
	local out = {}
	shape(g.raw, 0, out)
	return table.concat(out, "\n")
end
-- After this file changed a dialog: the dialog `w` is in, as it is now
local function reseal(w)
	local e = raw_of(w)
	for _ = 1, 64 do
		if e == nil then
			return
		end
		for _, g in ipairs(guards) do
			if g.raw == e then
				g.seen = picture(g)
				return
			end
		end
		e = e:GetParent()
	end
end
local web_wait = nil -- web_authorize's, for the Starport window's message
magic.SubscribeToEvent("Update", function()
	if web_wait then
		local m = __buildat_web_authorized()
		if m then
			local f = web_wait
			web_wait = nil
			f(m)
		end
	end
	local i = 1
	while i <= #guards do
		local g = guards[i]
		local now = picture(g)
		if now == nil then
			table.remove(guards, i) -- closed
		elseif now ~= g.seen then
			table.remove(guards, i)
			log:warning("A script changed the Starport dialog \""..g.desc..
					"\"; it is closed")
			local st = uistack.main.stack
			for _, e in ipairs(st) do
				if e == g.root then
					uistack.main:pop_to(g.root, true)
					break
				end
			end
		else
			i = i + 1
		end
	end
end)

-- opts.close_glyph = false: no × ([CLOSE_GLYPH]), for a small form with a
-- Close or Cancel beside its action
local glyphed = setmetatable({}, {__mode = "k"}) -- windows with the ×
local function open_window(desc, width, on_escape, opts)
	local root = uistack.main:push({desc = desc})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)
	local w = root:CreateChild("Window")
	w:SetStyleAuto()
	w:SetLayout(magic.LM_VERTICAL, 6, magic.IntRect(12, 12, 12, 12))
	w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	w:SetFixedWidth(math.min(width, magic.ui.root.width - 16))
	-- Over whatever a server draws (its join window is at 100): this
	-- side's dialogs are the ones the player has to be able to trust
	root.priority = 1000
	root:SubscribeToStackEvent("KeyDown", function(_, data)
		if data:GetInt("Key") == magic.KEY_ESCAPE then
			uistack.main:pop(root)
			if on_escape then
				on_escape()
			end
			return true
		end
	end)
	-- By the keyboard ([MENU_KEYS])
	require("buildat/extension/ui_utils").safe.keyboard_page(w)
	if not (opts and opts.close_glyph == false) then
		require("buildat/extension/ui_utils").safe.close_glyph(root, w)
		glyphed[raw_of(w)] = true
	end
	local g = {root = root, raw = raw_of(root), desc = desc}
	guards[#guards + 1] = g
	g.seen = picture(g)
	return root, w
end

local function add_text(parent, text, color)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t:SetWordwrap(true)
	-- A window's text is given its width less its margins (24), and the
	-- first one less the × above its end (40)
	local less = (parent:GetNumChildren(false) == 1 and
			glyphed[raw_of(parent)]) and 64 or 24
	if parent.width > less then
		t:SetFixedWidth(parent.width - less)
	end
	t.text = text
	if color then
		t.color = color
	end
	reseal(t)
	return t
end

-- A label in a row: one line, at least min_width wide
-- A choice of one: ui_utils' dropdown ([UI_DROPDOWN])
local function add_dropdown(parent, choices, current, on_choose, options)
	local d, row = require("buildat/extension/ui_utils").safe.dropdown(
			parent, choices, current, on_choose, options)
	reseal(parent)
	return d, row
end

local function add_label(parent, text, min_width)
	local t = add_text(parent, text)
	t:SetWordwrap(false)
	t.minWidth = min_width or 0
	reseal(t)
	return t
end

local function add_row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	reseal(r)
	return r
end

-- main: the screen's one main button, amber ([MENU_BRAND])
local function add_button(parent, label, on_click, enabled, main)
	local b = parent:CreateChild("Button")
	if main then b:SetStyle("PrimaryButton") else b:SetStyleAuto() end
	b.minHeight = 24
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t.text = label
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = t.width + 16
	if enabled == false then
		t.color = magic.Color(rgb("dim"))
	else
		magic.SubscribeToEvent(b, "Released", function() on_click() end)
	end
	reseal(b)
	return b
end

local function add_edit(parent, value, secret)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 24
	e.minWidth = 200
	e.textSelectable = true
	-- **Every field here is the client's own** ([TRUST_COLOR]): in the
	-- trust colour the launcher shows, which no script can read, so a
	-- look-alike login is told apart by its fields; and no wrapper but
	-- this one reads what is typed into it, and no script hears the keys
	-- while it has the focus (magic_sandbox.is_secret_field) -- not only
	-- the password, or a script would move the name field into a window
	-- of its own labelled "Password"
	e:SetName(secret and "__trusted_secret" or "__trusted_field")
	getmetatable(e).trusted_reader = true
	-- A solid fill of the colour, the style's texture off: multiplied
	-- into its dark texture, the colour came out near black. Not on the
	-- web, whose page is the server's code: it shows no colour to match
	-- (client/extensions/urho3d's is_web)
	if __buildat_get_env("BUILDAT_PAGE_HTTPS") == nil then
		local urho3d = require("buildat/extension/urho3d")
		local r, g, b = urho3d.trust_color()
		getmetatable(e).unsafe:SetTexture(nil)
		e.color = magic.Color(r, g, b, 1)
		-- The trust code at its top right, as in the overlay and the title
		local code = urho3d.trust_code_text(getmetatable(e).unsafe)
		code:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
		code:SetPosition(-3, 1)
	end
	if secret then
		e.echoCharacter = string.byte("*")
	else
		e.textCopyable = true
	end
	e:SetText(value or "")
	reseal(e)
	return e
end

local WARN = magic.Color(rgb("warn"))
local DIM = magic.Color(rgb("dim"))

local settings_page
-- What open_settings() was given: the list filtered again by what changed
local settings_closed
local settings_root = nil

-- The PIN, when one is set, before anything the lock covers is changed
local function ask_pin(on_done)
	local s = load_state()
	if s.pin == "" then
		on_done(true)
		return
	end
	local root, w = open_window("starport pin", 420, nil, {close_glyph = false})
	add_text(w, "These settings are locked with a PIN.")
	local e = add_edit(w, "", true)
	e:SetFocus(true)
	local function go(try)
		local ok = try and pin_hash(e:GetText()) == s.pin
		uistack.main:pop(root)
		on_done(ok)
	end
	magic.SubscribeToEvent(e, "TextFinished", function() go(true) end)
	local r = add_row(w)
	add_button(r, "Unlock", function() go(true) end)
	add_button(r, "View only", function() go(false) end)
end

-- [STARPORT_RECOMMENDS]: an address as a Starport sent it, or nil
local function web_url(u)
	return type(u) == "string" and u:match("^https?://[%w%.%-%[%]:]+/?$") and
			normalize_url(u) or nil
end

-- The Aittas the Starports in the settings recommend that are on neither
-- of this client's lists, as {aitta =, starport =}
local function new_aittas()
	local s, e = load_state(), effective()
	local known = {}
	for _, a in ipairs(e.aittas) do
		known[a] = true
	end
	for _, a in ipairs(s.ignored_aittas) do
		known[normalize_url(a)] = true
	end
	local out = {}
	for _, url in ipairs(e.starports) do
		local r = s.recommends[url]
		for _, a in ipairs(r and r.aittas or {}) do
			if not known[a] then
				known[a] = true
				out[#out + 1] = {aitta = a, starport = url}
			end
		end
	end
	return out
end

-- **The offer**: one dialog, a checkbox for each new Aitta under the
-- Starport recommending it; the ones not added are ignored. Only where
-- the user's word is the list's: not under the PIN or the managed file,
-- and not in a scripted run unless BUILDAT_STARPORT_OFFER=1. Over a game
-- it is not called (the trusted overlay calls it on the launcher's
-- screen).
local offer_root = nil
local refreshed = false
local id_refresh
function M.offer_aittas()
	local s, e = load_state(), effective()
	if offer_root or s.pin ~= "" or e.managed.aittas or
			(__buildat_is_scripted() and
			buildat.get_env("BUILDAT_STARPORT_OFFER") ~= "1") then
		return
	end
	-- At the start, what the logged-in IDs' Starports recommend now; one
	-- whose host was not accepted for good waits for the login or a fetch
	if not refreshed then
		refreshed = true
		for url in pairs(s.ids) do
			if accepted(url, true) then
				id_refresh(url, function() end)
			end
		end
	end
	local new = new_aittas()
	if #new == 0 then
		return
	end
	local checked = {}
	local function close(add, popped)
		if not popped then
			uistack.main:pop(offer_root)
		end
		offer_root = nil
		for i, x in ipairs(new) do
			if add and checked[i] then
				add_aitta(x.aitta)
			else
				table.insert(s.ignored_aittas, x.aitta)
			end
		end
		save_state()
		log:info("Aittas offered: " .. #new .. ", " ..
				(add and "added the checked" or "not now"))
	end
	local root, w = open_window("starport aittas", 620, function()
		close(false, true)
	end)
	offer_root = root
	log:info("Offering " .. #new .. " Aitta(s)")
	add_text(w, "Aittas are where people share apps: unreviewed, each " ..
			"run in the server's sandbox. Not added, an Aitta is not offered " ..
			"again; the Starport settings can add it later.", DIM)
	local last = nil
	for i, x in ipairs(new) do
		if x.starport ~= last then
			last = x.starport
			add_text(w, "Starport " .. x.starport .. " recommends:")
		end
		checked[i] = true
		local b
		b = add_button(w, "[x] " .. x.aitta, function()
			checked[i] = not checked[i]
			b:GetChild(0).text = (checked[i] and "[x] " or "[ ] ") .. x.aitta
		end)
	end
	local r = add_row(w)
	add_button(r, "Add", function() close(true) end, nil, true)
	add_button(r, "Not now", function() close(false) end)
end

-- **A newer client** ([VERSION_CHECK]): what the Starports' version
-- adapters say, the newest kept for this run, {version, url, starport};
-- the version the user said "Not now" to is in the state
local newer = nil

-- Version strings compared by their numbers: -1, 0 or 1
local function version_cmp(a, b)
	local pa, pb = {}, {}
	for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
	for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then
			return x < y and -1 or 1
		end
	end
	return 0
end
assert(version_cmp("0.6.10", "0.6.9") == 1 and version_cmp("0.6", "0.6.0") == 0
		and version_cmp("0.6.89", "1.0.0") == -1)

note_version = function(url, v)
	if type(v) ~= "table" or type(v.version) ~= "string" or
			not v.version:match("^%d[%d%.]*$") or
			version_cmp(v.version, buildat.version()) <= 0 or
			(newer and version_cmp(v.version, newer.version) <= 0) then
		return
	end
	-- This platform's link when the adapter gave one
	local platforms = type(v.platforms) == "table" and v.platforms or {}
	local p = platforms[({Windows = "win64", Linux = "linux"})[GetPlatform()]
			or ""]
	local link = type(p) == "table" and p.url or v.url
	newer = {version = v.version, url = tostring(link), starport = url}
end

-- The notice, on the launcher's screen (the trusted overlay calls it as it
-- does offer_aittas): never on the web, whose version is its server's, nor
-- in a scripted run unless BUILDAT_STARPORT_OFFER=1
local version_root = nil
local version_shown = nil
function M.offer_version()
	local s = load_state()
	if not newer or version_root or version_shown == newer.version or
			s.version_not_now == newer.version or GetPlatform() == "Web" or
			(__buildat_is_scripted() and
			buildat.get_env("BUILDAT_STARPORT_OFFER") ~= "1") then
		return
	end
	local n = newer
	version_shown = n.version
	local function close(not_now, popped)
		if not popped then
			uistack.main:pop(version_root)
		end
		version_root = nil
		if not_now then
			s.version_not_now = n.version
			save_state()
		end
	end
	local root, w = open_window("starport version", 620, function()
		close(false, true)
	end)
	version_root = root
	log:info("Offering version " .. n.version .. " (" .. n.url .. ", from " ..
			n.starport .. ")")
	add_text(w, "Buildat " .. n.version .. " is out; this is " ..
			tostring(buildat.version()) .. ".")
	add_text(w, n.url, DIM)
	local r = add_row(w)
	local failed = nil
	add_button(r, "Download", function()
		local ok, err = __buildat_open_url(n.url)
		log:info("Version link: " .. (ok and "opened" or tostring(err)))
		if ok then
			-- [VERSION_DOWNLOAD] What to do next, and the client out of
			-- the installer's way (Windows cannot replace a running .exe)
			r.visible = false
			local file = n.url:match("([^/?#]+)[^/]*$") or n.url
			local next_ = file:match("%.exe$") and
					"Let the download finish in your browser. Then close " ..
					"Buildat and run " .. file .. ": it updates this " ..
					"installation and keeps your saves and settings." or
					"Let the download finish in your browser. Then close " ..
					"Buildat, extract " .. file .. " and run bin/buildat " ..
					"from it. Your saves and settings are kept: they are in " ..
					__buildat_get_path("user") .. ", not in the folder you " ..
					"extract."
			log:info("Version next: " .. next_)
			add_text(w, next_, WARN)
			add_button(add_row(w), "Close Buildat", function()
				log:info("Version: closing for the update")
				__buildat_disconnect()
			end, true, true)
		elseif not failed then
			-- The window stays, the link on it to copy by hand
			failed = add_text(w, "Could not open it: " .. tostring(err), WARN)
		end
	end, n.url:match("^https://") ~= nil, true)
	add_button(r, "Not now", function() close(true) end)
end

note_recommends = function(url, r)
	if type(r) ~= "table" then
		return
	end
	local aittas = {}
	for _, a in ipairs(type(r.aittas) == "table" and r.aittas or {}) do
		aittas[#aittas + 1] = web_url(a)
	end
	-- The Hearth as given: its address is made as a home Hearth's
	-- (client/launch_grid.lua hearth_target)
	local hearth = type(r.hearth) == "string" and
			r.hearth:match("^https?://[%w%.%-%[%]:]+/?$") or nil
	load_state().recommends[url] = {hearth = hearth,
		aittas = aittas}
	save_state()
end

-- The Hearth a Starport recommends, as a URL, or nil
function M.recommended_hearth(url)
	local r = load_state().recommends[url]
	return r and r.hearth
end

-- **Discuss signs in with the ID** (user, 2026-10-07): the join it makes
-- is marked, and the server's login (builtin/accounts) takes the mark
-- once and asks id_token_here before showing its dialog
local id_join = nil
function M.join_with_id(address)
	id_join = canonical(address)
	buildat.safe.join_server(address)
end
function M.safe.take_id_join()
	local here = __buildat_server_address()
	local yes = here ~= nil and id_join == canonical(here)
	id_join = nil
	return yes
end
-- [STARPORT_LOGIN_FOCUS]: whether an ID is signed in on any Starport,
-- for the login dialog to make its button the default. One bit, and it
-- tells the server's code that much: not which Starport, nor the name
function M.safe.has_id()
	return next(load_state().ids or {}) ~= nil
end

-- **Where the ID signed in last** ([ID_AUTO_JOIN]): a server's canonical
-- address, marked when id_token_here gave a token for it, so the next join
-- there signs in with the ID again (builtin/accounts asks). Here on the
-- trusted side and not in the server's own storage, which its code writes:
-- a server cannot mark itself. id_used_here() is one bit for the server the
-- client is on; forget_id_here() drops the mark (a password login there,
-- Log out). A token is asked for each time, never kept for this.
-- simplified: not on the web, where the Starport's window is a popup a
-- browser lets open only from a press; the dialog's button stays the way
local function here_address()
	local a = __buildat_server_address()
	return a and canonical(a)
end
function M.safe.id_used_here()
	local a = here_address()
	return a ~= nil and __buildat_get_env("BUILDAT_PAGE_HTTPS") == nil and
			(load_state().id_used or {})[a] == true
end
function M.safe.forget_id_here()
	local a, s = here_address(), load_state()
	if a and s.id_used and s.id_used[a] then
		s.id_used[a] = nil
		save_state()
		log:info("starport: the ID is not used on " .. a .. " any more")
	end
end

-- A package's home Hearth when its manifest names none: the Hearth of the
-- Starport recommending the Aitta it is from, or with no Aitta given,
-- the first Starport in the settings that recommends one.
-- simplified: an installed package does not know its Aitta, so it gets
-- the first; keep the Aitta at install for the right one
function M.safe.fallback_hearth(aitta)
	local s = load_state()
	for _, url in ipairs(effective().starports) do
		local r = s.recommends[url]
		if r and r.hearth then
			local has = aitta == nil
			for _, a in ipairs(r.aittas) do
				has = has or a == aitta
			end
			if has then
				return r.hearth
			end
		end
	end
end

-- `hides`: the set says what is hidden, and [x] is still what is shown, as
-- in the rows above it (user, 2026-10-02: all of them ticked hid them all)
local function toggle_row(w, label, set, values, can, hides)
	local r = add_row(w)
	add_label(r, label, 90)
	for _, v in ipairs(values) do
		local name, shown = v, v
		if type(v) == "table" then
			name, shown = v[1], v[2]
		end
		local on = (set[name] and true or false) ~= (hides or false)
		add_button(r, (on and "[x] " or "[ ] ") .. shown, function()
			set[name] = not set[name]
			save_state()
			settings_page(can, true)
		end, can)
	end
end

-- can: the PIN was given (or there is none); `again`: redrawn in place
settings_page = function(can, again, message)
	if again and settings_root then
		uistack.main:pop(settings_root)
	end
	local s, e = load_state(), effective()
	local root, w = open_window("starport settings", 900, function()
		if settings_closed then
			settings_closed()
		end
	end)
	settings_root = root
	add_text(w, "Starport: the lists of public servers")
	if message then
		add_text(w, message, WARN)
	end
	if e.managed.starports or e.managed.filters or e.managed.direct_connect or
			e.managed.aittas then
		add_text(w, "Some of these are set by " .. managed_path() ..
				" and cannot be changed here.", DIM)
	end
	local lock_starports = can and not e.managed.starports
	for i, url in ipairs(e.starports) do
		local r = add_row(w)
		add_label(r, url, 360)
		-- [STARPORT] 10: this Starport's ID, or the way to one
		local id = s.ids[url]
		add_button(r, id and "ID: " .. tostring(id.name) .. "..." or
				"Starport ID...", function()
			if id then
				M.id_page(url)
			else
				M.id_login(url)
			end
		end)
		add_button(r, "Remove", function()
			table.remove(s.starports, i)
			save_state()
			settings_page(can, true)
		end, lock_starports)
	end
	local r = add_row(w)
	local new = add_edit(r, "https://")
	add_button(r, "Add Starport", function()
		local url = normalize_url(new:GetText())
		if not url:match("^https?://[%w%.%-]+[:%d]*$") then
			return settings_page(can, true, "A Starport is a host name, or "..
					"an http(s):// address")
		end
		table.insert(s.starports, url)
		save_state()
		settings_page(can, true)
	end, lock_starports)

	add_text(w, "Show servers:")
	local fc = can and not e.managed.filters
	local f = e.filters
	toggle_row(w, "Audience", f.audience, AUDIENCES, fc)
	toggle_row(w, "Kind", f.kind, KINDS, fc)
	toggle_row(w, "Access", f.access, ACCESSES, fc)
	local hides = {}
	for _, d in ipairs(DESCRIPTORS) do
		hides[#hides + 1] = {d[1], d[2]}
	end
	toggle_row(w, "With", f.hide, {hides[1], hides[2], hides[3]}, fc, true)
	toggle_row(w, "", f.hide, {hides[4], hides[5], hides[6]}, fc, true)
	toggle_row(w, "", f.hide, {hides[7], hides[8], hides[9]}, fc, true)
	r = add_row(w)
	add_label(r, "Languages (en, fi; empty: all)", 240)
	local langs = add_edit(r, f.languages)
	add_button(r, "Set", function()
		f.languages = langs:GetText()
		save_state()
		settings_page(can, true)
	end, fc)
	add_button(w, "Connecting by a typed address: " ..
			(e.direct_connect and "allowed" or "not allowed"), function()
		s.direct_connect = not s.direct_connect
		save_state()
		settings_page(can, true)
	end, can and not e.managed.direct_connect)
	-- [AITTA_MVP]
	add_button(w, "Apps from Aitta (unreviewed): " ..
			(f.unreviewed and "shown" or "hidden"), function()
		f.unreviewed = not f.unreviewed
		save_state()
		settings_page(can, true)
	end, fc)
	-- [STARPORT_RECOMMENDS]: removed is ignored, not offered again
	local ac = can and not e.managed.aittas
	for i, url in ipairs(e.aittas) do
		r = add_row(w)
		add_label(r, "Aitta: " .. url, 360)
		add_button(r, "Remove", function()
			table.remove(s.aittas, i)
			table.insert(s.ignored_aittas, url)
			save_state()
			settings_page(can, true)
		end, ac)
	end
	r = add_row(w)
	local new_aitta = add_edit(r, "https://")
	add_button(r, "Add Aitta", function()
		local url = normalize_url(new_aitta:GetText())
		if not url:match("^https?://[%w%.%-]+[:%d]*$") then
			return settings_page(can, true, "An Aitta is a host name, or "..
					"an http(s):// address")
		end
		add_aitta(url)
		save_state()
		settings_page(can, true)
	end, ac)
	for i, url in ipairs(s.ignored_aittas) do
		r = add_row(w)
		add_label(r, "Ignored Aitta: " .. url, 360)
		add_button(r, "Take back", function()
			table.remove(s.ignored_aittas, i)
			save_state()
			settings_page(can, true)
		end, ac)
	end

	-- 2b: a pool's server in the same region goes first
	r = add_row(w)
	add_label(r, "My region (e.g. eu)", 240)
	local region = add_edit(r, s.region or "")
	add_button(r, "Set", function()
		s.region = region:GetText()
		save_state()
		settings_page(can, true)
	end)
	-- 5b
	add_button(w, "Send my Starport key: " .. (s.send_key and "on" or "off"),
			function()
		s.send_key = not s.send_key
		save_state()
		settings_page(can, true)
	end)
	add_text(w, (s.send_key and
			"Your key builds the standing your reports are weighed by, and "..
			"brings you their outcomes." or
			"Off: your key is not sent, so Starports keep nothing new of "..
			"your use; your reports weigh as a new key's and get no "..
			"outcomes. The key is kept: turned on again, it is sent with "..
			"its standing as it was."), DIM)
	if not s.send_key then
		add_text(w, "The keys are in " .. STATE_PATH .. " (\"keys\"). "..
				"Deleting them there starts over with new ones.", DIM)
	end
	-- 5c
	r = add_row(w)
	add_button(r, "Export keys", function()
		write_json_file(EXPORT_PATH, {what = "Buildat Starport keys. "..
			"Whoever has this file reports as you.", keys = s.keys})
		settings_page(can, true, "Saved to " .. EXPORT_PATH)
	end)
	add_button(r, "Import keys", function()
		local v = read_json(EXPORT_PATH)
		if not v or type(v.keys) ~= "table" then
			return settings_page(can, true, "Nothing to import at " ..
					EXPORT_PATH)
		end
		local n = 0
		for url, k in pairs(v.keys) do
			if type(k) == "string" and k:match("^%x+$") and #k == 64 then
				s.keys[url] = k:lower()
				n = n + 1
			end
		end
		save_state()
		settings_page(can, true, n .. " key(s) imported from " .. EXPORT_PATH)
	end)

	-- The lock
	r = add_row(w)
	add_label(r, s.pin ~= "" and "PIN: set" or "PIN: none", 90)
	local pin = add_edit(r, "", true)
	add_button(r, s.pin ~= "" and "Change PIN" or "Set PIN", function()
		local p = pin:GetText()
		if #p < 4 then
			return settings_page(can, true, "A PIN of at least 4 characters")
		end
		s.pin = pin_hash(p)
		save_state()
		settings_page(can, true, "PIN set")
	end, can)
	add_button(r, "Remove PIN", function()
		s.pin = ""
		save_state()
		settings_page(can, true)
	end, can and s.pin ~= "")
	add_text(w, "The lock covers this client only: not someone with the "..
			"computer's administrator rights.", DIM)

	if #s.receipts > 0 then
		add_text(w, "Your reports:")
		for i = #s.receipts, math.max(1, #s.receipts - 4), -1 do
			local x = s.receipts[i]
			add_text(w, x.name .. ": " .. x.reason .. ": " ..
					(x.outcome and x.outcome ~= "" and x.outcome or
					x.state or "sent"), DIM)
		end
	end
end

--
-- **Starport ID** ([STARPORT] 10): logging in, registering and the account,
-- over the Starport's HTTPS API (POST /api/id/<call>). The password goes to
-- the Starport only; a server gets a token for itself (id_token_here).
--

-- cb(result) or cb(nil, why, unreachable): unreachable when the Starport
-- did not answer at all
local function id_call(url, what, body, cb)
	network.http_post(url .. "/api/id/" .. what, network.write_json(body),
			function(answer, err)
		local v = answer and network.parse_json(answer)
		if type(v) ~= "table" then
			cb(nil, tostring(err or "no answer"), true)
		elseif not v.ok then
			-- A session that ended is forgotten here too
			if v.error == "session" then
				load_state().ids[url] = nil
				save_state()
			end
			cb(nil, tostring(v.error))
		else
			cb(v.result)
		end
	end, {description = "Starport"})
end

-- What is kept of a logged-in ID: enough to log in to servers and to cap
-- the filters, nothing a server should see
-- **Tokens kept for when the Starport is away** (10c): sealed with the
-- Starport password (Mbed TLS: PBKDF2 and AES-GCM), which this client
-- holds in memory only, for the run it was typed in
local id_passwords = {}

local function unhex(h)
	return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end))
end

local function keep_token(url, address, token, exp)
	local pw = id_passwords[url]
	if not pw then
		return
	end
	local s = load_state()
	s.sealed = s.sealed or {}
	s.sealed[url] = s.sealed[url] or {}
	s.sealed[url][address] = hex(__buildat_seal(pw, network.write_json(
			{token = token, exp = exp})))
	save_state()
end

local function keep_id(url, session, me)
	local s = load_state()
	s.ids[url] = {session = session, name = me.name, band = me.band,
		key = me.key}
	save_state()
	note_recommends(url, me.recommends)
end

-- [ID_LINE]: the IDs logged in, for the launcher's trusted overlay
-- (client/extensions/urho3d), as {url =, name =}; and logging one out
-- from there, as the ID page's Log out does. On M and never in M.safe.
function M.logged_in_ids()
	local out = {}
	for url, id in pairs(load_state().ids or {}) do
		out[#out + 1] = {url = url, name = tostring(id.name)}
	end
	table.sort(out, function(a, b) return a.url < b.url end)
	return out
end

-- [ID_OVERLAY]: the Starports this client uses, for the overlay's
-- "Starport ID..." (one: its login; more: the settings, which list them)
function M.starport_urls()
	return effective().starports
end

function M.log_out(url)
	local id = load_state().ids[url]
	if not id then
		return
	end
	id_call(url, "logout", {session = id.session}, function() end)
	load_state().ids[url] = nil
	save_state()
	log:info("Logged out of the Starport ID at " .. url)
end

id_refresh = function(url, cb)
	local id = load_state().ids[url]
	if not id then
		return cb(nil, "not logged in")
	end
	id_call(url, "me", {session = id.session}, function(me, err)
		if me then
			keep_id(url, id.session, me)
		end
		cb(me, err)
	end)
end

local function close_and(root, f)
	return function()
		uistack.main:pop(root)
		if f then
			f()
		end
	end
end

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
	reseal(b)
	return b
end

-- id_login(url[, then_cb]): the login dialog; then_cb() once logged in
-- [WEB_ID_TRUST]: on the web an ID is logged in to and changed on the
-- Starport's own page (/id), in a window of its own: a password typed into
-- this page would be typed into code the game server sent
local function is_web()
	return __buildat_get_env("BUILDAT_PAGE_HTTPS") ~= nil
end
local function web_id_page(url)
	local root, w = open_window("starport id web page", 520, nil, {close_glyph = false})
	add_text(w, "Your Starport ID at " .. url .. " is on the Starport's own "..
			"page, which opens in a window of its own.")
	local st = add_text(w, "")
	local rr = add_row(w)
	add_button(rr, "Open", function()
		st.text = __buildat_web_authorize(url .. "/id") and "Opened" or
				"The browser blocked the window: allow pop-ups for this page"
	end)
	add_button(rr, "Close", close_and(root))
end

function M.id_login(url, then_cb, message)
	if is_web() then
		return web_id_page(url)
	end
	local root, w = open_window("starport id login", 520, nil, {close_glyph = false})
	add_text(w, "Starport ID at " .. url)
	if message then
		add_text(w, message, WARN)
	end
	local r = add_row(w)
	add_label(r, "Name", 120)
	local name = add_edit(r, "")
	r = add_row(w)
	add_label(r, "Password", 120)
	local password = add_edit(r, "", true)
	local totp_row = add_row(w)
	add_label(totp_row, "TOTP code (if on)", 120)
	local totp = add_edit(totp_row, "")
	local status = add_text(w, "")
	local function go()
		status.text = "Logging in..."
		id_call(url, "login", {name = name:GetText(),
			password = password:GetText(), totp = totp:GetText()},
				function(res, err)
			if not res then
				status.text = err == "totp" and
						"Enter the code from your authenticator app" or err
				return
			end
			keep_id(url, res.session, res.me)
			id_passwords[url] = password:GetText()
			uistack.main:pop(root)
			local remind = "This ID has no recovery e-mail: a forgotten "..
					"password is the end of it."
			if res.remind_email and then_cb then
				-- Said, and what the login was for goes on
				local root2, w2 = open_window("starport id remind", 520, nil, {close_glyph = false})
				add_text(w2, remind, WARN)
				local rr = add_row(w2)
				add_button(rr, "Add one...", close_and(root2, function()
					M.id_page(url)
				end))
				add_button(rr, "Later", close_and(root2, then_cb))
			elseif res.remind_email then
				M.id_page(url, remind .. " You can add one here.")
			elseif then_cb then
				then_cb()
			end
		end)
	end
	magic.SubscribeToEvent(password, "TextFinished", go)
	magic.SubscribeToEvent(totp, "TextFinished", go)
	r = add_row(w)
	add_button(r, "Log in", go, nil, true)
	add_button(r, "Make an ID...", function()
		uistack.main:pop(root)
		M.id_register(url, then_cb)
	end)
	add_button(r, "Forgot password...", function()
		uistack.main:pop(root)
		M.id_reset(url, name:GetText())
	end)
	add_button(r, "Close", close_and(root))
	name:SetFocus(true)
end

function M.id_reset(url, name_text)
	local root, w = open_window("starport id reset", 520, nil, {close_glyph = false})
	add_text(w, "A new password: a code goes to the ID's recovery e-mail.")
	local r = add_row(w)
	add_label(r, "Name", 120)
	local name = add_edit(r, name_text or "")
	local status = add_text(w, "")
	add_button(w, "Send the code", function()
		id_call(url, "reset_request", {name = name:GetText()},
				function(res, err)
			status.text = res or err
		end)
	end)
	r = add_row(w)
	add_label(r, "Code", 120)
	local code = add_edit(r, "")
	r = add_row(w)
	add_label(r, "New password", 120)
	local pw = add_edit(r, "", true)
	r = add_row(w)
	add_button(r, "Set the password", function()
		id_call(url, "reset", {name = name:GetText(), code = code:GetText(),
			password = pw:GetText()}, function(res, err)
			if res then
				uistack.main:pop(root)
				M.id_login(url, nil, "Password set: log in with it")
			else
				status.text = err
			end
		end)
	end)
	add_button(r, "Close", close_and(root))
end

-- The age, as 10b has it: "18 or over" and nothing more, or a birth year
-- and, under 13, a parent's consent. Under the lock (4): a PIN set, the
-- PIN first
local function age_rows(w)
	local age = {adult = nil, year = "", consent = false}
	local r = add_row(w)
	add_label(r, "Are you 18 or over?", 200)
	local yes, no
	local year_row, kept, consent_b
	local function draw()
		yes:GetChild(0).text = (age.adult == true and "[x]" or "[ ]") .. " Yes"
		no:GetChild(0).text = (age.adult == false and "[x]" or "[ ]") .. " No"
		year_row.visible = age.adult == false
		kept.visible = age.adult == false
		consent_b.visible = age.adult == false
		reseal(year_row)
		consent_b:GetChild(0).text = (age.consent and "[x]" or "[ ]") ..
				" Under 13: I have a parent's consent"
	end
	yes = add_button(r, "Yes", function() age.adult = true draw() end)
	no = add_button(r, "No", function() age.adult = false draw() end)
	year_row = add_row(w)
	add_label(year_row, "Your birth year", 200)
	local year = add_edit(year_row, "")
	-- The same words as the ID's web page ([SP_AGE_FORM])
	kept = add_text(w, "Kept only until you turn 18.", DIM)
	consent_b = add_button(w, "", function()
		age.consent = not age.consent
		draw()
	end)
	draw()
	return function()
		if age.adult == nil then
			return nil, "Say whether you are 18 or over"
		end
		if age.adult then
			return {adult = true}
		end
		local y = tonumber(year:GetText())
		if not y then
			return nil, "The year you were born"
		end
		return {adult = false, birth_year = y, consent = age.consent}
	end
end

function M.id_register(url, then_cb)
	ask_pin(function(can)
		if not can then
			return
		end
		local root, w = open_window("starport id register", 640, nil, {close_glyph = false})
		add_text(w, "A Starport ID at " .. url)
		-- 10a: what it holds, said where it is made
		add_text(w, "It holds: a name, a password (as a hash), a recovery "..
				"e-mail if you give one, \"18 or over\" or a birth year under "..
				"that, a parent's consent under 13, how many times you have "..
				"logged in, your report key, and a separate identity for "..
				"each community you join. That is all, on purpose: it is "..
				"made for privacy, and nothing more is asked or kept than "..
				"logging in, the age limits and moderation need.", DIM)
		local r = add_row(w)
		add_label(r, "Name", 200)
		local name = add_edit(r, "")
		r = add_row(w)
		add_label(r, "Password", 200)
		local pw = add_edit(r, "", true)
		r = add_row(w)
		add_label(r, "Password again", 200)
		local pw2 = add_edit(r, "", true)
		r = add_row(w)
		add_label(r, "Recovery e-mail (optional)", 200)
		local email = add_edit(r, "")
		add_text(w, "Without one, a forgotten password is the end of the ID "..
				"and its standing. You can add it later.", DIM)
		local get_age = age_rows(w)
		local status = add_text(w, "")
		r = add_row(w)
		add_button(r, "Make the ID", function()
			if pw:GetText() ~= pw2:GetText() then
				status.text = "The passwords differ"
				return
			end
			local a, why = get_age()
			if not a then
				status.text = why
				return
			end
			local body = {name = name:GetText(), password = pw:GetText(),
				email = email:GetText(), adult = a.adult,
				birth_year = a.birth_year, consent = a.consent,
				-- The key this client has used there: its standing comes
				key = load_state().keys[url]}
			status.text = "Making it..."
			id_call(url, "register", body, function(res, err)
				if not res then
					status.text = err
					return
				end
				keep_id(url, res.session, res.me)
				id_passwords[url] = pw:GetText()
				uistack.main:pop(root)
				if then_cb then
					then_cb()
				else
					M.id_page(url, res.email_error)
				end
			end)
		end)
		add_button(r, "Close", close_and(root))
	end)
end

-- The ID's own page: e-mail, TOTP, password, age, log out, delete
function M.id_page(url, message)
	if is_web() then
		return web_id_page(url)
	end
	id_refresh(url, function(me, err)
		local root, w = open_window("starport id", 680)
		if not me then
			add_text(w, "Starport ID at " .. url .. ": " .. tostring(err))
			add_button(w, "Log in...", function()
				uistack.main:pop(root)
				M.id_login(url)
			end)
			add_button(w, "Close", close_and(root))
			return
		end
		local function again(text)
			uistack.main:pop(root)
			M.id_page(url, text)
		end
		local session = load_state().ids[url].session
		add_text(w, "Starport ID " .. me.name .. " at " .. url .. " (age " ..
				me.band .. ", " .. me.logins .. " logins)")
		if message and message ~= "" then
			add_text(w, message, WARN)
		end
		for _, st in ipairs(me.statements or {}) do
			add_text(w, tostring(st.action) .. " for " .. tostring(st.reason) ..
					": " .. tostring(st.text), WARN)
		end
		-- With TOTP on, the e-mail's and the password's changes take a code
		-- from its row too ([WEB_ID_TRUST] (b))
		local code
		local function totp()
			return me.totp and code:GetText() or nil
		end
		-- The e-mail
		local r = add_row(w)
		add_label(r, "Recovery e-mail", 160)
		local email = add_edit(r, me.email_pending ~= "" and me.email_pending
				or me.email)
		add_button(r, "Set", function()
			id_call(url, "email", {session = session, email = email:GetText(),
				totp = totp()}, function(res, e2)
				again(res == "sent" and "A code went to the address" or
						res and "Set" or e2)
			end)
		end)
		if me.email_pending ~= "" then
			r = add_row(w)
			add_label(r, "Code from the mail", 160)
			local code = add_edit(r, "")
			add_button(r, "Confirm", function()
				id_call(url, "confirm_email", {session = session,
					code = code:GetText()}, function(res, e2)
					again(res and "Confirmed" or e2)
				end)
			end)
		end
		-- TOTP
		r = add_row(w)
		add_label(r, me.totp and "TOTP: on, code" or "TOTP: off", 160)
		code = add_edit(r, "")
		if me.totp then
			add_button(r, "Turn off (code)", function()
				id_call(url, "totp", {session = session, cmd = "off",
					code = code:GetText()}, function(res, e2)
					again(res and "TOTP is off" or e2)
				end)
			end)
		else
			add_button(r, "Turn on...", function()
				id_call(url, "totp", {session = session, cmd = "begin"},
						function(res, e2)
					if not res then
						return again(e2)
					end
					uistack.main:pop(root)
					local root2, w2 = open_window("starport id totp", 620, nil, {close_glyph = false})
					add_text(w2, "Add this key to an authenticator app, then "..
							"enter the code it shows:")
					local k = add_edit(w2, res.secret)
					k.minWidth = 400
					qr_image(w2, res.uri)
					local c = add_edit(w2, "")
					local rr = add_row(w2)
					add_button(rr, "Turn on", function()
						id_call(url, "totp", {session = session,
							cmd = "confirm", code = c:GetText()},
								function(res2, e3)
							uistack.main:pop(root2)
							M.id_page(url, res2 and "TOTP is on" or e3)
						end)
					end)
					add_button(rr, "Close", close_and(root2))
				end)
			end)
		end
		-- The password
		r = add_row(w)
		add_label(r, "Password: old, new", 160)
		local old = add_edit(r, "", true)
		local new = add_edit(r, "", true)
		add_button(r, "Change", function()
			id_call(url, "password", {session = session, old = old:GetText(),
				new = new:GetText(), totp = totp()}, function(res, e2)
				again(res and "Password changed" or e2)
			end)
		end)
		-- The age, under the lock
		add_button(w, "Change the age...", function()
			ask_pin(function(can)
				if not can then
					return
				end
				uistack.main:pop(root)
				local root2, w2 = open_window("starport id age", 560, nil, {close_glyph = false})
				local get_age = age_rows(w2)
				local st = add_text(w2, "")
				local rr = add_row(w2)
				add_button(rr, "Save", function()
					local a, why = get_age()
					if not a then
						st.text = why
						return
					end
					a.session = session
					id_call(url, "age", a, function(res, e3)
						uistack.main:pop(root2)
						M.id_page(url, res and "Saved" or e3)
					end)
				end)
				add_button(rr, "Close", close_and(root2))
			end)
		end)
		-- (b): where the ID is logged in, and its last logins
		add_button(w, "Sessions and recent logins...", function()
			id_call(url, "sessions", {session = session}, function(res, e2)
				if not res then
					return again(e2)
				end
				uistack.main:pop(root)
				local root2, w2 = open_window("starport id sessions", 680, nil, {close_glyph = false})
				local function line(x)
					return os.date("!%Y-%m-%d %H:%M UTC", tonumber(x.created)
							or 0) .. ", " .. tostring(x.how) ..
							(x.address ~= "" and ", from " ..
							tostring(x.address) or "")
				end
				add_text(w2, "Logged in now:")
				for _, x in ipairs(res.sessions or {}) do
					add_text(w2, line(x) .. (x.this and " (this one)" or ""),
							x.this and DIM or nil)
				end
				add_text(w2, "The last logins:")
				for i = #(res.recent or {}), 1, -1 do
					add_text(w2, line(res.recent[i]))
				end
				local rr = add_row(w2)
				add_button(rr, "Log out everywhere else", function()
					id_call(url, "logout_others", {session = session},
							function(n, e3)
						uistack.main:pop(root2)
						M.id_page(url, n and ("Logged out of " .. tostring(n) ..
								" other sessions") or e3)
					end)
				end)
				add_button(rr, "Close", close_and(root2, function()
					M.id_page(url)
				end))
			end)
		end)
		r = add_row(w)
		add_button(r, "Log out", function()
			id_call(url, "logout", {session = session}, function() end)
			load_state().ids[url] = nil
			save_state()
			uistack.main:pop(root)
		end)
		local dpw = add_edit(r, "", true)
		add_button(r, "Delete the ID (password)", function()
			id_call(url, "delete", {session = session,
				password = dpw:GetText()}, function(res, e2)
				if res then
					load_state().ids[url] = nil
					save_state()
					uistack.main:pop(root)
				else
					again(e2)
				end
			end)
		end)
		add_button(w, "Close", close_and(root))
	end)
end

-- The age an ID has not said yet, asked where a join needs it (user,
-- 2026-10-02: "say your age on the ID's page first" left a newcomer
-- stuck); on_done(true) once the Starport has it
local function ask_age(url, session, on_done)
	ask_pin(function(can)
		if not can then
			return on_done(false)
		end
		local root, w = open_window("starport id age", 560, nil, {close_glyph = false})
		add_text(w, "Your Starport ID has no age yet")
		add_text(w, "Servers on " .. url .. " have age limits, so before "..
				"your ID joins one, say whether you are 18 or over. That "..
				"is all that is kept for an adult; under 18, the birth "..
				"year. You can change it later: Starport settings..., "..
				"Starport ID..., Change the age...", DIM)
		local get_age = age_rows(w)
		local st = add_text(w, "")
		local rr = add_row(w)
		add_button(rr, "Save and join", function()
			local a, why = get_age()
			if not a then
				st.text = why
				return
			end
			a.session = session
			id_call(url, "age", a, function(res, err)
				if not res then
					st.text = tostring(err)
					return
				end
				uistack.main:pop(root)
				on_done(true)
			end)
		end)
		add_button(rr, "Cancel", close_and(root, function()
			on_done(false)
		end))
	end)
end

-- [WEB_ID_TRUST] The web client's way to a token: the Starport's own page
-- (/authorize), in a window of its own, logs the ID in and posts the token
-- back to this page. The password is typed on the Starport's page only, and
-- the token goes to this page's origin only if it is the listed server's
-- (or one of the Starport's web_clients). The window opens at a click of
-- this dialog's: the browser blocks one opened otherwise.
-- set_web_starports({{url =, listing =}, ...}): where the server says it is
-- listed. Taken on the web only: there the server's code is the client
-- anyway; natively the user's own Starports are the ones asked.
function M.safe.set_web_starports(rows)
	if __buildat_get_env("BUILDAT_PAGE_HTTPS") == nil or
			type(rows) ~= "table" then
		return
	end
	web_starports = {}
	for _, r in ipairs(rows) do
		if type(r) == "table" and type(r.url) == "string" and
				type(r.listing) == "string" and
				r.url:match("^https?://[%w%.%-%[%]:]+$") and
				r.listing:match("^%x+$") then
			web_starports[#web_starports + 1] = r
		end
	end
end
M.set_web_starports = M.safe.set_web_starports

-- rename_reason: the name this ID has here is refused; the Starport's
-- window asks for another
local function web_authorize(url, listing, address, cb, rename_reason)
	local q = "/authorize?address=" .. address
	if listing then
		q = q .. "&listing=" .. listing
	end
	if rename_reason then
		q = q .. "&rename=1"
	end
	local root, w = open_window("starport id web", 520, nil, {close_glyph = false})
	if rename_reason then
		add_text(w, rename_reason)
	end
	add_text(w, "Sign in with your Starport ID at " .. url .. ". Its page "..
			"opens in a window of its own; your password goes there only.")
	local st = add_text(w, "")
	local rr = add_row(w)
	local function open()
		st.text = __buildat_web_authorize(url .. q) and
				"Waiting for the Starport's window..." or
				"The browser blocked the window: allow pop-ups for this "..
				"page, then Open"
	end
	add_button(rr, "Open", open)
	-- [ID_CLAIM_ACCOUNT]: the account by that name is the user's own
	if rename_reason then
		add_button(rr, "That's my account", close_and(root, function()
			web_wait = nil
			cb(nil, "mine")
		end))
	end
	add_button(rr, "Cancel", close_and(root, function()
		web_wait = nil
		cb(nil, "cancelled")
	end))
	-- [PLAYTEST_1008] At once, from the press that came here, which the
	-- browser counts as the user's; Open again where it blocked that
	open()
	web_wait = function(m)
		for _, e in ipairs(uistack.main.stack) do
			if e == root then
				uistack.main:pop(root)
				break
			end
		end
		local v = network.parse_json(m)
		if type(v) ~= "table" or type(v.buildat_starport_token) ~= "string" then
			return cb(nil, "the Starport's window sent no token")
		end
		cb(v.buildat_starport_token)
	end
end

-- id_token_here(cb[, rename_reason]): a token for the server this client
-- is on, from the Starport ID of a Starport that lists it ([STARPORT]
-- 10c); cb(token) or cb(nil, why). The name used in the server's
-- community is asked the first time, in this side's own dialog; with
-- rename_reason, a new one is asked first, the reason shown (the server
-- has an account of its own by the name the ID had there), with "That's
-- my account" beside, which answers cb(nil, "mine")
function M.safe.id_token_here(cb, rename_reason)
	local address = here_address()
	if not address then
		return cb(nil, "not connected")
	end
	-- A token given marks the server ([ID_AUTO_JOIN])
	local given = cb
	cb = function(token, why)
		if token then
			local s = load_state()
			s.id_used = type(s.id_used) == "table" and s.id_used or {}
			if not s.id_used[address] then
				s.id_used[address] = true
				save_state()
			end
		end
		return given(token, why)
	end
	local function with_row(row)
		local s = load_state()
		local url, listing = nil, nil
		-- Not in the list (an unlisted server, 10g): the Starports the user
		-- has an ID on, which find the server by this address
		local ids = row and row.ids or {}
		if not row then
			for _, u in ipairs(effective().starports) do
				ids[u] = false
			end
		end
		if __buildat_get_env("BUILDAT_PAGE_HTTPS") ~= nil then
			-- simplified: the first Starport of several; a choice when
			-- web clients list on more than one
			local u, l = next(ids)
			if not u then
				return cb(nil, "No Starports in your settings")
			end
			return web_authorize(u, l or nil,
					address:gsub("^https://", ""):gsub("^wss://", ""), cb,
					rename_reason)
		end
		for u, l in pairs(ids) do
			if s.ids[u] then
				url, listing = u, l or nil
			end
		end
		if not url then
			if not next(ids) then
				return cb(nil, "No Starports in your settings")
			end
			-- Not logged in to any of them: the first one's login
			for u, l in pairs(ids) do
				url, listing = u, l or nil
			end
			return M.id_login(url, function()
				M.safe.id_token_here(cb, rename_reason)
			end)
		end
		-- The Starport away: a kept token, opened by the password
		local function offline(why)
			local sealed = s.sealed and s.sealed[url] and s.sealed[url][address]
			if not sealed then
				return cb(nil, "The Starport cannot be reached (" .. why ..
						"), and there is no saved login for this server")
			end
			local root, w = open_window("starport id offline", 520, nil, {close_glyph = false})
			add_text(w, "The Starport cannot be reached. Your saved login "..
					"for this server is locked with your Starport password:")
			local e = add_edit(w, "", true)
			local st = add_text(w, "")
			local function go()
				local plain = __buildat_unseal(e:GetText(), unhex(sealed))
				local v = plain and network.parse_json(plain)
				if not v then
					st.text = "Not the password"
					return
				end
				if (tonumber(v.exp) or 0) < os.time() then
					st.text = "The saved login has expired"
					return
				end
				uistack.main:pop(root)
				cb(v.token)
			end
			magic.SubscribeToEvent(e, "TextFinished", go)
			local rr = add_row(w)
			add_button(rr, "Log in", go, nil, true)
			add_button(rr, "Cancel", close_and(root, function()
				cb(nil, "cancelled")
			end))
			e:SetFocus(true)
		end
		local community = tostring(row and (type(row.fleet) == "table" and
				row.fleet.name or row.name) or address)
		local ask
		-- The name to use in the community, the reason first if any
		local function name_prompt(reason, suggest, rename)
			local root, w = open_window("starport id name", 520, nil, {close_glyph = false})
			if reason then
				add_text(w, reason, WARN)
			end
			add_text(w, "The name to use in " .. community .. ". Only this "..
					"community sees it; others do not see which name you "..
					"use here.")
			local e = add_edit(w, suggest or "")
			local rr = add_row(w)
			add_button(rr, "Use it", function()
				local n = e:GetText()
				uistack.main:pop(root)
				ask(n, rename)
			end)
			-- [ID_CLAIM_ACCOUNT]: the account by that name is the user's own
			if rename_reason then
				add_button(rr, "That's my account", close_and(root, function()
					cb(nil, "mine")
				end))
			end
			add_button(rr, "Cancel", close_and(root, function()
				cb(nil, "cancelled")
			end))
		end
		ask = function(name, rename)
			id_call(url, "token", {session = s.ids[url].session,
				listing = listing, address = address:gsub("^https://", ""),
				name = name, rename = rename or nil},
					function(res, err, away)
				if not res and away then
					return offline(err)
				end
				if not res then
					if err == "session" then
						return M.id_login(url, function()
							M.safe.id_token_here(cb, rename_reason)
						end, "Log in again")
					end
					-- An ID made without an age (one made by joining the
					-- Starport app): asked here, then the join goes on
					if tostring(err):lower():find("say your age", 1, true) then
						return ask_age(url, s.ids[url].session, function(ok)
							if ok then
								ask(name, rename)
							else
								cb(nil, "cancelled")
							end
						end)
					end
					-- A name the community has, or not a name: another
					if name and (tostring(err):find("is taken", 1, true) or
							tostring(err):find("a name is", 1, true)) then
						return name_prompt(err, name, rename)
					end
					return cb(nil, err)
				end
				if res.need_name then
					return name_prompt(nil, res.suggest)
				end
				keep_token(url, address, res.token, res.exp)
				cb(res.token)
			end)
		end
		if rename_reason then
			name_prompt(rename_reason, "", true)
		else
			ask(nil)
		end
	end
	-- The web, by where the server says it is listed: no list to fetch
	local ws = web_starports[1]
	if ws then
		return web_authorize(ws.url, ws.listing,
				address:gsub("^https://", ""):gsub("^wss://", ""), cb,
				rename_reason)
	end
	local row = row_of(address)
	if row then
		with_row(row)
	else
		M.safe.fetch(function() with_row(row_of(address)) end, true)
	end
end

-- open_settings([on_closed]): the settings dialog, behind the PIN where
-- one is set; on_closed() at its Back
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

-- **A report on a release** ([AITTA_REPORTS]), to its Aitta: a reason
-- and what is wrong, with this client's report key for that Aitta where
-- the settings send keys (a Starport's key_for, by the Aitta's address)
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
		if load_state().send_key then
			body.key = key_for(aitta)
		end
		status.text = "Sending..."
		network.http_post(aitta .. "/api/aitta/report", network.write_json(body),
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

-- An installed release's client half started with no server, the pages
-- over the launcher taken down first
local function play_installed(key, version)
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
		network.http_get(tostring(rel.aitta) .. "/api/aitta/media/" .. h,
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
		local base = rel.aitta .. "/api/aitta/archive/" .. tostring(rel.sha256)
		say("Fetching " .. k .. "...")
		local options = {description = "Aitta (install)"}
		network.http_get(base .. ".sig", function(sig, err1)
			if not sig then
				return say("Could not fetch: " .. tostring(err1), WARN)
			end
			network.http_get(base .. ".zip", function(zip, err2)
				if not zip then
					return say("Could not fetch: " .. tostring(err2), WARN)
				end
				local dir, why = __buildat_aitta_install(zip, sig, rel.aitta)
				if dir and play then
					return play_installed(k, rel.version)
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
			end, options)
		end, options)
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
				"an extension" or "an app") .. (rel.serverless == true and
				", runs in the browser" or "") .. ", by " ..
				tostring(rel.author) .. "; " .. (rel.review == "reviewed" and
				"reviewed" or "unreviewed"), DIM)
		ptext(tostring(rel.license_code) .. " / " ..
				tostring(rel.license_media) .. ", " ..
				math.floor((tonumber(rel.size) or 0) / 1000) .. " kB", DIM)
		if rel.description and rel.description ~= "" then
			ptext(tostring(rel.description))
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
		if rel.kind ~= "extension" then
			ptext("It runs in the server's sandbox: it cannot reach your " ..
					"files, only its own saves.", DIM)
		end
		local changelog = ptext("", DIM)
		local st = state(p)
		local actions = add_row(panel)
		-- [SERVERLESS_PLAY] Play: installed first where it is not; on the
		-- web, with no server to install onto, only Play
		if rel.serverless == true then
			add_button(actions, "Play", function()
				if st == "Installed" then
					play_installed(p.key, rel.version)
				else
					install(p, true)
				end
			end, true, true)
		end
		if not ON_WEB then
			add_button(actions, st == "Installed" and "Installed" or
					st == "Updates" and "Update" or "Install",
					function() install(p) end, st ~= "Installed",
					rel.serverless ~= true)
		end
		-- Without its own, the Hearth its Aitta's Starport recommends
		if not (type(rel.home_hearth) == "string" and
				rel.home_hearth:match("^https?://")) then
			rel.home_hearth = M.safe.fallback_hearth(rel.aitta)
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
		network.http_get(rel.aitta .. "/api/aitta/release?id=" .. id,
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
		table.sort(shown, function(a, b)
			if by == "newest" then
				return (tonumber(a.rel.time) or 0) > (tonumber(b.rel.time) or 0)
			end
			return a.key:lower() < b.key:lower()
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
					(st == "Installed" and ", installed" or
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
						state(p) ~= "Installed" then
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
						(rel.serverless == true or not ON_WEB) then
					rel.aitta = rel.aitta or a
					local k = tostring(rel.author) .. "/" .. tostring(rel.name)
					log:info("aitta page: " .. k .. " " ..
							tostring(rel.version) .. " " ..
							(rel.review == "reviewed" and "reviewed" or
							"unreviewed"))
					if not newest[k] then
						order[#order + 1] = k
					end
					if not newest[k] or (tonumber(rel.time) or 0) >
							(tonumber(newest[k].time) or 0) then
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
		network.http_get(a .. "/api/aitta/list", function(body, err)
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
		local base = offer.aitta .. "/api/aitta/archive/" .. offer.sha256
		local function failed(why)
			log:warning("playtest: " .. id .. ": " .. tostring(why))
			ui.show_message_dialog("Not installed: " .. tostring(why))
		end
		-- The network's own leave for the Aitta's address is asked as for
		-- any fetch, once
		local options = {description = "Aitta (playtest)"}
		network.http_get(base .. ".sig?ticket=" .. offer.ticket, function(sig, e1)
			if not sig or not sig:match("^%s*{") then
				return failed(sig and "the ticket was refused" or e1)
			end
			network.http_get(base .. ".zip?ticket=" .. offer.ticket,
					function(zip, e2)
				if not zip or zip:sub(1, 2) ~= "PK" then
					return failed(zip and "the ticket was refused" or e2)
				end
				local dir, why = __buildat_aitta_install(zip, sig, offer.aitta,
						true)
				if not dir then
					return failed(why)
				end
				local author, name, version = id:match("^(.-)/(.-)/(.*)$")
				local app = "review:" .. author .. "." .. name .. "@" .. version
				log:info("playtest: installed " .. app .. " in " .. dir)
				local menu = buildat.menu_extension()
				if menu and type(menu.refresh) == "function" then
					menu.refresh()
				end
				start(app)
			end, options)
		end, options)
	end, function()
		log:info("playtest: no, " .. id)
	end, "Playtest", "Cancel")
end

-- [SERVERLESS_PLAY] BUILDAT_RUN=<author>/<name>, a play page's #run=: the
-- newest serverless release of it on the Aittas in the settings,
-- installed if it is not (the signature checked) and played. With no
-- answer from them, an installed version of it is played.
-- simplified: the newest by the time an Aitta listed it, as the list's
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
			return play_installed(key, best.version)
		end
		if best then
			local base = best.aitta .. "/api/aitta/archive/" ..
					tostring(best.sha256)
			local options = {description = "Aitta (install)"}
			network.http_get(base .. ".sig", function(sig, e1)
				if not sig then
					return failed(tostring(e1))
				end
				network.http_get(base .. ".zip", function(zip, e2)
					if not zip then
						return failed(tostring(e2))
					end
					local dir, why = __buildat_aitta_install(zip, sig, best.aitta)
					if not dir then
						return failed(tostring(why))
					end
					play_installed(key, best.version)
				end, options)
			end, options)
			return
		end
		for version, _ in pairs(have or {}) do
			return play_installed(key, version)
		end
		failed(#errors > 0 and table.concat(errors, "; ") or
				"no Aitta in the settings lists it as playable with no server")
	end
	for _, a in ipairs(e.aittas) do
		network.http_get(a .. "/api/aitta/list", function(body, err)
			local v = body and network.parse_json(body)
			if type(v) == "table" and type(v.releases) == "table" then
				for _, rel in ipairs(v.releases) do
					if type(rel) == "table" and rel.serverless == true and
							tostring(rel.author) .. "/" ..
							tostring(rel.name) == key and
							(e.filters.unreviewed or rel.review == "reviewed")
							and (not best or (tonumber(rel.time) or 0) >
							(tonumber(best.time) or 0)) then
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

function M.safe.open_settings(on_closed)
	settings_closed = on_closed
	ask_pin(function(ok)
		settings_page(ok)
	end)
end

-- Base64, for the evidence a report carries in its JSON
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local q = {}
		for k = 4, 1, -1 do
			q[k] = n % 64 + 1
			n = math.floor(n / 64)
		end
		out[#out + 1] = B64:sub(q[1], q[1]) .. B64:sub(q[2], q[2]) ..
				(b and B64:sub(q[3], q[3]) or "=") ..
				(c and B64:sub(q[4], q[4]) or "=")
	end
	return table.concat(out)
end
assert(base64("Ma") == "TWE=" and base64("Man") == "TWFu" and
		base64("M") == "TQ==")

local MAX_EVIDENCE = 48 * 1024

-- **The evidence**: the newest screenshot the player took in the last ten
-- minutes (the screenshot key, before opening the report), made small
-- enough for a report. -> base64 JPEG and the file's name, or nil and why
-- simplified: found by trying the names the client gives a screenshot,
-- second by second, as there is no directory listing here; one taken
-- twice in a second is found by its first name only
local function latest_screenshot_evidence()
	local dir = __buildat_get_path("user") .. "/screenshots/"
	local now = os.time()
	local path, name = nil, nil
	for t = now, now - 600, -1 do
		local n = os.date("screenshot_%Y%m%d_%H%M%S.png", t)
		local f = io.open(dir .. n, "rb")
		if f then
			f:close()
			path, name = dir .. n, n
			break
		end
	end
	if not path then
		return nil, "No screenshot from the last ten minutes: take one "..
				"with the screenshot key, then attach it"
	end
	local img = Image:new()
	if not img:Load(path) or img.width == 0 then
		return nil, "Could not read " .. name
	end
	local tmp = __buildat_get_path("user") .. "/starport_evidence.jpg"
	for _, try in ipairs({{640, 60}, {480, 50}, {360, 40}, {240, 35}}) do
		local w = math.min(try[1], img.width)
		local h = math.max(1, math.floor(img.height * w / img.width))
		img:Resize(w, h)
		if img:SaveJPG(tmp, try[2]) then
			local f = io.open(tmp, "rb")
			local data = f and f:read("*a") or ""
			if f then
				f:close()
			end
			os.remove(tmp)
			local b64 = base64(data)
			if #b64 <= MAX_EVIDENCE and #data > 0 then
				return b64, name
			end
		end
	end
	return nil, "Could not make " .. name .. " small enough"
end

local function open_report_row(row)
	local root, w = open_window("starport report", 620, nil, {close_glyph = false})
	add_text(w, "Report " .. tostring(row.name) .. " (" .. row.address .. ")")
	local reason, suggest = nil, nil
	local rr = add_row(w)
	add_label(rr, "Reason", 240)
	local choices = {}
	for _, r in ipairs(REASONS) do
		choices[#choices + 1] = {r[2], r[1]}
	end
	add_dropdown(rr, choices, nil, function(v) reason = v end,
			{none = "(choose)"})
	local sr = add_row(w)
	add_label(sr, "Wrong rating: audience should be", 240)
	add_dropdown(sr, AUDIENCES, nil, function(v) suggest = v end,
			{none = "(say if so)"})
	add_text(w, "What is wrong (optional):")
	local text = add_edit(w, "")
	-- 2b: the whole fleet, where the server is in one
	local whole_fleet = false
	if type(row.fleet) == "table" and row.fleet.name then
		local fb
		fb = add_button(w, "[ ] The whole fleet: " .. tostring(row.fleet.name),
				function()
			whole_fleet = not whole_fleet
			fb:GetChild(0).text = (whole_fleet and "[x]" or "[ ]") ..
					" The whole fleet: " .. tostring(row.fleet.name)
		end)
	end
	local evidence = nil
	local er = add_row(w)
	local ev_text
	add_button(er, "Attach my latest screenshot", function()
		local b64, what = latest_screenshot_evidence()
		evidence = b64
		ev_text.text = b64 and "Attached: " .. what or what
	end)
	ev_text = add_label(er, "", 0)
	local status = add_text(w, "")
	local r = add_row(w)
	add_button(r, "Send", function()
		if not reason then
			status.text = "Choose a reason"
			return
		end
		local s = load_state()
		local n = 0
		for url, id in pairs(row.ids) do
			n = n + 1
			local body = {listing = id, reason = reason, text = text:GetText(),
				whole_fleet = whole_fleet, evidence = evidence}
			if reason == "category" and suggest then
				body.suggest = {audience = suggest}
			end
			if s.send_key then
				body.key = key_for(url)
			end
			network.http_post(url .. "/api/report", network.write_json(body),
					function(answer, err)
				local v = answer and network.parse_json(answer)
				if type(v) == "table" and v.ok then
					table.insert(s.receipts, {starport = url,
						receipt = v.receipt, name = tostring(row.name),
						reason = reason, ts = os.time(), keyed = s.send_key,
						state = "open"})
					save_state()
					status.text = "Sent; receipt " .. v.receipt ..
							(s.send_key and ". The outcome shows in the "..
							"Starport settings." or ".")
				else
					status.text = "Not sent: " .. tostring(type(v) == "table"
							and v.error or err)
				end
			end, {description = "Starport"})
		end
		status.text = "Sending to " .. n .. " Starport(s)..."
	end)
	add_button(r, "Close", function() uistack.main:pop(root) end)
end

-- open_report(address): the report dialog for a listing of the last fetch
function M.safe.open_report(address)
	local row = row_of(address)
	if not row then
		return false
	end
	open_report_row(row)
	return true
end

-- [REPORT_HERE]: an address as an endpoint -- the host without its case,
-- the port with the default said (443 under TLS, 29500 else) and whether
-- TLS -- so "Host:443" over https and a listing of host, 443, tls are one.
-- tls is the page's for an address with no scheme (the web client's).
local function endpoint(address, tls)
	local a = tostring(address)
	local scheme, rest = a:match("^(%a+)://(.*)$")
	if scheme then
		tls = scheme == "https" or scheme == "wss"
		a = rest
	end
	a = a:gsub("/.*$", "")
	local host, port
	if a:sub(1, 1) == "[" then
		host, port = a:match("^%[(.-)%]:?(%d*)$")
	else
		host, port = a:match("^([^:]*):?(%d*)$")
	end
	return (host or ""):lower() .. ":" ..
			(tonumber(port) or (tls and 443 or 29500)) ..
			(tls and " tls" or "")
end
M.endpoint = endpoint

-- open_report_here(): the report dialog for the server this client is on,
-- for a server's own page ([STARPORT] 5). **The server is never asked**
-- (user, 2026-10-02): a bad actor's would not help. The listing is found
-- in the lists of the Starports the player trusts -- the settings' and
-- the ones their IDs come from -- by the endpoint connected to; where none
-- has it, the player picks it by name.
function M.safe.open_report_here()
	local address = __buildat_server_address()
	if not address then
		return false
	end
	local here = endpoint(address,
			buildat.get_env("BUILDAT_PAGE_HTTPS") == "1")
	local function find()
		for _, x in ipairs(last_rows) do
			if endpoint(tostring(x.host) .. ":" .. tostring(x.port),
					x.tls == true) == here then
				return x
			end
		end
		return nil
	end
	local id_starports = {}
	for url, _ in pairs(load_state().ids or {}) do
		id_starports[#id_starports + 1] = url
	end
	table.sort(id_starports)
	local function go(_, info)
		local row = find()
		local addrs = {}
		for _, x in ipairs(last_rows) do
			addrs[#addrs + 1] = tostring(x.address)
		end
		local errors = info and info.errors or {}
		log:info("report here: connected to " .. address .. " (" .. here ..
				"); " .. #last_rows .. " rows (" .. table.concat(addrs, ", ") ..
				"); errors: " .. table.concat(errors, "; ") .. "; " ..
				(row and "found" or "NOT FOUND"))
		if row then
			open_report_row(row)
			return
		end
		-- Which failure it was, and the listings to pick from
		local root, w = open_window("starport report", 560, nil, {close_glyph = false})
		local asked = {}
		for _, url in ipairs(effective().starports) do
			asked[#asked + 1] = url
		end
		for _, url in ipairs(id_starports) do
			asked[#asked + 1] = url
		end
		if #asked == 0 then
			add_text(w, "No Starports are set, so there is nobody to " ..
					"report to: add one in the Starport settings.")
		else
			add_text(w, address .. " is not among the listings of " ..
					table.concat(asked, ", ") .. ".")
		end
		for _, e in ipairs(errors) do
			add_text(w, "Did not answer: " .. e, WARN)
		end
		log:info("report here: " .. math.min(#last_rows, 20) ..
				" listings offered to pick by name")
		if #last_rows > 0 then
			add_text(w, "If it is listed under another address, pick it:")
			-- simplified: the first twenty, by players; a long list wants
			-- the server list's filter
			for i, x in ipairs(last_rows) do
				if i > 20 then
					break
				end
				add_button(w, tostring(x.name) .. "  (" .. tostring(x.address) ..
						")", function()
					uistack.main:pop(root)
					open_report_row(x)
				end)
			end
		end
		add_button(w, "Close", function() uistack.main:pop(root) end)
	end
	if find() then
		go()
	else
		M.safe.fetch(go, true, id_starports)
	end
	return true
end

-- [DISCUSS_SERVER]: the listing of the Buildat server this client is on,
-- found as open_report_here finds it but only in the lists kept from the
-- last fetch, with the Starport that lists it: {name, host, port,
-- starport}, or nil. On M and never in M.safe.
function M.listing_here()
	local address = __buildat_server_address()
	if not address then
		return nil
	end
	local here = endpoint(address,
			buildat.get_env("BUILDAT_PAGE_HTTPS") == "1")
	local kept = read_json(LIST_CACHE) or {}
	for _, url in ipairs(effective().starports) do
		local k = kept[url]
		for _, x in ipairs(type(k) == "table" and type(k.servers) == "table"
				and k.servers or {}) do
			if type(x) == "table" and x.host and x.port and
					endpoint(tostring(x.host) .. ":" .. tostring(x.port),
					x.tls == true) == here then
				return {name = tostring(x.name or ""), host = tostring(x.host),
					port = tonumber(x.port), starport = url}
			end
		end
	end
	return nil
end

-- group(servers[, fleet_id]): a fetch's servers as fleet, pool and
-- server rows (group.lua), a pool's servers in the user's region first
function M.safe.group(servers, fleet_id)
	return group.group(servers, fleet_id, load_state().region or "")
end

M.fetch = M.safe.fetch
M.direct_connect_allowed = M.safe.direct_connect_allowed
M.open_settings = M.safe.open_settings
M.open_report = M.safe.open_report
M.open_report_here = M.safe.open_report_here
M.id_token_here = M.safe.id_token_here
M.take_id_join = M.safe.take_id_join
M.has_id = M.safe.has_id
M.group = M.safe.group
-- [AITTA_PUBLISH_UI]: the publish screen, drawn with this file's dialogs
dofile(__buildat_extension_path("starport") .. "/publish.lua")({M = M,
	network = network, magic = magic, uistack = uistack,
	open_window = open_window, add_text = add_text, add_label = add_label,
	add_row = add_row, add_button = add_button, add_edit = add_edit,
	add_dropdown = add_dropdown, effective = effective, WARN = WARN, DIM = DIM})
-- The verb itself in this file, the extension's surface, which is what
-- the sandbox scan holds an extension's verbs to; publish.lua's is what
-- it calls
local open_publish = M.safe.open_publish
function M.safe.open_publish() open_publish() end
M.open_publish = M.safe.open_publish
return M
-- vim: set noet ts=4 sw=4:
