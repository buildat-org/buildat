-- Crag Trial's run, each rider's own: the gems taken (every entity linked
-- to its input gem: all of them open the finish), on their screen (hud, to
-- a kit/ui_text whose to is "player"; what just happened on note, to one
-- that clears itself), [KIT_RECORDS] the clock a kit/stopwatch's (go starts
-- it, stop stops it at the finish, reset puts it at 0; its elapsed comes
-- back here) and the best times a kit/records' (the stopwatch's elapsed to
-- its time; its best and new_best back here for the result). A crash
-- (crag_bike's output; the bike goes back by itself), a hazard (a
-- kit/trigger_zone's entered: back to `start`) or the finish with every gem
-- (finished, the time; back to `start`) starts the run over: the clock at 0
-- for a second, then from 0, every linked gem back (and reset, for more).
-- [CRAG_BEST_RESET] The best times are the kit/records' kept state, by the
-- rider's name: play never resets them, a builder's "Clear kept state" does;
-- its board (to a kit/sign's value) the five best.
-- [KIT_LOBBY] With a kit/lobby's entered linked to start: each rider's clock
-- from their own Play or Again, their gems, crashes and finish counted only
-- then; the finish their result (the time and the best) and the run over.
-- [KIT_BODY_VARS] A rider with every gem (and in their run) has the finish
-- open on their body (c:body_var "finish_open", s.vars in crag_bike's step):
-- the bike holds itself on the finish line, on their client at once; the
-- finish here (the time, the result) still decides. simplified: a last gem
-- taken under a round trip before the line, the client's bike rewinds there.
local function view(c, by)
	local r = c.state.runs[by]
	if not r then
		r = {got = 0}
		c.state.runs[by] = r
	end
	return r
end

local function tenths(t)
	return string.format("%.1f", math.floor(t * 10 + 0.5) / 10)
end

local function gems(c)
	return #(c.linked_in.gem or {})
end

local function waits(c)
	return #(c.linked_in.start or {}) > 0
end

-- Its line: the gems; a note (what just happened) to its own text
local function show(c, by, r, note)
	c:emit("hud", "Gems " .. r.got .. "/" .. gems(c) ..
			(r.got >= gems(c) and "   The finish is open" or ""), by)
	if note then
		c:emit("note", note, by)
	end
end

-- The finish open for the rider's bike as they have every gem in their run
-- (true or nil: only a change sent)
local function open(c, by, r)
	local want = r.got >= gems(c) and (r.playing or not waits(c)) or nil
	if want ~= r.open then
		r.open = want
		c:body_var(by, "finish_open", want)
	end
end

-- Over from the start: the clock at 0, from 0 a second later (the bike's
-- crash, a teleport)
local function over(c, by, why)
	local r = view(c, by)
	r.got = 0
	for _, id in ipairs(c.linked_in.gem or {}) do
		c:send(id, "reset", nil, by)
	end
	c:emit("reset", nil, by)
	open(c, by, r)
	c:log(c:name(by) .. ": " .. why .. ", the run starts over")
	show(c, by, r, why:sub(1, 1):upper() .. why:sub(2))
	if r.playing or not waits(c) then
		c:after(1, "go", {player = by})
	end
end

-- The finish's time (the stopwatch's elapsed) and best (the records')
local function finished(c, by, r, best)
	local t, new = r.time, r.new
	r.time, r.new = nil, nil
	local name = c:name(by)
	c:emit("result", "Time " .. tenths(t) .. (best and "|Best " .. tenths(best) or
			"") .. (new and "|Your best yet" or ""), by)
	c:emit("finished", t, by)
	c:log(name, "finished in", tenths(t), new and "(best)" or "")
	over(c, by, "finished in " .. tenths(t) .. (new and ", the best" or ""))
	c:teleport(nil, {entity = c.params.start, yaw = 90})
end

return {
	version = 1,
	no_position = true,
	reads_players = true,
	linked_in = true,
	about = {
		group = "Game",
		what = "Crag Trial's run: each rider's gems, finish and result, timed by a kit/stopwatch, the bests a kit/records'.",
		inputs = {
			start = "The rider's run starts (a kit/lobby's entered); the clock starts from 0.",
			gem = "The rider took a gem. Every entity linked here is a gem needed to finish.",
			crash = "The rider crashed: the run starts over.",
			hazard = "The rider touched a hazard: back to the start.",
			finish = "The rider reached the finish; it counts as a time if every gem is taken.",
			elapsed = "The run's time at the finish (the kit/stopwatch's elapsed).",
			best = "The rider's best time (the kit/records' best): the finish's result.",
			new_best = "The finish was the rider's best yet (the kit/records' new_best).",
		},
		outputs = {
			hud = "The rider's HUD line. Value: the gems.",
			note = "What just happened, for a kit/ui_text that clears itself. Value: the line.",
			go = "The rider's clock starts (a kit/stopwatch's start), a second after the run started over.",
			stop = "The rider reached the finish with every gem: their clock stops (a kit/stopwatch's stop).",
			reset = "The run started over (the linked gems come back by themselves; the clock at 0).",
			finished = "A run finished. Value: its time.",
			result = "A run finished. Value: \"Time 12.3|Best 11.0\", for the rider's result card.",
		},
		params = {
			start = "The entity a rider is put back at after a hazard or the finish.",
		},
	},
	params = {
		start = {type = "entity", default = 0},
	},
	state = {
		runs = {default = {}, per_player = true},
	},
	inputs = {start = "none", gem = "any", crash = "none", hazard = "none",
		finish = "none", elapsed = "number", best = "number", new_best = "number"},
	outputs = {hud = "string", note = "string", go = "none", stop = "none",
		reset = "none", finished = "number", result = "string"},
	-- (back in: in the lobby, no run; their line as it was)
	on_join = function(c, by)
		local r = view(c, by)
		r.playing, r.open, r.finishing, r.time = nil, nil, nil, nil
		show(c, by, r)
		if not waits(c) then
			c:emit("go", nil, by)
		end
	end,
	-- (the second after a run started over)
	on_timer = function(c, name, player)
		local by = tostring(player)
		local r = view(c, by)
		if name == "go" and (r.playing or not waits(c)) then
			c:emit("go", nil, by)
		end
	end,
	on_input = function(c, input, value, by)
		if type(by) ~= "string" or not by:match("^player:%d+$") then
			return
		end
		local r = view(c, by)
		if input == "start" then
			r.playing, r.finishing, r.time = true, nil, nil
			over(c, by, "off you go")
			c:teleport(nil, {entity = c.params.start, yaw = 90})
			return
		elseif input == "elapsed" then
			-- (the finish's; the result once the records' best is back,
			-- or now with none linked)
			if r.finishing then
				r.finishing, r.time = nil, tonumber(value) or 0
				if #(c.linked_in.best or {}) == 0 then
					finished(c, by, r, nil)
				end
			end
			return
		elseif input == "new_best" then
			r.new = true
			return
		elseif input == "best" then
			if r.time then
				finished(c, by, r, tonumber(value))
			end
			return
		end
		-- (none while the finish's time comes back)
		if (waits(c) and not r.playing) or r.finishing or r.time then
			return
		end
		if input == "gem" then
			r.got = r.got + 1
			c:log(c:name(by), "has", r.got, "of", gems(c), "gems")
			open(c, by, r)
			show(c, by, r)
		elseif input == "crash" then
			over(c, by, "crashed")
		elseif input == "hazard" then
			over(c, by, "hit a hazard")
			c:teleport(nil, {entity = c.params.start, yaw = 90})
		elseif input == "finish" then
			if r.got < gems(c) then
				show(c, by, r, "Take every gem first")
				return
			end
			r.playing, r.finishing, r.new = nil, true, nil
			c:emit("stop", nil, by)
		end
	end,
}
