-- Brimstone Speedway's car: a movement (kit/controls' movement) for the
-- top-down view, stepped in kit/controls' plane "horizontal" (the body held
-- at its height, x and z the plane's 2D x and y). W gas, S brake and
-- reverse, A and D steer, Space the handbrake; the race's weapon fires on
-- its own key (the race's action "fire": Ctrl, the left mouse button).
-- A rigid body with a mass and a yaw inertia on four tyres (the user's
-- EDGM car, a Box2D truck, ported without Box2D): each tyre cancels the
-- speed across it at its place, up to a grip limit by the floor under it;
-- the driven rear ones grip more (weight), less under throttle, much less
-- under the handbrake, half braking; the front ones steer, their angle
-- falling with speed, rate-limited, released faster, with a counter-steer
-- of half the slide's angle. Air drag (the speed squared), rolling
-- resistance and each tyre's drag on the floor slow it, so the top speed
-- (`speed`) is approached slowly as the drag nears the engine's push.
-- The floor (w:under: a kit/polygon floor's surface under each tyre) sets
-- the grip and drag: dirt (and anything else: the track's ground), "mud",
-- "oil", "asphalt" holds best, "boost" pushes it on; "finish" is the lap
-- line (dirt to the tyres).
-- [KIT_BODY_VARS] Read from s.vars (the race's c:body_var), here and in the
-- client's prediction alike:
--   lap_open: every checkpoint passed in order; the next touch of the
--     finish line is a lap: the event "lap" (the race counts it and
--     closes it again), once a crossing (s.on_line till it leaves it);
--   boost: the ram boost on (a faster top speed and a harder push);
--   wreck: wrecked, no control, braked to a stop;
--   paint: its colour variant (1...6), drawn by brim_car.client.lua;
--   ghost: a time trial's car, meeting no other car;
--   fire: the race's count of its fire key's presses: a new one is the
--     event "fire" with the heading (the race's action has no heading).
-- [KIT_TOP_DOWN] (8) Two circles along the body meet the walls, one round
-- its middle (BODY.r) the other cars (movement.bodies: w:circle's hits with
-- info.body and info.vel); a hit is an impulse at the circle, so a corner
-- knocked turns the car. A wall: out of it, a bounce (WALL_E) and the scrape's friction
-- (WALL_MU). Another car: half the overlap each, and the speed they close
-- at traded as between equal masses; while boosted a hard enough one is
-- the event "ram" (value: the other's by). Each car is stepped apart (the
-- server's batches in any order), so each takes the other's speed before
-- the contact (s.vel is that) and gives up its own share, once each time
-- the other has stepped (s.met): a car pushed along keeps up with the one
-- pushing.
-- Events (the movement's outputs, the race's inputs): lap, fire (value: the
-- heading), smash (a wall hit hard; value: the speed into it), ram.
-- Its state: s.c {x, z, vx, vz}, s.h the heading (radians from +z toward
-- +x, kit's yaw), s.w its yaw rate, s.st the steering angle, s.bumps the
-- hard wall hits so far and s.bump_v the last one's speed (its client's
-- draw shakes on a new one), s.pose what the
-- clients draw: {heading, paint, steering, flags (1 boosting, 2 wrecked, 4
-- a tyre slipping much, 8 braking, 16 handbrake, 32 throttle, 64 and 128
-- the front and the back scraping a wall), speed, the floor (SURF's
-- index), the tyres slipping much (bits 1 2 4 8: TYRES' order), its hard
-- hits}. s.spheres two circles, front and back, as the zones (checkpoints,
-- crates, mines) meet it.
local R = 1.05 -- the circles against walls (m)
local AX = 1.35 -- their offset ahead and behind the middle
-- (its r the circle round the middle the other cars meet, as they see it:
-- movement.bodies' circle of the body's r. simplified: one circle, so cars
-- nose to tail overlap a little and side by side keep a little apart)
local BODY = {r = 1.4, h = 1.3, eye = 1}
-- The tyres: x right, z ahead of the middle (the mass's), the first two
-- steered, the last two driven (EDGM's 1.1 ahead, 0.7 behind, scaled)
local TYRES = {{0.92, 1.3}, {-0.92, 1.3}, {0.92, -1.25}, {-0.92, -1.25}}
-- The yaw inertia over the mass (m^2: a 4.8 by 2 m box's, a little more)
local RG2 = 1.5
-- The floor: {grip (a share of p.grip), drag (m/s^2 on the car, its four
-- tyres together), marks always}; EDGM's asphalt, gravel and field
local GROUND = {asphalt = {1, 0.16}, dirt = {0.5, 0.33}, mud = {0.25, 2.5, true},
	oil = {0.08, 0.1}, boost = {0.8, 0.1}}
-- (the pose's floor index: the client's dust and marks colours)
local SURF = {dirt = 1, mud = 2, oil = 3, asphalt = 4, boost = 5}
local ROLL = 0.25 -- rolling resistance (m/s^2)
local BRAKE = 9 -- the brakes (m/s^2)
local WALL_E, WALL_MU = 0.35, 0.35
local CAR_E = 0.2
local PI = math.pi
local NOVEL = {0, 0}
local BIT = {1, 2, 4, 8}

local function clamp(x, lo, hi)
	return x < lo and lo or x > hi and hi or x
end

-- x^0.3 and x^0.4 for x >= 1 (the box has no pow; sqrt is exact on every
-- side). simplified: x^0.3125 and x^0.375, the nearest sums of halvings
local function pow03(x)
	local q = math.sqrt(math.sqrt(x))
	return q * math.sqrt(math.sqrt(q))
end
local function pow04(x)
	local q = math.sqrt(math.sqrt(x))
	return q * math.sqrt(q)
end

-- EDGM's outer wheel: past 0.17 pi turned less
local OUTER = 0.17 * PI
local function outer(a)
	local m = a < 0 and -a or a
	if m > OUTER then
		m = pow04(m / OUTER) * OUTER
	end
	return a < 0 and -m or m
end

local function start(s)
	local pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
	s.c = {pos[1], pos[3], 0, 0}
	s.h = (tonumber(s.yaw) or 0) * PI / 180
	s.w, s.st = 0, 0
end

-- An impulse (per mass) j along the unit (nr, nf) of the body's frame at
-- its point (lx, lz): the speed {vr, vf} and the yaw rate changed
local function kick(m, j, nr, nf, lx, lz)
	m[1], m[2] = m[1] + j * nr, m[2] + j * nf
	m[3] = m[3] + j * (nr * lz - nf * lx) / RG2
end

return {
	version = 1,
	about = {
		group = "Players",
		what = "Brimstone Speedway's car, seen from above: a heavy body on four tyres. W gas, S brake, A and D steer, Space the handbrake. Grip by the floor's surface: dirt (the default), mud, oil, asphalt, boost; finish the lap line.",
		outputs = {
			lap = "Over the finish line with every checkpoint passed (the race's lap_open).",
			fire = "The race's fire key pressed (its body var fire). Value: the car's heading (degrees, kit's yaw).",
			smash = "A wall hit hard. Value: the speed into it.",
			ram = "A boosted car hit another. Value: the other's by.",
		},
	},
	root = true,
	outputs = {lap = "none", fire = "number", smash = "number", ram = "string"},
	movement = {body = BODY, raw_keys = true, touch = "drive", bodies = true,
		touch_buttons = {{"Handbrake", "jump"}},
		help = {{"[forward]/[back]", "gas, brake", "f"},
			{"[left]/[right]", "steer", "r"}, {"[jump]", "handbrake", "jump"},
			{"[fire]/Left click", "fire"}},
		touch_help = {{"Gas/Brake", "drive", "f"}, {"Stick", "steer", "r"},
			{"Handbrake", "slide", "jump"}}},
	params = {
		-- (the top speed on dirt, m/s: the air drag is made to match it)
		speed = {cat = "physics", type = "number", default = 28, min = 1,
			max = 80},
		-- (the engine's push, m/s^2; half again in first gear)
		accel = {cat = "physics", type = "number", default = 7, min = 1,
			max = 100},
		-- (the steering's widest angle, degrees)
		steer = {cat = "physics", type = "number", default = 54, min = 5,
			max = 80},
		-- (each tyre's grip on asphalt, m/s^2: EDGM's impulse_base)
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
		local hb = i.jump == 1
		if v.wreck or i.out_of_play then
			f, r, hb = 0, 0, false
		end
		local top = (p.speed or 28) * (v.boost and (p.boost or 1.45) or 1)
		local push = (p.accel or 7) * (v.boost and 2 or 1)
		local grip = p.grip or 7
		local y = type(s.pos) == "table" and tonumber(s.pos[2]) or 0
		local sh, ch = math.sin(s.h), math.cos(s.h)
		-- The body's frame: ahead (sh, ch), right (ch, -sh); m = {the speed
		-- right, the speed ahead, the yaw rate} (the yaw rate turning its
		-- nose to the right)
		local m = {c[3] * ch - c[4] * sh, c[3] * sh + c[4] * ch, s.w or 0}
		local vr, vf = m[1], m[2]
		local speed = math.sqrt(vr * vr + vf * vf)
		local flags = 0
		-- (c:speed(by, 0), the grid's freeze: held where it is)
		local frozen = top < 0.01
		if frozen then
			f, r, hb = 0, 0, false
			m[1], m[2], m[3] = 0, 0, 0
			speed = 0
		end
		-- The floor under the middle (the lap line, the dust) and each tyre
		local mid = w:under(c[1], y + 0.1, c[2])
		local surf = mid and mid.surface or "dirt"
		-- The forces (per mass, the body's frame): along it and across it
		local ar, af = 0, 0
		-- Air drag (the speed squared, so the top speed on dirt is `speed`)
		-- and rolling resistance, against the motion; none past a stop
		if speed > 1e-6 then
			local k = (push - ROLL - GROUND.dirt[2]) / (top * top)
			local d = math.min(k * speed * speed + ROLL, speed / dt)
			ar, af = ar - vr / speed * d, af - vf / speed * d
		end
		local throttle, brake = false, false
		if hb then
			-- (EDGM: the handbrake's force is the engine's push; here 0.35 of
			-- it: the locked rear's slide, not a stop, turns the car)
			af = af - clamp(vf / dt, -push * 0.35, push * 0.35)
			flags = flags + 16
		elseif f < 0 then
			if vf > 0 then
				af = af + BRAKE * f
				brake = true
			else
				af = af + push * f
				throttle = true
			end
		elseif f > 0 then
			if vf < 0 then
				af = af + BRAKE * f
				brake = true
			else
				af = af + push * f * (vf < 1.5 and 1.5 or 1)
				throttle = true
			end
		end
		if v.wreck and not frozen then
			af = af - clamp(vf / dt, -BRAKE, BRAKE)
			brake = true
		end
		if brake then
			flags = flags + 8
		end
		if throttle then
			flags = flags + 32
		end
		-- The tyres: each its floor's drag against its own motion, and its
		-- grip cancelling the speed across it, up to the limit (EDGM: a
		-- quarter of the mass's worth each, its impulses all from the speeds
		-- before them)
		local st = s.st or 0
		local d0 = {m[1], m[2], m[3]}
		local slips, much = 0, false
		-- (turning right the left wheel is the outer one, turned less)
		local turned_l = st > 0 and outer(st) or st
		local turned_r = st < 0 and outer(st) or st
		for k = 1, 4 do
			local t = TYRES[k]
			local lx, lz = t[1], t[2]
			local tx = c[1] + lx * ch + lz * sh
			local tz = c[2] - lx * sh + lz * ch
			local info = w:under(tx, y + 0.1, tz)
			local g = GROUND[info and info.surface or "dirt"] or GROUND.dirt
			local fr = info and tonumber(info.friction) or 1
			-- Its speed at its place: across and along the body
			local pr, pf = d0[1] + d0[3] * lz, d0[2] - d0[3] * lx
			local ts = math.sqrt(pr * pr + pf * pf)
			if ts > 1e-6 then
				kick(m, -math.min(g[2] / 4 * dt, ts / 4), pr / ts, pf / ts, lx, lz)
			end
			-- The grip: across the tyre (turned by the steering for the front)
			local a = k <= 2 and (lx > 0 and turned_r or turned_l) or 0
			local sa, ca = math.sin(a), math.cos(a)
			local across = pr * ca - pf * sa
			local j = -across / 4
			local lim = grip * g[1] * fr * dt
			local slip = g[3] == true
			if k > 2 then
				lim = lim * 1.2
				if hb then
					if speed > 0.2 then
						-- (EDGM's 0.4: the heavier car's slide wants less)
						lim = lim * 0.2
						slip = true
					end
				elseif throttle then
					lim = lim * 0.75
				elseif brake then
					lim = lim * 0.5
				end
			elseif brake then
				lim = lim * 0.5
			end
			local aj = j < 0 and -j or j
			if aj > lim then
				slip = aj > lim * 2.14
				j = j * lim / aj
			end
			kick(m, j, ca, -sa, lx, lz)
			if slip and ts > 1 then
				slips = slips + BIT[k]
				much = true
			end
		end
		if much then
			flags = flags + 4
		end
		-- The steering for the next step (EDGM's): its widest angle falling
		-- with the speed, the slide's angle half added (steering into it),
		-- the keys' share on top, rate-limited, back to the middle faster
		local smax = (p.steer or 54) * PI / 180
		local good = smax
		local fs = vf < 0 and -vf or vf
		if fs > 1.5 then
			good = good / pow03(fs / 1.5)
		end
		local want = 0
		if vf > 0 then
			want = want + math.atan2(vr, vf) * 0.5
		elseif speed > 9 then
			want = want + math.atan2(-vr, -vf) * 0.5
		end
		want = clamp(want + r * good, -smax, smax)
		local rate = smax * 3
		if r == 0 or (r > 0) ~= (st >= 0) then
			rate = rate * 3
		end
		st = st + clamp(want - st, -rate * dt, rate * dt)
		s.st = st
		-- Moved: the forces, then the turn and the place
		m[1], m[2] = m[1] + ar * dt, m[2] + af * dt
		if frozen then
			m[1], m[2], m[3] = 0, 0, 0
		end
		s.w = m[3]
		c[3], c[4] = m[2] * sh + m[1] * ch, m[2] * ch - m[1] * sh
		s.h = s.h + m[3] * dt
		c[1], c[2] = c[1] + c[3] * dt, c[2] + c[4] * dt
		-- Walls and (8) the other cars, met by two circles along the body
		local events = nil
		-- (s.vel: the speed before what it meets, the speed the other cars
		-- meet: a car that steps after this one is still hit as hard)
		local vx0, vz0 = c[3], c[4]
		-- (a car's speed traded once a look at it: the server steps each car a
		-- batch of inputs at a time against the others as they were, a client
		-- sees them a round trip old; traded again each step, the one ramming
		-- stopped dead on the standing one before its step took the knock.
		-- s.met: the velocity each car in contact was last seen at.
		-- simplified: the same velocity is the same look (a car's moves change
		-- it), so a car standing exactly still and never stepped is met once)
		local met = type(s.met) == "table" and s.met or {}
		local seen, traded = nil, {}
		sh, ch = math.sin(s.h), math.cos(s.h)
		for side = 1, 3 do
			local lz = side == 1 and AX or side == 2 and -AX or 0
			local n_hit = 0
			for _, h in ipairs(w:circle(c[1] + sh * lz, c[2] + ch * lz,
					side == 3 and BODY.r or R)) do
				n_hit = n_hit + 1
				if n_hit > 4 then
					break
				end
				local body = h.info and h.info.body
				-- (walls the end circles', cars the middle one's)
				if (body ~= nil) == (side == 3) and
						not (body and (v.ghost or traded[body])) then
					local nx, ny = h.nx, h.ny
					local dd = body and h.depth * 0.5 or h.depth
					c[1], c[2] = c[1] + nx * dd, c[2] + ny * dd
					-- The normal and its tangent in the body's frame
					local nr, nf = nx * ch - ny * sh, nx * sh + ny * ch
					local ov = body and h.info.vel or NOVEL
					local wr = s.w
					-- (the circle's speed: the body's and the turn's)
					local px, pz = c[3] + wr * lz * ch, c[4] - wr * lz * sh
					local vn = (px - ov[1]) * nx + (pz - ov[2]) * ny
					local mm = body and met[body]
					if body then
						seen = seen or {}
						seen[body] = {ov[1], ov[2]}
						traded[body] = true
					end
					if vn < 0 and not (mm and mm[1] == ov[1] and mm[2] == ov[2]) then
						local q = {c[3] * ch - c[4] * sh, c[3] * sh + c[4] * ch, wr}
						local inv = 1 + lz * nr * lz * nr / RG2
						local j
						if body then
							-- (equal masses: the other's step takes its own share)
							j = -(1 + CAR_E) * vn / (inv + 1)
						else
							j = -(1 + WALL_E) * vn / inv
							-- The scrape: friction along the wall, at most WALL_MU of
							-- the knock
							local tr, tf = -nf, nr
							local vt = (px * -ny + pz * nx)
							local jt = -vt / (1 + lz * tr * lz * tr / RG2)
							local lim = WALL_MU * j
							kick(q, clamp(jt, -lim, lim), tr, tf, 0, lz)
						end
						kick(q, j, nr, nf, 0, lz)
						c[3], c[4] = q[2] * sh + q[1] * ch, q[2] * ch - q[1] * sh
						s.w = q[3]
						if body and v.boost and -vn > 6 then
							events = events or {}
							events[#events + 1] = {"ram", tostring(body)}
						elseif not body and -vn > 6 then
							s.bumps = (tonumber(s.bumps) or 0) + 1
							s.bump_v = math.floor(-vn)
							if -vn > 12 then
								events = events or {}
								events[#events + 1] = {"smash", math.floor(-vn)}
							end
						end
					end
					if not body then
						local vt = (c[3] * -ny + c[4] * nx)
						if vt > 2 or vt < -2 then
							flags = flags + (side == 1 and 64 or 128)
						end
					end
				end
			end
		end
		s.met = seen
		-- The lap line: once a crossing, with the lap open
		local on_line = surf == "finish"
		if on_line and not s.on_line and v.lap_open then
			events = events or {}
			events[#events + 1] = "lap"
		end
		s.on_line = on_line or nil
		-- The race's fire key: a new count is a shot along the heading
		if v.fire ~= s.fired then
			s.fired = v.fire
			if v.fire and not v.wreck then
				events = events or {}
				events[#events + 1] = {"fire", math.floor(s.h * 1800 / PI + 0.5) / 10}
			end
		end
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
		s.pose = {s.h, tonumber(v.paint) or 1, st, flags,
			math.floor(speed * 10 + 0.5) / 10, SURF[surf] or 1, slips,
			tonumber(s.bumps) or 0}
		s.spheres = {{sh * AX, 0.5, ch * AX, 0.9}, {-sh * AX, 0.5, -ch * AX, 0.9}}
	end,
}
