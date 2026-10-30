-- A key door: a door (the cells it owns, one wide and two tall) that a
-- player opens only with `key` in their inventory, which it takes with
-- `take`; anyone shuts it, and a link by "close". It signals "refused" to
-- one without the key
local function shut(c, by)
	if not c.state.open then
		return
	end
	c.state.open = false
	c:set_voxel(c.params.closed)
	c:log("shut by", by)
	c:emit("closed")
end

return {
	version = 1,
	usable = true,
	owns_voxel = true,
	volume = "size",
	params = {
		size = {type = "position", default = {1, 2, 1}},
		closed = {type = "voxel", default = ""}, -- "": the app fills it, or you
		open = {type = "voxel", default = "air"},
		key = {type = "string", default = "key"},
		take = {type = "bool", default = false},
	},
	state = {open = {default = false, shared = true}},
	inputs = {"close"},
	outputs = {"opened", "closed", "refused"},
	on_start = function(c)
		c:set_voxel(c.state.open and c.params.open or c.params.closed)
	end,
	on_use = function(c, by)
		if c.state.open then
			return shut(c, by)
		end
		if not c:has(c.params.key) then
			c:log("locked to", by, "who has no", c.params.key)
			c:emit("refused")
			return
		end
		if c.params.take and not c:take(c.params.key) then
			return
		end
		c.state.open = true
		c:set_voxel(c.params.open)
		c:log("opened by", by, c.params.take and "taking their" or
				"with their", c.params.key)
		c:emit("opened")
	end,
	on_input = function(c, input, value, by)
		shut(c, by)
	end,
	on_voxel = function(c, voxel, by)
		c:log("kept its cells from", by)
	end,
}
