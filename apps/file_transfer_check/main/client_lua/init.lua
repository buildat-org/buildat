-- apps/file_transfer_check's client ([FILE_TRANSFER_LATENCY]): pings the
-- server every 50 ms; after a second of pings asks for the server's big
-- file, says how long it took to arrive and how the pings fared while it
-- did (every ping sent before the file was in, answered whenever), then
-- "ftc: done". util/file_transfer_check.sh reads the lines.
local log = buildat.Logger("ftc")
local magic = require("buildat/extension/urho3d")
local t0 = buildat.get_time_us()
local last_ping, asked, arrived, done = 0, nil, nil, false
local base, during = {}, {}
local waiting = 0 -- pings sent during the transfer and not answered

local function stats(list)
	if #list == 0 then return "none" end
	local s = {}
	for i, v in ipairs(list) do s[i] = v end
	table.sort(s)
	return string.format("%d pings, median %.0f ms, max %.0f ms", #s,
		s[math.ceil(#s / 2)], s[#s])
end

buildat.sub_packet("main:pong", function(data)
	local sent = tonumber(data)
	local ms = (buildat.get_time_us() - sent) / 1000
	if not asked or sent < asked then
		table.insert(base, ms)
	elseif not arrived or sent <= arrived then
		table.insert(during, ms)
		waiting = waiting - 1
	end
end)

magic.SubscribeToEvent("Update", function()
	if done then return end
	local now = math.floor(buildat.get_time_us())
	if not asked and now - t0 >= 1000000 then
		asked = now
		log:info("ftc: asking for the file")
		buildat.send_packet("main:big", "")
	end
	if now - last_ping >= 50000 and not arrived then
		last_ping = now
		if asked then waiting = waiting + 1 end
		buildat.send_packet("main:ping", string.format("%.0f", now))
	end
	local a = buildat.last_arrival()
	if asked and not arrived and a and a.kind == "file" and a.name == "main/big.bin" then
		-- This frame's time, not a.t: the pings since a.t were counted
		arrived = now
		log:info(string.format("ftc: the file in %.2f s", (arrived - asked) / 1e6))
	end
	if arrived and waiting <= 0 then
		log:info("ftc: pings before: " .. stats(base))
		log:info("ftc: pings during: " .. stats(during))
		log:info("ftc: done")
		done = true
	end
end)
log:info("ftc: started")
