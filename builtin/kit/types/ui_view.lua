-- A view of the play on the players' screens ([KIT_LOBBY]): a picture of
-- the scene following a player, the one in play longest (the earliest
-- "follow" without an "unfollow" since: kit/lobby's entered and left
-- linked to them), falling back to any player here; with none, its `title`
-- and "Nobody is playing". Its camera is each client's own (its turn and
-- distance from the body: a side camera's, a chase camera's) at the
-- followed player's body. A lobby's corner, a spectators' screen. Where and
-- its looks as kit/ui_text's; "show", "hide" and "toggle" for everyone.
-- simplified: the fallback is the lowest id here; read again each second
-- (a join or a leave up to a second late)
local function here(c)
	local h = {}
	for _, p in ipairs(c.players or {}) do
		if p.here then
			h[p.id] = true
		end
	end
	return h
end

local function update(c)
	local h, target = here(c), 0
	for _, id in ipairs(c.state.queue) do
		if h[id] then
			target = id
			break
		end
	end
	if target == 0 then
		for id in pairs(h) do
			if target == 0 or id < target then
				target = id
			end
		end
	end
	if target ~= c.state.value then
		c.state.value = target
		c:log("follows", target ~= 0 and c:name("player:" .. target) or "nobody")
	end
end

local function tick(c)
	update(c)
	c:after(1)
end

return {
	version = 1,
	no_position = true,
	players = true,
	ui = {kind = "view", text = "param:title", anchor = "param:anchor",
		x = "param:x", y = "param:y", width = "param:width",
		height = "param:height", color = "param:color",
		background = "param:background", border = "param:border",
		style = "param:style", size = "param:size", order = "param:order"},
	params = {
		title = {cat = "hud", type = "string", default = ""},
		anchor = {cat = "hud", type = "string", default = "bottom_right",
			choices = {"top_left",
			"top", "top_right", "left", "center", "right", "bottom_left",
			"bottom", "bottom_right"}},
		x = {cat = "hud", type = "number", default = 2, min = -400, max = 400},
		y = {cat = "hud", type = "number", default = 2, min = -400, max = 400},
		width = {cat = "hud", type = "number", default = 48, min = 0, max = 400},
		height = {cat = "hud", type = "number", default = 27, min = 0,
			max = 400},
		size = {cat = "hud", type = "number", default = 1.6, min = 0.5,
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
		-- The player followed (their entity's id; 0 none)
		value = {default = 0, shared = true},
		queue = {default = {}},
	},
	about = {
		group = "UI",
		what = "A picture of the play following a player, on the players' screens.",
		keywords = "lobby camera spectate watch viewport",
		inputs = {
			follow = "The player who set it off is in play (followed after those before).",
			unfollow = "The player who set it off is out of play.",
			show = "Shows it.",
			hide = "Hides it.",
			toggle = "Shows it if hidden, else hides it.",
		},
	},
	inputs = {follow = "none", unfollow = "none", show = "none", hide = "none",
		toggle = "none"},
	on_start = tick,
	on_timer = tick,
	on_params = function(c, changed)
		if changed.shown ~= nil then
			c.state.shown = c.params.shown
		end
	end,
	on_input = function(c, input)
		if input == "follow" or input == "unfollow" then
			local id, q = c.player, c.state.queue
			for i = #q, 1, -1 do
				if q[i] == id then
					table.remove(q, i)
				end
			end
			if input == "follow" and id then
				q[#q + 1] = id
			end
			update(c)
		elseif input == "toggle" then
			c.state.shown = not c.state.shown
		else
			c.state.shown = input == "show"
		end
	end,
}
