-- Buildat: multisection_lighting/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("multisection")
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")

local scene = replicate.main_scene

-- There is no player, so no collision shapes are wanted at all (and LOD is
-- off, voxelworld's default).
voxelworld.physics_distance = 1
-- The server fills the skylight bits of every voxel, so chunk geometry can be
-- shaded by them. This is what tells a cave apart from a tree's shadow.
voxelworld.use_skylight = true

-- Benchmark 1: outside the high +X +Y +Z corner, looking down the diagonal at
-- the opposite one. Pulled far enough back that a 45 degree fov covers the
-- ground plane, rather than widening the fov and distorting the corners.
-- VIEW_DIR is kept in sync with main.cpp by hand; the cave is carved along it
-- (yawed by CAVE_YAW_DEGREES there).
local VIEW_DIR = {x = -1.0, y = -0.7, z = -1.0}
-- voxel_lighting's look-at and distance, moved by SCENE_OFFSET in main.cpp,
-- so the overview frames the same scene the same way. The world keeps going
-- past the edges of it, which is the whole visible difference between the two.
local LOOK_AT = {x = 39, y = 62, z = 68}
local CAMERA_DISTANCE = 90
local CAMERA_FOV = 45
local FAR_CLIP = 400

-- Benchmarks 2 and 3 sit on the cave axis the server reports. Outside is far
-- enough back that the mouth is not the whole frame; inside is deep enough
-- that the opening reads as a bright hole at the end of a dark tunnel.
local CAVE_OUTSIDE_DISTANCE = 22
local CAVE_INSIDE_DISTANCE = 26

-- Light through leaves is animated off the scene's clock, so a screenshot of
-- it is different every run. F holds the clock here, which is what check.txt
-- does before it shoots anything; it is a toggle rather than something the
-- benchmark cameras do by themselves, so that just looking around the scene
-- always shows it moving. Any value would do for the moment to stop at.
local FROZEN_TIME = 12.0
local time_frozen = false

local MOVE_SPEED = 20
local MOUSE_SENSITIVITY = 0.15

local function normalized(v)
	local l = math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
	return {x = v.x/l, y = v.y/l, z = v.z/l}
end

-- Urho is left-handed and Y-up: yaw 0 looks towards +Z, and euler pitch is
-- positive downwards. Angles are in degrees, which is what Quaternion takes.
local function angles_from_dir(d)
	d = normalized(d)
	return math.deg(math.atan2(d.x, d.z)), math.deg(math.asin(-d.y))
end

-- Node.direction goes through SetDirection, which is a shortest-arc rotation
-- from forward and therefore rolls the camera; build the rotation from the
-- angles instead so that the horizon stays level.
local function apply_angles(node, yaw, pitch)
	node.rotation = magic.Quaternion(pitch, yaw, 0)
end

-- Benchmark camera placements. 1 is known up front; 2 and 3 need the cave,
-- which arrives from the server in main:cave.
local benchmarks = {}
do
	local d = normalized(VIEW_DIR)
	local b_yaw, b_pitch = angles_from_dir(VIEW_DIR)
	benchmarks[1] = {
		name = "Overview",
		x = LOOK_AT.x - d.x * CAMERA_DISTANCE,
		y = LOOK_AT.y - d.y * CAMERA_DISTANCE,
		z = LOOK_AT.z - d.z * CAMERA_DISTANCE,
		yaw = b_yaw, pitch = b_pitch,
	}
end

local yaw = benchmarks[1].yaw
local pitch = benchmarks[1].pitch
local free_look = false

-- Lighting. The voxel material is PBR (rough dielectric), lit in HDR and
-- tonemapped, so the sun can be brighter than white without the whole frame
-- clipping and a cave can be genuinely dark without going to pure black.
--
-- The zone's ambient color is the sky: it is what a surface with full skylight
-- receives. The mesher scales it per face by the stored skylight, tinting
-- towards a warm grey as skylight falls, so cave walls end up lit by something
-- that reads as bounced rock rather than as dim sky.
local SKY_AMBIENT = magic.Color(0.26, 0.33, 0.46)
-- Urho's PBR direct lighting is normalized (the BRDF is divided by pi, and so
-- is the diffuse term inside it), so a sun that reads as bright here is a much
-- larger number than the same sun under the legacy Diff technique.
local SUN_BRIGHTNESS = 50.0
-- The way the light travels, so the sun is the other way
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.8}
-- Fixed rather than auto-exposed: auto exposure would lift the inside of the
-- cave back to mid grey, which is the thing being looked at.
local EXPOSURE_BIAS = 1.6

do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = SKY_AMBIENT
	zone.fogColor = magic.Color(0.60, 0.72, 0.88)
	zone.fogStart = FAR_CLIP * 0.6
	zone.fogEnd = FAR_CLIP
	zone.priority = -1
	zone.override = true
	-- Same sky as voxel_lighting; see its init.lua
	zone.zoneTexture = magic.cache:GetResource("TextureCube",
			voxel_shading.sky_cubemap)
end

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

local camera_node = scene:CreateChild("Camera")
do
	camera_node.position = magic.Vector3(
			benchmarks[1].x, benchmarks[1].y, benchmarks[1].z)
	apply_angles(camera_node, yaw, pitch)
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 1.0
	camera.farClip = FAR_CLIP
	-- Of the screen's short side, a portrait one's width
	magic.keep_fov(camera, CAMERA_FOV)

	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})

	magic.renderer.HDRRendering = true
	local rp = viewport.renderPath:Clone()
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/BloomHDR.xml"))
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/Tonemap.xml"))
	rp:Append(magic.cache:GetResource("XMLFile",
			"PostProcess/GammaCorrection.xml"))
	-- Tonemap.xml ships with Reinhard on; Uncharted2 keeps more contrast in
	-- the shadows, which is where the whole scene is.
	rp:SetEnabled("TonemapReinhardEq3", false)
	rp:SetEnabled("TonemapUncharted2", true)
	rp:SetShaderParameter("TonemapExposureBias", EXPOSURE_BIAS)
	viewport.renderPath = rp
end

voxelworld.set_camera(camera_node)
voxel_shading.set_camera(camera_node)

magic.input:SetMouseVisible(true)

local function set_time_frozen(enable)
	time_frozen = enable
	if time_frozen then
		scene.elapsedTime = FROZEN_TIME
	end
	log:info("wind frozen: "..tostring(time_frozen))
end

local function set_free_look(enable)
	free_look = enable
	magic.input:SetMouseVisible(not free_look)
	local p = camera_node.position
	log:info("free move: "..tostring(free_look)..
			string.format("; camera (%.1f, %.1f, %.1f) yaw %.1f pitch %.1f",
			p.x, p.y, p.z, yaw, pitch))
end

local function go_to_benchmark(i)
	local b = benchmarks[i]
	if not b then
		log:warning("benchmark "..i..": no cave data from the server yet")
		return
	end
	if free_look then
		set_free_look(false)
	end
	yaw = b.yaw
	pitch = b.pitch
	camera_node.position = magic.Vector3(b.x, b.y, b.z)
	apply_angles(camera_node, yaw, pitch)
	-- Snapped, or a screenshot taken right after this would catch the blend
	-- part way and differ from run to run
	voxel_shading.update(nil)
	log:info(string.format("benchmark %d (%s): camera (%.1f, %.1f, %.1f) "..
			"yaw %.1f pitch %.1f", i, b.name, b.x, b.y, b.z, yaw, pitch))
end

-- Where the cave ended up, as "mx my mz dx dy dz". Sent rather than recomputed
-- here, so the benchmark cameras cannot drift out of sync with the carve.
buildat.sub_packet("main:cave", function(data)
	local mx, my, mz, dx, dy, dz = string.match(data,
			"([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+)")
	if not dz then
		log:error("main:cave: cannot parse \""..data.."\"")
		return
	end
	mx, my, mz = tonumber(mx), tonumber(my), tonumber(mz)
	dx, dy, dz = tonumber(dx), tonumber(dy), tonumber(dz)

	local out_yaw, out_pitch = angles_from_dir({x = dx, y = dy, z = dz})
	benchmarks[2] = {
		name = "Cave mouth",
		x = mx - dx * CAVE_OUTSIDE_DISTANCE,
		y = my - dy * CAVE_OUTSIDE_DISTANCE,
		z = mz - dz * CAVE_OUTSIDE_DISTANCE,
		yaw = out_yaw, pitch = out_pitch,
	}
	local in_yaw, in_pitch = angles_from_dir({x = -dx, y = -dy, z = -dz})
	benchmarks[3] = {
		name = "Inside cave",
		x = mx + dx * CAVE_INSIDE_DISTANCE,
		y = my + dy * CAVE_INSIDE_DISTANCE,
		z = mz + dz * CAVE_INSIDE_DISTANCE,
		yaw = in_yaw, pitch = in_pitch,
	}
	log:info(string.format("cave mouth (%.1f, %.1f, %.1f) dir (%.2f, %.2f, "..
			"%.2f); benchmarks 2 and 3 ready", mx, my, mz, dx, dy, dz))
end)

-- Voxel pointing and digging, so the relighting can be poked at by hand. Only
-- active in free move mode; the benchmark cameras must not be disturbed.
-- The highlight is a thin outline drawn on the +Y face of a unit cube and
-- rotated onto whichever face is being pointed at.
local pointed_voxel_p = nil
local pointed_voxel_p_above = nil
local pointed_node = scene:CreateChild("PointedVoxel")
do
	local g = pointed_node:CreateComponent("CustomGeometry")
	g:BeginGeometry(0, magic.TRIANGLE_LIST)
	g:SetNumGeometries(1)
	local c = magic.Color(0.12, 0.36, 0.12)
	local function define_face(lc, uc)
		local function v(x, y, z)
			g:DefineVertex(magic.Vector3(x, y, z))
			g:DefineColor(c)
		end
		v(lc.x, uc.y, uc.z) v(uc.x, uc.y, uc.z) v(uc.x, uc.y, lc.z)
		v(uc.x, uc.y, lc.z) v(lc.x, uc.y, lc.z) v(lc.x, uc.y, uc.z)
	end
	local d = 0.502
	local d2 = 1.0 / 16
	define_face(magic.Vector3(-d, d, d-d2), magic.Vector3(d, d, d))
	define_face(magic.Vector3(-d, d, -d), magic.Vector3(d, d, -d+d2))
	define_face(magic.Vector3(d-d2, d, -d+d2), magic.Vector3(d, d, d-d2))
	define_face(magic.Vector3(-d, d, -d+d2), magic.Vector3(-d+d2, d, d-d2))
	g:Commit()
	local m = magic.Material.new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureVColMultiply.xml"))
	g:SetMaterial(0, m)
	pointed_node.enabled = false
end

local DIG_REACH = 8

-- Returns nil, or the pointed voxel and the empty one just before it
local function find_pointed_voxel()
	local d_per_step = 0.1
	local p0 = buildat.Vector3(camera_node.worldPosition)
	local dir = buildat.Vector3(camera_node.worldDirection)
	local last_p = nil
	for i = 1, math.floor(DIG_REACH / d_per_step) do
		local p = (p0 + dir * i * d_per_step):round()
		if p ~= last_p then
			local v = voxelworld.get_static_voxel(p)
			-- 0 is "not loaded", 1 is air
			if v.id ~= 1 and v.id ~= 0 then
				return p, last_p
			end
			last_p = p
		end
	end
	return nil
end

local function send_voxel_p(name, p)
	buildat.send_packet(name, cereal.binary_output({
		p = {
			x = math.floor(p.x+0.5),
			y = math.floor(p.y+0.5),
			z = math.floor(p.z+0.5),
		},
	}, {"object",
		{"p", {"object",
			{"x", "int32_t"},
			{"y", "int32_t"},
			{"z", "int32_t"},
		}},
	}))
end

local function update_pointed_voxel()
	local p, p_above = find_pointed_voxel()
	pointed_voxel_p = p
	pointed_voxel_p_above = p_above
	if not (p and p_above) then
		pointed_node.enabled = false
		return
	end
	pointed_node.position = magic.Vector3.from_buildat(p)
	local d = p_above - p
	if d.x > 0 then pointed_node.rotation = magic.Quaternion(90, 0, -90)
	elseif d.x < 0 then pointed_node.rotation = magic.Quaternion(90, 0, 90)
	elseif d.y > 0 then pointed_node.rotation = magic.Quaternion(0, 0, 0)
	elseif d.y < 0 then pointed_node.rotation = magic.Quaternion(0, 0, -180)
	elseif d.z > 0 then pointed_node.rotation = magic.Quaternion(90, 0, 0)
	elseif d.z < 0 then pointed_node.rotation = magic.Quaternion(-90, 0, 0)
	end
	pointed_node.enabled = true
end

magic.SubscribeToEvent("MouseButtonDown", function(event_type, event_data)
	if not free_look then
		return
	end
	local button = event_data:GetInt("Button")
	if button == magic.MOUSEB_LEFT and pointed_voxel_p then
		send_voxel_p("main:dig_voxel", pointed_voxel_p)
	elseif button == magic.MOUSEB_RIGHT and pointed_voxel_p_above then
		send_voxel_p("main:place_voxel", pointed_voxel_p_above)
	end
end)

-- HUD, so the scene can be inspected without remembering the keys
do
	local ui_root = magic.ui.root
	ui_root.defaultStyle = magic.cache:GetResource("XMLFile",
			"UI/DefaultStyle.xml")

	local panel = ui_root:CreateChild("UIElement")
	panel:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(8, 8, 8, 8))
	panel:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)

	local function add_button(label, action)
		local button = panel:CreateChild("Button")
		button:SetStyleAuto()
		button:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(8, 4, 8, 4))
		button.minHeight = 24
		button.minWidth = 130
		button:SetFocusMode(magic.FM_NOTFOCUSABLE)
		local text = button:CreateChild("Text")
		text:SetStyleAuto()
		text.text = label
		text:SetTextAlignment(magic.HA_CENTER)
		magic.SubscribeToEvent(button, "Released", function()
			action()
			magic.ui:SetFocusElement(nil)
		end)
	end

	add_button("Free move (Tab)", function() set_free_look(not free_look) end)
	add_button("1 Overview", function() go_to_benchmark(1) end)
	add_button("2 Cave mouth", function() go_to_benchmark(2) end)
	add_button("3 Inside cave", function() go_to_benchmark(3) end)
	add_button("Dig shaft (P)", function()
		buildat.send_packet("main:bench_shaft", "")
	end)
	add_button("Cap shaft (O)", function()
		buildat.send_packet("main:bench_slab", "")
	end)
	add_button("Verify light (V)", function()
		buildat.send_packet("main:verify_skylight", "")
	end)
	add_button("Freeze wind (F)", function()
		set_time_frozen(not time_frozen)
	end)

	magic.ui:SetFocusElement(nil)
end

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_TAB then
		set_free_look(not free_look)
	elseif key == magic.KEY_1 or key == magic.KEY_HOME then
		go_to_benchmark(1)
	elseif key == magic.KEY_2 then
		go_to_benchmark(2)
	elseif key == magic.KEY_3 then
		go_to_benchmark(3)
	elseif key == magic.KEY_P then
		buildat.send_packet("main:bench_shaft", "")
	elseif key == magic.KEY_O then
		buildat.send_packet("main:bench_slab", "")
	elseif key == magic.KEY_V then
		buildat.send_packet("main:verify_skylight", "")
	elseif key == magic.KEY_F then
		set_time_frozen(not time_frozen)
	elseif key == magic.KEY_ESCAPE then
		if free_look then
			set_free_look(false)
		end
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	if time_frozen then
		scene.elapsedTime = FROZEN_TIME
	end
	voxel_shading.update(event_data:GetFloat("TimeStep"))
	if not free_look then
		pointed_node.enabled = false
		return
	end
	update_pointed_voxel()
	local dt = event_data:GetFloat("TimeStep")

	local dmouse = magic.input:GetMouseMove()
	yaw = yaw + dmouse.x * MOUSE_SENSITIVITY
	pitch = pitch + dmouse.y * MOUSE_SENSITIVITY
	if pitch > 89 then pitch = 89 end
	if pitch < -89 then pitch = -89 end

	-- Movement stays on the horizontal plane whatever the camera is looking
	-- at, so that pitching down to inspect the cave does not sink the camera
	-- into the ground. Space and Shift are the only way to change height.
	local yr = math.rad(yaw)
	local forward = magic.Vector3(math.sin(yr), 0, math.cos(yr))
	local right = magic.Vector3(math.cos(yr), 0, -math.sin(yr))

	local speed = MOVE_SPEED * dt
	local p = camera_node.position
	local function move(v, s)
		p = magic.Vector3(p.x + v.x*s, p.y + v.y*s, p.z + v.z*s)
	end
	if magic.input:GetKeyDown(magic.KEY_W) then move(forward, speed) end
	if magic.input:GetKeyDown(magic.KEY_S) then move(forward, -speed) end
	if magic.input:GetKeyDown(magic.KEY_D) then move(right, speed) end
	if magic.input:GetKeyDown(magic.KEY_A) then move(right, -speed) end
	if magic.input:GetKeyDown(magic.KEY_SPACE) then
		p = magic.Vector3(p.x, p.y + speed, p.z)
	end
	if magic.input:GetKeyDown(magic.KEY_SHIFT) then
		p = magic.Vector3(p.x, p.y - speed, p.z)
	end

	camera_node.position = p
	apply_angles(camera_node, yaw, pitch)
end)

log:info("multisection_lighting client ready; Tab = free move, 1/2/3 = benchmarks, "..
		"P/O = benchmark shaft dig/cap, V = verify light")
-- vim: set noet ts=4 sw=4:
