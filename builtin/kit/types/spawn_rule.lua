-- A spawn rule ([KIT_SPAWN_RULE]): copies of a prefab made around the
-- players, not at a place, for a world they walk away in (an infinite
-- terrain). Every `every` seconds while enabled, each player of its scene
-- may get one copy within `radius` m (from half of it out) where the
-- rule allows: on one of the voxels `on` (names, "kit/grass, kit/dirt";
-- empty: any solid), the sky light over it within light_min...light_max
-- (0 dark caves, 15 open sky; the World's sky light off reads 15), none
-- of its kind (copies of the prefab, its own or another's; apart_any:
-- any creature) within `apart` m; at most `max` of its copies at once.
-- Copies with no player within `despawn` m (0: never) are taken away,
-- so the cap follows the players. Spots: kit.cpp's spawn_spots_lit.
-- "enable" and "disable" (the param `enabled` at the start: a night's
-- dusk and dawn), "clear" takes its copies away. Its copies are play
-- state, gone at Stop.
-- simplified: one try a player each `every`; a prefab only (no single
-- type)
local function tick(c)
	local removed = {}
	for _, id in ipairs(c.far or {}) do
		c:remove(id)
		removed[id] = true
	end
	if #(c.far or {}) > 0 then
		c:log("took away", #c.far, "far from every player")
	end
	local live = 0
	for _, id in ipairs(c.made) do
		if not removed[id] then
			live = live + 1
		end
	end
	if live < c.params.max and #(c.spots or {}) == 0 then
		c:log("finds no spot,", live, "live")
	end
	for _, s in ipairs(c.spots or {}) do
		if live >= c.params.max then
			break
		end
		local id = c:spawn{prefab = c.params.prefab, pos = s}
		live = live + 1
		c:log(string.format("made %s at (%.1f, %.1f, %.1f), %d live", tostring(id),
			s[1], s[2], s[3], live))
		c:emit("spawned", id)
	end
end

return {
	version = 1,
	no_position = true,
	spawn_spots = true,
	params = {
		prefab = {type = "prefab", default = "kit/creature"},
		enabled = {type = "bool", default = true},
		every = {type = "number", default = 10, min = 1, max = 3600},
		max = {type = "number", default = 4, min = 1, max = 100},
		radius = {type = "number", default = 24, min = 4, max = 64},
		on = {type = "string", default = ""},
		light_min = {type = "number", default = 0, min = 0, max = 15},
		light_max = {type = "number", default = 15, min = 0, max = 15},
		apart = {type = "number", default = 12, min = 0, max = 128},
		apart_any = {type = "bool", default = false},
		despawn = {type = "number", default = 64, min = 0, max = 512},
	},
	state = {on = {default = true, param = "enabled"}},
	about = {
		group = "Creatures",
		what = "Makes copies of a prefab around the players, where its rules allow.",
		keywords = "spawn spawner mobs night",
		inputs = {
			enable = "Starts making copies.",
			disable = "Stops making copies; those made stay.",
			clear = "Takes its copies away.",
		},
		outputs = {
			spawned = "A copy was made. Value: its id.",
		},
	},
	inputs = {enable = "none", disable = "none", clear = "none"},
	outputs = {spawned = "any"},
	on_start = function(c)
		c:after(c.params.every)
	end,
	on_timer = function(c)
		if c.state.on and c.params.prefab ~= "" then
			tick(c)
		end
		c:after(c.params.every)
	end,
	on_input = function(c, input, value, by)
		if input == "clear" then
			for _, id in ipairs(c.made) do
				c:remove(id)
			end
			c:log("took away", #c.made, "copies")
			return
		end
		c.state.on = input == "enable"
		c:log(input .. "d by", c:name(by))
		-- (enabled: a first try at once, not an `every` later)
		if c.state.on then
			c:after(0.1)
		end
	end,
	on_params = function(c)
		c:after(c.params.every)
	end,
	on_remove = function(c)
		for _, id in ipairs(c.made) do
			c:remove(id)
		end
	end,
}
