-- Buildat: apps/floorplanner/main/client_lua/field_entry.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_PHONE_EDITING] 4z11 stage 5b, **the touch mode's field entry mode**
-- (builtin/kit/client_lua/field_entry.lua's, copied and put over panel.lua's
-- fields): wide, a field of a pane typed in with the on-screen keyboard up
-- (a name, a length, any panel.field) is the whole screen: what it belongs
-- to and its name, the value it had, what it takes, the field (a number
-- with - and + of its step beside it), a refusal in place, and Prev, Next,
-- Cancel and Apply. Apply does what Enter in the field does (its on_finish:
-- the edit sent) and leaves; Cancel leaves it as it was; Prev and Next
-- apply as Apply does and open the pane's field before or after it.
-- simplified: a refusal in place is the client's (a number that is none);
-- the server's comes after it is left, as a notice, as a desktop's typed
-- field's does. No choice list: floorplanner's choices are dropdowns, whose
-- list is a finger's already; no long text (floorplanner has none)
return function(A)
local S, E, M, magic, log, panel = A.S, A.E, A.M, A.magic, A.log, A.panel
local SH = M.sh
local FE = {list = {}}
M.fe = FE
local GOLD = magic.Color(1.0, 0.85, 0.3)
local DIM = magic.Color(0.7, 0.7, 0.7)
local WARN = magic.Color(1.0, 0.45, 0.35)

local function str(v)
	if type(v) == "number" then
		return string.format("%.10g", v)
	end
	return tostring(v == nil and "" or v)
end

-- panel.field's, each field made: kept with its window (a pane's, by
-- panel.top), the windows rebuilt since forgotten
local field_n = 0
function FE.add(e, parent, label, value, on_finish, step)
	if e:GetName() == "" then
		field_n = field_n + 1
		e:SetName("fp_field_" .. field_n)
	end
	if #FE.list > 200 then
		local tops, kept = {}, {}
		for _, w in pairs(A.wins()) do
			tops[panel.top(w)] = true
		end
		for _, r in ipairs(FE.list) do
			if tops[r.win] then
				kept[#kept + 1] = r
			end
		end
		FE.list = kept
	end
	FE.list[#FE.list + 1] = {name = e:GetName(), win = panel.top(parent),
		label = label, old = str(value), on_finish = on_finish,
		number = type(value) == "number" and step or nil}
end
panel.on_field = FE.add

-- The fields of the pane shown, in the order made
local function pane_list()
	local w = A.wins()[SH.pane]
	local top, l = w and panel.top(w), {}
	for _, r in ipairs(FE.list) do
		if r.win == top then
			l[#l + 1] = r
		end
	end
	return l
end

local function close(how)
	local s = FE.s
	FE.s = nil
	s.win:Remove()
	magic.ui:SetFocusElement(nil)
	log:info("fp editor: field entry: closed, " .. how .. " (" .. s.rec.label ..
			")")
end

local function refuse(why)
	local s = FE.s
	s.refusal.text = why
	s.edit:SetFocus(true)
	log:info("fp editor: field entry: refused in place: " .. why)
end

-- What is typed done as Enter in the field does; false (refused in place)
-- when it is no number where one is wanted
local function keep(s)
	local t = s.edit:GetText()
	if s.rec.number and not tonumber(t) then
		refuse(s.rec.label .. ": a number")
		return false
	end
	if t ~= s.rec.old then
		log:info("fp editor: field entry: " .. s.rec.label .. " = " .. t)
		s.rec.on_finish(t)
		s.applied = true
	end
	return true
end

local function go(by)
	local s = FE.s
	if not keep(s) then
		return
	end
	-- (by its label: the pane may have been made again by the edit)
	local l = pane_list()
	for i, r in ipairs(l) do
		if r.label == s.rec.label then
			return FE.open(l[(i - 1 + by) % #l + 1])
		end
	end
end

function FE.apply()
	local s = FE.s
	if s and keep(s) then
		close(s.applied and "applied" or "nothing changed")
	end
end

function FE.cancel()
	close("cancelled")
end

-- What it belongs to: the selection, else the pane
local function owner()
	local e = S.primary and E.doc.ents[S.primary]
	if not e then
		return SH.title_of(SH.pane) or ""
	end
	local n = e.strs and e.strs.name or ""
	return e.type .. " " .. e.id .. (n ~= "" and " \"" .. n .. "\"" or "")
end

-- The mode on rec's field: its window built, laid out a frame on (tick)
function FE.open(rec)
	local s = FE.s
	if s then
		s.win:Remove()
	end
	s = {rec = rec, age = 0, applied = s and s.applied}
	FE.s = s
	local w = panel.window_of(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	s.win = w
	w:SetName("fp: field entry")
	-- Over the shell and its panes, under the "..." menu; out of the UI fit
	w.priority = 0
	w.opacity = 1
	w.clipChildren = true
	w.visible = false
	w:SetVar("FollowsRoot", "1")
	s.title = panel.label(w, owner() .. " · " .. rec.label, GOLD)
	local was = #rec.old > 30 and rec.old:sub(1, 27) .. "..." or rec.old
	s.info = panel.label(w, "Was: " .. was .. "   ·   " .. (rec.number and
			"A number" .. (rec.number ~= 1 and ", steps of " .. str(rec.number)
			or "") or "Text"), DIM)
	for _, t in ipairs({s.title, s.info}) do
		t:SetWordwrap(true)
	end
	local r = panel.row(w)
	s.field_row = r
	local function step(dir)
		local x = tonumber(s.edit:GetText()) or tonumber(rec.old) or 0
		s.edit:SetText(str(x + dir * rec.number))
		log:info("fp editor: field entry: stepped " .. rec.label .. " to " ..
				s.edit:GetText())
	end
	s.steps = nil
	if rec.number then
		s.steps = {panel.button(r, "-", function() step(-1) end)}
		s.steps[1]:SetName("entry -")
	end
	local e = r:CreateChild("LineEdit")
	e:SetStyleAuto()
	e:SetName("entry field")
	e.textSelectable = true
	e:SetText(rec.old)
	s.edit = e
	magic.SubscribeToEvent(e, "TextFinished", function()
		FE.apply()
	end)
	if rec.number then
		s.steps[2] = panel.button(r, "+", function() step(1) end)
		s.steps[2]:SetName("entry +")
	end
	s.refusal = panel.label(w, " ", WARN)
	local br = panel.row(w)
	s.buttons_row, s.buttons = br, {}
	for _, b in ipairs({{"< Prev", "prev", function() go(-1) end},
			{"Next >", "next", function() go(1) end},
			{"Cancel", "cancel", FE.cancel}, {"Apply", "apply", FE.apply}}) do
		local el = panel.button(br, b[1], b[3])
		el:SetName("entry " .. b[2])
		s.buttons[#s.buttons + 1] = el
	end
	log:info("fp editor: field entry: " .. rec.label .. " (" .. (rec.number and
			"number" or "text") .. "), was " .. rec.old)
end

-- Its sizes, after the text size's scaling (what is set before it is scaled
-- too): the whole screen, the targets at the touch size
local function lay_out(s, kb)
	local r, T = magic.ui.root, SH.TOUCH
	local fw = r.width - 12
	local w = s.win
	w:SetPosition(0, 0)
	w:SetFixedSize(r.width, r.height)
	for _, t in ipairs({s.title, s.info, s.refusal}) do
		t:SetFixedWidth(fw)
	end
	s.buttons_row:SetFixedSize(fw, T)
	local bw = math.floor((fw - 12) / 4)
	for _, b in ipairs(s.buttons) do
		b:SetFixedSize(bw, T)
	end
	s.field_row:SetFixedSize(fw, T)
	for _, b in ipairs(s.steps or {}) do
		b:SetFixedSize(T, T)
	end
	s.edit:SetFixedSize(fw - (s.steps and 2 * (T + 4) or 0), T)
	if not w.visible then
		w.visible = true
		s.edit:SetFocus(true)
	end
	-- For a check, where they are now (pixels)
	local sc = magic.ui.scale
	local fy, by = s.edit.screenPosition.y, s.buttons_row.screenPosition.y
	log:info(string.format("fp editor: field entry: laid out %dx%d, the field "
			.. "%d to %d, the buttons %d to %d, the keyboard %d (pixels)",
			r.width * sc, r.height * sc, fy * sc, (fy + T) * sc, by * sc,
			(by + T) * sc, kb * sc))
end

-- Each frame (shell.lua's tick, after its layout)
function FE.tick()
	local s = FE.s
	if s then
		if not SH.on() then
			return close("the touch mode off")
		end
		s.age = s.age + 1
		local kb = buildat.keyboard_height()
		local r = magic.ui.root
		local key = r.width .. " " .. r.height .. " " .. kb
		if s.age >= 2 and s.laid ~= key then
			s.laid = key
			lay_out(s, kb)
		end
		return
	end
	-- A pane's field typed in, wide, with the keyboard up
	local f = magic.ui.focusElement
	if not SH.on() or SH.tall or not f or f:GetTypeName() ~= "LineEdit" or
			buildat.keyboard_height() == 0 then
		return
	end
	local name = f:GetName()
	for i = #FE.list, 1, -1 do
		if FE.list[i].name == name then
			return FE.open(FE.list[i])
		end
	end
end
end
-- vim: set noet ts=4 sw=4:
