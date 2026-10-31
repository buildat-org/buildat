-- [KIT] stage 4h: builtin/kit/client_lua/move.lua and the movement types
-- stepped as the box steps them (its environment: the box's math only),
-- over a floor of cells: kit/walker walks, jumps (and not with
-- jump_height 0), climbs a step, stops at a wall; kit/click_to_move gets
-- to a target and round a wall; kit/car drives; the heightmap's ground
-- holds. Run: lua util/kit_move_check.lua (Lua 5.1 or LuaJIT), from the
-- source tree's root.
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
local function type_of(name)
	return load_env("builtin/kit/types/" .. name .. ".lua", {math = m,
		ipairs = ipairs, pairs = pairs, type = type, tostring = tostring,
		tonumber = tonumber, table = table, string = string, error = error})
end
local function defaults(t)
	local p = {}
	for k, v in pairs(t.params) do
		p[k] = v.default
	end
	return p
end

-- sin, cos, atan2 against the C library's
for a = -7, 7, 0.37 do
	assert(math.abs(MV.sin(a) - math.sin(a)) < 1e-12, a)
	assert(math.abs(MV.cos(a) - math.cos(a)) < 1e-12, a)
	assert(math.abs(MV.atan2(a, 1.3) - math.atan2(a, 1.3)) < 1e-12, a)
	assert(math.abs(MV.atan2(-1.3, a) - math.atan2(-1.3, a)) < 1e-12, a)
end

-- A floor at y 0 (its top 0.5), a wall at x 5 (z -3...3), a block at z 4...5 (top
-- 1.5: a jump's), a slab (an object's box) at z -6...-4 (top 1.0: a step)
local STONE = MV.voxel_info("kit/stone", true)
local ICE = MV.voxel_info("kit/ice", true, 0.1)
local function world(extra)
	return MV.world{cell = function(i, j, k)
		local e = extra and extra(i, j, k)
		if e ~= nil then
			return e or nil
		end
		if j <= 0 then
			return STONE
		end
		if i == 5 and j <= 3 and k >= -3 and k <= 3 then
			return STONE
		end
		if j == 1 and k >= 4 and k <= 5 and i < 3 then
			return STONE
		end
		return nil
	end, boxes = {{-3, 0.5, -6.5, 3, 1.0, -3.5}}}
end
local function run(def, s, n, input, w, p)
	for _ = 1, n do
		MV.steps(def, s, {input}, 1 / 60, 1, w, p)
	end
	return s
end
local function near(a, b, e)
	return math.abs(a - b) < (e or 1e-3)
end

local walker = type_of("walker")
local wp = defaults(walker)
local w = world()
-- Standing: on the floor (its top 0.5)
local s = {pos = {0, 0.55, 0}}
run(walker, s, 30, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
assert(near(s.pos[2], 0.5) and s.ground == true, s.pos[2])
assert(s.surface == "stone", s.surface)
-- Walking +x (yaw 90: forward is +x): the wall at x 5 (its face 4.5)
-- stops the body's side (r 0.45) at 4.05
run(walker, s, 120, {f = 1, r = 0, yaw = 90, jump = 0, go = 0}, w, wp)
assert(near(s.pos[1], 4.05) and near(s.pos[3], 0), s.pos[1] .. "," .. s.pos[3])
-- Full speed reached on the way, at about 6 m/s
local s2 = {pos = {-20, 0.5, 0}}
run(walker, s2, 60, {f = 1, r = 0, yaw = 90, jump = 0, go = 0}, w, wp)
assert(near(s2.vel[1], wp.speed, 0.01), s2.vel[1])
-- A jump: as high as jump_height
local top, s3 = 0, {pos = {-20, 0.5, -10}}
run(walker, s3, 5, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
for _ = 1, 90 do
	run(walker, s3, 1, {f = 0, r = 0, yaw = 0, jump = 1, go = 0}, w, wp)
	top = math.max(top, s3.pos[2] - 0.5)
	if s3.jumps == 1 and s3.ground then
		break
	end
end
assert(near(top, wp.jump_height, 0.08) and s3.jumps == 1, top)
-- No jump with jump_height 0
local p0 = defaults(walker)
p0.jump_height = 0
local s4 = {pos = {-20, 0.5, -10}}
run(walker, s4, 60, {f = 0, r = 0, yaw = 0, jump = 1, go = 0}, w, p0)
assert(near(s4.pos[2], 0.5) and not s4.jumps, s4.pos[2])
-- The slab (0.5 up, under step_height 0.55): walked onto; the block not
local s5 = {pos = {0, 0.5, 0}}
run(walker, s5, 60, {f = -1, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
assert(s5.pos[3] < -4 and near(s5.pos[2], 1.0), s5.pos[2] .. "," .. s5.pos[3])
local s5b = {pos = {0, 0.5, 0}}
run(walker, s5b, 120, {f = 1, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
assert(near(s5b.pos[3], 3.05) and near(s5b.pos[2], 0.5), s5b.pos[3])
-- Jumping onto the block
run(walker, s5b, 60, {f = 1, r = 0, yaw = 0, jump = 1, go = 0}, w, wp)
assert(s5b.pos[3] > 3.6 and s5b.pos[2] >= 1.5 - 1e-3, s5b.pos[2] .. "," ..
		s5b.pos[3])
-- A jump buffered: pressed in the air just before landing
local s6 = {pos = {-20, 2.5, 10}}
local landed_jump = false
for n = 1, 120 do
	local j = s6.vel and s6.vel[2] < 0 and s6.pos[2] < 0.7 and 1 or 0
	run(walker, s6, 1, {f = 0, r = 0, yaw = 0, jump = j, go = 0}, w, wp)
	if s6.jumps == 1 then
		landed_jump = true
		break
	end
end
assert(landed_jump, "the buffered jump")
-- Coyote time: walked off an edge, a jump still taken a few steps later
local edge = world(function(i, j, k)
	if j <= 0 and i >= 10 then
		return false
	end
end)
local s7 = {pos = {9, 0.5, 0}}
run(walker, s7, 30, {f = 1, r = 0, yaw = 90, jump = 0, go = 0}, edge, wp)
assert(not s7.ground, "off the edge")
local s8 = {pos = {9.2, 0.5, 0}, vel = {6, 0, 0}, ground = true}
local jumped = false
for n = 1, 10 do
	run(walker, s8, 1, {f = 1, r = 0, yaw = 90, jump = n == 5 and 1 or 0,
		go = 0}, edge, wp)
	jumped = jumped or s8.jumps == 1
end
assert(jumped, "coyote time")
-- Ice: slower to speed up
local ice = world(function(i, j, k)
	if j == 0 and i < -30 then
		return ICE
	end
end)
local s9 = {pos = {-60, 0.5, 0}}
run(walker, s9, 5, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, ice, wp)
run(walker, s9, 10, {f = 1, r = 0, yaw = 90, jump = 0, go = 0}, ice, wp)
assert(s9.surface == "ice" and s9.vel[1] < 1, s9.vel[1])

-- Buried by a raise (two cells under a standing body): lifted onto them,
-- not shoved sideways; a heightmap raised under it the same
local bury = world(function(i, j, k)
	if i == 0 and k == 10 and (j == 1 or j == 2) then
		return STONE
	end
end)
local sb = {pos = {0.2, 0.5, 10.1}, ground = true}
run(walker, sb, 3, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, bury, wp)
assert(near(sb.pos[1], 0.2) and near(sb.pos[3], 10.1) and
		near(sb.pos[2], 2.5) and sb.ground, table.concat(sb.pos, ","))
local hraise = MV.world{cell = function() return nil end, ground = function()
	return 3
end}
local sh2 = {pos = {1, 0, 1}, ground = true}
run(walker, sh2, 3, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, hraise, wp)
assert(near(sh2.pos[1], 1) and near(sh2.pos[3], 1) and near(sh2.pos[2], 3),
		table.concat(sh2.pos, ","))

-- The heightmap: a slope rising 0.3 a metre along x, walked up
local hw = MV.world{cell = function() return nil end, ground = function(x, z)
	return x * 0.3
end}
local sh = {pos = {0, 0, 0}}
run(walker, sh, 60, {f = 1, r = 0, yaw = 90, jump = 0, go = 0}, hw, wp)
assert(sh.pos[1] > 4 and sh.pos[2] >= (sh.pos[1] + 0.45) * 0.3 - 0.05,
		sh.pos[1] .. "," .. sh.pos[2])

-- Click to move: there, and round a wall with the client's path
local ctm = type_of("click_to_move")
local cp = defaults(ctm)
local sc = {pos = {0, 0.5, 0}}
run(ctm, sc, 1, {f = 0, r = 0, yaw = 0, jump = 0, go = 1, tx = 3, ty = 0.5,
	tz = 2}, w, cp)
run(ctm, sc, 180, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, cp)
assert(sc.arrived == 1 and near(sc.pos[1], 3, cp.stop_distance + 0.05) and
		near(sc.pos[3], 2, cp.stop_distance + 0.05), sc.pos[1] .. "," .. sc.pos[3])
local route = ctm.plan(w, {3, 0.55, 0}, {7, 0.5, 0}, cp)
assert(route and #route >= 2, "a path round the wall")
local sr = {pos = {3, 0.5, 0}}
for _, leg in ipairs(route) do
	run(ctm, sr, 1, {f = 0, r = 0, yaw = 0, jump = 0, go = 1, tx = leg[1],
		ty = leg[2], tz = leg[3]}, w, cp)
	run(ctm, sr, 240, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, cp)
end
assert(near(sr.pos[1], 7, 0.5) and near(sr.pos[3], 0, 0.5),
		sr.pos[1] .. "," .. sr.pos[3])

-- The car: forward along its yaw, steering turns it
local ok_car, car = pcall(type_of, "car")
if ok_car then
	local kp = defaults(car)
	local w2 = world(function(i, j, k)
		if i == 5 and j > 0 then
			return false
		end
	end)
	local sv = {pos = {0, 0.5, -20}, yaw = 0}
	run(car, sv, 120, {f = 1, r = 0, yaw = 0, jump = 0, go = 0}, w2, kp)
	assert(sv.pos[3] > -15 and math.abs(sv.pos[1]) < 0.5, sv.pos[1] .. "," ..
			sv.pos[3])
	local y0 = sv.yaw
	run(car, sv, 60, {f = 1, r = 1, yaw = 0, jump = 0, go = 0}, w2, kp)
	assert(((sv.yaw - y0) % 360) > 10 and ((sv.yaw - y0) % 360) < 180, sv.yaw)
end
local ok_ball, ball = pcall(type_of, "ball")
if ok_ball then
	local bp = defaults(ball)
	local sb = {pos = {-20, 0.5, 20}}
	run(ball, sb, 120, {f = 1, r = 0, yaw = 0, jump = 0, go = 0}, w, bp)
	assert(sb.pos[3] > 21, sb.pos[3])
end

-- The server's snapshot: the same cells as a world
local snap = MV.snapshot{x0 = -2, y0 = -1, z0 = -2, nx = 5, ny = 4, nz = 5,
	cells = string.rep("A", 25) .. string.rep(".", 75),
	classes = {{"kit/stone", true, 1, ""}}}
local ss = {pos = {0, 0.6, 0}}
run(walker, ss, 30, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, snap, wp)
assert(near(ss.pos[2], -0.5) and ss.surface == "stone", ss.pos[2])
print("kit_move_check: ok")
