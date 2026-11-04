-- Buildat: builtin/kit/client_lua/input.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_INPUT_ACTIONS] (stage 4m) Input as named actions: Kit's keys, one
-- set for the editor and play, with the app's own and the world's (the
-- components' `actions`, "kit:actions"), in the client's key store
-- (client/api.lua's declare_keys: the player's own, the pause menu's
-- Settings, "Key bindings"). module.lua runs it before editor.lua and
-- controls.lua. An app's or a part's code:
--   kit.declare_keys(label, keys) -> {id = key name}: the app's own keys
--     ({{id =, label =, default =, shared =}...}, as buildat.declare_keys
--     takes them) declared with Kit's and the world's, the store's entry
--     called label. kit.declare_keys() again after the settings window:
--     the keys may have changed. One declaring for the app: the store
--     keeps an app's last list only
--   kit.key(id, key) -> whether the key code (a KeyDown's) is the action's
--   kit.key_down(id) -> whether the action's key or gamepad button is held
--   kit.key_name(id) -> the action's key ("" unbound; nil: no such action)
--   kit.key_text(s) -> s with each "[id]" of an action "[its key]" (a
--     touchscreen: its button's label), as signs and the HUD show it
--   kit.world_actions() -> {{name =, key =, label =}...}, the world's
--   kit.press_action(name, down): a world action pressed (true) or let go,
--     sent to the server (its keys, its touch button, a gamepad's; a UI's)
-- A world action named as one of Kit's or the app's (jump, use) has that
-- key. Escape and the mouse's buttons are not actions.
return function(K)
local M, E, O = K.M, K.E, K.O
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = K.log
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"

-- Kit's, the editor's and play's: id, label, default key, the store's
-- shared name (every app's), the gamepad's button (SDL's game controller:
-- A 0, B 1, X 2, Y 3), the mouse's button doing it too (shown unbound)
local KIT_KEYS = {
	{id = "forward", label = "Forward (play and the editor)", default = "W",
		shared = "move.forward"},
	{id = "back", label = "Back", default = "S", shared = "move.back"},
	{id = "left", label = "Left", default = "A", shared = "move.left"},
	{id = "right", label = "Right", default = "D", shared = "move.right"},
	{id = "jump", label = "Jump; up in the editor's 3D view",
		default = "Space", shared = "jump", pad = 0},
	{id = "down", label = "Down in the editor's 3D view", default = "C"},
	-- No key by default: the left click uses ([KIT] stage 4e2: E no longer
	-- did), the text's "[use]" says so; a key bound uses too
	{id = "use", label = "Use what is pointed at (and the left click)",
		pad = 2, mouse = "Left click"},
	{id = "exit", label = "Leave a seat", default = "F", pad = 1},
	-- [KIT_TOOLS_1] the hotbar (and the wheel in first person); no key by
	-- default: an app's own (skeldat's E and Q) may be there
	{id = "item_next", label = "The next item in hand"},
	{id = "item_prev", label = "The item before in hand"},
	-- [KIT_TOOLS_2] a ranged item's magazine
	{id = "reload", label = "Reload what is in hand", default = "R"},
	-- [KIT_INVENTORY_PLAY] the inventory screen, a drop, the hotbar's
	-- slots (in "inventory" building; the app's palette keys otherwise)
	{id = "inventory", label = "The inventory screen", default = "E"},
	{id = "drop", label = "Drop one of what is in hand (Ctrl: all)",
		default = "Q"},
	{id = "edit", label = "Edit mode on and off", default = "F6"},
	{id = "view_2d", label = "Editor: the 2D view", default = "F1"},
	{id = "view_3d", label = "Editor: the 3D view", default = "F2"},
	{id = "view_walk", label = "Editor: walking", default = "F3"},
	{id = "next", label = "Editor: the next object (Shift: back)",
		default = "Tab"},
	{id = "undo", label = "Editor: undo, with Ctrl", default = "Z"},
	{id = "copy", label = "Editor: copy, with Ctrl", default = "C"},
	{id = "paste", label = "Editor: paste, with Ctrl", default = "V"},
	{id = "duplicate", label = "Editor: duplicate, with Ctrl", default = "D"},
	{id = "delete", label = "Editor: delete", default = "Delete"},
	{id = "terrain", label = "Editor: the terrain brush", default = "T"},
	{id = "voxels", label = "Editor: the voxel brush", default = "V"},
	{id = "box", label = "Editor: the box", default = "B"},
	{id = "smaller", label = "Editor: the brush smaller (Shift: weaker)",
		default = "["},
	{id = "larger", label = "Editor: the brush larger (Shift: stronger)",
		default = "]"},
	{id = "grid", label = "Editor: the next grid", default = "G"},
	{id = "angle", label = "Editor: the next angle step", default = "H"},
	{id = "turn_left", label = "Editor: turn the selection left",
		default = "Z"},
	{id = "turn_right", label = "Editor: turn the selection right",
		default = "X"},
	{id = "nudge_left", label = "Editor: nudge left; the 3D view turns",
		default = "Left"},
	{id = "nudge_right", label = "Editor: nudge right; the 3D view turns",
		default = "Right"},
	{id = "nudge_forward", label = "Editor: nudge forward; the 3D view tilts",
		default = "Up"},
	{id = "nudge_back", label = "Editor: nudge back; the 3D view tilts",
		default = "Down"},
	{id = "nudge_up", label = "Editor: nudge up", default = "PageUp"},
	{id = "nudge_down", label = "Editor: nudge down", default = "PageDown"},
}
for i = 1, 10 do
	KIT_KEYS[#KIT_KEYS + 1] = {id = "hotbar" .. i, label = "Hotbar slot " .. i,
		default = tostring(i % 10)}
end
-- The world's actions take the gamepad's free buttons in order: Y, LB, RB
local PAD_FREE = {3, 9, 10}

local S = {label = nil, app = {}, world = {}, list = {}, by_id = {},
	code = {}, name = {}, pad = {}, held = {}, pad_was = {}, version = 0}

local function declare()
	local list, by_id = {}, {}
	local function add(k)
		if type(k) == "table" and type(k.id) == "string" and not by_id[k.id] then
			list[#list + 1] = k
			by_id[k.id] = k
		end
	end
	for _, k in ipairs(KIT_KEYS) do add(k) end
	for _, k in ipairs(S.app) do add(k) end
	local free = 1
	for _, a in ipairs(S.world) do
		if not by_id[a.name] then
			add({id = a.name, label = "This world: " .. (a.label ~= "" and
					a.label or a.name), default = a.key, pad = PAD_FREE[free],
					world = true})
			free = free + 1
		end
	end
	local names = buildat.declare_keys and
			buildat.declare_keys(nil, S.label, list) or nil
	S.list, S.by_id, S.code, S.name, S.pad = list, by_id, {}, {}, {}
	for _, k in ipairs(list) do
		local n = type(names) == "table" and names[k.id] or nil
		if type(names) ~= "table" then
			n = k.default
		end
		S.name[k.id] = n or ""
		S.code[k.id] = n and magic.input:GetKeyFromName(n) or 0
		S.pad[k.id] = k.pad
	end
	S.version = S.version + 1
	return names
end

function M.declare_keys(label, keys)
	if label ~= nil then
		S.label = label
	end
	if keys ~= nil then
		S.app = type(keys) == "table" and keys or {}
	end
	local names = declare()
	local out = {}
	for _, k in ipairs(S.app) do
		out[k.id] = S.name[k.id]
	end
	log:info("kit: keys: " .. #S.list .. " actions, use " ..
			tostring(S.name.use) .. ", jump " .. tostring(S.name.jump))
	return type(names) == "table" and out or nil
end

function M.key(id, key)
	local c = S.code[id]
	return c ~= nil and c ~= 0 and c == key
end

-- ---- The gamepad: the first game controller (SDL's layout), read
-- through the sandbox's Input:GetControllerButtonDown and
-- GetControllerAxis (client/core/urho3d/safe_classes.lua).
-- simplified: its buttons fixed (pad above), not rebindable: the key
-- store keeps key names; a pad column in it is the upgrade
local HAS_PAD = select(2, pcall(function()
	return magic.input.GetControllerAxis ~= nil
end)) == true
log:info("kit: the gamepad " .. (HAS_PAD and "read" or
		"not read (no Input:GetControllerAxis)"))
local function pad_button(b)
	return b ~= nil and HAS_PAD and magic.input:GetControllerButtonDown(b)
end
-- An axis (0, 1: the left stick's x and y; 2, 3: the right's), -1..1, 0
-- inside a dead zone
function M.pad_axis(i)
	if not HAS_PAD then
		return 0
	end
	local v = magic.input:GetControllerAxis(i)
	return math.abs(v) > 0.2 and v or 0
end

function M.key_down(id)
	local c = S.code[id]
	return (c ~= nil and c ~= 0 and magic.input:GetKeyDown(c)) or
			pad_button(S.pad[id]) or false
end

-- Whether the action's key went down since the last frame
function M.key_press(id)
	local c = S.code[id]
	return c ~= nil and c ~= 0 and magic.input:GetKeyPress(c)
end

function M.key_name(id)
	local k = S.by_id[id]
	if not k then
		return nil
	end
	return S.name[id]
end

function M.key_text(s)
	if type(s) ~= "string" or not s:find("[", 1, true) then
		return s
	end
	return (s:gsub("%[([%w_]+)%]", function(id)
		local k = S.by_id[id]
		if not k then
			return nil
		end
		if TOUCH then
			return "[" .. (k.mouse and "Tap" or
					k.label:match("^This world: (.*)$") or k.label) .. "]"
		end
		return "[" .. (S.name[id] ~= "" and S.name[id] or k.mouse or
				"no key") .. "]"
	end))
end

function M.world_actions()
	return S.world
end
-- Changes as the keys or the world's actions do (the touch bar's again)
function M.keys_version()
	return S.version
end

-- ---- The world's actions sent: pressed in play, let go
function M.press_action(name, down)
	down = down and true or false
	if (S.held[name] or false) == down then
		return
	end
	S.held[name] = down or nil
	log:info("kit: action " .. name .. (down and " pressed" or " released"))
	buildat.send_packet("kit:action", name .. (down and " 1" or " 0"))
end

local function typing()
	local f = magic.ui.focusElement
	return f ~= nil and f:GetTypeName() == "LineEdit"
end

local function playing()
	return not E.editing and not typing() and not (O.paused and O.paused())
			and not ui_utils.mouse_look_paused()
end

buildat.sub_packet("kit:actions", function(data)
	local l = network.parse_json(data)
	local w = {}
	for _, a in ipairs(type(l) == "table" and l or {}) do
		if type(a) == "table" and type(a.name) == "string" then
			w[#w + 1] = {name = a.name, key = tostring(a.key or ""),
				label = tostring(a.label or "")}
		end
	end
	S.world = w
	-- Gone ones let go
	local known = {}
	for _, a in ipairs(w) do known[a.name] = true end
	for name in pairs(S.held) do
		if not known[name] then
			S.held[name] = nil
		end
	end
	declare()
	log:info("kit: the world's actions: " .. #w)
end)

magic.SubscribeToEvent("KeyDown", function(_, data)
	if data:GetBool("Repeat") or not playing() then
		return
	end
	local key = data:GetInt("Key")
	for _, a in ipairs(S.world) do
		if M.key(a.name, key) then
			M.press_action(a.name, true)
		end
	end
end)

magic.SubscribeToEvent("KeyUp", function(_, data)
	local key = data:GetInt("Key")
	for _, a in ipairs(S.world) do
		if M.key(a.name, key) and not pad_button(S.pad[a.name]) then
			M.press_action(a.name, false)
		end
	end
end)

-- Play's presses on the gamepad (as a key's KeyDown would be), the world's
-- held ones let go out of play
local pad_cbs = {}
function M.on_pad_press(id, fn)
	pad_cbs[id] = fn
end
magic.SubscribeToEvent("Update", function()
	local play = playing()
	for _, k in ipairs(S.list) do
		local b = S.pad[k.id]
		if b then
			local down = pad_button(b) and play
			if down ~= (S.pad_was[k.id] or false) then
				S.pad_was[k.id] = down
				if k.world then
					M.press_action(k.id, down)
				elseif down and pad_cbs[k.id] then
					pad_cbs[k.id]()
				end
			end
		end
	end
	if not play then
		for name in pairs(S.held) do
			M.press_action(name, false)
		end
	end
end)

-- Kit's own until the app declares (Workbench, skeldat: kit.declare_keys)
declare()
end
-- vim: set noet ts=4 sw=4:
