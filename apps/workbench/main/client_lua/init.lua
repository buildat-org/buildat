-- Buildat: apps/workbench/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [KIT] Workbench's client: a player walking on the floor (demo_digger's
-- physics, copied), Kit's editor, and the voxels to build with.
--   W A S D, Space: walk, jump; the mouse looks
--   ([KIT] stage 4e2) what a click would do is shown on what the
--   crosshair is on (Kit's play_target: floorplanner's colours): the left
--   button uses an object with a click action, else digs (with edit
--   rights, or where a component grants it); the right one places
--   1...9, 0 the voxel placed (Kit's stone, Workbench's glass, Kit's
--   planks, Workbench's brick, Kit's grass, dirt, sand, log, leaves, water)
--   F6 or the menu's "Edit": Kit's editor, floorplanner's (its 2D, 3D and
--   walking views: here the walk); walking in it, the pointer is free and
--   the right button held looks round, a click goes up into the crosshair
--   (Escape back down). The menu's "Play" and "Stop" (a builder's): the
--   server Running or Stopped ([KIT] 4c)
--   L: log in (builtin/accounts' dialog)
--   Escape: the pause menu (extensions/pause_menu: Continue, Kit's Edit
--   and Play/Stop, Chat, Settings, Leave); in the tools Kit's first (a
--   pending link, a drag, the crosshair)
-- A touchscreen (BUILDAT_TOUCH=1, floorplanner's walking: [FP_TOUCH] 3):
-- a finger put down at the lower left is a stick that walks, a drag
-- elsewhere turns the view, a tap is the left click at the finger and a
-- finger held still the right click; Jump and Menu at the lower right
local log = buildat.Logger("workbench")
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local ui_utils = require("buildat/extension/ui_utils")
local voxelworld = require("buildat/module/voxelworld")
local kit = require("buildat/module/kit")
-- The server's copy (meta.json's client_extensions), whatever the client's
local _, pm_err, pause_menu = buildat.run_script_file("pause_menu/init.lua")
assert(type(pause_menu) == "table", "pause_menu: " .. tostring(pm_err))

local PLAYER_HEIGHT = 1.7
local PLAYER_WIDTH = 0.9
local PLAYER_MASS = 70
local MOVE_SPEED = 6
local JUMP_SPEED = 7
local PLAYER_ACCELERATION = 40
local REACH = 6
local MATERIALS = {"kit/stone", "workbench/glass", "kit/planks",
	"workbench/brick", "kit/grass", "kit/dirt", "kit/sand", "kit/log",
	"kit/leaves", "kit/water"}
-- [KIT] stage 4e: a World on a heightmap surface (builtin/heightmap's
-- client, loaded by Kit's dependency)
local heightmap = require("buildat/module/heightmap")

local scene = replicate.main_scene
local material = 1
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"

-- A login by builtin/accounts: "l", or at once where BUILDAT_JOIN_NAME
-- names one; the launcher's own user is the admin without one. Its
-- console is builtin/chat's, the menu's Chat
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
if buildat.get_env("BUILDAT_JOIN_NAME") then
	log_in()
end

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

-- The player (demo_digger's body)
local player_node = scene:CreateChild("Player")
local player_shape = player_node:CreateComponent("CollisionShape")
local body = player_node:CreateComponent("RigidBody")
player_node.position = magic.Vector3(0.5, 3, 0.5)
body.friction = 0
body.angularFactor = magic.Vector3(0, 0, 0)
body.gravityOverride = magic.Vector3(0, -15.0, 0)
-- Default COLLISION_ACTIVE drops events when the body sleeps, so a jump
-- would fail while standing still
body.collisionEventMode = magic.COLLISION_ALWAYS
player_shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT)

-- The yaw on a node of its own: the body's node is the physics', which a
-- step between frames sets back to the body's rotation of the last step,
-- undoing a turn of the mouse ([WORKBENCH_CHECK_FLAKY]: a scripted look
-- read 180 degrees as 120 and the dig went a cell off)
local yaw_node = player_node:CreateChild("Yaw")
local camera_node = yaw_node:CreateChild("Camera")
camera_node.position = magic.Vector3(0, 0.411 * PLAYER_HEIGHT, 0)
do
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.1
	camera.farClip = 250
	magic.keep_fov(camera, 75)
	magic.set_preferred_viewports({magic.Viewport:new(scene, camera)})
end
voxelworld.set_camera(camera_node)

-- Kit's water (translucent voxels, a chunk's child "alpha") alpha blended;
-- ([KIT] stage 4f) its leaves and plants (alpha masked, "masked") cut out;
-- a heightmap's decorations (voxel objects) drawn as the voxels are
local function voxel_look(node)
	for child, technique in pairs({[""] = "Techniques/Diff.xml",
			alpha = "Techniques/DiffAlpha.xml",
			masked = "kit/DiffAlphaMask.xml"}) do
		local n = child == "" and node or node:GetChild(child)
		local cg = n and n:GetComponent("CustomGeometry")
		local i = 0
		while cg and cg:GetMaterial(i) do
			cg:GetMaterial(i):SetTechnique(0, magic.cache:GetResource(
					"Technique", technique))
			i = i + 1
		end
	end
end
voxelworld.sub_material_update(voxel_look)
require("buildat/module/voxel_objects").set_material_cb(voxel_look)

local touches_ground = false
local physics_on = false
local spawned = false

-- Physics once there is a floor with its collision under the feet: the
-- volume arrives before Bullet's boxes
local function floor_ready()
	if heightmap.terrain then
		return true
	end
	local p = player_node:GetWorldPosition()
	local floor = magic.Vector3(p.x, p.y - PLAYER_HEIGHT / 2 - 0.25, p.z)
	if voxelworld.get_static_voxel(floor).id < 2 then
		return false
	end
	local chunk_p = voxelworld.get_chunk_position(floor)
	return chunk_p and voxelworld.chunk_has_physics(chunk_p)
end
local function physics()
	if physics_on or not spawned or not floor_ready() then
		return
	end
	body.mass = PLAYER_MASS
	physics_on = true
	log:info("player physics enabled")
end
body.mass = 0

-- The position, with the count of the server's puts it comes after.
-- A put can be undone by the body's motion state a frame later (the
-- interpolated physics puts the node back where the body was): until the
-- node has stayed where it was put for three frames, it is put again and
-- nothing is sent
local moves = 0
local put, put_frames = nil, 0
-- Where the server put the player last: a fall out of the world ends there
local spawn_at = magic.Vector3(0.5, 3, 0.5)
local function send_pos()
	local p = player_node:GetWorldPosition()
	if put then
		put_frames = (p - put):Length() > 1 and 0 or put_frames + 1
		if put_frames == 0 then
			player_node.position = put
		end
		if put_frames < 3 then
			return
		end
		put = nil
	end
	buildat.send_packet("main:player_pos", cereal.binary_output(
			{x = p.x, y = p.y, z = p.z, n = moves},
			{"object", {"x", "double"}, {"y", "double"}, {"z", "double"},
				{"n", "int32_t"}}))
end

-- The server puts the player: at the start, and a component's teleport
buildat.sub_packet("main:spawn", function(data)
	local v = cereal.binary_input(data, {"object", {"x", "double"},
		{"y", "double"}, {"z", "double"}, {"n", "int32_t"}})
	moves = v.n
	log:info("the server put the player at (" .. v.x .. ", " .. v.y .. ", " ..
			v.z .. ")")
	put, put_frames = magic.Vector3(v.x, v.y, v.z), 0
	spawn_at = put
	player_node.position = put
	body.linearVelocity = magic.Vector3(0, 0, 0)
	spawned = true
	physics()
end)

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

local function build(p, voxel)
	if not p then
		return
	end
	buildat.send_packet("main:build", '{"p": [' .. p.x .. ', ' .. p.y .. ', ' ..
			p.z .. '], "voxel": "' .. voxel .. '"}')
end

-- The voxels a click digs and places on (the heightmap's surface none)
local function voxel_at(x, y, z)
	-- 0: not there, 1: air
	return voxelworld.get_static_voxel(magic.Vector3(x, y, z)).id > 1
end

-- What a click would do in play ([KIT] stage 4e2, Kit's play_target): at
-- the crosshair, or a touchscreen's finger (x, y: its pixels)
local function target(x, y)
	local o, d = camera_node.worldPosition, camera_node.worldDirection
	if x then
		o, d = kit.screen_ray(x, y, camera_node,
				camera_node:GetComponent("Camera"))
	end
	return kit.play_target(o, d, REACH, voxel_at)
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
	if a.kind == "use" then
		kit.use(a.id)
	elseif a.kind == "dig" then
		build(magic.Vector3(a.cell[1], a.cell[2], a.cell[3]), "air")
	elseif a.kind == "place" then
		build(magic.Vector3(a.cell[1], a.cell[2], a.cell[3]),
				MATERIALS[material])
	end
end

-- Kit's items in the pause menu in place of its top bar
kit.editor{scene = scene, camera = camera_node, ground_y = 1, bar = false,
	mouse_look = true, set_camera = voxelworld.set_camera,
	solid = function(x, y, z)
		local h = heightmap.height_at(x, z)
		if h and y < h then
			return true
		end
		return voxel_at(x, y, z)
	end}

-- The mouse turns the view in play and in the editor's crosshair; the
-- menu, the tools at the pointer and a touchscreen free it. On the web a
-- lost pointer lock opens the menu (the editor's crosshair goes down to
-- the pointer instead), whose click takes it back
local editing, looking = false, false
local menu
local function capture(on)
	ui_utils.mouse_look(on and not TOUCH and (not editing or looking),
			function()
		if not kit.drop_crosshair() then
			menu.open()
		end
	end)
end
menu = pause_menu.new{capture = capture, accounts = accounts}
kit.add_menu_items(menu)
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
	elseif key == magic.KEY_L then
		log_in()
	elseif key >= magic.KEY_1 and key <= magic.KEY_9 then
		material = key - magic.KEY_1 + 1
	elseif key == magic.KEY_0 then
		material = 10
	end
end)

magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	if editing or TOUCH or menu.held() or ui_utils.mouse_look_paused() or
			ui_utils.clicks_wanted() then
		return
	end
	local button = data:GetInt("Button")
	act(target(), button == magic.MOUSEB_LEFT)
end)

-- ---- A touchscreen ([FP_TOUCH] 3, floorplanner's walking): a stick at
-- the lower left, a drag elsewhere turns, a tap is the left click at the
-- finger and a finger held still the right one; Jump and Menu
local fingers, stick = {}, nil
local touch_jump = false
local touch_bar = nil
local function screen()
	local sc = magic.ui.scale
	return magic.ui.root.width * sc, magic.ui.root.height * sc
end
local function on_ui(x, y)
	local sc = magic.ui.scale
	local b = touch_bar
	if b and b.visible then
		local p, s = b.screenPosition, b.size
		if x / sc >= p.x and y / sc >= p.y and x / sc < p.x + s.x and
				y / sc < p.y + s.y then
			return true
		end
	end
	return menu.held() or ui_utils.clicks_wanted() or
			(editing and kit.over_ui(x, y))
end
if TOUCH then
	touch_bar = magic.ui.root:CreateChild("Window")
	touch_bar.defaultStyle = magic.cache:GetResource("XMLFile",
			"ui_utils/res/style.xml")
	touch_bar:SetStyleAuto()
	touch_bar:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(6, 6, 6, 6))
	touch_bar:SetAlignment(magic.HA_RIGHT, magic.VA_BOTTOM)
	touch_bar:SetPosition(-8, -8)
	touch_bar.opacity = 0.92
	for _, b in ipairs({{"Jump", function() touch_jump = true end},
			{"Menu", function() menu.open() end}}) do
		local btn = touch_bar:CreateChild("Button")
		btn:SetStyleAuto()
		btn.minHeight = 24
		local t = btn:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(b[1])
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		btn.minWidth = t.width + 16
		magic.SubscribeToEvent(btn, "Released", b[2])
	end
	magic.SubscribeToEvent("TouchBegin", function(_, data)
		local id, x, y = data:GetInt("TouchID"), data:GetInt("X"),
				data:GetInt("Y")
		local f = {x = x, y = y, x0 = x, y0 = y, t0 = buildat.get_time_us(),
			ui = on_ui(x, y)}
		fingers[id] = f
		if f.ui or (editing and kit.view() ~= "walk") then
			f.ui = true
			return
		end
		local w, h = screen()
		if not stick and x < w * 0.45 and y > h * 0.55 then
			f.stick = true
			stick = {f = 0, r = 0}
		end
	end)
	magic.SubscribeToEvent("TouchMove", function(_, data)
		local f = fingers[data:GetInt("TouchID")]
		if not f or f.ui then
			return
		end
		local x, y = data:GetInt("X"), data:GetInt("Y")
		f.x, f.y = x, y
		if math.abs(x - f.x0) + math.abs(y - f.y0) > 8 * magic.ui.scale then
			f.moved = true
		end
		local w, h = screen()
		if f.stick then
			-- A tenth of the screen's short side is full speed
			local r = math.min(w, h) * 0.1
			stick.r = math.max(-1, math.min(1, (x - f.x0) / r))
			stick.f = math.max(-1, math.min(1, -(y - f.y0) / r))
			return
		end
		-- The mouse sensitivity's, at half of 0.2 (floorplanner's)
		yaw_node:Yaw(data:GetInt("DX") * 0.1)
		camera_node:Pitch(data:GetInt("DY") * 0.1)
		local pitch = camera_node.rotation:PitchAngle()
		if pitch > 89 or pitch < -89 then
			camera_node:Pitch(-data:GetInt("DY") * 0.1)
		end
	end)
	magic.SubscribeToEvent("TouchEnd", function(_, data)
		local id = data:GetInt("TouchID")
		local f = fingers[id]
		fingers[id] = nil
		if not f then
			return
		end
		if f.stick then
			stick = nil
		end
		-- A tap: the left click at the finger, in play (Kit's editor takes
		-- its own)
		if not f.ui and not f.stick and not f.moved and not f.held and
				not editing and buildat.get_time_us() - f.t0 < 500000 then
			act(target(f.x, f.y), true)
		end
	end)
end

-- What a click would do, shown on what is pointed at (play; the editor
-- shows its own); a touchscreen's at the finger down, held still the right
-- click's
local function show_pointed()
	if editing or menu.held() or ui_utils.mouse_look_paused() then
		kit.show_target(nil)
		return
	end
	if not TOUCH then
		kit.show_target(target())
		return
	end
	local f = nil
	for _, g in pairs(fingers) do
		if not g.ui and not g.stick and not g.moved then
			f = g
		end
	end
	local t = f and target(f.x, f.y) or nil
	kit.show_target(t)
	if f and not f.held and buildat.get_time_us() - f.t0 > 500000 then
		f.held = true
		act(t, false)
	end
end

local pos_frames = 0
magic.SubscribeToEvent("Update", function(_, data)
	local dt = data:GetFloat("TimeStep")
	-- Edit mode frees the pointer for the editor's clicks, but in its
	-- crosshair
	if kit.editing() ~= editing or kit.looking() ~= looking then
		editing, looking = kit.editing(), kit.looking()
		if not menu.held() then
			capture(true)
		end
	end
	-- Walking: in play and the editor's walking view; the crosshair where
	-- the mouse looks
	local walking = not editing or kit.view() == "walk"
	for _, bar in ipairs(crosshair) do
		bar.visible = not TOUCH and (not editing or looking)
	end
	if touch_bar then
		touch_bar.visible = not editing
	end
	show_pointed()
	pos_frames = pos_frames + 1
	if pos_frames >= 15 or put then
		pos_frames = 0
		send_pos()
	end
	physics()
	-- Below the World's region: back where the server put them
	if player_node.position.y < -140 then
		player_node.position = spawn_at
		body.linearVelocity = magic.Vector3(0, 0, 0)
	end
	-- A heightmap surface has no collision on the client: the feet are
	-- kept on it
	-- simplified: a floor under the capsule's middle, no slope or wall;
	-- a heightfield shape on the client (CollisionShape::SetTerrain) is
	-- the upgrade
	if physics_on and heightmap.terrain then
		local p = player_node.position
		local h = heightmap.height_at(p.x, p.z)
		if h and p.y - PLAYER_HEIGHT / 2 < h then
			player_node.position = magic.Vector3(p.x, h + PLAYER_HEIGHT / 2, p.z)
			local bv = body.linearVelocity
			if bv.y < 0 then
				bv.y = 0
				body.linearVelocity = bv
			end
			touches_ground = true
		end
	end
	local mx, my = ui_utils.mouse_look_move()
	if menu.held() or not walking or TOUCH then
		mx, my = 0, 0
	elseif editing and not looking then
		local m = magic.input:GetMouseMove()
		if magic.input:GetMouseButtonDown(magic.MOUSEB_RIGHT) then
			mx, my = m.x, m.y
		else
			mx, my = 0, 0
		end
	end
	camera_node:Pitch(my * 0.1)
	local pitch = camera_node.rotation:PitchAngle()
	if pitch > 89 or pitch < -89 then
		camera_node:Pitch(-my * 0.1)
	end
	yaw_node:Yaw(mx * 0.1)

	local want = magic.Vector3(0, 0, 0)
	local fwd, side = 0, 0
	if magic.input:GetKeyDown(magic.KEY_W) then fwd = fwd + 1 end
	if magic.input:GetKeyDown(magic.KEY_S) then fwd = fwd - 1 end
	if magic.input:GetKeyDown(magic.KEY_D) then side = side - 1 end
	if magic.input:GetKeyDown(magic.KEY_A) then side = side + 1 end
	if stick then
		fwd, side = fwd + stick.f, side - stick.r
	end
	if menu.held() or not walking then
		fwd, side = 0, 0
	end
	if fwd ~= 0 or side ~= 0 then
		local u = yaw_node.worldDirection
		local v = u:CrossProduct(magic.Vector3(0, 1, 0))
		want = (u * fwd + v * side) * (MOVE_SPEED /
				math.max(1, math.sqrt(fwd * fwd + side * side)))
	end
	if physics_on then
		local cur = body.linearVelocity
		cur.y = 0
		local diff = (want - cur) / MOVE_SPEED
		if diff:Length() > 0.1 then
			body:ApplyImpulse(diff:Normalized() * dt * PLAYER_ACCELERATION *
					PLAYER_MASS)
		else
			local bv = body.linearVelocity
			bv.x, bv.z = want.x, want.z
			body.linearVelocity = bv
		end
		local jump = touch_jump or (walking and
				(magic.input:GetKeyDown(magic.KEY_SPACE) or
				magic.input:GetKeyPress(magic.KEY_SPACE)))
		if jump and touches_ground and not menu.held() and
				math.abs(body.linearVelocity.y) < JUMP_SPEED then
			local bv = body.linearVelocity
			bv.y = JUMP_SPEED
			body.linearVelocity = bv
		end
	end
	local p = player_node:GetWorldPosition()
	status_text.visible = not editing
	status_text:SetText(string.format("(%d, %d, %d)  in hand: %s",
			math.floor(p.x + 0.5), math.floor(p.y - 0.4 + 0.5),
			math.floor(p.z + 0.5), MATERIALS[material]))
	touch_jump = false
	help_text:SetText(editing and "" or TOUCH and
			"Stick: walk  drag: look  tap: use/dig  hold: place" or
			"WASD Space: walk, jump  left: use or dig  right: place  " ..
			"0-9: voxel  F6: edit  L: log in  Esc: menu")
end)

-- PhysicsCollision is only sent on a Bullet step: the grounded flag is the
-- last step's until the next PreStep
magic.SubscribeToEvent("PhysicsPreStep", function()
	touches_ground = false
end)
magic.SubscribeToEvent("PhysicsCollision", function(_, data)
	local a = data:GetPtr("Node", "NodeA")
	local b = data:GetPtr("Node", "NodeB")
	if a:GetID() ~= player_node:GetID() and b:GetID() ~= player_node:GetID() then
		return
	end
	local y = player_node:GetWorldPosition().y
	local contacts = data:GetBuffer("Contacts")
	while not contacts.eof do
		local position = contacts:ReadVector3()
		contacts:ReadVector3()
		contacts:ReadFloat()
		contacts:ReadFloat()
		if position.y < y then
			touches_ground = true
		end
	end
end)
-- vim: set noet ts=4 sw=4:
