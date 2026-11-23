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
--   kit.movement_help() -> the movement's hints not used yet ("" none
--     left), nil: it declares none ([KIT_PLAY_HINTS], below)
--   kit.touch_bar_left() -> where the touch bars begin (UI x; nil: none)
--   kit.viewport(scene, camera) -> a Viewport with Kit's effects
--   [RACER_FEEL] (2) kit.shake(amount): the camera shaken from a client part
--     (its own prediction of a crash) as kit/controls' shake input does it
--     (amount 0...5, decaying at shake_decay), from this frame: called before
--     the camera is placed it is placed shaken, after (a draw hook) the
--     camera is moved now. This client's camera only; nothing sent
-- The keys (input.lua's actions, the player's to rebind; these the
-- defaults): W A S D (a car: throttle, brake and steering), Space jumps,
-- F leaves a seat (a key bound to use uses what is pointed at, the left
-- click's use without its dig); a gamepad's left stick
-- moves, its right one looks, A jumps, X uses, B leaves a seat; a free
-- cursor turns the view with the right button held, the wheel zooms a
-- chase or top-down camera, kept per camera mode and movement on this client
-- (Kit's storage kit_zoom: across races, rounds and rejoins). A touchscreen
-- (BUILDAT_TOUCH=1, floorplanner's walking): a stick at the lower left
-- walks (a car: steers), a drag elsewhere turns, two fingers pinch the zoom
-- as the wheel does, a tap is the left click
-- at the finger and a finger held still the right; [KIT_TOUCH_THUMBS] a
-- stack at the lower right, thumb-sized (thumb()): from the top the app's
-- (Menu) and Exit in a seat half as high, the movement's touch_buttons, Jump
-- (a car: Brake, Gas, then a touch_buttons' "low" one); the world's actions (held while pressed) a
-- stack above it, or left of it where that does not fit; the movement's
-- touch_axes a stack at the lower left, the stick beside it.
-- For a drive: "event kit_body" logs the body and the corrections (and the
-- side or top_down camera's followed point and lead).
-- [KIT_TOP_DOWN] kit/controls' plane horizontal (C.ctl.horizontal, M.level_plane):
-- the body held at one height (move.lua), the pointer and the camera as without a
-- plane; the top_down camera follows with a dead zone and a lead as side does
-- (follow_point); kit/parallax's follow_y along z (module.lua).
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
	touch_jump = false, touch_held = {}, touch_axis = {}, rows = {}, bar = nil, bar_kind = nil,
	classes = {}}
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
-- [KIT_EDIT_VIEW] The editor's first view (nil: the controls not here yet);
-- [RACER_FEEL] (4) a plane game's auto is 2d
function M.edit_view()
	local v = C.ctl and (params().edit_view or "auto")
	return v == "auto" and M.plane_game() and "2d" or v or nil
end
-- [RACER_FEEL] (4) kit/controls' plane, level or upright: the editor's 2D view
-- first, its right drag panning
function M.plane_game()
	return C.ctl ~= nil and (C.ctl.horizontal == true or tonumber(C.ctl.plane) ~= nil)
end
-- [KIT_CRAG_PLAYTEST_1] kit/controls' camera side, game-wide: the editor's
-- 2D view is the Front view
function M.side_game()
	return params().camera == "side"
end
-- [KIT_TOP_DOWN] (5) kit/controls' plane horizontal (the server's word)
function M.level_plane()
	return C.ctl ~= nil and C.ctl.horizontal == true
end
-- [KIT_CHASE_HEADING] A chase camera following the body's heading:
-- kit/controls' chase_follow (its lag, seconds; 0: mouse look), out of a seat
-- (a seat's chase as before); heading: its body has one (s.yaw).
-- [KIT_PARAM_AUDIT] first_person likewise: the eye turned with the body
local function chase_follow(heading)
	local lag = tonumber(params().chase_follow) or 0
	local m = camera_mode()
	if lag > 0 and (m == "chase" or m == "first_person") and not M.seated() and
			(not heading or C.s and tonumber(C.s.yaw)) then
		return lag
	end
	return nil
end
-- Whether the mouse or a drag turns the view (a top-down's, [KIT_PLANE] a
-- side camera's and a chase or first person following the heading never turn)
function M.view_turns()
	local m = camera_mode()
	return m ~= "top_down" and m ~= "side" and not chase_follow(true)
end
-- [KIT_TOOLS_2] A shot's recoil: the view kicked up by deg degrees
function M.kick(deg)
	C.pitch = math.max(-89, C.pitch - (tonumber(deg) or 0))
end

function M.pointer_free()
	local p = params().pointer or "auto"
	if p == "auto" then
		return camera_mode() == "top_down" or camera_mode() == "side" or
				chase_follow() ~= nil
	end
	return p == "cursor"
end

function M.seated()
	local s = C.ctl and tonumber(C.ctl.seat) or 0
	return s > 0 and s or nil
end

-- [KIT_VEHICLE_MOVEMENTS] What a seat held drives: it or what it is on
function M.vehicle_of(seat)
	return C.ctl and tonumber(C.ctl.vehicle) or seat
end
-- Whether a node is the vehicle held or under it (the body meets none of them)
local function on_vehicle(id, n)
	local v = M.seated() and M.vehicle_of(M.seated())
	for _ = 1, 17 do
		if not v or not n then
			return false
		end
		if id == v then
			return true
		end
		local pv = n.node:GetVar("kit_parent")
		id = pv:IsEmpty() and 0 or pv:GetInt()
		n = P.nodes[id]
	end
	return false
end
M.on_vehicle = on_vehicle

-- [KIT_SHIP_VIEW] The craft ridden: the topmost of the seat, what it is on that
-- moves (a free object or a member of one) and the vehicle it drives (nil: no seat)
local function craft()
	local seat = M.seated()
	if not seat then
		return nil
	end
	local v = M.vehicle_of(seat)
	local root, id, n = v, seat, P.nodes[seat]
	for _ = 1, 17 do
		if not n then
			break
		end
		if id == v or (C.turned_by and C.turned_by[id]) or (C.links and C.links[id]) then
			root = id
		end
		local pv = n.node:GetVar("kit_parent")
		id = pv:IsEmpty() and 0 or pv:GetInt()
		n = P.nodes[id]
	end
	return root
end
-- Whether an entity is the root or under it
local function under(root, id, n)
	for _ = 1, 17 do
		if id == root then
			return true
		end
		if not n then
			return false
		end
		local pv = n.node:GetVar("kit_parent")
		id = pv:IsEmpty() and 0 or pv:GetInt()
		n = P.nodes[id]
	end
	return false
end

-- [KIT_VEHICLE_MOVEMENTS] The steered vehicle ridden (its id; nil: none): the server
-- steps it, this client sends its inputs and draws it from its track
function M.riding()
	local r = C.ctl and tonumber(C.ctl.ride) or 0
	return r > 0 and r or nil
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

-- [KIT_PLANE] The z a vertical plane holds (nil: none, [KIT_TOP_DOWN] or level)
local function plane_z()
	return C.ctl and not C.ctl.horizontal and tonumber(C.ctl.plane) or nil
end

-- (skip: what is left out, a function of an entity's id and node; the vehicle held)
local function world(skip)
	local reg = voxelworld.get_voxel_registry()
	local boxes, polys = {}, {}
	local moving_looks = nil
	local turned = C.turned
	if skip and turned then
		turned = {}
		for _, t in ipairs(C.turned) do
			if not skip(t.id, P.nodes[t.id]) then
				turned[#turned + 1] = t
			end
		end
	end
	skip = skip or on_vehicle
	for id, n in pairs(P.nodes) do
		local show = type(n.show) == "table" and n.show or {}
		-- ([KIT_SIDE_SCENERY] (8) what is under a kit/parallax layer is never
		-- met: kit.cpp's snapshot leaves it out too)
		if type(show.look) == "table" and not show.player and not skip(id, n) and
				not M.parallax_layer(id, n) then
			local on = show.look.state and K.value(n, show.look.state) == true
			local links = M.links_of(id, n)
			local r = links and n.rest
			if r then
				-- [KIT_MOVING_OBJECTS] As each step's time has it, from where it rests
				-- ([RACER_FEEL] (1) the angles as the server's Turn::angles has them)
				local qy, qp, qr = MV.turn_angles(r[4], r[5], r[6], r[7])
				moving_looks = moving_looks or {}
				moving_looks[#moving_looks + 1] = {show.look, on == true, {r[1], r[2], r[3]},
					qy, qp, qr, links}
			else
				-- [KIT_STILL_LOOKS] kept till its place, turn or show change
				-- (module.lua's n.gen) or its state turns
				local c = n.world_made
				if not (c and n.gen and c.gen == n.gen and n.look and c.on == on) then
					local p = n.node.position
					local q = n.node.rotation
					local tilted = q.x ~= 0 or q.z ~= 0
					local qy, qp, qr = MV.turn_angles(q.w, q.x, q.y, q.z)
					c = {gen = n.gen, on = on, box = MV.look_box(show.look, on, {p.x, p.y, p.z}, qy,
							tilted and qp or 0, tilted and qr or 0),
						-- [KIT_PLANE] stage 3: a polygon's prism
						poly = show.look.shape == "polygon" and MV.look_poly(show.look, on,
							{p.x, p.y, p.z}, qy, tilted and qp or 0, tilted and qr or 0) or nil}
					n.world_made = c
				end
				boxes[#boxes + 1] = c.box
				polys[#polys + 1] = c.poly
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
			-- ([KIT_NO_WORLD] no ground: air)
			return not (C.ctl and C.ctl.void) and MV.UNKNOWN or nil
		end
		return voxel_info(id, v)
	end, boxes = boxes, turned = turned, ground = ground,
		edge = ground and {hm[3] or 0, hm[4] or 0, (hm[3] or 0) + hm[1] - 1,
			(hm[4] or 0) + hm[2] - 1} or nil,
		moving_looks = moving_looks, t = C.draw_t, polys = polys,
		-- [KIT_PLANE] the body's z held ([KIT_TOP_DOWN] or y: horizontal)
		plane = C.ctl and tonumber(C.ctl.plane), horizontal = C.ctl and C.ctl.horizontal,
		-- [KIT_TOP_DOWN] (8) the others, for a movement that meets them
		bodies = C.ctl and C.ctl.horizontal and decl().bodies == true and
			(tonumber(C.ctl.seat) or 0) == 0 and M.others_bodies and
			M.others_bodies(tonumber(body_decl().r) or 0.45, tonumber(body_decl().h) or 1.7) or nil}
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

-- Whether a and b hold the same: strings, booleans and tables of them, and
-- numbers to a billionth (the box's Lua and the client's differ in the last
-- bits of some: 57.772970860263 either way)
local function same(a, b)
	if type(a) == "number" and type(b) == "number" then
		local d, m = a - b, math.max(a < 0 and -a or a, b < 0 and -b or b)
		return (d < 0 and -d or d) <= 1e-9 * m + 1e-12
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function pos_of(s)
	local p = s and s.pos
	if type(p) ~= "table" then
		return nil
	end
	return {tonumber(p[1]) or 0, tonumber(p[2]) or 0, tonumber(p[3]) or 0}
end

-- [KIT_PLANE] stage 4: three steps in a row longer than this stop the
-- prediction (the server's places only) till the movement's next version (a
-- hitch's one is not the step's)
-- simplified: by the clock after the step (no count hook in the client's
-- sandbox); one that never returns is the watchdog's (app.cpp)
local SLOW_US = 50000
local function step(s, i, w)
	local m = move()
	if not C.def or not m or C.slow then
		return
	end
	-- [KIT_MOVE_DRAW] c:speed's factor now, as the server's batch has it
	i.speed = tonumber(m.speed) or 1
	local sub = math.max(1, math.min(8, tonumber(m.params.substeps) or 1))
	local t0 = buildat.get_time_us()
	local ok, err = pcall(MV.steps, C.def, s, {i}, 1 / rate(), sub, w,
			m.params)
	local us = buildat.get_time_us() - t0
	C.slow_n = ok and us > SLOW_US * sub and (C.slow_n or 0) + 1 or 0
	if C.slow_n >= 3 then
		C.slow = true
		log:warning(string.format("kit: the movement %s: too slow: a step of %d ms," ..
				" its prediction off", tostring(m.type), us / 1000 / sub))
	end
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
	if C.ctl and (C.ctl.hm and heightmap.terrain or C.ctl.void) then
		return true
	end
	-- [KIT_VEHICLE_MOVEMENTS] put on a deck (out of a seat): the deck's boxes are there
	if C.s and C.s.frame then
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
		-- ([KIT_CHASE_HEADING] the chase's turn taken at once, not swung to)
		C.chase_yaw = nil
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
	-- [KIT_VEHICLE_MOVEMENTS] Riding: nothing predicted, the seat is where it is drawn
	if M.riding() then
		C.acks = C.acks + 1
		C.pending = {}
		return
	end
	local before = pos_of(C.s)
	local keep, acked = {}, nil
	for _, q in ipairs(C.pending) do
		if q[1] > ack then
			keep[#keep + 1] = q
		elseif q[1] == ack then
			acked = q
		end
	end
	C.pending = keep
	-- [KIT_SAME_STATE] The server's state after the input acknowledged the
	-- one this client predicted after it: the steps since stand as they are
	-- (stepped again, each was the steps' cost again a body packet, a round
	-- trip's worth of them)
	if acked and same(acked[3], b.s) then
		C.acks = C.acks + 1
		return
	end
	C.s = b.s
	C.replays = (C.replays or 0) + (#keep > 0 and 1 or 0)
	local w = #keep > 0 and world() or nil
	for _, q in ipairs(keep) do
		step(C.s, q[2], w)
		q[3] = copy(C.s)
	end
	C.acks = C.acks + 1
	local after = pos_of(C.s)
	if before and after then
		local d = {before[1] - after[1], before[2] - after[2],
			before[3] - after[3]}
		local l = math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
		if l > 0.01 then
			-- [KIT_PUT_COUNTED_CORRECTION] Play or Stop moved what is under it
			-- before this client heard: taken, not a correction
			if b.settle then
				log:info(string.format("kit: the body settled by %.3f m after Play or Stop", l))
			else
				C.corrections = C.corrections + 1
				log:info(string.format("kit: the body corrected by %.3f m (%d of %d)",
						l, C.corrections, C.acks))
			end
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
-- [KIT_WALK_HERE] The view turned to yaw and pitch (degrees; nil: kept),
-- and the feet {x, y, z} for an eye at eye (a Vector3): the editor's
-- "Walk here" asks the server to put the body there (a put keeps the view)
function M.walk_here(eye, yaw, pitch)
	C.yaw = yaw and yaw % 360 or C.yaw
	C.pitch = pitch and math.max(-89, math.min(89, pitch)) or C.pitch
	return {eye.x, eye.y - (tonumber(body_decl().eye) or 1.5487), eye.z}
end
local function log_body()
	local p = pos_of(C.s) or {0, 0, 0}
	log:info(string.format("kit: body at %.2f,%.2f,%.2f, %d acks, %d " ..
			"corrections, %d pending, %d jumps, %d arrivals", p[1], p[2], p[3],
			C.acks, C.corrections, #C.pending, tonumber(C.s and C.s.jumps) or 0,
			tonumber(C.s and C.s.arrived) or 0))
	-- [KIT_WALKER_FRAME] To the tenth of a millimetre, for measuring a deck
	-- (kit_free_prefab_check reads it on the line after the one above)
	log:info(string.format("kit: feet at %.4f,%.4f,%.4f, frame %s", p[1], p[2],
			p[3], tostring(C.s and C.s.frame or "none")))
	-- ([KIT_TOP_DOWN] (2) what the step says it stands on: a floor polygon's)
	log:info(string.format("kit: body on %s, friction %s",
			tostring(C.s and C.s.surface or "none"), tostring(C.s and C.s.friction)))
	-- [KIT_SAME_STATE] the body packets whose steps were taken again
	log:info(string.format("kit: body replayed %d of %d acks", C.replays or 0, C.acks))
	-- ([KIT_TOUCH_THUMBS] (4) the camera's zoom, the input held)
	log:info(string.format("kit: zoom %.3f (%s), input f %s r %s, yaw %s", C.zoom,
			tostring(C.zoom_key), tostring(C.last_i and C.last_i.f),
			tostring(C.last_i and C.last_i.r), tostring(C.s and C.s.yaw)))
	-- [KIT_SIDE_LEAD] the side camera's middle and its lead
	if C.side_at and C.side_lead then
		log:info(string.format("kit: side camera at %.2f,%.2f, lead %.2f,%.2f",
				C.side_at[1], C.side_at[2], C.side_lead[1], C.side_lead[2]))
	end
	-- ([KIT_TOP_DOWN] (6) the top_down camera's, its view's axes on the ground)
	if C.top_at and C.top_lead then
		log:info(string.format("kit: top_down camera at %.2f,%.2f, lead %.2f,%.2f",
				C.top_at[1], C.top_at[2], C.top_lead[1], C.top_lead[2]))
	end
	-- [KIT_SPECTATE_CAMERA] The camera: its place, turn and fov, and how far
	-- a shake has it off its place
	if O.camera and C.cam then
		local p, q = O.camera.position, O.camera.rotation
		log:info(string.format("kit: camera at %.2f,%.2f,%.2f turn %.4f,%.4f,%.4f,%.4f, " ..
				"fov %.1f, shaken %.3f", p.x, p.y, p.z, q.w, q.x, q.y, q.z,
				O.camera:GetComponent("Camera").fov, (p - C.cam):Length()))
	end
	-- [KIT_SHIP_VIEW] A chase view's distance from what it looks at
	if C.chase_dist then
		log:info(string.format("kit: camera %.2f m behind", C.chase_dist))
	end
	if C.chase_dist or C.fp_follow then
		-- ([KIT_CHASE_HEADING] its turn and the body's as drawn)
		log:info(string.format("kit: chase yaw %.2f, the body's %s", C.chase_yaw or
				C.yaw, C.draw_yaw and string.format("%.2f", C.draw_yaw) or "none"))
	end
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
		-- [KIT_VEHICLE_MOVEMENTS] and the steered entities' nodes (a turret)
		for _, o in ipairs(C.ctl and type(C.ctl.steered) == "table" and C.ctl.steered or {}) do
			local n = P.nodes[o[1]]
			if n then
				local a, q = n.node.worldPosition, n.node.worldDirection
				parts[#parts + 1] = string.format("%d entity %.4f,%.4f,%.4f facing %.4f,%.4f,%.4f",
						o[1], a.x, a.y, a.z, q.x, q.y, q.z)
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

-- [RACER_FEEL] (2) A client part's shake (the header's kit.shake): the server's
-- shake input's, this frame (the engine's frame number; C.placed the frame the
-- camera was last placed in)
function M.shake(amount)
	local a = math.max(0, math.min(5, tonumber(amount) or 0))
	if a <= 0 or not O.camera then
		return
	end
	signal("shake", {amount = a})
	local f = magic.time.frameNumber
	if C.placed == f then
		-- Placed already this frame: moved now as place_camera moves it
		local function jitter(k)
			return (math.random() * 2 - 1) * k
		end
		local node = O.camera
		node.position = node.position + magic.Vector3(jitter(a * 0.3), jitter(a * 0.3),
				jitter(a * 0.3))
		node.rotation = node.rotation * magic.Quaternion(0, 0, jitter(a * 4))
		log:info(string.format("kit: a client part's shake %g, the camera moved in " ..
				"frame %d", a, f))
	else
		C.shake_frame = f
		log:info(string.format("kit: a client part's shake %g in frame %d", a, f))
	end
end

-- [KIT_FREE_PREFAB] The controls' free objects ({boxes, x, y, z, yaw, pitch, roll,
-- id, node, links}...) and each boxes name's boxes in its object's frame, as the
-- server's body meets them ([KIT_AIRSHIPS] a copy with its own voxels: a new name
-- each rebuild).
-- simplified: the names a rebuild left behind stay in object_boxes till the client
-- goes, a few hundred bytes each [KIT_MOVING_OBJECTS] C.links by entity: what moves each one that
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
	-- [KIT_VEHICLE_MOVEMENTS] the steered ones that are no free object: their nodes
	-- moved as an object's members are
	local st = C.ctl and C.ctl.steered
	for _, o in ipairs(type(st) == "table" and st or {}) do
		if type(o[2]) == "table" and #o[2] > 0 then
			links[o[1]] = o[2]
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

-- [KIT_VEHICLE_MOVEMENTS] A steered one's keys (move.lua's M.tracks), as kit.cpp's
-- send_tracks: "<id> <gen> <t> <x> <y> <z> <yaw> <pitch> <roll>...;..." (a new gen
-- starts it over); kept for 5 s
C.track_gen = {}
buildat.sub_packet("kit:track", function(data)
	for part in data:gmatch("[^;]+") do
		local nums = {}
		for v in part:gmatch("%S+") do
			nums[#nums + 1] = tonumber(v)
		end
		local id, gen = nums[1], nums[2]
		if id and gen then
			local k = MV.tracks[id]
			if C.track_gen[id] ~= gen or not k then
				k = {}
				MV.tracks[id] = k
				C.track_gen[id] = gen
				log:info("kit: a track for entity " .. id)
			end
			for i = 3, #nums - 6, 7 do
				k[#k + 1] = {nums[i], nums[i + 1], nums[i + 2], nums[i + 3], nums[i + 4],
					nums[i + 5], nums[i + 6]}
			end
			local last = k[#k] and k[#k][1] or 0
			local drop = 0
			while drop + 2 < #k and k[drop + 2][1] < last - 5000 do
				drop = drop + 1
			end
			if drop > 0 then
				local n = {}
				for i = drop + 1, #k do
					n[#n + 1] = k[i]
				end
				MV.tracks[id] = n
			end
		end
	end
end)

local function shared_time()
	return (C.clock_off or 0) + buildat.get_time_us() / 1e6 * (C.clock_rate or 1)
end

-- [KIT_RECORDS] (ui.lua's running kit/stopwatch times) nil before the first
-- kit:clock
function M.shared_time()
	return C.clock_off and shared_time()
end

-- [KIT_AIRSHIPS] The free object a ray meets first, where it is drawn now: {id,
-- t, cell, normal, dir} (move.lua's W:ray_objects, in its frame), centre (the
-- cell's middle in the world, a Vector3) and rot (its turn, a Quaternion); nil none
function M.object_target(origin, dir, len)
	if not C.pose_world or not C.turned or #C.turned == 0 then
		return nil
	end
	if C.draw_t then
		C.pose_world:pose_at(C.draw_t)
	end
	local t, ob, cell, n, ld = C.pose_world:ray_objects(origin.x, origin.y, origin.z,
			dir.x, dir.y, dir.z, len)
	if not t then
		return nil
	end
	local R = ob.R
	local c = {ob.x + R[1] * cell[1] + R[2] * cell[2] + R[3] * cell[3],
		ob.y + R[4] * cell[1] + R[5] * cell[2] + R[6] * cell[3],
		ob.z + R[7] * cell[1] + R[8] * cell[2] + R[9] * cell[3]}
	-- The rotation matrix (row-major, frame to world) as a quaternion
	local w, x, y, z
	local tr = R[1] + R[5] + R[9]
	if tr > 0 then
		local s = math.sqrt(tr + 1) * 2
		w, x, y, z = s / 4, (R[8] - R[6]) / s, (R[3] - R[7]) / s, (R[4] - R[2]) / s
	elseif R[1] > R[5] and R[1] > R[9] then
		local s = math.sqrt(1 + R[1] - R[5] - R[9]) * 2
		w, x, y, z = (R[8] - R[6]) / s, s / 4, (R[2] + R[4]) / s, (R[3] + R[7]) / s
	elseif R[5] > R[9] then
		local s = math.sqrt(1 + R[5] - R[1] - R[9]) * 2
		w, x, y, z = (R[3] - R[7]) / s, (R[2] + R[4]) / s, s / 4, (R[6] + R[8]) / s
	else
		local s = math.sqrt(1 + R[9] - R[1] - R[5]) * 2
		w, x, y, z = (R[4] - R[2]) / s, (R[3] + R[7]) / s, (R[6] + R[8]) / s, s / 4
	end
	return {id = ob.id, t = t, cell = cell, normal = n, dir = ld,
		centre = magic.Vector3(c[1], c[2], c[3]), rot = magic.Quaternion(w, x, y, z)}
end

-- A node's "kit_frame" and "kit_parent" (0: none), read again only once the server
-- has changed the node (module.lua drops n.fp then: [KIT_3D_GAINS_1] (4z38) a read
-- through the sandbox for each of a scene's nodes each frame was 10 ms of a frame)
local function frame_parent(n)
	if not n.fp then
		local v = n.node:GetVar("kit_frame")
		local w = n.node:GetVar("kit_parent")
		n.fp = {v:IsEmpty() and 0 or v:GetInt(), w:IsEmpty() and 0 or w:GetInt()}
	end
	return n.fp[1], n.fp[2]
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
	local pid, parent = frame_parent(n)
	if pid == 0 then
		pid = parent
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
		local _, pp = frame_parent(pn)
		pid = pp
	end
	return nil
end

-- A link's change at the draw's time, once a frame
local function link_now(l)
	if l.now_t ~= C.draw_t then
		local xt, yt, zt, _, wp, wy, wr, ky, kp, kr = MV.link_at(l, C.draw_t)
		if not l.q0 then
			l.q0 = magic.Quaternion(tonumber(l[5]) or 0, tonumber(l[4]) or 0, tonumber(l[6]) or 0)
			local q = l.q0
			l.q0i = magic.Quaternion(q.w, -q.x, -q.y, -q.z)
		end
		l.now_t = C.draw_t
		-- ([KIT_3D_GAINS_1] (4z38) l.ver: a new one only as it moves; place_moving
		-- leaves a node be while none of its links has)
		local was = l.was or {}
		if was[1] == xt and was[2] == yt and was[3] == zt and was[4] == wp and
				was[5] == wy and was[6] == wr and was[7] == ky and was[8] == kp and
				was[9] == kr then
			return l
		end
		l.was, l.ver = {xt, yt, zt, wp, wy, wr, ky, kp, kr}, (l.ver or 0) + 1
		l.xt, l.yt, l.zt = xt, yt, zt
		if ky then
			-- [KIT_VEHICLE_MOVEMENTS] steered: its parent's frame, its track's turn there
			local f = l[7].frame
			l.qf = l.qf or magic.Quaternion(tonumber(f[5]) or 0, tonumber(f[4]) or 0,
					tonumber(f[6]) or 0)
			l.d = l.qf * magic.Quaternion(kp, ky, kr) * magic.Quaternion(wp, wy, wr) * l.q0i
		else
			l.d = l.q0 * magic.Quaternion(wp, wy, wr) * l.q0i
		end
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
	local same = rec.rest and rec.lk == links
	if not rec.rest or p.x ~= rec.sx or p.y ~= rec.sy or p.z ~= rec.sz or q.w ~= rec.sw or
			q.x ~= rec.sa or q.y ~= rec.sb or q.z ~= rec.sc then
		rec.rest, same = {p.x, p.y, p.z, q.w, q.x, q.y, q.z}, false
	end
	-- (where it was put, while neither its rest nor a link has moved since: a
	-- barrel at rest, a deck stopped)
	rec.vers = same and rec.vers or {}
	for i, l in ipairs(links) do
		link_now(l)
		same = same and rec.vers[i] == l.ver
		rec.vers[i] = l.ver
	end
	if same then
		return
	end
	rec.lk = links
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
		if links and frame_parent(n) ~= 0 then
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
		log:info("kit: object boxes " .. name .. ": " .. #b / 6)
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
		-- [KIT_PLANE] stage 4: with move.lua's math, as box.c's define runs it
		local ok, def = buildat.eval("return function(math) " .. m.src .. "\nend",
				tostring(m.type) .. ".movement")
		if ok and type(def) == "function" then
			ok, def = pcall(def, copy(MV.math))
		end
		if ok and type(def) == "table" and type(def.step) == "function" then
			C.def, C.src, C.type, C.failed, C.slow = def, m.src, m.type, false, false
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
	-- ([KIT_SPECTATE_CAMERA] one gone, a Stop's or another scene's: none, as a
	-- camera_target or a mode left over would stay)
	for k in pairs(C.signals) do
		if sig[k] == nil then
			C.signals[k] = nil
		end
	end
	if was_free ~= M.pointer_free() and O.capture then
		O.capture(true)
	end
	log:info("kit: controls: camera " .. camera_mode() .. ", pointer " ..
			(M.pointer_free() and "cursor" or "crosshair") .. ", movement " ..
			tostring(m and m.type or "none") .. (M.seated() and ", seat " ..
			M.seated() or "") .. (c.plane and ", plane " .. (c.horizontal and "y " or "z ") ..
			tostring(c.plane) or ""))
	-- [KIT_PLAYER_PARAMS] the view's and the movement's numbers as they change
	-- (a player's own parameters among them)
	local p, mp = params(), m and type(m.params) == "table" and m.params or {}
	local view = string.format("distance %s, fov %s, offset %s,%s,%s, frame %s, " ..
			"gravity %s", tostring(p.distance), tostring(p.fov), tostring(p.offset_x),
			tostring(p.offset_y), tostring(p.offset_z), tostring(p.camera_frame),
			tostring(mp.gravity))
	if view ~= C.view_logged then
		C.view_logged = view
		log:info("kit: controls: view " .. view)
	end
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

-- The input yaw: the view's (a top-down camera's own; [KIT_PLANE] a side camera's
-- the way the body faces, gather()'s)
local function input_yaw()
	if camera_mode() == "top_down" then
		return tonumber(params().yaw) or 0
	end
	if camera_mode() == "side" then
		return C.face or 90
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

-- [KIT_LOBBY_OUT_OF_PLAY] Whether this player is out of play: waiting, or
-- in a kit/lobby's lobby or result (their pose's flag 4, the server's)
local function own_flags()
	local me = P.nodes[P.you]
	local v = me and me.node:GetVar("kit_pose")
	return v and not v:IsEmpty() and
			tonumber(v:GetString():match("^%S+ %S+ %S+ (%S+)")) or 0
end
function M.out_of_play()
	return M.waiting() or own_flags() % 8 >= 4
end
-- [KIT_CLIENT_REACT] (9) Out of play with the body kept drawn here (a
-- kit/lobby's keep_own_body: the pose's flag 8): no spectating
function M.own_body_kept()
	return own_flags() % 16 >= 8 and not M.waiting()
end

local go_next = nil -- a target to send in the next step
-- [KIT_SHIP] For a drive, what a gunman and a helmsman do by their keys, as drawn
-- here: "event kit_aim <id> [<speed> <gravity> [fire]]" turns the turret ridden at
-- that entity (0: off), its facing on its parent against the target's place there
-- (raised by a shot's fall at that speed and gravity); "kit: aimed at <id>" once
-- within a degree, and with "fire" its trigger held while within it. "event kit_steer <x> <z>" ("off": off) steers the vehicle
-- ridden there, slowing to stop on it; "kit: steered to <x> <z>" within 3 m, slow
local function angles(v)
	return math.deg(math.atan2(v.x, v.z)),
			-math.deg(math.atan2(v.y, math.sqrt(v.x * v.x + v.z * v.z)))
end

local function drive_aid(f, r)
	local vn = M.riding() and P.nodes[M.riding()]
	if not vn then
		return f, r
	end
	local n = vn.node
	if C.steer then
		local p = n.position
		local px, pz = p.x, p.z
		local s = C.steer
		local dx, dz = s.x - px, s.z - pz
		local dist = math.sqrt(dx * dx + dz * dz)
		local fw = n.rotation * magic.Vector3(0, 0, 1)
		-- (its speed along it as drawn, over a tenth of a second at least)
		local now = buildat.get_time_us() / 1e6
		if not s.pt then
			s.px, s.pz, s.pt, s.along = px, pz, now, 0
		elseif now - s.pt >= 0.1 then
			s.along = ((px - s.px) * fw.x + (pz - s.pz) * fw.z) / (now - s.pt)
			s.px, s.pz, s.pt = px, pz, now
		end
		local along = s.along
		if dist < 3 and math.abs(along) < 0.7 then
			if not s.done then
				s.done = true
				log:info(string.format("kit: steered to %.1f %.1f (%.2f m off)", s.x, s.z, dist))
			end
			return 0, 0
		end
		local want = math.min(7, dist * 0.4)
		local hy = angles(fw)
		local err = (math.deg(math.atan2(dx, dz)) - hy + 180) % 360 - 180
		return (want - along) * 0.5, err / 20
	end
	local gn = C.gun and P.nodes[C.gun.id]
	if not gn then
		return f, r
	end
	local pv = n:GetVar("kit_parent")
	local pn = P.nodes[pv:IsEmpty() and 0 or pv:GetInt()]
	local q = pn and pn.node.rotation or magic.Quaternion(1, 0, 0, 0)
	local inv = magic.Quaternion(q.w, -q.x, -q.y, -q.z)
	local to = gn.node.position - n.position
	if C.gun.speed > 0 then
		local t = to:Length() / C.gun.speed
		to = to + magic.Vector3(0, 0.5 * C.gun.gravity * t * t, 0)
	end
	local wy, wp = angles(inv * to)
	local y, p = angles(inv * (n.rotation * magic.Vector3(0, 0, 1)))
	local dy, dp = (wy - y + 180) % 360 - 180, wp - p
	if math.abs(dy) < 1 and math.abs(dp) < 1 then
		if not C.gun.done then
			C.gun.done = true
			log:info(string.format("kit: aimed at %d (%.2f, %.2f degrees off)", C.gun.id, dy, dp))
		end
	else
		C.gun.done = false
	end
	-- (up is W: its pitch falls)
	return -dp / 15, dy / 15, C.gun.fire and C.gun.done
end

magic.SubscribeToEvent("command_seq:kit_aim", function(_, data)
	local id, speed, g, fire = data:GetString("Param"):match(
			"^(%d+)%s*([%d.]*)%s*([%d.]*)%s*(%a*)$")
	id = tonumber(id) or 0
	C.gun = id > 0 and {id = id, speed = tonumber(speed) or 0, gravity = tonumber(g) or 0,
		fire = fire == "fire"} or nil
	log:info("kit: aiming at " .. id)
end)

magic.SubscribeToEvent("command_seq:kit_steer", function(_, data)
	local x, z = data:GetString("Param"):match("^(%-?[%d.]+) (%-?[%d.]+)$")
	C.steer = x and {x = tonumber(x), z = tonumber(z)} or nil
	log:info("kit: steering to " .. data:GetString("Param"))
end)

-- [KIT_PLAY_HINTS] The movement's hints for an app's help line: its
-- movement.help (the keys) or touch_help (a touchscreen's), {{keys, what,
-- input}...}, keys as key_text's {key:<action>}, input f, r, jump or down.
-- Each item is gone once its input was used in play, kept on this client
-- per movement type (Kit's storage kit_hints, "<type> <input>" lines).
-- kit.movement_help() -> "keys: what  ..." ("" all used), nil: none declared
local HINTS = nil
local function hints()
	if not HINTS then
		HINTS = {}
		for ty, k in (buildat.storage_read("kit_hints") or ""):gmatch("(%S+) (%S+)") do
			HINTS[ty] = HINTS[ty] or {}
			HINTS[ty][k] = true
		end
	end
	return HINTS
end
local function hint_used(ty, k)
	local h = hints()
	h[ty] = h[ty] or {}
	if h[ty][k] then
		return
	end
	h[ty][k] = true
	local l = {}
	for t, ks in pairs(h) do
		for i in pairs(ks) do
			l[#l + 1] = t .. " " .. i
		end
	end
	local ok, err = buildat.storage_write("kit_hints", table.concat(l, "\n"))
	log:info("kit: the hint of " .. ty .. "'s " .. k .. " used" ..
			(ok and "" or ", not kept: " .. tostring(err)))
end
function M.movement_help()
	local m, list = move(), decl()[TOUCH and "touch_help" or "help"]
	if not m or type(list) ~= "table" then
		return nil
	end
	local used, out = hints()[tostring(m.type)] or {}, {}
	for _, it in ipairs(list) do
		if type(it) == "table" and type(it[1]) == "string" and
				type(it[2]) == "string" and not used[it[3]] then
			out[#out + 1] = M.key_text(it[1]) .. ": " .. it[2]
		end
	end
	return table.concat(out, "  ")
end

local function gather()
	local f, r, jump, down = 0, 0, 0, 0
	if walking() and not paused() and not M.out_of_play() and
			not (ui_utils.clicks_wanted() and
			not M.looking()) then
		-- [KIT_VEHICLE_MOVEMENTS] down (an airship's descent)
		if key("down") then down = 1 end
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
		-- [KIT_TOUCH_THUMBS] the movement's touch_axes, held
		f = f + (C.touch_axis.f or 0)
		r = r + (C.touch_axis.r or 0)
		if C.touch_jump or C.touch_held.jump then
			jump = 1
		end
		-- [KIT_TOUCH_SEAT_BUTTONS] the movement's buttons, held
		if C.touch_held.down then
			down = 1
		end
	end
	local fire
	f, r, fire = drive_aid(f, r)
	if fire then
		jump = 1
	end
	f = math.max(-1, math.min(1, f))
	r = math.max(-1, math.min(1, r))
	-- [KIT_PLANE] The side camera looks along +z: left and right go along x, the
	-- body facing the way it last went (yaw 90: +x, 270: -x); forward and back,
	-- across the plane, go nowhere ([KIT_PLANE] stage 4: a movement's raw_keys
	-- takes them as they are, a bike's throttle and lean)
	if camera_mode() == "side" and not M.riding() and decl().raw_keys ~= true then
		if r ~= 0 then
			C.face = r > 0 and 90 or 270
		end
		f, r = math.abs(r), 0
	end
	local i = {f = fmt(f, 3), r = fmt(r, 3), yaw = fmt(input_yaw() % 360, 2),
		jump = jump, go = 0, tx = 0, ty = 0, tz = 0, down = down}
	if go_next then
		i.go, i.tx, i.ty, i.tz = 1, fmt(go_next[1], 2), fmt(go_next[2], 2),
				fmt(go_next[3], 2)
		go_next = nil
	end
	-- [KIT_CLIENT_REACT] (10) out of play, the step told (as kit.cpp's on_input_u
	-- tells the server's)
	if M.out_of_play() then
		i.out_of_play = true
	end
	if C.oop_said ~= (i.out_of_play == true) then
		C.oop_said = i.out_of_play == true
		log:info("kit: the steps' input: out of play " .. tostring(C.oop_said))
	end
	-- [KIT_AUTO_JUMP] the movement's auto_jump (kit/walker's): all, or
	-- touchscreen on a touch client; a touch builder's Walk view always
	local m = move()
	local aj = m and type(m.params) == "table" and m.params.auto_jump
	if aj == "all" or (TOUCH and (aj == "touchscreen" or
			(E.editing and M.view() == "walk"))) then
		i.auto = 1
	end
	if C.auto_said ~= (i.auto == 1) then
		C.auto_said = i.auto == 1
		log:info("kit: auto jump " .. (C.auto_said and "on" or "off"))
	end
	-- [KIT_PLAY_HINTS] the inputs used in play, of a movement with hints
	if m and not E.editing and (decl().help or decl().touch_help) then
		for _, k in ipairs({"f", "r", "jump", "down"}) do
			if i[k] ~= 0 then
				hint_used(tostring(m.type), k)
			end
		end
	end
	C.last_i = i
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

-- [KIT_TOUCH_THUMBS] (4) The zoom the player chose, kept per camera mode and
-- movement ("<mode>:<type> <zoom>" lines in Kit's storage kit_zoom: the game's
-- on this client), so a race, a round or a rejoin starts where they left it.
-- Written half a second after the last change (zoom_tick)
local ZOOMS = nil
local function zoom_key()
	return camera_mode() .. ":" .. tostring(C.type or "none")
end
local function zooms()
	if not ZOOMS then
		ZOOMS = {}
		for k, v in (buildat.storage_read("kit_zoom") or ""):gmatch("(%S+) (%S+)") do
			ZOOMS[k] = tonumber(v)
		end
	end
	return ZOOMS
end
local function set_zoom(z)
	C.zoom = math.max(0.3, math.min(3, z))
	zooms()[C.zoom_key or zoom_key()] = C.zoom
	C.zoom_save = buildat.get_time_us() + 500000
end
local function zoom_tick()
	local k = zoom_key()
	if k ~= C.zoom_key then
		C.zoom_key = k
		C.zoom = zooms()[k] or 1
		log:info(string.format("kit: the zoom %.3f for %s", C.zoom, k))
	end
	if C.zoom_save and buildat.get_time_us() > C.zoom_save then
		C.zoom_save = nil
		local l = {}
		for key, v in pairs(zooms()) do
			l[#l + 1] = key .. " " .. string.format("%.3f", v)
		end
		local ok, err = buildat.storage_write("kit_zoom", table.concat(l, "\n"))
		log:info(string.format("kit: the zoom %.3f kept for %s", C.zoom, k) ..
				(ok and "" or ", not: " .. tostring(err)))
	end
end

magic.SubscribeToEvent("MouseWheel", function(_, data)
	if not C.on or E.editing or paused() or camera_mode() == "first_person" then
		return
	end
	-- ([KIT_WHEEL_TRACKPAD] by the notch, the web's in tenths: a trackpad's
	-- many small events zoom as far as a notch's)
	local w = data:GetInt("Wheel")
	local notches = math.max(-10, math.min(10, M.wheel_left.web and w / 10 or w))
	set_zoom(C.zoom * 0.9 ^ notches)
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
	local aim = C.aim
	local ob = C.aim_obj and C.turned_by and C.turned_by[C.aim_obj[1]]
	if ob then
		if C.draw_t then
			C.pose_world:pose_at(C.draw_t)
		end
		local R, a = ob.R, C.aim_obj
		aim = magic.Vector3(ob.x + R[1] * a[2] + R[2] * a[3] + R[3] * a[4],
				ob.y + R[4] * a[2] + R[5] * a[3] + R[6] * a[4],
				ob.z + R[7] * a[2] + R[8] * a[3] + R[9] * a[4])
		-- (straight from the camera, wherever it looks)
		if not x then
			local o = node.worldPosition
			return o, (aim - o):Normalized()
		end
	end
	if not x and aim then
		local sp = cam:WorldToScreenPoint(aim)
		x, y = sp.x * w, sp.y * h
	elseif not x then
		if M.pointer_free() and not TOUCH then
			local mp = magic.input:GetMousePosition()
			x, y = mp.x, mp.y
		else
			x, y = w / 2, h / 2
		end
	end
	local o, d = M.screen_ray(x, y, node, cam)
	-- [KIT_PLANE] A side camera's from a hair inside the plane's layer: what is
	-- clipped in front of it is not met, a voxel of the layer is (to dig), and a
	-- free cell of it is placed in against what is behind it.
	-- simplified: a solid cell of the layer pointed at has no place (before its
	-- face is off the plane)
	local pz = camera_mode() == "side" and plane_z()
	if pz and d.z > 1e-6 and o.z < pz - 0.499 then
		o = o + d * ((pz - 0.499 - o.z) / d.z)
	end
	return o, d
end

-- [KIT_PLANE] A side camera's aim (hands.lua's shots): from the body's eye to where
-- the pointer meets the plane, along it (nil: no side camera)
function M.side_aim()
	local pz = plane_z()
	if camera_mode() ~= "side" or not C.draw or not pz then
		return nil
	end
	local o, d = M.pointer_ray()
	if d.z < 1e-6 then
		return nil
	end
	local t = (pz - o.z) / d.z
	local v = magic.Vector3(o.x + d.x * t - C.draw[1], o.y + d.y * t - C.draw[2] -
			(tonumber(body_decl().eye) or 1.5487), 0)
	return v:Length() > 1e-6 and v:Normalized() or nil
end

function M.body_pos()
	return C.draw and magic.Vector3(C.draw[1], C.draw[2], C.draw[3]) or nil
end

-- [KIT_ZONE_SHAPES] The body's spheres as the zones meet them (its movement's
-- s.spheres from the feet, 8 at most): {{x, y, z, r}...} in the world as drawn
function M.body_spheres()
	local s, out = C.s, {}
	if not C.draw or type(s) ~= "table" or type(s.spheres) ~= "table" then
		return out
	end
	for i, c in ipairs(s.spheres) do
		local x, y, z, r = type(c) == "table" and tonumber(c[1]), type(c) == "table" and
				tonumber(c[2]), type(c) == "table" and tonumber(c[3]),
				type(c) == "table" and tonumber(c[4])
		if i > 8 then
			break
		end
		if x and y and z and r and r > 0 then
			out[#out + 1] = {C.draw[1] + x, C.draw[2] + y, C.draw[3] + z, r}
		end
	end
	return out
end

-- [KIT_CLIENT_REACT] (1) This client's own predicted body as the zones meet
-- it (move.lua's zone_body, the server's body_shape: its step's spheres, else
-- a movement.zone = "box" body's box, else its point); nil: none yet. A
-- seat's rider: nil too (the server meets the seat's point, not predicted
-- here). M.zone_math: move.lua's zone shapes and tests (module.lua's
-- update_zones)
M.zone_math = MV
function M.zone_body()
	local feet = pos_of(C.s)
	if not feet or not MV or M.riding() then
		return nil
	end
	return MV.zone_body(feet, C.s.spheres, decl().zone == "box" and body_decl() or nil)
end

-- [KIT_SPECTATE_CAMERA] The feet the camera follows (the body's, a watched
-- player's, a camera_target's less half a body); nil before the first view
function M.camera_follows()
	return C.follow and magic.Vector3(C.follow[1], C.follow[2], C.follow[3]) or nil
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
	for _, b in ipairs({C.bar or false, C.abar or false, C.lbar or false, C.mbar or false}) do
		if b and b.visible then
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

-- [KIT_TOUCH_THUMBS] A thumb's button side, UI pixels: a pitch (a button's
-- edge to the same edge of the next) of 12 mm less the stacks' 4 px gap, at
-- a phone's 160 CSS pixels an inch (a CSS pixel about as big to the eye on
-- any screen: app.cpp's apply_ui_scale; natively under BUILDAT_TOUCH=1 one
-- to a device pixel). The 12 mm: the user's phone, 2026-11-19, alpha.46's
-- buttons in a wide landscape (address bar shown), edge to edge; 16 mm
-- before was too big in portrait
local THUMB_PITCH_MM, THUMB_GAP = 12, 4
local function thumb()
	local density = tonumber(buildat.display_density and buildat.display_density()) or 1
	local css = magic.ui.scale / math.max(0.1, density)
	return math.floor(THUMB_PITCH_MM / 25.4 * 160 / css) - THUMB_GAP
end

-- A row of buttons {label, pressed or nil, released} at the lower right,
-- y up from the bottom; [KIT_TOUCH_THUMBS] side s: a column of them s wide,
-- each s high ({..., half = true}: half that), in parent (default the root)
local function button_row(list, y, least, s, parent)
	local bar = (parent or magic.ui.root):CreateChild("Window")
	bar.defaultStyle = K.STYLE
	bar:SetStyleAuto()
	bar:SetLayout(s and magic.LM_VERTICAL or magic.LM_HORIZONTAL, THUMB_GAP,
			magic.IntRect(6, 6, 6, 6))
	bar:SetAlignment(magic.HA_RIGHT, magic.VA_BOTTOM)
	bar:SetPosition(-8, -y)
	bar.opacity = 0.92
	bar.visible = #list > 0
	for _, b in ipairs(list) do
		local btn = bar:CreateChild("Button")
		btn:SetStyleAuto()
		btn.minHeight = least or 24
		local t = btn:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(b[1])
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		btn.minWidth = math.max(least or 0, t.width + 16)
		if s then
			btn:SetFixedSize(s, b.half and math.floor(s / 2) or s)
			-- (a fifth of the side, less where the label is wider)
			local px = math.max(8, math.floor(s / 5))
			t:SetFontSize(px)
			if t.width > s - 10 then
				t:SetFontSize(math.max(8, math.floor(px * (s - 10) / t.width)))
			end
		end
		btn:SetName("touch bar " .. b[1])
	end
	if s then
		-- (a column no wider than its buttons: the labels' widths before
		-- their font was set widened it)
		bar:SetFixedWidth(s + 12)
	end
	-- (pressed and released by the finger: touch_button)
	C.rows[#C.rows + 1] = {bar = bar, list = list}
	return bar
end

-- [KIT_TOUCH_THUMBS] The bars' button under x, y (pixels) {label, pressed or
-- nil, released}, nil: none. A press is the finger's that made it, not the
-- button's under it (the phone test of 2026-11-19: Gas held, the finger slid
-- off it and lifted, stayed pressed): pressed as it goes down, released as
-- that finger lifts wherever it is (Urho3D's Button lets go as the finger
-- leaves it and sends no Released for a finger lifted off it), so two
-- fingers hold two buttons, each its own. The second value: its side,
-- "left" (the touch_axes stack) or "right"
local function touch_button(x, y)
	local sc = magic.ui.scale
	for _, row in ipairs(C.rows) do
		local bar = row.bar
		local list = bar.visible and (not row.outer or row.outer.visible) and row.list
		for i = 1, list and bar:GetNumChildren() or 0 do
			local btn = bar:GetChild(i - 1)
			local p, s = btn.screenPosition, btn.size
			if x / sc >= p.x and y / sc >= p.y and x / sc < p.x + s.x and
					y / sc < p.y + s.y then
				return list[i], bar == C.lbar and "left" or "right"
			end
		end
	end
	return nil
end

local function labels(list)
	local l = {}
	for i, b in ipairs(list) do
		l[i] = b[1]
	end
	return table.concat(l, ", ")
end

-- [KIT_TOUCH_SEAT_BUTTONS] The movement's touch_buttons {{label, input}...}
-- (input jump or down; (4z37i) a third "low": under Gas, lowest), nil: none
-- declared
local function touch_buttons()
	local tb = decl().touch_buttons
	if type(tb) ~= "table" then
		return nil
	end
	local l = {}
	for _, b in ipairs(tb) do
		if type(b) == "table" and type(b[1]) == "string" and
				(b[2] == "jump" or b[2] == "down") then
			l[#l + 1] = {b[1], b[2], low = b[3] == "low"}
		end
	end
	return l
end

-- [KIT_TOUCH_THUMBS] The movement's touch_axes {{label, "f" | "r", value}...}:
-- a stack at the lower left, top to bottom, each holding that input at that
-- value (-1 to 1) while pressed, on top of the stick's
local function touch_axes()
	local l = {}
	for _, b in ipairs(type(decl().touch_axes) == "table" and decl().touch_axes or {}) do
		if type(b) == "table" and type(b[1]) == "string" and
				(b[2] == "f" or b[2] == "r") and tonumber(b[3]) then
			l[#l + 1] = {b[1], b[2], math.max(-1, math.min(1, tonumber(b[3])))}
		end
	end
	return l
end

-- [KIT_PHONE_EDITING] stage 4b: edit, the editor's touch mode walking
-- (wr, the world's rect in pixels): the movement's own buttons only, at
-- the world's lower right; (4z37i) in play's stack (thumb(), fitted to the
-- world's height)
local function make_bar(wr)
	local tb = touch_buttons()
	local tb_kind = ""
	for _, b in ipairs(tb or {}) do
		tb_kind = tb_kind .. ":" .. b[1] .. "=" .. b[2] .. (b.low and "_" or "")
	end
	local ax = touch_axes()
	for _, b in ipairs(ax) do
		tb_kind = tb_kind .. ":" .. b[1] .. "=" .. b[2] .. b[3]
	end
	local edit = wr ~= nil
	local root = magic.ui.root
	local kind = touch_kind() .. (M.seated() and ":seat" or "") .. ":" ..
			M.keys_version() .. (tb and ":tb" or "") .. tb_kind ..
			(edit and ":edit" .. math.floor(wr[4]) or
			string.format(":%dx%d", root.width, root.height))
	if C.bar and C.bar_kind == kind then
		return
	end
	if C.bar then
		local kept = {}
		for _, row in ipairs(C.rows) do
			if row.menu then
				kept[#kept + 1] = row
			end
		end
		C.rows = kept
		C.bar:Remove()
		C.abar:Remove()
		C.lbar:Remove()
	end
	C.bar_kind = kind
	C.touch_held = {}
	C.touch_axis = {}
	-- (the stack's order, top to bottom: rank 1 the app's and Exit, half
	-- high; 2 the movement's; 3 Brake; 4 Gas, under the thumb; 5 the
	-- movement's low ones)
	local list = {}
	if touch_kind() == "drive" then
		list[#list + 1] = {"Brake", function() C.gas = -1 end,
			function() C.gas = 0 end, rank = 3}
		list[#list + 1] = {"Gas", function() C.gas = 1 end,
			function() C.gas = 0 end, rank = 4}
	end
	if tb then
		for _, b in ipairs(tb) do
			local input = b[2]
			list[#list + 1] = {b[1], function() C.touch_held[input] = true end,
				function() C.touch_held[input] = nil end, rank = b.low and 5 or 2}
		end
	elseif touch_kind() ~= "tap" and touch_kind() ~= "drive" then
		list[#list + 1] = {"Jump", nil, function() C.touch_jump = true end, rank = 2}
	end
	if M.seated() then
		list[#list + 1] = {"Exit", nil, exit_seat, rank = 1, half = true}
	end
	for _, b in ipairs(not edit and O.buttons or {}) do
		list[#list + 1] = {b[1], nil, b[2], rank = 1, half = true}
	end
	-- [KIT_INPUT_ACTIONS] the world's actions, held while pressed: a row
	-- of their own above (the bar not reaching into the app's help line)
	local acts = {}
	for _, a in ipairs(not edit and M.world_actions() or {}) do
		local name = a.name
		acts[#acts + 1] = {a.label ~= "" and a.label or name,
			function() M.press_action(name, true) end,
			function() M.press_action(name, false) end}
	end
	local lefts = {}
	for _, b in ipairs(not edit and ax or {}) do
		local input, v = b[2], b[3]
		lefts[#lefts + 1] = {b[1], function() C.touch_axis[input] = v end,
			function() if C.touch_axis[input] == v then C.touch_axis[input] = nil end end}
	end
	-- [KIT_TOUCH_THUMBS] The thumbs' side: thumb(), less where the stack
	-- would be over 0.92 of the height (a landscape phone's; (4z37i) in
	-- edit, the world's), 40 at least
	local col = {}
	for rank = 1, 5 do
		for _, b in ipairs(list) do
			if b.rank == rank then
				col[#col + 1] = b
			end
		end
	end
	local full, half = 0, 0
	for _, b in ipairs(col) do
		if b.half then half = half + 1 else full = full + 1 end
	end
	local high = edit and wr[4] / magic.ui.scale or root.height
	local room = high * 0.92 - 16 - 12 - 4 * math.max(0, #col - 1)
	local s = math.max(40, math.floor(math.min(thumb(),
			room / math.max(1, full + half / 2))))
	C.thumb = s
	C.bar = button_row(col, 8, nil, s)
	if edit then
		C.abar = button_row({}, 8)
		C.lbar = button_row({}, 8)
	else
		-- (the world's actions over it where they fit, else beside it in
		-- as many columns as they take, the first rightmost)
		local avail = root.height * 0.92 - 16
		local over = C.bar.height + 6 + 12 + #acts * (s + 4) - 4 <= avail
		local per = math.max(1, math.floor((avail - 8) / (s + 4)))
		C.abar = magic.ui.root:CreateChild("UIElement")
		C.abar:SetAlignment(magic.HA_RIGHT, magic.VA_BOTTOM)
		C.abar:SetPosition(over and -8 or -8 - C.bar.width - 6,
				over and -(8 + C.bar.height + 6) or -8)
		C.abar.visible = #acts > 0
		local w, h = 0, 0
		for i = 1, #acts, per do
			local part = {}
			for j = i, math.min(#acts, i + per - 1) do
				part[#part + 1] = acts[j]
			end
			local col = button_row(part, 0, nil, s, C.abar)
			C.rows[#C.rows].outer = C.abar
			col:SetPosition(-w, 0)
			w, h = w + col.width + 6, math.max(h, col.height)
		end
		C.abar:SetFixedSize(math.max(0, w - 6), h)
		C.lbar = button_row(lefts, 8, nil, s)
		C.lbar:SetAlignment(magic.HA_LEFT, magic.VA_BOTTOM)
		C.lbar:SetPosition(8, -8)
	end
	C.bar_at = nil
	log:info("kit: the touch bar: " .. labels(list) .. "; the world's: " ..
			labels(acts) .. (#lefts > 0 and "; the left: " .. labels(lefts) or ""))
end

-- [KIT_TEXT_PLACEHOLDER] The on-screen control an action is on in play, as
-- make_bar() labels it (nil: none), for kit.key_text's {key:<action>} on
-- a touchscreen: the movement's touch_buttons and touch_axes,
-- Gas and Brake, Jump, Exit, the world's actions; the stick for walking
function M.touch_label(id)
	local kind = touch_kind()
	if id == "use" then
		return "Tap"
	elseif id == "exit" then
		return M.seated() and "Exit" or nil
	end
	local tb = touch_buttons()
	for _, b in ipairs(tb or {}) do
		if b[2] == id then
			return b[1]
		end
	end
	if id == "jump" then
		return not tb and kind ~= "tap" and kind ~= "drive" and "Jump" or nil
	end
	local axis = ({forward = {"f", 1}, back = {"f", -1}, right = {"r", 1},
		left = {"r", -1}})[id]
	if axis then
		for _, b in ipairs(touch_axes()) do
			if b[2] == axis[1] and b[3] * axis[2] > 0 then
				return b[1]
			end
		end
		if kind == "drive" and axis[1] == "f" then
			return axis[2] > 0 and "Gas" or "Brake"
		end
		return kind ~= "tap" and "the stick" or nil
	end
	for _, a in ipairs(M.world_actions()) do
		if a.name == id then
			return a.label ~= "" and a.label or a.name
		end
	end
	return nil
end

-- [KIT_UI_COMPONENTS] Their top (UI y; nil: none): a UI component at the
-- bottom stays over them; [KIT_TOUCH_THUMBS] with x0, x1 (UI) those over
-- that stretch only (the stacks stand in the corners)
local function bars()
	return {C.bar or false, C.abar or false, C.lbar or false, C.mbar or false}
end
function M.touch_bar_top(x0, x1)
	local y = nil
	-- ([KIT_SCENE_PACKAGES] the Menu over a full screen too: the screen above it)
	for _, b in ipairs(bars()) do
		local p = b and b.visible and b.screenPosition
		if p and (not x0 or (p.x < x1 and p.x + b.width > x0)) then
			y = math.min(y or p.y, p.y)
		end
	end
	return y
end

-- [KIT_TOUCH_HELP_JUMP] Where the touch bars begin at the lower right
-- (UI units), the leftmost of those shown; nil with none: an app's help
-- line ends before it ([KIT_TOUCH_THUMBS] and the stack at the lower left:
-- kit.touch_left_top())
function M.touch_bar_left()
	local x = nil
	for _, b in ipairs({C.bar or false, C.abar or false, C.mbar or false}) do
		if b and b.visible then
			x = math.min(x or b.screenPosition.x, b.screenPosition.x)
		end
	end
	return x
end
-- [KIT_TOUCH_THUMBS] The top and the right (UI) of the stack at the lower
-- left, nil: none
function M.touch_left_top()
	if not (C.lbar and C.lbar.visible) then
		return nil
	end
	local p = C.lbar.screenPosition
	return p.y, p.x + C.lbar.width
end

if TOUCH then
	-- [KIT_TOUCH_THUMBS] A mouse's left button on a bar's button (a touch
	-- screen with a mouse, a scripted click), not a finger's mouse the
	-- platform makes of it: none within half a second of a finger
	magic.SubscribeToEvent("MouseButtonDown", function(_, data)
		if data:GetInt("Button") ~= magic.MOUSEB_LEFT or
				buildat.get_time_us() - (C.touch_us or -1e9) < 500000 then
			return
		end
		local mp = magic.input:GetMousePosition()
		C.mouse_btn = touch_button(mp.x, mp.y)
		if C.mouse_btn and C.mouse_btn[2] then
			C.mouse_btn[2]()
		end
	end)
	magic.SubscribeToEvent("MouseButtonUp", function(_, data)
		local b = data:GetInt("Button") == magic.MOUSEB_LEFT and C.mouse_btn
		if b then
			C.mouse_btn = nil
			b[3]()
		end
	end)
	magic.SubscribeToEvent("TouchBegin", function(_, data)
		C.touch_us = buildat.get_time_us()
		if not C.on then
			return
		end
		local id, x, y = data:GetInt("TouchID"), data:GetInt("X"),
				data:GetInt("Y")
		local f = {x = x, y = y, x0 = x, y0 = y, t0 = buildat.get_time_us(),
			ui = on_ui(x, y)}
		C.fingers[id] = f
		-- [KIT_TOUCH_THUMBS] a bar's button: this finger's till it lifts
		f.btn, f.side = touch_button(x, y)
		if f.btn then
			f.ui = true
			log:info("kit: touch button " .. f.btn[1] .. " down by finger " .. id)
			if f.btn[2] then
				f.btn[2]()
			end
			return
		end
		if f.ui or (E.editing and M.view() ~= "walk") then
			f.ui = true
			return
		end
		-- [KIT_PHONE_EDITING] stage 4b: walking in the editor's touch mode,
		-- the stick in the world's lower left, a finger on the selection
		-- the editor's (editor_input.lua's walk_finger)
		local wk = E.editing and M.walk_finger(x, y)
		if wk == "edit" then
			f.ui = true
			return
		elseif wk then
			if wk == "stick" and not C.stick and touch_kind() ~= "tap" then
				f.stick = true
				C.stick = {f = 0, r = 0}
				local p = pos_of(C.s)
				log:info(string.format("kit: the stick down, the body at %s",
						p and string.format("%.2f,%.2f,%.2f", p[1], p[2], p[3]) or "none"))
			end
			return
		end
		-- ([KIT_TOUCH_THUMBS] the stick's room right of the stack at the lower
		-- left: a finger on the stack is its button's, on_ui)
		local w, h = screen()
		local lw = C.lbar and C.lbar.visible and C.lbar.width * magic.ui.scale or 0
		if not C.stick and touch_kind() ~= "tap" and x < w * 0.45 + lw and
				y > h * 0.55 then
			f.stick = true
			C.stick = {f = 0, r = 0}
			return
		end
		-- [KIT_TOUCH_THUMBS] (4) A second free finger: the two pinch the zoom
		-- (a chase, top-down or side camera's, as the wheel)
		if camera_mode() ~= "first_person" and not E.editing then
			for oid, g in pairs(C.fingers) do
				if oid ~= id and not g.ui and not g.stick then
					C.pinch = {a = oid, b = id, d0 = math.max(1, math.sqrt(
						(x - g.x) ^ 2 + (y - g.y) ^ 2)), z0 = C.zoom}
					f.moved, g.moved = true, true
					break
				end
			end
		end
	end)
	magic.SubscribeToEvent("TouchMove", function(_, data)
		local f = C.fingers[data:GetInt("TouchID")]
		if not f then
			return
		end
		local x, y = data:GetInt("X"), data:GetInt("Y")
		f.x, f.y = x, y
		-- [KIT_TOUCH_THUMBS] A held button's finger slid onto another held
		-- button of its stack (Gas to Brake, Left to Right): that one's now;
		-- onto nothing, still the old one's. Only buttons held while pressed
		-- (a press handler): Jump, Exit and the app's act as they lift
		if f.btn and f.btn[2] then
			local b, side = touch_button(x, y)
			if b and b ~= f.btn and b[2] and side == f.side then
				local id = data:GetInt("TouchID")
				log:info(string.format("kit: touch button %s up by finger %d at %d,%d " ..
						"(slid onto %s)", f.btn[1], id, x, y, b[1]))
				f.btn[3]()
				f.btn = b
				log:info("kit: touch button " .. b[1] .. " down by finger " .. id)
				b[2]()
			end
		end
		if f.ui then
			return
		end
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
		local pn = C.pinch
		local a, b = pn and C.fingers[pn.a], pn and C.fingers[pn.b]
		if a and b then
			-- (spread: nearer, as the wheel up)
			set_zoom(pn.z0 * pn.d0 / math.max(1, math.sqrt((a.x - b.x) ^ 2 +
					(a.y - b.y) ^ 2)))
			return
		end
		-- The mouse sensitivity's, at half of 0.2 (floorplanner's)
		if M.view_turns() then
			C.yaw = C.yaw + data:GetInt("DX") * 0.1
			C.pitch = math.max(-89, math.min(89, C.pitch + data:GetInt("DY") * 0.1))
		end
	end)
	magic.SubscribeToEvent("TouchEnd", function(_, data)
		C.touch_us = buildat.get_time_us()
		local id = data:GetInt("TouchID")
		local f = C.fingers[id]
		C.fingers[id] = nil
		if not f then
			return
		end
		if f.btn then
			log:info(string.format("kit: touch button %s up by finger %d at %d,%d",
					f.btn[1], id, f.x, f.y))
			f.btn[3]()
		end
		if f.stick then
			C.stick = nil
		end
		if C.pinch and (C.pinch.a == id or C.pinch.b == id) then
			C.pinch = nil
			log:info(string.format("kit: pinched the zoom to %.3f", C.zoom))
		end
		-- (the editor's touch mode walking: for a check)
		if E.editing and (f.stick or (f.moved and not f.ui)) then
			local p = pos_of(C.s)
			log:info(string.format("kit: %s let go: the body at %s, the view's yaw %.1f, pitch %.1f",
					f.stick and "the stick" or "a look", p and string.format(
					"%.2f,%.2f,%.2f", p[1], p[2], p[3]) or "none", C.yaw % 360, C.pitch))
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

-- [KIT_SHIP_VIEW] A seated player's lines of sight ({from, direction...}; nil:
-- none) through the craft ridden: its looks within SEE_MARGIN m of one, up to
-- SEE_LEN m ahead, drawn faded (module.lua's own_look), but for the seat and the
-- vehicle it drives (a ship's sail over the captain's view, not the gunner's cannon)
local SEE_LEN, SEE_MARGIN = 40, 0.5
local seen = {}
-- Whether a line from o along dir crosses the box of half sizes h about 0
local function crosses(o, dir, h)
	local t0, t1 = 0, SEE_LEN
	for _, k in ipairs({"x", "y", "z"}) do
		local lo, hi = -h[k] - SEE_MARGIN, h[k] + SEE_MARGIN
		if math.abs(dir[k]) < 1e-6 then
			if o[k] < lo or o[k] > hi then
				return false
			end
		else
			local a, b = (lo - o[k]) / dir[k], (hi - o[k]) / dir[k]
			if a > b then
				a, b = b, a
			end
			t0, t1 = math.max(t0, a), math.min(t1, b)
		end
	end
	return t0 <= t1
end
local function see_through(sight)
	local root = sight and craft()
	local seat = M.seated()
	local v = seat and M.vehicle_of(seat)
	local now = {}
	for id, n in pairs(root and P.nodes or {}) do
		if n.body and id ~= seat and id ~= v and not (type(n.show) == "table" and
				n.show.player) and under(root, id, n) then
			local m = n.body.worldTransform
			local q = m:Rotation()
			local inv = magic.Quaternion(q.w, -q.x, -q.y, -q.z)
			local o = inv * (sight[1] - m:Translation())
			local h = m:Scale() * 0.5
			for i = 2, #sight do
				if crosses(o, inv * sight[i], h) then
					now[id] = true
					break
				end
			end
		end
	end
	for id in pairs(seen) do
		local n = P.nodes[id]
		if n and not now[id] then
			n.see_through = nil
		end
	end
	for id in pairs(now) do
		P.nodes[id].see_through = true
	end
	seen = now
end

-- [KIT_SPECTATE_CAMERA] kit/controls' camera_target for this player (their
-- own, else everyone's): the point the camera follows or looks at, an
-- entity's (a player's body's middle as drawn, else its look's or node's
-- place) or a position; nil none, or the entity not here (another scene,
-- gone): the normal follow
local function target_point()
	local s = C.signals.camera_target
	local t = type(s) == "table" and type(s.targets) == "table" and s.targets or {}
	local v = t[tostring(P.you)]
	if v == nil then
		v = t[""]
	end
	local p, what = nil, "none"
	if type(v) == "table" then
		p = magic.Vector3(tonumber(v[1]) or 0, tonumber(v[2]) or 0, tonumber(v[3]) or 0)
		what = string.format("position %g,%g,%g", p.x, p.y, p.z)
	elseif (tonumber(v) or 0) > 0 then
		local id = tonumber(v)
		local n = P.nodes[id]
		local show = n and type(n.show) == "table" and n.show or {}
		if show.player then
			local f = M.body_at(id)
			p = f and f + magic.Vector3(0, bd_h() / 2, 0)
		elseif n then
			p = (n.look or n.node).worldPosition
		end
		what = "entity " .. id .. (p and "" or " not here")
	end
	if what ~= C.target_said then
		log:info("kit: camera target " .. what .. (p and string.format(
				" at %.2f,%.2f,%.2f", p.x, p.y, p.z) or "") ..
				(C.target_said and ", was " .. C.target_said or ""))
		C.target_said = what
	end
	return p
end

-- The view turned toward p from eye (camera_target's: the mouse's look held)
local function look_at(eye, p)
	local d = p - eye
	local l = math.sqrt(d.x * d.x + d.z * d.z)
	if l + math.abs(d.y) > 1e-3 then
		C.yaw = math.deg(math.atan2(d.x, d.z)) % 360
		C.pitch = math.max(-89, math.min(89, -math.deg(math.atan2(d.y, l))))
	end
end

-- [KIT_SIDE_LEAD] [KIT_TOP_DOWN] (6) The point the side or top_down camera
-- follows, in the view's two axes (u across the screen, v up it): the body's (bu,
-- bv) led by (lu, lv), at most half the view's half width hw and height hh off it,
-- the lead eased (most of the way in half a second); the view's middle held within
-- dead_zone of that (half of it along v). C[key .. "_at"] and C[key .. "_lead"]
-- kept between frames (log_body's)
local function follow_point(key, par, dt, bu, bv, lu, lv, hw, hh)
	lu = math.max(-hw / 2, math.min(hw / 2, lu))
	lv = math.max(-hh / 2, math.min(hh / 2, lv))
	local lead = C[key .. "_lead"] or {lu, lv}
	local k = 1 - math.exp(-dt / 0.15)
	lead = {lead[1] + (lu - lead[1]) * k, lead[2] + (lv - lead[2]) * k}
	C[key .. "_lead"] = lead
	local bx, by = bu + lead[1], bv + lead[2]
	local dz = tonumber(par.dead_zone) or 0
	local f = C[key .. "_at"]
	if not f or math.abs(bx - f[1]) > 30 or math.abs(by - f[2]) > 30 then
		f = {bx, by}
	end
	f[1] = math.max(bx - dz, math.min(bx + dz, f[1]))
	f[2] = math.max(by - dz * 0.5, math.min(by + dz * 0.5, f[2]))
	C[key .. "_at"] = f
	return f
end

-- [KIT_CHASE_HEADING] Behind the way the body points as drawn (no 30 Hz
-- steps), lag seconds behind it, at most half a turn a second: a spin
-- does not whip the view round. The heading, not the way it goes: in
-- reverse the view stays behind the nose. Another's body followed
-- (a target, spectating, own false): the turn kept. The view's yaw (C.yaw:
-- the input's and the body drawn) set and returned.
-- simplified: that body's own heading if a spectator wants it
local function follow_heading(dt, lag, own)
	if own then
		local want = C.draw_yaw or tonumber(C.s.yaw)
		local was = C.chase_yaw or want
		local d = ((want - was) % 360 + 540) % 360 - 180
		local most = 180 * dt
		C.chase_yaw = (was + math.max(-most, math.min(most,
				d * (1 - math.exp(-dt / lag))))) % 360
	end
	C.yaw = C.chase_yaw or C.yaw
	return C.yaw
end

local function place_camera(dt, at)
	local node = O.camera
	local cam = node:GetComponent("Camera")
	local par = params()
	local mode = camera_mode()
	C.placed = magic.time.frameNumber
	if C.shake_frame then
		log:info(string.format("kit: the camera placed shaken %.3f in frame %d " ..
				"(asked in frame %d)", C.shake, C.placed, C.shake_frame))
		C.shake_frame = nil
	end
	-- (the near clip a side camera moved)
	if C.near0 then
		cam.nearClip, C.near0 = C.near0, nil
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
	-- [KIT_SPECTATE_CAMERA] What the camera follows: the body; a game's
	-- camera_target (first person: looked at from the eye); out of play
	-- ([KIT_SPECTATE], players.lua) the one watched, or in first person a free
	-- camera or the watched one's eyes
	local follows = mode ~= "first_person"
	local tp = target_point()
	local who, sp, sr = M.spectate_view(dt, node.position, node.rotation, C.yaw,
			C.pitch, follows)
	local own = true
	if follows and tp then
		at, own = {tp.x, tp.y - bd_h() / 2, tp.z}, false
	elseif who and who ~= P.you then
		local f = M.body_at(who)
		if f then
			at, own = {f.x, f.y, f.z}, false
		end
	end
	C.follow = at
	C.chase_dist, C.fp_follow = nil, nil
	cam.orthographic = false
	if sp then
		if tp then
			look_at(sp, tp)
			sr = magic.Quaternion(C.pitch, C.yaw, 0)
		end
		C.cam = sp
		node.position = sh > 0 and sp + magic.Vector3(jitter(sh * 0.3),
				jitter(sh * 0.3), jitter(sh * 0.3)) or sp
		node.rotation = sr * magic.Quaternion(0, 0, roll)
		return mode
	end
	local want_pos, rot, sight
	-- ([KIT_STUNTS] a chase camera's world and what it looks at, for its
	-- smoothed place too)
	local chase_w, chase_at
	local la, lvel = tonumber(par.look_ahead) or 0, tonumber(par.look_velocity) or 0
	-- ([KIT_SPECTATE_CAMERA] no lead for another's body or a target)
	local leads = (la ~= 0 or lvel ~= 0) and C.s and own
	local vel = leads and type(C.s.vel) == "table" and C.s.vel or {}
	local aspect = magic.ui.root.width / math.max(1, magic.ui.root.height)
	if mode == "top_down" then
		-- [KIT_TOP_DOWN] (6) Following as the side camera does (follow_point) in
		-- the view's axes on the ground: across the screen (cos yaw, -sin yaw)
		-- and up it (sin yaw, cos yaw) in x, z; led the way the body faces
		-- (s.yaw; none: the way it goes) and goes
		local h = (tonumber(par.height) or 14) * C.zoom
		local pitch = tonumber(par.angle) or 60
		local yaw = tonumber(par.yaw) or 0
		rot = magic.Quaternion(pitch, yaw, roll)
		local d = rot * magic.Vector3(0, 0, 1)
		local c, s = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
		local lx, lz = 0, 0
		if leads then
			local vx, vz = tonumber(vel[1]) or 0, tonumber(vel[3]) or 0
			local sp = math.sqrt(vx * vx + vz * vz)
			local a = tonumber(C.s.yaw) and math.rad(tonumber(C.s.yaw))
			local fx = a and math.sin(a) or sp > 0.1 and vx / sp or 0
			local fz = a and math.cos(a) or sp > 0.1 and vz / sp or 0
			lx, lz = fx * la + vx * lvel, fz * la + vz * lvel
		end
		local hh = par.ortho == true and h / 2 or h * math.tan(math.rad(cam.fov) / 2)
		local f = follow_point("top", par, dt, at[1] * c - at[3] * s,
				at[1] * s + at[3] * c, lx * c - lz * s, lx * s + lz * c, hh * aspect, hh)
		local target = magic.Vector3(f[1] * c + f[2] * s + ox, at[2] + oy + 1,
				-f[1] * s + f[2] * c + oz)
		want_pos = target - d * h
		if par.ortho == true then
			cam.orthographic = true
			-- (set only as it changes: the side camera's below says why)
			if math.abs(cam.orthoSize - h) > 1e-4 then
				cam.orthoSize = h
			end
		end
	elseif mode == "side" then
		-- [KIT_PLANE] Across the plane from the body, looking along +z (x right, y
		-- up), level, never turning; following once the body is dead_zone m off
		-- the view's middle (half that up and down); what is nearer than side_clip
		-- in front of the plane clipped (the near clip there; 0.55: the plane's
		-- layer's front, stage 3's foreground polygons want more). Ortho: the
		-- height perspective shows at the plane.
		-- simplified: as the editor's Front view, no caps: a cell of the layer
		-- behind a solid one has no face toward the view
		local dist = (tonumber(par.distance) or 6) * C.zoom
		-- [KIT_SIDE_LEAD] the point followed led the way the body faces
		-- (s.yaw: degrees from +z toward +x) and goes (s.vel) (follow_point)
		-- simplified: the view's size from its perspective at the plane (ortho's
		-- is the same)
		local lx, ly = 0, 0
		if leads then
			lx = math.sin(math.rad(tonumber(C.s.yaw) or 0)) * la +
					(tonumber(vel[1]) or 0) * lvel
			ly = (tonumber(vel[2]) or 0) * lvel
		end
		local hh = dist * math.tan(math.rad(cam.fov) / 2)
		local f = follow_point("side", par, dt, at[1], at[2] + (tonumber(bd.h) or 1.7) *
				0.5, lx, ly, hh * aspect, hh)
		local pz = plane_z() or at[3]
		local clip = math.min(dist, tonumber(par.side_clip) or 0.55)
		rot = magic.Quaternion(0, 0, roll)
		want_pos = magic.Vector3(f[1] + ox, f[2] + oy, pz - dist + oz)
		if par.ortho == true then
			-- (an ortho camera's near clip is 0 in Urho3D: it sits at the clip.
			-- Its size set only as it changes: a set makes its aspect 1 until the
			-- next frame's view, and kit_point_at's WorldToScreenPoint was off)
			cam.orthographic = true
			local size = 2 * dist * math.tan(math.rad(cam.fov) / 2)
			if math.abs(cam.orthoSize - size) > 1e-4 then
				cam.orthoSize = size
			end
			want_pos = magic.Vector3(want_pos.x, want_pos.y, pz - clip)
		else
			C.near0 = cam.nearClip
			cam.nearClip = math.max(C.near0, dist - oz - clip)
		end
	elseif mode == "chase" then
		local dist = (tonumber(decl().camera_distance) or tonumber(par.distance) or 6) *
				C.zoom
		local yaw = C.yaw
		local pitch = math.max(-10, math.min(80, C.pitch + 15))
		local lag = chase_follow(true)
		-- A vehicle's view behind it, turning as it turns
		if own and M.seated() and C.s and tonumber(C.s.yaw) then
			C.chase_yaw = lerp_yaw(C.chase_yaw or C.s.yaw, C.draw_yaw or C.s.yaw,
					1 - math.exp(-dt / 0.25))
			yaw = C.chase_yaw
		elseif lag then
			yaw = follow_heading(dt, lag, own)
			pitch = tonumber(par.chase_pitch) or 15
		end
		rot = magic.Quaternion(pitch, yaw, roll)
		if C.tilt then
			rot = C.tilt * rot
		end
		local d = rot * magic.Vector3(0, 0, 1)
		local h = tonumber(bd.h) or 1.7
		local off = magic.Vector3(ox, h * 0.8 + oy + (tonumber(decl().camera_up) or 0), oz)
		if C.tilt then
			off = C.tilt * off
		end
		local target = magic.Vector3(at[1] + off.x, at[2] + off.y, at[3] + off.z)
		-- Not through a wall: in front of what is between ([KIT_SHIP_VIEW] the craft
		-- ridden not counted: a ship's rail put the gunner's view in at the gun)
		local root = craft()
		local w = world(root and function(id, n) return under(root, id, n) end)
		local t = w:ray(target.x, target.y, target.z, -d.x, -d.y, -d.z, dist)
		if t then
			dist = math.max(0.3, t - 0.2)
		end
		want_pos = target - d * dist
		chase_w, chase_at = w, target
		-- (where the camera looks, and level ahead: where a ship goes)
		sight = {target, d, magic.Vector3(d.x, 0, d.z):Normalized()}
		C.chase_dist = dist
	else
		local off = magic.Vector3(ox, (tonumber(bd.eye) or 1.5487) + oy, oz)
		if C.tilt then
			off = C.tilt * off
		end
		want_pos = magic.Vector3(at[1] + off.x, at[2] + off.y, at[3] + off.z)
		-- ([KIT_SPECTATE_CAMERA] a camera_target looked at, untilted)
		if tp then
			look_at(want_pos, tp)
		elseif chase_follow(true) then
			-- [KIT_PARAM_AUDIT] the eye turned as the chase is, looking level
			follow_heading(dt, chase_follow(true), own)
			C.pitch, C.fp_follow = 0, true
		end
		rot = magic.Quaternion(C.pitch, C.yaw, roll)
		if C.tilt and not tp then
			rot = C.tilt * rot
		end
		local d = rot * magic.Vector3(0, 0, 1)
		sight = {want_pos, d, magic.Vector3(d.x, 0, d.z):Normalized()}
	end
	see_through(sight)
	-- Smoothed where the camera is not an eye
	local sm = tonumber(par.smoothing) or 0
	if mode ~= "first_person" and sm > 0 and C.cam then
		local k = 1 - math.exp(-dt / sm)
		want_pos = C.cam + (want_pos - C.cam) * k
		-- [KIT_STUNTS] (G4) a chase camera catching up is not through a wall
		-- either (a car into a tunnel under a deck: the camera above it came
		-- down through the deck)
		local dv = chase_w and want_pos - chase_at
		local l = dv and dv:Length() or 0
		if l > 0.3 then
			local t = chase_w:ray(chase_at.x, chase_at.y, chase_at.z, dv.x / l, dv.y / l,
					dv.z / l, l)
			if t then
				want_pos = chase_at + dv * (math.max(0.3, t - 0.2) / l)
			end
		end
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

-- ---- [KIT_GUIDE_STATIONS] The impact marker: riding a gun (its movement's
-- station "gun", kit/turret), where its shot would land from the gun as drawn,
-- its shot_speed and shot_gravity (move.lua's M.impact, by the arc kit/bot
-- aims with): a disc there, grey where the arc ends meeting nothing, and dots
-- along the arc. "event kit_impact" logs it: "kit: impact at <x> <y> <z>
-- (hit|none)". [KIT_STATIONS_LEFTOVERS] As kit.cpp's projectiles: a solid
-- voxel or water stops it, a cell not loaded does not (past the server's
-- loaded terrain the shot flies on: no hit), nor does the gun's own ship;
-- another ship's hull and an entity with health or a player do (kit.cpp
-- ray_target's boxes). simplified: a player or bot standing on the gun's own
-- ship stops the marker (the server's shot passes them); add kit.cpp's
-- aboard() here if crews stand in front of their guns
local IMPACT_DOTS, IMPACT_EVERY = 12, 0.1
local impact = nil
local impact_water = {}
local function impact_solid(i, j, k)
	local v = voxelworld.get_static_voxel(magic.Vector3(i, j, k))
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return false
	end
	if impact_water[id] == nil then
		-- Kit's water kind: edge material 10 (terrain.h)
		local def = reg:get_by_id(id)
		impact_water[id] = def ~= nil and def.edge_material_id == 10
	end
	return impact_water[id] or voxel_info(id, v) ~= nil
end
-- What else a shot meets on a chord from a to b: its fraction 0...1 or nil
local function impact_seg()
	local root = craft()
	local boxes = {}
	for id, n in pairs(P.nodes) do
		local s = type(n.show) == "table" and n.show or {}
		if (s.health or s.player) and id ~= P.you and
				not (root and under(root, id, n)) then
			local p = n.node.worldPosition
			local r = s.player and 0.35 or 0.5
			boxes[#boxes + 1] = {p.x - r, p.y - (s.player and 0.5 or r), p.z - r,
				p.x + r, p.y + (s.player and 1.2 or r), p.z + r}
		end
	end
	local w = C.pose_world
	if w and C.draw_t then
		w:pose_at(C.draw_t)
	end
	return function(ax, ay, az, bx, by, bz)
		local o, d = {ax, ay, az}, {bx - ax, by - ay, bz - az}
		local len = math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
		local best = nil
		if w and #w.turned > 0 and len > 1e-9 then
			local t = w:ray_objects(ax, ay, az, d[1], d[2], d[3], len, root)
			best = t and t / len
		end
		for _, b in ipairs(boxes) do
			-- The chord's entry into the box (slabs: t along d, 0...1)
			local t0, t1 = 0, 1
			for q = 1, 3 do
				if math.abs(d[q]) < 1e-9 then
					if o[q] < b[q] or o[q] > b[q + 3] then
						t0 = 2
					end
				else
					local a1, a2 = (b[q] - o[q]) / d[q], (b[q + 3] - o[q]) / d[q]
					if a1 > a2 then
						a1, a2 = a2, a1
					end
					t0, t1 = math.max(t0, a1), math.min(t1, a2)
				end
			end
			if t0 <= t1 and (not best or t0 < best) then
				best = t0
			end
		end
		return best
	end
end
-- The gun ridden's shot: its muzzle (a metre out of its front, kit.cpp's
-- drive_shot), facing, the point and whether it hit; nil: no gun ridden
local function impact_now()
	local r = M.riding()
	local n = r and decl().station == "gun" and P.nodes[r]
	if not n then
		return nil
	end
	local p = move().params or {}
	local d = n.node.worldDirection
	local o = n.node.worldPosition + d
	local v, g = tonumber(p.shot_speed) or 40, tonumber(p.shot_gravity) or 9.8
	local x, y, z, hit = MV.impact(v, g, 4, {o.x, o.y, o.z}, {d.x, d.y, d.z},
			impact_solid, 0.25, impact_seg())
	return {o = o, d = d, v = v, g = g, at = magic.Vector3(x, y, z), hit = hit}
end
local function impact_marker(dt)
	local scene = replicate.main_scene
	if impact and impact.t > 0 and M.riding() then
		impact.t = impact.t - dt
		return
	end
	local i = scene and impact_now()
	if not i then
		if impact then
			impact.node:Remove()
			impact = nil
			log:info("kit: impact marker off")
		end
		return
	end
	if not impact then
		local node = scene:CreateChild("kit_impact")
		local function part(size, col)
			local c = node:CreateChild("part")
			c.scale = magic.Vector3(size[1], size[2], size[3])
			local m = c:CreateComponent("StaticModel")
			m.model = magic.cache:GetResource("Model", size[4] or "Models/Box.mdl")
			m.material = K.material("glow")
			m.material:SetShaderParameter("MatDiffColor", col)
			m.castShadows = false
			return c, m
		end
		impact = {node = node, t = 0, dots = {}}
		impact.disc, impact.disc_m = part({1.4, 0.06, 1.4, "Models/Cylinder.mdl"},
				magic.Color(1, 0.6, 0.1))
		for k = 1, IMPACT_DOTS do
			impact.dots[k] = part({0.12, 0.12, 0.12}, magic.Color(1, 0.85, 0.4))
		end
		log:info("kit: impact marker on")
	end
	impact.t = IMPACT_EVERY
	impact.disc.position = i.at + magic.Vector3(0, 0.05, 0)
	impact.disc_m.material:SetShaderParameter("MatDiffColor", i.hit and
			magic.Color(1, 0.6, 0.1) or magic.Color(0.45, 0.45, 0.45))
	-- The dots along the arc to it
	local h = math.sqrt(i.d.x * i.d.x + i.d.z * i.d.z)
	local a = MV.atan2(i.d.y, h)
	local far = math.sqrt((i.at.x - i.o.x) ^ 2 + (i.at.z - i.o.z) ^ 2)
	for k, dot in ipairs(impact.dots) do
		local s = far * k / (IMPACT_DOTS + 1)
		local y = h > 1e-6 and MV.arc(i.v, i.g, a, s) or 0
		dot.position = magic.Vector3(i.o.x + i.d.x / math.max(h, 1e-6) * s,
				i.o.y + y, i.o.z + i.d.z / math.max(h, 1e-6) * s)
	end
end

magic.SubscribeToEvent("command_seq:kit_impact", function()
	local i = impact_now()
	if not i then
		log:info("kit: impact: no gun ridden")
		return
	end
	log:info(string.format("kit: impact at %.2f %.2f %.2f (%s) from %.2f %.2f %.2f",
			i.at.x, i.at.y, i.at.z, i.hit and "hit" or "none", i.o.x, i.o.y, i.o.z))
end)

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
	if walking() and not paused() and not TOUCH and M.view_turns() then
		if not M.pointer_free() and (not E.editing or M.looking()) then
			mx, my = ui_utils.mouse_look_move()
		elseif magic.input:GetMouseButtonDown(magic.MOUSEB_RIGHT) then
			local m = magic.input:GetMouseMove()
			mx, my = m.x, m.y
		end
	end
	-- The gamepad's right stick: 120 degrees a second at full
	if walking() and not paused() and M.view_turns() then
		mx = mx + M.pad_axis(2) * 1200 * dt
		my = my + M.pad_axis(3) * 1200 * dt
	end
	C.yaw = (C.yaw + mx * 0.1) % 360
	C.pitch = math.max(-89, math.min(89, C.pitch + my * 0.1))
	if TOUCH then
		local wr = E.editing and M.view() == "walk" and M.touch_world and
				M.touch_world() or nil
		make_bar(wr)
		-- ([KIT_LOBBY] none over a full screen)
		local full = M.full_screen and M.full_screen()
		C.bar.visible = (not E.editing and not full) or
				(wr ~= nil and C.bar:GetNumChildren() > 0)
		C.abar.visible = not E.editing and not full and #M.world_actions() > 0
		C.lbar.visible = not E.editing and not full and C.lbar:GetNumChildren() > 0
		-- [KIT_SCENE_PACKAGES] Over a full screen (the touch bar hidden) the
		-- app's pause menu a Menu button of Kit's own at the bar's corner,
		-- unless the screen has a button of its own for it
		local mo = full and not E.editing and E.menu and not E.menu.shown() and
				not (M.full_screen_menu and M.full_screen_menu()) and true or false
		if mo and not C.mbar then
			C.mbar = button_row({{"Menu", nil, function()
				if E.menu then
					log:info("kit: the touch Menu over the full screen pressed")
					E.menu.open()
				end
			end}}, 8)
			C.rows[#C.rows].menu = true
			C.mbar.visible = false
		end
		if C.mbar and C.mbar.visible ~= mo then
			C.mbar.visible = mo
			log:info("kit: the touch Menu over the full screen " ..
					(mo and "shown" or "hidden"))
		end
		-- (alignment right and bottom: from the root's corner, UI units)
		local sc, r = magic.ui.scale, magic.ui.root
		local at = wr and string.format("%d %d",
				-math.floor(r.width - (wr[1] + wr[3]) / sc + 8),
				-math.floor(r.height - (wr[2] + wr[4]) / sc + 8)) or "-8 -8"
		if C.bar_at ~= at then
			C.bar_at = at
			local bx, by = at:match("(%S+) (%S+)")
			C.bar:SetPosition(tonumber(bx), tonumber(by))
			if wr then
				local p = C.bar.screenPosition
				local mm = C.thumb * sc / math.max(0.1, tonumber(buildat.display_density and
						buildat.display_density()) or 1) / 160 * 25.4
				log:info(string.format("kit: the touch bar in the world at %d %d %d %d, " ..
						"side %d (%.1f mm)", p.x * sc, p.y * sc, C.bar.width * sc,
						C.bar.height * sc, C.thumb * sc, mm))
			else
				-- (for a check: the stacks' rects, pixels, and the side in
				-- CSS pixels and in mm at thumb()'s 160 an inch)
				local function rect(b)
					local p = b.screenPosition
					return string.format("%d %d %d %d", p.x * sc, p.y * sc,
							b.width * sc, b.height * sc)
				end
				local per = sc / math.max(0.1, tonumber(
						buildat.display_density and buildat.display_density()) or 1)
				local css, pitch = C.thumb * per, (C.thumb + THUMB_GAP) * per
				log:info(string.format("kit: the touch stacks of %dx%d: side %d " ..
						"(%.0f CSS px, %.1f mm), pitch %.0f CSS px (%.1f mm); " ..
						"right %s; world's %s; left %s",
						r.width * sc, r.height * sc, C.thumb * sc, css,
						css / 160 * 25.4, pitch, pitch / 160 * 25.4, rect(C.bar),
						rect(C.abar), rect(C.lbar)))
			end
		end
	end
	zoom_tick()
	-- The steps
	local riding = M.riding()
	if C.s and not C.ready and (riding or floor_ready()) then
		C.ready = true
		log:info("player physics enabled")
	end
	local step_len = 1 / rate()
	if C.s and C.ready and (C.def or riding) then
		-- [KIT_TEMPLATE_ROUGH_EDGES] A jump pressed (down and up) in a frame
		-- with no step is kept for the next step, as a touch's is
		if M.key_press("jump") then
			C.touch_jump = true
		end
		C.acc = C.acc + dt
		local n = 0
		local w = nil
		while C.acc >= step_len and n < 8 do
			C.acc = C.acc - step_len
			n = n + 1
			w = w or (not riding and world() or nil)
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
			if not riding then
				step(C.s, i, w)
				C.pending[#C.pending + 1] = {C.seq, i, copy(C.s)}
			end
			-- [KIT_PLAYER_MODEL] and the pitch, the swings and the dig
			-- others see on this body
			C.out[#C.out + 1] = string.format("%d %s %s %s %d %d %s %s %s " ..
					"%s %d %d", C.seq, i.f, i.r, i.yaw, i.jump, i.go, i.tx, i.ty,
					i.tz, fmt(C.pitch, 1), M.pose_swings or 0,
					M.dig_progress and M.dig_progress() and 1 or 0) ..
					(i.t and string.format(" %.0f", i.t) or ((i.down == 1 or
					i.auto == 1) and " 0" or "")) ..
					((i.down == 1 or i.auto == 1) and " " .. (i.down or 0) or "") ..
					(i.auto == 1 and " 1" or "")
			route_tick()
		end
		if C.acc > step_len then
			C.acc = 0
		end
		if n > 0 then
			C.touch_jump = false
		end
		-- [KIT_CLIENT_REACT] (1) the zones met where the steps left the body,
		-- before the server hears of the steps
		if n > 0 and M.update_zones then
			M.update_zones()
		end
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
	-- [KIT_VEHICLE_MOVEMENTS] Riding: the body where the seat is drawn
	local sn = riding and C.s and P.nodes[M.seated()]
	if sn then
		local p = sn.node.worldPosition
		C.s.pos = {p.x, p.y - 0.5, p.z}
		local d = sn.node.worldDirection
		C.s.yaw = math.deg(math.atan2(d.x, d.z)) % 360
		C.s.frame, C.s.at = nil, nil
		C.prev, C.prev_yaw = C.s.pos, C.s.yaw
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
	if seat and at and not riding then
		-- [KIT_VEHICLE_MOVEMENTS] the vehicle the seat is on or under
		P.pose[M.vehicle_of(seat)] = {at[1], at[2] + 0.5, at[3], C.draw_yaw or 0}
	end
	local mode = camera_mode()
	if at then
		place_camera(dt, at)
	end
	-- [KIT_PLAYER_MODEL] the players' bodies (players.lua): this one's
	-- where it is predicted, shown but in first person or in a seat
	-- ([KIT_PLANE] a side camera's facing the way it last went)
	M.draw_players(at, mode == "side" and input_yaw() or view_yaw(), C.pitch, bd_h(),
			mode ~= "first_person" and
			not seat and not M.spectating())
	impact_marker(dt)
	effects(dt)
end)

-- [KIT_PLANE] stage 4: the movement's draw hook (its client part's draw(s,
-- node, yaw, p): players.lua calls it for each body) and this body's state as
-- predicted, for it; [KIT_DRAWN_YAW] its yaw as drawn (degrees), between its
-- last two steps as its place is
function M.movement_draw()
	local part = C.type and P.parts[C.type]
	return type(part) == "table" and type(part.draw) == "function" and part.draw or nil
end
function M.body_state()
	return C.s
end
-- [KIT_MOVE_DRAW] the draw's p: the movement's parameters (the step's); the
-- pose's slot names (movement.pose, nil: none)
function M.movement_params()
	local m = move()
	return m and type(m.params) == "table" and m.params or {}
end
function M.movement_pose_names()
	return MV.pose_names(decl().pose)
end
function M.drawn_yaw()
	return C.draw_yaw
end

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
-- [KIT_AIRSHIPS] For a check: "event kit_obj_cell <id> <x> <y> <z>" logs whether that
-- cell of a free object's frame is solid in the boxes this client has
magic.SubscribeToEvent("command_seq:kit_obj_cell", function(_, data)
	local id, x, y, z = data:GetString("Param"):match("^(%d+) (%S+) (%S+) (%S+)")
	local ob = C.turned_by and C.turned_by[tonumber(id)]
	local c, solid = {tonumber(x), tonumber(y), tonumber(z)}, false
	for _, b in ipairs(ob and ob.b or {}) do
		if c[1] > b[1] and c[1] < b[4] and c[2] > b[2] and c[2] < b[5] and
				c[3] > b[3] and c[3] < b[6] then
			solid = true
		end
	end
	log:info(string.format("kit: object %s cell %s,%s,%s %s", tostring(id), x, y, z,
			not ob and "unknown" or solid and "solid" or "empty"))
end)
-- [KIT_AIRSHIPS] "event kit_point_obj <id> <x> <y> <z>": the same at a point in a
-- free object's frame (a deck's cell), followed as it moves; "event kit_point_obj"
-- lets go
magic.SubscribeToEvent("command_seq:kit_point_obj", function(_, data)
	local id, x, y, z = data:GetString("Param"):match("^(%d+) (%S+) (%S+) (%S+)")
	C.aim_obj = id and {tonumber(id), tonumber(x) or 0, tonumber(y) or 0,
		tonumber(z) or 0} or nil
	local ob = id and C.turned_by and C.turned_by[tonumber(id)]
	log:info("kit: pointing at " .. (id and x .. "," .. y .. "," .. z .. " on " .. id ..
			(ob and string.format(" (at %.2f,%.2f,%.2f)", ob.x, ob.y, ob.z) or
			" (unknown)") or "the pointer's own"))
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

-- [KIT_PHONE_EDITING] stage 4b: whether x, y (pixels) is on the touch bar
-- (the editor's over_ui: Jump is not a tap on the world)
function M.touch_bar_at(x, y)
	local b, sc = C.bar, magic.ui.scale
	if not (b and b.visible) then
		return false
	end
	local p, s = b.screenPosition, b.size
	return x / sc >= p.x and y / sc >= p.y and x / sc < p.x + s.x and
			y / sc < p.y + s.y
end
end
-- vim: set noet ts=4 sw=4:
