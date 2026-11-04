-- An arena ([KIT_SESSIONS_1]; the lobby, queue and round of
-- [KIT_MINIGAMES_1], stage 7b): the framework's half of a round-based
-- game, whose goal is the builder's (a link into "win").
-- **The queue**: players join by entering its zone (its own cell and
-- `size` on; its pad is drawn at its own cell) and leave it by stepping
-- out. With `players` (the minimum) in it and none of its rounds running,
-- a countdown of `countdown` seconds starts; one leaving below the
-- minimum cancels it. At its end a game session of the start
-- (c:session_start) takes the first `max_players` in, in the order they
-- came; the others keep waiting.
-- **The round**, its copy in the session: each player as they arrive put
-- in the team with the fewest (kit/team, "join": its pad their spawn;
-- with no teams they play alone), the round timer counting `duration`
-- seconds down (0: no limit). The round ends with a winner by "win"
-- (a team's id -- a kit/team's "reached" --, a team's name, or else the
-- team of the player who set it off), or as a draw at the timer's end;
-- the result shown for `results` seconds, then everyone back in the
-- default round. "end" ends it at once, from either side. The screens and
-- the log say why it ended ("Round ended by <arena>: time up", "a win",
-- "end"). [KIT_MINIGAMES_FIX] The session is a copy of the whole start:
-- only the arena that started it runs a round there, any other is idle.
-- Its outputs, in the default round: started and ended (the session's
-- id), result (the winner's name, "" a draw). Its status is on the
-- players' screens (`ui`), their own team's name with it in a round.
-- [KIT_INVENTORY_PLAY] The inventory at the round's ends (Kit's):
-- `at_start` "kit" (empty, then the starting kits), "clear" (empty, no
-- kit) or "keep" (what they had in the lobby); `at_end`, as they come
-- back after the results: "before" (what they had before the round),
-- "keep" (the round's), "clear" (nothing) or "living" (the round's for
-- one who did not die in it, else nothing). Health starts full in a
-- round (its player entity is the round's own)
local function ids_in(list, n)
	local out = {}
	for i = 1, math.min(n, #list) do
		out[i] = list[i]
	end
	return out
end

local function drop(list, x)
	for i, v in ipairs(list) do
		if v == x then
			table.remove(list, i)
			return true
		end
	end
	return false
end

-- The queue less players gone (a guest's entity dropped as they log in
-- tells no leave): c.players has those here
local function prune(c)
	local here = {}
	for _, p in ipairs(c.players or {}) do
		here[p.id] = true
	end
	local q = {}
	for _, id in ipairs(c.state.queue) do
		if here[id] then
			q[#q + 1] = id
		end
	end
	c.state.queue = q
	return q
end

-- In a session another arena started: nothing to do there
local function idle(c)
	return c.session ~= 0 and c.session_maker ~= c.id
end

-- Why the round ended, for the screens and the log
local function ended_by(c, cause)
	local n = c:name(c.id)
	return "Round ended by " .. (n == tostring(c.id) and ("arena " .. n) or n) ..
			": " .. cause
end

local function clock(s)
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- The default round's side: the queue's status
local function lobby_status(c)
	local q, p = #c.state.queue, c.params.players
	local s
	if c.state.session ~= 0 then
		s = "Round running (" .. q .. " waiting)"
	elseif c.state.count > 0 then
		s = "Starting in " .. c.state.count .. " (" .. q .. " of " ..
				c.params.max_players .. ")"
	else
		s = "Waiting for players: " .. q .. " of " .. p
	end
	if c.state.last ~= "" then
		s = s .. "|Last round: " .. c.state.last
	end
	c.state.status = s
	c.state.value = s
	c.state.shown = q > 0 or c.state.session ~= 0 or c.state.last ~= ""
end

local function start(c)
	c.state.count = 0
	c:after(-1, "count")
	local ids = ids_in(prune(c), c.params.max_players)
	c.state.taking = ids
	c:log("countdown over: a round for", #ids, "players")
	c:session_start(ids)
end

local function try_count(c)
	if c.state.session ~= 0 or c.state.count > 0 or
			#c.state.queue < c.params.players then
		return
	end
	if c.params.countdown <= 0 then
		return start(c)
	end
	c.state.count = c.params.countdown
	c:log("countdown", c.state.count, "s for", #c.state.queue, "players")
	c:after(1, "count")
end

-- The session's side: the teams by id, each with its count of players.
-- [KIT_TEAM_LEFTOVERS] A leaver's slot: only the players still here
-- counted, so the next to join fills the team they left; one who comes
-- back is put in their own team again
local function teams_of(c)
	local out, here = {}, {}
	for _, t in ipairs(c.teams or {}) do
		out[#out + 1] = {id = t.id, name = tostring(t.params.name or t.id),
			score = tonumber(t.state.score) or 0, n = 0}
	end
	for _, p in ipairs(c.players or {}) do
		here["player:" .. p.id] = true
	end
	for pid, tid in pairs(c.state.assigned) do
		for _, t in ipairs(out) do
			if t.id == tid and here[pid] then
				t.n = t.n + 1
			end
		end
	end
	return out
end

local function scores(teams)
	local t = {}
	for i, x in ipairs(teams) do
		t[i] = x.name .. " " .. x.score
	end
	return table.concat(t, " : ")
end

local function round_status(c)
	local teams = teams_of(c)
	local s = c.state.result ~= "" and
			(c.state.result .. "|" .. c.state.ended) or
			(c.params.duration > 0 and clock(c.state.left) .. " left" or
			"Round")
	if #teams > 0 then
		s = s .. "|" .. scores(teams)
	end
	c.state.status = s
	c.state.value = s
	c.state.shown = true
	local own, names = {}, {}
	for _, t in ipairs(teams) do
		names[t.id] = t.name
	end
	for pid, tid in pairs(c.state.assigned) do
		own[pid] = {value = "Team " .. tostring(names[tid]) .. "|" .. s}
	end
	c.state.own = own
end

-- The round's end: a winner's name, or nil (a draw; stopped: by "end",
-- at once), and its cause
local function finish(c, winner, cause, stopped)
	if c.state.result ~= "" then
		return
	end
	c:after(-1, "tick")
	local teams = teams_of(c)
	c.state.result = winner and (winner .. " wins!") or
			(stopped and "Stopped" or "Draw")
	c.state.ended = ended_by(c, cause)
	c:log("round over:", c.state.result, scores(teams), "--", c.state.ended)
	round_status(c)
	local sc = {}
	for _, t in ipairs(teams) do
		sc[t.name] = t.score
	end
	c.state.outcome = {winner = winner or "", scores = sc,
		ended = c.state.ended, stopped = stopped or nil}
	if c.params.results > 0 and not stopped then
		c:after(c.params.results, "over")
	else
		c:session_end(nil, c.state.outcome)
	end
end

return {
	version = 3,
	zone = "size",
	teams = true,
	-- (every player read: the queue keeps those here)
	players = true,
	params = {
		size = {type = "position", default = {4, 3, 4}},
		-- The minimum (version 1's only one)
		players = {type = "number", default = 2, min = 1, max = 16},
		max_players = {type = "number", default = 8, min = 1, max = 64},
		countdown = {type = "number", default = 10, min = 0, max = 600},
		duration = {type = "number", default = 300, min = 0, max = 86400},
		results = {type = "number", default = 5, min = 0, max = 60},
		at_start = {type = "string", default = "kit",
			choices = {"kit", "clear", "keep"}},
		at_end = {type = "string", default = "before",
			choices = {"before", "keep", "clear", "living"}},
	},
	state = {
		-- The default round's: the players in the zone in the order they
		-- came, the countdown's seconds left, the running round's session
		-- and the last round's result
		queue = {default = {}},
		taking = {default = {}},
		count = {default = 0},
		session = {default = 0},
		last = {default = ""},
		status = {default = "waiting", shared = true},
		-- The round's: the team of each player ("player:<id>" = its
		-- id), the seconds left, the result
		assigned = {default = {}},
		left = {default = 0},
		result = {default = ""},
		ended = {default = ""},
		outcome = {default = false},
		-- On the players' screens: everyone's, and each player's own
		shown = {default = true, shared = true},
		value = {default = "", shared = true},
		own = {default = {}, per_player = true},
	},
	ui = {kind = "text", text = "{value}", anchor = "top", x = 0, y = 70,
		size = 18, color = "#ffffff", background = "#00000080"},
	-- Its pad, the zone's first cell's floor, seen in play
	look = {shape = "box", size = {1, 0.1, 1}, color = "#f0a030"},
	inputs = {["end"] = "none", win = "any"},
	outputs = {started = "number", ended = "number", result = "string"},
	-- Version 1 started at once and had no results to show
	migrate = function(params, from)
		if from < 2 then
			params.countdown = 0
			params.results = 0
			params.max_players = 64
			params.duration = params.duration or 0
		end
		return params
	end,
	on_start = function(c)
		if c.session == 0 then
			return lobby_status(c)
		end
		if idle(c) then
			c.state.shown = false
			c:log("idle in session", c.session, "(another arena's round)")
			return
		end
		c.state.left = c.params.duration
		c:log("round starts:", c.params.duration > 0 and
				(c.params.duration .. " s") or "no time limit")
		round_status(c)
		c:after(1, "tick")
	end,
	on_enter = function(c, by)
		if c.session ~= 0 or not c.player then
			return
		end
		local q = prune(c)
		drop(q, c.player)
		q[#q + 1] = c.player
		c.state.queue = q
		c:log(c:name(by), "entered;", #q, "of", c.params.players, "inside")
		try_count(c)
		lobby_status(c)
	end,
	on_leave = function(c, by)
		if c.session ~= 0 or not c.player then
			return
		end
		local q = prune(c)
		drop(q, c.player)
		c.state.queue = q
		if c.state.count > 0 and #q < c.params.players then
			c.state.count = 0
			c:after(-1, "count")
			c:log(c:name(by), "left: the countdown cancelled")
		end
		lobby_status(c)
	end,
	on_join = function(c, by)
		if c.session == 0 or idle(c) or not c.player or
				c.state.result ~= "" then
			return
		end
		local key = "player:" .. c.player
		if c.state.assigned[key] then
			c:send(c.state.assigned[key], "join")
			return
		end
		local best
		for _, t in ipairs(teams_of(c)) do
			if not best or t.n < best.n then
				best = t
			end
		end
		if not best then
			return
		end
		local a = c.state.assigned
		a[key] = best.id
		c.state.assigned = a
		c:send(best.id, "join")
		round_status(c)
	end,
	on_session_start = function(c, id)
		c.state.session = id
		-- Those taken in are out of the queue (out of the zone, too)
		local q = c.state.queue
		for _, pid in ipairs(c.state.taking) do
			drop(q, pid)
		end
		c.state.queue = q
		c.state.taking = {}
		c:log("session", id, "started")
		c:emit("started", id)
		lobby_status(c)
	end,
	on_session_end = function(c, id, outcome)
		if id ~= c.state.session then
			return
		end
		c.state.session = 0
		local w = type(outcome) == "table" and outcome.winner or nil
		if type(outcome) == "table" then
			local t = {}
			for name, s in pairs(outcome.scores or {}) do
				t[#t + 1] = name .. " " .. tostring(s)
			end
			table.sort(t)
			c.state.last = (outcome.stopped and "stopped" or
					w ~= "" and (w .. " won") or "a draw") ..
					(#t > 0 and (" (" .. table.concat(t, ", ") .. ")") or "") ..
					(type(outcome.ended) == "string" and
					("|" .. outcome.ended) or "")
			if outcome.stopped then
				w = nil
			end
		end
		c:log("session", id, "ended", c.state.last)
		c:emit("ended", id)
		if type(w) == "string" then
			c:emit("result", w)
		end
		lobby_status(c)
		try_count(c)
	end,
	on_timer = function(c, name)
		if name == "count" then
			if c.state.count <= 0 then
				return
			end
			c.state.count = c.state.count - 1
			if #prune(c) < c.params.players then
				c.state.count = 0
				c:log("a player gone: the countdown cancelled")
			elseif c.state.count <= 0 then
				start(c)
			else
				c:after(1, "count")
			end
			lobby_status(c)
		elseif name == "tick" then
			if c.params.duration > 0 then
				c.state.left = math.max(0, c.state.left - 1)
				if c.state.left <= 3 or c.state.left % 10 == 0 then
					c:log("round:", c.state.left, "s left")
				end
				if c.state.left <= 0 then
					c:log("session", c.session, "over: its time is up")
					return finish(c, nil, "time up")
				end
			end
			round_status(c)
			c:after(1, "tick")
		elseif name == "over" then
			c:session_end(nil, c.state.outcome)
		end
	end,
	on_input = function(c, input, value, by)
		if idle(c) then
			return
		end
		if input == "win" then
			if c.session == 0 then
				return
			end
			local winner
			for _, t in ipairs(teams_of(c)) do
				if t.id == value or t.name == value then
					winner = t.name
				end
			end
			if not winner and c.player then
				local tid = c.state.assigned["player:" .. c.player]
				for _, t in ipairs(teams_of(c)) do
					if t.id == tid then
						winner = t.name
					end
				end
				winner = winner or c:name(by)
			end
			if winner then
				finish(c, winner, "a win")
			else
				c:log("win: no team or player in", tostring(value))
			end
			return
		end
		if input ~= "end" then
			return
		end
		if c.session ~= 0 then
			c:log("session", c.session, "ended from inside")
			if c.state.result ~= "" then
				c:session_end(nil, c.state.outcome)
			else
				finish(c, nil, '"end"', true)
			end
		elseif c.state.session ~= 0 then
			c.state.last = "stopped|" .. ended_by(c, '"end"')
			c:log("round over:", c.state.last)
			c:session_end(c.state.session)
		end
	end,
}
