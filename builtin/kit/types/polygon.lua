-- A polygon ([KIT_PLANE] stage 3): level geometry for the side view (kit/controls'
-- plane), a closed outline of points in its own x and y (concave too, no holes),
-- extruded `depth` along its own z round its place, in its colour and material.
-- The players' bodies meet it where it spans the plane's depth; one at another
-- depth is background or foreground (no collision; kit/controls' side_clip lets
-- the side view show what is in front). With the plane off a body meets its prism
-- while it lies flat to the world's x and y (yaw 0 or 180, any roll): a 2.5D
-- surface. Drawn and edited in the editor's 2D view of a game whose kit/controls
-- camera is side (its Front view): placed from the palette
-- there each click is a point, the first one again or Enter closes it; selected,
-- a point dragged moves it, an edge's middle dragged or clicked adds one there, a
-- right click (a long press) on a point takes it away. At most 512 points within
-- 256 of its place ([KIT_SIDE_SCENERY]: 512 wide, a skyline or a ridge in one
-- piece), no edge crossing another (the server's check_param).
-- [KIT_SIDE_SCENERY] `voxel` (a voxel type, kit/part's picker; "": its colour)
-- wears that type's textures, world-aligned a repeat a cell so pieces side by
-- side tile: its faces the type's bottom where that is not its top (grass: dirt),
-- else its side; the edges facing up the top on their sides and a band of it
-- `edge_depth` cells deep on the faces (0: none). Its colour is then unused (the
-- type's own tint); its material still counts (module.lua's polygon_mesh)
-- [KIT_CLIENT_REACT] (5) `surface` (a short tag) and `friction` (0...10): what a
-- movement's step meets on it (w:circle's, w:segment's and w:move's hit info, on
-- the server's steps and the clients' predictions alike, move.lua): a spike
-- strip's "spikes" a bike's step crashes on by itself, an "ice" floor
-- [KIT_TOP_DOWN] (2) Lying flat (turned pitch 90: its points' x and y the world's x
-- and z, its depth up and down round its place) it is a top-down view's level
-- geometry: its outline upright walls a body meets as a standing one's edges (in
-- kit/controls' plane horizontal where its depth spans the plane's height); drawn
-- and edited in the editor's plan (2D) view. `floor` (with collision off): a floor
-- patch, no wall: a body over its area meets its surface and friction under the
-- feet (w:under, kit/walker's ground), ice, mud or a boost pad
return {
	version = 1,
	about = {
		group = "Building",
		what = "A shape of points in the side view's plane, extruded: level geometry for side-scrolling. Lying flat (pitch 90: its x and y are the world's x and z; depth up), it makes a top-down view's walls, or, with floor on and collision off, a floor patch whose surface and friction a body meets under its feet. points: [[x, y]...] from its place, 3 to 512, within 256 (512 wide), with no crossing edges. voxel: a voxel type's textures, tiled across pieces, with a band of its top texture edge_depth cells deep along the edges that face up. surface (a tag) and friction: what a movement's step meets on it (info.surface, info.friction; \"spikes\" is a hazard the step itself reacts to). E.g. {\"points\": [[-20, -4], [20, -4], [20, 1], [0, 3], [-20, 2]], \"voxel\": \"kit/grass\", \"edge_depth\": 0.25}: a dirt hill edged with grass.",
		params = {
			points = "Its outline's points in its own x and y from its place (3 to 512, no crossing edges).",
			depth = "How far it is extruded along its own z, in metres.",
			color = "Its colour, as #rrggbb (unused with a voxel).",
			material = "Its surface: plain, metal, glass or glow.",
			collision = "Bodies meet it.",
			surface = "A tag a movement's step meets on it, as \"ice\" or \"spikes\".",
			friction = "The friction a movement's step meets on it (1: normal).",
			floor = "Lying flat with collision off: a floor patch whose surface and friction bodies meet underfoot.",
			voxel = "A voxel type whose textures it wears (empty: its colour).",
			edge_depth = "Cells deep of the voxel's top texture along its upward edges (0: none).",
		},
	},
	params = {
		points = {type = "points", default = {{-2, -0.5}, {2, -0.5}, {2, 0.5},
			{-2, 0.5}}},
		depth = {cat = "look", type = "number", default = 1, min = 0.05, max = 64},
		color = {cat = "look", type = "string", default = "#7a8a5a"},
		material = {cat = "look", type = "string", default = "plain",
			choices = {"plain", "metal", "glass", "glow"}},
		collision = {cat = "physics", type = "bool", default = true},
		surface = {cat = "physics", type = "string", default = "polygon"},
		friction = {cat = "physics", type = "number", default = 1, min = 0, max = 10},
		-- [KIT_TOP_DOWN] (2)
		floor = {cat = "physics", type = "bool", default = false},
		-- [KIT_SIDE_SCENERY] (kit/part's)
		voxel = {cat = "look", type = "voxel", default = "",
			choices_from = "voxels"},
		edge_depth = {cat = "look", type = "number", default = 0.25, min = 0,
			max = 4},
	},
	look = {shape = "polygon", points = "param:points", depth = "param:depth",
		color = "param:color", material = "param:material", solid = "param:collision",
		voxel = "param:voxel", edge_depth = "param:edge_depth",
		surface = "param:surface", friction = "param:friction", floor = "param:floor"},
}
