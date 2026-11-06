-- A door: an object one wide and two tall (its size), drawn shut or
-- swung open, and solid while shut. A player opens and shuts it by using
-- it, a link by "open", "close" or "toggle"; it shuts itself after
-- close_after seconds (0: it stays open). mirror: it swings the other way.
-- [KIT_SOUNDS] sound_open and sound_close play at it
local function set(c, open, by)
	if open == c.state.open then
		return
	end
	c.state.open = open
	c:sound(open and c.params.sound_open or c.params.sound_close)
	c:log(open and "opened" or "shut", "by", c:name(by))
	c:emit(open and "opened" or "closed")
	if open and c.params.close_after > 0 then
		c:after(c.params.close_after)
	end
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
		close_after = {type = "number", default = 0, min = 0, max = 3600},
		sound_open = {cat = "look", type = "sound", default = "kit/door"},
		sound_close = {cat = "look", type = "sound", default = "kit/door"},
	},
	look = {shape = "box", extent = "size", depth = 0.2,
		voxel = "param:material", color = "#8a5a30",
		solid = true, state = "open", when = {swing = true,
		mirror = "param:mirror", solid = false}},
	state = {open = {default = false, shared = true}},
	about = {
		what = "A door a player opens and shuts by using it; solid while shut.",
		inputs = {
			open = "Opens it.",
			close = "Shuts it.",
			toggle = "Opens it if shut, else shuts it.",
		},
		outputs = {
			opened = "It opened.",
			closed = "It shut.",
		},
	},
	inputs = {open = "none", close = "none", toggle = "none"},
	outputs = {opened = "none", closed = "none"},
	on_use = function(c, by)
		set(c, not c.state.open, by)
	end,
	on_input = function(c, input, value, by)
		set(c, input == "open" or (input == "toggle" and not c.state.open), by)
	end,
	on_timer = function(c)
		set(c, false, "its timer")
	end,
}
