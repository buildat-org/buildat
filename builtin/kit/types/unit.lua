-- A unit a player commands ([KIT_RTS], kit_plan 4z37zzn): `unit = true` makes
-- its entity one that the members of its team (the kit/team named by `team`;
-- "": any player) select and order with kit/controls' rts camera
-- (client_lua/rts.lua). An order (kit.cpp's on_order_u) runs on_order(c, order,
-- by) on each of the entity's types that has it; this one's: a point
-- (order.at, its own spot about the point clicked) is walked to
-- (c:propose_move: a movement such as kit/unit_walker walks it), an entity
-- (order.target) is gone after to within range and, with a weapon (a ranged
-- item's name), shot at (c:fire) while it is there. Its state `target` (0:
-- none) is c.target to the behaviours on the entity (`senses = true`).
-- [KIT_RTS] Under kit/game_rules' fog its `sight` is how far (m) it sees for
-- its team (`vision = "sight"`): another team's units that near are sent to
-- its team's players.
-- simplified: no queue of orders, no stance; a target is chased wherever it
-- goes, until it is gone or another order comes
local function think(c)
	local id = c.state.target
	if id == 0 then
		return
	end
	local t = c.target
	if not t then
		c.state.target = 0
		c:propose_move(nil)
		c:log("target " .. id .. " gone")
		return
	end
	local r = c.params.range
	if t.dist > r then
		c:propose_move({to = t.pos, range = r * 0.8})
	else
		c:propose_move(nil)
		if c.params.weapon ~= "" then
			c:fire({item = c.params.weapon, at = t.pos})
		end
	end
	c:after(0.25, "think")
end

return {
	version = 1,
	about = {
		group = "Creatures",
		what = "A unit a player commands with the rts camera: selected, ordered to a point or at a target.",
		params = {
			team = "The name of the team (kit/team) whose members command it; empty: any player.",
			weapon = "A ranged item (as kit/bow) it shoots at a target it was ordered at; empty: none.",
			range = "How near in metres it goes to a target before it shoots.",
			sight = "How far in metres it sees for its team under fog of war (kit/game_rules' fog).",
		},
	},
	component = true,
	creature = true,
	senses = true,
	unit = true,
	vision = "sight",
	params = {
		team = {type = "string", default = ""},
		weapon = {type = "string", default = ""},
		range = {type = "number", default = 10, min = 0.5, max = 64},
		sight = {type = "number", default = 12, min = 0, max = 64},
	},
	state = {target = {default = 0}},
	on_order = function(c, order)
		if order.target then
			-- (c.target is the state's as the run starts: the next run's)
			c.state.target = order.target
			c:log("ordered at " .. order.target)
			c:after(0.05, "think")
		else
			c.state.target = 0
			c:propose_move({to = order.at, range = 0.3})
		end
	end,
	on_timer = function(c, name)
		if name == "think" then
			think(c)
		end
	end,
}
