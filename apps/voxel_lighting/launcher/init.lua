-- Buildat: apps/voxel_lighting/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- Two tiles on the launch grid ([LAUNCH_GRID]): the scene in one section,
-- and in eight (main.cpp's sections=8)
return function(ctx) return {
	{id = "one", label = "voxel_lighting",
		run = function() ctx.launch{app = "voxel_lighting"} end},
	{id = "eight", label = "voxel_lighting, 8 sections",
		run = function() ctx.launch{app = "voxel_lighting",
				params = {sections = 8}} end},
} end
