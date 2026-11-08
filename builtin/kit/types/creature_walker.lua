-- A creature's movement ([KIT_CREATURES_8A], kit_plan stage 8): kit/walker's
-- server twin. The server steps it wherever its entity is (kit.cpp's drives;
-- movement.steered), along the way Kit's pathfinder found to where its winning
-- behaviour proposes (the state's `path`, feet points it walks and empties):
-- towards each point at speed (times the proposal's), a jump where the next is
-- higher. Its body is width x height (m); jump_height also says how high the
-- pathfinder lets it climb (a cell for the default). The clients draw its entity
-- where its track has it. Far from players it sleeps: its section unloaded, it
-- stops and goes on where it was.
-- simplified: walks and jumps (no swim, fly, climb); sleep only, no keep running
-- or coarse far away
local function body(p)
	return {r = (p.width or 0.8) / 2, h = p.height or 0.9}
end

return {
	version = 1,
	about = {
		what = "A creature's movement: it walks where its behaviours say, on Kit's paths.",
	},
	component = true,
	movement = {body = {r = 0.4, h = 0.9}, steered = true},
	params = {
		speed = {cat = "physics", type = "number", default = 3, min = 0, max = 20},
		width = {cat = "physics", type = "number", default = 0.8, min = 0.1, max = 3},
		height = {cat = "physics", type = "number", default = 0.9, min = 0.1, max = 4},
		jump_height = {cat = "physics", type = "number", default = 1.25, min = 0,
			max = 4},
		acceleration = {cat = "physics", type = "number", default = 30, min = 1,
			max = 500},
		gravity = {cat = "physics", type = "number", default = 20, min = 0, max = 100},
		step_height = {cat = "physics", type = "number", default = 0.6, min = 0,
			max = 2},
		slope_limit = {cat = "physics", type = "number", default = 50, min = 0,
			max = 89},
		rate = {cat = "advanced", type = "number", default = 30, min = 10, max = 120},
		substeps = {cat = "advanced", type = "number", default = 1, min = 1, max = 8},
	},
	step = function(s, i, dt, w, p)
		local b = body(p)
		local pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
		local path = type(s.path) == "table" and s.path or {}
		local wx, wz, jump = 0, 0, false
		while #path > 0 do
			local q = path[1]
			local dx, dz = q[1] - pos[1], q[3] - pos[3]
			local d = w.sqrt(dx * dx + dz * dz)
			-- There: the next one (a point up waits for the feet to be up too)
			if d < 0.3 and pos[2] > q[2] - 0.3 then
				table.remove(path, 1)
			else
				local sp = (p.speed or 3) * (tonumber(s.speed_k) or 1)
				-- Slower into the last one, so as not to pass it
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
		w:walk(s, b, wx, wz, jump, dt, p)
	end,
}
