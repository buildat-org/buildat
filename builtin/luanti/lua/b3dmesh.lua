-- Buildat: builtin/luanti/lua/b3dmesh.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Blitz3D .b3d, as the quads a voxel's shape is made of.
--
-- The node meshes .obj does not cover are .b3d: in this game the chests, the
-- shulker boxes and the mobs. The format is a tree of chunks, each a
-- four-letter tag, a length and a payload, and what a static node wants out
-- of it is the vertices and the triangles of every mesh in the tree, put
-- where the tree's transforms say.
--
-- BONE and KEYS pose a mob at a frame of its animation (parse()'s frame);
-- ANIM is not read, the game's animation ranges say the same.
--
-- Nothing here touches a file: parse() takes the bytes.

local M = {}

-- A reader over a string. Blitz3D is little-endian, which is the other way
-- round from everything Luanti sends over the network, so this does not use
-- serialize.lua.
local function reader(data)
	local pos = 1
	local r = {}

	function r.left()
		return #data - pos + 1
	end

	function r.tell()
		return pos
	end

	function r.seek(to)
		pos = to
	end

	function r.bytes(n)
		local s = data:sub(pos, pos + n - 1)
		pos = pos + n
		return s
	end

	function r.u32()
		local a, b, c, d = data:byte(pos, pos + 3)
		pos = pos + 4
		if d == nil then
			return 0
		end
		return ((d * 256 + c) * 256 + b) * 256 + a
	end

	function r.i32()
		local v = r.u32()
		if v >= 0x80000000 then
			v = v - 0x100000000
		end
		return v
	end

	-- IEEE 754 single precision, least significant byte first
	function r.f32()
		local b1, b2, b3, b4 = data:byte(pos, pos + 3)
		pos = pos + 4
		if b4 == nil then
			return 0
		end
		local sign = b4 >= 0x80 and -1 or 1
		local exponent = (b4 % 0x80) * 2 + math.floor(b3 / 0x80)
		local mantissa = ((b3 % 0x80) * 0x100 + b2) * 0x100 + b1
		if exponent == 0xff then
			return mantissa == 0 and sign * math.huge or 0 / 0
		end
		if exponent == 0 then
			return sign * (mantissa / 0x800000) * 2 ^ -126
		end
		return sign * (1 + mantissa / 0x800000) * 2 ^ (exponent - 127)
	end

	-- Zero-terminated, which is how a name is stored
	function r.cstring()
		local at = data:find("\0", pos, true)
		if not at then
			local s = data:sub(pos)
			pos = #data + 1
			return s
		end
		local s = data:sub(pos, at - 1)
		pos = at + 1
		return s
	end

	return r
end

-- A 4x4 matrix as sixteen numbers, row major: m[row * 4 + col + 1]
local IDENTITY = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

local function multiply(a, b)
	local out = {}
	for row = 0, 3 do
		for col = 0, 3 do
			local sum = 0
			for k = 0, 3 do
				sum = sum + a[row * 4 + k + 1] * b[k * 4 + col + 1]
			end
			out[row * 4 + col + 1] = sum
		end
	end
	return out
end

local function transform(m, x, y, z)
	return m[1] * x + m[2] * y + m[3] * z + m[4],
			m[5] * x + m[6] * y + m[7] * z + m[8],
			m[9] * x + m[10] * y + m[11] * z + m[12]
end

-- A node's own transform: its rotation as a quaternion, then its scale, then
-- its position, which is the order Blitz3D applies them in.
local function node_matrix(px, py, pz, sx, sy, sz, qw, qx, qy, qz)
	local n = math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
	if n > 0 then
		qw, qx, qy, qz = qw / n, qx / n, qy / n, qz / n
	else
		qw, qx, qy, qz = 1, 0, 0, 0
	end
	local xx, yy, zz = qx * qx, qy * qy, qz * qz
	local xy, xz, yz = qx * qy, qx * qz, qy * qz
	local wx, wy, wz = qw * qx, qw * qy, qw * qz
	return {
		(1 - 2 * (yy + zz)) * sx, (2 * (xy - wz)) * sy,
				(2 * (xz + wy)) * sz, px,
		(2 * (xy + wz)) * sx, (1 - 2 * (xx + zz)) * sy,
				(2 * (yz - wx)) * sz, py,
		(2 * (xz - wy)) * sx, (2 * (yz + wx)) * sy,
				(1 - 2 * (xx + yy)) * sz, pz,
		0, 0, 0, 1,
	}
end

-- The inverse of node_matrix() with the same arguments: the position
-- undone, then the rotation, then the scale, which is the same three the
-- other way round
local function node_matrix_inverse(px, py, pz, sx, sy, sz, qw, qx, qy, qz)
	local unrotate = node_matrix(0, 0, 0, 1, 1, 1, qw, -qx, -qy, -qz)
	local unscale = {1 / (sx ~= 0 and sx or 1), 0, 0, 0,
			0, 1 / (sy ~= 0 and sy or 1), 0, 0,
			0, 0, 1 / (sz ~= 0 and sz or 1), 0,
			0, 0, 0, 1}
	local untranslate = {1, 0, 0, -px, 0, 1, 0, -py, 0, 0, 1, -pz, 0, 0, 0, 1}
	return multiply(unscale, multiply(unrotate, untranslate))
end

-- A bone's position, scale or rotation at a frame: the keys that carry it
-- either side of the frame, mixed by where the frame falls between them, as
-- Irrlicht does; before the first key the first, after the last the last.
-- A rotation is a quaternion mixed the short way round and normalised
-- (node_matrix() normalises), which is near enough a slerp between keys a
-- few frames apart. nil when no key carries it: the rest stands.
local function sample(keys, field, frame)
	local a, b
	for _, key in ipairs(keys) do
		if key[field] then
			if key.frame <= frame and (a == nil or key.frame >= a.frame) then
				a = key
			end
			if key.frame >= frame and (b == nil or key.frame < b.frame) then
				b = key
			end
		end
	end
	a = a or b
	b = b or a
	if a == nil then
		return nil
	end
	if a.frame == b.frame then
		return a[field]
	end
	local t = (frame - a.frame) / (b.frame - a.frame)
	local u, v = a[field], b[field]
	local sign = 1
	if field == "rot" and u[1] * v[1] + u[2] * v[2] + u[3] * v[3] +
			u[4] * v[4] < 0 then
		sign = -1
	end
	local out = {}
	for i = 1, #u do
		out[i] = u[i] + (sign * v[i] - u[i]) * t
	end
	return out
end

-- parse(data[, frame]) -> quads, groups, skipped
--
-- The same shape objmesh.parse() gives back: quads of
-- {group = n, p = {12 numbers}, uv = {8 numbers}}, so the caller does not
-- care which format the model was in. A triangle comes out as a quad with
-- its last corner twice.
--
-- group counts up from 1 per brush the triangles name, which is Blitz3D's
-- word for a material, so a mesh with two materials has its faces marked 1
-- and 2 and the caller can put them on different tiles.
--
-- frame: the model posed at that frame of its animation -- every bone's
-- transform between its KEYS either side of the frame, and every
-- vertex moved by the bones that weight it, as Irrlicht does for Luanti.
-- Without it the mesh is its bind pose, which for a mob authored in Blender
-- is the arms out and the legs together ([OBJECT_MESH]).
--
-- What comes back is nil and a reason for bytes that are not a .b3d at all.
--
-- simplified: the winding and the axes go through as they are, which is what
-- the .obj reader does too. A node mesh is drawn from both sides, so a
-- winding that is the wrong way round costs the lighting of a face rather
-- than the face.
function M.parse(data, frame)
	data = tostring(data)
	local r = reader(data)
	if r.left() < 12 or r.bytes(4) ~= "BB3D" then
		return nil, "not a b3d file"
	end
	local size = r.u32()
	r.i32() -- version
	local top_end = math.min(#data + 1, r.tell() + size - 4)

	local quads = {}
	local groups = 0
	local skipped = 0
	-- Every vertex of every mesh in file order, in the model's space
	-- ({x, y, z, u, v}), which is what a bone's weights index
	local vertices = {}
	local tris = {} -- {group, a, b, c} into vertices
	-- Every node with bones or keys, in tree order: parent index, its rest
	-- transform's arguments, its keys and its weights
	local bones = {}

	-- Every chunk in a range: the tag, and the range of its payload
	local function chunks(from, to, fn)
		local at = from
		while at + 8 <= to do
			r.seek(at)
			local tag = r.bytes(4)
			local length = r.u32()
			local body = r.tell()
			local body_end = body + length
			if length < 0 or body_end > to then
				-- A length that runs past its parent is a broken file; what
				-- has been read so far is still worth drawing
				return
			end
			fn(tag, body, body_end)
			at = body_end
		end
	end

	local function read_mesh(from, to, matrix)
		r.seek(from)
		local mesh_brush = r.i32()
		local base = #vertices
		chunks(r.tell(), to, function(tag, body, body_end)
			if tag == "VRTS" then
				r.seek(body)
				local flags = r.i32()
				local sets = r.i32()
				local set_size = r.i32()
				local has_normal = flags % 2 == 1
				local has_color = math.floor(flags / 2) % 2 == 1
				local per_vertex = 3 + (has_normal and 3 or 0) +
						(has_color and 4 or 0) + sets * set_size
				while r.tell() + per_vertex * 4 <= body_end do
					local x, y, z = r.f32(), r.f32(), r.f32()
					if has_normal then
						r.f32(); r.f32(); r.f32()
					end
					if has_color then
						r.f32(); r.f32(); r.f32(); r.f32()
					end
					local u, v = 0, 0
					for set = 1, sets do
						for i = 1, set_size do
							local value = r.f32()
							if set == 1 and i == 1 then
								u = value
							elseif set == 1 and i == 2 then
								v = value
							end
						end
					end
					local tx, ty, tz = transform(matrix, x, y, z)
					vertices[#vertices + 1] = {tx, ty, tz, u, v}
				end
			elseif tag == "TRIS" then
				r.seek(body)
				local brush = r.i32()
				if brush < 0 then
					brush = mesh_brush
				end
				local group = brush + 1
				if group < 1 then
					group = 1
				end
				if group > groups then
					groups = group
				end
				while r.tell() + 12 <= body_end do
					local a = base + r.i32() + 1
					local b = base + r.i32() + 1
					local c = base + r.i32() + 1
					tris[#tris + 1] = {group, a, b, c}
				end
			end
		end)
	end

	local function read_node(from, to, parent, parent_bone)
		r.seek(from)
		r.cstring() -- name
		local px, py, pz = r.f32(), r.f32(), r.f32()
		local sx, sy, sz = r.f32(), r.f32(), r.f32()
		local qw, qx, qy, qz = r.f32(), r.f32(), r.f32(), r.f32()
		local matrix = multiply(parent, node_matrix(px, py, pz,
				sx, sy, sz, qw, qx, qy, qz))
		local bone = {parent = parent_bone,
				rest = {px, py, pz, sx, sy, sz, qw, qx, qy, qz},
				keys = {}, weights = {}}
		bones[#bones + 1] = bone
		local me = #bones
		chunks(r.tell(), to, function(tag, body, body_end)
			if tag == "MESH" then
				read_mesh(body, body_end, matrix)
			elseif tag == "NODE" then
				read_node(body, body_end, matrix, me)
			elseif tag == "BONE" then
				r.seek(body)
				while r.tell() + 8 <= body_end do
					local vertex = r.i32() + 1
					local weight = r.f32()
					if weight > 0 then
						bone.weights[#bone.weights + 1] = {vertex, weight}
					end
				end
			elseif tag == "KEYS" then
				r.seek(body)
				local flags = r.i32()
				local has_pos = flags % 2 == 1
				local has_scale = math.floor(flags / 2) % 2 == 1
				local has_rot = math.floor(flags / 4) % 2 == 1
				local per_key = 4 + (has_pos and 12 or 0) +
						(has_scale and 12 or 0) + (has_rot and 16 or 0)
				while r.tell() + per_key <= body_end do
					local key = {frame = r.i32()}
					if has_pos then
						key.pos = {r.f32(), r.f32(), r.f32()}
					end
					if has_scale then
						key.scale = {r.f32(), r.f32(), r.f32()}
					end
					if has_rot then
						key.rot = {r.f32(), r.f32(), r.f32(), r.f32()}
					end
					bone.keys[#bone.keys + 1] = key
				end
			end
			-- ANIM is the frame count and the speed, which the game's
			-- own animation ranges already say
		end)
	end

	chunks(r.tell(), top_end, function(tag, body, body_end)
		if tag == "NODE" then
			read_node(body, body_end, IDENTITY, nil)
		end
		-- TEXS and BRUS say what the model's own textures are, and a Luanti
		-- node mesh does not wear them: it wears the node's own tiles
	end)

	if frame ~= nil then
		-- Each bone's transform at the frame, against its rest: global
		-- matrices down the tree, and the rest's inverse the same way
		local posed = {}
		for i, bone in ipairs(bones) do
			local rest = bone.rest
			local p = sample(bone.keys, "pos", frame) or
					{rest[1], rest[2], rest[3]}
			local sc = sample(bone.keys, "scale", frame) or
					{rest[4], rest[5], rest[6]}
			local q = sample(bone.keys, "rot", frame) or
					{rest[7], rest[8], rest[9], rest[10]}
			local local_now = node_matrix(p[1], p[2], p[3], sc[1], sc[2],
					sc[3], q[1], q[2], q[3], q[4])
			local rest_inv = node_matrix_inverse(rest[1], rest[2], rest[3],
					rest[4], rest[5], rest[6], rest[7], rest[8], rest[9],
					rest[10])
			local parent = bone.parent and posed[bone.parent]
			posed[i] = {
				global = multiply(parent and parent.global or IDENTITY,
						local_now),
				-- inverse(parent_rest * local_rest)
				rest_inv = multiply(rest_inv,
						parent and parent.rest_inv or IDENTITY),
			}
		end
		local moved = {}
		local weight_sum = {}
		for i, bone in ipairs(bones) do
			if #bone.weights > 0 then
				local skin = multiply(posed[i].global, posed[i].rest_inv)
				for _, w in ipairs(bone.weights) do
					local v = vertices[w[1]]
					if v then
						local x, y, z = transform(skin, v[1], v[2], v[3])
						local m = moved[w[1]]
						if m == nil then
							m = {0, 0, 0}
							moved[w[1]] = m
						end
						m[1] = m[1] + x * w[2]
						m[2] = m[2] + y * w[2]
						m[3] = m[3] + z * w[2]
						weight_sum[w[1]] = (weight_sum[w[1]] or 0) + w[2]
					end
				end
			end
		end
		for index, m in pairs(moved) do
			local total = weight_sum[index]
			if total > 0 then
				local v = vertices[index]
				v[1], v[2], v[3] = m[1] / total, m[2] / total, m[3] / total
			end
		end
	end

	for _, t in ipairs(tris) do
		local va, vb, vc = vertices[t[2]], vertices[t[3]], vertices[t[4]]
		if not va or not vb or not vc then
			skipped = skipped + 1
		else
			-- A triangle is a quad with its last corner twice, which is
			-- what the mesher takes and what costs nothing to draw
			quads[#quads + 1] = {
				group = t[1],
				p = {va[1], va[2], va[3], vb[1], vb[2], vb[3],
						vc[1], vc[2], vc[3], vc[1], vc[2], vc[3]},
				uv = {va[4], va[5], vb[4], vb[5], vc[4], vc[5],
						vc[4], vc[5]},
			}
		end
	end

	if groups < 1 then
		groups = 1
	end
	return quads, groups, skipped
end

-- Every corner multiplied, for a node mesh a game asked to be drawn bigger
-- or smaller than the cube it sits in
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

core.__b3dmesh = M
return M
-- vim: set noet ts=4 sw=4:
