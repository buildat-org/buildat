-- Walking ([KIT] stage 4h): a movement (kit/controls' movement, the
-- default) for the players' bodies, on the app root to set its knobs:
-- speed (m/s), acceleration (m/s², times the ground's friction), gravity
-- (m/s²), jump_height (m, 0: no jump), air_control (of the acceleration,
-- in the air), coyote_time (s: a jump just after walking off still
-- counts), jump_buffer (s: one pressed just before landing counts),
-- step_height (m: climbed walking), slope_limit (degrees: the heightmap's
-- slopes walked up, and a free voxel object's deck stood on; past it the deck
-- slides), rate (steps a second) and substeps (a step's).
-- [KIT_AUTO_JUMP] auto_jump: walking into a one-voxel step jumps up it
-- without Jump (skeldat's, Luanti's autojump) -- off, touchscreen (a
-- touch client's, the default) or all. A touch builder's Walk view in
-- the editor has it whatever this says. The client asks for it in its
-- inputs (auto), so the server steps the same.
-- simplified: not on a free object's deck (W:walk_on).
-- The keys W A S D and Space; a touchscreen's stick and Jump.
local BODY = {r = 0.45, h = 1.7, eye = 1.5487}

return {
	version = 1,
	about = {
		what = "A movement: players walk with the keys and jump.",
	},
	root = true,
	movement = {body = BODY, touch = "stick"},
	params = {
		speed = {cat = "physics", type = "number", default = 6, min = 0,
			max = 50},
		acceleration = {cat = "physics", type = "number", default = 50, min = 1,
			max = 500},
		gravity = {cat = "physics", type = "number", default = 20, min = 0,
			max = 100},
		jump_height = {cat = "physics", type = "number", default = 1.25,
			min = 0, max = 10},
		air_control = {cat = "physics", type = "number", default = 0.5, min = 0,
			max = 1},
		coyote_time = {cat = "physics", type = "number", default = 0.1, min = 0,
			max = 1},
		jump_buffer = {cat = "physics", type = "number", default = 0.12,
			min = 0, max = 1},
		step_height = {cat = "physics", type = "number", default = 0.6, min = 0,
			max = 2},
		slope_limit = {cat = "physics", type = "number", default = 50, min = 0,
			max = 89},
		rate = {cat = "advanced", type = "number", default = 60, min = 10,
			max = 120},
		substeps = {cat = "advanced", type = "number", default = 1, min = 1,
			max = 8},
		auto_jump = {cat = "physics", type = "string", default = "touchscreen",
			choices = {"off", "touchscreen", "all"}},
	},
	step = function(s, i, dt, w, p)
		local a = (tonumber(i.yaw) or 0) * w.PI / 180
		local sn, cs = w.sin(a), w.cos(a)
		local f, r = i.f or 0, i.r or 0
		local l = w.sqrt(f * f + r * r)
		if l > 1 then
			f, r = f / l, r / l
		end
		local sp = p.speed or 6
		w:walk(s, BODY, (sn * f + cs * r) * sp, (cs * f - sn * r) * sp,
				i.jump == 1, dt, p, i.auto == 1)
	end,
}
