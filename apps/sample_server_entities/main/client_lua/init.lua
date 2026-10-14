-- Buildat: sample_server_entities/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
-- Copyright 2014 Břetislav Štec <valsiterb@gmail.com>
local log = buildat.Logger("sample_server_entities")
local dump = buildat.dump
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")

local scene = replicate.main_scene

-- Add a camera so we can look at the scene
local camera_node = scene:CreateChild("Camera")
camera_node:CreateComponent("Camera")
camera_node.position = magic.Vector3(7.0, 7.0, 7.0)
camera_node:LookAt(magic.Vector3(0, 1, 0))

-- And this thing so the camera is shown on the screen
local viewport = magic.Viewport:new(scene, camera_node:GetComponent("Camera"))
magic.set_preferred_viewports({viewport})

-- Add some text
local title_text = magic.ui.root:CreateChild("Text")
title_text:SetText("sample_server_entities/init.lua")
title_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
title_text.horizontalAlignment = magic.HA_CENTER
title_text.verticalAlignment = magic.VA_CENTER
title_text:SetPosition(0, magic.ui.root.height*(-0.33))

magic.ui:SetFocusElement(nil)

function handle_keydown(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESCAPE then
		log:info("KEY_ESCAPE pressed")
		buildat.leave()
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

replicate.sub_sync_node_added({}, function(node)
	local name = node:GetName()
	if name == "Box" then
		-- Models and materials can be created dynamically on the client side
		-- like this
		local object = node:CreateComponent("StaticModel")
		object.model = magic.cache:GetResource("Model", "Models/Box.mdl")
		object.material = magic.Material:new()
		object.material:SetTechnique(0,
				magic.cache:GetResource("Technique", "Techniques/Diff.xml"))
		object.material:SetTexture(magic.TU_DIFFUSE,
				magic.cache:GetResource("Texture2D", "main/pink_texture.png"))
		object.castShadows = true
	end
end)

-- vim: set noet ts=4 sw=4:
