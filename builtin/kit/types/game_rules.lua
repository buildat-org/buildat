-- The game's rules ([KIT_TOOLS_1], stage 7c) on the app root: peaceful
-- (players take no damage: Kit's hits on them refused). A region's pvp
-- and damage, and a team's friendly_fire, are the others Kit's hits ask.
-- Stage 8's scene override goes beside it
return {
	version = 1,
	root = true,
	params = {peaceful = {type = "bool", default = false}},
}
