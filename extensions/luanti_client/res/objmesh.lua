-- Buildat: extensions/luanti_client/res/objmesh.lua
-- (the luanti module runs it too, through mesh_read.lua)
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Wavefront .obj, as the quads a voxel's shape is made of.
--
-- A Luanti node whose drawtype is "mesh" names a model file, and in this game
-- those are almost all .obj: campfires, flowerpots, signs, lanterns,
-- lecterns, item frames, heads, rails. The format is text and a node mesh
-- uses a corner of it -- "v", "vt", "f" and "usemtl" -- so reading it here is
-- shorter than teaching the engine a mesh format, and what comes out is what
-- the voxel mesher already copies into a chunk: a chunk of lanterns then
-- costs what a chunk of cubes costs.
--
-- A node mesh is authored in the node's own cube of -0.5...0.5, which is the
-- same space VoxelDefinition.shape is in, so the numbers go straight through.
--
-- Nothing here touches a file: parse() takes the text.

local M = {}

-- An index in a face is 1-based from the start of the list, or negative from
-- the end of it, which is what a .obj written by some exporters uses
local function resolve_index(i, count)
	if i == nil then
		return nil
	end
	if i < 0 then
		i = count + 1 + i
	end
	if i < 1 or i > count then
		return nil
	end
	return i
end

-- parse(text) -> quads, groups, skipped
--
-- quads is an array of {group = n, p = {12 numbers}, uv = {8 numbers}}: the
-- corners in the voxel's own -0.5...0.5 cube and the texture coordinates in
-- the tile's own 0...1 with 0,0 at its top left, which is where
-- VoxelDefinition.shape wants them. .obj puts 0,0 at the bottom left, so the
-- second coordinate is turned over.
--
-- group counts up from 1 at every "usemtl", so a mesh with two materials has
-- its faces marked 1 and 2 and the caller can put them on different tiles.
--
-- groups is how many there were and skipped how many faces were not
-- triangles or quads. A triangle comes out as a quad with its last corner
-- twice, which is what the mesher takes and what costs nothing to draw.
function M.parse(text)
	local vs = {}
	local vts = {}
	local quads = {}
	local group = 1
	local groups = 1
	local skipped = 0

	for line in tostring(text):gmatch("[^\r\n]+") do
		local kind, rest = line:match("^%s*(%S+)%s*(.*)$")
		if kind == "v" then
			local x, y, z = rest:match("^(-?[%d.eE+-]+)%s+(-?[%d.eE+-]+)"..
					"%s+(-?[%d.eE+-]+)")
			if x then
				vs[#vs + 1] = {tonumber(x), tonumber(y), tonumber(z)}
			end
		elseif kind == "vt" then
			local u, v = rest:match("^(-?[%d.eE+-]+)%s+(-?[%d.eE+-]+)")
			if u then
				vts[#vts + 1] = {tonumber(u), tonumber(v)}
			end
		elseif kind == "usemtl" then
			-- The first material is the group the faces before it are in
			-- already; a later one is a new group
			if #quads > 0 or group > 1 then
				groups = groups + 1
				group = groups
			end
		elseif kind == "f" then
			-- Each corner is "v", "v/vt", "v//vn" or "v/vt/vn"
			local corners = {}
			for word in rest:gmatch("%S+") do
				local vi, ti = word:match("^(-?%d+)/?(-?%d*)")
				corners[#corners + 1] = {
					v = resolve_index(tonumber(vi), #vs),
					t = resolve_index(tonumber(ti), #vts),
				}
			end
			-- A face with a corner whose vertex is not there is not a face
			local ok = #corners == 3 or #corners == 4
			for _, c in ipairs(corners) do
				ok = ok and c.v ~= nil
			end
			if not ok then
				skipped = skipped + 1
			else
				if #corners == 3 then
					corners[4] = corners[3]
				end
				local p = {}
				local uv = {}
				for i = 1, 4 do
					local c = corners[i]
					local pos = vs[c.v]
					p[#p + 1] = pos[1]
					p[#p + 1] = pos[2]
					p[#p + 1] = pos[3]
					local t = c.t and vts[c.t] or nil
					if t then
						uv[#uv + 1] = t[1]
						uv[#uv + 1] = 1 - t[2]
					else
						-- No texture coordinates at all: the whole tile over
						-- the whole face, in the winding the corners are in
						local DEFAULT_U = {0, 1, 1, 0}
						local DEFAULT_V = {0, 0, 1, 1}
						uv[#uv + 1] = DEFAULT_U[i]
						uv[#uv + 1] = DEFAULT_V[i]
					end
				end
				-- The corner order goes through as it is: .obj winds a
				-- face counter-clockwise seen from outside, which is the
				-- same convention a voxel's shape wants -- the cross
				-- product of two consecutive edges points out of the
				-- shape. test.lua pins that against shapes.lua's own boxes.
				quads[#quads + 1] = {group = group, p = p, uv = uv}
			end
		end
	end
	return quads, groups, skipped
end

-- Every corner multiplied, for a node mesh a game asked to be drawn bigger or
-- smaller than the cube it sits in
function M.scale(quads, by)
	if by == nil or by == 1 then
		return quads
	end
	for _, q in ipairs(quads) do
		for i = 1, 12 do
			q.p[i] = q.p[i] * by
		end
	end
	return quads
end

return M
-- vim: set noet ts=4 sw=4:
