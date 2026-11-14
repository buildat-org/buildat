-- [KIT_PLANE] builtin/kit/client_lua/move.lua's plane and 2D queries, stepped as
-- the box steps them (its environment: the box's math only), in the plane z 0 over
-- a floor of cells (top 0.5), a ledge in the plane (x 5...20, top 1.5) and a wall
-- just off it (z 1, x 2): kit/walker held to the plane walks under the wall, does
-- not go across with W, jumps onto the ledge, the same bits twice; a step that
-- moves across is put back; w:circle and w:segment against the cells (a floor's
-- seams no wall), the off-plane wall (not met) and a heightmap's slope.
-- Run: lua util/kit_plane_check.lua (Lua 5.1 or LuaJIT), from the source tree's root.
local function load_env(path, env)
	local f = assert(loadfile(path))
	setfenv(f, env)
	return f()
end
local m = {floor = math.floor, ceil = math.ceil, sqrt = math.sqrt,
	fmod = math.fmod, abs = math.abs, min = math.min, max = math.max,
	huge = math.huge, pi = math.pi, random = math.random}
local MV = load_env("builtin/kit/client_lua/move.lua", {math = m,
	ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
	tonumber = tonumber, setmetatable = setmetatable})
local walker = load_env("builtin/kit/types/walker.lua", {math = m, ipairs = ipairs,
	pairs = pairs, type = type, tostring = tostring, tonumber = tonumber,
	table = table, string = string, error = error})
local wp = {}
for k, v in pairs(walker.params) do
	wp[k] = v.default
end
local function near(a, b, e)
	return math.abs(a - b) < (e or 1e-6)
end

local STONE = MV.voxel_info("kit/stone", true)
local function world(t)
	t = t or {}
	return MV.world{cell = function(i, j, k)
		if j <= 0 then
			return STONE
		end
		if k == 0 and j == 1 and i >= 5 and i <= 20 then
			return STONE
		end
		if k == 1 and i == 2 and j <= 3 then
			return STONE
		end
		return nil
	end, plane = t.plane == nil and 0 or t.plane or nil, ground = t.ground}
end
local function run(s, n, input, w)
	for _ = 1, n do
		MV.steps(walker, s, {input}, 1 / 60, 1, w, wp)
		assert(s.pos[3] == w.plane and s.vel[3] == 0, "off the plane: " .. s.pos[3])
	end
	return s
end

-- Settled on the floor, then W (forward, into the screen at yaw 0): not across
local w = world()
local s = run({pos = {0, 0.55, 0}}, 30, {f = 0, r = 0, yaw = 0, jump = 0}, w)
assert(near(s.pos[2], 0.5) and s.ground == true, s.pos[2])
run(s, 60, {f = 1, r = 0, yaw = 0, jump = 0}, w)
assert(near(s.pos[1], 0) and s.pos[3] == 0, s.pos[1] .. "," .. s.pos[3])
-- Right: under the wall one cell off the plane (x 2, z 1), up to the ledge's side
run(s, 60, {f = 0, r = 1, yaw = 0, jump = 0}, w)
assert(near(s.pos[1], 4.05, 1e-3) and near(s.pos[2], 0.5), s.pos[1] .. "," .. s.pos[2])
-- Jumping onto the ledge (its top 1.5)
run(s, 30, {f = 0, r = 1, yaw = 0, jump = 1}, w)
run(s, 60, {f = 0, r = 0, yaw = 0, jump = 0}, w)
assert(s.pos[1] > 5 and near(s.pos[2], 1.5, 1e-3) and s.ground, s.pos[1] .. "," .. s.pos[2])
-- Off the plane the wall stops the same walk
local w3 = world{plane = false}
local s3 = {pos = {0, 0.55, 1}}
for _ = 1, 120 do
	MV.steps(walker, s3, {{f = 0, r = 1, yaw = 0, jump = 0}}, 1 / 60, 1, w3, wp)
end
assert(near(s3.pos[1], 1.05, 1e-3), "the wall off the plane: " .. s3.pos[1])
-- The same inputs, the same bits (the client predicts as the box steps)
local function trace()
	local ww, ss, out = world(), {pos = {-3, 0.55, 0}}, {}
	for n = 1, 200 do
		local i = {f = n % 7 == 0 and 1 or 0, r = n < 150 and 1 or -1, yaw = 0,
			jump = (n > 40 and n < 60) and 1 or 0}
		MV.steps(walker, ss, {i}, 1 / 60, 1, ww, wp)
		out[#out + 1] = string.format("%.17g %.17g %.17g", ss.pos[1], ss.pos[2], ss.pos[3])
	end
	return table.concat(out, ";")
end
assert(trace() == trace(), "not the same bits")
-- A step of its own going across: back on the plane, its speed across gone
local drift = {step = function(st, i, dt)
	st.pos[3] = st.pos[3] + 3
	st.vel = {1, 0, 7}
end}
local s4 = {pos = {0, 0.5, 0}}
MV.steps(drift, s4, {{}}, 1 / 60, 1, w, {})
assert(s4.pos[3] == 0 and s4.vel[3] == 0 and s4.vel[1] == 1, "not held: " .. s4.pos[3])
print("ok: kit/walker in the plane: held at z 0, W goes nowhere, under a wall off the plane, onto a ledge; the same bits twice; a step going across held")

-- w:circle: on the floor, over a seam, sunk at a seam, at the ledge's side
local c = w:circle(3, 0.9, 0.5)
assert(#c == 1 and near(c[1].depth, 0.1) and c[1].nx == 0 and c[1].ny == 1, #c)
assert(c[1].info == STONE)
c = w:circle(3.5, 0.9, 0.5)
assert(#c == 1 and near(c[1].depth, 0.1) and c[1].ny == 1, "a seam: " .. #c)
c = w:circle(0.5, 0.45, 0.5)
assert(#c >= 1, "sunk at a seam: none")
for _, x in ipairs(c) do
	assert(x.nx == 0 and x.ny == 1, "a seam's side met: " .. x.nx .. "," .. x.ny)
end
assert(near(c[1].depth, 0.55), c[1].depth)
c = w:circle(4.2, 1.2, 0.5)
assert(#c == 1 and near(c[1].depth, 0.2) and c[1].nx == -1 and c[1].ny == 0, #c)
-- In the corner of the floor and the ledge: both, the deeper first
c = w:circle(4.1, 0.85, 0.45)
assert(#c == 2 and c[1].depth >= c[2].depth, #c)
-- The wall off the plane: nothing; in its own layer it is there
assert(#w:circle(2, 2, 0.4) == 0, "the wall off the plane met")
assert(#w:circle(2, 2, 0.4, 1) == 1, "the wall in its layer not met")
assert(#w:circle(3, 3, 0.5) == 0, "free air")
-- w:segment: down onto the floor, along into the ledge's side past the wall
local t, nx, ny, info = w:segment(0, 3, 0, -3)
assert(near(t, 2.5 / 6) and nx == 0 and ny == 1 and info == STONE, tostring(t))
t, nx, ny = w:segment(-2, 1, 10, 1)
assert(near(t, 6.5 / 12) and nx == -1 and ny == 0, tostring(t))
assert(w:segment(0, 3, 6, 3) == nil, "free air met")
-- A heightmap's slope (y = x / 2), no voxels
local hw = MV.world{cell = function() return nil end, plane = 0,
	ground = function(x) return x / 2 end}
c = hw:circle(2, 2, 1)
local d = 1 - 1 / math.sqrt(1.25)
assert(#c == 1 and near(c[1].depth, d) and near(c[1].nx, -1 / math.sqrt(5)) and
		near(c[1].ny, 2 / math.sqrt(5)) and c[1].info == MV.GROUND, #c)
c = hw:circle(2, 0.5, 0.25)
assert(#c == 1 and near(c[1].depth, 0.25 + 0.5 * 2 / math.sqrt(5)), "under the slope")
t, nx, ny, info = hw:segment(2, 5, 2, -5)
assert(near(t, 0.4) and near(nx, -1 / math.sqrt(5)) and near(ny, 2 / math.sqrt(5)) and
		info == MV.GROUND, tostring(t))
print("ok: w:circle and w:segment in the plane: the floor (its seams no wall), the ledge's side, a corner, the wall off the plane not met, a heightmap's slope")
-- vim: set noet ts=4 sw=4:
