-- The relay's score keeper: the rounds played (kept state: Play, Stop and
-- a server restart keep it), the timer's count as the counter last sent
-- it, and at the goal the round's result
return {
	version = 1,
	about = {
		group = "Game",
		what = "Keeps the relay's score: the rounds played and each round's count at the finish.",
		inputs = {
			count = "The count so far. Value: a number.",
			finish = "The runner reached the flag.",
		},
		outputs = {done = "The round is over. Value: the count."},
	},
	look = {shape = "box", size = 0.4, color = "#e0c040"},
	params = {
		bonus = {type = "number", default = 10, min = 0, max = 100},
	},
	state = {
		rounds = {default = 0, kept = true},
		count = {default = 0, shared = true},
		score = {default = 0, shared = true},
	},
	inputs = {count = "number", finish = "any"},
	outputs = {done = "number"},
	on_start = function(c)
		c.state.rounds = c.state.rounds + 1
		c:log("round", c.state.rounds)
	end,
	on_input = function(c, input, value, by)
		if input == "count" then
			c.state.count = value
		elseif input == "finish" then
			c.state.score = c.state.count + c.params.bonus
			c:log("finished by", c:name(by), "count", c.state.count,
				"score", c.state.score, "round", c.state.rounds)
			c:emit("done", c.state.score)
		end
	end,
}
