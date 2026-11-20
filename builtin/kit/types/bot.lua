-- A bot ([KIT_GUIDE_BOTS], kit_plan 4z7): a creature that does the goals
-- (kit/goal) a player would, its own goal state as each player's ("bot:<id>"
-- where a player's is "player:<id>"). For its active goal (c.goal, the
-- server's: the first by id active for it, not audience "players"): "reach"
-- walks into the goal's box; "use" walks to its target and uses it; "signal"
-- walks to what makes the signal (the goal's `via`) and uses it once. A signal
-- goal with no via, or one its via's use did not do in `patience` seconds,
-- leaves it stuck: a log line and "(stuck)" on its nameplate. Drawn as a
-- player. [KIT_GUIDE_BOTS_2] A player everywhere (kit.cpp's bots): in
-- c.players, teams, queues and rounds; its goal the first it can act on
-- now; "place_item" walks to the target and uses what it carries there; a
-- use or a place not done in `patience` seconds is tried again.
-- [KIT_GOAL_PRIORITIES] Its goal the highest priority one it can act on
-- (kit/goal's). "attack": it walks to the target and, within the item's
-- reach, hurts it for the item's damage once a cooldown; "place_item" with
-- an item (c.goal.item): it uses the item there (c:use_item).
-- [KIT_GUIDE_STATIONS] A reach or an attack goal whose via is a station
-- (c.goal.station: a seat on a steered vehicle whose movement declares
-- `station`): it takes the seat (walks within reach; one on a ship from
-- anywhere, kit.cpp's bot_seat), then drives through the seat's inputs
-- (c:drive): a "helm" into the goal's box, the rudder on the bearing and
-- forward slowing as it nears; a "gun" turned and raised onto the arc that
-- meets the target (c.aim: the shot's speed and gravity, move.lua's M.aim),
-- fired while within about a target's width of it. It leaves the seat for a
-- goal elsewhere; with none it stays, its inputs let go.
-- [KIT_BOT_DIFFICULTY] Its knobs, its state from its parameters: `aim` (%,
-- a hand's hit lands at that chance; a gun aims up to AIM_OFF degrees off
-- at 0, a new error after each shot), `reaction` (s: it stands that long at
-- a new goal, and waits that long before its first hit once in reach) and
-- `speed` (% of its walk). "ask" (a kit/spawner's, for a copy made for a
-- player) asks that player for them: a dialog on their screen
-- (bot.client.lua), the bot standing until they answer ("kit:ui_text"
-- "<id> <aim> <reaction> <speed>", or "cancel": it is gone) or ASK_S pass.
-- A round's copy of it carries them (kit.cpp's bots_into, its state).
-- [KIT_AIRSHIPS_BOTS_LEFTOVERS] Hurt, or the ship it crews hit, by someone
-- not aboard: for 30 s its goal is "fight back" (id -1, before any other), an
-- attack on them through that ship's gun if nobody else holds it (kit.cpp's
-- bot_foe_lit). A ship's gun's shots pass its own crew.
-- [KIT_AIRSHIPS_BOTS_2] Hurt on foot: the "fight back" goal is an attack on
-- them on foot (kit.cpp's bot_foe_lit); [KIT_CTF_BOTS_FIX] not while it
-- carries something to place (a flag home), and a death, its or theirs,
-- ends it. Kind "crew" (kit.cpp's crew_lit) comes
-- as the step it is on, each its own text (a new step a new goal here): a
-- helm's `keep` (m) is how far from the goal's place it stops, a gun's
-- `hold` aims without firing.
-- [KIT_BOT_DRIVE] (4z37i (4)) `drive`: no goals; it drives the players'
-- movement (the scene's kit/controls': a race's car) along a kit/path
-- (`path`, else its scene's first; c.path), its inputs follow()'s, its
-- one knob `skill` (%: how near the line, how late its braking and how
-- fast; the `skill` input, its dialog's one row). kit.cpp steps it as a
-- player's body: c:speed, c:body_var, the movement's events and zones as
-- for a player.
-- simplified: one goal at a time; a bot's use passes no who-may-use
-- rule (a region's or a part's own), the upgrade is may_use() for a bot
local DEG = 180 / math.pi

local function clamp(x)
	return x < -1 and -1 or x > 1 and 1 or x
end

local function wrap(a)
	return (a + 180) % 360 - 180
end

-- The seconds over which an input closes an error (two of its thinks)
local CLOSE = 0.25
-- A gun's most error (degrees, at aim 0); how long a dialog waits
local AIM_OFF, ASK_S = 8, 60
local KNOBS = {"aim", "reaction", "speed"}
-- [KIT_BOT_DRIVE] a driving bot's one knob
local DRIVE_KNOBS = {"skill"}

local function move(c, to, range)
	c:propose_move({to = to, range = range,
		speed = math.max(0.1, c.state.speed / 100)})
end

local function knobs(c)
	if c.params.drive then
		return "skill " .. c.state.skill .. "%"
	end
	return "aim " .. c.state.aim .. "%, reaction " .. c.state.reaction ..
			" s, speed " .. c.state.speed .. "%"
end

local function helm(g, s)
	-- (from the seat: it is what must be in the box)
	local dx, dz = g.at[1] - s.at[1], g.at[3] - s.at[3]
	local err = wrap(math.atan2(dx, dz) * DEG - s.yaw)
	local want = math.min(tonumber(s.params.top_speed) or 8,
			math.max(0, math.sqrt(dx * dx + dz * dz) - (g.keep or 0)) * 0.4)
	return {f = clamp((want - s.speed) * 0.5), r = clamp(err / 20)}
end

local function gun(c, g, s)
	local p, m = s.params, s.muzzle
	local dx, dy, dz = g.at[1] - m[1], g.at[2] - m[2], g.at[3] - m[3]
	local d = math.sqrt(dx * dx + dz * dz)
	local st = c.state
	local yerr = wrap(math.atan2(dx, dz) * DEG + st.off_y - s.yaw)
	-- Its elevation's limits as the world has them now (the deck's tilt in)
	local tilt = s.elev + s.pitch
	local v, grav = tonumber(p.shot_speed) or 40, tonumber(p.shot_gravity) or 9.8
	local a = c.aim and c.aim(v, grav, d, dy, (tilt - (tonumber(p.pitch_max) or 10)) / DEG,
			(tilt - (tonumber(p.pitch_min) or -60)) / DEG)
	if a and d / (v * math.cos(a)) > s.life then
		a = nil
	end
	local eerr = a and a * DEG + st.off_e - s.elev or 0
	local tol = math.max(0.25, math.min(2, math.atan2(0.4, d) * DEG))
	local fire = a ~= nil and not g.hold and math.abs(yerr) < tol and
			math.abs(eerr) < tol
	if fire then
		-- [KIT_BOT_DIFFICULTY] the next shot's error
		local m = AIM_OFF * (100 - st.aim) / 100
		st.off_y, st.off_e = (math.random() * 2 - 1) * m, (math.random() * 2 - 1) * m
	end
	return {f = clamp(eerr / ((tonumber(p.pitch_rate) or 30) * CLOSE)),
		r = clamp(yerr / ((tonumber(p.turn_rate) or 60) * CLOSE)),
		fire = fire}
end

-- [KIT_BOT_DRIVE] A driving bot's inputs for now ({f, r}: the players'
-- keys) on path (c.path: {points = {{x, y, z}...}}, a loop), its body b
-- (c.body: {pos, vel, yaw, top}) and k (skill %, grip and brake m/s^2);
-- st its memory (the bot's state: at, slow, back, t, yaw0), dt since the
-- last. Steered toward a point ahead on the line (further the faster),
-- off it by up to WANDER m at skill 0 (slowly to and fro), less the
-- turn's own rate; its speed the least of the car's top (times 0.7...1 by
-- skill) and what each bend ahead allows (sqrt(grip x its radius)) with
-- the braking to it (at brake, after a reaction's run); off the throttle
-- while it slides. Stuck (under 1 m/s on the throttle 1.5 s) or facing
-- the wrong way: backs off steered the other way, then on again.
-- simplified: no handbrake; a lone car's line (nobody overtaken round)
local WANDER, STUCK_S, BACK_S = 1.2, 1.5, 1.2

local function radius(P, i)
	local n = #P
	local a, b, q = P[(i - 2) % n + 1], P[(i - 1) % n + 1], P[i % n + 1]
	local cr = (b[1] - a[1]) * (q[3] - a[3]) - (b[3] - a[3]) * (q[1] - a[1])
	if cr > -1e-6 and cr < 1e-6 then
		return 1e9
	end
	local function d(u, v)
		return math.sqrt((u[1] - v[1]) ^ 2 + (u[3] - v[3]) ^ 2)
	end
	return d(a, b) * d(b, q) * d(a, q) / (2 * math.abs(cr))
end

local function follow(st, b, path, k, dt)
	local P = path.points
	local n = #P
	local x, z = b.pos[1], b.pos[3]
	local vx, vz = b.vel[1], b.vel[3]
	local v = math.sqrt(vx * vx + vz * vz)
	local yaw = b.yaw
	local s = math.max(0, math.min(100, k.skill)) / 100
	st.t = st.t + dt
	-- Where on the line: the nearest segment (near the last, else anywhere)
	local best, bi, bt
	local function try(i)
		local a, q = P[(i - 1) % n + 1], P[i % n + 1]
		local ex, ez = q[1] - a[1], q[3] - a[3]
		local l2 = ex * ex + ez * ez
		local t = l2 > 0 and math.max(0, math.min(1, ((x - a[1]) * ex + (z - a[3]) * ez) / l2)) or 0
		local px, pz = a[1] + ex * t - x, a[3] + ez * t - z
		local d2 = px * px + pz * pz
		if not best or d2 < best then
			best, bi, bt = d2, (i - 1) % n + 1, t
		end
	end
	if st.at >= 1 then
		for i = st.at - 3, st.at + 8 do
			try(i)
		end
	end
	if not best or best > 15 * 15 then
		best = nil
		for i = 1, n do
			try(i)
		end
	end
	st.at = bi
	-- The point ahead: along the line from there, off it by the wander
	local function seg(i)
		local a, q = P[(i - 1) % n + 1], P[i % n + 1]
		return a, q, math.sqrt((q[1] - a[1]) ^ 2 + (q[3] - a[3]) ^ 2)
	end
	local look = 4 + 0.45 * v
	local i, a, q, l = bi, seg(bi)
	local u = bt * l + look
	for _ = 1, n do
		if u <= l then
			break
		end
		u = u - l
		i = i + 1
		a, q, l = seg(i)
	end
	local f = l > 0 and u / l or 0
	local ox, oz = l > 0 and (q[3] - a[3]) / l or 0, l > 0 and -(q[1] - a[1]) / l or 0
	local off = WANDER * (1 - s) * math.sin(st.t * 0.45 + (k.seed or 0))
	local tx = a[1] + (q[1] - a[1]) * f + ox * off
	local tz = a[3] + (q[3] - a[3]) * f + oz * off
	local bearing = math.atan2(tx - x, tz - z) * DEG
	local err = wrap(bearing - yaw)
	local rate = wrap(yaw - (st.yaw0 or yaw)) / dt
	st.yaw0 = yaw
	-- Backing off: steered the other way (the nose swings toward the line)
	if st.back > 0 then
		st.back = st.back - dt
		return {f = -1, r = err > 0 and -1 or 1}
	end
	if math.abs(err) > 110 and v < 6 then
		st.back = BACK_S
		return {f = -1, r = err > 0 and -1 or 1}
	end
	-- The speed: the bends' ahead within the braking's reach
	local grip = k.grip * (0.5 + 0.5 * s)
	local brake = k.brake * (0.6 + 0.4 * s)
	local react = 0.7 - 0.5 * s
	local vt = (b.top or 30) * (0.7 + 0.3 * s)
	local reach = v * v / (2 * brake) + v * react + 10
	local _, _, l0 = seg(bi)
	local dist = (1 - bt) * l0
	for j = bi + 1, bi + n do
		if dist > reach then
			break
		end
		local vc = math.sqrt(grip * radius(P, j))
		local free = math.max(0, dist - v * react)
		vt = math.min(vt, math.sqrt(vc * vc + 2 * brake * free))
		local _, _, lj = seg(j)
		dist = dist + lj
	end
	-- (the way it goes, a slide's too; under a crawl its nose)
	local head = v > 3 and math.atan2(vx, vz) * DEG or yaw
	local steer = wrap(bearing - head) - 0.15 * rate
	local slide = v > 3 and math.abs(wrap(head - yaw)) > 15
	local fw = clamp((vt - v) * 0.5)
	if slide and fw > 0 then
		fw = 0
	end
	-- Stuck: on the throttle, hardly moving
	if fw > 0.3 and v < 1 then
		st.slow = st.slow + dt
		if st.slow > STUCK_S then
			st.slow, st.back = 0, BACK_S
		end
	else
		st.slow = 0
	end
	return {f = fw, r = clamp(steer / 12)}
end

-- [KIT_BOT_DRIVE] A driving bot's think: c:drive (kit.cpp steps the scene's
-- players' movement for it, not a seat's) by follow() on c.path. Held
-- (asked, no path, or its car stopped by c:speed: a race's grid): its
-- inputs let go, its being stuck forgotten
local function drive_think(c)
	local b, p, st = c.body, c.path, c.state
	if st.asker ~= 0 or not b or not p or #p.points < 3 or (b.top or 0) < 0.1 then
		st.slow, st.back = 0, 0
		c:drive({})
		return
	end
	c:drive(follow(st, b, p, {skill = st.skill, grip = c.params.grip,
		brake = c.params.brake, seed = c.id}, 0.1))
end

-- A goal's key: its id and its text (a "crew" goal's step)
local function gkey(g)
	return g.id .. " " .. g.text
end

local function plate(c)
	local p = c.params.name .. " " .. c.id .. (c.state.stuck and "\n(stuck)" or "")
	if p ~= c.state.plate then
		c.state.plate = p
	end
end

local function stuck(c, g, why)
	if c.state.stuck then
		return
	end
	c.state.stuck = true
	c:log("stuck on goal", g.id .. ":", why)
	c:emit("stuck", why)
	c:propose_move(nil)
	plate(c)
end

local function think(c)
	if c.params.drive then
		drive_think(c)
		return plate(c)
	end
	local g = c.goal
	local st = g and g.station
	if c.state.asker ~= 0 then
		c:propose_move(nil)
		return plate(c)
	end
	if not g then
		c:propose_move(nil)
		c.state.goal, c.state.stuck = 0, false
		if c.seat ~= 0 then
			c:drive({})
		end
		plate(c)
		return
	end
	if c.seat ~= 0 and not (st and st.held) then
		c:log("leaves the seat of", c.seat, "for goal", g.id)
		c:leave_seat()
		return plate(c)
	end
	if gkey(g) ~= c.state.goal then
		c.state.goal, c.state.used, c.state.stuck = gkey(g), false, false
		c:log("goal", g.id, g.kind, "\"" .. g.text .. "\"")
		c.state.ready = c.state.reaction <= 0
		if not c.state.ready then
			c:after(c.state.reaction, "react")
		end
	end
	if c.state.stuck then
		return plate(c)
	end
	if not c.state.ready then
		c:propose_move(nil)
		return plate(c)
	end
	if st and st.held then
		c:drive(st.does == "gun" and gun(c, g, st) or helm(g, st))
	elseif st then
		if st.dist > c.params.reach and not st.board then
			move(c, st.at, c.params.reach * 0.6)
		elseif not c.state.used then
			c:propose_move(nil)
			c.state.used = true
			c:log("takes the", st.does, "at", st.seat, "for goal", g.id)
			c:use(st.seat)
			c:after(math.min(2, c.params.patience), "patience")
		end
	elseif g.kind == "signal" and not g.via then
		stuck(c, g, "nothing to use for \"" .. g.text .. "\" (no via)")
	elseif g.kind == "reach" then
		move(c, g.at, 0.3)
	elseif g.kind == "attack" then
		local reach = math.max(1, g.reach or 2)
		move(c, g.at, reach * 0.6)
		-- [KIT_BOT_DIFFICULTY] in reach of a new target: its reaction first
		if g.dist > reach then
			c.state.near = 0
		elseif c.state.near ~= g.target and c.state.reaction > 0 then
			c.state.near, c.state.cooling = g.target, true
			c:after(c.state.reaction, "cool")
		elseif not c.state.cooling then
			c.state.near = g.target
			if math.random() * 100 < c.state.aim then
				c:hurt(g.target, {amount = g.damage or 1, type = "normal"})
				c:log("hits", g.target, "with", g.item or "a hand", "for goal", g.id)
			else
				c:log("misses", g.target, "for goal", g.id)
			end
			c.state.cooling = true
			c:after(math.max(0.3, g.cooldown or 0.5), "cool")
		end
	elseif g.kind == "place_item" and g.item then
		if g.dist > c.params.reach then
			move(c, g.at, c.params.reach * 0.6)
		elseif not c.state.used then
			c:propose_move(nil)
			c.state.used = true
			c:log("uses", g.item, "for goal", g.id)
			c:use_item(g.item)
			c:after(math.min(2, c.params.patience), "patience")
		end
	else
		local t = g.kind == "use" and g.target or g.kind == "place_item" and
				g.carry or g.via
		if g.dist > c.params.reach then
			move(c, g.at, c.params.reach * 0.6)
		elseif not c.state.used then
			c:propose_move(nil)
			c.state.used = true
			c:log("uses", t, "for goal", g.id)
			c:use(t)
			c:after(g.kind == "signal" and c.params.patience or
					math.min(2, c.params.patience), "patience")
		end
	end
	plate(c)
end

return {
	version = 1,
	about = {
		what = "A bot: it works through the goals a player would, one at a time.",
		inputs = {
			ask = "Shows the player who set it off a dialog for its settings.",
			skill = "Sets a driving bot's skill. Value: 0 to 100 (%).",
		},
		outputs = {
			stuck = "It cannot reach its goal. Value: the reason.",
		},
	},
	component = true,
	creature = true,
	bot = true,
	-- (its dialog's answer, kit:ui_text, its own check of who)
	takes_text = true,
	look = {shape = "box", size = {0.6, 1.8, 0.6}, color = "none", text = "plate",
		text_color = "#c0e0ff"},
	params = {
		name = {type = "string", default = "Bot"},
		-- (m, from what it uses; Kit's use range is the most)
		reach = {type = "number", default = 2.5, min = 0.5, max = 8},
		patience = {type = "number", default = 10, min = 1, max = 120},
		-- [KIT_BOT_DIFFICULTY] (%, s, %)
		aim = {type = "number", default = 75, min = 0, max = 100},
		reaction = {type = "number", default = 0.4, min = 0, max = 3},
		speed = {type = "number", default = 90, min = 30, max = 100},
		-- [KIT_BOT_DRIVE] (a kit/path: 0 its scene's first; %; m/s^2 the
		-- lateral acceleration it takes a bend at and its braking, at skill
		-- 100: Brimstone Speedway's car's on dirt)
		drive = {type = "bool", default = false},
		path = {type = "entity", default = 0},
		skill = {type = "number", default = 60, min = 0, max = 100},
		grip = {type = "number", default = 12, min = 1, max = 40},
		brake = {type = "number", default = 8, min = 1, max = 40},
	},
	state = {
		plate = {default = "", shared = true},
		goal = {default = 0},
		used = {default = false},
		stuck = {default = false},
		cooling = {default = false},
		ready = {default = true},
		near = {default = 0},
		off_y = {default = 0},
		off_e = {default = 0},
		-- (shared: its dialog starts at them)
		aim = {default = 75, param = "aim", shared = true},
		reaction = {default = 0.4, param = "reaction", shared = true},
		speed = {default = 90, param = "speed", shared = true},
		-- (the player its dialog is up for, 0 none; their by)
		asker = {default = 0, shared = true},
		asked = {default = ""},
		-- [KIT_BOT_DRIVE] (shared: its dialog); follow()'s memory
		skill = {default = 60, param = "skill", shared = true},
		driving = {default = false, param = "drive", shared = true},
		at = {default = 0},
		slow = {default = 0},
		back = {default = 0},
		t = {default = 0},
		yaw0 = {default = false},
	},
	inputs = {ask = "none", skill = "number"},
	outputs = {stuck = "string"},
	-- (util/kit_racer_sim_check.lua drives with follow offline, an upvalue
	-- of on_timer's: the type table holds Kit's fields alone)
	on_start = function(c)
		c.state.goal, c.state.used, c.state.stuck = 0, false, false
		c.state.cooling, c.state.ready, c.state.near = false, true, 0
		c.state.off_y, c.state.off_e = 0, 0
		c.state.asker, c.state.asked = 0, ""
		c:log("knobs:", knobs(c))
		plate(c)
		c:after(0.25)
	end,
	on_input = function(c, input, value, by)
		if input == "skill" and tonumber(value) then
			c.state.skill = math.max(0, math.min(100, tonumber(value)))
			return c:log("knobs:", knobs(c), "by", c:name(by))
		end
		local pid = tonumber(tostring(by):match("^player:(%d+)$"))
		if input ~= "ask" or not pid then
			return
		end
		c.state.asker, c.state.asked = pid, by
		c:log("asks", c:name(by), "for its knobs")
		c:after(ASK_S, "ask")
	end,
	on_ui = function(c, phase, by, text)
		if phase ~= "entered" or c.state.asker == 0 or by ~= c.state.asked then
			return c:log("an answer from", c:name(by), "not asked: ignored")
		end
		c.state.asker = 0
		if text == "cancel" then
			c:log("cancelled by", c:name(by))
			return c:remove()
		end
		local i = 0
		for w in tostring(text):gmatch("%S+") do
			i = i + 1
			local k, v = (c.params.drive and DRIVE_KNOBS or KNOBS)[i], tonumber(w)
			if k and v and v == v then
				c.state[k] = math.max(k == "speed" and 30 or 0,
						math.min(k == "reaction" and 3 or 100, v))
			end
		end
		c:log("knobs:", knobs(c), "by", c:name(by))
	end,
	on_timer = function(c, name)
		if name == "cool" then
			c.state.cooling = false
			return
		end
		if name == "react" then
			c.state.ready = true
			return
		end
		if name == "ask" then
			if c.state.asker ~= 0 then
				c.state.asker = 0
				c:log("no answer: knobs", knobs(c))
			end
			return
		end
		-- Its via used and the goal still there
		if name == "patience" then
			local g = c.goal
			if g and gkey(g) == c.state.goal and c.state.used then
				-- [KIT_GUIDE_BOTS_2] a use or a place again (a moving target)
				if g.kind ~= "signal" then
					c.state.used = false
					return
				end
				stuck(c, g, "using " .. (g.via or g.target) .. " did not do \"" .. g.text .. "\"")
			end
			return
		end
		think(c)
		-- (at a station, oftener: its inputs follow what it aims at)
		c:after((c.seat ~= 0 or c.params.drive) and 0.1 or 0.25)
	end,
}
