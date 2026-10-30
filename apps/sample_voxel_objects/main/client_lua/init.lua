-- Buildat: apps/sample_voxel_objects/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [VOXEL_OBJECTS] The camera over builtin/voxel_objects' houses on
-- builtin/heightmap's hills, and the ball. H looks over the houses, B at
-- the beam and the ball, E edits the models (the server's), Escape leaves.
-- Every 2 s the log says the frame time, triangles, draw calls and
-- voxel_objects' counts.
local log = buildat.Logger("sample_voxel_objects")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local heightmap = require("buildat/module/heightmap")
local voxel_objects = require("buildat/module/voxel_objects")

local scene = replicate.main_scene
local FAR_CLIP = 900

do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-5000, 5000)
	zone.ambientColor = magic.Color(0.35, 0.38, 0.45)
	zone.fogColor = magic.Color(0.62, 0.74, 0.90)
	zone.fogStart = FAR_CLIP * 0.5
	zone.fogEnd = FAR_CLIP
end

do
	local node = scene:CreateChild("Sun")
	node.direction = magic.Vector3(-0.5, -1.0, 0.7)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.color = magic.Color(1.0, 0.96, 0.88)
end

local camera_node = scene:CreateChild("Camera")
do
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.5
	camera.farClip = FAR_CLIP
	magic.keep_fov(camera, 60)
	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})
end

-- "houses" or "beam"
local view = "houses"
local ball = nil
replicate.sub_sync_node_added({}, function(node)
	if node:GetName() ~= "ball" then
		return
	end
	ball = node
	local model = node:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Sphere.mdl")
	model.material = magic.cache:GetResource("Material",
			"Materials/Stone.xml")
	model.castShadows = true
end)

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_E then
		buildat.send_packet("main:edit", "")
	elseif key == magic.KEY_B then
		view = "beam"
	elseif key == magic.KEY_H then
		view = "houses"
	elseif key == magic.KEY_ESCAPE then
		buildat.leave()
	end
end)

local frames, frame_s, worst_s, stat_s = 0, 0, 0, 0
magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	if view == "beam" and ball then
		local p = ball.position
		camera_node.position = magic.Vector3(p.x - 12, p.y + 7, p.z - 12)
		camera_node:LookAt(magic.Vector3(p.x, p.y - 2, p.z))
	else
		-- Over the grid's near corner, all hundred in view
		local y = (heightmap.height_at(0, 0) or 0)
		camera_node.position = magic.Vector3(-25, y + 70, -25)
		camera_node:LookAt(magic.Vector3(110, y, 110))
	end
	if not heightmap.terrain then
		return
	end
	frames, frame_s = frames + 1, frame_s + dt
	worst_s = math.max(worst_s, dt)
	stat_s = stat_s + dt
	if stat_s >= 2 then
		local c = voxel_objects.counts()
		log:info(string.format("sample_voxel_objects: frame %.1f ms average,"..
				" %.1f ms worst, %d triangles, %d draw calls; %d models, %d"..
				" meshes, %d objects, %d chunk nodes", frame_s / frames * 1000,
				worst_s * 1000, magic.renderer.numPrimitives,
				magic.renderer.numBatches, c.models, c.meshes, c.objects,
				c.chunk_nodes))
		frames, frame_s, worst_s, stat_s = 0, 0, 0, 0
	end
end)

log:info("sample_voxel_objects client ready; E edits, B the beam, H the"..
		" houses")
-- vim: set noet ts=4 sw=4:
