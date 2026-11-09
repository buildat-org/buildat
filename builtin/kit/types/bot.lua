-- A bot ([KIT_GUIDE_BOTS], kit_plan 4z7): a creature that does the goals
-- (kit/goal) a player would, its own goal state as each player's ("bot:<id>"
-- where a player's is "player:<id>"). For its active goal (c.goal, the
-- server's: the first by id active for it, not audience "players"): "reach"
-- walks into the goal's box; "use" walks to its target and uses it; "signal"
-- walks to what makes the signal (the goal's `via`) and uses it once. A signal
-- goal with no via, or one its via's use did not do in `patience` seconds,
-- leaves it stuck: a log line and "(stuck)" on its nameplate. Drawn as a
-- player. [KIT_GUIDE_BOTS_2] A player everywhere (kit.cpp's bots): in
-- c.players, teams, queues and rounds; its goal the first it can act on
-- now; "place_item" walks to the target and uses what it carries there; a
-- use or a place not done in `patience` seconds is tried again.
-- [KIT_GOAL_PRIORITIES] Its goal the highest priority one it can act on
-- (kit/goal's). "attack": it walks to the target and, within the item's
-- reach, hurts it for the item's damage once a cooldown; "place_item" with
-- an item (c.goal.item): it uses the item there (c:use_item).
-- [KIT_GUIDE_STATIONS] A reach or an attack goal whose via is a station
-- (c.goal.station: a seat on a steered vehicle whose movement declares
-- `station`): it takes the seat (walks within reach; one on a ship from
-- anywhere, kit.cpp's bot_seat), then drives through the seat's inputs
-- (c:drive): a "helm" into the goal's box, the rudder on the bearing and
-- forward slowing as it nears; a "gun" turned and raised onto the arc that
-- meets the target (c.aim: the shot's speed and gravity, move.lua's M.aim),
-- fired while within about a target's width of it. It leaves the seat for a
-- goal elsewhere; with none it stays, its inputs let go.
-- simplified: one goal at a time; a bot's use passes no who-may-use
-- rule (a region's or a part's own), the upgrade is may_use() for a bot
local DEG = 180 / math.pi

local function clamp(x)
	return x < -1 and -1 or x > 1 and 1 or x
end

local function wrap(a)
	return (a + 180) % 360 - 180
end

-- The seconds over which an input closes an error (two of its thinks)
local CLOSE = 0.25

local function helm(g, s)
	-- (from the seat: it is what must be in the box)
	local dx, dz = g.at[1] - s.at[1], g.at[3] - s.at[3]
	local err = wrap(math.atan2(dx, dz) * DEG - s.yaw)
	local want = math.min(tonumber(s.params.top_speed) or 8,
			math.sqrt(dx * dx + dz * dz) * 0.4)
	return {f = clamp((want - s.speed) * 0.5), r = clamp(err / 20)}
end

local function gun(c, g, s)
	local p, m = s.params, s.muzzle
	local dx, dy, dz = g.at[1] - m[1], g.at[2] - m[2], g.at[3] - m[3]
	local d = math.sqrt(dx * dx + dz * dz)
	local yerr = wrap(math.atan2(dx, dz) * DEG - s.yaw)
	-- Its elevation's limits as the world has them now (the deck's tilt in)
	local tilt = s.elev + s.pitch
	local v, grav = tonumber(p.shot_speed) or 40, tonumber(p.shot_gravity) or 9.8
	local a = c.aim and c.aim(v, grav, d, dy, (tilt - (tonumber(p.pitch_max) or 10)) / DEG,
			(tilt - (tonumber(p.pitch_min) or -60)) / DEG)
	if a and d / (v * math.cos(a)) > s.life then
		a = nil
	end
	local eerr = a and a * DEG - s.elev or 0
	local tol = math.max(0.25, math.min(2, math.atan2(0.4, d) * DEG))
	return {f = clamp(eerr / ((tonumber(p.pitch_rate) or 30) * CLOSE)),
		r = clamp(yerr / ((tonumber(p.turn_rate) or 60) * CLOSE)),
		fire = a ~= nil and math.abs(yerr) < tol and math.abs(eerr) < tol}
end

local function plate(c)
	local p = c.params.name .. " " .. c.id .. (c.state.stuck and "\n(stuck)" or "")
	if p ~= c.state.plate then
		c.state.plate = p
	end
end

local function stuck(c, g, why)
	if c.state.stuck then
		return
	end
	c.state.stuck = true
	c:log("stuck on goal", g.id .. ":", why)
	c:emit("stuck", why)
	c:propose_move(nil)
	plate(c)
end

local function think(c)
	local g = c.goal
	local st = g and g.station
	if not g then
		c:propose_move(nil)
		c.state.goal, c.state.stuck = 0, false
		if c.seat ~= 0 then
			c:drive({})
		end
		plate(c)
		return
	end
	if c.seat ~= 0 and not (st and st.held) then
		c:log("leaves the seat of", c.seat, "for goal", g.id)
		c:leave_seat()
		return plate(c)
	end
	if g.id ~= c.state.goal then
		c.state.goal, c.state.used, c.state.stuck = g.id, false, false
		c:log("goal", g.id, g.kind, "\"" .. g.text .. "\"")
	end
	if c.state.stuck then
		return plate(c)
	end
	if st and st.held then
		c:drive(st.does == "gun" and gun(c, g, st) or helm(g, st))
	elseif st then
		if st.dist > c.params.reach and not st.board then
			c:propose_move({to = st.at, range = c.params.reach * 0.6})
		elseif not c.state.used then
			c:propose_move(nil)
			c.state.used = true
			c:log("takes the", st.does, "at", st.seat, "for goal", g.id)
			c:use(st.seat)
			c:after(math.min(2, c.params.patience), "patience")
		end
	elseif g.kind == "signal" and not g.via then
		stuck(c, g, "nothing to use for \"" .. g.text .. "\" (no via)")
	elseif g.kind == "reach" then
		c:propose_move({to = g.at, range = 0.3})
	elseif g.kind == "attack" then
		local reach = math.max(1, g.reach or 2)
		c:propose_move({to = g.at, range = reach * 0.6})
		if g.dist <= reach and not c.state.cooling then
			c:hurt(g.target, {amount = g.damage or 1, type = "normal"})
			c:log("hits", g.target, "with", g.item or "a hand", "for goal", g.id)
			c.state.cooling = true
			c:after(math.max(0.3, g.cooldown or 0.5), "cool")
		end
	elseif g.kind == "place_item" and g.item then
		if g.dist > c.params.reach then
			c:propose_move({to = g.at, range = c.params.reach * 0.6})
		elseif not c.state.used then
			c:propose_move(nil)
			c.state.used = true
			c:log("uses", g.item, "for goal", g.id)
			c:use_item(g.item)
			c:after(math.min(2, c.params.patience), "patience")
		end
	else
		local t = g.kind == "use" and g.target or g.kind == "place_item" and
				g.carry or g.via
		if g.dist > c.params.reach then
			c:propose_move({to = g.at, range = c.params.reach * 0.6})
		elseif not c.state.used then
			c:propose_move(nil)
			c.state.used = true
			c:log("uses", t, "for goal", g.id)
			c:use(t)
			c:after(g.kind == "signal" and c.params.patience or
					math.min(2, c.params.patience), "patience")
		end
	end
	plate(c)
end

return {
	version = 1,
	about = {
		what = "A bot: it does the goals a player would, one at a time.",
		outputs = {
			stuck = "It cannot do its goal. Value: why.",
		},
	},
	component = true,
	creature = true,
	bot = true,
	look = {shape = "box", size = {0.6, 1.8, 0.6}, color = "none", text = "plate",
		text_color = "#c0e0ff"},
	params = {
		name = {type = "string", default = "Bot"},
		-- (m, from what it uses; Kit's use range is the most)
		reach = {type = "number", default = 2.5, min = 0.5, max = 8},
		patience = {type = "number", default = 10, min = 1, max = 120},
	},
	state = {
		plate = {default = "", shared = true},
		goal = {default = 0},
		used = {default = false},
		stuck = {default = false},
		cooling = {default = false},
	},
	outputs = {stuck = "string"},
	on_start = function(c)
		c.state.goal, c.state.used, c.state.stuck = 0, false, false
		c.state.cooling = false
		plate(c)
		c:after(0.25)
	end,
	on_timer = function(c, name)
		if name == "cool" then
			c.state.cooling = false
			return
		end
		-- Its via used and the goal still there
		if name == "patience" then
			local g = c.goal
			if g and g.id == c.state.goal and c.state.used then
				-- [KIT_GUIDE_BOTS_2] a use or a place again (a moving target)
				if g.kind ~= "signal" then
					c.state.used = false
					return
				end
				stuck(c, g, "using " .. (g.via or g.target) .. " did not do \"" .. g.text .. "\"")
			end
			return
		end
		think(c)
		-- (at a station, oftener: its inputs follow what it aims at)
		c:after(c.seat ~= 0 and 0.1 or 0.25)
	end,
}
