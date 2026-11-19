-- Buildat: apps/jam_check/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
return function(ctx) return {{id = "run", label = "jam_check",
	run = function() ctx.launch{app = "jam_check"} end}} end
