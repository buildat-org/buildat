-- Buildat: builtin/heightmap/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [HEIGHTMAP_TERRAIN] The client half: the map's chunks as the server sends
-- them (builtin/heightmap/api.h says the format), and one Urho3D Terrain in
-- the replicated scene built from them -- LOD per 64-sample patch, splatted
-- by TerrainBlend from a weight texture over three ground textures. The
-- server loads this module itself when the peer joins the scene; a game
-- requires it to read heights or to swap the textures.
--
--   M.node, M.terrain          once built (nil before)
--   M.height_at(x, z)          the surface's height at a world point
--   M.sub_built(cb)            cb() once the map is first built
--   M.textures                 the three ground textures, before building
--   M.detail_metres            how many metres a ground texture spans
local log = buildat.Logger("heightmap")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")

local M = {}

M.textures = {"heightmap/grass.png", "heightmap/rock.png", "heightmap/sand.png"}
M.detail_metres = 4
M.node = nil
M.terrain = nil

-- {chunks_x, chunks_z, chunk_size, cell, base_y, step}
local info = nil
-- [cz * chunks_x + cx + 1] = {h = heights, w = weights}, raw
local chunks = {}
local ready = false
local dirty = {}
local built_cbs = {}
local height_img, weight_img, weight_tex

buildat.sub_packet("heightmap:init", function(data)
	local v, cx, cz, cs, cell, base, step = data:match(
			"^(%S+) (%d+) (%d+) (%d+) (%S+) (%S+) (%S+)$")
	if v ~= "1" then
		log:error("heightmap:init of a format this does not read: "..
				tostring(data):sub(1, 40))
		return
	end
	info = {chunks_x = tonumber(cx), chunks_z = tonumber(cz),
			chunk_size = tonumber(cs), cell = tonumber(cell),
			base_y = tonumber(base), step = tonumber(step)}
	chunks = {}
	ready = false
end)

buildat.sub_packet("heightmap:chunk", function(data)
	if not info or #data < 6 then
		return
	end
	local a, b, c, d = data:byte(1, 4)
	local cx, cz = a * 256 + b, c * 256 + d
	if cx >= info.chunks_x or cz >= info.chunks_z or data:byte(5) ~= 1 then
		log:warning("heightmap:chunk ("..cx..", "..cz..") not read")
		return
	end
	local raw = buildat.decompress(data:sub(6), "zstd")
	local n = info.chunk_size * info.chunk_size
	if #raw ~= n * 5 then
		log:warning("heightmap:chunk ("..cx..", "..cz..") is "..#raw..
				" bytes, not "..(n * 5))
		return
	end
	chunks[cz * info.chunks_x + cx + 1] = {h = raw:sub(1, n * 2),
			w = raw:sub(n * 2 + 1)}
	dirty[#dirty + 1] = true
end)

buildat.sub_packet("heightmap:ready", function(data)
	ready = true
end)

-- The (sx + 1) x (sz + 1) image the Terrain wants: a vertex more each way,
-- the last row and column the one before again, the top row the largest z
local function image_bytes(per, field)
	local cs = info.chunk_size
	local sz = info.chunks_z * cs
	local zero = string.rep("\0", cs * cs * per)
	local rows = {}
	for r = 0, sz do
		local z = math.min(sz - r, sz - 1)
		local cz, lz = math.floor(z / cs), z % cs
		local parts = {}
		for cx = 0, info.chunks_x - 1 do
			local c = chunks[cz * info.chunks_x + cx + 1]
			parts[cx + 1] = (c and c[field] or zero):sub(lz * cs * per + 1,
					(lz + 1) * cs * per)
		end
		parts[#parts + 1] = parts[#parts]:sub(-per)
		rows[r + 1] = table.concat(parts)
	end
	return table.concat(rows)
end

local function create()
	local sx = info.chunks_x * info.chunk_size
	local sz = info.chunks_z * info.chunk_size
	M.node = replicate.main_scene:CreateChild("heightmap")
	M.node.position = magic.Vector3(sx * info.cell / 2, info.base_y,
			sz * info.cell / 2)
	M.terrain = M.node:CreateComponent("Terrain")
	M.terrain.patchSize = 64
	M.terrain:SetSpacing(magic.Vector3(info.cell, info.step * 256, info.cell))
	M.terrain:SetCastShadows(true)
	height_img = magic.Image:new()
	weight_img = magic.Image:new()
	weight_tex = magic.Texture2D:new()
	local material = magic.Material:new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/TerrainBlend.xml"))
	material:SetTexture(0, weight_tex)
	for i, name in ipairs(M.textures) do
		material:SetTexture(i, magic.cache:GetResource("Texture2D", name))
	end
	material:SetShaderParameter("DetailTiling", magic.Vector2(
			sx * info.cell / M.detail_metres, sz * info.cell / M.detail_metres))
	M.terrain.material = material
end

-- simplified: the whole image is made again on a change and the Terrain
-- rebuilds the patches whose heights differ (Urho3D's own region check);
-- the weight texture is uploaded whole. A map edited every frame wants
-- the changed rows written into the images instead.
local function build()
	local t0 = buildat.get_time_us()
	local first = M.node == nil
	if first then
		create()
	end
	local sx = info.chunks_x * info.chunk_size
	local sz = info.chunks_z * info.chunk_size
	magic.image_set_data(height_img, sx + 1, sz + 1, 2, image_bytes(2, "h"))
	M.terrain:SetHeightMap(height_img)
	magic.image_set_data(weight_img, sx + 1, sz + 1, 3, image_bytes(3, "w"))
	weight_tex:SetData(weight_img)
	local ms = math.floor((buildat.get_time_us() - t0) / 1000)
	if first then
		log:info("heightmap: terrain built: "..sx.."x"..sz.." samples, "..
				(info.chunks_x * info.chunks_z).." chunks, "..ms.." ms")
		for _, cb in ipairs(built_cbs) do
			cb()
		end
	else
		log:info("heightmap: terrain updated: "..#dirty.." chunks, "..ms..
				" ms")
	end
	dirty = {}
end

magic.SubscribeToEvent("Update", function(event_type, event_data)
	if ready and info and #dirty > 0 then
		build()
	end
end)

function M.height_at(x, z)
	if not M.terrain then
		return nil
	end
	return M.terrain:GetHeight(magic.Vector3(x, 0, z))
end

function M.sub_built(cb)
	if M.terrain then
		cb()
	else
		table.insert(built_cbs, cb)
	end
end

return M
-- vim: set noet ts=4 sw=4:
