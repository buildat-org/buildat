-- A key door: a door (an object one wide and two tall) that a player
-- opens only with `key` in their inventory, which it takes with `take`;
-- anyone shuts it, and a link by "close". It signals "refused" to one
-- without the key
local function shut(c, by)
	if not c.state.open then
		return
	end
	c.state.open = false
	c:log("shut by", c:name(by))
	c:emit("closed")
end

return {
	version = 2,
	usable = true,
	params = {
		size = {cat = "look", type = "position", default = {1, 2, 1}},
		-- [KIT_DOOR_MIRROR] It swings the other way: to its back (-z) rather
		-- than its front, round the same hinge. Two doors, one turned half
		-- round and mirrored, are a double door
		mirror = {type = "bool", default = false},
		-- [KIT_LOOK_MATERIAL] A voxel material it wears ("": its own colour)
		material = {cat = "look", type = "voxel", default = "",
			choices_from = "voxels"},
		key = {type = "string", default = "key"},
		take = {type = "bool", default = false},
	},
	look = {shape = "box", extent = "size", depth = 0.2,
		voxel = "param:material", color = "#c8a040",
		solid = true, state = "open", when = {swing = true,
		mirror = "param:mirror", solid = false}},
	state = {open = {default = false, shared = true}},
	inputs = {close = "none"},
	outputs = {opened = "none", closed = "none", refused = "none"},
	on_use = function(c, by)
		if c.state.open then
			return shut(c, by)
		end
		if not c:has(c.params.key) then
			c:log("locked to", c:name(by), "who has no", c.params.key)
			c:emit("refused")
			return
		end
		if c.params.take and not c:take(c.params.key) then
			return
		end
		c.state.open = true
		c:log("opened by", c:name(by), c.params.take and "taking their" or
				"with their", c.params.key)
		c:emit("opened")
	end,
	on_input = function(c, input, value, by)
		shut(c, by)
	end,
}
