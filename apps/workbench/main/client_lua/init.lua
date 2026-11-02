-- Buildat: apps/workbench/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [KIT] Workbench's client: Kit's controls (a body the server moves,
-- kit/controls on the app root: the camera, the pointer, the movement;
-- kit/walker's by default), Kit's editor, and the voxels to build with.
--   W A S D, Space: walk, jump; the mouse looks (a top-down camera's
--   cursor: the right button held turns the view, the wheel zooms)
--   ([KIT] stage 4e2) what a click would do is shown on what the
--   crosshair (or cursor) is on (Kit's play_target: floorplanner's
--   colours): the left button uses an object with a click action, else
--   digs (with edit rights, or where a component grants it); the right one
--   places. kit/click_to_move takes the left button: a click walks there
--   (The keys are the defaults: Kit's and these, the player's to rebind
--   in the pause menu's Settings, Key bindings; [KIT_INPUT_ACTIONS])
--   1...9, 0 the voxel placed (Kit's stone, Workbench's glass, Kit's
--   planks, Workbench's brick, Kit's grass, dirt, sand, log, leaves, water)
--   F: out of a seat (kit/car, kit/ball: a use takes it)
--   F6 or the menu's "Edit": Kit's editor, floorplanner's (its 2D, 3D and
--   walking views: here the walk); walking in it, the pointer is free and
--   the right button held looks round, a click goes up into the crosshair
--   (Escape back down). The menu's "Run" and "End" (a builder's): the
--   server Running or Ended, the start put back ([KIT] 4c)
--   L: log in (builtin/accounts' dialog)
--   Escape: the pause menu (extensions/pause_menu: Continue, Kit's Edit
--   and Run/End, Chat, Settings, Leave); in the tools Kit's first (a
--   pending link, a drag, the crosshair)
-- A touchscreen (BUILDAT_TOUCH=1, Kit's controls.lua): a stick at the
-- lower left, a drag elsewhere turns the view, a tap is the left click at
-- the finger and a finger held still the right click; Jump (a car's Gas
-- and Brake, a seat's Exit) and Menu at the lower right
local log = buildat.Logger("workbench")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local ui_utils = require("buildat/extension/ui_utils")
local voxelworld = require("buildat/module/voxelworld")
local kit = require("buildat/module/kit")
-- The server's copy (meta.json's client_extensions), whatever the client's
local _, pm_err, pause_menu = buildat.run_script_file("pause_menu/init.lua")
assert(type(pause_menu) == "table", "pause_menu: " .. tostring(pm_err))

local REACH = 6
local MATERIALS = {"kit/stone", "workbench/glass", "kit/planks",
	"workbench/brick", "kit/grass", "kit/dirt", "kit/sand", "kit/log",
	"kit/leaves", "kit/water"}
-- [KIT] stage 4e: a World on a heightmap surface (builtin/heightmap's
-- client, loaded by Kit's dependency)
local heightmap = require("buildat/module/heightmap")

local scene = replicate.main_scene
-- The voxel in hand: one of MATERIALS by its key, or any by Kit's
-- editor's Voxel list ([KIT] stage 4g, a builder's own types too)
local hand = MATERIALS[1]
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"
-- [KIT_INPUT_ACTIONS] Workbench's own keys, declared with Kit's (one set
-- for edit mode and play, the pause menu's Settings, Key bindings)
local KEYS = {{id = "login", label = "Log in", default = "L"}}
for i = 1, 10 do
	KEYS[#KEYS + 1] = {id = "voxel" .. i, label = "Voxel in hand: " ..
		MATERIALS[i], default = tostring(i % 10)}
end
kit.declare_keys("Workbench", KEYS)

-- A login by builtin/accounts: "l", or at once where BUILDAT_JOIN_NAME
-- names one (main:account: unless join.lua's login was it,
-- [WORKBENCH_PROJECTS]); the launcher's own user is the admin without one.
-- Its console is builtin/chat's, the menu's Chat
local accounts = nil
do
	local _, err, acc = buildat.run_script_file("accounts/accounts.lua")
	if type(acc) == "table" then
		accounts = acc
		require("buildat/module/chat").attach(accounts)
	else
		log:warning("workbench: no accounts.lua: " .. tostring(err))
	end
end
local logging_in = false
local function log_in()
	if logging_in or not accounts then
		return
	end
	logging_in = true
	accounts.start({title = "Workbench"})
end
buildat.sub_packet("main:account", function(data)
	if data == "1" and accounts then
		accounts.logged_in = true
	elseif buildat.get_env("BUILDAT_JOIN_NAME") then
		log_in()
	end
end)

-- A plain light: the world is a workshop, not a scenery
do
	local zone = scene:CreateChild("Zone"):CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = magic.Color(0.45, 0.45, 0.5)
	zone.fogColor = magic.Color(0.55, 0.68, 0.85)
	zone.fogStart = 120
	zone.fogEnd = 200
	local sun = scene:CreateChild("Sun")
	sun.direction = magic.Vector3(-0.5, -1.0, 0.7)
	local light = sun:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.brightness = 0.8
end

-- The camera: Kit's controls place it ([KIT] stage 4h)
local camera_node = scene:CreateChild("Camera")
do
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.1
	camera.farClip = 250
	camera.fov = magic.fov_for(75)
	magic.set_preferred_viewports({kit.viewport(scene, camera)})
end
voxelworld.set_camera(camera_node)

-- Kit's voxels' look (module.lua's voxel_look): water blended, leaves and
-- plants cut out, the tint and the World's sky light; a heightmap's
-- decorations (voxel objects) drawn as the voxels are
local voxel_look = kit.voxel_look
voxelworld.sub_material_update(voxel_look)
require("buildat/module/voxel_objects").set_material_cb(voxel_look)

-- The HUD: what the app is, the voxel in hand, the crosshair
local function hud_text(y, size)
	local t = magic.ui.root:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), size)
	t.horizontalAlignment = magic.HA_LEFT
	t.verticalAlignment = magic.VA_BOTTOM
	t:SetPosition(10, y)
	return t
end
local help_text = hud_text(-10, 13)
-- [KIT_TOUCH_HELP_JUMP] Wrapped to end before the touch bars (it ran
-- under Jump at 1024 px), the status line kept above it
help_text:SetWordwrap(true)
local status_text = hud_text(-30, 15)
local crosshair = {}
for _, s in ipairs({{15, 1}, {1, 15}}) do
	local bar = magic.ui.root:CreateChild("BorderImage")
	bar.width, bar.height = s[1], s[2]
	bar.horizontalAlignment = magic.HA_CENTER
	bar.verticalAlignment = magic.VA_CENTER
	bar.color = magic.Color(1, 1, 1)
	crosshair[#crosshair + 1] = bar
end

-- [KIT_VOXEL_FORMAT] a placing carries the shape in hand's facing and
-- Kit's tint in hand (the editor's palette)
local function build(p, voxel, param)
	if not p then
		return
	end
	local extra = ""
	if voxel ~= "air" then
		voxel = kit.hand_voxel(voxel)
		extra = ', "param": ' .. (kit.hand.shape ~= "" and param or 0) ..
				', "tint": ' .. (kit.hand.tint or 0)
	end
	buildat.send_packet("main:build", '{"p": [' .. p.x .. ', ' .. p.y .. ', ' ..
			p.z .. '], "voxel": "' .. voxel .. '"' .. extra .. '}')
end

-- The voxels a click digs and places on (the heightmap's surface none)
local function voxel_at(x, y, z)
	-- 0: not there, 1: air
	-- the id's bits only ([KIT_VOXEL_FORMAT]: param, tint and light above)
	return voxelworld.get_voxel_registry():id_of(
			voxelworld.get_static_voxel(magic.Vector3(x, y, z))) > 1
end

-- For a drive ([KIT_HM_NO_SEA]): "event wb_column" logs the voxels of
-- the column (5, 5) from y -8 to 0 (on a heightmap all air, no sea)
magic.SubscribeToEvent("command_seq:wb_column", function()
	local reg, n = voxelworld.get_voxel_registry(), {0, 0, 0}
	for y = -8, 0 do
		local id = reg:id_of(voxelworld.get_static_voxel(
				magic.Vector3(5, y, 5)))
		local k = id == 0 and 1 or id == 1 and 2 or 3
		n[k] = n[k] + 1
	end
	log:info("workbench: column 5,5: " .. n[1] .. " not loaded, " ..
			n[2] .. " air, " .. n[3] .. " voxels")
end)

-- What a click would do in play ([KIT] stage 4e2, Kit's play_target): at
-- the crosshair, or a touchscreen's finger (x, y: its pixels); a camera
-- away from the eye (chase, top-down) reaches as far past the player
local function target(x, y)
	local o, d = kit.pointer_ray(x, y)
	local b = kit.body_pos()
	local far = b and math.sqrt((o.x - b.x) ^ 2 + (o.y - b.y - 1.5) ^ 2 +
			(o.z - b.z) ^ 2) or 0
	return kit.play_target(o, d, REACH + (far > 1 and far or 0), voxel_at)
end

-- For a drive: "event workbench_build {"p": [x, y, z], "voxel": "air"}"
-- sends a build the pointing would not (the server's refusal)
magic.SubscribeToEvent("command_seq:workbench_build", function(_, data)
	buildat.send_packet("main:build", data:GetString("Param"))
end)

local function act(t, left)
	local a = t and (left and t.left or not left and t.right)
	if not a then
		return
	end
	if a.kind == "refused" then
		-- [KIT] stage 4j: a region's rule (or no grant): why, shown
		kit.refused(a.why)
	elseif a.kind == "use" then
		kit.use(a.id)
	elseif a.kind == "dig" then
		build(magic.Vector3(a.cell[1], a.cell[2], a.cell[3]), "air")
	elseif a.kind == "place" then
		build(magic.Vector3(a.cell[1], a.cell[2], a.cell[3]), hand, a.param)
	end
end

-- Kit's items in the pause menu in place of its top bar
kit.editor{scene = scene, camera = camera_node, ground_y = 1, bar = false,
	mouse_look = true, set_camera = voxelworld.set_camera,
	pick_voxel = function(name)
		hand = name
	end,
	-- The heightmap's ground (Kit's cells under it, [KIT_HM_VOXELS]) and
	-- the voxels
	solid = function(x, y, z)
		return kit.terrain_cell(x, y, z) or voxel_at(x, y, z)
	end}

-- The mouse turns the view in play and in the editor's crosshair; the
-- menu, the tools at the pointer and a touchscreen free it. On the web a
-- lost pointer lock opens the menu (the editor's crosshair goes down to
-- the pointer instead), whose click takes it back
local editing, looking = false, false
local menu
local function capture(on)
	ui_utils.mouse_look(on and not TOUCH and (not editing or looking) and
			not kit.pointer_free(),
			function()
		if not kit.drop_crosshair() then
			menu.open()
		end
	end)
end
menu = pause_menu.new{capture = capture, accounts = accounts,
	on_settings_closed = function() kit.declare_keys() end}
kit.add_menu_items(menu)
-- The controls: their clicks the app's where the movement takes none
kit.controls{camera = camera_node, capture = capture,
	paused = function() return menu.held() end,
	act = function(x, y, left) act(target(x, y), left) end,
	buttons = {{"Menu", function() menu.open() end}}}
capture(true)
magic.ui:SetFocusElement(nil)

magic.SubscribeToEvent("KeyDown", function(_, data)
	local key = data:GetInt("Key")
	local f = magic.ui.focusElement
	if f ~= nil and f:GetTypeName() == "LineEdit" then
		return
	end
	if key == magic.KEY_ESCAPE then
		if not ui_utils.mouse_look_escape() then
			menu.escape()
		end
	elseif menu.held() then
		return
	elseif kit.key("login", key) then
		log_in()
	else
		for i = 1, 10 do
			if kit.key("voxel" .. i, key) then
				hand = MATERIALS[i]
			end
		end
	end
end)

-- What a click would do, shown on what is pointed at (play; the editor
-- shows its own); a touchscreen's at the finger down, held still the right
-- click's
local function show_pointed()
	if editing or menu.held() or ui_utils.mouse_look_paused() or
			ui_utils.clicks_wanted() then
		kit.show_target(nil)
		return
	end
	if not TOUCH then
		kit.show_target(target())
		return
	end
	local f = kit.touch_finger()
	kit.show_target(f and target(f.x, f.y) or nil)
end

magic.SubscribeToEvent("Update", function()
	-- Edit mode frees the pointer for the editor's clicks, but in its
	-- crosshair
	if kit.editing() ~= editing or kit.looking() ~= looking then
		editing, looking = kit.editing(), kit.looking()
		if not menu.held() then
			capture(true)
		end
	end
	-- [KIT_UI_CROSSHAIR] None while a window wants clicks (a Kit panel
	-- with a button, the Server window): the pointer is the screen's then
	local cross = not TOUCH and (not editing or looking) and
			not kit.pointer_free() and not ui_utils.clicks_wanted()
	if cross ~= crosshair.shown then
		crosshair.shown = cross
		log:info("workbench: the crosshair " .. (cross and "shown" or "hidden"))
	end
	for _, bar in ipairs(crosshair) do
		bar.visible = cross
	end
	show_pointed()
	local p = kit.body_pos()
	status_text.visible = not editing and p ~= nil
	if p then
		status_text:SetText(string.format("(%d, %d, %d)  in hand: %s",
				math.floor(p.x + 0.5), math.floor(p.y + 0.95),
				math.floor(p.z + 0.5), hand))
	end
	local seated = kit.seated()
	-- [KIT_INPUT_ACTIONS] the keys as bound
	help_text:SetText(editing and "" or TOUCH and (seated and
			"Stick: move  Exit: leave the seat" or
			"Stick: walk  drag: look  tap: use/dig  hold: place") or
			kit.key_text(seated and "[forward][left][back][right] [jump]: " ..
			"move  [exit]: leave the seat  Esc: menu" or
			"[forward][left][back][right] [jump]: walk, jump  left: use or " ..
			"dig  right: place  [voxel1]-[voxel10]: voxel  " ..
			"[edit]: edit  [login]: log in  Esc: menu"))
	local right = kit.touch_bar_left() or magic.ui.root.width
	local w = math.max(100, right - 10 - 12)
	if help_text.width ~= w then
		help_text:SetFixedWidth(w)
	end
	status_text:SetPosition(10, -10 - help_text.height - 5)
end)
-- vim: set noet ts=4 sw=4:
