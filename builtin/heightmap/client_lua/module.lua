-- Buildat: builtin/heightmap/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [HEIGHTMAP_TERRAIN] The client half: the map's rectangles as the server
-- sends them (builtin/heightmap/api.h says the format), and one Urho3D
-- Terrain in the replicated scene built from them -- LOD per 64-sample
-- patch, splatted by heightmap/HeightmapBlend.xml from up to four RGBA
-- weight textures over a texture array of ground textures, a layer a
-- material. The server loads this module itself when the peer joins the
-- scene; a game requires it to read heights or to swap the textures.
--
--   M.node, M.terrain          once built (nil before)
--   M.height_at(x, z)          the surface's height at a world point
--   M.sub_built(cb)            cb() once the map is first built
--   M.version                  counts the builds and edits applied
--   M.grid()                   origin_x, origin_z, cell, sx, sz: sample
--                              (i, k) at (origin_x + i * cell, origin_z +
--                              k * cell), i 0...sx - 1, k 0...sz - 1
--   M.sample_height(i, k)      a sample's height, as fast as Lua indexes
--                              ([KIT_PLAN_CAPS]: height_at's sandbox calls
--                              were most of the plan's caps' time)
--   M.sample_material(i, k)    the material (1...) weighing most there
--   M.textures                 the ground textures, a material each in
--                              order, before building: one size, RGBA; a
--                              map of more materials than listed repeats
--                              the last
--   M.detail_metres            how many metres a ground texture spans
--   M.filter                   the ground textures' filter mode
--                              (magic.FILTER_*; nil: Urho3D's default),
--                              before building: FILTER_NEAREST for pixel
--                              art as voxels draw it
--
-- [HEIGHTMAP_REST] An edit is a rectangle: written into the height image
-- and the weight images where it is (image_set_region), the Terrain given
-- its image again (Urho3D rebuilds the patches whose heights differ), and
-- the rectangle alone uploaded to each weight texture (texture_set_region).
local log = buildat.Logger("heightmap")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")

local M = {}

M.textures = {"heightmap/grass.png", "heightmap/rock.png",
		"heightmap/sand.png", "heightmap/dirt.png", "heightmap/gravel.png"}
M.detail_metres = 4
M.node = nil
M.terrain = nil
M.version = 0

-- {chunks_x, chunks_z, chunk_size, cell, base_y, step, materials, planes,
-- sx, sz}
local info = nil
local ready = false
local built_cbs = {}
-- (sx + 1) x (sz + 1): a vertex more each way, the last row and column the
-- one before again, the top row the largest z (Terrain reads it upside down)
local height_img = nil
local hrows = {}
local weight_imgs = {}
local weight_texs = {}
-- What arrived since the last build: the image rectangles {x0, y0, x1, y1}
-- written, the regions and their bytes, the microseconds spent on them
local changed = {}
local got = {regions = 0, bytes = 0, us = 0}

local function blank_image(comps)
	local img = magic.Image:new()
	magic.image_set_data(img, info.sx + 1, info.sz + 1, comps,
			string.rep("\0", (info.sx + 1) * (info.sz + 1) * comps))
	return img
end

buildat.sub_packet("heightmap:init", function(data)
	-- [KIT_HM_ORIGIN] then the origin (sample (0, 0)'s world x, z) where
	-- it is not the scene's
	local v, cx, cz, cs, cell, base, step, n, rest = data:match(
			"^(%S+) (%d+) (%d+) (%d+) (%S+) (%S+) (%S+) (%d+)(.*)$")
	local ox, oz = (rest or ""):match("^ (%S+) (%S+)$")
	if v ~= "2" then
		log:error("heightmap:init of a format this does not read: "..
				tostring(data):sub(1, 40))
		return
	end
	if M.node then
		-- simplified: one map a client; a second replaces the first
		M.node:Remove()
		M.node, M.terrain = nil, nil
	end
	info = {chunks_x = tonumber(cx), chunks_z = tonumber(cz),
			chunk_size = tonumber(cs), cell = tonumber(cell),
			base_y = tonumber(base), step = tonumber(step),
			materials = tonumber(n), origin_x = tonumber(ox) or 0,
			origin_z = tonumber(oz) or 0}
	info.planes = math.ceil(info.materials / 4)
	info.sx = info.chunks_x * info.chunk_size
	info.sz = info.chunks_z * info.chunk_size
	height_img = blank_image(2)
	-- The heights again as a string a row (k), two bytes a sample, high
	-- first (the image's red and green)
	hrows = {}
	for k = 0, info.sz - 1 do
		hrows[k] = string.rep("\0", info.sx * 2)
	end
	weight_imgs, weight_texs = {}, {}
	for p = 1, info.planes do
		weight_imgs[p] = blank_image(4)
	end
	ready = false
	changed = {}
	got = {regions = 0, bytes = 0, us = 0}
end)

-- A w x h rectangle of samples at (x0, z0), comps bytes a sample, into an
-- image: its rows turned over, and the copied last row and column where it
-- reaches them
local function write_rect(img, comps, x0, z0, w, h, bytes)
	local sx, sz = info.sx, info.sz
	magic.image_set_region(img, x0, sz - (z0 + h - 1), w, h, bytes, true)
	if x0 + w == sx then
		local col = {}
		for r = 0, h - 1 do
			local o = (r * w + w - 1) * comps
			col[h - r] = bytes:sub(o + 1, o + comps)
		end
		magic.image_set_region(img, sx, sz - (z0 + h - 1), 1, h,
				table.concat(col))
	end
	if z0 + h == sz then
		local last = bytes:sub((h - 1) * w * comps + 1, h * w * comps)
		if x0 + w == sx then
			last = last..last:sub(-comps)
		end
		magic.image_set_region(img, x0, 0, #last / comps, 1, last)
	end
end

buildat.sub_packet("heightmap:region", function(data)
	if not info or #data < 10 then
		return
	end
	local t0 = buildat.get_time_us()
	local a, b, c, d, e, f, g, h = data:byte(1, 8)
	local x0, z0, w, hh = a * 256 + b, c * 256 + d, e * 256 + f, g * 256 + h
	if w < 1 or hh < 1 or x0 + w > info.sx or z0 + hh > info.sz or
			data:byte(9) ~= 2 then
		log:warning("heightmap:region ("..x0..", "..z0..", "..w..", "..hh..
				") not read")
		return
	end
	local raw = buildat.decompress(data:sub(10), "zstd")
	local n = w * hh
	if #raw ~= n * (2 + 4 * info.planes) then
		log:warning("heightmap:region ("..x0..", "..z0..") is "..#raw..
				" bytes, not "..(n * (2 + 4 * info.planes)))
		return
	end
	write_rect(height_img, 2, x0, z0, w, hh, raw:sub(1, n * 2))
	for r = 0, hh - 1 do
		local row = hrows[z0 + r]
		hrows[z0 + r] = row:sub(1, x0 * 2) ..
				raw:sub(r * w * 2 + 1, (r + 1) * w * 2) .. row:sub((x0 + w) * 2 + 1)
	end
	for p = 1, info.planes do
		local o = n * 2 + (p - 1) * n * 4
		write_rect(weight_imgs[p], 4, x0, z0, w, hh, raw:sub(o + 1, o + n * 4))
	end
	-- The image rectangle that changed, the copies included
	changed[#changed + 1] = {x0, z0 + hh == info.sz and 0 or
			info.sz - (z0 + hh - 1), x0 + w - 1 + (x0 + w == info.sx and 1 or 0),
			info.sz - z0}
	got.regions = got.regions + 1
	got.bytes = got.bytes + #data
	got.us = got.us + buildat.get_time_us() - t0
end)

buildat.sub_packet("heightmap:ready", function(data)
	ready = true
end)

-- The server deleted the map
buildat.sub_packet("heightmap:remove", function(data)
	if M.node then
		M.node:Remove()
	end
	M.node, M.terrain, info, ready = nil, nil, nil, false
	changed = {}
	M.version = M.version + 1
	log:info("heightmap: removed")
end)

local function create()
	M.node = replicate.main_scene:CreateChild("heightmap")
	M.node.position = magic.Vector3(info.origin_x + info.sx * info.cell / 2,
			info.base_y, info.origin_z + info.sz * info.cell / 2)
	M.terrain = M.node:CreateComponent("Terrain")
	M.terrain.patchSize = 64
	M.terrain:SetSpacing(magic.Vector3(info.cell, info.step * 256, info.cell))
	M.terrain:SetCastShadows(true)
	local material = magic.Material:new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"heightmap/HeightmapBlend.xml"))
	for p = 1, info.planes do
		weight_texs[p] = magic.Texture2D:new()
		weight_texs[p]:SetData(weight_imgs[p])
		material:SetTexture(p - 1, weight_texs[p])
	end
	local layers = magic.Texture2DArray:new()
	if M.filter then
		layers.filterMode = M.filter
	end
	layers:SetLayers(info.materials)
	for i = 1, info.materials do
		local name = M.textures[math.min(i, #M.textures)]
		local img = magic.cache:GetResource("Image", name)
		if not img or not layers:SetData(i - 1, img) then
			log:error("heightmap: the ground texture "..tostring(name)..
					" did not load into the array (one size, RGBA)")
		end
	end
	material:SetTexture(4, layers)
	material:SetShaderParameter("NumMaterials", info.materials)
	material:SetShaderParameter("DetailTiling", magic.Vector2(
			info.sx * info.cell / M.detail_metres,
			info.sz * info.cell / M.detail_metres))
	M.terrain.material = material
end

local function build()
	local t0 = buildat.get_time_us()
	local first = M.node == nil
	if first then
		create()
	else
		for _, r in ipairs(changed) do
			for p = 1, info.planes do
				magic.texture_set_region(weight_texs[p], weight_imgs[p],
						r[1], r[2], r[3] - r[1] + 1, r[4] - r[2] + 1)
			end
		end
	end
	-- simplified: Urho3D reads the whole image again and compares it, the
	-- most of an edit's time (12 ms of a crater's 12.4 in a debug build);
	-- a Terrain method taking the rectangle would skip the compare
	M.terrain:SetHeightMap(height_img)
	local ms = (got.us + buildat.get_time_us() - t0) / 1000
	if first then
		log:info(string.format("heightmap: terrain built: %dx%d samples, %d"..
				" materials, %d regions, %d bytes, %.0f ms", info.sx, info.sz,
				info.materials, got.regions, got.bytes, ms))
		for _, cb in ipairs(built_cbs) do
			cb()
		end
	else
		log:info(string.format("heightmap: terrain updated: %d regions, %d"..
				" bytes, %.1f ms", got.regions, got.bytes, ms))
	end
	changed = {}
	got = {regions = 0, bytes = 0, us = 0}
	M.version = M.version + 1
end

magic.SubscribeToEvent("Update", function(event_type, event_data)
	if ready and info and #changed > 0 then
		build()
	end
end)

-- What texture_set_region wrote is gone after a device reset; the images
-- have it all
magic.SubscribeToEvent("ScreenMode", function(event_type, event_data)
	for p, tex in ipairs(weight_texs) do
		tex:SetData(weight_imgs[p])
	end
end)

function M.height_at(x, z)
	if not M.terrain then
		return nil
	end
	return M.terrain:GetHeight(magic.Vector3(x, 0, z))
end

function M.grid()
	if not M.terrain then
		return nil
	end
	return info.origin_x, info.origin_z, info.cell, info.sx, info.sz
end

function M.sample_height(i, k)
	local a, b = hrows[k]:byte(i * 2 + 1, i * 2 + 2)
	return info.base_y + (a * 256 + b) * info.step
end

function M.sample_material(i, k)
	-- The images' rows turned over (write_rect's)
	local best, bw = 1, -1
	for p = 1, info.planes do
		local c = weight_imgs[p]:GetPixel(i, info.sz - k)
		local w = {c.r, c.g, c.b, c.a}
		for j = 1, 4 do
			local m = (p - 1) * 4 + j
			if m <= info.materials and w[j] > bw then
				best, bw = m, w[j]
			end
		end
	end
	return best
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
