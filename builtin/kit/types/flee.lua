-- A creature's fleeing ([KIT_CREATURES_8A], kit_plan stage 8): a behaviour on a
-- creature's entity, active by its own condition: its health under health_below
-- (a share of its max), or a player within player_within (m; 0: never for that).
-- Then it runs distance (m) away from its senses' target, else the nearest player,
-- again each half second (c:propose_move); "fleeing" and "calm" say the changes.
-- First on the Creature prefab: over attack and wander while active.
local function threat(c)
	if c.target then
		return c.target
	end
	return c:nearest("player")
end

local function think(c)
	local n = c:nearest("player")
	local low = c.health ~= nil and c.health < c.params.health_below
	local near = c.params.player_within > 0 and n ~= nil and n.dist <= c.params.player_within
	local t = c.state.on and (low or near) and threat(c) or nil
	if t then
		local dx, dz = c.pos[1] - t.pos[1], c.pos[3] - t.pos[3]
		local l = math.sqrt(dx * dx + dz * dz)
		if l < 0.1 then
			dx, dz, l = 1, 0, 1
		end
		local d = c.params.distance
		c:propose_move({to = {c.pos[1] + dx / l * d, c.pos[2], c.pos[3] + dz / l * d},
			speed = c.params.speed})
	else
		c:propose_move(nil)
	end
	if (t ~= nil) ~= c.state.fleeing then
		c.state.fleeing = t ~= nil
		c:log(t and ("flees from " .. t.id .. (low and " (health low)" or "")) or "is calm")
		c:emit(t and "fleeing" or "calm")
	end
end

return {
	version = 1,
	about = {
		what = "A creature behaviour: it runs away when its health is low or a player is near.",
		inputs = {
			enable = "Flees again.",
			disable = "Flees no more.",
		},
		outputs = {
			fleeing = "It began to flee.",
			calm = "It flees no more.",
		},
	},
	component = true,
	creature = true,
	-- the players near it (c:nearest), as far as it ever looks
	nearby = 32,
	params = {
		health_below = {type = "number", default = 0.3, min = 0, max = 1},
		player_within = {type = "number", default = 0, min = 0, max = 32},
		distance = {type = "number", default = 10, min = 1, max = 40},
		speed = {type = "number", default = 1.3, min = 0.1, max = 3},
		enabled = {type = "bool", default = true},
	},
	state = {on = {default = true, param = "enabled"}, fleeing = {default = false}},
	inputs = {enable = "none", disable = "none"},
	outputs = {fleeing = "none", calm = "none"},
	on_start = function(c)
		c:after(0.5)
	end,
	on_timer = function(c)
		think(c)
		c:after(0.5)
	end,
	on_input = function(c, input)
		c.state.on = input == "enable"
		think(c)
	end,
}
