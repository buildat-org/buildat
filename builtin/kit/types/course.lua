-- [KIT_VEHICLE_MOVEMENTS] A set course: a free object's root taken along a course of
-- offset cells there and back, course_time each way (kit/mover's path), a function
-- of the round's time on both sides as stage 4r4 made it (lifted out of kit/wave;
-- kit.cpp's timed_motion). Its members go with it, a player on its top is carried.
-- A movement (an entity's one), with nothing to step and no seat to drive it.
return {
	version = 1,
	about = {
		what = "Takes a free object along a course and back, by the round's time.",
	},
	component = true,
	movement = {timed = true, body = {r = 0.5, h = 1}},
	params = {
		course = {type = "position", default = {0, 0, 0}},
		course_time = {type = "number", default = 0, min = 0, max = 3600},
	},
	step = function() end,
}
