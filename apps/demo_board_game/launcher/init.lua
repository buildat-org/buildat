-- Buildat: apps/demo_board_game/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID]); the default tile is gone
return function(ctx) return {{id = "play", label = "demo_board_game",
	run = function() ctx.launch{app = "demo_board_game"} end}} end
