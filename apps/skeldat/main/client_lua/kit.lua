-- Buildat: apps/skeldat/main/client_lua/kit.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 6a: Kit's editor in skeldat. A builder's Edit (F6, or the
-- pause menu's) puts Kit's tools over the world: Kit's types and
-- skeldat's own (mob_spawner, bones) in the palette, its 2D, 3D and walk
-- views; walking is skeldat's own (the mouse looks in the editor's
-- crosshair only, a click goes up into it). The world is persistent
-- (stage 6a2): no Play or Stop, the edits live. In play a left click on
-- a usable Kit object uses it (init.lua's).
--   game.kit = run_script_file("main/kit.lua")(game, scene, camera_node)
local magic = require("buildat/extension/urho3d")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")
local kit = require("buildat/module/kit")

return function(game, scene, camera_node)
	kit.editor{scene = scene, camera = camera_node, ground_y = 0,
		bar = false, mouse_look = true,
		-- The walk view skeldat's own, its sky's render path
		viewport = function() return game.viewport end,
		set_camera = function(node)
			voxelworld.set_camera(node)
			voxel_shading.set_camera(node)
		end,
		solid = function(x, y, z)
			local v = voxelworld.get_static_voxel(magic.Vector3(x, y, z))
			if not v then
				return false
			end
			local reg = voxelworld.get_voxel_registry()
			local def = reg:get_by_id(reg:id_of(v))
			return def ~= nil and def.physically_solid
		end}
	-- Whether skeldat's own clicks and keys are off: Kit's tools are on
	function game.kit_editing()
		return kit.editing()
	end
	-- And its walking: the editor's 2D and 3D views move their own camera
	function game.kit_walks()
		return not kit.editing() or kit.view() == "walk"
	end
	-- The pointer free for the editor's clicks: in its tools, out of its
	-- crosshair
	-- (init.lua's Update compares it with kit_free, the last one: a boolean)
	function game.kit_pointer()
		return kit.editing() and not kit.looking() or false
	end
	game.kit_free = false
	return kit
end
-- vim: set noet ts=4 sw=4:
