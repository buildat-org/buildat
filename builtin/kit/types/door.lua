-- A door: an object one wide and two tall (its size), drawn shut or
-- swung open, and solid while shut. A player opens and shuts it by using
-- it, a link by "open", "close" or "toggle"; it shuts itself after
-- close_after seconds (0: it stays open)
local function set(c, open, by)
	if open == c.state.open then
		return
	end
	c.state.open = open
	c:log(open and "opened" or "shut", "by", c:name(by))
	c:emit(open and "opened" or "closed")
	if open and c.params.close_after > 0 then
		c:after(c.params.close_after)
	end
end

return {
	version = 2,
	usable = true,
	params = {
		size = {type = "position", default = {1, 2, 1}},
		close_after = {type = "number", default = 0, min = 0, max = 3600},
	},
	look = {shape = "box", extent = "size", depth = 0.2, color = "#8a5a30",
		solid = true, state = "open", when = {swing = true, solid = false}},
	state = {open = {default = false, shared = true}},
	inputs = {open = "none", close = "none", toggle = "none"},
	outputs = {opened = "none", closed = "none"},
	on_use = function(c, by)
		set(c, not c.state.open, by)
	end,
	on_input = function(c, input, value, by)
		set(c, input == "open" or (input == "toggle" and not c.state.open), by)
	end,
	on_timer = function(c)
		set(c, false, "its timer")
	end,
}
