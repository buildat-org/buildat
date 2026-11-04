-- Buildat: util/kit_player_model.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- [KIT_PLAYER_MODEL] VoxeLibre's mcl_armor_character.b3d as Kit's player
-- model: builtin/kit/client_data/player_model.json, which
-- builtin/kit/client_lua/players.lua draws. Run from the tree's top:
--
--   luajit util/kit_player_model.lua <mcl_armor_character.b3d> \
--       > builtin/kit/client_data/player_model.json
--
-- Read with luanti_client's b3dmesh.lua. Every vertex of this model is a
-- bone's alone, so a part is a bone's triangles (the skin's, brush 1: the
-- armour's layer and the cape and elytra are left out) in the model's
-- space, and an animation is each part's transform at each frame (its
-- bone posed against its rest, Irrlicht's skinning), a position (model
-- units, 10 a metre) and a rotation (w, x, y, z). Wield_Item has no
-- triangles: its rest (pivot and rotation) is where the held item goes.
-- The ranges are VoxeLibre's (mcl_armor/player.lua), 30 frames a second.

local b3d = dofile("extensions/luanti_client/res/b3dmesh.lua")

local PARTS = {"Body", "Leg_Right", "Leg_Left", "Arm_Right", "Arm_Left",
	"Head", "Wield_Item"}
local ANIMS = {stand = {0, 79}, walk = {168, 187}, mine = {189, 198},
	walk_mine = {200, 219}}

local f = assert(io.open(assert(arg[1], "the .b3d's path"), "rb"))
local data = f:read("*a")
f:close()
local quads, _, _, bones = b3d.parse(data)
assert(quads, "not a .b3d")
local index = {}
for i, b in ipairs(bones) do
	index[b.name] = i
end
for _, name in ipairs(PARTS) do
	assert(index[name], "no bone " .. name)
end

local function num(v)
	local s = string.format("%.4f", v):gsub("0+$", ""):gsub("%.$", "")
	return s == "-0" and "0" or s
end

-- A rotation matrix's quaternion (w, x, y, z)
local function quat(m)
	local r00, r01, r02 = m[1], m[2], m[3]
	local r10, r11, r12 = m[5], m[6], m[7]
	local r20, r21, r22 = m[9], m[10], m[11]
	local t = r00 + r11 + r22
	local w, x, y, z
	if t > 0 then
		local s = math.sqrt(t + 1) * 2
		w, x, y, z = s / 4, (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s
	elseif r00 > r11 and r00 > r22 then
		local s = math.sqrt(1 + r00 - r11 - r22) * 2
		w, x, y, z = (r21 - r12) / s, s / 4, (r01 + r10) / s, (r02 + r20) / s
	elseif r11 > r22 then
		local s = math.sqrt(1 + r11 - r00 - r22) * 2
		w, x, y, z = (r02 - r20) / s, (r01 + r10) / s, s / 4, (r12 + r21) / s
	else
		local s = math.sqrt(1 + r22 - r00 - r11) * 2
		w, x, y, z = (r10 - r01) / s, (r02 + r20) / s, (r12 + r21) / s, s / 4
	end
	if w < 0 then
		w, x, y, z = -w, -x, -y, -z
	end
	return w, x, y, z
end

local IDENTITY = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

-- Every bone's global transform at a frame (nil: the rest) and the rest's.
-- The *_Control bones at their rest: VoxeLibre sets them itself each step
-- (the head's pitch, the body's yaw, the arms' aim; mcl_playerplus), their
-- keys are not what it draws
local function pose(frame)
	local g = {}
	for i, bone in ipairs(bones) do
		local r = bone.rest
		local fr = frame
		if bone.name:match("_Control$") then
			frame = nil
		end
		local p = frame and b3d.sample(bone.keys, "pos", frame) or {r[1], r[2], r[3]}
		local s = frame and b3d.sample(bone.keys, "scale", frame) or {r[4], r[5], r[6]}
		local q = frame and b3d.sample(bone.keys, "rot", frame) or
				{r[7], r[8], r[9], r[10]}
		local m = b3d.node_matrix(p[1], p[2], p[3], s[1], s[2], s[3], q[1],
				q[2], q[3], q[4])
		g[i] = b3d.multiply(bone.parent and g[bone.parent] or IDENTITY, m)
		frame = fr
	end
	return g
end
local rest = pose(nil)
local rest_inv = {}
for i, bone in ipairs(bones) do
	local r = bone.rest
	rest_inv[i] = b3d.multiply(b3d.node_matrix_inverse(r[1], r[2], r[3], r[4],
			r[5], r[6], r[7], r[8], r[9], r[10]),
			bone.parent and rest_inv[bone.parent] or IDENTITY)
end

local out = {}
local function w(s)
	out[#out + 1] = s
end
w('{"source": "VoxeLibre 0.92.3 mods/ITEMS/mcl_armor/models/' ..
		'mcl_armor_character.b3d, CC BY-SA 3.0; see builtin/kit/README.txt",\n')
w('"unit": 0.1, "fps": 30,\n"parts": {')
local first = true
for _, name in ipairs(PARTS) do
	local list = {}
	for _, q in ipairs(quads) do
		if q.group == 1 and q.bone == index[name] then
			local t = {}
			for i = 1, 9 do
				t[#t + 1] = num(q.p[i])
			end
			for i = 1, 6 do
				t[#t + 1] = num(q.uv[i])
			end
			list[#list + 1] = "[" .. table.concat(t, ",") .. "]"
		end
	end
	local g = rest[index[name]]
	local qw, qx, qy, qz = quat(g)
	w((first and "" or ",") .. '\n"' .. name .. '": {"pivot": [' ..
			num(g[4]) .. "," .. num(g[8]) .. "," .. num(g[12]) .. '], "rot": [' ..
			num(qw) .. "," .. num(qx) .. "," .. num(qy) .. "," .. num(qz) ..
			'], "tris": [' .. table.concat(list, ",\n") .. "]}")
	first = false
end
w("},\n\"anims\": {")
first = true
for _, an in ipairs({"stand", "walk", "mine", "walk_mine"}) do
	local range = ANIMS[an]
	local frames = {}
	for fr = range[1], range[2] do
		-- A .b3d's keys count from 1, Luanti's frames from 0
		local g = pose(fr + 1)
		local t = {}
		for _, name in ipairs(PARTS) do
			local i = index[name]
			local m = b3d.multiply(g[i], rest_inv[i])
			local qw, qx, qy, qz = quat(m)
			t[#t + 1] = "[" .. table.concat({num(m[4]), num(m[8]), num(m[12]),
				num(qw), num(qx), num(qy), num(qz)}, ",") .. "]"
		end
		frames[#frames + 1] = "[" .. table.concat(t, ",") .. "]"
	end
	w((first and "" or ",") .. '\n"' .. an .. '": [' ..
			table.concat(frames, ",\n") .. "]")
	first = false
end
w('},\n"order": ["' .. table.concat(PARTS, '","') .. '"]}\n')
io.write(table.concat(out))
