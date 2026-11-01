-- Buildat: apps/sample_kit/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [KIT] sample_kit's client: keys that act on Kit's entities, and the
-- shared state Kit replicates, logged as it changes.
--   b: use the button (3)        f: use the far button (6, out of range)
--   r: use the runaway (7)       c: use the counter (5, not usable)
--   d: dig at the door           s: packets that try to fire signals
--   p: dig the pillar (a build: Stop discards it)
--   e: use the faulty one (10, an error in its Lua)
--   h: use the second runaway (11)
--   u: use the entity last selected in Kit's editor (F6 or "Edit")
--   x: a packet of each kind of edit (refused without edit rights)
--   g: a grant of edit rights (refused but to the server's admin)
--   l: log in (builtin/accounts' dialog)
local log = buildat.Logger("sample_kit")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")

local scene = replicate.main_scene
local camera_node = scene:CreateChild("Camera")
camera_node:CreateComponent("Camera")
camera_node.position = magic.Vector3(2, 4, -6)
camera_node:LookAt(magic.Vector3(2, 1, 0))
magic.set_preferred_viewports({magic.Viewport:new(scene,
		camera_node:GetComponent("Camera"))})
-- Kit's editor ([KIT] stage 3): the server's admin and its builders edit.
-- A login by builtin/accounts: "l", or at once where BUILDAT_JOIN_NAME
-- names one; else a player plays as "p<peer>"
local logging_in = false
local function log_in()
	if logging_in then
		return
	end
	logging_in = true
	local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
	assert(type(accounts) == "table", "accounts.lua: " .. tostring(err))
	accounts.start({title = "sample_kit"})
end
if buildat.get_env("BUILDAT_JOIN_NAME") then
	log_in()
end
-- The world's voxels, which the editor points at, in a plain light
local voxelworld = require("buildat/module/voxelworld")
voxelworld.set_camera(camera_node)
do
	local zone = scene:CreateChild("Zone"):CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = magic.Color(0.5, 0.5, 0.55)
	zone.fogColor = magic.Color(0.25, 0.3, 0.4)
	local sun = scene:CreateChild("Sun")
	sun.direction = magic.Vector3(-0.5, -1.0, 0.7)
	local light = sun:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
end
local kit = require("buildat/module/kit")
kit.editor{scene = scene, camera = camera_node, ground_y = 1,
	solid = function(x, y, z)
		-- 0: not there, 1: air
		-- the id's bits only ([KIT_VOXEL_FORMAT]: param, tint and light
		-- above)
		return voxelworld.get_voxel_registry():id_of(
				voxelworld.get_static_voxel(magic.Vector3(x, y, z))) > 1
	end}

local KEYS = {
	[magic.KEY_B] = function() buildat.send_packet("kit:use", "3") end,
	[magic.KEY_F] = function() buildat.send_packet("kit:use", "6") end,
	[magic.KEY_R] = function() buildat.send_packet("kit:use", "7") end,
	[magic.KEY_C] = function() buildat.send_packet("kit:use", "5") end,
	[magic.KEY_E] = function() buildat.send_packet("kit:use", "10") end,
	[magic.KEY_H] = function() buildat.send_packet("kit:use", "11") end,
	[magic.KEY_D] = function() buildat.send_packet("main:dig", "") end,
	[magic.KEY_P] = function()
		buildat.send_packet("main:dig", "pillar")
		log:info("a dig at the pillar sent")
	end,
	-- Every kind of edit, as packets, whatever edit mode says: a player
	-- without edit rights is refused each
	[magic.KEY_X] = function()
		for _, e in ipairs({
			'{"op": "mode", "on": true}',
			'{"op": "place", "type": "button", "pos": [0, 1, -1]}',
			'{"op": "move", "id": 3, "pos": [0, 1, -1]}',
			'{"op": "delete", "id": 3}',
			'{"op": "set", "id": 4, "comp": 0, "param": "closed", "value": "air"}',
			'{"op": "link", "id": 3, "comp": 0, "output": "pressed", "to": 5, "input": "count"}',
			'{"op": "unlink", "id": 3, "comp": 0, "output": "pressed", "to": 4, "input": "toggle"}',
			'{"op": "undo"}',
			'{"op": "restart", "id": 3, "comp": 0}',
			'{"op": "save_prefab", "ids": [3, 4], "name": "pair"}',
			'{"op": "place", "prefab": "kit/button_door", "pos": [0, 1, -1]}',
			'{"op": "builder", "name": "kitbob", "on": true}',
			'not json'}) do
			buildat.send_packet("kit:edit", e)
		end
		log:info("sent the edit packets")
	end,
	[magic.KEY_L] = log_in,
	-- A grant of edit rights, which only the server's admin makes
	[magic.KEY_G] = function()
		buildat.send_packet("kit:edit",
				'{"op": "builder", "name": "kitboss", "on": false}')
	end,
	-- The entity last selected in the editor
	[magic.KEY_U] = function()
		buildat.send_packet("kit:use", tostring(kit.selected()))
	end,
	[magic.KEY_S] = function()
		-- There is no packet that fires a signal: these go nowhere
		buildat.send_packet("kit:signal", '{"to": 5, "input": "count"}')
		buildat.send_packet("kit:input", '{"to": 4, "input": "toggle"}')
		buildat.send_packet("kit:emit", '{"from": 3, "output": "pressed"}')
		log:info("sent the signal packets")
	end,
}
magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	-- Text typed in a field (the login's, the inspector's) is no key here
	local f = magic.ui.focusElement
	if f ~= nil and f:GetTypeName() == "LineEdit" then
		return
	end
	if key == magic.KEY_ESCAPE then
		buildat.leave()
	elseif KEYS[key] then
		KEYS[key]()
	end
end)

-- Kit's nodes: "kit:<id>", a shared state value in the var "kit:<key>"
local NAMES = {"open", "presses"}
local seen = {}
local nodes = {}
replicate.sub_sync_node_added({}, function(node)
	if node:GetName():sub(1, 4) == "kit:" then
		table.insert(nodes, node)
	end
end)
magic.SubscribeToEvent("Update", function()
	for _, node in ipairs(nodes) do
		local name = node:GetName()
		do
			for _, k in ipairs(NAMES) do
				local v = node:GetVar("kit:" .. k)
				if not v:IsEmpty() then
					local s = v:GetString()
					local key = name .. "/" .. k
					if seen[key] ~= s then
						seen[key] = s
						log:info("replicated: entity " .. name:sub(5) .. " " ..
								k .. " = " .. s)
					end
				end
			end
		end
	end
end)
-- vim: set noet ts=4 sw=4:
