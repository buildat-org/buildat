-- [KIT_PLANE] builtin/kit/client_lua/move.lua's plane and 2D queries, stepped as
-- the box steps them (its environment: the box's math only), in the plane z 0 over
-- a floor of cells (top 0.5), a ledge in the plane (x 5...20, top 1.5) and a wall
-- just off it (z 1, x 2): kit/walker held to the plane walks under the wall, does
-- not go across with W, jumps onto the ledge, the same bits twice; a step that
-- moves across is put back; w:circle and w:segment against the cells (a floor's
-- seams no wall), the off-plane wall (not met) and a heightmap's slope.
-- Stage 3, kit/polygon's prisms (M.look_poly): the walker up a polygon slope and
-- stopped under an overhang (either winding), back down, a 70-degree one a wall,
-- the same bits twice; the plane off: climbing, passing beside it, stopped by its
-- face along z; w:circle and w:segment against an edge, a polygon at another
-- depth not met, w:down on its top, M.triangulate of a concave shape.
-- [KIT_POLYGON_POINTS] Three skylines of 512 points: a tower's wall met, a step's
-- Lua instructions well within box.c's cap.
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

-- [KIT_PLANE] stage 3: kit/polygon's prisms over the floor (top 0.5): a slope (x 6...12
-- up to 3.5, then level to 20), an overhang over its top (its underside from 6 at
-- x 15 down to 5 at x 20), a wall at another depth (z 3, x 2...3), a steep one (70
-- degrees, x 4...5) in a world of its own
local function poly(points, at, depth)
	return MV.look_poly({shape = "polygon", points = points, depth = depth or 1,
		solid = true}, false, at or {0, 0, 0}, 0)
