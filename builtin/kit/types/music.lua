-- Music ([MUSIC_SYNTH]): `song`, a song in jam's text format (jam1,
-- doc/client_api.txt), synthesised on each client as it plays. Placed on a
-- scene (no position, right under it) it is that scene's, on the app's
-- root every scene's. Kit plays each player the one that is on for them:
-- the highest `priority`, then a scene's over the root's, then the lowest
-- id; on everyone from a round's start with autoplay, or by its inputs
-- (with a player, theirs alone). Everyone hearing it hears the same bar:
-- it runs from when it went on, on the game's clock. A round's end stops
-- it; a scene change keeps it if it is still the one. The client's music
-- volume applies.
return {
	version = 1,
	no_position = true,
	params = {
		song = {cat = "look", type = "song", default = ""},
		autoplay = {type = "bool", default = true},
		mood = {type = "string", default = ""},
		priority = {type = "number", default = 0, min = -100, max = 100},
	},
	state = {
		-- everyone's (Kit reads these): on, and the mood ("" every track)
		playing = {param = "autoplay"},
		mood = {param = "mood"},
		-- a player's own over everyone's ({"player:<id>": v})
		on = {default = {}, per_player = true},
		moods = {default = {}, per_player = true},
	},
	about = {
		group = "World",
		what = "Music: a song written as text, played to the players in its scene (or every scene, on the root).",
		keywords = "song music soundtrack jam",
		inputs = {
			play = "Plays it: to the player who sent it, or to everyone.",
			stop = "Stops it: for the player who sent it, or for everyone.",
			mood = "Sets the mood from the next bar. Value: one of the song's moods (track levels); \"\" for every track.",
		},
		params = {
			song = "The song, in jam's text format.",
			autoplay = "Plays to everyone from the round's start.",
			mood = "The mood it starts in: one of the song's moods (empty: every track).",
			priority = "Of the music on for a player, the highest priority plays.",
		},
	},
	inputs = {play = "none", stop = "none", mood = "string"},
	on_input = function(c, input, value, by)
		if input == "mood" then
			local m = type(value) == "string" and value or ""
			if by then
				c.state.moods[by] = m
			else
				c.state.mood = m
			end
			return
		end
		local on = input == "play"
		if by then
			c.state.on[by] = on
		else
			c.state.playing = on
			-- everyone's: a player's own goes with it
			c.state.on = {}
		end
	end,
}
