-- Buildat: apps/skeldat/main/client_lua/join.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [WORLD_MENU_ADMIN] A public server's join while no world runs, through
-- builtin/accounts; after the login the server sends the world menu, or
-- the world if one has started meanwhile
local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("skeldat: could not load accounts.lua: " .. tostring(err))
end
accounts.start({title = "skeldat"})
-- vim: set noet ts=4 sw=4:
