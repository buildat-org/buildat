-- Buildat: apps/floorplanner/main/client_lua/overlay.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- What is drawn over the scene each frame: the plan's lines, the grid,
-- the selection, the guides, the other users ([FP_EDITOR_MODULES]: out
-- of editor.lua, over its E). Answers draw_overlay.
return function(E)
local S, M, magic, geom, scene, debug = E.S, E.M, E.magic, E.geom, E.scene,
		E.debug
local place, BODY_R, HEAD = E.place, E.BODY_R, E.HEAD
local W, settings, mm_per_px, grid_step = E.W, E.settings, E.mm_per_px, E.grid_step
local screen_size, flat_material, world_label, m2 = E.screen_size, E.flat_material, E.world_label, E.m2
local wall_span, plan_symbol, draw_guide, mm_text = E.wall_span, E.plan_symbol, E.draw_guide, E.mm_text
local room_ceiling, wall_gaps, crosshair, user_color = E.room_ceiling, E.wall_gaps, E.crosshair, E.user_color
local of_type, node_pos, over_ui, snapped_point = E.of_type, E.node_pos, E.over_ui, E.snapped_point

-- **What the plan view draws that changes only with the plan or the zoom**
-- (user, 2026-10-01: panning a big plan in Firefox was slow; the dashes
-- over what is above the cut alone were some 2000 debug lines a frame,
-- each two sandboxed vectors): the walls and objects above the cut, the
-- objects' outlines and the doors' and windows' symbols, as a line list on
-- a node, made again when the plan, the zoom, the cut or the floor edited
-- change. Drawn a frame at a time as before during a drag that moves
-- things without a rebuild (not a box selection's).
local plan_lines_node = scene:CreateChild("PlanLines")
-- And the grid, over three times the view each way, made again when the
-- view leaves that or the step changes
local grid_node = scene:CreateChild("PlanGrid")
-- And the branch point's ghost ([FP_GHOST])
local ghost_node = scene:CreateChild("PlanGhost")
-- And the selection's outlines (draw_overlay)
M.sel_lines_node = scene:CreateChild("SelLines")
M.build_gen = 0
M.sel_gen = 0

local function draw_overlay()
	local y = S.view == "2d" and W(settings().cut) - 0.001 or 0.004
	plan_lines_node.enabled = false
	grid_node.enabled = false
	ghost_node.enabled = false
	M.sel_lines_node.enabled = false
	local function P(x, z, yy)
		return magic.Vector3(W(x), yy or y, W(z))
	end
	-- Where the lines go instead of the debug renderer, while one is set
	local sink
	local function line(ax, az, bx, bz, col)
		if sink then
			return sink(ax, az, bx, bz, col)
		end
		debug:AddLine(P(ax, az), P(bx, bz), col, false)
	end
	local function dashed(pts, col, ln)
		ln = ln or line
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local l = geom.len(q[1] - p[1], q[2] - p[2])
			local n = math.max(1, math.floor(l / (6 * mm_per_px())))
			for j = 0, n - 1, 2 do
				ln(p[1] + (q[1] - p[1]) * j / n, p[2] + (q[2] - p[2]) * j / n,
						p[1] + (q[1] - p[1]) * (j + 1) / n,
						p[2] + (q[2] - p[2]) * (j + 1) / n, col)
			end
		end
	end
	local function outline(pts, col, ys)
		for _, yy in ipairs(ys or {y}) do
			for i = 1, #pts do
				local p, q = pts[i], pts[i % #pts + 1]
				if sink and yy == y then
					sink(p[1], p[2], q[1], q[2], col)
				else
					debug:AddLine(P(p[1], p[2], yy), P(q[1], q[2], yy), col, false)
				end
			end
		end
	end
	-- **A selection's lines thicker** in the plan view (a playtest,
	-- 2026-10-06): each three times, a pixel apart across it
	local function thick(pts, col, ys)
		if S.view ~= "2d" then
			return outline(pts, col, ys)
		end
		local k = mm_per_px()
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local l = geom.len(q[1] - p[1], q[2] - p[2])
			if l > 0 then
				local nx, nz = -(q[2] - p[2]) / l * k, (q[1] - p[1]) / l * k
				for o = -1, 1 do
					line(p[1] + nx * o, p[2] + nz * o, q[1] + nx * o, q[2] + nz * o,
							col)
				end
			end
		end
	end
	local dark = magic.Color(0.2, 0.2, 0.25)
	-- The grid, in the plan view: the snap step where it is at least 8
	-- pixels, coarser where it is not, and every metre darker
	if S.view == "2d" then
		local k = mm_per_px()
		local step = grid_step()
		while step / k < 8 do
			step = step * 10
		end
		local w, h = screen_size()
		local x0, x1 = S.cx - S.span * w / h / 2, S.cx + S.span * w / h / 2
		local z0, z1 = S.cz - S.span / 2, S.cz + S.span / 2
		local fine = magic.Color(0.62, 0.62, 0.62)
		local major = magic.Color(0.45, 0.45, 0.48)
		-- 30 mm up, over the floors (2 mm) by enough for a 16 bit depth
		-- buffer over the plan camera's 100 m (a browser's may be; user:
		-- the grid went under the floors in Firefox when it became
		-- geometry, where the debug lines drawn last had won the tie); the
		-- camera looks straight down, so the height shows nowhere else
		local gy = 0.03
		local g = M.grid_cache
		if not (g and g.step == step and x0 >= g.x0 and x1 <= g.x1 and
				z0 >= g.z0 and z1 <= g.z1) then
			local dx, dz = x1 - x0, z1 - z0
			g = {step = step, x0 = x0 - dx, x1 = x1 + dx, z0 = z0 - dz,
					z1 = z1 + dz}
			M.grid_cache = g
			local out = {}
			local function add(ax, az, bx, bz, c)
				local k = #out
				out[k + 1], out[k + 2], out[k + 3] = W(ax), gy, W(az)
				out[k + 4], out[k + 5], out[k + 6], out[k + 7] = c.r, c.g, c.b, 1
				out[k + 8], out[k + 9], out[k + 10] = W(bx), gy, W(bz)
				out[k + 11], out[k + 12], out[k + 13], out[k + 14] = c.r, c.g, c.b, 1
			end
			for gx = math.floor(g.x0 / step) * step, g.x1, step do
				add(gx, g.z0, gx, g.z1, gx % 1000 == 0 and major or fine)
			end
			for gz = math.floor(g.z0 / step) * step, g.z1, step do
				add(g.x0, gz, g.x1, gz, gz % 1000 == 0 and major or fine)
			end
			buildat.set_line_geometry(grid_node, out)
			grid_node:GetComponent("CustomGeometry"):SetMaterial(0,
					flat_material)
		end
		grid_node.enabled = true
		-- **The branch point's ghost** ([FP_GHOST]): its walls' outlines
		-- and its rooms' edges on this layout (matched by id), one faded
		-- colour, just over the floors so the plan's own walls cover it;
		-- nothing picks or snaps to it, and 3D draws none of it
		-- simplified: no doors, windows or objects of it
		local gh = E.doc.ghost
		if gh then
			local key = E.doc.ghost_gen .. ":" .. tostring(S.layout)
			if key ~= M.ghost_key then
				M.ghost_key = key
				local function on(id)
					local n = gh[id]
					return n and n.type == "node" and n.ints.layout == S.layout and
							n.ints
				end
				local walls, segs = {}, {}
				local function poly(pts)
					for i = 1, #pts do
						local p, q = pts[i], pts[i % #pts + 1]
						segs[#segs + 1] = {p[1], p[2], q[1], q[2]}
					end
				end
				for id, e in pairs(gh) do
					local a, b = on(e.ints.a), on(e.ints.b)
					if e.type == "wall" and a and b then
						walls[id] = {ax = a.x, az = a.z, bx = b.x, bz = b.z,
								a_node = e.ints.a, b_node = e.ints.b,
								thickness = e.ints.thickness,
								justify = e.ints.justify, shift = e.ints.shift,
								group = wall_span(e.ints) > 0 and 1 or 0}
					elseif e.type == "room" and e.lists.nodes then
						local pts = {}
						for _, nid in ipairs(e.lists.nodes) do
							local n = on(nid)
							if not n then
								pts = {}
								break
							end
							pts[#pts + 1] = {n.x, n.z}
						end
						poly(pts)
					end
				end
				for _, o in pairs(geom.wall_outlines(walls)) do
					poly(o.pts)
				end
				M.ghost_segs = segs
				M.ghost_built = false
			end
			local col = magic.Color(0.25, 0.4, 0.9, 0.55)
			local gy = 0.035
			if not M.ghost_built then
				M.ghost_built = true
				local out = {}
				for _, sg in ipairs(M.ghost_segs) do
					for j = 0, 1 do
						local k = #out
						out[k + 1], out[k + 2], out[k + 3] =
								W(sg[1 + 2 * j]), gy, W(sg[2 + 2 * j])
						out[k + 4], out[k + 5], out[k + 6], out[k + 7] =
								col.r, col.g, col.b, col.a
					end
				end
				buildat.set_line_geometry(ghost_node, out)
				ghost_node:GetComponent("CustomGeometry"):SetMaterial(0,
						flat_material)
			end
			ghost_node.enabled = true
		end
		-- The rooms' names and areas
		for id, r in pairs(E.room_data) do
			local cx, cz = geom.centroid(r.pts)
			world_label(cx, 0, cz, E.doc.ents[id].strs.name .. "\n" .. m2(r.net))
		end
		-- What is above the cut, dashed; the objects below it outlined
		local cut = settings().cut
		local function plan_lines(ln)
			for id, o in pairs(E.outlines) do
				if wall_span(E.doc.ents[id].ints) >= cut then
					dashed(o.pts, dark, ln)
				end
			end
			for id, it in pairs(E.inst_data) do
				if it.hosted then
					plan_symbol(id, it, ln)
				elseif it.y0 >= cut then
					dashed(it.foot, dark, ln)
				else
					for i = 1, #it.foot do
						local p, q = it.foot[i], it.foot[i % #it.foot + 1]
						ln(p[1], p[2], q[1], q[2], dark)
					end
				end
			end
		end
		if not (S.drag and S.drag.kind ~= "box") then
			local key = M.build_gen .. ":" .. mm_per_px() .. ":" .. cut ..
					":" .. tostring(S.layout) .. ":" .. S.plan_look
			if key ~= M.plan_lines_key then
				M.plan_lines_key = key
				local out = {}
				plan_lines(function(ax, az, bx, bz, c)
					local k = #out
					out[k + 1], out[k + 2], out[k + 3] = W(ax), y, W(az)
					out[k + 4], out[k + 5], out[k + 6], out[k + 7] = c.r, c.g, c.b, c.a
					out[k + 8], out[k + 9], out[k + 10] = W(bx), y, W(bz)
					out[k + 11], out[k + 12], out[k + 13], out[k + 14] =
							c.r, c.g, c.b, c.a
				end)
				buildat.set_line_geometry(plan_lines_node, out)
				plan_lines_node:GetComponent("CustomGeometry"):SetMaterial(0,
						flat_material)
			end
			plan_lines_node.enabled = true
		else
			plan_lines(line)
		end
	end
	local accent = magic.Color(1.0, 0.6, 0.1)
	-- **The selection's outlines, kept on a node** in the plan view while
	-- nothing is dragged ([FRAME_WORK]): a wall's outline three times over
	-- was some 60 sandboxed lines, over a millisecond a frame
	local sel_out, sel_kept
	if S.view == "2d" and not S.drag then
		local ks = {}
		for id, kind in pairs(S.sel) do
			ks[#ks + 1] = id .. kind
		end
		table.sort(ks)
		local key = M.build_gen .. ":" .. mm_per_px() .. ":" .. y .. ":" ..
				tostring(S.layout) .. ":" .. table.concat(ks, " ")
		sel_kept = key == M.sel_lines_key
		if not sel_kept then
			M.sel_lines_key, sel_out = key, {}
		end
		M.sel_lines_node.enabled = true
	else
		M.sel_lines_key = nil
	end
	local function sel(fn, ...)
		if sel_kept then
			return
		end
		sink = sel_out and function(ax, az, bx, bz, c)
			local k = #sel_out
			sel_out[k + 1], sel_out[k + 2], sel_out[k + 3] = W(ax), y, W(az)
			sel_out[k + 4], sel_out[k + 5], sel_out[k + 6], sel_out[k + 7] =
					c.r, c.g, c.b, 1
			sel_out[k + 8], sel_out[k + 9], sel_out[k + 10] = W(bx), y, W(bz)
			sel_out[k + 11], sel_out[k + 12], sel_out[k + 13], sel_out[k + 14] =
					c.r, c.g, c.b, 1
		end
		fn(...)
		sink = nil
	end
	for id, kind in pairs(S.sel) do
		if kind == "wall" and E.outlines[id] then
			local y0, y1 = wall_span(E.doc.ents[id].ints)
			sel(thick, E.outlines[id].pts, accent, S.view ~= "2d" and
					{W(y0) + 0.004, W(y1) + 0.004} or nil)
			-- The face it was selected by, brighter
			if S.sel_face[id] then
				draw_guide({hl = {{kind = "face", id = id, side = S.sel_face[id],
						col = magic.Color(1.0, 0.95, 0.4)}}}, P, line, outline)
			end
			local w = E.wall_data[id]
			world_label((w.ax + w.bx) / 2, 0, (w.az + w.bz) / 2,
					mm_text(geom.len(w.bx - w.ax, w.bz - w.az)))
		elseif kind == "room" and E.room_data[id] then
			sel(thick, E.room_data[id].pts, accent, S.sel_face[id] == "ceiling" and
					S.view ~= "2d" and {W(room_ceiling(E.doc.ents[id])) - 0.004} or nil)
			sel(outline, E.room_data[id].inner, magic.Color(0.2, 0.6, 1.0))
		elseif kind == "image" and E.image_data[id] then
			sel(thick, E.image_data[id].foot, accent)
		elseif kind == "instance" and E.inst_data[id] then
			local it = E.inst_data[id]
			sel(thick, it.foot, accent, S.view ~= "2d" and
					{W(it.y0) + 0.004, W(it.y1) + 0.004} or nil)
		end
	end
	if sel_out then
		buildat.set_line_geometry(M.sel_lines_node, sel_out)
		M.sel_lines_node:GetComponent("CustomGeometry"):SetMaterial(0,
				flat_material)
	end
	-- **The rooms on a dragged node, outlined** (a playtest, 2026-10-06)
	local dg = S.drag
	if dg and (dg.kind == "node" or dg.kind == "move" and next(dg.nodes)) then
		for id, r in pairs(E.room_data) do
			local e = E.doc.ents[id]
			for _, n in ipairs(e and e.lists.nodes or {}) do
				if (dg.kind == "node" and n == dg.id) or
						(dg.kind == "move" and dg.nodes[n]) then
					outline(r.pts, magic.Color(1.0, 0.8, 0.3))
					break
				end
			end
		end
	end
	-- The calibration's two points
	if S.calib then
		local c = S.calib
		for i, p in ipairs(c.pts) do
			debug:AddCross(P(p[1], p[2]), W(10 * mm_per_px()), accent, false)
			if i == 2 then
				line(c.pts[1][1], c.pts[1][2], p[1], p[2], accent)
			end
		end
	end
	-- A switch's lamps, joined to it by dashed lines
	local sw = S.primary and E.doc.ents[S.primary]
	if sw and sw.type == "instance" and #sw.lists.lamps > 0 and E.inst_data[sw.id] then
		local a = E.inst_data[sw.id]
		for _, l in ipairs(sw.lists.lamps) do
			local b = E.inst_data[l]
			if b then
				dashed({{a.x, a.z}, {b.x, b.z}}, magic.Color(0.9, 0.7, 0.1))
			end
		end
	end
	-- The primary object's gaps to the walls
	if S.primary and S.sel[S.primary] == "instance" and E.inst_data[S.primary] and
			not E.inst_data[S.primary].hosted and not S.drag then
		local it = E.inst_data[S.primary]
		for _, g in ipairs(wall_gaps(S.primary)) do
			if g.gap and g.gap > 0 then
				local ax, az = it.x + g.dir[1] * g.half, it.z + g.dir[2] * g.half
				local bx, bz = ax + g.dir[1] * g.gap, az + g.dir[2] * g.gap
				line(ax, az, bx, bz, magic.Color(0.2, 0.6, 1.0))
				world_label((ax + bx) / 2, 0, (az + bz) / 2, mm_text(g.gap))
			end
		end
	end
	-- The lines a dragged node was straightened onto (M.angle_snap), each
	-- wall's angle and length on it
	if S.drag and S.drag.kind == "node" and S.drag.angle_lines and S.drag.x then
		local d = S.drag
		for _, c in ipairs(d.angle_lines) do
			dashed({{c.p[1], c.p[2]}, {d.x, d.z}}, magic.Color(1.0, 0.55, 0.1))
			local a = math.deg(math.atan2(d.z - c.p[2], d.x - c.p[1]))
			world_label((c.p[1] + d.x) / 2, 0, (c.p[2] + d.z) / 2,
					string.format("%d deg, ", math.floor((a % 360) + 0.5) % 360) ..
					mm_text(geom.len(d.x - c.p[1], d.z - c.p[2])))
		end
	end
	-- **A door, window or opening moved along its wall, or selected**
	-- (user; a playtest, 2026-10-06): what is left of the wall each way,
	-- from the hole's edge to the nearest wall meeting this one
	-- (M.opening_gaps), numbered as the panel's Gap fields are
	local dr = S.drag
	local shown = {}
	if dr and dr.kind == "move" and dr.moved and dr.inst then
		shown = dr.inst
	elseif not dr and S.primary and S.sel[S.primary] == "instance" then
		shown = {[S.primary] = true}
	end
	for id in pairs(shown) do
		local g = M.opening_gaps(id)
		local f = g and E.inst_data[id].frame
		for k = 1, g and 2 or 0 do
			local a, b = g[k].face, g[k].edge
			if (b - a) * (k == 1 and 1 or -1) > 0 then
				local t = (a + b) / 2
				local blue = magic.Color(0.2, 0.6, 1.0)
				line(f.ax + f.ux * a, f.az + f.uz * a, f.ax + f.ux * b,
						f.az + f.uz * b, blue)
				world_label(f.ax + f.ux * t, 0, f.az + f.uz * t,
						k .. ": " .. mm_text(math.abs(b - a)))
			end
		end
	end
	-- A new selection, by what is in it, for doc.merge_tag
	local ids = {}
	for id in pairs(S.tool == "node" and S.nodes or S.sel) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	local key = table.concat(ids, " ")
	if key ~= M.sel_key then
		M.sel_key, M.sel_gen = key, M.sel_gen + 1
	end
	-- **How far the selected thing has moved since it was selected** (user,
	-- 2026-10-06), by drags and the movement keys alike, in X and Z
	local pk = S.primary and S.sel[S.primary]
	local px, pz
	if pk then
		px, pz = M.sel_pos(S.primary, pk)
	end
	local so = M.sel_origin
	if not px then
		M.sel_origin = nil
	elseif not so or so.id ~= S.primary then
		M.sel_origin = {id = S.primary, x = px, z = pz}
	else
		local dx, dz = px - so.x, pz - so.z
		if math.abs(dx) >= 0.5 or math.abs(dz) >= 0.5 then
			-- Off the middle, where a wall's length and a door's gap are
			world_label(px, 0, pz + M.px(40), string.format("X %+d mm\nZ %+d mm",
					math.floor(dx + 0.5), math.floor(dz + 0.5)))
		end
	end
	-- The registered tools' own drawing
	local tl = S.tool and E.tools[S.tool]
	if tl and tl.overlay then
		tl.overlay(thick)
	end
	-- The voxel tool's and walking's crosshair, and what the pointer is on
	crosshair.visible = S.captured or false
	draw_guide(S.guide, P, line, outline)
	-- The others: their cursors, their cameras, what they have selected
	for _, o in pairs(E.doc.others) do
		local p = o.p and place.presence(o.p, true)
		if p and o.name then
			local col = user_color(o.name)
			local size = S.view == "2d" and W(10 * mm_per_px()) or 0.15
			if p.view == 1 then
				-- Their camera, as a small frustum where it is
				local ex = magic.Vector3(W(p.px), W(p.py), W(p.pz))
				local function at(fx, fy)
					local x, y, z = geom.rot(fx * 0.3, fy * 0.2, 0.5, p.pitch / 1000,
							p.yaw / 1000, 0)
					return magic.Vector3(ex.x + x, ex.y + y, ex.z + z)
				end
				local c = {at(-1, -1), at(1, -1), at(1, 1), at(-1, 1)}
				for i = 1, 4 do
					debug:AddLine(ex, c[i], col, false)
					debug:AddLine(c[i], c[i % 4 + 1], col, false)
				end
				world_label(p.px, S.view ~= "2d" and p.py or 0, p.pz, o.name)
				if p.view == 2 then
					-- Walking: a body under the eyes
					local feet = p.py - S.eye
					local ring = {}
					for k = 0, 11 do
						local a = k / 12 * math.pi * 2
						ring[k + 1] = {p.px + math.cos(a) * BODY_R,
								p.pz + math.sin(a) * BODY_R}
					end
					outline(ring, col, S.view == "2d" and {y} or
							{W(feet) + 0.004, W(feet + HEAD) + 0.004})
					debug:AddLine(magic.Vector3(W(p.px), W(feet), W(p.pz)), ex,
							col, false)
				end
			else
				debug:AddCross(P(p.cx, p.cz), size, col, false)
				world_label(p.cx, 0, p.cz, o.name)
			end
			for _, id in ipairs(p.sel) do
				if E.outlines[id] then
					outline(E.outlines[id].pts, col)
				elseif E.inst_data[id] then
					outline(E.inst_data[id].foot, col)
				elseif E.room_data[id] then
					outline(E.room_data[id].pts, col)
				end
			end
		end
	end
	-- Nodes, for the tools that pick them or snap to them. The Nodes, Wall
	-- and Room tools draw them 10x the Select tool's size with 3x its
	-- stroke ([FP_NODES]; user, 2026-10-07): three crosses a pixel apart
	-- along x = z, which puts each arm's lines side by side.
	-- simplified: in 3D "a pixel" is 1 cm whatever the distance
	local big = S.tool == "node" or S.tool == "wall" or S.tool == "room"
	if S.tool == "select" or big then
		local size = S.view == "2d" and W(6 * mm_per_px()) or 0.08
		local px = S.view == "2d" and mm_per_px() or 10
		local strokes = big and {-px, 0, px} or {0}
		if big then
			size = size * 10
		end
		for _, n in ipairs(of_type("node")) do
			local x, z = node_pos(n.id)
			local on = S.sel[n.id] or S.nodes[n.id]
			for _, d in ipairs(strokes) do
				debug:AddCross(P(x + d, z + d), size, on and accent or
						magic.Color(0.1, 0.3, 0.8), S.view ~= "2d")
			end
		end
	end
	-- The box being dragged out, and a box's footprint being drawn
	local d = S.drag
	if d and d.kind == "box" and S.view == "2d" then
		local w, h = screen_size()
		local function pz(px, py)
			return S.cx + (px / w - 0.5) * S.span * w / h,
					S.cz - (py / h - 0.5) * S.span
		end
		local ax, az = pz(S.press.mx, S.press.my)
		local bx, bz = pz(S.mx, S.my)
		outline({{ax, az}, {bx, az}, {bx, bz}, {ax, bz}}, accent)
	elseif d and d.kind == "footprint" then
		outline({{d.x0, d.z0}, {d.x1, d.z0}, {d.x1, d.z1}, {d.x0, d.z1}},
				accent)
		world_label(d.x1, 0, d.z1, mm_text(math.abs(d.x1 - d.x0)) .. " x " ..
				mm_text(math.abs(d.z1 - d.z0)))
	end
	-- What the wall and room tools would do on a click
	if (S.tool == "wall" or S.tool == "room") and not over_ui() then
		local from = S.draw or (S.corners and S.corners[#S.corners])
		local x, z, ref = snapped_point(from)
		if x then
			local col = ref.node and magic.Color(0.1, 0.8, 0.2) or ref.edge and
					magic.Color(0.9, 0.3, 0.9) or accent
			local size = S.view == "2d" and W(8 * mm_per_px()) or 0.12
			debug:AddCross(P(x, z), size, col, false)
			if S.corners then
				for i = 2, #S.corners do
					line(S.corners[i - 1].x, S.corners[i - 1].z,
							S.corners[i].x, S.corners[i].z, accent)
				end
				line(S.corners[1].x, S.corners[1].z, x, z,
						magic.Color(0.9, 0.6, 0.3, 0.5))
			end
			if from then
				line(from.x, from.z, x, z, accent)
				local l = geom.len(x - from.x, z - from.z)
				world_label(x, 0, z, S.typed ~= "" and S.typed .. "_ mm" or
						mm_text(l))
			end
		end
	end
end

return draw_overlay
end
-- vim: set noet ts=4 sw=4:
