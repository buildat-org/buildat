-- Buildat: sample_material_wall/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sample_material_wall")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local ui_utils = require("buildat/extension/ui_utils")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")

local scene = replicate.main_scene

-- The whole scene is one section seen from outside itself, so nothing
-- needs collision (and LOD is off, voxelworld's default).
voxelworld.physics_distance = 0
voxelworld.use_skylight = true

-- This world's format binds tint, wetness, grain and gloss, which is the four
-- the reference shader reads; see builtin/voxel_shading/PBRVoxelModifiers.xml
voxel_shading.use_modifiers(true)

-- Head on to the wall of samples: the grid runs x 8...53 and y 11...26 at
-- z 34, and this is far enough back for all ten columns to fit across.
local CAMERA_POS = {x = 30.5, y = 44, z = 6}
local CAMERA_YAW = 0
local CAMERA_PITCH = 37
local CAMERA_FOV = 55
local FAR_CLIP = 400

local MOVE_SPEED = 20
local MOUSE_SENSITIVITY = 0.15

-- The same PBR setup the other voxel games use; apps/sample_lighting_scene's README
-- says why these numbers are what they are.
local SKY_AMBIENT = magic.Color(0.26, 0.33, 0.46)
local SUN_BRIGHTNESS = 14.0
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.8}
local EXPOSURE_BIAS = 1.0

local yaw, pitch = CAMERA_YAW, CAMERA_PITCH
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
	camera_node.position = magic.Vector3(CAMERA_POS.x, CAMERA_POS.y,
			CAMERA_POS.z)
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

-- What each row of the wall is, top row first, because that is the order they
-- are read on screen
local LEGEND =
		"gloss (binder) 0 -> full\n"..
		"tint + wetness (dry -> soaked)\n"..
		"rock -> sand, soaked\n"..
		"rock -> sand, dry\n"..
		"sag_top 0 -> full"

do
	local text = magic.ui.root:CreateChild("Text")
	text:SetText(LEGEND.."\n\nTab = free move")
	text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
	text.horizontalAlignment = magic.HA_LEFT
	text.verticalAlignment = magic.VA_TOP
	text:SetPosition(10, 10)
	magic.ui:SetFocusElement(nil)
end

local wait_text = magic.ui.root:CreateChild("Text")
wait_text:SetText("Generating...")
wait_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 24)
wait_text.horizontalAlignment = magic.HA_CENTER
wait_text.verticalAlignment = magic.VA_CENTER
wait_text:SetPosition(0, 0)
voxelworld.sub_geometry_update(function(node)
	wait_text:SetText("")
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

log:info("sample_material_wall client ready; Tab = free move")
-- vim: set noet ts=4 sw=4:
