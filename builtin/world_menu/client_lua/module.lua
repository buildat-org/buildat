-- Buildat: builtin/world_menu/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- builtin/world_menu's client half (api.h says what the menu is). The
-- server opens it (core:run_script) and fills it (world_menu:list); an
-- app's client has nothing of it. vanilla's world screen, drawn out of
-- apps/vanilla/main/client_lua/menu.lua: the worlds on the left as a list
-- with a filter, the selected one on the right with its options, Play,
-- Rename and Delete. A row's click selects it; a second click plays.
-- A new world and a rename are a screen of their own, a name field and,
-- for a new one, the app's options.
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.safe or ui_utils
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local write_json = require("buildat/extension/network").write_json
local log = buildat.Logger("world_menu")

local M = {}
local root = nil
-- The last world_menu:list, the selected world and what the filter has
local state = nil
local selected = nil
local filter = ""

local function close()
	if root then
		uistack.main:pop(root)
		root = nil
	end
end

local function send(name, t)
	buildat.send_packet("world_menu:" .. name, write_json(t))
end

-- **A width that fits the screen** (vanilla's, a phone): what the screen
-- asks for, or the screen's width less a margin; a narrow screen stacks
-- the two columns
local function fit(px)
	return math.min(px, magic.ui.root.width - 40)
end
local function narrow()
	return magic.ui.root.width < 1000
end

local function screen(desc)
	close()
	root = uistack.main:push({desc = "world menu: " .. desc})
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	return menu
end

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

local function on_escape(menu, fn)
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

local function waiting(message)
	local menu = screen("waiting")
	text_on(menu.window, message)
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

local draw

-- A new world's name and the app's options, or a world's new name
local function draw_name(rename)
	local menu = screen(rename and "rename" or "new world")
	text_on(menu.window, rename and ("Rename " .. rename .. " to:") or
			(state.title .. ": a new world, named:"))
	-- A rename's field starts empty: what is typed is the whole name
	local name = edit_on(menu.window, not rename and #state.worlds == 0 and
			"world" or "")
	local fields = {}
	if not rename then
		for _, f in ipairs(state.fields) do
			text_on(menu.window, f.label .. ((f.hint or "") ~= "" and
					" (" .. f.hint .. ")" or "") .. ":")
			fields[f.key] = edit_on(menu.window, f.default or "")
		end
	end
	local function ok()
		local n = name:GetText():match("^%s*(.-)%s*$")
		if n == "" or n == rename then
			return
		end
		if rename then
			log:info("world_menu: rename " .. rename .. " to " .. n)
			selected = n
			send("rename", {name = rename, to = n})
			waiting("Renaming " .. rename .. "...")
			return
		end
		local options = {}
		for key, e in pairs(fields) do
			options[key] = e:GetText():match("^%s*(.-)%s*$")
		end
		log:info("world_menu: create " .. n)
		send("create", {name = n, options = options})
		waiting("Creating " .. n .. "...")
	end
	menu:add(rename and "Rename" or "Create", ok, true)
	menu:add("Back", draw)
	on_escape(menu, draw)
	name:SetFocus(true)
	magic.input:SetMouseVisible(true, "a menu screen")
	log:info("world_menu: the name screen shown")
end

function draw()
	if not state.may_pick then
		waiting("Waiting for the host to pick a world")
		log:info("world_menu: the wait shown")
		return
	end
	local menu = screen("worlds")
	text_on(menu.window, state.title .. ": which world?")
	local columns = menu.window:CreateChild("UIElement")
	columns:SetLayout(narrow() and magic.LM_VERTICAL or magic.LM_HORIZONTAL,
			16, magic.IntRect(0, 0, 0, 0))
	local left = columns:CreateChild("UIElement")
	left:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(fit(520))
	local right = columns:CreateChild("UIElement")
	right:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	right:SetFixedWidth(fit(420))

	local shown, by_name = {}, {}
	for _, w in ipairs(state.worlds) do
		by_name[w.name] = w
		if M.matches(w.name, filter) then
			shown[#shown + 1] = w
		end
	end
	if not by_name[selected or ""] then
		selected = nil
	end
	-- simplified: the filter applies on Enter (TextChanged is not in the
	-- sandbox's events), as vanilla's
	text_on(left, filter ~= "" and ("filter (enter to apply): " .. #shown ..
			" of " .. #state.worlds .. " shown") or
			("filter (enter to apply), " .. #state.worlds .. " in the list:"))
	local edit = edit_on(left, filter)
	magic.SubscribeToEvent(edit, "TextFinished", function()
		filter = edit:GetText()
		draw()
	end)
	local list = left:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(520), narrow() and
			math.max(100, math.floor(magic.ui.root.height * 0.18)) or 400)
	local function play(name)
		log:info("world_menu: play " .. name)
		send("play", {name = name})
		waiting("Loading " .. name .. "...")
	end
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
		t:SetText(w.name)
		t:SetTextAlignment(magic.HA_LEFT)
		rows[w.name] = row
		menu:add(row, function()
			if selected == w.name then
				play(w.name)
			else
				selected = w.name
				draw()
			end
		end)
		list:AddItem(row)
	end
	if #shown == 0 then
		text_on(left, #state.worlds == 0 and "No worlds yet" or
				"Nothing matches")
	end
	button_on(menu, left, "New world...", function() draw_name(nil) end,
			fit(520))
	button_on(menu, left, "Leave the game", function() buildat.leave() end,
			fit(520))
	on_escape(menu, function() buildat.leave() end)

	-- The right column: the selected world, its options, what it does
	text_on(right, selected or (narrow() and "Pick a world above" or
			"Pick a world on the left"))
	if selected then
		local w = by_name[selected]
		text_on(right, "On disk: " .. M.mb(w.bytes or 0))
		for _, f in ipairs(state.fields) do
			local v = w.options and w.options[f.key]
			if v then
				text_on(right, f.label .. ": " .. v, fit(420))
			end
		end
		button_on(menu, right, "Play", function() play(selected) end,
				fit(420), true)
		button_on(menu, right, "Rename...", function()
			draw_name(selected)
		end, fit(420))
		button_on(menu, right, "Delete...", function()
			local name = selected
			ui_utils.show_confirm_dialog("Delete the world " .. name ..
					"? It cannot be undone.", function()
				log:info("world_menu: delete " .. name)
				selected = nil
				send("delete", {name = name})
				waiting("Deleting " .. name .. "...")
			end, nil, "Delete", "Keep")
		end, fit(420))
		if rows[selected] then
			list:SetSelection(list:FindItem(rows[selected]))
			rows[selected]:SetFocus(true)
		end
	end
	magic.input:SetMouseVisible(true, "a menu screen")
	-- What a check waits for
	log:info("world_menu: the list shown, " .. #state.worlds .. " worlds")
end

buildat.sub_packet("world_menu:list", function(data)
	state = buildat.parse_json(data)
	state.fields = state.fields or {}
	state.worlds = state.worlds or {}
	draw()
end)

buildat.sub_packet("world_menu:up", function()
	close()
end)

return M
-- vim: set noet ts=4 sw=4:
