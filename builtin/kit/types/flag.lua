-- A carriable objective ([KIT_CTF]): a flag, a relic, a ball to carry
-- home. It starts at its own place (home). A player takes it -- at home by
-- `take_home`, lying placed by `take_placed`: "click" (a use of it) or
-- "near" (within `home_range` / `placed_range` m of it; 1: a touch) --
-- and carries it, it following them `lift` m over their feet, they moving
-- at `speed` times their speed (c:speed; reset as it leaves them). For
-- `immunity` s after a take nobody takes it from them; then `steal`:
-- "opponents" (a player not of the holder's team -- a teamless one is
-- everyone's opponent -- within `steal_range` m of them takes it, immune
-- in turn), "anyone" or "none". The holder puts it down by the action
-- `place_action` (its key `place_key`, rebindable): it falls to the ground
-- under them. Lying placed in a team's region (c:region_at), every
-- `score_interval` s it gives `score_points` (kit/team's "add") to the
-- region's team, or with `score_to` "placer" to the team of who placed
-- it; the count starts over as it is taken. Taken from home, `return_time`
-- s (0: never) count down whatever happens, then it is home again; home
-- stops them. Home too: its carrier's death (`on_death` "home"; "drop":
-- it falls where they were), the carrier gone (left the game or the
-- scene), nothing under it to land on (out of the world), the input
-- "home". A blast (on_blast) on it lying placed: `on_blast` "fall" (it
-- drops onto what is left under it), "home" or "none".
-- Outputs for HUD texts, bars and links: taken (the taker's name), placed
-- (the placer's), home (why: "timer", "died", "left", "fell", "blast",
-- "signal"; sent again as a player dies while it is home, so a respawn
-- "on_signal" linked to it lets them back at once), left (the return's
-- whole seconds left, 0 home), progress (the scoring count, 0...100),
-- immune (the holder's whole seconds left), holder_team (its name, ""
-- none), scored (the team's name). "enable" and "disable" (`enabled` at
-- the start): disabled, nobody takes it (a prep phase).
-- Its marker (P1's) points it out on every screen, through walls.
-- Its times (return, immunity, scoring) are c:after's own; a clock each
-- second counts the outputs' numbers down (up).
-- simplified: it follows its holder by c:move every `poll` s (the
-- server's place, not the holder's client's prediction), and distances
-- are the players' feet's to its place
local function dist(a, b)
	local x, y, z = a[1] - b[1], a[2] - b[2], a[3] - b[3]
	return math.sqrt(x * x + y * y + z * z)
end

local function player(c, id)
	for _, p in ipairs(c.players or {}) do
		if p.id == id then
			return p
		end
	end
end

-- A player's team: {id, name} or nil
local function team_of(c, id)
	for _, t in ipairs(c.teams or {}) do
		for _, m in ipairs(t.state.members or {}) do
			if m == id then
				return {id = t.id, name = tostring(t.params.name or t.id)}
			end
		end
	end
end

-- Whether a player is here to act: in its scene, placed, alive
local function present(p)
	return p and p.here and not p.away and p.alive and p.pos
end

-- An output sent only as its value changes (the HUD's numbers)
local function report(c, name, v)
	local e = c.state.emitted
	if e[name] ~= v then
		e[name] = v
		c.state.emitted = e
		c:emit(name, v)
	end
end

local function ceil(x)
	return math.floor(x + 0.999)
end

local function carry_at(c, p)
	return {p.pos[1], p.pos[2] + c.params.lift, p.pos[3]}
end

local function let_go(c)
	if c.state.holder ~= 0 then
		c:speed(c.state.holder, 1)
	end
	c.state.holder = 0
	c.state.holder_team = 0
	c.state.immune = 0
	c:after(nil, "immune")
	report(c, "immune", 0)
	report(c, "holder_team", "")
end

local function go_home(c, why)
	let_go(c)
	c.state.where = "home"
	c.state.left = -1
	c:after(nil, "return")
	c.state.acc = 0
	c:after(nil, "score")
	report(c, "left", 0)
	report(c, "progress", 0)
	c:move(c.state.home)
	c:log("home:", why)
	c:emit("home", why)
end

local function take(c, p)
	local from = c.state.where
	let_go(c)
	local t = team_of(c, p.id)
	c.state.where = "carried"
	c.state.holder = p.id
	c.state.holder_team = t and t.id or 0
	c.state.immune = c.params.immunity
	if c.params.immunity > 0 then
		c:after(c.params.immunity, "immune")
	end
	c.state.acc = 0
	c:after(nil, "score")
	c:speed(p.id, c.params.speed)
	if from == "home" and c.params.return_time > 0 and c.state.left < 0 then
		c.state.left = c.params.return_time
		c:after(c.params.return_time, "return")
	end
	c:move(carry_at(c, p))
	c:log("taken by", p.name, "from", from, t and "(" .. t.name .. ")" or "")
	report(c, "holder_team", t and t.name or "")
	report(c, "immune", ceil(c.state.immune))
	report(c, "progress", 0)
	if c.state.left >= 0 then
		report(c, "left", ceil(c.state.left))
	end
	c:emit("taken", p.name)
end

-- How it is taken where it is now: "click", "near" or nil (not now)
local function taking(c)
	if not c.state.enabled then
		return nil
	end
	if c.state.where == "home" then
		return c.params.take_home, c.params.home_range
	elseif c.state.where == "placed" then
		return c.params.take_placed, c.params.placed_range
	end
end

-- Who may take it from its holder now: the nearest within steal_range
local function stealer(c, h)
	local rule = c.params.steal
	if rule == "none" or c.state.immune > 0 or not c.state.enabled then
		return nil
	end
	local best, bd
	for _, p in ipairs(c.players) do
		if p.id ~= h.id and present(p) then
			local ok = rule == "anyone"
			if rule == "opponents" then
				local t = team_of(c, p.id)
				ok = not t or t.id ~= c.state.holder_team or
						c.state.holder_team == 0
			end
			local d = dist(p.pos, h.pos)
			if ok and d <= c.params.steal_range and (not bd or d < bd) then
				best, bd = p, d
			end
		end
	end
	return best
end

-- The team it scores for where it lies now (0: none)
local function scoring_team(c)
	local r = c:region_at(c.pos)
	if not (r and r.team ~= 0) then
		return 0
	end
	return c.params.score_to == "region" and r.team or c.state.placer_team
end

-- Lying placed: the count (re)starts where it lies
local function count(c)
	c.state.acc = 0
	report(c, "progress", 0)
	if scoring_team(c) ~= 0 then
		c:after(c.params.score_interval, "score")
	else
		c:after(nil, "score")
	end
end

local function score(c)
	local team = scoring_team(c)
	if c.state.where ~= "placed" or team == 0 then
		return
	end
	c:send(team, "add", c.params.score_points)
	local name = tostring(team)
	for _, t in ipairs(c.teams or {}) do
		if t.id == team then
			name = tostring(t.params.name or team)
		end
	end
	c:log("scores", c.params.score_points, "for", name)
	c:emit("scored", name)
	count(c)
end

-- Each second: the outputs' numbers
local function clock(c)
	c:after(1, "clock")
	local s = c.state
	-- (1 at least: the timers say when they are done)
	if s.left >= 0 then
		s.left = math.max(1, s.left - 1)
		report(c, "left", ceil(s.left))
	end
	if s.immune > 0 then
		s.immune = math.max(1, s.immune - 1)
		report(c, "immune", ceil(s.immune))
	end
	if s.where == "placed" and scoring_team(c) ~= 0 then
		s.acc = s.acc + 1
		report(c, "progress", math.min(99, math.floor(100 * s.acc /
				c.params.score_interval)))
	end
end

local function poll(c)
	local dt = c.params.poll
	c:after(dt, "poll")
	local s = c.state
	if s.where == "carried" then
		local h = player(c, s.holder)
		if not present(h) then
			return go_home(c, h and h.here and not h.away and "died" or "left")
		end
		local at = carry_at(c, h)
		if dist(at, c.pos) > 0.05 then
			c:move(at)
		end
		local p = stealer(c, h)
		if p then
			take(c, p)
		end
		return
	end
	local how, range = taking(c)
	if how == "near" then
		local best, bd
		for _, p in ipairs(c.players) do
			local d = present(p) and dist(p.pos, c.pos)
			if d and d <= range and (not bd or d < bd) then
				best, bd = p, d
			end
		end
		if best then
			return take(c, best)
		end
	end
end

return {
	version = 1,
	usable = true,
	players = true,
	regions = true,
	teams = true,
	-- (a cloth off to its +x side, as on a pole: a kit/part placed under
	-- it; own_look off and parts under it for another look)
	look = {shape = "box", size = {0.7, 0.45, 0.06}, offset = {0.35, 0.65, 0},
		color = "param:color"},
	marker = {color = "param:marker_color", label = "param:marker_label",
		lift = "param:marker_lift"},
	actions = {{name = "param:place_action", key = "param:place_key",
		label = "param:place_label"}},
	params = {
		color = {type = "string", default = "#f0f0f0"},
		enabled = {type = "bool", default = true},
		take_home = {type = "string", default = "near",
			choices = {"click", "near"}},
		home_range = {type = "number", default = 1, min = 0, max = 32},
		take_placed = {type = "string", default = "click",
			choices = {"click", "near"}},
		placed_range = {type = "number", default = 1, min = 0, max = 32},
		steal = {type = "string", default = "opponents",
			choices = {"opponents", "anyone", "none"}},
		steal_range = {type = "number", default = 2, min = 0, max = 32},
		immunity = {type = "number", default = 5, min = 0, max = 3600},
		speed = {type = "number", default = 1, min = 0, max = 10},
		place_action = {type = "string", default = "place_flag"},
		place_key = {type = "string", default = "G"},
		place_label = {type = "string", default = "Place the flag"},
		score_points = {type = "number", default = 1, min = 0,
			max = 1000000},
		score_interval = {type = "number", default = 10, min = 0.1,
			max = 3600},
		score_to = {type = "string", default = "region",
			choices = {"region", "placer"}},
		return_time = {type = "number", default = 0, min = 0, max = 36000},
		on_death = {type = "string", default = "home",
			choices = {"home", "drop"}},
		on_blast = {type = "string", default = "fall",
			choices = {"fall", "home", "none"}},
		lift = {type = "number", default = 1.6, min = 0, max = 10},
		poll = {type = "number", default = 0.1, min = 0.05, max = 5},
		marker_color = {type = "string", default = "#ffe040"},
		marker_label = {type = "string", default = "Flag"},
		marker_lift = {type = "number", default = 1, min = 0, max = 10},
	},
	state = {
		-- "home", "carried" or "placed"
		where = {default = "home", shared = true},
		enabled = {default = true, shared = true},
		home = {default = false},
		holder = {default = 0, shared = true},
		holder_team = {default = 0},
		placer_team = {default = 0},
		immune = {default = 0},
		-- The return's seconds left (-1: not counting), the scoring's
		-- seconds so far
		left = {default = -1},
		acc = {default = 0},
		emitted = {default = {}},
	},
	inputs = {enable = "none", disable = "none", home = "none"},
	outputs = {taken = "string", placed = "string", home = "string",
		left = "number", progress = "number", immune = "number",
		holder_team = "string", scored = "string"},
	on_start = function(c)
		c.state.home = {c.pos[1], c.pos[2], c.pos[3]}
		c.state.enabled = c.params.enabled
		c:after(c.params.poll, "poll")
		c:after(1, "clock")
	end,
	on_timer = function(c, name)
		if name == "poll" then
			poll(c)
		elseif name == "clock" then
			clock(c)
		elseif name == "immune" then
			c.state.immune = 0
			report(c, "immune", 0)
		elseif name == "return" then
			if c.state.where ~= "home" then
				go_home(c, "timer")
			end
		elseif name == "score" then
			score(c)
		end
	end,
	on_input = function(c, input)
		if input == "home" then
			if c.state.where ~= "home" then
				go_home(c, "signal")
			end
		else
			c.state.enabled = input == "enable"
			c:log(input .. "d")
		end
	end,
	on_use = function(c, by)
		local p = player(c, c.player)
		if taking(c) == "click" and present(p) then
			take(c, p)
		end
	end,
	on_action = function(c, name, phase, value, by)
		if phase ~= "pressed" or name ~= c.params.place_action or
				c.state.where ~= "carried" or c.player ~= c.state.holder then
			return
		end
		local p = player(c, c.player)
		if not present(p) then
			return
		end
		c.state.placer_team = c.state.holder_team
		let_go(c)
		c.state.where = "placed"
		c:move(p.pos, {fall = true})
		c:log("placed by", p.name)
		c:emit("placed", p.name)
	end,
	on_died = function(c, player_id)
		if c.state.where == "home" then
			c:emit("home", "home")
		elseif c.state.where == "carried" and player_id == c.state.holder then
			if c.params.on_death == "home" then
				go_home(c, "died")
			else
				c.state.placer_team = c.state.holder_team
				let_go(c)
				c.state.where = "placed"
				c:move(c.pos, {fall = true})
				c:log("dropped: its holder died")
			end
		end
	end,
	on_fall = function(c, pos)
		if not pos then
			go_home(c, "fell")
		elseif c.state.where == "placed" then
			count(c)
		end
	end,
	on_blast = function(c, pos, by)
		if c.state.where ~= "placed" or c.params.on_blast == "none" then
			return
		end
		if c.params.on_blast == "home" then
			go_home(c, "blast")
		else
			c:log("a blast drops it")
			c:move(c.pos, {fall = true})
		end
	end,
}
