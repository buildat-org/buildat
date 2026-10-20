-- Buildat: apps/hillclimb/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- hillclimb's client ([HILLCLIMB] 1): the hill drawn in pbr as
-- skeldat draws its world (builtin/luanti's sky and light rules),
-- the sun where it is at the server's latitude, day and hour
-- (physical_sky.sun_toward), the car as the server moves it (main.cpp,
-- car.h) drawn as its tyres, wheels and axles, the keys sent to the
-- server, a camera orbiting the car, the time trial's clock and ranking,
-- the menu (Tab) picking the hill, the payload and the hour, and the
-- pause menu (Escape, main/pause.lua). A world unit is one voxel, 125 mm
-- (main/hill.h).
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")
uistack = uistack.safe or uistack
local log = buildat.Logger("hillclimb")

local function load(name)
	local ok, err, m = buildat.run_script_file(name)
	assert(ok and m, name .. ": " .. tostring(err))
	return m
end

local scene = replicate.main_scene
local U = 8 -- voxels to the metre
local FAR_CLIP = 150 * U
-- extensions/sky_render, and the day's schedule luanti_client's
-- sky_model.lua, served by main.cpp ([SKY_RENDER_SHARED])
local sky_model = load("luanti/sky_model.lua")
local sky_light = load("sky_render/init.lua")
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

local sky = sky_light.new_dome(scene, {x = -0.6, y = -1.0, z = 0.3},
		voxel_shading.sky_defaults, log, sky_model)
-- Open sky everywhere: never the indoor grey a cave dims it to
sky:set_auto_dim(false)
local sky_cube = {cube = sky_light.new_cube(sky.material), due = 0}
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

-- [HC_OPEN_EDGES] **The land around**: the server's outside() heights
-- (hillclimb:outside, main.cpp outside_packet) as one static mesh of
-- quads with a hole where the voxels are, 2 m cells near and 8 m far;
-- each quad by its slope into one of nine groups (flat, and four compass
-- ways at two tilts), a material each, lit as an object with no sun plus
-- the sun by the group's normal, as skeldat's backdrop is (its own copy:
-- apps do not consume each other). Sand-textured. And the fences
-- (hillclimb:fences: the area's edge, or a circuit's lanes' sides): posts
-- every 2 m at most, white with a red band, and two red-and-white ribbons
-- between them, drawn only.
local hill = nil -- the server's hillclimb:hill, below
local outside = {node = nil, fence = nil, groups = {}, light_t = 0}
local light_units = nil
local function lit_mat(r, g, b, texture)
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique", texture and
			"Techniques/Diff.xml" or "Techniques/NoTexture.xml"))
	if texture then
		m:SetTexture(magic.TU_DIFFUSE, magic.cache:GetResource("Texture2D",
				texture))
	end
	m:SetShaderParameter("MatDiffColor", magic.Color(r, g, b))
	m:SetShaderParameter("MatSpecColor", magic.Color(0, 0, 0))
	return m
end
local FENCE = {white = lit_mat(0.8, 0.8, 0.78), red = lit_mat(0.6, 0.04, 0.03),
	ribbon = lit_mat(1, 1, 1, "main/ribbon.png")}
-- The fences: a post at each point the server sends, on the ground
-- there; ribbons between a line's posts at 0.5 and 0.9 m, sagging 3 cm at
-- their middles
local function make_fence(lines)
	local quads = {}
	local function box(tile, x, y, z, w, h)
		local x0, x1, z0, z1 = x - w / 2, x + w / 2, z - w / 2, z + w / 2
		local y1 = y + h
		local function q(a, b, c, d)
			quads[#quads + 1] = {tile = tile, p = {a[1], a[2], a[3], b[1], b[2],
				b[3], c[1], c[2], c[3], d[1], d[2], d[3]}, uv = {0, 0, 1, 0, 1, 1, 0, 1}}
		end
		q({x0, y, z0}, {x1, y, z0}, {x1, y1, z0}, {x0, y1, z0})
		q({x1, y, z0}, {x1, y, z1}, {x1, y1, z1}, {x1, y1, z0})
		q({x1, y, z1}, {x0, y, z1}, {x0, y1, z1}, {x1, y1, z1})
		q({x0, y, z1}, {x0, y, z0}, {x0, y1, z0}, {x0, y1, z1})
		q({x0, y1, z0}, {x1, y1, z0}, {x1, y1, z1}, {x0, y1, z1})
	end
	local posts = 0
	for _, line in ipairs(lines) do
		for k, p in ipairs(line) do
			posts = posts + 1
			box(1, p[1], p[2], p[3], 0.06 * U, 1.0 * U)
			box(2, p[1], p[2] + 0.75 * U, p[3], 0.07 * U, 0.12 * U)
			local n = line[k + 1]
			local len = n and math.sqrt((n[1] - p[1]) ^ 2 + (n[3] - p[3]) ^ 2) / U
			for _, at_y in ipairs(n and {0.5, 0.9} or {}) do
				local mid = {(p[1] + n[1]) / 2, (p[2] + n[2]) / 2 + (at_y - 0.03) * U,
					(p[3] + n[3]) / 2}
				local a = {p[1], p[2] + at_y * U, p[3]}
				local b = {n[1], n[2] + at_y * U, n[3]}
				local w = 0.08 * U
				for _, seg in ipairs({{a, mid, 0, len / 2}, {mid, b, len / 2, len}}) do
					local u, v = seg[1], seg[2]
					quads[#quads + 1] = {tile = 3, p = {u[1], u[2], u[3], v[1], v[2],
						v[3], v[1], v[2] + w, v[3], u[1], u[2] + w, u[3]},
						uv = {seg[3] * 4, 1, seg[4] * 4, 1, seg[4] * 4, 0, seg[3] * 4, 0}}
				end
			end
		end
	end
	if outside.fence then
		outside.fence:Remove()
	end
	outside.fence = scene:CreateChild("Fence")
	local tiles = buildat.set_quad_geometry(outside.fence, quads)
	local cg = outside.fence:GetComponent("CustomGeometry")
	local mats = {FENCE.white, FENCE.red, FENCE.ribbon}
	for i, tile in ipairs(tiles) do
		cg:SetMaterial(i - 1, mats[tile])
	end
	return posts
end
-- "x y z ..." a post each, ";" between the lines (main.cpp fences_packet)
buildat.sub_packet("hillclimb:fences", function(data)
	local lines = {}
	for l in data:gmatch("[^;]+") do
		local v, line = {}, {}
		for w in l:gmatch("%S+") do v[#v + 1] = tonumber(w) end
		for i = 1, #v - 2, 3 do line[#line + 1] = {v[i], v[i + 1], v[i + 2]} end
		lines[#lines + 1] = line
	end
	log:info(string.format("hillclimb: %d fences, %d posts", #lines,
			make_fence(lines)))
end)
buildat.sub_packet("hillclimb:outside", function(data)
	local v = {}
	for w in data:gmatch("%S+") do v[#v + 1] = tonumber(w) end
	-- [HC_HOLLOW_MIDDLE] After the heights: "n sx sz ...", the section
	-- columns the server left out, drawn as land here
	local nx, nz = v[1], v[2]
	local nh = nz and v[3 + nx + nz + nx * nz]
	if not nh or #v ~= 3 + nx + nz + nx * nz + 2 * nh then
		log:warning("hillclimb: the outside's packet does not add up")
		return
	end
	local t0 = buildat.get_time_us()
	local xs, zs, hs = {}, {}, {}
	for i = 1, nx do xs[i] = v[2 + i] end
	for j = 1, nz do zs[j] = v[2 + nx + j] end
	for k = 1, nx * nz do hs[k] = v[2 + nx + nz + k] end
	local hollow = {}
	for k = 1, nh do
		local base = 3 + nx + nz + nx * nz + 2 * (k - 1)
		hollow[v[base + 1] .. " " .. v[base + 2]] = true
	end
	local function in_hollow(i, j)
		local sx = math.floor(((xs[i] + xs[i + 1]) / 2 + 0.5) / 64)
		local sz = math.floor(((zs[j] + zs[j + 1]) / 2 + 0.5) / 64)
		return hollow[sx .. " " .. sz]
	end
	-- The area's edges are lines of the grid: its first and last lines
	-- are where -0.5 and the size's are
	local area = {}
	for i, x in ipairs(xs) do
		if math.abs(x + 0.5) < 0.01 then area.i0 = i end
		if hill and math.abs(x - (hill.size.x - 0.5)) < 0.01 then area.i1 = i end
	end
	for j, z in ipairs(zs) do
		if math.abs(z + 0.5) < 0.01 then area.j0 = j end
		if hill and math.abs(z - (hill.size.z - 0.5)) < 0.01 then area.j1 = j end
	end
	if not (area.i0 and area.i1 and area.j0 and area.j1) then
		log:warning("hillclimb: the outside's packet has no area edges")
		return
	end
	local function group(nx_, ny, nz_)
		if ny > 0.97 then
			return 0
		end
		local way = math.abs(nx_) > math.abs(nz_) and (nx_ > 0 and 0 or 2) or
				(nz_ > 0 and 1 or 3)
		return 1 + way + (ny < 0.8 and 4 or 0)
	end
	local sums, quads = {}, {}
	for j = 1, nz - 1 do
		for i = 1, nx - 1 do
			if i < area.i0 or i >= area.i1 or j < area.j0 or j >= area.j1 or
					in_hollow(i, j) then
				local function p(a, b)
					return {xs[a], hs[(b - 1) * nx + a], zs[b]}
				end
				local a, b, c, d = p(i, j), p(i + 1, j), p(i + 1, j + 1), p(i, j + 1)
				local ux, uy, uz = c[1] - a[1], c[2] - a[2], c[3] - a[3]
				local wx, wy, wz = d[1] - b[1], d[2] - b[2], d[3] - b[3]
				local n1, n2, n3 = uy * wz - uz * wy, uz * wx - ux * wz,
						ux * wy - uy * wx
				local l = math.sqrt(n1 * n1 + n2 * n2 + n3 * n3)
				if n2 < 0 then
					l = -l
				end
				n1, n2, n3 = n1 / l, n2 / l, n3 / l
				local gi = group(n1, n2, n3)
				local sum = sums[gi] or {0, 0, 0}
				sum[1], sum[2], sum[3] = sum[1] + n1, sum[2] + n2, sum[3] + n3
				sums[gi] = sum
				quads[#quads + 1] = {tile = gi,
					p = {a[1], a[2], a[3], b[1], b[2], b[3], c[1], c[2], c[3],
						d[1], d[2], d[3]},
					uv = {a[1] / U, a[3] / U, b[1] / U, b[3] / U, c[1] / U,
						c[3] / U, d[1] / U, d[3] / U}}
			end
		end
	end
	if outside.node then
		outside.node:Remove()
	end
	outside.node = scene:CreateChild("Outside")
	local tex = magic.cache:GetResource("Texture2D", "main/sand.png")
	if tex then
		tex.filterMode = magic.FILTER_NEAREST
	end
	local tiles = buildat.set_quad_geometry(outside.node, quads)
	local cg = outside.node:GetComponent("CustomGeometry")
	outside.groups = {}
	for i = 1, #tiles do
		local m = magic.Material.new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"luanti_client/res/LuantiUnlitMask.xml"))
		if tex then
			m:SetTexture(magic.TU_DIFFUSE, tex)
		end
		cg:SetMaterial(i - 1, m)
		local sum = sums[tiles[i]]
		local l = math.sqrt(sum[1] ^ 2 + sum[2] ^ 2 + sum[3] ^ 2)
		outside.groups[i] = {mat = m, n = {sum[1] / l, sum[2] / l, sum[3] / l}}
	end
	outside.light_t = 0
	log:info(string.format("hillclimb: the outside, %d quads in %d groups, " ..
			"%.1f ms", #quads, #tiles, (buildat.get_time_us() - t0) / 1000))
end)
-- Lit as an object under the open sky, twice a second: the light with no
-- sun, and the sun's by each group's slope to it (object_light gives the
-- sun at a half: twice its share is the sun's whole)
local function light_outside(dt)
	outside.light_t = outside.light_t - dt
	if not outside.node or outside.light_t > 0 or not light_units then
		return
	end
	outside.light_t = 0.5
	local r0, g0, b0 = sky_light.object_light(light_units, 1, 0, true)
	local r1, g1, b1 = sky_light.object_light(light_units, 1, 0)
	local d = sun_node.enabled and sun_node.direction or magic.Vector3(0, 1, 0)
	for _, gr in ipairs(outside.groups) do
		local k = 2 * math.max(0, -(gr.n[1] * d.x + gr.n[2] * d.y + gr.n[3] * d.z))
		gr.mat:SetShaderParameter("MatDiffColor", magic.Color(r0 + (r1 - r0) * k,
				g0 + (g1 - g0) * k, b0 + (b1 - b0) * k, 1))
	end
end

-- What the server says (main.cpp hill_packet): the hill's size, where the
-- car starts, in voxels; the latitude, the day and the hour; the seed,
-- the steepness, the length and the payload; whether this client may
-- pick ([HC_MULTIPLAYER] 2: an admin on a public server), the rounds'
-- interval, seconds, and the steepness's variance ([HC_STEEP_NOISE]);
-- [HC_CIRCUIT] whether a circuit, its width and lanes (m), switchbacks (%);
-- [HC_SOFT_GROUND] the sand's bearing (kPa), digging, power (%), grip
-- (hundredths) and stones (%). Again whenever the menu makes another hill.
local picks = nil -- the menu's values, from the server's
buildat.sub_packet("hillclimb:hill", function(data)
	local v = {}
	for w in data:gmatch("%S+") do v[#v + 1] = tonumber(w) end
	if #v < 13 then
		return
	end
	hill = {size = magic.Vector3(v[1], v[2], v[3]),
		target = magic.Vector3(v[4], v[5], v[6]),
		lat = v[7], day = v[8], time = v[9]}
	picks = {seed = v[10], steep = v[11], length = v[12], payload = v[13],
		lat = v[7], day = v[8], hour = v[9], interval = v[15] or 0,
		steep_var = v[16] or 0, circuit = v[17] or 0, width = v[18] or 40,
		lane = v[19] or 7, switchbacks = v[20] or 50, bearing = v[21] or 80,
		dig = v[22] or 2, power = v[23] or 100, grip = v[24] or 60,
		stones = v[25] or 35}
	hill.may_pick = v[14] ~= 0
	log:info(string.format("hillclimb: the hill %dx%dx%d, at %g N, day %g, "
			.. "%g h; seed %d, %d degrees +-%d, %d m, %d kg", v[1], v[2], v[3],
			v[7], v[8], v[9], v[10], v[11], v[16] or 0, v[12], v[13]))
end)

-- The sky's hue by the sun's height, skeldat's hue_of_hour (copied)
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
	local tx, h, tz = sky_light.sun_toward(hill.lat, 0, hill.day,
			hill.time * 60)
	local l = math.sqrt(tx * tx + h * h + tz * tz)
	local dir = magic.Vector3(-tx / l, -h / l, -tz / l)
	sky:set_sun_direction({x = dir.x, y = dir.y, z = dir.z})
	-- [STARS_AXIS] The stars round the celestial pole, by the hour
	sky:set_sky_turn(sky_light.sky_turn_toward(hill.lat, 0, hill.time * 60))
	voxel_shading.set_sun_direction({x = dir.x, y = dir.y, z = dir.z})
	sky:set_moon_look(0)
	local day = math.max(0, math.min(1, (h + 0.15) / 0.3))
	day = math.max(day, sky_model.predawn(h))
	local lit = (0.175 + 0.825 * day) ^ 2.2
	local zenith, horizon = hue_of_hour(day, lit)
	zenith, horizon = sky_light.sky_radiance(zenith, horizon, h)
	sky:set_look(zenith, horizon, nil)
	local t = sky_light.terms(h, sky_light.dome(zenith, horizon))
	sky:set_dawn_glow(t.glow.r, t.glow.g, t.glow.b, t.glow_tint)
	local up = sky_model.above_horizon(h)
	sun_node.enabled = up > 0
	if up > 0 then
		sun_node.direction = dir
		sun.brightness = t.sun
		sun.color = magic.Color(t.sun_color.r, t.sun_color.g, t.sun_color.b)
	end
	local half = voxel_shading.sky_defaults.sun_half
	sky:set_sun_look(half, voxel_shading.sky_defaults.sun_color)
	sky:set_sun_radiance(sky_light.sun_disc(h, half, t.sun_color))
	sky:set_star_look(sky_model.STAR_DENSITY_DEFAULT, nil,
			(1 - day) * (1 - day))
	sky:set_cloud_lit(sky_light.cloud_lit(CLOUD, zenith, horizon, h, 1))
	sky_light.apply(voxel_shading, zone, magic, t)
	-- For the land around (light_outside), in the frame's units
	light_units = {ambient = t.ambient, bounce = {r = t.sky.r * PHYS.bounce,
		g = t.sky.g * PHYS.bounce, b = t.sky.b * PHYS.bounce}, lamp = t.lamp,
		sun = {r = t.sun_level * t.sun_color.r, g = t.sun_level * t.sun_color.g,
			b = t.sun_level * t.sun_color.b}}
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
-- The cars, drawn from hillclimb:car: car.h's Spec, in metres.
-- [HC_MULTIPLAYER] One each: this client's own (hillclimb:you) as it was,
-- the others' translucent with their names over them
--
local CAR = {tyre_r = 0.40, tyre_w = 0.30, track = 1.60, wheelbase = 2.80,
	mount_y = -0.1, droop = 0.45}
local function lit(r, g, b, a)
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique", a and
			"Techniques/NoTextureAlpha.xml" or "Techniques/NoTexture.xml"))
	m:SetShaderParameter("MatDiffColor", magic.Color(r, g, b, a or 1))
	m:SetShaderParameter("MatSpecColor", magic.Color(0.02, 0.02, 0.02))
	return m
end
local LOOKS = {
	own = {tyre = lit(0.01, 0.01, 0.01), rim = lit(0.15, 0.15, 0.14),
		steel = lit(0.05, 0.05, 0.06)},
	ghost = {tyre = lit(0.01, 0.01, 0.01, 0.35), rim = lit(0.15, 0.15, 0.14,
		0.35), steel = lit(0.05, 0.05, 0.06, 0.35)},
}
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
local hub_y = (CAR.mount_y - CAR.droop) * U
local SIDEWAYS = magic.Quaternion(90, magic.Vector3(0, 0, 1))
-- A car's nodes; a ghost's name over it
local function make_car(ghost, name)
	local look = ghost and LOOKS.ghost or LOOKS.own
	local c = {node = scene:CreateChild("Car"), wheels = {}, axles = {},
		states = {}, name = name}
	c.node.enabled = false
	part(c.node, "Box", look.steel, magic.Vector3(0, CAR.mount_y * U, 0),
			magic.Vector3(0.15 * U, 0.15 * U, (CAR.wheelbase + 0.3) * U))
	for i = 1, 4 do
		local x = (i % 2 == 1 and -1 or 1) * CAR.track / 2 * U
		local z = (i <= 2 and 1 or -1) * CAR.wheelbase / 2 * U
		local hub = c.node:CreateChild("Hub")
		hub.position = magic.Vector3(x, hub_y, z)
		local spin = hub:CreateChild("Spin")
		local d, w = 2 * CAR.tyre_r * U, CAR.tyre_w * U
		part(spin, "Cylinder", look.tyre, magic.Vector3(0, 0, 0),
				magic.Vector3(d, w, d), SIDEWAYS)
		part(spin, "Cylinder", look.rim, magic.Vector3(0, 0, 0),
				magic.Vector3(d * 0.6, w * 1.05, d * 0.6), SIDEWAYS)
		-- A bar across the rim, so the wheel is seen turning
		part(spin, "Box", look.steel, magic.Vector3(0, 0, 0),
				magic.Vector3(w * 1.1, 0.08 * U, d * 0.75))
		c.wheels[i] = {hub = hub, spin = spin, x = x, z = z}
	end
	for a = 1, 2 do
		c.axles[a] = part(c.node, "Box", look.steel, magic.Vector3(0, hub_y, 0),
				magic.Vector3(CAR.track * U, 0.1 * U, 0.1 * U))
	end
	if ghost then
		local l = c.node:CreateChild("Name")
		l.position = magic.Vector3(0, 2.2 * U, 0)
		local t = l:CreateComponent("Text3D")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 20)
		t.text = name
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		t.faceCameraMode = magic.FC_ROTATE_XYZ
		t.fixedScreenSize = true
		t.textEffect = magic.TE_STROKE
		t.effectColor = magic.Color(0, 0, 0, 0.8)
		log:info("hillclimb: " .. name .. "'s car drawn as a ghost")
	end
	return c
end

-- "id name" and the rest, by car: two states each, drawn a packet behind
-- and blended, so a car moves as smoothly as the frames do at the
-- server's 30 Hz. A car not heard of for 2 s is gone.
local own_id = nil
local cars = {}
buildat.sub_packet("hillclimb:you", function(data)
	own_id = tonumber(data)
	log:info("hillclimb: this client's car is " .. tostring(own_id))
end)
buildat.sub_packet("hillclimb:car", function(data)
	local id, name, rest = data:match("^(%d+) (%S+) (.*)$")
	id = tonumber(id)
	if not id or not own_id then
		return
	end
	local v = {}
	for w in rest:gmatch("%S+") do v[#v + 1] = tonumber(w) end
	if #v < 19 then
		return
	end
	local c = cars[id]
	if not c then
		c = make_car(id ~= own_id, name)
		cars[id] = c
	end
	c.states[1] = c.states[2]
	c.states[2] = {t = scene.elapsedTime, v = v}
	c.node.enabled = true
end)
local car_pos = nil
local function draw_car(c)
	local b = c.states[2]
	if b == nil then
		return
	end
	local a = c.states[1] or b
	local span = math.max(1e-3, b.t - a.t)
	local k = math.max(0, math.min(1, (scene.elapsedTime - b.t) / span))
	local function mix(i) return a.v[i] + (b.v[i] - a.v[i]) * k end
	c.pos = magic.Vector3(mix(1), mix(2), mix(3))
	c.node.position = c.pos
	c.node.rotation = magic.Quaternion(a.v[4], a.v[5], a.v[6], a.v[7]):Slerp(
			magic.Quaternion(b.v[4], b.v[5], b.v[6], b.v[7]), k)
	local spin_deg = math.deg(b.v[8])
	for i, w in ipairs(c.wheels) do
		local y = hub_y + b.v[10 + i]
		w.hub.position = magic.Vector3(w.x, y, w.z)
		w.y = y
		w.hub.rotation = magic.Quaternion(i <= 2 and math.deg(b.v[8 + i]) or 0,
				magic.Vector3(0, 1, 0))
		w.spin.rotation = magic.Quaternion(spin_deg, magic.Vector3(1, 0, 0))
	end
	-- Each axle between its two hubs, tilted as they stand
	for a_i = 1, 2 do
		local l, r = c.wheels[a_i * 2 - 1], c.wheels[a_i * 2]
		c.axles[a_i].position = magic.Vector3(0, (l.y + r.y) / 2, l.z)
		c.axles[a_i].rotation = magic.Quaternion(math.deg(math.atan2(r.y - l.y,
				r.x - l.x)), magic.Vector3(0, 0, 1))
	end
end
local function draw_cars()
	for id, c in pairs(cars) do
		if scene.elapsedTime - (c.states[2] and c.states[2].t or 0) > 2 then
			c.node:Remove()
			cars[id] = nil
		else
			draw_car(c)
		end
	end
	car_pos = cars[own_id] and cars[own_id].pos
end

-- [HC_MULTIPLAYER] 4: observing, the camera on the car furthest up the
-- slope (its z), driving ones first; a new leader taken after it has led
-- for 2 s, so two side by side do not flick it
local watch = {id = nil, cand = nil, since = 0}
local function observed()
	local own = cars[own_id]
	if not (own and own.states[2] and own.states[2].v[19] == 1) then
		watch.id = nil
		return nil
	end
	local best, best_z, running = nil, nil, false
	for id, c in pairs(cars) do
		local s = c.states[2]
		if s and c.pos then
			local run = s.v[17] == 1
			if (run and not running) or (run == running and
					(best_z == nil or c.pos.z > best_z)) then
				best, best_z, running = id, c.pos.z, run
			end
		end
	end
	local now = scene.elapsedTime
	if best ~= watch.cand then
		watch.cand, watch.since = best, now
	end
	if best and (watch.id == nil or not cars[watch.id] or
			(best ~= watch.id and now - watch.since >= 2)) then
		watch.id = best
		log:info("hillclimb: observing " .. cars[best].name)
	end
	return watch.id and cars[watch.id]
end

-- The stones come loose (main.cpp send_rocks): "id x y z qw qx qy qz
-- radius" each, ";" between, in voxels; spheres while they fly, the
-- voxels again when they rest
local STONE = lit(0.07, 0.066, 0.06)
local rocks = {}
buildat.sub_packet("hillclimb:rocks", function(data)
	local seen = {}
	for item in data:gmatch("[^;]+") do
		local v = {}
		for w in item:gmatch("%S+") do v[#v + 1] = tonumber(w) end
		if #v >= 9 then
			local r = rocks[v[1]]
			if r == nil then
				r = part(scene, "Sphere", STONE, magic.Vector3(0, 0, 0),
						magic.Vector3(2 * v[9], 2 * v[9], 2 * v[9]))
				rocks[v[1]] = r
			end
			r.position = magic.Vector3(v[2], v[3], v[4])
			r.rotation = magic.Quaternion(v[5], v[6], v[7], v[8])
			seen[v[1]] = true
		end
	end
	for id, r in pairs(rocks) do
		if not seen[id] then
			r:Remove()
			rocks[id] = nil
		end
	end
end)

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
	{id = "chat", label = "Chat", default = "T", shared = "chat"},
}
local key = {}
-- [HC_HUD_LAYOUT] Each one's name as bound, for the texts that name it
local key_name = {}
-- Again after the settings window, where they may have changed
local function read_keys()
	local names = buildat.declare_keys(nil, "hillclimb", KEYS)
	for _, k in ipairs(KEYS) do
		local name = type(names) == "table" and names[k.id] or k.default
		key[k.id] = magic.input:GetKeyFromName(name)
		key_name[k.id] = name
	end
end
read_keys()
local function down(id)
	return key[id] ~= 0 and magic.input:GetKeyDown(key[id])
end
local gear = 2
local menu = nil -- the menu, {values, root} while open: no driving
-- [HC_MULTIPLAYER] 6: the chat, builtin/chat's, its console
-- builtin/accounts' (skeldat's); open: no driving
local chat = require("buildat/module/chat")
local chat_open = false
local accounts
do
	local _, err, acc = buildat.run_script_file("accounts/accounts.lua")
	if type(acc) == "table" then
		accounts = acc
		-- The join was the boot's (main/join.lua) or none: the packets are
		-- this instance's from here on
		accounts.logged_in = true
		chat.attach(accounts)
	else
		log:warning("hillclimb: no accounts.lua: " .. tostring(err))
	end
end
-- after: run when it closes (the pause menu's way back)
local function open_chat(after)
	if not accounts or chat_open then
		return
	end
	chat_open = true
	local function back()
		accounts.close_page()
		chat_open = false
		magic.ui:SetFocusElement(nil)
		log:info("hillclimb: the chat closed")
		if after then
			after()
		end
	end
	accounts.chat_page(back)
	log:info("hillclimb: the chat shown")
end
local pause = nil -- main/pause.lua's, made below
-- [HC_TOUCH] main/touch.lua's on a touchscreen, made below; its Start
-- button's reset, sent once
local touch, touch_reset = nil, false
local sent, sent_t = nil, 0
-- "accel brake left right gear reset steer" (main.cpp on_input), sent
-- when it changes and twice a second besides; steer -100..100, the keys'
-- full lock or the touch stick's
local function send_input()
	for g = 1, 4 do
		if down("gear" .. g) then gear = g end
	end
	if down("reverse") then gear = 0 end
	local function b(id)
		return not menu and not chat_open and not pause.held() and down(id)
				and 1 or 0
	end
	local accel, brake, left, right = b("accel"), b("brake"), b("left"),
			b("right")
	local steer = (right - left) * 100
	local st = touch and touch.input
	if st then
		gear = st.gear or gear
		accel = st.accel and 1 or accel
		brake = st.brake and 1 or brake
		steer = math.floor(st.steer * 100 + 0.5)
	end
	local msg = string.format("%d %d %d %d %d %d %d", accel, brake, left,
			right, gear, touch_reset and 1 or b("reset"), steer)
	touch_reset = false
	local now = scene.elapsedTime
	if msg ~= sent then
		-- The car's z (up the slope) for the check
		log:info(string.format("hillclimb: input %s at z %.1f m", msg,
				car_pos and car_pos.z / U or 0))
	end
	if msg ~= sent or now - sent_t > 0.5 then
		buildat.send_packet("hillclimb:input", msg)
		sent, sent_t = msg, now
	end
end

--
-- The clock, the ranking and the menu
--
-- [HC_HUD_LAYOUT] A text on the brand's background, a box sized to it;
-- hidden while it says nothing. draw_hud places each.
local PAD = 4
local function panel(size, colour)
	local bg = magic.ui.root:CreateChild("BorderImage")
	bg.color = magic.Color(ui_utils.rgb("background"))
	local t = bg:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), size)
	t:SetPosition(PAD, PAD)
	if colour then
		t.color = magic.Color(ui_utils.rgb(colour))
	end
	bg.visible = false
	return {bg = bg, t = t, shown = true}
end
local function set_panel(p, s, x, y)
	p.bg.visible = p.shown and s ~= ""
	if s == "" then
		return
	end
	p.t:SetText(s)
	p.bg:SetFixedSize(p.t.width + 2 * PAD, p.t.height + 2 * PAD)
	-- A function of the size: where it goes
	if type(x) == "function" then
		x, y = x(p.bg.width, p.bg.height)
	end
	p.bg:SetPosition(math.floor(x), math.floor(y))
end
-- The state the player is at, brand cyan, top left; the bound keys under
-- it; what asks the player to act or wait, brand amber, across at 75%
-- down; the ranking bottom left, the chat over it
local status = panel(9, "focus")
local hint = panel(9)
local prompt = panel(9, "main")
local board = panel(8)
-- The chat's last lines, and the round's results, a while each
local chat_text = panel(8)
local said_prompt = nil
local chat_lines = {}
table.insert(chat.listeners, function(line)
	chat_lines[#chat_lines + 1] = {line = line, t = buildat.get_time_us()}
	if #chat_lines > 5 then
		table.remove(chat_lines, 1)
	end
end)
local round = {phase = 0, left = 0}
buildat.sub_packet("hillclimb:round", function(data)
	local phase, left = data:match("^(%d+) (%S+)")
	round.phase, round.left = tonumber(phase) or 0, tonumber(left) or 0
end)
local results = nil
buildat.sub_packet("hillclimb:results", function(data)
	results = {text = data, t = scene.elapsedTime}
	log:info("hillclimb: the round's results:" .. (data == "" and " no runs"
			or data:gsub("\n", "; ")))
end)
-- "<rank of the last finish or -1>", then a line each, "time laps
-- finished unfinished date name" (main.cpp send_ranking), under the hill
-- and the payload now picked; laps -1 on the straight hill, a circuit's
-- time the round's clock at the last lap; the counts the runs ended on the
-- hill before
local ranking = {last = -1, entries = {}}
buildat.sub_packet("hillclimb:ranking", function(data)
	local first = true
	ranking = {last = -1, entries = {}}
	for line in data:gmatch("[^\n]+") do
		if first then
			ranking.last = tonumber(line) or -1
			first = false
		else
			local t, laps, f, u, date, name = line:match(
					"^(%S+) (%-?%d+) (%d+) (%d+) (%S+) (.+)$")
			if t then
				ranking.entries[#ranking.entries + 1] = {t = tonumber(t),
					laps = tonumber(laps),
					fin = tonumber(f), unfin = tonumber(u), date = date,
					name = name}
			end
		end
	end
end)

local MENU = {
	{id = "seed", label = "Seed", min = 1, max = 999999, step = 1},
	{id = "steep", label = "Steepness", min = 5, max = 40, step = 1,
		unit = " degrees"},
	-- [HC_STEEP_NOISE] How far it varies over the slope, either way
	{id = "steep_var", label = "Steepness varies", min = 0, max = 10,
		step = 1, unit = " degrees", show = function(v) return "+-" .. v end},
	{id = "length", label = "Length", min = 20, max = 60, step = 5,
		unit = " m"},
	-- [HC_CIRCUIT] A circuit's own, shown in that mode
	{id = "width", label = "Width", min = 12, max = 60, step = 2, unit = " m",
		circuit = true},
	{id = "lane", label = "Lane width", min = 4, max = 12, step = 1,
		unit = " m", circuit = true},
	{id = "switchbacks", label = "Switchbacks", min = 0, max = 100, step = 10,
		unit = "%", circuit = true},
	{id = "payload", label = "Payload", list = {0, 500, 1000, 2000},
		unit = " kg"},
	-- [HC_SOFT_GROUND] How the ground gives (main.cpp's KNOBS), the menu's
	-- second page: softer sand sinks under the car's weight, more digging
	-- throws more where a tyre spins, more power spins them more; more grip
	-- slips and digs less
	{id = "bearing", label = "Sand firmness", min = 20, max = 100, step = 10,
		unit = " kPa", ground = true},
	{id = "dig", label = "Digging", min = 1, max = 8, step = 1, ground = true},
	{id = "power", label = "Engine power", min = 50, max = 200, step = 10,
		unit = "%", ground = true},
	{id = "grip", label = "Grip", min = 40, max = 100, step = 5, ground = true,
		show = function(v) return string.format("%.2f", v / 100) end},
	{id = "stones", label = "Loose stones", min = 15, max = 50, step = 5,
		unit = "% open", ground = true},
	{id = "lat", label = "Latitude", min = -80, max = 80, step = 5,
		unit = " degrees"},
	{id = "day", label = "Day of the year", min = 1, max = 365, step = 7},
	{id = "hour", label = "Hour (solar)", min = 0, max = 24, step = 0.5},
	-- [HC_MULTIPLAYER] 3: the rounds, seconds (0 never)
	{id = "interval", label = "Rounds", list = {0, 60, 120, 180, 300, 600,
		900, 1800}, show = function(v)
			return v == 0 and "never" or (v / 60 .. " min") end},
	-- [HC_CIRCUIT] The race: the straight climb or laps of a circuit;
	-- picking it brings its defaults
	{id = "circuit", label = "Race", list = {0, 1}, show = function(v)
		return v == 1 and "Circuit" or "Straight" end},
}
local MODE_DEFAULTS = {
	[0] = {steep = 27, steep_var = 4, length = 50},
	[1] = {steep = 18, steep_var = 4, length = 40, width = 40, lane = 7,
		switchbacks = 50},
}
-- [HC_HILL_MENU] A setting's choices for its dropdown: a list's entries,
-- a range's min..max by step, as {label, value}; the current value in
-- its place when it is between the steps (day 172 of a 7-day step)
local function menu_choices(m, current)
	local out = {}
	local function add(v)
		out[#out + 1] = {(m.show and m.show(v) or tostring(v)) ..
				(m.unit or ""), v}
	end
	local vs = {}
	if m.list then
		for _, v in ipairs(m.list) do vs[#vs + 1] = v end
	else
		for i = 0, math.floor((m.max - m.min) / m.step + 0.5) do
			vs[#vs + 1] = m.min + i * m.step
		end
	end
	local found = false
	for _, v in ipairs(vs) do found = found or v == current end
	if not found and current then
		vs[#vs + 1] = current
		table.sort(vs)
	end
	for _, v in ipairs(vs) do add(v) end
	return out
end
local function pressed(name)
	return magic.input:GetKeyPress(name)
end
-- A key typed into a field is the field's ([WEB_JOIN_054]: the setup code's
-- "T" opened the chat over the login page)
local function typing()
	local focus = magic.ui.focusElement
	return focus ~= nil and focus:GetTypeName() == "LineEdit"
end
local hud_note = nil
-- [HC_MISSED_TURN_MARK] The turn this car went past without passing: its
-- square a translucent red block until it is driven, then green for a
-- second (main.cpp set_missed)
local MISSED = {red = lit(0.9, 0.05, 0.03, 0.45), green = lit(0.1, 0.85, 0.15, 0.45)}
local missed = nil -- {n, node, ok, t}
buildat.sub_packet("hillclimb:missed", function(data)
	if missed then
		missed.node:Remove()
		missed = nil
	end
	local ok, v = data:sub(1, 3) == "ok ", {}
	for w in data:gmatch("[%d.-]+") do v[#v + 1] = tonumber(w) end
	if #v < 6 then
		log:info("hillclimb: no missed turn")
		return
	end
	local n, x0, z0, x1, z1, y = v[1], v[2], v[3], v[4], v[5], v[6]
	local node = scene:CreateChild("Missed turn")
	part(node, "Box", ok and MISSED.green or MISSED.red,
			magic.Vector3((x0 + x1) / 2, y + 1.5 * U, (z0 + z1) / 2),
			magic.Vector3(x1 - x0, 4 * U, z1 - z0))
			:GetComponent("StaticModel").castShadows = false
	missed = {n = n, node = node, ok = ok, t = scene.elapsedTime}
	log:info("hillclimb: turn " .. n .. (ok and " driven" or " missed"))
end)
-- [HC_OPEN_EDGES] "Off the track": the car put back (main.cpp)
buildat.sub_packet("hillclimb:note", function(data)
	hud_note = {text = data, t = scene.elapsedTime}
	log:info("hillclimb: note: " .. data)
end)
-- A drive's own: "event hillclimb_params <the packet>", sent whether or
-- not this client may pick, as a modified client would (the refusal's
-- check)
magic.SubscribeToEvent("command_seq:hillclimb_params", function(_, d)
	buildat.send_packet("hillclimb:params", d:GetString("Param"))
	log:info("hillclimb: the drive sends params " .. d:GetString("Param"))
end)
-- The Tab menu ([HC_HILL_MENU]: a window, a row a setting), or why not;
-- menu_values, its values to open again with (another race or page picked)
local menu_values = nil
local function close_hill_menu()
	if not menu then
		return
	end
	ui_utils.close_dropdowns()
	uistack.main:pop(menu.root)
	menu = nil
	-- A clicked button stays the focus, and Space would press it again
	magic.ui:SetFocusElement(nil)
	log:info("hillclimb: the hill menu closed")
end
local function open_hill_menu()
	if picks and not hill.may_pick then
		hud_note = {text = "Only an admin picks the hill here",
			t = scene.elapsedTime}
		return
	elseif not picks or menu then
		return
	end
	local values = {}
	for k, v in pairs(menu_values or picks) do values[k] = v end
	menu_values = nil
	menu = {values = values, root = uistack.main:push({desc = "hill"})}
	-- Rows of 24 four apart: the whole of it on a 400 high UI (800 x 500
	-- at a UI scale of 1.25); a circuit's three rows more, 20 two apart
	local row_h = values.circuit == 1 and 20 or 24
	local m = ui_utils.vertical_menu(menu.root, {min_width = 340,
		min_height = row_h, spacing = values.circuit == 1 and 2 or 4,
		padding = magic.IntRect(10, 6, 10, 6)})
	m.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local title = m.window:CreateChild("Text")
	title:SetStyleAuto()
	local ground = values.page == "ground"
	title.text = ground and "The ground and the car" or "The hill"
	title:SetFontSize(16)
	-- The seed: its digits typed, 1..999999, anything else back to the
	-- last good one when it loses the focus; and Random
	local row = m.window:CreateChild("UIElement")
	row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(0, 0, 0, 0))
	row:SetFixedHeight(row_h)
	local label = row:CreateChild("Text")
	label:SetStyleAuto()
	label.text = "Seed"
	label.verticalAlignment = magic.VA_CENTER
	local edit = row:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit:SetFixedWidth(110)
	edit.text = tostring(values.seed)
	local function seed_read()
		local n = tonumber(edit.text)
		if n and n == math.floor(n) and n >= 1 and n <= 999999 then
			values.seed = n
		end
		edit.text = tostring(values.seed)
	end
	magic.SubscribeToEvent(edit, "Defocused", seed_read)
	magic.SubscribeToEvent(edit, "TextFinished", seed_read)
	local random = row:CreateChild("Button")
	random:SetStyleAuto()
	random:SetLayout(magic.LM_VERTICAL, 0, magic.IntRect(8, 0, 8, 0))
	local rt = random:CreateChild("Text")
	rt:SetStyleAuto()
	rt.text = "Random"
	rt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	m:add(random, function()
		values.seed = math.random(1, 999999)
		edit.text = tostring(values.seed)
	end)
	for i = 2, #MENU do
		local e = MENU[i]
		local choices = menu_choices(e, values[e.id])
		-- A circuit's rounds end: "never" not offered
		if e.id == "interval" and values.circuit == 1 and choices[1][2] == 0 then
			table.remove(choices, 1)
		end
		if (e.ground or false) == ground and (values.circuit == 1 or
				not e.circuit) then
			m:add_dropdown(e.label, choices, values[e.id], function(v)
				values[e.id] = v
				log:info("hillclimb: the hill menu: " .. e.id .. " " .. v)
				-- Another race: its defaults, the menu again with its rows
				-- (on the next frame, out of the dropdown's own event)
				if e.id == "circuit" then
					for k, d in pairs(MODE_DEFAULTS[v]) do values[k] = d end
					if v == 1 and values.interval == 0 then
						values.interval = 600
					end
					menu_values = values
				end
			end, {label_width = 130, height = row_h})
		end
	end
	m:add("Make it", function()
		seed_read()
		local v = values
		local params = string.format(
				"%d %d %d %d %g %g %g %d %d %d %d %d %d %d %d %d %d %d",
				v.seed, v.steep, v.length, v.payload, v.lat, v.day, v.hour,
				v.interval, v.steep_var, v.circuit, v.width, v.lane, v.switchbacks,
				v.bearing, v.dig, v.power, v.grip, v.stones)
		buildat.send_packet("hillclimb:params", params)
		log:info("hillclimb: the hill menu sends params " .. params)
		close_hill_menu()
	end, true)
	-- The other page, these values kept (on the next frame, as above), on
	-- one row with Close: the window as high as it was, its rows where
	-- the touch check taps them
	local last = m.window:CreateChild("UIElement")
	last:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(0, 0, 0, 0))
	for _, b in ipairs({
		{ground and "Back to the hill" or "Ground and car...",
			function()
				seed_read()
				values.page = not ground and "ground" or nil
				menu_values = values
			end},
		{"Close", close_hill_menu}}) do
		local button = last:CreateChild("Button")
		button:SetStyleAuto()
		button:SetLayout(magic.LM_VERTICAL, 0, magic.IntRect(8, 0, 8, 0))
		button:SetFixedHeight(row_h)
		local t = button:CreateChild("Text")
		t:SetStyleAuto()
		t.text = b[1]
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		m:add(button, b[2])
	end
	log:info("hillclimb: the hill menu shown" ..
			(ground and " (the ground and the car)" or ""))
end
local function menu_keys()
	-- Tab opens and closes it; a dropdown's popup has the keys first
	if menu and menu_values then
		close_hill_menu()
		open_hill_menu()
	end
	if pressed(magic.KEY_TAB) and not ui_utils.dropdown_open() then
		if menu then
			close_hill_menu()
		else
			open_hill_menu()
		end
	end
	board.shown = menu == nil
end

local GEARS = {[0] = "R", "1", "2", "3", "4"}
local ROUND = {"The round's clock starts with the first drive",
	"Round %d:%02d left", "Extra time %d:%02d",
	"The round is over; a new hill in %d s"}
local function mmss(x)
	x = math.max(0, math.floor(x))
	return math.floor(x / 60), x % 60
end
-- What is watched: this client's car, or observing, the leader's
local function draw_hud(watched)
	local own = cars[own_id]
	local b = own and own.states[2]
	if b == nil then
		return
	end
	local race, t = b.v[17], b.v[18]
	local circuit = picks and picks.circuit == 1
	local laps = b.v[20] or 0
	-- [HC_HUD_LAYOUT] The middle: what asks for an action or a wait;
	-- while driving only a missed turn and the server's notes
	local go = touch and "The stick up" or key_name.accel
	local ask = {}
	if race == 0 then
		ask[1] = go .. (circuit and " starts your laps" or " starts the clock")
	elseif race == 2 then
		ask[1] = circuit and string.format("%d laps in the round", laps) or
				string.format("Finished in %.2f s. %s: another run", t,
				touch and "Start" or key_name.reset)
	elseif race == 3 then
		ask[1] = "The hill is being made"
	elseif race == 4 then
		ask[1] = "Out of time: did not finish"
	end
	if race ~= 1 and (round.phase == 1 or round.phase == 4) then
		ask[#ask + 1] = round.phase == 4 and string.format(ROUND[4],
				math.ceil(round.left)) or ROUND[1]
	end
	if missed and missed.ok and scene.elapsedTime - missed.t > 1 then
		missed.node:Remove()
		missed = nil
	end
	if missed and not missed.ok then
		ask[#ask + 1] = "Missed turn " .. missed.n
	elseif hud_note and scene.elapsedTime - hud_note.t < 3 then
		ask[#ask + 1] = hud_note.text
	end
	-- The status line: laps, the round's clock, the gear, the time
	local line = {}
	if watched and watched ~= own and watched.states[2] then
		line[1] = string.format("Observing %s: %.2f s", watched.name,
				watched.states[2].v[18])
	else
		if circuit and race == 1 then
			line[#line + 1] = string.format("Laps: %d", laps)
		end
		if round.phase == 2 or round.phase == 3 then
			line[#line + 1] = string.format(ROUND[round.phase], mmss(round.left))
		elseif race == 1 and round.phase == 1 then
			line[#line + 1] = ROUND[1]
		end
		line[#line + 1] = "Gear " .. (GEARS[b.v[16]] or "?")
		line[#line + 1] = string.format("%.2f s", t)
	end
	local W, H = magic.ui.root.width, magic.ui.root.height
	set_panel(status, table.concat(line, "   "), 12, 10)
	-- The keys as bound, no more; the touch controls' buttons say theirs
	-- simplified: the most important ones fixed here; a game's own list
	-- when a second game wants one
	hint.shown = not touch
	local k = key_name
	set_panel(hint, string.format("%s %s %s %s  %s %s %s %s  %s  %s  Tab  %s  Esc",
			k.accel, k.left, k.brake, k.right, k.gear1, k.gear2, k.gear3,
			k.gear4, k.reverse, k.reset, k.chat), 12,
			10 + (status.bg.visible and status.bg.height + 4 or 0))
	local said = table.concat(ask, "\n")
	set_panel(prompt, said, function(w, h)
		return (W - w) / 2, H * 0.75 - h / 2
	end)
	if said ~= said_prompt then
		said_prompt = said
		-- Its middle, which a check holds to the screen's
		log:info(string.format("hillclimb: the prompt centred at %d,%d of %dx%d: %s",
				prompt.bg.position.x + prompt.bg.width / 2,
				prompt.bg.position.y + prompt.bg.height / 2, W, H,
				(said:gsub("\n", " | "))))
	end
	if picks then
		local rows = {}
		if results and scene.elapsedTime - results.t < 8 then
			rows[1] = "The round's results:"
			for l in results.text:gmatch("[^\n]+") do
				rows[#rows + 1] = l:match("^%- ") and (l:sub(3) ..
						": did not finish") or ("  " .. l)
			end
		else
			rows[1] = string.format("Best on this %s with %d kg:",
					circuit and "circuit" or "hill", picks.payload)
			for i, e in ipairs(ranking.entries) do
				-- How worn the hill was when the run started
				local worn = (e.fin + e.unfin == 0) and "fresh" or
						string.format("after %d runs (%d finished)",
						e.fin + e.unfin, e.fin)
				local mark = i - 1 == ranking.last and ">" or " "
				rows[#rows + 1] = (e.laps or -1) >= 0 and string.format(
						"%s%2d. %3d laps, the last at %7.2f s  %s", mark, i, e.laps,
						e.t, e.name) or string.format("%s%2d. %7.2f s  %s, %s",
						mark, i, e.t, e.name, worn)
			end
			if #ranking.entries == 0 then
				rows[#rows + 1] = "  (none yet)"
			end
		end
		set_panel(board, table.concat(rows, "\n"), function(w, h)
			return 12, H - h - 10
		end)
	end
	local now, shown = buildat.get_time_us(), {}
	for _, c in ipairs(chat_lines) do
		if now - c.t < 20e6 then
			shown[#shown + 1] = c.line
		end
	end
	local over = board.bg.visible and board.bg.position.y or H
	set_panel(chat_text, table.concat(shown, "\n"), function(w, h)
		return 12, over - h - 6
	end)
end

-- [HC_SCORES] A High scores set's parameters made the hill, the seed,
-- the place and the hour kept, as the hill menu sends them
local function drive_set(set)
	if not picks then
		return
	end
	local v = picks
	local c = set.circuit and 1 or 0
	-- A knob not in the set's key is at its default
	local params = string.format(
			"%d %d %d %d %g %g %g %d %d %d %d %d %d %d %d %d %d %d",
			v.seed, set.steep or v.steep, set.length or v.length,
			set.payload or 0, v.lat, v.day, v.hour,
			c == 1 and (set.round or 600) or v.interval, set.var or 0, c,
			set.width or v.width, set.lane or v.lane,
			set.switch or v.switchbacks, set.bearing or 80, set.dig or 2,
			set.power or 100, set.grip or 60, set.stones or 35)
	buildat.send_packet("hillclimb:params", params)
	log:info("hillclimb: the high scores' set sends params " .. params)
end
pause = load("main/pause.lua")({hill_menu = open_hill_menu,
	chat = open_chat, keys = read_keys, drive = drive_set,
	may_pick = function() return hill ~= nil and hill.may_pick end})
-- The orbit about the car: dragged with the left button, the wheel the
-- distance
local yaw, pitch, dist = 200, 20, 12 * U
local function set_dist(v)
	dist = math.max(3 * U, math.min(80 * U, v))
end

-- simplified: the Tab menu, opened from the pause menu, takes keys only
if buildat.get_env("BUILDAT_TOUCH") == "1" then
	touch = load("main/touch.lua")({
		start = function() touch_reset = true end,
		chat = function() open_chat() end,
		menu = function()
			close_hill_menu()
			pause.open()
		end,
		-- Driving (not observing), no menu or window up
		active = function()
			return not menu and not chat_open and not pause.held() and
					watch.id == nil
		end,
		visible = function() return not chat_open and not pause.held() end,
		-- [HC_TOUCH_ORBIT] The camera's area: as the mouse's drag, a HUD
		-- pixel 0.3 degrees
		observing = function() return watch.id ~= nil end,
		camera = function()
			return not menu and not chat_open and not pause.held()
		end,
		orbit = function(dx, dy)
			yaw = (yaw + dx * 0.3) % 360
			pitch = math.max(-10, math.min(85, pitch + dy * 0.3))
		end,
		zoom = function(r) set_dist(dist * r) end,
		orbit_end = function()
			log:info(string.format("hillclimb: camera yaw %.0f pitch %.0f "
					.. "dist %.1f m", yaw, pitch, dist / U))
		end,
	})
end

magic.SubscribeToEvent("MouseWheel", function(_, d)
	local w = d:GetInt("Wheel")
	set_dist(dist * (w > 0 and 0.85 or 1.18))
end)

magic.SubscribeToEvent("Update", function(_, d)
	local dt = d:GetFloat("TimeStep")
	if hill == nil then
		return
	end
	update_sky()
	light_outside(dt)
	voxel_shading.update(dt)
	draw_cars()
	-- [HC_PAUSE_MENU] Escape: the Tab menu closed if it is open, else the
	-- pause menu opened or closed (not while the chat or the settings
	-- window has it)
	if pressed(magic.KEY_ESCAPE) and not chat_open and not (pause.held() and
			not pause.escape_closes()) and not ui_utils.dropdown_open() then
		if menu then
			close_hill_menu()
		elseif pause.shown() then
			pause.close()
		else
			pause.open()
		end
	end
	if not chat_open and not menu and not pause.held() and not typing() and
			pressed(key.chat) then
		open_chat()
	end
	if not chat_open and not pause.held() then
		menu_keys()
	end
	send_input()
	local watched = observed()
	draw_hud(watched or cars[own_id])
	local m = magic.input:GetMouseMove()
	-- A finger is a mouse's to SDL too: on a touchscreen touch.lua orbits
	if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) and
			not pause.held() and not touch then
		yaw = (yaw + m.x * 0.3) % 360
		pitch = math.max(-10, math.min(85, pitch + m.y * 0.3))
	end
	local y, p = math.rad(yaw), math.rad(pitch)
	-- [HC_MULTIPLAYER] 4: observing, the leader's car; else this client's
	local t = (watched and watched.pos) or car_pos or hill.target
	camera_node.position = magic.Vector3(
			t.x + dist * math.cos(p) * math.sin(y),
			t.y + 0.5 * U + dist * math.sin(p),
			t.z + dist * math.cos(p) * math.cos(y))
	camera_node:LookAt(magic.Vector3(t.x, t.y, t.z))
end)
