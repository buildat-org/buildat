-- An NPC that says lines: each use (or "say") says the next of its
-- `lines` (separated by |), over its head for everyone near, and signals
-- "said" with the line's number; after the last it starts over.
-- simplified: a box that stands still and talks to all, no reply to the
-- one who asked
local function say(c, by)
	local lines = {}
	for l in string.gmatch(c.params.lines, "[^|]+") do
		lines[#lines + 1] = l
	end
	if #lines == 0 then
		return
	end
	local at = c.state.at % #lines + 1
	c.state.at = at
	c.state.line = c.params.name .. ": " .. lines[at]
	c:log("says to", c:name(by), "\"" .. lines[at] .. "\"")
	c:emit("said", at)
end

return {
	version = 1,
	usable = true,
	look = {shape = "box", size = 0.45, color = "#e0b090", text = "line"},
	params = {
		name = {type = "string", default = "Bob"},
		lines = {type = "string",
			default = "Hello!|Press the button to open the gate.|Mind the timer."},
	},
	state = {
		at = {default = 0},
		line = {default = "", shared = true},
	},
	about = {
		group = "Creatures",
		what = "Says its lines in turn over its head, as it is used.",
		inputs = {
			say = "Says the next line.",
		},
		outputs = {
			said = "It said a line. Value: the line's number.",
		},
	},
	inputs = {say = "none"},
	outputs = {said = "number"},
	on_start = function(c)
		c.state.line = c.params.name
	end,
	on_use = function(c, by)
		say(c, by)
	end,
	on_input = function(c, input, value, by)
		say(c, by)
	end,
}
