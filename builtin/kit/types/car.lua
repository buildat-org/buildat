-- A car ([KIT] stage 4h): a seat (a use takes the player's controls, F
-- or the touch bar's Exit leaves it). W and S (a touchscreen's Gas and
-- Brake) drive and brake, then reverse; A and D (the stick) steer.
-- engine_force (N), brake (m/s²), steering (degrees at the front wheels),
-- grip (of gravity: the sideways pull the tyres hold before they slip),
-- suspension (spring stiffness a kilogram, its damping), ride_height (m),
-- mass (kg), top_speed (m/s), drivable (the surfaces it drives on with
-- full grip and engine, comma separated, "" any: a voxel's surface, its
-- name without the author, "ground" a heightmap's), gravity, rate and
-- substeps. Still while no one is in it.
-- simplified: arcade wheels (four rays down from the corners hold the body
-- up on springs, a bicycle's steering), drawn level (its yaw only), and
-- it collides as a 2 m square round its middle
local BODY = {r = 1, h = 1}
-- The wheels' corners and the wheelbase (m)
local WX, WZ, BASE = 0.8, 1.3, 2.6

local function drivable(p, info)
	local d = p.drivable or ""
	if d == "" or not info then
		return true
	end
	local surf = info.surface or ""
	for name in d:gmatch("[^,%s]+") do
		if name == surf then
			return true
		end
	end
	return false
end

return {
	version = 1,
	usable = true,
	seat = true,
	look = {shape = "box", size = {1.8, 0.7, 3.6}, offset = {0, -0.15, 0},
		color = "#3060c0", solid = true},
	movement = {body = BODY, camera = "chase", touch = "drive"},
	params = {
		engine_force = {cat = "physics", type = "number", default = 9000,
			min = 0, max = 1e6},
		brake = {cat = "physics", type = "number", default = 14, min = 0,
			max = 100},
		steering = {cat = "physics", type = "number", default = 32, min = 0,
			max = 60},
		grip = {cat = "physics", type = "number", default = 1.2, min = 0,
			max = 5},
		suspension = {cat = "physics", type = "number", default = 60, min = 1,
			max = 1000},
		damping = {cat = "physics", type = "number", default = 9, min = 0,
			max = 100},
		ride_height = {cat = "physics", type = "number", default = 0.4,
			min = 0.05, max = 2},
		mass = {cat = "physics", type = "number", default = 1000, min = 1,
			max = 1e6},
		top_speed = {cat = "physics", type = "number", default = 22, min = 0,
			max = 150},
		drivable = {type = "string", default = ""},
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
		local yaw = tonumber(s.yaw) or 0
		local a = yaw * w.PI / 180
		local sn, cs = w.sin(a), w.cos(a)
		local g = p.gravity or 20
		-- The wheels: how far down the ground is from each corner's hub
		local rest = p.ride_height or 0.4
		local under, info, n = 0, nil, 0
		for _, c in ipairs({{WX, WZ}, {-WX, WZ}, {WX, -WZ}, {-WX, -WZ}}) do
			local x = pos[1] + cs * c[1] + sn * c[2]
			local z = pos[3] - sn * c[1] + cs * c[2]
			local d, inf = w:down(x, pos[2] + 0.3, z, rest + 0.6)
			if d then
				local comp = rest + 0.3 - d
				if comp > -0.1 then
					under = under + (comp > 0 and comp or 0)
					n = n + 1
					info = info or inf
				end
			end
		end
		local ground = n > 0
		-- The springs hold it up, the dampers calm it
		if ground then
			v[2] = v[2] + ((p.suspension or 60) * under - (p.damping or 9) * v[2]) *
					dt
		end
		v[2] = v[2] - g * dt
		if v[2] < -60 then v[2] = -60 end
		-- Along and across the car
		local along = v[1] * sn + v[3] * cs
		local across = v[1] * cs - v[3] * sn
		local f, r = i.f or 0, i.r or 0
		local ok = drivable(p, info)
		if ground then
			local mass = p.mass or 1000
			local engine = (p.engine_force or 9000) / mass * (ok and 1 or 0.2)
			if f > 0 then
				if along < (p.top_speed or 22) then
					along = along + engine * f * dt
				end
			elseif f < 0 then
				if along > 0.5 then
					along = along - (p.brake or 14) * -f * dt
					if along < 0 then along = 0 end
				elseif along > -(p.top_speed or 22) * 0.3 then
					along = along + engine * 0.5 * f * dt
				end
			end
			-- Rolling resistance and the air's drag
			along = along - along * (0.3 + 0.002 * (along < 0 and -along or along)) * dt
			-- Steering: a bicycle's turn, the front wheels at r * steering,
			-- less of it at speed
			local sp = along < 0 and -along or along
			local st = r * (p.steering or 32) / (1 + sp / 8) * w.PI / 180
			local turn = along * w.sin(st) / w.cos(st) / BASE
			yaw = yaw + turn * dt * 180 / w.PI
			-- Grip: the tyres take the sideways speed up to their hold
			local hold = (p.grip or 1.2) * g * (info and info.friction or 1) *
					(ok and 1 or 0.3) * dt
			s.slip = across > hold or across < -hold
			if across > hold then
				across = across - hold
			elseif across < -hold then
				across = across + hold
			else
				across = 0
			end
		end
		yaw = yaw % 360
		s.yaw = yaw
		local a2 = yaw * w.PI / 180
		local sn2, cs2 = w.sin(a2), w.cos(a2)
		v[1] = sn2 * along + cs2 * across
		v[3] = cs2 * along - sn2 * across
		local mx, my, mz, hits = w:move({x = pos[1], y = pos[2], z = pos[3],
			r = BODY.r, h = BODY.h, slope = 1}, v[1] * dt, v[2] * dt, v[3] * dt,
			ground and 0.5 or 0)
		pos[1], pos[2], pos[3] = pos[1] + mx, pos[2] + my, pos[3] + mz
		if hits.x ~= 0 then v[1] = -v[1] * 0.2 end
		if hits.z ~= 0 then v[3] = -v[3] * 0.2 end
		if hits.y ~= 0 then v[2] = 0 end
		s.ground = ground
		s.surface = info and info.surface or nil
	end,
}
