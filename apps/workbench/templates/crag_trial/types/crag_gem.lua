-- Crag Trial's gem: a crystal a rider takes by riding through it (its zone:
-- `size` cells from its own on, the crystal over their middle), then gone
-- until "reset" (crag_run's to every gem linked to it, at a crash, a hazard
-- or the finish).
-- simplified: one taken is gone for every rider till the next reset
return {
	version = 1,
	zone = "size",
	about = {
		group = "Game",
		what = "A gem to collect in Crag Trial: ride through it.",
		inputs = {reset = "Back where it was."},
		outputs = {collected = "A rider took it."},
	},
	look = {shape = "box", size = 0.24, color = "#4cc9f0", offset = {0.5, 0.5, 0},
		state = "taken", when = {scale = {0.01, 0.01, 0.01}}},
	params = {
		size = {cat = "look", type = "position", default = {2, 2, 1}},
	},
	state = {taken = {default = false, shared = true}},
	inputs = {reset = "none"},
	outputs = {collected = "none"},
	on_enter = function(c, by)
		if c.state.taken then
			return
		end
		c.state.taken = true
		c:log(c:name(by), "took the gem")
		c:emit("collected")
		c:event("pickup")
	end,
	on_input = function(c, input)
		if input == "reset" and c.state.taken then
			c.state.taken = false
			c:log("back")
		end
	end,
}
