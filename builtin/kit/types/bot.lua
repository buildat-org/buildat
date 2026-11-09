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
-- simplified: one goal at a time, no combat; a bot's use passes no who-may-use
-- rule (a region's or a part's own), the upgrade is may_use() for a bot
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
	if not g then
		c:propose_move(nil)
		c.state.goal, c.state.stuck = 0, false
		plate(c)
		return
	end
	if g.id ~= c.state.goal then
		c.state.goal, c.state.used, c.state.stuck = g.id, false, false
		c:log("goal", g.id, g.kind, "\"" .. g.text .. "\"")
	end
	if c.state.stuck then
		return plate(c)
	end
	if g.kind == "signal" and not g.via then
		stuck(c, g, "nothing to use for \"" .. g.text .. "\" (no via)")
	elseif g.kind == "reach" then
		c:propose_move({to = g.at, range = 0.3})
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
	},
	outputs = {stuck = "string"},
	on_start = function(c)
		c.state.goal, c.state.used, c.state.stuck = 0, false, false
		plate(c)
		c:after(0.25)
	end,
	on_timer = function(c, name)
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
		c:after(0.25)
	end,
}
