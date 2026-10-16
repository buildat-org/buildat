-- Buildat: builtin/world_menu/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- builtin/world_menu's client half (api.h says what the menu is): the
-- world screen drawn out of vanilla's menu -- the worlds on the left as a
-- list with a filter, the selected one on the right, Play, Rename and
-- Delete. A row's click selects it; a second click plays. A rename (and
-- a new world, here) is a screen of its own, a name field and, for a new
-- one, the app's options.
--
-- Two ways in. The server opens it (core:run_script) and fills it
-- (world_menu:list), and an app's client has nothing of it. Or an app
-- with a menu of its own (vanilla) opens the screen itself:
--   local world_menu = require("buildat/module/world_menu")
--   world_menu.open(spec) -> {root, play}  -- the screen, its Play button
-- spec: title; worlds = {{name, label}} (label: the row and what the
-- filter reads, the name by default); selected (the menu writes it back,
-- and calls on_select(name)); empty (the text for no worlds); new_label;
-- play(name), new(), rename(name, to) (nil: no Rename), delete(name),
-- delete_text(name), delete_yes; play_label(name); back() (Escape and the
-- ×); push(kind) -> root, the app's own screen pushed for "worlds" and
-- "rename"; and what the app adds: footer(left) under the list,
-- under(add, left) after New, panel(add, right, name, head) before Play,
-- where add(label, action) is a button in the screen's keyboard walk.
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.safe or ui_utils
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local write_json = require("buildat/extension/network").write_json
local log = buildat.Logger("world_menu")

local M = {}
-- The module's own screen (the server's way in) and what the filter has
local own_root = nil
local filter = ""

-- The waiting screen's line, which a progress text replaces in place
local waiting_line = nil
local function close()
	if own_root then
		uistack.main:pop(own_root)
		own_root = nil
	end
	waiting_line = nil
end

local function own_push(kind)
	close()
	own_root = uistack.main:push({desc = "world menu: " .. kind})
	return own_root
end

