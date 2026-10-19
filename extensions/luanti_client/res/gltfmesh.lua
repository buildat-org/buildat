-- Buildat: extensions/luanti_client/res/gltfmesh.lua
-- (the luanti module runs it too, through mesh_read.lua)
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- glTF 2.0, as the quads a voxel's shape is made of -- the same thing
-- objmesh.lua and b3dmesh.lua hand back, so a node whose drawtype is "mesh"
-- and names a .gltf or a .glb is a shape like any other from there on.
--
-- Both containers: .gltf is the JSON document as a plain file, and .glb is
-- that document in a binary wrapper with the buffer beside it. The JSON
-- and the base64 of a data: URI are read by M.parse_json and
-- M.decode_base64, which mesh_read.lua sets: the module's core ones, the
-- client's network.safe.parse_json and texmod's (the same json.lua).
--
-- What is read: the default scene's nodes, each one's transform, and the
-- POSITION and TEXCOORD_0 of every triangle of every primitive of the mesh
-- it names. What is not:
--
--  * **the skins and the animations.** A mesh is read in its rest pose,
--    a node does not move anyway; b3dmesh.lua poses an object's .b3d
--    at a frame, and a posed glTF object is not done.
--  * **the materials.** A primitive's material number becomes the tile
--    number, the way a .obj's usemtl does, and nothing of what the material
--    says about itself is read: the tiles are the node definition's.
--  * **sparse accessors**, which one of devtest's models uses. The
--    accessor's base data is read and the sparse patch on top of it is not,
--    so that model comes out as whatever it was before the patch.
--  * **an external buffer**: a .gltf whose buffer is a .bin file beside it
--    is not read, because nothing here has the directory to read it from.
--    A data: URI is, which is what an exporter writes for a single file.
--
-- glTF is right-handed with Y up and Luanti's engine is left-handed, and
-- what its own loader does about that is negate X --
-- `convertHandedness()` in irr/src/CGLTFMeshFileLoader.cpp -- so that is
-- what happens here, together with the winding flip that goes with it.

local M = {}

local COMPONENT_SIZE = {
	[5120] = 1, [5121] = 1, [5122] = 2, [5123] = 2, [5125] = 4, [5126] = 4,
}
local TYPE_COUNT = {
	SCALAR = 1, VEC2 = 2, VEC3 = 3, VEC4 = 4, MAT2 = 4, MAT3 = 9, MAT4 = 16,
}

local function u32_at(data, i)
	local a, b, c, d = string.byte(data, i, i + 3)
	if d == nil then
		return nil
	end
	return a + b * 256 + c * 65536 + d * 16777216
end

-- One component out of a buffer, by glTF's own componentType numbers. The
-- floats are IEEE 754 single precision, taken apart by hand because there is
-- no string.unpack in this Lua.
local function read_component(data, at, component_type)
	local b1, b2, b3, b4 = string.byte(data, at, at + 3)
	if b1 == nil then
		return nil
	end
	if component_type == 5121 then        -- unsigned byte
		return b1
	elseif component_type == 5120 then    -- signed byte
		return b1 < 128 and b1 or b1 - 256
	elseif component_type == 5123 then    -- unsigned short
		if b2 == nil then return nil end
		return b1 + b2 * 256
	elseif component_type == 5122 then    -- signed short
		if b2 == nil then return nil end
		local v = b1 + b2 * 256
		return v < 32768 and v or v - 65536
	elseif component_type == 5125 then    -- unsigned int
		if b4 == nil then return nil end
		return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
	elseif component_type == 5126 then    -- float
		if b4 == nil then return nil end
		local sign = (b4 >= 128) and -1 or 1
		local exponent = (b4 % 128) * 2 + math.floor(b3 / 128)
		local mantissa = (b3 % 128) * 65536 + b2 * 256 + b1
		if exponent == 0 then
			if mantissa == 0 then
				return sign * 0
			end
			return sign * mantissa * 2 ^ -149
		elseif exponent == 255 then
			-- An inf or a nan is not a coordinate; zero is a better lie
			return 0
		end
		return sign * (1 + mantissa / 8388608) * 2 ^ (exponent - 127)
	end
	return nil
end

-- The values of one accessor, as a flat array: count times the type's own
-- number of components, in order. Interleaved data is what byteStride is
-- for, and an exporter writes it.
local function accessor_values(gltf, buffers, index)
	local acc = gltf.accessors and gltf.accessors[index + 1]
	if acc == nil then
		return nil
	end
	local per = TYPE_COUNT[acc.type]
	local size = COMPONENT_SIZE[acc.componentType]
	if per == nil or size == nil then
		return nil
	end
	local out = {}
	local n = 0
	local count = acc.count or 0
	-- An accessor with no bufferView is all zeroes, which is what glTF says
	-- and what a sparse accessor's base often is
	if acc.bufferView == nil then
		for i = 1, count * per do
			out[i] = 0
		end
		return out, per
	end
	local view = gltf.bufferViews and gltf.bufferViews[acc.bufferView + 1]
	if view == nil then
		return nil
	end
	local data = buffers[(view.buffer or 0) + 1]
	if data == nil then
		return nil
	end
	local stride = view.byteStride or (per * size)
	local base = (view.byteOffset or 0) + (acc.byteOffset or 0)
	for i = 0, count - 1 do
		local at = base + i * stride
		for c = 0, per - 1 do
			-- Lua strings are 1-based and glTF's offsets are not
			local v = read_component(data, at + c * size + 1, acc.componentType)
			n = n + 1
			out[n] = v or 0
		end
	end
	return out, per
end

-- A node's own transform, as the sixteen numbers of a column-major 4x4 --
-- either the matrix it names or the scale, rotation and translation it
-- names instead, in glTF's own T * R * S order
local function node_matrix(node)
	if type(node.matrix) == "table" and #node.matrix == 16 then
		return node.matrix
	end
	local t = node.translation or {0, 0, 0}
	local r = node.rotation or {0, 0, 0, 1}
	local s = node.scale or {1, 1, 1}
	local x, y, z, w = r[1], r[2], r[3], r[4]
	-- The rotation matrix of a unit quaternion, times the scale
	local m = {
		(1 - 2 * (y * y + z * z)) * s[1], (2 * (x * y + z * w)) * s[1],
		(2 * (x * z - y * w)) * s[1], 0,
		(2 * (x * y - z * w)) * s[2], (1 - 2 * (x * x + z * z)) * s[2],
		(2 * (y * z + x * w)) * s[2], 0,
		(2 * (x * z + y * w)) * s[3], (2 * (y * z - x * w)) * s[3],
		(1 - 2 * (x * x + y * y)) * s[3], 0,
		t[1], t[2], t[3], 1,
	}
	return m
end

local function matrix_multiply(a, b)
	-- b applied first, then a; both column-major
	local out = {}
	for col = 0, 3 do
		for row = 0, 3 do
			local v = 0
			for k = 0, 3 do
				v = v + a[k * 4 + row + 1] * b[col * 4 + k + 1]
			end
			out[col * 4 + row + 1] = v
		end
	end
	return out
end

local function transform_point(m, x, y, z)
	return m[1] * x + m[5] * y + m[9] * z + m[13],
			m[2] * x + m[6] * y + m[10] * z + m[14],
			m[3] * x + m[7] * y + m[11] * z + m[15]
end

-- The binary chunk of a .glb, and the JSON beside it, or nil for a file that
-- is not one
local function read_glb(data)
	if string.sub(data, 1, 4) ~= "glTF" then
		return nil
	end
	local total = u32_at(data, 9) or #data
	local at = 13
	local json_text, bin = nil, nil
	while at + 8 <= math.min(total, #data) + 1 do
		local length = u32_at(data, at)
		local kind = u32_at(data, at + 4)
		if length == nil or kind == nil then
			break
		end
		local chunk = string.sub(data, at + 8, at + 8 + length - 1)
		if kind == 0x4E4F534A then
			json_text = chunk
		elseif kind == 0x004E4942 then
			bin = chunk
		end
		at = at + 8 + length
		-- Chunks are four-byte aligned, and a writer that padded says so in
		-- the length already; this is the guard against a length that did
		-- not
		if length % 4 ~= 0 then
			at = at + (4 - length % 4)
		end
	end
	return json_text, bin
end

-- What a buffer's uri holds, or nil for one this cannot read. Only a data:
-- URI, because a .bin file beside the model is a file nothing here can open.
local function buffer_data(uri)
	if type(uri) ~= "string" then
		return nil
	end
	local b64 = uri:match("^data:[^,]*;base64,(.*)$")
	if b64 then
		return M.decode_base64(b64)
	end
	return nil
end

-- parse(data) -> quads, groups, skipped
--
-- The same three things objmesh.lua's parse() answers with: the quads in the
-- node's own -0.5...0.5 cube with their texture coordinates, how many
-- material groups there were, and how many faces could not be used.
function M.parse(data)
	data = tostring(data)
	local json_text, bin = read_glb(data)
	if json_text == nil then
		json_text = data
	end
	local gltf, err = M.parse_json(json_text)
	if type(gltf) ~= "table" then
		error("not glTF: " .. tostring(err))
	end
	local buffers = {}
	for i, buffer in ipairs(gltf.buffers or {}) do
		-- The first buffer of a .glb is the binary chunk and has no uri
		if i == 1 and buffer.uri == nil and bin ~= nil then
			buffers[i] = bin
		else
			buffers[i] = buffer_data(buffer.uri)
		end
	end
	local quads = {}
	local groups = 1
	local skipped = 0

	local function add_primitive(prim, matrix)
		local attrs = prim.attributes
		if type(attrs) ~= "table" or attrs.POSITION == nil then
			skipped = skipped + 1
			return
		end
		if prim.mode ~= nil and prim.mode ~= 4 then
			-- Only triangles; a fan or a strip is a different walk and
			-- nothing writes them for a model like this
			skipped = skipped + 1
			return
		end
		local pos = accessor_values(gltf, buffers, attrs.POSITION)
		if pos == nil then
			skipped = skipped + 1
			return
		end
		local uv = attrs.TEXCOORD_0 ~= nil and
				accessor_values(gltf, buffers, attrs.TEXCOORD_0) or nil
		local index = prim.indices ~= nil and
				accessor_values(gltf, buffers, prim.indices) or nil
		local group = (prim.material or 0) + 1
		if group > groups then
			groups = group
		end
		local count = index and #index or math.floor(#pos / 3)
		local function corner(k)
			local v = index and index[k] or (k - 1)
			local x, y, z = pos[v * 3 + 1], pos[v * 3 + 2], pos[v * 3 + 3]
			if x == nil then
				return nil
			end
			x, y, z = transform_point(matrix, x, y, z)
			-- glTF is right-handed and the engine is not; Luanti's own
			-- loader negates X and this follows it
			local u = uv and uv[v * 2 + 1] or 0
			local w = uv and uv[v * 2 + 2] or 0
			return {-x, y, z, u, w}
		end
		for t = 1, count - 2, 3 do
			-- The winding turns over with the handedness, so the corners
			-- come out in the order the mesher draws a front face in
			local a, b, c = corner(t), corner(t + 2), corner(t + 1)
			if a == nil or b == nil or c == nil then
				skipped = skipped + 1
			else
				quads[#quads + 1] = {
					group = group,
					-- A triangle is a quad with its last corner twice,
					-- which is what the mesher takes
					p = {a[1], a[2], a[3], b[1], b[2], b[3],
							c[1], c[2], c[3], c[1], c[2], c[3]},
					uv = {a[4], a[5], b[4], b[5], c[4], c[5], c[4], c[5]},
				}
			end
		end
	end

	local nodes = gltf.nodes or {}
	local function walk(index, parent)
		local node = nodes[index + 1]
		if node == nil then
			return
		end
		local matrix = matrix_multiply(parent, node_matrix(node))
		if node.mesh ~= nil then
			local mesh = (gltf.meshes or {})[node.mesh + 1]
			for _, prim in ipairs(mesh and mesh.primitives or {}) do
				add_primitive(prim, matrix)
			end
		end
		for _, child in ipairs(node.children or {}) do
			walk(child, matrix)
		end
	end

	local identity = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	local scene = (gltf.scenes or {})[(gltf.scene or 0) + 1]
	if scene ~= nil and type(scene.nodes) == "table" then
		for _, index in ipairs(scene.nodes) do
			walk(index, identity)
		end
	else
		-- No scene at all: every node that has a mesh, which is what a
		-- document written by hand often is
		for i = 1, #nodes do
			walk(i - 1, identity)
		end
	end
	return quads, groups, skipped
end

return M
-- vim: set noet ts=4 sw=4:
