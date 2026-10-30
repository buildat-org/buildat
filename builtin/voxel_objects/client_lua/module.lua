-- Buildat: builtin/voxel_objects/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [VOXEL_OBJECTS] The client half: the models' chunks as the server sends
-- them (builtin/voxel_objects/api.h says the format), each meshed once on
-- a hidden template node with voxelworld's registries, as a world's chunk
-- is (the same atlas, the corners' occlusion baked into the vertex
-- colours, lit by the scene's lights); every object of the model draws the
-- template's geometry through a StaticModel on a child node a chunk
-- (buildat.share_geometry): one mesh a chunk however many copies. The
-- server loads this module itself when the peer joins the scene; a game
-- requires it to set the look or to read the counts.
--
--   M.set_material_cb(cb)   cb(node) sets up a template's materials after
--                           each mesh, as voxelworld.sub_material_update's
--                           (voxel_shading.apply_to_node for a PBR world's
--                           look); by default VoxelObject.xml, lit by the
--                           scene's lights
--   M.counts()              {models, meshes, objects, chunk_nodes}
--   M.sub_meshed(cb)        cb(model_name, rev, cx, cy, cz) after a
--                           chunk's mesh reached its objects
local log = buildat.Logger("voxel_objects")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")

local M = {}

-- The default look: the scene's lights, the ambient by the mesher's vertex
-- colour (VoxelObject.glsl); the translucent and cut-out faces the mesher
-- put on the "alpha" and "masked" children their own variants
local TECHNIQUES = {[""] = "voxel_objects/VoxelObject.xml",
		alpha = "voxel_objects/VoxelObjectAlpha.xml",
		masked = "voxel_objects/VoxelObjectMasked.xml"}
local function default_material(node)
	for child, name in pairs(TECHNIQUES) do
		local n = child == "" and node or node:GetChild(child)
		local cg = n and n:GetComponent("CustomGeometry")
		local technique = magic.cache:GetResource("Technique", name)
		local i = 0
		while cg and cg:GetMaterial(i) do
			cg:GetMaterial(i):SetTechnique(0, technique)
			i = i + 1
		end
	end
end
local material_cb = default_material

function M.set_material_cb(cb)
	material_cb = cb or default_material
end

local meshed_cbs = {}
function M.sub_meshed(cb)
	table.insert(meshed_cbs, cb)
end

-- name -> {sx, sy, sz, chunk, chunks = {key -> chunk}}; a chunk is
-- {cx, cy, cz, data, rev, node (the template), busy, again}
local models = {}
-- node id -> model name
local objects = {}
local ready = false
local root = nil

local function chunk_key(cx, cy, cz)
	return cx..","..cy..","..cz
end

-- Where a chunk's mesh sits in its object: the mesher centres a volume on
-- its node, so the chunk's middle in the model's frame
local function chunk_offset(m, c)
	local ox, oy, oz = c.cx * m.chunk, c.cy * m.chunk, c.cz * m.chunk
	local w = math.min(m.chunk, m.sx - ox)
	local h = math.min(m.chunk, m.sy - oy)
	local d = math.min(m.chunk, m.sz - oz)
	return magic.Vector3(ox + w / 2, oy + h / 2, oz + d / 2)
end

-- An object's node for a chunk: drawing the template's mesh, or gone when
-- the chunk has none
local function attach(object, m, c)
	local name = "voxel_chunk_"..c.cx.."_"..c.cy.."_"..c.cz
	local child = object:GetChild(name)
	if not c.node or c.data == "" then
		if child then
			child:Remove()
		end
		return
	end
	if not child then
		child = object:CreateChild(name)
		child.position = chunk_offset(m, c)
	end
	buildat.share_geometry(c.node, child)
end

local function each_object_of(model_name, cb)
	for id, name in pairs(objects) do
		if name == model_name then
			local node = replicate.main_scene:GetNode(id)
			if node then
				cb(node)
			else
				objects[id] = nil
			end
		end
	end
end

local mesh_chunk

local function meshed(model_name, m, c, t0)
	-- The template is not drawn; its geometry is, through the objects
	c.node:SetDeepEnabled(false)
	local n = 0
	each_object_of(model_name, function(object)
		attach(object, m, c)
		n = n + 1
	end)
	log:info(string.format("voxel_objects: model %s rev %d chunk (%d,%d,%d)"..
			" meshed in %.1f ms, shared to %d objects", model_name, c.rev,
			c.cx, c.cy, c.cz, (buildat.get_time_us() - t0) / 1000, n))
	for _, cb in ipairs(meshed_cbs) do
		cb(model_name, c.rev, c.cx, c.cy, c.cz)
	end
	c.busy = false
	if c.again then
		c.again = false
		mesh_chunk(model_name, m, c)
	end
end

mesh_chunk = function(model_name, m, c)
	if not ready then
		return
	end
	if c.busy then
		-- The newest data is meshed once this one is done
		c.again = true
		return
	end
	if c.data == "" then
		if c.node then
			c.node:Remove()
			c.node = nil
		end
		each_object_of(model_name, function(object)
			attach(object, m, c)
		end)
		return
	end
	if not root then
		root = replicate.main_scene:CreateChild("voxel_object_meshes")
	end
	if not c.node then
		c.node = root:CreateChild(model_name.."_"..chunk_key(c.cx, c.cy, c.cz))
	end
	c.busy = true
	local t0 = buildat.get_time_us()
	local node = c.node
	buildat.set_voxel_geometry(node, c.data, voxelworld.get_voxel_registry(),
			voxelworld.get_atlas_registry(), true, function()
				material_cb(node)
				meshed(model_name, m, c, t0)
			end, nil, {x = c.cx * m.chunk, y = c.cy * m.chunk,
			z = c.cz * m.chunk})
end

buildat.sub_packet("voxel_objects:model", function(data)
	local v, name, sx, sy, sz, chunk = data:match(
			"^(%S+) (%S+) (%d+) (%d+) (%d+) (%d+)$")
	if v ~= "1" then
		log:error("voxel_objects:model of a format this does not read: "..
				tostring(data):sub(1, 60))
		return
	end
	sx, sy, sz, chunk = tonumber(sx), tonumber(sy), tonumber(sz),
			tonumber(chunk)
	local m = models[name]
	if m and m.sx == sx and m.sy == sy and m.sz == sz and m.chunk == chunk then
		return
	end
	if m then
		for _, c in pairs(m.chunks) do
			c.data = ""
			mesh_chunk(name, m, c)
		end
	end
	models[name] = {sx = sx, sy = sy, sz = sz, chunk = chunk, chunks = {}}
end)

buildat.sub_packet("voxel_objects:chunk", function(data)
	local nl = data:find("\n", 1, true)
	if not nl then
		return
	end
	local name, cx, cy, cz, rev = data:sub(1, nl - 1):match(
			"^(%S+) (%d+) (%d+) (%d+) (%d+)$")
	local m = name and models[name]
	if not m then
		log:warning("voxel_objects:chunk of no model: "..
				data:sub(1, math.min(nl, 60)))
		return
	end
	cx, cy, cz = tonumber(cx), tonumber(cy), tonumber(cz)
	local key = chunk_key(cx, cy, cz)
	local c = m.chunks[key]
	if not c then
		c = {cx = cx, cy = cy, cz = cz}
		m.chunks[key] = c
	end
	c.data = data:sub(nl + 1)
	c.rev = tonumber(rev)
	mesh_chunk(name, m, c)
end)

replicate.sub_sync_node_added({}, function(node)
	local name = node:GetVar("voxel_model"):GetString()
	if name == "" then
		return
	end
	objects[node:GetID()] = name
	local m = models[name]
	if m then
		for _, c in pairs(m.chunks) do
			if c.node and not c.busy then
				attach(node, m, c)
			end
		end
	end
end)

replicate.sub_sync_node_removed(function(node)
	objects[node:GetID()] = nil
end)

-- The registries are voxelworld's, there once it is ready
voxelworld.sub_ready(function()
	ready = true
	for name, m in pairs(models) do
		for _, c in pairs(m.chunks) do
			mesh_chunk(name, m, c)
		end
	end
end)

function M.counts()
	local r = {models = 0, meshes = 0, objects = 0, chunk_nodes = 0}
	for name, m in pairs(models) do
		r.models = r.models + 1
		for _, c in pairs(m.chunks) do
			if c.node then
				r.meshes = r.meshes + 1
			end
		end
	end
	for id, name in pairs(objects) do
		local node = replicate.main_scene:GetNode(id)
		if node then
			r.objects = r.objects + 1
			for i = 0, node:GetNumChildren() - 1 do
				if node:GetChild(i):GetName():sub(1, 12) == "voxel_chunk_" then
					r.chunk_nodes = r.chunk_nodes + 1
				end
			end
		end
	end
	return r
end

return M
-- vim: set noet ts=4 sw=4:
