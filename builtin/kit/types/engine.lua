-- An engine ([KIT_AIRSHIPS] stage 3): a component on an entity under a ship (a
-- free object with kit/airship). Kit sums the ship's parts for its movement:
-- each engine's `thrust` adds to the airship's own, its `lift` to its climb
-- (kit.cpp's ship_parts(), read by airship.lua as p.parts). Bought at a
-- kit/shop with `mount` and put on a face of the buyer's ship; it drops when
-- the voxel it is on goes. No behaviour of its own
return {
	version = 1,
	component = true,
	about = {
		what = "An engine on a ship: adds thrust and lift to its airship movement.",
	},
	params = {
		thrust = {cat = "physics", type = "number", default = 3, min = 0, max = 100},
		lift = {cat = "physics", type = "number", default = 0, min = 0, max = 50},
	},
}
