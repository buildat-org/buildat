-- A mover ([KIT] stage 4l): a box that moves by `offset` (cells, turned
-- with the entity) over `time` seconds, and back -- a piston, a sliding
-- wall, a lift's platform. "go" moves it out, "back" home, "toggle" the
-- other way; it signals "moving" (true: out) as it starts and "arrived"
-- (true: out) when it is there. Its state "out" draws it: the clients
-- slide it (the look's when.offset over when.slide).
-- simplified: the players meet its box where it is going at once, not
-- along the way, and a player on it is not carried (with 4i: a voxel box)
local function move(c, out, by)
	if c.state.out == out then
		return
	end
	c.state.out = out
	c:log(out and "going out" or "going back", by and ("by " .. c:name(by)) or "")
	c:emit("moving", out)
	c:after(c.params.time, "arrive")
end

return {
	version = 1,
	look = {shape = "box", size = "param:size", color = "param:color",
		voxel = "param:material", solid = "param:solid", state = "out",
		when = {offset = "param:offset", slide = "param:time"}},
	params = {
		offset = {type = "position", default = {0, 2, 0}},
		time = {type = "number", default = 1, min = 0, max = 600},
		size = {type = "position", default = {1, 0.25, 1}},
		color = {type = "string", default = "#9090a0"},
		-- [KIT_LOOK_MATERIAL] A voxel material it wears ("": its own colour)
		material = {type = "voxel", default = "", choices_from = "voxels"},
		solid = {type = "bool", default = true},
		start_out = {type = "bool", default = false},
	},
	state = {
		out = {default = false, shared = true},
	},
	inputs = {go = "none", back = "none", toggle = "none"},
	outputs = {moving = "bool", arrived = "bool"},
	on_start = function(c)
		c.state.out = c.params.start_out
	end,
	on_input = function(c, input, value, by)
		if input == "go" then
			move(c, true, by)
		elseif input == "back" then
			move(c, false, by)
		else
			move(c, not c.state.out, by)
		end
	end,
	on_timer = function(c, name)
		if name == "arrive" then
			c:log("arrived", c.state.out and "out" or "back")
			c:emit("arrived", c.state.out)
		end
	end,
}
