-- Buildat: apps/floorplanner/main/client_lua/tool_measure.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The Measure tool ([FP_EDITOR_MODULES]: out of editor.lua, the first in
-- E.tools): points clicked on the plan, each segment's length, the total,
-- and the area once closed. Its state is S.measure.
return function(E)
local S, M, geom, magic, grid_step = E.S, E.M, E.geom, E.magic, E.grid_step
local cursor_floor, snap_radius, nearest_node = E.cursor_floor, E.snap_radius, E.nearest_node
local node_pos, world_label, mm_text, m2 = E.node_pos, E.world_label, E.mm_text, E.m2

-- **The Measure tool's point** (a playtest, 2026-10-06): a node, a wall's
-- or an object's corner, a point on a wall's face or an object's edge,
-- within the snap radius in that order; else the grid. Ctrl: free.
local function point()
	local x, z = cursor_floor()
	if not x or S.ctrl then
		return x, z
	end
	local r = snap_radius()
	local n = nearest_node(x, z, r)
	if n then
		return node_pos(n)
	end
	local polys = {}
	for _, o in pairs(E.outlines) do
		polys[#polys + 1] = o.pts
	end
	for _, it in pairs(E.inst_data) do
		polys[#polys + 1] = not it.hosted and it.foot or nil
	end
	local bx, bz, bd = nil, nil, r
	for _, pts in ipairs(polys) do
		for _, p in ipairs(pts) do
			local d = geom.len(p[1] - x, p[2] - z)
			if d <= bd then
				bx, bz, bd = p[1], p[2], d
			end
		end
	end
	if bx then
		return bx, bz
	end
	for _, pts in ipairs(polys) do
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local px, pz, _, d = geom.nearest_on_segment(x, z, p[1], p[2], q[1], q[2])
			if d <= bd then
				bx, bz, bd = px, pz, d
			end
		end
	end
	if bx then
		return bx, bz
	end
	return geom.snap(x, grid_step()), geom.snap(z, grid_step())
end

-- Whether x, z closes the open measurement m: on its first point, with
-- three or more
local function closes(m, x, z)
	local f = m and not m.closed and m.pts[1]
	return f and #m.pts >= 3 and geom.len(x - f[1], z - f[2]) <= snap_radius()
end

E.tools.measure = {
	label = "Measure",
	viewer_ok = true,
	clear = function()
		S.measure = nil
	end,
	-- A point; the first again closes it; after closing, a new one
	press = function()
		local x, z = point()
		local m = S.measure
		if not m or m.closed then
			m = {pts = {}}
			S.measure = m
		end
		if x and closes(m, x, z) then
			m.closed = true
		elseif x then
			m.pts[#m.pts + 1] = {x, z}
		end
	end,
	escape = function()
		if S.measure then
			S.measure = nil
			return true
		end
	end,
	guide = function(g, hl)
		local x, z = point()
		local m = S.measure
		if not x then
			return
		end
		hl({kind = "point", x = x, z = z})
		local last = m and not m.closed and m.pts[#m.pts]
		if closes(m, x, z) then
			g.left = "close it to get the area"
		elseif last then
			g.left = "a point here, " .. mm_text(geom.len(x - last[1],
					z - last[2])) .. " on"
		else
			g.left = "measure from here"
		end
		g.note = m and "Esc: clear it" or "Ctrl: no snapping"
	end,
	-- Each segment's length on it, the total at the last point, the area
	-- inside when closed; to the pointer while open
	overlay = function(thick)
		local m = S.measure
		if not m then
			return
		end
		local pts = {}
		for i, p in ipairs(m.pts) do
			pts[i] = p
		end
		local px, pz = point()
		if not m.closed and px then
			pts[#pts + 1] = {px, pz}
		end
		local green, total = magic.Color(0.0, 0.65, 0.25), 0
		for i = 1, m.closed and #pts or #pts - 1 do
			local p, q = pts[i], pts[i % #pts + 1]
			local l = geom.len(q[1] - p[1], q[2] - p[2])
			total = total + l
			thick({p, q}, green)
			world_label((p[1] + q[1]) / 2, 0, (p[2] + q[2]) / 2, mm_text(l))
		end
		local last = pts[#pts]
		if m.closed then
			-- At the first point, off a room's label at its middle
			world_label(pts[1][1], 0, pts[1][2], "total " .. mm_text(total) ..
					", " .. m2(geom.area(pts)))
		elseif #pts > 2 then
			world_label(last[1], 0, last[2], "total " .. mm_text(total))
		end
	end,
}
E.tool_order[#E.tool_order + 1] = "measure"
end
-- vim: set noet ts=4 sw=4:
