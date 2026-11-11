-- Buildat: builtin/kit/client_lua/shell.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_PHONE_EDITING] stage 1, **the touch mode's split screen**: the
-- editor's own panels (editor.lua's palette, inspector and bar) as one pane
-- at a time in a UI half beside the world, which is drawn in a viewport of
-- its own rect. A second layout over the same editor, not another editor.
-- The client's preference kit_ui_mode (the game settings' "Editor UI
-- mode") picks it: 0 the device's (touch on a touchscreen), 1 desktop (the
-- floating windows), 2 touch with the UI half on the right in landscape, 3
-- on the left. In edit mode only (stage 4: its Signals and HUD views too);
-- play is as on the desktop.
--   - The screen's aspect picks the split: tall, the world above and the UI
--     half below (45 % / 55 %); wide, side by side (50 %), the UI half on
--     the handed side. The header dragged (its title or its empty part)
--     moves the divider, 0.2-0.8, remembered on this device (the app
--     preference kit_ui_split).
--   - The UI half: a header ("< <the pane's title>" for Back, the views
--     Walk | 3D | 2D with the one on lit, "..."; stage 4b), the
--     pane, Undo, Delete and Cancel, and a status line (Running or Ended,
--     the builders, the last refusal) in the corner boxes' place. The panes:
--     the palette (the left panel: Place and the tools' tabs), the
--     inspector and Tools (the bar). "..." opens any of them and the rest:
--     the builders' box, the Log, the Signals and HUD views, the app's menu.
--     The pane follows what is done: the palette as a placing is armed, the
--     inspector as something is selected; Back walks the panes shown before.
--   - A fixed scale: its windows do not count in the client's UI fit
--     (FollowsRoot), and its targets are at least SH.TOUCH UI pixels.
--   - Tall, a field typed in with the on-screen keyboard up: the UI half
--     moves up by the keyboard's height, unresized, and the world loses as
--     much; with a keyboard taller than the world, no world and the UI half
--     between the top and the keyboard (the inspector scrolls the field into
--     view, fit_inspector).
--   - Over the world only the edit's own: the selection, the gizmo, the
--     ports, the placing's ghost and the tool's hint in one line
--     (editor_input.lua's draw_guide); the Walk view's HUD laid out in the
--     world's rect (kit.hud_area). builtin/accounts' Server button is
--     hidden meanwhile (the pause menu's settings have its window).
-- Stage 3, the world's gestures (editor_input.lua), in the world's rect
-- (editor.lua's screen_size): the tool decides what one finger does, two
-- fingers move the view (pan and pinch; in 3D orbit and pinch). One finger:
--   - select (no tool): a tap selects (an entity the finger's half touch
--     size away too), on nothing deselects; a drag on the selection moves
--     it, on a knob turns it, on nothing pans; under Select+ a tap adds or
--     takes out and a drag on nothing boxes (adding);
--   - placing: a tap places (the view then panned to keep it off the
--     world's edge, NT.reveal), a drag pans;
--   - voxels: in each view as Walk's and play's, a tap digs and a finger
--     held places;
--   - Box: a tap is a corner, a face's handle dragged moves the face;
--   - terrain: a drag is a stroke (2D, 3D), as before.
-- A finger held still is the right click (the entity's menu), as before.
-- Walk (stage 4b; the touch mode starts in 3D): controls.lua's stick at the
-- world's lower left (0.45 of its width, 0.45 of its height) walks, its
-- touch bar (Jump, a movement's touch_buttons) at the world's lower right;
-- a drag begun on the selected entity (the finger's half touch size
-- round it too) or its knob moves or turns it, any other drag turns the
-- eye; a tap the tool's, a hold places (voxels) or the menu; no zoom. By
-- mouse Walk is the desktop mode's (a click into the crosshair, the right
-- drag turns).
-- The mouse: the left button a finger (a click a tap, a drag one finger's),
-- the right drag the two fingers' (the plan pans, 3D orbits, Walk turns),
-- the middle dragged a pinch (up zooms in), the wheel zooms; no crosshair.
-- The ports are hidden (beside a finger-sized entity they took its taps): a
-- link is begun by the inspector's Link <output>, and a tap on an entity of
-- one input ends it (of more, it is selected: the inspector's To buttons).
-- The foot's buttons: Select+, Turn - and + (Z, X), Up and Down (PageUp,
-- PageDown), Duplicate, Undo, Delete, Cancel, in rows as they fit.
-- Stage 4, the rest as panes, each opened from "...":
--   - a dialog (W.dialog: a new scene, a voxel type, a prefab, a sound's
--     name) is the dialog pane while it is up, its buttons above its form,
--     which scrolls (NT.dialog in editor.lua); Scenes lists the scenes (a
--     tap switches) with New scene...; Builders and the Log are the
--     builders' box and the selected entity's log;
--   - the Signals view: its entities, the selected one's links (Add link as
--     steps: an output, a target, an input) and the inspector as panes, its
--     3D view in the world's rect (signals.lua); the HUD view: the HUD laid
--     out in the world's rect, the selected element's panel the HUD pane;
--     the blip designer in the UI half, its code in the world's rect;
--   - Server (an app's kit.editor{server = fn}: Workbench's accounts'
--     Server window) and the app's Menu;
--   - Tools and the panes above scroll (SH.scroll); with a wide screen's
--     keyboard up a pane's view ends above it, and the field typed in is
--     scrolled into it;
--   - Turn - and + at the foot while a prefab or a paste is being placed;
--   - Kit's Fullscreen (the preference kit_fullscreen, the web page's,
--     set_web_fullscreen("always")); the screen's orientation is the
--     client's own preference, held while the page is fullscreen.
-- simplified: a world of no
-- height is drawn a pixel high under the UI half (a rect of nothing is the
-- whole screen to Urho3D). Stage 3's: no two-finger twist (the plan does
-- not turn); the ports hidden in each view, not only the plan; Walk's two
-- fingers each turn the eye (the app's own). Stage 4's: an app with
-- builtin/accounts' Server button and no kit.editor{server} has no Server
-- in "..." (the button stays hidden; the app's menu has its window); the
-- Builders and Log panes clip a line wider than the pane; the "..." menu
-- goes in columns where it is taller than the screen
return function(A)
local S, W, E, NT, M, O = A.S, A.W, A.E, A.NT, A.M, A.O
local magic, log, send, window, drop = A.magic, A.log, A.send, A.window, A.drop
local button, text, row = A.button, A.text, A.row
-- views: SH.scroll's, by their window ({view, fitted}; the sandbox has no
-- weak tables: those of windows gone are dropped as one is added)
local SH = {pane = "palette", stack = {}, views = {}}
NT.sh = SH

-- A target's least side, UI pixels (the user's 48, 2026-11-11)
SH.TOUCH = 48
local PAD = 6
-- The panes' windows
local PANE_W = {palette = "palette", inspector = "inspector", tools = "bar",
	dialog = "dialog", scenes = "scenes", people = "people", log = "log",
	sg_list = "sg_list", sg_links = "sg_links", hud = "hud_panel"}
local TITLES = {inspector = "Inspector", tools = "Tools", scenes = "Scenes",
	people = "Builders", log = "Log", sg_list = "Signals", sg_links = "Links",
	hud = "HUD element"}
-- The Signals view's own: placed by its layout (signals.lua)
local SG_PANES = {sg_list = true, sg_links = true, inspector = true}

S.ui_mode = (buildat.declare_preference and
		buildat.declare_preference("kit_ui_mode", function(v)
			S.ui_mode = v
			log:info("kit editor: UI mode " .. SH.mode())
		end)) or 0

-- The world's share of a tall screen's height, the UI half's of a wide one's
-- width: this device's (an app preference, not this game's storage)
do
	local t, w = tostring(buildat.get_app_preference and
			buildat.get_app_preference("kit_ui_split") or ""):match(
			"^([%d.]+) ([%d.]+)")
	SH.split = {tall = tonumber(t) or 0.45, wide = tonumber(w) or 0.5}
end

-- Kit's Fullscreen: the web page's whatever its address bar preference is.
-- Off, the page is left as the app has it (never set by Kit unless it was
-- on). A check's run has it off (util/web_drive.js pins it)
function SH.fullscreen(v)
	S.fullscreen = v == true
	if S.fullscreen or SH.fs_set then
		buildat.set_web_fullscreen(S.fullscreen and "always" or false)
		SH.fs_set = S.fullscreen
	end
	log:info("kit editor: fullscreen " .. (S.fullscreen and "on" or "off"))
end
SH.fullscreen(buildat.declare_preference and
		buildat.declare_preference("kit_fullscreen", SH.fullscreen))

function SH.mode()
	local m = tonumber(S.ui_mode) or 0
	if m == 0 then
		return S.touch and "rh" or "desktop"
	end
	return m == 1 and "desktop" or m == 3 and "lh" or "rh"
end

function SH.on()
	return E.editing == true and SH.mode() ~= "desktop"
end

-- Whether pane p has something to show in this view
local function available(p)
	if p == "dialog" then
		return W.dialog ~= nil
	elseif p == "sg_list" or p == "sg_links" then
		return NT.sig()
	elseif p == "hud" then
		return S.view == "hud"
	elseif p == "palette" then
		return not NT.world_off()
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

-- The width a pane's window has (UI units), before the shell is placed too
function SH.pane_w()
	local _, ui = SH.layout()
	return ui[3] - 2 * PAD
end

-- The world's rect in pixels {x, y, w, h} (w, h at least 1), nil with the
-- shell off: what the editor's rays and the viewport go by
function SH.world_px()
	if not SH.world then
		return nil
	end
	local sc, r = magic.ui.scale, SH.world
	return {math.floor(r[1] * sc + 0.5), math.floor(r[2] * sc + 0.5),
		math.max(1, math.floor(r[3] * sc + 0.5)),
		math.max(1, math.floor(r[4] * sc + 0.5))}
end

-- (controls.lua's: its touch bar at this rect's lower right, walking)
M.touch_world = SH.world_px

function SH.show(p)
	SH.placed = {}
	if p == SH.pane then
		return
	end
	SH.stack[#SH.stack + 1] = SH.pane
	if #SH.stack > 16 then
		table.remove(SH.stack, 1)
	end
	SH.pane = p
	log:info("kit editor: touch shell: the " .. p .. " pane")
	S.bar_key = nil
	A.refresh()
end

-- The pane before, past those with nothing to show now (a dialog closed)
function SH.back()
	local p
	repeat
		p = table.remove(SH.stack)
	until not p or (p ~= SH.pane and available(p))
	if not p then
		p = S.primary and "inspector" or available("palette") and "palette" or
				"tools"
		if p == SH.pane then
			return
		end
	end
	SH.pane, SH.placed = p, {}
	log:info("kit editor: touch shell: back to the " .. p .. " pane")
	S.bar_key = nil
	A.refresh()
end

-- A view that scrolls in a pane's window, after the window's own rows (the
-- shell sizes it each frame, tick): its body, where the rest goes. Off the
-- touch mode the window itself
function SH.scroll(w)
	if not SH.on() then
		return w
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
	local live = {}
	for _, x in pairs(W) do
		live[x] = true
	end
	for k in pairs(SH.views) do
		if not live[k] then
			SH.views[k] = nil
		end
	end
	SH.views[w] = {view = view}
	return body
end

-- The Scenes pane: each scene (a tap goes there), and New scene...
function SH.scenes()
	drop("scenes")
	if not (SH.on() and SH.pane == "scenes") then
		return
	end
	local w = window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	W.scenes = w
	w:SetName("kit: scenes")
	local body = SH.scroll(w)
	local st = E.state or {}
	local cur = st.scene or ""
	for _, n in ipairs(st.scenes or {}) do
		button(body, n == cur and n .. " (here)" or n, function()
			if n ~= cur then
				M.switch_scene(n)
			end
		end, n == cur):SetName("scene " .. n)
	end
	if #(st.scenes or {}) == 0 then
		text(body, "One scene", A.DIM)
	end
	if st.can_make_scenes then
		button(body, "New scene...", function()
			M.scene_dialog()
		end):SetName("scenes new")
	end
end

-- "...": the panes this view has, the views, the Server window, the app's
-- menu. A window as NT.menu's (W.ctx), in columns where one is taller than
-- the screen; kept on it in the UI half each frame (tick: its size changes
-- with the text size's scaling and the touch size)
function SH.more()
	local e = {}
	local function pane(p, label)
		if available(p) then
			e[#e + 1] = {label, function() SH.show(p) end}
		end
	end
	pane("sg_list", "Signals: entities")
	pane("sg_links", "Signals: links")
	pane("hud", "HUD element")
	pane("palette", "Palette")
	pane("inspector", "Inspector")
	pane("tools", "Tools")
	pane("dialog", SH.dialog_title or "Dialog")
	pane("scenes", "Scenes")
	pane("people", "Builders")
	pane("log", "Log")
	if NT.world_off() then
		e[#e + 1] = {"World view", function()
			A.set_view(S.view == "hud" and S.before_hud or
					S.before_signals or "walk")
		end}
	end
	if not NT.sig() then
		e[#e + 1] = {"Signals view", function() A.set_view("signals") end}
	end
	if S.view ~= "hud" then
		e[#e + 1] = {"HUD view", function() A.set_view("hud") end}
	end
	if O.server then
		e[#e + 1] = {"Server", function() O.server() end}
	end
	if O.menu then
		e[#e + 1] = {"Menu", function() O.menu() end}
	end
	drop("ctx")
	local w = window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	W.ctx = w
	w.priority = 10
	w.visible = true
	local per = math.max(1, math.floor((magic.ui.root.height - 2 * PAD - 12) /
			(SH.TOUCH + 4)))
	local cols = math.ceil(#e / per)
	local r
	local names = {}
	for i, en in ipairs(e) do
		if (i - 1) % cols == 0 then
			r = row(w)
		end
		-- (named "menu <label>" as NT.menu's, for a drive)
		button(r, en[1], function()
			drop("ctx")
			en[2]()
		end):SetName("menu " .. en[1])
		names[i] = en[1]
	end
	SH.more_w = w
	log:info("kit editor: touch shell: the ... menu, " .. #e .. " in " .. cols ..
			(cols == 1 and " column: " or " columns: ") .. table.concat(names, ", "))
end

-- The shell's window: the UI half's background, header, foot and status
function SH.build()
	drop("shell")
	SH.placed = {}
	if not SH.on() then
		return
	end
	local w = window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	W.shell = w
	SH.laid, SH.gap = nil, nil
	w:SetName("kit: touch shell")
	w:SetLayout(magic.LM_FREE, 0, magic.IntRect(0, 0, 0, 0))
	-- Under the panes (-1), opaque: the world is not under it
	w.priority = -2
	w.opacity = 1
	w.clipChildren = true
	-- Stage 4b: the header. Back carries the pane's title; a press on it or
	-- on the row's empty part (the window's own, not a target) may drag the
	-- divider, and a drag is then no Back
	SH.back_b, SH.title = button(w, "<", function()
		if not SH.divider_moved then
			SH.back()
		end
	end)
	SH.back_b:SetName("shell back")
	magic.SubscribeToEvent(SH.back_b, "Pressed", function()
		SH.drag, SH.divider_moved = true, nil
	end)
	SH.views_b = {}
	for _, v in ipairs({{"walk", "Walk"}, {"3d", "3D"}, {"2d", "2D"}}) do
		local b, t = button(w, v[2], function() A.set_view(v[1]) end)
		b:SetName("shell view " .. v[1])
		SH.views_b[#SH.views_b + 1] = {v = v[1], b = b, t = t}
	end
	SH.header_said = nil
	SH.more_b = button(w, "...", SH.more)
	SH.more_b:SetName("shell more")
	SH.empty = text(w, "")
	-- [KIT_PHONE_EDITING] stage 3: the world's mouse- and keyboard-only work
	-- (Select more, Z/X, PageUp/PageDown, Ctrl+D) as buttons
	local more_b, more_t = button(w, "Select+", function()
		SH.multi = not SH.multi
		log:info("kit editor: touch shell: select more " ..
				(SH.multi and "on" or "off"))
	end)
	SH.multi_t, SH.multi_shown = more_t, 0
	SH.acts = {more_b,
		button(w, "Turn -", function() NT.turn_step(-1) end),
		button(w, "Turn +", function() NT.turn_step(1) end),
		button(w, "Up", function() NT.raise(1) end),
		button(w, "Down", function() NT.raise(-1) end),
		button(w, "Duplicate", function() NT.duplicate() end),
		button(w, "Undo", function() send({op = "undo"}) end),
		button(w, "Delete", function() M.delete_selected() end),
		(button(w, "Cancel", function() M.escape() end))}
	-- (by name for a drive: "Up" is not the only one)
	for i, n in ipairs({"select more", "turn -", "turn +", "up", "down",
			"duplicate", "undo", "delete", "cancel"}) do
		SH.acts[i]:SetName("shell " .. n)
	end
	SH.status = text(w, "")
	SH.status_said = nil
end

-- Whether what is being placed turns (NT.turn_step's): a prefab, a paste
function SH.turning()
	local p = S.placing
	return p ~= nil and (p.prefab ~= nil or p.clipboard ~= nil)
end

-- Its parts where the UI half is now (after the text size's scaling)
local function place_shell()
	local u, w, T = SH.ui, W.shell, SH.TOUCH
	w:SetPosition(u[1], u[2])
	w:SetFixedSize(u[3], u[4])
	SH.title_set = nil
	local sy = u[4] - PAD - SH.status.height
	SH.status:SetPosition(PAD, sy)
	-- The buttons in rows as they fit (each its label's width, at least the
	-- touch size), each row stretched across. The world's (the first six)
	-- not in the palette's pane: a landscape phone's had room for one row of
	-- its list; but Turn - and + while a prefab or a paste is placed (stage
	-- 4). None of them in the Signals and HUD views (no world to edit)
	local room, rows = u[3] - 2 * PAD, {{used = -4}}
	local turning = SH.turning()
	for i, b in ipairs(SH.acts) do
		local bw, r = math.max(T, b:GetChild(0).width + 16), rows[#rows]
		b.visible = i > 6 or (not NT.world_off() and (SH.pane ~= "palette" or
				(turning and (i == 2 or i == 3))))
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

-- The header (stage 4b): "< <title>" at the left, as wide as its text,
-- the title cut to leave the rest their room; the row's empty part (gap)
-- after it; Walk | 3D | 2D and "..." at the right
-- simplified: a UI half under about 290 UI px across (the divider dragged
-- to 0.2 in landscape) has the view buttons narrower than the touch size,
-- not in a second row
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
	SH.title.text = "< " .. t
	while SH.title.width + 16 > most and n > 0 do
		n = n - 1
		SH.title.text = "< " .. t:sub(1, n) .. ".."
	end
	if SH.title.width + 16 > most then
		SH.title.text = "<"
	end
	local bw = math.max(T, math.min(most, SH.title.width + 16))
	SH.back_b:SetFixedSize(bw, T)
	SH.back_b:SetPosition(PAD, PAD)
	-- (the empty part, UI units in the window: a press there drags the
	-- divider, UIMouseClick below)
	SH.gap = {PAD + bw, x}
end

-- Each target in a window at the touch size: a button, a field, a dropdown
-- at least SH.TOUCH high (a button as wide), a check box SH.TOUCH square
-- simplified: once a window (its var KitTouch), so a row added to a window
-- built already keeps its size (the palette's filter only hides rows)
local function touch_size(el, depth)
	local T = SH.TOUCH
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
		elseif c and t ~= "ScrollBar" and t ~= "Text" and depth < 40 then
			touch_size(c, depth + 1)
		end
	end
end

function SH.touch_size(el)
	touch_size(el, 0)
end

local function status_text()
	local ses = E.session or {}
	local s = ses.kind == "bench" and "Prefab" or E.persistent and
			"Persistent" or E.running and "Running" or "Ended"
	local n = #(E.builders or {})
	s = s .. " · " .. n .. (n == 1 and " builder" or " builders")
	if (E.status or "") ~= "" then
		s = s .. " · " .. E.status
	end
	return s
end

local function title()
	if SH.pane == "palette" then
		return NT.tab()
	end
	return TITLES[SH.pane]
end

-- The divider dragged by the header (its title or its empty part): by as
-- much as the pointer moved since it was pressed (a finger is the left
-- button too), once that is a quarter of the touch size; let go, kept
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
			buildat.set_app_preference("kit_ui_split", string.format("%.3f %.3f",
					SH.split.tall, SH.split.wide))
		end
		log:info(string.format("kit editor: touch shell: the split %.2f %.2f",
				SH.split.tall, SH.split.wide))
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

-- [KIT_PHONE_EDITING] The Walk view's HUD in the world's rect, as the
-- Signals view's in its viewport (ui.lua's hud_box); the HUD view's too
do
	local sg_area = M.hud_area
	SH.area = {}
	function M.hud_area()
		local a = sg_area and sg_area()
		if a or not (SH.world and (S.view == "walk" or S.view == "hud")) then
			return a
		end
		local w, b = SH.world, SH.area
		b.x, b.y, b.w, b.h, b.node = w[1], w[2], w[3], math.max(1, w[4]), O.camera
		b.cam = O.camera and O.camera:GetComponent("Camera")
		return b
	end
end

-- The rects in pixels, for a check: "x y w h"
local function px_rect(r)
	local sc = magic.ui.scale
	return string.format("%d %d %d %d", r[1] * sc, r[2] * sc, r[3] * sc, r[4] * sc)
end

-- A pane's view (SH.scroll) in the pane: as tall as its body, at most to
-- the pane's foot and, with a wide screen's keyboard up, to above it; its
-- body the view's width. The field typed in scrolled into it once (a
-- finger's own scroll after is left alone)
function SH.fit_view(pw, rec, pr, tall)
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
		-- A dialog's buttons a row of the touch size: a shorter view's room
		-- went to them, under the keyboard
		local br = pw:GetChild("dialog buttons")
		if br then
			br:SetFixedHeight(SH.TOUCH)
		end
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
	-- For a check: the field, the dialog's buttons and the keyboard (pixels)
	local br = SH.pane == "dialog" and pw:GetChild("dialog buttons")
	if br then
		local sc = magic.ui.scale
		local line = string.format("kit editor: touch shell: typing in the " ..
				"dialog %s: the field %d to %d, its buttons %d to %d, the keyboard " ..
				"from %d (pixels)", tostring(SH.dialog_title), fp.y * sc,
				(fp.y + f.height) * sc,
				br.screenPosition.y * sc, (br.screenPosition.y + br.height) * sc,
				(magic.ui.root.height - kb) * sc)
		if line ~= SH.typing_said then
			SH.typing_said = line
			log:info(line)
		end
	end
end

-- Each frame, after the text size's scaling (editor_input.lua's Update)
function SH.tick()
	local on = SH.on()
	local world, ui, tall, kb = SH.layout()
	SH.tall = tall
	local key = tostring(on) .. " " .. SH.mode() .. " " .. tostring(tall)
	if key ~= SH.key then
		local was = SH.key
		SH.key = key
		SH.world, SH.ui, SH.laid = on and world or nil, ui, nil
		SH.build()
		-- builtin/accounts' Server button (the top right: the world's, or
		-- the "..." under it) away meanwhile; the app's menu has its window
		local sb = magic.ui.root:GetChild("accounts: server button")
		if sb and on and sb.visible then
			sb.visible, SH.server_hidden = false, true
		elseif sb and not on and SH.server_hidden then
			sb.visible, SH.server_hidden = true, nil
		end
		if was then
			log:info("kit editor: touch shell " .. (on and "on, " ..
					SH.mode() .. (tall and ", tall" or ", wide") or "off"))
			S.bar_key = nil
			A.refresh()
		end
	end
	SH.world = on and world or nil
	A.apply_viewport()
	if not on or not W.shell then
		SH.pane_rect = nil
		return
	end
	if SH.drag then
		drag_divider()
	end
	SH.ui = ui
	-- Into a view of its own panes (Signals, HUD) and out: laid out again
	local sig = NT.sig()
	if S.view ~= SH.view then
		local was = SH.view
		SH.view, SH.laid, SH.placed = S.view, nil, {}
		if sig then
			SH.show(S.primary and "sg_links" or "sg_list")
		elseif S.view == "hud" then
			SH.show("hud")
		elseif was and not available(SH.pane) then
			SH.show(S.primary and "inspector" or "palette")
		end
	end
	-- The pane follows the activity: a placing armed, a selection made, a
	-- dialog up (gone, the pane before it)
	local placing = S.placing ~= nil
	if placing and not SH.was_placing and available("palette") then
		SH.show("palette")
	end
	SH.was_placing = placing
	if S.primary ~= SH.was_primary and S.primary ~= nil then
		SH.show(sig and "sg_links" or S.view == "hud" and "hud" or "inspector")
	end
	SH.was_primary = S.primary
	local dw = W.dialog
	if dw and dw ~= SH.dialog_w then
		SH.show("dialog")
	end
	SH.dialog_w = dw
	if not dw and SH.pane == "dialog" then
		SH.back()
	end
	-- The windows out of the fit, and a frame after they are first seen (the
	-- text size's scaling then done) at the touch size and in their place:
	-- what is set before the scaling is scaled too
	for k, w in pairs(W) do
		local v = w:GetVar("KitTouch")
		if v == "" then
			w:SetVar("KitTouch", "0")
			w:SetVar("FollowsRoot", "1")
			if k == "shell" or (k == PANE_W[SH.pane] and
					not (sig and SG_PANES[SH.pane])) then
				w.visible = false
			end
		elseif v == "0" then
			w:SetVar("KitTouch", "1")
			if k ~= "shell" then
				touch_size(w, 0)
			end
		end
	end
	if W.shell:GetVar("KitTouch") ~= "1" then
		return
	end
	-- The other panes' windows away (the Signals view's own columns are its
	-- layout's, signals.lua)
	for p, k in pairs(PANE_W) do
		local w = W[k]
		if w and p ~= SH.pane and not (sig and SG_PANES[p]) and w.visible then
			w.visible = false
		end
	end
	local lk = table.concat(ui, " ") .. " " .. W.shell.width .. " " ..
			tostring(SH.pane == "palette") .. " " .. tostring(SH.turning()) ..
			" " .. tostring(NT.world_off())
	if lk ~= SH.laid then
		SH.laid = lk
		place_shell()
		SH.placed = {}
		log:info("kit editor: touch shell: pixels: the world " .. px_rect(world) ..
				", the UI " .. px_rect(ui) .. ", the pane " .. px_rect(SH.pane_rect) ..
				", the keyboard " .. math.floor(kb * magic.ui.scale) ..
				", the touch size " .. math.floor(SH.TOUCH * magic.ui.scale))
	end
	-- (the HUD view hides every window as it comes, editor.lua's set_view)
	if not W.shell.visible then
		W.shell.visible = true
	end
	local pr = SH.pane_rect
	local pw = W[PANE_W[SH.pane]]
	if pw and (pw:GetVar("KitTouch") ~= "1" or (sig and SG_PANES[SH.pane])) then
		pw = nil
	elseif pw and SH.placed.w ~= pw then
		SH.placed.w = pw
		pw:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
		pw:SetPosition(pr[1], pr[2])
		pw:SetFixedWidth(pr[3])
		pw.maxHeight = pr[4]
		pw.clipChildren = true
	end
	if pw and not pw.visible then
		pw.visible = true
	end
	local view = pw and SH.views[pw]
	if view then
		SH.fit_view(pw, view, pr, tall)
	end
	-- The header: its title and the view on lit (a drive's line as either
	-- changes)
	local t = title() or ""
	local hk = t .. "\0" .. tostring(S.view) .. "\0" .. ui[3]
	if SH.title_set ~= hk then
		SH.title_set = hk
		place_header(t)
		local names, on = {}, "none"
		for _, e in ipairs(SH.views_b) do
			local lit = S.view == e.v
			e.t:SetColor(lit and magic.Color(1.0, 0.85, 0.3) or magic.Color(1, 1, 1))
			names[#names + 1] = e.t.text
			on = lit and e.t.text or on
		end
		local sc = magic.ui.scale
		local hl = string.format("kit editor: touch shell: the header: \"%s\", " ..
				"%s, the empty part %d to %d at %d, lit %s", SH.title.text,
				table.concat(names, " | "), (ui[1] + SH.gap[1]) * sc,
				(ui[1] + SH.gap[2]) * sc, (ui[2] + PAD + SH.TOUCH / 2) * sc, on)
		if hl ~= SH.header_said then
			SH.header_said = hl
			log:info(hl)
		end
	end
	local e = ""
	if not W[PANE_W[SH.pane]] then
		e = SH.pane == "inspector" and "Nothing selected: tap an entity" or
				SH.pane == "hud" and "Tap a HUD element in the world" or
				SH.pane == "log" and "No log lines of the selected entity" or ""
	end
	if SH.empty.text ~= e then
		SH.empty.text = e
	end
	-- "..." in the UI half at its right, under the header, on the screen
	local c = W.ctx
	if c and c == SH.more_w and c:GetVar("KitTouch") == "1" then
		local r = magic.ui.root
		local x = math.max(0, math.min(ui[1] + ui[3] - c.width - PAD,
				r.width - c.width))
		local y = math.max(0, math.min(ui[2] + PAD + SH.TOUCH, r.height - c.height))
		if c.position.x ~= x or c.position.y ~= y then
			c:SetPosition(x, y)
		end
	end
	-- Select+ on in the bar buttons' yellow
	if SH.multi ~= SH.multi_shown then
		SH.multi_shown = SH.multi
		SH.multi_t:SetColor(SH.multi and magic.Color(1.0, 0.85, 0.3) or
				magic.Color(1, 1, 1))
	end
	local s = status_text()
	if s ~= SH.status_said then
		SH.status_said = s
		SH.status.text = s
		log:info("kit editor: touch shell: status: " .. s)
	end
end

-- A press on the header's empty part (UI units; the window's own, no
-- target there): the divider may be dragged
magic.SubscribeToEvent("UIMouseClick", function(_, data)
	local w, g = W.shell, SH.gap
	if not (SH.on() and w and w.visible and g) or W.ctx then
		return
	end
	local p = w.screenPosition
	local x, y = data:GetInt("X") - p.x, data:GetInt("Y") - p.y
	if x > g[1] and x < g[2] and y >= 0 and y < 2 * PAD + SH.TOUCH then
		SH.drag, SH.divider_moved = true, nil
	end
end)

-- For a check ("event kit_touch_targets <what>"): each target shown, a
-- button, a field, a dropdown or a check box, its rect in pixels
magic.SubscribeToEvent("command_seq:kit_touch_targets", function(_, data)
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
	log:info("kit editor: touch targets (" .. data:GetString("Param") .. "): " ..
			table.concat(out, "; "))
end)
end
-- vim: set noet ts=4 sw=4:
