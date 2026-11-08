-- A radar ([KIT_AIRSHIPS] stage 3): a component on an entity under a ship.
-- Twice a second Kit lists the other ships (free objects with kit/hull) in its
-- scene within `range` m: state `contacts`, a line each, nearest first: its
-- distance, its bearing off the radar's ship's heading and its height above
-- or below. Its client part shows them to a player within 12 m of it (on
-- its deck).
-- simplified: a text list, not a scope; every ship in range, through islands
return {
	version = 1,
	component = true,
	about = {
		what = "A radar on a ship: the other ships' bearings and distances on the HUD of those aboard.",
	},
	params = {
		range = {type = "number", default = 150, min = 1, max = 1000},
	},
	state = {contacts = {default = "", shared = true}},
}
