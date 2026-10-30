-- Buildat: extensions/luanti_client/res/formspec_ui.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Shared by both Luanti clients: the extension runs it as res/formspec_ui.lua
-- and the luanti module serves it to its own client as luanti/formspec_ui.lua
-- ([LUANTI_SHARED]). Each passes in its own formspec.lua and white
-- image through ctx.
--
-- A formspec on the screen, out of Urho3D's UI elements.
--
-- formspec.lua says what the elements are and where; this puts something
-- there. What a formspec asks for is mostly boxes with a texture in them, so
-- most of it is a BorderImage at a position, and the interesting parts are
-- the inventory lists: a slot's background, the item's image in it, and how
-- many of the item there are.
--
-- What an item looks like is its inventory image, or the texture of the top
-- of the node it places, and either of those is a texture modifier
-- expression, so it goes through the same composing the world's textures do.
--
-- The elements that are not implemented are counted and named once, which is
-- what says whether it is worth implementing the next one; styles and the
-- list ring are deliberately ignored rather than missing.

local M = {}

-- The elements that say nothing about what is drawn
local IGNORED = {
	listring = true, listcolors = true, style = true, style_type = true,
	field_enter_after_edit = true,
	no_prepend = true,
	allow_close = true, position = true,
	tableoptions = true,
	anchor = true, padding = true, ["scroll_container_end"] = true,
}

-- new(magic, buildat, log, ctx)
--
-- ctx.texture(expression) -> a resource name for a texture modifier
--   expression, or nil
-- ctx.item_image(item_name, stack) -> a resource name for what an item looks
--   like, or nil, and true when it is the cube drawn for a node with no
--   picture of its own
-- ctx.inventory(location, list_name) -> the list to draw in a list[] element,
--   as inventory.lua's {size =, items = {...}}, or nil
-- ctx.model(parent, w, h, mesh, textures, rotation_x, rotation_y) -> a UI
--   element drawing that mesh, or nil when the model is not there (yet)
-- ctx.style is the UI style (an XMLFile) everything under the form inherits;
--   without it a Text element has no font and draws nothing at all
-- ctx.white is a plain white image, which is what a box or a tint is drawn
--   with
-- ctx.formspec is the client's formspec.lua
function M.new(magic, buildat, log, ctx)
	local self = {}
	local WHITE = ctx.white
	local formspec = ctx.formspec
	local unknown = {}

	-- Urho3D sorts an element's children by priority and the sort is not a
	-- stable one, so siblings that all sit at the default priority are drawn
	-- in whatever order the sort happens to leave them in -- a background
	-- over the slots one run and under them the next. Every element gets the
	-- priority its turn to be drawn is instead.
	-- Counted from 0 again for each holder drawn (a form, the HUD): an
	-- element's priority is clamped at 999, under the client's own
	-- dialogs, and a count kept for the session reached that within a
	-- minute of HUD updates -- every element of a form then tied, and the
	-- background was drawn over its lists ([LUANTI_INV_LISTS]).
	-- simplified: a holder with over 999 elements ties again past that.
	local depth = 0
	local function next_priority()
		depth = depth + 1
		return depth
	end

	-- A game's own image, without smoothing: everything a Luanti game ships
	-- is pixel art, and the UI draws it at whatever size the form asked for,
	-- so interpolating it turns a furnace's flame and an item's picture into
	-- a blur. The world's textures have said FILTER_NEAREST all along; these
	-- are the same files.
	local function game_texture(resource)
		local tex = magic.cache:GetResource("Texture2D", resource)
		if tex then
			tex.filterMode = magic.FILTER_NEAREST
		end
		return tex
	end

	local function texture(name)
		if not name or name == "" then
			return nil
		end
		local resource = ctx.texture(name)
		if not resource then
			return nil
		end
		return game_texture(resource)
	end

	-- A rectangle of one colour, which is what a box is and what stands in
	-- for a texture that could not be composed
	local function box(parent, x, y, w, h, color)
		local e = parent:CreateChild("BorderImage")
		e:SetPosition(math.floor(x), math.floor(y))
		e.size = magic.IntVector2(math.floor(w), math.floor(h))
		e.texture = magic.cache:GetResource("Texture2D", WHITE)
		e.color = color
		e.priority = next_priority()
		return e
	end

	-- A nine-sliced image: the corners keep their size and only the middle
	-- stretches, which is what a formspec's background9 asks for. middle is
	-- Luanti's own field: one number for every side, two for horizontal and
	-- vertical, or four for left, top, right and bottom.
	-- As Luanti's parseMiddleRect(): x, or x,y, the same on both sides,
	-- or x,y,x2,y2 where x2,y2 is the far corner in the texture's pixels, a
	-- negative one from its right or bottom edge ([UI_PARITY] 8)
	local function slice_border(middle, tw, th)
		local n = {}
		for v in tostring(middle or ""):gmatch("-?%d+%.?%d*") do
			local x = tonumber(v)
			n[#n + 1] = x >= 0 and math.floor(x) or math.ceil(x)
		end
		if #n == 1 then
			return magic.IntRect(n[1], n[1], n[1], n[1])
		elseif #n == 2 then
			return magic.IntRect(n[1], n[2], n[1], n[2])
		elseif #n == 4 then
			return magic.IntRect(n[1], n[2],
					n[3] < 0 and -n[3] or math.max(0, tw - n[3]),
					n[4] < 0 and -n[4] or math.max(0, th - n[4]))
		end
		return nil
	end

	-- A picture on a BorderImage, with its rect said outright: Urho's
	-- AddQuad spans the element's width in texels while imageRect is still
	-- zero, and SetTexture fills the rect only if the texture has a size
	-- at that moment -- a media texture that arrives at zero tiles at one
	-- texel per pixel, sixteen pickaxes to a slot ([ITEM_TILED]). Logged
	-- once per picture while the why is read; not drawn that frame.
	local said_zero = {}
	local function set_picture(el, tex)
		el.texture = tex
		if tex.width > 0 and tex.height > 0 then
			el.imageRect = magic.IntRect(0, 0, tex.width, tex.height)
			return true
		end
		if not said_zero[tex.name] then
			said_zero[tex.name] = true
			log:info("picture " .. tostring(tex.name) .. " has no size yet at assignment ([ITEM_TILED])")
		end
		el.visible = false
		return false
	end

	local function image(parent, x, y, w, h, name)
		local tex = texture(name)
		if not tex then
			return nil
		end
		local e = parent:CreateChild("BorderImage")
		e:SetPosition(math.floor(x), math.floor(y))
		e.size = magic.IntVector2(math.floor(w), math.floor(h))
		set_picture(e, tex)
		e.priority = next_priority()
		return e
	end

	-- Luanti's colour markup: \27(c@#rgb) and \27(c@#rrggbb) set the colour
	-- of what follows. Only the first one is honoured -- a Text element is
	-- one colour -- which is enough for a label a game has coloured.
	local function markup_color(text)
		local hex = text:match("\27%(c@#(%x%x%x%x%x%x)%)") or
				text:match("\27%(c@#(%x%x%x)%)")
		if not hex then
			return nil
		end
		local function part(i, n)
			local v = tonumber(hex:sub(i, i + n - 1), 16) / (n == 1 and 15 or 255)
			return v
		end
		if #hex == 3 then
			return magic.Color(part(1, 1), part(2, 1), part(3, 1))
		end
		return magic.Color(part(1, 2), part(3, 2), part(5, 2))
	end

	-- A hypertext's text as lines, each its runs of one style ({runs =
	-- {{text, size, color, mono}...}, center} -- centred as its text
	-- starts), and each <img> a line of its own ({img, w, h, center}).
	-- Sizes are Luanti's pixels at 16 for normal text, drawn at 12 like the
	-- rest of a form.
	-- simplified: bold and italic are drawn plain (no such font here)
	local HYPERTEXT_TAGS = {big = {size = 24}, bigger = {size = 36},
			center = {halign = "center"}, left = {halign = "left"},
			right = {halign = "left"}, justify = {halign = "left"},
			normal = {size = 16}, mono = {font = "mono"}}
	local function hypertext_lines(raw)
		local global, defs, stack = {size = 16}, {}, {}
		local function attrs(s)
			local a = {}
			for k, v in s:gmatch("([%w_]+)=([^%s>]+)") do
				a[k] = v
			end
			return a
		end
		local function style()
			local st = {}
			for k, v in pairs(global) do
				st[k] = v
			end
			for _, e in ipairs(stack) do
				for k, v in pairs(e.props) do
					st[k] = v
				end
			end
			return {size = math.max(6, math.floor(
						(tonumber(st.size) or 16) * 12 / 16 + 0.5)),
					color = st.color and formspec.color_of(st.color),
					center = st.halign == "center", mono = st.font == "mono"}
		end
		local lines, line = {}, nil
		local function add_text(t)
			for piece, nl in t:gmatch("([^\n]*)(\n?)") do
				if piece ~= "" then
					local st = style()
					if not line then
						line = {runs = {}, center = st.center}
					end
					st.text = piece
					line.runs[#line.runs + 1] = st
				end
				if nl ~= "" then
					lines[#lines + 1] = line or {runs = {}, size = style().size}
					line = nil
				end
			end
		end
		local at = 1
		while at <= #raw do
			local s, e, close, name, rest = raw:find("<(/?)([%w_]+)([^>]*)>", at)
			add_text(raw:sub(at, (s or #raw + 1) - 1))
			if not s then
				break
			end
			at = e + 1
			if close == "/" then
				for i = #stack, 1, -1 do
					if stack[i].name == name then
						table.remove(stack, i)
						break
					end
				end
			elseif name == "global" then
				for k, v in pairs(attrs(rest)) do
					global[k] = v
				end
			elseif name == "tag" then
				local a = attrs(rest)
				if a.name then
					defs[a.name] = a
				end
			elseif name == "img" then
				local a = attrs(rest)
				if a.name then
					if line then
						lines[#lines + 1] = line
						line = nil
					end
					lines[#lines + 1] = {img = a.name, w = tonumber(a.width),
							h = tonumber(a.height), center = style().center}
				end
			elseif name == "style" or defs[name] or HYPERTEXT_TAGS[name] then
				stack[#stack + 1] = {name = name, props = name == "style" and
						attrs(rest) or defs[name] or HYPERTEXT_TAGS[name]}
			end
		end
		if line then
			lines[#lines + 1] = line
		end
		return lines
	end

	local function label(parent, x, y, w, text, size, color)
		local e = parent:CreateChild("Text")
		e:SetStyleAuto()
		e.text = text
		e.priority = next_priority()
		e:SetFontSize(size)
		e:SetPosition(math.floor(x), math.floor(y))
		e.color = color or magic.Color(1, 1, 1)
		if w then
			e.width = math.floor(w)
		end
		return e
	end

	-- tablecolumns[type,opt=val,...;...] says what the columns of the tables
	-- after it are. What matters here is which of them carry text and which
	-- only say something about the row: a colour column colours the cells
	-- after it and a tree column moves them to the right.
	local function parse_columns(fields)
		local cols = {}
		for _, part in ipairs(fields) do
			local bits = formspec.split(part, ",")
			local col = {type = (bits[1] or "text"):match("^%s*(.-)%s*$"),
					opts = {}}
			for i = 2, #bits do
				local k, v = bits[i]:match("^%s*([%w_]+)%s*=%s*(.*)$")
				if k then
					col.opts[k] = v
				end
			end
			cols[#cols + 1] = col
		end
		if #cols == 0 then
			cols[1] = {type = "text", opts = {}}
		end
		return cols
	end

	-- An item stack in a slot: what it looks like, and how many
	local function draw_stack(parent, x, y, size, stack)
		local resource, cube = nil, nil
		if stack then
			resource, cube = ctx.item_image(stack.name, stack)
		end
		if resource then
			local e = parent:CreateChild("BorderImage")
			-- The whole slot, as Luanti's drawItemStack(), and a node's
			-- cube a little inside it, where Luanti's camera puts its mesh
			-- ([UI_PARITY] 3)
			local inset = cube and size * 0.04 or 0
			e:SetPosition(math.floor(x + inset / 2), math.floor(y + inset))
			e.size = magic.IntVector2(math.floor(size - inset),
					math.floor(size - inset))
			local tex = game_texture(resource)
			if tex then
				set_picture(e, tex)
			end
			e.priority = next_priority()
		elseif stack then
			-- Something is there but there is no image for it; a marked
			-- square says so, and the name is in the tooltip line
			box(parent, x + size * 0.3, y + size * 0.3, size * 0.4,
					size * 0.4, magic.Color(0.8, 0.4, 0.8, 0.8))
		end
		-- The number, or what the stack's count_meta names instead
		-- ([ITEM_META_LOOK])
		local count_text = ctx.stack_count_text and
				ctx.stack_count_text(stack) or
				(stack and stack.count > 1 and tostring(stack.count) or nil)
		-- A worn tool's bar: a sixteenth of the slot high, a sixteenth in
		-- from the sides and the bottom, green through yellow to red over
		-- what is left and black over what is worn ([UI_PARITY] 5)
		-- simplified: any stack with wear gets it, where Luanti asks that
		-- it be a tool, and a definition's wear_color is not read
		if stack and (stack.wear or 0) > 0 then
			local wear = stack.wear / 65535
			local bx, bw, bh = x + size / 16, size * 14 / 16, size / 16
			local by = y + size - size / 16 - bh
			local mid = math.floor(bx + bw * (1 - wear))
			local wi = math.min(math.min(math.floor(wear * 600), 511) + 10,
					511)
			local c = wi <= 255 and magic.Color(wi / 255, 1, 0) or
					magic.Color(1, (511 - wi) / 255, 0)
			box(parent, bx, by, mid - math.floor(bx), bh, c)
			box(parent, mid, by, math.floor(bx + bw) - mid, bh,
					magic.Color(0, 0, 0))
		end
		if count_text then
			-- Its bottom right corner on the slot's ([UI_PARITY] 4)
			-- simplified: the digits land where Luanti's do by an offset
			-- measured for our font; another font wants it measured again
			-- (builtin/luanti/test/ui_parity.sh)
			local t = label(parent, x, y, size, count_text,
					math.max(8, math.floor(size * 0.245)))
			t:SetTextAlignment(2) -- HA_RIGHT
			t:SetPosition(math.floor(x + size * 0.025),
					math.floor(y + size * 1.06 - t.height))
		end
	end

	-- The slots of one inventory list, and what is in them. held is the slot
	-- whose stack is in hand, which is marked so that it can be seen.
	local function draw_list(parent, layout, e, slots, held)
		local pos = formspec.parse_v2(e.fields[3])
		local geom = formspec.parse_v2(e.fields[4])
		if not pos or not geom then
			return
		end
		local list = ctx.inventory(e.fields[1], e.fields[2])
		local start = tonumber(e.fields[5]) or 0
		local step = layout.slot_step
		local slot = layout.slot
		for row = 0, geom[2] - 1 do
			for col = 0, geom[1] - 1 do
				local x = (pos[1] + e.at[1]) * layout.scale[1] +
						layout.origin[1] + col * step
				local y = (pos[2] + e.at[2]) * layout.scale[2] +
						layout.origin[2] + row * step
				local index = start + row * geom[1] + col + 1
				local in_hand = held and held.location == e.fields[1] and
						held.list == e.fields[2] and held.index == index
				box(parent, x, y, slot, slot, in_hand and
						magic.Color(0.6, 0.6, 0.2, 0.55) or layout.slot_bg or
						magic.Color(0, 0, 0, 0.45))
				local stack = list and list.items[index] or nil
				-- The slot a stack is held from shows what is left in it,
				-- nothing after the whole was taken (Luanti draws it less
				-- m_selected_amount)
				local shown = stack
				if in_hand and stack and stack.count then
					local left = stack.count - (held.count or 0)
					shown = nil
					if left > 0 then
						shown = {}
						for k, v in pairs(stack) do shown[k] = v end
						shown.count = left
					end
				end
				draw_stack(parent, x, y, slot, shown)
				slots[#slots + 1] = {
					location = e.fields[1], list = e.fields[2],
					index = index, x = x, y = y, size = slot,
					stack = shown,
				}
			end
		end
	end

	-- The health bar, which is not a formspec at all: the game describes it
	-- as a HUD element and this draws the one a player needs to see, out of
	-- the hit points. The hotbar beside it is luanti/hotbar.lua, the row
	-- both Luanti clients share ([EXT_HOTBAR]).
	--
	-- simplified: not the game's own healthbar element -- its hearts, its
	-- bubbles, its armour bar are drawn by hud_draw.lua, and this is what
	-- is left when the game has none.
	--
	-- x0, y0 and width are where the hotbar's row is; the bar sits just
	-- above it. Returns the element it went under, for the caller to take
	-- away again when it changes.
	function self:health_bar(root, hp, hp_max, x0, y0, width, slot)
		depth = 0
		local holder = root:CreateChild("UIElement")
		if ctx.style then
			holder.defaultStyle = ctx.style
		end
		local bar_h = math.max(3, math.floor(slot * 0.14))
		local y = y0 - bar_h - 4
		box(holder, x0, y, width, bar_h, magic.Color(0, 0, 0, 0.5))
		local filled = math.floor(width * math.min(hp, hp_max) / hp_max)
		if filled > 0 then
			box(holder, x0, y, filled, bar_h,
					magic.Color(0.85, 0.15, 0.15, 0.9))
		end
		return holder
	end

	-- show(root, elements, layout, screen_w, screen_h)
	--
	-- root is the UI element everything goes under. What comes back is the
	-- window, where it ended up, and where the slots and the buttons are in
	-- it, for whoever handles clicks.
	--
	-- The window is positioned rather than aligned, because a click has to be
	-- turned back into a position inside it and the sandbox does not hand out
	-- an element's own position.
	-- state is what has to live longer than one drawing of the form: how far
	-- a table is scrolled. The caller keeps it and hands it back.
	-- The text a tooltip shows, next to the cursor, or nothing when text is
	-- nil. One element that moves and changes rather than one built per
	-- frame: this is called every frame a form is open.
	--
	-- The element is a child of the UI root rather than of the form, so that
	-- it draws over everything the form put on the screen.
	local tip = nil
	local tip_label = nil
	local tip_text = nil

	function self:tooltip(root, text, x, y, screen_w, screen_h, offset, bg, fg)
		if not text then
			if tip then
				tip.visible = false
			end
			tip_text = nil
			return
		end
		if not tip then
			tip = root:CreateChild("BorderImage")
			if ctx.style then
				tip.defaultStyle = ctx.style
			end
			tip.texture = magic.cache:GetResource("Texture2D", WHITE)
			-- Over everything, and never in the way of a click
			tip.priority = 30000
			tip.enabled = false
		end
		tip.color = bg and magic.Color(bg.r, bg.g, bg.b, bg.a or 1) or
				magic.Color(0.1, 0.1, 0.12, 0.95)
		if text ~= tip_text then
			tip_text = text
			if tip_label then
				tip_label:Remove()
			end
			tip_label = tip:CreateChild("Text")
			tip_label:SetStyleAuto()
			tip_label:SetFontSize(12)
			tip_label.text = text
			tip_label:SetPosition(4, 3)
			-- A Text works out its own size once it has text and a font, so
			-- the box is what the text turned out to be plus a margin
			tip.size = magic.IntVector2(tip_label.width + 8,
					tip_label.height + 6)
		end
		tip_label.color = fg and magic.Color(fg.r, fg.g, fg.b, fg.a or 1) or
				magic.Color(1, 1, 1)
		-- Right of and below the cursor by the offset, and where that is
		-- off the screen, Luanti's showTooltip(): pushed in to the offset
		-- from the edge, and over both edges, up by its own height again
		-- ([UI_PARITY] 7)
		offset = offset or 14
		local w = tip.width
		local h = tip.height
		local px, py = x + offset, y + offset
		local x_alt, y_alt = screen_w - w - offset, screen_h - h - offset
		if px > x_alt and py > y_alt then
			px, py = x_alt, screen_h - 2 * h - offset
		elseif px > x_alt then
			px = x_alt
		elseif py > y_alt then
			py = y_alt
		end
		tip:SetPosition(math.floor(px), math.floor(py))
		tip.visible = true
	end

	-- Takes the tooltip element away, for a session that is ending: it is a
	-- child of the UI root rather than of the form, so closing the form does
	-- not take it with it.
	function self:drop_tooltip()
		if tip then
			tip:Remove()
			tip = nil
			tip_label = nil
			tip_text = nil
		end
	end

	function self:show(root, elements, layout, screen_w, screen_h, state)
		depth = 0
		state = state or {}
		state.scroll = state.scroll or {}
		state.open = state.open or {}
		state.check = state.check or {}
		local slots = {}
		local buttons = {}
		local fields = {}
		-- The things that are not buttons but send the form back all the
		-- same: a tab of a tabheader, a checkbox
		local taps = {}
		-- tooltip[] asks for text over an area or over a named element; the
		-- named ones can only be placed once every element has been drawn
		local tooltips = {}
		local named_tooltips = {}

		local ox = math.floor((screen_w - layout.width) / 2)
		local oy = math.floor((screen_h - layout.height) / 2)
		-- No backdrop of its own: what a form looks like is the backgrounds
		-- it asks for, and a panel behind them darkens every one of them.
		-- The element is still what catches the clicks.
		local window = root:CreateChild("UIElement")
		-- Inherited by everything under it, which is where the text in a
		-- form gets its font
		if ctx.style then
			window.defaultStyle = ctx.style
		end
		window.size = magic.IntVector2(math.floor(layout.width),
				math.floor(layout.height))
		window:SetPosition(ox, oy)
		-- Over the HUD and the hotbar (10), as Luanti draws a form after
		-- the HUD -- a fullscreen bgcolor[] hides them ([UI_PARITY] 11) --
		-- and under the touch controls (49) and the menus (100)
		window.priority = 40
		-- Urho3D leaves an element disabled unless told otherwise, and a
		-- disabled element is not hit by a click: nothing is found under the
		-- mouse and no click event is sent at all
		window.enabled = true

		-- style[name;k=v;...] and style_type[type;k=v;...]. Only the default
		-- state is kept: hovered and pressed need an event this does not get.
		local styles, type_styles = {}, {}
		for _, e in ipairs(elements) do
			if e.name == "style" or e.name == "style_type" then
				local props = {}
				for i = 2, #e.fields do
					local k, v = e.fields[i]:match("^%s*([%w_]+)%s*=%s*(.*)$")
					if k then
						props[k] = v
					end
				end
				local into = e.name == "style" and styles or type_styles
				for target in tostring(e.fields[1] or ""):gmatch("[^,]+") do
					local base, state = target:match("^%s*([^:%s]+):?(.*)$")
					if base and (state == "" or state == "default") then
						into[base] = into[base] or {}
						for k, v in pairs(props) do
							into[base][k] = v
						end
					end
				end
			end
		end

		-- What a named element of a given type is styled as
		-- The parent type's style under the type's, as Luanti's
		-- getStyleForElement(): an item_image_button is styled as an
		-- image_button unless something says otherwise
		local function style_of(element_type, element_name, parent_type)
			local out = {}
			local layers = {parent_type and type_styles[parent_type],
					type_styles[element_type],
					element_name and styles[element_name]}
			for i = 1, 3 do
				for k, v in pairs(layers[i] or {}) do out[k] = v end
			end
			return out
		end

		-- A button's background: the style's image, nine-sliced (the
		-- middle stretches and the border keeps its size, or the image
		-- comes out smeared), else a box unless border=false
		local function button_bg(x, y, w, h, st)
			if st.bgimg and st.bgimg ~= "" then
				local drawn = image(window, x, y, w, h, st.bgimg)
				local tex = drawn and drawn.texture
				local border = drawn and slice_border(st.bgimg_middle,
						tex and tex.width or 0, tex and tex.height or 0)
				if border then
					drawn.imageBorder = border
					drawn.border = border
				end
				if drawn then
					return drawn
				end
			end
			if st.border ~= "false" then
				return box(window, x, y, w, h,
						magic.Color(0.35, 0.35, 0.42, 0.9))
			end
		end

		-- The columns the tables after a tablecolumns[] have, and where the
		-- tables ended up, for whoever handles a click in one
		local columns = {{type = "text", opts = {}}}
		local tables = {}

		-- table[X,Y;W,H;name;cell,cell,...;selected] and its cousin
		-- textlist[]: rows of text in a dark box, a cell per column.
		--
		-- A tree column makes the rows a tree: a row whose next row is
		-- deeper is one that opens, its children are hidden until it is
		-- clicked, and which ones are open is kept in the state the caller
		-- holds. Luanti's own table does the opening client-side as well.
		--
		-- Luanti measures a column's width from what is in it; this counts
		-- characters, which is close enough for the tables a game builds and
		-- needs none of the font's metrics.
		--
		-- simplified: no image or custom colour columns, and the scrollbar
		-- is drawn but not dragged -- the wheel is what scrolls. A cell that
		-- does not fit its column is cut rather than shortened with an
		-- ellipsis.
		local function draw_table(e, x, y, w, h)
			local list = e.name == "table" and columns or
					{{type = "text", opts = {}}}
			local ncol = #list
			local cells = {}
			for _, c in ipairs(formspec.split(e.raw[4] or "", ",")) do
				cells[#cells + 1] = formspec.strip_escapes(
						formspec.unescape(c))
			end
			local name = e.fields[3]
			local rows = {}
			for i = 1, math.ceil(#cells / ncol) do
				local row = {index = i}
				for j = 1, ncol do
					row[j] = cells[(i - 1) * ncol + j] or ""
				end
				rows[i] = row
			end

			-- What each column says about a row: its colour, how deep it is
			-- in the tree
			local color_col, tree_col = nil, nil
			for j, col in ipairs(list) do
				if col.type == "color" then
					color_col = j
				elseif col.type == "tree" or col.type == "indent" then
					tree_col = j
				end
			end
			for i, row in ipairs(rows) do
				row.depth = tree_col and (tonumber(row[tree_col]) or 0) or 0
				row.color = color_col and
						markup_color("\27(c@"..row[color_col]..")") or nil
				-- A cell may name its own colour in front of its text, as
				-- "#rgb" or "#rrggbb"; "##" is one of those characters
				-- rather than the start of a colour
				for j = 1, ncol do
					if j ~= color_col and j ~= tree_col then
						local hex, rest = row[j]:match("^#(%x%x%x%x%x%x)(.*)$")
						if not hex then
							hex, rest = row[j]:match("^#(%x%x%x)([^%x].*)$")
						end
						if hex then
							row.color = row.color or
									markup_color("\27(c@#"..hex..")")
							row[j] = rest
						else
							row[j] = row[j]:gsub("^##", "#")
						end
					end
				end
			end
			for i, row in ipairs(rows) do
				row.opens = tree_col ~= nil and rows[i + 1] ~= nil and
						rows[i + 1].depth > row.depth
			end

			-- Only what is open is on the screen
			local open = state.open[name] or {}
			state.open[name] = open
			local shown = {}
			local hidden_below = nil
			for _, row in ipairs(rows) do
				if hidden_below and row.depth > hidden_below then
					-- A child of something that is closed
				else
					hidden_below = nil
					shown[#shown + 1] = row
					if row.opens and not open[row.index] then
						hidden_below = row.depth
					end
				end
			end

			-- How wide each text column wants to be, by its longest cell
			local CHAR_W = 6.5
			local pad = 3
			local text_cols = {}
			local deepest = 0
			for _, row in ipairs(shown) do
				deepest = math.max(deepest, row.depth)
			end
			for j, col in ipairs(list) do
				if j ~= color_col and j ~= tree_col then
					local longest = 1
					for _, row in ipairs(shown) do
						longest = math.max(longest, #row[j])
					end
					local want = longest * CHAR_W + 12
					if #text_cols == 0 then
						-- The first column is where the tree's indent goes,
						-- and a name pushed to the right needs the room
						want = want + deepest * 14 + 12
					end
					text_cols[#text_cols + 1] = {j = j, want = want}
				end
			end
			-- A column keeps the width it wants, as long as it leaves room
			-- for the ones after it; the last one takes what is left and
			-- what does not fit in it is cut. A single cell with a long line
			-- in it must not be allowed to squeeze the columns before it
			-- down to nothing, which is what sharing the width out in
			-- proportion would do.
			local avail = w - pad * 2
			if #shown > math.max(1, math.floor((h - pad * 2) / 16)) then
				avail = avail - 12 -- the scrollbar's, below
			end
			local left = avail
			for k, tc in ipairs(text_cols) do
				local for_the_rest = (#text_cols - k) * 40
				tc.w = math.max(20, math.min(tc.want, left - for_the_rest))
				left = left - tc.w
			end

			box(window, x, y, w, h, magic.Color(0.04, 0.04, 0.05, 0.92))
			local row_h = 16
			local visible = math.max(1, math.floor((h - pad * 2) / row_h))
			local scroll = math.min(state.scroll[name] or 0,
					math.max(0, #shown - visible))
			-- A scrollbar down the right when the rows do not all fit, as
			-- Luanti's: the thumb as long as the share that shows
			local full_w = w
			if #shown > visible then
				local bar_w = 12
				w = w - bar_w
				box(window, x + w, y, bar_w, h,
						magic.Color(0.25, 0.25, 0.28, 0.95))
				local thumb_h = math.max(8, h * visible / #shown)
				local thumb_y = y + (h - thumb_h) * scroll /
						(#shown - visible)
				box(window, x + w + 1, thumb_y, bar_w - 2, thumb_h,
						magic.Color(0.6, 0.6, 0.62, 0.95))
			end
			-- The row the player picked, else the one the form names:
			-- Luanti's own client selects a clicked row itself and the
			-- game is only told
			local selected = (state.selected or {})[name] or
					tonumber(e.fields[5])
			local on_screen = {}
			for i = scroll + 1, math.min(#shown, scroll + visible) do
				local row = shown[i]
				local ry = y + pad + (i - scroll - 1) * row_h
				if row.index == selected then
					box(window, x + 1, ry, w - 2, row_h,
							magic.Color(0.35, 0.62, 0.23, 0.95))
				end
				local indent = row.depth * 14
				if row.opens then
					label(window, x + pad + indent, ry, 12,
							open[row.index] and "-" or "+", 12, row.color)
				end
				local cx = x + pad
				for k, tc in ipairs(text_cols) do
					-- The tree moves the row's own text to the right; the
					-- columns after the first stay in their places
					local tx = cx + (k == 1 and (indent + 12) or 0)
					local room = tc.w - (tx - cx) - 4
					local fits = math.max(0, math.floor(room / CHAR_W))
					local text = row[tc.j]
					if #text > fits then
						text = text:sub(1, fits)
					end
					if text ~= "" then
						label(window, tx, ry, room, text, 12, row.color)
					end
					cx = cx + tc.w
				end
				on_screen[#on_screen + 1] = {index = row.index, y = ry,
						opens = row.opens}
			end
			tables[#tables + 1] = {name = name, x = x, y = y, w = full_w, h = h,
					row_h = row_h, count = #shown, visible = visible,
					scroll = scroll, rows = on_screen}
		end

		-- The scroll_container being drawn into, if any: what is inside one
		-- is a child of its clipped element, so its coordinates are that
		-- element's and they ride the scrollbar ([FORMSPEC_SCROLL])
		local in_scroll = nil
		local function at(e, field_i)
			local pos = formspec.parse_v2(e.fields[field_i])
			if not pos then
				return nil
			end
			local x = (pos[1] + e.at[1]) * layout.scale[1] + layout.origin[1]
			local y = (pos[2] + e.at[2]) * layout.scale[2] + layout.origin[2]
			if in_scroll then
				return x - in_scroll.x + in_scroll.dx,
						y - in_scroll.y + in_scroll.dy
			end
			return x, y
		end

		local function geometry(e, field_i)
			local g = formspec.parse_v2(e.fields[field_i])
			if not g then
				return nil
			end
			return g[1] * layout.scale[1], g[2] * layout.scale[2]
		end

		-- Before formspec_version 2 Luanti sizes some elements by the slot
		-- rather than the spacing, and a button or a one-line field is a
		-- fixed height about the middle of its cell (guiFormSpecMenu.cpp,
		-- each parse function's legacy branch; m_btn_height)
		local legacy = layout.origin[1] ~= 0
		local sx, sy, imgsize = layout.scale[1], layout.scale[2], layout.imgsize
		local btn_h = imgsize * 15 / 13 * 0.35

		-- A form the game gave no bgcolor[] gets a dark grey one over the
		-- whole of it. A form is drawn over the world, and text on top of a
		-- sunlit hillside cannot be read. A background[] does not take it
		-- away: Luanti draws its default bgcolor under every form, and
		-- VoxeLibre's achievements lost their backdrop to a progress bar's
		-- background[] ([VL_ACHIEVE_BG]).
		layout.slot_bg, layout.tip_bg, layout.tip_fg = nil, nil, nil
		-- bgcolor[color;fullscreen;fbgcolor], as Luanti's
		-- parseBackgroundColor(): the form's colour, whether it or the
		-- screen's is drawn ("both", "neither", or yes for the screen's
		-- only), and the screen's colour ([UI_PARITY] 8)
		local bg = nil
		for _, e in ipairs(elements) do
			if e.name == "bgcolor" then
				bg = bg or {form = true, color = {r = 0, g = 0, b = 0,
						a = 140 / 255}, screen_color = {r = 0, g = 0, b = 0,
						a = 140 / 255}}
				local f = e.fields
				local c = f[1] and f[1] ~= "" and formspec.color_of(f[1])
				if c then
					bg.color = c
				end
				local mode = f[2]
				if mode == "both" then
					bg.form, bg.screen = true, true
				elseif mode == "neither" then
					bg.form, bg.screen = false, false
				elseif mode and mode ~= "" then
					bg.screen = mode == "true" or mode == "yes" or mode == "1"
					bg.form = not bg.screen
				end
				c = f[3] and f[3] ~= "" and formspec.color_of(f[3])
				if c then
					bg.screen_color = c
				end
			elseif e.name == "listcolors" and #e.fields ~= 4 then
				-- (four fields is no listcolors at all to Luanti)
				-- [UI_PARITY] Its slot colour, on every list of the form, as
				-- Luanti's; opaque unless it says otherwise.
				-- And the tooltips' colours, the fourth and fifth.
				-- simplified: the hover colour and the slot border are not
				-- drawn
				local c = formspec.color_of(e.fields[1])
				layout.slot_bg = c and magic.Color(c.r, c.g, c.b, c.a or 1)
				if #e.fields >= 5 then
					layout.tip_bg = formspec.color_of(e.fields[4])
					layout.tip_fg = formspec.color_of(e.fields[5])
				end
			end
		end
		local function rgba(c)
			return magic.Color(c.r, c.g, c.b, c.a or 1)
		end
		if bg then
			if bg.screen then
				box(window, -ox, -oy, screen_w, screen_h, rgba(bg.screen_color))
			end
			if bg.form then
				box(window, 0, 0, layout.width, layout.height, rgba(bg.color))
			end
		else
			box(window, 0, 0, layout.width, layout.height,
					magic.Color(0.12, 0.12, 0.14, 0.94))
		end

		-- Luanti draws the backgrounds in a pass of their own, behind
		-- everything else, whatever order they are in; a background that is
		-- drawn in element order covers the slots that came before it.
		for _, e in ipairs(elements) do
			if e.name == "background" or e.name == "background9" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				local pos = formspec.parse_v2(e.fields[1])
				local f4 = e.fields[4]
				if pos and (f4 == "true" or f4 == "yes" or f4 == "1") then
					-- auto_clip: the whole form, w and h not used, and x and
					-- y as Luanti's parseBackground() takes them
					-- ([UI_PARITY] 8): in real coordinates the form shrunk
					-- by that many units on every side, in legacy ones
					-- grown by that many whole pixels, and a prepend's
					-- always in legacy ones
					local dx, dy
					if layout.origin[1] == 0 and not e.prepend then
						dx = -(pos[1] + e.at[1]) * layout.scale[1]
						dy = -(pos[2] + e.at[2]) * layout.scale[2]
					else
						dx = pos[1] >= 0 and math.floor(pos[1]) or
								math.ceil(pos[1])
						dy = pos[2] >= 0 and math.floor(pos[2]) or
								math.ceil(pos[2])
					end
					x, y = -dx, -dy
					w, h = layout.width + 2 * dx, layout.height + 2 * dy
				end
				if x and w then
					local img = image(window, x, y, w, h, e.fields[3])
					if img and e.name == "background9" then
						local tex = img.texture
						local border = slice_border(e.fields[5],
								tex and tex.width or 0, tex and tex.height or 0)
						if border then
							img.imageBorder = border
							img.border = border
						end
					end
				end
			end
		end

		-- What each kind of element cost, for the slow-draw line
		-- ([FORMSPEC_FRAME]): the inventory drew in 251 ms with 82
		-- elements and 8 ms of pictures, and this says where the rest went
		self.kind_us = {}
		local kind_us = self.kind_us
		local scroll_boxes = {}
		-- The containers as rectangles, for the wheel over one, and the
		-- scrollbars for dragging their thumbs
		local scrolls = {}
		local bars = {}
		-- What the next scrollbar's range is; scrollbaroptions[] sets it and
		-- Luanti's default is 0..1000
		local bar_max = 1000
		local form_window = window
		for _, e in ipairs(elements) do
			local name = e.name
			local te = buildat.get_time_us()
			-- Inside a scroll_container: drawn into its clipped element,
			-- and at() answers in that element's coordinates
			in_scroll = e.scroll and scroll_boxes[e.scroll] or nil
			window = in_scroll and in_scroll.element or form_window
			if IGNORED[name] then
				-- Nothing to draw
			elseif name == "background" or name == "background9" then
				-- Drawn in the pass above
			elseif name == "list" then
				draw_list(window, layout, e, slots, state.held)
			elseif name == "image" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if legacy and w then
					w, h = w / sx * imgsize, h / sy * imgsize
				end
				if x and w then
					-- Nothing at all for a texture that is not there yet:
					-- these cover a whole form, and a grey box each hides
					-- what the form is made of. The media is asked for when
					-- the texture is wanted, and the form is drawn again
					-- when it arrives.
					local img = image(window, x, y, w, h, e.fields[3])
					-- A middle (formspec_version 6) slices it as
					-- background9[] does, the border at its texels' size
					local tex = img and e.fields[4] and img.texture
					local border = tex and slice_border(e.fields[4],
							tex.width, tex.height)
					if border then
						img.imageBorder = border
						img.border = border
					end
				end
			elseif name == "box" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				-- Its colour at Luanti's alpha 0x8C where the string has
				-- none; a colour it cannot read draws nothing, as Luanti's
				local c = formspec.color_of(e.fields[3])
				if x and w and c then
					box(window, x, y, w, h,
							magic.Color(c.r, c.g, c.b, c.a or 0x8C / 255))
				end
			elseif name == "item_image" or name == "item_image_button" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				local is_button = name == "item_image_button"
				if legacy and w then
					if is_button then
						w, h = w - (sx - imgsize), h - (sy - imgsize)
					else
						w, h = w / sx * imgsize, h / sy * imgsize
					end
				end
				if x and w then
					if is_button then
						button_bg(x, y, w, h,
								style_of(name, e.fields[4], "image_button"))
					end
					draw_stack(window, x, y, math.min(w, h),
							{name = e.fields[3], count = 1})
					if name == "item_image_button" then
						buttons[#buttons + 1] = {name = e.fields[4],
								x = x, y = y, w = w, h = h}
					end
				end
			elseif name == "button" or name == "button_exit" or
					name == "image_button" or name == "image_button_exit" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				local is_image = name:sub(1, 5) == "image"
				if legacy and x and w then
					w = w - (sx - imgsize)
					if is_image then
						h = h - (sy - imgsize)
					else
						y, h = y + h / sy * imgsize / 2 - btn_h, btn_h * 2
					end
				end
				if x and w then
					local button_name = is_image and e.fields[4] or e.fields[3]
					local text = is_image and e.fields[5] or e.fields[4]
					local st = style_of(name, button_name)
					-- The button under its image, as Luanti: the style's
					-- bgimg, or a box unless border=false (VoxeLibre's
					-- recipe book buttons are its bgimg with an icon on it)
					button_bg(x, y, w, h, st)
					if is_image then
						image(window, x, y, w, h, e.fields[3])
					end
					if text and text ~= "" then
						-- Luanti centres a button's text in it
						local t = label(window, x + 4, y + h / 2 - 8, w - 8,
								formspec.strip_escapes(text), 12,
								st.textcolor and markup_color(
										"\27(c@"..st.textcolor..")"))
						t:SetTextAlignment(1) -- HA_CENTER
					end
					-- A press sends the label, as Luanti does
					buttons[#buttons + 1] = {name = button_name,
							x = x, y = y, w = w, h = h,
							value = formspec.strip_escapes(text or ""),
							exit = name:sub(-5) == "_exit"}
				end
			elseif name == "tabheader" then
				-- tabheader[X,Y;name;caption,...;current;...] and the newer
				-- form with a W,H after the position. The tabs are drawn
				-- across the form, the one that is on lighter than the rest.
				--
				-- simplified: a tab's width comes from counting the
				-- characters of its caption rather than from the font, and
				-- neither the transparent nor the border flag is honoured.
				local x, y = at(e, 1)
				local sized = formspec.parse_v2(e.fields[2]) ~= nil
				local i0 = sized and 3 or 2
				local w = sized and select(1, geometry(e, 2)) or layout.width
				-- Luanti's own tab height, twice its button height, and its
				-- y is the bottom of the tabs rather than the top: they sit
				-- above whatever the form puts at the same y
				local h = layout.imgsize * 15 / 13 * 0.35 * 2
				y = y - h
				local captions = {}
				for _, c in ipairs(formspec.split(e.raw[i0 + 1] or "", ",")) do
					captions[#captions + 1] = formspec.strip_escapes(
							formspec.unescape(c))
				end
				local current = tonumber(e.fields[i0 + 2]) or 1
				if x and #captions > 0 then
					local tx = x
					for i, caption in ipairs(captions) do
						-- As wide as its own caption, which is what
						-- Luanti's tab control does
						local tw = #caption * 6.5 + 18
						box(window, tx, y, tw - 2, h, i == current and
								magic.Color(0.75, 0.75, 0.78, 0.95) or
								magic.Color(0.35, 0.35, 0.4, 0.9))
						local t = label(window, tx, y + h / 2 - 8, tw - 2,
								caption, 12, i == current and
								magic.Color(0.1, 0.1, 0.1) or nil)
						t:SetTextAlignment(1) -- HA_CENTER
						taps[#taps + 1] = {name = e.fields[i0],
								value = tostring(i), x = tx, y = y,
								w = tw - 2, h = h}
						tx = tx + tw
					end
				end
			elseif name == "checkbox" then
				-- checkbox[X,Y;name;label;selected]. The state the player
				-- clicked wins over the one the form was drawn with, so that
				-- the tick moves before the server has answered.
				local x, y = at(e, 1)
				if x then
					local on = state.check[e.fields[2]]
					if on == nil then
						on = e.fields[4] == "true"
					end
					local size = math.floor(layout.imgsize * 0.35)
					-- A label's y is the middle of its line, and so is a
					-- checkbox's
					local cy = y - size / 2
					-- Luanti's skin: a grey box edged dark, and the label
					-- in the skin's white whatever the style's textcolor
					-- (parseCheckbox reads no colour from it)
					box(window, x, cy, size, size, magic.Color(0, 0, 0))
					box(window, x + 1, cy + 1, size - 2, size - 2,
							magic.Color(0.5, 0.5, 0.5))
					if on then
						box(window, x + 3, cy + 3, size - 6, size - 6,
								magic.Color(0.85, 0.85, 0.9, 0.95))
					end
					label(window, x + size + 6, y - 8, nil,
							formspec.strip_escapes(e.fields[3] or ""), 13)
					taps[#taps + 1] = {name = e.fields[2],
							value = tostring(not on), x = x, y = cy,
							w = size, h = size, check = true}
				end
			elseif name == "table" or name == "textlist" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					draw_table(e, x, y, w, h)
				end
			elseif name == "animated_image" then
				-- animated_image[X,Y;W,H;name;texture;frame count;frame
				-- duration;frame start]: the texture is a vertical strip
				-- of frames and this draws one of them ([FORMSPEC_SCROLL]).
				--
				-- simplified: the frame stands still -- the one the element
				-- names as its start, or the first -- where Luanti runs
				-- through them at the duration it gives.
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				local frames = math.max(1, math.floor(
						tonumber(e.fields[6]) or 1))
				local first = math.max(1, math.min(frames,
						math.floor(tonumber(e.fields[8]) or 1)))
				if x and w then
					local el = image(window, x, y, w, h, e.fields[4])
					if el and frames > 1 and el.texture and
							el.texture.height > 0 then
						local fh = math.floor(el.texture.height / frames)
						el.imageRect = magic.IntRect(0, fh * (first - 1),
								el.texture.width, fh * first)
					end
				end
			elseif name == "button_url" or name == "button_url_exit" then
				-- button_url[X,Y;W,H;name;label;url]: a button that says
				-- where it would take the player. **The client does not
				-- open it**: a form from a server is not something this
				-- client hands to a browser, and Luanti asks the player
				-- first for the same reason. The url is drawn under the
				-- label and the press goes back as a button's does, so a
				-- game that reacts to it still works.
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					box(window, x, y, w, h,
							magic.Color(0.35, 0.35, 0.42, 0.9))
					local t = label(window, x + 4, y + 2, w - 8,
							formspec.strip_escapes(e.fields[4] or ""), 12)
					t:SetTextAlignment(1)
					local url = formspec.strip_escapes(e.fields[5] or "")
					if url ~= "" and h > 22 then
						local u = label(window, x + 4, y + h - 16, w - 8,
								url, 10, magic.Color(0.7, 0.75, 0.9))
						u:SetTextAlignment(1)
					end
					buttons[#buttons + 1] = {name = e.fields[3],
							x = x, y = y, w = w, h = h,
							exit = name:sub(-5) == "_exit"}
				end
			elseif name == "hypertext" then
				-- hypertext[X,Y;W,H;name;text]: the text with its tags
				-- taken out, wrapped in the box, and each <action ...>
				-- run as a button under it ([FORMSPEC_SCROLL]). Clicking
				-- one sends the element's name with "action:<the action's
				-- name>", which is what Luanti's own client sends.
				--
				-- The styles: <center>, <big>, <bigger>, <mono>, <style
				-- color= size=>, <global color= size= halign=>, and a
				-- <tag name=> the text defines, inside a line too -- its
				-- runs are wrapped word by word, each word measured in its
				-- run's font and size, and a row drawn a Text a run.
				--
				-- simplified: no bold, italic or table; a word wider than
				-- the box runs over it. The actions are gathered under the
				-- text rather than staying inline where they were written.
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				local hname = e.fields[3]
				local raw = formspec.unescape(e.raw[4] or "")
				if x and w then
					local actions = {}
					-- <action name=foo>label</action>, and the older
					-- <action name=foo> with no closing tag
					for aname, atext in raw:gmatch(
							"<action%s+name=([%w_]+)%s*>(.-)</action>") do
						actions[#actions + 1] = {name = aname,
								text = atext:gsub("<[^>]*>", "")}
					end
					local by = y + h - 20 * #actions
					local ty = y + 2
					local function font_of(run)
						return magic.cache:GetResource("Font", run.mono and
								buildat.font_mono or buildat.font_sans)
					end
					-- A word's width in its run's font, by a Text never shown
					local meter = label(window, 0, 0, nil, "", 12)
					meter.visible = false
					local function measure(s_, run)
						meter:SetFont(font_of(run), run.size)
						meter.text = s_
						return meter.width
					end
					for _, line in ipairs(hypertext_lines((raw:gsub(
							"<action%s+name=[%w_]+%s*>.-</action>", "")))) do
						if line.img then
							-- Its own size where it says none, at a form's
							-- 12 to Luanti's 16 as the text, no wider than
							-- the box
							local tex = texture(line.img)
							local iw = (line.w or (tex and tex.width > 0 and
									tex.width) or 32) * 12 / 16
							local ih = (line.h or (tex and tex.height > 0 and
									tex.height) or 32) * 12 / 16
							if iw > w - 4 then
								iw, ih = w - 4, ih * (w - 4) / iw
							end
							if ty + ih > by then
								break
							end
							image(window, x + 2 + (line.center and
									(w - 4 - iw) / 2 or 0), ty, iw, ih, line.img)
							ty = ty + ih
						elseif #line.runs == 0 then
							ty = ty + line.size
						else
							-- The rows: each a list of {run, text, x}, a
							-- run's words joined while they stay on it
							local rows, row, rx = {}, {}, 0
							local space = false
							for _, run in ipairs(line.runs) do
								local t = formspec.strip_escapes(run.text)
								for sp, word in t:gmatch("(%s*)(%S*)") do
									space = space or sp ~= ""
									if word ~= "" then
										local tok = (space and rx > 0) and
												" " .. word or word
										local tw = measure(tok, run)
										if rx > 0 and rx + tw > w - 4 then
											rows[#rows + 1] = {segs = row, w = rx}
											row, rx, tok = {}, 0, word
											tw = measure(tok, run)
										end
										local last = row[#row]
										if last and last.run == run then
											last.text = last.text .. tok
										else
											row[#row + 1] = {run = run,
													text = tok, x = rx}
										end
										rx, space = rx + tw, false
									end
								end
							end
							if #row > 0 then
								rows[#rows + 1] = {segs = row, w = rx}
							end
							for _, r in ipairs(rows) do
								local rh, ts = 0, {}
								for i, seg in ipairs(r.segs) do
									local c = seg.run.color
									ts[i] = label(window, 0, 0, nil, seg.text,
											seg.run.size,
											c and magic.Color(c.r, c.g, c.b))
									ts[i]:SetFont(font_of(seg.run), seg.run.size)
									rh = math.max(rh, ts[i].height)
								end
								if ty + rh > by then
									for _, t in ipairs(ts) do
										t:Remove()
									end
									break
								end
								local x0 = x + 2 + (line.center and
										math.max(0, (w - 4 - r.w) / 2) or 0)
								for i, seg in ipairs(r.segs) do
									ts[i]:SetPosition(math.floor(x0 + seg.x),
											math.floor(ty + rh - ts[i].height))
								end
								ty = ty + rh
							end
						end
					end
					by = y + h
					for i = #actions, 1, -1 do
						local a = actions[i]
						by = by - 20
						box(window, x + 2, by, w - 4, 18,
								magic.Color(0.3, 0.3, 0.38, 0.9))
						local at_ = label(window, x + 6, by + 1, w - 12,
								a.text ~= "" and a.text or a.name, 12)
						at_:SetTextAlignment(1)
						buttons[#buttons + 1] = {name = hname,
								value = "action:"..a.name,
								x = x + 2, y = by, w = w - 4, h = 18}
					end
				end
			elseif name == "scrollbaroptions" then
				-- scrollbaroptions[opt=value;...]: what the next scrollbar's
				-- range is. Only max is read; the steps are how far a key
				-- or a wheel moves one, and neither drives a bar here.
				for _, f in ipairs(e.fields) do
					local k, v = tostring(f):match("^%s*(%w+)%s*=%s*(.+)$")
					if k == "max" then
						bar_max = tonumber(v) or bar_max
					end
				end
			elseif name == "scrollbar" then
				-- scrollbar[X,Y;W,H;orientation;name;value]: a trough with
				-- a thumb in it. A click in the trough pages by a tenth of
				-- the range towards where it was clicked, and the value
				-- goes back as "CHG:<value>", which is what Luanti's own
				-- client sends ([FORMSPEC_SCROLL]).
				--
				-- simplified: the thumb is a fixed fifth of the trough and
				-- is not dragged -- the range a scrollbaroptions[] names is
				-- not read either, so the range is Luanti's default 0..1000
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				local vertical = tostring(e.fields[3] or "vertical")
						:lower() ~= "horizontal"
				local bar = e.fields[4]
				if x and w and bar then
					state.scroll = state.scroll or {}
					local v = state.scroll[bar] or tonumber(e.fields[5]) or 0
					state.scroll[bar] = v
					-- Luanti's own default range, unless a
					-- scrollbaroptions[] in front of this one said another
					local max = bar_max
					local step = math.max(1, math.floor(max / 10))
					box(window, x, y, w, h,
							magic.Color(0.1, 0.1, 0.12, 0.9))
					-- The bar as a rectangle, for dragging its thumb
					bars[#bars + 1] = {name = bar, x = x, y = y, w = w,
							h = h, vertical = vertical, max = max}
					local frac = math.max(0, math.min(1, v / max))
					if vertical then
						local th = h / 5
						box(window, x + 1, y + (h - th) * frac, w - 2, th,
								magic.Color(0.45, 0.45, 0.55, 0.95))
						taps[#taps + 1] = {name = bar, scroll = -step,
								x = x, y = y, w = w, h = h / 2,
								value = "CHG:"..math.max(0, v - step)}
						taps[#taps + 1] = {name = bar, scroll = step,
								x = x, y = y + h / 2, w = w, h = h / 2,
								value = "CHG:"..math.min(max, v + step)}
					else
						local tw = w / 5
						box(window, x + (w - tw) * frac, y + 1, tw, h - 2,
								magic.Color(0.45, 0.45, 0.55, 0.95))
						taps[#taps + 1] = {name = bar, scroll = -step,
								x = x, y = y, w = w / 2, h = h,
								value = "CHG:"..math.max(0, v - step)}
						taps[#taps + 1] = {name = bar, scroll = step,
								x = x + w / 2, y = y, w = w / 2, h = h,
								value = "CHG:"..math.min(max, v + step)}
					end
				end
			elseif name == "scroll_container" then
				-- scroll_container[X,Y;W,H;scrollbar name;orientation;
				-- factor]: a box that clips what is drawn in it, moved by
				-- the scrollbar of that name ([FORMSPEC_SCROLL]). The
				-- factor is in formspec units per scrollbar unit; Luanti's
				-- own default is 0.1.
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				local bar = e.fields[3]
				local vertical = tostring(e.fields[4] or "vertical")
						:lower() ~= "horizontal"
				local factor = tonumber(e.fields[5]) or 0.1
				if x and w then
					local el = window:CreateChild("UIElement")
					el:SetPosition(math.floor(x), math.floor(y))
					el.size = magic.IntVector2(math.floor(w), math.floor(h))
					el.clipChildren = true
					state.scroll = state.scroll or {}
					local v = state.scroll[bar] or 0
					local moved = v * factor * layout.scale[vertical and 2 or 1]
					-- The value is in the bar's own units and the factor is
					-- formspec units per one of them
					-- per: pixels a bar unit moves it, for Page Up and Down
					scroll_boxes[e.scroll_id] = {element = el, x = x, y = y,
							w = w, h = h, bar = bar, vertical = vertical,
							per = factor * layout.scale[vertical and 2 or 1],
							dx = vertical and 0 or -moved,
							dy = vertical and -moved or 0}
					scrolls[#scrolls + 1] = scroll_boxes[e.scroll_id]
				end
			elseif name == "dropdown" then
				-- dropdown[X,Y;W;name;item1,item2,...;selected;index event]
				-- and the newer form with W,H. Drawn as the chosen item in
				-- a box; a click opens the list under it and a click in
				-- that picks ([FORMSPEC_SCROLL]).
				--
				-- simplified: the list is drawn over whatever is under it
				-- without a shadow, and it is as tall as it needs to be
				-- rather than scrolling at some number of items.
				local x, y = at(e, 1)
				local sized = formspec.parse_v2(e.fields[2]) ~= nil
				local w, h
				if sized then
					w, h = geometry(e, 2)
				else
					-- The old form gives a width in formspec units and no
					-- height; Luanti's own is a button's height
					w = (tonumber(e.fields[2]) or 0) * layout.scale[1]
					h = layout.imgsize * 15 / 13 * 0.35
				end
				local i0 = sized and 3 or 3
				local dname = e.fields[i0]
				local items = {}
				for _, it in ipairs(formspec.split(e.raw[i0 + 1] or "", ",")) do
					items[#items + 1] = formspec.strip_escapes(
							formspec.unescape(it))
				end
				local index_event = tostring(e.fields[i0 + 3] or "") == "true"
				if x and w and dname then
					state.dropdown = state.dropdown or {}
					local chosen = state.dropdown[dname] or
							tonumber(e.fields[i0 + 2]) or 1
					if chosen < 1 or chosen > #items then
						chosen = 1
					end
					state.dropdown[dname] = chosen
					local text = items[chosen] or ""
					box(window, x, y, w, h,
							magic.Color(0.2, 0.2, 0.25, 0.9))
					label(window, x + 4, y + h / 2 - 8, w - 20, text, 12)
					label(window, x + w - 14, y + h / 2 - 8, 12, "v", 12)
					-- Its value rides with every submit, as a field's does
					fields[#fields + 1] = {name = dname, x = x, y = y,
							w = w, h = h,
							value = index_event and tostring(chosen) or text}
					taps[#taps + 1] = {name = dname, open = true,
							x = x, y = y, w = w, h = h}
					if state.dropdown_open == dname then
						for i, it in ipairs(items) do
							local iy = y + h * i
							box(window, x, iy, w, h, i == chosen and
									magic.Color(0.35, 0.35, 0.5, 0.95) or
									magic.Color(0.15, 0.15, 0.2, 0.95))
							label(window, x + 4, iy + h / 2 - 8, w - 8, it, 12)
							taps[#taps + 1] = {name = dname, pick = i,
									x = x, y = iy, w = w, h = h,
									value = index_event and tostring(i) or it}
						end
					end
				end
			elseif name == "tablecolumns" then
				columns = parse_columns(e.fields)
			elseif name == "textarea" then
				-- textarea[X,Y;W,H;name;label;default], its label above it.
				-- A nameless one is text to read, wrapped in its box, and
				-- with no default Luanti shows its label there instead
				-- (parseField's swap for old forms): VoxeLibre's
				-- achievement descriptions are written that way.
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if legacy and x and w then
					x, y = x - layout.origin[1], y - layout.origin[2] + btn_h
					w = w - (sx - imgsize)
				end
				if x and w then
					local st = style_of(name, e.fields[3])
					local color = st.textcolor and
							markup_color("\27(c@"..st.textcolor..")")
					local text, above = e.fields[5] or "", e.fields[4] or ""
					if (e.fields[3] or "") == "" and text == "" then
						text, above = above, ""
					end
					if text ~= "" then
						-- A read-only multi-line edit with no box, so text
						-- longer than the box scrolls by the wheel as
						-- Luanti's does ([TEXTAREA_WHEEL]); it wraps at its
						-- width itself
						local t = window:CreateChild("LineEdit")
						t:SetStyleAuto()
						t.multiLine = true
						t.editable = false
						t.textSelectable = true
						t.textCopyable = true
						t:SetPosition(math.floor(x), math.floor(y))
						t.size = magic.IntVector2(math.floor(w), math.floor(h))
						t.enabled = true
						t.priority = next_priority()
						t.color = magic.Color(0, 0, 0, 0)
						t.cursor.color = magic.Color(0, 0, 0, 0)
						t.textElement:SetFontSize(13)
						t.textElement.color = markup_color(text) or color or
								magic.Color(1, 1, 1)
						t:SetText(formspec.strip_escapes(text))
						t.cursorPosition = 0
					end
					if above ~= "" then
						label(window, x, y - 15, nil,
								formspec.strip_escapes(above), 12, color)
					end
				end
			elseif name == "label" or name == "vertlabel" then
				local x, y = at(e, 1)
				if legacy and y then
					y = y + 7 / 30 * sy
				end
				local text = e.fields[2]
				if name == "vertlabel" and text then
					-- Luanti's own: the label with a line break after each
					-- character (guiFormSpecMenu.cpp parseVertLabel)
					text = text:gsub("[%z\1-\127\194-\244][\128-\191]*",
							"%0\n"):gsub("\n$", "")
				end
				-- label[X,Y;W,H;label] as well as label[X,Y;label]. The
				-- sized form is the one style_type[label;halign=...] has a
				-- box to align inside, and it is what the builtin's death
				-- screen is written with: without it "You died" came out as
				-- "3.5,0.8", the box drawn where the words should be. A
				-- second field that parses as a pair is what says which form
				-- this is, because a semicolon inside a label is escaped.
				local w, h
				if name == "label" and e.fields[3] then
					w, h = geometry(e, 2)
					if w then
						text = e.fields[3]
					end
				end
				if x and text then
					local st = style_of(name, nil)
					-- A label's y is the middle of its line; a sized one is
					-- aligned inside its box instead
					local ty = w and (y + h / 2 - 8) or (y - 8)
					local t = label(window, x, ty, nil,
							formspec.strip_escapes(text), 13,
							markup_color(text) or
									(st.textcolor and
									markup_color("\27(c@"..st.textcolor..")")))
					if w and st.halign == "center" then
						t:SetPosition(math.floor(x + (w - t.width) / 2),
								math.floor(ty))
					elseif w and st.halign == "right" then
						t:SetPosition(math.floor(x + w - t.width),
								math.floor(ty))
					end
				end
			elseif name == "field" or name == "pwdfield" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if legacy and x and w then
					x = x - layout.origin[1]
					y = y - layout.origin[2] + h / sy * imgsize / 2 - btn_h
					w, h = w - (sx - imgsize), btn_h * 2
				end
				if x and w then
					local st = style_of(name, e.fields[3])
					local bg = st.bgcolor and
							markup_color("\27(c@"..st.bgcolor..")")
					if st.bgimg and st.bgimg ~= "" then
						image(window, x, y, w, h, st.bgimg)
					end
					-- A line edit of Urho3D's own, so that the field can be
					-- typed into; it is drawn dark with light text in it,
					-- which is what Luanti's own field looks like
					local edit = window:CreateChild("LineEdit")
					-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
					edit.textCopyable = true
					edit.textSelectable = true
					if ctx.style then
						edit.defaultStyle = ctx.style
					end
					edit:SetStyleAuto()
					edit:SetPosition(math.floor(x), math.floor(y))
					edit.size = magic.IntVector2(math.floor(w),
							math.floor(h))
					edit.enabled = true
					edit.priority = next_priority()
					edit.texture = magic.cache:GetResource("Texture2D", WHITE)
					-- Luanti's skin: grey, and green while it has the keys
					-- (EGDC_EDITABLE, EGDC_FOCUSED_EDITABLE)
					edit.color = bg or magic.Color(0.5, 0.5, 0.5)
					if not bg then
						magic.SubscribeToEvent(edit, "Focused", function()
							edit.color = magic.Color(96 / 255, 134 / 255,
									49 / 255)
						end)
						magic.SubscribeToEvent(edit, "Defocused", function()
							edit.color = magic.Color(0.5, 0.5, 0.5)
						end)
					end
					local value = name == "field" and e.fields[5] or ""
					edit:SetText(formspec.strip_escapes(value or ""))
					-- The text fits the field: the style's size is for the
					-- style's own field, and a form at a phone's scale made
					-- it taller than the box (user, 2026-09-30)
					local te = edit.textElement
					if te then
						te:SetFontSize(math.max(8, math.min(14,
								math.floor(h * 0.6))))
					end
					local fg = st.textcolor and
							markup_color("\27(c@"..st.textcolor..")")
					if te and fg then
						te:SetColor(fg)
					end
					if name == "pwdfield" then
						edit.echoCharacter = 42 -- an asterisk
					end
					-- The field's label goes above it, as Luanti puts it
					local text = e.fields[4]
					if text and text ~= "" then
						label(window, x, y - 15, nil,
								formspec.strip_escapes(text), 12)
					end
					fields[#fields + 1] = {name = e.fields[3],
							value = value or "", edit = edit,
							x = x, y = y, w = w, h = h}
				end
			elseif name == "tooltip" then
				-- tooltip[X,Y;W,H;text;...] over an area, or
				-- tooltip[element;text;...] over a named element, either
				-- with a background and a text colour after the text
				local first = tostring(e.fields[1] or "")
				if first:match("^%-?[%d.]+,%-?[%d.]+$") and #e.fields >= 3 then
					local x, y = at(e, 1)
					local w, h = geometry(e, 2)
					if x and w then
						tooltips[#tooltips + 1] = {x = x, y = y, w = w,
								h = h, text = formspec.strip_escapes(
										e.fields[3] or ""),
								bg = e.fields[4] and
										formspec.color_of(e.fields[4]),
								fg = e.fields[5] and
										formspec.color_of(e.fields[5])}
					end
				elseif e.fields[2] then
					named_tooltips[first] = {
							text = formspec.strip_escapes(e.fields[2]),
							bg = e.fields[3] and formspec.color_of(e.fields[3]),
							fg = e.fields[4] and formspec.color_of(e.fields[4])}
				end
			elseif name == "model" then
				-- model[X,Y;W,H;name;mesh;textures;rotation_X,rotation_Y;
				-- continuous;mouse_control;frame_loop;animation_speed].
				-- What ctx.model draws is the mesh at those angles; the
				-- rest of the fields are about animation and dragging,
				-- which the drawing does not do.
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w and ctx.model then
					local textures = {}
					for _, t in ipairs(formspec.split(e.raw[5] or "", ",")) do
						textures[#textures + 1] = formspec.unescape(t)
					end
					local rot = formspec.parse_v2(e.fields[6])
					local view = ctx.model(window, w, h, e.fields[4],
							textures, rot and rot[1] or 0,
							rot and rot[2] or 0)
					if view then
						view:SetPosition(math.floor(x), math.floor(y))
						view.priority = next_priority()
					end
				end
			elseif name == "set_focus" or name == "field_close_on_enter" then
				-- Read after the pass, where the fields are all known
			elseif not unknown[name] then
				unknown[name] = true
				log:info("formspec: nothing drawn for \""..name.."\"")
			end
			kind_us[name] = (kind_us[name] or 0) + buildat.get_time_us() - te
		end
		-- field_close_on_enter[name;bool] says whether pressing enter in a
		-- field closes the form; a field nobody said anything about does.
		-- set_focus[name;force] is which field starts with the keys.
		local close_on_enter = {}
		local focus_name = nil
		for _, e in ipairs(elements) do
			if e.name == "field_close_on_enter" then
				close_on_enter[e.fields[1]] = e.fields[2] ~= "false"
			elseif e.name == "set_focus" then
				focus_name = e.fields[1]
			end
		end
		-- None said: the first empty field, else the first field, as
		-- Luanti's setInitialFocus()
		if not focus_name then
			for _, f in ipairs(fields) do
				if f.edit and f.value == "" then
					focus_name = f.name
					break
				end
			end
			focus_name = focus_name or (fields[1] and fields[1].name)
		end
		-- Not on a touchscreen: a focused field opens its keyboard over the
		-- form, and the field is the player's to tap (user, 2026-09-30)
		if buildat.get_env("BUILDAT_TOUCH") == "1" then
			focus_name = nil
		end
		for _, f in ipairs(fields) do
			if f.name == focus_name and f.edit then
				-- On the next frame, not this one: the key that opened
				-- the form is a KeyDown followed by its TextInput in the
				-- same frame, and a field focused now takes the letter
				-- (the inventory key typed into the search field;
				-- [BOX_PLAYTEST_2] 8). Official swallows the key the
				-- same way.
				local edit = f.edit
				local sub
				sub = magic.SubscribeToEvent("Update", function()
					magic.UnsubscribeFromEvent("Update", sub)
					-- A form closed within the frame has no field left
					pcall(function() edit:SetFocus(true) end)
				end)
			end
		end
		-- A tooltip on a named element goes where that element ended up
		if next(named_tooltips) then
			local rects = {}
			for _, list in ipairs({buttons, taps, fields}) do
				for _, entry in ipairs(list) do
					if entry.name and entry.w then
						rects[entry.name] = entry
					end
				end
			end
			for element_name, t in pairs(named_tooltips) do
				local r = rects[element_name]
				if r then
					tooltips[#tooltips + 1] = {x = r.x, y = r.y, w = r.w,
							h = r.h, text = t.text, bg = t.bg, fg = t.fg}
				end
			end
		end
		-- The loop above points `window` at whatever it was drawing into
		window = form_window
		return {window = window, origin = {ox, oy},
				size = {layout.width, layout.height}, slots = slots,
				buttons = buttons, fields = fields, tables = tables,
				scrolls = scrolls, bars = bars,
				taps = taps, tooltips = tooltips,
				-- Luanti's m_btn_height, which a tooltip sits that far
				-- right of and below the cursor by
				-- simplified: a legacy form's is the font's line height
				-- there, here the same share of a slot as in real ones
				tip_offset = layout.slot * 15 / 13 * 0.35,
				tip_bg = layout.tip_bg, tip_fg = layout.tip_fg,
				close_on_enter = close_on_enter}
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
