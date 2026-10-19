-- Buildat: apps/skeldat/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID]), and a save's way to the
-- world menu with it selected ([SKELDAT_SAVE_WORLD_MENU], as vanilla's)
return function(ctx) return {{id = "play", label = "skeldat",
	icon = "icon.png", order = 141,
	description = "The bones are taking the world. Hold them back, and last as many days as you can",
	run = function() ctx.launch{app = "skeldat"} end},
	{id = "world_menu", label = "World menu...", for_save = true,
	run = function(save)
		ctx.launch{app = "skeldat", params = {menu = "worlds", world = save}}
	end}} end
