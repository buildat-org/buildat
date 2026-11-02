-- A mob spawner ([KIT] stage 6a, skeldat's own): used, or on "spawn",
-- `count` of skeldat's mobs of `kind` on the ground at it; with
-- `at_start` also as it starts (placed, restarted). The mobs are
-- skeldat's, in its persistent world as any other
local function spawn(c, by)
	c:log("spawns", c.params.count, c.params.kind, "for", c:name(by))
	c:app("mob", {kind = c.params.kind, count = c.params.count})
end

return {
	version = 1,
	usable = true,
	look = {shape = "box", size = 0.4, color = "#d8d0b8"},
	params = {
		kind = {type = "string", default = "skeleton",
			choices = {"skeleton", "boar", "cave_skeleton"}},
		count = {type = "number", default = 1, min = 1, max = 8},
		at_start = {type = "bool", default = false},
	},
	inputs = {spawn = "none"},
	on_start = function(c)
		if c.params.at_start then
			spawn(c, "app")
		end
	end,
	on_use = spawn,
	on_input = function(c, input, value, by)
		spawn(c, by)
	end,
}
