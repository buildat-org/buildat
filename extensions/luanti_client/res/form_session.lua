-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- The form on the screen and what the player does to it, for both Luanti
-- clients ([LUANTI_SHARED]): opening and closing one, drawing it again,
-- a click on a button, a tab, a table's row or a slot, the stack carried
-- between slots, the wheel, a scrollbar's thumb dragged, enter in a field,
-- the tooltip. Drawing is formspec_ui's; what goes out to the server, and
-- where a slot's stack comes from, is the client's, through env.
--
--   local session = form_session.new(env)
--
-- env:
--   magic, log, formspec  as everywhere
--   ui                    a formspec_ui
--   send_fields(form, fields)  a form's fields to whoever showed it; a
--                         form a client opened for itself (form.handler)
--                         never gets here
--   move(count, from, to) a stack moved; from and to are {location, list,
--                         index}
--   drop(count, from)     optional: the carried stack thrown away; without
--                         it a stack let go of off the form goes back
--   craft(count, location) optional: a click on craftpreview crafts count,
--                         and the hand carries craftresult; without it
--                         the preview is a slot like any other
--   item_description(name) -> the text over a slot, or nil
--   item_image(name)      -> a texture resource for the stack in hand
--   white                 a white pixel's resource, for an item with none
--   style                 the UI style the carried stack is drawn with
--   prepare(spec)         optional: the spec as drawn (the prepend)
--   on_open(), on_close() optional: the mouse let go and taken back
--   on_drawn(form)        optional: after each draw
--   escape_hook           a line edit with the focus swallows the keys,
--                         so a client whose escape is read from keys
--                         subscribes KeyDown while a form has one
--   compose_stats         optional {n, us}: pictures composed during a
--                         draw, for the slow-draw line
local M = {}

-- How long the cursor rests before a tooltip, Luanti's own pause rather than
-- a tooltip flashing past every slot the mouse crosses
local TOOLTIP_DELAY = 0.35
-- A second left click this soon and this near is a double click: Irrlicht's
-- (CIrrDeviceStub::checkSuccessiveClicks), which Luanti's tables read
local DOUBLE_CLICK_US = 500000
local DOUBLE_CLICK_PX = 3

