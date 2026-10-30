-- A part ([KIT] stage 4d): plain static geometry off the voxels' grid, a
-- beam, a ramp, a table top. A box or a wedge (its slope rising along +z
-- to its full height at its back), its size in cells (fractions too),
-- turned by its rotation (degrees round x, y and z), its colour and
-- material, solid (the players' bodies meet it) or not. No behaviour.
-- In the editor Shift and the arrows move it a quarter of a cell
return {
	version = 1,
	params = {
		shape = {type = "string", default = "box", choices = {"box", "wedge"}},
		size = {type = "position", default = {1, 1, 1}},
		rotation = {type = "position", default = {0, 0, 0}},
		color = {type = "string", default = "#b0b0b0"},
		material = {type = "string", default = "plain",
			choices = {"plain", "metal", "glass", "glow"}},
		collision = {type = "bool", default = true},
	},
	look = {shape = "param:shape", size = "param:size",
		rotation = "param:rotation", color = "param:color",
		material = "param:material", solid = "param:collision"},
}
