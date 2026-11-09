-- An item box ([KIT_TOOLS_2]): one of `item` put in and taken out, each
-- as it is -- its wear and loaded rounds kept (kit/inventory's
-- instances). A player who uses it puts one of theirs in while it is
-- empty, and takes the one in it while it holds one: a worn sword handed
-- on through it stays worn. Signals "put" and "taken"
return {
	version = 1,
	usable = true,
	look = {shape = "box", size = 0.35, color = "#7a5a3a"},
	params = {item = {type = "string", default = "kit/sword"}},
	state = {inside = {default = {}}},
	about = {
		group = "Items",
		what = "Holds one item, its wear kept: a player puts one in or takes it out.",
		outputs = {
			put = "A player put one in.",
			taken = "A player took it out.",
		},
	},
	outputs = {put = "none", taken = "none"},
	on_use = function(c, by)
		local inside, item = c.state.inside, c.params.item
		if inside.full then
			c:add(item, 1, {instances = {inside.data}})
			c.state.inside = {}
			c:log(c:name(by), "takes", item)
			c:emit("taken")
			return
		end
		local ext = {}
		if not c:take(item, 1, ext) then
			c:log(c:name(by), "has no", item)
			return
		end
		c.state.inside = {full = true, data = ext.instances and
				ext.instances[1] or {}}
		c:log(c:name(by), "puts in", item)
		c:emit("put")
	end,
}
