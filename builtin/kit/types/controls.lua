-- The players' controls ([KIT] stage 4h), game-wide, on the app root
-- ([KIT_SCENE_TREE] or on a scene: its players' and those of the scenes
-- under it, the nearest copy from a player's scene up winning, whole; a
-- movement's own parameters likewise, its nearest copy's): the
-- camera (first_person: the eye; chase: behind the player, distance away;
-- top_down: from height above at a fixed angle and yaw, ortho a flat
-- view; [KIT_PLANE] side: distance across the plane looking along +z, x
-- right and y up, following once the body is dead_zone m off the middle
-- (0: always), never turning, ortho flat, what is nearer than side_clip m
-- in front of the plane clipped (0.55: all in front of the plane's layer;
-- more for kit/polygon's foreground); [KIT_SIDE_LEAD] the point followed
-- led look_ahead m along x the way the body faces and its velocity times
-- look_velocity s, eased over half a second, at most half the view's half
-- width and height (the body stays in the view's middle half); left and
-- right walk along x, the body facing that way, the pointer aims in the
-- plane), the pointer (crosshair: the
-- view's middle and
-- mouse look; cursor: a free mouse pointer, the view turned with the right
-- button; auto: a cursor for top_down and side), camera_frame (a walker
-- standing on a free voxel object: world keeps the horizon level, object
-- tilts the first person and chase views with the deck), the movement (a type
-- stepping the players' bodies: kit/walker, kit/click_to_move, any other
-- with a step but a creature's or a course's; "none"), [KIT_PLANE] plane
-- (vertical: the players' bodies held at one z, the depth of the spawn a
-- joining player ends on, a whole z, both sides stepping so; [KIT_TOP_DOWN]
-- horizontal: held at one height, the feet on the bottom of the spawn's cell,
-- moving in x and z, no gravity or jump for kit/walker; none) and the
-- view's detail:
-- fov, an offset, smoothing (seconds), roll (degrees), and the effects
-- tint (#rrggbb) at tint_amount, vignette, blur and glitch (0...1). The
-- inputs play for everyone (to = player: the player who set them off):
-- shake (an amount, decaying at shake_decay a second; [KIT_FEEDBACK_EFFECTS]
-- a position: shake_amount, on each client full within shake_near m of its
-- camera, nothing from shake_far, 0 everywhere full), fov (to a value
-- over fov_time; 0: back), glitch (for seconds), tint (a flash of a
-- colour) and camera (a mode: "" the camera's own). [KIT_SPECTATE_CAMERA]
-- camera_target (an entity id or a position; 0 none): side, top_down and
-- chase follow it in place of the body, first_person looks at it; for the
-- player who set it off, else everyone, `to` or not. [KIT_EDIT_VIEW]
-- edit_view: the editor's view at a client's first edit mode (auto: the
-- editor's own, a remembered one; 2d, 3d; [KIT_CRAG_PLAYTEST_1] 2d is the
-- Front view where the camera is side), over the remembered,
-- the builder's picks standing after it. Without it an app
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
	elseif input == "camera_target" then
		-- [KIT_SPECTATE_CAMERA] Each player's (by player id; "": all of them),
		-- whatever `to` says: one by a player sets theirs, one by nobody
		-- everyone's. 0: none. by stays empty, so the server sends it to all.
		-- simplified: a gone player's entry stays till the next one by nobody
		local t = 0
		if type(value) == "table" then
			t = {tonumber(value[1]) or 0, tonumber(value[2]) or 0,
				tonumber(value[3]) or 0}
		elseif tonumber(value) then
			t = math.max(0, math.floor(tonumber(value)))
		end
		local id = tostring(by or ""):match("^player:(%d+)$")
		v.targets = id and type(s) == "table" and type(s.targets) == "table" and
				s.targets or {}
		v.targets[id or ""] = t
		v.by = ""
		value = type(t) == "table" and table.concat(t, ",") or t
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
			choices = {"first_person", "chase", "top_down", "side"}},
		pointer = {type = "string", default = "auto",
			choices = {"auto", "crosshair", "cursor"}},
		camera_frame = {type = "string", default = "world",
			choices = {"world", "object"}},
		movement = {type = "string", default = "kit/walker",
			choices_from = "movements"},
		plane = {type = "string", default = "none",
			choices = {"none", "vertical", "horizontal"}},
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
		dead_zone = {cat = "look", type = "number", default = 0, min = 0,
			max = 20},
		look_ahead = {cat = "look", type = "number", default = 0, min = 0,
			max = 20},
		look_velocity = {cat = "look", type = "number", default = 0, min = 0,
			max = 5},
		side_clip = {cat = "look", type = "number", default = 0.55, min = 0.05,
			max = 60},
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
		edit_view = {type = "string", default = "auto",
			choices = {"auto", "2d", "3d"}},
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
			camera = "Changes the camera's mode. Value: first_person, chase, top_down or side; \"\" its own.",
			camera_target = "Aims its sender's camera (no sender: all), whatever `to` says. Value: an entity id or [x, y, z]; 0 back.",
		},
	},
	inputs = {shake = "any", fov = "any", glitch = "any", tint = "any",
		camera = "any", camera_target = "any"},
	on_input = signal,
}
