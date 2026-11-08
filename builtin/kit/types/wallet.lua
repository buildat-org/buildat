-- A player's wallet ([KIT_AIRSHIPS]): on each player entity, money for the
-- round (0 at its start), its own player's on their screen (its client
-- part). A kit/shop sets the starting money and takes a ship's price; a
-- kit/hull's cost per voxel is taken by Kit. "note" is a line its player
-- is shown (a shop's refusal). Not placed.
-- [KIT_AIRSHIPS] stage 3: `part`, a ship part's prefab its player holds (a
-- kit/shop with `mount` sold it): their next place on a ship they may build
-- on puts it there instead of a voxel (Kit's, which empties it). Stage 4:
-- "repair" (a kit/supply's) puts back the destroyed voxels of every ship its
-- player owns (Kit's, kit.cpp's repair_ships())
-- [KIT_AIRSHIPS_2] `free` (set_free, a kit/shop's free_outside_rounds out
-- of a round): voxels on a ship cost nothing (Kit's), the money left as it
-- is; such a shop sells for nothing there too
return {
	version = 1,
	player = true,
	state = {
		money = {default = 0, shared = true},
		note = {default = "", shared = true},
		part = {default = "", shared = true},
		free = {default = false, shared = true},
	},
	about = {
		what = "A player's money for the round; on each player, not placed.",
		inputs = {
			give = "Adds money. Value: a number.",
			pay = "Takes money (not below 0). Value: a number.",
			set_money = "Sets the money. Value: a number.",
			note = "Shows its player a line. Value: the text.",
			hold_part = "Its player holds a ship part to put on. Value: its prefab.",
			repair = "Repairs the ships its player owns (Kit's).",
			set_free = "Purchases free (true) or paid (false). Value: a bool.",
		},
	},
	inputs = {give = "number", pay = "number", set_money = "number",
		note = "string", hold_part = "string", repair = "none",
		set_free = "bool"},
	on_input = function(c, input, value, by)
		local n = tonumber(value) or 0
		if input == "hold_part" then
			c.state.part = tostring(value)
			c:log("holds the part", c.state.part)
			return
		elseif input == "repair" then
			return
		elseif input == "set_free" then
			c.state.free = value == true
			return
		elseif input == "note" then
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
