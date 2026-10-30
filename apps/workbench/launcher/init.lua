-- Buildat: apps/workbench/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID])
return function(ctx) return {{id = "play", label = "Workbench",
	icon = "icon.png", order = 150,
	description = "A blank world for Kit: build, place components, link them and play",
	run = function() ctx.launch{app = "workbench"} end}} end
