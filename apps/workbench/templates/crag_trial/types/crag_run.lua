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
-- [KIT_TEMPLATE_CLEANUP] Back at `start` facing its way (a spawner's yaw:
-- turn it to turn the riders). The HUD's lines, notes and the result card's
-- are params (cat hud), {word}s in them filled in: {got} and {all} gems,
-- {time} and {best} seconds.
local function fill(c, param, vars)
	return (tostring(c.params[param]):gsub("{(%w+)}", function(k)
		local v = vars and vars[k]
		return v ~= nil and tostring(v) or nil
	end))
end

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
	c:emit("hud", fill(c, r.got >= gems(c) and "hud_open" or "hud_gems",
			{got = r.got, all = gems(c)}), by)
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
-- crash, a teleport); why for the log, the note the param `note`'s text
local function over(c, by, why, note, vars)
	local r = view(c, by)
	r.got = 0
	for _, id in ipairs(c.linked_in.gem or {}) do
		c:send(id, "reset", nil, by)
	end
	c:emit("reset", nil, by)
	open(c, by, r)
	c:log(c:name(by) .. ": " .. why .. ", the run starts over")
	show(c, by, r, fill(c, note, vars))
	if r.playing or not waits(c) then
		c:after(1, "go", {player = by})
	end
end

-- The finish's time (the stopwatch's elapsed) and best (the records')
local function finished(c, by, r, best)
	local t, new = r.time, r.new
	r.time, r.new = nil, nil
	local name = c:name(by)
	local vars = {time = tenths(t), best = best and tenths(best)}
	c:emit("result", fill(c, "result_time", vars) .. (best and "|" ..
			fill(c, "result_best", vars) or "") .. (new and "|" ..
			fill(c, "result_new", vars) or ""), by)
	c:emit("finished", t, by)
	c:log(name, "finished in", tenths(t), new and "(best)" or "")
	over(c, by, "finished in " .. tenths(t) .. (new and ", the best" or ""),
			new and "note_best" or "note_finish", vars)
	c:teleport(nil, {entity = c.params.start})
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
			start = "The entity a rider is put back at after a hazard or the finish, facing its way (a spawner's).",
			hud_gems = "The HUD: the gems taken ({got}) of all ({all}).",
			hud_open = "The HUD with every gem taken.",
			note_start = "The note as a run starts.",
			note_crash = "The note after a crash.",
			note_hazard = "The note after a hazard.",
			note_finish = "The note after the finish ({time}).",
			note_best = "The note after a finish that was the rider's best.",
			note_gems = "The note at the finish with a gem left.",
			result_time = "The result card's time line ({time}).",
			result_best = "The result card's best line ({best}).",
			result_new = "The result card's last line after a best.",
		},
	},
	params = {
		start = {type = "entity", default = 0},
		hud_gems = {cat = "hud", type = "string", default = "Gems {got}/{all}"},
		hud_open = {cat = "hud", type = "string",
			default = "Gems {got}/{all}   The finish is open"},
		note_start = {cat = "hud", type = "string", default = "Off you go"},
		note_crash = {cat = "hud", type = "string", default = "Crashed"},
		note_hazard = {cat = "hud", type = "string", default = "Hit a hazard"},
		note_finish = {cat = "hud", type = "string", default = "Finished in {time}"},
		note_best = {cat = "hud", type = "string",
			default = "Finished in {time}, the best"},
		note_gems = {cat = "hud", type = "string", default = "Take every gem first"},
		result_time = {cat = "hud", type = "string", default = "Time {time}"},
		result_best = {cat = "hud", type = "string", default = "Best {best}"},
		result_new = {cat = "hud", type = "string", default = "Your best yet"},
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
			over(c, by, "off you go", "note_start")
			c:teleport(nil, {entity = c.params.start})
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
			over(c, by, "crashed", "note_crash")
		elseif input == "hazard" then
			over(c, by, "hit a hazard", "note_hazard")
			c:teleport(nil, {entity = c.params.start})
		elseif input == "finish" then
			if r.got < gems(c) then
				show(c, by, r, fill(c, "note_gems"))
				return
			end
			r.playing, r.finishing, r.new = nil, true, nil
			c:emit("stop", nil, by)
		end
	end,
}
