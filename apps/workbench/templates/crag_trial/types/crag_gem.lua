-- Crag Trial's gem: a crystal a rider takes by riding through it (its zone:
-- `size` cells from its own on, the crystal over their middle), then gone
-- until "reset" (crag_run's to every gem linked to it, at a crash, a hazard
-- or the finish). [KIT_LOBBY] Each rider's own: taken per player (a
-- per_player state, each client drawing its own rider's), a reset by the
-- rider brings back theirs
return {
	version = 1,
	zone = "size",
	about = {
		group = "Game",
		what = "A gem to collect in Crag Trial: ride through it. Each rider takes their own.",
		inputs = {reset = "Back where it was, for the rider (everyone's with nobody)."},
		outputs = {collected = "A rider took it."},
	},
	look = {shape = "box", size = 0.24, color = "#4cc9f0", offset = {0.5, 0.5, 0},
		state = "taken", when = {scale = {0.01, 0.01, 0.01}}},
	params = {
		size = {cat = "look", type = "position", default = {2, 2, 1}},
	},
	state = {taken = {default = {}, per_player = true}},
	inputs = {reset = "none"},
	outputs = {collected = "none"},
	on_enter = function(c, by)
		if type(by) ~= "string" or c.state.taken[by] then
			return
		end
		c.state.taken[by] = true
		c:log(c:name(by), "took the gem")
		c:emit("collected", nil, by)
		c:event("pickup")
	end,
	on_input = function(c, input, value, by)
		if input ~= "reset" then
			return
		end
		if type(by) == "string" and by:match("^player:") then
			if c.state.taken[by] then
				c.state.taken[by] = nil
				c:log("back for", c:name(by))
			end
		elseif next(c.state.taken) then
			c.state.taken = {}
			c:log("back")
		end
	end,
}