-- **A width that fits the screen** (vanilla's, a phone): what the screen
-- asks for, or the screen's width less a margin; a narrow screen stacks
-- the two columns
function M.fit(px)
	return math.min(px, magic.ui.root.width - 40)
end
function M.narrow()
	return magic.ui.root.width < 1000
end
local fit, narrow = M.fit, M.narrow

local function text_on(parent, s, width)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(s)
	if width then
		t:SetWordwrap(true)
		t:SetFixedWidth(width)
	end
	return t
end

local function edit_on(parent, s)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself
	e.textCopyable = true
	e.textSelectable = true
	e.minHeight = 26
	e:SetText(s)
	return e
end

-- A menu button under any parent, in the menu's keyboard walk; main: the
-- screen's main button
local function button_on(menu, parent, label, action, width, main)
	local b = parent:CreateChild("Button")
	if main then b:SetStyle("PrimaryButton") else b:SetStyleAuto() end
	b:SetName("Button")
	b:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	-- Fixed: a vertical layout stretches an unfixed child
	b:SetFixedHeight(28)
	if width then
		b:SetFixedWidth(width)
	end
	local t = b:CreateChild("Text")
	t:SetName("ButtonText")
	t:SetStyleAuto()
	t:SetText(label)
	t:SetTextAlignment(magic.HA_CENTER)
	menu:add(b, action)
	return b
end

local function screen(spec, kind)
	local root = (spec.push or own_push)(kind)
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	return menu, root
end

local function on_escape(menu, root, fn)
	menu:on_key(function(key)
		if key == magic.KEY_ESCAPE and magic.input:GetKeyPress(key) then
			fn()
			return true
		end
	end)
	ui_utils.close_glyph(root, menu.window, fn)
end

-- Does this line answer what was typed? Case-insensitive, every word in
-- it somewhere, and a plain find: a world named "world (2)" is a name and
-- not a pattern.
function M.matches(label, filter)
	label = label:lower()
	for word in filter:lower():gmatch("%S+") do
		if not label:find(word, 1, true) then
			return false
		end
	end
	return true
end
assert(M.matches("caves (voxelibre)", "VOX cave") and
		M.matches("world (2)", "world (2)") and not M.matches("world", "x"),
		"world_menu: the filter")

-- Whole MB, 1000000 bytes: --max-disk-mb's unit
function M.mb(bytes)
	return string.format("%d MB", math.floor((bytes + 500000) / 1000000))
end

-- A world's new name
local function draw_rename(spec, name)
	local menu, root = screen(spec, "rename")
	text_on(menu.window, "Rename " .. name .. " to:")
	-- Empty: what is typed is the whole name
	local edit = edit_on(menu.window, "")
	local function ok()
		local to = edit:GetText():match("^%s*(.-)%s*$")
		if to == "" or to == name then
			return
		end
		log:info("world_menu: rename " .. name .. " to " .. to)
		spec.selected = to
		spec.rename(name, to)
	end
	menu:add("Rename", ok, true)
	menu:add("Back", function() M.open(spec) end)
	on_escape(menu, root, function() M.open(spec) end)
	edit:SetFocus(true)
	magic.input:SetMouseVisible(true, "a menu screen")
	log:info("world_menu: the name screen shown")
end

function M.open(spec)
	local menu, root = screen(spec, "worlds")
	text_on(menu.window, spec.title)
	local columns = menu.window:CreateChild("UIElement")
	columns:SetLayout(narrow() and magic.LM_VERTICAL or magic.LM_HORIZONTAL,
			16, magic.IntRect(0, 0, 0, 0))
	local left = columns:CreateChild("UIElement")
	left:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(fit(520))
	local right = columns:CreateChild("UIElement")
	right:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	right:SetFixedWidth(fit(420))

	local shown, found = {}, false
	for _, w in ipairs(spec.worlds) do
		if M.matches(w.label or w.name, filter) then
			shown[#shown + 1] = w
			found = found or w.name == spec.selected
		end
	end
	local function select(name)
		spec.selected = name
		if spec.on_select then
			spec.on_select(name)
		end
	end
	if spec.selected and not found then
		select(nil)
	end
	-- simplified: the filter applies on Enter (TextChanged is not in the
	-- sandbox's events) and the screen is drawn again
	text_on(left, filter ~= "" and ("filter (enter to apply): " .. #shown ..
			" of " .. #spec.worlds .. " shown") or
			("filter (enter to apply), " .. #spec.worlds .. " in the list:"))
	local edit = edit_on(left, filter)
	magic.SubscribeToEvent(edit, "TextFinished", function()
		filter = edit:GetText()
		M.open(spec)
		-- What a check waits for: the list drawn again under it
		log:info("world_menu: filtered by \"" .. filter .. "\"")
	end)
	local list = left:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(520), narrow() and
			math.max(100, math.floor(magic.ui.root.height * 0.18)) or 520)
	local rows = {}
	for _, w in ipairs(shown) do
		local row = list.contentElement:CreateChild("Button")
		row:SetStyleAuto()
		row:SetName("Button")
		row:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(8, 0, 8, 0))
		row:SetFixedWidth(fit(520) - 24)
		row.minHeight = 28
		local t = row:CreateChild("Text")
		t:SetName("ButtonText")
		t:SetStyleAuto()
		t:SetText(w.label or w.name)
		t:SetTextAlignment(magic.HA_LEFT)
		rows[w.name] = row
		menu:add(row, function()
			if spec.selected == w.name then
				spec.play(w.name)
			else
				select(w.name)
				M.open(spec)
			end
		end)
		list:AddItem(row)
	end
	if #shown == 0 then
		text_on(left, #spec.worlds == 0 and (spec.empty or "No worlds yet") or
				"Nothing matches")
	end
	if spec.footer then
		spec.footer(left)
	end
	local function add_left(label, action)
		return button_on(menu, left, label, action, fit(520))
	end
	add_left(spec.new_label or "New world...", spec.new)
	if spec.under then
		spec.under(add_left, left)
	end
	on_escape(menu, root, spec.back or function() buildat.leave() end)

	-- The right column: the selected world and what it does
	local head = text_on(right, spec.selected or (narrow() and
			"Pick a world above" or "Pick a world on the left"))
	local out = {root = root}
	if spec.selected then
		local name = spec.selected
		local function add_right(label, action, main)
			return button_on(menu, right, label, action, fit(420), main)
		end
		if spec.panel then
			spec.panel(add_right, right, name, head)
		end
		out.play = add_right(spec.play_label and spec.play_label(name) or
				"Play", function() spec.play(name) end, true)
		if spec.rename then
			add_right("Rename...", function() draw_rename(spec, name) end)
		end
		add_right("Delete...", function()
			ui_utils.show_confirm_dialog(spec.delete_text and
					spec.delete_text(name) or ("Delete the world " .. name ..
					"? It cannot be undone."), function()
				log:info("world_menu: delete " .. name)
				select(nil)
				spec.delete(name)
			end, function() end, spec.delete_yes or "Delete", "Keep")
		end)
		-- The selected row in view and in focus
		if rows[name] then
			list:SetSelection(list:FindItem(rows[name]))
			rows[name]:SetFocus(true)
		end
	end
	magic.input:SetMouseVisible(true, "a menu screen")
	-- What a check waits for
	log:info("world_menu: the list shown, " .. #spec.worlds .. " worlds")
	return out
end

--
-- The server's way in
--

local function waiting(message)
	if waiting_line and own_root then
		waiting_line:SetText(message)
		return
	end
	local root = own_push("waiting")
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	waiting_line = text_on(menu.window, message)
	-- And the seconds under it, so the screen moves while the user can
	-- only wait ([FIRST_RUN]: a screen still for 4 s fails a driven run)
	local secs = text_on(menu.window, "")
	local t0 = buildat.get_time_us()
	root:SubscribeToStackEvent("Update", function()
		secs:SetText(math.floor((buildat.get_time_us() - t0) / 1000000) .. " s")
	end)
	menu:add("Leave the game", function() buildat.leave() end)
	magic.input:SetMouseVisible(true, "a menu screen")
end

local function send(name, t)
	buildat.send_packet("world_menu:" .. name, write_json(t))
end

-- The server's list as a spec, and the selection kept across lists
local served = {}

-- A new world's name and the app's options
local function draw_new(state)
	local menu, root = screen(served, "new world")
	text_on(menu.window, state.title .. ": a new world, named:")
	local name = edit_on(menu.window, #state.worlds == 0 and "world" or "")
	local fields = {}
	for _, f in ipairs(state.fields) do
		text_on(menu.window, f.label .. ((f.hint or "") ~= "" and
				" (" .. f.hint .. ")" or "") .. ":")
		fields[f.key] = edit_on(menu.window, f.default or "")
	end
	local function ok()
		local n = name:GetText():match("^%s*(.-)%s*$")
		if n == "" then
			return
		end
		local options = {}
		for key, e in pairs(fields) do
			options[key] = e:GetText():match("^%s*(.-)%s*$")
		end
		log:info("world_menu: create " .. n)
		served.selected = n
		send("create", {name = n, options = options})
		waiting("Creating " .. n .. "...")
	end
	menu:add("Create", ok, true)
	menu:add("Back", function() M.open(served) end)
	on_escape(menu, root, function() M.open(served) end)
	name:SetFocus(true)
	magic.input:SetMouseVisible(true, "a menu screen")
	log:info("world_menu: the name screen shown")
end

buildat.sub_packet("world_menu:list", function(data)
	local state = buildat.parse_json(data)
	if not state.may_pick then
		local text = (state.wait or "") ~= "" and state.wait or
				"Waiting for the host to pick a world"
		waiting(text)
		log:info("world_menu: the wait shown: " .. text)
		return
	end
	state.fields = state.fields or {}
	state.worlds = state.worlds or {}
	local by_name = {}
	for _, w in ipairs(state.worlds) do
		by_name[w.name] = w
	end
	served.title = state.title .. ": which world?"
	served.worlds = state.worlds
	served.play = function(name)
		log:info("world_menu: play " .. name)
		send("play", {name = name})
		waiting("Loading " .. name .. "...")
	end
	served.new = function() draw_new(state) end
	served.rename = function(name, to)
		send("rename", {name = name, to = to})
		waiting("Renaming " .. name .. "...")
	end
	served.delete = function(name)
		send("delete", {name = name})
		waiting("Deleting " .. name .. "...")
	end
	served.under = function(add)
		add("Leave the game", function() buildat.leave() end)
	end
	-- Its size and the options it was made with
	served.panel = function(add, right, name)
		local w = by_name[name]
		text_on(right, "On disk: " .. M.mb(w.bytes or 0))
		for _, f in ipairs(state.fields) do
			local v = w.options and w.options[f.key]
			if v then
				text_on(right, f.label .. ": " .. v, fit(420))
			end
		end
	end
	M.open(served)
end)

buildat.sub_packet("world_menu:up", function()
	close()
end)

return M
-- vim: set noet ts=4 sw=4:
