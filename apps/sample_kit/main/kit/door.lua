-- A door: its voxel shows whether it is open; "toggle" opens or closes it
return {
	version = 1,
	owns_voxel = true,
	params = {
		closed = {type = "voxel", default = "stone"},
		open = {type = "voxel", default = "air"},
	},
	state = {open = {default = false, shared = true}},
	inputs = {"toggle"},
	outputs = {"opened", "closed"},
	on_start = function(c)
		c:set_voxel(c.params.closed)
	end,
	on_input = function(c, input, value, by)
		c.state.open = not c.state.open
		c:set_voxel(c.state.open and c.params.open or c.params.closed)
		c:log(c.state.open and "opened" or "closed", "by", by)
		c:emit(c.state.open and "opened" or "closed")
	end,
	-- Someone else's write to the door's voxel: the door keeps it
	on_voxel = function(c, voxel, by)
		c:log("kept its voxel from", by, "who wrote", voxel)
	end,
}
