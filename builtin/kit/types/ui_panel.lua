-- A panel on the players' screens ([KIT_UI_COMPONENTS], stage 4m): a box
-- `width` x `height` with a `title`, the UI components under it (its
-- children, [KIT_PANEL_PARENT]) laid out in it and shown while it is: a
-- dialog (its text, its buttons, one that `closes` it), a prompt, a teacher's
-- panel; a panel under a panel too.
-- [KIT_HUD_STYLE] Sizes in percent of the screen's shorter side; `layout`
-- "column" or "row" stacks its shown children by `order` with a `gap`, a
-- hidden one leaving no gap, a width or height of 0 fitting it to them;
-- `background` and `border` may be "none" (a layout alone, drawn nowhere).
-- While
-- one with a button is up, a player in mouse look has the pointer to
-- click with. Hidden at the start by default (`shown`); "show", "hide"
-- and "toggle", where and who sees it as kit/ui_text's: with `to`
-- "player", a dialog for the player who used something
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
	ui = {kind = "panel", text = "param:title", anchor = "param:anchor",
		x = "param:x", y = "param:y", width = "param:width",
		height = "param:height", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", size = "param:size", order = "param:order",
		layout = "param:layout", gap = "param:gap"},
	params = {
		title = {cat = "hud", type = "string", default = ""},
		anchor = {cat = "hud", type = "string", default = "center",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 0, min = -400, max = 400},
		y = {cat = "hud", type = "number", default = 0, min = -400, max = 400},
		width = {cat = "hud", type = "number", default = 30, min = 0,
			max = 400},
		height = {cat = "hud", type = "number", default = 15, min = 0,
			max = 400},
		size = {cat = "hud", type = "number", default = 1.7, min = 0.5,
			max = 30},
		style = {cat = "hud", type = "string", default = "shapes",
			choices = {"shapes", "plain"}},
		layout = {cat = "hud", type = "string", default = "none",
			choices = {"none", "column", "row"}},
		gap = {cat = "hud", type = "number", default = 0.6, min = 0, max = 100},
		color = {cat = "hud", type = "string", default = "#ffffff"},
		background = {cat = "hud", type = "string", default = "#000000a0"},
		border = {cat = "hud", type = "string", default = "#808080a0"},
		order = {cat = "hud", type = "number", default = 0, min = -40,
			max = 40},
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player", "team"}},
		shown = {cat = "hud", type = "bool", default = false},
	},
	state = {
		shown = {default = false, shared = true},
		own = {default = {}, per_player = true},
	},
	inputs = {show = "none", hide = "none", toggle = "none"},
	outputs = {shown = "bool"},
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
		if input == "toggle" then
			local now = v.shown
			if now == nil then
				now = c.state.shown
			end
			v.shown = not now
		else
			v.shown = input == "show"
		end
		c:log(v.shown and "shown" or "hidden",
				v == c.state and "for everyone" or "for " .. c:name(by))
		c:emit("shown", v.shown)
	end,
}
