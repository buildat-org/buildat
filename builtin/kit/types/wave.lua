-- [KIT_MOVING_OBJECTS] [KIT_COMPONENTS] A free object's motion in play, a function of
-- the round's time, on a placed prefab's root (kit.cpp's timed_motion; a stamped copy
-- does not move): a wave's roll, pitch and yaw (degrees, over its own, each at its
-- period, seconds), a heave along its own up (cells), round pivot (from its place, in
-- its frame). Its members go with it. A player on its top is carried.
-- Not a `movement`: an entity's one movement steps it, this is on top of its row, and
-- [KIT_VEHICLE_MOVEMENTS] on top of a steered one's track (a ship's sea_vessel). The
-- course is kit/course's now, a movement.
return {
	version = 1,
	about = {
		what = "Rolls, pitches and heaves a free object by the round's time.",
	},
	component = true,
	params = {
		wave_roll = {type = "number", default = 0, min = -89, max = 89},
		wave_roll_period = {type = "number", default = 8, min = 0.1, max = 600},
		wave_pitch = {type = "number", default = 0, min = -89, max = 89},
		wave_pitch_period = {type = "number", default = 11, min = 0.1, max = 600},
		wave_yaw = {type = "number", default = 0, min = -180, max = 180},
		wave_yaw_period = {type = "number", default = 13, min = 0.1, max = 600},
		wave_heave = {type = "number", default = 0, min = -64, max = 64},
		wave_heave_period = {type = "number", default = 6, min = 0.1, max = 600},
		-- [KIT_WAVE_PIVOT_CENTER] the object's centre when added, and by its button
		pivot = {type = "position", default = {0, 0, 0}, button = "center"},
	},
}
