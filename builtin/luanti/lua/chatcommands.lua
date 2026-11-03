-- Buildat: builtin/luanti/lua/chatcommands.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- What this tree adds to the chat commands the vendored builtin registers.
-- Loaded straight after vendor/builtin/init.lua, so the commands it changes
-- are already there; nothing under vendor/ is edited for it.

-- **/fixlight with a radius on its own** (user, 2026-09-28). Luanti's own
-- command takes `here [<radius>]` or two positions in parentheses, and what
-- a player wants when a patch of the world is dark is the ground they are
-- standing on: `/fixlight 64` is that radius, and `/fixlight` on its own is
-- 32. Anything else is Luanti's own parameter and is handed to it unread, so
-- `here`, `here 80` and `(x,y,z) (x,y,z)` all still work.
--
-- What wants it is [UNDERGROUND_LIGHT]: a world played before the relight
-- had a sky source of its own is dark in patches, and nothing re-marks those
-- sections, so this is how one is brought back.
do
	local cmd = core.registered_chatcommands and
			core.registered_chatcommands["fixlight"]
	if cmd then
		local orig = cmd.func
		core.override_chatcommand("fixlight", {
			params = "[<radius>] | (here [<radius>]) | (<pos1> <pos2>)",
			func = function(name, param)
				param = tostring(param or "")
				local radius = param:match("^%s*(%d+)%s*$")
				if radius or param:match("^%s*$") then
					return orig(name, "here " .. (radius or "32"))
				end
				return orig(name, param)
			end,
		})
	else
		core.log("warning", "chatcommands.lua: no fixlight to extend")
	end
end

-- **/grant and /revoke on a server's admin** ([SECURITY_RUN_1]): the
-- builtin reads the player's privileges, changes one and writes the lot
-- back -- and an admin's are every privilege there is (get_player_privs),
-- so a /grant of one wrote all of them into the world's own auth entry,
-- where they stayed after the account stopped being an admin or was made
-- again by someone else. For an admin the only news in what comes back
-- is what is missing from it, a revoke: the stored entry loses that and
-- gains nothing.
do
	local set_privs = core.set_player_privs
	core.set_player_privs = function(name, privs)
		if core.__admins and core.__admins[name] then
			local handler = core.get_auth_handler()
			local entry = handler and handler.get_auth(name)
			local stored = table.copy(entry and entry.privileges or {})
			for priv in pairs(core.registered_privileges) do
				if not privs[priv] then
					stored[priv] = nil
				end
			end
			return set_privs(name, stored)
		end
		return set_privs(name, privs)
	end
end

-- vim: set noet ts=4 sw=4:
