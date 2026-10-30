-- A button: a thin plate a player presses (uses); it signals "pressed"
-- and stays down for `hold` seconds, then "released". Drawn pushed in
-- while down
return {
	version = 2,
	usable = true,
	params = {
		hold = {type = "number", default = 1, min = 0.1, max = 60},
	},
	look = {shape = "box", size = {0.4, 0.4, 0.15}, color = "#d03030",
		state = "down", when = {scale = {1, 1, 0.4}, color = "#702020"}},
	state = {
		down = {default = false, shared = true},
		presses = {default = 0, shared = true},
	},
	outputs = {pressed = "none", released = "none"},
	on_use = function(c, by)
		if c.state.down then
			return
		end
		c.state.down = true
		c.state.presses = c.state.presses + 1
		c:log("pressed by", c:name(by), "times", c.state.presses)
		c:emit("pressed")
		c:after(c.params.hold)
	end,
	on_timer = function(c)
		c.state.down = false
		c:emit("released")
	end,
}
