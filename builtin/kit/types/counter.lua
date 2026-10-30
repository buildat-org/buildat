-- A counter: "count" adds one, "add" the signal's number, "reset" sets it
-- to nought; it signals "reached" when it comes to `target` (0: never)
-- and "changed" with the count each time. The count is drawn over it
return {
	version = 1,
	look = {shape = "box", size = 0.25, color = "#e0c040", text = "count"},
	params = {target = {type = "number", default = 0, min = 0, max = 1000000}},
	state = {count = {default = 0, shared = true}},
	inputs = {count = "none", add = "number", reset = "none"},
	outputs = {reached = "number", changed = "number"},
	on_input = function(c, input, value, by)
		local was = c.state.count
		if input == "reset" then
			c.state.count = 0
		elseif input == "add" then
			c.state.count = was + (type(value) == "number" and value or 0)
		else
			c.state.count = was + 1
		end
		c:log("count", c.state.count, "by", c:name(by))
		c:emit("changed", c.state.count)
		local t = c.params.target
		if t > 0 and was < t and c.state.count >= t then
			c:log("reached", t)
			c:emit("reached", c.state.count)
		end
	end,
}
