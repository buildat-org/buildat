-- Brimstone Speedway's music: a 12-bar boogie in A played by its client part
-- (brim_music.client.lua: blip1 sounds as the notes and the drums, a bar at
-- a time on blip's mixer). Each player's mood: "lobby" (the bass and quiet
-- drums), "race" (the band) or "off", set by "mood" (the race's, by the
-- player); `volume` for everyone, `tempo` in beats a minute.
return {
	version = 1,
	no_position = true,
	about = {
		group = "World",
		what = "Brimstone Speedway's rock and roll: a 12-bar loop made of blip sounds on each player's client, its mood each player's own.",
		inputs = {mood = "The player's music: lobby, race or off."},
	},
	params = {
		volume = {cat = "look", type = "number", default = 0.5, min = 0, max = 1},
		tempo = {cat = "look", type = "number", default = 168, min = 60, max = 260},
	},
	state = {
		mood = {default = {}, per_player = true},
		volume = {default = 0.5, shared = true, param = "volume"},
		tempo = {default = 168, shared = true, param = "tempo"},
	},
	inputs = {mood = "string"},
	on_input = function(c, input, value, by)
		if input == "mood" and type(by) == "string" and
				(value == "lobby" or value == "race" or value == "off") then
			c.state.mood[by] = value
		end
	end,
}
