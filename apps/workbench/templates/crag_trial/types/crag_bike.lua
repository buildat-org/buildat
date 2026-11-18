-- Crag Trial's bike: a movement (kit/controls' movement) for the side view,
-- stepped in the plane (x right, y up). A frame with an angle and two wheels
-- on springs under it, gravity; the wheels and the rider's head meet the
-- ground (a heightmap's or voxels) and the polygons (w:circle). The keys: W (Gas) the back wheel's
-- motor, S (Brake) both wheels held, A and D lean the bike as the screen
-- shows it (A counter-clockwise, D clockwise, whichever way it faces), Space
-- (Turn) faces the other way. The rider's head on
-- anything is a crash: the event "crash" (its output), the bike still a
-- second, then back where it started (its first step's place).
-- Its state: s.c the frame's middle and velocity {x, y, vx, vy}, s.a its angle
-- (radians, counter-clockwise), s.av its turn, s.dir 1 facing +x or -1, s.wl
-- and s.wr the wheels {x, y, vx, vy, spin (the tyre's speed, m/s), turn},
-- s.dead the crash's seconds left, s.start; s.pose what the clients draw
-- (crag_bike.client.lua): {a, dir (2 * dir crashed), the wheels from the feet
-- (lx, ly, rx, ry), their turns}. s.pos is the frame's middle less LIFT;
-- s.spheres the wheels and the head from it, as the zones (the gems) meet it.
-- The suspension: params stiffness and damping (the springs').
-- [KIT_BODY_VARS] The finish: a wheel on the finish line (a kit/polygon whose
-- surface is "finish") while s.vars.finish_open (crag_run's c:body_var, set
-- with the rider's last gem) holds the bike still there (s.done) till the run
-- puts it back: its own step's, on the server and in the client's prediction
-- alike, so no freeze from the server and no rewind. Without every gem it
-- rides over the line.
local R = 0.36 -- a wheel's radius
local AX, AY = 0.62, -0.36 -- the wheels' springs on the frame, from its middle
local LIFT = R - AY + 0.02 -- the middle over the feet
local HX, HY, HR = -0.08, 0.86, 0.22 -- the head, facing +x
local MC, MW, IC = 2, 0.5, 0.7 -- the frame's mass, a wheel's, the frame's inertia
local REACT = 0.06 -- the motor's turn back on the frame
local BODY = {r = 1.4, h = 2.2, eye = 0.9}

local function wheel(x, y)
	return {x, y, 0, 0, 0, 0}
end

-- Back where it started, at rest
local function reset(s)
	local x, y = s.start[1], s.start[2]
	local cx, cy = x, y + LIFT
	s.c = {cx, cy, 0, 0}
	s.a, s.av, s.dead = 0, 0, nil
	s.wl, s.wr = wheel(cx - AX, cy + AY), wheel(cx + AX, cy + AY)
end

-- A wheel's spring to its place on the frame: the force on it, the frame
-- pulled back (and turned)
local function spring(s, wh, lx, ca, sa, dt, K, D)
	local c = s.c
	local ox, oy = lx * ca - AY * sa, lx * sa + AY * ca
	local px, py = c[1] + ox, c[2] + oy
	local pvx, pvy = c[3] - s.av * oy, c[4] + s.av * ox
	local fx = -K * (wh[1] - px) - D * (wh[3] - pvx)
	local fy = -K * (wh[2] - py) - D * (wh[4] - pvy)
	wh[3], wh[4] = wh[3] + fx / MW * dt, wh[4] + fy / MW * dt
	c[3], c[4] = c[3] - fx / MC * dt, c[4] - fy / MC * dt
	s.av = s.av - (ox * fy - oy * fx) / IC * dt
end

-- A wheel against the world: out of what it is in, its speed into it gone,
-- its tyre gripping (the friction a share of the push); true and whether a
-- finish line is among what it met
local function ground(wh, w, dt)
	local touched, finish = false, false
	for k, h in ipairs(w:circle(wh[1], wh[2], R)) do
		if k > 3 then
			break
		end
		local nx, ny = h.nx, h.ny
		wh[1], wh[2] = wh[1] + nx * h.depth, wh[2] + ny * h.depth
		local vn = wh[3] * nx + wh[4] * ny
		if vn < 0 then
			wh[3], wh[4] = wh[3] - nx * vn * 1.1, wh[4] - ny * vn * 1.1
			-- Along the surface (t, the way a forward turn rolls it): the
			-- tyre's speed and the wheel's met halfway, within the grip
			local tx, ty = ny, -nx
			local slip = wh[3] * tx + wh[4] * ty - wh[5]
			local j = slip / 2
			local lim = (h.info and h.info.friction or 1) * -vn * 1.5
			j = j > lim and lim or j < -lim and -lim or j
			wh[3], wh[4] = wh[3] - tx * j, wh[4] - ty * j
			wh[5] = wh[5] + j
		end
		touched = true
		finish = finish or (h.info and h.info.surface == "finish")
	end
	return touched, finish
end

return {
	version = 1,
	about = {
		group = "Players",
		what = "Crag Trial's bike: W gas, S brake, A and D lean, Space turns; the head on the ground crashes.",
		outputs = {crash = "The rider's head hit something: back to the start in a second."},
	},
	root = true,
	outputs = {crash = "none"},
	movement = {body = BODY, raw_keys = true, touch = "drive",
		touch_buttons = {{"Turn", "jump"}},
		-- The help line in play, each item gone once its input is used
		help = {{"[forward]/[back]", "gas, brake", "f"},
			{"[left]/[right]", "lean", "r"}, {"[jump]", "turn round", "jump"}},
		touch_help = {{"Gas/Brake", "ride", "f"}, {"Stick", "lean", "r"},
			{"Turn", "turn round", "jump"}}},
	params = {
		gravity = {cat = "physics", type = "number", default = 14, min = 0,
			max = 100},
		speed = {cat = "physics", type = "number", default = 16, min = 1,
			max = 60},
		power = {cat = "physics", type = "number", default = 120, min = 1,
			max = 400},
		lean = {cat = "physics", type = "number", default = 24, min = 0,
			max = 200},
		stiffness = {cat = "physics", type = "number", default = 300, min = 20,
			max = 3000},
		damping = {cat = "physics", type = "number", default = 30, min = 0,
			max = 200},
		rate = {cat = "advanced", type = "number", default = 60, min = 10,
			max = 120},
		substeps = {cat = "advanced", type = "number", default = 4, min = 1,
			max = 8},
	},
	step = function(s, i, dt, w, p)
		if type(s.c) ~= "table" then
			local pos = type(s.pos) == "table" and s.pos or {0, 0, 0}
			s.start = {pos[1], pos[2]}
			s.dir = (tonumber(s.yaw) or 90) > 180 and -1 or 1
			reset(s)
		end
		local c, wl, wr = s.c, s.wl, s.wr
		local open = type(s.vars) == "table" and s.vars.finish_open
		if not open then
			s.done = nil
		end
		if s.done then
			-- (held at the finish: nothing moves)
		elseif s.dead then
			s.dead = s.dead - dt
			if s.dead <= 0 then
				reset(s)
				c, wl, wr = s.c, s.wl, s.wr
			end
		else
			local f, r = tonumber(i.f) or 0, tonumber(i.r) or 0
			-- Space turns it round (on the press)
			if i.jump == 1 and not s.held then
				s.dir = -s.dir
			end
			s.held = i.jump == 1
			local g = p.gravity or 14
			c[4] = c[4] - g * dt
			wl[4], wr[4] = wl[4] - g * dt, wr[4] - g * dt
			local ca, sa = math.cos(s.a), math.sin(s.a)
			local K, D = p.stiffness or 300, p.damping or 30
			spring(s, wl, -AX, ca, sa, dt, K, D)
			spring(s, wr, AX, ca, sa, dt, K, D)
			-- The motor on the back wheel, the brake on both
			local back = s.dir > 0 and wl or wr
			if f > 0 then
				local want = s.dir * (p.speed or 16)
				local d = want - back[5]
				local step = (p.power or 120) * f * dt
				d = d > step and step or d < -step and -step or d
				back[5] = back[5] + d
				-- (the wheel turned one way, the frame the other: a wheelie)
				s.av = s.av + REACT * d
			elseif f < 0 then
				for _, wh in ipairs({wl, wr}) do
					local step = 80 * -f * dt
					wh[5] = wh[5] > step and wh[5] - step or wh[5] < -step and
							wh[5] + step or 0
				end
			end
			-- Leaning as the screen shows it: D clockwise, A counter-clockwise,
			-- whichever way the bike faces; the whole bike turned round its
			-- middle (a wheel off the ground)
			local dw = -r * (p.lean or 24) * dt
			s.av = s.av + dw
			for _, wh in ipairs({wl, wr}) do
				wh[3], wh[4] = wh[3] - dw * (wh[2] - c[2]), wh[4] + dw * (wh[1] - c[1])
			end
			s.av = s.av * (1 - 0.6 * dt)
			c[1], c[2] = c[1] + c[3] * dt, c[2] + c[4] * dt
			s.a = s.a + s.av * dt
			local finish = false
			for _, wh in ipairs({wl, wr}) do
				wh[1], wh[2] = wh[1] + wh[3] * dt, wh[2] + wh[4] * dt
				local _, f = ground(wh, w, dt)
				finish = finish or f
				wh[6] = math.fmod(wh[6] - wh[5] / R * dt, 2 * math.pi)
			end
			-- The head
			local hx = c[1] + (HX * s.dir) * ca - HY * sa
			local hy = c[2] + (HX * s.dir) * sa + HY * ca
			local hit = w:circle(hx, hy, HR)[1]
			if hit and hit.depth > 0.02 then
				s.dead = 1
				c[3], c[4], s.av = 0, 0, 0
				for _, wh in ipairs({wl, wr}) do
					wh[3], wh[4], wh[5] = 0, 0, 0
				end
				s.events = {"crash"}
				s.crashes = (s.crashes or 0) + 1
			elseif finish and open then
				s.done = true
				c[3], c[4], s.av = 0, 0, 0
				for _, wh in ipairs({wl, wr}) do
					wh[3], wh[4], wh[5] = 0, 0, 0
				end
			end
		end
		local z = type(s.pos) == "table" and tonumber(s.pos[3]) or 0
		s.pos = {c[1], c[2] - LIFT, z}
		s.vel = {c[3], c[4], 0}
		s.yaw = s.dir > 0 and 90 or 270
		s.pose = {s.a, s.dead and 2 * s.dir or s.dir, wl[1] - c[1], wl[2] - c[2] + LIFT,
			wr[1] - c[1], wr[2] - c[2] + LIFT, wl[6], wr[6]}
		-- The wheels and the head as the zones meet them (a gem taken by a
		-- wheel), from s.pos
		local ca, sa = math.cos(s.a), math.sin(s.a)
		local px, py = s.pos[1], s.pos[2]
		s.spheres = {{wl[1] - px, wl[2] - py, 0, R}, {wr[1] - px, wr[2] - py, 0, R},
			{c[1] + HX * s.dir * ca - HY * sa - px, c[2] + HX * s.dir * sa + HY * ca - py,
				0, HR}}
	end,
}
