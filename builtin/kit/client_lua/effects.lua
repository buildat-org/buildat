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
-- [RACER_FEEL] (3) A client part's bursts (kit.effect below): at most
-- PART_BURSTS of MAX_BURSTS live, PART_RATE a second (PART_RATE / 4 at once);
-- past them dropped and counted
local PART_BURSTS, PART_RATE = 64, 240
local part_bursts, part_tokens, part_at, part_made, part_dropped = 0,
		PART_RATE / 4, 0, 0, 0

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

local function burst(d, at, part)
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
		local e = n > 0 and #bursts < MAX_BURSTS and (not part or
				part_bursts < PART_BURSTS) and effect_of(d, k[1], k[2])
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
				stop = math.ceil(n / IN_FRAME) + 1, till = now_s() + d.ttl_max + 0.1,
				part = part}
			part_bursts = part_bursts + (part and 1 or 0)
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

-- [RACER_FEEL] (3) kit.effect{...}: a burst of particles from a client part
-- (a handler or a movement's draw), drawn this frame on this client alone:
-- c:effect's particle fields (api.h; light, flash and arc not), clamped as
-- kit.cpp's effect_fx clamps them, at {x, y, z} (needed). Returns how many
-- particles it made (0: dropped). Its description is cached as c:effect's:
-- what varies call to call goes in at, dir and count
local function vec3(v, lim)
	if type(v) ~= "table" then
		return nil
	end
	local o = {}
	for i = 1, 3 do
		local n = tonumber(v[i])
		if not n or n ~= n or math.abs(n) > lim then
			return nil
		end
		o[i] = n
	end
	return o
end
function M.effect(x)
	local at = type(x) == "table" and vec3(x.at, 1e7)
	if not at then
		return 0
	end
	local t = now_s()
	part_tokens = math.min(PART_RATE / 4, part_tokens + (t - part_at) * PART_RATE)
	part_at = t
	if part_tokens < 1 or part_bursts >= PART_BURSTS then
		part_dropped = part_dropped + 1
		return 0
	end
	part_tokens = part_tokens - 1
	local function num(k, def, lo, hi)
		local v = tonumber(x[k])
		if v == nil or v ~= v or math.abs(v) == math.huge then
			return def
		end
		return math.max(lo, math.min(hi, v))
	end
	local d = {count = math.floor(num("count", 0, 0, 256)), shape = x.shape,
		colors = {}, voxels = {}}
	if d.shape ~= "round" and d.shape ~= "ring" and d.shape ~= "voxel" then
		d.shape = "square"
	end
	for _, k in ipairs({"colors", "voxels"}) do
		for i, c in ipairs(type(x[k]) == "table" and x[k] or {}) do
			if i <= 4 and type(c) == "string" and (k == "voxels" or
					c:match("^#%x%x%x%x%x%x$") or c:match("^#%x%x%x%x%x%x%x%x$")) then
				d[k][#d[k] + 1] = c
			end
		end
	end
	d.dir = vec3(x.dir, 1e6) or {0, 1, 0}
	local l = math.sqrt(d.dir[1] ^ 2 + d.dir[2] ^ 2 + d.dir[3] ^ 2)
	d.dir = l > 1e-6 and {d.dir[1] / l, d.dir[2] / l, d.dir[3] / l} or {0, 1, 0}
	d.spread = num("spread", 180, 0, 180)
	d.speed_min = num("speed_min", 1, 0, 60)
	d.speed_max = num("speed_max", d.speed_min, d.speed_min, 60)
	d.gravity = num("gravity", 0, -50, 50)
	d.drag = num("drag", 0, 0, 20)
	d.ttl_min = num("ttl_min", 1, 0.05, 10)
	d.ttl_max = num("ttl_max", d.ttl_min, d.ttl_min, 10)
	d.size_min = num("size_min", 0.1, 0.01, 8)
	d.size_max = num("size_max", d.size_min, d.size_min, 8)
	d.grow = num("grow", 0, -20, 100)
	d.fade = num("fade", 0.3, 0, 1)
	d.box = num("box", 0, 0, 16)
	d.spin = num("spin", 0, 0, 1440)
	d.land = x.land == true
	local made = burst(d, at, true)
	part_made = part_made + made
	return made
end

-- [RACER_FEEL] (3) kit.mark(x, y, z, yaw, size, color[, alpha]): a mark on the
-- ground from a client part (a tyre's): a flat quad at x, y + 0.02, z, turned
-- yaw degrees (from +z toward +x, as s.yaw), size {across, along} m (a number:
-- a square), color "#rrggbb", alpha 0...1 (0.6), unlit. Kept in a ring of
-- MAX_MARKS in the scene, the oldest replaced; drawn as CHUNK marks a
-- CustomGeometry, one that got marks rebuilt every MARK_EVERY s (a mark
-- shows up to that late: the cost is the sandbox's calls a vertex, ~3 ms for
-- a chunk of Vector3s made there; the corners made once, at the mark).
-- kit.clear_marks() takes them all away (a race's restart). This client's
-- alone. simplified: no fading with age, and a scene switch drops them (the
-- old scene's node goes with it)
local MAX_MARKS, CHUNK, MARK_EVERY = 1024, 32, 0.1
-- (two triangles of the four corners)
local QUAD = {1, 2, 3, 1, 3, 4}
local marks = {n = 0, next = 0, list = {}, dirty = {}, made = 0, at = 0}
local mark_mat
local mark_colors = {}
local function mark_chunk(c)
	if not marks.node or marks.scene ~= O.scene then
		return
	end
	local cg = marks.chunks[c]
	if not cg then
		cg = marks.node:CreateComponent("CustomGeometry")
		cg:SetNumGeometries(1)
		if not mark_mat then
			mark_mat = magic.Material:new()
			mark_mat:SetTechnique(0, magic.cache:GetResource("Technique",
					"kit/KitMarks.xml"))
		end
		cg:SetMaterial(0, mark_mat)
		cg.dynamic = true
		marks.chunks[c] = cg
	end
	-- (no normals or texcoords: unlit, NOUV)
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	for i = c * CHUNK, c * CHUNK + CHUNK - 1 do
		local m = marks.list[i]
		if m then
			local col = m[5]
			for _, k in ipairs(QUAD) do
				cg:DefineVertex(m[k])
				cg:DefineColor(col)
			end
		end
	end
	cg:Commit()
end
function M.mark(x, y, z, yaw, size, color, alpha)
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if not O.scene or not x or not y or not z then
		return
	end
	if marks.scene ~= O.scene then
		marks.scene = O.scene
		marks.node = O.scene:CreateChild("kit_marks")
		marks.chunks, marks.list, marks.dirty, marks.n, marks.next = {}, {}, {},
				0, 0
	end
	local w = type(size) == "table" and tonumber(size[1]) or tonumber(size) or 0.3
	local l = type(size) == "table" and tonumber(size[2]) or w
	w, l = math.max(0.01, math.min(16, w)) / 2, math.max(0.01, math.min(16, l)) / 2
	local a = math.rad(tonumber(yaw) or 0)
	-- along (sin, cos), across (cos, -sin)
	local fx, fz, rx, rz = math.sin(a) * l, math.cos(a) * l, math.cos(a) * w,
			-math.sin(a) * w
	y = y + 0.02
	alpha = math.max(0, math.min(1, tonumber(alpha) or 0.6))
	local ck = tostring(color) .. alpha
	local col = mark_colors[ck]
	if not col then
		-- (256 at most, then all start over: a game's few)
		mark_colors.n = (mark_colors.n or 0) + 1
		if mark_colors.n > 256 then
			mark_colors = {n = 1}
		end
		col = rgba(color, alpha)
		mark_colors[ck] = col
	end
	local i = marks.next
	local V3 = magic.Vector3
	marks.list[i] = {V3(x - fx - rx, y, z - fz - rz), V3(x - fx + rx, y, z - fz + rz),
		V3(x + fx + rx, y, z + fz + rz), V3(x + fx - rx, y, z + fz - rz), col}
	marks.dirty[math.floor(i / CHUNK)] = true
	marks.next = (i + 1) % MAX_MARKS
	marks.n = math.min(MAX_MARKS, marks.n + 1)
	marks.made = marks.made + 1
end
function M.clear_marks()
	if marks.node then
		marks.node:Remove()
	end
	marks.scene, marks.node = nil, nil
	log:info("kit: marks cleared")
end

-- For a drive: "event kit_effects" logs a client part's effects and marks
magic.SubscribeToEvent("command_seq:kit_effects", function()
	log:info(string.format("kit: effects: %d particles live in %d bursts (%d a " ..
			"client part's); client parts made %d particles, %d bursts dropped; " ..
			"%d marks kept of %d made (the last rebuilt in %d us)", live, #bursts,
			part_bursts, part_made, part_dropped, marks.scene == O.scene and
			marks.n or 0, marks.made, marks.us or 0))
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
			part_bursts = part_bursts - (b.part and 1 or 0)
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
	if next(marks.dirty) and t - marks.at >= MARK_EVERY then
		marks.at = t
		local t0 = buildat.get_time_us()
		for c in pairs(marks.dirty) do
			mark_chunk(c)
		end
		marks.dirty = {}
		marks.us = buildat.get_time_us() - t0
	end
end)
end
-- vim: set noet ts=4 sw=4:
