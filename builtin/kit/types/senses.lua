-- A creature's senses ([KIT_CREATURES_8A], kit_plan stage 8): every `every`
-- seconds the nearest living player within `range` (m), inside its view's
-- `angle` (degrees across, about the way its entity faces) and in sight (no
-- solid voxel between) is its target; it keeps one it has while they stay
-- within range and in sight, whatever the angle. "spotted" and "lost" say the
-- changes. Its state `target` (the player's entity, 0 none) is what the
-- behaviours on the entity take (their c.target).
-- simplified: sight only (no hearing); players only, not other creatures
local function on(c)
	return c.state.on
end

local function look(c)
	local best
	for _, n in ipairs(c.nearby) do
		if n.player and n.alive and n.sight then
			local keep = n.id == c.state.target
			local dx, dz = n.pos[1] - c.pos[1], n.pos[3] - c.pos[3]
			local off = (math.atan2(dx, dz) * 180 / math.pi - c.yaw + 540) % 360 - 180
			if keep or math.abs(off) <= c.params.angle / 2 then
				if keep then
					return n
				end
				best = best or n
			end
		end
	end
	return best
end

local function sense(c)
	local n = on(c) and look(c) or nil
	local id = n and n.id or 0
	if id == c.state.target then
		return
	end
	if c.state.target ~= 0 then
		c:log("lost", c.state.target)
		c:emit("lost")
	end
	c.state.target = id
	if n then
		c:log("spotted", n.id, n.name, string.format("%.1f m away", n.dist))
		c:emit("spotted", id)
	end
end

return {
	version = 1,
	about = {
		what = "What a creature sees: the nearest player in range, in its view and in sight.",
		inputs = {
			enable = "Senses again.",
			disable = "Senses nothing; a target is lost.",
		},
		outputs = {
			spotted = "A player became its target. Value: their entity.",
			lost = "Its target went: out of range or sight, or dead.",
		},
	},
	component = true,
	senses = true,
	nearby = "param:range",
	sight = true,
	params = {
		range = {type = "number", default = 12, min = 1, max = 48},
		angle = {type = "number", default = 140, min = 10, max = 360},
		enabled = {type = "bool", default = true},
		every = {cat = "advanced", type = "number", default = 0.25, min = 0.1, max = 5},
	},
	state = {
		target = {default = 0, shared = true},
		on = {default = true, param = "enabled"},
	},
	inputs = {enable = "none", disable = "none"},
	outputs = {spotted = "entity", lost = "none"},
	on_start = function(c)
		c:after(c.params.every)
	end,
	on_timer = function(c)
		sense(c)
		c:after(c.params.every)
	end,
	on_input = function(c, input)
		c.state.on = input == "enable"
		c:log(input == "enable" and "senses" or "senses nothing")
		sense(c)
	end,
}
