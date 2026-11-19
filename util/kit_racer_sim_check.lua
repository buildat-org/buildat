-- [KIT_TOP_DOWN] Brimstone Speedway's handbrake turn, offline: the template's own
-- types/brim_car.lua stepped through builtin/kit/client_lua/move.lua's
-- M.steps as kit/controls steps it (rate inputs a second, substeps each), in
-- the level plane over a dirt floor polygon, by a fixed input script: full
-- throttle to 14 m/s, turned in 0.5 s at full lock left on the throttle (from
-- straight at 14 m/s the pull alone slides it some 4 degrees), the handbrake
-- 0.4 s at full lock, then on the throttle again steered toward the slide
-- while it slides over 5 degrees. It slides 20...60 degrees off the
-- heading, never spins (under 80), and is straight again within 1.5 s of
-- the pull, at the template's defaults and at a user's tuning (accel 9, grip
-- 8, steer 40), at rate 30 x 4 substeps and 60 x 2 alike. (The
-- in-game drift in util/kit_racer_check.sh is a driver's, its pull's
-- length and the server's batching uneven: there only the turn is asserted.)
-- Run: lua util/kit_racer_sim_check.lua (Lua 5.1 or LuaJIT), from the source tree's root.
local function load_env(path, env)
	local f = assert(loadfile(path))
	setfenv(f, env)
	return f()
end
local function env()
	return {math = math, ipairs = ipairs, pairs = pairs, type = type,
		tostring = tostring, tonumber = tonumber, setmetatable = setmetatable,
		table = table, string = string, error = error}
end
local MV = load_env("builtin/kit/client_lua/move.lua", env())
local car = load_env("apps/workbench/templates/brimstone_speedway/types/brim_car.lua", env())

-- The track's ground: a kit/polygon floor lying flat (pitch 90), surface dirt
local FLOOR = MV.look_poly({shape = "polygon", depth = 0.05, solid = false,
	floor = true, surface = "dirt", points = {{-500, -500}, {500, -500}, {500, 500},
	{-500, 500}}}, false, {0, 0, 0}, 0, 90, 0)
local w = MV.world{cell = function() return nil end, plane = 0.5, horizontal = true,
	polys = {FLOOR}}
assert(w:under(0, 0.6, 0) and w:under(0, 0.6, 0).surface == "dirt", "no dirt under the car")

local TURN_IN = 0.5
local function run(name, over)
	local p = {}
	for k, d in pairs(car.params) do
		p[k] = d.default
	end
	for k, v in pairs(over) do
		p[k] = v
	end
	local rate, sub = p.rate, p.substeps
	local s = {pos = {0, 0.5, 0}, yaw = 0}
	local function step(f, r, hb)
		MV.steps(car, s, {{f = f, r = r, jump = hb and 1 or 0}}, 1 / rate, sub, w, p)
	end
	local function speed()
		return math.sqrt(s.c[3] ^ 2 + s.c[4] ^ 2)
	end
	-- The velocity's angle off the heading, degrees (positive: to the right)
	local function slip()
		local a = math.atan2(s.c[3], s.c[4]) - s.h
		return math.deg((a + math.pi) % (2 * math.pi) - math.pi)
	end
	step(0, 0, false)
	local n = 0
	while speed() < 14 do
		step(1, 0, false)
		n = n + 1
		assert(n < 20 * rate, name .. ": never 14 m/s")
	end
	-- Turned in: full lock left on the throttle, as into a bend
	for _ = 1, math.floor(TURN_IN * rate + 0.5) do
		step(1, -1, false)
	end
	local h0, most, back, turned = s.h, 0, nil, 0
	local pull = math.floor(0.4 * rate + 0.5)
	for k = 1, pull + 3 * rate do
		local t = k / rate
		if k <= pull then
			step(0, -1, true)
		else
			-- (on the throttle, steered toward the way it goes while sliding,
			-- else straight)
			local sl = slip()
			step(1, math.abs(sl) > 5 and (sl > 0 and 1 or -1) or 0, false)
		end
		local sl = math.abs(slip())
		if speed() > 1 then
			most = math.max(most, sl)
		end
		turned = math.max(turned, math.abs(math.deg(s.h - h0)))
		if k > pull and not back and most > 12 and sl < 8 and speed() > 3 then
			back = t - pull / rate
		end
	end
	assert(most >= 20 and most <= 60, string.format("%s: slid %.0f deg off the heading, " ..
		"not 20...60", name, most))
	assert(most < 80, name .. ": spun")
	assert(back and back <= 1.5, string.format("%s: straight again %s s after the pull",
		name, tostring(back)))
	print(string.format("ok: %s (rate %d, substeps %d): the handbrake slid it %.0f deg " ..
		"off the heading, turned %.0f deg, straight again %.2f s after the pull", name,
		rate, sub, most, turned, back))
	return most, turned
end

run("brim_car's defaults", {})
local m30, t30 = run("accel 9, grip 8, steer 40", {accel = 9, grip = 8, steer = 40})
-- (the same 120 substeps a second: the same car, the inputs twice as often)
local m60, t60 = run("accel 9, grip 8, steer 40 at rate 60", {accel = 9, grip = 8,
	steer = 40, rate = 60, substeps = 2})
assert(math.abs(m30 - m60) < 2 and math.abs(t30 - t60) < 2, string.format(
	"rate 30 x 4 and 60 x 2 differ: slid %.1f and %.1f, turned %.1f and %.1f", m30, m60,
	t30, t60))
print("ok: rate 30 with 4 substeps drives as rate 60 with 2")

-- [KIT_GENERATORS] (4z37f) The run-off's gravel (brim_yard's, brim_car's GROUND.gravel:
-- grip and drag between dirt's and mud's). A car run wide at the top speed on
-- full throttle: 2 s on gravel 1...4 m/s slower than on dirt and less than on
-- mud; from 8 m/s on gravel on the throttle it picks up speed (it rejoins
-- the road, never stuck there)
local function floor_of(surf)
	return MV.world{cell = function() return nil end, plane = 0.5, horizontal = true,
		polys = {MV.look_poly({shape = "polygon", depth = 0.05, solid = false, floor = true,
		surface = surf, points = {{-900, -900}, {900, -900}, {900, 900}, {-900, 900}}},
		false, {0, 0, 0}, 0, 90, 0)}}
end
local function wide(surf, from)
	local p = {}
	for k, d in pairs(car.params) do
		p[k] = d.default
	end
	local s = {pos = {0, 0.5, 0}, yaw = 0}
	local function speed()
		return math.sqrt(s.c[3] ^ 2 + s.c[4] ^ 2)
	end
	local dirt, on = floor_of("dirt"), floor_of(surf)
	MV.steps(car, s, {{f = 0, r = 0, jump = 0}}, 1 / p.rate, p.substeps, dirt, p)
	local n = 0
	while speed() < from - 0.05 and n < 30 * p.rate do
		MV.steps(car, s, {{f = 1, r = 0, jump = 0}}, 1 / p.rate, p.substeps, dirt, p)
		n = n + 1
	end
	local v0 = speed()
	for _ = 1, 2 * p.rate do
		MV.steps(car, s, {{f = 1, r = 0, jump = 0}}, 1 / p.rate, p.substeps, on, p)
	end
	return v0, speed()
end
local _, vd = wide("dirt", 27.9)
local v0, vg = wide("gravel", 27.9)
local _, vm = wide("mud", 27.9)
assert(vd - vg >= 1 and vd - vg <= 4 and vg > vm, string.format(
	"2 s on the run-off from %.1f m/s: %.1f on gravel, %.1f on dirt, %.1f on mud", v0, vg, vd, vm))
local g0, g1 = wide("gravel", 8)
assert(g1 > g0 + 2, string.format("on gravel from %.1f m/s, 2 s on the throttle: %.1f", g0, g1))
print(string.format("ok: run wide at %.1f m/s, 2 s on the throttle: %.1f on gravel (%.1f on dirt, " ..
	"%.1f on mud); from %.1f m/s on gravel %.1f", v0, vg, vd, vm, g0, g1))

-- (4z37i (4)) A bot's lap of the Bone Yard: local/brim_yard's output (its
-- default corners, built here through a stand-in for its c) as the world,
-- its racing line (the kit/path it makes) as the line, kit/bot's own
-- controller (bot.lua's follow) driving brim_car as kit.cpp steps a driving
-- bot: its inputs each 0.1 s (a think), the car stepped at its rate and
-- substeps. At skill 0, 50 and 100 it goes round in order and is back where
-- it started within 150 s, never hits a wall hard, its middle never off the
-- road (the run-off's gravel allowed under skill 50), and the higher its
-- skill the faster.
local bot = load_env("builtin/kit/types/bot.lua", env())
local yard = load_env("apps/workbench/templates/brimstone_speedway/types/brim_yard.lua", env())
local poly_t = load_env("builtin/kit/types/polygon.lua", env())
local kids = {}
local gc = {params = {}, pos = {0, 0, 0}, entities = {}}
for k, d in pairs(yard.params) do
	gc.params[k] = d.default
end
function gc:child(t) kids[#kids + 1] = t return #kids end
function gc:link() end
function gc:log() end
yard.on_build(gc)
local polys, path = {}, nil
for _, k in ipairs(kids) do
	if k.type == "kit/polygon" then
		local look = {shape = "polygon"}
		for n, d in pairs(poly_t.params) do
			look[n] = d.default
		end
		for n, v in pairs(k.params) do
			look[n] = v
		end
		look.solid = look.collision
		polys[#polys + 1] = MV.look_poly(look, false, k.pos, k.yaw or 0, k.pitch or 0, k.roll or 0)
	elseif k.type == "kit/path" then
		path = {points = {}}
		for i, q in ipairs(k.params.points) do
			path.points[i] = {k.pos[1] + q[1], k.pos[2], k.pos[3] + q[2]}
		end
	end
end
assert(path and #path.points >= 60, "no racing line from brim_yard")
local yw = MV.world{cell = function() return nil end, plane = 1, horizontal = true,
	polys = polys}
local function lap(skill)
	local p = {}
	for k, d in pairs(car.params) do
		p[k] = d.default
	end
	local P = path.points
	local a, b = P[1], P[2]
	local s = {pos = {a[1], 0.5, a[3]}, yaw = math.deg(math.atan2(b[1] - a[1], b[3] - a[3]))}
	local st = {at = 0, slow = 0, back = 0, t = 0}
	local knobs = {skill = skill, grip = bot.params.grip.default, brake = bot.params.brake.default}
	local n, per = #P, math.floor(p.rate / 10 + 0.5)
	local inp = {f = 0, r = 0, jump = 0}
	local done, last, steps, gravel = 0, 1, 0, 0
	MV.steps(car, s, {inp}, 1 / p.rate, p.substeps, yw, p)
	while done < n do
		if steps % per == 0 then
			local o = bot.follow(st, {pos = s.pos, vel = s.vel, yaw = s.yaw, top = p.speed},
				path, knobs, per / p.rate)
			inp = {f = o.f, r = o.r, jump = 0}
			-- (along the line in order: a step back is no progress)
			local d = (st.at - last) % n
			if d < n / 2 then
				done = done + d
			end
			last = st.at
		end
		MV.steps(car, s, {inp}, 1 / p.rate, p.substeps, yw, p)
		steps = steps + 1
		local u = yw:under(s.c[1], 0.6, s.c[2])
		local surf = u and u.surface or "none"
		if surf == "gravel" then
			gravel = gravel + 1 / p.rate
		end
		assert(surf ~= "none" and (surf ~= "gravel" or skill < 50), string.format(
			"skill %d: off the road (%s) at %.1f,%.1f after %.1f s", skill, surf, s.c[1],
			s.c[2], steps / p.rate))
		assert((tonumber(s.bumps) or 0) == 0, string.format("skill %d: hit a wall at %.1f,%.1f " ..
			"(%.1f m/s) after %.1f s", skill, s.c[1], s.c[2], s.bump_v or 0, steps / p.rate))
		assert(steps < 150 * p.rate, string.format("skill %d: no lap in 150 s (at point %d of %d)",
			skill, st.at, n))
	end
	local t = steps / p.rate
	print(string.format("ok: a bot at skill %d drove a lap of the Bone Yard's racing line in %.1f s " ..
		"(%.1f s on the run-off's gravel), no wall hit", skill, t, gravel))
	return t
end
local t0, t50, t100 = lap(0), lap(50), lap(100)
assert(t100 < t50 and t50 < t0, string.format("the laps not faster by skill: %.1f, %.1f, %.1f",
	t0, t50, t100))
