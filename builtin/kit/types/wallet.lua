-- A player's wallet ([KIT_AIRSHIPS]): on each player entity, money for the
-- round (0 at its start), its own player's on their screen (its client
-- part). A kit/shop sets the starting money and takes a ship's price; a
-- kit/hull's cost per voxel is taken by Kit. "note" is a line its player
-- is shown (a shop's refusal). Not placed
return {
	version = 1,
	player = true,
	state = {
		money = {default = 0, shared = true},
		note = {default = "", shared = true},
	},
	about = {
		what = "A player's money for the round; on each player, not placed.",
		inputs = {
			give = "Adds money. Value: a number.",
			pay = "Takes money (not below 0). Value: a number.",
			set_money = "Sets the money. Value: a number.",
			note = "Shows its player a line. Value: the text.",
		},
	},
	inputs = {give = "number", pay = "number", set_money = "number",
		note = "string"},
	on_input = function(c, input, value, by)
		local n = tonumber(value) or 0
		if input == "note" then
			-- a counter in front, so the same line twice is a change
			local k = tonumber(tostring(c.state.note):match("^(%d+):")) or 0
			c.state.note = (k + 1) .. ":" .. tostring(value)
			return
		elseif input == "give" then
			c.state.money = c.state.money + n
		elseif input == "pay" then
			c.state.money = math.max(0, c.state.money - n)
		else
			c.state.money = n
		end
		c:log("money", c.state.money, "by", c:name(by))
	end,
}
