-- A pouch: the players' inventory in place of Kit's counts (inventory =
-- true), each player's holding `capacity` items at most, all kinds
-- together. Kit asks the first pouch; a second is refused
local function total(mine)
	local n = 0
	for _, k in pairs(mine) do
		n = n + k
	end
	return n
end

return {
	version = 1,
	inventory = true,
	params = {capacity = {type = "number", default = 1, min = 1, max = 1000}},
	-- {player = {item = n}}, written back whole
	state = {held = {default = {}}},
	inventory_count = function(c, player, item, ext)
		return (c.state.held[player] or {})[item] or 0
	end,
	inventory_add = function(c, player, item, n, ext)
		local held = c.state.held
		local mine = held[player] or {}
		if total(mine) + n > c.params.capacity then
			c:log(player, "has no room for", n, item)
			return false
		end
		mine[item] = (mine[item] or 0) + n
		held[player] = mine
		c.state.held = held
		c:log(player, "holds", total(mine))
		return true
	end,
	inventory_take = function(c, player, item, n, ext)
		local held = c.state.held
		local mine = held[player] or {}
		if (mine[item] or 0) < n then
			return false
		end
		mine[item] = mine[item] > n and mine[item] - n or nil
		held[player] = mine
		c.state.held = held
		c:log(player, "gave up", n, item, "and holds", total(mine))
		return true
	end,
	inventory_list = function(c, player, ext)
		return c.state.held[player] or {}
	end,
}
