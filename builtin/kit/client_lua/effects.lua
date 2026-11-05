-- Buildat: builtin/kit/client_lua/effects.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- [KIT_PARTICLES], [KIT_FEEDBACK_EFFECTS] A component's c:effect drawn:
-- "kit:effect" (kit.cpp effect_fx(), which clamped it; api.h) a burst of
-- particles (an Urho3D ParticleEmitter a burst, a colour and a texture; its
-- ParticleEffect cached), a light with no shadow, a player's body tinted
-- (players.lua's M.flash_player); "kit:effect_arc" the arc at this player's
-- screen's edge towards where a hit came from. Nothing here reaches play.
-- Live particles past MAX_LIVE and bursts past MAX_BURSTS are dropped: a
-- particle that comes late is worse than one that does not come.
return function(K)
local M, O, P, log = K.M, K.O, K.P, K.log
local magic = require("buildat/extension/urho3d")
local network = require("buildat/extension/network")

local MAX_LIVE, MAX_BURSTS, MAX_LIGHTS = 1500, 128, 8
-- ParticleEmitter's MAX_PARTICLES_IN_FRAME
local IN_FRAME = 100
-- land's floor: this many cells round the place, looked for this far down
local FLOOR_R, FLOOR_DOWN = 3, 6

local TEXTURES = {square = "kit/particle_square.png",
	round = "kit/particle_round.png", ring = "kit/particle_ring.png"}

local now_s = function() return buildat.get_time_us() / 1e6 end
local live, bursts, lights = 0, {}, {}

-- One material a texture
local materials = {}
local function material_of(name)
	local m = materials[name]
	if m == nil then
		local tex = magic.cache:GetResource("Texture2D", name)
		if not tex then
			materials[name] = false
			return nil
		end
		m = magic.Material:new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/DiffUnlitParticleAlpha.xml"))
		m:SetTexture(magic.TU_DIFFUSE, tex)
		materials[name] = m
	end
	return m or nil
end

local function rgba(hex, alpha)
	local c = K.color(hex, magic.Color(1, 1, 1))
	return magic.Color(c.r, c.g, c.b, (alpha or 1) * c.a)
end

-- The part of a voxel material's texture a fragment shows: {name, u0, v0,
-- u1, v1, colour}, a quarter of its tile, in its palette's entry 0 as the
-- voxels wear it untinted (module.lua's voxel_mesh); nil: it has no texture
-- here
local function voxel_tile(name)
	local def = K.voxel_def(name)
	local seg = def and def.textures and (def.textures[3] or def.textures[1])
	if not seg or (seg.resource_name or "") == "" then
		return nil
	end
	-- (a texture of several tiles: side by side)
	local function x_of(v)
		return tonumber(v) or v and v.x or 0
	end
	local n = math.max(1, x_of(seg.total_segments))
	local u0 = x_of(seg.select_segment) / n
	local c0 = def.tint_palette and tonumber(def.tint_palette[1]) or 0xffffff
	return {seg.resource_name, u0 + 0.25 / n, 0.25, u0 + 0.5 / n, 0.5,
		string.format("#%06x", c0 % 0x1000000)}
end

local effects, effect_count = {}, 0
-- The cached effect of a burst's description in a colour and on a tile
local function effect_of(d, color, tile)
	local key = table.concat({d.shape, color, tile and table.concat(tile, " ") or "",
		d.spread, d.speed_min, d.speed_max, d.gravity, d.drag, d.ttl_min, d.ttl_max,
		d.size_min, d.size_max, d.grow, d.fade, d.box, d.spin}, "|")
	local e = effects[key]
	if e then
		return e
	end
	local mat = material_of(tile and tile[1] or TEXTURES[d.shape] or
			TEXTURES.square)
	if not mat then
		return nil
	end
	e = magic.ParticleEffect.new()
	e.material = mat
	e.relative = false
	e.scaled = false
	e.sorted = true
	-- (not in view until it has a particle: see particle_draw.lua)
	e.updateInvisible = true
	e.activeTime = 0
	e.inactiveTime = 0
	e.minEmissionRate = 100000
	e.maxEmissionRate = 100000
	e.minTimeToLive = d.ttl_min
	e.maxTimeToLive = d.ttl_max
	e:SetMinParticleSize(magic.Vector2(d.size_min / 2, d.size_min / 2))
	e:SetMaxParticleSize(magic.Vector2(d.size_max / 2, d.size_max / 2))
	-- The cone about the node's +z, by its half angle
	local s = d.spread
	if s >= 179.9 then
		e:SetMinDirection(magic.Vector3(-1, -1, -1))
		e:SetMaxDirection(magic.Vector3(1, 1, 1))
	elseif s >= 90 then
		e:SetMinDirection(magic.Vector3(-1, -1,
				math.cos(s * math.pi / 180) / math.max(0.01, math.sin(s * math.pi / 180))))
		e:SetMaxDirection(magic.Vector3(1, 1, 1))
	else
		local t = math.tan(s * math.pi / 180)
		e:SetMinDirection(magic.Vector3(-t, -t, 1))
		e:SetMaxDirection(magic.Vector3(t, t, 1))
	end
	e.minVelocity = d.speed_min
	e.maxVelocity = d.speed_max
	e:SetConstantForce(magic.Vector3(0, -d.gravity, 0))
	e.dampingForce = d.drag
	e.sizeAdd = d.grow
	e.emitterType = 1
	e:SetEmitterSize(magic.Vector3(d.box, d.box, d.box))
	if d.spin > 0 then
		e.minRotation, e.maxRotation = 0, 360
		e.minRotationSpeed, e.maxRotationSpeed = -d.spin, d.spin
	end
	if tile then
		e:AddTextureTime(magic.Rect(tile[2], tile[3], tile[4], tile[5]), 0)
	end
	e:AddColorTime(rgba(color), 0)
	if d.fade > 0 then
		e:AddColorTime(rgba(color), d.ttl_max * (1 - d.fade))
		e:AddColorTime(rgba(color, 0), d.ttl_max)
	end
	-- simplified: a burst's effects stay until there are 256, then all start
	-- over (a composition's few; a voxel's or a colour's more)
	if effect_count >= 256 then
		effects, effect_count = {}, 0
	end
	effects[key] = e
	effect_count = effect_count + 1
	return e
end

-- The ground under each column round the node's place, for land
local function set_floor(emitter, x, y, z)
	if not O.solid then
		return
	end
	local w = 2 * FLOOR_R + 1
	local x0, z0 = math.floor(x + 0.5) - FLOOR_R, math.floor(z + 0.5) - FLOOR_R
	local top = math.floor(y + 0.5)
	emitter:SetFloorMap(w, w, false)
	emitter:SetFloorOrigin(x0, z0)
	for cz = z0, z0 + w - 1 do
		for cx = x0, x0 + w - 1 do
			for cy = top, top - FLOOR_DOWN, -1 do
				if O.solid(cx, cy, cz) then
					emitter:SetFloorHeight(cx, cz, cy + 0.5)
					break
				end
			end
		end
	end
end

local function burst(d, at)
	if not O.scene or (tonumber(d.count) or 0) <= 0 then
		return 0
	end
	-- What it is shared between: each colour and, for voxels, each tile
	local kinds = {}
	local colors = type(d.colors) == "table" and #d.colors > 0 and d.colors or
			{"#ffffff"}
	if d.shape == "voxel" then
		for i, name in ipairs(d.voxels or {}) do
			local tile = voxel_tile(name)
			if tile then
				kinds[#kinds + 1] = {tile[6], tile}
			end
		end
	else
		for _, c in ipairs(colors) do
			kinds[#kinds + 1] = {c}
		end
	end
	local made = 0
	local dir = d.dir or {0, 1, 0}
	for _, k in ipairs(kinds) do
		local n = math.min(math.ceil(d.count / #kinds), MAX_LIVE - live)
		local e = n > 0 and #bursts < MAX_BURSTS and effect_of(d, k[1], k[2])
		if e then
			local node = O.scene:CreateChild("kit_effect")
			node.position = magic.Vector3(at[1], at[2], at[3])
			node.direction = magic.Vector3(dir[1], dir[2], dir[3])
			local em = node:CreateComponent("ParticleEmitter")
			em.effect = e
			em.numParticles = n
			if d.land then
				set_floor(em, at[1], at[2], at[3])
			end
			bursts[#bursts + 1] = {node = node, emitter = em, n = n, frames = 0,
				stop = math.ceil(n / IN_FRAME) + 1, till = now_s() + d.ttl_max + 0.1}
			live = live + n
			made = made + n
		end
	end
	return made
end

local function light(d, at)
	if not O.scene or not d.light_color or #lights >= MAX_LIGHTS then
		return
	end
	local node = O.scene:CreateChild("kit_effect_light")
	node.position = magic.Vector3(at[1], at[2], at[3])
	local l = node:CreateComponent("Light")
	l.lightType = magic.LIGHT_POINT
	l.range = d.light_range
	l.color = rgba(d.light_color)
	l.brightness = d.light_brightness
	-- Never a shadow: a point light's six faces are dear (the default's
	-- false; said for the reader)
	l.castShadows = false
	lights[#lights + 1] = {node = node, light = l, from = now_s(),
		time = d.light_time, brightness = d.light_brightness}
end

buildat.sub_packet("kit:effect", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or type(d.at) ~= "table" then
		return
	end
	local at = d.at
	-- An entity's look, as this client draws it (a carried flag's)
	local n = d.entity and P.nodes[d.entity]
	local src = n and (n.look or n.node)
	if src then
		local p, o = src.position, d.offset or {0, 0, 0}
		at = {p.x + o[1], p.y + o[2], p.z + o[3]}
	end
	local made = burst(d, at)
	light(d, at)
	if d.flash_player and M.flash_player then
		M.flash_player(d.flash_player, d.flash_color, d.flash_time)
	end
	log:verbose(string.format("kit: effect %d of %d %s at (%.1f,%.1f,%.1f), " ..
			"%d live%s", made, tonumber(d.count) or 0, tostring(d.shape), at[1], at[2],
			at[3], live, d.light_color and ", a light" or ""))
end)

-- ---- The arc: dots along the screen's edge, turning with the view
local ARC_DOTS, ARC_STEP, ARC_MAX = 21, 1.75 * math.pi / 180, 4
local arcs = {}

buildat.sub_packet("kit:effect_arc", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or type(d.from) ~= "table" then
		return
	end
	if #arcs >= ARC_MAX then
		for _, b in ipairs(table.remove(arcs, 1).dots) do
			b:Remove()
		end
	end
	local a = {from = d.from, at = now_s(), time = tonumber(d.time) or 1,
		color = rgba(d.color), dots = {}}
	for i = 1, ARC_DOTS do
		local b = magic.ui.root:CreateChild("BorderImage")
		b.blendMode = magic.BLEND_ALPHA
		b.priority = 90
		a.dots[i] = b
	end
	arcs[#arcs + 1] = a
	log:info(string.format("kit: a hit's arc from (%.1f,%.1f,%.1f)", d.from[1],
			d.from[2], d.from[3]))
end)

local function draw_arcs(t)
	local cam = O.camera
	for i = #arcs, 1, -1 do
		local a = arcs[i]
		local f = 1 - (t - a.at) / a.time
		if f <= 0 or not cam then
			for _, b in ipairs(a.dots) do
				b:Remove()
			end
			table.remove(arcs, i)
		else
			-- Its side as seen from above: round the view's forward direction
			local p, fw = cam.worldPosition, cam.worldDirection
			local dx, dz = a.from[1] - p.x, a.from[3] - p.z
			local ang = math.atan2(dx * fw.z - dz * fw.x, dx * fw.x + dz * fw.z)
			local w, h = magic.ui.root.width, magic.ui.root.height
			local size = math.max(4, math.floor(math.min(w, h) / 60))
			local rx, ry = w / 2 - 2 * size, h / 2 - 2 * size
			local col = magic.Color(a.color.r, a.color.g, a.color.b,
					math.min(1, 2 * f) * a.color.a)
			for k, b in ipairs(a.dots) do
				local q = ang + (k - (ARC_DOTS + 1) / 2) * ARC_STEP
				b:SetFixedSize(size, size)
				b:SetPosition(math.floor(w / 2 + rx * math.sin(q) - size / 2),
						math.floor(h / 2 - ry * math.cos(q) - size / 2))
				b.color = col
			end
		end
	end
end

magic.SubscribeToEvent("Update", function()
	local t = now_s()
	for i = #bursts, 1, -1 do
		local b = bursts[i]
		b.frames = b.frames + 1
		if b.emitter and b.frames == b.stop then
			-- Full by now: no more as the first go out
			b.emitter.emitting = false
		end
		if t >= b.till then
			live = live - b.n
			b.node:Remove()
			table.remove(bursts, i)
		end
	end
	for i = #lights, 1, -1 do
		local l = lights[i]
		local f = 1 - (t - l.from) / l.time
		if f <= 0 then
			l.node:Remove()
			table.remove(lights, i)
		else
			l.light.brightness = l.brightness * f
		end
	end
	if #arcs > 0 then
		draw_arcs(t)
	end
end)
end
-- vim: set noet ts=4 sw=4:
