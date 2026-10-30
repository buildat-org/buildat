-- A timer: once started ("start", or at once with autostart) it signals
-- "tick" every `interval` seconds of game time, `repeats` times (0: until
-- "stop"), then "done". The ticks so far are drawn over it
local function stop(c, why)
	c.state.running = false
	c:after()
	c:log("stopped:", why, "after", c.state.ticks, "ticks")
end

return {
	version = 1,
	look = {shape = "box", size = 0.25, color = "#a060e0", text = "ticks"},
	params = {
		interval = {type = "number", default = 2, min = 0.1, max = 3600},
		repeats = {type = "number", default = 0, min = 0, max = 1000000},
		autostart = {type = "bool", default = false},
	},
	state = {
		running = {default = false, shared = true},
		ticks = {default = 0, shared = true},
	},
	inputs = {"start", "stop"},
	outputs = {"tick", "done"},
	on_start = function(c)
		if c.params.autostart then
			c.state.running = true
			c:after(c.params.interval)
		end
	end,
	on_input = function(c, input, value, by)
		if input == "stop" then
			if c.state.running then
				stop(c, "by " .. by)
			end
			return
		end
		-- A start while it runs starts it over
		c.state.running = true
		c.state.ticks = 0
		c:after(c.params.interval)
		c:log("started by", by, "every", c.params.interval, "s")
	end,
	on_timer = function(c)
		if not c.state.running then
			return
		end
		c.state.ticks = c.state.ticks + 1
		c:log("tick", c.state.ticks)
		c:emit("tick", c.state.ticks)
		if c.params.repeats > 0 and c.state.ticks >= c.params.repeats then
			stop(c, "its repeats done")
			c:emit("done")
		else
			c:after(c.params.interval)
		end
	end,
}
