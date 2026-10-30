-- A relay: passes "in" on to "out". Two linked to each other are a loop
return {
	version = 1,
	inputs = {"in"},
	outputs = {"out"},
	state = {passed = {default = 0}},
	on_input = function(c, input, value, by)
		c.state.passed = c.state.passed + 1
		c:emit("out", value)
	end,
}
