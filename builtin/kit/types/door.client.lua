-- kit/door's client part ([KIT] stage 4d): the player who uses the door
-- sees it swing at once, before the server's answer (which then stands),
-- and the door turns on its hinge over a fifth of a second rather than
-- jumping, for everyone
local magic = require("buildat/extension/urho3d")
-- Degrees a second
local SPEED = 450

return {
	on_use = function(e)
		e:predict("open", not e:shown("open"))
	end,
	on_update = function(e, dt)
		if not e.hinge then
			return
		end
		local want = e:shown("open") == true and -90 or 0
		if not e.angle then
			e.angle = want
		end
		if e.angle == want then
			return
		end
		local step = SPEED * dt
		if math.abs(want - e.angle) <= step then
			e.angle = want
			e:log("swung to " .. want)
		else
			e.angle = e.angle + (want > e.angle and step or -step)
		end
		e.hinge.rotation = magic.Quaternion(0, e.angle, 0)
	end,
}
