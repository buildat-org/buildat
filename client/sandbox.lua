-- Buildat: client/sandbox.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sandbox")
local dump = buildat.dump

--
-- Base sandbox environment
--

__buildat_sandbox_environment = {
	assert = assert, -- Safe according to http://lua-users.org/wiki/SandBoxes
	error = error,
	-- Base sandbox from
	-- http://stackoverflow.com/questions/1224708/how-can-i-create-a-secure-lua-sandbox/6982080#6982080
	ipairs = ipairs,
	next = next,
	pairs = pairs,
	pcall = pcall,
	select = select,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	unpack = unpack,
	coroutine = { create = coroutine.create, resume = coroutine.resume,
		running = coroutine.running, status = coroutine.status,
		wrap = coroutine.wrap },
	string = { byte = string.byte, char = string.char, find = string.find,
		format = string.format, gmatch = string.gmatch, gsub = string.gsub,
		len = string.len, lower = string.lower, match = string.match,
		rep = string.rep, reverse = string.reverse, sub = string.sub,
		upper = string.upper },
	table = { concat = table.concat, insert = table.insert,
		maxn = table.maxn, remove = table.remove, sort = table.sort },
	math = { abs = math.abs, acos = math.acos, asin = math.asin,
		atan = math.atan, atan2 = math.atan2, ceil = math.ceil, cos = math.cos,
		cosh = math.cosh, deg = math.deg, exp = math.exp, floor = math.floor,
		fmod = math.fmod, frexp = math.frexp, huge = math.huge,
		ldexp = math.ldexp, log = math.log, log10 = math.log10, max = math.max,
		min = math.min, modf = math.modf, pi = math.pi, pow = math.pow,
		rad = math.rad, random = math.random, sin = math.sin, sinh = math.sinh,
		sqrt = math.sqrt, tan = math.tan, tanh = math.tanh },
	os = { clock = os.clock, difftime = os.difftime, time = os.time },
}

--
-- Read-only views
--

-- [SAFE_TABLE_PATCH]: **what the sandbox is handed is a view, not the
-- table**. An extension's .safe table is the same table trusted code
-- calls through -- the network permission dialog draws with
-- ui_utils.safe.vertical_menu and pushes on uistack.safe.main -- so a
-- game that assigned into it drew, labelled and answered the dialog.
-- A view reads through to the table, nested tables as views too, and
-- refuses every assignment; a table whose metatable takes assignments
-- itself is handed out as it is. A function read through a view gets its
-- view arguments back as the tables they show, so a method keeps
-- working (uistack.main:push() writes into the real stack).
-- simplified: # and the table library see a view as empty, and a table
-- a function returns is the table itself, not a view; a .safe function
-- that hands out shared state has to copy it.
local view_of = setmetatable({}, {__mode = "k"}) -- table -> its view
local real_of = setmetatable({}, {__mode = "k"}) -- view -> its table
local wrapper_of = setmetatable({}, {__mode = "k"}) -- function -> wrapper
local wrapped = setmetatable({}, {__mode = "k"}) -- wrapper -> function

-- What a view or a wrapper stands for, or nil: the exploit search walks
-- that, since a view's table and a wrapper's function are what the
-- sandbox reaches (client/core/sandbox_scan). Trusted only.
function __buildat_sandbox_seen_through(v)
	return real_of[v] or wrapped[v]
end

local function unwrap(n, a)
	for i = 1, n do
		local r = real_of[a[i]]
		if r then a[i] = r end
	end
	return unpack(a, 1, n)
end

-- **Only a method is wrapped** (2026-10-03, [WEB_BLANK]): a function at
-- a module's own level (magic.SubscribeToEvent, buildat.storage_read) is
-- handed out as it is, since it reads its caller's frame -- getfenv(2),
-- debug.getinfo -- and the web client's Lua 5.1 raises "no function
-- environment for tail call" through a wrapper, which blanked the 0.5.67
-- web client. A function a level further in (uistack.main.push) is
-- wrapped, so that a view passed to it as self is the table again.
local view
local depth_of = setmetatable({}, {__mode = "k"}) -- view -> its depth
local function shown(v, depth)
	local t = type(v)
	if t == "table" then
		return view(v, depth + 1)
	elseif t == "function" and depth >= 2 then
		local w = wrapper_of[v]
		if not w then
			w = function(...)
				return v(unwrap(select("#", ...), {...}))
			end
			wrapper_of[v] = w
			wrapped[w] = v
		end
		return w
	end
	return v
