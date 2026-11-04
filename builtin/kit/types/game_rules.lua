-- The game's rules ([KIT_TOOLS_1], stage 7c) on the app root: peaceful
-- (players take no damage: Kit's hits on them refused). A region's pvp
-- and damage, and a team's friendly_fire, are the others Kit's hits ask.
-- Without one on the root, Kit plays by these defaults.
-- [KIT_INVENTORY_PLAY] **Building**: "inventory" (a dig takes its time by
-- the voxel's material group and the held item, and drops the voxel into
-- the inventory at the item's level or above; a place puts down one of
-- the held slot's voxel, taken from it) or "creative" (the palette, every
-- voxel at once and free, nothing dropped: version 1's dig_by_tools off).
-- dig and place: off, no player digs or places in play (a region's rules
-- confine them further where they are on); placed_only: a player digs
-- only what players placed in this round (the round's marks: in a
-- persistent world, or with "Always keep builds", nothing counts).
-- **The inventory**: `slots` its size (0: unlimited, counts only),
-- `hotbar` its first slots on the screen (0: none), `stack` the stack
-- size of an item whose type names none, `full` what an add past the room
-- does ("drop": the rest a pickup where the player is; "refuse"),
-- `drop_items` (the drop key and a stack let go out of the screen),
-- `screen` (the inventory screen, its key E). `on_death`: "keep", "drop"
-- (each stack a pickup where they died) or "lose".
-- [KIT_HUD] show_health: the health bar on each player's screen.
-- [KIT_CTF] hand_level: the highest material level a hand digs (a dig at
-- a hand's speed: nothing held, or an item with no dig speed for the
-- voxel's group); one above it is refused. 15 (the default): any
-- Stage 8's scene override goes beside it
return {
	version = 2,
	root = true,
	params = {
		peaceful = {type = "bool", default = false},
		building = {type = "string", default = "inventory",
			choices = {"inventory", "creative"}},
		dig = {type = "bool", default = true},
		place = {type = "bool", default = true},
		placed_only = {type = "bool", default = false},
		slots = {type = "number", default = 36, min = 0, max = 100},
		hotbar = {type = "number", default = 9, min = 0, max = 10},
		stack = {type = "number", default = 99, min = 1, max = 1000000},
		full = {type = "string", default = "drop", choices = {"drop", "refuse"}},
		drop_items = {type = "bool", default = true},
		screen = {type = "bool", default = true},
		on_death = {type = "string", default = "keep",
			choices = {"keep", "drop", "lose"}},
		show_health = {type = "bool", default = true},
		hand_level = {type = "number", default = 15, min = 0, max = 15},
	},
	-- Version 1's dig_by_tools gone: building replaces it (nothing is
	-- released: every project plays by the inventory)
	migrate = function(params, from)
		params.dig_by_tools = nil
		return params
	end,
}
