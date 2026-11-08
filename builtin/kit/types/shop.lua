-- A shop ([KIT_AIRSHIPS]): a counter a player uses to buy a copy of
-- `prefab` for `price` from their kit/wallet. The copy is made at the
-- shop's place plus `pad` (a hangar pad beside it) and sent "own" as by the
-- buyer, so a kit/hull on it makes them its owner. Too little money: the
-- buyer's wallet notes it, "refused". `start_money` (0: none) is each
-- player's money at their round start.
-- [KIT_AIRSHIPS] stage 3: with `mount` the prefab is a part for a ship (a gun,
-- an engine, a radar: kit/airship_gun...): nothing is made at the pad; the
-- buyer holds it (their kit/wallet's `part`) until their next place on a ship
-- they may build on, which puts it on that face instead of a voxel. One held at
-- a time: buying another replaces it (no money back). Stage 4: a ship it sold
-- that is lost (its core hit, a deadly kit/trigger_zone touched) is "lost" to
-- it from Kit, and "lost" signals on (a point for the other team).
-- [KIT_AIRSHIPS_2] `free_outside_rounds`: out of a round (the default one)
-- its player's kit/wallet is set free (this shop's price and their voxels
-- nothing), in a round paid again.
-- simplified: nothing checks the pad is clear; a ship bought onto another
-- overlaps it
local function wallet(c)
	for _, p in ipairs(c.players or {}) do
		if p.id == c.player then
			local w = p.state and p.state["kit/wallet"]
			return w and tonumber(w.money) or 0
		end
	end
	return 0
end

local function free(c)
	return c.params.free_outside_rounds and c.session == 0
end

-- The price from the buyer's wallet, or a note that it was free
local function pay(c, price)
	if price > 0 then
		c:send(c.player, "pay", price)
	elseif free(c) then
		c:send(c.player, "note", c.params.title .. ": free outside a round")
	end
end

return {
	version = 1,
	usable = true,
	players = true,
	params = {
		prefab = {type = "prefab", default = "kit/airship_skiff"},
		price = {type = "number", default = 20, min = 0, max = 100000},
		pad = {type = "position", default = {0, 0, 6}},
		start_money = {type = "number", default = 0, min = 0, max = 100000},
		mount = {type = "bool", default = false},
		free_outside_rounds = {type = "bool", default = false},
		title = {type = "string", default = "Skiff"},
		color = {cat = "look", type = "string", default = "#d0a030"},
	},
	look = {shape = "box", size = {1, 1, 0.6}, color = "param:color",
		text = "label"},
	state = {
		label = {default = "", shared = true},
		sold = {default = 0, shared = true},
	},
	about = {
		what = "A counter that sells a copy of a prefab for money from the buyer's wallet.",
		outputs = {
			bought = "A player bought one. Value: the copy's id.",
			refused = "A player had too little money.",
			lost = "A ship it sold was lost (no value: a team's add counts 1).",
		},
		inputs = {
			lost = "Kit's: a ship it sold was lost. Value: the ship's id.",
		},
	},
	outputs = {bought = "entity", refused = "none", lost = "none"},
	inputs = {lost = "entity"},
	on_input = function(c, input, value, by)
		c:log("its ship", value, "lost")
		c:emit("lost")
	end,
	on_start = function(c)
		c.state.label = c.params.title .. ": " .. (free(c) and "free" or
				c.params.price)
	end,
	on_join = function(c, by)
		if c.params.start_money > 0 and c.player then
			c:send(c.player, "set_money", c.params.start_money)
		end
		if c.params.free_outside_rounds and c.player then
			c:send(c.player, "set_free", free(c))
		end
	end,
	on_use = function(c, by)
		if c.params.prefab == "" or not c.player then
			return
		end
		local p, money = c.params, wallet(c)
		local price = free(c) and 0 or p.price
		if money < price then
			c:send(c.player, "note", "Not enough money: " .. p.title ..
				" costs " .. p.price .. ", you have " .. money)
			c:log("refused", c:name(by), "money", money, "price", p.price)
			c:emit("refused")
			return
		end
		if p.mount then
			pay(c, price)
			c:send(c.player, "hold_part", p.prefab)
			c.state.sold = c.state.sold + 1
			c:log("sold the part", p.prefab, "to", c:name(by), "for", price)
			return
		end
		local pos = {c.pos[1] + p.pad[1], c.pos[2] + p.pad[2],
			c.pos[3] + p.pad[3]}
		local id = c:spawn{prefab = p.prefab, pos = pos}
		if not id then
			c:log("could not make", p.prefab)
			return
		end
		pay(c, price)
		c:send(id, "own")
		c.state.sold = c.state.sold + 1
		c:log("sold", p.prefab, "to", c:name(by), "as", id, "for", price)
		c:emit("bought", id)
	end,
}
