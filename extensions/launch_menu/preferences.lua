-- Buildat: extension/launch_menu/preferences.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The preferences screen: what the user sets once and every game honours.
--
-- doc/plan/client_preferences_plan.md built the preferences and made every
-- game honour them, but until this nothing set them except a file and -o.
-- The C++ side stays the authority -- api.set_preference() parses and
-- range checks a value through the same code -o goes through, applies what
-- takes effect now, and persists the rest -- so this file is a page of
-- widgets that knows nothing about the file and cannot set a value a flag
-- could not.
--
-- A dropdown per preference, of the values worth offering
-- ([ENGINE_SETTINGS_DROPDOWNS], user 2026-10-06: they were buttons that
-- cycled), in launch_menu's Server filter's style. The menu's arrows
-- reach each one and Enter opens it, Urho3D's own.
-- Run by the menu's own verb, so it loads on either side
-- ([LAUNCH_SANDBOX]): `require` answers an extension's safe half inside
-- the sandbox and the whole extension outside it, and the safe half
-- raises on a name it does not have rather than answering nil
local api = buildat.safe or buildat
local log = buildat.Logger("extension/launch_menu/preferences")
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
local uistack = require("buildat/extension/uistack")
uistack = uistack.main and uistack or uistack.safe
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.bind_button_menu and ui_utils or ui_utils.safe

-- **The constants are globals in trusted Lua and fields of the safe
-- table in the sandbox**, so they are named once here and the code
-- below reads the same on both sides ([LAUNCH_SANDBOX])
local HA_CENTER, KEY_ESCAPE, LM_VERTICAL, LM_HORIZONTAL =
		magic.HA_CENTER, magic.KEY_ESCAPE, magic.LM_VERTICAL,
		magic.LM_HORIZONTAL

local M = {}

-- The values each preference offers, and how one is written out. The ranges
-- are the parser's own -- see parse_preference_options() in src/client/app.cpp
-- -- so nothing here can be refused; what is offered is the useful subset of
-- what is allowed.
local function percent(v)
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

-- Named as the -l numbers are; the two upper ones say what they cost
local LOG_LEVEL_NAMES = {[1] = "error", [2] = "warning", [3] = "info",
		[4] = "verbose (large logs, slower)", [5] = "debug (huge logs, slow)"}

local PREFERENCES = {
	{
		name = "render_scale",
		label = "Render scale",
		-- 1.0 is no scaling at all and is the bypass: the game draws into
		-- the window itself. Above it is supersampling, which the same code
		-- path gives away for free.
		values = {"auto", 0.5, 0.67, 0.75, 1.0, 1.5, 2.0},
		show = function(v)
			if v == "auto" then
				return "automatic (" ..
						percent(api.get_preferred_render_scale()) .. ")"
			end
			return percent(v)
		end,
	},
	{
		name = "vsync",
		label = "Vertical sync",
		values = {false, true},
	},
	{
		name = "max_fps",
		label = "Frame limit",
		-- 200 is Urho3D's own desktop default, which is what a client that
		-- says nothing gets; 0 is no limit at all.
		values = {30, 60, 75, 120, 144, 200, 0},
		show = function(v) return v == 0 and "unlimited" or tostring(v) end,
	},
	{
		name = "multisampling",
		label = "Antialiasing",
		values = {1, 2, 4, 8, 16},
		show = function(v) return v == 1 and "off" or (v.."x") end,
	},
	-- **Decibels below full, not a fader position** ([VOLUME_LAW], user
	-- 2026-09-28: "80% vs 100% linear is basically no change at all").
	-- Eleven levels 3 dB apart and silence under them, so every step is
	-- heard as the same step; the gain is made from this in the client,
	-- where it is applied.
	{
		name = "sound_volume_db",
		label = "Sound volume",
		values = {-33, -30, -27, -24, -21, -18, -15, -12, -9, -6, -3, 0},
		show = function(v)
			return ui_utils.db_text(v)
		end,
	},
	{
		name = "sound_mute",
		label = "Mute",
		values = {false, true},
	},
	-- The UI scale; "auto" follows the window
	{
		name = "ui_size",
		label = "UI size",
		values = {"auto", 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0},
		show = function(v)
			-- The scale it comes to, while it is the one in use
			if v == "auto" and api.get_preference("ui_size") == "auto" then
				return "automatic (" .. percent(api.get_ui_scale()) .. ")"
			elseif v == "auto" then
				return "automatic"
			end
			return percent(v)
		end,
	},
	-- The web page's address bar while playing ([WEB_ADDRESS_BAR]); the
	-- web client's only, and no row natively
	{
		name = "web_address_bar",
		label = "Address bar while playing",
		web = true,
		values = {"hide", "show"},
		show = function(v) return v == "hide" and "hidden" or "shown" end,
	},
	-- The screen's orientation while the page is fullscreen
	-- ([SCREEN_ORIENTATION]); the web client's only. note() is said under
	-- the row.
	{
		name = "screen_orientation",
		label = "Screen orientation",
		web = true,
		values = {"auto", "landscape", "portrait"},
		show = function(v)
			return ({auto = "Auto", landscape = "Landscape",
					portrait = "Portrait"})[v]
		end,
		note = function()
			if api.get_preference("screen_orientation_error") then
				return "Not supported by this browser"
			elseif api.get_preference("screen_orientation") ~= "auto" and
					api.get_preference("web_address_bar") == "show" then
				return "Held only with the address bar hidden"
			end
		end,
	},
	-- The web client's frame rate while unfocused or idle
	{
		name = "web_idle_fps",
		label = "Frame rate while idle",
		web = true,
		values = {1, 5, 10, 30, 60},
	},
	-- The two logs' levels ([LOG_LEVEL_PREF]): a box report without a
	-- shell. The client's takes at once, the server's on its next start;
	-- -l on the command line wins for that run. The logs are
	-- cache/buildat.log and cache/buildat_server.log.
	{
		name = "log_level",
		label = "Client log (cache/buildat.log)",
		values = {1, 2, 3, 4, 5},
		show = function(v) return LOG_LEVEL_NAMES[v] end,
	},
	{
		name = "server_log_level",
		label = "Server log (cache/buildat_server.log), next start",
		values = {1, 2, 3, 4, 5},
		show = function(v) return LOG_LEVEL_NAMES[v] end,
	},
}

local function show_value(pref, value)
	if type(value) == "boolean" then
		return value and "on" or "off"
	end
	if pref.show then
		return pref.show(value)
	end
	return tostring(value)
end

-- The entry of pref.values that is nearest to what the preference actually
-- is. Nearest rather than equal because the value may have come from a
-- hand-edited file or from -o, and neither is restricted to this list; an
-- unlisted value still shows as the closest thing and cycles on from there.
local function nearest_index(pref, value)
	if type(value) == "boolean" then
		return value and 2 or 1
	end
	local best, best_d = 1, nil
	for i, v in ipairs(pref.values) do
		if v == value then
			return i
		end
		local d = type(v) == "number" and type(value) == "number" and
				math.abs(v - value) or math.huge
		if best_d == nil or d < best_d then
			best, best_d = i, d
		end
	end
	return best
end

-- A button and the Text inside it, kept rather than looked up again:
-- GetChild() hands back a UIElement and "text" is a property of Text, which
-- the sandbox is right to refuse. ui_utils.vertical_menu():add() takes a
-- button as readily as a label, so making it here costs nothing.
local function make_row(window, label)
	local button = window:CreateChild("Button")
	button:SetStyleAuto()
	button:SetName("Button")
	button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	button.minHeight = 24
	button.minWidth = 320
	local text = button:CreateChild("Text")
	text:SetName("ButtonText")
	text:SetStyleAuto()
	text.text = label
	text:SetTextAlignment(HA_CENTER)
	return button, text
end

-- The launch UIs as a list, the one in use first: each its title, its
-- extension name, its description and whether it is experimental.
-- Picking one switches to it; Back and Escape leave it as it is.
local function show_launch_uis(uis, now)
	local root = uistack.main:push({desc = "launch UIs"})
	local menu = ui_utils.vertical_menu(root, {
		on_key = function(key)
			if key == KEY_ESCAPE then
				uistack.main:pop(root)
				return true
			end
		end,
	})
	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Launch UI"
	title:SetFontSize(20)
	local order = {}
	for _, e in ipairs(uis) do
		table.insert(order, e.name == now and 1 or #order + 1, e)
	end
	for _, e in ipairs(order) do
		local button = menu.window:CreateChild("Button")
		button:SetStyleAuto()
		button:SetName("Button")
		button:SetLayout(LM_VERTICAL, 2, magic.IntRect(8, 4, 8, 6))
		button:SetFixedWidth(460)
		local function line(text, size, colour)
			local t = button:CreateChild("Text")
			t:SetStyleAuto()
			t.text = text
			if size then t:SetFontSize(size) end
			if colour then t.color = colour end
			return t
		end
		line(e.title .. "   (" .. e.name .. ")" ..
				(e.name == now and "   - in use" or ""))
		if e.experimental then
			line("experimental", 12, magic.Color(ui_utils.rgb("error")))
		end
		if e.description then
			local d = line(e.description, 12, magic.Color(ui_utils.rgb("dim")))
			-- simplified: 400 and not the row's 444, since under a UI
			-- scale the wrap measures a line narrower than it is drawn;
			-- the real fix is in the font scaling, not here
			d:SetFixedWidth(400)
			d:SetWordwrap(true)
		end
		menu:add(button, function()
			if e.name == now then
				uistack.main:pop(root)
				return
			end
			local ok, err = api.set_launch_ui(e.name)
			if not ok then
				log:warning("launch_ui: " .. tostring(err))
				ui_utils.show_message_dialog("Launch UI: " .. tostring(err))
			end
		end)
	end
	menu:add("Back", function()
		uistack.main:pop(root)
	end)
	-- What a check waits for
	log:info("Launch UIs shown")
end

function M.show()
	local root = uistack.main:push({desc = "preferences"})

	local menu = ui_utils.vertical_menu(root, {
		on_key = function(key)
			if key == KEY_ESCAPE then
				uistack.main:pop(root)
				return true -- taken; the menu's own Escape = Back stands down
			end
		end,
	})

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Engine settings"
	title:SetFontSize(20)

	for _, pref in ipairs(PREFERENCES) do
		local value = api.get_preference(pref.name)
		if value == nil and pref.web then
			-- Natively: not a preference here
		elseif value == nil then
			-- A build whose preferences this one does not have: leave the
			-- row out rather than showing a control that does nothing
			log:warning("No preference by the name "..pref.name)
		else
			local choices = {}
			for i, v in ipairs(pref.values) do
				choices[i] = {show_value(pref, v), i}
			end
			local drop = ui_utils.dropdown(menu.window, choices,
					nearest_index(pref, value), function(_, i)
				local ok, err = api.set_preference(pref.name, pref.values[i])
				if not ok then
					-- Cannot happen with the values above, and saying so is
					-- better than a control that quietly does nothing
					log:warning(pref.name..": "..tostring(err))
					ui_utils.show_message_dialog(
							pref.label..": "..tostring(err))
				end
			end, {label = pref.label, label_width = 300, width = 240})
			-- The press is the dropdown's own; this only puts it in the
			-- arrows' order
			menu:add(drop, function() end)
			local note = pref.note and pref.note()
			if note then
				local t = menu.window:CreateChild("Text")
				t:SetStyleAuto()
				t.text = note
			end
		end
	end

	-- **The name games offer when they ask for one** ([FP_LAUNCH]): a
	-- text, so a field rather than a cycling row. Enter sets it through
	-- the parser; a name it refuses is said and the field goes back.
	local username = api.get_preference("default_username")
	if username ~= nil then
		local row = menu.window:CreateChild("UIElement")
		row:SetLayout(LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
		local label = row:CreateChild("Text")
		label:SetStyleAuto()
		label.text = "Default username for apps"
		local edit = row:CreateChild("LineEdit")
		edit:SetStyleAuto()
		edit:SetFixedHeight(26)
		edit.minWidth = 320
		edit.textSelectable = true
		edit.textCopyable = true
		edit:SetText(username)
		magic.SubscribeToEvent(edit, "TextFinished", function()
			local ok, err = api.set_preference("default_username",
					edit:GetText())
			if not ok then
				log:warning("default_username: " .. tostring(err))
				ui_utils.show_message_dialog(tostring(err))
				edit:SetText(api.get_preference("default_username") or "")
			end
		end)
	end

	-- **Which launch UI this is** ([LAUNCH_SANDBOX]'s slot, and
	-- [TWO_AUDIENCES]: switching is one action from either side). The
	-- listing is read from the extensions that ship a `launch_ui.txt`,
	-- not by running them. **Looking is not taking** (user, 2026-09-24):
	-- one of the options is a bare console, so the row only says which
	-- one is in use and opens the list, and the list takes nothing until
	-- an entry is picked (2026-10-06: the cycling row and its "Use"
	-- button under it read as two settings, and a long title did not fit).
	local uis = api.list_launch_uis and api.list_launch_uis() or {}
	if #uis > 1 then
		local now = api.launch_ui_name()
		local now_title = now
		for _, e in ipairs(uis) do
			if e.name == now then now_title = e.title end
		end
		local button = make_row(menu.window, "Launch UI: " .. now_title ..
				"  >")
		menu:add(button, function() show_launch_uis(uis, now) end)
	end

	menu:add("Back", function()
		uistack.main:pop(root)
	end)
	-- What a check waits for
	log:info("Engine settings shown")
end

-- **The keys** ([LAUNCH_MENU_V2] step 3): the client's own, the shared
-- names (most used first), and every app that declared its keys, each
-- action with its key and where that comes from. Enter on a row and then
-- a key binds it; Backspace on a row puts it back -- a shared name to
-- each app's own, an app's action to the shared or default key, a
-- client key to its default -- and Delete unbinds a client key (not the
-- overlay's, which the client refuses), giving it to the apps.
-- **One page for the launcher's Keys screen and a game's**
-- ([SETTINGS_KEYS_PAGE]): a game's is its own actions, the client's
-- Fullscreen and Screenshot, and Defaults. A key bound, reset or unbound
-- changes the rows' keys in place, so the view and the selection stay.
-- simplified: one list, not the plan's two tabs; a key the client keeps
-- cannot be captured here (no script hears it), so two client keys are
-- swapped through a free one.
local CLIENT_KEY_LABEL = {overlay = "Trusted overlay on and off",
	profiler = "The engine's profiler (Ctrl: physics geometry)",
	fullscreen = "Fullscreen on and off",
	screenshot = "A screenshot (Ctrl: the sandbox scan)"}
local CLIENT_KEYS_SHOWN = {fullscreen = "Fullscreen", screenshot = "Screenshot"}
-- A shared name's glyph, and so an app's action under it ([GLYPH_ICONS])
local KEY_GLYPH = {["move.forward"] = "↑", ["move.back"] = "↓",
	["move.left"] = "←", ["move.right"] = "→",
	jump = "⮝", sneak = "⮟", sprint = "⇛"}

-- The page's rows from the key store: {header = s}, or {label, glyph,
-- badge, set(key), reset(), unbind() or nil}, or {label, badge, run()}
-- for one pressed rather than bound. app_key: that app's page.
local function key_rows(store, app_key)
	local out = {}
	local function row(label, key, note, set, reset, unbind, glyph)
		out[#out + 1] = {label = label, glyph = glyph,
			badge = (key or "-") .. (note and "   " .. note or ""),
			set = set, reset = reset, unbind = unbind}
	end
	local function client()
		out[#out + 1] = {header = "This client's"}
		for _, c in ipairs(store.client) do
			if not app_key or CLIENT_KEYS_SHOWN[c.which] then
				row(CLIENT_KEY_LABEL[c.which] or c.which,
						c.key ~= "" and c.key or nil,
						c.key ~= c.default and "(default " .. c.default .. ")" or nil,
						function(k) return api.set_client_key(c.which, k) end,
						function() return api.set_client_key(c.which, c.default) end,
						function() return api.set_client_key(c.which, nil) end)
			end
		end
	end
	if not app_key then
		client()
		-- The shared names, by how many apps use them
		local users = {}
		for _, a in ipairs(store.apps) do
			for _, e in ipairs(a.actions) do
				if e.shared then users[e.shared] = (users[e.shared] or 0) + 1 end
			end
		end
		local names = {}
		for i, n in ipairs(store.shared_names) do names[i] = n end
		table.sort(names, function(x, y)
			if (users[x] or 0) ~= (users[y] or 0) then
				return (users[x] or 0) > (users[y] or 0)
			end
			return x < y
		end)
		out[#out + 1] = {header = "Shared, for every app that has not its own"}
		for _, n in ipairs(names) do
			row(n, store.shared[n], store.shared[n] == nil and
					"each app's own, used by " .. (users[n] or 0) or
					"used by " .. (users[n] or 0),
					function(k) return api.set_shared_key(n, k) end,
					function() return api.set_shared_key(n, nil) end, nil,
					KEY_GLYPH[n])
		end
	end
	for _, a in ipairs(store.apps) do
		if #a.actions > 0 and (not app_key or a.id == app_key) then
			out[#out + 1] = {header = a.label .. "   (" .. a.id .. ")"}
			for _, e in ipairs(a.actions) do
				row(e.label, e.key, e.from == "shared" and "shared " ..
						e.shared or e.from == "app" and "this app's" or nil,
						function(k) return api.set_app_keys(a.id, {[e.id] = k}) end,
						function()
							return api.set_app_keys(a.id, {[e.id] = false})
						end, nil, KEY_GLYPH[e.shared])
			end
			if app_key then
				out[#out + 1] = {label = "Defaults", badge = "every key of " ..
						a.label .. " as it came", run = function()
					local all = {}
					for _, e in ipairs(a.actions) do all[e.id] = false end
					return api.set_app_keys(a.id, all)
				end}
			end
		end
	end
	if app_key then
		client()
	end
	return out
end

-- The page in parent: a list_view, its wheel scrolling it, and a line
-- under it. page.items are {button, action} for a menu; page:key(key)
-- takes a key the menu does not (the bound one, Backspace, Delete, and
-- Escape while one is waited for) and answers whether it did; page.log
-- is what the log says first.
local function key_page(parent, width, height, app_key, options)
	options = options or {}
	local view = ui_utils.list_view(parent, width, height,
			{wheel = 40, follow_focus = options.follow_focus})
	local rows, headers = {}, {}
	for _, r in ipairs(key_rows(api.key_store(), app_key)) do
		if r.header then
			view:header(r.header)
			headers[#headers + 1] = r.header
		else
			local b, _, badge = view:row({label = r.label, glyph = r.glyph},
					r.badge)
			r.button, r.badge_text = b, badge
			rows[#rows + 1] = r
		end
	end
	view:fit()
	local line = parent:CreateChild("Text")
	line:SetStyleAuto()
	line:SetFontSize(13)
	line.color = magic.Color(ui_utils.rgb("dim"))
	line:SetFixedHeight(20)
	local page = {view = view, rows = rows, headers = headers, items = {},
		log = options.log or "launch_menu"}
	local function selected()
		for _, r in ipairs(rows) do
			if r.button:HasFocus() then return r end
		end
		return nil
	end
	-- After a change, every row's key read again where it is: a shared
	-- key changes the rows under it
	local function changed(what)
		local i = 0
		for _, r in ipairs(key_rows(api.key_store(), app_key)) do
			if not r.header then
				i = i + 1
				if rows[i] then rows[i].badge_text.text = r.badge end
			end
		end
		local sel = selected()
		-- What a check reads: the view and the selection as they were
		log:info(string.format("%s: %s; the view at %d, %s selected",
				page.log, what, -view.list.position.y,
				sel and sel.label or "none"))
	end
	local listening = nil
	-- The Enter that started a capture reaches the page's key after the
	-- button pressed itself on it; that one is not the key
	local enter_down = nil
	for i, r in ipairs(rows) do
		page.items[i] = {button = r.button, action = function()
			if r.run then
				local ok, why = r.run()
				changed(r.label .. (ok and "" or ": " .. tostring(why)))
				return
			end
			listening = r
			enter_down = magic.input:GetKeyDown(magic.KEY_RETURN) and
					magic.KEY_RETURN or
					magic.input:GetKeyDown(magic.KEY_KP_ENTER) and
					magic.KEY_KP_ENTER or nil
			line.text = "Press a key for \"" .. r.label ..
					"\" (Escape leaves it)"
			log:info(page.log .. ": " .. r.label .. " waits for a key")
		end}
	end
	function page:key(key)
		if listening and key == enter_down then
			enter_down = nil
			return true
		end
		if listening then
			local r = listening
			listening = nil
			line.text = ""
			if key ~= KEY_ESCAPE then
				local name = magic.input:GetKeyName(key)
				local ok, why = r.set(name)
				changed(r.label .. " = " .. name ..
						(ok and "" or ": " .. tostring(why)))
			end
			return true
		end
		local r = selected()
		if key == magic.KEY_BACKSPACE and r and r.reset then
			r.reset()
			changed(r.label .. " reset")
			return true
		end
		if key == magic.KEY_DELETE and r and r.unbind then
			local ok, why = r.unbind()
			if ok then
				changed(r.label .. " unbound")
			else
				line.text = tostring(why)
			end
			return true
		end
		return false
	end
	function page:waiting() return listening ~= nil end
	return page
end

-- The launcher's Keys screen (launch_menu's Settings, Controls)
function M.show_keys()
	local root = uistack.main:push({desc = "launch_menu keys"})
	root.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	local width = math.min(magic.ui.root.width - 40, 760)
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 8, magic.IntRect(16, 12, 16, 12))
	window:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
	window:SetFixedWidth(width)
	local heading = window:CreateChild("Text")
	heading:SetStyleAuto()
	heading.text = "Keys   (Enter and a key binds; Backspace resets)"
	heading:SetFontSize(20)
	heading.color = magic.Color(ui_utils.rgb("dim"))
	ui_utils.close_glyph(root, window)
	local page = key_page(window, width - 32, magic.ui.root.height - 200)
	local nav = ui_utils.bind_button_menu(root, page.items, function(key)
		if page:key(key) then
			return true
		end
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end, {wheel = false})
	nav:on_change(function(button, sel)
		if sel then page.view:show(button) end
	end)
	log:info("launch_menu: keys, " .. #page.rows .. " rows")
end

--
-- **A game's settings** ([GAME_SETTINGS], user 2026-10-09):
-- buildat.show_game_settings{} (client/api.lua) draws this over the game.
-- The client's code, so it sets what a game may not; the game's own code
-- runs only in its sections' draw(w, ui). From the top: the game's
-- sections, Sound, Video (with the web's own rows on the web), Keys (the
-- game's declared actions and two of the client's), those the builtins
-- added (accounts' Server), and Logs and errors.
--
local GAME_ROWS = {
	{"Sound", {"sound_volume_db", "sound_mute"}},
	{"Video", {"render_scale", "max_fps", "vsync", "multisampling",
		"ui_size", "web_address_bar", "screen_orientation", "web_idle_fps"}},
}
local game = nil

local function game_close(silent)
	if not game then
		return
	end
	local g = game
	game = nil
	magic.UnsubscribeFromEvent("KeyDown", g.key_sub)
	-- A leave with the window open took them already: forget_game_ui()
	-- runs before the sandbox reset that closes it ([VIEW_SETTINGS_LOCAL])
	pcall(function() g.backdrop:Remove() end)
	pcall(function() g.win:Remove() end)
	if not silent and g.o.on_close then
		g.o.on_close()
	end
end

-- o: on_close, sections; app_key: the key store's id of the game (nil
-- with none); extra: the builtins' sections
function M.show_game(o, app_key, extra)
	game_close(true)
	local root = magic.ui.root
	local g = {o = o}
	game = g
	-- **Black behind it, over the game's windows**, as builtin/accounts'
	-- Server window a game opens
	g.backdrop = root:CreateChild("BorderImage")
	g.backdrop.color = magic.Color(0, 0, 0, 1)
	g.backdrop.priority = 101
	g.backdrop:SetFixedSize(root.width, root.height)
	local win = root:CreateChild("Window")
	g.win = win
	-- Its own style, for a game whose root has none
	win.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	win:SetStyleAuto()
	win.priority = 102
	win:SetLayout(LM_VERTICAL, 8, magic.IntRect(12, 12, 12, 12))
	win:SetAlignment(HA_CENTER, magic.VA_CENTER)
	local width = math.min(620, root.width - 16)
	win:SetFixedSize(width, math.min(720, root.height - 16))
	local top = win:CreateChild("UIElement")
	top:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(0, 0, 0, 0))
	top:SetFixedHeight(28)
	local title = top:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Settings"
	title:SetFontSize(20)
	local view = win:CreateChild("ScrollView")
	view:SetStyleAuto()
	view.scrollBarsAutoVisible = true
	local page = view:CreateChild("UIElement")
	page:SetLayout(LM_VERTICAL, 8, magic.IntRect(4, 4, 8, 4))
	-- Less the window's border and the vertical bar
	local inner = width - 24 - 24
	page:SetFixedWidth(inner)
	view.contentElement = page

	local function text(parent, t, color, size)
		local l = parent:CreateChild("Text")
		l:SetStyleAuto()
		l:SetWordwrap(true)
		l:SetFixedWidth(inner - 12)
		l.text = t
		if size then l:SetFontSize(size) end
		if color then l.color = magic.Color(ui_utils.rgb(color)) end
		return l
	end
	local function button(parent, label, on_click)
		local b = make_row(parent, label)
		b.minWidth = 0
		b.minHeight = 28
		magic.SubscribeToEvent(b, "Released", function() on_click() end)
		return b
	end
	local function dropdown(parent, label, choices, current, on_choose)
		local list, at = {}, 1
		for i, c in ipairs(choices) do
			list[i] = {c[1], i}
			if c[2] == current then at = i end
		end
		return ui_utils.dropdown(parent, list, at, function(_, i)
			on_choose(choices[i][2])
		end, {label = label, label_width = math.floor(inner * 0.45),
			width = math.floor(inner * 0.5)})
	end
	-- Not on the stack, so its own on_close ([CLOSE_GLYPH])
	ui_utils.close_glyph(root, win, function() game_close() end)

	local shown = {}
	local function section(t, draw)
		-- The keys' page alone (show_game_keys) has none
		if o.keys_only then
			return
		end
		shown[#shown + 1] = t
		text(page, t, nil, 17)
		local w = page:CreateChild("UIElement")
		w:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
		local ui = {}
		ui.text = function(t2, color) return text(w, t2, color) end
		ui.button = function(label, f) return button(w, label, f) end
		ui.dropdown = function(label, choices, current, f)
			return dropdown(w, label, choices, current, f)
		end
		ui.toggle = function(label, on, f)
			return dropdown(w, label, {{"off", false}, {"on", true}},
					on == true, f)
		end
		-- Drawn again, after a change it shows
		ui.redraw = function()
			w:RemoveAllChildren()
			local ok, err = pcall(draw, w, ui)
			if not ok then
				log:warning("A settings section failed: " .. tostring(err))
				text(w, "This section failed: " .. tostring(err), "error")
			end
		end
		-- This window closed for another, which comes back to it with
		-- back() (accounts' Server window)
		ui.away = function(f)
			game_close(true)
			f(function() M.show_game(o, app_key, extra) end)
		end
		ui.redraw()
	end

	for _, sec in ipairs(o.sections or {}) do
		section(tostring(sec.title), sec.draw)
	end
	for _, group in ipairs(GAME_ROWS) do
		local rows = {}
		for _, name in ipairs(group[2]) do
			for _, pref in ipairs(PREFERENCES) do
				if pref.name == name and api.get_preference(name) ~= nil then
					rows[#rows + 1] = pref
				end
			end
		end
		section(group[1], function(w)
			for _, pref in ipairs(rows) do
				local choices = {}
				for i, v in ipairs(pref.values) do
					choices[i] = {show_value(pref, v), i}
				end
				dropdown(w, pref.label, choices,
						nearest_index(pref, api.get_preference(pref.name)),
						function(i)
					local ok, err = api.set_preference(pref.name, pref.values[i])
					if not ok then
						log:warning(pref.name .. ": " .. tostring(err))
					end
				end)
				local note = pref.note and pref.note()
				if note then
					text(w, note, "dim")
				end
			end
		end)
		for _, pref in ipairs(rows) do
			shown[#shown + 1] = pref.name
		end
	end

	-- **Keys**: a line and the button that opens them, as a page in this
	-- window ([SETTINGS_KEYS_PAGE]); Back comes back to this page as it
	-- was. The game reads its keys again in on_close.
	local function key_count()
		local store = api.key_store and api.key_store()
		for _, a in ipairs(store and store.apps or {}) do
			if a.id == app_key then
				local n = 0
				for _, e in ipairs(a.actions) do
					if e.key and e.key ~= "" then n = n + 1 end
				end
				return #a.actions, n
			end
		end
		return 0, 0
	end
	local acts = key_count()
	shown[#shown + 1] = acts .. " of the game's keys"
	local keys_button = nil
	section("Keys", function(w, ui)
		local all, bound = key_count()
		ui.text(bound .. " of the game's " .. all ..
				" keys bound, and the client's Fullscreen and Screenshot", "dim")
		keys_button = ui.button("Key bindings...", function() g.open_keys() end)
	end)
	for _, sec in ipairs(extra or {}) do
		section(tostring(sec.title), sec.draw)
	end

	-- [LOG_REACH]'s rows, for a tester mid-game
	section("Logs and errors", function(w)
		local path = api.log_path() or ""
		text(w, path ~= "" and "The log: " .. path or
				"No log file here: the browser's console (F12) has it.")
		local status = text(w, "", "dim")
		if path ~= "" then
			button(w, "Copy the path", function()
				ui_utils.copy(path)
				status.text = "The path is on the clipboard"
			end)
			if api.get_preference("web_address_bar") == nil then
				button(w, "Open the log folder", function()
					local ok, why = api.open_log_folder()
					status.text = ok and "Opened" or tostring(why)
				end)
			end
		end
		button(w, "Copy the last errors", function()
			ui_utils.copy(api.recent_errors() or "")
			status.text = "The last errors, with the version, are on the clipboard"
		end)
	end)

	-- The keys' page in place of the settings, Back to them
	function g.open_keys()
		view.visible = false
		title.text = "Keys"
		local box = win:CreateChild("UIElement")
		box:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
		local hint = text(box, "Enter and a key binds; Backspace resets", "dim")
		hint:SetFixedHeight(20)
		local page = key_page(box, inner, win.height - 150, app_key,
				{follow_focus = true, log = "Game keys"})
		for _, item in ipairs(page.items) do
			magic.SubscribeToEvent(item.button, "Released", item.action)
		end
		local back = button(box, "Back", function() g.close_keys() end)
		g.keys = {box = box, page = page}
		ui_utils.keyboard_page(box)
		if page.rows[1] then page.rows[1].button:SetFocus(true) end
		log:info("Game keys shown: " .. #page.rows .. " rows under " ..
				table.concat(page.headers, ", "))
	end
	function g.close_keys()
		if not g.keys then return end
		g.keys.box:Remove()
		g.keys = nil
		log:info("Game keys closed")
		if o.keys_only then
			game_close()
			return
		end
		view.visible = true
		title.text = "Settings"
		if keys_button then keys_button:SetFocus(true) end
	end

	ui_utils.keyboard_page(win)
	-- simplified: not the key that opened it again (the Escape that
	-- closed a window it went away for); a frame's time rather than a frame
	local opened = api.get_time_us()
	g.key_sub = magic.SubscribeToEvent("KeyDown", function(_, data)
		local key = data:GetInt("Key")
		if api.get_time_us() - opened < 100000 then
			return
		end
		if g.keys then
			if not g.keys.page:key(key) and key == KEY_ESCAPE then
				g.close_keys()
			end
			return
		end
		if key == KEY_ESCAPE and not ui_utils.dropdown_open() then
			game_close()
		end
	end)
	if o.keys_only then
		g.open_keys()
		return
	end
	-- What a check reads
	log:info("Game settings shown: " .. table.concat(shown, ", "))
end

-- The keys' page alone, in the same window ([SETTINGS_KEYS_PAGE]: a
-- game's own menu has a "Key bindings..." of its own); Back and Escape
-- close it, and o.on_close is where the game reads its keys again
function M.show_game_keys(o, app_key)
	M.show_game({on_close = o.on_close, keys_only = true}, app_key)
end

-- Closed by the game (it left, or its own key)
M.close_game = function() game_close(true) end

return M
-- vim: set noet ts=4 sw=4:
