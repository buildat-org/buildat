-- The scenes to pick from on the players' screens ([KIT_SCENE_PACKAGES]):
-- under `title`, a button a listed scene (a kit/scene_info on it), its
-- title and author; a press signals "picked" with the scene's name, as by
-- that player (linked to a kit/lobby's play: that scene's run). Where, its
-- looks and "show", "hide" and "toggle" as kit/ui_button's; in a panel it
-- frees the pointer as a button does.
-- simplified: read again each second, so a scene listed or retitled shows
-- up to a second late
local function update(c)
	local l, key = {}, {}
	for _, s in ipairs(c.listed or {}) do
		l[#l + 1] = {s.title, s.author, s.scene}
		key[#key + 1] = s.scene .. "=" .. s.title .. "/" .. s.author
	end
	key = table.concat(key, ", ")
	if key ~= c.state.key then
		c.state.key = key
		c.state.value = l
		c:log("scenes:", key == "" and "-" or key)
	end
	c:after(1)
end

local function view(c, by)
	if c.params.to ~= "player" or not c.player then
		return c.state
	end
	local v = c.state.own[by] or {}
	c.state.own[by] = v
	return v
end

return {
	version = 1,
	no_position = true,
	listed = true,
	ui = {kind = "list", text = "param:title",
		anchor = "param:anchor", x = "param:x", y = "param:y",
		width = "param:width", height = "param:height", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", size = "param:size", order = "param:order"},
	params = {
		title = {cat = "hud", type = "string", default = ""},
		anchor = {cat = "hud", type = "string", default = "center",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 0, min = -400, max = 400},
		y = {cat = "hud", type = "number", default = 0, min = -400, max = 400},
		width = {cat = "hud", type = "number", default = 0, min = 0, max = 400},
		height = {cat = "hud", type = "number", default = 0, min = 0,
			max = 400},
		size = {cat = "hud", type = "number", default = 2.2, min = 0.5,
			max = 30},
		style = {cat = "hud", type = "string", default = "shapes",
			choices = {"shapes", "plain"}},
		color = {cat = "hud", type = "string", default = "#ffffff"},
		background = {cat = "hud", type = "string", default = "#000000a0"},
		border = {cat = "hud", type = "string", default = "#808080a0"},
		order = {cat = "hud", type = "number", default = 0, min = -40,
			max = 40},
		to = {type = "string", default = "everyone",
			choices = {"everyone", "player"}},
		shown = {cat = "hud", type = "bool", default = true},
	},
	state = {
		shown = {default = true, shared = true, param = "shown"},
		own = {default = {}, per_player = true},
		-- {{title, author, scene}...}
		value = {default = {}, shared = true},
		key = {default = ""},
	},
	about = {
		group = "UI",
		what = "A button a listed scene, to pick one.",
		keywords = "track level map lobby menu choose",
		inputs = {
			show = "Shows it.",
			hide = "Hides it.",
			toggle = "Shows it if hidden, else hides it.",
		},
		outputs = {
			picked = "A player pressed a scene's button. Value: the scene's name.",
		},
	},
	inputs = {show = "none", hide = "none", toggle = "none"},
	outputs = {picked = "string"},
	on_start = update,
	on_timer = update,
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
	on_ui = function(c, phase, by, row)
		local r = c.state.value[row]
		if phase ~= "pressed" or not r then
			return
		end
		c:log("picked", r[3], "by", c:name(by))
		c:emit("picked", r[3])
	end,
}
