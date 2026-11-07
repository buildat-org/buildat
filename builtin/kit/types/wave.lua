-- [KIT_MOVING_OBJECTS] [KIT_COMPONENTS] A free object's motion in play, a function of
-- the round's time, on a placed prefab's root (kit.cpp's motion_of; a stamped copy does
-- not move): a wave's roll, pitch and yaw (degrees, over its own, each at its period,
-- seconds), a heave along its own up (cells), round pivot (from its place, in its
-- frame); a course of offset cells there and back, course_time each way, as kit/mover's
-- path. Its members go with it. A player on its top is carried.
-- Not a `movement`: an entity's one movement steps it, this is on top of its row, and
-- stage 4r6's steered ship keeps the wave. No driver: a steered pose is that stage's.
return {
	version = 1,
	about = {
		what = "Rolls, pitches and heaves a free object by the round's time, or takes it along a course.",
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
		pivot = {type = "position", default = {0, 0, 0}},
		course = {type = "position", default = {0, 0, 0}},
		course_time = {type = "number", default = 0, min = 0, max = 3600},
	},
}
