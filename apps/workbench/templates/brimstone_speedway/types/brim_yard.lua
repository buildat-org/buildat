-- Brimstone Speedway's Bone Yard ([KIT_GENERATORS], a generator): the track
-- laid along `corners` (the centre line's corners in its frame's x, z: the
-- straights between them and an arc of the corner's `r` round each), its
-- built children: the road (dirt, `width` across), concrete walls along both
-- edges and tyre walls round the outside of each bend, a corner's `runoff`
-- (metres of loose gravel on the bend's outside, the wall moved out by it,
-- tapering back along the straights either side, kept out between two
-- bends' on one side when under JOIN m of wall is left), mud and an oil slick
-- across the line, the finish line 6 m ahead of the race's pole (the
-- local/brim_race in its scene: its place), a checkpoint in the middle of
-- the straight into each corner whose `checkpoint` is 1 (in the lap's order
-- from the finish, linked to that race's checkpoint), the yard's fence and
-- junk scattered off the road by `seed`, kept clear of every hand-placed
-- entity there. Run in the editor (Run, or a parameter's change) or by an
-- agent (run_generator); a round may run it with a new seed (c:generate).
-- Errors (a bend too tight for the walls, bends overlapping, the loop
-- meeting itself) refuse the run, why said.
-- simplified: the generator's own yaw is taken as 0 (turned, its children
-- turn with it but the race's pole is read unturned); the yard's size fixed
local PI = math.pi
-- The floors: their places (Kit puts a child on the 1/16) and depths, the
-- tops at 0.555 (the road, the run-off) and 0.5875 (mud, oil, the line)
local Y_ROAD, D_ROAD, Y_PATCH, D_PATCH = 0.5, 0.11, 0.5625, 0.05
local WALL = 1.5 -- the walls' thickness
local JOIN = 25 -- under this much wall between two bends' run-off on one side: joined
local YARD = {118, 82} -- the fence's half sizes
local MUD = {{9, 9}, {10, 7}, {8, 10}, {9, 8}} -- a patch's width and length, in turn
local RUST = {"#7a3b1e", "#4e5a3a", "#5b4a3a", "#6a2020", "#3a4a5a", "#8a6a2a"}
local DRUMS = {"#8a1a12", "#1d3a6a", "#7a5a1a", "#3a5a2a", "#5a5a5a"}

local function hypot(x, z)
	return math.sqrt(x * x + z * z)
end

local function r2(v)
	return math.floor(v * 100 + 0.5) / 100
end

-- (a child's place: Kit's grid, so that its points are where they were made)
local function sixteenth(v)
	return math.floor(v * 16 + 0.5) / 16
end

-- A Lehmer generator from the seed, the same on every server: r() in [0, 1)
local function rng(seed)
	local s = math.floor(seed) % 2147483646 + 1
	local function r()
		s = s * 16807 % 2147483647
		return (s - 1) / 2147483646
	end
	return r, function(a, b) return a + (b - a) * r() end
end

local function numbers(s)
	local t = {}
	for v in tostring(s):gmatch("[-%d.]+") do
		t[#t + 1] = tonumber(v)
	end
	return t
end

-- The loop: each corner's bend {t (its tangent's length), la (the straight
-- into it), pts {{x, z, nx, nz}...} (its arc, nx, nz the left normal), s (1
-- left, -1 right), ro (its run-off)}
local function bends(C, W)
	local n, out = #C, {}
	for i = 1, n do
		local p0, p1, p2 = C[(i - 2) % n + 1], C[i], C[i % n + 1]
		local x0, z0, x1, z1, x2, z2, r = p0[1], p0[2], p1[1], p1[2], p2[1], p2[2], p1[3]
		local la, lb = hypot(x1 - x0, z1 - z0), hypot(x2 - x1, z2 - z1)
		if la == 0 or lb == 0 then
			error("corner " .. i .. " is where the one before or after it is", 0)
		end
		local ax, az, bx, bz = (x1 - x0) / la, (z1 - z0) / la, (x2 - x1) / lb, (z2 - z1) / lb
		local turn = math.atan2(ax * bz - az * bx, ax * bx + az * bz)
		local h = math.abs(turn) / 2
		local t = r * math.sin(h) / math.cos(h)
		if r - W - WALL <= 0.4 then
			error("corner " .. i .. ": its r " .. r .. " is too tight for the walls (more than " ..
				(W + WALL + 0.4) .. ")", 0)
		end
		local px, pz = x1 - ax * t, z1 - az * t
		local s = turn > 0 and 1 or -1
		local cx, cz = px - az * r * s, pz + ax * r * s
		local a0 = math.atan2(pz - cz, px - cx)
		local k = math.max(2, math.floor(math.abs(turn) / (PI / 20)))
		local pts = {}
		for j = 0, k do
			local a = a0 + turn * j / k
			local ux, uz = math.cos(a), math.sin(a)
			pts[#pts + 1] = {cx + r * ux, cz + r * uz, -ux * s, -uz * s}
		end
		out[i] = {t = t, la = la, pts = pts, s = s, ro = p1[4] or 0, cp = (p1[5] or 0) >= 0.5}
	end
	for i = 1, n do
		if out[(i - 2) % n + 1].t + out[i].t >= out[i].la + 0.01 then
			error("the bends at corners " .. ((i - 2) % n + 1) .. " and " .. i .. " overlap", 0)
		end
	end
	return out
end

-- The pieces: the straight into each corner, then its bend, each a list of
-- {x, z, nx, nz, left, right} (left and right: the run-off on that side
-- there) and turn (0 a straight, else the bend's s)
local function pieces(B)
	local n, out = #B, {}
	for i = 1, n do
		local b0, b1 = B[(i - 2) % n + 1], B[i]
		local a, e = b0.pts[#b0.pts], b1.pts[1]
		local len = hypot(e[1] - a[1], e[2] - a[2])
		-- Out of the bend before: its run-off on its outside, down to 0 over
		-- 4 times its width; into this one: up from 0 over 2 times
		local lx = math.min(4 * b0.ro, 0.45 * len)
		local ln = math.min(2 * b1.ro, 0.45 * len)
		-- Both bends' run-off on one side with under JOIN m of wall between
		-- the tapers: kept out across the straight at the smaller of the two,
		-- no wall stub between them
		local m = b0.s == b1.s and b0.ro > 0 and b1.ro > 0 and len - lx - ln < JOIN and
			math.min(b0.ro, b1.ro) or 0
		local function off(side, d)
			local o = side == -b1.s and m or 0
			if side == -b0.s and lx > 0 and d < lx then
				o = math.max(o, b0.ro * (1 - d / lx))
			end
			if side == -b1.s and ln > 0 and d > len - ln then
				o = math.max(o, b1.ro * (1 - (len - d) / ln))
			end
			return o
		end
		local ds = {0}
		-- (where the tapers meet the joined width, if any)
		local j0 = m > 0 and lx * (1 - m / b0.ro) or lx
		local j1 = m > 0 and len - ln * (1 - m / b1.ro) or len - ln
		for _, d in ipairs({j0, j1}) do
			if d > 0.5 and d < len - 0.5 then
				ds[#ds + 1] = d
			end
		end
		ds[#ds + 1] = len
		table.sort(ds)
		local st = {}
		for _, d in ipairs(ds) do
			local f = d / len
			st[#st + 1] = {a[1] + (e[1] - a[1]) * f, a[2] + (e[2] - a[2]) * f, a[3], a[4],
				off(1, d), off(-1, d)}
		end
		out[#out + 1] = {turn = 0, pts = st, off = off, len = len}
		local bp = {}
		for k, p in ipairs(b1.pts) do
			bp[k] = {p[1], p[2], p[3], p[4], b1.s == -1 and b1.ro or 0, b1.s == 1 and b1.ro or 0}
		end
		out[#out + 1] = {turn = b1.s, pts = bp}
	end
	return out
end

return {
	version = 1,
	-- (a lap's worth of road, walls, run-off and junk: some 250 children)
	children = 600,
	gizmo = {shape = "sphere", size = 0.6, color = "#d08020"},
	about = {
		group = "Game",
		what = "Brimstone Speedway's track generator: the road, walls, run-off, mud, finish line, checkpoints and junk along a corner list; Run builds them again.",
	},
	params = {
		corners = {type = "points", level = true, values = {
				{name = "r", default = 10, min = 4, max = 60},
				{name = "runoff", default = 0, min = 0, max = 12},
				{name = "checkpoint", default = 0, min = 0, max = 1}},
			default = {{-100, -58, 12, 4, 1}, {60, -58, 10, 6, 0}, {60, -34, 10, 0, 0},
				{10, -34, 9, 0, 0}, {0, -14, 9, 0, 0}, {30, 0, 10, 0, 0}, {95, 0, 12, 5, 1},
				{95, 55, 12, 5, 0}, {50, 55, 9, 0, 1}, {40, 30, 8, 0, 0}, {25, 30, 8, 0, 0},
				{15, 58, 10, 0, 0}, {-40, 58, 12, 5, 0}, {-55, 20, 10, 0, 0}, {-30, 5, 9, 0, 0},
				{-60, -10, 10, 0, 0}, {-100, -20, 12, 4, 0}}},
		width = {type = "number", default = 12, min = 6, max = 24},
		seed = {type = "number", default = 1955, min = 0, max = 2147483646},
		junk = {type = "number", default = 1, min = 0, max = 2},
		mud = {type = "string", default = "150 300 455 560"},
		oil = {type = "string", default = "235"},
	},
	on_build = function(c)
		local W = c.params.width / 2
		local C = {}
		for i, p in ipairs(c.params.corners) do
			C[i] = {p[1], p[2], p[3] or 10, p[4] or 0, p[5] or 0}
		end
		if #C < 3 then
			error("3 corners at least", 0)
		end
		local B = bends(C, W)
		local P = pieces(B)
		-- The centre line every metre {x, z, run-off}, for distances
		local LINE = {}
		for _, pc in ipairs(P) do
			local p = pc.pts
			local a, list = 0, pc.turn == 0 and {p[1], p[#p]} or p
			for q = 1, #list - 1 do
				local A, Bq = list[q], list[q + 1]
				local d = hypot(Bq[1] - A[1], Bq[2] - A[2])
				local m = math.max(1, math.floor(d))
				for k = 0, m - 1 do
					local o = pc.turn == 0 and math.max(pc.off(1, a + d * k / m),
						pc.off(-1, a + d * k / m)) or math.max(A[5], A[6])
					LINE[#LINE + 1] = {A[1] + (Bq[1] - A[1]) * k / m, A[2] + (Bq[2] - A[2]) * k / m, o}
				end
				a = a + d
			end
		end
		local N = #LINE
		-- The loop must not come near itself: points far apart along it are apart
		for i = 1, N, 2 do
			for j = i + 40, math.min(N, i + N - 40), 2 do
				local a, b = LINE[i], LINE[j]
				local d = hypot(a[1] - b[1], a[2] - b[2])
				if d <= 2 * (W + WALL) + a[3] + b[3] + 2 then
					error(string.format("the loop meets itself near %.0f,%.0f and %.0f,%.0f (%.1f m apart)",
						a[1], a[2], b[1], b[2], d), 0)
				end
			end
		end
		local function off_road(x, z, margin)
			for _, p in ipairs(LINE) do
				local m = W + WALL + p[3] + margin
				local dx, dz = x - p[1], z - p[2]
				if dx * dx + dz * dz <= m * m then
					return false
				end
			end
			return true
		end
		local function along(s)
			s = math.floor(s) % N
			local a, b = LINE[s + 1], LINE[(s + 1) % N + 1]
			return a[1], a[2], math.atan2(b[1] - a[1], b[2] - a[2])
		end
		-- (lying flat: points the world's x and z round the place's)
		local function poly(name, pts, y, depth, t)
			local cx, cz = 0, 0
			for _, p in ipairs(pts) do
				cx, cz = cx + p[1], cz + p[2]
			end
			cx, cz = sixteenth(cx / #pts), sixteenth(cz / #pts)
			local p = {depth = depth, points = {}}
			for i, q in ipairs(pts) do
				p.points[i] = {r2(q[1] - cx), r2(q[2] - cz)}
			end
			for k, v in pairs(t or {}) do
				p[k] = v
			end
			if p.floor then
				p.collision = false
			end
			if not p.voxel then
				p.color = p.color or "#808080"
			end
			return c:child{type = "kit/polygon", name = name, pos = {cx, y, cz}, pitch = 90,
				params = p}
		end
		local function circle(x, z, r, n)
			local t = {}
			for a = 0, (n or 8) - 1 do
				t[#t + 1] = {x + r * math.cos(a * 2 * PI / (n or 8)), z + r * math.sin(a * 2 * PI / (n or 8))}
			end
			return t
		end
		-- (w across, l along the heading yaw, degrees, 0 = +z)
		local function rect(x, z, w, l, yaw)
			local a = yaw * PI / 180
			local fx, fz, rx, rz = math.sin(a), math.cos(a), math.cos(a), -math.sin(a)
			local t = {}
			for _, q in ipairs({{1, 1}, {1, -1}, {-1, -1}, {-1, 1}}) do
				t[#t + 1] = {x + fx * l / 2 * q[1] + rx * w / 2 * q[2], z + fz * l / 2 * q[1] + rz * w / 2 * q[2]}
			end
			return t
		end
		local rand, uniform = rng(c.params.seed)
		local function blob(x, z, r)
			local t = {}
			for a = 0, 9 do
				t[#t + 1] = {x + r * (0.7 + 0.5 * rand()) * math.cos(a * 2 * PI / 10),
					z + r * (0.7 + 0.5 * rand()) * math.sin(a * 2 * PI / 10)}
			end
			return t
		end
		-- The composition's own: the race (its pole) and what to keep clear of
		local o = c.pos or {0, 0, 0}
		local race, placed = nil, {}
		for _, e in ipairs(c.entities) do
			for _, t in ipairs(e.types) do
				if t == "local/brim_race" and not race then
					race = e
				end
			end
			if e.pos then
				placed[#placed + 1] = {e.pos[1] - o[1], e.pos[3] - o[3], 8}
			end
		end
		-- The chain-link round it
		local X, Z = YARD[1], YARD[2]
		for _, f in ipairs({{"the fence, south", {{-X, -Z}, {X, -Z}, {X, -Z + 0.15}, {-X, -Z + 0.15}}},
				{"the fence, north", {{-X, Z - 0.15}, {X, Z - 0.15}, {X, Z}, {-X, Z}}},
				{"the fence, west", {{-X, -Z}, {-X + 0.15, -Z}, {-X + 0.15, Z}, {-X, Z}}},
				{"the fence, east", {{X - 0.15, -Z}, {X, -Z}, {X, Z}, {X - 0.15, Z}}}}) do
			poly(f[1], f[2], 1.7, 2.4, {color = "#9aa2a8", material = "glass", collision = false})
		end
		-- The road: dirt, a piece a straight or a bend; the walls along both
		-- edges (concrete blocks, tyres round the outside of each bend), out
		-- by the run-off there, loose gravel between
		for _, pc in ipairs(P) do
			local p = pc.pts
			local left, right = {}, {}
			for k, q in ipairs(p) do
				left[k] = {q[1] + q[3] * W, q[2] + q[4] * W}
				right[#p - k + 1] = {q[1] - q[3] * W, q[2] - q[4] * W}
			end
			for _, q in ipairs(right) do
				left[#left + 1] = q
			end
			poly("the road", left, Y_ROAD, D_ROAD, {voxel = "kit/dirt", floor = true,
				surface = "dirt", edge_depth = 0})
			for _, side in ipairs({1, -1}) do
				local ri = side == 1 and 5 or 6
				local wall, runs = {}, {}
				for k, q in ipairs(p) do
					local a, b = W + q[ri], W + q[ri] + WALL
					wall[k] = {q[1] + q[3] * a * side, q[2] + q[4] * a * side}
					wall[2 * #p - k + 1] = {q[1] + q[3] * b * side, q[2] + q[4] * b * side}
					if q[ri] > 0.01 then
						local r = runs[#runs]
						if r and r[2] == k - 1 then
							r[2] = k
						else
							runs[#runs + 1] = {k, k}
						end
					end
				end
				-- (a bend's outside: the side away from where it turns)
				if side == -pc.turn then
					poly("a tyre wall", wall, 1.0, 1.1, {color = "#1c1c1e"})
				else
					poly("a concrete wall", wall, 1.0, 1.2, {voxel = "kit/stone", edge_depth = 0})
				end
				-- (each run of run-off, from the point before it to the one after)
				for _, run in ipairs(runs) do
					local a, b = math.max(1, run[1] - 1), math.min(#p, run[2] + 1)
					local g = {}
					for k = a, b do
						g[#g + 1] = {p[k][1] + p[k][3] * W * side, p[k][2] + p[k][4] * W * side}
					end
					for k = b, a, -1 do
						local q, w = p[k], W + p[k][ri]
						if q[ri] > 0.01 then
							g[#g + 1] = {q[1] + q[3] * w * side, q[2] + q[4] * w * side}
						end
					end
					poly("the run-off", g, Y_ROAD, D_ROAD, {voxel = "kit/gravel", floor = true,
						surface = "gravel", edge_depth = 0})
				end
			end
		end
		-- Mud: patches across the line where it is slowest to leave; oil: one
		for i, s in ipairs(numbers(c.params.mud)) do
			local x, z, a = along(s)
			local w, l = MUD[(i - 1) % #MUD + 1][1], MUD[(i - 1) % #MUD + 1][2]
			local pts = {}
			for q = 0, 13 do
				local t = q * 2 * PI / 14
				local fx = 0.85 + 0.3 * rand()
				local fz = 0.85 + 0.3 * rand()
				pts[#pts + 1] = {x + math.sin(a) * l / 2 * math.cos(t) + math.cos(a) * w / 2 * math.sin(t) * fx,
					z + math.cos(a) * l / 2 * math.cos(t) - math.sin(a) * w / 2 * math.sin(t) * fz}
			end
			poly("mud", pts, Y_PATCH, D_PATCH, {color = "#3b2a1a", floor = true, surface = "mud"})
		end
		for _, s in ipairs(numbers(c.params.oil)) do
			local x, z = along(s)
			local pts = {}
			for q = 0, 15 do
				local t = q * 2 * PI / 16
				pts[#pts + 1] = {x + 2.6 * math.cos(t) + 1.2 * math.sin(3 * t), z + 3.4 * math.sin(t)}
			end
			poly("the oil slick", pts, Y_PATCH, D_PATCH, {color = "#0b0b10", floor = true,
				surface = "oil", material = "glass"})
		end
		-- The finish line: white and black across the line 6 m ahead of the
		-- race's pole (the line's point nearest it)
		local start = 0
		if race and race.pos then
			local best
			for k, p in ipairs(LINE) do
				local d = hypot(p[1] - (race.pos[1] - o[1]), p[2] - (race.pos[3] - o[3]))
				if not best or d < best then
					best, start = d, k - 1
				end
			end
			start = start + 6
			local x, z, h = along(start)
			-- (along it, and across: the left of the way it goes)
			local dx, dz = math.sin(h), math.cos(h)
			local nx, nz = -dz, dx
			for k = 0, 5 do
				for j = 0, 1 do
					local bx, bz = x + dx * j + nx * (-W + 2 * k), z + dz * j + nz * (-W + 2 * k)
					poly("the finish line", {{bx, bz}, {bx + dx, bz + dz}, {bx + dx + 2 * nx, bz + dz + 2 * nz},
						{bx + 2 * nx, bz + 2 * nz}}, Y_PATCH, D_PATCH, {color = (k + j) % 2 == 0 and
						"#f2f2f2" or "#111111", floor = true, surface = "finish"})
				end
			end
		else
			c:log("no local/brim_race in the scene: no finish line, no checkpoint linked")
		end
		-- The checkpoints: in the middle of the straight into each marked
		-- corner, in the lap's order from the finish line (a zone `size` cells
		-- from its place, the road's width across).
		-- simplified: a straight's zone along the world's axis it mostly runs
		-- along (on a diagonal one a box round its cross-section's middle)
		local cps = {}
		local n = #C
		for i = 1, n do
			if B[i].cp then
				local p0, p1 = C[(i - 2) % n + 1], C[i]
				local mx, mz = math.floor((p0[1] + p1[1]) / 2), math.floor((p0[2] + p1[2]) / 2)
				local best, at = nil, 0
				for k, p in ipairs(LINE) do
					local d = hypot(p[1] - mx, p[2] - mz)
					if not best or d < best then
						best, at = d, k - 1
					end
				end
				cps[#cps + 1] = {mx, mz, p1[1] - p0[1], p1[2] - p0[2], (at - start) % N}
			end
		end
		table.sort(cps, function(a, b) return a[5] < b[5] end)
		for k, q in ipairs(cps) do
			local along_x = math.abs(q[3]) >= math.abs(q[4])
			local wide = 2 * math.floor(W) + 2
			local size = along_x and {2, 3, wide} or {wide, 3, 2}
			local h = math.floor(math.atan2(q[3], q[4]) * 180 / PI + 0.5) % 360
			local id = c:child{type = "local/brim_checkpoint", name = "checkpoint " .. k,
				pos = {q[1] - math.floor(size[1] / 2), 0, q[2] - math.floor(size[3] / 2)},
				params = {order = k, size = size, heading = h}}
			if race then
				c:link(id, "passed", {id = race.id}, "checkpoint")
			end
		end
		-- The junk: off the road, by the seed, clear of what is placed
		local function spot(margin, r)
			for _ = 1, 400 do
				local x, z = uniform(-X + 6, X - 6), uniform(-Z + 6, Z - 6)
				local ok = off_road(x, z, margin)
				for _, q in ipairs(placed) do
					ok = ok and hypot(x - q[1], z - q[2]) > r + q[3]
				end
				if ok then
					placed[#placed + 1] = {x, z, r}
					return x, z
				end
			end
		end
		local j = c.params.junk
		local missed = 0
		for k = 1, math.floor(16 * j + 0.5) do
			local x, z = spot(2.5, 3)
			if x then
				local yaw = uniform(0, 180)
				poly("a car hulk", rect(x, z, 2.1, 4.8, yaw), 1.05, 1.0, {color = RUST[(k - 1) % #RUST + 1],
					collision = false})
				poly("a car hulk's roof", rect(x, z, 1.8, 2.2, yaw + uniform(-6, 6)), 1.75, 0.4,
					{color = "#2a2420", collision = false})
			else
				missed = missed + 1
			end
		end
		for _ = 1, math.floor(10 * j + 0.5) do
			local x, z = spot(1.5, 2.2)
			if x then
				for q = 1, 3 + math.floor(rand() * 4) do
					local a = uniform(0, 2 * PI)
					local d = q == 1 and 0 or uniform(0.9, 1.8)
					poly("an oil drum", circle(x + d * math.cos(a), z + d * math.sin(a), 0.42), 1.0, 0.95,
						{color = DRUMS[math.floor(rand() * #DRUMS) + 1], collision = false})
				end
			else
				missed = missed + 1
			end
		end
		for _ = 1, math.floor(10 * j + 0.5) do
			local x, z = spot(3, 5)
			if x then
				local r = uniform(3.5, 5.5)
				for q, f in ipairs({{1.0, "#4a3e34"}, {0.68, "#6a5a48"}, {0.38, "#7a3b1e"}}) do
					poly("a scrap pile", blob(x + uniform(-0.6, 0.6), z + uniform(-0.6, 0.6), r * f[1]),
						0.8 + (q - 1) * 0.7, 0.8, {color = f[2], collision = false})
				end
			else
				missed = missed + 1
			end
		end
		for _ = 1, math.floor(12 * j + 0.5) do
			local x, z = spot(1.5, 1.5)
			if x then
				poly("a tyre stack", circle(x, z, 0.75), 1.3, 1.6, {color = "#1c1c1e", collision = false})
			else
				missed = missed + 1
			end
		end
		c:log(string.format("the loop %d m, %d corners, %d checkpoints%s", N, n, #cps,
			missed > 0 and ", " .. missed .. " junk with no room" or ""))
	end,
}
