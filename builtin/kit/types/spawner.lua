-- A spawner: where players appear. A player who goes through the round's
-- start in its scene (Play, or as they come in) is put on it; "spawn" puts
-- there the player who set the signal off (a way back to the start).
-- Several spawners: a joining player ends on the last placed.
-- simplified: players only; spawning things (copies of an entity) needs
-- entities made at run time, which Kit has not
return {
	version = 1,
	spawn = true,
	look = {shape = "sphere", size = 0.3, color = "#40d060"},
	inputs = {"spawn"},
	outputs = {"spawned"},
	on_join = function(c, by)
		c:log("spawns", by)
		c:teleport(c.pos)
		c:emit("spawned")
	end,
	on_input = function(c, input, value, by)
		c:log("spawns", by, "again")
		c:teleport(c.pos)
		c:emit("spawned")
	end,
}
