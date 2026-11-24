-- Deepcore's computer player ([KIT_RTS], kit_plan 4z37zzo): one side's
-- opponent, after the approach of the user's Ternadim skirmish AI (its own
-- Lua; nothing of that code). Started and stopped by its match ("start",
-- "stop"); every `think` seconds while on:
--   goals, each "have X" met through what X needs first (a harvester needs a
--   factory and a refinery, a unit a factory, a building the HQ: the one
--   missing is bought first): a refinery and two harvesters a refinery (four
--   at most), a factory, attack units (4 + 8 x `aggression` tanks) and
--   `defence` tanks, a digger; money kept back: nothing is bought that would
--   leave under `reserve` (but the first refinery and harvester);
--   activities in a random order each time: attack, defend, scout, dig.
-- Its units are in two pools, attack and defence, assigned as they come (one
-- in three to defence while it has fewer than it wants), all defenders let go
-- now and then (`pool_time`) when there are more than its buildings call for.
-- Idle attackers, once there are a wave of them (fewer the more aggressive),
-- go for the enemy seen nearest our units (seen: within `sight` m of one of
-- ours: it does not see through the fog), else where one was last seen,
-- else the enemy's base, along `route` (points "x y z, ..." from its base to
-- the enemy's: a long way taken a point at a time); with no enemy seen for a
-- while one goes as a scout to a random point of the map none of ours sees.
-- Defenders go for an enemy seen within 16 m of our buildings. Its digger
-- digs towards a random spot round the base (more ore for the harvesters).
-- It buys through its match ("build" "<Team> <what>") and orders its units
-- with c:order, the way a player's orders go (kit/unit's on_order).
-- Knobs: aggression, reserve, defence, think, pool_time (params).
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
	if k.money - cost < (must and 0 or c.params.reserve) then
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
		if idle(u) and tostring(u.id) ~= tostring(s.scout) then
			free[#free + 1] = u
		end
	end
	local wave = math.max(2, math.floor(6 - 4 * p.aggression + 0.5))
	if #free == 0 or (not s.attacking and #free < wave) then
		if #pool(c, k, "attack") == 0 then
			s.attacking = false
		end
		return
	end
	s.attacking = true
	local at = middle(free)
	local best, bd = nil, 1e18
	for _, e in ipairs(k.seen) do
		for _, m in ipairs(k.mine) do
			local d = d2(e.pos, m.pos)
			if d < bd then
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

function ACT.dig(c, k)
	local p = c.params
	for _, u in ipairs(k.by.digger or {}) do
		if idle(u) and math.random(1, 4) == 1 then
			local a = math.random() * 2 * math.pi
			local r = 8 + math.random() * 10
			local q = {math.floor(p.base[1] + math.cos(a) * r + 0.5), p.base[2],
				math.floor(p.base[3] + math.sin(a) * r + 0.5)}
			c:order({u.id}, {at = {q[1], q[2] - 0.5, q[3]}})
			c:log("digs towards " .. q[1] .. "," .. q[3])
		end
	end
end

local function think(c)
	local s, p = c.state, c.params
	local k = look(c)
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
	have(c, k, "tank", math.floor(4 + 8 * p.aggression + 0.5) + p.defence)
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
	params = {
		match = {type = "entity", default = 0},
		team = {type = "string", default = "Red"},
		enemy = {type = "string", default = "Blue"},
		aggression = {type = "number", default = 0.5, min = 0, max = 1},
		reserve = {type = "number", default = 100, min = 0, max = 10000},
		defence = {type = "number", default = 3, min = 0, max = 30},
		think = {type = "number", default = 1.5, min = 0.2, max = 10},
		pool_time = {type = "number", default = 20, min = 1, max = 600},
		sight = {type = "number", default = 12, min = 1, max = 64},
		base = {type = "position", default = {35, 4, 8}},
		enemy_base = {type = "position", default = {-36, 4, -9}},
		route = {type = "string", default = ""},
		map_x = {type = "number", default = 48, min = 4, max = 1024},
		map_z = {type = "number", default = 32, min = 4, max = 1024},
	},
	state = {on = {default = false, shared = true}, pending = {default = {}},
		pools = {default = {}}, pooled = {default = 0}, attacking = {default = false},
		scout = {default = 0}, seen_at = {default = 0}, last_seen = {default = false}},
	inputs = {start = "none", stop = "none"},
	on_input = function(c, input)
		local s = c.state
		if input == "start" then
			s.on, s.pending, s.pools, s.attacking = true, {}, {}, false
			s.scout, s.seen_at, s.last_seen, s.pooled = 0, c.now, false, c.now
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
