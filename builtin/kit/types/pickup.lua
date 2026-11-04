-- A pickup ([KIT_INVENTORY_PLAY]): `count` of `item` lying in the world,
-- a player who walks into it takes what fits in their inventory (an
-- instance's data kept: state `inst`, as kit/inventory's), the rest
-- stays. Kit makes one where a full inventory drops the rest, where a
-- player drops a stack (the drop key, a stack let go out of the screen)
-- and where one dies with kit/game_rules' on_death "drop"; a builder may
-- place one. "taken" signals the count taken; [KIT_SOUNDS] `sound` plays
-- at it then.
-- simplified: no pickup delay (a drop lands 2 m ahead of the dropper, an
-- overflow where a full inventory has no room); one standing in it takes it
-- only on entering again
local function show(c)
	c.state.label = c.state.left .. " " .. c.params.item
end

return {
	version = 1,
	zone = "size",
	look = {shape = "box", size = 0.3, color = "#e8d070", text = "label"},
	params = {
		item = {type = "string", default = "kit/stone", choices_from = "items"},
		count = {type = "number", default = 1, min = 1, max = 1000000},
		size = {type = "position", default = {1, 2, 1}},
		sound = {type = "sound", default = "kit/pickup"},
	},
	state = {
		left = {default = 0},
		inst = {default = {}},
		label = {default = "", shared = true},
	},
	outputs = {taken = "number"},
	on_start = function(c)
		if c.state.left <= 0 then
			c.state.left = c.params.count
		end
		show(c)
	end,
	on_enter = function(c, by)
		if c.state.left <= 0 then
			return -- not started yet
		end
		local ext = {partial = true, instances = c.state.inst}
		if not c:add(c.params.item, c.state.left, ext) then
			c:log(c:name(by), "has no room for", c.params.item)
			return
		end
		local n = tonumber(ext.added) or c.state.left
		local inst = {}
		for i = n + 1, #c.state.inst do
			inst[#inst + 1] = c.state.inst[i]
		end
		c.state.inst = inst
		c.state.left = c.state.left - n
		c:log(c:name(by), "takes", n, c.params.item)
		c:emit("taken", n)
		c:sound(c.params.sound)
		if c.state.left <= 0 then
			c:remove(c.id)
		else
			show(c)
		end
	end,
}
