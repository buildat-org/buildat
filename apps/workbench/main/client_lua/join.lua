-- Buildat: apps/workbench/main/client_lua/join.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [WORKBENCH_PROJECTS] A join while no project runs logs in first,
-- through builtin/accounts (skeldat's join.lua): an admin then gets
-- Manage, the rest the wait for the project
local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("workbench: could not load accounts.lua: " .. tostring(err))
end
accounts.start({title = "Workbench"})
-- vim: set noet ts=4 sw=4:
