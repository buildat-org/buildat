-- A creature's following ([KIT_CREATURES_8A], kit_plan stage 8): a behaviour on a
-- creature's entity. While its senses have a target (c.target, kit/senses'), it
-- goes after them to within distance (m), again as they move (c:propose_move).
-- simplified: the senses' target only (no tame, no owner)
local function think(c)
	local t = c.state.on and c.target or nil
	if t then
		c:propose_move({to = t.pos, range = c.params.distance})
	else
		c:propose_move(nil)
	end
	if (t ~= nil) ~= c.state.following then
		c.state.following = t ~= nil
		c:log(t and "follows " .. t.id or "follows nobody")
	end
end

return {
	version = 1,
	about = {
		what = "A creature behaviour: it goes after its senses' target, to within a distance.",
		inputs = {
			enable = "Follows again.",
			disable = "Follows no more.",
		},
	},
	component = true,
	creature = true,
	params = {
		distance = {type = "number", default = 3, min = 0, max = 32},
		enabled = {type = "bool", default = true},
	},
	state = {on = {default = true, param = "enabled"}, following = {default = false}},
	inputs = {enable = "none", disable = "none"},
	on_start = function(c)
		c:after(0.25)
	end,
	on_timer = function(c)
		think(c)
		c:after(0.25)
	end,
	on_input = function(c, input)
		c.state.on = input == "enable"
		think(c)
	end,
}
