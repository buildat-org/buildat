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
-- and the menu (Tab) picking the hill, the payload and the hour. A world
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

-- The land around, level with the bottom pad (a voxel's centre is its
-- integer position, so the pad's top is half a voxel over the start's y
-- - 1) and a tenth of a voxel under it so the pad draws over it: the
-- hill does not float. Its colour is a linear albedo over pi, the units
-- the pbr voxels are lit in, by eye against the sand.
-- simplified: a plain colour, no texture (Material has no UV transform
-- in the whitelist); a textured ground is the shader param UOffset's
local ground = scene:CreateChild("Ground")
ground.scale = magic.Vector3(1000 * U, 1, 1000 * U)
ground.enabled = false
do
	local model = ground:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Plane.mdl")
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTexture.xml"))
	m:SetShaderParameter("MatDiffColor", magic.Color(0.12, 0.10, 0.06))
	m:SetShaderParameter("MatSpecColor", magic.Color(0, 0, 0))
	model.material = m
end

-- What the server says (main.cpp hill_packet): the hill's size, where the
-- car starts, in voxels; the latitude, the day and the hour; the seed,
-- the steepness, the length and the payload; whether this client may
-- pick ([HC_MULTIPLAYER] 2: an admin on a public server) and the rounds'
-- interval, seconds. Again whenever the menu makes another hill.
local hill = nil
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
		lat = v[7], day = v[8], hour = v[9], interval = v[15] or 0}
	hill.may_pick = v[14] ~= 0
	ground.position = magic.Vector3(v[4], v[5] - 0.6, v[3] / 2)
	ground.enabled = true
	log:info(string.format("hillclimb: the hill %dx%dx%d, at %g N, day %g, "
			.. "%g h; seed %d, %d degrees, %d m, %d kg", v[1], v[2], v[3], v[7],
			v[8], v[9], v[10], v[11], v[12], v[13]))
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
local gear = 2
local menu = nil -- the menu, {sel, values} while open: no driving
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
local function open_chat()
	if not accounts or chat_open then
		return
	end
	chat_open = true
	local function back()
		accounts.close_page()
		chat_open = false
		magic.ui:SetFocusElement(nil)
		log:info("hillclimb: the chat closed")
	end
	accounts.chat_page(back)
	log:info("hillclimb: the chat shown")
end
local sent, sent_t = nil, 0
-- "accel brake left right gear reset" (main.cpp on_input), sent when it
-- changes and twice a second besides
local function send_input()
	for g = 1, 4 do
		if down("gear" .. g) then gear = g end
	end
	if down("reverse") then gear = 0 end
	local function b(id)
		return not menu and not chat_open and down(id) and 1 or 0
	end
	local msg = string.format("%d %d %d %d %d %d", b("accel"), b("brake"),
			b("left"), b("right"), gear, b("reset"))
	local now = scene.elapsedTime
	if msg ~= sent or now - sent_t > 0.5 then
		buildat.send_packet("hillclimb:input", msg)
		sent, sent_t = msg, now
	end
end

--
-- The clock, the ranking and the menu
--
local function text(x, y, size)
	local t = magic.ui.root:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), size)
	t:SetTextEffect(magic.TE_SHADOW)
	t:SetPosition(x, y)
	return t
end
local hud = text(12, 10, 18)
local board = text(12, 120, 15)
-- The chat's last lines, and the round's results, a while each
local chat_text = text(12, 330, 15)
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
local menu_text = text(12, 120, 16)
menu_text.visible = false

-- "<rank of the last finish or -1>", then a line each, "time finished
-- unfinished date name" (main.cpp send_ranking), under the hill and the
-- payload now picked; the counts the runs ended on the hill before
local ranking = {last = -1, entries = {}}
buildat.sub_packet("hillclimb:ranking", function(data)
	local first = true
	ranking = {last = -1, entries = {}}
	for line in data:gmatch("[^\n]+") do
		if first then
			ranking.last = tonumber(line) or -1
			first = false
		else
			local t, f, u, date, name = line:match(
					"^(%S+) (%d+) (%d+) (%S+) (.+)$")
			if t then
				ranking.entries[#ranking.entries + 1] = {t = tonumber(t),
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
	{id = "length", label = "Length", min = 20, max = 60, step = 5,
		unit = " m"},
	{id = "payload", label = "Payload", list = {0, 500, 1000, 2000},
		unit = " kg"},
	{id = "lat", label = "Latitude", min = -80, max = 80, step = 5,
		unit = " degrees"},
	{id = "day", label = "Day of the year", min = 1, max = 365, step = 7},
	{id = "hour", label = "Hour (solar)", min = 0, max = 24, step = 0.5},
	-- [HC_MULTIPLAYER] 3: the rounds, seconds (0 never)
	{id = "interval", label = "Rounds", list = {0, 60, 120, 180, 300, 600,
		900, 1800}, show = function(v)
			return v == 0 and "never" or (v / 60 .. " min") end},
}
local function menu_draw()
	local lines = {"The hill and the car (Up/Down, Left/Right; Enter: make it;"
			.. " Tab: close)", ""}
	for i, m in ipairs(MENU) do
		local v = menu.values[m.id]
		lines[#lines + 1] = string.format("%s %-16s %s%s",
				i == menu.sel and ">" or " ", m.label,
				m.show and m.show(v) or tostring(v), m.unit or "")
	end
	menu_text:SetText(table.concat(lines, "\n"))
end
local function menu_change(dir)
	local m = MENU[menu.sel]
	local v = menu.values[m.id]
	if m.list then
		local i = 1
		for j, x in ipairs(m.list) do if x == v then i = j end end
		v = m.list[(i - 1 + dir) % #m.list + 1]
	else
		v = math.max(m.min, math.min(m.max, v + dir * m.step))
	end
	menu.values[m.id] = v
end
local function pressed(name)
	return magic.input:GetKeyPress(name)
end
local hud_note = nil
-- A drive's own: "event hillclimb_params <the packet>", sent whether or
-- not this client may pick, as a modified client would (the refusal's
-- check)
magic.SubscribeToEvent("command_seq:hillclimb_params", function(_, d)
	buildat.send_packet("hillclimb:params", d:GetString("Param"))
	log:info("hillclimb: the drive sends params " .. d:GetString("Param"))
end)
local function menu_keys()
	if pressed(magic.KEY_TAB) then
		if menu then
			menu = nil
		elseif picks and not hill.may_pick then
			hud_note = {text = "Only an admin picks the hill here",
				t = scene.elapsedTime}
		elseif picks then
			local values = {}
			for k, v in pairs(picks) do values[k] = v end
			menu = {sel = 1, values = values}
		end
	end
	menu_text.visible = menu ~= nil
	board.visible = menu == nil
	if not menu then
		return
	end
	if pressed(magic.KEY_UP) then menu.sel = (menu.sel - 2) % #MENU + 1 end
	if pressed(magic.KEY_DOWN) then menu.sel = menu.sel % #MENU + 1 end
	if pressed(magic.KEY_LEFT) then menu_change(-1) end
	if pressed(magic.KEY_RIGHT) then menu_change(1) end
	if pressed(magic.KEY_RETURN) then
		local v = menu.values
		buildat.send_packet("hillclimb:params", string.format(
				"%d %d %d %d %g %g %g %d", v.seed, v.steep, v.length,
				v.payload, v.lat, v.day, v.hour, v.interval))
		menu = nil
		menu_text.visible = false
		board.visible = true
		return
	end
	menu_draw()
end

local GEARS = {[0] = "R", "1", "2", "3", "4"}
local ROUND = {"Round: the clock starts with the first drive",
	"Round: %d:%02d left", "Extra time: %d:%02d left to finish",
	"The round is over; a new hill in %d s"}
local function mmss(x)
	x = math.max(0, math.floor(x))
	return math.floor(x / 60), x % 60
end
-- What is watched: this client's car, or observing, the leader's
local function draw_hud(watched)
	local own = cars[own_id]
	local b, a = own and own.states[2], own and own.states[1]
	if b == nil then
		return
	end
	local speed = 0
	if a and b.t > a.t then
		local dx, dy, dz = b.v[1] - a.v[1], b.v[2] - a.v[2], b.v[3] - a.v[3]
		speed = math.sqrt(dx * dx + dy * dy + dz * dz) / (b.t - a.t) / U
	end
	local race, t = b.v[17], b.v[18]
	local state = race == 0 and "W starts the clock" or race == 1 and "" or
			race == 3 and "The hill is being made" or
			race == 4 and "Out of time: did not finish" or
			string.format("Finished in %.2f s. Backspace: another run", t)
	if watched and watched ~= own and watched.states[2] then
		state = string.format("Observing %s: %.2f s", watched.name,
				watched.states[2].v[18])
	end
	local lines = {string.format("Gear %s   %4.1f m/s   %6.2f s",
			GEARS[b.v[16]] or "?", speed, t), state}
	if round.phase > 0 then
		local f = ROUND[round.phase]
		lines[#lines + 1] = round.phase == 4 and string.format(f,
				math.ceil(round.left)) or round.phase == 1 and f or
				string.format(f, mmss(round.left))
	end
	if hud_note and scene.elapsedTime - hud_note.t < 3 then
		lines[#lines + 1] = hud_note.text
	end
	lines[#lines + 1] = "Tab: the hill and the car   Backspace: back to the "
			.. "start   T: chat"
	hud:SetText(table.concat(lines, "\n"))
	if picks and board.visible then
		local rows = {}
		if results and scene.elapsedTime - results.t < 8 then
			rows[1] = "The round's results:"
			for l in results.text:gmatch("[^\n]+") do
				rows[#rows + 1] = l:match("^%- ") and (l:sub(3) ..
						": did not finish") or ("  " .. l)
			end
		else
			rows[1] = string.format("Best on this hill with %d kg:",
					picks.payload)
			for i, e in ipairs(ranking.entries) do
				-- How worn the hill was when the run started
				local worn = (e.fin + e.unfin == 0) and "fresh" or
						string.format("after %d runs (%d finished)",
						e.fin + e.unfin, e.fin)
				rows[#rows + 1] = string.format("%s%2d. %7.2f s  %s, %s",
						i - 1 == ranking.last and ">" or " ", i, e.t, e.name, worn)
			end
			if #ranking.entries == 0 then
				rows[#rows + 1] = "  (none yet)"
			end
		end
		board:SetText(table.concat(rows, "\n"))
	end
	local now, shown = buildat.get_time_us(), {}
	for _, c in ipairs(chat_lines) do
		if now - c.t < 20e6 then
			shown[#shown + 1] = c.line
		end
	end
	chat_text:SetText(table.concat(shown, "\n"))
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
	draw_cars()
	if not chat_open and not menu and pressed(key.chat) then
		open_chat()
	end
	if not chat_open then
		menu_keys()
	end
	send_input()
	local watched = observed()
	draw_hud(watched or cars[own_id])
	local m = magic.input:GetMouseMove()
	if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
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
