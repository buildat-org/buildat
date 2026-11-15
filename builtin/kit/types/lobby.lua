-- A lobby round a game's runs ([KIT_LOBBY], any game's): each player's own
-- state, "lobby" (between runs: a menu, the chat), "playing" (a run) or
-- "over" (a run's result). A player who comes in while Running (and every
-- player at Play) is in the lobby. play (from the lobby or over) and again
-- (from over, or a run started over) start a run: "entered", by them;
-- over ends it, lobby goes back, each "left" if they were playing.
-- Its screens follow the state: kit/ui_panels `lobby_screen` (in the lobby)
-- and `over_screen` (over) shown to that player alone, hidden as they leave
-- it (each a panel whose `to` is "player": their own; a screen, `screen`
-- full or over). A start zone instead (a kit/trigger_zone linked to play)
-- or beside it works as well.
local STATES = {lobby = true, playing = true, over = true}

local function screens(c, by, now)
	local p = c.params
	for _, s in ipairs({{p.lobby_screen, "lobby"}, {p.over_screen, "over"}}) do
		if s[1] and s[1] ~= 0 then
			c:send(s[1], s[2] == now and "show" or "hide", nil, by)
		end
	end
end

local function set(c, by, now)
	local was = c.state.states[by]
	c.state.states[by] = now
	c:log(c:name(by) .. ":", tostring(was or "none"), "->", now)
	screens(c, by, now)
	if was == "playing" then
		c:emit("left", nil, by)
	end
	if now == "playing" then
		c:emit("entered", nil, by)
	end
end

return {
	version = 1,
	no_position = true,
	about = {
		group = "Game",
		what = "Each player's lobby, run and result, and the screens for them.",
		keywords = "menu start round result card",
		inputs = {
			play = "The player who set it off starts a run (from the lobby or a result).",
			again = "The player who set it off starts a run again (from a result, or over in a run).",
			lobby = "The player who set it off goes back to the lobby.",
			over = "The player's run is over: their result.",
		},
		outputs = {
			entered = "A player's run started.",
			left = "A player's run ended: over, or back to the lobby.",
		},
	},
	params = {
		lobby_screen = {type = "entity", default = 0},
		over_screen = {type = "entity", default = 0},
	},
	state = {states = {default = {}, per_player = true}},
	inputs = {play = "none", again = "none", lobby = "none", over = "none"},
	outputs = {entered = "none", left = "none"},
	on_join = function(c, by)
		if c.player then
			set(c, by, "lobby")
		end
	end,
	-- (a live edit's screen: each player's shown as their state is, the one
	-- it replaced hidden)
	on_params = function(c, changed)
		for k in pairs({lobby_screen = 1, over_screen = 1}) do
			local was = changed[k]
			if was ~= nil then
				for by in pairs(c.state.states) do
					if was ~= 0 then
						c:send(was, "hide", nil, by)
					end
				end
			end
		end
		for by, now in pairs(c.state.states) do
			screens(c, by, now)
		end
	end,
	on_input = function(c, input, value, by)
		if not c.player then
			return
		end
		local now = c.state.states[by]
		if not STATES[now] then
			now = "lobby"
		end
		if input == "play" and now ~= "playing" then
			set(c, by, "playing")
		elseif input == "again" and (now == "over" or now == "playing") then
			-- (over in a run: left, then entered again)
			if now == "playing" then
				c.state.states[by] = "over"
				c:emit("left", nil, by)
			end
			set(c, by, "playing")
		elseif input == "lobby" and now ~= "lobby" then
			set(c, by, "lobby")
		elseif input == "over" and now == "playing" then
			set(c, by, "over")
		end
	end,
}
