-- Buildat: apps/floorplanner/main/client_lua/shell.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_PHONE_EDITING] 4z11 stage 5a, **the touch mode's split screen** of
-- floorplanner's editor: builtin/kit/client_lua/shell.lua's layout, world
-- rect, divider, panes, header and foot, copied and put over panel.lua's
-- windows (the two share no code). The client's preference fp_ui_mode (the
-- game settings' "Editor UI mode") picks it: 0 the device's (touch on a
-- touchscreen), 1 desktop (the floating windows, as before), 2 touch with
-- the UI half on the right in landscape, 3 on the left. While editing only
-- (Start editing); viewing, the join and the plans are as on the desktop.
--   - The screen's aspect picks the split: tall, the world above and the UI
--     half below (45 % / 55 %); wide, side by side (50 %), the UI half on
--     the handed side. The header dragged (its title or its empty part)
--     moves the divider, 0.2-0.8, remembered on this device (the app
--     preference fp_ui_split).
--   - The world is the viewport's rect; the rays, the plan's scale, the
--     field of view and the labels go by it (E.world_rect, pick.lua's
--     screen_size). Over it only the plan's own, the tool's guide line and
--     the crosshair, at its middle.
--   - The UI half: a header ("< <the pane's title>" for Back, the title
--     alone where Back goes nowhere, 2D | 3D | Walk with the one on lit,
--     "..."), the pane, the touch bar's buttons (Undo, Redo, Delete, Angle,
--     Use in Walk, Cancel) and a status line. The panes are the editor's
--     windows: Tools (the toolbar less its views and Menu), Palette,
--     Properties, Layouts and a dialog (the colour picker, Replace, Fit to
--     samples); "..." lists them and Menu (the pause menu). The pane follows
--     what is done: Properties as something is selected or a tool other
--     than Material is taken, the Palette for Material, the dialog while it
--     is up. A pane's window is made in a view that scrolls (panel.window's
--     pane, SH.wrap), its rows spread across it, its targets at least
--     SH.TOUCH UI pixels; out of the client's UI fit (FollowsRoot).
--   - Tall, a field typed in with the on-screen keyboard up: the UI half
--     moves up by the keyboard's height, unresized, and the world loses as
--     much (Kit's); a keyboard taller than the world shortens the UI half,
--     its view scrolled to the field. Wide: the field entry mode
--     (field_entry.lua).
--   - Stage 5b: the world's gestures are [FP_TOUCH] 3's in its rect, a
--     press begun in the UI half none (editor.lua); the mouse is a finger's
--     (left a finger, a right drag two fingers', the middle a pinch, the
--     wheel zooming in 2D and 3D, not in Walk; Walk's mouse the desktop's).
-- simplified: the chat's lines at the world's lower left are as wide as on
-- the desktop (a long one runs over the UI half); a viewport's hidden menus
-- are as on the desktop; the colour sheet is wider than a phone's pane (it clips); a
-- world of no height is drawn a pixel high under the UI half (a rect of
-- nothing is the whole screen)
return function(A)
local S, E, M, magic, log, panel = A.S, A.E, A.M, A.magic, A.log, A.panel
local SH = {pane = "tools", stack = {}, views = {}, placed = {}}
M.sh = SH

-- A target's least side, UI pixels (the user's 48, as Kit's)
SH.TOUCH = 48
local PAD = 6
local TITLES = {tools = "Tools", palette = "Palette", props = "Properties",
	layouts = "Layouts"}
local PANES = {"tools", "palette", "props", "layouts", "dialog"}

local mode = buildat.declare_preference and
		buildat.declare_preference("fp_ui_mode", function(v)
			mode = v
			log:info("fp shell: UI mode " .. SH.mode())
		end) or 0

do
	local t, w = tostring(buildat.get_app_preference and
			buildat.get_app_preference("fp_ui_split") or ""):match(
			"^([%d.]+) ([%d.]+)")
	SH.split = {tall = tonumber(t) or 0.45, wide = tonumber(w) or 0.5}
end

function SH.mode()
	local m = tonumber(mode) or 0
	if m == 0 then
		return S.touch and "rh" or "desktop"
	end
	return m == 1 and "desktop" or m == 3 and "lh" or "rh"
end

function SH.on()
	local d = E.doc
	return d ~= nil and not S.suspended and d.can("edit") and
			SH.mode() ~= "desktop"
end

-- Whether a point in pixels is off the world's rect (nothing is with the
-- shell off): the UI half's, and anywhere under the field entry mode
function SH.off_world(x, y)
	local r = E.world_rect
	return r ~= nil and (M.fe.s ~= nil or x < r[1] or y < r[2] or
			x >= r[1] + r[3] or y >= r[2] + r[4])
end

local function available(p)
	if p == "dialog" then
		return S.picker ~= nil or S.replace ~= nil
	end
	return true
end

-- The world's and the UI half's rects ({x, y, w, h}, UI units), whether the
-- screen is tall, the keyboard's height taken
function SH.layout()
	local r = magic.ui.root
	local rw, rh = r.width, r.height
	if rh >= rw then
		local wh = math.floor(rh * SH.split.tall + 0.5)
		local world, ui = {0, 0, rw, wh}, {0, wh, rw, rh - wh}
		local f = magic.ui.focusElement
		local kb = f ~= nil and f:GetTypeName() == "LineEdit" and
				buildat.keyboard_height() or 0
		if kb > 0 and kb <= wh then
			world[4], ui[2] = wh - kb, wh - kb
		elseif kb > 0 then
			world[4], ui[2], ui[4] = 0, 0, math.max(SH.TOUCH * 3, rh - kb)
		end
		return world, ui, true, kb
	end
	local uw = math.floor(rw * SH.split.wide + 0.5)
	if SH.mode() == "lh" then
		return {uw, 0, rw - uw, rh}, {0, 0, uw, rh}, false, 0
	end
	return {0, 0, rw - uw, rh}, {rw - uw, 0, uw, rh}, false, 0
end

-- The width a pane's window has (UI units)
function SH.pane_w()
	local _, ui = SH.layout()
	return ui[3] - 2 * PAD
end

local function world_px(r)
	local sc = magic.ui.scale
	return {math.floor(r[1] * sc + 0.5), math.floor(r[2] * sc + 0.5),
		math.max(1, math.floor(r[3] * sc + 0.5)),
		math.max(1, math.floor(r[4] * sc + 0.5))}
end

local function drop_more()
	if SH.more_w then
		SH.more_w:Remove()
		SH.more_w = nil
	end
end

-- Pane p shown: Layouts' window is up only as its pane
local function set_pane(p)
	SH.pane, SH.placed = p, {}
	drop_more()
	S.layouts_open = p == "layouts"
	A.refresh()
end

