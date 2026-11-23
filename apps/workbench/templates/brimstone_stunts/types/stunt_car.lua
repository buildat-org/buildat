-- Brimstone Stunts' car (4z37zzd: a fork of Brimstone Speedway's brim_car,
-- seen by kit/controls' chase camera): a movement (kit/controls'
-- movement), stepped in kit/controls' plane "horizontal" (x and z the
-- plane's 2D x and y) with movement.own_height ([KIT_STUNTS]): its own
-- height and speed up (s.pos[2], s.vel[2]), not held. W gas, S brake and
-- reverse, A and D steer, Space the handbrake; a weapon fires on its own
-- key (stunt_weapons' action "fire": Ctrl, the left mouse button).
-- A rigid body with a mass and a yaw inertia on four tyres (the user's
-- EDGM car, a Box2D truck, ported without Box2D): each tyre cancels the
-- speed across it at its place, up to a grip limit by the floor under it;
-- the driven rear ones grip more (weight), less under throttle, much less
-- under the handbrake, half braking; the front ones steer, their angle
-- falling with speed, rate-limited, released faster, with a counter-steer
-- of half the slide's angle. Air drag (the speed squared), rolling
-- resistance and each tyre's drag on the floor slow it, so the top speed
-- (`speed`) is approached slowly as the drag nears the engine's push.
-- The floor (w:under: a kit/polygon floor's surface under each tyre, else
-- the solid polygon's it stands on: the road, the run-off, a ramp) sets
-- the grip and drag: dirt (and anything else: the track's ground), "gravel"
-- (the run-off beside it: less grip, more drag, short of "mud"), "mud",
-- "oil", "asphalt" holds best, "boost" pushes it on; "finish" is the lap
-- line (dirt to the tyres). [KIT_TEMPLATE_CLEANUP] The grip and the power
-- are params (cat physics), each surface's grip its <surface>_grip.
-- [KIT_BODY_VARS] Read from s.vars (the race's c:body_var), here and in the
-- client's prediction alike:
--   lap_open: every checkpoint passed in order; the next touch of the
--     finish line is a lap: the event "lap" (the race counts it and
--     closes it again), once a crossing (s.on_line till it leaves it);
--   boost: the ram boost on (a faster top speed and a harder push);
--   wreck: wrecked, no control, braked to a stop;
--   paint: its colour variant (1...6), drawn by stunt_car.client.lua;
--   ghost: a time trial's car, meeting no other car;
--   fire: stunt_weapons' count of its fire key's presses: a new one is the
--     event "fire" with the heading (the action has no heading);
--   run: the race's count of the player's runs: a new one clears the tyre
--     marks (stunt_car.client.lua, its own car's state's s.vars).
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
-- [KIT_STUNTS] (4z37zzd (2)) The height: each tyre's floor is w:down's
-- from CLIMB over the car (a kit/polygon ramp's top, the ground, a bridge's
-- deck; nothing under it within REACH: far down), the car's the axles' mean
-- at its middle, its pitch and roll the tyres' differences. It falls under
-- `gravity` (Kit scales it by kit/environment's) and stands where it meets
-- its floor, at the floor's speed up (the slope ahead times the speed):
-- off a ramp's lip it flies on, its tyres gripping nothing, no engine,
-- the pitch easing toward the way it flies. A landing whose speed into the
-- floor passes `hard_landing` slows it (by `landing_loss`) and shakes it
-- (a bump); past `wreck_landing`, or upside down, is the event "crash"
-- (the race wrecks it). Going up a slope gravity slows it, down one speeds
-- it. The walls and the cars are met at its own slice (KNEE over its
-- floor): a bridge's deck and walls are not there for a car under it.
-- simplified: one rigid car on four points (no springs); the floor read
-- along the tyres' places only (a ledge between the axles is not felt)
-- [KIT_STUNTS] (4z37zzd (3)) A loop (stunt_yard's tilted kit/polygon facets,
-- surface "loop"): landed with a tyre on one, it steps in the surface's
-- frame (loop_step, s.lp {p, v, f ahead, u up, on}): the same forces and
-- tyres in the face's plane, gravity's share along it, moved, then the frame
-- fitted to the facets under its four tyres (w:ray down its up). It stays on
-- while the face holds it (the speed into it, gravity's and the curve's,
-- not leaving it); too slow it leaves it (a flight under gravity, the
-- landing rules as off a lip). The rails beside the facets (surface "rail")
-- are walls either side (their sides only), one met heading into it turning
-- the car along it. The gas is held, the keys not read; off the loop
-- level it steps as before. s.up the frame's up (kit/controls' camera_frame
-- "body"), the pitch a whole turn there, 512 in flags on a loop.
-- simplified: no steering, no brakes on a loop (its rails hold it on the
-- helix); no other cars met there
-- Events (the movement's outputs; lap the race's input, fire and ram
-- stunt_weapons', crash the race's): lap, fire (value: the heading), smash
-- (a wall hit hard; value: the speed into it), ram, crash (a landing hard
-- enough to wreck it; value: the speed into the floor).
-- Its state: s.c {x, z, vx, vz}, s.h the heading (radians from +z toward
-- +x, kit's yaw), s.w its yaw rate, s.st the steering angle, s.bumps the
-- hard wall hits so far and s.bump_v the last one's speed (its client's
-- draw shakes on a new one), s.pose what the
-- clients draw, by its names (movement.pose): h the heading, paint, steer
-- the steering, flags (1 boosting, 2 wrecked, 4 a tyre slipping much, 8
-- braking, 16 handbrake, 32 throttle, 64 and 128 the front and the back
-- scraping a wall), speed, floor (SURF's index), slips (the tyres slipping
-- much, bits 1 2 4 8: the tyres' order), bumps (its hard hits and hard
-- landings), pitch and roll (radians, nose up, right side down; 256 in
-- flags: in the air). s.spheres
-- two circles, front and back, as the zones (checkpoints, crates, mines)
-- meet it. The tyres' places are params (track, front, rear), the client
-- part's draw's p too. The grid's freeze (the race's c:speed(by, 0)): i.speed
-- 0, held where it is.
local R = 1.05 -- the circles against walls (m)
local AX = 1.35 -- their offset ahead and behind the middle
-- (its r the circle round the middle the other cars meet, as they see it:
-- movement.bodies' circle of the body's r. simplified: one circle, so cars
-- nose to tail overlap a little and side by side keep a little apart)
local BODY = {r = 1.4, h = 1.3, eye = 1}
-- The tyres: x right, z ahead of the middle (the mass's), the first two
-- steered, the last two driven (EDGM's 1.1 ahead, 0.7 behind, scaled): the
-- params track (either side), front and rear
local function tyres(p)
	local x, f, b = p.track or 0.92, p.front or 1.3, -(p.rear or 1.25)
	return {{x, f}, {-x, f}, {x, b}, {-x, b}}
end
-- The yaw inertia over the mass (m^2: a 4.8 by 2 m box's, a little more)
local RG2 = 1.5
-- The floor: {grip (a share of p.grip: asphalt's whole, the others' their
-- params <surface>_grip), drag (m/s^2 on the car, its four tyres together),
-- marks always}; EDGM's asphalt, gravel and field
local GROUND = {asphalt = {1, 0.16}, dirt = {0.5, 0.33}, mud = {0.25, 2.5, true},
	gravel = {0.35, 1.8, true},
	oil = {0.08, 0.1}, boost = {0.8, 0.1}, loop = {1, 0.16}}
-- (the pose's floor index: the client's dust and marks colours)
local SURF = {dirt = 1, mud = 2, oil = 3, asphalt = 4, boost = 5, gravel = 6, loop = 7}
local WALL_E, WALL_MU = 0.35, 0.35
local CAR_E = 0.2
-- [KIT_STUNTS] A tyre's floor looked for from CLIMB over the car, REACH more
-- down; the walls' slice KNEE over the car's floor
local CLIMB, REACH, KNEE = 0.6, 6, 0.5
local PI = math.pi
local NOVEL = {0, 0}
local BIT = {1, 2, 4, 8}

local function clamp(x, lo, hi)
	return x < lo and lo or x > hi and hi or x
end

-- EDGM's outer wheel: past 0.17 pi turned less (math.pow: the same bits on
-- every side, as a movement's math is)
local OUTER = 0.17 * PI
local function outer(a)
	local m = a < 0 and -a or a
	if m > OUTER then
		m = math.pow(m / OUTER, 0.4) * OUTER
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

-- The forces from the air, the road, the engine and the brakes (per mass, the
-- body's frame: m = {the speed right, the speed ahead, the yaw rate}): along
-- it and across it, the pose's flags so far, throttle and brake (k: the
-- step's inputs and their limits)
local function forces(m, k, p, dt, speed)
	local ROLL, BRAKE = p.roll or 0.25, p.brake or 9
	local vr, vf = m[1], m[2]
	local ar, af, flags = 0, 0, 0
	-- Air drag (the speed squared, so the top speed on dirt is `speed`)
	-- and rolling resistance, against the motion; none past a stop
	if speed > 1e-6 then
		local kd = (k.push - ROLL - GROUND.dirt[2]) / (k.top * k.top)
		local d = math.min(kd * speed * speed + ROLL, speed / dt)
		ar, af = ar - vr / speed * d, af - vf / speed * d
	end
	local throttle, brake = false, false
	local f, push = k.f, k.push
	if k.hb then
		-- (EDGM: the handbrake's force is the engine's push; here 0.35 of
		-- it: the locked rear's slide, not a stop, turns the car)
		local hp = push * (p.handbrake or 0.35)
		af = af - clamp(vf / dt, -hp, hp)
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
			af = af + push * f * (vf < 1.5 and (p.low_gear or 1.5) or 1)
			throttle = true
		end
	end
	return ar, af, flags, throttle, brake
end

-- The tyres: each its floor's drag against its own motion, and its grip
-- cancelling the speed across it, up to the limit (EDGM: a quarter of the
-- mass's worth each, its impulses all from the speeds before them); m
-- changed. under(k, lx, lz): tyre k's floor's info. The slipping tyres' bits,
-- and whether any slips much
local function grip_tyres(m, k, p, dt, air, throttle, brake, speed, st, under)
	local grip = p.grip or 7
	local d0 = {m[1], m[2], m[3]}
	local slips, much = 0, false
	-- (turning right the left wheel is the outer one, turned less)
	local turned_l = st > 0 and outer(st) or st
	local turned_r = st < 0 and outer(st) or st
	local TYRES = tyres(p)
	for q = 1, 4 do
		local t = TYRES[q]
		local lx, lz = t[1], t[2]
		local info = under(q, lx, lz)
		local sf = info and GROUND[info.surface] and info.surface or "dirt"
		local g = GROUND[sf]
		local fr = info and tonumber(info.friction) or 1
		-- Its speed at its place: across and along the body
		local pr, pf = d0[1] + d0[3] * lz, d0[2] - d0[3] * lx
		local ts = math.sqrt(pr * pr + pf * pf)
		if ts > 1e-6 then
			kick(m, -math.min(air and 0 or g[2] / 4 * dt, ts / 4), pr / ts, pf / ts, lx, lz)
		end
		-- The grip: across the tyre (turned by the steering for the front)
		local a = q <= 2 and (lx > 0 and turned_r or turned_l) or 0
		local sa, ca = math.sin(a), math.cos(a)
		local across = pr * ca - pf * sa
		local j = -across / 4
		local lim = air and 0 or grip * (p[sf .. "_grip"] or g[1]) * fr * dt
		local slip = g[3] == true
		if q > 2 then
			lim = lim * (p.rear_grip or 1.2)
			if k.hb then
				if speed > 0.2 then
					-- (EDGM's 0.4: the heavier car's slide wants less;
					-- at 0.2 a half second's pull at full lock spun it past
					-- what a counter-steer catches)
					lim = lim * (p.handbrake_grip or 0.3)
					slip = true
				end
			elseif throttle then
				lim = lim * (p.throttle_grip or 0.75)
			elseif brake then
				lim = lim * (p.brake_grip or 0.5)
			end
		elseif brake then
			lim = lim * (p.brake_grip or 0.5)
		end
		local aj = j < 0 and -j or j
		if aj > lim then
			slip = aj > lim * 2.14 and not air
			j = j * lim / aj
		end
		kick(m, j, ca, -sa, lx, lz)
		if slip and ts > 1 then
			slips = slips + BIT[q]
			much = true
		end
	end
	return slips, much
end

-- The steering for the next step (EDGM's): its widest angle falling with
-- the speed, the slide's angle half added (steering into it), the keys'
-- share on top, rate-limited, back to the middle faster (m: as before the
-- step's forces)
local function steer(s, m, r, p, dt, speed)
	local vr, vf = m[1], m[2]
	local st = s.st or 0
	local smax = (p.steer or 54) * PI / 180
	local good = smax
	local fs = vf < 0 and -vf or vf
	if fs > 1.5 then
		good = good / math.pow(fs / 1.5, 0.3)
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
	s.st = st + clamp(want - st, -rate * dt, rate * dt)
end

-- [KIT_STUNTS] (4z37zzd (3)) Vectors {x, y, z}
local function add(a, b, q)
	return {a[1] + b[1] * q, a[2] + b[2] * q, a[3] + b[3] * q}
end
local function dot(a, b)
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
local function cross(a, b)
	return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]}
end
local function unit(a)
	local l = math.sqrt(dot(a, a))
	return l > 1e-9 and {a[1] / l, a[2] / l, a[3] / l} or nil
end

-- The heading (Kit's yaw, radians), pitch (nose up, full turn) and roll
-- (right side down) of the frame right Rt, ahead F (the client's draw turns
-- the car so: yaw, then roll, then pitch)
local function angles_of(Rt, F)
	local h = math.atan2(-Rt[3], Rt[1])
	local sh, ch = math.sin(h), math.cos(h)
	local ry = -Rt[2]
	-- (no asin in a movement's math; F's level part cos(roll) cos(pitch))
	local cr = math.sqrt(math.max(0, 1 - ry * ry))
	return h, math.atan2(F[2], cr * (F[1] * sh + F[3] * ch)), math.atan2(ry, cr)
end

-- Back to the level step from a loop: where it is, its speed and its turn
local function off_loop(s, L, flying)
	local Rt = cross(L.u, L.f)
	s.h, s.pt, s.rl = angles_of(Rt, L.f)
	s.c = {L.p[1], L.p[3], L.v[1], L.v[3]}
	s.pos = {L.p[1], L.p[2], L.p[3]}
	s.vy = L.v[2]
	s.air = flying or nil
	s.lp, s.up = nil, nil
end

-- [KIT_STUNTS] (4z37zzd (3)) The step on a loop (s.lp {p (the middle of its
-- feet), v (its speed), f (ahead), u (up), on (its tyres on the face), inf
-- (each tyre's face's info)}, the world's): the level step's tyres and forces
-- in the face's plane, gravity's share along it; the speed into the face
-- taken where the face meets it (the curve and gravity's share across it
-- pressing it on), else it flies on. Its frame follows the face under its
-- four tyres (w:ray from LOOP_UP over each down its up), the rails (w:ray
-- across it from its end circles, RAIL_AT up) push it back as walls. Off the
-- loop's faces level, or nothing under its tyres: the level step again.
-- simplified: no steering, no brakes on it (the gas alone; the rails hold it
-- on), no other cars met on it
local LOOP_UP, LOOP_REACH, LOOP_ON, RAIL_AT = 0.6, 1.2, 0.1, 0.25
-- (onto a loop at LOOP_IN m/s ahead or more; off it near its foot under LOOP_OUT)
local LOOP_IN, LOOP_OUT = 6, 3
local function loop_step(s, k, dt, w, p)
	local L = s.lp
	local P, V, F, U = L.p, L.v, L.f, L.u
	local Rt = cross(U, F)
	local G = k.G
	local m = {dot(V, Rt), dot(V, F), s.w or 0}
	local vn = dot(V, U)
	if k.frozen then
		m, vn = {0, 0, 0}, 0
	end
	local vr, vf = m[1], m[2]
	local speed = math.sqrt(vr * vr + vf * vf)
	local ar, af, flags, throttle, brake = forces(m, k, p, dt, speed)
	-- (gravity along the face; its share across it below)
	ar, af = ar - G * Rt[2], af - G * F[2]
	if throttle then
		flags = flags + 32
	end
	local air = not L.on
	local slips, much = grip_tyres(m, k, p, dt, air, throttle, brake, speed, s.st or 0,
		function(q)
			return L.inf and L.inf[q]
		end)
	if much then
		flags = flags + 4
	end
	steer(s, {vr, vf}, 0, p, dt, speed)
	m[1], m[2] = m[1] + ar * dt, m[2] + af * dt
	if k.frozen then
		m = {0, 0, 0}
	end
	s.w = m[3]
	-- Turned round its up, moved
	local a = m[3] * dt
	F = unit(add(add({0, 0, 0}, F, math.cos(a)), Rt, math.sin(a)))
	Rt = cross(U, F)
	vn = vn - G * U[2] * dt
	V = add(add(add({0, 0, 0}, Rt, m[1]), F, m[2]), U, vn)
	P = add(P, V, dt)
	-- The face under its tyres
	local TY = tyres(p)
	local H, inf, n = {}, {}, 0
	for q = 1, 4 do
		local t = TY[q]
		local o = add(add(add(P, Rt, t[1]), F, t[2]), U, LOOP_UP)
		local d, info = w:ray(o[1], o[2], o[3], -U[1], -U[2], -U[3], LOOP_UP + LOOP_REACH)
		if d then
			H[q], inf[q], n = add(o, U, -d), info, n + 1
		else
			H[q] = add(o, U, -LOOP_UP)
		end
	end
	local events = nil
	if n == 0 then
		L.p, L.v, L.f, L.u = P, V, F, U
		off_loop(s, L, true)
		s.pos = {P[1], P[2], P[3]}
		s.vel = {V[1], V[2], V[3]}
		return events, flags, "loop", speed, slips
	end
	-- Its frame from the tyres' places on the face: ahead the front's middle
	-- from the back's, right the right side's from the left's
	local F2 = unit(add(add(add({0, 0, 0}, H[1], 0.5), H[2], 0.5), add(add({0, 0, 0}, H[3], 0.5),
		H[4], 0.5), -1))
	local R2 = unit(add(add(add({0, 0, 0}, H[1], 0.5), H[3], 0.5), add(add({0, 0, 0}, H[2], 0.5),
		H[4], 0.5), -1))
	local U2 = F2 and R2 and unit(cross(F2, R2))
	local mid = add(add(add(add({0, 0, 0}, H[1], 0.25), H[2], 0.25), H[3], 0.25), H[4], 0.25)
	L.on = false
	if n >= 3 and U2 and dot(U2, U) > 0.9 then
		local hgt = dot(add(P, mid, -1), U2)
		-- (flying on, its speed out of the face: the curve not met)
		local vb = dot(V, U2)
		if hgt < 0 or hgt < LOOP_ON and vb <= 0 then
			-- On it: a landing's speed into it as the level step's; the speed
			-- along it turned with it
			local hit = -dot(V, U)
			if air and hit > (p.hard_landing or 7) then
				local keep = 1 - (p.landing_loss or 0.25)
				m[1], m[2] = m[1] * keep, m[2] * keep
				s.bumps = (tonumber(s.bumps) or 0) + 1
				s.bump_v = math.floor(hit)
				if hit > (p.wreck_landing or 15) then
					events = {{"crash", math.floor(hit)}}
				end
			end
			F = unit(add(F2, U2, -dot(F2, U2)))
			U = U2
			Rt = cross(U, F)
			V = add(add({0, 0, 0}, Rt, m[1]), F, m[2])
			if hgt < 0 then
				P = add(P, U, -hgt)
			end
			L.on = true
		end
	end
	L.inf = inf
	-- The rails: the end circles' sides, RAIL_AT up, as walls
	for _, lz in ipairs({AX, -AX}) do
		local o = add(add(P, F, lz), U, RAIL_AT)
		for _, sg in ipairs({1, -1}) do
			local d, info, nx, ny, nz = w:ray(o[1], o[2], o[3], Rt[1] * sg, Rt[2] * sg,
				Rt[3] * sg, R)
			if d and info and info.surface == "rail" then
				local n3 = {nx or -Rt[1] * sg, ny or -Rt[2] * sg, nz or -Rt[3] * sg}
				local nr, nf = dot(n3, Rt), dot(n3, F)
				local l = math.sqrt(nr * nr + nf * nf)
				-- (its sides only: a face mostly along the way is a rail's end at a
				-- joint between facets, one mostly up its top under a tyre, neither
				-- a wall: the end stopped the car dead there)
				if l > 0.7 and math.abs(nr) > 0.5 * l then
					nr, nf = nr / l, nf / l
					P = add(add(P, Rt, nr * (R - d)), F, nf * (R - d))
					local q = {dot(V, Rt), dot(V, F), s.w or 0}
					local pr, pf = q[1] + q[3] * lz, q[2]
					local vnr = pr * nr + pf * nf
					if vnr < 0 then
						local j = -(1 + WALL_E) * vnr / (1 + lz * nr * lz * nr / RG2)
						local tr, tf = -nf, nr
						local vt = pr * tr + pf * tf
						local jt = -vt / (1 + lz * tr * lz * tr / RG2)
						local lim = WALL_MU * j
						kick(q, clamp(jt, -lim, lim), tr, tf, 0, lz)
						kick(q, j, nr, nf, 0, lz)
						V = add(add(add({0, 0, 0}, Rt, q[1]), F, q[2]), U, dot(V, U))
						s.w = q[3]
						if -vnr > 6 then
							s.bumps = (tonumber(s.bumps) or 0) + 1
							s.bump_v = math.floor(-vnr)
							if -vnr > 12 then
								events = events or {}
								events[#events + 1] = {"smash", math.floor(-vnr)}
							end
						end
					end
					if math.abs(pr * -nf + pf * nr) > 2 then
						flags = flags + (lz > 0 and 64 or 128)
					end
					-- (heading into it: turned along it, its speed turned with it, its
					-- turn stopped. A car met a rail at an angle and the tyres turned
					-- its speed back into it each step: the scrape's friction slowed
					-- it short of the top. simplified: a guide rail's turn, not the
					-- body's swing round its corner)
					if nf < 0 then
						local vr2, vf2, vn2 = dot(V, Rt), dot(V, F), dot(V, U)
						F = unit(add(F, add(add({0, 0, 0}, Rt, nr), F, nf), -nf))
						Rt = cross(U, F)
						V = add(add(add({0, 0, 0}, Rt, vr2), F, vf2), U, vn2)
						s.w = 0
					end
				end
			end
		end
	end
	L.p, L.v, L.f, L.u = P, V, F, U
	-- Off it: level on what is not the loop's, or near level and slow (fallen
	-- in at its foot across it: the keys again, to drive off it)
	local still = false
	for q = 1, 4 do
		still = still or inf[q] ~= nil and inf[q].surface == "loop"
	end
	s.pos = {P[1], P[2], P[3]}
	s.vel = {V[1], V[2], V[3]}
	if L.on and (not still and U[2] > 0.97 or U[2] > 0.9 and math.abs(m[2]) < LOOP_OUT) then
		off_loop(s, L)
		return events, flags, "loop", speed, slips
	end
	s.h, s.pt, s.rl = angles_of(Rt, F)
	s.up = {U[1], U[2], U[3]}
	s.air = not L.on or nil
	s.spheres = {{F[1] * AX + U[1] * 0.5, F[2] * AX + U[2] * 0.5, F[3] * AX + U[3] * 0.5, 0.9},
		{-F[1] * AX + U[1] * 0.5, -F[2] * AX + U[2] * 0.5, -F[3] * AX + U[3] * 0.5, 0.9}}
	s.met = nil
	return events, flags + 512, "loop", speed, slips
end

-- The level step (the plane's: x, z and its own height): the forces, the
-- tyres, the walls and the other cars at its slice, its floor and its fall.
-- [KIT_STUNTS] (4z37zzd (3)) a tyre's floor a loop's face ("loop") with the
-- car on its floor at LOOP_IN ahead or more: on the loop from the next step
-- (s.lp)
local function flat_step(s, k, dt, w, p)
	local c = s.c
	local air = s.air == true
	local y = type(s.pos) == "table" and tonumber(s.pos[2]) or 0
	local vy = tonumber(s.vy) or 0
	local G = k.G
	local BRAKE = p.brake or 9
	local sh, ch = math.sin(s.h), math.cos(s.h)
	-- The body's frame: ahead (sh, ch), right (ch, -sh); m = {the speed
	-- right, the speed ahead, the yaw rate} (the yaw rate turning its
	-- nose to the right)
	local m = {c[3] * ch - c[4] * sh, c[3] * sh + c[4] * ch, s.w or 0}
	if k.frozen then
		m[1], m[2], m[3] = 0, 0, 0
	end
	local vr, vf = m[1], m[2]
	local speed = math.sqrt(vr * vr + vf * vf)
	-- The floor under the middle (the lap line, the dust) and each tyre
	local mid = w:under(c[1], y + 0.1, c[2])
	local surf = mid and mid.surface or "dirt"
	local ar, af, flags, throttle, brake = forces(m, k, p, dt, speed)
	-- ([KIT_STUNTS] on a slope: gravity along it)
	if not air then
		af = af - G * math.sin(tonumber(s.pt) or 0)
	end
	if k.wreck and not k.frozen then
		af = af - clamp(vf / dt, -BRAKE, BRAKE)
		brake = true
	end
	if brake then
		flags = flags + 8
	end
	if throttle then
		flags = flags + 32
	end
	local slips, much = grip_tyres(m, k, p, dt, air, throttle, brake, speed, s.st or 0,
		function(_, lx, lz)
			local tx = c[1] + lx * ch + lz * sh
			local tz = c[2] - lx * sh + lz * ch
			-- ([KIT_STUNTS] its floor as last stepped: a slope's top ahead)
			return w:under(tx, y + 0.1 + (tonumber(s.pt) or 0) * lz, tz)
		end)
	if much then
		flags = flags + 4
	end
	steer(s, {vr, vf}, k.r, p, dt, speed)
	-- Moved: the forces, then the turn and the place
	m[1], m[2] = m[1] + ar * dt, m[2] + af * dt
	if k.frozen then
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
	local v = k.vars
	local met = type(s.met) == "table" and s.met or {}
	local seen, traded = nil, {}
	sh, ch = math.sin(s.h), math.cos(s.h)
	for side = 1, 3 do
		local lz = side == 1 and AX or side == 2 and -AX or 0
		local n_hit = 0
		for _, h in ipairs(w:circle(c[1] + sh * lz, c[2] + ch * lz,
				side == 3 and BODY.r or R, y + KNEE)) do
			n_hit = n_hit + 1
			if n_hit > 4 then
				break
			end
			local body = h.info and h.info.body
			-- (walls the end circles', cars the middle one's; [KIT_STUNTS] (4z37zzd
			-- (3)) a tilted slab lying near level no wall: a loop's foot, its floor)
			local n3 = h.info and h.info.tilt and h.info.n
			if (body ~= nil) == (side == 3) and not (n3 and math.abs(n3[2]) > 0.7) and
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
	-- [KIT_STUNTS] The height: the tyres' floors, the car's, its fall
	local TYRES = tyres(p)
	local TF, TR, TX = p.front or 1.3, p.rear or 1.25, p.track or 0.92
	local fl, on_loop = {}, false
	for q = 1, 4 do
		local t = TYRES[q]
		local d, info = w:down(c[1] + t[1] * ch + t[2] * sh, y + CLIMB, c[2] - t[1] * sh + t[2] * ch,
			CLIMB + REACH)
		fl[q] = y + CLIMB - (d or CLIMB + REACH + 50)
		on_loop = on_loop or d ~= nil and d < CLIMB + 0.3 and info and info.surface == "loop"
	end
	local ff, fb = (fl[1] + fl[2]) / 2, (fl[3] + fl[4]) / 2
	local fy = fb + (ff - fb) * TR / (TF + TR)
	local pt = math.atan2(ff - fb, TF + TR)
	local rl = math.atan2((fl[2] + fl[4] - fl[1] - fl[3]) / 2, 2 * TX)
	local vf1 = c[3] * sh + c[4] * ch
	vy = vy - G * dt
	if y + vy * dt <= fy then
		-- On it: at its speed up; a landing's speed into it
		local up = vf1 * (ff - fb) / (TF + TR)
		local hit = up - vy
		if air and hit > (p.hard_landing or 7) then
			local keep = 1 - (p.landing_loss or 0.25)
			c[3], c[4] = c[3] * keep, c[4] * keep
			s.bumps = (tonumber(s.bumps) or 0) + 1
			s.bump_v = math.floor(hit)
			if hit > (p.wreck_landing or 15) or math.abs(tonumber(s.rl) or 0) > PI / 2 or
					math.abs(tonumber(s.pt) or 0) > PI / 2 then
				events = events or {}
				events[#events + 1] = {"crash", math.floor(hit)}
			end
		end
		y, vy, s.air = fy, up, nil
		s.pt, s.rl = pt, rl
		-- (4z37zzd (3)) onto a loop: its frame from the pitch and roll
		if on_loop and vf1 >= LOOP_IN then
			local cp, sp, cr, sr = math.cos(pt), math.sin(pt), math.cos(rl), math.sin(rl)
			local F = {sh * cp, sp, ch * cp}
			local Rt = {ch * cr, -sr, -sh * cr}
			local U = unit(cross(F, Rt))
			s.lp = {p = {c[1], y, c[2]}, v = {c[3], vy, c[4]}, f = F, u = U, on = true}
		end
	else
		-- In the air: the nose easing toward the way it flies
		y, s.air = y + vy * dt, true
		local want = math.atan2(vy, math.max(1, math.abs(vf1)))
		local pa = tonumber(s.pt) or 0
		s.pt = pa + (want - pa) * math.min(1, 2 * dt)
	end
	s.vy = vy
	s.pos = {c[1], y, c[2]}
	s.vel = {vx0, vy, vz0}
	s.spheres = {{sh * AX, 0.5, ch * AX, 0.9}, {-sh * AX, 0.5, -ch * AX, 0.9}}
	return events, flags, surf, speed, slips
end

return {
	version = 1,
	about = {
		group = "Players",
		what = "Brimstone Stunts' car, chased by the camera: a heavy body on four tyres. W is the gas, S the brake, A and D steer and Space is the handbrake. Its grip depends on the floor's surface: dirt (the default), gravel, mud, oil, asphalt, boost or finish (the lap line).",
		outputs = {
			lap = "It crossed the finish line with every checkpoint passed (the race's lap_open).",
			fire = "The fire key was pressed (its body var fire, stunt_weapons'). Value: the car's heading (degrees, kit's yaw).",
			smash = "It hit a wall hard. Value: its speed at impact.",
			ram = "It hit another car while boosted. Value: the other's by.",
			crash = "It landed hard enough to wreck (or upside down). Value: its speed into the floor.",
		},
		params = {
			speed = "The top speed on dirt, m/s; the air drag is made to match it.",
			accel = "The engine's push, m/s^2; half again in first gear.",
			steer = "The front tyres' widest steering angle, degrees.",
			grip = "Each tyre's grip on asphalt, m/s^2 (EDGM's impulse_base).",
			boost = "The top speed's factor while the ram boost is on.",
			boost_push = "The engine's push's factor while the ram boost is on.",
			low_gear = "The engine's push's factor under 1.5 m/s (first gear).",
			brake = "The brakes, m/s^2.",
			roll = "Rolling resistance, m/s^2.",
			handbrake = "The handbrake's pull, a share of the engine's push.",
			rear_grip = "The driven rear tyres' grip, a factor over the front ones'.",
			throttle_grip = "The rear tyres' grip under throttle, a factor.",
			brake_grip = "Every tyre's grip under the brakes, a factor.",
			handbrake_grip = "The rear tyres' grip under the handbrake while moving, a factor.",
			dirt_grip = "The grip on dirt (and any floor not named here), a share of the asphalt's.",
			gravel_grip = "The grip on gravel (the run-off), a share of the asphalt's.",
			mud_grip = "The grip in mud, a share of the asphalt's.",
			oil_grip = "The grip on oil, a share of the asphalt's.",
			boost_grip = "The grip on a boost floor, a share of the asphalt's.",
			track = "Each tyre's distance from the middle sideways, m (the client part draws them there).",
			front = "The front tyres ahead of the middle, m.",
			rear = "The rear tyres behind the middle, m.",
			rate = "Inputs a second; Kit draws the car between them.",
			substeps = "Physics steps an input; 120 a second as at 60 and 2.",
			gravity = "Its fall, m/s^2 (kit/environment's gravity scales it).",
			hard_landing = "A landing's speed into the floor past which it slows and shakes, m/s.",
			landing_loss = "The share of its speed a hard landing takes.",
			wreck_landing = "A landing's speed into the floor past which it wrecks (the event crash), m/s.",
		},
	},
	root = true,
	-- [KIT_SINGLE] the nearest copy is used: one a holder (the root, a scene)
	single = true,
	outputs = {lap = "none", fire = "number", smash = "number", ram = "string",
		crash = "number"},
	movement = {body = BODY, raw_keys = true, touch = "drive", bodies = true,
		own_height = true,
		-- (4z37i: Brake, Gas, Handbrake, each brake beside Gas)
		touch_buttons = {{"Handbrake", "jump", "low"}},
		touch_axes = {{"Left", "r", -1}, {"Right", "r", 1}},
		help = {{"{key:forward}/{key:back}", "gas, brake", "f"},
			{"{key:left}/{key:right}", "steer", "r"},
			{"{key:jump}", "handbrake", "jump"},
			{"{key:fire}/Left click", "fire"}},
		touch_help = {{"Gas/Brake", "drive", "f"}, {"Stick", "steer", "r"},
			{"Handbrake", "slide", "jump"}},
		-- s.pose's slots by name (the client part's draw reads them so)
		pose = {"h", "paint", "steer", "flags", "speed", "floor", "slips", "bumps",
			"pitch", "roll"}},
	params = {
		speed = {cat = "physics", type = "number", default = 28, min = 1,
			max = 80},
		accel = {cat = "physics", type = "number", default = 7, min = 1,
			max = 100},
		steer = {cat = "physics", type = "number", default = 54, min = 5,
			max = 80},
		grip = {cat = "physics", type = "number", default = 7, min = 0.1,
			max = 40},
		boost = {cat = "physics", type = "number", default = 1.45, min = 1,
			max = 3},
		boost_push = {cat = "physics", type = "number", default = 2, min = 1,
			max = 5},
		low_gear = {cat = "physics", type = "number", default = 1.5, min = 1,
			max = 4},
		brake = {cat = "physics", type = "number", default = 9, min = 1,
			max = 50},
		roll = {cat = "physics", type = "number", default = 0.25, min = 0,
			max = 5},
		handbrake = {cat = "physics", type = "number", default = 0.35, min = 0,
			max = 2},
		rear_grip = {cat = "physics", type = "number", default = 1.2, min = 0.1,
			max = 4},
		throttle_grip = {cat = "physics", type = "number", default = 0.75,
			min = 0.05, max = 1},
		brake_grip = {cat = "physics", type = "number", default = 0.5,
			min = 0.05, max = 1},
		handbrake_grip = {cat = "physics", type = "number", default = 0.3,
			min = 0.05, max = 1},
		dirt_grip = {cat = "physics", type = "number", default = 0.5, min = 0.01,
			max = 2},
		gravel_grip = {cat = "physics", type = "number", default = 0.35,
			min = 0.01, max = 2},
		mud_grip = {cat = "physics", type = "number", default = 0.25, min = 0.01,
			max = 2},
		oil_grip = {cat = "physics", type = "number", default = 0.08, min = 0.01,
			max = 2},
		boost_grip = {cat = "physics", type = "number", default = 0.8, min = 0.01,
			max = 2},
		track = {cat = "physics", type = "number", default = 0.92, min = 0.3,
			max = 2},
		front = {cat = "physics", type = "number", default = 1.3, min = 0.3,
			max = 3},
		rear = {cat = "physics", type = "number", default = 1.25, min = 0.3,
			max = 3},
		-- (substeps: the tyres' grip is a share of the speed across them
		-- each)
		rate = {cat = "advanced", type = "number", default = 30, min = 10,
			max = 120},
		substeps = {cat = "advanced", type = "number", default = 4, min = 1,
			max = 8},
		gravity = {cat = "physics", type = "number", default = 14, min = 1,
			max = 60},
		hard_landing = {cat = "physics", type = "number", default = 7, min = 1,
			max = 60},
		landing_loss = {cat = "physics", type = "number", default = 0.25, min = 0,
			max = 1},
		wreck_landing = {cat = "physics", type = "number", default = 15, min = 1,
			max = 100},
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
		-- [KIT_STUNTS] (in the air: no engine, no brakes, the tyres on nothing)
		local air = s.air == true
		if air then
			f, hb = 0, false
		end
		-- [KIT_STUNTS] (4z37zzd (3)) on a loop: the gas held, nothing else
		-- (loop_step). simplified: whatever the keys (a bot's read the loop's
		-- way back over the top as a slide and let go)
		if s.lp then
			f, r, hb = 1, 0, false
		end
		local top = (p.speed or 28) * (v.boost and (p.boost or 1.45) or 1)
		local push = (p.accel or 7) * (v.boost and (p.boost_push or 2) or 1)
		local G = p.gravity or 14
		-- (c:speed(by, 0), the grid's freeze: held where it is)
		local frozen = i.speed == 0
		if frozen then
			f, r, hb = 0, 0, false
		end
		local k = {f = f, r = r, hb = hb, top = top, push = push, G = G, frozen = frozen,
			wreck = v.wreck, vars = v}
		local events, flags, surf, speed, slips
		if s.lp then
			events, flags, surf, speed, slips = loop_step(s, k, dt, w, p)
		else
			events, flags, surf, speed, slips = flat_step(s, k, dt, w, p)
		end
		local st = s.st or 0
		-- The lap line: once a crossing, with the lap open
		local on_line = surf == "finish"
		if on_line and not s.on_line and v.lap_open then
			events = events or {}
			events[#events + 1] = "lap"
		end
		s.on_line = on_line or nil
		-- The fire key: a new count is a shot along the heading
		if v.fire ~= s.fired then
			s.fired = v.fire
			if v.fire and not v.wreck then
				events = events or {}
				events[#events + 1] = {"fire", math.floor(s.h * 1800 / PI + 0.5) / 10}
			end
		end
		s.events = events
		s.yaw = math.fmod(s.h * 180 / PI, 360)
		if v.boost then
			flags = flags + 1
		end
		if v.wreck then
			flags = flags + 2
		end
		if s.air then
			flags = flags + 256
		end
		s.pose = {h = s.h, paint = tonumber(v.paint) or 1, steer = st, flags = flags,
			speed = math.floor(speed * 10 + 0.5) / 10, floor = SURF[surf] or 1,
			slips = slips, bumps = tonumber(s.bumps) or 0,
			pitch = math.floor((tonumber(s.pt) or 0) * 1000 + 0.5) / 1000,
			roll = math.floor((tonumber(s.rl) or 0) * 1000 + 0.5) / 1000}
	end,
}
