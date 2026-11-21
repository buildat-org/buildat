-- A lobby round a game's runs ([KIT_LOBBY], any game's): each player's own
-- state, "lobby" (between runs: a menu, the chat), "playing" (a run) or
-- "over" (a run's result). A player who comes in while Running (and every
-- player at Play) is in the lobby. play (from the lobby or over) and again
-- (from over, or a run started over) start a run: "entered", by them;
-- over ends it, lobby goes back, each "left" if they were playing; in the
-- lobby (come in, or back) "in_lobby". (4z37i) So the music follows the
-- states by links alone: a lobby song's play from in_lobby and stop from
-- entered, a run's song's play from the game's start (GO) and stop from
-- left: none in a run's countdown or on its result.
-- Its screens follow the state: kit/ui_panels `lobby_screen` (in the lobby)
-- and `over_screen` (over) shown to that player alone, hidden as they leave
-- it (each a panel whose `to` is "player": their own; a screen, `screen`
-- full or over). A start zone instead (a kit/trigger_zone linked to play)
-- or beside it works as well.
-- [KIT_LOBBY_OUT_OF_PLAY] `out_of_play` (on by default): in the lobby and
-- over a player is out of play as one dead and waiting to respawn is (no
-- walking, no actions, their client spectating under the screen), their
-- body hidden from the others, not hit and in no zone; entered puts them
-- back where they were, for the game to place them (a teleport). Off for
-- a lobby that is a place in the world. [KIT_CLIENT_REACT] (9)
-- `keep_own_body` (off by default): out of play so, a player's own body stays
-- drawn for them where it stopped and their camera on it (no spectating: a
-- result card over their frozen bike), still hidden from the others.
-- [KIT_SCENE_PACKAGES] On the app root it is every scene's (its screens
-- too, on the root): a play whose value is a scene's name (a
-- kit/ui_scene_list's picked) takes the player there, onto its spawner of
-- players, and enters them as they arrive (again: the same scene once
-- more, where they are); without one, play enters them where they are. On
-- the root a player who comes into a scene another way is in the lobby.
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
	if now == "lobby" then
		c:emit("in_lobby", nil, by)
	end
end

return {
	version = 1,
	no_position = true,
	about = {
		group = "Game",
		what = "Each player's lobby, run and result, and their screens. out_of_play: in the lobby and the result, a player is out of play and hidden from the others. keep_own_body: their own body is still drawn for them, with the camera on it (a result card over their frozen bike).",
		keywords = "menu start round result card",
		inputs = {
			play = "The player who set it off starts a run (from the lobby or a result). Value: a scene to go to first.",
			again = "The player who set it off starts a run again (from a result, or restarts during a run).",
			lobby = "The player who set it off goes back to the lobby.",
			over = "Ends the player's run and shows their result.",
		},
		outputs = {
			entered = "A player's run started.",
			left = "A player's run ended: over, or back to the lobby.",
			in_lobby = "A player came into the lobby, or back to it. Link it to a lobby song's play.",
		},
		params = {
			lobby_screen = "A kit/ui_panel shown to a player while they are in the lobby.",
			over_screen = "A kit/ui_panel shown to a player with their run's result.",
			out_of_play = "In the lobby and the result a player is out of play and hidden from the others.",
			keep_own_body = "Out of play, a player's own body stays drawn for them with the camera on it.",
		},
	},
	params = {
		lobby_screen = {type = "entity", default = 0},
		over_screen = {type = "entity", default = 0},
		out_of_play = {type = "bool", default = true},
		keep_own_body = {type = "bool", default = false},
	},
	state = {states = {default = {}, per_player = true},
		-- [KIT_SCENE_PACKAGES] the scene a player's play is taking them to
		going = {default = {}}},
	inputs = {play = "any", again = "none", lobby = "none", over = "none"},
	outputs = {entered = "none", left = "none", in_lobby = "none"},
	on_join = function(c, by)
		if not c.player then
			return
		end
		local g = c.state.going[by]
		c.state.going[by] = nil
		set(c, by, g and g == c.player_scene and "playing" or "lobby")
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
			if type(value) == "string" and value ~= "" and
					value ~= c.player_scene then
				c.state.going[by] = value
				c:log(c:name(by), "goes to", value)
				c:teleport(nil, {scene = value})
				return
			end
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
