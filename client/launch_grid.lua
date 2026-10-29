-- Buildat: client/launch_grid.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch grid's actions ([LAUNCH_GRID]): every launcher/init.lua in
-- the tree run in the sandbox, its actions checked, their icons resolved
-- on this side, and ctx.launch -- the file's one way out -- with its
-- params crossing as plain data into a receiver that knows it is
-- untrusted. See doc/plan/launcher_plan.md. Loaded by client/api.lua,
-- whose launch_actions() and launch() are its safe face.
local M = {}

local ICON_FALLBACK = "buildat_logo.png"

-- **The screens a game is started through**, extensions/launch_menu/
-- screens.lua, run in the sandbox for each launch: every launch UI's game
-- starts end there, and the file keeps no state, so a fresh copy is the
-- same as a kept one. Run as the extension, as its own loader runs
-- it, so the verbs know whose file it is. file is another of
-- launch_menu's own the same way (preferences.lua).
function M.screens(file)
	file = file or "screens.lua"
	local f = io.open(__buildat_extension_path("launch_menu") ..
			"/" .. file, "rb")
	if not f then
		error("launch_grid: no launch_menu/" .. file)
	end
	local code = f:read("*a")
	f:close()
	local ok, err, m = __buildat_run_code_in_sandbox(code,
			"launch_menu/" .. file, "launch_menu")
	if not ok or type(m) ~= "table" then
		error("launch_grid: launch_menu/" .. file .. ": " .. tostring(err))
	end
	return m
end

-- A package's home Hearth (its manifest's home_hearth), as the address the
-- client connects to: Hearth answers the web and the client on one port
-- ("http://h:p/" is "h:p"; "https://h/" stays, a proxy with TLS)
function M.hearth_address(url)
	local scheme, host = tostring(url):match("^(https?)://([^/?#]+)")
	if not scheme then
		return nil
	end
	return scheme == "https" and "https://" .. host or
			(host:find(":%d+$") and host or host .. ":80")
end
local function hearth_target(url, author, name, version, key)
	local address = M.hearth_address(url)
	if not address then
		return nil
	end
	return {
		url = url,
		address = address,
		subject = author .. "/" .. name .. " " .. key,
		package = author .. "/" .. name, version = version,
		engine = tostring(buildat.version()), platform = GetPlatform(),
	}
end

