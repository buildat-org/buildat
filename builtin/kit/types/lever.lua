-- A lever: on or off, flipped by a player's use or a link's "toggle" (or
-- set by "on"/"off"); it signals "on" or "off" as it flips. Drawn grey
-- while off, green while on
local function flip(c, on, by)
	if on == c.state.on then
		return
	end
	c.state.on = on
	c:log("flipped", on and "on" or "off", "by", c:name(by))
	c:emit(on and "on" or "off")
end

return {
	version = 2,
	usable = true,
	look = {shape = "box", size = {0.2, 0.6, 0.2}, color = "#a0a0a0",
		state = "on", when = {color = "#40c040"}},
	state = {on = {default = false, shared = true}},
	about = {
		group = "Logic",
		what = "On or off, flipped by a player's use; green while on.",
		inputs = {
			toggle = "Flips it.",
			on = "Sets it on.",
			off = "Sets it off.",
		},
		outputs = {
			on = "It flipped on.",
			off = "It flipped off.",
		},
	},
	inputs = {toggle = "none", on = "none", off = "none"},
	outputs = {on = "none", off = "none"},
	on_use = function(c, by)
		flip(c, not c.state.on, by)
	end,
	on_input = function(c, input, value, by)
		flip(c, input == "on" or (input == "toggle" and not c.state.on), by)
	end,
}
