-- An explosive ([KIT_CTF]): armed -- at its start with `armed`, or by
-- "arm" (as by who set it off: a kit/placer's player) -- it waits `fuse`
-- seconds, playing `sound` every `sound_every` s, then explodes (c:explode
-- with `radius`, `power`, `kill`, `hurt`, `share` and `friendly_fire`,
-- api.h's) and is gone. "explode" sets it off at once. Nothing in Kit lets
-- a player remove an entity in play, so an armed one stays until it goes.
-- [KIT_FEEDBACK_EFFECTS] Armed, its look blinks (blink_color, "" not):
-- every blink_slow s at the fuse's start, every blink_fast s at its end.
-- Outputs: armed, exploded (where: kit/controls' shake, kit/effect's burst)
local function boom(c)
	local p = c.params
	c:log("explodes")
	c:explode{radius = p.radius, power = p.power, kill = p.kill,
		hurt = p.hurt, share = p.share, friendly_fire = p.friendly_fire}
	c:emit("exploded", c.pos)
	c:remove()
end

local function blink(c)
	local p = c.params
	if p.blink_color == "" or p.fuse <= 0 then
		return
	end
	c.state.lit = not c.state.lit
	local f = math.max(0, math.min(1, c.state.left / p.fuse))
	local every = p.blink_fast + (p.blink_slow - p.blink_fast) * f
	c:log("blink", every)
	c:after(every, "blink")
end

local function arm(c)
	if c.state.armed then
		return
	end
	c.state.armed = true
	c.state.left = c.params.fuse
	c:log("armed:", c.params.fuse, "s")
	c:emit("armed")
	c:sound(c.params.sound)
	c:after(math.min(c.params.sound_every, c.params.fuse), "tick")
	blink(c)
end

return {
	version = 1,
	-- (on the ground at its default size)
	look = {shape = "sphere", size = "param:size", offset = {0, -0.2, 0},
		color = "param:color", state = "lit",
		when = {color = "param:blink_color"}},
	params = {
		armed = {type = "bool", default = false},
		fuse = {type = "number", default = 5, min = 0, max = 3600},
		sound = {cat = "look", type = "sound", default = "kit/hiss"},
		sound_every = {cat = "look", type = "number", default = 1, min = 0.1,
			max = 60},
		radius = {type = "number", default = 3, min = 0, max = 9},
		power = {type = "number", default = 1, min = 0, max = 1000},
		kill = {type = "number", default = 3, min = 0, max = 32},
		hurt = {type = "number", default = 0, min = 0, max = 32},
		share = {type = "number", default = 0.5, min = 0, max = 1},
		friendly_fire = {type = "bool", default = true},
		size = {cat = "look", type = "number", default = 0.3, min = 0.05,
			max = 4},
		color = {cat = "look", type = "string", default = "#101010"},
		blink_color = {cat = "look", type = "string", default = ""},
		blink_slow = {cat = "look", type = "number", default = 0.8, min = 0.05,
			max = 60},
		blink_fast = {cat = "look", type = "number", default = 0.1, min = 0.05,
			max = 60},
	},
	state = {
		armed = {default = false, shared = true},
		lit = {default = false, shared = true},
		left = {default = 0},
	},
	about = {
		group = "Game",
		what = "Once armed, waits out its fuse, explodes and is gone.",
		inputs = {
			arm = "Starts the fuse.",
			explode = "Explodes at once.",
		},
		outputs = {
			armed = "The fuse started.",
			exploded = "It went off, just before it is gone. Value: where, a position.",
		},
	},
	inputs = {arm = "none", explode = "none"},
	outputs = {armed = "none", exploded = "position"},
	on_start = function(c)
		if c.params.armed then
			arm(c)
		end
	end,
	on_input = function(c, input)
		if input == "explode" then
			boom(c)
		else
			arm(c)
		end
	end,
	on_timer = function(c, name)
		if name == "blink" then
			return blink(c)
		end
		local s = c.state
		s.left = s.left - c.params.sound_every
		if s.left <= 0 then
			return boom(c)
		end
		c:sound(c.params.sound)
		c:after(math.min(c.params.sound_every, s.left), "tick")
	end,
}
