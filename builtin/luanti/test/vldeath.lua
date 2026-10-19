-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Run by hand, by the command below; no runner references it.
-- Does a VoxeLibre player die and come back whole? set_hp(0) runs the
-- game's on_dieplayer (mcl_death_drop over every list it registered) and
-- respawn() its on_respawnplayer (mcl_sprint over its mod channel), and
-- neither may error -- both did, on the fuzz run's fifth seed.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=vldeath \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/vldeath.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
--   vldeath: died and respawned, hp=20
core.register_on_joinplayer(function(player)
	core.after(8, function()
		player:set_hp(0)
		player:respawn()
		assert(player:get_hp() > 0, "vldeath: still dead")
		core.log("action", "vldeath: died and respawned, hp=" .. player:get_hp())
	end)
end)
