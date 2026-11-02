-- A bar on the players' screens ([KIT_UI_COMPONENTS], stage 4m): health,
-- the time left, a capture's progress. It fills from `min` to `max` as
-- the value on "value" does (`start`: at the start); `label` over it,
-- {value} the value. Where, who sees it and "show", "hide" and "toggle"
-- as kit/ui_text's
local function view(c, by)
	if c.params.to ~= "player" or not c.player then
		return c.state
	end
	c.state.own[by] = c.state.own[by] or {}
	return c.state.own[by]
end

return {
	version = 1,
	ui = {kind = "bar", text = "param:label", anchor = "param:anchor",
		x = "param:x", y = "param:y", width = "param:width",
		min = "param:min", max = "param:max", color = "param:color",
		panel = "param:panel"},
	params = {
		label = {type = "string", default = "{value}"},
		min = {type = "number", default = 0, min = -1000000, max = 1000000},
		max = {type = "number", default = 100, min = -1000000, max = 1000000},
		start = {type = "number", default = 100, min = -1000000,
			max = 1000000},
		anchor = {type = "string", default = "top_left", choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {type = "number", default = 12, min = -2000, max = 2000},
		y = {type = "number", default = 80, min = -2000, max = 2000},
		width = {type = "number", default = 160, min = 20, max = 2000},
		color = {type = "string", default = "#d04040"},
		panel = {type = "entity", default = 0},
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player"}},
		shown = {type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true},
		value = {default = 0, shared = true},
		own = {default = {}, per_player = true},
	},
	inputs = {value = "number", show = "none", hide = "none",
		toggle = "none"},
	on_start = function(c)
		c.state.shown = c.params.shown
		c.state.value = c.params.start
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
