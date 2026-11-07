-- [KIT_PREFAB_ROOT] A placed prefab's root: the editor's place of a prefab
-- makes it, its members under it as its built children. It does nothing in
-- play; its place and turn are the copy's. Not in the palette.
-- [KIT_FREE_PREFAB] mode: its voxels stamped into the world, or a free object
-- of the prefab's model at its place and any turn (kit.cpp's sync_free_objects):
-- [KIT_FREE_ROTATION] yaw, pitch and roll free, stamped multiples of 90 of yaw only.
-- [KIT_MOVING_OBJECTS] A free one's motion in play, a function of the round's time:
-- a wave's roll, pitch and yaw (degrees, over its own, each at its period, seconds), a
-- heave along its own up (cells), round pivot (from its place, in its frame); a course
-- of offset cells there and back, course_time each way, as kit/mover's path. Its members
-- go with it. No driver: a steered one's pose is a stage 4r6's. A player on its top is
-- carried. simplified: a motion's parameters here; 4r5's components are the upgrade.
return {
	version = 1,
	about = {
		what = "A placed prefab's root: where the copy is and how it is turned.",
	},
	params = {
		mode = {type = "string", default = "stamped",
			choices = {"stamped", "free"}},
		wave_roll = {cat = "physics", type = "number", default = 0, min = -89, max = 89},
		wave_roll_period = {cat = "physics", type = "number", default = 8, min = 0.1,
			max = 600},
		wave_pitch = {cat = "physics", type = "number", default = 0, min = -89, max = 89},
		wave_pitch_period = {cat = "physics", type = "number", default = 11, min = 0.1,
			max = 600},
		wave_yaw = {cat = "physics", type = "number", default = 0, min = -180, max = 180},
		wave_yaw_period = {cat = "physics", type = "number", default = 13, min = 0.1,
			max = 600},
		wave_heave = {cat = "physics", type = "number", default = 0, min = -64, max = 64},
		wave_heave_period = {cat = "physics", type = "number", default = 6, min = 0.1,
			max = 600},
		pivot = {cat = "physics", type = "position", default = {0, 0, 0}},
		course = {cat = "physics", type = "position", default = {0, 0, 0}},
		course_time = {cat = "physics", type = "number", default = 0, min = 0, max = 3600},
	},
	gizmo = {shape = "box", size = 0.25, color = "#60d0d0"},
}
