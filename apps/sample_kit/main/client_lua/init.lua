-- Buildat: apps/sample_kit/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [KIT] sample_kit's client: keys that act on Kit's entities, and the
-- shared state Kit replicates, logged as it changes.
--   b: use the button (3)        f: use the far button (6, out of range)
--   r: use the runaway (7)       c: use the counter (5, not usable)
--   d: dig at the door           s: packets that try to fire signals
--   e: use the faulty one (10, an error in its Lua)
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

local KEYS = {
	[magic.KEY_B] = function() buildat.send_packet("kit:use", "3") end,
	[magic.KEY_F] = function() buildat.send_packet("kit:use", "6") end,
	[magic.KEY_R] = function() buildat.send_packet("kit:use", "7") end,
	[magic.KEY_C] = function() buildat.send_packet("kit:use", "5") end,
	[magic.KEY_E] = function() buildat.send_packet("kit:use", "10") end,
	[magic.KEY_D] = function() buildat.send_packet("main:dig", "") end,
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
