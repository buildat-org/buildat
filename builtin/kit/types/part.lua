-- A part ([KIT] stage 4d): plain static geometry off the voxels' grid, a
-- beam, a ramp, a table top. A box, a wedge (its slope rising along +z
-- to its full height at its back) or ([KIT_CTF]) a sphere (a ball its
-- size's sides fit), its size in cells (fractions too),
-- turned by its rotation (degrees round x, y and z), its colour and
-- material, solid (the players' bodies meet it) or not. No behaviour.
-- In the editor Shift and the arrows move it a quarter of a cell
return {
	version = 1,
	about = {
		group = "Building",
		what = "Plain geometry off the voxel grid: a box, a wedge or a sphere.",
	},
	params = {
		shape = {cat = "look", type = "string", default = "box",
			choices = {"box", "wedge", "sphere"}},
		size = {cat = "look", type = "position", default = {1, 1, 1}},
		rotation = {cat = "look", type = "position", default = {0, 0, 0}},
		color = {cat = "look", type = "string", default = "#b0b0b0"},
		material = {cat = "look", type = "string", default = "plain",
			choices = {"plain", "metal", "glass", "glow"}},
		collision = {cat = "physics", type = "bool", default = true},
		-- [KIT_LOOK_MATERIAL] A voxel material it wears ("": its colour; a
		-- box's or a wedge's, its slope the material's top). Its `material`
		-- is its surface, from before
		voxel = {cat = "look", type = "voxel", default = "",
			choices_from = "voxels"},
	},
	-- [KIT_SYMMETRY] rotation is its own turn
	space = {rotation = "rotation"},
	look = {shape = "param:shape", size = "param:size",
		rotation = "param:rotation", color = "param:color",
		material = "param:material", voxel = "param:voxel", solid = "param:collision"},
}
