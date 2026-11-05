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
-- [KIT_HUD_STYLE] Where Kit's own HUD is and how the health bar looks: its
-- health_* a kit/ui_bar's parameters (of source "health"; percent of the
-- screen's shorter side), the anchor, x and y of hotbar_*, feed_* (the kill
-- feed), hint_* (the spectate hint) and item_line_* (the fallback item
-- line). Edit mode's drags write them here, on the scene's own kit/game_rules
-- (placed "on": "scene") when it has one: it overrides these for that scene.
-- [KIT_CTF] hand_level: the highest material level a hand digs (a dig at
-- a hand's speed: nothing held, or an item with no dig speed for the
-- voxel's group); one above it is refused. 15 (the default): any
-- [KIT_CTF] respawn: a dead player back at their spawn "at_once", or
-- "on_signal": waiting (no actions, their body still, "Waiting to
-- respawn" on their screen) until the input respawn, which respawns
-- every player of the round waiting
-- Stage 8's scene override goes beside it
local ANCHORS = {"top_left", "top", "top_right", "left", "center", "right",
	"bottom_left", "bottom", "bottom_right"}
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
		health_style = {type = "string", default = "shapes",
			choices = {"shapes", "plain"}},
		health_form = {type = "string", default = "bar",
			choices = {"bar", "pie"}},
		health_direction = {type = "string", default = "left_to_right",
			choices = {"left_to_right", "right_to_left", "bottom_to_top",
			"top_to_bottom"}},
		health_label = {type = "string", default = "{value:int}"},
		health_color = {type = "string", default = "#d82828"},
		health_background = {type = "string", default = "#000000a0"},
		health_border = {type = "string", default = "#808080a0"},
		health_size = {type = "number", default = 1.8, min = 0.5, max = 30},
		health_blink_below = {type = "number", default = 0.25, min = 0, max = 1},
		health_anchor = {type = "string", default = "bottom", choices = ANCHORS},
		health_x = {type = "number", default = 0, min = -400, max = 400},
		health_y = {type = "number", default = 10.2, min = -400, max = 400},
		health_width = {type = "number", default = 20, min = 0, max = 400},
		health_height = {type = "number", default = 2.4, min = 0, max = 400},
		health_order = {type = "number", default = 0, min = -40, max = 40},
		hotbar_anchor = {type = "string", default = "bottom", choices = ANCHORS},
		hotbar_x = {type = "number", default = 0, min = -400, max = 400},
		hotbar_y = {type = "number", default = 2.8, min = -400, max = 400},
		feed_anchor = {type = "string", default = "top_right", choices = ANCHORS},
		feed_x = {type = "number", default = 0.9, min = -400, max = 400},
		feed_y = {type = "number", default = 3.7, min = -400, max = 400},
		hint_anchor = {type = "string", default = "bottom", choices = ANCHORS},
		hint_x = {type = "number", default = 0, min = -400, max = 400},
		hint_y = {type = "number", default = 13.4, min = -400, max = 400},
		item_line_anchor = {type = "string", default = "bottom", choices = ANCHORS},
		item_line_x = {type = "number", default = 0, min = -400, max = 400},
		item_line_y = {type = "number", default = 7.4, min = -400, max = 400},
		hand_level = {type = "number", default = 15, min = 0, max = 15},
		respawn = {type = "string", default = "at_once",
			choices = {"at_once", "on_signal"}},
	},
	inputs = {respawn = "any"},
	on_input = function(c, input)
		if input == "respawn" then
			c:respawn_waiting()
		end
	end,
	-- Waiting players respawned when they would not wait any more
	on_params = function(c)
		if c.params.respawn == "at_once" then
			c:respawn_waiting()
		end
	end,
	-- Version 1's dig_by_tools gone: building replaces it (nothing is
	-- released: every project plays by the inventory)
	migrate = function(params, from)
		params.dig_by_tools = nil
		return params
	end,
}
