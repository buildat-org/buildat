-- A gate: a wall three wide and three tall (its size), solid while shut
-- and sunk to a strip on the ground while open, that a link opens and
-- shuts -- "open", "close", "toggle" -- and no player can open by hand.
-- What a button, a lever or a zone guards
return {
	version = 2,
	params = {
		size = {cat = "look", type = "position", default = {3, 3, 1}},
		-- [KIT_LOOK_MATERIAL] A voxel material it wears ("": its own colour)
		material = {cat = "look", type = "voxel", default = "",
			choices_from = "voxels"},
	},
	look = {shape = "box", extent = "size", depth = 0.3, color = "#707880",
		voxel = "param:material",
		solid = true, state = "open",
		when = {scale = {1, 0.08, 1}, solid = false}},
	state = {open = {default = false, shared = true}},
	about = {
		what = "A wall that only links open and shut; solid while shut.",
		inputs = {
			open = "Opens it.",
			close = "Shuts it.",
			toggle = "Opens it if shut, else shuts it.",
		},
		outputs = {
			opened = "It opened.",
			closed = "It shut.",
		},
	},
	inputs = {open = "none", close = "none", toggle = "none"},
	outputs = {opened = "none", closed = "none"},
	on_input = function(c, input, value, by)
		local open = input == "open" or (input == "toggle" and not c.state.open)
		if open == c.state.open then
			return
		end
		c.state.open = open
		c:log(open and "opened" or "shut", "by", c:name(by))
		c:emit(open and "opened" or "closed")
	end,
}
