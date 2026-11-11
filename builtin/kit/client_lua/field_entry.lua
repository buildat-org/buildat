-- Buildat: builtin/kit/client_lua/field_entry.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_PHONE_EDITING] stage 2, **the touch mode's field entry mode**: one
-- inspector parameter on the whole screen (shell.lua's touch mode only):
-- its entity and name, the value it had (the server's), what it takes (a
-- number's range, a unit and a description where its type declares them),
-- the field, the refusal of an Apply in place, and Prev, Next, Cancel and
-- Apply. It opens
--   - wide, as a field of the inspector is typed in with the on-screen
--     keyboard up;
--   - on a choice (a yes/no too) tapped, either way up: its choices as a
--     list of buttons, no keyboard;
--   - on a long text tapped, either way up: a box of several rows.
-- The inspector's own in the touch mode (params_form): a choice is a button
-- that opens it, and a number has - and + beside it (its type's `step`, else
-- 0.1 on a range of 10 or less, else 1; kept in its range), so a tap on the
-- number alone brings a keyboard.
-- Prev and Next keep what is typed as the inspector's pending edit (refused
-- in place when it does not check) and open the neighbouring field; Apply
-- sends every component's pending edits made meanwhile as the inspector's
-- Apply does, and leaves once the server's state has the value (a refusal
-- shown in place, the mode kept open); Cancel puts them back as they were.
-- Stage 4: a field of another form by the same rules, FE.extra[its name]:
-- a rec with apply(text), which Apply calls and leaves (no Prev or Next;
-- the Signals view's Name, signals.lua).
-- simplified: a long text is a string parameter whose value or default is
-- over 40 characters (no Kit type declares a multi-line one; a newline typed
-- is refused, Kit's strings are one line); the old value is shown to 30
-- characters, a choice's button to 60; the inspector's position, turn and
-- Try fields type as before
return function(A)
local S, W, E, NT = A.S, A.W, A.E, A.NT
local magic, ui_utils, log, find = A.magic, A.ui_utils, A.log, A.find
local window, drop, button, text, edit, row = A.window, A.drop, A.button,
		A.text, A.edit, A.row
local FE = {list = {}, extra = {}}
NT.fe = FE
local LONG = 40
local GOLD = magic.Color(1.0, 0.85, 0.3)

-- A value as the field shows it
local function str(v)
	if type(v) == "table" then
		local t = {}
		for i, x in ipairs(v) do
			t[i] = str(x)
		end
		return table.concat(t, " ")
	elseif type(v) == "number" then
		return string.format("%.10g", v)
	end
	return tostring(v == nil and "" or v)
end

local function shown(rec, v)
	for _, c in ipairs(rec.choices or {}) do
		if c[2] == v then
			return c[1]
		end
	end
	local s = str(v)
	return #s > 60 and s:sub(1, 57) .. "..." or s
end

-- The value pending for it, else the server's
local function current(rec)
	local p = E.pending[rec.key]
	if p and p[rec.k] ~= nil then
		return p[rec.k]
	end
	return rec.old
end

-- A number stepped by dir (-1, 1), kept in its range
function FE.stepped(d, x, dir)
	local lo, hi = tonumber(d.min), tonumber(d.max)
	local st = tonumber(d.step) or (lo and hi and hi - lo <= 10 and 0.1) or 1
	x = tonumber(string.format("%.6g", x + dir * st))
	if lo and x < lo then
		x = lo
	end
	if hi and x > hi then
		x = hi
	end
	return x
end

-- The touch mode's widgets for settings_form (params_form): each field
-- recorded in FE.list, a choice a button opening the mode, a number with
-- steppers
function FE.widgets(e, ci, c, decl, fields, base)
	local at = 0
	local function rec_of()
		return FE.list[#FE.list]
	end
	local w = {row = base.row, text = base.text, warn = base.warn}
	w.label = function(parent, s, width)
		at = at + 1
		local f = fields[at]
		local k = f.name
		local d = decl[k] or {}
		local old = (c.params or {})[k]
		if old == nil then
			old = d.default
		end
		local rec = {name = "field " .. k, k = k, key = e.id .. "/" .. ci, e = e,
			ci = ci, ctype = c.type, f = f, d = d, decl = decl, old = old,
			kind = f.type}
		if f.type == "bool" then
			rec.choices = {{"Yes", true}, {"No", false}}
		elseif f.type == "choice" then
			rec.choices = f.choices
		end
		rec.long = f.type == "text" and d.type == "string" and
				(#str(old) > LONG or #str(d.default) > LONG)
		FE.list[#FE.list + 1] = rec
		-- (narrower than the desktop's 160: a number's row with its steppers
		-- fits a phone's pane)
		return base.label(parent, s, 112)
	end
	w.dropdown = function(parent, choices, cur, on_choose)
		local rec = rec_of()
		local v = current(rec)
		local b = button(parent, shown(rec, v) .. "  ▼", function()
			FE.open(rec)
		end)
		b:SetName(rec.name)
		return b
	end
	w.edit = function(parent, value, on_text)
		local rec = rec_of()
		local el
		local function step(dir)
			local x = tonumber(el:GetText()) or tonumber(rec.old) or 0
			el:SetText(str(FE.stepped(rec.d, x, dir)))
			log:info("kit editor: field entry: stepped " .. rec.key .. " " ..
					rec.k .. " to " .. el:GetText())
		end
		if rec.kind == "number" then
			button(parent, "-", function() step(-1) end):SetName(rec.name .. " -")
		end
		el = edit(parent, value, on_text)
		el:SetName(rec.name)
		if rec.kind == "number" then
			el:SetFixedWidth(96)
			button(parent, "+", function() step(1) end):SetName(rec.name .. " +")
		end
		return el
	end
	return w
end

local function close(how)
	local s = FE.s
	FE.s = nil
	drop("entry")
	magic.ui:SetFocusElement(nil)
	log:info("kit editor: field entry: closed, " .. how .. (s and s.rec and
			" (" .. s.rec.key .. " " .. s.rec.k .. ")" or ""))
	A.refresh()
end

local function refuse(why)
	local s = FE.s
	s.bad = why
	s.waiting = nil
	if s.refusal then
		s.refusal.text = why
	end
	-- Typed again at once (Apply took the focus)
	if s.edit then
		s.edit:SetFocus(true)
	end
	log:info("kit editor: field entry: refused in place: " .. why)
end

-- The field's value as typed or picked, or nil and why not
local function value(s)
	local rec = s.rec
	if rec.choices then
		return s.pick
	end
	local t = s.edit:GetText()
	if rec.d.type == "position" then
		local p = NT.position_of(t)
		if not p then
			return nil, "three numbers, x y z"
		end
		return t
	end
	return ui_utils.check_setting(rec.f, t)
end

-- Kept as the inspector's pending edit (its earlier pending kept for Cancel)
local function keep(s)
	local v, bad = value(s)
	if v == nil then
		refuse(s.rec.k .. ": " .. tostring(bad))
		return false
	end
	local rec = s.rec
	if str(v) ~= str(current(rec)) then
		E.pending[rec.key] = E.pending[rec.key] or {}
		E.pending[rec.key][rec.k] = v
		s.recs[rec.key] = rec
		s.last = {id = rec.e.id, ci = rec.ci, k = rec.k, v = str(v)}
		log:info("kit editor: " .. rec.key .. " " .. rec.k .. " = " .. str(v))
	end
	return true
end

local function index_of(rec)
	for i, r in ipairs(FE.list) do
		if r.key == rec.key and r.k == rec.k then
			return i
		end
	end
end

local function go(by)
	local s = FE.s
	if s.rec.apply or s.waiting or not keep(s) then
		return
	end
	local n = #FE.list
	local i = index_of(s.rec)
	if not i or n == 0 then
		return
	end
	FE.open(FE.list[(i - 1 + by) % n + 1])
end

function FE.apply()
	local s = FE.s
	if s and s.rec.apply then
		s.rec.apply(s.edit:GetText())
		return close("applied")
	end
	if not s or s.waiting or not keep(s) then
		return
	end
	if not s.last then
		return close("nothing changed")
	end
	for _, r in pairs(s.recs) do
		local bad = NT.apply_params(r.e, r.ci, r.decl)
		if bad then
			return refuse(bad)
		end
	end
	s.recs, s.snap = {}, {}
	s.waiting = s.last
	s.bad = nil
	s.refusal.text = "Applying..."
	log:info("kit editor: field entry: applied, waiting for " .. s.waiting.id ..
			" " .. s.waiting.k .. " = " .. s.waiting.v)
end

function FE.cancel()
	local s = FE.s
	for key, p in pairs(s.snap) do
		E.pending[key] = next(p) and p or nil
	end
	close("cancelled")
end

-- The server's refusal of an edit (editor_input.lua's kit:edit_refused)
function FE.refused(why)
	if FE.s and FE.s.waiting then
		refuse(why)
	end
end

-- What it takes: "a number, 0 to 3600 s"
local function takes(rec)
	local d, f = rec.d, rec.f
	local s
	if rec.kind == "bool" then
		s = "Yes or no"
	elseif rec.choices then
		s = "One of " .. #rec.choices
	elseif rec.kind == "number" then
		s = "A number"
		if d.min and d.max then
			s = s .. ", " .. str(d.min) .. " to " .. str(d.max)
		elseif d.min then
			s = s .. ", at least " .. str(d.min)
		elseif d.max then
			s = s .. ", at most " .. str(d.max)
		end
	elseif d.type == "position" then
		s = "Three numbers, x y z"
	else
		s = "Text, at most " .. tostring(f.max_length or 256) .. " characters"
	end
	if type(d.unit) == "string" then
		s = s .. " " .. d.unit
	end
	return s
end

-- The mode on rec's field: its window built, laid out a frame on (tick)
function FE.open(rec)
	local s = FE.s
	if not s then
		s = {snap = {}, recs = {}}
		FE.s = s
	end
	if s.snap[rec.key] == nil then
		local p = {}
		for k, v in pairs(E.pending[rec.key] or {}) do
			p[k] = v
		end
		s.snap[rec.key] = p
	end
	s.rec, s.bad, s.waiting, s.laid, s.age = rec, nil, nil, nil, 0
	s.pick = current(rec)
	drop("entry")
	local w = window(magic.HA_LEFT, magic.VA_TOP, 0, 0)
	W.entry = w
	w:SetName("kit: field entry")
	-- Over the shell and its panes, under the menus; out of the UI fit
	w.priority = 0
	w.opacity = 1
	w.clipChildren = true
	w.visible = false
	w:SetVar("FollowsRoot", "1")
	s.win = w
	s.title = text(w, NT.entity_label(rec.e) .. " · " .. rec.k, GOLD)
	-- (one line, above a landscape keyboard)
	local was = shown(rec, rec.old)
	s.info = text(w, "Was: " .. (#was > 30 and was:sub(1, 27) .. "..." or was) ..
			"   ·   " .. takes(rec), A.DIM)
	local about = rec.d.about or rec.d.description
	s.about = type(about) == "string" and text(w, about, A.DIM) or nil
	s.edit, s.view, s.picks, s.steps = nil, nil, {}, nil
	if rec.choices then
		local view = w:CreateChild("ScrollView")
		local body = view:CreateChild("UIElement")
		body:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
		for _, c in ipairs(rec.choices) do
			local b, t = button(body, c[1], function()
				s.pick = c[2]
				for _, p in ipairs(s.picks) do
					p[2]:SetColor(p[3] == s.pick and GOLD or
							magic.Color(ui_utils.rgb("text")))
				end
				log:info("kit editor: field entry: picked " .. c[1])
			end, c[2] == s.pick)
			b:SetName("choice " .. c[1])
			s.picks[#s.picks + 1] = {b, t, c[2]}
		end
		view:SetStyleAuto()
		view:SetFocusMode(magic.FM_NOTFOCUSABLE)
		view.contentElement = body
		body:SetPosition(0, 0)
		s.view, s.body = view, body
	else
		local r = row(w)
		s.field_row = r
		local function step(dir)
			local x = tonumber(s.edit:GetText()) or tonumber(rec.old) or 0
			s.edit:SetText(str(FE.stepped(rec.d, x, dir)))
		end
		if rec.kind == "number" then
			s.steps = {button(r, "-", function() step(-1) end)}
		end
		s.edit = edit(r, str(current(rec)), function() end)
		s.edit:SetName("entry field")
		s.edit.multiLine = rec.long
		magic.SubscribeToEvent(s.edit, "TextFinished", function()
			FE.apply()
		end)
		if rec.kind == "number" then
			s.steps[2] = button(r, "+", function() step(1) end)
			s.steps[1]:SetName("entry -")
			s.steps[2]:SetName("entry +")
		end
	end
	s.refusal = text(w, " ", A.WARN)
	local br = row(w)
	s.buttons_row = br
	s.buttons = {}
	for _, b in ipairs({{"< Prev", "prev", function() go(-1) end},
			{"Next >", "next", function() go(1) end},
			{"Cancel", "cancel", FE.cancel}, {"Apply", "apply", FE.apply}}) do
		local el = button(br, b[1], b[3])
		el:SetName("entry " .. b[2])
		s.buttons[#s.buttons + 1] = el
	end
	-- A list needs no keyboard; a field takes the focus once shown (lay_out:
	-- the keyboard kept up meanwhile by the field it has)
	if not s.edit then
		magic.ui:SetFocusElement(nil)
	end
	log:info("kit editor: field entry: " .. rec.key .. " " .. rec.k .. " (" ..
			(rec.long and "long text" or rec.kind) .. "), was " .. str(rec.old))
end

-- Its sizes, after the text size's scaling (what is set before it is scaled
-- too): the whole screen, the targets at the touch size, a list or a long
-- text's box what is left (above the keyboard)
local function lay_out(s, kb)
	local r, T = magic.ui.root, NT.sh.TOUCH
	local fw = r.width - 12
	local w = s.win
	w:SetPosition(0, 0)
	w:SetFixedSize(r.width, r.height)
	for _, t in pairs({s.title, s.info, s.about or s.title, s.refusal}) do
		t:SetFixedWidth(fw)
	end
	s.buttons_row:SetFixedSize(fw, T)
	local bw = math.floor((fw - 12) / 4)
	for _, b in ipairs(s.buttons) do
		b:SetFixedSize(bw, T)
	end
	local others = s.title.height + s.info.height + (s.about and
			s.about.height + 4 or 0) + s.refusal.height + T + 4 * 4 + 12
	local room = r.height - others
	if s.view then
		s.view:SetFixedSize(fw, math.max(T, room))
		for _, p in ipairs(s.picks) do
			p[1]:SetFixedSize(fw - 24, T)
		end
		-- The pick in view
		for i, p in ipairs(s.picks) do
			if p[3] == s.pick then
				local y = (i - 1) * (T + 4) - math.floor(room / 3)
				s.view.viewPosition = magic.IntVector2(0, math.max(0,
						math.min(y, s.body.height - room)))
			end
		end
	else
		local h = s.edit.multiLine and math.max(T, math.min(240, room - kb)) or T
		s.field_row:SetFixedSize(fw, h)
		for _, b in ipairs(s.steps or {}) do
			b:SetFixedSize(T, T)
		end
		s.edit:SetFixedSize(fw - (s.steps and 2 * (T + 4) or 0), h)
	end
	if not w.visible and s.edit then
		w.visible = true
		s.edit:SetFocus(true)
	end
	w.visible = true
	-- For a check, where they are now (pixels)
	local sc = magic.ui.scale
	local f, by = s.edit or s.view, s.buttons_row.screenPosition.y
	log:info(string.format("kit editor: field entry: laid out %dx%d, the %s "
			.. "%d to %d, the buttons %d to %d, the keyboard %d (pixels)",
			r.width * sc, r.height * sc, s.edit and "field" or "list",
			f.screenPosition.y * sc,
			(f.screenPosition.y + f.height) * sc, by * sc, (by + T) * sc,
			kb * sc))
end

-- Each frame (editor_input.lua's Update, after shell.lua's)
function FE.tick()
	local s = FE.s
	if s then
		if not W.entry then
			FE.s = nil
			return
		end
		if not NT.sh.on() then
			return close("the touch mode off")
		end
		if s.waiting then
			local e = find(s.waiting.id)
			local c = e and e.components and e.components[s.waiting.ci]
			if c and str((c.params or {})[s.waiting.k]) == s.waiting.v then
				return close("applied")
			end
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
	if not NT.sh.on() then
		return
	end
	-- A field of the inspector's typed in: wide with the keyboard up, or a
	-- long text either way up
	local f = magic.ui.focusElement
	if not f or f:GetTypeName() ~= "LineEdit" then
		return
	end
	local name = f:GetName()
	local function maybe(rec)
		if rec.long or (not NT.sh.tall and buildat.keyboard_height() > 0) then
			FE.open(rec)
		end
	end
	for _, rec in ipairs(FE.list) do
		if rec.name == name then
			return maybe(rec)
		end
	end
	if FE.extra[name] then
		maybe(FE.extra[name])
	end
end
end
-- vim: set noet ts=4 sw=4:
