-- Buildat: sample_wasm/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [CLIENT_WASM] The module's wasm/ loaded and called: numbers both ways,
-- a buffer written, changed by the module and read back, and the traps.
-- apps/sample_wasm/check.sh reads the lines this logs.
local log = buildat.Logger("sample_wasm")
local magic = require("buildat/extension/urho3d")

local m, why = buildat.wasm_load("main")
assert(m, why)

local function check()
	assert(m:call("add", 2, 3) == 5, "add")
	assert(m:call("add", 2147483647, 1) == -2147483648, "add wraps")
	local x = m:call("mix", 1.5, 0.25, 1000000)
	assert(x == 1000003.25, "mix: "..tostring(x))
	local p = m:call("buffer")
	m:write(p, "hello wasm")
	local sum = m:call("reverse", 10)
	assert(m:read(p, 10) == "msaw olleh", "the buffer reversed")
	log:info("add(2, 3) = "..m:call("add", 2, 3)..", reverse checksum "..sum)
	-- Lua's own mistakes, refused before the module sees them
	assert(not pcall(m.call, m, "add", 1), "too few numbers")
	assert(not pcall(m.call, m, "add", 1.5, 2), "a fraction for an i32")
	assert(not pcall(m.call, m, "nope"), "no such export")
	assert(not pcall(m.read, m, 2^31, 4), "a read past its memory")
	-- The module's, traps, after which it still answers
	local ok, err = pcall(m.call, m, "recurse", 0)
	assert(not ok, "the endless recursion trapped")
	log:info("recursion trap: "..tostring(err))
	ok, err = pcall(m.call, m, "peek", 4294967292)
	assert(not ok, "the read past the memory trapped")
	log:info("memory trap: "..tostring(err))
	assert(m:call("add", 40, 2) == 42, "callable after the traps")
	-- A luaL_error() inside a guarded binding; check.sh reads its message
	-- natively and on the web ([GUARDED_LUA_ERROR], [WEB_LUA_ERROR_EH])
	ok, err = pcall(buildat.decompress, "x", "nope")
	assert(not ok, "an unknown format")
	log:info("guarded luaL_error: "..tostring(err))
	log:info("wasm done: ok")
end

-- Natively the first load compiles in the background
local done = false
magic.SubscribeToEvent("Update", function()
	if done then return end
	local status, err = m:status()
	if status == "loading" then return end
	done = true
	if status ~= "ready" then
		log:error("wasm done: failed: "..tostring(err))
		return
	end
	local ok, e = pcall(check)
	if not ok then
		log:error("wasm done: the check failed: "..tostring(e))
	end
end)
