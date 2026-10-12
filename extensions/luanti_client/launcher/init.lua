-- Buildat: extensions/luanti_client/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The Luanti client's tile on the launch grid ([LAUNCH_GRID]). Sandboxed:
-- it cannot reach the extension's trusted half, so the launch goes through
-- ctx.launch and the extension's on_untrusted_launch(), which treats the
-- params as it would a packet from a server.
return function(ctx)
	local out = {
		{id = "connect", label = "Join a Luanti server",
			icon = "grass_block.png", order = 20, network = "Luanti",
			description = "By its address, or from Luanti's server list",
			run = function() ctx.launch{extension = "luanti_client"} end},
		-- The client's own settings ([EXT_SETTINGS]): a trusted screen on
		-- the stack, no server behind it
		{id = "settings", label = "Luanti client settings",
			icon = "grass_block.png", order = 191,
			description = "Render mode, view range, view bobbing, name",
			run = function()
				ctx.launch{extension = "luanti_client", params = {menu = "settings"}}
			end},
	}
	-- **The Luanti servers this client has joined** ([LAUNCH_MENU_V2]):
	-- the network store's udp:// rows, keyed by address as serverlist's
	-- are, with the name used there; the connect dialog opens filled in
	local net = require("buildat/extension/network")
	net = net.known_addresses and net or net.safe
	for _, a in ipairs(net.known_addresses()) do
		local address = a.uri:match("^udp://(.+)$")
		if address and a.accepted then
			out[#out + 1] = {
				id = "s_" .. address:gsub("[^%w%.%-]", "_"),
				label = address, icon = "grass_block.png", category = "server",
				network = "Luanti",
				order = 290,
				description = address .. (a.name ~= "" and "   as " ..
						a.name or ""),
				run = function()
					ctx.launch{extension = "luanti_client",
						params = {address = address,
							name = a.name ~= "" and a.name or nil}}
				end,
			}
		end
	end
	return out
end
