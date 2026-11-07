-- A seat ([KIT_COMPONENTS]): a use of the entity it is on takes the player's controls
-- for that entity's movement (kit/car), F or the touch bar's Exit leaves it. One holder.
-- [KIT_VEHICLE_MOVEMENTS] On the moved entity or on a child of it (a deck's seat, a
-- turret's): the nearest movement on it or above it is what it drives.
return {
	version = 1,
	about = {
		what = "A seat: a player who uses this entity drives its movement.",
	},
	component = true,
	usable = true,
	seat = true,
	params = {},
}
