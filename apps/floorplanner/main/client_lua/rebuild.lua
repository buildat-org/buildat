-- Buildat: apps/floorplanner/main/client_lua/rebuild.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The scene built from the replica: the instances, voxels, openings,
-- decals, pictures and lamps, the layouts' nodes, the room table and
-- probes the light reads, and the daylight ([FP_EDITOR_MODULES]: out
-- of editor.lua, over its E). Puts rebuild, instances_of, voxel_meshes
-- and open_amount in E.
return function(E)
local FRAME_W, IMAGE_MATERIALS, KIND, LEAF_GAP = E.FRAME_W, E.IMAGE_MATERIALS, E.KIND, E.LEAF_GAP
local LEAF_T, M, S, TRI_LISTS = E.LEAF_T, E.M, E.S, E.TRI_LISTS
local UNLIT, UP, V3, W = E.UNLIT, E.UP, E.V3, E.W
local WHITE, box_geometry, build_room_data, caps_node = E.WHITE, E.box_geometry, E.build_room_data, E.caps_node
local copy_fields, decals_node, fill, flat_material = E.copy_fields, E.decals_node, E.fill, E.flat_material
local flat_polygon, geom, glass_material, grid_step = E.flat_polygon, E.geom, E.glass_material, E.grid_step
local ground_node, images_node, is_lamp_entry, kelvin_rgb = E.ground_node, E.images_node, E.is_lamp_entry, E.kelvin_rgb
local lamp_on, lamps_node, lit_material, log = E.lamp_on, E.lamps_node, E.lit_material, E.log
local magic, node_pos, of_type, overhead_node = E.magic, E.node_pos, E.of_type, E.overhead_node
local palette_texture, pieces_node, place, rgb_color = E.palette_texture, E.pieces_node, E.place, E.rgb_color
local room_at, room_ceiling, row, scene = E.room_at, E.room_ceiling, E.row, E.scene
local settings, sun, sun_node, tri = E.settings, E.sun, E.sun_node, E.tri
local voxel_bounds, wall_between, wall_frame, wall_span = E.voxel_bounds, E.wall_between, E.wall_frame, E.wall_span
local walls_node, zone = E.walls_node, E.zone

-- Each layout's own node under each of the parts, placing it ([FP_LAYOUTS]):
-- place.parts: layout id -> {walls = node, ...}, and P the one rebuild()
-- builds
local P = nil
-- The material each picture file has: file -> one of IMAGE_MATERIALS
local image_materials = {}
local images_used = 0

local function build_inst_data()
	E.inst_data = {}
	local d = S.drag
	for _, e in ipairs(of_type("instance")) do
		local i = e.ints
		-- Where somebody else's drag has it
		local pv = E.doc.previewed(e.id)
		if pv then
			i = copy_fields(i)
			for k, v in pairs(pv) do
				i[k] = v
			end
		end
		local def = E.doc.ents[i.def]
		local moved = d and d.moved and d.kind == "move" and d.inst[e.id]
		local it
		if def and i.host ~= 0 then
			-- In a wall: across its whole thickness and trim, at its sill;
			-- dragged onto another, in that one (the drag's rehost)
			local rh = moved and d.rehost
			local f = wall_frame(rh and rh.wall or i.host)
			local p = def.ints
			if f then
				local along = i.along
				if rh then
					along = rh.along
				elseif moved then
					along = geom.snap(along + d.dx * f.ux + d.dz * f.uz,
							grid_step())
				elseif not (pv and pv.along) then
					along = M.kept_along(along, i.host, p.w)
				end
				local mid = (f.lo - f.ro) / 2
				local trim = p.kind == KIND.opening and 0 or p.trim
				local td = p.kind == KIND.opening and 0 or p.trim_depth
				local thick = f.lo + f.ro + 2 * td
				if p.kind == KIND.switch then
					-- On one face, standing out of it
					mid = i.flip % 2 == 0 and f.lo + 5 or -f.ro - 5
					trim, thick = 0, 10
				end
				it = {x = f.ax + f.ux * along + f.nx * mid,
						z = f.az + f.uz * along + f.nz * mid,
						y = i.sill + p.h / 2, yaw = f.yaw, pitch = 0, roll = 0,
						ex = p.w + 2 * trim, ey = p.h, ez = thick,
						hosted = true, along = along, frame = f}
			end
		elseif def and def.ints.kind == KIND.voxel then
			-- About its origin cell's corner, which is where it is placed:
			-- its extent is what its voxels make it
			local p = def.ints
			local sz = p.voxel_size
			local b = voxel_bounds(i.def) or {0, 0, 0, 0, 0, 0}
			local lx0, ly0, lz0 = b[1] * sz, b[2] * sz, b[3] * sz
			local lx1, ly1, lz1 = (b[4] + 1) * sz, (b[5] + 1) * sz, (b[6] + 1) * sz
			local pitch, roll, yaw = i.pitch * 90, i.roll * 90, i.yaw / 1000
			local ox, oz = i.x, i.z
			if moved then
				ox, oz = ox + d.dx, oz + d.dz
			end
			local oy = i.align == 1 and M.ceiling_at(i.x, i.z) - i.offset or i.offset
			local cx, cy, cz = geom.rot((lx0 + lx1) / 2, (ly0 + ly1) / 2,
					(lz0 + lz1) / 2, pitch, yaw, roll)
			local ex, ey, ez = geom.rot(lx1 - lx0, ly1 - ly0, lz1 - lz0, pitch, 0,
					roll)
			it = {x = ox + cx, y = oy + cy, z = oz + cz, yaw = yaw, pitch = pitch,
					roll = roll, ex = math.abs(ex), ey = math.abs(ey),
					ez = math.abs(ez), hx = (lx1 - lx0) / 2, hy = (ly1 - ly0) / 2,
					hz = (lz1 - lz0) / 2, voxel = true, ox = ox, oy = oy, oz = oz,
					size = sz}
		elseif def then
			local p = def.ints
			local pitch, roll = i.pitch * 90, i.roll * 90
			local ex, ey, ez = geom.rot(p.w, p.h, p.d, pitch, 0, roll)
			ex, ey, ez = math.abs(ex), math.abs(ey), math.abs(ez)
			local x, z = i.x, i.z
			if moved then
				x, z = x + d.dx, z + d.dz
			end
			local y
			if i.align == 1 then
				y = M.ceiling_at(i.x, i.z) - i.offset - ey / 2
			else
				y = i.offset + ey / 2
			end
			it = {x = x, y = y, z = z, yaw = i.yaw / 1000, pitch = pitch,
					roll = roll, ex = ex, ey = ey, ez = ez,
					-- The box's own half sizes, before its rotation
					hx = p.w / 2, hy = p.h / 2, hz = p.d / 2}
		end
		if it then
			it.hx = it.hx or it.ex / 2
			it.hy = it.hy or it.ey / 2
			it.hz = it.hz or it.ez / 2
			it.y0, it.y1, it.def = it.y - it.ey / 2, it.y + it.ey / 2, i.def
			local foot = {}
			for k, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
				local fx, _, fz = geom.rot(c[1] * it.ex / 2, 0, c[2] * it.ez / 2,
						0, it.yaw, 0)
				foot[k] = {it.x + fx, it.z + fz}
			end
			if not geom.is_ccw(foot) then
				foot = {foot[4], foot[3], foot[2], foot[1]}
			end
			it.foot = foot
			E.inst_data[e.id] = it
		end
	end
end

-- Where a selected thing is in the plan, as its X and Z fields have it:
-- an instance's middle, a wall's or a room's nodes' average, a node; nil
-- for anything else
function M.sel_pos(id, kind)
	local e = E.doc.ents[id]
	if not e then
		return nil
	end
	if kind == "instance" then
		local it = E.inst_data[id]
		return it and it.x, it and it.z
	elseif kind == "node" then
		return node_pos(id)
	end
	local ns = kind == "wall" and {e.ints.a, e.ints.b} or
			kind == "room" and e.lists.nodes
	if not ns or #ns == 0 then
		return nil
	end
	local sx, sz = 0, 0
	for _, n in ipairs(ns) do
		local x, z = node_pos(n)
		sx, sz = sx + x, sz + z
	end
	return sx / #ns, sz / #ns
end

local function instances_of(def)
	local n = 0
	for _, e in ipairs(E.doc.of_type("instance")) do
		if e.ints.def == def then
			n = n + 1
		end
	end
	return n
end

-- The voxel volumes' meshes, kept between rebuilds: an instance's is made
-- again only when its voxels, its size or the palette's rows change, and
-- otherwise only moved. instance id -> {node, key}
local voxel_meshes = {}

local FACES = {
	{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
}

-- A volume's cells as the node's geometry: a face wherever a neighbour is
-- empty, built in the engine from one list of cells and palette rows
-- (buildat.set_cell_geometry; a face at a time from here was a freeze on
-- the web, user 2026-09-30)
-- simplified: a quad per exposed face; the upgrade is a greedy mesher,
-- which the same call can do inside
local function voxel_geometry(node, def, sz, tint, occ)
	local cells = {}
	for key, mat in pairs(E.doc.voxels[def] or {}) do
		cells[#cells + 1] = key
		cells[#cells + 1] = row(mat)
	end
	local c = tint or WHITE
	buildat.set_cell_geometry(node, cells, W(sz), c.r, c.g, c.b, c.a, occ or 0)
end

local function update_voxel_meshes(seen)
	for id, it in pairs(E.inst_data) do
		if it.voxel then
			seen[id] = true
			local e = E.doc.ents[id].ints
			local def = e.def
			local on = lamp_on(id)
			-- and the room it stands in, for the sky's share ([FP_DAYLIGHT])
			local occ = M.inst_occlusion(it)
			local key = (E.doc.voxel_version[def] or 0) .. ":" .. E.palette_gen ..
					":" .. it.size .. ":" .. def .. ":" .. e.align .. ":" ..
					tostring(on) .. ":" .. occ
			local m = voxel_meshes[id]
			if not m or m.key ~= key then
				if m then
					m.node:Remove()
				end
				local parent = e.align == 1 and P.overhead or P.walls
				local node = parent:CreateChild("voxels")
				voxel_geometry(node, def, it.size, not on and UNLIT or nil, occ)
				local g = node:GetComponent("CustomGeometry")
				g:SetMaterial(0, lit_material)
				g.castShadows = true
				m = {node = node, key = key}
				voxel_meshes[id] = m
			end
			m.node.position = magic.Vector3(W(it.ox), W(it.oy), W(it.oz))
			m.node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
		end
	end
end

-- How open a door or window is, in thousandths of a right angle (to 1889,
-- 170 degrees): a viewer's own opening wins over the plan's
local function open_amount(id)
	return S.local_open[id] or E.doc.ents[id].ints.open
end
-- How far down a window's blind is, in thousandths: a viewer's own wins
function M.blinds_amount(id)
	return S.local_blinds[id] or E.doc.ents[id].ints.blinds or 0
end
-- What a blind lets through, down that far: an almost shut venetian
-- blind's tenth or so where it is down
-- simplified: the light that comes through the slats, not their glow
M.BLIND_THROUGH = 0.08
function M.blinds_through(id)
	return 1 - (1 - M.BLIND_THROUGH) * M.blinds_amount(id) / 1000
end

-- A door's or window's parts, in the frame of the wall at its centre: X
-- along the wall, Y up from the floor, Z to the wall's left
local function build_hosted(id, it, def, e, geometry, commit)
	if def.kind == KIND.opening then
		return
	end
	if def.kind == KIND.switch then
		local g, node = geometry(P.pieces)
		node.position = magic.Vector3(W(it.x), W(it.y), W(it.z))
		node.rotation = magic.Quaternion(0, it.yaw, 0)
		box_geometry(g, W(def.w) / 2, W(def.h) / 2, W(5), row(def.mat))
		commit(g, lit_material)
		return
	end
	local f = it.frame
	local ox, oz = f.ax + f.ux * it.along, f.az + f.uz * it.along
	local function part()
		local g, node = geometry(P.pieces)
		node.position = magic.Vector3(W(ox), 0, W(oz))
		node.rotation = magic.Quaternion(0, f.yaw, 0)
		return g, node
	end
	local function B(g, x0, y0, z0, x1, y1, z1, col)
		box_geometry(g, W(x1 - x0) / 2, W(y1 - y0) / 2, W(z1 - z0) / 2, col,
				W(x0 + x1) / 2, W(y0 + y1) / 2, W(z0 + z1) / 2)
	end
	local frame_col = row(def.mat)
	local leaf_col = row(def.mat_leaf ~= 0 and def.mat_leaf or def.mat)
	-- simplified: only a window's glass is drawn see-through; a glass
	-- entry on a wall or a box is drawn opaque in its tint
	local glass_col = def.mat_glass ~= 0 and row(def.mat_glass) or 1
	local hw, t, td = def.w / 2, def.trim, def.trim_depth
	local y0, y1 = e.sill, e.sill + def.h
	local window = def.kind == KIND.window

	-- The trim on both faces
	local g = part()
	if t > 0 and td > 0 then
		for _, face in ipairs({{f.lo, f.lo + td}, {-f.ro - td, -f.ro}}) do
			local z0, z1 = face[1], face[2]
			local b = window and y0 - t or y0
			B(g, -hw - t, b, z0, -hw, y1 + t, z1, frame_col)
			B(g, hw, b, z0, hw + t, y1 + t, z1, frame_col)
			B(g, -hw, y1, z0, hw, y1 + t, z1, frame_col)
			if window then
				B(g, -hw, y0 - t, z0, hw, y0, z1, frame_col)
			end
		end
	end
	-- A window's frame in the opening
	if window then
		local fw = FRAME_W
		B(g, -hw, y0, -30, -hw + fw, y1, 30, frame_col)
		B(g, hw - fw, y0, -30, hw, y1, 30, frame_col)
		B(g, -hw + fw, y0, -30, hw - fw, y0 + fw, 30, frame_col)
		B(g, -hw + fw, y1 - fw, -30, hw - fw, y1, 30, frame_col)
		-- **Its blind** (user, 2026-10-02): a venetian blind almost shut,
		-- down from the top of the glass as far as it is drawn, on the
		-- room's side of the frame (the side a room is on; between two,
		-- the side the sashes swing to): slats a little apart, each a
		-- little out from the next, under a head rail, in the frame's
		-- colour. The sun comes through the gaps as the shadow map has
		-- them, a patch of dots (user: fine as it is); the worked out
		-- light goes by BLIND_THROUGH.
		local down = M.blinds_amount(id) / 1000
		if down > 0 then
			local off = f.lo + f.ro + 100
			local plus = room_at(it.x + f.nx * off, it.z + f.nz * off)
			local minus = room_at(it.x - f.nx * off, it.z - f.nz * off)
			local zs = (plus and minus) and
					(math.floor(e.flip / 2) % 2 == 1 and -1 or 1) or plus and 1 or -1
			local zc = zs * 40
			local top = y1 - fw
			local bottom = top - (top - (y0 + fw)) * down
			local xa, xb = -hw + fw, hw - fw
			B(g, xa, top - 30, zc - 6, xb, top, zc + 6, frame_col)
			local PITCH, SLAT = 25, 23
			local k = 0
			local y = top - 30
			while y - SLAT >= bottom - 1 do
				local dz = (k % 2 == 0) and 1.5 or -1.5
				B(g, xa + 2, y - SLAT, zc + dz - 1.5, xb - 2, y, zc + dz + 1.5,
						frame_col)
				y = y - PITCH
				k = k + 1
			end
		end
	end
	commit(g, lit_material)

	-- The leaves, each on its own node at its hinge, turned by how open it
	-- is: towards +Z, or -Z when the swing is flipped
	local angle = open_amount(id) / 1000 * 90
	local right = e.flip % 2 == 1
	local sign = math.floor(e.flip / 2) % 2 == 1 and -1 or 1
	local leaves = {}
	if window and def.leaf == 2 then
		-- Double casement (user): two sashes meeting in the middle
		local inner = hw - FRAME_W
		leaves[1] = {x = -inner, w = inner, dir = 1}
		leaves[2] = {x = inner, w = inner, dir = -1}
	elseif window then
		local inner = hw - FRAME_W
		leaves[1] = {x = right and inner or -inner, w = 2 * inner,
				dir = right and -1 or 1}
	elseif def.leaf == 1 then
		leaves[1] = {x = -hw + LEAF_GAP, w = hw - 1.5 * LEAF_GAP, dir = 1}
		leaves[2] = {x = hw - LEAF_GAP, w = hw - 1.5 * LEAF_GAP, dir = -1}
	else
		leaves[1] = {x = right and hw - LEAF_GAP or -hw + LEAF_GAP,
				w = 2 * hw - 2 * LEAF_GAP, dir = right and -1 or 1}
	end
	-- A fixed window does not open
	if window and def.leaf == 0 then
		angle = 0
	end
	-- **Where each leaf is, for a click on it** (user): its box in its own
	-- frame, and the hinge and the turn that frame is at, in the layout's
	-- metres as the picking ray is (ray_instance)
	it.leaves = {}
	for _, lf in ipairs(leaves) do
		local lg, node = part()
		local yaw = f.yaw - lf.dir * sign * angle
		local hx, _, hz = geom.rot(lf.x, 0, 0, 0, f.yaw, 0)
		node.position = magic.Vector3(W(ox + hx), 0, W(oz + hz))
		node.rotation = magic.Quaternion(0, yaw, 0)
		local x0, x1 = 0, lf.dir * lf.w
		if x1 < x0 then
			x0, x1 = x1, x0
		end
		local t = window and 20 or LEAF_T / 2
		it.leaves[#it.leaves + 1] = {x = W(ox + hx), z = W(oz + hz), yaw = yaw,
				lo = {W(x0), W(y0), W(-t)}, hi = {W(x1), W(y1), W(t)}}
		if window then
			local fw = FRAME_W
			B(lg, x0, y0 + fw, -20, x0 + fw, y1 - fw, 20, frame_col)
			B(lg, x1 - fw, y0 + fw, -20, x1, y1 - fw, 20, frame_col)
			B(lg, x0 + fw, y0 + fw, -20, x1 - fw, y0 + 2 * fw, 20, frame_col)
			B(lg, x0 + fw, y1 - 2 * fw, -20, x1 - fw, y1 - fw, 20, frame_col)
			commit(lg, lit_material)
			local gg, gnode = part()
			gnode.position = node.position
			gnode.rotation = node.rotation
			B(gg, x0 + fw, y0 + 2 * fw, -4, x1 - fw, y1 - 2 * fw, 4, glass_col)
			commit(gg, glass_material)
		else
			-- **A glazed leaf** (user): stiles and rails around a pane, the
			-- bottom rail a panel to 900 mm; a leaf too small for a pane
			-- is solid
			local st, top, bot = 120, 150, 900
			local ly1 = y1 - LEAF_GAP
			local lt = LEAF_T / 2
			if def.glazed == 1 and x1 - x0 > 2 * st + 100 and
					ly1 - y0 > top + bot + 200 then
				B(lg, x0, y0, -lt, x0 + st, ly1, lt, leaf_col)
				B(lg, x1 - st, y0, -lt, x1, ly1, lt, leaf_col)
				B(lg, x0 + st, y0, -lt, x1 - st, y0 + bot, lt, leaf_col)
				B(lg, x0 + st, ly1 - top, -lt, x1 - st, ly1, lt, leaf_col)
				commit(lg, lit_material)
				local gg, gnode = part()
				gnode.position = node.position
				gnode.rotation = node.rotation
				B(gg, x0 + st, y0 + bot, -4, x1 - st, ly1 - top, 4, glass_col)
				commit(gg, glass_material)
			else
				B(lg, x0, y0, -lt, x1, ly1, lt, leaf_col)
				commit(lg, lit_material)
			end
		end
	end
end

-- The pictures: a quad each over the floors, its size its pixels times
-- its scale, drawn in the plan view and, if asked, in 3D
-- A surface's material id, written on it: corner is the surface's upper
-- left corner as seen from in front, n the way it faces and up the way
-- that is up on it, all in mm and world axes
local DECAL_MARGIN = 40
local function decal(corner, n, up, entry)
	if not entry or entry == 0 or not S.show_ids then
		return
	end
	-- The viewer looks along -n; to their right is up x -n
	local fx, fy, fz = -n[1], -n[2], -n[3]
	local rx = up[2] * fz - up[3] * fy
	local ry = up[3] * fx - up[1] * fz
	local rz = up[1] * fy - up[2] * fx
	local m = DECAL_MARGIN
	local x = corner[1] + rx * m - up[1] * m + n[1] * 2
	local y = corner[2] + ry * m - up[2] * m + n[2] * 2
	local z = corner[3] + rz * m - up[3] * m + n[3] * 2
	local node = P.decals:CreateChild("decal")
	E.built[#E.built + 1] = node
	node.position = magic.Vector3(W(x), W(y), W(z))
	-- Text3D faces its node's -Z: the node looks into the surface
	node:LookAt(magic.Vector3(W(x + fx), W(y + fy), W(z + fz)),
			magic.Vector3(up[1], up[2], up[3]))
	node.scale = magic.Vector3(1.5, 1.5, 1.5)
	local t = node:CreateComponent("Text3D")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 14)
	t.text = tostring(entry)
	t:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
	t:SetColor(magic.Color(0.1, 0.1, 0.12))
	t.textEffect = magic.TE_STROKE
	t.effectColor = magic.Color(1, 1, 1, 0.8)
end

-- The decals of everything: a wall's two faces at their longest stretch
-- and its top, floors, ceilings, a box's six faces, a door's and a
-- window's frame
local function build_decals()
	for id, o in pairs(E.outlines) do
		local w = E.doc.ents[id].ints
		local y0, y1 = wall_span(w)
		for _, side in ipairs({"left", "right"}) do
			local best, bl = nil, 0
			for i = 1, #o.pts do
				if o.sides[i] == side then
					local p, q = o.pts[i], o.pts[i % #o.pts + 1]
					local l = geom.len(q[1] - p[1], q[2] - p[2])
					if l > bl then
						best, bl = i, l
					end
				end
			end
			if best and bl > 2 * DECAL_MARGIN then
				local p, q = o.pts[best], o.pts[best % #o.pts + 1]
				local nx, nz = (q[2] - p[2]) / bl, -(q[1] - p[1]) / bl
				-- Seen from outside, the edge runs left to right
				decal({p[1], y1, p[2]}, {nx, 0, nz}, {0, 1, 0},
						side == "left" and w.mat_left or w.mat_right)
			end
		end
		-- The top only when it is not the left face's, which says it already
		if w.mat_core ~= 0 and w.mat_core ~= w.mat_left then
			decal({o.pts[1][1], y1, o.pts[1][2]}, {0, 1, 0}, {0, 0, 1}, w.mat_core)
		end
	end
	for id, r in pairs(E.room_data) do
		local e = E.doc.ents[id].ints
		local x0, z1 = math.huge, -math.huge
		for _, p in ipairs(r.inner) do
			x0, z1 = math.min(x0, p[1]), math.max(z1, p[2])
		end
		decal({x0, 2, z1}, {0, 1, 0}, {0, 0, 1}, e.mat_floor)
		decal({x0, room_ceiling(E.doc.ents[id]), z1 - 2 * DECAL_MARGIN},
				{0, -1, 0}, {0, 0, -1}, e.mat_ceiling)
	end
	for id, it in pairs(E.inst_data) do
		local def = E.doc.ents[it.def].ints
		if not it.hosted and not it.voxel then
			-- Each face: its normal and its up, in the box's own axes
			for _, f in ipairs({{{0, 0, -1}, {0, 1, 0}}, {{0, 0, 1}, {0, 1, 0}},
					{{-1, 0, 0}, {0, 1, 0}}, {{1, 0, 0}, {0, 1, 0}},
					{{0, 1, 0}, {0, 0, 1}}, {{0, -1, 0}, {0, 0, -1}}}) do
				local n, up = f[1], f[2]
				local rx = up[2] * -n[3] - up[3] * -n[2]
				local ry = up[3] * -n[1] - up[1] * -n[3]
				local rz = up[1] * -n[2] - up[2] * -n[1]
				local h = {it.hx, it.hy, it.hz}
				local c = {}
				for a = 1, 3 do
					c[a] = (n[a] + up[a] - ({rx, ry, rz})[a]) * h[a]
				end
				local cx, cy, cz = geom.rot(c[1], c[2], c[3], it.pitch, it.yaw,
						it.roll)
				local wn = {geom.rot(n[1], n[2], n[3], it.pitch, it.yaw, it.roll)}
				local wu = {geom.rot(up[1], up[2], up[3], it.pitch, it.yaw,
						it.roll)}
				decal({it.x + cx, it.y + cy, it.z + cz}, wn, wu, def.mat)
			end
		elseif it.hosted and (def.kind == KIND.door or def.kind == KIND.window) then
			local f = it.frame
			local e = E.doc.ents[id].ints
			-- Seen from the wall's left, its far end along it is on the left
			local a = it.along + def.w / 2 + def.trim
			decal({f.ax + f.ux * a + f.nx * (f.lo + def.trim_depth),
					e.sill + def.h + def.trim, f.az + f.uz * a + f.nz *
					(f.lo + def.trim_depth)}, {f.nx, 0, f.nz}, {0, 1, 0}, def.mat)
		end
	end
end

local function build_images()
	E.image_data = {}
	local d = S.drag
	for _, e in ipairs(of_type("image")) do
		local i = e.ints
		-- The plan's own images/ ([FP_PLANS] 3)
		local tex = e.strs.file ~= "" and magic.cache:GetResource("Texture2D",
				"main/images/" .. E.doc.plan_name .. "/" .. e.strs.file)
		if tex then
			local mat = image_materials[e.strs.file]
			if not mat and images_used < IMAGE_MATERIALS then
				images_used = images_used + 1
				mat = magic.cache:GetResource("Material", "main/image" ..
						images_used .. ".xml")
				mat:SetTexture(magic.TU_DIFFUSE, tex)
				image_materials[e.strs.file] = mat
			end
			local x, z = i.x, i.z
			if d and d.moved and d.kind == "move" and d.inst[e.id] then
				x, z = x + d.dx, z + d.dz
			end
			local hw, hh = tex.width * i.scale / 2000, tex.height * i.scale / 2000
			local foot, uv = {}, {{0, 1}, {1, 1}, {1, 0}, {0, 0}}
			for k, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
				local fx, _, fz = geom.rot(c[1] * hw, 0, c[2] * hh, 0, i.yaw / 1000, 0)
				foot[k] = {x + fx, z + fz}
			end
			E.image_data[e.id] = {foot = foot, locked = i.locked == 1}
			if mat and (S.view == "2d" or i.show3d == 1) then
				local node = P.images:CreateChild("image")
				E.built[#E.built + 1] = node
				local g = node:CreateComponent("CustomGeometry")
				g:SetNumGeometries(1)
				g:BeginGeometry(0, magic.TRIANGLE_LIST)
				local col = magic.Color(1, 1, 1, i.opacity / 1000)
				-- Over the floors, under everything else
				for _, t in ipairs({{1, 3, 2}, {1, 4, 3}}) do
					for _, k in ipairs(t) do
						g:DefineVertex(magic.Vector3(W(foot[k][1]), W(3), W(foot[k][2])))
						g:DefineNormal(UP)
						g:DefineColor(col)
						g:DefineTexCoord(magic.Vector2(uv[k][1], uv[k][2]))
					end
				end
				g:Commit()
				g:SetMaterial(0, mat)
			end
		end
	end
end

local build_lamps
do
	-- A point light at (x, y, z) mm in a lamp entry's colour and brightness
	local function lamp_light(x, y, z, entry)
		local p = E.doc.ents[entry].ints
		local node = P.lamps:CreateChild("lamp")
		E.built[#E.built + 1] = node
		M.own_node(node)
		node.position = magic.Vector3(W(x), W(y), W(z))
		local light = node:CreateComponent("Light")
		light.lightType = magic.LIGHT_POINT
		light.color = rgb_color(kelvin_rgb(p.temperature))
		-- 1 is 100 %, a lamp's beside the sun (user, 2026-10-02); in
		-- proportion to it, as the lamp's surface is (Palette.glsl)
		local b = p.brightness / 1000
		light.brightness = 0.65 * b * M.daylight.PHYS.lamp
		light.range = 2 + 0.8 * b
end

-- The lamps that are on: each connected region of a volume's lamp voxels
-- is one light at its middle, not one per voxel; a box of a lamp material
-- is one at its centre. Only under PBR (user): in the unlit look, and so
-- in the plan view, a lamp's light only oversaturates.
build_lamps = function()
	if not M.pbr_now() then
		return
	end
	for id, it in pairs(E.inst_data) do
		M.geo_owner = id
		if lamp_on(id) and not it.hosted then
			local def = E.doc.ents[it.def].ints
			if it.voxel then
				local vox = E.doc.voxels[it.def] or {}
				local lit = {}
				for key, m in pairs(vox) do
					if is_lamp_entry(m) then
						lit[key] = m
					end
				end
				local seen = {}
				for key, m in pairs(lit) do
					if not seen[key] then
						-- The region this voxel is in, by its six neighbours
						local stack, n, sx, sy, sz = {key}, 0, 0, 0, 0
						seen[key] = true
						while #stack > 0 do
							local k = table.remove(stack)
							local x, y, z = E.doc.voxel_cell(k)
							n, sx, sy, sz = n + 1, sx + x + 0.5, sy + y + 0.5, sz + z + 0.5
							for _, f in ipairs(FACES) do
								local nk = E.doc.voxel_key(x + f[1], y + f[2], z + f[3])
								if lit[nk] and not seen[nk] then
									seen[nk] = true
									stack[#stack + 1] = nk
								end
							end
						end
						local lx, ly, lz = geom.rot(sx / n * it.size, sy / n * it.size,
								sz / n * it.size, it.pitch, it.yaw, it.roll)
						lamp_light(it.ox + lx, it.oy + ly, it.oz + lz, m)
					end
				end
			elseif def.kind == KIND.box and is_lamp_entry(def.mat) then
				lamp_light(it.x, it.y, it.z, def.mat)
			end
		end
	end
	M.geo_owner = nil
end

end

-- simplified: everything is rebuilt on any change, which at a few hundred
-- walls is milliseconds; the upgrade is rebuilding only what is at the
-- nodes that moved
local rebuild
do
-- Stairwells ([FP_LAYOUTS]): stairs whose top is within STAIRWELL mm of
-- another layout's floor cut their footprint out of that floor and out of
-- the ceilings of their own. layouts: every layout, cur the current one's
-- fields. Returns layout id -> {floor = {pts, ...}, ceiling = {...}}.
local STAIRWELL = 200
function place.stairwells(layouts, cur)
	local out, rels, list = {}, {}, {}
	for _, l in ipairs(layouts) do
		out[l.id] = {floor = {}, ceiling = {}}
		rels[l.id] = place.rel(l.ints, cur)
		S.view_layout = l.id
		for _, e in ipairs(of_type("instance")) do
			local i = e.ints
			local def = E.doc.ents[i.def]
			if def and def.ints.kind == KIND.stairs and i.pitch == 0 and
					i.roll == 0 then
				local p = def.ints
				local top = i.align == 1 and M.ceiling_at(i.x, i.z) - i.offset or
						i.offset + p.h
				local foot = {}
				for k, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
					local fx, _, fz = geom.rot(c[1] * p.w / 2, 0, c[2] * p.d / 2, 0,
							i.yaw / 1000, 0)
					foot[k] = {i.x + fx, i.z + fz}
				end
				if not geom.is_ccw(foot) then
					foot = {foot[4], foot[3], foot[2], foot[1]}
				end
				list[#list + 1] = {layout = l.id, top = top, foot = foot}
			end
		end
	end
	S.view_layout = S.layout
	for _, st in ipairs(list) do
		local r = rels[st.layout]
		for id, u in pairs(rels) do
			if id ~= st.layout and math.abs(st.top + r.y - u.y) <= STAIRWELL then
				local pts = {}
				for k, q in ipairs(st.foot) do
					local x, _, z = place.point(r, q[1], 0, q[2])
					local ux, _, uz = place.unpoint(u, x, 0, z)
					pts[k] = {ux, uz}
				end
				table.insert(out[id].floor, pts)
				table.insert(out[st.layout].ceiling, st.foot)
			end
		end
	end
	return out
end

-- Walking changes the current layout (geom.pick_floor)
function place.follow(w)
	local floors = {}
	for _, l in ipairs(place.layers) do
		local lx, _, lz = place.unpoint(l.rel, w.x, 0, w.z)
		local under = false
		for _, r in pairs(l.rooms) do
			if geom.point_in_polygon(lx, lz, r.pts) then
				under = true
				break
			end
		end
		floors[#floors + 1] = {id = l.id, y = l.rel.y, under = under}
	end
	local id = geom.pick_floor(floors, S.layout, w.feet)
	if id then
		place.switch(id)
		-- Stale until the rebuild the switch asks for
		place.layers = {}
		E.doc.notice("On " .. E.doc.ents[id].strs.name)
	end
end

-- **What of the open sky's light each room gets** ([FP_DAYLIGHT]): its
-- daylight factor from the glass it has -- windows, glazed doors and
-- openings, found on either side of their walls -- over its floor
-- (daylight.lua), kept as 1 - it by room id, and the lookup tri() makes
-- for a face in the layout's own frame. simplified: the sky's share only;
-- the sun a room's windows let in lights the floor it falls on and not
-- the rest of the room, which a bounce term would.
-- **Each room's slot**, 1 to 255, over the whole rebuild (0: outdoors,
-- or no slot left): its row in the room table, which the texture
-- coordinate's y carries as slot + 1 - daylight factor. And what its
-- sunlight bounce is worked out from (M.room_bounce): the glass to the
-- outside with which way it faces, in the scene's frame, and the room's
-- floor colour and surfaces.
-- Kept over rebuilds, so that a room keeps its row and its probe; a room
-- gone frees its slot at the end of the rebuild
M.room_slot, M.slot_owner, M.room_light, M.room_seen = {}, {}, {}, {}
-- And each slot's probes (M.room_probes): the rows of the probes' atlas
-- they are drawn in, {first, n, and the first's and the last's x and z in
-- the scene's frame, m}; each row's slot, where its probe stands (the
-- scene's frame, mm) and whether its six faces have been drawn
-- (M.probes_tick)
M.probe_rows, M.row_owner, M.probe_pos, M.probe_ready = {}, {}, {}, {}
local function entry_albedo(id)
	local e = id and E.doc.ents[id]
	if not e or e.type ~= "palette" then
		return {r = 0.5, g = 0.5, b = 0.5}
	end
	local p = e.ints
	local function lin(rgb)
		return {r = (math.floor(rgb / 65536) / 255) ^ 2.2,
				g = (math.floor(rgb / 256) % 256 / 255) ^ 2.2,
				b = (rgb % 256 / 255) ^ 2.2}
	end
	local base, paint = lin(p.base), lin(p.color)
	local k = p.finish == 1 and 1 or p.finish == 2 and p.opacity / 1000 or 0
	local function ch(c)
		local nat = base[c]
		return p.finish == 0 and nat * paint[c] or nat + (paint[c] - nat) * k
	end
	return {r = ch("r"), g = ch("g"), b = ch("b")}
end
M.entry_albedo = entry_albedo

-- A room's walls' albedo: their faces' to it, by their length
function M.wall_albedo(rd)
	local sum, len = {r = 0, g = 0, b = 0}, 0
	for i = 1, #rd.ids do
		local wid, forward = wall_between(rd.ids[i], rd.ids[i % #rd.ids + 1])
		local p, q = rd.pts[i], rd.pts[i % #rd.pts + 1]
		local l = geom.len(q[1] - p[1], q[2] - p[2])
		local w = wid and E.doc.ents[wid]
		-- The room is left of its counter-clockwise edges
		local a = entry_albedo(w and (forward and w.ints.mat_left or
				w.ints.mat_right))
		sum.r, sum.g, sum.b = sum.r + a.r * l, sum.g + a.g * l, sum.b + a.b * l
		len = len + l
	end
	if len <= 0 then
		return {r = 0.5, g = 0.5, b = 0.5}
	end
	return {r = sum.r / len, g = sum.g / len, b = sum.b / len}
end

-- **A room's probes** (user, 2026-10-01: one in the middle of a long room
-- lit its far wall as if it were by the sun's patch at the other end; the
-- path-traced reference had that wall at under half): along the room's
-- longest edge, one every 2 m or so, up to four, at a standing eye's
-- height or half the ceiling's. Rows of the atlas (PROBE_ROWS) for them,
-- next to each other, kept while their number is; fewer when there are
-- not enough, none past that.
-- simplified: on the line through the middle of the room across that
-- edge; a probe that is not in the room (an L) is put in its first
-- triangle's middle
M.PROBE_GAP, M.PROBES_MAX = 2000, 4
function M.free_rows(slot)
	local pr = M.probe_rows[slot]
	if not pr then
		return
	end
	for row = pr.first, pr.first + pr.n - 1 do
		M.row_owner[row], M.probe_pos[row], M.probe_ready[row] = nil, nil, nil
	end
	M.probe_rows[slot] = nil
end
function M.room_probes(slot, rd, e)
	local pts = #rd.inner >= 3 and rd.inner or rd.pts
	local ux, uz, best = 1, 0, 0
	for i = 1, #pts do
		local p, q = pts[i], pts[i % #pts + 1]
		local l = geom.len(q[1] - p[1], q[2] - p[2])
		if l > best then
			best, ux, uz = l, (q[1] - p[1]) / l, (q[2] - p[2]) / l
		end
	end
	local t0, t1, s0, s1 = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(pts) do
		local t, sv = p[1] * ux + p[2] * uz, -p[1] * uz + p[2] * ux
		t0, t1 = math.min(t0, t), math.max(t1, t)
		s0, s1 = math.min(s0, sv), math.max(s1, sv)
	end
	local n = math.max(1, math.min(M.PROBES_MAX, math.ceil((t1 - t0) / M.PROBE_GAP)))
	-- The rows: the same ones while the number is the same
	local pr = M.probe_rows[slot]
	if not pr or pr.n ~= n then
		M.free_rows(slot)
		pr = nil
		for want = n, 1, -1 do
			for first = 1, M.PROBE_ROWS - want do
				local free = true
				for row = first, first + want - 1 do
					free = free and not M.row_owner[row]
				end
				if free then
					pr = {first = first, n = want}
					break
				end
			end
			if pr then
				break
			end
		end
		if not pr then
			return
		end
		for row = pr.first, pr.first + pr.n - 1 do
			M.row_owner[row] = slot
		end
		M.probe_rows[slot] = pr
	end
	n = pr.n
	local y = math.min(1500, room_ceiling(e) / 2)
	local sm = (s0 + s1) / 2
	local r = M.cur_rel or place.WORLD
	for i = 1, n do
		local t = t0 + (t1 - t0) * (i - 0.5) / n
		local x, z = t * ux - sm * uz, t * uz + sm * ux
		if not geom.point_in_polygon(x, z, pts) then
			local tri = geom.triangulate(pts)[1]
			if tri then
				x = (pts[tri[1]][1] + pts[tri[2]][1] + pts[tri[3]][1]) / 3
				z = (pts[tri[1]][2] + pts[tri[2]][2] + pts[tri[3]][2]) / 3
			end
		end
		local px, py, pz = place.point(r, x, y, z)
		M.probe_pos[pr.first + i - 1] = {x = px, y = py, z = pz}
	end
	local a, b = M.probe_pos[pr.first], M.probe_pos[pr.first + n - 1]
	pr.x0, pr.z0, pr.x1, pr.z1 = W(a.x), W(a.z), W(b.x), W(b.z)
	-- and the room's box, which the probes' light is put back on
	-- (Palette.glsl's RoomAmbient): a corner, the along axis, the extents
	-- along it and across, the floor's and the ceiling's height; m
	local ox, oy, oz = place.point(r, t0 * ux - s0 * uz, 0, t0 * uz + s0 * ux)
	local ax, _, az = place.point(r, ux, 0, uz)
	local zx, _, zz = place.point(r, 0, 0, 0)
	pr.box = {ox = W(ox), oz = W(oz), ux = ax - zx, uz = az - zz,
			lu = W(t1 - t0), lv = W(s1 - s0), y0 = W(oy), y1 = W(oy + room_ceiling(e))}
end

-- Where along a room's probes a point (the scene's frame, m) is: the row
-- before it, the row after and how far between
function M.probe_at(pr, x, z)
	if pr.n < 2 then
		return pr.first, pr.first, 0
	end
	local dx, dz = pr.x1 - pr.x0, pr.z1 - pr.z0
	local t = ((x - pr.x0) * dx + (z - pr.z0) * dz) / (dx * dx + dz * dz)
	t = math.max(0, math.min(1, t)) * (pr.n - 1)
	local i = math.min(math.floor(t), pr.n - 2)
	return pr.first + i, pr.first + i + 1, t - i
end
function M.room_occlusion()
	local glass = {}
	local sunward = {}
	for iid, it in pairs(E.inst_data) do
		local def = it.hosted and it.frame and E.doc.ents[it.def]
		local d = def and def.ints
		local a = 0
		if d and d.kind == KIND.window then
			-- less what its blind keeps out
			a = math.max(0, d.w - 4 * FRAME_W) * math.max(0, d.h - 4 * FRAME_W) *
					M.blinds_through(iid)
		elseif d and d.kind == KIND.opening then
			a = d.w * d.h
		elseif d and d.kind == KIND.door and d.glazed == 1 then
			a = math.max(0, d.w - 240) * math.max(0, d.h - 1050)
		end
		if a > 0 then
			local f = it.frame
			local off = f.lo + f.ro + 100
			local side = {}
			for _, sgn in ipairs({1, -1}) do
				side[sgn] = room_at(it.x + f.nx * off * sgn, it.z + f.nz * off * sgn)
				local rid = side[sgn]
				if rid then
					glass[rid] = (glass[rid] or 0) + a
				end
			end
			-- Glass with the outside behind it lets the sun in: facing
			-- away from the room, in the scene's frame
			local through = d.kind == KIND.opening and 1 or 0.75
			for _, sgn in ipairs({1, -1}) do
				local rid = side[sgn]
				if rid and not side[-sgn] then
					local r = M.cur_rel or place.WORLD
					local x0, _, z0 = place.point(r, 0, 0, 0)
					local x1, _, z1 = place.point(r, -f.nx * sgn, 0, -f.nz * sgn)
					local l = sunward[rid] or {}
					sunward[rid] = l
					-- and its middle in the scene's frame, in metres, for the
					-- light the probes see from it (M.cpu_cubes)
					local cx, cy, cz = place.point(r, it.x, (it.y0 + it.y1) / 2, it.z)
					l[#l + 1] = {a = a / 1e6 * through, ox = x1 - x0, oz = z1 - z0,
							x = W(cx), y = W(cy), z = W(cz), through = through}
				end
			end
		end
	end
	M.room_occ = {}
	for id, rd in pairs(E.room_data) do
		local occ = 1 - M.daylight.daylight_factor(glass[id] or 0, rd.net)
		local slot = M.room_slot[id]
		if not slot then
			for k = 1, 255 do
				if not M.slot_owner[k] then
					slot = k
					M.slot_owner[k] = id
					M.room_slot[id] = slot
					break
				end
			end
		end
		M.room_seen[id] = true
		-- Packed: slot + occ, occ under 1
		M.room_occ[id] = (slot or 0) + math.min(occ, 0.995)
		if slot then
			local e = E.doc.ents[id]
			local perim = 0
			for i = 1, #rd.pts do
				local p, q = rd.pts[i], rd.pts[i % #rd.pts + 1]
				perim = perim + geom.len(q[1] - p[1], q[2] - p[2])
			end
			local floor = rd.net / 1e6
			local height = room_ceiling(e) / 1000
			local _, fy = place.point(M.cur_rel or place.WORLD, 0, 0, 0)
			M.room_light[slot] = {wins = sunward[id] or {},
					area = 2 * floor + perim / 1000 * height,
					floor_area = floor, wall_area = perim / 1000 * height,
					floor = entry_albedo(e.ints.mat_floor),
					ceiling = entry_albedo(e.ints.mat_ceiling),
					wall = M.wall_albedo(rd), height = height,
					floor_y = W(fy)}
			M.room_probes(slot, rd, e)
		end
	end
	M.tri_occ, M.tri_occ_fn = 0, function(xm, zm)
		local id = room_at(xm * 1000, zm * 1000)
		return id and M.room_occ[id] or 0
	end
end

-- **The sun a room's windows let in, bounced** (user, 2026-10-01): what
-- comes through the glass facing the sun lands on the floor, which sends
-- its colour of it back into the room; spread over the room's surfaces
-- and taken up again by them, half each time (1 / (1 - 0.5)). As the
-- shader's ambient adds it: irradiance over pi. For a room without
-- probes; with them, the probes' light is the ambient (M.cpu_cubes, or
-- the cube mode's drawn ones).
-- simplified: the patch is taken to land on the floor, whatever the
-- sun's height, and nothing outside shades a window
--
-- **The room table**, eight texels a row (Palette.glsl's RoomTexel). By
-- the room's slot: the bounce as sqrt(L / 16) and whether the room's
-- probes are there to light it (alpha); its first probe row and their
-- number (/ 255); its box (M.room_probes): the corner's x and z, the
-- extents along and across, the along axis's x and z, the floor's and the
-- ceiling's height. By a probe's row: its x and z, and its y and its
-- room's slot (/ 255). A length is
-- 16 bits in two bytes, 4 mm a step from -131 m; the axis 16 bits from -1
-- to 1.
M.ROOM_TABLE_ROWS = 256
function M.room_bounce(tx, h, tz, light)
	M.bounce_args = {tx, h, tz, light}
	local image = M.room_table_image
	if not image then
		image = magic.Image:new()
		assert(image:SetSize(8, M.ROOM_TABLE_ROWS, 4), "room table image")
		assert(magic.cache:AddManualResource(image, "fp_room_table_image"),
				"room table image in the cache")
		M.room_table_image = image
	end
	-- The texels as one list (buildat.set_image_data), four numbers each
	local W8 = 8
	local v = {}
	for i = 1, W8 * M.ROOM_TABLE_ROWS * 4 do
		v[i] = 0
	end
	local function put(x, y, r, g, b, a)
		local i = (y * W8 + x) * 4
		v[i + 1], v[i + 2], v[i + 3], v[i + 4] = r, g, b, a
	end
	local function c16(x, y, a, b, unit)
		local function k(val)
			if unit then
				return math.max(0, math.min(65535, math.floor((val + 1) * 32767.5 + 0.5)))
			end
			return math.max(0, math.min(65535, math.floor(val / 0.004 + 0.5) + 32768))
		end
		local ka, kb = k(a), k(b)
		put(x, y, math.floor(ka / 256) / 255, ka % 256 / 255,
				math.floor(kb / 256) / 255, kb % 256 / 255)
	end
	local e = h > 0 and light.sun or 0
	local sc = light.sun_color
	local drawn = S.lighting == "pbr_cube"
	for slot, rl in pairs(M.room_light) do
		local c = {0, 0, 0}
		if e > 0 then
			local flux = 0
			for _, w in ipairs(rl.wins) do
				flux = flux + w.a * e * math.max(0, w.ox * tx + w.oz * tz)
			end
			local k = flux / math.max(rl.area, 1) / 0.5 / math.pi
			c = {k * rl.floor.r * sc.r, k * rl.floor.g * sc.g, k * rl.floor.b * sc.b}
		end
		local pr = M.probe_rows[slot]
		local ready = pr ~= nil
		if pr and drawn then
			for row = pr.first, pr.first + pr.n - 1 do
				ready = ready and M.probe_ready[row] == true
			end
		end
		put(0, slot, math.sqrt(math.min(c[1], 16) / 16),
				math.sqrt(math.min(c[2], 16) / 16),
				math.sqrt(math.min(c[3], 16) / 16), ready and 1 or 0)
		if pr then
			put(1, slot, pr.first / 255, pr.n / 255, 0, 0)
			local b = pr.box
			c16(2, slot, b.ox, b.oz)
			c16(3, slot, b.lu, b.lv)
			c16(4, slot, b.ux, b.uz, true)
			c16(5, slot, b.y0, b.y1)
		end
	end
	-- By a probe's row: its place, and its room's slot
	for row, at in pairs(M.probe_pos) do
		c16(6, row, W(at.x), W(at.z))
		c16(7, row, W(at.y), 0)
		v[(row * W8 + 7) * 4 + 3] = (M.row_owner[row] or 0) / 255
	end
	buildat.set_image_data(image, v)
	local texture = M.room_table
	if not texture then
		texture = magic.Texture2D:new()
		texture:SetNumLevels(1)
		-- Held by the cache, and read by name by the grid's pass
		-- (fp_grid.xml)
		assert(magic.cache:AddManualResource(texture, "fp_room_table"),
				"room table in the cache")
		M.room_table = texture
	end
	assert(texture:SetData(image), "room table texture")
	texture.filterMode = magic.FILTER_NEAREST
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetTexture(magic.TU_SPECULAR, texture)
	end
	M.cpu_cubes(tx, h, tz, light)
end

-- **The probes' light worked out here** (plain PBR, user 2026-10-01: the
-- mode without the drawn probes, to come close to the path-traced
-- reference too): each probe's cells (M.PROBE_K by M.PROBE_K a face, as
-- the reduce pass has the drawn ones) as they would have seen the room's
-- box. Where a cell's middle looks, the box is the room's surfaces -- the
-- ceiling up, the floor down, the walls round -- at their albedo times
-- the room's light, as an integrating sphere has it: the sky's flux
-- through the glass spread over the surfaces, and what they and the
-- sun's patches send on, again and again (1 / (1 - the mean albedo), a
-- channel at a time, which is the room's colour cast); and on them the
-- sources, by the share of the cell that sees them: each window's view
-- of half sky and half ground, and each sun's patch, the window's area
-- where the sun through its middle lands on the box, at that face's
-- albedo times the sun on it. Palette.glsl puts the cells back on the box
-- for each surface, near and far as they are. In a 6 * K * K by
-- PROBE_ROWS texture as sqrt(L / 16).
-- simplified: a window and a patch are discs; glass between rooms lets
-- nothing through; a source is not shaded; the surfaces are lit evenly
M.PROBE_K = 2
M.FACE_AXES = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1},
		{0, 0, -1}}
-- Each face's right and up, as Palette.glsl's ProbeSample has the face
-- cameras' (PROBE_FACES)
M.FACE_RU = {{{0, 0, -1}, {0, 1, 0}}, {{0, 0, 1}, {0, 1, 0}},
		{{1, 0, 0}, {0, 0, -1}}, {{1, 0, 0}, {0, 0, 1}},
		{{1, 0, 0}, {0, 1, 0}}, {{-1, 0, 0}, {0, 1, 0}}}
-- Where a ray from p (local to the box: along, up, across) leaves the box,
-- and the face's inward normal
function M.box_exit(b, p, d)
	local lo, hi = {0, b.y0, 0}, {b.lu, b.y1, b.lv}
	local tmin, axis = math.huge, 1
	for i = 1, 3 do
		if math.abs(d[i]) > 1e-9 then
			local t = ((d[i] > 0 and hi[i] or lo[i]) - p[i]) / d[i]
			if t < tmin then
				tmin, axis = t, i
			end
		end
	end
	local n = {0, 0, 0}
	n[axis] = d[axis] > 0 and -1 or 1
	tmin = math.max(tmin, 0)
	return {p[1] + d[1] * tmin, p[2] + d[2] * tmin, p[3] + d[3] * tmin}, n
end
function M.cpu_cubes(tx, h, tz, light)
	local K = M.PROBE_K
	local image = M.cpu_cells_init()
	M.cpu_cube = {}
	-- The texels as one list (buildat.set_image_data)
	local cw = 6 * K * K
	local v = {}
	for i = 1, cw * M.PROBE_ROWS * 4 do
		v[i] = 0
	end
	local rgb = M.ground_rgb()
	local function lin(v)
		return (v / 255) ^ 2.2
	end
	local ground = {lin(math.floor(rgb / 65536)), lin(math.floor(rgb / 256) % 256),
			lin(rgb % 256)}
	local sky = {light.ambient.r, light.ambient.g, light.ambient.b}
	local sc = {light.sun_color.r, light.sun_color.g, light.sun_color.b}
	local e_sun = h > 0 and light.sun or 0
	local view = {}
	for c = 1, 3 do
		view[c] = 0.5 * sky[c] + 0.5 * ground[c] * (e_sun * math.max(h, 0) / math.pi + sky[c])
	end
	for slot, pr in pairs(M.probe_rows) do
		local rl = M.room_light[slot]
		local b = pr.box
		if rl and b then
			local function ch(t)
				return {t.r, t.g, t.b}
			end
			local rf, rc, rw = ch(rl.floor), ch(rl.ceiling), ch(rl.wall)
			local function albedo(n)
				return n[2] > 0.5 and rf or n[2] < -0.5 and rc or rw
			end
			-- The scene's frame to the box's: along, up, across
			local function loc(x, y, z)
				local dx, dz = x - b.ox, z - b.oz
				return {dx * b.ux + dz * b.uz, y, -dx * b.uz + dz * b.ux}
			end
			local function dir(x, y, z)
				return {x * b.ux + z * b.uz, y, -x * b.uz + z * b.ux}
			end
			local A = math.max(rl.area, 1)
			-- The sources, discs on the box: middle, inward normal, area,
			-- radiance
			local sources = {}
			local phi_win, phi_ref = {0, 0, 0}, {0, 0, 0}
			local s = dir(tx, h, tz)
			for _, w in ipairs(rl.wins) do
				-- The window on its wall's face of the box: its middle (on
				-- the wall's line) brought onto the box, facing in
				local c = loc(w.x, w.y, w.z)
				local at = {math.max(0, math.min(b.lu, c[1])),
						math.max(b.y0, math.min(b.y1, c[2])), math.max(0, math.min(b.lv, c[3]))}
				local inward = dir(-w.ox, 0, -w.oz)
				local n = math.abs(inward[1]) > math.abs(inward[3]) and
						{inward[1] > 0 and 1 or -1, 0, 0} or {0, 0, inward[3] > 0 and 1 or -1}
				sources[#sources + 1] = {p = at, n = n, a = w.a, l = view}
				for i = 1, 3 do
					phi_win[i] = phi_win[i] + math.pi * view[i] * w.a
				end
				local cosw = w.ox * tx + w.oz * tz
				if e_sun > 0 and cosw > 0 then
					local pp, pn = M.box_exit(b, at, {-s[1], -s[2], -s[3]})
					local cosf = math.max(0.05, s[1] * pn[1] + s[2] * pn[2] + s[3] * pn[3])
					local alb = albedo(pn)
					local lp = {}
					for i = 1, 3 do
						phi_ref[i] = phi_ref[i] + alb[i] * e_sun * cosw * w.a * sc[i]
						lp[i] = alb[i] * e_sun * cosf * w.through * sc[i] / math.pi
					end
					sources[#sources + 1] = {p = pp, n = pn,
							a = math.min(w.a / w.through * cosw / cosf, rl.floor_area), l = lp}
				end
			end
			-- The surfaces' irradiance: the sky's direct, spread, and what
			-- has been reflected once or more
			local eu = {}
			for i = 1, 3 do
				local mean = (rl.floor_area * (rf[i] + rc[i]) + rl.wall_area * rw[i]) / A
				eu[i] = phi_win[i] / A + (phi_ref[i] + mean * phi_win[i]) /
						(A * (1 - math.min(mean, 0.95)))
			end
			for row = pr.first, pr.first + pr.n - 1 do
				local pw = M.probe_pos[row]
				local q = loc(W(pw.x), W(pw.y), W(pw.z))
				local cells = {}
				for f = 1, 6 do
					local fa, ru = M.FACE_AXES[f], M.FACE_RU[f]
					for cy = 0, K - 1 do
						for cx = 0, K - 1 do
							-- Three by three looks in the cell, at what the box
							-- is there
							local sum = {0, 0, 0}
							for sy = 0, 2 do
								for sx = 0, 2 do
									local a = 2 * (cx + (sx + 0.5) / 3) / K - 1
									local bb = 1 - 2 * (cy + (sy + 0.5) / 3) / K
									local d = dir(fa[1] + ru[1][1] * a + ru[2][1] * bb,
											fa[2] + ru[1][2] * a + ru[2][2] * bb,
											fa[3] + ru[1][3] * a + ru[2][3] * bb)
									local hp, hn = M.box_exit(b, q, d)
									local alb = albedo(hn)
									local l = {alb[1] * eu[1] / math.pi,
											alb[2] * eu[2] / math.pi, alb[3] * eu[3] / math.pi}
									for _, src in ipairs(sources) do
										local dx, dy, dz = hp[1] - src.p[1], hp[2] - src.p[2],
												hp[3] - src.p[3]
										if hn[1] * src.n[1] + hn[2] * src.n[2] +
												hn[3] * src.n[3] > 0.9 and
												dx * dx + dy * dy + dz * dz < src.a / math.pi then
											l = src.l
										end
									end
									for i = 1, 3 do
										sum[i] = sum[i] + l[i] / 9
									end
								end
							end
							cells[#cells + 1] = sum
						end
					end
				end
				M.cpu_cube[row] = cells
				for i, c in ipairs(cells) do
					local o = (row * cw + i - 1) * 4
					v[o + 1] = math.sqrt(math.min(c[1], 16) / 16)
					v[o + 2] = math.sqrt(math.min(c[2], 16) / 16)
					v[o + 3] = math.sqrt(math.min(c[3], 16) / 16)
					v[o + 4] = 1
				end
			end
		end
	end
	buildat.set_image_data(image, v)
	assert(M.cpu_cube_texture:SetData(image), "cpu cubes texture")
	M.cpu_cube_texture.filterMode = magic.FILTER_NEAREST
	M.grid_bake()
end
-- The worked out cells' image and texture, by name for the grid's pass:
-- held by the cache, as one nothing holds is freed under the next SetData
function M.cpu_cells_init()
	if not M.cpu_cube_image then
		local image = magic.Image:new()
		assert(image:SetSize(6 * M.PROBE_K * M.PROBE_K, M.PROBE_ROWS, 4),
				"cpu cubes image")
		local texture = magic.Texture2D:new()
		texture:SetNumLevels(1)
		assert(magic.cache:AddManualResource(image, "fp_cpu_cubes_image"),
				"cpu cubes image in the cache")
		assert(magic.cache:AddManualResource(texture, "fp_cpu_cubes"),
				"cpu cubes in the cache")
		assert(texture:SetData(image), "cpu cubes texture")
		M.cpu_cube_image, M.cpu_cube_texture = image, texture
	end
	return M.cpu_cube_image
end
-- The rooms' grid drawn again, at the next frame, when what it is from has
-- changed: the room table, the worked out cells, the mode
function M.grid_bake()
	if M.probe then
		M.probe.grid_surface:QueueUpdate()
	end
end

-- **A probe in each room** (3D lighting "PBR with room cube maps", user,
-- 2026-10-01): the room seen from its middle in six 90 degree faces,
-- drawn in HDR into a row of an atlas, PROBE_T a face, a row a room slot;
-- and each face averaged into a texel of a 6 by PROBE_ROWS table by the
-- reduce pass (probe_reduce.xml), which is the ambient cube a surface
-- takes its indirect light from (Palette.glsl). One face is drawn a
-- frame, round all the rooms, so a change in the light reaches a room's
-- probe in a second or so for ten rooms. Each face sees the probes of the
-- frames before, so the light bounces on.
-- simplified: one probe a room, so all of a room is lit as from its
-- middle; a slot over PROBE_ROWS - 1 has none, and its room is lit as
-- without the cubes. A float16 render target has no mips on the driver
-- this was written on (extensions/launch_world's [PBR_HDR] finding), so
-- the average is the reduce pass's and a reflection is sharp.
local PROBE_T, PROBE_ROWS = 32, 64
M.PROBE_ROWS = PROBE_ROWS
-- Pitch and yaw of each face's camera: +X, -X, +Y, -Y, +Z, -Z, which is
-- the order and the axes Palette.glsl's ProbeUV reads them in
local PROBE_FACES = {{0, 90}, {0, -90}, {-90, 0}, {90, 0}, {0, 0}, {0, 180}}
local function probes_init()
	if M.probe then
		return M.probe
	end
	local p = {i = 0}
	local f16 = magic.Graphics.GetRGBAFloat16Format()
	local atlas = magic.Texture2D:new()
	atlas:SetNumLevels(1)
	assert(atlas:SetSize(6 * PROBE_T, PROBE_ROWS * PROBE_T, f16,
			magic.TEXTURE_RENDERTARGET), "the probes' atlas")
	atlas.filterMode = magic.FILTER_BILINEAR
	-- By name, for the reduce pass's render path to read
	assert(magic.cache:AddManualResource(atlas, "fp_probe_atlas"),
			"the probes' atlas in the cache")
	local reduce = magic.Texture2D:new()
	reduce:SetNumLevels(1)
	assert(reduce:SetSize(6 * M.PROBE_K * M.PROBE_K, PROBE_ROWS, f16,
			magic.TEXTURE_RENDERTARGET),
			"the probes' ambient cubes")
	reduce.filterMode = magic.FILTER_NEAREST
	-- and for the frame's white (FpFrame.glsl)
	assert(magic.cache:AddManualResource(reduce, "fp_probe_reduce"),
			"the probes' ambient cubes in the cache")
	local function view(texture, xml, fov)
		local node = scene:CreateChild("probe camera")
		local cam = node:CreateComponent("Camera")
		cam.fov = fov
		cam.aspectRatio = 1
		cam.nearClip = 0.05
		cam.farClip = 500
		local vp = magic.Viewport:new(scene, cam)
		local rp = vp.renderPath:Clone()
		rp:Load(magic.cache:GetResource("XMLFile", xml))
		vp.renderPath = rp
		local surface = texture:GetRenderSurface()
		surface:SetViewport(0, vp)
		surface.updateMode = magic.SURFACE_MANUALUPDATE
		M.kept[#M.kept + 1] = vp
		return node, vp, surface
	end
	p.node, p.vp, p.surface = view(atlas, "RenderPaths/Deferred.xml", 90)
	local _, _, rsurface = view(reduce, "main/probe_reduce.xml", 90)
	p.reduce_surface = rsurface
	p.atlas, p.reduce = atlas, reduce
	M.kept[#M.kept + 1] = atlas
	M.kept[#M.kept + 1] = reduce
	-- **The rooms' grid** (GridBake.glsl): GRID_U * 6 by 64 rooms'
	-- GRID_Y * GRID_V, what a surface's light is read from in both modes;
	-- drawn from either mode's cells, which are there by name before
	M.cpu_cells_init()
	local grid = magic.Texture2D:new()
	grid:SetNumLevels(1)
	assert(grid:SetSize(48, PROBE_ROWS * 24, f16, magic.TEXTURE_RENDERTARGET),
			"the rooms' grid")
	grid.filterMode = magic.FILTER_BILINEAR
	assert(magic.cache:AddManualResource(grid, "fp_room_grid"),
			"the rooms' grid in the cache")
	local _, gvp, gsurface = view(grid, "main/fp_grid.xml", 90)
	p.grid, p.grid_vp, p.grid_surface = grid, gvp, gsurface
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetTexture(magic.TU_NORMAL, atlas)
		m:SetTexture(magic.TU_EMISSIVE, grid)
	end
	M.probe = p
	return p
end
M.probes_init = probes_init

-- Each frame: which probes light the rooms (the shader's RoomCubes: 0
-- none, 1 the drawn ones, 2 M.cpu_cubes'), and under the cube mode the
-- next face of the next probe
function M.probes_tick()
	local mode = not M.pbr_now() and 0 or S.lighting == "pbr_cube" and 1 or 2
	if mode ~= M.cube_mode then
		M.cube_mode = mode
		local p = mode > 0 and probes_init()
		for _, m in ipairs({lit_material, glass_material}) do
			m:SetShaderParameter("RoomCubes", mode)
		end
		if p then
			-- The grid from this mode's cells
			p.grid_vp.renderPath:SetShaderParameter("RoomCubes", mode)
			M.grid_bake()
		end
		-- The room table's readiness is the mode's
		S.daylight_key = nil
	end
	if mode ~= 1 then
		return
	end
	local p = probes_init()
	local rows = {}
	for row in pairs(M.probe_pos) do
		rows[#rows + 1] = row
	end
	if #rows == 0 then
		return
	end
	table.sort(rows)
	p.i = p.i % (#rows * 6)
	local row = rows[math.floor(p.i / 6) + 1]
	local face = p.i % 6
	p.i = p.i + 1
	local at = M.probe_pos[row]
	p.node.position = magic.Vector3(W(at.x), W(at.y), W(at.z))
	p.node.rotation = magic.Quaternion(PROBE_FACES[face + 1][1],
			PROBE_FACES[face + 1][2], 0)
	p.vp:SetRect(magic.IntRect(face * PROBE_T, row * PROBE_T,
			(face + 1) * PROBE_T, (row + 1) * PROBE_T))
	p.surface:QueueUpdate()
	p.reduce_surface:QueueUpdate()
	p.grid_surface:QueueUpdate()
	if face == 5 and not M.probe_ready[row] then
		M.probe_ready[row] = true
		if M.bounce_args then
			local a = M.bounce_args
			M.room_bounce(a[1], a[2], a[3], a[4])
		end
	end
end
-- One value for what is built in its own frame: the room it stands in, or
-- for a door or a window the darker of the two it is between; and for
-- those, the two, on the side of the frame's normal first
function M.inst_occlusion(it)
	local function at(x, z)
		local id = room_at(x, z)
		return id and M.room_occ[id] or 0
	end
	if it.hosted and it.frame then
		local f = it.frame
		local off = f.lo + f.ro + 100
		-- The darker of the two by the occ part (slot + occ, packed)
		local a = at(it.x + f.nx * off, it.z + f.nz * off)
		local b = at(it.x - f.nx * off, it.z - f.nz * off)
		return (a % 1) >= (b % 1) and a or b, a, b
	end
	return at(it.x, it.z)
end

-- wells: {floor = {pts, ...}, ceiling = {pts, ...}}, the stairwells cut in
-- this layout's rooms
-- **A foundation from the ground up to the floor** (user): set by
-- rebuild() for a building's lowest layout when it is above the ground,
-- {h = its height in mm, mat = the palette entry}, else nil
local foundation = nil

-- The time since the last lap into M.laps[name], in ms, over a rebuild
M.lap_order = {"ground", "data", "walls", "rooms", "openings", "objects",
		"voxels", "lamps", "images", "rest"}
function M.lap(name)
	local t = buildat.get_time_us()
	M.laps[name] = (M.laps[name] or 0) + (t - M.lap_t) / 1000
	M.lap_t = t
end
-- [FP_MOVE_FAST] The nodes built for an instance alone, which a drag of it
-- moves (M.rebuild_light): its box or stairs, its caps and its lamp's
-- light; M.geo_owner the instance being built, for geometry()
function M.own_node(node)
	local id = M.geo_owner
	if id then
		local l = E.inst_nodes[id] or {}
		l[#l + 1] = node
		E.inst_nodes[id] = l
	end
end
local function build_layout(seen_voxels, wells)
	E.solids = {}
	E.wall_data = {}
	E.inst_nodes = {}
	for _, e in ipairs(of_type("wall")) do
		local w = e.ints
		local ax, az = node_pos(w.a)
		local bx, bz = node_pos(w.b)
		E.wall_data[e.id] = {ax = ax, az = az, bx = bx, bz = bz,
				a_node = w.a, b_node = w.b, thickness = w.thickness,
				justify = w.justify, shift = w.shift,
				-- Joined with what is at its height: one that hangs clear
				-- of the floor apart from the standing ones, but one hung
				-- from the ceiling all the way down is standing (user:
				-- such a corner was open outside)
				group = (wall_span(w)) > 0 and 1 or 0}
	end
	E.outlines = geom.wall_outlines(E.wall_data)
	build_room_data()
	build_inst_data()
	M.room_occlusion()
	M.lap("data")
	local cut = settings().cut
	-- A part's triangles, gathered in Lua and handed to the engine by
	-- commit() in one call (see tri())
	local function geometry(parent)
		local node = parent:CreateChild("")
		E.built[#E.built + 1] = node
		M.own_node(node)
		local g = {node = node}
		TRI_LISTS[g] = {}
		return g, node
	end
	local function commit(g, material)
		-- A door's or a window's face takes the room it is in front of, as
		-- a wall's does (tri_occ_fn), by where it is in the layout's frame
		-- with the node's turn about Y; one inside the wall, the side of
		-- the wall it faces or, square to the wall in the opening, is on
		local sides, list = M.tri_sides, TRI_LISTS[g]
		if sides then
			local d, o = g.node.direction, g.node.position
			local dx, dz = d.x, d.z
			for k = 0, #list - 36, 36 do
				local nx, nz = list[k + 4], list[k + 6]
				local wx, wz = nx * dz + nz * dx, nz * dz - nx * dx
				local lx = (list[k + 1] + list[k + 13] + list[k + 25]) / 3
				local lz = (list[k + 3] + list[k + 15] + list[k + 27]) / 3
				local px = o.x + lx * dz + lz * dx
				local pz = o.z + lz * dz - lx * dx
				local id = room_at((px + wx * 0.05) * 1000, (pz + wz * 0.05) * 1000)
				local s = wx * sides.nx + wz * sides.nz
				if math.abs(s) <= 0.01 then
					s = (px * 1000 - sides.x) * sides.nx + (pz * 1000 - sides.z) * sides.nz
				end
				local occ = id and M.room_occ[id] or (s > 0 and sides.a or sides.b)
				list[k + 12], list[k + 24], list[k + 36] = occ, occ, occ
			end
		end
		M.lap_tris = M.lap_tris + #list / 36
		buildat.set_triangle_geometry(g.node, list)
		TRI_LISTS[g] = nil
		local cg = g.node:GetComponent("CustomGeometry")
		cg:SetMaterial(0, material)
		-- Everything in the sun's way casts its shadow but the glass, which
		-- is how daylight comes in ([FP_DAYLIGHT])
		cg.castShadows = material ~= glass_material
	end
	-- What the plan view shows where the cut goes through something: dark
	-- where it is cut, lighter for what is below the cut
	local function cap(pts, y0, y1, cut_col, low_col)
		if y0 < cut then
			local cg = geometry(P.caps)
			flat_polygon(cg, pts, math.min(y1, cut) - 3, M.UP3, y1 >= cut and
					cut_col or low_col)
			commit(cg, flat_material)
		end
	end

	-- An outline extruded between y0 and y1, its faces coloured by label
	local function extrude(g, pts, labels, y0, y1, cols, bottom)
		flat_polygon(g, pts, y1, M.UP3, cols.core)
		if bottom then
			flat_polygon(g, pts, y0, M.DOWN3, cols.core)
		end
		local function v(p, y)
			return V3(W(p[1]), W(y), W(p[2]))
		end
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local dx, dz = q[1] - p[1], q[2] - p[2]
			local l = geom.len(dx, dz)
			if l > 0.01 then
				-- Outward of a counter-clockwise outline is to the right
				local n = V3(dz / l, 0, -dx / l)
				local col = cols[labels[i]]
				tri(g, v(p, y0), v(q, y0), v(q, y1), n, col)
				tri(g, v(p, y0), v(q, y1), v(p, y1), n, col)
			end
		end
	end

	-- The openings in each wall, by where they are along it
	local holes = {}
	for id, it in pairs(E.inst_data) do
		if it.hosted and E.doc.ents[it.def].ints.kind ~= KIND.switch then
			local host = E.doc.ents[id].ints.host
			local p = E.doc.ents[it.def].ints
			holes[host] = holes[host] or {}
			table.insert(holes[host], {c = it.along, w = p.w,
					sill = E.doc.ents[id].ints.sill, h = p.h})
		end
	end

	-- A wall is cut along its length into slabs: whole ones between the
	-- openings, and at each opening the part below its sill and the part
	-- above its head. The faces the cuts make are the reveals.
	for id, o in pairs(E.outlines) do
		local w = E.doc.ents[id].ints
		local y0, y1 = wall_span(w)
		local cols = {
			left = row(w.mat_left),
			right = row(w.mat_right),
			core = row(w.mat_core ~= 0 and w.mat_core or w.mat_left),
		}
		local f = wall_frame(id)
		local list = holes[id] or {}
		table.sort(list, function(a, b) return a.c < b.c end)
		local slabs, prev = {}, -math.huge
		for _, h in ipairs(list) do
			local s0, e0 = h.c - h.w / 2, h.c + h.w / 2
			if s0 > prev then
				slabs[#slabs + 1] = {prev, s0}
			end
			slabs[#slabs + 1] = {math.max(s0, prev), e0, h}
			prev = math.max(prev, e0)
		end
		slabs[#slabs + 1] = {prev, math.huge}
		local d0 = f and f.ax * f.ux + f.az * f.uz or 0
		if foundation then
			local g = geometry(P.walls)
			local labels = {}
			for i = 1, #o.pts do
				labels[i] = "core"
			end
			extrude(g, o.pts, labels, -foundation.h, 0,
					{core = row(foundation.mat)}, false)
			commit(g, lit_material)
		end
		for _, sl in ipairs(slabs) do
			local pts, labels = o.pts, o.sides
			if f and sl[1] > -math.huge then
				pts, labels = geom.clip(pts, labels, -f.ux, -f.uz, -(d0 + sl[1]),
						"core")
			end
			if f and sl[2] < math.huge then
				pts, labels = geom.clip(pts, labels, f.ux, f.uz, d0 + sl[2], "core")
			end
			local parts = {{y0, y1}}
			if sl[3] then
				parts = {{y0, math.min(y1, sl[3].sill)},
						{math.max(y0, sl[3].sill + sl[3].h), y1}}
			end
			if #pts >= 3 then
				for _, part in ipairs(parts) do
					if part[2] - part[1] > 0.5 then
						local g = geometry(P.walls)
						extrude(g, pts, labels, part[1], part[2], cols, part[1] > 0)
						commit(g, lit_material)
						cap(pts, part[1], part[2], magic.Color(0.16, 0.16, 0.18),
								magic.Color(0.55, 0.55, 0.58))
						E.solids[#E.solids + 1] = {pts = pts, y0 = part[1],
								y1 = part[2]}
					end
				end
			end
		end
	end

	M.lap("walls")
	for id, r in pairs(E.room_data) do
		local e = E.doc.ents[id]
		-- The foundation under the floor too, where a room has no walls
		if foundation and #r.pts >= 3 then
			local g = geometry(P.walls)
			local labels = {}
			for i = 1, #r.pts do
				labels[i] = "core"
			end
			extrude(g, r.pts, labels, -foundation.h, 0,
					{core = row(foundation.mat)}, false)
			commit(g, lit_material)
		end
		if #r.pts >= 3 then
			local g = geometry(P.walls)
			r.floor = geom.minus(r.pts, wells.floor)
			for _, pts in ipairs(r.floor) do
				flat_polygon(g, pts, 2, M.UP3, row(e.ints.mat_floor))
			end
			commit(g, lit_material)
			local cg = geometry(P.overhead)
			for _, pts in ipairs(geom.minus(r.pts, wells.ceiling)) do
				flat_polygon(cg, pts, room_ceiling(e), M.DOWN3,
						row(e.ints.mat_ceiling))
			end
			commit(cg, lit_material)
			-- A slab over it for the sun's shadow alone, 300 mm thick and
			-- out past the walls: the thin wall tops and the ceiling
			-- leaked a line of daylight where they meet ([FP_DAYLIGHT])
			local offs = {}
			for i = 1, #r.pts do
				offs[i] = -300
			end
			local slab_pts = geom.inset(r.pts, offs)
			if #slab_pts >= 3 then
				local sg = geometry(P.overhead)
				local c0 = room_ceiling(e)
				local labels = {}
				for i = 1, #slab_pts do
					labels[i] = "core"
				end
				extrude(sg, slab_pts, labels, c0, c0 + 300, {core = 0}, true)
				commit(sg, M.shadow_material)
			end
		end
	end

	M.lap("rooms")
	local occ_fn = M.tri_occ_fn
	M.tri_occ_fn = nil
	local kind
	for id, it in pairs(E.inst_data) do
		if kind then
			M.lap(kind)
		end
		kind = it.hosted and "openings" or "objects"
		local def = E.doc.ents[it.def].ints
		local e = E.doc.ents[id].ints
		M.geo_owner = (def.kind == KIND.box or def.kind == KIND.stairs) and id
				or nil
		local occ, a, b = M.inst_occlusion(it)
		M.tri_occ = occ
		-- A door's or a window's faces each their own room (commit):
		-- the darker one's was black on the lit side of a door to a room
		-- with no window and its lamp off
		M.tri_sides = a and {a = a, b = b, nx = it.frame.nx, nz = it.frame.nz,
				x = it.x, z = it.z}
		if it.hosted then
			build_hosted(id, it, def, e, geometry, commit)
			-- A window and a shut door are in the way; an open door is not
			-- simplified: the opening, not the leaf where it has swung to
			if def.kind == KIND.window or (def.kind == KIND.door and
					open_amount(id) < 300) then
				E.solids[#E.solids + 1] = {pts = it.foot, y0 = it.y0, y1 = it.y1}
			end
		elseif def.kind == KIND.box then
			local g, node = geometry(e.align == 1 and P.overhead or P.walls)
			node.position = magic.Vector3(W(it.x), W(it.y), W(it.z))
			node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
			local rgb = M.cap_rgb(def.mat)
			box_geometry(g, W(def.w) / 2, W(def.h) / 2, W(def.d) / 2,
					row(def.mat), nil, nil, nil,
					M.tech_tint() or not lamp_on(id) and UNLIT or nil)
			commit(g, lit_material)
			cap(it.foot, it.y0, it.y1, rgb_color(rgb, 0.7), rgb_color(rgb, 0.9))
			E.solids[#E.solids + 1] = {pts = it.foot, y0 = it.y0, y1 = it.y1}
		elseif def.kind == KIND.stairs then
			-- A box a step, and a solid a step to walk up
			local g, node = geometry(e.align == 1 and P.overhead or P.walls)
			node.position = magic.Vector3(W(it.x), W(it.y), W(it.z))
			node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
			local rgb = M.cap_rgb(def.mat)
			local flat = it.pitch % 360 == 0 and it.roll % 360 == 0
			for _, b in ipairs(geom.stair_steps(def.w, def.h, def.d, def.steps)) do
				box_geometry(g, W(b[4] - b[1]) / 2, W(b[5] - b[2]) / 2,
						W(b[6] - b[3]) / 2, row(def.mat), W(b[1] + b[4]) / 2,
						W(b[2] + b[5]) / 2, W(b[3] + b[6]) / 2, M.tech_tint())
				-- simplified: stairs pitched or rolled are walked as their box
				if flat then
					local pts = {}
					for k, c in ipairs({{b[1], b[3]}, {b[4], b[3]}, {b[4], b[6]},
							{b[1], b[6]}}) do
						local px, _, pz = geom.rot(c[1], 0, c[2], 0, it.yaw, 0)
						pts[k] = {it.x + px, it.z + pz}
					end
					if not geom.is_ccw(pts) then
						pts = {pts[4], pts[3], pts[2], pts[1]}
					end
					E.solids[#E.solids + 1] = {pts = pts, y0 = it.y + b[2],
							y1 = it.y + b[5]}
					-- A cap a step, inside it: one over the whole footprint
					-- floated over the low steps, the caps being drawn in 3D too
					cap(pts, it.y + b[2], it.y + b[5], rgb_color(rgb, 0.7),
							rgb_color(rgb, 0.9))
				end
			end
			commit(g, lit_material)
			if not flat then
				E.solids[#E.solids + 1] = {pts = it.foot, y0 = it.y0, y1 = it.y1}
			end
		end
	end
	M.tri_occ, M.tri_occ_fn, M.tri_sides = 0, occ_fn, nil
	M.geo_owner = nil
	-- A floor is something to stand on, when walking up to another layout
	for _, r in pairs(E.room_data) do
		for _, pts in ipairs(r.floor or {}) do
			E.solids[#E.solids + 1] = {pts = pts, y0 = 0, y1 = 0, floor = true}
		end
	end
	M.lap(kind or "objects")
	update_voxel_meshes(seen_voxels)
	M.lap("voxels")
	build_lamps(geometry)
	M.lap("lamps")
	-- The pictures traced over and the material ids are the current
	-- layout's; seen from above another's are clutter
	E.image_data = {}
	if S.view_layout == S.layout then
		build_images()
		build_decals()
	end
	M.lap("images")
end

-- The layouts' own inst_data and where each is, for the walker's voxels:
-- {{insts, rel}, ...}
place.layers = {}

-- simplified: every layout is rebuilt on any change
rebuild = function()
	M.build_gen = M.build_gen + 1
	M.lap_t, M.laps, M.lap_tris = buildat.get_time_us(), {}, 0
	local t0 = M.lap_t
	palette_texture()
	M.build_ground()
	M.lap("ground")
	for _, n in ipairs(E.built) do
		n:Remove()
	end
	E.built = {}
	local cur = place.current()
	local order = {}
	for _, l in ipairs(E.doc.of_type("layout")) do
		if l.id ~= S.layout then
			order[#order + 1] = l
		end
	end
	-- The current one last, so what the tools read is its
	if S.layout then
		order[#order + 1] = E.doc.ents[S.layout]
	end
	local seen_voxels, all_solids = {}, {}
	place.layers = {}
	-- [FP_FLOOR_AREA] Each layout's rooms' net floor, summed: what their
	-- labels on the plan add up to (none for a layout with no rooms)
	local areas = {}
	M.room_light, M.room_seen = {}, {}
	-- Which layouts are above the current one, for S.hide_above; what is
	-- built new is shown, so the hiding is done again
	place.above, place.shown = {}, {}
	local wells = place.stairwells(order, cur)
	-- Each building's lowest floor, which a foundation goes under
	local lowest = {}
	for _, l in ipairs(order) do
		local g = l.strs.group
		lowest[g] = math.min(lowest[g] or math.huge, l.ints.y)
	end
	for _, l in ipairs(order) do
		local r = place.rel(l.ints, cur)
		local parts = place.parts[l.id]
		if not parts then
			parts = {}
			for k, n in pairs({walls = walls_node, caps = caps_node,
					overhead = overhead_node, pieces = pieces_node,
					images = images_node, decals = decals_node,
					lamps = lamps_node}) do
				parts[k] = n:CreateChild("layout")
			end
			place.parts[l.id] = parts
		end
		for _, n in pairs(parts) do
			n.position = magic.Vector3(W(r.x), W(r.y), W(r.z))
			n.rotation = magic.Quaternion(0, r.yaw, 0)
		end
		place.above[l.id] = r.y > 0
		P, S.view_layout = parts, l.id
		M.cur_rel = r
		foundation = l.ints.y > 0 and l.ints.y == lowest[l.strs.group] and
				{h = l.ints.y, mat = l.ints.mat_foundation} or nil
		build_layout(seen_voxels, wells[l.id])
		foundation = nil
		for _, sd in ipairs(E.solids) do
			local pts = {}
			for k, q in ipairs(sd.pts) do
				local x, _, z = place.point(r, q[1], 0, q[2])
				pts[k] = {x, z}
			end
			all_solids[#all_solids + 1] = {pts = pts, y0 = sd.y0 + r.y,
					y1 = sd.y1 + r.y, floor = sd.floor}
		end
		place.layers[#place.layers + 1] = {id = l.id, insts = E.inst_data, rel = r,
				rooms = E.room_data}
		for _, rd in pairs(E.room_data) do
			areas[l.id] = (areas[l.id] or 0) + rd.net
		end
	end
	-- The layouts menu shows them: drawn again when one changed
	local changed = false
	for id in pairs(areas) do
		changed = changed or areas[id] ~= place.areas[id]
	end
	for id in pairs(place.areas) do
		changed = changed or areas[id] == nil
	end
	place.areas = areas
	if changed and S.layouts_open then
		place.build_window()
	end
	E.solids = all_solids
	-- The slots of rooms that are gone
	for id, slot in pairs(M.room_slot) do
		if not M.room_seen[id] then
			M.room_slot[id], M.slot_owner[slot] = nil, nil
			M.free_rows(slot)
		end
	end
	for id, m in pairs(voxel_meshes) do
		if not seen_voxels[id] then
			m.node:Remove()
			voxel_meshes[id] = nil
		end
	end
	for id, parts in pairs(place.parts) do
		local e = E.doc.ents[id]
		if not e or e.type ~= "layout" then
			for _, n in pairs(parts) do
				n:Remove()
			end
			place.parts[id] = nil
		end
	end
	-- The ground is the world's, under every layout
	ground_node.position = magic.Vector3(0, W(-cur.y), 0)
	pieces_node.enabled = S.view ~= "2d"
	caps_node.enabled = S.view == "2d"
	S.daylight_key = nil
	S.dirty = false
	M.lap("rest")
	-- A slow one in the log, by its parts, for what a drag costs
	-- ([FP_DRAG_COST]); a drag rebuilds each frame
	local ms = (buildat.get_time_us() - t0) / 1000
	local light = M.drag_is_light(S.drag)
	if light == "moved" or (light and ms > 30) then
		S.drag.light = true
	end
	if M.probe_what then
		M.probe_add("rebuild", ms)
	end
	if ms > 30 then
		local parts = {}
		for _, k in ipairs(M.lap_order) do
			parts[#parts + 1] = string.format("%s %.1f", k, M.laps[k] or 0)
		end
		log:info(string.format("rebuild %.1f ms%s, %d triangles: %s", ms,
				S.drag and " (drag " .. tostring(S.drag.kind) .. ")" or "",
				M.lap_tris, table.concat(parts, ", ")))
	end
end
-- **A slow drag of doors and windows rebuilds on release** ([FP_DRAG_COST],
-- user 2026-10-06): once a rebuild of the drag takes over 30 ms, the rest
-- of it only places the instances again, which the plan view's symbols,
-- the outlines and the gaps are drawn from; the walls' holes and the 3D
-- meshes stay where they were until the release (end_drag rebuilds)
-- **[FP_MOVE_FAST] A drag of boxes, stairs and voxel volumes alone moves
-- their nodes** ("moved", at once): each frame the instances placed again
-- and their own nodes (E.inst_nodes, a volume's mesh) put by how far they
-- went, the rest of the scene kept until the release. "hosted" with a
-- door or a window among them, the rule above.
-- simplified: a moved stair does not cut the floors over it again until
-- the release; another client's preview still rebuilds in full
function M.drag_is_light(d)
	if not d or d.kind ~= "move" or next(d.nodes) or not next(d.inst) then
		return false
	end
	local hosted = false
	for id in pairs(d.inst) do
		local it = E.inst_data[id]
		local kind = it and E.doc.ents[it.def].ints.kind
		if not it or not (it.hosted or kind == KIND.box or kind == KIND.stairs or
				kind == KIND.voxel) then
			return false
		end
		hosted = hosted or it.hosted
	end
	return hosted and "hosted" or "moved"
end
function M.rebuild_light()
	local d = S.drag
	-- Where the moved ones' nodes were built, before the drag's first
	-- light frame (a position copied: the property follows the node)
	if d and not d.bases then
		d.bases = {}
		for id in pairs(d.inst or {}) do
			local it = E.inst_data[id]
			local nodes = {}
			for _, n in ipairs(E.inst_nodes and E.inst_nodes[id] or {}) do
				local p = n.position
				nodes[#nodes + 1] = {n, magic.Vector3(p.x, p.y, p.z)}
			end
			d.bases[id] = it and {x = it.x, z = it.z, nodes = nodes}
		end
	end
	-- The current layout's, which rebuild() made last
	build_inst_data()
	place.layers[#place.layers].insts = E.inst_data
	for id, b in pairs(d and d.bases or {}) do
		local it = E.inst_data[id]
		if it then
			local ox, oz = W(it.x - b.x), W(it.z - b.z)
			for _, nb in ipairs(b.nodes) do
				nb[1].position = magic.Vector3(nb[2].x + ox, nb[2].y, nb[2].z + oz)
			end
			local vm = voxel_meshes[id]
			if vm and it.ox then
				vm.node.position = magic.Vector3(W(it.ox), W(it.oy), W(it.oz))
			end
		end
	end
	S.dirty = false
end
end

-- **The plan's daylight** on the 3D view and walking ([FP_DAYLIGHT],
-- daylight.lua): the sun where the plan's place and hour put it, at its
-- irradiance and colour, the sky's ambient and fog, the sky drawn and its
-- cube reflected; or, unlit and in the plan view, the plain look. Each
-- frame, recomputed when the minute (to a tenth), the settings or the
-- mode change.
M.UNLIT = {ambient = magic.Color(0.55, 0.55, 0.58),
		fog = magic.Color(0.55, 0.62, 0.72)}
-- **The moment's settings, saved or this client's** (user, 2026-09-30):
-- the date, the hour, the time-lapse and the ground as the plan has them
-- ("Saved"), or a copy of them this client changes for its own view and
-- sends nowhere ("Temporary", S.sun_temp, for the plan it was made in),
-- which a viewer may change too
function M.sun()
	local t = S.sun_temp
	local base = (t and t.plan == E.doc.plan_name) and t or settings()
	-- A viewport that recalls its moment: its day and minute, still
	local vp = S.vp and E.doc.ents[S.vp]
	if vp and vp.ints.recall == 1 then
		local t2 = {}
		for k, v in pairs(base) do
			t2[k] = v
		end
		t2.day, t2.minute, t2.lapse = vp.ints.day, vp.ints.minute, 0
		return t2
	end
	return base
end
-- The plan's minute now: its own, or on from it at the time-lapse's
-- speed since this client saw it set
-- simplified: from when this client saw it, so two clients that joined
-- apart see a time-lapse apart; the upgrade is the server's clock
function M.plan_minute()
	local st = M.sun()
	-- Real time (user): each viewer's own wall clock, as the solar hour
	-- simplified: the clock's hour, not the sun's at the plan's longitude
	-- (the plan has none) and with summer time in it
	if st.lapse < 0 then
		local _, h, m, sec = buildat.get_local_time()
		return h * 60 + m + sec / 60
	end
	local key = st.minute .. ":" .. st.lapse
	if S.lapse_key ~= key then
		S.lapse_key, S.lapse_t0 = key, buildat.get_time_us()
	end
	if st.lapse == 0 then
		return st.minute
	end
	return (st.minute + st.lapse * (buildat.get_time_us() - S.lapse_t0) / 1e6) % 1440
end
-- The plan's day of the year now: its own, or the viewer's calendar's
-- under "real date and time"
function M.plan_day()
	local st = M.sun()
	if st.lapse == -2 then
		return math.min(365, (buildat.get_local_time()))
	end
	return st.day
end
-- The ground's colour now, as the palette's row and the light's albedo
function M.ground_rgb()
	local st = settings()
	return M.daylight.ground(st.latitude, M.plan_day(), M.sun().ground)
end
-- Whether what is drawn now is PBR: the setting's, and never the plan view
function M.pbr_now()
	return S.lighting ~= "unlit" and S.view ~= "2d"
end
M.MOVE_LIGHT_WAIT = 0.3
function M.apply_daylight()
	local pbr = M.pbr_now()
	local st = settings()
	local minute = pbr and M.plan_minute() or 0
	local day = M.plan_day()
	-- The trees' foot is the ground's, which moves with the floor edited,
	-- and the ground's disc is under the camera
	if M.sky then
		local y = ground_node.position.y
		M.sky.material:SetShaderParameter("TreeGround", y)
		if pbr then
			ground_node.position = magic.Vector3(S.pos.x, y, S.pos.z)
		end
	end
	local key = string.format("%s %.1f %d %d %d %d %d %d", tostring(pbr), minute,
			st.north, st.latitude, day, M.sun().ground, st.treeline, M.sun().sky or 0)
	-- [FP_MOVE_FAST] While things move -- a drag, or key steps less than
	-- MOVE_LIGHT_WAIT apart -- the lighting stays as it was (the rooms'
	-- bounce and the bake are the cost), redone that long after the last
	if key == S.daylight_key or (pbr and M.sky and M.move_t and
			buildat.get_time_us() - M.move_t < M.MOVE_LIGHT_WAIT * 1e6) then
		if pbr and M.sky then
			M.sky:flush()
		end
		return
	end
	S.daylight_key = key
	if pbr and M.probe_what then
		log:info("fp daylight: computed in " .. S.view)
	end
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetShaderParameter("Pbr", pbr and 1 or 0)
	end
	if not pbr then
		sun.enabled, fill.enabled = false, true
		zone.ambientColor, zone.fogColor = M.UNLIT.ambient, M.UNLIT.fog
		if M.sky then
			M.sky:show(false)
		end
		return
	end
	M.sky = M.sky or M.daylight.new_sky(scene)
	M.sky:show(true)
	zone.zoneTexture = M.sky.texture
	local tx, h, tz = M.daylight.sun_toward(st.latitude, st.north, day, minute)
	local rgb = M.ground_rgb()
	local function lin(v)
		return (v / 255) ^ 2.2
	end
	local light = M.daylight.light(h, {r = lin(math.floor(rgb / 65536)),
			g = lin(math.floor(rgb / 256) % 256), b = lin(rgb % 256)},
			M.sun().sky == 1)
	sun.enabled, fill.enabled = light.sun > 0, false
	sun_node.direction = magic.Vector3(-tx, -h, -tz)
	-- The shader's Lambert has no 1/pi, which the irradiance carries here
	sun.brightness = light.sun / math.pi
	local sc = light.sun_color
	sun.color = magic.Color(sc.r, sc.g, sc.b)
	local a, f = light.ambient, light.horizon
	-- The white outdoors (M.wb_tick): a grey card's light, a quarter of
	-- the sun's irradiance over its sphere and half of the sky's
	M.wb_outdoor = {r = sc.r * light.sun / 4 / math.pi + a.r / 2,
			g = sc.g * light.sun / 4 / math.pi + a.g / 2,
			b = sc.b * light.sun / 4 / math.pi + a.b / 2}
	zone.ambientColor = magic.Color(a.r, a.g, a.b)
	zone.fogColor = magic.Color(f.r, f.g, f.b)
	M.sky.material:SetShaderParameter("Treeline", st.treeline / 1000)
	M.room_bounce(tx, h, tz, light)
	M.sky:set(tx, h, tz, h, light)
	-- A changed treeline is in the reflections at once, not when the sun
	-- next moves
	if M.sky.treeline ~= st.treeline then
		M.sky.treeline = st.treeline
		M.sky.cube:update()
	end
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetShaderParameter("SunToward", magic.Vector3(tx, h, tz))
	end
end

E.rebuild, E.instances_of, E.voxel_meshes, E.open_amount =
		rebuild, instances_of, voxel_meshes, open_amount
end
-- vim: set noet ts=4 sw=4:
