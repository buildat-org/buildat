-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [DAWN_LIGHT]: the hours the user named, one after another, so that a
-- client can shoot each of them. The three probed hours are in the list
-- too: they are what must not move.
-- The terrain this was written against: devtest's v7, which a new world
-- no longer gets by default (valleys)
core.settings:set("mg_name", "v7")
local HOURS = {"0200", "0400", "0430", "0500", "0545", "1900", "1930",
		"2000", "2030"}

local function at(i)
	local h = HOURS[i]
	if not h then
		core.log("action", "dawn: done")
		return
	end
	local hh = tonumber(h:sub(1, 2))
	local mm = tonumber(h:sub(3, 4))
	core.set_timeofday((hh + mm / 60) / 24)
	core.log("action", "dawn: hour " .. h)
	-- In the client's log as well, which is what a driven run waits on
	core.chat_send_all("dawn: hour " .. h)
	core.after(8, function() at(i + 1) end)
end

core.register_on_joinplayer(function(player)
	-- The clock stands still, so a shot is of the hour it was asked for
	core.settings:set("time_speed", "0")
	-- Late enough that the client has its world drawn before the first
	-- hour: a shot of a world still being meshed is a shot of nothing
	core.after(25, function() at(1) end)
end)
