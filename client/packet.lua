-- Buildat: client/packet.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/packet")

local packet_subs = {}
-- A packet that came before anything subscribed to it, {name, data, time},
-- in order of arrival, kept for HELD_US: an app's setup packet races the
-- engine loader's run_script of the script that subscribes to it, the two
-- sent from separate module threads ([VOXEL_LIGHTING_CAVE]). Handed over
-- once served code has run (__buildat_deliver_held_packets). HELD_MAX and
-- HELD_BYTES bound them, past which a packet is dropped as it was before.
local held = {}
local held_bytes = 0
local HELD_US = 10000000
local HELD_MAX = 256
local HELD_BYTES = 4 * 1024 * 1024

-- Microseconds the packets' Lua took since the reader last took it, and
-- the packet that took longest since then: the frame peak's "packets"
-- phase ([FRAME_PEAK]). A packet's work is a phase of the frame it lands
-- in, and it was the largest one in the first fuzz runs.
buildat.packet_us = {total = 0, worst = 0, worst_name = ""}
-- take_packet_us() -> {total, worst, worst_name}, zeroed after: the
-- sandbox sees its tables read-only, so the taking is the client's
buildat.safe.take_packet_us = function()
	local acc = buildat.packet_us
	local out = {total = acc.total, worst = acc.worst,
			worst_name = acc.worst_name}
	acc.total, acc.worst, acc.worst_name = 0, 0, ""
	return out
end

function __buildat_handle_packet(name, data)
	-- [SERVE_UPDATE_POLITE] 2: the server's admin's notice, whatever the
	-- app subscribed to, in the notice line in its own colour
	if name == "network:notice" then
		log:info("Notice from the server: " .. data)
		require("buildat/extension/ui_utils").safe.show_notice(data, nil,
				"warn")
		return
	end
	local cb = packet_subs[name]
	if not cb then
		local now = buildat.get_time_us()
		while held[1] and now - held[1][3] > HELD_US do
			held_bytes = held_bytes - #held[1][2]
			table.remove(held, 1)
		end
		if #held < HELD_MAX and held_bytes + #data <= HELD_BYTES then
			table.insert(held, {name, data, now})
			held_bytes = held_bytes + #data
		end
	end
	if cb then
		local t0 = buildat.get_time_us()
		cb(data)
		local us = buildat.get_time_us() - t0
		local acc = buildat.packet_us
		acc.total = acc.total + us
		if us > acc.worst then
			acc.worst, acc.worst_name = us, name
		end
	end
end

-- Every handler dropped: a menu-only connection left ([MENU_CONTEXT])
-- [SERVERLESS_PLAY] While an app's client half runs with no server, the
-- packet names it sent, each logged once; nil otherwise
local serverless_sent = nil

function __buildat_reset_packet_subs()
	packet_subs = {}
	held = {}
	held_bytes = 0
	serverless_sent = nil
end

-- The held packets something now subscribes to, in order; after served
-- code has run (sandbox.lua), so a script's handler is called once the
-- whole script has
function __buildat_deliver_held_packets()
	local i = 1
	while i <= #held do
		local name, data = held[i][1], held[i][2]
		local cb = packet_subs[name]
		if cb then
			table.remove(held, i)
			held_bytes = held_bytes - #data
			local ok, err = pcall(cb, data)
			if not ok then
				log:error("held packet "..name..": "..tostring(err))
			end
		else
			i = i + 1
		end
	end
end

function buildat.sub_packet(name, cb)
	packet_subs[name] = cb
end
buildat.safe.sub_packet = buildat.sub_packet

function buildat.unsub_packet(cb)
	for name, cb1 in pairs(packet_subs) do
		if cb1 == cb then
			packet_subs[name] = nil
		end
	end
end
buildat.safe.unsub_packet = buildat.unsub_packet

function buildat.send_packet(name, data)
	if serverless_sent then
		if not serverless_sent[name] then
			serverless_sent[name] = true
			log:info("serverless: " .. tostring(name) .. " goes nowhere")
		end
		return
	end
	__buildat_send_packet(name, data)
end
buildat.safe.send_packet = buildat.send_packet

-- buildat.serverless(): whether this app runs with no server, until it
-- is left ([SERVERLESS_PLAY])
function __buildat_set_serverless()
	serverless_sent = {}
end
buildat.safe.serverless = function()
	return serverless_sent ~= nil
end

-- vim: set noet ts=4 sw=4:
