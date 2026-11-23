-- Brimstone Stunts' birds (4z38): a flock on the ground round its entity,
-- drawn by its client part (stunt_birds.client.lua: nodes of its own under
-- the entity's), which scatters it when this player's car comes near: up and
-- round in a loop, wings flapping, and down again where they were. Nothing
-- on the server: each client its own birds, from its own car.
return {
	version = 1,
	about = {
		group = "Game",
		what = "A flock of birds on the ground that scatters when a car comes near (drawn on each client).",
		params = {
			count = "How many birds.",
			spread = "How far from its place they sit, in metres.",
			scare = "How near a car scatters them, in metres.",
			color = "Their colour, as #rrggbb.",
		},
	},
	client_params = {"count", "spread", "scare", "color"},
	params = {
		count = {cat = "look", type = "number", default = 28, min = 1, max = 64},
		spread = {cat = "look", type = "number", default = 5, min = 0.5, max = 30},
		scare = {cat = "look", type = "number", default = 14, min = 1, max = 60},
		color = {cat = "look", type = "string", default = "#26262c"},
	},
}
