-- Click to move ([KIT] stage 4h): a movement (kit/controls' movement)
-- that walks the player to where they click: the ground, or an object,
-- which they use on arriving. speed (m/s), stop_distance (m), path
-- (straight: toward it; simple: round the walls, a short search over the
-- cells, by the client) and kit/walker's knobs. The keys still walk
-- (they cancel the target); stuck against a step it jumps. A touchscreen:
-- a tap.
local BODY = {r = 0.45, h = 1.7, eye = 1.5487}

-- A cell a body stands in: it and the one over it free, a floor under it
local function standable(w, i, j, k)
	if w:cell(i, j, k) or w:cell(i, j + 1, k) then
		return false
	end
	return w:down(i, j - 0.49, k, 1.05) ~= nil
end

return {
	version = 1,
	root = true,
	movement = {body = BODY, touch = "tap", click = true},
	params = {
		speed = {type = "number", default = 5, min = 0, max = 50},
		stop_distance = {type = "number", default = 0.3, min = 0.05, max = 10},
		path = {type = "string", default = "simple",
			choices = {"straight", "simple"}},
		acceleration = {type = "number", default = 50, min = 1, max = 500},
		gravity = {type = "number", default = 20, min = 0, max = 100},
		jump_height = {type = "number", default = 1.25, min = 0, max = 10},
		air_control = {type = "number", default = 0.5, min = 0, max = 1},
		coyote_time = {type = "number", default = 0.1, min = 0, max = 1},
		jump_buffer = {type = "number", default = 0.12, min = 0, max = 1},
		step_height = {type = "number", default = 0.55, min = 0, max = 2},
		slope_limit = {type = "number", default = 50, min = 0, max = 89},
		rate = {type = "number", default = 60, min = 10, max = 120},
		substeps = {type = "number", default = 1, min = 1, max = 8},
	},
	step = function(s, i, dt, w, p)
		local sp = p.speed or 5
		if i.go == 1 then
			s.target = {i.tx, i.ty, i.tz}
			s.stuck = 0
		end
		local f, r = i.f or 0, i.r or 0
		local wx, wz, jump = 0, 0, i.jump == 1
		if f ~= 0 or r ~= 0 then
			-- The keys: walking as kit/walker does, the target dropped
			s.target = nil
			local a = (tonumber(i.yaw) or 0) * w.PI / 180
			local sn, cs = w.sin(a), w.cos(a)
			local l = w.sqrt(f * f + r * r)
			if l > 1 then
				f, r = f / l, r / l
			end
			wx, wz = (sn * f + cs * r) * sp, (cs * f - sn * r) * sp
		elseif type(s.target) == "table" then
			local pos = s.pos or {0, 0, 0}
			local dx, dz = s.target[1] - pos[1], s.target[3] - pos[3]
			local d = w.sqrt(dx * dx + dz * dz)
			if d <= (p.stop_distance or 0.3) then
				s.target = nil
				s.arrived = (s.arrived or 0) + 1
			else
				-- Slower in the last metre; facing where it goes
				local v = sp * (d < 1 and d or 1)
				wx, wz = dx / d * v, dz / d * v
				s.yaw = w.atan2(dx, dz) * 180 / w.PI
				-- Not getting there: a jump at a step, given up after a second
				local vel = s.vel or {0, 0, 0}
				if vel[1] * vel[1] + vel[3] * vel[3] < v * v * 0.04 then
					s.stuck = (s.stuck or 0) + dt
				else
					s.stuck = 0
				end
				if s.stuck > 0.15 and s.ground then
					jump = true
				end
				if s.stuck > 1.5 then
					s.target = nil
					s.stuck = 0
				end
			end
		end
		w:walk(s, BODY, wx, wz, jump, dt, p)
	end,
	-- The client's path from {x, y, z} (feet) to {x, y, z}: the cells to go
	-- through ({x, feet y, z}...), nil: none found (walked straight).
	-- simplified: a breadth-first search over 1500 cells at most, four
	-- ways, a cell up or down; an A* with diagonals when it is not enough
	plan = function(w, from, to, p)
		local floor = math.floor
		local si, sj, sk = floor(from[1] + 0.5), floor(from[2] + 0.5),
				floor(from[3] + 0.5)
		local ti, tk = floor(to[1] + 0.5), floor(to[3] + 0.5)
		local tj = floor(to[2] + 0.51)
		local function key(i, j, k)
			return i .. "," .. j .. "," .. k
		end
		local prev = {[key(si, sj, sk)] = false}
		local q, head = {{si, sj, sk}}, 1
		local found = nil
		while head <= #q and #q < 1500 do
			local c = q[head]
			head = head + 1
			if c[1] == ti and c[3] == tk and math.abs(c[2] - tj) <= 1 then
				found = c
				break
			end
			for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
				for _, dj in ipairs({0, 1, -1}) do
					local i, j, k = c[1] + d[1], c[2] + dj, c[3] + d[2]
					local kk = key(i, j, k)
					-- Up: room over the head first; down: room over the cell
					local room = dj == 0 or (dj == 1 and not w:cell(c[1], c[2] + 2,
							c[3])) or (dj == -1 and not w:cell(i, j + 2, k))
					if prev[kk] == nil and room and standable(w, i, j, k) then
						prev[kk] = c
						q[#q + 1] = {i, j, k}
						break
					end
				end
			end
		end
		if not found then
			return nil
		end
		local route = {}
		local c = found
		while c do
			table.insert(route, 1, {c[1], c[2] - 0.45, c[3]})
			c = prev[key(c[1], c[2], c[3])]
		end
		table.remove(route, 1)
		-- The last leg to the point itself
		if #route > 0 then
			route[#route] = {to[1], to[2], to[3]}
		end
		-- Straight runs in one leg
		local out = {}
		for n, r in ipairs(route) do
			local a, b = out[#out - 1], out[#out]
			if a and b and r[2] == b[2] and b[2] == a[2] and
					(r[1] - b[1]) * (b[3] - a[3]) == (r[3] - b[3]) * (b[1] - a[1]) then
				out[#out] = r
			else
				out[#out + 1] = r
			end
		end
		return out
	end,
}
