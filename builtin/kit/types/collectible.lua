-- [KIT_COLLECTIBLE] A collectible: a gem, coin or crate a player takes by
-- walking (riding, driving) into its zone (`size` cells from its own on),
-- each player their own: one player's take leaves it for the others (a
-- per_player state, each client drawing its own player's). A take sends
-- "pickup" (the value, by the player), Kit's world event "pickup" and its
-- sound; it is back for that player after `again` seconds (0: at a
-- reset only). "reset" brings it back for the player (or bot) who set it
-- off (a run's c:send(id, "reset", nil, by)), from anything else for
-- everyone.
-- A run counts a player's takes by linking pickup to an input of its own
-- (Crag Trial's crag_run: its linked gems are the ones to take). The
-- client part hides it on this player's screen at once (e:predict), the
-- look's when.vanish (module.lua) playing it out: "fly" a short shrink
-- and rise, "none" gone at once. [KIT_COLLECTIBLE] (4z37zr) Its box may wear
-- a voxel material (`voxel`) and darker boards along its edges (`edge`, the
-- look's edge): Brimstone Speedway's wooden crates.
return {
	version = 1,
	zone = "size",
	look = {shape = "box", size = "param:look_size", color = "param:color",
		offset = "param:offset", voxel = "param:voxel", edge = "param:edge",
		state = "taken",
		when = {scale = {0.01, 0.01, 0.01}, vanish = "param:vanish"}},
	params = {
		value = {type = "string", default = ""},
		again = {type = "number", default = 0, min = 0, max = 3600},
		size = {cat = "look", type = "position", default = {1, 1, 1}},
		sound = {cat = "look", type = "sound", default = "kit/pickup"},
		look_size = {cat = "look", type = "number", default = 0.25,
			min = 0.02, max = 8},
		color = {cat = "look", type = "string", default = "#4cc9f0"},
		offset = {cat = "look", type = "position", default = {0, 0, 0}},
		voxel = {cat = "look", type = "voxel", default = "",
			choices_from = "voxels"},
		edge = {cat = "look", type = "string", default = ""},
		vanish = {cat = "look", type = "string", default = "fly",
			choices = {"fly", "none"}},
	},
	state = {taken = {default = {}, per_player = true}},
	about = {
		group = "Game",
		keywords = "gem coin crate pickup collect token star",
		what = "Something each player collects by walking into it: gone for them alone, back after a while or at a reset.",
		inputs = {
			reset = "Puts it back for the player who set it off, or for everyone from no player.",
		},
		outputs = {
			pickup = "A player took it. Value: its value.",
		},
		params = {
			value = "What a take sends on pickup (a weapon's name, a score...).",
			again = "Seconds until it is back for that player; 0: at a reset only.",
			size = "Its zone: the cells from its own on.",
			sound = "Played at it on a take (empty: none).",
			look_size = "Its look's half side, in cells.",
			color = "Its look's colour, as #rrggbb.",
			offset = "Its look's middle from its position.",
			voxel = "A voxel material its box wears (empty: its colour): kit/planks for a wooden crate.",
			edge = "Boards of this colour (#rrggbb) along its box's edges, a crate's frame (empty: none).",
			vanish = "How it goes on a take: fly (shrinks and rises) or none (at once).",
		},
	},
	inputs = {reset = "none"},
	outputs = {pickup = "string"},
	on_enter = function(c, by)
		if type(by) ~= "string" or c.state.taken[by] then
			return
		end
		c.state.taken[by] = true
		c:log(c:name(by), "took it")
		c:emit("pickup", c.params.value, by)
		c:event("pickup")
		c:sound(c.params.sound)
		if c.params.again > 0 then
			c:after(c.params.again, "back " .. by)
		end
	end,
	on_timer = function(c, name)
		local by = type(name) == "string" and name:match("^back (.+)$")
		if by and c.state.taken[by] then
			c.state.taken[by] = nil
			c:log("back for", c:name(by))
		end
	end,
	on_input = function(c, input, value, by)
		if input ~= "reset" then
			return
		end
		-- (a pending "back" timer needs no cancelling: a take again sets
		-- it anew, replacing it)
		if type(by) == "string" and (by:match("^player:") or by:match("^bot:")) then
			if c.state.taken[by] then
				c.state.taken[by] = nil
				c:log("back for", c:name(by))
			end
		elseif next(c.state.taken) then
			c.state.taken = {}
			c:log("back")
		end
	end,
}
