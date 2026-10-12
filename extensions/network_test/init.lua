-- Buildat: extension/network_test/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A menu extension that exercises extension/network against one address:
--
--   $ bin/buildat -m network_test -w 800x600
--
-- With no arguments it opens a UDP socket to localhost:30001 (a Luanti
-- server), sends one datagram and shows whatever comes back.
local log = buildat.Logger("extension/network_test")
local dump = buildat.dump
local magic = require("buildat/extension/urho3d")
local HA_LEFT, LM_VERTICAL, VA_BOTTOM =
		magic.HA_LEFT, magic.LM_VERTICAL, magic.VA_BOTTOM
local uistack = require("buildat/extension/uistack")
local network = require("buildat/extension/network")
local M = {safe = nil}

local HOST = "localhost"
local PORT = 30001

function M.boot()
	local root = uistack.main:push({desc="network_test"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "ui_utils/res/style.xml")

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	local status = window:CreateChild("Text")
	status:SetStyleAuto()

	local function set_status(text)
		log:info(text)
		status.text = text
		-- Alignment does not follow a later resize
		window:SetAlignment(HA_LEFT, VA_BOTTOM)
	end

	set_status("Asking about udp://"..HOST..":"..PORT)

	network.udp_connect(HOST, PORT, function(socket, err)
		if not socket then
			set_status("udp_connect failed: "..err)
			return
		end
		log:info("Socket at "..dump({socket:getsockname()}).." talking to "..
				dump({socket:getpeername()})) 
		-- A Luanti reliable packet with a nonsense body: the server ACKs a
		-- reliable packet before it looks at what is inside, which is enough
		-- of a reply to check the receive path with.
		local packet = string.char(
				0x4f, 0x45, 0x74, 0x03, -- protocol id
				0x00, 0x00,             -- peer id: inexistent
				0x00,                   -- channel
				0x03, 0xff, 0xdc,       -- reliable, seqnum
				0x01, 0x00, 0x02)       -- original, TOSERVER_INIT
		local sent, send_err = socket:send(packet)
		if not sent then
			set_status("send failed: "..send_err)
			return
		end
		set_status("Sent a datagram to "..socket:address())
		local done = false
		magic.SubscribeToEvent("Update", function(event_type, event_data)
			if done then
				return
			end
			local data, err = socket:receive()
			if data then
				set_status("Received "..#data.." bytes from "..socket:address())
			elseif err ~= "timeout" then
				set_status("receive failed: "..err)
				done = true
			end
		end)
	end, {description = "network_test"})
end

return M
-- vim: set noet ts=4 sw=4:
