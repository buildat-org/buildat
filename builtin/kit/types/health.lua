-- Health ([KIT_TOOLS_1], stage 7c): on each player entity, and placed on
-- an entity a hit may damage (placeable). Kit's hits (a melee item's,
-- api.h) go through the entity's modify_hit hooks, then on_hit here: hp
-- goes down by the amount, "damaged" signals it; at 0 "died", and a
-- player's death is Kit's (c:died: on_died hooks, then kit/game_rules'
-- respawn: at once at their spawn -- their team's pad, the scene's
-- spawner -- with hp back at max, or [KIT_CTF] waiting, state "waiting",
-- until a respawn signal). "heal" adds the signal's number (max without
-- one), "set" sets hp. Its client part shows the player theirs
return {
	version = 1,
	player = true,
	placeable = true,
	health = true,
	params = {max = {type = "number", default = 20, min = 1, max = 1000000}},
	state = {
		hp = {default = 20, shared = true},
		max = {default = 20, shared = true},
		waiting = {default = false, shared = true},
	},
	about = {
		group = "Players",
		what = "Hit points of a player or of what it is placed on.",
		inputs = {
			heal = "Adds hit points. Value: how many; none heals fully.",
			set = "Sets the hit points. Value: how many; 0 here neither kills nor signals died.",
		},
		outputs = {
			damaged = "A hit landed. Value: the amount.",
			died = "A hit took its last hit points.",
		},
	},
	inputs = {heal = "any", set = "number"},
	outputs = {damaged = "number", died = "none"},
	on_start = function(c)
		c.state.max = c.params.max
		c.state.hp = c.params.max
	end,
	on_input = function(c, input, value)
		local hp = input == "set" and value or c.state.hp +
				(type(value) == "number" and value or c.params.max)
		c.state.hp = math.max(0, math.min(c.params.max, hp))
	end,
	on_hit = function(c, hit, by)
		local hp = math.max(0, c.state.hp - hit.amount)
		c.state.hp = hp
		c:log("hit", hit.amount, hit.type, "by", c:name(by), "hp", hp)
		c:emit("damaged", hit.amount)
		if hp > 0 then
			return
		end
		c:log("died")
		c:emit("died")
		if c.is_player then
			c:died(by, hit.type)
		end
	end,
}
