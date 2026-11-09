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
-- simplified: one goal at a time; a bot's use passes no who-may-use
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
		c:after(0.25)
	end,
}
