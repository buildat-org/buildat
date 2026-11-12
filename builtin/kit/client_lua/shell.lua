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
--     the handed side. The header dragged (its empty part) moves the divider, 0.2-0.8, remembered on this device (the app
--     preference kit_ui_split).
--   - The UI half: a header ("< <the pane's title>" for Back, the title
--     alone where Back goes nowhere; a dropdown of the views, Walk, 3D, 2D,
--     Signals, HUD, then the scenes, a pick going there in this view, and
--     New scene...; Tools. The user's of 2026-11-12, for stage 4b's
--     Walk | 3D | 2D and "..."), the pane, the foot's buttons under the
--     palette and the inspector, and a status line (Running or Ended, the
--     builders, the last refusal) in the corner boxes' place. The panes:
--     the palette (the left panel: Place and the tools' tabs), the
--     inspector (the selected entity's log at its foot) and Tools (the bar:
--     the Server window and the app's menu first, the builders' box last).
--     The pane follows what is done: the palette as a placing is armed, the
--     inspector as something is selected (the placing ended), a dialog
--     while it is up; Back walks the panes shown before, to the view's first
--     (the palette, the Signals view's entities, the HUD view's element).
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
-- PageDown), Duplicate, Undo, Delete, Cancel, those that apply now
-- (foot_shown), in rows as they fit; none while the keyboard is up.
-- Stage 4, the rest as panes:
--   - a dialog (W.dialog: a new scene, a voxel type, a prefab, a sound's
--     name) is the dialog pane while it is up, its buttons above its form,
--     which scrolls (NT.dialog in editor.lua); another pane picked gives
--     it up;
--   - the Signals view: its entities, the inspector (a selection's) and the
--     selected one's links (its Links; Add link as steps: an output, a
--     target, an input) as panes, its
--     3D view in the world's rect (signals.lua); the HUD view: the HUD laid
--     out in the world's rect, the selected element's panel the HUD pane;
--     the blip designer in the UI half, its code in the world's rect;
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
-- in Tools (the button stays hidden; the app's menu has its window); the
-- builders' box and the log clip a line wider than the pane
return function(A)
local S, W, E, NT, M, O = A.S, A.W, A.E, A.NT, A.M, A.O
local magic, log, send, window, drop = A.magic, A.log, A.send, A.window, A.drop
local button, text, row = A.button, A.text, A.row
-- views: SH.scroll's, by their window ({view, fitted}; the sandbox has no
-- weak tables: those of windows gone are dropped as one is added)
local SH = {pane = "palette", stack = {}, views = {}}
NT.sh = SH

-- A target's least side, UI pixels: the user's 48 of 2026-11-11, then 32
-- after the phone test of 2026-11-12 (a pane showing more at once over a
-- comfortable finger: about 33 CSS px on a phone)
SH.TOUCH = 32
local PAD = 4
-- The panes' windows
local PANE_W = {palette = "palette", inspector = "inspector", tools = "bar",
	dialog = "dialog", sg_list = "sg_list", sg_links = "sg_links",
	hud = "hud_panel"}
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

-- The view's first pane, where Back ends: the palette, the Signals view's
-- entities, the HUD view's element
local function home()
	return NT.sig() and "sg_list" or S.view == "hud" and "hud" or "palette"
end

-- Where Back goes now (SH.back's), nil where it would do nothing
function SH.back_to()
	for i = #SH.stack, 1, -1 do
		local p = SH.stack[i]
		if p ~= SH.pane and available(p) then
			return p
		end
	end
	return home() ~= SH.pane and home() or nil
end

-- The pane before, past those with nothing to show now (a dialog closed)
function SH.back()
	local p
	repeat
		p = table.remove(SH.stack)
	until not p or (p ~= SH.pane and available(p))
	if not p then
		p = home()
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

-- The header's dropdown's choices ({label, value}; the user's of
-- 2026-11-12, for the views' buttons, "..."'s views and the Scenes pane):
-- the views, then the scenes (a pick goes there, the view kept) and New
-- scene...; the view it is in "<view> · <scene>" where there are scenes
-- to tell apart
local function view_choices()
	local st, ses = E.state or {}, E.session or {}
	local scenes = ses.kind ~= "bench" and (#(st.scenes or {}) > 1 or
			st.can_make_scenes) and st.scenes or nil
	local cur = st.scene or ""
	local c = {}
	for _, v in ipairs({"walk", "3d", "2d", "signals", "hud"}) do
		local l = A.VIEW_NAMES[v]
		c[#c + 1] = {v == S.view and scenes and cur ~= "" and l .. " · " .. cur or
				l, v}
	end
	for _, n in ipairs(scenes or {}) do
		c[#c + 1] = {"Scene: " .. n, "\1" .. n}
	end
	if ses.kind ~= "bench" and st.can_make_scenes then
		c[#c + 1] = {"New scene...", "\0new"}
	end
	return c
end

local function pick_view(v)
	-- (made again: a pick of a scene left it showing that)
	SH.view_key = nil
	if v == "\0new" then
		M.scene_dialog()
	elseif v:sub(1, 1) == "\1" then
		if v:sub(2) ~= ((E.state or {}).scene or "") then
			M.switch_scene(v:sub(2))
		end
	else
		A.set_view(v)
	end
end

-- The shell's window: the UI half's background, header, foot and status
function SH.build()
	drop("shell")
	drop("shell_views")
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
	-- (not raised over the panes by a tap on its buttons)
	w.bringToFront = false
	-- Stage 4b: the header. Back carries the pane's title; a press on it or
	-- on the row's empty part (the window's own, not a target) may drag the
	-- divider, and a drag is then no Back. Then the views' dropdown (tick
	-- makes it) and Tools (the user's of 2026-11-12, for "...")
	SH.back_b, SH.title = button(w, "<", function()
		if not SH.divider_moved then
			SH.back()
		end
	end)
	SH.back_b:SetName("shell back")
	-- (the title alone, no "<", where Back has nowhere to go)
	SH.label = text(w, "")
	magic.SubscribeToEvent(SH.back_b, "Pressed", function()
		SH.drag, SH.divider_moved = true, nil
	end)
	-- The views' dropdown in an element of its own, not the shell's: its
	-- popup, modal, takes the dropdown's top-level element along over the
	-- rest, and the shell (opaque) hid the pane meanwhile
	local vb = magic.ui.root:CreateChild("UIElement")
	W.shell_views = vb
	vb:SetName("kit: touch shell views")
	vb.priority = -1
	SH.view_d, SH.view_key, SH.header_said = nil, nil, nil
	SH.tools_b, SH.tools_t = button(w, "Tools", function()
		-- (a dialog given up for it, as Escape does)
		if W.dialog then
			drop("dialog")
		end
		SH.show("tools")
	end)
	SH.tools_b:SetName("shell tools")
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
		(button(w, "Cancel", function()
			-- (the inspector's Place under this, its last: the sweep of
			-- 2026-11-12 armed it by a mis-tap, with no sign of it)
			if not M.escape() and S.under then
				S.under = nil
				log:info("kit editor: placing under the scene")
				A.refresh()
			end
		end))}
	-- (by name for a drive: "Up" is not the only one)
	for i, n in ipairs({"select more", "turn -", "turn +", "up", "down",
			"duplicate", "undo", "delete", "cancel"}) do
		SH.acts[i]:SetName("shell " .. n)
	end
	SH.status = text(w, "")
	SH.status_said = nil
	-- At the text size now, not in the next frame: place_shell sets the
	-- foot's font size against it (foot_font)
	SH.foot_px = nil
	if magic.ui_text_scale then
		magic.ui_text_scale(w, S.font)
	end
end

-- Whether what is being placed turns (NT.turn_step's): a prefab, a paste
function SH.turning()
	local p = S.placing
	return p ~= nil and (p.prefab ~= nil or p.clipboard ~= nil)
end

-- Which of the foot's buttons apply now (SH.acts' order), so that it is
-- mostly a row and the pane has the height (the phone test of 2026-11-12):
-- Select+ where selecting (no tool, nothing being placed; on, to turn it
-- off), Turn - and +, Up, Down and Duplicate with a selection, Turn too
-- while a prefab or a paste is placed; Undo always; Delete with a
-- selection; Cancel with something for Escape to give up (NT.cancellable)
-- or Place under this armed.
-- The world's (the first six) not in the palette's pane but the placing's
-- Turn (a landscape phone's had room for one row of its list), nor in the
-- Signals and HUD views (no world to edit). Only under the palette and the
-- inspector (Tools, a dialog: their own buttons), and none while the
-- keyboard is up (the pane has the room)
local function foot_shown(kb)
	if kb > 0 or (SH.pane ~= "palette" and SH.pane ~= "inspector") then
		return {}
	end
	local sel = next(S.sel) ~= nil
	local world = not NT.world_off() and SH.pane ~= "palette"
	local turn = (world and sel) or (not NT.world_off() and SH.turning())
	return {world and (SH.multi or (S.tool == nil and S.placing == nil)), turn,
		turn, world and sel, world and sel, world and sel, true, sel,
		NT.cancellable() or S.under ~= nil}
end

-- The foot's labels (SH.acts' order): the names, then shorter ones for a
-- row that does not fit (the sweep of 2026-11-12: two rows in landscape
-- with something selected), then with less room round their text (pad)
-- and in a smaller font (k; the user: a button's size matters more than
-- its text's, the text shrinks and the button stays at the touch size)
-- simplified: past the smallest, two rows of the names
local SHORTEST = {"Sel+", "T-", "T+", "Up", "Down", "Dup", "Undo", "Del", "Cancel"}
local FOOT = {{"Select+", "Turn -", "Turn +", "Up", "Down", "Duplicate", "Undo",
		"Delete", "Cancel"},
	{"Select+", "T-", "T+", "Up", "Down", "Dup", "Undo", "Del", "Cancel"},
	{pad = 6}, {pad = 6, k = 0.8}, {pad = 4, k = 0.65}}
for i = 3, #FOOT do
	for j, s in ipairs(SHORTEST) do
		FOOT[i][j] = s
	end
end

-- The foot's texts at k of the editor's text size
-- simplified: the style's Text size (15) taken as theirs: the sandbox's
-- Text has no font size to read
local function foot_font(k)
	local px = math.max(6, math.floor(15 * S.font * k + 0.5))
	-- (by the share too: the scaler scales them again when it changes)
	if SH.foot_px ~= px .. " " .. S.font then
		SH.foot_px = px .. " " .. S.font
		for _, b in ipairs(SH.acts) do
			b:GetChild(0):SetFontSize(px)
		end
	end
end

-- Its parts where the UI half is now (after the text size's scaling)
local function place_shell(shown)
	local u, w, T = SH.ui, W.shell, SH.TOUCH
	w:SetPosition(u[1], u[2])
	w:SetFixedSize(u[3], u[4])
	W.shell_views:SetPosition(u[1], u[2])
	W.shell_views:SetFixedSize(u[3], T + 2 * PAD)
	SH.title_set = nil
	local sy = u[4] - PAD - SH.status.height
	SH.status:SetPosition(PAD, sy)
	-- The buttons in rows as they fit (each its label's width, at least the
	-- touch size), each row stretched across: in one row by the first
	-- labels that fit it, else the names in two
	local room = u[3] - 2 * PAD
	local function rows_of(labels)
		local rows = {}
		foot_font(labels.k or 1)
		SH.foot_k = labels.k or 1
		for i, b in ipairs(SH.acts) do
			local t = b:GetChild(0)
			if t.text ~= labels[i] then
				t.text = labels[i]
			end
			local bw, r = math.max(T, t.width + (labels.pad or 12)), rows[#rows]
			b.visible = shown[i] and true or false
			if not b.visible then
				bw = nil
			elseif not r or r.used + 4 + bw > room then
				r = {used = -4}
				rows[#rows + 1] = r
			end
			if bw then
				r[#r + 1], r.used = {b = b, w = bw}, r.used + 4 + bw
			end
		end
		return rows
	end
	local rows
	for _, labels in ipairs(FOOT) do
		rows = rows_of(labels)
		if #rows <= 1 then
			break
		end
	end
	if #rows > 1 then
		rows = rows_of(FOOT[1])
	end
	SH.foot_rows = #rows
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
-- after it; the views' dropdown and Tools at the right
-- simplified: the dropdown at most half the header's room, a longer
-- scene's name cut
local function place_header(t)
	local u, T = SH.ui, SH.TOUCH
	local tw = math.max(T, SH.tools_t.width + 16)
	local x = u[3] - PAD - tw
	SH.tools_b:SetFixedSize(tw, T)
	SH.tools_b:SetPosition(x, PAD)
	SH.tools_t:SetColor(SH.pane == "tools" and magic.Color(1.0, 0.85, 0.3) or
			magic.Color(1, 1, 1))
	local dw = math.min(SH.view_dw, math.floor((x - 2 * PAD) / 2))
	x = x - 4 - dw
	SH.view_d:SetFixedSize(dw, T)
	SH.view_d:SetPosition(x, PAD)
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
		-- A label: the row's empty part from the left (a press on the text
		-- is the window's too)
		SH.label:SetPosition(PAD + 8, PAD + math.floor((T - SH.label.height) / 2))
		SH.gap = {PAD - 1, x}
		return
	end
	local bw = math.max(T, math.min(most, SH.title.width + 16))
	SH.back_b:SetFixedSize(bw, T)
	SH.back_b:SetPosition(PAD, PAD)
	-- (the empty part, UI units in the window: a press there drags the
	-- divider, UIMouseClick below)
	SH.gap = {PAD + bw, x}
end

-- The pane's title in the header
local TITLES = {inspector = "Inspector", tools = "Tools", sg_list = "Signals",
	sg_links = "Links", hud = "HUD element"}
local function title()
	if SH.pane == "palette" then
		return NT.tab()
	elseif SH.pane == "dialog" then
		return SH.dialog_title or "Dialog"
	end
	return TITLES[SH.pane]
end

-- Each target in a window at the touch size: a button, a field, a dropdown
-- at least SH.TOUCH high (a button as wide), a check box SH.TOUCH square;
-- in a row (module.lua's, its var KitRow) in a scroll view (the pane's
-- body, which the pane's width) free to grow, so the row's layout spreads
-- them across it
-- A dropdown's popup's rows at the touch size: the text size's scaling
-- has them smaller (the sweep of 2026-11-12: 20 px)
local function drop_rows(d)
	local T = SH.TOUCH
	for i = 0, d.numItems - 1 do
		local it = d:GetItem(i)
		if it and it.height ~= T then
			it:SetFixedHeight(T)
		end
	end
end

-- A dropdown's own texts (its arrow) in the middle of its height
local function drop_center(d)
	for i = 0, d:GetNumChildren() - 1 do
		local c = d:GetChild(i)
		if c and c:GetTypeName() == "Text" then
			c.verticalAlignment = magic.VA_CENTER
		end
	end
end

-- simplified: once a window (its var KitTouch), so a row added to a window
-- built already keeps its size (the palette's filter only hides rows)
local function touch_size(el, depth, scrolled)
	local T = SH.TOUCH
	local row_el = el:GetVar("KitRow") == "1"
	local in_row = scrolled and row_el
	-- A row of a fixed height lower than its targets' (the sweep of
	-- 2026-11-12: the Signals list's filter, 22 pixels)
	if row_el and el.maxHeight < T then
		el:SetFixedHeight(T)
	end
	for i = 0, el:GetNumChildren() - 1 do
		local c = el:GetChild(i)
		local t = c and c:GetTypeName()
		if t == "Text" and row_el then
			-- A row's label in the middle of its height, as its targets' text
			-- (the sweep of 2026-11-12: "x" at the top of its field's row)
			c.verticalAlignment = magic.VA_CENTER
		elseif t == "CheckBox" then
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
			-- (a pane's button takes no focus: a scroll's drag begun on one
			-- took a typed field's, and the layout gave the keyboard's room
			-- back with the keyboard still up, the user's phone 2026-11-12)
			if t == "Button" and scrolled then
				c:SetFocusMode(magic.FM_NOTFOCUSABLE)
			end
			-- (one marked narrow its own width: the palette's tabs, its x)
			if in_row and c:GetVar("KitNarrow") ~= "1" then
				c.maxWidth = 100000
			end
			if t == "DropDownList" then
				drop_rows(c)
				drop_center(c)
			end
		elseif c and t ~= "ScrollBar" and t ~= "Text" and depth < 40 then
			touch_size(c, depth + 1, scrolled or t == "ScrollView")
		end
	end
	-- (laid out again as module.lua's row(): its targets' new maximum is
	-- not applied by itself, and the sandbox has no UpdateLayout)
	if in_row then
		el:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	end
end

function SH.touch_size(el)
	touch_size(el, 0)
end

-- A typed field let go, so that the page closes its keyboard: by Apply (the
-- inspector's, Move, Turn; Enter's LineEdit lets go by itself with the
-- screen keyboard on). A pane's buttons take no focus (touch_size), so a
-- scroll's drag and the - / + steppers keep it; the field entry mode keeps
-- its own field (a refusal types again)
function SH.let_go(why)
	local f = magic.ui.focusElement
	if SH.on() and f and f:GetTypeName() == "LineEdit" and not NT.fe.s then
		magic.ui:SetFocusElement(nil)
		log:info("kit editor: touch shell: " .. why .. ": the field let go")
	end
end

-- What a tap on the world does now, before the first (the sweep of
-- 2026-11-12: a placing or a paste armed, or Place under this, said
-- nothing until the world was tapped), first in the status line
local function armed_text()
	local under = S.under and A.find(S.under)
	under = under and " under " .. NT.entity_label(under) or ""
	if S.placing then
		return "Placing " .. tostring(S.placing.label) .. under .. ": tap the world"
	end
	return under ~= "" and "Placing" .. under .. " (Cancel: stop)" or nil
end

local function status_text()
	local ses = E.session or {}
	local s = ses.kind == "bench" and "Prefab" or E.persistent and
			"Persistent" or E.running and "Running" or "Ended"
	local armed = not NT.world_off() and armed_text()
	if armed then
		s = armed .. " · " .. s
	end
	local n = #(E.builders or {})
	s = s .. " · " .. n .. (n == 1 and " builder" or " builders")
	if (E.status or "") ~= "" then
		s = s .. " · " .. E.status
	end
	return s
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
	-- [KIT_HUD_OUTLINES] Walk's HUD as in play: no frames, no boxes of Kit's
	-- own over the world (ui.lua's framed; the HUD view frames them)
	function M.hud_plain()
		return SH.world ~= nil and S.view == "walk"
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
			SH.show("sg_list")
		elseif S.view == "hud" then
			SH.show("hud")
		elseif was and not available(SH.pane) then
			SH.show(S.primary and "inspector" or "palette")
		end
	end
	-- The pane follows the activity: a placing armed, a selection made (the
	-- placing then ended: the sweep of 2026-11-12 saw a tap on the door
	-- just placed place a second, and Turn turn the ghost), a dialog up
	-- (gone, the pane before it)
	local placing = S.placing ~= nil
	if placing and not SH.was_placing and available("palette") then
		SH.show("palette")
	end
	if S.primary ~= SH.was_primary and S.primary ~= nil then
		if S.placing then
			S.placing = nil
			log:info("kit editor: placing nothing (a selection took over)")
		end
		SH.show(S.view == "hud" and "hud" or "inspector")
	end
	SH.was_placing, SH.was_primary = S.placing ~= nil, S.primary
	local dw = W.dialog
	if dw and dw ~= SH.dialog_w then
		SH.show("dialog")
	end
	SH.dialog_w = dw
	if not dw and SH.pane == "dialog" then
		SH.back()
	end
	-- The keyboard closed with a field still focused (the phone test of
	-- 2026-11-12: a tap on the field then brought it back no more): the
	-- field let go, so that a tap focuses it again
	-- (a wide screen's too: its layout keeps no keyboard)
	local f = magic.ui.focusElement
	local typing = f ~= nil and f:GetTypeName() == "LineEdit"
	local kbh = typing and buildat.keyboard_height() or 0
	if kbh > 0 then
		SH.kb_up = true
	elseif SH.kb_up then
		SH.kb_up = nil
		if typing then
			magic.ui:SetFocusElement(nil)
			log:info("kit editor: touch shell: the keyboard closed: the field let go")
		end
	end
	-- The windows out of the fit, and a frame after they are first seen (the
	-- text size's scaling then done) at the touch size and in their place:
	-- what is set before the scaling is scaled too. A menu (W.ctx) hidden
	-- until then too: it grew past the screen's foot as it was clamped
	-- before (the sweep of 2026-11-12; a frame at its first size flashed)
	for k, w in pairs(W) do
		local v = w:GetVar("KitTouch")
		if v == "" then
			w:SetVar("KitTouch", "0")
			w:SetVar("FollowsRoot", "1")
			if k == "shell" or k == "ctx" or (k == PANE_W[SH.pane] and
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
	-- A menu kept on the screen whole as it is now, then shown
	local c = W.ctx
	if c and c:GetVar("KitTouch") == "1" then
		local r = magic.ui.root
		local x = math.max(0, math.min(c.position.x, r.width - c.width))
		local y = math.max(0, math.min(c.position.y, r.height - c.height))
		if c.position.x ~= x or c.position.y ~= y then
			c:SetPosition(x, y)
		end
		if not c.visible and S.view ~= "hud" then
			c.visible = true
			log:info("kit editor: touch shell: a menu shown at " ..
					px_rect({x, y, c.width, c.height}) .. " (pixels)")
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
	local shown, names = foot_shown(kbh), {}
	for i in ipairs(SH.acts) do
		if shown[i] then
			names[#names + 1] = FOOT[1][i]
		end
	end
	local foot = table.concat(names, ", ")
	local lk = table.concat(ui, " ") .. " " .. W.shell.width .. " " .. foot
	if lk ~= SH.laid then
		SH.laid = lk
		place_shell(shown)
		SH.placed = {}
		log:info("kit editor: touch shell: the foot: " .. foot .. " (" ..
				SH.foot_rows .. (SH.foot_rows == 1 and " row" or " rows") ..
				(SH.foot_k < 1 and ", its text at " .. SH.foot_k * 100 .. "%)" or ")"))
		log:info("kit editor: touch shell: pixels: the world " .. px_rect(world) ..
				", the UI " .. px_rect(ui) .. ", the pane " .. px_rect(SH.pane_rect) ..
				", the keyboard " .. math.floor(kb * magic.ui.scale) ..
				", the touch size " .. math.floor(SH.TOUCH * magic.ui.scale))
	end
	-- (the HUD view hides every window as it comes, editor.lua's set_view)
	if not W.shell.visible then
		W.shell.visible, W.shell_views.visible = true, true
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
	-- The views' dropdown made again as what it lists changes
	local vc, names, on = view_choices(), {}, "none"
	for _, c in ipairs(vc) do
		names[#names + 1] = c[1]
		on = c[2] == S.view and c[1] or on
	end
	local vk = table.concat(names, " | ")
	if SH.view_key ~= vk then
		SH.view_key = vk
		if SH.view_d then
			SH.view_d:Remove()
		end
		SH.view_d = A.ui_utils.dropdown(W.shell_views, vc, S.view, pick_view,
				{height = SH.TOUCH, name = "shell views"})
		drop_center(SH.view_d)
		SH.view_dw, SH.title_set = SH.view_d.width, nil
	end
	-- Its popup's rows at the touch size (the sweep of 2026-11-12: the text
	-- size's scaling had them 20 px); after that scaling, so each frame
	drop_rows(SH.view_d)
	-- The header: its title, the view and the scene (a drive's line as they
	-- change)
	local t = title() or ""
	local hk = t .. "\0" .. vk .. "\0" .. ui[3] .. "\0" ..
			tostring(SH.back_to()) .. "\0" .. SH.pane
	if SH.title_set ~= hk then
		SH.title_set = hk
		place_header(t)
		local sc = magic.ui.scale
		local hl = string.format("kit editor: touch shell: the header: \"%s\", " ..
				"%s (%s), Tools%s, the empty part %d to %d at %d", SH.shown_title,
				on, vk, SH.pane == "tools" and " lit" or "", (ui[1] + SH.gap[1]) * sc,
				(ui[1] + SH.gap[2]) * sc, (ui[2] + PAD + SH.TOUCH / 2) * sc)
		if hl ~= SH.header_said then
			SH.header_said = hl
			log:info(hl)
		end
	end
	local e = ""
	if not W[PANE_W[SH.pane]] then
		e = SH.pane == "inspector" and "Nothing selected: tap an entity" or
				SH.pane == "hud" and "Tap a HUD element in the world" or ""
	end
	if SH.empty.text ~= e then
		SH.empty.text = e
	end
	-- Select+ on in the bar buttons' yellow
	if SH.multi ~= SH.multi_shown then
		SH.multi_shown = SH.multi
		SH.multi_t:SetColor(SH.multi and magic.Color(1.0, 0.85, 0.3) or
				magic.Color(1, 1, 1))
	end
	-- (one line, cut to the UI half's width: a long refusal ran off it)
	local s = status_text()
	if s .. ui[3] ~= SH.status_said then
		SH.status_said = s .. ui[3]
		local st, n = SH.status, #s
		st.text = s
		while st.width > ui[3] - 2 * PAD and n > 0 do
			repeat
				n = n - 1
			until n == 0 or s:byte(n + 1) < 0x80 or s:byte(n + 1) >= 0xC0
			st.text = s:sub(1, n) .. ".."
		end
		log:info("kit editor: touch shell: status: " .. st.text)
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
				-- (a check box in a button: the Signals view's link's Shown)
				if t == "Button" and depth < 40 then
					walk(c, depth + 1)
				end
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