function SH.show(p)
	if p == SH.pane then
		drop_more()
		return
	end
	SH.stack[#SH.stack + 1] = SH.pane
	if #SH.stack > 16 then
		table.remove(SH.stack, 1)
	end
	log:info("fp shell: the " .. p .. " pane")
	set_pane(p)
end

local function fallback()
	return S.primary and "props" or "tools"
end

-- Where Back goes now (SH.back's), nil where it would do nothing
function SH.back_to()
	for i = #SH.stack, 1, -1 do
		local p = SH.stack[i]
		if p ~= SH.pane and available(p) then
			return p
		end
	end
	local p = fallback()
	return p ~= SH.pane and p or nil
end

function SH.back()
	local p
	repeat
		p = table.remove(SH.stack)
	until not p or (p ~= SH.pane and available(p))
	if not p then
		p = fallback()
		if p == SH.pane then
			return
		end
	end
	log:info("fp shell: back to the " .. p .. " pane")
	set_pane(p)
end

-- panel.window's for a pane's window ({pane = ...}): a view that scrolls
-- in it, whose body the window's builder fills; nil off the touch mode
-- (the shell sizes the view each frame, fit_view)
function SH.wrap(w)
	if not SH.on() then
		return nil
	end
	local view = w:CreateChild("ScrollView")
	view:SetStyleAuto()
	view:SetFocusMode(magic.FM_NOTFOCUSABLE)
	view.scrollBarsAutoVisible = false
	view:SetScrollBarsVisible(false, false)
	local body = view:CreateChild("UIElement")
	body:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	view.contentElement = body
	body:SetPosition(0, 0)
	view:SetFixedSize(SH.TOUCH, SH.TOUCH)
	SH.views[w] = {view = view}
	return body
end
panel.pane_wrap = SH.wrap

-- "...": the panes and the pause menu, under the header at the UI half's
-- right (tick)
function SH.more()
	if SH.more_w then
		drop_more()
		return
	end
	local e = {}
	for _, p in ipairs(PANES) do
		if available(p) then
			e[#e + 1] = {p == "dialog" and SH.title_of("dialog") or TITLES[p],
				function() SH.show(p) end}
		end
	end
	e[#e + 1] = {"Menu", function() A.open_pause() end}
	local w = panel.window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	w.priority = 10
	w.opacity = 1
	-- Hidden until sized and placed (tick): it showed at the top left at the
	-- text size for a frame (the sweep of 2026-11-12)
	w.visible = false
	local names = {}
	for i, en in ipairs(e) do
		-- (named "menu <label>" as Kit's, for a drive)
		panel.button(w, en[1], function()
			drop_more()
			en[2]()
		end):SetName("menu " .. en[1])
		names[i] = en[1]
	end
	SH.more_w = w
	log:info("fp shell: the ... menu: " .. table.concat(names, ", "))
end

local function angle_label()
	return "Angle " .. (S.touch_angle and M.angle_text(S.angle) or "90 deg")
end

-- The shell's window: the UI half's background, header, foot and status
function SH.build()
	if SH.win then
		SH.win:Remove()
		SH.win = nil
	end
	drop_more()
	SH.placed = {}
	if not SH.on() then
		return
	end
	local w = panel.window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	SH.win = w
	SH.laid, SH.gap = nil, nil
	w:SetName("fp: touch shell")
	w:SetLayout(magic.LM_FREE, 0, magic.IntRect(0, 0, 0, 0))
	-- Under the panes, opaque: the world is not under it
	w.priority = -2
	w.opacity = 1
	w.clipChildren = true
	-- The header: Back carries the pane's title; a press on it or on the
	-- row's empty part may drag the divider, and a drag is then no Back
	SH.back_b = panel.button(w, "<", function()
		if not SH.divider_moved then
			SH.back()
		end
	end)
	SH.title = SH.back_b:GetChild(0)
	SH.back_b:SetName("shell back")
	SH.label = panel.label(w, "")
	magic.SubscribeToEvent(SH.back_b, "Pressed", function()
		SH.drag, SH.divider_moved = true, nil
	end)
	SH.views_b = {}
	for _, v in ipairs({{"2d", "2D"}, {"3d", "3D"}, {"walk", "Walk"}}) do
		local b = panel.button(w, v[2], function() M.pick_view(v[1]) end)
		b:SetName("shell view " .. v[1])
		SH.views_b[#SH.views_b + 1] = {v = v[1], b = b, t = b:GetChild(0)}
	end
	SH.header_said = nil
	SH.more_b = panel.button(w, "...", SH.more)
	SH.more_b:SetName("shell more")
	SH.empty = panel.label(w, "")
	-- The foot: the touch bar's (editor.lua's build_toolbar off the shell)
	SH.acts = {}
	for _, a in ipairs({
			{"undo", "Undo", function() E.doc.undo() end},
			{"redo", "Redo", function() E.doc.redo() end},
			{"delete", "Delete", function() A.delete_selected() end},
			{"angle", angle_label(), function()
				S.touch_angle = not S.touch_angle
			end},
			{"use", "Use", function() M.use() end},
			{"cancel", "Cancel", function() M.escape() end}}) do
		local b = panel.button(w, a[2], a[3])
		b:SetName("shell " .. a[1])
		SH.acts[#SH.acts + 1] = {b = b, t = b:GetChild(0), use = a[1] == "use"}
	end
	SH.status = panel.label(w, "")
	SH.status_said = nil
end

-- Its parts where the UI half is now (after the text size's scaling)
local function place_shell()
	local u, w, T = SH.ui, SH.win, SH.TOUCH
	w:SetPosition(u[1], u[2])
	w:SetFixedSize(u[3], u[4])
	SH.title_set = nil
	local sy = u[4] - PAD - SH.status.height
	SH.status:SetPosition(PAD, sy)
	-- The buttons in rows as they fit (each its label's width, at least the
	-- touch size), each row stretched across; Use in Walk only
	local room, rows = u[3] - 2 * PAD, {{used = -4}}
	for _, a in ipairs(SH.acts) do
		local b = a.b
		local bw, r = math.max(T, a.t.width + 16), rows[#rows]
		b.visible = not a.use or S.view == "walk"
		if not b.visible then
			bw = nil
		elseif #r > 0 and r.used + 4 + bw > room then
			r = {used = -4}
			rows[#rows + 1] = r
		end
		if bw then
			r[#r + 1], r.used = {b = b, w = bw}, r.used + 4 + bw
		end
	end
	local ay = sy - #rows * (T + 4)
	for i, r in ipairs(rows) do
		local x, extra = PAD, math.floor((room - r.used) / #r)
		for _, c in ipairs(r) do
			c.b:SetFixedSize(c.w + extra, T)
			c.b:SetPosition(x, ay + (i - 1) * (T + 4))
			x = x + c.w + extra + 4
		end
	end
	local top = PAD + T + 4
	SH.empty:SetPosition(PAD, top + 4)
	SH.pane_rect = {u[1] + PAD, u[2] + top, u[3] - 2 * PAD, ay - 4 - top}
end

-- The header: "< <title>" at the left, as wide as its text, the title cut
-- to leave the rest their room; the row's empty part (gap) after it;
-- 2D | 3D | Walk and "..." at the right
-- simplified: a UI half under about 290 UI px across has the view buttons
-- narrower than the touch size, not in a second row (Kit's)
local function place_header(t)
	local u, T = SH.ui, SH.TOUCH
	local x = u[3] - PAD - T
	SH.more_b:SetFixedSize(T, T)
	SH.more_b:SetPosition(x, PAD)
	local vw, need = {}, 0
	for i, e in ipairs(SH.views_b) do
		vw[i] = math.max(T, e.t.width + 16)
		need = need + vw[i] + 4
	end
	local room = x - 2 * PAD - T - 4
	local k = need > room and room / need or 1
	for i = #SH.views_b, 1, -1 do
		local bw = math.floor(vw[i] * k)
		x = x - 4 - bw
		SH.views_b[i].b:SetFixedSize(bw, T)
		SH.views_b[i].b:SetPosition(x, PAD)
	end
	local most, n = x - 4 - PAD, #t
	local can = SH.back_to() ~= nil
	local tx, pre = can and SH.title or SH.label, can and "< " or ""
	tx.text = pre .. t
	while tx.width + 16 > most and n > 0 do
		n = n - 1
		tx.text = pre .. t:sub(1, n) .. ".."
	end
	if tx.width + 16 > most then
		tx.text = can and "<" or ""
	end
	SH.back_b.visible, SH.label.visible = can, not can
	SH.shown_title = tx.text
	if not can then
		SH.label:SetPosition(PAD + 8, PAD + math.floor((T - SH.label.height) / 2))
		SH.gap = {PAD - 1, x}
		return
	end
	local bw = math.max(T, math.min(most, SH.title.width + 16))
	SH.back_b:SetFixedSize(bw, T)
	SH.back_b:SetPosition(PAD, PAD)
	SH.gap = {PAD + bw, x}
end

-- Each target in a window at the touch size: a button, a field, a dropdown
-- at least SH.TOUCH high (a button as wide), a check box SH.TOUCH square;
-- in a row (panel.row's, its var FpRow) in a scroll view free to grow, so
-- the row's layout spreads them across it (Kit's touch_size)
local function touch_size(el, depth, scrolled)
	local T = SH.TOUCH
	local in_row = scrolled and el:GetVar("FpRow") == "1"
	for i = 0, el:GetNumChildren() - 1 do
		local c = el:GetChild(i)
		local t = c and c:GetTypeName()
		if t == "CheckBox" then
			c:SetFixedSize(T, T)
		elseif t == "Button" or t == "LineEdit" or t == "DropDownList" then
			if c.maxHeight < T then
				c.maxHeight = T
			end
			if c.minHeight < T then
				c.minHeight = T
			end
			if t == "Button" and c.minWidth < T then
				if c.maxWidth < T then
					c.maxWidth = T
				end
				c.minWidth = T
			end
			if in_row then
				c.maxWidth = 100000
			end
		elseif c and t ~= "ScrollBar" and t ~= "Text" and depth < 40 then
			touch_size(c, depth + 1, scrolled or t == "ScrollView")
		end
	end
	-- (laid out again as panel.row's: a target's new maximum is not applied
	-- by itself)
	if in_row then
		el:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	end
end

function SH.title_of(p)
	if p == "dialog" then
		return S.replace and "Replace" or S.picker and (S.picker.fit and
				"Fit to samples" or S.picker.title) or "Dialog"
	end
	return TITLES[p]
end

local function status_text()
	local d, n = E.doc, 1
	for _ in pairs(d.others) do
		n = n + 1
	end
	return (d.plan_name or "") .. " · Editing · " .. n .. " here"
end

-- The divider dragged by the header: by as much as the pointer moved since
-- it was pressed (a finger is the left button too), once that is a quarter
-- of the touch size; let go, kept
local function drag_divider()
	local input = magic.input
	local p = input:GetMousePosition()
	local d = SH.drag
	if type(d) ~= "table" then
		d = {x = p.x, y = p.y, tall = SH.split.tall, wide = SH.split.wide}
		SH.drag = d
	end
	local r, sc = magic.ui.root, magic.ui.scale
	if not SH.divider_moved and math.abs(p.x - d.x) + math.abs(p.y - d.y) >
			SH.TOUCH / 4 * sc then
		SH.divider_moved = true
	end
	if not input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
		SH.drag = nil
		if not SH.divider_moved then
			return
		end
		if buildat.set_app_preference then
			buildat.set_app_preference("fp_ui_split", string.format("%.3f %.3f",
					SH.split.tall, SH.split.wide))
		end
		log:info(string.format("fp shell: the split %.2f %.2f", SH.split.tall,
				SH.split.wide))
		return
	end
	if not SH.divider_moved then
		return
	end
	local dx, dy = (p.x - d.x) / sc / r.width, (p.y - d.y) / sc / r.height
	local function clamp(v)
		return math.max(0.2, math.min(0.8, v))
	end
	if SH.tall then
		SH.split.tall = clamp(d.tall + dy)
	else
		SH.split.wide = clamp(d.wide + (SH.mode() == "lh" and dx or -dx))
	end
end

local function px_rect(r)
	local sc = magic.ui.scale
	return string.format("%d %d %d %d", r[1] * sc, r[2] * sc, r[3] * sc, r[4] * sc)
end

-- A pane's view in the pane: as tall as its body, at most to the pane's
-- foot and, with a wide screen's keyboard up, to above it; its body the
-- view's width. The field typed in scrolled into it once (Kit's fit_view)
local function fit_view(rec, pr, tall)
	local view = rec.view
	local body = view.contentElement
	local f = magic.ui.focusElement
	local typing = f ~= nil and f:GetTypeName() == "LineEdit"
	local kb = typing and buildat.keyboard_height() or 0
	local vy = view.screenPosition.y
	local room = pr[2] + pr[4] - vy - 8
	if kb > 0 and not tall then
		room = math.min(room, magic.ui.root.height - kb - vy - 4)
	end
	local bh = body.height + 4
	local h = math.max(SH.TOUCH, math.min(bh, room))
	local more = h < bh
	local vw = pr[3] - 12
	local bw = vw - 4 - (more and view.verticalScrollBar.width + 4 or 0)
	local key = h .. " " .. vw .. " " .. bw .. " " .. tostring(more)
	if rec.fitted ~= key then
		rec.fitted = key
		view:SetScrollBarsVisible(false, more)
		body:SetFixedWidth(bw)
		view:SetFixedSize(vw, h)
	end
	if kb == 0 then
		return
	end
	local fp, bp = f.screenPosition, body.screenPosition
	if fp.x < bp.x or fp.x >= bp.x + body.width or fp.y < bp.y or
			fp.y >= bp.y + body.height then
		return
	end
	local fy = fp.y - bp.y
	local k = fy .. " " .. kb
	if SH.kb_key ~= k then
		SH.kb_key = k
		view.viewPosition = magic.IntVector2(0, math.max(0, math.min(fy - 8,
				bh - h)))
	end
	-- (for a check, as it moves: pixels)
	local sc = magic.ui.scale
	local said = string.format("fp shell: typing: the field %d to %d, the " ..
			"keyboard from %d", fp.y * sc, (fp.y + f.height) * sc,
			(magic.ui.root.height - kb) * sc)
	if said ~= SH.typing_said then
		SH.typing_said = said
		log:info(said)
	end
end

-- The guide line, the crosshair, the time-lapse's clock and the chat's
-- lines (init.lua's) in the world's rect (after editor.lua's own placing,
-- M.update)
function SH.place_overlays(hud, crosshair, clock)
	local r = SH.world
	local msg = E.doc and E.doc.msg_text
	if not r then
		if SH.overlaid then
			SH.overlaid = nil
			hud:SetPosition(0, -12)
			crosshair:SetPosition(0, 0)
			if clock then
				clock:SetPosition(0, 40)
			end
			if msg then
				msg:SetPosition(10, -44)
			end
		end
		return
	end
	SH.overlaid = true
	local root = magic.ui.root
	if msg then
		msg:SetPosition(r[1] + 10, r[2] + r[4] - root.height - 44)
	end
	local dx = math.floor(r[1] + r[3] / 2 - root.width / 2)
	if S.touch then
		hud:SetFixedWidth(math.max(SH.TOUCH, r[3] - 24))
	end
	hud:SetPosition(dx, r[2] + r[4] - root.height - 12)
	crosshair:SetPosition(dx, math.floor(r[2] + r[4] / 2 - root.height / 2))
	if clock then
		clock:SetPosition(dx, r[2] + 40)
	end
end

-- Each frame, after the text size's scaling (editor.lua's M.update)
function SH.tick()
	local on = SH.on()
	local world, ui, tall, kb = SH.layout()
	SH.tall = tall
	local key = tostring(on) .. " " .. SH.mode() .. " " .. tostring(tall)
	if key ~= SH.key then
		local was = SH.key
		SH.key = key
		SH.ui, SH.laid = ui, nil
		-- The panels unfolded meanwhile ([FP_TOUCH] 2's), each its pane
		panel.no_folds = on
		SH.build()
		E.world_rect = on and world_px(world) or nil
		if on or (was and was:sub(1, 4) == "true") then
			log:info("fp shell " .. (on and "on, " .. SH.mode() ..
					(tall and ", tall" or ", wide") or "off"))
			A.refresh()
		end
	end
	SH.world = on and world or nil
	E.world_rect = on and world_px(world) or nil
	A.apply_viewport()
	if not on or not SH.win then
		SH.pane_rect = nil
		return
	end
	if SH.drag then
		drag_divider()
	end
	-- The rows are laid out for the pane's width (UI units): built again
	-- when it changes, by the scale or the divider (once let go)
	local pw = math.floor(ui[3])
	if pw ~= SH.built_w and not SH.drag then
		if SH.built_w then
			A.refresh()
		end
		SH.built_w = pw
	end
	SH.ui = ui
	-- The pane follows the activity: a dialog up (gone, the pane before
	-- it), a selection made, a tool taken
	local dlg = available("dialog")
	if dlg and not SH.was_dlg then
		SH.show("dialog")
	elseif not dlg and SH.pane == "dialog" then
		SH.back()
	end
	SH.was_dlg = dlg
	if SH.pane == "layouts" and not S.layouts_open then
		SH.back()
	end
	if S.primary ~= SH.was_primary and S.primary ~= nil then
		local e = E.doc.ents[S.primary]
		log:info("fp shell: selected " .. S.primary .. " (" ..
				tostring(e and e.type) .. ")")
		SH.show("props")
	end
	SH.was_primary = S.primary
	local tool = S.tool or false
	if SH.was_tool ~= nil and tool ~= SH.was_tool then
		if tool == "paint" then
			SH.show("palette")
		elseif tool and tool ~= "select" then
			SH.show("props")
		end
	end
	SH.was_tool = tool
	-- The windows out of the fit, and a frame after they are first seen (the
	-- text size's scaling then done) at the touch size: what is set before
	-- the scaling is scaled too. Whether one was meant to be shown is kept
	-- (props with no tool is not)
	local wins = A.wins()
	wins.shell = SH.win
	local tops = {}
	for p, b in pairs(wins) do
		local w = panel.top(b)
		tops[p] = w
		local v = w:GetVar("FpTouch")
		if v == "" then
			w:SetVar("FpTouch", "0")
			w:SetVar("FollowsRoot", "1")
			w:SetVar("FpShown", b.visible and "1" or "0")
			w.visible = false
		elseif v == "0" then
			w:SetVar("FpTouch", "1")
			if p ~= "shell" then
				touch_size(w, 0)
			end
		end
	end
	for w in pairs(SH.views) do
		local live = false
		for _, t in pairs(tops) do
			live = live or t == w
		end
		if not live then
			SH.views[w] = nil
		end
	end
	if SH.win:GetVar("FpTouch") ~= "1" then
		return
	end
	if SH.more_w and SH.more_w:GetVar("FpTouch") == "" then
		SH.more_w:SetVar("FpTouch", "0")
	elseif SH.more_w and SH.more_w:GetVar("FpTouch") == "0" then
		SH.more_w:SetVar("FpTouch", "1")
		touch_size(SH.more_w, 0)
	end
	for p, w in pairs(tops) do
		if p ~= SH.pane and p ~= "shell" and w.visible then
			w.visible = false
		end
	end
	local lk = table.concat(ui, " ") .. " " .. SH.win.width .. " " ..
			tostring(S.view == "walk") .. " " .. angle_label()
	if lk ~= SH.laid then
		SH.laid = lk
		SH.acts[4].t.text = angle_label()
		place_shell()
		SH.placed = {}
		log:info("fp shell: pixels: the world " .. px_rect(world) ..
				", the UI " .. px_rect(ui) .. ", the pane " .. px_rect(SH.pane_rect) ..
				", the keyboard " .. math.floor(kb * magic.ui.scale) ..
				", the touch size " .. math.floor(SH.TOUCH * magic.ui.scale))
	end
	if not SH.win.visible then
		SH.win.visible = true
	end
	local pr = SH.pane_rect
	local pw = tops[SH.pane]
	if pw and (pw:GetVar("FpTouch") ~= "1" or pw:GetVar("FpShown") ~= "1") then
		pw = nil
	elseif pw and SH.placed.w ~= pw then
		SH.placed.w = pw
		pw:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
		pw:SetPosition(pr[1], pr[2])
		pw:SetFixedWidth(pr[3])
		pw.maxHeight = pr[4]
		pw.clipChildren = true
		-- Under the "..." menu, over the shell
		pw.priority = -1
	end
	if pw and not pw.visible then
		pw.visible = true
	end
	local view = pw and SH.views[pw]
	if view then
		fit_view(view, pr, tall)
	end
	-- The header: its title and the view on lit (a drive's line as either
	-- changes)
	local t = SH.title_of(SH.pane) or ""
	local hk = t .. "\0" .. tostring(S.view) .. "\0" .. ui[3] .. "\0" ..
			tostring(SH.back_to())
	if SH.title_set ~= hk then
		SH.title_set = hk
		place_header(t)
		local names, lit_n = {}, "none"
		for _, e in ipairs(SH.views_b) do
			local lit = S.view == e.v
			e.t:SetColor(lit and magic.Color(1.0, 0.85, 0.3) or magic.Color(1, 1, 1))
			names[#names + 1] = e.t.text
			lit_n = lit and e.t.text or lit_n
		end
		local sc = magic.ui.scale
		local hl = string.format("fp shell: the header: \"%s\", %s, the empty " ..
				"part %d to %d at %d, lit %s", SH.shown_title,
				table.concat(names, " | "), (ui[1] + SH.gap[1]) * sc,
				(ui[1] + SH.gap[2]) * sc, (ui[2] + PAD + SH.TOUCH / 2) * sc, lit_n)
		if hl ~= SH.header_said then
			SH.header_said = hl
			log:info(hl)
		end
	end
	local e = ""
	if not pw then
		e = SH.pane == "props" and (S.tool and "Nothing to show" or
				"No tool: take one in Tools") or ""
	end
	if SH.empty.text ~= e then
		SH.empty.text = e
	end
	-- "..." in the UI half at its right, under the header, on the screen
	local c = SH.more_w
	if c and c:GetVar("FpTouch") == "1" then
		local r = magic.ui.root
		local x = math.max(0, math.min(ui[1] + ui[3] - c.width - PAD,
				r.width - c.width))
		local y = math.max(0, math.min(ui[2] + PAD + SH.TOUCH, r.height - c.height))
		if c.position.x ~= x or c.position.y ~= y then
			c:SetPosition(x, y)
		end
		if not c.visible then
			c.visible = true
			local sc = magic.ui.scale
			log:info(string.format("fp shell: the ... menu shown at %d %d %d %d " ..
					"(pixels)", x * sc, y * sc, c.width * sc, c.height * sc))
		end
	end
	local s = status_text()
	if s ~= SH.status_said then
		SH.status_said = s
		SH.status.text = s
		log:info("fp shell: status: " .. s)
	end
end

-- A press on the header's empty part (UI units; the shell window's own, no
-- target there): the divider may be dragged. One off the "..." menu closes
-- it
magic.SubscribeToEvent("MouseButtonDown", function()
	local c = SH.more_w
	if not c then
		return
	end
	local p, sc = magic.input:GetMousePosition(), magic.ui.scale
	if not panel.over({c, SH.more_b}, p.x / sc, p.y / sc) then
		drop_more()
	end
end)
magic.SubscribeToEvent("UIMouseClick", function(_, data)
	local w, g = SH.win, SH.gap
	if not (SH.on() and w and w.visible and g) or SH.more_w then
		return
	end
	local p = w.screenPosition
	local x, y = data:GetInt("X") - p.x, data:GetInt("Y") - p.y
	if x > g[1] and x < g[2] and y >= 0 and y < 2 * PAD + SH.TOUCH then
		SH.drag, SH.divider_moved = true, nil
	end
end)

-- For a check ("event fp_touch_targets <what>"): each target shown, a
-- button, a field, a dropdown or a check box, its rect in pixels; and the
-- editor's windows up
magic.SubscribeToEvent("command_seq:fp_touch_targets", function(_, data)
	local sc, out = magic.ui.scale, {}
	local KINDS = {Button = true, LineEdit = true, DropDownList = true,
		CheckBox = true}
	local function walk(el, depth)
		for i = 0, el:GetNumChildren() - 1 do
			local c = el:GetChild(i)
			local t = c and c.visible and c:GetTypeName()
			if t and KINDS[t] then
				local p, label = c.screenPosition, ""
				local l = t == "LineEdit" and c or c:GetNumChildren() > 0 and
						c:GetChild(0)
				if l and (l:GetTypeName() == "Text" or t == "LineEdit") then
					label = tostring(l.text):gsub("[\n\"]", " "):sub(1, 24)
				end
				out[#out + 1] = string.format("%s \"%s\" %d %d %d %d", t, label,
						p.x * sc, p.y * sc, c.width * sc, c.height * sc)
			elseif t and t ~= "ScrollBar" and depth < 40 then
				walk(c, depth + 1)
			end
		end
	end
	walk(magic.ui.root, 0)
	local what = data:GetString("Param")
	log:info("fp shell: touch targets (" .. what .. "): " ..
			table.concat(out, "; "))
	local ws = A.wins()
	ws.more = SH.more_w
	local up = {}
	for _, p in ipairs({"tools", "palette", "props", "layouts", "dialog", "more"}) do
		local w = ws[p] and panel.top(ws[p])
		if w and w.visible then
			local q = w.screenPosition
			up[#up + 1] = string.format("%s %d %d %d %d", p, q.x * sc, q.y * sc,
					w.width * sc, w.height * sc)
		end
	end
	log:info("fp shell: the windows at " .. table.concat(up, ", ") .. " (" ..
			what .. ")")
end)
end
-- vim: set noet ts=4 sw=4:
