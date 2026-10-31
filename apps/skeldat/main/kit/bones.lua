-- Bones ([KIT] stage 6a, skeldat's own): used, or on "set", the voxels
-- that hold bones within `size` of it get `value` bones (0 clears them,
-- 8 and over is flooded), and with `at_start` also at each round's start.
-- The bones then grow or burn back as skeldat's do
local function set(c, by)
	c:log("bones", c.params.value, "within", c.params.size, "for", c:name(by))
	c:app("bones", {value = c.params.value, size = c.params.size})
end

return {
	version = 1,
	usable = true,
	look = {shape = "sphere", size = 0.35, color = "#f0ece0"},
	params = {
		value = {type = "number", default = 8, min = 0, max = 15},
		size = {type = "number", default = 2, min = 0, max = 4},
		at_start = {type = "bool", default = false},
	},
	inputs = {set = "none"},
	on_start = function(c)
		if c.params.at_start then
			set(c, "app")
		end
	end,
	on_use = set,
	on_input = function(c, input, value, by)
		set(c, by)
	end,
}
