-- A path for bots ([KIT_BOT_DRIVE], kit_plan 4z37i (4)): a line through its
-- `points` (its frame's x and z, at its height; dragged in the plan view),
-- the last joined to the first. A kit/bot with `drive` drives the players'
-- movement (a car) along it, in the order of its points: a race's racing
-- line (Brimstone Speedway's local/brim_yard makes one).
-- simplified: a loop only; the points a polygon's (3 to 128, its edges not
-- crossing), so a figure eight or an open route is no path yet
return {
	version = 1,
	gizmo = {shape = "sphere", size = 0.3, color = "#40c0ff"},
	about = {
		group = "Game",
		what = "A line for bots to drive along, such as a race's racing line: a loop through its points in order.",
		keywords = "racing line route waypoints bot",
	},
	params = {
		points = {type = "points", level = true, default = {{-8, -8}, {8, -8},
			{8, 8}, {-8, 8}}},
	},
}
