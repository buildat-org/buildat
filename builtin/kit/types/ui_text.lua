-- A text on the players' screens ([KIT_UI_COMPONENTS], stage 4m): a
-- score, a countdown, a hint. In `text`, {value} is the last value on
-- "value" ({value:time} as m:ss, [KIT_RECORDS] {value:time1} to a tenth
-- (12.3, 1:02.3; 0.0 before any), {value:int} a whole number, 0 before
-- any; a kit/stopwatch's running time counts on in all three),
-- {key:<action>} each player's key for it, | a new line. Where: `anchor` (a corner, an
-- edge's middle or the centre) and x, y in from it, on the screen or in
-- its parent if a kit/ui_panel (shown while it is). [KIT_HUD_STYLE] x, y,
-- width, height and size in percent of the screen's shorter side; width
-- and height 0 from the text; `order` over or under what it overlaps;
-- `style` "shapes" (`background` and `border` round the text, each a
-- colour with alpha or "none") or "plain" (the text alone). Who sees it: everyone, or with `to` "player" each player
-- their own, the player who set a signal off the one it changes (a signal
-- by no player, everyone's), or with "team" the members of that
-- player's team alike. "show", "hide" and "toggle" show it;
-- `shown`: at the start. [KIT_RECORDS] `clear_after` (seconds, 0 never):
-- each value shown for that long, then as none, on the client (a note,
-- an announcer's line; the same value again shows it again: `sets`
-- counts them). Edit mode draws every UI component where it
-- would be, to click on. [KIT_UI_EMPHASIS] `appear` (fade, slide, pop) as
-- it is shown, `on_change` pop as its text changes (pop_words: not as its
-- numbers alone do), on the client (client_lua/ui.lua)
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
	reads_teams = true,
	ui = {kind = "text", text = "param:text", anchor = "param:anchor",
		x = "param:x", y = "param:y", width = "param:width",
		height = "param:height", size = "param:size", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", order = "param:order",
		clear_after = "param:clear_after", appear = "param:appear",
		on_change = "param:on_change"},
	params = {
		text = {cat = "hud", type = "string", default = "Score: {value}"},
		anchor = {cat = "hud", type = "string", default = "top",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 0, min = -400, max = 400},
		y = {cat = "hud", type = "number", default = 3.7, min = -400,
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
		clear_after = {cat = "hud", type = "number", default = 0, min = 0,
			max = 3600},
		appear = {cat = "hud", type = "string", default = "none",
			choices = {"none", "fade", "slide", "pop"}},
		on_change = {cat = "hud", type = "string", default = "none",
			choices = {"none", "pop", "pop_words"}},
	},
	state = {
		shown = {default = true, shared = true, param = "shown"},
		value = {default = "", shared = true},
		-- ([KIT_RECORDS] with clear_after: the values set, each shown anew)
		sets = {default = 0, shared = true},
		own = {default = {}, per_player = true},
	},
	about = {
		group = "UI",
		what = "Text on the players' screens.",
		inputs = {
			value = "Fills {value} in its text. Value: what to show; none empties it.",
			clear = "Empties {value}.",
			show = "Shows it.",
			hide = "Hides it.",
			toggle = "Shows it if hidden, otherwise hides it.",
		},
		params = {
			text = "What it says: {value} the last value ({value:time} m:ss, {value:time1} to a tenth, {value:int} whole), {key:<action>} a player's key, | a new line.",
			anchor = "The corner, edge's middle or centre of the screen (or its panel) it is placed from.",
			x = "How far in from its anchor sideways, in percent of the screen's shorter side.",
			y = "How far in from its anchor up or down, in percent of the screen's shorter side.",
			width = "Its width in percent of the screen's shorter side (0: the text's).",
			height = "Its height in percent of the screen's shorter side (0: the text's).",
			size = "The text's size in percent of the screen's shorter side.",
			style = "shapes: a background and a border round the text; plain: the text alone.",
			color = "The text's colour, as #rrggbb.",
			background = "The background's colour, as #rrggbbaa, or none.",
			border = "The border's colour, as #rrggbbaa, or none.",
			order = "Drawn over what it overlaps with a lower order.",
			to = "Who sees a change: everyone, the player who set it off, or that player's team.",
			shown = "Whether it is up at the start.",
			clear_after = "Seconds each value is shown before it is cleared on the screen (0: never).",
			appear = "How it comes up as it is shown: at once (none), fading in, sliding in or popping up.",
			on_change = "pop: it pops as its text changes; pop_words: as its words do, not its numbers alone (a clock's tick); none: never.",
		},
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
	on_params = function(c, changed)
		if changed.shown ~= nil then
			c.state.shown = c.params.shown
		end
	end,
	on_input = function(c, input, value, by)
		local v = view(c, by)
		if input == "value" or input == "clear" then
			v.value = input == "value" and value ~= nil and value or ""
			if c.params.clear_after > 0 then
				v.sets = (v.sets or 0) + 1
			end
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
