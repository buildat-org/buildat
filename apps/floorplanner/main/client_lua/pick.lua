-- Buildat: apps/floorplanner/main/client_lua/pick.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The screen and the plan under the cursor: rays, picking a node, an
-- edge, an instance or a surface, and snapping a point
-- ([FP_EDITOR_MODULES]: out of editor.lua, over its E). Puts what the
-- rest calls in E.
return function(E)
local ANGLE_STEPS, FRAME_W, KIND, M = E.ANGLE_STEPS, E.FRAME_W, E.KIND, E.M
local S, SNAP_PX, W, cam3d = E.S, E.SNAP_PX, E.W, E.cam3d
local geom, grid_step, is_lamp, magic = E.geom, E.grid_step, E.is_lamp, E.magic
local node_pos, of_type, open_amount, room_at = E.node_pos, E.of_type, E.open_amount, E.room_at
local room_ceiling, wall_between, wall_span = E.room_ceiling, E.wall_between, E.wall_span

--
-- Screen and plan
--
-- [KIT_PHONE_EDITING] The view is the touch mode's world rect where it is
-- on (E.world_rect, pixels, shell.lua), else the window
local function screen_size()
	local r = E.world_rect
	if r then
		return r[3], r[4]
	end
	return magic.graphics.width, magic.graphics.height
end

-- A point of the window in the view's pixels
function E.world_xy(x, y)
	local r = E.world_rect
	if r then
		return x - r[1], y - r[2]
	end
	return x, y
end

-- **A field of view is of the screen's short side** (user, the sixth
-- round): the camera's is vertical, which on a portrait screen left a
-- slot. The degrees are the narrower of width and height; set each frame,
-- so a turned phone follows.
function M.fov_for(deg)
	local w, h = screen_size()
	if h <= w or w <= 0 then
		return deg
	end
	return math.deg(2 * math.atan(math.tan(math.rad(deg) / 2) * h / w))
end

-- Millimetres per pixel in the plan view
local function mm_per_px()
	local _, h = screen_size()
	return S.span / h
end

-- The ray under the cursor: origin and direction in world metres
local function cursor_ray()
	local w, h = screen_size()
	local mx, my = E.world_xy(S.mx, S.my)
	if S.view == "2d" then
		local x = S.cx + (mx / w - 0.5) * S.span * w / h
		local z = S.cz - (my / h - 0.5) * S.span
		return {x = W(x), y = 100, z = W(z)}, {x = 0, y = -1, z = 0}
	end
	local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
	local f = {x = math.sin(yaw) * math.cos(pitch), y = -math.sin(pitch),
			z = math.cos(yaw) * math.cos(pitch)}
	local r = {x = math.cos(yaw), y = 0, z = -math.sin(yaw)}
	local u = {x = math.sin(yaw) * math.sin(pitch), y = math.cos(pitch),
			z = math.cos(yaw) * math.sin(pitch)}
	local tan = math.tan(math.rad(cam3d.fov) / 2)
	local nx = (2 * mx / w - 1) * tan * w / h
	local ny = (1 - 2 * my / h) * tan
	if S.looking then
		nx, ny = 0, 0
	end
	local d = {x = f.x + r.x * nx + u.x * ny, y = f.y + r.y * nx + u.y * ny,
			z = f.z + r.z * nx + u.z * ny}
	return S.pos, d
end

-- Where the ray meets the horizontal plane at y mm: x, z in mm and the
-- ray's parameter; nil when it does not
local function ray_at_height(y)
	local o, d = cursor_ray()
	if math.abs(d.y) < 1e-9 then
		return nil
	end
	local t = (W(y) - o.y) / d.y
	if t <= 0 then
		return nil
	end
	return (o.x + d.x * t) * 1000, (o.z + d.z * t) * 1000, t
end

-- Where the cursor is on the floor, in mm; nil when looking above it
local function cursor_floor()
	local x, z = ray_at_height(0)
	return x, z
end

-- How far a pixel is on the floor where the cursor is, for snap radii
local function snap_radius()
	if S.view == "2d" then
		return M.px(SNAP_PX) * mm_per_px()
	end
	local x, z = cursor_floor()
	if not x then
		return 100
	end
	local dist = geom.len(x / 1000 - S.pos.x, z / 1000 - S.pos.z)
	dist = math.sqrt(dist * dist + S.pos.y * S.pos.y)
	local _, h = screen_size()
	return M.px(SNAP_PX) * dist * 1000 * 2 * math.tan(math.rad(cam3d.fov) / 2) / h
end



local function angle_step()
	return ANGLE_STEPS[S.angle] or 1
end

-- The node nearest to (x, z) within r, skipping those in `except`
local function nearest_node(x, z, r, except)
	local best, bd = nil, r
	for _, n in ipairs(of_type("node")) do
		if not (except and except[n.id]) then
			local nx, nz = node_pos(n.id)
			local d = geom.len(nx - x, nz - z)
			if d <= bd then
				best, bd = n.id, d
			end
		end
	end
	return best
end

-- The node of the wall join whose face corner is within r of (x, z), the
-- nearest corner's; nil if none
function M.corner_node(x, z, r, except)
	local best, bd = nil, r
	for id, o in pairs(E.outlines) do
		local w = E.wall_data[id]
		for _, p in ipairs(w and o.pts or {}) do
			local d = geom.len(p[1] - x, p[2] - z)
			if d <= bd then
				local n = geom.len(p[1] - w.ax, p[2] - w.az) <=
						geom.len(p[1] - w.bx, p[2] - w.bz) and w.a_node or w.b_node
				if not (except and except[n]) then
					best, bd = n, d
				end
			end
		end
	end
	return best
end

-- Every edge a point can land on: the walls, and the rooms' edges that have
-- no wall. {u, v, wall = id or nil}
local function edges()
	local out = {}
	for id, w in pairs(E.wall_data) do
		out[#out + 1] = {u = w.a_node, v = w.b_node, wall = id}
	end
	for _, r in pairs(E.room_data) do
		for i = 1, #r.ids do
			local u, v = r.ids[i], r.ids[i % #r.ids + 1]
			if not wall_between(u, v) then
				out[#out + 1] = {u = u, v = v}
			end
		end
	end
	return out
end

-- The edge nearest to (x, z) within r: the edge, the point on it and its
-- distance along it from u
local function nearest_edge(x, z, r, except)
	local best, bx, bz, bt = nil, 0, 0, 0
	local bd = r
	for _, e in ipairs(edges()) do
		if not (except and (except[e.u] or except[e.v])) then
			local ux, uz = node_pos(e.u)
			local vx, vz = node_pos(e.v)
			local px, pz, t, d = geom.nearest_on_segment(x, z, ux, uz, vx, vz)
			if d <= bd and t > 0 and t < 1 then
				best, bx, bz, bd = e, px, pz, d
				bt = t * geom.len(vx - ux, vz - uz)
			end
		end
	end
	return best, bx, bz, bt
end

-- Where the cursor's ray enters an instance's box, or nil
-- Whether a point on a wall (mm) is in one of its openings, doors or
-- windows: the wall is not there, whatever its outline says
local function in_hole(wall, x, y, z)
	for id, it in pairs(E.inst_data) do
		if it.hosted and E.doc.ents[id].ints.host == wall then
			local def = E.doc.ents[it.def].ints
			if def.kind ~= KIND.switch then
				local f = it.frame
				local along = (x - f.ax) * f.ux + (z - f.az) * f.uz
				local sill = E.doc.ents[id].ints.sill
				if math.abs(along - it.along) < def.w / 2 and y > sill and
						y < sill + def.h then
					return true
				end
			end
		end
	end
	return false
end

-- How far into an opening's edge its trim and frame stay pickable, mm
local HOLE_MARGIN = 40

-- id: the instance, for an opening or an open door: a ray through the hole
-- in the wall misses it and goes on to what is seen through it
-- A ray against a box from lo to hi, in the box's frame: where it enters,
-- or nil. These are on M: this file is at Lua's 200 locals.
function M.ray_box(ox, oy, oz, dx, dy, dz, lo, hi)
	local tmin, tmax = 0, math.huge
	for a, v in ipairs({{ox, dx}, {oy, dy}, {oz, dz}}) do
		if math.abs(v[2]) < 1e-12 then
			if v[1] < lo[a] or v[1] > hi[a] then
				return nil
			end
		else
			local t1, t2 = (lo[a] - v[1]) / v[2], (hi[a] - v[1]) / v[2]
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end

-- Where the ray meets one of a door's or a window's leaves first, or nil
function M.ray_leaves(it, o, d)
	local best = nil
	for _, lf in ipairs(it.leaves or {}) do
		local ox, oy, oz = geom.unrot(o.x - lf.x, o.y, o.z - lf.z, 0, lf.yaw, 0)
		local dx, dy, dz = geom.unrot(d.x, d.y, d.z, 0, lf.yaw, 0)
		local t = M.ray_box(ox, oy, oz, dx, dy, dz, lf.lo, lf.hi)
		if t and (not best or t < best) then
			best = t
		end
	end
	return best
end

-- The ray against an instance: where it enters, and "leaf" when that is a
-- door's or a window's leaf, which is outside the box once it swings
local function ray_instance(it, o, d, id)
	local leaf_t = it.hosted and M.ray_leaves(it, o, d)
	local t = M.ray_instance_box(it, o, d, id)
	-- A shut leaf is inside the frame's box, a little behind where the
	-- ray enters it: a leaf hit within a wall's depth of that is the leaf
	if leaf_t and (not t or leaf_t <= t + 0.4) then
		return leaf_t, "leaf"
	end
	return t
end

function M.ray_instance_box(it, o, d, id)
	local ox, oy, oz = geom.unrot(o.x - W(it.x), o.y - W(it.y), o.z - W(it.z),
			it.pitch, it.yaw, it.roll)
	local dx, dy, dz = geom.unrot(d.x, d.y, d.z, it.pitch, it.yaw, it.roll)
	local tmin, tmax = 0, math.huge
	for _, a in ipairs({{ox, dx, W(it.hx)}, {oy, dy, W(it.hy)},
			{oz, dz, W(it.hz)}}) do
		if math.abs(a[2]) < 1e-12 then
			if math.abs(a[1]) > a[3] then
				return nil
			end
		else
			local t1, t2 = (-a[3] - a[1]) / a[2], (a[3] - a[1]) / a[2]
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	local def = it.hosted and id and E.doc.ents[it.def].ints
	if def and (def.kind == KIND.opening or (def.kind == KIND.door and
			open_amount(id) > 0)) then
		-- Where the ray enters, in mm about the opening's middle: inside
		-- the hole less the margin is the hole; a door's hole goes down to
		-- the floor
		local lx = (ox + dx * tmin) * 1000
		local ly = (oy + dy * tmin) * 1000
		local hw, hh = def.w / 2 - HOLE_MARGIN, def.h / 2 - HOLE_MARGIN
		local floor = E.doc.ents[id].ints.sill == 0
		if math.abs(lx) < hw and ly < hh and (ly > -hh or floor) then
			return nil
		end
	end
	return tmin
end

-- What is under the cursor for painting and selecting: an instance, a
-- wall and which of its faces, or a room's floor or ceiling.
-- {kind = "instance"|"wall"|"floor"|"ceiling", id, side}
-- whole: an opening's hole is the opening's too, as the use key wants it
-- -- an open door is closed by pointing through it
-- accept(kind, id): what may be picked, the rest seen through (Select's
-- filter, M.sel_accept); all when nil
local function pick_surface(whole, accept)
	local function ok(kind, id)
		return not accept or accept(kind, id)
	end
	if S.view == "2d" then
		local x, z = cursor_floor()
		-- The topmost instance under the cursor, as seen from above
		local best, top = nil, -math.huge
		for id, it in pairs(E.inst_data) do
			if it.y1 > top and geom.point_in_polygon(x, z, it.foot) and
					ok("instance", id) then
				best, top = id, it.y1
			end
		end
		if best then
			return {kind = "instance", id = best}
		end
		for id, o in pairs(E.outlines) do
			if geom.point_in_polygon(x, z, o.pts) and ok("wall", id) then
				local w = E.wall_data[id]
				local side = (w.bx - w.ax) * (z - w.az) -
						(w.bz - w.az) * (x - w.ax) > 0 and "left" or "right"
				return {kind = "wall", id = id, side = side, x = x, z = z}
			end
		end
		for id, im in pairs(E.image_data) do
			if not im.locked and geom.point_in_polygon(x, z, im.foot) and
					ok("image", id) then
				return {kind = "image", id = id}
			end
		end
		local r = room_at(x, z)
		return r and ok("floor", r) and {kind = "floor", id = r} or nil
	end
	local o, d = cursor_ray()
	local best, best_t = nil, math.huge
	-- What hangs from the ceiling is drawn from above too, so it is
	-- picked from above too
	for id, it in pairs(E.inst_data) do
		local t, part = ray_instance(it, o, d, not whole and id or nil)
		if t and t < best_t and ok("instance", id) then
			-- A leaf is the door's leaf part, which a click selects
			best, best_t = {kind = "instance", id = id,
					side = part == "leaf" and "mat_leaf" or nil}, t
		end
	end
	for id, ol in pairs(E.outlines) do
		-- (an outline outlives its wall for the frame a plan is left in)
		local we = ok("wall", id) and E.doc.ents[id]
		local y0, y1 = 0, 0
		if we then
			y0, y1 = wall_span(we.ints)
		end
		y0, y1 = W(y0), W(y1)
		local pts = we and ol.pts or {}
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local px, pz, qx, qz = W(p[1]), W(p[2]), W(q[1]), W(q[2])
			-- The face's plane is vertical through p-q
			local nx, nz = qz - pz, -(qx - px)
			local denom = d.x * nx + d.z * nz
			if math.abs(denom) > 1e-9 then
				local t = ((px - o.x) * nx + (pz - o.z) * nz) / denom
				if t > 0 and t < best_t then
					local hx, hy, hz = o.x + d.x * t, o.y + d.y * t, o.z + d.z * t
					local _, _, _, dist = geom.nearest_on_segment(hx, hz,
							px, pz, qx, qz)
					if dist < 1e-4 and hy >= y0 and hy <= y1 and
							not in_hole(id, hx * 1000, hy * 1000, hz * 1000) then
						best, best_t = {kind = "wall", id = id,
								side = ol.sides[i], x = hx * 1000, z = hz * 1000}, t
					end
				end
			end
		end
		local hx, hz, t = ray_at_height(y1 * 1000)
		if hx and t < best_t and geom.point_in_polygon(hx, hz, pts) then
			best, best_t = {kind = "wall", id = id, side = "core", x = hx,
					z = hz}, t
		end
	end
	for id, r in pairs(E.room_data) do
		local surfaces = ok("floor", id) and {{"floor", 2}} or {}
		-- (the 3D pick: best_t is how far along the ray it is)
		-- A ceiling faces down and is seen only from under it
		if d.y > 0 and #surfaces > 0 then
			surfaces[2] = {"ceiling", room_ceiling(E.doc.ents[id])}
		end
		for _, s in ipairs(surfaces) do
			local hx, hz, t = ray_at_height(s[2])
			if hx and t < best_t and geom.point_in_polygon(hx, hz, r.pts) then
				best, best_t = {kind = s[1], id = id}, t
			end
		end
	end
	if best then
		best.t = best_t
	end
	return best
end

-- **The selection filter** (user, 2026-10-02, as KiCad's PCB editor
-- has): what of the plan Select picks, by click and by box, a check box a
-- kind in its panel while nothing is selected; what is not picked is
-- seen through. With no tool at all nothing is. The Material tool and
-- the snapping of the tools that draw go by everything. This client's,
-- kept in its storage as "<kind>=0" lines for what is off.
M.SEL_KINDS = {{"walls", "Walls"}, {"rooms", "Rooms"}, {"objects", "Objects"},
		{"lamps", "Lamps"}, {"wall_items", "Wall items"}, {"stairs", "Stairs"},
		{"voxels", "Voxels"}, {"pictures", "Pictures"}, {"nodes", "Nodes"}}
function M.sel_filter()
	if not M.sel_filter_on then
		M.sel_filter_on = {}
		for _, k in ipairs(M.SEL_KINDS) do
			M.sel_filter_on[k[1]] = true
		end
		for line in (buildat.storage_read("select_filter") or ""):gmatch("[^\n]+") do
			local k, v = line:match("^([%w_]+)=(%d)$")
			if k and M.sel_filter_on[k] ~= nil then
				M.sel_filter_on[k] = v == "1"
			end
		end
	end
	return M.sel_filter_on
end
function M.set_sel_filter(kind, on)
	local f = M.sel_filter()
	if kind then
		f[kind] = on
	else
		for k in pairs(f) do
			f[k] = on
		end
	end
	local lines = {}
	for _, k in ipairs(M.SEL_KINDS) do
		if not f[k[1]] then
			lines[#lines + 1] = k[1] .. "=0"
		end
	end
	buildat.storage_write("select_filter", table.concat(lines, "\n"))
	-- What is selected and no longer may be lets go
	M.sel_drop_filtered()
end
-- The filter's kind of a pick or a selection: kind as pick_surface or
-- S.sel has it
function M.sel_category(kind, id)
	if kind == "instance" then
		local e = E.doc.ents[id]
		local def = e and E.doc.ents[e.ints.def]
		local k = def and def.ints.kind
		if k == KIND.stairs then
			return "stairs"
		elseif k == KIND.voxel then
			return "voxels"
		elseif k and k ~= KIND.box then
			return "wall_items"
		end
		return is_lamp(id) and "lamps" or "objects"
	elseif kind == "wall" then
		return "walls"
	elseif kind == "image" then
		return "pictures"
	elseif kind == "node" then
		return "nodes"
	end
	return "rooms"
end
function M.sel_accept(kind, id)
	return S.tool == "select" and M.sel_filter()[M.sel_category(kind, id)]
end
function M.sel_drop_filtered()
	for id, k in pairs(S.sel) do
		if not M.sel_accept(k, id) then
			S.sel[id], S.sel_face[id] = nil, nil
		end
	end
	if S.primary and not S.sel[S.primary] then
		S.primary = next(S.sel)
	end
	S.dirty = true
	M.refresh_panels()
end

-- The cell of a volume under the cursor: the first voxel the ray enters
-- and the cell it came from, in the volume's own cells. With no voxel on
-- the way, the cell on the floor where the ray meets it, as the place.
local function voxel_ray(id)
	local it = E.inst_data[id]
	local o, d = cursor_ray()
	local sz = it.size
	local ox, oy, oz = geom.unrot((o.x - W(it.ox)) * 1000, (o.y - W(it.oy)) * 1000,
			(o.z - W(it.oz)) * 1000, it.pitch, it.yaw, it.roll)
	local dx, dy, dz = geom.unrot(d.x, d.y, d.z, it.pitch, it.yaw, it.roll)
	ox, oy, oz = ox / sz, oy / sz, oz / sz
	local vox = E.doc.voxels[E.doc.ents[id].ints.def] or {}
	-- Amanatides and Woo: from cell to cell along the ray
	local cell = {math.floor(ox), math.floor(oy), math.floor(oz)}
	local pos, dir = {ox, oy, oz}, {dx, dy, dz}
	local stepv, tmax, tdelta = {}, {}, {}
	for a = 1, 3 do
		if dir[a] > 0 then
			stepv[a] = 1
			tmax[a] = (cell[a] + 1 - pos[a]) / dir[a]
			tdelta[a] = 1 / dir[a]
		elseif dir[a] < 0 then
			stepv[a] = -1
			tmax[a] = (pos[a] - cell[a]) / -dir[a]
			tdelta[a] = -1 / dir[a]
		else
			stepv[a], tmax[a], tdelta[a] = 0, math.huge, math.huge
		end
	end
	local prev = nil
	for _ = 1, 600 do
		local inside = true
		for a = 1, 3 do
			inside = inside and cell[a] >= -128 and cell[a] <= 127
		end
		if inside and vox[E.doc.voxel_key(cell[1], cell[2], cell[3])] then
			return {cell[1], cell[2], cell[3]}, prev
		end
		prev = {cell[1], cell[2], cell[3]}
		local a = 1
		if tmax[2] < tmax[a] then a = 2 end
		if tmax[3] < tmax[a] then a = 3 end
		cell[a] = cell[a] + stepv[a]
		tmax[a] = tmax[a] + tdelta[a]
	end
	local x, z = cursor_floor()
	if not x then
		return nil
	end
	local lx, ly, lz = geom.unrot(x - it.ox, 1 - it.oy, z - it.oz, it.pitch,
			it.yaw, it.roll)
	return nil, {math.floor(lx / sz), math.floor(ly / sz), math.floor(lz / sz)}
end

-- **Imaginary cells past the volume** (user): the cell where the pointer's
-- ray meets the plane through cell `a` that faces the view most -- of the
-- volume's three axes, the one nearest the view's direction -- so a box
-- held on past the voxels goes on as a sheet in that plane. nil when the
-- ray runs along the plane or away from it.
function M.voxel_plane_cell(id, a)
	local it = E.inst_data[id]
	if not it then
		return nil
	end
	local o, d = cursor_ray()
	local sz = it.size
	local ox, oy, oz = geom.unrot((o.x - W(it.ox)) * 1000, (o.y - W(it.oy)) * 1000,
			(o.z - W(it.oz)) * 1000, it.pitch, it.yaw, it.roll)
	local dx, dy, dz = geom.unrot(d.x, d.y, d.z, it.pitch, it.yaw, it.roll)
	local p, v = {ox / sz, oy / sz, oz / sz}, {dx, dy, dz}
	-- The camera's own forward, for which plane faces it
	local f = {geom.rot(0, 0, 1, S.pitch, S.yaw, 0)}
	f = {geom.unrot(f[1], f[2], f[3], it.pitch, it.yaw, it.roll)}
	local ax = 1
	for k = 2, 3 do
		if math.abs(f[k]) > math.abs(f[ax]) then
			ax = k
		end
	end
	if math.abs(v[ax]) < 1e-6 then
		return nil
	end
	local t = (a[ax] + 0.5 - p[ax]) / v[ax]
	if t <= 0 then
		return nil
	end
	local c = {}
	for k = 1, 3 do
		c[k] = k == ax and a[ax] or math.floor(p[k] + v[k] * t)
	end
	for k = 1, 3 do
		if c[k] < -128 or c[k] > 127 then
			return nil
		end
	end
	return c
end

-- **Where along an edge a point snaps** (user, 2026-10-02: a corner put
-- on a wall could not make the wall drawn to it straight), the edge from
-- (ux, uz) to (vx, vz), l long, the pointer at et along it: where a line
-- from the point drawn from -- and, drawing a room, from its first
-- corner, which the last wall goes back to -- at a right angle crosses
-- it; else at the angle step (45 degrees, or Shift's); within the snap
-- radius r of the pointer each. Else where a grid line crosses it, the
-- nearest; else the grid's steps from its u end.
function M.along_edge(ux, uz, vx, vz, l, et, from, r)
	local ex, ez = (vx - ux) / l, (vz - uz) / l
	local anchors = {}
	if from then
		anchors[#anchors + 1] = from
	end
	local first = S.tool == "room" and S.corners and S.corners[1]
	if first and not (from and first.x == from.x and first.z == from.z) then
		anchors[#anchors + 1] = first
	end
	-- Where the line from p at angle a (degrees) crosses the edge's line
	local function cross_at(p, a)
		local dx, dz = math.cos(math.rad(a)), math.sin(math.rad(a))
		local den = ex * dz - ez * dx
		if math.abs(den) < 1e-9 then
			return nil
		end
		return ((p.x - ux) * dz - (p.z - uz) * dx) / den
	end
	local steps = {90}
	if S.shift or S.touch_angle then
		-- (free: none)
		steps[2] = ANGLE_STEPS[S.angle] or nil
	else
		steps[2] = 45
	end
	for _, step in ipairs(steps) do
		local best, bd = nil, r
		for _, p in ipairs(anchors) do
			for k = 0, math.floor(360 / step) - 1 do
				local t = cross_at(p, k * step)
				if t and t > 0 and t < l and math.abs(t - et) <= bd then
					best, bd = t, math.abs(t - et)
				end
			end
		end
		if best then
			return best
		end
	end
	-- The grid's lines, x and z, where they cross the edge
	local g = grid_step()
	local best, bd = nil, math.huge
	local px, pz = ux + ex * et, uz + ez * et
	for _, axis in ipairs({{ex, ux, px}, {ez, uz, pz}}) do
		local d, o, at = axis[1], axis[2], axis[3]
		if math.abs(d) > 1e-6 then
			for _, k in ipairs({math.floor(at / g), math.floor(at / g) + 1}) do
				local t = (k * g - o) / d
				if t > 0 and t < l and math.abs(t - et) < bd then
					best, bd = t, math.abs(t - et)
				end
			end
		end
	end
	if best then
		return best
	end
	return geom.snap(et, g)
end

-- Where a point the cursor gives lands: on a node, on an edge, or on the
-- grid. from: the point a segment is drawn from, for the angle snap.
-- Returns x, z and what it landed on: {node = id} or {edge = e, t = mm}.
local function snapped_point(from, except)
	local x, z = cursor_floor()
	if not x then
		return nil
	end
	local r = snap_radius()
	local n = nearest_node(x, z, r, except)
	-- **A wall's face corner takes the node of its join** while a room or
	-- a wall is drawn (a playtest, 2026-10-06): a room drawn at the walls'
	-- inner corners is on their nodes, its area to their faces (`net`),
	-- and a wall drawn to another's corner joins it there. Not for a drag,
	-- which would merge a node it went near.
	if not n and not S.drag and (S.tool == "room" or S.tool == "wall") then
		n = M.corner_node(x, z, r, except)
	end
	if n then
		local nx, nz = node_pos(n)
		return nx, nz, {node = n}
	end
	local e, _, _, et = nearest_edge(x, z, r, except)
	if e then
		local ux, uz = node_pos(e.u)
		local vx, vz = node_pos(e.v)
		local l = geom.len(vx - ux, vz - uz)
		local t = M.along_edge(ux, uz, vx, vz, l, et, from, r)
		t = math.max(1, math.min(l - 1, t))
		return math.floor(ux + (vx - ux) * t / l + 0.5),
				math.floor(uz + (vz - uz) * t / l + 0.5), {edge = e, t = t}
	end
	if from then
		-- Right angles, or with Shift or the touch bar's Angle the angle
		-- step, which may be free
		local step = 90
		if S.shift or S.touch_angle then
			step = ANGLE_STEPS[S.angle] or nil
		end
		local ex, ez = geom.snap_direction(from.x, from.z, x, z, step,
				grid_step())
		return math.floor(ex + 0.5), math.floor(ez + 0.5), {}
	end
	return geom.snap(x, grid_step()), geom.snap(z, grid_step()), {}
end

-- **A dragged node straightens its walls** (user): for each wall joined to
-- it, lines out of the wall's other end at every multiple of the angle
-- step (90 degrees when the angle is free). The pointer within a degree of
-- one -- or within the snap radius of it, which a short wall needs -- puts
-- the node on it, the wall's length snapped to the grid; near two walls'
-- lines, where they cross, both straight. Before the grid and after nodes
-- and edges; Ctrl gives it up. `ends`: the other ends, {{x, z}, ...}.
-- Returns x, z and the lines it used ({p = {x, z}, ux, uz}), or nil.
function M.angle_snap(x, z, ends)
	if S.ctrl or #ends == 0 then
		return nil
	end
	local step = ANGLE_STEPS[S.angle] or 90
	local r = snap_radius()
	local g = grid_step()
	local tol = math.tan(math.rad(1))
	local cands = {}
	for _, p in ipairs(ends) do
		local dx, dz = x - p[1], z - p[2]
		local l = geom.len(dx, dz)
		if l > 1 then
			-- The step's angle nearest, and the wall's own (p.own, radians):
			-- a node slides along its wall at any angle (a playtest,
			-- 2026-10-06)
			local angles = {math.rad(math.floor(math.deg(math.atan2(dz, dx)) /
					step + 0.5) * step), p.own}
			for _, a in ipairs(angles) do
				local ux, uz = math.cos(a), math.sin(a)
				local t = dx * ux + dz * uz
				local perp = math.abs(dx * uz - dz * ux)
				local cap = math.max(t * tol, r)
				if t > 0 and perp <= cap then
					cands[#cands + 1] = {p = p, ux = ux, uz = uz, t = t, perp = perp,
							cap = cap}
				end
			end
		end
	end
	if #cands == 0 then
		return nil
	end
	-- Two lines of different walls: where they cross, the nearest crossing
	-- the pointer is in both captures of
	local best, bd = nil, math.huge
	for i = 1, #cands do
		for j = i + 1, #cands do
			local a, b = cands[i], cands[j]
			local den = a.ux * b.uz - a.uz * b.ux
			if (a.p[1] ~= b.p[1] or a.p[2] ~= b.p[2]) and math.abs(den) > 1e-6 then
				local s = ((b.p[1] - a.p[1]) * b.uz - (b.p[2] - a.p[2]) * b.ux) / den
				local cx, cz = a.p[1] + a.ux * s, a.p[2] + a.uz * s
				local d = geom.len(cx - x, cz - z)
				if s > 0 and d <= math.min(a.cap, b.cap) and d < bd then
					best, bd = {cx, cz, a, b}, d
				end
			end
		end
	end
	if best then
		return math.floor(best[1] + 0.5), math.floor(best[2] + 0.5),
				{best[3], best[4]}
	end
	-- One line: on it, at a length of whole grid steps
	table.sort(cands, function(a, b) return a.perp < b.perp end)
	local c = cands[1]
	local t = math.max(g, geom.snap(c.t, g))
	return math.floor(c.p[1] + c.ux * t + 0.5), math.floor(c.p[2] + c.uz * t + 0.5),
			{c}
end

-- The gaps from an instance's footprint to the nearest wall face along its
-- own four axes: {{dir = {ux, uz}, half = mm, gap = mm}, ...}; gap is nil
-- where no wall is that way
-- **A door's, window's or opening's gaps along its wall** (a playtest,
-- 2026-10-06: measured from the nearest T, not the wall's end): each way,
-- from the hole's edge to the face of the nearest wall that meets this
-- one -- at a T or a corner, past a node that only splits a straight
-- wall -- where that face crosses this wall's line; the wall's end where
-- none meets it. {hw = the half width measured, {face = t, edge = t} for
-- the a way, then the b way}, t along the wall from its a end; nil if
-- it is not in a wall.
function M.opening_gaps(id)
	local it, e = E.inst_data[id], E.doc.ents[id]
	local def = e and E.doc.ents[e.ints.def]
	local f = it and it.frame
	local wd = e and E.wall_data[e.ints.host]
	if not (it and it.hosted and f and def and wd) then
		return nil
	end
	local hw = def.ints.w / 2
	-- From the glass's edges for a window measured by its glass
	if def.ints.kind == KIND.window and def.ints.measure == 1 then
		hw = hw - 2 * FRAME_W
	end
	local out = {hw = hw}
	for side, start in ipairs({{wd.a_node, -1}, {wd.b_node, 1}}) do
		local n, sign, from = start[1], start[2], e.ints.host
		local edge = it.along + sign * hw
		local face
		for _ = 1, 50 do
			local nx, nz = node_pos(n)
			local others = {}
			for wid, w in pairs(E.wall_data) do
				if wid ~= from and (w.a_node == n or w.b_node == n) then
					others[#others + 1] = wid
				end
			end
			-- One wall going on along the same line: on to its far end
			local w1 = #others == 1 and E.wall_data[others[1]]
			local o = w1 and (w1.a_node == n and w1.b_node or w1.a_node)
			local ox, oz = 0, 0
			if o then
				ox, oz = node_pos(o)
			end
			local dx, dz = ox - nx, oz - nz
			if o and math.abs(dx * f.uz - dz * f.ux) < 1 and
					(dx * f.ux + dz * f.uz) * sign > 0 then
				n, from = o, others[1]
			else
				face = (nx - f.ax) * f.ux + (nz - f.az) * f.uz
				-- The faces of the walls meeting here where they cross
				-- this one's line: the nearest to the hole on its side
				local best
				for _, wid in ipairs(others) do
					local w = E.wall_data[wid]
					local l = geom.len(w.bx - w.ax, w.bz - w.az)
					local vx, vz = (w.bx - w.ax) / l, (w.bz - w.az) / l
					local den = f.ux * vz - f.uz * vx
					if l > 0 and math.abs(den) > 1e-6 then
						local lo, ro = geom.offsets(w.thickness, w.justify, w.shift)
						for _, off in ipairs({lo, -ro}) do
							local px, pz = w.ax - vz * off, w.az + vx * off
							local t = ((px - f.ax) * vz - (pz - f.az) * vx) / den
							if (t - edge) * sign >= 0 and (not best or
									math.abs(t - edge) < math.abs(best - edge)) then
								best = t
							end
						end
					end
				end
				face = best or face
				break
			end
		end
		out[side] = {face = face or edge, edge = edge}
	end
	return out
end

local function wall_gaps(id)
	local it = E.inst_data[id]
	local out = {}
	for k, a in ipairs({{1, 0, it.ex}, {-1, 0, it.ex}, {0, 1, it.ez},
			{0, -1, it.ez}}) do
		local ux, _, uz = geom.rot(a[1], 0, a[2], 0, it.yaw, 0)
		local best = nil
		for _, o in pairs(E.outlines) do
			local pts = o.pts
			for i = 1, #pts do
				local p, q = pts[i], pts[i % #pts + 1]
				local t = geom.ray_segment(it.x, it.z, ux, uz, p[1], p[2],
						q[1], q[2])
				if t and t > a[3] / 2 and (not best or t < best) then
					best = t
				end
			end
		end
		out[k] = {dir = {ux, uz}, half = a[3] / 2,
				gap = best and best - a[3] / 2}
	end
	return out
end

E.screen_size, E.mm_per_px, E.cursor_ray, E.ray_at_height = screen_size, mm_per_px, cursor_ray, ray_at_height
E.cursor_floor, E.snap_radius, E.angle_step, E.nearest_node = cursor_floor, snap_radius, angle_step, nearest_node
E.pick_surface, E.voxel_ray, E.snapped_point, E.wall_gaps = pick_surface, voxel_ray, snapped_point, wall_gaps
end
-- vim: set noet ts=4 sw=4:
