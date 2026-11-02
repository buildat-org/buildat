-- Buildat: builtin/kit/client_lua/caps.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_PLAN_CAPS] Kit stage 4e3: what the 2D plan's cut goes through,
-- drawn as floorplanner's caps_node draws it. The plan is a camera at the
-- cut looking down, so a wall, a hill or a box crossing the cut lost its
-- top to the near clip and showed its sides edge-on. Flat quads just under
-- the cut, in a node of their own shown in 2D alone, lit as the voxels'
-- tops are (unlit, under skeldat's HDR path the colours came out nearly
-- black, its exposure being for its sun's radiance):
--   - every solid (physically_solid) cell of the cut's layer (the cells
--     the cut is in, ceil(cut - 0.5): the ones under it where it is at
--     their tops, as the plan's x.5 cuts are, floor(cut)), in its
--     voxel's colour (its top texture's average) darkened, a material's
--     cells merged into rectangles;
--   - the heightmap's ground over the cut, in its material's colour
--     darkened the same;
--   - an entity's look box the cut crosses, its footprint in its colour.
-- The voxels and the heightmap are built a tile at a time (a chunk's
-- column), the ones nearest the view's middle first, a few milliseconds a
-- frame: a tile again when the cut moves, a chunk of the cut's layer is
-- meshed again (a voxel changed, or it arrived), the heightmap
-- changes, or the view goes past the tiles built (a quarter of the view's
-- height round it).
-- Used by editor.lua:
--   local caps = install{O = O, S = S, P = P, color = color, log = log}
--   caps.update(on, aspect)   each frame; on: the 2D view is shown
return function(K)
local O, S, P, color, log = K.O, K.S, K.P, K.color, K.log
local magic = require("buildat/extension/urho3d")
local voxelworld = require("buildat/module/voxelworld")
local heightmap = require("buildat/module/heightmap")

-- How much darker a cut is than a top of its colour beside it
-- (floorplanner's objects' 0.7)
local DARK = 0.6
-- The plan's camera under the cut by CAM_UNDER (editor.lua), the voxels'
-- and the heightmap's caps by UNDER, the entities' over those
local CAM_UNDER = 0.01
local UNDER = 0.02
-- The time a frame's building may take, microseconds
local BUDGET_US = 4000

local node -- the caps' node, in the app's scene
local material
local C = {layer = nil, tiles = {}, want = nil, queue = {}, hv = -1,
	size = nil, ents = nil, mats = {}}

local function make()
	node = O.scene:CreateChild("kit_caps")
	material = magic.Material:new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureVCol.xml"))
	material.cullMode = magic.CULL_NONE
	node.enabled = false
	C.ent_node = node:CreateChild("entities")
end

-- An image's average colour (a texture's), nil where it does not load
-- simplified: the whole image, not an atlas segment's part of it
local averages = {}
local function average(name)
	if averages[name] ~= nil then
		return averages[name] or nil
	end
	local img = name ~= "" and magic.cache:GetResource("Image", name)
	local r, g, b, n = 0, 0, 0, 0
	if img and img.width > 0 and img.height > 0 then
		local step = math.max(1, math.floor(math.max(img.width, img.height) / 16))
		for y = 0, img.height - 1, step do
			for x = 0, img.width - 1, step do
				local c = img:GetPixel(x, y)
				if c.a > 0.5 then
					r, g, b, n = r + c.r, g + c.g, b + c.b, n + 1
				end
			end
		end
	end
	averages[name] = n > 0 and {r / n, g / n, b / n} or false
	return averages[name] or nil
end

-- A voxel's cap colour by its value (plane 0's number): {r, g, b}, or
-- false where it is not solid. The registry's own: reset with it
-- simplified: the tint is not in it
local cols, cols_reg = {}, nil
local GREY = {0.5, 0.5, 0.5}
local function voxel_col(reg, v)
	if cols_reg ~= reg then
		cols, cols_reg = {}, reg
	end
	local c = cols[v]
	if c == nil then
		local def = reg:get_by_id(reg:id_of(buildat.VoxelInstance(v)))
		c = false
		if def and def.physically_solid then
			local seg = def.textures[1]
			c = average(seg and seg.resource_name or "") or GREY
		end
		cols[v] = c
	end
	return c
end

local function hm_col(m)
	local name = heightmap.textures[math.min(m, #heightmap.textures)]
	return average(name or "") or GREY
end

-- Two triangles over a rectangle (x0..x1, z0..z1) at y, into out
-- (set_triangle_geometry's 12 numbers a vertex: position, normal, colour,
-- texture coordinate); both sides drawn (the material's), so unwound
local function quad(out, xz, y, c)
	local r, g, b = c[1] * DARK, c[2] * DARK, c[3] * DARK
	local n = #out
	for _, k in ipairs({1, 2, 3, 1, 3, 4}) do
		local p = xz[k]
		out[n + 1], out[n + 2], out[n + 3] = p[1], y, p[2]
		out[n + 4], out[n + 5], out[n + 6] = 0, 1, 0
		out[n + 7], out[n + 8], out[n + 9], out[n + 10] = r, g, b, 1
		out[n + 11], out[n + 12] = 0, 0
		n = n + 12
	end
end
-- A hair over each side: the sky showed through in dots where one
-- rectangle's corner met another's side
local function rect(out, x0, z0, x1, z1, y, c)
	local e = 0.003
	x0, z0, x1, z1 = x0 - e, z0 - e, x1 + e, z1 + e
	quad(out, {{x0, z0}, {x0, z1}, {x1, z1}, {x1, z0}}, y, c)
end

-- Cells (w x d, colour tables by index, false empty) merged into
-- rectangles of one colour: greedy, along x and then z
local function merge(grid, w, d, x0, z0, y, out)
	local done = {}
	local count = 0
	for j = 0, d - 1 do
		for i = 0, w - 1 do
			local k = j * w + i + 1
			local c = grid[k]
			if c and not done[k] then
				local i1 = i
				while i1 + 1 < w and grid[k + i1 + 1 - i] == c and
						not done[k + i1 + 1 - i] do
					i1 = i1 + 1
				end
				local j1 = j
				while j1 + 1 < d do
					local ok = true
					for ii = i, i1 do
						local kk = (j1 + 1) * w + ii + 1
						if grid[kk] ~= c or done[kk] then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
					j1 = j1 + 1
				end
				for jj = j, j1 do
					for ii = i, i1 do
						done[jj * w + ii + 1] = true
					end
				end
				rect(out, x0 + i - 0.5, z0 + j - 0.5, x0 + i1 + 0.5,
						z0 + j1 + 0.5, y, c)
				count = count + 1
			end
		end
	end
	return count
end

-- A tile's caps: the chunk column (tx, tz)'s cells of the layer, the
-- voxels' and the heightmap's over the cut
local function build_tile(t, tx, tz)
	local size = C.size
	local sx, sz = size.x, size.z
	local x0, z0 = tx * sx, tz * sz
	local layer, y = C.layer, S.cut - UNDER
	local grid, any = {}, false
	local reg = voxelworld.get_voxel_registry()
	local cy = math.floor(layer / size.y)
	local chunk = reg and voxelworld.get_static_node(
			buildat.Vector3(tx, cy, tz))
	local vol = chunk and voxelworld.get_volume(chunk)
	if vol then
		local ly = layer - cy * size.y
		for j = 0, sz - 1 do
			for i = 0, sx - 1 do
				local c = voxel_col(reg, vol:get_plane_at(0, i, ly, j))
				if c then
					grid[j * sx + i + 1] = c
					any = true
				end
			end
		end
	end
	local ox, oz, cell, nx, nz = heightmap.grid()
	local function sample(v, o, n)
		return math.max(-1, math.min(n, math.floor((v - o) / cell + 0.5)))
	end
	local s0, s1, k0, k1
	if ox then
		s0, s1 = sample(x0, ox, nx), sample(x0 + sx - 1, ox, nx)
		k0, k1 = sample(z0, oz, nz), sample(z0 + sz - 1, oz, nz)
	end
	if ox and s1 >= 0 and s0 < nx and k1 >= 0 and k0 < nz then
		-- A cell over the cut where its sample is, or where the surface
		-- toward one of the 8 round it is at the middle between them, or at
		-- a corner between the two beside it (the patch to the surface's
		-- crossing, a half cell over at most; the sky showed through where
		-- the patch stopped short)
		-- simplified: the nearest sample's, not the surface between samples
		-- The samples' heights over the tile and one round it
		local H, hgt = {}, heightmap.sample_height
		for k = math.max(0, k0 - 1), math.min(nz - 1, k1 + 1) do
			local row = {}
			for s = math.max(0, s0 - 1), math.min(nx - 1, s1 + 1) do
				row[s] = hgt(s, k)
			end
			H[k] = row
		end
		-- (h + n) / 2 > cut: the middle toward n over it; n = h itself
		local cut2 = S.cut * 2
		for j = 0, sz - 1 do
			local k = sample(z0 + j, oz, nz)
			if k >= 0 and k < nz then
				for i = 0, sx - 1 do
					local g = j * sx + i + 1
					local s = sample(x0 + i, ox, nx)
					if not grid[g] and s >= 0 and s < nx then
						local h, over = H[k][s], false
						for dk = -1, 1 do
							local r = H[k + dk]
							for ds = -1, 1 do
								local n = r and r[s + ds]
								if n and h + n > cut2 then
									over = true
								end
							end
						end
						-- A corner's other diagonal: the two beside it
						local r0 = H[k]
						for dk = -1, 1, 2 do
							for ds = -1, 1, 2 do
								local a, b = r0[s + ds], H[k + dk] and H[k + dk][s]
								if a and b and a + b > cut2 then
									over = true
								end
							end
						end
						if over then
							local key = k * nx + s
							local m = C.mats[key]
							if not m then
								m = heightmap.sample_material(s, k)
								C.mats[key] = m
							end
							grid[g] = hm_col(m)
							any = true
						end
					end
				end
			end
		end
	end
	local out = {}
	local n = any and merge(grid, sx, sz, x0, z0, y, out) or 0
	if n > 0 then
		if not t.node then
			t.node = node:CreateChild("tile")
		end
		buildat.set_triangle_geometry(t.node, out)
		t.node:GetComponent("CustomGeometry"):SetMaterial(0, material)
		t.node.enabled = true
	elseif t.node then
		t.node.enabled = false
	end
	return n
end

local function drop_tile(key)
	local t = C.tiles[key]
	if t and t.node then
		t.node:Remove()
	end
	C.tiles[key] = nil
end

-- The tiles a rectangle of the world covers
local function tile_range(x0, z0, x1, z1)
	local sx, sz = C.size.x, C.size.z
	return math.floor((x0 + 0.5) / sx), math.floor((z0 + 0.5) / sz),
			math.floor((x1 + 0.5) / sx), math.floor((z1 + 0.5) / sz)
end

-- The tiles wanted, nearest the view's middle first, that are not current
local function plan(aspect)
	-- A quarter of the view's height more round it: a pan or a zoom out
	-- that far is built already
	local hw, hh = S.span * (aspect / 2 + 0.25), S.span * 0.75
	C.want = {S.cx - hw, S.cz - hh, S.cx + hw, S.cz + hh}
	local a, b, c, d = tile_range(C.want[1], C.want[2], C.want[3], C.want[4])
	local keep, q = {}, {}
	for tz = b, d do
		for tx = a, c do
			local key = tx .. "," .. tz
			keep[key] = true
			local t = C.tiles[key]
			if not (t and t.cut == S.cut and t.hv == C.hv) then
				local mx = (tx + 0.5) * C.size.x - S.cx
				local mz = (tz + 0.5) * C.size.z - S.cz
				q[#q + 1] = {key = key, tx = tx, tz = tz, d = mx * mx + mz * mz}
			end
		end
	end
	for key in pairs(C.tiles) do
		if not keep[key] then
			drop_tile(key)
		end
	end
	table.sort(q, function(p, r) return p.d < r.d end)
	C.queue = q
end

-- A chunk meshed again: its tile again, where it is the layer's
voxelworld.sub_geometry_update(function(chunk)
	if not C.size or not C.layer then
		return
	end
	local p = chunk.worldPosition
	local cy = math.floor(p.y / C.size.y)
	if cy ~= math.floor(C.layer / C.size.y) then
		return
	end
	local key = math.floor(p.x / C.size.x) .. "," ..
			math.floor(p.z / C.size.z)
	local t = C.tiles[key]
	if t then
		t.cut = nil
		C.want = nil
	end
end)

-- The entities' looks the cut goes through: each one's footprint, the
-- box's bottom's corners
-- simplified: a box turned round y only (a tilted one draws its bottom's
-- outline), a sphere's and a wedge's their box's, and the look's colour
-- where it wears a voxel material
local CORNERS = {{-0.5, -0.5}, {-0.5, 0.5}, {0.5, 0.5}, {0.5, -0.5}}
local function entity_caps()
	local cut = S.cut
	-- simplified: ten times a second (a door's swing a step behind), a
	-- dozen sandbox calls an entity
	local now = buildat.get_time_us()
	if C.ents_cut == cut and now - (C.ents_us or 0) < 100000 then
		return
	end
	C.ents_cut, C.ents_us = cut, now
	local list, sig = {}, {}
	for id, n in pairs(P.nodes) do
		local body = n.body
		if body and body.enabled and n.box then
			local m = body.worldTransform
			local lo, hi, pts = math.huge, -math.huge, {}
			for _, sy in ipairs({0.5, -0.5}) do
				for i, c in ipairs(CORNERS) do
					local w = m * magic.Vector3(c[1], sy, c[2])
					lo, hi = math.min(lo, w.y), math.max(hi, w.y)
					pts[i] = {w.x, w.z}
				end
			end
			if lo < cut and hi > cut then
				local col = color(n.box.color, magic.Color(0.8, 0.8, 0.8))
				list[#list + 1] = {pts, {col.r, col.g, col.b}}
				sig[#sig + 1] = string.format("%d %.3f %.3f %.3f %.3f %.3f %s",
						id, pts[1][1], pts[1][2], pts[3][1], pts[3][2],
						pts[2][1], tostring(n.box.color))
			end
		end
	end
	sig = table.concat(sig, ";") .. "@" .. cut
	if sig == C.ents then
		return
	end
	C.ents = sig
	local out = {}
	for _, e in ipairs(list) do
		quad(out, e[1], cut - (CAM_UNDER + UNDER) / 2, e[2])
	end
	buildat.set_triangle_geometry(C.ent_node, out)
	local cg = C.ent_node:GetComponent("CustomGeometry")
	cg:SetMaterial(0, material)
	C.ent_node.enabled = #out > 0
end

local M = {CAM_UNDER = CAM_UNDER}

function M.update(on, aspect)
	if not node then
		make()
	end
	node.enabled = on
	if not on or not S.cut then
		return
	end
	if not C.size then
		local s = voxelworld.chunk_size_voxels
		if not s then
			return
		end
		C.size = {x = s.x, y = s.y, z = s.z}
	end
	local layer = math.ceil(S.cut - 0.5)
	local hv = heightmap.version
	if hv ~= C.hv then
		-- The samples' materials, read as the caps want them
		C.mats = {}
	end
	if hv ~= C.hv or C.cut ~= S.cut then
		C.layer, C.hv, C.cut, C.want = layer, hv, S.cut, nil
	end
	local hw, hh = S.span * aspect / 2, S.span / 2
	local w = C.want
	if not w or S.cx - hw < w[1] or S.cz - hh < w[2] or S.cx + hw > w[3] or
			S.cz + hh > w[4] then
		plan(aspect)
	end
	entity_caps()
	if #C.queue == 0 then
		return
	end
	local t0 = buildat.get_time_us()
	local tiles, rects = 0, 0
	while #C.queue > 0 and buildat.get_time_us() - t0 < BUDGET_US do
		local q = table.remove(C.queue, 1)
		local t = C.tiles[q.key] or {}
		C.tiles[q.key] = t
		rects = rects + build_tile(t, q.tx, q.tz)
		t.cut, t.hv = S.cut, C.hv
		tiles = tiles + 1
	end
	C.built = (C.built or 0) + tiles
	C.rects = (C.rects or 0) + rects
	local us = buildat.get_time_us() - t0
	C.us, C.most = (C.us or 0) + us, math.max(C.most or 0, us)
	C.frames = (C.frames or 0) + 1
	if #C.queue == 0 then
		log:info(string.format("kit editor: caps at layer %d (cut %g): %d"..
				" tiles, %d rectangles, %.1f ms over %d frames (%.1f ms the"..
				" most a frame), the plan %.0f across", C.layer, S.cut,
				C.built, C.rects, C.us / 1000, C.frames, C.most / 1000,
				S.span * aspect))
		C.built, C.rects, C.us, C.frames, C.most = 0, 0, 0, 0, 0
	end
end

return M
end
-- vim: set noet ts=4 sw=4:
