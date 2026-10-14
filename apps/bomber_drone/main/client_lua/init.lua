-- Buildat: bomber_drone/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("bomber_drone")
local dump = buildat.dump
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")

-- Fog hides the streaming edge (section = 64 voxels, load radius 5).
local RENDER_DISTANCE = 280
local FOG_END = RENDER_DISTANCE * 1.15

voxelworld.use_skylight = true
-- Nothing here is simulated by Bullet, so no collision shapes are needed;
-- terrain hits are read from the voxel volumes instead
voxelworld.physics_distance = 0

-- Lighting as in apps/infidigger: a PBR voxel material lit in HDR and
-- tonemapped, so the sun can be brighter than white without the frame clipping
local SKY_AMBIENT = magic.Color(0.26, 0.33, 0.46)
local SUN_BRIGHTNESS = 50.0
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.8}
local EXPOSURE_BIAS = 1.6

-- Flight model. One unit is one voxel; angles are degrees.
-- Motor on accelerates at a constant rate up to MOTOR_SPEED. STALL_SPEED^2 /
-- (2 * MOTOR_ACCEL) = 8 voxels of runway from a standstill to flying speed.
local STALL_SPEED = 6
local MOTOR_SPEED = 13
-- STALL_SPEED^2 / (2 * MOTOR_ACCEL) = 8 voxels of runway
local MOTOR_ACCEL = 2.25
local IDLE_DECEL = 1.0
-- Climbing trades speed for height and diving gives it back
local GRAVITY_EXCHANGE = 6
-- How fast it falls out of the sky with no flying speed left
local SINK_RATE = 4
-- Rolling on the ground with the motor off comes to a stop
local GROUND_BRAKE = 4

-- The runway is 32 voxels; takeoff has to fit in a fraction of it
assert(math.abs(STALL_SPEED^2 / (2 * MOTOR_ACCEL) - 8) < 0.5)

local PITCH_RATE = 55
local ROLL_RATE = 110
-- Aerodynamic stability: how fast the attitude returns to level flight with no
-- input. Roll returns slower than pitch, and both are mushy under stall speed.
local PITCH_LEVEL_K = 0.2
local ROLL_LEVEL_K = 0.2
-- Under stall speed the nose drops instead of leveling
local STALL_PITCH_DOWN = 25
-- Degrees per second of yaw at full 90-degree bank
local YAW_PER_ROLL = 25

local BOMB_GRAVITY = 20
local BOMB_DRAG = 0.15
local BOMB_EJECT_SPEED = 4
local BOMB_MAX_AGE = 30
-- Voxels a bomb may cover between two collision tests. A bomb reaches some
-- 25 voxels a second, so at a low frame rate one step of a whole frame would
-- pass clean through the ground it should hit.
local BOMB_MAX_STEP = 0.4
-- Enough for a frame of any length worth simulating
local BOMB_MAX_STEPS = 200

local CHASE_DIST = 14
local CHASE_UP = 7
-- Aimed this far below the drone, so the frame carries the terrain under it
-- and a bomb can be watched down to the ground
local CHASE_AIM_DOWN = 9
local CHASE_MIN_ALT = 6
local CHASE_LAG = 4

local KEY_MOTOR = magic.KEY_M

local scene = replicate.main_scene

local spawn_received = false
local spawn_p = nil

-- The node's own rotation is the attitude. Control and trim are rotations
-- about the drone's own axes, so that pitch pulls towards wherever its own
-- roof is pointing rather than towards the sky; euler angles of our own
-- cannot express that, and would fold at +-90 degrees of pitch besides.
local speed = 0
-- Which way the drone is going, level, for the chase camera. Kept rather
-- than derived every frame because it is meaningless while the nose points
-- straight up or down.
local heading = magic.Vector3(1, 0, 0)
local motor_on = false
local on_ground = true
-- The client only knows the terrain once its chunks arrive; until then the
-- drone waits on the runway instead of gliding off through nothing
local terrain_seen = false

-- Set up zone (global visual parameters)
do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-100000, 100000)
	zone.ambientColor = SKY_AMBIENT
	zone.fogColor = magic.Color(0.60, 0.72, 0.88)
	zone.fogStart = FOG_END * 0.6
	zone.fogEnd = FOG_END
	zone.priority = -1
	zone.override = true
	-- What the voxel shader reflects; see builtin/voxel_shading
	zone.zoneTexture = magic.cache:GetResource("TextureCube",
			voxel_shading.sky_cubemap)
end

do
	local node = scene:CreateChild("DirectionalLight")
	node.direction = magic.Vector3(SUN_DIR.x, SUN_DIR.y, SUN_DIR.z)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.brightness = SUN_BRIGHTNESS
	light.color = magic.Color(1.0, 0.96, 0.88)
end

voxel_shading.create_skybox(scene, SUN_DIR)

local function matte_material(r, g, b)
	local m = magic.Material.new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/PBR/PBRNoTexture.xml"))
	m:SetShaderParameter("MatDiffColor", magic.Color(r, g, b))
	m:SetShaderParameter("Roughness", 0.85)
	m:SetShaderParameter("Metallic", 0.1)
	return m
end

-- A Material made here is kept alive only by the components that use it:
-- Urho3D's Lua binding hands out the object without holding a reference of
-- its own. One shared between nodes that all get removed again -- every bomb
-- so far -- is freed the moment the last of them goes, and this side is left
-- with a dangling handle. The drone's parts live as long as the session, so
-- they can share one; a bomb gets its own.
local drone_material = matte_material(0.05, 0.055, 0.045)

-- The drone: cuboids only, no propeller, wingspan 4 voxels
local drone_node = scene:CreateChild("Drone")
do
	local box_model = magic.cache:GetResource("Model", "Models/Box.mdl")
	local function cuboid(px, py, pz, sx, sy, sz)
		local n = drone_node:CreateChild("part")
		n.position = magic.Vector3(px, py, pz)
		n.scale = magic.Vector3(sx, sy, sz)
		local sm = n:CreateComponent("StaticModel")
		sm.model = box_model
		sm.material = drone_material
		sm.castShadows = true
	end
	-- Forward is +Z
	cuboid(0, 0, 0, 0.5, 0.5, 3.0)        -- fuselage
	cuboid(0, 0.05, 1.7, 0.35, 0.35, 0.6) -- nose
	cuboid(0, 0.15, 0.1, 4.0, 0.15, 0.8)  -- wing (4 voxels of span)
	cuboid(0, 0, -1.4, 1.4, 0.12, 0.5)    -- tailplane
	cuboid(0, 0.45, -1.4, 0.12, 0.7, 0.5) -- fin
	cuboid(0, -0.3, 0.2, 0.3, 0.2, 1.2)   -- belly pylon
end

-- Where a bomb comes off. Read as a node rather than computed, so the drop
-- point and direction are the drone's own coordinate space at any attitude.
local bomb_mount = drone_node:CreateChild("BombMount")
bomb_mount.position = magic.Vector3(0, -0.6, 0.2)

-- The drone's own axes in world space. The sandbox has no quaternion times
-- vector, but a child node's world position is that same rotation applied,
-- which is all these are.
local axis_right = drone_node:CreateChild("AxisRight")
axis_right.position = magic.Vector3(1, 0, 0)
local axis_up = drone_node:CreateChild("AxisUp")
axis_up.position = magic.Vector3(0, 1, 0)

local function body_axis(node)
	return (node:GetWorldPosition() -
			drone_node:GetWorldPosition()):Normalized()
end

local function drone_down()
	return (bomb_mount:GetWorldPosition() -
			drone_node:GetWorldPosition()):Normalized()
end

local function make_camera(name, parent)
	local node = parent:CreateChild(name)
	local camera = node:CreateComponent("Camera")
	camera.nearClip = 0.15
	camera.farClip = RENDER_DISTANCE
	-- Of the screen's short side, a portrait one's width
	magic.keep_fov(camera, 90)
	return node, camera
end

-- Right: fixed to the drone's nose, so it moves with every axis
local nose_camera_node, nose_camera = make_camera("NoseCamera", drone_node)
nose_camera_node.position = magic.Vector3(0, 0.2, 1.9)

-- Left: a gimbal on an imaginary aircraft flying ahead of the drone
local chase_camera_node, chase_camera = make_camera("ChaseCamera", scene)

local viewports = {}
local viewport_w, viewport_h = nil, nil

-- Half the window each. Called again whenever the window size changes; a
-- Viewport rect is in backbuffer pixels and does not follow it by itself.
local function layout_viewports()
	local w = magic.graphics.width
	local h = magic.graphics.height
	if w == viewport_w and h == viewport_h then
		return
	end
	viewport_w, viewport_h = w, h
	local half = math.floor(w / 2)
	viewports[1]:SetRect(magic.IntRect(0, 0, half, h))
	viewports[2]:SetRect(magic.IntRect(half, 0, w, h))
	-- Declarative: this is what is on the screen now, at whatever the user's
	-- render scale is. The rects are read again here, so a new layout has to
	-- say so rather than being noticed
	magic.set_preferred_viewports(viewports)
end

do
	local function add_viewport(index, camera)
		local viewport = magic.Viewport:new(scene, camera)
		viewports[index + 1] = viewport
		local rp = viewport.renderPath:Clone()
		rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/BloomHDR.xml"))
		rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/Tonemap.xml"))
		rp:Append(magic.cache:GetResource("XMLFile",
				"PostProcess/GammaCorrection.xml"))
		rp:SetEnabled("TonemapReinhardEq3", false)
		rp:SetEnabled("TonemapUncharted2", true)
		rp:SetShaderParameter("TonemapExposureBias", EXPOSURE_BIAS)
		viewport.renderPath = rp
	end
	magic.renderer.HDRRendering = true
	add_viewport(0, chase_camera)
	add_viewport(1, nose_camera)
	-- Puts both on the screen, since it is what sets their rects
	layout_viewports()
end

-- The nose camera is the drone's own point of view; stream and shade for it
voxelworld.set_camera(nose_camera_node)
voxel_shading.set_camera(nose_camera_node)

local title_text = magic.ui.root:CreateChild("Text")
local misc_text = magic.ui.root:CreateChild("Text")
local worldgen_text = magic.ui.root:CreateChild("Text")
local wait_text = magic.ui.root:CreateChild("Text")
do
	local function setup(text, y, size)
		text:SetFont(magic.cache:GetResource("Font", buildat.font_mono),
				size or 15)
		text.horizontalAlignment = magic.HA_CENTER
		text.verticalAlignment = magic.VA_TOP
		text:SetPosition(0, y)
	end
	title_text:SetText("bomber_drone: M motor, WASD fly (S nose up), "..
			"Space drop bomb")
	setup(title_text, 20)
	misc_text:SetText("")
	setup(misc_text, 40)
	worldgen_text:SetText("")
	setup(worldgen_text, 60)
	wait_text:SetText("Generating terrain...")
	wait_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 24)
	wait_text.horizontalAlignment = magic.HA_CENTER
	wait_text.verticalAlignment = magic.VA_CENTER
	wait_text:SetPosition(0, 0)
end

local function set_generating_status(queue_size)
	if spawn_received then
		wait_text:SetText("")
		if queue_size and queue_size > 0 then
			worldgen_text:SetText("Worldgen queue size: "..queue_size)
		else
			worldgen_text:SetText("")
		end
		return
	end
	if queue_size and queue_size > 0 then
		wait_text:SetText("Generating terrain... ("..queue_size..
				" sections left)")
	else
		wait_text:SetText("Generating terrain...")
	end
end

local function send_drone_pos()
	local p = drone_node:GetWorldPosition()
	local data = cereal.binary_output({x = p.x, y = p.y, z = p.z},
			{"object", {"x", "double"}, {"y", "double"}, {"z", "double"}})
	buildat.send_packet("main:drone_pos", data)
end

-- Top face of the terrain at p's column, or nil if it is not known (the
-- chunk has not arrived). A point inside terrain searches upwards, so flying
-- into a hillside puts the drone on top of it rather than one voxel at a
-- time. Voxel n is a 1x1x1 cube centered at n, so its top face is at n + 0.5.
local function terrain_top_near(p, max_d)
	local x = math.floor(p.x + 0.5)
	local z = math.floor(p.z + 0.5)
	local y0 = math.floor(p.y + 0.5)
	local function solid(y)
		return voxelworld.get_static_voxel(buildat.Vector3(x, y, z)).id >= 2
	end
	if solid(y0) then
		for y = y0 + 1, y0 + max_d do
			if not solid(y) then
				return (y - 1) + 0.5
			end
		end
		return y0 + max_d + 0.5
	end
	for y = y0 - 1, y0 - max_d, -1 do
		if solid(y) then
			return y + 0.5
		end
	end
	return nil
end

magic.ui:SetFocusElement(nil)

local bombs = {} -- {node=, vel=, age=}

local function drop_bomb()
	local node = scene:CreateChild("Bomb")
	node.position = bomb_mount:GetWorldPosition()
	node.scale = magic.Vector3(0.3, 0.9, 0.3)
	local sm = node:CreateComponent("StaticModel")
	sm.model = magic.cache:GetResource("Model", "Models/Cylinder.mdl")
	sm.material = matte_material(0.04, 0.04, 0.045)
	sm.castShadows = true
	local vel = drone_node:GetWorldDirection() * speed +
			drone_down() * BOMB_EJECT_SPEED
	table.insert(bombs, {node = node, vel = vel, age = 0})
end

local function explode(p)
	local diameter = 10 + math.random() * 10
	local data = cereal.binary_output(
			{x = p.x, y = p.y, z = p.z, diameter = diameter},
			{"object", {"x", "double"}, {"y", "double"}, {"z", "double"},
				{"diameter", "double"}})
	buildat.send_packet("main:explode", data)
end

local function update_bombs(dt)
	local i = 1
	while i <= #bombs do
		local b = bombs[i]
		b.age = b.age + dt
		-- Substepped so that the terrain is tested along the whole path of
		-- this frame rather than only at its end
		local steps = math.ceil(b.vel:Length() * dt / BOMB_MAX_STEP)
		if steps < 1 then
			steps = 1
		elseif steps > BOMB_MAX_STEPS then
			steps = BOMB_MAX_STEPS
		end
		local sdt = dt / steps
		local p = b.node.position
		local hit = false
		for _ = 1, steps do
			b.vel.y = b.vel.y - BOMB_GRAVITY * sdt
			b.vel = b.vel * (1 - BOMB_DRAG * sdt)
			p = p + b.vel * sdt
			if voxelworld.get_static_voxel(buildat.Vector3(p)).id >= 2 then
				hit = true
				break
			end
		end
		b.node.position = p
		-- Cylinder points along its own +Y; aim that along the trajectory
		b.node.direction = b.vel:Normalized()
		b.node:Pitch(90)
		if hit then
			explode(p)
		end
		if hit or b.age > BOMB_MAX_AGE or p.y < -200 then
			b.node:Remove()
			table.remove(bombs, i)
		else
			i = i + 1
		end
	end
end

local function update_flight(dt)
	if not terrain_seen then
		if not terrain_top_near(drone_node.position, 24) then
			return
		end
		terrain_seen = true
	end

	local pitch_input = 0
	local roll_input = 0
	if magic.input:GetKeyDown(magic.KEY_W) then
		pitch_input = pitch_input + 1 -- nose down
	end
	if magic.input:GetKeyDown(magic.KEY_S) then
		pitch_input = pitch_input - 1 -- nose up
	end
	if magic.input:GetKeyDown(magic.KEY_D) then
		roll_input = roll_input - 1
	end
	if magic.input:GetKeyDown(magic.KEY_A) then
		roll_input = roll_input + 1
	end

	-- Control authority and stability both come from airflow
	local q = math.min(1, speed / STALL_SPEED)

	-- On its gear it sits level: no stall attitude, and nothing that would
	-- let it roll off down a slope
	local rolling = on_ground and speed < STALL_SPEED

	-- Where the drone stands relative to the horizon. Roll is how far its
	-- own roof has turned away from up, and climb is where its nose points.
	local forward = drone_node:GetWorldDirection()
	local right = body_axis(axis_right)
	local up = body_axis(axis_up)
	local roll_angle = math.deg(math.atan2(right.y, up.y))
	local climb = math.deg(math.asin(
			math.max(-1, math.min(1, forward.y))))

	-- Every one of these turns the drone about its own axes: pitch about the
	-- wing line, roll about the nose. A rolled drone pitching therefore pulls
	-- towards its own roof, which is what makes a bank turn.
	local pitch_deg = 0
	local roll_deg = 0
	if pitch_input ~= 0 and not rolling then
		pitch_deg = pitch_input * PITCH_RATE * q * dt
	elseif rolling then
		-- On its gear: level, and nothing that would let it roll off a slope
		pitch_deg = climb * math.min(1, 4 * dt)
	else
		-- Above stall speed it trims itself level; below it, the nose drops
		local target = (speed >= STALL_SPEED) and 0 or -STALL_PITCH_DOWN
		pitch_deg = (climb - target) * math.min(1, PITCH_LEVEL_K * dt)
	end
	if roll_input ~= 0 and not rolling then
		roll_deg = roll_input * ROLL_RATE * q * dt
	elseif rolling then
		roll_deg = -roll_angle * math.min(1, 4 * dt)
	else
		roll_deg = -roll_angle * math.min(1, ROLL_LEVEL_K * dt)
	end

	if pitch_deg ~= 0 then
		drone_node:Rotate(magic.Quaternion(pitch_deg,
				magic.Vector3(1, 0, 0)), magic.TS_LOCAL)
	end
	if roll_deg ~= 0 then
		drone_node:Rotate(magic.Quaternion(roll_deg,
				magic.Vector3(0, 0, 1)), magic.TS_LOCAL)
	end
	-- The yaw a bank drags with it turns about the world's vertical, not the
	-- drone's own, so that it reads as a turn however far the drone is rolled
	local yaw_deg = -YAW_PER_ROLL * math.sin(math.rad(roll_angle)) * q * dt
	if yaw_deg ~= 0 then
		drone_node:Rotate(magic.Quaternion(yaw_deg,
				magic.Vector3(0, 1, 0)), magic.TS_WORLD)
	end

	forward = drone_node:GetWorldDirection()
	-- Keep the last heading that meant anything: straight up has none
	if math.abs(forward.x) + math.abs(forward.z) > 0.1 then
		heading = magic.Vector3(forward.x, 0, forward.z):Normalized()
	end
	if motor_on then
		speed = math.min(MOTOR_SPEED, speed + MOTOR_ACCEL * dt)
	else
		speed = speed - (rolling and GROUND_BRAKE or IDLE_DECEL) * dt
	end
	if not rolling then
		speed = speed - GRAVITY_EXCHANGE * forward.y * dt
	end
	if speed < 0 then
		speed = 0
	end

	local p = drone_node.position + forward * (speed * dt)
	-- Not knowing where the ground is means the chunk has not arrived yet;
	-- hold altitude rather than sink through terrain that is about to exist
	local ground_top = terrain_top_near(p, 24)
	if speed < STALL_SPEED and ground_top then
		p.y = p.y - SINK_RATE * (1 - speed / STALL_SPEED) * dt
	end

	-- Terrain is a floor rather than a crash; the drone slides on it
	on_ground = false
	if ground_top and p.y - 0.5 < ground_top then
		p.y = ground_top + 0.5
		on_ground = true
	end
	drone_node.position = p
end

local function update_chase_camera(dt)
	local drone_p = drone_node:GetWorldPosition()
	-- Level heading only: the gimbal aircraft flies level even in a loop
	local desired = drone_p + heading * CHASE_DIST +
			magic.Vector3(0, CHASE_UP, 0)
	-- Near the ground the camera stays in the air and points down instead
	local ground_top = terrain_top_near(desired, 32)
	if ground_top and desired.y < ground_top + CHASE_MIN_ALT then
		desired.y = ground_top + CHASE_MIN_ALT
	end
	local cam_p = chase_camera_node.position
	chase_camera_node.position = cam_p +
			(desired - cam_p) * math.min(1, CHASE_LAG * dt)
	chase_camera_node:LookAt(drone_p - magic.Vector3(0, CHASE_AIM_DOWN, 0))
end

-- One action per press of the key: KeyDown also fires on key repeat, and the
-- motor toggle in particular must not flicker while the key is held
magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if event_data:GetBool("Repeat") then
		return
	end
	if key == magic.KEY_ESCAPE then
		buildat.leave()
	elseif key == KEY_MOTOR then
		motor_on = not motor_on
	elseif key == magic.KEY_SPACE then
		drop_bomb()
	end
end)

local pos_send_counter = 0

magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")

	voxel_shading.update(dt)
	layout_viewports()

	pos_send_counter = pos_send_counter + 1
	if pos_send_counter >= 15 then
		pos_send_counter = 0
		send_drone_pos()
	end

	if spawn_received and drone_node.position.y < -200 then
		-- Out of the world (it can only get there through a gap in the
		-- streamed terrain); put it back on the runway
		drone_node.position = spawn_p
		drone_node.rotation = magic.Quaternion(0, 90, 0)
		heading = magic.Vector3(1, 0, 0)
		speed = 0
		motor_on = false
	end

	if spawn_received then
		update_flight(dt)
		update_bombs(dt)
	end
	update_chase_camera(dt)

	local p = drone_node:GetWorldPosition()
	misc_text:SetText(string.format(
			"motor %s  speed %.0f%s  alt %.0f  (%.0f, %.0f, %.0f)  bombs %i",
			motor_on and "ON " or "off",
			speed, (speed < STALL_SPEED) and " STALL" or "",
			p.y, p.x, p.y, p.z, #bombs))
end)

buildat.sub_packet("main:spawn", function(data)
	local v = cereal.binary_input(data, {"object",
		{"x", "double"}, {"y", "double"}, {"z", "double"}})
	log:info("spawn ("..v.x..", "..v.y..", "..v.z..")")
	spawn_p = magic.Vector3(v.x, v.y, v.z)
	drone_node.position = spawn_p
	-- Level, pointing along the runway towards +X
	drone_node.rotation = magic.Quaternion(0, 90, 0)
	heading = magic.Vector3(1, 0, 0)
	speed = 0
	motor_on = false
	spawn_received = true
	set_generating_status(0)
	send_drone_pos()
end)

buildat.sub_packet("main:worldgen_queue_size", function(data)
	set_generating_status(tonumber(data))
end)

-- vim: set noet ts=4 sw=4:
