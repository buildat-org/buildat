-- Buildat: apps/sample_material_wall/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID]); the default tile is gone
return function(ctx) return {{id = "play", label = "sample_material_wall",
	run = function() ctx.launch{app = "sample_material_wall"} end}} end
