-- An item giver: a player who uses it gets `count` of `item` (once each
-- with `once`), into their inventory (Kit's counts, or the component that
-- replaces them, which may refuse: a full bag), shown on their screen
return {
	version = 1,
	usable = true,
	look = {shape = "box", size = 0.3, color = "#f0a020"},
	params = {
		item = {type = "string", default = "key", choices_from = "items"},
		count = {type = "number", default = 1, min = 1, max = 1000},
		once = {type = "bool", default = true},
	},
	-- Who has had theirs, by their stable `by`: a table changed in place
	-- ([KIT] stage 4d: Kit sees that too)
	state = {given = {default = {}}},
	about = {
		what = "A player who uses it gets its items.",
		outputs = {
			given = "A player got them.",
			refused = "They did not fit: the inventory refused them.",
		},
	},
	outputs = {given = "none", refused = "none"},
	on_use = function(c, by)
		local given = c.state.given
		if c.params.once and given[by] then
			c:log(c:name(by), "has had theirs")
			return
		end
		if not c:add(c.params.item, c.params.count) then
			c:log(c:name(by), "could not take", c.params.count, c.params.item)
			c:emit("refused")
			return
		end
		given[by] = true
		c:log("gives", c:name(by), c.params.count, c.params.item)
		c:emit("given")
	end,
}
