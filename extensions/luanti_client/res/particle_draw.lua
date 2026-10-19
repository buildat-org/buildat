-- Buildat: extensions/luanti_client/res/particle_draw.lua
-- (vanilla's client runs it too, served as luanti/particle_draw.lua)
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **The particles drawn**: an Urho3D ParticleEmitter per spawner, and one of
-- a single particle that fires once. One copy for both Luanti clients
-- ([LUANTI_SHARED_1019]); what differs is how each gets the record, which
-- particles.lua reads off the wire for luanti_client and lua/particles.lua
-- sends vanilla.
--
-- The two do not line up field for field, and this is where they are made
-- to. Luanti gives, per field, a tween of a range: a start range and an end
-- range and a way of moving between them over the spawner's life. Urho3D
-- gives one emitter box, one box of directions, one constant force and one
-- size range for the whole emitter.
--
-- simplified: the tween is dropped -- the starting range is what the whole
-- spawner runs at -- and so are the bias inside a range, the collision of
-- what does not fall (particles.floor_new()), the drag, the jitter, the
-- bounce and the attractors. What that costs is a spawner that grows or
-- shrinks over its life; the upgrade path is either a manager of this
-- client's own or more of Urho3D's own fields.
--
--   draw = <this file>(o)
-- o: magic; particles (res/particles.lua: speed_range, falls, floor_*);
-- scene() -> the scene to draw in, or nil (nothing is drawn); texture(name)
-- -> Texture2D or nil, name a resolved resource name; light_color(x, y, z,
-- glow) -> Color or nil (at full glow the flash's); attached_pos(id) -> x,
-- y, z or nil; solid_at(x, y, z) -> true, false or nil (not arrived);
-- glow_full (physical_sky's GLOW_FULL); log.
-- The record, both a spawner's and a single particle's (a single one has
-- min == max and no time): texture (resolved), amount, time, vertical,
-- attached (an id, or nil), pos_min, pos_max, vel_min, vel_max, acc_min,
-- acc_max ({x, y, z} in nodes), exp_min, exp_max, size_min, size_max
-- (Luanti's scene units), animation {type, aspect_w, aspect_h, length,
-- frames_w, frames_h}, glow, collision, collision_removal.
-- draw.spawner(id, p): p nil takes the spawner away
-- (DELETE_PARTICLESPAWNER); draw.single(p); draw.update(dtime);
-- draw.count() -> how many emitters there are.
return function(o)
	local magic, particles = o.magic, o.particles
	local D = {}
	-- Enough for a game's digging and footsteps at once. A batch beyond this
	-- is dropped rather than queued: a particle that turns up late is worse
	-- than one that does not turn up.
	local SINGLE_PARTICLE_MAX = 128
	-- The spawners that have been taken away and whose particles are living
	-- out their lives; see D.spawner(). Each holds an emitter's pool of
	-- billboards, so there is a cap on how many are kept: at the twenty a
	-- second VoxeLibre's rain churns through, this is a second and a half of
	-- drops, which is about how long one takes to fall.
	local DYING_SPAWNERS_MAX = 32
	-- Node lookups a frame for an emitter's floor map: a rain box's 1000
	-- columns in about two seconds, the gained row as it moves at once
	local FLOOR_BUDGET = 400
	-- Urho3D stops on the last texture frame rather than looping, so the
	-- frames are laid out again and again until the longest life the
	-- particle can have is covered. The cap is what keeps a
	-- one-frame-a-millisecond animation on a minute-long particle from
	-- filling memory.
	local PARTICLE_FRAMES_MAX = 64
	-- A particle's size is in Luanti's scene units, where a node is ten
	-- across; everything here is in nodes
	local PARTICLE_SIZE_TO_NODES = 1 / 10

	local particle_nodes = {}     -- spawner id -> what draws it
	local dying_spawners = {}     -- ones whose particles are still expiring
	local single_particles = {}

	local function middle(a, b)
		return {(a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2}
	end

	-- Luanti's tile animation on a particle, as Urho3D's texture frames: the
	-- part of the image each frame is, and how many seconds into a
	-- particle's life it is shown from. How many frames a vertical strip
	-- holds comes out of the image's own shape against the aspect the game
	-- gave, which is Luanti's own arithmetic.
	local function particle_frames(effect, tex, anim, ttl)
		if tex == nil or anim == nil or anim.type == 0 then
			return
		end
		local frames = {}
		local step = nil
		if anim.type == 1 then
			-- A vertical strip. One frame is as tall as the image is wide,
			-- times the aspect the game asked for.
			local frame_h = tex.width / (anim.aspect_w or 1) *
					(anim.aspect_h or 1)
			local count = frame_h > 0 and
					math.floor(tex.height / frame_h + 0.5) or 1
			if count < 2 then
				return
			end
			for i = 0, count - 1 do
				frames[#frames + 1] = {0, i / count, 1, (i + 1) / count}
			end
			-- Luanti's length is the whole animation
			step = (anim.length or 1) / count
		elseif anim.type == 2 then
			-- A sheet, left to right and then down, which is the order
			-- Luanti numbers its frames in
			local across = math.max(1, anim.frames_w or 1)
			local down = math.max(1, anim.frames_h or 1)
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
			step = anim.length or 0.1
		end
		if step == nil or step <= 0 then
			return
		end
		local at, i, added = 0, 1, 0
		while at < ttl and added < PARTICLE_FRAMES_MAX do
			local f = frames[i]
			effect:AddTextureTime(magic.Rect(f[1], f[2], f[3], f[4]), at)
			at = at + step
			i = i % #frames + 1
			added = added + 1
		end
	end

	-- The effect is handed to the emitter by the caller, once it has set the
	-- fields that differ between a spawner and a single particle: assigning
	-- the same effect twice is a no-op in Urho3D, so everything has to be on
	-- it before it goes on.
	local particle_materials = {}
	local function particle_effect(resource, amount, ttl_min, ttl_max,
			size_min, size_max, vel_min, vel_max, acc, active_time, anim, glow)
		local effect = magic.ParticleEffect.new()
		-- One material a texture, made the first time it is drawn and kept
		-- here: every particle of a snow storm made its own, and that was
		-- half of what a particle cost ([PACKET_STALL], 2026-10-03). A
		-- particle at full glow is a light and has one of its own, unfogged
		-- (res/ParticleGlow.xml)
		local full = (glow or 0) >= o.glow_full
		local key = full and resource .. "#glow" or resource
		local cached = particle_materials[key]
		local material = cached and cached.material
		local tex = cached and cached.tex
		if not cached then
			material = magic.Material.new()
			tex = o.texture(resource)
			if tex then
				-- Nearest magnification and mipmapped minification: crisp
				-- up close, and a particle far away is not a sparkle of
				-- whichever texel won ([RENDER_SURVEY], texture filtering)
				tex.filterMode = magic.FILTER_NEAREST_ANISOTROPIC
				material:SetTexture(0, tex)
			end
			-- Particles are blended rather than cut out -- smoke and a spark
			-- are soft-edged -- and unlit, like the objects. Urho3D ships
			-- the technique.
			material:SetTechnique(0, magic.cache:GetResource("Technique",
					full and "luanti_client/res/ParticleGlow.xml" or
					"Techniques/DiffUnlitParticleAlpha.xml"))
			-- **Held by the resource cache, not by this table**
			-- ([PARTICLE_SEGV]): a Material made in Lua lives only while the
			-- engine holds it, so when the last effect using one went it was
			-- freed, and the next particle of that texture handed the freed
			-- one to SetMaterial -- SIGSEGV in RefCounted. The cache's
			-- reference keeps it.
			magic.cache:AddManualResource(material, "luanti_particle/" ..
					key:gsub("[^%w%._%-/]", "_"):gsub("%.%.", "_"))
			particle_materials[key] = {material = material, tex = tex}
		end
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
		particle_frames(effect, tex, anim, ttl_max)
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
		-- node a second whatever the game asked for.
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

	-- What makes two spawners the same spawner: everything about them that
	-- this draws. A game that takes its spawner away and adds it again --
	-- VoxeLibre's weather does, twenty times a second -- gets the emitter it
	-- had back rather than a new one, which is what keeps its rain falling
	-- in a stream instead of in fifty-millisecond bursts.
	local function spawner_signature(p)
		local n = {p.texture, p.amount, p.time, tostring(p.attached),
				p.vertical and 1 or 0}
		for _, v in ipairs({p.pos_min, p.pos_max, p.vel_min, p.vel_max,
				p.acc_min, p.acc_max}) do
			for i = 1, 3 do
				n[#n + 1] = string.format("%g", v[i])
			end
		end
		for _, v in ipairs({p.exp_min, p.exp_max, p.size_min, p.size_max}) do
			n[#n + 1] = string.format("%g", v)
		end
		return table.concat(n, "/")
	end

	-- **A particle's light** ([VANILLA_WEATHER] 5): Luanti's is its node's,
	-- raised to its glow; here the emitter's, at its middle, as a sprite
	-- object's. A spawner has a material of its own and the light goes on
	-- its colour, unclipped (pbr's daylight is past 1); a single particle
	-- shares its texture's, and the light is the effect's colour, which
	-- Urho3D applies to the live particles too but which is 8-bit and stops
	-- at 1. Full glow is a light: on the (glow) material's colour.
	-- simplified: one light for the emitter's whole box; set again when it
	-- moves by a 255th.
	local function light(entry)
		local p = entry.node.position
		local c = o.light_color(p.x, p.y, p.z, entry.glow)
		if c == nil then
			return
		end
		if (entry.glow or 0) >= o.glow_full and not entry.own_material then
			entry.material:SetShaderParameter("MatDiffColor", c)
			c = magic.Color(1, 1, 1, 1)
		end
		local was = entry.lit
		if was and math.abs(c.r - was.r) < 1 / 255 and
				math.abs(c.g - was.g) < 1 / 255 and
				math.abs(c.b - was.b) < 1 / 255 then
			return
		end
		entry.lit = c
		if entry.own_material then
			entry.material:SetShaderParameter("MatDiffColor", c)
			return
		end
		entry.effect:SetNumColorFrames(0)
		entry.effect:AddColorTime(magic.Color(c.r, c.g, c.b, 1), 0)
	end

	local function remove_spawner(id)
		local old = particle_nodes[id]
		if old == nil then
			return
		end
		particle_nodes[id] = nil
		-- The particles a spawner has already made outlive it, which is
		-- what Luanti does: its own particles are not owned by the spawner
		-- that made them. It matters more than it sounds -- VoxeLibre's
		-- weather takes its rain spawner away and adds it again twenty times
		-- a second, so a client that drops the particles with the spawner
		-- erases its own rain fifty milliseconds after making it. So the
		-- emitter stops emitting and the node goes when the last particle
		-- it made has expired.
		if old.emitter then
			old.emitter.emitting = false
		end
		old.life = old.ttl_max + 0.2
		old.attached = nil
		dying_spawners[#dying_spawners + 1] = old
		-- A cap, because each of these holds a pool of billboards: the
		-- oldest goes, which is the one whose particles are nearest the end
		-- of their lives anyway
		while #dying_spawners > DYING_SPAWNERS_MAX do
			table.remove(dying_spawners, 1).node:Remove()
		end
	end

	-- A spawner attached to an object has its positions relative to that
	-- object and follows it, which is what D.update() moves; the weather of
	-- a game is a spawner attached to the player.
	function D.spawner(id, p)
		remove_spawner(id)
		local scene = o.scene()
		if p == nil or p.texture == nil or scene == nil then
			return
		end
		local pos = middle(p.pos_min, p.pos_max)
		-- The same spawner as one that was taken away a moment ago: pick
		-- its emitter back up where it left off
		local signature = spawner_signature(p)
		for i, e in ipairs(dying_spawners) do
			if e.signature == signature then
				table.remove(dying_spawners, i)
				if e.emitter then
					e.emitter.emitting = true
				end
				e.life = p.time > 0 and (p.time + e.ttl_max + 0.5) or nil
				e.attached = p.attached
				e.offset = pos
				e.at_x, e.at_y, e.at_z = nil, nil, nil
				particle_nodes[id] = e
				return
			end
		end
		local node = scene:CreateChild("particles")
		node.position = magic.Vector3(pos[1], pos[2], pos[3])
		local amount = math.max(1, math.min(p.amount, 1000))
		local ttl_max = math.max(0.01, p.exp_max)
		local effect, material = particle_effect(p.texture, amount,
				math.max(0.01, p.exp_min), ttl_max,
				math.max(0.001, p.size_min), math.max(0.001, p.size_max),
				p.vel_min, p.vel_max, middle(p.acc_min, p.acc_max), p.time,
				p.animation, p.glow)
		-- What the emitter box is: the position range, which the node sits
		-- in the middle of
		effect.emitterType = 1 -- EMITTER_BOX
		effect:SetEmitterSize(magic.Vector3(
				math.max(0, p.pos_max[1] - p.pos_min[1]),
				math.max(0, p.pos_max[2] - p.pos_min[2]),
				math.max(0, p.pos_max[3] - p.pos_min[3])))
		-- Luanti spawns amount particles over time seconds, and amount a
		-- second when there is no time at all
		local rate = p.time > 0 and amount / p.time or amount
		effect.minEmissionRate = rate
		effect.maxEmissionRate = rate
		-- A spawner's own copy of the material, for its light on the
		-- material's colour (light())
		material = material:Clone()
		effect.material = material
		local emitter = node:CreateComponent("ParticleEmitter")
		emitter.effect = effect
		emitter.emitting = true
		emitter.castShadows = false
		-- Luanti's vertical particle is an upright quad turned to the
		-- player about Y rather than one facing the camera, which is what
		-- makes a rain drop look like a falling drop rather than a blob
		if p.vertical then
			emitter.faceCameraMode = magic.FC_ROTATE_Y
		end
		-- Collision, for what falls: a floor map (particles.lua)
		local floor = nil
		if p.collision and particles.falls(p.vel_min, p.vel_max,
				p.acc_min, p.acc_max) then
			local lo, hi = p.pos_min, p.pos_max
			floor = particles.floor_new(emitter,
					{lo[1] - pos[1], lo[2] - pos[2], lo[3] - pos[3]},
					{hi[1] - pos[1], hi[2] - pos[2], hi[3] - pos[3]},
					p.collision_removal)
		end
		-- The effect and its material are kept for as long as the emitter
		-- is: both were made in Lua, and a Lua-made Urho3D object is
		-- destroyed when the last Lua reference to it goes, whatever the
		-- engine still holds. An emitter whose effect has been collected
		-- reads freed memory: every particle flew off in a random direction
		-- at the default size instead of falling.
		particle_nodes[id] = {node = node, emitter = emitter, effect = effect,
				material = material, own_material = true,
				signature = signature, glow = p.glow, floor = floor,
				-- A spawner that ends takes itself away once the last
				-- particle it made has expired; one with no time waits for
				-- the server
				life = p.time > 0 and (p.time + ttl_max + 0.5) or nil,
				attached = p.attached, offset = pos, ttl_max = ttl_max}
	end

	-- One particle the server picked itself: an emitter of one that fires
	-- once and is taken away when it has expired
	function D.single(p)
		local scene = o.scene()
		if #single_particles >= SINGLE_PARTICLE_MAX or p.texture == nil or
				scene == nil then
			return
		end
		local ttl = math.max(0.01, p.exp_min)
		local node = scene:CreateChild("particle")
		node.position = magic.Vector3(p.pos_min[1], p.pos_min[2],
				p.pos_min[3])
		local effect, material = particle_effect(p.texture, 1, ttl, ttl,
				math.max(0.001, p.size_min), math.max(0.001, p.size_max),
				p.vel_min, p.vel_max, middle(p.acc_min, p.acc_max), 0.05,
				p.animation, p.glow)
		effect.emitterType = 0 -- EMITTER_SPHERE, of no size
		effect:SetEmitterSize(magic.Vector3(0, 0, 0))
		effect.minEmissionRate = 100
		effect.maxEmissionRate = 100
		local emitter = node:CreateComponent("ParticleEmitter")
		emitter.effect = effect
		emitter.emitting = true
		emitter.castShadows = false
		if p.vertical then
			emitter.faceCameraMode = magic.FC_ROTATE_Y
		end
		local entry = {node = node, life = ttl + 0.5, effect = effect,
				material = material, glow = p.glow}
		light(entry)
		single_particles[#single_particles + 1] = entry
	end

	-- Ages the emitters and takes away the ones that are done with. A
	-- spawner with no time of its own is not aged: the server deletes it.
	-- Called every frame.
	function D.update(dtime)
		for id, entry in pairs(particle_nodes) do
			if entry.attached then
				local x, y, z = o.attached_pos(entry.attached)
				if not x and not entry.said_missing then
					-- A spawner whose object the client does not know draws
					-- where the offset alone puts it, which is somewhere
					-- around the world's origin: worth one line rather than
					-- being a mystery
					entry.said_missing = true
					o.log:warning("particles: spawner " .. tostring(id) ..
							" is attached to object " ..
							tostring(entry.attached) ..
							", which is not one this client has")
				end
				if x and (x ~= entry.at_x or y ~= entry.at_y or
						z ~= entry.at_z) then
					entry.at_x, entry.at_y, entry.at_z = x, y, z
					entry.node.position = magic.Vector3(x + entry.offset[1],
							y + entry.offset[2], z + entry.offset[3])
				end
			end
			light(entry)
			if entry.floor then
				local q = entry.node.position
				particles.floor_update(entry.floor, entry.emitter, q.x, q.y,
						q.z, o.solid_at, FLOOR_BUDGET)
			end
			if entry.life then
				entry.life = entry.life - dtime
				if entry.life <= 0 then
					entry.node:Remove()
					particle_nodes[id] = nil
				end
			end
		end
		for _, list in ipairs({dying_spawners, single_particles}) do
			local i = 1
			while i <= #list do
				local entry = list[i]
				entry.life = entry.life - dtime
				if entry.life <= 0 then
					entry.node:Remove()
					table.remove(list, i)
				else
					i = i + 1
				end
			end
		end
	end

	-- For the counters line
	function D.count()
		local n = #single_particles + #dying_spawners
		for _, _ in pairs(particle_nodes) do
			n = n + 1
		end
		return n
	end

	return D
end
-- vim: set noet ts=4 sw=4:
