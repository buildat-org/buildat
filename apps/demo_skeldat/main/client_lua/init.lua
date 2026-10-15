-- Buildat: apps/demo_skeldat/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- skeldat's client ([SKELDAT]): the world drawn with voxel_shading, the
-- player moved by player.lua (builtin/luanti's movement, copied), the
-- pointing, digging and placing, the keys, day and night, and the others
-- as boxes; the sounds of digging, placing and walking, and the music by
-- the place. The HUD and the inventory are ui.lua's, Escape's menu
-- pause.lua's, the mobs mobs.lua's. main.cpp is the other end of every
-- packet here.
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")
local log = buildat.Logger("skeldat")

local function load(name)
	local ok, err, m = buildat.run_script_file(name)
	assert(ok and m, name .. ": " .. tostring(err))
	return m
end
local physics = load("main/player.lua")

local scene = replicate.main_scene
local FAR_CLIP = 160
local POINT_RANGE = 4.5
local POINT_STEP = 0.02
-- builtin/luanti's sky and its pbr light's rules ([SKELDAT_LUANTI_PARTS]
-- 3), served by main.cpp under their own names: the sun, the moon and the
-- stars, dawn and dusk, and the light's colour as builtin/luanti's pbr
local sky_dome = load("luanti/sky_dome.lua")
local sky_light = load("luanti/sky_light.lua")
local PHYS = sky_light.PHYS

voxelworld.use_skylight = true
voxelworld.horizon = true
voxel_shading.set_packed_sky(true)
voxel_shading.use_sun_gate(true)
-- builtin/luanti's shaders, which the light's rules are for
voxel_shading.use_technique_set({
	plain = "luanti_client/res/LuantiVoxel.xml",
	modifiers = "main/SkeldatVoxel.xml",
	alpha = "luanti_client/res/LuantiVoxelAlpha.xml",
	masked = "luanti_client/res/LuantiVoxelMasked.xml",
	sun = "luanti_client/res/LuantiVoxelSun.xml",
	sun_modifiers = "main/SkeldatVoxelSun.xml",
	sun_alpha = "luanti_client/res/LuantiVoxelSunAlpha.xml",
	sun_masked = "luanti_client/res/LuantiVoxelSunMasked.xml",
})
-- The bones, the format's first modifier, drawn as skelenti's danger
-- (main/SkeldatVoxel.xml)
voxel_shading.use_modifiers(true)
voxelworld.lod_distance = 4000
voxelworld.send_distance = FAR_CLIP
voxelworld.physics_distance = 1

--
-- What the server says: the game is the shared state ui.lua draws from
--
local game = {
	items = {}, nodes = {}, hand = {},
	inv = {main = {}, craft = {}, craftresult = {}, craftpreview = {}},
	node_inv = {},
	stats = {hp = 20, breath = 10, breath_max = 10},
	wield = 1,
	day = 0.25, day_rate = 1 / 1200,
	listeners = {},
}

function game.parse_stack(s)
	if not s or s == "" then
		return nil
	end
	local name, count, wear = s:match("^(%S+)%s*(%d*)%s*(%d*)$")
	if not name then
		return nil
	end
	return {name = name, count = tonumber(count) or 1,
		wear = tonumber(wear) or 0}
end

function game.item_texture(name)
	local d = game.items[name]
	return d and d.image or nil
end

local function caps_of(s)
	local caps = {}
	for group, t1, t2, t3, uses in (s or ""):gmatch(
			"([^:;]+):([^,]+),([^,]+),([^:]+):(%d+);") do
		caps[#caps + 1] = {group = group, times = {tonumber(t1),
			tonumber(t2), tonumber(t3)}, uses = tonumber(uses)}
	end
	return caps
end

