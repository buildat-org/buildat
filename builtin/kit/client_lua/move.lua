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
--     camera = "first_person"|"chase" (a vehicle's), touch = "stick"|
--     "tap"|"drive"}
--   step = function(s, i, dt, w, p) ... end
-- s its state (s.pos the body's bottom middle {x, y, z}, s.vel; the rest
-- its own), changed in place; i this step's input: f (forward, -1...1),
-- r (right), yaw (the camera's, degrees from +z toward +x), jump (0/1),
-- go (0/1: a target), tx, ty, tz (where to go); dt seconds; p its
-- parameters; w the world:
--   w:cell(i, j, k) -> info or nil (air): the voxel centred on i, j, k
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
-- ("ground") or a cell not loaded ("unknown", solid).
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
-- and the entity's yaw, as the box round it {x0, y0, z0, x1, y1, z1};
-- nil when it is not solid
local function rotation(rx, ry, rz)
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

function M.look_box(look, on, pos, yaw)
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
		local hinge, front = off[1] - size[1] / 2, off[3] - size[3] / 2
		size[1], size[3] = size[3], size[1]
		off[1], off[3] = hinge + size[1] / 2, front + size[3] / 2
	end
	local r = type(look.rotation) == "table" and look.rotation or {}
	local R = rotation(tonumber(r[1]) or 0, (tonumber(r[2]) or 0) +
			(tonumber(yaw) or 0), tonumber(r[3]) or 0)
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

-- ---- The world: t.cell(i, j, k) -> info or nil, t.boxes ({x0, y0, z0,
-- x1, y1, z1, info = ...}...), t.ground(x, z) -> a heightmap's height
-- or nil
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
	w.ground_fn = t.ground
	w.cache = {}
	return w
end

function W:cell(i, j, k)
	-- A number (a string's making is dear in the box)
	local key = (i + 32768) + 65536 * ((j + 32768) + 65536 * (k + 32768))
	local v = self.cache[key]
	if v == nil then
		v = self.cell_fn(i, j, k) or false
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

local function lo_cell(a)
	return floor(a + EPS - 0.5) + 1
end
local function hi_cell(a)
	return -floor(-(a - EPS + 0.5)) - 1
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
	-- The shapes' boxes in the way, met with the objects' below
	local sub = nil
	for i = r0[1], r1[1] do
		for j = r0[2], r1[2] do
			for k = r0[3], r1[3] do
				local info = self:cell(i, j, k)
				if info and info.boxes then
					sub = sub or {}
					for _, o in ipairs(cell_boxes(info, i, j, k)) do
						sub[#sub + 1] = o
					end
				elseif info then
					local c = a == 1 and i or a == 2 and j or k
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

-- Whether the box is in anything solid
function W:blocked(b)
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
				elseif info then
					return true
				end
			end
		end
	end
	for _, o in ipairs(self.boxes) do
		if o[1] < b[4] - EPS and o[4] > b[1] + EPS and o[2] < b[5] - EPS and
				o[5] > b[2] + EPS and o[3] < b[6] - EPS and o[6] > b[3] + EPS then
			return true
		end
	end
	return false
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
		-- The next cell top over the bottom
		cand = floor(cand + 0.5 + EPS) + 0.5
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
	local s = {x = b.x, y = b.y + my, z = b.z, r = b.r, h = b.h, slope = b.slope}
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
			if mx2 * mx2 + mz2 * mz2 > mx * mx + mz * mz + 1e-8 then
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

function W:walk(s, b, wx, wz, jump, dt, p)
	if type(s.pos) ~= "table" then
		s.pos = {0, 0, 0}
	end
	if type(s.vel) ~= "table" then
		s.vel = {0, 0, 0}
	end
	local pos, v = s.pos, s.vel
	if self:unbury(pos, b) and v[2] < 0 then
		v[2] = 0
	end
	local g = num(p.gravity, 15)
	local jh = num(p.jump_height, 1.6)
	local ground = s.ground == true
	-- Toward the wished velocity: on the ground as its friction lets, in
	-- the air as air_control does
	local acc = num(p.acceleration, 40) * dt * (ground and num(s.friction, 1) or
			num(p.air_control, 0.6))
	local dx, dz = wx - v[1], wz - v[3]
	local l = sqrt(dx * dx + dz * dz)
	if l > acc and l > 0 then
		dx, dz = dx * acc / l, dz * acc / l
	end
	v[1], v[3] = v[1] + dx, v[3] + dz
	-- A jump: pressed up to jump_buffer before the ground, taken up to
	-- coyote_time after it
	if ground then
		s.coyote = num(p.coyote_time, 0.1)
	end
	if jump and (not s.held or ground) then
		s.buffer = num(p.jump_buffer, 0.12)
	end
	s.held = jump and true or false
	local jumped = false
	if jh > 0 and num(s.buffer, 0) > 0 and num(s.coyote, 0) > 0 then
		v[2] = sqrt(2 * g * jh)
		s.buffer, s.coyote = 0, 0
		s.jumps = num(s.jumps, 0) + 1
		ground, jumped = false, true
	end
	s.buffer = num(s.buffer, 0) - dt
	if s.buffer < 0 then s.buffer = 0 end
	if not ground then
		s.coyote = num(s.coyote, 0) - dt
		if s.coyote < 0 then s.coyote = 0 end
	end
	v[2] = v[2] - g * dt
	if v[2] < -60 then v[2] = -60 end
	local lim = num(p.slope_limit, 45) * PI / 180
	local body = {x = pos[1], y = pos[2], z = pos[3], r = b.r, h = b.h,
		slope = M.sin(lim) / M.cos(lim)}
	local mx, my, mz, hits = self:move(body, v[1] * dt, v[2] * dt, v[3] * dt,
			ground and num(p.step_height, 0.55) or 0)
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
				-num(p.step_height, 0.55))
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
	s.ground = on ~= nil
	s.friction = on and on.friction or nil
	s.surface = on and on.surface or nil
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
-- looks near {look, on, {x, y, z}, yaw}; a heightmap's samples round it)
function M.snapshot(t)
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
	local boxes = {}
	for _, l in ipairs(t.looks or {}) do
		local b = M.look_box(l[1], l[2] == true, l[3], l[4])
		if b then
			boxes[#boxes + 1] = b
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
	return M.world{cell = cell, boxes = boxes, ground = ground}
end

-- The steps of a batch: each input dt long, in sub steps of its own
function M.steps(def, s, inputs, dt, sub, w, p)
	sub = sub or 1
	for _, i in ipairs(inputs) do
		for _ = 1, sub do
			def.step(s, i, dt / sub, w, p)
		end
	end
	return s
end

return M
-- vim: set noet ts=4 sw=4:
