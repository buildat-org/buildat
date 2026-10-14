-- Buildat: apps/demo_bomber_drone/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID]); the default tile is gone
return function(ctx) return {{id = "play", label = "demo_bomber_drone",
	run = function() ctx.launch{app = "demo_bomber_drone"} end}} end
