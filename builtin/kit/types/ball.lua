-- A ball ([KIT] stage 4h): a seat (a use takes the player's controls, F
-- or the touch bar's Exit leaves it) that rolls: pushed toward where the
-- keys point (from the camera's side), mass (kg), push (N), rolling
-- friction (of gravity, times the ground's friction), top_speed (m/s),
-- jump_impulse (N s, 0: none), bounce (of the speed, off walls and
-- landings), gravity, rate and substeps. Still while no one is in it.
-- simplified: it slides rather than spins (drawn without turning) and
-- collides as a box round it
local BODY = {r = 0.5, h = 1}

return {
	version = 1,
	usable = true,
	seat = true,
	look = {shape = "sphere", size = 0.5, color = "#e05030", solid = true},
	movement = {body = BODY, camera = "chase", touch = "stick"},
	params = {
		mass = {cat = "physics", type = "number", default = 10, min = 0.1,
			max = 10000},
		push = {cat = "physics", type = "number", default = 150, min = 0,
			max = 100000},
		rolling_friction = {cat = "physics", type = "number", default = 0.05,
			min = 0, max = 2},
		top_speed = {cat = "physics", type = "number", default = 12, min = 0,
			max = 100},
		jump_impulse = {cat = "physics", type = "number", default = 70, min = 0,
			max = 100000},
		bounce = {cat = "physics", type = "number", default = 0.4, min = 0,
			max = 1},
		gravity = {cat = "physics", type = "number", default = 20, min = 0,
			max = 100},
		rate = {cat = "advanced", type = "number", default = 60, min = 10,
			max = 120},
		substeps = {cat = "advanced", type = "number", default = 1, min = 1,
			max = 8},
	},
	step = function(s, i, dt, w, p)
		s.pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		s.vel = type(s.vel) == "table" and s.vel or {0, 0, 0}
		local pos, v = s.pos, s.vel
		w:unbury(pos, BODY)
		local mass = p.mass or 10
		local a = (tonumber(i.yaw) or 0) * w.PI / 180
		local sn, cs = w.sin(a), w.cos(a)
		local f, r = i.f or 0, i.r or 0
		local l = w.sqrt(f * f + r * r)
		if l > 1 then
			f, r = f / l, r / l
		end
		-- The push: less in the air
		local acc = (p.push or 150) / mass * dt * (s.ground and 1 or 0.3)
		v[1] = v[1] + (sn * f + cs * r) * acc
		v[3] = v[3] + (cs * f - sn * r) * acc
		local g = p.gravity or 20
		-- Rolling friction on the ground
		local h = w.sqrt(v[1] * v[1] + v[3] * v[3])
		if s.ground and h > 0 then
			local dec = (p.rolling_friction or 0.05) * g * (s.friction or 1) * dt
			local k = h > dec and (h - dec) / h or 0
			v[1], v[3] = v[1] * k, v[3] * k
			h = h * k
		end
		local top = p.top_speed or 12
		if h > top then
			v[1], v[3] = v[1] * top / h, v[3] * top / h
		end
		-- A jump on the press
		if i.jump == 1 and not s.held and s.ground and (p.jump_impulse or 0) > 0 then
			v[2] = v[2] + p.jump_impulse / mass
			s.jumps = (s.jumps or 0) + 1
		end
		s.held = i.jump == 1
		v[2] = v[2] - g * dt
		if v[2] < -60 then v[2] = -60 end
		local mx, my, mz, hits = w:move({x = pos[1], y = pos[2], z = pos[3],
			r = BODY.r, h = BODY.h, slope = 1}, v[1] * dt, v[2] * dt, v[3] * dt,
			s.ground and 0.3 or 0)
		pos[1], pos[2], pos[3] = pos[1] + mx, pos[2] + my, pos[3] + mz
		local b = p.bounce or 0.4
		if hits.x ~= 0 then v[1] = -v[1] * b end
		if hits.z ~= 0 then v[3] = -v[3] * b end
		local on = nil
		if hits.y ~= 0 then
			if hits.y < 0 then
				on = hits.y_info
			end
			v[2] = v[2] < -3 and -v[2] * b or 0
		end
		s.ground = on ~= nil
		s.friction = on and on.friction or nil
		s.surface = on and on.surface or nil
	end,
}
