-- A gate: a wall of the cells it owns (three wide, three tall) that a
-- link opens and shuts -- "open", "close", "toggle" -- and no player can
-- open by hand. What a button, a lever or a zone guards
return {
	version = 1,
	owns_voxel = true,
	volume = "size",
	params = {
		size = {type = "position", default = {3, 3, 1}},
		closed = {type = "voxel", default = ""}, -- "": the app fills it, or you
		open = {type = "voxel", default = "air"},
	},
	state = {open = {default = false, shared = true}},
	inputs = {"open", "close", "toggle"},
	outputs = {"opened", "closed"},
	on_start = function(c)
		c:set_voxel(c.state.open and c.params.open or c.params.closed)
	end,
	on_input = function(c, input, value, by)
		local open = input == "open" or (input == "toggle" and not c.state.open)
		if open == c.state.open then
			return
		end
		c.state.open = open
		c:set_voxel(open and c.params.open or c.params.closed)
		c:log(open and "opened" or "shut", "by", by)
		c:emit(open and "opened" or "closed")
	end,
	on_voxel = function(c, voxel, by)
		c:log("kept its cells from", by)
	end,
}
