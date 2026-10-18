-- Buildat: apps/hillclimb/main/client_lua/join.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [HC_MULTIPLAYER] 6: a public server's join, through builtin/accounts
-- (skeldat's); after the login the server gives this player a car
local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("hillclimb: could not load accounts.lua: " .. tostring(err))
end
-- [HC_TOUCH_SERVER] No corner Server button: it lay over the touch
-- column's Start, and the pause menu's Settings... has the Server window
accounts.no_account_button()
accounts.start({title = "hillclimb"})
-- vim: set noet ts=4 sw=4:
