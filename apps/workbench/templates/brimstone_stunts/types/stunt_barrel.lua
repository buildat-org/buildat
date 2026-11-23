-- Brimstone Stunts' barrel (4z38): a steered movement (the server steps it
-- wherever its entity is, as kit/creature_walker's) in kit/controls' level
-- plane, its look a kit/part beside it on the entity (collision off: the cars
-- drive through it, it is knocked away). movement.bodies: its w:circle meets
-- the cars' circles (info.body, info.vel), and a car closing on it hands it
-- the car's speed along the contact and more (BOUNCE) and a spin; the walls
-- (and the hammers, the other barrels' looks not) bounce it back (WALL_E).
-- Rolling on, it slows (ROLL); its state s.v {vx, vz}, s.spin (degrees a
-- second), s.yaw the world's.
-- simplified: a circle with no mass of its own (a car is not slowed by it,
-- it never meets it: the cars' bodies meet no creature); a barrel turns in
-- yaw alone (a creature's track carries no roll)
local R = 0.5
local BOUNCE, WALL_E, ROLL = 1.25, 0.4, 1.6

return {
	version = 1,
	about = {
		group = "Game",
		what = "A barrel the cars knock about in Brimstone Stunts: a movement on an entity with a look.",
		params = {
			rate = "Steps a second of its movement.",
			substeps = "Smaller steps in each step: finer collisions, more work.",
		},
	},
	component = true,
	movement = {body = {r = R, h = 1.1}, steered = true, bodies = true},
	params = {
		rate = {cat = "advanced", type = "number", default = 30, min = 10, max = 120},
		substeps = {cat = "advanced", type = "number", default = 1, min = 1, max = 8},
	},
	step = function(s, i, dt, w, p)
		local pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		local v = type(s.v) == "table" and s.v or {0, 0}
		local vx, vz = tonumber(v[1]) or 0, tonumber(v[2]) or 0
		local spin = tonumber(s.spin) or 0
		local x, z = pos[1] + vx * dt, pos[3] + vz * dt
		for _, h in ipairs(w:circle(x, z, R)) do
			local nx, ny = h.nx, h.ny
			x, z = x + nx * h.depth, z + ny * h.depth
			local ov = h.info and h.info.body and h.info.vel or {0, 0}
			local rx, rz = vx - ov[1], vz - ov[2]
			local vn = rx * nx + rz * ny
			if vn < 0 then
				local e = h.info and h.info.body and BOUNCE or WALL_E
				vx, vz = vx - (1 + e) * vn * nx, vz - (1 + e) * vn * ny
				-- (a glancing knock spins it: the speed along the contact)
				spin = spin + (rx * -ny + rz * nx) * 40
			end
		end
		local sp = math.sqrt(vx * vx + vz * vz)
		if sp > 1e-6 then
			local k = math.max(0, sp - ROLL * dt) / sp
			vx, vz = vx * k, vz * k
		end
		spin = spin * math.max(0, 1 - 1.5 * dt)
		if sp < 0.05 and spin < 1 and spin > -1 then
			vx, vz, spin = 0, 0, 0
		end
		s.v, s.spin = {vx, vz}, spin
		s.yaw = ((tonumber(s.yaw) or 0) + spin * dt) % 360
		s.pos = {x, pos[2], z}
		s.vel = {vx, 0, vz}
	end,
}
