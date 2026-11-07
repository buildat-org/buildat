-- A turret's movement ([KIT_VEHICLE_MOVEMENTS]): a component on a child entity of a
-- deck (the gunman's: a seat on it or under it). A and D turn it about its parent's
-- up at turn_rate, W and S raise and lower it at pitch_rate between pitch_min and
-- pitch_max (degrees; up negative, as an entity's pitch). It stays where it is put
-- on its parent and goes with it. No holder: its inputs steer and elevate (-1...1).
-- [KIT_SHIP] Its gun: Space fires a shot every `cooldown` s (0: no gun), counted in
-- s.shots; kit.cpp launches each from the turret's front along its facing, a
-- projectile of shot_speed (m/s) falling at shot_gravity, hitting for shot_damage
-- what has health (kit/health) as its holder's hit.
-- simplified: the keys turn it, not the gunman's view; only a holder fires
local BODY = {r = 0.5, h = 1}

return {
	version = 1,
	about = {
		what = "A turret's movement: a seat's holder turns, raises and fires it on its parent.",
		inputs = {
			steer = "Turns it while nobody holds its seat. Value: 1 right to -1 left.",
			throttle = "Raises it while nobody holds its seat. Value: 1 raise to -1 lower.",
		},
	},
	component = true,
	movement = {body = BODY, camera = "chase", touch = "drive"},
	params = {
		turn_rate = {cat = "physics", type = "number", default = 60, min = 0, max = 720},
		pitch_rate = {cat = "physics", type = "number", default = 30, min = 0, max = 720},
		pitch_min = {cat = "physics", type = "number", default = -60, min = -90, max = 90},
		pitch_max = {cat = "physics", type = "number", default = 10, min = -90, max = 90},
		cooldown = {type = "number", default = 0.8, min = 0, max = 60},
		shot_speed = {type = "number", default = 40, min = 1, max = 200},
		shot_gravity = {type = "number", default = 9.8, min = 0, max = 100},
		shot_damage = {type = "number", default = 10, min = 0, max = 1000},
		rate = {cat = "advanced", type = "number", default = 30, min = 10, max = 120},
	},
	inputs = {steer = "number", throttle = "number"},
	on_input = function(c, input, value)
		c.state[input] = tonumber(value) or 0
	end,
	step = function(s, i, dt, w, p)
		s.yaw = ((tonumber(s.yaw) or 0) + (i.r or 0) * (p.turn_rate or 60) * dt) % 360
		local pitch = (tonumber(s.pitch) or 0) - (i.f or 0) * (p.pitch_rate or 30) * dt
		local lo, hi = p.pitch_min or -60, p.pitch_max or 10
		s.pitch = pitch < lo and lo or pitch > hi and hi or pitch
		local cool = (tonumber(s.cool) or 0) - dt
		local every = p.cooldown or 0.8
		if i.jump == 1 and every > 0 and cool <= 0 then
			s.shots = (tonumber(s.shots) or 0) + 1
			cool = every
		end
		s.cool = cool > 0 and cool or 0
	end,
}
