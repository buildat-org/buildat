-- Buildat: extension/luanti_client/world_particles.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The particles: a part of world.lua's M.new, which calls this with what it reads
-- of M.new's ([SPLITS]: moved out as it was). Drawn by res/particle_draw.lua,
-- which vanilla's client draws its own with ([LUANTI_SHARED_1019]).
local particle_draw = buildat.run_extension_file("res/particle_draw.lua")

return function(self, magic, log, scene, camera_node, particles, glow_full,
		particle_light, solid_at, game_texture)
	-- res/particle_draw.lua draws them, over its own record: this turns
	-- particles.lua's into it. resolve(name) turns a texture string into a
	-- resource name, or nil for one that has not arrived.
	local particle_objects = nil
	local drawn = particle_draw({magic = magic, particles = particles,
		log = log, glow_full = glow_full, solid_at = solid_at,
		light_color = particle_light,
		scene = function()
			return scene
		end,
		texture = function(name)
			return game_texture(name, magic.FILTER_NEAREST_ANISOTROPIC)
		end,
		attached_pos = function(id)
			local obj = particle_objects and particle_objects[id]
			if obj and obj.is_self then
				-- The player's own object: the server sends no position
				-- for it, and where the player is is where the camera is
				local p = camera_node.position
				return p.x, p.y, p.z
			elseif obj and obj.position then
				return obj.position[1], obj.position[2], obj.position[3]
			end
		end,
	})
	-- set_particle_spawner(id, p, resolve): p nil takes the spawner away,
	-- which is what DELETE_PARTICLESPAWNER does. What is drawn of a tween is
	-- its start.
	function self:set_particle_spawner(id, p, resolve)
		if p == nil then
			drawn.spawner(id, nil)
			return
		end
		local pos, vel, acc = p.pos.start, p.vel.start, p.acc.start
		drawn.spawner(id, {
			texture = p.texture ~= "" and resolve(p.texture) or nil,
			amount = p.amount, time = p.time, vertical = p.vertical,
			attached = p.attached ~= nil and p.attached ~= 0 and
					p.attached or nil,
			pos_min = pos.min, pos_max = pos.max,
			vel_min = vel.min, vel_max = vel.max,
			acc_min = acc.min, acc_max = acc.max,
			exp_min = p.exptime.start.min, exp_max = p.exptime.start.max,
			size_min = p.size.start.min, size_max = p.size.start.max,
			animation = p.animation, glow = p.glow,
			collision = p.collision,
			collision_removal = p.collision_removal,
		})
	end
	-- One particle the server picked itself
	function self:add_particle(p, resolve)
		drawn.single({
			texture = p.texture ~= "" and resolve(p.texture) or nil,
			pos_min = p.pos, pos_max = p.pos, vel_min = p.vel,
			vel_max = p.vel, acc_min = p.acc, acc_max = p.acc,
			exp_min = p.exptime, exp_max = p.exptime,
			size_min = p.size, size_max = p.size,
			vertical = p.vertical, animation = p.animation, glow = p.glow,
		})
	end
	-- objects is what the client has parsed, keyed by object id, so that a
	-- spawner attached to one can be moved to where that one is now; it may
	-- be nil for a caller that has none
	function self:update_particles(dtime, objects)
		particle_objects = objects
		drawn.update(dtime)
	end
	function self:particle_count()
		return drawn.count()
	end
end
-- vim: set noet ts=4 sw=4:
