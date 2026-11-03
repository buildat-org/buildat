-- A player's equipment ([KIT_TOOLS_1], stage 7c): on each player entity,
-- the hands slot -- the item they hold, one of their items, picked on
-- their client's hotbar (Kit sets it; it empties when the item is gone)
-- -- and the wear of their items: an item type's uses left. Kit runs
-- on_tool after each use (a dig, a hit): a drop added, the wear taken;
-- at 0 one of the item breaks ("broke") and the next starts new. Stage
-- 8's other slots go beside the hands. Not placed
-- simplified: the wear is an item type's, the first of a stack's, not
-- each item's (counts only in the inventory); an item type's repair item
-- is kept on its sheet, and nothing mends with it yet (a station's job)
return {
	version = 1,
	player = true,
	equipment = true,
	state = {
		hands = {default = "", shared = true},
		wear = {default = {}, shared = true},
	},
	outputs = {broke = "any"},
	on_tool = function(c, item, cost, uses, drop)
		if drop then
			c:add(drop, 1)
			c:log("drop", drop)
		end
		if item == "" or cost <= 0 or uses <= 0 then
			return
		end
		local wear = c.state.wear
		local left = (wear[item] or uses) - cost
		if left > 0 then
			wear[item] = left
			c.state.wear = wear
			c:log(item, "uses left", left)
			return
		end
		wear[item] = nil
		c.state.wear = wear
		c:take(item, 1)
		c:log(item, "breaks")
		c:emit("broke", item)
	end,
}
