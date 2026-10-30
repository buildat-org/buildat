-- A lever: on or off, flipped by a player's use or a link's "toggle" (or
-- set by "on"/"off"); it signals "on" or "off" as it flips. Its cell
-- shows which
local function flip(c, on, by)
	if on == c.state.on then
		return
	end
	c.state.on = on
	c:set_voxel(on and c.params.on_voxel or c.params.off_voxel)
	c:log("flipped", on and "on" or "off", "by", by)
	c:emit(on and "on" or "off")
end

return {
	version = 1,
	usable = true,
	owns_voxel = true,
	params = {
		off_voxel = {type = "voxel", default = "lever_off"},
		on_voxel = {type = "voxel", default = "lever_on"},
	},
	state = {on = {default = false, shared = true}},
	inputs = {"toggle", "on", "off"},
	outputs = {"on", "off"},
	on_start = function(c)
		c:set_voxel(c.state.on and c.params.on_voxel or c.params.off_voxel)
	end,
	on_use = function(c, by)
		flip(c, not c.state.on, by)
	end,
	on_input = function(c, input, value, by)
		flip(c, input == "on" or (input == "toggle" and not c.state.on), by)
	end,
	on_voxel = function(c, voxel, by)
		c:log("kept its cell from", by)
	end,
}
