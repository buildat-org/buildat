-- Buildat: vanilla/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A window onto a Luanti world running inside buildat_server, and the player
-- standing in it: the box walks, falls, climbs a step and is stopped by what
-- it runs into, and the camera sits where its eyes are. The physics is
-- player.lua, copied from extensions/luanti_client, which is also where its
-- checks live; what is here is the keys, the camera and the world to ask
-- about.
local log = buildat.Logger("vanilla")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")
-- The module's own client half: what a Luanti game's textures are made of,
-- when a tile is an expression rather than a file, and what the player is
-- carrying
local luanti = require("buildat/module/luanti")

local scene = replicate.main_scene

-- Where the module's client half puts the objects: a Luanti world's dropped
-- items and entities are drawn by it, into whatever scene this game has
luanti.set_scene(scene)

-- Seen from outside itself, so nothing drops to a reduced LOD, and nothing
-- here walks on anything
-- How far full detail reaches. Past it voxelworld meshes a chunk from a
-- downsampled volume, which is what the lod_detail setting picks below;
-- 4000 is the largest view range there is, so this is "never" until the
-- settings say otherwise.
voxelworld.lod_distance = 4000
-- What is asked of the server until the settings say ([VIEW_RANGE]): the
-- same 120 as the setting's default, so the answer's arrival changes
-- nothing on a fresh install
voxelworld.send_distance = 120
-- The terrain's horizon into every chunk's mesh, and the vertex alpha
-- packed with it; the shader reads it so ([PBR_FIT] 2c)
voxelworld.horizon = true
voxel_shading.set_packed_sky(true)
voxelworld.physics_distance = 1
voxelworld.use_skylight = true

-- A Luanti world's light value says how much sky reaches a voxel, so that is
-- what says whether the sun reaches a surface: without this the sun lights
-- the walls of a cave it cannot see into, because a shadow map cannot tell
-- a cave from a canopy. See use_sun_gate() in builtin/voxel_shading.
voxel_shading.use_sun_gate(true)

-- And Luanti's own shaders rather than buildat's. One set, in
-- extensions/luanti_client/res/, used by both Luanti clients: this launcher
-- and the extension. builtin/voxel_shading is nine other games' look and
-- stays theirs -- it is still what chooses between these eight and what
-- pushes their parameters, and the .glsl behind them is the extension's.
-- See [SHADER_HOME] in doc/plan/master_plan.md.
-- BUILDAT_LUANTI_ABLATE=gate: the sun-gated four replaced by the plain
-- four, so the nibble never gates the sun -- a fit's ablation ([PBR_FIT])
local gated = not (buildat.get_env("BUILDAT_LUANTI_ABLATE") or ""):find("gate")
voxel_shading.use_technique_set({
	plain = "luanti_client/res/LuantiVoxel.xml",
	modifiers = "luanti_client/res/LuantiVoxelModifiers.xml",
	alpha = "luanti_client/res/LuantiVoxelAlpha.xml",
	masked = "luanti_client/res/LuantiVoxelMasked.xml",
	sun = gated and "luanti_client/res/LuantiVoxelSun.xml" or
			"luanti_client/res/LuantiVoxel.xml",
	sun_modifiers = gated and "luanti_client/res/LuantiVoxelSunModifiers.xml" or
			"luanti_client/res/LuantiVoxelModifiers.xml",
	sun_alpha = gated and "luanti_client/res/LuantiVoxelSunAlpha.xml" or
			"luanti_client/res/LuantiVoxelAlpha.xml",
	sun_masked = gated and "luanti_client/res/LuantiVoxelSunMasked.xml" or
			"luanti_client/res/LuantiVoxelMasked.xml",
})

-- Luanti's origin is where its mods build, so that is what the camera frames
local LOOK_AT = {x = 0, y = 2, z = 0}
local CAMERA_DISTANCE = 34
-- [UNDERGROUND_LIGHT]: the cave ambient the last frame was drawn with,
-- for the reference note beside a picture. A file-scope local, because the
-- note is defined with the render path and read long before sky_now exists.
local cave_ambient_now = 0
-- [DAWN_LIGHT]: the sun's height (its elevation's sine) and the day factor
-- the frame was drawn with, for the same note. Whether the predawn term is
-- even in its window at an hour is a fact about these two numbers, and a
-- picture cannot be asked it.
local sun_height_now, day_factor_now, predawn_now = 0, 0, 0

-- Luanti's own default, and what extensions/luanti_client uses
-- (BASE_FOV = 72): the two are compared frame against frame, and nothing in
-- a frame lines up while the cameras see different amounts of the world
local CAMERA_FOV = 72
-- The viewing range's default ([VIEW_RANGE]); the setting replaces it
local FAR_CLIP = 120
local VIEW_DIR = {x = -0.7, y = -0.55, z = -0.7}

local MOUSE_SENSITIVITY = 0.15

-- Below this a landing costs nothing, in nodes a second. Luanti's own
-- number, BS*14 on its wire; the server has it too and is the one that
-- decides, this only keeps a packet from going for every step off a kerb.
local FALL_TOLERANCE = 14

-- The player's own physics, which knows neither the protocol nor Urho3D:
-- see the header of player.lua
local ok_player, err_player, player_physics =
		buildat.run_script_file("main/player.lua")
if not ok_player or type(player_physics) ~= "table" then
	error("vanilla: could not load player.lua: " .. tostring(err_player))
end

-- A game's own sky, which is six pictures rather than a gradient; see the
-- header of skybox.lua
local ok_sky, err_sky, skybox = buildat.run_script_file("main/skybox.lua")
if not ok_sky or type(skybox) ~= "table" then
	error("vanilla: could not load skybox.lua: " .. tostring(err_sky))
end

-- And the sky itself, which is Luanti's own shader rather than buildat's;
-- see the header of luanti_sky.lua
local ok_lsky, err_lsky, luanti_sky =
		buildat.run_script_file("main/luanti_sky.lua")
if not ok_lsky or type(luanti_sky) ~= "table" then
	error("vanilla: could not load luanti_sky.lua: " ..
			tostring(err_lsky))
end

-- The keys, in one place, so that what the player is told and what the code
-- reads cannot drift apart. Luanti's own defaults, and the F5 line below
-- lists them. `name` is what a player is shown, because a key constant is
-- not something to put in front of one.
-- The bindings and their editor live in keys.lua ([KEY_BINDINGS]); the
-- table here is that one, so a rebound key is what key_down() reads
local keys = (function(ok, err, m)
	if not ok or type(m) ~= "table" then
		error("vanilla: could not load keys.lua: " .. tostring(err))
	end
	return m
end)(buildat.run_script_file("main/keys.lua"))
local BINDINGS = keys.BINDINGS
local BIND = keys.BIND

local function key_down(action)
	local b = BIND[action]
	-- A touchscreen's stick and buttons (luanti/touch.lua) hold the same
	-- actions the keys do
	if keys.touch and keys.touch.held[action] then
		return true
	end
	return b ~= nil and b.key ~= nil and magic.input:GetKeyDown(b.key)
end


-- The same PBR setup the lighting games use; apps/voxel_lighting's README
-- says why these numbers are what they are. These are what noon looks like;
-- the sun moves with the world's clock, and night is the same sun dimmed
-- and turned blue -- see update_sky() below.
-- Luanti's own hue, at this game's own level. Its get_sunlight_color() is
-- all but neutral at noon -- 0.96, 0.96, 1.058, a tenth more blue than red
-- -- where this was nearly twice as blue as red and a quarter more green.
-- The mesher bakes the skylight into the vertex colour's alpha and the
-- shader adds cAmbientColor * alpha + rgb, so the ambient colour multiplies
-- every sky-lit surface: a blue ambient is a blue world.
--
-- **Set against pictures** (2026-09-16), which is what the note here used to
-- say this was waiting for. At 13:00 the reference shots put the module's
-- sunlit surfaces where official Luanti's are -- the 90th percentile of the
-- frame was 0.757 against 0.769 -- and its shade at nearly twice Luanti's:
-- 0.365 against 0.200. A sunlit surface is mostly sun and a shaded one is
-- almost all ambient, so the ambient is the term that separates them, and it
-- is [TOO_BRIGHT]'s "the top slightly above Luanti's, the bottom far below
-- it" in one number. The hue stays Luanti's, neutral.
local SKY_AMBIENT = magic.Color(0.144, 0.144, 0.158)
-- What is left when the sun is down. **Set against pictures** (2026-09-16):
-- at 20:30 the old value put the ground four times brighter than official
-- Luanti's, where extensions/luanti_client -- which derives its night ambient
-- from the sky with a floor of 0.015 of the moon's own colour -- lands within
-- a percent of it. The same hue, at the level the reference shots ask for;
-- see [TOO_BRIGHT] in doc/plan/rendering_plan.md.
local NIGHT_AMBIENT = magic.Color(0.012, 0.0144, 0.024)
-- **Set against pictures** (2026-09-16). At 13:00 a patch of sunlit grass
-- measured twice official Luanti's -- 0.396, 0.483, 0.349 against 0.186,
-- 0.234, 0.153, and the same ratio at a second patch -- while a shaded cliff
-- face measured 1.09 times its and the sky 1.04 times its. So the sun was the
-- whole of what was left, and twice is not the "slightly brighter than
-- non-PBR official Luanti, crisper, not excessive" the brief asks for. It
-- also blew the brightest surfaces out: foreground sand came back 1.00, 1.00,
-- 0.91 where its own texture is 0.87, 0.67, 0.50 and official Luanti draws it
-- at 0.85, 0.64, 0.48 -- white, and with the colour of the sand gone. See
-- [TOO_BRIGHT] in doc/plan/rendering_plan.md.
local SUN_BRIGHTNESS = 28.0
-- A fiftieth of the sun, which is extensions/luanti_client's number and is
-- not a measurement: real moonlight would render as nothing. It is a night
-- lit coldly from where the moon is, far enough above the sky's own light
-- that the moon casts a shadow. See [LIGHT_SHAPE].
local MOON_BRIGHTNESS = 1.0
-- [PBR_FIT] term 1: the pbr path's sun, sky and moon in the path-traced
-- reference's units, one copy for both Luanti clients: PHYS in
-- res/sky_model.lua ([LC_PBR_PARITY]). What is vanilla's alone is below.
local PHYS = luanti_sky.PHYS
function PHYS.sun_color(height)
	return magic.Color(PHYS.sun_rgb(height))
end
PHYS.SUN_COLOR = magic.Color(1.0, 0.96, 0.88)
PHYS.MOON_COLOR = magic.Color(0.55, 0.68, 1.0)
-- Reassigned when a game says what its horizon is; see sub_sky below
local DAY_FOG = magic.Color(0.60, 0.72, 0.88)
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.8}
-- [PT_EXPOSURE]: the pbr path meters its exposure by Urho3D's
-- AutoExposure.xml -- log-average luminance as the key, clamped to the
-- range, the frame scaled by middle grey over it -- which is the rule the
-- path-traced reference applies to its own frame (pathtrace_render.py,
-- LUM_RANGE and MIDDLE_GREY). The reference's constants are in radiance;
-- this frame is in the shader's own light scale until [PBR_TARGET]'s
-- Luanti-isms are out, so these are that scale's, and become the
-- reference's numbers the day the two scales meet. The adaptation rate is
-- this client's alone: a still has no time axis.
-- The floor is how far the eye may adapt into the dark: 0.05 was a
-- daylight-adapted eye looking at the night, and the moonlit snow field
-- rendered pitch black under it. 0.003 puts that field's probe at a
-- median of 39 of 255 in the render with the sky still at 0, which is
-- [PT_NIGHT]'s target; the same number is LUM_RANGE in
-- pathtrace_render.py. **0.015 caps the gain at 12x**
-- ([CAVE_EXPOSURE_FLOOR], user 2026-10-08: a cave dark on the screen,
-- not metered up to grey). pbr_pair.sh's medians: a closed cave 49
-- (101 at 0.003), its moonlit snow field 37 (74); at 0.04 31 and 24.
-- **The top is vp5_1000's own key** (user, 2026-10-01: its greenery sets
-- a good snow exposure, and a field of snow and ice should keep it rather
-- than be metered down to dull): 7.04 there, measured as the ratio of the
-- metered reference shot to one at a key pinned at 1. It is the highest
-- key of the reference views (vp1_1300 is 3.0, the rest under 2), so the
-- cap changes none of them; pathtrace_render.py's 100 is left alone.
local AUTO_EXPOSURE = {
	adapt_rate = 0.6,
	lum_range = {0.015, 7.0},
	middle_grey = 0.18,
	-- Frames left before the rate goes back after a reset; in this
	-- table since the chunk is at Lua 5.1's two hundred locals
	reset_frames = 0,
}

local function normalized(v)
	local l = math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
	return {x = v.x/l, y = v.y/l, z = v.z/l}
end

-- Urho is left-handed and Y-up: yaw 0 looks towards +Z, and euler pitch is
-- positive downwards
local function angles_from_dir(d)
	d = normalized(d)
	return math.deg(math.atan2(d.x, d.z)), math.deg(math.asin(-d.y))
end

-- Level, and facing the way VIEW_DIR does, until the server says which way
-- the player was facing: a world they have been in before saved that along
-- with where they stood, and a level view for the moment before it arrives
-- reads as waiting where a confidently wrong angle reads as a bug. See
-- luanti.sub_player_pos() below.
local yaw = angles_from_dir(VIEW_DIR)
local pitch = 0
-- Whether the mouse turns the player's head or points at the screen. In the
-- world while playing, on the screen while a form is open or Tab says so.
local mouse_in_world = false
local set_mouse_in_world

-- A form is clicked with the pointer, so while one is open the mouse is on
-- the screen and not in the world, and it goes back where it was wanted
-- when the form goes. **Which form it is does not matter**: the server
-- opens one by itself -- a sign, a chest, /help -- and the keys here are
-- not in it, so the state is followed rather than set at the places that
-- open one. What is wanted is kept apart from what is: a placement that
-- asks for the world while a form is open (nodecore opens one at the
-- join) gets it when the form closes, rather than the form's close
-- putting back what was before it opened.
do
	local was_open = false
	local wanted = false
	-- **A browser holds the pointer only in relative mode** (user,
	-- 2026-09-30: the look stopped at the screen's edge): Urho3D asks for
	-- the pointer lock with MM_RELATIVE and leaves it with anything else,
	-- where a hidden cursor is all a native window needs. The browser
	-- grants it just after a click or a key; a click in the world asks
	-- again while it is not held (see MouseButtonDown below).
	local web = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
	keys.web_lock = function(enable)
		if web and not keys.touch then
			magic.input:SetMouseMode(enable and magic.MM_RELATIVE or
					magic.MM_ABSOLUTE)
		end
	end
	-- reason: a word for the log ([FOCUS_LOG]), which is where a lost
	-- mouse is read from
	set_mouse_in_world = function(enable, reason)
		wanted = enable
		if enable and luanti.form_open() then
			return
		end
		mouse_in_world = enable
		-- A touchscreen's pointer stays: the UI takes a finger's taps only
		-- while it is shown, and the touch controls are UI
		magic.input:SetMouseVisible(not enable or keys.touch ~= nil,
				reason or "set_mouse_in_world")
		keys.web_lock(enable)
	end
	-- **A lost lock pauses** ([WEB_LOCK_LOST], user, 2026-10-11: a form
	-- closed by Escape let go of the mouse and the view spun): on the web
	-- the mouse turns the view only while the browser holds the pointer,
	-- and when the world has the mouse with no lock and nothing is up over
	-- it, the pause menu opens, whose Continue or a click off it is the
	-- click a lock is granted for. Lost: at once; asked for and not given
	-- (a form closed by Escape asks, and the browser refuses): in 0.5 s.
	-- simplified: the refusal is waited out, not read from the request's
	-- promise
	keys.mouse_held = function()
		return not web or keys.touch ~= nil or magic.input:IsMouseLocked()
	end
	local was_locked, unlocked_s = false, 0
	magic.SubscribeToEvent("Update", function(_, d)
		if not web or keys.touch or not mouse_in_world or luanti.form_open() or
				luanti.held() or magic.input:IsMouseLocked() then
			was_locked, unlocked_s = magic.input:IsMouseLocked(), 0
			return
		end
		unlocked_s = unlocked_s + d:GetFloat("TimeStep")
		if was_locked or unlocked_s > 0.5 then
			log:info("the pointer lock is not held: paused (" ..
					(was_locked and "lost" or "not given") .. ")")
			was_locked, unlocked_s = false, 0
			keys.open_pause()
		end
	end)
	magic.SubscribeToEvent("Update", function()
		local open = luanti.form_open()
		if open == was_open then
			return
		end
		was_open = open
		if open then
			mouse_in_world = false
			magic.input:SetMouseVisible(true, "a form opened")
			keys.web_lock(false)
		else
			mouse_in_world = wanted
			magic.input:SetMouseVisible(not wanted or keys.touch ~= nil,
					"the form closed")
			keys.web_lock(wanted)
		end
	end)
end

local zone = nil
-- The sun and the moon, both in the scene: {sun_node, sun, moon_node, moon}.
-- One table rather than four locals because this file's main chunk is at
-- Lua 5.1's limit of two hundred of them.
local sky_lights = {}
-- The render path the world is drawn with, set where the viewport is; a
-- second view of the same world wants the same one
local world_render_path = nil

do
	local zone_node = scene:CreateChild("Zone")
	zone = zone_node:CreateComponent("Zone")
	-- **Big enough for a Luanti world.** A thousand either way is a
	-- hundredth of one: a chunk past it is inside no zone at all and is
	-- lit by Urho's default zone, whose ambient nothing here ever sets.
	-- extensions/luanti_client's is a hundred thousand and has been.
	zone.boundingBox = magic.BoundingBox(-100000, 100000)
	zone.ambientColor = SKY_AMBIENT
	zone.fogColor = magic.Color(0.60, 0.72, 0.88)
	-- Seven tenths of the way out, which is where
	-- extensions/luanti_client's starts; see [LIGHT_SHAPE]
	zone.fogStart = FAR_CLIP * 0.7
	zone.fogEnd = FAR_CLIP
	-- **Above Urho's default zone, which is 0** ([SKY_COLUMN_CAVE],
	-- 2026-09-28, and it was -1 until then). View::FindZone() keeps a
	-- drawable's existing zone whenever that zone's priority is at least
	-- the highest in view, so a chunk that once landed on the default
	-- zone -- priority 0, and nothing in this game ever sets its ambient
	-- -- kept it for as long as it was loaded. The picture: at 02:00 the
	-- hill in front of the player was lit like noon and the ground beyond
	-- it was black, with a hard edge, because the two were on different
	-- zones. One is enough above; the number leaves room for a game's own.
	zone.priority = tonumber(buildat.get_env("BUILDAT_LUANTI_ZONE_PRIO") or "")
			or 1
	zone.override = true
	-- What the voxel shader reflects; without it its IBL term samples
	-- nothing and every reflection is black
	zone.zoneTexture = magic.cache:GetResource("TextureCube",
			voxel_shading.sky_cubemap)
end

-- **Two lights, not one that turns round at midnight.** The moon is the
-- same light from the other side of the sky, and having it as a light of its
-- own is what lets each be faded out over the hour it crosses the horizon
-- instead of the one direction flipping the instant the sun goes down --
-- which snapped every shadow in the world round at dawn and at dusk. Both
-- are in the scene for that hour, which is two shadow maps for two hours of
-- the day and one for the rest of it. extensions/luanti_client's shape; see
-- [LIGHT_SHAPE] in doc/plan/rendering_plan.md.
do
	local function body_light(name, color, brightness)
		local node = scene:CreateChild(name)
		node.direction = magic.Vector3(SUN_DIR.x, SUN_DIR.y, SUN_DIR.z)
		local light = node:CreateComponent("Light")
		light.lightType = magic.LIGHT_DIRECTIONAL
		light.castShadows = true
		light.brightness = brightness
		light.color = color
		light.specularIntensity = 1.0
		-- Voxel faces at a grazing sun angle are the classic shadow acne
		-- case: a whole flat face falls inside one shadow texel and shadows
		-- itself in stripes. A slope-scaled bias on top of the automatic
		-- one, and a normal offset, which is the one that works on a face
		-- that is flat and wide. extensions/luanti_client's own numbers;
		-- see [WOBBLY_SHADOWS].
		light.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
		-- Two cascades rather than Urho3D's one spread over the whole
		-- shadow distance. The near one is confined to where the player is
		-- looking, so a node gets the texels it needs; without the split
		-- the same sparse grid slides under static geometry as the shadow
		-- camera is refitted each frame, which is the wobble.
		--
		-- 24 nodes and 96, not the far clip: a shadow map stretched over
		-- four hundred nodes has no density left where the player is.
		light.shadowCascade = magic.CascadeParameters(24, 96, 0, 0, 0.8)
		return node, light
	end
	sky_lights.sun_node, sky_lights.sun =
			body_light("Sun", PHYS.SUN_COLOR, SUN_BRIGHTNESS)
	sky_lights.moon_node, sky_lights.moon =
			body_light("Moon", PHYS.MOON_COLOR, MOON_BRIGHTNESS)
	-- Past the far cascade the world is ambient-lit, which at that range
	-- reads as haze rather than as a missing shadow.
	magic.renderer.shadowMapSize = 1024
	magic.renderer.shadowQuality = magic.SHADOWQUALITY_SIMPLE_16BIT
	magic.renderer.drawShadows = true
	-- **Urho3D's occluder budget of 5000 stays**, although a voxel chunk's
	-- mesh is about eight thousand triangles and the software occlusion
	-- buffer therefore spends the whole of it on the first chunk it comes
	-- to. Raising it to 50000 was tried and taken back out
	-- ([CLIENT_FRAME]): it is worth one frame a second where the GPU is
	-- the wall, and on a machine where the GPU is not -- the same desk's
	-- Nvidia at twice the range -- rasterising those occluders is **a
	-- third of the client's CPU**, which is the wall there. A budget
	-- cannot be right for both. What would be is a cheap occluder: a
	-- chunk's solid core as a few large quads, which is the mesher's work
	-- rather than a setting's.
end

-- The sky the world stands under. builtin/voxel_shading's gradient sky is
-- not made at all: its sky setters all begin "if not skybox_material then
-- return", so the ones this file used to call become no-ops of their own
-- accord, and what it still owns -- the voxel materials, the reflections'
-- own cube map, set_sky_light() and set_sky_tint() -- is untouched.
local world_sky = luanti_sky.new(scene, SUN_DIR,
		voxel_shading.sky_defaults)

-- What the world reflects on the pbr path: the sky as it is drawn, into
-- a cube of its own, re-rendered when the hour or the sun moves. The
-- parity modes read no cube map, and a game's own skybox replaces it
-- below. See [SKY_REFLECTIONS] in doc/plan/rendering_plan.md.
-- One table, since this chunk is at Lua 5.1's two hundred locals: the
-- cube, and when it is next due -- the sun's direction moves every frame
-- and the cube is six renders, so once a second, which nobody sees jump
local sky_cube = {cube = require("buildat/extension/skycube").new(
		magic, world_sky.material), due = 0}
zone.zoneTexture = sky_cube.cube.texture
-- Microseconds the cube's render took since the frame peak last read it
sky_cube.us = 0
function sky_cube.refresh(force)
	local now = scene.elapsedTime
	-- The faces go out one a frame ([CLIENT_FRAME]); `tick` is what sends
	-- them, and a forced refresh -- the first build -- sends all six
	local t0 = buildat.get_time_us()
	if force or now >= sky_cube.due then
		sky_cube.due = now + 1
		if force then
			sky_cube.cube:update_now()
		else
			sky_cube.cube:update()
		end
	end
	sky_cube.cube:tick()
	sky_cube.us = sky_cube.us + buildat.get_time_us() - t0
end

local game_skybox = skybox.new(scene, world_sky.node,
		function(expr) return luanti.texture(expr) end)

local camera_node = scene:CreateChild("Camera")
-- The component, because a waypoint asks it where a place in the world is
-- on the screen
local camera = nil
do
	local d = normalized(VIEW_DIR)
	camera_node.position = magic.Vector3(
			LOOK_AT.x - d.x * CAMERA_DISTANCE,
			LOOK_AT.y - d.y * CAMERA_DISTANCE,
			LOOK_AT.z - d.z * CAMERA_DISTANCE)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	camera = camera_node:CreateComponent("Camera")
	-- Luanti's own near plane, with its scaling undone: it sets
	-- 0.1 * BS in Camera::updateViewingRange() and BS is ten units to the
	-- node, so a tenth of a node. A standing player's eye is inside a node
	-- of any wall it is against, which at 1.0 clipped the wall away.
	camera.nearClip = 0.1
	camera.farClip = FAR_CLIP
	-- What the fov is wanted at: set on the screen's short side each frame
	-- (magic.fov_for), a portrait phone's width (user, 2026-09-30)
	keys.fov_want = CAMERA_FOV
	camera.fov = magic.fov_for(CAMERA_FOV)

	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})

	-- Where the sounds are heard from, which is where the eyes are. How
	-- loud they are altogether is the user's own preference and not this
	-- game's to set.
	local listener = camera_node:CreateComponent("SoundListener")
	if magic.audio then
		magic.audio.listener = listener
	end

	magic.renderer.HDRRendering = true
	local base = viewport.renderPath
	local rp = base:Clone()
	-- The exposure first and the bloom after it: the bloom's threshold
	-- (0.8) is a screen value, and taken before the exposure on a world at
	-- the reference's radiances ([PBR_FIT], a sky of 5 and snow of 30) it
	-- passed every pixel, and the 40% blur it mixed back in was a haze
	-- that took the shadows with it.
	-- The gray of the eye's rods first, before the meter: the pass reads
	-- the scene's radiance in the reference's units ([NIGHT_GRAY]).
	-- (0.0003, 0.003) is the user's pick off the second ladder (2026-09-21):
	-- the caves whole, the night with a trace of green; in the xml. Off
	-- under BUILDAT_LUANTI_LINEAR, where the probes read linear light.
	rp:Append(magic.cache:GetResource("XMLFile",
			"luanti_client/res/LuantiNightGray.xml"))
	-- **[NIGHT_GRAY], as picked**: the gray is the voxel shader's, keyed
	-- on the light a face gets rather than on the radiance the frame
	-- reads, full gray at the cave floor's own luminance and colour
	-- whole at **1.5 times it** (the user's pick off the fourth ladder,
	-- 2026-09-25, `local/options_for_NIGHT_GRAY/ladder4/`: at 1.25 the
	-- transition reads as a band, and 1.5 widens it for under a
	-- hundredth of the lit cave's colour). **And the frame pass goes
	-- with it here**: it reads light times albedo, so it cannot hold
	-- the rule across materials -- snow at the floor gives out more
	-- than stone lit at three times it -- and two grays over one frame
	-- would compound.
	--
	-- BUILDAT_LUANTI_GRAY_BY_LIGHT=<top> moves the ramp's top and 0
	-- turns the shader's gray off, which is how the ladders are shot;
	-- BUILDAT_LUANTI_NIGHT_GRAY="<L0> <L1>" moves the frame pass's two
	-- levels and "off" turns it off. With the shader's gray on, the
	-- pass is off whatever it says.
	local by_light = tonumber(
			buildat.get_env("BUILDAT_LUANTI_GRAY_BY_LIGHT") or "") or 1.5
	local gray_env = buildat.get_env("BUILDAT_LUANTI_NIGHT_GRAY") or ""
	-- **The pass stays on unless it is asked off** (2026-09-26): taking
	-- it out of the pbr path took the night with it -- vp4 at 20:30 went
	-- from a mean of 8 to 109 -- so it is doing something the metered
	-- exposure depends on, and the two grays do not compound: the
	-- shader's acts only under the cave floor's own luminance and the
	-- pass's own range is a hundredth of that.
	local gray_off = gray_env == "off"
	rp:SetEnabled("NightGray", not gray_off and
			buildat.get_env("BUILDAT_LUANTI_LINEAR") ~= "1")
	local l0, l1 = gray_env:match("^([%d.]+)%s+([%d.]+)$")
	if l0 then
		rp:SetShaderParameter("NightGray",
				magic.Vector2(tonumber(l0), tonumber(l1)))
	end
	-- Under the same gate as the pass: BUILDAT_LUANTI_LINEAR is the probes'
	-- own frame and a gray in it would corrupt what they read.
	voxel_shading.set_gray_by_light(
			buildat.get_env("BUILDAT_LUANTI_LINEAR") ~= "1" and by_light)
	rp:Append(magic.cache:GetResource("XMLFile",
			"luanti_client/res/LuantiAutoExposure.xml"))
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/BloomHDR.xml"))
	-- The curve: Urho's per-channel Uncharted2, picked by the user off the
	-- pair for its range in caves ([PBR_FIT] term 4, 2026-09-20); ACES
	-- (luanti_client/res/LuantiTonemap) behind BUILDAT_LUANTI_TONEMAP=aces
	local tonemap = buildat.get_env("BUILDAT_LUANTI_TONEMAP") or "uncharted2"
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/Tonemap.xml"))
	rp:Append(magic.cache:GetResource("XMLFile",
			"luanti_client/res/LuantiTonemap.xml"))
	rp:Append(magic.cache:GetResource("XMLFile",
			"PostProcess/GammaCorrection.xml"))
	rp:SetEnabled("TonemapReinhardEq3", false)
	-- BUILDAT_LUANTI_LINEAR=1: the metered frame clipped, no curve, which
	-- is what the path-traced reference's PNGs are; the reference runners
	-- set it so the fit's probes read linear against linear ([PBR_FIT])
	local curve = buildat.get_env("BUILDAT_LUANTI_LINEAR") ~= "1"
	rp:SetEnabled("TonemapUncharted2", curve and tonemap ~= "aces")
	rp:SetEnabled("TonemapACES", curve and tonemap == "aces")
	-- and no bloom either: the render has none, and a bright pass blurred
	-- over a probe crop is a white the crop did not earn
	rp:SetEnabled("BloomHDR", buildat.get_env("BUILDAT_LUANTI_LINEAR") ~= "1")
	-- The bloom's threshold is against the exposed frame, so it sits where
	-- that frame clips (the tonemap's shoulder starts above 1.0), and the
	-- stock 40% mix is a haze over a whole daylight picture; 15% was a
	-- glow on what clips ([BLOOM_PLACE]) and still too much on a desk, so
	-- a fifth of that (user, 2026-09-20, [BLOOM_FIFTH]); the grade's
	-- ladder kept it (user, 2026-09-21, [PBR_GRADE]).
	rp:SetShaderParameter("BloomHDRThreshold", 1.2)
	rp:SetShaderParameter("BloomHDRMix", magic.Vector2(1.0, 0.03))
	-- No bias on top of the meter: the meter owns the level and a bias is
	-- a second exposure that pushes the lit parts up the curve's shoulder
	-- ([PBR_FIT] term 4). The minimap draws through a clone of this.
	rp:SetShaderParameter("TonemapExposureBias", 1.0)
	-- Uncharted2's white point: 2, the grade's ladder's pick (user,
	-- 2026-09-21, [PBR_GRADE]; Urho's own is 4.0); the shoulder is the
	-- curve's own
	rp:SetShaderParameter("TonemapMaxWhite", 2.0)
	-- BUILDAT_LUANTI_KEY=<lum> pins the metered key by closing the range on
	-- it, so an ablation's frames are comparable in absolute terms: with
	-- the key free, a term turned off re-exposes everything else
	local key = tonumber(buildat.get_env("BUILDAT_LUANTI_KEY") or "")
	if key then AUTO_EXPOSURE.lum_range = {key, key} end
	-- BUILDAT_LUANTI_ADAPT=<rate>: the adaptation rate, for a run that
	-- asks whether the meter had settled. **Read before the rate is set
	-- on the path**, or it reached the shader only after an
	-- exposure_reset put it back (2026-09-24) -- so a run asking for an
	-- instant meter got the default 0.6 and a picture of whatever the
	-- adaptation had reached by then, which on a slow machine is a
	-- different picture.
	AUTO_EXPOSURE.adapt_rate = tonumber(
			buildat.get_env("BUILDAT_LUANTI_ADAPT") or "") or
			AUTO_EXPOSURE.adapt_rate
	rp:SetShaderParameter("AutoExposureAdaptRate", AUTO_EXPOSURE.adapt_rate)
	rp:SetShaderParameter("AutoExposureLumRange",
			magic.Vector2(AUTO_EXPOSURE.lum_range[1],
			AUTO_EXPOSURE.lum_range[2]))
	rp:SetShaderParameter("AutoExposureMiddleGrey", AUTO_EXPOSURE.middle_grey)
	viewport.renderPath = rp
	-- A reference picture is taken at a settled exposure ([PT_SETTLE]):
	-- the reference fixture asks for this before the shot, and the
	-- adaptation -- adapted + (lum - adapted) * (1 - exp(-dt * rate)) in
	-- AutoExposure.glsl, kept in a persistent 1x1 target -- lands on the
	-- frame's own key in one frame at a rate of a million, and the rate
	-- goes back the frame after. Deterministic, and no wait.
	-- A reference picture wants the sky-visibility cube converged as well
	-- as the exposure: both are averaged over time and both are wrong for
	-- a frame or two after a teleport. update(nil) is the module's own
	-- snap -- several sweeps at once, averaged as the easing would have.
	luanti.sky_vis_snap = function()
		voxel_shading.update(nil)
	end
	luanti.refshot_note = function()
		return string.format(
				"chamber light %.3f, sky above %.3f, applied %.3f; " ..
				"sun height %.3f (%.1f deg), day %.3f, predawn %.3f",
				voxel_shading.chamber_light(),
				voxel_shading.sky_visibility_above(),
				cave_ambient_now, sun_height_now,
				math.deg(math.asin(math.max(-1, math.min(1,
						sun_height_now)))),
				day_factor_now, predawn_now)
	end
	luanti.exposure_reset = function()
		rp:SetShaderParameter("AutoExposureAdaptRate", 1000000)
		AUTO_EXPOSURE.reset_frames = 2
	end
	-- The key pinned at one value, as BUILDAT_LUANTI_KEY does at start
	-- **Said out loud** ([SKY_COLUMN_CAVE], 2026-09-28): a debug mode that
	-- asks for the key and does not get it draws a metered picture that
	-- reads like an absolute one, and two of those were argued from for an
	-- evening. The same shape as the adaptation rate's own silent miss
	-- (2026-09-24, above).
	luanti.exposure_pin = function(k)
		AUTO_EXPOSURE.lum_range = {k, k}
		rp:SetShaderParameter("AutoExposureLumRange", magic.Vector2(k, k))
		log:info(string.format("exposure: key pinned at %.3f, gain %.3f",
				k, AUTO_EXPOSURE.middle_grey / k))
	end
	-- What a second view of the same world is drawn with -- the minimap:
	-- the frame's own path, meter and curve and all, on a clone whose
	-- adaptation target is its own. A stamp path of its own with a fixed
	-- bias (1.6, no meter) was white over a noon world -- the minimap
	-- "oversaturated" on the box ([BOX_PLAYTEST_2] 9; [EXT_HUD_PARITY]
	-- saw it) -- since the HDR frame is fifty times the sky at the sun
	-- and only the meter brings that down.
	world_render_path = rp:Clone()
	-- The clone's meter adapts in one step rather than at the frame's rate
	-- ([BOX_PLAYTEST_2] 9b): the stamp is drawn a few times a second, not
	-- every frame, so a rate meant for frames gave the clone's meter one
	-- step per stamp and it hunted -- the minimap cycling from white to
	-- right about every fifteen seconds. At this rate each stamp is
	-- exposed on its own content and the level does not drift between
	-- stamps. (The frame's own adapted level lives in a 1x1 render target
	-- and is not readable here, which is why this meters rather than
	-- copies.)
	world_render_path:SetShaderParameter("AutoExposureAdaptRate", 1000000)
end



voxelworld.set_camera(camera_node)
voxel_shading.set_camera(camera_node)

magic.input:SetMouseVisible(true, "the launcher's start")

-- Every line of the HUD is drawn over a world that may be snow, sand or a
-- dark cave, so all of them carry a shadow; without it a white world takes
-- white text with it.
-- Whether the HUD and the chat log are drawn at all, which F1 and F2 are.
-- The game can take either away as well; both have to say yes -- see
-- draw_hud().
local hud_shown = true
local chat_shown = true

local function hud_text(size)
	local t = magic.ui.root:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), size or 15)
	t:SetTextEffect(magic.TE_SHADOW)
	t.effectColor = magic.Color(0, 0, 0, 0.85)
	return t
end

-- One line of a game's text, in as many pieces as it has colours in it: a
-- mod writes core.colorize() into a line and each piece is drawn in the
-- colour it asks for. Returns how wide and how tall the line came out.
local function draw_text_line(parent, line, x0, y0, base, size)
	local font = magic.cache:GetResource("Font", buildat.font_mono)
	local x, h = 0, 0
	for _, piece in ipairs(luanti.text_segments(line)) do
		local t = parent:CreateChild("Text")
		t:SetFont(font, size or 15)
		t:SetTextEffect(magic.TE_SHADOW)
		t.effectColor = magic.Color(0, 0, 0, 0.85)
		t:SetText(luanti.strip_escapes(piece.text))
		t.color = piece.color and magic.Color(piece.color.r, piece.color.g,
				piece.color.b) or base
		t:SetPosition(math.floor(x0 + x), math.floor(y0))
		x = x + t.width
		h = math.max(h, t.height)
	end
	return x, h
end

local crosshair = hud_text(20)
crosshair:SetText("+")
crosshair.horizontalAlignment = magic.HA_CENTER
crosshair.verticalAlignment = magic.VA_CENTER
crosshair:SetPosition(0, 0)

--
-- The hotbar
--
-- The first slots of the player's own inventory, along the bottom where
-- Luanti puts them: what is in each, how many, and which one is in hand.
-- The keys 1-8 and the wheel pick one, and the server is told -- what is in
-- hand is what a dig or a place asks it about.
-- How many are drawn is the game's to say -- hud_set_hotbar_itemcount() --
-- and this is Luanti's own ceiling on it. They are all built once and the
-- ones past the count are hidden, because the number changes when a game
-- says so and rebuilding them would be the same slots again.
local HOTBAR_MAX = 32
local WHITE = luanti.texture("[fill:1x1:#ffffffff")

-- Luanti's own m_scale_factor, which every size and offset a HUD element
-- carries is multiplied by before it is drawn, in this UI's units: the
-- hotbar's, so the HUD stays against it ([HUD_DENSITY])
local hotbar_ui = nil
local function hud_scale()
	if not hotbar_ui then
		return magic.ui.root.width / math.max(1,
				buildat.logical_size() or magic.graphics.width)
	end
	return hotbar_ui:scale()
end

-- The row itself is luanti/hotbar.lua, the drawing both Luanti clients
-- share ([EXT_HOTBAR]); this file feeds it and keeps what is drawn beside
-- it. metrics is its three numbers, for the rest of the HUD; SLOT is a
-- slot's size, for the line of text that sits a slot and a bit above it.
local hotbar_metrics = nil
-- Defined below, where the picture cache is; the hotbar's own texture
-- lookup is this and it is made before it
local hotbar_picture = nil
local SLOT = 0

local hotbar_stacks = {}
local hotbar_shown = true
local wield_index = 1

-- "basenodes:stone 7" -> the name and the count
local function parse_stack(str)
	if str == nil or str == "" then
		return nil
	end
	local name, count = string.match(str, "^([^ ]+) *(%d*)")
	if name == nil or name == "" then
		return nil
	end
	return name, tonumber(count) or 1
end

local function game_texture(resource)
	if not resource or not magic.cache:Exists(resource) then
		-- Not there (yet): a cold cache has the media on its way, and the
		-- sky packet that named it comes again once it has arrived
		return nil
	end
	local tex = magic.cache:GetResource("Texture2D", resource)
	if tex then
		-- A node's tile is sixteen pixels across and is drawn at forty:
		-- anything but nearest turns it to soup
		tex.filterMode = magic.FILTER_NEAREST
	end
	return tex
end

-- What a game's own sun or moon is drawn as, composed once per name: this is
-- asked for every frame and the answer changes twice a day
-- One cache per body, because both are up at once now and a single one
-- would recompose on every frame the two names differed
local body_picture_name, body_picture = {}, {}

local function body_picture_of(slot, name)
	-- No name is the shader's painted square, and nothing to look up
	if name == nil then
		return nil
	end
	-- A picture not there yet (a cold cache) is asked for again a second
	-- later; every frame was ~150 us of lookups ([FRAME_WORK])
	local due = slot .. " due"
	if name ~= body_picture_name[slot] or (body_picture[slot] == nil and
			scene.elapsedTime >= (body_picture_name[due] or 0)) then
		body_picture_name[slot] = name
		body_picture_name[due] = scene.elapsedTime + 1
		body_picture[slot] = game_texture(luanti.texture(name))
	end
	return body_picture[slot]
end

-- The row both clients share, fed with this client's own idea of what a
-- hotbar picture and an item stack look like
hotbar_ui = (function(ok, err, lib)
	if not ok or type(lib) ~= "table" then
		log:warning("hotbar.lua: " .. tostring(err))
		return nil
	end
	return lib.new{
		magic = magic, buildat = buildat, log = log,
		max = HOTBAR_MAX, white = game_texture(WHITE),
		font = magic.cache:GetResource("Font", buildat.font_mono),
		texture = function(name)
			return hotbar_picture(name)
		end,
		stack = function(stack)
			local resource, count_text, name, wear = luanti.stack_look(stack)
			return resource and game_texture(resource) or nil,
					count_text, name, wear
		end,
	}
end)(buildat.run_script_file("luanti/hotbar.lua"))

hotbar_metrics = function()
	if not hotbar_ui then
		return 48, 4, 56, 4
	end
	return hotbar_ui:metrics()
end
do
	local _, _, slot_size = hotbar_metrics()
	SLOT = slot_size
end

-- What is in hand, drawn in front of the camera the way Luanti draws it: a
-- cube wearing the item's own image, turned so that three of its faces show.
--
-- simplified: a cube for everything, and unlit. A craftitem is a flat
-- picture in Luanti and a node is drawn as the node it places, with the
-- light where the player stands; here it is one shape and always visible.
local wield_node = camera_node:CreateChild("wielded")
local wield_model = wield_node:CreateChild("box"):CreateComponent("StaticModel")
local wield_material = magic.Material.new()
-- Cut out by the picture's own alpha rather than opaque, because an item's
-- picture is a cutout: a plant, a tool, a sapling. Drawn opaque the holes in
-- it are black, and drawn blended a picture that is mostly holes is a ghost.
-- See builtin/luanti's client_data, which is where the technique is.
wield_material:SetTechnique(0, magic.cache:GetResource("Technique",
		"luanti/UnlitAlphaMask.xml"))
wield_model:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
wield_model.material = wield_material
-- Where a hand is: official's numbers ([WIELD_MESH] 4, camera.cpp
-- drawWieldedTool and wieldmesh.cpp), read off the code: the wield scene's
-- camera is at the origin looking down +Z at FOV 72, the mesh rests at
-- (55, -35, 65) Irrlicht units (BS 10 to the node; the tool-change
-- timer sits at 0.125 at rest, so its `|timer| * 320 - 40` is nought
-- and not -40), turned by the Euler
-- (-100, 120, -100) taken X then Y then Z about the fixed axes (Irrlicht's
-- setRotationDegrees), an extruded item scaled by wield_scale * 40, a node
-- by wield_scale * 30 / BS.
--
-- Luanti draws it in a scene of its own with the depth cleared. Ours is a
-- child of the camera node in the world's scene, so it has to sit inside
-- the world's near plane (a tenth of a node) and nearer than the player's
-- own box is wide, so that no wall comes between it and the eye: the whole
-- thing is divided by WIELD_SHRINK, position and size together, which is
-- the same picture from a camera at the origin.
-- simplified: wield_scale is the item definition's and not on the wire,
-- so every item is at (1, 1, 1); the arm inertia, the swings and the bob
-- are not here. The world's FOV is official's 72; a camera packet that
-- changes it is followed by wield_k so the hand keeps its place on the
-- screen where official's would not move.
-- (one table: this file is at Lua's 200 locals)
local WIELD = {shrink = 26}
WIELD.extruded_scale = 40 / 10 / WIELD.shrink
WIELD.node_scale = 30 / 10 / WIELD.shrink
function WIELD.place(fov)
	local wield_k = math.tan(math.rad(fov / 2)) / math.tan(math.rad(36))
	WIELD.base = {x = 5.5 / WIELD.shrink * wield_k,
			y = -3.5 / WIELD.shrink * wield_k, z = 6.5 / WIELD.shrink}
	wield_node.position = magic.Vector3(WIELD.base.x, WIELD.base.y, WIELD.base.z)
	wield_node.rotation = magic.Quaternion(-100, magic.Vector3(0, 0, 1)) *
			magic.Quaternion(120, magic.Vector3(0, 1, 0)) *
			magic.Quaternion(-100, magic.Vector3(1, 0, 0))
	wield_node.scale = magic.Vector3(wield_k, wield_k, wield_k)
end
WIELD.place(CAMERA_FOV)
-- View bobbing and the hand's motion, official's ([VIEW_BOB]): the shared
-- module under luanti_client/res; the setting view_bobbing_amount comes
-- with main:settings (1 unless set; 0 is off, as official's)
WIELD.motion = (function(ok, err, lib)
	if not ok then
		log:warning("camera_motion.lua: " .. tostring(err))
		return nil
	end
	return lib.new()
end)(buildat.run_script_file("luanti/camera_motion.lua"))
WIELD.last_wield_index = nil
-- 1 first person, 2 third from behind, 3 third from the front
WIELD.camera_mode = 1
-- The back view centred, or over the shoulder ([OVER_SHOULDER]); a taste,
-- so the Luanti settings screen has the knob
WIELD.shoulder = false
wield_node:GetChild("box").scale = magic.Vector3(WIELD.node_scale, WIELD.node_scale,
		WIELD.node_scale)
-- **Lit under pbr** (user, 2026-09-30): a shape through Urho's PBR lit
-- passes, so the sun's direction and its shadow map fall on it as the
-- world's own light pass has them. The ambient is the world zone's, the
-- open sky's; the material's colour scales it to the light where the
-- player stands (update_sky), so a cave darkens the hand and a torch
-- lights it -- and the sun with it, which a cave's shadow map has taken
-- away already. (A zone of the hand's own carried the ambient and took the
-- sun's light pass away with it, for a reason not found.) The parity modes
-- keep the flat unlit colour.
function WIELD.set_lit(sh, lit)
	if sh.lit == lit then
		return
	end
	sh.lit = lit
	for _, m in ipairs(sh.materials) do
		m:SetTechnique(0, magic.cache:GetResource("Technique", lit and
				"luanti/PBRLitAlphaMask.xml" or "luanti/UnlitAlphaMask.xml"))
		m:SetShaderParameter("Roughness", 1.0)
		m:SetShaderParameter("Metallic", 0.0)
	end
end

-- A node's enabled does not reach its children (Urho's SetEnabled is
-- not deep): the box's child node and the shapes are switched with it,
-- or an empty hand drew the box black in every picture (2026-09-20)
function WIELD.show(on)
	-- What is wanted is kept apart from what is drawn: the third-person
	-- views hide the hand, and first person puts back what was wanted
	WIELD.shown_wanted = on
	on = on and WIELD.camera_mode == 1 and hud_shown
	wield_node.enabled = on
	if not on then
		for i = 0, wield_node:GetNumChildren() - 1 do
			wield_node:GetChild(i).enabled = false
		end
	end
end
wield_node:GetChild("box").enabled = false
wield_node.enabled = false

-- The name of what is in hand, above the slots: Luanti shows it when the
-- player switches, and it is what says an empty-looking slot has something
-- in it that has no image
local wielded_text = hud_text(14)
wielded_text:SetText("")
wielded_text.horizontalAlignment = magic.HA_CENTER
wielded_text.verticalAlignment = magic.VA_BOTTOM
wielded_text:SetPosition(0, -(8 + SLOT + 30))

-- The pictures the game named, kept as textures because these are asked for
-- on every redraw and a name is composed anew each time it is looked up
local hotbar_pictures = {}

-- The shape in the hand is the item's ([WIELD_MESH]): a flat item's
-- picture extruded, a node's cube with its faces, built by the module's
-- client half into a CustomGeometry; one material per texture, all of
-- them lit by the same colour update_sky() sets. The box stays for an
-- item the module has no shape for.
-- (the shapes live on hotbar_pictures under a marker key: this file is
-- at Lua's 200 locals)
-- stack is the itemstring, since what the hand holds may be a stack's own
-- picture rather than its item's ([ITEM_META_LOOK])
local function draw_wielded(item_name, stack)
	-- What was built before the mesh nodes were known is built again
	if WIELD.generation ~= luanti.wield_generation then
		WIELD.generation = luanti.wield_generation
		for _, sh in pairs(hotbar_pictures["\1shapes"] or {}) do
			if sh then
				sh.node:Remove()
			end
		end
		hotbar_pictures["\1shapes"] = nil
	end
	hotbar_pictures["\1shapes"] = hotbar_pictures["\1shapes"] or {}
	local wield_shapes = hotbar_pictures["\1shapes"]
	if item_name == nil or not luanti.hud_flag("wielditem") then
		WIELD.show(false)
		return
	end
	local expr, key, sx, sy, sz = luanti.wield_look(stack)
	key = key or item_name
	local shape = wield_shapes[key]
	if shape == nil then
		local holder = wield_node:CreateChild("shape")
		local resources, kind = luanti.wield_geometry(holder, item_name, expr)
		if resources == nil then
			-- Not kept: a picture whose file had not come yet was a box
			-- for the rest of the session (user, 2026-09-30: a torch as a
			-- see-through cube); the next redraw tries again
			holder:Remove()
		else
			local cg = holder:GetComponent("CustomGeometry")
			-- Unlit until update_sky() says the frame is pbr's, which
			-- lights it (WIELD.set_lit)
			local materials = {}
			for i, resource in ipairs(resources) do
				local m = wield_material:Clone()
				local tex = game_texture(resource)
				if tex then
					m:SetTexture(magic.TU_DIFFUSE, tex)
				end
				cg:SetMaterial(i - 1, m)
				materials[i] = m
			end
			cg.castShadows = false
			holder.enabled = false
			-- a node's cube or mesh and a picture's slab are official's
			-- sizes
			local sc = kind ~= "flat" and WIELD.node_scale or
					WIELD.extruded_scale
			-- And what the stack asked the hand to hold it at, over that
			-- ([ITEM_META_LOOK]'s wield_scale)
			holder.scale = magic.Vector3(sc * (sx or 1), sc * (sy or sx or 1),
					sc * (sz or sx or 1))
			shape = {node = holder, materials = materials, lit = false}
			wield_shapes[key] = shape
		end
	end
	-- Only in first person, and only with the HUD on: the corner item goes
	-- with the HUD ([HUD_HIDES_HAND]). A child is drawn whatever its parent
	-- says, so the third-person views have to be said here too
	-- ([THIRD_PERSON_WIELD])
	local first = WIELD.camera_mode == 1 and hud_shown
	for name, sh in pairs(wield_shapes) do
		if sh then
			sh.node.enabled = first and (name == key)
		end
	end
	if shape then
		wield_node:GetChild("box").enabled = false
		WIELD.shown_wanted = true
		wield_node.enabled = first
		return
	end
	-- No shape: the box wearing one face of the picture, as before
	local tex = game_texture(luanti.item_face_texture(item_name))
	if tex == nil then
		WIELD.show(false)
		return
	end
	wield_material:SetTexture(magic.TU_DIFFUSE, tex)
	wield_node:GetChild("box").enabled = first
	WIELD.shown_wanted = true
	wield_node.enabled = first
end


function hotbar_picture(name)
	if name == nil then
		return nil
	end
	if hotbar_pictures[name] == nil then
		-- false rather than nil, so that a game whose picture was never
		-- shipped is not composed again on every redraw
		hotbar_pictures[name] = game_texture(luanti.texture(name)) or false
	end
	return hotbar_pictures[name] or nil
end

local function draw_hotbar()
	local shown = luanti.hotbar or {}
	if hotbar_ui then
		hotbar_ui:draw{
			list = hotbar_stacks, wield = wield_index,
			count = shown.count or 8, shown = hotbar_shown,
			image = shown.image, selected_image = shown.selected_image,
		}
	end
	local name = parse_stack(hotbar_stacks[wield_index])
	wielded_text:SetText(name or "")
	if name then
		draw_wielded(name, hotbar_stacks[wield_index])
	else
		draw_wielded(parse_stack(WIELD.hand_stack), WIELD.hand_stack)
	end
end

-- Set once the HUD is built: a HUD element that draws a list of the player's
-- own has to follow it, and what the game sends is only the element
local hud_follows_inventory = nil

-- The images arrive after the inventory does -- the server sends one and the
-- client asks for the other -- so what was drawn without them is drawn again
luanti.sub_item_images(function()
	draw_hotbar()
end)

luanti.sub_inventory(function(lists)
	hotbar_stacks = lists.main or {}
	-- What an empty hand holds: the player's "hand" list, official's
	-- (LocalPlayer::getWieldedItem's hand fallback) -- VoxeLibre's arm in
	-- the player's skin
	WIELD.hand_stack = (lists.hand or {})[1]
	draw_hotbar()
	if hud_follows_inventory then
		hud_follows_inventory()
	end
end)

local function set_wield(i)
	local n = math.max(1, math.min(HOTBAR_MAX,
			(luanti.hotbar and luanti.hotbar.count) or 8))
	if i < 1 then
		i = n
	elseif i > n then
		i = 1
	end
	if i == wield_index then
		return
	end
	wield_index = i
	draw_hotbar()
	buildat.send_packet("main:wield",
			cereal.binary_output({tostring(i)}, {"array", "string"}))
end

draw_hotbar()

magic.ui:SetFocusElement(nil)

-- Mods load for several seconds before there is anything to draw, and what is
-- on the screen until then is sky
local wait_text = hud_text(24)
-- The chat's
local CHAT_STYLE = magic.cache:GetResource("XMLFile",
		"launch_menu/res/main_style.xml")
wait_text:SetText("Loading the world...")
wait_text.horizontalAlignment = magic.HA_CENTER
wait_text.verticalAlignment = magic.VA_CENTER
wait_text:SetPosition(0, 0)
-- [LOAD_SHOWN]: said again every 0.5 s ([LOADING_STRIPES]), with the
-- whole seconds, so that the line changes while the server sends nothing
local load_wait = {t = 0, next = 0.5}
-- **And what comes** ([JOIN_PROGRESS], user 2026-10-11: "0 of 125" stood
-- still while 21 MB came, and the join was given up): the megabytes read
-- and their rate; nothing for 10 s says so; at 30 s the client leaves by
-- itself (state.cpp's SILENCE_US). No Leave button ([LOADING_STRIPES],
-- user 2026-10-12): the pause menu leaves. A client with no
-- buildat.received() says what it did.
-- simplified: no total; the server learns a node's size only as it sends
-- it
-- **A screen of its own** ([LOADING_SCREEN], user 2026-10-11): the world
-- is not drawn while it loads -- Buildat's dark colour over it, and one of
-- the game's menu/background*.png that the server picked at random,
-- scaled to cover and centred -- and the HUD, walking and mouse look wait
-- with it. Under all else on the UI, so the line, Leave, the chat and the
-- pause menu are over it.
-- simplified: the scene is still rendered under the screen
load_wait.screen = magic.ui.root:CreateChild("BorderImage")
load_wait.screen.priority = -100
load_wait.screen.color = magic.Color(0x15 / 255, 0x15 / 255, 0x1a / 255)
-- **Two stripes** ([LOADING_STRIPES], user 2026-10-12), over the
-- picture, which is made later, by their priority: the line in amber on
-- one across the width, and under it, a line's height lower, a taller one
-- with the last thing that came, its icon and its name in cyan (a file
-- browser's entry), the pair centred
local BRAND_PAGE = magic.Color(0x1b / 255, 0x1b / 255, 0x22 / 255)
wait_text:SetColor(magic.Color(1, 0x9e / 255, 0x1f / 255))
load_wait.box = load_wait.screen:CreateChild("BorderImage")
load_wait.box.color = BRAND_PAGE
load_wait.box.priority = 1
load_wait.last = load_wait.screen:CreateChild("BorderImage")
load_wait.last.color = BRAND_PAGE
load_wait.last.priority = 1
load_wait.last.visible = false
load_wait.pair = load_wait.last:CreateChild("UIElement")
load_wait.pair:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
load_wait.icon = load_wait.pair:CreateChild("BorderImage")
load_wait.icon.verticalAlignment = magic.VA_CENTER
load_wait.name = load_wait.pair:CreateChild("Text")
load_wait.name.verticalAlignment = magic.VA_CENTER
load_wait.name:SetColor(magic.Color(0x26 / 255, 0xd9 / 255, 1))
-- The glyphs, 16x16 pixel art written once under the cache: nothing the
-- game must have, and no font has them
local GLYPHS = {
	note = {
		"................", "......#########.", "......#########.",
		"......##.....##.", "......##.....##.", "......##.....##.",
		"......##.....##.", "......##.....##.", "......##.....##.",
		"......##.....##.", "...####...#####.", "..#####..######.",
		"..#####..######.", "...###....####..", "................",
		"................"},
	cube = {
		"................", "......#########.", ".....#.......##.",
		"....#.......#.#.", "...#.......#..#.", "..#########...#.",
		"..#.......#...#.", "..#.......#...#.", "..#.......#...#.",
		"..#.......#...#.", "..#.......#..#..", "..#.......#.#...",
		"..#.......##....", "..#########.....", "................",
		"................"},
	page = {
		"................", "...#######......", "...#.....##.....",
		"...#.....#.#....", "...#.....####...", "...#........#...",
		"...#.####...#...", "...#........#...", "...#.#####..#...",
		"...#........#...", "...#.####...#...", "...#........#...",
		"...#.#####..#...", "...#........#...", "...##########...",
		"................"},
	globe = {
		"................", "......####......", "....##.##.##....",
		"...#..#..#..#...", "..#..#....#..#..", "..#..#....#..#..",
		".##############.", ".#...#....#...#.", ".#...#....#...#.",
		".##############.", "..#..#....#..#..", "..#..#....#..#..",
		"...#..#..#..#...", "....##.##.##....", "......####......",
		"................"},
}
local function glyph(name)
	local resource = "vanilla_loading/glyph_" .. name .. ".png"
	if not load_wait.glyphs_written then
		load_wait.glyphs_written = true
		local dir = buildat.get_cache_path() .. "/vanilla_res"
		for n, rows in pairs(GLYPHS) do
			local ops = {}
			for y, row in ipairs(rows) do
				for x0, x1 in row:gmatch("()#+()") do
					ops[#ops + 1] = {op = "fill", color = {255, 255, 255, 255},
							at = {x0 - 1, y - 1}, size = {x1 - x0, 1}}
				end
			end
			buildat.compose_image({size = {16, 16}, ops = ops,
					write = dir .. "/vanilla_loading/glyph_" .. n .. ".png"})
		end
		buildat.add_resource_dir(dir)
	end
	return magic.cache:GetResource("Texture2D", resource)
end
-- What last_arrival() said, on stripe two: a PNG's own picture, else the
-- glyph of its kind
local function load_wait_show(a)
	local tex, name = nil, nil
	if a.kind == "file" then
		name = a.name
		local ext = (a.name:match("%.(%w+)$") or ""):lower()
		if ext == "png" then
			tex = magic.cache:GetResource("Texture2D", a.name)
		end
		tex = tex or glyph(ext == "ogg" and "note" or
				(ext == "obj" or ext == "b3d" or ext == "x") and "cube" or "page")
	elseif a.kind == "chunk" then
		name = string.format("chunk %d, %d, %d", a.x, a.y, a.z)
		tex = glyph("globe")
	else
		name = a.what
		tex = glyph("page")
	end
	if tex then
		tex.filterMode = magic.FILTER_NEAREST
	end
	-- Kept beside: the sandbox's texture getter raises on none
	load_wait.icon_tex = tex
	if tex then
		load_wait.icon.texture = tex
	end
	load_wait.name:SetText(name)
	load_wait.last.visible = true
	load_wait.fit()
	return name
end
function load_wait.fit()
	local w, h = magic.ui.root.width, magic.ui.root.height
	load_wait.screen:SetFixedSize(w, h)
	-- The F5 info's size (user 2026-10-12), which fits a narrow window
	local size = 13
	if load_wait.font ~= size then
		load_wait.font = size
		local font = magic.cache:GetResource("Font", buildat.font_mono)
		wait_text:SetFont(font, size)
		load_wait.name:SetFont(font, size)
	end
	-- Stripe one right above the gap, which is a line's height centred on
	-- the screen, and stripe two right below it, 1.5 times as tall
	local lh = wait_text.height > 0 and wait_text.height or size
	local h1 = lh + math.floor(size / 2)
	local h2 = math.floor(h1 * 1.5)
	local top = math.floor(h / 2 - lh / 2) - h1
	local box = load_wait.box
	box.visible = wait_text.text ~= ""
	box:SetFixedSize(w, h1)
	box:SetPosition(0, top)
	wait_text:SetPosition(0, top + math.floor(h1 / 2) - math.floor(h / 2))
	load_wait.last:SetFixedSize(w, h2)
	load_wait.last:SetPosition(0, top + h1 + lh)
	-- The icon as tall as the stripe allows; a picture kept to its
	-- proportions in that square
	local side = h2 - math.floor(size / 2)
	local iw, ih = side, side
	local tex = load_wait.icon_tex
	if tex and tex.width > 0 and tex.height > 0 then
		local k = side / math.max(tex.width, tex.height)
		iw, ih = math.floor(tex.width * k + 0.5), math.floor(tex.height * k + 0.5)
		load_wait.icon.imageRect = magic.IntRect(0, 0, tex.width, tex.height)
	end
	load_wait.icon:SetFixedSize(iw, ih)
	load_wait.icon:SetPosition(math.floor((side - iw) / 2), 0)
	load_wait.name:SetPosition(side + math.floor(size / 2), 0)
	load_wait.pair:SetFixedSize(side + math.floor(size / 2) +
			load_wait.name.width, h2)
	-- **Not larger than the window** ([LOADING_PIC_FIT], user 2026-10-11):
	-- the client's fit lowers the UI scale for an element past the root,
	-- so the element is the root's size and its imageRect the centred
	-- part of the picture in the root's proportions
	local p = load_wait.pic
	if p then
		local k = math.max(w / p.w, h / p.h)
		local cw, ch = w / k, h / k
		local x0, y0 = math.floor((p.w - cw) / 2), math.floor((p.h - ch) / 2)
		p.el:SetFixedSize(w, h)
		p.el.imageRect = magic.IntRect(x0, y0, x0 + math.floor(cw + 0.5),
				y0 + math.floor(ch + 0.5))
	end
end
load_wait.fit()
buildat.sub_packet("main:loading_picture", function(data)
	local got = cereal.binary_input(data, {"array", "string"})
	if not load_wait or #got < 2 then
		log:info("load: no loading picture")
		return
	end
	-- simplified: compose_image decodes and writes the PNG again, about
	-- a second for VoxeLibre's 2 MB ones with the screen standing still;
	-- a plain write under the cache for served code would skip it
	local dir = buildat.get_cache_path() .. "/vanilla_res"
	local resource = "vanilla_loading/" .. buildat.hex(buildat.sha1(got[2])) ..
			".png"
	local ok, w, h = pcall(buildat.compose_image, {
		ops = {{op = "blit", src_data = got[2]}},
		write = dir .. "/" .. resource,
	})
	if not ok then
		log:warning("load: the picture " .. got[1] .. ": " .. tostring(w))
		return
	end
	buildat.add_resource_dir(dir)
	local el = load_wait.screen:CreateChild("BorderImage")
	el.texture = magic.cache:GetResource("Texture2D", resource)
	el:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	load_wait.pic = {el = el, w = w, h = h}
	load_wait.fit()
	log:info(string.format("load: the picture %s, %dx%d", got[1], w, h))
end)
local function load_wait_end()
	wait_text:SetText("")
	load_wait.screen:Remove()
	load_wait = nil
	log:info("load: the world is in")
	-- And the player into it: until now they were only placed
	-- ([JOIN_WHEN_LOADED])
	buildat.send_packet("main:world_in", "")
	keys.redraw_hud()
	keys.take_world()
end
local function load_wait_line(s)
	local got, quiet = (buildat.received or function() end)()
	local secs = math.floor(load_wait.t)
	if not got then
		return string.format("%s... %d s", s, secs)
	end
	-- The rate from the line before: the first would count the game's files
	local rate = load_wait.at and
			(got - load_wait.got) / (load_wait.t - load_wait.at)
	load_wait.got, load_wait.at = got, load_wait.t
	if quiet and quiet >= 10 then
		return string.format("Waiting for the server... %d s", quiet)
	end
	return string.format("%s -- %.1f MB%s... %d s", s, got / 1e6,
			rate and string.format(", %d KB/s", rate / 1000) or "", secs)
end
-- It ends once the player is placed and the chunks within 2 of them are
-- drawn, or 60 s after the first chunk (the per-frame block below)
voxelworld.sub_geometry_update(function(node)
	if load_wait and not load_wait.first then
		load_wait.first = load_wait.t
	end
end)
-- The forms' font sizes rasterized now, under the loading line
-- ([FORMSPEC_FRAME]); the first inventory then draws in a frame
luanti.warm_fonts()

--
-- The sky, and what time it is
--
-- The server says what time it is every few seconds and the clock is
-- carried on here in between, because a sky that jumps every five seconds is
-- worse than one that drifts. Luanti's day is one whole unit: 0.25 is
-- sunrise, 0.5 is noon, 0.75 is sunset.
--
-- simplified: the voxels' own light is what the mesher baked -- the sky
-- light a node has -- so a wall lit by the sky stays as bright at midnight
-- as it is at noon, dimmed only by the sun going away. Luanti's day-night
-- ratio, which scales the sky light per node, is the upgrade path.
local time_of_day = nil
local time_speed = 72

local function blend(a, b, t)
	return magic.Color(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
			a.b + (b.b - a.b) * t)
end

-- What the last sky update worked out, for the line of detail
local sky_now = {height = 0, day = 0}

-- The camera's far clip and the fog from the viewing range ([VIEW_RANGE],
-- FAR_CLIP) and the game's sky. Luanti's fog_distance is not a fog knob
-- but an upper bound on the client's viewing range, and the settled rule
-- is that a game may lower it and never raise it -- see [SKY_KNOBS].
-- Negative gives it back.
function sky_now.apply_far(sky)
	local far = FAR_CLIP
	if sky.fog_distance and sky.fog_distance >= 0 then
		far = math.min(FAR_CLIP, sky.fog_distance)
	end
	sky_now.far_clip = far
	if camera then
		camera.farClip = far
	end
	-- fog_start is a fraction of that range and not a distance; without one
	-- it is where extensions/luanti_client's starts
	if zone then
		if sky_now.fog_off then
			-- Off: past the far clip, so nothing fades (official's fog
			-- toggle draws to the range without the fade)
			zone.fogStart = far * 10
			zone.fogEnd = far * 10 + 1
		else
			zone.fogStart = far * (sky.fog_start or 0.7)
			zone.fogEnd = far
		end
	end
end


-- **Registered after sky_now**, which it writes to: a closure made before
-- that local exists closes over a global of the same name instead, and the
-- handler then dies on its first line with nothing switched -- which is
-- exactly what happened, and what made three sets of reference shots that
-- were all pbr look like three modes that draw the same.
-- Or one of the two parity modes, if this session asked for one. **A startup
-- choice and not a toggle** -- the atlas's surface maps have to be on from the
-- first texture it builds -- so it arrives with luanti:world_info, which the
-- module asks for as its client half loads, well before the first chunk has
-- been meshed. What is already drawn keeps the technique it was drawn with,
-- which is what use_technique_set() says of itself.
--
-- | mode | what it draws | what it matches |
-- | unlit | the baked light and nothing else | official Luanti, shadows off |
-- | shadows | the same, with the sun's shadow map multiplying it | official Luanti as the reference runs it |
-- | pbr | this launcher's own look, and the default | nothing but the sunlit anchor |
--
-- See [RENDER_MODES] in doc/plan/rendering_plan.md.
--
-- **Four names for two files, and nothing new was written for unlit.**
-- VoxelUnlit discards below half alpha already, which is the whole of what
-- masked means; no Luanti game binds surface modifiers, so that name is the
-- plain one; and the sun-gated four go the same way, an unlit surface having
-- no sun to gate. The cube map, set_sky_light() and set_sky_tint() are left
-- alone: neither unlit shader reads any of them.
luanti.sub_world_info(function(info)
	local mode = info.mode or "pbr"
	if mode == "pbr" then
		return
	end
	log:info("BUILDAT_LUANTI_PBR=" .. mode .. ": drawing the world " .. mode)
	-- pbr_debug_shadows: pbr's path with the shadow-kind diagnostic on
	-- ([PBR_FIT] 2c). The mesher, which runs in this client and reads the
	-- same variable, colours each occlusion term into its own channel --
	-- terrain red, corners green, rays blue -- and the shader draws the
	-- vertex colour as it is; the sun and the moon go out (see the
	-- ablation) and the key is pinned at middle grey so a full term reads
	-- as one. BUILDAT_LUANTI_LINEAR=1 beside it, or the curve is on it.
	if mode == "pbr_debug_shadows" then
		sky_now.debug_shadows = true
		voxel_shading.set_shadow_kinds(true)
		if luanti.exposure_pin then luanti.exposure_pin(0.18) end
		return
	end
	-- pbr_debug_light / pbr_debug_nibbles: pbr's path and pbr's mesh, with
	-- the shader drawing a number instead of the world
	-- ([UNDERGROUND_LIGHT]). `light` is every ambient term a face gets
	-- summed -- the sky share, the bounce, the ground, the cave floor, the
	-- lamp -- with no albedo and no sun: the light a "the shadows are not
	-- lit" report is about, and what the gray keys on. `nibbles` is what
	-- the mesher wrote: the flood's share in red, the sky share it becomes
	-- in green, the shade in blue. Both want BUILDAT_LUANTI_LINEAR=1
	-- beside them, or the curve and the meter are on the reading; the key
	-- is pinned so that one on the screen is one in the sky's units.
	-- pbr_debug_skyamb / pbr_debug_baked are `light`'s two halves, and
	-- they exist because the sum could not answer which half carried a
	-- night frame that stayed lit with every uniform ablated
	-- ([SKY_COLUMN_CAVE]).
	if mode == "pbr_debug_light" or mode == "pbr_debug_nibbles" or
			mode == "pbr_debug_ground" or mode == "pbr_debug_skyamb" or
			mode == "pbr_debug_baked" then
		voxel_shading.set_shadow_kinds(mode == "pbr_debug_light" and 2 or
				mode == "pbr_debug_nibbles" and 3 or
				mode == "pbr_debug_skyamb" and 5 or
				mode == "pbr_debug_baked" and 6 or 4)
		if luanti.exposure_pin then
			luanti.exposure_pin(0.18)
		else
			log:warning("exposure: " .. mode .. " could not pin the key; " ..
					"the picture is metered, not absolute")
		end
		return
	end
	-- On sky_now rather than locals of their own: init.lua's main chunk is at
	-- Lua 5.1's two hundred locals and has been for a while
	sky_now.unlit = true
	sky_now.shadows = mode == "shadows"
	-- The light kept in a shadow, until the game's set_lighting() says
	-- (below, the hud handler): Luanti's shadow_intensity 0.33. The shadow
	-- pass reads it from the light and carries no constant of its own.
	sky_lights.sun.shadowIntensity = 0.67
	sky_lights.moon.shadowIntensity = 0.67
	-- The packed vertex layout is the pbr shader's ([PBR_FIT] 2c); the
	-- unlit shader draws the vertex colour as the light, and read the
	-- packed one as purple and green since 2026-09-18 (found 2026-09-20 on
	-- the vp7/vp8 shots). Off here, before any chunk is meshed: the world
	-- streams only after the texture modifiers, which come after this.
	voxelworld.horizon = false
	voxel_shading.set_packed_sky(false)
	-- **And no tonemap, which is half of what either parity mode means.** The
	-- unlit shader writes the light the mesher baked, which is already the
	-- number that belongs on the screen; put that through an HDR buffer, an
	-- exposure bias of 1.6 and Uncharted2 and the world comes out white.
	-- Official Luanti has no tonemap either, and being comparable to it is
	-- what these modes are for. The commands are disabled rather than removed
	-- because that is what a RenderPath offers.
	local vp = magic.renderer:GetViewport(0)
	local rp = vp and vp.renderPath
	if rp then
		rp:SetEnabled("BloomHDR", false)
		rp:SetEnabled("AutoExposure", false)
		rp:SetEnabled("NightGray", false)
		rp:SetEnabled("TonemapUncharted2", false)
		rp:SetEnabled("GammaCorrection", false)
	end
	-- The minimap draws the same world through its own path
	if world_render_path then
		world_render_path:SetEnabled("TonemapUncharted2", false)
		world_render_path:SetEnabled("GammaCorrection", false)
	end
	magic.renderer.HDRRendering = false
	-- The difference between the two modes is one technique: LuantiVoxelUnlit
	-- adds a light pass that multiplies by the shadow factor, VoxelUnlit does
	-- not; the water the same way through LuantiVoxelUnlitAlpha
	-- ([PARITY_LEFTOVERS]).
	local opaque = sky_now.shadows and
			"luanti_client/res/LuantiVoxelUnlit.xml" or
			"luanti_client/res/VoxelUnlit.xml"
	local alpha = sky_now.shadows and
			"luanti_client/res/LuantiVoxelUnlitAlpha.xml" or
			"luanti_client/res/VoxelUnlitAlpha.xml"
	voxel_shading.use_technique_set({
		plain = opaque,
		modifiers = opaque,
		masked = opaque,
		alpha = alpha,
		sun = opaque,
		sun_modifiers = opaque,
		sun_masked = opaque,
		sun_alpha = alpha,
	})
end)
-- Whether the eye is in a node that tints the screen
local underwater = false
-- What the game said its sky is, as luanti.sub_sky() gives it
local game_sky = {}

-- The viewing range, the Luanti settings' view_range row: what the server
-- sends, what is meshed and what the camera draws are all this far; the
-- game's sky may still lower it. Changed live, the server drops what is
-- beyond and the client with it.
function sky_now.set_range(n)
	n = tonumber(n)
	if not n or n < 20 or n > 4000 or n == FAR_CLIP then
		return
	end
	FAR_CLIP = n
	voxelworld.set_send_distance(n)
	sky_now.apply_lod()
	sky_now.apply_far(game_sky)
	log:info("view range: " .. n)
end

-- **How far full detail reaches**, as a share of the viewing range
-- ([CLIENT_FRAME]). Past it a chunk is meshed from a downsampled volume:
-- a quarter of the triangles at the first step, and measurably fewer
-- re-meshes as the player moves, at the price of a coarser silhouette in
-- the distance. What it is for is a machine whose GPU is slower than its
-- processor -- LOD spends CPU to buy triangles back -- and on this desk's
-- Intel a made VoxeLibre world reads 30 fps at full, 55 at half. On a
-- fast GPU it is worth almost nothing. "full" is the default, the
-- server's too ([LOD_FULL_DEFAULT]).
--
-- The share and not a distance, because it has to follow the range the
-- player picks beside it.
local LOD_SHARE = {half = 0.5, third = 1.0 / 3.0}
sky_now.lod_detail = "full"
function sky_now.apply_lod()
	local share = LOD_SHARE[sky_now.lod_detail]
	-- A chunk is placed by its centre, so full detail has to reach a
	-- little past the clip or the rim of the world coarsens
	voxelworld.lod_distance = share and
			math.max(32, math.floor(FAR_CLIP * share)) or 4000
end

function sky_now.set_lod_detail(d)
	if d ~= "full" and d ~= "half" and d ~= "third" then
		return
	end
	if d == sky_now.lod_detail then
		return
	end
	sky_now.lod_detail = d
	sky_now.apply_lod()
	log:info("distant terrain: " .. d .. " (lod_distance " ..
			tostring(voxelworld.lod_distance) .. ")")
end

-- Luanti's indoors colour, the game's own or its default #646464, at a
-- brightness: what a direction that cannot see the sky is drawn as, and
-- what the fog underground is. See [CAVE_SKY].
local function indoors_of(k)
	local c = game_sky.indoors or {r = 0.39, g = 0.39, b = 0.39}
	return {r = c.r * k, g = c.g * k, b = c.b * k}
end

-- The moon has a colour of its own in the sky shader now, so nothing here
-- needs one; see set_moon_look() in luanti_sky.lua
-- A picture of a sun is drawn as itself: the colour multiplies it, so
-- anything but white would tint the game's own art
local WHITE_DISC_COLOR = {r = 1, g = 1, b = 1}

-- The experiment knobs the sky reads, once: update_sky() runs every
-- frame and a get_env is a sandbox call ([FRAME_WORK]). One table, the
-- chunk being at Lua 5.1's two hundred locals.
local SKY_ENV = {
	ablate = buildat.get_env("BUILDAT_LUANTI_ABLATE") or "",
	translucency = tonumber(
			buildat.get_env("BUILDAT_LUANTI_TRANSLUCENCY") or ""),
	light_log = buildat.get_env("BUILDAT_LUANTI_LIGHT_LOG") == "1",
	cloud_n = tonumber(buildat.get_env("BUILDAT_LUANTI_CLOUD_N") or ""),
}

-- The sky at this hour: dark at night, the game's own colour by day, and the
-- dawn colour in between, with the stars fading as the light comes. Luanti
-- keeps three colours for exactly this and blends between them as the sun
-- goes round.
--
-- simplified: three colours and one factor, where Luanti's Sky::update()
-- has a separate brightness for the horizon, a sunrise band and a tonemap.
-- What this is for is a night that looks like night; the rest is the
-- difference between this sky and a photograph of Luanti's.
-- `force` sends all six faces of the reflection cube in this frame
-- rather than one a frame ([CLIENT_FRAME]): the sky the player is
-- under has been replaced, not merely moved on by a frame.
local function apply_sky_of_hour(force)
	local defaults = voxel_shading.sky_defaults
	local day_zenith = game_sky.zenith or defaults.zenith
	local day_horizon = game_sky.horizon or defaults.horizon
	if not sky_now.unlit then
		-- pbr: the day's hue is the render's, the game's own being
		-- display colours for Luanti's sky, not a radiance -- Nishita's (Nishita at 13:00, zenith (2.6, 5.1, 9.4), horizon
		-- (8.5, 12.6, 16.4)), given here display-encoded since dim()
		-- decodes. Luanti's (97, 146, 255) decodes to a zenith three
		-- times as blue as green, and a shadow lit by it read (0.95,
		-- 0.63, 1.8) against the render's (0.35, 0.39, 0.6) -- the
		-- desaturation of every shaded face ([PBR_FIT]).
		day_zenith = PHYS.day_zenith
		day_horizon = PHYS.day_horizon
	end
	-- A night sky the game did not name is its own day sky with the light
	-- taken out of it, which keeps a game's own colour rather than putting
	-- Luanti's blue over it
	local night_zenith = game_sky.night_zenith or
			{r = day_zenith.r * 0.10, g = day_zenith.g * 0.10,
			b = day_zenith.b * 0.14}
	local night_horizon = game_sky.night_horizon or
			{r = day_horizon.r * 0.10, g = day_horizon.g * 0.10,
			b = day_horizon.b * 0.14}
	local dawn_zenith = game_sky.dawn_zenith or
			{r = (day_zenith.r + night_zenith.r) * 0.5,
			g = (day_zenith.g + night_zenith.g) * 0.5,
			b = (day_zenith.b + night_zenith.b) * 0.5}
	local dawn_horizon = game_sky.dawn_horizon or
			{r = day_horizon.r * 0.75, g = day_horizon.g * 0.52,
			b = day_horizon.b * 0.45}
	local function three(night, dawn, day, t)
		local a, b, k
		if t < 0.5 then
			a, b, k = night, dawn, t * 2
		else
			a, b, k = dawn, day, (t - 0.5) * 2
		end
		return {r = a.r + (b.r - a.r) * k, g = a.g + (b.g - a.g) * k,
				b = a.b + (b.b - a.b) * k}
	end
	local t = sky_now.day
	-- The hour's own brightness, out of update_sky. Without it the launcher
	-- drew VoxeLibre's night_horizon #4A6790 as it stands and the night sky
	-- came out sixteen times official Luanti's.
	local lit = sky_now.lit or 1
	-- **The game's sky colours are sRGB and this pipeline is linear.** Luanti
	-- multiplies its colours by the hour and writes the product to an 8-bit
	-- buffer, so what it draws at midnight is that product as it stands;
	-- here the product goes into an HDR buffer and comes back out through
	-- GammaCorrection at the end of the render path, which lifts a dark value
	-- enormously -- a night sky Luanti draws at 0.008 was reaching the screen
	-- at 0.052, six times it. Converting once, here, is what makes the two
	-- ends meet: the day sky survives the round trip unchanged and the night
	-- lands where Luanti puts it.
	local function dim(c)
		local function one(v)
			local x = v * lit
			return x > 0 and x ^ 2.2 or 0
		end
		return {r = one(c.r), g = one(c.g), b = one(c.b)}
	end
	local horizon_now = dim(three(night_horizon, dawn_horizon, day_horizon, t))
	local zenith_now = dim(three(night_zenith, dawn_zenith, day_zenith, t))
	-- [DUSK_PARITY]: Luanti's dusk colours, mixed in by its shares: the
	-- moon's all round, and the difference to the sun's as the glow term,
	-- which is that towards the sun along the horizon and fades away from
	-- it and upwards. The parity modes draw with no gamma correction, so
	-- Luanti's display colour goes in as it stands. Its sunrisebg.png, an
	-- orange glow on the horizon under the sun, is the band's orange here,
	-- on the same clock: all orange from half of it, where the band was a
	-- white patch.
	local hb = sky_now.hb or 0
	local glow = {r = 0, g = 0, b = 0}
	if hb > 0 then
		local pc = sky_now.point
		local function mix(c, v, k)
			return {r = c.r + (v.r - c.r) * k, g = c.g + (v.g - c.g) * k,
					b = c.b + (v.b - c.b) * k}
		end
		local to = mix(horizon_now, pc.sun, hb * 0.5)
		horizon_now = mix(horizon_now, pc.moon, hb * 0.5)
		zenith_now = mix(zenith_now, pc.moon, hb * 0.25)
		glow = {r = to.r - horizon_now.r, g = to.g - horizon_now.g,
				b = to.b - horizon_now.b}
	end
	if sky_now.unlit then
		world_sky:set_parity_band(luanti_sky.DUSK_BAND, math.min(1, 2 * hb),
				glow)
	end
	if not sky_now.unlit then
		-- pbr: Luanti's hue at the reference's radiance ([PBR_FIT] term 1)
		local function at(c, radiance)
			local lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			if lum <= 1e-6 then
				return {r = radiance, g = radiance, b = radiance}
			end
			local k = radiance / lum
			return {r = c.r * k, g = c.g * k, b = c.b * k}
		end
		local f = PHYS.sky(sky_now.height or 0)
		zenith_now = at(zenith_now,
				PHYS.night_sky + (PHYS.sky_zenith - PHYS.night_sky) * f)
		horizon_now = at(horizon_now, PHYS.night_sky +
				(PHYS.sky_horizon - PHYS.night_sky) * PHYS.horizon(sky_now.height or 0))
	end
	world_sky:set_look(zenith_now, horizon_now, nil)
	-- For the fog below, which on the pbr path is this horizon: the same
	-- radiance the sky meets the ground with, not a display colour
	sky_now.horizon_radiance = (not sky_now.unlit) and horizon_now or nil
	-- The dome's hue for the ambient: two parts zenith, one horizon, the
	-- cosine weighting a face sees -- a dawn's warm horizon reaches a
	-- wall, which is what the render's dawn dirt face is lit by
	-- With the horizon white on the pbr path the third of it made every
	-- shade too warm: the render's open shaded wall reads B/R 0.92 and
	-- pbr's 0.68 ([PBR_FIT], open_shade_dirt). Five parts zenith, one
	-- horizon: the band is bright but narrow under the cosine.
	sky_now.dome = {r = (5 * zenith_now.r + horizon_now.r) / 6,
			g = (5 * zenith_now.g + horizon_now.g) / 6,
			b = (5 * zenith_now.b + horizon_now.b) / 6}

	-- What the sun shines with now: its own colour, going red while it is
	-- crossing the horizon, which is where that colour belongs. It does not
	-- blend towards the moon any more -- the moon is a light of its own and
	-- has its own colour. The window is luanti_sky.sun_tint_share(), where
	-- the check is.
	--
	-- The colour is the game's own where it gave one, which is Luanti's
	-- fog_sun_tint and fog_moon_tint; the defaults behind them are Luanti's
	-- too. The moon takes the same handover on the other side of the sky,
	-- where it is crossing the horizon at the same hours.
	--
	-- simplified: fog_tint_type is carried but not read. "default" is
	-- Luanti's classic tinting, which goes through the tonemaps this sky
	-- has nowhere to put -- the drawing half of [SKY_LEFTOVERS] -- so both
	-- modes use the two colours, which is what was hardcoded before.
	local share = luanti_sky.sun_tint_share(sky_now.daylight)
	sky_lights.sun.color = blend(PHYS.SUN_COLOR,
			game_sky.sun_tint or luanti_sky.SUN_TINT, share)
	if not sky_now.unlit then
		-- pbr: the sun's colour from its elevation, not a tint at a
		-- clock (PHYS.sun_color). simplified: no ozone, no aerosol; the
		-- dawn's target is the render's 05:45 (see the plan).
		sky_lights.sun.color = PHYS.sun_color(sky_now.height or 0)
		-- And the disc drawn at that: E0 of the hour over the disc's
		-- solid angle, pi times the half-width squared (0.075 is the
		-- tangent of the half-angle, near enough), in the same colour.
		-- The path trace's disc is this and clips white at every hour;
		-- Luanti's square at texture brightness sat under the snow after
		-- metering ([PBR_FIT] step 2). rgba16f holds 65 504, which the
		-- noon sun's eleven thousand is inside.
		local half = (game_sky.sun_scale or 1) *
				voxel_shading.sky_defaults.sun_half
		local disc = PHYS.sun(sky_now.height or 0) /
				(math.pi * half * half)
		disc = math.min(disc, 65504)
		local sc = sky_lights.sun.color
		world_sky:set_sun_radiance(disc * sc.r, disc * sc.g, disc * sc.b)
	end
	-- pbr: the render's moon, a 4100 K lamp (1, 0.86, 0.70) -- the cold
	-- blue is the parity modes' look, and the night probe read pbr's snow
	-- blue against the render's warm ([NIGHT_LIGHT], 2026-09-20)
	sky_lights.moon.color = sky_now.unlit and blend(PHYS.MOON_COLOR,
			game_sky.moon_tint or luanti_sky.MOON_TINT, share) or
			magic.Color(1.0, 0.86, 0.70)

	-- The sun and the moon are two bodies, drawn at once: the shader puts
	-- the moon opposite the sun, which is where Luanti puts it, so both are
	-- in the sky together and which one can be seen is which way the player
	-- is facing. It used to be one square that changed colour at nightfall,
	-- and a game that shows its moon in the day could not say so.
	--
	-- The game's own picture of each, if it gave one and the client could
	-- compose it -- Luanti's own sun.png and moon.png when the game said
	-- nothing, which is what it draws too. Without one each is the shader's
	-- own painted square, and the moon has its own colour there.
	local sun_picture = body_picture_of("sun", game_sky.sun_texture)
	world_sky:set_sun_texture(sun_picture)
	world_sky:set_sun_look(
			(game_sky.sun_visible ~= false) and
					defaults.sun_half * (game_sky.sun_scale or 1) or 0,
			sun_picture and WHITE_DISC_COLOR or defaults.sun_color)

	local moon_picture = body_picture_of("moon", game_sky.moon_texture)
	world_sky:set_moon_texture(moon_picture)
	-- The disc's size is update_sky()'s: the moon is out in its hours
	-- only, and until the server has said the hour there are none. Kept
	-- on sky_now, because update_sky() ends by calling this: a 0 here
	-- undid its size every frame and the moon was never drawn.
	world_sky:set_moon_look(sky_now.moon_half or 0)

	-- The stars come out as the light goes: Luanti's day_opacity is zero by
	-- default, which is a sky with none in it until the sun is down
	local count = game_sky.star_count or luanti_sky.STARS_DEFAULT
	-- How many cells of the sky's grid have a star in them. The grid is a
	-- quarter of a million cells, not the ten thousand this used to divide
	-- by, so a game's thousand stars was putting **twenty-five times** that
	-- many in the sky -- which is most of why the module's night sky read
	-- three times brighter than official Luanti's. A game that hides its
	-- stars has none.
	local density = (game_sky.stars_visible ~= false) and
			math.min(0.5, luanti_sky.STAR_DENSITY_DEFAULT * count /
					luanti_sky.STARS_DEFAULT) or 0
	-- The count and the night ramp go to different parameters here, which
	-- is what LuantiSky keeps apart and buildat's sky folded together; see
	-- set_star_look() in luanti_sky.lua
	world_sky:set_star_look(density, game_sky.star_color, (1 - t) * (1 - t))

	-- What a direction that cannot see the sky is drawn as: Luanti's indoors
	-- colour, dimmed by the hour, and the game's own say over whether it
	-- happens at all. **By the same brightness the gradient is dimmed by**:
	-- Luanti keeps its indoors colour in the same bright-colour it keeps the
	-- sky's two ends in and multiplies all three by m_brightness at once. A
	-- linear tenth at midnight is five times that, which is enough to be the
	-- night sky -- it is mixed in wherever the sky-visibility cube says a
	-- direction is less than open, which outdoors is most of the low sky.
	world_sky:set_indoors(indoors_of(1), sky_now.lit or 1)
	-- The dim is Luanti's stand-in for the eye adapting to a cave, and
	-- pbr has the real thing in the meter: dimmed by the gate and keyed by
	-- the meter, the sky through a cave mouth read under its lit rim
	-- ([PBR_FIT], cave_opening). The parity modes keep it.
	world_sky:set_auto_dim(sky_now.unlit and
			game_sky.auto_dim_skybox ~= false or false)
	world_sky:set_physical(not sky_now.unlit)

	-- The clouds are white because the sun is on them, so they go with it --
	-- by the same brightness everything else up there goes by, which is what
	-- Luanti does: its Sky keeps a bright cloud colour and hands the Clouds
	-- what is left of it at this hour. The tenth-and-a-bit this used to floor
	-- at is eight times `lit` at midnight, and at viewpoint 1 at 20:30 the
	-- clouds were most of what was left of the night sky's brightness: the
	-- band measured 0.070, 0.080, 0.087 against official Luanti's 0.016,
	-- 0.022, 0.032, where the gradient behind them computes to less than
	-- official's on its own.
	-- [DUSK_PARITY]: Luanti lifts them by 0.15 of the blend and mixes a
	-- quarter of it towards the point colour
	world_sky:set_cloud_light(math.min((sky_now.lit or 1) + 0.15 * hb, 1))
	if hb > 0 then
		world_sky:set_cloud_tint(sky_now.point.mid, hb * 0.25)
	else
		world_sky:set_cloud_tint(nil)
	end
	if not sky_now.unlit then
		-- pbr: the cloud is a reflectance lit by the sun and the sky
		-- ([CLOUD_LIGHT]), not a display colour in a radiance sky. The
		-- game's cloud colour is the albedo (a cloud top's is near 0.9);
		-- the sky's share is the dome's mean, five parts zenith to one
		-- horizon; the sun's share is E_sun of the hour times how high
		-- it is, times k_sun. k_sun is set so that at noon a thin cloud
		-- is CLOUD_N times the zenith patch -- there being no reference
		-- for it, CLOUD_N was rated by the user (PHYS.cloud_n,
		-- default 2; the options are rendered under it).
		local albedo = game_sky.cloud_color or {r = 0.9, g = 0.92, b = 0.95}
		local function lum(c)
			return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		end
		local sky_mean = {r = (5 * zenith_now.r + horizon_now.r) / 6,
				g = (5 * zenith_now.g + horizon_now.g) / 6,
				b = (5 * zenith_now.b + horizon_now.b) / 6}
		local n = SKY_ENV.cloud_n or PHYS.cloud_n
		local noon_mean = (5 * PHYS.sky_zenith + PHYS.sky_horizon) / 6
		-- [DUSK_CLOUD]: a dome of radiance L puts pi L on a face, which
		-- reflects albedo L: the sky's share is the dome's mean as it is.
		-- It was over pi, which k_sun made up for at noon and nothing did
		-- after sunset, where the sun's share is gone: the clouds were a
		-- third of the sky they hang in.
		local k_sun = math.max(0, (n * PHYS.sky_zenith /
				math.max(lum(albedo), 1e-6) - noon_mean) * math.pi /
				PHYS.sun(1))
		-- The sun as the clouds see it: from 7 km up it sets
		-- PHYS.cloud_dip later, through the longer air that reddens it
		local h = (sky_now.height or 0) + PHYS.cloud_dip
		local e = PHYS.sun(h) * math.max(h, 0) * k_sun / math.pi
		local sc = PHYS.sun_color(h)
		-- And the dusk glow is sky light too: what a cloud gets of it is
		-- the dome's mean of LuantiSky's glow term, (1 - y)^2 over the
		-- hemisphere (a third) times away + (1 - away) of a quarter for
		-- cos^2 towards the sun.
		local gm = luanti_sky.dawn_glow(sky_now.height or 0) *
				luanti_sky.DUSK_SKY *
				(luanti_sky.DUSK_AWAY + (1 - luanti_sky.DUSK_AWAY) / 4) / 3
		local gc = luanti_sky.DAWN_COLOR
		world_sky:set_cloud_lit(
				{r = albedo.r * e * sc.r, g = albedo.g * e * sc.g,
					b = albedo.b * e * sc.b},
				{r = albedo.r * (sky_mean.r + gm * gc.r),
					g = albedo.g * (sky_mean.g + gm * gc.g),
					b = albedo.b * (sky_mean.b + gm * gc.b)})
	end
	-- And so does what a pond mirrors: the cube map it comes from is baked
	-- at noon, so without this the water is a bright blue sky at midnight
	-- On pbr the cube is rendered from this same sky at this hour and
	-- carries the night itself, so it is not dimmed a second time
	voxel_shading.set_sky_light(sky_now.unlit and (0.10 + 0.90 * t) or 1.0)
	-- The cube's reflection at 0.7 on pbr ([PBR_FIT] tuning): at 1 the
	-- glint on a grass top carried a blue the render's has not, and the
	-- water's far reflection read 3.4 over its near against 2.5
	-- The ablation is here, where the value is set each frame: set from
	-- the ambient's pass it was overwritten before a frame was drawn
	voxel_shading.set_specular_emphasis(
			SKY_ENV.ablate:find("ibl")
			and 0 or (sky_now.unlit and 1.0 or 0.7))
	-- And what colour that sky is now, which the cube map cannot know: the
	-- reflection is moved towards the zenith of this hour as the day goes,
	-- and left alone at noon, where the cube map is already right
	voxel_shading.set_sky_tint(
			three(night_zenith, dawn_zenith, day_zenith, t), 1 - t)
	sky_cube.refresh(force)
end

local function update_sky(dt)
	if time_of_day == nil then
		return
	end
	-- A day is 24*60*60 game seconds and time_speed is how many of them a
	-- real second is
	time_of_day = (time_of_day + dt * time_speed / (24 * 60 * 60)) % 1.0

	local daylight = time_of_day * 24000
	-- The moon's disc is drawn in the moon's hours only, the ones its
	-- light is on in (moon_amount()), so it is never on a day sky
	-- ([MOON_BY_DAY])
	local moon_half = (game_sky.moon_visible ~= false and
			luanti_sky.moon_amount(daylight) > 0) and
			luanti_sky.MOON_HALF * (game_sky.moon_scale or 1) or 0
	sky_now.moon_half = moon_half
	world_sky:set_moon_look(moon_half)

	-- Where the sun is. Luanti's own stretched day, out of luanti_sky, and
	-- with it the clocks the two lights fade on. The tilt out of the
	-- vertical plane is this game's own, so that noon does not light every
	-- face of a cube the same way.
	--
	-- **Where the shadow is cast from steps and the light does not**: a
	-- shadow map rasterized afresh each frame from a light that has turned a
	-- little between two of them has crawling edges, so the direction is
	-- held still a step at a time. How bright, what colour and whether it is
	-- up stay smooth.
	-- How far the orbit is tilted, and who decided; see
	-- luanti_sky.orbit_tilt(). The one vector it produces is the light's and
	-- the drawn sun's both.
	local tilt = luanti_sky.orbit_tilt(game_sky.body_orbit_tilt,
			(luanti.world_info() or {}).orbit_tilt)
	local sx, sy, sz =
			luanti_sky.sun_direction(luanti_sky.stepped_time(daylight), tilt)
	local mx, smooth_sy, mz = luanti_sky.sun_direction(daylight, tilt)
	local height = smooth_sy
	-- The light travels the other way, which is what a Light's direction is.
	-- **Nothing else is done to it**: the sun is drawn from the same orbit
	-- below, so anything added here would move the sun away from its own
	-- light. The tilt above is the only thing that turns the orbit.
	local dir = normalized({x = -sx, y = -sy, z = -sz})
	-- And the sky is given the sun's, always: it draws the moon opposite,
	-- so there is nothing to flip at nightfall. **The unstepped one**
	-- (user, 2026-10-06): the sun, the moon and the stars moved in jumps
	-- of a step, which is a degree and a half every five seconds at the
	-- default speed. Drawn smooth, the sun is at most half a step from
	-- where its shadow is cast from, which does not show.
	world_sky:set_sun_direction(normalized({x = -mx, y = -smooth_sy, z = -mz}))
	sky_cube.refresh(false)

	-- Dawn and dusk are the half hour either side of the horizon rather
	-- than a switch -- unless the game says what the light is whatever the
	-- hour, which is what a dimension of its own is made of
	local day = math.max(0, math.min(1, (height + 0.15) / 0.3))
	-- And the hour before the sun itself ([DAWN_LIGHT]): the halo is drawn
	-- from the sun's direction and is up well before the disc, while this
	-- ramp is zero until the sun is within half an hour of the horizon --
	-- so 4:00-5:00 read as a bright halo over black ground under a night
	-- sky, and 19:00-20:00 the same. A term that rises with the sun from
	-- about -18 degrees (where the stretched day puts 4:00) to the horizon
	-- and is nothing above it, peaking near official's own ratio at
	-- daybreak, so those two windows gain light and colour and no probed
	-- hour outside them moves: 02:00 (-54 degrees) and 20:30 (-27) are
	-- below it and 05:45 (+10) is above.
	--
	-- This is art and not astronomy, the way Luanti's own ratio is: a dark
	-- dawn is dull to play in. luanti_client's half of it is in
	-- daynight_ratio().
	predawn_now = luanti_sky.predawn(height)
	sun_height_now, day_factor_now = height, math.max(day, predawn_now)
	day = math.max(day, predawn_now)
	if luanti.day_night_override then
		day = luanti.day_night_override
	end
	-- How light it is, which is not the same as which colours the hour uses.
	-- **Luanti multiplies what it drew by this** -- the sky's two ends and
	-- the fog with them -- so a game's night colours are a base to be dimmed
	-- and not the colour of the sky at midnight. The ramp is the extension's:
	-- Luanti's day/night ratio bottoms out at 0.175 rather than nothing, and
	-- goes through its light curve, which a gamma of 2.2 is the shape of.
	sky_now.lit = (0.175 + 0.825 * day) ^ 2.2
	-- [DUSK_PARITY]: Luanti's dusk colours, on the parity modes. Luanti
	-- picks one colour for the whole view by which way the camera faces --
	-- the sun's straight at it, the moon's away -- which shifts the whole
	-- sky as the player turns. Here the sky has both, the sun's towards
	-- the sun (apply_sky_of_hour()), and the fog and the clouds, which
	-- are one colour, take the two half and half (user, 2026-10-06).
	sky_now.hb = sky_now.unlit and
			luanti_sky.horizon_blend(time_of_day or 0.5) or 0
	if sky_now.hb > 0 then
		local sun, moon = luanti_sky.point_colors(sky_now.lit, game_sky)
		sky_now.point = {sun = sun, moon = moon, mid = {
				r = (sun.r + moon.r) / 2, g = (sun.g + moon.g) / 2,
				b = (sun.b + moon.b) / 2}}
	end

	-- How much of each light there is: its own hour of the day, whether it
	-- is over the horizon at all, what the cloud leaves of it, and whether
	-- the game turned it off. A body that is not there casts no light --
	-- VoxeLibre turns all three off when the weather turns -- so that is a
	-- gate and not a dimming. 0.8 is what a full overcast takes.
	local through_cloud = 1 - 0.8 * (game_sky.cloud_cover or 0)
	-- The discs' visibility (set_sun / set_moon) is the discs' alone:
	-- official Luanti lights the day the same with the sun hidden, having
	-- no light from either body, and the reference fixture hides the
	-- moon's disc to keep it out of the crops while its moonlit ground
	-- stays -- the light went with the disc and the night probe read the
	-- moon as absent ([NIGHT_LIGHT], 2026-09-20)
	local up = luanti_sky.sun_amount(daylight) *
			luanti_sky.above_horizon(smooth_sy) * through_cloud
	local moon_up = luanti_sky.moon_amount(daylight) *
			luanti_sky.above_horizon(-smooth_sy) * through_cloud
	-- A light below the horizon is taken out of the scene rather than
	-- dimmed: a directional light does not know about the horizon, and one
	-- under it lights the undersides of everything and puts the night's
	-- specular on the wrong side of the sky.
	-- **In shadows the sun is in the scene for its shadow map alone** --
	-- LuantiVoxelUnlit's light pass multiplies rather than adds, so the
	-- light's colour and brightness never reach the picture -- and **in unlit
	-- it is not there at all**, which is what matches official Luanti with
	-- its dynamic shadows off. In pbr it lights the world the usual way.
	sky_lights.sun_node.enabled = up > 0 and
			not (sky_now.unlit and not sky_now.shadows)
	if up > 0 then
		sky_lights.sun_node.direction = magic.Vector3(dir.x, dir.y, dir.z)
		sky_lights.sun.brightness = sky_now.unlit and SUN_BRIGHTNESS * up or
				PHYS.sun(height)
		-- BUILDAT_LUANTI_ABLATE=sun,shadow,amb,bounce,ground,ibl: a term turned
		-- off for a fit's ablation run ([PBR_FIT]); the sun goes with any
		local abl0 = SKY_ENV.ablate
		if sky_now.debug_shadows then abl0 = abl0 .. ",sun,moon" end
		if abl0:find("sun") then
			sky_lights.sun.brightness = 0
		end
		sky_lights.sun.castShadows = not abl0:find("shadow")
	end
	sky_lights.moon_node.enabled = moon_up > 0 and
			not (sky_now.unlit and not sky_now.shadows)
	-- Said when it changes: the night probe read the moon as absent
	-- ([NIGHT_LIGHT], 2026-09-20), and this is the first thing to ask
	if sky_now.moon_on ~= sky_lights.moon_node.enabled then
		sky_now.moon_on = sky_lights.moon_node.enabled
		log:info(string.format("moon light %s: amount %.2f, elevation %.2f, cloud %.2f, visible %s, disc %.3f",
				sky_now.moon_on and "on" or "off", luanti_sky.moon_amount(daylight),
				-smooth_sy, game_sky.cloud_cover or 0, tostring(game_sky.moon_visible),
				moon_half))
	end
	if moon_up > 0 then
		sky_lights.moon_node.direction =
				magic.Vector3(-dir.x, -dir.y, -dir.z)
		sky_lights.moon.brightness = sky_now.unlit and MOON_BRIGHTNESS * moon_up
				or PHYS.moon_e * moon_up
		if sky_now.debug_shadows or
				SKY_ENV.ablate:find("moon") then
			sky_lights.moon.brightness = 0
		end
	end

	if sky_now.unlit then
		-- Unlit reads cAmbientColor.rgb * vColor.a + vColor.rgb, where the
		-- alpha is how much sky the surface sees, so the ambient is the whole
		-- of the daylight rather than a share of it beside a sun.
		--
		-- **And Luanti's daylight is not white.** get_sunlight_color() gives
		-- `ratio - 0.04` for red and green and `0.98 * ratio + 0.078` for
		-- blue, which at noon is 0.96, 0.96, 1.058 -- a tenth more blue than
		-- red. A neutral ambient, which this was, drew official Luanti's own
		-- stone at B/R 0.90 against its 1.00 and its snow at 1.03 against
		-- 1.12; extensions/luanti_client has carried the colour all along and
		-- reads 0.99 and 1.16 on the same probes. The brightness stays
		-- `lit` -- what is taken here is the hue, normalised at green.
		-- **Linear in the day/night ratio, not through the light curve.**
		-- Luanti applies its curve to the light *level*, which is what the
		-- mesher baked into the vertex colour's alpha and what this ambient
		-- multiplies; the hour enters as get_sunlight_color(), which is
		-- `ratio - 0.04` and linear. Taking the curved value for both
		-- squared the night: the parity modes drew every 20:30 and 02:00 at
		-- a quarter of official Luanti's, which is what the check against
		-- the reference set flagged.
		local ratio = 0.175 + 0.825 * day
		local rg = math.max(ratio - 0.04, 1e-4)
		local blue = (0.98 * ratio + 0.078) / rg
		zone.ambientColor = magic.Color(ratio, ratio, ratio * blue)
		luanti.set_light_units(nil)
	else
		-- pbr: the ambient is the sky's mean radiance, in the sky's hue
		-- -- what a face lit by the sky alone receives, which the shader
		-- multiplies by how much sky the face sees. First cut of the
		-- two-term ambient ([PBR_FIT] term 2): one colour for the whole
		-- hemisphere, no ground bounce yet.
		local f = PHYS.sky(height)
		-- What a horizontal face receives over pi: the render's grass
		-- (albedo 0.036) reads 1.50 sunlit at 13:00 and 0.15 in the
		-- shade at 05:45, which leaves the dome at about the zenith's
		-- radiance -- the horizon's band is bright but at a grazing
		-- weight. So the zenith's, not a mean that counts the horizon.
		-- 0.7 of it: the render's snow in an open shadow at 10:00 reads
		-- (1.6, 3.0, 5.3), which off snow's albedo is a dome of 3.2
		-- against a drawn zenith patch of 4.5 -- Nishita's dome is
		-- bright toward the sun and dark away, and a face sees the mean
		local mean = PHYS.night_sky +
				(PHYS.sky_zenith * PHYS.dome - PHYS.night_sky) * f
		-- In the drawn sky's own hue, which is what a shadow on snow is
		-- lit by: the render's reads (1.6, 3.0, 5.3), the sky's blue,
		-- where a grey ambient gave a grey shadow.
		local c = sky_now.dome or blend(NIGHT_AMBIENT, SKY_AMBIENT, day)
		local lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		local k = lum > 1e-6 and mean / lum or 0
		-- [DAWN_LIGHT]'s glow: on the sky's band, and a share of it added
		-- to the three ambient terms in its orange -- each of which the
		-- shader gates by the face's sky, so a sealed chamber keeps its
		-- dark; never into the cave floor
		local glow = luanti_sky.dawn_glow(height)
		local gc = luanti_sky.DAWN_COLOR
		local ga = glow * luanti_sky.DAWN_AMBIENT
		local gs = glow * luanti_sky.DUSK_SKY
		world_sky:set_dawn_glow(gs * gc.r, gs * gc.g, gs * gc.b,
				luanti_sky.dusk_tint(height))
		zone.ambientColor = magic.Color(c.r * k + ga * gc.r,
				c.g * k + ga * gc.g, c.b * k + ga * gc.b)
		-- And what a face the sky does not reach gets instead: light off
		-- the surroundings, a share of the sky's mean in its hue -- the
		-- second term ([PBR_FIT] term 2), fitted to the render's cave
		-- mouth. simplified: one share for the whole day; the render's
		-- cave at other hours is what would fit it further.
		voxel_shading.set_bounce_light((c.r * k + ga * gc.r) * PHYS.bounce,
				(c.g * k + ga * gc.g) * PHYS.bounce,
				(c.b * k + ga * gc.b) * PHYS.bounce)
		-- A lamp at full in the sky's units: PHYS.lamp, in the glowstone's
		-- own orange, at a torch's own faces ([TORCH_LIGHT]; sky_model.lua
		-- says why not at [LAMP_REF]'s lamp_wall). simplified: one level
		-- and one colour for every light source; a torch is not a
		-- glowstone.
		voxel_shading.set_lamp_light(PHYS.lamp * 1.0, PHYS.lamp * 0.6,
				PHYS.lamp * 0.3)
		-- The same three for the objects and the hand, drawn unlit in
		-- the frame's units ([OBJECT_LIGHT], the unit gap), and the
		-- sun's on a level face, which the open sky adds: without it a
		-- torch held in the midday sun was a shadow's dark blue (user,
		-- 2026-09-30)
		local sun_level = PHYS.sun(height) * math.max(height, 0) / math.pi
		local suc = sky_lights.sun.color
		luanti.set_light_units(zone.ambientColor,
				magic.Color(c.r * k * PHYS.bounce, c.g * k * PHYS.bounce,
						c.b * k * PHYS.bounce),
				magic.Color(PHYS.lamp * 1.0, PHYS.lamp * 0.6, PHYS.lamp * 0.3),
				magic.Color(sun_level * suc.r, sun_level * suc.g,
						sun_level * suc.b))
		voxel_shading.set_translucency_gain(SKY_ENV.translucency or
				PHYS.translucency)
		-- And the ground as the lower hemisphere sees it: its albedo
		-- times what falls on it, the sky on all of it and a third of
		-- the sun, over pi. A third, not the half that is lit on
		-- average: the ground a shaded wall faces is partly in the same
		-- shadow, and the base pass has no shadow map to say which. The
		-- tenth that stood here was fitted to the pit beside vp1's stone
		-- block and left the open shadow on the cliff top 1.75 times too
		-- dark ([PBR_FIT], contrast_dirt against contrast_dirt_pit).
		-- simplified: one albedo for every ground.
		local sun = PHYS.sun(height) * math.max(height, 0) * 1.0 / math.pi
		local sc = sky_lights.sun.color
		voxel_shading.set_ground_light(
				PHYS.ground.r * (sun * sc.r + c.r * k + ga * gc.r),
				PHYS.ground.g * (sun * sc.g + c.g * k + ga * gc.g),
				PHYS.ground.b * (sun * sc.b + c.b * k + ga * gc.b))
		-- [CAVE_AO]: a constant light under the ambient so a cave at both
		-- nibbles nought keeps its corners. The same at every hour, which
		-- is what [UNDERGROUND_LIGHT]'s invariant needs. PHYS.cave_floor,
		-- shared with luanti_client (0.04 picked by the user 2026-09-25 off
		-- local/options_for_UNDERGROUND_LIGHT/, lowered by
		-- [CAVE_EXPOSURE_FLOOR]).
		-- What the camera's own rays say the chamber has, read once: the
		-- floor below and the bounce term's scale both take it
		local chamber_read = voxel_shading.chamber_light()
		local floor_f = PHYS.cave_floor
		-- **Only where the chamber is dark** (2026-09-25): the floor is
		-- hour-independent on purpose -- that is what keeps a sealed
		-- room equal at both hours -- but applied everywhere it lifts
		-- the open world at night as well, and the meter opens on top
		-- of that: a re-take of the reference set drew 20:30 as
		-- daylight, vp4 going from a mean of 8.27 to 114.65. Scaled by
		-- how unlit the chamber the camera is in is, it is the whole
		-- floor in a sealed place, nothing under an open sky, and the
		-- same reading the bounce term's own scale comes from.
		local dark = 1.0 - math.min(1.0, chamber_read)
		voxel_shading.set_cave_ambient(floor_f * dark, floor_f * dark,
				floor_f * dark)
		-- [UNDERGROUND_LIGHT]: and what the bounce term's own floor is
		-- worth here. That floor is the light a face gets where the
		-- flood's nibble says nothing reaches it, and it follows the
		-- hour, so a sealed chamber is lit by the sun it cannot see --
		-- twenty-one levels of it at vp10. Scaled by how lit the chamber
		-- the camera is in is, a sealed place stops following the hour
		-- and a cave lit round a corner keeps its light.
		--
		-- The reading is the camera's rays, not the face's: no face can
		-- work out what arrives round a corner, and the player is taken
		-- to be in the chamber they are looking at (user, 2026-09-25).
		-- **Gain 1, picked by the user 2026-09-25** off the same sheet:
		-- vp10, which nothing reaches, stops following the hour (21.47 at
		-- noon against 0.00 at night, both 0.00 now) while vp8, a cave
		-- lit round a corner, keeps 87% of its daylight.
		local chamber = chamber_read
		voxel_shading.set_chamber_light(chamber)
		cave_ambient_now = chamber
		-- **Every term of the light, said out loud** under
		-- BUILDAT_LUANTI_LIGHT_LOG=1 ([UNDERGROUND_LIGHT]): the sky
		-- ambient a face with the whole sky gets, the bounce and the
		-- ground in the same units, the cave floor and the two per-frame
		-- camera readings that scale them. Read beside the
		-- pbr_debug_light picture, which is what a face actually gets:
		-- the picture says which term is missing and this says why.
		-- Once a second, and nothing at all unless it is asked for.
		if SKY_ENV.light_log and
				(sky_now.light_log_due or 0) <= os.time() then
			sky_now.light_log_due = os.time() + 1
			-- **Five decimals, not three** ([SKY_COLUMN_CAVE], 2026-09-28):
			-- at 02:00 every one of these rounded to 0.000 while
			-- pbr_debug_light drew the same faces at half a unit, and a
			-- whole night's investigation read "the ambient is off" off
			-- that. A night term is small, not absent.
			log:info(string.format("light terms: sky %.5f/%.5f/%.5f " ..
					"bounce %.5f ground %.5f floor %.5f " ..
					"chamber_read %.3f dark %.3f chamber %.3f sky_above %.3f",
					c.r * k, c.g * k, c.b * k, c.r * k * PHYS.bounce,
					PHYS.ground.r * (sun * sc.r + c.r * k),
					floor_f * dark, chamber_read, dark, chamber,
					voxel_shading.sky_visibility_above()) ..
					string.format(" skyvis mean/lo/hi %.3f/%.3f/%.3f",
							voxel_shading.sky_vis_stats()))
		end
		local abl = SKY_ENV.ablate
		if abl:find("amb") then zone.ambientColor = magic.Color(0, 0, 0) end
		if abl:find("bounce") then voxel_shading.set_bounce_light(0, 0, 0) end
		if abl:find("ground") then voxel_shading.set_ground_light(0, 0, 0) end
		if abl:find("lamp") then voxel_shading.set_lamp_light(0, 0, 0) end
	end
	-- And the fog with it. This is the one thing the cave sky needs that is
	-- not per direction, so it takes the mean of the same cube: underground
	-- the haze is the indoors colour rather than a sky the player cannot
	-- see. See [CAVE_SKY].
	local seen = voxel_shading.sky_visibility_above()
	-- And whether the sky is drawn at all, which is a late and conservative
	-- gate rather than a fade: anything less than fully enclosed draws the
	-- sky as it is, and only a cave with essentially no sky over it dims it.
	-- The short ramp is so that walking into one is not a step. See
	-- [CAVE_SKY]'s correction in doc/plan/rendering_plan.md.
	local outside = math.max(0, math.min(1, (seen - 0.02) / 0.08))
	world_sky:set_outside(outside)
	-- Logged when it moves, so a reference run's log carries the gate at
	-- each viewpoint -- the reading [CAVE_SKY] was owed from inside a cave
	if math.abs(seen - (sky_now.seen_said or -1)) >= 0.01 then
		sky_now.seen_said = seen
		log:info(string.format("cave gate: sky seen %.3f, outside %.2f",
				seen, outside))
	end
	-- A game's own fog colour is art direction and wins outright; without one
	-- the fog is the horizon, dimmed by the hour the way the sky it meets is.
	-- **One colour scaled, not two blended**: a hardcoded night fog is a
	-- second thing to keep in step with the gradient, and it was not in step
	-- -- the sky went dark and the fog stayed at 0.05, 0.07, 0.12, which is
	-- what the night sky then measured.
	-- Into the same space as the gradient it meets at the horizon: a fog that
	-- is still sRGB where the sky behind it has been converted is a bright
	-- band along the horizon of a dark sky. See dim() in apply_sky_of_hour().
	local base = game_sky.fog_color or
			blend(magic.Color(0, 0, 0), DAY_FOG, sky_now.lit)
	base = magic.Color(base.r > 0 and base.r ^ 2.2 or 0,
			base.g > 0 and base.g ^ 2.2 or 0,
			base.b > 0 and base.b ^ 2.2 or 0)
	-- [DUSK_PARITY]: half way to the point colour, as the sky's horizon is
	-- (apply_sky_of_hour())
	if not game_sky.fog_color and sky_now.hb > 0 then
		local v = sky_now.point.mid
		base = blend(base, magic.Color(v.r, v.g, v.b), sky_now.hb * 0.5)
	end
	-- On the pbr path the fog is the drawn horizon's radiance of the hour
	-- (apply_sky_of_hour(), a frame behind): a display colour dimmed by
	-- the hour sat at 0.004 under a night sky of 0.00005, and the meter
	-- lifted everything at the far edge of the range -- the snow-topped
	-- trees on vp5's ridge at 02:00 -- to white ([LOD_LIGHT]'s finding:
	-- it was the fog, not the far chunks' mesh path).
	-- And the indoors half of the blend in radiance too: Luanti's indoors
	-- colour (0.39 grey, dimmed by the hour) is display units, and under
	-- a forest's canopy `seen` is well under one, so at 02:00 the fog was
	-- 0.016 against a sky of 0.00005 -- and everything at the far edge of
	-- the range, where the fog is all there is, came out white after the
	-- meter: the snow-topped tree tops on vp5's ridge, at last. What a
	-- cave's haze is on the pbr path is the ambient of the hour, which is
	-- the light a cave gets.
	local indoors = indoors_of(0.10 + 0.90 * day)
	if sky_now.horizon_radiance then
		local h = sky_now.horizon_radiance
		base = magic.Color(h.r, h.g, h.b)
		indoors = zone.ambientColor
	end
	zone.fogColor = blend(base, indoors, 1 - seen)
	sky_now.height = height
	sky_now.day = day
	sky_now.daylight = daylight
	apply_sky_of_hour()
	-- What is in the player's hand is drawn unlit, so the daylight is put
	-- on it by hand; without this it glows at midnight. What the two bodies
	-- are worth to something with no normal to take a share of them by is
	-- the extension's object_sun: the moon counted at what it is worth
	-- against the sun.
	--
	-- simplified: kept as the same floor-and-ramp this always had rather
	-- than the extension's colour with the amount in its alpha, because the
	-- one thing here that is drawn unlit is the held item and a night at
	-- the extension's amount would leave it invisible.
	local k = 0.28 + 0.72 *
			math.min(1, up + moon_up * MOON_BRIGHTNESS / SUN_BRIGHTNESS)
	-- The objects take the same day's amount, by where each stands
	-- ([OBJECT_LIGHT])
	luanti.set_daylight(math.min(1, up + moon_up * MOON_BRIGHTNESS / SUN_BRIGHTNESS))
	-- By the light where the player stands ([WIELD_MESH] 3, Luanti's
	-- light_color): the eye voxel's light as an object there gets it --
	-- the parity floor and ramp, or under pbr the frame's units
	-- ([OBJECT_LIGHT]) -- so a cave darkens the hand and a torch lights
	-- it. No voxel loaded yet: the day's amount alone, as before.
	local cp = camera_node.worldPosition
	local col = luanti.light_color(cp.x, cp.y, cp.z) or magic.Color(k, k, k, 1.0)
	wield_material:SetShaderParameter("MatDiffColor", col)
	-- and the shapes' own materials, clones of it ([WIELD_MESH]); a lit
	-- one's the light there without the sun over the zone's ambient, which
	-- the shader multiplies it by
	local lit_col = nil
	local lit = luanti.light_units ~= nil
	for _, sh in pairs(hotbar_pictures["\1shapes"] or {}) do
		if sh then
			WIELD.set_lit(sh, lit)
		end
		if sh and sh.lit then
			if lit_col == nil then
				local a = luanti.light_color(cp.x, cp.y, cp.z, true) or col
				local z = zone.ambientColor
				local function ratio(v, zv)
					return zv > 1e-6 and v / zv or 0
				end
				lit_col = magic.Color(ratio(a.r, z.r), ratio(a.g, z.g),
						ratio(a.b, z.b), 1.0)
			end
			for _, m in ipairs(sh.materials) do
				m:SetShaderParameter("MatDiffColor", lit_col)
			end
		elseif sh then
			for _, m in ipairs(sh.materials) do
				m:SetShaderParameter("MatDiffColor", col)
			end
		end
	end
end

-- What the game says its sky is: the two ends of the gradient and how much
-- of it is cloud. A game that says nothing keeps the sky voxel_shading
-- draws, which is what create_skybox() set.
luanti.sub_sky(function(sky)
	game_sky = sky
	local cover = nil
	if sky.clouds == false then
		cover = 0
	elseif sky.density then
		cover = math.max(0, math.min(1, sky.density))
	end
	if cover then
		world_sky:set_look(nil, nil, cover)
	end
	-- Kept as well as sent, because cloud dims the sun and the moon; see
	-- through_cloud in update_sky()
	game_sky.cloud_cover = cover
	-- The fog is the horizon seen through the world's air, so it follows
	-- the horizon the game asked for
	if sky.horizon then
		DAY_FOG = magic.Color(sky.horizon.r, sky.horizon.g, sky.horizon.b)
	end
	sky_now.apply_far(sky)
	-- A skybox sky has no gradient to take a fog colour from, so Luanti fogs
	-- it with base_color; a plain sky's base_color is already the sky itself
	if sky.type == "skybox" and sky.base_color and not sky.fog_color then
		DAY_FOG = magic.Color(sky.base_color.r, sky.base_color.g,
				sky.base_color.b)
	end

	-- Six pictures rather than a gradient, if that is what the game asked
	-- for and all six of them arrived
	local handed_over = false
	if sky.type == "skybox" and sky.textures and sky.textures[6] then
		local cube = game_skybox:set(sky.textures)
		-- What the world reflects follows the sky it is under; the zone's
		-- own is the baked gradient, which is what a game with no skybox
		-- keeps
		if cube and zone then
			zone.zoneTexture = cube
			handed_over = true
			log:info("the world reflects the game's own sky now")
		end
	elseif game_skybox:clear() and zone then
		zone.zoneTexture = sky_cube.cube.texture
		handed_over = true
	end
	-- **Forced only when the sky was replaced, not whenever it speaks**
	-- ([CLIENT_FRAME], 2026-09-26). A game sends this packet as often as
	-- it likes -- VoxeLibre's weather sends five of them every three
	-- seconds, for ever -- and a force is six scene renders in one frame,
	-- so the spreading the cube does was undone every three seconds and
	-- the debug HUD read seven views. What has to be immediate is the
	-- handover above, where the thing the world reflects has just been
	-- swapped; an hour that has moved a little can wait for the faces to
	-- go out one a frame.
	apply_sky_of_hour(handed_over)
end)

luanti.sub_time(function(tod, speed)
	time_of_day = tod
	time_speed = speed
	update_sky(0)
end)

--
-- Under water
--
-- Luanti paints the node's own post_effect_color over the screen while the
-- camera is in it -- renderPostFx() in clientmap.cpp: the colour the game
-- gave the node, any node and not only a liquid, and black in a solid one
-- unless noclip is on; the fog is left alone. That is what
-- extensions/luanti_client does too, and what this did before
-- ([RENDER_SURVEY], the underwater tint) was a fixed blue over any liquid
-- with the fog closed to forty nodes, which was neither.
-- simplified: post_effect_color_shaded, which dims the tint by the light
-- where the camera is, is read as the colour given.
local water_tint = magic.ui.root:CreateChild("BorderImage")
water_tint.visible = false
water_tint.priority = -500

-- The registry's definition of the voxel at p, or nil for nothing there
local function voxel_def_at(p)
	local v = voxelworld.get_static_voxel(p)
	if v == nil then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return nil
	end
	return reg:get_by_id(id)
end

-- The liquid at p, or nil: the registry's own is_liquid, so a game's lava
-- counts as much as its water. What the player swims in.
local function voxel_liquid_at(p)
	local def = voxel_def_at(p)
	if def == nil or not def.is_liquid then
		return nil
	end
	return def
end

-- The player's physics, made below; named here so update_underwater()
-- reaches it (it read a global before, and errored every frame the eye
-- was in a solid node -- 16472 frames of a run, 2026-09-20)
local player
local function update_underwater(eye)
	-- The tint of the node the eye is in: the game's colour for it, or
	-- black for a solid node in first person, or nothing
	local color = nil
	local def = voxel_def_at(eye)
	if def then
		local pe = luanti.post_effect_of(def.name.block_name)
		if pe and pe.a > 0 then
			color = magic.Color(pe.r / 255, pe.g / 255, pe.b / 255, pe.a / 255)
		elseif def.physically_solid and not player.noclip then
			color = magic.Color(0, 0, 0, 1)
		end
	end
	local now = color ~= nil
	underwater = now
	water_tint.visible = now
	if now then
		water_tint.texture = game_texture(WHITE)
		water_tint.color = color
		water_tint.size = magic.IntVector2(magic.ui.root.width,
				magic.ui.root.height)
	end
end

--
-- The player
--
-- What stops the player is the registry's own physically_solid, so glass
-- stops them and a plant does not. A voxel that has not arrived stops them
-- as well: standing still in a world that is still loading is better than
-- falling through it.
--
-- A slab or a stair is the boxes its collision_box names, turned by its
-- param, which is what lets a player walk up stairs ([VL_STAIRS]);
-- anything else solid is the whole cube.
local function node_stops(x, y, z)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return true
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return true
	end
	local def = reg:get_by_id(id)
	if def == nil then
		return true
	end
	return def.physically_solid and (reg:collision_boxes_of(v) or true)
end

-- And what the player is standing in, which is the same registry flag the
-- screen tint above reads. It was not passed, so in_liquid was false forever
-- -- no sinking, no swimming, no way out by jumping -- twenty lines from the
-- code that paints the water over the screen: the camera knew it was
-- underwater and the body did not.
local function node_is_liquid(x, y, z)
	-- What the player is in is the node's liquid_move_physics, not
	-- whether it is drawn as a liquid ([WATER_PARITY]: official's
	-- LocalPlayer reads that flag, which a game sets either way)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return false
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return false
	end
	local def = reg:get_by_id(id)
	return def ~= nil and def.swimmable == true
end

-- And what holds the player up instead of letting them fall: a ladder, a
-- vine, a rope. Luanti's own climbable, which the registry carries now.
local function node_is_climbable(x, y, z)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return false
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return false
	end
	local def = reg:get_by_id(id)
	return def ~= nil and def.climbable
end

-- And how much it holds them back: Luanti's move_resistance, which water
-- and lava have without a game saying anything and which a game can put on
-- anything else
local function node_resistance(x, y, z)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return 0
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return 0
	end
	local def = reg:get_by_id(id)
	return (def and def.move_resistance) or 0
end

-- And what standing on it does: the bouncy, slippery, disable_jump and
-- disable_descend groups, which the registry carries as fields. Inline:
-- this file is at Lua's 200-local limit.
player = player_physics.new(node_stops, node_is_liquid,
		node_is_climbable, node_resistance, function(x, y, z)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return nil
	end
	return reg:get_by_id(id)
end)

-- What a mod has done to how this player moves: set_physics_override() on
-- the server. It multiplies the constants above rather than replacing them,
-- so speed boots, low gravity and a jump curse are these numbers arriving.
luanti.sub_physics(function(p)
	-- The game's movement constants ride along as movement_<name>; the
	-- rest is the override that multiplies them
	local override = {}
	for k, v in pairs(p) do
		local name = k:match("^movement_(.*)$")
		if name then
			player.movement[name] = v
		else
			override[k] = v
		end
	end
	player.override = override
	-- Old move is not supported (decided 2026-09-19, [PLAYER_PHYSICS]):
	-- a game that asks for it gets new move and this line
	if p.new_move == 0 then
		log:warning("physics_override new_move = false asked; " ..
				"this client only has new move")
	end
end)

-- And what it has done to the view: set_fov() and set_eye_offset(). The
-- field of view is degrees, or a multiplier of this client's own when the
-- game says so, and 0 hands it back; the eye offset is in tenths of a node,
-- which is what BS is on Luanti's wire.
--
-- simplified: the transition time arrives and is not used -- the change is
-- at once. Luanti eases it over that many seconds, and the number is here
-- when somebody wants that.
local eye_offset = {x = 0, y = 0, z = 0}

luanti.sub_camera(function(c)
	if camera then
		if c.fov and c.fov > 0 then
			keys.fov_want = c.is_multiplier and (CAMERA_FOV * c.fov) or c.fov
		else
			keys.fov_want = CAMERA_FOV
		end
		camera.fov = magic.fov_for(keys.fov_want)
		WIELD.place(camera.fov)
	end
	-- Luanti's own unit here is BS, which is ten units to the node
	eye_offset = {x = (c.eye.x or 0) / 10, y = (c.eye.y or 0) / 10,
			z = (c.eye.z or 0) / 10}
end)
-- Nothing moves until the server says where the player is: what it answers
-- with is the spawn, or where the last run left them, and a client that
-- started walking from somewhere of its own would tell the server that
-- instead. See M.sub_player_pos in the module's client half.
local player_placed = false

luanti.sub_player_pos(function(p)
	player:set_position(p.x, p.y, p.z)
	player.vx, player.vy, player.vz = 0, 0, 0
	-- And which way they were facing, which is send_where() below in
	-- reverse: the horizontal angle turns the other way round from Urho's
	-- yaw, and the vertical one is positive downwards as Urho's pitch is.
	if p.look_h then
		-- Wrapped, because a client that has been turning for a while sends
		-- a yaw of several hundred degrees and gets it back
		yaw = (-math.deg(p.look_h) + 180) % 360 - 180
		pitch = math.deg(p.look_v)
	end
	if not player_placed then
		player_placed = true
		if not load_wait then
			keys.take_world()
		end
	end
	log:info("the server put the player at " ..
			string.format("%.1f, %.1f, %.1f", p.x, p.y, p.z) ..
			string.format(" looking %.0f, %.0f", yaw, pitch))
end)
-- The mouse into the world once the player is placed and the world is in
-- (load_wait_end)
keys.take_world = function()
	if player_placed and not keys.world_taken then
		keys.world_taken = true
		-- **On the web the game starts paused** (user, 2026-09-30): a
		-- browser locks the pointer only for a click, and taking the
		-- mouse without one left a view that spun with a mouse the game
		-- thought it had. The menu's Continue, or a click off it, is
		-- that click. A touchscreen has no lock to ask for.
		-- Wanted all the same: with the menu up that is only noted, and
		-- the menu closing takes the mouse
		if buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil and not keys.touch then
			keys.open_pause()
		end
		set_mouse_in_world(true, "the first placement")
	end
end

-- What F5 shows: the two lines official Luanti's own status row shows, in
-- its units and its order, and buildat's own facts under them. The shape is
-- not a preference: every reference shot's numbers are read off Luanti's
-- row and typed back in here, and a line that prints the same facts
-- differently makes each of those a conversion done by hand. The keys are
-- not here -- they are in the pause menu, which lists the same BINDINGS.
--
-- The top left corner, at the very top, which is where official Luanti and
-- extensions/luanti_client both put it.
local detail_text = hud_text(13)
detail_text:SetText("")
detail_text.horizontalAlignment = magic.HA_LEFT
detail_text.verticalAlignment = magic.VA_TOP
detail_text:SetPosition(8, 8)
-- 0 nothing, 1 the two blocks official Luanti's own first debug level shows,
-- 2 everything. F5 cycles it; see [STATUS_LEVELS]. Starts at 1, so the row
-- is up without a key press -- [STATUS_DEFAULT]. The level is kept on this
-- client for this server, F5's and the settings' ([DEBUG_INFO_SETTING])
local detail_level = tonumber(buildat.storage_read("debug_info") or "") or 1
detail_text.visible = detail_level > 0
keys.set_detail = function(level)
	detail_level = level
	detail_text.visible = level > 0
	buildat.storage_write("debug_info", tostring(level))
	log:info("debug info: " .. level)
end
log:info("debug info at start: " .. detail_level)

-- Luanti's yaw, from the launcher's. The launcher measures from +Z towards
-- +X, the way Urho does; Luanti measures from +Z towards -X, so the number
-- turns the other way round. The cardinal label is Luanti's own, in its own
-- quadrants -- and it is not decoration: it is what says the sign came out
-- right, because a picture labelled "South -Z" cannot be a picture of north.
local function luanti_yaw(internal)
	local y = (360 - internal) % 360
	local label
	if y >= 45 and y < 135 then
		label = "West -X"
	elseif y >= 135 and y < 225 then
		label = "South -Z"
	elseif y >= 225 and y < 315 then
		label = "East +X"
	else
		label = "North +Z"
	end
	return y, label
end

do
	-- The four directions, in the launcher's angles: 0 looks towards +Z and
	-- 90 towards +X, which Luanti calls 0 North and 270 East.
	local cases = {[0] = {0, "North +Z"}, [90] = {270, "East +X"},
			[180] = {180, "South -Z"}, [-90] = {90, "West -X"}}
	for internal, want in pairs(cases) do
		local y, label = luanti_yaw(internal)
		assert(y == want[1] and label == want[2],
				"luanti_yaw(" .. internal .. ") = " .. y .. " " .. label)
	end
end

-- The frame's wall time, held and decayed the way the server's step is
-- ([STEP_PEAK]): halved per minute, with the phase that set it. The
-- phases are what the client's frame does on the main thread that a
-- profiler block would sit around -- the mesh commit and the horizon
-- map (voxelworld's), the sky cube's render, the sky-visibility sweep,
-- this script's own update and the packets' Lua (client/packet.lua) --
-- and "rest" is the frame's time none of them account for: the
-- renderer, the network, the UI. The wall time is
-- the clock between this update and the last -- not Urho's TimeStep,
-- which its minFps clamps to 0.1 s -- so it is the previous frame's and
-- the phases are read one frame late to match it. See [FRAME_PEAK] in
-- doc/plan/performance_plan.md.
-- One table, this file being near Lua's 200 locals. A frame over
-- CEILING_S is a line at debug (trace is voxelworld's per-voxel spam), and the worst since the last info line
-- is said at info every LINE_S; the fuzz run reads the info lines.
-- DECAY halves the peak per 12 s, a fifth of Luanti's minute ([STATUS_MS])
local frame_peak = {DECAY = 0.9715, DECAY_EVERY_S = 0.5,
		CEILING_S = 0.05, LINE_S = 5,
		s = 0, phase = "", decay_due = 0,
		worst = 0, worst_phase = "", line_due = 5,
		-- this frame's own phases, in microseconds, set by the handler
		skyvis_us = 0, script_us = 0, last_us = nil}
function frame_peak.note(dt)
	local now = buildat.get_time_us()
	local wall = frame_peak.last_us and (now - frame_peak.last_us) / 1000000
			or dt
	frame_peak.last_us = now
	frame_peak.wall = wall
	local vw = voxelworld.frame_us
	local pk = buildat.take_packet_us()
	local phases = {
		{"mesh", vw.mesh}, {"horizon", vw.horizon}, {"physics", vw.physics},
		-- **What "rest" was hiding** (2026-09-26): the three above are
		-- parts of voxelworld's Update handler and the rest of it -- the
		-- queue walk, the node updates, the LOD passes -- was accounted
		-- to nothing, so a settled client's every peak read "rest" while
		-- this block was 7.3 ms of a 33 ms frame. What is left after it
		-- is Urho3D's own frame, which is what "rest" should mean.
		{"voxelworld", math.max(0, vw.update - vw.mesh - vw.horizon -
				vw.physics)},
		{"sky cube", sky_cube.us}, {"sky vis", frame_peak.skyvis_us},
		{"script", frame_peak.script_us},
		-- The packets' Lua, named by the packet that took longest
		{"packets " .. pk.worst_name, pk.total},
		-- The module's own frame: the HUD's redraw
		{"hud", luanti.frame_us or 0},
	}
	vw.mesh, vw.horizon, vw.physics, sky_cube.us = 0, 0, 0, 0
	vw.update = 0
	luanti.frame_us = 0
	local accounted = 0
	local longest, longest_phase = 0, "rest"
	for _, ph in ipairs(phases) do
		accounted = accounted + ph[2]
		if ph[2] > longest then
			longest, longest_phase = ph[2], ph[1]
		end
	end
	local rest = wall * 1000000 - accounted
	if rest > longest then
		longest_phase = "rest"
	end
	frame_peak.decay_due = frame_peak.decay_due - dt
	if frame_peak.decay_due <= 0 then
		frame_peak.s = frame_peak.s * frame_peak.DECAY
		frame_peak.decay_due = frame_peak.DECAY_EVERY_S
	end
	if wall > frame_peak.s then
		frame_peak.s, frame_peak.phase = wall, longest_phase
	end
	if wall > frame_peak.worst then
		frame_peak.worst, frame_peak.worst_phase = wall, longest_phase
	end
	if wall >= frame_peak.CEILING_S then
		local said = {}
		for _, ph in ipairs(phases) do
			if ph[2] >= 5000 then
				said[#said + 1] = string.format("%s %.0f ms", ph[1],
						ph[2] / 1000)
			end
		end
		log:debug(string.format("frame %.0f ms: %s", wall * 1000,
				#said > 0 and table.concat(said, ", ") or "rest"))
		-- And Urho's own table at once for a frame mostly outside the
		-- marks: its interval is reset every second by the debug HUD,
		-- so a table five seconds later has lost the frame. Its Max
		-- column is the slow frame's.
		if wall >= 0.2 and accounted < wall * 1000000 * 0.5 and
				buildat.profiler_data and
				(frame_peak.table_at or 0) + 5 < buildat.get_time_us() / 1e6 then
			frame_peak.table_at = buildat.get_time_us() / 1e6
			-- Depth 5, not 4: the per-packet-type block
			-- ("Buildat|packet:<name>", [PACKET_STALL]) sits one under
			-- handle_packet, and naming the packet is the whole point.
			--
			-- **Said at info, not debug** ([CLIENT_FRAME], 2026-09-26):
			-- a frame of a fifth of a second that none of the marks
			-- accounts for is the fault this item is about, and a table
			-- only a debug run prints is a table nobody has. It is
			-- already rare by construction -- a fifth of a second, more
			-- than half of it unaccounted, and one every five seconds at
			-- most.
			log:info("profiler at that frame:\n" ..
					(buildat.profiler_data(5) or ""))
		end
	end
	-- How the world settles around a placed player, once a second while
	-- there is anything left to mesh: the queue, the chunks in scene and
	-- those still undrawn within two chunks -- what says whether a seed
	-- that takes minutes to show anything is the mesher's ([SEED5_SETTLE])
	frame_peak.settle_due = (frame_peak.settle_due or 0) - dt
	if frame_peak.settle_due <= 0 and player_placed then
		frame_peak.settle_due = 1
		local w = voxelworld.counts()
		local undrawn = voxelworld.undrawn_around(
				buildat.Vector3(player.x, player.y, player.z), 2)
		if w.to_mesh > 0 or undrawn > 0 or (frame_peak.settled_said or 0) == 0 then
			frame_peak.settled_said = (w.to_mesh > 0 or undrawn > 0) and 0 or 1
			log:info(string.format("settle: %d to mesh, %d chunks in scene, %d undrawn within 2",
					w.to_mesh, w.chunks, undrawn))
		end
	end
	if load_wait then
		load_wait.t = load_wait.t + dt
		load_wait.fit()
		-- [LOAD_OWN_CHUNK] The chunk the player is in, not the 125 round
		-- it: the rest comes in under play (a phone sat at 40 of 125)
		if load_wait.first and (load_wait.t - load_wait.first >= 60 or
				player_placed and voxelworld.undrawn_around(
				buildat.Vector3(player.x, player.y, player.z), 0) == 0) then
			load_wait_end()
		end
	end
	if load_wait then
		if load_wait.t >= load_wait.next then
			load_wait.next = math.floor(load_wait.t * 2) / 2 + 0.5
			local line = load_wait_line("Loading the world")
			wait_text:SetText(line)
			log:info("load: " .. line)
			local a = (buildat.last_arrival or function() end)()
			if a then
				log:info(string.format("load: last %s %s", a.kind,
						load_wait_show(a)))
			end
		end
	end
	frame_peak.frames = (frame_peak.frames or 0) + 1
	frame_peak.line_due = frame_peak.line_due - dt
	if frame_peak.line_due <= 0 then
		frame_peak.line_due = frame_peak.LINE_S
		-- Only once there is a player: the world loading around the
		-- overview camera is not a frame anyone waits on, and the fuzz
		-- run reads these lines as the walk's
		if player_placed and frame_peak.worst > 0 then
			-- **And the rate beside the peak** ([CLIENT_FRAME],
			-- 2026-09-26): a peak says what the worst frame was and
			-- nothing about what the player is looking at the rest of
			-- the time, and on a client whose frame is the GPU's the
			-- steady rate is the thing that moves when the renderer is
			-- given less to do. Frames since this line last printed.
			log:info(string.format("frame peak %.3f s in %s, held %.3f s" ..
					", %.0f fps", frame_peak.worst, frame_peak.worst_phase,
					frame_peak.s,
					(frame_peak.frames or 0) / frame_peak.LINE_S))
			frame_peak.frames = 0
			-- Urho's own table of the same five seconds when the worst
			-- was over the ceiling: what "rest" was made of
			if frame_peak.worst >= frame_peak.CEILING_S and
					buildat.profiler_data then
				log:debug("profiler over those seconds:\n" ..
						(buildat.profiler_data(4) or ""))
			end
		end
		frame_peak.worst, frame_peak.worst_phase = 0, ""
	end
end

-- How fast frames are coming, over the same quarter second the block is
-- rebuilt in. Luanti's row prints the jitter beside the rate because an
-- average hides a stutter: it is how far the worst frame of the window ran
-- over the average one, which is what a hitch looks like as a number.
local frames, frame_sum, frame_max = 0, 0, 0
local function frame_sample(dt)
	frames = frames + 1
	frame_sum = frame_sum + dt
	if dt > frame_max then
		frame_max = dt
	end
end
local function frame_stats()
	local avg = frames > 0 and frame_sum / frames or 0
	local fps = avg > 0 and 1 / avg or 0
	local jitter = avg > 0 and (frame_max / avg - 1) * 100 or 0
	frames, frame_sum, frame_max = 0, 0, 0
	return fps, jitter
end

-- The counted facts, in the words extensions/luanti_client's debug line uses
-- them in: the two clients reach the same world by entirely different routes,
-- and a count that differs between them names the fault where a picture that
-- differs only asks a question. See doc/plan/luanti_module_plan.md, "The
-- numbers before the pixels".
local function counted_line()
	local c = luanti.counts()
	local w = voxelworld.counts()
	return string.format(
			"%d node definitions | %d item images | %d composed\n" ..
			"%d meshes | %d objects | %d hud | " ..
			"blocks: %d in scene, %d to mesh",
			w.voxel_types, c.items, c.composed,
			c.meshes, c.objects, c.hud, w.chunks, w.to_mesh)
end

-- Put under the lines of detail, which is where a Luanti client's chat goes;
-- assigned with the chat itself further down, because that is where the
-- block it moves is made.
local place_chat

-- The whole block, as one string, and the only place its shape is decided:
-- what is logged and what is drawn have to be the same text or the two
-- disagree eventually, and the disagreement turns up in the middle of a
-- comparison.
--
-- The first two lines are official Luanti's, field for field, so a number
-- here and a number in a reference shot are compared down the column
-- without arithmetic. Two of its fields are not here: drawtime, which needs
-- the renderer's own frame timing, and RTT, which needs the buildat link to
-- measure one. Everything buildat has and Luanti has not is on the lines
-- under them, out of the way of that comparison.
local function status_lines(level)
	local info = luanti.world_info()
	local fps, jitter = frame_stats()
	-- The three modes as words, the ones on and whether they act
	-- ([FLY_MODES]); then the ground
	local mode = player.on_ground and "on the ground" or "falling"
	if player.fly then
		mode = (player.fly_active and "flying" or "fly (no privilege)")
		if player.noclip then
			mode = mode .. (player.noclip_active and ", noclip" or ", noclip (no privilege)")
		end
	end
	if player.fast then
		mode = mode .. (luanti.privs.fast and ", fast" or ", fast (no privilege)")
	end
	local chunk_p = voxelworld.get_chunk_position(buildat.Vector3(
			player.x, player.y, player.z))
	local lyaw, cardinal = luanti_yaw(yaw)
	-- **One composer, and the short level is a subset of it.** Nothing else
	-- may know how to print a status field: the keybind banner this replaced
	-- was a second string written by hand somewhere else, and it ended up
	-- contradicting the row. See [STATUS_LEVELS] in
	-- doc/plan/luanti_module_plan.md.
	local game = info.game ~= "" and info.game or "?"
	-- Which of the three the picture was drawn in. **Three of the six
	-- reference sets differ from each other only by this**, so a shot that
	-- does not name it is the failure the position and the seed are there to
	-- prevent: one that cannot be told from a shot of something else.
	local rmode = info.mode or "pbr"
	-- Where the player is and looks, and the seed, as official Luanti
	-- shows them: with the debug privilege or the game's basic_debug HUD
	-- flag, which is on until a game turns it off ([DEBUG_INFO_PRIV])
	local placed = luanti.privs.debug or luanti.hud_flag("basic_debug")
	local place = placed and string.format(
			" | (%.1f, %.1f, %.1f) | yaw: %.1f\194\176 %s" ..
			" | pitch: %.1f\194\176 | seed: %s",
			player.x, player.y, player.z,
			lyaw, cardinal,
			-- Luanti's pitch is positive looking up, where the launcher's
			-- own is positive looking down as Urho's euler angle is
			-pitch,
			info.seed ~= "" and info.seed or "?") or ""
	-- **Level 1 is one line and stays one line.** It exists so a reference
	-- run can carry a row without burying the thing being photographed, and
	-- that is a standing constraint rather than a detail: it carries what
	-- makes a picture a picture of what it claims to be, and nothing else.
	-- The frame rate is level 2's -- somebody watching frame times is
	-- debugging, which is what that level is for.
	-- The server's longest step, held and decayed: what a click has been
	-- waiting on lately. See [STEP_PEAK] in doc/plan/performance_plan.md.
	-- Latest/peak in whole milliseconds ([STATUS_MS])
	-- Padded to three digits so the row does not bounce: "step:  8/877
	-- ms", "step:453/1422ms" -- the number takes the space and the "ms"
	-- one when it needs it, the colon and the slash still delimit
	local ms = function(latest, peak)
		local a, b = string.format("%3d", latest * 1000),
				string.format("%-3d", peak * 1000)
		return a .. "/" .. b .. (#b > 3 and "ms" or " ms")
	end
	local step = "step:" .. ms(info.step_latest or 0, info.step_peak or 0)
	-- And the client's longest frame beside it ([FRAME_PEAK])
	local frame = "frame:" .. ms(frame_peak.wall or 0, frame_peak.s)
	-- The build, so that one look at a shot says which it is
	-- ([BOX_PLAYTEST_4] 1): b/<version>, where "buildat" stood
	local first = "b/" .. buildat.version() .. " | " .. game .. " | " ..
			rmode .. " | " .. step .. " | " .. frame .. place
	if level == 1 then
		return first
	end
	-- **Level 2's first line is level 1's, exactly** ([BOX_PLAYTEST_4] 2):
	-- the levels differ in what follows, so a number read at one level is
	-- the number at the other. The engine's own version went with it: it
	-- says nothing about this build.
	local blocks = {
		first,
		string.format(
			"FPS: %.0f | dtime jitter: %.1f%% | view range: %d%s%s",
			fps, jitter, sky_now.far_clip or FAR_CLIP,
			(info.step_peak_phase or "") ~= "" and
					(" | step " .. info.step_peak_phase) or "",
			frame_peak.phase ~= "" and
					(" | frame " .. frame_peak.phase) or ""),
		string.format(
			"%s | fov %.0f | speed %.1f, %.1f, %.1f%s%s",
			-- What the camera is actually at, not what this game asked
			-- for: a game's set_fov() changes it, and an FOV that does
			-- not match the shot it is compared against is one of the
			-- three most expensive findings this programme has had
			mode, (camera and camera.fov) or CAMERA_FOV,
			player.vx, player.vy, player.vz,
			-- No chunk_p before voxelworld knows its chunk size (F5 while
			-- the game's files still come)
			placed and chunk_p and string.format(" | chunk %d, %d, %d",
					chunk_p.x, chunk_p.y, chunk_p.z) or "",
			(not chunk_p or voxelworld.chunk_has_physics(chunk_p)) and "" or
					" (no physics)"),
		string.format("%02d:%02d | sun %.2f up, %.0f%% day",
			math.floor((time_of_day or 0) * 24),
			math.floor(((time_of_day or 0) * 24 % 1) * 60),
			sky_now.height, sky_now.day * 100),
		counted_line(),
	}
	return table.concat(blocks, "\n")
end

local detail_timer = 0
local function update_detail(dt)
	-- Every frame, whether the block is up or not: the rate and the jitter
	-- are of the frames, and a window that only counts while somebody is
	-- looking starts empty every time F5 is pressed
	frame_sample(dt)
	if not detail_text.visible then
		-- Rolled anyway, or the first line after F5 reports the jitter of
		-- every frame since the world came up, which is a loading hitch
		if frame_sum >= 0.25 then
			frame_stats()
		end
		return
	end
	detail_timer = detail_timer + dt
	if detail_timer < 0.25 then
		return
	end
	detail_timer = 0
	detail_text:SetText(status_lines(detail_level))
	if place_chat then
		place_chat()
	end
end


--
-- Chat
--
-- What has been said is at the bottom left, above what the player is
-- carrying; T opens a line to say something of one's own, and a line that
-- starts with "/" is a command the game answers. Both ends of it are the
-- server's: the module runs the callbacks, the vendored builtin runs the
-- commands, and what comes back arrives as luanti:chat.
local CHAT_LINES = 8

-- A block of lines rather than one Text with newlines in it, because a line
-- is drawn in as many pieces as it has colours in it
local CHAT_SIZE = 14
local CHAT_LINE_H = 17
local CHAT_COLOR = magic.Color(1.0, 1.0, 0.9)
local chat_block = magic.ui.root:CreateChild("UIElement")
chat_block.horizontalAlignment = magic.HA_LEFT
-- The top left corner, under the lines of detail, which is where
-- extensions/luanti_client already decided a Luanti client's chat goes and
-- why: what a game puts on the screen of its own is along the bottom, and
-- chat down there lands on top of it. This was at the bottom, above the
-- hotbar, and that is exactly the collision.
chat_block.verticalAlignment = magic.VA_TOP
chat_block.size = magic.IntVector2(600, CHAT_LINES * CHAT_LINE_H)

-- And it moves: down as the lines of detail grow, back up when F5 takes them
-- away. Copying the position without copying this gives a block that is
-- right at one size and wrong at every other.
local chat_at_y = nil
place_chat = function()
	local y = 8
	if detail_text.visible then
		y = 8 + detail_text.height + 8
	end
	if y ~= chat_at_y then
		chat_at_y = y
		chat_block:SetPosition(8, y)
	end
end
place_chat()

local chat_input = nil
-- The key that opens the line arrives as text as well, and the line edit
-- would get it: the field goes up on the next frame instead, when that text
-- has gone nowhere. Copied from the extension, which found this out.
local chat_wanted = false

luanti.sub_chat(function(line, lines)
	-- The markup is still in these, which is what makes a coloured line
	-- coloured; luanti.chat_lines has the same lines without it
	local raw = luanti.chat_raw
	local first = math.max(1, #raw - CHAT_LINES + 1)
	chat_block:RemoveAllChildren()
	local y = 0
	for i = first, #raw do
		draw_text_line(chat_block, raw[i], 0, y, CHAT_COLOR, CHAT_SIZE)
		y = y + CHAT_LINE_H
	end
end)

local function close_chat()
	if chat_input then
		chat_input:Remove()
		chat_input = nil
		magic.ui:SetFocusElement(nil)
	end
end

local function open_chat()
	if chat_input then
		return
	end
	chat_input = magic.ui.root:CreateChild("LineEdit")
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	chat_input.textCopyable = true
	chat_input.textSelectable = true
	chat_input.defaultStyle = CHAT_STYLE
	chat_input:SetStyleAuto()
	chat_input.horizontalAlignment = magic.HA_LEFT
	chat_input.verticalAlignment = magic.VA_BOTTOM
	chat_input.size = magic.IntVector2(
			math.min(560, magic.ui.root.width - 16), 26)
	chat_input:SetPosition(8, -8)
	chat_input.enabled = true
	chat_input:SetText("")
	chat_input:SetFocus(true)
end

local function send_chat()
	if not chat_input then
		return
	end
	local text = chat_input:GetText()
	close_chat()
	if text == nil or text == "" then
		return
	end
	buildat.send_packet("main:chat",
			cereal.binary_output({text}, {"array", "string"}))
end

--
-- The HUD a game draws itself: luanti/hud_draw.lua, the renderer both
-- Luanti clients share ([LUANTI_SHARED]); this feeds it the textures, the
-- scale, the camera and the player's inventory.
--
-- Official's minimap: the module both Luanti clients share,
-- luanti_client/res/minimap.lua, served as luanti/minimap.lua
-- ([EXT_HUD_PARITY]). Official's V walks its modes; on sky_now, since the
-- file is at Lua's 200-local line.
sky_now.minimap = (function(ok, err, lib)
	if not ok or type(lib) ~= "table" then
		log:warning("minimap.lua: " .. tostring(err))
		return nil
	end
	return lib
end)(buildat.run_script_file("luanti/minimap.lua"))
sky_now.minimap_mode = 1  -- hidden until V; see [MINIMAP_OFF]

local hud_r = (function(ok, err, lib)
	if not ok or type(lib) ~= "table" then
		error("hud_draw.lua: " .. tostring(err))
	end
	local function load(name)
		local ok2, err2, m = buildat.run_script_file(name)
		if not ok2 or type(m) ~= "table" then
			error(name .. ": " .. tostring(err2))
		end
		return m
	end
	return lib.new(magic, log, {
		hud = load("luanti/hud.lua"),
		formspec = load("luanti/formspec.lua"),
		parent = magic.ui.root,
		scale = hud_scale,
		texture = function(name)
			local resource = luanti.texture(name)
			return resource and game_texture(resource)
		end,
		font = magic.cache:GetResource("Font", buildat.font_mono),
		font_size = 15,
		white = game_texture(WHITE),
		slots = hotbar_metrics,
		inventory = function(list_name)
			local stacks = luanti.inventory and luanti.inventory[list_name]
			if stacks == nil then
				return nil
			end
			local out = {}
			for i, s in ipairs(stacks) do
				local name, count = parse_stack(s)
				out[i] = {count = count,
						texture = name and
						game_texture(luanti.item_texture(name))}
			end
			return out
		end,
		eye = function()
			local p = camera_node.worldPosition
			return p.x, p.y, p.z
		end,
		-- Where a place in the world is on the screen, or nil behind the
		-- camera, which Luanti does not draw a waypoint for either. The
		-- scene's coordinates are the game's node coordinates.
		screen_of = function(x, y, z)
			if camera == nil then
				return nil
			end
			local eye = camera_node.position
			local dir = camera_node:GetWorldDirection()
			if (x - eye.x) * dir.x + (y - eye.y) * dir.y +
					(z - eye.z) * dir.z <= 0 then
				return nil
			end
			local p = camera:WorldToScreenPoint(magic.Vector3(x, y, z))
			return p.x * magic.ui.root.width, p.y * magic.ui.root.height
		end,
		yaw = function() return yaw end,
		minimap = sky_now.minimap and function(parent, w, h)
			local m = sky_now.minimap.new{magic = magic, scene = scene,
					parent = parent, render_path = world_render_path,
					w = w, h = h, zone = zone}
			m:set_mode(sky_now.minimap_mode)
			return m
		end,
		hud_flag = luanti.hud_flag,
	})
end)(buildat.run_script_file("luanti/hud_draw.lua"))
function sky_now.apply_minimap_mode()
	for _, m in ipairs(hud_r.minimaps) do
		m:set_mode(sky_now.minimap_mode)
	end
end

-- What the game last sent, so that the HUD can be drawn again when
-- something it is about -- the player's own inventory -- has changed
local hud_elements = {}

local function draw_hud(elements, flags)
	hud_elements = elements
	-- The health and the breath are the game's to draw and not the client's:
	-- Luanti's own builtin puts hearts and bubbles on the screen as statbar
	-- elements out of the engine's textures, which are served now, and a
	-- game that wants something else of its own replaces them. A bar drawn
	-- here as well was a second one under the hearts.
	--
	-- The game can take the client's own away, and what it draws instead is
	-- these elements; see luanti.hud_flag()
	-- Nothing of it on the loading screen
	local shown = hud_shown and not load_wait
	hud_r.root.visible = shown
	crosshair.visible = shown and luanti.hud_flag("crosshair") and
			not (keys.touch and not keys.touch_crosshair)
	chat_block.visible = chat_shown and luanti.hud_flag("chat")
	hotbar_shown = shown and luanti.hud_flag("hotbar")
	draw_hotbar()
	wielded_text.visible = hotbar_shown
	hud_r:draw(elements)
	-- Official's own minimap ([VIEW_KEYS]): the engine draws one at the
	-- top right whether or not the game adds a minimap element, under the
	-- minimap HUD flag, and V walks its modes; here the same element as a
	-- game's, 128 Luanti pixels, hidden while the mode is "off"
	if #hud_r.minimaps == 0 and shown then
		hud_r:draw_one({type = "minimap", pos = "1,0", offset = "-10,10",
				align = "-1,1", size = "128,128"})
	end
end

luanti.sub_hud(draw_hud)
keys.redraw_hud = function() draw_hud(hud_elements) end
keys.redraw_hud()

-- The game's set_lighting(): shadows.intensity is how dark a shadow is,
-- 1 being black, and Urho's shadowIntensity is the other way round -- how
-- much light a shadow keeps. Luanti's own default is 0 and VoxeLibre asks
-- for 0.33. The saturation is carried and not drawn: it wants a colour
-- grade on the render path, which is [PBR_LEVEL]'s tonemap to settle.
luanti.sub_hud(function()
	local l = luanti.lighting
	if not l or not sky_lights.sun then
		return
	end
	-- On the parity modes only. On pbr a shadow is what the sun does not
	-- reach, lit by the sky alone, which is what the path trace draws;
	-- VoxeLibre's 0.33 kept two thirds of the sun in every shadow and
	-- was the whole of the snow contrast's shortfall (1.2 against the
	-- render's 5.2) -- a Luanti-ism, [PBR_FIT] and [PBR_TARGET].
	local keep = 1 - math.max(0, math.min(1, l.shadow_intensity))
	if not sky_now.unlit then
		keep = 0
	end
	if sky_lights.shadow_keep ~= keep then
		sky_lights.shadow_keep = keep
		sky_lights.sun.shadowIntensity = keep
		if sky_lights.moon then
			sky_lights.moon.shadowIntensity = keep
		end
		log:info(string.format("set_lighting: shadows keep %.2f (the light reads %s), " ..
				"saturation %.2f (not drawn)", keep,
				tostring(sky_lights.sun.shadowIntensity), l.saturation))
	end
end)

hud_follows_inventory = function()
	if hud_r.has_inventory then
		draw_hud(hud_elements)
	end
end

--
-- The pause menu, main/pause.lua; its key binding editor is keys.lua's, the
-- same screen the launcher's settings draw
local open_pause_menu = (function(ok, err, m)
	if not ok or type(m) ~= "function" then
		error("vanilla: could not load pause.lua: " .. tostring(err))
	end
	return m
end)(buildat.run_script_file("main/pause.lua"))({keys = keys})
keys.open_pause = open_pause_menu

--
-- Pointing at a node, and digging it
--
-- The ray is marched here because the camera is here; what the node it hits
-- means is the server's, and core.dig_node() is what it comes to. A voxel
-- is something to point at when it is not the void (id 0) and something
-- stands in it, which is what fully_empty says.

local POINT_RANGE = 12
local POINT_STEP = 0.1

local pointed_p = nil
local pointed_above = nil
-- The pointed node's selection boxes, nil for the cube
local pointed_boxes = nil
-- An object in front of that node, which takes the pointing from it: hit
-- rather than dug, and framed by its own box ([OBJECT_SELECTION_BOX])
local pointed_obj = nil
local pointed_node = scene:CreateChild("pointed")
-- frame_boxes(boxes): the frame drawn round these boxes, {{x0, y0, z0, x1,
-- y1, z1}, ...} about the node's position, each as official draws each of
-- a node's selection boxes ([VL_RAIL_BOXES]). Built again only when the
-- boxes change.
local frame_boxes
do
	-- Four thin strips along the edges of each face of each box: a
	-- wireframe box, the way apps/digger draws one
	local geometry = pointed_node:CreateComponent("CustomGeometry")
	local material = magic.Material.new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureVColMultiply.xml"))
	local c = magic.Color(0.10, 0.10, 0.10)
	local drawn = nil
	frame_boxes = function(boxes)
		local key = {}
		for _, b in ipairs(boxes) do
			key[#key + 1] = string.format("%.3f,%.3f,%.3f,%.3f,%.3f,%.3f",
					b[1], b[2], b[3], b[4], b[5], b[6])
		end
		key = table.concat(key, ";")
		if key == drawn then
			return
		end
		drawn = key
		geometry:BeginGeometry(0, magic.TRIANGLE_LIST)
		geometry:SetNumGeometries(1)
		-- Both windings, since the faces below are not all turned the
		-- same way round
		local function quad(a, b, cc, d)
			for _, v in ipairs({a, b, cc, cc, d, a, a, d, cc, cc, b, a}) do
				geometry:DefineVertex(v)
				geometry:DefineColor(c)
			end
		end
		for _, box in ipairs(boxes) do
			-- Just outside the box, so it does not z-fight
			local l = {box[1] - 0.004, box[2] - 0.004, box[3] - 0.004}
			local h = {box[4] + 0.004, box[5] + 0.004, box[6] + 0.004}
			for ax = 1, 3 do
				local u, w = ax % 3 + 1, (ax + 1) % 3 + 1
				-- A strip is 1/16 thick, and thinner on a thin box
				local tu = math.min(1.0 / 16, (h[u] - l[u]) / 3)
				local tw = math.min(1.0 / 16, (h[w] - l[w]) / 3)
				for _, s in ipairs({l[ax], h[ax]}) do
					local function v(pu, pw)
						local q = {}
						q[ax], q[u], q[w] = s, pu, pw
						return magic.Vector3(q[1], q[2], q[3])
					end
					quad(v(l[u], l[w]), v(l[u] + tu, l[w]), v(l[u] + tu, h[w]),
							v(l[u], h[w]))
					quad(v(h[u] - tu, l[w]), v(h[u], l[w]), v(h[u], h[w]),
							v(h[u] - tu, h[w]))
					quad(v(l[u], l[w]), v(h[u], l[w]), v(h[u], l[w] + tw),
							v(l[u], l[w] + tw))
					quad(v(l[u], h[w] - tw), v(h[u], h[w] - tw), v(h[u], h[w]),
							v(l[u], h[w]))
				end
			end
		end
		geometry:Commit()
		geometry:SetMaterial(0, material)
	end
	frame_boxes({{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}})
	pointed_node.enabled = false
end

-- A voxel is something to point at when it is not the void and something
-- stands in it. Which type it is has to be asked of the registry: a
-- VoxelInstance's own id is the legacy layout of the word, and this world
-- says otherwise -- Luanti's id is sixteen bits with the light above it.
local function voxel_is_solid(v)
	if v == nil then
		return false
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return false
	end
	local def = reg:get_by_id(id)
	return def ~= nil and not def.fully_empty, def
end


-- The voxel the ray hit, and the last empty one before it -- which is where
-- a node is placed and what Luanti calls the "above" of a pointed thing.
-- How far it reaches is what the player is holding reaches: Luanti's
-- getToolRange(), which luanti.dig_range() answers, bounded by what this
-- march can afford.
-- Where the pointing ray goes: the camera's way, or on a touchscreen in
-- Luanti's tap style through the last finger on the world
-- ([TOUCH_PARITY]; Luanti's getShootline). simplified: the view bobbing's
-- roll is left out of the finger's ray.
keys.point_dir = function()
	local t = keys.touch
	if not t or not t.aim or keys.touch_crosshair then
		return camera_node.worldDirection
	end
	local w, h = magic.ui.root.width, magic.ui.root.height
	local th = math.tan(math.rad(((camera and camera.fov) or CAMERA_FOV) / 2))
	-- The finger's point on a plane a unit ahead, turned by the pitch and
	-- then the yaw as the camera's rotation is
	local a = (2 * t.aim.x / w - 1) * th * w / h
	local b = (1 - 2 * t.aim.y / h) * th
	local p, y = math.rad(pitch), math.rad(yaw)
	local y1 = b * math.cos(p) - math.sin(p)
	local z1 = b * math.sin(p) + math.cos(p)
	local x2 = a * math.cos(y) + z1 * math.sin(y)
	local z2 = z1 * math.cos(y) - a * math.sin(y)
	local l = math.sqrt(x2 * x2 + y1 * y1 + z2 * z2)
	return magic.Vector3(x2 / l, y1 / l, z2 / l)
end

local function find_pointed_voxel()
	local p0 = buildat.Vector3(camera_node.worldPosition)
	local dir = buildat.Vector3(keys.point_dir())
	local last = nil
	local range = math.min(POINT_RANGE, luanti.dig_range(wield_index))
	for i = 1, math.floor(range / POINT_STEP) do
		local p = (p0 + dir * (i * POINT_STEP)):round()
		if p ~= last then
			-- Luanti's pointable ([POINTABLE]): the ray goes through a
			-- pointable = false node (water in most games, decor) as
			-- through the void, and stops with nothing pointed at
			-- "blocking" (2)
			local v = voxelworld.get_static_voxel(p)
			local solid, def = voxel_is_solid(v)
			if solid and def.pointable ~= 0 then
				if def.pointable == 2 then
					return nil, nil
				end
				-- Its selection boxes when it has them ([VL_RAIL_BOXES]):
				-- the nearest one the ray meets, and the node beyond the
				-- face it meets is the above, as official's; a ray that
				-- meets none goes on to what is behind
				local boxes = voxelworld.get_voxel_registry():selection_boxes_of(v)
				if not boxes then
					return p, last or p
				end
				local best, normal = range, nil
				for _, b in ipairs(boxes) do
					local t0, t1, n = 0, best, nil
					for ax, k in ipairs({"x", "y", "z"}) do
						local o, d = p0[k] - p[k], dir[k]
						if math.abs(d) < 1e-9 then
							if o < b[ax] or o > b[ax + 3] then
								t0 = math.huge
							end
						else
							local a1, a2 = (b[ax] - o) / d, (b[ax + 3] - o) / d
							if a1 > a2 then
								a1, a2 = a2, a1
							end
							if a1 > t0 then
								t0, n = a1, {0, 0, 0}
								n[ax] = d < 0 and 1 or -1
							end
							t1 = math.min(t1, a2)
						end
					end
					if t0 <= t1 and t0 < best then
						best, normal = t0, n or {0, 0, 0}
					end
				end
				if normal then
					return p, p + buildat.Vector3(normal[1], normal[2], normal[3]),
							boxes
				end
			end
			last = p
		end
	end
	return nil, nil
end

-- What the node at a voxel is called, which is what luanti.dig_time() wants:
-- the voxel definition's own name is the node's name, because that is what
-- built the registry
local function node_name_at(p)
	if p.y >= luanti.REGION_Y then
		return luanti.body_node_name(p)
	end
	local v = voxelworld.get_static_voxel(p)
	if v == nil then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return nil
	end
	local def = reg:get_by_id(id)
	return def and def.name.block_name or nil
end

-- `event scan <resolution> <label>` ([SCAN_EVENT]) lives in scan.lua and
-- is handed what it reads of this file's state as functions, this file
-- being at Lua's 200 locals
(function(ok, err, install)
	if not ok or type(install) ~= "function" then
		error("vanilla: could not load scan.lua: " .. tostring(err))
	end
	return install
end)(buildat.run_script_file("main/scan.lua"))({
	camera_node = function() return camera_node end,
	view = function() return yaw, pitch, (camera and camera.fov) or CAMERA_FOV end,
	pointed = function() return pointed_p end, -- the frame's, bodies included
	node_name_at = node_name_at,
	voxel_is_solid = voxel_is_solid,
	dig_range = function() return math.min(POINT_RANGE, luanti.dig_range(wield_index)) end,
	-- The view turned to a world point, for `event look_body`: a fallen
	-- body lands where physics put it, which no script knows beforehand
	look_at = function(x, y, z)
		local eye = camera_node.worldPosition
		yaw, pitch = angles_from_dir({x = x - eye.x, y = y - eye.y, z = z - eye.z})
	end,
	chat_text = function() return chat_input and chat_input:GetText() end,
	hud_rect = function(e)
		local el = e.__placed
		if not el then
			return nil
		end
		local at = el.screenPosition
		return at.x, at.y, el.width, el.height
	end,
	player_pos = function() return player.x, player.y, player.z end,
	wield = function() return hotbar_stacks[wield_index] end,
	hotbar = function() return hotbar_stacks end,
	keys = function() return BINDINGS end,
	log = log,
})

local function voxel_packet_value(p)
	return {
		x = math.floor(p.x + 0.5),
		y = math.floor(p.y + 0.5),
		z = math.floor(p.z + 0.5),
	}
end

local VOXEL_PACKET_TYPE = {"object",
	{"x", "int32_t"},
	{"y", "int32_t"},
	{"z", "int32_t"},
}

--
-- The dig, which is held rather than clicked
--
-- Luanti times a dig on the client: how long the node takes is worked out
-- from its groups and what is in hand -- luanti.dig_time(), out of the dig
-- props -- and the server hears the punch on the way in and the dig when
-- the time is up. The server digs the node itself and checks again, so a
-- client that says a dig took no time gets nothing for it.

-- A frame of the crack strip, as a resource name: Luanti's own
-- crack_anylength.png, cut into frames by the same [verticalframe an
-- animated tile uses. "anylength" is the promise that how many frames it
-- holds is the picture's own shape rather than a number written down.
local CRACK_FRAMES_DEFAULT = 5
local crack_frames = nil
local crack_resource = {}

local function crack_frame_count()
	if crack_frames then
		return crack_frames
	end
	crack_frames = CRACK_FRAMES_DEFAULT
	local resource = luanti.texture("crack_anylength.png")
	local tex = resource and
			magic.cache:GetResource("Texture2D", resource) or nil
	-- A strip of square frames, so how many there are is its shape
	if tex and tex.width > 0 and tex.height > tex.width then
		crack_frames = math.floor(tex.height / tex.width)
	end
	return crack_frames
end

local function crack_texture(index)
	local resource = crack_resource[index]
	if resource == nil then
		resource = luanti.texture("crack_anylength.png^[verticalframe:" ..
				crack_frame_count() .. ":" .. index) or false
		crack_resource[index] = resource
	end
	return resource or nil
end

-- The crack itself: a cube just outside the voxel wearing one frame.
--
-- One node per frame, enabled one at a time, rather than one node whose
-- material is swapped: a Material lives only as long as something in the
-- engine holds it, and a StaticModel that has been handed one is such a
-- thing -- keeping materials in a Lua table and putting them back later
-- reads the freed one.
--
-- simplified: the crack on a stair or a torch is a cube around it, because
-- it is a cube and not the node's own shape wearing a second layer. The
-- faithful way is a voxel type per (definition, frame), which is five more
-- per definition on top of VoxeLibre's several thousand.
local crack_nodes = {}
local crack_worn = nil

local function crack_node_for(resource)
	local node = crack_nodes[resource]
	if node then
		return node
	end
	node = scene:CreateChild("crack")
	local model = node:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	local material = magic.Material.new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/DiffUnlitAlpha.xml"))
	local texture = magic.cache:GetResource("Texture2D", resource)
	if texture then
		texture.filterMode = magic.FILTER_NEAREST
		material:SetTexture(0, texture)
	end
	model.material = material
	-- Just outside the voxel, so the crack does not fight the face it
	-- covers for the depth buffer
	node.scale = magic.Vector3(1.004, 1.004, 1.004)
	node.enabled = false
	crack_nodes[resource] = node
	return node
end

local function set_crack(p, resource)
	if crack_worn and crack_worn ~= resource then
		crack_nodes[crack_worn].enabled = false
		crack_worn = nil
	end
	if p == nil or resource == nil then
		return
	end
	local node = crack_node_for(resource)
	node.position = magic.Vector3.from_buildat(luanti.body_world(p) or p)
	node.enabled = true
	crack_worn = resource
end

-- What is being dug: {p =, name =, time =, elapsed =, done =}. time is nil
-- when what is held cannot dig this at all, and then nothing is ever sent.
local dig = nil

local function update_crack()
	if dig == nil or dig.time == nil or dig.time <= 0 or dig.done then
		set_crack(nil, nil)
		return
	end
	local frames = crack_frame_count()
	local index = math.floor(dig.elapsed / dig.time * frames)
	if index < 0 then
		index = 0
	elseif index > frames - 1 then
		index = frames - 1
	end
	set_crack(dig.p, crack_texture(index))
end

-- A node this client writes ahead of the server's answer ([PREDICTION]):
-- Luanti's client does the same and lets the server's update overwrite it,
-- which comes whatever the server made of the dig or place -- see
-- core.__dig_node() and core.__use_node() in the module. The voxel keeps
-- its light and param; the id is what changes. Voxel ids are content ids,
-- and the registry names them by node name. On WIELD for Lua's 200-local
-- limit; WIELD.predict_ids is node name -> voxel id.
WIELD.predict_ids = {count = -1}
function WIELD.predict_node(p, name)
	local reg = voxelworld.get_voxel_registry()
	if reg == nil or name == "" then
		return
	end
	local ids = WIELD.predict_ids
	if ids.count ~= reg:get_count() then
		ids = {count = reg:get_count()}
		for i = 1, ids.count do
			local def = reg:get_by_id(i)
			if def then
				ids[def.name.block_name] = i
			end
		end
		WIELD.predict_ids = ids
	end
	local id = ids[name]
	if id == nil then
		return
	end
	local v = voxelworld.get_static_voxel(p)
	if v == nil or reg:id_of(v) == 0 then
		return
	end
	voxelworld.set_static_voxel(p, reg:with_id(v, id))
	log:info(string.format("predicted %s at (%d, %d, %d)", name,
			p.x, p.y, p.z))
end

local function dig_packet(name, p)
	buildat.send_packet(name, cereal.binary_output({
		p = voxel_packet_value(p),
	}, {"object", {"p", VOXEL_PACKET_TYPE}}))
	if name == "main:dig" and dig and dig.name then
		local pr = luanti.prediction(dig.name)
		local dug_name = node_name_at(p)
		WIELD.predict_node(voxel_packet_value(p), pr and pr.dig or "air")
		-- **And the sound of it** ([NO_SOUND], 2026-09-25): the builtin
		-- plays a dig with the digger excluded, official's own client
		-- playing its own, so this is the one place the player who dug
		-- can hear it. **The node's name and not dig.name**, which is
		-- the wielded item -- the prediction above is keyed by the item
		-- and the sound by what is being dug -- and read before the
		-- prediction puts air there.
		luanti.dig_sound(dug_name, p.x, p.y, p.z)
	end
	-- Which chunk the dug voxel is in, and which node draws it. The client
	-- says when a chunk that changed waits to be drawn again and names it by
	-- node id (see builtin/voxelworld's client half), and this is the line
	-- that matches a dig against those: a dug voxel whose chunk is among
	-- them waited its turn, and one that is not is a chunk nobody asked to
	-- redraw. See section 3 of doc/plan/master_plan.md.
	if name == "main:dig" then
		local chunk_p = voxelworld.get_chunk_position(
				buildat.Vector3(p.x, p.y, p.z))
		local node = voxelworld.get_static_node(chunk_p)
		log:info(string.format(
				"dug (%d, %d, %d) in chunk (%d, %d, %d), chunk node %s",
				p.x, p.y, p.z, chunk_p.x, chunk_p.y, chunk_p.z,
				node and tostring(node:GetID()) or "none"))
	end
end

-- An object is hit rather than dug: one hit per press, and no faster than
-- this while the button is held, which is Luanti's own object_hit_delay
local OBJECT_HIT_DELAY = 0.2
local hit_wait = 0

local function update_dig(dt, playing)
	-- On a touchscreen the first finger is also the left button, which
	-- SDL makes of it: the touch controls say when a dig is held
	local holding = playing and (keys.touch and keys.touch.dig or
			not keys.touch and magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT))
	-- What swings the hand, wherever it points ([DIG_SWING_SOUND])
	WIELD.holding = holding
	hit_wait = math.max(0, hit_wait - dt)
	if not holding then
		hit_wait = 0
	end
	-- An object in front of the node is what is hit (pointed_obj, found
	-- with the frame), at the reach a dig has
	if holding then
		local id = pointed_obj
		if id then
			dig = nil
			update_crack()
			if hit_wait <= 0 then
				hit_wait = OBJECT_HIT_DELAY
				buildat.send_packet("main:punch_object", cereal.binary_output(
						{tostring(id)}, {"array", "string"}))
			end
			return
		end
	end
	if not holding or pointed_p == nil then
		dig = nil
		update_crack()
		return
	end
	if dig == nil or dig.p ~= pointed_p then
		local name = node_name_at(pointed_p)
		-- And the group the dig goes by, which a "__group" dig sound is
		-- named after
		local time, group = nil, nil
		if name then
			time, group = luanti.dig_time(name, wield_index)
		end
		dig = {
			p = pointed_p,
			name = name,
			time = time,
			group = group,
			elapsed = 0,
		}
		-- A mod's on_punch runs on the way in, whether or not the node can
		-- be dug at all
		log:debug("dig: " .. tostring(dig.name) .. " takes " ..
				tostring(dig.time) .. " s")
		dig_packet("main:dig_start", dig.p)
		update_crack()
		return
	end
	if dig.done then
		return
	end
	dig.elapsed = dig.elapsed + dt
	if dig.time and dig.elapsed >= dig.time then
		dig_packet("main:dig", dig.p)
		dig.done = true
	end
	update_crack()
end

magic.SubscribeToEvent("MouseButtonDown", function(event_type, event_data)
	-- The pointer lock asked for again by a click, which a browser grants
	-- (lost to Escape, or asked for at the join with no click to go on);
	-- Urho3D asks only while it is not held
	if mouse_in_world then
		keys.web_lock(true)
	end
	local button = event_data:GetInt("Button")
	if button ~= magic.MOUSEB_LEFT and button ~= magic.MOUSEB_RIGHT then
		return
	end
	-- A form on the screen is clicked through UIMouseClick below, which is
	-- what says where the click landed; what is behind it is not what was
	-- clicked on. A touchscreen's finger is its own (luanti/touch.lua).
	if luanti.form_open() or keys.touch or load_wait then
		return
	end
	if button == magic.MOUSEB_RIGHT then
		keys.place_now()
	end
end)

-- Luanti's place-or-use at what is pointed at: the right button, and a
-- touchscreen's tap
keys.place_now = function()
	if pointed_p == nil then
		log:info(string.format("click at nothing: reach %.1f",
				math.min(POINT_RANGE, luanti.dig_range(wield_index))))
		return
	end
	-- The right button is Luanti's place-or-use: what it comes to is the
	-- node's on_rightclick if it has one and the wielded item's on_place
	-- otherwise, which is the server's to decide
	-- Shift is Luanti's sneak: held, it means build against the node rather
	-- than use it, which is the only way to put something on top of a chest
	local under = voxel_packet_value(pointed_p)
	local above = voxel_packet_value(pointed_above or pointed_p)
	local sneak = key_down("sneak") or magic.input:GetKeyDown(magic.KEY_LSHIFT) or
			magic.input:GetKeyDown(magic.KEY_RSHIFT)
	buildat.send_packet("main:place", cereal.binary_output({
		under = under,
		above = above,
		sneak = sneak and 1 or 0,
	}, {"object",
		{"under", VOXEL_PACKET_TYPE},
		{"above", VOXEL_PACKET_TYPE},
		{"sneak", "byte"},
	}))
	-- The placement predicted, by Luanti's client's rules
	-- (Game::nodePlacement): the wielded item's node_placement_prediction
	-- into above, or into under when that is buildable_to; not when the
	-- pointed node takes the click (on_rightclick, no sneak), the item
	-- predicts nothing, or a walkable node would land in the player's
	-- own box (which the server refuses; core.__use_node). simplified:
	-- a node whose param2 the placement works out from the look
	-- (facedir, wallmounted) waits for the server; what it needs is the
	-- module's placement arithmetic on this side.
	local held = parse_stack(hotbar_stacks[wield_index])
	local pr = held and luanti.prediction(held)
	local upr = luanti.prediction(node_name_at(pointed_p) or "")
	local at = (upr and upr.buildable_to) and under or above
	local in_body = pr and pr.walkable and
			at.x + 0.5 > player.x - 0.3 and at.x - 0.5 < player.x + 0.3 and
			at.y + 0.5 > player.y and at.y - 0.5 < player.y + 1.75 and
			at.z + 0.5 > player.z - 0.3 and at.z - 0.5 < player.z + 0.3
	if pr and pr.place ~= "" and not pr.placed_param2 and not in_body and
			not (upr and upr.rightclick and not sneak) then
		WIELD.predict_node(at, pr.place)
		-- The placed node's own sound, for the same reason the dig's is
		-- here: item_place excludes the player who placed it
		luanti.place_sound(pr.place, at.x, at.y, at.z)
	end
end

-- The wheel picks a hotbar slot, which is what it does in Luanti
magic.SubscribeToEvent("MouseWheel", function(event_type, event_data)
	if luanti.form_open() then
		-- Over a scroll_container the wheel is that container's
		-- ([FORMSPEC_SCROLL]); anywhere else in a form it is nobody's
		luanti.form_wheel(event_data:GetInt("Wheel"))
		return
	end
	if chat_input then
		return
	end
	set_wield(wield_index - event_data:GetInt("Wheel"))
end)

-- Where the mouse is, which a tooltip needs and GetMouseMove does not say:
-- that is the movement since the last frame. Input reports window pixels and
-- a form is laid out in the UI's own coordinates, which are those divided by
-- the UI scale -- the same ones a click arrives in.
magic.SubscribeToEvent("MouseMove", function(event_type, event_data)
	local scale = magic.ui:GetScale()
	if not scale or scale <= 0 then
		scale = 1
	end
	local rp = magic.ui.root.position
	-- The button state goes with it: a scrollbar's thumb is dragged while
	-- it is held ([FORMSPEC_SCROLL])
	luanti.hover(math.floor(event_data:GetInt("X") / scale) - rp.x,
			math.floor(event_data:GetInt("Y") / scale) - rp.y,
			magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT))
end)

-- Where a click landed, which MouseButtonDown does not say. A form is the
-- only thing here that cares.
magic.SubscribeToEvent("UIMouseClick", function(event_type, event_data)
	-- A touchscreen's taps are clicked by luanti/touch.lua
	if not luanti.form_open() or keys.touch then
		return
	end
	local button = event_data:GetInt("Button")
	-- Less the root's own position: a scripted client's root sits in a
	-- letterbox ([SEQ_FIXED_SIZE]) and a form's rectangles are the root's
	local rp = magic.ui.root.position
	luanti.click(event_data:GetInt("X") - rp.x, event_data:GetInt("Y") - rp.y,
			button == magic.MOUSEB_RIGHT and "right" or
			button == magic.MOUSEB_MIDDLE and "middle" or "left")
end)

-- A stack picked up by a press and let go over another slot: a drag
magic.SubscribeToEvent("MouseButtonUp", function(event_type, event_data)
	if not luanti.form_open() or keys.touch then
		return
	end
	local button = event_data:GetInt("Button")
	luanti.release(button == magic.MOUSEB_RIGHT and "right" or
			button == magic.MOUSEB_MIDDLE and "middle" or "left")
end)

-- Official's three mode toggles ([FLY_MODES]): each says its line in the
-- chat, with the note when the player lacks the privilege of the same
-- name -- the mode is still switched, as official does, and the server
-- holds the player down
keys.toggle_mode = function(mode, word)
	player[mode] = not player[mode]
	luanti.send_modes(player.fly, player.fast, player.noclip)
	local line = word .. (player[mode] and " enabled" or " disabled")
	if player[mode] and not luanti.privs[mode] then
		line = line .. " (note: no '" .. mode .. "' privilege)"
	end
	luanti.chat_local(line)
	log:info(line)
end

-- And as the player left them in this world ([FLY_STATE_SAVE])
luanti.sub_modes(function(modes)
	player.fly, player.fast, player.noclip = modes.fly, modes.fast, modes.noclip
	log:info("modes as left: fly " .. tostring(player.fly) .. ", fast " ..
			tostring(player.fast) .. ", noclip " .. tostring(player.noclip))
end)

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	keys.on_key(event_data:GetInt("Key"))
end)
-- A key's action, which a touchscreen's buttons press as well
keys.on_key = function(key)
	-- A form takes escape to close itself; what is left is this game's own
	-- While a line is being typed the keys are that line's, which is why
	-- this is before everything else
	if chat_input then
		if key == magic.KEY_RETURN or key == magic.KEY_KP_ENTER then
			send_chat()
		elseif key == BIND.menu.key then
			close_chat()
		end
		return
	end
	-- **A text field being typed in takes the keys** (user): a form's,
	-- such as a creative inventory's search, or a page's; Esc still closes
	-- what it is on
	local focus = magic.ui.focusElement
	if focus and focus:GetTypeName() == "LineEdit" and
			key ~= magic.KEY_ESCAPE then
		return
	end
	if luanti.key(key) then
		return
	end
	if key >= magic.KEY_1 and key <= magic.KEY_9 then
		-- A game with fewer slots than that has no slot for the key
		local i = key - magic.KEY_1 + 1
		if i <= ((luanti.hotbar and luanti.hotbar.count) or 8) then
			set_wield(i)
		end
	elseif key == BIND.chat.key then
		chat_wanted = true
	elseif key == BIND.mouse.key then
		-- Not under Alt: alt+tab delivers the Tab to the client before the
		-- window manager takes it, and the game freed its own mouse on
		-- every alt-tab out, so nothing wanted it back after ([FOCUS_LOG],
		-- the playtest of 2026-09-21 18:54)
		if not (magic.input:GetKeyDown(magic.KEY_LALT) or
				magic.input:GetKeyDown(magic.KEY_RALT) or load_wait) then
			set_mouse_in_world(not mouse_in_world, "the mouse key")
		end
	elseif key == BIND.drop.key then
		-- Luanti's own drop key: the whole stack, and one of it with the
		-- key that means "one" everywhere else here. The server takes it
		-- out of the inventory, so nothing is drawn until it says so.
		local one = magic.input:GetKeyDown(magic.KEY_LCTRL) or
				magic.input:GetKeyDown(magic.KEY_RCTRL)
		buildat.send_packet("main:drop", cereal.binary_output(
				{one and "1" or "0"}, {"array", "string"}))
		elseif key == BIND.inventory.key then
		-- Luanti's own inventory key, and what a game's inventory formspec
		-- is for. The same key closes it again. A game that sets no
		-- inventory formspec opens nothing, and the mouse stays in the
		-- world: nothing opened for it to point at.
		luanti.open_player_inventory()
	elseif key == BIND.fly.key then
		keys.toggle_mode("fly", "Fly mode")
	elseif key == BIND.fast.key then
		keys.toggle_mode("fast", "Fast mode")
	elseif key == BIND.noclip.key then
		keys.toggle_mode("noclip", "Noclip mode")
	elseif key == BIND.minimap.key then
		sky_now.minimap_mode = sky_now.minimap_mode % #sky_now.minimap.MODES + 1
		sky_now.apply_minimap_mode()
		luanti.chat_local(sky_now.minimap.MODES[sky_now.minimap_mode].label)
	elseif key == BIND.fog.key then
		-- Official's fog toggle (F3, [VIEW_KEYS]): the fog pushed past
		-- the far clip, and back to the sky's rule
		sky_now.fog_off = not sky_now.fog_off
		sky_now.apply_far(game_sky)
		luanti.chat_local(sky_now.fog_off and "Fog disabled" or "Fog enabled")
	elseif key == BIND.camera.key then
		-- Official's camera mode key ([THIRD_PERSON]): first person,
		-- third from behind, third from the front; a game's
		-- set_camera{mode = "first"} keeps it in first
		local allowed = luanti.camera().mode or "any"
		local modes = {"first", "third", "third_front"}
		local next_mode = WIELD.camera_mode % 3 + 1
		if allowed ~= "any" then
			for i, m in ipairs(modes) do
				if m == allowed then next_mode = i end
			end
		end
		WIELD.camera_mode = next_mode
		luanti.set_draw_self(next_mode ~= 1)
		-- **Deep, and drawn again on the way back** ([THIRD_PERSON_WIELD],
		-- 2026-10-03): a node's enabled does not reach its children, so
		-- turning off wield_node alone left the held block and the bare
		-- hand drawn at the screen's corner in third person. First person
		-- puts back exactly what the item in hand draws.
		if next_mode == 1 then
			draw_hotbar()
		else
			wield_node:SetDeepEnabled(false)
		end
		luanti.chat_local(({"First person view", "Third person view",
				"Third person view (front)"})[next_mode])
	elseif key == BIND.mute.key then
		-- Official's mute key ([BOX_FIXES] b)
		local mute, volume = buildat.get_sound()
		buildat.set_sound(not mute, volume)
		luanti.chat_local(mute and "Sound unmuted" or "Sound muted")
	elseif key == BIND.hud.key then
		hud_shown = not hud_shown
		draw_hud(hud_elements)
		-- The first-person item in the corner goes with the HUD
		-- ([HUD_HIDES_HAND]); the third-person item is the world's and
		-- stays. draw_hotbar() puts back exactly what is in hand, now that
		-- draw_wielded() reads hud_shown.
		draw_hotbar()
	elseif key == BIND.chatlog.key then
		chat_shown = not chat_shown
		draw_hud(hud_elements)
	elseif key == BIND.detail.key then
		-- Cycled rather than toggled, the way Luanti's own F5 is, and what a
		-- player coming from it expects: nothing, short, everything. See
		-- [STATUS_LEVELS].
		keys.set_detail((detail_level + 1) % 3)
		detail_timer = 1
		if detail_text.visible then
			-- In the log as well as on the screen, and the same string: a
			-- scripted comparison then reads text instead of reading a
			-- screenshot, which is the difference between a check that runs
			-- and a check somebody looks at
			-- Whole whatever the level is: this line exists for a scripted
			-- comparison rather than for the screen
			log:info(status_lines(2):gsub("\n", " | "))
		end
		place_chat()
	elseif key == BIND.menu.key then
		open_pause_menu()
	end
end

-- Where the player is, a few times a second: the server moves its own player
-- there, and a Luanti mod asking where the player is gets this.
local WHERE_INTERVAL = 0.2
local where_timer = 0

-- What the player is holding down, in Luanti's own bit order --
-- PlayerControl::getKeysPressed(), and CONTROL_BITS in
-- builtin/luanti/lua/entity.lua, which reads these back out: up, down, left,
-- right, jump, aux1, sneak, dig, place, zoom.
--
-- Nothing sent this before, so get_player_control() answered twelve falses
-- forever and every sprint mod, aux1 ability and sneak-dependent behaviour
-- saw a player standing perfectly still -- without erroring, which is the
-- worst shape a gap can have.
--
-- aux1 is the fast key: in Luanti that is the same key and the same
-- meaning, and it is what a sprint mod reads. zoom has no binding here and
-- is never set.
local CONTROL_KEYS = {"forward", "back", "left", "right", "jump", "fast",
		"sneak"}
local CONTROL_DIG = 128
local CONTROL_PLACE = 256

local function control_bits()
	-- Nothing is held while the mouse is on the screen: a form is open, a
	-- line is being typed, or Tab put it there, and the keys are that
	-- window's rather than the player's
	if not (mouse_in_world or keys.touch) or luanti.form_open() or
			chat_input ~= nil or load_wait then
		return 0
	end
	local bits = 0
	for i = 1, #CONTROL_KEYS do
		if key_down(CONTROL_KEYS[i]) then
			bits = bits + 2 ^ (i - 1)
		end
	end
	if keys.touch then
		if keys.touch.dig then
			bits = bits + CONTROL_DIG
		end
	else
		if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
			bits = bits + CONTROL_DIG
		end
		if magic.input:GetMouseButtonDown(magic.MOUSEB_RIGHT) then
			bits = bits + CONTROL_PLACE
		end
	end
	-- zoom, the tenth bit ([VIEW_KEYS]): official's Z, behind the zoom
	-- privilege, which the server hands out with the rest
	if key_down("zoom") and (luanti.physics().zoom_fov or 0) > 0 then
		bits = bits + 512 -- CONTROL_ZOOM, over the 200-local line
	end
	return bits
end

-- What went last, so that a key going down or up is sent on the frame it
-- happens rather than waiting out the heartbeat
local last_controls = -1

local function send_where()
	local p = {x = player.x, y = player.y, z = player.z}
	last_controls = control_bits()
	-- Luanti measures the horizontal angle counter-clockwise from +Z, so it
	-- turns towards -X where Urho's yaw turns towards +X; its vertical one
	-- is positive downwards, which is what Urho's pitch already is. See
	-- lua_api.md, get_look_horizontal and get_look_vertical.
	-- Stamped with the client's clock ([NET_SIM]): the server reads how
	-- long the update waited behind whatever was on the wire, as the
	-- excess over the fastest one it saw, and logs the worst per five
	-- seconds -- the number the channels attack
	buildat.send_packet("main:where", cereal.binary_output({
		x = p.x, y = p.y, z = p.z,
		look_h = math.rad(-yaw),
		look_v = math.rad(pitch),
		controls = last_controls,
		sent_us = buildat.get_time_us(),
	}, {"object",
		{"x", "double"},
		{"y", "double"},
		{"z", "double"},
		{"look_h", "double"},
		{"look_v", "double"},
		{"controls", "int32_t"},
		{"sent_us", "double"},
	}))
end

-- The frame, as a function of its own so the handler under it can time
-- it whichever of the returns it leaves by
function frame_peak.update(dt)
	local t0 = buildat.get_time_us()
	voxel_shading.update(dt)
	frame_peak.skyvis_us = buildat.get_time_us() - t0
	update_sky(dt)
	-- The exposure reset's rate goes back once its frame has rendered
	if AUTO_EXPOSURE.reset_frames > 0 then
		AUTO_EXPOSURE.reset_frames = AUTO_EXPOSURE.reset_frames - 1
		if AUTO_EXPOSURE.reset_frames == 0 then
			local vp = magic.renderer:GetViewport(0)
			if vp and vp.renderPath then
				vp.renderPath:SetShaderParameter("AutoExposureAdaptRate",
						AUTO_EXPOSURE.adapt_rate)
			end
		end
	end

	if player_placed then
		where_timer = where_timer + dt
		-- simplified: the keys are sampled, so a tap that begins and ends
		-- between two of these is not seen. Sending on change narrows that
		-- to the server's own 0.2 s coalescing of where packets, which is
		-- what would have to go next if a tap ever has to count.
		if where_timer >= WHERE_INTERVAL or control_bits() ~= last_controls then
			where_timer = 0
			send_where()
		end
	end

	pointed_p, pointed_above, pointed_boxes = find_pointed_voxel()
	-- A body that came off the world, when the ray reaches it first
	-- ([BODY_INTERACT]): its voxel's region position stands in for the
	-- map's, and the dig and the place below send it as they send any
	do
		local eye = camera_node.worldPosition
		local dir = keys.point_dir()
		local reach = pointed_p and (buildat.Vector3(eye.x, eye.y, eye.z) -
				pointed_p):length() or
				math.min(POINT_RANGE, luanti.dig_range(wield_index))
		local bp, babove = luanti.pointed_body(eye.x, eye.y, eye.z,
				dir.x, dir.y, dir.z, reach)
		if bp then
			pointed_p, pointed_above, pointed_boxes = bp, babove, nil
		end
	end
	-- An object nearer than the node is what is pointed at, and the frame
	-- goes around its selection box
	do
		local eye = camera_node.worldPosition
		local dir = keys.point_dir()
		local reach = math.min(POINT_RANGE, luanti.dig_range(wield_index))
		local id, distance = luanti.pointed_object(eye.x, eye.y, eye.z,
				dir.x, dir.y, dir.z, reach)
		pointed_obj = id and (pointed_p == nil or distance <
				(buildat.Vector3(eye.x, eye.y, eye.z) - pointed_p):length()) and
				id or nil
	end
	-- A finger's place, at what this frame points at: a tap's begin and
	-- end can come in one frame, before the ray went through it
	if keys.touch_place then
		keys.touch_place = nil
		keys.place_now()
	end
	local lo, hi = nil, nil
	if pointed_obj then
		lo, hi = luanti.object_box(pointed_obj)
	end
	if lo then
		local x, y, z = (hi[1] - lo[1]) / 2, (hi[2] - lo[2]) / 2, (hi[3] - lo[3]) / 2
		pointed_node.position = magic.Vector3(lo[1] + x, lo[2] + y, lo[3] + z)
		frame_boxes({{-x, -y, -z, x, y, z}})
		pointed_node.enabled = true
	elseif pointed_p then
		pointed_node.position = magic.Vector3.from_buildat(
				luanti.body_world(pointed_p) or pointed_p)
		frame_boxes(pointed_boxes or {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}})
		pointed_node.enabled = true
	else
		pointed_node.enabled = false
	end

	update_detail(dt)
	luanti.update_tooltip(dt)
	luanti.update_sounds(dt)
	luanti.update_particles(dt, magic.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z))
	luanti.update_lights(dt, magic.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z))

	-- Until the server has said where the player is there is no player:
	-- what is on the screen is the overview the camera started at
	if not player_placed then
		return
	end

	if chat_wanted then
		chat_wanted = false
		open_chat()
	end

	-- The mouse turns the head while it is in the world; while it is on the
	-- screen -- a form is open, a line is being typed, or Tab put it there
	-- -- it is the pointer
	-- -- it is the pointer. A touchscreen has no pointer to put anywhere:
	-- a finger turns the head (luanti/touch.lua), in degrees
	local playing = (mouse_in_world or keys.touch) and
			not luanti.form_open() and chat_input == nil and not load_wait
	if playing then
		local dmouse = keys.mouse_held() and magic.input:GetMouseMove() or
				{x = 0, y = 0}
		if keys.touch then
			dmouse = {x = 0, y = 0}
			yaw, pitch = yaw + keys.touch.yaw, pitch + keys.touch.pitch
			keys.touch.yaw, keys.touch.pitch = 0, 0
		end
		yaw = yaw + dmouse.x * MOUSE_SENSITIVITY
		pitch = pitch + dmouse.y * MOUSE_SENSITIVITY
		if pitch > 89 then pitch = 89 end
		if pitch < -89 then pitch = -89 end
	end

	-- What the keys ask for, in world coordinates: a direction of any
	-- length, which player.lua turns into a speed
	local wish = {x = 0, z = 0}
	if playing then
		local yr = math.rad(yaw)
		local fx, fz = math.sin(yr), math.cos(yr)
		local function walk(x, z)
			wish.x = wish.x + x
			wish.z = wish.z + z
		end
		local stick = keys.touch and keys.touch.stick
		if stick and (stick.x ~= 0 or stick.y ~= 0) then
			-- Luanti's analog stick: its direction, and its length
			-- (0..1) the speed
			walk(-stick.y * fx + stick.x * fz, -stick.y * fz - stick.x * fx)
			wish.speed = math.sqrt(stick.x * stick.x + stick.y * stick.y)
		else
			if key_down("forward") then walk(fx, fz) end
			if key_down("back") then walk(-fx, -fz) end
			if key_down("right") then walk(fz, -fx) end
			if key_down("left") then walk(-fz, fx) end
		end
		wish.jump = key_down("jump")
		wish.sneak = key_down("sneak")
		-- The modes as official's LocalPlayer has them ([FLY_MODES]):
		-- each acts only with its privilege -- the mode stays "enabled"
		-- and does nothing, so a revoked fly is a fall -- and fast is
		-- the special key on the ground and always while flying
		-- (always_fly_fast)
		local privs = luanti.privs
		player.fly_active = player.fly and privs.fly == true
		player.noclip_active = player.noclip and privs.noclip == true
		wish.fast = player.fast and privs.fast == true and
				(key_down("aux1") or player.fly_active)
	end

	update_dig(dt, playing)

	player:update(dt, wish)

	-- A landing hard enough to hurt, told to the server, which is the end
	-- that decides what it costs. Luanti's own client does the same -- it
	-- computes the damage and sends that -- and this sends the speed
	-- instead, so that the arithmetic and the bounds are the server's.
	if player.landed_at then
		local speed = player.landed_at
		player.landed_at = nil
		if speed > FALL_TOLERANCE then
			buildat.send_packet("main:fell", cereal.binary_output(
					{speed = speed}, {"object", {"speed", "double"}}))
		end
	end

	camera_node.position = magic.Vector3(player.x + eye_offset.x,
			player.y + player_physics.EYE_HEIGHT + eye_offset.y,
			player.z + eye_offset.z)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	-- **Footsteps** ([NO_SOUND]): the module knows what each node sounds
	-- like underfoot and how far a stride is; this says where the foot
	-- is and what it is on, which is what official Luanti's engine reads
	-- off the player for itself
	if player.on_ground and luanti.footstep then
		local sx = math.sqrt(player.vx * player.vx + player.vz * player.vz)
		if sx > 1 then
			-- The node under the feet, rounded the way Luanti rounds a
			-- position to a node
			local fx = math.floor(player.x + 0.5)
			local fy = math.floor(player.y - 0.5)
			local fz = math.floor(player.z + 0.5)
			luanti.footstep(node_name_at({x = fx, y = fy, z = fz}),
					player.x, player.y, player.z)
		end
	end
	if WIELD.motion then
		-- The swing's phase: official's camera advances it at 3.5 swings a
		-- second while the dig button is held, at a node or at nothing
		-- (Camera::step, m_digging_anim), whatever the dig takes -- one
		-- swing per dig was a stone by hand swung once in seconds (user)
		-- -- and a swing started is finished after the button lets go. As
		-- it crosses 0.15 the dig and use sounds play
		-- (SoundMaker::cameraPunchLeft; [DIG_SWING_SOUND]).
		local was = WIELD.dig_phase or 0
		local digging_now = WIELD.holding or was > 0
		if digging_now then
			local now = was + dt * 3.5
			if was < 0.15 and now >= 0.15 then
				local diggable = dig ~= nil and dig.time ~= nil and not dig.done
				local held = parse_stack(hotbar_stacks[wield_index])
				local d, u = luanti.swing_sound(diggable and dig.name or nil,
						diggable and dig.group or nil, held and held.name or "",
						pointed_p ~= nil or pointed_obj ~= nil,
						player.x, player.y, player.z)
				log:debug(string.format("swing: at %.2f, dig %s, use %s", now,
						tostring(d), tostring(u)))
			end
			WIELD.dig_phase = now >= 1 and 0 or now
		else
			WIELD.dig_phase = 0
		end
		local speed_xz = math.sqrt(player.vx * player.vx + player.vz * player.vz)
		local flying = player.fly_active or player.fly
		local m = WIELD.motion:update(dt, {
			walking = speed_xz > 1 and player.on_ground,
			swimming = player.in_liquid and (speed_xz > 1 or math.abs(player.vy) > 1),
			climbing = player.climbing and math.abs(player.vy) > 1,
			flying = flying,
			speed = math.sqrt(speed_xz * speed_xz + player.vy * player.vy),
			digging = digging_now,
			dig_anim = WIELD.dig_phase,
			wield_changed = WIELD.last_wield_index ~= nil and
					WIELD.last_wield_index ~= wield_index,
		})
		WIELD.last_wield_index = wield_index
		if WIELD.motion.state == 1 and not WIELD.bob_said then
			WIELD.bob_said = true
			log:info(string.format("view bobbing: started at %.1f nodes/s, amount %g",
					speed_xz, WIELD.motion.amount))
		end
		if m.roll ~= 0 or m.offset[1] ~= 0 or m.offset[2] ~= 0 then
			camera_node.rotation = magic.Quaternion(pitch, yaw, m.roll)
			-- Sideways along the camera's right (the yaw turned a quarter),
			-- and straight up: official adds its bobvec before the pitch
			local ry = math.rad(yaw)
			camera_node.position = magic.Vector3(
					player.x + eye_offset.x + m.offset[1] * math.cos(ry),
					player.y + player_physics.EYE_HEIGHT + eye_offset.y + m.offset[2],
					player.z + eye_offset.z - m.offset[1] * math.sin(ry))
		end
		-- The hand's offset in the wield node's own scale: official's
		-- units are the node's tenth, and the node is a twenty-sixth
		local b = WIELD.base
		if b then
			wield_node.position = magic.Vector3(b.x + m.hand[1] / WIELD.shrink,
					b.y + m.hand[2] / WIELD.shrink, b.z + m.hand[3] / WIELD.shrink)
		end
	end
	-- Zoom while Z is held ([VIEW_KEYS]): the player's zoom_fov property
	-- when a game set one (official's: 0 off, 15 in creative), back on
	-- release
	if camera then
		local zoom_fov = luanti.physics().zoom_fov or 0
		local zooming = key_down("zoom") and zoom_fov > 0 and
				mouse_in_world and not luanti.form_open()
		if zooming ~= WIELD.zooming then
			WIELD.zooming = zooming
			local c = luanti.camera()
			local base = (c.fov and c.fov > 0) and
					(c.is_multiplier and (CAMERA_FOV * c.fov) or c.fov) or CAMERA_FOV
			keys.fov_want = zooming and zoom_fov or base
			camera.fov = magic.fov_for(keys.fov_want)
			WIELD.place(camera.fov)
		end
		-- And when the screen turns
		local fov = magic.fov_for(keys.fov_want or CAMERA_FOV)
		if math.abs(camera.fov - fov) > 0.01 then
			camera.fov = fov
			WIELD.place(fov)
		end
	end
	if WIELD.camera_mode ~= 1 then
		-- The own model at the player's own feet, turned with the look
		-- ([BOX_PLAYTEST_4] 4, 5): the server's echo is a round trip old
		-- and its yaw is never the local player's
		luanti.set_self_pose(player.x, player.y, player.z, yaw)
		-- Third person, official's Camera::update: back along the look
		-- (or ahead of it, turned round) up to 2.75 nodes, a fifth up,
		-- the height following the look past 1.2 nodes, and half a node
		-- short of any walkable node on the way so the camera never sits
		-- inside a wall
		local eye = camera_node.position
		local ry, rp = math.rad(yaw), math.rad(pitch)
		local dx = math.sin(ry) * math.cos(rp)
		local dy = -math.sin(rp)
		local dz = math.cos(ry) * math.cos(rp)
		if WIELD.camera_mode == 3 then
			dx, dy, dz = -dx, -dy, -dz
		end
		local cx, cy, cz = eye.x, eye.y + 0.2, eye.z
		for i = 10, 27 do
			local t = i / 10
			cx = eye.x - dx * t
			cz = eye.z - dz * t
			if i > 12 then
				cy = eye.y - dy * t
			end
			if node_stops(math.floor(cx + 0.5), math.floor(cy + 0.5),
					math.floor(cz + 0.5)) then
				cx, cy, cz = cx + dx * 0.5, cy + dy * 0.5, cz + dz * 0.5
				break
			end
		end
		-- Over the shoulder, when the player asked for it
		-- ([OVER_SHOULDER]): the eye a little to the right and up, the
		-- camera still looking along the player's own look, so the
		-- crosshair stays the pointing ray's -- the ray itself leaves
		-- the player's eye and does not move. The back view only: in
		-- front the model is what is being looked at.
		if WIELD.shoulder and WIELD.camera_mode == 2 then
			local rr = math.rad(yaw + 90)
			cx = cx + math.sin(rr) * 0.4
			cz = cz + math.cos(rr) * 0.4
			cy = cy + 0.15
		end
		camera_node.position = magic.Vector3(cx, cy, cz)
		if WIELD.camera_mode == 3 then
			camera_node.rotation = magic.Quaternion(-pitch, yaw + 180, 0)
		end
	end
	hud_r:update(dt)
	update_underwater(buildat.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z))
end
magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	-- Out of the packet handler that asked for it: a leave and a connect
	-- inside the old connection's packet loop left the new one silent.
	-- Nothing after it: the game's UI is gone with the leave
	if keys.rejoin_due then
		keys.rejoin_due = nil
		keys.rejoin()
		return
	end
	frame_peak.note(dt)
	local t0 = buildat.get_time_us()
	frame_peak.update(dt)
	-- The script's own share: the handler less the two phases timed inside
	frame_peak.script_us = buildat.get_time_us() - t0 -
			frame_peak.skyvis_us - sky_cube.us
end)

-- The settings, for the key rows in them ([KEY_BINDINGS]); the same
-- packet answers the pause menu's editor after a save
-- **The viewing range** (user, 2026-09-30): the server's view_range is
-- the most anyone gets; within it the player's own, kept on this client
-- for this server (the pause menu's View range), or else the web client's
-- default, which is lower since a browser meshes on one thread: the
-- server's web_view_range, else 80, 60 on a touchscreen. On keys: this
-- file is at Lua's 200 locals.
keys.view = {ceiling = 120}
function keys.view.default()
	local v = keys.view
	if buildat.get_env("BUILDAT_PAGE_HTTPS") == nil then
		return v.ceiling
	end
	local web = v.web or (buildat.get_env("BUILDAT_TOUCH") == "1" and 60 or 80)
	return math.min(v.ceiling, web)
end
function keys.view.current()
	local chosen = tonumber(buildat.storage_read("view_range") or "")
	return chosen and math.min(chosen, keys.view.ceiling) or keys.view.default()
end
-- The player's choice, or nil for the default
function keys.view.choose(n)
	buildat.storage_write("view_range", n and tostring(n) or "")
	sky_now.set_range(keys.view.current())
end
-- From the start, before the server's settings come: a browser does not
-- first ask for the whole of the native default
sky_now.set_range(keys.view.current())

-- **The player's own view settings** ([VANILLA_PLAYER_SETTINGS], user
-- 2026-10-11: a player on somebody's server could not change them): the
-- game settings window's View section, kept on this client for this
-- server as the view range is, each as "view_<row's name>". One set wins
-- over the server's row of the same name, which stays the default. The
-- render mode is read at join (luanti/module.lua's get_world_info).
-- **On the client's own local server they are settings.json's**
-- ([VIEW_SETTINGS_LOCAL]): the launcher's "Luanti settings" and these
-- show and set the same values, the server's whole list sent back with
-- the row changed.
keys.view_rows = {render_mode = "pbr", lod_detail = "full",
		view_bobbing_amount = "1", third_person_shoulder = "0"}
-- What can be applied without a rejoin, at once
keys.apply_view = function(row)
	local lod = row:match("^lod_detail=(%a+)$")
	if lod then
		sky_now.set_lod_detail(lod)
	end
	local bob = row:match("^view_bobbing_amount=([%d.]+)$")
	if bob and WIELD.motion then
		WIELD.motion.amount = tonumber(bob) or 1
	end
	-- The back view centred or over the shoulder ([OVER_SHOULDER])
	local shoulder = row:match("^third_person_shoulder=([01])$")
	if shoulder then
		WIELD.shoulder = shoulder == "1"
	end
end
keys.set_view = function(name, value)
	if keys.view_local then
		local list = {}
		for _, row in ipairs(keys.settings or {}) do
			if not row:match("^" .. name .. "=") then
				list[#list + 1] = row
			end
		end
		list[#list + 1] = name .. "=" .. value
		keys.settings = list
		buildat.send_packet("main:set_settings",
				cereal.binary_output(list, {"array", "string"}))
	else
		buildat.storage_write("view_" .. name, value)
	end
	keys.view_rows[name] = value
	keys.apply_view(name .. "=" .. value)
	log:info("view: " .. name .. " = " .. value)
end

keys.rejoin = function(later)
	local why = keys.rejoin_why
	if not later then
		keys.rejoin_why = nil
	end
	local ok, err = buildat.rejoin(why, keys.world, later)
	log:info("view: rejoin: " .. tostring(ok) .. " " .. tostring(err))
end

buildat.sub_packet("main:settings", function(data)
	local list = keys.own_rows(cereal.binary_input(data, {"array", "string"}))
	keys.view_local = buildat.connected_locally and buildat.connected_locally()
	for i, row in ipairs(list) do
		local name = row:match("^([%w_]+)=")
		if name and keys.view_rows[name] then
			local own = not keys.view_local and
					buildat.storage_read("view_" .. name) or ""
			if own ~= "" then
				list[i] = name .. "=" .. own
			end
			keys.view_rows[name] = list[i]:match("=(.*)$")
		end
	end
	local v = keys.view_rows
	log:info(string.format("view settings: render %s, distant %s, " ..
			"bobbing %s, shoulder %s", v.render_mode, v.lod_detail,
			v.view_bobbing_amount, v.third_person_shoulder))
	keys.apply(list)
	keys.view.web = nil
	for _, row in ipairs(list) do
		local w = row:match("^web_view_range=(%d+)$")
		if w then
			keys.view.web = tonumber(w)
		end
	end
	for _, row in ipairs(list) do
		local n = row:match("^view_range=(%d+)$")
		if n then
			keys.view.ceiling = tonumber(n)
			sky_now.set_range(keys.view.current())
		end
		keys.apply_view(row)
	end
	if keys.rejoin_why then
		keys.rejoin_due = true
	end
end)

keys.settings_sections = {{title = "View", draw = function(_, ui)
	local v = keys.view_rows
	-- Fixed for a session: a new one is a rejoin
	ui.dropdown("Render mode", {{"PBR", "pbr"},
			{"Shadows", "shadows"}, {"Unlit", "unlit"}}, v.render_mode,
			function(m)
		if m == v.render_mode then
			return
		end
		keys.set_view("render_mode", m)
		keys.rejoin_why = "Rejoining for the render mode " .. m .. "..."
		-- A local server's write is in once its list comes back: armed
		-- now, on the click, and run by the main:settings handler
		keys.rejoin(keys.view_local)
	end)
	ui.dropdown("Distant terrain detail", {{"Full", "full"},
			{"Reduced past half range", "half"},
			{"Reduced past a third", "third"}}, v.lod_detail,
			function(d) keys.set_view("lod_detail", d) end)
	ui.toggle("View bobbing", v.view_bobbing_amount ~= "0", function(on)
		keys.set_view("view_bobbing_amount", on and "1" or "0")
	end)
	ui.toggle("Over the shoulder", v.third_person_shoulder == "1",
			function(on)
		keys.set_view("third_person_shoulder", on and "1" or "0")
	end)
	ui.dropdown("Debug info (F5)", {{"Off", "0"}, {"Basic", "1"},
			{"Full", "2"}}, tostring(detail_level), function(l)
		keys.set_detail(tonumber(l))
	end)
end}}
-- A window that changed size -- fullscreen toggled, the window dragged --
-- leaves the screen-sized containers the wrong size, and what is centred or
-- bottom-aligned inside them lands wherever that size says. Both are put
-- right here and the hotbar drawn again, rather than at the next slot the
-- player picks ([HOTBAR_LAYERS]). A new UI scale is a new root size with
-- no ScreenMode (a phone's join fitting the scale down: the hotbar halfway
-- up, [WEB_QUARTER_VIEW]), so the root's size is what is watched.
-- The HUD's elements are placed against the screen and at the hotbar's
-- scale, which the width and the game's slot count change
-- ([HUD_DENSITY]), so the HUD is drawn again too.
local laid_out_w, laid_out_h, laid_out_scale = nil, nil, nil
magic.SubscribeToEvent("Update", function()
	local w, h = magic.ui.root.width, magic.ui.root.height
	local scale = hud_scale()
	if w == laid_out_w and h == laid_out_h and scale == laid_out_scale then
		return
	end
	laid_out_w, laid_out_h, laid_out_scale = w, h, scale
	if hotbar_ui then
		hotbar_ui:relayout()
	end
	hud_r.root.size = magic.IntVector2(w, h)
	draw_hud(hud_elements)
end)

-- **Touch controls** on a touchscreen (luanti/touch.lua, luanti_client's
-- res/touch.lua); nil elsewhere, and then the mouse is what it always was
if buildat.get_env("BUILDAT_TOUCH") == "1" then
	keys.touch = (function(ok, err, m)
		if not ok or type(m) ~= "function" then
			error("vanilla: could not load touch.lua: " .. tostring(err))
		end
		return m
	end)(buildat.run_script_file("luanti/touch.lua"))({
		on_key = keys.on_key,
		BIND = BIND,
		pause = open_pause_menu,
		place = function() keys.touch_place = true end,
		set_wield = set_wield,
		inventory = function() keys.on_key(BIND.inventory.key) end,
		chat = function() keys.open_chat() end,
		hotbar = function()
			local _, _, slot, margin = hotbar_metrics()
			return (luanti.hotbar and luanti.hotbar.count) or 8, slot, margin
		end,
		form_open = luanti.form_open,
		-- The finger as the mouse's left button on a form: the press
		-- picks up, the moves carry (and drag a scrollbar's thumb), the
		-- lift puts down, a second finger's tap is a right click
		form_press = function(x, y)
			luanti.hover(x, y, true)
			luanti.click(x, y, "left")
		end,
		form_move = function(x, y) luanti.hover(x, y, true) end,
		form_release = function(x, y)
			luanti.hover(x, y, false)
			luanti.release("left")
		end,
		form_right = function(x, y) luanti.click(x, y, "right") end,
		-- The wielded item's touch_interaction for what is pointed at
		short_dig = function()
			local held = parse_stack(hotbar_stacks[wield_index])
			return luanti.short_dig(held and held.name or "",
					pointed_obj and "object" or pointed_p and "node" or
					"nothing")
		end,
	})
	-- Luanti's touch_interaction_style: tap (at the finger) unless the
	-- player chose the crosshair
	keys.touch_crosshair = buildat.storage_read("touch_crosshair") == "1"
	-- Luanti's touchscreen_sensitivity ([TOUCH_LOOK_SETTING]).
	-- simplified: steps in a dropdown, as every other row, not a slider
	keys.touch.sensitivity =
			tonumber(buildat.storage_read("touch_sensitivity") or "") or 0.2
	local SENSITIVITIES = {0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1}
	keys.settings_sections[#keys.settings_sections + 1] = {title = "Touch",
			draw = function(_, ui)
		ui.toggle("Interaction at the crosshair", keys.touch_crosshair,
				function(on)
			keys.touch_crosshair = on
			buildat.storage_write("touch_crosshair", on and "1" or "")
		end)
		local list = {}
		for i, v in ipairs(SENSITIVITIES) do
			list[i] = {tostring(v), v}
		end
		ui.dropdown("Look sensitivity", list, keys.touch.sensitivity,
				function(v)
			keys.touch.sensitivity = v
			buildat.storage_write("touch_sensitivity", tostring(v))
			log:info("touch look sensitivity " .. v)
		end)
	end}
	-- And Luanti's Android autojump: a node's step is walked up without
	-- the Jump button
	player.autojump = true
	log:info("touch controls on, look sensitivity " .. keys.touch.sensitivity)
end

buildat.send_packet("main:get_settings", "")
log:info("vanilla client ready")
-- vim: set noet ts=4 sw=4:
