-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Does a dead player come back? set_hp(0) puts the death screen up, and
-- respawn() is what its button calls: the player is alive, at full
-- breath, and somewhere -- the spawn, or wherever an on_respawnplayer
-- callback put them.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=respawn \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/respawn.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
--   respawn: dead hp=0, back hp=20 at (0,8,0), all callbacks ran
--
-- Every on_respawnplayer callback runs, also after one answered true:
-- VoxeLibre's mcl_spawn does, and mcl_burning's extinguish comes after it.
local ran = 0
core.register_on_respawnplayer(function(player)
	ran = ran + 1
	player:set_pos({x = 0, y = 8, z = 0})
	return true
end)
core.register_on_respawnplayer(function()
	ran = ran + 1
end)
core.register_on_joinplayer(function(player)
	core.after(6, function()
		player:set_hp(0)
		local dead = player:get_hp()
		assert(dead == 0, "respawn: set_hp(0) left hp " .. tostring(dead))
		player:respawn()
		local hp = player:get_hp()
		assert(hp > 0, "respawn: still dead after respawn()")
		assert(ran == 2, "respawn: " .. ran .. " of the 2 callbacks ran")
		core.log("action", string.format("respawn: dead hp=%d, back hp=%d at %s, all callbacks ran",
				dead, hp, core.pos_to_string(vector.round(player:get_pos()))))
	end)
end)
