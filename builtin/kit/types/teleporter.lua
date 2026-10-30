-- A teleporter: a pad that moves the player who steps on it (or uses it,
-- or sets off its "teleport") to the cell `to`
local function go(c, by, how)
	c:log(how, c:name(by), "to", c.params.to[1], c.params.to[2], c.params.to[3])
	c:teleport(c.params.to)
	c:emit("teleported")
end

return {
	version = 1,
	usable = true,
	zone = "pad",
	look = {shape = "sphere", size = 0.35, color = "#8050ff"},
	params = {
		to = {type = "position", default = {0, 1, 0}},
		pad = {type = "position", default = {1, 1, 1}},
	},
	inputs = {teleport = "none"},
	outputs = {teleported = "none"},
	on_enter = function(c, by)
		go(c, by, "stepped on by")
	end,
	on_use = function(c, by)
		go(c, by, "used by")
	end,
	on_input = function(c, input, value, by)
		go(c, by, "signalled for")
	end,
}
