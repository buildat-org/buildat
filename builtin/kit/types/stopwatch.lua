-- A stopwatch for each player ([KIT_RECORDS]): "start" starts theirs from 0
-- (again while it runs: from 0 again), "stop" stops it and sends elapsed
-- (its seconds), "reset" stops it at 0, "lap" sends lap (the seconds since
-- its start or the last lap) and it runs on; each by the player the signal
-- carries (a stop or reset by no player: everyone's; a start or lap by none
-- does nothing). "time" is for a kit/ui_text (`to` "player"; its
-- {value:time1}): one signal at each start, stop and reset, no more. While
-- it runs that is {since = c.now} (the round's clock as it was 0), which
-- the player's screen counts on from by the shared time; stopped, the
-- seconds it stands at
local function who(by)
	if type(by) == "string" and (by:match("^player:%d+$") or
			by:match("^bot:%d+$")) then
		return by
	end
end

local function stop(c, by, reset)
	local r = c.state.runs[by]
	if r and r.from and not reset then
		local t = math.max(0, c.now - r.from)
		c.state.runs[by] = {at = t}
		c:emit("elapsed", t, by)
		c:emit("time", t, by)
		c:log("stopped for", c:name(by), "at", string.format("%.2f", t), "s")
	elseif r and reset then
		c.state.runs[by] = nil
		c:emit("time", 0, by)
		c:log("reset for", c:name(by))
	end
end

return {
	version = 1,
	no_position = true,
	-- (a stop or reset by nobody reaches every player's)
	reads_players = true,
	params = {},
	state = {
		-- {[by] = {from = c.now at its start, lap = at the last lap}, or
		-- {at = seconds} stopped}
		runs = {default = {}, per_player = true},
	},
	about = {
		group = "Logic",
		what = "Each player's own stopwatch: their run's time, counted on their screen.",
		inputs = {
			start = "Starts the player's stopwatch from 0 (again while it runs: from 0 again).",
			stop = "Stops it and sends elapsed. By no player: everyone's.",
			reset = "Stops it at 0. By no player: everyone's.",
			lap = "Sends lap, the seconds since its start or the last lap; it runs on.",
		},
		outputs = {
			elapsed = "Its stop. Value: the seconds it ran.",
			lap = "A lap. Value: the seconds since its start or the last lap.",
			time = "For a kit/ui_text's {value:time1}, at each start, stop and reset: the running time, counted on the player's screen.",
		},
		params = {},
	},
	inputs = {start = "none", stop = "none", reset = "none", lap = "none"},
	outputs = {elapsed = "number", lap = "number", time = "any"},
	on_input = function(c, input, value, by)
		local p = who(by)
		if input == "stop" or input == "reset" then
			if p then
				stop(c, p, input == "reset")
				return
			end
			local all = {}
			for b in pairs(c.state.runs) do
				all[#all + 1] = b
			end
			table.sort(all)
			for _, b in ipairs(all) do
				stop(c, b, input == "reset")
			end
			return
		end
		if not p then
			c:log(input, "by", c:name(by), "(no player): nothing to time")
			return
		end
		local r = c.state.runs[p]
		if input == "start" then
			c.state.runs[p] = {from = c.now, lap = c.now}
			c:emit("time", {since = c.now}, p)
			c:log("started for", c:name(p))
		elseif input == "lap" and r and r.from then
			local t = math.max(0, c.now - r.lap)
			r.lap = c.now
			c:emit("lap", t, p)
			c:log("lap for", c:name(p), string.format("%.2f", t), "s")
		end
	end,
}
