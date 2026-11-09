-- A button on the players' screens ([KIT_UI_COMPONENTS], stage 4m): a
-- player presses it (a click, a tap) and it signals "pressed" and
-- "released", as by them; with `closes`, a press hides its parent panel too
-- (a dialog's OK). Or with `action` (a kit/action's name) it is that
-- action's button: it presses the action, its own signals silent, and
-- with no `label` it is called what the action is. A press counts only
-- while it is on that player's screen, within their acts a second (as
-- an action's). Where, who sees it and "show", "hide" and "toggle" as
-- kit/ui_text's ([KIT_HUD_STYLE] its `style`, colours and sizes too).
-- [KIT_HUD_BUTTONS_MOUSE_LOOK] Out of a panel it is drawn only on a
-- touchscreen or with a free pointer (top-down): in mouse look nothing
-- could click it, an action's key or a panel (which frees the pointer,
-- opened by a key's kit/action) is the way there
local function view(c, by)
	if (c.params.to ~= "player" and c.params.to ~= "team") or
			not c.player then
		return c.state
	end
	local v = c.state.own[by] or {}
	c.state.own[by] = v
	-- [KIT_TEAM_LEFTOVERS] to "team": the player's team's members see the
	-- same (a player in no team, their own)
	for _, t in ipairs(c.params.to == "team" and c.teams or {}) do
		local m = t.state.members or {}
		for _, id in ipairs(m) do
			if id == c.player then
				for _, o in ipairs(m) do
					c.state.own["player:" .. o] = v
				end
			end
		end
	end
	return v
end

return {
	version = 2,
	no_position = true,
	-- (to "team" reads them)
	teams = true,
	ui = {kind = "button", text = "param:label", action = "param:action",
		anchor = "param:anchor", x = "param:x", y = "param:y",
		width = "param:width", height = "param:height", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", size = "param:size", order = "param:order"},
	params = {
		label = {cat = "hud", type = "string", default = "OK"},
		action = {type = "string", default = ""},
		closes = {type = "bool", default = false},
		anchor = {cat = "hud", type = "string", default = "bottom",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 0, min = -400, max = 400},
		y = {cat = "hud", type = "number", default = 5.6, min = -400,
			max = 400},
		width = {cat = "hud", type = "number", default = 0, min = 0, max = 400},
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
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player", "team"}},
		shown = {cat = "hud", type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true, param = "shown"},
		own = {default = {}, per_player = true},
	},
	about = {
		group = "UI",
		what = "A button on the players' screens.",
		inputs = {
			show = "Shows it.",
			hide = "Hides it.",
			toggle = "Shows it if hidden, else hides it.",
		},
		outputs = {
			pressed = "A player pressed it.",
			released = "A player let go of it.",
		},
	},
	inputs = {show = "none", hide = "none", toggle = "none"},
	outputs = {pressed = "none", released = "none"},
	-- [KIT_HUD_STYLE] Version 1's pixels as percents of the shorter side,
	-- against a 1080 p screen
	migrate = function(params, from)
		if from < 2 then
			for _, k in ipairs({"x", "y", "width", "height", "size"}) do
				if type(params[k]) == "number" then
					params[k] = math.floor(params[k] * 10000 / 1080 + 0.5) / 100
				end
			end
		end
		return params
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
		if phase == "pressed" and c.params.closes and c.panel then
			c:send(c.panel, "hide")
		end
	end,
}
