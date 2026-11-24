-- Deepcore's unit or building ([KIT_RTS], kit_plan 4z37zzo): what every one
-- of them has besides Kit's kit/unit (a unit's orders, its weapon) and
-- kit/health. Its kit/health's "died" links to its input died: the entity
-- and its parts go (c:remove), an effect where it was. A building is a
-- kit/unit with no movement and no weapon: its team selects it, an order to
-- it does nothing, it sees for its team (kit/unit's sight). A shot of a unit
-- of its own team does it no harm (a tank firing past another of its side).
-- simplified: no wreck left, no death sound; a shot still stops at the
-- friend in its way (no shooting through)
return {
	version = 1,
	about = {
		group = "Creatures",
		what = "A Deepcore unit or building: it goes when its health runs out.",
		inputs = {died = "Its kit/health ran out: it goes."},
	},
	component = true,
	reads_units = true,
	inputs = {died = "none"},
	modify_hit = function(c, hit)
		if not hit.unit then
			return
		end
		local mine, theirs
		for _, u in ipairs(c.units) do
			if u.id == c.id then
				mine = u.team
			elseif u.id == hit.unit then
				theirs = u.team
			end
		end
		if mine and mine ~= "" and mine == theirs then
			return {amount = 0}
		end
	end,
	on_input = function(c, input)
		if input == "died" then
			c:effect({count = 40, shape = "square", colors = {"#ffb040", "#ff6020",
				"#504840", "#303030"}, speed_min = 1, speed_max = 5, spread = 80,
				dir = {0, 1, 0}, gravity = 6, ttl_min = 0.4, ttl_max = 1.2,
				size_min = 0.08, size_max = 0.25, light_time = 0.4,
				light_color = "#ff9040", light_range = 6, light_brightness = 2})
			c:log("destroyed")
			c:remove(nil)
		end
	end,
}
