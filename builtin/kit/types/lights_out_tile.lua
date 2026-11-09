-- A Lights Out tile (kit/lights_out builds them): lit or not, `lit` at the
-- round's start. A player's use signals "pressed" (the board links it to
-- the tile's own "toggle" and its neighbours'); "toggle" flips it, and it
-- signals "changed" +1 as it lights, -1 as it goes dark (the board counts)
return {
	version = 1,
	usable = true,
	params = {lit = {type = "bool", default = false}},
	look = {shape = "box", size = {0.9, 0.15, 0.9}, color = "#303848",
		state = "lit", when = {color = "#ffe040"}},
	state = {lit = {default = false, shared = true}},
	about = {
		group = "Logic",
		what = "One tile of a Lights Out board, lit or not.",
		inputs = {
			toggle = "Flips it.",
		},
		outputs = {
			pressed = "A player used it; it flips only by its links.",
			changed = "It flipped. Value: 1 lit, -1 dark.",
		},
	},
	inputs = {toggle = "none"},
	outputs = {pressed = "none", changed = "number"},
	on_start = function(c)
		c.state.lit = c.params.lit
		if c.state.lit then
			c:emit("changed", 1)
		end
	end,
	on_use = function(c)
		c:emit("pressed")
	end,
	on_input = function(c)
		c.state.lit = not c.state.lit
		c:emit("changed", c.state.lit and 1 or -1)
	end,
}
