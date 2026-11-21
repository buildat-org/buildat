-- The chat on the players' screens ([KIT_LOBBY]): its last `lines` lines
-- and under them a field to say one, `label` at its left. The same chat as
-- the pause menu's (builtin/chat's, in an app that has it; none: "No chat
-- here"), so players in a lobby talk with the builder editing. Where and its
-- looks as kit/ui_text's; "show", "hide" and "toggle" for everyone (in a
-- kit/ui_panel whose `to` is "player", each player's with it).
-- simplified: a line longer than the width wraps, the oldest cut at the top
return {
	version = 1,
	no_position = true,
	ui = {kind = "chat", text = "param:label", lines = "param:lines",
		anchor = "param:anchor", x = "param:x", y = "param:y",
		width = "param:width", height = "param:height", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", size = "param:size", order = "param:order"},
	params = {
		label = {cat = "hud", type = "string", default = "Say:"},
		lines = {cat = "hud", type = "number", default = 8, min = 1, max = 30},
		anchor = {cat = "hud", type = "string", default = "bottom_left",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 1, min = -400, max = 400},
		y = {cat = "hud", type = "number", default = 1, min = -400, max = 400},
		width = {cat = "hud", type = "number", default = 50, min = 0, max = 400},
		height = {cat = "hud", type = "number", default = 0, min = 0,
			max = 400},
		size = {cat = "hud", type = "number", default = 1.8, min = 0.5,
			max = 30},
		style = {cat = "hud", type = "string", default = "shapes",
			choices = {"shapes", "plain"}},
		color = {cat = "hud", type = "string", default = "#ffffff"},
		background = {cat = "hud", type = "string", default = "#000000a0"},
		border = {cat = "hud", type = "string", default = "#808080a0"},
		order = {cat = "hud", type = "number", default = 0, min = -40,
			max = 40},
		shown = {cat = "hud", type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true, param = "shown"},
	},
	about = {
		group = "UI",
		what = "The chat's last lines and a field to say one, on the players' screens.",
		keywords = "lobby talk message",
		inputs = {
			show = "Shows it.",
			hide = "Hides it.",
			toggle = "Shows it if hidden, otherwise hides it.",
		},
		params = {
			label = "The text at the left of the field to say a line.",
			lines = "How many of the chat's last lines it shows.",
			anchor = "The corner, edge's middle or centre of the screen (or its panel) it is placed from.",
			x = "How far in from its anchor sideways, in percent of the screen's shorter side.",
			y = "How far in from its anchor up or down, in percent of the screen's shorter side.",
			width = "Its width in percent of the screen's shorter side.",
			height = "Its height in percent of the screen's shorter side (0: its lines').",
			size = "The text's size in percent of the screen's shorter side.",
			style = "shapes: a background and a border round it; plain: the text alone.",
			color = "The text's colour, as #rrggbb.",
			background = "The background's colour, as #rrggbbaa, or none.",
			border = "The border's colour, as #rrggbbaa, or none.",
			order = "Drawn over what it overlaps with a lower order.",
			shown = "Whether it is up at the start.",
		},
	},
	inputs = {show = "none", hide = "none", toggle = "none"},
	on_params = function(c, changed)
		if changed.shown ~= nil then
			c.state.shown = c.params.shown
		end
	end,
	on_input = function(c, input)
		if input == "toggle" then
			c.state.shown = not c.state.shown
		else
			c.state.shown = input == "show"
		end
	end,
}