end

view = function(t, depth)
	depth = depth or 1
	if real_of[t] then return t end
	-- A wrapped object (magic.ui.root) has its own __newindex, which is
	-- the sandbox's way of setting a property, and it checks the write
	local mt = getmetatable(t)
	if type(mt) == "table" and mt.__newindex then return t end
	local p = view_of[t]
	if p then return p end
	p = setmetatable({}, {
		__index = function(_, k) return shown(t[k], depth) end,
		__newindex = function(_, k)
			error("sandbox: "..tostring(k).." is read-only here", 2)
		end,
		__call = function(_, ...) return t(unwrap(select("#", ...), {...})) end,
		__metatable = false,
	})
	view_of[t] = p
	real_of[p] = t
	depth_of[p] = depth
	return p
end

-- Iterating a view walks the table under it
local function view_next(p, k)
	local nk, v = next(real_of[p], k)
	return nk, shown(v, depth_of[p] or 1)
end
__buildat_sandbox_environment.next = function(t, k)
	if real_of[t] then return view_next(t, k) end
	return next(t, k)
end
__buildat_sandbox_environment.pairs = function(t)
	if real_of[t] then return view_next, t, nil end
	return pairs(t)
end
__buildat_sandbox_environment.ipairs = function(t)
	local r = real_of[t]
	if not r then return ipairs(t) end
	return function(_, i)
		i = i + 1
		local v = r[i]
		if v ~= nil then return i, shown(v, depth_of[t] or 1) end
	end, t, 0
end
-- The standard tables too, one sandboxed script not rewriting
-- string.format under another; their functions take no views and are
-- handed out as they are
for _, k in ipairs({"coroutine", "string", "table", "math", "os"}) do
	local t = __buildat_sandbox_environment[k]
	local p = setmetatable({}, {
		__index = t,
		__newindex = function(_, k)
			error("sandbox: "..tostring(k).." is read-only here", 2)
		end,
		__metatable = false,
	})
	real_of[p] = t
	__buildat_sandbox_environment[k] = p
end
-- **And the string metatable**, which every string shares with the host:
-- ("").dump was string.dump past the curated table above ([SANDBOX_HUNT],
-- 2026-10-03). Strings' methods are the curated ones, in and out of the
-- sandbox; the host keeps the whole library as `string`.
getmetatable("").__index = real_of[__buildat_sandbox_environment.string]

--
-- Sandbox require
--

-- Two namespaces are loadable from inside the sandbox and nothing else is:
-- an extension's safe interface, and a module's client half.
--
-- **package.loaded is not a whitelist and must never be searched by name**,
-- which is what this used to do before looking at either namespace. It
-- holds every standard library the host state has -- so require("os")
-- handed the sandbox os.execute, require("io") handed it io.open,
-- require("package") handed it loadlib and require("_G") handed it
-- loadstring, none of which are anywhere near the sandbox environment
-- itself. A server's client Lua runs in here, so that was the server
-- running what it liked on the machine of everyone who connected to it.
-- Each namespace looks in package.loaded under its own full name, which is
-- what it was written under.
__buildat_sandbox_environment.require = function(name)
	log:debug("require(\""..name.."\")")
	-- Allow loading the client core's parts and extensions, a core part
	-- kept under its one name whichever it was asked by
	local m, key = __buildat_extension_of(name)
	if m then
		name = key
		local unsafe = package.loaded[name]
		if unsafe == nil then
			unsafe = __buildat_require_extension(m)
			if unsafe == nil then
				error("require: Cannot load extension: \""..m.."\"")
			end
			package.loaded[name] = unsafe
			log:verbose("Loaded extension \""..name.."\"")
		end
		if type(unsafe) ~= 'table' or type(unsafe.safe) ~= 'table' then
			error("require: \""..name.."\" didn't return safe interface")
		end
		return view(unsafe.safe)
	end
	-- Allow loading the client-side parts of modules
	local m = string.match(name, '^buildat/module/([a-zA-Z0-9_]+)$')
	if m then
		local interface = package.loaded[name]
		if interface == nil then
			interface = __buildat_require_module(m)
			if interface == nil then
				error("require: Cannot load module: \""..m.."\"")
			end
			package.loaded[name] = interface
			log:verbose("Loaded module \""..name.."\"")
		end
		return interface
	end
	-- Disallow loading anything else
	error("require: \""..name.."\" not found in sandbox")
end

-- What a connection's sandboxed scripts left behind, dropped, so that a
-- menu-only connection can be left for the launcher without exiting the
-- client ([MENU_CONTEXT]): the packet handlers, the module halves'
-- require cache, the event mux's sandbox handlers, and the replicated
-- scene's children (the game's camera, zone, sky). The UI stack is the
-- launcher's to pop. simplified: what the module halves put in C++ --
-- composed textures, the voxel registry -- stays; a new connection
-- replaces it by name.
function __buildat_reset_sandbox()
	__buildat_reset_packet_subs()
	-- The join's loading screen, if it is still up ([JOIN_STRIPES])
	local ui_utils = __buildat_loaded_extension("ui_utils")
	if ui_utils then
		pcall(ui_utils.safe.join_screen, "left")
	end
	for name, _ in pairs(package.loaded) do
		if string.match(name, '^buildat/module/') then
			package.loaded[name] = nil
		end
	end
	__buildat_reset_modules()
	__buildat_game_settings_reset()
	-- **These two never ran**: an extension is not in package.loaded --
	-- the loader keeps its own table -- so both lookups read nil from
	-- the day they were written (found 2026-09-23 by [LAUNCH_WORLD]).
	-- __buildat_loaded_extension() is the table's own reader, and it
	-- does not load an extension that is not up.
	local urho3d = __buildat_loaded_extension("urho3d")
	if urho3d and urho3d.drop_sandbox_handlers then
		-- **The launch UI's own handlers stay**: it is sandboxed code
		-- too now ([LAUNCH_SANDBOX]), and dropping them left the room
		-- drawing and answering nothing after a game (2026-09-23)
		urho3d.drop_sandbox_handlers(__buildat_menu_extension_name)
	end
	local replicate = __buildat_loaded_extension("replicate")
	if replicate and replicate.reset then
		replicate.reset()
	end
	log:info("__buildat_reset_sandbox(): done")
end

--
-- Sandbox environment debugging
--

-- Bindings for debug or safety checks (override function)
local __buildat_sandbox_debug_check_value_subs = {}
function __buildat_sandbox_debug_check_value_sub(f)
	table.insert(__buildat_sandbox_debug_check_value_subs, f)
end
function __buildat_sandbox_debug_check_value(value)
	for _, f in ipairs(__buildat_sandbox_debug_check_value_subs) do
		f(value)
	end
end

-- For debugging purposes. Used by client/core/sandbox_scan.
__buildat_latest_sandbox_global_wrapper_number = 0 -- Incremented every time
__buildat_latest_sandbox_global_wrapper = nil
-- Save a number of old wrappers for debugging purposes
__buildat_old_sandbox_global_wrappers = {}

-- A ring of the last 300, overwritten in place ([SANDBOX_CALLS]): a
-- table.remove(list, 1) on it shifted all of them a call
local old_wrapper_i = 0
local function debug_new_wrapper(sandbox)
	if __buildat_latest_sandbox_global_wrapper then
		old_wrapper_i = old_wrapper_i % (60*5) + 1
		__buildat_old_sandbox_global_wrappers[old_wrapper_i] =
				__buildat_latest_sandbox_global_wrapper
	end
	__buildat_latest_sandbox_global_wrapper_number = __buildat_latest_sandbox_global_wrapper_number + 1
	__buildat_latest_sandbox_global_wrapper = sandbox
end

--
-- Running code in sandbox
--

local function wrap_globals(base_sandbox)
	local sandbox = {}
	local sandbox_declared_globals = {}
	-- Sandbox special functions
	sandbox.sandbox = {}
	function sandbox.sandbox.make_global(t)
		for k, v in pairs(t) do
			if sandbox[k] == nil then
				rawset(sandbox, k, v)
			end
		end
	end
	-- Prevent setting sandbox globals from functions (only from the main chunk)
	setmetatable(sandbox, {
		__index = function(t, k)
			local v = rawget(sandbox, k)
			if v ~= nil then return v end
			return base_sandbox[k]
		end,
		__newindex = function(t, k, v)
			if not sandbox_declared_globals[k] then
				local info = debug.getinfo(2, "Sl")
				log:debug("Global: "..dump(k).." (set by {what="..dump(info.what)..
						", name="..dump(info.name).."})")
				if info.what == "Lua" then
					error("Assignment to undeclared global \""..k.."\"\n     in "..
							info.short_src.." line "..info.currentline)
				end
			end
			sandbox_declared_globals[k] = true
			rawset(sandbox, k, v)
		end
	})
	debug_new_wrapper(sandbox)
	return sandbox
end

local function run_function_in_sandbox(untrusted_function, sandbox, own_globals)
	sandbox = wrap_globals(sandbox)
	for k, v in pairs(own_globals or {}) do
		rawset(sandbox, k, v)
	end
	setfenv(untrusted_function, sandbox)
	local retval = nil
	local status, err = __buildat_pcall(function()
		retval = untrusted_function()
	end)
	return status, err, retval
end

-- A caught error shown, not only logged ([MENU_ERRORS]): before a world
-- is joined -- the launch menu and every screen on the stack -- a dialog
-- with the message's first line and "the log has the rest", the screen
-- it happened on left as it is; in a game a notice line, since a form's
-- callback erroring must not take the mouse. One per distinct message
-- a minute, so a per-frame error is one dialog and a log full. The
-- box's Connect died in its pcall and the screen just went back
-- (2026-09-22).
local reported_at = {}
-- The last caught errors in full, the message and its traceback, for
-- Copy ([LOG_REACH]): at most 10 and 64 KB, the oldest dropped first
local recent_errors, recent_bytes = {}, 0
-- The client's version and platform, then the errors, newest last; or
-- only err's, given one
function __buildat_errors_text(err)
	local list = err and {tostring(err)} or recent_errors
	local head = "Buildat " .. tostring(__buildat_version()) .. ", " ..
			tostring(GetPlatform()) .. "\n"
	if #list == 0 then
		return head .. "\n(no errors caught since the client started)\n"
	end
	return head .. "\n" .. table.concat(list, "\n\n") .. "\n"
end
function __buildat_report_error(err)
	local first = tostring(err):match("^[^\n]*") or tostring(err)
	local now = os.time()
	if reported_at[first] and now - reported_at[first] < 60 then
		return
	end
	reported_at[first] = now
	local full = tostring(err):sub(1, 65536)
	recent_errors[#recent_errors + 1] = full
	recent_bytes = recent_bytes + #full
	while #recent_errors > 10 or recent_bytes > 65536 do
		recent_bytes = recent_bytes - #table.remove(recent_errors, 1)
	end
	local ui_utils = __buildat_loaded_extension("ui_utils") or
			__buildat_require_extension("ui_utils")
	if type(ui_utils) ~= "table" or type(ui_utils.safe) ~= "table" then
		return
	end
	-- A game the launcher started, or a client that says a world is up on
	-- its own screens (luanti_client's session). Whichever extension is
	-- the launcher, not launch_menu by name (buildat.menu_extension).
	local menu = buildat.menu_extension and buildat.menu_extension()
	local in_app = (menu and menu.in_app and menu.in_app()) or
			ui_utils.in_app == true
	local shown = first .. "\n\n(the rest: Copy, or Settings > Logs and errors)"
	log:info("error shown "..(in_app and "as a notice" or "in a dialog")..": "..first)
	if in_app then
		if ui_utils.safe.show_notice then
			ui_utils.safe.show_notice(first ..
					"  (the rest: Settings > Logs and errors)",
					__buildat_errors_text(err))
		end
	elseif ui_utils.safe.show_message_dialog then
		ui_utils.safe.show_message_dialog(shown, nil,
				__buildat_errors_text(err))
	end
end

local function report_failure(err)
	log:error("Failed to run function:\n"..tostring(err))
	local ok, why = pcall(__buildat_report_error, err)
	if not ok then
		log:warning("the error could not be shown: "..tostring(why))
	end
end

function __buildat_run_function_in_sandbox(untrusted_function)
	local status, err, retval = run_function_in_sandbox(
			untrusted_function, __buildat_sandbox_environment)
	if status == false then
		report_failure(err)
	end
	return status, err, retval
end

-- The same for a function run again and again -- an event's delivery,
-- every frame ([SANDBOX_CALLS]): its environment is made once, here,
-- rather than a new one a call. The returned runner takes no arguments;
-- what a call needs, the function reads from its upvalues.
function __buildat_sandboxed_runner(untrusted_function)
	setfenv(untrusted_function, wrap_globals(__buildat_sandbox_environment))
	return function()
		local status, err = __buildat_pcall(untrusted_function)
		if status == false then
			report_failure(err)
		end
	end
end

local function run_code_in_sandbox(untrusted_code, sandbox, chunkname,
		own_globals)
	if untrusted_code:byte(1) == 27 then
		return false, "binary bytecode prohibited", nil
	end
	local untrusted_function, message = loadstring(untrusted_code, chunkname)
	if not untrusted_function then
		return false, message, nil
	end
	return run_function_in_sandbox(untrusted_function, sandbox, own_globals)
end

function __buildat_run_code_in_sandbox(untrusted_code, chunkname)
	local status, err, retval = run_code_in_sandbox(
			untrusted_code, __buildat_sandbox_environment, chunkname)
	if status == false then
		log:error("Failed to run script:\n"..tostring(err))
		local ok, why = pcall(__buildat_report_error, err)
		if not ok then
			log:warning("the error could not be shown: "..tostring(why))
		end
	end
	return status, err, retval
end

-- What core:run_script runs is a server's too (app.cpp's run_script)
__buildat_served_chunks["=server"] = true

-- What a server sends runs with the served buildat and require (below) as
-- its own: core:run_script (app.cpp) and every file it runs by name
local served_globals = {}
function __buildat_run_served_code(code, chunkname)
	local status, err, retval = run_code_in_sandbox(
			code, __buildat_sandbox_environment, chunkname, served_globals)
	if status == false then
		log:error("Failed to run script:\n"..tostring(err))
		local ok, why = pcall(__buildat_report_error, err)
		if not ok then
			log:warning("the error could not be shown: "..tostring(why))
		end
	end
	__buildat_deliver_held_packets()
	return status, err, retval
end

function buildat.run_script_file(name)
	local code = __buildat_get_file_content(name)
	if not code then
		log:error("Failed to load script file: "..name)
		return false
	end
	log:info("buildat.run_script_file("..name.."): code length: "..#code)
	-- A chunk a server served, which the gates in api.lua read as well
	__buildat_served_chunks[name] = true
	return __buildat_run_served_code(code, name)
end
buildat.safe.run_script_file = buildat.run_script_file

--
-- Insert buildat.safe into sandbox as buildat
--

__buildat_sandbox_environment.buildat = {}
for k, v in pairs(buildat.safe) do
	__buildat_sandbox_environment.buildat[k] = v
end

-- With this you can do stuff like
--   local is_in_sandbox = getfenv(2).buildat.is_in_sandbox
-- in extensions.
__buildat_sandbox_environment.buildat.is_in_sandbox = true

-- A view, as the extensions' tables are: a game rewriting buildat.launch
-- would have rewritten it under the launch UI
-- The served buildat: the same, with the user's verbs refusing
-- (api.lua's __buildat_served_overrides)
do
	local t = {}
	for k, v in pairs(__buildat_sandbox_environment.buildat) do
		t[k] = v
	end
	for k, v in pairs(__buildat_served_overrides) do
		t[k] = v
	end
	served_globals.buildat = view(t)
end

-- And require: the extensions as anyone gets them, but the network one
-- without what is the user's alone -- the addresses they have been to,
-- with the descriptions and the names they used there, and the name kept
-- per address -- which any server's script read ([SECURITY_RUN_1]). Only
-- the launch UIs and the client's own extensions ask for them.
do
	local real_require = __buildat_sandbox_environment.require
	local withheld = {known_addresses = true, set_address_name = true,
		unseen_counts = true}
	local network_for_servers
	served_globals.require = function(name)
		local m = real_require(name)
		if __buildat_extension_of(name) ~= "network" then
			return m
		end
		if not network_for_servers then
			local t = {}
			for k, v in pairs(real_of[m] or m) do
				if not withheld[k] then
					t[k] = v
				end
			end
			network_for_servers = view(t)
		end
		return network_for_servers
	end
end
__buildat_sandbox_environment.buildat =
		view(__buildat_sandbox_environment.buildat)

log:info("sandbox.lua loaded")
-- vim: set noet ts=4 sw=4:
