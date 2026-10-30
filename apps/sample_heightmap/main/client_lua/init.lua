-- Buildat: apps/sample_heightmap/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [HEIGHTMAP_TERRAIN] The ball and the camera behind it; the ground is
-- builtin/heightmap's. WASD pushes the ball, C digs a crater under it, O
-- looks over the whole map from above a corner and back.
-- Every 2 s the log says the frame time, triangles and draw calls.
local log = buildat.Logger("sample_heightmap")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local heightmap = require("buildat/module/heightmap")

local scene = replicate.main_scene
local FAR_CLIP = 1200

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
	camera_node.position = magic.Vector3(500, 60, 490)
	camera_node:LookAt(magic.Vector3(512, 30, 512))
	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})
end

local ball = nil
local overview = false
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
	-- The sphere model is a metre across; the ball two
	node.scale = magic.Vector3(2, 2, 2)
end)

local KEY_BITS = {[magic.KEY_W] = 1, [magic.KEY_A] = 2, [magic.KEY_S] = 4,
		[magic.KEY_D] = 8}
local keys = 0
local function send_keys(bit, down)
	local k = down and bit or 0
	local new = keys - (keys % (bit * 2)) + (keys % bit) + k
	if new ~= keys then
		keys = new
		buildat.send_packet("main:input", string.char(keys))
	end
end

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if KEY_BITS[key] then
		send_keys(KEY_BITS[key], true)
	elseif key == magic.KEY_C then
		buildat.send_packet("main:crater", "")
	elseif key == magic.KEY_O then
		overview = not overview
	elseif key == magic.KEY_ESCAPE then
		buildat.leave()
	end
end)
magic.SubscribeToEvent("KeyUp", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if KEY_BITS[key] then
		send_keys(KEY_BITS[key], false)
	end
end)

-- The crater the server says it dug, until this client's terrain has it
local crater = nil
buildat.sub_packet("main:crater", function(data)
	local x, z, h = data:match("^(%S+) (%S+) (%S+)$")
	crater = {x = tonumber(x), z = tonumber(z), h = tonumber(h)}
end)

local frames, frame_s, worst_s, stat_s = 0, 0, 0, 0
magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	if overview then
		camera_node.position = magic.Vector3(0, 300, 0)
		camera_node:LookAt(magic.Vector3(400, 0, 400))
	elseif ball then
		local p = ball.position
		-- Over the ground where the camera is: a hill behind the ball
		-- would have it look out from inside the hill
		local y = math.max(p.y + 9,
				(heightmap.height_at(p.x - 14, p.z - 14) or p.y) + 3)
		camera_node.position = magic.Vector3(p.x - 14, y, p.z - 14)
		camera_node:LookAt(magic.Vector3(p.x, p.y, p.z))
	end
	if crater and heightmap.terrain then
		local h = heightmap.height_at(crater.x, crater.z)
		if math.abs(h - crater.h) < 0.01 then
			log:info(string.format("sample_heightmap: the crater reached"..
					" this client: the ground at (%.2f, %.2f) reads %.3f",
					crater.x, crater.z, h))
			crater = nil
		end
	end
	if not heightmap.terrain then
		return
	end
	frames, frame_s = frames + 1, frame_s + dt
	worst_s = math.max(worst_s, dt)
	stat_s = stat_s + dt
	if stat_s >= 2 then
		log:info(string.format("sample_heightmap: frame %.1f ms average,"..
				" %.1f ms worst, %d triangles, %d draw calls",
				frame_s / frames * 1000, worst_s * 1000,
				magic.renderer.numPrimitives, magic.renderer.numBatches))
		frames, frame_s, worst_s, stat_s = 0, 0, 0, 0
	end
end)

log:info("sample_heightmap client ready; WASD pushes the ball, C digs,"..
		" O looks over the map")
-- vim: set noet ts=4 sw=4:
