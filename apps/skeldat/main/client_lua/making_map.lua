-- Buildat: apps/skeldat/main/client_lua/making_map.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [SKELDAT_MAKING_MAP] The world's making seen from above, behind the
-- wait's stripes (world_menu's, ui_utils' load screen): a pixel a column,
-- the footprints the screen's dark until a section of them is in, then
-- black (the user's, 2026-10-18), then their map -- grass, water and the
-- rest, darker the lower -- +x right and +z up as map.png. The server runs this on a peer waiting
-- for the world and sends "skeldat:making_map" (making_map.h says what).
-- Written into the Image a footprint at a time, the texture filled from it
-- at most four times a second.
-- simplified: a 1024 world's map is a 1024 square texture; a bigger
-- world wants one downscaled by the server
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.safe or ui_utils
local log = buildat.Logger("skeldat")

local S = 64
local n, img, tex, update = nil, nil, nil, nil
-- The load screen's api, kept: load_screen() again would open a new one
-- once world_menu's wait has closed it
local screen = nil
local dirty, sent_us = false, 0

-- 0xAABBGGRR, as SetPixelInt() takes it
local function rgb(r, g, b)
	return 0xff000000 + math.floor(b) * 65536 + math.floor(g) * 256 +
			math.floor(r)
end
local BLACK = rgb(0, 0, 0)
-- terrain.h write_map()'s colours, by the class in a byte's high bits
local CLASS = {[1] = {60, 140, 60}, [2] = {40, 80, 200}, [3] = {128, 128, 128}}

-- Footprint (sx, sz)'s top left pixel
local function corner(sx, sz)
	return (sx + n / 2) * S, (n / 2 - 1 - sz) * S
end

local function fill(sx, sz, c)
	local x0, y0 = corner(sx, sz)
	for y = y0, y0 + S - 1 do
		for x = x0, x0 + S - 1 do
			img:SetPixelInt(x, y, c)
		end
	end
	dirty = true
end

local function draw_map(sx, sz, bytes)
	local x0, y0 = corner(sx, sz)
	for zi = 0, S - 1 do
		-- +z up: the footprint's least z at its bottom row
		local y = y0 + S - 1 - zi
		for xi = 0, S - 1 do
			local v = bytes:byte(zi * S + xi + 1) or 0
			local c = CLASS[math.floor(v / 64)]
			if c then
				local k = 0.35 + 0.65 * (v % 64) / 63
				img:SetPixelInt(x0 + xi, y, rgb(c[1] * k, c[2] * k, c[3] * k))
			else
				img:SetPixelInt(x0 + xi, y, BLACK)
			end
		end
	end
	dirty = true
end

local function upload()
	if dirty then
		tex:SetData(img)
		dirty = false
		sent_us = buildat.get_time_us()
	end
end

-- The world in: the last footprints (world_in()'s sweep, sent just
-- before this) drawn, and the map left on the screen until it closes,
-- the whole of it then
local function off()
	if update then
		magic.UnsubscribeFromEvent("Update", update)
		update = nil
	end
	if img then
		upload()
	end
	img, tex, n, screen = nil, nil, nil, nil
	log:info("making_map: off")
end

buildat.sub_packet("skeldat:making_map", function(data)
	local what, rest = data:match("^(%S+)%s*(.*)$")
	if what == "grid" then
		n = tonumber(rest)
		img = magic.Image:new()
		img:SetSize(n * S, n * S, 4)
		-- The load screen's own dark (0x15151a), not the stripes' lighter one
		img:Clear(magic.Color(0x15 / 255, 0x15 / 255, 0x1a / 255, 1))
		tex = magic.Texture2D:new()
		tex:SetData(img)
		screen = ui_utils.load_screen()
		screen.backdrop(tex)
		if not update then
			update = magic.SubscribeToEvent("Update", function()
				if img and buildat.get_time_us() - sent_us >= 250000 then
					upload()
				end
			end)
		end
		log:info("making_map: first packet, " .. n .. " x " .. n ..
				" footprints")
	elseif what == "off" then
		off()
	elseif not img then
		return
	elseif what == "loaded" then
		local sx, sz = rest:match("^(%-?%d+) (%-?%d+)")
		fill(tonumber(sx), tonumber(sz), BLACK)
	elseif what == "map" then
		local sx, sz, bytes = data:match("^map (%-?%d+) (%-?%d+)\n(.*)$")
		if bytes and #bytes == S * S then
			draw_map(tonumber(sx), tonumber(sz), bytes)
			log:info("making_map: footprint " .. sx .. " " .. sz .. " mapped")
		end
	end
end)
-- vim: set noet ts=4 sw=4:
