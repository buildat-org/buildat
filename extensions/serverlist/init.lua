-- Buildat: extensions/serverlist/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **A fetched serverlist as launch actions** ([LAUNCH_WORLD] step 5's
-- last piece, [SERVER_LIST]). The launch grid is built at boot and a
-- fetch is not, so the rows a launcher file offers are **the last
-- fetch's**, kept in a file of this extension's own; asking for them
-- starts a fetch that rewrites it for the next boot.
--
-- **It changes nothing in `luanti_client`**, which is frozen: that
-- extension's `on_untrusted_launch` already takes an `address`, so a
-- launch action can hand it a server and it opens its connect dialog on
-- one. This is the source of the list and nothing else.
--
-- The fetch goes through `network.http_get`, which asks the user about
-- the host the first time as it does for a socket -- a launcher that
-- reached the network without asking would be the wrong kind of quiet.
local log = buildat.Logger("serverlist")
local M = {safe = {}}
local network = require("buildat/core/network")

-- The list this client knows: Luanti's official one.
-- BUILDAT_SERVERLIST_URL overrides it, which is what the check serves its
-- own list on. It used to be the first https row of the client's address
-- store, which became a Starport's once the client had talked to one, and
-- the list was then asked of the Starport.
local DEFAULT_URL = "https://servers.luanti.org"
-- In the extension's own storage (user/extensions/serverlist/)
local CACHE = "serverlist.csv"
-- simplified: twelve, which is what a launcher's floor or grid has room
-- for; the list has hundreds and a launcher that drew them all would be
-- the list it is replacing. Ordered by players, so the twelve are the
-- ones with somebody on them.
local MAX = 12

local function list_url()
	local env = buildat.get_env and buildat.get_env("BUILDAT_SERVERLIST_URL")
	if env and env ~= "" then
		return env
	end
	return DEFAULT_URL
end

-- One row a line: address|name|players. A file a person can read and
-- delete, as the room's own save is.
local function read_cache()
	local rows = {}
	local data = buildat.storage_read(CACHE)
	if not data then
		return rows
	end
	for line in data:gmatch("[^\r\n]+") do
		local address, name, players, game =
				line:match("^(.-)|(.-)|(%d+)|?([%w_]*)$")
		if address and address ~= "" and #rows < MAX then
			rows[#rows + 1] = {address = address, name = name,
				players = tonumber(players), game = game}
		end
	end
	return rows
end

local function write_cache(rows)
	local out = {}
	for _, r in ipairs(rows) do
		-- A name with a bar or a newline in it would make a second row
		out[#out + 1] = string.format("%s|%s|%d|%s", r.address,
				tostring(r.name):gsub("[|\r\n]", " "), r.players or 0,
				r.game or "")
	end
	local ok, err = buildat.storage_write(CACHE, table.concat(out, "\n"))
	if not ok then
		log:warning("cannot write " .. CACHE .. ": " .. tostring(err))
		return
	end
	log:info(#rows .. " servers cached in " .. CACHE)
end

-- **Whether this client has already said yes to that host.** A launcher
-- that put a permission dialog in front of a first-time user before
-- they had asked for anything would be answering a question nobody
-- posed ([TWO_AUDIENCES]: the room's first frame is the point of it).
-- So a boot fetches only where the answer is already on file, and
-- asking is what the list's own launch action is for.
local function accepted(url)
	-- The host and the port, which is what network's consent is keyed on
	local uri = url:match("^(https?://[^/?#]+)")
	for _, a in ipairs(network.known_addresses()) do
		if a.uri == uri then
			return a.accepted
		end
	end
	return false
end

local fetching = false
local function fetch(ask)
	if fetching then return end
	local url = list_url()
	if not ask and not accepted(url) then
		log:info("not fetching " .. url .. " until asked to: this client" ..
				" has not said yes to it")
		return
	end
	fetching = true
	network.http_get(url .. "/list", function(body, err)
		fetching = false
		if not body then
			log:warning("the list did not come: " .. tostring(err))
			return
		end
		local data = network.parse_json(body)
		local rows = {}
		for _, sv in ipairs(data and data.list or {}) do
			local address = tostring(sv.address or "")
			if address ~= "" then
				rows[#rows + 1] = {
					address = address .. ":" .. tostring(sv.port or 30000),
					name = tostring(sv.name or address),
					-- **The player count is the significance**
					-- ([LAUNCH_SIGNIFY]: a server's is the player count
					-- the last time it was played on), which is what a
					-- launch UI ranks and scales by
					players = tonumber(sv.clients) or 0,
					-- The game it runs, by the list's word: its tile
					-- wears that game's icon where it is installed here
					-- ([SERVER_ICONS])
					game = tostring(sv.gameid or ""):match("^[%w_]+$") or "",
				}
			end
		end
		table.sort(rows, function(a, b) return a.players > b.players end)
		while #rows > MAX do table.remove(rows) end
		write_cache(rows)
	end, {description = "the server list"})
end

-- The rows a launcher file draws: the last fetch's, as plain data
function M.safe.servers()
	local out = {}
	for i, r in ipairs(read_cache()) do
		out[i] = {address = r.address, name = r.name, players = r.players,
			game = r.game}
	end
	return out
end

-- **Fetching it now, and saying so**: the launch action a launcher file
-- offers beside the rows, for the first list and for a fresher one.
-- This is the call that may ask the user about the host.
function M.safe.refresh()
	fetch(true)
end

-- Loading this extension starts a fetch where the host is already
-- accepted, so the rows a launcher draws are the last list this client
-- was given rather than the first one it ever saw
fetch(false)

return M
-- vim: set noet ts=4 sw=4:
