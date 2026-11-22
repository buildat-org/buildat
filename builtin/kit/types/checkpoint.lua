-- [KIT_RACE_PIECES] A checkpoint: an unseen gate a player (their car, bike,
-- body) passes, one of a course's, `order` its place (1, 2...). Its zone is
-- `size` cells from its own on along its own axes, turned by its yaw: x
-- across the gate, y up, z the way through it (a gate across a road: its
-- yaw the road's heading). Each player's last one passed is their state
-- `last`, the same in every kit/checkpoint of the scene (Kit copies a
-- change to them all: share_checkpoints()). A pass counts in order: the
-- one after the last (1 when none), or 1 at any time, again too (the next
-- lap, a fresh start: a run needs no reset to begin anew); one out of
-- order (3 before 2: a short cut, a wrong way) or the last one again does
-- nothing. A counted pass sends "passed" (its order, by the player).
-- "respawn" (by a player or bot) puts them back at the middle of their
-- last one, facing its yaw: send it to every checkpoint (the one that is
-- their last acts). "reset" clears the player's progress (by a player or
-- bot), or everyone's (by anything else). Laps are the course's own (a
-- run's: Brimstone Speedway's brim_race counts them).
-- simplified: one course a scene (two would share the progress)

-- The gate's middle on the ground, in the world: the corner cell's middle
-- (unturned: its position floored, as Kit's zone) and half its sides
local function middle(c)
	local s, p, yaw = c.params.size, c.pos, c.yaw or 0
	local x, y, z = p[1], math.floor(p[2]) + 0.5, p[3]
	if yaw % 360 == 0 then
		x, z = math.floor(x), math.floor(z)
	end
	local a = yaw * math.pi / 180
	local hx, hz = (s[1] - 1) / 2, (s[3] - 1) / 2
	return {x + hx * math.cos(a) + hz * math.sin(a), y,
		z - hx * math.sin(a) + hz * math.cos(a)}
end

local function actor(by)
	return type(by) == "string" and (by:match("^player:%d+$") or
			by:match("^bot:%d+$")) ~= nil
end

return {
	version = 1,
	zone = "size",
	gizmo = {shape = "sphere", size = 0.3, color = "#ff5030"},
	about = {
		group = "Game",
		keywords = "race lap gate course respawn",
		what = "An unseen gate across a course: passed in order, each player's last one is where they respawn.",
		inputs = {
			respawn = "Puts the player who sent it back at their last checkpoint passed, if it is this one: send it to every checkpoint.",
			reset = "Clears the progress of the player who sent it, or everyone's from no player.",
		},
		outputs = {
			passed = "A player passed it in order. Value: its order.",
		},
		params = {
			order = "Its place in the course: 1 first, then 2... A pass counts after the one before it (1 at any time).",
			size = "Its zone in cells from its own along its own axes: across the gate, up, and through it.",
		},
	},
	params = {
		order = {type = "number", default = 1, min = 1, max = 64},
		size = {type = "position", default = {12, 3, 2}},
	},
	state = {last = {default = {}, per_player = true}},
	inputs = {respawn = "none", reset = "none"},
	outputs = {passed = "number"},
	on_enter = function(c, by)
		if not actor(by) then
			return
		end
		local n, last = c.params.order, c.state.last[by] or 0
		if n ~= 1 and n ~= last + 1 then
			if n ~= last then
				c:log(c:name(by), "passed", n, "out of order: the last", last)
			end
			return
		end
		c.state.last[by] = n
		c:log(c:name(by), "passed", n)
		c:emit("passed", n, by)
	end,
	on_input = function(c, input, value, by)
		if input == "reset" then
			if actor(by) then
				c.state.last[by] = nil
			else
				c.state.last = {}
			end
		elseif input == "respawn" and actor(by) and
				c.state.last[by] == c.params.order then
			c:teleport(middle(c), {yaw = c.yaw or 0})
			c:log(c:name(by), "back at", c.params.order)
		end
	end,
}
