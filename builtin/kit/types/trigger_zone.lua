-- A trigger zone: a box of cells (its own and `size` on) that signals
-- "entered" and "left" as players walk in and out, with how many are in
-- it, and "empty" as the last one leaves. Unseen in play; the editor draws
-- its box.
-- [KIT_AIRSHIPS] stage 5: `deadly`, death by touch (ground under the sky
-- islands): a player walking in is hurt for their health's max (c:hurt, a
-- hit of type "ground": kit/health's death, refused under game_rules'
-- peaceful), and a ship touching it (a free object with kit/hull, its boxes'
-- corners or middle in the box) is lost as by its core hit (Kit's,
-- check_zones()).
return {
	version = 1,
	zone = "size",
	params = {
		size = {type = "position", default = {3, 2, 3}},
		deadly = {type = "bool", default = false},
	},
	state = {inside = {default = 0, shared = true}},
	gizmo = {shape = "sphere", size = 0.2, color = "#40c0ff"},
	about = {
		what = "An unseen box that notices players walking in and out.",
		outputs = {
			entered = "A player walked in. Value: how many are in it now.",
			left = "A player walked out. Value: how many are in it now.",
			empty = "The last one left.",
		},
	},
	outputs = {entered = "number", left = "number", empty = "none"},
	on_enter = function(c, by)
		c.state.inside = c.state.inside + 1
		c:log(c:name(by), "entered;", c.state.inside, "inside")
		c:emit("entered", c.state.inside)
		if c.params.deadly and c.player then
			c:hurt(c.player, {fraction = 1, type = "ground"})
		end
	end,
	on_leave = function(c, by)
		c.state.inside = math.max(0, c.state.inside - 1)
		c:log(c:name(by), "left;", c.state.inside, "inside")
		c:emit("left", c.state.inside)
		if c.state.inside == 0 then
			c:emit("empty")
		end
	end,
}
