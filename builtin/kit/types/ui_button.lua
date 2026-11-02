-- A button on the players' screens ([KIT_UI_COMPONENTS], stage 4m): a
-- player presses it (a click, a tap) and it signals "pressed" and
-- "released", as by them; with `closes`, a press hides its panel too
-- (a dialog's OK). Or with `action` (a kit/action's name) it is that
-- action's button: it presses the action, its own signals silent, and
-- with no `label` it is called what the action is. A press counts only
-- while it is on that player's screen, within their acts a second (as
-- an action's). Where, who sees it and "show", "hide" and "toggle" as
-- kit/ui_text's.
-- simplified: out of a panel, a player in mouse look (the pointer
-- captured) cannot click it: an action's key, a touchscreen, a free
-- pointer (top-down) or a panel (which frees the pointer) reach it
local function view(c, by)
	if c.params.to ~= "player" or not c.player then
		return c.state
	end
	c.state.own[by] = c.state.own[by] or {}
	return c.state.own[by]
end

return {
	version = 1,
	ui = {kind = "button", text = "param:label", action = "param:action",
		anchor = "param:anchor", x = "param:x", y = "param:y",
		width = "param:width", panel = "param:panel"},
	params = {
		label = {type = "string", default = "OK"},
		action = {type = "string", default = ""},
		closes = {type = "bool", default = false},
		anchor = {type = "string", default = "bottom", choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {type = "number", default = 0, min = -2000, max = 2000},
		y = {type = "number", default = 60, min = -2000, max = 2000},
		width = {type = "number", default = 0, min = 0, max = 2000},
		panel = {type = "entity", default = 0},
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player"}},
		shown = {type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true},
		own = {default = {}, per_player = true},
	},
	inputs = {show = "none", hide = "none", toggle = "none"},
	outputs = {pressed = "none", released = "none"},
	on_start = function(c)
		c.state.shown = c.params.shown
	end,
	on_params = function(c, changed)
		if changed.shown ~= nil then
			c.state.shown = c.params.shown
		end
	end,
	on_input = function(c, input, value, by)
		local v = view(c, by)
		if input == "toggle" then
			local now = v.shown
			if now == nil then
				now = c.state.shown
			end
			v.shown = not now
		else
			v.shown = input == "show"
		end
	end,
	on_ui = function(c, phase, by)
		c:log(phase, "by", c:name(by))
		c:emit(phase)
		if phase == "pressed" and c.params.closes and c.params.panel ~= 0 then
			c:send(c.params.panel, "hide")
		end
	end,
}
