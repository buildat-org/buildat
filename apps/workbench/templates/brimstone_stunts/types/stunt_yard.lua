-- Brimstone Stunts' Bone Yard ([KIT_GENERATORS], a generator): the track
-- laid along `corners` (the centre line's corners in its frame's x, z: the
-- straights between them and an arc of the corner's `r` round each), its
-- built children: the road (dirt, `width` across), concrete walls along both
-- edges and tyre walls round the outside of each bend, a corner's `runoff`
-- (metres of loose gravel on the bend's outside, the wall moved out by it,
-- tapering back along the straights either side, kept out between two
-- bends' on one side when under JOIN m of wall is left), mud and an oil slick
-- across the line, the finish line 6 m ahead of the race's pole (the
-- local/stunt_race in its scene: its place), a checkpoint in the middle of
-- the straight into each corner whose `checkpoint` is 1 (in the lap's order
-- from the finish, linked to that race's checkpoint), the yard's fence and
-- junk scattered off the road by `seed`, kept clear of every hand-placed
-- entity there. Run in the editor (Run, or a parameter's change) or by an
-- agent (run_generator); a round may run it with a new seed (c:generate).
-- Errors (a bend too tight for the walls, bends overlapping, the loop
-- meeting itself) refuse the run, why said.
-- [KIT_STUNTS] (4z37zzd (2)) Heights: standing kit/polygon prisms along x
-- (their tops what the car's w:down meets: a slope along x only, so each lies
-- on a straight along x), the road and its walls' width across, concrete walls
-- beside them as high as the road there and RAIL over it:
--   the bridge where two straights cross (one along x, the bridge's, one
--     along z through its tunnel: an over-under), a ramp up, a deck over the
--     other road and a ramp down, eased (a car at full speed stays on);
--   `tables` (metres along the centre line, a kicker's foot each): tabletop
--     jumps, a kicker to its lip, a table too high to climb from aside (its
--     walls) and a landing ramp.
-- Their checkpoints are put at the road's height (a zone 3 cells up from it).
-- simplified: the generator's own yaw is taken as 0 (turned, its children
-- turn with it but the race's pole is read unturned); the yard's size fixed;
-- one crossing, a bridge
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
-- [KIT_STUNTS] The road's top (the ground the car stands on: the road and
-- the run-off are solid, the car's w:down meets them; the terrain's own is
-- 0, a whole cell), the walls' height over the road beside a height, the
-- bridge: its ramps' length, deck's, height (the deck's top over the road),
-- its tunnel's roof and width
local GROUND_Y, RAIL = Y_ROAD + D_ROAD / 2, 1.4
local BRIDGE = {up = 34, deck = 20, h = 4.5, roof = 3.9, tunnel = 18}

-- [KIT_STUNTS] A height's profile: {{d, h}...} along the way it is driven
-- from its foot (m), h over the ground, d rising.
-- An eased rise from h0 to h1 over d0...d1 (half a cosine: no edge)
local function ease(P, d0, d1, h0, h1, n)
	for k = 1, n do
		local t = k / n
		P[#P + 1] = {d0 + (d1 - d0) * t, h0 + (h1 - h0) * (1 - math.cos(PI * t)) / 2}
	end
end
-- (a landing ramp of slope s down from h at d: its foot rounded over its
-- last 2 m; its end)
local function landing(P, d, h, s)
	local e = d + h / s + 1
	P[#P + 1] = {e - 2, s}
	for k = 1, 4 do
		local q = e - 2 + k * 0.5
		P[#P + 1] = {q, s * (e - q) * (e - q) / 4}
	end
	return e
end
-- A tabletop: a 2 m curve into the kicker's slope (KICK), straight to its
-- lip (1.5 m), a 10 m table, a landing ramp (0.125)
local KICK = 0.35
local function tabletop()
	local P = {{0, 0}}
	for k = 1, 4 do
		local q = k * 0.5
		P[#P + 1] = {q, KICK * q * q / 4}
	end
	local lip = 2 + (1.5 - KICK) / KICK
	P[#P + 1] = {lip, 1.5}
	P[#P + 1] = {lip + 10, 1.5}
	return P, landing(P, lip + 10, 1.5, 0.125)
end
-- The bridge: eased up, the deck, eased down
local function bridge()
	local B = BRIDGE
	local P = {{0, 0}}
	ease(P, 0, B.up, 0, B.h, 17)
	P[#P + 1] = {B.up + B.deck, B.h}
	ease(P, B.up + B.deck, 2 * B.up + B.deck, B.h, 0, 17)
	return P, 2 * B.up + B.deck
end
-- h at d (between its points; past them 0)
local function prof_h(P, d)
	for k = 2, #P do
		local a, b = P[k - 1], P[k]
		if d >= a[1] and d <= b[1] then
			return a[2] + (b[2] - a[2]) * (d - a[1]) / (b[1] - a[1])
		end
	end
	return 0
end

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
		out[#out + 1] = {turn = 0, pts = st, off = off, len = len, a = a, e = e, ds = ds}
		local bp = {}
		for k, p in ipairs(b1.pts) do
			bp[k] = {p[1], p[2], p[3], p[4], b1.s == -1 and b1.ro or 0, b1.s == 1 and b1.ro or 0}
		end
		out[#out + 1] = {turn = b1.s, pts = bp}
	end
	return out
end

-- (4z37i (4)) The racing line ({{x, z}...}, the lap's way round): the centre
-- line (LINE) at RL_N points, each moved across the road (held RL_IN m inside
-- its edges) to where the line bends least: again and again toward what its
-- neighbours two either side make straightest (the second differences'
-- least squares), at a coarse spacing first, then the fine, each until no
-- point moves RL_SETTLED m in a round (RL_ROUNDS at most). It runs wide
-- into a bend, cuts its inside and runs wide out. (200 rounds a spacing
-- took 70 % of a build and put the Bone Yard near the build's budget;
-- settled, it ends within 0.25 m of that line at well under half the cost)
-- simplified: the road's width only, never the run-off's
local RL_N, RL_IN, RL_SETTLED, RL_ROUNDS = 120, 2.8, 0.005, 200
local function racing_line(LINE, W)
	local N, n = #LINE, math.min(RL_N, math.floor(#LINE / 3))
	local C, Q, d = {}, {}, {}
	for k = 1, n do
		local s = (k - 1) * N / n
		local i = math.floor(s)
		local a, b = LINE[i % N + 1], LINE[(i + 1) % N + 1]
		C[k] = {a[1] + (b[1] - a[1]) * (s - i), a[2] + (b[2] - a[2]) * (s - i)}
		d[k] = 0
	end
	for k = 1, n do
		local a, b = C[(k - 2) % n + 1], C[k % n + 1]
		local l = hypot(b[1] - a[1], b[2] - a[2])
		Q[k] = {-(b[2] - a[2]) / l, (b[1] - a[1]) / l}
	end
	local lim = W - RL_IN
	local function at(k)
		k = (k - 1) % n + 1
		return C[k][1] + Q[k][1] * d[k], C[k][2] + Q[k][2] * d[k]
	end
	for _, span in ipairs({3, 2, 1}) do
		for _ = 1, RL_ROUNDS do
			local moved = 0
			for k = 1, n do
				local ax, az = at(k - span)
				local bx, bz = at(k + span)
				local cx, cz = at(k - 2 * span)
				local ex, ez = at(k + 2 * span)
				local tx = (4 * (ax + bx) - cx - ex) / 6
				local tz = (4 * (az + bz) - cz - ez) / 6
				local v = (tx - C[k][1]) * Q[k][1] + (tz - C[k][2]) * Q[k][2]
				v = v < -lim and -lim or v > lim and lim or v
				moved = math.max(moved, math.abs(v - d[k]))
				d[k] = v
			end
			if moved < RL_SETTLED then
				break
			end
		end
	end
	local out = {}
	for k = 1, n do
		local x, z = at(k)
		out[k] = {r2(x), r2(z)}
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
		what = "Brimstone Stunts' track generator: it builds the road, walls, run-off, mud, finish line, checkpoints and junk along a list of corners, a bridge where two straights cross (one along x over one along z), and tabletop jumps; Run rebuilds them.",
		params = {
			corners = "The centre line's corners (x, z): each one's radius r, its runoff in metres of gravel and checkpoint (1: one before it).",
			width = "The road's width, metres.",
			seed = "The seed of the mud's shapes and the junk's places.",
			junk = "How much junk off the road: 0 none, 1 the usual, 2 double.",
			mud = "Mud patches: metres along the centre line, space-separated.",
			oil = "Oil slicks: metres along the centre line, space-separated.",
			tables = "Tabletop jumps (a kicker, a table, a landing ramp): their feet in metres along the centre line, each on a straight along x.",
		},
	},
	params = {
		corners = {type = "points", level = true, crossing = true, values = {
				{name = "r", default = 10, min = 4, max = 60},
				{name = "runoff", default = 0, min = 0, max = 12},
				{name = "checkpoint", default = 0, min = 0, max = 1}},
			default = {{-100, 10, 16, 4, 0}, {100, 10, 16, 5, 1}, {100, 68, 16, 4, 1},
				{0, 68, 14, 0, 0}, {0, -68, 14, 4, 1}, {-100, -68, 16, 4, 0}}},
		width = {type = "number", default = 12, min = 6, max = 24},
		seed = {type = "number", default = 1955, min = 0, max = 2147483646},
		junk = {type = "number", default = 1, min = 0, max = 2},
		mud = {type = "string", default = "218 358 468 576"},
		oil = {type = "string", default = "265"},
		tables = {type = "string", default = "318 534"},
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
		-- ([KIT_STUNTS] each point's piece and its metres along it: pi, d)
		local LINE = {}
		for pi, pc in ipairs(P) do
			local p = pc.pts
			local a, list = 0, pc.turn == 0 and {p[1], p[#p]} or p
			for q = 1, #list - 1 do
				local A, Bq = list[q], list[q + 1]
				local d = hypot(Bq[1] - A[1], Bq[2] - A[2])
				local m = math.max(1, math.floor(d))
				for k = 0, m - 1 do
					local o = pc.turn == 0 and math.max(pc.off(1, a + d * k / m),
						pc.off(-1, a + d * k / m)) or math.max(A[5], A[6])
					LINE[#LINE + 1] = {A[1] + (Bq[1] - A[1]) * k / m, A[2] + (Bq[2] - A[2]) * k / m, o,
						pi = pi, d = a + d * k / m}
				end
				a = a + d
			end
		end
		local N = #LINE
		-- [KIT_STUNTS] The heights: {kind, pi (its straight), d0 (its foot's metres
		-- along it), len, prof, x0 (its foot's x), sgn (+-1: the way it is driven
		-- along x), zc, tunnel {x0, x1, roof's y}}
		local F = {}
		local function along_x(pc)
			return pc.turn == 0 and math.abs(pc.e[2] - pc.a[2]) <= 0.5
		end
		local function feature(kind, pi, d0, prof, len, what)
			local pc = P[pi]
			if not along_x(pc) then
				error(what .. ": not on a straight along x (a height's slope is along x)", 0)
			end
			if d0 < 3 or d0 + len > pc.len - 3 then
				error(string.format("%s: %.0f m long, no room on its straight (%.0f m)", what, len,
					pc.len), 0)
			end
			for _, d in ipairs({d0, d0 + len}) do
				if pc.off(1, d) > 0.01 or pc.off(-1, d) > 0.01 then
					error(what .. ": on a bend's run-off", 0)
				end
			end
			for _, f in ipairs(F) do
				if f.pi == pi and d0 < f.d0 + f.len + 3 and f.d0 < d0 + len + 3 then
					error(what .. ": on another height", 0)
				end
			end
			local sgn = pc.e[1] > pc.a[1] and 1 or -1
			local f = {kind = kind, pi = pi, d0 = d0, len = len, prof = prof, sgn = sgn,
				x0 = pc.a[1] + sgn * d0, zc = (pc.a[2] + pc.e[2]) / 2}
			F[#F + 1] = f
			return f
		end
		-- The bridge: where two straights cross, the one along x over the one along z
		local under = nil
		for i = 1, #P do
			for j = i + 1, #P do
				local p, q = P[i], P[j]
				if p.turn == 0 and q.turn == 0 then
					local ax, az, bx, bz = p.a[1], p.a[2], p.e[1] - p.a[1], p.e[2] - p.a[2]
					local cx, cz, ex, ez = q.a[1], q.a[2], q.e[1] - q.a[1], q.e[2] - q.a[2]
					local den = bx * ez - bz * ex
					if math.abs(den) > 1e-9 then
						local t = ((cx - ax) * ez - (cz - az) * ex) / den
						local u = ((cx - ax) * bz - (cz - az) * bx) / den
						if t > 0 and t < 1 and u > 0 and u < 1 then
							if under then
								error("the loop crosses itself more than once (one bridge)", 0)
							end
							local up, lo, tu = i, j, t
							if not along_x(p) then
								up, lo, tu = j, i, u
							end
							local L = P[lo]
							if not along_x(P[up]) or math.abs(L.e[1] - L.a[1]) > 0.05 * L.len then
								error(string.format("the crossing near %.0f,%.0f: one straight along x " ..
									"(the bridge) over one along z", ax + bx * t, az + bz * t), 0)
							end
							local prof, len = bridge()
							local f = feature("bridge", up, tu * P[up].len - BRIDGE.up - BRIDGE.deck / 2,
								prof, len, "the bridge")
							-- (the other road's walls through its tunnel)
							local xc = ax + bx * t
							local half = BRIDGE.tunnel / 2
							for _, k in ipairs({-1, 1}) do
								local zq = f.zc + k * (W + WALL + 2)
								local xq = L.a[1] + (L.e[1] - L.a[1]) * (zq - L.a[2]) / (L.e[2] - L.a[2])
								if math.abs(xq - xc) > half - W - WALL then
									error("the road under the bridge leaves its tunnel", 0)
								end
							end
							f.tunnel = {xc - half, xc + half, GROUND_Y + BRIDGE.roof}
							under = lo
						end
					end
				end
			end
		end
		-- The jumps, by their feet along the line
		for _, s in ipairs(numbers(c.params.tables)) do
			local q = LINE[math.floor(s) % N + 1]
			local prof, len = tabletop()
			feature("tabletop", q.pi, q.d, prof, len, string.format("a tabletop at %.0f m", s))
		end
		-- Each point's height (its road's over the ground)
		for _, q in ipairs(LINE) do
			q.h = 0
			for _, f in ipairs(F) do
				if q.pi == f.pi and q.d >= f.d0 and q.d <= f.d0 + f.len then
					q.h = prof_h(f.prof, q.d - f.d0)
				end
			end
		end
		local function on_bridge(q)
			local f = F[1]
			return f and f.kind == "bridge" and q.pi == f.pi and q.d >= f.d0 and
				q.d <= f.d0 + f.len
		end
		-- The loop must not come near itself: points far apart along it are apart
		-- ([KIT_STUNTS] but the bridge's over the road through its tunnel)
		for i = 1, N, 2 do
			for j = i + 40, math.min(N, i + N - 40), 2 do
				local a, b = LINE[i], LINE[j]
				local d = hypot(a[1] - b[1], a[2] - b[2])
				if under and (on_bridge(a) and b.pi == under or on_bridge(b) and a.pi == under) then
					d = math.huge
				end
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
		-- (c:random: the same numbers from the seed on every server)
		local g = c:random(c.params.seed)
		local function uniform(a, b)
			return a + (b - a) * g:next()
		end
		local function blob(x, z, r)
			local t = {}
			for a = 0, 9 do
				t[#t + 1] = {x + r * (0.7 + 0.5 * g:next()) * math.cos(a * 2 * PI / 10),
					z + r * (0.7 + 0.5 * g:next()) * math.sin(a * 2 * PI / 10)}
			end
			return t
		end
		-- The composition's own: the race (its pole) and what to keep clear of
		local o = c.pos or {0, 0, 0}
		local race, placed = nil, {}
		for _, e in ipairs(c.entities) do
			for _, t in ipairs(e.types) do
				if t == "local/stunt_race" and not race then
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
		-- ([KIT_STUNTS] a straight with heights in parts: the stretches clear of them)
		local parts = {}
		for pi, pc in ipairs(P) do
			local cut = {}
			for _, f in ipairs(F) do
				if f.pi == pi then
					cut[#cut + 1] = {f.d0, f.d0 + f.len}
				end
			end
			if #cut == 0 then
				parts[#parts + 1] = pc
			else
				table.sort(cut, function(a, b) return a[1] < b[1] end)
				local from = 0
				cut[#cut + 1] = {pc.len, pc.len}
				for _, r in ipairs(cut) do
					if r[1] - from > 0.5 then
						local ds = {from}
						for _, d in ipairs(pc.ds) do
							if d > from + 0.5 and d < r[1] - 0.5 then
								ds[#ds + 1] = d
							end
						end
						ds[#ds + 1] = r[1]
						local st = {}
						for _, d in ipairs(ds) do
							local t = d / pc.len
							st[#st + 1] = {pc.a[1] + (pc.e[1] - pc.a[1]) * t, pc.a[2] + (pc.e[2] - pc.a[2]) * t,
								pc.a[3], pc.a[4], pc.off(1, d), pc.off(-1, d)}
						end
						parts[#parts + 1] = {turn = 0, pts = st}
					end
					from = r[2]
				end
			end
		end
		for _, pc in ipairs(parts) do
			local p = pc.pts
			local left, right = {}, {}
			for k, q in ipairs(p) do
				left[k] = {q[1] + q[3] * W, q[2] + q[4] * W}
				right[#p - k + 1] = {q[1] - q[3] * W, q[2] - q[4] * W}
			end
			for _, q in ipairs(right) do
				left[#left + 1] = q
			end
			poly("the road", left, Y_ROAD, D_ROAD, {voxel = "kit/dirt",
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
					poly("the run-off", g, Y_ROAD, D_ROAD, {voxel = "kit/gravel",
						surface = "gravel", edge_depth = 0})
				end
			end
		end
		-- [KIT_STUNTS] The heights: each a standing prism (its top along x, its
		-- bottom 0.5 under the ground, the bridge's tunnel cut out), the walls
		-- beside it in stretches of 4 m at most, each RAIL over the highest road
		-- there (over the bridge's deck from its tunnel's roof up)
		local LOOK = {bridge = {"the bridge", "kit/stone"}, tabletop = {"a tabletop jump",
			"kit/planks"}}
		local function fx(f, d)
			return f.x0 + f.sgn * d
		end
		for _, f in ipairs(F) do
			local top = {}
			for _, q in ipairs(f.prof) do
				local x = fx(f, q[1])
				if f.sgn > 0 then
					top[#top + 1] = {x, GROUND_Y + q[2]}
				else
					table.insert(top, 1, {x, GROUND_Y + q[2]})
				end
			end
			local x0, x1 = top[1][1], top[#top][1]
			local pts = top
			pts[#pts + 1] = {x1, 0}
			if f.tunnel then
				local t = f.tunnel
				for _, q in ipairs({{t[2], 0}, {t[2], t[3]}, {t[1], t[3]}, {t[1], 0}}) do
					pts[#pts + 1] = q
				end
			end
			pts[#pts + 1] = {x0, 0}
			local cx, cz = sixteenth((x0 + x1) / 2), sixteenth(f.zc)
			local pp = {depth = 2 * (W + WALL), points = {}, voxel = LOOK[f.kind][2], edge_depth = 0,
				surface = "asphalt"}
			for i, q in ipairs(pts) do
				pp.points[i] = {r2(q[1] - cx), r2(q[2])}
			end
			c:child{type = "kit/polygon", name = LOOK[f.kind][1], pos = {cx, 0, cz}, params = pp}
			-- (the bridge's walls in its ramps and its deck apart)
			local spans = f.kind == "bridge" and {{0, BRIDGE.up}, {BRIDGE.up, BRIDGE.up + BRIDGE.deck},
				{BRIDGE.up + BRIDGE.deck, f.len}} or {{0, f.len}}
			for _, sp in ipairs(spans) do
				local n = math.ceil((sp[2] - sp[1]) / 4 - 1e-9)
				local deck = f.kind == "bridge" and sp[1] == BRIDGE.up
				for k = 0, n - 1 do
					local a, b = sp[1] + (sp[2] - sp[1]) * k / n, sp[1] + (sp[2] - sp[1]) * (k + 1) / n
					local hi = math.max(prof_h(f.prof, a), prof_h(f.prof, b))
					for _, q in ipairs(f.prof) do
						if q[1] > a and q[1] < b and q[2] > hi then
							hi = q[2]
						end
					end
					local y0, y1 = deck and f.tunnel[3] or 0.4, GROUND_Y + hi + RAIL
					local xa, xb = fx(f, a), fx(f, b)
					for _, side in ipairs({1, -1}) do
						local za, zb = f.zc + side * W, f.zc + side * (W + WALL)
						poly(deck and "the bridge's rail" or "a wall by a height",
							{{xa, za}, {xb, za}, {xb, zb}, {xa, zb}}, (y0 + y1) / 2, y1 - y0,
							{voxel = "kit/stone", edge_depth = 0})
					end
				end
			end
		end
		-- (mud, oil and the like on the flat only)
		local function flat(s)
			return LINE[math.floor(s) % N + 1].h == 0 and LINE[(math.floor(s) + 8) % N + 1].h == 0 and
				LINE[(math.floor(s) - 8) % N + 1].h == 0
		end
		-- Mud: patches across the line where it is slowest to leave; oil: one
		for i, s in ipairs(numbers(c.params.mud)) do
			if not flat(s) then
				error(string.format("mud at %.0f m: on a height", s), 0)
			end
			local x, z, a = along(s)
			local w, l = MUD[(i - 1) % #MUD + 1][1], MUD[(i - 1) % #MUD + 1][2]
			local pts = {}
			for q = 0, 13 do
				local t = q * 2 * PI / 14
				local fx = 0.85 + 0.3 * g:next()
				local fz = 0.85 + 0.3 * g:next()
				pts[#pts + 1] = {x + math.sin(a) * l / 2 * math.cos(t) + math.cos(a) * w / 2 * math.sin(t) * fx,
					z + math.cos(a) * l / 2 * math.cos(t) - math.sin(a) * w / 2 * math.sin(t) * fz}
			end
			poly("mud", pts, Y_PATCH, D_PATCH, {color = "#3b2a1a", floor = true, surface = "mud"})
		end
		for _, s in ipairs(numbers(c.params.oil)) do
			if not flat(s) then
				error(string.format("oil at %.0f m: on a height", s), 0)
			end
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
			c:log("no local/stunt_race in the scene: no finish line, no checkpoint linked")
		end
		-- The checkpoints (kit/checkpoint): in the middle of the straight into
		-- each marked corner, in the lap's order from the finish line, turned
		-- to the straight's heading (its zone the road's width across, 2 cells
		-- along: its corner half of that back from the middle).
		local cps = {}
		local n = #C
		for i = 1, n do
			if B[i].cp then
				local p0, p1 = C[(i - 2) % n + 1], C[i]
				local mx, mz = math.floor((p0[1] + p1[1]) / 2), math.floor((p0[2] + p1[2]) / 2)
				-- ([KIT_STUNTS] its straight's point: one over another at a
				-- bridge; the road's height there)
				local best, at = nil, 0
				for k, p in ipairs(LINE) do
					local d = hypot(p[1] - mx, p[2] - mz)
					if p.pi == 2 * i - 1 and (not best or d < best) then
						best, at = d, k - 1
					end
				end
				cps[#cps + 1] = {mx, mz, p1[1] - p0[1], p1[2] - p0[2], (at - start) % N,
					LINE[at + 1].h}
			end
		end
		table.sort(cps, function(a, b) return a[5] < b[5] end)
		for k, q in ipairs(cps) do
			local wide = 2 * math.floor(W) + 2
			local h = math.floor(math.atan2(q[3], q[4]) * 180 / PI + 0.5) % 360
			local a, hx, x, z = h * PI / 180, (wide - 1) / 2, q[1] - 0.5, q[2] - 0.5
			local id = c:child{type = "kit/checkpoint", name = "checkpoint " .. k,
				pos = {x - hx * math.cos(a) - 0.5 * math.sin(a), q[6] > 0 and GROUND_Y + q[6] or 0,
					z + hx * math.sin(a) - 0.5 * math.cos(a)},
				yaw = h, params = {order = k, size = {wide, 3, 2}}}
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
				for q = 1, g:int(3, 6) do
					local a = uniform(0, 2 * PI)
					local d = q == 1 and 0 or uniform(0.9, 1.8)
					poly("an oil drum", circle(x + d * math.cos(a), z + d * math.sin(a), 0.42), 1.0, 0.95,
						{color = DRUMS[g:int(1, #DRUMS)], collision = false})
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
		-- (4z37i (4)) The racing line: the race's bots drive along it
		c:child{type = "kit/path", name = "the racing line", pos = {0, Y_ROAD, 0},
			params = {points = racing_line(LINE, W)}}
		local kinds = {}
		for _, f in ipairs(F) do
			kinds[#kinds + 1] = string.format("%s at %.0f,%.0f", f.kind, fx(f, f.len / 2), f.zc)
		end
		c:log(string.format("the loop %d m, %d corners, %d checkpoints%s; %s", N, n, #cps,
			missed > 0 and ", " .. missed .. " junk with no room" or "",
			#kinds > 0 and table.concat(kinds, ", ") or "no heights"))
	end,
}
