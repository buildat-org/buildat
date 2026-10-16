-- Buildat: apps/demo_skelenti/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID])
return function(ctx) return {{id = "play", label = "skelenti",
	icon = "icon.png", order = 140,
	description = "A demo: a Luanti game and Buildat's own parts in one app",
	run = function() ctx.launch{app = "demo_skelenti"} end}} end