function M.new(env)
	local magic, log, ui = env.magic, env.log, env.ui
	local self = {form = nil}
	local mouse_at = nil
	local tooltip_over, tooltip_wait = nil, 0
	local key_cb = nil
	local last_click = nil -- {x, y, button, us}, for the double click
	local held_element, held_key, held_size = nil, nil, 32

	local function form_fields()
		local out = {}
		for _, f in ipairs(self.form and self.form.drawn and
				self.form.drawn.fields or {}) do
			out[f.name] = f.edit and f.edit:GetText() or f.value
		end
		return out
	end

	local function send(fields)
		local form = self.form
		if form.handler then
			form.handler(fields)
			return
		end
		env.send_fields(form, fields)
	end

	local function unhook()
		if key_cb then
			magic.UnsubscribeFromEvent("KeyDown", key_cb)
			key_cb = nil
		end
	end

	-- The point in the form's own coordinates, which a click is laid
	-- against
	local function local_xy(x, y)
		local o = self.form.drawn.origin
		return x - o[1], y - o[2]
	end

	local function slot_at(lx, ly)
		for _, slot in ipairs(self.form.drawn.slots or {}) do
			if lx >= slot.x and lx < slot.x + slot.size and
					ly >= slot.y and ly < slot.y + slot.size then
				return slot
			end
		end
		return nil
	end

	local function on_form(lx, ly)
		local size = self.form.drawn.size
		return lx >= 0 and ly >= 0 and lx < size[1] and ly < size[2]
	end

	-- quit says the *player* closed the form -- an exit button, escape, the
	-- inventory key -- which Luanti's own client tells the server by sending
	-- the fields with quit set. A game acts on it: the death screen's
	-- respawn is "the player closed __builtin:death". A form the server
	-- closed or replaced gets no quit.
	function self:close(quit)
		local form = self.form
		if not form then
			return
		end
		if quit then
			local fields = form_fields()
			fields.quit = "true"
			send(fields)
		end
		unhook()
		if form.drawn then
			form.drawn.window:Remove()
		end
		self.form = nil
		tooltip_over = nil
		ui:tooltip(magic.ui.root, nil)
		if held_element then
			held_element:Remove()
			held_element, held_key = nil, nil
		end
		if env.on_close then
			env.on_close()
		end
	end

	-- Pressing enter in a field sends the form the way a button does, with
	-- which field it was among the fields; Luanti's own client calls them
	-- key_enter and key_enter_field, and a game's search box is what reads
	-- them ([FORM_ENTER]). field_close_on_enter[name;false] keeps the form
	-- open, which is what a search wants.
	local function field_entered(name)
		local fields = form_fields()
		fields.key_enter = "true"
		fields.key_enter_field = name
		local closes = (self.form.drawn.close_on_enter or {})[name] ~= false
		if closes then
			fields.quit = "true"
		end
		log:verbose("form: enter in \""..tostring(name).."\"")
		send(fields)
		if closes then
			self:close(false)
		end
	end

	function self:draw()
		local form = self.form
		-- What the player typed into a field, kept where the new spec's
		-- default for it is the old one's: a game redrawing its form (a
		-- page turned, [CREATIVE_PAGES]) does not wipe a search
		local typed = {}
		for _, f in ipairs(form.drawn and form.drawn.fields or {}) do
			if f.edit and f.edit:GetText() ~= f.value then
				typed[f.name] = {value = f.value, text = f.edit:GetText()}
			end
		end
		if form.drawn then
			unhook()
			form.drawn.window:Remove()
			form.drawn = nil
		end
		local stats = env.compose_stats
		if stats then
			stats.n, stats.us = 0, 0
		end
		local t0 = buildat.get_time_us()
		local spec = env.prepare and env.prepare(form.spec) or form.spec
		local elements, size, real = env.formspec.parse(spec)
		local t1 = buildat.get_time_us()
		-- Under the UI's root: a form is laid out in the coordinates a click
		-- arrives in, which are the root's
		local root = magic.ui.root
		local w, h = root.width, root.height
		local layout = env.formspec.layout(size, real, w, h,
				h / math.max(1, magic.graphics.height), buildat.display_density())
		form.drawn = ui:show(root, elements, layout, w, h, form.state)
		local typeable = false
		for _, f in ipairs(form.drawn.fields or {}) do
			local t = typed[f.name]
			if f.edit and t and t.value == f.value then
				f.edit:SetText(t.text)
			end
			if f.edit then
				typeable = true
				local name = f.name
				magic.SubscribeToEvent(f.edit, "TextFinished", function()
					field_entered(name)
				end)
			end
		end
		if typeable and env.escape_hook then
			key_cb = magic.SubscribeToEvent("KeyDown",
					function(event_type, event_data)
						if event_data:GetInt("Key") == magic.KEY_ESCAPE then
							self:close(true)
						end
					end)
		end
		form.stale = false
		if env.on_drawn then
			env.on_drawn(form)
		end
		-- A slow draw says where it went: the first open of a game's
		-- inventory was 3.5 s in one frame in the fuzz campaign
		-- ([FORMSPEC_FRAME]), and this is what tells the pictures from the
		-- rest
		local t2 = buildat.get_time_us()
		if t2 - t0 >= 100000 then
			local kinds = {}
			for name, us in pairs(ui.kind_us or {}) do
				kinds[#kinds + 1] = {name, us}
			end
			table.sort(kinds, function(a, b) return a[2] > b[2] end)
			local by_kind = {}
			for i = 1, math.min(4, #kinds) do
				by_kind[i] = string.format("%s %.0f ms", kinds[i][1],
						kinds[i][2] / 1000)
			end
			log:info(string.format("form %s drawn in %.0f ms: parse %.0f " ..
					"ms, %d elements, %d pictures composed in %.0f ms; %s",
					form.formname, (t2 - t0) / 1000, (t1 - t0) / 1000,
					#elements, stats and stats.n or 0,
					(stats and stats.us or 0) / 1000,
					table.concat(by_kind, ", ")))
		end
	end

	-- Drawn again at the next frame(): what is in its slots, its spec or
	-- a picture it waited for has changed
	function self:redraw()
		if self.form then
			self.form.stale = true
		end
	end

	-- opts: source (which form it is, for the client's own bookkeeping),
	-- at (the node it came out of), handler (a form of the client's own:
	-- its fields go there, not out)
	function self:open(spec, formname, opts)
		self:close(false)
		if not spec or spec == "" then
			return
		end
		opts = opts or {}
		self.form = {spec = spec, formname = formname or "",
				source = opts.source, at = opts.at, handler = opts.handler,
				state = {scroll = {}, open = {}, check = {}}}
		self:draw()
		if env.on_open then
			env.on_open()
		end
		-- The checks wait for this line
		log:info("form " .. tostring(formname) .. " opened")
	end

	-- A scroll value set and the form sent with it, as Luanti's own
	-- scrollbar does
	local function scroll_to(name, v)
		local state = self.form.state
		if v == (state.scroll[name] or 0) then
			return
		end
		state.scroll[name] = v
		self.form.stale = true
		local fields = form_fields()
		fields[name] = "CHG:"..v
		send(fields)
	end

	-- The left button held over a scrollbar sets its value from where the
	-- cursor is, which is what dragging its thumb is ([FORMSPEC_SCROLL])
	local function drag(lx, ly)
		for _, b in ipairs(self.form.drawn.bars or {}) do
			if lx >= b.x and lx < b.x + b.w and
					ly >= b.y and ly < b.y + b.h then
				local frac = b.vertical and (ly - b.y) / math.max(1, b.h)
						or (lx - b.x) / math.max(1, b.w)
				scroll_to(b.name, math.floor(
						math.max(0, math.min(1, frac)) * b.max))
				return
			end
		end
	end

	-- Where the cursor is, in the UI root's coordinates; nil off the
	-- screen. left_down drags a scrollbar's thumb.
	function self:hover(x, y, left_down)
		mouse_at = x and {x, y} or nil
		if x and left_down and self.form and self.form.drawn then
			drag(local_xy(x, y))
		end
	end

	-- What a click takes of a stack: all of it with the left button, half
	-- with the right, ten with the middle -- Luanti's own inventory
	local function take_count(count, button)
		if button == "right" then
			return math.ceil(count / 2)
		elseif button == "middle" then
			return math.min(10, count)
		end
		return count
	end

	-- And what it puts down: all, one, ten. What is left stays held, so a
	-- right button held over a row of slots lays one item in each.
	local function put_count(count, button)
		if button == "right" then
			return 1
		elseif button == "middle" then
			return math.min(10, count)
		end
		return count
	end

	local function held_spends(n)
		local held = self.form.state.held
		held.count = held.count - n
		if held.count <= 0 then
			self.form.state.held = nil
		end
		self.form.stale = true
	end

	local function put_into(slot, button)
		local held = self.form.state.held
		local n = put_count(held.count, button)
		env.move(n, held, slot)
		held_spends(n)
	end

	-- Off the form: thrown away where the client can, which is in front of
	-- the player; otherwise back where it came from, which is nothing
	-- happening at all
	local function let_go(button)
		local held = self.form.state.held
		if env.drop then
			env.drop(button == "right" and 1 or held.count, held)
			held_spends(button == "right" and 1 or held.count)
		else
			self.form.state.held = nil
			self.form.stale = true
		end
	end

	-- The grid's answer: a craft makes it into craftresult, and that is
	-- what the hand then carries and puts down as a move; a further click
	-- crafts onto what is held (Luanti's GUIFormSpecMenu: one, ten with the
	-- middle button, and updateSelectedItem holding craftresult). The craft
	-- is the server's and cannot be put back. simplified: shift's stack
	-- and its move to the inventory are not read.
	local function craft_from(slot, button)
		local held = self.form.state.held
		local times = button == "middle" and 10 or 1
		env.craft(times, slot.location)
		local n = (slot.stack.count or 1) * times
		if held then
			held.count = held.count + n
		else
			self.form.state.held = {location = slot.location,
					list = "craftresult", index = 1, count = n,
					name = slot.stack.name}
		end
		self.form.stale = true
	end

	local function take_from(slot, button)
		self.form.state.held = {location = slot.location,
				list = slot.list, index = slot.index,
				count = take_count(slot.stack.count, button),
				name = slot.stack.name}
		self.form.stale = true
	end

	-- A click at x, y in the root's coordinates, with "left", "right" or
	-- "middle". Returns whether the form took it, so that one that was not
	-- on a form still digs.
	function self:click(x, y, button)
		local form = self.form
		if not form or not form.drawn then
			return false
		end
		-- One line a click on a form: what a driven run waits on between
		-- two taps of a move
		log:info("form: a "..button.." click")
		local lx, ly = local_xy(x, y)
		local function inside(e)
			return lx >= e.x and lx < e.x + e.w and ly >= e.y and
					ly < e.y + e.h
		end
		for _, b in ipairs(form.drawn.buttons or {}) do
			if inside(b) then
				local fields = form_fields()
				-- A hypertext's action says which one it was; a button sends its
				-- label ([FORMSPEC_SCROLL])
				fields[b.name] = b.value or ""
				if b.exit then
					fields.quit = "true"
				end
				log:verbose("form: button \""..tostring(b.name).."\" at "..
						lx..","..ly..(b.exit and " (exit)" or ""))
				send(fields)
				if b.exit then
					self:close(false)
				end
				return true
			end
		end
		-- A table's or a textlist's row: it is selected, "CHG:<row>" goes
		-- back as Luanti's own client sends it -- "DCL:<row>" for the second
		-- click of a double one -- and a tree's row that opens opens or
		-- closes
		local now = buildat.get_time_us()
		local double = last_click and button == "left" and
				last_click[3] == "left" and
				now - last_click[4] < DOUBLE_CLICK_US and
				math.abs(x - last_click[1]) <= DOUBLE_CLICK_PX and
				math.abs(y - last_click[2]) <= DOUBLE_CLICK_PX
		-- A third click starts over, as Irrlicht's count does
		last_click = not double and {x, y, button, now} or nil
		for _, t in ipairs(form.drawn.tables or {}) do
			if inside(t) then
				for _, r in ipairs(t.rows) do
					if ly >= r.y and ly < r.y + t.row_h then
						if r.opens and not double then
							local open = form.state.open[t.name] or {}
							form.state.open[t.name] = open
							open[r.index] = not open[r.index] or nil
						end
						form.state.selected = form.state.selected or {}
						form.state.selected[t.name] = r.index
						form.stale = true
						local fields = form_fields()
						fields[t.name] = (double and "DCL:" or "CHG:")..r.index
						log:verbose("form: table \""..tostring(t.name)..
								"\" row "..r.index)
						send(fields)
						break
					end
				end
				return true
			end
		end
		-- A tab, a checkbox, a dropdown or a scrollbar's trough: the form
		-- goes back with the new value in it, as Luanti's own client sends
		for _, t in ipairs(form.drawn.taps or {}) do
			if inside(t) then
				-- A dropdown's box opens and closes its list and sends
				-- nothing; an item in the list is the choice
				if t.open then
					form.state.dropdown_open =
							form.state.dropdown_open ~= t.name and t.name
							or nil
					form.stale = true
					log:info("form: dropdown \""..tostring(t.name).."\" "..
							(form.state.dropdown_open and "opened" or "closed"))
					return true
				end
				if t.scroll then
					local v = (form.state.scroll[t.name] or 0) + t.scroll
					form.state.scroll[t.name] = math.max(0, math.min(1000, v))
				end
				if t.pick then
					form.state.dropdown = form.state.dropdown or {}
					form.state.dropdown[t.name] = t.pick
					form.state.dropdown_open = nil
				end
				if t.check then
					form.state.check[t.name] = t.value == "true"
				end
				form.stale = true
				local fields = form_fields()
				fields[t.name] = t.value
				log:verbose("form: \""..tostring(t.name).."\" = "..
						tostring(t.value))
				send(fields)
				return true
			end
		end
		-- A slot: the stack in it is picked up, or what is carried is put
		-- down in it. The move itself is the server's; what is carried here
		-- is a drawing, and the mark formspec_ui puts on the slot it came
		-- from.
		local slot = slot_at(lx, ly)
		if slot then
			log:verbose("form: slot "..slot.list.." "..slot.index..
					" at "..lx..","..ly)
			local held = form.state.held
			if env.craft and slot.list == "craftpreview" then
				-- Crafted onto a held result of the same, as Luanti; with
				-- anything else in hand the click does nothing
				if slot.stack and slot.stack.name and
						slot.stack.name ~= "" and (not held or
						held.list == "craftresult" and
						held.name == slot.stack.name) then
					craft_from(slot, button)
				end
			elseif held then
				put_into(slot, button)
			elseif slot.stack and slot.stack.name and
					slot.stack.name ~= "" then
				take_from(slot, button)
				-- Picked up by this press: its release over another slot
				-- is a drag
				form.state.held.pressed = true
			end
			return true
		end
		if on_form(lx, ly) then
			-- Anything else on the form swallows the click, which keeps it
			-- from digging the node behind
			return true
		end
		if form.state.held then
			let_go(button)
			return true
		end
		-- **Outside it, the form closes** as Luanti's does, unless it says
		-- allow_close[false] (a death screen): on a touchscreen that is the
		-- one way out, having no Escape (user, 2026-09-30). One tap, not
		-- Luanti's double tap ([FORM_TAP_CLOSE], user 2026-10-11).
		if not form.spec:find("allow_close%[false%]") then
			self:close(true)
		end
		return true
	end

	-- A button let go: a stack picked up by the press (a click lands on the
	-- way down) and let go over another slot goes there, which is a drag.
	-- Over its own slot it stays in hand, and the next click puts it down;
	-- off the form it is let go.
	function self:release(button)
		local form = self.form
		local held = form and form.drawn and form.state.held
		-- Only a stack this press picked up: one already in hand was put
		-- by the click, and putting it again on the release laid two
		-- where a right click lays one
		if not held or not held.pressed or not mouse_at then
			return
		end
		held.pressed = nil
		local lx, ly = local_xy(mouse_at[1], mouse_at[2])
		local slot = slot_at(lx, ly)
		if slot and not (slot.location == held.location and
				slot.list == held.list and slot.index == held.index) then
			put_into(slot, button)
		elseif not slot and not on_form(lx, ly) then
			let_go(button)
		end
	end

	-- The wheel, Urho3D's delta (one notch up is 1): over a
	-- scroll_container it pages that container's bar ([FORMSPEC_SCROLL]),
	-- elsewhere it scrolls the form's first table
	function self:wheel(delta)
		local form = self.form
		if not form or not form.drawn then
			return false
		end
		if mouse_at then
			local lx, ly = local_xy(mouse_at[1], mouse_at[2])
			for _, c in ipairs(form.drawn.scrolls or {}) do
				if c.bar and lx >= c.x and lx < c.x + c.w and
						ly >= c.y and ly < c.y + c.h then
					scroll_to(c.bar, math.max(0, math.min(1000,
							(form.state.scroll[c.bar] or 0) - delta * 100)))
					return true
				end
			end
		end
		local t = (form.drawn.tables or {})[1]
		if t and t.count > t.visible then
			local at = math.max(0, math.min(t.count - t.visible,
					t.scroll - delta * 3))
			if at ~= t.scroll then
				form.state.scroll[t.name] = at
				form.stale = true
			end
		end
		return true
	end

	-- Escape closes it, which is the player closing it. Page Up and Down
	-- scroll the scroll_container under the cursor, else the first, by its
	-- height less a line or two ([SCROLL_PAGE_KEYS])
	local u = require("buildat/extension/ui_utils")
	u = u.safe or u
	function self:key(key)
		if self.form and key == magic.KEY_ESCAPE then
			self:close(true)
			return true
		end
		local d = u.page_dir(key)
		local drawn = self.form and self.form.drawn
		if not d or not drawn then
			return false
		end
		local c = (drawn.scrolls or {})[1]
		if mouse_at then
			local lx, ly = local_xy(mouse_at[1], mouse_at[2])
			for _, s in ipairs(drawn.scrolls or {}) do
				if lx >= s.x and lx < s.x + s.w and ly >= s.y and
						ly < s.y + s.h then
					c = s
				end
			end
		end
		if not c or not c.bar or (c.per or 0) <= 0 then
			return false
		end
		local max = 1000
		for _, b in ipairs(drawn.bars or {}) do
			if b.name == c.bar then
				max = b.max
			end
		end
		-- simplified: a line is the form's 13-point label's row
		local px = u.page_step(c.vertical and c.h or c.w, 16)
		local v = self.form.state.scroll[c.bar] or 0
		local to = math.max(0, math.min(max, v + d * math.floor(px / c.per)))
		log:info(string.format("form: page %d, %s %d -> %d (view %d px, %.2f px a unit)",
				d, c.bar, v, to, c.vertical and c.h or c.w, c.per))
		scroll_to(c.bar, to)
		return true
	end

	local function update_tooltip(dtime)
		local drawn = self.form and self.form.drawn
		if not drawn or not mouse_at then
			if tooltip_over then
				tooltip_over = nil
				ui:tooltip(magic.ui.root, nil)
			end
			return
		end
		local lx, ly = local_xy(mouse_at[1], mouse_at[2])
		-- The last one that covers the cursor: a form's later elements are
		-- the ones on top
		local over, over_text = nil, nil
		for _, t in ipairs(drawn.tooltips or {}) do
			if lx >= t.x and lx < t.x + t.w and ly >= t.y and ly < t.y + t.h then
				over, over_text = t, t.text
			end
		end
		-- A slot is the most specific thing under the cursor and wins; its
		-- text is its item's: the description, and the name under it
		local slot = slot_at(lx, ly)
		local stack = slot and slot.stack
		if stack and stack.name and stack.name ~= "" then
			local desc = env.item_description(stack.name) or ""
			if desc == "" then
				desc = stack.name
			end
			over, over_text = slot, desc.."\n["..stack.name.."]"
		end
		if over ~= tooltip_over then
			tooltip_over = over
			tooltip_wait = 0
			ui:tooltip(magic.ui.root, nil)
			return
		end
		if not over then
			return
		end
		tooltip_wait = tooltip_wait + dtime
		if tooltip_wait >= TOOLTIP_DELAY then
			-- A tooltip[]'s own colours, or else listcolors' for the form
			ui:tooltip(magic.ui.root, over_text, mouse_at[1], mouse_at[2],
					magic.ui.root.width, magic.ui.root.height,
					drawn.tip_offset, over.bg or drawn.tip_bg,
					over.fg or drawn.tip_fg)
		end
	end

	-- The carried stack under the cursor, over everything and never in the
	-- way of a click: a stack on its way between slots is seen on the way
	local function update_held_image()
		local held = self.form and self.form.drawn and self.form.state.held
		local key = held and mouse_at and held.name and
				held.name.." "..held.count
		if key ~= held_key and held_element then
			held_element:Remove()
			held_element = nil
		end
		held_key = key
		if not key then
			return
		end
		if not held_element then
			local slot = self.form.drawn.slots[1]
			held_size = math.floor(slot and slot.size or 32)
			held_element = magic.ui.root:CreateChild("BorderImage")
			held_element.defaultStyle = env.style
			held_element.priority = 30000
			held_element.enabled = false
			held_element.size = magic.IntVector2(held_size, held_size)
			local resource = env.item_image(held.name)
			local tex = magic.cache:GetResource("Texture2D",
					resource or env.white)
			if resource and tex then
				-- Pixel art, like everything else a game ships
				tex.filterMode = magic.FILTER_NEAREST
			else
				held_element.color = magic.Color(0.8, 0.4, 0.8, 0.8)
			end
			held_element.texture = tex
			if held.count > 1 then
				local t = held_element:CreateChild("Text")
				t:SetStyleAuto()
				t:SetPosition(0, math.floor(held_size * 0.5))
				t.text = tostring(held.count)
				t:SetFontSize(math.max(8, math.floor(held_size * 0.32)))
			end
		end
		-- Centred on the cursor, the way Luanti carries it
		held_element:SetPosition(mouse_at[1] - math.floor(held_size / 2),
				mouse_at[2] - math.floor(held_size / 2))
	end

	-- Every frame: a stale form drawn again, the tooltip, the carried stack
	function self:frame(dtime)
		if self.form and self.form.stale then
			self:draw()
		end
		update_tooltip(dtime)
		update_held_image()
	end

	-- The open form's slots for a scan ([SCAN_DRIVE]): where each is on
	-- the screen, which list and index, and what is in it
	function self:slots()
		local form = self.form
		if not form or not form.drawn then
			return nil
		end
		local ox, oy = form.drawn.origin[1], form.drawn.origin[2]
		local out = {}
		for _, slot in ipairs(form.drawn.slots or {}) do
			out[#out + 1] = {
				location = slot.location, list = slot.list,
				index = slot.index, x = ox + slot.x, y = oy + slot.y,
				size = slot.size,
				stack = slot.stack and slot.stack.name and
						(slot.stack.name.." "..tostring(slot.stack.count or 1))
						or "",
			}
		end
		return out
	end

	return self
end

return M
