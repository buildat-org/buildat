-- Buildat: apps/demo_hillclimb/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- demo_hillclimb's client ([HILLCLIMB] 1): the hill drawn in pbr as
-- demo_skeldat draws its world (builtin/luanti's sky and light rules),
-- the sun where it is at the server's latitude, day and hour
-- (physical_sky.sun_toward), and a camera orbiting the start. A world
-- unit is one voxel, 125 mm (main/hill.h).
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

-- The orbit: dragged with the left button, the wheel the distance
-- simplified: around the start; the car's position once there is a car
-- ([HILLCLIMB] 2)
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
	local m = magic.input:GetMouseMove()
	if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
		yaw = (yaw + m.x * 0.3) % 360
		pitch = math.max(-10, math.min(85, pitch + m.y * 0.3))
	end
	local y, p = math.rad(yaw), math.rad(pitch)
	local t = hill.target
	camera_node.position = magic.Vector3(
			t.x + dist * math.cos(p) * math.sin(y),
			t.y + 1.5 * U + dist * math.sin(p),
			t.z + dist * math.cos(p) * math.cos(y))
	camera_node:LookAt(magic.Vector3(t.x, t.y + U, t.z))
end)
