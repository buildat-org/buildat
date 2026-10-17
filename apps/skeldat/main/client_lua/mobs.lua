-- Buildat: apps/skeldat/main/client_lua/mobs.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The mobs as the client sees them, skelenti's mobs.lua: the server's
-- nodes (main.cpp) dressed as boxes of the skins' layout, the legs and arms
-- swinging as they walk, lit by the voxel light where they stand, red for
-- a moment when hurt. M.point() finds the one the eyes are on; a click at
-- it is sent as luanti:punch_object. Their sounds come by name (skeldat:sound)
-- and are played from sounds.lua's.
--   local mobs = run_script_file("main/mobs.lua")(game, sounds)
-- game.light_units: the frame's light (init.lua's update_sky), and
-- game.sky_light builtin/luanti's rules that light an object by it.
-- simplified: no death animation and no bow drawn; boxes axis-aligned
-- for pointing (a boar is pointed at as a square); unlit, flat by the
-- light where it stands -- no sun direction on its sides, no shadow
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local log = buildat.Logger("skeldat")

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
	skeldat_skeleton = {texture = "main/skeleton.png", tw = 64, th = 32,
		half = 0.35, height = 2,
		parts = {
			{0, 24, 0, {-4, 0, -4, 4, 8, 4}, skin(0, 0, 8, 8, 8)},
			{0, 12, 0, {-4, 0, -2, 4, 12, 2}, skin(16, 16, 8, 12, 4)},
			{-5, 24, 0, {-1, -12, -1, 1, 0, 1}, skin(40, 16, 2, 12, 2), 1},
			{5, 24, 0, {-1, -12, -1, 1, 0, 1}, skin(40, 16, 2, 12, 2), -1},
			{-2, 12, 0, {-1, -12, -1, 1, 0, 1}, skin(0, 16, 2, 12, 2), -1},
			{2, 12, 0, {-1, -12, -1, 1, 0, 1}, skin(0, 16, 2, 12, 2), 1},
		}},
	skeldat_boar = {texture = "main/boar.png", tw = 64, th = 32,
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

-- An unlit cut-out (builtin/luanti's objects' technique)
local function material(texture)
	local m = magic.Material.new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"luanti_client/res/LuantiUnlitMask.xml"))
	local t = magic.cache:GetResource("Texture2D", texture)
	if t then
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

return function(game, sounds)
	local M = {}
	local mobs = {} -- node id -> {node, kind, parts, mat, ...}

	-- The light where it stands, as builtin/luanti's pbr path lights an
	-- object (sky_light.object_light): r, g, b
	local function light_at(p)
		local v = voxelworld.get_static_voxel(buildat.Vector3(
				math.floor(p.x + 0.5), math.floor(p.y + 0.5),
				math.floor(p.z + 0.5)))
		if v == nil or game.light_units == nil then
			return nil
		end
		local reg = voxelworld.get_voxel_registry()
		return game.sky_light.object_light(game.light_units,
				reg:light_sky_of(v) / 15, reg:light_lamp_of(v) / 15)
	end

	-- The kind's parts on node, and its entry in mobs
	local function wear(node, kind)
		local mat = material(kind.texture)
		local parts = {}
		for _, p in ipairs(kind.parts) do
			local child = node:CreateChild("part")
			child.position = magic.Vector3(p[1] / 16, p[2] / 16, p[3] / 16)
			local quads, b = {}, p[4]
			box(quads, p[5], kind.tw, kind.th, b[1], b[2], b[3], b[4], b[5], b[6])
			build(child, quads, mat)
			parts[#parts + 1] = {node = child, swing = p[6]}
		end
		local pos = node.worldPosition
		local m = {node = node, kind = kind, parts = parts,
			mat = mat, last = magic.Vector3(pos.x, pos.y, pos.z), phase = 0,
			light_t = 0, hurt = node:GetVar("skeldat_hurt"):GetInt(), red_t = 0}
		mobs[node:GetID()] = m
		return m
	end

	local function dress(node)
		local name = node:GetName()
		local kind = KINDS[name]
		if name == "skeldat_arrow" then
			-- Two crossed strips of the arrow's side, the head forward (+z)
			local quads, w, l = {}, 0.08, 0.4
			local r = {0, 0, 32, 8}
			quad(quads, r, 64, 64, {0, w, -l}, {0, w, l}, {0, -w, l}, {0, -w, -l})
			quad(quads, r, 64, 64, {-w, 0, -l}, {-w, 0, l}, {w, 0, l}, {w, 0, -l})
			local mat = material("main/arrow_entity.png")
			build(node:CreateChild("look"), quads, mat)
			mobs[node:GetID()] = {node = node, mat = mat, arrow = true,
				light_t = 0}
			return
		end
		if name == "skeldat_drop" then
			-- A stack on the ground ([SKELDAT_DEATH_DROPS]): its item's
			-- picture on two crossed upright quads, no swing (as an arrow)
			local quads, w = {}, 0.2
			local r = {0, 0, 16, 16}
			quad(quads, r, 16, 16, {-w, 2 * w, 0}, {w, 2 * w, 0}, {w, 0, 0},
					{-w, 0, 0})
			quad(quads, r, 16, 16, {0, 2 * w, -w}, {0, 2 * w, w}, {0, 0, w},
					{0, 0, -w})
			local item = node:GetVar("skeldat_item"):GetString()
			local mat = material(game.item_texture(item) or "")
			mat.cullMode = magic.CULL_NONE
			build(node:CreateChild("look"), quads, mat)
			mobs[node:GetID()] = {node = node, mat = mat, arrow = true,
				light_t = 0}
			log:info("skeldat: a drop of " .. item .. " is here")
			return
		end
		if not kind then
			return
		end
		wear(node, kind)
		log:info("skeldat: a " .. name:gsub("skeldat_", "") .. " (" ..
				node:GetID() .. ") is here")
	end

	replicate.sub_sync_node_added({}, function(node)
		dress(node)
	end)
	replicate.sub_sync_node_removed(function(node, id)
		mobs[id] = nil
	end)

	-- [SKELDAT_SKELETON_PLAYERS] Another player's node (init.lua) as a
	-- mob kind ("skeldat_skeleton"), walking and lit like one but not
	-- pointed at; undress takes it off
	function M.dress_as(node, name)
		wear(node, KINDS[name]).player = true
	end
	function M.undress(node)
		local m = mobs[node:GetID()]
		for _, part in ipairs(m and m.parts or {}) do
			part.node:Remove()
		end
		mobs[node:GetID()] = nil
	end

	function M.update(dt)
		for _, m in pairs(mobs) do
			local p = m.node.worldPosition
			m.light_t = m.light_t - dt
			if not m.arrow then
				local h = m.node:GetVar("skeldat_hurt"):GetInt()
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
				local r, g, b = light_at(magic.Vector3(p.x, p.y + 0.5, p.z))
				if r then
					local c = magic.Color(r, g, b, 1)
					if m.red_t and m.red_t > 0 then
						local k = (r + g + b) / 3
						c = magic.Color(k * 1.5 + 0.3, k * 0.4, k * 0.4, 1)
					end
					m.mat:SetShaderParameter("MatDiffColor", c)
				end
			end
		end
	end

	-- The nearest mob the ray from eye along dir goes into within reach:
	-- its distance and its node id
	function M.point(eye, dir, reach)
		local best, hit
		for id, m in pairs(mobs) do
			if not m.arrow and not m.player then
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
					best, hit = t0, id
				end
			end
		end
		return best, hit
	end

	function M.punch(id)
		log:info("skeldat: punch " .. id)
		game.send_luanti("punch_object", {tostring(id)}, {"array", "string"})
	end

	-- A sound by name at a place, heard from up to 24 voxels, or far
	local playing = {}
	-- [SKELDAT_BOW_SOUNDS] An arrow lands mostly 20 to 40 off; a shot
	-- heard to 32 ([SKELDAT_BOW_SOUND_TUNE])
	local FAR = {arrow_land = 48, bow = 32}
	function M.play_at(moment, x, y, z, gain, far)
		local sound = sounds.pick(moment)
		if not sound then
			return
		end
		local node = replicate.main_scene:CreateChild("sound")
		node.position = magic.Vector3(x, y, z)
		local src = node:CreateComponent("SoundSource3D")
		src.soundType = magic.SOUND_EFFECT
		src.nearDistance = 2
		src.farDistance = far or FAR[moment] or 24
		src.gain = gain or 1
		src:Play(sound)
		playing[#playing + 1] = {node = node, t = 5}
	end
	buildat.sub_packet("skeldat:sound", function(data)
		local moment, x, y, z = data:match("^(%S+) (%S+) (%S+) (%S+)$")
		x, y, z = tonumber(x), tonumber(y), tonumber(z)
		if not z then
			return
		end
		log:info(string.format("skeldat: sound %s at %.1f,%.1f,%.1f", moment,
				x, y, z))
		M.play_at(moment, x, y, z)
	end)
	-- The bodiless skeletons out to the view ([SKELDAT_FAR_SKELETONS]):
	-- skeldat:far, "x y z yaw" a line (the yaw in sixteenths of a turn),
	-- each a pooled node built once with the skeleton's parts in the
	-- standing pose, moved and turned per packet; the spare ones hidden.
	-- One geometry for all was rebuilt per packet, 80 ms for 590 of them
	-- (luabind's conversion of every quad), a hitch every second.
	-- simplified: lit by one value, the light at the first of them; no
	-- step between the voxels (a lerp if the jumps read badly)
	local far = {pool = {}, mat = nil, light_t = 0, at = nil, n = 0,
		frames = 0, frames_t = 0}
	-- The skeleton's quads round its feet, once
	local far_template = {}
	do
		local k = KINDS.skeldat_skeleton
		for _, part in ipairs(k.parts) do
			local q, b = {}, part[4]
			box(q, part[5], k.tw, k.th, b[1], b[2], b[3], b[4], b[5], b[6])
			for _, one in ipairs(q) do
				for i = 1, 12, 3 do
					one.p[i] = one.p[i] + part[1] / 16
					one.p[i + 1] = one.p[i + 1] + part[2] / 16
					one.p[i + 2] = one.p[i + 2] + part[3] / 16
				end
				far_template[#far_template + 1] = one
			end
		end
	end
	buildat.sub_packet("skeldat:far", function(data)
		local t0 = buildat.get_time_us()
		far.mat = far.mat or material(KINDS.skeldat_skeleton.texture)
		local n = 0
		far.at = nil
		for line, x, y, z, yw in data:gmatch("((%S+) (%S+) (%S+) (%S+))\n") do
			n = n + 1
			local slot = far.pool[n]
			if not slot then
				slot = {node = replicate.main_scene:CreateChild("far_skeleton"),
					line = nil}
				build(slot.node, far_template, far.mat)
				far.pool[n] = slot
			end
			x, y, z = tonumber(x), tonumber(y), tonumber(z)
			-- The sandbox's calls are the cost: none for one that is as it was
			if slot.line ~= line then
				slot.node.position = magic.Vector3(x, y, z)
				slot.node.rotation = magic.Quaternion(0, tonumber(yw) * 22.5, 0)
				if not slot.line then
					slot.node:SetEnabled(true)
				end
				slot.line = line
			end
			far.at = far.at or magic.Vector3(x, y + 1, z)
		end
		for i = n + 1, far.n do
			far.pool[i].node:SetEnabled(false)
			far.pool[i].line = nil
		end
		far.n = n
		far.light_t = 0
		if far.n ~= far.said then
			far.said = far.n
			log:info(string.format("skeldat: %d far skeletons drawn (placed in "
					.. "%.1f ms)", far.n, (buildat.get_time_us() - t0) / 1000))
		end
	end)

	magic.SubscribeToEvent("Update", function(_, d)
		local dt = d:GetFloat("TimeStep")
		-- The frames' mean beside the far count, every 10 s
		far.frames, far.frames_t = far.frames + 1, far.frames_t + dt
		if far.frames_t >= 10 then
			log:info(string.format("skeldat: frames %.1f ms, %d far skeletons",
					far.frames_t * 1000 / far.frames, far.n))
			far.frames, far.frames_t = 0, 0
		end
		far.light_t = far.light_t - dt
		if far.at and far.light_t <= 0 then
			far.light_t = 0.5
			local r, g, b = light_at(far.at)
			if r then
				far.mat:SetShaderParameter("MatDiffColor", magic.Color(r, g, b, 1))
			end
		end
		for i = #playing, 1, -1 do
			playing[i].t = playing[i].t - dt
			if playing[i].t <= 0 then
				playing[i].node:Remove()
				table.remove(playing, i)
			end
		end
		M.update(dt)
	end)

	return M
end
-- vim: set noet ts=4 sw=4:
