-- Deepcore's round ([KIT_RTS], kit_plan 4z37zzo): the lobby, a 1v1 match and
-- its result, the money and what it buys.
--   The lobby (its `lobby` panel, shown to each player as they come in):
--   "vs_computer" puts the player in Blue and starts a match against the
--   computer (its `ai`, a local/rts_ai playing Red); "versus" puts the first
--   player in Blue to wait, the next in Red, and starts. A start clears what
--   an earlier match made, sets each team's score (its money) to
--   `start_money`, makes each side's HQ at its base (`blue_base`, `red_base`)
--   with a refinery, a factory (`start_factory`), a harvester and a digger,
--   and puts ore pockets into each base's walls (`ore_pockets`, `room` cells
--   out from the HQ), shows the players their `hud` (a team's join put them
--   on its pad, at their base). A harvester of a team standing still 15 s
--   (it waits where it is with no ore it reaches): the team's player is
--   told so.
--   Buying (build_<what> from a button, by a player of a team; or "build"
--   with "<Team> <what>" from the computer): `cost_<what>` off the team's
--   money; a unit (harvester, digger, tank) queues at the team's least busy
--   factory, made in its bay after `build_time` s and ordered out of its door
--   (c:order: the way a player orders); a building (refinery, factory) goes at
--   a free spot round the team's HQ (a random one of 14 tries: floor under it,
--   room over it, no other building near). At most `cap` units a side.
--   The end: a side with no building left loses ("Blue wins"), the `result`
--   panel on each player's screen ("again": the same match once more; "lobby":
--   back). The `money` text (to its team) shows the team's money, `status`
--   (to the player) what a buy did and at a start what to do first,
--   `notice` (to the player, near the top right for a few seconds) a buy
--   refused and an idle harvester, `alert` Under attack (alerts() below).
-- simplified: dug tunnels stay dug from one match to the next (Stop puts the
-- World back); a building is made at once, no construction time; a player
-- leaving a 1v1 does not end it
local UNITS = {harvester = true, digger = true, tank = true}
local BUILDINGS = {hq = true, refinery = true, factory = true}

local function team_named(c, name)
	for _, t in ipairs(c.teams or {}) do
		if t.params.name == name then
			return t
		end
	end
end

local function team_of_player(c, by)
	local id = tonumber(tostring(by):match("^player:(%d+)$"))
	for _, t in ipairs(c.teams or {}) do
		for _, m in ipairs(t.state.members or {}) do
			if m == id then
				return t.params.name
			end
		end
	end
end

-- (bad: a buy refused, the `notice` near the top right instead)
local function say(c, by, text, bad)
	if by and tostring(by):match("^player:") then
		local to = bad and c.params.notice or c.params.status
		if to ~= 0 then
			c:send(to, "value", text, by)
		end
	end
	c:log(text)
end

local function count(c, team)
	local n, b, kinds = 0, 0, {}
	for _, u in ipairs(c.units or {}) do
		if u.team == team then
			kinds[u.name] = (kinds[u.name] or 0) + 1
			if BUILDINGS[u.name] then
				b = b + 1
			elseif UNITS[u.name] then
				n = n + 1
			end
		end
	end
	return n, b, kinds
end

local function base_of(c, team)
	return team == "Blue" and c.params.blue_base or c.params.red_base
end

-- A free spot round the team's HQ for a building: floor under a 5 x 5
-- footprint, 3 cells of air over it, no building within 5.5 m
local function spot(c, hq)
	local h = {math.floor(hq.pos[1] + 0.5), math.floor(hq.pos[2] + 0.5),
		math.floor(hq.pos[3] + 0.5)}
	for _ = 1, 14 do
		local a = math.random() * 2 * math.pi
		local r = 5.5 + math.random() * 3
		local p = {h[1] + math.floor(math.cos(a) * r + 0.5), h[2],
			h[3] + math.floor(math.sin(a) * r + 0.5)}
		local free = true
		for _, u in ipairs(c.units or {}) do
			-- (apart from the buildings, and not over a unit: one inside
			-- its walls is stuck there)
			if (u.pos[1] - p[1]) ^ 2 + (u.pos[3] - p[3]) ^ 2 < (BUILDINGS[u.name] and 5.5 or 3.5) ^ 2 then
				free = false
				break
			end
		end
		if free then
			local v = c:voxels_at({p[1] - 2, p[2] - 1, p[3] - 2}, {5, 4, 6})
			local i = 0
			for y = 0, 3 do
				for _ = 0, 5 do
					for _ = 0, 4 do
						i = i + 1
						local n = v[i] or ""
						if (y == 0 and (n == "air" or n == "")) or (y > 0 and n ~= "air") then
							free = false
						end
					end
				end
			end
		end
		if free then
			return p
		end
	end
end

local function prefab(c, what, team)
	return c.params[what .. "_" .. (team == "Blue" and "blue" or "red")]
end

local function spawn(c, what, team, pos)
	local id = c:spawn({prefab = prefab(c, what, team), pos = pos})
	c:log("made " .. team .. " " .. what .. " " .. tostring(id) .. " at " ..
		pos[1] .. "," .. pos[2] .. "," .. pos[3])
	return id
end

local function buy(c, team, what, by)
	local s = c.state
	if s.mode ~= "playing" then
		return say(c, by, "Not in a match", true)
	end
	local cost = c.params["cost_" .. what]
	local t = team_named(c, team)
	if not cost or not t then
		return say(c, by, "Nothing to buy: " .. tostring(what), true)
	end
	if (t.state.score or 0) < cost then
		return say(c, by, team .. ": not enough money for a " .. what ..
			" ($" .. cost .. ")", true)
	end
	local n, _, kinds = count(c, team)
	if UNITS[what] then
		local queued = 0
		for _, q in pairs(s.queue) do
			if q.team == team then
				queued = queued + #q.list + (q.busy and 1 or 0)
			end
		end
		if n + queued >= c.params.cap then
			return say(c, by, team .. ": at the unit cap (" .. c.params.cap .. ")", true)
		end
		local best, bn = nil, 1e9
		for _, u in ipairs(c.units or {}) do
			if u.name == "factory" and u.team == team then
				local q = s.queue[tostring(u.id)]
				local k = q and #q.list + (q.busy and 1 or 0) or 0
				if k < bn then
					best, bn = u, k
				end
			end
		end
		if not best then
			return say(c, by, team .. ": a " .. what .. " needs a factory", true)
		end
		local key = tostring(best.id)
		local q = s.queue[key] or {team = team, list = {}, busy = false,
			pos = best.pos}
		q.list[#q.list + 1] = what
		q.pos = best.pos
		s.queue[key] = q
		c:send(t.id, "add", -cost)
		say(c, by, team .. ": a " .. what .. " queued at the factory (" ..
			(#q.list + (q.busy and 1 or 0)) .. ")")
		if not q.busy then
			q.busy = table.remove(q.list, 1)
			c:after(c.params.build_time, "f" .. key)
		end
	elseif BUILDINGS[what] and what ~= "hq" then
		local hq
		for _, u in ipairs(c.units or {}) do
			if u.name == "hq" and u.team == team then
				hq = u
			end
		end
		if not hq then
			return say(c, by, team .. ": a " .. what .. " needs an HQ", true)
		end
		local p = spot(c, hq)
		if not p then
			return say(c, by, team .. ": no room for a " .. what .. " round the HQ", true)
		end
		c:send(t.id, "add", -cost)
		spawn(c, what, team, p)
		say(c, by, team .. ": a " .. what .. " built")
	end
end

-- Ore into a base's walls: n pockets of 5 x 2 x 5 (5 deep: mined a layer at
-- a time from the room), each where the cells are solid, in the walls of
-- the room `room` cells each way from the HQ (its walls room + 1 out): east,
-- west, south, north, then east and west again further north (Blue's
-- tunnel leaves its east wall south of the HQ). Red's are Blue's turned
-- round the map's middle (side -1), as the bases are
local function pockets(c, base, side)
	local r, out, P = c.params.room, {}, 5
	local h = {math.floor(base[1] + 0.5), math.floor(base[2] + 0.5), math.floor(base[3] + 0.5)}
	local corners = {{r + 1, -2}, {-r - P, -2}, {-1, r + 1}, {-1, -r - P}, {r + 1, -2 - P},
		{-r - P, -2 - P}}
	for k = 1, math.min(c.params.ore_pockets, #corners) do
		local o = corners[k]
		-- (the box's low corner, Blue's way or Red's)
		local x = h[1] + (side > 0 and o[1] or -o[1] - (P - 1))
		local z = h[3] + (side > 0 and o[2] or -o[2] - (P - 1))
		local v = c:voxels_at({x, h[2], z}, {P, 2, P})
		local i = 0
		for y = 0, 1 do
			for dz = 0, P - 1 do
				for dx = 0, P - 1 do
					i = i + 1
					if v[i] and v[i] ~= "air" and v[i] ~= "" then
						out[#out + 1] = {x + dx, h[2] + y, z + dz, c.params.ore}
					end
				end
			end
		end
	end
	if #out > 0 then
		c:set_voxels_at(out)
	end
	return #out
end

-- [KIT_RTS_PLAYTEST_1] (11) "Under attack": a unit or building of a side
-- with a player whose health went down since the last tick (c.units'
-- share), out of the player's view, tells them in the `alert` text, once in
-- `alert_every` s. The view (s.attention): within `view` m of the tank or
-- digger of theirs that last set off moving, following it while it moves
-- (those move on their player's orders alone; one 5 s out of the factory
-- not yet); the camera's start, their base, before that.
-- simplified: the server does not know the camera, nor can a unit made in
-- play reach its match to tell it of an order (no prefab link or entity
-- parameter outside the prefab); a pan, or an order to a harvester or to a
-- unit on the move, is not seen
local function alerts(c)
	local s, p = c.state, c.params
	local hp, hit, moving = {}, {}, {}
	for _, u in ipairs(c.units or {}) do
		local k = tostring(u.id)
		s.seen[k] = s.seen[k] or c.now
		if (u.name == "tank" or u.name == "digger") and u.moving and s.players[u.team] then
			moving[k] = true
			if not s.moving[k] and c.now - s.seen[k] > 5 and s.follow[u.team] ~= u.id then
				s.follow[u.team] = u.id
				c:log("view: " .. u.team .. " follows " .. u.name .. " " .. k)
			end
		end
		if s.follow[u.team] == u.id and u.moving then
			s.attention[u.team] = {u.pos[1], u.pos[2], u.pos[3]}
		end
	end
	s.moving = moving
	for _, u in ipairs(c.units or {}) do
		if u.health then
			local k = tostring(u.id)
			hp[k] = u.health
			local a = s.attention[u.team]
			if s.hp[k] and u.health < s.hp[k] - 1e-6 and s.players[u.team] and
					not hit[u.team] and not (a and (u.pos[1] - a[1]) ^ 2 +
					(u.pos[3] - a[3]) ^ 2 < p.view ^ 2) then
				hit[u.team] = u
			end
		end
	end
	s.hp = hp
	for team, u in pairs(hit) do
		local what = team .. "'s " .. u.name .. " " .. u.id .. " hit out of view"
		local ago = c.now - (s.alerted[team] or -1e9)
		if ago >= p.alert_every then
			s.alerted[team] = c.now
			c:log(string.format("under attack: %s, told at t=%.1f", what, c.now))
			if p.alert ~= 0 then
				c:send(p.alert, "value", "Under attack: your " ..
					(u.name == "hq" and "HQ" or u.name), s.players[team])
			end
		else
			c:log(string.format("under attack: %s at t=%.1f, not told (told %.0f s ago)",
				what, c.now, ago))
		end
	end
end

local function panels(c, by, now)
	local p = c.params
	for _, x in ipairs({{p.lobby, "lobby"}, {p.hud, "playing"}, {p.result, "over"}}) do
		if x[1] ~= 0 then
			c:send(x[1], x[2] == now and "show" or "hide", nil, by)
		end
	end
end

local function start(c)
	local s, p = c.state, c.params
	for _, id in ipairs(c.made or {}) do
		c:remove(id)
	end
	s.queue = {}
	s.winner = ""
	s.hp, s.alerted, s.seen, s.moving, s.follow = {}, {}, {}, {}, {}
	s.attention = {Blue = p.blue_base, Red = p.red_base}
	s.mode = "playing"
	s.since = c.now
	for _, team in ipairs({"Blue", "Red"}) do
		local t = team_named(c, team)
		if t then
			c:send(t.id, "set", p.start_money)
		end
		local b = base_of(c, team)
		spawn(c, "hq", team, {b[1], b[2], b[3]})
		local side = team == "Blue" and 1 or -1
		spawn(c, "refinery", team, {b[1] + 6 * side, b[2], b[3] - 5 * side})
		if p.start_factory then
			-- (west of Blue's HQ, east of Red's: its door, +z, to the
			-- room, away from the tunnels into the rooms; on a whole cell
			-- as a bought one: what it makes stands on the floor)
			spawn(c, "factory", team, {b[1] - 7 * side, math.floor(b[2] + 0.5),
				b[3] + (side > 0 and 3 or -3)})
		end
		-- (movers half a cell up, as a factory's: on the floor's top they
		-- stood stuck)
		spawn(c, "harvester", team, {b[1] + 3 * side, b[2] + 0.5, b[3] + 4 * side})
		spawn(c, "digger", team, {b[1] - 3 * side, b[2] + 0.5, b[3] + 4 * side})
		c:log(team .. "'s ore pockets: " .. pockets(c, b, side) .. " cells")
	end
	c:send(p.ai, s.vs == "computer" and "start" or "stop")
	for team, by in pairs(s.players) do
		panels(c, by, "playing")
		-- (what to do first: a playtest's player found nothing to do)
		say(c, by, "Click a unit to select it, right click where it goes. " ..
			"Diggers dig, harvesters bring ore home; the bar below buys.")
	end
	c:log("match started: " .. s.vs)
end

local function over(c, winner)
	local s = c.state
	s.mode = "over"
	s.winner = winner
	c:send(c.params.ai, "stop")
	for team, by in pairs(s.players) do
		panels(c, by, "over")
		if c.params.result_text ~= 0 then
			c:send(c.params.result_text, "value", (team == winner and "You win: " or
				"You lose: ") .. winner .. " holds the deep.", by)
		end
	end
	c:log("match over: " .. winner .. " wins")
end

return {
	version = 1,
	about = {
		group = "Game",
		what = "Deepcore's round: the lobby, a 1v1 match against a player or the computer, the money and what it buys, the result.",
		params = {
			blue = "Blue's kit/team.", red = "Red's kit/team.",
			ai = "The computer player (a local/rts_ai).",
			lobby = "The lobby's panel.", hud = "The panel of what to buy, shown in a match.",
			result = "The result card's panel.", result_text = "The result card's text.",
			money = "A text shown to a team: its money.",
			status = "A text shown to a player: what their buy did.",
			notice = "A text shown to a player near the top right: a buy refused, a harvester idle.",
			alert = "A text shown to a player near the top right: Under attack.",
			view = "Metres about the tank or digger of a player's that last set off moving (their base before) that count as in their view (no Under attack there).",
			alert_every = "Seconds between a side's Under attack notices at most.",
			start_factory = "Each side starts with a factory.",
			blue_base = "Where Blue's HQ is made.", red_base = "Where Red's HQ is made.",
			start_money = "Each side's money at the start.",
			cap = "Units a side at most (buildings aside).",
			build_time = "Seconds a factory takes to make a unit.",
			room = "Cells from the HQ to a base's walls, where ore pockets go.",
			ore_pockets = "Ore pockets put into each base's walls at the start.",
			ore = "The ore voxel.",
		},
		inputs = {
			vs_computer = "A player starts a match against the computer.",
			versus = "A player waits for, or joins, a 1v1.",
			again = "The same match once more.",
			lobby = "Back to the lobby.",
			build = "The computer buys. Value: \"<Team> <what>\".",
		},
	},
	no_position = true,
	reads_teams = true,
	reads_units = true,
	reads_players = true,
	world_voxels = true,
	params = {
		blue = {type = "entity", default = 0}, red = {type = "entity", default = 0},
		ai = {type = "entity", default = 0},
		lobby = {type = "entity", default = 0}, hud = {type = "entity", default = 0},
		result = {type = "entity", default = 0}, result_text = {type = "entity", default = 0},
		money = {type = "entity", default = 0}, status = {type = "entity", default = 0},
		notice = {type = "entity", default = 0},
		alert = {type = "entity", default = 0},
		view = {type = "number", default = 16, min = 1, max = 200},
		alert_every = {type = "number", default = 20, min = 1, max = 600},
		start_factory = {type = "bool", default = true},
		blue_base = {type = "position", default = {-36, 4, -9}},
		red_base = {type = "position", default = {35, 4, 8}},
		start_money = {type = "number", default = 400, min = 0, max = 100000},
		cap = {type = "number", default = 30, min = 1, max = 100},
		build_time = {type = "number", default = 4, min = 0.2, max = 60},
		room = {type = "number", default = 9, min = 3, max = 30},
		ore_pockets = {type = "number", default = 6, min = 0, max = 6},
		ore = {type = "voxel", default = "kit/ore"},
		cost_harvester = {type = "number", default = 80, min = 0, max = 10000},
		cost_digger = {type = "number", default = 60, min = 0, max = 10000},
		cost_tank = {type = "number", default = 100, min = 0, max = 10000},
		cost_refinery = {type = "number", default = 150, min = 0, max = 10000},
		cost_factory = {type = "number", default = 200, min = 0, max = 10000},
		hq_blue = {type = "prefab", default = ""}, hq_red = {type = "prefab", default = ""},
		refinery_blue = {type = "prefab", default = ""}, refinery_red = {type = "prefab", default = ""},
		factory_blue = {type = "prefab", default = ""}, factory_red = {type = "prefab", default = ""},
		harvester_blue = {type = "prefab", default = ""}, harvester_red = {type = "prefab", default = ""},
		digger_blue = {type = "prefab", default = ""}, digger_red = {type = "prefab", default = ""},
		tank_blue = {type = "prefab", default = ""}, tank_red = {type = "prefab", default = ""},
	},
	state = {mode = {default = "lobby", shared = true}, vs = {default = ""},
		players = {default = {}}, queue = {default = {}}, winner = {default = "", shared = true},
		since = {default = 0}, waiting = {default = ""}, money = {default = {}},
		idle = {default = {}}, still = {default = {}}, hp = {default = {}},
		attention = {default = {}}, alerted = {default = {}}, seen = {default = {}},
		moving = {default = {}}, follow = {default = {}}},
	inputs = {vs_computer = "none", versus = "none", again = "none", lobby = "none",
		build = "string", build_harvester = "none", build_digger = "none",
		build_tank = "none", build_refinery = "none", build_factory = "none"},
	on_start = function(c)
		c:after(1, "tick")
	end,
	on_join = function(c, by)
		local s = c.state
		for team, p in pairs(s.players) do
			if p == by and s.mode ~= "lobby" then
				panels(c, by, s.mode == "over" and "over" or "playing")
				return
			end
		end
		panels(c, by, "lobby")
	end,
	on_input = function(c, input, value, by)
		local s, p = c.state, c.params
		local what = input:match("^build_(%a+)$")
		if what then
			local team = team_of_player(c, by)
			if not team then
				return say(c, by, "Not on a side", true)
			end
			return buy(c, team, what, by)
		elseif input == "build" then
			local team, w = tostring(value):match("^(%a+) (%a+)$")
			if team then
				buy(c, team, w, nil)
			end
		elseif input == "vs_computer" and (s.mode == "lobby" or s.mode == "waiting") then
			s.players = {Blue = by}
			s.vs = "computer"
			c:send(p.blue, "join", nil, by)
			start(c)
		elseif input == "versus" and s.mode == "lobby" then
			s.players = {Blue = by}
			s.mode = "waiting"
			s.vs = "players"
			c:send(p.blue, "join", nil, by)
			say(c, by, "Waiting for a second player")
		elseif input == "versus" and s.mode == "waiting" and s.players.Blue ~= by then
			s.players.Red = by
			c:send(p.red, "join", nil, by)
			start(c)
		elseif input == "again" and s.mode == "over" then
			start(c)
		elseif input == "lobby" and s.mode == "over" then
			for _, b in pairs(s.players) do
				panels(c, b, "lobby")
			end
			for _, id in ipairs(c.made or {}) do
				c:remove(id)
			end
			s.players = {}
			s.mode = "lobby"
			c:send(p.ai, "stop")
		end
	end,
	on_timer = function(c, name, player)
		local s, p = c.state, c.params
		if name == "tick" then
			c:after(1, "tick")
			if s.mode ~= "playing" then
				return
			end
			local alive = {}
			for _, team in ipairs({"Blue", "Red"}) do
				local _, b = count(c, team)
				alive[team] = b > 0
				local t = team_named(c, team)
				local by = s.players[team]
				local money = t and math.floor(t.state.score or 0)
				if money and money ~= s.money[team] then
					s.money[team] = money
					c:log(team .. "'s money: " .. money)
				end
				if t and by and p.money ~= 0 then
					c:send(p.money, "value", "$" .. math.floor(t.state.score or 0), by)
				end
			end
			-- a harvester still 15 s (simplified: seen by what it does, not
			-- told by it: a made copy reaches nothing outside itself, and
			-- play's c:set_param is not a Lua type's c.params)
			local still = {}
			for _, u in ipairs(c.units or {}) do
				if u.name == "harvester" then
					local k, w = tostring(u.id), s.still[tostring(u.id)]
					if u.moving or not w or math.abs(w[1] - u.pos[1]) + math.abs(w[2] - u.pos[3]) > 0.3 then
						w = {u.pos[1], u.pos[3], c.now}
					elseif c.now - w[3] > 15 and c.now - (s.idle[u.team] or -100) > 20 then
						s.idle[u.team] = c.now
						c:log(u.team .. "'s harvester idle (" .. k .. ")")
						local _, _, kinds = count(c, u.team)
						if s.players[u.team] then
							say(c, s.players[u.team], kinds.refinery and
								"Harvester idle: no reachable ore - dig to a pocket" or
								"Harvester idle: no refinery", true)
						end
					end
					still[k] = w
				end
			end
			s.still = still
			alerts(c)
			-- (a second for the start's buildings to be made)
			if c.now - s.since > 2 then
				if not alive.Blue then
					over(c, "Red")
				elseif not alive.Red then
					over(c, "Blue")
				end
			end
		elseif name:sub(1, 1) == "f" then
			local key = name:sub(2)
			local q = s.queue[key]
			if not q or not q.busy then
				return
			end
			if s.mode == "playing" then
				local f = q.pos
				local id = spawn(c, q.busy, q.team, {f[1], f[2], f[3]})
				s.leaving = s.leaving or {}
				s.leaving[#s.leaving + 1] = {id, {f[1], f[2] - 0.5, f[3] + 4.5}}
				c:after(0.2, "out")
			end
			q.busy = table.remove(q.list, 1) or false
			if q.busy then
				c:after(p.build_time, name)
			end
		elseif name == "out" then
			for _, l in ipairs(s.leaving or {}) do
				c:order({l[1]}, {at = l[2]})
			end
			s.leaving = {}
		end
	end,
}