-- The launch menu's own two tiles, which every launch UI's grid has:
-- the local game list and connecting to a server
local function menu_actions()
	local out = {
		{id = "local", label = "Local app", order = 1,
			icon = "own:launch_menu/res/icon_local.png", resolved_icon = true,
			description = "Start an app on this machine",
			run = function() M.screens().show_local_apps() end},
		{id = "connect", label = "Join a Buildat server", order = 2,
			category = "connect",
			icon = "own:launch_menu/res/icon_network.png", resolved_icon = true,
			description = "By its address, on this network or from the Starports",
			run = function() M.screens().show_connect_to_server() end},
	}
	-- [AITTA_REVIEW]: where the filters (under Starport's lock) hide
	-- unreviewed content, the tile lists reviewed releases only
	local ok, aitta = pcall(require, "buildat/core/aitta")
	if ok and type(aitta) == "table" then
		out[#out + 1] = {id = "aitta", label = "Apps from Aitta", order = 3,
			category = "catalog",
			icon = "own:launch_menu/res/icon_network.png", resolved_icon = true,
			description = __buildat_get_env("BUILDAT_PAGE_HTTPS") ~= nil and
					"Play apps others made that run in the browser" or
					"Install apps others made: " ..
					(aitta.safe.aitta_shown() and "reviewed or not" or
					"reviewed ones") .. ", each in the server's sandbox",
			-- "Discuss" on a release: its home Hearth, at the package's place
			run = function() aitta.safe.open_aitta(function(rel)
				local home = hearth_target(rel.home_hearth,
						tostring(rel.author), tostring(rel.name),
						tostring(rel.version), tostring(rel.key))
				if home then
					home.place = true
					buildat.set_feedback(home)
					M.screens().connect(home.address)
				end
			end) end}
	end
	return out
end
local MAX_PARAMS_DEPTH = 8

-- params as plain data: strings, numbers, booleans and tables of them,
-- copied into a fresh table so nothing of the sandbox's reaches the
-- trusted side by reference; anything else is an error at the call
local function plain_copy(v, depth)
	local t = type(v)
	if t == "string" or t == "number" or t == "boolean" or t == "nil" then
		return v
	end
	if t ~= "table" then
		error("ctx.launch: params may hold strings, numbers, booleans and "..
				"tables, not a "..t)
	end
	if depth > MAX_PARAMS_DEPTH then
		error("ctx.launch: params nested too deep")
	end
	local out = {}
	for k, x in pairs(v) do
		local kt = type(k)
		if kt ~= "string" and kt ~= "number" then
			error("ctx.launch: a params key is a "..kt)
		end
		out[k] = plain_copy(x, depth + 1)
	end
	return out
end

-- What a launch does, per target kind. An extension is entered through its
-- on_untrusted_launch(request) and nothing else; a game starts a local
-- server the way the local-game screen does. simplified: params reach an
-- extension and not yet a game or a builtin -- the server has no door for
-- them yet (`untrusted_launch` in its config is the plan), so a game with
-- params, and a module target, are refused with a warning until it does.
local function do_launch(log, from, request)
	local params = plain_copy(request.params, 0) or {}
	if request.extension then
		local name = tostring(request.extension)
		local ok, ext = pcall(require, "buildat/extension/"..name)
		if not ok or type(ext) ~= "table" or
				type(ext.on_untrusted_launch) ~= "function" then
			log:warning("launch from "..from..": extension "..name..
					" has no on_untrusted_launch; not a target")
			return
		end
		ext.on_untrusted_launch({from = from, params = params})
	elseif request.app or request.game then
		-- (`game`, as an app was called before: accepted still)
		local app = request.app or request.game
		-- To a game the params go as key=value lines through the server's
		-- -u, which a module reads as it would a packet; the top level
		-- only, strings, numbers and booleans, a key of a name's shape
		local lines = {}
		for k, v in pairs(params) do
			if type(k) ~= "string" or not k:match("^[%w_]+$") or
					type(v) == "table" or tostring(v):find("\n") then
				log:warning("launch from "..from..": param "..tostring(k)..
						" cannot reach a game; dropped")
			else
				lines[#lines + 1] = k.."="..tostring(v)
			end
		end
		M.screens().start_local_app(tostring(app),
				table.concat(lines, "\n"))
	elseif request.module then
		log:warning("launch from "..from..": a builtin module is not a "..
				"target yet ([LAUNCH_GRID])")
	else
		log:warning("launch from "..from..": no extension, game or module")
	end
end

-- The file, run in the sandbox as a module's client Lua is, given ctx
local function run_launcher(log, source)
	local path = source.path.."/launcher/init.lua"
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local code = f:read("*a")
	f:close()
	local from = source.kind.."/"..source.name
	local ctx = {
		kind = source.kind, name = source.name, path = source.path,
		launch = function(request)
			if type(request) ~= "table" then
				error("ctx.launch: wants a table")
			end
			-- An app installed from a release launches itself and nothing
			-- else: its launcher names the app as it is in its tree, and
			-- the tile is that version of it ([AITTA_MVP])
			if source.kind == "installed" or source.kind == "review" then
				request = {app = source.name, params = request.params}
			end
			-- And an author's own in <user>/dev_apps ([AITTA_PUBLISH_UI])
			if source.kind == "dev" then
				request = {app = "dev:" .. source.name, params = request.params}
			end
			do_launch(log, from, request)
		end,
	}
	local status, err, chunk = __buildat_run_code_in_sandbox(code,
			"launcher "..from)
	if not status then
		log:warning("launcher "..from..": "..tostring(err))
		return nil
	end
	if type(chunk) ~= "function" then
		log:warning("launcher "..from..": the file did not return a function")
		return nil
	end
	local ok, actions = pcall(chunk, ctx)
	if not ok then
		log:warning("launcher "..from..": "..tostring(actions))
		return nil
	end
	if type(actions) ~= "table" then
		log:warning("launcher "..from..": returned a "..type(actions)..
				", not a table of actions")
		return nil
	end
	return actions, from, ctx
end

local KIND_ORDER = {menu = 0, app = 1, installed = 1, dev = 1, review = 1,
	web_local = 1,
	builtin = 2,
	extension = 3}

-- Every action the tree offers, checked and in the grid's order: explicit
-- order first, then by kind -- apps, builtins, extensions -- then label
-- **What a launch action says about itself** ([LAUNCH_SIGNIFY]): the
-- category is what kind of thing it is -- an **open set**, so a launch
-- UI that meets one it does not know draws its default rather than
-- failing -- and the significance is a non-negative number it may rank
-- and scale by, comparable **within** a category and nowhere else.
-- Absent means "no opinion" and is never an error, since most sources
-- have no view.
--
-- A launcher file may say both; what it does not say is defaulted here:
-- a game is a `game` of its own installed size, and everything else is
-- an `action` with no opinion. So the size a launch UI already draws
-- games by comes from the action rather than from the UI guessing which
-- game an action came from.
local function significance_of(a, source, app_sizes)
	local n = tonumber(a.significance)
	if n == nil and source.kind == "app" then
		n = app_sizes[source.name]
	end
	if n == nil or n < 0 then
		return nil
	end
	return n
end

local function category_of(a)
	if type(a.category) == "string" and a.category:match("^[%w_]+$") then
		return a.category
	end
	return nil
end

-- Where a server is ([SERVER_FILTER]): `network` is what it speaks and
-- plays, "Luanti" for luanti_client's and serverlist's, absent for
-- Buildat's own; `listed_by` the list it came from ("Luanti server
-- list"). Short names a launch UI shows and filters by; open sets, as the
-- category is.
local function short_name(s)
	if type(s) == "string" and #s > 0 and #s <= 40 then
		return s
	end
	return nil
end

-- An installed app's home Hearth, from its meta.json
local function feedback_target(source)
	local f = io.open(source.path .. "/meta.json", "rb")
	if not f then
		return nil
	end
	local m = __buildat_parse_json(f:read("*a"))
	f:close()
	if type(m) ~= "table" then
		return nil
	end
	-- [STARPORT_RECOMMENDS]: without its own, the Hearth a Starport
	-- recommends
	local ok, starport = pcall(require, "buildat/core/starport")
	local home = type(m.home_hearth) == "string" and m.home_hearth or
			ok and type(starport) == "table" and starport.safe.fallback_hearth()
	if not home then
		return nil
	end
	local kf = io.open(source.path .. "/../key", "rb")
	local key = kf and kf:read("*a"):match("%x+") or ""
	if kf then kf:close() end
	local author, name, version = source.name:match("^(.-)%.(.-)@(.*)$")
	return hearth_target(home, author, name, version, key)
end

-- [SAVE_CONTEXT_MENU] An app's actions on one of its saves, a launcher's
-- `for_save = true`: {app, id, label, description, run(save)}, rebuilt
-- with the tiles and none of them a tile
M.for_save = {}
-- [SAVE_ICON] **What each save of an app is**: app -> {store, key, icon},
-- from a launcher's `ctx.save_variant = {store =, key =, icon =}`. The
-- value at that key of a save's store names one of the app's tiles (its
-- id), whose picture the save shows; icon, the launcher's own file, is
-- for a save whose value names none. Nil before the first scan.
M.save_variants = nil
-- [WORLD_PACKAGES] **The apps whose saves are worlds to publish**: app ->
-- {code = {paths}, player_rows = {rows}}, from a launcher's
-- `ctx.world_packages = {code = {...}, player_rows = {...}}`: the app's
-- saves copy as files, code names the paths in a save that the app runs as
-- code (a world package carries none), and player_rows the rows of its
-- save.sqlite that are per player, "<store>/<key>" (left out of a
-- published world: its players' privileges and what they carry). Each such
-- app's saves have "Publish this world". Nil before the first scan.
M.world_packages = nil

function M.actions(log)
	local out = {}
	M.for_save = {}
	M.save_variants = {}
	M.world_packages = {}
	local app_sizes = {}
	for _, g in ipairs(buildat.list_apps() or {}) do
		app_sizes[g.name] = tonumber(g.size)
	end
	local sources = buildat.list_launchers()
	-- How many versions of each installed app are here ([AITTA_MVP])
	local versions = {}
	for _, source in ipairs(sources) do
		if source.kind == "installed" then
			local app = source.name:match("^(.-)@")
			versions[app] = (versions[app] or 0) + 1
		end
	end
	for _, source in ipairs(sources) do
		local actions, from = nil, source.kind.."/"..source.name
		-- One rule: a directory is on the grid if it has launcher/init.lua.
		-- The default tile for a game without one put the test scenes on
		-- the grid; the real games carry a two-line file each.
		if source.kind == "extension" and source.name == "launch_menu" then
			actions = menu_actions()
		elseif source.launcher then
			local ctx
			actions, _, ctx = run_launcher(log, source)
			-- simplified: an app's own (kind "app") only, as for_save
			local v = ctx and ctx.save_variant
			if source.kind == "app" and type(v) == "table" and
					type(v.store) == "string" and type(v.key) == "string" then
				M.save_variants[source.name] = {store = v.store, key = v.key,
					icon = type(v.icon) == "string" and
							not v.icon:find("[/\\]") and
							source.name.."/launcher/"..v.icon or nil}
			end
			-- An app that comes with Buildat by its name, an installed one
			-- by <author>.<name>: where their saves are
			local wp = ctx and ctx.world_packages
			local app = source.kind == "app" and source.name or
					source.kind == "installed" and source.name:match("^(.-)@")
			if app and type(wp) == "table" and M.world_packages[app] == nil then
				local code = {}
				for _, c in ipairs(type(wp.code) == "table" and wp.code or {}) do
					-- A path inside the save; one that is not is no opt-in,
					-- since a world would then carry what it names
					if type(c) ~= "string" or not c:match("^[%w_%-][%w_%-%./]*$") or
							c:find("%.%.") or c:find("//") or c:sub(-1) == "/" then
						log:warning("launcher "..from..": world_packages.code: "..
								"a "..type(c).." that is not a path in a save")
						code = nil
						break
					end
					code[#code + 1] = c
				end
				-- The save's rows that are per player, "<store>/<key>" in
				-- save.sqlite: left out of what is published
				local rows = code and {}
				for _, r in ipairs(code and type(wp.player_rows) == "table" and
						wp.player_rows or {}) do
					if type(r) ~= "string" or not r:match("^[%w_]+/[^%c]+$") then
						log:warning("launcher "..from..": world_packages."..
								"player_rows: a "..type(r).." that is not "..
								"<store>/<key>")
						code, rows = nil, nil
						break
					end
					rows[#rows + 1] = r
				end
				M.world_packages[app] = code and {code = code,
						player_rows = rows} or false
				if code then
					M.for_save[#M.for_save + 1] = {app = app, id = "publish_world",
						label = "Publish this world",
						description = "Publish this save on an Aitta, for " ..
								"others to install as a world of their own",
						run = function(save)
							local ok, aitta = pcall(require, "buildat/core/aitta")
							if ok and type(aitta) == "table" then
								aitta.publish_world(app, save, code, rows)
							end
						end}
				end
			end
		elseif source.kind == "dev" or source.kind == "installed" or
				source.kind == "review" then
			-- [APP_REMIX] A remix carries no launcher, which is code: one
			-- tile, its name
			local f = io.open(source.path .. "/meta.json", "rb")
			local m = f and __buildat_parse_json(f:read("*a"))
			if f then f:close() end
			if type(m) == "table" and m.kind == "remix" then
				actions = {{id = "play", label = tostring(m.name),
					description = "A version of " .. tostring(m.base),
					run = function()
						do_launch(log, from, {app = source.kind == "dev" and
								"dev:" .. source.name or source.name})
					end}}
			end
		end
		-- **A save stays with the version that made it**, and moves to
		-- another when the player says so: this tile is the saying
		if source.kind == "installed" and actions and actions[1] and
				versions[source.name:match("^(.-)@")] > 1 then
			local first = actions[1]
			actions[#actions + 1] = {id = "move_saves",
				label = tostring(first.label) .. " " ..
						source.name:match("@(.*)$") .. ": move saves here",
				description = "Play this version, moving the saves another " ..
						"version made to it",
				run = function()
					do_launch(log, from, {app = source.name,
						params = {aitta_move_saves = 1}})
				end}
		end
		-- **"Make my own version"** ([APP_REMIX]) of an app that declares
		-- settings in its meta.json: a remix of it in dev_apps, its page
		-- opened (client/core/aitta/publish.lua)
		if (source.kind == "app" or source.kind == "installed") and actions and
				actions[1] then
			local f = io.open(source.path .. "/meta.json", "rb")
			local m = f and __buildat_parse_json(f:read("*a"))
			if f then f:close() end
			if type(m) == "table" and type(m.settings) == "table" and
					m.settings[1] and m.base == nil and (m.kind == nil or
					m.kind == "app") then
				actions[#actions + 1] = {id = "remix",
					label = tostring(actions[1].label) ..
							": make my own version",
					description = "A version of your own: its settings and " ..
							"files, played here and published on an Aitta",
					category = "action",
					run = function()
						local ok, aitta = pcall(require, "buildat/core/aitta")
						if ok and type(aitta) == "table" then
							aitta.make_remix(source.name)
						end
					end}
			end
		end
		-- **A playtest** ([AITTA_REVIEW]): unreviewed, from its Aitta, and
		-- there until removed
		if source.kind == "review" and actions and actions[1] then
			local f = io.open(source.path .. "/.aitta_from", "rb")
			local aitta = f and f:read("*l") or "?"
			if f then f:close() end
			for _, a in ipairs(actions) do
				a.description = "Playtest, unreviewed, from " .. aitta
			end
			actions[#actions + 1] = {id = "remove",
				label = tostring(actions[1].label) .. " " ..
						source.name:match("@(.*)$") .. ": remove",
				description = "Remove this playtest from the grid",
				category = "action",
				run = function()
					local ok, why = __buildat_remove_review(source.name)
					log:info("playtest: removed " .. source.name .. ": " ..
							tostring(ok or why))
					local menu = buildat.menu_extension()
					if menu and type(menu.refresh) == "function" then
						menu.refresh()
					end
				end}
		end
		-- **Report...** on a release from an Aitta, to that Aitta, and the
		-- note of its delisting there ([AITTA_REPORTS])
		if (source.kind == "installed" or source.kind == "review") and
				actions and actions[1] then
			local function read(name)
				local f = io.open(source.path .. "/" .. name, "rb")
				local s = f and f:read("*a")
				if f then f:close() end
				return s
			end
			local note = read(".aitta_delisted")
			if note then
				for _, a in ipairs(actions) do
					a.description = "Delisted by its Aitta: " .. note
				end
			end
			local aitta = (read(".aitta_from") or ""):match("^(https?://%S+)")
			local author, name, version = source.name:gsub("^review:", ""):
					match("^([%w_]+)%.([%w_]+)@(.+)$")
			local ok, aitta_ext = pcall(require, "buildat/core/aitta")
			if aitta and author and ok and type(aitta_ext) == "table" then
				actions[#actions + 1] = {id = "report",
					label = tostring(actions[1].label) .. " " .. version ..
							": report...",
					description = "Report this release to " .. aitta,
					category = "action",
					run = function()
						aitta_ext.report_release(aitta, author .. "/" .. name ..
								"/" .. version)
					end}
			end
		end
		-- **"Feedback..." to the app's home Hearth** ([PACKAGE_SUBJECT]),
		-- the package and versions filled in there
		local home = source.kind == "installed" and actions and actions[1] and
				feedback_target(source)
		if home then
			actions[#actions + 1] = {id = "feedback",
				label = tostring(actions[1].label) .. " " ..
						source.name:match("@(.*)$") .. ": feedback...",
				description = "Tell the app's makers about it, at " ..
						home.url,
				run = function()
					buildat.set_feedback(home)
					M.screens().connect(home.address)
				end}
		end
		local seen = {}
		for i, a in ipairs(actions or {}) do
			if type(a) ~= "table" or type(a.label) ~= "string" or
					type(a.run) ~= "function" then
				log:warning("launcher "..from..": action "..i..
						" has no label or run; skipped")
			elseif a.id ~= nil and seen[a.id] then
				log:warning("launcher "..from..": duplicate id "..
						tostring(a.id).."; first wins")
			elseif a.for_save then
				-- simplified: an app's own (kind "app") only; an installed
				-- release's saves are under its versioned name
				if a.id ~= nil then seen[a.id] = true end
				if source.kind == "app" then
					local run = a.run
					M.for_save[#M.for_save + 1] = {app = source.name,
						id = tostring(a.id or i), label = a.label,
						description = type(a.description) == "string" and
								a.description or nil,
						run = function(save)
							local ok, err = pcall(run, save)
							if not ok then
								log:warning("launcher "..from..": "..tostring(err))
							end
						end}
				end
			else
				if a.id ~= nil then seen[a.id] = true end
				local icon = ICON_FALLBACK
				if a.resolved_icon then
					icon = a.icon
				elseif source.kind == "installed" or source.kind == "dev" or
						source.kind == "review" then
					-- [PACKAGE_MEDIA] Its manifest's icon, copied under the
					-- cache by list_launchers(); none, the fallback
					icon = source.icon or ICON_FALLBACK
				elseif type(a.icon) == "string" and
						not a.icon:find("[/\\]") then
					-- Resolved here, never by the file: <name>/launcher/<icon>
					-- under the kind's resource dir, so two launchers with an
					-- icon.png do not collide
					icon = source.name.."/launcher/"..a.icon
				end
				local run = a.run
				out[#out + 1] = {
					id = a.id, icon = icon,
					-- Every installed version is a tile, and says which
					label = ((source.kind == "installed" or source.kind ==
							"review") and a.id ~= "move_saves" and
							a.id ~= "remove") and
							a.label.." "..source.name:match("@(.*)$") or a.label,
					description = type(a.description) == "string" and
							a.description or nil,
					order = tonumber(a.order),
					kind = source.kind, from = from,
					category = category_of(a) or
							((source.kind == "app" or source.kind == "installed" or
							source.kind == "dev" or source.kind == "review") and
							"app" or "action"),
					significance = significance_of(a, source, app_sizes),
					network = short_name(a.network),
					listed_by = short_name(a.listed_by),
					section = short_name(a.section),
					run = function()
						local ok, err = pcall(run)
						if not ok then
							log:warning("launcher "..from..": "..tostring(err))
						end
					end,
				}
			end
		end
	end
	-- [WEB_LOCAL_SERVER] On a page with no game, the apps beside it that
	-- run with a server of their own in the page: each goes to
	-- ?local=<app>
	for app in (__buildat_get_env("BUILDAT_WEB_LOCAL_APPS") or ""):gmatch(
			"[A-Za-z0-9_]+") do
		out[#out + 1] = {id = "play", label = app, kind = "web_local",
			from = "web_local/" .. app, category = "app",
			icon = "own:launch_menu/res/icon_local.png",
			description = "Runs in this page with a server of its own: " ..
					"a game for one, its saves kept in the browser",
			run = function() __buildat_web_go_local(app) end}
	end
	table.sort(out, function(a, b)
		if (a.order ~= nil) ~= (b.order ~= nil) then
			return a.order ~= nil
		end
		if a.order ~= nil and a.order ~= b.order then
			return a.order < b.order
		end
		if KIND_ORDER[a.kind] ~= KIND_ORDER[b.kind] then
			return KIND_ORDER[a.kind] < KIND_ORDER[b.kind]
		end
		return a.label < b.label
	end)
	return out
end

return M
-- vim: set noet ts=4 sw=4:
