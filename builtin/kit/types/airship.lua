-- An airship's movement ([KIT_VEHICLE_MOVEMENTS]): a component on the entity it
-- moves (a free voxel object's root, steered in play). It holds an altitude: Space
-- (jump) takes it up and the down key (C) down at `climb`, and when let go it stays
-- at the height it has, a damped spring; W and S (throttle) push it along its
-- heading up to top_speed, A and D turn it at turn_rate whatever its speed; drag
-- slows it. Starts holding the height it was placed at, never under `floor` m over
-- whatever is below it. Driven by whoever holds a seat on it or under it, else by
-- its inputs throttle, steer and climb (-1...1).
-- [KIT_AIRSHIPS] stage 3: on a ship (a free object with kit/hull) its numbers come
-- from its parts, p.parts = {mass, thrust, lift} (kit.cpp's ship_parts(): its
-- voxels' masses by material, its engines' thrust and lift): with `mass` set (0:
-- not reckoned), thrust and top speed are for that mass and go down as the ship
-- gets heavier (thrust / (mass / `mass`)); each engine's thrust adds to `thrust`
-- and its top speed in proportion, its lift to `climb`.
-- simplified: one body round its place meets the world (body below), not its hull;
-- a ship's mass only slows it (no inertia in turns, no centre of mass)
local BODY = {r = 1.5, h = 2}

return {
	version = 1,
	about = {
		what = "An airship's movement: it holds its altitude; a seat's holder steers, climbs and sinks.",
		inputs = {
			throttle = "Thrust while nobody holds its seat. Value: 1 forward to -1 back.",
			steer = "Steers while nobody holds its seat. Value: 1 right to -1 left.",
			climb = "Climbs while nobody holds its seat. Value: 1 up to -1 down.",
		},
	},
	component = true,
	movement = {body = BODY, camera = "chase", touch = "drive"},
	params = {
		thrust = {cat = "physics", type = "number", default = 4, min = 0, max = 100},
		mass = {cat = "physics", type = "number", default = 0, min = 0, max = 100000},
		top_speed = {cat = "physics", type = "number", default = 10, min = 0, max = 100},
		turn_rate = {cat = "physics", type = "number", default = 30, min = 0, max = 180},
		climb = {cat = "physics", type = "number", default = 3, min = 0, max = 50},
		drag = {cat = "physics", type = "number", default = 0.4, min = 0, max = 10},
		floor = {cat = "physics", type = "number", default = 2, min = 0, max = 100},
		ceiling = {cat = "physics", type = "number", default = 200, min = -100, max = 1000},
		rate = {cat = "advanced", type = "number", default = 30, min = 10, max = 120},
		substeps = {cat = "advanced", type = "number", default = 1, min = 1, max = 8},
	},
	inputs = {throttle = "number", steer = "number", climb = "number"},
	on_input = function(c, input, value)
		c.state[input] = tonumber(value) or 0
	end,
	step = function(s, i, dt, w, p)
		s.pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		s.vel = type(s.vel) == "table" and s.vel or {0, 0, 0}
		local pos, v = s.pos, s.vel
		s.alt = tonumber(s.alt) or pos[2]
		local yaw = tonumber(s.yaw) or 0
		local a = yaw * w.PI / 180
		local sn, cs = w.sin(a), w.cos(a)
		local along = v[1] * sn + v[3] * cs
		local across = v[1] * cs - v[3] * sn
		local f, r = i.f or 0, i.r or 0
		local up = (i.jump == 1 and 1 or 0) - (i.down == 1 and 1 or 0) + (tonumber(i.climb) or 0)
		up = up > 1 and 1 or up < -1 and -1 or up
		-- [KIT_AIRSHIPS] its parts: the mass slows it, the engines push
		local parts = type(p.parts) == "table" and p.parts or {}
		local base = p.thrust or 4
		local thrust = base + (tonumber(parts.thrust) or 0)
		local m = 1
		if (p.mass or 0) > 0 and tonumber(parts.mass) then
			m = parts.mass / p.mass
			m = m > 0.5 and m or 0.5
		end
		local top = (p.top_speed or 10) * (base > 0 and thrust / base or 1) / m
		top = top < 3 * (p.top_speed or 10) and top or 3 * (p.top_speed or 10)
		if (f > 0 and along < top) or (f < 0 and along > -top / 2) then
			along = along + thrust / m * f * dt
		end
		along = along - along * (p.drag or 0.4) * dt
		across = across - across * (p.drag or 0.4) * 3 * dt
		yaw = (yaw + r * (p.turn_rate or 30) * dt) % 360
		s.yaw = yaw
		-- The height held: moved by the climb, kept off the ground under it
		local alt = s.alt + up * ((p.climb or 3) + (tonumber(parts.lift) or 0)) / m * dt
		local d = w:down(pos[1], pos[2] + 0.5, pos[3], (p.floor or 2) + 0.5)
		if d and up <= 0 then
			local least = pos[2] + 0.5 - d + (p.floor or 2)
			alt = alt > least and alt or least
		end
		alt = alt < (p.ceiling or 200) and alt or (p.ceiling or 200)
		s.alt = alt
		v[2] = v[2] + ((alt - pos[2]) * 4 - v[2] * 3) * dt
		local a2 = yaw * w.PI / 180
		local sn2, cs2 = w.sin(a2), w.cos(a2)
		v[1] = sn2 * along + cs2 * across
		v[3] = cs2 * along - sn2 * across
		local mx, my, mz, hits = w:move({x = pos[1], y = pos[2], z = pos[3],
			r = BODY.r, h = BODY.h, slope = 0}, v[1] * dt, v[2] * dt, v[3] * dt, 0)
		pos[1], pos[2], pos[3] = pos[1] + mx, pos[2] + my, pos[3] + mz
		if hits.x ~= 0 then v[1] = 0 end
		if hits.z ~= 0 then v[3] = 0 end
		if hits.y ~= 0 then v[2] = 0 end
	end,
}
