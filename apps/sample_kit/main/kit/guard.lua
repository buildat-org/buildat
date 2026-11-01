-- [KIT] stage 4j: a region's allow hook (util/kit_regions_check.sh): on
-- a region's entity (the prefab sample_kit/guarded_region) it refuses
-- digging there with its reason while on, and leaves the rest to the
-- region's rules; "toggle" turns it off and on
return {
	version = 1,
	params = {
		reason = {type = "string", default = "The guard says no"},
	},
	state = {
		on = {default = true},
	},
	inputs = {toggle = "none"},
	on_input = function(c, input)
		c.state.on = not c.state.on
		c:log(c.state.on and "on" or "off")
	end,
	allow = function(c, player, action, pos)
		c:log("asked", action, "at", pos[1] .. "," .. pos[2] .. "," .. pos[3],
				"by", c:name(player))
		if action == "dig" and c.state.on then
			return false, c.params.reason
		end
		return nil
	end,
}
