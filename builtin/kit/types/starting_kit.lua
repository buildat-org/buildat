-- A starting kit ([KIT_INVENTORY_PLAY]; UEFN's Item Granter): `items`
-- ("kit/sword, kit/stone 20") given to a player at a round's start (Play,
-- an arena's round, joining one; `when` "round") or at each spawn, the
-- round's and every respawn ("spawn"), with `clear` their inventory
-- emptied first. Under a kit/team: that team's members only. kit/arena's
-- round start "keep" and "clear" give none at its round's start
local function parse(text)
	local out = {}
	for part in tostring(text):gmatch("[^,]+") do
		local item, n = part:match("^%s*(%S+)%s*(%d*)%s*$")
		if item and (item:match("^[%w_]+$") or item:match("^[%w_]+/[%w_]+$")) then
			out[#out + 1] = {item, math.max(1, tonumber(n) or 1)}
		end
	end
	return out
end

return {
	version = 1,
	no_position = true,
	-- (it reads the team it is under: not a component on one)
	component = false,
	params = {
		items = {type = "string", default = "kit/pickaxe, kit/stone 20",
			choices_from = "item_list"},
		when = {type = "string", default = "round", choices = {"round", "spawn"}},
		clear = {type = "bool", default = false},
	},
	about = {
		what = "Gives players items at a round's start or at each spawn.",
		outputs = {
			given = "A player got them.",
		},
	},
	outputs = {given = "none"},
	-- Kit's call, by the player (an inventory emptied first with clear)
	on_give = function(c, by)
		local given = {}
		for _, it in ipairs(parse(c.params.items)) do
			if c:add(it[1], it[2]) then
				given[#given + 1] = it[2] .. " " .. it[1]
			end
		end
		c:log("gives", c:name(by), table.concat(given, ", "))
		c:emit("given")
	end,
}
