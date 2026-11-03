-- A player's inventory: on each player entity ([KIT] stage 4d), Kit's own
-- counts of their items, what c:count, c:add, c:take and c:list reach
-- unless a component replaces it for every player (a type with
-- inventory = true). Not placed.
-- [KIT_TOOLS_2] Item instances ([KIT_ITEM_WEAR_SHAPE]): an item can carry
-- its own data (kit/equipment's wear and loaded rounds, a component's
-- free fields) in `inst` {item: {data...}}: the first of an item's count
-- each a table of its own, the rest (none listed) as new. Through the
-- interface's extension argument: c:take(item, n, ext) puts the data of
-- the n taken (the first n) in ext.instances; c:add(item, n, {instances
-- = {...}}) puts those first. So a worn sword given or moved keeps its
-- wear, and two wear apart. A replacing provider may do the same or keep
-- counts only
local MAX = 1000000

return {
	version = 1,
	player = true,
	state = {items = {default = {}}, inst = {default = {}}},
	inventory_count = function(c, player, item)
		return c.state.items[item] or 0
	end,
	inventory_add = function(c, player, item, n, ext)
		local items = c.state.items
		items[item] = math.min(MAX, (items[item] or 0) + n)
		local given = type(ext.instances) == "table" and ext.instances or {}
		if #given > 0 then
			local list, new = c.state.inst[item] or {}, {}
			for i = 1, math.min(n, #given) do
				new[i] = type(given[i]) == "table" and given[i] or {}
			end
			-- Those before them that were new keep their place as new
			for i = #new + 1, n do new[i] = {} end
			for _, d in ipairs(list) do new[#new + 1] = d end
			-- Trailing new ones are not listed
			while #new > 0 and next(new[#new]) == nil do new[#new] = nil end
			c.state.inst[item] = #new > 0 and new or nil
		end
		return true
	end,
	inventory_take = function(c, player, item, n, ext)
		local items = c.state.items
		local had = items[item] or 0
		if had < n then
			return false
		end
		items[item] = had > n and had - n or nil
		local list, taken = c.state.inst[item] or {}, {}
		for i = 1, n do
			taken[i] = list[1] or {}
			table.remove(list, 1)
		end
		c.state.inst[item] = #list > 0 and items[item] and list or nil
		ext.instances = taken
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
