-- The players' controls ([KIT] stage 4h), game-wide, on the app root: the
-- camera (first_person: the eye; chase: behind the player, distance away;
-- top_down: from height above at a fixed angle and yaw, ortho a flat
-- view), the pointer (crosshair: the view's middle and mouse look;
-- cursor: a free mouse pointer, the view turned with the right button;
-- auto: a cursor for top_down), camera_frame (a walker standing on a free
-- voxel object: world keeps the horizon level, object tilts the first person
-- and chase views with the deck), the movement (a type stepping the
-- players' bodies: kit/walker, kit/click_to_move) and the view's detail:
-- fov, an offset, smoothing (seconds), roll (degrees), and the effects
-- tint (#rrggbb) at tint_amount, vignette, blur and glitch (0...1). The
-- inputs play for everyone (to = player: the player who set them off):
-- shake (an amount, decaying at shake_decay a second; [KIT_FEEDBACK_EFFECTS]
-- a position: shake_amount, on each client full within shake_near m of its
-- camera, nothing from shake_far, 0 everywhere full), fov (to a value
-- over fov_time; 0: back), glitch (for seconds), tint (a flash of a
-- colour) and camera (a mode: "" the camera's own). Without it an app
-- with Kit's controls walks with kit/walker in first person.
local function signal(c, input, value, by)
	local s = c.state[input]
	local n = type(s) == "table" and (tonumber(s.n) or 0) + 1 or 1
	local who = tostring(by or ""):match("^player:") and c:name(by) or ""
	local v = {n = n, by = who}
	if input == "shake" then
		if type(value) == "table" then
			v.amount = c.params.shake_amount
			v.at = {tonumber(value[1]) or 0, tonumber(value[2]) or 0,
				tonumber(value[3]) or 0}
		else
			v.amount = math.max(0, math.min(5, tonumber(value) or 1))
		end
	elseif input == "fov" then
		v.value = math.max(0, math.min(170, tonumber(value) or 0))
	elseif input == "glitch" then
		v.seconds = math.max(0, math.min(30, tonumber(value) or 1))
	elseif input == "tint" then
		v.color = type(value) == "string" and value or "#ffffff"
	elseif input == "camera" then
		v.mode = type(value) == "string" and value or ""
	end
	c.state[input] = v
	c:log(input, tostring(value), who ~= "" and "for " .. who or "")
end

return {
	version = 1,
	root = true,
	controls = true,
	params = {
		camera = {type = "string", default = "first_person",
			choices = {"first_person", "chase", "top_down"}},
		pointer = {type = "string", default = "auto",
			choices = {"auto", "crosshair", "cursor"}},
		camera_frame = {type = "string", default = "world",
			choices = {"world", "object"}},
		movement = {type = "string", default = "kit/walker",
			choices = {"kit/walker", "kit/click_to_move", "none"}},
		fov = {cat = "look", type = "number", default = 75, min = 20,
			max = 150},
		distance = {cat = "look", type = "number", default = 6, min = 1,
			max = 60},
		height = {cat = "look", type = "number", default = 14, min = 2,
			max = 200},
		angle = {cat = "look", type = "number", default = 60, min = 10,
			max = 90},
		yaw = {cat = "look", type = "number", default = 0, min = -360,
			max = 360},
		ortho = {cat = "look", type = "bool", default = false},
		smoothing = {cat = "look", type = "number", default = 0.1, min = 0,
			max = 2},
		offset_x = {cat = "look", type = "number", default = 0, min = -10,
			max = 10},
		offset_y = {cat = "look", type = "number", default = 0, min = -10,
			max = 10},
		offset_z = {cat = "look", type = "number", default = 0, min = -10,
			max = 10},
		roll = {cat = "look", type = "number", default = 0, min = -180,
			max = 180},
		tint = {cat = "look", type = "string", default = "#ff4020"},
		tint_amount = {cat = "look", type = "number", default = 0, min = 0,
			max = 1},
		vignette = {cat = "look", type = "number", default = 0, min = 0,
			max = 1},
		blur = {cat = "look", type = "number", default = 0, min = 0, max = 1},
		glitch = {cat = "look", type = "number", default = 0, min = 0, max = 1},
		shake_decay = {cat = "look", type = "number", default = 3, min = 0.1,
			max = 30},
		shake_amount = {cat = "look", type = "number", default = 1, min = 0,
			max = 5},
		shake_near = {cat = "look", type = "number", default = 2, min = 0,
			max = 200},
		shake_far = {cat = "look", type = "number", default = 0, min = 0,
			max = 500},
		fov_time = {cat = "look", type = "number", default = 0.3, min = 0,
			max = 10},
		to = {type = "string", default = "all", choices = {"all", "player"}},
	},
	-- Any signal: one without a value is shake 1, fov back, glitch 1 s,
	-- tint white, the camera's own
	about = {
		group = "Players",
		what = "The players' camera, pointer and movement, for the whole game.",
		inputs = {
			shake = "Shakes the camera. Value: an amount (none: 1), or a position to shake from.",
			fov = "Takes the view's angle over its fov time. Value: the angle; 0 goes back.",
			glitch = "A glitch on the screen. Value: its seconds (none: 1).",
			tint = "A flash of a colour. Value: #rrggbb (none: white).",
			camera = "Changes the camera's mode. Value: first_person, chase or top_down; \"\" its own.",
		},
	},
	inputs = {shake = "any", fov = "any", glitch = "any", tint = "any",
		camera = "any"},
	on_input = signal,
}
