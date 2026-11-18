-- Buildat: extensions/weave/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- weave's designer on the launch grid ([KIT_TEXTURE_DESIGNER])
return function(ctx)
	return {{id = "designer", label = "weave texture designer", order = 186,
		category = "app",
		description = "Seamless pixel-art textures made of parameters",
		run = function() ctx.launch{extension = "weave"} end}}
end
