-- A button: a player presses it (uses it), it signals "pressed" and stays
-- down for `hold` seconds, then "released". Its cell shows which
return {
	version = 1,
	usable = true,
	owns_voxel = true,
	params = {
		up = {type = "voxel", default = "button"},
		down = {type = "voxel", default = "button_pressed"},
		hold = {type = "number", default = 1, min = 0.1, max = 60},
	},
	state = {
		down = {default = false, shared = true},
		presses = {default = 0, shared = true},
	},
	outputs = {"pressed", "released"},
	on_start = function(c)
		c:set_voxel(c.params.up)
	end,
	on_use = function(c, by)
		if c.state.down then
			return
		end
		c.state.down = true
		c.state.presses = c.state.presses + 1
		c:set_voxel(c.params.down)
		c:log("pressed by", by, "times", c.state.presses)
		c:emit("pressed")
		c:after(c.params.hold)
	end,
	on_timer = function(c)
		c.state.down = false
		c:set_voxel(c.params.up)
		c:emit("released")
	end,
	on_voxel = function(c, voxel, by)
		c:log("kept its cell from", by)
	end,
}
