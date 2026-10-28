-- Buildat: extension/uistack/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/uistack")
local magic_sandbox = require("buildat/core/magic_sandbox")
local magic = require("buildat/core/urho3d").safe
local dump = buildat.dump
local M = {safe = {}}
log:info("extension/uistack/init.lua: Loading")

-- Inherit a thing from UIElement to be used as roots in the stack. UIStack
-- wants to add additional fields to each instance, and that can only be done to
-- inherited classes in the sandbox.
magic_sandbox.safe.class "UIStackElement" (magic.UIElement)
local UIStackElement = __buildat_sandbox_environment.UIStackElement
UIStackElement.HasRecursiveFocus = {}
UIStackElement.SubscribeToStackEvent = {}
assert(UIStackElement)
-- An entry's SubscribeToStackEvent subscriptions, dropped by its pop:
-- element -> {{event_name =, cb_name =}, ...}. Kept here and not on the
-- element, which the script holds and writes ([SAFE_UNSUB_FOREIGN]): a
-- name it put in the list was unsubscribed by this code, the client's
-- own handlers included.
local stack_subscriptions = setmetatable({}, {__mode = "k"})
local unsubscribe = require("buildat/core/urho3d").unsafe.UnsubscribeFromEvent

local ui_stack_name_i = 1  -- For generating a unique name for each stack
-- [TAP_BACK] The entries pushed with {tap_outside = false}: a world's own
-- layer, where a click on nothing is the game's
local no_tap_outside = setmetatable({}, {__mode = "k"})
-- **Where the focus was in an entry when one was pushed over it**: a
-- path of child indices from the entry's element, so that its pop puts
-- the focus, and with it a menu's selection, back where it was. Indices
-- rather than the element: one removed meanwhile is then not reached,
-- the walk just stops short.
local focus_paths = setmetatable({}, {__mode = "k"})
local function focus_path(entry)
	local top = getmetatable(entry).unsafe
	local f = ui:GetFocusElement()
	local path = {}
	while f and f ~= top do
		local parent = f:GetParent()
		local at
		for i = 0, parent and parent:GetNumChildren() - 1 or -1 do
			if parent:GetChild(i) == f then at = i break end
		end
		if not at then return nil end
		table.insert(path, 1, at)
		f = parent
	end
	return f and path or nil
end
local function refocus(entry)
	local e = entry
	for _, i in ipairs(focus_paths[entry] or {}) do
		local child = e:GetChild(i)
		if not child then break end
		e = child
	end
	e:SetFocus(true)
end
-- The main stack's depth to the web page's Back (index.html)
local function depth_changed(stack)
	if stack == M.main then
		buildat.set_back_depth(#stack.stack)
	end
end
local last_stack_with_pushed_element = nil

-- Root can be a sandboxed or non-sandboxed element
-- Whether a wrapper's element has been removed under it: magic_sandbox
-- marks every wrapper of a removed UIElement, and reaching one raises
local function element_gone(e)
	local m = getmetatable(e)
	return m == nil or m.dead ~= nil
end

function M.UIStack(root)
	if not getmetatable(root) or not getmetatable(root).unsafe then
		error("UIStack can only be used with a sandboxed root")
	end
	local self = {}
	self.is_ui_stack = true
	self.root = root
	self.stack_name = "ui_stack_"..ui_stack_name_i
	ui_stack_name_i = ui_stack_name_i + 1
	self.element_name_i = 1
	self.stack = {}
	local current_ui_stack_object = self
	function self:push(options)
		if type(self) ~= 'table' or not self.is_ui_stack then
			error("self is not an instance of UIStack")
		end

		-- The caller's: on the web's Lua 5.1 the sandbox's method wrapper
		-- (sandbox.lua, shown()) tail-calls this, so level 2 is a "tail
		-- call" with no environment and the caller is one further out
		local level = debug.getinfo(2, "S").what == "tail" and 3 or 2
		local is_in_sandbox = getfenv(level).buildat.is_in_sandbox

		if type(options) == "string" then options = {desc = options} end
		options = options or {}
		-- **An entry whose element has gone is dropped** ([LEAVE_POP]):
		-- a sandbox reset removes the elements under the stack's
		-- entries, and reaching one of them raises ([UI_UAF]'s guard,
		-- which is right). Hiding a dead top on the way to drawing a
		-- new screen ended the client (2026-09-25, the exploit hunt's
		-- own result dialog).
		while #self.stack >= 1 and element_gone(self.stack[#self.stack]) do
			table.remove(self.stack)
			log:warning("UIStack:push(): an element below was already gone")
		end
		if #self.stack >= 1 then
			local top = self.stack[#self.stack]
			focus_paths[top] = focus_path(top)
			top:SetVisible(false)
		end
		local element_name =
				self.stack_name.."_"..#self.stack.."."..self.element_name_i
		-- desc is what every caller passes; description was the name here
		-- and no push ever carried one
		local description = options.description or options.desc
		if description then
			element_name = element_name..": "..description
		end
		log:verbose("UIStack:push(): "..dump(element_name))

		-- Create element and cast it to UIStackElement with unsafe magic
		local element = self.root:CreateChild("UIElement")
		local unsafe_element = getmetatable(element).unsafe
		element = getmetatable(UIStackElement).wrap(unsafe_element)

		element:SetName(element_name)
		element:SetStyleAuto()
		element:SetLayout(magic.LM_HORIZONTAL, 0, magic.IntRect(0, 0, 0, 0))
		element:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		element:SetFocusMode(magic.FM_FOCUSABLE)
		element:SetFocus(true)
		self.element_name_i = self.element_name_i + 1

		-- Add a recursive version of UIElement::HasFocus() to the pushed root
		-- element which also handles the "no focus" situation as expected
		local function has_plain_recursive_focus(self)
			if self:HasFocus() then return true end
			local n = self:GetNumChildren()
			for i = 0, n-1 do
				local child = self:GetChild(i)
				-- nil for the client's own hidden UI
				local child_has_focus = child and has_plain_recursive_focus(child)
				if child_has_focus then return true end
			end
			return false
		end
		function element.HasRecursiveFocus(self)
			-- If focused element is nil, then assume focus is owned by the
			-- stack on which an element was pushed latest
			local focused_element = ui:GetFocusElement()
			if focused_element == nil then
				if last_stack_with_pushed_element == current_ui_stack_object then
					-- It is this stack; check if self is the top element
					local top = current_ui_stack_object.stack[#current_ui_stack_object.stack]
					if top == self then
						-- Pass
						return true
					end
				end
				return false
			end
			-- Check that self exists as some of this stack's elements. If not,
			-- it is invalid and running HasFocus() on it will cause a segfault.
			local found = false
			for _, k in ipairs(current_ui_stack_object.stack) do
				if k == self then
					found = true
					break
				end
			end
			if not found then
				log:verbose("HasRecursiveFocus called for removed element "..
						dump(self:GetName()).."; ignoring")
				-- Not returning here will cause a NULL dereference in Urho3D
				-- once the garbage collector kicks in
				return
			end
			-- Non-special case
			return has_plain_recursive_focus(self)
		end

		-- Subscribe to event until this stack level is popped out
		local subscriptions = {}
		stack_subscriptions[element] = subscriptions
		function element:SubscribeToStackEvent(event_name, callback)
			local cb_name = magic.SubscribeToEvent(event_name,
			function(event_type, event_data)
				if not element:HasRecursiveFocus() then
					return
				end
				-- A key a dropdown took this frame (ui_utils.dropdown's
				-- Escape, which closed its popup)
				if M.key_taken and event_name == "KeyDown" and
						event_data:GetInt("Key") == M.key_taken then
					return
				end
				callback(event_type, event_data)
			end)
			table.insert(subscriptions, {
				event_name = event_name,
				cb_name = cb_name
			})
		end

		table.insert(self.stack, element)
		last_stack_with_pushed_element = self
		if options.tap_outside == false then
			no_tap_outside[element] = true
		end
		depth_changed(self)
		return element
	end
	-- Everything above `root` popped, top down, root itself included when
	-- inclusive; the launcher leaving a menu-only game ([MENU_CONTEXT])
	-- The top entry, or nil. A sandboxed caller sees self.stack through a
	-- read-only view, whose # is 0 on Lua 5.1 (no __len for tables), so
	-- stack[#stack] there was always nil ([LUANTI_NO_WORLD])
	function self:top()
		return self.stack[#self.stack]
	end
	function self:pop_to(root, inclusive)
		while #self.stack > 0 do
			local top = self.stack[#self.stack]
			if top == root and not inclusive then
				return
			end
			self:pop(top)
			if top == root then
				return
			end
		end
	end
	function self:pop(current_top_root)
		if type(self) ~= 'table' or not self.is_ui_stack then
			error("self is not an instance of UIStack")
		end
		-- This check should keep things better in sync
		if self.stack[#self.stack] ~= current_top_root then
			-- Both named: which window is in the way says how it got there
			local function name(e)
				local ok, n = pcall(function() return e:GetName() end)
				return ok and tostring(n) or tostring(e)
			end
			error("UIStack:pop(): Wrong current_top_root: asked to pop \"" ..
					name(current_top_root) .. "\", the top is \"" ..
					name(self.stack[#self.stack]) .. "\"")
		end
		-- **An entry whose element has gone is dropped, not raised on**
		-- ([LEAVE_POP], 2026-09-25): a sandbox reset removes the
		-- elements under the stack's entries, and reaching one from the
		-- sandbox afterwards raises ([UI_UAF]'s guard, which is right
		-- and stays) -- inside a leave_app, where everything after the
		-- pop then never runs and the player is left with a button that
		-- does nothing. A removed element needs no unsubscribing and no
		-- reparenting; it needs taking off the stack.
		if element_gone(self.stack[#self.stack]) then
			table.remove(self.stack)
			log:warning("UIStack:pop(): the top element was already gone")
			if #self.stack >= 1 and not element_gone(self.stack[#self.stack]) then
				local below = self.stack[#self.stack]
				below:SetVisible(true)
				below:SetFocus(true)
			end
			depth_changed(self)
			return
		end
		local top = table.remove(self.stack)
		log:verbose("UIStack:pop(): "..dump(top:GetName()))
		for _, sub in ipairs(stack_subscriptions[top] or {}) do
			unsubscribe(sub.event_name, sub.cb_name)
		end
		stack_subscriptions[top] = nil
		--top:SetVisible(false)
		--top:SetFocus(false)
		self.root:RemoveChild(top)
		if #self.stack >= 1 then
			local top = self.stack[#self.stack]
			top:SetVisible(true)
			refocus(top)
		end
		depth_changed(self)
	end
	return self
end

M.safe.UIStack = M.UIStack

-- Main UIStack instance

M.main = M.safe.UIStack(magic.ui.root)
M.safe.main = M.main

-- **A tap or click on nothing is Back** ([TAP_BACK]): Escape, so each
-- screen goes back the way its Escape does, and a touchscreen, which has
-- no Escape, gets out of every menu. Not on the first screen, which has
-- nothing under it (Escape there is Quit), and not on an entry pushed with
-- {tap_outside = false}. "Nothing" is what Urho3D's own click found: no
-- enabled element there. The cursor hidden (a game holding the mouse),
-- there is no UIMouseClick.
magic.SubscribeToEvent("UIMouseClick", function(event_type, event_data)
	local stack = M.main.stack
	local top = stack[#stack]
	if #stack < 2 or no_tap_outside[top] or element_gone(top) then
		return
	end
	if ui:GetElementAt(IntVector2(event_data:GetInt("X"),
			event_data:GetInt("Y")), true) ~= nil then
		return
	end
	log:verbose("UIStack: a click on nothing; Back")
	buildat.press_back()
end)
-- The same Back for a screen's × ([CLOSE_GLYPH]), drawn by ui_utils,
-- which runs sandboxed too: closing the top screen is what a tap beside
-- it does already
function M.safe.press_back()
	buildat.press_back()
end
M.press_back = M.safe.press_back
-- Set by whoever answers `event scan` for the world (vanilla's scan.lua),
-- so the menu's answer below stands aside once it is there
-- A key taken for the rest of its frame: ui_utils.dropdown's Escape, which
-- closed its popup, is not the screen's
M.key_taken = nil
function M.safe.take_key(key)
	M.key_taken = key
	__buildat_take_key(key)
end
magic.SubscribeToEvent("Update", function()
	M.key_taken = nil
	__buildat_take_key(nil)
end)

M.world_scan = false
-- An element outside the stack that a scan should walk too: a client that
-- draws its world UI on the UI root rather than on its screen (the Luanti
-- client extension's forms) puts its window here while it is up, so a
-- driven run can find what is on the screen ([FORMSPEC_SCROLL]'s check
-- wanted the form's own elements)
M.scan_extra = nil
function M.set_scan_extra(element)
	M.scan_extra = element
end
M.safe.set_scan_extra = M.set_scan_extra
function M.safe.set_world_scan(on)
	M.world_scan = on and true or false
end

-- The focused element's line of a scan, and a field's cursor and selection
local function focus_line(label, lines)
	local ui_utils = require("buildat/extension/ui_utils").safe
	local focus = magic.ui.focusElement
	if focus then
		local at = focus.screenPosition
		local x, y, w, h = ui_utils.scan_pixels(at.x, at.y, focus.width, focus.height)
		local text = ""
		pcall(function() text = focus:GetText() end)
		-- A field's cursor and selection, wherever it is ([TEXT_KEYS])
		local field = ""
		pcall(function()
			if focus:GetTypeName() == "LineEdit" then
				field = string.format(" cursor %d selection %d+%d",
						focus.cursorPosition, focus.textElement.selectionStart,
						focus.textElement.selectionLength)
			end
		end)
		lines[#lines + 1] = string.format("scan %s: focus %s at %d,%d size %dx%d text %s%s",
				label, focus:GetTypeName(), x, y, w, h, dump(text), field)
	else
		lines[#lines + 1] = string.format("scan %s: focus none", label)
	end
end

-- `event scan <res> <label>` on a menu screen ([FIRST_RUN]): the screen on
-- top of the main stack by its name, every element under it with its
-- rectangle and text (ui_utils.scan_ui, the lines a form gives), and
-- which element has the focus -- a field being typed into is "waiting
-- for input" to a driver. The world's own scan (vanilla's scan.lua)
-- answers the same event with the world; an empty top -- the stack's
-- placeholder while a game runs -- gives nothing here.
do
	magic.SubscribeToEvent("command_seq:scan", function(event_type, event_data)
		local top = M.main.stack[#M.main.stack]
		-- The stack's placeholder while a game runs has no children and
		-- the world's scan answers then; between two screens the top is
		-- empty for a moment too, and that gets an answer of its name
		-- alone, so a driver's read does not time out on the gap
		-- With no screen at all (a game's own UI, Hearth's), the field in
		-- focus alone, for a check of the text keys ([TEXT_KEYS])
		if top == nil then
			local f = magic.ui.focusElement
			if f and f:GetTypeName() == "LineEdit" then
				local label = (event_data:GetString("Param") or ""):match("^%d*%s*(%S+)") or "scan"
				local lines = {}
				focus_line(label, lines)
				log:info(table.concat(lines, "\n"))
			end
			return
		end
		-- The launcher's placeholder while a game runs: the world's scan
		-- answers once vanilla's client half is up, and until then this
		-- does, with the name alone, so a scan in the gap is not lost
		if top:GetName():find("game is running", 1, true) and M.world_scan then
			return
		end
		-- Required here and not above: ui_utils requires this file
		local ui_utils = require("buildat/extension/ui_utils").safe
		local param = event_data:GetString("Param") or ""
		local _, label = param:match("^(%d*)%s*(%S*)")
		if label == nil or label == "" then
			label = "scan"
		end
		local lines = {}
		lines[#lines + 1] = string.format("scan %s: menu %s", label,
				dump(top:GetName()))
		local lw, lh = buildat.logical_size()
		lines[#lines + 1] = string.format("scan %s: frame %dx%d root %dx%d ui_scale %.3f",
				label, lw, lh, magic.ui.root.width, magic.ui.root.height,
				magic.ui:GetScale() or 0)
		-- Whether the cursor is the player's to point with: a screen over
		-- a game must show it and must not have the view under it
		-- ([BOX_PLAYTEST_3] 2)
		lines[#lines + 1] = string.format("scan %s: mouse %s", label,
				magic.input.mouseVisible and "visible" or "hidden")
		ui_utils.scan_ui(label, top, 1, lines)
		if M.scan_extra then
			local ok = pcall(ui_utils.scan_ui, label, M.scan_extra, 1, lines)
			if not ok then
				M.scan_extra = nil
			end
		end
		focus_line(label, lines)
		lines[#lines + 1] = string.format("scan %s: done, %d lines", label, #lines)
		log:info(table.concat(lines, "\n"))
	end)
end

return M
-- vim: set noet ts=4 sw=4:
