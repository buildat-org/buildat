-- Buildat: extension/luanti_client/world_particles.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The world's particles: a part of world.lua's M.new, which calls this with
-- what it reads of M.new's ([SPLITS]: moved out as it was).

return function(self, magic, log, scene, camera_node, game_texture,
		particle_technique, particles, particle_light, solid_at)
	-- The particle emitters in the scene: the spawners by the id the server
	-- deletes them by, and the single particles, each of which is an emitter
	-- of one that fires once.
	local particle_nodes = {}
	local single_particles = {}
	-- Enough for a game's digging and footsteps at once. A batch beyond this
	-- is dropped rather than queued: a particle that turns up late is worse
	-- than one that does not turn up.
	local SINGLE_PARTICLE_MAX = 128

	-- The spawners that have been taken away and whose particles are living
	-- out their lives; see set_particle_spawner(). Each holds an emitter's
	-- pool of billboards, so there is a cap on how many are kept: at the
	-- twenty a second VoxeLibre's rain churns through, this is a second and
	-- a half of drops, which is about how long one takes to fall.
	local dying_spawners = {}
	local DYING_SPAWNERS_MAX = 32
	-- Node lookups a frame for an emitter's floor map: a rain box's 1000
	-- columns in about two seconds, the gained row as it moves at once
	local FLOOR_BUDGET = 400

	-- One Urho3D emitter out of one Luanti particle description.
	--
	-- The two do not line up field for field, and this is where they are
	-- made to. Luanti gives, per field, a tween of a range: a start range
	-- and an end range and a way of moving between them over the spawner's
	-- life. Urho3D gives one emitter box, one box of directions, one
	-- constant force and one size range for the whole emitter.
	--
	-- simplified: the tween is dropped -- the starting range is what the
	-- whole spawner runs at -- and so are the bias inside a range, the
	-- collision of what does not fall (particles.floor_new()), the drag, the jitter, the bounce and the
	-- attractors. What that costs is a spawner that grows or shrinks over
	-- its life, and particles that stop at the ground; the upgrade path is
	-- either a manager of this client's own or more of Urho3D's own fields.
	-- Luanti's tile animation on a particle, as Urho3D's texture frames: the
	-- part of the image each frame is, and how many seconds into a
	-- particle's life it is shown from. How many frames a vertical strip
	-- holds comes out of the image's own shape against the aspect the game
	-- gave, which is Luanti's own arithmetic.
	--
	-- Urho3D stops on the last frame rather than looping, so the frames are
	-- laid out again and again until the longest life the particle can have
	-- is covered. The cap is what keeps a one-frame-a-millisecond animation
	-- on a minute-long particle from filling memory.
	local PARTICLE_FRAMES_MAX = 64
	local function particle_frames(effect, tex, animation, ttl)
		if not tex or not animation or animation.type == 0 then
			return
		end
		local frames = {}
		local step = nil
		if animation.type == 1 then
			-- A vertical strip. One frame is as tall as the image is wide,
			-- times the aspect the game asked for.
			local aspect_w = animation.aspect_w or 1
			local aspect_h = animation.aspect_h or 1
			local frame_h = tex.width / aspect_w * aspect_h
			local count = frame_h > 0 and
					math.floor(tex.height / frame_h + 0.5) or 1
			if count < 2 then
				return
			end
			for i = 0, count - 1 do
				frames[#frames + 1] = {0, i / count, 1, (i + 1) / count}
			end
			-- Luanti's length is the whole animation
			step = (animation.length or 1) / count
		elseif animation.type == 2 then
			-- A sheet, left to right and then down, which is the order
			-- Luanti numbers its frames in
			local across = math.max(1, animation.frames_w or 1)
			local down = math.max(1, animation.frames_h or 1)
			if across * down < 2 then
				return
			end
			for y = 0, down - 1 do
				for x = 0, across - 1 do
					frames[#frames + 1] = {x / across, y / down,
							(x + 1) / across, (y + 1) / down}
				end
			end
			-- And here it is the length of one frame
			step = animation.length or 0.1
		end
		if not step or step <= 0 then
			return
		end
		local at = 0
		local i = 1
		local added = 0
		while at < ttl and added < PARTICLE_FRAMES_MAX do
			local f = frames[i]
			effect:AddTextureTime(magic.Rect(f[1], f[2], f[3], f[4]), at)
			at = at + step
			i = i % #frames + 1
			added = added + 1
		end
	end

	-- A particle's size crosses the wire in Luanti's scene units, where a
	-- node is ten across; everything here is in nodes
	local PARTICLE_SIZE_TO_NODES = 1 / 10

	-- The effect is handed to the emitter by the caller, once it has set the
	-- fields that differ between a spawner and a single particle: assigning
	-- the same effect twice is a no-op in Urho3D, so everything has to be on
	-- it before it goes on.
	-- A particle at full glow is a light, a lightning bolt: unfogged
	local GLOW_FULL = require("buildat/extension/physical_sky").GLOW_FULL
	local glow_technique = magic.cache:GetResource("Technique",
			"luanti_client/res/ParticleGlow.xml")
	local function particle_effect(texture_name, amount, ttl_min,
			ttl_max, size_min, size_max, vel_min, vel_max, acc, active_time,
			animation, glow)
		local effect = magic.ParticleEffect.new()
		local material = magic.Material.new()
		local tex = game_texture(texture_name, magic.FILTER_NEAREST_ANISOTROPIC)
		material:SetTechnique(0, (glow or 0) >= GLOW_FULL and glow_technique or
				particle_technique)
		material:SetTexture(0, tex)
		effect.material = material
		effect.numParticles = amount
		effect.relative = false
		effect.scaled = true
		effect.sorted = true
		-- A fresh emitter is not in view until it has a particle in it, and
		-- Urho3D does not update an emitter that is out of view: without
		-- this the first particle is never emitted and nothing is ever seen
		effect.updateInvisible = true
		-- White, and only white: a particle with no colour frame at all
		-- comes out as one anyway, but saying so is what keeps it that way
		effect:AddColorTime(magic.Color(1, 1, 1, 1), 0)
		particle_frames(effect, tex, animation, ttl_max)
		effect.minTimeToLive = ttl_min
		effect.maxTimeToLive = ttl_max
		-- Luanti's size is the whole particle across, in the scene units its
		-- own client draws in -- ten to the node, the same as an object's
		-- visual_size -- and a billboard's is half of one side. So a rain
		-- drop's size of 4 is four tenths of a node, not four nodes.
		local half = PARTICLE_SIZE_TO_NODES / 2
		effect:SetMinParticleSize(magic.Vector2(size_min * half,
				size_min * half))
		effect:SetMaxParticleSize(magic.Vector2(size_max * half,
				size_max * half))
		-- The velocity: the box the direction is picked from, and the speeds
		-- that box holds. Without the speeds every particle leaves at one
		-- node a second whatever the game asked for, which reads as all of
		-- them flying away from wherever they started.
		effect:SetMinDirection(magic.Vector3(vel_min[1], vel_min[2],
				vel_min[3]))
		effect:SetMaxDirection(magic.Vector3(vel_max[1], vel_max[2],
				vel_max[3]))
		local near, far = particles.speed_range(vel_min, vel_max)
		effect.minVelocity = near
		effect.maxVelocity = far
		effect:SetConstantForce(magic.Vector3(acc[1], acc[2], acc[3]))
		effect.dampingForce = 0
		-- An active time with no inactive time after it is one burst and
		-- then nothing, which is what a spawner with a time and a single
		-- particle both are. Zero active time never stops, which is what a
		-- spawner with no time is.
		effect.activeTime = active_time
		effect.inactiveTime = 0
		return effect, material
	end

	-- An emitter's light, on its own material's colour (not clipped at one,
	-- as pbr's sunlight is not). simplified: one light for the emitter's
	-- whole box, read at its middle, and set again when it moves by a 255th.
	local function light(entry)
		local p = entry.node.position
		local c = particle_light(p.x, p.y, p.z, entry.glow)
		local o = entry.lit
		if c == nil or o and math.abs(c.r - o.r) < 1 / 255 and
				math.abs(c.g - o.g) < 1 / 255 and
				math.abs(c.b - o.b) < 1 / 255 then
			return
		end
		entry.lit = c
		entry.material:SetShaderParameter("MatDiffColor", c)
	end

	-- set_particle_spawner(id, p, resolve): p nil takes the spawner away,
	-- which is what DELETE_PARTICLESPAWNER does. resolve(name) turns a
	-- texture string into a resource name, or nil for one that has not
	-- arrived.
	--
	-- What makes two spawners the same spawner: everything about them that
	-- this draws. A game that takes its spawner away and adds it again --
	-- VoxeLibre's weather does, twenty times a second -- gets the emitter it
	-- had back rather than a new one, which is what keeps its rain falling
	-- in a stream instead of in fifty-millisecond bursts.
	local function spawner_signature(p, texture_name)
		local n = {texture_name, p.amount, p.time, p.attached,
				p.vertical and 1 or 0}
		for _, range in ipairs({p.pos.start, p.vel.start, p.acc.start}) do
			for i = 1, 3 do
				n[#n + 1] = string.format("%g", range.min[i])
				n[#n + 1] = string.format("%g", range.max[i])
			end
		end
		for _, range in ipairs({p.exptime.start, p.size.start}) do
			n[#n + 1] = string.format("%g", range.min)
			n[#n + 1] = string.format("%g", range.max)
		end
		return table.concat(n, "/")
	end

	-- A spawner attached to an object has its positions relative to that
	-- object and follows it, which is what update_particles() moves; the
	-- weather of a game is a spawner attached to the player.
	function self:set_particle_spawner(id, p, resolve)
		local old = particle_nodes[id]
		if old then
			-- The particles a spawner has already made outlive it, which is
			-- what Luanti does: its own particles are not owned by the
			-- spawner that made them. It matters more than it sounds --
			-- VoxeLibre's weather takes its rain spawner away and adds it
			-- again twenty times a second, so a client that drops the
			-- particles with the spawner erases its own rain fifty
			-- milliseconds after making it, which is why the sky was empty.
			-- So the emitter stops emitting and the node goes when the last
			-- particle it made has expired.
			if old.emitter then
				old.emitter.emitting = false
			end
			old.life = (old.ttl_max or 0) + 0.2
			old.attached = nil
			dying_spawners[#dying_spawners + 1] = old
			-- A cap, because each of these holds a pool of billboards: the
			-- oldest goes, which is the one whose particles are nearest the
			-- end of their lives anyway
			while #dying_spawners > DYING_SPAWNERS_MAX do
				scene:RemoveChild(table.remove(dying_spawners, 1).node)
			end
			particle_nodes[id] = nil
		end
		if p == nil then
			return
		end
		local texture_name = p.texture ~= "" and resolve(p.texture) or nil
		if not texture_name then
			return
		end
		local pos = particles.middle(p.pos.start)
		local size = p.size.start
		local exptime = p.exptime.start
		-- The same spawner as one that was taken away a moment ago: pick its
		-- emitter back up where it left off
		local signature = spawner_signature(p, texture_name)
		for i, e in ipairs(dying_spawners) do
			if e.signature == signature then
				table.remove(dying_spawners, i)
				if e.emitter then
					e.emitter.emitting = true
				end
				e.life = p.time > 0 and
						(p.time + math.max(0.01, exptime.max) + 0.5) or nil
				e.attached = p.attached ~= 0 and p.attached or nil
				e.offset = pos
				e.at_x, e.at_y, e.at_z = nil, nil, nil
				particle_nodes[id] = e
				return
			end
		end
		local node = scene:CreateChild("particles_"..id)
		node.position = magic.Vector3(pos[1], pos[2], pos[3])
		local amount = math.max(1, math.min(p.amount, 1000))
		local effect, material = particle_effect(texture_name,
				amount, math.max(0.01, exptime.min),
				math.max(0.01, exptime.max),
				math.max(0.001, size.min), math.max(0.001, size.max),
				p.vel.start.min, p.vel.start.max,
				particles.middle(p.acc.start), p.time, p.animation, p.glow)
		-- What the emitter box is: the position range, which the node sits
		-- in the middle of
		effect.emitterType = 1 -- EMITTER_BOX
		effect:SetEmitterSize(magic.Vector3(
				math.max(0, p.pos.start.max[1] - p.pos.start.min[1]),
				math.max(0, p.pos.start.max[2] - p.pos.start.min[2]),
				math.max(0, p.pos.start.max[3] - p.pos.start.min[3])))
		-- Luanti spawns amount particles over time seconds, and amount a
		-- second when there is no time at all
		local rate = p.time > 0 and amount / p.time or amount
		effect.minEmissionRate = rate
		effect.maxEmissionRate = rate
		local emitter = node:CreateComponent("ParticleEmitter")
		emitter.effect = effect
		emitter.emitting = true
		emitter.castShadows = false
		-- Luanti's `vertical` particle is an upright quad turned to the
		-- player about Y rather than one facing the camera, which is what
		-- makes a rain drop look like a falling drop rather than a blob
		if p.vertical then
			emitter.faceCameraMode = magic.FC_ROTATE_Y
		end
		-- Collision, for what falls: a floor map (res/particles.lua)
		local floor = nil
		if p.collision and particles.falls(p.vel.start.min,
				p.vel.start.max, p.acc.start.min, p.acc.start.max) then
			local lo, hi = p.pos.start.min, p.pos.start.max
			floor = particles.floor_new(emitter,
					{lo[1] - pos[1], lo[2] - pos[2], lo[3] - pos[3]},
					{hi[1] - pos[1], hi[2] - pos[2], hi[3] - pos[3]},
					p.collision_removal)
		end
		-- A spawner that ends takes itself away once the last particle it
		-- made has expired; one with no time waits for the server
		local life = nil
		if p.time > 0 then
			life = p.time + exptime.max + 0.5
		end
		-- Attached to an object: the position read above is an offset from
		-- where that object is, and update_particles() keeps up with it
		local attached = p.attached ~= nil and p.attached ~= 0 and
				p.attached or nil
		-- The effect and its material are kept here for as long as the
		-- emitter is: both were made in Lua, and a Lua-made Urho3D object is
		-- destroyed when the last Lua reference to it goes, whatever the
		-- engine still holds. An emitter whose effect has been collected
		-- reads freed memory: on this one it came out as Urho3D's defaults,
		-- so every particle flew off in a random direction at the default
		-- size instead of falling, which is what made rain invisible.
		particle_nodes[id] = {node = node, life = life, attached = attached,
				offset = pos, emitter = emitter, signature = signature,
				effect = effect, material = material, glow = p.glow,
				floor = floor,
				ttl_max = math.max(0.01, exptime.max)}
	end

	-- One particle the server picked itself: an emitter of one that fires
	-- once and is taken away when it has expired.
	function self:add_particle(p, resolve)
		if #single_particles >= SINGLE_PARTICLE_MAX then
			return
		end
		local texture_name = p.texture ~= "" and resolve(p.texture) or nil
		if not texture_name then
			return
		end
		local ttl = math.max(0.01, p.exptime)
		local node = scene:CreateChild("particle")
		node.position = magic.Vector3(p.pos[1], p.pos[2], p.pos[3])
		local effect, material = particle_effect(texture_name, 1,
				ttl, ttl, math.max(0.001, p.size), math.max(0.001, p.size),
				p.vel, p.vel, p.acc, 0.05, p.animation, p.glow)
		effect.emitterType = 0 -- EMITTER_SPHERE, of no size
		effect:SetEmitterSize(magic.Vector3(0, 0, 0))
		effect.minEmissionRate = 100
		effect.maxEmissionRate = 100
		local emitter = node:CreateComponent("ParticleEmitter")
		emitter.effect = effect
		emitter.emitting = true
		emitter.castShadows = false
		-- The effect and the material live as long as the emitter does; see
		-- set_particle_spawner()
		local entry = {node = node, life = ttl + 0.5, effect = effect,
				material = material, glow = p.glow}
		light(entry)
		single_particles[#single_particles + 1] = entry
	end

	-- Ages the emitters and takes away the ones that are done with. A
	-- spawner with no time of its own is not aged: the server deletes it.
	-- objects is what the client has parsed, keyed by object id, so that a
	-- spawner attached to one can be moved to where that one is now; it may
	-- be nil for a caller that has none.
	function self:update_particles(dtime, objects)
		for id, entry in pairs(particle_nodes) do
			if entry.attached then
				local obj = objects and objects[entry.attached] or nil
				local x, y, z = nil, nil, nil
				if obj and obj.is_self then
					-- The player's own object: the server sends no position
					-- for it, and where the player is is where the camera is
					local p = camera_node.position
					x, y, z = p.x, p.y, p.z
				elseif obj and obj.position then
					x, y, z = obj.position[1], obj.position[2],
							obj.position[3]
				end
				if not x and not entry.said_missing then
					-- A spawner whose object the client does not know draws
					-- where the offset alone puts it, which is somewhere
					-- around the world's origin: worth one line rather than
					-- being a mystery
					entry.said_missing = true
					log:warning("particles: spawner "..tostring(id)..
							" is attached to object "..
							tostring(entry.attached)..
							", which is not one this client has")
				end
				if x and (x ~= entry.at_x or y ~= entry.at_y or
						z ~= entry.at_z) then
					entry.at_x, entry.at_y, entry.at_z = x, y, z
					entry.node.position = magic.Vector3(
							x + entry.offset[1], y + entry.offset[2],
							z + entry.offset[3])
				end
			end
			light(entry)
			if entry.floor then
				local q = entry.node.position
				particles.floor_update(entry.floor, entry.emitter, q.x, q.y,
						q.z, solid_at, FLOOR_BUDGET)
			end
			if entry.life then
				entry.life = entry.life - dtime
				if entry.life <= 0 then
					scene:RemoveChild(entry.node)
					particle_nodes[id] = nil
				end
			end
		end
		local d = 1
		while d <= #dying_spawners do
			local entry = dying_spawners[d]
			entry.life = entry.life - dtime
			if entry.life <= 0 then
				scene:RemoveChild(entry.node)
				table.remove(dying_spawners, d)
			else
				d = d + 1
			end
		end
		local i = 1
		while i <= #single_particles do
			local entry = single_particles[i]
			entry.life = entry.life - dtime
			if entry.life <= 0 then
				scene:RemoveChild(entry.node)
				table.remove(single_particles, i)
			else
				i = i + 1
			end
		end
	end

	-- For the counters line
	function self:particle_count()
		local n = #single_particles + #dying_spawners
		for _, _ in pairs(particle_nodes) do
			n = n + 1
		end
		return n
	end
end
-- vim: set noet ts=4 sw=4:
