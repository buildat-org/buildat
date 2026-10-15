-- Buildat: apps/blip_check/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
return function(ctx) return {{id = "run", label = "blip_check",
	run = function() ctx.launch{app = "blip_check"} end}} end
