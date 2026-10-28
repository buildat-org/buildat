-- Buildat: sample_falling_blocks/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sample_falling_blocks")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local ui_utils = require("buildat/extension/ui_utils")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")

local scene = replicate.main_scene

-- The pieces are simulated on the server and arrive as node transforms, so
-- the client needs no collision shapes of its own (and LOD is off,
-- voxelworld's default).
voxelworld.physics_distance = 1
voxelworld.use_skylight = true

-- Close in on where the pieces land rather than framing the whole section:
-- the terrain is 64 voxels across and the pile is a few voxels wide.
local LOOK_AT = {x = 32, y = 20, z = 32}
local CAMERA_DISTANCE = 34
local CAMERA_FOV = 45
local FAR_CLIP = 400
-- Steep enough that the camera is above the bank of the bowl at this
-- distance, and looking down into it rather than across the rim
local VIEW_DIR = {x = -1.0, y = -0.9, z = -1.0}

local MOVE_SPEED = 20
local MOUSE_SENSITIVITY = 0.15

-- Lighting, the same PBR setup sample_lighting_scene uses; its README says why these
-- numbers are what they are.
local SKY_AMBIENT = magic.Color(0.26, 0.33, 0.46)
local SUN_BRIGHTNESS = 50.0
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.8}
local EXPOSURE_BIAS = 1.6

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

local yaw, pitch = angles_from_dir(VIEW_DIR)
local free_look = false

do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = SKY_AMBIENT
	zone.fogColor = magic.Color(0.60, 0.72, 0.88)
	zone.fogStart = FAR_CLIP * 0.6
	zone.fogEnd = FAR_CLIP
	zone.priority = -1
	zone.override = true
	-- What the voxel shader reflects; without it the shader's IBL term
	-- samples nothing and every reflection is black
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

local camera_node = scene:CreateChild("Camera")
do
	local d = normalized(VIEW_DIR)
	camera_node.position = magic.Vector3(
			LOOK_AT.x - d.x * CAMERA_DISTANCE,
			LOOK_AT.y - d.y * CAMERA_DISTANCE,
			LOOK_AT.z - d.z * CAMERA_DISTANCE)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 1.0
	camera.farClip = FAR_CLIP
	-- Of the screen's short side, a portrait one's width
	magic.keep_fov(camera, CAMERA_FOV)

	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})

	magic.renderer.HDRRendering = true
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

voxelworld.set_camera(camera_node)
voxel_shading.set_camera(camera_node)

magic.input:SetMouseVisible(true)

local title_text = magic.ui.root:CreateChild("Text")
title_text:SetText("Tab = free move, R = clear the pieces")
title_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
title_text.horizontalAlignment = magic.HA_CENTER
title_text.verticalAlignment = magic.VA_TOP
title_text:SetPosition(0, 10)
magic.ui:SetFocusElement(nil)

-- The terrain is generated on the server after the client has connected, which
-- takes a few seconds and shows as nothing but sky. Say what is going on until
-- the first chunk's geometry exists.
local wait_text = magic.ui.root:CreateChild("Text")
wait_text:SetText("Generating terrain...")
wait_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 24)
wait_text.horizontalAlignment = magic.HA_CENTER
wait_text.verticalAlignment = magic.VA_CENTER
wait_text:SetPosition(0, 0)
voxelworld.sub_geometry_update(function(node)
	wait_text:SetText("")
end)

-- The pieces. They are replicated scene nodes carrying voxel data in their
-- vars, not part of the voxel world, so the geometry is built here out of the
-- world's own registry: same textures and atlas as the terrain.
local function setup_simple_voxel_data(node)
	local voxel_reg = voxelworld.get_voxel_registry()
	local atlas_reg = voxelworld.get_atlas_registry()
	local data = node:GetVar("simple_voxel_data"):GetBuffer()
	local w = node:GetVar("simple_voxel_w"):GetInt()
	local h = node:GetVar("simple_voxel_h"):GetInt()
	local d = node:GetVar("simple_voxel_d"):GetInt()
	-- A body: no world position, so the texture repeat starts at its corner
	buildat.set_8bit_voxel_geometry(node, w, h, d, data, voxel_reg, atlas_reg,
			0, 0, 0)
	-- Same shader as the terrain, or the piece is drawn by whatever the
	-- mesher left on it and comes out nothing like the ground it lands on
	voxel_shading.apply_to_node(node)
end

voxelworld.sub_ready(function()
	-- Only now, because the registries are voxelworld's
	replicate.sub_sync_node_added({}, function(node)
		if not node:GetVar("simple_voxel_data"):IsEmpty() then
			setup_simple_voxel_data(node)
		end
	end)
end)

local function set_free_look(enable)
	free_look = enable
	-- On the web the pointer lock too ([WEB_MOUSE_CAPTURE])
	ui_utils.mouse_look(free_look)
end

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_TAB then
		set_free_look(not free_look)
	elseif key == magic.KEY_R then
		buildat.send_packet("main:reset", "")
	elseif key == magic.KEY_ESCAPE and ui_utils.mouse_look_escape() then
		-- The browser's letting go of the pointer: "Click to continue" is up
	elseif key == magic.KEY_ESCAPE then
		if free_look then
			set_free_look(false)
		else
			buildat.leave()
		end
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	voxel_shading.update(dt)
	if not free_look then
		return
	end

	local dmouse = {}
	dmouse.x, dmouse.y = ui_utils.mouse_look_move()
	yaw = yaw + dmouse.x * MOUSE_SENSITIVITY
	pitch = pitch + dmouse.y * MOUSE_SENSITIVITY
	if pitch > 89 then pitch = 89 end
	if pitch < -89 then pitch = -89 end

	local yr = math.rad(yaw)
	local forward = magic.Vector3(math.sin(yr), 0, math.cos(yr))
	local right = magic.Vector3(math.cos(yr), 0, -math.sin(yr))

	local speed = MOVE_SPEED * dt
	local p = camera_node.position
	local function move(v, s)
		p = magic.Vector3(p.x + v.x*s, p.y + v.y*s, p.z + v.z*s)
	end
	if magic.input:GetKeyDown(magic.KEY_W) then move(forward, speed) end
	if magic.input:GetKeyDown(magic.KEY_S) then move(forward, -speed) end
	if magic.input:GetKeyDown(magic.KEY_D) then move(right, speed) end
	if magic.input:GetKeyDown(magic.KEY_A) then move(right, -speed) end
	if magic.input:GetKeyDown(magic.KEY_SPACE) then
		p = magic.Vector3(p.x, p.y + speed, p.z)
	end
	if magic.input:GetKeyDown(magic.KEY_SHIFT) then
		p = magic.Vector3(p.x, p.y - speed, p.z)
	end

	camera_node.position = p
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
end)

log:info("sample_falling_blocks client ready; Tab = free move, R = clear the pieces")
-- vim: set noet ts=4 sw=4:
