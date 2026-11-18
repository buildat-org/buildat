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
-- vim: set noet ts=4 sw=4:
