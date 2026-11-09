-- The players on everyone's screen ([KIT_PLAYER_LIST]): under `title`, a
-- row a player here, the name in their team's colour (`color` in no team)
-- and their score (kit/score, what a kit/scoreboard adds to) at the
-- right, the highest first. Where and its looks as kit/ui_text's;
-- "show", "hide" and "toggle" for everyone.
-- simplified: read again each second, so a join or a score shows up to a
-- second late; a player's join or a score's change as an event is the
-- upgrade
local function rows(c)
	local col = {}
	for _, t in ipairs(c.teams or {}) do
		for _, id in ipairs(t.state.members or {}) do
			col[id] = t.params.color
		end
	end
	local l = {}
	for _, p in ipairs(c.players or {}) do
		if p.here then
			local s = p.state["kit/score"] and p.state["kit/score"].score or 0
			l[#l + 1] = {p.name, col[p.id] or "", s}
		end
	end
	table.sort(l, function(a, b)
		if a[3] ~= b[3] then
			return a[3] > b[3]
		end
		return a[1] < b[1]
	end)
	return l
end

local function update(c)
	local l = rows(c)
	local key = {}
	for _, r in ipairs(l) do
		key[#key + 1] = table.concat(r, " ")
	end
	key = table.concat(key, ", ")
	if key ~= c.state.key then
		c.state.key = key
		c.state.value = l
		c:log("players:", key == "" and "-" or key)
	end
	c:after(1)
end

return {
	version = 1,
	no_position = true,
	players = true,
	teams = true,
	ui = {kind = "players", text = "param:title",
		anchor = "param:anchor", x = "param:x", y = "param:y",
		width = "param:width", height = "param:height", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", size = "param:size", order = "param:order"},
	params = {
		title = {cat = "hud", type = "string", default = "Players"},
		anchor = {cat = "hud", type = "string", default = "top_right",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 1, min = -400, max = 400},
		y = {cat = "hud", type = "number", default = 12, min = -400,
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
		shown = {cat = "hud", type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true, param = "shown"},
		-- {{name, team colour or "", score}...}
		value = {default = {}, shared = true},
		key = {default = ""},
	},
	about = {
		group = "UI",
		what = "The players, their teams' colours and scores, on the screen.",
		inputs = {
			show = "Shows it.",
			hide = "Hides it.",
			toggle = "Shows it if hidden, else hides it.",
		},
	},
	inputs = {show = "none", hide = "none", toggle = "none"},
	on_start = update,
	on_timer = update,
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
