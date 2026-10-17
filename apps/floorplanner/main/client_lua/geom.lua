-- Buildat: apps/floorplanner/main/client_lua/geom.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The plan's 2D geometry, in millimetres, knowing neither Urho3D nor the
-- network: wall outlines with their joins, triangulation, and the small
-- vector helpers the editor picks with. Plan coordinates are (x, z), which
-- are the world's X and Z; seen from above, +X is right and +Z is up, so
-- "left" of a direction is its counter-clockwise side. The self-checks at
-- the end run every time the file loads.
local M = {}

-- Below this the mitre point runs off; the join is capped flat instead
M.MITRE_LIMIT = 4

local function len(x, z)
	return math.sqrt(x * x + z * z)
end
M.len = len

local function cross(ax, az, bx, bz)
	return ax * bz - az * bx
end

-- How far a wall's two faces are from its a->b line: (left, right)
-- justify 3 is custom (user, 2026-10-02): the wall's middle `shift` mm
-- to the left of the line, or to its right where negative, by any amount:
-- past half the thickness the line is off the wall, a face's distance
-- negative
function M.offsets(thickness, justify, shift)
	if justify == 1 then
		return thickness, 0
	elseif justify == 2 then
		return 0, thickness
	elseif justify == 3 then
		local s = shift or 0
		return thickness / 2 + s, thickness / 2 - s
	end
	return thickness / 2, thickness / 2
end

-- Where lines p + s*u and q + t*v meet, or nil when parallel
local function intersect(px, pz, ux, uz, qx, qz, vx, vz)
	local d = cross(ux, uz, vx, vz)
	if math.abs(d) < 1e-9 then
		return nil
	end
	local s = cross(qx - px, qz - pz, vx, vz) / d
	return px + ux * s, pz + uz * s
end

-- walls: {id = {ax, az, bx, bz, thickness, justify, group}}, the ends
-- already looked up. Walls join only within one group (standing and
-- hanging walls never do) and only where they share a node:
-- a_node and b_node are the ids that say so.
-- Returns {id = {pts = {{x, z}, ...}, sides = {"right"|"left"|"core", ...}}}:
-- the outline counter-clockwise, sides[i] naming the face from pts[i] to
-- pts[i + 1].
-- How far, in mm, a wall's end keeps off another's face it would touch
-- (wall_outlines): enough for the depth buffer to tell them apart
M.WALL_KEEP_OFF = 3

