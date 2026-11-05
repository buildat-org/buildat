-- A timer: once started ("start", or at once with autostart) it signals
-- "tick" every `interval` seconds of game time, `repeats` times (0: until
-- "stop"), then "done". The ticks so far are drawn over it.
-- scope ([KIT] stage 7b's first part): "shared", one timer for all; or
-- "per_player", each player who starts it their own (their own ticks,
-- signalled as by them, a "stop" of theirs stopping only theirs); a start
-- by no player (autostart, the app) is the shared one's.
-- [KIT_CTF] "left": the seconds left, (repeats - ticks) * interval, at
-- its start and each tick (none without repeats), for a HUD's text;
-- [KIT_HUD_STYLE] "progress" beside it: 0 at its start to 1 at its end, for
-- a kit/ui_bar (a bar or a pie; its min 1 and max 0 to empty instead)
local function player_of(c, by)
	if c.params.scope == "per_player" and type(by) == "string" and
			by:match("^player:%d+$") then
		return by
	end
end

local function stop(c, player, why)
	if player then
		local per = c.state.per
		c:after(nil, "tick", {player = player})
		c:log("stopped for", c:name(player) .. ":", why, "after",
			per[player] or 0, "ticks")
		per[player] = nil
		return
	end
	c.state.running = false
	c:after()
	c:log("stopped:", why, "after", c.state.ticks, "ticks")
end

local function left(c, n)
	if c.params.repeats > 0 then
		c:emit("left", (c.params.repeats - n) * c.params.interval)
		c:emit("progress", n / c.params.repeats)
	end
end

local function start(c, player)
	left(c, 0)
	if player then
		c.state.per[player] = 0
		c:after(c.params.interval, "tick", {player = player})
	else
		c.state.running = true
		c.state.ticks = 0
		c:after(c.params.interval)
	end
end

return {
	version = 2,
	look = {shape = "box", size = 0.25, color = "#a060e0", text = "ticks"},
	params = {
		interval = {type = "number", default = 2, min = 0.1, max = 3600},
		repeats = {type = "number", default = 0, min = 0, max = 1000000},
		autostart = {type = "bool", default = false},
		scope = {type = "string", default = "shared",
			choices = {"shared", "per_player"}},
	},
	state = {
		running = {default = false, shared = true},
		ticks = {default = 0, shared = true},
		-- per_player: {["player:<id>"] = ticks} of those running
		per = {default = {}},
	},
	inputs = {start = "none", stop = "none"},
	outputs = {tick = "number", done = "none", left = "number",
		progress = "number"},
	on_start = function(c)
		if c.params.autostart then
			start(c, nil)
		end
	end,
	on_input = function(c, input, value, by)
		local player = player_of(c, by)
		if input == "stop" then
			if player and c.state.per[player] then
				stop(c, player, "by them")
			elseif not player and c.state.running then
				stop(c, nil, "by " .. c:name(by))
			end
			return
		end
		-- A start while it runs starts it over
		start(c, player)
		c:log("started by", c:name(by), "every", c.params.interval, "s",
			player and "(theirs)" or "")
	end,
	on_timer = function(c, name, player)
		local n
		if player then
			local per = c.state.per
			if not per[player] then
				return
			end
			per[player] = per[player] + 1
			n = per[player]
			c:log("tick", n, "for", c:name(player))
		else
			if not c.state.running then
				return
			end
			c.state.ticks = c.state.ticks + 1
			n = c.state.ticks
			c:log("tick", n)
		end
		c:emit("tick", n)
		left(c, n)
		if c.params.repeats > 0 and n >= c.params.repeats then
			stop(c, player, "its repeats done")
			c:emit("done")
		elseif player then
			c:after(c.params.interval, "tick", {player = player})
		else
			c:after(c.params.interval)
		end
	end,
}
