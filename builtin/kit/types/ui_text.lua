-- A text on the players' screens ([KIT_UI_COMPONENTS], stage 4m): a
-- score, a countdown, a hint. In `text`, {value} is the last value on
-- "value" ({value:time} as m:ss, {value:int} a whole number), [<action>]
-- each player's key for it, | a new line. Where: `anchor` (a corner, an
-- edge's middle or the centre) and x, y in from it, on the screen or in
-- its `panel` (a kit/ui_panel: shown while it is). [KIT_HUD_STYLE] x, y,
-- width, height and size in percent of the screen's shorter side; width
-- and height 0 from the text; `order` over or under what it overlaps;
-- `style` "shapes" (`background` and `border` round the text, each a
-- colour with alpha or "none") or "plain" (the text alone). Who sees it: everyone, or with `to` "player" each player
-- their own, the player who set a signal off the one it changes (a signal
-- by no player, everyone's), or with "team" the members of that
-- player's team alike. "show", "hide" and "toggle" show it;
-- `shown`: at the start. Edit mode draws every UI component where it
-- would be, to click on
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
	-- (to "team" reads them)
	teams = true,
	ui = {kind = "text", text = "param:text", anchor = "param:anchor",
		x = "param:x", y = "param:y", width = "param:width",
		height = "param:height", size = "param:size", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", order = "param:order", panel = "param:panel"},
	params = {
		text = {type = "string", default = "Score: {value}"},
		anchor = {type = "string", default = "top", choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {type = "number", default = 0, min = -400, max = 400},
		y = {type = "number", default = 3.7, min = -400, max = 400},
		width = {type = "number", default = 0, min = 0, max = 400},
		height = {type = "number", default = 0, min = 0, max = 400},
		size = {type = "number", default = 2, min = 0.5, max = 30},
		style = {type = "string", default = "shapes",
			choices = {"shapes", "plain"}},
		color = {type = "string", default = "#ffffff"},
		background = {type = "string", default = "#000000a0"},
		border = {type = "string", default = "#808080a0"},
		order = {type = "number", default = 0, min = -40, max = 40},
		panel = {type = "entity", default = 0},
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player", "team"}},
		shown = {type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true},
		value = {default = "", shared = true},
		own = {default = {}, per_player = true},
	},
	inputs = {value = "any", clear = "none", show = "none", hide = "none",
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
		if input == "value" or input == "clear" then
			v.value = input == "value" and value ~= nil and value or ""
		elseif input == "toggle" then
			local now = v.shown
			if now == nil then
				now = c.state.shown
			end
			v.shown = not now
		else
			v.shown = input == "show"
		end
		c:log(input, v == c.state and "for everyone" or "for " .. c:name(by))
	end,
}
