-- A bar on the players' screens ([KIT_UI_COMPONENTS], stage 4m): health,
-- the time left, a capture's progress. It fills from `min` to `max` as
-- the value on "value" does (`start`: at the start; min over max: it
-- empties as the value grows); `label` over it, {value} the value
-- ({value:time}, {value:int}), shrunk to fit it, then clipped. Where, who
-- sees it and "show", "hide" and "toggle" as kit/ui_text's.
-- [KIT_HUD_STYLE] `form` "bar" (running by `direction`) or "pie" (a disc in
-- 32 steps; width and height 0: a bar's or a pie's default size); `color`
-- the fill's, `background` and `border` each a colour with alpha or "none";
-- `blink_below` a fraction of the range under which it blinks (0 off);
-- `source` "health": the player's own kit/health instead of signals (Kit's
-- health bar, kit/game_rules' show_health, gives way to one up)
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
	ui = {kind = "bar", text = "param:label", anchor = "param:anchor",
		x = "param:x", y = "param:y", width = "param:width",
		height = "param:height", min = "param:min", max = "param:max",
		color = "param:color", background = "param:background",
		border = "param:border", style = "param:style", form = "param:form",
		direction = "param:direction", size = "param:size",
		blink_below = "param:blink_below", order = "param:order",
		source = "param:source"},
	params = {
		label = {cat = "hud", type = "string", default = "{value}"},
		min = {type = "number", default = 0, min = -1000000, max = 1000000},
		max = {type = "number", default = 100, min = -1000000, max = 1000000},
		start = {type = "number", default = 100, min = -1000000,
			max = 1000000},
		anchor = {cat = "hud", type = "string", default = "top_left",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 1.1, min = -400,
			max = 400},
		y = {cat = "hud", type = "number", default = 7.4, min = -400,
			max = 400},
		width = {cat = "hud", type = "number", default = 0, min = 0, max = 400},
		height = {cat = "hud", type = "number", default = 0, min = 0,
			max = 400},
		size = {cat = "hud", type = "number", default = 1.7, min = 0.5,
			max = 30},
		style = {cat = "hud", type = "string", default = "shapes",
			choices = {"shapes", "plain"}},
		form = {cat = "hud", type = "string", default = "bar", choices = {"bar",
			"pie"}},
		direction = {cat = "hud", type = "string", default = "left_to_right",
			choices = {"left_to_right", "right_to_left", "bottom_to_top",
			"top_to_bottom"}},
		source = {type = "string", default = "signal",
			choices = {"signal", "health"}},
		color = {cat = "hud", type = "string", default = "#20c8e0"},
		background = {cat = "hud", type = "string", default = "#000000a0"},
		border = {cat = "hud", type = "string", default = "#808080a0"},
		blink_below = {cat = "hud", type = "number", default = 0, min = 0,
			max = 1},
		order = {cat = "hud", type = "number", default = 0, min = -40,
			max = 40},
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player", "team"}},
		shown = {cat = "hud", type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true, param = "shown"},
		value = {default = 0, shared = true, param = "start"},
		own = {default = {}, per_player = true},
	},
	about = {
		what = "A bar or a pie on the players' screens.",
		inputs = {
			value = "Sets what it shows. Value: a number, within its min and max.",
			show = "Shows it.",
			hide = "Hides it.",
			toggle = "Shows it if hidden, else hides it.",
		},
	},
	inputs = {value = "number", show = "none", hide = "none",
		toggle = "none"},
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
		if changed.start ~= nil then
			c.state.value = c.params.start
		end
	end,
	on_input = function(c, input, value, by)
		local v = view(c, by)
		if input == "value" then
			v.value = value
		elseif input == "toggle" then
			local now = v.shown
			if now == nil then
				now = c.state.shown
			end
			v.shown = not now
		else
			v.shown = input == "show"
		end
		c:log(input, input == "value" and value or "",
				v == c.state and "for everyone" or "for " .. c:name(by))
	end,
}
