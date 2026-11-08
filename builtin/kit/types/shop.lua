-- A shop ([KIT_AIRSHIPS]): a counter a player uses to buy a copy of
-- `prefab` for `price` from their kit/wallet. The copy is made at the
-- shop's place plus `pad` (a hangar pad beside it) and sent "own" as by the
-- buyer, so a kit/hull on it makes them its owner. Too little money: the
-- buyer's wallet notes it, "refused". `start_money` (0: none) is each
-- player's money at their round start.
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

return {
	version = 1,
	usable = true,
	players = true,
	params = {
		prefab = {type = "prefab", default = "kit/airship_skiff"},
		price = {type = "number", default = 20, min = 0, max = 100000},
		pad = {type = "position", default = {0, 0, 6}},
		start_money = {type = "number", default = 0, min = 0, max = 100000},
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
		},
	},
	outputs = {bought = "entity", refused = "none"},
	on_start = function(c)
		c.state.label = c.params.title .. ": " .. c.params.price
	end,
	on_join = function(c, by)
		if c.params.start_money > 0 and c.player then
			c:send(c.player, "set_money", c.params.start_money)
		end
	end,
	on_use = function(c, by)
		if c.params.prefab == "" or not c.player then
			return
		end
		local p, money = c.params, wallet(c)
		if money < p.price then
			c:send(c.player, "note", "Not enough money: " .. p.title ..
				" costs " .. p.price .. ", you have " .. money)
			c:log("refused", c:name(by), "money", money, "price", p.price)
			c:emit("refused")
			return
		end
		local pos = {c.pos[1] + p.pad[1], c.pos[2] + p.pad[2],
			c.pos[3] + p.pad[3]}
		local id = c:spawn{prefab = p.prefab, pos = pos}
		if not id then
			c:log("could not make", p.prefab)
			return
		end
		if p.price > 0 then
			c:send(c.player, "pay", p.price)
		end
		c:send(id, "own")
		c.state.sold = c.state.sold + 1
		c:log("sold", p.prefab, "to", c:name(by), "as", id, "for", p.price)
		c:emit("bought", id)
	end,
}
