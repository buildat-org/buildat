-- A door: the cells it owns (one wide, two tall) show it shut or open. A
-- player opens and shuts it by using it, a link by "open", "close" or
-- "toggle"; it shuts itself after close_after seconds (0: it stays open)
local function set(c, open, by)
	if open == c.state.open then
		return
	end
	c.state.open = open
	c:set_voxel(open and c.params.open or c.params.closed)
	c:log(open and "opened" or "shut", "by", by)
	c:emit(open and "opened" or "closed")
	if open and c.params.close_after > 0 then
		c:after(c.params.close_after)
	end
end

return {
	version = 1,
	usable = true,
	owns_voxel = true,
	volume = "size",
	params = {
		size = {type = "position", default = {1, 2, 1}},
		closed = {type = "voxel", default = ""}, -- "": the app fills it, or you
		open = {type = "voxel", default = "air"},
		close_after = {type = "number", default = 0, min = 0, max = 3600},
	},
	state = {open = {default = false, shared = true}},
	inputs = {"open", "close", "toggle"},
	outputs = {"opened", "closed"},
	on_start = function(c)
		c:set_voxel(c.state.open and c.params.open or c.params.closed)
	end,
	on_use = function(c, by)
		set(c, not c.state.open, by)
	end,
	on_input = function(c, input, value, by)
		set(c, input == "open" or (input == "toggle" and not c.state.open), by)
	end,
	on_timer = function(c)
		set(c, false, "its timer")
	end,
	-- Someone else's write to its cells (a dig): routed here, not made
	on_voxel = function(c, voxel, by)
		c:log("kept its cells from", by)
	end,
}
