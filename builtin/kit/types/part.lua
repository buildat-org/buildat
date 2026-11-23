-- A part ([KIT] stage 4d): plain static geometry off the voxels' grid, a
-- beam, a ramp, a table top. A box, a wedge (its slope rising along +z
-- to its full height at its back) or ([KIT_CTF]) a sphere (a ball its
-- size's sides fit), its size in cells (fractions too),
-- turned by its rotation (degrees round x, y and z), its colour and
-- material, solid (the players' bodies meet it) or not. No behaviour.
-- In the editor Shift and the arrows move it a quarter of a cell
-- [KIT_3D_GAINS_1] (4z38) `surface` (a short tag) and `friction` (0...10) of its
-- solid, as kit/polygon's: what a movement's step meets on it (w:down's, w:under's,
-- w:circle's and the sweeps' hit info, move.lua's M.look_box), a boost pad or a
-- hazard part; the defaults, "object" and 1, are what every part was before
return {
	version = 1,
	about = {
		group = "Building",
		what = "Plain geometry off the voxel grid: a box, a wedge or a sphere.",
		params = {
			shape = "A box, a wedge (rising along +z to its back) or a sphere.",
			size = "Its width, height and depth in cells (fractions too).",
			rotation = "Its turn, in degrees round x, y and z.",
			color = "Its colour, as #rrggbb.",
			material = "Its surface: plain, metal, glass or glow.",
			collision = "Players' bodies meet it.",
			voxel = "A voxel material it wears (empty: its colour).",
			surface = "A tag a movement's step meets on its solid, as \"boost\" or \"oil\".",
			friction = "The friction a movement's step meets on it (1: normal).",
		},
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
		surface = {cat = "physics", type = "string", default = "object"},
		friction = {cat = "physics", type = "number", default = 1, min = 0, max = 10},
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
		material = "param:material", voxel = "param:voxel", solid = "param:collision",
		surface = "param:surface", friction = "param:friction"},
}
