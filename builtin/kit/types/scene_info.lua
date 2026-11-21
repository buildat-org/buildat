-- A scene's title ([KIT_SCENE_PACKAGES]): placed on a scene (no position,
-- right under it, as a kit/environment of its own), its `title` (the
-- scene's name where empty) and `author`; `listed` (on by default) puts the
-- scene in the list of scenes the players pick from (kit/ui_scene_list, a
-- kit/arena's maps "*"). A scene without one is not listed.
return {
	version = 1,
	no_position = true,
	-- [KIT_SINGLE] its scene's first is used: one a holder
	single = true,
	params = {
		title = {type = "string", default = ""},
		author = {type = "string", default = ""},
		listed = {type = "bool", default = true},
	},
	about = {
		group = "Game",
		what = "A scene's title and author, and whether players can pick it.",
		keywords = "track level map arena list",
		params = {
			title = "The scene's title (empty: its name).",
			author = "Who made the scene.",
			listed = "Puts the scene in the list players pick scenes from.",
		},
	},
}
