-- A hull ([KIT_AIRSHIPS]): on a free voxel object's root (a prefab's
-- "root" components, a ship from a kit/shop), what play may do to its voxels.
-- Kit reads it on each place and dig aimed at the object ("kit:obuild"):
--   build  who builds on it: owner (its owner alone), team (the owner's
--          team too), anyone, nobody
--   cost   what a placed voxel takes from the placer's kit/wallet (0: free;
--          a dig gives nothing back)
-- Its owner (a player's id, 0 none) is set by "own", as by whom: a shop
-- sends it to the ship it sold. Without a hull a free object is not built
-- on in play. Editing ignores it.
return {
	version = 1,
	component = true,
	params = {
		build = {type = "string", default = "owner",
			choices = {"owner", "team", "anyone", "nobody"}},
		cost = {type = "number", default = 0, min = 0, max = 1000},
	},
	state = {owner = {default = 0, shared = true}},
	about = {
		what = "Who builds on a free voxel object in play, and what a voxel costs.",
		inputs = {
			own = "Makes who sent it the owner.",
		},
	},
	inputs = {own = "none"},
	on_input = function(c, input, value, by)
		c.state.owner = c.player or 0
		c:log("owned by", c:name(by))
	end,
}
