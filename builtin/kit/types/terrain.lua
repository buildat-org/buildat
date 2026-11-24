-- The World ([KIT] stage 4e): what the app's world is made of, game-wide,
-- on the app root (an app hosting Kit with a world scene; Kit generates
-- it natively, builtin/kit/terrain.h). The first one counts; with none
-- ([KIT_NO_WORLD]) the scene has no World: surface none (an app may say
-- its defaults are one instead, Host::world_default).
--   generator  empty, flat (a ground at level), noise (hills: level +-
--              height, a feature every spread cells), valleys (Luanti's
--              valleys mapgen's surface, without rivers; native servers),
--              ([KIT_RTS]) underground: solid from the top, for a game
--              played inside the ground. Every cell from level down
--              `height` cells is ground (height is that depth here, not
--              hills), the biome's filler as soil, stone as rock, hard
--              (hard rock) and ore by 3D noise: soil more common near the
--              top, hard rock in walls that make a digger go round, rock
--              the bulk, pockets of ore 2 to 4 cells across (about one a
--              block of 8x8x8) in soil and rock; under it a floor of hard
--              (every cell down: a game's dig rule keeps diggers off it);
--              air over level. With caves, caverns: layers of wide spaces 3
--              to 6 cells high with flat floors (cave_floor), long winding
--              tunnels and chambers. Point-symmetric round the map's middle
--              ((x, z) is (-x - 1, -z - 1)'s; finite maps of even sides):
--              fair for two sides, kit/symmetry for more. Kit's biome
--              "underground" (dirt, stone, kit/hard_rock, kit/ore, gravel
--              floors and top: a kit/terrain_region's flat room floor)
--   seed       noise, valleys and underground
--   flatten    ([KIT_TERRAIN_FLATTEN]) noise flat at level round the scene's
--              parts on the ground (a look's box within 3 of level), the
--              hills rising 1 to 9 cells past each; off: hills under them too.
--              simplified: the parts as the World generates; one placed or
--              moved later is flattened round at its next generation
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
--              the same area as the voxels, its sides whole chunks of 64,
--              or of the next power of two under 64: a 192x8 map is 8
--              deep), or ([KIT_NO_WORLD]) none: no ground, nothing generated
--              or loaded, the voxel and terrain tools refused (the other
--              parameters then do nothing). Each replaces the other at once,
--              the voxel sections nobody edited forgotten (the edited ones
--              kept in the save)
--   caves      ([KIT] stage 4f) tunnels and caverns under the ground (not
--              under a heightmap), their floors and walls the biome's
--              cave roles (underground: its own caverns, above)
--   decorations  the biome's decorations scattered by the seed: trees,
--              bushes, flowers, grass, a log with mushrooms, mushrooms and
--              moss in caves (on a heightmap: those bigger than a cell, as
--              voxel objects); none under the water ([KIT_SEABED_DECOR]:
--              Kit's set has no "water" decorations, a set's own may)
--   sky_light  ([KIT_VOXEL_FORMAT]) the sky's light in the voxels: a room
--              with no way out to the sky is dark, a cave mouth's light
--              fades inward. Off, nothing computes it (the scene's lights
--              alone, the look before it); not on a heightmap. Changing it
--              generates nothing again
--   dig, place ([KIT_TERRAIN_PLAY_RULES]) who digs and places in play
--              outside every kit/region, on the cells the World covers
--              (a finite map's area, an infinite one's every cell): all,
--              builders (edit rights), none. Past a finite map's edge
--              nobody; a region decides inside its box, kit/game_rules'
--              dig and place still turn building off. Generates nothing
-- Changing them while editing generates again every section nobody
-- edited; edited ones stay, a warning names the seams.
-- Voxel objects ([VOXEL_OBJECTS]) on a heightmap are their own entities
-- once they exist, not a World parameter.
return {
	version = 2,
	about = {
		group = "World",
		keywords = "world ground mapgen",
		what = "What the world is generated from: the generator, seed, materials and biome.",
		params = {
			generator = "empty, flat (ground at level), noise (hills), valleys (Luanti's valleys surface) or underground (solid from level down height cells).",
			seed = "The noise, valleys and underground generators' seed.",
			materials = "The material set the world is made of; none: the app's own.",
			biome = "The material set's biome: which voxels the ground is.",
			level = "The ground's height in cells (underground: its top).",
			height = "How far noise's hills rise and fall from level, in cells (underground: how deep the ground is under level).",
			spread = "Cells between noise's hills.",
			flatten = "Keeps the ground flat at level round the scene's parts on it.",
			sea_level = "Water up to this height over lower ground.",
			soil_depth = "Filler layers under the top (-1: the biome's, 0: stone right under it).",
			size = "finite: width x depth cells round the origin; infinite: made where players go.",
			width = "A finite map's width in cells (x).",
			depth = "A finite map's depth in cells (z).",
			border = "A finite map's edge: void, a wall or water.",
			surface = "voxels, a heightmap (finite only), or none: no ground at all.",
			caves = "Tunnels and caverns under the ground.",
			decorations = "The biome's trees, bushes, flowers and the like scattered by the seed.",
			sky_light = "Sky light in the voxels: closed rooms dark, a cave's light fading inward.",
			dig = "Who digs in play outside every region: all, builders or none.",
			place = "Who places voxels in play outside every region: all, builders or none.",
		},
	},
	root = true,
	-- [KIT_SINGLE] the nearest copy is used: one a holder (the root, a scene)
	single = true,
	world = true,
	params = {
		generator = {type = "string", default = "flat",
			choices = {"empty", "flat", "noise", "valleys", "underground"}},
		seed = {type = "number", default = 0, min = 0, max = 4294967295},
		materials = {cat = "look", type = "string", default = "",
			choices_from = "material_sets"},
		biome = {cat = "look", type = "string", default = "grassland",
			choices_from = "biomes"},
		level = {type = "number", default = 0, min = -100, max = 200},
		height = {type = "number", default = 12, min = 0, max = 100},
		spread = {type = "number", default = 48, min = 4, max = 2000},
		-- [KIT_TERRAIN_FLATTEN]
		flatten = {type = "bool", default = true},
		sea_level = {type = "number", default = 0, min = -100, max = 200},
		soil_depth = {cat = "look", type = "number", default = -1, min = -1,
			max = 16},
		size = {type = "string", default = "finite",
			choices = {"finite", "infinite"}},
		width = {type = "number", default = 64, min = 16, max = 2048},
		depth = {type = "number", default = 64, min = 4, max = 2048},
		border = {type = "string", default = "void",
			choices = {"void", "wall", "water"}},
		surface = {type = "string", default = "voxels",
			choices = {"voxels", "heightmap", "none"}},
		caves = {type = "bool", default = false},
		decorations = {cat = "look", type = "bool", default = true},
		sky_light = {cat = "look", type = "bool", default = false},
		dig = {type = "string", default = "all",
			choices = {"all", "builders", "none"}},
		place = {type = "string", default = "all",
			choices = {"all", "builders", "none"}},
	},
}
