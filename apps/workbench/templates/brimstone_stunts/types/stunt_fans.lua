-- Brimstone Stunts' spectators (4z38): rows of fans on a stand (a kit/part
-- wedge on the same entity, rising toward its back: turned by `facing` as
-- the part by its rotation's y), drawn by the client part
-- (stunt_fans.client.lua), still till this player's car is near, then
-- hopping and waving. Nothing on the server.
return {
	version = 1,
	about = {
		group = "Game",
		what = "Spectators on a stand who cheer when a car comes near (drawn on each client).",
		params = {
			size = "The stand's size (its kit/part's): width, height, depth in metres.",
			rows = "Rows of fans up the stand.",
			facing = "The stand's turn round y in degrees (its kit/part's rotation's y).",
			near = "How near a car sets them cheering, in metres.",
		},
	},
	client_params = {"size", "rows", "facing", "near"},
	params = {
		size = {cat = "look", type = "position", default = {16, 2.4, 4}},
		rows = {cat = "look", type = "number", default = 3, min = 1, max = 6},
		facing = {cat = "look", type = "number", default = 0, min = -360, max = 360},
		near = {cat = "look", type = "number", default = 30, min = 1, max = 100},
	},
}
