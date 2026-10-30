-- A button: a player uses it, it signals "pressed"
return {
	version = 1,
	usable = true,
	outputs = {"pressed"},
	state = {presses = {default = 0, shared = true}},
	on_use = function(c, by)
		c.state.presses = c.state.presses + 1
		c:log("pressed by", by, "times", c.state.presses)
		c:emit("pressed")
	end,
}
