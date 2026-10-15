-- Buildat: extensions/luanti_client/res/particles.lua
-- (the luanti module runs it too, served as luanti/particles.lua:
-- speed_range and the floor map)
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Luanti's particle descriptions, out of ADD_PARTICLESPAWNER and
-- SPAWN_PARTICLE.
--
-- The wire format is ParticleParameters::deSerialize and
-- Client::handleCommand_AddParticleSpawner in Luanti's own source. The layout
-- is built out of three shapes, which is what most of this file is:
--   value  -- one f32, or three of them for a vector
--   range  -- min, max, and a bias that skews where inside them a pick lands
--   tween  -- a style, a repetition count, an offset, and a start and an end
-- so a spawner's position is a tween of a range of vectors: fifteen floats.
--
-- Everything after the fields read here is optional on the wire: Luanti's own
-- reader stops when the stream runs out, which is what lets an older client
-- read a newer server's packet. This stops at the node fields for the same
-- reason -- drag, jitter, bounce, the attractors and the texture pool are
-- past that point and are not read.
--
-- simplified: only protocol 42 and up, which is Luanti 5.6 and up. Before
-- that the tweens are not on the wire at all and the ranges are laid out
-- differently; a spawner from such a server is dropped rather than read
-- wrong. See doc/luanti_client.txt for which servers this client is for.

local M = {}

M.MIN_PROTOCOL = 42

-- style, in Luanti's TweenStyle order
M.TWEEN_FORWARD = 0
M.TWEEN_REVERSE = 1
M.TWEEN_PULSE = 2
M.TWEEN_FLICKER = 3

local function read_range(r, read_value)
	local min = read_value(r)
	local max = read_value(r)
	return {min = min, max = max, bias = r:f32()}
end

local function read_tween(r, read_inner)
	local style = r:u8()
	if style >= 4 then
		style = M.TWEEN_FORWARD
	end
	local reps = r:u16()
	local beginning = r:f32()
	return {style = style, reps = reps, beginning = beginning,
			start = read_inner(r), stop = read_inner(r)}
end

local function read_f32(r)
	return r:f32()
end

local function read_v3f(r)
	local x, y, z = r:v3f()
	return {x, y, z}
end

local function read_f32_range(r)
	return read_range(r, read_f32)
end

local function read_v3f_range(r)
	return read_range(r, read_v3f)
end

-- parse_particle(r, protocol) -> a description of one particle
--
-- One particle has no ranges and no tweens: it is where it is and it moves
-- the way it moves. This is ParticleParameters::deSerialize.
function M.parse_particle(r, protocol)
	local p = {}
	p.pos = read_v3f(r)
	p.vel = read_v3f(r)
	p.acc = read_v3f(r)
	p.exptime = r:f32()
	p.size = r:f32()
	p.collision = r:u8() ~= 0
	p.texture = r:longstring()
	p.vertical = r:u8() ~= 0
	p.collision_removal = r:u8() ~= 0
	p.animation = r:animation()
	p.glow = r:u8()
	p.object_collision = r:u8() ~= 0
	-- The optional tail: which node the particle is a piece of, for a
	-- particle that wears a node's texture rather than one of its own
	if r:remaining() >= 4 then
		p.node_param0 = r:u16()
		p.node_param2 = r:u8()
		p.node_tile = r:u8()
	end
	return p
end

-- parse_spawner(r, protocol) -> a description of a spawner, or nil
--
-- What comes back has, per field, either a plain value or a tween of a range;
-- the caller picks what it can use. server_id is the id the server will
-- delete it by, and attached is the object it follows, or 0 for none.
function M.parse_spawner(r, protocol)
	if protocol < M.MIN_PROTOCOL then
		return nil, "protocol "..protocol.." is older than "..M.MIN_PROTOCOL
	end
	local p = {}
	p.amount = r:u16()
	p.time = r:f32()
	if p.time < 0 then
		return nil, "time < 0"
	end
	p.pos = read_tween(r, read_v3f_range)
	p.vel = read_tween(r, read_v3f_range)
	p.acc = read_tween(r, read_v3f_range)
	p.exptime = read_tween(r, read_f32_range)
	p.size = read_tween(r, read_f32_range)
	p.collision = r:u8() ~= 0
	p.texture = r:longstring()
	p.server_id = r:u32()
	p.vertical = r:u8() ~= 0
	p.collision_removal = r:u8() ~= 0
	p.attached = r:u16()
	p.animation = r:animation()
	p.glow = r:u8()
	p.object_collision = r:u8() ~= 0
	if r:remaining() >= 4 then
		p.node_param0 = r:u16()
		p.node_param2 = r:u8()
		p.node_tile = r:u8()
	end
	return p
end

-- speed_range(vel_min, vel_max) -> the slowest and the fastest a velocity
-- inside that box can be.
--
-- What wants it is Urho3D, which takes a particle's velocity as a direction
-- and a speed and normalizes the direction: a range of velocity *vectors*
-- has to be handed over as the box the direction is picked from plus the
-- magnitudes that box holds. Without the second half every particle leaves
-- at one node a second whatever the game asked for.
--
-- simplified: the speed is then picked independently of the direction, so a
-- particle aimed along a short axis of the box can come out as fast as one
-- aimed along a long one. Exact for a single particle, where the box is one
-- vector.
function M.speed_range(vel_min, vel_max)
	local near, far = 0, 0
	for i = 1, 3 do
		local lo, hi = vel_min[i], vel_max[i]
		local a = math.abs(lo)
		local b = math.abs(hi)
		-- Nothing has to travel along this axis at all when the range
		-- crosses zero; otherwise the shorter end is as slow as it gets
		local closest = (lo <= 0 and hi >= 0) and 0 or math.min(a, b)
		near = near + closest * closest
		far = far + math.max(a, b) * math.max(a, b)
	end
	return math.sqrt(near), math.sqrt(far)
end

-- The middle of a range, and the middle of a tween's starting range: what a
-- description that has no room for a range or a tween gets out of one.
function M.middle(range)
	local min, max = range.min, range.max
	if type(min) == "table" then
		return {(min[1] + max[1]) / 2, (min[2] + max[2]) / 2,
				(min[3] + max[3]) / 2}
	end
	return (min + max) / 2
end

-- **Particle collision** ([VANILLA_WEATHER] 4): Magic's ParticleEmitter
-- floor map (doc/client_api.txt), filled for a spawner with
-- `collisiondetection` whose particles fall. A column's floor is the top of
-- the first solid node below the box's top: a doorway's roofed half, eaves
-- or a tree's edge each get their own, and a box inside the ground has its
-- floor at its top, so nothing falls there. The window is the box's
-- columns and one more each side, for drift.
--
-- simplified: only what falls -- a particle flying sideways or up keeps no
-- collision, nor does object_collision. A node change reaches its column
-- by the round: every column is scanned again in turn, a budget of node
-- lookups a frame, the columns the window gains as it moves first. Until
-- one of those is scanned the ring holds the column a window's width
-- away. The scan stops FLOOR_DEPTH nodes down: what falls further has no
-- floor.
M.FLOOR_DEPTH = 96

function M.falls(p_vel_min, p_vel_max, p_acc_min, p_acc_max)
	return p_vel_min[2] <= 0 and p_vel_max[2] <= 0 and
			p_acc_min[2] <= 0 and p_acc_max[2] <= 0 and
			(p_vel_min[2] < 0 or p_vel_max[2] < 0 or p_acc_min[2] < 0 or
			p_acc_max[2] < 0)
end

-- A floor for emitter, whose box is lo..hi from its node (two {x,y,z}).
-- nil if it is wider than the engine takes.
function M.floor_new(emitter, lo, hi, remove)
	local w = math.ceil(hi[1] - lo[1]) + 3
	local d = math.ceil(hi[3] - lo[3]) + 3
	if w > 256 or d > 256 then
		return nil
	end
	emitter:SetFloorMap(w, d, remove)
	return {w = w, d = d, lo = lo, hi = hi, rr = 0, queue = {}, qi = 1}
end

-- Moves the window to where the emitter's node is (x, y, z) and scans
-- columns until budget node lookups are spent. solid_at(x, y, z) is true,
-- false, or nil where the map has not arrived (no floor there).
function M.floor_update(f, emitter, x, y, z, solid_at, budget)
	local x0 = math.floor(x + f.lo[1] + 0.5) - 1
	local z0 = math.floor(z + f.lo[3] + 0.5) - 1
	local top = math.floor(y + f.hi[2] + 0.5)
	local w, d = f.w, f.d
	if x0 ~= f.x0 or z0 ~= f.z0 then
		local ox, oz = f.x0, f.z0
		local queue = {}
		for i = f.qi, #f.queue do
			queue[#queue + 1] = f.queue[i]
		end
		for cz = z0, z0 + d - 1 do
			for cx = x0, x0 + w - 1 do
				if not ox or cx < ox or cx >= ox + w or cz < oz or
						cz >= oz + d then
					queue[#queue + 1] = {cx, cz}
				end
			end
		end
		f.queue, f.qi = queue, 1
		f.x0, f.z0 = x0, z0
		emitter:SetFloorOrigin(x0, z0)
	end
	local spent = 0
	while spent < budget do
		local cx, cz
		if f.qi <= #f.queue then
			local c = f.queue[f.qi]
			f.qi = f.qi + 1
			cx, cz = c[1], c[2]
		else
			cx, cz = x0 + f.rr % w, z0 + math.floor(f.rr / w)
			f.rr = (f.rr + 1) % (w * d)
		end
		if cx >= x0 and cx < x0 + w and cz >= z0 and cz < z0 + d then
			local floor = -1e9
			for cy = top, top - M.FLOOR_DEPTH, -1 do
				spent = spent + 1
				local s = solid_at(cx, cy, cz)
				if s == nil then
					break
				elseif s then
					floor = cy + 0.5
					break
				end
			end
			emitter:SetFloorHeight(cx, cz, floor)
		end
		spent = spent + 1
	end
end

return M
-- vim: set noet ts=4 sw=4:
