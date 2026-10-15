-- Buildat: client/api.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/api")

buildat.connect_server    = __buildat_connect_server
-- The connect on a worker, polled from a frame handler: the blocking one
-- froze the waiting screen for as long as the connect took
-- ([BOX_PLAYTEST_2] 12)
buildat.connect_server_start = __buildat_connect_server_start
buildat.connect_server_poll  = __buildat_connect_server_poll
buildat.list_apps        = __buildat_list_apps
-- list_saves([app]) -> {{app=, name=, modified=}, ...}, newest first.
-- The saves on disk, enumerated without a server, since a launcher has
-- none to ask ([LAUNCH_WORLD]).
buildat.list_saves        = __buildat_list_saves
-- list_launchers() -> {{kind, name, path, launcher = bool}, ...}: every
-- game, builtin and extension in the tree, for the launch grid
buildat.list_launchers    = __buildat_list_launchers
-- list_installed_games(app) -> {{name =, size =, icon =}, ...} under
-- <user>/shared/<app>/games ("vanilla": the Luanti games); read-only, and in the sandbox too, for a launcher
-- file's tiles. icon is the resource name of the game's own menu/icon.png
-- where it ships one, and absent where it does not ([LAUNCH_API])
buildat.list_installed_games = __buildat_list_installed_games
buildat.safe.list_installed_games = __buildat_list_installed_games
buildat.start_local_server = __buildat_start_local_server
buildat.stop_local_server = __buildat_stop_local_server
buildat.request_stop_local_server = __buildat_request_stop_local_server
buildat.force_kill_local_server = __buildat_force_kill_local_server
buildat.local_server_ready = __buildat_local_server_ready
buildat.local_server_port = __buildat_local_server_port
buildat.local_server_running = __buildat_local_server_running
-- The last STATUS line of the local server's log, and its tail for a
-- dialog about one that died ([START_PROGRESS])
buildat.local_server_status = __buildat_local_server_status
buildat.local_server_log_tail = __buildat_local_server_log_tail
buildat.extension_path    = __buildat_extension_path
buildat.get_time_us       = __buildat_get_time_us
buildat.version           = __buildat_version
-- [COMPAT_BREAK_07] 8a: the engine API, and has(name) for what a patch
-- release added to the protocol behind a name (interface/protocol.h)
local protocol_features
buildat.api, protocol_features = __buildat_protocol()
function buildat.has(name)
	return protocol_features[name] == true
end
buildat.sha1              = __buildat_sha1
buildat.sha256            = __buildat_sha256
buildat.qr_code           = __buildat_qr_code
buildat.hex               = __buildat_hex
buildat.random_bytes      = __buildat_random_bytes
-- compress(data, format [, level]) -> string, where format is "zlib" or "zstd"
-- decompress(data, format) -> data, bytes_consumed
buildat.compress          = __buildat_compress
buildat.decompress        = __buildat_decompress
-- Big-endian byte strings in, byte strings out
buildat.bignum = {
	add     = __buildat_bignum_add,
	mul     = __buildat_bignum_mul,
	mod     = __buildat_bignum_mod,
	sub_mod = __buildat_bignum_sub_mod,
	mul_mod = __buildat_bignum_mul_mod,
	mod_exp = __buildat_bignum_mod_exp,
}
buildat.set_ui_scale      = __buildat_set_ui_scale
buildat.get_ui_scale      = __buildat_get_ui_scale
buildat.logical_size      = __buildat_logical_size
-- The fraction of the window size the user asked 3D viewports to be rendered
-- at. magic.set_preferred_viewports() applies it; this is for a game that
-- wants to know. 1.0 means no scaling at all.
buildat.get_preferred_render_scale = __buildat_get_preferred_render_scale
-- The preferences the user sets once and every game honours. The C++ side is
-- the authority: it parses and range checks a value through the same code -o
-- goes through, applies what takes effect now, and persists the rest. A
-- screen over these is a page of widgets that knows nothing about the file.
--
-- list_preferences() -> {name, ...}
-- get_preference(name) -> number or boolean, nil for a name there is none by
-- set_preference(name, value) -> true, or false and why
buildat.list_preferences  = __buildat_list_preferences
buildat.get_preference    = __buildat_get_preference
buildat.set_preference    = __buildat_set_preference
buildat.font_sans         = "Fonts/Overpass-Regular.ttf"
buildat.font_mono         = "Fonts/OverpassMono-Regular.ttf"
buildat.SpatialUpdateQueue = __buildat_SpatialUpdateQueue
buildat.pack_voxel_volume = __buildat_pack_voxel_volume
-- add_resource_dir(path) -> bool. Only under the cache path; Urho3D's own Lua
-- bindings do not have this.
buildat.add_resource_dir  = __buildat_add_resource_dir
-- take_screenshot() -> the file name it was saved under, or nil and why not.
-- Into <user>/screenshots, named by the date and the time; see
-- l_take_screenshot() in src/client/app.cpp for why this is in the sandbox.
buildat.take_screenshot   = __buildat_take_screenshot
-- save_file, exported_files, read_exported, pick_file, picked_file: files a
-- game hands the user and takes from them; buildat.safe's below has no
-- listing or reading of <user>/exports
buildat.save_file         = __buildat_save_file
buildat.exported_files    = __buildat_exported_files
buildat.read_exported     = __buildat_read_exported
buildat.pick_file         = __buildat_pick_file
buildat.picked_file       = __buildat_picked_file
-- dump_meshes([atlas_json], [node]) -> the file name, or nil and why not. Same sandbox rule
-- as take_screenshot: into <user>/meshdumps, named by the date. The
-- scene's CustomGeometry in world space, which is what the client already
-- drew. See l_dump_meshes() in src/client/app.cpp.
buildat.dump_meshes       = __buildat_dump_meshes
-- compose_image(args) -> w, h. Raster operations over an RGBA canvas, saved as
-- a PNG under the cache path. See doc/client_api.txt.
buildat.compose_image     = __buildat_compose_image
-- read_image(resource_name) -> w, h, rgba. The pixels of an image, for
-- whoever has to look at them rather than draw them.
buildat.read_image        = __buildat_read_image
buildat.get_env           = __buildat_get_env
buildat.create_directories = __buildat_create_directories -- unsafe only
buildat.set_watchdog_seconds = __buildat_set_watchdog_seconds -- unsafe only

buildat.safe.disconnect    = __buildat_disconnect
buildat.safe.set_reload_on_return = __buildat_set_reload_on_return
buildat.safe.set_web_fullscreen = __buildat_set_web_fullscreen
-- **The extension this client was booted with as its launcher**, which
-- is -m's argument and launch_menu by default. What asks is whatever has
-- to go back to the launcher; those places named launch_menu outright,
-- which is wrong the moment the client is booted with another one.
-- Loaded only if it already is: this never boots a launcher by itself.
-- **A sandboxed launch UI is not in the trusted table of loaded
-- extensions** ([LAUNCH_SANDBOX]): its init.lua is run through the
-- sandbox's own loader, so `__buildat_loaded_extension` answers nil for
-- it and every caller that asked for the launcher got nothing. What
-- that cost: a game's own "back to the launcher" fell through to a
-- plain disconnect, and the client sat with no server and no room --
-- [FIRST_RUN]'s ContentDB run has been failing on exactly that
-- (2026-09-24). So a sandboxed launch UI hands its interface over as it
-- boots, and this is where it is kept.
local launch_ui_interface = nil
-- The three the client and a game's own menu call ([MENU_CONTEXT]);
-- anything else in the table is ignored rather than refused, since a
-- launch UI's module is its own and may hold whatever it likes.
local LAUNCH_INTERFACE = {entered_app = true, leave_app = true,
	in_app = true, show_dead_server = true, app_loading = true,
	-- [AITTA_MVP]: the grid drawn again after an install
	refresh = true}
-- **Merged, not replaced**, because a launch UI may be a composition
-- ([TWO_AUDIENCES]: the menu over the room). The composing extension's
-- own module usually has none of these -- it boots two others and that
-- is all -- so a replace would wipe what the composed ones gave and
-- leave the same dead client this was written to fix. Last one with a
-- function wins, which is the menu over the room: the menu is what a
-- game is launched from, so the menu is what it comes back to.
buildat.safe.provide_launch_interface = function(t)
	if type(t) ~= "table" then
		return false, "provide_launch_interface(t): a table"
	end
	launch_ui_interface = launch_ui_interface or {}
	for name in pairs(LAUNCH_INTERFACE) do
		if type(t[name]) == "function" then
			launch_ui_interface[name] = t[name]
		end
	end
	return true
end

-- **A game says when it stops being a menu and starts being a world**
-- ([LAUNCH_API]'s fourth ask, user 2026-09-28). A game launched into a
-- menu of its own -- vanilla's save list, its server screen -- is on the
-- screen for as long as the player takes to choose, and a launch UI that
-- paused an animation for it has no way of knowing when the choosing is
-- over. The heuristics it has are the viewport handover and the local
-- server coming up, and both are late and neither says which happened.
--
-- launch_loading(what): `what` is "world" or "server", anything else is
-- refused. Nothing but the launch UI hears it, and a launch UI that
-- provides no `app_loading` is not an error -- most will not want one.
buildat.safe.launch_loading = function(what)
	if what ~= "world" and what ~= "server" then
		return false, 'launch_loading(what): "world" or "server"'
	end
	log:info("launch: the game is loading a " .. what)
	local m = buildat.menu_extension()
	if m and m.app_loading then
		m.app_loading(what)
	end
	return true
end

function buildat.menu_extension()
	local name = __buildat_menu_extension_name or "launch_menu"
	return __buildat_loaded_extension(name) or launch_ui_interface
end
-- leave(): back to the launcher's grid when there is one under the game
-- ([MENU_CONTEXT]: the game's own menu offers it), else what disconnect
-- does -- a client started straight into a server has nothing to go back to
-- [LEAVE_WITH_REASON]: why the server is about to drop this client, a
-- kick's text (builtin/accounts), said when it has
local leave_reason = nil
-- What runs, for the overlay's Discuss ([OVERLAY_DISCUSS], below)
local local_launch, running_game = nil, nil
buildat.safe.set_leave_reason = function(text)
	leave_reason = tostring(text)
end
-- [TAP_BACK] The main stack's depth for the web page's Back, and what an
-- app adds to it ([PLAYTEST_1008]): screens of its own inside one of the
-- main stack's, so Back is Escape while it has one to go back from
local back_depth, back_extra = 0, 0
buildat.set_back_depth = function(n)
	back_depth = n
	__buildat_set_back_depth(back_extra > 0 and
			math.max(back_depth, 1) + back_extra or back_depth)
end
buildat.safe.set_back_depth_extra = function(n)
	back_extra = math.max(0, math.floor(tonumber(n) or 0))
	buildat.set_back_depth(back_depth)
end
-- [HEARTH_WEB_BACK] leave_web_page(go) -> on the web, whether there is a
-- page before this one, and with go, back to it (the browser's Back past
-- the page's own entries); nil natively
buildat.safe.leave_web_page = function(go)
	return __buildat_leave_web_page(go and true or false)
end
-- Back to the launcher, true when there was one to go back to; `why`, a
-- dialog over it. A launcher with no game running under it (a client
-- started straight into a server) answers false
local function leave_to_launcher(why)
	-- simplified: an app's extra depth goes when it is left through here;
	-- another way out keeps it until the next app sets its own
	buildat.safe.set_back_depth_extra(0)
	local m = buildat.menu_extension()
	if not (m and m.leave_app and m.leave_app()) then
		return false
	end
	if why then
		require("buildat/extension/ui_utils").safe.show_message_dialog(why)
	end
	return true
end
-- Whether leave_to_launcher() would go anywhere, asked without leaving:
-- the test the launch UIs' leave_app makes. A client started straight
-- into a server (-s) has no game under a launcher.
local function launcher_under_game()
	local m = buildat.menu_extension()
	return m ~= nil and m.leave_app ~= nil and
			((m.in_app ~= nil and m.in_app() == true) or
			__buildat_local_server_running() == true)
end
-- The connection to a remote server went (src/client/app.cpp,
-- check_lost_connection): to the launcher with why, or false.
-- [SERVE_UPDATE_SMOOTH] 6: one that was not a kick is rejoined from
-- there -- at once when the server's goodbye said it restarts, else when
-- asked
function __buildat_leave_lost(lost, restarting)
	local kicked = leave_reason
	local address = __buildat_server_address()
	local why = kicked and "Left the server: " .. kicked or
			restarting and tostring(lost) or
			"Left the server: " .. tostring(lost)
	leave_reason = nil
	log:info("leave: " .. why .. "; to the launcher if there is one")
	if kicked or not address then
		return leave_to_launcher(why)
	end
	if not leave_to_launcher() then
		return false
	end
	__buildat_reconnect(address, why, restarting)
	return true
end
-- Whether leave() goes back to a launcher rather than disconnecting: an
-- app offers a way out only where there is one ([HEARTH_CLOSE])
buildat.safe.can_leave_to_launcher = function()
	return launcher_under_game()
end
buildat.safe.leave = function()
	leave_reason = nil
	if not leave_to_launcher() then
		-- **Said out loud, because the quiet version of this is a dead
		-- client**: with no launcher to go back to, leaving a game is a
		-- disconnect and whatever drew the game is gone with it. That is
		-- right for a client started straight into a server and wrong
		-- for one booted with a launcher, so which it was is worth a
		-- line in the log rather than a guess afterwards.
		log:info("leave: no launcher to go back to (" ..
				tostring(__buildat_menu_extension_name) ..
				"); disconnecting")
		__buildat_disconnect()
	end
end
--
-- **The launch UI's own verbs** ([LAUNCH_SANDBOX]). A launch extension
-- is a slot anybody can fill, so it has to be able to run in the
-- sandbox every game runs in -- and the rule that keeps this small is
-- that **the trusted side owns the verbs and the sandbox owns the
-- drawing**. Each of these does one nameable thing; none is a general
-- capability, because every addition here is attack surface for every
-- game as well.
--
-- launch_actions() -> the launch grid's tiles as plain data: no
-- functions, no paths to open, and the `key` is what launch() takes.
-- The list itself is built by sandboxed launcher files behind
-- `ctx.launch` already ([LAUNCH_GRID]), so this is one step further
-- out, not a new reach.
local launch_runs = {}
local save_runs = {} -- [SAVE_CONTEXT_MENU] key -> launch_grid.for_save's
local launch_grid = dofile(__buildat_get_path("share") ..
		"/client/launch_grid.lua")

-- **A launch history, kept once for every launch UI** ([LAUNCH_API]).
-- The API knew a save's modified time and nothing about what was
-- launched when, so each launcher that wanted "recently played" had to
-- keep a list of its own -- and a list per launcher is a list that
-- disagrees with the next one. One line per key in
-- <user>/launch_history.csv, "<unix seconds> <key>", and the oldest
-- dropped past the cap: what was launched when is not worth more than
-- a small file.
local LAUNCH_HISTORY_MAX = 200
local function launch_history_read()
	local out = {}
	local f = io.open(__buildat_get_path("user") .. "/launch_history.csv", "r")
	if not f then
		return out
	end
	for line in f:lines() do
		local t, key = line:match("^(%d+) (.+)$")
		if key then
			out[key] = tonumber(t)
		end
	end
	f:close()
	return out
end
local function launch_history_note(key)
	-- A key is written a line at a time, so one with a newline or a
	-- control character in it would write a line this cannot read back
	if key:find("%c") then
		return
	end
	local seen = launch_history_read()
	seen[key] = os.time()
	local rows = {}
	for k, t in pairs(seen) do
		rows[#rows + 1] = {k = k, t = t}
	end
	table.sort(rows, function(a, b)
		if a.t ~= b.t then return a.t > b.t end
		return a.k < b.k
	end)
	local f = io.open(__buildat_get_path("user") .. "/launch_history.csv", "w")
	if not f then
		log:warning("launch: cannot write the launch history")
		return
	end
	for i = 1, math.min(#rows, LAUNCH_HISTORY_MAX) do
		f:write(rows[i].t .. " " .. rows[i].k .. "\n")
	end
	f:close()
end

-- **A game or an app just installed is on the recent list**
-- ([INSTALLED_RECENT]): one this side has never seen in the list is noted
-- as launched now. A Luanti game, or an installed app's first action (its
-- own tile; not move_saves, not Feedback). The keys seen are one a line in
-- <user>/launch_seen.csv, an app's without its version, so a new version
-- is not new. With no such file every one there now is seen and none
-- noted: an upgrade of the client puts nothing on the list.
local function launch_note_installed(actions)
	local path = __buildat_get_path("user") .. "/launch_seen.csv"
	local seen, first_run = {}, true
	local f = io.open(path, "r")
	if f then
		first_run = false
		for line in f:lines() do
			seen[line] = true
		end
		f:close()
	end
	local froms, new = {}, {}
	for i, a in ipairs(actions) do
		local key = tostring(a.from) .. "/" .. tostring(a.id or i)
		local app = a.kind == "installed" and not froms[a.from]
		froms[a.from] = true
		if a.category == "game" or app then
			local id = key:gsub("^(installed/[^/@]*)@[^/]*", "%1")
			if not seen[id] then
				seen[id] = true
				new[#new + 1] = id
				if not first_run then
					launch_history_note(key)
				end
			end
		end
	end
	if #new == 0 and not first_run then
		return
	end
	f = io.open(path, "a")
	if not f then
		log:warning("launch: cannot write " .. path)
		return
	end
	for _, id in ipairs(new) do
		if not id:find("%c") then
			f:write(id .. "\n")
		end
	end
	f:close()
end

buildat.safe.launch_actions = function()
	local out = {}
	local actions = launch_grid.actions(log)
	launch_note_installed(actions)
	local history = launch_history_read()
	launch_runs = {}
	save_runs = {}
	for _, a in ipairs(launch_grid.for_save) do
		save_runs["save_action/" .. a.app .. "/" .. a.id] = a
	end
	for i, a in ipairs(actions) do
		local key = tostring(a.from) .. "/" .. tostring(a.id or i)
		launch_runs[key] = a.run
		out[i] = {key = key, id = a.id, label = a.label, icon = a.icon,
			kind = a.kind, from = a.from, description = a.description,
			order = a.order,
			-- What the action says about itself ([LAUNCH_SIGNIFY]): the
			-- category is an open set and the significance a number to
			-- rank and scale by within one. Both are plain data and both
			-- may be absent.
			category = a.category, significance = a.significance,
			-- What a server speaks and which list it came from, or
			-- absent ([SERVER_FILTER])
			network = a.network, listed_by = a.listed_by,
			-- When this key was last launched, in unix seconds, or
			-- absent for one that never was
			last_launched = history[key]}
	end
	return out
end
-- save_actions(app) -> what the app's launcher does to one of its saves
-- ([SAVE_CONTEXT_MENU]): {{key, label, description}}, for launch(key,
-- save); none of them a tile
buildat.safe.save_actions = function(app)
	if next(save_runs) == nil then
		buildat.safe.launch_actions()
	end
	local out = {}
	for key, a in pairs(save_runs) do
		if a.app == app then
			out[#out + 1] = {key = key, label = a.label,
				description = a.description}
		end
	end
	table.sort(out, function(x, y) return x.key < y.key end)
	return out
end
-- launch(key[, save]): run one of them. The key is looked up in the table
-- the trusted side built, so a sandbox cannot name anything that is not
-- on the grid, and it never hands a function across. A save action's
-- save is one list_saves(app) answers, as launch_save's.
buildat.safe.launch = function(key, save)
	if type(key) ~= "string" then
		return false, "launch(key): a string from launch_actions()"
	end
	local sa = save_runs[key]
	if sa then
		for _, sv in ipairs(__buildat_list_saves(sa.app)) do
			if sv.name == save then
				sa.run(save)
				return true
			end
		end
		return false, "launch(" .. key .. "): no save " .. tostring(save) ..
				" of " .. sa.app
	end
	local run = launch_runs[key]
	if not run then
		return false, "launch(" .. key .. "): no such action"
	end
	launch_history_note(key)
	run()
	return true
end
-- **Its own persistent storage**, one directory per launch extension
-- under the user path: `storage_read(name)` and `storage_write(name,
-- data)`. A name is one file, not a path -- no slashes, no dots on
-- their own -- so a launcher writes where it is put and nowhere else,
-- and the size is capped because a slot anybody can fill is a slot
-- anybody can fill a disk from.
local STORAGE_MAX = 4 * 1024 * 1024
-- And the names: a server's script writing a new one in a loop filled
-- the disk 4 MiB at a time ([SECURITY_RUN_1])
local STORAGE_FILES_MAX = 64

-- **Which extension is asking**, taken from the caller's chunk name
-- rather than from which launch UI the client booted. The two are the
-- same until one launch UI composes another ([TWO_AUDIENCES]' third
-- option): then the global says the composer and the code running says
-- the composed, and a room borrowed as a backdrop would read and write
-- the composer's storage and load the composer's files. Every chunk
-- these verbs can be called from is named "<extension>/<file>" by the
-- loader that ran it, which is what this reads.
local function calling_extension(level)
	local info = debug.getinfo(level or 3, "S")
	local src = info and info.source or ""
	-- **A sandboxed chunk** is named `<extension>/<file>` by the loader
	-- that ran it
	local name = src:match("^@?([%w_]+)/[%w_%-%.]+$") or
			src:match("^@?([%w_]+)/[%w_%-]+/[%w_%-%.]+$")
	if name then
		return name
	end
	-- **And a trusted one is a path on disk**, which is what an
	-- extension required by another extension is: the menu, required
	-- by another, asked for its `preferences.lua` in the other's
	-- directory, found nothing, answered nil, and the client aborted
	-- eighty lines later ([MENU_FALLBACK], 2026-09-23). The same fault
	-- the composition found, in the other direction.
	name = src:match("[/\\]extensions[/\\]([%w_]+)[/\\]")
	if name then
		return name
	end
	return __buildat_menu_extension_name or "launch_menu"
end

-- The chunks servers served, by name (sandbox.lua's run_script_file)
__buildat_served_chunks = {}

-- Whose storage a call is in: "server" for game code a server sent, or the
-- launch extension's name. 1 is this, 2 the verb, 3 who called it.
local function storage_domain()
	local info = debug.getinfo(3, "S")
	if __buildat_served_chunks[info and info.source or ""] then
		return "server"
	end
	return calling_extension(4)
end

-- The user dir's own directories, which no extension's storage was
local storage_not_moved = {apps = true, servers = true, installed = true,
	shared = true, screenshots = true, exports = true, extensions = true}
local storage_moved = {}
local function storage_path(name, domain)
	if type(name) ~= "string" or not name:match("^[%w_%-%.]+$") or
			name:find("%.%.") then
		return nil, "storage: a name of letters, digits, _ - and ."
	end
	-- **Game code a server sent** keeps its things where the server's
	-- game_storage_dir() says, like a web page's localStorage: a game
	-- started here has its game's, anything else its address's. A server's
	-- chunks have a buildat of their own that says so (sandbox.lua's
	-- __buildat_run_served_code); a launch extension is told by its
	-- chunk's name.
	if domain == "server" then
		local dir = __buildat_game_storage_dir()
		if not dir then
			return nil, "storage: not connected to a server"
		end
		return dir .. "/" .. name, dir
	end
	if not domain:match("^[%w_]+$") then
		return nil, "storage: the launch extension has an odd name"
	end
	local dir = __buildat_get_path("user") .. "/extensions/" .. domain
	if not storage_moved[domain] then
		storage_moved[domain] = true
		-- 0.6 kept it at user/<extension>/ ([COMPAT_BREAK_07] 8i); moved
		-- once. With both there, the new one is used and the old one left
		local old = __buildat_get_path("user") .. "/" .. domain
		if not storage_not_moved[domain] and
				__buildat_count_files(old) > 0 then
			if __buildat_count_files(dir) > 0 then
				log:warning("storage: " .. old .. " is 0.6's and " .. dir ..
						" is there too; " .. dir .. " is used, " .. old ..
						" left as it is")
			else
				__buildat_create_directories(__buildat_get_path("user") ..
						"/extensions")
				local ok, err = os.rename(old, dir)
				if ok then
					log:info("storage: moved 0.6's " .. old .. " to " .. dir)
				else
					log:warning("storage: could not move 0.6's " .. old ..
							" to " .. dir .. ": " .. tostring(err))
				end
			end
		end
	end
	return dir .. "/" .. name, dir
end
local function storage_read_in(name, domain)
	local path = storage_path(name, domain)
	if not path then
		return nil
	end
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end
local function storage_write_in(name, data, domain)
	local path, dir = storage_path(name, domain)
	if not path then
		return false, dir
	end
	if type(data) ~= "string" then
		return false, "storage_write(name, data): data is a string"
	end
	if #data > STORAGE_MAX then
		return false, "storage_write: " .. #data .. " bytes is over the " ..
				STORAGE_MAX .. " a launcher may keep"
	end
	local old = io.open(path, "rb")
	if old then
		old:close()
	elseif __buildat_count_files(dir) >= STORAGE_FILES_MAX then
		return false, "storage_write: " .. STORAGE_FILES_MAX ..
				" names are kept already"
	end
	__buildat_create_directories(dir)
	local f = io.open(path, "wb")
	if not f then
		return false, "storage_write: could not open " .. name
	end
	f:write(data)
	f:close()
	return true
end
buildat.safe.storage_read = function(name)
	local domain = storage_domain()
	return storage_read_in(name, domain)
end
buildat.safe.storage_write = function(name, data)
	local domain = storage_domain()
	return storage_write_in(name, data, domain)
end

-- **What a server's chunks get instead** ([SECURITY_RUN_1]): the gates
-- below read the calling frame, and a tail call or a verb passed as a
-- callback leaves no frame of the server's to read -- `return
-- buildat.set_preference(...)` at a chunk's top set any preference. So a
-- chunk a server sent is run with a buildat of its own
-- (sandbox.lua's __buildat_run_served_code), in which the user's verbs
-- refuse whoever is on the stack and storage is the server's.
local function refused(verb)
	return function()
		return false, verb .. ": the user's, not a server's"
	end
end
__buildat_served_overrides = {
	set_preference = refused("set_preference"),
	start_local_server = refused("start_local_server"),
	stop_local_server = refused("stop_local_server"),
	launch = refused("launch"),
	launch_save = refused("launch_save"),
	join_server = refused("join_server"),
	show_engine_settings = refused("show_engine_settings"),
	show_key_settings = refused("show_key_settings"),
	log_path = function() return nil end,
	open_log_folder = refused("open_log_folder"),
	recent_errors = function() return nil end,
	set_shared_key = refused("set_shared_key"),
	set_client_key = refused("set_client_key"),
	key_store = function() return nil end,
	set_launch_ui = refused("set_launch_ui"),
	compose_launch_ui = refused("compose_launch_ui"),
	cache_read = function() return nil end,
	cache_write = refused("cache_write"),
	storage_read = function(name)
		return storage_read_in(name, "server")
	end,
	storage_write = function(name, data)
		return storage_write_in(name, data, "server")
	end,
}

-- **An extension's cache** ([EXTENSIONS_SANDBOXED]): files under
-- <cache>/<extension>/, which is also a place add_resource_dir() takes,
-- so what is written can be loaded by name. A name is up to three
-- segments of letters, digits, _ - and . ("server/composed/x.png").
-- simplified: a cap per file and none on the whole; compose_image()
-- already writes under the cache without one.
local CACHE_FILE_MAX = 32 * 1024 * 1024
local function cache_path(name)
	if type(name) ~= "string" or #name > 256 or name:find("%.%.") or
			not (name:match("^[%w_%-%.]+$") or
				name:match("^[%w_%-%.]+/[%w_%-%.]+$") or
				name:match("^[%w_%-%.]+/[%w_%-%.]+/[%w_%-%.]+$")) then
		return nil, "cache: a name of up to three segments of letters, " ..
				"digits, _ - and ."
	end
	-- 1 is this, 2 cache_read or cache_write, 3 who called that. **Not
	-- a server's**: a module named like an extension would be writing
	-- that extension's media.
	local info = debug.getinfo(3, "S")
	if __buildat_served_chunks[info and info.source or ""] then
		return nil, "cache: an extension's, not a server's"
	end
	local who = calling_extension(4)
	local root = __buildat_get_path("cache") .. "/" .. who
	local path = root .. "/" .. name
	return path, path:match("^(.*)/[^/]+$")
end
buildat.safe.cache_read = function(name)
	local path = cache_path(name)
	if not path then
		return nil
	end
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end
buildat.safe.cache_write = function(name, data)
	local path, dir = cache_path(name)
	if not path then
		return false, dir
	end
	if type(data) ~= "string" then
		return false, "cache_write(name, data): data is a string"
	end
	if #data > CACHE_FILE_MAX then
		return false, "cache_write: " .. #data .. " bytes is over the " ..
				CACHE_FILE_MAX .. " a file may have"
	end
	__buildat_create_directories(dir)
	local f = io.open(path, "wb")
	if not f then
		return false, "cache_write: could not open " .. name
	end
	f:write(data)
	f:close()
	return true
end

-- **Connecting to a server**, which a launcher does on a worker and
-- polls from a frame handler: the blocking one freezes the frame for as
-- long as it takes ([BOX_PLAYTEST_2] 12). An address is a string and
-- the client is what parses it.
local feedback = nil
buildat.safe.connect_start = function(address)
	if type(address) ~= "string" or #address > 256 then
		return false, "connect_start(address): a string"
	end
	if feedback and feedback.address ~= address then
		feedback = nil
	end
	-- What a server's code said of its game was that server's
	if running_game and not running_game.leave then
		running_game = nil
	end
	__buildat_connect_server_start(address)
	return true
end
-- **JSON, because a body fetched is a body to read** ([URHO_SWEEP],
-- 2026-09-25): `network.http_get` hands a game a string and the sandbox
-- had nothing to parse it with. The answer is plain Lua -- tables,
-- strings, numbers, booleans -- parsed by the client's own reader, so
-- nothing holds a C++ object. A JSON null becomes nil, which in an
-- array leaves a hole; a document nests 64 deep at most.
-- parse_json(text) -> value, or nil and why not
buildat.safe.parse_json = function(text)
	if type(text) ~= "string" then
		return nil, "parse_json(text): a string"
	end
	return __buildat_parse_json(text)
end
buildat.safe.connect_poll = __buildat_connect_server_poll
-- **"Feedback..." on an installed app** ([PACKAGE_SUBJECT]): the grid
-- (trusted) sets what the user is about to tell the app's home Hearth
-- and connects there; the Hearth's client takes it once -- the package,
-- its version, this engine's and the platform, nothing else. A connect
-- to another address drops it.
buildat.set_feedback = function(f)
	feedback = f
end
-- feedback() -> {subject, package, version, engine, platform, place} or
-- nil; place: open the package's threads ("Discuss" on Aitta's list), not
-- the composer
buildat.safe.feedback = function()
	local f = feedback
	-- A server's or a game's is discussed()'s: a Hearth from before it
	-- read this one as a package's and could not draw it
	if f and (f.server or f.game or f.bind) then
		return nil
	end
	feedback = nil
	return f and {subject = f.subject, package = f.package,
			version = f.version, engine = f.engine, platform = f.platform,
			place = f.place == true}
end

-- **"Discuss (leave server)"** ([DISCUSS_SERVER]): the server being
-- played, on a Hearth -- its thread, or a new one filled in. Where it
-- goes and what it says are this side's. On a Buildat server: what a
-- Starport's kept list says of the address connected to, whatever the
-- server's code passes, and the listing Starport's Hearth. With no
-- Buildat server the caller is the client's own luanti_client, and claim
-- is a Luanti server it joined off Luanti's list, {name =, address =};
-- the Hearth is the first one a Starport recommends. Only for a player
-- logged in to a Starport ID, whom the Hearth's login then takes.
local DISCUSS_NAME_MAX = 60
local function discuss_target(claim)
	local ok, starport = pcall(require, "buildat/core/starport")
	if not ok or type(starport) ~= "table" or
			#starport.logged_in_ids() == 0 then
		return nil, "not logged in to a Starport ID"
	end
	local name, host, port, hearth
	if __buildat_server_address() then
		if not launcher_under_game() then
			return nil, "no launcher to go back to"
		end
		local l = starport.listing_here()
		if not l then
			return nil, "no Starport lists this server"
		end
		name, host, port = l.name, l.host, l.port
		hearth = starport.recommended_hearth(l.starport) or
				starport.safe.fallback_hearth()
	else
		if type(claim) ~= "table" or type(claim.name) ~= "string" or
				type(claim.address) ~= "string" or #claim.address > 256 then
			return nil, "discuss_this_server({name =, address =})"
		end
		name = claim.name
		local a = claim.address
		if a:sub(1, 1) == "[" then
			host, port = a:match("^%[(.-)%]:?(%d*)$")
		else
			host, port = a:match("^([^:]*):?(%d*)$")
		end
		-- Luanti's own default
		port = tonumber(port) or 30000
		hearth = starport.safe.fallback_hearth()
	end
	if not host or host == "" or host:find("[%c%s]") then
		return nil, "no address"
	end
	local address = (host:find(":") and "[" .. host .. "]" or host) .. ":" ..
			port
	local hearth_address = hearth and launch_grid.hearth_address(hearth)
	if not hearth_address then
		return nil, "no Starport recommends a Hearth"
	end
	-- The owner's text, which only fills a form the player edits.
	-- simplified: a cut through a character drops the whole of it
	name = name:gsub("%c", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
	if #name > DISCUSS_NAME_MAX then
		name = name:sub(1, DISCUSS_NAME_MAX):gsub("[\192-\255][\128-\191]*$",
				"") .. "..."
	end
	return {name = name, address = address, hearth = hearth_address,
		subject = "server:" .. host:lower() .. ":" .. port,
		title = name ~= "" and name .. " [" .. address .. "]" or address}
end
-- can_discuss_this_server(claim) -> whether the button has somewhere to go
buildat.safe.can_discuss_this_server = function(claim)
	return discuss_target(claim) ~= nil
end
-- discuss_this_server(claim) -> true, or false and why: the game left
-- (luanti_client leaves its own first), and the Hearth joined a frame
-- on, out of the button's handler
buildat.safe.discuss_this_server = function(claim)
	local t, why = discuss_target(claim)
	if not t then
		return false, why
	end
	if __buildat_server_address() then
		leave_reason = nil
		if not leave_to_launcher() then
			return false, "no launcher to go back to"
		end
	end
	feedback = {address = t.hearth, server = {name = t.name,
		address = t.address, subject = t.subject, title = t.title}}
	log:info("discuss: " .. t.subject .. " on " .. t.hearth)
	local magic = require("buildat/core/urho3d").safe
	local sub
	sub = magic.SubscribeToEvent("Update", function()
		magic.UnsubscribeFromEvent("Update", sub)
		require("buildat/core/starport").join_with_id(t.hearth)
	end)
	return true
end
-- **"Bind on <Aitta>..."** ([AITTA_PUBLISH_UI]): the publish screen
-- (trusted) sets the author name and public key it made, with the
-- Aitta's address, and joins it; the Aitta's page takes them once to
-- fill its Bind form. aitta_bind() -> {author, key} or nil
buildat.safe.aitta_bind = function()
	local f = feedback
	if not (f and f.bind) then
		return nil
	end
	feedback = nil
	return {author = tostring(f.bind.author), key = tostring(f.bind.key)}
end
-- **A reviewer's playtest** ([AITTA_REVIEW]): offer_playtest{release =
-- "author/name/version", ticket =, sha256 =}, from an Aitta's review page,
-- leaves to the launcher, which asks the player in its own dialog
-- (client/core/aitta playtest()) before it fetches the release by
-- the ticket from the Aitta this client is on and installs it apart. The
-- page only offers: nothing is installed without the yes. -> true, or
-- false and why
buildat.safe.offer_playtest = function(o)
	local address = __buildat_server_address()
	if type(o) ~= "table" or type(o.release) ~= "string" or
			not o.release:match("^[%w_]+/[%w_]+/[%w%.%-%+_]+$") or
			type(o.ticket) ~= "string" or not o.ticket:match("^%x+$") or
			type(o.sha256) ~= "string" or not o.sha256:match("^%x+$") then
		return false, "offer_playtest{release =, ticket =, sha256 =}"
	end
	if not address then
		return false, "not on an Aitta"
	end
	local url = address:match("^https?://") and address or
			address:gsub("^wss://", "https://"):gsub("^ws://", "http://")
	if not url:match("^https?://") then
		url = "http://" .. url
	end
	local offer = {aitta = url:gsub("/+$", ""), release = o.release,
		ticket = o.ticket, sha256 = o.sha256}
	leave_reason = nil
	if not leave_to_launcher() then
		return false, "no launcher to go back to"
	end
	log:info("playtest: offered " .. offer.release .. " from " .. offer.aitta)
	local magic = require("buildat/core/urho3d").safe
	local sub
	sub = magic.SubscribeToEvent("Update", function()
		magic.UnsubscribeFromEvent("Update", sub)
		require("buildat/core/aitta").playtest(offer, function(app)
			launch_grid.screens().start_local_app(app, "")
		end)
	end)
	return true
end

-- **The overlay's Discuss in a game** ([OVERLAY_DISCUSS]): the server
-- and the game, whichever are known, and the Hearth offers the choice.
-- What runs is the client's to know: the local app it started
-- (local_launch), or what a client of another kind running on the
-- launcher says through set_running_game -- luanti_client its leave,
-- the Official list's claim and the game id; vanilla its world's game.
local function from_served()
	-- 1 is this, 2 the verb, 3 who called it
	local info = debug.getinfo(3, "S")
	return info ~= nil and __buildat_served_chunks[info.source] ~= nil
end
-- set_running_game({leave =, claim = {name =, address =}, game =}) or
-- nil. leave is taken only from the client's own extensions, never from
-- a server's code; game is a Luanti game id.
buildat.safe.set_running_game = function(t)
	if t == nil then
		running_game = nil
		return true
	end
	if type(t) ~= "table" then
		return false, "set_running_game(table or nil)"
	end
	local g = type(t.game) == "string" and t.game:match("^[%w_]+$") and
			#t.game <= 64 and t.game or nil
	local claim = type(t.claim) == "table" and {name = t.claim.name,
			address = t.claim.address} or nil
	local leave = type(t.leave) == "function" and not from_served() and
			t.leave or nil
	if from_served() then
		-- A server's code names its game, and nothing else
		running_game = running_game or {}
		running_game.game = g
	else
		running_game = {leave = leave, claim = claim, game = g}
	end
	return true
end
-- A Luanti game by its id: its title from game.conf, and where it came
-- from by the file its installer left beside it (vanilla's ContentDB
-- download writes ".buildat_source", "contentdb:author/name")
local function luanti_game(id)
	local dir = __buildat_get_path("user") .. "/shared/vanilla/games/" .. id
	local title = id
	local f = io.open(dir .. "/game.conf", "rb")
	if f then
		local t = ("\n" .. f:read("*a")):match("\ntitle%s*=%s*([^\r\n]+)") or ""
		f:close()
		if #t > 0 and #t <= 60 and not t:find("%c") then
			title = t
		end
	end
	local src = nil
	f = io.open(dir .. "/.buildat_source", "rb")
	if f then
		src = (f:read("*a") or ""):match("^contentdb:[%w_%-]+/[%w_%-]+")
		f:close()
	end
	-- simplified: a game with no file is "unknown", whatever it is; a
	-- game bundled with Buildat would name itself here
	return {name = title, source = src or "unknown",
		subject = "game:" .. (src or "unknown:" .. id)}
end
local function game_target()
	if running_game and running_game.game then
		return luanti_game(running_game.game)
	end
	local app = __buildat_local_server_running() and local_launch
	if not app then
		return nil
	end
	-- An app from Aitta is a package: its subject as [PACKAGE_SUBJECT]
	-- makes it, and the Hearth's package page
	local author, name, version = app:match("^([%w_]+)%.([%w_]+)@(.+)$")
	if author then
		local dir = __buildat_get_path("user") .. "/installed/" .. author ..
				"/" .. name
		local kf = io.open(dir .. "/key", "rb")
		local key = kf and kf:read("*a"):match("%x+") or ""
		if kf then kf:close() end
		return {name = author .. "/" .. name, source = "aitta",
			subject = author .. "/" .. name .. " " .. key,
			package = author .. "/" .. name, version = version,
			engine = tostring(buildat.version()), platform = GetPlatform()}
	end
	return {name = app, source = "buildat",
		subject = "game:buildat:" .. app}
end
-- What the overlay's button says in a game, or nil out of one
function __buildat_discuss_label()
	if __buildat_server_address() and not __buildat_local_server_running() or
			running_game and running_game.leave then
		return "Discuss (leave server)"
	elseif __buildat_server_address() then
		return "Discuss (leave game)"
	end
	return nil
end
-- The overlay's Discuss in a game, to `hearth` (a Starport's URL for it):
-- leave properly, then the Hearth with what is known
function __buildat_discuss_from_overlay(hearth)
	local hearth_address = launch_grid.hearth_address(hearth)
	if not hearth_address then
		return false
	end
	local claim = running_game and running_game.claim
	local t = discuss_target(claim)
	local server = t and {name = t.name, address = t.address,
		subject = t.subject, title = t.title}
	local game = game_target()
	local leave = running_game and running_game.leave
	running_game = nil
	if __buildat_server_address() then
		leave_reason = nil
		if not leave_to_launcher() then
			return false
		end
	elseif leave then
		leave()
	end
	feedback = {address = hearth_address, server = server, game = game}
	log:info("discuss from the overlay: " .. (server and server.subject or
			"no server") .. ", " .. (game and game.subject or "no game") ..
			" on " .. hearth_address)
	local magic = require("buildat/core/urho3d").safe
	local sub
	sub = magic.SubscribeToEvent("Update", function()
		magic.UnsubscribeFromEvent("Update", sub)
		require("buildat/core/starport").join_with_id(hearth_address)
	end)
	return true
end
-- discussed() -> {server = {name, address, subject, title} or nil,
-- game = {name, source, subject[, package, version, engine, platform]}
-- or nil} or nil, once: the Hearth's side of either Discuss
buildat.safe.discussed = function()
	local f = feedback
	if not (f and (f.server or f.game)) then
		return nil
	end
	feedback = nil
	local s, g = f.server, f.game
	return {server = s and {name = s.name, address = s.address,
			subject = s.subject, title = s.title},
		game = g and {name = g.name, source = g.source, subject = g.subject,
			package = g.package, version = g.version, engine = g.engine,
			platform = g.platform}}
end
-- **Back to the launcher from a game** ([MENU_CONTEXT]): the connection
-- dropped, the local server stopped and the sandbox's leavings cleared.
-- The launcher's own screens are its business; this is the client half.
buildat.safe.leave_to_menu = __buildat_leave_to_menu
-- Whether this client is driven by a command sequence, which a launcher
-- asks before taking the mouse: a check shares a desk with the person
-- whose mouse it is ([BOX_PLAYTEST_3])
buildat.safe.is_scripted = __buildat_is_scripted
-- [TAP_BACK] uistack's: Escape pressed as Back (the depth is above)
buildat.press_back = __buildat_press_back

-- **The client's preferences, against a fixed key set**: the names are
-- `list_preferences()`'s and nothing else, which is what keeps this a
-- verb rather than a capability. The values live in `app::Options` and
-- the C++ side parses, range checks and persists them, so a launcher is
-- a page of widgets over these three calls and knows nothing about the
-- file. A name outside the list is refused here rather than reaching
-- the parser, which also reads a log level the sandbox has no business
-- with.
local function a_preference(name)
	if type(name) ~= "string" then
		return false
	end
	for _, k in ipairs(__buildat_list_preferences()) do
		if k == name then
			return true
		end
	end
	return false
end
buildat.safe.list_preferences = __buildat_list_preferences
buildat.safe.get_preference = function(name)
	if not a_preference(name) then
		return nil
	end
	return __buildat_get_preference(name)
end
buildat.safe.set_preference = function(name, value)
	if not a_preference(name) then
		return false, "set_preference: no preference by that name"
	end
	-- **Read by apps, set by the user**: a chunk a server sent may read
	-- a preference (a game's name field offers default_username) and may
	-- not write one; a launch extension, which is the user's, may
	local info = debug.getinfo(2, "S")
	if info and __buildat_served_chunks[info.source] then
		return false, "set_preference: the user's, not a server's"
	end
	if type(value) ~= "boolean" and type(value) ~= "string" and
			type(value) ~= "number" then
		return false, "set_preference(name, value): a boolean, a number " ..
				"or a string"
	end
	if type(value) == "number" then
		value = tostring(value)
	end
	return __buildat_set_preference(name, value)
end

-- **A launch extension's own second file** ([LAUNCH_SANDBOX]). Nothing
-- in the sandbox could load one: `require` reaches another extension's
-- safe interface and a module's client half, and an extension's own
-- files are neither -- so a launch UI of any size had to be one chunk,
-- or reach for `dofile` and a path. This runs one named file of the
-- calling launch extension in the sandbox and answers what it returned,
-- which is what `dofile` was being used for.
--
-- A name is one file, `.lua`, or one in a subdirectory (`res/x.lua`),
-- and not a path: an extension runs its own code and nobody else's.
buildat.safe.run_extension_file = function(name)
	if type(name) ~= "string" or not (name:match("^[%w_%-]+%.lua$") or
			name:match("^[%w_%-]+/[%w_%-]+%.lua$")) then
		return nil, "run_extension_file(name): one .lua file, not a path"
	end
	local who = calling_extension()
	local path = __buildat_extension_path(who) .. "/" .. name
	local f = io.open(path, "rb")
	if not f then
		-- **Raised, not answered nil**: every caller would otherwise
		-- write the same assert, and a nil indexed eighty lines later
		-- names the symptom instead of the cause ([MENU_FALLBACK])
		error("run_extension_file: no " .. name .. " in " .. who, 2)
	end
	local code = f:read("*a")
	f:close()
	local status, err, ret = __buildat_run_code_in_sandbox(code,
			who .. "/" .. name)
	if not status then
		return nil, err
	end
	return ret
end

-- One of the calling extension's own files as text, by the same names
-- ([BLIP]: the designer saves its generator's source for an app to copy)
buildat.safe.read_extension_file = function(name)
	if type(name) ~= "string" or not (name:match("^[%w_%-]+%.lua$") or
			name:match("^[%w_%-]+/[%w_%-]+%.lua$")) then
		return nil, "read_extension_file(name): one .lua file, not a path"
	end
	local who = calling_extension()
	local f = io.open(__buildat_extension_path(who) .. "/" .. name, "rb")
	if not f then
		return nil, "read_extension_file: no " .. name .. " in " .. who
	end
	local text = f:read("*a")
	f:close()
	return text
end

-- **The launch UIs this client has**, listed without running one:
-- an extension says it is one by shipping `launch_ui.txt`, whose first
-- line is its name for a person. Listing by loading would mean running
-- every candidate, which is the opposite of what a slot is for.
-- The launch UI that was asked for and did not load, or nil: what the
-- one that did load tells the user, so a setting cannot quietly do
-- nothing
-- **Evaluating a line of Lua, in the caller's own environment**
-- ([LAUNCH_CONSOLE]). A console whose lines each ran in a fresh
-- environment would teach something that does not transfer: `local x`
-- on one line and `x` on the next has to mean what it means everywhere
-- else. So the chunk is loaded here and given `getfenv(2)` -- the
-- sandbox wrapper of whoever called -- which is the same environment
-- the caller's own code runs in and no wider.
--
-- **Bytecode is refused**, as `run_code_in_sandbox` refuses it: a chunk
-- beginning with byte 27 is how a string-eval escapes a LuaJIT sandbox.
buildat.safe.eval = function(code, chunkname)
	if type(code) ~= "string" then
		return false, "eval(code): a string"
	end
	if code:byte(1) == 27 then
		return false, "binary bytecode prohibited"
	end
	-- **The chunk is the caller's, by name too**: every gate that tells a
	-- server's code from the user's -- set_preference, storage, the local
	-- server -- reads the calling chunk's name, so a name of the caller's
	-- choosing was a way to be someone else ([SECURITY_RUN_1]). The name
	-- asked for is only what an error message says.
	local info = debug.getinfo(2, "S")
	local own = info and info.source or "=eval"
	local f, err = loadstring(code, own)
	local function shown(e)
		if type(chunkname) ~= "string" or type(e) ~= "string" then
			return e
		end
		local short = info and info.short_src or ""
		if short ~= "" and e:sub(1, #short) == short then
			return chunkname:gsub("^[=@]", "") .. e:sub(#short + 1)
		end
		return e
	end
	if not f then
		return false, shown(err)
	end
	setfenv(f, getfenv(2))
	local r = {pcall(f)}
	local ok = table.remove(r, 1)
	if not ok then
		r[1] = shown(r[1])
	end
	return ok, unpack(r)
end
-- **The API document**, for a launch UI that shows it beside a console
-- ([LAUNCH_CONSOLE]). One named file of the client's own documentation,
-- read-only; not a way to read files.
buildat.safe.client_api_text = function()
	local f = io.open(__buildat_get_path("share") .. "/doc/client_api.txt",
			"rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

-- **One launch UI running another over it** ([TWO_AUDIENCES]' third
-- option: the room in attract mode with the menu stacked on it). The
-- composed one is booted exactly as the client boots a launch UI --
-- sandboxed if its `launch_ui.txt` asks -- and `action` is the string
-- its `boot()` takes, which is how a room is asked for a backdrop
-- rather than a game.
--
-- **Only the listed ones**, so this names no code that is not already a
-- launch UI, and a launch UI cannot compose itself.
buildat.safe.compose_launch_ui = function(name, action)
	if type(name) ~= "string" then
		return false, "compose_launch_ui(name): a string"
	end
	if action ~= nil and (type(action) ~= "string" or
			not action:match("^[%w_/%-]*$")) then
		return false, "compose_launch_ui: an action is a plain name"
	end
	if name == calling_extension() then
		return false, "compose_launch_ui: a launch UI cannot compose itself"
	end
	local found = false
	for _, e in ipairs(buildat.safe.list_launch_uis()) do
		if e.name == name then
			found = true
		end
	end
	if not found then
		return false, "compose_launch_ui: no launch UI called " .. name
	end
	local m
	if buildat.launch_ui_sandboxed(name) then
		local f = io.open(__buildat_extension_path(name) .. "/init.lua", "rb")
		if not f then
			return false, "compose_launch_ui: no init.lua in " .. name
		end
		local code = f:read("*a")
		f:close()
		-- The chunk is named after the extension, which is what the
		-- verbs above read to know whose files and whose storage they
		-- are being asked for
		local ok, err, ret = __buildat_run_code_in_sandbox(code,
				name .. "/init.lua")
		if not ok then
			return false, err
		end
		m = ret
	else
		m = __buildat_require_extension(name)
	end
	if type(m) ~= "table" or type(m.boot) ~= "function" then
		return false, "compose_launch_ui: " .. name .. " has no boot()"
	end
	m.boot(action)
	-- A composed launch UI answers the client the same way a booted one
	-- does ([MENU_CONTEXT]): leaving a game, a dead server, whether a
	-- game is running. Without this a game launched from the menu of a
	-- composition could not be left.
	buildat.safe.provide_launch_interface(m)
	return true
end

-- **Quitting**, which is a launch UI's own verb ([LAUNCH_SANDBOX]): the
-- client shuts down. It is `disconnect()` under another name -- with no
-- connection to drop, dropping it is what leaving is -- and a launcher
-- calling `engine:Exit()` is reaching for the engine to do it.
buildat.safe.quit = function()
	__buildat_disconnect()
end
buildat.safe.launch_ui_fell_back = __buildat_launch_ui_fell_back
-- The path names the user's own directories: the launcher's to show,
-- not a server's chunk's to read ([WIN_MINIDUMP])
buildat.safe.crash_dump_untold = function()
	local info = debug.getinfo(2, "S")
	if info and __buildat_served_chunks[info.source] then
		return nil
	end
	return __buildat_crash_dump_untold()
end

-- **Whose screen it is now**: the launch UI the client last booted or
-- was set to. A launch UI that is still running under another one --
-- `set_launch_ui` boots the new one over the old, and the old one's
-- handlers are still subscribed -- asks this to know that it no longer
-- holds the screen, and hands the input back ([LAUNCH_WORLD], 2026-09-24:
-- whatever holds the screen owns the input).
buildat.safe.launch_ui_name = function()
	return __buildat_menu_extension_name or "launch_menu"
end
-- The tail of a local server's log and where the whole of it is, for a
-- launcher's dialog about one that died ([START_PROGRESS]). Read-only,
-- and the path is the client's own.
buildat.safe.local_server_log_tail = __buildat_local_server_log_tail
-- Whether a launch UI asks to be run in the sandbox: a "sandboxed" line
-- in its launch_ui.txt ([LAUNCH_SANDBOX]). Trusted, and read by the
-- client's boot rather than by anything in the sandbox.
local function launch_ui_says(name, word)
	if type(name) ~= "string" or not name:match("^[%w_]+$") then
		return false
	end
	local f = io.open(__buildat_extension_path(name) .. "/launch_ui.txt", "rb")
	if not f then
		return false
	end
	local text = f:read("*a")
	f:close()
	for line in text:gmatch("[^\r\n]+") do
		if line:match("^%s*" .. word .. "%s*$") then
			return true
		end
	end
	return false
end
function buildat.launch_ui_sandboxed(name)
	-- One installed from Aitta ("<author>__<name>") always is
	return type(name) == "string" and name:find("__", 1, true) ~= nil or
			launch_ui_says(name, "sandboxed")
end
buildat.safe.list_launch_uis = function()
	local out = {}
	for _, e in ipairs(__buildat_list_launchers()) do
		if e.kind == "extension" and type(e.path) == "string" then
			local f = io.open(e.path .. "/launch_ui.txt", "rb")
			if f then
				local text = f:read("*a")
				f:close()
				local title, description =
						text:match("^([^\r\n]*)\r?\n?([^\r\n]*)")
				-- **"hidden" keeps it out of the list, not out of the
				-- slot**: a launch UI that exists to be tested is still
				-- selectable by name (`-m`, or the preference), and a
				-- person picking a launcher should not be offered one
				-- whose whole job is to try to break out of the sandbox.
				local hidden, experimental = false, false
				for line in text:gmatch("[^\r\n]+") do
					if line:match("^%s*hidden%s*$") then
						hidden = true
					elseif line:match("^%s*experimental%s*$") then
						experimental = true
					end
				end
				if not hidden then
					out[#out + 1] = {name = e.name,
							title = (title ~= nil and title ~= "") and
							title or e.name,
							description = description ~= "" and
							description or nil,
							experimental = experimental}
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end
-- **Switching the launch UI**: the name is remembered and the extension
-- is booted now, so the switch is one action rather than a restart. A
-- name that is not one of the listed ones is refused here -- the
-- preference would take it, but a slot is picked from what there is.
-- The launch UIs booted in this client, the one it started with too
local booted_launch_uis = {}
buildat.safe.set_launch_ui = function(name, opts)
	local old = __buildat_menu_extension_name or "launch_menu"
	-- **close**: the old one is taken down rather than left running
	-- under this one, and switching back to it boots it again. It
	-- takes its own elements and view down first; this drops the
	-- handlers it subscribed.
	local close = type(opts) == "table" and opts.close == true and
			old ~= name
	booted_launch_uis[old] = not close or nil
	local found = nil
	for _, e in ipairs(buildat.safe.list_launch_uis()) do
		if e.name == name then
			found = e
		end
	end
	if not found then
		return false, "set_launch_ui: no launch UI called " .. tostring(name)
	end
	local ok, err = __buildat_set_preference("launch_ui", name)
	if not ok then
		return false, err
	end
	-- **A "persistent" launch UI is booted once**: the room keeps running
	-- under another launch UI and takes the screen back by itself, so a
	-- second boot was a second room with every key acted on twice
	-- (2026-10-03). The stack is cleared and the name taken all the same.
	local again = booted_launch_uis[name] and launch_ui_says(name, "persistent")
	local m = nil
	if not again then
		m = __buildat_require_extension(name)
		if type(m) ~= "table" or type(m.boot) ~= "function" then
			return false, "set_launch_ui: " .. name .. " has no boot()"
		end
	end
	-- **Nothing of the old one's stays on the screen** ([LAUNCH_WORLD]
	-- stage 2, 2026-10-03): the switch is often made from the old one's
	-- own settings window, which was left drawn over the new one and
	-- kept the input. Everything on the main stack is the old launch
	-- UI's, so all of it goes before the new one boots.
	local us = __buildat_require_extension("uistack")
	local stack = us and us.main and us.main.stack
	if stack and stack[1] then
		local ok_pop, why = pcall(function()
			us.main:pop_to(stack[1], true)
		end)
		if not ok_pop then
			log:warning("set_launch_ui: clearing the stack: " .. tostring(why))
		end
	end
	if close then
		local urho3d = __buildat_loaded_extension("urho3d")
		if urho3d and urho3d.drop_handlers_of then
			urho3d.drop_handlers_of(old)
		end
	end
	__buildat_menu_extension_name = name
	booted_launch_uis[name] = true
	if again then
		log:info("set_launch_ui: " .. name .. " is running; it has the screen again")
	else
		m.boot()
	end
	return true
end

-- The two read-only enumerations a launcher draws its room from
buildat.safe.list_apps = __buildat_list_apps
-- A save's last_launched is launch_save's note: playing one need not
-- write its file, so the file's time alone does not say it was played
buildat.safe.list_saves = function(...)
	local history = launch_history_read()
	local saves = __buildat_list_saves(...)
	if not launch_grid.save_variants then
		buildat.safe.launch_actions()
	end
	for _, sv in ipairs(saves) do
		sv.last_launched = history["save/" .. tostring(sv.app) .. "/" ..
				tostring(sv.name)]
		-- [SAVE_ICON] Which of its app's tiles it is (an id of one, or
		-- anything), and the app's picture for its saves
		-- simplified: a read of each save's database each time; a cache
		-- by the file's modified time if a long list makes it slow
		local v = launch_grid.save_variants[sv.app]
		if v then
			sv.variant = __buildat_save_value(sv.app, sv.name, v.store, v.key)
			sv.icon = v.icon
		end
	end
	return saves
end
-- launch_save(game, name): open one of them. A save is the player's own
-- and the launch grid has no tile for it, so this is the one launch a
-- launcher asks for by name rather than by key ([LAUNCH_WORLD]: a save
-- is a sphere on the room's floor).
--
-- The pair has to be one list_saves() answers, so what reaches the
-- server's -u is a save that is on the disk and nothing a sandbox
-- composed. From there it is the grid's own path for a game with
-- params: the game starts and reads "save=<name>" as it would a packet.
buildat.safe.launch_save = function(game, name)
	if type(game) ~= "string" or type(name) ~= "string" then
		return false, "launch_save(game, name): two strings"
	end
	local found = false
	for _, sv in ipairs(__buildat_list_saves(game)) do
		if sv.name == name then
			found = true
			break
		end
	end
	if not found then
		return false, "launch_save(" .. game .. ", " .. name ..
				"): no such save"
	end
	launch_history_note("save/" .. game .. "/" .. name)
	launch_grid.screens().start_local_app(game, "save=" .. name)
	return true
end
-- [PAUSE_WORLDS_LOCAL] A served game may open another of its own saves
-- on the user's click (vanilla's Worlds... in the pause menu): only the
-- game of the local server the client is connected to, which is left
-- first. Any other game, or a remote server, is refused.
local launch_own_save
__buildat_served_overrides.launch_save = function(game, name)
	local here = __buildat_local_game and __buildat_local_game()
	-- nil: the local server's own
	game = game or here
	if not here or game ~= here then
		return false, "launch_save: only the local server's own game"
	end
	if not __buildat_user_activated() then
		return false, "launch_save: only right after the user's own key or click"
	end
	return launch_own_save(game, name)
end
launch_own_save = function(game, name)
	local found = false
	for _, sv in ipairs(__buildat_list_saves(game)) do
		found = found or sv.name == name
	end
	if not found then
		return false, "launch_save(" .. tostring(game) .. ", " ..
				tostring(name) .. "): no such save"
	end
	buildat.safe.leave()
	return buildat.safe.launch_save(game, name)
end
-- [VIEW_SETTINGS_LOCAL] Whether the server joined is the local one this
-- client started, whose settings are the user's own
buildat.safe.connected_locally = function()
	return (__buildat_local_game and __buildat_local_game()) ~= nil
end
-- [VIEW_SETTINGS_LOCAL] The game joined again on the user's click (a
-- render mode is fixed for a session): the local server's save opened
-- again through the launcher, since leaving stops that server; another
-- server reconnected at the address in use, why on the wait.
-- later: the local server's rejoin armed on the click and run by the next
-- call within 30 s, once the game's own settings write is in (the server's
-- answer can take seconds while it loads).
local rejoin_armed = nil
buildat.safe.rejoin = function(why, save, later)
	local now = __buildat_get_time_us()
	if rejoin_armed and now < rejoin_armed.until_us and
			buildat.safe.connected_locally() then
		local name = rejoin_armed.save
		rejoin_armed = nil
		return launch_own_save(__buildat_local_game(), name)
	end
	if not __buildat_user_activated() then
		return false, "rejoin: only right after the user's own key or click"
	end
	if buildat.safe.connected_locally() then
		if later then
			rejoin_armed = {save = save, until_us = now + 30e6}
			return true, "armed"
		end
		return __buildat_served_overrides.launch_save(nil, save)
	end
	local address = __buildat_server_address()
	if not address then
		return false, "rejoin: not joined"
	end
	if not leave_to_launcher() then
		return false, "rejoin: no launcher to rejoin from"
	end
	__buildat_reconnect(address, tostring(why or "Rejoining"), true)
	return true
end
-- **The launch menu's screens for any launch UI** ([LAUNCH_MENU_V2]): a
-- launch UI runs its own files and nobody else's, so these two are how
-- another one joins a server and shows the Engine settings without a
-- copy of launch_menu's. The connect is screens.lua's: the stopped
-- local server, the connecting screen, the error dialog and the
-- "game is running" placeholder a leave pops.
buildat.safe.join_server = function(address)
	if type(address) ~= "string" or address:find("%c") then
		return false, "join_server(address): a string"
	end
	launch_grid.screens().connect(address)
	return true
end
-- **An app's client half with no server** ([SERVERLESS_PLAY]): its files
-- from its directory, the launcher's placeholder under it so that
-- leave_app takes it down, and its client_mains run, buildat.serverless()
-- true for it. `id` as list_apps() names it -> true, or false and why.
-- Trusted only: the launcher's Play
buildat.serverless_play = function(id)
	local scripts, why = __buildat_serverless_start(tostring(id))
	if not scripts then
		return false, why
	end
	__buildat_set_serverless()
	launch_grid.screens().game_running()
	for _, name in ipairs(scripts) do
		buildat.run_script_file(name)
	end
	return true
end
-- BUILDAT_RUN, from src/client/app.cpp once the launch UI is up: an app id
-- as list_apps() names it played at once, or <author>/<name> from the
-- Aittas (client/core/aitta)
function __buildat_run_serverless(what)
	if what:match("^[%w_]+/[%w_]+$") then
		require("buildat/core/aitta").run_serverless(what)
		return
	end
	local ok, why = buildat.serverless_play(what)
	if not ok then
		log:warning("BUILDAT_RUN=" .. what .. ": " .. tostring(why))
	end
end
-- [SERVE_UPDATE_SMOOTH] 6, from __buildat_leave_lost above
function __buildat_reconnect(address, why, restarting)
	launch_grid.screens().reconnect(address, why, restarting)
end
-- [PLAY_LINKS] the play page's ?server=, from src/client/app.cpp once the
-- launch UI is up: screens.lua joins it if it is listed
function __buildat_join_listed(address)
	launch_grid.screens().join_listed(address)
end
buildat.safe.show_engine_settings = function()
	launch_grid.screens("preferences.lua").show()
	return true
end
-- launch_menu's Keys screen, which is preferences.lua's for the game
-- settings window's keys page to be the same ([SETTINGS_KEYS_PAGE])
buildat.safe.show_key_settings = function()
	launch_grid.screens("preferences.lua").show_keys()
	return true
end
-- [LOG_REACH] for Settings' "Logs and errors": the log's path ("" with
-- none, the web's), the folder it is in opened by the system's file
-- manager (on the user's own click; the path is the native side's), and
-- the caught errors in full with the version and platform on top
buildat.safe.log_path = function()
	return __buildat_get_path("log") or ""
end
buildat.safe.open_log_folder = function()
	if not __buildat_user_activated() then
		return nil, "open_log_folder: only right after the user's own key or click"
	end
	return __buildat_open_log_folder()
end
-- [LUANTI_IMPORT_FOLDER]: the import folder of the local server's app,
-- <user>/shared/<app>/import, opened by the system's file manager on the
-- user's own click; nil and why for a remote server. Absent on the web.
if __buildat_open_import_folder then
	buildat.safe.open_import_folder = function()
		if not __buildat_user_activated() then
			return nil, "open_import_folder: only right after the user's own key or click"
		end
		return __buildat_open_import_folder()
	end
end
buildat.safe.recent_errors = function()
	return __buildat_errors_text()
end

-- **The key store** ([LAUNCH_MENU_V2] step 3): one client-side store of
-- key bindings, the player's and not any server's. An app declares its
-- actions -- an id, a label, a default key, and optionally a shared name
-- from SHARED_KEY_NAMES -- and gets each one's key back: the app's own
-- override, else the shared name's binding, else the default. A launch
-- UI edits it: the shared names once for every app, an app's override
-- for that app alone, and the client's own four keys.
-- <user>/keys.txt, a line a fact, tab-separated:
--   shared <name> <key>            override <app> <action> <key>
--   client <which> <key or "">     app <app> <label>
--   action <app> <action> <default> <shared> <label>
-- Key names are Urho3D's (Input::GetKeyName).
local SHARED_KEY_NAMES = {"move.forward", "move.back", "move.left",
	"move.right", "jump", "sneak", "sprint", "fly", "noclip", "camera",
	"zoom", "chat", "inventory", "drop", "hud", "menu"}
local shared_key_name = {}
for _, n in ipairs(SHARED_KEY_NAMES) do shared_key_name[n] = true end
-- The client's own keys and their defaults; the overlay's cannot be
-- unbound, so the client's trust signal always has a key
local CLIENT_KEYS = {{"overlay", "F9"}, {"profiler", "F10"},
	{"fullscreen", "F11"}, {"screenshot", "F12"}}
local KEY_ID = "^[%w_%.%-/]+$"
local key_store_cache = nil
local function key_store_path()
	return __buildat_get_path("user") .. "/keys.txt"
end
local function key_name_ok(name)
	return type(name) == "string" and #name <= 32 and
			not name:find("[%c]") and input:GetKeyFromName(name) ~= 0
end
local function key_label(v)
	return (tostring(v or ""):gsub("[%c]", " ")):sub(1, 80)
end
local function key_store_load()
	if key_store_cache then return key_store_cache end
	local st = {shared = {}, client = {}, apps = {}, order = {}}
	for _, c in ipairs(CLIENT_KEYS) do st.client[c[1]] = c[2] end
	local function app(id)
		if not st.apps[id] then
			st.apps[id] = {id = id, label = id, actions = {}, by_id = {},
				overrides = {}}
			st.order[#st.order + 1] = id
		end
		return st.apps[id]
	end
	local f = io.open(key_store_path(), "r")
	for line in (f and f:lines() or function() end) do
		local t = {}
		for x in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = x end
		if t[1] == "shared" and shared_key_name[t[2]] then
			st.shared[t[2]] = t[3]
		elseif t[1] == "client" and st.client[t[2]] then
			st.client[t[2]] = t[3] or ""
		elseif t[1] == "app" and t[2] then
			app(t[2]).label = t[3] or t[2]
		elseif t[1] == "override" and t[3] then
			app(t[2]).overrides[t[3]] = t[4]
		elseif t[1] == "action" and t[3] then
			local a = app(t[2])
			local e = {id = t[3], default = t[4] ~= "" and t[4] or nil,
				shared = t[5] ~= "" and t[5] or nil, label = t[6] or t[3]}
			a.actions[#a.actions + 1] = e
			a.by_id[e.id] = e
		end
	end
	if f then f:close() end
	key_store_cache = st
	return st
end
local function key_store_save()
	local st = key_store_load()
	local out = {}
	for _, c in ipairs(CLIENT_KEYS) do
		out[#out + 1] = "client\t" .. c[1] .. "\t" .. st.client[c[1]]
	end
	for _, n in ipairs(SHARED_KEY_NAMES) do
		if st.shared[n] then
			out[#out + 1] = "shared\t" .. n .. "\t" .. st.shared[n]
		end
	end
	for _, id in ipairs(st.order) do
		local a = st.apps[id]
		out[#out + 1] = "app\t" .. id .. "\t" .. a.label
		for _, e in ipairs(a.actions) do
			out[#out + 1] = table.concat({"action", id, e.id, e.default or "",
				e.shared or "", e.label}, "\t")
			if a.overrides[e.id] then
				out[#out + 1] = "override\t" .. id .. "\t" .. e.id .. "\t" ..
						a.overrides[e.id]
			end
		end
	end
	local f = io.open(key_store_path(), "w")
	if not f then
		log:warning("keys: cannot write " .. key_store_path())
		return false
	end
	f:write(table.concat(out, "\n") .. "\n")
	f:close()
	return true
end
-- What an action's key is and where it comes from
local function key_resolve(st, a, e)
	if a.overrides[e.id] then return a.overrides[e.id], "app" end
	if e.shared and st.shared[e.shared] then
		return st.shared[e.shared], "shared"
	end
	return e.default, "default"
end
do
	local e = {id = "j", shared = "jump", default = "Space"}
	assert(key_resolve({shared = {}}, {overrides = {}}, e) == "Space")
	assert(key_resolve({shared = {jump = "J"}}, {overrides = {}}, e) == "J")
	assert(select(2, key_resolve({shared = {jump = "J"}},
			{overrides = {j = "K"}}, e)) == "app")
end
-- The client's four as key codes, for the client's own handlers
-- (client/core/urho3d/init.lua), which read this at start and
-- after every change
__buildat_client_key_names = function()
	local st = key_store_load()
	local out = {}
	for _, c in ipairs(CLIENT_KEYS) do out[c[1]] = st.client[c[1]] end
	return out
end
local function client_keys_changed()
	if __buildat_apply_client_keys then
		__buildat_apply_client_keys(__buildat_client_key_names())
	end
end
local MAX_KEY_ACTIONS = 64
-- declare_keys(app, label, actions) -> {action id = key name}, and
-- {action id = the key it has without the app's override}
local function declare_keys(app_id, label, actions, served)
	if type(app_id) ~= "string" or not app_id:match(KEY_ID) or
			#app_id > 64 or type(actions) ~= "table" then
		return nil, "declare_keys(app, label, actions): an id, a " ..
				"label and a list"
	end
	local st = key_store_load()
	local client = {}
	for _, c in ipairs(CLIENT_KEYS) do client[st.client[c[1]]] = true end
	local a = st.apps[app_id]
	if not a then
		a = {id = app_id, actions = {}, by_id = {}, overrides = {}}
		st.apps[app_id] = a
		st.order[#st.order + 1] = app_id
	end
	a.label = key_label(label ~= nil and label or app_id)
	a.actions, a.by_id = {}, {}
	for i, x in ipairs(actions) do
		if i > MAX_KEY_ACTIONS then break end
		local id = type(x) == "table" and x.id
		if type(id) == "string" and id:match(KEY_ID) and #id <= 64 and
				not a.by_id[id] then
			local default = key_name_ok(x.default) and x.default or nil
			-- **A server may not propose the client's own keys**: what
			-- the client's keys are bound to no app hears, and a
			-- server's default there is a claim on them
			if served and default and (client[default] or
					default:match("^F9$") or default:match("^F1[012]$")) then
				default = nil
			end
			local e = {id = id, default = default,
				shared = shared_key_name[x.shared] and x.shared or nil,
				label = key_label(x.label or id)}
			a.actions[#a.actions + 1] = e
			a.by_id[id] = e
		end
	end
	key_store_save()
	local out, base = {}, {}
	for _, e in ipairs(a.actions) do
		out[e.id] = (key_resolve(st, a, e))
		base[e.id] = e.shared and st.shared[e.shared] or e.default
	end
	return out, base
end
-- set_app_keys(app, {action id = key name, or false for none of its own});
-- a name that is the action's key without an override clears the override
local function set_app_keys(app_id, map)
	local st = key_store_load()
	local a = type(app_id) == "string" and st.apps[app_id]
	if not a or type(map) ~= "table" then
		return false, "set_app_keys(app, map): a declared app and a table"
	end
	for id, name in pairs(map) do
		local e = a.by_id[id]
		if e then
			-- The key it would have anyway is no override: it follows
			-- the shared name when that changes
			local base = e.shared and st.shared[e.shared] or e.default
			if name == false or name == base then
				a.overrides[id] = nil
			elseif key_name_ok(name) then
				a.overrides[id] = name
			end
		end
	end
	return key_store_save()
end
buildat.safe.declare_keys = function(app_id, label, actions)
	return declare_keys(app_id, label, actions, false)
end
buildat.safe.set_app_keys = set_app_keys
-- set_shared_key(name, key name or nil): the binding every app's action
-- of that shared name has, unless the app overrides it
buildat.safe.set_shared_key = function(name, key)
	if not shared_key_name[name] then
		return false, "set_shared_key: no shared name " .. tostring(name)
	end
	if key ~= nil and not key_name_ok(key) then
		return false, "set_shared_key: no key " .. tostring(key)
	end
	key_store_load().shared[name] = key
	return key_store_save()
end
-- set_client_key(which, key name or nil): overlay, profiler, fullscreen,
-- screenshot. Unbinding the overlay is refused.
buildat.safe.set_client_key = function(which, key)
	local st = key_store_load()
	if st.client[which] == nil then
		return false, "set_client_key: no client key " .. tostring(which)
	end
	if key == nil and which == "overlay" then
		return false, "set_client_key: the overlay keeps a key"
	end
	if key ~= nil and not key_name_ok(key) then
		return false, "set_client_key: no key " .. tostring(key)
	end
	st.client[which] = key or ""
	key_store_save()
	client_keys_changed()
	return true
end
-- key_store() -> the whole store as plain data, for an editor:
-- {shared_names, shared = {name = key}, client = {{which, key}},
--  apps = {{id, label, actions = {{id, label, default, shared, key,
--  from = "app"|"shared"|"default"}}}}}
buildat.safe.key_store = function()
	local st = key_store_load()
	local out = {shared_names = {}, shared = {}, client = {}, apps = {}}
	for i, n in ipairs(SHARED_KEY_NAMES) do
		out.shared_names[i] = n
		out.shared[n] = st.shared[n]
	end
	for i, c in ipairs(CLIENT_KEYS) do
		out.client[i] = {which = c[1], key = st.client[c[1]],
			default = c[2]}
	end
	for _, id in ipairs(st.order) do
		local a = st.apps[id]
		local acts = {}
		for i, e in ipairs(a.actions) do
			local key, from = key_resolve(st, a, e)
			acts[i] = {id = e.id, label = e.label, default = e.default,
				shared = e.shared, key = key, from = from}
		end
		out.apps[#out.apps + 1] = {id = id, label = a.label, actions = acts}
	end
	return out
end
-- **An app on a server** declares and overrides under its own identity
-- only -- the place game_storage_dir() keeps its storage, the app's name
-- for a server this client started, the address for any other -- and
-- never touches the shared names, the client's keys or the store.
local function served_key_app()
	local dir = __buildat_game_storage_dir()
	if not dir then return nil end
	local rel = dir:sub(#__buildat_get_path("user") + 2)
	local app = rel:match("^apps/([^/]+)/client$")
	if app then return "app/" .. app end
	return "server/" .. (rel:match("^servers/(.+)$") or rel):gsub("[^%w_%.%-]", "_")
end
__buildat_served_overrides.declare_keys = function(_, label, actions)
	local id = served_key_app()
	if not id then return nil, "declare_keys: not connected" end
	return declare_keys(id, label, actions, true)
end
__buildat_served_overrides.set_app_keys = function(_, map)
	local id = served_key_app()
	if not id then return false, "set_app_keys: not connected" end
	return set_app_keys(id, map)
end
-- **A game's settings window** ([GAME_SETTINGS]):
-- show_game_settings{on_close = f, sections = {{title =, draw =
-- function(w, ui) end}, ...}}, drawn by the client over the game with
-- the engine's settings, the game's keys and the logs after the game's
-- sections (extensions/launch_menu/preferences.lua, show_game). A
-- section's draw(w, ui) fills w with ui.text(t, colour), ui.button(label,
-- f), ui.dropdown(label, {{label, value}, ...}, current, f(value)),
-- ui.toggle(label, on, f(on)), or with its own widgets; ui.redraw()
-- draws it again, ui.away(f) closes the window for another, f(back).
-- on_close: Close or Escape; the keys may have changed, so a game reads
-- them again there. add_game_settings_section(name, section): a
-- builtin's own (accounts' Server), in every game's window, until the
-- connection ends.
local game_settings, game_settings_extra = nil, {}
buildat.safe.show_game_settings = function(o)
	if type(o) ~= "table" then
		return false, "show_game_settings{on_close =, sections =}"
	end
	local extra = {}
	for _, name in ipairs(game_settings_extra.order or {}) do
		extra[#extra + 1] = game_settings_extra[name]
	end
	game_settings = game_settings or launch_grid.screens("preferences.lua")
	game_settings.show_game({on_close = o.on_close,
		sections = type(o.sections) == "table" and o.sections or nil},
		served_key_app(), extra)
	return true
end
-- show_game_keys{on_close = f}: the window's keys page alone, for a game
-- whose own menu offers its keys ([SETTINGS_KEYS_PAGE]); on_close as
-- show_game_settings'
buildat.safe.show_game_keys = function(o)
	if type(o) ~= "table" then
		return false, "show_game_keys{on_close =}"
	end
	game_settings = game_settings or launch_grid.screens("preferences.lua")
	game_settings.show_game_keys({on_close = o.on_close}, served_key_app())
	return true
end
buildat.safe.add_game_settings_section = function(name, section)
	if type(name) ~= "string" or type(section) ~= "table" or
			type(section.draw) ~= "function" then
		return false, "add_game_settings_section(name, {title =, draw =})"
	end
	game_settings_extra.order = game_settings_extra.order or {}
	if not game_settings_extra[name] then
		table.insert(game_settings_extra.order, name)
	end
	game_settings_extra[name] = {title = section.title or name,
		draw = section.draw}
	return true
end
-- The connection's sandbox reset (sandbox.lua): its sections dropped, and
-- the window, whose game is gone
function __buildat_game_settings_reset()
	game_settings_extra = {}
	if game_settings then
		game_settings.close_game()
	end
end
-- Whether the client has a local server up, which is how a launcher
-- knows a launch action started a game rather than opening a screen
buildat.safe.local_server_running = __buildat_local_server_running

-- **The local server, for the screens a game is started through**
-- (extensions/launch_menu/screens.lua, which runs in the sandbox). The
-- user's and not a server's: a chunk a server sent may not start, stop
-- or kill a process on this machine.
-- start_local_server(game[, launch]) -> true, or false and why. game is
-- one list_apps() answers; launch is key=value lines for the server's
-- -u, a key of a name's shape, which the module reads as it would a
-- packet.
buildat.safe.start_local_server = function(game, launch)
	if from_served() then
		return false, "start_local_server: the user's, not a server's"
	end
	local found = false
	for _, g in ipairs(__buildat_list_apps()) do
		if g.name == game then
			found = true
		end
	end
	if not found then
		return false, "start_local_server: no app called " .. tostring(game)
	end
	if launch ~= nil then
		if type(launch) ~= "string" or #launch > 4096 then
			return false, "start_local_server: launch is a string"
		end
		for line in launch:gmatch("[^\n]+") do
			if not line:match("^[%w_]+=[^\r]*$") then
				return false, "start_local_server: a launch line is key=value"
			end
		end
	end
	local ok, why = __buildat_start_local_server(game, launch)
	if ok then
		local_launch = game
		running_game = nil
	end
	return ok, why
end
-- stop_local_server(force): asks it to stop, or kills it with force
buildat.safe.stop_local_server = function(force)
	if from_served() then
		return false, "stop_local_server: the user's, not a server's"
	end
	if force == true then
		__buildat_force_kill_local_server()
	else
		__buildat_request_stop_local_server()
	end
	return true
end
-- local_server_state() -> port or nil, status: the port once it
-- answers, and the last status line of its log
-- lan_address() -> "a.b.c.d" or nil: this machine's address on the LAN,
-- only while connected to the server this client started (the pause
-- menu's "Open to LAN" says it)
buildat.safe.lan_address = __buildat_lan_address
-- lan_servers() -> {{host, port, name, app, version, players, account},
-- ...}: the games announcing themselves on this network, heard within
-- 6 s ([LAN_DISCOVERY]); empty while connected to a server. Ask it every
-- second or so while the list is on the screen.
buildat.safe.lan_servers = __buildat_lan_servers

buildat.safe.local_server_state = function()
	local port = __buildat_local_server_ready() and
			__buildat_local_server_port() or nil
	return port, __buildat_local_server_status()
end

-- The one preference a game may set ([BOX_FIXES] b): the player's ear.
-- Official's pause menu has mute and volume, and that is where a player
-- reaches for them. get_sound() -> mute, db; set_sound(mute, db) ->
-- true, or false and why. The rest of the preferences stay the
-- launcher's.
--
-- **The volume is decibels below full** ([VOLUME_LAW], user
-- 2026-09-28): 0 is full, -3, -6 and so on are the steps a setting
-- offers, and -33 or less is off. A game shows it in those units; the
-- gain is made from it in the client, in the one place it is applied.
buildat.safe.get_sound = function()
	return __buildat_get_preference("sound_mute") == true,
			__buildat_get_preference("sound_volume_db") or 0
end
buildat.safe.set_sound = function(mute, db)
	if type(mute) ~= "boolean" or type(db) ~= "number" then
		return false, "set_sound(mute, db): a boolean and decibels"
	end
	local ok, err = __buildat_set_preference("sound_mute", mute)
	if not ok then
		return false, err
	end
	return __buildat_set_preference("sound_volume_db", tostring(db))
end
-- **The web page's address bar, a third** ([WEB_ADDRESS_BAR]): a game's
-- pause menu switches it. get_web_address_bar() -> "hide" or "show", nil
-- natively; set_web_address_bar("hide" or "show") -> true, or false and
-- why. It shows while the game does not ask for fullscreen
-- (set_web_fullscreen) whatever it is.
buildat.safe.get_web_address_bar = function()
	return __buildat_get_preference("web_address_bar")
end
buildat.safe.set_web_address_bar = function(v)
	if v ~= "hide" and v ~= "show" then
		return false, "set_web_address_bar: hide or show"
	end
	return __buildat_set_preference("web_address_bar", v)
end
-- **The screen's orientation on the web** ([SCREEN_ORIENTATION]): a
-- game's pause menu switches it. get_screen_orientation() -> "auto",
-- "landscape" or "portrait", nil natively; set_screen_orientation(v) ->
-- true, or false and why. The page holds it while it is fullscreen.
buildat.safe.get_screen_orientation = function()
	return __buildat_get_preference("screen_orientation")
end
buildat.safe.set_screen_orientation = function(v)
	if v ~= "auto" and v ~= "landscape" and v ~= "portrait" then
		return false, "set_screen_orientation: auto, landscape or portrait"
	end
	return __buildat_set_preference("screen_orientation", v)
end
-- **The render scale, the other preference a game may set** (user,
-- 2026-09-30): the web client has no launcher to reach Engine settings
-- through, so a game's own settings carry it. What the game gets to set
-- is how much its frame costs, never what is in it.
-- get_render_scale() -> share, automatic; set_render_scale(share or
-- "auto") -> true, or false and why. "auto" is the client's own choice,
-- made again on each start and resize.
buildat.safe.get_render_scale = function()
	return __buildat_get_preferred_render_scale(),
			__buildat_get_preference("render_scale") == "auto"
end
buildat.safe.set_render_scale = function(v)
	if type(v) ~= "number" and v ~= "auto" then
		return false, "set_render_scale(share): a number or \"auto\""
	end
	return __buildat_set_preference("render_scale", tostring(v))
end
-- **The UI's size, a third** (user, 2026-10-06): for the same reason, from
-- an app's own settings. get_ui_size() -> the UI scale now, automatic;
-- set_ui_size(scale or "auto") -> true, or false and why. "auto" follows
-- the window; a scale is 0.5 to 3.
buildat.safe.get_ui_size = function()
	return __buildat_get_ui_scale(),
			__buildat_get_preference("ui_size") == "auto"
end
buildat.safe.set_ui_size = function(v)
	if type(v) ~= "number" and v ~= "auto" then
		return false, "set_ui_size(scale): a number or \"auto\""
	end
	return __buildat_set_preference("ui_size", tostring(v))
end
-- The bytes of a file the server served, or nil ([BLOCKED_MODULE]): a
-- module that is busy answers no packet, and client_file is a module of its
-- own, so a table served as a file reaches the client anyway. The sandbox
-- already runs a served file as code (run_script_file); reading one's bytes
-- is no wider than that.
buildat.safe.get_file_content = function(name)
	if type(name) ~= "string" then
		return nil
	end
	return __buildat_get_file_content(name)
end
buildat.safe.set_ui_scale  = __buildat_set_ui_scale
buildat.safe.get_ui_scale  = __buildat_get_ui_scale
buildat.safe.logical_size  = __buildat_logical_size
-- keyboard_height() -> the on-screen keyboard's height in UI pixels, 0 with
-- none (a native client)
buildat.safe.keyboard_height = __buildat_keyboard_height
-- display_density() -> device pixels per CSS pixel on the web, 1 natively
buildat.safe.display_density = __buildat_display_density
-- received() -> the bytes read from the server since the connect, and the
-- seconds since the last came (nil before any) ([JOIN_PROGRESS])
buildat.safe.received = __buildat_received
-- last_arrival() -> nil before anything came, else {t (get_time_us()'s
-- clock), kind = "file" (name) | "chunk" (x, y, z) | "other" (what)}; an
-- "other" does not hide a file or chunk for a second ([LOADING_STRIPES])
buildat.safe.last_arrival = __buildat_last_arrival
-- in_flight() -> nil, or {name, have, size}: the packet arriving and not
-- yet whole ([LOAD_IN_FLIGHT])
buildat.safe.in_flight = __buildat_in_flight
-- The join's loading screen ([JOIN_STRIPES]): state.cpp says what the wait
-- for the game's files is at, and ui_utils draws it. An error in it is
-- the log's, not the client's end.
function __buildat_join_screen(what, got, total)
	local ui_utils = __buildat_require_extension("ui_utils")
	local ok, err = pcall(ui_utils.safe.join_screen, what, got, total)
	if not ok then
		log:error("join screen: " .. tostring(err))
	end
end
buildat.safe.get_preferred_render_scale = __buildat_get_preferred_render_scale
buildat.safe.font_sans     = buildat.font_sans
buildat.safe.font_mono     = buildat.font_mono
buildat.safe.get_time_us   = __buildat_get_time_us
buildat.safe.get_local_time = __buildat_get_local_time
buildat.safe.version       = __buildat_version
buildat.safe.api           = buildat.api
buildat.safe.has           = buildat.has
buildat.safe.sha1          = __buildat_sha1
buildat.safe.sha256        = __buildat_sha256
-- qr_code(text) -> the QR code's modules as a string of "0" and "1", row
-- by row from the top, and its side; or nil. Reads and writes nothing:
-- a TOTP secret's otpauth:// link for an authenticator app ([STARPORT] 10a)
buildat.safe.qr_code       = __buildat_qr_code
buildat.safe.hex           = __buildat_hex
buildat.safe.compress      = __buildat_compress
buildat.safe.decompress    = __buildat_decompress
buildat.safe.profiler_block_begin = __buildat_profiler_block_begin
buildat.safe.profiler_block_end   = __buildat_profiler_block_end
buildat.safe.profiler_data        = __buildat_profiler_data
buildat.safe.VoxelName            = __buildat_VoxelName
buildat.safe.AtlasSegmentDefinition = __buildat_AtlasSegmentDefinition
buildat.safe.VoxelDefinition      = __buildat_VoxelDefinition
buildat.safe.createVoxelRegistry  = __buildat_createVoxelRegistry
buildat.safe.createAtlasRegistry  = __buildat_createAtlasRegistry
buildat.safe.Region        = __buildat_Region
buildat.safe.VoxelInstance = __buildat_VoxelInstance
buildat.safe.Volume        = __buildat_Volume
-- pack_voxel_volume(args): packed samples -> a serialized volume, which
-- set_voxel_geometry() and deserialize_volume() take. See doc/client_api.txt.
buildat.safe.pack_voxel_volume        = __buildat_pack_voxel_volume
buildat.safe.deserialize_volume       = __buildat_deserialize_volume
buildat.safe.deserialize_volume_int32 = __buildat_deserialize_volume_int32
buildat.safe.deserialize_volume_8bit  = __buildat_deserialize_volume_8bit
-- cast_voxel_rays(args): marches rays through voxel data. args.directions is a
-- flat array of numbers, three to a ray. With args.rays_per_cell set,
-- consecutive rays are one cell's and what comes back is their average
-- visibility per cell; without it, what every ray ran into. See the comments
-- in src/lua_bindings/voxel_volume.cpp.
buildat.safe.cast_voxel_rays          = __buildat_cast_voxel_rays
-- cast_voxel_rays_start(args) takes what cast_voxel_rays() takes and returns a
-- handle; cast_voxel_rays_collect(handle) returns nil until the marching has
-- finished on a worker thread, and then what cast_voxel_rays() would have
-- returned. The volumes and the registry are held for the job's lifetime, so a
-- chunk arriving meanwhile does not pull data out from under it.
buildat.safe.cast_voxel_rays_start    = __buildat_cast_voxel_rays_start
buildat.safe.cast_voxel_rays_collect  = __buildat_cast_voxel_rays_collect
-- write_floats(vector_buffer, values): the values into the buffer as floats,
-- replacing what was in it
buildat.safe.write_floats             = __buildat_write_floats
-- write_shorts(vector_buffer, values): the same as 16-bit samples, each
-- floored and clamped
buildat.safe.write_shorts             = __buildat_write_shorts
-- [SYNTH_BLOCKS]: synth.buffer(n), a buffer of samples in C++ and the
-- blocks that write it (src/lua_bindings/synth.cpp, doc/client_api.txt)
buildat.safe.synth = {buffer = __buildat_synth_buffer}
-- add_resource_dir(path) and compose_image(args), in the sandbox as they
-- are (decided 2026-09-13). What they give sandboxed code is "write files
-- under the cache and make them loadable", which a server can already do
-- through client_file -- it ships whatever files it likes into the same
-- cache -- so this adds no power that was not already there. What it does
-- do is make the cache-path check in each of them load-bearing rather than
-- a sanity check: anything added beside them writes under the cache or it
-- does not go in the sandbox. See doc/plan/luanti_module_plan.md, "what a
-- module's client half is allowed to do".
buildat.safe.add_resource_dir         = __buildat_add_resource_dir
buildat.safe.compose_image            = __buildat_compose_image
-- take_screenshot() -> the name of the file it went into, or nil and why
-- not. **The caller says when and nothing else**: the client picks the
-- directory and the name, so sandboxed code cannot choose a path, cannot
-- read what it wrote and cannot overwrite an existing shot. What it can do
-- is fill <user>/screenshots, which is what the screenshot key already does.
-- The file lands at the end of the frame; the name is reserved before this
-- returns. See l_take_screenshot() in src/client/app.cpp.
buildat.safe.take_screenshot          = __buildat_take_screenshot
-- **Files a game hands the user and takes from them** ([FP_EXPORT] 4), the
-- same rule as take_screenshot: the client picks where. On native,
-- <user>/exports; on the web, the browser's download and file picker.
--   save_file(name, data) -> the path it went to ("" for a download), or
--       nil and why not; never overwrites
--   pick_file([accept]) -> true: the web's file picker, or on native the
--       client's own, which starts in <user>/exports and browses the disk
--       (extension/network)
--   picked_file() -> name, data once the picked file is read, else nil;
--       nil and why once the user picked nothing or it could not be read
-- **No listing or reading of <user>/exports** ([SECURITY_RUN_1]): every
-- server's game exports there, so a game that read it all read another
-- server's plans; it gets the file the user picks.
-- Files are at most 64 MiB. See l_save_file() in src/client/app.cpp.
buildat.safe.save_file                = __buildat_save_file
-- **A file a part at a time** ([WORLD_TRIM_MOVE]), for one more than a
-- string or a packet holds:
--   save_file_parts(name) -> a writer, or nil and why not: w.add(data) ->
--       true, or nil and why (the parts dropped); w.finish() -> the path
--       ("" for a download), or nil and why; w.cancel() drops the parts
--   pick_file(accept, true): picked_file() then gives name, reader, with
--       reader.size and reader.read(offset, len) -> the bytes from offset,
--       at most len (16 MiB); reader.close() when done
buildat.safe.save_file_parts = function(name)
	local id, why = __buildat_save_part_begin(tostring(name))
	if not id then
		return nil, why
	end
	return {
		add = function(data) return __buildat_save_part_add(id, data) end,
		finish = function() return __buildat_save_part_end(id, true) end,
		cancel = function() __buildat_save_part_end(id, false) end,
	}
end
local picked_export = nil
local picked_parts = false
buildat.safe.pick_file = function(accept, parts)
	picked_parts = parts == true
	if __buildat_pick_file(accept) then
		return true
	end
	picked_export = nil
	__buildat_require_extension("network").pick_export(
			type(accept) == "string" and accept or "", function(name, data)
		picked_export = {name, data}
	end, nil, nil, picked_parts)
	return true
end
buildat.safe.picked_file = function()
	local p = picked_export
	if p then
		picked_export = nil
		return p[1], p[2]
	end
	if not picked_parts then
		return __buildat_picked_file()
	end
	-- The web's: kept by the page and read from there
	local _, size, name = __buildat_picked_part(0, 0)
	if not name then
		return nil
	end
	picked_parts = false
	return name, {size = size,
		read = function(offset, len)
			return (__buildat_picked_part(offset, len))
		end,
		close = function() __buildat_picked_part(-1) end}
end
-- dump_meshes([atlas_json], [node]): node, a sandboxed Node, dumps what is
-- under it rather than the replicated scene
function buildat.safe.dump_meshes(atlas, safe_node)
	if safe_node ~= nil then
		if not getmetatable(safe_node) or
				getmetatable(safe_node).type_name ~= "Node" and
				getmetatable(safe_node).type_name ~= "Scene" then
			error("node is not a sandboxed Node instance")
		end
		return __buildat_dump_meshes(atlas, getmetatable(safe_node).unsafe)
	end
	return __buildat_dump_meshes(atlas)
end
-- get_env(name) -> the variable, or nil. Only BUILDAT_-prefixed names, so a
-- server's Lua cannot read the user's environment; what it is for is a knob
-- a harness sets on the client's process, such as the rendering mode. See
-- l_get_env() in src/client/app.cpp.
buildat.safe.get_env                  = __buildat_get_env
-- get_locale() -> the user's language as the environment says it
-- (LANGUAGE, LC_ALL, LC_MESSAGES, LANG, the first set), or ""
buildat.safe.get_locale = function()
	for _, k in ipairs({"LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}) do
		local v = os.getenv(k)
		if v and v ~= "" then
			return v
		end
	end
	return ""
end
-- Harmless in the sandbox ([EXTENSIONS_SANDBOXED]): bytes from the
-- system's generator, arithmetic on byte strings, and the pixels of a
-- resource the sandbox could already load
buildat.safe.random_bytes = buildat.random_bytes
buildat.safe.bignum = buildat.bignum
buildat.safe.read_image = buildat.read_image
-- The cereal extension's two bindings ([EXTENSIONS_SANDBOXED]): a byte
-- string and a type list in, values out, or the reverse
buildat.safe.cereal_binary_input = function(data, types)
	if type(data) ~= 'string' then
		error("data not string")
	end
	if type(types) ~= 'table' then
		error("types not table")
	end
	return __buildat_cereal_binary_input(data, types)
end
buildat.safe.cereal_binary_output = function(values, types)
	if type(values) ~= 'table' then
		error("values not table")
	end
	if type(types) ~= 'table' then
		error("types not table")
	end
	return __buildat_cereal_binary_output(values, types)
end
-- connection_encrypted() -> whether the server connection is under TLS:
-- a web client on an https page, or a native one joined by https://
buildat.safe.connection_encrypted = function()
	local a = __buildat_server_address() or ""
	return __buildat_get_env("BUILDAT_PAGE_HTTPS") == "1" or
			a:match("^https://") ~= nil or a:match("^wss://") ~= nil
end
-- server_address() -> the address the server was joined by, as it was given
-- ("host:port", "https://host:port"); nil when not joined
buildat.safe.server_address = function()
	return __buildat_server_address()
end
-- get_cache_path() -> the directory those two work in. The share and user
-- paths stay out of the sandbox; this is here because writing a file under
-- the cache means knowing where the cache is.
buildat.safe.get_cache_path           = function()
	return __buildat_get_path("cache")
end
-- What stopped a ray cast by cast_voxel_rays(); see its comment in
-- src/lua_bindings/voxel_volume.cpp
buildat.safe.VOXEL_RAY = {
	BLOCKED  = 0, -- Ran into something not passable
	NO_DATA  = 1, -- Left the volumes it was given
	RANGE    = 2, -- Used up max_steps
	SKYLIGHT = 3, -- Reached the stop_skylight it was given
}

-- NOTE: Maybe not actually safe
--buildat.safe.class_info = class_info -- Luabind class_info()

buildat.safe.SpatialUpdateQueue = function()
	local internal = __buildat_SpatialUpdateQueue()
	return {
		update = function(self, ...)
			return internal:update(...)
		end,
		set_p = function(self, ...)
			return internal:set_p(...)
		end,
		-- `player` is "the player caused this"; it rides into the queue
		-- and puts the item before the world's own churn ([CLIENT_FRAME])
		put = function(self, safe_p, near_weight, near_trigger_d,
				far_weight, far_trigger_d, value, player)
			if not getmetatable(safe_p) or
					getmetatable(safe_p).type_name ~= "Vector3" then
				error("p is not a sandboxed Vector3 instance")
			end
			p = getmetatable(safe_p).unsafe
			return internal:put(p, near_weight, near_trigger_d,
					far_weight, far_trigger_d, value, player)
		end,
		get = function(self, ...)
			return internal:get(...)
		end,
		peek_next_f = function(self, ...)
			return internal:peek_next_f(...)
		end,
		peek_next_fw = function(self, ...)
			return internal:peek_next_fw(...)
		end,
		peek_next_value = function(self, ...)
			return internal:peek_next_value(...)
		end,
		find = function(self, ...)
			return internal:find(...)
		end,
		get_length = function(self, ...)
			return internal:get_length(...)
		end,
		is_sorting = function(self)
			return internal:is_sorting()
		end,
		set_p = function(self, safe_p)
			if not getmetatable(safe_p) or
					getmetatable(safe_p).type_name ~= "Vector3" then
				error("p is not a sandboxed Vector3 instance")
			end
			p = getmetatable(safe_p).unsafe
			internal:set_p(p)
		end,
		-- Which way the camera looks, for the queue's view term. **A
		-- method the C++ has and this table does not is a nil call that
		-- kills the handler it is in** (2026-09-26: set_dir raised every
		-- frame, voxelworld's whole update went with it and 3024 chunks
		-- stood undrawn).
		set_dir = function(self, safe_dir)
			if not getmetatable(safe_dir) or
					getmetatable(safe_dir).type_name ~= "Vector3" then
				error("dir is not a sandboxed Vector3 instance")
			end
			internal:set_dir(getmetatable(safe_dir).unsafe)
		end,
	}
end

-- TODO: Implement sandbox unwrapping in C++ and remove these from here
--       (already done in lua_bindings/voxel.cpp)

-- voxel_reg, atlas_reg, and then where this block's (0, 0, 0) sits in the
-- world, which is what a voxel of uv_scale > 1 takes its slice of the
-- repeat from ([WORLD_UV]). Required ([VOXEL_GEOMETRY_ORIGIN]): a block
-- with no world position passes 0, 0, 0.
function buildat.safe.set_8bit_voxel_geometry(safe_node, w, h, d, safe_buffer,
		voxel_reg, atlas_reg, ox, oy, oz)
	if type(ox) ~= "number" or type(oy) ~= "number" or
			type(oz) ~= "number" then
		error("set_8bit_voxel_geometry(): the origin ox, oy, oz is required"..
				" (where the block's (0, 0, 0) sits in the world; 0, 0, 0"..
				" for one with no world position)", 2)
	end
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_8bit_voxel_geometry(node, w, h, d, buffer,
			voxel_reg, atlas_reg, ox, oy, oz)
end

-- origin, {x=, y=, z=} or a Vector3, is where the volume's inside
-- (0, 0, 0) sits in the world ([WORLD_UV]); nil for a model of its own
function buildat.safe.set_voxel_geometry(safe_node, safe_buffer, voxel_reg,
		atlas_reg, use_skylight, material_cb, horizon, origin)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	-- Every argument: luabind matches by count
	__buildat_set_voxel_geometry(node, buffer, voxel_reg, atlas_reg,
			use_skylight or false, material_cb, horizon,
			origin and {x = origin.x, y = origin.y, z = origin.z})
end

-- set_voxel_data(node, data): a chunk node's voxel data from a serialized
-- volume, for a predicted dig or place; see src/lua_bindings/misc_urho3d.cpp
function buildat.safe.set_voxel_data(safe_node, data)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(data) ~= "string" then
		error("data is not a string")
	end
	__buildat_set_voxel_data(getmetatable(safe_node).unsafe, data)
end

-- get_voxel_data(node) -> string: the same var as it is
function buildat.safe.get_voxel_data(safe_node)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	return __buildat_get_voxel_data(getmetatable(safe_node).unsafe)
end

-- set_mesh_bounce(r, g, b): the light the unpacked mesher bakes into every
-- face the sky does not reach, for meshes made after it; nil restores the
-- default. See src/interface/mesh.h set_bounce_color()
function buildat.safe.set_mesh_bounce(r, g, b)
	if r == nil then
		r, g, b = 0.055, 0.050, 0.045
	end
	for _, v in ipairs({r, g, b}) do
		if type(v) ~= "number" or not (v >= 0 and v <= 1) then
			error("set_mesh_bounce: a colour channel is not in 0...1")
		end
	end
	__buildat_set_mesh_bounce(r, g, b)
end

-- set_mesh_alpha_nibbles(on): the unpacked mesher's alpha as the sky and the
-- shade in a nibble each, for meshes made after it. See src/interface/mesh.h
-- set_alpha_nibbles()
function buildat.safe.set_mesh_alpha_nibbles(on)
	__buildat_set_mesh_alpha_nibbles(on == true)
end

-- column_heights(buffer, voxel_reg) -> string; see src/lua_bindings/mesh.cpp
function buildat.safe.column_heights(safe_buffer, ...)
	local buffer
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	return __buildat_column_heights(buffer, ...)
end

function buildat.safe.set_voxel_lod_geometry(lod, safe_node, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_voxel_lod_geometry(lod, node, buffer, ...)
end

function buildat.safe.set_quad_geometry(safe_node, quads)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(quads) ~= "table" then
		error("quads is not a table")
	end
	return __buildat_set_quad_geometry(getmetatable(safe_node).unsafe, quads)
end

-- set_triangle_geometry(node, verts): a triangle list, 12 numbers a vertex
-- (position, normal, colour, texture coordinate), as the node's
-- CustomGeometry; see src/lua_bindings/mesh.cpp
function buildat.safe.set_triangle_geometry(safe_node, verts)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(verts) ~= "table" then
		error("verts is not a table")
	end
	-- Anything not a number reads as 0 in the engine (lua_tonumber)
	return __buildat_set_triangle_geometry(getmetatable(safe_node).unsafe, verts)
end

-- set_image_data(image, values): all of an Image's bytes from a flat list
-- of numbers from 0 to 1, rows from the top; see src/lua_bindings/mesh.cpp
function buildat.safe.set_image_data(safe_image, values)
	if not getmetatable(safe_image) or
			getmetatable(safe_image).type_name ~= "Image" then
		error("image is not a sandboxed Image instance")
	end
	if type(values) ~= "table" then
		error("values is not a table")
	end
	return __buildat_set_image_data(getmetatable(safe_image).unsafe, values)
end

-- set_line_geometry(node, verts): a line list, 7 numbers a vertex
-- (position, colour), as the node's CustomGeometry; see
-- src/lua_bindings/mesh.cpp
function buildat.safe.set_line_geometry(safe_node, verts)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(verts) ~= "table" then
		error("verts is not a table")
	end
	return __buildat_set_line_geometry(getmetatable(safe_node).unsafe, verts)
end

-- set_cell_geometry(node, cells, size, r, g, b, a, v): a volume of cubic
-- cells as the node's CustomGeometry, v the texture coordinate's second
-- half on every vertex (0 unless given); see src/lua_bindings/mesh.cpp
function buildat.safe.set_cell_geometry(safe_node, cells, size, r, g, b, a, v)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if type(cells) ~= "table" or type(size) ~= "number" then
		error("cells is not a table or size is not a number")
	end
	for _, v in ipairs(cells) do
		if type(v) ~= "number" then
			error("cells holds something that is not a number")
		end
	end
	local function num(v)
		return type(v) == "number" and v or 1
	end
	return __buildat_set_cell_geometry(getmetatable(safe_node).unsafe, cells,
			size, num(r), num(g), num(b), num(a), type(v) == "number" and v or 0)
end

function buildat.safe.clear_voxel_geometry(safe_node)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	__buildat_clear_voxel_geometry(node)
end

function buildat.safe.set_voxel_physics_boxes(safe_node, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_voxel_physics_boxes(node, buffer, ...)
end

function buildat.safe.clear_voxel_physics_boxes(safe_node)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	__buildat_clear_voxel_physics_boxes(node)
end

local Vector3_prototype = {
	x = 0,
	y = 0,
	z = 0,
	dump = function(a)
		return "("..a.x..", "..a.y..", "..a.z..")"
	end,
	eq = function(a, b)
		return (a.x == b.x and a.y == b.y and a.z == b.z)
	end,
	mul_components = function(a, b)
		return buildat.safe.Vector3(
				a.x * b.x, a.y * b.y, a.z * b.z)
	end,
	div_components = function(a, b)
		return buildat.safe.Vector3(
				a.x / b.x, a.y / b.y, a.z / b.z)
	end,
	floor = function(a)
		return buildat.safe.Vector3(
				math.floor(a.x), math.floor(a.y), math.floor(a.z))
	end,
	round = function(a)
		return buildat.safe.Vector3(
				math.floor(a.x+0.5), math.floor(a.y+0.5), math.floor(a.z+0.5))
	end,
	add = function(a, b)
		return buildat.safe.Vector3(
				a.x + b.x, a.y + b.y, a.z + b.z)
	end,
	sub = function(a, b)
		return buildat.safe.Vector3(
				a.x - b.x, a.y - b.y, a.z - b.z)
	end,
	mul = function(a, b)
		return buildat.safe.Vector3(
				a.x * b, a.y * b, a.z * b)
	end,
	div = function(a, b)
		return buildat.safe.Vector3(
				a.x / b, a.y / b, a.z / b)
	end,
	length = function(a)
		return math.sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
	end,
	DotProduct = function(a, b)
		return a.x * b.x + a.y * b.y + a.z * b.z
	end,
	CrossProduct = function(a, b)
		return buildat.safe.Vector3(a.y * b.z - a.z * b.y,
				a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
	end,
}
-- **Urho3D's names** ([VECTOR_NAMES]), as magic.Vector3 has them; the
-- lowercase ones are the same functions, kept until the next break
-- (doc/plan/compatibility_plan.md). `*` and `/` by a vector are by
-- component, as Urho3D's are
local function urho_names(P, new)
	P.Length, P.Equals, P.Floor, P.Round = P.length, P.eq, P.floor, P.round
	P.Normalized = function(a)
		local l = a:length()
		return l > 0 and a:div(l) or new(a)
	end
	P.__mul = function(a, b)
		if type(b) == "table" then return a:mul_components(b) end
		return a:mul(b)
	end
	P.__div = function(a, b)
		if type(b) == "table" then return a:div_components(b) end
		return a:div(b)
	end
end
urho_names(Vector3_prototype, function(a) return buildat.safe.Vector3(a) end)

function buildat.safe.Vector3(x, y, z)
	local self = {}
	if x ~= nil and y == nil and z == nil then
		assert(type(x.x) == "number" and type(x.y) == "number" and
				type(x.z) == "number")
		self.x = x.x
		self.y = x.y
		self.z = x.z
	else
		self.x = x
		self.y = y
		self.z = z
	end
	setmetatable(self, {
		__index = Vector3_prototype,
		__eq = Vector3_prototype.eq,
		__add = Vector3_prototype.add,
		__sub = Vector3_prototype.sub,
		__mul = Vector3_prototype.__mul,
		__div = Vector3_prototype.__div,
	})
	return self
end

local Vector2_prototype = {
	x = 0,
	y = 0,
	dump = function(a)
		return "("..a.x..", "..a.y..")"
	end,
	eq = function(a, b)
		return (a.x == b.x and a.y == b.y)
	end,
	mul_components = function(a, b)
		return buildat.safe.Vector2(
				a.x * b.x, a.y * b.y)
	end,
	div_components = function(a, b)
		return buildat.safe.Vector2(
				a.x / b.x, a.y / b.y)
	end,
	floor = function(a)
		return buildat.safe.Vector2(
				math.floor(a.x), math.floor(a.y))
	end,
	round = function(a)
		return buildat.safe.Vector2(
				math.floor(a.x+0.5), math.floor(a.y+0.5))
	end,
	add = function(a, b)
		return buildat.safe.Vector2(
				a.x + b.x, a.y + b.y)
	end,
	sub = function(a, b)
		return buildat.safe.Vector2(
				a.x - b.x, a.y - b.y)
	end,
	mul = function(a, b)
		return buildat.safe.Vector2(
				a.x * b, a.y * b)
	end,
	div = function(a, b)
		return buildat.safe.Vector2(
				a.x / b, a.y / b)
	end,
	length = function(a)
		return math.sqrt(a.x*a.x + a.y*a.y)
	end,
	DotProduct = function(a, b)
		return a.x * b.x + a.y * b.y
	end,
}
urho_names(Vector2_prototype, function(a) return buildat.safe.Vector2(a) end)

function buildat.safe.Vector2(x, y)
	local self = {}
	if x ~= nil and y == nil then
		assert(type(x.x) == "number" and type(x.y) == "number")
		self.x = x.x
		self.y = x.y
	else
		self.x = x
		self.y = y
	end
	setmetatable(self, {
		__index = Vector2_prototype,
		__eq = Vector3_prototype.eq,
		__add = Vector2_prototype.add,
		__sub = Vector2_prototype.sub,
		__mul = Vector2_prototype.__mul,
		__div = Vector2_prototype.__div,
	})
	return self
end

-- vim: set noet ts=4 sw=4:
