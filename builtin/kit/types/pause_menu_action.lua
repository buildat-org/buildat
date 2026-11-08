-- [KIT_AIRSHIPS_2] A button in the players' pause menu (Escape): `label`,
-- placed by `order` among the app's (Continue 0, Kit's Edit 10, Chat 20,
-- an app's 50, Settings 80, Leave 100). A player's press signals
-- "pressed" as by them, so a link acts on that player (a kit/spawner's
-- "spawn" takes them there). "show" and "hide" (or `shown`) put it in the
-- menu or take it out, for everyone in the round it is in; in play only.
-- simplified: `order` is read when the item first reaches a client; a
-- changed order shows at the client's next join
return {
	version = 1,
	no_position = true,
	ui = {kind = "menu", text = "param:label", order = "param:order"},
	params = {
		label = {cat = "hud", type = "string", default = "Back"},
		order = {cat = "hud", type = "number", default = 50, min = 1,
			max = 99},
		shown = {cat = "hud", type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true, param = "shown"},
	},
	about = {
		what = "A button in the players' pause menu.",
		inputs = {
			show = "Puts it in the menu.",
			hide = "Takes it out of the menu.",
		},
		outputs = {
			pressed = "A player pressed it (they set it off).",
		},
	},
	inputs = {show = "none", hide = "none"},
	outputs = {pressed = "none"},
	on_params = function(c, changed)
		if changed.shown ~= nil then
			c.state.shown = c.params.shown
		end
	end,
	on_input = function(c, input)
		c.state.shown = input == "show"
	end,
	on_ui = function(c, phase, by)
		if phase == "pressed" then
			c:log("pressed by", c:name(by))
			c:emit("pressed")
		end
	end,
}
