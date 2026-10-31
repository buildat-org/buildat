-- [FORCELOAD_STARVED]: a forceload and an emerge_area far from the
-- player, asked for while the player keeps generating: a fixture for
-- forceload_starved.sh. The player is moved two sections along +x every
-- second, which is more new terrain than the generator makes in that time
-- on any machine this runs on, so the player always has sections waiting.
-- Each far block is logged once it is there, with the seconds it took and
-- how many times the player had moved by then; the walk stops at 120 s.
local FL = {x = -3000, y = 0, z = -3000}
local EM = {x = 3000, y = 0, z = -3000}
local t0, moved = nil, 0
local fl_done, em_done = false, false

local function since()
	return (core.get_us_time() - t0) / 1e6
end

local function watch_fl()
	if core.get_node(FL).name ~= "ignore" then
		fl_done = true
		core.log("action", ("fl: forceloaded block in after %.1f s, " ..
				"the player moved %d times"):format(since(), moved))
		return
	end
	core.after(0.2, watch_fl)
end

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local x = 0
	local function walk()
		local p = core.get_player_by_name(name)
		if not p then
			return
		end
		if (fl_done and em_done) or since() > 120 then
			core.log("action", ("fl: the walk stopped after %d moves, " ..
					"at x=%d"):format(moved, x))
			return
		end
		x = x + 128
		p:set_pos({x = x, y = 40, z = 0})
		moved = moved + 1
		core.after(1, walk)
	end
	core.after(3, function()
		t0 = core.get_us_time()
		core.log("action", "fl: asked; the player walks from x=0")
		core.forceload_block(FL, true)
		core.emerge_area(EM, EM, function(bp, action, left)
			if left == 0 then
				em_done = true
				core.log("action", ("fl: emerged block in after %.1f s " ..
						"(action %d), the player moved %d times"):format(
						since(), action, moved))
			end
		end)
		watch_fl()
		walk()
	end)
end)
