-- Brimstone Speedway's checkpoint: an unseen gate across the track (its
-- zone: `size` cells from its own on, along the world's axes) a car
-- passes, "passed" with its order (1, 2...: linked to the race's
-- checkpoint, which takes them in order). "respawn" (the race's, by a
-- wrecked player) with its order puts that player back on the road at its
-- middle, facing `heading` (degrees, kit's yaw: 0 +z, 90 +x).
local function middle(c)
	local s, p = c.params.size, c.pos
	return {math.floor(p[1]) + (s[1] - 1) / 2, math.floor(p[2]) + 0.5,
		math.floor(p[3]) + (s[3] - 1) / 2}
end

return {
	version = 1,
	zone = "size",
	gizmo = {shape = "sphere", size = 0.3, color = "#ff5030"},
	about = {
		group = "Game",
		what = "A checkpoint across Brimstone Speedway's track: passed in order, they open the lap.",
		inputs = {
			respawn = "Puts the player back here if the value is its order. Value: a checkpoint's order.",
		},
		outputs = {
			passed = "A car passed it. Value: its order.",
		},
		params = {
			order = "Its place in the lap: 1 first, then 2...",
			size = "Its zone across the track, cells from its own along the world's axes.",
			heading = "The way a respawned car faces, degrees (0 +z, 90 +x).",
		},
	},
	params = {
		order = {type = "number", default = 1, min = 1, max = 64},
		size = {type = "position", default = {14, 2, 2}},
		heading = {type = "number", default = 0, min = -360, max = 360},
	},
	inputs = {respawn = "number"},
	outputs = {passed = "number"},
	on_enter = function(c, by)
		c:emit("passed", c.params.order, by)
	end,
	on_input = function(c, input, value, by)
		if input == "respawn" and tonumber(value) == c.params.order then
			c:teleport(middle(c), {yaw = c.params.heading})
		end
	end,
}
