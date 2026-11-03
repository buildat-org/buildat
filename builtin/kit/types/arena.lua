-- An arena ([KIT_SESSIONS_1]): a zone (its own cell and `size` on). Once
-- `players` are in it and none of its sessions runs, a game session of the
-- start for those in it (c:session_start), which they are taken to. It
-- ends on the input "end", after `duration` seconds (0: when ended), or
-- from inside the session (its own copy there given "end"); its players
-- are back in the default round then. "started" and "ended" carry the
-- session's id; "status" says it. Its pad is drawn at its own cell. Its
-- copy in the session starts none
return {
	version = 1,
	zone = "size",
	params = {
		size = {type = "position", default = {4, 3, 4}},
		players = {type = "number", default = 2, min = 1, max = 16},
		duration = {type = "number", default = 0, min = 0, max = 86400},
	},
	state = {
		inside = {default = 0},
		session = {default = 0},
		status = {default = "waiting", shared = true},
	},
	-- Its pad, the zone's first cell's floor, seen in play
	look = {shape = "box", size = {1, 0.1, 1}, color = "#f0a030"},
	inputs = {["end"] = "none"},
	outputs = {started = "number", ended = "number"},
	on_enter = function(c, by)
		if c.session ~= 0 then
			return
		end
		c.state.inside = c.state.inside + 1
		c:log(c:name(by), "entered;", c.state.inside, "of",
			c.params.players, "inside")
		if c.state.session == 0 and c.state.inside >= c.params.players then
			c:session_start()
		end
	end,
	on_leave = function(c)
		if c.session ~= 0 then
			return
		end
		c.state.inside = math.max(0, c.state.inside - 1)
	end,
	on_session_start = function(c, id)
		c.state.session = id
		c.state.status = "session " .. id .. " running"
		c:log("session", id, "started")
		c:emit("started", id)
		if c.params.duration > 0 then
			c:after(c.params.duration, "end")
		end
	end,
	on_session_end = function(c, id)
		if id ~= c.state.session then
			return
		end
		c.state.session = 0
		c.state.status = "waiting"
		c:after(-1, "end")
		c:log("session", id, "ended")
		c:emit("ended", id)
	end,
	on_timer = function(c)
		if c.state.session ~= 0 then
			c:log("session", c.state.session, "over: its time is up")
			c:session_end(c.state.session)
		end
	end,
	on_input = function(c, input)
		if input ~= "end" then
			return
		end
		if c.session ~= 0 then
			c:log("session", c.session, "ended from inside")
			c:session_end()
		elseif c.state.session ~= 0 then
			c:session_end(c.state.session)
		end
	end,
}
