-- Buildat: featuretest/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("featuretest")
local magic = require("buildat/extension/urho3d")
log:info("featuretest/init.lua loaded")

scene = magic.Scene()
scene:CreateComponent("Octree")
scene:CreateComponent("PhysicsWorld")

do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-200, 200)
	zone.ambientColor = magic.Color(0.35, 0.38, 0.45)
	zone.fogColor = magic.Color(0.55, 0.62, 0.72)
	zone.fogStart = 20
	zone.fogEnd = 60
end

do
	local node = scene:CreateChild("Sun")
	node.direction = magic.Vector3(0.4, -1.0, 0.35)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.brightness = 1.1
	light.color = magic.Color(1.0, 0.96, 0.88)
	light.shadowBias = magic.BiasParameters(0.00025, 0.5)
	light.shadowCascade = magic.CascadeParameters(10, 20, 40, 80, 0.8)
end

do
	local node = scene:CreateChild("Ground")
	node.position = magic.Vector3(0, -0.5, 0)
	node.scale = magic.Vector3(40, 1, 40)
	local model = node:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	local mat = magic.Material:new()
	mat:SetTechnique(0, magic.cache:GetResource("Technique", "Techniques/Diff.xml"))
	mat:SetTexture(magic.TU_DIFFUSE,
			magic.cache:GetResource("Texture2D", "main/default_stone.png"))
	model.material = mat
	model.castShadows = true
	local body = node:CreateComponent("RigidBody")
	body.mass = 0
	body.friction = 0.8
	local shape = node:CreateComponent("CollisionShape")
	shape:SetBox(magic.Vector3(1, 1, 1))
end

falling = {}
do
	local models = {"Box.mdl", "Sphere.mdl", "Cylinder.mdl", "Cone.mdl"}
	for i = 1, 10 do
		local node = scene:CreateChild("Falling"..i)
		node.position = magic.Vector3((i % 5) - 2, 6 + i * 0.7, (i % 3) - 1)
		local model = node:CreateComponent("StaticModel")
		model.model = magic.cache:GetResource("Model", "Models/"..models[(i % 4) + 1])
		model.material = magic.cache:GetResource("Material", "Materials/Stone.xml")
		model.castShadows = true
		local body = node:CreateComponent("RigidBody")
		body.mass = 1.5
		body.friction = 0.4
		body.restitution = 0.35
		body.linearDamping = 0.05
		local shape = node:CreateComponent("CollisionShape")
		if i % 4 == 2 then
			shape:SetSphere(1)
		elseif i % 4 == 3 then
			shape:SetCylinder(1, 1)
		elseif i % 4 == 0 then
			shape:SetCone(1, 1)
		else
			shape:SetBox(magic.Vector3(1, 1, 1))
		end
		falling[i] = node
	end
end

jack_node = scene:CreateChild("Jack")
do
	jack_node.position = magic.Vector3(-5, 0, 2)
	jack_node:Yaw(40)
	local model = jack_node:CreateComponent("AnimatedModel")
	model.model = magic.cache:GetResource("Model", "Models/Jack.mdl")
	model.material = magic.cache:GetResource("Material", "Materials/Jack.xml")
	model.castShadows = true
	local anim = jack_node:CreateComponent("AnimationController")
	anim:Play("Models/Jack_Walk.ani", 0, true)
	anim:SetSpeed("Models/Jack_Walk.ani", 0.8)
end

spider_node = scene:CreateChild("Spider")
do
	spider_node.position = magic.Vector3(5, 0.65, 2)
	spider_node:Yaw(-40)
	local model = spider_node:CreateComponent("AnimatedModel")
	model.model = magic.cache:GetResource("Model", "main/gltf_spider_animated.gltf")
	local mat = magic.Material:new()
	mat:SetTechnique(0, magic.cache:GetResource("Technique", "Techniques/Diff.xml"))
	mat:SetTexture(magic.TU_DIFFUSE,
			magic.cache:GetResource("Texture2D", "main/gltf_spider.png"))
	model.material = mat
	model.castShadows = true
	local anim = spider_node:CreateComponent("AnimationController")
	anim:Play("main/gltf_spider_animated.gltf", 0, true)
end

do
	local node = scene:CreateChild("Fire")
	node.position = magic.Vector3(3.5, 0.2, -3)
	-- Urho3D's Particle/Fire.xml, built here: its material's texture is a
	-- DDS, which the client does not load
	local mat = magic.Material:new()
	mat:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/DiffUnlitParticleAdd.xml"))
	mat:SetTexture(magic.TU_DIFFUSE,
			magic.cache:GetResource("Texture2D", "main/fire_basic_flame.png"))
	local effect = magic.ParticleEffect.new()
	effect.material = mat
	effect.numParticles = 200
	effect.emitterType = 0
	effect:SetMinDirection(magic.Vector3(-0.1, 0.1, -0.1))
	effect:SetMaxDirection(magic.Vector3(0.1, 1, 0.1))
	effect:SetConstantForce(magic.Vector3(0, 2, 0))
	effect.dampingForce = 2
	effect.minEmissionRate = 40
	effect.maxEmissionRate = 50
	effect:SetMinParticleSize(magic.Vector2(0.1, 0.1))
	effect:SetMaxParticleSize(magic.Vector2(0.4, 0.4))
	effect.minTimeToLive = 1
	effect.maxTimeToLive = 1
	effect.minVelocity = 1
	effect.maxVelocity = 2
	effect.sizeMul = 0.5
	effect.scaled = true
	effect:AddColorTime(magic.Color(0.1, 0.5, 1, 1), 0)
	effect:AddColorTime(magic.Color(1, 0.63, 0.45, 1), 0.5)
	effect:AddColorTime(magic.Color(0, 0, 0, 0), 1)
	local emitter = node:CreateComponent("ParticleEmitter")
	emitter.effect = effect
	emitter.emitting = true
end

do
	local node = scene:CreateChild("Billboards")
	node.position = magic.Vector3(0, 3, 0)
	local bb = node:CreateComponent("BillboardSet")
	local mat = magic.Material:new()
	mat:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/DiffUnlitParticleAdd.xml"))
	mat:SetTexture(magic.TU_DIFFUSE,
			magic.cache:GetResource("Texture2D", "main/fire_basic_flame.png"))
	bb.material = mat
	bb.numBillboards = 6
	bb.sorted = true
	bb.faceCameraMode = magic.FC_ROTATE_XYZ
	for i = 0, 5 do
		local b = bb:GetBillboard(i)
		local a = i * math.pi * 2 / 6
		b.position = magic.Vector3(math.cos(a) * 3, math.sin(a * 2) * 0.6, math.sin(a) * 3)
		b.size = magic.Vector2(0.8, 0.8)
		b.color = magic.Color(1, 0.85, 0.4, 0.9)
		b.enabled = true
	end
	bb:Commit()
end

orbit_node = scene:CreateChild("Orbit")
do
	orbit_node.position = magic.Vector3(0, 2.5, 0)
	local ball = orbit_node:CreateChild("TrailHead")
	ball.position = magic.Vector3(6, 0, 0)
	local model = ball:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Sphere.mdl")
	model.material = magic.cache:GetResource("Material", "Materials/Stone.xml")
	model.castShadows = true
	ball.scale = magic.Vector3(0.35, 0.35, 0.35)
	local trail = ball:CreateComponent("RibbonTrail")
	trail.material = magic.cache:GetResource("Material", "Materials/RibbonTrail.xml")
	trail.vertexDistance = 0.15
	trail.width = 0.18
	trail.startColor = magic.Color(1, 0.4, 0.15, 1)
	trail.endColor = magic.Color(1, 0.2, 0.05, 0)
	trail.lifetime = 1.2
	trail.emitting = true
	trail.trailType = magic.TT_FACE_CAMERA
	local light = ball:CreateComponent("Light")
	light.lightType = magic.LIGHT_POINT
	light.range = 6
	light.brightness = 1.4
	light.color = magic.Color(1.0, 0.45, 0.15)
	orbit_ball = ball
end

camera_node = scene:CreateChild("Camera")
do
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.2
	camera.farClip = 120
	-- Of the screen's short side, a portrait one's width
	magic.keep_fov(camera, 60)
	local listener = camera_node:CreateComponent("SoundListener")
	if magic.audio then
		magic.audio.listener = listener
	end
	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})
end

do
	if magic.audio then
		local fire = magic.cache:GetResource("Sound", "main/fire_small.ogg")
		fire.looped = true
		local src = scene:CreateChild("Ambient"):CreateComponent("SoundSource")
		src.soundType = magic.SOUND_AMBIENT
		src.gain = 0.22
		src:Play(fire)

		local whoosh = magic.cache:GetResource("Sound", "main/fire_fire.ogg")
		whoosh.looped = true
		local src3 = orbit_ball:CreateComponent("SoundSource3D")
		src3.soundType = magic.SOUND_EFFECT
		src3.gain = 0.4
		src3.nearDistance = 1
		src3.farDistance = 18
		src3:Play(whoosh)

		flint_sound = magic.cache:GetResource("Sound",
				"main/fire_flint_and_steel.ogg")
		flint_src = jack_node:CreateComponent("SoundSource3D")
		flint_src.soundType = magic.SOUND_EFFECT
		flint_src.gain = 0.55
		flint_src.nearDistance = 2
		flint_src.farDistance = 20
	else
		log:info("audio subsystem not present")
	end
end

local title = magic.ui.root:CreateChild("Text")
title:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 16)
title.text = "featuretest"
title.horizontalAlignment = magic.HA_CENTER
title.verticalAlignment = magic.VA_TOP
title:SetPosition(0, 16)

local info = magic.ui.root:CreateChild("Text")
info:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 13)
info.text = "physics  particles  billboards\n"..
		"animated model  glTF spider  ribbon trail\n"..
		"point light  ambient + 3D audio"
info.horizontalAlignment = magic.HA_LEFT
info.verticalAlignment = magic.VA_TOP
info:SetPosition(16, 16)
info.color = magic.Color(0.75, 0.8, 0.85)

magic.ui:SetFocusElement(nil)

local t_accum = 0
local flint_t = 0
magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	t_accum = t_accum + dt
	orbit_node:Yaw(dt * 70)
	camera_node.position = magic.Vector3(
			math.cos(t_accum * 0.15) * 16,
			7 + math.sin(t_accum * 0.2) * 1.5,
			math.sin(t_accum * 0.15) * 16)
	camera_node:LookAt(magic.Vector3(0, 1.5, 0))
	jack_node:Translate(magic.Vector3(dt * 0.6, 0, 0))
	if jack_node.position.x > 6 then
		jack_node.position = magic.Vector3(-6, 0, 2)
	end
	if flint_src and flint_sound then
		flint_t = flint_t + dt
		if flint_t > 3.5 then
			flint_t = 0
			flint_src:Play(flint_sound)
		end
	end
end)

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESCAPE then
		log:info("KEY_ESCAPE pressed")
		buildat.leave()
	end
end)
-- vim: set noet ts=4 sw=4:
