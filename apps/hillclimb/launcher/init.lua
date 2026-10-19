-- Buildat: apps/hillclimb/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID])
return function(ctx) return {{id = "play", label = "hillclimb", order = 142,
	description = "Laps of a circuit on a hill, or a timed climb, on generated voxel ground",
	run = function() ctx.launch{app = "hillclimb"} end}} end
