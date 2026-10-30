-- A counter: counts what reaches its "count"
return {
	version = 1,
	inputs = {"count"},
	state = {count = {default = 0}},
	on_input = function(c, input, value, by)
		c.state.count = c.state.count + 1
		c:log("count", c.state.count, "by", by)
	end,
}
