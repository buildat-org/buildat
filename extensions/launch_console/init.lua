-- extensions/launch_console: [LAUNCH_CONSOLE], the smallest launch UI
-- that could exist -- two columns filling the screen.
--
--   Build/bin/buildat -m launch_console
--
-- **Left**: doc/client_api.txt, scrollable, with a search field and
-- next/previous. **Right**: a console that takes Lua statements and runs
-- them, showing what came back and what went wrong.
--
-- Four purposes, all of them the point rather than side effects: show
-- one kind of minimalism, show the API, show the launch-UI setting by
-- being a third thing in it, and let someone learn the API by reading it
-- on one side and running it on the other.
--
-- **And it is [LAUNCH_SANDBOX]'s conformance test with the hostility
-- removed**: this runs in the sandbox, so if a console evaluating
-- arbitrary Lua in here cannot reach past the verbs, nothing can --
-- and anyone can check that by typing.
local api = buildat.safe or buildat
local log = buildat.Logger("launch_console")
local urho3d = require("buildat/core/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
-- The words in the menus' colours ([MENU_BRAND]); the panels are its own
local ui_utils = require("buildat/extension/ui_utils")
local rgb = (ui_utils.safe or ui_utils).rgb
local function color(name) return magic.Color(rgb(name)) end
local M = {}
-- What Urho3D must not free while the console is up: an Image and the
-- Texture2D made from it ([the Material lifetime rule], and the same
-- for a texture)
kept = nil
-- The key handler, declared here because the sandbox refuses a global
-- that is first assigned from inside a function
launch_console_key = nil
-- What the eval self-check leaves behind, declared for the sandbox
console_self_check = nil

local FONT = 13
local MARGIN = 8

-- The API document, once. A launcher reads it through a verb of its own
-- rather than through a path ([LAUNCH_CONSOLE]).
local function api_lines()
	local text = api.client_api_text()
	if not text then
		return {"doc/client_api.txt was not found beside the client."}
	end
	local out = {}
	-- Every line, blank ones included: "[^\n]*" answers an empty string
	-- between every pair of lines as well, which read as 3661 lines of
	-- a 1896-line document, double-spaced
	for line in (text .. "\n"):gmatch("(.-)\n") do
		out[#out + 1] = line
	end
	return out
end

-- **The screen, which is either the whole launch UI or a panel over
-- another one** ([LAUNCH_CONSOLE]: it offers itself to the others, so
-- the room gets a developer console for free). `opts.on_close` makes it
-- the second kind: Escape calls it instead of quitting, and everything
-- drawn goes under one element the closer removes.
local function open(opts)
	opts = opts or {}
	-- **One element of its own, always** -- not only when it is drawn
	-- over somebody else's screen. Urho3D cycles Tab between the
	-- focusable elements of one top-level element (`UI.cpp:1741`), and
	-- that is the console's two fields exactly when they share this
	-- root; built straight on `ui.root` the two panels were two top
	-- levels and Tab did nothing, which is why this screen had a Tab of
	-- its own -- and why that one lost a fight with Urho3D's as soon as
	-- the console was opened over the room ([LAUNCH_WORLD], 2026-09-24:
	-- whatever holds the screen owns the input).
	local root = magic.ui.root:CreateChild("UIElement")
	root:SetFixedSize(magic.ui.root.width, magic.ui.root.height)
	root.priority = 100
	local w = magic.ui.root.width
	local h = magic.ui.root.height
	local half = math.floor(w / 2)

	-- **A flat white texel to tint**: an image element with no texture
	-- draws nothing at all, and the client ships no plain white one
	local white = magic.Image:new()
	white:SetSize(2, 2, 3)
	for y = 0, 1 do
		for x = 0, 1 do
			white:SetPixel(x, y, magic.Color(1, 1, 1, 1))
		end
	end
	local white_tex = magic.Texture2D:new()
	white_tex:SetData(white)
	kept = {white, white_tex}

	local function panel(x, width, colour)
		local e = root:CreateChild("BorderImage")
		e.texture = white_tex
		e.imageRect = magic.IntRect(0, 0, 2, 2)
		e.color = colour
		e:SetPosition(x, 0)
		e:SetFixedSize(width, h)
		return e
	end
	-- **A default style, or SetStyleAuto does nothing at all**: it looks
	-- a style up on the element's root, and an element whose root has
	-- none is left exactly as it was -- which is why the scroll view
	-- had no panel to clip with and the document drew over the hint.
	root.defaultStyle = magic.cache:GetResource("XMLFile",
			"UI/DefaultStyle.xml")
	local left = panel(0, half, magic.Color(0.06, 0.07, 0.09, 1))
	local right = panel(half, w - half, magic.Color(0.03, 0.04, 0.05, 1))

	-- **Left: the manual.** A ScrollView over one Text, which is what
	-- 1900 lines of plain text want; the search moves the view rather
	-- than re-laying anything out.
	local lines = api_lines()
	-- Where each line starts in the joined text, so a match can be
	-- pointed at rather than merely scrolled to
	local line_at = {}
	do
		local at = 0
		for i, line in ipairs(lines) do
			line_at[i] = at
			at = at + #line + 1
		end
	end
	-- **A field is dark with light text, like the rest of the column**
	-- (playtest, 2026-09-23: "the text fields are unreadable"). Urho3D's
	-- default style paints a light LineEdit, and the text in it is this
	-- console's own white -- white on white until something is selected.
	-- Built without SetStyleAuto, the way the ScrollView beside it
	-- already is, with a cursor of its own since the style is what draws
	-- one.
	local function field(parent, x, y, w)
		local e = parent:CreateChild("LineEdit")
		e.texture = white_tex
		e.imageRect = magic.IntRect(0, 0, 2, 2)
		e.color = magic.Color(0.13, 0.15, 0.18, 1)
		e:SetPosition(x, y)
		e:SetFixedSize(w, 22)
		e.textCopyable = true
		e.textSelectable = true
		local t = e.textElement
		if t then
			t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), FONT)
			t:SetColor(color("text"))
			t:SetPosition(4, 3)
		end
		local cur = e.cursor
		if cur then
			cur.texture = white_tex
			cur.imageRect = magic.IntRect(0, 0, 2, 2)
			cur.color = color("main")
			cur:SetFixedSize(2, 16)
		end
		return e
	end
	-- **At the bottom of its column, as the console's input is** (user,
	-- 2026-09-24): the eye should not travel to the top of the screen
	-- to type and back down to read what it found.
	local search = field(left, MARGIN, h - 30, half - 2 * MARGIN)
	search:SetName("console_search")
	-- **Its own line, under the field** (playtest: the hint was cut off
	-- after "search: Enter next, Shi"). It was placed beside a field
	-- that was wider than the room left for it, with no width of its
	-- own, so it ran past the column and was clipped -- and a label cut
	-- off in the middle of explaining the controls is worse than none.
	local hint = left:CreateChild("Text")
	hint:SetFont(magic.cache:GetResource("Font", buildat.font_mono), FONT)
	hint:SetPosition(MARGIN, h - 54)
	hint:SetFixedWidth(half - 2 * MARGIN)
	hint:SetColor(color("dim"))
	hint.text = "Tab moves the keyboard; in here Enter finds the next, " ..
			"Shift+Enter the one before"

	local view = left:CreateChild("ScrollView")
	-- **The style gives it a panel that clips**, which is what a scroll
	-- view is for: without one the document drew over the hint above it
	-- and off both ends of the column, however the panel was sized and
	-- told to clip by hand. The style's own light colour is painted
	-- over below.
	view:SetStyleAuto()
	-- **Out of Tab's way**: Urho3D cycles the focus through every
	-- focusable element under this screen's root, and a styled
	-- ScrollView is one of them -- so the second Tab landed on the
	-- document rather than back in the console. The two fields are the
	-- only things here worth the keyboard.
	view:SetFocusMode(magic.FM_NOTFOCUSABLE)
	view:SetPosition(MARGIN, MARGIN)
	view:SetFixedSize(half - 2 * MARGIN, h - MARGIN - 64)
	-- **The view's own panel is what was drawing white**: a ScrollView
	-- makes a BorderImage to clip its content in, and one with no
	-- texture is a white quad over the column whatever the column is
	if view.scrollPanel then
		view.scrollPanel.texture = white_tex
		view.scrollPanel.imageRect = magic.IntRect(0, 0, 2, 2)
		view.scrollPanel.color = magic.Color(0.06, 0.07, 0.09, 1)
		-- **And it clips**, which the default style would have done: a
		-- scrolled document drew over the hint above it and off the top
		-- of the column
		view.scrollPanel.clipChildren = true
	end
	local doc = left:CreateChild("Text")
	doc:SetSelectionColor(magic.Color(0.30, 0.42, 0.16, 1))
	doc:SetFont(magic.cache:GetResource("Font", buildat.font_mono), FONT)
	doc:SetColor(color("text"))
	doc.text = table.concat(lines, "\n")
	-- simplified: the document is read, not copied out of. A `Text`
	-- does have a selection -- it is what the search's match is drawn
	-- with below -- but it is set from code and not dragged with a
	-- mouse, and `textCopyable` is a `LineEdit`'s. Copying a line out
	-- wants either a LineEdit per line or a selection that follows the
	-- pointer. The console's own answers are the same.
	view.contentElement = doc

	-- Which line the view is on, so a match can be scrolled to: a Text's
	-- rows are its font's row height apart
	local row_h = math.max(1, math.floor(doc.height / math.max(1, #lines)))
	local function show_line(i)
		view.viewPosition = magic.IntVector2(0,
				math.max(0, (i - 1) * row_h - 40))
	end
	local found_at = 0
	-- The line the search is pointing at, which is what Ctrl+C takes
	local found_line = nil
	local function find(from, back)
		local q = search.text:lower()
		if q == "" then
			return
		end
		local n = #lines
		for step = 1, n do
			local i = back and (from - step) or (from + step)
			i = ((i - 1) % n) + 1
			local col = lines[i]:lower():find(q, 1, true)
			if col then
				found_at = i
				show_line(i)
				-- **The match is pointed at, not only scrolled to**
				-- (user): a line in the middle of a screenful is not
				-- an answer until something says which one it is.
				doc:SetSelection(line_at[i] + col - 1, #q)
				-- What Ctrl+C would take: the line the match is on,
				-- which is the unit a person reading an API wants
				found_line = lines[i]
				hint.text = "line " .. i .. " of " .. n
				log:info("console: search " .. q .. " -> line " .. i ..
						" column " .. col)
				return
			end
		end
		hint.text = "no line has " .. q
		doc:ClearSelection()
		log:info("console: search " .. q .. " -> nothing")
	end

	-- **Right: the console.** What was typed and what came back, oldest
	-- at the top, and one field at the bottom.
	local out_lines = {
		"buildat " .. tostring(api.version and api.version() or ""),
		"This is the sandbox every game runs in. Try: buildat.version()",
		"",
	}
	local out = right:CreateChild("Text")
	out:SetFont(magic.cache:GetResource("Font", buildat.font_mono), FONT)
	out:SetPosition(MARGIN, MARGIN)
	out:SetFixedWidth(w - half - 2 * MARGIN)
	out:SetColor(color("text"))
	out:SetWordwrap(true)
	out.text = table.concat(out_lines, "\n")
	local input = field(right, MARGIN, h - 30, w - half - 2 * MARGIN)
	input:SetName("console_input")

	local MAX_LINES = math.max(4, math.floor((h - 60) / (FONT + 4)))
	local function say(text)
		for line in tostring(text):gmatch("[^\n]+") do
			out_lines[#out_lines + 1] = line
		end
		while #out_lines > MAX_LINES do
			table.remove(out_lines, 1)
		end
		out.text = table.concat(out_lines, "\n")
	end

	-- One line in, one answer out. **`return` is added when the line is
	-- an expression**, because a console where `1 + 1` says nothing is a
	-- console nobody believes.
	local function run(line)
		say("> " .. line)
		local ok, a, b, c = api.eval("return " .. line, "=console")
		if not ok and type(a) == "string" and a:find("'<eof>'") then
			ok, a, b, c = api.eval(line, "=console")
		end
		if not ok then
			say(tostring(a))
			log:info("console: " .. line .. " ! " .. tostring(a))
			return
		end
		if a == nil and b == nil then
			return
		end
		local parts = {}
		for _, v in ipairs({a, b, c}) do
			parts[#parts + 1] = (type(v) == "table" and api.dump) and
					api.dump(v) or tostring(v)
		end
		local answer = table.concat(parts, "\t")
		say(answer)
		-- In the log as well as on the screen: a session someone had is
		-- worth as much in a bug report as anything else the client logs
		log:info("console: " .. line .. " = " .. answer)
	end

	-- **Ctrl+C and Ctrl+V reach the OS clipboard**, not a copy of
	-- Urho3D's own ([LAUNCH_CONSOLE]'s done-when: text pastes into the
	-- console from the OS). Urho3D reads the paste on the C++ side into
	-- the field the user has focused; nothing of the clipboard reaches
	-- this sandbox, which is why the safe API offers the write and not
	-- the read.
	magic.ui:SetUseSystemClipboard(true)
	magic.ui:SetFocusElement(input)
	-- **Declared at the top of the file, assigned here**: the sandbox
	-- refuses a global first assigned from inside a function, and
	-- SubscribeToEvent takes a name rather than a function
	launch_console_key = function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == magic.KEY_ESCAPE then
			if opts.on_close then
				magic.UnsubscribeFromEvent("KeyDown",
						"launch_console_key")
				root:Remove()
				magic.ui:SetFocusElement(nil)
				log:info("console: closed")
				opts.on_close()
			else
				api.quit()
			end
			return
		end
		-- **Tab moves the keyboard between the two columns**, and it is
		-- Urho3D's own: both fields sit under one top-level element, so
		-- `UI::HandleKeyDown` cycles between them and Shift+Tab goes
		-- back. A Tab of this screen's own used to do it and was undone
		-- by Urho3D's in the same frame whenever the console had a root
		-- of its own -- two handlers for one key, of which only one
		-- can be last.
		-- **Ctrl+C takes the line the search is pointing at**
		-- ([LAUNCH_CONSOLE]'s done-when: text copies out of the
		-- document). A `Text` has a selection and no copy of its own,
		-- and the selection here is always a search hit, so the line it
		-- is on is what goes to the clipboard -- the unit a person
		-- reading an API actually wants, rather than the three words
		-- they typed.
		-- The qualifier off the event rather than the key state: Urho3D
		-- names the two control keys separately and the event already
		-- says which modifiers were down (QUAL_SHIFT 1, QUAL_CTRL 2,
		-- QUAL_ALT 4; Lua 5.1 has no bitwise operators)
		local qual = event_data:GetInt("Qualifiers") or 0
		local ctrl = math.floor(qual / 2) % 2 == 1
		if key == magic.KEY_C and ctrl then
			if found_line and found_line ~= "" then
				magic.ui:SetClipboardText(found_line)
				hint.text = "copied the line"
				log:info("console: copied " .. #found_line ..
						" characters to the clipboard")
			end
			return
		end
		if key ~= magic.KEY_RETURN and key ~= magic.KEY_KP_ENTER then
			return
		end
		-- **Whichever field has the keyboard is what Enter means**, asked
		-- by name (playtest: the search did nothing). `focusElement`
		-- hands back a **fresh wrapper table** each time it is read, so
		-- comparing it to the element is comparing two different Lua
		-- tables and is always false -- the search could never be
		-- reached however well it was focused.
		local focused = magic.ui.focusElement
		local who = focused and focused:GetName() or ""
		if who == "console_search" then
			local back = magic.input:GetKeyDown(magic.KEY_SHIFT) or
					magic.input:GetKeyDown(magic.KEY_LSHIFT)
			find(found_at, back)
			return
		end
		local line = input.text
		if line == "" then
			return
		end
		input.text = ""
		run(line)
	end
	magic.SubscribeToEvent("KeyDown", "launch_console_key")
	-- As the launch UI, a way back to the menu that needs no knowing
	-- set_launch_ui(); over the room, Escape is that way already
	if not opts.on_close then
		local u = require("buildat/extension/ui_utils")
		u = u.safe or u
		local menu = u.menu_button(root, function()
			magic.UnsubscribeFromEvent("KeyDown", "launch_console_key")
			root:Remove()
			magic.ui:SetFocusElement(nil)
			log:info("console: closed for the menu")
		end)
		-- Above the input line, which runs the whole column's width
		menu:SetPosition(-10, -40)
	end

	-- **The verb's own check**, run at boot and logged: an expression, a
	-- statement whose effect the next line sees (the environment is the
	-- caller's, which is the whole point), and a syntax error caught
	-- rather than thrown.
	do
		local ok1, two = api.eval("return 1 + 1")
		local ok2 = api.eval("console_self_check = 41 + 1")
		local ok3, back = api.eval("return console_self_check")
		local ok4, err = api.eval("return 1 +")
		log:info(("console: eval %s, it keeps what a line left (%s), " ..
				"and a bad line is an answer not a crash (%s)"):format(
				(ok1 and two == 2) and "works" or "FAILED",
				(ok2 and ok3 and back == 42) and "ok" or "FAILED",
				(not ok4 and type(err) == "string") and "ok" or "FAILED"))
	end
	log:info("console: " .. #lines .. " lines of the API document, " ..
			"and a sandbox to type into")
end

function M.boot(action)
	if action then
		log:warning("launch_console: -a " .. tostring(action) ..
				" is not something a console launches")
	end
	open()
end

-- **Offered to the other launch UIs**, which is what gives a room its
-- developer console: `show{on_close = f}` draws the same two columns
-- over whatever is there and Escape takes them away again. The caller
-- stands its own handlers down while it is up -- this takes the
-- keyboard, not the events.
M.safe = {
	show = function(on_close)
		open({on_close = type(on_close) == "function" and on_close or
				function() end})
	end,
}

return M
-- vim: set noet ts=4 sw=4:
