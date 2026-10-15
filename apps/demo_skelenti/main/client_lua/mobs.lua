-- Buildat: apps/demo_skelenti/main/client_lua/mobs.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- skelenti's mobs as the client sees them: the server's nodes (main.cpp)
-- dressed as boxes of the skins' layout, the legs and arms swinging as
-- they walk, lit by the world's light, red for a moment when hurt. A
-- click at one is the module's point stage, sent to the server as
-- skelenti:punch. Their sounds come by name and are played from
-- sounds.lua's.
-- simplified: no death animation and no bow drawn; boxes axis-aligned
-- for pointing (a boar is pointed at as a square).
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local luanti = require("buildat/module/luanti")
local log = buildat.Logger("skelenti")

local M = {}

-- What each moment sounds like: sounds.lua's, set by init.lua
M.sounds = nil

-- A face's pixels {x, y, w, h} in the skin, and its four corners from the
-- top left, seen from outside
local function quad(quads, rect, tw, th, a, b, c, d)
	local u0, v0 = rect[1] / tw, rect[2] / th
	local u1, v1 = (rect[1] + rect[3]) / tw, (rect[2] + rect[4]) / th
	quads[#quads + 1] = {tile = 0,
		p = {a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3],
			d[1], d[2], d[3]},
		uv = {u0, v0, u1, v0, u1, v1, u0, v1}}
end

-- The six faces of the skin layout's box at u, v of w, h, d pixels
local function skin(u, v, w, h, d)
	return {top = {u + d, v, w, d}, bottom = {u + d + w, v, w, d},
		right = {u, v + d, d, h}, front = {u + d, v + d, w, h},
		left = {u + d + w, v + d, d, h}, back = {u + 2 * d + w, v + d, w, h}}
end

-- A box from x0, y0, z0 to x1, y1, z1 in pixels, its front +z and its
-- right +x
local function box(quads, f, tw, th, x0, y0, z0, x1, y1, z1)
	local s = 1 / 16
	x0, y0, z0, x1, y1, z1 = x0 * s, y0 * s, z0 * s, x1 * s, y1 * s, z1 * s
	quad(quads, f.front, tw, th, {x1, y1, z1}, {x0, y1, z1}, {x0, y0, z1},
			{x1, y0, z1})
	quad(quads, f.back, tw, th, {x0, y1, z0}, {x1, y1, z0}, {x1, y0, z0},
			{x0, y0, z0})
	quad(quads, f.right, tw, th, {x1, y1, z0}, {x1, y1, z1}, {x1, y0, z1},
			{x1, y0, z0})
	quad(quads, f.left, tw, th, {x0, y1, z1}, {x0, y1, z0}, {x0, y0, z0},
			{x0, y0, z1})
	quad(quads, f.top, tw, th, {x1, y1, z0}, {x0, y1, z0}, {x0, y1, z1},
			{x1, y1, z1})
	quad(quads, f.bottom, tw, th, {x1, y0, z1}, {x0, y0, z1}, {x0, y0, z0},
			{x1, y0, z0})
end

-- The kinds: a skin, the parts (a pivot in pixels, a box around it, the
-- skin's faces, and how it swings), and the box a click finds it in
local KINDS = {
	skelenti_skeleton = {texture = "skelenti_skeleton.png", tw = 64, th = 32,
		half = 0.35, height = 2,
		parts = {
			{0, 24, 0, {-4, 0, -4, 4, 8, 4}, skin(0, 0, 8, 8, 8)},
			{0, 12, 0, {-4, 0, -2, 4, 12, 2}, skin(16, 16, 8, 12, 4)},
			{-5, 24, 0, {-1, -12, -1, 1, 0, 1}, skin(40, 16, 2, 12, 2), 1},
			{5, 24, 0, {-1, -12, -1, 1, 0, 1}, skin(40, 16, 2, 12, 2), -1},
			{-2, 12, 0, {-1, -12, -1, 1, 0, 1}, skin(0, 16, 2, 12, 2), -1},
			{2, 12, 0, {-1, -12, -1, 1, 0, 1}, skin(0, 16, 2, 12, 2), 1},
		}},
	skelenti_boar = {texture = "skelenti_boar.png", tw = 64, th = 32,
		half = 0.5, height = 0.9,
		parts = {
			{0, 8, 7, {-4, 0, 0, 4, 8, 8}, skin(0, 0, 8, 8, 8)},
			{0, 9, 15, {-2, 0, 0, 2, 3, 1}, skin(16, 16, 4, 3, 1)},
			-- The body lies along z: the skin's back is its top
			{0, 6, 0, {-5, 0, -8, 5, 8, 8}, (function()
				local f = skin(28, 8, 10, 16, 8)
				return {top = f.back, bottom = f.front, front = f.top,
					back = f.bottom, right = f.right, left = f.left}
			end)()},
			{-3, 6, 5, {-2, -6, -2, 2, 0, 2}, skin(0, 16, 4, 6, 4), 1},
			{3, 6, 5, {-2, -6, -2, 2, 0, 2}, skin(0, 16, 4, 6, 4), -1},
			{-3, 6, -5, {-2, -6, -2, 2, 0, 2}, skin(0, 16, 4, 6, 4), -1},
			{3, 6, -5, {-2, -6, -2, 2, 0, 2}, skin(0, 16, 4, 6, 4), 1},
		}},
}

local function material(texture_name)
	local m = magic.Material.new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"luanti_client/res/LuantiUnlitMask.xml"))
	local res = luanti.texture(texture_name)
	if res and magic.cache:Exists(res) then
		local t = magic.cache:GetResource("Texture2D", res)
		t.filterMode = magic.FILTER_NEAREST
		m:SetTexture(magic.TU_DIFFUSE, t)
	end
	return m
end

local function build(node, quads, mat)
	local tiles = buildat.set_quad_geometry(node, quads)
	local cg = node:GetComponent("CustomGeometry")
	for i = 1, #tiles do
		cg:SetMaterial(i - 1, mat)
	end
	return cg
end

local mobs = {} -- node id -> {node, kind, parts, mat, ...}

local function dress(node)
	local name = node:GetName()
	local kind = KINDS[name]
	if name == "skelenti_arrow" then
		-- Two crossed strips of the arrow's side, the head forward (+z)
		local quads, w, l = {}, 0.08, 0.4
		local r = {0, 0, 32, 8}
		quad(quads, r, 64, 64, {0, w, -l}, {0, w, l}, {0, -w, l}, {0, -w, -l})
		quad(quads, r, 64, 64, {-w, 0, -l}, {-w, 0, l}, {w, 0, l}, {w, 0, -l})
		local mat = material("skelenti_arrow_entity.png")
		mobs[node:GetID()] = {node = node, mat = mat, arrow = true,
				light_t = 0, cgs = {build(node:CreateChild("look"), quads, mat)}}
		return
	end
	if not kind then
		return
	end
	local mat = material(kind.texture)
	local parts, cgs = {}, {}
	for _, p in ipairs(kind.parts) do
		local child = node:CreateChild("part")
		child.position = magic.Vector3(p[1] / 16, p[2] / 16, p[3] / 16)
		local quads, b = {}, p[4]
		box(quads, p[5], kind.tw, kind.th, b[1], b[2], b[3], b[4], b[5], b[6])
		cgs[#cgs + 1] = build(child, quads, mat)
		parts[#parts + 1] = {node = child, swing = p[6]}
	end
	local pos = node.worldPosition
	mobs[node:GetID()] = {node = node, kind = kind, parts = parts, mat = mat,
		cgs = cgs, last = magic.Vector3(pos.x, pos.y, pos.z), phase = 0, light_t = 0,
		hurt = node:GetVar("skelenti_hurt"):GetInt(), red_t = 0}
	log:info("skelenti: a " .. name:gsub("skelenti_", "") .. " (" ..
			node:GetID() .. ") is here")
end

replicate.sub_sync_node_added({}, function(node)
	dress(node)
end)
replicate.sub_sync_node_removed(function(node, id)
	mobs[id] = nil
end)

function M.update(dt)
	for id, m in pairs(mobs) do
		local p = m.node.worldPosition
		m.light_t = m.light_t - dt
		if not m.arrow then
			local h = m.node:GetVar("skelenti_hurt"):GetInt()
			if h ~= m.hurt then
				m.hurt = h
				m.red_t = 0.3
				m.light_t = 0
			end
			if m.red_t > 0 then
				m.red_t = m.red_t - dt
				if m.red_t <= 0 then
					m.light_t = 0
				end
			end
			-- The swing: as fast as it goes, as far as it goes
			local dx, dz = p.x - m.last.x, p.z - m.last.z
			local speed = dt > 0 and math.sqrt(dx * dx + dz * dz) / dt or 0
			m.last = magic.Vector3(p.x, p.y, p.z)
			m.phase = m.phase + speed * dt * 5
			local a = math.sin(m.phase) * math.min(1, speed) * 35
			for _, part in ipairs(m.parts) do
				if part.swing then
					part.node.rotation = magic.Quaternion(a * part.swing, 0, 0)
				end
			end
		end
		if m.light_t <= 0 then
			m.light_t = 0.25
			-- Under pbr through the lit passes, as the module's own
			-- objects: the sun's direction and shadow on its sides, and
			-- its shadow cast ([SKELENTI_MOB_LIGHT])
			local pbr = luanti.light_units ~= nil
			if m.pbr ~= pbr then
				m.pbr = pbr
				luanti.set_model_technique(m.mat, pbr)
				for _, cg in ipairs(m.cgs) do
					cg.castShadows = pbr
				end
			end
			local c
			if pbr then
				c = luanti.model_light(p.x, p.y + 0.5, p.z, true)
			else
				c = luanti.light_color(p.x, p.y + 0.5, p.z, false, true)
			end
			if c then
				if m.red_t and m.red_t > 0 then
					c = magic.Color(math.min(1, c.r * 1.5 + 0.3), c.g * 0.4,
							c.b * 0.4, 1)
				end
				m.mat:SetShaderParameter("MatDiffColor", c)
			end
		end
	end
end

-- The point stage: the nearest mob the ray goes into within reach, as
-- its distance and what a click at it does
function M.point(eye, dir, reach)
	local best, hit
	for id, m in pairs(mobs) do
		if not m.arrow then
			local p, k = m.node.worldPosition, m.kind
			local lo = {p.x - k.half, p.y, p.z - k.half}
			local hi = {p.x + k.half, p.y + k.height, p.z + k.half}
			local o, d = {eye.x, eye.y, eye.z}, {dir.x, dir.y, dir.z}
			local t0, t1 = 0, reach
			for a = 1, 3 do
				if math.abs(d[a]) < 1e-9 then
					if o[a] < lo[a] or o[a] > hi[a] then
						t0 = math.huge
					end
				else
					local ta, tb = (lo[a] - o[a]) / d[a], (hi[a] - o[a]) / d[a]
					t0 = math.max(t0, math.min(ta, tb))
					t1 = math.min(t1, math.max(ta, tb))
				end
			end
			if t0 <= t1 and (best == nil or t0 < best) then
				best = t0
				hit = function()
					log:info("skelenti: punch " .. id)
					buildat.send_packet("skelenti:punch", tostring(id))
				end
			end
		end
	end
	return best, hit
end

-- For a drive: where each mob is
function M.list()
	local out = {}
	for id, m in pairs(mobs) do
		local p = m.node.worldPosition
		out[#out + 1] = {id = id, arrow = m.arrow or false,
			x = p.x, y = p.y, z = p.z}
	end
	return out
end

local sounds = {}
buildat.sub_packet("skelenti:sound", function(data)
	local moment, x, y, z = data:match("^(%S+) (%S+) (%S+) (%S+)$")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if not z then
		return
	end
	local sound = M.sounds and M.sounds.pick(moment)
	log:info(string.format("skelenti: sound %s at %.1f,%.1f,%.1f: %s", moment,
			x, y, z, sound and "blip" or "silent"))
	if not sound then
		return
	end
	local node = replicate.main_scene:CreateChild("sound")
	node.position = magic.Vector3(x, y, z)
	local src = node:CreateComponent("SoundSource3D")
	src.soundType = magic.SOUND_EFFECT
	src.nearDistance = 2
	src.farDistance = 24
	src:Play(sound)
	sounds[#sounds + 1] = {node = node, t = 5}
end)
magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	for i = #sounds, 1, -1 do
		sounds[i].t = sounds[i].t - dt
		if sounds[i].t <= 0 then
			sounds[i].node:Remove()
			table.remove(sounds, i)
		end
	end
	M.update(dt)
end)

return M
-- vim: set noet ts=4 sw=4:
