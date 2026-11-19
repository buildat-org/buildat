-- Buildat: apps/floorplanner/client_lua/keys.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The key bindings** (user: a key mapping menu like vanilla's): the
-- table the editor's keys are read from, so a key cannot be bound here and
-- missed there, and what the pause menu's "Keys..." page edits. What
-- differs from the defaults is kept in this client's storage as
-- "<action>=<key name>" lines; the names are Urho3D's. The rest are listed
-- for the user's sake and are not bindable.
local magic = require("buildat/extension/urho3d")

local M = {}

M.BINDINGS = {
	{action = "forward", key = magic.KEY_W, what = "Forward"},
	{action = "back", key = magic.KEY_S, what = "Back"},
	{action = "left", key = magic.KEY_A, what = "Left"},
	{action = "right", key = magic.KEY_D, what = "Right"},
	{action = "up", key = magic.KEY_SPACE, what = "Up (3D; noclip)"},
	{action = "down", key = magic.KEY_C, what = "Down"},
	{action = "use", key = magic.KEY_E, what = "Open, close or switch"},
	{action = "noclip", key = magic.KEY_F, what = "Noclip (walking)"},
	{action = "turn_view_left", key = magic.KEY_LEFT, what = "Turn the view left"},
	{action = "turn_view_right", key = magic.KEY_RIGHT, what = "Turn the view right"},
	{action = "tilt_up", key = magic.KEY_UP, what = "Tilt the view up"},
	{action = "tilt_down", key = magic.KEY_DOWN, what = "Tilt the view down"},
	{action = "view_2d", key = magic.KEY_F1, what = "2D view"},
	{action = "view_3d", key = magic.KEY_F2, what = "3D view"},
	{action = "view_walk", key = magic.KEY_F3, what = "Walk"},
	{action = "select", key = magic.KEY_V, what = "Select tool"},
	{action = "node", key = magic.KEY_N, what = "Nodes tool"},
	{action = "wall", key = magic.KEY_B, what = "Wall tool"},
	{action = "room", key = magic.KEY_R, what = "Room tool"},
	{action = "box", key = magic.KEY_O, what = "Object tool"},
	{action = "hosted", key = magic.KEY_I,
			what = "Wall items tool"},
	{action = "voxel", key = magic.KEY_K, what = "Voxels tool"},
	{action = "paint", key = magic.KEY_M, what = "Material tool"},
	{action = "measure", key = magic.KEY_Q, what = "Measure tool"},
	{action = "turn_left", key = magic.KEY_Z, what = "Turn the selection left"},
	{action = "turn_right", key = magic.KEY_X, what = "Turn the selection right"},
	{action = "delete", key = magic.KEY_DELETE, what = "Delete the selection"},
	{action = "grid", key = magic.KEY_G, what = "Next grid size"},
	{action = "angle", key = magic.KEY_H, what = "Next angle step"},
	{action = "flat", key = magic.KEY_L, what = "The plan's look: lit, flat, technical"},
	{action = "next_user", key = magic.KEY_U, what = "To the next user's view"},
	{action = "chat", key = magic.KEY_T, what = "Chat"},
	-- Listed, not bindable
	{name = "Escape", what = "Menu, or cancel"},
	{name = "Ctrl+Z", what = "Undo"},
	{name = "Ctrl+Y", what = "Redo"},
	{name = "Ctrl+D", what = "Copy"},
	{name = "Ctrl+L", what = "Linked clone"},
	{name = "Shift", what = "Faster; angle step"},
	{name = "Ctrl", what = "Free node drag"},
	{name = "0 - 9, Enter", what = "Typed length"},
}

M.BIND = {}
for _, b in ipairs(M.BINDINGS) do
	if b.action then
		M.BIND[b.action] = b
		b.default_key = b.key
	end
end

-- simplified: an unknown action errors here rather than reading as no key
function M.key(action)
	return M.BIND[action].key
end
function M.name(action)
	return magic.input:GetKeyName(M.BIND[action].key)
end
function M.down(action)
	return magic.input:GetKeyDown(M.BIND[action].key)
end

-- Whether another binding has this one's key
function M.taken(b)
	for _, o in ipairs(M.BINDINGS) do
		if o ~= b and o.key and o.key == b.key then
			return true
		end
	end
	return false
end

function M.load()
	for _, b in pairs(M.BIND) do
		b.key = b.default_key
	end
	for line in (buildat.storage_read("keys") or ""):gmatch("[^\n]+") do
		local action, name = line:match("^([%w_]+)=(.+)$")
		local key = name and magic.input:GetKeyFromName(name) or 0
		if action and M.BIND[action] and key ~= 0 then
			M.BIND[action].key = key
		end
	end
end

-- key nil: the default
function M.set(action, key)
	local b = M.BIND[action]
	b.key = key or b.default_key
	local lines = {}
	for _, o in ipairs(M.BINDINGS) do
		if o.action and o.key ~= o.default_key then
			lines[#lines + 1] = o.action .. "=" .. magic.input:GetKeyName(o.key)
		end
	end
	buildat.storage_write("keys", table.concat(lines, "\n"))
end

function M.defaults()
	for _, b in pairs(M.BIND) do
		b.key = b.default_key
	end
	buildat.storage_write("keys", "")
end

M.load()

return M
