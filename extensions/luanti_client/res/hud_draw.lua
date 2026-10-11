-- Buildat: extensions/luanti_client/res/hud_draw.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Shared by both Luanti clients ([LUANTI_SHARED]): the extension runs it as
-- res/hud_draw.lua and the luanti module serves it to vanilla's client as
-- luanti/hud_draw.lua.
--
-- The HUD a game draws itself, out of Urho3D's UI elements. Luanti's own
-- elements: an image, a line of text, a bar of icons, a row of an inventory,
-- a compass, a minimap. Where they go is `pos` as a fraction of the screen
-- plus `offset` in pixels, with `align` saying which corner of the element
-- lands there -- Luanti's drawLuaElements; hud.lua has that arithmetic.
-- A waypoint and an image_waypoint are not over a corner of the screen but
-- over a place in the world; the camera says where that is.
--
-- An element comes either as hud.lua reads it (arrays, type a number) or as
-- the luanti module hands it to vanilla (strings "x,y", type a name); both
-- are read into hud.lua's shape first.
--
-- new(magic, log, ctx) -> a renderer; ctx:
--   hud            the client's hud.lua (its scale_factor is set here)
--   formspec       the client's formspec.lua (split_colors, strip_escapes)
--   parent         the UI element the HUD goes under
--   scale()        Luanti's m_scale_factor in this UI's units
--   texture(name)  a game's texture expression -> a Texture2D or nil
--   font           the Font everything is written in
--   font_size      Luanti's default font size here (15)
-- and, each optional -- without one that kind is counted as not drawn:
--   inventory(list_name) -> {{texture =, count =}, ...} or nil
--   slots()        -> image size, padding, slot size (the hotbar's)
--   white          a plain white Texture2D, the inventory's squares
--   eye()          -> x, y, z of the camera, and screen_of(x, y, z) -> the
--                  pixel a world point is at, or nil behind the camera
--   yaw()          the camera's horizontal angle, for the compass
--   minimap(parent, w, h) -> a minimap.lua minimap
--   hud_flag(name) whether the game left that flag on
-- r:draw(elements) -> what was not drawn {kind = count}, and the image
--   elements' rectangles {name, x, y, w, h}
-- r:update(dt)     the waypoints, compasses and minimaps, once a frame
-- r.root, r.minimaps
--
-- simplified: the style field -- bold, italic, monospace -- is not read.
-- Everything is drawn in ctx.font, and bold and italic want font files the
-- clients do not ship.
local M = {}

-- Luanti's type numbers, hud.lua's ELEM, by the module's names
local KINDS = {[0] = "image", "text", "statbar", "inventory", "waypoint",
		"image_waypoint", "compass", "minimap", "hotbar"}

-- A two-number field either way: {x, y}, "x,y", or nil for the default
local function v2(f, dx, dy)
	if type(f) == "table" then
		return tonumber(f[1] or f.x) or dx, tonumber(f[2] or f.y) or dy
	end
	if type(f) == "string" then
		local x, y = string.match(f, "^([^,]*),(.*)$")
		return tonumber(x) or dx, tonumber(y) or dy
	end
	return dx, dy
end

local function v3(f)
	local x, y, z
	if type(f) == "table" then
		x, y, z = f[1] or f.x, f[2] or f.y, f[3] or f.z
	elseif type(f) == "string" then
		x, y, z = string.match(f, "^([^,]*),([^,]*),(.*)$")
	end
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if x == nil or y == nil or z == nil then
		return nil
	end
	return {x, y, z}
end

-- An element in hud.lua's shape, whichever it came as
function M.normalize(e)
	local kind = e.type
	if type(kind) == "number" then
		kind = KINDS[kind] or tostring(kind)
	end
	local p = function(f, dx, dy)
		local x, y = v2(f, dx, dy)
		return {x, y}
	end
	return {
		kind = kind or "text",
		pos = p(e.pos, 0, 0), offset = p(e.offset, 0, 0),
		align = p(e.align, 0, 0), scale = p(e.scale, 1, 1),
		size = p(e.size, 0, 0),
		number = math.floor(tonumber(e.number) or 0),
		number_set = tonumber(e.number) ~= nil,
		item = math.floor(tonumber(e.item) or 0),
		dir = math.floor(tonumber(e.dir) or 0),
		z_index = tonumber(e.z_index) or 0,
		text = e.text or "", text2 = e.text2 or "", name = e.name or "",
		world_pos = v3(e.world_pos),
	}
end

-- How wide a picture is for its height, which is what a compass strip is
-- scaled by
local function tex_aspect(tex)
	if tex == nil or tex.height == nil or tex.height <= 0 then
		return 1
	end
	return tex.width / tex.height
end

function M.new(magic, log, ctx)
	local hud, formspec = ctx.hud, ctx.formspec
	local self = {minimaps = {}}
	local root = ctx.parent:CreateChild("UIElement")
	root:SetPosition(0, 0)
	self.root = root
	local FONT_SIZE = ctx.font_size or 15
	local missing = {}
	local waypoints, compasses = {}, {}
	local sw, sh = 1, 1

	local function say_once(key, text)
		if not missing[key] then
			missing[key] = true
			log:info(text)
		end
	end

	local function color(n)
		local r, g, b, a = hud.color_of(n)
		return magic.Color(r / 255, g / 255, b / 255, a / 255)
	end

	-- What a missing texture is said as, once per name
	local function texture(name, what)
		local tex = name ~= "" and ctx.texture(name) or nil
		if not tex and name ~= "" then
			say_once(name, "the game's HUD wants " .. what .. " called \"" ..
					name .. "\", which is not there")
		end
		return tex
	end

	local function place(element, n, w, h)
		local x, y = hud.place(n, sw, sh, w, h)
		element:SetPosition(x, y)
		return x, y
	end

	-- A text block's lines, each in as many pieces as it has colours in it:
	-- a game writes core.colorize() into a HUD line and Luanti draws each
	-- piece in its own colour
	local function text_line(parent, line, base, size)
		local x, h = 0, 0
		for _, piece in ipairs(formspec.split_colors(line)) do
			local t = parent:CreateChild("Text")
			t:SetFont(ctx.font, size)
			t:SetTextEffect(magic.TE_SHADOW)
			t.effectColor = magic.Color(0, 0, 0, 0.85)
			t:SetText(formspec.strip_escapes(piece.text))
			local c = piece.color
			t.color = c and magic.Color(c.r, c.g, c.b) or base
			t:SetPosition(math.floor(x), 0)
			x = x + t.width
			h = math.max(h, t.height)
		end
		return x, h
	end

	local draw = {}

	-- Luanti multiplies its own default font size by size.X when that is
	-- set (hud.cpp, HUD_ELEM_TEXT), so this is what a game's
	-- `size = {x = 2}` comes to ([UI_PARITY])
	function draw.text(n)
		local base = color(n.number)
		local block = root:CreateChild("UIElement")
		local size = n.size[1] > 0 and math.floor(FONT_SIZE * n.size[1]) or
				FONT_SIZE
		local w, h = 0, 0
		local lines = {}
		for line in (n.text .. "\n"):gmatch("([^\n]*)\n") do
			local row = block:CreateChild("UIElement")
			local lw, lh = text_line(row, line, base, size)
			lines[#lines + 1] = {row, lw, math.floor(h)}
			w = math.max(w, lw)
			h = h + (lh > 0 and lh or size)
		end
		-- Each line aligned on its own about the point, as Luanti's
		-- (align - 1) * line width / 2 ([UI_PARITY] 9): inside the block
		-- that is its share of what it is short of the widest
		for _, l in ipairs(lines) do
			l[1]:SetPosition(math.floor((1 - n.align[1]) * (w - l[2]) / 2),
					l[3])
		end
		block.size = magic.IntVector2(math.floor(w), math.floor(h))
		place(block, n, w, h)
		return block
	end

	function draw.image(n, images)
		local tex = texture(n.text, "an image")
		if not tex then
			return
		end
		local w, h = hud.image_size(n, sw, sh, tex.width, tex.height)
		if w <= 0 or h <= 0 then
			return
		end
		local img = root:CreateChild("BorderImage")
		img.texture = tex
		img.size = magic.IntVector2(w, h)
		local x, y = place(img, n, w, h)
		images[#images + 1] = {name = n.text, x = x, y = y, w = w, h = h}
		return img
	end

	-- A row of icons, each whole or half: hearts, bubbles, a bar of armour.
	-- hud.lua's statbar_icons() is Luanti's drawStatbar(), which reads pos
	-- and offset and not align.
	function draw.statbar(n)
		local tex = texture(n.text, "an image")
		if not tex then
			return
		end
		local bg = n.text2 ~= "" and
				texture(n.text2, "a picture for what a bar has lost") or nil
		local icons = hud.statbar_icons(n, sw, sh, tex.width, tex.height,
				bg ~= nil)
		-- The row is as big as its icons, for the scan's rectangle
		local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
		for _, icon in ipairs(icons) do
			x0, y0 = math.min(x0, icon.x), math.min(y0, icon.y)
			x1 = math.max(x1, icon.x + icon.w)
			y1 = math.max(y1, icon.y + icon.h)
		end
		if #icons == 0 then
			return
		end
		x0, y0 = math.floor(x0), math.floor(y0)
		say_once(("statbar %s %d %d %d"):format(n.text, x0, x1, sw),
				("hud: statbar %s from %d to %d of %d"):format(n.text, x0,
						math.floor(x1), sw))
		local row = root:CreateChild("UIElement")
		row:SetPosition(x0, y0)
		row.size = magic.IntVector2(math.floor(x1) - x0, math.floor(y1) - y0)
		for _, icon in ipairs(icons) do
			local t = icon.bg and bg or tex
			local el = row:CreateChild("BorderImage")
			el:SetPosition(math.floor(icon.x) - x0, math.floor(icon.y) - y0)
			el.size = magic.IntVector2(math.floor(icon.w), math.floor(icon.h))
			el.texture = t
			el.imageRect = magic.IntRect(
					math.floor(icon.src[1] * t.width),
					math.floor(icon.src[2] * t.height),
					math.floor(icon.src[3] * t.width),
					math.floor(icon.src[4] * t.height))
		end
		return row
	end

	-- A row of the player's own inventory, which is what a game that draws
	-- its own hotbar puts on the HUD: number is how many of the list's slots
	-- to draw and item is the one to mark. Luanti's drawItems() draws it
	-- with the hotbar's own numbers and does not read the element's size.
	function draw.inventory(n)
		if not ctx.inventory then
			return false
		end
		local stacks = ctx.inventory(n.text)
		if stacks == nil then
			say_once("inv:" .. n.text, "the game's HUD wants the " ..
					"inventory list \"" .. n.text .. "\", which this " ..
					"player has not got")
			return
		end
		local count = n.number_set and math.min(n.number, #stacks) or #stacks
		if count <= 0 then
			return
		end
		local imagesize, padding, slot = ctx.slots()
		-- Luanti's dir: 0 right, 1 left, 2 down, 3 up
		local dir = n.dir
		local row = root:CreateChild("UIElement")
		for i = 1, count do
			local frame = row:CreateChild("BorderImage")
			if ctx.white then
				frame.texture = ctx.white
			end
			frame.color = (i == n.item) and
					magic.Color(0.9, 0.9, 0.7, 0.75) or
					magic.Color(0.1, 0.1, 0.12, 0.55)
			frame.size = magic.IntVector2(slot, slot)
			-- A row that runs the other way is the same squares in the
			-- other order, which is what drawItems() does
			local at = ((dir == 1 or dir == 3) and (count - i) or (i - 1)) *
					slot
			if dir == 2 or dir == 3 then
				frame:SetPosition(0, at)
			else
				frame:SetPosition(at, 0)
			end
			local s = stacks[i]
			if s.texture then
				local image = frame:CreateChild("BorderImage")
				image.texture = s.texture
				image:SetPosition(padding, padding)
				image.size = magic.IntVector2(imagesize, imagesize)
			end
			if (s.count or 0) > 1 then
				local t = frame:CreateChild("Text")
				t:SetFont(ctx.font, 12)
				t:SetTextEffect(magic.TE_SHADOW)
				t.effectColor = magic.Color(0, 0, 0, 0.9)
				t.horizontalAlignment = magic.HA_RIGHT
				t.verticalAlignment = magic.VA_BOTTOM
				t:SetPosition(-3, -2)
				t:SetText(tostring(s.count))
			end
		end
		local w = (dir <= 1) and (count * slot) or slot
		local h = (dir <= 1) and slot or (count * slot)
		row.size = magic.IntVector2(w, h)
		place(row, n, w, h)
		self.has_inventory = true
		return row
	end

	-- A label over a place in the world, with how far away it is. Luanti
	-- keeps the precision in the item field -- item is precision + 1, and
	-- zero means ten -- and text is the unit the distance is written in.
	local function waypoint_text(n)
		local text = formspec.strip_escapes(n.name)
		local precision = (n.item == 0) and 10 or (n.item - 1)
		if precision <= 0 then
			return text
		end
		local ex, ey, ez = ctx.eye()
		local dx, dy, dz = n.world_pos[1] - ex, n.world_pos[2] - ey,
				n.world_pos[3] - ez
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		local decimals = math.max(0,
				math.ceil(math.log(precision) / math.log(10)))
		return text .. string.format("%." .. decimals .. "f",
				math.floor(distance * precision) / precision) .. n.text
	end

	function draw.waypoint(n)
		if not ctx.screen_of then
			return false
		end
		if not n.world_pos then
			return
		end
		local t = root:CreateChild("Text")
		t:SetFont(ctx.font, FONT_SIZE)
		t:SetTextEffect(magic.TE_SHADOW)
		t.effectColor = magic.Color(0, 0, 0, 0.85)
		t.color = color(n.number)
		waypoints[#waypoints + 1] = {element = t, n = n, text = true}
		return t
	end

	-- The same place in the world, with a picture on it instead of a label
	function draw.image_waypoint(n)
		if not ctx.screen_of then
			return false
		end
		local tex = n.world_pos and texture(n.text, "an image")
		if not tex then
			return
		end
		local w, h = hud.image_size(n, sw, sh, tex.width, tex.height)
		local img = root:CreateChild("BorderImage")
		img.texture = tex
		img.size = magic.IntVector2(w, h)
		waypoints[#waypoints + 1] = {element = img, n = n, w = w, h = h}
		return img
	end

	-- A negative size is a percentage of the screen, as an image's scale
	-- is; a positive one is in Luanti's screen pixels times scaled
	local function box_size(n, scaled, dw, dh)
		local w, h = n.size[1], n.size[2]
		if w == 0 and h == 0 then
			w, h = dw, dh
		end
		local k = scaled and hud.scale_factor or 1
		w = w < 0 and -w * 0.01 * sw or w * k
		h = h < 0 and -h * 0.01 * sh or h * k
		return math.floor(w), math.floor(h)
	end

	-- Luanti's compass: a picture that turns with the player, or a strip
	-- that scrolls past. dir says which -- 0 turns, 1 turns the other way,
	-- 2 scrolls, 3 scrolls the other way -- and number is an angle added
	-- to the camera's.
	function draw.compass(n)
		if not ctx.yaw then
			return false
		end
		local tex = texture(n.text, "an image")
		if not tex then
			return
		end
		local w, h = box_size(n, false, 0, 0)
		if w <= 0 or h <= 0 then
			return
		end
		local block = root:CreateChild("UIElement")
		block.size = magic.IntVector2(w, h)
		local piece = nil
		if n.dir == 0 or n.dir == 1 then
			-- A Sprite turns about its hot spot and is drawn with that point
			-- where it sits, so it hangs under an element at the middle of
			-- this one with its own middle as the hot spot
			local holder = block:CreateChild("UIElement")
			holder:SetPosition(math.floor(w / 2), math.floor(h / 2))
			piece = holder:CreateChild("Sprite")
			piece:SetTexture(tex)
			piece:SetFixedSize(w, h)
			piece.hotSpot = magic.IntVector2(math.floor(w / 2),
					math.floor(h / 2))
		end
		place(block, n, w, h)
		compasses[#compasses + 1] = {block = block, sprite = piece, n = n,
				tex = tex, w = w, h = h}
		return block
	end

	-- Luanti's minimap element: the world around the player, from above
	-- (minimap.lua). A game that has turned the minimap off does not get
	-- one from its own element either, which is Luanti's rule for this kind.
	function draw.minimap(n)
		if not ctx.minimap then
			return false
		end
		if ctx.hud_flag and not ctx.hud_flag("minimap") then
			return
		end
		local w, h = box_size(n, true, 128, 128)
		if w <= 0 or h <= 0 then
			return
		end
		local m = ctx.minimap(root, w, h)
		if not m then
			return
		end
		place(m.view, n, w, h)
		self.minimaps[#self.minimaps + 1] = m
		return m.view
	end

	-- The HUD again from what the game last sent: everything taken away
	-- and drawn in z_index order, the id breaking a tie because
	-- table.sort is not stable
	function self:draw(elements)
		root:RemoveAllChildren()
		waypoints, compasses = {}, {}
		-- The cameras the minimaps put in the world are this one's to take
		-- away
		for _, m in ipairs(self.minimaps) do
			m.camera:Remove()
		end
		self.minimaps = {}
		self.has_inventory = false
		hud.scale_factor = ctx.scale()
		sw, sh = ctx.parent.width, ctx.parent.height
		-- As big as the screen, because an element aligned to the centre or
		-- the bottom is aligned inside this
		root.size = magic.IntVector2(sw, sh)
		local order = {}
		for id, e in pairs(elements) do
			order[#order + 1] = {id = id, e = e, n = M.normalize(e)}
		end
		table.sort(order, function(a, b)
			if a.n.z_index ~= b.n.z_index then
				return a.n.z_index < b.n.z_index
			end
			return tostring(a.id) < tostring(b.id)
		end)
		local skipped, images = {}, {}
		for _, o in ipairs(order) do
			local f = draw[o.n.kind]
			local el = f and f(o.n, images)
			-- Which UI element it was placed as, for the scan's rectangles
			-- ([SCAN_EVENT]); none for one not drawn this time, whose
			-- last one is gone
			o.e.__placed = el or nil
			if el == false or not f then
				skipped[o.n.kind] = (skipped[o.n.kind] or 0) + 1
				say_once("kind:" .. o.n.kind, "the game asked for a \"" ..
						o.n.kind .. "\" HUD element, which is not drawn")
			end
		end
		return skipped, images
	end

	-- One element drawn on top of what is there: official's own minimap,
	-- which the engine draws whether or not the game adds one
	function self:draw_one(e)
		local n = M.normalize(e)
		return draw[n.kind](n, {})
	end

	-- Once a frame: what moves is the player
	function self:update(dt)
		for _, w in ipairs(waypoints) do
			local x, y = nil, nil
			x, y = ctx.screen_of(w.n.world_pos[1], w.n.world_pos[2],
					w.n.world_pos[3])
			w.element.visible = x ~= nil
			if x then
				if w.text then
					w.element:SetText(waypoint_text(w.n))
				end
				local ew = w.text and w.element.width or w.w
				local eh = w.text and w.element.height or w.h
				w.element:SetPosition(
						math.floor(x + w.n.offset[1] * hud.scale_factor +
						(w.n.align[1] - 1) * 0.5 * ew),
						math.floor(y + w.n.offset[2] * hud.scale_factor +
						(w.n.align[2] - 1) * 0.5 * eh))
			end
		end
		for _, c in ipairs(compasses) do
			-- Luanti's own: the camera's horizontal angle, the other way
			-- round, plus what the game asked for
			local angle = (-ctx.yaw() + c.n.number) % 360
			if c.n.dir == 1 or c.n.dir == 3 then
				angle = (360 - angle) % 360
			end
			if c.sprite then
				c.sprite.rotation = angle
			else
				-- The strip: as wide as the picture is at this height,
				-- scrolled by the angle and repeated until the element is
				-- covered, each copy cut to what shows -- Urho3D's UI clips
				-- nothing by itself
				local stw = math.floor(c.h * tex_aspect(c.tex))
				c.block:RemoveAllChildren()
				local x = -math.floor(angle * stw / 360)
				while x > 0 do
					x = x - stw
				end
				while x < c.w do
					local left = math.max(0, -x)
					local right = math.min(stw, c.w - x)
					if right > left then
						local img = c.block:CreateChild("BorderImage")
						img.texture = c.tex
						img.size = magic.IntVector2(right - left, c.h)
						img:SetPosition(x + left, 0)
						img.imageRect = magic.IntRect(
								math.floor(left * c.tex.width / stw), 0,
								math.floor(right * c.tex.width / stw),
								c.tex.height)
					end
					x = x + stw
				end
			end
		end
		if #self.minimaps > 0 then
			local ex, ey, ez = ctx.eye()
			local p = magic.Vector3(ex, ey, ez)
			for _, m in ipairs(self.minimaps) do
				m:follow(p, dt)
			end
		end
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
