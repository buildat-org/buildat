-- A gate: a wall three wide and three tall (its size), solid while shut
-- and sunk to a strip on the ground while open, that a link opens and
-- shuts -- "open", "close", "toggle" -- and no player can open by hand.
-- What a button, a lever or a zone guards
return {
	version = 2,
	params = {
		size = {type = "position", default = {3, 3, 1}},
	},
	look = {shape = "box", extent = "size", depth = 0.3, color = "#707880",
		solid = true, state = "open",
		when = {scale = {1, 0.08, 1}, solid = false}},
	state = {open = {default = false, shared = true}},
	inputs = {"open", "close", "toggle"},
	outputs = {"opened", "closed"},
	on_input = function(c, input, value, by)
		local open = input == "open" or (input == "toggle" and not c.state.open)
		if open == c.state.open then
			return
		end
		c.state.open = open
		c:log(open and "opened" or "shut", "by", by)
		c:emit(open and "opened" or "closed")
	end,
}