buildat.sub_packet("skeldat:items", function(data)
	for line in data:gmatch("[^\n]+") do
		local f = {}
		for part in (line .. "\t"):gmatch("([^\t]*)\t") do
			f[#f + 1] = part
		end
		if f[1] == "hand" then
			game.hand = {caps = caps_of(f[2])}
		elseif f[1] == "item" then
			game.items[f[2]] = {name = f[2], desc = f[3], image = f[4],
				stack_max = tonumber(f[5]), caps = caps_of(f[6]),
				eat = tonumber(f[7]) or 0}
		elseif f[1] == "node" then
			local groups = {}
			for k, v in (f[3] or ""):gmatch("([^=;]+)=(%d+);") do
				groups[k] = tonumber(v)
			end
			game.nodes[f[2]] = {groups = groups}
		end
	end
	log:info("skeldat: the item definitions in")
	game.changed()
end)

-- How long the wielded item takes on the node, as game.h's dig_time():
-- the first of its caps that digs it, else the hand's; nil for never
function game.dig_time(tool, node)
	local n = game.nodes[node]
	if not n then
		return nil
	end
	local t = game.items[tool]
	for _, def in ipairs({t or {caps = {}}, game.hand}) do
		for _, c in ipairs(def.caps or {}) do
			local g = n.groups[c.group]
			if g and g >= 1 and g <= 3 and (c.times[g] or 0) > 0 then
				return c.times[g]
			end
		end
	end
	return nil
end

local function parse_lists(data, into)
	for name, rest in data:gmatch("([%w_]+)=([^\n]*)") do
		local l = {}
		for s in (rest .. "|"):gmatch("([^|]*)|") do
			l[#l + 1] = s
		end
		into[name] = l
	end
end

function game.changed()
	for _, f in ipairs(game.listeners) do
		f()
	end
end

buildat.sub_packet("skeldat:inv", function(data)
	parse_lists(data, game.inv)
	game.changed()
end)

buildat.sub_packet("skeldat:node_inv", function(data)
	local at, rest = data:match("^([^\n]+)\n(.*)$")
	if at then
		game.node_inv[at] = {}
		parse_lists(rest, game.node_inv[at])
		game.changed()
	end
end)

buildat.sub_packet("skeldat:stats", function(data)
	local hp, breath = data:match("^(%-?%d+) (%-?%d+)")
	game.stats.hp, game.stats.breath = tonumber(hp), tonumber(breath)
	log:info("skeldat: hp " .. hp .. " breath " .. breath)
	game.changed()
end)

buildat.sub_packet("skeldat:time", function(data)
	local day, rate = data:match("^(%S+) (%S+)")
	game.day, game.day_rate = tonumber(day), tonumber(rate)
end)

-- A game's window over the world (ui.lua's, pause.lua's): while one is up
-- the mouse is the screen's, Escape calls `close`, and on.click(x, y,
-- button) and on.key(key) get the clicks and the keys first
local held = nil
function game.hold(close, window, _, on)
	held = close and {close = close, on = on or {}} or nil
end
function game.held()
	return held ~= nil
end
function game.send(name, data)
	buildat.send_packet("skeldat:" .. name, data)
end
-- What a player does in the world goes as builtin/luanti's session packets
-- (luanti/session.h), which the server's C++ reads
function game.send_luanti(name, value, type)
	buildat.send_packet("luanti:" .. name,
			value and cereal.binary_output(value, type) or "")
end
local VOXEL = {"object", {"x", "int32_t"}, {"y", "int32_t"}, {"z", "int32_t"}}
local function voxel(p)
	return {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5),
			z = math.floor(p.z + 0.5)}
end
local function send_voxel(name, p)
	game.send_luanti(name, {p = voxel(p)}, {"object", {"p", VOXEL}})
end
local function send_wield()
	game.send_luanti("wield", {tostring(game.wield)}, {"array", "string"})
end

--
-- The keys, in the client's key store ([LAUNCH_MENU_V2]): the shared
-- names where there is one, so the player's own movement keys apply
--
local KEYS = {
	{id = "forward", label = "Walk forward", default = "W",
		shared = "move.forward"},
	{id = "back", label = "Walk back", default = "S", shared = "move.back"},
	{id = "left", label = "Walk left", default = "A", shared = "move.left"},
	{id = "right", label = "Walk right", default = "D", shared = "move.right"},
	{id = "jump", label = "Jump, and up in water", default = "Space",
		shared = "jump"},
	{id = "sneak", label = "Sneak", default = "Left Shift", shared = "sneak"},
	{id = "inventory", label = "Inventory", default = "E",
		shared = "inventory"},
	{id = "hud", label = "The HUD on and off", default = "F1", shared = "hud"},
	{id = "chat", label = "Chat", default = "T", shared = "chat"},
	{id = "fly", label = "Fly on and off (admins)", default = "K",
		shared = "fly"},
	{id = "fast", label = "Fast on and off (admins)", default = "J"},
	{id = "noclip", label = "Noclip on and off, while flying (admins)",
		default = "H", shared = "noclip"},
}
local key = {}
game.key = key
local function declare_keys()
	local names = buildat.declare_keys(nil, "skeldat", KEYS)
	for _, k in ipairs(KEYS) do
		local name = type(names) == "table" and names[k.id] or k.default
		key[k.id] = magic.input:GetKeyFromName(name)
	end
end
declare_keys()
local function down(id)
	return held == nil and key[id] ~= 0 and magic.input:GetKeyDown(key[id])
end

--
-- The scene
--
do
	local zone = scene:CreateChild("Zone"):CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-100000, 100000)
	zone.fogStart = FAR_CLIP * 0.6
	zone.fogEnd = FAR_CLIP * 0.95
	-- Above Urho's default zone, as builtin/luanti's: a chunk that once
	-- landed on the default one kept its unset ambient
	zone.priority = 1
	zone.override = true
	game.zone = zone
end
-- The sun and the moon, two lights each faded over the hour it crosses
-- the horizon (builtin/luanti's [LIGHT_SHAPE], its shadow numbers)
local function body_light(name)
	local node = scene:CreateChild(name)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.specularIntensity = 1.0
	light.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
	light.shadowCascade = magic.CascadeParameters(24, 96, 0, 0, 0.8)
	return node, light
end
local sun_node, sun = body_light("Sun")
local moon_node, moon = body_light("Moon")
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.3}
local sky = sky_dome.new(scene, SUN_DIR, voxel_shading.sky_defaults,
		log)
sky:set_physical(true)
sky:set_auto_dim(false)
-- What the world reflects: the sky as it is drawn, re-rendered once a
-- second, a face a frame
local sky_cube = {cube = require("buildat/extension/skycube").new(magic,
		sky.material), due = 0}
game.zone.zoneTexture = sky_cube.cube.texture
voxel_shading.set_sky_light(1.0)
voxel_shading.set_specular_emphasis(0.7)
voxel_shading.set_gray_by_light(1.5)

local player = physics.new(
	function(x, y, z)
		local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
		if v == nil then
			return true -- not loaded: stand still rather than fall
		end
		local reg = voxelworld.get_voxel_registry()
		local id = reg:id_of(v)
		if id == 0 then
			return true
		end
		local def = reg:get_by_id(id)
		if def == nil then
			return true
		end
		return def.physically_solid and (reg:collision_boxes_of(v) or true)
	end,
	function(x, y, z)
		local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
		if v == nil then
			return false
		end
		local reg = voxelworld.get_voxel_registry()
		local def = reg:get_by_id(reg:id_of(v))
		return def ~= nil and def.swimmable == true
	end)
local yaw, pitch = 0, 0
local placed = false

local camera_node = scene:CreateChild("Camera")
local camera = camera_node:CreateComponent("Camera")
camera.nearClip = 0.05
camera.farClip = FAR_CLIP
magic.keep_fov(camera, 72)
do
	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})
	magic.renderer.HDRRendering = true
	local rp = sky_light.render_path(magic, viewport.renderPath)
	viewport.renderPath = rp
end
voxelworld.set_camera(camera_node)
voxel_shading.set_camera(camera_node)

buildat.sub_packet("skeldat:position", function(data)
	local x, y, z, yw = data:match("^(%S+) (%S+) (%S+) (%S+)")
	player:set_position(tonumber(x), tonumber(y), tonumber(z))
	yaw = tonumber(yw) or 0
	if not placed then
		-- The loading is over when the server has placed the player
		game.send_luanti("world_in")
	end
	placed = true
	log:info(string.format("skeldat: placed at (%.1f, %.1f, %.1f)",
			player.x, player.y, player.z))
end)

-- Day and night off the server's clock (game.day is Luanti's time of
-- day, 0.5 noon), lit by builtin/luanti's rules (sky_light.lua) at the sun
-- height of its stretched day: the sky's two ends in its hue at the
-- reference's radiance, and the sun, the moon, the ambient, the bounce,
-- the ground, a lamp, the cave floor and the fog from them. The sky's hue
-- by the hour is builtin/luanti's: night, dawn and day colours, three
-- blended (client.lua's apply_sky_of_hour), here at the render's day
-- colours alone.
-- simplified: no weather, no game sky; a clear sky every day
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
local CLOUD = {r = 0.9, g = 0.92, b = 0.95}
local function update_sky(dt)
	game.day = (game.day + dt * game.day_rate) % 1
	local daylight = game.day * 24000
	local tilt = sky_dome.orbit_tilt(nil, nil)
	-- The shadow's direction held a step at a time (a map rasterised from
	-- a light that turned between two frames crawls), the drawn sun smooth
	local sx, sy, sz = sky_dome.sun_direction(sky_dome.stepped_time(daylight),
			tilt)
	local mx, height, mz = sky_dome.sun_direction(daylight, tilt)
	local l = math.sqrt(sx * sx + sy * sy + sz * sz)
	local dir = magic.Vector3(-sx / l, -sy / l, -sz / l)
	local ml = math.sqrt(mx * mx + height * height + mz * mz)
	sky:set_sun_direction({x = -mx / ml, y = -height / ml, z = -mz / ml})
	voxel_shading.set_sun_direction({x = dir.x, y = dir.y, z = dir.z})
	sky:set_moon_look(sky_dome.moon_amount(daylight) > 0 and
			sky_dome.MOON_HALF or 0)
	local day = math.max(0, math.min(1, (height + 0.15) / 0.3))
	day = math.max(day, sky_dome.predawn(height))
	local up = sky_dome.sun_amount(daylight) * sky_dome.above_horizon(height)
	local moon_up = sky_dome.moon_amount(daylight) *
			sky_dome.above_horizon(-height)

	local lit = (0.175 + 0.825 * day) ^ 2.2
	local zenith, horizon = hue_of_hour(day, lit)
	zenith, horizon = sky_light.sky_radiance(zenith, horizon, height)
	sky:set_look(zenith, horizon, nil)
	-- Where a direction cannot see the sky (a cave): Luanti's indoors grey
	sky:set_indoors({r = 0.39, g = 0.39, b = 0.39}, lit)
	local t = sky_light.terms(height, sky_light.dome(zenith, horizon))
	sky:set_dawn_glow(t.glow.r, t.glow.g, t.glow.b, t.glow_tint)

	sun_node.enabled = up > 0
	if up > 0 then
		sun_node.direction = dir
		sun.brightness = t.sun
		sun.color = magic.Color(t.sun_color.r, t.sun_color.g, t.sun_color.b)
	end
	moon_node.enabled = moon_up > 0
	if moon_up > 0 then
		moon_node.direction = magic.Vector3(-dir.x, -dir.y, -dir.z)
		moon.brightness = t.moon * moon_up
		moon.color = magic.Color(t.moon_color.r, t.moon_color.g,
				t.moon_color.b)
	end
	local half = voxel_shading.sky_defaults.sun_half
	sky:set_sun_look(half, voxel_shading.sky_defaults.sun_color)
	sky:set_sun_radiance(sky_light.sun_disc(height, half, t.sun_color))
	sky:set_star_look(sky_dome.STAR_DENSITY_DEFAULT, nil,
			(1 - day) * (1 - day))
	sky:set_cloud_lit(sky_light.cloud_lit(CLOUD, zenith, horizon, height, 1))

	sky_light.apply(voxel_shading, game.zone, magic, t)
	-- For the mobs (mobs.lua), in the frame's units
	game.light_units = {ambient = t.ambient, bounce = {r = t.sky.r * PHYS.bounce,
		g = t.sky.g * PHYS.bounce, b = t.sky.b * PHYS.bounce}, lamp = t.lamp,
		sun = {r = t.sun_level * t.sun_color.r, g = t.sun_level * t.sun_color.g,
			b = t.sun_level * t.sun_color.b}}
	local seen = voxel_shading.sky_visibility_above()
	sky:set_outside(sky_light.outside(seen))
	local fc = sky_light.fog(horizon, t.ambient, seen)
	game.zone.fogColor = magic.Color(fc.r, fc.g, fc.b)

	local now = scene.elapsedTime
	if now >= sky_cube.due then
		sky_cube.due = now + 1
		sky_cube.cube:update()
	end
	sky_cube.cube:tick()
end
game.sky_light = sky_light

--
-- The danger is the bones around the player ([SKELDAT], user, 2026-10-15:
-- no danger zone on the client): the mean bones of the voxels that are not
-- empty in a box 9 across about the feet, every other voxel, 0 to 1. The
-- fog closes in with it, eased over about half a second; read four times
-- a second, logged at each tenth.
--
local fog = {d = 0, want = 0, t = 0, logged = -1}
local function danger_here()
	local reg = voxelworld.get_voxel_registry()
	local fx, fy, fz = math.floor(player.x + 0.5), math.floor(player.y + 0.5),
			math.floor(player.z + 0.5)
	local sum, n = 0, 0
	for dz = -4, 4, 2 do
		for dy = -4, 4, 2 do
			for dx = -4, 4, 2 do
				local p = buildat.Vector3(fx + dx, fy + dy, fz + dz)
				local v = voxelworld.get_static_voxel(p)
				local def = v and reg:get_by_id(reg:id_of(v))
				if def and not def.fully_empty then
					n = n + 1
					sum = sum + (voxelworld.get_static_voxel_plane(p, 1) or 0) % 16
				end
			end
		end
	end
	return n > 0 and sum / (n * 15) or 0
end
local function update_fog(dt)
	fog.t = fog.t - dt
	if fog.t <= 0 then
		fog.t = 0.25
		fog.want = danger_here()
	end
	fog.d = fog.d + (fog.want - fog.d) * math.min(1, dt * 2)
	local tenth = math.floor(fog.d * 10 + 0.5)
	if tenth ~= fog.logged then
		fog.logged = tenth
		log:info("skeldat: fog for danger " .. tenth / 10)
	end
	local far = FAR_CLIP * 0.95
	local fog_end = far - (far - 8) * fog.d
	game.zone.fogEnd = fog_end
	game.zone.fogStart = fog_end * (0.6 - 0.6 * fog.d)
end
game.danger = function() return fog.d end

--
-- Pointing: the voxel the eyes look at, and the empty one before it
--
local function voxel_def(v)
	if v == nil then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return nil
	end
	local def = reg:get_by_id(id)
	if def == nil or def.fully_empty then
		return nil
	end
	return def
end

-- builtin/luanti's find_pointed_voxel(): through what is not pointable,
-- onto the nearest selection box of what is
local function find_pointed()
	local p0 = buildat.Vector3(camera_node.worldPosition)
	local dir = buildat.Vector3(camera_node.worldDirection)
	local last = nil
	for i = 1, math.floor(POINT_RANGE / POINT_STEP) do
		local p = (p0 + dir * (i * POINT_STEP)):Round()
		if p ~= last then
			local v = voxelworld.get_static_voxel(p)
			local def = voxel_def(v)
			if def and def.pointable ~= 0 then
				local boxes = voxelworld.get_voxel_registry():selection_boxes_of(v)
				if not boxes then
					return p, last or p, def
				end
				local best, normal = POINT_RANGE, nil
				for _, b in ipairs(boxes) do
					local t0, t1, n = 0, best, nil
					for ax, k in ipairs({"x", "y", "z"}) do
						local o, d = p0[k] - p[k], dir[k]
						if math.abs(d) < 1e-9 then
							if o < b[ax] or o > b[ax + 3] then
								t0 = math.huge
							end
						else
							local a1, a2 = (b[ax] - o) / d, (b[ax + 3] - o) / d
							if a1 > a2 then
								a1, a2 = a2, a1
							end
							if a1 > t0 then
								t0, n = a1, {0, 0, 0}
								n[ax] = d < 0 and 1 or -1
							end
							t1 = math.min(t1, a2)
						end
					end
					if t0 <= t1 and t0 < best then
						best, normal = t0, n or {0, 0, 0}
					end
				end
				if normal then
					return p, p + buildat.Vector3(normal[1], normal[2],
							normal[3]), def
				end
			end
			last = p
		end
	end
	return nil
end

-- The pointed voxel outlined: a box of thin edges
local outline = scene:CreateChild("Outline")
do
	local g = outline:CreateComponent("CustomGeometry")
	g:BeginGeometry(0, magic.LINE_LIST)
	local d = 0.505
	local c = {{-d, -d, -d}, {d, -d, -d}, {d, -d, d}, {-d, -d, d},
		{-d, d, -d}, {d, d, -d}, {d, d, d}, {-d, d, d}}
	for _, e in ipairs({{1, 2}, {2, 3}, {3, 4}, {4, 1}, {5, 6}, {6, 7},
			{7, 8}, {8, 5}, {1, 5}, {2, 6}, {3, 7}, {4, 8}}) do
		for _, i in ipairs(e) do
			g:DefineVertex(magic.Vector3(c[i][1], c[i][2], c[i][3]))
			g:DefineColor(magic.Color(0.1, 0.1, 0.1))
		end
	end
	g:Commit()
	local m = magic.Material.new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureVCol.xml"))
	g:SetMaterial(0, m)
	outline.enabled = false
end

--
-- The sounds, made once at startup (sounds.lua): what a node sounds like
-- by what it is made of, as skelenti's game has it
-- simplified: only the player's own digging, placing and steps are heard;
-- the others' are not sent
--
local sounds = load("main/sounds.lua")
do
	local t0 = buildat.get_time_us()
	local made = sounds.make(require("buildat/extension/blip"))
	log:info(string.format("skeldat: %d sounds made in %.0f ms", made,
			(buildat.get_time_us() - t0) / 1000))
end
local mobs = load("main/mobs.lua")(game, sounds)
local function material_of(name)
	local n = name and game.nodes[name]
	local g = n and n.groups or {}
	return g.cracky and "stone" or g.crumbly and "earth" or
			g.choppy and "wood" or g.snappy and "leaves" or nil
end
local function node_sound(what, name, p, gain)
	local kind = material_of(name)
	if what == "step" and kind then
		kind = (name == "skeldat:gravel" or name == "skeldat:sand") and
				"gravel" or kind == "leaves" and "earth" or kind
	end
	if kind then
		mobs.play_at(what .. "_" .. kind, p.x, p.y, p.z, gain)
	end
end

--
-- Digging and placing
--
local pointed, above, pointed_def = nil, nil, nil
local dig = nil -- {key, t, need, name, sound_t}
local pointed_mob = nil
local place_cooldown = 0
local function pkey(p)
	return string.format("%d %d %d", p.x, p.y, p.z)
end

local function wielded()
	local st = game.parse_stack(game.inv.main[game.wield])
	return st and st.name or ""
end

local function step_dig(dt)
	if not pointed or held or not magic.input:GetMouseButtonDown(
			magic.MOUSEB_LEFT) then
		dig = nil
		return
	end
	local k = pkey(pointed)
	if not dig or dig.key ~= k then
		local name = pointed_def and pointed_def.name.block_name
		local need = name and game.dig_time(wielded(), name)
		if not need then
			dig = {key = k, t = 0}
			return
		end
		dig = {key = k, t = 0, need = need, name = name, sound_t = 0}
		send_voxel("dig_start", pointed)
	end
	if not dig.need then
		return
	end
	dig.t = dig.t + dt
	dig.sound_t = dig.sound_t - dt
	if dig.t >= dig.need then
		send_voxel("dig", pointed)
		node_sound("dig", dig.name, pointed, 1.0)
		dig = nil
	elseif dig.sound_t <= 0 then
		dig.sound_t = 0.3
		node_sound("dig", dig.name, pointed, 0.5)
	end
end

local function on_place()
	if not pointed then
		-- Eating needs nothing pointed at
		local d = game.items[wielded()]
		if d and d.eat > 0 then
			game.send_luanti("use")
		end
		return
	end
	local name = pointed_def and pointed_def.name.block_name
	if name == "skeldat:table" then
		game.open("table", (pkey(pointed):gsub(" ", ",")))
		game.send("open", pkey(pointed))
		return
	end
	if name == "skeldat:furnace" or name == "skeldat:furnace_active" then
		game.open("furnace", (pkey(pointed):gsub(" ", ",")))
		game.send("open", pkey(pointed))
		return
	end
	local d = game.items[wielded()]
	if d and d.eat > 0 then
		game.send_luanti("use")
	elseif above and game.nodes[wielded()] then
		game.send_luanti("place", {under = voxel(pointed), above = voxel(above),
				sneak = 0}, {"object", {"under", VOXEL}, {"above", VOXEL},
				{"sneak", "byte"}})
		node_sound("place", wielded(), above, 1.0)
	end
end

--
-- The others, as boxes
-- simplified: no names over them, no animation
--
local others = {}
buildat.sub_packet("skeldat:players", function(data)
	local seen = {}
	for name, x, y, z, yw, skeleton in
			data:gmatch("(%S+) (%S+) (%S+) (%S+) (%S+) (%S+)\n") do
		seen[name] = true
		do
			local o = others[name]
			if not o then
				local node = scene:CreateChild("Other")
				local body = node:CreateChild("Body")
				body.position = magic.Vector3(0, 0.875, 0)
				body.scale = magic.Vector3(0.6, 1.75, 0.6)
				local model = body:CreateComponent("StaticModel")
				model.model = magic.cache:GetResource("Model", "Models/Box.mdl")
				o = {node = node}
				others[name] = o
			end
			o.node.position = magic.Vector3(tonumber(x), tonumber(y),
					tonumber(z))
			o.node.rotation = magic.Quaternion(0, tonumber(yw), 0)
			-- [SKELDAT_SKELETON_PLAYERS] Near enough bones, the skeleton
			skeleton = skeleton == "1"
			if skeleton ~= (o.skeleton or false) then
				o.skeleton = skeleton
				o.node:GetChild("Body").enabled = not skeleton
				if skeleton then
					mobs.dress_as(o.node, "skeldat_skeleton")
				else
					mobs.undress(o.node)
				end
				log:info("skeldat: " .. name .. " looks like a " ..
						(skeleton and "skeleton" or "player"))
			end
		end
	end
	for name, o in pairs(others) do
		if not seen[name] then
			mobs.undress(o.node)
			o.node:Remove()
			others[name] = nil
		end
	end
end)

--
-- The mouse and the keys
--
local web = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
local mouse_in_world = false
local function set_mouse_in_world(on)
	mouse_in_world = on
	magic.input:SetMouseVisible(not on)
	if web then
		magic.input:SetMouseMode(on and magic.MM_RELATIVE or
				magic.MM_ABSOLUTE)
	end
end

local ui = load("main/ui.lua")(game)
game.open = ui.open
local open_pause = load("main/pause.lua")(game, declare_keys)

-- The chat's last lines over the world for a while, as Luanti's
local chat_text = magic.ui.root:CreateChild("Text")
chat_text:SetTextEffect(magic.TE_SHADOW)
chat_text.priority = 1000
chat_text:SetPosition(8, 8)
local CHAT_SHOWN, CHAT_FOR = 6, 20
local chat_recent = {}
local chat_size = nil
-- A line of the chat's, or the game's own to this player
local function hud_line(line)
	chat_recent[#chat_recent + 1] = {line = line, t = buildat.get_time_us()}
	if #chat_recent > CHAT_SHOWN then
		table.remove(chat_recent, 1)
	end
end
table.insert(require("buildat/module/chat").listeners, hud_line)

-- fly, fast and noclip, the admin's ([SKELDAT] decision 3), toggled by
-- their keys as Luanti's; the server checks nobody else's moves
local admin = false
buildat.sub_packet("skeldat:role", function(data)
	admin = data == "admin"
	game.admin = admin
	if not admin then
		player.fly, player.fast, player.noclip = false, false, false
	end
	log:info("skeldat: role " .. (admin and "admin" or "player"))
end)
-- A drive's own: the modes set whatever the role, as a modified client
-- would, for the server's movement check to be seen ("event
-- skeldat_modes fly noclip fast", any of them)
magic.SubscribeToEvent("command_seq:skeldat_modes", function(_, d)
	local p = " " .. d:GetString("Param") .. " "
	for _, mode in ipairs({"fly", "fast", "noclip"}) do
		player[mode] = p:find(" " .. mode .. " ") ~= nil
	end
	log:info("skeldat: modes set by the drive:" .. p)
end)
local function toggle(mode, on_text, off_text)
	if not admin then
		hud_line("Only an admin can " .. on_text:lower() .. ".")
		return
	end
	player[mode] = not player[mode]
	hud_line(player[mode] and on_text or off_text)
	log:info("skeldat: " .. mode .. " " .. tostring(player[mode]))
end
magic.SubscribeToEvent("Update", function()
	local now = buildat.get_time_us()
	while chat_recent[1] and now - chat_recent[1].t > CHAT_FOR * 1e6 do
		table.remove(chat_recent, 1)
	end
	local lines = {}
	for i, c in ipairs(chat_recent) do
		lines[i] = c.line
	end
	-- The HUD's scale (ui.lua's), as the root's size goes
	local r = magic.ui.root
	local size = 5 * math.max(1, math.floor(math.min(r.width / 320,
			r.height / 220)))
	if size ~= chat_size then
		chat_size = size
		chat_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono),
				size)
	end
	chat_text:SetText(table.concat(lines, "\n"))
	chat_text.visible = game.hud_visible() and not held
end)
local hud_on = true
function game.hud_visible()
	return hud_on
end

magic.SubscribeToEvent("KeyDown", function(_, d)
	local k = d:GetInt("Key")
	if held then
		if held.on.key and held.on.key(k) then
			return
		end
		if k == magic.KEY_ESCAPE then
			held.close()
		end
		return
	end
	if k == magic.KEY_ESCAPE then
		open_pause()
	elseif k == key.inventory then
		ui.open("inventory")
	elseif k == key.hud then
		hud_on = not hud_on
	elseif k == key.chat then
		game.chat()
	elseif k == key.fly then
		toggle("fly", "Fly", "Walk")
	elseif k == key.fast then
		toggle("fast", "Move fast", "Move at walking speed")
	elseif k == key.noclip then
		toggle("noclip", "Noclip (while flying)", "Noclip off")
	elseif k >= magic.KEY_1 and k <= magic.KEY_9 then
		game.wield = k - magic.KEY_1 + 1
		send_wield()
		game.changed()
	end
end)

-- A held window's clicks: UIMouseClick says where, in the root's own
-- coordinates once its letterbox in a scripted run is taken off
magic.SubscribeToEvent("UIMouseClick", function(_, d)
	if held and held.on.click then
		local rp = magic.ui.root.position
		held.on.click(d:GetInt("X") - rp.x, d:GetInt("Y") - rp.y,
				d:GetInt("Button") == magic.MOUSEB_RIGHT and "right" or "left")
	end
end)

magic.SubscribeToEvent("MouseButtonDown", function(_, d)
	local b = d:GetInt("Button")
	if held then
		return
	end
	if not mouse_in_world then
		set_mouse_in_world(true)
		return
	end
	if b == magic.MOUSEB_RIGHT then
		on_place()
	elseif b == magic.MOUSEB_LEFT and pointed_mob then
		mobs.punch(pointed_mob)
	end
end)

magic.SubscribeToEvent("MouseWheel", function(_, d)
	if held then
		return
	end
	local w = d:GetInt("Wheel")
	game.wield = (game.wield - 1 - (w > 0 and 1 or w < 0 and -1 or 0)) % 9 + 1
	send_wield()
	game.changed()
end)

--
-- The steps: one each 1.6 voxels walked on the ground
--
local step = {d = 0, x = nil, z = nil}
local function update_steps()
	if step.x and player.on_ground then
		step.d = step.d + math.sqrt((player.x - step.x) ^ 2 +
				(player.z - step.z) ^ 2)
		if step.d >= 1.6 then
			step.d = 0
			local p = buildat.Vector3(math.floor(player.x + 0.5),
					math.floor(player.y - 0.4), math.floor(player.z + 0.5))
			local def = voxel_def(voxelworld.get_static_voxel(p))
			node_sound("step", def and def.name.block_name, p, 0.5)
		end
	end
	step.x, step.z = player.x, player.z
end

--
-- The music, by the place (skelenti's): a cave (little sky at the head),
-- thick bones (the danger the fog reads), or sunrise; none otherwise. A
-- mood holds for 2 s before the music follows it, so the edge of a cave
-- does not flicker it. The first 5 s are not read: the world comes in.
--
local music = load("main/music.lua")
music.new(magic, log, scene)
local mood = {now = nil, seen = nil, held = 0, since = 0}
local function mood_here()
	if mood.since < 5 then
		return nil
	end
	local v = voxelworld.get_static_voxel(buildat.Vector3(
			math.floor(player.x + 0.5), math.floor(player.y + 1.6 + 0.5),
			math.floor(player.z + 0.5)))
	if v ~= nil and voxelworld.get_voxel_registry():light_sky_of(v) < 8 then
		return "caves"
	end
	if fog.want >= 0.5 then
		return "danger"
	end
	if game.day >= 0.2 and game.day < 0.33 then
		return "sunrise"
	end
end
local function update_music(dt)
	mood.since = mood.since + dt
	local m = mood_here()
	if m ~= mood.seen then
		mood.seen, mood.held = m, 0
	end
	mood.held = mood.held + dt
	if mood.held >= 2 and mood.now ~= m then
		mood.now = m
		log:info("skeldat: mood " .. tostring(m))
	end
	music.update(dt, mood.now)
end

--
-- The frame
--
local send_t = 0
local was_held = false
magic.SubscribeToEvent("Update", function(_, d)
	local dt = d:GetFloat("TimeStep")
	if (held ~= nil) ~= was_held then
		was_held = held ~= nil
		set_mouse_in_world(not was_held)
		dig = nil
	end
	update_sky(dt)
	voxel_shading.update(dt)
	if not placed then
		return
	end
	update_fog(dt)
	update_music(dt)
	if mouse_in_world and not held then
		local m = magic.input:GetMouseMove()
		yaw = (yaw + m.x * 0.12) % 360
		pitch = math.max(-89, math.min(89, pitch + m.y * 0.12))
	end
	local dead = game.stats.hp <= 0
	local fx, fz = 0, 0
	if not dead then
		local f = (down("forward") and 1 or 0) - (down("back") and 1 or 0)
		local r = (down("right") and 1 or 0) - (down("left") and 1 or 0)
		local s, c = math.sin(math.rad(yaw)), math.cos(math.rad(yaw))
		fx, fz = s * f + c * r, c * f - s * r
	end
	player:update(dt, {x = fx, z = fz, jump = not dead and down("jump"),
			sneak = not dead and down("sneak"), fast = player.fast})
	if player.landed_at then
		if player.landed_at > 14 then
			game.send_luanti("fell", {speed = player.landed_at},
					{"object", {"speed", "double"}})
		end
		player.landed_at = nil
	end
	camera_node.position = magic.Vector3(player.x,
			player.y + physics.EYE_HEIGHT, player.z)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	send_t = send_t + dt
	if send_t >= 0.1 then
		send_t = 0
		-- Luanti's look: radians, the horizontal turning the other way
		-- simplified: no controls; nothing on the server reads them
		game.send_luanti("where", {x = player.x, y = player.y, z = player.z,
			look_h = math.rad(-yaw), look_v = math.rad(pitch), controls = 0,
			sent_us = buildat.get_time_us()}, {"object", {"x", "double"},
			{"y", "double"}, {"z", "double"}, {"look_h", "double"},
			{"look_v", "double"}, {"controls", "int32_t"},
			{"sent_us", "double"}})
	end
	pointed_mob = nil
	if dead then
		pointed = nil
	else
		pointed, above, pointed_def = find_pointed()
		-- A mob before the voxel takes the click
		local eye = camera_node.worldPosition
		local t, id = mobs.point(eye, camera_node.worldDirection,
				POINT_RANGE)
		if t and (not pointed or t < (buildat.Vector3(eye) -
				pointed):Length() - 0.5) then
			pointed, pointed_mob = nil, id
		end
	end
	outline.enabled = pointed ~= nil
	if pointed then
		outline.position = magic.Vector3(pointed.x, pointed.y, pointed.z)
	end
	step_dig(dt)
	update_steps()
	ui.draw_hud()
end)

set_mouse_in_world(true)
log:info("skeldat client ready")
-- vim: set noet ts=4 sw=4:
