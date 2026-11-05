-- An action ([KIT_INPUT_ACTIONS], stage 4m): a key the players press,
-- named `action`. `key` is its default (each player may bind their own:
-- the pause menu's Settings, Key bindings), `label` what the keys page and
-- a touchscreen's button call it. "[<action>]" in a sign's text shows each
-- player the key they have for it. It signals "pressed" and "released" as
-- a player presses and lets go, and "held" with the seconds held every
-- 0.1 s in between; each as by that player
return {
	version = 1,
	no_position = true,
	params = {
		action = {type = "string", default = "fire"},
		key = {type = "string", default = "R"},
		label = {type = "string", default = "Fire"},
	},
	actions = {{name = "param:action", key = "param:key",
		label = "param:label"}},
	state = {presses = {default = 0, shared = true}},
	outputs = {pressed = "none", released = "none", held = "number"},
	on_action = function(c, name, phase, value, by)
		if phase == "pressed" then
			c.state.presses = c.state.presses + 1
			c:log(name, "pressed by", c:name(by))
		end
		c:emit(phase, phase == "held" and value or nil)
	end,
}
