-- Buildat: builtin/kit/client_lua/move.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 4h: the movement interface's world, the same file on both
-- sides: the client predicts with it (controls.lua) and the server's box
-- steps with it (kit.cpp loads it into box.c's Lua, request "L"). Plain
-- Lua with + - * /, floor and sqrt only (the box has no libm), so both
-- sides compute the same bits; sin, cos and atan2 are its own.
--
-- A movement type (builtin/kit/types/walker.lua...) has
--   movement = {body = {r = half width, h = height, eye = eye height},
--     camera = "first_person"|"chase" (a vehicle's), camera_distance = a
--     chase view's metres behind (else kit/controls' distance), camera_up =
--     metres its target is raised, touch = "stick"|"tap"|"drive",
--     touch_buttons = {{"Fire", "jump"}...}: the touch bar's buttons, each
--     held while pressed as that input (jump or down), for the default Jump}
--   step = function(s, i, dt, w, p) ... end
-- s its state (s.pos the body's bottom middle {x, y, z}, s.vel; the rest
-- its own), changed in place; i this step's input: f (forward, -1...1),
-- r (right), yaw (the camera's, degrees from +z toward +x), jump (0/1),
-- go (0/1: a target), tx, ty, tz (where to go); dt seconds; p its
-- parameters; w the world:
--   w:cell(i, j, k) -> info or nil (air): the voxel centred on i, j, k
--   w:walk(s, b, wx, wz, jump, dt, p): a character's step, s.frame below
--   w:move(b, dx, dy, dz, step) -> dx, dy, dz moved, hits {x, y, z}
--     (hit sides: -1, 0 or 1): the body b = {x, y, z, r, h} swept along
--     y, then x and z, up a step of `step` where blocked, and onto the
--     ground's slope up to b.slope (tan of the slope limit)
--   w:ray(ox, oy, oz, dx, dy, dz, len) -> t, info, nx, ny, nz
--   w:down(x, y, z, len) -> how far down the first solid is, its info
--   w:under(x, y, z) -> the info of what is under the point (0.6 down)
--   w:contacts(b) -> {{info, nx, ny, nz}...} what touches the body
--   w.sin, w.cos, w.atan2, w.sqrt
-- info = {solid = true, friction = n (1), surface = "<tag>"}: a voxel's
-- (its type's `friction` and `surface` where it has them, else 1 and its
-- name without the author), an object's ("object"), the heightmap's
-- ("ground") or a cell not loaded ("unknown", solid; air over a
-- heightmap, [KIT_HM_FREE]) or a heightmap's edge ("edge").
-- [KIT_WALKER_FRAME] A walker on a free voxel object steps in the object's
-- frame, where its boxes are flat: s.frame the object's entity id, s.at the feet
-- there, s.vel its velocity there (s.pos stays the feet in the world, kept up
-- each step). Gravity is the world's turned in: past slope_limit the deck slides.
-- It enters on landing on an object's top (W:walk's end) and leaves by jumping,
-- by nothing under it, or by the world's floor under it (W:walk_on).
-- [KIT_MOVING_OBJECTS] A free object's pose can be a function of the shared time,
-- so no pose is ever sent: each input carries the time it was stepped at (i.t, ms),
-- M.steps puts the world's objects where they are at that time on both sides, and a
-- body in a frame is carried by s.at being local. The motion's parameters are
-- kit/wave's (M.wave); a row has its own and those of the moving objects it
-- is under as links, each in the world at rest (M.turned).
local M = {}
local floor, sqrt = math.floor, math.sqrt
local PI = 3.14159265358979323846
local EPS = 1e-4

local function abs(x)
	return x < 0 and -x or x
end

-- ---- Trigonometry of its own: Taylor series after the reduction, good
-- to 1e-14, the same bits on every side
-- The last ones kept: a movement asks the same few each step (the yaw's,
-- the slope limit's), and a series is dear in the box
local sin_cache, sin_n = {}, 0
function M.sin(x)
	local c = sin_cache[x]
	if c then
		return c
	end
	local x0 = x
	x = x - floor(x / (2 * PI) + 0.5) * 2 * PI
	if x > PI / 2 then
		x = PI - x
	elseif x < -PI / 2 then
		x = -PI - x
	end
	local x2, t, s = x * x, x, x
	for n = 1, 9 do
		t = -t * x2 / ((2 * n) * (2 * n + 1))
		s = s + t
	end
	if sin_n >= 64 then
		sin_cache, sin_n = {}, 0
	end
	sin_cache[x0], sin_n = s, sin_n + 1
	return s
end

function M.cos(x)
	return M.sin(x + PI / 2)
end

local function atan(t)
	local neg = t < 0
	if neg then
		t = -t
	end
	local inv = t > 1
	if inv then
		t = 1 / t
	end
	-- Halved twice: |t| <= tan(pi / 16)
	t = t / (1 + sqrt(1 + t * t))
	t = t / (1 + sqrt(1 + t * t))
	local t2, p, s = t * t, t, t
	for n = 1, 10 do
		p = -p * t2
		s = s + p / (2 * n + 1)
	end
	s = 4 * s
	if inv then
		s = PI / 2 - s
	end
	return neg and -s or s
end

function M.atan2(y, x)
	if x > 0 then
		return atan(y / x)
	elseif x < 0 then
		return atan(y / x) + (y >= 0 and PI or -PI)
	end
	return y > 0 and PI / 2 or y < 0 and -PI / 2 or 0
end
M.sqrt = sqrt
M.PI = PI

-- ---- Infos
M.UNKNOWN = {solid = true, friction = 1, surface = "unknown"}
M.OBJECT = {solid = true, friction = 1, surface = "object"}
M.GROUND = {solid = true, friction = 1, surface = "ground"}
M.EDGE = {solid = true, friction = 1, surface = "edge"}

-- A voxel's info from its definition's values (the server's table, both
-- sides): solid, friction (1 if none), surface ("" if none: its name's
-- after the author)
-- ([KIT_VOXEL_FORMAT]) and boxes: a shape's, {x0, y0, z0, x1, y1, z1, ...}
-- in the cell's -0.5...0.5 (none: the whole cell); the surface of a shape
-- ("kit/stone:stair") its material's
function M.voxel_info(name, solid, friction, surface, boxes)
	if not solid then
		return nil
	end
	if not surface or surface == "" then
		surface = tostring(name):match("([^/:]*)[^/]*$") or ""
	end
	local info = {solid = true, friction = tonumber(friction) or 1,
		surface = surface}
	if type(boxes) == "table" and #boxes >= 6 then
		info.boxes = boxes
	end
	return info
end

-- A cell's sub-boxes in the world (a shape's), or nil for the whole cell
local function cell_boxes(info, i, j, k)
	local bx = info.boxes
	if not bx then
		return nil
	end
	local out = {}
	for q = 1, #bx - 5, 6 do
		out[#out + 1] = {i + bx[q], j + bx[q + 1], k + bx[q + 2],
			i + bx[q + 3], j + bx[q + 4], k + bx[q + 5], info = info}
	end
	return out
end

-- ---- Looks as boxes: an object's look (module.lua's look_box: its size,
-- its middle off the entity, `when` over it while its state is on, a
-- swing a quarter turn round its -x edge) turned by its look's rotation
-- and the entity's turn (yaw, pitch, roll), as the box round it {x0, y0, z0,
-- x1, y1, z1}; nil when it is not solid
local function m3(a, b)
	local r = {}
	for i = 0, 2 do
		for j = 0, 2 do
			local s = 0
			for k = 0, 2 do
				s = s + a[i * 3 + k + 1] * b[k * 3 + j + 1]
			end
			r[i * 3 + j + 1] = s
		end
	end
	return r
end
local function rotation(rx, ry, rz)
	local function ry_(d)
		local c, s = M.cos(d * PI / 180), M.sin(d * PI / 180)
		return {c, 0, s, 0, 1, 0, -s, 0, c}
	end
	local function rx_(d)
		local c, s = M.cos(d * PI / 180), M.sin(d * PI / 180)
		return {1, 0, 0, 0, c, -s, 0, s, c}
	end
	local function rz_(d)
		local c, s = M.cos(d * PI / 180), M.sin(d * PI / 180)
		return {c, -s, 0, s, c, 0, 0, 0, 1}
	end
	return m3(ry_(ry), m3(rx_(rx), rz_(rz)))
end

function M.look_box(look, on, pos, yaw, pitch, roll)
	-- ([KIT_MOVING_OBJECTS] or yaw the entity's turn as a matrix)
	if type(look) ~= "table" then
		return nil
	end
	local size, off = {}, {0, 0, 0}
	if type(look.size) == "table" then
		for i = 1, 3 do
			local v = tonumber(look.size[i]) or 1
			size[i] = v < 0.02 and 0.02 or v > 64 and 64 or v
		end
	else
		local v = (tonumber(look.size) or 0.4) * 2
		size = {v, v, v}
	end
	if type(look.offset) == "table" then
		for i = 1, 3 do
			off[i] = tonumber(look.offset[i]) or 0
		end
	end
	local w = on and type(look.when) == "table" and look.when or {}
	local solid = look.solid == true
	if w.solid ~= nil then
		solid = w.solid == true
	end
	if not solid then
		return nil
	end
	-- [KIT] stage 4l: moved by when.offset while on (kit/mover).
	-- simplified: where the state has it at once, not along its slide
	if type(w.offset) == "table" then
		for i = 1, 3 do
			off[i] = off[i] + (tonumber(w.offset[i]) or 0)
		end
	end
	if type(w.scale) == "table" then
		for i = 1, 3 do
			local was = size[i]
			size[i] = size[i] * (tonumber(w.scale[i]) or 1)
			if i == 2 then
				off[2] = off[2] - (was - size[2]) / 2
			end
		end
	end
	if w.swing then
		-- [KIT_DOOR_MIRROR] mirror: the other way, from its back to -z
		local hinge, front = off[1] - size[1] / 2, off[3] - size[3] / 2
		local back = off[3] + size[3] / 2
		size[1], size[3] = size[3], size[1]
		off[1] = hinge + size[1] / 2
		off[3] = w.mirror == true and back - size[3] / 2 or
				front + size[3] / 2
	end
	local r = type(look.rotation) == "table" and look.rotation or {}
	local R
	pitch, roll = tonumber(pitch) or 0, tonumber(roll) or 0
	if type(yaw) == "table" then
		R = m3(yaw, rotation(tonumber(r[1]) or 0, tonumber(r[2]) or 0, tonumber(r[3]) or 0))
	elseif pitch == 0 and roll == 0 then
		R = rotation(tonumber(r[1]) or 0, (tonumber(r[2]) or 0) +
				(tonumber(yaw) or 0), tonumber(r[3]) or 0)
	else
		R = m3(rotation(pitch, tonumber(yaw) or 0, roll), rotation(
				tonumber(r[1]) or 0, tonumber(r[2]) or 0, tonumber(r[3]) or 0))
	end
	-- simplified: the turned box's bounds, the box round it; a wedge is
	-- its whole box
	local b = {math.huge, math.huge, math.huge, -math.huge, -math.huge,
		-math.huge}
	for cx = -1, 1, 2 do for cy = -1, 1, 2 do for cz = -1, 1, 2 do
		local v = {off[1] + cx * size[1] / 2, off[2] + cy * size[2] / 2,
			off[3] + cz * size[3] / 2}
		for i = 0, 2 do
			local c = R[i * 3 + 1] * v[1] + R[i * 3 + 2] * v[2] +
					R[i * 3 + 3] * v[3] + pos[i + 1]
			if c < b[i + 1] then b[i + 1] = c end
			if c > b[i + 4] then b[i + 4] = c end
		end
	end end end
	return b
end

-- [KIT_MOVING_OBJECTS] What the object's motion is at t (seconds): the turn over its
-- own (pitch, yaw, roll, degrees), how far up its own axis, how far along its course
-- (0...1...0)
local function swing(amp, period, t)
	amp, period = tonumber(amp) or 0, tonumber(period) or 0
	if amp == 0 or period <= 0 then
		return 0
	end
	return amp * M.sin(2 * PI * t / period)
end
function M.wave(m, t)
	local ct, u = tonumber(m.course_time) or 0, 0
	if ct > 0 then
		u = t / ct
		u = u - 2 * floor(u / 2)
		u = u > 1 and 2 - u or u
	end
	return swing(m.wave_pitch, m.wave_pitch_period, t),
			swing(m.wave_yaw, m.wave_yaw_period, t),
			swing(m.wave_roll, m.wave_roll_period, t),
			swing(m.wave_heave, m.wave_heave_period, t), u
end

local function vec3(v)
	if type(v) ~= "table" then
		return 0, 0, 0
	end
	return tonumber(v[1]) or 0, tonumber(v[2]) or 0, tonumber(v[3]) or 0
end

-- [KIT_VEHICLE_MOVEMENTS] A steered object's track: M.tracks[entity] its keys, each
-- {t ms, x, y, z, yaw, pitch, roll} (its place and turn in its parent's frame), in
-- order; the client's from "kit:track", the box's each request's (M.snapshot). At t
-- (seconds): between the two round it, past the last on from the two last for half
-- a second at most, before the first the first (kit.cpp's track_at says the same).
-- nil: no keys
M.tracks = {}
function M.track_at(id, t)
	local k = M.tracks[id]
	if type(k) ~= "table" or #k == 0 then
		return nil
	end
	local ms = t * 1000
	if ms <= k[1][1] then
		local a = k[1]
		return a[2], a[3], a[4], a[5], a[6], a[7]
	end
	local lo, hi = 1, #k
	while lo < hi do
		local mid = floor((lo + hi + 1) / 2)
		if k[mid][1] <= ms then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local a, b, u = k[lo], k[lo + 1], 0
	if b then
		u = (ms - a[1]) / (b[1] - a[1])
	elseif lo > 1 then
		a, b = k[lo - 1], k[lo]
		u = ((ms < b[1] + 500 and ms or b[1] + 500) - a[1]) / (b[1] - a[1])
	else
		return a[2], a[3], a[4], a[5], a[6], a[7]
	end
	local r = {}
	for i = 2, 7 do
		local d = b[i] - a[i]
		if i >= 5 then
			d = d - 360 * floor((d + 180) / 360)
		end
		r[i] = a[i] + d * u
	end
	return r[2], r[3], r[4], r[5], r[6], r[7]
end

-- A link {x, y, z, yaw, pitch, roll, motion} (an object at rest in the world, what
-- moves it) at t: where its origin is, D, the world's turn it makes round where its
-- origin was at rest, and the wave's angles (kit.cpp's moved_local says the same in
-- the object's parent). [KIT_VEHICLE_MOVEMENTS] A steered one's (motion.track its
-- entity, motion.frame its parent's frame at rest {x, y, z, yaw, pitch, roll}): its
-- track's place and turn there, the wave on top; then also the track's yaw, pitch
-- and roll
function M.link_at(l, t)
	local R0 = l.R0
	if not R0 then
		R0 = rotation(tonumber(l[5]) or 0, tonumber(l[4]) or 0, tonumber(l[6]) or 0)
		l.R0 = R0
	end
	local m = l[7]
	local wp, wy, wr, h, u = M.wave(m, t)
	local W = rotation(wp, wy, wr)
	local px, py, pz = vec3(m.pivot)
	local cx, cy, cz = vec3(m.course)
	local vx = px + cx * u - (W[1] * px + W[2] * py + W[3] * pz)
	local vy = py + cy * u + h - (W[4] * px + W[5] * py + W[6] * pz)
	local vz = pz + cz * u - (W[7] * px + W[8] * py + W[9] * pz)
	local kx, ky, kz, kyaw, kpitch, kroll
	if m.track and type(m.frame) == "table" then
		kx, ky, kz, kyaw, kpitch, kroll = M.track_at(m.track, t)
	end
	if kx then
		local f = m.frame
		local F = l.F
		if not F then
			F = rotation(tonumber(f[5]) or 0, tonumber(f[4]) or 0, tonumber(f[6]) or 0)
			l.F = F
		end
		local FK = m3(F, rotation(kpitch, kyaw, kroll))
		local A = m3(FK, W)
		local D = {}
		for i = 0, 2 do
			for j = 0, 2 do
				D[i * 3 + j + 1] = A[i * 3 + 1] * R0[j * 3 + 1] + A[i * 3 + 2] * R0[j * 3 + 2]
						+ A[i * 3 + 3] * R0[j * 3 + 3]
			end
		end
		local fx, fy, fz = vec3(f)
		return fx + F[1] * kx + F[2] * ky + F[3] * kz + FK[1] * vx + FK[2] * vy + FK[3] * vz,
				fy + F[4] * kx + F[5] * ky + F[6] * kz + FK[4] * vx + FK[5] * vy + FK[6] * vz,
				fz + F[7] * kx + F[8] * ky + F[9] * kz + FK[7] * vx + FK[8] * vy + FK[9] * vz,
				D, wp, wy, wr, kyaw, kpitch, kroll
	end
	local A = m3(R0, W)
	local D = {}
	for i = 0, 2 do
		for j = 0, 2 do
			D[i * 3 + j + 1] = A[i * 3 + 1] * R0[j * 3 + 1] + A[i * 3 + 2] * R0[j * 3 + 2]
					+ A[i * 3 + 3] * R0[j * 3 + 3]
		end
	end
	return l[1] + R0[1] * vx + R0[2] * vy + R0[3] * vz,
			l[2] + R0[4] * vx + R0[5] * vy + R0[6] * vz,
			l[3] + R0[7] * vx + R0[8] * vy + R0[9] * vz, D, wp, wy, wr
end

-- A place and turn at rest as its links have them at t (the nearest link first)
local function pose_of(links, x, y, z, R, t)
	for _, l in ipairs(links) do
		local xt, yt, zt, D = M.link_at(l, t)
		local dx, dy, dz = x - l[1], y - l[2], z - l[3]
		x = xt + D[1] * dx + D[2] * dy + D[3] * dz
		y = yt + D[4] * dx + D[5] * dy + D[6] * dz
		z = zt + D[7] * dx + D[8] * dy + D[9] * dz
		R = m3(D, R)
	end
	return x, y, z, R
end

-- A point or direction into an object's frame, and out of it (R: frame to world)
local function into(o, x, y, z)
	local R = o.R
	return R[1] * x + R[4] * y + R[7] * z, R[2] * x + R[5] * y + R[8] * z,
			R[3] * x + R[6] * y + R[9] * z
end
local function outof(o, x, y, z)
	local R = o.R
	return R[1] * x + R[2] * y + R[3] * z, R[4] * x + R[5] * y + R[6] * z,
			R[7] * x + R[8] * y + R[9] * z
end

-- [KIT_FREE_PREFAB] The free voxel objects as a world's t.turned: from {x, y, z,
-- yaw, pitch, roll, {x0, y0, z0, x1, y1, z1, ...}, id} (a place, a turn, boxes in
-- that frame, its entity). [KIT_WALKER_FRAME] A body outside its frame meets one
-- as a box of the object's axes, from its feet: turned with the object. A body
-- standing on it steps in its frame. [KIT_MOVING_OBJECTS] And o[9], its links
-- (M.link_at): W:pose_at moves it.
function M.turned(list)
	local out = {}
	for _, o in ipairs(list) do
		local b, rad, boxes = o[7], 0, {}
		for i = 1, #b - 5, 6 do
			boxes[#boxes + 1] = {b[i], b[i + 1], b[i + 2], b[i + 3], b[i + 4],
				b[i + 5]}
			local e = {b[i], b[i + 1], b[i + 2]}
			for k = 1, 3 do
				if abs(b[i + k + 2]) > abs(e[k]) then
					e[k] = b[i + k + 2]
				end
			end
			local d = sqrt(e[1] * e[1] + e[2] * e[2] + e[3] * e[3])
			rad = d > rad and d or rad
		end
		local t = {id = o[8], x = o[1], y = o[2], z = o[3], rad = rad, b = boxes,
			R = rotation(tonumber(o[5]) or 0, tonumber(o[4]) or 0, tonumber(o[6]) or 0)}
		if type(o[9]) == "table" and #o[9] > 0 then
			t.links, t.x0, t.y0, t.z0, t.R0 = o[9], t.x, t.y, t.z, t.R
		end
		-- What a sweep along y meets on its top: M.OBJECT and the way in
		t.info = {solid = true, friction = 1, surface = "object", frame = t}
		out[#out + 1] = t
	end
	return out
end

-- ---- The world: t.cell(i, j, k) -> info or nil, t.boxes ({x0, y0, z0,
-- x1, y1, z1, info = ...}...), t.turned (M.turned), t.ground(x, z) -> a
-- heightmap's height
-- or nil, t.edge {x0, z0, x1, z1}: a heightmap's extent. [KIT_HM_FREE]
-- Over a heightmap (t.ground or t.edge) a cell not loaded is air: its
-- voxels are only what is built, and a body walks on while they come in;
-- the extent is a wall: nobody walks off the map
local W = {}
W.sin, W.cos, W.atan2, W.sqrt, W.PI = M.sin, M.cos, M.atan2, sqrt, PI

function M.world(t)
	-- Copied in (the client's sandbox has no setmetatable)
	local w = {}
	for k, v in pairs(W) do
		w[k] = v
	end
	w.cell_fn = t.cell
	w.boxes = t.boxes or {}
	w.turned = t.turned or {}
	w.ground_fn = t.ground
	w.edge = t.edge
	w.unknown_air = t.ground ~= nil or t.edge ~= nil
	w.cache = {}
	-- [KIT_MOVING_OBJECTS] t.moving_looks: solid looks on moving objects, each
	-- {look, on, {x, y, z}, yaw, pitch, roll, links} at rest
	w.moving_looks = t.moving_looks
	w.moving = t.moving_looks ~= nil and #t.moving_looks > 0
	for _, o in ipairs(w.turned) do
		w.moving = w.moving or o.links ~= nil
	end
	if w.moving and t.t then
		w:pose_at(t.t)
	end
	return w
end

-- [KIT_MOVING_OBJECTS] The moving objects and looks of this world where they are at
-- t (seconds): both sides, for a step stamped t
function W:pose_at(t)
	self.t = t
	for _, o in ipairs(self.turned) do
		if o.links then
			o.x, o.y, o.z, o.R = pose_of(o.links, o.x0, o.y0, o.z0, o.R0, t)
		end
	end
	if self.moving_looks then
		if not self.static_boxes then
			self.static_boxes = self.boxes
		end
		local b = {}
		for _, o in ipairs(self.static_boxes) do
			b[#b + 1] = o
		end
		for _, l in ipairs(self.moving_looks) do
			local p = l[3]
			local x, y, z, R = pose_of(l[7], p[1], p[2], p[3], rotation(tonumber(l[5]) or 0,
					tonumber(l[4]) or 0, tonumber(l[6]) or 0), t)
			local box = M.look_box(l[1], l[2], {x, y, z}, R)
			if box then
				box.links = l[7]
				b[#b + 1] = box
			end
		end
		self.boxes = b
	end
end

-- What a moving object's point goes at, in the world, as it is at self.t: m/s
function W:deck_velocity(o, x, y, z)
	if not o.links or not self.t then
		return 0, 0, 0
	end
	local lx, ly, lz = into(o, x - o.x, y - o.y, z - o.z)
	local dt = 0.02
	local ax, ay, az, R = pose_of(o.links, o.x0, o.y0, o.z0, o.R0, self.t - dt)
	local bx, by, bz = outof({R = R}, lx, ly, lz)
	return (x - bx - ax) / dt, (y - by - ay) / dt, (z - bz - az) / dt
end

function W:cell(i, j, k)
	-- A number (a string's making is dear in the box)
	local key = (i + 32768) + 65536 * ((j + 32768) + 65536 * (k + 32768))
	local v = self.cache[key]
	if v == nil then
		v = self.cell_fn(i, j, k) or false
		if v == M.UNKNOWN and self.unknown_air then
			v = false
		end
		self.cache[key] = v
	end
	return v or nil
end

-- The heightmap's height at x, z (nil: none there)
function W:height(x, z)
	return self.ground_fn and self.ground_fn(x, z) or nil
end

-- The highest ground under a footprint: its corners and middle
function W:ground_max(x0, z0, x1, z1)
	if not self.ground_fn then
		return nil
	end
	local best = nil
	for _, p in ipairs({{x0, z0}, {x1, z0}, {x0, z1}, {x1, z1},
			{(x0 + x1) / 2, (z0 + z1) / 2}}) do
		local h = self.ground_fn(p[1], p[2])
		if h and (not best or h > best) then
			best = h
		end
	end
	return best
end

local ray_turned

local function lo_cell(a)
	return floor(a + EPS - 0.5) + 1
end
local function hi_cell(a)
	return -floor(-(a - EPS + 0.5)) - 1
end

-- [KIT_WALKER_FRAME] The feet in an object's box grown by the body, a hair in from
-- the faces, so that one touching can go along or away: lo and hi
local function grown(f, r, h)
	return f[1] - r + EPS, f[2] - h + EPS, f[3] - r + EPS,
			f[4] + r - EPS, f[5] - EPS, f[6] + r - EPS
end

-- The sweep's move d along world axis a past the free objects: the body from its
-- feet along each object's axes, the move turned in. Along x and z any face stops
-- it. Along y what can hold a body does: an object's top, a face within 60 degrees
-- of level; a steeper side lets it past and W:shed moves it out, so that nothing
-- hangs on a leaning wall. On a top the info is the object's own (W:walk's way in).
function W:sweep_turned(b, a, d)
	local hit = nil
	local r, h = (b[4] - b[1]) / 2, b[5] - b[2]
	local fx, fy, fz = (b[1] + b[4]) / 2, b[2], (b[3] + b[6]) / 2
	for _, o in ipairs(self.turned) do
		local lx, ly, lz = into(o, fx - o.x, fy - o.y, fz - o.z)
		local reach = o.rad + 2 * r + h + abs(d)
		if o ~= self.skip and lx * lx + ly * ly + lz * lz <= reach * reach then
			local p = {lx, ly, lz}
			local m = {into(o, a == 1 and d or 0, a == 2 and d or 0,
					a == 3 and d or 0)}
			local t, len = 1, abs(d)
			for _, f in ipairs(len > 1e-12 and o.b or {}) do
				local x0, y0, z0, x1, y1, z1 = grown(f, r, h)
				local lo, hi = {x0, y0, z0}, {x1, y1, z1}
				-- One the body is in already is no wall: it gets out
				if not (lx > x0 and lx < x1 and ly > y0 and ly < y1 and
						lz > z0 and lz < z1) then
					local t0, t1, na = 0, 1, nil
					for q = 1, 3 do
						if abs(m[q]) < 1e-12 then
							if p[q] <= lo[q] or p[q] >= hi[q] then
								t0 = 2
							end
						else
							local e0, e1 = (lo[q] - p[q]) / m[q], (hi[q] - p[q]) / m[q]
							if e0 > e1 then
								e0, e1 = e1, e0
							end
							if e0 >= t0 then
								t0, na = e0, q
							end
							if e1 < t1 then
								t1 = e1
							end
						end
					end
					if na and t0 <= t1 and t0 < t then
						local top = a == 2 and d < 0 and na == 2 and m[2] < 0
						if a ~= 2 or top or abs(m[na]) >= 0.5 * len then
							-- Short of it by as much again
							t = t0 - 2 * EPS / len
							if t < 0 then
								t = 0
							end
							hit = top and o.info or M.OBJECT
						end
					end
				end
			end
			d = d * t
		end
	end
	return d, hit
end

-- A side passed by the sweep along y, moved: the feet out of it by its nearest
-- side, no more than the move's own size: x, y, z to add. Level objects have no
-- such side
function W:shed(x, y, z, r, h, moved)
	local sx, sy, sz = 0, 0, 0
	for _, o in ipairs(self.turned) do
		local lx, ly, lz = into(o, x - o.x, y - o.y, z - o.z)
		local reach = o.rad + 2 * r + h
		if abs(1 - o.R[5]) > 1e-9 and lx * lx + ly * ly + lz * lz <= reach * reach then
			for _, f in ipairs(o.b) do
				local x0, y0, z0, x1, y1, z1 = grown(f, r, h)
				if lx > x0 and lx < x1 and ly > y0 and ly < y1 and lz > z0 and lz < z1 then
					local best, ax, q = lx - x0, 1, -1
					if x1 - lx < best then best, ax, q = x1 - lx, 1, 1 end
					if lz - z0 < best then best, ax, q = lz - z0, 3, -1 end
					if z1 - lz < best then best, ax, q = z1 - lz, 3, 1 end
					if best <= abs(moved) + 2 * EPS then
						local e = q * (best + 2 * EPS)
						local dx, dy, dz = outof(o, ax == 1 and e or 0, 0,
								ax == 3 and e or 0)
						sx, sy, sz = sx + dx, sy + dy, sz + dz
						lx, ly, lz = into(o, x + sx - o.x, y + sy - o.y, z + sz - o.z)
					end
				end
			end
		end
	end
	return sx, sy, sz
end

-- The box b0..b1 ({x0, y0, z0, x1, y1, z1}) moved by d along axis a (1:
-- x, 2: y, 3: z) as far as the solid cells and boxes let it: the move,
-- and the info hit (nil: none)
function W:sweep(b, a, d)
	if d == 0 then
		return 0, nil
	end
	local lo, hi = {b[1], b[2], b[3]}, {b[4], b[5], b[6]}
	if d > 0 then
		hi[a] = hi[a] + d
	else
		lo[a] = lo[a] + d
	end
	local hit = nil
	-- Along a only the cells past the face (those it is in are no wall)
	local r0, r1 = {lo_cell(lo[1]), lo_cell(lo[2]), lo_cell(lo[3])},
		{hi_cell(hi[1]), hi_cell(hi[2]), hi_cell(hi[3])}
	if d > 0 then
		r0[a] = -floor(-(b[a + 3] - EPS + 0.5))
	else
		r1[a] = floor(b[a] + EPS - 0.5)
	end
	-- [KIT_SLAB_WALK] A shape's boxes in the cell the face is in are in
	-- the way too (a slab's top is mid-cell: a body standing on it has
	-- its feet in that cell); the boxes behind the face are left out below
	local e0, e1 = r0[a], r1[a]
	if d > 0 then
		e0 = e0 - 1
	else
		e1 = e1 + 1
	end
	local lo_a, hi_a = r0[a], r1[a]
	r0[a], r1[a] = e0, e1
	-- The shapes' boxes in the way, met with the objects' below
	local sub = nil
	for i = r0[1], r1[1] do
		for j = r0[2], r1[2] do
			for k = r0[3], r1[3] do
				local info = self:cell(i, j, k)
				local c = a == 1 and i or a == 2 and j or k
				if info and not info.boxes and (c < lo_a or c > hi_a) then
					info = nil
				end
				if info and info.boxes then
					sub = sub or {}
					for _, o in ipairs(cell_boxes(info, i, j, k)) do
						sub[#sub + 1] = o
					end
				elseif info then
					-- One the box is in already is no wall: it gets out
					if d > 0 then
						local lim = c - 0.5 - b[a + 3]
						if lim > -EPS and lim < d then
							d, hit = lim < 0 and 0 or lim, info
						end
					else
						local lim = c + 0.5 - b[a]
						if lim < EPS and lim > d then
							d, hit = lim > 0 and 0 or lim, info
						end
					end
				end
			end
		end
	end
	local function box_list(n)
		if n == 1 then return self.boxes end
		return sub or {}
	end
	for n = 1, 2 do for _, o in ipairs(box_list(n)) do
		local over = true
		for q = 1, 3 do
			if q ~= a and (o[q] >= b[q + 3] - EPS or o[q + 3] <= b[q] + EPS) then
				over = false
			end
		end
		if over then
			if d > 0 and o[a] >= b[a + 3] - EPS then
				local lim = o[a] - b[a + 3]
				if lim < d then
					d, hit = lim < 0 and 0 or lim, o.info or M.OBJECT
				end
			elseif d < 0 and o[a + 3] <= b[a] + EPS then
				local lim = o[a + 3] - b[a]
				if lim > d then
					d, hit = lim > 0 and 0 or lim, o.info or M.OBJECT
				end
			end
		end
	end end
	local dt, ht = self:sweep_turned(b, a, d)
	d, hit = dt, ht or hit
	-- [KIT_HM_FREE] The heightmap's extent: a wall (one past it already:
	-- no further out)
	local e = self.edge
	if e and a ~= 2 then
		local q = a == 1 and 0 or 1
		if d > 0 then
			local lim = e[q + 3] - b[a + 3]
			if lim < d then
				d, hit = lim < 0 and 0 or lim, M.EDGE
			end
		else
			local lim = e[q + 1] - b[a]
			if lim > d then
				d, hit = lim > 0 and 0 or lim, M.EDGE
			end
		end
	end
	-- The heightmap stops a fall (one in it already: at once)
	if a == 2 and d < 0 then
		local g = self:ground_max(b[1], b[3], b[4], b[6])
		if g and g - b[2] > d then
			d, hit = g - b[2] > 0 and 0 or g - b[2], M.GROUND
		end
	end
	return d, hit
end

local function box_of(x, y, z, r, h)
	return {x - r, y, z - r, x + r, y + h, z + r}
end

-- [KIT_VEHICLE_MOVEMENTS] A moving look on the skipped object (a seat on the deck the
-- body stands on): its frame has it; as an axis-aligned box in the world, a turned deck's
-- look reaches past its sides
local function on_skipped(w, box)
	local d = w.skip and w.skip.links and w.skip.links[1]
	if not d or not box.links then
		return false
	end
	for _, l in ipairs(box.links) do
		if l[1] == d[1] and l[2] == d[2] and l[3] == d[3] then
			return true
		end
	end
	return false
end

-- Whether the box is in anything solid (known_only: not counting a cell not loaded;
-- self.skip left out)
function W:blocked(b, known_only)
	for i = lo_cell(b[1]), hi_cell(b[4]) do
		for j = lo_cell(b[2]), hi_cell(b[5]) do
			for k = lo_cell(b[3]), hi_cell(b[6]) do
				local info = self:cell(i, j, k)
				if info and info.boxes then
					for _, o in ipairs(cell_boxes(info, i, j, k)) do
						if o[1] < b[4] - EPS and o[4] > b[1] + EPS and
								o[2] < b[5] - EPS and o[5] > b[2] + EPS and
								o[3] < b[6] - EPS and o[6] > b[3] + EPS then
							return true
						end
					end
				elseif info and not (known_only and info == M.UNKNOWN) then
					return true
				end
			end
		end
	end
	for _, o in ipairs(self.boxes) do
		if o[1] < b[4] - EPS and o[4] > b[1] + EPS and o[2] < b[5] - EPS and
				o[5] > b[2] + EPS and o[3] < b[6] - EPS and o[6] > b[3] + EPS and
				not on_skipped(self, o) then
			return true
		end
	end
	local r, h = (b[4] - b[1]) / 2, b[5] - b[2]
	for _, o in ipairs(self.turned) do
		local lx, ly, lz = into(o, (b[1] + b[4]) / 2 - o.x, b[2] - o.y,
				(b[3] + b[6]) / 2 - o.z)
		for _, f in ipairs(o ~= self.skip and o.b or {}) do
			local x0, y0, z0, x1, y1, z1 = grown(f, r, h)
			if lx > x0 and lx < x1 and ly > y0 and ly < y1 and lz > z0 and lz < z1 then
				return true
			end
		end
	end
	return false
end

-- [KIT_MOVING_OBJECTS] A moving object has come over a body not on it (its pose
-- changes between steps, and a sweep starts from one it is in as no wall): the feet
-- out by its nearest side, a top's up, as far as a step's change can be and not into
-- the world's; a body on its top is so caught as it lands.
-- simplified: PUSH_MOST a step, so an object faster than 30 m/s at its surface goes
-- past. A sweep from the last pose is the upgrade
local PUSH_MOST = 0.5
function W:pushed(pos, b)
	for _, o in ipairs(self.turned) do
		local lx, ly, lz = into(o, pos[1] - o.x, pos[2] - o.y, pos[3] - o.z)
		local reach = o.rad + 2 * b.r + b.h
		if o.links and lx * lx + ly * ly + lz * lz <= reach * reach then
			for _, f in ipairs(o.b) do
				local x0, y0, z0, x1, y1, z1 = grown(f, b.r, b.h)
				if lx > x0 and lx < x1 and ly > y0 and ly < y1 and lz > z0 and lz < z1 then
					local best, ax, q = lx - x0, 1, -1
					if x1 - lx < best then best, ax, q = x1 - lx, 1, 1 end
					if ly - y0 < best then best, ax, q = ly - y0, 2, -1 end
					if y1 - ly < best then best, ax, q = y1 - ly, 2, 1 end
					if lz - z0 < best then best, ax, q = lz - z0, 3, -1 end
					if z1 - lz < best then best, ax, q = z1 - lz, 3, 1 end
					if best <= PUSH_MOST then
						local e = q * (best + 2 * EPS)
						local dx, dy, dz = outof(o, ax == 1 and e or 0, ax == 2 and e or 0,
								ax == 3 and e or 0)
						self.skip = o
						local free = not self:blocked(box_of(pos[1] + dx, pos[2] + dy,
								pos[3] + dz, b.r, b.h), true)
						self.skip = nil
						if free then
							pos[1], pos[2], pos[3] = pos[1] + dx, pos[2] + dy, pos[3] + dz
							lx, ly, lz = into(o, pos[1] - o.x, pos[2] - o.y, pos[3] - o.z)
						end
					end
				end
			end
		end
	end
end

-- A body buried by an edit (voxels or the heightmap raised into it):
-- lifted to the lowest free place over it, up to its height and a cell,
-- never sideways. pos the body's bottom middle, changed; true: lifted
function W:unbury(pos, b)
	local x, y, z = pos[1], pos[2], pos[3]
	local g = self:ground_max(x - b.r, z - b.r, x + b.r, z + b.r)
	local cand = y
	if g and g > y + EPS then
		cand = g
	end
	local top = y + b.h + 1
	while cand <= top do
		if not self:blocked(box_of(x, cand, z, b.r, b.h)) then
			if cand == y then
				return false
			end
			pos[2] = cand
			return true
		end
		-- The next half cell over the bottom ([KIT_SLAB_WALK]: a slab's
		-- top, a cell's)
		cand = (floor(cand * 2 + EPS) + 1) / 2
	end
	return false
end

-- x and z, each as far as it goes; then the heightmap's ground under the
-- new footprint: climbed where its slope is within b.slope, else the move
-- back
function W:slide(b, dx, dz)
	local bx = box_of(b.x, b.y, b.z, b.r, b.h)
	local mx, hx = self:sweep(bx, 1, dx)
	bx[1], bx[4] = bx[1] + mx, bx[4] + mx
	local mz, hz = self:sweep(bx, 3, dz)
	local x, z, y = b.x + mx, b.z + mz, b.y
	local g = self:ground_max(x - b.r, z - b.r, x + b.r, z + b.r)
	if g and g > y then
		local dist = sqrt(mx * mx + mz * mz)
		-- Climbed from where it is, or the ground under it before
		local g0 = self:ground_max(b.x - b.r, b.z - b.r, b.x + b.r, b.z + b.r)
		if g - (g0 and g0 > y and g0 or y) <= dist * (b.slope or 1) + 0.02 and
				not self:blocked(box_of(x, g, z, b.r, b.h)) then
			y = g
		else
			return b.x, b.y, b.z, 0, 0, dx ~= 0 and 1 or nil, dz ~= 0 and 1 or nil
		end
	end
	return x, y, z, mx, mz, hx, hz
end

function W:move(b, dx, dy, dz, step)
	local hits = {x = 0, y = 0, z = 0}
	local bb = box_of(b.x, b.y, b.z, b.r, b.h)
	local my, hy = self:sweep(bb, 2, dy)
	if hy then
		hits.y = dy < 0 and -1 or 1
		hits.y_info = hy
	end
	local sx, sy, sz = 0, 0, 0
	if my ~= 0 then
		sx, sy, sz = self:shed(b.x, b.y + my, b.z, b.r, b.h, my)
	end
	local s = {x = b.x + sx, y = b.y + my + sy, z = b.z + sz, r = b.r, h = b.h,
		slope = b.slope}
	local x, y, z, mx, mz, hx, hz = self:slide(s, dx, dz)
	-- Up a step where blocked: lifted, slid, put down again; taken if it
	-- went further
	if (hx or hz) and step and step > 0 then
		local up = self:sweep(box_of(s.x, s.y, s.z, b.r, b.h), 2, step)
		if up > EPS then
			local s2 = {x = s.x, y = s.y + up, z = s.z, r = b.r, h = b.h,
				slope = b.slope}
			local x2, y2, z2, mx2, mz2, hx2, hz2 = self:slide(s2, dx, dz)
			local down = self:sweep(box_of(x2, y2, z2, b.r, b.h), 2, -up - EPS)
			-- ([KIT_WALKER_FRAME] past a side leaning away it would be coming down
			-- inside the object)
			if mx2 * mx2 + mz2 * mz2 > mx * mx + mz * mz + 1e-8 and
					not self:blocked(box_of(x2, y2 + down, z2, b.r, b.h)) then
				x, y, z, mx, mz, hx, hz = x2, y2 + down, z2, mx2, mz2, hx2, hz2
			end
		end
	end
	if hx then
		hits.x = dx < 0 and -1 or 1
	end
	if hz then
		hits.z = dz < 0 and -1 or 1
	end
	return x - b.x, y - b.y, z - b.z, hits
end

-- A ray into a free object's frame: the nearest of its boxes, t and the axis it
-- came in by (nil: inside)
function ray_turned(ob, ox, oy, oz, dx, dy, dz, len)
	local lo = {into(ob, ox - ob.x, oy - ob.y, oz - ob.z)}
	local lv = {into(ob, dx, dy, dz)}
	local best, ba = nil, nil
	for _, f in ipairs(ob.b) do
		local t0, t1, na = 0, len, nil
		for k = 1, 3 do
			if abs(lv[k]) < 1e-9 then
				if lo[k] < f[k] or lo[k] > f[k + 3] then
					t0 = math.huge
				end
			else
				local a1, a2 = (f[k] - lo[k]) / lv[k], (f[k + 3] - lo[k]) / lv[k]
				if a1 > a2 then
					a1, a2 = a2, a1
				end
				if a1 > t0 then
					t0, na = a1, k
				end
				if a2 < t1 then
					t1 = a2
				end
			end
		end
		if t0 <= t1 and (not best or t0 < best) then
			best, ba = t0, na
		end
	end
	return best, ba
end

-- [KIT_AIRSHIPS] A ray at the free objects alone: t, the object, the cell hit in
-- its frame ({i, j, k}, a cell's middle its whole coordinates), the normal out of
-- that face and the ray's direction, both in its frame
function W:ray_objects(ox, oy, oz, dx, dy, dz, len)
	local l = sqrt(dx * dx + dy * dy + dz * dz)
	if l < 1e-9 then
		return nil
	end
	dx, dy, dz = dx / l, dy / l, dz / l
	local best, bo, ba
	for _, ob in ipairs(self.turned) do
		local t0, na = ray_turned(ob, ox, oy, oz, dx, dy, dz, len)
		if t0 and na and (not best or t0 < best) then
			best, bo, ba = t0, ob, na
		end
	end
	if not best then
		return nil
	end
	local lo = {into(bo, ox - bo.x, oy - bo.y, oz - bo.z)}
	local lv = {into(bo, dx, dy, dz)}
	local n = {0, 0, 0}
	n[ba] = lv[ba] > 0 and -1 or 1
	local cell = {}
	for k = 1, 3 do
		cell[k] = floor(lo[k] + lv[k] * best - n[k] * 0.5 + 0.5)
	end
	return best, bo, cell, n, lv
end

-- A ray: the first solid cell (Amanatides and Woo), object box or ground
-- along it within len: t, info, the normal
function W:ray(ox, oy, oz, dx, dy, dz, len)
	local l = sqrt(dx * dx + dy * dy + dz * dz)
	if l < 1e-9 then
		return nil
	end
	dx, dy, dz = dx / l, dy / l, dz / l
	local o, v = {ox, oy, oz}, {dx, dy, dz}
	local best, bi, bn = nil, nil, nil
	local c, st, tmax, td = {}, {}, {}, {}
	for k = 1, 3 do
		local p = o[k] + 0.5
		c[k] = floor(p)
		if v[k] > 1e-9 then
			st[k], tmax[k], td[k] = 1, (c[k] + 1 - p) / v[k], 1 / v[k]
		elseif v[k] < -1e-9 then
			st[k], tmax[k], td[k] = -1, (p - c[k]) / -v[k], -1 / v[k]
		else
			st[k], tmax[k], td[k] = 0, math.huge, math.huge
		end
	end
	local t, axis = 0, nil
	for _ = 1, 1024 do
		if t > len then
			break
		end
		local info = self:cell(c[1], c[2], c[3])
		if info and info.boxes then
			-- A shape: its boxes, the nearest hit (else on through it)
			for _, b in ipairs(cell_boxes(info, c[1], c[2], c[3])) do
				local t0, t1, na = 0, len, nil
				for q = 1, 3 do
					if abs(v[q]) < 1e-9 then
						if o[q] < b[q] or o[q] > b[q + 3] then
							t0 = math.huge
						end
					else
						local a1, a2 = (b[q] - o[q]) / v[q], (b[q + 3] - o[q]) / v[q]
						if a1 > a2 then
							a1, a2 = a2, a1
						end
						if a1 > t0 then
							t0, na = a1, q
						end
						if a2 < t1 then
							t1 = a2
						end
					end
				end
				if t0 <= t1 and (not best or t0 < best) then
					local n = {0, 0, 0}
					if na then
						n[na] = v[na] > 0 and -1 or 1
					end
					best, bi, bn = t0, info, n
				end
			end
			if best then
				break
			end
		elseif info then
			local n = {0, 0, 0}
			if axis then
				n[axis] = -st[axis]
			end
			best, bi, bn = t, info, n
			break
		end
		local k = 1
		if tmax[2] < tmax[k] then k = 2 end
		if tmax[3] < tmax[k] then k = 3 end
		t, axis = tmax[k], k
		c[k] = c[k] + st[k]
		tmax[k] = tmax[k] + td[k]
	end
	for _, b in ipairs(self.boxes) do
		local t0, t1, na = 0, len, nil
		for k = 1, 3 do
			if abs(v[k]) < 1e-9 then
				if o[k] < b[k] or o[k] > b[k + 3] then
					t0 = math.huge
				end
			else
				local a1, a2 = (b[k] - o[k]) / v[k], (b[k + 3] - o[k]) / v[k]
				if a1 > a2 then
					a1, a2 = a2, a1
				end
				if a1 > t0 then
					t0, na = a1, k
				end
				if a2 < t1 then
					t1 = a2
				end
			end
		end
		if t0 <= t1 and (not best or t0 < best) then
			local n = {0, 0, 0}
			if na then
				n[na] = v[na] > 0 and -1 or 1
			end
			best, bi, bn = t0, b.info or M.OBJECT, n
		end
	end
	for _, ob in ipairs(self.turned) do
		local t0, na = ray_turned(ob, ox, oy, oz, dx, dy, dz, len)
		if t0 and (not best or t0 < best) then
			local n = {0, 0, 0}
			if na then
				local lv = {into(ob, dx, dy, dz)}
				local q = lv[na] > 0 and -1 or 1
				n = {outof(ob, na == 1 and q or 0, na == 2 and q or 0,
						na == 3 and q or 0)}
			end
			best, bi, bn = t0, M.OBJECT, n
		end
	end
	if self.ground_fn then
		local stp, prev = 0.25, 0
		local lim = best or len
		local tt = 0
		while tt <= lim do
			local h = self.ground_fn(ox + dx * tt, oz + dz * tt)
			if h and oy + dy * tt < h then
				-- Bisected between the last point above and this one
				local a, b2 = prev, tt
				for _ = 1, 12 do
					local m = (a + b2) / 2
					local hm = self.ground_fn(ox + dx * m, oz + dz * m)
					if hm and oy + dy * m < hm then
						b2 = m
					else
						a = m
					end
				end
				best, bi, bn = b2, M.GROUND, {0, 1, 0}
				break
			end
			prev = tt
			tt = tt + stp
		end
	end
	if not best then
		return nil
	end
	return best, bi, bn[1], bn[2], bn[3]
end

-- How far down from x, y, z the first solid is (within len): the
-- distance and its info, or nil
function W:down(x, y, z, len)
	local i, k = floor(x + 0.5), floor(z + 0.5)
	local best, info = nil, nil
	local j = floor(y + 0.5)
	local top = j
	while top + 0.5 > y - len - 1 do
		local c = self:cell(i, top, k)
		local ctop = top + 0.5
		if c and c.boxes then
			-- A shape: the highest of its boxes under the point (none: on
			-- down through the cell)
			local hi = nil
			for _, o in ipairs(cell_boxes(c, i, top, k)) do
				if x >= o[1] and x <= o[4] and z >= o[3] and z <= o[6] and
						o[2] <= y + EPS and (not hi or o[5] > hi) then
					hi = o[5]
				end
			end
			if hi then
				ctop = hi
			else
				c = nil
			end
		end
		if c then
			-- Inside it: the top of the cell above it... a wall, 0
			local d = y - ctop
			if d < 0 then
				d = 0
			end
			if d <= len then
				best, info = d, c
			end
			break
		end
		top = top - 1
	end
	for _, b in ipairs(self.boxes) do
		if x >= b[1] and x <= b[4] and z >= b[3] and z <= b[6] and
				b[2] <= y then
			local d = y - b[5]
			if d < 0 then
				d = 0
			end
			if d <= len and (not best or d < best) then
				best, info = d, b.info or M.OBJECT
			end
		end
	end
	for _, o in ipairs(self.turned) do
		local d = ray_turned(o, x, y, z, 0, -1, 0, len)
		if d and (not best or d < best) then
			best, info = d, M.OBJECT
		end
	end
	local h = self:height(x, z)
	if h then
		local d = y - h
		if d < 0 then
			d = 0
		end
		if d <= len and (not best or d < best) then
			best, info = d, M.GROUND
		end
	end
	return best, info
end

function W:under(x, y, z)
	local _, info = self:down(x, y, z, 0.6)
	return info
end

-- What touches the body (b = {x, y, z, r, h}): each side's within 0.05
function W:contacts(b)
	local out = {}
	local bb = box_of(b.x, b.y, b.z, b.r, b.h)
	for a = 1, 3 do
		for _, sgn in ipairs({-1, 1}) do
			local d, info = self:sweep(bb, a, sgn * 0.05)
			if info then
				local n = {0, 0, 0}
				n[a] = -sgn
				out[#out + 1] = {info, n[1], n[2], n[3], dist = abs(d)}
			end
		end
	end
	return out
end

-- ---- A character: kit/walker's and kit/click_to_move's step. s the
-- state (s.pos, s.vel; s.ground, s.friction and s.surface of what it
-- stands on, s.coyote, s.buffer, s.held, s.jumps: the jumps counted), b
-- the body {r, h}, wx, wz the wished velocity (m/s), jump the button
-- (held: it jumps again on landing), p the parameters: acceleration,
-- gravity, jump_height (0: no jump), air_control, coyote_time,
-- jump_buffer, step_height, slope_limit (degrees)
local function num(v, d)
	return type(v) == "number" and v or d
end

-- Toward a wish on the plane: at most acc this step
local function toward(v, wx, wz, acc)
	local dx, dz = wx - v[1], wz - v[3]
	local l = sqrt(dx * dx + dz * dz)
	if l > acc and l > 0 then
		dx, dz = dx * acc / l, dz * acc / l
	end
	v[1], v[3] = v[1] + dx, v[3] + dz
end

-- A jump pressed up to jump_buffer before the ground, taken up to coyote_time
-- after it: true when it is taken now, its speed up left to the caller
local function jump_taken(s, ground, jump, dt, p)
	if ground then
		s.coyote = num(p.coyote_time, 0.1)
	end
	if jump and (not s.held or ground) then
		s.buffer = num(p.jump_buffer, 0.12)
	end
	s.held = jump and true or false
	local taken = false
	if num(p.jump_height, 1.6) > 0 and num(s.buffer, 0) > 0 and
			num(s.coyote, 0) > 0 then
		s.buffer, s.coyote = 0, 0
		s.jumps = num(s.jumps, 0) + 1
		ground, taken = false, true
	end
	s.buffer = num(s.buffer, 0) - dt
	if s.buffer < 0 then s.buffer = 0 end
	if not ground then
		s.coyote = num(s.coyote, 0) - dt
		if s.coyote < 0 then s.coyote = 0 end
	end
	return taken
end

-- [KIT_WALKER_FRAME] An object's frame as a world: its boxes the flat voxels. The
-- rest of the world (the cells, looks, heightmap, other objects) has its say on
-- each move: the body upright at its feet there, swept along the move in the
-- world; the deck's own frame goes no further. A floor it reaches is remembered
-- (W:walk_on leaves for it).
local function frame_sweep(f, b, a, d)
	local got, hit = W.sweep(f, b, a, d)
	if got == 0 then
		return 0, hit
	end
	local w, o = f.outer, f.o
	local x, y, z = outof(o, (b[1] + b[4]) / 2, b[2], (b[3] + b[6]) / 2)
	local wb = box_of(x + o.x, y + o.y, z + o.z, (b[4] - b[1]) / 2, b[5] - b[2])
	local m = {outof(o, a == 1 and got or 0, a == 2 and got or 0,
			a == 3 and got or 0)}
	local t = 1
	w.skip = o
	for q = 1, 3 do
		if abs(m[q]) > 1e-9 then
			local g, info = w:sweep(wb, q, m[q])
			if info and g / m[q] < t then
				t, hit = g / m[q], info
			end
			if info and q == 2 and m[2] < 0 then
				f.floor = true
			end
		end
	end
	w.skip = nil
	return got * t, hit
end

function W:frame_world(o)
	self.frames = self.frames or {}
	local f = self.frames[o]
	if not f then
		f = M.world{cell = function() return nil end, boxes = o.b}
		f.cell, f.sweep, f.outer, f.o = f.cell_fn, frame_sweep, self, o
		self.frames[o] = f
	end
	f.floor = false
	return f
end

-- The frame left: the body's velocity the world's. simplified: nothing carries a
-- walker up off a high edge (its velocity up dropped: a deck is no ramp to launch
-- from). [KIT_MOVING_OBJECTS] A moving deck's velocity at the feet added: what it
-- leaves with in the world, kept through the air (s.carry, W:walk) until it lands
local function leave_frame(w, s, o)
	local v = s.vel
	local x, y, z = outof(o, v[1], v[2], v[3])
	local dx, dy, dz = w:deck_velocity(o, s.pos[1], s.pos[2], s.pos[3])
	s.vel = {x + dx, (y > 0 and 0 or y) + dy, z + dz}
	s.frame, s.at = nil, nil
	s.carry = o.links and {dx, dz} or nil
end

-- A step in the frame of o: true; false: it jumped, out of the frame, and the
-- world's step goes on with it
function W:walk_on(o, s, b, wx, wz, jump, dt, p)
	local f = self:frame_world(o)
	if type(s.at) ~= "table" then
		s.at = {into(o, s.pos[1] - o.x, s.pos[2] - o.y, s.pos[3] - o.z)}
	end
	local at, v = s.at, s.vel
	if f:unbury(at, b) and v[2] < 0 then
		v[2] = 0
	end
	-- [KIT_MOVING_OBJECTS] Carried into the world (a deck rolled into the ground, a
	-- course through a wall): off it, the world's step goes on from there, out by
	-- unbury. simplified: carrying is no sweep, so a fast deck can take a body
	-- through a thin wall; a sweep of the feet from the last pose is the upgrade
	if o.links then
		local x, y, z = outof(o, at[1], at[2], at[3])
		x, y, z = x + o.x, y + o.y, z + o.z
		self.skip = o
		local in_world = self:blocked(box_of(x, y, z, b.r, b.h), true)
		self.skip = nil
		if in_world then
			s.pos[1], s.pos[2], s.pos[3] = x, y, z
			leave_frame(self, s, o)
			s.ground = false
			return false
		end
	end
	local g = num(p.gravity, 15)
	-- The world's up in the frame
	local R = o.R
	local ux, uy, uz = R[4], R[5], R[6]
	local flat = uy >= M.cos(num(p.slope_limit, 45) * PI / 180)
	local ground = s.ground == true
	-- The wish: what goes that way in the world, level, along the deck, at its
	-- speed (straight down the world's up onto the deck)
	local sp = sqrt(wx * wx + wz * wz)
	local lx, ly, lz = into(o, wx, 0, wz)
	local lift = uy > 1e-3 and -ly / uy or 0
	lx, lz = lx + lift * ux, lz + lift * uz
	local l = sqrt(lx * lx + lz * lz)
	if l > 1e-9 then
		lx, lz = lx * sp / l, lz * sp / l
	end
	local acc = num(p.acceleration, 40) * dt
	if flat then
		toward(v, lx, lz, acc * (ground and num(s.friction, 1) or
				num(p.air_control, 0.6)))
	else
		-- Past the limit: gravity along the deck; no walking up it, sideways as
		-- in the air
		local tx, tz = -g * ux, -g * uz
		v[1], v[3] = v[1] + tx * dt, v[3] + tz * dt
		local tl = sqrt(tx * tx + tz * tz)
		if tl > 0 then
			local sx, sz = -tz / tl, tx / tl
			local want = lx * sx + lz * sz - v[1] * sx - v[3] * sz
			local most = acc * num(p.air_control, 0.6)
			want = want > most and most or want < -most and -most or want
			v[1], v[3] = v[1] + sx * want, v[3] + sz * want
		end
		ground = false
	end
	if jump_taken(s, ground, jump, dt, p) then
		local x, y, z = outof(o, at[1], at[2], at[3])
		s.pos[1], s.pos[2], s.pos[3] = x + o.x, y + o.y, z + o.z
		leave_frame(self, s, o)
		s.vel[2] = s.vel[2] + sqrt(2 * g * num(p.jump_height, 1.6))
		s.ground = false
		return false
	end
	v[2] = v[2] - g * uy * dt
	local speed = sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
	if speed > 60 then
		v[1], v[2], v[3] = v[1] * 60 / speed, v[2] * 60 / speed, v[3] * 60 / speed
	end
	local body = {x = at[1], y = at[2], z = at[3], r = b.r, h = b.h}
	local mx, my, mz, hits = f:move(body, v[1] * dt, v[2] * dt, v[3] * dt,
			ground and num(p.step_height, 0.6) or 0)
	at[1], at[2], at[3] = at[1] + mx, at[2] + my, at[3] + mz
	if hits.x ~= 0 then v[1] = 0 end
	if hits.z ~= 0 then v[3] = 0 end
	local on = nil
	if hits.y ~= 0 then
		v[2] = 0
		if hits.y < 0 then
			on = hits.y_info
		end
	end
	if not on then
		local d, info = f:sweep(box_of(at[1], at[2], at[3], b.r, b.h), 2,
				-num(p.step_height, 0.6))
		if info then
			at[2] = at[2] + d
			v[2] = 0
			on = info
		end
	end
	local x, y, z = outof(o, at[1], at[2], at[3])
	s.pos[1], s.pos[2], s.pos[3] = x + o.x, y + o.y, z + o.z
	-- The world's floor under the feet, or nothing: the world's again
	local floor = false
	if f.floor then
		self.skip = o
		local _, info = self:sweep(box_of(s.pos[1], s.pos[2], s.pos[3], b.r, b.h),
				2, -0.02)
		self.skip = nil
		floor = info ~= nil
	end
	if not on or floor then
		leave_frame(self, s, o)
		s.ground, s.friction, s.surface = false, nil, nil
		return true
	end
	s.ground = flat
	s.friction = flat and on.friction or nil
	s.surface = on.surface
	return true
end

-- [KIT_AUTO_JUMP] auto (the input's): up a one-voxel step without Jump
M.AUTOJUMP_HEIGHT = 1.1
M.AUTOJUMP_S = 0.1
function W:walk(s, b, wx, wz, jump, dt, p, auto)
	if type(s.pos) ~= "table" then
		s.pos = {0, 0, 0}
	end
	if type(s.vel) ~= "table" then
		s.vel = {0, 0, 0}
	end
	-- [KIT_WALKER_FRAME] On an object: in its frame. Its object gone (taken away
	-- in an edit): the world's, where it stood
	if s.frame then
		local o = nil
		for _, t in ipairs(self.turned) do
			if t.id == s.frame then
				o = t
			end
		end
		-- A knock from the server (kit.cpp's knock()): out, its speed the world's
		local push = s.push
		s.push = nil
		if o and type(push) == "table" then
			leave_frame(self, s, o)
			for k = 1, 3 do
				s.vel[k] = s.vel[k] + (tonumber(push[k]) or 0)
			end
			s.ground = false
		elseif o and self:walk_on(o, s, b, wx, wz, jump, dt, p) then
			return s
		elseif not o then
			s.frame, s.at = nil, nil
		end
	end
	local pos, v = s.pos, s.vel
	if self.moving then
		self:pushed(pos, b)
	end
	if self:unbury(pos, b) and v[2] < 0 then
		v[2] = 0
	end
	local g = num(p.gravity, 15)
	local jh = num(p.jump_height, 1.6)
	local ground = s.ground == true
	-- Toward the wished velocity: on the ground as its friction lets, in
	-- the air as air_control does ([KIT_MOVING_OBJECTS] over what a moving deck
	-- gave it, so that a jump keeps up with the deck)
	local carry = not ground and type(s.carry) == "table" and s.carry or nil
	-- [KIT_AUTO_JUMP] the jump auto jump chose, held a moment
	if num(s.auto_t, 0) > 0 then
		s.auto_t = s.auto_t - dt
		jump = true
	end
	toward(v, wx + (carry and num(carry[1], 0) or 0), wz + (carry and num(carry[2], 0) or 0),
			num(p.acceleration, 40) * dt * (ground and num(s.friction, 1)
			or num(p.air_control, 0.6)))
	local jumped = jump_taken(s, ground, jump, dt, p)
	if jumped then
		v[2] = sqrt(2 * g * jh)
		ground = false
	end
	v[2] = v[2] - g * dt
	if v[2] < -60 then v[2] = -60 end
	local vy = v[2]
	local lim = num(p.slope_limit, 45) * PI / 180
	local body = {x = pos[1], y = pos[2], z = pos[3], r = b.r, h = b.h,
		slope = M.sin(lim) / M.cos(lim)}
	local mx, my, mz, hits = self:move(body, v[1] * dt, v[2] * dt, v[3] * dt,
			ground and num(p.step_height, 0.6) or 0)
	-- [KIT_AUTO_JUMP] Walking on the ground into what the step does not take:
	-- a jump when the same move from AUTOJUMP_HEIGHT up (room over the head)
	-- gets further (Luanti's LocalPlayer::handleAutojump), held AUTOJUMP_S
	if auto and ground and not jump and not jumped and (hits.x ~= 0 or
			hits.z ~= 0) and (wx ~= 0 or wz ~= 0) then
		local up = self:sweep(box_of(body.x, body.y, body.z, b.r, b.h), 2,
				M.AUTOJUMP_HEIGHT)
		if up >= M.AUTOJUMP_HEIGHT - EPS then
			local _, _, _, jx, jz = self:slide({x = body.x, y = body.y + up,
				z = body.z, r = b.r, h = b.h, slope = body.slope}, v[1] * dt,
				v[3] * dt)
			if jx * jx + jz * jz > (mx * mx + mz * mz) * 1.01 + 1e-12 then
				s.auto_t = M.AUTOJUMP_S
			end
		end
	end
	pos[1], pos[2], pos[3] = pos[1] + mx, pos[2] + my, pos[3] + mz
	if hits.x ~= 0 then v[1] = 0 end
	if hits.z ~= 0 then v[3] = 0 end
	local on = nil
	if hits.y ~= 0 then
		v[2] = 0
		if hits.y < 0 then
			on = hits.y_info
		end
	end
	-- Off an edge walking: down a step, not into the air
	if not on and ground and not jumped then
		local d, info = self:sweep(box_of(pos[1], pos[2], pos[3], b.r, b.h), 2,
				-num(p.step_height, 0.6))
		if info then
			pos[2] = pos[2] + d
			v[2] = 0
			on = info
		end
	end
	-- The heightmap's ground climbed: on it
	if not on and my >= 0 and self.ground_fn then
		local gm = self:ground_max(pos[1] - b.r, pos[3] - b.r, pos[1] + b.r,
				pos[3] + b.r)
		if gm and gm >= pos[2] - EPS and v[2] <= 0 then
			on = M.GROUND
			v[2] = 0
		end
	end
	-- [KIT_SURVIVAL_TUNING] a landing's speed (the fastest of the steps since
	-- the server last took it: kit.cpp's fall_hurt)
	if on and not ground and -vy > num(s.impact, 0) then
		s.impact = -vy
	end
	s.ground = on ~= nil
	s.friction = on and on.friction or nil
	s.surface = on and on.surface or nil
	if on then
		s.carry = nil
	end
	-- [KIT_WALKER_FRAME] On an object's top: into its frame, what it landed with
	-- going along the deck (past [KIT_MOVING_OBJECTS] a moving deck's own velocity).
	-- simplified: a top only; an object turned over stands a
	-- body on its other faces in the world's frame, which holds it where it hit;
	-- choosing the face nearest the world's up as the frame's floor is the upgrade
	local o = on and on.frame
	if o and o.R[5] > 0.02 then
		s.frame = o.id
		s.at = {into(o, pos[1] - o.x, pos[2] - o.y, pos[3] - o.z)}
		local dx, dy, dz = self:deck_velocity(o, pos[1], pos[2], pos[3])
		s.vel = {into(o, v[1] - dx, v[2] - dy, v[3] - dz)}
		s.vel[2] = 0
		s.ground = o.R[5] >= M.cos(lim)
		s.friction = s.ground and 1 or nil
	end
	return s
end

-- ---- Heights: builtin/heightmap's height_at() over its samples
-- (sample(ix, iz) -> the height there, nil past the map), the same
-- triangles
function M.height(sample, x, z)
	local ix, iz = floor(x), floor(z)
	local xf, zf = x - ix, z - iz
	local h1, h2, h3
	if xf + zf >= 1 then
		h1, h2, h3 = sample(ix + 1, iz + 1), sample(ix, iz + 1),
				sample(ix + 1, iz)
		xf, zf = 1 - xf, 1 - zf
	else
		h1, h2, h3 = sample(ix, iz), sample(ix + 1, iz), sample(ix, iz + 1)
	end
	if not h1 or not h2 or not h3 then
		return nil
	end
	return h1 * (1 - xf - zf) + h2 * xf + h3 * zf
end

-- ---- The server's world: what kit.cpp sends a step (a box of cells round
-- the body, a char each, x fastest, then z, then y: "." air, "?" not
-- loaded, "A"... its classes {name, solid, friction, surface, boxes (a
-- shape's, [KIT_VOXEL_FORMAT]; a class a facing)}; the solid
-- looks near {look, on, {x, y, z}, yaw[, pitch, roll]}; a heightmap's samples
-- round it)
function M.snapshot(t)
	-- [KIT_VEHICLE_MOVEMENTS] the steered ones' keys
	M.tracks = type(t.tracks) == "table" and t.tracks or {}
	local classes = {}
	for i, c in ipairs(t.classes or {}) do
		classes[i] = M.voxel_info(c[1], c[2], c[3], c[4], c[5])
	end
	local cells, x0, y0, z0 = t.cells or "", t.x0 or 0, t.y0 or 0, t.z0 or 0
	local nx, ny, nz = t.nx or 0, t.ny or 0, t.nz or 0
	local function cell(i, j, k)
		local a, b, c = i - x0, j - y0, k - z0
		if a < 0 or b < 0 or c < 0 or a >= nx or b >= ny or c >= nz then
			return nil
		end
		local ch = cells:byte(1 + a + nx * (c + nz * b))
		if ch == 63 then
			return M.UNKNOWN
		elseif not ch or ch < 65 then
			return nil
		end
		return classes[ch - 64]
	end
	local boxes, moving_looks = {}, nil
	for _, l in ipairs(t.looks or {}) do
		-- [KIT_MOVING_OBJECTS] on a moving object: placed as each step's time has it
		if l[7] then
			moving_looks = moving_looks or {}
			l[2] = l[2] == true
			moving_looks[#moving_looks + 1] = l
		else
			local b = M.look_box(l[1], l[2] == true, l[3], l[4], l[5], l[6])
			if b then
				boxes[#boxes + 1] = b
			end
		end
	end
	local ground = nil
	local hm = t.hm
	if type(hm) == "table" then
		local function sample(ix, iz)
			local a, c = ix - hm.x0, iz - hm.z0
			if a < 0 or c < 0 or a >= hm.nx or c >= hm.nz then
				return nil
			end
			return hm.h[1 + a + hm.nx * c]
		end
		ground = function(x, z)
			return M.height(sample, x, z)
		end
	end
	-- [KIT_HM_ORIGIN] the map from its origin's world cell
	local edge = type(hm) == "table" and hm.sx and {hm.ox or 0, hm.oz or 0,
			(hm.ox or 0) + hm.sx - 1, (hm.oz or 0) + hm.sz - 1} or nil
	return M.world{cell = cell, boxes = boxes, ground = ground, edge = edge,
		turned = M.turned(t.turned or {}), moving_looks = moving_looks, t = t.t}
end

-- The steps of a batch: each input dt long, in sub steps of its own
-- ([KIT_MOVING_OBJECTS] the world's moving objects as each has them: i.t its stamp, ms)
function M.steps(def, s, inputs, dt, sub, w, p)
	sub = sub or 1
	for _, i in ipairs(inputs) do
		for n = 1, sub do
			if w.moving and i.t then
				w:pose_at(i.t / 1000 + (n - 1) * dt / sub)
			end
			def.step(s, i, dt / sub, w, p)
		end
	end
	return s
end

return M
-- vim: set noet ts=4 sw=4:
