-- The game's rules ([KIT_TOOLS_1], stage 7c) on the app root: peaceful
-- (players take no damage: Kit's hits on them refused). A region's pvp
-- and damage, and a team's friendly_fire, are the others Kit's hits ask.
-- dig_by_tools ([KIT_DEFAULT_GROUPS]): digging by a voxel's material group
-- and level (dig times by the held item's speed, a drop only at its level
-- or above); off, every voxel digs at once and drops nothing.
-- Stage 8's scene override goes beside it
return {
	version = 1,
	root = true,
	params = {peaceful = {type = "bool", default = false},
		dig_by_tools = {type = "bool", default = false}},
}
