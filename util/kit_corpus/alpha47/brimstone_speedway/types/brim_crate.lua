-- Brimstone Speedway's weapon crate: driven through (its zone, `size` cells
-- from its own on), it is gone for that driver for `again` seconds (each
-- driver's own, as Crag Trial's gems) and "taken" says which weapon
-- (`weapon`: gun, mines, boost, or any: the race picks), linked to the
-- race's crate. Kit's pickup event and sound go off at it.
return {
	version = 1,
	zone = "size",
	about = {
		group = "Game",
		what = "A weapon crate on Brimstone Speedway's track: driven through, it arms the car (the race's crate).",
		outputs = {taken = "A driver took it. Value: the weapon."},
	},
	look = {shape = "box", size = 1.1, color = "#c8402a", offset = {0.5, 0.6, 0.5},
		text = "label", state = "taken", when = {scale = {0.01, 0.01, 0.01}}},
	params = {
		weapon = {type = "string", default = "any",
			choices = {"any", "gun", "mines", "boost"}},
		again = {type = "number", default = 6, min = 0.5, max = 120},
		size = {cat = "look", type = "position", default = {2, 2, 2}},
		sound = {cat = "look", type = "sound", default = "kit/pickup"},
	},
	state = {
		taken = {default = {}, per_player = true},
		label = {default = "?", shared = true},
	},
	outputs = {taken = "string"},
	on_start = function(c)
		c.state.label = c.params.weapon == "any" and "?" or
				c.params.weapon:sub(1, 1):upper()
	end,
	on_enter = function(c, by)
		if type(by) ~= "string" or c.state.taken[by] then
			return
		end
		c.state.taken[by] = true
		c:emit("taken", c.params.weapon, by)
		c:event("pickup")
		c:sound(c.params.sound)
		c:after(c.params.again, "back", {player = c.player})
	end,
	on_timer = function(c, name, player)
		if name == "back" and player then
			c.state.taken["player:" .. player] = nil
		end
	end,
}
