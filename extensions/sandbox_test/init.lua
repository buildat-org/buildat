-- Buildat: extension/sandbox_test/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sandbox_test")
local dump = buildat.dump
-- The hostile launch UI, sandboxed. The trusted half that Ctrl+F12 runs
-- is client/core/sandbox_scan.
local M = {}

-- **The hostile launch UI** ([LAUNCH_SANDBOX]'s done-when): selected
-- like any other -- `-m sandbox_test`, or the `launch_ui` preference --
-- and it spends its boot trying to reach past the verbs instead of
-- drawing anything. What it could reach is one log line, which is what
-- extensions/sandbox_test/check.sh reads.
function M.boot(action)
	local attack = buildat.run_extension_file("launch_attack.lua")
	if type(attack) ~= "table" then
		log:error("sandbox_test: launch_attack.lua did not load")
		return
	end
	attack.run()
	-- **The whitelist's other half**, in the same boot ([URHO_SWEEP]):
	-- the attack says what cannot be reached, and `tests/safe.lua` says
	-- that what was wrapped works -- a class added to the whitelist and
	-- silently doing nothing is the fault that sweep exists to avoid.
	-- It ran only behind Ctrl+F12 before, which no check presses.
	-- This boot is sandboxed code itself, so the file is run through the
	-- sandbox's own verb rather than read off the disk
	-- **The file's own answer, not the call's**: a sandboxed file that
	-- raises is caught inside run_extension_file, which then answers nil
	-- and an error -- so a pcall around it says "fine" about a file that
	-- failed every assertion in it (2026-09-25). wrapped.lua ends with
	-- `return true`, and that is what is read.
	local ok, ret = pcall(function()
		return buildat.run_extension_file("wrapped.lua")
	end)
	if ok and ret == true then
		log:info("launch sandbox: the safe tests passed")
	else
		log:error("launch sandbox: the safe tests failed (" ..
				tostring(ret) .. "); the raise is in the lines above")
	end
end

return M
-- vim: set noet ts=4 sw=4:
