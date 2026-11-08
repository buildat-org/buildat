-- [KIT_AIRSHIPS_2] A world region: the World's mapgen applied to one piece
-- of the world, a box of cells (its own and `size` on) or, `shape` sphere,
-- the ball inscribed in that box (equal sides: a sphere of that diameter).
-- Put in the air it is a floating island; in the ground it remakes that
-- piece. Its own generator (flat, noise, valleys), seed, biome (the World's
-- material set's) and soil depth; `level` is the ground's top in cells over
-- the box's bottom (-1: its middle), `height` and `spread` the noise's.
-- The voxels are the World's own (built on, dug, the terrain tool's), Kit
-- writes them as it is placed or changed while editing (one undo with the
-- edit; kit.cpp's regions_sync()): its cells (air over its ground too),
-- and a change takes back the cells still as it made them (its old ground
-- over the World's own generated ground there again). A heightmap's
-- World has its regions in its voxels over the map. With kit/symmetry on,
-- what it writes in the authored slice is copied to the others (a copy of
-- it writes nothing itself).
-- simplified: no water or caves in a region; 128 cells a side at most; a
-- cell a builder changed inside it is written over when the region's
-- parameters or place change, and its "Regenerate" (the edited sections)
-- drops it like any edit
return {
	version = 1,
	world_region = "size",
	params = {
		shape = {type = "string", default = "box", choices = {"box", "sphere"}},
		size = {type = "position", default = {16, 8, 16}},
		generator = {type = "string", default = "noise",
			choices = {"flat", "noise", "valleys"}},
		seed = {type = "number", default = 0, min = 0, max = 4294967295},
		biome = {cat = "look", type = "string", default = "grassland",
			choices_from = "biomes"},
		level = {type = "number", default = -1, min = -1, max = 128},
		height = {type = "number", default = 2, min = 0, max = 64},
		spread = {type = "number", default = 12, min = 4, max = 2000},
		soil_depth = {cat = "look", type = "number", default = -1, min = -1,
			max = 16},
		decorations = {cat = "look", type = "bool", default = true},
	},
	gizmo = {shape = "box", size = 0.3, color = "#50c050"},
	about = {
		what = "Generates the World's ground in a box or a ball of cells: in the air, a floating island.",
	},
}
