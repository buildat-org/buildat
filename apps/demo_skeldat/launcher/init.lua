-- Buildat: apps/demo_skeldat/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID])
return function(ctx) return {{id = "play", label = "skeldat",
	icon = "icon.png", order = 141,
	description = "The bones are taking the world. Hold them back, and last as many days as you can",
	run = function() ctx.launch{app = "demo_skeldat"} end}} end
