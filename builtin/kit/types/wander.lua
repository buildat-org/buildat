-- A creature's wandering ([KIT_CREATURES_8A], kit_plan stage 8): a behaviour on a
-- creature's entity. Now and then (pause seconds, give or take a half) while its
-- creature stands, a point within radius (m) of where it started, for its movement
-- to walk to (c:propose_move). The behaviours on an entity propose and the first
-- enabled one in its order that does wins, so wander goes last: what it does when
-- nothing else wants anything.
return {
	version = 1,
	about = {
		what = "A creature behaviour: it walks to a point near where it started, now and then.",
		inputs = {enable = "Wanders again.", disable = "Wanders no more."},
	},
	component = true,
	creature = true,
	params = {
		radius = {type = "number", default = 8, min = 1, max = 32},
		pause = {type = "number", default = 3, min = 0.5, max = 60},
		enabled = {type = "bool", default = true},
	},
	state = {on = {default = true, param = "enabled"}, home = {default = false}},
	inputs = {enable = "none", disable = "none"},
	on_start = function(c)
		c.state.home = c.pos
		c:after(0.5)
	end,
	on_timer = function(c)
		if not c.state.on then
			return
		end
		if not c.moving then
			local h = c.state.home or c.pos
			local a, r = math.random() * 2 * math.pi, c.params.radius * (0.3 + 0.7 * math.random())
			local to = {h[1] + math.sin(a) * r, h[2], h[3] + math.cos(a) * r}
			c:log(string.format("wanders to (%.1f, %.1f, %.1f)", to[1], to[2], to[3]))
			c:propose_move({to = to, range = 0.5})
		end
		c:after(c.params.pause * (0.5 + math.random()))
	end,
	on_input = function(c, input)
		c.state.on = input == "enable"
		if c.state.on then
			c:after(0.5)
		else
			c:propose_move(nil)
		end
	end,
}
