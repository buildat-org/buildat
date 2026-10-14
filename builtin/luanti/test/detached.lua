-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- A detached inventory, which belongs to nobody: a form shows one, what is
-- moved in and out of it goes through the callbacks its owner gave it, and
-- the client draws what is in it.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=detached_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/detached.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- Connect a client and press E: the form has the player's own slots under a
-- row of three, which is the detached inventory, holding stone, dirt and
-- sand. Moving a stack in or out logs what the callbacks were told -- and
-- the left button carries the whole stack, the right button one item of it
-- and the middle button ten, which is Luanti's own rule and is what the
-- logged counts say.
--
-- It is also where the slot tooltip is seen: rest the mouse on one of the
-- three and the item's description appears beside the cursor, with the name
-- it is known by under it.
local NAME = "detached_check"

core.register_on_mods_loaded(function()
	local inv = core.create_detached_inventory(NAME, {
		allow_move = function(inv, from_list, from_i, to_list, to_i, n, player)
			core.log("action", "detached check: allow_move " .. n)
			return n
		end,
		allow_put = function(inv, listname, index, stack, player)
			core.log("action", "detached check: allow_put " ..
					stack:get_name() .. " " .. stack:get_count())
			return stack:get_count()
		end,
		allow_take = function(inv, listname, index, stack, player)
			core.log("action", "detached check: allow_take " ..
					stack:get_name() .. " " .. stack:get_count())
			return stack:get_count()
		end,
		on_put = function(inv, listname, index, stack, player)
			core.log("action", "detached check: on_put " .. stack:get_name())
		end,
		on_take = function(inv, listname, index, stack, player)
			core.log("action", "detached check: on_take " .. stack:get_name())
		end,
	})
	inv:set_size("main", 3)
	inv:set_stack("main", 1, ItemStack("basenodes:stone 5"))
	inv:set_stack("main", 2, ItemStack("basenodes:dirt 3"))
	inv:set_stack("main", 3, ItemStack("basenodes:sand"))
	assert(core.get_inventory({type = "detached", name = NAME}) == inv,
			"the detached inventory is not found by its name")
	core.log("action", "detached check: three stacks in " .. NAME)
end)

core.register_on_joinplayer(function(player)
	core.after(2, function()
		if not (player and player:is_player()) then
			return
		end
		player:set_inventory_formspec(
				"size[8,7]" ..
				"label[0,0;detached:" .. NAME .. "]" ..
				"list[detached:" .. NAME .. ";main;0,0.5;3,1;]" ..
				"list[current_player;main;0,2.5;8,4;]")
		core.log("action", "detached check: the player's form shows it")
	end)
end)