end
local function rev(l)
	local o = {}
	for i = #l, 1, -1 do
		o[#o + 1] = l[i]
	end
	return o
end
local SLOPE = {{6, 0.5}, {12, 3.5}, {20, 3.5}, {20, 0.5}}
local OVER = {{15, 6}, {20, 5}, {24, 5}, {24, 8}, {15, 8}}
local function pworld(polys, plane)
	return MV.world{cell = function(i, j, k)
		return j <= 0 and STONE or nil
	end, plane = plane, polys = polys}
end
local function walk(w, s, n, i)
	for _ = 1, n do
		MV.steps(walker, s, {i}, 1 / 60, 1, w, wp)
	end
	return s
end
local RIGHT = {f = 0, r = 1, yaw = 0, jump = 0}
local pw = pworld({poly(SLOPE), poly(OVER), poly({{2, 0.5}, {3, 0.5}, {3, 2.5},
	{2, 2.5}}, {0, 0, 3})}, 0)
s = walk(pw, {pos = {0, 0.55, 0}}, 300, RIGHT)
assert(near(s.pos[1], 18.55, 1e-3) and near(s.pos[2], 3.5, 1e-6) and s.ground and
		s.surface == "polygon", "up the slope, under the overhang: " .. s.pos[1] .. "," ..
		s.pos[2])
-- The other way round the points: the same
local pw2 = pworld({poly(rev(SLOPE)), poly(rev(OVER))}, 0)
local s2 = walk(pw2, {pos = {0, 0.55, 0}}, 300, RIGHT)
assert(s2.pos[1] == s.pos[1] and s2.pos[2] == s.pos[2], "wound the other way: " ..
		s2.pos[1])
-- Back down the slope to the floor, on the ground all the way
walk(pw, s, 200, {f = 0, r = -1, yaw = 0, jump = 0})
assert(near(s.pos[2], 0.5) and s.pos[1] < 5 and s.ground, "down: " .. s.pos[2])
-- Past slope_limit (70 degrees): a wall, no step up it
local steep = pworld({poly({{4, 0.5}, {5, 3.25}, {8, 3.25}, {8, 0.5}})}, 0)
local s5 = walk(steep, {pos = {0, 0.55, 0}}, 120, RIGHT)
assert(near(s5.pos[1], 3.55, 1e-3) and near(s5.pos[2], 0.5), "the steep one: " ..
		s5.pos[1] .. "," .. s5.pos[2])
-- The same bits twice
local function ptrace()
	local ww, ss, out = pworld({poly(SLOPE), poly(OVER)}, 0), {pos = {0, 0.55, 0}}, {}
	for n = 1, 400 do
		MV.steps(walker, ss, {{f = 0, r = n < 300 and 1 or -1, yaw = 0,
			jump = (n > 100 and n < 110) and 1 or 0}}, 1 / 60, 1, ww, wp)
		out[#out + 1] = string.format("%.17g %.17g", ss.pos[1], ss.pos[2])
	end
	return table.concat(out, ";")
end
assert(ptrace() == ptrace(), "not the same bits over polygons")
-- The plane off: a body at z 0 climbs it as well; one at z 2 is past its depth
local s6 = walk(pworld({poly(SLOPE)}), {pos = {0, 0.55, 0}}, 120, RIGHT)
assert(s6.pos[2] > 1 and near(s6.pos[3], 0), "3D up the slope: " .. s6.pos[2])
local s7 = walk(pworld({poly(SLOPE)}), {pos = {0, 0.55, 2}}, 120, RIGHT)
assert(near(s7.pos[2], 0.5) and s7.pos[1] > 7, "3D past its depth met: " .. s7.pos[1])
-- ... and walking along z into its face (x 9, its area there 0.5...2) stops there
local s8 = walk(pworld({poly(SLOPE)}), {pos = {9, 0.55, -3}}, 120,
	{f = 1, r = 0, yaw = 0, jump = 0})
assert(near(s8.pos[3], -0.95, 1e-3), "3D its face: " .. s8.pos[3])
print("ok: kit/walker over polygons: up a slope, stopped under an overhang, either winding, back down, a 70-degree one a wall, one at another depth not met, the same bits twice; the plane off: up it at its depth, past it off it, its face along z")

-- w:circle and w:segment against a polygon's edge; one at another depth not met
c = pw:circle(9, 2.4, 0.5)
local dd = 0.5 - 0.8 / math.sqrt(5)
assert(#c == 1 and near(c[1].depth, dd) and near(c[1].nx, -1 / math.sqrt(5)) and
		near(c[1].ny, 2 / math.sqrt(5)) and c[1].info.surface == "polygon", #c)
-- Its middle in the slope, within the radius: out along the edge's normal
c = pw:circle(9, 1.8, 0.5)
assert(#c >= 1 and near(c[1].nx, -1 / math.sqrt(5)) and c[1].depth > 0.5, #c)
assert(#pw:circle(2.5, 2.8, 0.4) == 0, "the wall at another depth met")
assert(#pw:circle(2.5, 2.8, 0.4, 3) == 1, "the wall at its own depth not met")
t, nx, ny, info = pw:segment(9, 5, 9, 0)
assert(near(t, 0.6) and near(nx, -1 / math.sqrt(5)) and near(ny, 2 / math.sqrt(5)) and
		info.surface == "polygon", tostring(t))
assert(pw:segment(2.5, 1.5, 2.5, 3) == nil, "the segment met the one at another depth")
-- w:down onto its top; the triangles of a concave one cover its area
local dn = pw:down(16, 5, 0, 3)
assert(near(dn, 1.5), "down: " .. tostring(dn))
local L = {0, 0, 4, 0, 4, 1, 1, 1, 1, 3, 0, 3}
local tri, area = MV.triangulate(L), 0
for q = 1, #tri, 3 do
	local a, b, e = tri[q], tri[q + 1], tri[q + 2]
	area = area + ((L[2 * b - 1] - L[2 * a - 1]) * (L[2 * e] - L[2 * a]) -
			(L[2 * b] - L[2 * a]) * (L[2 * e - 1] - L[2 * a - 1])) / 2
end
assert(#tri == 12 and near(area, 6), "triangles: " .. #tri .. ", " .. area)
print("ok: w:circle, w:segment and w:down against polygon edges, one at another depth not met; a concave one's triangles")

-- [KIT_POLYGON_POINTS] Three skylines of 512 points (127 towers 2 wide, 2 apart, on
-- a base; kit_plane_check.sh's): the walker in the gap at x 10...12 stops at the
-- tower's wall (x 12); its dearest step (that, dropped onto the towers jumping,
-- put inside one) well within box.c's STEP_CAP (200000 instructions, counted by a
-- hook; with every edge looked at each query 150000, some steps 415000)
local SKY = {{-255, -4}, {-85, -4.5}, {85, -4.5}, {255, -4}}
for k = 0, 126 do
	local x, h = 254 - 4 * k, 2 + (k * 37 % 23) / 2
	for _, p in ipairs({{x, 0.5}, {x, h}, {x - 2, h}, {x - 2, 0.5}}) do
		SKY[#SKY + 1] = p
	end
end
assert(#SKY == 512)
local skw = MV.world{cell = function() return nil end, plane = 0, polys = {
	poly(SKY, {0, 10, 0}), poly(SKY, {0, 10, 0}), poly(SKY, {0, 10, 0})}}
if jit then
	jit.off()
end
local count, worst = 0, 0
local function counted(s, n, i)
	for _ = 1, n do
		count = 0
		debug.sethook(function() count = count + 100 end, "", 100)
		MV.steps(walker, s, {i}, 1 / 60, 1, skw, wp)
		debug.sethook()
		worst = math.max(worst, count)
	end
end
s = {pos = {10.6, 10.55, 0}}
counted(s, 120, RIGHT)
assert(near(s.pos[1], 11.55, 1e-3) and near(s.pos[2], 10.5) and s.ground,
		"the skyline's wall: " .. s.pos[1] .. "," .. s.pos[2])
-- (then dropped onto the towers, jumping along them)
s = {pos = {0, 41, 0}}
counted(s, 240, {f = 0, r = 1, yaw = 0, jump = 1})
-- (and put inside a tower: pushed out)
s = {pos = {13, 12, 0}}
counted(s, 30, RIGHT)
if jit then
	jit.on()
end
assert(worst < 100000, "a step over three skylines: " .. worst .. " instructions")
print("ok: three skylines of 512 points: the walker stopped at a tower's wall, its dearest step ~" ..
		worst .. " instructions")

-- [KIT_CLIENT_REACT] (5) a polygon's own surface and friction in what a step meets:
-- w:circle's, w:segment's and the walker's ground (s.surface); none: "polygon", 1
local spikes = MV.look_poly({shape = "polygon", points = SLOPE, depth = 1, solid = true,
	surface = "spikes", friction = 0.25}, false, {0, 0, 0}, 0)
local sw = pworld({spikes}, 0)
c = sw:circle(9, 2.4, 0.5)
assert(#c == 1 and c[1].info.surface == "spikes" and c[1].info.friction == 0.25 and
		near(c[1].info.ny, 2 / math.sqrt(5)), "spikes' circle: " .. #c)
t, nx, ny, info = sw:segment(9, 5, 9, 0)
assert(near(t, 0.6) and info.surface == "spikes" and info.friction == 0.25, tostring(t))
s = walk(sw, {pos = {0, 0.55, 0}}, 150, RIGHT)
assert(s.ground and s.surface == "spikes" and s.pos[2] > 1, "on the spikes: " ..
		tostring(s.surface) .. " at " .. s.pos[2])
assert(pw:circle(9, 2.4, 0.5)[1].info.friction == 1, "a polygon's default friction")
assert(MV.look_poly({shape = "polygon", points = SLOPE, solid = true, surface = "",
	friction = 40}, false, {0, 0, 0}, 0).info.friction == 10, "friction past 10")
print("ok: a polygon's surface and friction in w:circle, w:segment and the walker's ground; none: polygon, 1")

-- [KIT_3D_GAINS_1] (4z38) A part's own surface and friction (kit/part's): M.look_box's
-- info (none: nil, M.OBJECT where met); a boost pad on a floor polygon (a road) is
-- what w:under meets over it, the road beside it; w:circle in a level plane meets a
-- free object (a hammer's arm hanging 6.5 from its pivot) as its box sliced at y,
-- swung by a kit/wave's roll at the step's time (M.turned's links, W:pose_at)
local pad = MV.look_box({size = {2, 0.08, 2}, solid = true, surface = "boost",
	friction = 1.5}, false, {0, 0.54, 0}, 0)
assert(pad.info.surface == "boost" and pad.info.friction == 1.5, "the pad's info")
assert(MV.look_box({size = {1, 1, 1}, solid = true, surface = "object", friction = 1},
	false, {0, 0, 0}, 0).info == nil, "a plain part's info")
assert(MV.look_box({size = {1, 1, 1}, solid = true, friction = 40}, false, {0, 0, 0},
	0).info.friction == 10, "a part's friction past 10")
local road = MV.look_poly({shape = "polygon", points = {{-10, -10}, {10, -10}, {10, 10},
	{-10, 10}}, depth = 0.11, floor = true, surface = "asphalt"}, false, {0, 0.5, 0}, 0, 90)
local rw = MV.world{cell = function(i, j, k)
	return j <= 0 and STONE or nil
end, plane = 1, horizontal = true, polys = {road}, boxes = {pad}}
assert(rw:under(0, 0.6, 0).surface == "boost" and rw:under(5, 0.6, 5).surface == "asphalt",
	"the pad on the road: " .. rw:under(0, 0.6, 0).surface)
assert(rw:under(20, 0.6, 0).surface == "kit/stone" or rw:under(20, 0.6, 0) == STONE,
	"off the road")
local ARM = {-0.5, -6.5, -0.5, 0.5, 0.5, 0.5}
local function hw(turned, t)
	return MV.world{cell = function() return nil end, plane = 1, horizontal = true,
		turned = MV.turned(turned), t = t}
end
-- Rolled 30 degrees: the arm's middle line through y 1 at x 10 + 4.619 / 2
local x1 = 10 + 0.5 * 4 / math.cos(math.pi / 6)
local tw = hw({{10, 5, 0, 0, 0, 30, ARM, 7}})
c = tw:circle(x1, 0, 0.5)
assert(#c == 1 and c[1].depth > 0.5, "in the rolled arm: " .. #c)
c = tw:circle(x1 + 0.577 + 0.3, 0, 0.5)
assert(#c == 1 and near(c[1].depth, 0.2, 2e-3) and near(c[1].nx, 1) and near(c[1].ny, 0),
	"beside the rolled arm: " .. #c .. " " .. (c[1] and c[1].depth or 0))
assert(#tw:circle(x1 + 2, 0, 0.5) == 0 and #tw:circle(x1, 0, 0.5, 6) == 0,
	"past the arm, over its pivot")
-- Swung by a wave (30 degrees each way, 4 s): at rest at 0, a quarter in at 30
local WAVE = {wave_roll = 30, wave_roll_period = 4, pivot = {0, 0, 0}}
local sw0 = hw({{10, 5, 0, 0, 0, 0, ARM, 7, {{10, 5, 0, 0, 0, 0, WAVE}}}}, 0)
assert(#sw0:circle(x1, 0, 0.5) == 0 and #sw0:circle(10, 0, 0.5) == 1, "the wave at 0")
sw0:pose_at(1)
assert(#sw0:circle(x1, 0, 0.5) == 1 and #sw0:circle(10, 0, 0.5) == 0, "the wave at 1 s")
-- (none in a vertical plane)
assert(#MV.world{cell = function() return nil end, plane = 0,
	turned = MV.turned({{10, 0, 0, 0, 0, 0, ARM, 7}})}:circle(10, -2, 0.5) == 0,
	"a free object in a vertical plane")
print("ok: a part's surface and friction (a boost pad over a road under w:under); a free object's box sliced in w:circle, swung by a wave")

-- [KIT_CLIENT_REACT] (6) a polygon look's `when` while its state is on: scaled about
-- its own point, moved by its offset (its depth along z too); off: as it is
local GEM = {shape = "polygon", points = {{-1, 0}, {1, 0}, {1, 2}, {-1, 2}}, depth = 2,
	solid = true, state = "taken", when = {scale = {0.5, 0.25, 0.5}, offset = {3, 1, 0.5}}}
local g0 = MV.look_poly(GEM, false, {10, 5, 0}, 0)
assert(g0.x0 == 9 and g0.x1 == 11 and g0.y0 == 5 and g0.y1 == 7 and g0.z0 == -1 and
		g0.z1 == 1, "off: " .. g0.x0 .. " " .. g0.y1)
local g1 = MV.look_poly(GEM, true, {10, 5, 0}, 0)
assert(g1.x0 == 12.5 and g1.x1 == 13.5 and g1.y0 == 6 and g1.y1 == 6.5 and
		g1.z0 == 0 and g1.z1 == 1, "on: " .. g1.x0 .. " " .. g1.x1 .. " " .. g1.y0 .. " " ..
		g1.y1 .. " " .. g1.z0 .. " " .. g1.z1)
-- Turned round (yaw 180): its offset with it
local g2 = MV.look_poly(GEM, true, {10, 5, 0}, 180)
assert(near(g2.x0, 6.5) and near(g2.x1, 7.5) and near(g2.z0, -1) and near(g2.z1, 0),
		"turned: " .. g2.x0 .. " " .. g2.z0)
print("ok: a polygon's when: scaled about its point and offset while on, turned with it")

-- [KIT_CLIENT_REACT] (1) The client's zone tests (move.lua's port of kit.cpp's)
-- on the cases util/kit_agent_tools_check.sh's zones phase asks of the server,
-- the same answers: get_state's bounds, who is in
local function bounds(z, lo, hi, what)
	for k = 1, 3 do
		assert(near(z.lo[k], lo[k]) and near(z.hi[k], hi[k]), what .. ": " ..
				table.concat(z.lo, ",") .. " " .. table.concat(z.hi, ","))
	end
end
local function probe(x, y, wheels)
	return MV.zone_body({x, y, 0}, wheels and {{-0.6, 0.36, 0, 0.36}, {0.6, 0.36, 0, 0.36}})
end
local U = {{0, 0}, {3, 0}, {3, 3}, {2, 3}, {2, 1}, {1, 1}, {1, 3}, {0, 3}}
local uz = MV.zone_look({shape = "polygon", points = U}, false, {20, 1, 0})
bounds(uz, {20, 1, -0.5}, {23, 4, 0.5}, "the U")
assert(not MV.zone_meets(uz, probe(21.5, 2.5)), "the U's notch met")
assert(MV.zone_meets(uz, probe(20.5, 2)), "the U's outline not met")
local gz = MV.zone_cells({60, 1, 0}, nil, {1, 1, 1})
bounds(gz, {59.5, 0.5, -0.5}, {60.5, 1.5, 0.5}, "the gem's cells")
assert(not MV.zone_meets(gz, probe(59.2, 0.6)), "the gem by the point outside")
local wb = probe(59.2, 0.6, true)
assert(near(wb.spheres[1][1], 58.6) and near(wb.spheres[2][2], 0.96), "the wheels")
assert(MV.zone_meets(gz, wb), "the gem not met by a wheel")
assert(MV.zone_meets(gz, probe(59.8, 0.6)), "the gem not met by the point")
local wbox = MV.zone_body({59.25, 0.6, 0}, nil, {r = 0.3, h = 1})
assert(wbox.box and near(wbox.lo[1], 58.951) and near(wbox.hi[2], 1.599) and
		near(wbox.hi[3], 0.299), "the walker's box")
assert(MV.zone_meets(gz, wbox), "the gem not met by a walker's box")
local pg = {shape = "polygon", points = {{-1, 0}, {1, 0}, {1, 2}, {-1, 2}}, depth = 1,
	state = "taken", when = {scale = {0.25, 0.25, 1}, offset = {0, 1, 0}}}
bounds(MV.zone_look(pg, false, {-40, 1, 0}), {-41, 1, -0.5}, {-39, 3, 0.5}, "the polygon gem")
bounds(MV.zone_look(pg, true, {-40, 1, 0}), {-40.25, 2, -0.5}, {-39.75, 2.5, 0.5},
		"the polygon gem taken")
assert(MV.zone_meets(MV.zone_look(pg, false, {-40, 1, 0}), probe(-39.2, 1)) and
		not MV.zone_meets(MV.zone_look(pg, true, {-40, 1, 0}), probe(-39.2, 1)),
		"the polygon gem whole met, taken not")
-- A turned box (a part turned a quarter round y: its long side along z), a
-- sphere, a turned cell box (yaw 90 from a node's rotation)
local q = MV.quat_matrix(math.cos(math.pi / 4), 0, math.sin(math.pi / 4), 0)
local bz = MV.zone_look({size = {4, 1, 1}}, false, {0, 0, 0}, q)
bounds(bz, {-0.5, -0.5, -2}, {0.5, 0.5, 2}, "a turned box")
assert(MV.zone_meets(bz, MV.zone_body({0, -0.5, 1.8})) and
		not MV.zone_meets(bz, MV.zone_body({1.8, -0.5, 0})), "a turned box's long side")
local sz = MV.zone_look({shape = "sphere", size = {2, 2, 2}}, false, {0, 0, 0})
assert(sz.kind == "s" and MV.zone_meets(sz, MV.zone_body({0.6, -0.5, 0.6})) and
		not MV.zone_meets(sz, MV.zone_body({0.8, -0.5, 0.8})), "a sphere")
local cz = MV.zone_cells({0.5, 0, 0}, q, {3, 1, 1})
assert(MV.zone_meets(cz, MV.zone_body({0.5, -0.5, -2})) and
		not MV.zone_meets(cz, MV.zone_body({2.5, -0.5, 0})), "turned cells")
-- [KIT_TOP_DOWN] (3) A flat L (pitch 90 from a node's rotation: its x, y the world's
-- x, z) 1 deep round y 0.5, as kit.cpp's zone_d2 has it in the entity's own frame;
-- turned yaw 90 after (its x along -z, its y along +x)
local h = math.sqrt(0.5)
local L = {shape = "polygon", depth = 1, points = {{0, 0}, {4, 0}, {4, 1}, {1, 1}, {1, 4},
	{0, 4}}}
local lz = MV.zone_look(L, false, {0, 0.5, 0}, MV.quat_matrix(h, h, 0, 0))
bounds(lz, {0, 0, 0}, {4, 1, 4}, "the flat L")
local function meets(z, x, y, zz, box)
	return MV.zone_meets(z, MV.zone_body({x, y, zz}, nil, box and {r = 0.3, h = 1}))
end
-- (a point probe 0.5 over the feet)
assert(meets(lz, 3, 0, 0.5) and meets(lz, 0.5, 0, 3) and not meets(lz, 3, 0, 3) and
		not meets(lz, 0.5, 0.7, 3) and not meets(lz, 0.5, -0.7, 3), "the flat L by a point")
assert(meets(lz, 0.5, 0.6, 3, true) and meets(lz, 1.2, 0.5, 3, true) and
		not meets(lz, 1.4, 0.5, 3, true) and not meets(lz, 0.5, 1.1, 3, true) and
		meets(lz, 0.5, -0.9, 3, true), "the flat L by a walker's box")
-- (yaw 90 then pitch 90: q = qy * qx)
local ty = MV.zone_look(L, false, {0, 0.5, 0}, MV.quat_matrix(0.5, 0.5, 0.5, -0.5))
bounds(ty, {0, 0, -4}, {4, 1, 0}, "the flat L turned")
assert(meets(ty, 0.5, 0, -3) and meets(ty, 3, 0, -0.5) and not meets(ty, 3, 0, -3),
		"the flat L turned by a point")
print("ok: zones on the client as on the server: the U, the gem's cells by a wheel, the point and a box, a polygon gem's when, turned boxes, a sphere; a flat L and one turned yaw 90")

-- [KIT_TOP_DOWN] (1) A level plane (kit/controls' plane "horizontal") at y 1: the
-- feet held at 0.5 over a floor of cells (top 0.5), a wall in the plane's layer (x 3,
-- z -5...5), a ledge over the head's (y 3, x -6...-4); a solid look's box through the
-- layer (x 0...1, z 6...7) and one over it (z -8)
local function hworld(t)
	t = t or {}
	return MV.world{cell = function(i, j, k)
		if j <= 0 and not t.void then
			return STONE
		end
		if j == 1 and i == 3 and k >= -5 and k <= 5 then
			return STONE
		end
		if j == 3 and i >= -6 and i <= -4 then
			return STONE
		end
		return nil
	end, plane = 1, horizontal = true, polys = t.polys, boxes = {
		{0, 0.5, 6, 1, 1.5, 7, info = MV.OBJECT}, {0, 2.5, -8, 1, 3, -7, info = MV.OBJECT}}}
end
local function hrun(s, n, input, w)
	for _ = 1, n do
		MV.steps(walker, s, {input}, 1 / 60, 1, w, wp)
		assert(s.pos[2] == 0.5 and s.vel[2] == 0, "off the level plane: " .. s.pos[2])
	end
	return s
end
local hw0 = hworld()
assert(hw0.horizontal == true and MV.world{plane = 1, horizontal = true}.horizontal and
		not MV.world{horizontal = true}.horizontal, "w.horizontal")
-- W along +z (yaw 0), on the floor; Jump does nothing
s = hrun({pos = {0, 0.5, 0}}, 60, {f = 1, r = 0, yaw = 0, jump = 1}, hw0)
assert(s.pos[3] > 4 and near(s.pos[1], 0) and s.ground == true and s.surface == "stone",
		"along z: " .. s.pos[3] .. " " .. tostring(s.surface))
-- Right (+x) into the wall: stopped at its side; under the ledge (over the head) free
hrun(s, 90, {f = 0, r = 1, yaw = 0, jump = 0}, hw0)
assert(near(s.pos[1], 2.05, 1e-3), "the wall: " .. s.pos[1])
local sl = hrun({pos = {-2, 0.5, 0}}, 60, {f = 0, r = -1, yaw = 0, jump = 0}, hw0)
assert(sl.pos[1] < -6, "under the ledge: " .. sl.pos[1])
-- Nothing under it: held all the same, walking as on the ground
local sv = hrun({pos = {0, 0.5, 0}}, 30, {f = 1, r = 0, yaw = 0, jump = 0},
	hworld{void = true})
local sf = hrun({pos = {0, 0.5, 0}}, 30, {f = 1, r = 0, yaw = 0, jump = 0}, hw0)
assert(sv.pos[3] == sf.pos[3] and sv.pos[3] > 2 and sv.ground and sv.surface == nil and
		sv.friction == 1, "over nothing: " .. sv.pos[3] .. " " .. sf.pos[3])
-- A step going up: put back, its speed up gone, the rest kept
local s9 = {pos = {0, 0.5, 0}}
MV.steps({step = function(st) st.pos[2] = st.pos[2] + 3; st.vel = {1, 7, 2} end},
	s9, {{}}, 1 / 60, 1, hw0, {})
assert(s9.pos[2] == 0.5 and s9.vel[2] == 0 and s9.vel[1] == 1 and s9.vel[3] == 2,
		"not held level: " .. s9.pos[2])
-- The same bits twice
local function htrace()
	local ww, ss, out = hworld(), {pos = {-1, 0.5, -1}}, {}
	for n = 1, 200 do
		MV.steps(walker, ss, {{f = n % 3 == 0 and 1 or 0, r = n < 150 and 1 or -1,
			yaw = 30, jump = 0}}, 1 / 60, 1, ww, wp)
		out[#out + 1] = string.format("%.17g %.17g %.17g", ss.pos[1], ss.pos[2], ss.pos[3])
	end
	return table.concat(out, ";")
end
assert(htrace() == htrace(), "not the same bits level")
print("ok: kit/walker in a level plane: held at y 0.5, no jump, along z and into a wall, under a ledge, over nothing, a step going up held; the same bits twice")

-- w:circle and w:segment level: x, y the world's x and z
c = hw0:circle(2.2, 0, 0.5)
assert(#c == 1 and near(c[1].depth, 0.2) and c[1].nx == -1 and c[1].ny == 0 and
		c[1].info == STONE, "level circle: " .. #c)
-- At a seam of the wall's cells: one side, no seam's
c = hw0:circle(2.2, 0.5, 0.5)
assert(#c == 1 and c[1].nx == -1, "level seam: " .. #c)
-- The ledge over the layer: not met; in its own layer it is
assert(#hw0:circle(-5, 0, 0.4) == 0, "the ledge off the level met")
assert(#hw0:circle(-5, 0, 0.4, 3) == 1, "the ledge in its layer not met")
-- The box through the layer met (its z side), the one over it not
c = hw0:circle(0.5, 5.8, 0.5)
assert(#c == 1 and near(c[1].depth, 0.3) and c[1].nx == 0 and c[1].ny == -1 and
		c[1].info == MV.OBJECT, "the box level: " .. #c)
assert(#hw0:circle(0.5, -8.2, 0.5) == 0, "the box over the layer met")
t, nx, ny, info = hw0:segment(0, 0, 10, 0)
assert(near(t, 0.25) and nx == -1 and ny == 0 and info == STONE, "level segment: " ..
		tostring(t))
t, nx, ny = hw0:segment(0.5, 0, 0.5, 10)
assert(near(t, 0.6) and nx == 0 and ny == -1, "level segment along z: " .. tostring(t))
assert(hw0:segment(-8, 1, -2, 1) == nil, "the level segment met the ledge")
print("ok: w:circle and w:segment level: a wall, its seams, the ledge off the layer, a box through it and one over it")

-- [KIT_TOP_DOWN] (2) kit/polygon lying flat (pitch 90: its x, y the world's x, z;
-- -90: its y along -z), its depth along y
local function flat(points, at, t)
	t = t or {}
	return MV.look_poly({shape = "polygon", points = points, depth = t.depth or 2,
		solid = t.solid ~= false, floor = t.floor, surface = t.surface,
		friction = t.friction}, false, at, t.yaw or 0, t.pitch or 90, 0)
end
local TRI = {{0, 0}, {3, 0}, {0, 1}}
local f1, f2 = flat(TRI, {1, 1, 5}), flat(TRI, {1, 1, 5}, {pitch = -90})
assert(f1.da == 2 and near(f1.x0, 1) and near(f1.x1, 4) and near(f1.y0, 5) and
		near(f1.y1, 6) and near(f1.z0, 0) and near(f1.z1, 2), "flat: " .. f1.y0 .. " " ..
		f1.y1 .. " " .. f1.z0)
assert(f2.da == 2 and near(f2.y0, 4) and near(f2.y1, 5), "flat at -90: " .. f2.y0)
local f3 = flat(TRI, {1, 1, 5}, {yaw = 90})
assert(f3.da == 2 and near(f3.x0, 1) and near(f3.x1, 2) and near(f3.y0, 2) and
		near(f3.y1, 5), "flat turned 90: " .. f3.x0 .. " " .. f3.x1 .. " " .. f3.y0)
assert(MV.look_poly({shape = "polygon", points = TRI, solid = true}, false, {0, 0, 0}, 0,
	45, 0) == nil, "a tilted one met")
assert(flat(TRI, {0, 0, 0}, {solid = false}) == nil, "a flat one not solid, no floor, met")
assert(flat(TRI, {0, 0, 0}, {solid = false, floor = true}).floor, "a floor not a floor")
assert(MV.look_poly({shape = "polygon", points = TRI, floor = true}, false, {0, 0, 0}, 0) ==
		nil, "a standing floor met")
-- In the level plane (y 1): a flat wall across z 4...6 (x -2...2, y 0...2), one over
-- the layer (y 2.5...3.5), an ice floor patch (x -8...-4, y 0.45...0.55)
local WALL = {{-2, -1}, {2, -1}, {2, 1}, {-2, 1}}
local ICE = flat(WALL, {-6, 0.5, 0}, {solid = false, floor = true, depth = 0.1,
	surface = "ice", friction = 0.1})
local function fworld(rev_)
	return hworld{polys = {flat(rev_ and rev(WALL) or WALL, {0, 1, 5}),
		flat(WALL, {0, 3, -5}, {depth = 1}), ICE}}
end
local fw = fworld()
assert(#fw.polys == 2 and #fw.floors == 1, "the floors apart")
s = hrun({pos = {0, 0.5, 0}}, 90, {f = 1, r = 0, yaw = 0, jump = 0}, fw)
assert(near(s.pos[3], 3.55, 1e-3), "the flat wall: " .. s.pos[3])
s2 = hrun({pos = {0, 0.5, 0}}, 90, {f = 1, r = 0, yaw = 0, jump = 0}, fworld(true))
assert(s2.pos[3] == s.pos[3], "the flat wall wound the other way: " .. s2.pos[3])
-- Along -z under the one over the layer, onto the ice: its surface and friction
s = hrun({pos = {0, 0.5, 0}}, 90, {f = -1, r = 0, yaw = 0, jump = 0}, fw)
assert(s.pos[3] < -6, "the flat one over the layer met: " .. s.pos[3])
s = hrun({pos = {-1, 0.5, 0}}, 40, {f = 0, r = -1, yaw = 0, jump = 0}, fw)
assert(s.pos[1] < -4.2 and s.surface == "ice" and s.friction == 0.1, "on the ice: " ..
		s.pos[1] .. " " .. tostring(s.surface))
assert(fw:under(-6, 0.5, 0).surface == "ice" and fw:under(-6, 1.1, 0).surface == "ice" and
		fw:under(-6, 1.2, 0) == nil and fw:under(-3, 0.5, 0).surface == "stone",
		"w:under the ice")
-- Run onto the ice and let go: it slides on (5 m/s2 at 6 m/s), the ground stops
-- it within 0.36
local function let_go(x)
	local st = hrun({pos = {x, 0.5, 0}}, 40, {f = 0, r = -1, yaw = 0, jump = 0}, fw)
	local x0 = st.pos[1]
	hrun(st, 20, {f = 0, r = 0, yaw = 0, jump = 0}, fw)
	return x0 - st.pos[1], x0
end
local slid, on_at = let_go(-1)
local stopped = let_go(8)
assert(on_at < -4 and slid > 1.5 and stopped < 0.4, "ice slides " .. slid .. " from " ..
		on_at .. ", ground " .. stopped)
-- w:circle and w:segment against the flat wall's edge (its normal -z), not the one
-- over the layer
c = fw:circle(0, 3.7, 0.5)
assert(#c == 1 and near(c[1].depth, 0.2) and near(c[1].nx, 0) and near(c[1].ny, -1) and
		c[1].info.surface == "polygon" and c[1].info.flat, "the flat wall's circle: " .. #c)
assert(#fw:circle(0, -4, 0.5) == 0 and #fw:circle(0, -4, 0.5, 3) == 1,
		"the flat one over the layer")
assert(#fw:circle(-6, 0, 0.5) == 0, "the floor met as a wall")
t, nx, ny, info = fw:segment(0, 0, 0, 10)
assert(near(t, 0.4) and near(nx, 0) and near(ny, -1) and info.flat, "the flat wall's " ..
		"segment: " .. tostring(t))
local function ftrace()
	local ww, ss, out = fworld(), {pos = {-1, 0.5, -1}}, {}
	for n = 1, 200 do
		MV.steps(walker, ss, {{f = n < 100 and 1 or -1, r = n % 5 == 0 and -1 or 0,
			yaw = 10, jump = 0}}, 1 / 60, 1, ww, wp)
		out[#out + 1] = string.format("%.17g %.17g", ss.pos[1], ss.pos[3])
	end
	return table.concat(out, ";")
end
assert(ftrace() == ftrace(), "not the same bits over flat polygons")
-- The plane off: a flat slab 1 high is a wall, one 0.4 high a step up onto its top
-- (W:down's), a floor patch the walker's ground's surface
local function slab(h, at)
	return flat(WALL, {at, 0.5 + h / 2, 0}, {depth = h})
end
local s3d = walk(pworld({slab(1, 6)}), {pos = {0, 0.55, 0}}, 120, RIGHT)
assert(near(s3d.pos[1], 3.55, 1e-3) and near(s3d.pos[2], 0.5), "3D the slab 1 high: " ..
		s3d.pos[1] .. "," .. s3d.pos[2])
s3d = walk(pworld({slab(0.4, 6)}), {pos = {0, 0.55, 0}}, 60, RIGHT)
assert(s3d.pos[1] > 4.5 and near(s3d.pos[2], 0.9) and s3d.surface == "polygon",
		"3D up the slab 0.4 high: " .. s3d.pos[1] .. "," .. s3d.pos[2])
assert(near(pworld({slab(0.4, 6)}):down(6, 2, 0, 3), 1.1), "3D down onto its top")
s3d = walk(pworld({ICE}), {pos = {-3, 0.55, 0}}, 30, {f = 0, r = -1, yaw = 0, jump = 0})
assert(s3d.pos[1] < -4.5 and s3d.surface == "ice", "3D on the ice: " .. tostring(s3d.surface))
print("ok: kit/polygon lying flat: its frame at pitch 90, -90 and turned; walls in the level plane either winding, one over the layer not met, the ice floor's surface and slide, w:under; w:circle and w:segment; the same bits twice; the plane off a slab a wall or a step, its top, the floor")

-- [RACER_FEEL] (1) A flat polygon turned in yaw: the server's steps get its angles
-- from kit.cpp's Turn::angles (doubles: all yaw at the gimbal), a client from its
-- node's float rotation (M.turn_angles; Urho3D's own put it all in roll): the same
-- frame, the same bits, its walls and zone where the turn puts them
local function turn_q(yaw, pitch, roll) -- kit.cpp's Turn::of
	local k = math.pi / 360
	local sy, cy = math.sin(yaw * k), math.cos(yaw * k)
	local sx, cx = math.sin(pitch * k), math.cos(pitch * k)
	local sz, cz = math.sin(roll * k), math.cos(roll * k)
	return cy * cx * cz + sy * sx * sz, cy * sx * cz + sy * cx * sz,
			sy * cx * cz - cy * sx * sz, cy * cx * sz - sy * sx * cz
end
local function f32(x) -- to a float's 24 bits, as a node's rotation has it
	if x == 0 then return 0 end
	local mm, e = math.frexp(x)
	return math.floor(mm * 2 ^ 24 + 0.5) / 2 ^ 24 * 2 ^ e
end
local function fpts(p)
	local o = {}
	for i = 1, #p.pts do o[i] = string.format("%.17g", p.pts[i]) end
	return table.concat(o, " ") .. string.format(" %.17g %.17g", p.z0, p.z1)
end
local WALLK = {shape = "polygon", points = WALL, depth = 2, solid = true}
for _, yaw in ipairs({30, 135, 200, 317.5}) do
	for _, pitch in ipairs({90, -90}) do
		local w, x, y, z = turn_q(yaw, pitch, 0)
		local sy, sp, sr = MV.turn_angles(w, x, y, z)
		local cy, cp, cr = MV.turn_angles(f32(w), f32(x), f32(y), f32(z))
		assert(math.abs(sp) == 90 or sp == 270, "the server's flat pitch: " .. sp)
		local server = MV.look_poly(WALLK, false, {0, 1, 5}, sy, sp, sr)
		local client = MV.look_poly(WALLK, false, {0, 1, 5}, cy, cp, cr)
		-- (Urho3D's split: all roll, off by a float's error)
		local roll = pitch > 0 and -yaw or yaw
		local urho = MV.look_poly(WALLK, false, {0, 1, 5}, 0, pitch, roll + 1e-5)
		local given = MV.look_poly(WALLK, false, {0, 1, 5}, yaw, pitch, 0)
		assert(server and server.da == 2 and fpts(server) == fpts(client) and
				fpts(server) == fpts(urho) and fpts(server) == fpts(given),
				"a flat one turned " .. yaw .. " at " .. pitch .. ": the sides differ\n" ..
				fpts(server) .. "\n" .. fpts(client) .. "\n" .. fpts(urho))
		-- Its corner (2, -1 at pitch 90; 2, 1 at -90) where Ry(yaw) Rx(pitch) puts it
		local a = yaw * math.pi / 180
		local ly = pitch > 0 and -1 or 1
		local wx, wz = math.cos(a) * 2 + math.sin(a) * (pitch > 0 and ly or -ly),
				-math.sin(a) * 2 + math.cos(a) * (pitch > 0 and ly or -ly) + 5
		local found = false
		for i = 1, server.n do
			found = found or near(server.pts[2 * i - 1], wx, 1e-9) and
					near(server.pts[2 * i], wz, 1e-9)
		end
		assert(found, "a flat one turned " .. yaw .. " at " .. pitch .. ": no corner at " ..
				wx .. "," .. wz .. ": " .. fpts(server))
		-- Met the same: w:circle at its middle's edge, the walker into it
		local function tw(p)
			return MV.world{cell = function() return nil end, plane = 1, horizontal = true, polys = {p}}
		end
		local mx, mz = math.sin(a) * 2.2, 5 + math.cos(a) * 2.2
		local cs, cc = tw(server):circle(mx, mz, 1.5), tw(client):circle(mx, mz, 1.5)
		assert(#cs == 1 and #cc == 1 and cs[1].depth == cc[1].depth and
				cs[1].nx == cc[1].nx and cs[1].ny == cc[1].ny and near(cs[1].depth, 0.3, 1e-9),
				"a flat one turned " .. yaw .. ": its wall's circle " .. #cs .. " " .. #cc)
		-- Its zone (the server's and the client's port by the node's rotation)
		local zs = MV.zone_look(WALLK, false, {0, 1, 5}, MV.quat_matrix(w, x, y, z))
		local zc = MV.zone_look(WALLK, false, {0, 1, 5}, MV.quat_matrix(f32(w), f32(x),
				f32(y), f32(z)))
		for _, pr in ipairs({{0, 5, true}, {mx * 0.4, 5 + (mz - 5) * 0.4, true},
				{wx * 0.98, 5 + (wz - 5) * 0.98, true}, {mx * 1.5, 5 + (mz - 5) * 1.5, false},
				{0, 8, false}}) do
			local m1 = MV.zone_meets(zs, MV.zone_body({pr[1], 0.5, pr[2]}))
			local m2 = MV.zone_meets(zc, MV.zone_body({pr[1], 0.5, pr[2]}))
			assert(m1 == pr[3] and m2 == pr[3], "a flat zone turned " .. yaw .. " at " ..
					pitch .. ": " .. pr[1] .. "," .. pr[2] .. " " .. tostring(m1) .. " " ..
					tostring(m2))
		end
	end
end
print("ok: a flat polygon turned in yaw (30, 135, 200, 317.5; pitch 90 and -90): the server's angles, a client's from a float rotation and Urho3D's split the same frame to the bit; its corner, wall and zone where the turn puts them")

-- [KIT_TOP_DOWN] (8) The other bodies: in a level plane (the server's snapshot,
-- kit.cpp's bodies_lit()) w:circle meets them as circles, info.body their by and
-- info.vel; none in a vertical plane or without them
local OTHERS = {{3, 0, 1, 2, -1, "player:7"}}
local wb = MV.snapshot{plane = 1, horizontal = true, bodies = OTHERS}
local hb = wb:circle(1.5, 0, 1)
assert(#hb == 1 and near(hb[1].depth, 0.5) and near(hb[1].nx, -1) and near(hb[1].ny, 0) and
		hb[1].info.body == "player:7" and hb[1].info.vel[1] == 2 and hb[1].info.vel[2] == -1,
		"a body met: " .. #hb)
hb = wb:circle(3, 0.5, 1)
assert(#hb == 1 and near(hb[1].depth, 1.5) and near(hb[1].ny, 1), "a body met off its middle")
assert(#wb:circle(-0.5, 0, 1) == 0, "a body out of reach")
assert(#wb:circle(3, 0, 1) == 1, "a body on the middle: out along +x")
assert(#MV.snapshot{plane = 1, horizontal = true}:circle(1.5, 0, 1) == 0, "no bodies asked")
assert(#MV.snapshot{plane = 1, bodies = OTHERS}:circle(1.5, 0, 1) == 0,
		"no bodies in a vertical plane")
print("ok: the other bodies in a level plane: met as circles, their by and velocity; none unasked or upright")

-- What the client's pass costs: 300 zones (cells, boxes, polygons, spheres)
-- built (module.lua builds one again as it moves or its state turns), and
-- met by a bike's two wheels, a frame
local looks = {{size = {1, 1, 1}}, {shape = "polygon", points = U},
	{shape = "sphere", size = {1, 1, 1}}}
local FRAMES, zs, met = 200, {}, 0
local t0 = os.clock()
for f = 1, FRAMES do
	for i = 1, 300 do
		zs[i] = i % 4 == 0 and MV.zone_cells({i % 30, 1, 0}, nil, {1, 1, 1}) or
				MV.zone_look(looks[i % 3 + 1], false, {i % 30, 1, math.floor(i / 30)})
	end
end
local t1 = os.clock()
for f = 1, FRAMES do
	local body = probe(f % 30, 1, true)
	for i = 1, 300 do
		if MV.zone_meets(zs[i], body) then
			met = met + 1
		end
	end
end
local t2 = os.clock()
assert(met > 0)
print(string.format("ok: 300 zones: built in %.0f us, met in %.0f us a frame (luajit)",
		(t1 - t0) / FRAMES * 1e6, (t2 - t1) / FRAMES * 1e6))
-- vim: set noet ts=4 sw=4:
