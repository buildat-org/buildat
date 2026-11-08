-- A creature's attack ([KIT_CREATURES_8A], kit_plan stage 8): a behaviour on a
-- creature's entity. While its senses' target (c.target) is a player, it chases
-- them (c:propose_move) and, within reach (m), hits them for damage through their
-- health (c:hurt, Kit's rules: peaceful, a region's damage), at most once every
-- cooldown seconds; "hit" says each.
-- simplified: players only, no other creatures; no wind-up or swing to see
local function think(c)
	local t = c.state.on and c.target or nil
	if not (t and t.player) then
		if c.state.chasing then
			c.state.chasing = false
			c:log("chases nobody")
		end
		c:propose_move(nil)
		return
	end
	if not c.state.chasing then
		c.state.chasing = true
		c:log("chases", t.id)
	end
	c:propose_move({to = t.pos, range = 1})
	if t.dist <= c.params.reach and not c.state.cooling then
		c:hurt(t.id, {amount = c.params.damage, type = "bite"})
		c:log("hits", t.id, "for", c.params.damage)
		c:emit("hit", t.id)
		c.state.cooling = true
		c:after(c.params.cooldown, "cool")
	end
end

return {
	version = 1,
	about = {
		what = "A creature behaviour: it chases its senses' target and hits them in reach.",
		inputs = {enable = "Attacks again.", disable = "Attacks no more."},
		outputs = {hit = "It hit its target. Value: their entity."},
	},
	component = true,
	creature = true,
	params = {
		damage = {type = "number", default = 2, min = 0, max = 1000},
		reach = {type = "number", default = 1.8, min = 0.5, max = 8},
		cooldown = {type = "number", default = 1, min = 0.1, max = 60},
		enabled = {type = "bool", default = true},
	},
	state = {
		on = {default = true, param = "enabled"},
		chasing = {default = false},
		cooling = {default = false},
	},
	inputs = {enable = "none", disable = "none"},
	outputs = {hit = "entity"},
	on_start = function(c)
		c:after(0.25)
	end,
	on_timer = function(c, name)
		if name == "cool" then
			c.state.cooling = false
			return
		end
		think(c)
		c:after(0.25)
	end,
	on_input = function(c, input)
		c.state.on = input == "enable"
		think(c)
	end,
}
