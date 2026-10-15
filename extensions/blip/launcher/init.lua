-- Buildat: extensions/blip/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- blip's designer on the launch grid ([BLIP])
return function(ctx)
	return {{id = "designer", label = "blip sound designer", order = 185,
		description = "sfxr's sounds, made and exported for a game",
		run = function() ctx.launch{extension = "blip"} end}}
end
