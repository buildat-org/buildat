-- Brimstone Stunts' race control, on the starting grid (its place the
-- pole's, its yaw the way the grid faces), one in each scene: its `mode`
-- the scene's way to drive the track, each player's pick in the lobby (a
-- kit/lobby on the root: its scene list takes them to that scene; its
-- entered and left linked here by name):
-- **Time trial**: alone against the clock (a ghost: no other car meets
-- it, no weapons), `trial_laps` laps from a countdown on the pole.
-- [KIT_RECORDS] Its clock a kit/stopwatch's (go starts it, countdown puts it
-- at 0, split takes a lap's time, stop the whole trial's; they come back on
-- lap_clock and trial_clock), the lap records a kit/records' (the
-- stopwatch's lap to its time: the best lap by name, kept state, and the
-- board; its best and new_best back on record and new_record): each lap's
-- note, the result card once its record is back. Notes go to `note` (a
-- kit/ui_text that clears itself).
-- Every car in a time trial's scene is a ghost (c:body_var ghost: the
-- car's step meets no other).
-- **Race**: the players who pick it line up on the grid (frozen, their
-- grid panel shown: `grid_screen`); anyone there presses Start (its button
-- linked to start) and after a countdown everyone goes at once; `laps`
-- laps; the places by the order of finishing, each finisher's result card
-- showing the places so far (`result`, then the lobby's over); `time_out`
-- seconds after the winner the rest are out (DNF). Who picks Race while
-- one is on waits for the next.
-- Laps: every checkpoint (kit/checkpoint, its passed linked to checkpoint:
-- its value its order; a pass out of order it does not send) passed in
-- order opens the lap on the car's body
-- (c:body_var lap_open, [KIT_BODY_VARS]); the car's own step then counts
-- the finish line as a lap (its event lap, linked here) on the server and
-- in its prediction alike, and this closes it again.
-- [KIT_TEMPLATE_CLEANUP] Weapons are stunt_weapons' (races only): this arms
-- a racer's car there at GO and back on the road (arm), disarms it at a
-- wreck, the finish, a leave or a new run (disarm), and says over as the
-- race ends. Damage is Kit's health (kit/game_rules not peaceful, its
-- respawn on_signal): at 0 a wreck (on_died: an explosion, fire, debris, a
-- scorch mark: a copy of `scorch`), then `wreck_wait` s later (each wreck
-- its own wait) back on the road at the last checkpoint passed (its
-- respawn) with full health.
-- The announcer (`announce`, to a kit/ui_text for everyone) calls the start,
-- the leader, the wrecks and the finish. Its lines and the HUD's are params
-- (cat hud), {word}s in them filled in (fill()): {name} a player's, {killer}
-- a wrecker's, {place} 1st..., {n} a number, {time} a clock.
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
-- it is for the next. No crates for them (stunt_weapons'), no time trials
-- (no lap records), no lobby, no Retry: those are the players'. A race of
-- bots alone (every player finished or gone) runs on until it ends or a
-- player comes onto the grid: that ends it.
local PAINTS = 6
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

-- A text param with its {word}s from vars (one not given stays as written)
local function fill(c, param, vars)
	return (tostring(c.params[param]):gsub("{(%w+)}", function(k)
		local v = vars and vars[k]
		return v ~= nil and tostring(v) or nil
	end))
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

-- (the announcer's kit/ui_text clears it: its clear_after)
local function say(c, param, vars)
	c:emit("announce", fill(c, param, vars))
end

-- A grid slot's place: staggered, `grid_gap` m behind the one before and
-- 0.5 m to its other side (a car's nose on the bumper of the one ahead)
local function slot(c, k)
	local a = (c.yaw or 0) * math.pi / 180
	local fx, fz = math.sin(a), math.cos(a)
	local back = (k - 1) * c.params.grid_gap
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
	if r.mode == "trial" then
		-- (the time and record are the stopwatch's and the records' texts)
		c:emit("hud", fill(c, "hud_trial", {lap = math.min(r.lap or 1,
				c.params.trial_laps), laps = c.params.trial_laps}), by)
		if note then
			c:emit("note", note, by)
		end
		return
	end
	if note then
		r.note, r.note_left = note, 2
	end
	note = (r.note_left or 0) > 0 and r.note or nil
	local line
	if r.mode == "race" then
		local n = #c.state.racers
		if c.state.phase == "grid" then
			line = fill(c, "hud_grid", {cars = n .. " car" .. (n == 1 and "" or "s")})
		else
			line = fill(c, "hud_race", {lap = math.min(r.lap or 1, c.params.laps),
				laps = c.params.laps, pos = r.pos or 1, cars = n,
				time = clock(c.state.t)})
		end
	else
		line = ""
	end
	c:emit("hud", line .. (note and "   " .. note or ""), by)
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
			say(c, "say_lead", {name = c:name(list[1])})
		end
		c.state.leader = list[1]
	end
end

-- The result card's text for the race so far
local function standings(c)
	local lines = {}
	for i, f in ipairs(c.state.finished) do
		lines[#lines + 1] = fill(c, "result_line", {place = place(i), name = f[1],
			time = clock(f[2])})
	end
	return lines
end

local function results(c)
	local lines = standings(c)
	for i, f in ipairs(c.state.finished) do
		if f[3] then
			c:emit("result", fill(c, "result_place", {place = place(i)}) .. "|" ..
					table.concat(lines, "|"), f[3])
		end
	end
end

local race_over

-- A run's start for the player (the lobby's entered; a bot's: the tick's)
local function enter(c, by)
	local r = view(c, by)
	local p = player_of(c, by)
	r.mode = c.params.mode
	r.lap, r.next, r.last, r.done, r.at = 1, 1, 0, nil, 0
	r.finishing, r.lap_t, r.total, r.new, r.best_lap = nil, nil, nil, nil, nil
	r.wrecked = nil
	c:emit("disarm", nil, by)
	set_open(c, by, r, false)
	c:body_var(by, "wreck", nil)
	-- (the checkpoints' progress: one reset does all, they share it)
	local cps = c.linked_in.checkpoint or {}
	if cps[1] then
		c:send(cps[1], "reset", nil, by)
	end
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
			c:emit("hud", fill(c, "hud_busy"), by)
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
		say(c, "say_grid", {name = c:name(by)})
		for _, b in ipairs(c.state.racers) do
			show(c, b, view(c, b))
		end
		retry_racers(c)
	else
		r.mode = "trial"
		r.count = c.params.countdown
		-- (its countdown a second a step; none: GO at once)
		c:after(r.count > 0 and 1 or 0, "trial", {player = by})
		c:emit("countdown", nil, by)
		c:body_var(by, "ghost", true)
		c:body_var(by, "paint", p and (p.id % PAINTS) + 1 or 1)
		c:speed(by, 0)
		c:teleport(slot(c, 1), {yaw = c.yaw or 0})
		c:log(c:name(by), "starts a time trial")
		if r.count > 0 then
			show(c, by, r, fill(c, "note_count", {n = r.count}))
		end
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
			c:emit("result", fill(c, "result_dnf") .. "|" ..
					table.concat(standings(c), "|"), by)
			c:send(c.params.lobby, "over", nil, by)
		end
		r.mode = nil
		set_open(c, by, r, false)
		c:speed(by, 1)
	end
	-- (the weapons: every car disarmed, the mines gone; the scorch marks)
	c:emit("over")
	for _, id in ipairs(c.made or {}) do
		c:remove(id)
	end
	c.state.racers, c.state.finished = {}, {}
	c.state.phase, c.state.leader, c.state.first_blood = "grid", nil, nil
end

local function finish_race(c, by, r)
	r.done = #c.state.finished + 1
	c.state.finished[#c.state.finished + 1] = {c:name(by), c.state.t, by}
	c:log(c:name(by), "finished", place(r.done), "in", clock(c.state.t))
	if r.done == 1 then
		say(c, "say_win", {name = c:name(by)})
		c.state.out_at = c.state.t + c.params.time_out
	else
		say(c, "say_home", {name = c:name(by), place = place(r.done)})
	end
	c:emit("disarm", nil, by)
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
		-- (its time and record come back: lap_clock, record)
		r.lap_n = r.lap
		c:emit("split", nil, by)
		if r.lap >= c.params.trial_laps then
			r.mode, r.finishing = nil, true
			c:emit("stop", nil, by)
			return
		end
		r.lap = r.lap + 1
		show(c, by, r)
		return
	end
	c:log(c:name(by), "completed lap", r.lap)
	if r.lap >= c.params.laps then
		return finish_race(c, by, r)
	end
	r.lap = r.lap + 1
	if r.lap == c.params.laps then
		show(c, by, r, fill(c, "note_last"))
	end
	rank(c)
end

-- [KIT_RECORDS] A trial's lap with its time (the stopwatch's) and record
-- (the records' best): its note, or after the last the result card
local function lap_done(c, by, r, record)
	local t, new = r.lap_t, r.new
	r.lap_t, r.new = nil, nil
	local name = c:name(by)
	r.best_lap = math.min(r.best_lap or t, t)
	c:log(name, "lap", r.lap_n, "in", tenths(t), new and "(record)" or "")
	c:emit("lap_time", t, by)
	if not r.finishing then
		show(c, by, r, fill(c, new and "note_record" or "note_lap", {time = tenths(t)}))
		return
	end
	r.finishing = nil
	local total = r.total or 0
	c:emit("result", fill(c, "result_trial", {time = clock(total),
		best = tenths(r.best_lap), record = tenths(record or r.best_lap)}) ..
		(new and "|" .. fill(c, "result_new") or ""), by)
	c:emit("finished", total, by)
	c:log(name, "finished the trial in", clock(total))
	c:send(c.params.lobby, "over", nil, by)
end

-- Back on the road where they wrecked: full health (the game rules'
-- respawn is on_signal: c:respawn_waiting(by), the "wrecked" timer's), at
-- the last checkpoint passed (each one told: theirs puts them there; the
-- grid's slot before any); armed again while the race runs
local function back(c, by, r)
	r.wrecked = nil
	c:body_var(by, "wreck", nil)
	if (r.last or 0) > 0 then
		for _, id in ipairs(c.linked_in.checkpoint or {}) do
			c:send(id, "respawn", nil, by)
		end
	else
		c:teleport(slot(c, r.slot or 1), {yaw = c.yaw or 0})
	end
	if r.mode == "race" and not r.done and c.state.phase == "running" then
		c:emit("arm", nil, by)
	end
	c:log(c:name(by), "back on the road at checkpoint", r.last or 0)
end

local effects_wreck
-- A wreck: the car disarmed, stopped, its blast; the announcer's line; back
-- on the road wreck_wait s later
local function wreck(c, pb, player, r, by, kind)
	r.wrecked = true
	c:emit("disarm", nil, pb)
	c:body_var(pb, "wreck", true)
	local p = player_of(c, pb)
	if p and p.pos then
		effects_wreck(c, p.pos)
	end
	local killer = type(by) == "string" and (by:match("^player:") or is_bot(by)) and
			by ~= pb and
			c:name(by) or nil
	local vars = {name = c:name(pb), killer = killer}
	if not c.state.first_blood then
		c.state.first_blood = true
		say(c, killer and "say_first_blood" or "say_first_wreck", vars)
	else
		say(c, killer and "say_kill" or "say_wreck", vars)
	end
	c:log(c:name(pb), "wrecked by", tostring(kind), killer or "")
	c:after(c.params.wreck_wait, "wrecked", {player = player})
end

function effects_wreck(c, at)
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

-- (the HUD's and the announcer's lines: params of cat hud, about.params)
local TEXTS = {
	{"say_grid", "{name} rolls onto the grid. Fresh meat!", "The announcer as a car rolls onto the grid."},
	{"say_start", "Engines hot! The yard gates are open!", "The announcer as the race's countdown starts."},
	{"say_count", "{n}...", "The announcer's countdown, each second ({n} the seconds left)."},
	{"say_go", "GO! Eat dirt, scrap heaps!", "The announcer at GO."},
	{"say_lead", "{name} takes the lead! The yard loves a climber!", "The announcer as the lead changes."},
	{"say_win", "{name} wins it! Chrome, fire and glory!", "The announcer as the winner finishes."},
	{"say_home", "{name} limps home {place}.", "The announcer as a later car finishes ({place}: 2nd...)."},
	{"say_first_blood", "{killer} draws first blood! {name} is a hood ornament now!", "The announcer at the race's first wreck by another car."},
	{"say_first_wreck", "{name} wrecks! First blood to the track!", "The announcer at the race's first wreck by no car."},
	{"say_kill", "{killer} sends {name} to the scrapyard!", "The announcer at a later wreck by another car."},
	{"say_wreck", "{name} leaves a mark on the dirt!", "The announcer at a later wreck by no car."},
	{"hud_grid", "On the grid: {cars}. Start when ready.", "The HUD on the grid ({cars}: \"2 cars\")."},
	{"hud_race", "Lap {lap}/{laps}   Pos {pos}/{cars}   Time {time}", "The HUD in a race."},
	{"hud_busy", "A race is on: the next one starts from the lobby.", "The HUD to a player who comes while a race is on."},
	{"hud_trial", "Lap {lap}/{laps}", "The HUD in a time trial."},
	{"note_count", "{n}", "A time trial's countdown note, each second."},
	{"note_go", "GO!", "A time trial's note at GO."},
	{"note_checkpoint", "Checkpoint {n}/{all}", "The note at a checkpoint passed."},
	{"note_last", "Last lap!", "The note as a race's last lap begins."},
	{"note_lap", "Lap {time}", "A time trial's note after a lap."},
	{"note_record", "Lap {time}, a record!", "A time trial's note after a lap that was the player's best."},
	{"result_place", "You: {place}", "A race's result card: the player's place, above the places so far."},
	{"result_line", "{place}  {name}  {time}", "A race's result card: each finisher's line."},
	{"result_dnf", "Out of time: DNF", "A race's result card for a car out of time."},
	{"result_trial", "Time {time}|Best lap {best}|Record {record}", "A time trial's result card (| a new line)."},
	{"result_new", "A new record!", "A time trial's result card's last line after a lap record."},
}

local type_t = {
	version = 1,
	reads_players = true,
	linked_in = true,
	-- (the grid's pole and the way it faces)
	gizmo = {shape = "box", size = 0.3, color = "#f4d35e"},
	about = {
		group = "Game",
		what = "Brimstone Stunts' race control on the starting grid: time trials, races from a grid with a countdown, laps by checkpoints, places and wrecks.",
		inputs = {
			entered = "A player's run started (kit/lobby's entered).",
			left = "A player's run ended (kit/lobby's left).",
			start = "Starts the race on the grid: a countdown, then everyone goes.",
			checkpoint = "The player passed a checkpoint. Value: its order (1...).",
			lap = "The player's car crossed the finish line with every checkpoint passed.",
			back = "Sent by itself: a wrecked car goes back on the road, as its player.",
			crash = "The player's car landed too hard (the car's crash): wrecked, in a race or a time trial.",
			lap_clock = "A trial's lap time (the kit/stopwatch's lap).",
			trial_clock = "A finished trial's whole time (the kit/stopwatch's elapsed).",
			record = "The player's lap record (the kit/records' best): the lap's note or the trial's result.",
			new_record = "The lap was the player's best yet (the kit/records' new_best).",
		},
		outputs = {
			hud = "The player's HUD line. Value: lap, place and time.",
			announce = "The announcer's line for everyone (its kit/ui_text clears it after a while). Value: the line.",
			result = "The player's result card. Value: their place and the places so far, or their trial's times.",
			note = "A time trial's note (the countdown, a checkpoint, a lap), for a kit/ui_text that clears itself. Value: the line.",
			countdown = "A time trial's countdown began for the player: their clock to 0 (a kit/stopwatch's reset).",
			split = "A time trial's lap closed: its time (a kit/stopwatch's lap).",
			stop = "A time trial's last lap closed: its clock stops (a kit/stopwatch's stop).",
			lap_time = "A time trial's lap. Value: its seconds.",
			finished = "A player finished. Value: their place (a race) or time (a trial).",
			go = "The player's run began: the race's GO, or the start of their trial.",
			arm = "The player's car may carry weapons now (stunt_weapons' arm): GO, or back on the road.",
			disarm = "The player's car carries none now (stunt_weapons' disarm): a wreck, the finish, a leave.",
			over = "The race is over (stunt_weapons' over).",
		},
		params = {
			mode = "This scene's way to drive the track: a race from the grid, or a time trial alone.",
			laps = "A race's laps.",
			trial_laps = "A time trial's laps.",
			time_out = "Seconds after the winner finishes until the rest are out (DNF).",
			countdown = "Seconds of countdown before GO, a race's and a time trial's.",
			wreck_wait = "Seconds a wrecked car waits before it is back on the road.",
			grid_gap = "Metres between a grid slot and the one ahead of it.",
			lobby = "The kit/lobby told when a player's run is over.",
			grid_screen = "The UI panel shown to the players waiting on the grid.",
			scorch = "The scorch mark left by a wreck: copies of this entity.",
			retry = "The pause menu's Retry (a kit/pause_menu_action), shown when one player may restart.",
		},
	},
	params = {
		mode = {type = "string", default = "race", choices = {"race", "trial"}},
		laps = {type = "number", default = 3, min = 1, max = 50},
		trial_laps = {type = "number", default = 3, min = 1, max = 50},
		time_out = {type = "number", default = 45, min = 5, max = 600},
		countdown = {type = "number", default = 3, min = 0, max = 10},
		wreck_wait = {type = "number", default = 2, min = 0, max = 30},
		grid_gap = {type = "number", default = 5.5, min = 3, max = 20},
		lobby = {type = "entity", default = 0},
		grid_screen = {type = "entity", default = 0},
		scorch = {type = "entity", default = 0},
		retry = {type = "entity", default = 0},
	},
	state = {
		runs = {default = {}, per_player = true},
		phase = {default = "grid"},
		racers = {default = {}},
		finished = {default = {}},
		t = {default = 0},
		count = {default = 0},
		scorches = {default = {}},
	},
	inputs = {entered = "none", left = "none",
		start = "none", checkpoint = "number", lap = "none", back = "none", crash = "number",
		lap_clock = "number", trial_clock = "number", record = "number",
		new_record = "number"},
	outputs = {hud = "string", announce = "string", result = "string",
		lap_time = "number", finished = "number", go = "none", note = "string",
		countdown = "none", split = "none", stop = "none", arm = "none",
		disarm = "none", over = "none"},
	on_start = function(c)
		c:after(0.1, "tick")
	end,
	on_join = function(c, by)
		local r = view(c, by)
		r.mode = nil
		show(c, by, r)
	end,
	-- Gone (from the game or this scene): out of the race
	on_away = function(c, by)
		local r = c.state.runs[by]
		if r and r.mode then
			if r.mode == "race" then
				drop_racer(c, by)
			end
			r.mode = nil
		end
	end,
	on_timer = function(c, name, player)
		if name == "wrecked" then
			-- That car alone back (as its player: a run by them, for the
			-- teleport)
			local by = tostring(player)
			c:respawn_waiting(by)
			if view(c, by).wrecked then
				c:send(c.id, "back", nil, by)
			end
			return
		elseif name == "trial" then
			-- A trial's countdown, a second a step
			local by = tostring(player)
			local r = view(c, by)
			if r.mode ~= "trial" or not r.count then
				return
			end
			r.count = r.count - 1
			if r.count > 0 then
				show(c, by, r, fill(c, "note_count", {n = r.count}))
				c:after(1, "trial", {player = by})
				return
			end
			r.count = nil
			c:speed(by, 1)
			show(c, by, r, fill(c, "note_go"))
			c:emit("go", nil, by)
			return
		elseif name == "count" then
			local n = c.state.count
			if n > 0 then
				say(c, "say_count", {n = n})
				c.state.count = n - 1
				c:after(1, "count")
				return
			end
			say(c, "say_go")
			c.state.phase, c.state.t = "running", 0
			for _, by in ipairs(c.state.racers) do
				c:speed(by, 1)
				view(c, by).at = 0
				c:emit("go", nil, by)
				c:emit("arm", nil, by)
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
		for _, by in ipairs(st.racers) do
			local r = c.state.runs[by]
			if r and r.mode == "race" then
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
		wreck(c, pb, player, r, by, kind)
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
			c:emit("disarm", nil, by)
			set_open(c, by, r, false)
			r.mode = nil
			return
		elseif input == "back" then
			return back(c, by, r)
		elseif input == "crash" then
			-- [KIT_STUNTS] a landing too hard: wrecked, a race's or a trial's
			if r.mode and not r.done and not r.wrecked then
				local p = player_of(c, by)
				wreck(c, by, p and p.id, r, nil, "landing")
			end
			return
		elseif input == "lap_clock" then
			-- [KIT_RECORDS] (a trial's: its note once the record is back)
			r.lap_t = tonumber(value) or 0
			return
		elseif input == "trial_clock" then
			r.total = tonumber(value) or 0
			return
		elseif input == "new_record" then
			r.new = true
			return
		elseif input == "record" then
			if r.lap_t then
				lap_done(c, by, r, tonumber(value))
			end
			return
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
			say(c, "say_start")
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
			show(c, by, r, fill(c, "note_checkpoint", {n = n, all = all}))
		elseif input == "lap" then
			lap(c, by, r)
		end
	end,
}
for _, t in ipairs(TEXTS) do
	type_t.params[t[1]] = {cat = "hud", type = "string", default = t[2]}
	type_t.about.params[t[1]] = t[3]
end
return type_t
