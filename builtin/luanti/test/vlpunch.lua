-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Run by hand, by the command below; no runner references it.
-- Does a punched VoxeLibre mob keep its engine hp? Its mobs are immortal to
-- the engine and keep their own health, and a punch that took a point off
-- the engine's hp beside it removed the mob at zero -- [PUNCH_VANISH].
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=vlpunch \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/vlpunch.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- A pig beside the player, punched three times through the same
-- ObjectRef:punch a client's punch comes to. hp stays; health drops once
-- and then VoxeLibre's own invulnerability window holds it:
--
--   vlpunch: pig hp=10 health=10 immortal=1
--   vlpunch: after punch 1 hp=10 health=9 alive=true
--
-- The timer is generous: core.after() ran eighteen seconds late while the
-- spawn chunks were generating.
core.register_on_joinplayer(function(player)
	core.after(6, function()
		local p = vector.round(player:get_pos())
		local obj = core.add_entity({x = p.x + 3, y = p.y + 1, z = p.z},
				"mobs_mc:pig")
		if not obj then
			core.log("action", "vlpunch: no pig")
			return
		end
		local le = obj:get_luaentity()
		core.log("action", "vlpunch: pig hp=" .. tostring(obj:get_hp()) ..
				" health=" .. tostring(le and le.health) .. " immortal=" ..
				tostring(obj:get_armor_groups().immortal))
		local caps = player:get_wielded_item():get_tool_capabilities()
		for i = 1, 3 do
			obj:punch(player, 2.0, caps, {x = 1, y = 0, z = 0})
			le = obj:get_luaentity()
			core.log("action", "vlpunch: after punch " .. i .. " hp=" ..
					tostring(obj:get_hp()) .. " health=" ..
					tostring(le and le.health) .. " alive=" .. tostring(le ~= nil))
			assert(obj:get_hp() == 10, "the engine hp of an immortal moved")
		end
	end)
end)
