-- Buildat: apps/workbench/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- [KIT] Workbench's client: a player walking on the floor (demo_digger's
-- physics, copied), Kit's editor, and the voxels to build with.
--   W A S D, Space: walk, jump; the mouse looks
--   E, or the right button on a component: use it
--   (with edit rights, or where a component grants it) the left button
--   digs, the right one places;
--   1...5 the voxel placed (stone, glass, wood, brick, grass)
--   F6 or the menu's "Edit": Kit's editor; there the pointer is free for
--   its clicks, and the right button held looks round. The menu's "Play"
--   and "Stop" (a builder's): the server Running or Stopped ([KIT] 4c)
--   L: log in (builtin/accounts' dialog)
--   Escape: the pause menu (extensions/pause_menu: Continue, Kit's Edit
--   and Play/Stop, Chat, Settings, Leave); in the tools a pending link
--   is cancelled first
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
local MATERIALS = {"stone", "glass", "wood", "brick", "grass"}

local scene = replicate.main_scene
local material = 1

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

local touches_ground = false
local physics_on = false
local spawned = false

-- Physics once there is a floor with its collision under the feet: the
-- volume arrives before Bullet's boxes
local function floor_ready()
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

-- The voxel the view points at, and the cell in front of it (demo_digger's
-- walk along the ray)
local function pointed()
	local p0 = buildat.Vector3(camera_node.worldPosition)
	local dir = buildat.Vector3(camera_node.worldDirection)
	local last = nil
	for i = 1, REACH * 10 do
		local p = (p0 + dir * i * 0.1):Round()
		if p ~= last then
			local v = voxelworld.get_static_voxel(p)
			if v.id ~= 1 and v.id ~= 0 then
				return p, last
			end
			last = p
		end
	end
end

local function build(p, voxel)
	if not p then
		return
	end
	buildat.send_packet("main:build", '{"p": [' .. p.x .. ', ' .. p.y .. ', ' ..
			p.z .. '], "voxel": "' .. voxel .. '"}')
end

-- What the view points at in play: a component near the ray (Kit's), used
local function use_pointed()
	local id = kit.pointed(camera_node.worldPosition,
			camera_node.worldDirection, REACH)
	if id then
		kit.use(id)
		return true
	end
	return false
end

-- Kit's items in the pause menu in place of its top bar
kit.editor{scene = scene, camera = camera_node, ground_y = 1, bar = false,
	solid = function(x, y, z)
		-- 0: not there, 1: air
		return voxelworld.get_static_voxel(magic.Vector3(x, y, z)).id > 1
	end}

-- The mouse turns the view in play; the menu and the tools free it. On the
-- web a lost pointer lock opens the menu, whose click takes it back
local editing = false
local menu
local function capture(on)
	ui_utils.mouse_look(on and not editing, function() menu.open() end)
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
	elseif key == magic.KEY_E and not editing then
		use_pointed()
	elseif key >= magic.KEY_1 and key < magic.KEY_1 + #MATERIALS then
		material = key - magic.KEY_1 + 1
	end
end)

magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	if editing or menu.held() or ui_utils.mouse_look_paused() then
		return
	end
	local button = data:GetInt("Button")
	local p, front = pointed()
	if button == magic.MOUSEB_LEFT then
		build(p, "air")
	elseif button == magic.MOUSEB_RIGHT and not use_pointed() then
		build(front, MATERIALS[material])
	end
end)

local pos_frames = 0
magic.SubscribeToEvent("Update", function(_, data)
	local dt = data:GetFloat("TimeStep")
	-- Edit mode frees the pointer for the editor's clicks
	if kit.editing() ~= editing then
		editing = kit.editing()
		if not menu.held() then
			capture(true)
		end
		for _, bar in ipairs(crosshair) do
			bar.visible = not editing
		end
	end
	pos_frames = pos_frames + 1
	if pos_frames >= 15 or put then
		pos_frames = 0
		send_pos()
	end
	physics()
	if player_node.position.y < -20 then
		player_node.position = magic.Vector3(0.5, 3, 0.5)
	end
	local mx, my = ui_utils.mouse_look_move()
	if menu.held() then
		mx, my = 0, 0
	elseif editing then
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
	if menu.held() then
		fwd, side = 0, 0
	end
	if fwd ~= 0 or side ~= 0 then
		local u = yaw_node.worldDirection
		local v = u:CrossProduct(magic.Vector3(0, 1, 0))
		want = (u * fwd + v * side):Normalized() * MOVE_SPEED
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
		if (magic.input:GetKeyDown(magic.KEY_SPACE) or
				magic.input:GetKeyPress(magic.KEY_SPACE)) and touches_ground and
				not menu.held() and
				math.abs(body.linearVelocity.y) < JUMP_SPEED then
			local bv = body.linearVelocity
			bv.y = JUMP_SPEED
			body.linearVelocity = bv
		end
	end
	local p = player_node:GetWorldPosition()
	status_text:SetText(string.format("(%d, %d, %d)  in hand: %s",
			math.floor(p.x + 0.5), math.floor(p.y - 0.4 + 0.5),
			math.floor(p.z + 0.5), MATERIALS[material]))
	help_text:SetText(editing and
			"Editing: click to select or place, right button held looks; " ..
			"F6 leaves  Esc: menu" or
			"WASD Space: walk, jump  E: use  left: dig  right: place/use  " ..
			"1-5: voxel  F6: edit  L: log in  Esc: menu")
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
