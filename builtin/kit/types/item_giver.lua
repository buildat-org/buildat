-- An item giver: a player who uses it gets `count` of `item` (once each
-- with `once`), into their inventory (Kit's counts, or the component that
-- replaces them, which may refuse: a full bag), shown on their screen
return {
	version = 1,
	usable = true,
	look = {shape = "box", size = 0.3, color = "#f0a020"},
	params = {
		item = {type = "string", default = "key"},
		count = {type = "number", default = 1, min = 1, max = 1000},
		once = {type = "bool", default = true},
	},
	-- Who has had theirs: a table, so written back whole (Kit sees only
	-- c.state.x = ..., not a change inside a table it holds)
	state = {given = {default = {}}},
	outputs = {"given", "refused"},
	on_use = function(c, by)
		local given = c.state.given
		if c.params.once and given[by] then
			c:log(by, "has had theirs")
			return
		end
		if not c:add(c.params.item, c.params.count) then
			c:log(by, "could not take", c.params.count, c.params.item)
			c:emit("refused")
			return
		end
		given[by] = true
		c.state.given = given
		c:log("gives", by, c.params.count, c.params.item)
		c:emit("given")
	end,
}
