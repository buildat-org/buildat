-- Buildat: extensions/weave/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **weave, a texture designer and generator** ([KIT_TEXTURE_DESIGNER],
-- kit_plan 4z33 (9)): seamless pixel-art textures made of parameters, no
-- pen or brush -- blip's way with sounds, for textures. Sandboxed; an app
-- reaches it as require("buildat/extension/weave"):
--   weave.texture(recipe) -> Texture2D  made once and kept, registered in
--                            the resource cache (an Image and a Texture2D)
--                            as weave.name(recipe), so a voxel type naming
--                            that texture draws it
--   weave.name(recipe) -> "generated/weave/weave1/<the compact form>"
--   weave.image(recipe) -> Image         made, not kept
--   weave.pack(recipe) -> "weave1:..."   and weave.unpack(s) -> its table
--   weave.params(recipe) -> the recipe as a full table
--   weave.presets, weave.preset(name, seed), weave.random(seed),
--   weave.mutate(recipe, seed[, amount])
--   weave.from_name(name) -> the recipe of a weave.name(), or nil
--   weave.design(recipe, on_save[, opts]) the designer on the recipe; its
--     Save calls on_save(the recipe packed, "weave1:...") and closes it.
--     opts {rect = {x, y, w, h}, world = {x, y, w, h}} put its controls in
--     rect and its preview in world (UI units; Kit's touch mode: its UI
--     half and its world's), as blip.design's
-- A recipe is any of weave1's forms (weave_gen.lua's params()): the
-- compact form, "weave1:" and 53 characters, a table {pattern = "bricks",
-- color_a = "#9c4a32", grain = 0.6, ...} or both ({"weave1:...", ...}).
-- weave.gen is the generator (weave_gen.lua), which an app may also copy
-- into itself. **The name is the recipe**: a client that meets
-- "generated/weave/weave1/..." in a voxel registry makes it from the name
-- alone (voxelworld's registry_from_file()), before anything is meshed.
-- Its versioning is its format's (weave1, frozen at Kit's first stable
-- release), not the engine's.
local api = buildat.safe or buildat
local log = buildat.Logger("weave")
local magic = require("buildat/core/urho3d")
local gen = api.run_extension_file("weave_gen.lua")
local KEY_ESCAPE, KEY_LEFT, KEY_RIGHT, LM_HORIZONTAL, LM_VERTICAL =
	magic.KEY_ESCAPE, magic.KEY_LEFT, magic.KEY_RIGHT, magic.LM_HORIZONTAL,
	magic.LM_VERTICAL
-- A Left or Right on a selected slider: 50 steps across its range
local SLIDER_STEP = 0.02
local PREFIX = "generated/weave/"

local M = {safe = {gen = gen}}

-- The textures made and registered, by their compact form: a wrapper
-- dropped would drop its resource with it
-- simplified: kept for the client's run (a project's few hundred at most);
-- dropping the unused ones is the upgrade if a game makes thousands
local made = {}

local function image_of(r)
	local px = gen.render(r)
	local img = magic.Image:new()
	img:SetSize(px.size, px.size, 4)
	magic.image_set_data(img, px.size, px.size, 4, px.rgba)
	return img
end

local function name_of(packed)
	return PREFIX .. (packed:gsub(":", "/"))
end

function M.safe.name(recipe)
	return name_of(gen.pack(gen.params(recipe)))
end

function M.safe.image(recipe)
	return image_of(gen.params(recipe))
end

function M.safe.texture(recipe)
	local r = gen.params(recipe)
	local packed = gen.pack(r)
	local m = made[packed]
	if not m then
		local t0 = api.get_time_us()
		local img = image_of(r)
		local tex = magic.Texture2D:new()
		tex.filterMode = magic.FILTER_NEAREST
		tex:SetData(img, false)
		-- (the sandbox adds "generated/" before the name)
		local rel = name_of(packed):sub(#"generated/" + 1)
		magic.cache:AddManualResource(img, rel)
		magic.cache:AddManualResource(tex, rel)
		m = {image = img, texture = tex}
		made[packed] = m
		log:info(string.format("made %s (%d px, %d ms)", packed, r.size,
				math.floor((api.get_time_us() - t0) / 1000)))
	end
	return m.texture
end

-- The recipe a weave.name() names, or nil for any other name
function M.safe.from_name(name)
	if type(name) ~= "string" or name:sub(1, #PREFIX) ~= PREFIX then
		return nil
	end
	local ok, r = pcall(gen.unpack, (name:sub(#PREFIX + 1):gsub("/", ":", 1)))
	return ok and r or nil
end

M.safe.params = gen.params
M.safe.pack = function(recipe)
	return gen.pack(gen.params(recipe))
end
M.safe.unpack = gen.unpack
M.safe.presets = gen.PRESETS
M.safe.preset = gen.preset
M.safe.random = gen.random
M.safe.mutate = function(recipe, seed, amount)
	return gen.mutate(gen.params(recipe), seed, amount)
end
M.safe.self_check = gen.self_check

-- ---- The designer

-- A colour's hue, saturation and value (0...1 each) and back
local function to_hsv(hex)
	local n = tonumber(hex:sub(2), 16)
	local r, g, b = math.floor(n / 65536) / 255,
			math.floor(n / 256) % 256 / 255, n % 256 / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == r then
			h = ((g - b) / d) % 6
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = h / 6
	end
	return h, mx > 0 and d / mx or 0, mx
end
local function from_hsv(h, s, v)
	local i = math.floor(h * 6) % 6
	local f = h * 6 - math.floor(h * 6)
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	local c = ({{v, t, p}, {q, v, p}, {p, v, t}, {p, q, v}, {t, p, v},
		{v, p, q}})[i + 1]
	local function byte(x)
		return math.floor(math.max(0, math.min(1, x)) * 255 + 0.5)
	end
	return string.format("#%02x%02x%02x", byte(c[1]), byte(c[2]), byte(c[3]))
end

-- **The preview's block**: a cube wearing the texture, in a scene of its
-- own drawn into a texture, made once a client and kept (a drawn texture
-- and its viewport are never freed: magic.render_scene_to_texture)
local cube = nil
local function preview_cube(tex)
	if cube then
		cube.material:SetTexture(magic.TU_DIFFUSE, tex)
		return cube.image
	end
	local scene = magic.Scene:new()
	scene:CreateComponent("Octree")
	local zone = scene:CreateChild("zone"):CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-100, 100)
	zone.ambientColor = magic.Color(0.45, 0.45, 0.5)
	zone.fogColor = magic.Color(0.16, 0.16, 0.2)
	zone.fogStart = 100
	zone.fogEnd = 101
	local ln = scene:CreateChild("light")
	ln.direction = magic.Vector3(0.6, -1, 0.3)
	local light = ln:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.brightness = 0.75
	local node = scene:CreateChild("cube")
	local cg = node:CreateComponent("CustomGeometry")
	cg:SetNumGeometries(1)
	cg:BeginGeometry(0, magic.TRIANGLE_LIST)
	-- Each face: its normal, its across and down edges; a whole tile
	for _, f in ipairs({
		{{0, 1, 0}, {1, 0, 0}, {0, 0, -1}}, {{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
		{{1, 0, 0}, {0, 0, 1}, {0, -1, 0}}, {{-1, 0, 0}, {0, 0, -1}, {0, -1, 0}},
		{{0, 0, 1}, {-1, 0, 0}, {0, -1, 0}}, {{0, 0, -1}, {1, 0, 0}, {0, -1, 0}},
	}) do
		local nr, eu, ev = f[1], f[2], f[3]
		local function at(u, v)
			cg:DefineVertex(magic.Vector3(nr[1] * 0.5 + eu[1] * (u - 0.5) +
					ev[1] * (v - 0.5), nr[2] * 0.5 + eu[2] * (u - 0.5) +
					ev[2] * (v - 0.5), nr[3] * 0.5 + eu[3] * (u - 0.5) +
					ev[3] * (v - 0.5)))
			cg:DefineNormal(magic.Vector3(nr[1], nr[2], nr[3]))
			cg:DefineTexCoord(magic.Vector2(u, v))
		end
		-- Wound as Kit's looks are: cross(p2 - p1, p3 - p1) along the normal
		at(0, 0) at(1, 0) at(1, 1)
		at(0, 0) at(1, 1) at(0, 1)
	end
	cg:Commit()
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/Diff.xml"))
	m:SetTexture(magic.TU_DIFFUSE, tex)
	cg:SetMaterial(0, m)
	local cam = scene:CreateChild("camera")
	cam:CreateComponent("Camera").fov = 30
	cam.position = magic.Vector3(-2.2, 2, -2.6)
	cam:LookAt(magic.Vector3(0, 0, 0))
	cube = {scene = scene, material = m,
		image = magic.render_scene_to_texture(scene, cam, 192, 192)}
	return cube.image
end

local designer = nil

local function open_designer(recipe, on_save, opts)
	opts = opts or {}
	if designer then
		return
	end
	local uistack = require("buildat/core/uistack")
	local ui_utils = require("buildat/extension/ui_utils")
	local d = {r = recipe and gen.params(recipe) or gen.preset("stone", 1),
		seed = 1}
	-- Seeds drawn, not counted: a preset at seeds next to each other
	-- starts its choices alike
	local seeds = gen.rng(api.get_time_us() % 2147483646)
	local function next_seed()
		d.seed = math.floor(seeds.frnd(1048576))
	end
	designer = d
	local root = uistack.main:push({desc = "weave"})
	root.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	local win = root:CreateChild("Window")
	win:SetStyleAuto()
	win:SetLayout(LM_VERTICAL, 6, magic.IntRect(10, 10, 10, 10))
	win:SetName("weave designer")
	-- **The preview beside the controls on a landscape screen with room
	-- for it** (blip's code column), above them otherwise
	-- simplified: decided as the designer opens, as blip's
	local ui_w, ui_h = magic.ui.root.width, magic.ui.root.height
	local col, prev_col = win, nil
	local rect = opts.rect
	local tile_px = 48
	if rect then
		-- Placed by the caller: the controls clipped to rect, the preview
		-- in a window of its own in opts.world
		root:SetLayout(magic.LM_FREE, 0, magic.IntRect(0, 0, 0, 0))
		root:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
		root:SetPosition(0, 0)
		root:SetFixedSize(ui_w, ui_h)
		win:SetPosition(rect[1], rect[2])
		win:SetFixedSize(rect[3], rect[4])
		win.clipChildren = true
		local wr = opts.world
		if wr and wr[3] >= 120 and wr[4] >= 80 then
			prev_col = root:CreateChild("Window")
			prev_col:SetStyleAuto()
			prev_col:SetName("weave preview")
			prev_col:SetPosition(wr[1], wr[2])
			prev_col:SetFixedSize(wr[3], wr[4])
			prev_col.clipChildren = true
			tile_px = math.max(16, math.floor(math.min(wr[3] - 20,
					(wr[4] - 40) / 2) / 3))
		end
	elseif ui_w >= 820 and ui_w > ui_h then
		win:SetLayout(LM_HORIZONTAL, 12, magic.IntRect(10, 10, 10, 10))
		prev_col = win:CreateChild("UIElement")
		col = win:CreateChild("UIElement")
		col:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
		tile_px = math.max(32, math.min(80, math.floor((ui_h - 300) / 6)))
	else
		prev_col = win:CreateChild("UIElement")
		tile_px = math.max(24, math.min(48, math.floor((ui_w - 260) / 3)))
	end
	ui_utils.wants_clicks(win)
	local function close()
		win.visible = false
		M.on_update = nil
		designer = nil
		uistack.main:pop(root)
		log:info("designer closed")
	end
	ui_utils.close_glyph(root, win, close)
	local sliders = {}
	local nav = ui_utils.bind_button_menu(root, nil, function(key)
		if key == KEY_ESCAPE and magic.input:GetKeyPress(key) and
				not ui_utils.dropdown_open() then
			close()
			return true
		end
		if key == KEY_LEFT or key == KEY_RIGHT then
			for _, sl in ipairs(sliders) do
				if sl.slider:HasFocus() then
					-- Sends SliderChanged, as a drag does
					sl.slider.value = math.max(0, math.min(1, sl.slider.value +
							(key == KEY_LEFT and -SLIDER_STEP or SLIDER_STEP)))
					return true
				end
			end
		end
	end, {wheel = false})
	local n_items, slider_at = 0, {}
	local function item(e, fn)
		n_items = n_items + 1
		nav:add(e, fn or function() end)
		return e
	end
	local function text(parent, s, width)
		local t = parent:CreateChild("Text")
		t:SetStyleAuto()
		t.text = s
		if width then
			t:SetFixedWidth(width)
		end
		return t
	end
	local function row(parent)
		local r = (parent or col):CreateChild("UIElement")
		r:SetLayout(LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
		return r
	end
	local function button(parent, label, fn)
		local b = parent:CreateChild("Button")
		b:SetStyleAuto()
		b:SetName(label)
		b:SetFixedHeight(28)
		b:SetLayout(LM_HORIZONTAL, 0, magic.IntRect(8, 2, 8, 2))
		local t = b:CreateChild("Text")
		t:SetStyleAuto()
		t.text = label
		item(b, fn)
		return b
	end

	-- **The preview**: the texture tiled 3 by 3, and on a block
	local ptex = magic.Texture2D:new()
	ptex.filterMode = magic.FILTER_NEAREST
	local tiles, code = {}, nil
	if prev_col then
		prev_col:SetLayout(LM_VERTICAL, 6, magic.IntRect(rect and 10 or 0,
				rect and 10 or 0, 0, 0))
		text(prev_col, "Tiled, and on a block")
		local grid = prev_col:CreateChild("UIElement")
		grid:SetFixedSize(tile_px * 3, tile_px * 3)
		for ty = 0, 2 do
			for tx = 0, 2 do
				local b = grid:CreateChild("BorderImage")
				b:SetPosition(tx * tile_px, ty * tile_px)
				b:SetFixedSize(tile_px, tile_px)
				tiles[#tiles + 1] = b
			end
		end
		local block = prev_col:CreateChild("BorderImage")
		block:SetName("weave block")
		block:SetFixedSize(tile_px * 3, tile_px * 3)
		block.texture = preview_cube(ptex)
		block.imageRect = magic.IntRect(0, 0, 192, 192)
		if not rect then
			-- The recipe's code, as Copy makes it: selected and copied in
			-- part, not typed into
			code = prev_col:CreateChild("LineEdit")
			code:SetStyleAuto()
			code.multiLine = true
			code.editable = false
			code.clipBorder = magic.IntRect(3, 3, 3, 3)
			code.textSelectable = true
			code.textCopyable = true
			code:SetFixedSize(tile_px * 3, 90)
		end
	end

	text(col, "weave: textures of parameters, no pen or brush")
	local status = nil
	local function say(s)
		status.text = s
		log:info("designer: " .. s)
	end
	if on_save then
		local sr = row()
		button(sr, "Save", function()
			local packed = gen.pack(d.r)
			log:info("designer: saved " .. packed)
			close()
			on_save(packed)
		end)
		button(sr, "Cancel", close)
	end

	local function snippet(format)
		local packed = gen.pack(d.r)
		local s = format == "table" and gen.table_source(gen.to_table(d.r)) or
				string.format("%q", packed)
		return "local weave = require(\"buildat/extension/weave\")\n" ..
				"local tex = weave.texture(" .. s .. ")\n"
	end
	-- Made again on a change; while a slider moves, the next waits twice
	-- what the last took, and at least 60 ms
	local dirty, last, wait_us = false, 0, 0
	local function show_now()
		dirty = false
		local t0 = api.get_time_us()
		local img = image_of(d.r)
		ptex:SetData(img, false)
		for _, b in ipairs(tiles) do
			b.texture = ptex
			b.imageRect = magic.IntRect(0, 0, d.r.size, d.r.size)
		end
		if code then
			code:SetText((snippet("compact"):gsub("\t", "    ")))
			code.cursorPosition = 0
		end
		last = api.get_time_us()
		wait_us = math.max(60000, 2 * (last - t0))
	end
	local function changed()
		dirty = true
	end
	M.on_update = function()
		if dirty and api.get_time_us() - last > wait_us then
			show_now()
		end
	end
	if not M.ticking then
		M.ticking = true
		magic.SubscribeToEvent("Update", function()
			if M.on_update then
				M.on_update()
			end
		end)
	end

	-- The sliders' values from d.r
	local updating = false
	local hsv = {}
	local dropdowns = {}
	local function show_values()
		updating = true
		for _, c in ipairs(gen.COLORS) do
			local h, s, v = to_hsv(d.r[c[1]])
			hsv[c[1]] = {h, s, v}
		end
		for _, sl in ipairs(sliders) do
			local def = sl.def
			local v
			if def.color then
				v = hsv[def.color][def.part]
				sl.value.text = d.r[def.color]
			else
				v = (d.r[def[1]] - def[2]) / (def[3] - def[2])
				sl.value.text = def[5] and tostring(d.r[def[1]]) or
						string.format("%.2f", d.r[def[1]])
			end
			sl.slider.value = v
		end
		ui_utils.dropdown_set(dropdowns.size, d.r.size)
		ui_utils.dropdown_set(dropdowns.pattern, d.r.pattern)
		updating = false
	end
	local function set_recipe(r, what)
		d.r = r
		show_values()
		show_now()
		say(what .. ": " .. gen.pack(r))
	end

	-- The presets, then mutate and random, five a row
	local rows = {}
	local function gen_row(i)
		local k = math.floor((i - 1) / 5) + 1
		rows[k] = rows[k] or row()
		return rows[k]
	end
	for i, name in ipairs(gen.PRESETS) do
		button(gen_row(i), name, function()
			next_seed()
			local r = gen.preset(name, d.seed)
			r.size = d.r.size
			set_recipe(r, name)
		end)
	end
	local n = #gen.PRESETS
	button(gen_row(n + 1), "Mutate", function()
		next_seed()
		set_recipe(gen.mutate(d.r, d.seed), "mutated")
	end)
	button(gen_row(n + 2), "Randomize", function()
		next_seed()
		local r = gen.random(d.seed)
		r.size = d.r.size
		set_recipe(r, "random")
	end)
	button(gen_row(n + 3), "New seed", function()
		next_seed()
		d.r.seed = d.seed
		set_recipe(d.r, "seed " .. d.seed)
	end)
	local choice_row = row()
	local sizes = {}
	for i, s in ipairs(gen.SIZES) do
		sizes[i] = {s .. " px", s}
	end
	dropdowns.size = item((ui_utils.dropdown(choice_row, sizes, d.r.size,
			function(s)
		if not updating then
			d.r.size = s
			changed()
		end
	end, {label = "Size"})))
	local pats = {}
	for i, p in ipairs(gen.PATTERNS) do
		pats[i] = {p, p}
	end
	dropdowns.pattern = item((ui_utils.dropdown(choice_row, pats, d.r.pattern,
			function(p)
		if not updating then
			d.r.pattern = p
			changed()
		end
	end, {label = "Pattern"})))

	local view = col:CreateChild("ScrollView")
	view:SetStyleAuto()
	view.scrollBarsAutoVisible = true
	local page = view:CreateChild("UIElement")
	page:SetLayout(LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	view.contentElement = page
	view:SetFixedHeight(math.min(300,
			math.max(120, (rect and rect[4] or ui_h) - 300 -
			(prev_col and not rect and ui_w < 820 and tile_px * 6 + 60 or 0))))
	-- Each colour as three sliders (hue, saturation, value), then the
	-- parameters
	local defs = {}
	for _, c in ipairs(gen.COLORS) do
		local short = c[1]:gsub("_?color_?", "")
		for part, pn in ipairs({"hue", "sat", "value"}) do
			defs[#defs + 1] = {short .. " " .. pn, color = c[1], part = part}
		end
	end
	for _, def in ipairs(gen.PARAMS) do
		defs[#defs + 1] = def
	end
	for _, def in ipairs(defs) do
		local r = row(page)
		r:SetFixedHeight(20)
		-- Each text in a holder of the row's height (blip's)
		local function centred(s, width)
			local holder = r:CreateChild("UIElement")
			holder:SetFixedSize(width, 20)
			local t = text(holder, s, width)
			t.position = magic.IntVector2(0,
					math.floor((20 - t.height) / 2) - 4)
			return t
		end
		local name = centred(def[1], 104)
		local slider = r:CreateChild("Slider")
		slider:SetStyleAuto()
		slider:SetName("weave " .. def[1])
		slider.range = 1
		slider:SetFixedHeight(16)
		local value = centred("", 64)
		local sl = {def = def, slider = slider, value = value, name = name,
			row = r}
		sliders[#sliders + 1] = sl
		item(slider)
		slider_at[n_items] = sl
		magic.SubscribeToEvent(slider, "SliderChanged", function(_, _, data)
			if updating then
				return
			end
			local x = data:GetFloat("Value")
			if def.color then
				local c = hsv[def.color]
				c[def.part] = x
				d.r[def.color] = from_hsv(c[1], c[2], c[3])
				value.text = d.r[def.color]
			else
				local v = def[2] + x * (def[3] - def[2])
				if def[5] then
					v = math.floor(v + 0.5)
				end
				d.r[def[1]] = v
				value.text = def[5] and tostring(v) or string.format("%.2f", v)
			end
			changed()
		end)
	end
	-- A selected slider: its name in the focus colour, its row scrolled into
	-- the view (blip's)
	local focus_color = magic.Color(ui_utils.rgb("focus"))
	local c0 = sliders[1].name.color
	local text_color = magic.Color(c0.r, c0.g, c0.b, c0.a)
	nav:on_change(function(_, selected, i, by_mouse)
		local sl = slider_at[i]
		if not sl then
			return
		end
		sl.name.color = selected and focus_color or text_color
		if selected and not by_mouse then
			local panel = view.scrollPanel
			local y = math.min(sl.row.screenPosition.y, sl.name.screenPosition.y)
			local top = panel.screenPosition.y + 4
			local bottom = panel.screenPosition.y + panel.height - 4
			local h = math.max(sl.row.screenPosition.y + sl.row.height,
					sl.name.screenPosition.y + sl.name.height) - y
			local move = y < top and y - top or math.max(0, y + h - bottom)
			if move ~= 0 then
				view.viewPosition = magic.IntVector2(0,
						math.max(0, view.viewPosition.y + move))
			end
		end
	end)

	-- The export row: the code that makes it, and the generator's file
	local ex = row()
	button(ex, "Copy", function()
		ui_utils.copy(snippet("compact"))
		say("copied " .. gen.pack(d.r))
	end)
	button(ex, "Copy as a table", function()
		ui_utils.copy(snippet("table"))
		say("copied as a table")
	end)
	button(ex, "Save weave_gen.lua", function()
		local path = api.save_file("weave_gen.lua",
				api.read_extension_file("weave_gen.lua"))
		say(path and "saved weave_gen.lua" or "weave_gen.lua not saved")
	end)

	status = text(col, "")
	status:SetFixedWidth(rect and math.max(40, rect[3] - 24) or 380)
	page:SetFixedWidth((rect and rect[3] - 20 or 380) - 24)
	show_values()
	show_now()
	say(gen.pack(d.r))
	log:info("designer shown")
end

function M.safe.design(recipe, on_save, opts)
	assert(type(on_save) == "function", "weave.design: on_save a function")
	local function rect(r)
		if r == nil then
			return nil
		end
		assert(type(r) == "table" and #r == 4, "weave.design: a rect {x, y, w, h}")
		local o = {}
		for i = 1, 4 do
			assert(type(r[i]) == "number", "weave.design: a rect's numbers")
			o[i] = math.floor(math.max(0, math.min(100000, r[i])))
		end
		return o
	end
	opts = type(opts) == "table" and opts or {}
	open_designer(recipe ~= nil and gen.params(recipe) or nil, on_save,
			{rect = rect(opts.rect), world = opts.rect and rect(opts.world)})
end

-- The launch tile's way in (launcher/init.lua)
function M.on_untrusted_launch(request)
	open_designer()
end

return M
-- vim: set noet ts=4 sw=4:
