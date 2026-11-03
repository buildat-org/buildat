-- Buildat: apps/skeldat/main/client_lua/join.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [WORLD_MENU_ADMIN] Every join (but check.sh's guests) logs in through
-- builtin/accounts; after the login the server sends the world menu, or
-- the world if one has started meanwhile. [SK_OWNER_NO_ADMIN_PAGES] The
-- launcher's own user without the dialog ([WB_LAN]'s local_login)
local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("skeldat: could not load accounts.lua: " .. tostring(err))
end
-- [SKELDAT_PAUSE_ACCOUNT] No corner Server button (every public join
-- comes here, [SKELDAT_LOGIN]): the pause menu has My account...
accounts.no_account_button()
accounts.start({title = "skeldat", local_login = true})
-- vim: set noet ts=4 sw=4:
