-- Buildat: apps/sample_kit/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID])
return function(ctx) return {{id = "play", label = "sample_kit",
	run = function() ctx.launch{app = "sample_kit"} end}} end
