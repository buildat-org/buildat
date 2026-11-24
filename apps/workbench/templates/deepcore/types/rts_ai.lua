-- Deepcore's computer player ([KIT_RTS], kit_plan 4z37zzo): one side's
-- opponent, after the approach of the user's Ternadim skirmish AI (its own
-- Lua; nothing of that code). Started and stopped by its match ("start",
-- "stop"); every `think` seconds while on:
--   goals, each "have X" met through what X needs first (a harvester needs a
--   factory and a refinery, a unit a factory, a building the HQ: the one
--   missing is bought first): a refinery and two harvesters a refinery (four
--   at most), a factory, attack units (4 + 8 x `aggression` tanks) and
--   `defence` tanks (one more while it has `rich` money), a digger; money
--   kept back: nothing is bought that would leave under `reserve` (but the
--   first refinery and harvester), while money comes in (none for `dry` s:
--   the reserve spent too);
--   activities in a random order each time: attack, defend, scout, dig.
-- Its units are in two pools, attack and defence, assigned as they come (one
-- in three to defence while it has fewer than it wants), all defenders let go
-- now and then (`pool_time`) when there are more than its buildings call for.
-- Idle attackers, once there are a wave of them (fewer the more aggressive;
-- any at all after `patience` s with no wave sent, or with no money coming
-- in; none before `first_wave` s), go for the enemy seen nearest our units
-- (seen: within `sight` m of one of ours: it does not see through the
-- fog), else where one was last seen,
-- else the enemy's base, along `route` (points "x y z, ..." from its base to
-- the enemy's: a long way taken a point at a time); with no enemy seen for a
-- while one goes as a scout to a random point of the map none of ours sees.
-- Defenders go for an enemy seen within 16 m of our buildings. Its digger
-- digs to the ore in the rock nearest its base (a cell short of it: the ore
-- the harvesters'), then a way towards the enemy's base, each goal kept
-- until the digger is there or gets no nearer for `dig_patience` s (hard
-- rock: given up, not tried again).
-- It buys through its match ("build" "<Team> <what>") and orders its units
-- with c:order, the way a player's orders go (kit/unit's on_order).
-- An attacker shooting at one target for `aim_time` s (a wall or its own in
-- the way) is free again, that target left alone a minute.
-- Knobs: aggression, reserve, defence, think, pool_time, dry, patience,
-- first_wave, rich, aim_time (params).
-- simplified: one factory, one refinery; no retreat, no repair; buildings
-- placed by its match (at random round its HQ)
local COST = {harvester = 80, digger = 60, tank = 100, refinery = 150, factory = 200}
local NEEDS = {harvester = {"factory", "refinery"}, digger = {"factory"},
	tank = {"factory"}, refinery = {"hq"}, factory = {"hq"}, hq = {}}

local function d2(a, b)
	return (a[1] - b[1]) ^ 2 + (a[3] - b[3]) ^ 2
end

local function route(s)
	local r = {}
	for x, y, z in tostring(s):gmatch("(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)") do
		r[#r + 1] = {tonumber(x), tonumber(y), tonumber(z)}
	end
	return r
end

local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(1, i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

-- What it knows this think: its units by kind, the enemy it sees, money
local function look(c)
	local p = c.params
	local k = {mine = {}, by = {}, seen = {}, buildings = 0, money = 0}
	local enemy = {}
	for _, u in ipairs(c.units or {}) do
		if u.team == p.team then
			k.mine[#k.mine + 1] = u
			k.by[u.name] = k.by[u.name] or {}
			table.insert(k.by[u.name], u)
			if u.name == "hq" or u.name == "refinery" or u.name == "factory" then
				k.buildings = k.buildings + 1
			end
		elseif u.team == p.enemy then
			enemy[#enemy + 1] = u
		end
	end
	local r2 = p.sight ^ 2
	for _, e in ipairs(enemy) do
		for _, m in ipairs(k.mine) do
			if d2(e.pos, m.pos) <= r2 then
				k.seen[#k.seen + 1] = e
				break
			end
		end
	end
	for _, t in ipairs(c.teams or {}) do
		if t.params.name == p.team then
			k.money = t.state.score or 0
		end
	end
	return k
end

local function n_of(k, what)
	return k.by[what] and #k.by[what] or 0
end

-- "Have n of what": true when there are; else what it needs first, then a
-- buy of it if the money allows (pending ones counted)
local function have(c, k, what, n, must)
	local s = c.state
	local pend = s.pending[what]
	local queued = pend and c.now - pend < 5 and 1 or 0
	if n_of(k, what) + queued >= n then
		return n_of(k, what) >= n
	end
	for _, need in ipairs(NEEDS[what] or {}) do
		if not have(c, k, need, 1, must) then
			return false
		end
	end
	local cost = COST[what] or 0
	-- (the reserve kept while money comes in: with none for `dry` s it is
	-- spent)
	local keep = (must or c.now - s.income_at > c.params.dry) and 0 or c.params.reserve
	if k.money - cost < keep then
		return false
	end
	k.money = k.money - cost
	s.pending[what] = c.now
	c:send(c.params.match, "build", c.params.team .. " " .. what)
	c:log("buys a " .. what .. " (" .. math.floor(k.money) .. " left)")
	return false
end

local function idle(u)
	return not u.moving and (u.target or 0) == 0
end

-- The way to a place far off: the route's next point past the nearest one
local function towards(c, from, to)
	local r = route(c.params.route)
	if #r == 0 or d2(from, to) < 30 ^ 2 then
		return to
	end
	-- the route runs from our base to theirs; going home it runs back
	local home = d2(to, c.params.base) < d2(to, c.params.enemy_base)
	local best, bd = 1, 1e18
	for i, q in ipairs(r) do
		local d = d2(q, from)
		if d < bd then
			best, bd = i, d
		end
	end
	local nxt = home and math.max(1, best - (bd < 9 and 1 or 0)) or
		math.min(#r, best + (bd < 9 and 1 or 0))
	return r[nxt]
end

local function pools(c, k)
	local s = c.state
	local tanks = k.by.tank or {}
	local alive, def = {}, 0
	for _, u in ipairs(tanks) do
		alive[tostring(u.id)] = true
		if s.pools[tostring(u.id)] == "defence" then
			def = def + 1
		end
	end
	for id in pairs(s.pools) do
		if not alive[id] then
			s.pools[id] = nil
		end
	end
	if c.now - s.pooled > c.params.pool_time then
		s.pooled = c.now
		if def > math.max(c.params.defence, k.buildings) then
			for id, v in pairs(s.pools) do
				if v == "defence" then
					s.pools[id] = nil
				end
			end
			def = 0
		end
	end
	for _, u in ipairs(tanks) do
		local id = tostring(u.id)
		if not s.pools[id] then
			if def < c.params.defence and math.random(1, 3) == 1 then
				s.pools[id] = "defence"
				def = def + 1
			else
				s.pools[id] = "attack"
			end
		end
	end
end

local function pool(c, k, which)
	local out = {}
	for _, u in ipairs(k.by.tank or {}) do
		if c.state.pools[tostring(u.id)] == which then
			out[#out + 1] = u
		end
	end
	return out
end

local function middle(us)
	local m = {0, 0, 0}
	for _, u in ipairs(us) do
		for i = 1, 3 do
			m[i] = m[i] + u.pos[i] / #us
		end
	end
	return m
end

local ACT = {}

function ACT.attack(c, k)
	local s, p = c.state, c.params
	local free = {}
	for _, u in ipairs(pool(c, k, "attack")) do
		local id, a = tostring(u.id), s.aims[tostring(u.id)]
		if idle(u) and id ~= tostring(s.scout) then
			free[#free + 1] = u
		elseif (u.target or 0) == 0 then
			s.aims[id] = nil
		elseif not a or a[1] ~= u.target then
			s.aims[id] = {u.target, c.now}
		elseif c.now - a[2] > p.aim_time then
			-- (at one target that long, still there: it does not hit it, a
			-- wall or its own in the way; free, the target left a while)
			s.shun[tostring(u.target)] = c.now + 60
			s.aims[id] = nil
			free[#free + 1] = u
		end
	end
	local wave = math.max(2, math.floor(6 - 4 * p.aggression + 0.5))
	-- (no wave for `patience` s, or no money coming in: what it has)
	if c.now - s.wave_at > p.patience or c.now - s.income_at > p.dry then
		wave = 1
	end
	-- (none before `first_wave` s of the match: the player's time to build)
	if #free == 0 or c.now - s.started < p.first_wave or
			(not s.attacking and #free < wave) then
		if #pool(c, k, "attack") == 0 then
			s.attacking = false
		end
		return
	end
	s.attacking = true
	s.wave_at = c.now
	local at = middle(free)
	local best, bd = nil, 1e18
	for _, e in ipairs(k.seen) do
		for _, m in ipairs(k.mine) do
			local d = d2(e.pos, m.pos)
			if d < bd and (s.shun[tostring(e.id)] or 0) < c.now then
				best, bd = e, d
			end
		end
	end
	local ids = {}
	for _, u in ipairs(free) do
		ids[#ids + 1] = u.id
	end
	if best and d2(best.pos, at) < 30 ^ 2 then
		c:order(ids, {target = best.id})
		c:log("attacks " .. best.name .. " " .. best.id .. " with " .. #ids)
		return
	end
	local goal = best and best.pos or (s.last_seen ~= false and s.last_seen) or p.enemy_base
	local w = towards(c, at, goal)
	c:order(ids, {at = {w[1], w[2] - 0.5, w[3]}})
	c:log(string.format("sends %d attackers towards %.0f,%.0f", #ids, w[1], w[3]))
end

function ACT.defend(c, k)
	local close, bd = nil, (16) ^ 2
	for _, e in ipairs(k.seen) do
		for _, b in ipairs(k.mine) do
			if b.name == "hq" or b.name == "refinery" or b.name == "factory" then
				local d = d2(e.pos, b.pos)
				if d < bd then
					close, bd = e, d
				end
			end
		end
	end
	if not close then
		return
	end
	local ids = {}
	for _, u in ipairs(pool(c, k, "defence")) do
		if u.target ~= close.id then
			ids[#ids + 1] = u.id
		end
	end
	if #ids > 0 then
		c:order(ids, {target = close.id})
		c:log("defends against " .. close.name .. " " .. close.id)
	end
end

function ACT.scout(c, k)
	local s, p = c.state, c.params
	if #k.seen > 0 or c.now - s.seen_at < 20 then
		return
	end
	for _, u in ipairs(k.by.tank or {}) do
		if tostring(u.id) == tostring(s.scout) then
			if not idle(u) then
				return
			end
		end
	end
	local pick
	for _, u in ipairs(pool(c, k, "attack")) do
		if idle(u) then
			pick = u
			break
		end
	end
	if not pick then
		return
	end
	-- a random point of the map's half towards the enemy none of ours sees
	for _ = 1, 12 do
		local side = p.enemy_base[1] >= p.base[1] and 1 or -1
		local q = {side * math.random() * p.map_x, p.base[2], (math.random() * 2 - 1) * p.map_z}
		local seen = false
		for _, m in ipairs(k.mine) do
			if d2(q, m.pos) < p.sight ^ 2 then
				seen = true
				break
			end
		end
		if not seen then
			local w = towards(c, pick.pos, q)
			s.scout = pick.id
			c:order({pick.id}, {at = {w[1], w[2] - 0.5, w[3]}})
			c:log(string.format("scouts with %d towards %.0f,%.0f", pick.id, q[1], q[3]))
			return
		end
	end
end

-- The digger's next goal from where it is: beside the nearest ore round the
-- base (`dig_reach` cells) with no open side at its level or the one over
-- it (a tunnel's height), else a point of the way to the enemy's base; one
-- tried before is not again. {x, z} and what it is, or nil
local function dig_goal(c, from)
	local p, s = c.params, c.state
	local r = math.min(22, p.dig_reach)
	local n = 2 * r + 1
	local b = {math.floor(p.base[1] + 0.5), math.floor(from[2] + 0.5),
		math.floor(p.base[3] + 0.5)}
	local x0, z0 = b[1] - r, b[3] - r
	local v = c:voxels_at({x0, b[2], z0}, {n, 2, n})
	local function at(x, y, z)
		if x < 0 or z < 0 or x >= n or z >= n then
			return ""
		end
		return v[1 + x + n * (z + n * y)] or ""
	end
	local best, bd = nil, 1e18
	for y = 0, 1 do
		for z = 0, n - 1 do
			for x = 0, n - 1 do
				if at(x, y, z) == p.ore and at(x + 1, y, z) ~= "air" and
						at(x - 1, y, z) ~= "air" and at(x, y, z + 1) ~= "air" and
						at(x, y, z - 1) ~= "air" and at(x, 1 - y, z) ~= "air" then
					local q = {x0 + x, z0 + z}
					local d = (q[1] - b[1]) ^ 2 + (q[2] - b[3]) ^ 2
					if d < bd and not s.tried[q[1] .. "," .. q[2]] then
						best, bd = q, d
					end
				end
			end
		end
	end
	if best then
		-- (a cell short of it, the last leg's way: the digger digs the
		-- longer way first; the ore left for the harvesters)
		local dx, dz = best[1] - math.floor(from[1] + 0.5), best[2] - math.floor(from[3] + 0.5)
		local last = math.abs(dx) >= math.abs(dz) and (dz ~= 0 and 2 or 1) or (dx ~= 0 and 1 or 2)
		local g = {best[1], best[2]}
		local dv = last == 1 and dx or dz
		g[last] = g[last] - (dv > 0 and 1 or dv < 0 and -1 or 0)
		return g, best, "ore"
	end
	for _, f in ipairs({0.3, 0.55, 0.8, 1}) do
		local q = {math.floor(p.base[1] + (p.enemy_base[1] - p.base[1]) * f + 0.5),
			math.floor(p.base[3] + (p.enemy_base[3] - p.base[3]) * f + 0.5)}
		if not s.tried[q[1] .. "," .. q[2]] then
			return q, q, "the enemy"
		end
	end
end

-- Its digger keeps a goal until it is there or gets no nearer for
-- `dig_patience` s (hard rock, a fall), then the next
function ACT.dig(c, k)
	local s, p = c.state, c.params
	local u = (k.by.digger or {})[1]
	if not u then
		return
	end
	local g = s.dig
	if g and g.id == u.id then
		local d = math.sqrt((u.pos[1] - g.at[1]) ^ 2 + (u.pos[3] - g.at[2]) ^ 2)
		if d <= 1.6 then
			c:log("its digger is at " .. g.at[1] .. "," .. g.at[2])
		elseif d < g.best - 0.7 then
			g.best, g.since = d, c.now
			return
		elseif c.now - g.since <= p.dig_patience then
			return
		else
			c:log("its digger gives up on " .. g.at[1] .. "," .. g.at[2])
		end
		s.tried[g.key] = true
		s.dig = false
	end
	local at, mark, what = dig_goal(c, u.pos)
	if not at then
		return
	end
	local key = mark[1] .. "," .. mark[2]
	s.dig = {id = u.id, at = at, key = key, best = 1e9, since = c.now}
	c:order({u.id}, {at = {at[1], u.pos[2] - 0.5, at[2]}})
	c:log("digs towards " .. at[1] .. "," .. at[2] .. " (" .. what .. ")")
end

local function think(c)
	local s, p = c.state, c.params
	local k = look(c)
	if k.money > s.money then
		s.income_at = c.now
	end
	s.money = k.money
	if #k.seen > 0 then
		s.seen_at = c.now
		s.last_seen = k.seen[1].pos
	end
	pools(c, k)
	-- the goals, the economy first
	if have(c, k, "refinery", 1, true) then
		have(c, k, "harvester", math.min(4, 2 * n_of(k, "refinery")),
			n_of(k, "harvester") == 0)
	end
	have(c, k, "factory", 1)
	-- (and one more while it has `rich` money: what comes in spent)
	local tanks = math.floor(4 + 8 * p.aggression + 0.5) + p.defence
	have(c, k, "tank", k.money >= p.rich and math.max(tanks, n_of(k, "tank") + 1) or tanks)
	have(c, k, "digger", 1)
	for _, a in ipairs(shuffle({"attack", "defend", "scout", "dig"})) do
		ACT[a](c, k)
	end
end

return {
	version = 1,
	about = {
		group = "Game",
		what = "Deepcore's computer player: builds an economy and an army, defends, scouts and attacks.",
		params = {
			match = "Its match (a local/rts_match): it buys through it.",
			team = "The kit/team it plays.", enemy = "The kit/team it plays against.",
			aggression = "0...1: more attackers, smaller waves sent sooner.",
			reserve = "Money it keeps back.",
			defence = "Tanks it keeps at home.",
			think = "Seconds between its turns.",
			pool_time = "Seconds between letting surplus defenders go.",
			dry = "Seconds with no money coming in before it spends its reserve and attacks with what it has.",
			patience = "Seconds with no attack sent before it attacks with what it has.",
			first_wave = "Seconds of the match before its first attack.",
			rich = "Money over which it buys a tank more than it wants.",
			aim_time = "Seconds an attacker shoots at one target before it tries another.",
			dig_reach = "Cells round its base it looks for ore in the rock for its digger.",
			dig_patience = "Seconds its digger may get no nearer to its goal before it gives that one up.",
			ore = "The ore voxel.",
			sight = "How far its units see the enemy, m.",
			base = "Its base.", enemy_base = "The enemy's base.",
			route = "Points \"x y z, ...\" from its base to the enemy's: the long way, a point at a time.",
			map_x = "Half the map's width (x), m, for scouting.",
			map_z = "Half the map's depth (z), m, for scouting.",
		},
		inputs = {start = "Plays.", stop = "Stops playing."},
	},
	no_position = true,
	reads_units = true,
	reads_teams = true,
	world_voxels = true,
	params = {
		match = {type = "entity", default = 0},
		team = {type = "string", default = "Red"},
		enemy = {type = "string", default = "Blue"},
		aggression = {type = "number", default = 0.5, min = 0, max = 1},
		reserve = {type = "number", default = 100, min = 0, max = 10000},
		defence = {type = "number", default = 3, min = 0, max = 30},
		think = {type = "number", default = 1.5, min = 0.2, max = 10},
		pool_time = {type = "number", default = 20, min = 1, max = 600},
		dry = {type = "number", default = 45, min = 5, max = 600},
		patience = {type = "number", default = 150, min = 10, max = 3600},
		first_wave = {type = "number", default = 180, min = 0, max = 3600},
		rich = {type = "number", default = 400, min = 0, max = 100000},
		aim_time = {type = "number", default = 30, min = 5, max = 600},
		dig_reach = {type = "number", default = 22, min = 4, max = 22},
		dig_patience = {type = "number", default = 25, min = 5, max = 300},
		ore = {type = "voxel", default = "kit/ore"},
		sight = {type = "number", default = 12, min = 1, max = 64},
		base = {type = "position", default = {35, 4, 8}},
		enemy_base = {type = "position", default = {-36, 4, -9}},
		route = {type = "string", default = ""},
		map_x = {type = "number", default = 48, min = 4, max = 1024},
		map_z = {type = "number", default = 32, min = 4, max = 1024},
	},
	state = {on = {default = false, shared = true}, pending = {default = {}},
		pools = {default = {}}, pooled = {default = 0}, attacking = {default = false},
		scout = {default = 0}, seen_at = {default = 0}, last_seen = {default = false},
		money = {default = 0}, income_at = {default = 0}, wave_at = {default = 0},
		dig = {default = false}, tried = {default = {}}, started = {default = 0},
		aims = {default = {}}, shun = {default = {}}},
	inputs = {start = "none", stop = "none"},
	on_input = function(c, input)
		local s = c.state
		if input == "start" then
			s.on, s.pending, s.pools, s.attacking = true, {}, {}, false
			s.scout, s.seen_at, s.last_seen, s.pooled = 0, c.now, false, c.now
			s.money, s.income_at, s.wave_at, s.dig, s.tried = 0, c.now, c.now, false, {}
			s.started, s.aims, s.shun = c.now, {}, {}
			c:log("plays " .. c.params.team)
			c:after(c.params.think, "think")
		elseif input == "stop" then
			s.on = false
			c:after(nil, "think")
		end
	end,
	on_timer = function(c, name)
		if name == "think" and c.state.on then
			c:after(c.params.think, "think")
			think(c)
		end
	end,
}
