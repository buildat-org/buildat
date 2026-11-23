-- [KIT_STUNTS] (4z37zzd (2)) Brimstone Stunts' heights, offline: the
-- template's stunt_yard built through a stand-in for its c (its default
-- corners: a figure eight, the bridge where it crosses itself, two tabletop
-- jumps) as the world over the flat ground (0: the road's top 0.555 the
-- car stands on), and kit/bot's own
-- controller (bot.lua's follow) driving types/stunt_car.lua along the
-- yard's racing line through move.lua's M.steps as kit.cpp steps a driving
-- bot. At skill 100 and 50 it goes round in order, never wrecks (no
-- "crash", no "smash"), and: on the bridge's deck its feet at the deck's
-- top (5.055), under it at the road's (0.555), never between there; off a
-- kicker's lip in the air for a while, at some height over its floor, and
-- landed again on its tyres; (4z37zzd (3)) round the loop (its up pointing
-- down at the top) and off it level, on its tyres. Then a car dropped 0.4 m
-- lands softly, one dropped 2.5 m lands hard (slowed, a bump), one dropped
-- 12 m crashes; one into the loop too slow falls off it and lands.
-- Run: lua util/kit_stunts_sim_check.lua (Lua 5.1 or LuaJIT), from the source tree's root.
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
local car_env = env()
car_env.math = MV.math
local T = "apps/workbench/templates/brimstone_stunts/types/"
local car = load_env(T .. "stunt_car.lua", car_env)
local bot = load_env("builtin/kit/types/bot.lua", env())
local function upvalue(f, name, depth)
	for i = 1, 255 do
		local n, v = debug.getupvalue(f, i)
		if not n then
			return
		end
		if n == name then
			return v
		end
		if type(v) == "function" and depth > 0 then
			local r = upvalue(v, name, depth - 1)
			if r then
				return r
			end
		end
	end
end
bot.follow = assert(upvalue(bot.on_timer, "follow", 3), "bot.lua's follow not found")
local yard = load_env(T .. "stunt_yard.lua", env())
-- (the loop's radius: stunt_yard's LOOP.r)
local LOOP_R = 6.5
local poly_t = load_env("builtin/kit/types/polygon.lua", env())
local kids = {}
-- (the race's pole where the template has it)
local gc = {params = {}, pos = {0, 0, 0}, entities = {{id = 1, pos = {-100, 0.5, -20},
	types = {"local/stunt_race"}}}}
for k, d in pairs(yard.params) do
	gc.params[k] = d.default
end
function gc:child(t) kids[#kids + 1] = t return #kids end
function gc:link() end
local loop_e
function gc:log(m)
	local x, z = tostring(m):match("loop at (%-?%d+),(%-?%d+)")
	loop_e = x and {tonumber(x), tonumber(z)} or loop_e
end
function gc:random(seed)
	local s = math.floor(tonumber(seed) or 0) % 2147483646 + 1
	local function nxt() s = s * 16807 % 2147483647 return (s - 1) / 2147483646 end
	return {next = function() return nxt() end,
		int = function(_, a, b) return a + math.floor(nxt() * (b - a + 1)) end}
end
yard.on_build(gc)
local polys, path, cps, facets = {}, nil, {}, {}
for _, k in ipairs(kids) do
	if k.name == "the loop" then
		facets[#facets + 1] = k
	end
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
	elseif k.type == "kit/checkpoint" then
		cps[#cps + 1] = k
	end
end
assert(path and #path.points >= 60, "no racing line from stunt_yard")
assert(loop_e and #facets >= 24, "no loop from stunt_yard")
-- (the way into the loop: its first facets' way)
local loop_d = {facets[2].pos[1] - facets[1].pos[1], facets[2].pos[3] - facets[1].pos[3]}
do
	local l = math.sqrt(loop_d[1] ^ 2 + loop_d[2] ^ 2)
	loop_d = {loop_d[1] / l, loop_d[2] / l}
end
assert(#cps == 3 and math.floor(cps[1].pos[2]) == 5, "checkpoint 1 not on the deck (y 5): " ..
	tostring(cps[1] and cps[1].pos[2]))
local yw = MV.world{cell = function() return nil end, plane = 1, horizontal = true,
	polys = polys, ground = function() return 0 end}
local function defaults()
	local p = {}
	for k, d in pairs(car.params) do
		p[k] = d.default
	end
	return p
end
-- (the bridge's deck and the tunnel under it: x -9...9 and z 2.5...17.5)
local function at_crossing(s)
	return math.abs(s.pos[1]) < 8 and s.pos[3] > 4 and s.pos[3] < 16
end
local function lap(skill)
	local p = defaults()
	local P = path.points
	local a, b = P[1], P[2]
	local s = {pos = {a[1], 0.5, a[3]}, yaw = math.deg(math.atan2(b[1] - a[1], b[3] - a[3]))}
	local st = {at = 0, slow = 0, back = 0, t = 0}
	local knobs = {skill = skill, grip = bot.params.grip.default, brake = bot.params.brake.default}
	local n, per = #P, math.floor(p.rate / 10 + 0.5)
	local inp = {f = 0, r = 0, jump = 0}
	local done, last, steps = 0, 1, 0
	local over, under, air, most, landed, flown, high, off, fast = 0, 0, 0, 0, 0, 0, 0, nil, 0
	-- (the loop: steps on it, its up's lowest y there, the steps since off it,
	-- level and on its tyres then)
	local looped, low, since, level = 0, 1, nil, false
	MV.steps(car, s, {inp}, 1 / p.rate, p.substeps, yw, p)
	while done < n do
		if steps % per == 0 then
			local o = bot.follow(st, {pos = s.pos, vel = s.vel, yaw = s.yaw, top = p.speed},
				path, knobs, per / p.rate)
			inp = {f = o.f, r = o.r, jump = 0}
			local d = (st.at - last) % n
			if d < n / 2 then
				done = done + d
			end
			last = st.at
		end
		MV.steps(car, s, {inp}, 1 / p.rate, p.substeps, yw, p)
		steps = steps + 1
		local y, t = s.pos[2], steps / p.rate
		for _, e in ipairs(s.events or {}) do
			local name = type(e) == "table" and e[1] or e
			assert(name ~= "crash" and name ~= "smash", string.format("skill %d: %s (%s) at " ..
				"%.1f,%.1f,%.1f after %.1f s", skill, name, tostring(e[2]), s.pos[1], y,
				s.pos[3], t))
		end
		if s.lp then
			looped, since = looped + 1, 0
			low = math.min(low, s.up and s.up[2] or 1)
		elseif since then
			since = since + 1
			if since == p.rate then
				level = not s.air and math.abs(tonumber(s.pt) or 0) < 0.05 and
					math.abs(tonumber(s.rl) or 0) < 0.05 and math.abs(y - 0.555) < 0.05
			end
		end
		if at_crossing(s) then
			assert(math.abs(y - 5.055) < 0.05 or math.abs(y - 0.555) < 0.05, string.format(
				"skill %d: at the crossing at y %.2f, neither on the deck nor under it", skill, y))
			if y > 3 then
				over = over + 1
			else
				under = under + 1
			end
		end
		-- (a flight: in the air over 0.2 s; its height over the floor as the
		-- car finds its floor, from 0.6 over it)
		if s.air then
			if flown == 0 then
				off = s.vel
			end
			flown = flown + 1 / p.rate
			local d = yw:down(s.pos[1], y + 0.6, s.pos[3], 20)
			high = math.max(high, (d or 20) - 0.6)
		elseif flown > 0 then
			if flown > 0.2 then
				air, landed, most = air + flown, landed + 1, math.max(most, high)
				fast = math.max(fast, math.sqrt(off[1] ^ 2 + off[3] ^ 2))
			end
			flown, high = 0, 0
		end
		assert(steps < 150 * p.rate, string.format("skill %d: no lap in 150 s (at point %d of %d)",
			skill, st.at, n))
	end
	assert(over > 0 and under > 0, string.format("skill %d: %d steps over the crossing, %d under",
		skill, over, under))
	assert(looped > 0 and low < -0.95 and level, string.format("skill %d: %d steps on the loop, " ..
		"its up's y %.2f at the lowest, %s a second after it", skill, looped, low,
		level and "level" or "not level"))
	assert(air > 0.5 and most > 0.3 and landed >= 2, string.format("skill %d: %.2f s in the " ..
		"air, %.2f m over the floor at most, %d flights", skill, air, most, landed))
	print(string.format("ok: a bot at skill %d drove a lap of the figure eight in %.1f s, over the " ..
		"bridge (%d steps on its deck) and under it (%d), %d flights over 0.2 s (%.2f s, %.2f m " ..
		"over its floor at most, off its lip at %.1f m/s), round the loop in %.1f s (up %.2f at the " ..
		"top) and off it level, never crashed", skill, steps / p.rate, over, under, landed,
		air, most, fast, looped / p.rate, low))
end
lap(100)
lap(50)

-- Dropped from a height onto the flat at 10 m/s: the speed kept, slowed, wrecked
local function drop(h)
	local p = defaults()
	local s = {pos = {0, 0.5, -40}, yaw = 0}
	MV.steps(car, s, {{f = 0, r = 0, jump = 0}}, 1 / p.rate, p.substeps, yw, p)
	s.c[4], s.pos[2], s.air = 10, 0.555 + h, true
	local crash, n = false, 0
	while s.air do
		MV.steps(car, s, {{f = 0, r = 0, jump = 0}}, 1 / p.rate, p.substeps, yw, p)
		for _, e in ipairs(s.events or {}) do
			crash = crash or type(e) == "table" and e[1] == "crash"
		end
		n = n + 1
		assert(n < 3 * p.rate, "dropped " .. h .. " m: not landed")
	end
	assert(math.abs(s.pos[2] - 0.555) < 0.01, "dropped " .. h .. " m: landed at " .. s.pos[2])
	return s.c[4], tonumber(s.bumps) or 0, crash
end
local v1, b1, c1 = drop(0.4)
local v2, b2, c2 = drop(2.5)
local _, _, c3 = drop(12)
assert(b1 == 0 and not c1 and v1 > 9, string.format("a 0.4 m drop: %.1f m/s, %d bumps", v1, b1))
assert(b2 == 1 and not c2 and v2 < v1 - 1.5, string.format("a 2.5 m drop: %.1f m/s, %d bumps",
	v2, b2))
assert(c3, "a 12 m drop did not crash")
print(string.format("ok: dropped 0.4 m it lands at %.1f m/s, 2.5 m slowed to %.1f with a bump, " ..
	"12 m it crashes", v1, v2))

-- Into the loop at 10 m/s (the gas held): up its side short of the top,
-- off it, then down (as hard as the landing rules have it: a crash from
-- there)
do
	local p = defaults()
	local v = 10
	local s = {pos = {loop_e[1] - 3 * loop_d[1], 0.555, loop_e[2] - 3 * loop_d[2]},
		yaw = math.deg(math.atan2(loop_d[1], loop_d[2]))}
	local inp = {{f = 1, r = 0, jump = 0}}
	MV.steps(car, s, inp, 1 / p.rate, p.substeps, yw, p)
	s.c[3], s.c[4] = v * loop_d[1], v * loop_d[2]
	local on, top, fell, landed, n, crash = false, -1, nil, nil, 0, false
	while not landed do
		MV.steps(car, s, inp, 1 / p.rate, p.substeps, yw, p)
		n = n + 1
		for _, e in ipairs(s.events or {}) do
			crash = crash or type(e) == "table" and e[1] == "crash"
		end
		if s.lp then
			on, top = true, math.max(top, s.pos[2])
		elseif on and not fell then
			fell = s.pos[2]
		elseif fell and not s.air then
			landed = s.pos[2]
		end
		assert(n < 6 * p.rate, string.format("too slow into the loop: %s after 6 s (at %.1f,%.1f,%.1f)",
			fell and "not landed" or on and "still on it" or "not on it", s.pos[1], s.pos[2], s.pos[3]))
	end
	assert(fell > 3 and top < 2 * LOOP_R, string.format("too slow into the loop: off it at %.1f m " ..
		"(%.1f at the highest)", fell, top))
	print(string.format("ok: into the loop at %.0f m/s it falls off it at %.1f m and lands at %.2f%s",
		v, fell, landed, crash and " (a crash)" or ""))
end

-- Into the loop off its line, the gas held: v m/s, its heading dy degrees
-- left of the loop's way, lo m left of its lane's middle at its foot, from
-- back m before it. Round it upside down, off it level, never under 2 m/s
-- on it for 0.3 s, no crash, no smash. (kit_stunts_check's failed run: in at
-- 18 m/s 15 degrees left from 1.3 m right, the tyres turned its speed back
-- into the left rail each step, the scrape slowed it and it fell off near
-- the top; a rail's end at a joint between facets, met as a wall, stopped
-- a car dead)
local function off_line(v, dy, lo, back)
	local p = defaults()
	local h = math.atan2(loop_d[1], loop_d[2]) - dy * math.pi / 180
	local fx, fz, b = math.sin(h), math.cos(h), back / math.cos(dy * math.pi / 180)
	local s = {pos = {loop_e[1] - loop_d[2] * lo - b * fx, 0.555, loop_e[2] + loop_d[1] * lo - b * fz},
		yaw = math.deg(h)}
	local inp = {{f = 1, r = 0, jump = 0}}
	MV.steps(car, s, inp, 1 / p.rate, p.substeps, yw, p)
	s.c[3], s.c[4] = v * fx, v * fz
	local what = string.format("into the loop at %d m/s, %d degrees left, %.1f m left", v, dy, lo)
	local on, low, slow, stalled, since, level = 0, 1, 0, 0, nil, false
	for _ = 1, 8 * p.rate do
		MV.steps(car, s, inp, 1 / p.rate, p.substeps, yw, p)
		for _, e in ipairs(s.events or {}) do
			local name = type(e) == "table" and e[1] or e
			assert(name ~= "crash" and name ~= "smash", string.format("%s: %s (%s) at %.1f,%.1f,%.1f",
				what, name, tostring(e[2]), s.pos[1], s.pos[2], s.pos[3]))
		end
		if s.lp then
			assert(not since, what .. ": on the loop again after it")
			local V = s.lp.v
			on, low = on + 1, math.min(low, s.up and s.up[2] or 1)
			slow = math.sqrt(V[1] ^ 2 + V[2] ^ 2 + V[3] ^ 2) < 2 and slow + 1 or 0
			stalled = math.max(stalled, slow)
		elseif on > 0 then
			since = (since or 0) + 1
			if since == p.rate then
				level = not s.air and math.abs(tonumber(s.pt) or 0) < 0.05 and
					math.abs(tonumber(s.rl) or 0) < 0.05 and math.abs(s.pos[2] - 0.555) < 0.05
				break
			end
		end
	end
	assert(on > 0 and low < -0.95 and level and stalled < 0.3 * p.rate, string.format("%s: %.2f s " ..
		"on it, its up's y %.2f at the lowest, %s a second after it, under 2 m/s on it %.2f s at most",
		what, on / p.rate, low, level and "level" or "not level", stalled / p.rate))
	return on / p.rate
end
local offs = {{18, 15, -1.3, 3}, {18, 15, -1, 3}, {18, -10, 0, 3}, {17, 10, 1, 3}, {20, 5, 0.5, 3},
	{20, 10, 0, 3}, {22, 10, 1, 6.3}, {22, -15, -1, 6.3}}
for _, o in ipairs(offs) do
	off_line(o[1], o[2], o[3], o[4])
end
print(string.format("ok: into the loop off its line (%d ways: 17-22 m/s, up to 15 degrees off its way, " ..
	"up to 1.3 m off its lane's middle) round it and off it level, never stalled on it, never " ..
	"crashed or smashed", #offs))

-- After a wreck: the race puts the car back at its last checkpoint (kit/
-- checkpoint's respawn: its middle, its yaw) in a new state (Kit's put: the
-- place 0.45 under it, the yaw). The gas held, it drives off it on its floor
-- (on the bridge's deck for the first), no crash, no smash
local cp_t = load_env("builtin/kit/types/checkpoint.lua", env())
local middle = assert(upvalue(cp_t.on_input, "middle", 0), "checkpoint.lua's middle not found")
for k, cp in ipairs(cps) do
	local p = defaults()
	local m = middle({params = cp.params, pos = cp.pos, yaw = cp.yaw})
	local s = {pos = {m[1], m[2] - 0.45, m[3]}, yaw = cp.yaw or 0}
	local floor = cp.pos[2] > 1 and 5.055 or 0.555
	local inp = {{f = 1, r = 0, jump = 0}}
	for n = 1, 2 * p.rate do
		MV.steps(car, s, inp, 1 / p.rate, p.substeps, yw, p)
		for _, e in ipairs(s.events or {}) do
			local name = type(e) == "table" and e[1] or e
			assert(name ~= "crash" and name ~= "smash", string.format("back at checkpoint %d: %s", k,
				name))
		end
		if n == math.floor(p.rate / 2) then
			assert(not s.air and math.abs(s.pos[2] - floor) < 0.05, string.format("back at " ..
				"checkpoint %d: at y %.2f, not on its floor (%.3f)", k, s.pos[2], floor))
		end
	end
	local moved = math.sqrt((s.pos[1] - m[1]) ^ 2 + (s.pos[3] - m[3]) ^ 2)
	assert(moved > 8, string.format("back at checkpoint %d (%.1f,%.1f,%.1f): %.1f m in 2 s", k,
		m[1], m[2], m[3], moved))
end
print(string.format("ok: put back at each of the %d checkpoints after a wreck, it drives off its " ..
	"floor there", #cps))
