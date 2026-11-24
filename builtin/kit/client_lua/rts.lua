-- [KIT_RTS] kit/controls' camera "rts" (kit_plan 4z37zzn): a camera alone (no
-- body: the server steps none, players.lua draws none), an orbit round a
-- point, a depth cut, and the selection of and the orders to kit/unit's
-- entities (kit.cpp's on_order_u).
--
--   The orbit: kit/controls' height m from the point (times the zoom: the
--   wheel, a pinch), angle degrees down, yaw its first turn. The movement keys
--   (WASD) or the touch stick pan; a middle drag or one finger drags the
--   ground; a right drag or the arrow keys turn and tilt.
--   The cut (module.lua's set_cut: the voxels; the looks here): what is above
--   it is not drawn. PageUp and PageDown (the editor's nudges) or Shift and
--   the wheel move it a metre, Home takes it off and puts it back; the cut
--   param (> 0) puts it on at the start. With it on the point is 1.5 m under
--   it, so the view goes down with it.
--   The selection: a left click picks a unit of the player's (show.unit's team
--   "" or theirs) under the pointer, a left drag those in its box; Shift adds.
--   A right click orders the selection at what is under the pointer: an
--   entity not theirs with a health or a unit, else the point of the ground
--   (the cut's floor). Ctrl and a hotbar key (1-9, 0) keeps the selection as
--   that group, the key alone takes it again. A selected unit has a ring.
--   A touchscreen: a tap on a unit of theirs selects it, elsewhere orders.
--
-- simplified: no pan at the screen's edge (a window's pointer leaves it); no
-- box selection by touch; the looks' cut by their bottom, whole (a tall one
-- below the cut is drawn whole); the order's ground point the voxels' (a
-- heightmap's ground: the point's plane)
return function(K)
local M, E, O, P = K.M, K.E, K.O, K.P
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = K.log
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"

local R = {on = false, at = nil, yaw = 0, pitch = 60, cut = nil, sel = {},
	groups = {}, rings = {}, hidden = {}, drag = nil, ring_mat = nil, box = nil,
	moved = 0}

local function screen()
	local sc = magic.ui.scale
	return magic.ui.root.width * sc, magic.ui.root.height * sc
end

local function cam_of()
	return O.camera and O.camera:GetComponent("Camera")
end

-- A unit's look (its middle), nil none
local function unit_point(n)
	if not n.look or not n.box then
		return nil
	end
	local p, o = n.look.position, n.box.off
	return magic.Vector3(p.x + o[1], p.y + o[2], p.z + o[3])
end

-- Where a point is on the screen (pixels), nil behind the camera (or none)
local function on_screen(cam, p)
	if not p then
		return nil
	end
	local o, f = O.camera.worldPosition, O.camera.worldDirection
	if (p.x - o.x) * f.x + (p.y - o.y) * f.y + (p.z - o.z) * f.z <= 0 then
		return nil
	end
	local s = cam:WorldToScreenPoint(p)
	local w, h = screen()
	return s.x * w, s.y * h
end

local function own(n)
	local u = type(n.show) == "table" and n.show.unit
	return type(u) == "table" and (u.team == "" or u.team == M.my_team())
end

local function count(t)
	local k = 0
	for _ in pairs(t) do
		k = k + 1
	end
	return k
end

-- ---- The rings

local function ring_of(id, n, on)
	local r = R.rings[id]
	if r and r.look ~= n.look then
		r = nil
	end
	if not on then
		if r then
			r.node.enabled = false
		end
		return
	end
	if not r then
		if not R.ring_mat then
			R.ring_mat = K.material("glow")
			R.ring_mat:SetShaderParameter("MatDiffColor", magic.Color(0.2, 1, 0.3))
		end
		local node = n.look:CreateChild("kit_ring")
		local m = node:CreateComponent("StaticModel")
		m.model = magic.cache:GetResource("Model", "Models/Cylinder.mdl")
		m.material = R.ring_mat
		r = {look = n.look, node = node}
		R.rings[id] = r
	end
	local o, s = n.box.off, n.box.size
	local d = math.max(s[1], s[3]) * 1.4
	r.node.position = magic.Vector3(o[1], o[2] - s[2] / 2 + 0.03, o[3])
	r.node.scale = magic.Vector3(d, 0.04, d)
	r.node.enabled = not R.hidden[id]
end

local function select_ids(ids, add, why)
	if not add then
		R.sel = {}
	end
	for _, id in ipairs(ids) do
		R.sel[id] = true
	end
	log:info("kit: rts: selected " .. count(R.sel) .. " (" .. why .. ")")
end

-- ---- The cut on the looks: one whose bottom is over it not drawn, its
-- nodes' own enabled kept to be put back

local function walk(node, out)
	out[#out + 1] = {node, node.enabled}
	for i = 0, node:GetNumChildren() - 1 do
		walk(node:GetChild(i), out)
	end
end

local function cut_look(id, n)
	local p = n.look and n.box and n.look.position
	local over = R.cut ~= nil and p ~= nil and
			p.y + n.box.off[2] - n.box.size[2] / 2 > R.cut
	local h = R.hidden[id]
	if over and not h then
		h = {look = n.look}
		walk(n.look, h)
		R.hidden[id] = h
		n.look:SetDeepEnabled(false)
	elseif h and (not over or h.look ~= n.look) then
		R.hidden[id] = nil
		if h.look == n.look then
			for _, e in ipairs(h) do
				e[1].enabled = e[2]
			end
		end
	end
end

local function set_cut(y)
	R.cut = y
	M.set_cut(y)
	log:info("kit: rts: the cut " .. (y and string.format("at %.1f", y) or "off"))
end

-- ---- The camera (controls.lua's Update calls it in the rts mode)

function M.rts_camera(dt, at, node, par)
	local cam = node:GetComponent("Camera")
	if not R.on then
		R.on = true
		R.yaw = tonumber(par.yaw) or 0
		R.pitch = math.max(15, math.min(89, tonumber(par.angle) or 60))
		R.at = nil
		log:info("kit: rts: the camera on")
	end
	if not R.at and at then
		R.at = {at[1], at[2], at[3]}
		local c = tonumber(par.cut) or 0
		if c > 0 then
			set_cut(R.at[2] + c)
		end
	end
	R.at = R.at or {0, 0, 0}
	local dist = (tonumber(par.height) or 14) * M.view_zoom()
	cam.fov = magic.fov_for(tonumber(par.fov) or 75)
	cam.orthographic = false
	local busy = E.editing or M.controls_paused() or
			(M.ui_keys and M.ui_keys())
	if not busy then
		local yr = math.rad(R.yaw)
		local fx, fz, rx, rz = math.sin(yr), math.cos(yr), math.cos(yr), -math.sin(yr)
		local f = (M.key_down("forward") and 1 or 0) - (M.key_down("back") and 1 or 0)
		local r = (M.key_down("right") and 1 or 0) - (M.key_down("left") and 1 or 0)
		local st = M.touch_stick()
		if st then
			f, r = f + st.f, r + st.r
		end
		local v = dist * 0.8 * dt
		R.at[1] = R.at[1] + (fx * f + rx * r) * v
		R.at[3] = R.at[3] + (fz * f + rz * r) * v
		local t = (M.key_down("nudge_right") and 1 or 0) -
				(M.key_down("nudge_left") and 1 or 0)
		local tl = (M.key_down("nudge_forward") and 1 or 0) -
				(M.key_down("nudge_back") and 1 or 0)
		R.yaw = (R.yaw - t * 90 * dt) % 360
		R.pitch = math.max(15, math.min(89, R.pitch + tl * 45 * dt))
		local mm = magic.input:GetMouseMove()
		if not TOUCH and magic.input:GetMouseButtonDown(magic.MOUSEB_RIGHT) then
			R.yaw = (R.yaw + mm.x * 0.3) % 360
			R.pitch = math.max(15, math.min(89, R.pitch + mm.y * 0.2))
			R.moved = R.moved + math.abs(mm.x) + math.abs(mm.y)
		elseif not TOUCH and magic.input:GetMouseButtonDown(magic.MOUSEB_MIDDLE) then
			M.rts_pan_pixels(mm.x, mm.y)
		end
	end
	if R.cut then
		R.at[2] = R.cut - 1.5
	end
	local rot = magic.Quaternion(R.pitch, R.yaw, 0)
	local focus = magic.Vector3(R.at[1], R.at[2], R.at[3])
	node.position = focus - rot * magic.Vector3(0, 0, dist)
	node.rotation = rot
	-- The rings and the looks' cut
	for id, n in pairs(P.nodes) do
		if R.cut or R.hidden[id] then
			cut_look(id, n)
		end
		if R.sel[id] or R.rings[id] then
			if R.sel[id] and not n.look then
				R.sel[id] = nil
			end
			if n.look then
				ring_of(id, n, R.sel[id] == true)
			end
		end
	end
	for id in pairs(R.rings) do
		if not P.nodes[id] then
			R.rings[id] = nil
		end
	end
	for id in pairs(R.sel) do
		if not P.nodes[id] then
			R.sel[id] = nil
		end
	end
	R.dist = dist
end

-- A drag of the ground by dx, dy pixels (the point under the pointer kept
-- there, as on the point's plane)
function M.rts_pan_pixels(dx, dy)
	local cam = cam_of()
	if not R.at or not cam then
		return
	end
	local _, h = screen()
	local k = (R.dist or 14) * 2 * math.tan(math.rad(cam.fov) / 2) / math.max(1, h)
	local yr = math.rad(R.yaw)
	local fx, fz, rx, rz = math.sin(yr), math.cos(yr), math.cos(yr), -math.sin(yr)
	local fk = k / math.max(0.3, math.sin(math.rad(R.pitch)))
	R.at[1] = R.at[1] - rx * dx * k + fx * dy * fk
	R.at[3] = R.at[3] - rz * dx * k + fz * dy * fk
end

-- ---- Picking

-- The entity drawn nearest the pointer within 24 px (scaled) that want(n)
-- says, nil none
local function pick(x, y, want)
	local cam = cam_of()
	local best, bd = nil, (24 * magic.ui.scale) ^ 2
	for id, n in pairs(P.nodes) do
		if id ~= P.you and not R.hidden[id] and want(n) then
			local p = unit_point(n)
			local sx, sy = on_screen(cam, p)
			if sx then
				local d = (sx - x) ^ 2 + (sy - y) ^ 2
				if d < bd then
					best, bd = id, d
				end
			end
		end
	end
	return best
end

-- The ground under the pointer: the first voxel under the cut along the
-- ray, else the point's plane
local function ground_at(x, y)
	local o, d = M.screen_ray(x, y, O.camera, cam_of())
	local solid = O.solid
	if solid then
		local cut = R.cut
		local hit, _, t = M.voxel_ray({o.x, o.y, o.z}, {d.x, d.y, d.z},
				function(cx, cy, cz)
					return (not cut or cy - 0.5 < cut) and solid(cx, cy, cz)
				end, 400)
		if hit then
			local p = o + d * t
			return {p.x, math.min(p.y, hit[2] + 0.5), p.z}
		end
	end
	if math.abs(d.y) < 1e-4 then
		return nil
	end
	local t = (R.at[2] - o.y) / d.y
	if t <= 0 then
		return nil
	end
	local p = o + d * t
	return {p.x, p.y, p.z}
end

local function order(x, y)
	local ids = {}
	for id in pairs(R.sel) do
		ids[#ids + 1] = id
	end
	if #ids == 0 then
		return false
	end
	local t = pick(x, y, function(n)
		local s = type(n.show) == "table" and n.show or {}
		return not own(n) and (s.health ~= nil or s.unit ~= nil)
	end)
	local j
	if t then
		j = {ids = ids, target = t}
		log:info("kit: rts: " .. #ids .. " ordered at entity " .. t)
	else
		local g = ground_at(x, y)
		if not g then
			return false
		end
		j = {ids = ids, at = g}
		log:info(string.format("kit: rts: %d ordered to %.2f,%.2f,%.2f", #ids,
				g[1], g[2], g[3]))
	end
	buildat.send_packet("kit:order", network.write_json(j))
	return true
end

local function click_select(x, y, add)
	local id = pick(x, y, own)
	select_ids(id and {id} or {}, add, id and "click on " .. id or "click on none")
end

-- controls.lua's click() in the rts mode: a mouse's left selects, its right
-- orders; a tap selects a unit of theirs, else orders
function M.rts_tap(x, y, left, touch)
	if not x then
		return
	end
	if touch then
		if pick(x, y, own) then
			return click_select(x, y, false)
		end
		return order(x, y)
	end
	if left then
		click_select(x, y, magic.input:GetQualifierDown(magic.QUAL_SHIFT))
	else
		order(x, y)
	end
end

-- ---- The mouse

local function playing()
	return R.on and M.camera_mode() == "rts" and not E.editing and
			not M.controls_paused()
end

local function box_rect(d)
	return math.min(d.x0, d.x), math.min(d.y0, d.y), math.max(d.x0, d.x),
			math.max(d.y0, d.y)
end

magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	if TOUCH or not playing() or ui_utils.clicks_wanted() then
		return
	end
	local mp = magic.input:GetMousePosition()
	if M.ui_at and M.ui_at(mp.x, mp.y) then
		return
	end
	local b = data:GetInt("Button")
	if b == magic.MOUSEB_LEFT then
		R.drag = {x0 = mp.x, y0 = mp.y, x = mp.x, y = mp.y}
	elseif b == magic.MOUSEB_RIGHT then
		R.right, R.moved = {mp.x, mp.y}, 0
	end
end)

magic.SubscribeToEvent("MouseMove", function()
	local d = R.drag
	if not d then
		return
	end
	local mp = magic.input:GetMousePosition()
	d.x, d.y = mp.x, mp.y
	local x0, y0, x1, y1 = box_rect(d)
	if x1 - x0 + y1 - y0 < 6 * magic.ui.scale then
		return
	end
	local sc = magic.ui.scale
	if not R.box then
		R.box = magic.ui.root:CreateChild("BorderImage")
		R.box.priority = 900
		R.box.blendMode = magic.BLEND_ALPHA
		R.box.color = magic.Color(0.3, 1, 0.4, 0.25)
	end
	R.box.visible = true
	R.box:SetPosition(math.floor(x0 / sc), math.floor(y0 / sc))
	R.box:SetFixedSize(math.max(1, math.floor((x1 - x0) / sc)),
			math.max(1, math.floor((y1 - y0) / sc)))
end)

magic.SubscribeToEvent("MouseButtonUp", function(_, data)
	local b = data:GetInt("Button")
	local mp = magic.input:GetMousePosition()
	if b == magic.MOUSEB_LEFT and R.drag then
		local d = R.drag
		R.drag = nil
		if R.box then
			R.box.visible = false
		end
		if not playing() then
			return
		end
		d.x, d.y = mp.x, mp.y
		local x0, y0, x1, y1 = box_rect(d)
		local add = magic.input:GetQualifierDown(magic.QUAL_SHIFT)
		if x1 - x0 + y1 - y0 < 6 * magic.ui.scale then
			return click_select(mp.x, mp.y, add)
		end
		local cam, ids = cam_of(), {}
		for id, n in pairs(P.nodes) do
			local p = own(n) and not R.hidden[id] and unit_point(n)
			local sx, sy = on_screen(cam, p)
			if sx and sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1 then
				ids[#ids + 1] = id
			end
		end
		select_ids(ids, add, string.format("box %d,%d %d,%d", x0, y0, x1, y1))
	elseif b == magic.MOUSEB_RIGHT and R.right then
		local r = R.right
		R.right = nil
		-- (a turn's drag is no order)
		if playing() and R.moved < 6 then
			order(r[1], r[2])
		end
	end
end)

magic.SubscribeToEvent("MouseWheel", function(_, data)
	if not playing() or not magic.input:GetQualifierDown(magic.QUAL_SHIFT) then
		return
	end
	local w = data:GetInt("Wheel")
	local n = w > 0 and 1 or w < 0 and -1 or 0
	set_cut((R.cut or (R.at and R.at[2] + 1.5) or 0) + n)
end)

-- ---- The keys: the cut, the groups

magic.SubscribeToEvent("KeyDown", function(_, data)
	if not playing() or data:GetBool("Repeat") or (M.ui_keys and M.ui_keys()) then
		return
	end
	local f = magic.ui.focusElement
	if f ~= nil and f:GetTypeName() == "LineEdit" then
		return
	end
	local k = data:GetInt("Key")
	local base = R.cut or (R.at and R.at[2] + 1.5) or 0
	if M.key("nudge_up", k) then
		return set_cut(base + 1)
	elseif M.key("nudge_down", k) then
		return set_cut(base - 1)
	elseif k == magic.KEY_HOME then
		if R.cut then
			R.cut_was = R.cut
			return set_cut(nil)
		end
		return set_cut(R.cut_was or base + 0.5)
	end
	for g = 1, 10 do
		if M.key("hotbar" .. g, k) then
			if magic.input:GetQualifierDown(magic.QUAL_CTRL) then
				local l = {}
				for id in pairs(R.sel) do
					l[#l + 1] = id
				end
				R.groups[g] = l
				log:info("kit: rts: group " .. g .. " set (" .. #l .. ")")
			else
				local l = {}
				for _, id in ipairs(R.groups[g] or {}) do
					if P.nodes[id] then
						l[#l + 1] = id
					end
				end
				select_ids(l, false, "group " .. g)
			end
			return
		end
	end
end)

-- ---- [KIT_RTS] Fog of war's darkening (kit:controls' fog: the server sends
-- this client only what its team's units see): its team's units' sight
-- (show.unit.sight) as circles in x, z, merged to FOG_MAX, handed every
-- FOG_EVERY s to the chunks' KITFOG (KitVoxel.glsl) through the view's scene
-- commands (one value for every material), module.lua's set_fog the
-- techniques. simplified: circles, not spheres (a deep tunnel under a unit
-- reads seen); merged by a grid of growing cells, each group's circle the
-- one round its members' (more than they see, never less)

local FOG_MAX, FOG_EVERY = 16, 0.2
local FOG = {on = false, t = 0, rp = nil, n = -1}

local function fog_circles()
	local my, pts, g = M.my_team(), {}, 1
	for _, n in pairs(P.nodes) do
		local u = type(n.show) == "table" and n.show.unit
		local r = type(u) == "table" and u.team == my and my ~= "" and
				tonumber(u.sight) or 0
		if r > 0 then
			local p = unit_point(n) or n.node.position
			pts[#pts + 1] = {p.x, p.z, r}
			g = math.max(g, r)
		end
	end
	while true do
		local cells, out = {}, {}
		for _, q in ipairs(pts) do
			local k = math.floor(q[1] / g) .. "," .. math.floor(q[2] / g)
			local c = cells[k]
			if not c then
				c = {n = 0, x = 0, z = 0}
				cells[k] = c
				out[#out + 1] = c
			end
			c.n, c.x, c.z = c.n + 1, c.x + q[1], c.z + q[2]
			c[#c + 1] = q
		end
		if #out <= FOG_MAX then
			for _, c in ipairs(out) do
				c.x, c.z, c.r = c.x / c.n, c.z / c.n, 0
				for _, q in ipairs(c) do
					c.r = math.max(c.r, math.sqrt((q[1] - c.x) ^ 2 +
							(q[2] - c.z) ^ 2) + q[3])
				end
			end
			return out
		end
		g = g * 2
	end
end

local function fog_path()
	return (O.viewport and O.viewport() and O.viewport().renderPath) or
			(M.play_path and M.play_path())
end

local function fog_params(rp, circles)
	for i = 0, rp:GetNumCommands() - 1 do
		local c = rp:GetCommand(i)
		if c ~= nil and (c.type == magic.CMD_SCENEPASS or
				c.type == magic.CMD_FORWARDLIGHTS) then
			for k = 1, FOG_MAX do
				local f = circles and circles[k]
				if not circles then
					c:RemoveShaderParameter("KitFog" .. (k - 1))
				else
					c:SetShaderParameter("KitFog" .. (k - 1), f and
							magic.Color(f.x, f.z, f.r, 0) or magic.Color(0, 0, 0, 0))
				end
			end
		end
	end
end

magic.SubscribeToEvent("Update", function(_, ev)
	local on = M.fog_on()
	if not on and not FOG.on then
		return
	end
	FOG.t = FOG.t + ev:GetFloat("TimeStep")
	if on == FOG.on and FOG.t < FOG_EVERY then
		return
	end
	FOG.t = 0
	if on ~= FOG.on then
		FOG.on = on
		M.set_fog(on)
		log:info("kit: rts: fog " .. (on and "on" or "off"))
		if not on then
			if FOG.rp then
				fog_params(FOG.rp, nil)
			end
			FOG.rp, FOG.n = nil, -1
			return
		end
	end
	local rp = fog_path()
	if not rp then
		return
	end
	if FOG.rp and FOG.rp ~= rp then
		fog_params(FOG.rp, nil)
	end
	FOG.rp = rp
	local circles = fog_circles()
	fog_params(rp, circles)
	if #circles ~= FOG.n then
		FOG.n = #circles
		log:info("kit: rts: fog: " .. #circles .. " sight circles")
	end
end)

-- For a drive: "event kit_rts_nodes" logs the entities this client has
magic.SubscribeToEvent("command_seq:kit_rts_nodes", function()
	local ids = {}
	for id in pairs(P.nodes) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	log:info("kit: rts: nodes " .. #ids .. ": " .. table.concat(ids, " "))
end)

-- For a drive: "event kit_rts_focus <x> <y> <z>" turns the camera round
-- that point
magic.SubscribeToEvent("command_seq:kit_rts_focus", function(_, data)
	local x, y, z = data:GetString("Param"):match("^(%S+) (%S+) (%S+)")
	if tonumber(z) then
		R.at = {tonumber(x), tonumber(y), tonumber(z)}
	end
end)

-- For a drive: "event kit_rts" logs the camera and the selection
magic.SubscribeToEvent("command_seq:kit_rts", function()
	local a = R.at or {0, 0, 0}
	local ids = {}
	for id in pairs(R.sel) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	log:info(string.format("kit: rts: camera at %.2f,%.2f,%.2f, yaw %.1f, pitch %.1f, " ..
			"distance %.2f, cut %s, steps %d, selected %d: %s", a[1], a[2], a[3],
			R.yaw, R.pitch, R.dist or 0, R.cut and string.format("%.1f", R.cut) or "off",
			M.steps_sent(), #ids, table.concat(ids, " ")))
end)
end
