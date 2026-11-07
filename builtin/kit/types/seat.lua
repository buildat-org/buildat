-- A seat ([KIT_COMPONENTS]): a use of the entity it is on takes the player's controls
-- for that entity's movement (kit/car), F or the touch bar's Exit leaves it. One holder.
-- simplified: on the moved entity itself, with no place of its own; a seat as a child
-- entity on a deck is stage 4r6's.
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
