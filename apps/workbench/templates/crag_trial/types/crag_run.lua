-- Crag Trial's run, each rider's own: a clock from the start (a tenth at a
-- time), the gems taken (every entity linked to its input gem: all of them
-- open the finish) and the best time, on their screen (hud, to a
-- kit/ui_text whose to is "player"). A crash (crag_bike's output; the bike
-- goes back by itself), a hazard (a kit/trigger_zone's entered: back to
-- `start`) or the finish with every gem (finished, the time; back to
-- `start`) starts the run over: the clock at 0, every linked gem back (and
-- reset, for more). [CRAG_BEST_RESET] The best times are kept state, by the
-- rider's name: play never resets them, a builder's "Clear kept state" does;
-- the five best go out on board (a kit/sign's value) as they change.
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
		r = {t = 0, got = 0}
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

-- Its line; a note (what just happened) for two seconds
local function show(c, by, r, note)
	if note then
		r.note, r.note_left = note, 2
	end
	local all = r.got >= gems(c)
	local best = c.state.bests[c:name(by)]
	note = (r.note_left or 0) > 0 and r.note or all and "The finish is open" or nil
	c:emit("hud", "Time " .. tenths(math.max(0, r.t)) .. (best and
			"   Best " .. tenths(best) or "") .. "   Gems " .. r.got .. "/" ..
			gems(c) .. (note and "   " .. note or ""), by)
end

-- The five best, "1. name 12.3|2. ...", out when it changed
local function board(c)
	local all = {}
	for name, t in pairs(c.state.bests) do
		all[#all + 1] = {name, t}
	end
	table.sort(all, function(a, b)
		return a[2] < b[2] or a[2] == b[2] and a[1] < b[1]
	end)
	local lines = {}
	for i = 1, math.min(5, #all) do
		lines[i] = i .. ". " .. all[i][1] .. " " .. tenths(all[i][2])
	end
	local text = table.concat(lines, "|")
	if text ~= c.state.board then
		c.state.board = text
		c:emit("board", text)
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

-- Over from the start: the clock held a second (the bike's crash, a teleport)
local function over(c, by, why)
	local r = view(c, by)
	r.t, r.got = -1, 0
	for _, id in ipairs(c.linked_in.gem or {}) do
		c:send(id, "reset", nil, by)
	end
	c:emit("reset", nil, by)
	open(c, by, r)
	c:log(c:name(by) .. ": " .. why .. ", the run starts over")
	show(c, by, r, why:sub(1, 1):upper() .. why:sub(2))
end

return {
	version = 1,
	no_position = true,
	reads_players = true,
	linked_in = true,
	about = {
		group = "Game",
		what = "Crag Trial's run: each rider's clock, gems, finish and best time.",
		inputs = {
			start = "The rider's run starts (a kit/lobby's entered); the clock starts from 0.",
			gem = "The rider took a gem. Every entity linked here is a gem needed to finish.",
			crash = "The rider crashed: the run starts over.",
			hazard = "The rider touched a hazard: back to the start.",
			finish = "The rider reached the finish; it counts as a time if every gem is taken.",
		},
		outputs = {
			hud = "The rider's HUD line. Value: time, best time and gems.",
			reset = "The run started over (the linked gems come back by themselves).",
			finished = "A run finished. Value: its time.",
			result = "A run finished. Value: \"Time 12.3|Best 11.0\", for the rider's result card.",
			board = "The five best times as they change. Value: \"1. name 12.3|2. ...\".",
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
		bests = {default = {}, kept = true},
		board = {default = false},
	},
	inputs = {start = "none", gem = "any", crash = "none", hazard = "none",
		finish = "none"},
	outputs = {hud = "string", reset = "none", finished = "number", board = "string",
		result = "string"},
	on_start = function(c)
		c:after(0.1, "tick")
	end,
	-- (back in: in the lobby, no run; their line, the best, as it was)
	on_join = function(c, by)
		local r = view(c, by)
		r.playing, r.open = nil, nil
		show(c, by, r)
	end,
	on_timer = function(c)
		for _, p in ipairs(c.players or {}) do
			local by = "player:" .. p.id
			local r = view(c, by)
			-- (one on another track: not this run's clock)
			if p.here and not p.away and (r.playing or not waits(c)) then
				r.t = r.t + 0.1
				r.note_left = (r.note_left or 0) - 0.1
				show(c, by, r)
				-- (a gem placed or removed meanwhile)
				open(c, by, r)
			end
		end
		board(c)
		c:after(0.1, "tick")
	end,
	on_input = function(c, input, value, by)
		if type(by) ~= "string" or not by:match("^player:%d+$") then
			return
		end
		local r = view(c, by)
		if input == "start" then
			r.playing = true
			over(c, by, "off you go")
			c:teleport(nil, {entity = c.params.start, yaw = 90})
			return
		end
		if waits(c) and not r.playing then
			return
		end
		if input == "gem" then
			r.got = r.got + 1
			c:log(c:name(by), "has", r.got, "of", gems(c), "gems")
			open(c, by, r)
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
			local t = math.max(0, r.t)
			local name = c:name(by)
			local best = not c.state.bests[name] or t < c.state.bests[name]
			if best then
				c.state.bests[name] = t
			end
			r.playing = nil
			c:emit("result", "Time " .. tenths(t) .. "|Best " ..
					tenths(c.state.bests[name]) .. (best and "|Your best yet" or ""), by)
			c:emit("finished", t, by)
			c:log(name, "finished in", tenths(t), best and "(best)" or "")
			over(c, by, "finished in " .. tenths(t) .. (best and ", the best" or ""))
			board(c)
			c:teleport(nil, {entity = c.params.start, yaw = 90})
		end
	end,
}
