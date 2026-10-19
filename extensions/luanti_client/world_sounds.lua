-- Buildat: extension/luanti_client/world_sounds.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The sounds: a part of world.lua's M.new, which calls this with what it reads
-- of M.new's ([SPLITS]: moved out as it was). Played by res/sound_play.lua, which
-- vanilla's client plays its own with ([LUANTI_SHARED_1019]).
local sound_play = buildat.run_extension_file("res/sound_play.lua")

return function(self, magic, scene, camera_node, sounds_proto, object_nodes)
	-- res/sound_play.lua plays them; spec is what sounds.lua read out of
	-- PLAY_SOUND and resource the name of one file of the group it asked
	-- for -- picking which one is the caller's, because which files there
	-- are is the media's business
	local sounds = sound_play({magic = magic, sounds = sounds_proto,
		scene = function()
			return scene
		end,
		object_pos = function(id)
			local at = object_nodes[id]
			return at and at.at_x and magic.Vector3(at.at_x,
					at.at_y + (at.offset or 0), at.at_z)
		end,
	})
	function self:play_sound(id, spec, resource)
		return sounds.play(id, spec,
				magic.cache:GetResource("Sound", resource)) ~= nil
	end
	function self:stop_sound(id)
		sounds.stop(id)
	end
	function self:fade_sound(id, step, gain)
		sounds.fade(id, step, gain)
	end
	function self:update_sounds(dtime)
		sounds.update(dtime, camera_node.worldPosition)
	end
	function self:sound_count()
		return sounds.count()
	end
end
-- vim: set noet ts=4 sw=4:
