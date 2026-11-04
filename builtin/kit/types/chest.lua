-- A chest ([KIT_INVENTORY_PLAY]): slots of its own (`size`), a player who
-- uses it sees them beside their own in the inventory screen and moves
-- stacks between the two (Kit's, while they stand in reach). Its state
-- `slots` as kit/inventory's ({item, n, inst}, {} empty); `items` the
-- builder's start ("kit/stone 20, kit/sword": filled at the round's
-- start). "opened" signals each use
local function parse(text)
	local out = {}
	for part in tostring(text):gmatch("[^,]+") do
		local item, n = part:match("^%s*(%S+)%s*(%d*)%s*$")
		if item and (item:match("^[%w_]+$") or item:match("^[%w_]+/[%w_]+$")) then
			out[#out + 1] = {item = item, n = math.max(1, tonumber(n) or 1)}
		end
	end
	return out
end

return {
	version = 1,
	usable = true,
	container = "size",
	look = {shape = "box", size = {0.8, 0.6, 0.6}, color = "#8a6236"},
	params = {
		size = {type = "number", default = 27, min = 1, max = 54},
		items = {type = "string", default = "", choices_from = "item_list"},
	},
	state = {slots = {default = {}}},
	outputs = {opened = "none"},
	on_start = function(c)
		local slots = {}
		for i, s in ipairs(parse(c.params.items)) do
			if i <= c.params.size then
				slots[i] = s
			end
		end
		c.state.slots = slots
	end,
	on_use = function(c, by)
		c:log(c:name(by), "opens it")
		c:emit("opened")
	end,
}
