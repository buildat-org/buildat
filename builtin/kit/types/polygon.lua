-- A polygon ([KIT_PLANE] stage 3): level geometry for the side view (kit/controls'
-- plane), a closed outline of points in its own x and y (concave too, no holes),
-- extruded `depth` along its own z round its place, in its colour and material.
-- The players' bodies meet it where it spans the plane's depth; one at another
-- depth is background or foreground (no collision; kit/controls' side_clip lets
-- the side view show what is in front). With the plane off a body meets its prism
-- while it lies flat to the world's x and y (yaw 0 or 180, any roll): a 2.5D
-- surface. Drawn and edited in the editor's Front view: placed from the palette
-- there each click is a point, the first one again or Enter closes it; selected,
-- a point dragged moves it, an edge's middle dragged or clicked adds one there, a
-- right click (a long press) on a point takes it away. At most 128 points within
-- 32 of its place, no edge crossing another (the server's check_param)
return {
	version = 1,
	about = {
		group = "Building",
		what = "A shape of points in the side view's plane, extruded: level geometry for side-scrolling. points: [[x, y]...] from its place, 3 to 128, its edges not crossing.",
	},
	params = {
		points = {type = "points", default = {{-2, -0.5}, {2, -0.5}, {2, 0.5},
			{-2, 0.5}}},
		depth = {cat = "look", type = "number", default = 1, min = 0.05, max = 64},
		color = {cat = "look", type = "string", default = "#7a8a5a"},
		material = {cat = "look", type = "string", default = "plain",
			choices = {"plain", "metal", "glass", "glow"}},
		collision = {cat = "physics", type = "bool", default = true},
	},
	look = {shape = "polygon", points = "param:points", depth = "param:depth",
		color = "param:color", material = "param:material", solid = "param:collision"},
}
