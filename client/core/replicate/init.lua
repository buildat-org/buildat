-- Buildat: extension/replicate/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/replicate")
local magic = require("buildat/core/urho3d").safe
local dump = buildat.dump
local M = {safe = {}}

-- __buildat_replicated_scene is set by client/replication.lua
M.unsafe_main_scene = __buildat_replicated_scene
M.safe.main_scene = getmetatable(magic.Scene).wrap(__buildat_replicated_scene)

local sync_node_added_subs = {}
local sync_node_removed_subs = {}

-- The scene emptied and the subscribers forgotten: a connection left
-- ([MENU_CONTEXT]); the next one fills it again
function M.reset()
	sync_node_added_subs = {}
	sync_node_removed_subs = {}
	__buildat_replicated_scene:RemoveAllChildren()
end

-- Callback will be called for each node added to the scene.
-- Callback is called immediately for all existing nodes.
function M.safe.sub_sync_node_added(opts, cb)
	-- Add to subscriber table
	table.insert(sync_node_added_subs, cb)
	-- Handle existing nodes
	local function handle_node(node)
		local name = node:GetName()
		--log:debug("sub_sync_node_added(): node "..node:GetID()..", name="..name)
		cb(node)
		for i = 0, node:GetNumChildren()-1 do
			handle_node(node:GetChild(i))
		end
	end
	-- Handle existing nodes starting from the scene
	local scene = M.safe.main_scene
	handle_node(scene)
end

function M.safe.sub_sync_node_removed(cb)
	table.insert(sync_node_removed_subs, cb)
end

-- Override dummy default
function __buildat_replicate_on_node_created(node_id)
	log:debug("__buildat_replicate_on_node_created(): id="..node_id)
	local node = M.safe.main_scene:GetNode(node_id)
	if not node then
		return
	end
	for _, v in ipairs(sync_node_added_subs) do
		v(node)
	end
end

function __buildat_replicate_on_node_removed(node_id)
	log:debug("__buildat_replicate_on_node_removed(): id="..node_id)
	local node = M.safe.main_scene:GetNode(node_id)
	for _, v in ipairs(sync_node_removed_subs) do
		v(node, node_id)
	end
end

return M
-- vim: set noet ts=4 sw=4:
