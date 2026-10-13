-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [UNDERGROUND_LIGHT]: /fixlight's radius forms, and the daylight they put
-- back. The world is made fresh, a patch of it is darkened the way a
-- half-finished relight left one (every voxel's sky nibble zeroed through
-- VoxelManip), and the command is asked to bring it back.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_LUA=builtin/luanti/test/fixlight.lua \
--       bin/buildat_server -m ../apps/vanilla -D ../user -P 29791
core.register_on_joinplayer(function(player)
	core.after(25, function()
		local p = player:get_pos()
		local X, Z = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
		local name = player:get_player_name()
		-- The client's drive waits for the chat line
		local function done()
			core.log("warning", "fixcheck: done")
			core.chat_send_player(name, "fixcheck: done")
		end
		core.set_player_privs(name, {server = true, privs = true})
		local cmd = core.registered_chatcommands["fixlight"]
		if not cmd then
			core.log("warning", "fixcheck: no fixlight command at all")
			done()
			return
		end
		-- **The boxes first**: the command's own answer names the area it
		-- worked on, which is the only thing that says a bare radius
		-- reached the right one
		for _, param in ipairs({"", "48", " 8 ", "nonsense"}) do
			local ok, msg = cmd.func(name, param)
			core.log("warning", string.format("fixcheck: box [%s] %s %s",
					param, tostring(ok), tostring(msg):gsub("[^%-%d%.,%(%)]", "")))
		end
		-- The surface over the player, which a made world lights
		local surface
		for y = 120, -20, -1 do
			local n = core.get_node({x = X, y = y, z = Z})
			if n.name ~= "air" and n.name ~= "ignore" then surface = y break end
		end
		if not surface then
			core.log("warning", "fixcheck: no surface under the player")
			done()
			return
		end
		local air = {x = X, y = surface + 6, z = Z}
		local function light() return core.get_node_light(air, 0.5) end
		core.log("warning", "fixcheck: made surface=" .. surface ..
				" open air light=" .. tostring(light()))
		done()
	end)
end)
-- vim: set noet ts=4 sw=4:
