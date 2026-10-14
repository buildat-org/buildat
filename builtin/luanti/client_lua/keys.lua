-- Buildat: builtin/luanti/client_lua/keys.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The key bindings, and the one screen that edits them ([KEY_BINDINGS]):
-- the Luanti settings screen of the launcher and the pause menu's "Key
-- bindings" both draw this. The table is the code's own -- key_down() in
-- client.lua reads it -- so a key cannot be bound here and missed there.
-- What the keys are is the client's key store's (client/api.lua's
-- declare_keys), the player's for every server. Key names are Urho3D's;
-- the mouse's buttons and wheel are not bindable.
local magic = require("buildat/extension/urho3d")
local log = buildat.Logger("luanti/keys")

local M = {}

M.BINDINGS = {
	{action = "forward", key = magic.KEY_W, name = "W", what = "Walk forward"},
	{action = "back", key = magic.KEY_S, name = "S", what = "Walk back"},
	{action = "left", key = magic.KEY_A, name = "A", what = "Walk left"},
	{action = "right", key = magic.KEY_D, name = "D", what = "Walk right"},
	{action = "jump", key = magic.KEY_SPACE, name = "Space",
			what = "Jump, and up while flying"},
	{action = "sneak", key = magic.KEY_LSHIFT, name = "Shift",
			what = "Sneak, and down while flying"},
	-- Official's three modes and its special key ([FLY_MODES]): fast mode
	-- is a toggle, and on the ground the special key is what moves fast
	-- while it is on
	{action = "aux1", key = magic.KEY_F, name = "F",
			what = "Special - move fast in fast mode"},
	{action = "fly", key = magic.KEY_K, name = "K", what = "Fly mode on and off"},
	{action = "fast", key = magic.KEY_J, name = "J", what = "Fast mode on and off"},
	{action = "noclip", key = magic.KEY_H, name = "H",
			what = "Noclip on and off (while flying)"},
	{action = "hotbar", first = magic.KEY_1, last = magic.KEY_9,
			name = "1 - 9", what = "Pick a hotbar slot"},
	{action = "chat", key = magic.KEY_T, name = "T",
			what = "Chat - a / line is a command"},
	{action = "inventory", key = magic.KEY_E, name = "E", what = "Inventory"},
	{action = "drop", key = magic.KEY_Q, name = "Q",
			what = "Drop what is held (Ctrl: one)"},
	{action = "mouse", key = magic.KEY_TAB, name = "Tab",
			what = "The mouse: in the world, on the screen"},
	{action = "mute", key = magic.KEY_M, name = "M",
			what = "Sound muted or not"},
	{action = "camera", key = magic.KEY_C, name = "C",
			what = "Camera: first person, behind, in front"},
	{action = "zoom", key = magic.KEY_Z, name = "Z",
			what = "Zoom while held (the zoom privilege)"},
	{action = "fog", key = magic.KEY_F3, name = "F3",
			what = "Fog on and off"},
	{action = "minimap", key = magic.KEY_V, name = "V",
			what = "Minimap: off, surface, radar, three sizes each"},
	-- The engine's own, listed for the player and not rebindable here
	{action = "screenshot", key = magic.KEY_F12, name = "F12", engine = true,
			what = "A screenshot (the engine's)"},
	{action = "profiler", key = magic.KEY_F10, name = "F10", engine = true,
			what = "The engine's profiler on and off"},
	{action = "fullscreen", key = magic.KEY_F11, name = "F11", engine = true,
			what = "Fullscreen on and off (the engine's)"},
	{action = "hud", key = magic.KEY_F1, name = "F1",
			what = "The HUD on and off"},
	{action = "chatlog", key = magic.KEY_F2, name = "F2",
			what = "The chat log on and off"},
	{action = "detail", key = magic.KEY_F5, name = "F5",
			what = "The line of detail on and off"},
	{action = "menu", key = magic.KEY_ESCAPE, name = "Escape",
			what = "Pause menu, or close what is open"},
	-- Listed for the player's sake; the code for these is the mouse
	-- handling rather than a key lookup, and they are not bindable
	{action = "dig", name = "Left mouse", what = "Dig"},
	{action = "place", name = "Right mouse", what = "Place, or use"},
	{action = "wield", name = "Mouse wheel", what = "Pick a hotbar slot"},
}

M.BIND = {}
for _, b in ipairs(M.BINDINGS) do
	M.BIND[b.action] = b
	b.default_key = b.key
	b.default_name = b.name
end

local function bindable(b)
	return b.default_key ~= nil and not b.engine
end

-- The settings list as last sent by the server, so that the editor sends
-- the whole of it back with its rows changed
M.settings = {}

-- **The keys are the client's key store's** ([LAUNCH_MENU_V2] step 3):
-- declared as this game's ("app/vanilla" for one this client started, the
-- server's address for any other), the common actions under the shared
-- names, so a player binds them once for every app.
local editor = (function(ok, err, e)
	if not ok or type(e) ~= "table" then
		log:warning("key_editor.lua: " .. tostring(err))
		return nil
	end
	return e
end)(buildat.run_script_file("luanti/key_editor.lua"))
local SHARED = {forward = "move.forward", back = "move.back",
	left = "move.left", right = "move.right", jump = "jump",
	sneak = "sneak", aux1 = "sprint", fly = "fly", noclip = "noclip",
	camera = "camera", zoom = "zoom", chat = "chat",
	inventory = "inventory", drop = "drop", hud = "hud", menu = "menu"}
local function declare()
	return editor ~= nil and
			editor.declare(magic, nil, "Luanti", M.BINDINGS, bindable, SHARED)
end
declare()
-- Read again after the game's settings window ([GAME_SETTINGS])
M.declare = declare

return M
