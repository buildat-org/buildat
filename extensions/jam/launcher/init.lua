-- Buildat: extensions/jam/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The jam app on the launch grid ([JAM_APP])
return function(ctx)
	return {{id = "app", label = "jam music maker", order = 187,
		category = "app",
		description = "Songs as text, edited in views and exported",
		run = function() ctx.launch{extension = "jam"} end}}
end
