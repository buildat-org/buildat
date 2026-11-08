-- The World ([KIT] stage 4e): what the app's world is made of, game-wide,
-- on the app root (an app hosting Kit with a world scene; Kit generates
-- it natively, builtin/kit/terrain.h). The first one counts; with none the
-- parameters' defaults (and the app's) are the World.
--   generator  empty, flat (a ground at level), noise (hills: level +-
--              height, a feature every spread cells), valleys (Luanti's
--              valleys mapgen's surface, without rivers; native servers)
--   seed       noise and valleys
--   materials  ([KIT_MATERIAL_SETS]) the material set: "" the app's
--              (Workbench's: Kit's own), or an installed set package's
--              (where the app allows it); the inspector's dropdown of them.
--              Changing it generates again what the generator wrote, the
--              voxels placed keep theirs; refused, the role named, when the
--              generator needs a role the set's biome lacks. A package's
--              upgrade is the same change
--   biome      the material set's biome: which voxels the ground is
--              (Kit's set: grassland, desert, rock -- rock has no water);
--              the inspector's dropdown of them (choices_from)
--   sea_level  water up to it over lower ground
--   soil_depth ([KIT_SOIL_DEPTH]) the filler's layers under the top
--              (grassland's dirt under the grass): -1 the biome's
--              (grassland 3), 0 stone right under the top.
--              simplified: the generator's; the terrain brushes lay the
--              biome's depth (a Brush taking it too when one wants it)
--   size       finite (width x depth cells round the origin, baked:
--              every section stored) or infinite (generated where players
--              go; only edited sections saved, the generator pinned)
--   border     a finite map's edge: void, wall, water
--   surface    voxels, or heightmap (builtin/heightmap; finite only, on
--              the same area as the voxels, a side a multiple of 64): either
--              replaces the other at once, the voxel sections nobody
--              edited forgotten (the edited ones kept in the save)
--   caves      ([KIT] stage 4f) tunnels and caverns under the ground (not
--              under a heightmap), their floors and walls the biome's
--              cave roles
--   decorations  the biome's decorations scattered by the seed: trees,
--              bushes, flowers, grass, a log with mushrooms, boulders under
--              water, mushrooms and moss in caves (on a heightmap: those
--              bigger than a cell, as voxel objects)
--   sky_light  ([KIT_VOXEL_FORMAT]) the sky's light in the voxels: a room
--              with no way out to the sky is dark, a cave mouth's light
--              fades inward. Off, nothing computes it (the scene's lights
--              alone, the look before it); not on a heightmap. Changing it
--              generates nothing again
-- Changing them while editing generates again every section nobody
-- edited; edited ones stay, a warning names the seams.
-- Voxel objects ([VOXEL_OBJECTS]) on a heightmap are their own entities
-- once they exist, not a World parameter.
return {
	version = 2,
	about = {
		what = "What the world is generated from: generator, seed, materials, biome.",
	},
	root = true,
	world = true,
	params = {
		generator = {type = "string", default = "flat",
			choices = {"empty", "flat", "noise", "valleys"}},
		seed = {type = "number", default = 0, min = 0, max = 4294967295},
		materials = {cat = "look", type = "string", default = "",
			choices_from = "material_sets"},
		biome = {cat = "look", type = "string", default = "grassland",
			choices_from = "biomes"},
		level = {type = "number", default = 0, min = -100, max = 200},
		height = {type = "number", default = 12, min = 0, max = 100},
		spread = {type = "number", default = 48, min = 4, max = 2000},
		sea_level = {type = "number", default = 0, min = -100, max = 200},
		soil_depth = {cat = "look", type = "number", default = -1, min = -1,
			max = 16},
		size = {type = "string", default = "finite",
			choices = {"finite", "infinite"}},
		width = {type = "number", default = 64, min = 16, max = 2048},
		depth = {type = "number", default = 64, min = 16, max = 2048},
		border = {type = "string", default = "void",
			choices = {"void", "wall", "water"}},
		surface = {type = "string", default = "voxels",
			choices = {"voxels", "heightmap"}},
		caves = {type = "bool", default = false},
		decorations = {cat = "look", type = "bool", default = true},
		sky_light = {cat = "look", type = "bool", default = false},
	},
}
