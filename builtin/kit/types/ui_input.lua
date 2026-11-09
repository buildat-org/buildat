-- A line of text a player enters on their screen ([KIT_TEXT_INPUT]): a
-- prompt, a name, a sign's text. `label` at its left, the field the rest;
-- Enter signals "entered" with the line (control characters out, cut at
-- `max_length` characters), as by them, and empties the field. The field
-- is a LineEdit: the system's IME natively, the page's text input (a
-- phone's keyboard) on the web. While it has the keys, the controls do not
-- (Enter or a click elsewhere gives them back). Where, who sees it and
-- "show", "hide" and "toggle" as kit/ui_text's; in a kit/ui_panel it frees
-- the pointer as a button does.
-- simplified: out of a panel, a player in mouse look (the pointer
-- captured) cannot click it, as a button
local function view(c, by)
	if (c.params.to ~= "player" and c.params.to ~= "team") or
			not c.player then
		return c.state
	end
	local v = c.state.own[by] or {}
	c.state.own[by] = v
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
	no_position = true,
	teams = true,
	ui = {kind = "input", text = "param:label", max_length = "param:max_length",
		anchor = "param:anchor", x = "param:x", y = "param:y",
		width = "param:width", height = "param:height", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", size = "param:size", order = "param:order"},
	params = {
		label = {cat = "hud", type = "string", default = "Say:"},
		max_length = {type = "number", default = 100, min = 1, max = 200},
		anchor = {cat = "hud", type = "string", default = "bottom",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 0, min = -400, max = 400},
		y = {cat = "hud", type = "number", default = 9, min = -400,
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
		what = "A line of text a player enters on their screen.",
		inputs = {
			show = "Shows it.",
			hide = "Hides it.",
			toggle = "Shows it if hidden, else hides it.",
		},
		outputs = {
			entered = "A player entered a line. Value: the text.",
		},
	},
	inputs = {show = "none", hide = "none", toggle = "none"},
	outputs = {entered = "string"},
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
	on_ui = function(c, phase, by, text)
		if phase ~= "entered" or type(text) ~= "string" then
			return
		end
		-- Characters, not bytes: a cut never splits one
		-- (a byte not 10xxxxxx starts one)
		local n, chars = math.floor(c.params.max_length or 100), 0
		for i = 1, #text do
			local b = text:byte(i)
			if b < 0x80 or b >= 0xc0 then
				chars = chars + 1
				if chars > n then
					text = text:sub(1, i - 1)
					break
				end
			end
		end
		c:log("entered by", c:name(by) .. ":", text)
		c:emit("entered", text)
	end,
}
