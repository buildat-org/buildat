-- A supply ([KIT_AIRSHIPS] stage 4): a crate on a small island; a player
-- walking into it gets `money` (their kit/wallet's "give") and with `repair`
-- the destroyed voxels of the ships they own put back as they were (the
-- wallet's "repair"). Then it is gone for `every` seconds (0: once a round).
-- simplified: a player's, walked into; a ship flying through it gets nothing
return {
	version = 1,
	zone = "size",
	look = {shape = "box", size = 0.8, color = "param:color", text = "label"},
	params = {
		money = {type = "number", default = 10, min = 0, max = 100000},
		repair = {type = "bool", default = false},
		every = {type = "number", default = 30, min = 0, max = 3600},
		size = {cat = "look", type = "position", default = {1, 2, 1}},
		color = {cat = "look", type = "string", default = "#e8c040"},
	},
	state = {
		ready = {default = true},
		was = {default = ""},
		label = {default = "", shared = true},
	},
	about = {
		group = "Game",
		what = "A crate a player walks into for money or to repair their ships.",
		outputs = {
			taken = "A player took it.",
		},
	},
	outputs = {taken = "none"},
	on_start = function(c)
		c.state.ready = true
		local p = c.params
		c.state.label = (p.repair and "Repair" or "") ..
				(p.repair and p.money > 0 and " + " or "") ..
				(p.money > 0 and p.money .. " money" or "")
	end,
	on_enter = function(c, by)
		if not c.state.ready or not c.player then
			return
		end
		local p = c.params
		if p.money > 0 then
			c:send(c.player, "give", p.money)
		end
		if p.repair then
			c:send(c.player, "repair")
		end
		c:log("taken by", c:name(by))
		c:emit("taken")
		c.state.ready = false
		c.state.was = c.state.label
		c.state.label = ""
		if p.every > 0 then
			c:after(p.every, "back")
		end
	end,
	on_timer = function(c)
		c.state.ready = true
		c.state.label = c.state.was
	end,
}
