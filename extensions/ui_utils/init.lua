-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("ui_utils")
local magic = require("buildat/core/urho3d")
-- The engine's constants come from magic in the sandbox
local FM_NOTFOCUSABLE, HA_CENTER, HA_LEFT, HA_RIGHT, KEY_DOWN,
		KEY_ESCAPE, KEY_KP_ENTER, KEY_LEFT, KEY_RETURN, KEY_RETURN2,
		KEY_RIGHT, KEY_UP, LM_VERTICAL, VA_CENTER, VA_TOP =
	magic.FM_NOTFOCUSABLE, magic.HA_CENTER, magic.HA_LEFT, magic.HA_RIGHT,
	magic.KEY_DOWN, magic.KEY_ESCAPE, magic.KEY_KP_ENTER, magic.KEY_LEFT,
	magic.KEY_RETURN, magic.KEY_RETURN2, magic.KEY_RIGHT, magic.KEY_UP,
	magic.LM_VERTICAL, magic.VA_CENTER, magic.VA_TOP
local dump = buildat.dump
local uistack = require("buildat/core/uistack")
-- res/style.xml is all of buildat's UI's style, its atlas res/style.png
-- drawn by util/style_atlas.py
local M = {safe = {}}

-- **The menus' colours** ([MENU_BRAND], c_quiet, src/interface/web_brand.h):
-- what a menu colours by hand rather than through res/style.xml. Numbers,
-- not Colors -- a sandbox's property takes only its own -- and through a
-- function, as the sandbox's view of a table unpacks as empty:
-- magic.Color(ui_utils.rgb("error")). text, dim and focus are the style's.
local colors = {
	text = {0.867, 0.867, 0.867},  -- #ddd
	dim = {0.6, 0.6, 0.6},         -- #999
	warn = {1, 0.8, 0.4},
	error = {1, 0.36, 0.36},       -- #ff5c5c
	focus = {0.149, 0.851, 1},     -- #26d9ff
	main = {1, 0.62, 0.122},       -- #ff9e1f, the main button
}
-- db_text(db): a sound volume as it is shown, "-6 dB (66%)" ([VOLUME_PERCENT]);
-- -33 and under is "off". The percent is loudness, 2^(dB/10): -10 dB is
-- half as loud, which is what a reader without audio terms takes 50% for.
function M.safe.db_text(db)
	if db <= -33 then
		return "off"
	end
	return string.format("%d dB (%d%%)", math.floor(db + 0.5),
			math.floor(100 * 2 ^ (db / 10) + 0.5))
end
assert(M.safe.db_text(0) == "0 dB (100%)" and M.safe.db_text(-6) == "-6 dB (66%)"
		and M.safe.db_text(-3) == "-3 dB (81%)" and M.safe.db_text(-33) == "off")

function M.safe.rgb(name)
	return unpack(colors[name])
end

-- API naming:
-- show_*_notification()
-- show_*_dialog()
-- show_*_window() (?)
-- vertical_menu() / bind_button_menu()

-- **Every page by the keyboard** ([MENU_KEYS], user 2026-10-02). The
-- arrows, Tab and Shift+Tab go through a page's buttons and fields, Enter
-- or Space presses the button with the focus (both Tab and the press are
-- Urho3D's own once a button takes the focus). **No letters**
-- ([NO_LETTER_KEYS], user 2026-10-07): "[B]utton" was hard to read and
-- went unused beside the arrows and Tab.

-- Whether an element is still there, and whether it is shown: a removed
-- one raises ([UI_UAF]'s guard), which is the answer to the first
local function gone(e)
	return not pcall(function() return e.visible end)
end

-- **A page's window is known by a name of its own**: a window removed and
-- another made in the same frame can sit at the same address, and the old
-- wrapper then reads the new one (the guard's own simplified: note) -- the
-- plan picker's page went on to walk the editor's toolbar. A window with
-- a name keeps it and is known by that.
local page_serial = 0
local function page_name(win)
	local ok, name = pcall(function() return win:GetName() end)
	if not ok then
		return nil
	end
	if name == "" then
		page_serial = page_serial + 1
		name = "keyboard_page_" .. page_serial
		win:SetName(name)
	end
	return name
end
local function shown(e)
	local ok, v = pcall(function() return e.visible end)
	return ok and v == true
end

-- **A view that scrolls**, read the same way whichever kind it is: a
-- ScrollView (the Server window's page) or a list_view's viewport. y in
-- its content, top the content's y at the view's top edge.
local list_views, list_view_serial = {}, 0
local function scroller(e, t)
	if t == "ScrollView" or t == "ListView" then
		-- None set reads as an error in the sandbox
		local ok, content = pcall(function() return e.contentElement end)
		return ok and content and {content = content,
			top = function() return e.viewPosition.y end,
			height = function() return e.scrollPanel.height end,
			set_top = function(y)
				y = math.max(0, math.min(y,
						content.height - e.scrollPanel.height))
				e.viewPosition = magic.IntVector2(e.viewPosition.x, y)
			end}
	end
	local view = t == "UIElement" and list_views[e:GetName()]
	return view and {content = view.list,
		top = function() return -view.list.position.y end,
		height = function() return view.viewport.height end,
		set_top = function(y) view:scroll(y + view.list.position.y) end}
end
local function y_in(sc, e)
	return e.screenPosition.y - sc.content.screenPosition.y
end
local function in_view(sc, e)
	local y, top = y_in(sc, e), sc.top()
	return y >= top and y + e.height <= top + sc.height()
end
-- Scrolls just enough that e is in view, its top if it is taller; a
-- multi-line field's caret, not the whole of it ([HEARTH_PAGE_SCROLL]:
-- one grows with its text)
local function show_in(sc, e)
	e = e:GetCaret() or e
	local y, top, h = y_in(sc, e), sc.top(), sc.height()
	if y + e.height > top + h then
		sc.set_top(math.min(y, y + e.height - h))
	elseif y < top then
		sc.set_top(y)
	end
end

-- The page's buttons and fields, in the order they are drawn. scs, when
-- given, gets the view each one scrolls in (scs[i] for out[i]; the same
-- table for one view in one walk), none for those outside any.
local function page_items(e, out, scs, sc)
	if not e.visible then
		return out
	end
	local t = e:GetTypeName()
	-- A scroll bar's arrows are the wheel's and the mouse's
	if t == "ScrollBar" then
		return out
	end
	if scs then
		sc = scroller(e, t) or sc
	end
	if ((t == "Button" or t == "DropDownList") and e.enabled) or
			t == "LineEdit" then
		out[#out + 1] = e
		if scs then
			scs[#out] = sc
		end
		if t ~= "LineEdit" then
			-- A dropdown's or a checkbox's insides are the button's
			return out
		end
	end
	-- A child of the client's own reads nil ([TRUST_CODE]: the code in a
	-- Starport field)
	for i = 0, e:GetNumChildren() - 1 do
		local c = e:GetChild(i)
		if c then
			page_items(c, out, scs, sc)
		end
	end
	return out
end

local function button_text(b)
	for i = 0, b:GetNumChildren() - 1 do
		-- nil for the client's own hidden UI
		local c = b:GetChild(i)
		if c and c:GetTypeName() == "Text" then
			return c
		end
		local d = c and button_text(c)
		if d then
			return d
		end
	end
	return nil
end

-- **The selected item is the one with the focus** ([ONE_FOCUS]): one
-- thing on a screen is selected, a field or a button, and Enter is its --
-- a focused button presses itself on Enter or Space (Urho3D's
-- Button::OnKey), a field finishes its line. A selection of the menu's own
-- beside the focus had Enter in a field press a button: on the web a
-- LineEdit drops its focus on Enter before a script hears the key (the
-- screen keyboard, LineEdit.cpp), and the menu then pressed its own.
-- Button.selected draws the focus, with pressedOffset; native hover would
-- draw a second item, so hoverOffset moves onto pressedOffset, and hover
-- moves the focus instead, unless a field is being typed in.
-- PageUp and PageDown move this many items ([MENU_FAST_SCROLL])
local PAGE = 10

-- A dropdown's popup was up at the last Update (M.safe.dropdown)
local drop_open = false
-- One closed its popup on this frame's Escape
local escape_taken = false

-- How many rows one wheel click moves in a menu of n items in rows of
-- columns: a list of any length is crossed in 10 to 20 clicks
local function wheel_step(n, columns)
	return math.max(1, math.ceil(math.ceil(n / columns) / 20))
end
assert(wheel_step(15, 1) == 1 and wheel_step(20, 1) == 1 and
		wheel_step(21, 1) == 2 and wheel_step(60, 1) == 3 and
		wheel_step(300, 1) == 15 and wheel_step(84, 4) == 2,
		"wheel_step")

local function button_menu_nav(root, options)
	local items = {}
	-- The focused item's index, 0 for none: read from the focus
	local selected = 0
	-- **A selection the mouse made goes when the mouse leaves its button**
	-- (user, 2026-10-06): a highlight is what a click would press, and a
	-- click just beside a button presses nothing. One the keys or the
	-- wheel made stays wherever the mouse goes. anchor is the item the
	-- mouse left, which the next arrow brings back rather than the first.
	local by_mouse = false
	local anchor = 0
	local on_other_key = nil
	local on_change = nil

	local function typing()
		local focus = magic.ui.focusElement
		return focus ~= nil and focus:GetTypeName() == "LineEdit"
	end

	local function apply()
		for i, item in ipairs(items) do
			item.button.selected = (i == selected)
			if on_change then
				on_change(item.button, i == selected, i)
			end
		end
	end

	-- The drawing follows the focus, wherever it moved it from: a click,
	-- Tab, a field taking it
	local function sync()
		-- Most frames nothing moved: the selected one still has the focus,
		-- and only one element has it ([FRAME_WORK]: every item's was
		-- asked, ~5-10 us an item a frame)
		local cur = items[selected]
		if cur and not gone(cur.button) and cur.button:HasFocus() then
			return
		end
		if selected == 0 and magic.ui.focusElement == nil then
			return
		end
		local at = 0
		for i, item in ipairs(items) do
			if not gone(item.button) and item.button:HasFocus() then
				at = i
			end
		end
		if at ~= selected then
			selected = at
			apply()
		end
	end

	local function select_i(i)
		local n = #items
		if n == 0 then
			return
		end
		if i < 1 then
			i = n
		elseif i > n then
			i = 1
		end
		items[i].button:SetFocus(true)
		sync()
	end

	-- **After the wheel a hover is the mouse's only once it moves**
	-- ([SETTINGS_KEYS_PAGE]): a list the wheel scrolls passes its rows
	-- under a still mouse, and that walked the selection
	local wheeled_at = nil
	local function mouse_moved()
		if not wheeled_at then
			return true
		end
		local p = magic.input:GetMousePosition()
		if p.x == wheeled_at.x and p.y == wheeled_at.y then
			return false
		end
		wheeled_at = nil
		return true
	end

	local nav = {}

	function nav:add(button, action)
		if button == nil or action == nil then
			error("button_menu: add() needs a button and an action")
		end
		local i = #items + 1
		items[i] = {button = button, action = action}
		-- A slider is an item too, with no press to draw (a Button's
		-- offsets are not its)
		if button:GetTypeName() ~= "Slider" then
			local hover = button.hoverOffset
			button.pressedOffset = magic.IntVector2(hover.x, hover.y)
			button.hoverOffset = magic.IntVector2(0, 0)
		end
		button:SetFocusMode(magic.FM_FOCUSABLE)
		magic.SubscribeToEvent(button, "Released",
		function(self, event_type, event_data)
			action()
		end)
		magic.SubscribeToEvent(button, "HoverBegin",
		function(self, event_type, event_data)
			if not typing() and mouse_moved() then
				select_i(i)
				by_mouse = true
			end
		end)
		magic.SubscribeToEvent(button, "HoverEnd",
		function(self, event_type, event_data)
			-- Not under a screen pushed over this one: the focus is that
			-- screen's (a click that opened it ends the hover too)
			if not by_mouse or gone(root) or not root.visible or
					not mouse_moved() then
				return
			end
			sync()
			if selected == i then
				anchor = i
				root:SetFocus(true)
				sync()
			end
		end)
		apply()
		return button
	end

	function nav:on_key(fn)
		on_other_key = fn
		return self
	end

	-- The item that is the way back, by its label: "< back", "Back",
	-- "Cancel", "< back to the launcher" and the like -- what Escape
	-- presses. nil for a screen with none.
	function nav:back_item()
		for _, item in ipairs(items) do
			local text = item.button:GetChild("ButtonText")
			local label = text and text.text or ""
			label = label:lower()
			if label:sub(1, 1) == "<" or label == "back" or label == "cancel" or
					label == "ok" or label == "close" then
				return item
			end
		end
		return nil
	end

	-- What being the selected item looks like, for a menu whose buttons draw
	-- more than their own style: an icon menu dims what is not selected. The
	-- callback gets (button, selected, index) for every item whenever the
	-- selection moves.
	function nav:on_change(fn)
		on_change = fn
		apply()
		return self
	end

	-- A grid rather than a row or a column: up and down move by this many
	-- items, left and right by one ([LAUNCH_GRID])
	local columns = 1
	function nav:set_columns(n)
		columns = math.max(1, math.floor(n or 1))
		return self
	end

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		-- A text field on the same screen owns the keys that are text: Enter
		-- finishes the line being typed and left and right move the caret.
		-- Without this a filter box beside a list cannot be used at all --
		-- Enter in it also presses whichever button is selected under it,
		-- which opens something instead of filtering.
		--
		-- **Whether anything has the focus is not the question.** The stack
		-- gives its own root the focus as it pushes it -- see
		-- UIStack:push() -- and a Button takes it when it is clicked, so
		-- something always has it and asking that turned the arrows and
		-- Enter off on every menu in the tree, this client's own first
		-- screen included. What stands the menu down is the focus being in
		-- a field that is being typed into.
		-- Escape is Back on every menu screen, typing or not
		-- ([BOX_PLAYTEST_2] 6, 7; the rule is in doc/conventions.txt):
		-- the item labelled as the way back is pressed, when the screen
		-- has one; a screen's own handler sees the key first and may
		-- take it (a capture's cancel), by returning true
		-- The screen's own handler first, for every key: true means it
		-- took it (a key capture takes the arrows too)
		if on_other_key and on_other_key(key) == true then
			return
		end
		-- A dropdown's popup has the keys
		if drop_open then
			return
		end
		if key == KEY_ESCAPE and magic.input:GetKeyPress(key) then
			local back = nav:back_item()
			if back then
				back.action()
				return
			end
		end
		if typing() then
			return
		end
		sync()
		-- Left and right as well as up and down, because a menu can be a row
		-- as well as a column and a player should not have to know which.
		-- From none, the one the mouse left, else the first. Enter is the
		-- focused button's own.
		-- Whatever is selected from here on, the keys chose it
		by_mouse = false
		if selected == 0 and (key == KEY_LEFT or key == KEY_RIGHT or
				key == KEY_UP or key == KEY_DOWN) then
			select_i(anchor >= 1 and anchor <= #items and anchor or 1)
		elseif key == KEY_LEFT then
			select_i(selected - 1)
		elseif key == KEY_RIGHT then
			select_i(selected + 1)
		elseif key == KEY_UP then
			select_i(selected - columns)
		elseif key == KEY_DOWN then
			select_i(selected + columns)
		elseif key == magic.KEY_PAGEUP or key == magic.KEY_PAGEDOWN then
			-- [MENU_FAST_SCROLL]: ten items, ten rows in a grid, clamped
			local d = (key == magic.KEY_PAGEUP and -PAGE or PAGE) * columns
			select_i(math.max(1, math.min(#items,
					math.max(selected, 1) + d)))
		end
	end)

	-- The wheel moves the selection, and the menu's on_change scrolls it
	-- into view; clamped rather than wrapped, so a wheel past the end
	-- stops on the last item, which is how a partial last row is reached
	-- ([LAUNCH_GRID]). **Its step grows with the list**
	-- ([MENU_FAST_SCROLL]): a row a click up to 20 rows, two up to 40,
	-- so any list is crossed in 10 to 20 clicks.
	-- options.wheel = false: the wheel is the screen's, a list_view's
	-- that scrolls the view and leaves the selection
	root:SubscribeToStackEvent("MouseWheel", function(event_type, event_data)
		local p = magic.input:GetMousePosition()
		wheeled_at = {x = p.x, y = p.y}
		if #items == 0 or drop_open or (options and options.wheel == false) then
			return
		end
		by_mouse = false
		sync()
		local i = math.max(selected, 1) - event_data:GetInt("Wheel") *
				wheel_step(#items, columns) * columns
		select_i(math.max(1, math.min(#items, i)))
	end)

	-- **A button the menu does not know of** is one the keyboard cannot
	-- reach: said once, the first frame the menu is up ([MENU_KEYS])
	local checked = false
	root:SubscribeToStackEvent("Update", function()
		if checked then
			sync()
			return
		end
		checked = true
		-- The first item has the focus to start with, unless the screen gave
		-- it to something of its own (a field to type in, a dropdown)
		local focus = magic.ui.focusElement
		local kind = focus and focus:GetTypeName()
		if items[1] and kind ~= "LineEdit" and kind ~= "Button" and
				kind ~= "DropDownList" then
			items[1].button:SetFocus(true)
		end
		sync()
		-- simplified: a wrapper is not the same table twice, so a button
		-- is known by its label and where it is
		local function id(b)
			local t = button_text(b)
			local p = b.screenPosition
			return (t and t.text or "") .. "@" .. p.x .. "," .. p.y
		end
		local known = {}
		for _, item in ipairs(items) do
			known[id(item.button)] = true
		end
		for _, e in ipairs(page_items(root, {})) do
			-- The × is out of the walk on purpose: the keyboard has Escape
			if e:GetTypeName() == "Button" and not known[id(e)] and
					e:GetName() ~= "close_glyph" then
				local t = button_text(e)
				log:warning("menu: a button outside its menu's keys: " ..
						(t and dump(t.text) or "(no label)"))
			end
		end
		log:verbose("menu: " .. #items .. " items")
	end)

	return nav
end

-- The one closed last by a pick or Escape, for its focus back on the next
-- frame: a modal popup takes the dropdown's top-level element along under
-- the modal root and puts it back as it closes, the focus is lost on the
-- way, and a screen under it may take it before this does
local refocus = nil
-- The one whose closing was told on this frame
local closed_now = nil
-- **A pick's on_choose, run on the next frame** ([AITTA_FILTER_POP]): for
-- the same reason. A page the pick drew again, popped inside the pick,
-- was popped from under the modal root and put back by the closing, its
-- dropdown live over the page drawn in its place
local picked = nil

-- The pages that took the keys, newest last: only the newest one still
-- shown answers, so a page over another does not share its keys
local keyboard_pages = {}

-- The page's own window still there: not removed, and not another one at
-- its address
local function page_gone(page)
	if gone(page.win) then
		return true
	end
	local ok, name = pcall(function() return page.win:GetName() end)
	return not ok or name ~= page.name
end

local function newest_page()
	for i = #keyboard_pages, 1, -1 do
		if not page_gone(keyboard_pages[i]) and shown(keyboard_pages[i].win) then
			return keyboard_pages[i]
		end
	end
	return nil
end

-- The page's items read again from its window: nothing of it is held
-- from one frame to the next but the window
local function rewalk(page)
	page.scs = {}
	page.items = page_items(page.win, {}, page.scs)
	for _, e in ipairs(page.items) do
		if e:GetTypeName() == "Button" then
			e:SetFocusMode(magic.FM_FOCUSABLE)
		end
	end
end

-- An item of the page removed: the page was redrawn after the frame a
-- click re-read it, as Hearth's is when its server answers, and the new
-- buttons are not focusable yet.
-- simplified: items added with none removed are not noticed until the
-- next key or click; ElementAdded (not in safe_events) would catch them.
local function stale(page)
	for _, e in ipairs(page.items) do
		if gone(e) then
			return true
		end
	end
	return false
end

-- For the log a check reads: a button's label, else what the item is
local function label_of(e)
	local t = e:GetTypeName() == "Button" and button_text(e)
	return t and t.text or e:GetTypeName()
end

local function arrange(page)
	rewalk(page)
	local first, inside = nil, false
	for _, e in ipairs(page.items) do
		if e:HasFocus() then
			inside = true
		end
		local t = e:GetTypeName()
		if t == "Button" or t == "DropDownList" then
			first = first or e
		end
	end
	-- The first button has the focus to start with, unless the page gave
	-- it to one of its own (a password page's first field)
	if first and not inside then
		first:SetFocus(true)
	end
end

-- keyboard_page(win): win, a window or a page, by the keyboard. Its
-- buttons and fields are read a frame later, so a page built after the
-- call that made its window gets them all.
function M.safe.keyboard_page(win)
	local page = {win = win, items = {}, name = page_name(win)}
	keyboard_pages[#keyboard_pages + 1] = page
	local update_sub, key_sub, click_sub
	local arranged, dirty = false, false
	-- A key or a click may have changed the page: read again the frame
	-- after, which is when its labels are what the press made them
	click_sub = magic.SubscribeToEvent("MouseButtonUp", function()
		dirty = true
	end)
	update_sub = magic.SubscribeToEvent("Update", function()
		if page_gone(page) then
			magic.UnsubscribeFromEvent("Update", update_sub)
			magic.UnsubscribeFromEvent("MouseButtonUp", click_sub)
			magic.UnsubscribeFromEvent("KeyDown", key_sub)
			for i, p in ipairs(keyboard_pages) do
				if p == page then
					table.remove(keyboard_pages, i)
					break
				end
			end
			return
		end
		if not arranged and shown(win) then
			arranged = true
			arrange(page)
			local labels = {}
			for _, e in ipairs(page.items) do
				-- The focused one marked, for a check
				labels[#labels + 1] = (e:HasFocus() and "*" or "") .. label_of(e)
			end
			log:verbose("keyboard_page: " .. table.concat(labels, "|"))
		elseif shown(win) and (dirty or stale(page)) then
			dirty = false
			rewalk(page)
		end
		-- **The view follows the focus** a key moved (Tab, PageDown) into
		-- an item not wholly in it; the wheel and the mouse are as they are
		if page.follow and arranged and shown(win) then
			page.follow = false
			for i, e in ipairs(page.items) do
				if page.scs[i] and e:HasFocus() then
					show_in(page.scs[i], e)
				end
			end
		end
		-- A multi-line field's caret before a key moves it: Up on its first
		-- row and Down on its last leave it ([HEARTH_PAGE_SCROLL])
		local f = magic.ui.focusElement
		local caret, first = nil, false
		if f then
			caret, first = f:GetCaret()
		end
		page.rows_at = caret and {f, first, f:IsCaretOnLastRow()} or nil
		local cols = page.columns
		-- Most frames the focus is where it was: that one asked, not both
		-- columns walked ([FRAME_WORK]: ~1 ms a frame on the join screen)
		local held = page.held
		if cols and arranged and shown(win) and not page.keep_left and
				(held and not gone(held) and held:HasFocus() or
				not held and magic.ui.focusElement == nil) then
			page.at_start = held and page.side == 2 and
					held:GetTypeName() == "LineEdit" and
					held.cursorPosition == 0 and held or nil
		elseif cols and arranged and shown(win) then
			-- The left one last focused there, by its place: a sidebar
			-- drawn again has new buttons in the same places
			local left, focused = page_items(cols[1], {}), false
			page.held = nil
			for i, e in ipairs(left) do
				if e:HasFocus() then
					page.left_at, page.side, focused = i, 1, true
					page.held = e
				end
			end
			page.at_start = nil
			for _, e in ipairs(page_items(cols[2], {})) do
				if e:HasFocus() then
					page.side, focused = 2, true
					page.held = e
					-- The field's cursor before a key moves it: Left at its
					-- start is the sidebar's
					if e:GetTypeName() == "LineEdit" and
							e.cursorPosition == 0 then
						page.at_start = e
					end
				end
			end
			-- After Enter on the left: its button again once the sidebar
			-- drawn again has dropped the focus, for 3 s
			local wait = page.keep_left
			if wait and buildat.get_time_us() > wait then
				page.keep_left = nil
			elseif wait and not focused and #left > 0 then
				page.keep_left = nil
				left[math.min(page.left_at or 1, #left)]:SetFocus(true)
			end
		end
	end)
	key_sub = magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
		if page_gone(page) or not shown(win) then
			-- Removed, not hidden for a moment
			if page_gone(page) then
				magic.UnsubscribeFromEvent("KeyDown", key_sub)
				for i, p in ipairs(keyboard_pages) do
					if p == page then
						table.remove(keyboard_pages, i)
						break
					end
				end
			end
			return
		end
		-- A dropdown's popup has the keys
		if newest_page() ~= page or not arranged or drop_open then
			return
		end
		-- So has a dialog over the page, an item of its own focused (the
		-- file picker over Hearth, [HEARTH_USABILITY]: Down went to the
		-- sidebar under it, Enter opened a topic). Not a plain element:
		-- uistack focuses the one under a dialog it pops.
		local f = magic.ui.focusElement
		if f and not win:HasRecursiveFocus() then
			local t = f:GetTypeName()
			if t == "Button" or t == "LineEdit" or t == "DropDownList" then
				return
			end
		end
		dirty = true
		page.follow = true
		rewalk(page)
		if #page.items == 0 then
			return
		end
		local key = event_data:GetInt("Key")
		local focus = magic.ui.focusElement
		local typing = focus ~= nil and focus:GetTypeName() == "LineEdit"
		-- A multi-line field's rows are its up and down ([HEARTH_MVP])
		local ra = page.rows_at
		local rows = typing and focus:IsMultiLine() and not (ra and
				ra[1]:HasFocus() and (key == KEY_UP and ra[2] or
				key == KEY_DOWN and ra[3]))
		if not typing and (key == magic.KEY_PAGEUP or
				key == magic.KEY_PAGEDOWN) then
			local at = 0
			for i, e in ipairs(page.items) do
				if shown(e) and e:HasFocus() then
					at = i
				end
			end
			local d = key == magic.KEY_PAGEUP and -PAGE or PAGE
			page.items[math.max(1, math.min(#page.items,
					math.max(at, 1) + d))]:SetFocus(true)
			return
		end
		-- **Two columns** (keyboard_columns): Up and Down stay in the one
		-- with the focus, Right goes to the right one's first item, Left
		-- back to the left one's last; Enter on the left one stays there
		-- (user, 2026-10-07: browsing the pages, Right to act in one)
		local items, scs = page.items, page.scs
		local side = nil
		local cols = page.columns
		if cols then
			local lscs, rscs = {}, {}
			local left, right = page_items(cols[1], {}, lscs),
					page_items(cols[2], {}, rscs)
			for i, e in ipairs(left) do
				if e:HasFocus() then
					side, items, scs, page.left_at = 1, left, lscs, i
				end
			end
			for _, e in ipairs(right) do
				if e:HasFocus() then
					side, items, scs = 2, right, rscs
				end
			end
			-- Nothing focused (a page with nothing to focus came up after
			-- Enter, or one drawn again after a click): Right goes to the
			-- page's first, another arrow key back to the left one's last
			if key ~= KEY_RETURN and key ~= KEY_RETURN2 and
					key ~= KEY_KP_ENTER then
				page.keep_left = nil
			end
			if not side and key == KEY_RIGHT and #right > 0 then
				right[1]:SetFocus(true)
				page.side = 2
				return
			end
			if not side and #left > 0 and (key == KEY_UP or
					key == KEY_DOWN or key == KEY_LEFT or key == KEY_RIGHT) then
				left[math.min(page.left_at or 1, #left)]:SetFocus(true)
				page.side = 1
				return
			end
			if not typing and key == KEY_RIGHT and side == 1 and #right > 0 then
				right[1]:SetFocus(true)
				page.side = 2
				return
			end
			-- simplified: two Lefts in one frame from the field's second
			-- character stay in it; the next Left goes
			if key == KEY_LEFT and side == 2 and #left > 0 and
					(not typing or (page.at_start and
					not gone(page.at_start) and page.at_start:HasFocus())) then
				left[math.min(page.left_at or 1, #left)]:SetFocus(true)
				page.side = 1
				return
			end
			-- The button may have drawn the sidebar again already, its
			-- focus gone with it: the side last seen then
			if (side or page.side) == 1 and (key == KEY_RETURN or
					key == KEY_RETURN2 or key == KEY_KP_ENTER) then
				page.keep_left = buildat.get_time_us() + 3000000
			end
		end
		-- **Rows by Up and Down only** (user, 2026-10-07): Left and Right
		-- are a field's cursor, or the columns'
		if not rows and (key == KEY_UP or key == KEY_DOWN) and #items > 0 then
			local at = 0
			for i, e in ipairs(items) do
				if shown(e) and e:HasFocus() then
					at = i
				end
			end
			local d = key == KEY_DOWN and 1 or -1
			local n = #items
			local i = at == 0 and 1 or at + d
			-- **In a view that scrolls, past it and never round**
			-- ([STARPORT_LIST_FILL]): at its last item Down scrolls half a
			-- view, and at its end goes on to the item under it, or
			-- stops; an item further than the view's edge is scrolled to
			-- half a view at a time, nothing between skipped unread. Up
			-- the same. A page that does not scroll wraps around.
			local cur, nsc = scs[at], scs[i]
			local half = cur and math.floor(cur.height() / 2)
			if cur and nsc ~= cur then
				local top = cur.top()
				cur.set_top(top + d * half)
				if cur.top() ~= top then
					return
				end
			elseif cur and items[i] and not in_view(cur, items[i]) then
				local e, top, h = items[i], cur.top(), cur.height()
				local need = d > 0 and y_in(cur, e) + e.height - top - h or
						top - y_in(cur, e)
				cur.set_top(top + d * math.min(half, need))
				if need > half and cur.top() ~= top then
					return
				end
			end
			if not items[i] then
				if cur or scs[(at - 1 + d) % n + 1] then
					return
				end
				i = (at - 1 + d) % n + 1
			end
			items[i]:SetFocus(true)
			if scs[i] then
				show_in(scs[i], items[i])
			end
			-- Keys come several in a frame: kept now, not at the next Update
			if side == 1 then
				page.left_at = i
			end
			log:verbose("keyboard: to " .. label_of(items[i]))
			return
		end
	end)
	return win
end

-- keyboard_columns(win, left, right): win's keyboard_page in two columns,
-- a sidebar and the page beside it (Starport's window): see the keys in
-- keyboard_page. Tab is Urho3D's UI's own, which moves the focus by itself.
function M.safe.keyboard_columns(win, left, right)
	local name = page_name(win)
	for _, p in ipairs(keyboard_pages) do
		if p.name == name and not page_gone(p) then
			p.columns = {left, right}
		end
	end
end

-- Bind up/down/enter and hover selection to existing buttons on a uistack
-- root. Each item is {button, action} or {button=..., action=...}.
-- Subscribes Released on the buttons; don't also subscribe Released.
-- Returns a handle with :add(button, action) and :on_key(fn). options:
-- wheel = false leaves the wheel alone.
function M.safe.bind_button_menu(root, items, on_other_key, options)
	local nav = button_menu_nav(root, options)
	if items then
		for _, item in ipairs(items) do
			nav:add(item.button or item[1], item.action or item[2])
		end
	end
	if on_other_key then
		nav:on_key(on_other_key)
	end
	return nav
end

local function make_menu_button(parent, label, options, main)
	local button = parent:CreateChild("Button")
	if main then button:SetStyle("PrimaryButton") else button:SetStyleAuto() end
	button:SetName("Button")
	button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	button.minHeight = options.min_height or 24
	if options.min_width then
		button.minWidth = options.min_width
	end
	local text = button:CreateChild("Text")
	text:SetName("ButtonText")
	text:SetStyleAuto()
	text.text = label
	text:SetTextAlignment(HA_CENTER)
	return button
end

-- Vertical Window on a uistack root, with the same keyboard/mouse nav.
-- Extra widgets (logo, titles) go on menu.window before :add().
-- :add("Label", action) creates a button; :add(button, action) registers one.
-- :add("Label", action, true): the screen's main button, amber ([MENU_BRAND]).
function M.safe.vertical_menu(root, options)
	options = options or {}
	-- SetStyleAuto() below needs a style to find, and a root that has none
	-- gives an unstyled window with invisible text -- which reads as a blank
	-- vertical bar. Every caller in this tree sets this first; do it here so
	-- that a caller which forgets gets a menu rather than a bar, the same way
	-- show_message_dialog() and show_notification() already do. A root that
	-- has its own style keeps it.
	if not root.defaultStyle then
		root.defaultStyle = magic.cache:GetResource("XMLFile",
				options.style or "ui_utils/res/style.xml")
	end
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, options.spacing or 10,
			options.padding or magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local nav = button_menu_nav(root, options)
	if options.on_key then
		nav:on_key(options.on_key)
	end

	local menu = {window = window}

	function menu:add(label_or_button, action, main)
		local button = label_or_button
		if type(label_or_button) == "string" then
			button = make_menu_button(window, label_or_button, options, main)
		end
		nav:add(button, action)
		return button
	end

	function menu:on_key(fn)
		nav:on_key(fn)
		return self
	end

	-- A choice of one: M.safe.dropdown with `label` before it, an item
	-- the arrows reach like the buttons; Enter opens it
	function menu:add_dropdown(label, choices, current, on_choose, opts)
		opts = opts or {}
		opts.label = label
		local d = M.safe.dropdown(window, choices, current, on_choose, opts)
		nav:add(d, function() end)
		return d
	end

	return menu
end

-- view:header() and view:row() of a list_view, adding to `list`
local function list_view_rows(view, list, width, options)
	local row_height = options.row_height or 28
	local icon_size = options.icon_size or 20
	local function text(at, s, size, color)
		local t = at:CreateChild("Text")
		t:SetStyleAuto()
		t.text = s
		if size then t:SetFontSize(size) end
		if color then t.color = magic.Color(M.safe.rgb(color)) end
		return t
	end
	function view:header(s, size, color)
		local t = text(list, s, size or 13, color or "dim")
		t:SetFixedHeight(math.max(t.height, row_height - 4))
		return t
	end
	function view:row(e, badge)
		local b = list:CreateChild("Button")
		b:SetStyleAuto()
		b:SetName("Button")
		b:SetLayout(magic.LM_HORIZONTAL, 8, magic.IntRect(10, 2, 10, 2))
		b:SetFixedHeight(row_height)
		-- The row's own icon, small enough to keep its height; an empty
		-- one where there is none, so that the labels line up
		local tex = e.icon and magic.cache:GetResource("Texture2D", e.icon)
		local icon = b:CreateChild(tex and "BorderImage" or "UIElement")
		icon:SetFixedSize(icon_size, icon_size)
		if tex then
			-- A game's own icon is pixel art
			tex.filterMode = magic.FILTER_NEAREST
			icon.texture = tex
			icon.blendMode = magic.BLEND_ALPHA
		elseif e.glyph then
			-- [GLYPH_ICONS]
			text(icon, e.glyph, icon_size + 2, "dim"):SetAlignment(HA_CENTER,
					VA_CENTER)
		end
		local label = text(b, e.label)
		label:SetName("ButtonText")
		label:SetFixedWidth(math.floor(width * (options.label_share or 0.62)))
		label:SetAlignment(HA_LEFT, VA_CENTER)
		local bt = text(b, badge or e.badge or "", 12, "dim")
		bt:SetAlignment(HA_LEFT, VA_CENTER)
		-- e.mark = {glyph, colour name}: a glyph at the right of the
		-- label's column ([HEARTH_NEW_MARKS]), returned for the caller to
		-- change; and the badge's Text, for one that changes in place
		local m = nil
		if e.mark then
			m = text(label, e.mark[1], nil, e.mark[2])
			m:SetAlignment(HA_RIGHT, VA_CENTER)
			m.position = magic.IntVector2(-4, 0)
		end
		return b, m, bt
	end
end

-- **A list in a viewport that clips it** and scrolls by moving it
-- (launch_menu's, shared since [HEARTH_UI]). Its rows are anything:
-- view:row() makes the menus' one-line button, and a caller with rows of
-- its own (a forum message: a box of wrapped text, its height its own)
-- creates them on view.list and calls fit().
--
--   local view = ui_utils.list_view(parent, width, height, {
--       row_height = 28, icon_size = 20, label_share = 0.62, spacing = 2,
--       wheel = nil, follow_focus = false})
--   view:header(s, size, color)  a heading row; dim, 13 by default
--   view:row(e, badge)           a Button: e.icon (a texture, or none;
--                                else e.glyph, a character of the font,
--                                dim in its place), e.label, and badge
--                                (or e.badge) dim after; returns it, the
--                                e.mark Text and the badge's Text
--   view:fit()                   lays the rows out; again after adding more
--   view:show(e)                 scrolls so that e is in view
--   view:scroll(dy)              by dy pixels, clamped; math.huge: the end
--
-- **The layout is set in fit(), once the rows are in**: a vertical layout
-- is redone for every child added, so 300 rows took 1.8 s where 50 took
-- 30 ms ([SEARCH_CAP]). Rows added after fit() are laid out one by one,
-- which is fine for a few (a chat's new line).
-- **What scrolls it**: the caller's show() and scroll() -- a menu's
-- selection (bind_button_menu's on_change -> show), which owns the wheel
-- there. options.wheel: the wheel over the list scrolls it, this many
-- pixels a click, for a list read rather than walked. options.follow_focus:
-- after a key, the row holding the focus is scrolled into view, for a list
-- walked by keyboard_page.
-- simplified: no scroll bar.
function M.safe.list_view(parent, width, height, options)
	options = options or {}
	local row_height = options.row_height or 28
	-- options.within: another view, whose list this one's rows are a
	-- group in ([HEARTH_PAGE_SCROLL]: a page's rows among its other
	-- things, one scroll for them all); `parent` and `height` are then
	-- unused, and the scrolling, the wheel and the focus are the other's
	local outer = options.within
	if outer then
		local list = outer.list:CreateChild("UIElement")
		list:SetFixedWidth(width)
		list.enabled = true
		local view = {viewport = outer.viewport, list = list}
		list_view_rows(view, list, width, options)
		function view:fit()
			list:SetLayout(LM_VERTICAL, options.spacing or 2,
					magic.IntRect(0, 0, 0, 0))
			outer:fit()
		end
		function view:scroll(dy) outer:scroll(dy) end
		function view:show(e) outer:show(e) end
		return view
	end
	local viewport = parent:CreateChild("UIElement")
	viewport.clipChildren = true
	viewport.enabled = true
	local list = viewport:CreateChild("UIElement")
	list:SetFixedWidth(width)
	list.enabled = true
	local view = {viewport = viewport, list = list}
	-- keyboard_page knows it by its name as a view that scrolls
	list_view_serial = list_view_serial + 1
	local name = "list_view_" .. list_view_serial
	viewport:SetName(name)
	list_views[name] = view
	local subs = {}
	local function on(event, fn)
		subs[event] = magic.SubscribeToEvent(event, function(t, d)
			if gone(viewport) then
				list_views[name] = nil
				for e, sub in pairs(subs) do
					magic.UnsubscribeFromEvent(e, sub)
				end
				return
			end
			if shown(viewport) then
				fn(d)
			end
		end)
	end
	-- x, y in window pixels, as the mouse and a touch give them: the UI's
	-- units are those over its scale ([JOIN_LIST_WHEEL]: at a scale not
	-- 1 the wheel missed the list)
	local function over(x, y)
		local sc = magic.ui.scale
		x, y = x / sc, y / sc
		local at = viewport.screenPosition
		return x >= at.x and x < at.x + viewport.width and
				y >= at.y and y < at.y + viewport.height
	end
	-- **A finger drags it** (playtest, 2026-10-07): a touchscreen has no
	-- wheel and no keys to walk it by
	on("TouchMove", function(d)
		if over(d:GetInt("X"), d:GetInt("Y")) then
			view:scroll(-d:GetInt("DY"))
		end
	end)
	if options.wheel or options.follow_focus then
		local pending = false
		if options.wheel then
			on("MouseWheel", function(d)
				local p = magic.input:GetMousePosition()
				local w = d:GetInt("Wheel")
				-- A text area in the list with more to show that way
				-- scrolls itself ([TEXTAREA_WHEEL]); the list at its end
				if over(p.x, p.y) and not list:WheelTakenAt(p.x, p.y, w) then
					view:scroll(-w * options.wheel)
				end
			end)
		end
		if options.follow_focus then
			on("KeyDown", function() pending = true end)
			-- The frame after the key, when the focus has moved
			on("Update", function()
				if not pending then
					return
				end
				pending = false
				-- The focused element itself: a row may be a group of
				-- them taller than the view
				local f = magic.ui.focusElement
				if f and list:HasRecursiveFocus() then
					view:show(f)
				end
			end)
		end
	end
	list_view_rows(view, list, width, options)
	function view:fit()
		list:SetLayout(LM_VERTICAL, options.spacing or 2,
				magic.IntRect(0, 0, 0, 0))
		-- options.fill: the height whatever is in it (a page)
		viewport:SetFixedSize(width, options.fill and height or
				math.max(row_height, math.min(height, list.height)))
		view:scroll(0)
	end
	function view:scroll(dy)
		local most = math.max(0, list.height - viewport.height)
		local top = math.min(most, math.max(0, -list.position.y + dy))
		list:SetPosition(0, -top)
	end
	function view:show(e)
		show_in(scroller(viewport, "UIElement"), e)
	end
	return view
end

-- A list too long for the screen, a page at a time.
--
-- The items are the menu's own buttons, so the keyboard walks them like any
-- others, and the page buttons ask the caller to draw the menu again --
-- because what else is on the menu is the caller's business, and rebuilding
-- it is what every menu in this tree already does when its contents change.
--
--   ui_utils.add_paged(menu, items, {
--       page = page, per_page = 12,
--       redraw = function(new_page) ... end,
--   })
--
-- items are {label = , action = } or {label, action}. Returns how many
-- pages there are and which one was drawn.
function M.safe.add_paged(menu, items, options)
	options = options or {}
	local per_page = math.max(1, options.per_page or 12)
	local pages = math.max(1, math.ceil(#items / per_page))
	local page = math.max(1, math.min(options.page or 1, pages))
	local first = (page - 1) * per_page + 1
	local last = math.min(#items, first + per_page - 1)
	for i = first, last do
		local item = items[i]
		menu:add(item.label or item[1], item.action or item[2])
	end
	if pages > 1 and options.redraw then
		-- Which way round: the list is newest first everywhere this is
		-- used, so the next page is older
		if page > 1 then
			menu:add((options.prev_label or "^ newer") ..
					"   (page " .. (page - 1) .. " of " .. pages .. ")",
					function() options.redraw(page - 1) end)
		end
		if page < pages then
			menu:add((options.next_label or "v older") ..
					"   (page " .. (page + 1) .. " of " .. pages .. ")",
					function() options.redraw(page + 1) end)
		end
	end
	return pages, page
end

-- **A list of servers** in a list_view, the rows launch_menu's
-- Servers screen has ([SERVER_LIST]; that look since the playtest of
-- 2026-10-07): one line each, the name and a dim badge, and the row
-- under the mouse or picked last described in options.panel, the column
-- beside the list, at its top.
--
--   local list = ui_utils.server_list(parent, {width = 520, height = 480,
--       panel = column}, function(row, second) ... end)
--   list:set_rows({{name = , badge = , line = , icon = }, {header = }, ...})
--
-- options.hint is what the panel says before a pick.
--
-- on_pick(row, second) is called on a click, second true when the same
-- row was picked again within a second -- a double-click. set_rows()
-- replaces what is shown; the caller filters before it. A {header = s}
-- row is a heading.
function M.safe.server_list(parent, options, on_pick)
	options = options or {}
	local width, height = options.width or 520, options.height or 480
	local view = M.safe.list_view(parent, width, height,
			{wheel = 40, follow_focus = true})
	local detail = nil
	if options.panel then
		detail = options.panel:CreateChild("UIElement")
		-- **One height whatever it says**: the fields and Join under it
		-- stay put as the mouse crosses rows on its way to them.
		-- simplified: a description longer than this is cut off
		detail:SetFixedHeight(options.detail_height or 130)
		detail.clipChildren = true
	end
	local list = {view = view}
	local picked, last_us = nil, 0
	local function describe(row)
		if not detail or gone(detail) then
			return
		end
		detail:RemoveAllChildren()
		-- Placed by hand: a layout would share the spare height out
		-- between the lines
		local y = 0
		local function text(s, size, color)
			local t = detail:CreateChild("Text")
			t:SetStyleAuto()
			t.text = s
			t:SetFontSize(size)
			if color then t.color = magic.Color(M.safe.rgb(color)) end
			t:SetWordwrap(true)
			t:SetFixedWidth(options.panel.width)
			t:SetPosition(0, y)
			y = y + t.height + 4
		end
		if row then
			text(row.name or "", 18)
			if row.badge and row.badge ~= "" then text(row.badge, 12, "dim") end
			if row.line and row.line ~= "" then text(row.line, 13, "dim") end
		else
			text(options.hint or "Pick a server, or type its address", 13,
					"dim")
		end
	end
	describe(nil)
	function list:set_rows(rows)
		view.list:RemoveAllChildren()
		-- Free while the rows go in: a vertical layout is redone for each
		-- one added (list_view's fit())
		view.list:SetLayout(magic.LM_FREE, 0, magic.IntRect(0, 0, 0, 0))
		view.list:SetPosition(0, 0)
		for _, row in ipairs(rows) do
			if row.header then
				view:header(row.header)
			else
				local b = view:row({label = row.name or "", icon = row.icon},
						row.badge)
				b:SetFocusMode(magic.FM_FOCUSABLE)
				magic.SubscribeToEvent(b, "HoverBegin", function()
					describe(row)
				end)
				magic.SubscribeToEvent(b, "HoverEnd", function()
					describe(picked)
				end)
				magic.SubscribeToEvent(b, "Released", function()
					local now = buildat.get_time_us()
					local second = picked == row and now - last_us < 1000000
					picked, last_us = row, now
					describe(row)
					on_pick(row, second)
				end)
			end
		end
		view:fit()
		-- The list's height stays: the window does not move under the
		-- mouse as rows come and go
		view.viewport:SetFixedSize(width, height)
	end
	return list
end

local message_handle = nil

-- **One dropdown for every choice of one** ([UI_DROPDOWN], user
-- 2026-10-09), launch_menu's filter's look: the "▼" at its right end,
-- the row under the pointer highlighted and the chosen one less
-- (style.xml's button and button-line greys). choices are
-- {label, value} (a plain string is both), current a value;
-- on_choose(value, index) on a pick of another. options: width (the
-- longest choice's, at least min_width), height (28), label (a text
-- before it, label_width wide), none (what it says in red while nothing
-- is chosen), on_dismiss (called when it closes with no pick), fill (as
-- wide as its row lets it, at least that).
-- By the keyboard (keyboard_page takes it as a button): Enter or Space
-- opens it, Up and Down move, Enter picks; Escape or a press outside it
-- closes it with the choice as it was, and the page does not see that
-- Escape. The popup is under it, or over it where there is more room,
-- scrolled when neither holds it. Returns the DropDownList, and the row
-- holding it and its label when there is one.
local drops = {} -- live dropdowns
local drops_update, drops_sub -- below
local drop_serial = 0
local drop_labels = {} -- by the dropdown's name: {label, row, fill, width}
local drop_setters = {} -- by the dropdown's name: {dropdown, dropdown_set's}
local drop_was = {} -- by the dropdown's name: its popup up last frame
function M.safe.dropdown(parent, choices, current, on_choose, options)
	options = options or {}
	local h = options.height or 28
	local row = nil
	if options.label then
		row = parent:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(0, 0, 0, 0))
		-- Not stretched by a column it is put in
		row:SetFixedHeight(h)
		local t = row:CreateChild("Text")
		t:SetStyleAuto()
		t.text = options.label
		-- Its text's own width: a layout may have stretched it already
		t:SetFixedWidth(options.label_width or t.minWidth)
		t.verticalAlignment = VA_CENTER
		parent = row
	end
	local drop = parent:CreateChild("DropDownList")
	drop_serial = drop_serial + 1
	drop:SetName("dropdown_" .. drop_serial)
	if row and not options.label_width then
		local l = row:GetChild(0)
		drop_labels[drop:GetName()] = {l, row, options.fill, l.width}
	end
	drop:SetStyleAuto()
	drop:SetFocusMode(magic.FM_FOCUSABLE)
	drop.resizePopup = true
	local arrow = drop:CreateChild("Text")
	arrow:SetStyleAuto()
	arrow.text = "▼"
	arrow:SetFontSize(12)
	arrow.color = magic.Color(M.safe.rgb("dim"))
	-- The placeholder's own text, which Urho3D shows while nothing is
	-- selected, the arrows' highlight included
	local none = nil
	if options.none then
		none = drop.placeholder:GetChild(0)
		none.text = options.none
		none.color = magic.Color(M.safe.rgb("error"))
		none.verticalAlignment = VA_CENTER
	end
	local values, index, widest = {}, nil, none and none.width or 0
	for i, c in ipairs(choices) do
		local label, value = c, c
		if type(c) == "table" then
			label, value = c[1], c[2]
		end
		values[i] = value
		-- A row: an empty text, which draws the colours over all of it,
		-- and the label centred in it, a font's glyphs overhanging their
		-- own text's box
		local t = parent:CreateChild("Text")
		t:SetStyleAuto()
		t:SetFixedHeight(h)
		-- Named for a driven click covered by it ([SEQ_CLICK])
		t:SetName(drop:GetName() .. ": " .. tostring(label))
		local l = t:CreateChild("Text")
		l:SetStyleAuto()
		l.text = label
		l.verticalAlignment = VA_CENTER
		widest = math.max(widest, l.width)
		drop:AddItem(t)
		-- Text draws neither colour without one, and only when enabled
		t.enabled = true
		t:SetSelectionColor(magic.Color(0.2, 0.2, 0.25))
		t:SetHoverColor(magic.Color(0.33, 0.33, 0.4))
		if value == current and current ~= nil then
			index = i
			drop:SetSelection(i - 1)
		end
	end
	-- Urho3D chooses the first one added when none is: none again
	if not index then
		drop.listView:ClearSelection()
	end
	local w = options.width or
			math.max(widest + 48, options.min_width or 0)
	if options.fill then
		drop:SetFixedHeight(h)
		drop.minWidth = w
		drop.maxWidth = 100000
	else
		drop:SetFixedSize(w, h)
		-- Its label's and its own, not spread over a row it is put in
		if row then
			row:SetFixedWidth(row:GetChild(0).width + 10 + w)
		end
	end
	-- The list lays its children out in a row, so the choice's text takes
	-- all but the arrow's room (kept so as it grows: the Update below)
	drop.placeholder:SetFixedWidth(w - 28)
	-- The popup closing sends the list's selection whatever closed it. A
	-- pick (a click on a row, Enter) leaves the focus on the dropdown;
	-- Escape and a press elsewhere take it away, and the arrows may have
	-- moved the selection: put back
	magic.SubscribeToEvent(drop, "ItemSelected", function(_, _, data)
		-- A pick closes it twice: the popup's closing loses the focus,
		-- and Menu closes it again on that, inside the first
		if closed_now == drop then
			return
		end
		-- Removed with its window: a window rebuilt by the pick and taken
		-- down a frame later (floorplanner's panel.discard) loses the
		-- focus then, which closes it again; nothing to put back
		local ok, focused = pcall(function() return drop:HasFocus() end)
		if not ok then
			return
		end
		closed_now = drop
		refocus = nil
		if not focused then
			if index then
				drop:SetSelection(index - 1)
			else
				drop.listView:ClearSelection()
			end
			if magic.input:GetKeyPress(KEY_ESCAPE) then
				escape_taken = true
				uistack.take_key(KEY_ESCAPE)
				refocus = drop
			end
			if options.on_dismiss then
				options.on_dismiss()
			end
			return
		end
		refocus = drop
		local i = data:GetInt("Selection") + 1
		if i ~= index and values[i] ~= nil then
			index = i
			picked = function()
				local had = drop:HasFocus()
				on_choose(values[i], i)
				-- Moved on purpose (a page drawn again, a field to fill)
				if gone(drop) or drop:HasFocus() ~= had then
					refocus = nil
				end
			end
		end
	end)
	drop_setters[drop:GetName()] = {drop, function(value)
		for i, v in ipairs(values) do
			if v == value then
				index = i
				drop:SetSelection(i - 1)
			end
		end
	end}
	drops[#drops + 1] = drop
	if drops_sub then
		magic.UnsubscribeFromEvent("Update", drops_sub)
	end
	drops_sub = magic.SubscribeToEvent("Update", drops_update)
	return drop, row
end

-- Whether a dropdown has the keys and the mouse: its popup up, or closed
-- by this frame's Escape. A screen's own Escape or click-off stands down.
-- **The choice shown set by the screen**, not by a pick: on_choose is not
-- called. A plain SetSelection is put back by the dropdown, which keeps
-- its own record of the choice, and a later pick of the old one is then
-- no change to it.
function M.safe.dropdown_set(drop, value)
	local set = drop_setters[drop:GetName()]
	if set then
		set[2](value)
	end
end

function M.safe.dropdown_open()
	return drop_open or escape_taken
end

-- Every dropdown's popup closed, with no pick
function M.safe.close_dropdowns()
	for _, d in ipairs(drops) do
		if not gone(d) and d.showPopup then
			d:ShowPopup(false)
		end
	end
end

-- Each frame: the popups' room set for their next opening, which is
-- where Urho3D picks under or over, and the dropdowns removed forgotten.
-- Subscribed again by each dropdown made: a handler goes with the sandbox
-- that subscribed it, and this module outlives the screen that first
-- loaded it (the launcher's, left for a server and drawn again)
drops_update = function()
	escape_taken = false
	closed_now = nil
	local pick = picked
	picked = nil
	if pick then
		pick()
	end
	if refocus and not gone(refocus) and refocus.visible then
		refocus:SetFocus(true)
	end
	refocus = nil
	if #drops == 0 then
		drop_open = false
		return
	end
	local open, kept = false, {}
	local root_h = magic.ui.root.height
	for _, d in ipairs(drops) do
		if not gone(d) then
			kept[#kept + 1] = d
			-- Said as it changes, for a check that taps them ([TAP_DROPDOWN])
			if (drop_was[d:GetName()] or false) ~= d.showPopup then
				drop_was[d:GetName()] = d.showPopup
				log:info(d:GetName() .. (d.showPopup and " open" or " closed"))
			end
			if d.showPopup then
				open = true
				-- Opened by a click, the press gives the focus back to
				-- the dropdown after the popup took it: the arrows went
				-- nowhere
				if d:HasFocus() then
					d.listView:SetFocus(true)
				end
			elseif shown(d) then
				if d.placeholder.width ~= d.width - 28 then
					d.placeholder:SetFixedWidth(d.width - 28)
				end
				-- The label as wide as it is drawn. simplified: under a UI
				-- scale below 1 the letters are drawn wider than measured
				-- (each advance rounded at the drawn size), taken as 0.7
				-- px a letter; exact would be measuring at that size
				local l = drop_labels[d:GetName()]
				local sc = magic.ui.scale
				local lw = l and l[4] + (sc < 1 and
						math.ceil(#l[1].text * 0.7 / sc) or 0)
				if lw and l[1].width ~= lw then
					l[1]:SetFixedWidth(lw)
					if not l[3] then
						l[2]:SetFixedWidth(lw + 10 + d.width)
					end
				end
				local y = d.screenPosition.y
				-- simplified: the popup's frame is taken as 8 px
				d.popup.maxHeight = math.max(root_h - y - d.height, y) - 8
			end
		end
	end
	drops, drop_open = kept, open
	for name, l in pairs(drop_labels) do
		if gone(l[2]) then
			drop_labels[name] = nil
		end
	end
	for name, set in pairs(drop_setters) do
		if gone(set[1]) then
			drop_setters[name] = nil
		end
	end
end

-- on_close is optional and is called when the dialog goes away, however it
-- goes: what wants it is a message that is the last thing before something
-- else has to happen, like a client quitting after it says why.
-- A line at the top of the screen for a few seconds, taking nothing --
-- not the mouse, not the focus: what an error in a game's form callback
-- is shown as ([MENU_ERRORS])
local notices = {}
-- Whether a world is up on the screen ([MENU_ERRORS]): a caught error is a
-- dialog before a join and a notice line in a game, and the launcher's own
-- game is not the only kind -- luanti_client's session runs on the menu's
-- screens and a dialog there takes the mouse from the player. A client says
-- so here; client/sandbox.lua reads it.
M.in_app = false

function M.safe.set_in_game(on)
	M.in_app = on and true or false
end

-- Text on the OS clipboard, on the user's own key or click: Urho3D's
-- SetClipboardText keeps it to itself unless told to use the system's
function M.safe.copy(text)
	magic.ui:SetUseSystemClipboard(true)
	magic.ui:SetClipboardText(tostring(text))
end

-- copy, if given ([LOG_REACH]: the error's full text), gets a "Copy"
-- button beside the line, which takes no focus and only a click where the
-- pointer is free; the line then stays 20 s, and while the pointer is on it
-- color: a name for rgb(), "error" when absent
-- **A screen's ×** ([CLOSE_GLYPH]): a dim "×" at the window's top right,
-- for a touchscreen with nothing to tap off a screen that fills it. A
-- Button with no style, so no border or background, 40x40 for a finger;
-- a child of `parent`, the window's (a sandbox has no GetParent), as the
-- window's layout would place it; kept at the window's corner and over it
-- each frame. Not in the keyboard's walk. Does on_close, or what a tap on
-- nothing does: Escape.
function M.safe.close_glyph(parent, window, on_close)
	local b = parent:CreateChild("Button")
	b:SetName("close_glyph")
	b.color = magic.Color(0, 0, 0, 0)
	b:SetFixedSize(40, 40)
	b:SetFocusMode(FM_NOTFOCUSABLE)
	-- The window's style (its own, or its parent's), for a parent with
	-- none: the UI's root
	local style = window.defaultStyle
	if style then
		b.defaultStyle = style
	end
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t.text = "×"
	t:SetFontSize(24)
	t:SetAlignment(HA_CENTER, VA_CENTER)
	-- HoverEnd comes after a close removed it
	local function shade(c)
		if not gone(t) then t.color = magic.Color(M.safe.rgb(c)) end
	end
	shade("dim")
	magic.SubscribeToEvent(b, "HoverBegin", function() shade("text") end)
	magic.SubscribeToEvent(b, "HoverEnd", function() shade("dim") end)
	magic.SubscribeToEvent(b, "Released", function()
		log:info("close_glyph: closing")
		if on_close then on_close() else uistack.press_back() end
	end)
	local sub
	local function place()
		if gone(b) or gone(window) then
			magic.UnsubscribeFromEvent("Update", sub)
			if not gone(b) then b:Remove() end
			return
		end
		local w, p = window.screenPosition, parent.screenPosition
		b:SetPosition(w.x - p.x + window.width - 40, w.y - p.y)
		b.visible = window.visible
		b.priority = window.priority + 1
	end
	sub = magic.SubscribeToEvent("Update", place)
	place()
	return b
end

function M.safe.show_notice(text, copy, color)
	local t = magic.ui.root:CreateChild("UIElement")
	t.defaultStyle = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	t:SetLayout(magic.LM_HORIZONTAL, 8, magic.IntRect(0, 0, 0, 0))
	t:SetAlignment(HA_CENTER, VA_TOP)
	t:SetPosition(0, 40 + 28 * #notices)
	t.priority = 1000
	local line = t:CreateChild("Text")
	line:SetStyleAuto()
	line.text = tostring(text)
	line.color = magic.Color(M.safe.rgb(color or "error"))
	line:SetTextEffect(magic.TE_SHADOW)
	local b, bt
	if copy then
		b = t:CreateChild("Button")
		b:SetStyleAuto()
		b:SetFocusMode(FM_NOTFOCUSABLE)
		b:SetLayout(LM_VERTICAL, 0, magic.IntRect(6, 2, 6, 2))
		bt = b:CreateChild("Text")
		bt:SetStyleAuto()
		bt.text = "Copy"
	end
	local n = {element = t,
			until_us = buildat.get_time_us() + (copy and 20000000 or 6000000)}
	notices[#notices + 1] = n
	if b then
		magic.SubscribeToEvent(b, "Released", function()
			M.safe.copy(copy)
			bt.text = "Copied"
		end)
		magic.SubscribeToEvent(b, "HoverBegin", function() n.held = true end)
		magic.SubscribeToEvent(b, "HoverEnd", function() n.held = false end)
	end
	if #notices == 1 then
		local sub
		sub = magic.SubscribeToEvent("Update", function()
			local now = buildat.get_time_us()
			local kept = {}
			for _, n in ipairs(notices) do
				if n.held then
					n.until_us = math.max(n.until_us, now + 2000000)
				end
				if now >= n.until_us then
					n.element:Remove()
				else
					kept[#kept + 1] = n
				end
			end
			notices = kept
			if #notices == 0 then
				magic.UnsubscribeFromEvent("Update", sub)
			end
		end)
	end
end

-- **A way back to the menu** (user, 2026-10-06): a "Menu" button in the
-- bottom right corner of parent, for a launch UI with no menu of its own
-- to switch from (the console, the room). It switches to launch_menu;
-- before(), if given, runs first, for one that has to take its own
-- screen down, and opts go to set_launch_ui ({close = true}). Returns
-- the button, whose visible the caller may set.
function M.safe.menu_button(parent, before, opts)
	local box = parent:CreateChild("UIElement")
	box.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	box:SetAlignment(HA_RIGHT, magic.VA_BOTTOM)
	box:SetFixedSize(80, 30)
	box:SetPosition(-10, -10)
	box.priority = 950
	local b = box:CreateChild("Button")
	b:SetStyleAuto()
	b:SetName("Button")
	b:SetFixedSize(80, 30)
	b:SetLayout(LM_VERTICAL, 0, magic.IntRect(0, 0, 0, 0))
	-- A click's, not the keyboard's: Tab in the console cycles its
	-- fields, and Enter on this would leave it
	b:SetFocusMode(FM_NOTFOCUSABLE)
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t.text = "Menu"
	t:SetTextAlignment(HA_CENTER)
	magic.SubscribeToEvent(b, "Released", function()
		if before then before() end
		local ok, why = (buildat.safe or buildat).set_launch_ui(
				"launch_menu", opts)
		if not ok then
			log:warning("menu_button: " .. tostring(why))
			M.safe.show_message_dialog(tostring(why))
		end
	end)
	return box
end

-- copy, if given, is put on the clipboard by a "Copy" button above "Ok"
-- ([LOG_REACH]: a caught error's full text); written only, on the user's
-- own click, as SetClipboardText is
function M.safe.show_message_dialog(message, on_close, copy)
	-- Don't stack multiple dialogs
	if message_handle then
		-- **A dialog can go without being closed** (2026-09-25): a
		-- sandbox reset, or a stack popped from elsewhere, takes its
		-- elements with it and leaves this handle pointing at a removed
		-- Text -- which raises on the next append, in trusted code,
		-- where it ends the client. Then it is not a dialog to add to,
		-- and a new one is drawn instead.
		if pcall(message_handle.append, message) then
			-- The newest caller is the one whose message is at the
			-- bottom of the dialog, so its on_close is the one that runs
			message_handle.on_close = on_close or message_handle.on_close
			if copy and message_handle.copy then
				message_handle.copy = message_handle.copy .. "\n" .. tostring(copy)
			end
			return
		end
		log:warning("show_message_dialog: the last dialog is gone; a new one")
		message_handle = nil
	end

	local root = uistack.main:push({desc="show_message_dialog"})

	local style = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	root.defaultStyle = style

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetName("show_message_dialog window")
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local message_text = window:CreateChild("Text")
	message_text:SetName("message_text")
	message_text:SetStyleAuto()
	message_text.text = message
	message_text:SetTextAlignment(HA_LEFT)

	-- The window is as wide as the widest line: the style gives it a width of
	-- its own and a message longer than that is otherwise cut off. A Text
	-- knows how wide it turned out once it has text and a font.
	local function fit_window()
		-- The text's own width plus the window's layout border and the frame
		-- its style draws
		local wanted = message_text.width + 40
		if wanted > window.minWidth then
			window.minWidth = wanted
		end
	end
	fit_window()

	local copy_button, copy_text
	if copy then
		copy_button = window:CreateChild("Button")
		copy_button:SetStyleAuto()
		copy_button:SetName("Button")
		copy_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
		copy_button.minHeight = 20
		copy_text = copy_button:CreateChild("Text")
		copy_text:SetName("ButtonText")
		copy_text:SetStyleAuto()
		copy_text.text = "Copy"
		copy_text:SetTextAlignment(HA_CENTER)
	end

	local ok_button = window:CreateChild("Button")
	ok_button:SetStyle("PrimaryButton")
	ok_button:SetName("Button")
	ok_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	ok_button.minHeight = 20
	local ok_button_text = ok_button:CreateChild("Text")
	ok_button_text:SetName("ButtonText")
	ok_button_text:SetStyleAuto()
	ok_button_text.text = "Ok"
	ok_button_text:SetTextAlignment(HA_CENTER)

	message_handle = {
		append = function(text)
			if #message_text.text < 1000 then
				message_text.text = message_text.text.."\n"..text
				fit_window()
			end
		end,
		on_close = on_close,
		copy = copy and tostring(copy),
	}

	local function close()
		local closed = message_handle
		uistack.main:pop(root)
		message_handle = nil
		if closed and closed.on_close then
			closed.on_close()
		end
	end

	-- The menu's keys: Enter, and Escape on the "Ok" that is the way back
	local items = {{ok_button, function()
		log:info("show_message_dialog: closed")
		close()
	end}}
	if copy_button then
		table.insert(items, 1, {copy_button, function()
			M.safe.copy(message_handle.copy)
			copy_text.text = "Copied"
		end})
	end
	M.safe.bind_button_menu(root, items)
	ok_button:SetFocus(true)
end

-- yes_label is the first button's, "Yes" when absent ([DELETE_WORDING]:
-- it was "Force kill", its first user's, and a deletion asked that);
-- no_label the second's, "Cancel" when absent
-- options: yes_focused (yes has the focus, not Cancel), yes_key (a key that
-- answers yes, as the quit dialog's Q)
function M.safe.show_confirm_dialog(message, on_yes, on_no, yes_label, no_label, options)
	options = options or {}
	local root = uistack.main:push({desc="show_confirm_dialog"})
	-- Over a window outside the stack (a page window's 100)
	if options.priority then
		root.priority = options.priority
	end

	local style = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	root.defaultStyle = style

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local message_text = window:CreateChild("Text")
	message_text:SetStyleAuto()
	message_text.text = message

	local function finish(yes)
		uistack.main:pop(root)
		if yes then
			if on_yes then on_yes() end
		else
			if on_no then on_no() end
		end
	end

	local yes_button = window:CreateChild("Button")
	yes_button:SetName("Button")
	yes_button:SetStyle("PrimaryButton")
	yes_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	yes_button.minHeight = 20
	local yes_text = yes_button:CreateChild("Text")
	yes_text:SetName("ButtonText")
	yes_text:SetStyleAuto()
	yes_text.text = yes_label or "Yes"
	yes_text:SetTextAlignment(HA_CENTER)

	local no_button = window:CreateChild("Button")
	no_button:SetName("Button")
	no_button:SetStyleAuto()
	no_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	no_button.minHeight = 20
	local no_text = no_button:CreateChild("Text")
	no_text:SetName("ButtonText")
	no_text:SetStyleAuto()
	no_text.text = no_label or "Cancel"
	no_text:SetTextAlignment(HA_CENTER)

	-- The menu's keys ([MENU_KEYS]): the arrows, Enter, and
	-- Escape on "Cancel", the way back
	M.safe.bind_button_menu(root, {
		{yes_button, function() finish(true) end},
		{no_button, function() finish(false) end},
	}, function(key)
		for _, k in ipairs(options.yes_keys or {options.yes_key}) do
			if key == k then
				finish(true)
				return true
			end
		end
	end)
	if options.yes_focused then
		yes_button:SetFocus(true)
	else
		no_button:SetFocus(true)
	end
	-- What a check waits for
	log:info("confirm dialog: " .. tostring(message))
end

-- A small non-modal notice in the top right corner. It does not take focus and
-- disappears by itself. A second call replaces what is showing.
local notification = nil
local notification_update_subscribed = false

function M.safe.show_notification(text, duration_s)
	duration_s = duration_s or 2.0

	if notification then
		notification.window:Remove()
		notification = nil
	end

	local window = magic.ui.root:CreateChild("Window")
	window.defaultStyle = magic.cache:GetResource(
			"XMLFile", "ui_utils/res/style.xml")
	window:SetStyleAuto()
	window:SetName("show_notification window")
	window:SetLayout(LM_VERTICAL, 0, magic.IntRect(10, 6, 10, 6))
	window:SetFocusMode(FM_NOTFOCUSABLE)

	local message_text = window:CreateChild("Text")
	message_text:SetStyleAuto()
	message_text.text = text

	-- Align once the text is in; alignment does not follow a later resize
	window:SetAlignment(HA_RIGHT, VA_TOP)

	notification = {
		window = window,
		end_time_us = buildat.get_time_us() + duration_s * 1000000,
	}

	-- One subscription for the lifetime of the process. Unsubscribing from
	-- inside a handler breaks extension/urho3d's global event multiplexer.
	if not notification_update_subscribed then
		notification_update_subscribed = true
		magic.SubscribeToEvent("Update",
		function(event_type, event_data)
			if notification and buildat.get_time_us() >= notification.end_time_us then
				notification.window:Remove()
				notification = nil
			end
		end)
	end
end


-- The half of `event scan` that reads the UI ([SCAN_EVENT], [FIRST_RUN]):
-- every element under one, with its kind, its rectangle in window pixels
-- and its text or image, one line each under the label. A form in the
-- world and a menu screen give the same lines, so a driver reads both
-- the same way.
--
-- Every rectangle is in window pixels, the coordinates mouse_pos takes:
-- Urho's UI is laid out in its own units, the window's pixels over
-- ui:GetScale(), and one conversion here beats every reader knowing
-- which space a line is in. Clipped to the window, so that the centre of
-- what is left is a valid mouse position.
function M.safe.scan_pixels(x, y, w, h)
	-- The frame's pixels over the root's units: the logical frame in
	-- a scripted client, whatever the window is ([SEQ_FIXED_SIZE])
	local ww, wh = buildat.logical_size()
	local k = ww / math.max(1, magic.ui.root.width)
	local x0 = math.max(0, math.floor(x * k))
	local y0 = math.max(0, math.floor(y * k))
	local x1 = math.min(ww, math.floor((x + w) * k))
	local y1 = math.min(wh, math.floor((y + h) * k))
	return x0, y0, math.max(0, x1 - x0), math.max(0, y1 - y0)
end

function M.safe.scan_ui(label, element, depth, out)
	local ok, n = pcall(function() return element:GetNumChildren() end)
	if not ok then
		return
	end
	for i = 0, n - 1 do
		local child = element:GetChild(i)
		if child then
			local kind = child:GetTypeName()
			local at = child.screenPosition
			local x, y, w, h = M.safe.scan_pixels(at.x, at.y, child.width, child.height)
			local line = string.format("scan %s: ui %s%s at %d,%d size %dx%d",
					label, string.rep("  ", depth), kind, x, y, w, h)
			if kind == "Text" or kind == "LineEdit" then
				local okt, text = pcall(function()
					return child.GetText and child:GetText() or child.text
				end)
				if okt and text then
					line = line .. " text " .. dump(text)
				end
				-- A field's cursor and its selection ([TEXT_KEYS])
				local okc, c = pcall(function()
					return kind == "LineEdit" and child.cursorPosition or nil
				end)
				if okc and c then
					line = line .. " cursor " .. c
				end
				local oks, from, n = pcall(function()
					return child.selectionStart, child.selectionLength
				end)
				if kind == "Text" and oks and n and n > 0 then
					line = line .. " selection " .. from .. "+" .. n
				end
			end
			if kind == "BorderImage" or kind == "Sprite" or
					kind == "Button" then
				local okt, name = pcall(function()
					local tex = child.texture
					return tex and tex.name or nil
				end)
				if okt and name and name ~= "" then
					line = line .. " image " .. dump(name)
				-- No texture reads as a nil the sandbox refuses: no image
				-- (a close_glyph's button)
				elseif not okt and not tostring(name):find(
						'Disallowed type: "nil"', 1, true) then
					line = line .. " image ? (" .. tostring(name) .. ")"
				end
			end
			if child.visible == false then
				line = line .. " hidden"
			end
			-- What draws over what among siblings
			if child.priority ~= 0 then
				line = line .. " priority " .. child.priority
			end
			out[#out + 1] = line
			M.safe.scan_ui(label, child, depth + 1, out)
		end
	end
end

--
-- The loading screen ([JOIN_STRIPES], user 2026-10-12)
--
-- Buildat's dark colour over the window and two stripes: the line in amber
-- across the width, and under it, a line's height lower and 1.5 times as
-- tall, the last thing that came, its icon and name in cyan (a file
-- browser's entry), the pair centred. The client opens it at a join's
-- first announce of files (__buildat_join_screen) and says what the wait
-- is at; a game's code takes the one that is up with load_screen() and
-- goes on with its own lines and picture, so there is no frame between
-- the two. One nobody took closes when the game's scripts have run.
-- **The page's stripes** (src/client/web/index.html) are at the same
-- places and sizes: what fit() does here, its stripes() does there.
local load = nil
local BRAND_PAGE = {0x1b / 255, 0x1b / 255, 0x22 / 255}
-- The glyphs, 16x16 pixel art written once under the cache: nothing a
-- game must have, and no font has them. index.html draws the same rows.
local GLYPHS = {
	note = {
		"................", "......#########.", "......#########.",
		"......##.....##.", "......##.....##.", "......##.....##.",
		"......##.....##.", "......##.....##.", "......##.....##.",
		"......##.....##.", "...####...#####.", "..#####..######.",
		"..#####..######.", "...###....####..", "................",
		"................"},
	cube = {
		"................", "......#########.", ".....#.......##.",
		"....#.......#.#.", "...#.......#..#.", "..#########...#.",
		"..#.......#...#.", "..#.......#...#.", "..#.......#...#.",
		"..#.......#...#.", "..#.......#..#..", "..#.......#.#...",
		"..#.......##....", "..#########.....", "................",
		"................"},
	page = {
		"................", "...#######......", "...#.....##.....",
		"...#.....#.#....", "...#.....####...", "...#........#...",
		"...#.####...#...", "...#........#...", "...#.#####..#...",
		"...#........#...", "...#.####...#...", "...#........#...",
		"...#.#####..#...", "...#........#...", "...##########...",
		"................"},
	globe = {
		"................", "......####......", "....##.##.##....",
		"...#..#..#..#...", "..#..#....#..#..", "..#..#....#..#..",
		".##############.", ".#...#....#...#.", ".#...#....#...#.",
		".##############.", "..#..#....#..#..", "..#..#....#..#..",
		"...#..#..#..#...", "....##.##.##....", "......####......",
		"................"},
}
local glyphs_written = false
local function glyph(name)
	if not glyphs_written then
		glyphs_written = true
		local dir = buildat.get_cache_path() .. "/ui_utils_res"
		for n, rows in pairs(GLYPHS) do
			local ops = {}
			for y, row in ipairs(rows) do
				for x0, x1 in row:gmatch("()#+()") do
					ops[#ops + 1] = {op = "fill", color = {255, 255, 255, 255},
							at = {x0 - 1, y - 1}, size = {x1 - x0, 1}}
				end
			end
			buildat.compose_image({size = {16, 16}, ops = ops,
					write = dir .. "/load_glyphs/" .. n .. ".png"})
		end
		buildat.add_resource_dir(dir)
	end
	return magic.cache:GetResource("Texture2D", "load_glyphs/" .. name .. ".png")
end

local function load_fit(s)
	local w, h = magic.ui.root.width, magic.ui.root.height
	s.screen:SetFixedSize(w, h)
	-- The F5 info's size (user 2026-10-12), which fits a narrow window
	local size = 13
	if not s.font then
		s.font = magic.cache:GetResource("Font", buildat.font_mono)
		s.text:SetFont(s.font, size)
		s.name:SetFont(s.font, size)
	end
	-- Stripe one right above the gap, which is a line's height centred on
	-- the screen, and stripe two right below it, 1.5 times as tall
	local lh = s.text.height > 0 and s.text.height or size
	local h1 = lh + math.floor(size / 2)
	local h2 = math.floor(h1 * 1.5)
	local top = math.floor(h / 2 - lh / 2) - h1
	s.box.visible = s.text.text ~= ""
	s.box:SetFixedSize(w, h1)
	s.box:SetPosition(0, top)
	s.last:SetFixedSize(w, h2)
	s.last:SetPosition(0, top + h1 + lh)
	-- [SKELDAT_MAKING_MAP] The backdrop fitted whole and centred, seen in
	-- the gap between the stripes (the user's, 2026-10-18)
	local b = s.back
	if b and b.tex.width > 0 and b.tex.height > 0 then
		local k = math.min(w / b.tex.width, h / b.tex.height)
		b.el:SetFixedSize(math.floor(b.tex.width * k), math.floor(b.tex.height * k))
		b.el.imageRect = magic.IntRect(0, 0, b.tex.width, b.tex.height)
	end
	-- The icon as tall as the stripe allows; a picture kept to its
	-- proportions in that square
	local side = h2 - math.floor(size / 2)
	local iw, ih = side, side
	local tex = s.icon_tex
	if tex and tex.width > 0 and tex.height > 0 then
		local k = side / math.max(tex.width, tex.height)
		iw, ih = math.floor(tex.width * k + 0.5), math.floor(tex.height * k + 0.5)
		s.icon.imageRect = magic.IntRect(0, 0, tex.width, tex.height)
	end
	s.icon:SetFixedSize(iw, ih)
	s.icon:SetPosition(math.floor((side - iw) / 2), 0)
	s.name:SetPosition(side + math.floor(size / 2), 0)
	s.pair:SetFixedSize(side + math.floor(size / 2) + s.name.width, h2)
	-- **Not larger than the window** ([LOADING_PIC_FIT], user 2026-10-11):
	-- the client's fit lowers the UI scale for an element past the root,
	-- so the element is the root's size and its imageRect the centred
	-- part of the picture in the root's proportions
	local p = s.pic
	if p then
		local k = math.max(w / p.w, h / p.h)
		local cw, ch = w / k, h / k
		local x0, y0 = math.floor((p.w - cw) / 2), math.floor((p.h - ch) / 2)
		p.el:SetFixedSize(w, h)
		p.el.imageRect = magic.IntRect(x0, y0, x0 + math.floor(cw + 0.5),
				y0 + math.floor(ch + 0.5))
	end
end

local function load_open()
	local s = {}
	-- Under all else on the UI, so a game's chat and pause menu are over it
	-- simplified: the scene is still rendered under the screen
	s.screen = magic.ui.root:CreateChild("BorderImage")
	s.screen.priority = -100
	s.screen.color = magic.Color(0x15 / 255, 0x15 / 255, 0x1a / 255)
	s.box = s.screen:CreateChild("BorderImage")
	s.box.color = magic.Color(unpack(BRAND_PAGE))
	s.box.priority = 1
	s.text = s.box:CreateChild("Text")
	s.text:SetAlignment(HA_CENTER, VA_CENTER)
	s.text:SetColor(magic.Color(unpack(colors.main)))
	s.last = s.screen:CreateChild("BorderImage")
	s.last.color = magic.Color(unpack(BRAND_PAGE))
	s.last.priority = 1
	s.last.visible = false
	s.pair = s.last:CreateChild("UIElement")
	s.pair:SetAlignment(HA_CENTER, VA_CENTER)
	s.icon = s.pair:CreateChild("BorderImage")
	s.icon.verticalAlignment = VA_CENTER
	s.name = s.pair:CreateChild("Text")
	s.name.verticalAlignment = VA_CENTER
	s.name:SetColor(magic.Color(unpack(colors.focus)))
	s.update = magic.SubscribeToEvent("Update", function()
		load_fit(s)
	end)
	local api = {}
	-- line(text): stripe one
	function api.line(text)
		s.text:SetText(text)
		load_fit(s)
	end
	-- wait_line(what[, phase[, no_mb]]) -> "what -- X MB, Y KB/s... n s":
	-- the bytes read since the connect (unless no_mb), their rate since
	-- the last call, and the seconds since the phase (what, unless given)
	-- began; "Waiting for the server... n s" when nothing came for 10 s
	-- ([JOIN_PROGRESS])
	-- simplified: no total; the server learns a node's size only as it
	-- sends it
	function api.wait_line(what, phase, no_mb)
		phase = phase or what
		local now = buildat.get_time_us() / 1e6
		if s.phase ~= phase then
			s.phase, s.phase_t, s.at = phase, now, nil
		end
		local secs = math.floor(now - s.phase_t)
		local got, quiet = (buildat.received or function() end)()
		if not got then
			return string.format("%s... %d s", what, secs)
		end
		-- The rate from the line before: the first would count what came
		-- before the phase
		local rate = s.at and now > s.at and (got - s.got) / (now - s.at)
		s.got, s.at = got, now
		if quiet and quiet >= 10 then
			return string.format("Waiting for the server... %d s", quiet)
		end
		local mb = not no_mb and string.format("%.1f MB", got / 1e6)
		rate = rate and string.format("%d KB/s", rate / 1000)
		local parts = (mb and rate) and mb .. ", " .. rate or mb or rate
		return string.format("%s%s... %d s", what,
				parts and " -- " .. parts or "", secs)
	end
	-- arrival() -> kind, name: stripe two from what came last
	-- (last_arrival()), or what is coming when nothing whole came for
	-- half a second ([LOAD_IN_FLIGHT]); nil before anything
	function api.arrival()
		local a = (buildat.last_arrival or function() end)()
		if not a then
			return nil
		end
		local f = buildat.get_time_us() - a.t > 500000 and
				buildat.in_flight and buildat.in_flight()
		if f then
			a = {kind = "flight", name = f.name, have = f.have, size = f.size}
		end
		local tex, name = nil, nil
		if a.kind == "file" then
			name = a.name
			local ext = (a.name:match("%.(%w+)$") or ""):lower()
			if ext == "png" then
				tex = magic.cache:GetResource("Texture2D", a.name)
			end
			tex = tex or glyph(ext == "ogg" and "note" or
					(ext == "obj" or ext == "b3d" or ext == "x") and "cube" or
					"page")
		elseif a.kind == "chunk" then
			name = string.format("chunk %d, %d, %d", a.x, a.y, a.z)
			tex = glyph("globe")
		elseif a.kind == "flight" then
			name = string.format("%s  %.1f of %.1f MB",
					a.name ~= "" and a.name or "?", a.have / 1e6, a.size / 1e6)
			tex = glyph("page")
		else
			name = a.what
			tex = glyph("page")
		end
		if tex then
			tex.filterMode = magic.FILTER_NEAREST
			s.icon.texture = tex
		end
		-- Kept beside: the sandbox's texture getter raises on none
		s.icon_tex = tex
		s.name:SetText(name)
		s.last.visible = true
		load_fit(s)
		return a.kind, name
	end
	-- picture(data) -> w, h, or nil and why: a PNG or JPEG over the dark,
	-- scaled to cover and centred, under the stripes. Decoded once into a
	-- texture, no file ([LOADING_PIC_DECODE]).
	function api.picture(data)
		local img = magic.Image:new()
		if not magic.image_load_data(img, data, 4096) then
			-- An iPhone's own PNG (Apple's CgBI) is not read: said so, not
			-- as any picture that does not decode
			if data:sub(1, 4) == "\137PNG" and data:sub(13, 16) == "CgBI" then
				return nil, "an iPhone's PNG (Apple's CgBI), which is not " ..
						"read here: save it again as a plain PNG or a JPEG"
			end
			return nil, #data .. " bytes; a PNG or JPEG, 4096 a side at most"
		end
		local tex = magic.Texture2D:new()
		tex:SetData(img)
		if s.pic then
			s.pic.el:Remove()
		end
		local el = s.screen:CreateChild("BorderImage")
		el.texture = tex
		el:SetAlignment(HA_CENTER, VA_CENTER)
		s.pic = {el = el, w = img.width, h = img.height, tex = tex}
		load_fit(s)
		return img.width, img.height
	end
	-- backdrop(tex) ([SKELDAT_MAKING_MAP]): a texture the game owns and
	-- writes, over the dark and under the stripes, fitted whole (not
	-- covered as picture()'s), centred, its pixels kept square; nil
	-- takes it off
	function api.backdrop(tex)
		-- Nothing on a screen closed meanwhile (world_menu's wait goes
		-- before an app's "off" comes)
		if load ~= s or (s.back and s.back.tex == tex) then
			return
		end
		if s.back then
			s.back.el:Remove()
			s.back = nil
		end
		if tex then
			tex.filterMode = magic.FILTER_NEAREST
			local el = s.screen:CreateChild("BorderImage")
			el.texture = tex
			el:SetAlignment(HA_CENTER, VA_CENTER)
			s.back = {el = el, tex = tex}
		end
		load_fit(s)
	end
	function api.close()
		if load ~= s then
			return
		end
		load = nil
		magic.UnsubscribeFromEvent("Update", s.update)
		s.screen:Remove()
		log:info("load screen: closed")
	end
	s.api = api
	load_fit(s)
	return s
end

-- load_screen() -> the loading screen up, taken over: {line, wait_line,
-- arrival, picture, backdrop, close}; a new one if none is
function M.safe.load_screen()
	if not load then
		load = load_open()
		log:info("load screen: made by the game")
	elseif not load.taken then
		log:info("load screen: taken over by the game")
	end
	load.taken = true
	return load.api
end

-- The client's join ([JOIN_STRIPES]): what = "files" with got of total,
-- "starting" when the scripts are about to run, "done" after they ran
-- (closing a screen the game did not take), "left" on leaving.
-- simplified: said again only every 100 files; the seconds and stripe two
-- by the screen's own half second
function M.safe.join_screen(what, got, total)
	if what == "left" or what == "done" then
		if load and (what == "left" or not load.taken) then
			load.api.close()
		end
		return
	end
	if not load then
		load = load_open()
		log:info("load screen: made for the join")
		load.join_tick = magic.SubscribeToEvent("Update", function()
			local s = load
			if not s or s.taken then
				return
			end
			local t = buildat.get_time_us()
			if t < (s.join_next or 0) then
				return
			end
			s.join_next = t + 500000
			-- No MB beside the files: the line fits a phone's 400 pixels
			local line = s.api.wait_line(s.join_what or "Joining",
					s.join_phase, s.join_phase == "files")
			s.api.line(line)
			local kind, name = s.api.arrival()
			log:info("join: " .. line .. (kind and " | last " .. kind ..
					" " .. name or ""))
		end)
		local s = load
		local close = s.api.close
		s.api.close = function()
			magic.UnsubscribeFromEvent("Update", s.join_tick)
			close()
		end
	end
	if what == "files" then
		load.join_what = string.format("Files %d of %d", got, total)
		load.join_phase = "files"
	elseif what == "starting" then
		load.join_what, load.join_phase = "Starting the game", nil
	end
	load.join_next = 0
end

return M
-- vim: set noet ts=4 sw=4:
