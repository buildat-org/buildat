-- A panel on the players' screens ([KIT_UI_COMPONENTS], stage 4m): a box
-- `width` x `height` UI units with a `title`, the UI components whose
-- `panel` it is laid out in it and shown while it is: a dialog (its text,
-- its buttons, one that `closes` it), a prompt, a teacher's panel. While
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
	version = 1,
	-- (to "team" reads them)
	teams = true,
	ui = {kind = "panel", text = "param:title", anchor = "param:anchor",
		x = "param:x", y = "param:y", width = "param:width",
		height = "param:height", color = "param:background",
		panel = "param:panel"},
	params = {
		title = {type = "string", default = ""},
		anchor = {type = "string", default = "center", choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {type = "number", default = 0, min = -2000, max = 2000},
		y = {type = "number", default = 0, min = -2000, max = 2000},
		width = {type = "number", default = 320, min = 40, max = 2000},
		height = {type = "number", default = 160, min = 30, max = 2000},
		background = {type = "string", default = "#203040"},
		panel = {type = "entity", default = 0},
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player", "team"}},
		shown = {type = "bool", default = false},
	},
	state = {
		shown = {default = false, shared = true},
		own = {default = {}, per_player = true},
	},
	inputs = {show = "none", hide = "none", toggle = "none"},
	outputs = {shown = "bool"},
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
