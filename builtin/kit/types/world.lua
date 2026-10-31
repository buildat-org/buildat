-- The World ([KIT] stage 4e): what the app's world is made of, game-wide,
-- on the app root (an app hosting Kit with a world scene; Kit generates
-- it natively, builtin/kit/world.h). The first one counts; with none the
-- parameters' defaults (and the app's) are the World.
--   generator  empty, flat (a ground at level), noise (hills: level +-
--              height, a feature every spread cells), valleys (Luanti's
--              valleys mapgen's surface, without rivers; native servers)
--   seed       noise and valleys
--   biome      the material set's biome: which voxels the ground is
--              (Kit's set: grassland, desert, rock -- rock has no water)
--   sea_level  water up to it over lower ground
--   size       finite (width x depth cells round the origin, baked:
--              every section stored) or infinite (generated where players
--              go; only edited sections saved, the generator pinned)
--   border     a finite map's edge: void, wall, water
--   surface    voxels, or heightmap (builtin/heightmap; finite only, its
--              map from the origin, a side a multiple of 64): either
--              replaces the other at once, the voxel sections nobody
--              edited forgotten (the edited ones kept in the save)
--   caves      ([KIT] stage 4f) tunnels and caverns under the ground (not
--              under a heightmap), their floors and walls the biome's
--              cave roles
--   decorations  the biome's decorations scattered by the seed: trees,
--              bushes, flowers, grass, a log with mushrooms, boulders under
--              water, mushrooms and moss in caves (on a heightmap: those
--              bigger than a cell, as voxel objects)
-- Changing them while editing generates again every section nobody
-- edited; edited ones stay, a warning names the seams.
-- Voxel objects ([VOXEL_OBJECTS]) on a heightmap are their own entities
-- once they exist, not a World parameter.
return {
	version = 2,
	root = true,
	world = true,
	params = {
		generator = {type = "string", default = "flat",
			choices = {"empty", "flat", "noise", "valleys"}},
		seed = {type = "number", default = 0, min = 0, max = 4294967295},
		biome = {type = "string", default = "grassland"},
		level = {type = "number", default = 0, min = -100, max = 200},
		height = {type = "number", default = 12, min = 0, max = 100},
		spread = {type = "number", default = 48, min = 4, max = 2000},
		sea_level = {type = "number", default = 0, min = -100, max = 200},
		size = {type = "string", default = "finite",
			choices = {"finite", "infinite"}},
		width = {type = "number", default = 64, min = 16, max = 2048},
		depth = {type = "number", default = 64, min = 16, max = 2048},
		border = {type = "string", default = "void",
			choices = {"void", "wall", "water"}},
		surface = {type = "string", default = "voxels",
			choices = {"voxels", "heightmap"}},
		caves = {type = "bool", default = false},
		decorations = {type = "bool", default = true},
	},
}
