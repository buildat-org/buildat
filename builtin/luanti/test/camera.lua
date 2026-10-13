-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [THIRD_PERSON]: the stage for camera.sh -- the player on a stone floor
-- with a wall two nodes behind them, so the third-person camera from
-- behind has something to be pulled in by, and open ground ahead for the
-- front view
core.register_on_joinplayer(function(player)
	core.after(6, function()
		local p = player:get_pos()
		local base = {x = math.floor(p.x), y = math.floor(p.y) + 30, z = math.floor(p.z)}
		for dz = -6, 6 do
			for dx = -6, 6 do
				for dy = -1, 4 do
					core.set_node({x = base.x + dx, y = base.y + dy, z = base.z + dz},
							{name = dy == -1 and "mcl_core:stone" or "air"})
				end
			end
		end
		-- The wall, two nodes behind a player looking along +z
		for dx = -6, 6 do
			for dy = 0, 3 do
				core.set_node({x = base.x + dx, y = base.y + dy, z = base.z - 2},
						{name = "mcl_core:stone"})
			end
		end
		player:set_pos({x = base.x, y = base.y + 0.5, z = base.z})
		player:set_look_horizontal(0)
		player:set_look_vertical(0)
		-- The zoom key wants a zoom_fov ([VIEW_KEYS]); official's creative
		-- default
		player:set_properties({zoom_fov = 15})
		-- And a second floor forty nodes away with nothing behind the
		-- player at all: the walled stage is what the wall check wants,
		-- and this one is what says how the third-person view frames the
		-- player when nothing is pulling the camera in ([OVER_SHOULDER])
		local open_base = {x = base.x + 40, y = base.y, z = base.z}
		for dz = -10, 10 do
			for dx = -10, 10 do
				for dy = -1, 6 do
					core.set_node({x = open_base.x + dx, y = open_base.y + dy,
							z = open_base.z + dz},
							{name = dy == -1 and "mcl_core:stone" or "air"})
				end
			end
		end
		core.log("action", "camera: the floor and the wall are placed")
		-- What a drive waits for: the client logs a chat line
		core.chat_send_all("camera: the floor and the wall are placed")
		-- Driven by chat rather than by a timer, so it cannot land in the
		-- middle of the walled stage's own shots: the runner types "open"
		core.register_on_chat_message(function(name, message)
			if message ~= "open" then
				return false
			end
			local pl = core.get_player_by_name(name)
			if pl then
				pl:set_pos({x = open_base.x, y = open_base.y + 0.5,
						z = open_base.z})
				pl:set_look_horizontal(0)
				pl:set_look_vertical(0)
			end
			core.chat_send_all("camera: the open stage is ready")
			return true
		end)
	end)
end)
