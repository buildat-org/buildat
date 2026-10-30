-- A spawner: where players appear, and ([KIT] stage 4d) where copies are
-- made. With `players`, a player who goes through the round's start in
-- its scene (Play, or as they come in) is put on it. With a `copy` (an
-- entity) or a `prefab`, "spawn" makes a copy on it (and so every
-- `every` seconds, 0: never), at most `max` of its copies there at once,
-- and "clear" takes them away; without, "spawn" puts there the player who
-- set the signal off (a way back to the start). Its copies are play
-- state, gone at Stop; "Restart this" and deleting it take them away.
-- Several spawners of players: a joining player ends on the last placed
local function copying(c)
	return c.params.prefab ~= "" or c.params.copy ~= 0
end

local function make(c, by)
	if #c.made >= c.params.max then
		c:log("has", #c.made, "copies: no more")
		return
	end
	local id = c:spawn(c.params.prefab ~= "" and {prefab = c.params.prefab} or
			{entity = c.params.copy})
	c:log("made", id, "for", c:name(by))
	c:emit("spawned", id)
end

local function clear(c)
	for _, id in ipairs(c.made) do
		c:remove(id)
	end
	if #c.made > 0 then
		c:log("took away", #c.made, "copies")
	end
end

local function every(c)
	c:after(copying(c) and c.params.every > 0 and c.params.every or -1)
end

return {
	version = 2,
	spawn = "players",
	look = {shape = "sphere", size = 0.3, color = "#40d060"},
	params = {
		players = {type = "bool", default = true},
		copy = {type = "entity", default = 0},
		prefab = {type = "prefab", default = ""},
		max = {type = "number", default = 5, min = 1, max = 100},
		every = {type = "number", default = 0, min = 0, max = 3600},
	},
	inputs = {spawn = "none", clear = "none"},
	outputs = {spawned = "any"},
	on_start = every,
	on_join = function(c, by)
		if not c.params.players then
			return
		end
		c:log("spawns", c:name(by))
		c:teleport(c.pos)
		c:emit("spawned")
	end,
	on_input = function(c, input, value, by)
		if input == "clear" then
			return clear(c)
		end
		if copying(c) then
			return make(c, by)
		end
		c:log("spawns", c:name(by), "again")
		c:teleport(c.pos)
		c:emit("spawned")
	end,
	on_timer = function(c)
		make(c, "app")
		every(c)
	end,
	-- Live editing: its timer as its parameters are now
	on_params = function(c, changed)
		local names = {}
		for k in pairs(changed) do
			names[#names + 1] = k
		end
		table.sort(names)
		c:log("parameters changed:", table.concat(names, " "))
		every(c)
	end,
	on_remove = clear,
}
