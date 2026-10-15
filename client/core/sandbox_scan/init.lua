-- Buildat: client/core/sandbox_scan/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sandbox_test")
local dump = buildat.dump
-- The trusted half of the sandbox's tests, which Ctrl+F12 runs: safe
-- code runs, bytecode and the standard libraries do not, and the exploit
-- search walks what the sandbox can reach. The hostile launch UI is
-- extensions/sandbox_test, sandboxed like any other.
local try_exploit = dofile(buildat.extension_path("sandbox_scan").."/try_exploit.lua")
local M = {}

local function get_file_content(path)
	local f = io.open(path, "rb")
	if not f then
		log:error("Could not open file "..dump(path))
		return nil
	end
	local content = f:read("*all")
	f:close()
	return content
end

local function run_in_sandbox(content, chunkname)
	local sandbox_status = nil
	local f = function()
		sandbox_status = __buildat_run_code_in_sandbox(content, chunkname)
	end
	local status, err = __buildat_pcall(f)
	if err then
		log:verbose(err)
	end
	return sandbox_status
end

function M.run()
	log:info("sandbox_test(): Begin")
	local ext_path = buildat.extension_path("sandbox_scan")

	-- Check that running safe code works
	log:info("sandbox_test(): Testing safe code")
	local safe_content = get_file_content(ext_path.."/tests/safe.lua")
	assert(safe_content)
	local success = run_in_sandbox(safe_content, "=safe.lua")
	assert(success)

	-- Check that running the safe code as bytecode doesn't work
	log:info("sandbox_test(): Testing bytecode")
	local f, err = loadstring(safe_content)
	if f == nil then
		error("Could not load bytecode source: "..err)
	end
	local bytecode = string.dump(f)
	local success = run_in_sandbox(bytecode)
	assert(success == false)

	-- Check that the standard libraries cannot be required
	log:info("sandbox_test(): Testing require")
	local require_content = get_file_content(ext_path.."/tests/require.lua")
	assert(require_content)
	local success = run_in_sandbox(require_content, "=require.lua")
	assert(success)

	-- Run the exploit search
	log:info("sandbox_test(): Trying to find an exploit")
	try_exploit.run()

	log:info("sandbox_test(): Finished")
end

-- Armed by toggle() (Ctrl+F12), not by loading: a sandboxed file's
-- require("buildat/extension/sandbox_test") loads this file before
-- learning it has no safe interface, and armed at load the walk ran in
-- every client from the menu on ([UI_UAF], 2026-09-20).
local value_checker_enabled = false
function M.check_value(value)
	if not value_checker_enabled then return end
	log:debug("sandbox_test.check_value()")
	try_exploit.search_single_value(value)
end
__buildat_sandbox_debug_check_value_sub(M.check_value)

local is_active = false

function M.toggle() -- Called by client/app
	if not is_active then
		M.run()
		value_checker_enabled = true
		is_active = true
	else
		value_checker_enabled = false
		is_active = false
	end
end

return M
-- vim: set noet ts=4 sw=4:
