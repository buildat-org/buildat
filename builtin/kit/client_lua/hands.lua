-- Buildat: builtin/kit/client_lua/hands.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [KIT_TOOLS_1] (stage 7c's first part) The hands: the item types
-- ("kit:item_types"), the hotbar -- this player's items in a line at the
-- bottom, the one held marked; the wheel (first person) and the keys
-- item_next and item_prev (none by default) pick, "kit:hold" tells the
-- server -- and what a held item does: a melee item's hit on a player or
-- an entity with health in its reach (M.hit_pick, play_target's "hit"):
-- the swing at once, here, the hit the server's ("kit:hit"); an item of
-- use kind "use" ("kit:item"). A dig the server says takes time
-- ("kit:digging") is asked again when due while the left button is held
-- (M.on_digging(cb): the app sends it).
-- [KIT_TOOLS_2] A ranged item: the left button shoots ("kit:shoot" {dir}
-- along the view: single a press, auto while held, burst `burst` a
-- press), a charge draws while held and shoots as let go ("kit:draw"
-- first), the key reload ("kit:reload"); the view kicks up by its recoil.
-- The held item in first person (skeldat's way, its wield.lua: a node
-- under the camera, at the item's grip): its look's prefab of parts and
-- voxels fitted to FIT metres (none: a box in its colour, its icon on it),
-- a swing for a melee hit, a kick back and a muzzle flash for a shot.
-- Shots ("kit:shot") leave a splat of their colour where they end;
-- projectiles ("kit:projectile") fly as the server's do, stopping where
-- it says ("kit:projectile_end"). No sounds: Kit has no sound path yet.
-- For a drive: "event kit_hold <item>" ("" a hand), "event kit_hit <id>"
-- ("nearest": the nearest player or entity with health), "event
-- kit_shoot [<id>]" (at that entity, else along the view), "event
-- kit_draw" (a charge's start), "event kit_reload"
return function(K)
local M, E, P = K.M, K.E, K.P
local magic = require("buildat/extension/urho3d")
local network = require("buildat/extension/network")
local log = K.log
local entity_t = K.entity_t

M.item_types = {}
local items = {} -- {name: count}, as the server last sent
local held = ""
local bar = nil
local last_swing = 0
local dig_cbs, digging = {}, nil

buildat.sub_packet("kit:item_types", function(data)
	local t = network.parse_json(data)
	M.item_types = type(t) == "table" and t or {}
	local n = 0
	for _ in pairs(M.item_types) do n = n + 1 end
	log:info("kit: " .. n .. " item types")
end)

-- The held item's sheet (nil: a hand, or no item type)
function M.held_item()
	return held ~= "" and M.item_types[held] or nil, held
end

local function show()
	if not P.hands then
		if bar then bar.visible = false end
		return
	end
	if not bar then
		bar = magic.ui.root:CreateChild("Text")
		bar:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 14)
		bar:SetAlignment(magic.HA_CENTER, magic.VA_BOTTOM)
		bar:SetPosition(0, -64)
	end
	local s = {held == "" and "[hand]" or "hand"}
	local names = {}
	for k in pairs(items) do names[#names + 1] = k end
	table.sort(names)
	for _, k in ipairs(names) do
		local t = k .. (items[k] > 1 and " x" .. items[k] or "")
		s[#s + 1] = k == held and "[" .. t .. (M.held_text and
				M.held_text() or "") .. "]" or t
	end
	bar:SetText(table.concat(s, "  "))
	bar.visible = not E.editing
end

function M.hold(item)
	item = tostring(item or "")
	if item ~= "" and not items[item] then
		return
	end
	held = item
	log:info("kit: holds " .. (item == "" and "nothing" or item))
	buildat.send_packet("kit:hold", item)
	show()
end

-- The next (step 1) or the one before (-1) of the hand and the items
local function pick(step)
	local list = {""}
	for k in pairs(items) do list[#list + 1] = k end
	table.sort(list)
	local at = 1
	for i, k in ipairs(list) do
		if k == held then at = i end
	end
	M.hold(list[(at - 1 + step) % #list + 1])
end

-- module.lua's kit:items handler tells it
function M.hands_items(t)
	items = {}
	for k, v in pairs(type(t) == "table" and t or {}) do
		items[tostring(k)] = tonumber(v) or 1
	end
	if held ~= "" and not items[held] then
		held = ""
	end
	show()
end

-- The player or entity with health along the ray within the held melee
-- item's reach (from the body, a camera away from it reaching as far
-- past), and how far: nil without a melee item
function M.hit_pick(origin, dir, far)
	local sheet = M.held_item()
	if not sheet or sheet.use ~= "melee" then
		return nil
	end
	local reach = (tonumber(sheet.reach) or 3) + 0.5 + (far or 0)
	local best, bd = nil, nil
	for id, n in pairs(P.nodes) do
		local s = type(n.show) == "table" and n.show or {}
		local t
		if s.player and id ~= P.you then
			-- A body: 1.7 tall from its node's 0.5 down
			local p = n.node.position
			local wx, wy, wz = p.x - origin.x, p.y + 0.35 - origin.y,
					p.z - origin.z
			local tt = wx * dir.x + wy * dir.y + wz * dir.z
			local cx, cy, cz = wx - dir.x * tt, wy - dir.y * tt, wz - dir.z * tt
			if tt > 0 and math.abs(cy) <= 0.9 and
					math.sqrt(cx * cx + cz * cz) <= 0.55 then
				t = tt
			end
		elseif s.health and not s.player then
			t = entity_t(n, origin, dir)
		end
		if t and t <= reach and (not bd or t < bd) then
			best, bd = id, t
		end
	end
	return best, bd
end

-- A melee item's click: the swing here at once (its cooldown kept here
-- too), the hit on id (nil: a swing at nothing) the server's
function M.swing(id)
	local sheet, item = M.held_item()
	if not sheet then
		return false
	end
	local now = buildat.get_time_us()
	if now - last_swing < (tonumber(sheet.cooldown) or 0) * 1000000 then
		return true
	end
	last_swing = now
	log:info("kit: swing " .. item .. (id and " at " .. tostring(id) or ""))
	M.view_swing()
	if id then
		buildat.send_packet("kit:hit", tostring(id))
	end
	return true
end

-- An item of use kind "use": its click, on the entity pointed at (0 none)
function M.use_item(id)
	local sheet, item = M.held_item()
	if not sheet or sheet.use ~= "use" then
		return false
	end
	log:info("kit: uses " .. item .. " on " .. tostring(id or 0))
	buildat.send_packet("kit:item", tostring(id or 0))
	return true
end

function M.on_digging(cb)
	dig_cbs[#dig_cbs + 1] = cb
end

buildat.sub_packet("kit:digging", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or type(d.cell) ~= "table" then
		return
	end
	local wait = tonumber(d.wait) or 0
	digging = {cell = d.cell, due = buildat.get_time_us() + wait * 1000000}
	log:info(string.format("kit: digging (%d,%d,%d): %.2f s",
			d.cell[1] or 0, d.cell[2] or 0, d.cell[3] or 0, wait))
end)

magic.SubscribeToEvent("Update", function()
	if bar and bar.visible == E.editing then
		show()
	end
	if not digging or buildat.get_time_us() < digging.due then
		return
	end
	local c = digging.cell
	digging = nil
	-- simplified: the button held is the dig going on; the pointer moved
	-- off the cell meanwhile still digs it (the server's reach decides)
	if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
		for _, cb in ipairs(dig_cbs) do cb(c) end
	end
end)

magic.SubscribeToEvent("MouseWheel", function(_, data)
	if not P.hands or E.editing or magic.ui.focusElement ~= nil or
			M.camera_mode() ~= "first_person" or M.pointer_free() then
		return
	end
	pick(data:GetInt("Wheel") > 0 and -1 or 1)
end)

magic.SubscribeToEvent("KeyDown", function(_, data)
	local key = data:GetInt("Key")
	if not P.hands or E.editing or magic.ui.focusElement ~= nil then
		return
	end
	if M.key("item_next", key) then
		pick(1)
	elseif M.key("item_prev", key) then
		pick(-1)
	end
end)

magic.SubscribeToEvent("command_seq:kit_hold", function(_, data)
	M.hold(data:GetString("Param"))
end)
magic.SubscribeToEvent("command_seq:kit_hit", function(_, data)
	local id = data:GetString("Param")
	if id == "nearest" then
		local me = P.nodes[P.you] and P.nodes[P.you].node.position
		local bd = nil
		for nid, n in pairs(P.nodes) do
			local s = type(n.show) == "table" and n.show or {}
			if me and nid ~= P.you and (s.player or s.health) then
				local d = (n.node.position - me):Length()
				if not bd or d < bd then
					id, bd = nid, d
				end
			end
		end
	end
	log:info("kit: hit " .. tostring(id))
	buildat.send_packet("kit:hit", tostring(id))
end)

-- ---- [KIT_TOOLS_2] Ranged items, the held item drawn, shots drawn
local O = K.O
local replicate = require("buildat/extension/replicate")
local FIT = 0.2 -- the look's longest side in first person (m)
local V = {node = nil, item = nil, built = nil, swing = -1, kick = -1,
	flash = nil, flash_at = -1, front = 0.2}
local R = {down = false, drawing = false, draw_at = 0, last = 0, burst = 0,
	reloading = 0}
local now_s = function() return buildat.get_time_us() / 1e6 end

-- The held instance's data (kit/equipment's state "held": wear, loaded)
local function held_state()
	local me = P.nodes[P.you]
	local v = me and me.node:GetVar("kit:held")
	local t = v and not v:IsEmpty() and network.parse_json(v:GetString())
	return type(t) == "table" and t or {}
end

-- The text after the held item on the hotbar: rounds and uses left
function M.held_text()
	local sheet = M.held_item()
	if not sheet then
		return ""
	end
	local h, s = held_state(), {}
	local mag = tonumber(sheet.magazine) or 0
	if sheet.use == "ranged" and mag > 0 then
		s[#s + 1] = (R.reloading > now_s() and "reloading " or "") ..
				tostring(tonumber(h.loaded) or mag) .. "/" .. mag
	end
	local uses = tonumber(sheet.uses) or 0
	if uses > 0 then
		s[#s + 1] = "uses " .. tostring(tonumber(h.wear) or uses)
	end
	return #s > 0 and " " .. table.concat(s, " ") or ""
end

local function unit_box(parent, size, col, mat)
	local n = parent:CreateChild("box")
	n.scale = magic.Vector3(size[1], size[2], size[3])
	local m = n:CreateComponent("StaticModel")
	m.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	m.material = mat or K.material("plain")
	if not mat then
		m.material:SetShaderParameter("MatDiffColor", col)
	end
	m.castShadows = false
	return n
end

-- The look built under holder: its parts and voxels (look_data), else the
-- default; fitted to FIT about its grip (the prefab's base). How many of
-- each, and its front (the muzzle's z)
local function build_look(holder, sheet)
	local inner = holder:CreateChild("look")
	local ld = type(sheet.look_data) == "table" and sheet.look_data or nil
	local lo, hi = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
	local function grow(c, h)
		for k = 1, 3 do
			lo[k] = math.min(lo[k], c[k] - h[k])
			hi[k] = math.max(hi[k], c[k] + h[k])
		end
	end
	local nparts, nvox = 0, 0
	for _, pt in ipairs(ld and type(ld.parts) == "table" and ld.parts or {}) do
		local size = {}
		for k = 1, 3 do
			size[k] = math.max(0.01, tonumber(type(pt.size) == "table" and
					pt.size[k]) or 1)
		end
		local pos = type(pt.pos) == "table" and pt.pos or {}
		local c = {tonumber(pos[1]) or 0, tonumber(pos[2]) or 0,
			tonumber(pos[3]) or 0}
		local n = inner:CreateChild("part")
		n.position = magic.Vector3(c[1], c[2], c[3])
		local r = type(pt.rotation) == "table" and pt.rotation or {}
		n.rotation = magic.Quaternion(tonumber(r[1]) or 0, tonumber(r[2]) or 0,
				tonumber(r[3]) or 0)
		local def = type(pt.voxel) == "string" and pt.voxel ~= "" and
				K.voxel_def(pt.voxel)
		local body = n:CreateChild("body")
		body.scale = magic.Vector3(size[1], size[2], size[3])
		if not (def and K.voxel_mesh(body, def, size, pt.shape)) then
			local mat = K.material(pt.material)
			mat:SetShaderParameter("MatDiffColor", K.color(pt.color,
					magic.Color(0.7, 0.7, 0.7)))
			if pt.shape == "wedge" then
				K.wedge(body):SetMaterial(0, mat)
			else
				local m = body:CreateComponent("StaticModel")
				m.model = magic.cache:GetResource("Model", "Models/Box.mdl")
				m.material = mat
			end
		end
		-- simplified: its bounds unturned
		grow(c, {size[1] / 2, size[2] / 2, size[3] / 2})
		nparts = nparts + 1
	end
	local vx = ld and type(ld.voxels) == "table" and ld.voxels or nil
	if vx and type(vx.kinds) == "table" and type(vx.runs) == "table" and
			type(vx.size) == "table" then
		local sx, sz = tonumber(vx.size[1]) or 0, tonumber(vx.size[3]) or 0
		local at = type(vx.at) == "table" and vx.at or {0, 0, 0}
		local i = 0
		for r = 1, #vx.runs - 1, 2 do
			local kind = vx.kinds[(tonumber(vx.runs[r + 1]) or 0) + 1]
			local name = type(kind) == "table" and kind[1] or "air"
			local def = name ~= "air" and K.voxel_def(name)
			for _ = 1, tonumber(vx.runs[r]) or 0 do
				if def and nvox < 4096 then
					local x, z = i % sx, math.floor(i / sx) % sz
					local y = math.floor(i / (sx * sz))
					local c = {(tonumber(at[1]) or 0) + x, (tonumber(at[2]) or 0) +
						y, (tonumber(at[3]) or 0) + z}
					local n = inner:CreateChild("voxel")
					n.position = magic.Vector3(c[1], c[2], c[3])
					K.voxel_mesh(n, def, {1, 1, 1})
					grow(c, {0.5, 0.5, 0.5})
					nvox = nvox + 1
				end
				i = i + 1
			end
		end
	end
	if nparts + nvox == 0 then
		-- The default: a bar in its colour along +z, its icon on it
		local mat = nil
		local tex = type(sheet.icon) == "string" and sheet.icon ~= "" and
				magic.cache:GetResource("Texture2D", sheet.icon)
		if tex then
			tex.filterMode = magic.FILTER_NEAREST
			mat = magic.Material:new()
			mat:SetTechnique(0, magic.cache:GetResource("Technique",
					"Techniques/Diff.xml"))
			mat:SetTexture(magic.TU_DIFFUSE, tex)
		end
		local n = unit_box(inner, {0.05, 0.05, 0.2}, K.color(sheet.color,
				magic.Color(0.7, 0.7, 0.7)), mat)
		n.position = magic.Vector3(0, 0, 0.08)
		grow({0, 0, 0.08}, {0.025, 0.025, 0.1})
	end
	local ext = math.max(hi[1] - lo[1], hi[2] - lo[2], hi[3] - lo[3], 0.01)
	local k = FIT / ext
	inner.scale = magic.Vector3(k, k, k)
	return nparts, nvox, hi[3] * k
end

-- The held item's node under the camera, built as the hands change; drawn
-- in first person while playing
local function view_update()
	local sheet, item = M.held_item()
	local cam = O.camera
	local show = cam ~= nil and sheet ~= nil and P.hands and not E.editing and
			M.camera_mode() == "first_person"
	if V.node and (V.cam ~= cam or V.item ~= item or V.look ~= sheet) then
		V.node:Remove()
		V.node, V.item, V.look = nil, nil, nil
	end
	if not show then
		if V.node then V.node.enabled = false end
		return
	end
	if not V.node then
		V.node = cam:CreateChild("kit_held")
		V.cam, V.item, V.look = cam, item, sheet
		local np, nv
		np, nv, V.front = build_look(V.node, sheet)
		V.flash = unit_box(V.node, {0.035, 0.035, 0.035},
				magic.Color(1, 0.95, 0.6), K.material("glow"))
		V.flash.position = magic.Vector3(0, 0, V.front + 0.02)
		V.flash.enabled = false
		log:info(string.format("kit: %s drawn in first person: %s, %d parts, " ..
				"%d voxels", item, np + nv > 0 and "look " ..
				tostring(sheet.look) or "the default look", np, nv))
	end
	V.node.enabled = true
	local g = type(sheet.grip) == "table" and sheet.grip or {}
	local t = now_s()
	local pos = magic.Vector3(tonumber(g[1]) or 0.13, tonumber(g[2]) or -0.11,
			tonumber(g[3]) or 0.22)
	local rot = magic.Quaternion(0, -4, 0)
	-- A melee swing: down and in over a quarter of a second
	local sw = V.swing >= 0 and (t - V.swing) / 0.25 or 1
	if sw < 1 then
		local a = math.sin(sw * math.pi)
		rot = rot * magic.Quaternion(60 * a, -20 * a, 0)
		pos = pos + magic.Vector3(-0.04 * a, -0.02 * a, 0.05 * a)
	end
	-- A shot's kick: back and up, eased out over 0.15 s
	local kk = V.kick >= 0 and (t - V.kick) / 0.15 or 1
	if kk < 1 then
		local a = (1 - kk) * (1 - kk)
		rot = rot * magic.Quaternion(-10 * a, 0, 0)
		pos = pos + magic.Vector3(0, 0.01 * a, -0.04 * a)
	end
	-- A charge: drawn back as it fills
	if R.drawing then
		local c = tonumber(sheet.charge) or 0
		local f = c > 0 and math.min(1, (t - R.draw_at) / c) or 0
		pos = pos + magic.Vector3(0, 0, -0.06 * f)
	end
	V.node.position = pos
	V.node.rotation = rot
	V.flash.enabled = t - V.flash_at < 0.06
end

-- The aim: along the view, or at an entity or along a direction (a
-- drive's)
local function aim(id, dir)
	if dir then
		return dir
	end
	local cam = O.camera
	local d = cam and cam.worldDirection or magic.Vector3(0, 0, 1)
	local n = id and P.nodes[id]
	if n and cam then
		local to = n.node.position + magic.Vector3(0, (type(n.show) == "table"
				and n.show.player) and 0.35 or 0, 0)
		local me = M.body_pos and M.body_pos()
		local eye = me and me + magic.Vector3(0, 1.55, 0) or cam.worldPosition
		d = (to - eye):Normalized()
	end
	return d
end

-- A shot: the server decides; here at once the kick, the flash, the
-- recoil (its cooldown kept here too)
local function shoot(id, dir)
	local sheet, item = M.held_item()
	if not sheet or sheet.use ~= "ranged" then
		return false
	end
	local t = now_s()
	if t - R.last < (tonumber(sheet.cooldown) or 0) - 0.01 then
		return false
	end
	R.last = t
	local d = aim(id, dir)
	buildat.send_packet("kit:shoot", network.write_json({dir = {d.x, d.y, d.z}}))
	R.drawing = false
	V.kick, V.flash_at = t, t
	if M.kick then
		M.kick(tonumber(sheet.recoil) or 0)
	end
	log:info(string.format("kit: shoots %s along (%.2f, %.2f, %.2f)", item,
			d.x, d.y, d.z))
	return true
end

local function draw()
	local sheet = M.held_item()
	if not sheet or (tonumber(sheet.charge) or 0) <= 0 then
		return false
	end
	R.drawing, R.draw_at = true, now_s()
	buildat.send_packet("kit:draw", "")
	log:info("kit: draws " .. tostring(held))
	return true
end

local function reload()
	log:info("kit: reloads " .. tostring(held))
	buildat.send_packet("kit:reload", "")
end

buildat.sub_packet("kit:reloading", function(data)
	local d = network.parse_json(data)
	R.reloading = now_s() + (type(d) == "table" and tonumber(d.time) or 0)
end)

-- Splats and projectiles in the world's scene
local splats, flying = {}, {}
local function splat(p, col, keep)
	local scene = replicate.main_scene
	if not scene then
		return
	end
	local n = scene:CreateChild("kit_splat")
	n.position = magic.Vector3(p[1], p[2], p[3])
	unit_box(n, {0.16, 0.16, 0.16}, K.color(col, magic.Color(1, 0.3, 0.8)))
	splats[#splats + 1] = {node = n, till = now_s() + (keep or 20)}
	if #splats > 64 then
		table.remove(splats, 1).node:Remove()
	end
end

buildat.sub_packet("kit:shot", function(data)
	local d = network.parse_json(data)
	if type(d) ~= "table" or type(d.ends) ~= "table" then
		return
	end
	local n = 0
	for _, e in ipairs(d.ends) do
		if type(e) == "table" and (tonumber(e[4]) or 0) > 0 then
			splat(e, d.color)
			n = n + 1
		end
	end
	log:info("kit: a shot of " .. tostring(d.item) .. ": " .. n .. " splats")
end)

buildat.sub_packet("kit:projectile", function(data)
	local d = network.parse_json(data)
	local scene = replicate.main_scene
	if type(d) ~= "table" or type(d.from) ~= "table" or not scene then
		return
	end
	local n = scene:CreateChild("kit_projectile")
	unit_box(n, {0.04, 0.04, 0.5}, K.color(d.color, magic.Color(0.6, 0.4,
			0.2)))
	flying[tonumber(d.id) or 0] = {node = n, from = d.from, vel = d.vel,
		g = tonumber(d.gravity) or 0, at = now_s(), life = tonumber(d.life) or 5}
	log:info("kit: projectile " .. tostring(d.id))
end)

buildat.sub_packet("kit:projectile_end", function(data)
	local d = network.parse_json(data)
	local f = type(d) == "table" and flying[tonumber(d.id) or 0]
	if not f then
		return
	end
	flying[tonumber(d.id)] = nil
	f.node:Remove()
	if type(d.at) == "table" then
		splat(d.at, d.color, 10)
	end
	log:info("kit: projectile " .. tostring(d.id) .. (d.hit and " hit" or
			" ended"))
end)

local function fly()
	local t = now_s()
	for id, f in pairs(flying) do
		local s = t - f.at
		if s > f.life + 1 then
			f.node:Remove()
			flying[id] = nil
		else
			local v = f.vel
			f.node.position = magic.Vector3(f.from[1] + v[1] * s,
					f.from[2] + v[2] * s - 0.5 * f.g * s * s, f.from[3] + v[3] * s)
			-- Along its flight: its yaw and pitch from the velocity
			local vy = v[2] - f.g * s
			f.node.rotation = magic.Quaternion(-math.deg(math.atan2(vy,
					math.sqrt(v[1] * v[1] + v[3] * v[3]))),
					math.deg(math.atan2(v[1], v[3])), 0)
		end
	end
	while splats[1] and splats[1].till < t do
		table.remove(splats, 1).node:Remove()
	end
end

-- The left button while playing (the pointer captured)
local function playing()
	return P.hands and not E.editing and magic.ui.focusElement == nil and
			not M.pointer_free()
end

magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	if data:GetInt("Button") ~= magic.MOUSEB_LEFT or not playing() then
		return
	end
	local sheet = M.held_item()
	if not sheet or sheet.use ~= "ranged" then
		return
	end
	R.down = true
	if draw() then
		return
	end
	if shoot() and sheet.mode == "burst" then
		R.burst = (tonumber(sheet.burst) or 1) - 1
	end
end)

magic.SubscribeToEvent("MouseButtonUp", function(_, data)
	if data:GetInt("Button") ~= magic.MOUSEB_LEFT then
		return
	end
	R.down = false
	if R.drawing then
		shoot()
	end
end)

function M.view_swing()
	V.swing = now_s()
end

magic.SubscribeToEvent("Update", function()
	view_update()
	fly()
	-- The hotbar again as the held instance's rounds and wear change
	local ht = M.held_text()
	if ht ~= R.ht then
		R.ht = ht
		show()
		if ht ~= "" then
			log:info("kit: in hand " .. tostring(held) .. ht)
		end
	end
	local sheet = M.held_item()
	if not sheet or sheet.use ~= "ranged" then
		R.burst, R.drawing = 0, false
		return
	end
	-- Auto while held, the rest of a burst
	if (sheet.mode == "auto" and R.down and playing()) or R.burst > 0 then
		if shoot() and R.burst > 0 then
			R.burst = R.burst - 1
		end
	end
end)

magic.SubscribeToEvent("KeyDown", function(_, data)
	if P.hands and not E.editing and magic.ui.focusElement == nil and
			M.key("reload", data:GetInt("Key")) then
		reload()
	end
end)

magic.SubscribeToEvent("command_seq:kit_shoot", function(_, data)
	local p = data:GetString("Param")
	local x, y, z = p:match("^([%-%d.]+),([%-%d.]+),([%-%d.]+)$")
	if x then
		shoot(nil, magic.Vector3(tonumber(x), tonumber(y), tonumber(z)):
				Normalized())
	else
		shoot(tonumber(p))
	end
end)
magic.SubscribeToEvent("command_seq:kit_draw", function()
	draw()
end)
magic.SubscribeToEvent("command_seq:kit_reload", function()
	reload()
end)

end
-- vim: set noet ts=4 sw=4:
