-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Run by hand, by the command below; no runner references it.
-- A row of the player's own inventory on the HUD: Luanti's inventory
-- element, which a game that draws its own hotbar uses.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=hudinv_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/hudinventory.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- Connect a client: four slots sit above the middle of the screen with the
-- second one marked, holding what the player was given. A column of four
-- sits to the left of them, which is the direction field.
core.register_on_joinplayer(function(player)
	core.after(2, function()
		if not (player and player:is_player()) then
			return
		end
		local inv = player:get_inventory()
		inv:set_stack("main", 1, ItemStack("basenodes:stone 42"))
		inv:set_stack("main", 2, ItemStack("basenodes:dirt 7"))
		inv:set_stack("main", 3, ItemStack("basenodes:sand"))
		player:hud_add({
			hud_elem_type = "inventory",
			position = {x = 0.5, y = 0.25},
			alignment = {x = 0, y = 0},
			text = "main",
			number = 4,
			item = 2,
			direction = 0,
		})
		player:hud_add({
			hud_elem_type = "inventory",
			position = {x = 0.2, y = 0.25},
			alignment = {x = 0, y = 1},
			text = "main",
			number = 4,
			item = 0,
			direction = 2,
		})
		core.log("action", "hud inventory check: a row and a column added")
	end)
end)
