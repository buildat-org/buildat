-- Buildat: client/core/starport/group.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Fleets and pools as the list shows them** ([STARPORT] 2b): the
-- servers of a fetch, which the filters let through, made into what a row
-- is. Plain data in and out, so test_group.lua runs it with no client:
--
--   group(servers)            the top: a row a fleet, a row a server in none
--   group(servers, fleet_id[, region])
--                             inside a fleet: a row a pool, a row a server
--                             in no pool; a pool's servers in `region`
--                             first
--
-- A row: {kind = "fleet"|"pool"|"server", name, description, players,
-- count, fleet (its {id, name, description, link}), servers (the row's,
-- a pool's best first), server (a "server" row's one)}.
local M = {}

local function load_of(x)
	local players = tonumber(x.players) or 0
	local max = tonumber(x.players_max) or 0
	-- One with no limit said counts as full at a hundred
	return players / (max > 0 and max or 100)
end

-- A pool's servers, the one to connect to first: those in the user's
-- region (their Starport setting, "" for none), then the least loaded, the
-- address as the tie-break so every client agrees
function M.order_pool(servers, region)
	local out = {}
	for i, x in ipairs(servers) do
		out[i] = x
	end
	region = (region or ""):lower()
	local function near(x)
		return region ~= "" and tostring(x.region or ""):lower() == region
	end
	table.sort(out, function(a, b)
		if near(a) ~= near(b) then
			return near(a)
		end
		local la, lb = load_of(a), load_of(b)
		if la ~= lb then
			return la < lb
		end
		return tostring(a.address) < tostring(b.address)
	end)
	return out
end

local function players_of(servers)
	local n = 0
	for _, x in ipairs(servers) do
		n = n + (tonumber(x.players) or 0)
	end
	return n
end

function M.group(servers, fleet_id, region)
	local rows, at = {}, {}
	local function bucket(key, make)
		if not at[key] then
			at[key] = make()
			rows[#rows + 1] = at[key]
		end
		return at[key]
	end
	for _, x in ipairs(servers) do
		local f = type(x.fleet) == "table" and x.fleet or nil
		if fleet_id == nil then
			if f and f.id then
				local r = bucket("f:" .. f.id, function()
					return {kind = "fleet", fleet = f, name = f.name,
						description = f.description, servers = {}}
				end)
				table.insert(r.servers, x)
			else
				rows[#rows + 1] = {kind = "server", server = x,
					servers = {x}, name = x.name,
					description = x.description}
			end
		elseif f and f.id == fleet_id then
			local pool = x.pool or ""
			if pool ~= "" then
				local r = bucket("p:" .. pool, function()
					return {kind = "pool", fleet = f, name = pool,
						servers = {}}
				end)
				table.insert(r.servers, x)
			else
				rows[#rows + 1] = {kind = "server", server = x, fleet = f,
					servers = {x}, name = x.name,
					description = x.description}
			end
		end
	end
	for _, r in ipairs(rows) do
		r.count = #r.servers
		r.players = players_of(r.servers)
		if r.kind == "pool" then
			r.servers = M.order_pool(r.servers, region)
			r.server = r.servers[1]
			r.description = r.server.description
		end
	end
	-- The busiest first, as the list was
	table.sort(rows, function(a, b)
		if a.players ~= b.players then
			return a.players > b.players
		end
		return tostring(a.name) < tostring(b.name)
	end)
	return rows
end

return M
-- vim: set noet ts=4 sw=4:
