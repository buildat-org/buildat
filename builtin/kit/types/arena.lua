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
-- round (its player entity is the round's own).
-- [KIT_CTF] `map`: the scene the round is played in ("": the arena's
-- own): the session's players go into its copy, its teams the round's,
-- and back to the arena's scene at the end. `time_up`: "draw" (the
-- default) or "most" (the team with the most points wins; a tie is
-- overtime, shown, until the scores differ). Its UI is drawn in its own
-- scene: output `status`, the round's line as it changes (the time left
-- or "Overtime", the scores, the result), is for a text in the map
-- [KIT_ARENA_SCORE_TO_WIN] `score_to_win` (0: none): a team with that
-- many points wins the round (checked each second), whichever of it and
-- the round's time comes first; a tie at the time up under "most" is
-- overtime still.
-- [KIT_ARENA_INSTANT_ROUND] `after_round`: after a round's end the next
-- countdown lasts at least this many seconds (0: `countdown` alone), so
-- the round's players, back in the lobby, have time to step into the
-- queue for the next one; first come, first served -- with the next
-- round full, the last to come wait. A countdown running then starts
-- over.
-- [KIT_LATE_JOIN] `late_join`, what a player stepping into the queue
-- while a round runs gets: "queue" (wait for the next round), "join"
-- (into a running round with room: fewer than `max_players` in it,
-- within `join_window` seconds of its start (0: any time) and before its
-- `duration`), "parallel" (enough waiting start another round in a
-- session of its own, `max_rounds` at once) or "join_or_parallel" (join
-- where there is room, else a parallel round). `join_team`, the team a
-- late joiner gets: "fewest" (the fewest players, at random on a tie),
-- "lowest_score" (then the fewest) or "backfill" (only into a round
-- fewer than its start took are in now, into the team furthest under its
-- most). The players a round starts with are split by the fewest, the
-- first on a tie.
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
	local n = #c.state.rounds
	if c.state.count > 0 then
		s = "Starting in " .. c.state.count .. " (" .. q .. " of " ..
				c.params.max_players .. ")"
	elseif n > 0 then
		s = (n == 1 and "Round running" or (n .. " rounds running")) ..
				" (" .. q .. " waiting)"
	else
		s = "Waiting for players: " .. q .. " of " .. p
	end
	if c.state.last ~= "" then
		s = s .. "|Last round: " .. c.state.last
	end
	c.state.status = s
	c.state.value = s
	c.state.shown = q > 0 or n > 0 or c.state.last ~= ""
end

local function start(c)
	c.state.count = 0
	c:after(-1, "count")
	local ids = ids_in(prune(c), c.params.max_players)
	c.state.taking = ids
	c:log("countdown over: a round for", #ids, "players")
	c:session_start(ids)
end

local function parallel(c)
	return c.params.late_join == "parallel" or
			c.params.late_join == "join_or_parallel"
end

local function try_count(c)
	local n = #c.state.rounds
	if c.state.count > 0 or #c.state.queue < c.params.players or
			(n > 0 and (not parallel(c) or n >= c.params.max_rounds)) then
		return
	end
	local secs = c.params.countdown
	if c.state.fresh then
		secs = math.max(secs, c.params.after_round)
		c.state.fresh = false
	end
	if secs <= 0 then
		return start(c)
	end
	c.state.count = secs
	c:log("countdown", c.state.count, "s for", #c.state.queue, "players")
	c:after(1, "count")
end

-- [KIT_LATE_JOIN] A player in the queue into a running round with room.
-- c.sessions is as the run began, the moves done after the tick: those
-- sent since its count last changed (`sent`) are counted on it
-- simplified: a leave in the tick a move lands leaves the count as it
-- was, the move counted twice until it changes again (one waits)
local function try_join(c, pid, by)
	local lj, p = c.params.late_join, c.params
	if lj ~= "join" and lj ~= "join_or_parallel" then
		return false
	end
	local sent = c.state.sent
	for _, id in ipairs(c.state.rounds) do
		local s = (c.sessions or {})[id]
		local k = tostring(id)
		local n = s and s.players
		if s and sent[k] and sent[k].was == s.players then
			n = n + sent[k].n
		end
		if s and n < p.max_players and
				(p.join_window <= 0 or s.clock < p.join_window) and
				(p.duration <= 0 or s.clock < p.duration) and
				(p.join_team ~= "backfill" or n < s.taken) then
			local q = c.state.queue
			drop(q, pid)
			c.state.queue = q
			sent[k] = {was = s.players, n = n - s.players + 1}
			c.state.sent = sent
			c:log(c:name(by), "joins the running round in session",
					id, "(" .. n .. " in it)")
			c:session_move(pid, id)
			return true
		end
	end
	return false
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
			(c.state.overtime and "Overtime" or
			c.params.duration > 0 and clock(c.state.left) .. " left" or
			"Round")
	if #teams > 0 then
		s = s .. "|" .. scores(teams)
	end
	if s ~= c.state.value then
		c:emit("status", s)
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
		map = {type = "string", default = "", choices_from = "scenes"},
		time_up = {type = "string", default = "draw",
			choices = {"draw", "most"}},
		score_to_win = {type = "number", default = 0, min = 0,
			max = 1000000},
		after_round = {type = "number", default = 10, min = 0, max = 600},
		late_join = {type = "string", default = "queue",
			choices = {"queue", "join", "parallel", "join_or_parallel"}},
		join_window = {type = "number", default = 0, min = 0, max = 86400},
		join_team = {type = "string", default = "fewest",
			choices = {"fewest", "lowest_score", "backfill"}},
		max_rounds = {type = "number", default = 2, min = 1, max = 8},
	},
	state = {
		-- The default round's: the players in the zone in the order they
		-- came, the countdown's seconds left, the running rounds' sessions
		-- and the last round's result
		queue = {default = {}},
		taking = {default = {}},
		count = {default = 0},
		-- A round ended, no countdown since (for `after_round` seconds)
		fresh = {default = false},
		rounds = {default = {}},
		-- The players sent into each round ({[id] = {was, n}}: n since its
		-- count was `was`)
		sent = {default = {}},
		last = {default = ""},
		status = {default = "waiting", shared = true},
		-- The round's: the team of each player ("player:<id>" = its
		-- id), the seconds left, the result
		assigned = {default = {}},
		peak = {default = {}},
		left = {default = 0},
		overtime = {default = false},
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
	outputs = {started = "number", ended = "number", result = "string",
		status = "string"},
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
		c.state.overtime = false
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
		if not try_join(c, c.player, by) then
			try_count(c)
		end
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
		-- [KIT_LATE_JOIN] Those its start took split by the fewest (the
		-- first on a tie); a late joiner by join_team, at random on a tie
		local a, taken = c.state.assigned, 0
		for _ in pairs(a) do
			taken = taken + 1
		end
		local late = taken >= (c.session_players or 0)
		local rule = late and c.params.join_team or "fewest"
		local peak = c.state.peak
		local function rank(t)
			if rule == "lowest_score" then
				return t.score * 1000 + t.n
			elseif rule == "backfill" then
				return (t.n - (peak[tostring(t.id)] or 0)) * 1000 + t.n
			end
			return t.n
		end
		local best, ties = nil, {}
		for _, t in ipairs(teams_of(c)) do
			if not best or rank(t) < rank(best) then
				best, ties = t, {t}
			elseif rank(t) == rank(best) then
				ties[#ties + 1] = t
			end
		end
		if not best then
			return
		end
		if late and #ties > 1 then
			best = ties[math.random(#ties)]
		end
		if late then
			c:log(c:name(by), "joins late (" .. rule .. ")")
		end
		a[key] = best.id
		c.state.assigned = a
		c:send(best.id, "join")
		-- Each team's most players at once (backfill's)
		for _, t in ipairs(teams_of(c)) do
			peak[tostring(t.id)] = math.max(peak[tostring(t.id)] or 0, t.n)
		end
		c.state.peak = peak
		round_status(c)
	end,
	on_session_start = function(c, id)
		local rounds = c.state.rounds
		rounds[#rounds + 1] = id
		c.state.rounds = rounds
		-- Those taken in are out of the queue (out of the zone, too)
		local q = c.state.queue
		for _, pid in ipairs(c.state.taking) do
			drop(q, pid)
		end
		c.state.queue = q
		c.state.taking = {}
		c:log("session", id, "started")
		c:emit("started", id)
		-- Those left waiting: a parallel round
		try_count(c)
		lobby_status(c)
	end,
	on_session_end = function(c, id, outcome)
		local rounds = c.state.rounds
		if not drop(rounds, id) then
			return
		end
		c.state.rounds = rounds
		local sent = c.state.sent
		sent[tostring(id)] = nil
		c.state.sent = sent
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
		if c.params.after_round > 0 then
			c.state.fresh = true
			c:after(c.params.after_round, "fresh")
		end
		if c.state.count > 0 then
			c.state.count = math.max(c.params.countdown,
					c.params.after_round)
			c.state.fresh = false
			c:log("a round ended: the countdown starts over,",
					c.state.count, "s")
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
			local goal = c.params.score_to_win
			if goal > 0 then
				local best
				for _, t in ipairs(teams_of(c)) do
					if t.score >= goal and (not best or t.score > best.score) then
						best = t
					end
				end
				if best then
					c:log("session", c.session, "over:", best.name, "has",
							best.score, "of", goal, "points")
					return finish(c, best.name, "score to win (" .. goal .. ")")
				end
			end
			if c.params.duration > 0 then
				c.state.left = math.max(0, c.state.left - 1)
				if not c.state.overtime and
						(c.state.left <= 3 or c.state.left % 10 == 0) then
					c:log("round:", c.state.left, "s left")
				end
				if c.state.left <= 0 and c.params.time_up == "most" then
					local best, tie
					for _, t in ipairs(teams_of(c)) do
						if not best or t.score > best.score then
							best, tie = t, false
						elseif t.score == best.score then
							tie = true
						end
					end
					if best and not tie then
						c:log("session", c.session, "over: its time is up,",
								best.name, "has the most points")
						return finish(c, best.name, "time up, the most points")
					elseif best and not c.state.overtime then
						c.state.overtime = true
						c:log("time up, tied:", scores(teams_of(c)),
								"-- overtime")
					end
				end
				if c.state.left <= 0 and not c.state.overtime then
					c:log("session", c.session, "over: its time is up")
					return finish(c, nil, "time up")
				end
			end
			round_status(c)
			c:after(1, "tick")
		elseif name == "over" then
			c:session_end(nil, c.state.outcome)
		elseif name == "fresh" then
			c.state.fresh = false
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
		elseif #c.state.rounds > 0 then
			c.state.last = "stopped|" .. ended_by(c, '"end"')
			c:log("round over:", c.state.last)
			for _, id in ipairs(c.state.rounds) do
				c:session_end(id)
			end
		end
	end,
}
