-- Player state between plays: what players keep from one round to the
-- next (Play to Stop to Play), game-wide, on the app root; without it
-- nothing is kept. keep_inventory: what a player had at Stop is theirs
-- again at Play (put aside meanwhile); keep_position: Play leaves the
-- players where they are (no spawn places them); keep_builds ("Always
-- keep builds" in the tools): what players build while playing goes into
-- the start as they build it, and Stop discards only the game's changes.
-- [KIT_INVENTORY_PLAY] carry: the state keys of the player's components
-- whose numbers carry (money, XP, score: "score money"), kept over Stop
-- and Play and into and out of an arena's rounds.
-- The first one counts.
return {
	version = 1,
	about = {
		group = "Players",
		what = "What players keep from one round to the next.",
	},
	root = true,
	between_plays = true,
	params = {
		keep_inventory = {type = "bool", default = false},
		keep_position = {type = "bool", default = false},
		keep_builds = {type = "bool", default = false},
		carry = {type = "string", default = ""},
	},
}
