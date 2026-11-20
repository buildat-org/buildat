-- Brimstone Speedway's race control, on the starting grid (its place the
-- pole's, its yaw the way the grid faces), one in each scene: its `mode`
-- the scene's way to drive the track, each player's pick in the lobby (a
-- kit/lobby on the root: its scene list takes them to that scene; its
-- entered and left linked here by name):
-- **Time trial**: alone against the clock (a ghost: no other car meets
-- it, no weapons), `trial_laps` laps from a countdown on the pole; each
-- lap's time, the best lap kept (kept state, by name: play never resets
-- it, a builder's Clear kept state does) and the five best on `board`.
-- Every car in a time trial's scene is a ghost (c:body_var ghost: the
-- car's step meets no other).
-- **Race**: the players who pick it line up on the grid (frozen, their
-- grid panel shown: `grid_screen`); anyone there presses Start (its button
-- linked to start) and after a countdown everyone goes at once; `laps`
-- laps; the places by the order of finishing, each finisher's result card
-- showing the places so far (`result`, then the lobby's over); `time_out`
-- seconds after the winner the rest are out (DNF). Who picks Race while
-- one is on waits for the next.
-- Laps: every checkpoint (local/brim_checkpoint, linked to checkpoint: its
-- value its order) passed in order opens the lap on the car's body
-- (c:body_var lap_open, [KIT_BODY_VARS]); the car's own step then counts
-- the finish line as a lap (its event lap, linked here) on the server and
-- in its prediction alike, and this closes it again.
-- Weapons (races only): a crate (local/brim_crate's taken, linked to crate;
-- value the kind) arms the car with a gun (6 shots ahead), mines (3, dropped
-- behind: copies of the entity `mine`) or a ram boost (2.5 s, faster; a hit
-- on a car then hurts it); the fire key (its action "fire", Left Ctrl by
-- default; the left mouse button too: brim_race.client.lua) uses it: a
-- press counts up the car's body var fire, and the car's step says fire with
-- its heading (linked to fire here). Damage is Kit's
-- health (c:hurt; kit/game_rules not peaceful, its respawn on_signal): at 0
-- a wreck (on_died: an explosion, fire, debris, a scorch mark: a copy of
-- `scorch`), then 2 s later back on the road at the last checkpoint passed
-- (its own teleport) with full health.
-- The announcer (`announce`, to a kit/ui_text for everyone) calls the start,
-- the leader, the wrecks and the finish.
-- (4z37i) go, to each racer at GO (a trial's at its own): the run's song
-- linked from it (kit/music's play; the lobby's left its stop), so none
-- plays in the countdown or on the result.
-- (4z37h) The pause menu's Retry (`retry`, a kit/pause_menu_action to the
-- player, linked to the lobby's again): shown in a time trial and to a
-- racer alone on the grid or in a race, hidden otherwise (one player can't
-- restart a shared race); a lone racer's Retry ends the race at once, so
-- they are back on the grid. To lobby (the lobby's lobby) forfeits a race.
-- (4z37i (4)) Bots (Kit's driving bots, "bot:<id>": kit/bot_driver, added
-- from the pause menu) race as players do: each one in a race's scene rolls
-- onto the grid while it is open (the tick), waits for GO, counts in the
-- places and on the result card; one added during a race waits frozen where
-- it is for the next. No crates for them (no weapons, no Fire), no time
-- trials (no lap records), no lobby, no Retry: those are the players'. A
-- race of bots alone (every player finished or gone) runs on until it ends
-- or a player comes onto the grid: that ends it.
local PAINTS = 6
local WEAPONS = {gun = 6, mines = 3, boost = 1}
local NAMES = {gun = "Gun", mines = "Mines", boost = "Ram boost"}
local ORDINAL = {"1st", "2nd", "3rd"}

local function tenths(t)
	return string.format("%.1f", math.floor(t * 10 + 0.5) / 10)
end

local function clock(t)
	t = math.max(0, t)
	local m = math.floor(t / 60)
	return m > 0 and string.format("%d:%04.1f", m, t - m * 60) or tenths(t)
end

local function place(n)
	return ORDINAL[n] or n .. "th"
end

local function view(c, by)
	local r = c.state.runs[by]
	if not r then
		r = {}
		c.state.runs[by] = r
	end
	return r
end

local function checkpoints(c)
	return #(c.linked_in.checkpoint or {})
end

local function player_of(c, by)
	for _, p in ipairs(c.players or {}) do
		if p.by == by then
			return p
		end
	end
end

local function is_bot(by)
	return tostring(by):match("^bot:%d+$") ~= nil
end

local function say(c, text)
	c.state.said = text
	c.state.said_left = 3
	c:emit("announce", text)
end

-- A grid slot's place: staggered, 5.5 m behind the one before and 0.5 m to
-- its other side (a car's nose on the bumper of the one ahead)
local function slot(c, k)
	local a = (c.yaw or 0) * math.pi / 180
	local fx, fz = math.sin(a), math.cos(a)
	local back = (k - 1) * 5.5
	local side = (k % 2 == 1) and -0.5 or 0.5
	local p = c.pos
	return {p[1] - fx * back + fz * side, p[2], p[3] - fz * back - fx * side}
end

-- Retry shown to by or not
local function retry(c, by, on)
	if c.params.retry ~= 0 then
		c:send(c.params.retry, on and "show" or "hide", nil, by)
	end
end

-- The players racing (bots not)
local function people(c)
	local n = 0
	for _, b in ipairs(c.state.racers) do
		n = n + (is_bot(b) and 0 or 1)
	end
	return n
end

-- Retry to each racer: only one player racing alone may (bots or not)
local function retry_racers(c)
	for _, b in ipairs(c.state.racers) do
		if not is_bot(b) then
			retry(c, b, people(c) == 1)
		end
	end
end

local function set_open(c, by, r, want)
	want = want or nil
	if want ~= r.open then
		r.open = want
		c:body_var(by, "lap_open", want)
	end
end

local function show(c, by, r, note)
	-- (a bot has no screen)
	if is_bot(by) then
		return
	end
	if note then
		r.note, r.note_left = note, 2
	end
	note = (r.note_left or 0) > 0 and r.note or nil
	local line
	if r.mode == "trial" then
		local best = c.state.bests[c:name(by)]
		line = "Lap " .. math.min(r.lap or 1, c.params.trial_laps) .. "/" ..
				c.params.trial_laps .. "   Time " .. clock(r.t or 0) ..
				(best and "   Record " .. tenths(best) or "")
	elseif r.mode == "race" then
		local ph = c.state.phase
		if ph == "grid" then
			line = "On the grid: " .. #c.state.racers .. " car" ..
					(#c.state.racers == 1 and "" or "s") .. ". Start when ready."
		else
			line = "Lap " .. math.min(r.lap or 1, c.params.laps) .. "/" ..
					c.params.laps .. "   Pos " .. (r.pos or 1) .. "/" ..
					#c.state.racers .. "   Time " .. clock(c.state.t) ..
					(r.weapon and "   " .. NAMES[r.weapon] .. " x" .. r.ammo or "")
		end
	else
		line = ""
	end
	c:emit("hud", line .. (note and "   " .. note or ""), by)
end

-- The board: the five best laps, "1. name 23.4|2. ..."
local function board(c)
	local all = {}
	for name, t in pairs(c.state.bests) do
		all[#all + 1] = {name, t}
	end
	table.sort(all, function(a, b)
		return a[2] < b[2] or a[2] == b[2] and a[1] < b[1]
	end)
	local lines = {}
	for i = 1, math.min(5, #all) do
		lines[i] = i .. ". " .. all[i][1] .. " " .. tenths(all[i][2])
	end
	local text = table.concat(lines, "|")
	if text ~= c.state.board then
		c.state.board = text
		c:emit("board", text)
	end
end

local function racing(c, by)
	for _, b in ipairs(c.state.racers) do
		if b == by then
			return true
		end
	end
	return false
end

local function drop_racer(c, by)
	for i, b in ipairs(c.state.racers) do
		if b == by then
			table.remove(c.state.racers, i)
			return
		end
	end
end

-- The places now: laps, then checkpoints, then who got there first
local function rank(c)
	local list = {}
	for _, by in ipairs(c.state.racers) do
		list[#list + 1] = by
	end
	local runs = c.state.runs
	table.sort(list, function(a, b)
		local ra, rb = runs[a] or {}, runs[b] or {}
		local fa, fb = ra.done or 1e9, rb.done or 1e9
		if fa ~= fb then
			return fa < fb
		end
		local pa = (ra.lap or 1) * 100 + (ra.next or 1)
		local pb = (rb.lap or 1) * 100 + (rb.next or 1)
		if pa ~= pb then
			return pa > pb
		end
		return (ra.at or 0) < (rb.at or 0) or (ra.at or 0) == (rb.at or 0) and a < b
	end)
	for i, by in ipairs(list) do
		view(c, by).pos = i
	end
	if list[1] and list[1] ~= c.state.leader and c.state.phase == "running" then
		if c.state.leader then
			say(c, c:name(list[1]) .. " takes the lead! The yard loves a climber!")
		end
		c.state.leader = list[1]
	end
end

-- The result card's text for the race so far
local function standings(c)
	local lines = {}
	for i, f in ipairs(c.state.finished) do
		lines[#lines + 1] = place(i) .. "  " .. f[1] .. "  " .. clock(f[2])
	end
	return lines
end

local function results(c)
	local lines = standings(c)
	for i, f in ipairs(c.state.finished) do
		if f[3] then
			c:emit("result", "You: " .. place(i) .. "|" .. table.concat(lines, "|"), f[3])
		end
	end
end

local function clear_weapon(c, by, r)
	r.weapon, r.ammo = nil, nil
	if r.boosted then
		r.boosted = nil
		c:body_var(by, "boost", nil)
	end
end

local race_over

-- A run's start for the player (the lobby's entered; a bot's: the tick's)
local function enter(c, by)
	local r = view(c, by)
	local p = player_of(c, by)
	r.mode = c.params.mode
	r.lap, r.next, r.last, r.t, r.done, r.at = 1, 1, 0, 0, nil, 0
	r.wrecked = nil
	clear_weapon(c, by, r)
	set_open(c, by, r, false)
	c:body_var(by, "wreck", nil)
	-- (the car's client part clears the tyre marks on a new run)
	r.run = (r.run or 0) + 1
	c:body_var(by, "run", r.run)
	if r.mode == "race" then
		-- (4z37i (4)) a race of bots alone: over for a player who comes
		if c.state.phase ~= "grid" and not is_bot(by) and people(c) == 0 then
			race_over(c, "a player comes: only bots on the track")
		end
		if c.state.phase ~= "grid" then
			-- (a race on: back to the lobby to wait)
			r.mode = nil
			show(c, by, r)
			c:emit("hud", "A race is on: the next one starts from the lobby.", by)
			c:send(c.params.lobby, "lobby", nil, by)
			return
		end
		if not racing(c, by) then
			c.state.racers[#c.state.racers + 1] = by
		end
		local k = #c.state.racers
		r.slot = k
		c:body_var(by, "ghost", nil)
		c:body_var(by, "paint", (k - 1) % PAINTS + 1)
		c:speed(by, 0)
		c:teleport(slot(c, k), {yaw = c.yaw or 0})
		if c.params.grid_screen ~= 0 and not is_bot(by) then
			c:send(c.params.grid_screen, "show", nil, by)
		end
		c:log(c:name(by), "is on the grid, slot", k)
		say(c, c:name(by) .. " rolls onto the grid. Fresh meat!")
		for _, b in ipairs(c.state.racers) do
			show(c, b, view(c, b))
		end
		retry_racers(c)
	else
		r.mode = "trial"
		r.count = 3
		c:body_var(by, "ghost", true)
		c:body_var(by, "paint", p and (p.id % PAINTS) + 1 or 1)
		c:speed(by, 0)
		c:teleport(slot(c, 1), {yaw = c.yaw or 0})
		c:log(c:name(by), "starts a time trial")
		show(c, by, r, "3")
		retry(c, by, true)
	end
end

-- The race over: the grid open again
function race_over(c, why)
	c:log("the race is over:", why)
	-- (ended in its countdown: none to GO)
	c:after(nil, "count")
	for _, by in ipairs(c.state.racers) do
		local r = view(c, by)
		if not r.done and not is_bot(by) then
			c:emit("result", "Out of time: DNF|" .. table.concat(standings(c), "|"), by)
			c:send(c.params.lobby, "over", nil, by)
		end
		r.mode = nil
		clear_weapon(c, by, r)
		set_open(c, by, r, false)
		c:speed(by, 1)
	end
	for _, id in ipairs(c.made or {}) do
		c:remove(id)
	end
	c.state.racers, c.state.finished = {}, {}
	c.state.phase, c.state.leader, c.state.first_blood = "grid", nil, nil
	c.state.mines = {}
end

local function finish_race(c, by, r)
	r.done = #c.state.finished + 1
	c.state.finished[#c.state.finished + 1] = {c:name(by), c.state.t, by}
	c:log(c:name(by), "finished", place(r.done), "in", clock(c.state.t))
	if r.done == 1 then
		say(c, c:name(by) .. " wins it! Chrome, fire and glory!")
		c.state.out_at = c.state.t + c.params.time_out
	else
		say(c, c:name(by) .. " limps home " .. place(r.done) .. ".")
	end
	clear_weapon(c, by, r)
	set_open(c, by, r, false)
	if not is_bot(by) then
		c:send(c.params.lobby, "over", nil, by)
	end
	results(c)
	c:emit("finished", r.done, by)
	-- (those who finished and left are no longer racers)
	local on = 0
	for _, b in ipairs(c.state.racers) do
		on = on + (view(c, b).done and 0 or 1)
	end
	if on == 0 then
		race_over(c, "everyone finished")
	end
end

local function lap(c, by, r)
	if not r.open then
		c:log(c:name(by), "crossed the line: no lap, checkpoint", r.next, "not passed")
		return
	end
	set_open(c, by, r, false)
	r.next = 1
	if r.mode == "trial" then
		local t = r.t - (r.lap_at or 0)
		r.lap_at = r.t
		local name = c:name(by)
		local best = not c.state.bests[name] or t < c.state.bests[name]
		if best then
			c.state.bests[name] = t
		end
		r.best_lap = math.min(r.best_lap or t, t)
		c:log(name, "lap", r.lap, "in", tenths(t), best and "(record)" or "")
		c:emit("lap_time", t, by)
		board(c)
		if r.lap >= c.params.trial_laps then
			c:emit("result", "Time " .. clock(r.t) .. "|Best lap " ..
					tenths(r.best_lap) .. "|Record " .. tenths(c.state.bests[name]) ..
					(best and "|A new record!" or ""), by)
			c:emit("finished", r.t, by)
			c:log(name, "finished the trial in", clock(r.t))
			r.mode = nil
			c:send(c.params.lobby, "over", nil, by)
			return
		end
		r.lap = r.lap + 1
		show(c, by, r, "Lap " .. tenths(t) .. (best and ", a record!" or ""))
		return
	end
	c:log(c:name(by), "completed lap", r.lap)
	if r.lap >= c.params.laps then
		return finish_race(c, by, r)
	end
	r.lap = r.lap + 1
	if r.lap == c.params.laps then
		show(c, by, r, "Last lap!")
	end
	rank(c)
end

-- Back on the road where they wrecked: full health (the game rules'
-- respawn is on_signal: c:respawn_waiting(), the "wrecked" timer's), at the
-- last checkpoint passed (the grid's slot before any)
local function back(c, by, r)
	r.wrecked = nil
	c:body_var(by, "wreck", nil)
	if (r.last or 0) > 0 then
		for _, id in ipairs(c.linked_in.checkpoint or {}) do
			c:send(id, "respawn", r.last, by)
		end
	else
		c:teleport(slot(c, r.slot or 1), {yaw = c.yaw or 0})
	end
	c:log(c:name(by), "back on the road at checkpoint", r.last or 0)
end

local function effects_wreck(c, at)
	local up = {at[1], at[2] + 0.6, at[3]}
	-- The blast, the fire, the debris
	c:effect{at = up, count = 60, shape = "round", colors = {"#ffe14a",
		"#ff7a12", "#ff3b0a"}, speed_min = 4, speed_max = 12, gravity = -2,
		drag = 3, ttl_min = 0.3, ttl_max = 0.8, size_min = 0.3, size_max = 0.9,
		grow = 1.5, fade = 0.6, light_time = 0.6, light_color = "#ffa040",
		light_range = 16, light_brightness = 4}
	c:effect{at = up, count = 40, shape = "round", colors = {"#ff9a1a",
		"#ffd040", "#c02008", "#3a3030"}, speed_min = 0.5, speed_max = 2,
		gravity = -3, ttl_min = 1, ttl_max = 2.6, size_min = 0.4,
		size_max = 1, grow = 0.6, fade = 0.5, box = 1.6}
	c:effect{at = up, count = 24, shape = "square", colors = {"#2a2420",
		"#d9dee4", "#5a4a40"}, speed_min = 5, speed_max = 11, gravity = 14,
		ttl_min = 0.6, ttl_max = 1.2, size_min = 0.12, size_max = 0.3,
		spin = 720}
	if c.params.scorch ~= 0 then
		local id = c:spawn{entity = c.params.scorch, pos = {at[1], at[2] + 0.02, at[3]}}
		c.state.scorches[#c.state.scorches + 1] = id
		if #c.state.scorches > 8 then
			c:remove(table.remove(c.state.scorches, 1))
		end
	end
end

local function fire(c, by, r, p, heading)
	if not r.weapon or not p then
		return
	end
	local a = (tonumber(heading) or 0) * math.pi / 180
	local fx, fz = math.sin(a), math.cos(a)
	local at = p.pos
	if r.weapon == "gun" then
		local best, bd
		for _, q in ipairs(c.players or {}) do
			local qb = q.by
			if q.id ~= p.id and racing(c, qb) and q.pos and not q.away and
					not view(c, qb).wrecked then
				local dx, dz = q.pos[1] - at[1], q.pos[3] - at[3]
				local ahead = dx * fx + dz * fz
				local across = math.abs(dx * fz - dz * fx)
				if ahead > 0 and ahead < 45 and across < 1.6 + ahead * 0.08 and
						(not bd or ahead < bd) then
					best, bd = q, ahead
				end
			end
		end
		c:effect{at = {at[1] + fx * 2.6, at[2] + 0.7, at[3] + fz * 2.6},
			dir = {fx, 0, fz}, spread = 3, count = 10, shape = "square",
			colors = {"#fff27a", "#ffb030"}, speed_min = 50, speed_max = 70,
			gravity = 0, ttl_min = 0.12, ttl_max = 0.3, size_min = 0.12,
			size_max = 0.2, light_time = 0.08, light_color = "#ffe080",
			light_range = 6}
		if best then
			c:hurt(best.id, {amount = c.params.gun_damage, type = "gun"})
			c:effect{at = {best.pos[1], best.pos[2] + 0.8, best.pos[3]},
				dir = {-fx, 0.5, -fz}, spread = 60, count = 14, shape = "square",
				colors = {"#ffffff", "#ffd040", "#ff6010"}, speed_min = 3,
				speed_max = 9, gravity = 10, ttl_min = 0.2, ttl_max = 0.5,
				size_min = 0.08, size_max = 0.16}
			c:log(c:name(by), "shoots", best.name)
		end
	elseif r.weapon == "mines" and c.params.mine ~= 0 then
		-- (its zone's 2x2 cells from its place: their middle on the car's line)
		local pos = {at[1] - fx * 3.4 - 0.5, at[2], at[3] - fz * 3.4 - 0.5}
		local id = c:spawn{entity = c.params.mine, pos = pos}
		if id then
			c.state.mines[tostring(id):match("%d+")] = pos
			c:send(id, "arm")
			c:log(c:name(by), "drops a mine", id, "at", math.floor(pos[1] * 10) / 10,
					math.floor(pos[3] * 10) / 10)
		end
	elseif r.weapon == "boost" then
		r.boosted = true
		c:body_var(by, "boost", true)
		c:after(2.5, "unboost", {player = p.id})
		c:log(c:name(by), "boosts")
	end
	r.ammo = r.ammo - 1
	if r.ammo <= 0 then
		r.weapon, r.ammo = nil, nil
	end
	show(c, by, r)
end

return {
	version = 1,
	players = true,
	linked_in = true,
	-- (the grid's pole and the way it faces)
	gizmo = {shape = "box", size = 0.3, color = "#f4d35e"},
	about = {
		group = "Game",
		what = "Brimstone Speedway's race control on the starting grid: time trials, races from a grid and a countdown, laps by checkpoints, the places, weapons, wrecks.",
		inputs = {
			entered = "A player's run started (kit/lobby's entered).",
			left = "A player's run ended (kit/lobby's left).",
			start = "Starts the race on the grid: a countdown, then everyone goes.",
			checkpoint = "A checkpoint passed by the player. Value: its order (1...).",
			lap = "The player's car crossed the finish line with every checkpoint passed.",
			fire = "The player fires what their car carries. Value: the car's heading (degrees).",
			crate = "The player took a crate. Value: gun, mines, boost or any.",
			mine = "A mine touched by the player. Value: the mine.",
			ram = "The player's boosted car rammed another. Value: the other's by.",
			back = "(its own: a wrecked car back on the road, as its player)",
		},
		outputs = {
			hud = "The player's line: lap, place, time, weapon.",
			announce = "The announcer's line for everyone (\"\" after a while).",
			result = "The player's result card: their place and the places so far, or their trial's times.",
			board = "The five best laps as they change. Value: \"1. name 23.4|2. ...\".",
			lap_time = "A time trial's lap. Value: its seconds.",
			finished = "A player finished. Value: their place (a race) or time (a trial).",
			go = "The player's run is off: the race's GO, or their trial's.",
		},
	},
	params = {
		mode = {type = "string", default = "race", choices = {"race", "trial"}},
		laps = {type = "number", default = 3, min = 1, max = 50},
		trial_laps = {type = "number", default = 3, min = 1, max = 50},
		time_out = {type = "number", default = 45, min = 5, max = 600},
		countdown = {type = "number", default = 3, min = 0, max = 10},
		lobby = {type = "entity", default = 0},
		grid_screen = {type = "entity", default = 0},
		mine = {type = "entity", default = 0},
		scorch = {type = "entity", default = 0},
		retry = {type = "entity", default = 0},
		gun_damage = {type = "number", default = 3, min = 0, max = 100},
		mine_damage = {type = "number", default = 9, min = 0, max = 100},
		ram_damage = {type = "number", default = 6, min = 0, max = 100},
	},
	state = {
		runs = {default = {}, per_player = true},
		bests = {default = {}, kept = true},
		board = {default = false},
		phase = {default = "grid"},
		racers = {default = {}},
		finished = {default = {}},
		t = {default = 0},
		count = {default = 0},
		mines = {default = {}},
		scorches = {default = {}},
		dice = {default = 0},
		said_left = {default = 0},
	},
	actions = {{name = "fire", key = "Left Ctrl", label = "Fire"}},
	inputs = {entered = "none", left = "none",
		start = "none", checkpoint = "number", lap = "none", fire = "number",
		crate = "string", mine = "entity", ram = "string", back = "none"},
	outputs = {hud = "string", announce = "string", result = "string",
		board = "string", lap_time = "number", finished = "number", go = "none"},
	on_start = function(c)
		c:after(0.1, "tick")
		board(c)
	end,
	on_join = function(c, by)
		local r = view(c, by)
		r.mode = nil
		show(c, by, r)
	end,
	on_timer = function(c, name, player)
		if name == "unboost" then
			local by = "player:" .. tostring(player)
			local r = view(c, by)
			r.boosted = nil
			c:body_var(by, "boost", nil)
			show(c, by, r)
			return
		elseif name == "wrecked" then
			-- simplified: c:respawn_waiting() puts every wrecked car back,
			-- so one wrecked a moment after another waits less than 2 s;
			-- a respawn per player in Kit would make each wait its own.
			-- (each back as that player: a run by them, for the teleport)
			c:respawn_waiting()
			for by, r in pairs(c.state.runs) do
				if r.wrecked then
					c:send(c.id, "back", nil, by)
				end
			end
			return
		elseif name == "count" then
			local n = c.state.count
			if n > 0 then
				say(c, n .. "...")
				c.state.count = n - 1
				c:after(1, "count")
				return
			end
			say(c, "GO! Eat dirt, scrap heaps!")
			c.state.phase, c.state.t = "running", 0
			for _, by in ipairs(c.state.racers) do
				c:speed(by, 1)
				view(c, by).at = 0
				c:emit("go", nil, by)
			end
			rank(c)
			return
		end
		-- The tick: the clocks, the lines
		local st = c.state
		if st.phase == "running" then
			st.t = st.t + 0.1
			if st.out_at and st.t >= st.out_at then
				st.out_at = nil
				race_over(c, "out of time")
			end
		end
		-- (4z37i (4)) racers no longer listed (a bot removed): out
		local listed = {}
		for _, p in ipairs(c.players or {}) do
			listed[p.by] = true
		end
		for i = #st.racers, 1, -1 do
			if not listed[st.racers[i]] then
				c:log(st.racers[i], "is gone: out of the race")
				table.remove(st.racers, i)
			end
		end
		-- The bots here: onto an open grid, else frozen till the next race
		for _, p in ipairs(c.players or {}) do
			if p.bot and not p.away and c.params.mode == "race" and
					not racing(c, p.by) then
				if st.phase == "grid" then
					c:send(c.id, "entered", nil, p.by)
				else
					c:speed(p.by, 0)
				end
			end
		end
		if st.said_left > 0 then
			st.said_left = st.said_left - 0.1
			if st.said_left <= 0 then
				c:emit("announce", "")
			end
		end
		for _, p in ipairs(c.players or {}) do
			local by = p.by
			local r = c.state.runs[by]
			if r and r.mode and (not p.here or p.away) then
				-- (gone: out of the race)
				if r.mode == "race" then
					drop_racer(c, by)
				end
				r.mode = nil
			elseif r and r.mode == "trial" then
				if r.count then
					r.count = r.count - 0.1
					if r.count <= 0 then
						r.count, r.t, r.lap_at = nil, 0, 0
						c:speed(by, 1)
						show(c, by, r, "GO!")
						c:emit("go", nil, by)
					else
						show(c, by, r, tostring(math.ceil(r.count)))
					end
				else
					r.t = r.t + 0.1
					r.note_left = (r.note_left or 0) - 0.1
					show(c, by, r)
				end
			elseif r and r.mode == "race" then
				r.note_left = (r.note_left or 0) - 0.1
				show(c, by, r)
			end
		end
		if st.phase == "running" and #st.racers == 0 then
			race_over(c, "nobody left")
		end
		c:after(0.1, "tick")
	end,
	on_died = function(c, player, by, kind)
		local pb = "player:" .. tostring(player)
		for _, p in ipairs(c.players or {}) do
			if p.id == player then
				pb = p.by
			end
		end
		local r = c.state.runs[pb]
		if not (r and r.mode == "race") or r.wrecked then
			return
		end
		r.wrecked = true
		clear_weapon(c, pb, r)
		c:body_var(pb, "wreck", true)
		local p = player_of(c, pb)
		if p and p.pos then
			effects_wreck(c, p.pos)
		end
		local killer = type(by) == "string" and (by:match("^player:") or is_bot(by)) and
				by ~= pb and
				c:name(by) or nil
		if not c.state.first_blood then
			c.state.first_blood = true
			say(c, killer and killer .. " draws first blood! " .. c:name(pb) ..
					" is a hood ornament now!" or c:name(pb) .. " wrecks! First blood to the track!")
		else
			say(c, killer and killer .. " sends " .. c:name(pb) .. " to the scrapyard!" or
					c:name(pb) .. " leaves a mark on the dirt!")
		end
		c:log(c:name(pb), "wrecked by", tostring(kind), killer or "")
		c:after(2, "wrecked", {player = player})
	end,
	-- The fire key: the car's body var fire counted up (its step fires
	-- along its heading)
	on_action = function(c, name, phase, value, by)
		if name ~= "fire" or phase ~= "pressed" or type(by) ~= "string" or
				not by:match("^player:%d+$") then
			return
		end
		local r = view(c, by)
		r.shots = (r.shots or 0) + 1
		c:log(c:name(by), "presses fire")
		c:body_var(by, "fire", r.shots)
	end,
	on_input = function(c, input, value, by)
		if type(by) ~= "string" or not (by:match("^player:%d+$") or is_bot(by)) then
			return
		end
		local r = view(c, by)
		if input == "entered" then
			return enter(c, by)
		elseif input == "left" then
			if r.mode == "race" then
				drop_racer(c, by)
				c:speed(by, 1)
				if c.state.phase ~= "grid" and #c.state.racers == 0 then
					-- (the last one out: over now, a Retry's entered next
					-- finds the grid open)
					race_over(c, "nobody left")
				elseif c.state.phase == "running" then
					rank(c)
				end
				retry_racers(c)
			end
			retry(c, by, false)
			if c.params.grid_screen ~= 0 then
				c:send(c.params.grid_screen, "hide", nil, by)
			end
			clear_weapon(c, by, r)
			set_open(c, by, r, false)
			r.mode = nil
			return
		elseif input == "back" then
			return back(c, by, r)
		elseif input == "start" then
			if c.state.phase ~= "grid" or not racing(c, by) or is_bot(by) then
				return
			end
			c.state.phase = "countdown"
			c.state.count = c.params.countdown
			c.state.finished = {}
			for _, b in ipairs(c.state.racers) do
				if c.params.grid_screen ~= 0 then
					c:send(c.params.grid_screen, "hide", nil, b)
				end
			end
			c:log(c:name(by), "starts the race:", #c.state.racers, "cars")
			say(c, "Engines hot! The yard gates are open!")
			c:after(1, "count")
			return
		end
		if not r.mode or r.done then
			return
		end
		if input == "checkpoint" then
			local n = tonumber(value) or 0
			if n ~= r.next then
				return
			end
			r.next, r.last, r.at = n + 1, n, c.state.t
			local all = checkpoints(c)
			c:log(c:name(by), "passed checkpoint", n, "of", all)
			if r.next > all then
				set_open(c, by, r, true)
			end
			if r.mode == "race" then
				rank(c)
			end
			show(c, by, r, "Checkpoint " .. n .. "/" .. all)
		elseif input == "lap" then
			lap(c, by, r)
		elseif r.mode ~= "race" or c.state.phase ~= "running" or r.wrecked then
			return
		elseif input == "crate" then
			if is_bot(by) then
				return
			end
			local kind = WEAPONS[value] and value
			if not kind then
				local all = {"gun", "mines", "boost"}
				c.state.dice = c.state.dice + 1
				kind = all[c.state.dice % 3 + 1]
			end
			clear_weapon(c, by, r)
			r.weapon, r.ammo = kind, WEAPONS[kind]
			c:log(c:name(by), "picks up", kind)
			show(c, by, r, NAMES[kind] .. "!")
		elseif input == "fire" then
			fire(c, by, r, player_of(c, by), value)
		elseif input == "mine" then
			-- (an entity value: its id, or "entity:<id>")
			local key = tostring(value):match("%d+")
			local pos = key and c.state.mines[key]
			if not pos then
				c:log("a mine not of this race:", tostring(value))
				return
			end
			c.state.mines[key] = nil
			c:remove(tonumber(key))
			c:hurt(tonumber(by:match("%d+")), {amount = c.params.mine_damage, type = "mine"})
			c:effect{at = {pos[1] + 0.5, pos[2] + 0.4, pos[3] + 0.5}, count = 40, shape = "round",
				colors = {"#ffe14a", "#ff7a12", "#5a5050"}, speed_min = 3,
				speed_max = 10, gravity = -1, drag = 3, ttl_min = 0.3,
				ttl_max = 0.9, size_min = 0.25, size_max = 0.7, grow = 1,
				light_time = 0.4, light_color = "#ffa040", light_range = 12,
				light_brightness = 3}
			c:log(c:name(by), "hits a mine")
		elseif input == "ram" then
			local other = tostring(value)
			if not racing(c, other) or view(c, other).wrecked or
					(r.rammed_at or -9) > c.state.t - 0.5 then
				return
			end
			r.rammed_at = c.state.t
			local q = player_of(c, other)
			if q then
				c:hurt(q.id, {amount = c.params.ram_damage, type = "ram"})
				c:log(c:name(by), "rams", c:name(other))
			end
		end
	end,
}
