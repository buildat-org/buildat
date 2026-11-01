-- A sign ([KIT] stage 4l): text on a board, written by the builders (its
-- `text`, a parameter: edited in edit mode only). In the text, {value} is
-- the last signal's value on "value" (nothing until one comes), and | a
-- new line. Flat on the board's front (-z, the side it faces) or facing
-- the camera; its letters `size` cells high, in `color`, on a board of
-- `background` ("none": no board, the letters alone)
local function shown(c)
	local v = c.state.value
	local t = c.params.text:gsub("{value}", function()
		return tostring(v)
	end)
	return (t:gsub("|", "\n"))
end

local function show(c)
	c.state.shown = shown(c)
end

return {
	version = 1,
	look = {shape = "box", size = "param:board", color = "param:background",
		voxel = "param:material",
		text = "shown", text_size = "param:size", text_color = "param:color",
		text_facing = "param:facing", solid = "param:solid"},
	params = {
		text = {type = "string", default = "Welcome!"},
		facing = {type = "string", default = "flat",
			choices = {"flat", "camera"}},
		size = {type = "number", default = 0.25, min = 0.05, max = 4},
		color = {type = "string", default = "#ffffff"},
		background = {type = "string", default = "#304050"},
		-- [KIT_LOOK_MATERIAL] A voxel material it wears ("": its background's colour; a background
		-- of "none" no board still)
		material = {type = "voxel", default = "", choices_from = "voxels"},
		board = {type = "position", default = {1.5, 0.75, 0.1}},
		solid = {type = "bool", default = true},
	},
	state = {
		value = {default = ""},
		shown = {default = "", shared = true},
	},
	inputs = {value = "any", clear = "none"},
	on_start = function(c)
		show(c)
	end,
	on_params = function(c)
		show(c)
	end,
	on_input = function(c, input, value, by)
		if input == "clear" or value == nil then
			c.state.value = ""
		else
			c.state.value = value
		end
		show(c)
		c:log("shows \"" .. c.state.shown .. "\"", by and ("by " .. c:name(by)) or "")
	end,
}
