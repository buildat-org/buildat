-- apps/drive_waits_check's client ([DRIVE_WAITS]): at its start asks the
-- server to act (answered half a second later) and fills a queue of 300
-- that drains 5 a frame, registered as the idle source "dwc queue". "dwc:
-- drained" when it is empty. In a command sequence, `event check` says
-- whether the answer is in and how long the queue is, and `event mark`
-- how many frames this has seen. util/drive_waits_check.sh reads the lines.
local log = buildat.Logger("dwc")
local magic = require("buildat/extension/urho3d")
local queue, frames, acted = 300, 0, false

buildat.idle_source("dwc queue", function()
	return queue
end)
buildat.sub_packet("main:acted", function(data)
	acted = true
	log:info("dwc: acted")
end)
magic.SubscribeToEvent("Update", function()
	frames = frames + 1
	if queue > 0 then
		queue = math.max(0, queue - 5)
		if queue == 0 then
			log:info("dwc: drained")
		end
	end
end)
magic.SubscribeToEvent("command_seq:check", function(event_type, event_data)
	log:info("dwc: check: acted " .. (acted and "yes" or "no") ..
			", queue " .. queue)
end)
magic.SubscribeToEvent("command_seq:mark", function(event_type, event_data)
	log:info("dwc: mark: frame " .. frames)
end)
buildat.send_packet("main:act", "")
log:info("dwc: started")
