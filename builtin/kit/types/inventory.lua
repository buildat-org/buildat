-- A player's inventory: on each player entity ([KIT] stage 4d), Kit's own
-- counts of their items, what c:count, c:add, c:take and c:list reach
-- unless a component replaces it for every player (a type with
-- inventory = true). Not placed
local MAX = 1000000

return {
	version = 1,
	player = true,
	state = {items = {default = {}}},
	inventory_count = function(c, player, item)
		return c.state.items[item] or 0
	end,
	inventory_add = function(c, player, item, n)
		local items = c.state.items
		items[item] = math.min(MAX, (items[item] or 0) + n)
		return true
	end,
	inventory_take = function(c, player, item, n)
		local items = c.state.items
		local had = items[item] or 0
		if had < n then
			return false
		end
		items[item] = had > n and had - n or nil
		return true
	end,
	inventory_list = function(c, player)
		local t = {}
		for k, v in pairs(c.state.items) do
			t[k] = v
		end
		return t
	end,
}
