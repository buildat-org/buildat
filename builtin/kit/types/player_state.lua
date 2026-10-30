-- Player state between plays: what players keep from one round to the
-- next (Play to Stop to Play), game-wide, on the app root; without it
-- nothing is kept. keep_inventory: what a player had at Stop is theirs
-- again at Play (put aside meanwhile); keep_position: Play leaves the
-- players where they are (no spawn places them). The first one counts.
return {
	version = 1,
	root = true,
	between_plays = true,
	params = {
		keep_inventory = {type = "bool", default = false},
		keep_position = {type = "bool", default = false},
	},
}
