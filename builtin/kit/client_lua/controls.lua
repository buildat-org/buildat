-- Buildat: builtin/kit/client_lua/controls.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT] stage 4h, the players' controls on the client: the body the
-- server moves (Host::controls, builtin/kit/api.h) predicted here with
-- its movement's own step (move.lua's world over this client's voxels),
-- the camera, the pointer and the touch mapping as the app root's
-- kit/controls says. module.lua runs this file with what it shares. An
-- app that hosts Kit with controls:
--   kit.controls{camera = camera_node, paused = function() <menu> end,
--       act = function(x, y, left) <a click the movement does not take:
--         the app's at the pixel x, y, nil: the pointer> end,
--       capture = function(on) <the mouse look, as kit.pointer_free()>,
--       on_ui = function(x, y) <a finger on the app's UI> end,
--       buttons = {{"Menu", fn}...} <the touch bar's, after Kit's>}
--   kit.pointer_ray(x, y) -> origin, direction: the pointer's ray (x, y
--     pixels; nil: the crosshair's middle, or the cursor where it is)
--   kit.pointer_free(): the pointer is a cursor (no mouse look)
--   kit.body_pos() -> the body's feet as drawn (nil before it is put)
--   kit.seated() -> the seat's entity id (nil: none)
--   kit.touch_bar_left() -> where the touch bars begin (UI x; nil: none)
--   kit.viewport(scene, camera) -> a Viewport with Kit's effects
-- The keys (input.lua's actions, the player's to rebind; these the
-- defaults): W A S D (a car: throttle, brake and steering), Space jumps,
-- F leaves a seat (a key bound to use uses what is pointed at, the left
-- click's use without its dig); a gamepad's left stick
-- moves, its right one looks, A jumps, X uses, B leaves a seat; a free
-- cursor turns the view with the right button held, the wheel zooms a
-- chase or top-down camera. A touchscreen
-- (BUILDAT_TOUCH=1, floorplanner's walking): a stick at the lower left
-- walks (a car: steers), a drag elsewhere turns, a tap is the left click
-- at the finger and a finger held still the right; the bar at the lower
-- right: Jump (a car: Gas and Brake), Exit in a seat, the world's actions
-- (held while pressed), the app's.
-- For a drive: "event kit_body" logs the body and the corrections.
return function(K)
local M, E, O, P = K.M, K.E, K.O, K.P
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local voxelworld = require("buildat/module/voxelworld")
local heightmap = require("buildat/module/heightmap")
local replicate = require("buildat/extension/replicate")
local log = K.log
local _, mv_err, MV = buildat.run_script_file("kit/move.lua")
assert(type(MV) == "table", "kit: move.lua: " .. tostring(mv_err))
M.move_lib = MV

-- The controls as the server sent them, the movement's file, the body
-- (its state as predicted, the inputs the server has not answered), the
-- view's turn and the effects
local C = {on = false, ctl = nil, def = nil, src = nil, s = nil, seq = 0,
	put = 0, pending = {}, out = {}, acc = 0, ready = false, prev = nil,
	offset = {0, 0, 0}, yaw = 0, pitch = 0, zoom = 1, acks = 0,
	corrections = 0, signals = {}, shake = 0, fov = nil, fov_tween = nil,
	glitch = 0, glitch_s = 0, flash = 0, flash_color = nil, cam = nil,
	route = nil, use_at = nil, fingers = {}, stick = nil, gas = 0,
	touch_jump = false, bar = nil, bar_kind = nil, classes = {}}
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"
local PI = math.pi

local function params()
	return C.ctl and type(C.ctl.params) == "table" and C.ctl.params or {}
end
local function move()
	return C.ctl and type(C.ctl.move) == "table" and C.ctl.move or nil
end
local function decl()
	local m = move()
	return m and type(m.decl) == "table" and m.decl or {}
end
local function body_decl()
	local b = decl().body
	return type(b) == "table" and b or {}
end
local function rate()
	local m = move()
	local r = m and type(m.params) == "table" and tonumber(m.params.rate) or 60
	return math.max(10, math.min(120, r))
end

-- The camera mode now: a seat's (a vehicle's chase), a signal's, the
-- controls'
local function camera_mode()
	local d = decl()
	if C.ctl and (tonumber(C.ctl.seat) or 0) > 0 and type(d.camera) == "string" then
		return d.camera
	end
	local s = C.signals.camera
	if type(s) == "table" and type(s.mode) == "string" and s.mode ~= "" then
		return s.mode
	end
	return params().camera or "first_person"
end

-- [KIT_TOOLS_1] hands.lua's wheel picks in first person
M.camera_mode = function() return camera_mode() end
-- [KIT_TOOLS_2] A shot's recoil: the view kicked up by deg degrees
function M.kick(deg)
	C.pitch = math.max(-89, C.pitch - (tonumber(deg) or 0))
end

function M.pointer_free()
	local p = params().pointer or "auto"
	if p == "auto" then
		return camera_mode() == "top_down"
	end
	return p == "cursor"
end

function M.seated()
	local s = C.ctl and tonumber(C.ctl.seat) or 0
	return s > 0 and s or nil
end

-- ---- The world: this client's voxels (not loaded: solid), the solid
-- looks (the seat held none), a heightmap's samples
-- ([KIT_VOXEL_FORMAT]) a shape's class is its facing's too: keyed by the
-- id and param bits (Kit's format: the low 24), its boxes the variant's
local function voxel_info(id, v)
	local reg = voxelworld.get_voxel_registry()
	local key = v and v.data % 16777216 or id
	local c = C.classes[key]
	if c == nil then
		local def = reg:get_by_id(id)
		c = false
		if def and def.physically_solid then
			local name = def.name and def.name.block_name or ""
			local mat = name:match("^(.*):[%w_]+$") or name
			local x = C.ctl and type(C.ctl.voxels) == "table" and
					C.ctl.voxels[mat] or {}
			local boxes = nil
			local bl = v and reg:collision_boxes_of(v)
			if type(bl) == "table" then
				boxes = {}
				for _, b in ipairs(bl) do
					for q = 1, 6 do
						boxes[#boxes + 1] = b[q]
					end
				end
			end
			c = MV.voxel_info(name, true, x.friction, x.surface, boxes)
		end
		C.classes[key] = c
	end
	return c or nil
end

local function world()
	local reg = voxelworld.get_voxel_registry()
	local boxes = {}
	local moving_looks = nil
	local seat = M.seated()
	for id, n in pairs(P.nodes) do
		local show = type(n.show) == "table" and n.show or {}
		if type(show.look) == "table" and id ~= seat and not show.player then
			local on = show.look.state and K.value(n, show.look.state) == true
			local links = M.links_of(id, n)
			local r = links and n.rest
			if r then
				-- [KIT_MOVING_OBJECTS] As each step's time has it, from where it rests
				local q = magic.Quaternion(r[4], r[5], r[6], r[7])
				moving_looks = moving_looks or {}
				moving_looks[#moving_looks + 1] = {show.look, on == true, {r[1], r[2], r[3]},
					q:YawAngle(), q:PitchAngle(), q:RollAngle(), links}
			else
				local p = n.node.position
				local q = n.node.rotation
				local tilted = q.x ~= 0 or q.z ~= 0
				local b = MV.look_box(show.look, on, {p.x, p.y, p.z}, q:YawAngle(),
						tilted and q:PitchAngle() or 0, tilted and q:RollAngle() or 0)
				if b then
					boxes[#boxes + 1] = b
				end
			end
		end
	end
	local ground = nil
	local hm = C.ctl and C.ctl.hm
	if type(hm) == "table" and heightmap.terrain then
		local samples = {}
		local function sample(ix, iz)
			-- [KIT_HM_ORIGIN] hm: {sx, sz, the origin's world x, z}
			local ox, oz = hm[3] or 0, hm[4] or 0
			if ix < ox or iz < oz or ix >= ox + hm[1] or iz >= oz + hm[2] then
				return nil
			end
			local k = ix * 65536 + iz
			local h = samples[k]
			if h == nil then
				h = heightmap.height_at(ix, iz)
				samples[k] = h
			end
			return h
		end
		ground = function(x, z)
			return MV.height(sample, x, z)
		end
	end
	return MV.world{cell = function(i, j, k)
		local v = voxelworld.get_static_voxel(magic.Vector3(i, j, k))
		local id = reg:id_of(v)
		if id == 0 then
			return MV.UNKNOWN
		end
		return voxel_info(id, v)
	end, boxes = boxes, turned = C.turned, ground = ground,
		edge = ground and {hm[3] or 0, hm[4] or 0, (hm[3] or 0) + hm[1] - 1,
			(hm[4] or 0) + hm[2] - 1} or nil,
		moving_looks = moving_looks, t = C.draw_t}
end

-- ---- The body
local function copy(t)
	if type(t) ~= "table" then
		return t
	end
	local r = {}
	for k, v in pairs(t) do
		r[k] = copy(v)
	end
	return r
end

local function pos_of(s)
	local p = s and s.pos
	if type(p) ~= "table" then
		return nil
	end
	return {tonumber(p[1]) or 0, tonumber(p[2]) or 0, tonumber(p[3]) or 0}
end

local function step(s, input, w)
	local m = move()
	if not C.def or not m then
		return
	end
	local sub = math.max(1, math.min(8, tonumber(m.params.substeps) or 1))
	local ok, err = pcall(MV.steps, C.def, s, {input}, 1 / rate(), sub, w,
			m.params)
	if not ok and not C.failed then
		C.failed = true
		log:warning("kit: the movement " .. tostring(m.type) .. ": " ..
				tostring(err))
	end
end

-- An input as it is sent, the numbers it is sent with
local function fmt(v, digits)
	return tonumber(string.format("%." .. digits .. "f", v))
end

-- The floor under a put body loaded (a heightmap's built): it steps
local function floor_ready()
	local p = pos_of(C.s)
	if not p then
		return false
	end
	if C.ctl and C.ctl.hm and heightmap.terrain then
		return true
	end
	local v = voxelworld.get_static_voxel(magic.Vector3(p[1], p[2] - 0.6,
			p[3]))
	return voxelworld.get_voxel_registry():id_of(v) ~= 0
end

buildat.sub_packet("kit:body", function(data)
	local b = network.parse_json(data)
	if type(b) ~= "table" or type(b.s) ~= "table" then
		return
	end
	if b.put then
		C.put = tonumber(b.put) or 0
		C.s = b.s
		C.pending = {}
		C.out = {}
		C.seq = math.max(C.seq, tonumber(b.ack) or 0)
		C.prev = pos_of(C.s)
		C.prev_at, C.prev_frame = nil, nil
		C.prev_yaw = tonumber(C.s.yaw)
		C.offset = {0, 0, 0}
		C.acc = 0
		C.ready = false
		C.route, C.use_at = nil, nil
		local p = pos_of(C.s)
		local h = tonumber(body_decl().h) or 1.7
		-- A vehicle's facing; a walker's view kept, or turned the way the
		-- server says, level ([KIT_SPAWNER_PLAYERS]: a spawner's facing)
		local look, facing = tonumber(b.look), ""
		if M.seated() and tonumber(C.s.yaw) then
			C.yaw = tonumber(C.s.yaw)
		elseif look and look == look then
			C.yaw = look % 360
			C.pitch = 0
			facing = " facing " .. C.yaw
		end
		log:info("the server put the player at (" .. p[1] .. ", " ..
				(p[2] + h / 2) .. ", " .. p[3] .. ")" .. facing)
		return
	end
	if not C.s then
		return
	end
	local ack = tonumber(b.ack) or 0
	local before = pos_of(C.s)
	local keep = {}
	for _, q in ipairs(C.pending) do
		if q[1] > ack then
			keep[#keep + 1] = q
		end
	end
	C.pending = keep
	C.s = b.s
	local w = #keep > 0 and world() or nil
	for _, q in ipairs(keep) do
		step(C.s, q[2], w)
	end
	C.acks = C.acks + 1
	local after = pos_of(C.s)
	if before and after then
		local d = {before[1] - after[1], before[2] - after[2],
			before[3] - after[3]}
		local l = math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
		if l > 0.01 then
			C.corrections = C.corrections + 1
			log:info(string.format("kit: the body corrected by %.3f m (%d of %d)",
					l, C.corrections, C.acks))
			-- Drawn where it was, the difference going in a tenth of a second
			if l < 2 then
				for k = 1, 3 do
					C.offset[k] = C.offset[k] + d[k]
				end
			end
			C.prev = after
			C.prev_at, C.prev_frame = nil, nil
		end
	end
end)

-- [KIT_FREE_ROTATION] For a page's drive, which has no look_dir: "event kit_face
-- <yaw> <pitch>"
magic.SubscribeToEvent("command_seq:kit_face", function(_, data)
	local y, p = data:GetString("Param"):match("(%S+) (%S+)")
	C.yaw, C.pitch = tonumber(y) % 360, tonumber(p)
end)
local function log_body()
	local p = pos_of(C.s) or {0, 0, 0}
	log:info(string.format("kit: body at %.2f,%.2f,%.2f, %d acks, %d " ..
			"corrections, %d pending, %d jumps, %d arrivals", p[1], p[2], p[3],
			C.acks, C.corrections, #C.pending, tonumber(C.s and C.s.jumps) or 0,
			tonumber(C.s and C.s.arrived) or 0))
	-- [KIT_WALKER_FRAME] To the tenth of a millimetre, for measuring a deck
	log:info(string.format("kit: feet at %.4f,%.4f,%.4f, frame %s", p[1], p[2],
			p[3], tostring(C.s and C.s.frame or "none")))
	-- [KIT_COMPONENTS] What a vehicle's numbers are compared by
	local v = C.s and type(C.s.vel) == "table" and C.s.vel
	if v then
		log:info(string.format("kit: vehicle speed %.4f,%.4f,%.4f, yaw %.3f", v[1], v[2], v[3],
				tonumber(C.s.yaw) or 0))
	end
	-- [KIT_MOVING_OBJECTS] The time they were stepped at, and as drawn this frame:
	-- the time, the body's feet and each moving object's node
	if C.draw_t then
		local d = C.draw or p
		local parts = {string.format("kit: moving: stepped at %.3f, drawn at %.3f, drawn "
				.. "feet %.4f,%.4f,%.4f, offset of the shared time %.3f", C.last_t or 0,
				C.draw_t, d[1], d[2], d[3], C.clock_off or 0)}
		for _, o in ipairs(C.moving_nodes) do
			local n = replicate.main_scene:GetNode(o.node)
			if n then
				local a, q = n.position, n.rotation
				parts[#parts + 1] = string.format("%d node %.4f,%.4f,%.4f turn "
						.. "%.5f,%.5f,%.5f,%.5f", o.id, a.x, a.y, a.z, q.w, q.x, q.y, q.z)
			end
		end
		log:info(table.concat(parts, "; "))
	end
end
magic.SubscribeToEvent("command_seq:kit_body", log_body)
-- [KIT_COMPONENTS] For a drive: "event kit_body_in <ms>", the same that much later, a
-- key still held (a page's held key is one step of its sequence)
local body_logs = {}
magic.SubscribeToEvent("command_seq:kit_body_in", function(_, data)
	body_logs[#body_logs + 1] = buildat.get_time_us() + tonumber(data:GetString("Param")) * 1000
end)

-- ---- The controls: the movement's file, the signals as they come
local function signal(key, v)
	local par = params()
	if key == "shake" then
		local a = tonumber(v.amount) or 0
		-- [KIT_FEEDBACK_EFFECTS] From a place: weaker with the distance
		local far = tonumber(par.shake_far) or 0
		if type(v.at) == "table" and far > 0 and O.camera then
			local p = O.camera.worldPosition
			local dx, dy, dz = p.x - (tonumber(v.at[1]) or 0), p.y -
					(tonumber(v.at[2]) or 0), p.z - (tonumber(v.at[3]) or 0)
			local near = tonumber(par.shake_near) or 0
			local d = math.sqrt(dx * dx + dy * dy + dz * dz)
			a = a * math.max(0, math.min(1, (far - d) / math.max(far - near, 1e-3)))
			log:info(string.format("kit: camera shake from %.1f m", d))
		end
		C.shake = math.max(C.shake, a)
		log:info("kit: camera shake " .. tostring(a))
	elseif key == "fov" then
		local to = tonumber(v.value) or 0
		if to <= 0 then
			to = tonumber(par.fov) or 75
		end
		C.fov_tween = {from = C.fov or tonumber(par.fov) or 75, to = to,
			t = 0, len = math.max(0, tonumber(v.time) or tonumber(par.fov_time) or
				0.3)}
		log:info("kit: camera fov " .. to .. " over " .. C.fov_tween.len .. " s")
	elseif key == "glitch" then
		C.glitch_s = math.max(0, tonumber(v.seconds) or 0)
		C.glitch = C.glitch_s
		log:info("kit: camera glitch " .. C.glitch_s .. " s")
	elseif key == "tint" then
		C.flash, C.flash_color = 1, tostring(v.color or "#ffffff")
		log:info("kit: camera tint " .. C.flash_color)
	elseif key == "camera" then
		log:info("kit: camera mode " .. camera_mode())
	end
end

-- [KIT_FREE_PREFAB] The controls' free objects ({model, x, y, z, yaw, pitch, roll,
-- id, node, links}...) and each model's boxes in its object's frame, as the server's
-- body meets them. [KIT_MOVING_OBJECTS] C.links by entity: what moves each one that
-- moves; C.moving_nodes their voxel nodes
local object_boxes = {}
C.links, C.moving_nodes = {}, {}
local function update_turned()
	local l = {}
	local list = C.ctl and C.ctl.objects
	local links, nodes = {}, {}
	C.turned_by = {}
	for _, o in ipairs(type(list) == "table" and list or {}) do
		local li = type(o[10]) == "table" and #o[10] > 0 and o[10] or nil
		if li then
			links[o[8]] = li
			nodes[#nodes + 1] = {id = o[8], node = o[9], links = li}
		end
		if object_boxes[o[1]] then
			l[#l + 1] = {o[2], o[3], o[4], o[5], o[6], o[7], object_boxes[o[1]], o[8], li}
		end
	end
	-- (what was moved and is no more goes back in M.moving_tick)
	C.gone_nodes = C.gone_nodes or {}
	for _, o in ipairs(C.moving_nodes) do
		C.gone_nodes[o.node] = o
	end
	for _, o in ipairs(nodes) do
		local was = C.gone_nodes[o.node]
		if was then
			o.rest, o.sx, o.sy, o.sz, o.sw, o.sa, o.sb, o.sc = was.rest, was.sx, was.sy, was.sz,
					was.sw, was.sa, was.sb, was.sc
			C.gone_nodes[o.node] = nil
		end
	end
	C.links, C.moving_nodes = links, nodes
	C.turned = MV.turned(l)
	for _, t in ipairs(C.turned) do
		C.turned_by[t.id] = t
	end
	C.pose_world = MV.world{turned = C.turned}
end

-- ---- [KIT_MOVING_OBJECTS] The shared time: the server's now and then ("kit:clock",
-- ms and its rate), the network's delay in it held low (each client draws a little
-- behind the server, by its own delay; what matters is that a step and the server's
-- stepping of it share its stamp).
-- simplified: no round trip measured: two clients differ by the difference of their
-- delays, a matter of how a deck's phase looks from outside
buildat.sub_packet("kit:clock", function(data)
	local t, rate = data:match("^(%S+) (%S+)")
	t, rate = tonumber(t), tonumber(rate)
	if not t or not rate then
		return
	end
	local s = t / 1000 - buildat.get_time_us() / 1e6 * rate
	local off = C.clock_off
	if not off or rate ~= C.clock_rate or math.abs(s - off) > 0.5 then
		C.clock_off, C.clock_rate = s, rate
		log:info(string.format("kit: the shared time is %.3f", t / 1000))
	elseif s > off then
		C.clock_off = off + (s - off) * 0.5
	else
		C.clock_off = off + (s - off) * 0.05
	end
end)

local function shared_time()
	return (C.clock_off or 0) + buildat.get_time_us() / 1e6 * (C.clock_rate or 1)
end

-- What moves an entity's node: its own object's links, those of what it is under, or
-- a body's deck ("kit_frame", kit.cpp's place_player); nil: nothing
function M.links_of(id, n)
	if not next(C.links) then
		return nil
	end
	if C.links[id] then
		return C.links[id]
	end
	local v = n.node:GetVar("kit_frame")
	local pid = v:IsEmpty() and 0 or v:GetInt()
	if pid == 0 then
		v = n.node:GetVar("kit_parent")
		pid = v:IsEmpty() and 0 or v:GetInt()
	end
	for _ = 1, 16 do
		if pid == 0 then
			return nil
		end
		if C.links[pid] then
			return C.links[pid]
		end
		local pn = P.nodes[pid]
		if not pn then
			return nil
		end
		v = pn.node:GetVar("kit_parent")
		pid = v:IsEmpty() and 0 or v:GetInt()
	end
	return nil
end

-- A link's change at the draw's time, once a frame
local function link_now(l)
	if l.now_t ~= C.draw_t then
		local xt, yt, zt, _, wp, wy, wr = MV.link_at(l, C.draw_t)
		if not l.q0 then
			l.q0 = magic.Quaternion(tonumber(l[5]) or 0, tonumber(l[4]) or 0, tonumber(l[6]) or 0)
			local q = l.q0
			l.q0i = magic.Quaternion(q.w, -q.x, -q.y, -q.z)
		end
		l.now_t = C.draw_t
		l.xt, l.yt, l.zt = xt, yt, zt
		l.d = l.q0 * magic.Quaternion(wp, wy, wr) * l.q0i
	end
	return l
end

-- A place at rest, as the links have it now: a Vector3
local function moved_point(links, x, y, z)
	local p = magic.Vector3(x, y, z)
	for _, l in ipairs(links) do
		link_now(l)
		p = l.d * magic.Vector3(p.x - l[1], p.y - l[2], p.z - l[3]) +
				magic.Vector3(l.xt, l.yt, l.zt)
	end
	return p
end

-- A node (rec: what is kept of it: n, or a row's) where its links have it now. What
-- it rests at is what the server last set (a value not the one written here): the
-- server's nodes stay at rest, and nothing but this moves them.
-- simplified: a node the server moves during play under a moving object (a kit/mover
-- on a deck) comes through the client's SmoothedTransform, whose blend reads as a new
-- rest here. The way out is a rest in a variable as a body has it, or a client that
-- can take the smoothing off a node (no binding for it yet)
local function place_moving(rec, node, links)
	local p, q = node.position, node.rotation
	if not rec.rest or p.x ~= rec.sx or p.y ~= rec.sy or p.z ~= rec.sz or q.w ~= rec.sw or
			q.x ~= rec.sa or q.y ~= rec.sb or q.z ~= rec.sc then
		rec.rest = {p.x, p.y, p.z, q.w, q.x, q.y, q.z}
	end
	local r = rec.rest
	local at = moved_point(links, r[1], r[2], r[3])
	local turn = magic.Quaternion(r[4], r[5], r[6], r[7])
	for _, l in ipairs(links) do
		turn = l.d * turn
	end
	node.position = at
	node.rotation = turn
	p, q = node.position, node.rotation
	rec.sx, rec.sy, rec.sz = p.x, p.y, p.z
	rec.sw, rec.sa, rec.sb, rec.sc = q.w, q.x, q.y, q.z
end

-- No longer moved: at rest, unless the server has since set it
local function place_rest(rec, node)
	local p, q = node.position, node.rotation
	local r = rec.rest
	if p.x == rec.sx and p.y == rec.sy and p.z == rec.sz and q.w == rec.sw and
			q.x == rec.sa and q.y == rec.sb and q.z == rec.sc then
		node.position = magic.Vector3(r[1], r[2], r[3])
		node.rotation = magic.Quaternion(r[4], r[5], r[6], r[7])
	end
	rec.rest = nil
end

-- Each frame, first: the time everything is drawn at; each moved node there
function M.moving_tick()
	if not next(C.links) and not next(C.gone_nodes or {}) and not C.were_moving then
		C.draw_t = nil
		return
	end
	local any = next(C.links) ~= nil
	C.draw_t = any and shared_time() or nil
	C.were_moving = any
	if any then
		C.pose_world:pose_at(C.draw_t)
	end
	for id, n in pairs(P.nodes) do
		local links = M.links_of(id, n)
		-- A body on a deck: its rest in "kit_rest" (kit.cpp's place_player)
		local fv = links and n.node:GetVar("kit_frame")
		if fv and not fv:IsEmpty() and fv:GetInt() ~= 0 then
			local rs = n.node:GetVar("kit_rest"):GetString()
			if rs ~= n.body_rest_s then
				local x, y, z = rs:match("^(%S+) (%S+) (%S+)$")
				n.body_rest_s = rs
				n.body_rest = x and magic.Vector3(tonumber(x), tonumber(y), tonumber(z)) or nil
			end
			if n.body_rest then
				local r = n.body_rest
				n.node.position = moved_point(links, r.x, r.y, r.z)
			end
		else
			n.body_rest, n.body_rest_s = nil, nil
			if links then
				place_moving(n, n.node, links)
			elseif n.rest then
				place_rest(n, n.node)
			end
		end
	end
	for _, o in ipairs(C.moving_nodes) do
		local node = replicate.main_scene:GetNode(o.node)
		if node then
			place_moving(o, node, o.links)
		end
	end
	for id, o in pairs(C.gone_nodes or {}) do
		local node = replicate.main_scene:GetNode(id)
		if node and o.rest then
			place_rest(o, node)
		end
		C.gone_nodes[id] = nil
	end
end

-- For players.lua: a body's place at rest, what a moved point is as drawn; the time
function M.rest_position(n)
	return n.body_rest or n.node.position
end
function M.moved_body(id, n, at)
	local links = M.links_of(id, n)
	return links and C.draw_t and moved_point(links, at.x, at.y, at.z) or at
end
function M.draw_time()
	return C.draw_t
end

buildat.sub_packet("kit:object_boxes", function(data)
	local name, list = data:match("^(%S+) (.*)$")
	local b = list and network.parse_json(list)
	if type(b) == "table" then
		object_boxes[name] = b
		update_turned()
	end
end)

buildat.sub_packet("kit:controls", function(data)
	local c = network.parse_json(data)
	if type(c) ~= "table" then
		return
	end
	local had = C.ctl
	local was_free = M.pointer_free()
	C.ctl = c
	C.on = true
	C.classes = {}
	update_turned()
	local m = move()
	if m and type(m.src) == "string" and (m.src ~= C.src or m.type ~= C.type) then
		local ok, def = buildat.eval(m.src, tostring(m.type) .. ".movement")
		if ok and type(def) == "table" and type(def.step) == "function" then
			C.def, C.src, C.type, C.failed = def, m.src, m.type, false
			log:info("kit: the movement " .. tostring(m.type))
		else
			C.def, C.src, C.type = nil, nil, nil
			log:warning("kit: the movement " .. tostring(m.type) ..
					" does not load: " .. tostring(def))
		end
	elseif not m then
		C.def, C.src, C.type = nil, nil, nil
	end
	-- The signals: each counted, the new ones played
	local sig = type(c.signals) == "table" and c.signals or {}
	for k, v in pairs(sig) do
		if type(v) == "table" then
			local seen = C.signals[k]
			if had and (not seen or seen.n ~= v.n) then
				C.signals[k] = v
				signal(k, v)
			end
			C.signals[k] = v
		end
	end
	if was_free ~= M.pointer_free() and O.capture then
		O.capture(true)
	end
	log:info("kit: controls: camera " .. camera_mode() .. ", pointer " ..
			(M.pointer_free() and "cursor" or "crosshair") .. ", movement " ..
			tostring(m and m.type or "none") .. (M.seated() and ", seat " ..
			M.seated() or ""))
end)

-- ---- Effects: Kit's render path (kit_effects.xml), on a viewport of
-- the play view; off while none is on. [KIT_LIGHTING] On the lighting's
-- path (environment.lua's: physical's HDR), made again when it changes
function M.viewport(scene, cam)
	local vp = magic.Viewport:new(scene, cam)
	M.lit_viewport(vp, "play", function(rp)
		rp:Append(magic.cache:GetResource("XMLFile", "kit/kit_effects.xml"))
		rp:SetEnabled("KitEffects", false)
		C.rp, C.rp_on = rp, false
	end)
	return vp
end

local function hex_color(s)
	local r, g, b, a = tostring(s or ""):match(
			"^#(%x%x)(%x%x)(%x%x)(%x?%x?)$")
	if not r then
		return nil
	end
	return tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255,
			a ~= "" and tonumber(a, 16) / 255 or 1
end

local function effects(dt)
	if not C.rp then
		return
	end
	local par = params()
	C.flash = math.max(0, C.flash - dt)
	C.glitch = math.max(0, C.glitch - dt)
	local tr, tg, tb, ta = hex_color(par.tint)
	ta = (ta or 0) * (tonumber(par.tint_amount) or 0)
	if C.flash > 0 then
		local fr, fg, fb = hex_color(C.flash_color)
		if fr then
			tr, tg, tb, ta = fr, fg, fb, math.max(ta, 0.6 * C.flash)
		end
	end
	local vig = tonumber(par.vignette) or 0
	local blur = tonumber(par.blur) or 0
	local glitch = math.max(tonumber(par.glitch) or 0, C.glitch_s > 0 and
			C.glitch / C.glitch_s or 0)
	local on = ta > 0.001 or vig > 0.001 or blur > 0.001 or glitch > 0.001
	if on ~= C.rp_on then
		C.rp_on = on
		C.rp:SetEnabled("KitEffects", on)
		log:info("kit: effects " .. (on and "on" or "off"))
	end
	if on then
		C.rp:SetShaderParameter("KitTint", magic.Color(tr or 0, tg or 0,
				tb or 0, ta))
		C.rp:SetShaderParameter("KitFx", magic.Color(vig, blur, glitch,
				buildat.get_time_us() % 100000000 / 1000000))
	end
end

-- ---- Input: the keys (input.lua's actions), the stick, the touch bar's,
-- the gamepad's
local key = M.key_down

local function walking()
	if O.walking then
		return O.walking()
	end
	return not E.editing or M.view() == "walk"
end

local function paused()
	return (O.paused and O.paused()) or ui_utils.mouse_look_paused()
end

-- [KIT_WALKER_FRAME] kit/controls' camera_frame: "object" turns the view with the
-- deck under the body: C.tilt the turn from level to the deck's up, eased; nil
-- level (the world's). Only its tilt: the mouse's yaw stays the world's heading on
-- a static object, so nothing jumps on entering; [KIT_MOVING_OBJECTS] one turning
-- round its own up adds that to C.yaw.
local function update_tilt(dt)
	local nx, ny, nz = 0, 1, 0
	local heading = nil
	if params().camera_frame == "object" and C.s and C.s.frame then
		for _, o in ipairs(C.turned or {}) do
			if o.id == C.s.frame then
				nx, ny, nz = o.R[2], o.R[5], o.R[8]
				-- [KIT_MOVING_OBJECTS] An object turning under the body: the view with it
				if o.links then
					heading = {o.id, math.atan2(o.R[3], o.R[9]) * 180 / PI}
				end
			end
		end
	end
	if heading and C.heading and C.heading[1] == heading[1] then
		C.yaw = C.yaw + ((heading[2] - C.heading[2] + 180) % 360 - 180)
	end
	C.heading = heading
	local u = C.up or {0, 1, 0}
	local k = 1 - math.exp(-dt / 0.15)
	u = {u[1] + (nx - u[1]) * k, u[2] + (ny - u[2]) * k, u[3] + (nz - u[3]) * k}
	local l = math.sqrt(u[1] * u[1] + u[2] * u[2] + u[3] * u[3])
	u = {u[1] / l, u[2] / l, u[3] / l}
	C.up = u
	if u[2] > 0.9999999 then
		C.tilt = nil
		return
	end
	-- Round up x u, the half angle's: the shortest way from up to u
	local w, x, z = 1 + u[2], u[3], -u[1]
	local q = math.sqrt(w * w + x * x + z * z)
	C.tilt = magic.Quaternion(w / q, x / q, 0, z / q)
end

-- The heading the view looks along in the world: its yaw, or under a tilt where
-- that forward goes, level. move.lua's W:walk_on takes it back onto the deck
local function view_yaw()
	if not C.tilt then
		return C.yaw
	end
	local a = C.yaw * PI / 180
	local f = C.tilt * magic.Vector3(math.sin(a), 0, math.cos(a))
	return math.atan2(f.x, f.z) * 180 / PI
end

-- The input yaw: the view's (a top-down camera's own)
local function input_yaw()
	if camera_mode() == "top_down" then
		return tonumber(params().yaw) or 0
	end
	return view_yaw()
end

-- [KIT_CTF] Whether this player is dead and waiting to respawn (their
-- kit/health's shared "waiting"): they stay where they fell (the server
-- steps them so too) and Kit's HUD says so
function M.waiting()
	local me = P.nodes[P.you]
	local v = me and me.node:GetVar("kit:waiting")
	return v ~= nil and not v:IsEmpty() and v:GetString() == "true"
end

local go_next = nil -- a target to send in the next step
local function gather()
	local f, r, jump = 0, 0, 0
	if walking() and not paused() and not M.waiting() and
			not (ui_utils.clicks_wanted() and
			not M.looking()) then
		if key("forward") then f = f + 1 end
		if key("back") then f = f - 1 end
		if key("right") then r = r + 1 end
		if key("left") then r = r - 1 end
		if key("jump") or M.key_press("jump") then
			jump = 1
		end
		-- The gamepad's left stick (its y down)
		r = r + M.pad_axis(0)
		f = f - M.pad_axis(1)
		if C.stick then
			r = r + C.stick.r
			if (decl().touch or "stick") ~= "drive" then
				f = f + C.stick.f
			end
		end
		f = f + C.gas
		if C.touch_jump then
			jump = 1
		end
	end
	f = math.max(-1, math.min(1, f))
	r = math.max(-1, math.min(1, r))
	local i = {f = fmt(f, 3), r = fmt(r, 3), yaw = fmt(input_yaw() % 360, 2),
		jump = jump, go = 0, tx = 0, ty = 0, tz = 0}
	if go_next then
		i.go, i.tx, i.ty, i.tz = 1, fmt(go_next[1], 2), fmt(go_next[2], 2),
				fmt(go_next[3], 2)
		go_next = nil
	end
	return i
end

-- ---- Click to move: a click on the ground goes there, on an object
-- walks to it and uses it ([KIT] stage 4h); a simple path when the
-- movement plans one (its plan(w, from, to, p))
local function clicks_move()
	return decl().click == true
end
M.clicks_move = clicks_move

local function go_to(target)
	local m = move()
	local w = world()
	C.route = nil
	if C.def and type(C.def.plan) == "function" and m and
			m.params.path == "simple" then
		local ok, route = pcall(C.def.plan, w, pos_of(C.s), target, m.params)
		if ok and type(route) == "table" and #route > 0 then
			C.route = route
			log:info("kit: a path of " .. #route .. " steps")
		end
	end
	if C.route then
		go_next = table.remove(C.route, 1)
	else
		go_next = target
	end
	C.going = true
	log:info(string.format("kit: going to %.2f,%.2f,%.2f", target[1],
			target[2], target[3]))
end

-- A click the movement takes: true
local function move_click(x, y, left)
	if not left or not clicks_move() or not C.s then
		return false
	end
	local o, d = M.pointer_ray(x, y)
	local id, et = M.pick_entity(o, d, 64)
	local w = world()
	local t = w:ray(o.x, o.y, o.z, d.x, d.y, d.z, 128)
	if id and (not t or et <= t + 0.05) then
		local p = P.nodes[id].node.position
		C.use_at = {id = id, x = p.x, z = p.z}
		go_to({p.x, p.y - 0.5, p.z})
		return true
	end
	if not t then
		return false
	end
	C.use_at = nil
	go_to({o.x + d.x * t, o.y + d.y * t, o.z + d.z * t})
	return true
end

-- The next leg, the use on arrival
local function route_tick()
	if not C.s or C.s.target or go_next then
		return
	end
	if C.route and #C.route > 0 then
		go_next = table.remove(C.route, 1)
		return
	end
	C.route = nil
	if C.going then
		-- There, or given up (the body's arrivals say which)
		C.going = false
		local p = pos_of(C.s) or {0, 0, 0}
		log:info(string.format("kit: stopped at %.2f,%.2f,%.2f", p[1], p[2],
				p[3]))
	end
	if C.use_at then
		local p = pos_of(C.s)
		local dx, dz = p[1] - C.use_at.x, p[3] - C.use_at.z
		if dx * dx + dz * dz < 4 * 4 then
			log:info("kit: arrived at " .. C.use_at.id)
			M.use(C.use_at.id)
		end
		C.use_at = nil
	end
end

-- The app's click, or the movement's
local function click(x, y, left)
	-- [KIT_SPECTATE] the clicks pick whom to watch (players.lua)
	if M.spectate_click(left) then
		return
	end
	if move_click(x, y, left) then
		return
	end
	if O.act then
		O.act(x, y, left)
	end
end

magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	if not C.on or TOUCH or E.editing or paused() or ui_utils.clicks_wanted() or
			not O.act then
		return
	end
	local b = data:GetInt("Button")
	if b ~= magic.MOUSEB_LEFT and b ~= magic.MOUSEB_RIGHT then
		return
	end
	local x, y = nil, nil
	if M.pointer_free() then
		local mp = magic.input:GetMousePosition()
		x, y = mp.x, mp.y
		-- [KIT_UI_COMPONENTS] a UI button's, not the world's
		if M.ui_at and M.ui_at(x, y) then
			return
		end
	end
	click(x, y, b == magic.MOUSEB_LEFT)
end)

magic.SubscribeToEvent("MouseWheel", function(_, data)
	if not C.on or E.editing or paused() or camera_mode() == "first_person" then
		return
	end
	C.zoom = math.max(0.3, math.min(3, C.zoom * (data:GetInt("Wheel") > 0 and
			0.9 or 1 / 0.9)))
end)

local function exit_seat()
	if M.seated() then
		log:info("kit: leaving the seat")
		buildat.send_packet("kit:exit", "")
	end
end

-- [KIT_INPUT_ACTIONS] "use": the object pointed at used (a left click's
-- use, never its dig), within the app's reach past the camera's distance
local function use_pointed()
	if not C.s or E.editing then
		return
	end
	local o, d = M.pointer_ray()
	local b = M.body_pos()
	local far = b and math.sqrt((o.x - b.x) ^ 2 + (o.y - b.y - 1.5) ^ 2 +
			(o.z - b.z) ^ 2) or 0
	local t = M.play_target(o, d, 6 + (far > 1 and far or 0))
	local l = t and t.left
	if l and l.kind == "use" then
		M.use(l.id)
	elseif l and l.kind == "refused" then
		M.refused(l.why)
	end
end
M.on_pad_press("exit", function() if C.on then exit_seat() end end)
M.on_pad_press("use", function() if C.on then use_pointed() end end)

magic.SubscribeToEvent("KeyDown", function(_, data)
	if not C.on or paused() then
		return
	end
	local f = magic.ui.focusElement
	if f ~= nil and f:GetTypeName() == "LineEdit" then
		return
	end
	local k = data:GetInt("Key")
	if M.key("exit", k) then
		exit_seat()
	elseif M.key("use", k) and not data:GetBool("Repeat") then
		use_pointed()
	end
end)

-- ---- The pointer
local function screen()
	local sc = magic.ui.scale
	return magic.ui.root.width * sc, magic.ui.root.height * sc
end

function M.pointer_ray(x, y)
	local node = O.camera
	local cam = node:GetComponent("Camera")
	local w, h = screen()
	if not x and C.aim then
		local sp = cam:WorldToScreenPoint(C.aim)
		x, y = sp.x * w, sp.y * h
	elseif not x then
		if M.pointer_free() and not TOUCH then
			local mp = magic.input:GetMousePosition()
			x, y = mp.x, mp.y
		else
			x, y = w / 2, h / 2
		end
	end
	return M.screen_ray(x, y, node, cam)
end

function M.body_pos()
	return C.draw and magic.Vector3(C.draw[1], C.draw[2], C.draw[3]) or nil
end

-- ---- The touchscreen ([FP_TOUCH] 3, floorplanner's walking)
local function touch_kind()
	if M.seated() then
		return decl().touch or "drive"
	end
	return decl().touch or "stick"
end

local function on_ui(x, y)
	local sc = magic.ui.scale
	for _, b in ipairs({C.bar, C.abar}) do
		if b.visible then
			local p, s = b.screenPosition, b.size
			if x / sc >= p.x and y / sc >= p.y and x / sc < p.x + s.x and
					y / sc < p.y + s.y then
				return true
			end
		end
	end
	return paused() or ui_utils.clicks_wanted() or (O.on_ui and O.on_ui(x, y))
			or (E.editing and M.over_ui(x, y)) or (M.ui_at and M.ui_at(x, y))
end

-- A row of buttons {label, pressed or nil, released} at the lower right,
-- y up from the bottom
local function button_row(list, y)
	local bar = magic.ui.root:CreateChild("Window")
	bar.defaultStyle = K.STYLE
	bar:SetStyleAuto()
	bar:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(6, 6, 6, 6))
	bar:SetAlignment(magic.HA_RIGHT, magic.VA_BOTTOM)
	bar:SetPosition(-8, -y)
	bar.opacity = 0.92
	bar.visible = #list > 0
	for _, b in ipairs(list) do
		local btn = bar:CreateChild("Button")
		btn:SetStyleAuto()
		btn.minHeight = 24
		local t = btn:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(b[1])
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		btn.minWidth = t.width + 16
		if b[2] then
			magic.SubscribeToEvent(btn, "Pressed", b[2])
		end
		magic.SubscribeToEvent(btn, "Released", b[3])
	end
	return bar
end

local function labels(list)
	local l = {}
	for i, b in ipairs(list) do
		l[i] = b[1]
	end
	return table.concat(l, ", ")
end

local function make_bar()
	local kind = touch_kind() .. (M.seated() and ":seat" or "") .. ":" ..
			M.keys_version()
	if C.bar and C.bar_kind == kind then
		return
	end
	if C.bar then
		C.bar:Remove()
		C.abar:Remove()
	end
	C.bar_kind = kind
	local list = {}
	if touch_kind() == "drive" then
		list[#list + 1] = {"Brake", function() C.gas = -1 end,
			function() C.gas = 0 end}
		list[#list + 1] = {"Gas", function() C.gas = 1 end,
			function() C.gas = 0 end}
	elseif touch_kind() ~= "tap" then
		list[#list + 1] = {"Jump", nil, function() C.touch_jump = true end}
	end
	if M.seated() then
		list[#list + 1] = {"Exit", nil, exit_seat}
	end
	for _, b in ipairs(O.buttons or {}) do
		list[#list + 1] = {b[1], nil, b[2]}
	end
	-- [KIT_INPUT_ACTIONS] the world's actions, held while pressed: a row
	-- of their own above (the bar not reaching into the app's help line)
	local acts = {}
	for _, a in ipairs(M.world_actions()) do
		local name = a.name
		acts[#acts + 1] = {a.label ~= "" and a.label or name,
			function() M.press_action(name, true) end,
			function() M.press_action(name, false) end}
	end
	C.bar = button_row(list, 8)
	C.abar = button_row(acts, 8 + C.bar.height + 6)
	log:info("kit: the touch bar: " .. labels(list) .. "; the world's: " ..
			labels(acts))
end

-- [KIT_UI_COMPONENTS] Their top (UI y; nil: none): a UI component at the
-- bottom stays over them
function M.touch_bar_top()
	local y = nil
	for _, b in ipairs({C.bar, C.abar}) do
		if b and b.visible then
			y = math.min(y or b.screenPosition.y, b.screenPosition.y)
		end
	end
	return y
end

-- [KIT_TOUCH_HELP_JUMP] Where the touch bars begin at the lower right
-- (UI units), the leftmost of the two shown; nil with none: an app's help
-- line ends before it
function M.touch_bar_left()
	local x = nil
	for _, b in ipairs({C.bar, C.abar}) do
		if b and b.visible then
			x = math.min(x or b.screenPosition.x, b.screenPosition.x)
		end
	end
	return x
end

if TOUCH then
	magic.SubscribeToEvent("TouchBegin", function(_, data)
		if not C.on then
			return
		end
		local id, x, y = data:GetInt("TouchID"), data:GetInt("X"),
				data:GetInt("Y")
		local f = {x = x, y = y, x0 = x, y0 = y, t0 = buildat.get_time_us(),
			ui = on_ui(x, y)}
		C.fingers[id] = f
		if f.ui or (E.editing and M.view() ~= "walk") then
			f.ui = true
			return
		end
		local w, h = screen()
		if not C.stick and touch_kind() ~= "tap" and x < w * 0.45 and
				y > h * 0.55 then
			f.stick = true
			C.stick = {f = 0, r = 0}
		end
	end)
	magic.SubscribeToEvent("TouchMove", function(_, data)
		local f = C.fingers[data:GetInt("TouchID")]
		if not f or f.ui then
			return
		end
		local x, y = data:GetInt("X"), data:GetInt("Y")
		f.x, f.y = x, y
		if math.abs(x - f.x0) + math.abs(y - f.y0) > 8 * magic.ui.scale then
			f.moved = true
		end
		local w, h = screen()
		if f.stick then
			-- A tenth of the screen's short side is full speed
			local r = math.min(w, h) * 0.1
			C.stick.r = math.max(-1, math.min(1, (x - f.x0) / r))
			C.stick.f = math.max(-1, math.min(1, -(y - f.y0) / r))
			return
		end
		-- The mouse sensitivity's, at half of 0.2 (floorplanner's)
		if camera_mode() ~= "top_down" then
			C.yaw = C.yaw + data:GetInt("DX") * 0.1
			C.pitch = math.max(-89, math.min(89, C.pitch + data:GetInt("DY") * 0.1))
		end
	end)
	magic.SubscribeToEvent("TouchEnd", function(_, data)
		local id = data:GetInt("TouchID")
		local f = C.fingers[id]
		C.fingers[id] = nil
		if not f then
			return
		end
		if f.stick then
			C.stick = nil
		end
		-- A tap: the left click at the finger, in play (Kit's editor takes
		-- its own)
		if not f.ui and not f.stick and not f.moved and not f.held and
				not E.editing and buildat.get_time_us() - f.t0 < 500000 then
			click(f.x, f.y, true)
		end
	end)
end

-- The finger that points (a touchscreen's, down and not moved), held
-- still the right click; nil: none
function M.touch_finger()
	for _, g in pairs(C.fingers) do
		if not g.ui and not g.stick and not g.moved then
			if not g.held and buildat.get_time_us() - g.t0 > 500000 then
				g.held = true
				click(g.x, g.y, false)
			end
			return g
		end
	end
	return nil
end

-- ---- The view: the camera placed each frame as the mode has it
local function body_at(dt, alpha)
	local p = pos_of(C.s)
	if not p then
		return nil
	end
	local q = C.prev or p
	-- The correction's offset goes in a tenth of a second
	local k = math.exp(-dt / 0.1)
	for i = 1, 3 do
		C.offset[i] = C.offset[i] * k
	end
	-- [KIT_MOVING_OBJECTS] On a moving deck: its own steps' place on the deck as the
	-- deck is drawn, so nothing is between the view and the deck
	local fr = C.s.frame
	local o = fr and C.draw_t and C.turned_by and C.turned_by[fr]
	if o and o.links and type(C.s.at) == "table" then
		local a = C.s.at
		local b = C.prev_frame == fr and C.prev_at or a
		local lx, ly, lz = b[1] + (a[1] - b[1]) * alpha, b[2] + (a[2] - b[2]) * alpha,
				b[3] + (a[3] - b[3]) * alpha
		local R = o.R
		return {o.x + R[1] * lx + R[2] * ly + R[3] * lz + C.offset[1],
			o.y + R[4] * lx + R[5] * ly + R[6] * lz + C.offset[2],
			o.z + R[7] * lx + R[8] * ly + R[9] * lz + C.offset[3]}
	end
	return {q[1] + (p[1] - q[1]) * alpha + C.offset[1],
		q[2] + (p[2] - q[2]) * alpha + C.offset[2],
		q[3] + (p[3] - q[3]) * alpha + C.offset[3]}
end

local function bd_h()
	return tonumber(body_decl().h) or 1.7
end

local function lerp_yaw(a, b, t)
	local d = ((b - a) % 360 + 540) % 360 - 180
	return a + d * t
end

local function place_camera(dt, at)
	local node = O.camera
	local cam = node:GetComponent("Camera")
	local par = params()
	local mode = camera_mode()
	-- [KIT_SPECTATE] out of play: a free camera or a player's view
	-- (players.lua)
	local sp, sr = M.spectate_view(dt, node.position, C.yaw, C.pitch)
	if sp then
		node.position = sp
		node.rotation = sr
		C.cam = sp
		return mode
	end
	local bd = body_decl()
	local ox, oy, oz = tonumber(par.offset_x) or 0, tonumber(par.offset_y) or 0,
			tonumber(par.offset_z) or 0
	-- The fov: the controls', a signal's tween over it
	local fov = tonumber(par.fov) or 75
	if C.fov_tween then
		local t = C.fov_tween
		t.t = t.t + dt
		local k = t.len > 0 and math.min(1, t.t / t.len) or 1
		k = k * k * (3 - 2 * k)
		C.fov = t.from + (t.to - t.from) * k
		if k >= 1 and t.to == fov then
			C.fov_tween, C.fov = nil, nil
		end
	end
	cam.fov = magic.fov_for(C.fov or fov)
	-- The shake: decays
	C.shake = C.shake * math.exp(-(tonumber(par.shake_decay) or 3) * dt)
	if C.shake < 0.001 then
		C.shake = 0
	end
	local sh = C.shake
	local function jitter(a)
		return (math.random() * 2 - 1) * a
	end
	local roll = (tonumber(par.roll) or 0) + jitter(sh * 4)
	local want_pos, rot
	cam.orthographic = false
	if mode == "top_down" then
		local h = (tonumber(par.height) or 14) * C.zoom
		local pitch = tonumber(par.angle) or 60
		rot = magic.Quaternion(pitch, tonumber(par.yaw) or 0, roll)
		local d = rot * magic.Vector3(0, 0, 1)
		local target = magic.Vector3(at[1] + ox, at[2] + oy + 1, at[3] + oz)
		want_pos = target - d * h
		if par.ortho == true then
			cam.orthographic = true
			cam.orthoSize = h
		end
	elseif mode == "chase" then
		local dist = (tonumber(par.distance) or 6) * C.zoom
		local yaw = C.yaw
		-- A vehicle's view behind it, turning as it turns
		if M.seated() and C.s and tonumber(C.s.yaw) then
			C.chase_yaw = lerp_yaw(C.chase_yaw or C.s.yaw, C.draw_yaw or C.s.yaw,
					1 - math.exp(-dt / 0.25))
			yaw = C.chase_yaw
		end
		local pitch = math.max(-10, math.min(80, C.pitch + 15))
		rot = magic.Quaternion(pitch, yaw, roll)
		if C.tilt then
			rot = C.tilt * rot
		end
		local d = rot * magic.Vector3(0, 0, 1)
		local h = tonumber(bd.h) or 1.7
		local off = magic.Vector3(ox, h * 0.8 + oy, oz)
		if C.tilt then
			off = C.tilt * off
		end
		local target = magic.Vector3(at[1] + off.x, at[2] + off.y, at[3] + off.z)
		-- Not through a wall: in front of what is between
		local w = world()
		local t = w:ray(target.x, target.y, target.z, -d.x, -d.y, -d.z, dist)
		if t then
			dist = math.max(0.3, t - 0.2)
		end
		want_pos = target - d * dist
	else
		rot = magic.Quaternion(C.pitch, C.yaw, roll)
		local off = magic.Vector3(ox, (tonumber(bd.eye) or 1.5487) + oy, oz)
		if C.tilt then
			rot = C.tilt * rot
			off = C.tilt * off
		end
		want_pos = magic.Vector3(at[1] + off.x, at[2] + off.y, at[3] + off.z)
	end
	-- Smoothed where the camera is not an eye
	local sm = tonumber(par.smoothing) or 0
	if mode ~= "first_person" and sm > 0 and C.cam then
		local k = 1 - math.exp(-dt / sm)
		want_pos = C.cam + (want_pos - C.cam) * k
	end
	C.cam = want_pos
	if sh > 0 then
		want_pos = want_pos + magic.Vector3(jitter(sh * 0.3), jitter(sh * 0.3),
				jitter(sh * 0.3))
	end
	node.position = want_pos
	node.rotation = rot
	return mode
end

-- ---- Each frame: the look turned, the steps at the movement's rate, the
-- view
local was_ready = false
magic.SubscribeToEvent("Update", function(_, data)
	for i = #body_logs, 1, -1 do
		if buildat.get_time_us() >= body_logs[i] then
			table.remove(body_logs, i)
			log_body()
		end
	end
	if not C.on or not O.camera then
		return
	end
	local dt = data:GetFloat("TimeStep")
	-- The look: the mouse in the crosshair, the right drag with a cursor
	local mx, my = 0, 0
	if walking() and not paused() and not TOUCH and camera_mode() ~= "top_down" then
		if not M.pointer_free() and (not E.editing or M.looking()) then
			mx, my = ui_utils.mouse_look_move()
		elseif magic.input:GetMouseButtonDown(magic.MOUSEB_RIGHT) then
			local m = magic.input:GetMouseMove()
			mx, my = m.x, m.y
		end
	end
	-- The gamepad's right stick: 120 degrees a second at full
	if walking() and not paused() and camera_mode() ~= "top_down" then
		mx = mx + M.pad_axis(2) * 1200 * dt
		my = my + M.pad_axis(3) * 1200 * dt
	end
	C.yaw = (C.yaw + mx * 0.1) % 360
	C.pitch = math.max(-89, math.min(89, C.pitch + my * 0.1))
	if TOUCH then
		make_bar()
		C.bar.visible = not E.editing
		C.abar.visible = not E.editing and #M.world_actions() > 0
	end
	-- The steps
	if C.s and not C.ready and floor_ready() then
		C.ready = true
		log:info("player physics enabled")
	end
	local step_len = 1 / rate()
	if C.s and C.ready and C.def then
		C.acc = C.acc + dt
		local n = 0
		local w = nil
		while C.acc >= step_len and n < 8 do
			C.acc = C.acc - step_len
			n = n + 1
			w = w or world()
			C.prev = pos_of(C.s)
			C.prev_at = type(C.s.at) == "table" and {C.s.at[1], C.s.at[2], C.s.at[3]} or nil
			C.prev_frame = C.s.frame
			C.prev_yaw = tonumber(C.s.yaw)
			local i = gather()
			-- [KIT_MOVING_OBJECTS] The time of this step: both sides step it there
			if C.draw_t then
				i.t = math.floor((C.draw_t - C.acc * (C.clock_rate or 1)) * 1000)
				C.last_t = i.t / 1000
			end
			C.seq = C.seq + 1
			step(C.s, i, w)
			C.pending[#C.pending + 1] = {C.seq, i}
			-- [KIT_PLAYER_MODEL] and the pitch, the swings and the dig
			-- others see on this body
			C.out[#C.out + 1] = string.format("%d %s %s %s %d %d %s %s %s " ..
					"%s %d %d", C.seq, i.f, i.r, i.yaw, i.jump, i.go, i.tx, i.ty,
					i.tz, fmt(C.pitch, 1), M.pose_swings or 0,
					M.dig_progress and M.dig_progress() and 1 or 0) ..
					(i.t and string.format(" %.0f", i.t) or "")
			route_tick()
		end
		if C.acc > step_len then
			C.acc = 0
		end
		C.touch_jump = false
		if #C.out > 0 then
			buildat.send_packet("kit:input", C.put .. ";" ..
					table.concat(C.out, ";"))
			C.out = {}
		end
	end
	-- (a step left what moves at its stamp)
	if C.draw_t then
		C.pose_world:pose_at(C.draw_t)
	end
	update_tilt(dt)
	-- [KIT_WALKER_FRAME] For a drive: when the frame changes
	local fr = C.s and C.s.frame or nil
	if fr ~= C.was_frame then
		C.was_frame = fr
		log:info("kit: the body's frame: " .. tostring(fr or "the world"))
	end
	local at = body_at(dt, C.ready and C.acc / step_len or 1)
	C.draw = at
	if C.s and tonumber(C.s.yaw) then
		C.draw_yaw = lerp_yaw(C.prev_yaw or C.s.yaw, C.s.yaw, C.ready and
				C.acc / step_len or 1)
	end
	-- The seat held drawn where it is predicted
	P.pose = {}
	local seat = M.seated()
	if seat and at then
		P.pose[seat] = {at[1], at[2] + 0.5, at[3], C.draw_yaw or 0}
	end
	local mode = camera_mode()
	if at then
		place_camera(dt, at)
	end
	-- [KIT_PLAYER_MODEL] the players' bodies (players.lua): this one's
	-- where it is predicted, shown but in first person or in a seat
	M.draw_players(at, view_yaw(), C.pitch, bd_h(), mode ~= "first_person" and
			not seat and not M.spectating())
	effects(dt)
end)

-- For a drive: "event kit_click_at <x> <y> <z> [right]" clicks (the left
-- button; the right one) where that point is on the screen
magic.SubscribeToEvent("command_seq:kit_click_at", function(_, data)
	local x, y, z, b = data:GetString("Param"):match(
			"^(%S+) (%S+) (%S+) ?(%S*)")
	local cam = O.camera:GetComponent("Camera")
	local sp = cam:WorldToScreenPoint(magic.Vector3(tonumber(x) or 0,
			tonumber(y) or 0, tonumber(z) or 0))
	local w, h = screen()
	log:info(string.format("kit: a click at %d,%d", sp.x * w, sp.y * h))
	click(sp.x * w, sp.y * h, b ~= "right")
end)

-- For a drive: "event kit_point_at <x> <y> <z>" points the pointer (the
-- crosshair or the cursor) where that point is on the screen, following
-- it as the camera moves; "event kit_point_at" lets go
magic.SubscribeToEvent("command_seq:kit_point_at", function(_, data)
	local x, y, z = data:GetString("Param"):match("^(%S+) (%S+) (%S+)")
	C.aim = x and magic.Vector3(tonumber(x) or 0, tonumber(y) or 0,
			tonumber(z) or 0) or nil
	log:info("kit: pointing at " .. (x and x .. "," .. y .. "," .. z or
			"the pointer's own"))
end)

-- The app's options
function M.controls(o)
	for k, v in pairs(o) do
		O[k] = v
	end
	if TOUCH then
		make_bar()
	end
end
end
-- vim: set noet ts=4 sw=4:
