-- Buildat: apps/demo_skelenti/main/client_lua/join.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [SKELENTI_LOGIN_GATE] A join that is not the launcher's own logs in
-- through builtin/accounts; after the login the server sends the world, or
-- world_menu while none runs
local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("skelenti: could not load accounts.lua: " .. tostring(err))
end
accounts.start({title = "skelenti"})
-- vim: set noet ts=4 sw=4:
