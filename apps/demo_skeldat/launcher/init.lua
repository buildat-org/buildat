-- Buildat: apps/demo_skeldat/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID])
return function(ctx) return {{id = "play", label = "skeldat",
	icon = "icon.png", order = 141,
	description = "skelenti made in Buildat alone, no Luanti game under it",
	run = function() ctx.launch{app = "demo_skeldat"} end}} end
