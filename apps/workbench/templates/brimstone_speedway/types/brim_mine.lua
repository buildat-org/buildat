-- Brimstone Speedway's mine: a copy of it is dropped behind a car
-- (brim_weapons' c:spawn of its `mine` entity) and sent "arm"; armed a moment
-- later, a car driving onto it (its zone) says "touched" with its id, linked
-- to the weapons' mine by name (a copy keeps only links by name or into itself),
-- which blows it up there. The one placed in the scene is the
-- pattern the copies are made of, never armed.
return {
	version = 1,
	zone = "size",
	about = {
		group = "Game",
		what = "A mine in Brimstone Speedway's race: dropped behind a car and armed, it goes off when a car drives onto it (brim_weapons' mine).",
		inputs = {arm = "Arms it after a moment."},
		outputs = {touched = "A car drove onto it while it was armed. Value: the mine."},
		params = {
			size = "Its zone, cells from its own.",
			delay = "Seconds from arm until it is armed.",
		},
	},
	look = {shape = "sphere", size = 0.7, color = "#3a0d0d", offset = {0.5, 0.25, 0.5},
		state = "armed", when = {color = "#e01818"}},
	params = {
		size = {cat = "look", type = "position", default = {2, 1, 2}},
		delay = {type = "number", default = 0.8, min = 0, max = 10},
	},
	state = {armed = {default = false, shared = true}},
	inputs = {arm = "none"},
	outputs = {touched = "entity"},
	on_input = function(c, input)
		if input == "arm" then
			c:after(c.params.delay, "arm")
		end
	end,
	on_timer = function(c)
		c.state.armed = true
	end,
	on_enter = function(c, by)
		if c.state.armed then
			c:emit("touched", c.id, by)
		end
	end,
}
