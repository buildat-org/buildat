-- Buildat: apps/workbench/main/client_lua/join.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [WORKBENCH_PROJECTS] Every join logs in first, through
-- builtin/accounts (skeldat's join.lua): an admin then gets Manage (no
-- project running), the rest the wait for the project. [WB_LAN] The
-- launcher's own user without the dialog; the account is the pause menu's
-- My account..., not a corner button
local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("workbench: could not load accounts.lua: " .. tostring(err))
end
accounts.no_account_button()
accounts.start({title = "Workbench", local_login = true})
-- vim: set noet ts=4 sw=4:
