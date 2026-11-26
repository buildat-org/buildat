-- [KIT_RTS] kit/controls' camera "rts" (kit_plan 4z37zzn): a camera alone (no
-- body: the server steps none, players.lua draws none), an orbit round a
-- point, a depth cut, and the selection of and the orders to kit/unit's
-- entities (kit.cpp's on_order_u).
--
--   The orbit: kit/controls' height m from the point (times the zoom: the
--   wheel, a pinch), angle degrees down, yaw its first turn. The movement keys
--   (WASD; [KIT_RTS_PLAYTEST_1] with Shift three times as fast) or the touch
--   stick pan, and the pointer at the screen's edge in fullscreen or held
--   (the pointer below); a middle drag or one finger drags the ground; a
--   right drag or the arrow keys turn and tilt.
--   The cut (module.lua's set_cut: the voxels; the looks here): what is above
--   it is not drawn. PageUp and PageDown (the editor's nudges) or Shift and
--   the wheel move it a metre, Home takes it off and puts it back; the cut
--   param (> 0) puts it on at the start. With it on the point is 1.5 m under
--   it, so the view goes down with it.
--   The selection: a left click picks a unit of the player's (show.unit's team
--   "" or theirs) under the pointer, a left drag those in its box that move
--   ([KIT_RTS_PLAYTEST_1] show.unit.moves: no building); Shift adds.
--   A right click orders the selection at what is under the pointer: an
--   entity not theirs with a health or a unit, else the point of the ground
--   (the cut's floor). Ctrl and a hotbar key (1-9, 0) keeps the selection as
--   that group, the key alone takes it again. A selected unit has a ring
--   (the selection rectangle's green).
--   A touchscreen: a tap on a unit of theirs selects it, elsewhere orders.
--
-- simplified: no box selection by touch; the looks' cut by their bottom, whole (a tall one
-- below the cut is drawn whole); the order's ground point the voxels' (a
-- heightmap's ground: the point's plane)
return function(K)
local M, E, O, P = K.M, K.E, K.O, K.P
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = K.log
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"
local WEB = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil

local R = {on = false, at = nil, yaw = 0, pitch = 60, cut = nil, sel = {},
	groups = {}, hidden = {}, drag = nil, box = nil, moved = 0}

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
-- [KIT_RTS_PLAYTEST_1] drawn by the scene's debug renderer, after the view's
-- tonemap: the selection rectangle's green whatever the light (an unlit
-- model's under physical's exposure was near black)
local RING = magic.Color(0.3, 1, 0.4)
local UP = magic.Vector3(0, 1, 0)

local function debug_renderer()
	return O.debug or (O.scene and O.scene:GetComponent("DebugRenderer"))
end

local function ring(dbg, n)
	local o, s, p = n.box.off, n.box.size, n.look.position
	local c = magic.Vector3(p.x + o[1], p.y + o[2] - s[2] / 2 + 0.05, p.z + o[3])
	local d = math.max(s[1], s[3]) * 0.7
	for k = 0, 2 do
		dbg:AddCircle(c, UP, d + k * 0.04, RING, 32, false)
	end
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

-- ([KIT_RTS] (4z37zzo) the occlusion buffer off while it is on: the cut is the
-- chunks' shader's, their occluders stay whole, and the rock over a cavern hid
-- the units in it)
local function set_cut(y)
	if (y ~= nil) ~= (R.cut ~= nil) then
		R.occluders = R.occluders or magic.renderer.maxOccluderTriangles
		magic.renderer.maxOccluderTriangles = y and 0 or R.occluders
	end
	R.cut = y
	M.set_cut(y)
	log:info("kit: rts: the cut " .. (y and string.format("at %.1f", y) or "off"))
end

-- ---- [KIT_RTS_PLAYTEST_1] The pointer: the screen's edge pans in
-- fullscreen (the pointer cannot leave it: the native client's F11, its
-- ScreenMode; the web page's Kit Fullscreen) and while held. "Prefer pointer
-- lock" (Kit's section of the game's settings, this client's storage
-- kit_pointer_lock, off by default) holds it in a window too: the app's mouse
-- look (kit.pointer_lock(): Workbench's capture), the system's pointer hidden
-- and Kit's own drawn where its moves take it, the clicks on a Kit button or
-- window there sent to it (the UI's own see none). On the web the browser's
-- Escape lets it go: the app's pause, as a walker's mouse look.
-- simplified: a native client started fullscreen is a window to this until
-- its next mode change; a held click reaches Kit's UI buttons and windows
-- only (a scene list's rows, a field: not)
local EDGE = 3
local PL = {pref = buildat.storage_read ~= nil and
		buildat.storage_read("kit_pointer_lock") == "on", full = false}

-- Whether the pointer is Kit's own drawn one (a drive's kit_rts_pointer
-- too, with the system's still shown)
local function locked()
	return (PL.pref or PL.sim) and not TOUCH and M.camera_mode() == "rts" and
			not E.editing and (PL.sim or not magic.input.mouseVisible)
end

-- Where the pointer is (pixels)
local function mouse_pos()
	if locked() and PL.x then
		return PL.x, PL.y
	end
	local mp = magic.input:GetMousePosition()
	return mp.x, mp.y
end

function M.pointer_lock()
	return PL.pref and not TOUCH and M.camera_mode() == "rts"
end

function M.prefer_pointer_lock(on)
	if on == nil then
		return PL.pref
	end
	PL.pref = on == true
	local ok, err = buildat.storage_write("kit_pointer_lock", PL.pref and "on" or "off")
	log:info("kit: rts: prefer pointer lock " .. (PL.pref and "on" or "off") ..
			(ok and "" or ", not kept: " .. tostring(err)))
end

magic.SubscribeToEvent("ScreenMode", function(_, data)
	PL.full = data:GetBool("Fullscreen")
end)

local function fullscreen()
	return PL.full or (WEB and E.page_fullscreen == true)
end

-- The pan of the pointer at an edge: forward, right (-1...1)
local function edge_pan()
	local on = not TOUCH and (locked() or fullscreen())
	local f, r = 0, 0
	if on then
		local x, y = mouse_pos()
		local w, h = screen()
		r = x <= EDGE and -1 or x >= w - 1 - EDGE and 1 or 0
		f = y <= EDGE and 1 or y >= h - 1 - EDGE and -1 or 0
	end
	local k = f .. "," .. r
	if k ~= PL.edge_said then
		PL.edge_said = k
		log:info("kit: rts: edge pan " .. k .. (on and "" or " (off: a window)"))
	end
	return f, r
end

-- Kit's own pointer drawn while held
local function draw_pointer()
	local on = locked() == true
	if on and not PL.x then
		local w, h = screen()
		PL.x, PL.y = math.floor(w / 2), math.floor(h / 2)
	end
	if on and not PL.cur then
		PL.cur = magic.ui.root:CreateChild("Cursor")
		PL.cur.priority = 1000
		PL.cur.enabled = false
		-- (the style's arrow; its Shapes from SetStyleAuto left it 0x0)
		local img = magic.cache:GetResource("Image", "Textures/UI.png")
		if img then
			PL.cur:DefineShape("Normal", img, magic.IntRect(0, 0, 12, 24),
					magic.IntVector2(0, 0))
		end
	end
	if PL.cur then
		PL.cur.visible = on
		if on then
			local sc = magic.ui.scale
			PL.cur:SetPosition(math.floor(PL.x / sc), math.floor(PL.y / sc))
		end
	end
	if on ~= (PL.said == true) then
		PL.said = on
		log:info("kit: rts: the pointer " .. (on and "held, Kit's drawn" or
				"the system's"))
	end
end

-- ---- The camera (controls.lua's Update calls it in the rts mode)

-- [KIT_RTS] (4z37zzo) a put (a teleport, a team's join onto its pad): the
-- camera's point taken again from where the player is
function M.rts_put()
	R.at = nil
end

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
		-- ([KIT_RTS_PLAYTEST_1] the pointer at the screen's edge pans too)
		local ef, er = edge_pan()
		f, r = math.max(-1, math.min(1, f + ef)), math.max(-1, math.min(1, r + er))
		-- ([KIT_RTS_PLAYTEST_1] Shift: faster)
		local fast = magic.input:GetQualifierDown(magic.QUAL_SHIFT) and 3 or 1
		local v = dist * 0.8 * dt * fast
		if (f ~= 0 or r ~= 0) and fast ~= R.fast_said then
			R.fast_said = fast
			log:info("kit: rts: panning x" .. fast)
		end
		R.at[1] = R.at[1] + (fx * f + rx * r) * v
		R.at[3] = R.at[3] + (fz * f + rz * r) * v
		local t = (M.key_down("nudge_right") and 1 or 0) -
				(M.key_down("nudge_left") and 1 or 0)
		local tl = (M.key_down("nudge_forward") and 1 or 0) -
				(M.key_down("nudge_back") and 1 or 0)
		R.yaw = (R.yaw - t * 90 * dt) % 360
		R.pitch = math.max(15, math.min(89, R.pitch + tl * 45 * dt))
		local mm = magic.input:GetMouseMove()
		-- (not the move of the press's own frame, made before it: a quick
		-- right click turned the view and was no order)
		if R.pressed then
			R.pressed = nil
			mm = {x = 0, y = 0}
		end
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
	local dbg = debug_renderer()
	for id, n in pairs(P.nodes) do
		if R.cut or R.hidden[id] then
			cut_look(id, n)
		end
		if R.sel[id] then
			if not n.look then
				R.sel[id] = nil
			elseif dbg and not R.hidden[id] then
				ring(dbg, n)
			end
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

-- ([KIT_RTS_PLAYTEST_1] the windows below: whether x, y is on one, and a held
-- pointer's click on its button)
local on_window, press_window

local function click_select(x, y, add)
	local id = pick(x, y, own)
	select_ids(id and {id} or {}, add, id and "click on " .. id or "click on none")
end

-- controls.lua's click() in the rts mode: a mouse's left selects, its right
-- orders; a tap selects a unit of theirs, else orders
function M.rts_tap(x, y, left, touch)
	if not x or on_window(x, y) then
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
	R.pressed = true
	if TOUCH or not playing() or ui_utils.clicks_wanted() then
		return
	end
	local x, y = mouse_pos()
	local b = data:GetInt("Button")
	-- (held: the system's pointer is not there, the UI hears nothing)
	local held = locked() and not magic.input.mouseVisible
	if on_window(x, y) then
		if held and b == magic.MOUSEB_LEFT then
			press_window(x, y)
		end
		return
	end
	if M.ui_at and M.ui_at(x, y) then
		if held and b == magic.MOUSEB_LEFT and M.ui_press_at and
				M.ui_press_at(x, y, true) then
			R.ui_down = {x, y}
		end
		return
	end
	if b == magic.MOUSEB_LEFT then
		R.drag = {x0 = x, y0 = y, x = x, y = y}
	elseif b == magic.MOUSEB_RIGHT then
		R.right, R.moved = {x, y}, 0
	end
end)

magic.SubscribeToEvent("MouseMove", function(_, data)
	-- ([KIT_RTS_PLAYTEST_1] Kit's own pointer moved by the moves)
	if locked() and PL.x then
		local w, h = screen()
		PL.x = math.max(0, math.min(w - 1, PL.x + data:GetInt("DX")))
		PL.y = math.max(0, math.min(h - 1, PL.y + data:GetInt("DY")))
	end
	local d = R.drag
	if not d then
		return
	end
	d.x, d.y = mouse_pos()
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
	local x, y = mouse_pos()
	if b == magic.MOUSEB_LEFT and R.ui_down then
		R.ui_down = nil
		M.ui_press_at(x, y, false)
	end
	if b == magic.MOUSEB_LEFT and R.drag then
		local d = R.drag
		R.drag = nil
		if R.box then
			R.box.visible = false
		end
		if not playing() then
			return
		end
		d.x, d.y = x, y
		local x0, y0, x1, y1 = box_rect(d)
		local add = magic.input:GetQualifierDown(magic.QUAL_SHIFT)
		if x1 - x0 + y1 - y0 < 6 * magic.ui.scale then
			return click_select(x, y, add)
		end
		-- ([KIT_RTS_PLAYTEST_1] units only: not what does not move, a
		-- building; a click still selects one)
		local cam, ids = cam_of(), {}
		for id, n in pairs(P.nodes) do
			local p = own(n) and n.show.unit.moves == true and not R.hidden[id] and
					unit_point(n)
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

-- ---- [KIT_RTS_PLAYTEST_1] The windows, in play only (the editor's panels
-- have the screen in edit mode), and the health bars
--   Getting started (top left): its title folds it to itself, each section's
--   title folds the section (the editor's Log's way, [KIT_LOG_PANE]), kept on
--   this client (storage kit_getting_started: "minimized", "folded <title>"
--   lines). Its sections: Keys (the rts camera's, as bound), then
--   kit/controls' help ("Title: line|line||Title: ...").
--   The selection (bottom right): one unit's name, health and what it does
--   (a type's shared state `status`, else "attacking" while its kit/unit has
--   a target, "moving", "idle"); several, how many of each name. Lifted over
--   the game's bottom panels where it would meet them (Deepcore's build bar).
--   The health bars: over each damaged entity with kit/health this client
--   has (both teams'; one the fog hides it does not have), not under the cut.
-- simplified: a line longer than WRAP characters broken at a word; a
-- building is a unit with no movement (show.unit.moves)
local WRAP = 44
local GS = {min = false, folded = {}, buttons = {}, t = 1}
for l in tostring(buildat.storage_read and
		buildat.storage_read("kit_getting_started") or ""):gmatch("[^\n]+") do
	if l == "minimized" then
		GS.min = true
	elseif l:match("^folded .") then
		GS.folded[l:sub(8)] = true
	end
end
local SW = {pos = {}}
local HB = {bars = {}}

local function gs_keep(what)
	local l = {GS.min and "minimized" or "shown"}
	for t in pairs(GS.folded) do
		l[#l + 1] = "folded " .. t
	end
	local ok, err = buildat.storage_write("kit_getting_started", table.concat(l, "\n"))
	log:info("kit: rts: getting started: " .. what ..
			(ok and "" or ", not kept: " .. tostring(err)))
	GS.key = nil
end

local function wrap(line, out)
	while #line > WRAP do
		local sp = line:sub(1, WRAP + 1):match("^.*() ")
		if sp and sp > 10 then
			out[#out + 1] = line:sub(1, sp - 1)
			line = "  " .. line:sub(sp + 1)
		else
			out[#out + 1] = line:sub(1, WRAP)
			line = "  " .. line:sub(WRAP + 1)
		end
	end
	out[#out + 1] = line
end

local function keys_lines()
	local l
	if TOUCH then
		l = {"The stick or a drag: pan", "Two fingers: zoom",
			"A tap on a unit of yours: select it",
			"A tap elsewhere: order the selection there"}
	else
		l = {M.key_text("{key:forward}{key:left}{key:back}{key:right}: pan " ..
				"(Shift: faster)"),
			"Middle drag: pan, the wheel: zoom",
			"Right drag or the arrows: turn, tilt",
			"Left click or drag: select units (Shift: add)",
			"Right click: order (a place, an enemy)",
			"Ctrl+1-9: keep a group, 1-9: select it",
			"PageUp, PageDown, Shift+wheel: cut the rock",
			"Home: the cut off and on"}
		if PL.pref or fullscreen() then
			l[#l + 1] = "The pointer at the screen's edge: pan"
		end
	end
	if E.can_edit then
		l[#l + 1] = M.key_text("{key:edit}: edit")
	end
	if not TOUCH then
		l[#l + 1] = "Esc: menu"
	end
	return l
end

local function sections(par)
	local out = {{title = "Keys", lines = {}}}
	for _, l in ipairs(keys_lines()) do
		wrap(l, out[1].lines)
	end
	for part in (tostring(par.help or "") .. "||"):gmatch("(.-)||") do
		local t, rest = part:match("^%s*([^:|]-)%s*:%s*(.*)$")
		if t and t ~= "" then
			local s = {title = t, lines = {}}
			for l in (rest .. "|"):gmatch("(.-)|") do
				if l ~= "" then
					wrap(l, s.lines)
				end
			end
			out[#out + 1] = s
		end
	end
	return out
end

local function inside(w, x, y)
	local p, s = w.screenPosition, w.size
	return x >= p.x and y >= p.y and x < p.x + s.x and y < p.y + s.y
end

function on_window(x, y)
	local sc = magic.ui.scale
	x, y = x / sc, y / sc
	return (GS.w ~= nil and GS.w.visible and inside(GS.w, x, y)) or
			(SW.w ~= nil and SW.w.visible and inside(SW.w, x, y))
end

function press_window(x, y)
	local sc = magic.ui.scale
	for _, b in ipairs(GS.buttons) do
		if inside(b[1], x / sc, y / sc) then
			return b[2]()
		end
	end
end

local function window(name, halign, valign)
	if not magic.ui.root.defaultStyle then
		magic.ui.root.defaultStyle = K.STYLE
	end
	local w = magic.ui.root:CreateChild("Window")
	w:SetStyleAuto()
	w:SetName(name)
	w:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(6, 6, 6, 6))
	w:SetAlignment(halign, valign)
	w.opacity = 0.9
	-- (under the editor's panels and the menus)
	w.priority = -2
	w.bringToFront = false
	return w
end

local function fold_button(w, label, folded, fn)
	local hb, ht = K.button(w, label, fn)
	hb:SetName("kit getting started " .. label)
	local m = K.text(hb, folded and "▲" or "▼")
	m:SetAlignment(magic.HA_RIGHT, magic.VA_CENTER)
	m:SetPosition(-6, 0)
	ht:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
	ht:SetPosition(6, 0)
	hb.minWidth = hb.minWidth + m.width + 16
	GS.buttons[#GS.buttons + 1] = {hb, fn}
end

local function gs_build(secs)
	if GS.w then
		GS.w:Remove()
	end
	GS.buttons = {}
	local w = window("kit getting started", magic.HA_LEFT, magic.VA_TOP)
	w:SetPosition(8, 8)
	GS.w = w
	fold_button(w, "Getting started", GS.min, function()
		GS.min = not GS.min
		gs_keep(GS.min and "minimized" or "shown")
	end)
	local n = 0
	for _, s in ipairs(GS.min and {} or secs) do
		local f = GS.folded[s.title] == true
		fold_button(w, s.title, f, function()
			GS.folded[s.title] = not f or nil
			gs_keep(s.title .. (f and " shown" or " folded"))
		end)
		if not f then
			for _, l in ipairs(s.lines) do
				K.text(w, l)
				n = n + 1
			end
		end
	end
	log:info("kit: rts: getting started " .. (GS.min and "minimized" or
			#secs .. " sections, " .. n .. " lines shown"))
end

local function cap(s)
	s = tostring(s)
	return #s <= 2 and s:upper() or s:sub(1, 1):upper() .. s:sub(2)
end

local function var(n, key)
	local v = n.node:GetVar("kit:" .. key)
	return not v:IsEmpty() and network.parse_json(v:GetString()) or nil
end

-- What a selected unit does (nil: nothing to say, a building's)
local function doing(id, n, pos)
	local st = var(n, "status")
	if type(st) == "string" and st ~= "" then
		return st
	end
	if (tonumber(var(n, "target")) or 0) ~= 0 then
		return "attacking"
	end
	if n.show.unit.moves ~= true then
		return nil
	end
	local p, q = unit_point(n), SW.pos[id]
	pos[id] = p and {p.x, p.z}
	return p and q and (p.x - q[1]) ^ 2 + (p.z - q[2]) ^ 2 > 0.01 and
			"moving" or "idle"
end

local function sel_lines()
	local ids, pos = {}, {}
	for id in pairs(R.sel) do
		local n = P.nodes[id]
		if n and type(n.show) == "table" and type(n.show.unit) == "table" then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	local l = {}
	if #ids == 1 then
		local n = P.nodes[ids[1]]
		l[1] = cap(n.show.unit.name or "unit")
		local st = n.e and n.e.state
		local hp, mx = st and tonumber(st.hp), st and tonumber(st.max)
		if hp and mx then
			l[#l + 1] = string.format("Health %d/%d", math.ceil(hp), mx)
		end
		local d = doing(ids[1], n, pos)
		if d then
			wrap(d, l)
		end
	elseif #ids > 1 then
		local by, names = {}, {}
		for _, id in ipairs(ids) do
			local nm = cap(P.nodes[id].show.unit.name or "unit")
			if not by[nm] then
				by[nm] = 0
				names[#names + 1] = nm
			end
			by[nm] = by[nm] + 1
		end
		table.sort(names, function(a, b)
			return by[a] > by[b] or by[a] == by[b] and a < b
		end)
		l[1] = #ids .. " selected"
		for _, nm in ipairs(names) do
			l[#l + 1] = by[nm] .. " " .. nm
		end
	end
	SW.pos = pos
	return l
end

local function sw_update(on)
	local l = on and sel_lines() or {}
	local key = table.concat(l, "\n")
	if key ~= SW.key then
		SW.key = key
		if SW.w then
			SW.w:Remove()
			SW.w = nil
		end
		if #l > 0 then
			SW.w = window("kit selection", magic.HA_RIGHT, magic.VA_BOTTOM)
			for _, s in ipairs(l) do
				K.text(SW.w, s)
			end
		end
		log:info("kit: rts: the selection window: " .. (#l > 0 and
				table.concat(l, "; ") or "none"))
	end
	if not SW.w then
		return
	end
	-- Over the game's bottom panels and Kit's own frames it would meet
	local root = magic.ui.root
	local ww, wh = SW.w.width, SW.w.height
	local x0, x1, top = root.width - 8 - ww, root.width - 8, root.height - 8 - wh
	local lift = 8
	for _, game in ipairs({true, false}) do
		local t = M.own_frames_top and M.own_frames_top(x0, x1, top, game)
		if t then
			lift = math.max(lift, root.height - t + 4)
		end
	end
	if SW.w.position.y ~= -lift then
		SW.w:SetPosition(-8, -lift)
		log:info("kit: rts: the selection window " .. lift .. " up")
	end
end

local function bar_color(f)
	return magic.Color(math.min(1, 2 * (1 - f)), math.min(1, 2 * f) * 0.9, 0.15)
end

local function bars_update(on)
	local cam, seen, list = cam_of(), {}, {}
	local sc = magic.ui.scale
	for id, n in pairs(on and cam and P.nodes or {}) do
		local st = type(n.show) == "table" and n.show.health and n.look and
				n.box and not R.hidden[id] and id ~= P.you and n.e and n.e.state
		local hp, mx = st and tonumber(st.hp), st and tonumber(st.max)
		local p = hp and mx and mx > 0 and hp > 0 and hp < mx and unit_point(n)
		if p then
			p.y = p.y + n.box.size[2] / 2 + 0.3
		end
		local sx, sy = on_screen(cam, p or nil)
		if sx then
			local b = HB.bars[id]
			if not b then
				b = {back = magic.ui.root:CreateChild("BorderImage")}
				b.back.blendMode = magic.BLEND_ALPHA
				b.back.color = magic.Color(0, 0, 0, 0.6)
				b.back.priority = -3
				b.fill = b.back:CreateChild("BorderImage")
				b.fill:SetPosition(1, 1)
				HB.bars[id] = b
			end
			local w = math.floor(math.max(24, math.min(60,
					14 * math.max(n.box.size[1], n.box.size[3]))))
			local f = hp / mx
			b.back.visible = true
			b.back:SetFixedSize(w + 2, 5)
			b.back:SetPosition(math.floor(sx / sc - w / 2 - 1), math.floor(sy / sc - 2))
			b.fill:SetFixedSize(math.max(1, math.floor(w * f + 0.5)), 3)
			b.fill.color = bar_color(f)
			seen[id] = true
			list[#list + 1] = id
		end
	end
	for id, b in pairs(HB.bars) do
		if not P.nodes[id] then
			b.back:Remove()
			HB.bars[id] = nil
		elseif not seen[id] then
			b.back.visible = false
		end
	end
	table.sort(list)
	local said = table.concat(list, " ")
	if said ~= HB.said then
		HB.said = said
		log:info("kit: rts: health bars over " .. #list .. (#list > 0 and
				": " .. said or ""))
	end
end

magic.SubscribeToEvent("Update", function(_, ev)
	local on = R.on and M.camera_mode() == "rts" and not E.editing and
			not (M.full_screen and M.full_screen()) and
			not (E.menu and E.menu.held())
	draw_pointer()
	bars_update(on)
	GS.t = GS.t + ev:GetFloat("TimeStep")
	if GS.t < 0.25 and on == GS.on then
		return
	end
	GS.t, GS.on = 0, on
	sw_update(on)
	if on then
		local secs = sections(M.controls_params())
		local key = tostring(GS.min)
		for _, s in ipairs(secs) do
			key = key .. "\n" .. s.title .. tostring(GS.folded[s.title]) ..
					table.concat(s.lines, "\n")
		end
		if key ~= GS.key then
			GS.key = key
			gs_build(secs)
		end
		-- (under the game's own top-left frames: a score, the money)
		local b = M.game_top_left_bottom and
				M.game_top_left_bottom(8, 8 + GS.w.width)
		local y = b and b + 4 or 8
		if GS.w.position.y ~= y then
			GS.w:SetPosition(8, y)
			log:info("kit: rts: getting started at " .. y)
		end
	end
	if GS.w and GS.w.visible ~= on then
		GS.w.visible = on
		log:info("kit: rts: getting started " .. (on and "up" or "down"))
	end
end)

-- For a drive: "event kit_rts_pointer <x> <y>" puts Kit's own pointer there
-- (the system's left shown: a check's runs never hold it), "off" ends that
magic.SubscribeToEvent("command_seq:kit_rts_pointer", function(_, data)
	local x, y = data:GetString("Param"):match("^(%d+) (%d+)$")
	PL.sim = x ~= nil
	PL.x, PL.y = tonumber(x), tonumber(y)
	log:info("kit: rts: a drive's pointer " .. (x and "at " .. x .. ", " .. y or "off"))
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

-- For a drive: "event kit_rts_where <id | x,y,z>..." logs where each unit
-- or point is drawn on the screen (the mouse's pixels), for a real click
-- there; nothing: the player's own units. [KIT_RTS_PLAYTEST_1] "click" first:
-- a left click on the first where it is drawn this frame (one that moves)
magic.SubscribeToEvent("command_seq:kit_rts_where", function(_, data)
	local cam, list = cam_of(), {}
	local w, h = screen()
	local param = data:GetString("Param")
	local clk = param:match("^click ") ~= nil
	for s in param:gsub("^click ", ""):gmatch("%S+") do
		list[#list + 1] = s
	end
	if #list == 0 then
		for id, n in pairs(P.nodes) do
			if id ~= P.you and own(n) then
				list[#list + 1] = tostring(id)
			end
		end
		table.sort(list)
		log:info("kit: rts: own units: " .. #list)
	end
	for _, s in ipairs(list) do
		local x, y, z = s:match("^([^,]+),([^,]+),([^,]+)$")
		local n = not z and P.nodes[tonumber(s)]
		local p = z and magic.Vector3(tonumber(x) or 0, tonumber(y) or 0,
				tonumber(z) or 0) or n and unit_point(n)
		local sx, sy = on_screen(cam, p)
		local what = (z and "point " or "unit ") .. s
		log:info(sx and sx >= 0 and sy >= 0 and sx < w and sy < h and
				string.format("kit: rts: %s on the screen at %d, %d", what, sx, sy) or
				"kit: rts: " .. what .. " not on the screen")
		if clk and sx then
			M.rts_tap(sx, sy, true)
			clk = false
		end
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
