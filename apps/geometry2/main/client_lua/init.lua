-- Buildat: geometry2/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
-- Copyright 2014 Břetislav Štec <valsiterb@gmail.com>
local log = buildat.Logger("geometry2")
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
title_text:SetText("geometry2/init.lua")
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

local voxel_reg = buildat.createVoxelRegistry()
voxel_reg:set_format("blocks")
local atlas_reg = buildat.createAtlasRegistry()
do
	local vdef = buildat.VoxelDefinition()
	vdef.name.block_name = "empty"
	vdef.name.segment_x = 0
	vdef.name.segment_y = 0
	vdef.name.segment_z = 0
	vdef.name.rotation_primary = 0
	vdef.name.rotation_secondary = 0
	vdef.handler_module = ""
	vdef.edge_material_id = buildat.VoxelDefinition.EDGEMATERIALID_EMPTY
	vdef.physically_solid = true
	voxel_reg:add_voxel(vdef)
end
do
	local vdef = buildat.VoxelDefinition()
	vdef.name.block_name = "foo"
	vdef.name.segment_x = 0
	vdef.name.segment_y = 0
	vdef.name.segment_z = 0
	vdef.name.rotation_primary = 0
	vdef.name.rotation_secondary = 0
	vdef.handler_module = ""
	local textures = {}
	for i = 1, 6 do
		local seg = buildat.AtlasSegmentDefinition()
		seg.resource_name = "main/green_texture.png"
		seg.total_segments = magic.IntVector2(1, 1)
		seg.select_segment = magic.IntVector2(0, 0)
		table.insert(textures, seg)
	end
	vdef.textures = textures
	vdef.edge_material_id = buildat.VoxelDefinition.EDGEMATERIALID_GROUND
	vdef.physically_solid = true
	voxel_reg:add_voxel(vdef)
end
do
	local vdef = buildat.VoxelDefinition()
	vdef.name.block_name = "bar"
	vdef.name.segment_x = 0
	vdef.name.segment_y = 0
	vdef.name.segment_z = 0
	vdef.name.rotation_primary = 0
	vdef.name.rotation_secondary = 0
	vdef.handler_module = ""
	local textures = {}
	for i = 1, 6 do
		local seg = buildat.AtlasSegmentDefinition()
		seg.resource_name = "main/pink_texture.png"
		seg.total_segments = magic.IntVector2(1, 1)
		seg.select_segment = magic.IntVector2(0, 0)
		table.insert(textures, seg)
	end
	vdef.textures = textures
	vdef.edge_material_id = buildat.VoxelDefinition.EDGEMATERIALID_GROUND
	vdef.physically_solid = true
	voxel_reg:add_voxel(vdef)
end

function setup_simple_voxel_data(node)
	--buildat.set_simple_voxel_model(node, 3, 3, 3, "010111010111111111010111010")
	--node:SetScale(magic.Vector3(0.5, 0.5, 0.5))
	--buildat.set_simple_voxel_model(node, 2, 2, 2, "11101111")
	--node:SetScale(magic.Vector3(1, 1, 1))
	--buildat.set_simple_voxel_model(node, 1, 1, 1, "1")
	--node:SetScale(magic.Vector3(2, 2, 2))

	-- Should be something like "11101111"
	local data = node:GetVar("simple_voxel_data"):GetBuffer()
	local w = node:GetVar("simple_voxel_w"):GetInt()
	local h = node:GetVar("simple_voxel_h"):GetInt()
	local d = node:GetVar("simple_voxel_d"):GetInt()
	log:info(dump(node:GetName()).." voxel data size: "..data:GetSize())
	buildat.set_8bit_voxel_geometry(node, w, h, d, data, voxel_reg, atlas_reg)

	--local object = node:GetComponent("StaticModel")
	--object.castShadows = true
end

replicate.sub_sync_node_added({}, function(node)
	if not node:GetVar("simple_voxel_data"):IsEmpty() then
		setup_simple_voxel_data(node)
	end
	local name = node:GetName()
	--[[if name == "Testbox" then
		local object = node:CreateComponent("StaticModel")
		object.model = magic.cache:GetResource("Model", "Models/Box.mdl")
		object.material = magic.Material:new()
		object.material:SetTechnique(0,
				magic.cache:GetResource("Technique", "Techniques/Diff.xml"))
		object.material:SetTexture(magic.TU_DIFFUSE,
				magic.cache:GetResource("Texture2D", "main/pink_texture.png"))
		object.castShadows = true
	end]]
end)

-- vim: set noet ts=4 sw=4:
