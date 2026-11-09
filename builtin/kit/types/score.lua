-- A player's score: on each player entity ([KIT] stage 4d), a number
-- every client sees, its own player's on their screen (its client part).
-- "add" adds the signal's number (1 without one), "set" sets it, "reset"
-- makes it 0; a scoreboard sends them (it reads every player's). From the
-- round's start: 0. Not placed
return {
	version = 1,
	player = true,
	state = {score = {default = 0, shared = true}},
	about = {
		group = "Players",
		what = "A player's score; on each player, not placed.",
		inputs = {
			add = "Adds to the score. Value: a number; none adds 1.",
			set = "Sets the score. Value: a number.",
			reset = "Sets it to 0.",
		},
	},
	inputs = {add = "any", set = "number", reset = "none"},
	on_input = function(c, input, value, by)
		if input == "reset" then
			c.state.score = 0
		elseif input == "set" then
			c.state.score = value
		else
			c.state.score = c.state.score + (type(value) == "number" and
					value or 1)
		end
		c:log("score", c.state.score, "by", c:name(by))
	end,
}
