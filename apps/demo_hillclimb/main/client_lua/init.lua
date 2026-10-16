-- Buildat: apps/demo_hillclimb/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- demo_hillclimb's client ([HILLCLIMB] 1): the hill drawn in pbr as
-- demo_skeldat draws its world (builtin/luanti's sky and light rules),
-- the sun where it is at the server's latitude, day and hour
-- (physical_sky.sun_toward), the car as the server moves it (main.cpp,
-- car.h) drawn as its tyres, wheels and axles, the keys sent to the
-- server, and a camera orbiting the car. A world unit is one voxel,
-- 125 mm (main/hill.h).
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")
local log = buildat.Logger("hillclimb")

local function load(name)
	local ok, err, m = buildat.run_script_file(name)
	assert(ok and m, name .. ": " .. tostring(err))
	return m
end

local scene = replicate.main_scene
local U = 8 -- voxels to the metre
local FAR_CLIP = 150 * U
local sky_dome = load("luanti/sky_dome.lua")
local sky_light = load("luanti/sky_light.lua")
local PHYS = sky_light.PHYS

voxelworld.use_skylight = true
voxelworld.horizon = true
voxel_shading.set_packed_sky(true)
voxel_shading.use_sun_gate(true)
voxel_shading.use_technique_set({
	plain = "luanti_client/res/LuantiVoxel.xml",
	alpha = "luanti_client/res/LuantiVoxelAlpha.xml",
	masked = "luanti_client/res/LuantiVoxelMasked.xml",
	sun = "luanti_client/res/LuantiVoxelSun.xml",
	sun_alpha = "luanti_client/res/LuantiVoxelSunAlpha.xml",
	sun_masked = "luanti_client/res/LuantiVoxelSunMasked.xml",
})
voxelworld.lod_distance = 4000
voxelworld.send_distance = FAR_CLIP

local zone = scene:CreateChild("Zone"):CreateComponent("Zone")
zone.boundingBox = magic.BoundingBox(-100000, 100000)
zone.fogStart = FAR_CLIP * 0.6
zone.fogEnd = FAR_CLIP * 0.95
zone.priority = 1
zone.override = true

-- Shadow cascades in voxels: the car's surroundings sharp, the hill whole
local sun_node = scene:CreateChild("Sun")
local sun = sun_node:CreateComponent("Light")
sun.lightType = magic.LIGHT_DIRECTIONAL
sun.castShadows = true
sun.specularIntensity = 1.0
sun.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
sun.shadowCascade = magic.CascadeParameters(10 * U, 40 * U, 120 * U, 0, 0.8)

local sky = sky_dome.new(scene, {x = -0.6, y = -1.0, z = 0.3},
		voxel_shading.sky_defaults, log)
sky:set_physical(true)
-- Open sky everywhere: never the indoor grey a cave dims it to
sky:set_auto_dim(false)
local sky_cube = {cube = sky_dome.new_cube(sky.material), due = 0}
zone.zoneTexture = sky_cube.cube.texture
voxel_shading.set_sky_light(1.0)
voxel_shading.set_specular_emphasis(0.7)

local camera_node = scene:CreateChild("Camera")
local camera = camera_node:CreateComponent("Camera")
camera.nearClip = 0.05 * U
camera.farClip = FAR_CLIP
magic.keep_fov(camera, 60)
do
	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})
	magic.renderer.HDRRendering = true
	viewport.renderPath = sky_light.render_path(magic, viewport.renderPath)
end
voxelworld.set_camera(camera_node)
voxel_shading.set_camera(camera_node)

-- What the server says (main.cpp hill_packet): the hill's size, where the
-- car starts, in voxels; the latitude, the day and the hour
local hill = nil
buildat.sub_packet("hillclimb:hill", function(data)
	local v = {}
	for w in data:gmatch("%S+") do v[#v + 1] = tonumber(w) end
	hill = {size = magic.Vector3(v[1], v[2], v[3]),
		target = magic.Vector3(v[4], v[5], v[6]),
		lat = v[7], day = v[8], time = v[9]}
	-- The land around, level with the bottom pad (a voxel's centre is its
	-- integer position, so the pad's top is half a voxel over v[5] - 1) and
	-- a tenth of a voxel under it so the pad draws over it: the hill does
	-- not float. Its colour is a linear albedo over pi, the units the pbr
	-- voxels are lit in, by eye against the sand
	-- simplified: a plain colour, no texture (Material has no UV transform
	-- in the whitelist); a textured ground is the shader param UOffset's
	local ground = scene:CreateChild("Ground")
	ground.position = magic.Vector3(v[4], v[5] - 0.6, v[3] / 2)
	ground.scale = magic.Vector3(1000 * U, 1, 1000 * U)
	local model = ground:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Plane.mdl")
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTexture.xml"))
	m:SetShaderParameter("MatDiffColor", magic.Color(0.12, 0.10, 0.06))
	m:SetShaderParameter("MatSpecColor", magic.Color(0, 0, 0))
	model.material = m
	log:info(string.format("hillclimb: the hill %dx%dx%d, at %g N, day %g, "
			.. "%g h", v[1], v[2], v[3], v[7], v[8], v[9]))
end)

-- The sky's hue by the sun's height, demo_skeldat's hue_of_hour (copied)
local function hue_of_hour(t, lit)
	local function three(night, dawn, day)
		local a, b, k
		if t < 0.5 then
			a, b, k = night, dawn, t * 2
		else
			a, b, k = dawn, day, (t - 0.5) * 2
		end
		local function one(v, w)
			local x = (v + (w - v) * k) * lit
			return x > 0 and x ^ 2.2 or 0
		end
		return {r = one(a.r, b.r), g = one(a.g, b.g), b = one(a.b, b.b)}
	end
	local dz, dh = PHYS.day_zenith, PHYS.day_horizon
	local nz = {r = dz.r * 0.10, g = dz.g * 0.10, b = dz.b * 0.14}
	local nh = {r = dh.r * 0.10, g = dh.g * 0.10, b = dh.b * 0.14}
	return three(nz, {r = (dz.r + nz.r) * 0.5, g = (dz.g + nz.g) * 0.5,
			b = (dz.b + nz.b) * 0.5}, dz),
		three(nh, {r = dh.r * 0.75, g = dh.g * 0.52, b = dh.b * 0.45}, dh)
end

-- simplified: the hour holds still; no clock, no weather, no moon
local CLOUD = {r = 0.9, g = 0.92, b = 0.95}
local function update_sky()
	-- +Z is north (the hill climbs north)
	local tx, h, tz = sky_dome.sun_toward(hill.lat, 0, hill.day,
			hill.time * 60)
	local l = math.sqrt(tx * tx + h * h + tz * tz)
	local dir = magic.Vector3(-tx / l, -h / l, -tz / l)
	sky:set_sun_direction({x = dir.x, y = dir.y, z = dir.z})
	voxel_shading.set_sun_direction({x = dir.x, y = dir.y, z = dir.z})
	sky:set_moon_look(0)
	local day = math.max(0, math.min(1, (h + 0.15) / 0.3))
	day = math.max(day, sky_dome.predawn(h))
	local lit = (0.175 + 0.825 * day) ^ 2.2
	local zenith, horizon = hue_of_hour(day, lit)
	zenith, horizon = sky_light.sky_radiance(zenith, horizon, h)
	sky:set_look(zenith, horizon, nil)
	local t = sky_light.terms(h, sky_light.dome(zenith, horizon))
	sky:set_dawn_glow(t.glow.r, t.glow.g, t.glow.b, t.glow_tint)
	local up = sky_dome.above_horizon(h)
	sun_node.enabled = up > 0
	if up > 0 then
		sun_node.direction = dir
		sun.brightness = t.sun
		sun.color = magic.Color(t.sun_color.r, t.sun_color.g, t.sun_color.b)
	end
	local half = voxel_shading.sky_defaults.sun_half
	sky:set_sun_look(half, voxel_shading.sky_defaults.sun_color)
	sky:set_sun_radiance(sky_light.sun_disc(h, half, t.sun_color))
	sky:set_star_look(sky_dome.STAR_DENSITY_DEFAULT, nil,
			(1 - day) * (1 - day))
	sky:set_cloud_lit(sky_light.cloud_lit(CLOUD, zenith, horizon, h, 1))
	sky_light.apply(voxel_shading, zone, magic, t)
	-- The open sky everywhere: the fog is the horizon (sky_light.fog's seen 1)
	zone.fogColor = magic.Color(horizon.r, horizon.g, horizon.b)
	local now = scene.elapsedTime
	if now >= sky_cube.due then
		sky_cube.due = now + 1
		sky_cube.cube:update()
	end
	sky_cube.cube:tick()
end

--
-- The car, drawn from hillclimb:car: car.h's Spec, in metres
--
local CAR = {tyre_r = 0.40, tyre_w = 0.30, track = 1.60, wheelbase = 2.80,
	mount_y = -0.1, droop = 0.45}
local function lit(r, g, b)
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTexture.xml"))
	m:SetShaderParameter("MatDiffColor", magic.Color(r, g, b))
	m:SetShaderParameter("MatSpecColor", magic.Color(0.02, 0.02, 0.02))
	return m
end
local TYRE, RIM, STEEL = lit(0.01, 0.01, 0.01), lit(0.15, 0.15, 0.14),
		lit(0.05, 0.05, 0.06)
local function part(parent, model, mat, pos, scale, rot)
	local n = parent:CreateChild("Part")
	n.position = pos
	n.scale = scale
	if rot then
		n.rotation = rot
	end
	local m = n:CreateComponent("StaticModel")
	m.model = magic.cache:GetResource("Model", "Models/" .. model .. ".mdl")
	m.material = mat
	m.castShadows = true
	return n
end
local car_node = scene:CreateChild("Car")
car_node.enabled = false
local hub_y = (CAR.mount_y - CAR.droop) * U
part(car_node, "Box", STEEL, magic.Vector3(0, CAR.mount_y * U, 0),
		magic.Vector3(0.15 * U, 0.15 * U, (CAR.wheelbase + 0.3) * U))
local wheels, axles = {}, {}
local SIDEWAYS = magic.Quaternion(90, magic.Vector3(0, 0, 1))
for i = 1, 4 do
	local x = (i % 2 == 1 and -1 or 1) * CAR.track / 2 * U
	local z = (i <= 2 and 1 or -1) * CAR.wheelbase / 2 * U
	local hub = car_node:CreateChild("Hub")
	hub.position = magic.Vector3(x, hub_y, z)
	local spin = hub:CreateChild("Spin")
	local d, w = 2 * CAR.tyre_r * U, CAR.tyre_w * U
	part(spin, "Cylinder", TYRE, magic.Vector3(0, 0, 0),
			magic.Vector3(d, w, d), SIDEWAYS)
	part(spin, "Cylinder", RIM, magic.Vector3(0, 0, 0),
			magic.Vector3(d * 0.6, w * 1.05, d * 0.6), SIDEWAYS)
	-- A bar across the rim, so the wheel is seen turning
	part(spin, "Box", STEEL, magic.Vector3(0, 0, 0),
			magic.Vector3(w * 1.1, 0.08 * U, d * 0.75))
	wheels[i] = {hub = hub, spin = spin, x = x, z = z}
end
for a = 1, 2 do
	axles[a] = part(car_node, "Box", STEEL, magic.Vector3(0, hub_y, 0),
			magic.Vector3(CAR.track * U, 0.1 * U, 0.1 * U))
end

-- Two states, drawn a packet behind and blended, so the car moves as
-- smoothly as the frames do at the server's 30 Hz
local states = {}
buildat.sub_packet("hillclimb:car", function(data)
	local v = {}
	for w in data:gmatch("%S+") do v[#v + 1] = tonumber(w) end
	if #v < 16 then
		return
	end
	states[1] = states[2]
	states[2] = {t = scene.elapsedTime, v = v}
	car_node.enabled = true
end)
local car_pos = nil
local function draw_car()
	local b = states[2]
	if b == nil then
		return
	end
	local a = states[1] or b
	local span = math.max(1e-3, b.t - a.t)
	local k = math.max(0, math.min(1, (scene.elapsedTime - b.t) / span))
	local function mix(i) return a.v[i] + (b.v[i] - a.v[i]) * k end
	car_pos = magic.Vector3(mix(1), mix(2), mix(3))
	car_node.position = car_pos
	car_node.rotation = magic.Quaternion(a.v[4], a.v[5], a.v[6], a.v[7]):Slerp(
			magic.Quaternion(b.v[4], b.v[5], b.v[6], b.v[7]), k)
	local spin_deg = math.deg(b.v[8])
	for i, w in ipairs(wheels) do
		local y = hub_y + b.v[10 + i]
		w.hub.position = magic.Vector3(w.x, y, w.z)
		w.y = y
		w.hub.rotation = magic.Quaternion(i <= 2 and math.deg(b.v[8 + i]) or 0,
				magic.Vector3(0, 1, 0))
		w.spin.rotation = magic.Quaternion(spin_deg, magic.Vector3(1, 0, 0))
	end
	-- Each axle between its two hubs, tilted as they stand
	for a_i = 1, 2 do
		local l, r = wheels[a_i * 2 - 1], wheels[a_i * 2]
		axles[a_i].position = magic.Vector3(0, (l.y + r.y) / 2, l.z)
		axles[a_i].rotation = magic.Quaternion(math.deg(math.atan2(r.y - l.y,
				r.x - l.x)), magic.Vector3(0, 0, 1))
	end
end

--
-- The keys, in the client's key store: the shared movement names where
-- there is one
--
local KEYS = {
	{id = "accel", label = "Accelerator", default = "W",
		shared = "move.forward"},
	{id = "brake", label = "Brake", default = "S", shared = "move.back"},
	{id = "left", label = "Steer left", default = "A", shared = "move.left"},
	{id = "right", label = "Steer right", default = "D",
		shared = "move.right"},
	{id = "gear1", label = "First gear", default = "1"},
	{id = "gear2", label = "Second gear", default = "2"},
	{id = "gear3", label = "Third gear", default = "3"},
	{id = "gear4", label = "Fourth gear", default = "4"},
	{id = "reverse", label = "Reverse", default = "R"},
	{id = "reset", label = "The car back to the start", default = "Backspace"},
}
local key = {}
do
	local names = buildat.declare_keys(nil, "hillclimb", KEYS)
	for _, k in ipairs(KEYS) do
		local name = type(names) == "table" and names[k.id] or k.default
		key[k.id] = magic.input:GetKeyFromName(name)
	end
end
local function down(id)
	return key[id] ~= 0 and magic.input:GetKeyDown(key[id])
end
local gear = 1
local sent, sent_t = nil, 0
-- "accel brake left right gear reset" (main.cpp on_input), sent when it
-- changes and twice a second besides
local function send_input()
	for g = 1, 4 do
		if down("gear" .. g) then gear = g end
	end
	if down("reverse") then gear = 0 end
	local function b(id) return down(id) and 1 or 0 end
	local msg = string.format("%d %d %d %d %d %d", b("accel"), b("brake"),
			b("left"), b("right"), gear, b("reset"))
	local now = scene.elapsedTime
	if msg ~= sent or now - sent_t > 0.5 then
		buildat.send_packet("hillclimb:input", msg)
		sent, sent_t = msg, now
	end
end

-- The orbit about the car: dragged with the left button, the wheel the
-- distance
local yaw, pitch, dist = 200, 20, 12 * U
magic.SubscribeToEvent("MouseWheel", function(_, d)
	local w = d:GetInt("Wheel")
	dist = math.max(3 * U, math.min(80 * U, dist * (w > 0 and 0.85 or 1.18)))
end)

magic.SubscribeToEvent("Update", function(_, d)
	local dt = d:GetFloat("TimeStep")
	if hill == nil then
		return
	end
	update_sky()
	voxel_shading.update(dt)
	draw_car()
	send_input()
	local m = magic.input:GetMouseMove()
	if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
		yaw = (yaw + m.x * 0.3) % 360
		pitch = math.max(-10, math.min(85, pitch + m.y * 0.3))
	end
	local y, p = math.rad(yaw), math.rad(pitch)
	local t = car_pos or hill.target
	camera_node.position = magic.Vector3(
			t.x + dist * math.cos(p) * math.sin(y),
			t.y + 0.5 * U + dist * math.sin(p),
			t.z + dist * math.cos(p) * math.cos(y))
	camera_node:LookAt(magic.Vector3(t.x, t.y, t.z))
end)
