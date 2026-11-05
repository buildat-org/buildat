-- A sound player ([KIT_SOUNDS]): "play" plays `sound`, one of the
-- project's sounds, at it (heard nearer louder) or, with everywhere, as
-- loud for every player in its scene
return {
	version = 1,
	look = {shape = "sphere", size = 0.25, color = "#30b0e0"},
	params = {
		sound = {cat = "look", type = "sound", default = "kit/click"},
		everywhere = {cat = "look", type = "bool", default = false},
	},
	inputs = {play = "none"},
	on_input = function(c, input, value, by)
		c:sound(c.params.sound, {everywhere = c.params.everywhere})
		c:log("plays", c.params.sound, "by", c:name(by))
	end,
}
