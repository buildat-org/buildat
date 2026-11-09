-- A teleporter: a pad that moves the player who steps on it (or uses it,
-- or sets off its "teleport") to the cell `to`; [KIT_SCENES] in the scene
-- `scene` when it names another of the composition, or onto the entity
-- `target` (in whichever scene it is), arriving there without stepping on
-- it. `two_way`: the editor places a teleporter back at the target
local function go(c, by, how)
	local p = c.params
	if p.target and p.target ~= 0 then
		c:log(how, c:name(by), "to entity", p.target)
		c:teleport(nil, {entity = p.target})
	elseif p.scene ~= "" then
		c:log(how, c:name(by), "to", p.to[1], p.to[2], p.to[3], "in", p.scene)
		c:teleport(p.to, {scene = p.scene})
	else
		c:log(how, c:name(by), "to", p.to[1], p.to[2], p.to[3])
		c:teleport(p.to)
	end
	c:emit("teleported")
end

return {
	version = 1,
	usable = true,
	zone = "pad",
	-- [KIT_SYMMETRY] to is a place in the world
	space = {to = "world"},
	look = {shape = "sphere", size = 0.35, color = "#8050ff"},
	params = {
		to = {type = "position", default = {0, 1, 0}},
		pad = {type = "position", default = {1, 1, 1}},
		scene = {type = "string", default = "", choices_from = "scenes"},
		target = {type = "entity", default = 0},
		two_way = {type = "bool", default = false},
	},
	about = {
		group = "Building",
		what = "A pad that moves a player who steps on it or uses it.",
		inputs = {
			teleport = "Moves who set it off.",
		},
		outputs = {
			teleported = "A player was moved.",
		},
	},
	inputs = {teleport = "none"},
	outputs = {teleported = "none"},
	on_enter = function(c, by)
		go(c, by, "stepped on by")
	end,
	on_use = function(c, by)
		go(c, by, "used by")
	end,
	on_input = function(c, input, value, by)
		go(c, by, "signalled for")
	end,
}
