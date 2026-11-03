-- A team ([KIT_MINIGAMES_1], stage 7b): its colour, its spawn (where it
-- stands: a pad of its colour) and its shared score. A kit/arena's round
-- puts each player in a team ("join", by the player: a member from then
-- on, put on its pad); "add" adds the signal's number to the score (1
-- without one), "set" sets it; "scored" signals the new score and
-- "reached" (its own id) as the score first reaches `win_score` (0:
-- never) -- linked to the arena's "win", the first team there wins.
-- Kit reads it as the Team interface: a type with `team = true`, its
-- state `members` (player entity ids) and `score`, its `name`, its
-- `friendly_fire` (off: Kit's hits between its members refused): a
-- kit/region under it with owner "team" is its members' (api.h)
local function show(c)
	c.state.status = c.params.name .. ": " .. tostring(c.state.score)
end

return {
	version = 1,
	team = true,
	look = {shape = "box", size = {2, 0.1, 2}, color = "param:color",
		text = "status"},
	params = {
		name = {type = "string", default = "Red"},
		color = {type = "string", default = "#d03030"},
		win_score = {type = "number", default = 0, min = 0, max = 1000000},
		-- [KIT_TOOLS_1] whether its members' hits hurt each other
		friendly_fire = {type = "bool", default = false},
	},
	state = {
		members = {default = {}, shared = true},
		score = {default = 0, shared = true},
		status = {default = "", shared = true},
	},
	inputs = {join = "none", add = "any", set = "number"},
	outputs = {scored = "number", reached = "entity"},
	on_start = show,
	on_params = show,
	on_input = function(c, input, value, by)
		if input == "join" then
			if not c.player then
				return
			end
			-- [KIT_MINIGAMES_FIX] the team's members are in its scene
			if c.player_away then
				c:log(c:name(by), "is not in this team's scene: the join refused")
				return
			end
			local m = c.state.members
			for _, id in ipairs(m) do
				if id == c.player then
					return
				end
			end
			m[#m + 1] = c.player
			c.state.members = m
			c:log(c:name(by), "joins team", c.params.name)
			c:teleport(c.pos, {yaw = c.yaw})
			return
		end
		local was = c.state.score
		if input == "set" then
			c.state.score = value
		else
			c.state.score = was + (type(value) == "number" and value or 1)
		end
		show(c)
		c:log("score", c.state.score, by and ("by " .. c:name(by)) or "")
		c:emit("scored", c.state.score)
		local w = c.params.win_score
		if w > 0 and was < w and c.state.score >= w then
			c:emit("reached", c.id)
		end
	end,
}
