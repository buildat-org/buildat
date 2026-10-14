-- Buildat: demo_digger/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
-- Copyright 2014 Břetislav Štec <valsiterb@gmail.com>
local log = buildat.Logger("demo_digger")
local dump = buildat.dump
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")

--local RENDER_DISTANCE = 640
local RENDER_DISTANCE = 480
--local RENDER_DISTANCE = 320
--local RENDER_DISTANCE = 240
--local RENDER_DISTANCE = 160

local FOG_END = RENDER_DISTANCE * 1.2

-- The server fills the skylight bits of every voxel and the mesher shades the
-- geometry by them, which is what tells a cave apart from a shadow.
voxelworld.use_skylight = true

-- Lighting as in apps/sample_lighting_scene: a PBR voxel material lit in HDR and
-- tonemapped, so the sun can be brighter than white without the frame clipping
-- and a dug tunnel can be genuinely dark. The zone's ambient color is the sky,
-- which is what a surface with full skylight receives.
local SKY_AMBIENT = magic.Color(0.26, 0.33, 0.46)
-- Urho's PBR direct lighting is normalized, so a sun that reads as bright is a
-- much larger number here than under the legacy Diff technique
local SUN_BRIGHTNESS = 50.0
-- The way the light travels, so the sun is the other way
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.8}
-- Auto exposure would lift the inside of a tunnel back to mid grey, which is
-- the thing worth being dark in a digging game
local EXPOSURE_BIAS = 1.6

local PLAYER_HEIGHT = 1.7
local PLAYER_WIDTH = 0.9
local PLAYER_MASS = 70
local MOVE_SPEED = 10
local JUMP_SPEED = 7 -- Barely 2 voxels
local PLAYER_ACCELERATION = 40
local PLAYER_DECELERATION = 40

local scene = replicate.main_scene

local player_touches_ground = false
local player_crouched = false
local physics_enabled = false
local spawn_received = false

local pointed_voxel_p = nil
local pointed_voxel_p_above = nil
local pointed_voxel_visual_node = scene:CreateChild("node")
local pointed_voxel_visual_geometry =
		pointed_voxel_visual_node:CreateComponent("CustomGeometry")
do
	pointed_voxel_visual_geometry:BeginGeometry(0, magic.TRIANGLE_LIST)
	pointed_voxel_visual_geometry:SetNumGeometries(1)
	local function define_face(lc, uc, color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(lc.x, uc.y, uc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(uc.x, uc.y, uc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(uc.x, uc.y, lc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(uc.x, uc.y, lc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(lc.x, uc.y, lc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(lc.x, uc.y, uc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
	end

	-- Full face
	--local d = 0.502
	--local c = magic.Color(0.04, 0.12, 0.04)
	--define_face(magic.Vector3(-d, d, -d), magic.Vector3(d, d, d), c)
	--pointed_voxel_visual_geometry:Commit()
	--local m = magic.Material.new()
	--m:SetTechnique(0, magic.cache:GetResource("Technique",
	--		"Techniques/NoTextureVColAdd.xml"))

	-- Face edges
	local d = 0.502
	local d2 = 1.0 / 16
	local c = magic.Color(0.12, 0.36, 0.12)
	define_face(magic.Vector3(-d, d, d-d2), magic.Vector3(d, d, d), c)
	define_face(magic.Vector3(-d, d, -d), magic.Vector3(d, d, -d+d2), c)
	define_face(magic.Vector3(d-d2, d, -d+d2), magic.Vector3(d, d, d-d2), c)
	define_face(magic.Vector3(-d, d, -d+d2), magic.Vector3(-d+d2, d, d-d2), c)
	pointed_voxel_visual_geometry:Commit()
	local m = magic.Material.new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureVColMultiply.xml"))

	pointed_voxel_visual_geometry:SetMaterial(0, m)
	pointed_voxel_visual_node.enabled = false
end

-- demo_undermine's own cut of a voxel word. main.cpp sets it on the registry and
-- both ends have to agree on it.
--
-- Nothing here uses VoxelInstance.id or :get_skylight(): those are the
-- *default* cut, hardcoded in the bindings, and under this format they would
-- read the load and the support as part of the id.
local FIELD = {
	id    = {shift = 0,  width = 8},
	light = {shift = 8,  width = 4},
	param = {shift = 12, width = 8},
}

local function field_of(v, f)
	return math.floor(v.data / 2 ^ f.shift) % 2 ^ f.width
end

-- The param carries both of the simulation's numbers; see the layout at the
-- top of main.cpp. Support is how far the voxel is from something holding it
-- up, and the band is how much of what it can carry is already on it, both
-- 0...15.
local function support_of(v)
	return field_of(v, FIELD.param) % 16
end

local function band_of(v)
	return math.floor(field_of(v, FIELD.param) / 16)
end

-- In the order main.cpp adds them, which is what the ids are
local MATERIAL = {
	"air", "bedrock", "rock", "dirt", "grass", "sand", "rubble",
	"timber", "brick", "water", "trunk", "leaves", "wet dirt",
}
local M_AIR = 1

-- What the right button places, and the keys that pick it. Rock is what a
-- mine is made of, timber props a ceiling, brick carries a load; dirt is
-- there to backfill with.
local BUILD_MATERIALS = {
	{key = magic.KEY_1, id = 3, name = "rock"},
	{key = magic.KEY_2, id = 8, name = "timber"},
	{key = magic.KEY_3, id = 9, name = "brick"},
	{key = magic.KEY_4, id = 4, name = "dirt"},
	-- Not something to build with: something to pour next to dirt and watch
	{key = magic.KEY_5, id = 10, name = "water"},
}
local build_material = 1

magic.input:SetMouseVisible(false)

-- Set up zone (global visual parameters)
do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = SKY_AMBIENT
	zone.fogColor = magic.Color(0.60, 0.72, 0.88)
	zone.fogStart = FOG_END * 0.6
	zone.fogEnd = FOG_END
	zone.priority = -1
	zone.override = true
	-- What the voxel shader reflects; see builtin/voxel_shading
	zone.zoneTexture = magic.cache:GetResource("TextureCube",
			voxel_shading.sky_cubemap)
end

-- Add lights
do
	local node = scene:CreateChild("DirectionalLight")
	node.direction = magic.Vector3(SUN_DIR.x, SUN_DIR.y, SUN_DIR.z)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.brightness = SUN_BRIGHTNESS
	light.color = magic.Color(1.0, 0.96, 0.88)
end

voxel_shading.create_skybox(scene, SUN_DIR)

-- Add a node that the player can use to walk around with
local player_node = scene:CreateChild("Player")
local player_shape = player_node:CreateComponent("CollisionShape")
do
	-- Placeholder until main:spawn arrives with terrain height at this x,z
	player_node.position = magic.Vector3(-5, 80, 257)
	player_node.direction = magic.Vector3(-1, 0, 0.4)
	---[[
	local body = player_node:CreateComponent("RigidBody")
	body.friction = 0
	--body.linearVelocity = magic.Vector3(0, -10, 0)
	body.angularFactor = magic.Vector3(0, 0, 0)
	body.gravityOverride = magic.Vector3(0, -15.0, 0) -- A bit more than normally
	-- Default COLLISION_ACTIVE drops events when the body sleeps, so jump
	-- would fail while standing still.
	body.collisionEventMode = magic.COLLISION_ALWAYS
	--player_shape:SetBox(magic.Vector3(1, 1.7*PLAYER_SCALE, 1))
	player_shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT)
	--]]
end

-- Volume data can exist before Bullet boxes. Require a solid voxel under
-- the feet and a RigidBody on that chunk (set_voxel_physics_boxes).
local function floor_has_collision()
	local p = player_node:GetWorldPosition()
	local floor = magic.Vector3(p.x, p.y - PLAYER_HEIGHT / 2 - 0.25, p.z)
	local v = voxelworld.get_static_voxel(floor)
	if v.id < 2 then
		return false
	end
	local chunk_p = voxelworld.get_chunk_position(floor)
	if not chunk_p then
		return false
	end
	-- Not "does the chunk node have a RigidBody": that is true from the
	-- moment the client starts building the collision, which is before there
	-- is any of it. See voxelworld.chunk_has_physics().
	return voxelworld.chunk_has_physics(chunk_p)
end

-- The client takes a chunk's collision apart and puts it back a step or two
-- later, so while a chunk is being rebuilt there is nothing to stand on. It
-- happens most while a world loads. Freeze rather than fall: a floor that is
-- missing for two frames is not a floor that is missing.
--
-- Only the chunk matters here, not whether there is a solid voxel below --
-- jumping and standing at a ledge are not this. The hold is capped so that
-- genuinely unloaded space does not lock the player in the air forever.
local PHYSICS_HOLD_MAX = 2.0
local physics_held = 0

local function floor_chunk_ready()
	local p = player_node:GetWorldPosition()
	local floor = magic.Vector3(p.x, p.y - PLAYER_HEIGHT / 2 - 0.25, p.z)
	local chunk_p = voxelworld.get_chunk_position(floor)
	if not chunk_p then
		return true
	end
	return voxelworld.chunk_has_physics(chunk_p)
end

local function hold_physics_while_floor_rebuilds(dt)
	if not physics_enabled then
		return
	end
	local body = player_node:GetComponent("RigidBody")
	if not body then
		return
	end
	if floor_chunk_ready() or physics_held > PHYSICS_HOLD_MAX then
		if physics_held > 0 then
			physics_held = 0
			body.mass = PLAYER_MASS
		end
		return
	end
	if physics_held == 0 then
		log:info("player held: the floor chunk is being rebuilt")
		body.mass = 0
		local bv = body.linearVelocity
		bv.y = 0
		body.linearVelocity = bv
	end
	physics_held = physics_held + dt
end

local function enable_physics()
	if physics_enabled or not spawn_received then
		return
	end
	if not floor_has_collision() then
		return
	end
	local body = player_node:GetComponent("RigidBody")
	if not body then
		return
	end
	body.mass = PLAYER_MASS
	physics_enabled = true
	log:info("player physics enabled")
end

-- Free move: the camera goes where it is pointed, through anything, and
-- nothing pulls it down. What it is for is looking at what the structures
-- menu put up -- which is why placing one while it is on takes the camera to
-- somewhere the whole thing can be seen from.
local FREE_MOVE_SPEED = 22
local free_move = false

local function set_free_move(on)
	free_move = on
	local body = player_node:GetComponent("RigidBody")
	if body then
		body.useGravity = not on
		body.linearVelocity = magic.Vector3(0, 0, 0)
	end
	if player_crouched then
		player_shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT)
		player_crouched = false
	end
	log:info(on and "free move on" or "free move off")
end

-- Add a camera so we can look at the scene
local camera_node = player_node:CreateChild("Camera")
do
	camera_node.position = magic.Vector3(0, 0.411*PLAYER_HEIGHT, 0)
	--camera_node:Pitch(13.60000)
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.5 * math.min(
			PLAYER_WIDTH * 0.15,
			PLAYER_HEIGHT * (0.5 - 0.411)
	)
	camera.farClip = RENDER_DISTANCE
	-- Of the screen's short side, a portrait one's width
	magic.keep_fov(camera, 75)

	-- And this thing so the camera is shown on the screen
	local viewport = magic.Viewport:new(scene, camera_node:GetComponent("Camera"))
	magic.set_preferred_viewports({viewport})

	magic.renderer.HDRRendering = true
	local rp = viewport.renderPath:Clone()
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/BloomHDR.xml"))
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/Tonemap.xml"))
	rp:Append(magic.cache:GetResource("XMLFile",
			"PostProcess/GammaCorrection.xml"))
	-- Tonemap.xml ships with Reinhard on; Uncharted2 keeps more contrast in
	-- the shadows, which is where a dug tunnel is
	rp:SetEnabled("TonemapReinhardEq3", false)
	rp:SetEnabled("TonemapUncharted2", true)
	rp:SetShaderParameter("TonemapExposureBias", EXPOSURE_BIAS)
	viewport.renderPath = rp
end

-- Tell about the camera to the voxel world so it can do stuff based on the
-- camera's position and other properties
voxelworld.set_camera(camera_node)
voxel_shading.set_camera(camera_node)

---[[
-- Add a light to the camera
do
	local node = camera_node:CreateChild("Light")
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_POINT
	light.castShadows = false
	-- Enough to dig by without lifting a tunnel to the brightness of outside;
	-- a PBR point light needs a much larger number than the legacy one did
	light.brightness = 15.0
	light.color = magic.Color(1.0, 0.97, 0.92)
	-- A pool of light around the player rather than a lit tunnel, so that
	-- digging into the dark still reads as going into the dark. The ramp is
	-- what keeps the edge of it from showing: full brightness out to two
	-- voxels, then a smoothstep to nothing at five, flat at both ends.
	-- lamp_ramp.png holds that curve as 64 texels of distance/range.
	light.range = 5.0
	light.fadeDistance = 5.0
	light.rampTexture = magic.cache:GetResource("Texture2D",
			"main/lamp_ramp.png")
end
--]]

-- Add some text
local title_text = magic.ui.root:CreateChild("Text")
local misc_text = magic.ui.root:CreateChild("Text")
local worldgen_text = magic.ui.root:CreateChild("Text")
local wait_text = magic.ui.root:CreateChild("Text")
do
	title_text:SetText("demo_undermine/init.lua")
	title_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
	title_text.horizontalAlignment = magic.HA_CENTER
	title_text.verticalAlignment = magic.VA_TOP
	title_text:SetPosition(0, 20)

	misc_text:SetText("")
	misc_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
	misc_text.horizontalAlignment = magic.HA_CENTER
	misc_text.verticalAlignment = magic.VA_TOP
	misc_text:SetPosition(0, 40)

	worldgen_text:SetText("")
	worldgen_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
	worldgen_text.horizontalAlignment = magic.HA_CENTER
	worldgen_text.verticalAlignment = magic.VA_TOP
	worldgen_text:SetPosition(0, 60)

	wait_text:SetText("Generating terrain...")
	wait_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 24)
	wait_text.horizontalAlignment = magic.HA_CENTER
	wait_text.verticalAlignment = magic.VA_CENTER
	wait_text:SetPosition(0, 0)

	local function crosshair_bar(w, h)
		local bar = magic.ui.root:CreateChild("BorderImage")
		bar.width = w
		bar.height = h
		bar.horizontalAlignment = magic.HA_CENTER
		bar.verticalAlignment = magic.VA_CENTER
		bar:SetPosition(0, 0)
		bar.color = magic.Color(1, 1, 1)
	end
	crosshair_bar(15, 1)
	crosshair_bar(1, 15)
end

local function set_generating_status(queue_size)
	if spawn_received then
		wait_text:SetText("")
		if queue_size and queue_size > 0 then
			worldgen_text:SetText("Worldgen queue size: "..queue_size)
		else
			worldgen_text:SetText("")
		end
		return
	end
	if queue_size and queue_size > 0 then
		wait_text:SetText("Generating terrain... ("..queue_size.." sections left)")
	else
		wait_text:SetText("Generating terrain...")
	end
end

-- Unfocus UI
magic.ui:SetFocusElement(nil)

-- The structures the server can put up, in the order the menu lists them.
-- Placing one and then cutting a pillar out of it is the whole point of
-- having them: building a cathedral by hand first is tedium, not a game.
local STRUCTURES = {
	{name = "chamber", label = "Chamber - too wide to roof"},
	{name = "cathedral", label = "Cathedral - pillars and roof"},
	{name = "bridge", label = "Bridge - deck on piers"},
	{name = "mineshaft", label = "Mineshaft - timber props"},
}

local structure_menu = nil

local function place_structure(name, p)
	local data = cereal.binary_output({
		name = name,
		p = {
			x = math.floor(p.x + 0.5),
			y = math.floor(p.y + 0.5),
			z = math.floor(p.z + 0.5),
		},
	}, {"object",
		{"name", "string"},
		{"p", {"object",
			{"x", "int32_t"},
			{"y", "int32_t"},
			{"z", "int32_t"},
		}},
	})
	buildat.send_packet("main:place_structure", data)
end

-- Put the camera somewhere the whole of a box is in frame, looking at the
-- middle of it: off one corner and above, far enough back for its size.
local function overlook(lc, uc)
	local cx = (lc.x + uc.x) / 2
	local cy = (lc.y + uc.y) / 2
	local cz = (lc.z + uc.z) / 2
	local size = math.max(uc.x - lc.x, uc.y - lc.y, uc.z - lc.z) + 1
	local d = size * 1.3 + 12
	-- Off a corner and above, so three sides of the box are in frame. Which
	-- corner is whichever leaves the camera in open air: standing inside a
	-- tree shows a leaf and nothing else.
	local CORNERS = {
		{-0.62, -0.62}, {0.62, -0.62}, {0.62, 0.62}, {-0.62, 0.62},
	}
	local oy = 0.48
	local ox, oz = CORNERS[1][1], CORNERS[1][2]
	for _, c in ipairs(CORNERS) do
		local p = magic.Vector3(cx + c[1] * d, cy + oy * d, cz + c[2] * d)
		local clear = true
		-- The camera itself and one voxel around it, since a solid voxel
		-- next to the near clip plane fills the frame as well as one in it
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local v = voxelworld.get_static_voxel(buildat.Vector3(
							math.floor(p.x + 0.5) + dx,
							math.floor(p.y + 0.5) + dy,
							math.floor(p.z + 0.5) + dz))
					local id = field_of(v, FIELD.id)
					if id ~= M_AIR and id ~= 0 then
						clear = false
					end
				end
			end
		end
		if clear then
			ox, oz = c[1], c[2]
			break
		end
	end
	player_node.position = magic.Vector3(cx + ox * d, cy + oy * d, cz + oz * d)
	-- Yaw at the middle, and the pitch is whatever looking down at it takes
	player_node.direction = magic.Vector3(-ox, 0, -oz)
	local horiz = math.sqrt(ox * ox + oz * oz)
	camera_node.rotation = magic.Quaternion(
			math.deg(math.atan2(oy, horiz)), 0, 0)
end

-- The views: the same voxels meshed out of a registry whose materials wear a
-- gradient instead of their texture, by how close they are to failing. The
-- server builds one per mode and sends them; see build_view_registry() in
-- main.cpp for why they cost no storage. Mode 0 is off.
local VIEW_NAMES = {"load", "support", "danger"}
local view_regs = {}
local play_reg = nil
local view_mode = 0

buildat.sub_packet("main:view_registry", function(data)
	local values = cereal.binary_input(data, {"object",
		{"mode", "int32_t"},
		{"data", "string"},
	})
	local reg = buildat.createVoxelRegistry()
	reg:deserialize(values.data)
	view_regs[values.mode + 1] = reg
	log:info("view registry "..(VIEW_NAMES[values.mode + 1] or
			values.mode)..": "..reg:dump_format())
end)

-- While a view is on, the chunks are drawn by their vertex colour
-- and nothing else: no texture, no light, no reflection. Registered after
-- voxel_shading's own material callback, so this is the one that wins.
local VIEW_TECHNIQUE = "Techniques/NoTextureUnlitVCol.xml"

voxelworld.sub_material_update(function(node)
	if view_mode == 0 then
		return
	end
	local cg = node:GetComponent("CustomGeometry")
	if not cg then
		return
	end
	local i = 0
	while true do
		local m = cg:GetMaterial(i)
		if m == nil then
			break
		end
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				VIEW_TECHNIQUE))
		i = i + 1
	end
end)

local function set_view_mode(mode)
	if mode == view_mode then
		return
	end
	if mode ~= 0 and not view_regs[mode] then
		log:warning("view: registry "..mode.." has not arrived")
		return
	end
	view_mode = mode
	play_reg = play_reg or voxelworld.get_voxel_registry()
	voxelworld.set_voxel_registry(mode ~= 0 and view_regs[mode] or play_reg)
	-- The vertex colour is the band, so nothing else may be in it: with
	-- skylight on, a view of a dark mine is a dark mine
	voxelworld.use_skylight = (mode == 0)
	voxelworld.remesh_all()
	log:info("view: "..(mode == 0 and "off" or VIEW_NAMES[mode]))
end

buildat.sub_packet("main:structure_placed", function(data)
	local values = cereal.binary_input(data, {"object",
		{"lc", {"object",
			{"x", "int32_t"}, {"y", "int32_t"}, {"z", "int32_t"},
		}},
		{"uc", {"object",
			{"x", "int32_t"}, {"y", "int32_t"}, {"z", "int32_t"},
		}},
	})
	-- Only in free move: standing inside what was just built is the other
	-- way to experience it, and taking the camera away would spoil it
	if free_move then
		overlook(values.lc, values.uc)
	end
end)

local function close_structure_menu()
	if structure_menu then
		uistack.main:pop(structure_menu.root)
		structure_menu = nil
		magic.input:SetMouseVisible(false)
	end
end

-- Opened with B, and it takes the mouse back so the buttons can be clicked;
-- arrows and enter work too, from ui_utils.
local function open_structure_menu()
	if structure_menu then
		close_structure_menu()
		return
	end
	-- On a uistack level of its own: that is what gives it the keyboard, and
	-- what ui_utils' menus subscribe to their keys through
	local root = uistack.main:push({desc = "structures"})
	local menu = ui_utils.vertical_menu(root, {
		-- Wide enough for the longest label; the window follows its buttons
		min_width = 330,
		on_key = function(key)
			if key == magic.KEY_ESCAPE or key == magic.KEY_B then
				close_structure_menu()
				return true
			end
		end,
	})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	for _, st in ipairs(STRUCTURES) do
		menu:add(st.label, function()
			-- Where the player stands, so a building goes up around them
			place_structure(st.name, player_node:GetWorldPosition())
			close_structure_menu()
		end)
	end
	menu:add("< back", close_structure_menu)
	structure_menu = {root = root, menu = menu}
	magic.input:SetMouseVisible(true)
end

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	-- While the menu is up it has the keyboard, and its own handler is what
	-- closes it. Without this, escape would disconnect the client from
	-- inside a menu, which is not what anyone means by escape.
	if structure_menu then
		return
	end
	if key == magic.KEY_ESCAPE then
		log:info("KEY_ESCAPE pressed")
		buildat.leave()
	end
	if key == magic.KEY_B then
		open_structure_menu()
	end
	if key == magic.KEY_TAB then
		set_free_move(not free_move)
	end
	if key == magic.KEY_V then
		-- Off, load, support, danger, off...
		set_view_mode((view_mode + 1) % (#VIEW_NAMES + 1))
	end
	for i, m in ipairs(BUILD_MATERIALS) do
		if key == m.key then
			build_material = i
			log:info("Building with "..m.name)
		end
	end
end)

-- Returns: nil or p_under, p_above: buildat.Vector3
-- TODO: This algorithm is quite wasteful
local function find_pointed_voxel(camera_node)
	local max_d = 6
	local d_per_step = 0.1
	local p0 = buildat.Vector3(camera_node.worldPosition)
	local dir = buildat.Vector3(camera_node.worldDirection)
	local last_p = nil
	--log:verbose("p0="..p0:dump()..", dir="..dir:dump())
	for i = 1, math.floor(max_d / d_per_step) do
		local p = (p0 + dir * i * d_per_step):Round()
		if p ~= last_p then
			local v = voxelworld.get_static_voxel(p)
			local id = field_of(v, FIELD.id)
			if id ~= M_AIR and id ~= 0 then
				return p, last_p
			end
			last_p = p
		end
	end
	return nil
end

magic.SubscribeToEvent("MouseButtonDown", function(event_type, event_data)
	if structure_menu then
		return -- The menu has the mouse
	end
	local button = event_data:GetInt("Button")
	log:info("MouseButtonDown: "..button)
	if button == magic.MOUSEB_RIGHT then
		local p = pointed_voxel_p_above
		if p then
			local data = cereal.binary_output({
				p = {
					x = math.floor(p.x+0.5),
					y = math.floor(p.y+0.5),
					z = math.floor(p.z+0.5),
				},
				material = BUILD_MATERIALS[build_material].id,
			}, {"object",
				{"p", {"object",
					{"x", "int32_t"},
					{"y", "int32_t"},
					{"z", "int32_t"},
				}},
				{"material", "int32_t"},
			})
			buildat.send_packet("main:place_voxel", data)
		end
	end
	if button == magic.MOUSEB_LEFT then
		local p = pointed_voxel_p
		if p then
			local data = cereal.binary_output({
				p = {
					x = math.floor(p.x+0.5),
					y = math.floor(p.y+0.5 + 0.2),
					z = math.floor(p.z+0.5),
				},
			}, {"object",
				{"p", {"object",
					{"x", "int32_t"},
					{"y", "int32_t"},
					{"z", "int32_t"},
				}},
			})
			buildat.send_packet("main:dig_voxel", data)
		end
	end
	if button == magic.MOUSEB_MIDDLE then
		local p = player_node.position
		local v = voxelworld.get_static_voxel(p)
		log:info("get_static_voxel("..buildat.Vector3(p):dump()..")"..
				" returned v.id="..dump(v.id))
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	--log:info("Update")
	local dt = event_data:GetFloat("TimeStep")

	-- Samples how much sky the camera can see, per direction, which is what
	-- dims the reflected sky under ground; see builtin/voxel_shading
	voxel_shading.update(dt)

	if camera_node then
		local p, p_above = find_pointed_voxel(camera_node)
		pointed_voxel_p = p
		pointed_voxel_p_above = p_above
		if p and p_above then
			local v = voxelworld.get_static_voxel(p)
			--log:info("pointed voxel: "..p:dump()..": "..v.id)
			pointed_voxel_visual_node.position = p
			local d = p_above - p
			if d.x > 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(90, 0, -90)
			elseif d.x < 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(90, 0, 90)
			elseif d.y > 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(0, 0, 0)
			elseif d.y < 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(0, 0, -180)
			elseif d.z > 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(90, 0, 0)
			elseif d.z < 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(-90, 0, 0)
			end
			pointed_voxel_visual_node.enabled = true
		else
			pointed_voxel_visual_node.enabled = false
		end
	end

	if player_node then
		-- If falling out of world, restore onto world
		if player_node.position.y < -500 then
			player_node.position = magic.Vector3(0, 500, 0)
		end

		local dmouse = magic.input:GetMouseMove()
		--log:info("dmouse: ("..dmouse.x..", "..dmouse.y..")")
		camera_node:Pitch(dmouse.y * 0.1)
		player_node:Yaw(dmouse.x * 0.1)
		--[[log:info("y="..player_node:GetRotation():YawAngle())
		log:info("p="..camera_node:GetRotation():PitchAngle())]]

		local body = player_node:GetComponent("RigidBody")
		if not free_move then
			enable_physics()
		end
		hold_physics_while_floor_rebuilds(dt)

		if free_move then
			-- Level, along the horizontal part of where the camera looks, so
			-- that looking down at something and holding W flies over it
			-- instead of into it. Space and shift are what go up and down.
			local wanted = magic.Vector3(0, 0, 0)
			local d = camera_node.worldDirection
			local dir = magic.Vector3(d.x, 0, d.z)
			if dir:Length() < 0.001 then
				-- Straight up or straight down: the camera says nothing
				-- about which way forward is, so the body's yaw does
				local u = player_node.direction
				dir = magic.Vector3(u.x, 0, u.z)
			end
			dir = dir:Normalized()
			local right = dir:CrossProduct(magic.Vector3(0, 1, 0))
			if magic.input:GetKeyDown(magic.KEY_W) then
				wanted = wanted + dir
			end
			if magic.input:GetKeyDown(magic.KEY_S) then
				wanted = wanted - dir
			end
			if magic.input:GetKeyDown(magic.KEY_D) then
				wanted = wanted - right
			end
			if magic.input:GetKeyDown(magic.KEY_A) then
				wanted = wanted + right
			end
			if magic.input:GetKeyDown(magic.KEY_SPACE) then
				wanted = wanted + magic.Vector3(0, 1, 0)
			end
			if magic.input:GetKeyDown(magic.KEY_SHIFT) then
				wanted = wanted - magic.Vector3(0, 1, 0)
			end
			if wanted:Length() > 0.01 then
				wanted = wanted:Normalized() * FREE_MOVE_SPEED
			end
			body.linearVelocity = wanted
		end

		if not free_move then 
			local wanted_v = magic.Vector3(0, 0, 0) -- re. world
			do
				local wanted_v_re_body = magic.Vector3(0, 0, 0)
				if magic.input:GetKeyDown(magic.KEY_W) then
					wanted_v_re_body.x = wanted_v_re_body.x + 1
				end
				if magic.input:GetKeyDown(magic.KEY_S) then
					wanted_v_re_body.x = wanted_v_re_body.x - 1
				end
				if magic.input:GetKeyDown(magic.KEY_D) then
					wanted_v_re_body.z = wanted_v_re_body.z - 1
				end
				if magic.input:GetKeyDown(magic.KEY_A) then
					wanted_v_re_body.z = wanted_v_re_body.z + 1
				end
				wanted_v_re_body = wanted_v_re_body:Normalized() * MOVE_SPEED
				local u = player_node.direction
				local v = u:CrossProduct(magic.Vector3(0, 1, 0))
				wanted_v = wanted_v + u * wanted_v_re_body.x
				wanted_v = wanted_v + v * wanted_v_re_body.z
			end

			local current_v = body.linearVelocity
			current_v.y = 0

			local v_diff = (wanted_v - current_v) / MOVE_SPEED

			if v_diff:Length() > 0.1 then
				v_diff = v_diff:Normalized()
				local f = v_diff * dt * PLAYER_ACCELERATION * PLAYER_MASS
				body:ApplyImpulse(f)
			else
				local bv = body.linearVelocity
				bv.x = wanted_v.x
				bv.z = wanted_v.z
				body.linearVelocity = bv
			end
		end

		if not free_move and (magic.input:GetKeyDown(magic.KEY_SPACE) or
				magic.input:GetKeyPress(magic.KEY_SPACE)) then
			if player_touches_ground and
					math.abs(body.linearVelocity.y) < JUMP_SPEED then
				local bv = body.linearVelocity
				bv.y = JUMP_SPEED
				body.linearVelocity = bv
			end
		end
		if not free_move and magic.input:GetKeyDown(magic.KEY_SHIFT) then
			enable_physics()
			if not player_crouched then
				player_shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT/2)
				camera_node.position = magic.Vector3(0, 0.411*PLAYER_HEIGHT/2, 0)
				player_crouched = true
			end
		else
			if player_crouched then
				player_shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT)
				player_node:Translate(magic.Vector3(0, PLAYER_HEIGHT/4, 0))
				camera_node.position = magic.Vector3(0, 0.411*PLAYER_HEIGHT, 0)
				player_crouched = false
			end
		end

		local p = player_node:GetWorldPosition()
		local line = "("..math.floor(p.x + 0.5)..", "..
				math.floor(p.y + 0.5)..", "..math.floor(p.z + 0.5)..")"..
				"  building: "..BUILD_MATERIALS[build_material].name..
				" (1-5)  structures: B  free move: Tab"..
				(free_move and " (on)" or "").."  view: V"..
				(view_mode ~= 0 and " ("..VIEW_NAMES[view_mode]..")" or "")
		-- What the pointed voxel is and how close it is to failing, which
		-- is the whole debug interface between digs
		if pointed_voxel_p then
			local v = voxelworld.get_static_voxel(pointed_voxel_p)
			local id = field_of(v, FIELD.id)
			line = line.."\n"..(MATERIAL[id] or ("id "..id))..
					"  support "..support_of(v).."/15"..
					"  load "..band_of(v).."/15"..
					"  light "..field_of(v, FIELD.light)
		end
		misc_text:SetText(line)
	end
end)

-- PhysicsCollision is only sent on a Bullet step. Update can run on
-- interpolation frames with no step; keep the last step's grounded flag
-- until the next PreStep instead of clearing it every Update.
magic.SubscribeToEvent("PhysicsPreStep", function(event_type, event_data)
	player_touches_ground = false
end)

magic.SubscribeToEvent("PhysicsCollision", function(event_type, event_data)
	--log:info("PhysicsCollision")
	local node_a = event_data:GetPtr("Node", "NodeA")
	local node_b = event_data:GetPtr("Node", "NodeB")
	local contacts = event_data:GetBuffer("Contacts")
	if node_a:GetID() == player_node:GetID() or
			node_b:GetID() == player_node:GetID() then
		-- PhysicsCollision normals are NodeA's view and flip with pointer
		-- order. Contact height does not: feet are below the capsule center.
		local player_y = player_node:GetWorldPosition().y
		while not contacts.eof do
			local position = contacts:ReadVector3()
			local normal = contacts:ReadVector3()
			local distance = contacts:ReadFloat()
			local impulse = contacts:ReadFloat()
			if position.y < player_y then
				player_touches_ground = true
			end
		end
	end
end)

function setup_simple_voxel_data(node)
	local voxel_reg = voxelworld.get_voxel_registry()
	local atlas_reg = voxelworld.get_atlas_registry()

	local data = node:GetVar("simple_voxel_data"):GetBuffer()
	local w = node:GetVar("simple_voxel_w"):GetInt()
	local h = node:GetVar("simple_voxel_h"):GetInt()
	local d = node:GetVar("simple_voxel_d"):GetInt()
	log:info(dump(node:GetName()).." voxel data size: "..data:GetSize())
	-- A body: no world position, so the texture repeat starts at its corner
	buildat.set_8bit_voxel_geometry(node, w, h, d, data, voxel_reg, atlas_reg,
			0, 0, 0)
end

voxelworld.sub_ready(function()
	-- Subscribe to this only after the voxelworld is ready because we are using
	-- voxelworld's registries
	replicate.sub_sync_node_added({}, function(node)
		if not node:GetVar("simple_voxel_data"):IsEmpty() then
			setup_simple_voxel_data(node)
		end
		local name = node:GetName()
	end)
end)

buildat.sub_packet("main:spawn", function(data)
	local v = cereal.binary_input(data, {"object",
		{"x", "double"},
		{"y", "double"},
		{"z", "double"},
	})
	log:info("spawn ("..v.x..", "..v.y..", "..v.z..")")
	player_node.position = magic.Vector3(v.x, v.y, v.z)
	local body = player_node:GetComponent("RigidBody")
	if body then
		body.linearVelocity = magic.Vector3(0, 0, 0)
	end
	spawn_received = true
	enable_physics()
	set_generating_status(0)
end)

buildat.sub_packet("main:worldgen_queue_size", function(data)
	set_generating_status(tonumber(data))
end)

-- vim: set noet ts=4 sw=4:
