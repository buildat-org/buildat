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
-- The slab (0.5 up, under step_height 0.6): walked onto; the block not
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
-- [KIT_SLAB_WALK] Shaped cells as wide stairs, along +z from the floor:
-- a slab (its top 1.0), a cube (1.5), a slab (2.0), cubes (2.5); a row of
-- stairs (Kit's stair, facing 0: its back half +z) beside it, at x 10.
-- Walked up holding forward only, settled on each top, a jump off a slab
local SLAB = MV.voxel_info("kit/stone:slab", true, nil, nil,
	{-0.5, -0.5, -0.5, 0.5, 0, 0.5})
local STAIR = MV.voxel_info("kit/stone:stair", true, nil, nil,
	{-0.5, -0.5, -0.5, 0.5, 0, 0.5, -0.5, 0, 0, 0.5, 0.5, 0.5})
local rise = world(function(i, j, k)
	local half = i >= 8 and STAIR or SLAB
	if i < -2 or (i > 2 and i < 8) or i > 12 or j < 1 then
		return nil
	end
	if k == 2 and j == 1 then return half end
	if k == 3 and j == 1 then return STONE end
	if k == 4 and j == 1 then return STONE end
	if k == 4 and j == 2 then return half end
	if k >= 5 and j <= 2 then return STONE end
	return false
end)
for _, x in ipairs({0, 10}) do
	local sr, ys = {pos = {x, 0.5, 0}}, {}
	for n = 1, 120 do
		run(walker, sr, 1, {f = 1, r = 0, yaw = 0, jump = 0, go = 0}, rise, wp)
		ys[n] = sr.pos[2]
	end
	assert(sr.pos[3] > 6 and near(sr.pos[2], 2.5) and sr.ground,
			"up the " .. (x == 0 and "slabs" or "stairs") .. ": " ..
			sr.pos[2] .. "," .. sr.pos[3])
	-- Never down while climbing (no bounce)
	for n = 2, 120 do
		assert(ys[n] >= ys[n - 1] - 0.02, "down at step " .. n .. ": " ..
				ys[n - 1] .. " -> " .. ys[n])
	end
end
local sj = {pos = {0, 1.0, 2}}
run(walker, sj, 30, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, rise, wp)
assert(near(sj.pos[2], 1.0) and sj.ground, "on the slab: " .. sj.pos[2])
local sjtop = 0
for _ = 1, 60 do
	run(walker, sj, 1, {f = 0, r = 0, yaw = 0, jump = 1, go = 0}, rise, wp)
	sjtop = math.max(sjtop, sj.pos[2])
end
assert(sj.jumps >= 1 and near(sjtop, 1.0 + wp.jump_height, 0.08),
		"a jump off the slab: " .. sjtop)
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
-- [KIT_DOOR_MIRROR] A door's box, shut, open, and open mirrored: its leaf
-- turned round its -x edge to its front (+z), or to its back (-z)
local function door_box(on, mirror)
	-- (as the server sends kit/door's look; its open box asked for solid,
	-- as look_box gives none for a box that is not)
	return MV.look_box({shape = "box", size = {1, 2, 0.2},
		offset = {0, 0.5, 0}, solid = true, state = "open",
		when = {swing = true, mirror = mirror, solid = true}}, on, {0, 0, 0}, 0)
end
local function box_is(b, want)
	assert(b, "no box")
	for i = 1, 6 do
		assert(near(b[i], want[i]), table.concat(b, ",") .. " not " ..
				table.concat(want, ","))
	end
end
assert(type_of("door").params.mirror.default == false)
box_is(door_box(false, false), {-0.5, -0.5, -0.1, 0.5, 1.5, 0.1})
box_is(door_box(true, false), {-0.5, -0.5, -0.1, -0.3, 1.5, 0.9})
box_is(door_box(true, true), {-0.5, -0.5, -0.9, -0.3, 1.5, 0.1})
-- [KIT_FREE_PREFAB] A free object turned 37.5 at (20, 0.5, 0), a wall along its
-- x and 1 thick: walked into along +z the body stops at it in the object's frame,
-- with a gap in the wall it passes; a ray and the ground beneath find it
local function turned_world(boxes)
	local tw = MV.world{cell = function(_, j)
		return j <= 0 and STONE or nil
	end, turned = MV.turned({{20, 0.5, 0, 37.5, 0, 0, boxes, 9}})}
	return tw
end
local function wall_walk(boxes)
	local a = 37.5 * math.pi / 180
	-- The wall's middle at (20 + 3 cos, -3 sin), from 5 before it along z
	local mx, mz = 20 + 3 * math.cos(a), -3 * math.sin(a)
	local s = {pos = {mx, 0.5, mz - 5}}
	return run(walker, s, 120, {f = 1, r = 0, yaw = 0, jump = 0, go = 0},
			turned_world(boxes), wp), mx, mz, a
end
local whole = {-0.5, 0, -0.5, 6.5, 2, 0.5}
local s, mx, mz, a = wall_walk(whole)
local lx = (s.pos[1] - 20) * math.cos(a) - s.pos[3] * math.sin(a)
local lz = (s.pos[1] - 20) * math.sin(a) + s.pos[3] * math.cos(a)
assert(lz < -0.5 and lz > -2 and lx > 0 and lx < 6.5,
		"stopped at the wall: " .. lx .. " " .. lz)
assert(s.pos[3] > mz - 4.5, "it did walk: " .. s.pos[3])
local g = wall_walk({-0.5, 0, -0.5, 1.5, 2, 0.5, 4.5, 0, -0.5, 6.5, 2, 0.5})
assert(g.pos[3] > mz + 1, "through the gap: " .. g.pos[3])
local tw = turned_world(whole)
local t = tw:ray(mx, 1, mz - 3, 0, 0, 1, 10)
assert(t and t > 1 and t < 3, "a ray meets it: " .. tostring(t))
assert(tw:ray(mx + 30, 1, mz - 3, 0, 0, 1, 10) == nil, "a ray beside it")
local d, di = tw:down(mx, 4, mz, 5)
assert(di == MV.OBJECT and near(d, 1.5), "its top from above: " .. tostring(d))
assert(tw:blocked({mx - 0.3, 1, mz - 0.3, mx + 0.3, 2, mz + 0.3}), "in it")
assert(not tw:blocked({mx + 30, 1, mz, mx + 31, 2, mz + 1}), "beside it")

-- [KIT_WALKER_FRAME] A deck 20 x 1 x 20 (top at y 0.5 of its frame) on a pivot at
-- (0, 5, 0) over the floor, at each turn: walked on in every direction the feet stay
-- on the true surface, whatever the direction, off it and back; jumps, falls.
local DECK = {-10, -0.5, -10, 10, 0.5, 10}
local function deck_world(yaw, pitch, roll, y, boxes)
	return MV.world{cell = function(_, j)
		return j <= 0 and STONE or nil
	end, turned = MV.turned({{0, y or 5, 0, yaw, pitch, roll, boxes or DECK, 7}})}
end
local function deck_of(w)
	return w.turned[1]
end
-- The feet in the deck's frame, by the check's own transpose: its R is also
-- checked against the true turn below
local function feet(w, s)
	local o, p = deck_of(w), s.pos
	local x, y, z = p[1] - o.x, p[2] - o.y, p[3] - o.z
	local R = o.R
	return R[1] * x + R[4] * y + R[7] * z, R[2] * x + R[5] * y + R[8] * z,
			R[3] * x + R[6] * y + R[9] * z
end
-- A body put on the deck's top at (lx, lz) of its frame
local function on_deck(w, lx, lz)
	local o, R = deck_of(w), deck_of(w).R
	return {pos = {o.x + R[1] * lx + R[2] * 0.6 + R[3] * lz,
		o.y + R[4] * lx + R[5] * 0.6 + R[6] * lz,
		o.z + R[7] * lx + R[8] * 0.6 + R[9] * lz}}
end
-- pitch 10: +z goes down the world's y (Urho3D: Ry Rx Rz)
do
	local R = deck_of(deck_world(0, 10, 0)).R
	assert(near(R[6], -math.sin(10 * math.pi / 180), 1e-12), "R: pitch " .. R[6])
	assert(near(R[5], math.cos(10 * math.pi / 180), 1e-12), "R: pitch's up")
	R = deck_of(deck_world(0, 0, 10)).R
	assert(near(R[2], -math.sin(10 * math.pi / 180), 1e-12), "R: roll " .. R[2])
end
local function walk_deck(yaw, pitch, roll, dir)
	local w = deck_world(yaw, pitch, roll)
	local s = on_deck(w, 0, 0)
	local worst = 0
	local input = {f = 1, r = 0, yaw = dir, jump = 0, go = 0}
	local start = nil
	run(walker, s, 20, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
	for n = 1, 60 do
		walker.step(s, input, 1 / 60, w, wp)
		if n > 0 then
			assert(s.frame == 7, string.format("in its frame at step %d: yaw %g pitch %g roll %g dir %g at %.3f,%.3f,%.3f", n, yaw, pitch, roll, dir, s.pos[1], s.pos[2], s.pos[3]))
			local _, ly = feet(w, s)
			worst = math.max(worst, math.abs(ly - 0.5))
			assert(s.ground, "on the ground at " .. n)
		end
		if n == 30 then
			start = {s.pos[1], s.pos[2], s.pos[3]}
		end
	end
	-- Half a second at full speed: along the deck, at speed, the way it was asked
	local dx, dy, dz = s.pos[1] - start[1], s.pos[2] - start[2], s.pos[3] - start[3]
	local len = math.sqrt(dx * dx + dy * dy + dz * dz)
	assert(math.abs(len - wp.speed * 0.5) < 0.05, string.format(
			"speed along the deck: %.3f in half a second (yaw %g pitch %g roll %g dir %g)",
			len, yaw, pitch, roll, dir))
	local a = math.atan2(dx, dz) * 180 / math.pi
	local off = ((a - dir) % 360 + 180) % 360 - 180
	assert(math.abs(off) < 0.5, string.format("heading %.2f, asked %g (yaw %g pitch %g roll %g)",
			a, dir, yaw, pitch, roll))
	assert(worst < 1e-3, "above the surface: " .. worst)
	return s, w
end
for _, t in ipairs({{0, 10, 0}, {0, 350, 0}, {0, 0, 10}, {0, 0, 350}, {30, 15, 350},
		{125, 20, 25}, {0, 45, 0}, {0, 0, 45}, {0, 0, 0}, {37.5, 0, 0}}) do
	for dir = 0, 315, 45 do
		walk_deck(t[1], t[2], t[3], dir)
	end
end
-- A walk's start: at rest, it stands: no creep down a deck within the limit
do
	local w = deck_world(0, 45, 0)
	local s = on_deck(w, 2, 2)
	local idle = {f = 0, r = 0, yaw = 0, jump = 0, go = 0}
	run(walker, s, 30, idle, w, wp)
	local p = {s.pos[1], s.pos[2], s.pos[3]}
	run(walker, s, 120, idle, w, wp)
	assert(s.frame == 7 and s.ground, "stands on a 45 degree deck")
	assert(near(s.pos[1], p[1], 1e-9) and near(s.pos[2], p[2], 1e-9) and
			near(s.pos[3], p[3], 1e-9), "no creep")
end
-- Past the limit (default 50): it slides down the fall line, faster and faster, off
-- the deck's end, and cannot walk up. At a limit raised over the deck's angle it stands
do
	local w = deck_world(0, 60, 0, 20)
	local s = on_deck(w, 0, -5)
	local up = {f = -1, r = 0, yaw = 0, jump = 0, go = 0}
	local idle = {f = 0, r = 0, yaw = 0, jump = 0, go = 0}
	run(walker, s, 15, idle, w, wp)
	assert(s.frame == 7 and not s.ground, "60: in the frame, not on ground")
	local _, ly0, lz0 = feet(w, s)
	assert(near(ly0, 0.5, 1e-3), "60: on the surface: " .. ly0)
	run(walker, s, 30, up, w, wp)
	local _, ly1, lz1 = feet(w, s)
	assert(lz1 > lz0 + 1 and near(ly1, 0.5, 1e-3), "60: slid down it, trying to walk up: " ..
			lz0 .. " to " .. lz1 .. " at " .. ly1)
	local jumps = s.jumps or 0
	run(walker, s, 5, {f = 0, r = 0, yaw = 0, jump = 1, go = 0}, w, wp)
	assert((s.jumps or 0) == jumps, "60: no jump off a slide")
	run(walker, s, 240, idle, w, wp)
	assert(s.frame == nil and s.pos[2] < 1 and s.ground, "off its end, to the floor: " ..
			s.pos[2])
	local pl = {}
	for k, v in pairs(wp) do pl[k] = v end
	pl.slope_limit = 65
	w = deck_world(0, 60, 0, 20)
	s = on_deck(w, 0, -5)
	run(walker, s, 30, idle, w, pl)
	local p = s.pos[3]
	run(walker, s, 60, idle, w, pl)
	assert(s.frame == 7 and s.ground and near(s.pos[3], p, 1e-9), "stands at limit 65")
	-- And the limit down: 10 degrees slides at limit 5
	pl.slope_limit = 5
	w = deck_world(0, 10, 0, 20)
	s = on_deck(w, 0, -5)
	run(walker, s, 30, idle, w, pl)
	local _, _, lz = feet(w, s)
	assert(lz > -5 + 0.1, "slides at limit 5: " .. lz)
end
-- Off the deck's end and back: world's fall, floor; onto it again from the floor
-- by the low end's step. A deck low on the floor, pitched 10: its z- end's top a step
-- over the floor.
do
	-- Its low end (+z) a step of 0.3 over the floor, its high end a wall 1 m high
	local w = MV.world{cell = function(_, j)
		return j <= 0 and STONE or nil
	end, turned = MV.turned({{0, 0.65, 0, 0, 5, 0, {-4, -0.5, -4, 4, 0.5, 4}, 7}})}
	local o = w.turned[1]
	-- From the floor beyond the low end, walking -z (uphill): it steps on
	local s = {pos = {0, 0.5, 9}, ground = true}
	local up = {f = -1, r = 0, yaw = 0, jump = 0, go = 0}
	local entered, left = false, false
	for n = 1, 240 do
		walker.step(s, up, 1 / 60, w, wp)
		if s.frame == 7 then entered = true end
	end
	assert(entered, "stepped on from the floor, at " .. s.pos[1] .. "," .. s.pos[2] ..
			"," .. s.pos[3])
	-- Off the high end: falls, stands on the floor beyond it
	assert(s.frame == nil and near(s.pos[2], 0.5, 1e-3) and s.pos[3] < -4,
			"off the far end: " .. s.pos[2] .. " " .. s.pos[3])
	-- Back along +z, over the high end's wall: a body cannot step 1 m; stopped by it
	local down = {f = 1, r = 0, yaw = 0, jump = 0, go = 0}
	run(walker, s, 120, down, w, wp)
	assert(s.frame == nil and s.pos[3] < -3, "stopped at the deck's high end: " .. s.pos[3])
	-- Jumped onto it, on: in the frame again
	for n = 1, 60 do
		walker.step(s, {f = 1, r = 0, yaw = 0, jump = 1, go = 0}, 1 / 60, w, wp)
		if s.frame == 7 then left = true end
	end
	assert(left, "jumped onto it")
	-- A jump: out of the frame, then back on it on landing, the height the world's
	local top = 0
	s = on_deck(w, 0, 0)
	run(walker, s, 10, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
	assert(s.frame == 7, "on it to jump")
	local y0 = s.pos[2]
	walker.step(s, {f = 0, r = 0, yaw = 0, jump = 1, go = 0}, 1 / 60, w, wp)
	assert(s.frame == nil and s.at == nil, "a jump leaves the frame")
	for n = 1, 120 do
		walker.step(s, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, 1 / 60, w, wp)
		top = math.max(top, s.pos[2] - y0)
	end
	assert(math.abs(top - wp.jump_height) < 0.1, "its height: " .. top)
	assert(s.frame == 7 and s.ground, "lands in the frame")
	local _, ly = feet(w, s)
	assert(near(ly, 0.5, 1e-3), "on the surface after: " .. ly)
end
-- Falls onto a tilted deck from above, each way: in the frame on the surface
for _, t in ipairs({{0, 10, 0}, {0, 0, 350}, {30, 20, 15}}) do
	local w = deck_world(t[1], t[2], t[3], 3)
	local s = {pos = {1, 10, 1}}
	run(walker, s, 120, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
	assert(s.frame == 7 and s.ground, "fell onto it")
	local _, ly = feet(w, s)
	assert(near(ly, 0.5, 1e-3), "on the surface: " .. ly)
end
-- Beside a leaning wall: no hanging on it, falling past it; a walled deck: stopped
-- at its wall, in the frame
do
	-- The wall leans out over the body, which falls alongside: it reaches the floor
	local w = deck_world(0, 0, 20, 2, {-0.5, -1, -3, 0.5, 4, 3})
	local R = deck_of(w).R
	local s = {pos = {2.2, 6, 0}}
	run(walker, s, 180, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
	assert(s.pos[2] < 0.6 or s.frame == 7, "fell by the wall: " .. s.pos[1] .. "," .. s.pos[2])
	-- A deck with a wall at its +z end, in the frame
	local w2 = deck_world(0, 10, 0, 5, {-5, -0.5, -5, 5, 0.5, 5, -5, 0.5, 3, 5, 2.5, 4})
	local s2 = on_deck(w2, 0, 0)
	run(walker, s2, 120, {f = 1, r = 0, yaw = 0, jump = 0, go = 0}, w2, wp)
	local _, ly, lz = feet(w2, s2)
	assert(s2.frame == 7 and near(lz, 3 - 0.45, 1e-3) and near(ly, 0.5, 1e-3),
			"stopped at the wall: " .. lz .. " " .. ly)
end
-- A wall leaning away, floor to its top: walked into, the step over it never goes in
do
	local w = deck_world(0, 10, 0, 1.4, {-3, -0.5, -0.5, 3, 1.5, 3})
	local s = {pos = {0, 0.5, -4}, ground = true}
	run(walker, s, 120, {f = 1, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
	assert(near(s.pos[2], 0.5, 1e-3) and s.pos[3] < -0.5, "stopped at it on the floor: " ..
			s.pos[2] .. " " .. s.pos[3])
end
-- A deck into the floor: walking down it the floor takes over, and level on, it stands
do
	local w = MV.world{cell = function(_, j)
		return j <= 0 and STONE or nil
	end, turned = MV.turned({{0, 1.5, 0, 0, 10, 0, {-5, -0.5, -8, 5, 0.5, 8}, 7}})}
	local s = {pos = {0, 2.1, -3}}
	run(walker, s, 30, {f = 0, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
	assert(s.frame == 7, "on the deck first")
	run(walker, s, 180, {f = 1, r = 0, yaw = 0, jump = 0, go = 0}, w, wp)
	assert(s.frame == nil and near(s.pos[2], 0.5, 1e-3) and s.pos[3] > 8,
			"on the floor past the deck: " .. s.pos[2] .. " " .. s.pos[3])
end
-- The same bits from a state that went through the text the wire carries (%.17g), each
-- batch: the client's prediction and the server's step
do
	local function wire(v)
		if type(v) == "table" then
			local r = {}
			for k, x in pairs(v) do r[k] = wire(x) end
			return r
		elseif type(v) == "number" then
			return tonumber(string.format("%.17g", v))
		end
		return v
	end
	local w = deck_world(30, 15, 350)
	local a, b = on_deck(w, 0, 0), on_deck(w, 0, 0)
	for n = 1, 300 do
		local i = {f = n % 200 < 150 and 1 or 0, r = n % 60 < 30 and 1 or 0,
			yaw = n % 360, jump = n % 97 == 0 and 1 or 0, go = 0}
		walker.step(a, i, 1 / 60, w, wp)
		walker.step(b, i, 1 / 60, deck_world(30, 15, 350), wp)
		if n % 5 == 0 then
			b = wire(b)
		end
	end
	for k = 1, 3 do
		assert(a.pos[k] == b.pos[k], "the same bits: " .. a.pos[k] .. " " .. b.pos[k])
	end
	assert(a.frame == b.frame)
end
print("kit_move_check: ok")
