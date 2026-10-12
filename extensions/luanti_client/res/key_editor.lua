-- Buildat: extensions/luanti_client/res/key_editor.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The key bindings editor both Luanti clients draw ([EXT_SETTINGS]):
-- apps/vanilla's keys.lua over its table saved in the launcher's settings,
-- and extensions/luanti_client over its own in settings.json. A row per
-- action with its key's name and what it does; a row picked (click, or
-- arrows and Enter) says "Press a key...", and the next key down binds it
-- -- Escape leaves it, Backspace puts the default back. A key bound on
-- two rows shows red on both, and the later bind stands. "Defaults" puts
-- every default back. Every change is saved at once.
--
-- Served by the luanti module as luanti/key_editor.lua for the sandbox
-- and dofile'd by the extension, so what it needs comes in the call:
--   draw{magic =, uistack =, ui_utils =, bindings = {{action, key, name,
--     what, default_key, default_name}, ...}, bindable = function(b),
--     save = function(), on_back = function()}
-- An entry with a key and a default_key is bindable unless bindable()
-- says otherwise; the rest are listed for the player's sake.
local M = {}

-- **The key store** ([LAUNCH_MENU_V2] step 3): the bindings declared
-- under app_id (a served game's id is its own, whatever is passed) with
-- the shared names in `shared` (action -> name), and the keys the store
-- resolves put in the table. What the editor calls a default becomes the
-- key without the app's override -- the shared one, else the default.
function M.declare(magic, app_id, label, bindings, bindable, shared)
	local actions = {}
	for _, b in ipairs(bindings) do
		-- The code's key by Urho3D's name for it: the table's names are
		-- for the player ("Shift" is "Left Shift")
		b.code_key = b.code_key or b.key
		if b.code_key ~= nil and b.default_key ~= nil and
				(bindable == nil or bindable(b)) then
			actions[#actions + 1] = {id = b.action, label = b.what,
				default = magic.input:GetKeyName(b.code_key),
				shared = shared[b.action]}
		end
	end
	local keys, base = buildat.declare_keys(app_id, label, actions)
	if type(keys) ~= "table" then
		return false
	end
	local function code(name)
		return name and magic.input:GetKeyFromName(name) or 0
	end
	for _, b in ipairs(bindings) do
		if keys[b.action] and code(keys[b.action]) ~= 0 then
			b.key, b.name = code(keys[b.action]), keys[b.action]
			if code(base[b.action]) ~= 0 then
				b.default_key = code(base[b.action])
				b.default_name = base[b.action]
			end
		end
	end
	return true
end

-- The editor's save: every bindable row's key as the app's, which the
-- store keeps only where it differs
function M.store(app_id, bindings, bindable)
	local map = {}
	for _, b in ipairs(bindings) do
		if b.default_key ~= nil and (bindable == nil or bindable(b)) then
			map[b.action] = b.name
		end
	end
	return buildat.set_app_keys(app_id, map)
end

function M.draw(o)
	local magic, uistack, ui_utils = o.magic, o.uistack, o.ui_utils
	local BINDINGS = o.bindings
	local function bindable(b)
		return b.default_key ~= nil and (o.bindable == nil or o.bindable(b))
	end
	local save, on_back = o.save, o.on_back
	local root = uistack.main:push({desc = "key bindings"})
	-- Over a game's HUD, such as the Luanti hotbar (priority 10)
	root.priority = 100
	root.defaultStyle = magic.cache:GetResource("XMLFile", "ui_utils/res/style.xml")
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local title = window:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText("Key bindings")
	local hint = window:CreateChild("Text")
	hint:SetStyleAuto()
	hint:SetText("Pick a row and press a key. Escape leaves it, Backspace puts the default back.")
	-- Two columns, so that the rows fit a 720 window ([BOX_FIXES] a): the
	-- buttons interleave left, right, left... which is the order the
	-- grid nav walks with two columns
	local columns = window:CreateChild("UIElement")
	columns:SetLayout(magic.LM_HORIZONTAL, 12, magic.IntRect(0, 0, 0, 0))
	local col = {}
	for c = 1, 2 do
		col[c] = columns:CreateChild("UIElement")
		col[c]:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	end
	local function make_button(parent, label)
		local button = parent:CreateChild("Button")
		button:SetStyleAuto()
		button:SetName("Button")
		button:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
		button.minHeight = 24
		button.minWidth = 380
		local text = button:CreateChild("Text")
		text:SetName("ButtonText")
		text:SetStyleAuto()
		text.text = label
		text:SetTextAlignment(magic.HA_LEFT)
		return button
	end
	local rows = {}
	local items = {}
	local listening = nil
	local function label_of(b)
		return string.format("%-8s  %s", b.name, b.what)
	end
	local function refresh()
		local seen = {}
		for _, b in ipairs(BINDINGS) do
			if bindable(b) then
				seen[b.key] = (seen[b.key] or 0) + 1
			end
		end
		for _, r in ipairs(rows) do
			local text = r.button:GetChild("ButtonText")
			if text then
				if listening == r.b then
					text.text = "Press a key...   " .. r.b.what
				else
					text.text = label_of(r.b)
				end
				local twice = bindable(r.b) and seen[r.b.key] and seen[r.b.key] > 1
				text.color = twice and magic.Color(1, 0.35, 0.35) or magic.Color(1, 1, 1)
			end
		end
	end
	for i, b in ipairs(BINDINGS) do
		local button = make_button(col[(i - 1) % 2 + 1], label_of(b))
		rows[#rows + 1] = {b = b, button = button}
		items[#items + 1] = {button, function()
			if bindable(b) then
				listening = b
				refresh()
			end
		end}
	end
	-- An odd count leaves the right column a row short; the two rows
	-- under the columns are a row of their own each, so the nav's index
	-- arithmetic stays on the grid: a blank fills the gap
	if #BINDINGS % 2 == 1 then
		local blank = col[2]:CreateChild("UIElement")
		blank.minHeight = 24
	end
	local bottom = window:CreateChild("UIElement")
	bottom:SetLayout(magic.LM_HORIZONTAL, 12, magic.IntRect(0, 0, 0, 0))
	local defaults = make_button(bottom, "Defaults")
	items[#items + 1] = {defaults, function()
		for _, b in ipairs(BINDINGS) do
			if bindable(b) then
				b.key, b.name = b.default_key, b.default_name
			end
		end
		listening = nil
		refresh()
		save()
	end}
	local back = make_button(bottom, "< back")
	items[#items + 1] = {back, function()
		uistack.main:pop(root)
		on_back()
	end}
	local nav = ui_utils.bind_button_menu(root, items)
	nav:set_columns(2)
	-- The key while a row listens, through the menu's own handler (which
	-- sees it before its navigation and its Escape = Back; true takes
	-- the key). Outside a capture Escape is Back, as on every screen
	-- ([BOX_PLAYTEST_2] 7).
	nav:on_key(function(key)
		if listening == nil then
			return false
		end
		local b = listening
		listening = nil
		if key == magic.KEY_ESCAPE then
			-- Leaves the row as it was
		elseif key == magic.KEY_BACKSPACE then
			b.key, b.name = b.default_key, b.default_name
			save()
		else
			local name = magic.input:GetKeyName(key)
			if name ~= nil and name ~= "" then
				b.key, b.name = key, name
				save()
			end
		end
		refresh()
		return true
	end)
	refresh()
	magic.input:SetMouseVisible(true, "the key bindings")
	return root
end

return M
-- vim: set noet ts=4 sw=4:
