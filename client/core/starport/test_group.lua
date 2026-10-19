-- Buildat: client/core/starport/test_group.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- group.lua's rows ([STARPORT] 2b), with no client:
--   luajit client/core/starport/test_group.lua
local dir = arg[0]:match("^(.*)/") or "."
local g = dofile(dir .. "/group.lua")

local fleet = {id = "f1", name = "Lakeside", description = "builders"}
local servers = {
	{address = "a:1", name = "Alone", players = 2},
	{address = "b:1", name = "Creative", players = 1, fleet = fleet},
	{address = "c:1", name = "Main 1", players = 9, players_max = 10,
		fleet = fleet, pool = "main"},
	{address = "c:2", name = "Main 2", players = 3, players_max = 10,
		fleet = fleet, pool = "main"},
	{address = "c:3", name = "Main 3", players = 3, players_max = 10,
		fleet = fleet, pool = "main"},
}

-- The top: the fleet as one row with everybody's players, the lone one
local top = g.group(servers)
assert(#top == 2, #top)
assert(top[1].kind == "fleet" and top[1].count == 4 and top[1].players == 16)
assert(top[2].kind == "server" and top[2].server.address == "a:1")

-- Inside: the pool as one row, the least loaded first and the address
-- breaking the tie; the fleet's server in no pool as its own
local inside = g.group(servers, "f1")
assert(#inside == 2, #inside)
assert(inside[1].kind == "pool" and inside[1].name == "main")
assert(inside[1].count == 3 and inside[1].players == 15)
assert(inside[1].server.address == "c:2", inside[1].server.address)
assert(inside[1].servers[2].address == "c:3")
assert(inside[1].servers[3].address == "c:1")
assert(inside[2].kind == "server" and inside[2].server.address == "b:1")

-- No limit said: counted against a hundred, so 5 of none is lighter than
-- 9 of 10
local o = g.order_pool({{address = "x", players = 9, players_max = 10},
	{address = "y", players = 5}})
assert(o[1].address == "y")
-- The user's region before the load
local r = g.order_pool({{address = "x", players = 0, region = "us"},
	{address = "y", players = 9, players_max = 10, region = "EU"}}, "eu")
assert(r[1].address == "y")
print("test_group: ok")
