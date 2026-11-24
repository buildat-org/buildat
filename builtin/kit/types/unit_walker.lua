-- A unit's movement ([KIT_ENT_PERF], kit_plan 4z37zzk): kit/creature_walker for
-- many at once, an RTS's units. Its movement says `native = "path"`: the server
-- steps it in C++ (kit.cpp's native_path(), no box call), along the way Kit's
-- pathfinder found to where its winning behaviour proposes (c:propose_move), and
-- pushes it out of the other units' bodies. The step below is the same walk in
-- Lua, run only where the server cannot step it so (held, on a moving deck).
-- simplified: walks and jumps over whole cells (no slopes, swim or fly), as
-- kit/creature_walker sleeps far from players
local function body(p)
	return {r = (p.width or 0.8) / 2, h = p.height or 0.9}
end

return {
	version = 1,
	about = {
		what = "A unit's movement: kit/creature_walker stepped by the server itself, cheap for many, and kept apart from the other units.",
		params = {
			speed = "Walking speed in m/s.",
			width = "Its body's width in metres.",
			height = "Its body's height in metres.",
			jump_height = "How high a jump goes in metres; also how high its paths may climb.",
			acceleration = "How fast it gets up to speed, in m/s^2.",
			gravity = "The fall's acceleration in m/s^2.",
			rate = "Steps a second of its movement.",
		},
	},
	component = true,
	movement = {body = {r = 0.4, h = 0.9}, steered = true, native = "path"},
	params = {
		speed = {cat = "physics", type = "number", default = 3, min = 0, max = 20},
		width = {cat = "physics", type = "number", default = 0.8, min = 0.1, max = 3},
		height = {cat = "physics", type = "number", default = 0.9, min = 0.1, max = 4},
		jump_height = {cat = "physics", type = "number", default = 1.25, min = 0,
			max = 4},
		acceleration = {cat = "physics", type = "number", default = 30, min = 1,
			max = 500},
		gravity = {cat = "physics", type = "number", default = 20, min = 0, max = 100},
		rate = {cat = "advanced", type = "number", default = 20, min = 10, max = 120},
	},
	step = function(s, i, dt, w, p)
		local pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		local path = type(s.path) == "table" and s.path or {}
		local wx, wz, jump = 0, 0, false
		while #path > 0 do
			local q = path[1]
			local dx, dz = q[1] - pos[1], q[3] - pos[3]
			local d = w.sqrt(dx * dx + dz * dz)
			if d < 0.3 and pos[2] > q[2] - 0.3 then
				table.remove(path, 1)
			else
				local sp = (p.speed or 3) * (tonumber(s.speed_k) or 1)
				if #path == 1 and d < sp * 0.25 then
					sp = d * 4
				end
				wx, wz = dx / d * sp, dz / d * sp
				jump = q[2] > pos[2] + 0.3 and d < 1.5 and s.ground == true
				s.yaw = w.atan2(dx, dz) * 180 / w.PI % 360
				break
			end
		end
		s.path = path
		w:walk(s, body(p), wx, wz, jump, dt, p)
	end,
}
