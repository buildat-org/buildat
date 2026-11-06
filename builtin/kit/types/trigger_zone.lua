-- A trigger zone: a box of cells (its own and `size` on) that signals
-- "entered" and "left" as players walk in and out, with how many are in
-- it, and "empty" as the last one leaves. Unseen in play; the editor draws
-- its box
return {
	version = 1,
	zone = "size",
	params = {size = {type = "position", default = {3, 2, 3}}},
	state = {inside = {default = 0, shared = true}},
	gizmo = {shape = "sphere", size = 0.2, color = "#40c0ff"},
	about = {
		what = "An unseen box that notices players walking in and out.",
		outputs = {
			entered = "A player walked in. Value: how many are in it now.",
			left = "A player walked out. Value: how many are in it now.",
			empty = "The last one left.",
		},
	},
	outputs = {entered = "number", left = "number", empty = "none"},
	on_enter = function(c, by)
		c.state.inside = c.state.inside + 1
		c:log(c:name(by), "entered;", c.state.inside, "inside")
		c:emit("entered", c.state.inside)
	end,
	on_leave = function(c, by)
		c.state.inside = math.max(0, c.state.inside - 1)
		c:log(c:name(by), "left;", c.state.inside, "inside")
		c:emit("left", c.state.inside)
		if c.state.inside == 0 then
			c:emit("empty")
		end
	end,
}
