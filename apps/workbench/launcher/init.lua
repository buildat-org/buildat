-- Buildat: apps/workbench/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- The tile on the launch grid ([LAUNCH_GRID]) and its projects
-- ([WORKBENCH_PROJECTS]): the tile and Manage open Manage (New in it), New
-- its name screen; a save is a project, its "Manage..." Manage with it
-- selected
return function(ctx)
	local function manage(params)
		return function() ctx.launch{app = "workbench", params = params} end
	end
	return {{id = "play", label = "Workbench",
		icon = "icon.png", order = 150,
		description = "A blank world for Kit: build, place components, link them and play",
		run = manage({menu = "projects"})},
	{id = "new", label = "New workbench project", icon = "icon.png",
		order = 151, description = "A blank Workbench project, named",
		run = manage({menu = "new"})},
	{id = "manage", label = "Manage workbench projects", icon = "icon.png",
		order = 152, description = "Workbench's projects: open, rename, delete",
		run = manage({menu = "projects"})},
	{id = "manage_project", label = "Manage...", for_save = true,
		run = function(save)
			ctx.launch{app = "workbench",
					params = {menu = "projects", project = save}}
		end}}
end