function M.wall_outlines(walls)
	-- Every end at every node, per group
	local at = {}
	for id, w in pairs(walls) do
		local l = len(w.bx - w.ax, w.bz - w.az)
		if l > 0 then
			local ux, uz = (w.bx - w.ax) / l, (w.bz - w.az) / l
			local lo, ro = M.offsets(w.thickness, w.justify, w.shift)
			for _, e in ipairs({"a", "b"}) do
				local key = (w.group or 0) .. ":" .. w[e .. "_node"]
				at[key] = at[key] or {}
				local end_ = {id = id, e = e, x = w[e .. "x"], z = w[e .. "z"]}
				if e == "a" then
					end_.ux, end_.uz = ux, uz
					-- Seen leaving the node, left is the ccw side
					end_.ccw_off, end_.cw_off = lo, ro
				else
					end_.ux, end_.uz = -ux, -uz
					end_.ccw_off, end_.cw_off = ro, lo
				end
				table.insert(at[key], end_)
			end
		end
	end

	-- Each end's two corner points: ccw_pt on its ccw face, cw_pt on its
	-- cw face, and the node itself where three or more meet, which fills
	-- the hole a T or an X leaves in the middle
	local corners = {}
	for _, ends in pairs(at) do
		for _, en in ipairs(ends) do
			en.angle = math.atan2(en.uz, en.ux)
			-- A flat cap until a neighbour says otherwise
			en.ccw_pt = {en.x - en.uz * en.ccw_off, en.z + en.ux * en.ccw_off}
			en.cw_pt = {en.x + en.uz * en.cw_off, en.z - en.ux * en.cw_off}
		end
		table.sort(ends, function(p, q) return p.angle < q.angle end)
		local n = #ends
		if n >= 2 then
			for i = 1, n do
				local p = ends[i]
				local q = ends[i % n + 1]
				-- p's ccw face meets q's cw face
				local px, pz = p.x - p.uz * p.ccw_off, p.z + p.ux * p.ccw_off
				local qx, qz = q.x + q.uz * q.cw_off, q.z - q.ux * q.cw_off
				local ix, iz = intersect(px, pz, p.ux, p.uz, qx, qz, q.ux, q.uz)
				local limit = M.MITRE_LIMIT *
						math.max(p.ccw_off, q.cw_off, 1)
				if ix and len(ix - p.x, iz - p.z) <= limit then
					p.ccw_pt = {ix, iz}
					q.cw_pt = {ix, iz}
				end
			end
		end
		-- **A wall's end that would touch another's face at the node keeps
		-- off it** (user): where a wall is justified to one side, its face
		-- on that side runs through the node, and a wall joined there from
		-- its other side filled the T's hole right up to that face -- a
		-- line of its material on it. An end with both faces off the node,
		-- whose corners are further along it than the node, takes its node
		-- point WALL_KEEP_OFF back into itself; what that leaves is inside
		-- the walls.
		local face_through = false
		for _, en in ipairs(ends) do
			if en.ccw_off == 0 or en.cw_off == 0 then
				face_through = true
			end
		end
		for _, en in ipairs(ends) do
			local mid = n >= 3 and {en.x, en.z} or nil
			if mid and face_through and en.ccw_off > 0 and en.cw_off > 0 then
				local function along(p)
					return (p[1] - en.x) * en.ux + (p[2] - en.z) * en.uz
				end
				local k = M.WALL_KEEP_OFF
				if along(en.ccw_pt) > k and along(en.cw_pt) > k then
					mid = {en.x + en.ux * k, en.z + en.uz * k}
				end
			end
			corners[en.id] = corners[en.id] or {}
			corners[en.id][en.e] = {ccw = en.ccw_pt, cw = en.cw_pt, mid = mid}
		end
	end

	local out = {}
	for id, w in pairs(walls) do
		local c = corners[id]
		if c and c.a and c.b then
			-- At a, ccw is left and cw is right; at b the other way round
			local pts, sides = {}, {}
			local function add(p, side)
				pts[#pts + 1] = p
				sides[#sides + 1] = side
			end
			add(c.a.cw, "right")
			add(c.b.ccw, "core")
			if c.b.mid then
				add(c.b.mid, "core")
			end
			add(c.b.cw, "left")
			add(c.a.ccw, "core")
			if c.a.mid then
				add(c.a.mid, "core")
			end
			out[id] = {pts = pts, sides = sides}
		end
	end
	return out
end

-- Twice the signed area; positive when counter-clockwise
local function area2(pts)
	local a = 0
	for i = 1, #pts do
		local p, q = pts[i], pts[i % #pts + 1]
		a = a + cross(p[1], p[2], q[1], q[2])
	end
	return a
end

function M.area(pts)
	return math.abs(area2(pts)) / 2
end

-- Ear clipping. Returns triangles as index triples into pts, each
-- counter-clockwise; nothing for a degenerate polygon.
-- simplified: O(n^3), which is nothing for a wall and fine for a room;
-- a polygon of thousands of corners would want a better one.
function M.triangulate(pts)
	-- **A corner given twice is one corner** (user, a wall's top half
	-- missing): it has no area and no ear, and the fallback below took a
	-- real corner out with the half of the polygon it made
	local idx = {}
	for i = 1, #pts do
		local q = pts[idx[#idx] or #pts]
		if math.abs(pts[i][1] - q[1]) > 0.01 or math.abs(pts[i][2] - q[2]) > 0.01 then
			idx[#idx + 1] = i
		end
	end
	if area2(pts) < 0 then
		local r = {}
		for i = #idx, 1, -1 do
			r[#r + 1] = idx[i]
		end
		idx = r
	end
	local tris = {}
	local guard = 0
	while #idx > 3 and guard < 10000 do
		guard = guard + 1
		local found = false
		for i = 1, #idx do
			local ia, ib, ic = idx[(i - 2) % #idx + 1], idx[i], idx[i % #idx + 1]
			local a, b, c = pts[ia], pts[ib], pts[ic]
			local convex = cross(b[1] - a[1], b[2] - a[2],
					c[1] - b[1], c[2] - b[2]) > 1e-9
			if convex then
				local inside = false
				for _, j in ipairs(idx) do
					if j ~= ia and j ~= ib and j ~= ic then
						local p = pts[j]
						if cross(b[1] - a[1], b[2] - a[2], p[1] - a[1], p[2] - a[2]) >= 0 and
								cross(c[1] - b[1], c[2] - b[2], p[1] - b[1], p[2] - b[2]) >= 0 and
								cross(a[1] - c[1], a[2] - c[2], p[1] - c[1], p[2] - c[2]) >= 0 then
							inside = true
							break
						end
					end
				end
				if not inside then
					tris[#tris + 1] = {ia, ib, ic}
					table.remove(idx, i)
					found = true
					break
				end
			end
		end
		if not found then
			-- Collinear leftovers: drop the flattest corner and go on
			local flat, best = 1, math.huge
			for i = 1, #idx do
				local a = pts[idx[(i - 2) % #idx + 1]]
				local b, c = pts[idx[i]], pts[idx[i % #idx + 1]]
				local k = math.abs(cross(b[1] - a[1], b[2] - a[2],
						c[1] - b[1], c[2] - b[2]))
				if k < best then
					flat, best = i, k
				end
			end
			table.remove(idx, flat)
		end
	end
	if #idx == 3 and area2({pts[idx[1]], pts[idx[2]], pts[idx[3]]}) > 1e-9 then
		tris[#tris + 1] = {idx[1], idx[2], idx[3]}
	end
	return tris
end

-- The point on segment a-b nearest to p, its parameter t in 0..1 and the
-- distance to it
function M.nearest_on_segment(px, pz, ax, az, bx, bz)
	local dx, dz = bx - ax, bz - az
	local l2 = dx * dx + dz * dz
	local t = 0
	if l2 > 0 then
		t = math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / l2))
	end
	local x, z = ax + dx * t, az + dz * t
	return x, z, t, len(px - x, pz - z)
end

function M.point_in_polygon(px, pz, pts)
	local inside = false
	local j = #pts
	for i = 1, #pts do
		local a, b = pts[i], pts[j]
		if (a[2] > pz) ~= (b[2] > pz) and
				px < (b[1] - a[1]) * (pz - a[2]) / (b[2] - a[2]) + a[1] then
			inside = not inside
		end
		j = i
	end
	return inside
end

-- The polygon with each edge moved inward: offsets[i] for the edge from
-- pts[i] to pts[i + 1]. pts counter-clockwise; inward is then left.
function M.inset(pts, offsets)
	local n = #pts
	local lines = {}
	for i = 1, n do
		local p, q = pts[i], pts[i % n + 1]
		local l = len(q[1] - p[1], q[2] - p[2])
		local ux, uz = 0, 0
		if l > 0 then
			ux, uz = (q[1] - p[1]) / l, (q[2] - p[2]) / l
		end
		local o = offsets[i] or 0
		lines[i] = {x = p[1] - uz * o, z = p[2] + ux * o, ux = ux, uz = uz}
	end
	local out = {}
	for i = 1, n do
		local a, b = lines[(i - 2) % n + 1], lines[i]
		local x, z = intersect(a.x, a.z, a.ux, a.uz, b.x, b.z, b.ux, b.uz)
		out[i] = x and {x, z} or {b.x, b.z}
	end
	return out
end

function M.is_ccw(pts)
	return area2(pts) > 0
end

function M.centroid(pts)
	local a, cx, cz = 0, 0, 0
	for i = 1, #pts do
		local p, q = pts[i], pts[i % #pts + 1]
		local c = cross(p[1], p[2], q[1], q[2])
		a = a + c
		cx = cx + (p[1] + q[1]) * c
		cz = cz + (p[2] + q[2]) * c
	end
	if math.abs(a) < 1e-9 then
		return pts[1][1], pts[1][2]
	end
	return cx / (3 * a), cz / (3 * a)
end

-- The polygon clipped to the side of a line where nx * x + nz * z <= d.
-- labels[i] names the edge from pts[i]; an edge the clip makes is named
-- `cut`. Returns the points and their labels.
function M.clip(pts, labels, nx, nz, d, cut)
	local op, ol = {}, {}
	local n = #pts
	for i = 1, n do
		local p, q = pts[i], pts[i % n + 1]
		local dp = nx * p[1] + nz * p[2] - d
		local dq = nx * q[1] + nz * q[2] - d
		local function crossing()
			local t = dp / (dp - dq)
			return {p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t}
		end
		if dp <= 0 then
			op[#op + 1], ol[#ol + 1] = p, labels[i]
			if dq > 0 then
				op[#op + 1], ol[#ol + 1] = crossing(), cut
			end
		elseif dq <= 0 then
			op[#op + 1], ol[#ol + 1] = crossing(), labels[i]
		end
	end
	return op, ol
end

-- Where a ray from (ox, oz) along (ux, uz) crosses segment a-b: the ray's
-- parameter, or nil
function M.ray_segment(ox, oz, ux, uz, ax, az, bx, bz)
	local ex, ez = bx - ax, bz - az
	local d = cross(ux, uz, ex, ez)
	if math.abs(d) < 1e-9 then
		return nil
	end
	local t = cross(ax - ox, az - oz, ex, ez) / d
	local s = cross(ax - ox, az - oz, ux, uz) / d
	if t < 0 or s < 0 or s > 1 then
		return nil
	end
	return t
end

-- Urho3D's Quaternion(pitch, yaw, roll) on a vector, in degrees: roll about
-- Z first, then pitch about X, then yaw about Y
function M.rot(x, y, z, pitch, yaw, roll)
	local c, s = math.cos(math.rad(roll)), math.sin(math.rad(roll))
	x, y = x * c - y * s, x * s + y * c
	c, s = math.cos(math.rad(pitch)), math.sin(math.rad(pitch))
	y, z = y * c - z * s, y * s + z * c
	c, s = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
	x, z = x * c + z * s, -x * s + z * c
	return x, y, z
end

function M.unrot(x, y, z, pitch, yaw, roll)
	local c, s = math.cos(math.rad(-yaw)), math.sin(math.rad(-yaw))
	x, z = x * c + z * s, -x * s + z * c
	c, s = math.cos(math.rad(-pitch)), math.sin(math.rad(-pitch))
	y, z = y * c - z * s, y * s + z * c
	c, s = math.cos(math.rad(-roll)), math.sin(math.rad(-roll))
	x, y = x * c - y * s, x * s + y * c
	return x, y, z
end

function M.snap(v, step)
	return math.floor(v / step + 0.5) * step
end

-- The end point of a segment drawn from (ax, az) towards (px, pz), with its
-- angle snapped to multiples of step_deg (nil: free) and its length -- the
-- cursor's distance along that angle -- to multiples of len_step
function M.snap_direction(ax, az, px, pz, step_deg, len_step)
	local dx, dz = px - ax, pz - az
	if len(dx, dz) == 0 then
		return ax, az
	end
	local ang = math.atan2(dz, dx)
	if step_deg then
		local s = math.rad(step_deg)
		ang = math.floor(ang / s + 0.5) * s
	end
	local c, s = math.cos(ang), math.sin(ang)
	local l = math.max(len_step, M.snap(dx * c + dz * s, len_step))
	return ax + c * l, az + s * l
end

-- The walker, a cylinder of radius r standing at (x, z) with its feet at
-- `feet`, among solids {pts (counter-clockwise), y0, y1, floor}: pushed out
-- of what it would be in, then standing on the highest one under its
-- footprint that it can step onto (at most `step` up). A floor is only
-- stood on, never in the way. ground: the level with nothing on it, the
-- world's ground (0 when omitted). Returns x, z and the new feet.
-- simplified: it steps down at once rather than falling
function M.walk(list, x, z, feet, r, step, head, ground)
	-- The nearest point of a solid's outline, its distance, and whether
	-- (x, z) is inside it
	local function nearest(pts)
		local bd, bx, bz = math.huge, 0, 0
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local nx, nz, _, d = M.nearest_on_segment(x, z, p[1], p[2], q[1], q[2])
			if d < bd then
				bd, bx, bz = d, nx, nz
			end
		end
		return bx, bz, bd, M.point_in_polygon(x, z, pts)
	end
	for _ = 1, 4 do
		for _, sd in ipairs(list) do
			if not sd.floor and sd.y1 > feet + step and sd.y0 < feet + head then
				local bx, bz, bd, inside = nearest(sd.pts)
				if inside or bd < r then
					local dx, dz = x - bx, z - bz
					local l = math.max(len(dx, dz), 1e-6)
					if inside then
						dx, dz = -dx, -dz
					end
					x, z = bx + dx / l * r, bz + dz / l * r
				end
			end
		end
	end
	-- Under the whole footprint, not its middle: a stair's tread is
	-- narrower than the body, whose edge meets the riser after next before
	-- its middle is over the next
	ground = ground or 0
	for _, sd in ipairs(list) do
		if sd.y1 <= feet + step and sd.y1 > ground then
			local _, _, bd, inside = nearest(sd.pts)
			if inside or bd < r then
				ground = sd.y1
			end
		end
	end
	return x, z, ground
end

-- Stairs w wide, rising h over their depth d along +Z in n steps, as one
-- box a step, solid down to the bottom, about the stairs' middle:
-- {{x0, y0, z0, x1, y1, z1}, ...}
function M.stair_steps(w, h, d, n)
	local out = {}
	for k = 0, n - 1 do
		out[#out + 1] = {-w / 2, -h / 2, -d / 2 + k * d / n,
				w / 2, -h / 2 + (k + 1) * h / n, -d / 2 + (k + 1) * d / n}
	end
	return out
end

-- A polygon less the convex holes over it (all counter-clockwise), as the
-- polygons that are left: for each hole, the part outside each of its edges
-- that is inside the edges before it
-- simplified: clipping a concave polygon can leave pieces joined by a
-- zero-width sliver, which triangulate as nothing
function M.minus(pts, holes)
	local pieces = {pts}
	for _, hole in ipairs(holes) do
		local out = {}
		for _, piece in ipairs(pieces) do
			for i = 1, #hole do
				local a, b = hole[i], hole[i % #hole + 1]
				local l = len(b[1] - a[1], b[2] - a[2])
				if l > 0 then
					-- Outward of a counter-clockwise edge is to its right
					local nx, nz = (b[2] - a[2]) / l, -(b[1] - a[1]) / l
					local p = M.clip(piece, {}, -nx, -nz, -(nx * a[1] + nz * a[2]))
					for j = 1, i - 1 do
						local c, d = hole[j], hole[j % #hole + 1]
						local m = len(d[1] - c[1], d[2] - c[2])
						if m > 0 and #p >= 3 then
							local mx, mz = (d[2] - c[2]) / m, -(d[1] - c[1]) / m
							p = M.clip(p, {}, mx, mz, mx * c[1] + mz * c[2])
						end
					end
					if #p >= 3 and M.area(p) > 1 then
						out[#out + 1] = p
					end
				end
			end
		end
		pieces = out
	end
	return pieces
end

-- The convex hull, counter-clockwise (Andrew's monotone chain)
function M.hull(pts)
	local p = {}
	for i, q in ipairs(pts) do
		p[i] = q
	end
	table.sort(p, function(a, b)
		return a[1] < b[1] or a[1] == b[1] and a[2] < b[2]
	end)
	if #p < 3 then
		return p
	end
	local h = {}
	local function add(q, k0)
		while #h >= k0 + 2 and cross(h[#h][1] - h[#h - 1][1],
				h[#h][2] - h[#h - 1][2], q[1] - h[#h - 1][1],
				q[2] - h[#h - 1][2]) <= 0 do
			h[#h] = nil
		end
		h[#h + 1] = q
	end
	for i = 1, #p do
		add(p[i], 0)
	end
	local lower = #h
	for i = #p - 1, 1, -1 do
		add(p[i], lower - 1)
	end
	h[#h] = nil
	return h
end

-- [FP_NET_WALLS] A room's net floor: its inset polygon (counter-clockwise)
-- less the footprints over it, each by its convex hull. -> mm2
-- simplified: an outline that is not convex (an odd join) is cut by its
-- hull, a little too much; split it into convex parts if that shows
function M.net_area(inner, feet)
	local holes = {}
	for _, f in ipairs(feet) do
		local h = M.hull(f)
		if #h >= 3 then
			holes[#holes + 1] = h
		end
	end
	local a = 0
	for _, piece in ipairs(M.minus(inner, holes)) do
		a = a + M.area(piece)
	end
	return a
end

-- Which floor a walker is on, of floors {{id, y (its level), under (a
-- room of it is under the walker)}, ...} with its feet at `feet`: the id to
-- change to, or nil to stay on cur. Up to a floor over the walker once the
-- feet are within 200 mm below it, down once they are 300 mm below cur's,
-- and across to another building's rooms from outside cur's. The 100 mm
-- between is so a step at the threshold does not flip them.
function M.pick_floor(floors, cur, feet)
	local c, best
	for _, f in ipairs(floors) do
		if f.id == cur then
			c = f
		end
		if f.under and feet >= f.y - 200 and (not best or f.y > best.y) then
			best = f
		end
	end
	if not c or not best or best == c then
		return nil
	end
	if best.y > c.y + 1 or feet < c.y - 300 or not c.under then
		return best.id
	end
	return nil
end

--
-- Self-checks
--
local function near(a, b, what)
	assert(math.abs(a - b) < 1e-6, what .. ": " .. a .. " is not " .. b)
end

do
	-- An L of two 100 mm centred walls: the corner is square outside and in
	local o = M.wall_outlines({
		[1] = {ax = 0, az = 0, bx = 1000, bz = 0, a_node = 1, b_node = 2,
				thickness = 100, justify = 0},
		[2] = {ax = 0, az = 0, bx = 0, bz = 1000, a_node = 1, b_node = 3,
				thickness = 100, justify = 0},
	})
	local p = o[1].pts
	-- right face at a (below the line) reaches the outer corner
	near(p[1][1], -50, "L outer x")
	near(p[1][2], -50, "L outer z")
	-- left face at a meets the other wall's face: the inner corner
	near(p[4][1], 50, "L inner x")
	near(p[4][2], 50, "L inner z")
	near(M.area(p), 1000 * 100 - 50 * 50 + 50 * 50 - 50 * 50 + 50 * 50, "L area")
	do
		local lo, ro = M.offsets(120, 3, 200)
		assert(lo == 260 and ro == -140, "a custom justify off the wall")
		lo, ro = M.offsets(120, 3, -60)
		assert(lo == 0 and ro == 120, "a custom justify is right's at -60")
	end
	assert(#M.triangulate(p) == 2, "a wall's outline is two triangles")

	-- A T: the stem ends at the through walls' face, the node fills the rest
	local t = M.wall_outlines({
		[1] = {ax = 0, az = 0, bx = 1000, bz = 0, a_node = 1, b_node = 2,
				thickness = 100, justify = 0},
		[2] = {ax = 0, az = 0, bx = -1000, bz = 0, a_node = 1, b_node = 3,
				thickness = 100, justify = 0},
		[3] = {ax = 0, az = 0, bx = 0, bz = -1000, a_node = 1, b_node = 4,
				thickness = 100, justify = 0},
	})
	assert(#t[1].pts == 5, "a T's end carries the node")
	-- The through wall's top face runs straight over the node
	near(t[1].pts[4][2], 50, "T top face z")
	near(t[1].pts[4][1], 0, "T top face ends at the node")
	-- The stem's ends are the through walls' bottom corners
	local s = t[3].pts
	near(math.abs(s[4][1]), 50, "T stem corner x")
	near(s[4][2], -50, "T stem corner z")
	local total = M.area(t[1].pts) + M.area(t[2].pts) + M.area(t[3].pts)
	near(total, 2000 * 100 + 950 * 100, "T covers its footprint exactly once")

	-- An outset room wall, its face on the line inside the room (z > 0),
	-- and a centred wall joined to its middle from outside: the joined
	-- wall stops short of the room's face, and the room's wall still runs
	-- straight along it
	local ot = M.wall_outlines({
		[1] = {ax = 0, az = 0, bx = 1000, bz = 0, a_node = 1, b_node = 2,
				thickness = 200, justify = 2},
		[2] = {ax = 0, az = 0, bx = -1000, bz = 0, a_node = 1, b_node = 3,
				thickness = 200, justify = 1},
		[3] = {ax = 0, az = 0, bx = 0, bz = -1000, a_node = 1, b_node = 4,
				thickness = 100, justify = 0},
	})
	for _, q in ipairs(ot[3].pts) do
		assert(q[2] < -1,
				"the joined wall keeps off the room's face: z " .. q[2])
	end
	for _, w in ipairs({ot[1], ot[2]}) do
		local top = -math.huge
		for _, q in ipairs(w.pts) do
			top = math.max(top, q[2])
		end
		near(top, 0, "the room's face stays on the line")
	end
	-- and a plain centred T is as it was
	near(M.area(t[1].pts) + M.area(t[2].pts) + M.area(t[3].pts),
			2000 * 100 + 950 * 100, "T still covers its footprint")

	-- A wall on its own is its rectangle, left-justified above the line
	local r = M.wall_outlines({[1] = {ax = 0, az = 0, bx = 2000, bz = 0,
			a_node = 1, b_node = 2, thickness = 120, justify = 1}})
	near(M.area(r[1].pts), 2000 * 120, "lone wall area")
	near(r[1].pts[1][2], 0, "left-justified: the right face is on the line")
	near(r[1].pts[3][2], 120, "left-justified: the left face is 120 up")

	-- A concave polygon triangulates to its own area
	local u = {{0, 0}, {3, 0}, {3, 3}, {2, 3}, {2, 1}, {1, 1}, {1, 3}, {0, 3}}
	local sum = 0
	for _, tri in ipairs(M.triangulate(u)) do
		sum = sum + M.area({u[tri[1]], u[tri[2]], u[tri[3]]})
	end
	near(sum, M.area(u), "U triangulated")
	near(M.area(u), 7, "U area")

	local sq = {{0, 0}, {4000, 0}, {4000, 4000}, {0, 4000}}
	near(M.area(M.inset(sq, {50, 50, 50, 50})), 3900 * 3900, "inset square")
	near(M.area(M.inset(sq, {100, 0, 0, 0})), 3900 * 4000, "inset one side")
	local cx, cz = M.centroid(sq)
	near(cx, 2000, "centroid x")
	near(cz, 2000, "centroid z")

	-- A 4 by 4 square clipped to x <= 1 keeps a 1 by 4 strip, and the new
	-- edge is the clip's
	local cp, cl = M.clip(sq, {"a", "b", "c", "d"}, 1, 0, 1000, "cut")
	near(M.area(cp), 1000 * 4000, "clip area")
	local cuts = 0
	for _, l in ipairs(cl) do
		cuts = cuts + (l == "cut" and 1 or 0)
	end
	assert(cuts == 1 and #cp == 4, "clip makes one new edge")

	near(M.ray_segment(0, 0, 1, 0, 5, -1, 5, 1), 5, "ray meets segment")
	assert(M.ray_segment(0, 0, -1, 0, 5, -1, 5, 1) == nil, "ray points away")

	-- Yaw 90 turns +Z to +X, pitch 90 turns +Z down, and unrot undoes rot
	local rx, ry, rz = M.rot(0, 0, 1, 0, 90, 0)
	near(rx, 1, "yaw 90 x")
	near(rz, 0, "yaw 90 z")
	rx, ry, rz = M.rot(0, 0, 1, 90, 0, 0)
	near(ry, -1, "pitch 90 looks down")
	rx, ry, rz = M.rot(1, 2, 3, 90, 37, 180)
	rx, ry, rz = M.unrot(rx, ry, rz, 90, 37, 180)
	near(rx, 1, "unrot x")
	near(ry, 2, "unrot y")
	near(rz, 3, "unrot z")

	local x, z = M.snap_direction(0, 0, 1000, 800, 90, 10)
	near(x, 1000, "snap_direction projects onto the axis")
	near(z, 0, "snap_direction z")
end

do
	-- Ten stairs of 200 mm voxels, 200 mm treads, up to a landing: walked
	-- up in 20 mm strides. A 400 mm step alone is a wall.
	local list = {}
	local function cell(x0, z0, x1, z1, y0, y1, floor)
		list[#list + 1] = {pts = {{x0, z0}, {x1, z0}, {x1, z1}, {x0, z1}},
				y0 = y0, y1 = y1, floor = floor}
	end
	for k = 1, 10 do
		for cy = 0, k - 1 do
			cell(-400, k * 200, 400, k * 200 + 200, cy * 200, cy * 200 + 200)
		end
	end
	cell(-400, 2200, 400, 5000, 2000, 2000, true)
	local x, z, feet = 0, 0, 0
	for _ = 1, 200 do
		x, z, feet = M.walk(list, x, z + 20, feet, 250, 250, 1750)
	end
	near(feet, 2000, "walked up the stairs")
	assert(z > 3000, "walked up the stairs: stopped at z " .. z)
	list = {}
	cell(-400, 1000, 400, 1200, 0, 400)
	x, z, feet = 0, 0, 0
	for _ = 1, 100 do
		x, z, feet = M.walk(list, x, z + 20, feet, 250, 250, 1750)
	end
	near(feet, 0, "a 400 mm step")
	near(z, 750, "a 400 mm step stops the body")

	-- Parametric stairs, 3000 mm up in 15 steps over 3750 mm, their middle
	-- 2000 mm ahead: walked up onto the landing past them
	list = {}
	for _, b in ipairs(M.stair_steps(1000, 3000, 3750, 15)) do
		cell(b[1], b[3] + 2000, b[4], b[6] + 2000, b[2] + 1500, b[5] + 1500)
	end
	near(list[15].y1, 3000, "the top step")
	cell(-500, 3875, 500, 6000, 3000, 3000, true)
	x, z, feet = 0, -500, 0
	for _ = 1, 300 do
		x, z, feet = M.walk(list, x, z + 20, feet, 250, 250, 1750)
	end
	near(feet, 3000, "walked up the parametric stairs")

	-- Down from an upper floor at 0 into a stairwell whose stairs start a
	-- step below it, the world's ground 3000 mm down
	list = {}
	cell(-2000, -3000, 2000, 0, 0, 0, true)
	for k = 0, 13 do
		cell(-500, k * 250, 500, (k + 1) * 250, -3000, -200 - k * 200)
	end
	x, z, feet = 0, -1000, 0
	for _ = 1, 150 do
		x, z, feet = M.walk(list, x, z + 20, feet, 250, 250, 1750, -3000)
	end
	assert(feet < -1000, "walked down into the stairwell: feet at " .. feet)
end

do
	local function total(pieces)
		local a = 0
		for _, p in ipairs(pieces) do
			a = a + M.area(p)
		end
		return a
	end
	local room = {{0, 0}, {4000, 0}, {4000, 4000}, {0, 4000}}
	near(total(M.minus(room, {{{1000, 1000}, {2000, 1000}, {2000, 3000},
			{1000, 3000}}})), 14e6, "a stairwell in a room")
	near(total(M.minus(room, {{{5000, 0}, {6000, 0}, {6000, 1000},
			{5000, 1000}}})), 16e6, "a hole beside the room")
	near(total(M.minus(room, {{{3000, 3000}, {5000, 3000}, {5000, 5000},
			{3000, 5000}}})), 15e6, "a hole over a corner")
	near(total(M.minus(room, {{{1000, 1000}, {2000, 1000}, {2000, 2000},
			{1000, 2000}}, {{2500, 2500}, {3500, 2500}, {3500, 3500},
			{2500, 3500}}})), 14e6, "two holes")
end

do
	-- A floor at 0 and one at 3000 over it, as from the lower one
	local function fl(over)
		return {{id = 1, y = 0, under = true}, {id = 2, y = 3000, under = over}}
	end
	assert(M.pick_floor(fl(true), 1, 2700) == nil, "on the stairs, below")
	assert(M.pick_floor(fl(true), 1, 2800) == 2, "up at 200 mm below")
	assert(M.pick_floor(fl(false), 1, 3000) == nil, "no room over the walker")
	-- The same from the upper one, whose level is then 0
	local up = {{id = 1, y = -3000, under = true}, {id = 2, y = 0, under = true}}
	assert(M.pick_floor(up, 2, -200) == nil, "a step down stays up")
	assert(M.pick_floor(up, 2, -300) == nil, "300 mm down stays up")
	assert(M.pick_floor(up, 2, -301) == 1, "further down is the lower floor")
	-- Out of one building's rooms and into another's at the same level
	local side = {{id = 1, y = 0, under = false}, {id = 3, y = 0, under = true}}
	assert(M.pick_floor(side, 1, 0) == 3, "into the other building")
	assert(M.pick_floor({{id = 1, y = 0, under = false}}, 1, 0) == nil,
			"outside, nowhere to go")
end

-- [FP_NET_WALLS] A 4000 x 3000 room less a 100 x 2000 partition standing
-- in it: 0.2 m2; a wall reaching in from outside: its part inside; one
-- along the edge, outside the inset polygon: nothing
do
	local room = {{0, 0}, {4000, 0}, {4000, 3000}, {0, 3000}}
	near(M.net_area(room, {}), 12e6, "no walls")
	local part = {{1950, 500}, {2050, 500}, {2050, 2500}, {1950, 2500}}
	near(M.net_area(room, {part}), 12e6 - 0.2e6, "a partition")
	local reach = {{3000, 1450}, {5000, 1450}, {5000, 1550}, {3000, 1550}}
	near(M.net_area(room, {reach}), 12e6 - 0.1e6, "a wall reaching in")
	local edge = {{-50, -100}, {4050, -100}, {4050, 0}, {-50, 0}}
	near(M.net_area(room, {edge}), 12e6, "a wall outside the edge")
	near(M.net_area(room, {part, reach}), 12e6 - 0.3e6, "two")
	-- Clockwise or with a point inside, the hull is the same box
	local cw = {{1950, 500}, {1950, 2500}, {2000, 1500}, {2050, 2500},
			{2050, 500}}
	near(M.net_area(room, {cw}), 12e6 - 0.2e6, "a hull")
end

-- A corner given twice (two walls' outlines meeting at a room corner) or a
-- point on an edge still covers the whole polygon
do
	local function covered(pts)
		local s = 0
		for _, t in ipairs(M.triangulate(pts)) do
			s = s + M.area({pts[t[1]], pts[t[2]], pts[t[3]]})
		end
		return math.abs(s - M.area(pts)) < 1
	end
	assert(covered({{0, 0}, {4000, 0}, {4000, 0}, {4000, 100}, {0, 100}}),
			"a repeated corner")
	assert(covered({{0, 0}, {4000, 0}, {4000, 100}, {0, 100}, {0, 0}}),
			"a repeated corner at the wrap")
	assert(covered({{0, 0}, {2000, 0}, {4000, 0}, {4000, 100}, {0, 100}}),
			"a point on an edge")
	assert(covered({{0, 0}, {4000, 0}, {4000, 100}, {100, 100}, {100, 100},
			{100, 3000}, {0, 3000}}), "an L with a repeated corner")
end

return M
-- vim: set noet ts=4 sw=4:
