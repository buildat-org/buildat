-- Buildat: extensions/serverlist/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The fetched serverlist's tiles ([LAUNCH_WORLD] step 5). Sandboxed, as
-- every launcher file is: the rows are plain data from the extension's
-- safe side, and a launch hands the address to `luanti_client` through
-- ctx.launch -- the same door its own tile uses.
return function(ctx)
	local sl = require("buildat/extension/serverlist")
	local out = {}
	-- The installed Luanti games' icons, already resolved under the cache
	-- (vanilla's launcher does the same for the games' own tiles)
	local icons = {}
	for _, g in ipairs(buildat.list_installed_games("vanilla")) do
		icons[g.name] = g.icon
	end
	for i, s in ipairs(sl.servers()) do
		local icon = s.game and icons[s.game]
		out[#out + 1] = {
			-- By address, not by place in the list: the key is what the
			-- launch history keeps, and a list fetched again reorders
			-- ([LAUNCH_MENU_V2]'s Continue). -a's characters only.
			id = "s_" .. tostring(s.address):gsub("[^%w%.%-]", "_"),
			label = s.name,
			icon = icon, resolved_icon = icon ~= nil,
			-- **A server, and how much it matters** ([LAUNCH_SIGNIFY]):
			-- the player count, which a launch UI ranks and scales by
			-- without having to know what a server is
			category = "server",
			network = "Luanti", listed_by = "Luanti server list",
			significance = s.players,
			order = 300 + i,
			description = s.address .. "   " .. s.players .. " playing",
			run = function()
				ctx.launch{extension = "luanti_client",
					params = {address = s.address}}
			end,
		}
	end
	-- **The list is fetched because somebody asked**, which is also the
	-- only place the network permission is put in front of a player:
	-- this action is what a room with no rows yet offers instead of them
	out[#out + 1] = {
		id = "refresh",
		label = #out > 0 and "Fetch the server list again" or
				"Fetch the server list",
		order = 299, network = "Luanti", listed_by = "Luanti server list",
		description = "Ask the list this client knows for its servers",
		run = function() sl.refresh() end,
	}
	return out
end
-- vim: set noet ts=4 sw=4:
