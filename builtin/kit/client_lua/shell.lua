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
-- on the left. In edit mode's 2D, 3D and Walk views only; play, Signals and
-- the HUD view are as on the desktop.
--   - The screen's aspect picks the split: tall, the world above and the UI
--     half below (45 % / 55 %); wide, side by side (50 %), the UI half on
--     the handed side. The header's grip ("=" or "||") dragged moves the
--     divider, remembered in this game's storage (kit_ui_split).
--   - The UI half: a header (Back, the pane's title, the grip, "..."), the
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
-- Walk is the app's: a drag turns (and its stick), a tap the tool's.
-- The mouse: the left button a finger (a click a tap, a drag one finger's),
-- the right drag the two fingers' (the plan pans, 3D orbits, Walk turns),
-- the middle dragged a pinch (up zooms in), the wheel zooms; no crosshair.
-- The ports are hidden (beside a finger-sized entity they took its taps): a
-- link is begun by the inspector's Link <output>, and a tap on an entity of
-- one input ends it (of more, it is selected: the inspector's To buttons).
-- The foot's buttons: Select+, Turn - and + (Z, X), Up and Down (PageUp,
-- PageDown), Duplicate, Undo, Delete, Cancel, in rows as they fit.
-- simplified: Scenes, the voxel dialog, the HUD editor, the blip designer,
-- the builders' box and the Log open as on the desktop, and the dialogs
-- still count in the UI fit (stage 4 makes them panes); Tools does not
-- scroll (a pane's room is the UI half less its header and foot); landscape
-- typing is as on the desktop (stage 2's field entry mode); a world of no
-- height is drawn a pixel high under the UI half (a rect of nothing is the
-- whole screen to Urho3D). Stage 3's: no two-finger twist (the plan does
-- not turn); the ports hidden in each view, not only the plan; Walk's two
-- fingers each turn the eye (the app's own)
return function(A)
local S, W, E, NT, M, O = A.S, A.W, A.E, A.NT, A.M, A.O
local magic, log, send, window, drop = A.magic, A.log, A.send, A.window, A.drop
local button, text = A.button, A.text
local SH = {pane = "palette", stack = {}}
NT.sh = SH

-- A target's least side, UI pixels (the user's 48, 2026-11-11)
SH.TOUCH = 48
local PAD = 6
-- The panes' windows
local PANE_W = {palette = "palette", inspector = "inspector", tools = "bar"}
local TITLES = {inspector = "Inspector", tools = "Tools"}

S.ui_mode = (buildat.declare_preference and
		buildat.declare_preference("kit_ui_mode", function(v)
			S.ui_mode = v
			log:info("kit editor: UI mode " .. SH.mode())
		end)) or 0

-- The world's share of a tall screen's height, the UI half's of a wide one's
-- width
do
	local t, w = (buildat.storage_read("kit_ui_split") or ""):match(
			"^([%d.]+) ([%d.]+)")
	SH.split = {tall = tonumber(t) or 0.45, wide = tonumber(w) or 0.5}
end

function SH.mode()
	local m = tonumber(S.ui_mode) or 0
	if m == 0 then
		return S.touch and "rh" or "desktop"
	end
	return m == 1 and "desktop" or m == 3 and "lh" or "rh"
end

function SH.on()
	return E.editing == true and SH.mode() ~= "desktop" and
			(S.view == "walk" or S.view == "2d" or S.view == "3d")
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

function SH.show(p)
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

function SH.back()
	local p = table.remove(SH.stack)
	if not p then
		return
	end
	SH.pane = p
	log:info("kit editor: touch shell: back to the " .. p .. " pane")
	S.bar_key = nil
	A.refresh()
end

-- "...": every pane, and what is not one yet
function SH.more()
	local e = {}
	for _, p in ipairs({{"palette", "Palette"}, {"inspector", "Inspector"},
			{"tools", "Tools"}}) do
		e[#e + 1] = {p[2], function() SH.show(p[1]) end}
	end
	e[#e + 1] = {SH.people and "Hide builders" or "Builders", function()
		SH.people = not SH.people
		A.people()
	end}
	e[#e + 1] = {SH.log and "Hide log" or "Log", function()
		SH.log = not SH.log
		A.show_log()
	end}
	e[#e + 1] = {"Signals view", function() A.set_view("signals") end}
	e[#e + 1] = {"HUD view", function() A.set_view("hud") end}
	if O.menu then
		e[#e + 1] = {"Menu", function() O.menu() end}
	end
	local u = SH.ui
	NT.menu(e, u[1] + u[3], u[2] + PAD + SH.TOUCH)
	-- In the UI half, at its right
	local c = W.ctx
	if c then
		c:SetPosition(math.max(u[1], u[1] + u[3] - c.width - PAD),
				c.position.y)
	end
	log:info("kit editor: touch shell: the ... menu")
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
	SH.laid = nil
	w:SetName("kit: touch shell")
	w:SetLayout(magic.LM_FREE, 0, magic.IntRect(0, 0, 0, 0))
	-- Under the panes (-1), opaque: the world is not under it
	w.priority = -2
	w.opacity = 1
	w.clipChildren = true
	SH.back_b = button(w, "<", SH.back)
	SH.back_b:SetName("shell back")
	SH.title = text(w, "")
	SH.grip = button(w, SH.tall and "=" or "||", function() end)
	SH.grip:SetName("shell divider")
	magic.SubscribeToEvent(SH.grip, "Pressed", function()
		SH.drag = true
	end)
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

-- Its parts where the UI half is now (after the text size's scaling)
local function place_shell()
	local u, w, T = SH.ui, W.shell, SH.TOUCH
	w:SetPosition(u[1], u[2])
	w:SetFixedSize(u[3], u[4])
	for _, b in ipairs({SH.back_b, SH.grip, SH.more_b}) do
		b:SetFixedSize(T, T)
	end
	SH.back_b:SetPosition(PAD, PAD)
	SH.more_b:SetPosition(u[3] - PAD - T, PAD)
	SH.grip:SetPosition(u[3] - PAD - 2 * T - 4, PAD)
	SH.title:SetPosition(PAD + T + 8, PAD + math.floor((T - SH.title.height) / 2))
	local sy = u[4] - PAD - SH.status.height
	SH.status:SetPosition(PAD, sy)
	-- The buttons in rows as they fit (each its label's width, at least the
	-- touch size), each row stretched across. The world's (the first six)
	-- not in the palette's pane: a landscape phone's had room for one row of
	-- its list
	-- simplified: so a prefab being placed is turned by Z and X only
	local room, rows = u[3] - 2 * PAD, {{used = -4}}
	for i, b in ipairs(SH.acts) do
		local bw, r = math.max(T, b:GetChild(0).width + 16), rows[#rows]
		b.visible = i > 6 or SH.pane ~= "palette"
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

-- The divider dragged by the grip: by as much as the pointer moved since
-- the grip was pressed (a finger is the left button too); let go, kept
local function drag_divider()
	local input = magic.input
	local p = input:GetMousePosition()
	local d = SH.drag
	if type(d) ~= "table" then
		d = {x = p.x, y = p.y, tall = SH.split.tall, wide = SH.split.wide}
		SH.drag = d
	end
	if not input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
		SH.drag = nil
		buildat.storage_write("kit_ui_split", string.format("%.3f %.3f",
				SH.split.tall, SH.split.wide))
		log:info(string.format("kit editor: touch shell: the split %.2f %.2f",
				SH.split.tall, SH.split.wide))
		return
	end
	local r, sc = magic.ui.root, magic.ui.scale
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
-- Signals view's in its viewport (ui.lua's hud_box)
do
	local sg_area = M.hud_area
	SH.area = {}
	function M.hud_area()
		local a = sg_area and sg_area()
		if a or not (SH.world and S.view == "walk") then
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
	-- The pane follows the activity: a placing armed, a selection made
	local placing = S.placing ~= nil
	if placing and not SH.was_placing then
		SH.show("palette")
	end
	SH.was_placing = placing
	if S.primary ~= SH.was_primary and S.primary ~= nil then
		SH.show("inspector")
	end
	SH.was_primary = S.primary
	-- The windows out of the fit, and a frame after they are first seen (the
	-- text size's scaling then done) at the touch size and in their place:
	-- what is set before the scaling is scaled too
	for k, w in pairs(W) do
		local v = k ~= "dialog" and w:GetVar("KitTouch")
		if v == "" then
			w:SetVar("KitTouch", "0")
			w:SetVar("FollowsRoot", "1")
			if k == "shell" or k == PANE_W[SH.pane] then
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
	local lk = table.concat(ui, " ") .. " " .. W.shell.width .. " " ..
			tostring(SH.pane == "palette")
	if lk ~= SH.laid then
		SH.laid = lk
		place_shell()
		W.shell.visible = true
		SH.placed = {}
		log:info("kit editor: touch shell: pixels: the world " .. px_rect(world) ..
				", the UI " .. px_rect(ui) .. ", the pane " .. px_rect(SH.pane_rect) ..
				", the keyboard " .. math.floor(kb * magic.ui.scale) ..
				", the touch size " .. math.floor(SH.TOUCH * magic.ui.scale))
	end
	local pr = SH.pane_rect
	local pw = W[PANE_W[SH.pane]]
	if pw and pw:GetVar("KitTouch") ~= "1" then
		pw = nil
	elseif pw and SH.placed.w ~= pw then
		SH.placed.w = pw
		pw:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
		pw:SetPosition(pr[1], pr[2])
		pw:SetFixedWidth(pr[3])
		pw.maxHeight = pr[4]
		pw.clipChildren = true
		pw.visible = true
	end
	local t = title() or ""
	if SH.title.text ~= t then
		SH.title.text = t
	end
	local e = not W[PANE_W[SH.pane]] and SH.pane == "inspector" and
			"Nothing selected: tap an entity" or ""
	if SH.empty.text ~= e then
		SH.empty.text = e
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
