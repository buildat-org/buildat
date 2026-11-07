-- A sea vessel's movement ([KIT_VEHICLE_MOVEMENTS]): a component on the entity it
-- moves (a free voxel object's root: its deck steered in play, kit.cpp's drives).
-- It floats at the water level (the world's sea level, or water_level), its place
-- `draft` under the surface, held there by a spring (buoyancy, its damping). W and S
-- (throttle) push it along its heading up to top_speed, and back at a third; A and D
-- turn the rudder, which turns it by the speed of the water past it (turn_rate at
-- top_speed, a fifth of it at rest); drag slows it, along and more across. Driven by
-- whoever holds a seat on it or under it, else by its inputs throttle and steer
-- (-1...1; an NPC's, a signal's). kit/wave on the same root rolls and pitches it on
-- top.
-- simplified: it meets the world as one body round its place (body below), not by
-- its hull's shape; the water is a level, not water voxels (a lake above the sea is
-- water_level by hand)
local BODY = {r = 1.5, h = 2}

return {
	version = 1,
	about = {
		what = "A sea vessel's movement: it floats, a seat's holder steers it with the rudder.",
		inputs = {
			throttle = "Thrust while nobody holds its seat. Value: 1 forward to -1 back.",
			steer = "The rudder while nobody holds its seat. Value: 1 right to -1 left.",
		},
	},
	component = true,
	movement = {body = BODY, camera = "chase", touch = "drive"},
	params = {
		water = {type = "string", default = "world", choices = {"world", "level"}},
		water_level = {type = "number", default = 0, min = -1000, max = 1000},
		draft = {cat = "physics", type = "number", default = 0.5, min = -10, max = 30},
		thrust = {cat = "physics", type = "number", default = 3, min = 0, max = 100},
		top_speed = {cat = "physics", type = "number", default = 8, min = 0, max = 100},
		turn_rate = {cat = "physics", type = "number", default = 25, min = 0, max = 180},
		drag = {cat = "physics", type = "number", default = 0.3, min = 0, max = 10},
		side_drag = {cat = "physics", type = "number", default = 2, min = 0, max = 50},
		buoyancy = {cat = "physics", type = "number", default = 8, min = 0.1, max = 200},
		gravity = {cat = "physics", type = "number", default = 20, min = 0, max = 100},
		rate = {cat = "advanced", type = "number", default = 30, min = 10, max = 120},
		substeps = {cat = "advanced", type = "number", default = 1, min = 1, max = 8},
	},
	inputs = {throttle = "number", steer = "number"},
	on_input = function(c, input, value)
		c.state[input] = tonumber(value) or 0
	end,
	step = function(s, i, dt, w, p)
		s.pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		s.vel = type(s.vel) == "table" and s.vel or {0, 0, 0}
		local pos, v = s.pos, s.vel
		local yaw = tonumber(s.yaw) or 0
		local a = yaw * w.PI / 180
		local sn, cs = w.sin(a), w.cos(a)
		local along = v[1] * sn + v[3] * cs
		local across = v[1] * cs - v[3] * sn
		local f, r = i.f or 0, i.r or 0
		local top = p.top_speed or 8
		-- The screw: up to its top speed, a third of it astern
		if f > 0 and along < top then
			along = along + (p.thrust or 3) * f * dt
		elseif f < 0 and along > -top / 3 then
			along = along + (p.thrust or 3) * f * dt
		end
		along = along - along * (p.drag or 0.3) * dt
		across = across - across * (p.side_drag or 2) * dt
		-- The rudder: by the water going past it
		local flow = top > 0 and along / top or 0
		local k = (flow < 0 and -flow or flow) * 0.8 + 0.2
		yaw = (yaw + r * (p.turn_rate or 25) * k * (flow < 0 and -1 or 1) * dt) % 360
		s.yaw = yaw
		-- Afloat: its place `draft` under the surface, a damped spring
		local want = (p.water_level or 0) - (p.draft or 0.5) - 0.5
		local g = p.gravity or 20
		local b = p.buoyancy or 8
		v[2] = v[2] + ((want - pos[2]) * b * b * 0.25 - v[2] * b * 0.7) * dt
		if pos[2] > want + 0.5 then
			v[2] = v[2] - g * dt
		end
		local a2 = yaw * w.PI / 180
		local sn2, cs2 = w.sin(a2), w.cos(a2)
		v[1] = sn2 * along + cs2 * across
		v[3] = cs2 * along - sn2 * across
		local mx, my, mz, hits = w:move({x = pos[1], y = pos[2], z = pos[3],
			r = BODY.r, h = BODY.h, slope = 0}, v[1] * dt, v[2] * dt, v[3] * dt, 0)
		pos[1], pos[2], pos[3] = pos[1] + mx, pos[2] + my, pos[3] + mz
		-- Aground: stopped where it struck
		if hits.x ~= 0 then v[1] = 0 end
		if hits.z ~= 0 then v[3] = 0 end
		if hits.y ~= 0 then v[2] = 0 end
	end,
}
