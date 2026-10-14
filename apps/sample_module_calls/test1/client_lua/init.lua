-- Buildat: test1/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("test1")
local dump = buildat.dump
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")
local client_lib_test = require("buildat/module/client_lib_test")

-- 3D things

-- NOTE: Create global variable so that it doesn't get automatically deleted
local scene = magic.Scene()
scene:CreateComponent("Octree")

-- Note that naming the scene nodes is optional
local plane_node = scene:CreateChild("Plane")
plane_node.scale = magic.Vector3(10.0, 1.0, 10.0)
local plane_object = plane_node:CreateComponent("StaticModel")
plane_object.model = magic.cache:GetResource("Model", "Models/Plane.mdl")
plane_object.material = magic.cache:GetResource("Material", "Materials/Stone.xml")
plane_object.material:SetTexture(magic.TU_DIFFUSE,
		magic.cache:GetResource("Texture2D", "test1/green_texture.png"))

local light_node = scene:CreateChild("DirectionalLight")
light_node.direction = magic.Vector3(-0.6, -1.0, 0.8) -- The direction vector does not need to be normalized
local light = light_node:CreateComponent("Light")
light.lightType = magic.LIGHT_DIRECTIONAL
light.castShadows = true
light.shadowBias = magic.BiasParameters(0.00025, 0.5)
light.shadowCascade = magic.CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
light.brightness = 0.8

local light_node = scene:CreateChild("DirectionalLight")
light_node.direction = magic.Vector3(0.6, -1.0, -0.8) -- The direction vector does not need to be normalized
local light = light_node:CreateComponent("Light")
light.lightType = magic.LIGHT_DIRECTIONAL
light.brightness = 0.2

-- Add a camera so we can look at the scene
camera_node = scene:CreateChild("Camera")
camera_node:CreateComponent("Camera")
camera_node.position = magic.Vector3(7.0, 7.0, 7.0)
--camera_node.rotation = Quaternion(0, 0, 0.0)
camera_node:LookAt(magic.Vector3(0, 1, 0))
-- And this thing so the camera is shown on the screen
local viewport = magic.Viewport:new(scene, camera_node:GetComponent("Camera"))
magic.set_preferred_viewports({viewport})

-- Add some text
local title_text = magic.ui.root:CreateChild("Text")
title_text:SetText("test1/init.lua")
title_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
title_text.horizontalAlignment = magic.HA_CENTER
title_text.verticalAlignment = magic.VA_CENTER
title_text:SetPosition(0, magic.ui.root.height*(-0.33))

-- Call client_lib_test module
-- This adds some text to the bottom right corner
client_lib_test.f()

the_box = nil

buildat.sub_packet("test1:add_box", function(data)
	local values = cereal.binary_input(data, {"object",
		{"w", "double"},
		{"h", "double"},
		{"d", "double"},
		{"x", "double"},
		{"y", "double"},
		{"z", "double"},
	})
	local w = values.w
	local h = values.h
	local d = values.d
	local x = values.x
	local y = values.y
	local z = values.z
	log:info("values="..dump(values))

	--
	-- Mission: Make a box
	--

	-- 1) Make the entity in the scene
	local node = scene:CreateChild("THE GLORIOUS BOX")
	the_box = node
	node.scale = magic.Vector3(w, h, d)
	node.position = magic.Vector3(x, y, z)

	-- 2) Create a StaticModel which kind of is what we need
	local object = node:CreateComponent("StaticModel")

	-- 3) First it needs a model. We could just load this binaray blob:
	object.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	assert(object.model)
	-- TODO: let's not. Let's generate some geometry!
	--[[local cc = CustomGeometry()
	cc.SetNumGeometries(1)
	cc.BeginGeometry(0, TRIANGLE_STRIP)
	cc.DefineVertex(]]

	-- 4) Create a material. Again we could just load it from a file:
	--object.material = magic.cache:GetResource("Material", "Materials/Stone.xml")
	-- ...but let's create a material ourselves:
	-- Call buildat.store_inifnitely() because deletion of it causes a crash
	object.material = magic.Material:new()
	-- We use this Diff.xml file to define that we want diffuse rendering. It
	-- doesn't make much sense to define it ourselves as it consists of quite many
	-- parameters:
	object.material:SetTechnique(0,
			magic.cache:GetResource("Technique", "Techniques/Diff.xml"))
	-- And load the texture from a file:
	object.material:SetTexture(magic.TU_DIFFUSE,
			magic.cache:GetResource("Texture2D", "test1/pink_texture.png"))

	object.castShadows = true

	--
	-- Make a non-useful but nice reply packet and send it to the server
	--

	values = {
		a = 128,
		b = 1000,
		c = 3.14,
		d = "Foo",
		e = {"Bar1", "Bar2"},
		f = {x=1, y=2},
	}
	data = cereal.binary_output(values, {"object",
		{"a", "byte"},
		{"b", "int32_t"},
		{"c", "double"},
		{"d", "string"},
		{"e", {"array", "string"}},
		{"f", {"object", {"x", "int32_t"}, {"y", "int32_t"}}}
	})
	buildat.send_packet("test1:box_added", data)

	-- Try deserializing it too and see if all is working
	values = cereal.binary_input(data, {"object",
		{"a", "byte"},
		{"b", "int32_t"},
		{"c", "double"},
		{"d", "string"},
		{"e", {"array", "string"}},
		{"f", {"object", {"x", "int32_t"}, {"y", "int32_t"}}}
	})
	assert(values.a == 128)
	assert(values.b == 1000)
	assert(values.c == 3.14)
	assert(values.d == "Foo")
	assert(values.e[2] == "Bar2")
	assert(values.f.y == 2)
end)

function move_box_by_user_input(dt)
    -- Do not move if the UI has a focused element (the console)
    if magic.ui.focusElement ~= nil then
        return
    end

    local MOVE_SPEED = 6.0
    local MOUSE_SENSITIVITY = 0.005

	if the_box then
		--local p = the_box.position
		--p.y = magic.Clamp(p.y - magic.input.mouseMove.y * MOUSE_SENSITIVITY, 0.5, 6)
		--the_box.position = p -- Needed?

		if magic.input:GetKeyDown(magic.KEY_UP) then
			the_box:Translate(magic.Vector3(-1.0, 0.0, 0.0) * MOVE_SPEED * dt)
		end
		if magic.input:GetKeyDown(magic.KEY_DOWN) then
			the_box:Translate(magic.Vector3(1.0, 0.0, 0.0) * MOVE_SPEED * dt)
		end
		if magic.input:GetKeyDown(magic.KEY_LEFT) then
			the_box:Translate(magic.Vector3(0.0, 0.0, -1.0) * MOVE_SPEED * dt)
		end
		if magic.input:GetKeyDown(magic.KEY_RIGHT) then
			the_box:Translate(magic.Vector3(0.0, 0.0, 1.0) * MOVE_SPEED * dt)
		end
	end
end

function handle_update(event_type, event_data)
	--log:info("handle_update() in test1/init.lua")
	local dt = event_data:GetFloat("TimeStep")
	--node:Rotate(Quaternion(50, 80*dt, 0, 0))
	move_box_by_user_input(dt)
end
magic.SubscribeToEvent("Update", "handle_update")

function handle_keydown(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESCAPE then
		log:info("KEY_ESCAPE pressed")
		buildat.leave()
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

-- vim: set noet ts=4 sw=4:
