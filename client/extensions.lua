-- Buildat: client/extensions.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/extensions")

-- Extension interfaces, indexed by extension name
local loaded_extensions = {}

-- [EXTENSIONS_SANDBOXED]: **an extension in extensions/ runs in the
-- sandbox**, as a server's client Lua and a launch UI do. The client
-- core, client/core/, is the client's own and trusted ([CLIENT_CORE]);
-- it loads here the same way. What it returns is kept as it is, so
-- trusted code reads its .safe as before, and the sandbox's require hands
-- out a view of that.

local core_dir = __buildat_get_path("share").."/client/core/"

-- Whether name is a part of the client core rather than an extension
function __buildat_is_core(name)
	return __buildat_extension_path(name):sub(1, #core_dir) == core_dir
end

-- The core part or extension a require name asks for, and the name it is
-- kept under, or nil: buildat/core/<core part> and
-- buildat/extension/<extension>. buildat/extension/<core part> is the
-- name from before [CLIENT_CORE], an alias until the next break (served
-- client Lua uses it, and an older 0.7 client knows no other).
function __buildat_extension_of(name)
	local m = string.match(name, '^buildat/core/([a-zA-Z0-9_]+)$')
	if m then
		if __buildat_is_core(m) then
			return m, name
		end
		return nil
	end
	m = string.match(name, '^buildat/extension/([a-zA-Z0-9_]+)$')
	if m and __buildat_is_core(m) then
		return m, "buildat/core/"..m
	end
	return m, name
end

local function load_trusted(name, path)
	local script, err = loadfile(path)
	if script == nil then
		log:error("Extension could not be opened: "..name.." at "..path..": "..err)
		return nil
	end
	return script()
end

local function load_sandboxed(name, path)
	local f = io.open(path, "rb")
	if not f then
		log:error("Extension could not be opened: "..name.." at "..path)
		return nil
	end
	local code = f:read("*a")
	f:close()
	-- Run as the extension: its buildat is bound to its name
	local ok, err, interface = __buildat_run_code_in_sandbox(code,
			name.."/init.lua", name)
	if not ok then
		log:error("Extension "..name.." raised: "..tostring(err))
		return nil
	end
	return interface
end

-- Called by this file and client/sandbox.lua
function __buildat_require_extension(name)
	log:debug("__buildat_require_extension(\""..name.."\")")
	if loaded_extensions[name] then
		return loaded_extensions[name]
	end
	local dir = __buildat_extension_path(name)
	local path = dir.."/init.lua"
	local interface
	if dir:sub(1, #core_dir) == core_dir then
		interface = load_trusted(name, path)
	else
		interface = load_sandboxed(name, path)
	end
	if interface == nil then
		log:error("Extension returned nil: "..name.." at "..path)
		return nil
	end
	loaded_extensions[name] = interface
	return interface
end

-- An extension that is already loaded, or nil -- **without loading it**,
-- which is what asking for the launcher must not do. The table above is
-- the only record of a loaded extension: `require` puts nothing in
-- `package.loaded` for these names, so every
-- `package.loaded["buildat/extension/..."]` in the tree read nil and the
-- code behind it never ran (found 2026-09-23 by [LAUNCH_WORLD], which
-- wanted the same lookup for its own name).
function __buildat_loaded_extension(name)
	return loaded_extensions[name]
end

-- Don't use package.loaders because for whatever reason it doesn't work in the
-- Windows version at least in Wine
-- TODO: Was that due to the table indexing bug which was fixed by using LuaJIT
--       instead of Lua?
local old_require = require

function require(name)
	log:debug("require called with name=\""..name.."\"")
	local m = __buildat_extension_of(name)
	if m then
		return __buildat_require_extension(m)
	end
	return old_require(name)
end

-- vim: set noet ts=4 sw=4:
