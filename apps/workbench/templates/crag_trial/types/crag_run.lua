-- Crag Trial's run, each rider's own: a clock from the start (a tenth at a
-- time), the gems taken (all `gems` of them open the finish) and the best
-- time, on their screen (hud, to a kit/ui_text whose to is "player"). A crash
-- (crag_bike's output; the bike goes back by itself), a hazard (a
-- kit/trigger_zone's entered: back to `start`) or the finish with every gem
-- (finished, the time; back to `start`) starts the run over: the clock at 0,
-- the gems back (reset).
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

-- Its line; a note (what just happened) for two seconds
local function show(c, by, r, note)
	if note then
		r.note, r.note_left = note, 2
	end
	local all = r.got >= c.params.gems
	note = (r.note_left or 0) > 0 and r.note or all and "The finish is open" or nil
	c:emit("hud", "Time " .. tenths(math.max(0, r.t)) .. (r.best and
			"   Best " .. tenths(r.best) or "") .. "   Gems " .. r.got .. "/" ..
			c.params.gems .. (note and "   " .. note or ""), by)
end

-- Over from the start: the clock held a second (the bike's crash, a teleport)
local function over(c, by, why)
	local r = view(c, by)
	r.t, r.got = -1, 0
	c:emit("reset", nil, by)
	c:log(c:name(by) .. ": " .. why .. ", the run starts over")
	show(c, by, r, why:sub(1, 1):upper() .. why:sub(2))
end

return {
	version = 1,
	no_position = true,
	players = true,
	about = {
		group = "Game",
		what = "Crag Trial's run: each rider's clock, gems, finish and best time.",
		inputs = {
			gem = "A gem taken by the rider.",
			crash = "The rider crashed: the run starts over.",
			hazard = "The rider touched a hazard: back to the start.",
			finish = "The rider reached the finish: a time if every gem is taken.",
		},
		outputs = {
			hud = "The rider's line: time, best, gems.",
			reset = "The gems back (a run over).",
			finished = "A run done. Value: its time.",
		},
	},
	params = {
		gems = {type = "number", default = 3, min = 0, max = 100},
		start = {type = "entity", default = 0},
	},
	state = {runs = {default = {}, per_player = true}},
	inputs = {gem = "any", crash = "none", hazard = "none", finish = "none"},
	outputs = {hud = "string", reset = "none", finished = "number"},
	on_start = function(c)
		c:after(0.1, "tick")
	end,
	on_timer = function(c)
		for _, p in ipairs(c.players or {}) do
			if p.here then
				local by = "player:" .. p.id
				local r = view(c, by)
				r.t = r.t + 0.1
				r.note_left = (r.note_left or 0) - 0.1
				show(c, by, r)
			end
		end
		c:after(0.1, "tick")
	end,
	on_input = function(c, input, value, by)
		if type(by) ~= "string" or not by:match("^player:%d+$") then
			return
		end
		local r = view(c, by)
		if input == "gem" then
			r.got = r.got + 1
			c:log(c:name(by), "has", r.got, "of", c.params.gems, "gems")
		elseif input == "crash" then
			over(c, by, "crashed")
		elseif input == "hazard" then
			over(c, by, "hit a hazard")
			c:teleport(nil, {entity = c.params.start, yaw = 90})
		elseif input == "finish" then
			if r.got < c.params.gems then
				show(c, by, r, "Take every gem first")
				return
			end
			local t = math.max(0, r.t)
			local best = not r.best or t < r.best
			r.best = best and t or r.best
			c:emit("finished", t, by)
			c:log(c:name(by), "finished in", tenths(t), best and "(best)" or "")
			over(c, by, "finished in " .. tenths(t) .. (best and ", the best" or ""))
			c:teleport(nil, {entity = c.params.start, yaw = 90})
		end
	end,
}
