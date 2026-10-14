-- Buildat: apps/sample_lighting_scene/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- Two tiles on the launch grid ([LAUNCH_GRID]): the scene in one section,
-- and in eight (main.cpp's sections=8)
return function(ctx) return {
	{id = "one", label = "sample_lighting_scene",
		run = function() ctx.launch{app = "sample_lighting_scene"} end},
	{id = "eight", label = "sample_lighting_scene, 8 sections",
		run = function() ctx.launch{app = "sample_lighting_scene",
				params = {sections = 8}} end},
} end
