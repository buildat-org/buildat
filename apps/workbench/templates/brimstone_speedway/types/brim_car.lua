-- Brimstone Speedway's car: a movement (kit/controls' movement) for the
-- top-down view, stepped in kit/controls' plane "horizontal" (the body held
-- at its height, x and z the plane's 2D x and y). W gas, S brake and
-- reverse, A and D steer, Space fires what the car carries (the race's
-- weapon). Arcade: the speed along the heading pushed by the engine, the
-- speed across it bled away by the tyres' grip, so a car slides through a
-- turn as fast as the floor lets it.
-- The floor (w:under: a kit/polygon floor's surface under the car) sets the
-- grip: asphalt (any other surface) holds, "dirt" slides and slows, "oil"
-- barely steers, "boost" pushes it on; "finish" is the lap line.
-- [KIT_BODY_VARS] Read from s.vars (the race's c:body_var), here and in the
-- client's prediction alike:
--   lap_open: every checkpoint passed in order; the next touch of the
--     finish line is a lap: the event "lap" (the race counts it and
--     closes it again), once a crossing (s.on_line till it leaves it);
--   boost: the ram boost on (a faster top speed and a harder push);
--   wreck: wrecked, no control, rolling to a stop;
--   paint: its colour variant (1...6), drawn by brim_car.client.lua;
--   ghost: a time trial's car, meeting no other car.
-- [KIT_TOP_DOWN] (8) The other cars (movement.bodies: w:circle's hits with
-- info.body and info.vel) push it out of them, half the overlap each, and
-- trade the speed they close at; while boosted a hard enough one is the
-- event "ram" (value: the other's by). Each car is stepped apart (the
-- server's batches in any order), so each takes the other's speed before
-- the contact (s.vel is that) and gives up its own share: a car pushed
-- along keeps up with the one pushing.
-- Events (the movement's outputs, the race's inputs): lap, fire (Space
-- pressed; value: the heading), smash (a wall hit hard; value: the speed into it), ram.
-- Its state: s.c {x, z, vx, vz}, s.h the heading (radians from +z toward
-- +x, kit's yaw), s.pose what the clients draw: {heading, paint, steer,
-- flags (1 boosting, 2 wrecked, 4 sliding, 8 braking), slide speed}.
-- s.spheres two circles, front and back, as the zones (checkpoints,
-- crates, mines) meet it.
local R = 1.05 -- a car's circle against walls and cars (m)
local AX = 1.1 -- the zone circles' offset front and back
local BODY = {r = 1.05, h = 1.3, eye = 1}
local GRIP = {dirt = 0.35, oil = 0.05}
local DRAG = {dirt = 1.4, oil = 0.1}
local PI = math.pi
local NOVEL = {0, 0}

local function clamp(x, lo, hi)
	return x < lo and lo or x > hi and hi or x
end

local function start(s)
	local pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
	s.c = {pos[1], pos[3], 0, 0}
	s.h = (tonumber(s.yaw) or 0) * PI / 180
end

return {
	version = 1,
	about = {
		group = "Players",
		what = "Brimstone Speedway's car, seen from above: W gas, S brake, A and D steer, Space fires. Grip by the floor's surface: dirt, oil, boost; finish the lap line.",
		outputs = {
			lap = "Over the finish line with every checkpoint passed (the race's lap_open).",
			fire = "Space pressed: the race fires what the car carries. Value: the car's heading (degrees, kit's yaw).",
			smash = "A wall hit hard. Value: the speed into it.",
			ram = "A boosted car hit another. Value: the other's by.",
		},
	},
	root = true,
	outputs = {lap = "none", fire = "number", smash = "number", ram = "string"},
	movement = {body = BODY, raw_keys = true, touch = "drive", bodies = true,
		touch_buttons = {{"Fire", "jump"}},
		help = {{"[forward]/[back]", "gas, brake", "f"},
			{"[left]/[right]", "steer", "r"}, {"[jump]", "fire", "jump"}},
		touch_help = {{"Gas/Brake", "drive", "f"}, {"Stick", "steer", "r"},
			{"Fire", "fire", "jump"}}},
	params = {
		speed = {cat = "physics", type = "number", default = 24, min = 1,
			max = 80},
		accel = {cat = "physics", type = "number", default = 16, min = 1,
			max = 100},
		steer = {cat = "physics", type = "number", default = 2.6, min = 0.2,
			max = 10},
		grip = {cat = "physics", type = "number", default = 7, min = 0.1,
			max = 40},
		boost = {cat = "physics", type = "number", default = 1.45, min = 1,
			max = 3},
		rate = {cat = "advanced", type = "number", default = 60, min = 10,
			max = 120},
		substeps = {cat = "advanced", type = "number", default = 2, min = 1,
			max = 8},
	},
	step = function(s, i, dt, w, p)
		if type(s.c) ~= "table" then
			start(s)
		end
		local c = s.c
		local v = type(s.vars) == "table" and s.vars or {}
		local f, r = tonumber(i.f) or 0, tonumber(i.r) or 0
		if v.wreck or i.out_of_play then
			f, r = 0, 0
		end
		local sh, ch = math.sin(s.h), math.cos(s.h)
		-- Forward (sh, ch), right (ch, -sh): the speed along and across
		local vf = c[3] * sh + c[4] * ch
		local vs = c[3] * ch - c[4] * sh
		local y = type(s.pos) == "table" and tonumber(s.pos[2]) or 0
		local info = w:under(c[1], y + 0.1, c[2])
		local surf = info and info.surface or "asphalt"
		local grip = (p.grip or 7) * (GRIP[surf] or 1) *
				(info and tonumber(info.friction) or 1)
		local top = (p.speed or 24) * (v.boost and (p.boost or 1.45) or 1)
		local acc = (p.accel or 16) * (v.boost and 2 or 1)
		local flags = 0
		-- (c:speed(by, 0), the grid's freeze: held where it is)
		if top < 0.01 then
			f, r, vf, vs = 0, 0, 0, 0
		end
		if surf == "boost" and top > 0 then
			vf = vf + 30 * dt
			top = top * 1.4
		end
		if f > 0 then
			vf = vf + acc * f * dt * clamp(1 - vf / top, 0, 1) * 1.6
		elseif f < 0 then
			if vf > 0.5 then
				vf = math.max(0, vf + 34 * f * dt)
				flags = flags + 8
			else
				vf = math.max(-top * 0.3, vf + acc * 0.6 * f * dt)
			end
		end
		-- Rolling and the floor's drag
		local drag = 0.25 + (DRAG[surf] or 0)
		vf = vf * (1 - drag * dt)
		if f == 0 and math.abs(vf) < 0.3 then
			vf = 0
		end
		-- Steering, by the speed (none standing; backwards the other way)
		local turn = clamp(math.abs(vf) / 6, 0, 1) * (vf < 0 and -1 or 1)
		local lim = surf == "oil" and 0.35 or 1
		s.h = s.h + r * (p.steer or 2.6) * turn * lim * dt
		-- The tyres: the slide across bled away, less of it the faster
		local bleed = clamp(grip * dt / (1 + math.abs(vf) * 0.02), 0, 1)
		vs = vs * (1 - bleed)
		if math.abs(vs) > 2.5 then
			flags = flags + 4
		end
		sh, ch = math.sin(s.h), math.cos(s.h)
		c[3], c[4] = vf * sh + vs * ch, vf * ch - vs * sh
		c[1], c[2] = c[1] + c[3] * dt, c[2] + c[4] * dt
		-- Walls and (8) the other cars: out of them, the speed into them
		-- gone (a little bounce off a wall)
		local events = nil
		-- (s.vel: the speed before what it meets, the speed the other cars
		-- meet: a car that steps after this one is still hit as hard)
		local vx0, vz0 = c[3], c[4]
		for k, h in ipairs(w:circle(c[1], c[2], R)) do
			if k > 4 then
				break
			end
			local body = h.info and h.info.body
			if not (body and v.ghost) then
				local nx, ny = h.nx, h.ny
				local d = body and h.depth * 0.5 or h.depth
				c[1], c[2] = c[1] + nx * d, c[2] + ny * d
				-- (a car's closing speed: its velocity's less ours; each car takes
				-- half of it and a fifth more, as equal weights bouncing a little)
				local ov = body and h.info.vel or NOVEL
				local vn = (c[3] - ov[1]) * nx + (c[4] - ov[2]) * ny
				if vn < 0 then
					local e = body and 0.6 or 1.3
					c[3], c[4] = c[3] - nx * vn * e, c[4] - ny * vn * e
					if body and v.boost and -vn > 6 then
						events = events or {}
						events[#events + 1] = {"ram", tostring(body)}
					elseif not body and -vn > 12 then
						events = events or {}
						events[#events + 1] = {"smash", math.floor(-vn)}
					end
				end
			end
		end
		-- The lap line: once a crossing, with the lap open
		local on_line = surf == "finish"
		if on_line and not s.on_line and v.lap_open then
			events = events or {}
			events[#events + 1] = "lap"
		end
		s.on_line = on_line or nil
		if i.jump == 1 and not s.held and not v.wreck then
			events = events or {}
			-- (its heading: a player's yaw on the server is the camera's)
			events[#events + 1] = {"fire", math.floor(s.h * 1800 / PI + 0.5) / 10}
		end
		s.held = i.jump == 1
		s.events = events
		s.pos = {c[1], y, c[2]}
		s.vel = {vx0, 0, vz0}
		s.yaw = math.fmod(s.h * 180 / PI, 360)
		if v.boost then
			flags = flags + 1
		end
		if v.wreck then
			flags = flags + 2
		end
		s.pose = {s.h, tonumber(v.paint) or 1, r, flags, vs}
		s.spheres = {{sh * AX, 0.5, ch * AX, 0.9}, {-sh * AX, 0.5, -ch * AX, 0.9}}
	end,
}
