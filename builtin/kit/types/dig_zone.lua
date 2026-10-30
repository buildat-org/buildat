-- A dig zone: a box of cells (its own and `size` on) where players may dig
-- (and place, with `place`), edit rights or not. "off" takes it back, "on"
-- gives it again. Unseen in play; the editor draws its box
local function set(c, on, by)
	c.state.dig = on and c.params.dig
	c.state.place = on and c.params.place
	local what = {}
	what[#what + 1] = c.state.dig and "dig" or nil
	what[#what + 1] = c.state.place and "place" or nil
	c:log("grants", #what > 0 and table.concat(what, " and ") or "nothing",
			"by", c:name(by))
end

return {
	version = 1,
	grants = "size",
	params = {
		size = {type = "position", default = {5, 2, 5}},
		dig = {type = "bool", default = true},
		place = {type = "bool", default = false},
	},
	state = {
		dig = {default = false},
		place = {default = false},
	},
	gizmo = {shape = "box", size = 0.2, color = "#c08040"},
	inputs = {on = "none", off = "none"},
	on_start = function(c)
		set(c, true, "its start")
	end,
	on_input = function(c, input, value, by)
		set(c, input == "on", by)
	end,
}
